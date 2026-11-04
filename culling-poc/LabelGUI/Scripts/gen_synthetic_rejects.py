"""生成 Fixtures/synthetic-rejects/（判决回归的合成坏片场次）：从 photot-session 抄 DSCF7207 那一行 manifest / layer1，
改成边界值 —— 判废的八条理由各自的边界两侧、组内相对 EAR、合影小脸、复审撤罪名（和撤不了的）、老结果的退路、
连拍去重、场内提名、人工改判、整章全灭。不要照片，不跑分析。

cases.tsv 是每张的设计（测什么、三种跑法下期望的判决和理由），Scripts/verdict_regression.sh 拿它逐张核对
--per-photo 的输出，再和 expected_*.txt 逐字比对。改夹具：改这个脚本，跑
    python3 -I Scripts/gen_synthetic_rejects.py
再 UPDATE_SYNTH=1 Scripts/verdict_regression.sh <LabelGUI>（逐张核对过了才写期望文件）。"""
import copy, json, os, sys
from datetime import datetime, timedelta

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # culling-poc/LabelGUI
FIX = os.path.join(ROOT, "Fixtures", "photot-session")
OUT = os.path.join(ROOT, "Fixtures", "synthetic-rejects")
PHOTOS = "/tmp/labelgui-fixture-synthetic"

man = json.load(open(os.path.join(FIX, "manifest.json")))
l1 = json.load(open(os.path.join(FIX, "layer1_results.json")))
base_m = next(p for p in man["photos"] if p["id"] == "DSCF7207")
base_l = next(r for r in l1["results"] if r["id"] == "DSCF7207")

T0 = datetime(2026, 3, 21, 10, 0, 0)
rows = []      # (id, time, layer1 patch, extra)
cases = []     # (id, 测什么, 默认, 去重, 接受推荐后)
layer2 = []
appeal = []
overrides = {}
group = [0]


def face(ear=0.36, area=0.0084, full_res=False, eye_closed=False):
    f = copy.deepcopy(base_l["faces"][0])
    f.update({"ear": ear, "area_pct": area, "ear_full_res": full_res, "eye_closed": eye_closed})
    return f


def add(pid, t, what, default, dedupe=None, accept=None, patch=None, new_group=True, drop=()):
    if new_group:
        group[0] += 1
    r = copy.deepcopy(base_l)
    r["id"] = pid
    r["capture_time"] = t.strftime("%Y-%m-%dT%H:%M:%S")
    r["capture_subsec"] = 0.0
    r["burst_group"] = group[0]
    for k, v in (patch or {}).items():
        r[k] = v
    if "faces" in (patch or {}) and patch["faces"] and "face_area_pct" not in patch:
        r["face_area_pct"] = patch["faces"][0].get("area_pct")
    for k in drop:
        r.pop(k, None)
    m = copy.deepcopy(base_m)
    m["id"] = pid
    m["capture_time"] = r["capture_time"]
    m["raw_path"] = m["decode_path"] = f"{PHOTOS}/{pid}.JPG"
    m["preview_path"] = f"previews/{pid}.jpg"
    rows.append((m, r))
    cases.append((pid, what, default, dedupe or default, accept or default))


def appeal_row(pid, closed_eyes=None, subject_sharp=None, intentional_exposure=None, error=None):
    appeal.append({"id": pid, "closed_eyes": closed_eyes, "subject_sharp": subject_sharp,
                   "intentional_exposure": intentional_exposure, "expression_score": None,
                   "reason": "合成夹具", "error": error})


def vlm_row(pid, error=None):
    layer2.append({"id": pid, "closed_eyes": False, "composition_issues": [], "expression_score": None,
                   "reject_recommended": True, "confidence": 0.9, "reason": "合成夹具", "error": error})


t = T0
step = timedelta(seconds=20)
NOFACE = {"faces": [], "face_found": False, "face_count": 0, "face_quality": None, "face_area_pct": None,
          "face_bbox": None, "face_luma": None, "eye_closed": None, "blink_score": None, "sharpness_scope": "whole"}

