"""Stage 2: VLM semantic judgment (closed eyes / composition / expression).

Two backends:
- openai (default): one comprehensive JSON judgment per photo via an
  OpenAI-compatible endpoint (llama-server + Ternary-Bonsai-27B, vLLM, etc).
- ollama: tuned for SMALL models (MiniCPM-V 4.6 1.3B). Small models can't hold a
  long multi-part rubric, so the judgment is split into focused single-topic
  questions, each sent with the RIGHT image scale: the face CROP for eye state /
  expression, the FULL frame for background & framing. Output is grammar-locked
  with Ollama's `format` JSON-schema constraint. Prompts deliberately avoid
  enumerating example objects — measured on real photos, a 1.3B model happily
  echoes back every example you name (asked a 99px face crop about "trash bins,
  reflectors...", it reported all of them).

Usage:
  uv run python layer2.py --base-url http://localhost:8080/v1 --model qwen3-vl-8b
  uv run python layer2.py --backend ollama --base-url http://localhost:11434 \
      --model minicpm-v4.6:f16
  # production run: only judge photos that survived layer1 (sharp, in-focus,
  # not a duplicate, not confidently closed-eyes) — thresholds come from
  # evaluate.py's sweep against your labeled data, not guessed:
  uv run python layer2.py --skip-blurry 50 --dedup-keep-best --skip-closed-eyes
"""
import argparse
import base64
import io
import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests
from tqdm import tqdm

from common import load_manifest, save_manifest

PROMPT_PATH = Path("prompts/judge_prompt.txt")

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "closed_eyes": {"type": "boolean"},
        "composition_issues": {"type": "array", "items": {"type": "string"}},
        "expression_score": {"type": "integer", "minimum": 1, "maximum": 5},
        "reject_recommended": {"type": "boolean"},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "reason": {"type": "string"},
    },
    "required": [
        "closed_eyes", "composition_issues", "expression_score",
        "reject_recommended", "confidence", "reason",
    ],
}


def select_photos(manifest_photos, layer1_results, skip_blurry, dedup_keep_best, skip_closed_eyes):
    if layer1_results is None:
        return manifest_photos

    l1_by_id = {r["id"]: r for r in layer1_results if "error" not in r}
    keep_ids = set(l1_by_id)

    if skip_blurry is not None:
        keep_ids = {pid for pid in keep_ids if l1_by_id[pid]["sharpness"] >= skip_blurry}

    if skip_closed_eyes:
        # eye_closed is None when no face was found (nothing to skip there) — only
        # drop photos where layer1 confidently flagged the eyes as closed.
        keep_ids = {pid for pid in keep_ids if l1_by_id[pid].get("eye_closed") is not True}

    if dedup_keep_best:
        best_per_group = {}
        for pid in keep_ids:
            r = l1_by_id[pid]
            group = r["burst_group"]
            if group not in best_per_group or r["sharpness"] > l1_by_id[best_per_group[group]]["sharpness"]:
                best_per_group[group] = pid
        keep_ids = set(best_per_group.values())

    return [p for p in manifest_photos if p["id"] in keep_ids]


def encode_image_b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def extract_json(text):
    text = text.strip()
    text = re.sub(r"^```(?:json)?|```$", "", text, flags=re.MULTILINE).strip()
    match = re.search(r"\{.*\}", text, flags=re.DOTALL)
    if not match:
        raise ValueError(f"no JSON object found in response: {text[:200]!r}")
    return json.loads(match.group(0))


def call_vlm(base_url, model, prompt_text, image_b64, timeout, use_schema=True):
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt_text},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                ],
            }
        ],
        "temperature": 0.1,
        "max_tokens": 400,
    }
    if use_schema:
        payload["response_format"] = {
            "type": "json_schema",
            "json_schema": {"name": "photo_judgement", "schema": RESPONSE_SCHEMA, "strict": True},
        }

    resp = requests.post(f"{base_url}/chat/completions", json=payload, timeout=timeout)
    if use_schema and resp.status_code >= 400:
        # server may not support structured outputs; retry relying on prompt + lenient parse
        return call_vlm(base_url, model, prompt_text, image_b64, timeout, use_schema=False)
    resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]
    return extract_json(content)


