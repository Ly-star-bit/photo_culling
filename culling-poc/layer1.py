"""Stage 1: cheap algorithmic triage — burst dedup, face-region sharpness, eye-closed.

Design notes (see project discussion):
- Dedup uses pHash on the small preview (fast, sufficient).
- Sharpness is measured on a half-size RAW decode, NOT the small preview — embedded
  previews are downsampled enough to hide subtle focus misses, which is exactly the
  judgment call that matters most. Non-RAW inputs just use the full image.
- Face LOCATION uses YuNet (cv2.FaceDetectorYN), not MediaPipe's bundled detector.
  MediaPipe FaceLandmarker's own face detector is tuned for close-up/selfie-style
  faces and, confirmed on real environmental-portrait photos (full-body shot, face
  a small fraction of frame), fails to find anyone at all — at any resolution, since
  it's a relative-size problem, not a downsampling one. YuNet handles this framing
  correctly. Once YuNet locates the face, MediaPipe FaceLandmarker runs on a tight
  crop around it just for blendshapes (eyeBlinkLeft/Right) — more robust than a
  hand-rolled eye-aspect-ratio threshold across eye shapes / squint-smiles, and it
  works fine once handed a properly-scaled crop.
- Photos with no detected face skip eye-closed (None) and fall back to whole-frame
  sharpness, since focus-on-face doesn't apply to detail/venue/landscape shots.

Usage: uv run python layer1.py [--manifest data/manifest.json] [--out data/layer1_results.json]
"""
import argparse
import time
from pathlib import Path

import cv2
import imagehash
import mediapipe as mp
import numpy as np
import rawpy
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision as mp_vision
from PIL import Image, ImageOps
from tqdm import tqdm

from common import RAW_EXTS, group_bursts, load_manifest, save_manifest

FACE_LANDMARKER_MODEL_PATH = "models/face_landmarker.task"
FACE_DETECTOR_MODEL_PATH = "models/face_detection_yunet.onnx"
BLINK_THRESHOLD = 0.5  # blendshape score above which an eye counts as closed
FACE_DETECT_CONFIDENCE = 0.6
BBOX_PADDING = 0.15    # fraction of bbox size to pad on each side before cropping


def build_landmarker():
    options = mp_vision.FaceLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=FACE_LANDMARKER_MODEL_PATH),
        running_mode=mp_vision.RunningMode.IMAGE,
        output_face_blendshapes=True,
        num_faces=1,
    )
    return mp_vision.FaceLandmarker.create_from_options(options)


def build_face_detector():
    return cv2.FaceDetectorYN.create(
        FACE_DETECTOR_MODEL_PATH, "", (320, 320), score_threshold=FACE_DETECT_CONFIDENCE
    )


def crop_bbox(img_array, bbox_norm):
    h, w = img_array.shape[:2]
    x0, y0, x1, y1 = bbox_norm
    return img_array[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)]


def locate_face_bbox(face_detector, preview_arr_rgb):
    """Returns a padded normalized (x0, y0, x1, y1) bbox for the highest-confidence
    face, or None. YuNet's faces are pre-sorted by confidence descending."""
    h, w = preview_arr_rgb.shape[:2]
    arr_bgr = cv2.cvtColor(preview_arr_rgb, cv2.COLOR_RGB2BGR)
    face_detector.setInputSize((w, h))
    _, faces = face_detector.detect(arr_bgr)
    if faces is None or len(faces) == 0:
        return None

    x, y, fw, fh = faces[0][:4]
    x0, y0, x1, y1 = x / w, y / h, (x + fw) / w, (y + fh) / h
    pad_x = (x1 - x0) * BBOX_PADDING
    pad_y = (y1 - y0) * BBOX_PADDING
    return (max(0.0, x0 - pad_x), max(0.0, y0 - pad_y), min(1.0, x1 + pad_x), min(1.0, y1 + pad_y))


def detect_face(landmarker, face_detector, preview_img):
    """Returns (bbox_norm, eye_closed, blink_score) or (None, None, None) if no face.
    bbox_norm = (x0, y0, x1, y1) as fractions of image width/height, padded.
    """
    preview_arr = np.asarray(preview_img)
    bbox = locate_face_bbox(face_detector, preview_arr)
    if bbox is None:
        return None, None, None

    crop = crop_bbox(preview_arr, bbox)
    if crop.size == 0:
        return bbox, None, None

    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(crop))
    result = landmarker.detect(mp_image)

    blink_score = None
    eye_closed = None
    if result.face_blendshapes:
        scores = {c.category_name: c.score for c in result.face_blendshapes[0]}
        left = scores.get("eyeBlinkLeft", 0.0)
        right = scores.get("eyeBlinkRight", 0.0)
        blink_score = (left + right) / 2
        eye_closed = blink_score > BLINK_THRESHOLD

    return bbox, eye_closed, blink_score


def laplacian_variance(gray):
    return cv2.Laplacian(gray, cv2.CV_64F).var()


