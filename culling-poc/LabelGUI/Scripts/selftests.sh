#!/bin/bash
# 不要照片的进程内自检（CI 的「自检」步骤）：每条都在一个新的临时 LABELGUI_DATA_DIR 里跑，任何一条退出码不是 0 就红。
#   --ux-selftest        网格改判后焦点落在哪（BatchView.placeAfterChange）
#   --timeline-selftest  时间轴 3000 组随机章节不出界、不重叠；随机数按 seed 播种，这里固定跑 3 个 seed（seed 先混开再和
#                        trial 组合，三个 seed 是三批互不相同的 3000 组，自检开头核对）
#   --swiss-selftest     瑞士风版式规则（完全不收照片参数）
#   --minimal / --mask / --album / --fashion / --newspaper-selftest   不给照片文件夹时只验合成数据
#   --delivery-selftest  交付环节的数据安全：XMP 归属 / 合并、同名另存 -2、截断 JPEG、同一个文件、两条去 GPS
#                        （端到端的命令行出口在 Scripts/delivery_regression.py）
#   --session-move-selftest  挪了的文件夹认得回来（同卷改名 / 拷贝不认 / 重新定位 / 实时桥不跟书签），造假的拍摄、真改名
#   --quit-selftest      长任务和退出：退出 / 取消时 VLM 的 uv、python 子进程整组停掉（假的 uv），阈值防抖退出时写掉，
#                        分析 / VLM 期间防闲置睡眠（pmset 里核对电源断言）、所有出口都放掉；⌘Q 确认的判断表和
#                        「停下并退出」流程（注入的弹框，从不真弹；合成 JPEG 真跑分析）
#   --diag-selftest      诊断：状态栏提示历史、日志轮转、诊断包里没有照片和客户原话、逐张失败的原因、文件夹没权限
#                        （端到端的命令行出口在 Scripts/diag_regression.py）
#   --followup-selftest  跟进小修：写盘失败报给 MCP（persisted / save_failed）、水印页按客户选中导入、复制原片连续失败就停……
#   --persist-selftest   场次持久化：删场次留判决、坏文件挪开不盖、读不了的拒绝切场次、写盘失败看得见（Fixtures/photot-session）
#   --cull-mcp-selftest  选片 MCP 在真的 BatchStore 上：概览的 XMP 待更新 / 上次写的时间、导入客户选择（带备注、托盘跟着刷、
#                        纯数字交付名）、AI 改判的出处（阈值建议不拿 AI 的当样本、亲手改过就拿掉）、一次定一场；
#                        用 Fixtures/photot-session 的 JSON（不要照片），要一个空的数据目录（run 每条都给新的）
#   --files-selftest     文件安全：XMP 只写改了的、同名共用 .xmp、废片避开拼图、高 ISO RAW 复制不互相顶掉
#   --collage-export-selftest  拼图 / 相册导出：PDF 先写临时文件再改名、缺跨页不出 PDF、空照片格先确认
#   --proof-selftest     选片确认表页面脚本（JavaScriptCore）：套餐张数、每张备注、复制的文字、确认表水印
#   --film-looks-selftest  光谱胶片色调：表读得到（裸二进制往上找 third_party/film-luts）、名字不带品牌、GPU 和 CPU 同色
# 别处跑的（最后那段「CI 登记」核对的就是这张表）：--mcp-selftest 在 mcp_smoke.py、--card-queue-selftest 在
# card_import_regression.py、--launch-gate-probe 在 cli_guard_regression.py；--film-selftest 要先分析过的真照片，CI 不跑。
#
# 为什么每条都要临时数据目录：main.swift 在分派之前就建数据目录、往里写内置字体；ux / timeline / swiss 不查
# LABELGUI_DATA_DIR，不设就会在 runner 上建出 ~/Library/Application Support/选片工具，MCP 冒烟里「不建目录」那一条就测不了
# （所以 CI 里这一步也放在 MCP 冒烟后面，两层防护）。跑完再看一眼：跑之前没有真实数据目录的，跑完也不能有。
#
# 用法: Scripts/selftests.sh <LabelGUI 可执行文件>
#       SELFTEST_SEEDS="1 2 3" Scripts/selftests.sh <bin>     # 换时间轴自检的 seed
set -uo pipefail
BIN="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # culling-poc/LabelGUI
FIX="$ROOT/Fixtures/photot-session"
SEEDS="${SELFTEST_SEEDS:-1 2 3}"
REAL_DATA="$HOME/Library/Application Support/选片工具"
real_before=0
[ -e "$REAL_DATA" ] && real_before=1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/mcp-out"

