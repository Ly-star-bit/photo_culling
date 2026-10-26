#!/bin/bash
# 拼图门禁（CI 不跑：照片不在仓库里）：同一组无头命令重出一遍，和基线逐像素比；水印页的输出逐字节比。
# 只用 --collage / --collage-ops / --watermark 这些无头参数，不开任何界面（ops 里也不跑 export:）。
#
# 用法: Scripts/collage_gate.sh <照片目录> <分析好的数据目录> <基线目录|-> <输出目录> [LabelGUI 可执行文件]
#   数据目录  --analyze 跑过一次的 LABELGUI_DATA_DIR，只读：每次会改状态的运行（--collage 也会改 sessions.json）
#             都先拷一份新的进 <输出目录>/_data，跑完就删。不要重新分析：face_quality 每次分析都不一样，
#             换一份分析结果，挑片、主图、排版都可能变，基线就作废了。
#   基线目录  - = 只出图不比（拍基线用）；否则比 <基线目录> 里 img/ 和 wmpage/ 下的每一个文件。
#   输出目录  不存在就建；已存在必须是这个脚本建的（里面有 .collage_gate），整个清掉重出。
#   可执行文件 默认 .build/release/LabelGUI。
#   GATE_COMPARE_ONLY=1  不出图，拿 <输出目录> 里已有的结果和基线比（两次基线互比、改了比较规则重比）。
#   GATE_IMGDIFF=<路径>  比图工具编译到这里（缺了、或比 Scripts/imgdiff.swift 旧就重编）；默认 <输出目录>/_tools。
#
# 比什么：img/ 下的 PNG/JPG 解码后逐像素比（JPEG 同一台机器同一个编码器，像素一样就是一样）；wmpage/ 逐字节比；
# .marks.json 只卡原来就有的顶层键（scale…items，水印核对用的那些）；S0 起加的 texts/crops/masks/contactSheet/
# halftone 后面的步骤会按设计往里填，不同只报告。info/ 下的出图（全模板总览、
# 色调总览 —— 加模板、加色调必然会变）只报告不算失败。基线里没有的新文件列出来，不算失败。
# 不进门禁的：additem（相纸角度是 Int.random）、相册 PDF（带时间戳）。
# 每次运行都设 LABELGUI_STABLE_SEEDS=1：胶带撕口、圆点条纹按图层 id 定，新撒的图层 id 每次都是新 UUID，
# 不设的话同一个程序跑两次胶带都对不上（AppRuntime.stableSeeds）。不认这个变量的旧程序拍的基线里，
# 这类文件列在 <基线目录>/nondeterministic.txt（一行一个相对路径）：照比，但不同只报告、不算失败。
# 返回 0 = 基线里每个文件都相同、每条命令都成功；1 = 有不同 / 缺文件 / 命令失败 / ops 有跳过的步骤；2 = 用法错。
set -u

if [ $# -lt 4 ]; then
    sed -n '2,22p' "$0"
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHOTO="$(cd "$1" && pwd)" || exit 2
PRISTINE="$(cd "$2" && pwd)" || exit 2
BASE="$3"
OUT="$4"
BIN="${5:-$ROOT/.build/release/LabelGUI}"
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
COMPARE_ONLY="${GATE_COMPARE_ONLY:-}"

[ -f "$PRISTINE/sessions.json" ] || { echo "数据目录 $PRISTINE 里没有 sessions.json：先 --analyze 一次"; exit 2; }
if [ "$BASE" != "-" ]; then
    BASE="$(cd "$BASE" && pwd)" || exit 2
fi
command -v python3 > /dev/null || { echo "要 python3（比 .marks.json、拆模板名单）"; exit 2; }

if [ "$COMPARE_ONLY" != "1" ]; then
    [ -x "$BIN" ] || { echo "没有可执行文件 $BIN"; exit 2; }
    if [ -e "$OUT" ]; then
        [ -f "$OUT/.collage_gate" ] || { echo "输出目录 $OUT 已存在、但不是门禁建的：不清它"; exit 2; }
        rm -rf "$OUT"
    fi
    mkdir -p "$OUT"
    touch "$OUT/.collage_gate"
fi
OUT="$(cd "$OUT" && pwd)" || exit 2
case "$OUT/" in
    "$PRISTINE/"*) echo "输出目录不能在数据目录里面"; exit 2 ;;
