#!/usr/bin/env python3
"""交付对照回归：导出 JPG / 精华 Top N / 水印页写出去的文件名记进这一场的 exports.json，
「导入客户选择」按交付文件名（01_DSCF7208、DSCF7207_wm、20260321_002）认回原片，认不准的照实列出来、不猜。

用法: python3 -I delivery_ledger_regression.py <LabelGUI 可执行文件> [工作目录]
照片是 sips 合成的小 JPEG（不用真照片），分析结果用 Fixtures/photot-session（前 8 张）。每次调用都带临时数据目录、
LABELGUI_NO_GUI=1、测试自己的 socket 根目录和 MCP 输出目录；工作目录不给就用临时目录，跑完删掉。
"""
import json, os, random, shutil, struct, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1])
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "Fixtures", "photot-session")
WORK = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="delivery-ledger-")
CLEANUP = len(sys.argv) <= 2
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
SOCK = tempfile.mkdtemp(prefix="dl-sock-")
MCP_OUT = os.path.join(WORK, "mcp-out")
os.makedirs(MCP_OUT)
SHOOT = os.path.join(WORK, "shoot")
failures = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


def env(data):
    return dict(os.environ, LABELGUI_DATA_DIR=data, LABELGUI_NO_GUI="1", LABELGUI_LIVE_SOCK_ROOT=SOCK,
                LABELGUI_MCP_OUT=MCP_OUT)


def run(data, *args, quiet=False):
    r = subprocess.run([BIN, *args], env=env(data), capture_output=True, text=True, timeout=300, cwd=WORK,
                       stdin=subprocess.DEVNULL)
    if not quiet:
        print("    $ " + " ".join(os.path.basename(a) if a.startswith(WORK) else a for a in args))
        print("    " + r.stdout.strip().replace("\n", "\n    "))
        if r.stderr.strip():
            print("    [stderr] " + r.stderr.strip()[-400:])
    return r


def make_jpeg(path, w, h, seed):
    """24 位 BMP（四色块 + 噪声）→ sips 转 JPEG。"""
    rnd = random.Random(seed)
    rb = w * 3
    pad = (4 - rb % 4) % 4
    body = bytearray()
    for y in range(h):
        base = (200, 60, 40) if y < h // 2 else (40, 180, 40)
        row = bytes(c for x in range(w) for c in ((base[0] + rnd.randrange(16)) % 256, base[1], base[2]))
        body += row + b"\0" * pad
    bmp = path + ".bmp"
    hdr = struct.pack("<2sIHHI", b"BM", 54 + len(body), 0, 0, 54)
    hdr += struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(body), 2835, 2835, 0, 0)
    with open(bmp, "wb") as f:
        f.write(hdr + body)
    r = subprocess.run(["sips", "-s", "format", "jpeg", bmp, "--out", path], capture_output=True)
    os.unlink(bmp)
    if r.returncode != 0 or not os.path.isfile(path):
        print("sips 转不出 JPEG：合成图做不出来")
        sys.exit(2)


# ---- 合成场次：照片文件夹 + 分析结果（fixture 的 manifest / layer1，路径换成合成图）----
man = json.load(open(os.path.join(FIX, "manifest.json")))
l1 = json.load(open(os.path.join(FIX, "layer1_results.json")))
PHOTOS = man["photos"][:8]
IDS = [p["id"] for p in PHOTOS]
os.makedirs(SHOOT)
for i, p in enumerate(PHOTOS):
    make_jpeg(os.path.join(SHOOT, p["id"] + ".JPG"), 360, 240, seed=i)
r = run(os.path.join(WORK, "data-key"), "--session-key", SHOOT, quiet=True)
KEY = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
if len(KEY) != 16:
    print(f"--session-key 算不出 key：{r.stdout!r} {r.stderr[-300:]!r}")
    sys.exit(2)


