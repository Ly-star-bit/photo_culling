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

def run_card_env(card, data, dest, env_extra, *extra):
    env = dict(os.environ, LABELGUI_DATA_DIR=data, **env_extra)
    r = subprocess.run([BIN, "--ingest", card, *(["--dest", dest] if dest else []), *extra], env=env,
                       capture_output=True, text=True, timeout=300)
    print("    " + r.stdout.strip().replace("\n", "\n    "))
    if r.stderr.strip():
        print("    [stderr] " + r.stderr.strip()[:400])
    return r


def hidden(dest):
    return [f for f in os.listdir(dest) if f.startswith(".")] if os.path.isdir(dest) else []


NO_EXCL = {"LABELGUI_TEST_NO_RENAME_EXCL": "1"}
print("K1. 目标卷不支持 RENAME_EXCL（SMB / NFS / 部分 exFAT 回 ENOTSUP）：退回 lstat + 普通改名，照样全导进来")
k1_files = {"DCIM/100CANON/IMG_0001.CR3": rand(1 << 20), "DCIM/100CANON/IMG_0001.JPG": rand(300_000),
            "DCIM/100CANON/IMG_0002.CR3": rand(1 << 20), "DCIM/100CANON/IMG_0002.JPG": rand(300_000)}
c = mkcard("card_k1", k1_files)
d = os.path.join(WORK, "dest_k1")
r = run_card_env(c, os.path.join(WORK, "data_k1"), d, NO_EXCL)
check(r.returncode == 0 and listing(d) == sorted(os.path.basename(k) for k in k1_files), f"4 个文件都导了（{listing(d)}）")
check(all(sha(os.path.join(d, os.path.basename(k))) == hashlib.sha256(v).hexdigest() for k, v in k1_files.items()),
      "内容和卡上逐字节一致")
check(hidden(d) == [], f"没有残留的 .part（{hidden(d)}）")
PRETEND = "（测试：假装目标卷不支持 RENAME_EXCL）"


def fallbacks(stdout):
    """--ingest 打的「RENAME_EXCL 退路：N 次」（copyOne 真的走了 ENOTSUP 那条退路几次）。"""
    m = re.search(r"RENAME_EXCL 退路：(\d+) 次", stdout)
    return int(m.group(1)) if m else -1


check(PRETEND in r.stdout and fallbacks(r.stdout) == 4, f"开关真的生效：4 个文件都走了退路（{fallbacks(r.stdout)} 次）")

print("K2. 退路下，整张检查之后才冒出来的悬空符号链接：lstat 看得见，没被改名盖掉")
d = os.path.join(WORK, "dest_k2")
r = run_card_env(c, os.path.join(WORK, "data_k2"), d, NO_EXCL, "--plant-symlink-mid", "IMG_0001.JPG")
link = os.path.join(d, "IMG_0001.JPG")
check(os.path.islink(link) and os.readlink(link) == "nowhere-planted-by-test", "符号链接还是原来那个，没被盖掉")
check(r.returncode != 0 and "没覆盖" in r.stdout, "IMG_0001.JPG 报「已经有、没覆盖」，退出码非 0")
check(hidden(d) == [], f"没有残留的 .part（{hidden(d)}）")
check(PRETEND in r.stdout and fallbacks(r.stdout) >= 2, f"撞上链接的那个也是在退路里拦下的（退路 {fallbacks(r.stdout)} 次）")

