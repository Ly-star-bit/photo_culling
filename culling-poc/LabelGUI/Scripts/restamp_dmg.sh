#!/bin/bash
# 推 tag 沿用 feature 那次的 DMG 时：把 app 的版本号换成 tag 的、重签，再打回 DMG（release.yml 的 restamp job）。
# build job 每次都拿一份副本、用假版本号预演一遍（「预演 restamp」那一步）：tag 那次才走到的这条路，feature 上就验过。
#
# 用法: Scripts/restamp_dmg.sh <输入.dmg> <版本号> <输出.dmg>
#
# 不在原卷上改：build_app.sh 用 hdiutil create -srcfolder 建卷，卷上几乎没有空余（man hdiutil：「source data plus some
# padding」），codesign 重签要先写一整份 .cstemp（二进制约 14 MB）再改名，原地改会 ENOSPC。所以照 build_app.sh 的路子走：
# 只读挂上 → ditto 拷出来（.background、.DS_Store、Applications 替身一起）→ 改 Info.plist、重签（和 build_app.sh 同一句
# codesign）、验签 → hdiutil create -srcfolder 重新建卷（同一个卷名，访达排版的 .DS_Store 照旧对得上）→ 转 ULMO。
# 最后只读挂上输出，核对版本号、签名、Applications 替身。挂载都带 -nobrowse -noautoopen（不进访达、不开窗口）。
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "用法: $0 <输入.dmg> <版本号> <输出.dmg>" >&2
    exit 2
fi
IN="$1"
VERSION="$2"
OUT="$3"
NAME="选片工具"

WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/restamp.XXXXXX")"
MNT="$WORK/mnt"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
mkdir -p "$MNT"

MOUNTED=0
attach() {
    hdiutil attach "$1" -nobrowse -readonly -noautoopen -mountpoint "$MNT" -quiet
    MOUNTED=1
}
# 访达、Spotlight 可能还捏着卷：先礼貌重试几次，再 -force（同 build_app.sh）。
detach() {
    [ "$MOUNTED" = 1 ] || return 0
    for _ in 1 2 3 4 5; do
        if hdiutil detach "$MNT" -quiet; then MOUNTED=0; return 0; fi
        sleep 1
    done
    hdiutil detach "$MNT" -force -quiet || true
    MOUNTED=0
}
cleanup() {
    detach
    rm -rf "$WORK"
}
trap cleanup EXIT

# 1. 拷出来
attach "$IN"
ditto "$MNT" "$STAGE"
detach
# 挂载时系统建的东西不带走
rm -rf "$STAGE/.fseventsd" "$STAGE/.Trashes" "$STAGE/.Spotlight-V100" "$STAGE/.TemporaryItems"

APP="$STAGE/${NAME}.app"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "!! ${IN} 里没有 ${NAME}.app/Contents/Info.plist" >&2; exit 1; }

# 2. 版本号、重签
OLD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. 重新建卷、压缩
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -format UDRW -ov -quiet "$RW"
rm -f "$OUT"
hdiutil convert "$RW" -format ULMO -o "$OUT" -quiet

# 4. 核对输出：只读挂上，版本号、签名、拖进去安装用的替身
attach "$OUT"
GOT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MNT/${NAME}.app/Contents/Info.plist")"
[ "$GOT" = "$VERSION" ] || { echo "!! 输出里的版本号是 ${GOT}，不是 ${VERSION}" >&2; exit 1; }
[ -x "$MNT/${NAME}.app/Contents/MacOS/LabelGUI" ] || { echo "!! 输出里没有 ${NAME}.app/Contents/MacOS/LabelGUI" >&2; exit 1; }
[ "$(readlink "$MNT/Applications")" = /Applications ] || { echo "!! 输出里没有指向 /Applications 的替身" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$MNT/${NAME}.app"
detach

echo "版本号 ${OLD} → ${VERSION}（CFBundleVersion ${BUILD} 不变）；只改了 Info.plist、重签，输出 ${OUT}"
