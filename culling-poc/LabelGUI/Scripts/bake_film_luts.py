#!/usr/bin/env python3
"""把 spektrafilm 的「胶片 × 相纸」烘成拼图色调用的 32³ LUT（sRGB 伽马进 → sRGB 伽马出）。

spektrafilm（Andrea Volpato，https://github.com/andreavolpato/spektrafilm）是光谱级的胶片 + 相纸模拟，
代码 GPL-3.0，胶片 / 相纸数据和由它们生成的 LUT 是 CC BY-SA 4.0。这里只烘逐像素的那一半（上游的
debug.lut_mode：光谱上采样、负片曲线、DIR 层间抑制、放大机、相纸、扫描、输出色域压缩），颗粒、晕光、
DIR 扩散这些空间 / 随机效果不在表里。中灰曝光固定为原样（sRGB 码值 0.46 ≈ 线性 0.184 的中灰），不加上游给
编码 SDR 默认的 4 档余量（那张表不配预增益会整体亮 1.5 档），只在中灰两侧按 TONE 收一收暗部、推一推高光
（见下面 TONE 的注释）；我们自己先反伽马、io.input_cctf_decoding=False
（让 spektrafilm 自己反伽马时，自动曝光的增益会乘在伽马值上，见 reports/胶片模拟调研_2026-11-05 R6 §2.4）。

产物写进 third_party/film-luts/：每个色调一个 <rawValue>.cube（文件头带署名和许可），外加
SPEKTRAFILM_LICENSE.txt（上游原文）和 CHANGELOG.txt（CC BY-SA 要求注明改了什么）。色调名、文件名都是
通用词：片种只在下面 LOOKS 表里对得上上游的 profile 文件名，不进界面（商标红线，见 CollageModel.swift
CollageLook 的注释）。

无头运行（不装 Qt / napari，不碰 spektrafilm 的 GUI 入口）：
    uv venv --python 3.13 <venv>
    uv pip install --python <venv>/bin/python numpy scipy colour-science scikit-image matplotlib opt-einsum \
        numba OpenImageIO pyfftw rawpy "exiv2~=0.18.1" "lensfunpy~=1.18.0" Pillow markdown
    uv pip install --python <venv>/bin/python --no-deps <spektrafilm 源码目录>
    QT_QPA_PLATFORM=offscreen MPLBACKEND=Agg <venv>/bin/python -I Scripts/bake_film_luts.py \
        --out ../../third_party/film-luts
    # 挑片：每款胶片套在几张样片上拼一张总览（不写 LUT）
    ... bake_film_luts.py --explore <样片目录> <总览.jpg>
"""
from __future__ import annotations

import argparse
import datetime
import os
import shutil
import sys

os.environ.setdefault("MPLBACKEND", "Agg")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
import matplotlib  # noqa: E402

matplotlib.use("Agg", force=True)

import numpy as np  # noqa: E402

SIZE = 32  # 和 CollageLooks.cubeSize 一样：格点就是 cube() 取样的点，不用再插值

# rawValue → 上游 profile。scan_film = 反转片直接扫（不印相纸，印了影调会反过来）。
# 顺序 = CollageLook 里新 case 的顺序。
LOOKS = [
    ("filmSoftSkin", "kodak_portra_160", "kodak_portra_endura", False),
    ("filmWarmSkin", "kodak_portra_400", "kodak_portra_endura", False),
    ("filmRich", "kodak_ektar_100", "kodak_portra_endura", False),
    ("filmSunny", "kodak_gold_200", "kodak_portra_endura", False),
    ("filmFresh", "fujifilm_c200", "fujifilm_crystal_archive_typeii", False),
    ("filmPastel", "fujifilm_pro_400h", "fujifilm_crystal_archive_typeii", False),
    ("slideVivid", "fujifilm_velvia_100", "kodak_portra_endura", True),
    ("slideClean", "fujifilm_provia_100f", "kodak_portra_endura", True),
    ("slideVintage", "kodak_kodachrome_64", "kodak_portra_endura", True),
    ("cineDay", "kodak_vision3_250d", "kodak_2383", False),
]

_FORBIDDEN = ("napari", "PySide6", "PyQt5", "PyQt6", "qtpy", "spektrafilm_gui", "tkinter")


def assert_headless():
    bad = sorted({m.split(".")[0] for m in sys.modules if m.split(".")[0] in _FORBIDDEN})
    if bad:
        raise SystemExit(f"不该出现的 GUI 模块被 import 了：{bad}")