print("K3. 计划之后冒出悬空的符号链接：整张跳过（RAW 也不导，不拆开），链接没动")
d = os.path.join(WORK, "dest_k3")
r = run_card_env(c, os.path.join(WORK, "data_k3"), d, {}, "--plant-symlink-after-plan", "IMG_0002.JPG")
check(listing(d) == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.JPG"], f"IMG_0002 整张没导（{listing(d)}）")
check(os.path.islink(os.path.join(d, "IMG_0002.JPG")), "符号链接还在")
check(PRETEND not in r.stdout and fallbacks(r.stdout) == 0, f"对照：不设开关时一次退路都不走（{fallbacks(r.stdout)} 次）")

# ---------- RAW、JPG 分卡存：文件头（拍摄时间、SubSec、型号、机身序列号）认同一帧 ----------
import struct

# 8x8 灰色基线 JPEG（sips 生成、去掉了 APP 段），塞一段 EXIF 进去 ImageIO 就读得出文件头。
TINY_JPEG = bytes.fromhex(
    "ffd8ffc00011080008000803012200021101031101ffc4001f0000010501010101010100000000000000000102030405060708090a0b"
    "ffc400b5100002010303020403050504040000017d01020300041105122131410613516107227114328191a1082342b1c11552d1f024"
    "33627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778"
    "797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9"
    "dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9faffc4001f0100030101010101010101010000000000000102030405060708090a0b"
    "ffc400b51100020102040403040705040400010277000102031104052131061241510761711322328108144291a1b1c109233352f015"
    "6272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a7374757677"
    "78797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7"
    "d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9faffdb0043000606060606060a06060a0e0a0a0a0e120e0e0e0e1217121212121217"
    "1c1717171717171c1c1c1c1c1c1c1c22222222222227272727272c2c2c2c2c2c2c2c2c2cffdb0043010707070b0a0b130a0a132e1f1a"
    "1f2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2effdd00"
    "040001ffda000c03010002110311003f0028a28a00ffd9")


def exif_tiff(model, when, subsec, serial, pixels=b"", side=0):
    """TIFF 块：IFD0（Make、Model、指向 EXIF）+ EXIF（DateTimeOriginal、SubSecTimeOriginal、BodySerialNumber）。
    给了 pixels（side×side 个字节）就是一张完整合法的基线 TIFF：IFD0 再带上 8 位灰度、不压缩的图像标签，
    StripOffsets 指向块尾的 pixels。"""
    def asc(v):
        return 2, v.encode() + b"\0"

    def num(typ, v):                                          # 3 = SHORT、4 = LONG，一个值、放在条目里
        return typ, struct.pack("<H" if typ == 3 else "<I", v)
    ifd0 = {0x010F: asc("SONY"), 0x0110: asc(model), 0x8769: num(4, 0)}
    if pixels:
        ifd0.update({0x00FE: num(4, 0), 0x0100: num(4, side), 0x0101: num(4, side), 0x0102: num(3, 8),
                     0x0103: num(3, 1), 0x0106: num(3, 1), 0x0111: num(4, 0), 0x0115: num(3, 1),
                     0x0116: num(4, side), 0x0117: num(4, len(pixels))})
    sub = {tag: asc(v) for tag, v in [(0x9003, when), (0x9291, subsec), (0xA431, serial)] if v is not None}
    exif_off = 8 + 2 + 12 * len(ifd0) + 4
    data_off = exif_off + 2 + 12 * len(sub) + 4
    padded = lambda v: len(v) + len(v) % 2
    blob_len = sum(padded(v) for _, v in list(ifd0.values()) + list(sub.values()) if len(v) > 4)
    ifd0[0x8769] = num(4, exif_off)
    if pixels:
        ifd0[0x0111] = num(4, data_off + blob_len)
    blobs = bytearray()

    def ifd(entries):
        out = struct.pack("<H", len(entries))
        for tag in sorted(entries):
            typ, val = entries[tag]
            count = len(val) if typ == 2 else 1
            if len(val) <= 4:
                out += struct.pack("<HHI", tag, typ, count) + val.ljust(4, b"\0")
            else:
                out += struct.pack("<HHII", tag, typ, count, data_off + len(blobs))
                blobs.extend(val + b"\0" * (len(val) % 2))
        return out + struct.pack("<I", 0)
    head = ifd(ifd0) + ifd(sub)
    return b"II" + struct.pack("<HI", 42, 8) + head + bytes(blobs) + pixels


def fake_arw(model, when, subsec, serial, side=64):
    """伪 RAW：一张完整合法的小 TIFF（64×64 灰度，像素随机 —— 每个文件内容都不一样）+ 上面那段 EXIF，后面不再接随机字节。
    以前是 TIFF 头 + EXIF + 30 万随机字节、没有图像标签：ImageIO 把它认成 Sony RAW（com.sony.arw-raw-image），
    读不读得出文件头要看那个系统的 RAW 插件（本机 macOS 26 读得出，CI 的 macOS 15 没验过）。这样的小 TIFF 本机
    认成 public.tiff、走普通的 TIFF 读取器；换个系统就算认成 RAW，拿到的也是一份结构完整的文件。"""
    return exif_tiff(model, when, subsec, serial, pixels=os.urandom(side * side), side=side)


def fake_jpg(model, when, subsec, serial, size=120_000):
    app1 = b"Exif\0\0" + exif_tiff(model, when, subsec, serial)
    head = TINY_JPEG[:2] + b"\xff\xe1" + struct.pack(">H", len(app1) + 2) + app1 + TINY_JPEG[2:]
    return head + os.urandom(size - len(head))


def describe_count(stdout, label):
    m = re.search(label + r" (\d+) 张", stdout)
    return int(m.group(1)) if m else 0


T1, T2 = "2026:10:01 09:30:00", "2026:10:01 09:31:07"
CAM1, CAM2 = "4012345", "4099999"


def raw_header_readable():
    """这台机器的 ImageIO 读不读得出伪 RAW 的文件头 —— 用 sips 问（也是 ImageIO），跟导卡代码无关。"""
    probe = os.path.join(WORK, "probe_header.ARW")
    with open(probe, "wb") as f:
        f.write(fake_arw("ILCE-7M4", T1, "123", CAM1))
    try:
        out = subprocess.run(["/usr/bin/sips", "-g", "format", "-g", "make", "-g", "model", probe],
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError) as e:
        out = f"sips 跑不了：{e}"
    finally:
        os.remove(probe)
    shown = " · ".join(line.strip() for line in out.splitlines()[1:]) or out.strip()
    return "model: ILCE-7M4" in out, shown


# 读不出 = 这台机器 ImageIO 的事（导卡代码读不出文件头时走「改名、不硬配」那条安全的路）：M1 / M2 / M2t / M3 里
# 要靠 RAW 文件头配对的断言只打 SKIP、不算失败，另打一条 ::warning::（CI 摘要页看得到）。读得出、导卡却没配上 ——
# 那是导卡代码的毛病，照常算失败。
RAW_HEADER_OK, raw_probe = raw_header_readable()
print(f"（ImageIO 读伪 RAW 的文件头：{'读得出' if RAW_HEADER_OK else '读不出'} —— sips：{raw_probe}）")
if not RAW_HEADER_OK:
    print("::warning::存储卡导入回归：这台机器的 ImageIO 读不出伪 RAW 的文件头，M1/M2/M2t/M3 里靠 RAW 文件头配对的断言跳过了")
raw_skipped = []


def check_raw(cond, msg):
    """要从 RAW 文件头读出身份才成立的断言：ImageIO 读不出伪 RAW 时只打 SKIP。"""
    if RAW_HEADER_OK:
        check(cond, msg)
        return
    print(("  ok   " if cond else "  SKIP ") + msg + "（要读 RAW 文件头，这台机器的 ImageIO 读不出）")
    if not cond:
        raw_skipped.append(msg)


def same_bytes(a, b):
    return os.path.isfile(a) and os.path.isfile(b) and sha(a) == sha(b)


print("M1. RAW、JPG 分卡存：卡 A 只有 RAW、卡 B 只有同名 JPG，文件头一致 → 补成一对、不改名；旁边 LR 的 .xmp 不挡")
card_a = mkcard("card_m_a", {"DCIM/100MSDCF/DSC00001.ARW": fake_arw("ILCE-7M4", T1, "123", CAM1),
                             "DCIM/100MSDCF/DSC00002.ARW": fake_arw("ILCE-7M4", T2, "045", CAM1)})
card_b = mkcard("card_m_b", {"DCIM/100MSDCF/DSC00001.JPG": fake_jpg("ILCE-7M4", T1, "123", CAM1),
                             "DCIM/100MSDCF/DSC00002.JPG": fake_jpg("ILCE-7M4", T2, "045", CAM1)})
d = os.path.join(WORK, "dest_m1")
data_m = os.path.join(WORK, "data_m1")
r = run_card(card_a, data_m, d)
check(r.returncode == 0 and listing(d) == ["DSC00001.ARW", "DSC00002.ARW"], f"卡 A 的 RAW 导进来了（{listing(d)}）")
open(os.path.join(d, "DSC00002.xmp"), "w").write("<x:xmpmeta/>")          # Lightroom 给 RAW 写的
r = run_card(card_b, data_m, d, "--plan-only")
check_raw(describe_count(r.stdout, "补成一对") == 2 and "改名 0 张" in r.stdout, "计划：补成一对 2 张、改名 0 张")
r = run_card(card_b, data_m, d)
check_raw(r.returncode == 0 and listing(d) == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.ARW", "DSC00002.JPG", "DSC00002.xmp"],
          f"JPG 用原名补在 RAW 旁边（{listing(d)}）")
check_raw(same_bytes(os.path.join(d, "DSC00001.JPG"), os.path.join(card_b, "DCIM/100MSDCF/DSC00001.JPG")), "补进来的就是卡 B 的 JPG")
check_raw("改名导入了" not in r.stdout and "导入提醒" not in r.stdout, "导完的摘要、提醒里都没有改名")
r = run_card(card_b, data_m, d, "--reimport")
check_raw("要导入：没有" in r.stdout and "目标里已有 2 张" in r.stdout, "再导一次卡 B（勾重导）：都认出来、不多出 _2")

print("M2. 反例：目标里已经有同名的别的 JPG（同类）→ 照旧改名；序列号读不到 → 照旧改名（认不准，确认框照实说）；摘要、提醒都说改了名")
card_c = mkcard("card_m_c", {"DCIM/100MSDCF/DSC00001.JPG": fake_jpg("ILCE-7M4", "2026:10:02 18:00:00", "123", CAM1)})
r = run_card(card_c, data_m, d)
check_raw(same_bytes(os.path.join(d, "DSC00001_2.JPG"), os.path.join(card_c, "DCIM/100MSDCF/DSC00001.JPG")),
          f"目标里已有同名的别的 JPG → 改名 DSC00001_2.JPG（{listing(d)}）")
check_raw(same_bytes(os.path.join(d, "DSC00001.JPG"), os.path.join(card_b, "DCIM/100MSDCF/DSC00001.JPG")), "原来那对没被动")
check_raw("改名导入了（如 DSC00001_2）" in r.stdout, "导完的摘要里说了改名")
notice = [l for l in r.stdout.splitlines() if l.startswith("导入提醒：")]
check(len(notice) == 1 and "改名导入了" in notice[0] and "先别格式化" not in notice[0], f"提醒里说了改名、没叫人先别格式化（{notice}）")
d2 = os.path.join(WORK, "dest_m2")
card_ns_a = mkcard("card_m_nsa", {"DCIM/100MSDCF/DSC00005.ARW": fake_arw("ILCE-7M4", T1, "123", None)})
card_ns_b = mkcard("card_m_nsb", {"DCIM/100MSDCF/DSC00005.JPG": fake_jpg("ILCE-7M4", T1, "123", None)})
run_card(card_ns_a, os.path.join(WORK, "data_m2"), d2)
r = run_card(card_ns_b, os.path.join(WORK, "data_m2"), d2)
check(listing(d2) == ["DSC00005.ARW", "DSC00005_2.JPG"], f"序列号读不到 → 改名、不硬配（{listing(d2)}）")
check(describe_count(r.stdout, "认不准没配") == 1, "计划里数出 1 张认不准没配")

print("M2t. 反例：目标里只有 RAW，同型号、同机身序列号的 JPG 只差拍摄时间 / 只差 SubSec（同号机身转了一圈、格式化后编号重置）→ 不配、改名")
d_t = os.path.join(WORK, "dest_m2t")
data_t = os.path.join(WORK, "data_m2t")
raw_t = mkcard("card_m2t_r", {"DCIM/100MSDCF/DSC00007.ARW": fake_arw("ILCE-7M4", T1, "123", CAM1),
                              "DCIM/100MSDCF/DSC00008.ARW": fake_arw("ILCE-7M4", T1, "123", CAM1)})
jpg_t = mkcard("card_m2t_j", {"DCIM/100MSDCF/DSC00007.JPG": fake_jpg("ILCE-7M4", "2026:10:02 18:00:00", "123", CAM1),
                              "DCIM/100MSDCF/DSC00008.JPG": fake_jpg("ILCE-7M4", T1, "124", CAM1)})
run_card(raw_t, data_t, d_t)
r = run_card(jpg_t, data_t, d_t, "--plan-only")
check_raw(describe_count(r.stdout, "补成一对") == 0 and describe_count(r.stdout, "认不准没配") == 0 and "改名 2 张" in r.stdout,
          "计划：补成一对 0 张（文件头都读得到、只是时间 / SubSec 对不上，不算认不准）、改名 2 张")
r = run_card(jpg_t, data_t, d_t)
check(listing(d_t) == ["DSC00007.ARW", "DSC00007_2.JPG", "DSC00008.ARW", "DSC00008_2.JPG"],
      f"只差时间的、只差 SubSec 的都改名导入，没和 RAW 拼成一张（{listing(d_t)}）")

print("M2b. 只改了名的提醒不挤掉前面「先别格式化」那条：横幅最多 3 条，超了先扔纯信息的")
d_m2b = os.path.join(WORK, "dest_m2b")
os.makedirs(d_m2b)
open(os.path.join(d_m2b, "DSC00001.JPG"), "wb").write(rand(70_000))          # 目标里同名的别的照片 → 改名
card_m2b = mkcard("card_m2b", {"DCIM/100MSDCF/DSC00001.JPG": rand(80_000)})
problem = "存储卡「CARD1」：备份没写全：3 个文件没备份到 T7 › 备份（备份盘满了） —— 先别格式化存储卡"
info_old = "12 张导到了 ~/A/20261103，还没打开、没分析 —— 用文件夹菜单「选择文件夹…」打开它"
info_new = "存储卡「CARD3」：2 张和目标里别的照片重名，改名导入了（如 IMG_0001_2）"
r = run_card(card_m2b, os.path.join(WORK, "data_m2b"), d_m2b, "--via-store", "--no-analyze",
             "--preload-notice", problem, "--preload-notice", info_old, "--preload-notice", info_new)
check("改名导入了（如 DSC00001_2）" in r.stdout and problem in r.stdout,
      "这张卡的改名提醒进来了，前面那条「先别格式化」还在")
check(info_old not in r.stdout and info_new in r.stdout, "挤掉的是最早的纯信息那条")

print("M3. 两台同号机身（防的就是把它们拼成一张）：各自的 JPG 找到各自的 RAW")
d3 = os.path.join(WORK, "dest_m3")
data_m3 = os.path.join(WORK, "data_m3")
cam1_raw = mkcard("card_m3_r1", {"DCIM/100MSDCF/DSC00009.ARW": fake_arw("ILCE-7M4", T1, "500", CAM1)})
cam2_raw = mkcard("card_m3_r2", {"DCIM/100MSDCF/DSC00009.ARW": fake_arw("ILCE-7M4", T1, "500", CAM2)})
cam1_jpg = mkcard("card_m3_j1", {"DCIM/100MSDCF/DSC00009.JPG": fake_jpg("ILCE-7M4", T1, "500", CAM1)})
cam2_jpg = mkcard("card_m3_j2", {"DCIM/100MSDCF/DSC00009.JPG": fake_jpg("ILCE-7M4", T1, "500", CAM2)})
for card in (cam1_raw, cam2_raw, cam2_jpg, cam1_jpg):
    run_card(card, data_m3, d3)
check_raw(listing(d3) == ["DSC00009.ARW", "DSC00009.JPG", "DSC00009_2.ARW", "DSC00009_2.JPG"], f"两对各归各（{listing(d3)}）")
pairs_m3 = {"DSC00009.ARW": cam1_raw, "DSC00009.JPG": cam1_jpg, "DSC00009_2.ARW": cam2_raw, "DSC00009_2.JPG": cam2_jpg}
check_raw(all(same_bytes(os.path.join(d3, k), os.path.join(v, "DCIM/100MSDCF/" + k.replace("_2", ""))) for k, v in pairs_m3.items()),
          "机身 1 的 JPG 配机身 1 的 RAW、机身 2 的配机身 2 的（逐字节核对）")

# ---------- 导到哪：导入根目录可以改（外接盘），盘不在时明说、绝不落回系统盘 ----------
TODAY = time.strftime("%Y%m%d")
rcard = mkcard("card_r", {"DCIM/100CANON/IMG_0001.CR3": rand(400_000), "DCIM/100CANON/IMG_0001.JPG": rand(100_000)})
RFILES = ["IMG_0001.CR3", "IMG_0001.JPG"]


def ingest_to(data, *extra):
    return run_card_env(rcard, data, None, {}, *extra)


print("R1. 记住的导入根目录：照旧在里面按今天建 yyyyMMdd")
root1 = os.path.join(WORK, "root_r1")
os.makedirs(root1)
r = ingest_to(os.path.join(WORK, "data_r1"), "--dest-root", root1)
check(r.returncode == 0 and listing(os.path.join(root1, TODAY)) == RFILES, f"导进了 root_r1/{TODAY}（{listing(os.path.join(root1, TODAY))}）")

print("R2. 外接盘没插上 / 文件夹没了 / 没给目标：不导、明说，不往别处落")
r = ingest_to(os.path.join(WORK, "data_r2"), "--dest-root", "/Volumes/NoSuchDisk_K/照片")
check(r.returncode == 3 and "「NoSuchDisk_K」" in r.stdout and "没插上" in r.stdout, "盘没插上：说出盘名、退出码 3")
check(not os.path.exists("/Volumes/NoSuchDisk_K"), "没在 /Volumes 下建出文件夹")
gone = os.path.join(WORK, "root_gone")
r = ingest_to(os.path.join(WORK, "data_r2"), "--dest-root", gone)
check(r.returncode == 3 and "不在了" in r.stdout and not os.path.exists(gone), "文件夹没了：说「不在了」、没重新建出来")
r = ingest_to(os.path.join(WORK, "data_r2"), "--use-saved-settings")
check(r.returncode == 2, "没记导入位置（= 图片）又没给 --dest：拒绝跑，退出码 2")

print("R3. 记住的位置跟着书签走：根目录改了名照样找得到")
root3 = os.path.join(WORK, "root_r3")
os.makedirs(root3)
data_r3 = os.path.join(WORK, "data_r3")
r = ingest_to(data_r3, "--dest-root", root3, "--save-settings", "--plan-only")
saved = json.load(open(os.path.join(data_r3, "card_import_settings.json")))
check(r.returncode == 0 and saved["root"]["path"].endswith("root_r3") and saved["root"].get("bookmark"), "设置里记了路径和书签")
os.rename(root3, root3 + "_改名")
r = ingest_to(data_r3, "--use-saved-settings")
check(r.returncode == 0 and listing(os.path.join(root3 + "_改名", TODAY)) == RFILES, "导进了改名后的文件夹")
check(not os.path.exists(root3), "没在旧路径上重新建出文件夹")

print("R3b. 记住的导入 / 备份根目录被删掉（挪进废纸篓）：书签会跟进废纸篓 —— 不算还在，说「不在了」、哪儿都不写")
fake_trash = os.path.join(WORK, ".Trash")          # 和 ~/.Trash、/Volumes/X/.Trashes/501 一样认路径里的 .Trash
os.makedirs(fake_trash)
root3t = os.path.join(WORK, "root_r3t")
os.makedirs(root3t)
data_r3t = os.path.join(WORK, "data_r3t")
ingest_to(data_r3t, "--dest-root", root3t, "--save-settings", "--plan-only")
trashed = os.path.join(fake_trash, "root_r3t")
os.rename(root3t, trashed)
r = ingest_to(data_r3t, "--use-saved-settings")
check(r.returncode == 3 and "不在了" in r.stdout, "导入根目录在废纸篓里：退出码 3、说「不在了」")
check(listing(trashed) == [] and not os.path.exists(root3t), f"废纸篓里那个没写东西、旧路径没重建（{listing(trashed)}）")
os.makedirs(root3t)                                  # 用户在原来的地方重新建了一个同名文件夹：导进新建的那个
r = ingest_to(data_r3t, "--use-saved-settings")
check(r.returncode == 0 and listing(os.path.join(root3t, TODAY)) == RFILES and listing(trashed) == [],
      f"原路径上新建的同名文件夹：导进它，不进废纸篓（{listing(os.path.join(root3t, TODAY))}）")
root3u, broot3u = os.path.join(WORK, "root_r3u"), os.path.join(WORK, "backup_r3u")
os.makedirs(root3u)
os.makedirs(broot3u)
data_r3u = os.path.join(WORK, "data_r3u")
ingest_to(data_r3u, "--dest-root", root3u, "--backup", broot3u, "--save-settings", "--plan-only")
trashed_b = os.path.join(fake_trash, "backup_r3u")
os.rename(broot3u, trashed_b)
r = ingest_to(data_r3u, "--use-saved-settings")
check(r.returncode == 3 and "备份位置有问题" in r.stdout and "不在了" in r.stdout, "备份根目录在废纸篓里：退出码 3、说备份位置「不在了」")
check(listing(root3u) == [] and listing(trashed_b) == [], f"导入位置、废纸篓里的备份都没写（{listing(root3u)} / {listing(trashed_b)}）")

print("R4. 路径上有文件夹、但不在记住的那块盘上（/Volumes/T7 没挂时系统盘上同名的空文件夹）：不算，不导")
root4 = os.path.join(WORK, "root_r4")
os.makedirs(root4)
data_r4 = os.path.join(WORK, "data_r4")
ingest_to(data_r4, "--dest-root", root4, "--save-settings", "--plan-only")
settings_path = os.path.join(data_r4, "card_import_settings.json")
saved = json.load(open(settings_path))
saved["root"]["volumeUUID"] = "00000000-0000-0000-0000-00000000C0DE"
saved["root"]["volumeName"] = "T7"
json.dump(saved, open(settings_path, "w"))
r = ingest_to(data_r4, "--use-saved-settings")
check(r.returncode == 3 and "「T7」" in r.stdout and "没插上" in r.stdout, "说「T7」没插上、退出码 3")
check(listing(root4) == [], f"那个文件夹里什么都没写（{listing(root4)}）")

print("R4b. 拿不到卷 UUID 的盘（很多网络共享）：靠挂载点认 —— 共享断了、/Volumes/photo 留下系统盘上的空文件夹（落回了系统盘），不算，不导")
root4b = os.path.join(WORK, "root_r4b")
os.makedirs(root4b)
data_r4b = os.path.join(WORK, "data_r4b")
ingest_to(data_r4b, "--dest-root", root4b, "--save-settings", "--plan-only")
settings_path = os.path.join(data_r4b, "card_import_settings.json")
saved = json.load(open(settings_path))
check(bool(saved["root"].get("volumePath")), f"设置里记了那块盘的挂载点（{saved['root'].get('volumePath')}）")
saved["root"].pop("volumeUUID", None)                    # 像 SMB 共享那样拿不到 UUID，挂载点照实记着
json.dump(saved, open(settings_path, "w"))
r = ingest_to(data_r4b, "--use-saved-settings", "--plan-only")
check(r.returncode == 0 and f"root_r4b/{TODAY}" in r.stdout, "没有 UUID、挂载点对得上：照常出计划")
legacy = dict(saved["root"])
legacy.pop("volumePath", None)                           # 以前的设置没记挂载点、文件夹也不在 /Volumes 下
json.dump(dict(saved, root=legacy), open(settings_path, "w"))
r = ingest_to(data_r4b, "--use-saved-settings", "--plan-only")
check(r.returncode == 0 and f"root_r4b/{TODAY}" in r.stdout, "以前的设置（没记挂载点）、文件夹在系统盘上：照常出计划")
saved["root"]["volumePath"] = "/Volumes/NoSuchDisk_K"   # 记的是那个共享，现在路径上的文件夹在系统盘上
saved["root"]["volumeName"] = "photo"
json.dump(saved, open(settings_path, "w"))
r = ingest_to(data_r4b, "--use-saved-settings")
check(r.returncode == 3 and "「photo」" in r.stdout and "没插上" in r.stdout, "落回了系统盘：说「photo」没插上、退出码 3")
check(listing(root4b) == [], f"那个文件夹里什么都没写（{listing(root4b)}）")

print("R5. 这次导进一个已有的文件夹（追加到已有场次）：不建日期子文件夹；文件夹不在就不导")
exist5 = os.path.join(WORK, "已有场次_r5")
os.makedirs(exist5)
open(os.path.join(exist5, "DSC_0001.JPG"), "wb").write(rand(5000))
r = ingest_to(os.path.join(WORK, "data_r5"), "--into-existing", exist5)
check(r.returncode == 0 and listing(exist5) == sorted(RFILES + ["DSC_0001.JPG"]), f"直接放进已有文件夹（{listing(exist5)}）")
r = ingest_to(os.path.join(WORK, "data_r5b"), "--into-existing", os.path.join(WORK, "没有这个"))
check(r.returncode == 3 and not os.path.exists(os.path.join(WORK, "没有这个")), "不在的文件夹：不导、不建")

print("R6. 确认之后导入根目录被拔掉（挪走）：停下、不在原路径上重建（不会落到系统盘）")
root6 = os.path.join(WORK, "root_r6")
os.makedirs(root6)
r = ingest_to(os.path.join(WORK, "data_r6"), "--dest-root", root6, "--rename-after-plan", root6)
check(r.returncode != 0 and "不见了" in r.stdout, "说导入位置不见了")
check(not os.path.exists(root6) and listing(root6 + ".moved") == [], "原路径没重建，挪走的那个里也没写东西")

print("R6b. 确认之后那块盘换了（排队时拔了、共享断了，原路径上留下系统盘上的空文件夹）：开始导之前再核对卷，不导")
root6b = os.path.join(WORK, "root_r6b")
os.makedirs(root6b)
r = ingest_to(os.path.join(WORK, "data_r6b"), "--dest-root", root6b, "--pretend-volume-changed")
check(r.returncode != 0 and "不在原来那块盘上" in r.stdout and listing(root6b) == [], f"直接导：不导、说不在原来那块盘上（{listing(root6b)}）")
r = ingest_to(os.path.join(WORK, "data_r6b2"), "--dest-root", root6b, "--pretend-volume-changed", "--via-store", "--no-analyze")
check("不在原来那块盘上" in r.stdout and "先别格式化" in r.stdout and listing(root6b) == [],
      "走界面那条（开始时重做计划）：带着确认时的卷身份，照样拦住、提醒先别格式化")
root6c, broot6c = os.path.join(WORK, "root_r6c"), os.path.join(WORK, "backup_r6c")
os.makedirs(root6c)
os.makedirs(broot6c)
r = ingest_to(os.path.join(WORK, "data_r6c"), "--dest-root", root6c, "--backup", broot6c, "--pretend-backup-volume-changed")
check(listing(os.path.join(root6c, TODAY)) == RFILES and listing(broot6c) == [] and r.returncode != 0
      and "不在原来那块盘上" in r.stdout and "先别格式化" in r.stdout, "备份盘换了：主目标照常导完，备份没写、叫人先别格式化")
root6e, broot6e = os.path.join(WORK, "root_r6e"), os.path.join(WORK, "backup_r6e")
os.makedirs(root6e)
os.makedirs(broot6e)
r = ingest_to(os.path.join(WORK, "data_r6e"), "--dest-root", root6e, "--backup", broot6e, "--pretend-backup-volume-changed",
              "--via-store", "--no-analyze")
check(listing(os.path.join(root6e, TODAY)) == RFILES and listing(broot6e) == []
      and "不在原来那块盘上" in r.stdout and "先别格式化" in r.stdout,
      f"备份盘换了、走界面那条：重做的计划也带着备份根目录确认时的卷身份（备份里 {listing(broot6e)}）")
root6d = os.path.join(WORK, "root_r6d")
os.makedirs(root6d)
r = ingest_to(os.path.join(WORK, "data_r6d"), "--dest-root", root6d, "--via-store", "--no-analyze")
check("不在原来那块盘上" not in r.stdout and listing(os.path.join(root6d, TODAY)) == RFILES,
      f"对照：盘没换时走界面那条照常导（{listing(os.path.join(root6d, TODAY))}）")

print("R7. 以前导到的文件夹在一块现在没插上的盘上：说「盘没插上」，不说「文件夹不在了」")
small = rand(50_000)
c7 = mkcard("card_r7", {"DCIM/100CANON/IMG_0700.JPG": small})
fp = hashlib.sha256(small).hexdigest()[:32]
data_r7 = os.path.join(WORK, "data_r7")
os.makedirs(data_r7)
json.dump({"version": 1, "entries": {f"IMG_0700.JPG|{len(small)}|{fp}":
          {"dest": "/Volumes/NoSuchDisk_K/照片/20261001/IMG_0700.JPG", "at": "2026-10-01T09:30:00Z"}}},
          open(os.path.join(data_r7, "import_ledger.json"), "w"))
r = run_card(c7, data_r7, os.path.join(WORK, "dest_r7"), "--plan-only")
check("以前导入过 1 张" in r.stdout and "「NoSuchDisk_K」没插上" in r.stdout and "已经不在了" not in r.stdout,
      "以前导入过 1 张、那块盘没插上")

print("R8. 真的 exFAT 盘（只在 CI 里跑：CARD_REGRESSION_EXFAT=1；别在自己电脑上挂映像）")
if os.environ.get("CARD_REGRESSION_EXFAT") != "1":
    print("  (跳过：没设 CARD_REGRESSION_EXFAT=1)")
else:
    img = os.path.join(WORK, "exfat.sparseimage")
    mnt = os.path.join(WORK, "exfat_mnt")
    os.makedirs(mnt)
    # 映像里不放 DCIM（插卡检测要根目录有 DCIM 才当成存储卡）；-nobrowse 不在访达里出现。
    # 要比 1 GB 余量大（导完那块盘至少还得剩 1 GB：64 MB 的映像永远「空间不够」，这一段从来跑不通 —— 审查发现）；
    # SPARSE 只占实际写进去的那点地方。文件名得带 .sparseimage，不带的话 hdiutil 自己补上，attach 就找不到了。
    subprocess.run(["hdiutil", "create", "-size", "2g", "-type", "SPARSE", "-fs", "ExFAT", "-volname", "KEXFAT", img],
                   check=True, capture_output=True)
    subprocess.run(["hdiutil", "attach", img, "-nobrowse", "-mountpoint", mnt], check=True, capture_output=True)
    try:
        r = ingest_to(os.path.join(WORK, "data_r8"), "--dest-root", mnt, "--plan-only")
        check(r.returncode == 0 and "空间够" in r.stdout, "exFAT 上空间查得出来（不是 0、不是查不到）")
        r = ingest_to(os.path.join(WORK, "data_r8"), "--dest-root", mnt)
        got = os.path.join(mnt, TODAY)
        check(r.returncode == 0 and listing(got) == RFILES, f"exFAT 上照样全导进来（{listing(got)}）")
        check(all(sha(os.path.join(got, f)) == sha(os.path.join(rcard, "DCIM/100CANON", f)) for f in RFILES), "内容逐字节一致")
        check(hidden(got) == [] or all(f.startswith("._") for f in hidden(got)), f"没有残留的 .part（{hidden(got)}）")
    finally:
        subprocess.run(["hdiutil", "detach", mnt, "-force"], capture_output=True)

# ---------- 第二份备份：主目标校验过以后从主目标再写一份到备份盘；备份出问题只停备份、照实报 ----------
bfiles = {"DCIM/100CANON/IMG_0001.CR3": rand(500_000), "DCIM/100CANON/IMG_0001.JPG": rand(120_000),
          "DCIM/100CANON/IMG_0002.CR3": rand(500_000), "DCIM/100CANON/IMG_0002.JPG": rand(120_000)}
bcard = mkcard("card_b", bfiles)
BNAMES = sorted(os.path.basename(k) for k in bfiles)


def same_as_card(folder, names=None):
    return all(sha(os.path.join(folder, n)) == hashlib.sha256(bfiles["DCIM/100CANON/" + n]).hexdigest()
               for n in (names or BNAMES))


def ledger_dests(data):
    path = os.path.join(data, "import_ledger.json")
    return [v["dest"] for v in json.load(open(path))["entries"].values()] if os.path.exists(path) else []


print("B1. 开着备份：两份都逐字节一致，账本照旧只记主目标，哪边都没有残留的 .part")
d, broot = os.path.join(WORK, "dest_b1"), os.path.join(WORK, "backup_b1")
os.makedirs(broot)
data_b1 = os.path.join(WORK, "data_b1")
r = run_card_env(bcard, data_b1, d, {}, "--backup", broot)
bdest = os.path.join(broot, "dest_b1")
check(r.returncode == 0 and listing(d) == BNAMES and listing(bdest) == BNAMES, f"主目标、备份都是 4 个（{listing(d)} / {listing(bdest)}）")
check(same_as_card(d) and same_as_card(bdest), "两份内容都和卡上一样")
check(hidden(d) == [] and hidden(bdest) == [], "没有残留的 .part")
dests = ledger_dests(data_b1)
check(len(dests) == 4 and all(x.startswith(os.path.realpath(d)) or x.startswith(d) for x in dests), f"账本只记主目标（{dests[:1]}…）")
check("另备份 4 个文件" in r.stdout and "导入提醒" not in r.stdout, "摘要说另备份了 4 个，没有提醒")

print("B1b. 走界面那条路（重做计划 → 复制 → 打开）：照样两份")
d, broot = os.path.join(WORK, "dest_b1b"), os.path.join(WORK, "backup_b1b")
os.makedirs(broot)
r = run_card_env(bcard, os.path.join(WORK, "data_b1b"), d, {}, "--backup", broot, "--via-store", "--no-analyze")
check(listing(d) == BNAMES and listing(os.path.join(broot, "dest_b1b")) == BNAMES and same_as_card(os.path.join(broot, "dest_b1b")),
      "主目标、备份都齐了")
check("另备份 4 个文件" in r.stdout and "导入提醒" not in r.stdout, "顶栏摘要说另备份了 4 个，没有提醒")

print("B2. 备份里同名的是别的文件：两边一起换一个都空着的名字，备份里那个不动")
d, broot = os.path.join(WORK, "dest_b2"), os.path.join(WORK, "backup_b2")
os.makedirs(os.path.join(broot, "dest_b2"))
planted_b2 = os.path.join(broot, "dest_b2", "IMG_0001.CR3")
open(planted_b2, "wb").write(rand(7000))
planted_sha = sha(planted_b2)
r = run_card_env(bcard, os.path.join(WORK, "data_b2"), d, {}, "--backup", broot)
want_b2 = ["IMG_0001_2.CR3", "IMG_0001_2.JPG", "IMG_0002.CR3", "IMG_0002.JPG"]
check(r.returncode == 0 and listing(d) == want_b2, f"主目标里 IMG_0001 也改成了 _2，两边名字一样（{listing(d)}）")
check(listing(os.path.join(broot, "dest_b2")) == sorted(want_b2 + ["IMG_0001.CR3"]) and sha(planted_b2) == planted_sha,
      "备份里原来那个没动，新的用 _2")

print("B3. 备份盘中途写满：主目标照样导完，备份停下、照实报，叫人先别格式化")
d, broot = os.path.join(WORK, "dest_b3"), os.path.join(WORK, "backup_b3")
os.makedirs(broot)
data_b3 = os.path.join(WORK, "data_b3")
r = run_card_env(bcard, data_b3, d, {}, "--backup", broot, "--backup-full-at", "2")
check(listing(d) == BNAMES and same_as_card(d), "主目标 4 个都导进来了")
check(len(listing(os.path.join(broot, "dest_b3"))) == 1 and hidden(os.path.join(broot, "dest_b3")) == [], "备份里只有满之前那 1 个，没有 .part")
check(r.returncode != 0 and "备份没写全" in r.stdout and "先别格式化" in r.stdout and "备份盘满了" in r.stdout,
      "退出码非 0，提醒说备份没写全（备份盘满了）、先别格式化")
check("导进同一个文件夹「" in r.stdout and "dest_b3」" in r.stdout, "补备份的指引写出了要导回的那个文件夹")

print("B4. 补备份：再插一次、勾重导 → 主目标里的不重复复制，只从主目标补到备份")
r = run_card_env(bcard, data_b3, d, {}, "--backup", broot, "--reimport")
check(r.returncode == 0 and "目标里已有 2 张" in r.stdout and "补备份 3 个" in r.stdout, "计划：目标里已有 2 张、补备份 3 个")
check(listing(d) == BNAMES and listing(os.path.join(broot, "dest_b3")) == BNAMES and same_as_card(os.path.join(broot, "dest_b3")),
      "主目标没多出 _2，备份补齐、逐字节一致")

print("B5. 备份盘中途被拔：主目标照样导完，不在原路径上重建备份文件夹")
d, broot = os.path.join(WORK, "dest_b5"), os.path.join(WORK, "backup_b5")
os.makedirs(broot)
r = run_card_env(bcard, os.path.join(WORK, "data_b5"), d, {}, "--backup", broot, "--unplug-backup-after", "1")
check(listing(d) == BNAMES and same_as_card(d), "主目标 4 个都导进来了")
check(not os.path.exists(broot) and r.returncode != 0 and "备份盘找不到了" in r.stdout, "说备份盘找不到了，原路径没重建")

print("B6. 备份盘没插上 / 和导入位置是同一个地方：不导（开着备份的人以为有两份）")
d = os.path.join(WORK, "dest_b6")
r = run_card_env(bcard, os.path.join(WORK, "data_b6"), d, {}, "--backup", "/Volumes/NoSuchDisk_K/备份")
check(r.returncode == 3 and "备份位置有问题" in r.stdout and "没插上" in r.stdout and not os.path.exists(d), "备份盘没插上：退出码 3、主目标也没写")
root_b6 = os.path.join(WORK, "root_b6")
os.makedirs(root_b6)
r = run_card_env(bcard, os.path.join(WORK, "data_b6"), None, {}, "--dest-root", root_b6, "--backup", root_b6)
check(r.returncode == 3 and "同一个地方" in r.stdout and listing(root_b6) == [], "备份位置就是导入位置：拒绝")

print("B7. 确认框自己那条路（CardImportCenter.replan，后台找目标 / 备份位置再出计划）：说不通的不出计划")


def card_ui(*extra):
    env = dict(os.environ, LABELGUI_DATA_DIR=os.path.join(WORK, "data_b7"))
    png = os.path.join(WORK, "card_ui_b7.png")
    r = subprocess.run([BIN, "--card-ui", bcard, png, "--via-replan", *extra], env=env,
                       capture_output=True, text=True, timeout=120)
    print("    " + r.stdout.strip().replace("\n", "\n    "))
    return r


root_b7, broot_b7 = os.path.join(WORK, "root_b7"), os.path.join(WORK, "backup_b7")
os.makedirs(root_b7)
os.makedirs(broot_b7)
r = card_ui("--dest-root", root_b7, "--backup", broot_b7)
check(r.returncode == 0 and "要导入：2 张" in r.stdout and f"root_b7/{TODAY}" in r.stdout and "备份：" in r.stdout,
      "导入位置、备份都在：出了计划（2 张，带备份）")
r = card_ui("--dest-root", "/Volumes/NoSuchDisk_K/照片")
check(r.returncode == 0 and "导入位置有问题" in r.stdout and "要导入" not in r.stdout, "导入位置的盘没插上：不出计划，说清楚")
r = card_ui("--dest-root", root_b7, "--backup", "/Volumes/NoSuchDisk_K/备份")
check(r.returncode == 0 and "备份位置有问题" in r.stdout and "要导入" not in r.stdout, "备份盘没插上：不出计划，说清楚")
check(listing(root_b7) == [] and listing(broot_b7) == [], "确认框读卡不往任何地方写")

print("B8. 开着备份、取消落在一张照片最后那个文件的备份上：那个文件不记账本，再插一次（不勾重导）就从主目标补上备份")
d, broot = os.path.join(WORK, "dest_b8"), os.path.join(WORK, "backup_b8")
os.makedirs(broot)
data_b8 = os.path.join(WORK, "data_b8")
bdest = os.path.join(broot, "dest_b8")
# 字节按主目标、备份一起数：IMG_0001.CR3 50 万 + 它的备份 50 万 + IMG_0001.JPG 12 万 = 112 万，再多一个字节就落在 JPG 的备份上。
r = run_card_env(bcard, data_b8, d, {}, "--backup", broot, "--cancel-at-bytes", str(1_120_001))
check("已取消导入" in r.stdout and listing(d) == ["IMG_0001.CR3", "IMG_0001.JPG"] and listing(bdest) == ["IMG_0001.CR3"],
      f"取消时 JPG 主目标那份写成了、备份没写成（{listing(d)} / {listing(bdest)}）")
check(hidden(d) == [] and hidden(bdest) == [], "两边都没有残留的 .part")
dests_b8 = ledger_dests(data_b8)
check(len(dests_b8) == 1 and dests_b8[0].endswith("IMG_0001.CR3"), f"账本只记了两份都写成的 IMG_0001.CR3（{[os.path.basename(x) for x in dests_b8]}）")
r = run_card_env(bcard, data_b8, d, {}, "--backup", broot, "--plan-only")
check("补备份 1 个" in r.stdout and "要导入：1 张" in r.stdout, "再插一次：从主目标补备份 1 个（IMG_0001.JPG）、导剩下的 1 张")
# 这次取消落在补备份那一步（IMG_0002 两份 124 万字节之后）：补备份的那个也不该先记进账本。
r = run_card_env(bcard, data_b8, d, {}, "--backup", broot, "--cancel-at-bytes", str(1_240_001))
check("已取消导入" in r.stdout and "IMG_0001.JPG" not in listing(bdest) and len(listing(bdest)) == 3,
      f"取消落在补备份上：IMG_0002 两份都齐，IMG_0001.JPG 的备份没写成（{listing(bdest)}）")
check(not any(x.endswith("IMG_0001.JPG") for x in ledger_dests(data_b8)), "补备份没写成的 IMG_0001.JPG 还是没记账本")
r = run_card_env(bcard, data_b8, d, {}, "--backup", broot)
check(r.returncode == 0 and listing(d) == BNAMES and listing(bdest) == BNAMES and same_as_card(bdest),
      f"两份都齐了、逐字节一致（{listing(bdest)}）")

print("B9. 换了一天来补备份：提醒写出原来那个文件夹；勾重导时计划里说「会再复制一份」，「改成导进那个文件夹」只补备份")
root_b9, broot_b9 = os.path.join(WORK, "root_b9"), os.path.join(WORK, "backup_b9")
yday = os.path.join(root_b9, "20261001")              # 「昨天」那场：这次导进一个已有的文件夹
os.makedirs(yday)
os.makedirs(broot_b9)
data_b9 = os.path.join(WORK, "data_b9")
r = run_card_env(bcard, data_b9, None, {}, "--into-existing", yday, "--backup", broot_b9, "--backup-full-at", "2")
notice = [l for l in r.stdout.splitlines() if l.startswith("导入提醒：")]
check(r.returncode != 0 and len(notice) == 1 and "备份没写全" in notice[0] and "root_b9/20261001" in notice[0]
      and "这次导进一个已有的文件夹" in notice[0], f"提醒写出了原来那个文件夹、怎么选回它（{notice}）")
r = run_card_env(bcard, data_b9, None, {}, "--dest-root", root_b9, "--backup", broot_b9, "--reimport", "--plan-only")
warn = [l for l in r.stdout.splitlines() if l.startswith("重导提醒：")]
check(len(warn) == 1 and warn[0].startswith("重导提醒：以前导到 ") and "root_b9/20261001" in warn[0],
      f"今天的文件夹 + 勾重导：计划里提醒以前导到 20261001、会再复制一份（{warn}）")
r = run_card_env(bcard, data_b9, None, {}, "--into-existing", yday, "--backup", broot_b9, "--reimport", "--plan-only")
check("重导提醒" not in r.stdout and "要导入：没有" in r.stdout and "补备份 3 个" in r.stdout, "导回原来那个文件夹：不提醒，只补备份 3 个")
png_b9 = os.path.join(WORK, "card_ui_b9.png")
r = subprocess.run([BIN, "--card-ui", bcard, png_b9, "--via-replan", "--reimport", "--then-into-previous",
                    "--dest-root", root_b9, "--backup", broot_b9],
                   env=dict(os.environ, LABELGUI_DATA_DIR=data_b9), capture_output=True, text=True, timeout=120)
print("    " + r.stdout.strip().replace("\n", "\n    "))
check(r.returncode == 0 and "重导提醒" not in r.stdout and "要导入：没有" in r.stdout and "补备份 3 个" in r.stdout
      and "root_b9/20261001（原有 4 个文件）" in r.stdout, "确认框点「改成导进那个文件夹」：重读出的计划只补备份 3 个")
r = run_card_env(bcard, data_b9, None, {}, "--into-existing", yday, "--backup", broot_b9, "--reimport")
check(r.returncode == 0 and listing(yday) == BNAMES and listing(os.path.join(broot_b9, "20261001")) == BNAMES
      and same_as_card(os.path.join(broot_b9, "20261001")) and not os.path.exists(os.path.join(root_b9, TODAY)),
      f"原来那份备份补齐了，主目标没多出 _2、也没建今天的文件夹（{listing(os.path.join(broot_b9, '20261001'))}）")

# ---------- 日期文件夹的名字被挪走了的那一场占着（审查）：场次按路径的哈希认，改了名 / 挪走的那一场 key 还是原路径的 ----------
def bmp_l(w, h):
    """真能解码的 BMP（随机字节的「JPG」解不开：分析不出照片、不进「最近场次」，就测不到书签那一路）。"""
    row = (w * 3 + 3) & ~3
    pixels = os.urandom(row * h)
    header = b"BM" + (54 + len(pixels)).to_bytes(4, "little") + b"\0\0\0\0" + (54).to_bytes(4, "little")
    info = (40).to_bytes(4, "little") + w.to_bytes(4, "little") + h.to_bytes(4, "little") + \
        (1).to_bytes(2, "little") + (24).to_bytes(2, "little") + b"\0" * 24
    return header + info + pixels


def opened_l(stdout):
    """「现在打开的：<照片文件夹> · N 张 · 状态栏」那一行拆成 (文件夹, 整行)。"""
    line = next((l for l in stdout.splitlines() if l.startswith("现在打开的：")), "")
    return line[len("现在打开的："):].split(" · ")[0], line


def manifests_l(data):
    """数据目录里各场 manifest：key → (photo_dir, 照片路径列表)。"""
    out = {}
    sessions = os.path.join(data, "sessions")
    for key in sorted(os.listdir(sessions)) if os.path.isdir(sessions) else []:
        path = os.path.join(sessions, key, "manifest.json")
        if os.path.exists(path):
            j = json.load(open(path))
            out[key] = (j.get("photo_dir", ""), [p.get("raw_path", "") for p in j.get("photos", [])])
    return out


root_l = os.path.join(WORK, "root_l")
os.makedirs(root_l)
data_l = os.path.join(WORK, "data_l")
p_l = os.path.join(root_l, TODAY)
q_l = os.path.join(root_l, TODAY + " 张三")
p2_l = p_l + "-2"
LNAMES = ["IMG_0001.BMP", "IMG_0002.BMP"]

print("L1. 第一张卡导进 yyyyMMdd、分析完；改了名以后同一天再导一张：导进 yyyyMMdd-2，打开、分析的是新卡")
card_la = mkcard("card_la", {"DCIM/100CANON/" + n: bmp_l(320, 240) for n in LNAMES})
r = run_card_env(card_la, data_l, None, {}, "--dest-root", root_l, "--via-store")
folder, line = opened_l(r.stdout)
check(r.returncode == 0 and listing(p_l) == LNAMES and folder.endswith("/" + TODAY) and " · 2 张" in line,
      f"第一张卡导进 {TODAY}、打开并分析了 2 张（{line}）")
a_sizes = {n: os.path.getsize(os.path.join(p_l, n)) for n in LNAMES}
os.rename(p_l, q_l)                       # 用户在访达里把这一场改名成「yyyyMMdd 张三」
card_lb = mkcard("card_lb", {"DCIM/100CANON/" + n: bmp_l(360, 240) for n in LNAMES})   # 第二机位：同名、不同片
r = run_card_env(card_lb, data_l, None, {}, "--dest-root", root_l, "--via-store")
folder, line = opened_l(r.stdout)
check(f"{TODAY}-2（原有 0 个文件）" in r.stdout, f"计划的目标是 {TODAY}-2（{TODAY} 这个名字被改了名的那一场占着）")
check(r.returncode == 0 and listing(p2_l) == LNAMES and not os.path.exists(p_l),
      f"导进了 {TODAY}-2，没在原路径上重新建出 {TODAY}（{listing(p2_l)}）")
check(folder.endswith("/" + TODAY + "-2") and " · 2 张" in line and "lastError" not in r.stdout,
      f"自动打开、分析的是 {TODAY}-2 这一场（新卡的 2 张），不是改了名的那一场（{line}）")
check(listing(q_l) == LNAMES and all(os.path.getsize(os.path.join(q_l, n)) == a_sizes[n] for n in LNAMES),
      "改了名的那一场的照片没被动")
q_session = [k for k, (d, _) in manifests_l(data_l).items() if d.endswith(" 张三")]
check(len(q_session) == 1, f"改了名的那一场还在（manifest 跟到了新名字，{manifests_l(data_l)}）")

print("L2. 同一天第三张卡：yyyyMMdd-2 是它自己那一场的，照旧导进去（追加），不再往后编号")
card_lc = mkcard("card_lc", {"DCIM/100CANON/IMG_0003.BMP": bmp_l(320, 200)})
r = run_card_env(card_lc, data_l, None, {}, "--dest-root", root_l, "--via-store")
folder, line = opened_l(r.stdout)
check(r.returncode == 0 and listing(p2_l) == LNAMES + ["IMG_0003.BMP"] and not os.path.exists(p_l + "-3"),
      f"导进了 {TODAY}-2（{listing(p2_l)}）")
check(folder.endswith("/" + TODAY + "-2") and " · 3 张" in line, f"打开、分析的是 {TODAY}-2 这一场，3 张（{line}）")

print("L3. 「这次导进一个已有的文件夹…」选了原路径（上面又建了 yyyyMMdd）：自动打开认出的是改了名的那一场 —— 不接着分析，红条和横幅说要先改名")
os.makedirs(p_l)
card_ld = mkcard("card_ld", {"DCIM/100CANON/" + n: bmp_l(400, 240) for n in LNAMES})   # 同名、不同片
q_before = manifests_l(data_l)[q_session[0]] if q_session else None
r = run_card_env(card_ld, data_l, None, {}, "--into-existing", p_l, "--via-store")
folder, line = opened_l(r.stdout)
err = next((l for l in r.stdout.splitlines() if l.startswith("lastError：")), "")
notice = next((l for l in r.stdout.splitlines() if l.startswith("导入提醒：")), "")
check(r.returncode == 0 and listing(p_l) == LNAMES, f"照片导进了选的 {TODAY}（{listing(p_l)}）")
check(folder.endswith("/" + TODAY + " 张三") and " · 2 张" in line, f"按 {TODAY} 认出的是改了名的那一场（{line}）")
check("另一个文件夹" in err and "改个名" in err, f"红条说原路径现在是另一个文件夹、要改名再开，没被接着的分析清掉（{err}）")
check("分析" not in line.split(" · ", 2)[-1], f"没接着分析改了名的那一场（{line}）")
check("2 张导到了" in notice and "改个名" in notice and "选择文件夹" in notice, f"导入横幅说新导的这批没打开、怎么打开（{notice}）")
check(q_session and manifests_l(data_l).get(q_session[0]) == q_before, "改了名的那一场的 manifest 一字没动（新卡的照片没混进去）")

print("L4. 改了名的那一场所在的盘拔了（书签解析不到）、原路径上是另一张卡的同名照片：启动重开、导完自动打开都不把那一场的照片路径改回原路径，也不接着分析")
stash_l = os.path.join(WORK, "unplugged_l")
shutil.copytree(q_l, stash_l)              # 盘上的东西拷一份留着，再删掉（改名不行：书签跟着改名走）
shutil.rmtree(q_l)
card_le = mkcard("card_le", {"DCIM/100CANON/IMG_0009.BMP": bmp_l(300, 200)})
r = run_card_env(card_le, data_l, None, {}, "--into-existing", p_l, "--via-store")
folder, line = opened_l(r.stdout)
err = next((l for l in r.stdout.splitlines() if l.startswith("lastError：")), "")
notice = next((l for l in r.stdout.splitlines() if l.startswith("导入提醒：")), "")
after = manifests_l(data_l)
check(r.returncode == 0 and listing(p_l) == LNAMES + ["IMG_0009.BMP"], f"照片导进了选的 {TODAY}（{listing(p_l)}）")
check(q_session and after.get(q_session[0]) == q_before, "那一场的 manifest 一字没动（照片路径没被改到原路径上那张卡的同名照片上）")
check(not any(d.rstrip("/").endswith("/" + TODAY) for d, _ in after.values()),
      f"没有哪一场的照片文件夹记成原路径（原路径上的新卡没被当成那一场分析，{sorted(d for d, _ in after.values())}）")
check(folder.endswith("/" + TODAY + " 张三") and "已改到" not in r.stdout and "分析" not in line.split(" · ", 2)[-1],
      f"打开的是记在拔掉的盘上的那一场，不说「照片路径已改到现在的位置」，没接着分析（{line}）")
check("不是这一场的照片" in err and "重新定位文件夹" in err, f"红条说原路径上的不是这一场的照片、照片路径没改（{err}）")
check("改个名" in notice, f"导入横幅说新导的这批没打开、要先改名（{notice}）")

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
if raw_skipped:
    print(f"（跳过 {len(raw_skipped)} 条要读 RAW 文件头的断言：这台机器的 ImageIO 读不出伪 RAW 的文件头）")
print("存储卡导入回归全部通过" if not failures else f"存储卡导入回归 {len(failures)} 项失败")
if CLEANUP and not failures:
    subprocess.run(["chmod", "-R", "u+rwX", WORK])   # chmod 000 的东西不放开 rmtree 删不掉
    shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if failures else 0)
