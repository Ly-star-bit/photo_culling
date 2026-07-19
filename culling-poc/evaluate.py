"""Stage 3: compare layer1/layer2 output against human labels.csv, produce report.html.

labels.csv columns:
  id                  - matches manifest photo id (filename stem)
  blur                - 1 if you consider the photo unusably out of focus, else 0
  closed_eyes         - 1 if the main subject's eyes are closed/bad, else 0
  group_id            - your own burst/duplicate grouping; same number = same burst.
                        Leave a unique number per photo if it isn't part of any burst.
  composition_issue   - free text description if there's a composition problem, else empty
  exposure_issue      - 1 if you'd reject/reshoot for exposure (blown highlights or
                        crushed shadows you can't recover), 0 if fine as shot — even
                        if it looks "clipped" in a preview but you know the RAW/your
                        edit intent (ETTR, deliberate underexposure) makes it a non-issue
  human_score         - your overall 1-5 keeper rating

Usage: uv run python evaluate.py --labels data/labels.csv
"""
import argparse
import csv
from itertools import combinations
from pathlib import Path

from jinja2 import Environment, FileSystemLoader

from common import group_bursts, load_manifest

HASH_THRESHOLDS = [4, 6, 8, 10, 12, 16]
TIME_WINDOWS = [1.0, 2.0, 3.0, 5.0]
SHARPNESS_THRESHOLDS = [20, 40, 60, 80, 100, 150, 200, 300, 500]
CLIP_PCT_THRESHOLDS = [0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3]


def load_labels(path):
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    labels = {}
    for r in rows:
        labels[r["id"]] = {
            "blur": int(r["blur"]) if r["blur"] not in ("", None) else None,
            "closed_eyes": int(r["closed_eyes"]) if r["closed_eyes"] not in ("", None) else None,
            "group_id": r["group_id"],
            "composition_issue": (r["composition_issue"] or "").strip(),
            "exposure_issue": int(r["exposure_issue"]) if r.get("exposure_issue") not in ("", None) else None,
            "human_score": int(r["human_score"]) if r["human_score"] not in ("", None) else None,
        }
    return labels


def recall_precision(y_true, y_pred):
    tp = sum(1 for t, p in zip(y_true, y_pred) if t == 1 and p == 1)
    fn = sum(1 for t, p in zip(y_true, y_pred) if t == 1 and p == 0)
    fp = sum(1 for t, p in zip(y_true, y_pred) if t == 0 and p == 1)
    recall = tp / (tp + fn) if (tp + fn) else None
    precision = tp / (tp + fp) if (tp + fp) else None
    return recall, precision


def sweep_blur_thresholds(l1_by_id, labels):
    rows = []
    for thr in SHARPNESS_THRESHOLDS:
        y_true, y_pred = [], []
        for pid, lab in labels.items():
            if lab["blur"] is None or pid not in l1_by_id:
                continue
            y_true.append(lab["blur"])
            y_pred.append(1 if l1_by_id[pid]["sharpness"] < thr else 0)
        recall, precision = recall_precision(y_true, y_pred)
        rows.append({"threshold": thr, "recall": recall, "precision": precision, "n": len(y_true)})
    return rows


def sweep_exposure_thresholds(l1_by_id, labels):
    """Sweeps a single clip-pct cutoff applied to max(highlight_clip_pct,
    shadow_clip_pct) — whichever side is worse decides. Same "measure, calibrate
    against real labels, don't guess" approach as sharpness."""
    rows = []
    for thr in CLIP_PCT_THRESHOLDS:
        y_true, y_pred = [], []
        for pid, lab in labels.items():
            if lab["exposure_issue"] is None or pid not in l1_by_id:
                continue
            r = l1_by_id[pid]
            worst_clip = max(r.get("highlight_clip_pct", 0), r.get("shadow_clip_pct", 0))
            y_true.append(lab["exposure_issue"])
            y_pred.append(1 if worst_clip >= thr else 0)
        recall, precision = recall_precision(y_true, y_pred)
        rows.append({"threshold": thr, "recall": recall, "precision": precision, "n": len(y_true)})
    return rows


def pairwise_group_agreement(pred_groups, labels):
    ids = [pid for pid in pred_groups if pid in labels and labels[pid]["group_id"]]
    tp = fp = fn = tn = 0
    for a, b in combinations(ids, 2):
        same_pred = pred_groups[a] == pred_groups[b]
        same_true = labels[a]["group_id"] == labels[b]["group_id"]
        if same_pred and same_true:
            tp += 1
        elif same_pred and not same_true:
            fp += 1
        elif not same_pred and same_true:
            fn += 1
        else:
            tn += 1
    precision = tp / (tp + fp) if (tp + fp) else None
    recall = tp / (tp + fn) if (tp + fn) else None
    f1 = (2 * precision * recall / (precision + recall)) if precision and recall else None
    return precision, recall, f1