esac
[ "$BASE" != "$OUT" ] || { echo "基线目录和输出目录不能是同一个"; exit 2; }

# 比图工具：按需编译。
SRC="$ROOT/Scripts/imgdiff.swift"
IMGDIFF="${GATE_IMGDIFF:-$OUT/_tools/imgdiff}"
if [ ! -x "$IMGDIFF" ] || [ "$SRC" -nt "$IMGDIFF" ]; then
    mkdir -p "$(dirname "$IMGDIFF")"
    swiftc -O "$SRC" -o "$IMGDIFF" || { echo "imgdiff 编译失败"; exit 2; }
fi

FAILS=()

# ---------------------------------------------------------------- 出图

# 新拷一份分析好的数据目录（拷过来的是只读的也要能写）。
fresh() {
    local d="$OUT/_data/$1"
    rm -rf "$d"
    mkdir -p "$OUT/_data"
    cp -R "$PRISTINE" "$d"
    chmod -R u+w "$d"
    echo "$d"
}

# run <名字> <参数…>：在新拷的数据目录里跑一次（工作目录 = 输出目录），输出进 logs/<名字>.log。
run() {
    local name="$1"
    shift
    local data
    data="$(fresh "$name")"
    if ! (cd "$OUT" && LABELGUI_DATA_DIR="$data" LABELGUI_STABLE_SEEDS=1 "$BIN" "$@" > "$OUT/logs/$name.log" 2>&1); then
        FAILS+=("$name（退出码非 0，见 logs/$name.log）")
    fi
    # ops 里写错一步只会打印一行接着跑：门禁里不许有跳过的步骤，不然测的不是写的那些。
    if grep -Eq "^(未知操作|参数不对，跳过)" "$OUT/logs/$name.log"; then
        FAILS+=("$name（ops 有跳过的步骤：$(grep -Em1 "^(未知操作|参数不对，跳过)" "$OUT/logs/$name.log")）")
    fi
    rm -rf "$data"
}

# ops <名字> <输出子目录> <ops 串>
ops() {
    mkdir -p "$OUT/img/$2"
    run "$1" --collage-ops "$PHOTO" --out "$OUT/img/$2" --ops "$3"
}

