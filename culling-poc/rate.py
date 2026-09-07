"""Stage 4: synthesize layer1 + layer2 signals into a final per-photo verdict
(废片/可用/精选) and write XMP sidecars so Lightroom/Capture One can read star
ratings and pick flags directly, no import plugin needed.

Reject (废片) if ANY of: layer1 confidently flagged closed-eyes, sharpness below
--sharpness-threshold, worst exposure clip pct at/above --exposure-threshold, or
the VLM recommended rejecting it. The two thresholds are NOT guessed defaults —
they must come from evaluate.py's threshold sweep against your own labels.csv
(same "measure, don't assume" principle as the rest of this pipeline).

Among the survivors, the sharpest/best-scored photo in each burst_group is the
"精选" (pick); everyone else that passed is "可用". Photos layer2.py never judged
(e.g. dedup losers, if you ran with --dedup-keep-best) fall back to a sharpness-only
rating since there's no VLM expression_score for them.

XMP sidecars are written next to the original file (never touching the original
photo itself) as `<stem>.xmp`, using the standard xmp:Rating field (-1 = rejected,
1-5 = stars) that Lightroom/Bridge/Capture One all read. The pick also gets
xmp:Label=Green, the common pick color-label convention. Lightroom Classic embeds
metadata directly into JPEGs by default rather than reading external sidecars for
them — for JPGs you may need Metadata > Read Metadata from Files after import to
pick these up; RAW formats read the sidecar natively.

Usage:
  uv run python rate.py --sharpness-threshold 50 --exposure-threshold 0.1 --write-xmp
"""
import argparse
import json
from pathlib import Path

from common import load_manifest, save_manifest

# 我们自己写的 sidecar 的指纹 —— Lightroom 写的是 x:xmptk="Adobe XMP Core ..."，
# 靠这个区分“可以安全覆盖”和“别人的调色数据，碰不得”。
XMP_MARKER = 'x:xmptk="culling-poc"'

