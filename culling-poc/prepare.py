"""Stage 0: scan a photo folder, extract embedded previews + EXIF capture time.

Usage: uv run python prepare.py <photo_dir> [--out data/manifest.json]
"""
import argparse
import io
import json
import subprocess
import sys
from pathlib import Path

import rawpy
from PIL import Image, ImageOps

from common import IMAGE_EXTS, RAW_EXTS, parse_capture_time, save_manifest

PREVIEW_DIR = Path("data/previews")
PREVIEW_MAX_SIDE = 1024  # plenty for pHash / face detection / VLM input


def list_photos(photo_dir):
    """One shutter press, one entry: a RAW+JPEG pair (same stem, e.g. DSCF7207.RAF
    + DSCF7207.JPG) is a single photo, keyed on the RAW half — the file XMP
    sidecars belong next to. Matches the native Swift engine's pairing."""
    all_images = sorted(p for p in Path(photo_dir).rglob("*") if p.suffix.lower() in IMAGE_EXTS)
    by_stem = {}
    for p in all_images:
        existing = by_stem.get(p.stem)
        if existing is None or (p.suffix.lower() in RAW_EXTS and existing.suffix.lower() not in RAW_EXTS):
            by_stem[p.stem] = p
    return sorted(by_stem.values())


def read_exif_batch(paths):
    """One exiftool call for the whole batch; far faster than per-file spawns."""
    if not paths:
        return {}
    cmd = ["exiftool", "-j", "-DateTimeOriginal", "-Model", "-Orientation", *[str(p) for p in paths]]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    records = json.loads(result.stdout)
    return {rec["SourceFile"]: rec for rec in records}


def extract_preview(path):
    """Return a PIL Image preview, downsized to PREVIEW_MAX_SIDE on the long edge."""
    suffix = path.suffix.lower()
    if suffix in RAW_EXTS:
        with rawpy.imread(str(path)) as raw:
            thumb = raw.extract_thumb()
        if thumb.format == rawpy.ThumbFormat.JPEG:
            img = Image.open(io.BytesIO(thumb.data))
        else:  # bitmap fallback, rare
            img = Image.fromarray(thumb.data)
    else:
        img = Image.open(path)
    # Cameras store the sensor's native (often landscape) pixel grid plus an EXIF
    # Orientation tag; without applying it, portrait shots come out sideways and
    # face detection in layer1 silently fails to find anyone.
    img = ImageOps.exif_transpose(img)
    img = img.convert("RGB")
    img.thumbnail((PREVIEW_MAX_SIDE, PREVIEW_MAX_SIDE), Image.LANCZOS)
    return img


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("photo_dir")
    parser.add_argument("--out", default="data/manifest.json")
    args = parser.parse_args()

    photos = list_photos(args.photo_dir)
    if not photos:
        print(f"No RAW/JPEG files found under {args.photo_dir}", file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(photos)} photos, reading EXIF...")
    exif_by_path = read_exif_batch(photos)

    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    entries = []
    for i, path in enumerate(photos):
        photo_id = path.stem
        exif = exif_by_path.get(str(path), {})
        try:
            preview = extract_preview(path)
        except Exception as e:
            print(f"  [skip] {path.name}: preview extraction failed ({e})", file=sys.stderr)
            continue

        preview_path = PREVIEW_DIR / f"{photo_id}.jpg"
        preview.save(preview_path, "JPEG", quality=90)

        capture_time = parse_capture_time(exif.get("DateTimeOriginal"))
        entries.append({
            "id": photo_id,
            "raw_path": str(path),
            "preview_path": str(preview_path),
            "capture_time": capture_time.isoformat() if capture_time else None,
            "camera": exif.get("Model"),
            "orientation": exif.get("Orientation"),
        })
        if (i + 1) % 25 == 0:
            print(f"  {i + 1}/{len(photos)} previews extracted")

    save_manifest({"photo_dir": str(args.photo_dir), "photos": entries})
    n_dated = sum(1 for e in entries if e["capture_time"])
    print(f"Done: {len(entries)} photos, {n_dated} with capture time. Wrote data/manifest.json")


if __name__ == "__main__":
    main()
