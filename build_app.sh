#!/bin/bash
# 构建 选片工具.app 并打包精美 DMG (拖拽安装布局)。
# 用法: ./build_app.sh
# VLM 阶段的 Python 运行时打进 app 的 Contents/Resources/culling-poc —— app 启动时
# 自动同步到 App Support,保证脚本永远和 app 版本一致。只带 layer2.py 真正需要的
# 东西 (requests/tqdm/pillow, 见 culling-poc/runtime/pyproject.toml),不带
# mediapipe/opencv/rawpy 全家桶:那是已被原生引擎取代的 Python layer1 的依赖。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/选片工具.app"
DMG="$ROOT/选片工具.dmg"
POC="$ROOT/culling-poc"
VOL="/Volumes/选片工具"

echo "==> swift build"
cd "$POC/LabelGUI"
swift build -c release

echo "==> 装配 app bundle"
# 从零装配:叠在旧 bundle 上会把已删掉的文件 (旧 Python 脚本、旧 plist 键) 一起带走。
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Info.plist 每次都生成 — CI 从零装配 bundle,缺了它 codesign 直接报
# "bundle format unrecognized"。版本号只从 TAG 带入 (v1.1.1 → 1.1.1)：
# GITHUB_REF_NAME 在分支构建上是 "main"，会写出 CFBundleShortVersionString=main。
VERSION="0.1"
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    VERSION="${GITHUB_REF_NAME#v}"
fi
# CFBundleVersion 要单调递增 (Finder/LaunchServices 据此分辨"哪个是新版")：
# 用提交数;CI 需要 fetch-depth: 0,浅克隆会数成 1。没有 git 就退回 VERSION。
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
if [ -z "$BUILD_NUMBER" ] || [ "$BUILD_NUMBER" -le 1 ]; then
    BUILD_NUMBER="$VERSION"
fi
# 图标:仓库目前没有 .icns (没有 CFBundleIconFile 时 macOS 用通用 app 图标)。
# 放一个 culling-poc/LabelGUI/AppIcon.icns 进来就会自动打包并写入 plist。
ICON_SRC="$POC/LabelGUI/AppIcon.icns"
ICON_PLIST=""
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST="
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LabelGUI</string>
    <key>CFBundleIdentifier</key>
    <string>local.culling.labelgui</string>
    <key>CFBundleName</key>
    <string>选片工具</string>
    <key>CFBundleDisplayName</key>
    <string>选片工具</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>${ICON_PLIST}
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
cp .build/release/LabelGUI "$APP/Contents/MacOS/LabelGUI"

# 精简 Python 运行时进 Resources:只放 layer2.py 及其 import (common.py、
# prompts/),外加 runtime/ 里的精简 pyproject + 锁文件 —— 改名放到 layer2.py
# 旁边,因为 app 在 App Support/runtime/culling-poc 里执行 `uv run python layer2.py`,
# uv 只认脚本旁边的 pyproject。prepare.py/layer1.py/evaluate.py 是开发工具,
# 不进 bundle。
RES="$APP/Contents/Resources/culling-poc"
mkdir -p "$RES"
cp "$POC/layer2.py" "$POC/common.py" "$POC/.python-version" "$RES/"
cp -R "$POC/prompts" "$RES/prompts"
cp "$POC/runtime/pyproject.toml" "$RES/pyproject.toml"
cp "$POC/runtime/uv.lock" "$RES/uv.lock"
find "$RES" -name __pycache__ -prune -exec rm -rf {} +

echo "==> 签名"
codesign --force --sign - "$APP"

echo "==> 渲染 DMG 背景图"
# --no-project: 这一步只要 Pillow — 别为了画一张背景图装整个项目环境。
# --python python3: 用机器上现成的解释器 (本机 Homebrew、CI runner 自带),
# 否则 uv 会为 culling-poc/.python-version 的 3.12 再下载一个 CPython。
BG_DIR="$(mktemp -d)"
BG="$BG_DIR/bg.png"
uv run --no-project --with pillow --python python3 python - "$BG" <<'EOF'
import glob
import sys
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]
W, H = 1200, 800
img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
for y in range(H):
    g = int(30 + 14 * y / H)
    d.line([(0, y), (W, y)], fill=(g, g, g + 4))

