#!/usr/bin/env python3
"""存储卡导入回归：造一张假卡，跑 --ingest 的各种情况，检查目标文件夹、账本，以及卡上的文件从头到尾没被动过。

用法: python3 card_import_regression.py <LabelGUI 可执行文件> [工作目录]
不需要真照片（导入不解码，文件内容用随机字节）；工作目录不给就用临时目录，跑完删掉。
数据安全相关（只读存储卡、绝不覆盖、复制后校验、取消不留半截），改 CardImport.swift 先跑它。
"""
import hashlib, json, os, random, re, shutil, subprocess, sys, tempfile, time

BIN = sys.argv[1]
WORK = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="card-import-")
CLEANUP = len(sys.argv) <= 2
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
CARD = os.path.join(WORK, "card")
OLD = time.mktime((2026, 10, 1, 9, 30, 0, 0, 0, -1))   # 卡上照片的修改时间
rng = random.Random(7)
failures = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


def put(rel, data=None, src=None):
    path = os.path.join(CARD, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if src:
        shutil.copyfile(src, path)
    else:
        with open(path, "wb") as f:
            f.write(data)
    os.utime(path, (OLD, OLD))
    return path


def rand(n):
    return bytes(rng.getrandbits(8) for _ in range(n)) if n < 4096 else os.urandom(n)


# 100CANON：IMG_0001..0004 是 RAW+JPG，IMG_0005 只有 JPG；IMG_0001.CR3 做大一点（测文件中间取消）
put("DCIM/100CANON/IMG_0001.CR3", rand(40 << 20))
put("DCIM/100CANON/IMG_0001.JPG", rand(1_200_000))
for n in [2, 3, 4]:
    put(f"DCIM/100CANON/IMG_000{n}.CR3", rand(3 << 20))
    put(f"DCIM/100CANON/IMG_000{n}.JPG", rand(1_000_000 + n * 1000))
put("DCIM/100CANON/IMG_0005.JPG", rand(900_000))
put("DCIM/100CANON/MVI_0006.MP4", rand(2 << 20))          # 视频：不导
put("DCIM/100CANON/MVI_0006.THM", rand(9000))             # 缩略图：不导
put("DCIM/100CANON/._IMG_0001.JPG", rand(4096))           # AppleDouble：不导
# 101CANON：编号转了一圈，又是 IMG_0001，内容不一样 → 整组改名 IMG_0001_2
put("DCIM/101CANON/IMG_0001.CR3", rand(3 << 20))
put("DCIM/101CANON/IMG_0001.JPG", rand(1_100_000))
put(".Trashes/501/IMG_9999.JPG", rand(500_000))  # 隐藏：不导
put("MISC/IMG_8888.JPG", rand(500_000))          # DCIM 外：不导


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree(root):
    out = {}
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            st = os.stat(p)
            out[os.path.relpath(p, root)] = (st.st_size, int(st.st_mtime), sha(p))
    return out


card_before = tree(CARD)


def run(data, dest, *extra):
    env = dict(os.environ, LABELGUI_DATA_DIR=data)
    r = subprocess.run([BIN, "--ingest", CARD, "--dest", dest, *extra], env=env,
                       capture_output=True, text=True, timeout=300)
    print("    " + r.stdout.strip().replace("\n", "\n    "))
    if r.stderr.strip():
        print("    [stderr] " + r.stderr.strip()[:400])
    return r


def listing(dest):
    return sorted(f for f in os.listdir(dest)) if os.path.isdir(dest) else []


src = lambda rel: os.path.join(CARD, rel)
DATA1 = os.path.join(WORK, "data1")
D1 = os.path.join(WORK, "dest1")

print("A. 新卡导入")
r = run(DATA1, D1)
check(r.returncode == 0, "退出码 0")
expected = ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001_2.CR3", "IMG_0001_2.JPG", "IMG_0002.CR3", "IMG_0002.JPG",
            "IMG_0003.CR3", "IMG_0003.JPG", "IMG_0004.CR3", "IMG_0004.JPG", "IMG_0005.JPG"]
check(listing(D1) == expected, f"目标文件 = {listing(D1)}")
pairs = {"IMG_0001.CR3": "DCIM/100CANON/IMG_0001.CR3", "IMG_0001.JPG": "DCIM/100CANON/IMG_0001.JPG",
         "IMG_0001_2.CR3": "DCIM/101CANON/IMG_0001.CR3", "IMG_0001_2.JPG": "DCIM/101CANON/IMG_0001.JPG",
         "IMG_0005.JPG": "DCIM/100CANON/IMG_0005.JPG"}