def sweep_grouping(l1_results, labels):
    rows = []
    for thr in HASH_THRESHOLDS:
        for window in TIME_WINDOWS:
            groups = group_bursts(l1_results, hash_threshold=thr, time_window_sec=window)
            precision, recall, f1 = pairwise_group_agreement(groups, labels)
            rows.append({
                "hash_threshold": thr, "time_window": window,
                "precision": precision or 0, "recall": recall or 0, "f1": f1 or 0,
            })
    rows.sort(key=lambda r: r["f1"], reverse=True)
    return rows


def eye_closed_accuracy(l1_by_id, labels, key="eye_closed"):
    y_true, y_pred = [], []
    for pid, lab in labels.items():
        if lab["closed_eyes"] is None or pid not in l1_by_id:
            continue
        pred = l1_by_id[pid].get(key)
        if pred is None:  # no face detected, not evaluable
            continue
        y_true.append(lab["closed_eyes"])
        y_pred.append(1 if pred else 0)
    if not y_true:
        return None, 0
    acc = sum(1 for t, p in zip(y_true, y_pred) if t == p) / len(y_true)
    return acc, len(y_true)


def composition_agreement(l2_by_id, labels):
    y_true, y_pred = [], []
    for pid, lab in labels.items():
        if pid not in l2_by_id or "error" in l2_by_id[pid]:
            continue
        human_has_issue = 1 if lab["composition_issue"] else 0
        vlm_has_issue = 1 if l2_by_id[pid].get("composition_issues") else 0
        y_true.append(human_has_issue)
        y_pred.append(vlm_has_issue)
    if not y_true:
        return None, 0
    acc = sum(1 for t, p in zip(y_true, y_pred) if t == p) / len(y_true)
    return acc, len(y_true)


