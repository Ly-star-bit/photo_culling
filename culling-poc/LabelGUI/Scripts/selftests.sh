#!/bin/bash
# 不要照片的进程内自检（CI 的「自检」步骤）：每条都在一个新的临时 LABELGUI_DATA_DIR 里跑，任何一条退出码不是 0 就红。
#   --ux-selftest        网格改判后焦点落在哪（BatchView.placeAfterChange）
#   --timeline-selftest  时间轴 3000 组随机章节不出界、不重叠；随机数按 seed 播种，这里固定跑 3 个 seed
#   --swiss-selftest     瑞士风版式规则（完全不收照片参数）
#   --minimal / --mask / --album / --fashion / --newspaper-selftest   不给照片文件夹时只验合成数据
#   --delivery-selftest  交付环节的数据安全：XMP 归属 / 合并、同名另存 -2、截断 JPEG、同一个文件、两条去 GPS
#                        （端到端的命令行出口在 Scripts/delivery_regression.py）
#   --diag-selftest      诊断：状态栏提示历史、逐张失败的原因、文件夹没权限
#                        （端到端的命令行出口在 Scripts/diag_regression.py）
#
# 为什么每条都要临时数据目录：main.swift 在分派之前就建数据目录、往里写内置字体；ux / timeline / swiss 不查
# LABELGUI_DATA_DIR，不设就会在 runner 上建出 ~/Library/Application Support/选片工具，MCP 冒烟里「不建目录」那一条就测不了
# （所以 CI 里这一步也放在 MCP 冒烟后面，两层防护）。跑完再看一眼：跑之前没有真实数据目录的，跑完也不能有。
#
# 用法: Scripts/selftests.sh <LabelGUI 可执行文件>
#       SELFTEST_SEEDS="1 2 3" Scripts/selftests.sh <bin>     # 换时间轴自检的 seed
set -uo pipefail
BIN="$1"
SEEDS="${SELFTEST_SEEDS:-1 2 3}"
REAL_DATA="$HOME/Library/Application Support/选片工具"
real_before=0
[ -e "$REAL_DATA" ] && real_before=1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/mcp-out"

failed=()
passed=0
run() {
    local label="$1"; shift
    local data sock out rc
    data="$(mktemp -d "$WORK/data.XXXXXX")"
    sock="$(mktemp -d "$WORK/sock.XXXXXX")"
    local start=$SECONDS
    # stdin 接 /dev/null：自检不该读终端；LABELGUI_NO_GUI=1：万一哪条走到了开界面那一句，最后一道闸直接退出。
    out="$(LABELGUI_DATA_DIR="$data" LABELGUI_NO_GUI=1 LABELGUI_LIVE_SOCK_ROOT="$sock" LABELGUI_MCP_OUT="$WORK/mcp-out" \
        "$BIN" "$@" </dev/null 2>&1)"
    rc=$?
    local took=$((SECONDS - start))
    if [ $rc -eq 0 ]; then
        passed=$((passed + 1))
        echo "PASS $label (${took}s): $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
    else
        failed+=("$label")
        echo "FAIL ${label}：退出码 ${rc} (${took}s)，完整输出："
        printf '%s\n' "$out" | sed 's/^/    /'
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::error title=自检 $label::退出码 $rc"; fi
    fi
    rm -rf "$data" "$sock"
}

run ux --ux-selftest
for seed in $SEEDS; do
    run "timeline seed=$seed" --timeline-selftest --seed "$seed"
done
run swiss --swiss-selftest
run minimal --minimal-selftest
run mask --mask-selftest
run album --album-selftest
run fashion --fashion-selftest
run newspaper --newspaper-selftest
run delivery --delivery-selftest
run diag --diag-selftest

if [ $real_before -eq 0 ] && [ -e "$REAL_DATA" ]; then
    failed+=("真实数据目录")
    echo "FAIL 跑之前没有 ${REAL_DATA}，跑完有了：哪条自检没走临时数据目录"
fi

if [ ${#failed[@]} -gt 0 ]; then
    echo "!! 自检 ${#failed[@]} 条没过：${failed[*]}（通过 $passed 条）" >&2
    exit 1
fi
echo "自检全部通过：$passed 条"