check(all(sha(os.path.join(D1, k)) == sha(src(v)) for k, v in pairs.items()), "内容和卡上逐字节一致（含改名的 101CANON）")
check(all(int(os.stat(os.path.join(D1, f)).st_mtime) == int(OLD) for f in listing(D1)), "修改时间和原片一样")
ledger = json.load(open(os.path.join(DATA1, "import_ledger.json")))["entries"]
check(len(ledger) == 11, f"账本 11 条（实际 {len(ledger)}）")
renamed = [k for k, v in ledger.items() if v["dest"].endswith("IMG_0001_2.CR3")]
check(len(renamed) == 1 and renamed[0].startswith("IMG_0001.CR3|"), "改名的那张在账本里按卡上原名记")

print("B. 再插一次：全部按账本跳过")
r = run(DATA1, D1)
check("要导入：没有" in r.stdout and "以前导入过 6 张" in r.stdout, "0 个要导入，以前导入过 6 张")
check(listing(D1) == expected, "目标没多东西")

print("C. 勾「以前导入过的也再导一遍」导进同一个文件夹：内容一样的都认出来，不重复")
r = run(DATA1, D1, "--reimport")
check("要导入：没有" in r.stdout and "目标里已有 6 张" in r.stdout, "0 个要导入，目标里已有 6 张")
check(listing(D1) == expected, "目标没多东西")

print("D. 目标里预先放了：别的照片同名、只剩 xmp、半套（JPG 已在）、同大小不同内容")
D2 = os.path.join(WORK, "dest2")
os.makedirs(D2)
with open(os.path.join(D2, "IMG_0002.JPG"), "wb") as f:                                    # 别的照片
    f.write(rand(800_000))
open(os.path.join(D2, "IMG_0003.xmp"), "w").write("<x:xmpmeta/>")                          # 孤零零的 xmp
shutil.copyfile(src("DCIM/100CANON/IMG_0004.JPG"), os.path.join(D2, "IMG_0004.JPG"))       # 半套
size5 = os.path.getsize(src("DCIM/100CANON/IMG_0005.JPG"))
with open(os.path.join(D2, "IMG_0005.JPG"), "wb") as f:                                    # 同大小、不同内容
    f.write(os.urandom(size5))
planted = {f: sha(os.path.join(D2, f)) for f in listing(D2)}
r = run(DATA1, D2, "--reimport")
check(r.returncode == 0, "退出码 0")
want = sorted(["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001_2.CR3", "IMG_0001_2.JPG",
               "IMG_0002.JPG", "IMG_0002_2.CR3", "IMG_0002_2.JPG",
               "IMG_0003.xmp", "IMG_0003_2.CR3", "IMG_0003_2.JPG",
               "IMG_0004.CR3", "IMG_0004.JPG", "IMG_0005.JPG", "IMG_0005_2.JPG"])
check(listing(D2) == want, f"目标文件 = {listing(D2)}")
check(all(sha(os.path.join(D2, f)) == h for f, h in planted.items()), "预先放的文件一个字节没动")
check(sha(os.path.join(D2, "IMG_0005_2.JPG")) == sha(src("DCIM/100CANON/IMG_0005.JPG")), "同大小不同内容 → 改名导入，没当成已有")
check(sha(os.path.join(D2, "IMG_0004.CR3")) == sha(src("DCIM/100CANON/IMG_0004.CR3")), "半套只补 RAW，名字和已有 JPG 配上")
check("改名 4 张" in r.stdout, "改名 4 张（101 的 0001、0002、0003、0005）")

