#!/bin/bash
# 推 feature 分支之前的类型检查预检：用和 CI（Xcode 16.4）同版本的 Swift 6.1.2 对整个模块做一次 -typecheck（不出构建产物），
# 列出最慢的表达式和函数体；有一句表达式超过阈值就非零退出。
#
# 为什么要它（优化分析 2026-11-18 codehealth 复核「漏 1」）：同一份源码，6.1.2 的类型检查比本机 6.3.2 慢 3.3 倍，而且慢在
# 个别表达式上 —— 封面看版的 proofNames 在 6.1.2 上一句 11.9 秒、本机 0.45 秒；CollageItems.bounds 6.1.2 上两遍各 2 秒、本机
# 1 毫秒。本机编译器（连带 -warn-long-expression-type-checking）看不见，CI 上超了就是「unable to type-check this expression in
# reasonable time」，main 10-26 就这样红过两处、红一次白跑二十多分钟。以前的预检是拿 6.1.2 整份 swift build -c release（约
# 3.5 分钟，只看编不编得过）；这里只做类型检查（= 发版 WMO 构建里 Sema 那一段），本机 CPU 一分钟上下，还看得出离超时有多远。
#
# 用法：Scripts/typecheck_612.sh [--limit-ms 3000] [--report-ms 100] [--top 15]
#   --limit-ms   有一句表达式单次超过这么多毫秒就退出码 1（默认 3000）
#   --report-ms  比这慢的表达式才记下来（默认 100，传给 -warn-long-expression-type-checking；不影响类型检查本身）
#   --top        列最慢的几句表达式（默认 15）；函数体固定列 10 个
# 环境变量：
#   TC612        工具链根（底下有 usr/bin/swiftc）。默认 ~/server/bonsai-verify/tc612/expanded/swift-6.1.2-RELEASE-osx-package.pkg/Payload
#                —— swift.org 下 swift-6.1.2-RELEASE-osx.pkg，`pkgutil --expand-full <pkg> <目录>/expanded`。别放 /private/tmp（每晚清）。
#   SDK          默认 /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk（发版 DMG 链用的同一份；CI 是 Xcode 16.4 自带的 15.5）
#   TC612_CACHE  模块缓存和日志放哪，默认 <包>/.build/tc612-typecheck（第一次要现建系统模块缓存，多约 30 秒 CPU）
# 退出码：0 全在阈值以内；1 有表达式超过 --limit-ms；2 工具链 / SDK 不在、类型检查报错、参数不对。
# 说明：
#   - 这是 swift.org 版 6.1.2，不是 Xcode 16.4 里那个二进制：版本号一样，复现过 CI 的超时；个别毫秒数可能有出入，看量级。
#   - 6.1.2 有时对同一句解两遍（同一位置出现两次是真的），按单次最慢的那遍和阈值比。
#   - 墙上时间受机器上别的编译影响；比前后用「用户态 CPU」和「指令数」。
#   - 「编译警告」是 15.x SDK 下的（不算计时那些），和 CI 摘要页上的是同一批；本机默认的 26 SDK 一条都看不到。
#   - 参数照 SwiftPM 发版构建：-swift-version 5、-DSWIFT_PACKAGE、不带 -DDEBUG、目标 macOS 14（Package.swift）。
set -euo pipefail

LIMIT_MS=3000
REPORT_MS=100
TOP=15
while [ $# -gt 0 ]; do
    case "$1" in
        --limit-ms) LIMIT_MS=${2:?}; shift 2 ;;
        --report-ms) REPORT_MS=${2:?}; shift 2 ;;
        --top) TOP=${2:?}; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "不认识的参数：$1（--help 看用法）" >&2; exit 2 ;;
    esac
done
for n in "$LIMIT_MS" "$REPORT_MS" "$TOP"; do
    case "$n" in ''|*[!0-9]*) echo "--limit-ms / --report-ms / --top 要正整数：$n" >&2; exit 2 ;; esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC612="${TC612:-$HOME/server/bonsai-verify/tc612/expanded/swift-6.1.2-RELEASE-osx-package.pkg/Payload}"
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
CACHE="${TC612_CACHE:-$ROOT/.build/tc612-typecheck}"
SWIFTC="$TC612/usr/bin/swiftc"

if [ ! -x "$SWIFTC" ]; then
    echo "找不到 Swift 6.1.2：$SWIFTC" >&2
    echo "  从 swift.org 下 swift-6.1.2-RELEASE-osx.pkg，pkgutil --expand-full 解开，TC612= 指到解出来的 Payload。" >&2
    exit 2
fi
if ! "$SWIFTC" --version 2>&1 | grep -q "Swift version 6\.1\.2"; then
    echo "$SWIFTC 不是 6.1.2：$("$SWIFTC" --version 2>&1 | head -1)" >&2
    exit 2
fi
if [ ! -d "$SDK" ]; then
    echo "找不到 SDK：${SDK}（SDK= 指一个 macOS 15.x 的 SDK）" >&2
    exit 2
fi