single = [
    ("A01-ok", "对照：原样抄 DSCF7207", "可用 -", {}),
    ("A02-sharp44", "锐度 44 < 线 45", "废片 虚焦", {"sharpness": 44.0}),
    ("A03-sharp45", "锐度正好 45：不判（< 才判）", "可用 -", {"sharpness": 45.0}),
    ("A04-under-face70-p99-90", "欠曝：脸 70 < 80 且整张 p99 90 < 100", "废片 欠曝", {"face_luma": 70, "frame_luma_p99": 90}),
    ("A05-under-p99-100", "脸 70 但 p99 正好 100：不判（画面里有亮的）", "可用 -", {"face_luma": 70, "frame_luma_p99": 100}),
    ("A06-under-face80", "脸正好 80、p99 90：不判（< 80 才判）", "可用 -", {"face_luma": 80, "frame_luma_p99": 90}),
    ("A07-over-face240", "过曝：脸正好 240（≥ 240 判）", "废片 过曝", {"face_luma": 240}),
    ("A08-over-face239", "脸 239：不判", "可用 -", {"face_luma": 239}),
    ("A09-clip-subject20", "主体高光裁切 0.2 ≥ 0.15", "废片 曝光裁切", {"subject_highlight_clip_pct": 0.2}),
    ("A10-clip-whole-only", "整张裁切 0.5 但主体只有 0.01：按主体，不判", "可用 -",
     {"highlight_clip_pct": 0.5, "subject_highlight_clip_pct": 0.01}),
    ("A11-clip-shadow15", "主体暗部裁切正好 0.15（≥ 判）", "废片 曝光裁切", {"subject_shadow_clip_pct": 0.15}),
    ("A12-ear005", "EAR 0.05、脸 0.4%：单张，地板 0.08 和单张线 0.15 都判（只有地板判得出的见 X 组）", "废片 闭眼",
     {"faces": [face(0.05, 0.004)]}),
    ("A13-ear005-tiny", "EAR 0.05 但脸 0.2% < 0.3%：太小免检", "可用 -", {"faces": [face(0.05, 0.002)]}),
    ("A14-ear018-single", "单张 EAR 0.18 ≥ 单张线 0.15：睁眼", "可用 -", {"faces": [face(0.18, 0.004)]}),
    ("A15-ear014-single", "单张 EAR 0.14 < 单张线 0.15：闭眼", "废片 闭眼", {"faces": [face(0.14, 0.004)]}),
    ("A16-fullres-closed-appeal", "合影小脸原图 EAR 0.05（ear_full_res、脸 0.1%）+ 复审说没闭眼：复审撤不了", "废片 闭眼",
     {"faces": [face(0.05, 0.001, full_res=True)]}),
    ("A17-fullres-tiny", "原图量的脸 0.04% < 0.05%：免检", "可用 -", {"faces": [face(0.05, 0.0004, full_res=True)]}),
    ("A18-appeal-eyes", "EAR 0.05 闭眼 + 复审 closed_eyes=false：撤掉", "可用 -", {"faces": [face(0.05, 0.004)]}),
    ("A19-appeal-sharp", "锐度 30 + 复审 subject_sharp=true：撤掉", "可用 -", {"sharpness": 30.0}),
    ("A20-appeal-partial", "锐度 30 + 主体裁切 0.2，复审只撤虚焦：剩曝光裁切", "废片 曝光裁切",
     {"sharpness": 30.0, "subject_highlight_clip_pct": 0.2}),
    ("A21-appeal-lowkey", "欠曝 + 复审 intentional_exposure=true：撤掉", "可用 -", {"face_luma": 70, "frame_luma_p99": 90}),
    ("A22-appeal-highkey", "过曝 + 复审 intentional_exposure=true：撤掉", "可用 -", {"face_luma": 245}),
    ("A23-appeal-error", "锐度 30 + 复审 subject_sharp=true 但 error 不为空：这条复审不算", "废片 虚焦", {"sharpness": 30.0}),
    ("A24-q-single-low", "单张人脸质量 0.10，脸 0.84%（景别放宽后线约 0.139）", "废片 人脸质量低", {"face_quality": 0.10}),
    ("A25-q-closeup", "特写（脸 12%）人脸质量 0.25 < 0.30", "废片 人脸质量低",
     {"face_quality": 0.25, "faces": [face(0.36, 0.12)]}),
    ("A26-q-wide", "远景（脸 0.4%）人脸质量 0.25 ≥ 放宽后的 0.133", "可用 -",
     {"face_quality": 0.25, "faces": [face(0.36, 0.004)]}),
    ("A27-vlm", "layer2 reject_recommended=true", "废片 VLM建议淘汰", {}),
    ("A28-vlm-error", "layer2 reject_recommended=true 但 error 不为空：不算", "可用 -", {}),
    ("A29-multi", "七条理由一起，看顺序", "废片 文件损坏,闭眼,虚焦,曝光裁切,过曝,人脸质量低,VLM建议淘汰",
     {"file_corrupt": True, "faces": [face(0.05, 0.004)], "sharpness": 30.0, "subject_highlight_clip_pct": 0.2,
      "face_luma": 245, "face_quality": 0.05}),
    ("A30-noface-dark", "没有脸：整张中位数 30 < 40 且 p99 90 < 100", "废片 欠曝",
     dict(NOFACE, frame_luma=30, frame_luma_p99=90)),
    ("A31-noface-dark-p99", "没有脸：整张 30 但 p99 115（有亮的）", "可用 -", dict(NOFACE, frame_luma=30, frame_luma_p99=115)),
    ("A32-noface-white", "没有脸整张死白：只判曝光裁切，不判过曝（过曝只看脸）", "废片 曝光裁切",
     dict(NOFACE, frame_luma=250, frame_luma_p99=255, highlight_clip_pct=0.9, subject_highlight_clip_pct=0.9)),
    ("A33-legacy-no-p99", "老结果：没有 p99 / 主体裁切，脸 30 不判欠曝，整张裁切 0.2 判曝光裁切", "废片 曝光裁切",
     {"face_luma": 30, "highlight_clip_pct": 0.2}),
    ("A34-legacy-eye", "老结果：脸上没有 EAR，用烘进去的 eye_closed=true", "废片 闭眼",
     {"eye_closed": True, "faces": [{"bbox": base_l["faces"][0]["bbox"], "eye_closed": True}]}),
]
for pid, what, default, patch in single:
    drop = ()
    if pid == "A33-legacy-no-p99":
        drop = ("frame_luma_p99", "subject_highlight_clip_pct", "subject_shadow_clip_pct")
    add(pid, t, what, default, patch=patch, drop=drop)
    t += step

