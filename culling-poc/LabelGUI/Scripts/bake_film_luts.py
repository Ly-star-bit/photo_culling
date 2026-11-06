#!/usr/bin/env python3
"""把 spektrafilm 的「胶片 × 相纸」烘成拼图色调用的 32³ LUT（sRGB 伽马进 → sRGB 伽马出）。

spektrafilm（Andrea Volpato，https://github.com/andreavolpato/spektrafilm）是光谱级的胶片 + 相纸模拟，
代码 GPL-3.0，胶片 / 相纸数据和由它们生成的 LUT 是 CC BY-SA 4.0。这里只烘逐像素的那一半（上游的
debug.lut_mode：光谱上采样、负片曲线、DIR 层间抑制、放大机、相纸、扫描、输出色域压缩），颗粒、晕光、
DIR 扩散这些空间 / 随机效果不在表里。中灰曝光固定为原样（sRGB 码值 0.46 ≈ 线性 0.184 的中灰），不加上游给
编码 SDR 默认的 4 档余量（那张表不配预增益会整体亮 1.5 档），只在中灰两侧按 TONE 收一收暗部、推一推高光
（见下面 TONE 的注释）；我们自己先反伽马、io.input_cctf_decoding=False
（让 spektrafilm 自己反伽马时，自动曝光的增益会乘在伽马值上，见 reports/胶片模拟调研_2026-11-05 R6 §2.4）。

2026-11-05 第二版（用户嫌「太黄、不够胶片味」，对标「柯达 400」的冲扫店扫描，调研见 reports/胶片模拟调研_2026-11-05/R8）：
每款按 RECIPES 调暗房参数（相纸反差、DIR 层间抑制、扫描黑位、放大机滤色），再过一层只看输出色的扫描校正
（scan_correct：白点、黑位、暗冷亮暖、肤色 / 草绿 / 天蓝、饱和）。扫描校正同样套在颗粒用的 print 表上，颗粒和
底色对得上。--check-rules 按 R8 §2.1 的 G1–G6 逐款量（高光灰、暖往橙、肤色色相、白、暗部、天空）。
注意：上游的预闪（enlarger.preflash_exposure）给负片相纸整体加曝光，会把相纸的白也压灰，不能拿来抬黑位；
黑位用 scanner.black_level，白点交给扫描校正。

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
    # 逐款量「不脏」规则（不写 LUT）
    ... bake_film_luts.py --check-rules
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
    ("filmSunny", "kodak_ultramax_400", "kodak_portra_endura", False),
    ("filmFresh", "fujifilm_c200", "fujifilm_crystal_archive_typeii", False),
    ("filmPastel", "fujifilm_pro_400h", "fujifilm_crystal_archive_typeii", False),
    ("slideVivid", "fujifilm_velvia_100", "kodak_portra_endura", True),
    ("slideClean", "fujifilm_provia_100f", "kodak_portra_endura", True),
    ("slideVintage", "kodak_kodachrome_64", "kodak_portra_endura", True),
    ("cineDay", "kodak_vision3_250d", "kodak_2383", False),
    # 第二批（2026-11-05，用户在样张上挑的）
    ("filmAmber", "kodak_gold_200", "kodak_portra_endura", False),
    ("filmPushed", "kodak_portra_800_push2", "kodak_portra_endura", False),
    ("filmEveryday", "fujifilm_xtra_400", "fujifilm_crystal_archive_typeii", False),
    ("slideCool", "kodak_ektachrome_100", "kodak_portra_endura", True),
    ("cineTungsten", "kodak_vision3_500t", "kodak_2383", False),
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

# 每款的暗房 / 扫描配方（R8 §2.2 的目标；暖肤是用户 2026-11-05 在样张上选定的分寸，其余照它调）。
#   物理（喂给 spektrafilm）：gamma 相纸反差（print_render.density_curves_morph.gamma_factor）、dir DIR 层间抑制倍数
#     （上游默认偏强，色发「酸」、过饱和）、black 扫描黑位（scanner.black_level）、yf / mf 放大机黄 / 品滤色偏移
#     （Kodak CC；负 = 印出来更黄 / 更品）、highlight 喂片前的高光系数（覆盖 TONE）。反转片直扫，没有相纸和放大机。
#   scan：扫描校正（scan_correct 的参数），只看表的输出色。
#   defaults：app 里从「没有光谱色调」换进这一款时颗粒 / 晕光的起始值（滑杆刻度；晕光滑杆是平方刻度，0.2 ≈ 防光晕层
#     strong 的真片，0.5 ≈ weak）。
#   cap：--check-rules 的放宽（暖阳、怀旧高光和暗部可以更暖，银幕的白可以低一点）。
_NEG = dict(black=0.04, gamma=0.65, dir=0.6)
RECIPES = {
    "filmSoftSkin": dict(phys=dict(_NEG, black=0.035, gamma=0.55, yf=-2),
                         scan=dict(white=95.5, all=(0.8, 1.5), hi=(0, 1.5), sh=(0, -1.5), skin=(0.75, 46, 1.15),
                                   skinband=(35, 70), green=(3, 1.4), blue=(12, 1.0)),
                         defaults=dict(grain=0.35, halation=0.2)),
    "filmWarmSkin": dict(phys=dict(_NEG, yf=-3),
                         scan=dict(white=95, hi=(1, 3), sh=(-1, -3), skin=(0.5, 50, 1.15), green=(0, 1.2),
                                   blue=(8, 1.05), sat=1.05),
                         defaults=dict(grain=0.6, halation=0.2)),
    "filmRich": dict(phys=dict(_NEG, black=0.02, gamma=0.68, dir=0.8, yf=-3, mf=-0.5),
                     scan=dict(white=95.5, hi=(0, 1), sh=(0, 0.5), skin=(0.85, 50, 0.85), green=(3, 1.1),
                               blue=(17, 1.15), sat=1.12),
                     defaults=dict(grain=0.25, halation=0.2)),
    "filmSunny": dict(phys=dict(_NEG, black=0.05, gamma=0.66, dir=0.65, yf=-5),
                      scan=dict(white=94.5, all=(1.8, 2), hi=(0.3, 3.5), sh=(0, -4), skin=(0.8, 52, 1.05),
                                skinband=(35, 70), green=(-7, 1.1), blue=(8, 1.1), sat=1.12),
                      defaults=dict(grain=0.65, halation=0.4), cap=dict(hi_b=7, sh_b=3, skin_dh=3)),
    "filmFresh": dict(phys=dict(_NEG, black=0.05, gamma=0.5),
                      scan=dict(white=95.5, hi=(1.3, -2.5), sh=(0.5, -3), skin=(0.7, 47, 1.25), green=(8, 1.3),
                                blue=(8, 1.0), sat=0.97),
                      defaults=dict(grain=0.5, halation=0.35)),
    "filmPastel": dict(phys=dict(_NEG, black=0.11, gamma=0.5, dir=0.5, yf=-1, mf=-2),
                       scan=dict(white=96.5, hi=(0, -1), sh=(1.8, -3), skin=(0.7, 46, 1.4), green=(8, 1.35),
                                 blue=(8, 1.05), sat=0.9),
                       defaults=dict(grain=0.4, halation=0.2)),
    "slideVivid": dict(phys=dict(dir=0.6, highlight=1.2),
                       scan=dict(contrast=0.75, white=95.5, black=3, rot=(40, 105, -20), skin=(0.5, 52, 0.9),
                                 blue=(5, 1.05), sat=1.1),
                       defaults=dict(grain=0.2, halation=0.2)),
    "slideClean": dict(phys=dict(dir=0.6, highlight=1.2),
                       scan=dict(contrast=0.7, white=96, black=4, sh=(-1.3, 0.9), rot=(40, 105, -16),
                                 skin=(0.4, 52, 1.05), green=(0, 1.1), blue=(15, 1.1), sat=1.05),
                       defaults=dict(grain=0.2, halation=0.2)),
    "slideVintage": dict(phys=dict(dir=0.6, highlight=1.2),
                         scan=dict(contrast=0.85, white=94.5, black=4.5, hi=(2.6, -1), sh=(0, -2), skin=(0.6, 52, 1.0),
                                   green=(-5, 0.9), blue=(25, 1.0)),
                         defaults=dict(grain=0.3, halation=0.45), cap=dict(hi_b=7, sh_b=3)),
    "cineDay": dict(phys=dict(_NEG, black=0.03, gamma=0.8, dir=0.7, yf=-2),
                    scan=dict(white=93, hi=(2, -3.2), sh=(1.5, -3), rot=(40, 105, -4), skin=(0.7, 50, 1.1),
                              green=(12, 1.0), blue=(12, 1.0), sat=0.95),
                    defaults=dict(grain=0.4, halation=0.3), cap=dict(white=92)),
    # 第二批
    "filmAmber": dict(phys=dict(_NEG, black=0.05, gamma=0.66, dir=0.65, yf=-6),
                       scan=dict(white=94.5, all=(1.5, 1.5), hi=(0.5, 3), sh=(0, -5.5), skin=(0.75, 54, 1.05),
                                 skinband=(35, 70), green=(-9, 1.05), blue=(8, 1.05), sat=1.1),
                       defaults=dict(grain=0.6, halation=0.45), cap=dict(hi_b=7.5, sh_b=3, skin_dh=3)),
    "filmPushed": dict(phys=dict(_NEG, black=0.03, gamma=0.62, dir=0.65, yf=-3),
                       scan=dict(white=95, hi=(1, 3), sh=(-1, -3), skin=(0.75, 50, 1.0), green=(0, 1.1),
                                 blue=(8, 1.1), sat=1.08),
                       defaults=dict(grain=0.75, halation=0.25)),
    "filmEveryday": dict(phys=dict(_NEG, black=0.05, gamma=0.58),
                         scan=dict(white=95.5, hi=(0.5, 0), sh=(-1.5, -2), skin=(0.7, 48, 1.15), green=(5, 1.25),
                                   blue=(6, 1.05), sat=1.03),
                         defaults=dict(grain=0.6, halation=0.35)),
    "slideCool": dict(phys=dict(dir=0.6, highlight=1.2),
                      scan=dict(contrast=0.72, white=96, black=3.5, all=(0, -1.5), hi=(-0.5, -1.5), sh=(-1, -3),
                                rot=(40, 105, -15), skin=(0.5, 50, 1.0), blue=(5, 1.1), sat=1.05),
                      defaults=dict(grain=0.2, halation=0.2)),
    "cineTungsten": dict(phys=dict(_NEG, black=0.03, gamma=0.8, dir=0.7),
                         scan=dict(white=93, all=(-0.5, -5), hi=(1, -2), sh=(0, -3), skin=(0.95, 50, 1.05),
                                   skinband=(35, 72), green=(10, 1.0), blue=(8, 1.05), sat=0.95),
                         defaults=dict(grain=0.6, halation=0.35), cap=dict(white=92)),
}


def make_pipeline(film, paper, scan_film, tone=TONE, phys=None):
    """上游的 SimulationPipeline（Simulator 包的就是它）+ 消化过的参数。process() 能从中间的 tap 进出
    （inject / collect），2-LUT 的颗粒要用。phys：RECIPES 里的物理参数（None = 上游默认，--explore 用）。"""
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.runtime.pipeline import SimulationPipeline
    from spektrafilm.utils.morph_curves import PrintCurvesMorphParams

    phys = phys or {}
    p = init_params(film_profile=film, print_profile=paper)
    p.io.input_color_space = "sRGB"
    p.io.input_cctf_decoding = False
    p.io.output_color_space = "sRGB"
    p.io.output_cctf_encoding = True
    p.io.scan_film = scan_film
    p.debug.lut_mode = True
    if "gamma" in phys:
        p.print_render.density_curves_morph = PrintCurvesMorphParams(active=True, gamma_factor=phys["gamma"])
    if "dir" in phys:
        p.film_render.dir_couplers.amount = phys["dir"]
    if "yf" in phys:
        p.enlarger.y_filter_shift = phys["yf"]
    if "mf" in phys:
        p.enlarger.m_filter_shift = phys["mf"]
    dp = digest_params(p)
    if tone["wb"]:
        dp.scanner.white_correction = True
        dp.scanner.black_correction = True
    if "black" in phys:
        dp.scanner.black_level = phys["black"]
    return SimulationPipeline(dp), dp


def look_tone(raw):
    """这一款喂片前的影调：TONE，配方里给了 highlight 就换掉（反转片直扫，高光推少一点）。"""
    phys = RECIPES[raw]["phys"]
    return dict(TONE, highlight=phys.get("highlight", TONE["highlight"]))


# ---------------------------------------------------------------- 扫描校正（只看输出色）

_M = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
_MI = np.linalg.inv(_M)
_W = _M @ np.ones(3)


def to_lab(rgb):
    """sRGB 伽马值 → CIELAB（D65）。"""
    xyz = srgb_decode(rgb) @ _M.T / _W
    f = np.where(xyz > 0.008856, np.cbrt(np.maximum(xyz, 0)), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def from_lab(lab):
    fy = (lab[..., 0] + 16) / 116
    f = np.stack([fy + lab[..., 1] / 500, fy, fy - lab[..., 2] / 200], -1)
    xyz = np.where(f > 0.206893, f ** 3, (f - 16 / 116) / 7.787) * _W
    return srgb_encode(xyz @ _MI.T)


def _band(h, lo, hi, soft=12.0):
    """色相 h（度）在 [lo, hi] 里是 1，两边 soft 度里平滑降到 0。"""
    half = (hi - lo) / 2
    d = np.abs(((h - (lo + hi) / 2 + 180) % 360) - 180)
    t = np.clip((half + soft - d) / soft, 0, 1)
    return t * t * (3 - 2 * t)


def scan_correct(y, o, L0, L1):
    """扫描校正：sRGB → sRGB，只看输入的这个颜色（不看原图），所以同一个函数既能改色调表、也能改 print 表。
    L0 / L1 = 这一款表本身的黑 / 白 L*（烘的时候量一次，两张表用同一组）。o 的键（都可省）：
      contrast      中灰（L*≈49）附近的反差倍数，先整体压，再把黑白点按 white / black 钉回去
      white / black 白点 / 黑位的目标 L*，修正量往中灰平方渐弱
      all / hi / sh 近中性色整体 / 高光 / 暗部加的 (a*, b*)：暗冷亮暖；往橙暖要 a、b 一起给（只给 b 是黄绿，发脏）
      rot           (lo, hi, 度)：色相落在 [lo, hi] 的整段转一个固定角度（反转片把暖色整段往黄转了，转回来）
      skin          (比例, 目标色相°, 彩度倍数)：肤色带（skinband，默认 35–66°）往目标色相转。皮肤 C*≈20–30、色相≈55°，
                    米色石头、木头 C*≈10–14、色相≈75°：按色相和彩度一起卡，别把石头拉成粉的
      green / blue  (色相偏移°, 彩度倍数)：草绿（100–160°）/ 天蓝（220–290°）
      sat           整体彩度倍数（> 1 时压一点亮度：饱和色变深不变亮）"""
    lab = to_lab(y)
    L = lab[..., 0]
    mid = 49.0
    if "contrast" in o:
        c = o["contrast"]
        L, L0, L1 = mid + (L - mid) * c, mid + (L0 - mid) * c, mid + (L1 - mid) * c
    if "white" in o:
        L = L + (o["white"] - L1) * np.clip((L - mid) / max(L1 - mid, 1e-3), 0, 1) ** 2
    if "black" in o:
        L = L + (o["black"] - L0) * np.clip((mid - L) / max(mid - L0, 1e-3), 0, 1) ** 2
    a, b = lab[..., 1], lab[..., 2]
    neutral = 1 / (1 + (np.hypot(a, b) / 18) ** 2)  # 越接近灰加得越满
    if "all" in o:
        a, b = a + o["all"][0] * neutral, b + o["all"][1] * neutral
    if "hi" in o:
        w = np.clip((L - 55) / 40, 0, 1) * neutral
        a, b = a + o["hi"][0] * w, b + o["hi"][1] * w
    if "sh" in o:
        w = np.clip((50 - L) / 40, 0, 1) * neutral
        a, b = a + o["sh"][0] * w, b + o["sh"][1] * w
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360
    vivid = np.clip(C / 12, 0, 1)  # 灰不算肤色 / 草绿 / 天蓝
    if "rot" in o:
        lo, hi, deg = o["rot"]
        h = h + deg * _band(h, lo, hi) * np.clip((C - 3) / 6, 0, 1)
    if "skin" in o:
        k, target, cm = o["skin"]
        lo, hi = o.get("skinband", (35, 66))
        w = _band(h, lo, hi, soft=7) * np.clip((C - 10) / 8, 0, 1)
        h = h + (((target - h + 180) % 360) - 180) * k * w
        C = C * (1 + (cm - 1) * w)
    for key, lo, hi in (("green", 100, 160), ("blue", 220, 290)):
        if key in o:
            dh, cm = o[key]
            w = _band(h, lo, hi) * vivid
            h, C = h + dh * w, C * (1 + (cm - 1) * w)
    if "sat" in o:
        C2 = C * o["sat"]
        if o["sat"] > 1:
            L = L - (C2 - C) * 0.25 * vivid
        C = C2
    out = np.stack([L, C * np.cos(np.radians(h)), C * np.sin(np.radians(h))], -1)
    return np.clip(from_lab(out), 0.0, 1.0)


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


def bake(film, paper, scan_film, n=SIZE, tone=TONE, phys=None):
    """只有 spektrafilm 那一段（不含扫描校正）。"""
    pipe, _ = make_pipeline(film, paper, scan_film, tone, phys)
    out = np.asarray(pipe.process(pre_tone(srgb_decode(identity_grid(n)), tone)), dtype=np.float64)
    return np.clip(out.reshape(n, n, n, 3), 0.0, 1.0)


def bake_look(raw, film, paper, scan_film, n=SIZE):
    """一款色调的成表：spektrafilm（按配方）→ 扫描校正。返回 (表, 扫描校正函数)；校正函数也要套在 print 表上。"""
    r = RECIPES[raw]
    raw_table = bake(film, paper, scan_film, n, look_tone(raw), r["phys"])
    L0 = float(to_lab(raw_table[0, 0, 0])[0])
    L1 = float(to_lab(raw_table[-1, -1, -1])[0])

    def correct(y):
        return scan_correct(y, r["scan"], L0, L1)

    return correct(raw_table), correct


# ---------------------------------------------------------------- 颗粒、晕光要的数据

# 颗粒在胶片密度上加（上游也是：负片显影出 CMY 密度以后、印相纸之前）。app 拿不到 spektrafilm 的流水线，
# 就把它在 cmy_film 这个 tap 拆成两张表：film = sRGB → 密度，print = 密度 → 输出；颗粒 = print(密度 + 噪声)
# − print(密度)，加在一步到位的那张色调表的结果上（不加颗粒时和 phase 1 逐像素一样）。颗粒只用 print 表局部的
# 斜率，24³ 够（32³ 每款多 1.8 MB）。
SPLIT_SIZE = 24
# 密度两头各留的余量：噪声把密度推出观测范围时 cube 不夹断（上游 2-LUT 在雾度下面留 0.2）。
DENSITY_HEADROOM = 0.25

# 冲印区（暗房的「胶片曝光」「冷暖」，2026-11-05 用户选的方向 B；验证见 reports/胶片模拟调研_2026-11-05/R9 之后的记录）：
#   胶片曝光：负片和电影负片多一对「放宽」的两半表 <look>.film_e.cube / .print_e.cube，输入是 EXT_HEAD 倍的线性光
#     （+2 档还留一点余量给统一色温的增益），app 里 film_e(enc(lin·2^EV / EXT_HEAD)) 拿到曝光后的密度。冲扫店把中灰的
#     密度位移补回 EXPOSURE_COMPENSATION（0.5 = 补一半：+1 档更亮更通透、+2 档高光被肩部压软，「过曝的空气感」；
#     全补回去几档几乎看不出差别）。和 spektrafilm 直接算（印放曝光二分到同样的中灰）比，暖肤 / 银幕 −1…+2 档
#     灰阶、肤色平均 ΔE 0.6–1.9、最大 ≤ 3.7（24³）。反转片没有冲扫补偿这一层（过曝就是发白），不出这对表、不给曝光。
#   冷暖：放大机黄滤色 ≈ 底片黄密度加一个常数（CC 单位 = 0.01 密度），品滤色按 WARMTH_M_RATIO 跟着走（往橙暖，不往
#     黄绿）。滑杆 ±1 = ±WARMTH_CC_MAX CC；和真改 yf / mf 比，中灰的偏移量对得上（倍数 0.89–1.12），±8 CC 时饱和色
#     平均 ΔE 约 2.5。反转片没有放大机：同样的密度偏移相当于扫描时的色偏校正。
EXT_HEAD = 4.6
EXPOSURE_COMPENSATION = 0.5
WARMTH_CC_MAX = 8.0
WARMTH_M_RATIO = 3 / 8


def bake_split(film, paper, scan_film, n=SPLIT_SIZE, tone=TONE, phys=None, correct=None):
    """film 表的值 = 归一化密度，按 sRGB 编码存（app 用 CIColorCubeWithColorSpace(sRGB) 读，工作空间里拿到的
    正好是归一化密度）；print 表的值 = 线性 sRGB（app 用不带色彩空间的 CIColorCube，按工作空间里的归一化密度
    直接查，查出来就是线性光）。correct：和色调表同一个扫描校正（套在 print 的 sRGB 输出上），
    颗粒 = print(d + δ) − print(d) 才和底色同一条曲线。返回 (film, print, d_lo, d_hi, dp)。"""
    pipe, dp = make_pipeline(film, paper, scan_film, tone, phys)
    grid = pre_tone(srgb_decode(identity_grid(n)), tone)
    dens = np.asarray(pipe.process(grid, collect="cmy_film"), dtype=np.float64).reshape(n, n, n, 3)
    flat = dens.reshape(-1, 3)
    d_lo = flat.min(axis=0) - DENSITY_HEADROOM
    d_hi = flat.max(axis=0) + DENSITY_HEADROOM
    film_table = srgb_encode((dens - d_lo) / (d_hi - d_lo))
    phys_d = d_lo + identity_grid(n) * (d_hi - d_lo)
    out = np.clip(np.asarray(pipe.process(phys_d, inject="cmy_film"), dtype=np.float64), 0.0, 1.0)
    if correct is not None:
        out = correct(out)
    print_table = srgb_decode(out).reshape(n, n, n, 3)
    return film_table, print_table, d_lo, d_hi, dp


def bake_ext(film, paper, scan_film, n=SPLIT_SIZE, tone=TONE, phys=None, correct=None):
    """冲印区「胶片曝光」用的放宽两半表：film_e 的输入 = sRGB 编码的 (线性光 / EXT_HEAD)，值 = 放宽范围里的归一化密度
    （按 sRGB 编码存，和 film 表一样）；print_e = 那段密度 → 线性 sRGB（同一个扫描校正）。返回 (film_e, print_e, e_lo, e_hi)。"""
    pipe, _ = make_pipeline(film, paper, scan_film, tone, phys)
    grid = identity_grid(n)
    dens = np.asarray(pipe.process(pre_tone(EXT_HEAD * srgb_decode(grid), tone), collect="cmy_film"),
                      dtype=np.float64).reshape(n, n, n, 3)
    flat = dens.reshape(-1, 3)
    e_lo = flat.min(axis=0) - DENSITY_HEADROOM
    e_hi = flat.max(axis=0) + DENSITY_HEADROOM
    film_e = srgb_encode((dens - e_lo) / (e_hi - e_lo))
    phys_d = e_lo + grid * (e_hi - e_lo)
    out = np.clip(np.asarray(pipe.process(phys_d, inject="cmy_film"), dtype=np.float64), 0.0, 1.0)
    if correct is not None:
        out = correct(out)
    print_e = srgb_decode(out).reshape(n, n, n, 3)
    return film_e, print_e, e_lo, e_hi


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


def check_grain(raw, film, paper, scan_film, pixel_um=10.0, size=256):
    """解析的颗粒标准差 vs 上游真抽样（apply_grain_to_density_layers，模糊关掉）：几个密度上比一比。"""
    from spektrafilm.model.density_curves import interp_density_cmy_layers
    from spektrafilm.model.grain import apply_grain_to_density_layers

    _, _, d_lo, d_hi, dp = bake_split(film, paper, scan_film, n=9, tone=look_tone(raw), phys=RECIPES[raw]["phys"])
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
    三次反弹、每次宽 √k 倍、强度减半。σ 按片基厚度（照相片 65 µm、电影片 50 µm）。app 里滑杆是平方刻度
    （强度 = 滑杆² × strength_max）：防光晕层 strong 的真片（红 0.015）≈ 22%，weak（红 0.08）≈ 52%。"""
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


