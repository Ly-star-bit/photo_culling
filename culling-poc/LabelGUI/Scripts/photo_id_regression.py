#!/usr/bin/env python3
"""照片 id 稳定回归：后加 / 移走同名文件以后，没动过的照片 id 不变，人工改判还对得上。

用法: python3 -I Scripts/photo_id_regression.py <LabelGUI 可执行文件> [工作目录的上级]
      KEEP=1 ...   # 跑完留着工作目录（排查用）
工作目录默认建在 culling-poc/LabelGUI/.build 底下（已被 .gitignore 忽略）：系统临时目录在 /var → /private/var
的符号链接底下，带路径的 id 在那里会多带上拍摄文件夹的名字（见 H 组），前几组要核对的是平常 ~/Pictures、/Volumes 底下的起名。

用 sips 合成几十张小 JPEG / PNG 放进临时目录，跑 `--analyze` 两三遍，中间加 / 删 / 换文件，
读 sessions/<key>/manifest.json 核对「文件 → id」，写 overrides.json 再用 `--verdicts --per-photo` 核对改判还在。
每次调用都带临时的 LABELGUI_DATA_DIR、LABELGUI_NO_GUI=1、LABELGUI_LIVE_SOCK_ROOT，不碰真实数据目录。
改 ImageLoader.listPhotos / PhotoIDMemory.swift / AnalysisEngine.analyzeFolder 的复用部分先跑它。
"""
import hashlib, json, os, random, re, shutil, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1])
PARENT = sys.argv[2] if len(sys.argv) > 2 else \
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".build")
os.makedirs(PARENT, exist_ok=True)
WORK = tempfile.mkdtemp(prefix="photo-id-", dir=os.path.realpath(PARENT))
# H 组：系统临时目录（/var/folders，/var → /private/var 的符号链接），路径原样不解析。
LINKED_WORK = tempfile.mkdtemp(prefix="photo-id-linked-")
SOCK = tempfile.mkdtemp(prefix="photo-id-sock-")
SRC = os.path.join(WORK, "src")
os.makedirs(SRC)
rng = random.Random(11)
failures = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


def env_for(data):
    env = dict(os.environ, LABELGUI_DATA_DIR=data, LABELGUI_NO_GUI="1", LABELGUI_LIVE_SOCK_ROOT=SOCK)
    env.setdefault("LABELGUI_MCP_OUT", os.path.join(WORK, "mcp-out"))
    return env