def srgb_decode(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


# 喂给胶片之前、出相纸之后的两处调整（都和图像内容无关，烘得进表）：
#   shadow / highlight：在 log2(线性 / 中灰 0.184) 上分段乘的系数。成片 JPEG 已经过相机的 S 曲线，再叠
#     胶片 + 相纸的 S 曲线，暗部压死、白发灰；shadow < 1 把暗部往中灰收（提一点），highlight > 1 把高光往外推，
#     让 sRGB 的白落到相纸的肩上、而不是肩前。
#   wb：扫描的白点 / 黑点校正（上游 scanner.white_correction / black_correction，只看片种参考密度）。
# 0.8 / 1.5 是拿 photot 的晴天外景挑的（reports/胶片模拟调研_2026-11-05）：原样（1 / 1 / 关）暗部的木梁压成死黑、
# 白只到 0.82；这一档暗部留得住层次，白到 0.88 上下（相纸白本来就到不了 1），中灰基本不动。
TONE = dict(shadow=0.8, highlight=1.5, wb=True)


def make_simulator(film, paper, scan_film, tone=TONE):
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.runtime.process import Simulator

    p = init_params(film_profile=film, print_profile=paper)
    p.io.input_color_space = "sRGB"
    p.io.input_cctf_decoding = False
    p.io.output_color_space = "sRGB"
    p.io.output_cctf_encoding = True
    p.io.scan_film = scan_film
    p.debug.lut_mode = True
    dp = digest_params(p)
    if tone["wb"]:
        dp.scanner.white_correction = True
        dp.scanner.black_correction = True
    return Simulator(dp)


def pre_tone(lin, tone=TONE):
    """线性光 → 喂给胶片的线性光：log2(x / 0.184) 暗部乘 shadow、亮部乘 highlight。0 还是 0。"""
    mid = 0.184
    x = np.log2(np.maximum(lin, 1e-6) / mid)
    x = np.where(x < 0, x * tone["shadow"], x * tone["highlight"])
    return np.where(lin <= 0, 0.0, mid * np.exp2(x))


def identity_grid(n):
    """(n*n, n, 3)：展平后 R 变得最快、B 最慢（.cube 和 CIColorCube 的顺序）。"""
    v = np.linspace(0.0, 1.0, n)
    b, g, r = np.meshgrid(v, v, v, indexing="ij")
    return np.stack([r, g, b], axis=-1).reshape(n * n, n, 3)


def bake(film, paper, scan_film, n=SIZE, tone=TONE):
    sim = make_simulator(film, paper, scan_film, tone)
    out = np.asarray(sim.process(pre_tone(srgb_decode(identity_grid(n)), tone)), dtype=np.float64)
    return np.clip(out.reshape(n, n, n, 3), 0.0, 1.0)


def apply_trilinear(img, table):
    n = table.shape[0]
    x = np.clip(img, 0, 1) * (n - 1)
    i0 = np.clip(np.floor(x).astype(np.int64), 0, n - 2)
    f = x - i0
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]
    fr, fg, fb = f[..., 0:1], f[..., 1:2], f[..., 2:3]
    out = np.zeros(img.shape, dtype=np.float64)
    for db, wb in ((0, 1 - fb), (1, fb)):
        for dg, wg in ((0, 1 - fg), (1, fg)):
            for dr, wr in ((0, 1 - fr), (1, fr)):
                out += wb * wg * wr * table[b0 + db, g0 + dg, r0 + dr]
    return out


def spektrafilm_version():
    try:
        from importlib.metadata import version

        return version("spektrafilm")
    except Exception:
        return "unknown"


def write_cube(table, path, raw_value, version):
    n = table.shape[0]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f'TITLE "{raw_value}"\n')
        fh.write(f"# 选片工具 拼图色调 {raw_value}: sRGB gamma-encoded in -> sRGB gamma-encoded out, {n}^3\n")
        fh.write(f"# Generated with spektrafilm {version} by Andrea Volpato - https://github.com/andreavolpato/spektrafilm\n")
        fh.write("# Licensed CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/), see SPEKTRAFILM_LICENSE.txt\n")
        fh.write("# Modified: per-pixel part only (no grain / halation / diffusion), fixed exposure, see CHANGELOG.txt\n")
        fh.write(f"LUT_3D_SIZE {n}\n")
        fh.write("DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n")
        for bi in range(n):
            for gi in range(n):
                for ri in range(n):
                    r, g, b = table[bi, gi, ri]
                    fh.write(f"{r:.6f} {g:.6f} {b:.6f}\n")


def upstream_license_path():
    import spektrafilm

    here = os.path.dirname(spektrafilm.__file__)
    for cand in (os.path.join(here, "data", "license", "SPEKTRAFILM_LICENSE.txt"),
                 os.path.join(here, "..", "..", "SPEKTRAFILM_LICENSE.txt")):
        if os.path.exists(cand):
            return os.path.abspath(cand)
    raise SystemExit("找不到 spektrafilm 自带的 SPEKTRAFILM_LICENSE.txt")