def make_data(name, shoot=SHOOT, key=KEY, rename=None):
    """`rename`：fixture 的 id → 这一场的 id（照片文件名跟着它，见 I 段）；不给就照 fixture。"""
    rename = rename or {}
    data = os.path.join(WORK, name)
    sdir = os.path.join(data, "sessions", key)
    os.makedirs(os.path.join(sdir, "previews"))
    rows = []
    for p in PHOTOS:
        q = dict(p)
        q["id"] = rename.get(p["id"], p["id"])
        q["raw_path"] = q["decode_path"] = os.path.join(shoot, q["id"] + ".JPG")
        q["preview_path"] = f"previews/{q['id']}.jpg"
        q["body_serial"] = "SYN0001"
        shutil.copyfile(q["raw_path"], os.path.join(sdir, "previews", q["id"] + ".jpg"))
        rows.append(q)
    json.dump({"photo_dir": shoot, "photos": rows}, open(os.path.join(sdir, "manifest.json"), "w"), ensure_ascii=False)
    l1o = dict(l1)
    l1o["results"] = [dict(x, id=rename.get(x["id"], x["id"])) for x in l1["results"] if x["id"] in IDS]
    json.dump(l1o, open(os.path.join(sdir, "layer1_results.json"), "w"), ensure_ascii=False)
    return data, os.path.join(sdir, "exports.json")


def ledger(path):
    return json.load(open(path)) if os.path.isfile(path) else []


def only_jpgs(folder):
    names = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
    return bool(names) and all(n.endswith(".jpg") for n in names)


def client_import(data, text, shoot=SHOOT):
    path = os.path.join(WORK, "reply.txt")
    with open(path, "w") as f:
        f.write(text)
    r = run(data, "--client-import", shoot, "--text", path)
    lines = r.stdout.splitlines()
    got = next((l[len("认出: "):] for l in lines if l.startswith("认出: ")), "-")
    miss = next((l[len("没认出: "):] for l in lines if l.startswith("没认出: ")), "-")
    return ([] if got == "-" else got.split(" ")), ([] if miss == "-" else miss.split(" | "))


ORIGINAL = {p["id"]: os.path.join(SHOOT, p["id"] + ".JPG") for p in PHOTOS}
DAY = {p["id"]: p["capture_time"][:10].replace("-", "") for p in PHOTOS}
DATA, LEDGER = make_data("data")

print("A. 还没导出过：交付文件名认不出（和以前一样列在没认出里）")
got, miss = client_import(DATA, "01_DSCF7208.jpg\nDSCF7207_wm\n")
check(got == [] and miss == ["01_DSCF7208.jpg", "DSCF7207_wm"], f"认出 {got} · 没认出 {miss}")
check(not os.path.exists(LEDGER), "还没有 exports.json")

print("B. 导出 JPG（默认 {原名}）")
out_jpg = os.path.join(WORK, "out-jpg")
r = run(DATA, "--export-jpeg", SHOOT, "--dest", out_jpg, "--size", "long:200")
recs = ledger(LEDGER)
check(r.returncode == 0 and len(recs) == 1, f"退出码 0、exports.json 1 次（{len(recs)}）")
jpg = recs[-1] if recs else {"files": []}
check(jpg.get("kind") == "jpeg" and os.path.realpath(jpg.get("folder", "")) == os.path.realpath(out_jpg),
      f"kind=jpeg、folder 是导出文件夹（{jpg.get('kind')} {jpg.get('folder')}）")
check(len(jpg["files"]) >= 2 and all(f["file"] == f["id"] + ".jpg" for f in jpg["files"]),
      f"{len(jpg['files'])} 张，文件名 = 原名.jpg")
check(all(f["original"] == ORIGINAL.get(f["id"]) for f in jpg["files"]), "original 是原片路径")
check(sorted(f["file"] for f in jpg["files"]) == sorted(os.listdir(out_jpg)), "记的就是文件夹里写出的那些")
check(only_jpgs(out_jpg), "导出文件夹里只有 JPG（对照不写进要发给客户的文件夹）")

print("C. 精华 Top 3（默认 {名次:2}_{原名}）")
out_hl = os.path.join(WORK, "out-hl")
r = run(DATA, "--export-jpeg", SHOOT, "--dest", out_hl, "--scope", "top:3", "--size", "long:200")
recs = ledger(LEDGER)
hl = recs[-1] if recs else {"files": []}
check(r.returncode == 0 and len(recs) == 2 and hl.get("kind") == "highlights", f"第 2 次、kind=highlights（{len(recs)}）")
check([f["file"] for f in hl["files"]] == [f"{i + 1:02d}_{f['id']}.jpg" for i, f in enumerate(hl["files"])]
      and len(hl["files"]) == 3, f"按名次记：{[f['file'] for f in hl['files']]}")