render_all() {
    mkdir -p "$OUT/logs" "$OUT/img" "$OUT/info" "$OUT/wmpage" "$OUT/inputs"
    local INPUTS="$OUT/inputs"
    "$IMGDIFF" --make-sig "$INPUTS/sig.png" || FAILS+=("签名图生成失败")
    # 自由文字图层带花字投影的用户模板（自带模板和 ops 都给不了图层花字，只能 importtpl）。
    cat > "$INPUTS/fx_template.json" << 'EOF'
[{"name": "门禁花字图层", "category": "门禁", "fitAspects": false,
  "canvas": {"name": "门禁 3:4", "width": 1440, "height": 1920},
  "root": {"axis": "row", "ratio": 0.5, "children": [],
           "cell": {"kind": "photo", "framing": "auto",
                    "overlay": {"anchor": "bottom", "text": {"alignH": "center", "lines": [
                        {"text": "{date}", "font": "futura", "weight": "bold", "size": 0.05, "color": {"r": 1, "g": 1, "b": 1},
                         "effect": {"shadow": 0.6, "shadowBlur": 0.15, "shadowOffset": 0.06}}]}}}},
  "items": [
    {"kind": "text", "cx": 0.5, "cy": 0.16, "width": 0.84, "height": 0.16, "rotation": -4,
     "text": {"alignH": "center", "alignV": "center", "lines": [
         {"text": "门禁 · 投影", "font": "songti", "weight": "bold", "size": 0.09, "color": {"r": 1, "g": 1, "b": 1},
          "effect": {"shadow": 0.55, "shadowBlur": 0.15, "shadowOffset": 0.08}}]}},
    {"kind": "text", "cx": 0.5, "cy": 0.34, "width": 0.7, "height": 0.1, "rotation": 0,
     "text": {"alignH": "center", "alignV": "center", "lines": [
         {"text": "GLOW {year}", "font": "didot", "weight": "bold", "size": 0.06, "color": {"r": 1, "g": 0.95, "b": 0.8},
          "effect": {"shadow": 0.9, "shadowBlur": 0.35, "shadowOffset": 0, "shadowColor": {"r": 1, "g": 0.82, "b": 0.48}}}]}}
  ]}]
EOF
    # 水印页三份设置（--watermark --config）：签名 + EXIF 字、相框参数条、平铺 + 画布比例。
    cat > "$INPUTS/wm1.json" << 'EOF'
{"signatureEnabled": true, "position": "bottom_right", "sizeRatio": 0.18, "opacity": 0.85,
 "tintEnabled": true, "tint": {"r": 255, "g": 255, "b": 255},
 "exifText": {"enabled": true, "position": "bottom_left"}, "maxLongSide": 2400, "quality": 0.9}
EOF
    cat > "$INPUTS/wm2.json" << 'EOF'
{"signatureEnabled": true, "position": "top_left", "sizeRatio": 0.12, "opacity": 0.7,
 "frame": {"enabled": true, "showDivider": true}, "maxLongSide": 2400, "quality": 0.9}
EOF
    cat > "$INPUTS/wm3.json" << 'EOF'
{"signatureEnabled": true, "sizeRatio": 0.1, "opacity": 0.35,
 "tile": {"enabled": true, "angleDeg": 30, "gapRatio": 0.6},
 "canvasRatio": {"enabled": true, "ratioW": 1, "ratioH": 1, "fillColor": {"r": 245, "g": 242, "b": 235}},
 "exifText": {"enabled": true, "customText": "门禁 · 水印页", "position": "bottom_center"},
 "maxLongSide": 2400, "quality": 0.9}
EOF

    echo "== 模板总览（按旧分类）"
    for cat in 小红书封面 日系杂志 中式 九宫格 手账散落 电影感 基础; do
        run "sheet_$cat" --collage "$PHOTO" --auto 6 --template-sheet "$OUT/img/sheet_$cat.jpg" --only "$cat"
    done
    # 全表、色调总览：加模板 / 加色调必然会变，只看不比。
    run sheet_all --collage "$PHOTO" --auto 6 --template-sheet "$OUT/info/sheet_all.jpg"
    run look_sheet --collage "$PHOTO" --auto 6 --look-sheet "$OUT/info/look_sheet.jpg"

    echo "== 每个内置模板（导出尺寸 PNG + 0.4 预览）"
    local list name file
    list="$(LABELGUI_DATA_DIR="$(fresh tpl_list)" LABELGUI_STABLE_SEEDS=1 "$BIN" --collage "$PHOTO" --auto 1 \
        --template "__门禁列模板__" 2>&1 \
        | sed -n 's/^没有模板「__门禁列模板__」：//p')"
    rm -rf "$OUT/_data/tpl_list"
    [ -n "$list" ] || FAILS+=("拿不到内置模板名单")
    printf '%s' "$list" | python3 -I -c 'import sys; print("\n".join(n for n in sys.stdin.read().strip().split(" / ") if n))' \
        > "$OUT/logs/templates.txt"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        file="${name// /}"
        file="${file//\//_}"
        ops "tpl_$file" tpl "applytpl:$name,renderexport:tpl_$file.png,renderclean:tpl_${file}_p.png@0.4"
    done < "$OUT/logs/templates.txt"

    echo "== 样式预设"
    local ids="DSCF7232,DSCF7208,DSCF7222,DSCF7215,DSCF7212,DSCF7214"
    mkdir -p "$OUT/img/style"
    for key in grid white dark editorial chinese film polaroid gallery tinted frosted gradient airy cinema journal cover; do
        run "style_$key" --collage "$PHOTO" --ids "$ids" --style "$key" --overlay masthead --subtitle "门禁 · $key" \
            --out "$OUT/img/style/style_$key.jpg"
    done

    echo "== 色调"
    local lookops=""
    for look in none film airy faded cinema cool mono sepia; do
        lookops+="look:$look,renderexport:look_$look.png,"
    done
    ops looks looks "${lookops}look:faded,strength:0.5,renderexport:look_faded_s05.png,harmonize:0.6,renderexport:look_faded_h06.png"

    echo "== 散落"
    mkdir -p "$OUT/img/scatter"
    for frame in polaroid white none film mounts; do
        run "scatter_$frame" --collage "$PHOTO" --auto 6 --scatter --frame "$frame" --out "$OUT/img/scatter/scatter_$frame.jpg"
    done
    run scatter_stickers --collage "$PHOTO" --auto 5 --scatter --frame polaroid --tilt 8 --tape 0.6 \
        --sticker washi@0.3,0.1,15 --sticker postmark@0.8,0.85,0 --sticker label@0.5,0.95,0 --sticker clip@0.2,0.3,0 \
        --out "$OUT/img/scatter/scatter_stickers.jpg"

    echo "== 相册（--album，只比跨页图）"
    run album --collage "$PHOTO" --album --spreads 4 --out "$OUT/img/album"
    run album_glued25 --collage "$PHOTO" --album --canvas album25 --binding glued --spreads 3 --out "$OUT/img/album_glued25"

    echo "== 切块 / 印刷画布"
    mkdir -p "$OUT/img/split"
    run grid9 --collage "$PHOTO" --auto 9 --canvas grid9 --template "九宫格 · 中心标题" --out "$OUT/img/split/grid9.jpg"
    run carousel --collage "$PHOTO" --auto 3 --canvas carousel3 --title 门禁 --overlay masthead --out "$OUT/img/split/carousel.jpg"
    run a4 --collage "$PHOTO" --auto 4 --canvas a4 --style gallery --title 拾光 --overlay vertical \
        --out "$OUT/img/split/a4.jpg"

    echo "== ops：压字 / 花字 / 文字格"
    ops ops_text text "overlay:00=masthead,effect:00=outline,overlay:11=vertical,effect:11=gold,overlay:100=number,effect:100=shadow,overlay:101=script,effect:101=glow,overlay:010=corner,effect:010=neon,overlay:011=handwrite,effect:011=tape,text:00=bottom,effect:001=pill,subtitle:二〇二六 · 春,renderclean:text_p.png@0.5,renderexport:text_e.png,anchor:100=bottomLeading,overlaytext:000=门禁 · 刊头,overlaypos:11=0.7;0.4,renderclean:text2_p.png@0.35,renderexport:text2_e.png"
    echo "== ops：贴纸 / 文字图层"
    ops ops_items items "sticker:washi,sticker:stripe,sticker:dots,sticker:kraft,sticker:label,sticker:postmark,sticker:clip,itemtext,itemmove:0=0.3;0.2,itemrot:1=20,itemsize:2=1.5,itemmove:7=0.5;0.7,itemfront:0,renderclean:items_p.png@0.5,renderexport:items_e.png"
    echo "== ops：版式 / 形状 / 底"
    ops ops_layout layout "swap:00>11,ratio:0=0.4,shape:010=arch,shape:011=circle,contain:100,containblur:101,framing:11=close,crop:00=0.5;0.4;1.6,renderclean:layout_p.png@0.5,renderexport:layout_e.png,margin:0,bg:blurPhoto,renderexport:layout_blur.png,bg:gradient,renderexport:layout_grad.png"
    echo "== ops：散落 / 九宫格"
    ops ops_scatter scatter "layout:scatter,renderclean:scatter_p.png@0.5,renderexport:scatter_e.png,layout:grid,renderexport:scatter_back.png"
    ops ops_grid9 grid9 "canvas:grid9,autolayout:9,renderclean:grid9_p.png@0.4,renderexport:grid9_e.png"
    echo "== ops：相册跨页"
    ops ops_album album "mode:album,arrange,page:0,renderexport:album_p0.png,page:1,renderclean:album_p1_p.png@0.3,renderexport:album_p1.png,page:2,renderexport:album_p2.png,binding:glued,page:0,renderexport:album_glued_p0.png,page:1,renderexport:album_glued_p1.png"
    echo "== ops：水印两层"
    ops ops_wm wm "wm:photos:$INPUTS/sig.png,wm:page,wmtext:page:拾光 · 门禁,wmpos:page:bottom_center,renderclean:wm_p.png@0.5,renderexport:wm_e.png,wmtile:photos:on,renderexport:wm_tile.png,wmtile:photos:off,mode:album,arrange,page:1,renderclean:wm_album_p.png@0.3,renderexport:wm_album.png"
    echo "== ops：自由文字图层花字投影（S0 修过：预览里的投影按缩放算）"
    ops ops_fxitem fxitem "importtpl:$INPUTS/fx_template.json,applytpl:门禁花字图层,renderclean:fxitem_p.png@0.5,renderclean:fxitem_p25.png@0.25,renderexport:fxitem_e.png"

    echo "== 水印页（逐字节）"
    local i
    for i in 1 2 3; do
        run "wmpage_$i" --watermark "$PHOTO/DSCF7232.JPG" "$OUT/wmpage/wm_$i.jpg" "$INPUTS/sig.png" --config "$INPUTS/wm$i.json"
    done
    run wmpage_portrait --watermark "$PHOTO/DSCF7208.JPG" "$OUT/wmpage/wm_portrait.jpg" "$INPUTS/sig.png" \
        --config "$INPUTS/wm1.json"
    rm -rf "$OUT/_data"
}