def font(size, bold=False):
    # PingFang 在新系统里不在 /System/Library/Fonts 下,而是按需下载的字体资产;
    # 找不到就退到随系统自带的冬青黑体 (W3/W6 两个字重)。
    pingfang = glob.glob("/System/Library/Fonts/PingFang.ttc") + glob.glob(
        "/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc")
    # ttc 面索引:PingFang.ttc 3 = SC Regular, 11 = SC Semibold;
    # Hiragino Sans GB.ttc 0 = W3, 2 = W6。
    candidates = [(p, 11 if bold else 3) for p in pingfang]
    candidates.append(("/System/Library/Fonts/Hiragino Sans GB.ttc", 2 if bold else 0))
    candidates.append(("/System/Library/Fonts/STHeiti Medium.ttc", 0))
    for path, idx in candidates:
        try:
            return ImageFont.truetype(path, size, index=idx)
        except Exception:
            continue
    return ImageFont.load_default(size)

def center(y, text, f, fill):
    d.text(((W - d.textlength(text, font=f)) / 2, y), text, font=f, fill=fill)

center(90, "选片工具", font(64, bold=True), (240, 240, 245))
center(185, "AI 辅助批量选片 · 本地运行", font(30), (150, 150, 158))
ay = 460
d.line([(470, ay), (700, ay)], fill=(110, 110, 120), width=10)
d.polygon([(700, ay - 22), (700, ay + 22), (745, ay)], fill=(110, 110, 120))
center(640, "把 选片工具 拖到 Applications 完成安装", font(34), (210, 210, 218))
# macOS 15 起"右键 → 打开"不再绕过 Gatekeeper,只能走系统设置。
center(700, "首次打开若被拦截：系统设置 → 隐私与安全性 → 仍要打开", font(24), (130, 130, 138))
img.save(out, dpi=(144, 144))
EOF

echo "==> 组装 DMG"
# 上一次构建若在 detach 前失败（Finder 窗口没关 = Resource busy），卷会一直挂着：
# 下次 attach 会挂成"选片工具 1"，osascript 和 detach 操作的是旧卷，convert 也会
# 因为 RW 镜像仍被挂载而失败 —— 从此每次都失败，直到手动 detach。
if [ -d "$VOL" ]; then
    echo "==> 卸载上次残留的卷"
    hdiutil detach "$VOL" -force -quiet || true
fi

STAGE=$(mktemp -d)
mkdir -p "$STAGE/.background"
cp "$BG" "$STAGE/.background/bg.png"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
RW=$(mktemp -u).dmg
hdiutil create -volname 选片工具 -srcfolder "$STAGE" -format UDRW -ov -quiet "$RW"
# -nobrowse: 不在桌面/边栏弹出卷。Finder 排版脚本按 POSIX 路径找卷,不依赖它可见。
hdiutil attach "$RW" -nobrowse -quiet
# 挂载是异步生效的:等挂载点真出现,最多 10 秒,而不是盲睡 1 秒。
for _ in $(seq 1 20); do
    [ -d "$VOL" ] && break
    sleep 0.5
done
if [ ! -d "$VOL" ]; then
    echo "!! $VOL 没有挂上"; exit 1
fi

# Finder 排版在无 GUI 的 CI runner 上可能失败 — 失败就跳过,DMG 照样能装,
# 只是没有自定义布局/背景。
if ! osascript - "$VOL" <<'EOF'
on run argv
    set volPath to item 1 of argv
    tell application "Finder"
        set theVol to (POSIX file volPath) as alias
        open theVol
        set theWindow to container window of theVol
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        set the bounds of theWindow to {300, 150, 900, 550}
        set viewOptions to the icon view options of theWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:bg.png" of theVol
        set position of item "选片工具.app" of theWindow to {150, 195}
        set position of item "Applications" of theWindow to {450, 195}
        update theVol without registering applications
        delay 1
        close theWindow
    end tell
end run
EOF
then
    echo "!! Finder 排版失败 (CI 常见) — 继续打包默认布局的 DMG"
fi

# Finder 关窗后才把布局写进 .DS_Store:等它落地 (最多 5 秒) 再卸载。
for _ in $(seq 1 10); do
    [ -f "$VOL/.DS_Store" ] && break
    sleep 0.5
done
# Finder/Spotlight 可能还捏着卷:先礼貌重试几次,再 -force —— set -e 下一次
# Resource busy 就会退出并把卷留在那里毒害下一次构建。
detached=0
for _ in $(seq 1 5); do
    if hdiutil detach "$VOL" -quiet 2>/dev/null; then
        detached=1; break
    fi
    sleep 1
done
if [ "$detached" = 0 ]; then
    hdiutil detach "$VOL" -force -quiet
fi
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -o "$DMG" -quiet
rm -rf "$RW" "$STAGE" "$BG_DIR"

echo "==> 完成: $DMG"
ls -lh "$DMG"
