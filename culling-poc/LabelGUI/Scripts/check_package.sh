#!/bin/bash
# 打包后的 app 本身对不对（release.yml「打包后的 Info.plist」那一步，用 DMG 里挂出来的那份跑）：裸二进制没有 Info.plist、没有
# Resources，自检和回归看不到这些，只能拿包查。
#
# 用法: Scripts/check_package.sh <选片工具.app>
#
#   - 开发语言 CFBundleDevelopmentRegion = zh-Hans（优化分析 2026-11-18 OP-06）：不写的话系统给的字按英文取 —— 菜单栏是
#     File / Edit / View / Window / Help、打开 / 存储面板的按钮、系统报错的原话都是英文。
#
# 全部只读：不改包、不往包里写。
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1/Contents" ]; then
    echo "用法: $0 <选片工具.app>" >&2
    exit 2
fi
APP="$1"
PLIST="$APP/Contents/Info.plist"
FAILS=0

fail() {
    FAILS=$((FAILS + 1))
    echo "FAIL $1"
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::error title=打包后的 app::$1"; fi
}

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }

plutil -lint "$PLIST" >/dev/null || fail "Info.plist 读不了：$PLIST"

REGION="$(plist CFBundleDevelopmentRegion)"
if [ "$REGION" = "zh-Hans" ]; then
    echo "PASS 开发语言 CFBundleDevelopmentRegion = zh-Hans（系统菜单、面板、系统报错是中文）"
else
    fail "CFBundleDevelopmentRegion 是「${REGION}」，应该是 zh-Hans（不写的话系统菜单、面板、系统报错都是英文）"
fi

if [ "$FAILS" -gt 0 ]; then
    echo "打包后的 app：${FAILS} 项不对"
    exit 1
fi
echo "打包后的 app：都对"