def judge_photo(photo, base_url, model, prompt_text, timeout):
    t0 = time.perf_counter()
    try:
        image_b64 = encode_image_b64(photo["preview_path"])
        judgement = call_vlm(base_url, model, prompt_text, image_b64, timeout)
        judgement["id"] = photo["id"]
        judgement["elapsed_sec"] = time.perf_counter() - t0
        return judgement
    except Exception as e:
        return {"id": photo["id"], "error": str(e), "elapsed_sec": time.perf_counter() - t0}


# --- ollama backend (small-model question suite) ---------------------------

FACE_SCHEMA = {
    "type": "object",
    "properties": {
        "eyes": {"type": "string", "enum": ["open", "closed", "squinting_smile", "not_visible"]},
        "expression_score": {"type": "integer", "minimum": 1, "maximum": 5},
    },
    "required": ["eyes", "expression_score"],
}
FACE_PROMPT = (
    "This is a face from a portrait photo shoot. "
    "1) Are the eyes closed (caught mid-blink), open, or narrowed because the person "
    "is smiling naturally? If you cannot see the eyes, say not_visible. "
    "2) Rate the facial expression for a delivered portrait from 1 (awkward, "
    "mid-speech, unflattering) to 5 (natural and engaging)."
)

FRAME_SCHEMA = {
    "type": "object",
    "properties": {
        "background_distractions": {"type": "array", "items": {"type": "string"}},
        "photobomber": {"type": "boolean"},
        "awkward_limb_crop": {"type": "boolean"},
    },
    "required": ["background_distractions", "photobomber", "awkward_limb_crop"],
}
# Open-ended on purpose: naming example objects makes the small model "find" them.
# "Photobomber" is defined tightly — distant background people are NORMAL in
# location shoots and the model calls them intruders if you let it.
FRAME_PROMPT = (
    "You are reviewing a portrait photo before delivering it to a client. "
    "1) List anything in the background a photographer would consider a real "
    "problem for the delivered photo (empty list if none; ordinary scenery and "
    "distant background people are fine). "
    "2) Is another person OVERLAPPING or BLOCKING the subject, or so close and "
    "prominent that they compete with the subject? Distant people behind the "
    "subject do not count. "
    "3) Do any of the subject's limbs get cut off at an awkward point by the "
    "edge of the frame?"
)


def call_ollama(base_url, model, prompt_text, image_b64, schema, timeout):
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt_text, "images": [image_b64]}],
        "format": schema,
        "stream": False,
        # think must be OFF: MiniCPM-V 4.6 on newer Ollama defaults to thinking
        # mode, and a long prompt makes it burn the whole num_predict budget
        # inside `thinking` — `content` comes back EMPTY and the batch dies
        # with a JSON parse error on every photo.
        "think": False,
        # num_ctx pinned: this Ollama version auto-sizes context to VRAM
        # (262144 on big Macs) and the KV cache lazily grows toward that
        # ceiling as photos stream through — reads as a memory leak. One
        # image + a short question + a JSON answer fits in 8K many times over.
        "options": {"temperature": 0, "num_ctx": 8192, "num_predict": 500},
    }
    resp = requests.post(f"{base_url}/api/chat", json=payload, timeout=timeout)
    if resp.status_code == 400:
        # Older Ollama / models that reject the think param — retry without it.
        payload.pop("think", None)
        resp = requests.post(f"{base_url}/api/chat", json=payload, timeout=timeout)
    resp.raise_for_status()
    content = resp.json()["message"]["content"]
    if not content.strip():
        raise ValueError("empty content from model (thinking ate the token budget?)")
    return json.loads(content)


