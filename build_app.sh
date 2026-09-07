#!/bin/bash
# 构建 选片工具.app 并打包精美 DMG (拖拽安装布局)。
# 用法: ./build_app.sh
# Python 流水线会打进 app 的 Contents/Resources/culling-poc —— app 启动时自动
# 同步到 App Support,保证脚本永远和 app 版本一致。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/选片工具.app"
DMG="$ROOT/选片工具.dmg"
POC="$ROOT/culling-poc"

echo "==> swift build"
cd "$POC/LabelGUI"
swift build -c release

echo "==> 装配 app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LabelGUI "$APP/Contents/MacOS/LabelGUI"
# Python 流水线进 Resources (只带运行所需,不带开发目录)
rsync -a --delete \
    --exclude LabelGUI --exclude .venv --exclude data \
    --exclude __pycache__ --exclude models --exclude .git \
    "$POC/" "$APP/Contents/Resources/culling-poc/"

echo "==> 签名"
codesign --force --sign - "$APP"

echo "==> 渲染 DMG 背景图"
# --no-project: 这一步只要 Pillow — 别为了画一张背景图装 mediapipe/opencv
# 全家桶 (CI runner 上尤其致命)。
cd "$POC" && uv run --no-project --with pillow python - <<'EOF'
from PIL import Image, ImageDraw, ImageFont

W, H = 1200, 800
img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
for y in range(H):
    g = int(30 + 14 * y / H)
    d.line([(0, y), (W, y)], fill=(g, g, g + 4))

def font(size, bold=False):
    for path, idx in [("/System/Library/Fonts/PingFang.ttc", 2 if bold else 0),
                      ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0)]:
        try:
            return ImageFont.truetype(path, size, index=idx)
        except Exception:
            continue
    return ImageFont.load_default()

def center(y, text, f, fill):
    d.text(((W - d.textlength(text, font=f)) / 2, y), text, font=f, fill=fill)

center(90, "选片工具", font(64, bold=True), (240, 240, 245))
center(185, "AI 辅助批量选片 · 本地运行", font(30), (150, 150, 158))
ay = 460
d.line([(470, ay), (700, ay)], fill=(110, 110, 120), width=10)
d.polygon([(700, ay - 22), (700, ay + 22), (745, ay)], fill=(110, 110, 120))
center(640, "把 选片工具 拖到 Applications 完成安装", font(34), (210, 210, 218))
center(700, "首次打开请右键 → 打开 (绕过未验证开发者提示)", font(24), (130, 130, 138))
img.save("/tmp/dmg_bg.png", dpi=(144, 144))
EOF

echo "==> 组装 DMG"
STAGE=$(mktemp -d)
mkdir -p "$STAGE/.background"
cp /tmp/dmg_bg.png "$STAGE/.background/bg.png"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
RW=$(mktemp -u).dmg
hdiutil create -volname 选片工具 -srcfolder "$STAGE" -format UDRW -ov -quiet "$RW"
hdiutil attach "$RW" -quiet
sleep 1

# Finder 排版在无 GUI 的 CI runner 上可能失败 — 失败就跳过,DMG 照样能装,
# 只是没有自定义布局/背景。
if ! osascript <<'EOF'
tell application "Finder"
    tell disk "选片工具"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {300, 150, 900, 550}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:bg.png"
        set position of item "选片工具.app" of container window to {150, 195}
        set position of item "Applications" of container window to {450, 195}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "!! Finder 排版失败 (CI 常见) — 继续打包默认布局的 DMG"
fi

sync && sleep 1
hdiutil detach "/Volumes/选片工具" -quiet
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -o "$DMG" -quiet
rm -rf "$RW" "$STAGE" /tmp/dmg_bg.png

echo "==> 完成: $DMG"
ls -lh "$DMG"