# 表里的数写 4 位小数：0.0001 比 8 位色的一级（1/255 ≈ 0.004）小 40 倍，颗粒用的密度、线性光也够；6 位的时候 33 MB，
# zlib / LZMA 都压不动后面那两位噪声（v1.26.2 起 4 位，DMG 小一半）。
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
                    fh.write(f"{r:.4f} {g:.4f} {b:.4f}\n")


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
                    fh.write(f"{r:.4f} {g:.4f} {b:.4f}\n")


def write_all(out_dir):
    import json

    from spektrafilm.runtime.params_schema import GrainParams

    os.makedirs(out_dir, exist_ok=True)
    version = spektrafilm_version()
    for raw, film, paper, scan in LOOKS:
        table, correct = bake_look(raw, film, paper, scan)
        write_cube(table, os.path.join(out_dir, f"{raw}.cube"), raw, version)
        film_t, print_t, d_lo, d_hi, dp = bake_split(film, paper, scan, tone=look_tone(raw),
                                                     phys=RECIPES[raw]["phys"], correct=correct)
        write_data_cube(film_t, os.path.join(out_dir, f"{raw}.film.cube"), raw, version,
                        "film: sRGB gamma-encoded in -> normalized film CMY density, stored sRGB-encoded")
        write_data_cube(print_t, os.path.join(out_dir, f"{raw}.print.cube"), raw, version,
                        "print: normalized film CMY density in -> linear sRGB out")
        sigma = grain_sigma_unit(dp, d_lo, d_hi)
        develop = {"warmth_cc_max": WARMTH_CC_MAX, "warmth_m_ratio": WARMTH_M_RATIO}
        if dp.film.info.type != "positive":
            fe, pe, e_lo, e_hi = bake_ext(film, paper, scan, tone=look_tone(raw), phys=RECIPES[raw]["phys"], correct=correct)
            write_data_cube(fe, os.path.join(out_dir, f"{raw}.film_e.cube"), raw, version,
                            f"film_e: sRGB gamma-encoded (linear / {EXT_HEAD}) in -> normalized film CMY density, stored sRGB-encoded")
            write_data_cube(pe, os.path.join(out_dir, f"{raw}.print_e.cube"), raw, version,
                            "print_e: normalized film CMY density (extended range) in -> linear sRGB out")
            develop.update({"ext_head": EXT_HEAD, "exposure_compensation": EXPOSURE_COMPENSATION,
                            "e_lo": [round(float(v), 6) for v in e_lo], "e_hi": [round(float(v), 6) for v in e_hi]})
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
            # 冲印区：冷暖的滤色换算；负片 / 电影负片还有胶片曝光用的放宽两半表（film_e / print_e）的范围。
            "develop": develop,
            # 从「没有光谱色调」换进这一款时颗粒 / 晕光的起始值（滑杆刻度）。
            "defaults": {k: float(v) for k, v in RECIPES[raw]["defaults"].items()},
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
            f"  - baked as a {SIZE}^3 3D LUT, sRGB gamma-encoded input and output, values written\n"
            "    with 4 decimals;\n"
            "  - per-pixel part only (spektrafilm debug.lut_mode): no grain, halation, coupler\n"
            "    diffusion, glare, blur or sharpening; auto exposure off;\n"
            "  - exposure fixed at mid gray (no auto exposure); before the film, log2 exposure\n"
            f"    around mid gray is scaled by {TONE['shadow']} below and {TONE['highlight']} above (an\n"
            "    inverse of the camera tone curve already in the photo; reversal films 1.2 above);\n"
            "    scanner white / black point correction on;\n"
            "  - per look (since 2026-11-05, see RECIPES in the script): print paper contrast\n"
            "    (density curve morph gamma), DIR coupler amount, scanner black level and\n"
            "    enlarger Y / M filtration changed from the spektrafilm defaults; one film changed\n"
            "    (filmSunny now Kodak UltraMax 400 instead of Gold 200);\n"
            "  - after spektrafilm, an output-only \"scan correction\" (scan_correct in the script:\n"
            "    white / black point, cool shadows and warm highlights on near-neutrals, skin /\n"
            "    green / blue hue and chroma, saturation) is applied to the look table and to the\n"
            "    print table below, so grain stays consistent with the look;\n"
            "  - renamed with generic look names (file name = look id in the app);\n"
            f"  - <look>.film.cube / <look>.print.cube: the same chain split at the film density\n"
            f"    (spektrafilm's cmy_film tap) into two {SPLIT_SIZE}^3 tables, so the app can add grain\n"
            f"    between them; <look>.json: the density range of that split, the per-channel grain\n"
            "    standard deviation derived from spektrafilm's grain model, and its halation preset;\n"
            f"  - <look>.film_e.cube / <look>.print_e.cube (negative and cine films only): the same split\n"
            f"    with the input extended to {EXT_HEAD}x linear light, so the app can expose the film up to\n"
            "    +2 stops (and down) and let the lab compensate half of the mid-gray shift;\n"
            "    the app also offsets film density by a constant for enlarger-like warm / cool filtration.\n"
            "  These tables are the output of this simulation, not scans of real film.\n"
            "  The app blends each table toward the original with its strength slider at run time.\n"
            "  Script: culling-poc/LabelGUI/Scripts/bake_film_luts.py\n"
        )
    print(f"写好 {len(LOOKS)} 张 LUT + SPEKTRAFILM_LICENSE.txt + CHANGELOG.txt → {out_dir}")


