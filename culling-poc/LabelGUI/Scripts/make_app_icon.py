#!/usr/bin/env python3
"""画 app 图标（优化分析 2026-11-18 OP-08）：石墨圆角方块上一个琥珀色的光圈，四角是取景框的角标 —— 和默认主题
「石墨 + 琥珀（暗房安全灯）」一套（颜色抄 AppTheme.swift 的 graphite，不引用它）。全用代码画，出 macOS 要的 10 个尺寸，
iconutil 打成 .icns。仓库里的 culling-poc/LabelGUI/AppIcon.icns 就是它出的；build_app.sh 看到这个文件就打进包、写进 Info.plist。

换成自己的图：准备一张 1024×1024 的 PNG（透明底、主体留边，见下面的 BODY），用 --from <png> 只做缩放和打包；
或者直接拿别的工具出好的 AppIcon.icns 覆盖 culling-poc/LabelGUI/AppIcon.icns。

用法（要 Pillow；和 build_app.sh 画 DMG 背景一样借 uv 临时装，不进项目环境）：
  uv run --no-project --with pillow --python python3 python Scripts/make_app_icon.py <输出 AppIcon.icns> [--png-dir <目录>] [--from <1024.png>]
--png-dir：另把 1024 和每个尺寸的 PNG 存一份（看样子用）。

画法：按苹果的图标网格，1024 的画布里主体是 824×824、圆角半径 185 的圆角方块，四周留透明边、底下一层淡影子。
先在 4 倍大的画布上画，再按每个尺寸缩下来（都从大图直接缩，不一级一级缩）。32 像素及以下用简化版：去掉取景框角标、
光圈开口放大一点，16 像素在程序坞的小图、访达列表里也认得出是一个琥珀色的圈。
"""
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

SS = 4                      # 超采样倍数
W = 1024 * SS               # 画布
BODY = 824 * SS             # 主体（连续圆角方块）的边长
BODY_TOP = (W - BODY) // 2  # 主体左上角（上下左右留一样的边）
CX = CY = W / 2

# AppTheme.swift 的 graphite：bar 0x111111、panel 0x1A1A1A、card 0x242424、track 0x3A3A3A、text 0xEDEDED、accent 0xFFB340
GRAPHITE_TOP = (0x2C, 0x2C, 0x2C)
GRAPHITE_BOTTOM = (0x14, 0x14, 0x14)
EDGE = (0x3A, 0x3A, 0x3A)
AMBER = (0xFF, 0xB3, 0x40)
AMBER_DEEP = (0xC9, 0x82, 0x1C)
HOLE = (0x11, 0x11, 0x11)
BRACKET = (0xED, 0xED, 0xED)

# iconset 里的名字 → 像素
SIZES = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
SMALL = 32  # 这个像素及以下用简化版


RADIUS = 185 * SS           # 圆角半径（主体边长的 22.5%，苹果图标网格的值）


def body_mask(inset=0, dy=0):
    """主体的形状：圆角方块（往里缩 inset、往下挪 dy）。"""
    m = Image.new("L", (W, W), 0)
    lo, hi = BODY_TOP + inset, W - BODY_TOP - inset
    ImageDraw.Draw(m).rounded_rectangle([lo, lo + dy, hi, hi + dy], radius=RADIUS - inset, fill=255)
    return m


def body_layer():
    """影子 + 石墨渐变的主体 + 一圈浅一点的边（深色程序坞上也看得出轮廓）。"""
    out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    # 影子：往下挪一点、糊开，很淡
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (0, 0), body_mask(dy=10 * SS))
    out = Image.alpha_composite(out, shadow.filter(ImageFilter.GaussianBlur(14 * SS)))
    # 主体：从上到下由浅到深的石墨
    grad = Image.new("RGBA", (W, W))
    gd = ImageDraw.Draw(grad)
    for y in range(W):
        f = min(1.0, max(0.0, (y - BODY_TOP) / BODY))
        col = tuple(round(a + (b - a) * f) for a, b in zip(GRAPHITE_TOP, GRAPHITE_BOTTOM))
        gd.line([(0, y), (W, y)], fill=col + (255,))
    edge = Image.new("RGBA", (W, W), EDGE + (255,))
    out.paste(edge, (0, 0), body_mask())
    out.paste(grad, (0, 0), body_mask(inset=5 * SS))
    return out