XMP_TEMPLATE = """<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="culling-poc">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmp:Rating="{rating}">
{label_element}   <dc:description xmlns:dc="http://purl.org/dc/elements/1.1/">
    <rdf:Alt>
     <rdf:li xml:lang="x-default">{reason}</rdf:li>
    </rdf:Alt>
   </dc:description>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""


def rate_photo(l1, l2, sharpness_threshold, exposure_threshold, min_face_quality=0.0):
    reasons = []
    reject = False

    if l1.get("eye_closed") is True:
        reject = True
        reasons.append("闭眼")
    if l1["sharpness"] < sharpness_threshold:
        reject = True
        reasons.append(f"虚焦(sharpness={l1['sharpness']:.1f})")
    worst_clip = max(l1.get("highlight_clip_pct", 0.0), l1.get("shadow_clip_pct", 0.0))
    if worst_clip >= exposure_threshold:
        reject = True
        reasons.append(f"曝光裁切({worst_clip:.1%})")
    # face_quality is Apple's FaceCaptureQuality (native engine only; 0 disables).
    face_quality = l1.get("face_quality")
    if min_face_quality > 0 and face_quality is not None and face_quality < min_face_quality:
        reject = True
        reasons.append(f"人脸质量低({face_quality:.2f})")
    if l2 and l2.get("reject_recommended"):
        reject = True
        reasons.append(f"VLM建议淘汰: {l2.get('reason', '')}")

    return reject, reasons, worst_clip


def pick_group_bests(l1_by_id, l2_by_id, rejected_ids):
    """For each burst_group of 2+ surviving photos, return the id of the best one
    (highest VLM expression_score if judged, else highest sharpness as a tiebreak/
    fallback). A group of exactly one survivor never produces a pick — "精选" means
    it won a real comparison against similar shots, not that it was the only entry."""
    groups = {}
    for pid, l1 in l1_by_id.items():
        if pid in rejected_ids:
            continue
        groups.setdefault(l1["burst_group"], []).append(pid)

    best_ids = set()
    for group, pids in groups.items():
        if len(pids) < 2:
            continue
        def rank_key(pid):
            l2 = l2_by_id.get(pid)
            expr = l2["expression_score"] if l2 and "error" not in l2 else -1
            # FaceCaptureQuality outranks Laplacian sharpness — ranking same-subject
            # captures is exactly what Apple trained it for. Matches BatchStore.
            quality = l1_by_id[pid].get("face_quality")
            return (expr, quality if quality is not None else -1, l1_by_id[pid]["sharpness"])
        best_ids.add(max(pids, key=rank_key))
    return best_ids


def write_xmp(photo_path, rating, label, reason, force=False):
    """label: 'Green' for picks, 'Red' for rejects (the cross-app 淘汰 color —
    Capture One ignores Rating=-1 but filters color labels fine), None otherwise.

    Returns True when written, False when a foreign sidecar was left alone.
    Lightroom keeps develop settings, keywords and GPS in that same .xmp —
    replacing it with our rating-only template throws away a whole shoot's
    edits, so anything we didn't write ourselves is preserved unless --force-xmp.
    """
    xmp_path = Path(photo_path).with_suffix(".xmp")
    if xmp_path.exists() and not force:
        try:
            if XMP_MARKER not in xmp_path.read_text(encoding="utf-8", errors="ignore"):
                return False
        except OSError:
            return False
    label_element = f"   <xmp:Label>{label}</xmp:Label>\n" if label else ""
    # & first — escaping < first would turn a literal "<" into "&amp;lt;".
    escaped = reason.replace("&", "&amp;").replace("<", "&lt;")
    content = XMP_TEMPLATE.format(rating=rating, label_element=label_element, reason=escaped)
    xmp_path.write_text(content, encoding="utf-8")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="data/manifest.json")
    parser.add_argument("--layer1", default="data/layer1_results.json")
    parser.add_argument("--layer2", default="data/layer2_results.json")
    parser.add_argument("--sharpness-threshold", type=float, required=True,
                         help="from evaluate.py's blur threshold sweep, not a guess")
    parser.add_argument("--exposure-threshold", type=float, required=True,
                         help="from evaluate.py's exposure threshold sweep, not a guess")
    parser.add_argument("--min-face-quality", type=float, default=0.0,
                         help="reject when Apple FaceCaptureQuality is below this (0 disables)")
    parser.add_argument("--out", default="data/ratings.json")
    parser.add_argument("--write-xmp", action="store_true", help="write .xmp sidecars next to originals")
    parser.add_argument("--force-xmp", action="store_true",
                        help="overwrite sidecars written by other apps (DESTROYS Lightroom develop settings)")
    args = parser.parse_args()

    manifest = load_manifest(Path(args.manifest))
    l1_data = load_manifest(Path(args.layer1))
    l1_by_id = {r["id"]: r for r in l1_data["results"] if "error" not in r}

    l2_by_id = {}
    if Path(args.layer2).exists():
        l2_data = load_manifest(Path(args.layer2))
        l2_by_id = {r["id"]: r for r in l2_data["results"]}

    raw_path_by_id = {p["id"]: p["raw_path"] for p in manifest["photos"]}

    rejected_ids, reject_info = set(), {}
    for pid, l1 in l1_by_id.items():
        reject, reasons, worst_clip = rate_photo(l1, l2_by_id.get(pid), args.sharpness_threshold, args.exposure_threshold, args.min_face_quality)
        reject_info[pid] = (reject, reasons, worst_clip)
        if reject:
            rejected_ids.add(pid)

    pick_ids = pick_group_bests(l1_by_id, l2_by_id, rejected_ids)

    ratings = []
    xmp_written = 0
    xmp_preserved = []
    for pid, l1 in l1_by_id.items():
        reject, reasons, worst_clip = reject_info[pid]
        l2 = l2_by_id.get(pid)
        expression_score = l2["expression_score"] if l2 and "error" not in l2 else None

        if reject:
            verdict, stars = "废片", -1
        else:
            is_pick = pid in pick_ids
            if expression_score is not None:
                stars = expression_score if is_pick else max(1, expression_score - 1)
            else:
                stars = 4 if is_pick else 3
            verdict = "精选" if is_pick else "可用"

        entry = {
            "id": pid,
            "raw_path": raw_path_by_id.get(pid),
            "verdict": verdict,
            "stars": stars,
            "is_pick": pid in pick_ids,
            "reasons": reasons,
            "burst_group": l1["burst_group"],
        }
        ratings.append(entry)

        if args.write_xmp and entry["raw_path"]:
            label = "Green" if entry["is_pick"] else ("Red" if verdict == "废片" else None)
            if write_xmp(entry["raw_path"], stars, label,
                         "; ".join(reasons) if reasons else "", force=args.force_xmp):
                xmp_written += 1
            else:
                xmp_preserved.append(Path(entry["raw_path"]).name)

    save_manifest({"sharpness_threshold": args.sharpness_threshold,
                    "exposure_threshold": args.exposure_threshold,
                    "ratings": ratings}, Path(args.out))

    n_reject = sum(1 for r in ratings if r["verdict"] == "废片")
    n_pick = sum(1 for r in ratings if r["verdict"] == "精选")
    n_usable = sum(1 for r in ratings if r["verdict"] == "可用")
    print(f"Done: {len(ratings)} photos -> {n_reject} 废片, {n_usable} 可用, {n_pick} 精选. Wrote {args.out}")
    if args.write_xmp:
        print(f"Wrote {xmp_written} .xmp sidecars next to the original photos.")
        if xmp_preserved:
            sample = ", ".join(xmp_preserved[:3])
            print(f"Kept {len(xmp_preserved)} existing sidecars written by another app "
                  f"({sample}...) — they may hold Lightroom edits. Use --force-xmp to overwrite.")


if __name__ == "__main__":
    main()
