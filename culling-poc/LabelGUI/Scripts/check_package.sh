#!/bin/bash
# 打包后的 app 本身对不对（release.yml「打包后的 Info.plist」那一步，用 DMG 里挂出来的那份跑）：裸二进制没有 Info.plist、没有
# Resources，自检和回归看不到这些，只能拿包查。
#
# 用法: Scripts/check_package.sh <选片工具.app>
#
#   - 开发语言 CFBundleDevelopmentRegion = zh-Hans（优化分析 2026-11-18 OP-06）：不写的话系统给的字按英文取 —— 菜单栏是
#     File / Edit / View / Window / Help、打开 / 存储面板的按钮、系统报错的原话都是英文。
#   - 图标（OP-08）：Info.plist 的 CFBundleIconFile 指到 Resources 里一个真的 .icns，iconutil 拆得开、里面有 16 到 1024 的
#     10 个尺寸（build_app.sh 只在仓库里有 culling-poc/LabelGUI/AppIcon.icns 时才带，文件丢了这里红）。
#   - 包里的二进制真按 zh-Hans 取系统的字（OP-06 / OP-10）：临时数据目录里跑一次 --diag-export，info.txt 的「界面语言」
#     是 zh-Hans。bundle id 是真 app 的（local.culling.labelgui）时只在 CI 上跑：本机跑会读真 app 的设置域。
#
# 不改包、不往包里写；--diag-export 只写临时目录。
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

ICON="$(plist CFBundleIconFile)"
ICNS="$APP/Contents/Resources/${ICON%.icns}.icns"
if [ -z "$ICON" ]; then
    fail "Info.plist 没有 CFBundleIconFile：程序坞、访达里是通用图标（仓库里的 culling-poc/LabelGUI/AppIcon.icns 丢了？）"
elif [ ! -f "$ICNS" ]; then
    fail "CFBundleIconFile 是 ${ICON}，包里没有 Resources/${ICON%.icns}.icns"
else
    WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/check-icon.XXXXXX")"
    if iconutil -c iconset "$ICNS" -o "$WORK/x.iconset" 2>/dev/null; then
        N="$(find "$WORK/x.iconset" -name 'icon_*.png' | wc -l | tr -d ' ')"
        if [ "$N" -ge 10 ] && [ -f "$WORK/x.iconset/icon_512x512@2x.png" ] && [ -f "$WORK/x.iconset/icon_16x16.png" ]; then
            echo "PASS 图标 ${ICON}：${N} 个尺寸（16 到 1024）"
        else
            fail "图标 ${ICON} 只拆出 ${N} 个尺寸，缺 16 或 1024"
        fi
    else
        fail "图标 ${ICNS} iconutil 拆不开"
    fi
    rm -rf "$WORK"
fi

BIN="$APP/Contents/MacOS/$(plist CFBundleExecutable)"
if [ "$(plist CFBundleIdentifier)" = "local.culling.labelgui" ] && [ "${GITHUB_ACTIONS:-}" != "true" ]; then
    echo "skip 界面语言：bundle id 是真 app 的，本机不跑（会读真 app 的设置域）；CI 上跑"
elif [ ! -x "$BIN" ]; then
    fail "包里没有可执行文件 $BIN"
else
    WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/check-lang.XXXXXX")"
    mkdir -p "$WORK/data" "$WORK/sock" "$WORK/mcp"
    if LABELGUI_DATA_DIR="$WORK/data" LABELGUI_NO_GUI=1 LABELGUI_LIVE_SOCK_ROOT="$WORK/sock" LABELGUI_MCP_OUT="$WORK/mcp" \
        "$BIN" --diag-export "$WORK/d.zip" >"$WORK/out.txt" 2>&1 && ditto -x -k "$WORK/d.zip" "$WORK/x" 2>/dev/null; then
        LANG_LINE="$(cat "$WORK"/x/*/info.txt 2>/dev/null | grep '^界面语言：' || true)"
        case "$LANG_LINE" in
            界面语言：zh-Hans*) echo "PASS 包里的二进制按 zh-Hans 取系统的字（诊断包 info.txt：${LANG_LINE}）" ;;
            *) fail "包里的二进制取系统的字不是 zh-Hans（诊断包 info.txt：「${LANG_LINE}」）" ;;
        esac
    else
        fail "包里的二进制跑 --diag-export 没成：$(tail -3 "$WORK/out.txt" 2>/dev/null)"
    fi
    rm -rf "$WORK"
fi

if [ "$FAILS" -gt 0 ]; then
    echo "打包后的 app：${FAILS} 项不对"
    exit 1
fi
echo "打包后的 app：都对"