def write_all(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    version = spektrafilm_version()
    for raw, film, paper, scan in LOOKS:
        table = bake(film, paper, scan)
        write_cube(table, os.path.join(out_dir, f"{raw}.cube"), raw, version)
        print(f"{raw}.cube  白 {table[-1, -1, -1].round(3)}  黑 {table[0, 0, 0].round(3)}")
    shutil.copyfile(upstream_license_path(), os.path.join(out_dir, "SPEKTRAFILM_LICENSE.txt"))
    today = datetime.date.today().isoformat()
    with open(os.path.join(out_dir, "CHANGELOG.txt"), "w", encoding="utf-8") as fh:
        fh.write(
            "Changes to the spektrafilm material in this folder (CC BY-SA 4.0)\n"
            "=================================================================\n\n"
            f"{today}  选片工具 (https://github.com/Ly-star-bit/photo_culling)\n"
            f"  Each .cube here was generated with spektrafilm {version} (Andrea Volpato,\n"
            "  https://github.com/andreavolpato/spektrafilm) from one film profile and one print\n"
            "  profile (reversal films scanned directly). Changes from a full spektrafilm render:\n"
            f"  - baked as a {SIZE}^3 3D LUT, sRGB gamma-encoded input and output;\n"
            "  - per-pixel part only (spektrafilm debug.lut_mode): no grain, halation, coupler\n"
            "    diffusion, glare, blur or sharpening; auto exposure off;\n"
            "  - exposure fixed at mid gray (no auto exposure); before the film, log2 exposure\n"
            f"    around mid gray is scaled by {TONE['shadow']} below and {TONE['highlight']} above (an\n"
            "    inverse of the camera tone curve already in the photo); scanner white / black\n"
            "    point correction on;\n"
            "  - renamed with generic look names (file name = look id in the app).\n"
            "  The app blends each table toward the original with its strength slider at run time.\n"
            "  Script: culling-poc/LabelGUI/Scripts/bake_film_luts.py\n"
        )
    print(f"写好 {len(LOOKS)} 张 LUT + SPEKTRAFILM_LICENSE.txt + CHANGELOG.txt → {out_dir}")


def explore(sample_dir, out_path, combos, per_sheet=5, th=300):
    """每款组合套在样片上拼成总览，每张 per_sheet 行，第一行都是原图。只看，不写 LUT。
    out_path 是 x.jpg 时写 x_1.jpg、x_2.jpg……"""
    from PIL import Image, ImageDraw, ImageFont, ImageOps

    files = sorted(f for f in os.listdir(sample_dir) if f.lower().endswith((".jpg", ".jpeg", ".png")))
    thumbs = []
    for f in files:
        pil = ImageOps.exif_transpose(Image.open(os.path.join(sample_dir, f))).convert("RGB")
        pil = pil.resize((int(pil.width * th / pil.height), th), Image.LANCZOS)
        thumbs.append(np.asarray(pil).astype(np.float64) / 255)
    rows = []
    for name, film, paper, scan in combos:
        table = bake(film, paper, scan, n=33)
        rows.append((name, [apply_trilinear(t, table) for t in thumbs]))
        print("  ", name)
    font = ImageFont.load_default(size=22)
    stem, ext = os.path.splitext(out_path)
    width = sum(t.shape[1] for t in thumbs) + 6 * len(thumbs)
    row_h = th + 34
    for si in range(0, len(rows), per_sheet):
        chunk = [("original", thumbs)] + rows[si:si + per_sheet]
        sheet = Image.new("RGB", (width, row_h * len(chunk)), (40, 40, 40))
        draw = ImageDraw.Draw(sheet)
        for ri, (name, row) in enumerate(chunk):
            y = ri * row_h
            draw.text((8, y + 4), name, fill=(235, 235, 235), font=font)
            x = 0
            for t in row:
                sheet.paste(Image.fromarray((np.clip(t, 0, 1) * 255).round().astype(np.uint8)), (x, y + 32))
                x += t.shape[1] + 6
        path = f"{stem}_{si // per_sheet + 1}{ext}"
        sheet.save(path, quality=90)
        print("总览 →", path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="写 LUT 的目录（third_party/film-luts）")
    ap.add_argument("--explore", nargs=2, metavar=("SAMPLES", "SHEET"), help="挑片总览，不写 LUT")
    ap.add_argument("--all-films", action="store_true", help="--explore 时把上游所有拍摄用胶片都排上")
    args = ap.parse_args()
    if args.explore:
        combos = [(f"{raw} ({film}/{paper})", film, paper, scan) for raw, film, paper, scan in LOOKS]
        if args.all_films:
            combos = all_film_combos()
        explore(args.explore[0], args.explore[1], combos)
    elif args.out:
        write_all(args.out)
    else:
        ap.error("要 --out 或 --explore")
    assert_headless()


def all_film_combos():
    import json

    import spektrafilm

    pdir = os.path.join(os.path.dirname(spektrafilm.__file__), "data", "profiles")
    out = []
    for f in sorted(os.listdir(pdir)):
        if not f.endswith(".json"):
            continue
        with open(os.path.join(pdir, f), encoding="utf-8") as fh:
            info = json.load(fh).get("info", {})
        if info.get("stage") != "filming":
            continue
        stock = f[:-5]
        positive = info.get("type") == "positive"
        paper = info.get("target_print") or "kodak_portra_endura"
        out.append((f"{stock} / {'直扫' if positive else paper}", stock, paper, positive))
    return out


if __name__ == "__main__":
    main()
