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


def make_pipeline(film, paper, scan_film, tone=TONE):
    """上游的 SimulationPipeline（Simulator 包的就是它）+ 消化过的参数。process() 能从中间的 tap 进出
    （inject / collect），2-LUT 的颗粒要用。"""
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.runtime.pipeline import SimulationPipeline

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
    return SimulationPipeline(dp), dp


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


def srgb_encode(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * x ** (1 / 2.4) - 0.055)


def bake(film, paper, scan_film, n=SIZE, tone=TONE):
    pipe, _ = make_pipeline(film, paper, scan_film, tone)
    out = np.asarray(pipe.process(pre_tone(srgb_decode(identity_grid(n)), tone)), dtype=np.float64)
    return np.clip(out.reshape(n, n, n, 3), 0.0, 1.0)


# ---------------------------------------------------------------- 颗粒、晕光要的数据

# 颗粒在胶片密度上加（上游也是：负片显影出 CMY 密度以后、印相纸之前）。app 拿不到 spektrafilm 的流水线，
# 就把它在 cmy_film 这个 tap 拆成两张表：film = sRGB → 密度，print = 密度 → 输出；颗粒 = print(密度 + 噪声)
# − print(密度)，加在一步到位的那张色调表的结果上（不加颗粒时和 phase 1 逐像素一样）。颗粒只用 print 表局部的
# 斜率，24³ 够（32³ 每款多 1.8 MB）。
SPLIT_SIZE = 24
# 密度两头各留的余量：噪声把密度推出观测范围时 cube 不夹断（上游 2-LUT 在雾度下面留 0.2）。
DENSITY_HEADROOM = 0.25


def bake_split(film, paper, scan_film, n=SPLIT_SIZE, tone=TONE):
    """film 表的值 = 归一化密度，按 sRGB 编码存（app 用 CIColorCubeWithColorSpace(sRGB) 读，工作空间里拿到的
    正好是归一化密度）；print 表的值 = 线性 sRGB（app 用不带色彩空间的 CIColorCube，按工作空间里的归一化密度
    直接查，查出来就是线性光）。返回 (film, print, d_lo, d_hi, dp)。"""
    pipe, dp = make_pipeline(film, paper, scan_film, tone)
    grid = pre_tone(srgb_decode(identity_grid(n)), tone)
    dens = np.asarray(pipe.process(grid, collect="cmy_film"), dtype=np.float64).reshape(n, n, n, 3)
    flat = dens.reshape(-1, 3)
    d_lo = flat.min(axis=0) - DENSITY_HEADROOM
    d_hi = flat.max(axis=0) + DENSITY_HEADROOM
    film_table = srgb_encode((dens - d_lo) / (d_hi - d_lo))
    phys = d_lo + identity_grid(n) * (d_hi - d_lo)
    out = np.asarray(pipe.process(phys, inject="cmy_film"), dtype=np.float64)
    print_table = srgb_decode(np.clip(out, 0.0, 1.0)).reshape(n, n, n, 3)
    return film_table, print_table, d_lo, d_hi, dp


