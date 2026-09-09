"""Shared helpers for the culling pipeline: manifest I/O and burst grouping."""
import json
import os
from datetime import datetime
from pathlib import Path

MANIFEST_PATH = Path("data/manifest.json")

RAW_EXTS = {
    ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".dng", ".rw2", ".pef", ".srw",
}
IMAGE_EXTS = RAW_EXTS | {".jpg", ".jpeg"}


def load_manifest(path=MANIFEST_PATH):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_manifest(manifest, path=MANIFEST_PATH):
    """Atomic: layer2 rewrites the whole results file every 10 photos and again
    from its SIGTERM handler (the GUI's cancel button); a signal landing
    mid-dump used to leave truncated JSON — resume was dead and every VLM
    verdict vanished from the grid."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def parse_capture_time(value):
    """exiftool DateTimeOriginal looks like '2026:06:01 14:23:11[.ss][+08:00]'."""
    if not value:
        return None
    value = value.split("+")[0].split(".")[0].strip()
    try:
        return datetime.strptime(value, "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None


def hamming(hash_a, hash_b):
    return bin(int(hash_a, 16) ^ int(hash_b, 16)).count("1")


def group_bursts(photos, hash_threshold=10, time_window_sec=2.0):
    """Group photos into bursts by perceptual-hash similarity + capture-time proximity.

    photos: list of dicts with 'id', 'phash' (hex str), 'capture_time' (ISO str or None).
    Sequential clustering ordered by capture time: a photo joins the current burst if it is
    within time_window_sec of the previous photo AND hash distance <= hash_threshold.
    Returns dict: photo_id -> group_id (int).
    """
    dated = [p for p in photos if p.get("capture_time")]
    undated = [p for p in photos if not p.get("capture_time")]
    dated.sort(key=lambda p: p["capture_time"])

    groups = {}
    group_id = 0
    prev = None
    for p in dated:
        if prev is None:
            group_id += 1
        else:
            prev_t = datetime.fromisoformat(prev["capture_time"])
            cur_t = datetime.fromisoformat(p["capture_time"])
            dt = (cur_t - prev_t).total_seconds()
            dist = hamming(prev["phash"], p["phash"]) if p.get("phash") and prev.get("phash") else 99
            if not (dt <= time_window_sec and dist <= hash_threshold):
                group_id += 1
        groups[p["id"]] = group_id
        prev = p

    for p in undated:
        group_id += 1
        groups[p["id"]] = group_id

    return groups