def build_rows(manifest_photos, l1_by_id, l2_by_id, labels, group_map):
    rows = []
    for photo in manifest_photos:
        pid = photo["id"]
        l1 = l1_by_id.get(pid, {})
        l2 = l2_by_id.get(pid, {})
        lab = labels.get(pid, {})

        pred_closed = l1.get("eye_closed")
        vlm_closed = l2.get("closed_eyes")
        human_closed = lab.get("closed_eyes")
        human_blur = lab.get("blur")
        sharpness = l1.get("sharpness")

        disagree = False
        if human_closed is not None and pred_closed is not None and bool(human_closed) != bool(pred_closed):
            disagree = True
        if human_closed is not None and vlm_closed is not None and bool(human_closed) != bool(vlm_closed):
            disagree = True
        human_has_issue = bool(lab.get("composition_issue"))
        vlm_has_issue = bool(l2.get("composition_issues"))
        if lab.get("composition_issue") is not None and human_has_issue != vlm_has_issue:
            disagree = True

        confidence = l2.get("confidence")
        rows.append({
            "id": pid,
            "preview_path": photo["preview_path"],
            "human_blur": human_blur if human_blur is not None else "-",
            "sharpness": sharpness,
            "sharpness_scope": l1.get("sharpness_scope", "-"),
            "human_closed_eyes": human_closed if human_closed is not None else "-",
            "pred_closed_eyes": pred_closed if pred_closed is not None else "-",
            "vlm_closed_eyes": vlm_closed if vlm_closed is not None else "-",
            "human_composition": lab.get("composition_issue") or "-",
            "vlm_composition": ", ".join(l2.get("composition_issues", [])) or "-",
            "vlm_reject": l2.get("reject_recommended", "-"),
            "vlm_confidence": confidence,
            "disagree": disagree,
            "lowconf": confidence is not None and confidence < 0.6,
        })

    rows.sort(key=lambda r: (not r["disagree"], not r["lowconf"], r["id"]))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="data/manifest.json")
    parser.add_argument("--layer1", default="data/layer1_results.json")
    parser.add_argument("--layer2", default="data/layer2_results.json")
    parser.add_argument("--labels", default="data/labels.csv")
    parser.add_argument("--out", default="report.html")
    args = parser.parse_args()

    manifest = load_manifest(Path(args.manifest))
    labels = load_labels(Path(args.labels))

    l1_data = load_manifest(Path(args.layer1)) if Path(args.layer1).exists() else {"results": []}
    l1_results = [r for r in l1_data["results"] if "error" not in r]
    l1_by_id = {r["id"]: r for r in l1_results}

    l2_by_id = {}
    if Path(args.layer2).exists():
        l2_data = load_manifest(Path(args.layer2))
        l2_by_id = {r["id"]: r for r in l2_data["results"]}

    metrics = []

    blur_sweep = sweep_blur_thresholds(l1_by_id, labels)
    best_blur = max(
        (r for r in blur_sweep if r["recall"] is not None and r["recall"] >= 0.9),
        key=lambda r: r["precision"] or 0, default=None,
    )
    if best_blur:
        metrics.append({
            "name": "虚焦检测 (最佳阈值, recall>=0.9)",
            "ok": True,
            "value": f"threshold={best_blur['threshold']}, precision={best_blur['precision']:.2f}",
            "detail": f"n={best_blur['n']}",
        })
    else:
        metrics.append({"name": "虚焦检测", "ok": False, "value": "no threshold reaches recall>=0.9", "detail": ""})

    exposure_sweep = sweep_exposure_thresholds(l1_by_id, labels)
    best_exposure = max(
        (r for r in exposure_sweep if r["recall"] is not None and r["recall"] >= 0.9),
        key=lambda r: r["precision"] or 0, default=None,
    )
    if best_exposure:
        metrics.append({
            "name": "曝光裁切检测 (最佳阈值, recall>=0.9)",
            "ok": True,
            "value": f"clip_pct>={best_exposure['threshold']}, precision={best_exposure['precision']:.2f}",
            "detail": f"n={best_exposure['n']}",
        })
    elif any(r["n"] > 0 for r in exposure_sweep):
        metrics.append({"name": "曝光裁切检测", "ok": False, "value": "no threshold reaches recall>=0.9", "detail": ""})

    group_sweep = sweep_grouping(l1_results, labels)
    best_group = group_sweep[0] if group_sweep else None
    default_groups = {r["id"]: r["burst_group"] for r in l1_results}
    if best_group:
        metrics.append({
            "name": "重复/连拍分组 (最佳组合)",
            "ok": best_group["f1"] >= 0.85,
            "value": f"hash<={best_group['hash_threshold']}, window={best_group['time_window']}s, F1={best_group['f1']:.2f}",
            "detail": f"precision={best_group['precision']:.2f}, recall={best_group['recall']:.2f}",
        })

    eye_acc, eye_n = eye_closed_accuracy(l1_by_id, labels)
    if eye_acc is not None:
        metrics.append({
            "name": "闭眼检测准确率 (MediaPipe, 仅有人脸样本)",
            "ok": eye_acc >= 0.9,
            "value": f"{eye_acc:.2%}",
            "detail": f"n={eye_n}",
        })

    if l2_by_id:
        vlm_eye_acc, vlm_eye_n = eye_closed_accuracy(l2_by_id, labels, key="closed_eyes")
        if vlm_eye_acc is not None:
            metrics.append({
                "name": "闭眼检测准确率 (VLM)",
                "ok": vlm_eye_acc >= 0.9,
                "value": f"{vlm_eye_acc:.2%}",
                "detail": f"n={vlm_eye_n}",
            })
        comp_acc, comp_n = composition_agreement(l2_by_id, labels)
        if comp_acc is not None:
            metrics.append({
                "name": "构图问题一致率 (VLM vs 人工, 有/无二分类)",
                "ok": comp_acc >= 0.7,
                "value": f"{comp_acc:.2%}",
                "detail": f"n={comp_n}",
            })
        avg_l2_time = sum(r["elapsed_sec"] for r in l2_by_id.values() if "error" not in r) / max(
            1, sum(1 for r in l2_by_id.values() if "error" not in r)
        )
        metrics.append({
            "name": "VLM 单张耗时",
            "ok": avg_l2_time < 3.0,
            "value": f"{avg_l2_time:.2f}s",
            "detail": f"model={l2_data.get('model', '-')}",
        })
    else:
        metrics.append({"name": "VLM 判断", "ok": False, "value": "未找到 layer2 结果", "detail": "先运行 layer2.py"})

    if l1_results:
        avg_l1_time = sum(r["elapsed_sec"] for r in l1_results) / len(l1_results)
        metrics.append({
            "name": "第一层单张耗时",
            "ok": avg_l1_time < 1.0,
            "value": f"{avg_l1_time:.3f}s",
            "detail": "",
        })

    rows = build_rows(manifest["photos"], l1_by_id, l2_by_id, labels, default_groups)

    env = Environment(loader=FileSystemLoader("."))
    template = env.get_template("report_template.html")
    html = template.render(metrics=metrics, group_sweep=group_sweep[:10], rows=rows)
    Path(args.out).write_text(html, encoding="utf-8")
    print(f"Wrote {args.out} ({len(rows)} rows, {sum(1 for r in rows if r['disagree'])} disagreements)")


if __name__ == "__main__":
    main()