failed=()
passed=0
LIMIT="${SELFTEST_TIMEOUT:-300}"
timings=""
ran=" "   # 跑过的自检参数（最后「CI 登记」那段对 AppRuntime.headlessFlags 用）
run() {
    local label="$1"; shift
    ran="$ran$1 "
    local data sock out rc
    data="$(mktemp -d "$WORK/data.XXXXXX")"
    sock="$(mktemp -d "$WORK/sock.XXXXXX")"
    local start=$SECONDS
    # stdin 接 /dev/null：自检不该读终端；LABELGUI_NO_GUI=1：万一哪条走到了开界面那一句，最后一道闸直接退出。
    # 每条自检单独限时（SELFTEST_TIMEOUT 秒，默认 300：CI 的虚拟机上 --quit-selftest 要 170 秒左右）：到点先用 sample 抓一份调用栈（卡在哪），再停掉、点名报出来，后面的照跑。
    # 以前整步 10 分钟一到被 CI 杀掉，看不出是哪一条。输出写文件（被停掉时 print 的缓冲本来就会丢，调用栈才是线索）。
    local log="$WORK/out.$$.txt" stack="$WORK/sample.$$.txt" timedout=0 pid
    LABELGUI_DATA_DIR="$data" LABELGUI_NO_GUI=1 LABELGUI_LIVE_SOCK_ROOT="$sock" LABELGUI_MCP_OUT="$WORK/mcp-out" \
        "$BIN" "$@" </dev/null >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ $((SECONDS - start)) -ge "$LIMIT" ]; then
            timedout=1
            /usr/bin/sample "$pid" 3 -file "$stack" >/dev/null 2>&1 || true
            kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
            break
        fi
        sleep 0.5
    done
    wait "$pid" 2>/dev/null
    rc=$?
    out="$(cat "$log" 2>/dev/null)"
    rm -f "$log"
    local took=$((SECONDS - start))
    timings="$timings $label=${took}s"
    if [ $timedout -eq 1 ]; then
        failed+=("${label}（超时）")
        # 调用栈里本程序和系统框架的那几层（主线程在最前），够看出卡在哪
        local frames
        frames="$(grep -E '\(in (LabelGUI|CoreText|CoreGraphics|ImageIO|Vision|AppKit|Foundation|CoreFoundation|libdispatch|libsystem_kernel)' "$stack" 2>/dev/null \
            | sed -E 's/^[[:space:]+!:|]*//; s/  +/ /g' | head -40)"
        echo "FAIL ${label}：超过 ${LIMIT}s 没跑完，被停掉。调用栈（sample）："
        printf '%s\n' "$frames" | sed 's/^/    /'
        printf '%s\n' "$out" | tail -10 | sed 's/^/    /'
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
            echo "::error title=自检超时 $label::超过 ${LIMIT}s 没跑完。调用栈：%0A$(printf '%s\n' "$frames" | cut -c1-160 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
        fi
        rm -f "$stack"
    elif [ $rc -eq 0 ]; then
        passed=$((passed + 1))
        echo "PASS $label (${took}s): $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
    else
        failed+=("$label")
        echo "FAIL ${label}：退出码 ${rc} (${took}s)，完整输出："
        printf '%s\n' "$out" | sed 's/^/    /'
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
            echo "::error title=自检 $label::退出码 ${rc}。没过的：%0A$(printf '%s\n' "$out" | grep -E 'FAIL|失败|✗|✘' | head -12 | cut -c1-240 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
        fi
    fi
    # 被限时停掉的自检来不及收尾（比如 --quit-selftest 起的假 uv / python）：凡是命令行里带着这条自检临时目录的进程都是它起的，一并停掉
    pkill -f -- "$data/" 2>/dev/null || true
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
run session-move --session-move-selftest
run quit --quit-selftest
run diag --diag-selftest
run followup --followup-selftest
run persist --persist-selftest "$FIX"
run cull-mcp --cull-mcp-selftest "$FIX"
run files --files-selftest
run collage-export --collage-export-selftest
run proof --proof-selftest
run film-looks --film-looks-selftest