hl_dir = hl.get("folder", "")
check(os.path.dirname(os.path.realpath(hl_dir)) == os.path.realpath(out_hl) and only_jpgs(hl_dir),
      f"folder 是新建的 TopN_… 子文件夹、里面只有 JPG（{os.path.basename(hl_dir)}）")

print("D. 自定义模板 {日期}_{序号:3}，同一个文件夹再导一次（另存 -2）")
out_seq = os.path.join(WORK, "out-seq")
run(DATA, "--export-jpeg", SHOOT, "--dest", out_seq, "--scope", "picks", "--name", "{日期}_{序号:3}", "--size", "long:200")
r = run(DATA, "--export-jpeg", SHOOT, "--dest", out_seq, "--scope", "picks", "--name", "{日期}_{序号:3}", "--size", "long:200")
recs = ledger(LEDGER)
seq, seq2 = (recs[-2], recs[-1]) if len(recs) >= 4 else ({"files": []}, {"files": []})
check(r.returncode == 0 and len(recs) == 4, f"第 3、4 次（{len(recs)}）")
check([f["file"] for f in seq["files"]] == [f"{DAY[f['id']]}_{i + 1:03d}.jpg" for i, f in enumerate(seq["files"])],
      f"第一次：{[f['file'] for f in seq['files']]}")
check([f["file"] for f in seq2["files"]] == [f"{DAY[f['id']]}_{i + 1:03d}-2.jpg" for i, f in enumerate(seq2["files"])]
      and [f["id"] for f in seq2["files"]] == [f["id"] for f in seq["files"]],
      f"第二次照实记 -2：{[f['file'] for f in seq2['files']]}")

print("E. 水印页批量导出（{原名}_wm）；拍摄文件夹外面同名的照片不记")
out_wm = os.path.join(WORK, "out-wm")
r = run(DATA, "--watermark-batch", SHOOT, out_wm, "--exif")
recs = ledger(LEDGER)
wm = recs[-1] if recs else {"files": []}
check(r.returncode == 0 and len(recs) == 5 and wm.get("kind") == "watermark", f"第 5 次、kind=watermark（{len(recs)}）")
check(sorted((f["file"], f["id"]) for f in wm["files"]) == sorted((i + "_wm.jpg", i) for i in IDS),
      f"8 张都按原图对回这一场：{[f['file'] for f in wm['files']][:3]}…")
check(all(f["original"] == ORIGINAL[f["id"]] for f in wm["files"]), "original 是原片路径")
other = os.path.join(WORK, "other-day")
os.makedirs(other)
make_jpeg(os.path.join(other, IDS[0] + ".JPG"), 360, 240, seed=99)     # 别的日子、同名的另一张
r = run(DATA, "--watermark-batch", other, os.path.join(WORK, "out-wm-other"), "--exif", "--session", SHOOT)
check(r.returncode == 0 and len(ledger(LEDGER)) == 5 and "没记" in r.stdout,
      "批量页开着这一场、水印页导的是别处同名的文件：不记（按文件本身对，不按文件名猜）")
if os.geteuid() == 0:
    print("  SKIP 水印页对照写不进去（root 跑时 chmod 挡不住读）")
else:
    before = open(LEDGER, "rb").read()
    os.chmod(LEDGER, 0)
    try:
        r = run(DATA, "--watermark-batch", SHOOT, os.path.join(WORK, "out-wm-locked"), "--exif")
    finally:
        os.chmod(LEDGER, 0o644)
    check(r.returncode == 1 and "没记下" in r.stdout and "读不出来" in r.stdout and "不在分析过的场次里" not in r.stdout
          and open(LEDGER, "rb").read() == before,
          f"水印页这次的对照没记进去（exports.json 读不出来）：退出码 1、说原因，不说成「不在分析过的场次里」（{r.returncode}）")