print("E. 复制到一半取消：.part 清干净，账本只记导完的；再导一次补齐")
DATA3 = os.path.join(WORK, "data3")
D3 = os.path.join(WORK, "dest3")
r = run(DATA3, D3, "--cancel-at-bytes", str(20 << 20))
check("已取消导入" in r.stdout, "取消了")
leftovers = [f for f in os.listdir(D3) if f.startswith(".")] if os.path.isdir(D3) else []
check(leftovers == [], f"没有残留的 .part（{leftovers}）")
check(listing(D3) == [], f"大文件中途取消 → 目标里什么都没有（{listing(D3)}）")
r = run(DATA3, D3, "--cancel-after", "3")
check(len(listing(D3)) == 3, f"导 3 个就取消 → 目标里 3 个（{listing(D3)}）")
ledger3 = json.load(open(os.path.join(DATA3, "import_ledger.json")))["entries"]
check(len(ledger3) == 3, f"账本 3 条（实际 {len(ledger3)}）")
r = run(DATA3, D3)
check(listing(D3) == expected, f"再导一次补齐 = {listing(D3)}")
check(all(sha(os.path.join(D3, k)) == sha(src(v)) for k, v in pairs.items()), "补齐后内容一致")

print("F0. 账本到上限：一次扔到 90%，最新导的留着")
DATA4 = os.path.join(WORK, "data4")
D4 = os.path.join(WORK, "dest4")
r = run(DATA4, D4, "--ledger-cap", "5")
check(r.returncode == 0 and listing(D4) == expected, "上限 5 照样全部导完")
ledger4 = json.load(open(os.path.join(DATA4, "import_ledger.json")))["entries"]
check(4 <= len(ledger4) <= 5, f"账本 4–5 条（实际 {len(ledger4)}）")
newest = max(ledger4.values(), key=lambda e: e["at"])["dest"]
check(any(v["dest"].endswith("IMG_0001_2.JPG") for v in ledger4.values()), f"最后导的 IMG_0001_2.JPG 还在账本里（最新：{os.path.basename(newest)}）")
r = run(DATA4, os.path.join(WORK, "dest5"), "--plan-only")
check("要导入：没有" not in r.stdout, "被扔出账本的下次当新照片（换个空文件夹会再导）")

print("F1. 目标选到了卡里面：一个都不写，连文件夹都不建")
inside = os.path.join(CARD, "DCIM", "导入")
r = run(os.path.join(WORK, "data6"), inside)
check("重叠" in r.stdout and r.returncode != 0, "拒绝导入（目标和存储卡重叠）")
check(not os.path.exists(inside), "卡上没多出文件夹")

# ---------- 审查发现的边界情况（每张假卡各用各的目录）----------
ROOT_USER = os.geteuid() == 0   # root 不受权限限制，chmod 000 的用例没意义


def mkcard(name, files):
    root = os.path.join(WORK, name)
    for rel, data in files.items():
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        os.utime(p, (OLD, OLD))
    return root


def run_card(card, data, dest, *extra):
    env = dict(os.environ, LABELGUI_DATA_DIR=data)
    r = subprocess.run([BIN, "--ingest", card, "--dest", dest, *extra], env=env,
                       capture_output=True, text=True, timeout=300)
    print("    " + r.stdout.strip().replace("\n", "\n    "))
    if r.stderr.strip():
        print("    [stderr] " + r.stderr.strip()[:400])
    return r


print("H1. 目标里同名同大小、头尾一样但中间坏了：不能当成「已有」")
orig = rand(3 << 20)
c = mkcard("card_h1", {"DCIM/100CANON/IMG_0001.CR3": orig})
d = os.path.join(WORK, "dest_h1")
os.makedirs(d)
bad = bytearray(orig)
bad[1 << 20:(1 << 20) + 4096] = b"\0" * 4096
with open(os.path.join(d, "IMG_0001.CR3"), "wb") as f:
    f.write(bytes(bad))
r = run_card(c, os.path.join(WORK, "data_h1"), d)
card_sha = sha(os.path.join(c, "DCIM/100CANON/IMG_0001.CR3"))
check(any(sha(os.path.join(d, f)) == card_sha for f in listing(d)), f"卡上的原片导进来了（{listing(d)}）")
check(sha(os.path.join(d, "IMG_0001.CR3")) == hashlib.sha256(bytes(bad)).hexdigest(), "坏掉的旧副本没被动")
led_path = os.path.join(WORK, "data_h1", "import_ledger.json")
led = json.load(open(led_path))["entries"] if os.path.exists(led_path) else {}
check(all(not v["dest"].endswith("/IMG_0001.CR3") for v in led.values()), "账本没把坏副本记成「导入过」")

