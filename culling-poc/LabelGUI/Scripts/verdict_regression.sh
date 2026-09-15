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