def bmp(w, h, seed):
    # 渐变 + 色块 + 噪点：每张不一样（pHash 不同，不被当成连拍重复），解得开、分析得动。
    r = random.Random(seed)
    row = (w * 3 + 3) & ~3
    base = [r.randrange(256) for _ in range(3)]
    bx, by = r.randrange(w // 2), r.randrange(h // 2)
    out = bytearray()
    for y in range(h):
        line = bytearray()
        for x in range(w):
            inside = bx <= x < bx + w // 3 and by <= y < by + h // 3
            for c in range(3):
                v = (base[c] + x * (c + 1) // 2 + y * (3 - c) // 2) % 256
                if inside:
                    v = 255 - v
                line.append((v + r.randrange(24)) % 256)
        line += b"\0" * (row - w * 3)
        out += line
    header = b"BM" + (54 + len(out)).to_bytes(4, "little") + b"\0\0\0\0" + (54).to_bytes(4, "little")
    info = (40).to_bytes(4, "little") + w.to_bytes(4, "little") + h.to_bytes(4, "little") + \
        (1).to_bytes(2, "little") + (24).to_bytes(2, "little") + b"\0" * 24
    return header + info + bytes(out)


_pool = {}


def image(fmt, n):
    """第 n 张合成图（jpeg / png），做一次、之后拷贝。"""
    key = (fmt, n)
    if key not in _pool:
        src = os.path.join(SRC, f"{n}.bmp")
        with open(src, "wb") as f:
            f.write(bmp(240, 160, 1000 + n))
        dst = os.path.join(SRC, f"{n}.{fmt}")
        r = subprocess.run(["sips", "-s", "format", fmt, src, "--out", dst], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(dst):
            sys.exit(f"sips 转 {fmt} 失败: {r.stderr.strip()}")
        _pool[key] = dst
    return _pool[key]


_serial = [0]


def put(shoot, rel, fmt="jpeg"):
    _serial[0] += 1
    path = os.path.join(shoot, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    shutil.copyfile(image(fmt, _serial[0]), path)
    return path


def put_junk(shoot, rel):
    path = os.path.join(shoot, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(bytes(rng.getrandbits(8) for _ in range(4096)))
    return path


class Shoot:
    def __init__(self, name, base=None):
        self.root = os.path.join(base or WORK, name)
        self.data = os.path.join(WORK, name + "-data")
        os.makedirs(self.root)
        os.makedirs(self.data)
        r = subprocess.run([BIN, "--session-key", self.root], env=env_for(self.data),
                           capture_output=True, text=True, timeout=60)
        self.session = os.path.join(self.data, "sessions", r.stdout.strip())

    def put(self, rel, fmt="jpeg"):
        return put(self.root, rel, fmt)

    def rm(self, rel):
        os.remove(os.path.join(self.root, rel))

    def analyze(self):
        r = subprocess.run([BIN, "--analyze", self.root], env=env_for(self.data),
                           capture_output=True, text=True, timeout=600)
        done = re.search(r"Done: (\d+) analyzed, (\d+) reused", r.stdout)
        failed = re.search(r"Failed \(\d+\): (.*)", r.stdout)
        if r.returncode != 0 or not done:
            print("    [stdout] " + r.stdout.strip()[-600:])
            print("    [stderr] " + r.stderr.strip()[-600:])
        return {
            "ok": r.returncode == 0 and done is not None,
            "analyzed": int(done.group(1)) if done else -1,
            "reused": int(done.group(2)) if done else -1,
            "failed": failed.group(1).split(", ") if failed else [],
        }

    def ids(self):
        """manifest 里「相对路径（XMP 跟着的那个文件）→ id」，外加 decode_path 那一份。"""
        with open(os.path.join(self.session, "manifest.json")) as f:
            m = json.load(f)
        root = os.path.realpath(self.root)
        by_raw, by_decode = {}, {}
        for p in m["photos"]:
            by_raw[os.path.relpath(os.path.realpath(p["raw_path"]), root)] = p["id"]
            by_decode[os.path.relpath(os.path.realpath(p["decode_path"]), root)] = p["id"]
        return by_raw, by_decode

    def write(self, name, obj):
        with open(os.path.join(self.session, name), "w") as f:
            json.dump(obj, f, ensure_ascii=False)

    def edit(self, name, fn):
        path = os.path.join(self.session, name)
        with open(path) as f:
            obj = json.load(f)
        fn(obj)
        with open(path, "w") as f:
            json.dump(obj, f, ensure_ascii=False)

    def preview_sha(self, pid):
        path = os.path.join(self.session, "previews", pid + ".jpg")
        if not os.path.exists(path):
            return None
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()

    def verdicts(self):
        r = subprocess.run([BIN, "--verdicts", self.root, "--per-photo"], env=env_for(self.data),
                           capture_output=True, text=True, timeout=120)
        out, started = {}, False
        for line in r.stdout.splitlines():
            if line.startswith("阈值:"):
                started = True
                continue
            parts = line.split()
            if started and len(parts) >= 2 and line.startswith("  "):
                out[parts[0]] = parts[1]
        return out


def expect_ids(shoot, want, label):
    by_raw, _ = shoot.ids()
    for rel, pid in want.items():
        got = by_raw.get(rel)
        check(got == pid, f"{label}: {rel} → {pid}" + ("" if got == pid else f"（实际 {got}）"))
    extra = sorted(set(by_raw) - set(want))
    check(not extra, f"{label}: manifest 里没有多出来的照片" + ("" if not extra else f"（多了 {extra}）"))


def expect_run(res, analyzed, reused, label):
    check(res["ok"] and res["analyzed"] == analyzed and res["reused"] == reused,
          f"{label}: 分析 {analyzed} 张、复用 {reused} 张（实际 {res['analyzed']} / {res['reused']}）")


def run_all():
    print("A. 两个子文件夹里各有一张 DSC_0001，改判过留下的那张，另一张移走以后重新分析")
    a = Shoot("shoot_a")
    a.put("仪式/DSC_0001.JPG"); a.put("晚宴/DSC_0001.JPG"); a.put("仪式/DSC_0002.JPG")
    expect_run(a.analyze(), 3, 0, "第一次")
    expect_ids(a, {"仪式/DSC_0001.JPG": "仪式_DSC_0001", "晚宴/DSC_0001.JPG": "晚宴_DSC_0001",
                   "仪式/DSC_0002.JPG": "DSC_0002"}, "第一次（新场次照老规矩起名）")
    a.write("overrides.json", {"仪式_DSC_0001": "精选", "DSC_0002": "废片"})
    a.write("client_picks.json", ["仪式_DSC_0001"])
    a.rm("晚宴/DSC_0001.JPG")
    expect_run(a.analyze(), 0, 2, "移走以后")
    expect_ids(a, {"仪式/DSC_0001.JPG": "仪式_DSC_0001", "仪式/DSC_0002.JPG": "DSC_0002"},
               "移走以后（不变回 DSC_0001）")
    v = a.verdicts()
    check(v.get("仪式_DSC_0001") == "精选" and v.get("DSC_0002") == "废片",
          f"改判还对得上：仪式_DSC_0001 精选、DSC_0002 废片（实际 {v}）")

    print("A2. 同上，但旧结果是别的分析版本写的（整场重分析）：id 照样沿用")
    a2 = Shoot("shoot_a2")
    a2.put("仪式/DSC_0001.JPG"); a2.put("晚宴/DSC_0001.JPG"); a2.put("仪式/DSC_0002.JPG")
    expect_run(a2.analyze(), 3, 0, "第一次")
    a2.write("overrides.json", {"仪式_DSC_0001": "精选"})
    a2.edit("layer1_results.json", lambda j: j.update(analysis_version=1))
    a2.rm("晚宴/DSC_0001.JPG")
    expect_run(a2.analyze(), 2, 0, "版本对不上 → 整场重分析")
    expect_ids(a2, {"仪式/DSC_0001.JPG": "仪式_DSC_0001", "仪式/DSC_0002.JPG": "DSC_0002"}, "重分析以后 id 不变")
    check(a2.verdicts().get("仪式_DSC_0001") == "精选", "改判还对得上")

    print("B. 主机位在子文件夹里、改判过，后来放进号码重叠的副机位子文件夹")
    b = Shoot("shoot_b")
    b.put("主机位/DSCF0001.JPG"); b.put("主机位/DSCF0002.JPG")
    expect_run(b.analyze(), 2, 0, "第一次")
    expect_ids(b, {"主机位/DSCF0001.JPG": "DSCF0001", "主机位/DSCF0002.JPG": "DSCF0002"}, "第一次")
    b.write("overrides.json", {"DSCF0001": "精选", "DSCF0002": "废片"})
    b.write("client_picks.json", ["DSCF0002"])
    b.put("副机位/DSCF0001.JPG"); b.put("副机位/DSCF0003.JPG")
    expect_run(b.analyze(), 2, 2, "加了副机位")
    expect_ids(b, {"主机位/DSCF0001.JPG": "DSCF0001", "主机位/DSCF0002.JPG": "DSCF0002",
                   "副机位/DSCF0001.JPG": "副机位_DSCF0001", "副机位/DSCF0003.JPG": "DSCF0003"},
               "加了副机位（主机位不改名，只有新来的带路径）")
    v = b.verdicts()
    check(v.get("DSCF0001") == "精选" and v.get("DSCF0002") == "废片",
          f"改判还对得上：DSCF0001 精选、DSCF0002 废片（实际 DSCF0001={v.get('DSCF0001')} DSCF0002={v.get('DSCF0002')}）")
    print("B2. 接着在主机位 JPG 旁边补拷 RAF（主文件换成 RAF）：按 decode_path 认")
    put_junk(b.root, "主机位/DSCF0001.RAF")   # 解码走 JPG，RAF 只是 XMP 跟着的主文件，内容随便
    expect_run(b.analyze(), 0, 4, "补了 RAF")
    by_raw, by_decode = b.ids()
    check(by_raw.get("主机位/DSCF0001.RAF") == "DSCF0001" and by_decode.get("主机位/DSCF0001.JPG") == "DSCF0001",
          f"主机位 RAF+JPG 一张照片、还叫 DSCF0001（实际 raw→{by_raw.get('主机位/DSCF0001.RAF')}）")
    print("B3. 再把 JPG 删掉只剩 RAF：按 raw_path 认（RAF 是随机字节解不开，报失败的那张还叫 DSCF0001）")
    b.rm("主机位/DSCF0001.JPG")
    res = b.analyze()
    check(res["failed"] == ["DSCF0001"], f"失败的是 DSCF0001，不是 主机位_DSCF0001（实际 {res['failed']}）")

    print("C. 子文件夹里的 DSCF0001 改判过，根目录后来放进一张同名的")
    c = Shoot("shoot_c")
    c.put("主机位/DSCF0001.JPG"); c.put("主机位/DSCF0002.JPG")
    expect_run(c.analyze(), 2, 0, "第一次")
    c.write("overrides.json", {"DSCF0001": "精选"})
    sha_before = c.preview_sha("DSCF0001")
    c.put("DSCF0001.JPG")
    expect_run(c.analyze(), 1, 2, "根目录加了同名的")
    expect_ids(c, {"主机位/DSCF0001.JPG": "DSCF0001", "主机位/DSCF0002.JPG": "DSCF0002", "DSCF0001.JPG": "DSCF0001_2"},
               "根目录新来的拿 DSCF0001_2，不顶替原来那张")
    check(sha_before is not None and c.preview_sha("DSCF0001") == sha_before, "previews/DSCF0001.jpg 没被新来的那张盖掉")
    check(c.preview_sha("DSCF0001_2") is not None, "新来的那张有自己的预览图")
    check(c.verdicts().get("DSCF0001") == "精选", "改判还在原来那张上")

    print("D. 对照：根目录 DSCF0001 + 后来加 B/DSCF0001（以前就不改名）")
    d = Shoot("shoot_d")
    d.put("DSCF0001.JPG"); d.put("DSCF0002.JPG")
    expect_run(d.analyze(), 2, 0, "第一次")
    d.put("B/DSCF0001.JPG")
    expect_run(d.analyze(), 1, 2, "加了 B")
    expect_ids(d, {"DSCF0001.JPG": "DSCF0001", "DSCF0002.JPG": "DSCF0002", "B/DSCF0001.JPG": "B_DSCF0001"}, "id 不变")

    print("E. 老场次：manifest 里的 id 不是现在这套规矩起的（老版本只带一级文件夹、Python 管线没写 photo_dir），原样留着")
    e = Shoot("shoot_e")
    e.put("仪式/JPG/DSC_0005.JPG"); e.put("DSC_0006.JPG")
    expect_run(e.analyze(), 2, 0, "第一次")


    def legacy_manifest(j):
        j.pop("photo_dir", None)
        for p in j["photos"]:
            if p["id"] == "DSC_0005":
                p["id"], p["preview_path"] = "JPG_DSC_0005", "previews/JPG_DSC_0005.jpg"


    def legacy_layer1(j):
        for r in j["results"]:
            if r["id"] == "DSC_0005":
                r["id"] = "JPG_DSC_0005"


    e.edit("manifest.json", legacy_manifest)
    e.edit("layer1_results.json", legacy_layer1)
    os.rename(os.path.join(e.session, "previews", "DSC_0005.jpg"), os.path.join(e.session, "previews", "JPG_DSC_0005.jpg"))
    e.write("overrides.json", {"JPG_DSC_0005": "精选"})
    expect_run(e.analyze(), 0, 2, "老场次再跑一次（全部复用）")
    expect_ids(e, {"仪式/JPG/DSC_0005.JPG": "JPG_DSC_0005", "DSC_0006.JPG": "DSC_0006"}, "老 id 原样留着")
    check(e.verdicts().get("JPG_DSC_0005") == "精选", "老 id 上的改判还在")

    print("F. 同一个文件夹里 IMG_0001.JPG + IMG_0001.PNG（不是一对，PNG 单算 IMG_0001_png），之后撞名、删掉 JPG")
    f_ = Shoot("shoot_f")
    f_.put("仪式/IMG_0001.JPG"); f_.put("仪式/IMG_0001.PNG", "png")
    expect_run(f_.analyze(), 2, 0, "第一次")
    expect_ids(f_, {"仪式/IMG_0001.JPG": "IMG_0001", "仪式/IMG_0001.PNG": "IMG_0001_png"}, "第一次")
    f_.write("overrides.json", {"IMG_0001": "精选", "IMG_0001_png": "废片"})
    f_.put("晚宴/IMG_0001.JPG")
    expect_run(f_.analyze(), 1, 2, "加了 晚宴/IMG_0001")
    expect_ids(f_, {"仪式/IMG_0001.JPG": "IMG_0001", "仪式/IMG_0001.PNG": "IMG_0001_png", "晚宴/IMG_0001.JPG": "晚宴_IMG_0001"},
               "仪式两张都不改名")
    f_.rm("仪式/IMG_0001.JPG")
    expect_run(f_.analyze(), 0, 2, "删掉 仪式/IMG_0001.JPG")
    expect_ids(f_, {"仪式/IMG_0001.PNG": "IMG_0001_png", "晚宴/IMG_0001.JPG": "晚宴_IMG_0001"},
               "PNG 成了这个位置唯一的一张，还叫 IMG_0001_png（同一个文件 id 不变）")
    check(f_.verdicts().get("IMG_0001_png") == "废片", "PNG 的改判还在")

    print("G. 换了格式（晚宴/DSC_0009.JPG 换成 .PNG），同时另一张同名的被移走：按去掉扩展名的位置认")
    g = Shoot("shoot_g")
    g.put("仪式/DSC_0009.JPG"); g.put("晚宴/DSC_0009.JPG")
    expect_run(g.analyze(), 2, 0, "第一次")
    g.write("overrides.json", {"晚宴_DSC_0009": "精选"})
    g.rm("晚宴/DSC_0009.JPG"); g.put("晚宴/DSC_0009.PNG", "png"); g.rm("仪式/DSC_0009.JPG")
    expect_run(g.analyze(), 1, 0, "换了格式（内容变了，重分析）")
    expect_ids(g, {"晚宴/DSC_0009.PNG": "晚宴_DSC_0009"}, "还叫 晚宴_DSC_0009，不变成 DSC_0009")
    check(g.verdicts().get("晚宴_DSC_0009") == "精选", "改判还在")

    print("H. 拍摄文件夹在符号链接底下（/var → /private/var），后加同名子文件夹：id 照样不变")
    h = Shoot("shoot_h", base=LINKED_WORK)
    check(h.root != os.path.realpath(h.root), f"H 组的路径没解析过符号链接（{h.root}）")
    h.put("A/DSCF0001.JPG"); h.put("A/DSCF0002.JPG")
    expect_run(h.analyze(), 2, 0, "第一次")
    first, _ = h.ids()
    h.write("overrides.json", {first.get("A/DSCF0001.JPG", "?"): "精选"})
    h.put("B/DSCF0001.JPG")
    expect_run(h.analyze(), 1, 2, "加了 B")
    second, _ = h.ids()
    check(all(second.get(rel) == pid for rel, pid in first.items()), f"A 的两张 id 不变（{first} → {second}）")
    check(len(set(second.values())) == 3, "三张 id 各不相同")
    check(h.verdicts().get(first.get("A/DSCF0001.JPG")) == "精选", "改判还对得上")

# 中途抛异常（比如分析失败、manifest 没写出来）也要删工作目录：它在 .build 底下，CI 会把 .build 整个缓存起来。
try:
    run_all()
finally:
    if os.environ.get("KEEP") == "1":
        print(f"工作目录留着: {WORK} {LINKED_WORK}")
    else:
        shutil.rmtree(WORK, ignore_errors=True)
        shutil.rmtree(LINKED_WORK, ignore_errors=True)
    shutil.rmtree(SOCK, ignore_errors=True)

print()
print("照片 id 稳定回归全部通过" if not failures else f"照片 id 稳定回归 {len(failures)} 项失败")
sys.exit(1 if failures else 0)