# ---------------------------------------------------------------- CI 登记
# 这一轮各车道加的自检、回归脚本有一半没进 CI（只在自己的分支上手跑过），合进来以后改坏了 CI 照样绿。这里核对两件事：
#   1. AppRuntime.headlessFlags 里每个 --*-selftest / --*-probe 要么上面 run 过，要么在 ELSEWHERE 里写清在哪个脚本跑
#      （那个脚本里真有这个参数的字面量、release.yml 里真有那一步），要么在 NOT_IN_CI 里写清为什么不跑；
#   2. Scripts/ 下每个 *_regression.py、*_smoke.py、verdict_regression.sh、selftests.sh 在 release.yml 里都有一步（注释不算）。
# 新加一个自检或回归脚本忘了接进 CI，这里就红。只读源码和 release.yml，不跑二进制。
ELSEWHERE="
--mcp-selftest mcp_smoke.py
--card-queue-selftest card_import_regression.py
--launch-gate-probe cli_guard_regression.py
"
NOT_IN_CI="
--film-selftest 要先分析过的真照片（按卷出印样、合成帧都从真的像素来），Fixtures 里只有 JSON
"
RUNTIME_SRC="$ROOT/Sources/LabelGUI/AppRuntime.swift"
WORKFLOW="$ROOT/../../.github/workflows/release.yml"
ci_bad=()
if [ ! -f "$RUNTIME_SRC" ] || [ ! -f "$WORKFLOW" ]; then
    ci_bad+=("找不到 $RUNTIME_SRC 或 $WORKFLOW")
else
    workflow_steps="$(grep -vE '^[[:space:]]*#' "$WORKFLOW")"
    flags="$(sed -n '/headlessFlags: Set<String> = \[/,/^    \]/p' "$RUNTIME_SRC" \
        | grep -oE -- '"--[a-z0-9-]+-(selftest|probe)"' | tr -d '"' | sort -u)"
    [ -n "$flags" ] || ci_bad+=("AppRuntime.headlessFlags 里一个 --*-selftest 都没读到：解析坏了")
    for flag in $flags; do
        case "$ran" in *" $flag "*) continue ;; esac
        where="$(printf '%s\n' "$ELSEWHERE" | awk -v f="$flag" '$1 == f { print $2 }')"
        if [ -n "$where" ]; then
            grep -qF -- "\"$flag\"" "$ROOT/Scripts/$where" 2>/dev/null \
                || ci_bad+=("$flag 登记在 $where 里跑，可是 Scripts/$where 里没有 \"$flag\"")
            printf '%s\n' "$workflow_steps" | grep -qF -- "Scripts/$where" \
                || ci_bad+=("$flag 登记在 $where 里跑，可是 release.yml 不跑 Scripts/$where")
            continue
        fi
        printf '%s\n' "$NOT_IN_CI" | awk -v f="$flag" '$1 == f { hit = 1 } END { exit !hit }' && continue
        ci_bad+=("$flag 没进 CI：加进 Scripts/selftests.sh（run <名字> $flag …），或在 ELSEWHERE / NOT_IN_CI 里写清楚")
    done
    for script in "$ROOT"/Scripts/*_regression.py "$ROOT"/Scripts/*_smoke.py "$ROOT"/Scripts/verdict_regression.sh \
                  "$ROOT"/Scripts/selftests.sh; do
        [ -e "$script" ] || continue
        name="$(basename "$script")"
        printf '%s\n' "$workflow_steps" | grep -qF -- "culling-poc/LabelGUI/Scripts/$name" \
            || ci_bad+=("Scripts/$name 不在 release.yml 里：加一步（放在 MCP 冒烟后面）")
    done
fi
if [ ${#ci_bad[@]} -gt 0 ]; then
    failed+=("CI 登记")
    for msg in "${ci_bad[@]}"; do
        echo "FAIL CI 登记：$msg"
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::error title=自检 CI 登记::$msg"; fi
    done
else
    passed=$((passed + 1))
    echo "PASS CI 登记: $(printf '%s\n' $flags | wc -l | tr -d ' ') 个 --*-selftest / --*-probe 和 Scripts/ 下的回归脚本都有人跑"
fi

if [ $real_before -eq 0 ] && [ -e "$REAL_DATA" ]; then
    failed+=("真实数据目录")
    echo "FAIL 跑之前没有 ${REAL_DATA}，跑完有了：哪条自检没走临时数据目录"
fi

echo "各条用时：$timings"
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::notice title=自检用时::$timings"; fi

if [ ${#failed[@]} -gt 0 ]; then
    echo "!! 自检 ${#failed[@]} 条没过：${failed[*]}（通过 $passed 条）" >&2
    exit 1
fi
echo "自检全部通过：$passed 条"
