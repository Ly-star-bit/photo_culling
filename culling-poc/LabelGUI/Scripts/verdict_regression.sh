#!/bin/bash
# 判决层无头回归：把 Fixtures/photot-session 的分析结果（目录不能叫 photot：根 .gitignore 忽略 photot/）（不带图，几十 KB）灌进一个临时
# 数据目录，跑 `LabelGUI --verdicts`，和 expected_verdicts.txt 逐字比对。
# 任何人改分组 / 判决 / 提名逻辑，CI 直接红，不用再靠人肉比 "21·5·15·1"。
#
# 用法: Scripts/verdict_regression.sh <LabelGUI 可执行文件>
#       UPDATE=1 Scripts/verdict_regression.sh <bin>   # 有意改了判决时重写期望值
set -euo pipefail
BIN="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/Fixtures/photot-session"
# 照片文件夹不需要存在：--verdicts 只读 session JSON。路径固定，因为 session key
# 是从它算出来的。
PHOTOS="/tmp/labelgui-fixture-photot"
DATA="$(mktemp -d)"
trap 'rm -rf "$DATA"' EXIT
export LABELGUI_DATA_DIR="$DATA"
KEY="$("$BIN" --session-key "$PHOTOS")"
mkdir -p "$DATA/sessions/$KEY"
cp "$FIX/manifest.json" "$FIX/layer1_results.json" "$DATA/sessions/$KEY/"
"$BIN" --verdicts "$PHOTOS" > "$DATA/actual.txt"
if [ "${UPDATE:-}" = "1" ]; then
    cp "$DATA/actual.txt" "$FIX/expected_verdicts.txt"
    echo "expected_verdicts.txt 已更新："; cat "$FIX/expected_verdicts.txt"
    exit 0
fi
if diff -u "$FIX/expected_verdicts.txt" "$DATA/actual.txt"; then
    echo "判决回归 OK: $(sed -n '2p' "$DATA/actual.txt")"
else
    echo "!! 判决输出和 Fixtures/photot-session/expected_verdicts.txt 不一致。有意改动请 UPDATE=1 重跑。" >&2
    exit 1
fi

# ---------------------------------------------------------------- 合成坏片场次（Fixtures/synthetic-rejects）
# 上面那份 21 张全是好片、按老场次阈值（人脸质量线 0）判：判废的八条理由、组内相对 EAR、复审撤罪名、
# 连拍去重、接受全部推荐在那里一条都走不到。这一份是从同一行 layer1 抄出来改成边界值的（每张测什么见 cases.tsv），
# 带 thresholds.json（标准 45 / 0.15 / 0.30）、layer2、appeal、overrides。每条命令都：
#   1. 用一个全新的数据目录（--accept-all 写 overrides.json、--clear-recents 删场次目录，共用会串）；
#   2. 输出和 expected_<名字>.txt 逐字比对；
#   3. 带 --per-photo 的再按 cases.tsv 逐张核对判决和理由 —— 期望文件是按设计核过的，不是跑出来什么就记什么。
# 去重开关按场次存（thresholds.json 的 rejectBurstDuplicates，审查 S20a）：--dedupe 只在内存里钉成开，不写设置域、
# 不写这一场的 thresholds.json；不带 --dedupe 按这一场存的（这份夹具没存这个键 = 老场次，回落到钉住的全局值：关）。
# 夹具和 cases.tsv 都是 Scripts/gen_synthetic_rejects.py 生成的。有意改了判决：先改那个脚本里的期望、重新生成，
# 再 UPDATE_SYNTH=1 Scripts/verdict_regression.sh <bin>（逐张核对过了才写期望文件）。
SYN="$ROOT/Fixtures/synthetic-rejects"
# 照片文件夹同样不需要存在；路径和 photot 那份不同，key 不撞。
SYN_PHOTOS="/tmp/labelgui-fixture-synthetic"
syn_bad=0