if [ "$COMPARE_ONLY" != "1" ]; then
    start=$(date +%s)
    render_all
    echo "出图 $(( $(date +%s) - start ))s → $OUT"
fi

# ---------------------------------------------------------------- 比

if [ "$BASE" = "-" ]; then
    if [ ${#FAILS[@]} -gt 0 ]; then
        printf '!! %s\n' "${FAILS[@]}"
        exit 1
    fi
    echo "只出图（基线目录 = -）：$(cd "$OUT" && find img wmpage info -type f | wc -l | tr -d ' ') 个文件"
    exit 0
fi

REPORT="$OUT/gate_report.txt"
SAME=0
DIFFS=()
MISSING=()
NEWS=()
INFOS=()
UNSTABLE=()
mkdir -p "$OUT/_diff"
NONDET="$BASE/nondeterministic.txt"

# .marks.json：原有的顶层键要相同（退出 1）；新加的那几段不同只报告（退出 3）。
marks_same() {
    python3 -I - "$1" "$2" << 'EOF'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
legacy = {"scale", "includeBleed", "watermark", "image", "canvas", "marks", "obstacles", "items"}
bad = [k for k in sorted(a) if k in legacy and a[k] != b.get(k)]
soft = [k for k in sorted(a) if k not in legacy and a[k] != b.get(k)]
print(",".join(bad or soft))
sys.exit(1 if bad else (3 if soft else 0))
EOF
}

compare_file() {
    local rel="$1" line heat
    case "$rel" in
        *.png|*.jpg|*.jpeg)
            if [ "${rel#wmpage/}" != "$rel" ] && cmp -s "$BASE/$rel" "$OUT/$rel"; then
                SAME=$((SAME + 1))
                return
            fi
            heat="$OUT/_diff/$(echo "$rel" | tr '/' '_').heat.png"
            line="$("$IMGDIFF" "$BASE/$rel" "$OUT/$rel" --heat "$heat")"
            case $? in
                0)
                    if [ "${rel#wmpage/}" != "$rel" ]; then
                        DIFFS+=("$rel  像素相同但字节不同（水印页要逐字节相同）")
                    else
                        SAME=$((SAME + 1))
                    fi ;;
                1)
                    if [ -f "$NONDET" ] && grep -qxF "$rel" "$NONDET"; then
                        UNSTABLE+=("$rel  $line")
                    else
                        DIFFS+=("$rel  $line")
                    fi ;;
                *) DIFFS+=("$rel  读不了：$line") ;;
            esac ;;
        *.marks.json)
            line="$(marks_same "$BASE/$rel" "$OUT/$rel")"
            case $? in
                0) SAME=$((SAME + 1)) ;;
                3) SAME=$((SAME + 1)); INFOS+=("$rel  新加的段变了：$line") ;;
                *) DIFFS+=("$rel  原有的键不同：$line") ;;
            esac ;;
        *)
            if cmp -s "$BASE/$rel" "$OUT/$rel"; then SAME=$((SAME + 1)); else DIFFS+=("$rel  字节不同"); fi ;;
    esac
}