print("F. 导入客户选择：按交付文件名认回原片")
h0, h1 = hl["files"][0]["id"], hl["files"][1]["id"]
rest = [i for i in IDS if i not in {h0, h1}]
got, miss = client_import(DATA, "\n".join([
    hl["files"][0]["file"],                  # 01_DSCFxxxx.jpg
    hl["files"][1]["file"][:-4],             # 02_DSCFxxxx（不带扩展名）
    rest[0] + "_wm.jpg",
    rest[1].lower() + "_WM",                 # 大小写不论
    rest[2] + "-修.jpg",                     # 精修师改的名：不是我们导出的
    "99_DSCF0000.jpg",                       # 没导出过
]) + "\n")
check(got == [h0, h1, rest[0], rest[1]], f"精华名次名、水印 _wm 名认回原片：{got}（应为 {[h0, h1, rest[0], rest[1]]}）")
check(miss == [rest[2] + "-修.jpg", "99_DSCF0000.jpg"], f"改过名的、没导出过的照实列出：{miss}")
s1, s2 = seq["files"][1], seq2["files"][0]
got, miss = client_import(DATA, s1["file"] + "\n" + s2["file"][:-4] + "\n")
check(got == [s1["id"], s2["id"]] and s1["id"] != s2["id"] and miss == [],
      f"自定义模板名（含另存的 -2）：{s1['file']} → {got[:1]}，{s2['file'][:-4]} → {got[1:]}")

print("G. 纯数字的交付名（{序号:3}）：带扩展名按文件名认；不带扩展名和确认表编号指的不是同一张 = 不猜")
out_num = os.path.join(WORK, "out-num")
r = run(DATA, "--export-jpeg", SHOOT, "--dest", out_num, "--scope", "picks+usable", "--name", "{序号:3}", "--size", "long:200")
num = ledger(LEDGER)[-1]
a, b, c = (num["files"][i]["id"] for i in range(3))
check(r.returncode == 0 and [f["file"] for f in num["files"][:3]] == ["001.jpg", "002.jpg", "003.jpg"],
      f"001.jpg → {a}，002.jpg → {b}，003.jpg → {c}")
got, miss = client_import(DATA, "002\n")
check(got == [b] and miss == [], f"没有确认表：「002」按交付名认（认出 {got} · 没认出 {miss}）")
sheet = os.path.join(WORK, "sheet.html")
r = run(DATA, "--proof-sheet", SHOOT, "--out", sheet, "--ids", f"{a},{c}")
check(r.returncode == 0 and r.stdout.strip().endswith(f"2 张: {a} {c}"), f"确认表：第 1 张 {a}、第 2 张 {c}")
got, miss = client_import(DATA, "001.jpg\n002\n003\n1\n")
check(got == [a, c], f"001.jpg 按交付名、003 交付名和表上都没冲突、1 = 表上第 1 张（认出 {got}）")
check(miss == ["002（交付文件名还是编号？）"], f"002：交付名是 {b}、表上第 2 张是 {c} → 不猜（没认出 {miss}）")

print("H. 只留最近 30 次；坏掉的单条跳过、写回去原样留着；整份坏了先挪开再写；读不出来的不写；重名不替你挑；不在这一场的 id 不认")
DATA2, LEDGER2 = make_data("data2")


def seed(n, kind="jpeg", files=None):
    return {"id": f"seed-{n}", "at": "2026-11-01T10:00:00Z", "kind": kind, "folder": "/x",
            "files": files if files is not None else [{"file": f"seed{n}.jpg", "id": IDS[0], "original": "/x"}]}


json.dump([seed(n) for n in range(30)], open(LEDGER2, "w"))
r = run(DATA2, "--export-jpeg", SHOOT, "--dest", os.path.join(WORK, "out-cap"), "--scope", "top:1", "--size", "long:200")
recs = ledger(LEDGER2)
check(r.returncode == 0 and len(recs) == 30 and recs[0]["id"] == "seed-1" and recs[-1]["kind"] == "highlights",
      f"30 次满了再导：最早那次挤掉、新的在最后（{len(recs)}，{recs[0]['id'] if recs else '-'}）")
json.dump([{"broken": True}, seed(1, files=[{"file": "AMBI.jpg", "id": IDS[1], "original": "/x"}]),
           seed(2, files=[{"file": "ambi.jpg", "id": IDS[2], "original": "/x"},
                          {"file": "keep_me.jpg", "id": IDS[2], "original": "/x"},
                          {"file": "ghost.jpg", "id": "GHOST", "original": "/x"}])], open(LEDGER2, "w"))