def brackets(draw):
    """取景框的四个角标（浅灰，细）。"""
    inset = 146 * SS
    arm = 96 * SS
    t = 24 * SS
    lo, hi = BODY_TOP + inset, W - BODY_TOP - inset
    col = BRACKET + (150,)
    for x, sx in ((lo, 1), (hi, -1)):
        for y, sy in ((lo, 1), (hi, -1)):
            xs = sorted([x, x + sx * arm])
            ys = sorted([y, y + sy * t])
            draw.rectangle([xs[0], ys[0], xs[1], ys[1]], fill=col)
            xs = sorted([x, x + sx * t])
            ys = sorted([y, y + sy * arm])
            draw.rectangle([xs[0], ys[0], xs[1], ys[1]], fill=col)


def aperture(draw, small):
    """琥珀色的光圈：六片叶片围出一个六边形的开口，叶片按光从左上来深浅略有不同，片和片之间一道暗缝。"""
    R = (290 if small else 222) * SS          # 光圈的外径
    r = (R * 0.44) if small else (R * 0.40)   # 开口（六边形外接圆）的半径
    rim = (22 if small else 14) * SS
    # 外圈一道深一点的琥珀，给边
    draw.ellipse([CX - R - rim, CY - R - rim, CX + R + rim, CY + R + rim], fill=AMBER_DEEP + (255,))
    off = math.radians(-90)
    verts = [(CX + r * math.cos(off + k * math.pi / 3), CY + r * math.sin(off + k * math.pi / 3)) for k in range(6)]

    def hit_circle(p, d):
        # 从 p 沿 d（单位向量）走到半径 R 的圆上
        px, py = p[0] - CX, p[1] - CY
        b = px * d[0] + py * d[1]
        c = px * px + py * py - R * R
        s = -b + math.sqrt(b * b - c)
        return (p[0] + d[0] * s, p[1] + d[1] * s)

    ends = []
    for k in range(6):
        a, b = verts[k - 1], verts[k]
        dx, dy = b[0] - a[0], b[1] - a[1]
        n = math.hypot(dx, dy)
        ends.append(hit_circle(b, (dx / n, dy / n)))
    for k in range(6):
        p0, p1 = ends[k], ends[(k + 1) % 6]
        a0 = math.atan2(p0[1] - CY, p0[0] - CX)
        a1 = math.atan2(p1[1] - CY, p1[0] - CX)
        while a1 < a0:
            a1 += 2 * math.pi
        arc = [(CX + R * math.cos(a0 + (a1 - a0) * i / 48), CY + R * math.sin(a0 + (a1 - a0) * i / 48)) for i in range(49)]
        poly = [verts[k]] + arc + [verts[k]]
        mid = (a0 + a1) / 2
        light = 0.93 + 0.07 * math.cos(mid - math.radians(-135))
        col = tuple(min(255, round(c * light)) for c in AMBER)
        draw.polygon(poly, fill=col + (255,))
    seam = (10 if small else 9) * SS
    for k in range(6):
        draw.line([verts[k], ends[k]], fill=AMBER_DEEP + (255,), width=seam)
    draw.polygon(verts, fill=HOLE + (255,))


def master(small):
    img = body_layer()
    over = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    if not small:
        brackets(d)
    aperture(d, small)
    return Image.alpha_composite(img, over)


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__)
        sys.exit(2)
    out = os.path.abspath(args[0])
    png_dir = args[args.index("--png-dir") + 1] if "--png-dir" in args else None
    source = args[args.index("--from") + 1] if "--from" in args else None
    if source:
        big = Image.open(source).convert("RGBA")
        if big.size != (1024, 1024):
            print(f"--from 要 1024×1024 的 PNG，这张是 {big.size[0]}×{big.size[1]}")
            sys.exit(2)
        masters = {False: big, True: big}
    else:
        masters = {False: master(False), True: master(True)}
    work = tempfile.mkdtemp(prefix="appicon-")
    try:
        iconset = os.path.join(work, "AppIcon.iconset")
        os.makedirs(iconset)
        for name, px in SIZES:
            img = masters[px <= SMALL].resize((px, px), Image.LANCZOS)
            img.save(os.path.join(iconset, name))
        if png_dir:
            os.makedirs(png_dir, exist_ok=True)
            for name, _ in SIZES:
                shutil.copy(os.path.join(iconset, name), png_dir)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"图标 → {out}（{os.path.getsize(out) // 1024} KB，{len(SIZES)} 个尺寸）")


if __name__ == "__main__":
    main()