while IFS= read -r rel; do
    if [ ! -f "$OUT/$rel" ]; then
        MISSING+=("$rel")
        continue
    fi
    compare_file "$rel"
done < <(cd "$BASE" && find img wmpage -type f ! -name '.*' | sort)

while IFS= read -r rel; do
    [ -f "$BASE/$rel" ] || NEWS+=("$rel")
done < <(cd "$OUT" && find img wmpage -type f ! -name '.*' | sort)

while IFS= read -r rel; do
    if [ ! -f "$OUT/$rel" ]; then
        INFOS+=("$rel  没出")
    elif ! line="$("$IMGDIFF" "$BASE/$rel" "$OUT/$rel")"; then
        INFOS+=("$rel  $line")
    fi
done < <(cd "$BASE" && [ -d info ] && find info -type f ! -name '.*' | sort)

{
    echo "门禁 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  基线 $BASE"
    echo "  输出 $OUT"
    if [ "$COMPARE_ONLY" = "1" ]; then echo "  程序 —（只比）"; else echo "  程序 $BIN"; fi
    echo "相同 $SAME · 不同 ${#DIFFS[@]} · 缺 ${#MISSING[@]} · 新增 ${#NEWS[@]} · 命令失败 ${#FAILS[@]}"
    [ ${#UNSTABLE[@]} -eq 0 ] || printf '  ~~ 基线本身不稳定（nondeterministic.txt），只报告 %s\n' "${UNSTABLE[@]}"
    [ ${#FAILS[@]} -eq 0 ] || printf '  !! 失败 %s\n' "${FAILS[@]}"
    [ ${#DIFFS[@]} -eq 0 ] || printf '  != %s\n' "${DIFFS[@]}"
    [ ${#MISSING[@]} -eq 0 ] || printf '  -- 缺 %s\n' "${MISSING[@]}"
    if [ ${#NEWS[@]} -gt 0 ]; then
        marks=0
        for rel in "${NEWS[@]}"; do
            case "$rel" in
                *.marks.json) marks=$((marks + 1)) ;;
                *) echo "  ++ 新 $rel" ;;
            esac
        done
        [ $marks -eq 0 ] || echo "  ++ 新 .marks.json $marks 个"
    fi
    [ ${#INFOS[@]} -eq 0 ] || printf '  ~~ 只报告 %s\n' "${INFOS[@]}"
    if [ ${#DIFFS[@]} -gt 0 ]; then echo "  差异图（红 = 不同的像素）在 $OUT/_diff/"; fi
} | tee "$REPORT"

if [ ${#DIFFS[@]} -gt 0 ] || [ ${#MISSING[@]} -gt 0 ] || [ ${#FAILS[@]} -gt 0 ]; then
    echo "门禁不过"
    exit 1
fi
echo "门禁通过"
exit 0