appeal_row("A16-fullres-closed-appeal", closed_eyes=False)
appeal_row("A18-appeal-eyes", closed_eyes=False)
appeal_row("A19-appeal-sharp", subject_sharp=True)
appeal_row("A20-appeal-partial", subject_sharp=True)
appeal_row("A21-appeal-lowkey", intentional_exposure=True)
appeal_row("A22-appeal-highkey", intentional_exposure=True)
appeal_row("A23-appeal-error", subject_sharp=True, error="timeout")
vlm_row("A27-vlm")
vlm_row("A28-vlm-error", error="timeout")
vlm_row("A29-multi")

# B：组内相对 EAR（同一 burst_group，组里最好 0.30 → 线 0.21）。0.18 单张算睁眼（见 A14），组里算闭眼。
t = T0 + timedelta(minutes=12)
add("B01-ear030", t, "组内相对 EAR：最好的一张 0.30（去重后场里只剩它一张，不提名）", "精选 -", dedupe="可用 -",
    patch={"faces": [face(0.30, 0.004)], "face_quality": 0.62})
add("B02-ear018-rel", t + timedelta(seconds=1), "组内 0.18 < 0.30×0.7=0.21：闭眼（单张就不判，见 A14）", "废片 闭眼",
    patch={"faces": [face(0.18, 0.004)], "face_quality": 0.61}, new_group=False)
add("B03-ear0215", t + timedelta(seconds=2), "组内 0.215 ≥ 0.21：睁眼", "可用 -", dedupe="废片 连拍重复", accept="废片 -",
    patch={"faces": [face(0.215, 0.004)], "face_quality": 0.60}, new_group=False)

# C：组内人脸质量（同一 burst_group，比最好的低 0.15 以上才判）。
t = T0 + timedelta(minutes=12, seconds=30)
add("C01-q070", t, "组内人脸质量最好 0.70（去重后场里只剩它一张，不提名）", "精选 -", dedupe="可用 -",
    patch={"face_quality": 0.70})
add("C02-q050", t + timedelta(seconds=1), "组内 0.50 比最好的低 0.20 > 0.15：人脸质量低", "废片 人脸质量低",
    patch={"face_quality": 0.50}, new_group=False)
add("C03-q056", t + timedelta(seconds=2), "组内 0.56 只低 0.14：不判", "可用 -", dedupe="废片 连拍重复", accept="废片 -",
    patch={"face_quality": 0.56}, new_group=False)

# D：连拍去重 + 人工改判（同一 burst_group）。D03 人工标了可用：去重、接受推荐都不碰它。
t = T0 + timedelta(minutes=13)
add("D01-q066", t, "近似重复组里没赢的", "可用 -", dedupe="废片 连拍重复", accept="废片 -", patch={"face_quality": 0.66})
add("D02-q068", t + timedelta(seconds=1), "近似重复组里人脸质量最好：精选", "精选 -", patch={"face_quality": 0.68},
    new_group=False)