# cases.tsv 第 <列> 列 vs 实际输出里「阈值:」那行后面的逐张行（id 判决 理由）。
syn_check() {
    awk -F'\t' -v col="$2" '
        NR == FNR { if ($1 !~ /^#/ && $1 != "id") want[$1] = $col; next }
        /^阈值: / { per = 1; next }
        per && /^  / { n = split($0, a, " "); got[a[1]] = a[2] " " a[3]; next }
        per { per = 0 }
        END {
            bad = 0
            for (id in want) {
                g = (id in got) ? got[id] : "不在"
                if (g != want[id]) { printf "    %s：期望「%s」，实际「%s」\n", id, want[id], g; bad = 1 }
            }
            for (id in got) if (!(id in want)) { printf "    %s：cases.tsv 里没有这张\n", id; bad = 1 }
            exit bad
        }' "$SYN/cases.tsv" "$1"
}

# syn_run <名字> <cases.tsv 的列，0 = 不逐张核对> <LabelGUI 参数…>
# 每条跑完都核对这一场的 thresholds.json 一个字节都没变（还在的话；--clear-recents 会整场删掉）：--dedupe 只在内存里、
# 不落盘，夹具没存去重这个键（老场次）时无头也不把回落的全局值写回去（审查 S20a）。只对这一条的两个旋钮：
#   SYN_STORED_DEDUPE=true|false  这一场的 thresholds.json 多存一个 rejectBurstDuplicates（按场次存的去重开关）
#   SYN_EXPECT=<名字>              和 expected_<名字>.txt 比（同一组判决换一种设法），UPDATE_SYNTH 时也不改写它
syn_run() {
    local name="$1" col="$2"; shift 2
    local d="$DATA/syn-$name"
    mkdir -p "$d"
    local key
    key="$(LABELGUI_DATA_DIR="$d" LABELGUI_NO_GUI=1 "$BIN" --session-key "$SYN_PHOTOS")"
    mkdir -p "$d/sessions/$key"
    cp "$SYN/manifest.json" "$SYN/layer1_results.json" "$SYN/layer2_results.json" "$SYN/appeal_results.json" \
        "$SYN/thresholds.json" "$SYN/overrides.json" "$d/sessions/$key/"
    if [ -n "${SYN_STORED_DEDUPE:-}" ]; then
        printf '{"sharpness": 45, "exposure": 0.15, "faceQuality": 0.30, "rejectBurstDuplicates": %s}\n' "$SYN_STORED_DEDUPE" \
            > "$d/sessions/$key/thresholds.json"
    fi
    cp "$d/sessions/$key/thresholds.json" "$d/thresholds.before.json"
    # 一场早就掉出「最近」菜单的旧场次（不在 sessions.json 里，只剩人工改判）：--clear-recents 不能顺手删它。
    mkdir -p "$d/sessions/feedfacefeedface"
    printf '{"OLD0001":"精选"}' > "$d/sessions/feedfacefeedface/overrides.json"
    if ! LABELGUI_DATA_DIR="$d" LABELGUI_NO_GUI=1 "$BIN" "$@" > "$d/actual.txt" 2> "$d/stderr.txt"; then
        echo "!! 合成坏片 ${name}：$* 退出码不是 0" >&2
        cat "$d/stderr.txt" >&2
        syn_bad=1
        return
    fi
    if [ "$col" != "0" ] && ! syn_check "$d/actual.txt" "$col" > "$d/check.txt"; then
        echo "!! 合成坏片 ${name}：逐张判决和 cases.tsv 第 $col 列对不上：" >&2
        cat "$d/check.txt" >&2
        syn_bad=1
        return
    fi
    if [ -e "$d/sessions/$key/thresholds.json" ] && ! cmp -s "$d/thresholds.before.json" "$d/sessions/$key/thresholds.json"; then
        echo "!! 合成坏片 ${name}：这一场的 thresholds.json 被改了（命令行钉的去重开关、无头回落的全局值都不该落盘）：" >&2
        diff "$d/thresholds.before.json" "$d/sessions/$key/thresholds.json" >&2
        syn_bad=1
        return
    fi
    local want="$SYN/expected_${SYN_EXPECT:-$name}.txt"
    if [ "${UPDATE_SYNTH:-}" = "1" ] && [ -z "${SYN_EXPECT:-}" ]; then
        cp "$d/actual.txt" "$want"
        echo "expected_$name.txt 已更新"
    elif diff -u "$want" "$d/actual.txt"; then
        echo "合成坏片 $name OK: $(grep -m1 '^照片 ' "$d/actual.txt" || head -1 "$d/actual.txt")"
    else
        echo "!! 合成坏片 ${name}：输出和 Fixtures/synthetic-rejects/expected_${SYN_EXPECT:-$name}.txt 不一致。有意改动请改 cases.tsv 后 UPDATE_SYNTH=1 重跑。" >&2
        syn_bad=1
    fi
}

syn_run per_photo 2 --verdicts "$SYN_PHOTOS" --per-photo
syn_run dedupe 3 --verdicts "$SYN_PHOTOS" --dedupe --per-photo
# 去重开关按场次存：这一场存着开、不带 --dedupe → 和 --dedupe 那份一模一样（按场次读，不看全局）；存着关、带 --dedupe
# → 也一样，跑完这一场的 thresholds.json 逐字节不变（命令行钉的值不落盘）。
SYN_STORED_DEDUPE=true SYN_EXPECT=dedupe syn_run stored_dedupe 3 --verdicts "$SYN_PHOTOS" --per-photo
SYN_STORED_DEDUPE=false SYN_EXPECT=dedupe syn_run pinned_dedupe 3 --verdicts "$SYN_PHOTOS" --dedupe --per-photo
syn_run accept_all 4 --verdicts "$SYN_PHOTOS" --accept-all --per-photo
# 连拍挑选的按键脚本（和界面同一个 PickSession）：选第 3 张、⏎ 定下一组、⌘ 点多留一张、全留、撤销、方向键 + 空格……
# 每一步的草稿和 ⏎ 会怎么定都打出来，逐字比对。它不带 --dedupe，去重按这一场存的（没存 = 关）。
# ⏎ 写 overrides.json：只在这个临时数据目录里。
syn_run compare 0 --compare "$SYN_PHOTOS" --keys "3,enter,cmd:C03-q056,enter,keepall,enter,undo,right,space,enter"
# 接受全部推荐、撤销一次，判决回到默认那一列；再「全部清除」最近场次
# （列在菜单里的这一场整份删，掉出菜单的 feedfacefeedface 留着）。
syn_run accept_undo 2 --verdicts "$SYN_PHOTOS" --accept-all --undo --per-photo --clear-recents
if [ "$syn_bad" != "0" ]; then
    exit 1
fi