def face_crop_b64(photo, l1, pad=0.15):
    """Crop the primary face out of the preview (bbox is normalized top-left from
    layer1). Falls back to the full preview when there's no face."""
    bbox = (l1 or {}).get("face_bbox")
    if not bbox:
        return None
    from PIL import Image

    with Image.open(photo["preview_path"]) as im:
        w, h = im.size
        x0, y0, x1, y1 = bbox
        px, py = (x1 - x0) * pad, (y1 - y0) * pad
        crop = im.crop((
            int(max(0.0, x0 - px) * w), int(max(0.0, y0 - py) * h),
            int(min(1.0, x1 + px) * w), int(min(1.0, y1 + py) * h),
        ))
        if crop.width < 8 or crop.height < 8:
            return None
        buf = io.BytesIO()
        crop.convert("RGB").save(buf, format="JPEG", quality=90)
        return base64.b64encode(buf.getvalue()).decode("ascii")


SHARP_SCHEMA = {
    "type": "object",
    "properties": {"subject_sharp": {"type": "boolean"}},
    "required": ["subject_sharp"],
}
SHARP_PROMPT = (
    "This photo was flagged as possibly out of focus by an algorithm. Look at "
    "the MAIN SUBJECT (the person, or the central object if there is no person). "
    "Is the subject itself acceptably sharp and in focus? Ignore background "
    "blur — shallow depth of field is normal in portraits."
)

EXPOSURE_SCHEMA = {
    "type": "object",
    "properties": {"intentional_exposure": {"type": "boolean"}},
    "required": ["intentional_exposure"],
}
EXPOSURE_PROMPT = (
    "This photo was flagged for clipped highlights or shadows. Does the exposure "
    "read as a deliberate artistic choice that still delivers a usable photo "
    "(silhouette, dramatic backlight, high-key or low-key look), rather than a "
    "genuinely ruined exposure?"
)


def judge_photo_appeal(photo, l1, reasons, base_url, model, timeout):
    """Appeal court: the photo was auto-rejected; re-examine ONLY the charges it
    was rejected for. Output carries a verdict per charge — the GUI drops a
    charge when the VLM clears it, and the photo walks if no charges remain."""
    t0 = time.perf_counter()
    try:
        out = {"id": photo["id"]}
        notes = []
        full_b64 = encode_image_b64(photo["preview_path"])

        if any("闭眼" in r for r in reasons):
            crop_b64 = face_crop_b64(photo, l1)
            face = call_ollama(base_url, model, FACE_PROMPT, crop_b64 or full_b64,
                               FACE_SCHEMA, timeout)
            out["closed_eyes"] = face["eyes"] == "closed"
            out["expression_score"] = face["expression_score"]
            notes.append("闭眼维持" if out["closed_eyes"] else
                         ("眯眼笑平反" if face["eyes"] == "squinting_smile" else "睁眼平反"))
        if any("虚焦" in r for r in reasons):
            sharp = call_ollama(base_url, model, SHARP_PROMPT, full_b64,
                                SHARP_SCHEMA, timeout)
            out["subject_sharp"] = sharp["subject_sharp"]
            notes.append("主体清晰平反" if sharp["subject_sharp"] else "虚焦维持")
        if any("曝光" in r for r in reasons):
            expo = call_ollama(base_url, model, EXPOSURE_PROMPT, full_b64,
                               EXPOSURE_SCHEMA, timeout)
            out["intentional_exposure"] = expo["intentional_exposure"]
            notes.append("刻意曝光平反" if expo["intentional_exposure"] else "曝光维持")

        out["reason"] = "; ".join(notes) if notes else "无可复审罪名"
        out["elapsed_sec"] = time.perf_counter() - t0
        return out
    except Exception as e:
        return {"id": photo["id"], "error": str(e), "elapsed_sec": time.perf_counter() - t0}


class GroupFrameCache:
    """FRAME-question answers shared across a burst group. The background /
    photobomber / limb-crop situation is identical for every frame of a 2-second
    burst, so ask once per group instead of once per photo — 30-40% fewer VLM
    calls on bursty shoots, at ~6s/call. Per-group locks make concurrent
    siblings wait for the one in-flight answer instead of duplicating it."""

    def __init__(self):
        self._cache = {}
        self._locks = {}
        self._master = threading.Lock()

    def get_or_compute(self, group, compute):
        if group is None:
            return compute()
        with self._master:
            lock = self._locks.setdefault(group, threading.Lock())
        with lock:
            if group not in self._cache:
                self._cache[group] = compute()
            return self._cache[group]


