#!/bin/bash
# 不要照片的进程内自检（CI 的「自检」步骤）：每条都在一个新的临时 LABELGUI_DATA_DIR 里跑，任何一条退出码不是 0 就红。
# 跑哪些、按什么先后、带什么参数、各测什么，都在自检登记表 Sources/LabelGUI/SelfTestRegistry.swift 里（优化分析 NE8）：
# 这里先跑一次 `LabelGUI --list-selftests` 拿清单（一条一行：参数、CI 怎么跑、selftests.sh 给的参数、说明），ci 一列是 selftests.sh 的照着跑：
#   参数里的 {fixture} 换成 Fixtures/photot-session；带 {seed} 的（时间轴）按 SELFTEST_SEEDS 每个跑一遍，标签带 seed=N。
#   标签是参数去掉 -- 和 -selftest（--session-move-selftest → session-move）。
# 加一条自检只改那张表（SelfTestRegistry.all 加一行），这个脚本不用动。
# 别处跑的（ci 一列是回归脚本名，比如 --mcp-selftest 在 mcp_smoke.py）、CI 不跑的（none，带为什么）也在那张表里，
# 最后那段「CI 登记」核对。
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
ran=" "   # 跑过的自检参数（最后「CI 登记」那段对登记表用）
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

# 清单从程序里拿（自检登记表），和每条自检一样走临时数据目录：拿清单本身不建数据目录、不读写任何文件。
LIST="$WORK/selftests.tsv"
mkdir -p "$WORK/list-data" "$WORK/list-sock"
LABELGUI_DATA_DIR="$WORK/list-data" LABELGUI_NO_GUI=1 LABELGUI_LIVE_SOCK_ROOT="$WORK/list-sock" LABELGUI_MCP_OUT="$WORK/mcp-out" \
    "$BIN" --list-selftests </dev/null >"$LIST" 2>"$WORK/list.err"
list_rc=$?
if [ $list_rc -ne 0 ] || ! grep -q -- '^--' "$LIST"; then
    echo "FAIL 自检清单：$BIN --list-selftests 退出码 ${list_rc}，读不到登记表（旧版程序没有这个参数？）"
    sed 's/^/    /' "$WORK/list.err" "$LIST"
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::error title=自检清单::--list-selftests 退出码 ${list_rc}"; fi
    exit 1
fi

# 一行四列（tab 分开，空的写 -）：参数、CI 怎么跑、selftests.sh 给的参数、说明（none 的再带一列为什么不跑）。
# fd 3 读：run 里起的进程不会吃掉清单的 stdin。
while IFS=$'\t' read -r -u 3 flag ci args _summary; do
    case "$flag" in --*) ;; *) continue ;; esac
    [ "$ci" = "selftests.sh" ] || continue
    label="${flag#--}"
    label="${label%-selftest}"
    argv=()
    [ "$args" = "-" ] || read -r -a argv <<<"$args"
    has_seed=0
    for a in ${argv[@]+"${argv[@]}"}; do [ "$a" = "{seed}" ] && has_seed=1; done
    if [ $has_seed -eq 1 ]; then
        for seed in $SEEDS; do
            cmd=()
            for a in "${argv[@]}"; do
                case "$a" in "{seed}") cmd+=("$seed") ;; "{fixture}") cmd+=("$FIX") ;; *) cmd+=("$a") ;; esac
            done
            run "$label seed=$seed" "$flag" "${cmd[@]}"
        done
    else
        cmd=()
        for a in ${argv[@]+"${argv[@]}"}; do
            case "$a" in "{fixture}") cmd+=("$FIX") ;; *) cmd+=("$a") ;; esac
        done
        run "$label" "$flag" ${cmd[@]+"${cmd[@]}"}
    fi
done 3<"$LIST"

# ---------------------------------------------------------------- CI 登记
# 这一轮各车道加的自检、回归脚本有一半没进 CI（只在自己的分支上手跑过），合进来以后改坏了 CI 照样绿。这里核对三件事：
#   1. 登记表（上面 --list-selftests 拿到的清单）里每一条都有人跑：ci 是 selftests.sh 的上面真跑过；是回归脚本名的，
#      Scripts/ 下那个脚本里真有这个参数的字面量、release.yml 里真有那一步；none 的写了为什么不跑。参数不重复。
#   2. 没有绕过登记表的自检：Sources/ 下每个 "--…-selftest" / "--…-probe" 字面量都在登记表里（往 main.swift 里直接写一个
#      分派、不登记的，这里红）。
#   3. Scripts/ 下每个 *_regression.py、*_smoke.py、verdict_regression.sh、selftests.sh 在 release.yml 里都有一步（注释不算）。
# 新加一个自检或回归脚本忘了接进 CI，这里就红。读上面拿到的清单、源码和 release.yml，不另跑二进制。
SRC_DIR="$ROOT/Sources/LabelGUI"
WORKFLOW="$ROOT/../../.github/workflows/release.yml"
ci_bad=()
if [ ! -d "$SRC_DIR" ] || [ ! -f "$WORKFLOW" ]; then
    ci_bad+=("找不到 $SRC_DIR 或 $WORKFLOW")
else
    workflow_steps="$(grep -vE '^[[:space:]]*#' "$WORKFLOW")"
    flags="$(grep -E -- '^--' "$LIST" | cut -f1 | sort)"
    [ -n "$flags" ] || ci_bad+=("登记表里一条都没读到：--list-selftests 的输出解析坏了")
    dups="$(printf '%s\n' "$flags" | uniq -d)"
    [ -z "$dups" ] || ci_bad+=("登记表里有重复的参数：$(echo $dups)")
    while IFS=$'\t' read -r -u 3 flag ci _args _summary why; do
        case "$flag" in --*) ;; *) continue ;; esac
        case "$ci" in
            selftests.sh)
                case "$ran" in *" $flag "*) ;; *) ci_bad+=("$flag 登记成 selftests.sh 跑，可是上面没跑到") ;; esac
                ;;
            none)
                [ -n "$why" ] && [ "$why" != "-" ] || ci_bad+=("$flag 登记成 CI 不跑（none），可是没写为什么")
                ;;
            *)
                if [ ! -f "$ROOT/Scripts/$ci" ]; then
                    ci_bad+=("$flag 登记在 $ci 里跑，可是 Scripts/ 下没有 $ci")
                else
                    grep -qF -- "\"$flag\"" "$ROOT/Scripts/$ci" \
                        || ci_bad+=("$flag 登记在 $ci 里跑，可是 Scripts/$ci 里没有 \"$flag\"")
                    printf '%s\n' "$workflow_steps" | grep -qF -- "Scripts/$ci" \
                        || ci_bad+=("$flag 登记在 $ci 里跑，可是 release.yml 不跑 Scripts/$ci")
                fi
                ;;
        esac
    done 3<"$LIST"
    literals="$(grep -rhoE --include='*.swift' -- '"--[a-z0-9-]+-(selftest|probe)"' "$SRC_DIR" | tr -d '"' | sort -u)"
    [ -n "$literals" ] || ci_bad+=("Sources 里一个 \"--…-selftest\" 字面量都没读到：扫描坏了")
    for lit in $literals; do
        printf '%s\n' "$flags" | grep -qxF -- "$lit" \
            || ci_bad+=("Sources 里有 \"$lit\"，登记表里却没有：自检只登在 SelfTestRegistry.all（入口、CI 怎么跑），别直接写进 main.swift 的分派")
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