print("H2. 带隐藏标记的照片（FAT 隐藏属性，如尼康「隐藏图像」）也要导")
c = mkcard("card_h2", {"DCIM/100NIKON/DSC_0001.NEF": rand(200_000), "DCIM/100NIKON/DSC_0002.NEF": rand(200_000)})
subprocess.run(["chflags", "hidden", os.path.join(c, "DCIM/100NIKON/DSC_0002.NEF")], check=True)
d = os.path.join(WORK, "dest_h2")
r_h2 = run_card(c, os.path.join(WORK, "data_h2"), d)
check(listing(d) == ["DSC_0001.NEF", "DSC_0002.NEF"], f"两张都导了（{listing(d)}）")
m = re.search(r"elapsed=([0-9.]+)", r_h2.stdout)
check(m is not None and float(m.group(1)) > 0, f"用时算上了（{m.group(0) if m else '没打印 elapsed'}）")

print("H3. 读不出来的文件夹：要说出来，不能装作卡上就这么多")
if ROOT_USER:
    print("  (root 跳过)")
else:
    c = mkcard("card_h3", {"DCIM/100CANON/IMG_0001.JPG": rand(50_000), "DCIM/101CANON/IMG_0101.JPG": rand(50_000)})
    locked = os.path.join(c, "DCIM/101CANON")
    os.chmod(locked, 0)
    try:
        r = run_card(c, os.path.join(WORK, "data_h3"), os.path.join(WORK, "dest_h3"), "--plan-only")
        check("读不出来" in r.stdout and "101CANON" in r.stdout, "计划里列出读不出来的 DCIM/101CANON")
        r = run_card(c, os.path.join(WORK, "data_h3"), os.path.join(WORK, "dest_h3"))
        check(r.returncode != 0 and "读不出来" in r.stdout, "导完也提醒（退出码非 0）")
    finally:
        os.chmod(locked, 0o755)

print("H4. 名单外的照片格式（NRW、3FR、IIQ……）要导；不是照片的文件要数出来")
names = ["DSC_0001.NRW", "DSC_0002.SR2", "B0000003.3FR", "CF000004.IIQ", "GOPR0005.GPR", "IMG_0006.insp",
         "CRW_0007.CRW", "IMG_0008.JPG", "IMG_0008.WAV"]
c = mkcard("card_h4", {f"DCIM/100MISC/{n}": rand(50_000) for n in names})
d = os.path.join(WORK, "dest_h4")
r = run_card(c, os.path.join(WORK, "data_h4"), d)
check(listing(d) == sorted(n for n in names if not n.endswith(".WAV")), f"8 个照片文件都导了（{listing(d)}）")
check("其他文件" in r.stdout and "WAV" in r.stdout, "WAV 录音备注没导，但数出来、说出来了")

print("H5. 计划之后目标里冒出同名文件：整张跳过（RAW+JPG 不拆开），原因说清楚")
c = mkcard("card_h5", {"DCIM/100CANON/IMG_0001.CR3": rand(1 << 20), "DCIM/100CANON/IMG_0001.JPG": rand(300_000),
                       "DCIM/100CANON/IMG_0002.CR3": rand(1 << 20), "DCIM/100CANON/IMG_0002.JPG": rand(300_000)})