got, miss = client_import(DATA2, "AMBI\nkeep_me.jpg\nghost.jpg\n")
check(got == [IDS[2]], f"坏掉的那条不影响别的：keep_me.jpg 认出（{got}）")
check(miss == ["AMBI（重名）", "ghost.jpg"], f"两次导出同名指向两张 = 重名；不在这一场的 id 不认（{miss}）")
r = run(DATA2, "--export-jpeg", SHOOT, "--dest", os.path.join(WORK, "out-keep"), "--scope", "top:1", "--size", "long:200")
recs = ledger(LEDGER2)
check(r.returncode == 0 and len(recs) == 4 and recs[0] == {"broken": True} and recs[-1].get("kind") == "highlights",
      f"再记一笔：解不开的那一条原样留在文件里，不悄悄丢（{len(recs)} 条，第一条 {recs[0] if recs else '-'}）")
got, miss = client_import(DATA2, "keep_me.jpg\n")
check(got == [IDS[2]], f"　…… 写回去以后别的照样认（{got}）")
SDIR2 = os.path.dirname(LEDGER2)


def corrupt_copies():
    return sorted(n for n in os.listdir(SDIR2) if n.startswith("exports.corrupt-") and n.endswith(".json"))


with open(LEDGER2, "w") as f:
    f.write("not json")
r = run(DATA2, "--export-jpeg", SHOOT, "--dest", os.path.join(WORK, "out-bad"), "--scope", "top:1", "--size", "long:200")
recs = ledger(LEDGER2)
moved = corrupt_copies()
first = open(os.path.join(SDIR2, moved[0])).read() if moved else ""
check(r.returncode == 0 and len(recs) == 1 and len(moved) == 1 and first == "not json"
      and not os.path.exists(LEDGER2 + ".bak"),
      f"整份坏了：原件挪成 exports.corrupt-<时间>.json、新写 1 次（{len(recs)}，{moved}）")
with open(LEDGER2, "w") as f:
    f.write("still not json")
r = run(DATA2, "--export-jpeg", SHOOT, "--dest", os.path.join(WORK, "out-bad2"), "--scope", "top:1", "--size", "long:200")
moved = corrupt_copies()
texts = sorted(open(os.path.join(SDIR2, n)).read() for n in moved)
check(r.returncode == 0 and len(ledger(LEDGER2)) == 1 and texts == ["not json", "still not json"],
      f"又坏一次：另挪一份，不盖掉上一次挪开的（{moved}）")
if os.geteuid() == 0:
    print("  SKIP 读不出来的 exports.json（root 跑时 chmod 挡不住读）")
else:
    before = open(LEDGER2, "rb").read()
    os.chmod(LEDGER2, 0)
    try:
        r = run(DATA2, "--export-jpeg", SHOOT, "--dest", os.path.join(WORK, "out-unreadable"), "--scope", "top:1",
                "--size", "long:200")
    finally:
        os.chmod(LEDGER2, 0o644)
    after = open(LEDGER2, "rb").read()
    check(r.returncode == 1 and "没记下" in r.stdout and "读不出来" in r.stdout and after == before
          and corrupt_copies() == moved,
          f"读不出来（chmod 000）：不当空的盖掉、不挪，退出码 1、说原因（{r.returncode}，"
          f"{'原件没动' if after == before else '原件被改了'}）")

print("I. 原片本身就叫 001.JPG（按序号命名的扫描件、导入时改过名）：交付名 001.jpg 指的是另一张 = 不猜，带不带扩展名都一样")
SEQ = os.path.join(WORK, "shoot-seq")
os.makedirs(SEQ)
# 倒着起名：拍得最早的叫 008，{序号:3} 导出来的 001.jpg 就不是原片 001。
SEQ_NAME = {p["id"]: f"{len(PHOTOS) - i:03d}" for i, p in enumerate(PHOTOS)}
for i, p in enumerate(PHOTOS):
    make_jpeg(os.path.join(SEQ, SEQ_NAME[p["id"]] + ".JPG"), 360, 240, seed=300 + i)