mkdir -p "$CACHE/ModuleCache"
LOG="$CACHE/typecheck.log"
TIMES="$CACHE/time.txt"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources/LabelGUI" -name '*.swift' | LC_ALL=C sort)
[ ${#SOURCES[@]} -gt 0 ] || { echo "Sources/LabelGUI 下没有 .swift" >&2; exit 2; }

echo "Swift 6.1.2 整模块类型检查：${#SOURCES[@]} 个文件，SDK $(basename "$SDK")，表达式 ≥ ${REPORT_MS} ms 记下、单次 > ${LIMIT_MS} ms 算超"
# -wmo + -typecheck：驱动只起一个 swift-frontend、没有 primary 文件，就是整模块类型检查。-Onone 只为不做无用功，类型检查和 -O 无关。
rc=0
/usr/bin/time -l -o "$TIMES" "$SWIFTC" -typecheck -wmo \
    -module-name LabelGUI -target arm64-apple-macosx14.0 -sdk "$SDK" -swift-version 5 -DSWIFT_PACKAGE -Onone \
    -module-cache-path "$CACHE/ModuleCache" \
    -Xfrontend -debug-time-function-bodies \
    -Xfrontend -warn-long-expression-type-checking="$REPORT_MS" \
    "${SOURCES[@]}" > "$LOG" 2>&1 || rc=$?

python3 -I - "$LOG" "$TIMES" "$ROOT/Sources/LabelGUI/" "$LIMIT_MS" "$TOP" "$rc" <<'PY'
import re
import sys

log, times, src, limit, top, rc = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
text = open(log, encoding="utf-8", errors="replace").read().splitlines()


def rel(p):
    return p[len(src):] if p.startswith(src) else p


EXPR = re.compile(r"^(?P<loc>/[^:]+:\d+:\d+): warning: expression took (?P<ms>\d+)ms to type-check")
FUNC = re.compile(r"^\s*(?P<ms>[\d.]+)ms\t(?P<loc>/[^\t]+:\d+:\d+)\t(?P<name>.*)$")
DIAG = re.compile(r"^(?P<loc>/[^:]+:\d+:\d+): (?P<kind>warning|error): (?P<msg>.*)$")
exprs, funcs, warns, errs = [], [], [], []
for line in text:
    m = EXPR.match(line)
    if m:
        exprs.append((int(m["ms"]), rel(m["loc"])))
        continue
    m = FUNC.match(line)
    if m:
        # 「static method LabelGUI.(file).类型.函数(_:)@/绝对路径:行:列」→「static method 类型.函数(_:)」
        name = m["name"].split("@/")[0].replace("LabelGUI.(file).", "")
        funcs.append((float(m["ms"]), rel(m["loc"]), name))
        continue
    m = DIAG.match(line)
    if m:
        (warns if m["kind"] == "warning" else errs).append("%s: %s" % (rel(m["loc"]), m["msg"]))

t = open(times, encoding="utf-8", errors="replace").read()
user = re.search(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", t)
ins = re.search(r"(\d+)\s+instructions retired", t)
rss = re.search(r"(\d+)\s+maximum resident set size", t)
print("用时：real %s s、用户态 %s s、sys %s s；指令 %s 亿条；内存峰值 %s MB" % (
    user[1] if user else "?", user[2] if user else "?", user[3] if user else "?",
    "%.0f" % (int(ins[1]) / 1e8) if ins else "?", "%.0f" % (int(rss[1]) / 1e6) if rss else "?"))
print("函数体合计 %.1f s（%d 个，含嵌套的局部函数）" % (sum(f[0] for f in funcs) / 1000, len(funcs)))

# 同一位置可能解两遍：按位置归并，列单次最慢和遍数。
by_loc = {}
for ms, loc in exprs:
    worst, n = by_loc.get(loc, (0, 0))
    by_loc[loc] = (max(worst, ms), n + 1)
ranked = sorted(by_loc.items(), key=lambda kv: -kv[1][0])
print("\n最慢的 %d 句表达式（单次 ms，×遍数）：" % min(top, len(ranked)))
for loc, (ms, n) in ranked[:top]:
    print("  %6d  %s%s%s" % (ms, loc, "  ×%d" % n if n > 1 else "", "  ← 超过 %d" % limit if ms > limit else ""))
if not ranked:
    print("  （没有超过 --report-ms 的）")
print("\n最慢的 10 个函数体（ms）：")
for ms, loc, name in sorted(funcs, key=lambda f: -f[0])[:10]:
    print("  %8.0f  %s  %s" % (ms, loc, name))

print("\n编译警告（不算计时）：%d 条" % len(warns))
for w in warns[:20]:
    print("  " + w)
if len(warns) > 20:
    print("  ……还有 %d 条，全文在 %s" % (len(warns) - 20, log))

over = [loc for loc, (ms, _) in ranked if ms > limit]
if rc != 0 or errs:
    print("\nFAIL 类型检查没过（swiftc 退出码 %d，%d 个错误）：" % (rc, len(errs)))
    for e in errs[:10]:
        print("  " + e)
    if not errs:
        print("\n".join("  " + l for l in text[-30:]))
    sys.exit(2)
if over:
    print("\nFAIL %d 句表达式超过 %d ms：拆成几句、给中间量写明类型（只改写法，行为不变）。" % (len(over), limit))
    sys.exit(1)
print("\nPASS 没有超过 %d ms 的表达式" % limit)
PY