# ---------------------------------------------------------------- 「不脏」规则（R8 §2.1）

_SKIN = [(0.90, 0.74, 0.64), (0.84, 0.64, 0.53), (0.78, 0.58, 0.47), (0.93, 0.78, 0.70), (0.70, 0.50, 0.40)]
_SKY = (110 / 255, 160 / 255, 215 / 255)


def _hue(lab):
    return float(np.degrees(np.arctan2(lab[2], lab[1])) % 360)


def rule_metrics(table):
    def at(rgb):
        return to_lab(apply_trilinear(np.asarray(rgb, dtype=np.float64)[None], table)[0])

    gray = {k: at([v] * 3) for k, v in (("sh", 0.2), ("mid", 0.46), ("hi", 0.9))}
    dh = [((_hue(at(s)) - _hue(to_lab(np.asarray(s))) + 180) % 360) - 180 for s in _SKIN]
    dl = [at(s)[0] - to_lab(np.asarray(s))[0] for s in _SKIN]
    lo, hi = at([0.40] * 3)[0], at([0.52] * 3)[0]
    return dict(gray={k: (round(float(v[1]), 1), round(float(v[2]), 1)) for k, v in gray.items()},
                black=round(float(at([0, 0, 0])[0]), 1), white=round(float(at([1, 1, 1])[0]), 1),
                skin_dh=round(float(np.mean(dh)), 1), skin_dl=round(float(np.mean(dl)), 1),
                sky_b=round(float(at(_SKY)[2]), 1),
                contrast=round(float((hi - lo) / (to_lab(np.full(3, 0.52))[0] - to_lab(np.full(3, 0.40))[0])), 2))