r = run(os.path.join(WORK, "data-key-seq"), "--session-key", SEQ, quiet=True)
SEQ_KEY = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
check(len(SEQ_KEY) == 16, f"第二场算得出 key（{SEQ_KEY!r}）")
DATA_SEQ, LEDGER_SEQ = make_data("data-seq", shoot=SEQ, key=SEQ_KEY, rename=SEQ_NAME)
r = run(DATA_SEQ, "--export-jpeg", SEQ, "--dest", os.path.join(WORK, "out-seq-orig"), "--scope", "picks+usable",
        "--size", "long:200")
got, miss = client_import(DATA_SEQ, "003\n005.jpg\n", shoot=SEQ)
check(r.returncode == 0 and got == ["003", "005"] and miss == [],
      f"默认 {{原名}} 导出：交付名就是原片名、两边是同一张，照认（认出 {got} · 没认出 {miss}）")
os.remove(LEDGER_SEQ)
r = run(DATA_SEQ, "--export-jpeg", SEQ, "--dest", os.path.join(WORK, "out-seq-num"), "--scope", "picks+usable",
        "--name", "{序号:3}", "--size", "long:200")
files = ledger(LEDGER_SEQ)[-1]["files"] if ledger(LEDGER_SEQ) else []
clash = next((f for f in files if f["file"][:-4] != f["id"] and f["file"][:-4] in SEQ_NAME.values()), None)
check(r.returncode == 0 and clash is not None, f"{{序号:3}} 导出：有一张交付名和另一张原片同名（{clash}）")
if clash:
    t = clash["file"][:-4]
    got, miss = client_import(DATA_SEQ, f"{t}\n{t}.jpg\n", shoot=SEQ)
    check(got == [] and miss == [f"{t}（交付文件名还是原片名？）", f"{t}.jpg（交付文件名还是原片名？）"],
          f"「{t}」「{t}.jpg」：原片 {t} 和交付名 {t}.jpg（是 {clash['id']}）各指一张 → 都不猜（认出 {got} · 没认出 {miss}）")

print("J. {序号} 不补零、同一个文件夹再导一次另存的 1-2.jpg：客户回「1-2」，有确认表时和表上第 1 到 2 张对不上 = 不猜")
DATA3, LEDGER3 = make_data("data3")
out_plain = os.path.join(WORK, "out-plain")
for _ in range(2):
    r = run(DATA3, "--export-jpeg", SHOOT, "--dest", out_plain, "--scope", "picks+usable", "--name", "{序号}",
            "--size", "long:200")
recs = ledger(LEDGER3)
again = recs[-1]["files"] if len(recs) == 2 else []
x = again[0]["id"] if again else "-"
check(r.returncode == 0 and bool(again) and again[0]["file"] == "1-2.jpg",
      f"第二次另存成 1-2.jpg → {x}（{[f['file'] for f in again[:3]]}）")
got, miss = client_import(DATA3, "1-2\n")
check(got == [x] and miss == [], f"没有确认表：「1-2」就是交付文件名 1-2.jpg（认出 {got} · 没认出 {miss}）")
sa, sb, sc = [i for i in IDS if i != x][:3]
r = run(DATA3, "--proof-sheet", SHOOT, "--out", os.path.join(WORK, "sheet3.html"), "--ids", f"{sa},{sb},{sc}")
check(r.returncode == 0, f"确认表：第 1–3 张是 {sa} {sb} {sc}，都不是 1-2.jpg 那张")
got, miss = client_import(DATA3, "1-2\n1 - 2\n1-2.jpg\n2-3\n")
check(got == [x, sb, sc], f"「1-2.jpg」带扩展名按交付名，「2-3」是表上第 2 到 3 张（认出 {got}）")
check(miss == ["1-2（交付文件名还是编号？）"],
      f"「1-2」「1 - 2」：交付名是 {x}、表上第 1 到 2 张是 {sa} {sb} → 不猜（没认出 {miss}）")

if CLEANUP:
    shutil.rmtree(WORK, ignore_errors=True)
shutil.rmtree(SOCK, ignore_errors=True)
print(f"交付对照回归: {'全部通过' if not failures else f'{len(failures)} 条失败'}")
sys.exit(1 if failures else 0)