add("D03-manual-usable", t + timedelta(seconds=2), "人工标可用：去重、接受推荐都不动", "可用 -",
    patch={"face_quality": 0.64}, new_group=False)
add("D04-blur", t + timedelta(seconds=3), "同组虚焦的：已经是废片，去重不再加「连拍重复」", "废片 虚焦",
    patch={"face_quality": 0.65, "sharpness": 30.0}, new_group=False)
overrides["D03-manual-usable"] = "可用"

# E：同一场、不同近似重复组：去重不动（去重只看 burst_group），接受推荐照样动。
t = T0 + timedelta(minutes=13, seconds=30)
add("E01-take-best", t, "同一场两张、不是近似重复：场内最好的提名精选", "精选 -", patch={"face_quality": 0.62})
add("E02-take-other", t + timedelta(seconds=3), "同一场、另一个近似重复组：去重不动，接受推荐变废片", "可用 -",
    accept="废片 -", patch={"face_quality": 0.60})

# F：场里有人工精选：不再自动提名。
t = T0 + timedelta(minutes=14)
add("F01-take-auto", t, "场里有人工精选：这张不提名", "可用 -", accept="废片 -", patch={"face_quality": 0.70})
add("F02-manual-pick", t + timedelta(seconds=3), "人工精选", "精选 -", patch={"face_quality": 0.60})
overrides["F02-manual-pick"] = "精选"

# M：人工改判压过阈值。
t = T0 + timedelta(minutes=14, seconds=30)
add("M01-manual-keep-blur", t, "锐度 30 但人工标可用：判决可用，理由照记", "可用 虚焦", patch={"sharpness": 30.0})
add("M02-manual-reject", t + timedelta(seconds=20), "没有理由、人工标废片：「滑杆漏掉」数到它", "废片 -")
overrides["M01-manual-keep-blur"] = "可用"
overrides["M02-manual-reject"] = "废片"

# X：EAR 绝对地板 0.08（同一 burst_group，整组都在眨眼）。组里最好的 0.07 → 相对线 0.049，两张按组内相对都算睁眼、
# 又是组（不走单张线 0.15）：只有地板判得出闭眼。A12 那种单张的 0.05 地板去掉了单张线照样判，测不到地板。
# 放在 M02 之后 10 s（> 8 s，自成一场）、还在第一章里。
t = T0 + timedelta(minutes=15)
add("X01-ear007-floor", t, "组内最好 0.07 < 地板 0.08：闭眼（相对线 0.049 算睁眼，只有地板判）", "废片 闭眼",
    patch={"faces": [face(0.07, 0.004)]})
add("X02-ear005-floor", t + timedelta(seconds=1), "组内 0.05 ≥ 相对线 0.049，< 地板 0.08：闭眼（只有地板判）", "废片 闭眼",
    patch={"faces": [face(0.05, 0.004)]}, new_group=False)

# Z：第二章（隔 1 小时 45 分），全是废片 → 章节警告。Z03 的 layer1 带 error：不进网格。
t = T0 + timedelta(hours=2)
add("Z01-corrupt", t, "file_corrupt=true", "废片 文件损坏", patch={"file_corrupt": True})
add("Z02-ch2-blur", t + timedelta(seconds=20), "第二章另一张虚焦：这一章全灭", "废片 虚焦", patch={"sharpness": 20.0})
add("Z03-l1-error", t + timedelta(seconds=40), "layer1 这一行带 error：不进网格（照片数不算它）", "不在", patch={"error": "decode failed"})

os.makedirs(OUT, exist_ok=True)


def dump(name, obj):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")


dump("manifest.json", {"photo_dir": PHOTOS, "photos": [m for m, _ in rows]})
l1o = {k: v for k, v in l1.items() if k != "results"}
l1o["results"] = [r for _, r in rows]
dump("layer1_results.json", l1o)
dump("layer2_results.json", {"results": layer2})
dump("appeal_results.json", {"results": appeal})
dump("thresholds.json", {"sharpness": 45, "exposure": 0.15, "faceQuality": 0.30})
dump("overrides.json", overrides)
with open(os.path.join(OUT, "cases.tsv"), "w", encoding="utf-8") as f:
    f.write("# 每张测什么、期望（判决 理由）：--per-photo / --dedupe --per-photo / --accept-all --per-photo。"
            "verdict_regression.sh 逐张核对；「不在」= 不进网格。\n")
    f.write("id\t默认\t去重\t接受推荐后\t测什么\n")
    for pid, what, d, dd, a in cases:
        f.write(f"{pid}\t{d}\t{dd}\t{a}\t{what}\n")
print(len(rows), "photos")