d = os.path.join(WORK, "dest_h5")
r = run_card(c, os.path.join(WORK, "data_h5"), d, "--plant-after-plan", "IMG_0002.JPG")
check(listing(d) == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.JPG"], f"IMG_0002 整张没导，只剩冒出来的那个（{listing(d)}）")
planted = os.path.join(d, "IMG_0002.JPG")
check(os.path.exists(planted) and open(planted, "rb").read() == b"planted by test", "冒出来的那个没被覆盖")
check(r.returncode != 0 and "同名" in r.stdout and "存储卡坏了" not in r.stdout, "退出码非 0，原因写的是同名文件、不是「存储卡坏了」")

print("H6. 读不了的源文件：失败要说出来，走界面那条路也要留着「先别格式化」")
if ROOT_USER:
    print("  (root 跳过)")
else:
    c = mkcard("card_h6", {"DCIM/100CANON/IMG_0001.JPG": rand(300_000), "DCIM/100CANON/IMG_0002.JPG": rand(300_000)})
    badfile = os.path.join(c, "DCIM/100CANON/IMG_0002.JPG")
    os.chmod(badfile, 0)
    try:
        r = run_card(c, os.path.join(WORK, "data_h6"), os.path.join(WORK, "dest_h6"))
        check(r.returncode != 0 and "没导进来" in r.stdout, "摘要里写了有文件没导进来")
        check("IMG_0002.JPG" in r.stdout and "读" in r.stdout and "save" not in r.stdout, "原因是读不出来（不是「没有权限保存」）")
        r = run_card(c, os.path.join(WORK, "data_h6b"), os.path.join(WORK, "dest_h6b"), "--via-store", "--no-analyze")
        check("先别格式化" in r.stdout, "导完切到新文件夹之后，「先别格式化存储卡」的提示还在")
    finally:
        os.chmod(badfile, 0o644)

print("H8. 连着读不出来停下了：没导进来的要按全部没导的算，不是只算试过的")
if ROOT_USER:
    print("  (root 跳过)")
else:
    c = mkcard("card_h8", {f"DCIM/100CANON/IMG_{i:04d}.JPG": rand(60_000) for i in range(1, 13)})
    locked = [os.path.join(c, f"DCIM/100CANON/IMG_{i:04d}.JPG") for i in range(1, 11)]
    for f in locked:
        os.chmod(f, 0)
    try:
        r = run_card(c, os.path.join(WORK, "data_h8"), os.path.join(WORK, "dest_h8"))
        check(r.returncode != 0 and "停下了" in r.stdout, "连续读不出来 → 停下")
        check("12 个文件没导进来" in r.stdout, "说的是 12 个没导进来（试了 8 个、后面 4 个没试）")
    finally:
        for f in locked:
            os.chmod(f, 0o644)

print("H7. 排队：第一张导入中又确认第二张；分析中点「停下分析并导入」")
if os.environ.get("CARD_REGRESSION_SKIP_QUEUE"):
    print("  (跳过)")
else:
    # 真能解码的 BMP（随机字节的「JPG」解不开，分析一眨眼就完，「停下分析并导入」那条路走不到）。
    def bmp(w, h):
        row = (w * 3 + 3) & ~3
        pixels = os.urandom(row * h)
        header = b"BM" + (54 + len(pixels)).to_bytes(4, "little") + b"\0\0\0\0" + (54).to_bytes(4, "little")
        info = (40).to_bytes(4, "little") + w.to_bytes(4, "little") + h.to_bytes(4, "little") + \
            (1).to_bytes(2, "little") + (24).to_bytes(2, "little") + b"\0" * 24
        return header + info + pixels
    c_a = mkcard("card_qa", {f"DCIM/100CANON/IMG_{i:04d}.BMP": bmp(1800, 1200) for i in range(1, 5)})
    c_b = mkcard("card_qb", {f"DCIM/100CANON/IMG_{i:04d}.BMP": bmp(1800, 1200) for i in range(1, 5)})
    r = subprocess.run([BIN, "--card-queue-selftest", c_a, c_b, "--dest", os.path.join(WORK, "dest_q")],
                       env=dict(os.environ, LABELGUI_DATA_DIR=os.path.join(WORK, "data_q")),
                       capture_output=True, text=True, timeout=600)
    print("    " + r.stdout.strip().replace("\n", "\n    "))
    check(r.returncode == 0 and "排队自检通过" in r.stdout, "两种情形都导全了，分析在最后跑完")

print("F. 存储卡从头到尾没被动过")
check(tree(CARD) == card_before, "卡上每个文件的大小 / 修改时间 / SHA-256 都和开始时一样")

print("G. 没给 --dest / 没设 LABELGUI_DATA_DIR 都拒绝跑")
r = subprocess.run([BIN, "--ingest", CARD], env=dict(os.environ, LABELGUI_DATA_DIR=DATA1), capture_output=True, text=True)
check(r.returncode == 2, "没给 --dest → 退出码 2")
# 家目录指到工作目录：程序在拒绝之前会先碰一下 Application Support，别碰到真的。
env = {k: v for k, v in os.environ.items() if k != "LABELGUI_DATA_DIR"}
env["CFFIXED_USER_HOME"] = os.path.join(WORK, "home")
r = subprocess.run([BIN, "--ingest", CARD, "--dest", D1], env=env, capture_output=True, text=True)
check(r.returncode == 2, "没设 LABELGUI_DATA_DIR → 退出码 2")

print()
print("存储卡导入回归全部通过" if not failures else f"存储卡导入回归 {len(failures)} 项失败")
if CLEANUP and not failures:
    subprocess.run(["chmod", "-R", "u+rwX", WORK])   # chmod 000 的东西不放开 rmtree 删不掉
    shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if failures else 0)