HIGHLIGHT_CLIP_VALUE = 250  # out of 255; a pixel counts as blown only if every channel is this bright
SHADOW_CLIP_VALUE = 5       # a pixel counts as crushed only if every channel is this dark


def exposure_clipping(rgb_array):
    """Returns (highlight_clip_pct, shadow_clip_pct): fraction of pixels where every
    channel is blown/crushed (a true washed-out white or black, not just a saturated
    color like a pure-red flower). Measured on the RAW-decoded frame, not the small
    preview — a JPEG preview can look blown while the RAW still has recoverable
    headroom, which matters for photographers shooting ETTR or deliberately
    underexposed. This only measures; it does not decide what counts as "too much" —
    evaluate.py calibrates that cutoff against your own labels.csv judgment instead
    of a guessed threshold.
    """
    max_channel = rgb_array.max(axis=2)
    min_channel = rgb_array.min(axis=2)
    total = rgb_array.shape[0] * rgb_array.shape[1]
    highlight_pct = float(np.count_nonzero(min_channel >= HIGHLIGHT_CLIP_VALUE)) / total
    shadow_pct = float(np.count_nonzero(max_channel <= SHADOW_CLIP_VALUE)) / total
    return highlight_pct, shadow_pct


def decode_for_sharpness(raw_path):
    """Half-size RGB decode for RAW files; direct read for already-rasterized images.

    rawpy/libraw auto-rotates RAW output per the embedded orientation by default
    (user_flip=-1), matching the preview. Plain JPEGs need the same exif_transpose
    applied to the preview in prepare.py, or the face bbox (computed on the
    correctly-oriented preview) lands in the wrong place on this sideways buffer.
    """
    suffix = Path(raw_path).suffix.lower()
    if suffix in RAW_EXTS:
        with rawpy.imread(str(raw_path)) as raw:
            rgb = raw.postprocess(half_size=True, no_auto_bright=True, output_bps=8, use_camera_wb=True)
        return rgb
    img = ImageOps.exif_transpose(Image.open(raw_path))
    return np.asarray(img.convert("RGB"))


def process_photo(landmarker, face_detector, photo):
    t0 = time.perf_counter()
    preview_img = Image.open(photo["preview_path"]).convert("RGB")

    phash = str(imagehash.phash(preview_img))
    bbox, eye_closed, blink_score = detect_face(landmarker, face_detector, preview_img)

    sharpness_img = decode_for_sharpness(photo["raw_path"])
    if bbox is not None:
        region = crop_bbox(sharpness_img, bbox)
        sharpness_scope = "face"
    else:
        region = sharpness_img
        sharpness_scope = "whole"

    if region.size == 0:
        region = sharpness_img
        sharpness_scope = "whole"

    gray = cv2.cvtColor(region, cv2.COLOR_RGB2GRAY)
    sharpness = laplacian_variance(gray)
    highlight_clip_pct, shadow_clip_pct = exposure_clipping(sharpness_img)

    elapsed = time.perf_counter() - t0
    return {
        "id": photo["id"],
        "phash": phash,
        "capture_time": photo["capture_time"],
        "face_found": bbox is not None,
        "eye_closed": eye_closed,
        "blink_score": blink_score,
        "sharpness": float(sharpness),
        "sharpness_scope": sharpness_scope,
        "highlight_clip_pct": highlight_clip_pct,
        "shadow_clip_pct": shadow_clip_pct,
        "elapsed_sec": elapsed,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="data/manifest.json")
    parser.add_argument("--out", default="data/layer1_results.json")
    parser.add_argument("--hash-threshold", type=int, default=10)
    parser.add_argument("--time-window", type=float, default=2.0)
    args = parser.parse_args()

    manifest = load_manifest(Path(args.manifest))
    photos = manifest["photos"]

    landmarker = build_landmarker()
    face_detector = build_face_detector()
    results = []
    for photo in tqdm(photos, desc="layer1"):
        try:
            results.append(process_photo(landmarker, face_detector, photo))
        except Exception as e:
            print(f"  [error] {photo['id']}: {e}")
            results.append({"id": photo["id"], "error": str(e)})
    landmarker.close()

    groups = group_bursts(
        [r for r in results if "error" not in r],
        hash_threshold=args.hash_threshold,
        time_window_sec=args.time_window,
    )
    for r in results:
        r["burst_group"] = groups.get(r["id"])

    save_manifest(
        {
            "hash_threshold": args.hash_threshold,
            "time_window_sec": args.time_window,
            "results": results,
        },
        Path(args.out),
    )

    ok = [r for r in results if "error" not in r]
    avg_time = sum(r["elapsed_sec"] for r in ok) / len(ok) if ok else 0
    n_groups = len(set(groups.values()))
    n_faces = sum(1 for r in ok if r["face_found"])
    n_closed = sum(1 for r in ok if r.get("eye_closed"))
    print(f"Done: {len(ok)} photos -> {n_groups} burst groups, {n_faces} with face, "
          f"{n_closed} flagged eye-closed. Avg {avg_time:.3f}s/photo. Wrote {args.out}")


if __name__ == "__main__":
    main()