def check_rules(raw, m):
    """G1 高光灰 |a|≤2、b≤+4；G2 灰轴 b>+2 时 a≥0（不许黄绿灰）；G3 肤色色相平均不往黄偏 2° 以上、L* 不降；
    G4 白 L*≥94；G5 暗部灰 b≤+1；G6 天蓝 b≤−15。配方里的 cap 放宽个别款。返回没过的几条。"""
    cap = RECIPES[raw].get("cap", {})
    bad = []
    ha, hb = m["gray"]["hi"]
    if abs(ha) > 2 or hb > cap.get("hi_b", 4):
        bad.append(f"G1 高光灰 {m['gray']['hi']}")
    for k, (a, b) in m["gray"].items():
        if b > 2 and a < -0.3:
            bad.append(f"G2 {k} 灰黄绿 {(a, b)}")
    if m["skin_dh"] > cap.get("skin_dh", 2) or m["skin_dl"] < 0:
        bad.append(f"G3 肤色 Δh {m['skin_dh']} ΔL {m['skin_dl']}")
    if m["white"] < cap.get("white", 94):
        bad.append(f"G4 白 L{m['white']}")
    if m["gray"]["sh"][1] > cap.get("sh_b", 1):
        bad.append(f"G5 暗部灰 {m['gray']['sh']}")
    if m["sky_b"] > -15:
        bad.append(f"G6 天 b {m['sky_b']}")
    return bad


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
    ap.add_argument("--check-rules", action="store_true", help="逐款量「不脏」规则 G1–G6（R8 §2.1），不写 LUT")
    args = ap.parse_args()
    if args.check_grain:
        worst = 0.0
        for raw, film, paper, scan in LOOKS:
            print(raw)
            worst = max(worst, check_grain(raw, film, paper, scan))
        print(f"最大相对差 {worst:.3f}")
    elif args.check_rules:
        failed = 0
        for raw, film, paper, scan in LOOKS:
            m = rule_metrics(bake_look(raw, film, paper, scan)[0])
            bad = check_rules(raw, m)
            failed += bool(bad)
            print(f"{'没过' if bad else '通过'} {raw:13s} 灰 {m['gray']} 黑 L{m['black']} 白 L{m['white']} 肤 Δh{m['skin_dh']:+} "
                  f"ΔL{m['skin_dl']:+} 天 b{m['sky_b']} 反差 {m['contrast']}" + (f"  ← {'；'.join(bad)}" if bad else ""))
        print(f"{len(LOOKS) - failed}/{len(LOOKS)} 款通过")
        if failed:
            sys.exit(1)
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