def grain_sigma_unit(dp, d_lo, d_hi, samples=256):
    """每个通道：归一化密度 → 1 µm 边长的像素上颗粒的标准差（归一化单位）。照搬上游
    apply_grain_to_density_layers 的泊松-二项模型：一个子层里显影的颗粒数 ~ Binomial(Poisson(n/sat), p)，
    密度方差 = p·dmax²·sat/n（sat = 1 − p·u），三个子层独立相加；子层怎么分总密度用上游的
    interp_density_cmy_layers。n 和像素面积成正比，所以边长 s µm 的像素上标准差 = 这个值 / s。
    染料云模糊（1 µm）、微结构（30 nm）在拼图的像素尺寸（≥ 5 µm）下看不出来，不做；最后那一下 0.65 像素的
    模糊在 app 里做。"""
    from spektrafilm.model.density_curves import interp_density_cmy_layers

    g = dp.film_render.grain
    curves = np.asarray(dp.film.data.density_curves, dtype=np.float64)
    norm_curves = curves - np.nanmin(curves, axis=0)
    layer_curves = np.asarray(dp.film.data.density_curves_layers, dtype=np.float64)
    t = np.linspace(0.0, 1.0, samples)
    dens = np.clip(d_lo[None, :] + t[:, None] * (d_hi - d_lo)[None, :], 0.0, None)
    layers = interp_density_cmy_layers(dens[None, :, :], norm_curves, layer_curves,
                                       positive_film=dp.film.info.type == "positive")[0]  # (samples, 子层, 通道)
    dmax_layers = np.nanmax(layer_curves, axis=0)  # (子层, 通道)
    frac = dmax_layers / dmax_layers.sum(axis=0)[None, :]
    dmin_layers = frac * np.asarray(g.density_min)[None, :]
    dmax_eff = dmax_layers + dmin_layers
    area = g.particle_area_um2 * np.asarray(g.particle_scale)[None, :] * np.asarray(g.particle_scale_layers)[:, None]
    n_unit = frac / area  # 1 µm² 上的颗粒数
    p = np.clip((layers + dmin_layers[None]) / dmax_eff[None], 1e-6, 1 - 1e-6)
    sat = 1 - p * np.asarray(g.uniformity)[None, None, :]
    var = p * dmax_eff[None] ** 2 * sat / n_unit[None]
    return np.sqrt(var.sum(axis=1)) / (d_hi - d_lo)[None, :]  # (samples, 通道)


def check_grain(film, paper, scan_film, pixel_um=10.0, size=256):
    """解析的颗粒标准差 vs 上游真抽样（apply_grain_to_density_layers，模糊关掉）：几个密度上比一比。"""
    from spektrafilm.model.density_curves import interp_density_cmy_layers
    from spektrafilm.model.grain import apply_grain_to_density_layers

    _, _, d_lo, d_hi, dp = bake_split(film, paper, scan_film, n=9)
    sig = grain_sigma_unit(dp, d_lo, d_hi)
    g = dp.film_render.grain
    curves = np.asarray(dp.film.data.density_curves, dtype=np.float64)
    norm_curves = curves - np.nanmin(curves, axis=0)
    layer_curves = np.asarray(dp.film.data.density_curves_layers, dtype=np.float64)
    worst = 0.0
    for t in (0.2, 0.4, 0.6, 0.8):
        d = np.clip(d_lo + t * (d_hi - d_lo), 0, None)
        flat = np.ones((size, size, 3)) * d[None, None, :]
        layers = interp_density_cmy_layers(flat, norm_curves, layer_curves, positive_film=dp.film.info.type == "positive")
        out = apply_grain_to_density_layers(layers, np.nanmax(layer_curves, axis=0), pixel_size_um=pixel_um,
                                            particle_area_um2=g.particle_area_um2, particle_scale=g.particle_scale,
                                            particle_scale_layers=g.particle_scale_layers, density_min=g.density_min,
                                            grain_uniformity=g.uniformity, grain_blur=0.0,
                                            grain_blur_dye_clouds_um=0.0, grain_micro_structure=(0.0, 0.0))
        measured = out.reshape(-1, 3).std(axis=0)
        predicted = np.array([np.interp(t, np.linspace(0, 1, sig.shape[0]), sig[:, c]) for c in range(3)]) \
            * (d_hi - d_lo) / pixel_um
        ratio = measured / predicted
        worst = max(worst, float(np.max(np.abs(ratio - 1))))
        print(f"  t={t}  抽样 {measured.round(4)}  解析 {predicted.round(4)}  比 {ratio.round(3)}")
    return worst


def halation_params(dp):
    """晕光滑杆拉满 = 上游「没有防光晕层」那一档（_HALATION_PRESETS 的 (use, 'no')）：底片片基的反射，
    三次反弹、每次宽 √k 倍、强度减半。σ 按片基厚度（照相片 65 µm、电影片 50 µm）。"""
    from spektrafilm.runtime import params_builder as pb

    preset = pb._HALATION_PRESETS.get((dp.film.info.use, "no")) or pb._HALATION_PRESETS[("still", "no")]
    from spektrafilm.runtime.params_schema import HalationParams

    h = HalationParams()  # 反弹次数、衰减用上游默认（lut_mode 只清了 σ，这两个没动，但别依赖它）
    return {
        "sigma_um": float(preset["sigma_h"][0]),
        "strength_max": [float(v) for v in preset["strength"]],
        "bounces": int(h.halation_n_bounces),
        "bounce_decay": float(h.halation_bounce_decay),
    }


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