def judge_photo_ollama(photo, l1, base_url, model, timeout, frame_cache=None):
    """Two focused calls instead of one rubric: face crop (eyes, expression),
    full frame (background, photobombers, limb crops). Results are mapped onto
    the same output schema the openai backend produces, so rate.py / the GUI /
    evaluate.py don't know or care which backend ran."""
    t0 = time.perf_counter()
    try:
        full_b64 = encode_image_b64(photo["preview_path"])
        crop_b64 = face_crop_b64(photo, l1)

        face = call_ollama(base_url, model, FACE_PROMPT, crop_b64 or full_b64,
                           FACE_SCHEMA, timeout)
        group = (l1 or {}).get("burst_group")

        def ask_frame():
            return call_ollama(base_url, model, FRAME_PROMPT, full_b64,
                               FRAME_SCHEMA, timeout)

        frame = frame_cache.get_or_compute(group, ask_frame) if frame_cache else ask_frame()

        closed = face["eyes"] == "closed"
        issues = list(frame["background_distractions"])
        if frame["photobomber"]:
            issues.append("背景有人抢镜")
        if frame["awkward_limb_crop"]:
            issues.append("肢体被画框切断")

        reasons = []
        if closed:
            reasons.append("闭眼(非眯眼笑)")
        elif face["eyes"] == "squinting_smile":
            reasons.append("眯眼笑(放行)")
        if issues:
            reasons.append("构图: " + "; ".join(issues))

        return {
            "id": photo["id"],
            "closed_eyes": closed,
            "composition_issues": issues,
            "expression_score": face["expression_score"],
            # Only a confirmed blink kills. Everything else (photobomber, limb
            # crop, clutter) surfaces as composition badges for the photographer
            # to weigh — a 1.3B model doesn't get veto power over scene judgment
            # (measured: it flagged distant bridge tourists as photobombers).
            "reject_recommended": closed,
            "confidence": 0.8,
            "reason": "; ".join(reasons) if reasons else "无明显问题",
            "elapsed_sec": time.perf_counter() - t0,
        }
    except Exception as e:
        return {"id": photo["id"], "error": str(e), "elapsed_sec": time.perf_counter() - t0}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="data/manifest.json")
    parser.add_argument("--layer1", default="data/layer1_results.json")
    parser.add_argument("--no-layer1-filter", action="store_true", help="judge every photo, ignore layer1")
    parser.add_argument("--ids-file", default=None,
                        help="only judge photo ids listed in this file (one per line) — "
                             "used by the GUI to send only the photos that survived its thresholds")
    parser.add_argument("--skip-blurry", type=float, default=None, help="drop photos with sharpness below this")
    parser.add_argument("--dedup-keep-best", action="store_true", help="only judge the sharpest photo per burst group")
    parser.add_argument("--skip-closed-eyes", action="store_true", help="drop photos layer1 confidently flagged as closed-eyes")
    parser.add_argument("--backend", choices=["openai", "ollama"], default="openai",
                        help="openai: one comprehensive judgment per photo (big models); "
                             "ollama: focused per-topic questions with face crops (small models)")
    parser.add_argument("--mode", choices=["full", "appeal"], default="full",
                        help="full: judge photos (eyes/composition/expression); "
                             "appeal: re-examine auto-REJECTED photos, asking only about "
                             "the charges in --appeal-file (ollama backend only)")
    parser.add_argument("--appeal-file", default=None,
                        help="JSON {photo_id: [reject reasons]} written by the GUI for --mode appeal")
    parser.add_argument("--base-url", default="http://localhost:8080/v1",
                        help="for --backend ollama use the server root, e.g. http://localhost:11434")
    parser.add_argument("--model", default="local-vlm")
    parser.add_argument("--out", default="data/layer2_results.json")
    parser.add_argument("--concurrency", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--progress", action="store_true",
                        help="print machine-readable 'PROGRESS n/total' lines to stdout as photos finish (for GUI streaming)")
    parser.add_argument("--fresh", action="store_true",
                        help="re-judge everything, ignoring results already in --out")
    args = parser.parse_args()

    manifest = load_manifest(Path(args.manifest))
    photos = manifest["photos"]

    # The ollama backend needs layer1's face bboxes for its crops even when
    # layer1 FILTERING is off, so load the file whenever it exists.
    all_l1 = None
    if Path(args.layer1).exists():
        all_l1 = load_manifest(Path(args.layer1))["results"]
    l1_by_id = {r["id"]: r for r in (all_l1 or []) if "error" not in r}

    layer1_results = None if args.no_layer1_filter else all_l1
    photos = select_photos(photos, layer1_results, args.skip_blurry, args.dedup_keep_best, args.skip_closed_eyes)
    if args.ids_file:
        wanted = {line.strip() for line in open(args.ids_file, encoding="utf-8") if line.strip()}
        photos = [p for p in photos if p["id"] in wanted]
    if args.limit:
        photos = photos[: args.limit]

    # Resume: photos already judged (successfully, by the SAME model) are skipped
    # and their results carried over — an interrupted batch continues instead of
    # restarting. Results are flushed to disk after EVERY photo, so any kind of
    # death (cancel, crash, server gone) loses at most the in-flight requests.
    out_path = Path(args.out)
    done_by_id = {}
    if not args.fresh and out_path.exists():
        try:
            prev = load_manifest(out_path)
            if prev.get("model") == args.model:
                done_by_id = {r["id"]: r for r in prev.get("results", []) if "error" not in r}
        except Exception:
            pass
    todo = [p for p in photos if p["id"] not in done_by_id]
    if len(todo) < len(photos):
        print(f"Resuming: {len(photos) - len(todo)} already judged, {len(todo)} remaining")
    print(f"Judging {len(todo)} photos with model={args.model!r} at {args.base_url}")

    def flush():
        save_manifest({"model": args.model, "base_url": args.base_url,
                       "results": list(done_by_id.values())}, out_path)

    appeal_reasons = {}
    if args.mode == "appeal":
        if args.appeal_file and Path(args.appeal_file).exists():
            appeal_reasons = json.loads(Path(args.appeal_file).read_text(encoding="utf-8"))
        else:
            raise SystemExit("--mode appeal requires --appeal-file")

    finished = 0
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        if args.mode == "appeal":
            futures = {
                pool.submit(judge_photo_appeal, p, l1_by_id.get(p["id"]),
                            appeal_reasons.get(p["id"], []),
                            args.base_url, args.model, args.timeout): p
                for p in todo
            }
        elif args.backend == "ollama":
            frame_cache = GroupFrameCache()
            futures = {
                pool.submit(judge_photo_ollama, p, l1_by_id.get(p["id"]),
                            args.base_url, args.model, args.timeout, frame_cache): p
                for p in todo
            }
        else:
            prompt_text = PROMPT_PATH.read_text(encoding="utf-8")
            futures = {
                pool.submit(judge_photo, p, args.base_url, args.model, prompt_text, args.timeout): p
                for p in todo
            }
        for fut in tqdm(as_completed(futures), total=len(futures), desc="layer2"):
            result = fut.result()
            done_by_id[result["id"]] = result
            flush()
            finished += 1
            if args.progress:
                print(f"PROGRESS {finished}/{len(futures)}", flush=True)

    flush()
    results = list(done_by_id.values())
    ok = [r for r in results if "error" not in r]
    errors = [r for r in results if "error" in r]
    avg_time = sum(r["elapsed_sec"] for r in ok) / len(ok) if ok else 0
    print(f"Done: {len(ok)} judged, {len(errors)} errors. Avg {avg_time:.2f}s/photo. Wrote {args.out}")
    if errors:
        print(f"  sample error: {errors[0]['id']}: {errors[0]['error']}")


if __name__ == "__main__":
    main()