def write_data_cube(table, path, raw_value, version, what):
    n = table.shape[0]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f'TITLE "{raw_value} {what.split(":")[0]}"\n')
        fh.write(f"# 选片工具 拼图色调 {raw_value} {what}, {n}^3 (data for grain, not a look LUT)\n")
        fh.write(f"# Generated with spektrafilm {version} by Andrea Volpato - https://github.com/andreavolpato/spektrafilm\n")
        fh.write("# Licensed CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/), see SPEKTRAFILM_LICENSE.txt\n")
        fh.write(f"LUT_3D_SIZE {n}\n")
        fh.write("DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n")
        for bi in range(n):
            for gi in range(n):
                for ri in range(n):
                    r, g, b = table[bi, gi, ri]
                    fh.write(f"{r:.6f} {g:.6f} {b:.6f}\n")


def write_all(out_dir):
    import json

    from spektrafilm.runtime.params_schema import GrainParams

    os.makedirs(out_dir, exist_ok=True)
    version = spektrafilm_version()
    for raw, film, paper, scan in LOOKS:
        table = bake(film, paper, scan)
        write_cube(table, os.path.join(out_dir, f"{raw}.cube"), raw, version)
        film_t, print_t, d_lo, d_hi, dp = bake_split(film, paper, scan)
        write_data_cube(film_t, os.path.join(out_dir, f"{raw}.film.cube"), raw, version,
                        "film: sRGB gamma-encoded in -> normalized film CMY density, stored sRGB-encoded")
        write_data_cube(print_t, os.path.join(out_dir, f"{raw}.print.cube"), raw, version,
                        "print: normalized film CMY density in -> linear sRGB out")
        sigma = grain_sigma_unit(dp, d_lo, d_hi)
        meta = {
            "look": raw,
            "spektrafilm": version,
            "license": "CC BY-SA 4.0, Andrea Volpato, https://github.com/andreavolpato/spektrafilm",
            "split_size": SPLIT_SIZE,
            "d_lo": [round(float(v), 6) for v in d_lo],
            "d_hi": [round(float(v), 6) for v in d_hi],
            "film_format_mm": float(dp.camera.film_format_mm),
            # lut_mode 把 grain.blur 清成 0 了（空间效果全关），这里要的是上游默认那 0.65 像素。
            "grain_blur_px": float(GrainParams().blur),
            "grain_sigma_unit": [[round(float(v), 7) for v in sigma[:, c]] for c in range(3)],
            "halation": halation_params(dp),
        }
        with open(os.path.join(out_dir, f"{raw}.json"), "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
            fh.write("\n")
        # 两半合起来应该就是一步到位那张表（只差两次插值）。
        chained = apply_trilinear(srgb_decode(apply_trilinear(identity_grid(SIZE).reshape(-1, 3), film_t)), print_t)
        err = np.abs(srgb_encode(chained) - table.reshape(-1, 3)).max()
        print(f"{raw}.cube  白 {table[-1, -1, -1].round(3)}  黑 {table[0, 0, 0].round(3)}"
              f"  film∘print 和一步到位最大差 {err:.4f}")
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
            "  - renamed with generic look names (file name = look id in the app);\n"
            f"  - <look>.film.cube / <look>.print.cube: the same chain split at the film density\n"
            f"    (spektrafilm's cmy_film tap) into two {SPLIT_SIZE}^3 tables, so the app can add grain\n"
            "    between them; <look>.json: the density range of that split, the per-channel grain\n"
            "    standard deviation derived from spektrafilm's grain model, and its halation preset.\n"
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
    ap.add_argument("--check-grain", action="store_true", help="解析的颗粒标准差对上游真抽样")
    args = ap.parse_args()
    if args.check_grain:
        worst = 0.0
        for raw, film, paper, scan in LOOKS:
            print(raw)
            worst = max(worst, check_grain(film, paper, scan))
        print(f"最大相对差 {worst:.3f}")
    elif args.explore:
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
