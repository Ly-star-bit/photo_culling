#!/usr/bin/env python3
"""交付环节端到端回归（CI 的「交付回归」步骤）：真命令行跑一遍交付出口，断言数据安全承诺 —— 全部用合成图和临时目录。
纯函数那一半（XMP 归属 / 合并的期望表、同名另存、截断 JPEG、isSameFile、两条去 GPS）在 `--delivery-selftest`（进程内，
Scripts/selftests.sh 里跑）；这里验它们在命令行出口上确实接上了：

1. --watermark 输出路径就是原片（同一路径、. 和 ..、大小写不同、硬链接）→ 退出码 1、原片逐字节不变；
   指向原片的符号链接 → 不管成不成功，原片逐字节不变。
2. --watermark-batch 输出目录在拍摄文件夹里面（照片目录本身、里面还没建的「交付」、--session 那一场里面）、文件名模板
   {原名}（先写好 watermark/state.json）→ 退出码 1、报「不能导出到拍摄文件夹」、照片目录一个文件都不多、子目录不建（审查 S11）；
   导进照片目录里的「水印导出/」（分析跳过）照常、原片不变，再导一次全是 -2；
   没有任何水印内容（不带 --exif / --signature）→ 退出码 1，而且是因为「没有任何水印内容」（不是别的原因）。
3. --export-xmp：原图旁边已有 LR 写的 sidecar → 只改星级 / 色标，调色、关键字按解析后的字段逐个不变；
   自己写的（x:xmptk="选片工具"）和以前 culling-poc 写的 → 整份重写成现在的模板；读不全的（rdf:resource）、
   读不了的（chmod 000）→ 字节不变、点名「没写星级」；没有 sidecar 的 → 新写一份。星级按 --verdicts 的判决算。
4. --export-jpeg --scope top:N（精华，出厂默认去 GPS）：原片 EXIF 带 GPS → 输出没有 GPS（命令行自己说的「无GPS」和
   这里自己读 EXIF / XMP 两边都看）；--keep-gps 的对照组 GPS 还在。
5. --watermark --config '{"stripGPS":true}' → 输出没有 GPS；false 的对照组 GPS 还在。

每条命令都带临时 LABELGUI_DATA_DIR、LABELGUI_NO_GUI=1；CI 里放在 MCP 冒烟后面。
用法: python3 -I Scripts/delivery_regression.py <LabelGUI> [--keep]
"""
import hashlib, importlib.util, json, os, re, shutil, stat, subprocess, sys, tempfile
import xml.etree.ElementTree as ET

ARGS = sys.argv[1:]
if not ARGS or ARGS[0].startswith("-"):
    print(__doc__)
    sys.exit(2)
BIN = os.path.abspath(ARGS[0])
KEEP = "--keep" in ARGS
ON_GITHUB = os.environ.get("GITHUB_ACTIONS") == "true"
SLACK = 4.0 if ON_GITHUB else 1.0
HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(os.path.dirname(HERE), "Fixtures", "photot-session")
_spec = importlib.util.spec_from_file_location("synth_jpeg", os.path.join(HERE, "synth_jpeg.py"))
sj = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sj)

REAL_DATA = os.path.expanduser("~/Library/Application Support/选片工具")
REAL_BEFORE = os.path.exists(REAL_DATA)
WORK = tempfile.mkdtemp(prefix="delivery-reg-")
os.makedirs(os.path.join(WORK, "mcp-out"))
FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)
        if ON_GITHUB:
            print(f"::error title=交付回归::{msg}")
    return cond


def fresh_data(label):
    d = tempfile.mkdtemp(prefix=f"data-{label}-", dir=WORK)
    return d


def run(args, data, timeout=120):
    sock = tempfile.mkdtemp(prefix="sock-", dir=WORK)
    env = {k: v for k, v in os.environ.items() if not k.startswith("LABELGUI_")}
    env.update(LABELGUI_DATA_DIR=data, LABELGUI_NO_GUI="1", LABELGUI_LIVE_SOCK_ROOT=sock,
               LABELGUI_MCP_OUT=os.path.join(WORK, "mcp-out"))
    return subprocess.run([BIN] + args, env=env, capture_output=True, text=True, timeout=timeout * SLACK,
                          stdin=subprocess.DEVNULL, cwd=WORK)


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def tree(folder):
    """文件名 → sha256（只看这一层）。"""
    return {n: sha(os.path.join(folder, n)) for n in sorted(os.listdir(folder))
            if os.path.isfile(os.path.join(folder, n)) and not os.path.islink(os.path.join(folder, n))}


def make_jpeg(path, seed, w=900, h=600, **exif):
    bmp = os.path.join(WORK, f"tmp-{seed}.bmp")
    tmp = os.path.join(WORK, f"tmp-{seed}.jpg")
    sj.bmp_quadrants(bmp, w, h, seed=seed)
    sj.to_jpeg(bmp, tmp)
    data = open(tmp, "rb").read()
    os.unlink(bmp)
    os.unlink(tmp)
    if exif:
        data = sj.with_exif(data, **exif)
    with open(path, "wb") as f:
        f.write(data)


def session_key(path):
    r = run(["--session-key", path], fresh_data("key"))
    key = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
    if not re.match(r"^[0-9a-f]{16}$", key):
        print(f"--session-key 算不出 {path} 的 key：{r.stdout!r} {r.stderr[-300:]!r}")
        sys.exit(2)
    return key


def synth_session(label, n, **exif):
    """照片文件夹（n 张合成图，文件名用 fixture 的 id）+ 数据目录（sessions/<key>/ 下 fixture 前 n 行的 manifest、layer1）。
    判决按 fixture 的数值来（和 verdict_regression 一样确定），不跑 --analyze（纯色 / 噪声图分析出来多半整场废片）。"""
    man = json.load(open(os.path.join(FIX, "manifest.json")))
    l1 = json.load(open(os.path.join(FIX, "layer1_results.json")))
    photos = os.path.join(WORK, f"photos-{label}")
    os.makedirs(photos)
    rows = []
    for i, p in enumerate(man["photos"][:n]):
        path = os.path.join(photos, p["id"] + ".JPG")
        make_jpeg(path, seed=100 + i, **exif)
        q = dict(p, raw_path=path, decode_path=path, preview_path=f"previews/{p['id']}.jpg", body_serial="")
        rows.append(q)
    key = session_key(photos)
    data = fresh_data(label)
    sdir = os.path.join(data, "sessions", key)
    os.makedirs(os.path.join(sdir, "previews"))
    for q in rows:
        shutil.copy(q["raw_path"], os.path.join(sdir, "previews", q["id"] + ".jpg"))
    ids = {q["id"] for q in rows}
    json.dump({"photo_dir": photos, "photos": rows}, open(os.path.join(sdir, "manifest.json"), "w"), ensure_ascii=False)
    json.dump(dict(l1, results=[r for r in l1["results"] if r["id"] in ids]),
              open(os.path.join(sdir, "layer1_results.json"), "w"), ensure_ascii=False)
    return photos, data, [q["id"] for q in rows]


def verdicts(photos, data):
    r = run(["--verdicts", photos, "--per-photo"], data)
    out, on = {}, False
    for line in r.stdout.splitlines():
        if line.startswith("阈值: "):
            on = True
            continue
        m = re.match(r"^  (\S+) (精选|可用|废片) (\S+)$", line) if on else None
        if m:
            out[m.group(1)] = m.group(2)
    return out


# ---------------------------------------------------------------- XMP 解析（按字段比，不比字节：合并会重新序列化）

NS = {"x": "adobe:ns:meta/", "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#"}
PREFIX = {"http://ns.adobe.com/xap/1.0/": "xmp", "http://ns.adobe.com/camera-raw-settings/1.0/": "crs",
          "http://ns.adobe.com/lightroom/1.0/": "lr", "http://purl.org/dc/elements/1.1/": "dc",
          "http://ns.adobe.com/xap/1.0/rights/": "xmpRights", "adobe:ns:meta/": "x",
          "http://www.w3.org/1999/02/22-rdf-syntax-ns#": "rdf"}


def qname(tag):
    if tag.startswith("{"):
        uri, local = tag[1:].split("}", 1)
        return f"{PREFIX.get(uri, uri)}:{local}"
    return tag


def xmp_fields(data):
    """rdf:Description 上的属性和子元素 → {前缀:名字: 值}；rdf:Bag / Seq / Alt 记成值的列表。属性写法和元素写法一样对待。"""
    root = ET.fromstring(data)
    out = {}
    meta = root if qname(root.tag) == "x:xmpmeta" else root.find("x:xmpmeta", NS)
    if meta is not None:
        for k, v in meta.attrib.items():
            out[qname(k)] = v
    for desc in root.iter("{%s}Description" % NS["rdf"]):
        for k, v in desc.attrib.items():
            name = qname(k)
            if name != "rdf:about":
                out[name] = v
        for child in desc:
            name = qname(child.tag)
            lis = [li.text or "" for li in child.iter("{%s}li" % NS["rdf"])]
            if lis or any(qname(c.tag) in ("rdf:Bag", "rdf:Seq", "rdf:Alt") for c in child):
                out[name] = lis
            else:
                out[name] = (child.text or "").strip()
    return out


def lr_sidecar(rating=2, label="Blue"):
    lab = f'\n   xmp:Label="{label}"' if label else ""
    return f"""<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 79.dabacbb, 2021/04/14-00:39:44        ">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
   xmp:Rating="{rating}"{lab}
   crs:Version="15.4"
   crs:Exposure2012="+0.35"
   crs:Contrast2012="-12"
   crs:WhiteBalance="Custom">
   <dc:subject>
    <rdf:Bag>
     <rdf:li>婚礼</rdf:li>
     <rdf:li>仪式</rdf:li>
    </rdf:Bag>
   </dc:subject>
   <lr:hierarchicalSubject>
    <rdf:Bag>
     <rdf:li>婚礼|仪式</rdf:li>
    </rdf:Bag>
   </lr:hierarchicalSubject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
""".encode()


def simple_sidecar(xmptk, rating):
    return f"""<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="{xmptk}">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="{rating}"/>
 </rdf:RDF>
</x:xmpmeta>
""".encode()


RESOURCE_SIDECAR = b"""<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/" xmp:Rating="2">
   <xmpRights:WebStatement rdf:resource="https://example.com/license"/>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""

STARS = {"精选": "4", "可用": "3", "废片": "-1"}     # 没有 VLM 表情分时（BatchStore.xmpRating）
LABELS = {"精选": "Green", "可用": None, "废片": "Red"}


# ---------------------------------------------------------------- 1. 水印不写回原片

def same_file_section():
    print("1. --watermark：输出路径就是原片")
    d = os.path.join(WORK, "same")
    os.makedirs(d)
    a = os.path.join(d, "a.jpg")
    make_jpeg(a, seed=1)
    before = sha(a)
    os.link(a, os.path.join(d, "hard.jpg"))
    os.symlink(a, os.path.join(d, "link.jpg"))
    ci = os.path.exists(os.path.join(d, "A.JPG"))
    targets = [("同一个路径", a), ("带 . 和 ..", os.path.join(d, "sub", "..", ".", "a.jpg")),
               ("硬链接", os.path.join(d, "hard.jpg"))]
    if ci:
        targets.append(("大小写不同", os.path.join(d, "A.JPG")))
    else:
        print("  skip 大小写不同：这个卷分大小写")
    for label, dest in targets:
        r = run(["--watermark", a, dest], fresh_data("wm-same"))
        check(r.returncode == 1 and "输出路径与原片相同" in r.stderr and sha(a) == before,
              f"{label}：退出码 {r.returncode}（要 1）、报「输出路径与原片相同」、原片逐字节不变")
    r = run(["--watermark", a, os.path.join(d, "link.jpg")], fresh_data("wm-link"))
    check(sha(a) == before, f"指向原片的符号链接：原片逐字节不变（退出码 {r.returncode}；"
                            f"链接{'被换成了普通文件' if not os.path.islink(os.path.join(d, 'link.jpg')) else '还在'}）")


# ---------------------------------------------------------------- 2. 水印批量输出到照片目录

def batch_section():
    print("2. --watermark-batch：输出目录在拍摄文件夹里面不导、「水印导出/」照常，文件名 {原名}")
    d = os.path.join(WORK, "batch")
    os.makedirs(d)
    for i, name in enumerate(("p1.jpg", "p2.jpg", "P3.JPG")):
        make_jpeg(os.path.join(d, name), seed=10 + i)
    with open(os.path.join(d, "notes.txt"), "w") as f:
        f.write("不是照片")
    before = tree(d)
    data = fresh_data("wm-batch")
    os.makedirs(os.path.join(data, "watermark"))
    json.dump({"options": {"nameTemplate": "{原名}", "size": "long:600"}},
              open(os.path.join(data, "watermark", "state.json"), "w"), ensure_ascii=False)
    r = run(["--watermark-batch", d, d], data)
    check(r.returncode == 1 and "没有任何水印内容" in r.stdout,
          f"不带 --exif / --signature：退出码 {r.returncode}（要 1），原因是「没有任何水印内容」（{r.stdout.strip()[-80:]!r}）")
    check(tree(d) == before, "　…… 照片目录一个文件都没多、没变")
    # 审查 S11：输出目录在拍摄文件夹里面（下次分析会把带水印的副本当成新照片）就不导 —— 以前这里导出成 -2
    refuse = "不能导出到拍摄文件夹"
    r = run(["--watermark-batch", d, d, "--exif"], data)
    check(r.returncode == 1 and refuse in r.stdout and tree(d) == before,
          f"带 --exif、输出目录就是照片目录：退出码 {r.returncode}（要 1）、报「{refuse}」、照片目录一个文件都没多"
          f"（{(r.stdout + r.stderr).strip()[-160:]!r}）")
    deliver = os.path.join(d, "交付", "客户A")
    r = run(["--watermark-batch", d, deliver, "--exif"], data)
    check(r.returncode == 1 and refuse in r.stdout and not os.path.exists(os.path.join(d, "交付")),
          f"输出到照片目录里还没建的「交付/客户A」：退出码 {r.returncode}（要 1）、报「{refuse}」、「交付」没建出来")
    other = os.path.join(WORK, "batch-session")
    os.makedirs(other)
    r = run(["--watermark-batch", d, os.path.join(other, "交付"), "--exif", "--session", other], data)
    check(r.returncode == 1 and f"{refuse}「batch-session」" in r.stdout and not os.path.exists(os.path.join(other, "交付")),
          f"照片在别处、输出到批量页开着的那一场（--session）里面：退出码 {r.returncode}（要 1）、点名那一场、没建目录"
          f"（{r.stdout.strip()[-120:]!r}）")
    wm = os.path.join(d, "水印导出")
    r = run(["--watermark-batch", d, wm, "--exif"], data)
    first = sorted(os.listdir(wm)) if os.path.isdir(wm) else []
    check(r.returncode == 0 and first == ["P3.jpg", "p1.jpg", "p2.jpg"],
          f"导进照片目录里的「水印导出/」（分析跳过）：退出码 {r.returncode}（要 0）、写出 {first}"
          f"（{(r.stdout + r.stderr).strip()[-160:]!r}）")
    r = run(["--watermark-batch", d, wm, "--exif"], data)
    new = sorted(set(os.listdir(wm)) - set(first)) if os.path.isdir(wm) else []
    check(r.returncode == 0 and new == ["P3-2.jpg", "p1-2.jpg", "p2-2.jpg"], f"再导一次：全是 -2（{new}）")
    check("另存为 -2" in r.stdout, f"说了「目标里已有同名，另存为 -2」：{r.stdout.strip().splitlines()[:1]}")
    check(tree(d) == before, "原片（和旁边的 notes.txt）逐字节不变、照片目录这一层没多文件")


# ---------------------------------------------------------------- 3. 写 XMP

def xmp_section():
    print("3. --export-xmp：别人的 sidecar 只合并、自己的整份重写、读不全 / 读不了的不碰")
    photos, data, ids = synth_session("xmp", 6)
    v = verdicts(photos, data)
    check(sorted(v) == sorted(ids), f"前提：--verdicts 给出 6 张的判决 {v}")
    lr_id, own_id, legacy_id, resource_id, locked_id, none_id = ids
    side = {i: os.path.join(photos, i + ".xmp") for i in ids}
    lr = lr_sidecar(rating=2, label="Blue")
    with open(side[lr_id], "wb") as f:
        f.write(lr)
    with open(side[own_id], "wb") as f:
        f.write(simple_sidecar("选片工具", 1))
    with open(side[legacy_id], "wb") as f:
        f.write(simple_sidecar("culling-poc", 1))
    with open(side[resource_id], "wb") as f:
        f.write(RESOURCE_SIDECAR)
    with open(side[locked_id], "wb") as f:
        f.write(lr_sidecar(rating=1, label="Yellow"))
    locked_before = sha(side[locked_id])
    resource_before = sha(side[resource_id])
    os.chmod(side[locked_id], 0)
    try:
        open(side[locked_id], "rb").close()
        # root 跑的话 chmod 000 照样读得了：这一张就和 LR 那张一样会被合并，下面按「读得了」的期望走。
        locked_readable = True
    except OSError:
        locked_readable = False
    try:
        r = run(["--export-xmp", photos], data)
    finally:
        os.chmod(side[locked_id], stat.S_IRUSR | stat.S_IWUSR)
    if locked_readable:
        print("  skip chmod 000 读不了的那条：当前用户（root？）照样读得了")
    out = r.stdout
    check(r.returncode == 1, f"有张没写进去（合并不了 / 读不了）→ 退出码 1（实际 {r.returncode}）")
    kept_line = [l for l in out.splitlines() if "没写星级" in l][:1]
    if locked_readable:
        check("1 张没写星级" in out and resource_id in out, f"点名没写星级的那张：{kept_line}")
        check("其中 2 个是其它软件的 XMP" in out, "完成摘要说了 2 个是其它软件的 XMP、只改了星级/色标")
    else:
        check("2 张没写星级" in out and resource_id in out and locked_id in out, f"点名没写星级的 2 张：{kept_line}")
        check("其中 1 个是其它软件的 XMP" in out, "完成摘要说了 1 个是其它软件的 XMP、只改了星级/色标")

    before = xmp_fields(lr)
    after = xmp_fields(open(side[lr_id], "rb").read())
    want_stars, want_label = STARS.get(v.get(lr_id)), LABELS.get(v.get(lr_id))
    check(after.get("xmp:Rating") == want_stars, f"LR 的：星级按判决（{v.get(lr_id)}）改成 {want_stars}：{after.get('xmp:Rating')}")
    # 可用不带色标、上次也没写过（没有 xmp_state）→ 文件里的 Blue 是用户自己的，留着；精选 / 废片换成 Green / Red。
    check(after.get("xmp:Label") == (want_label or "Blue"), f"LR 的：色标 {after.get('xmp:Label')}（要 {want_label or 'Blue'}）")
    rest_b = {k: x for k, x in before.items() if k not in ("xmp:Rating", "xmp:Label", "x:xmptk")}
    rest_a = {k: x for k, x in after.items() if k not in ("xmp:Rating", "xmp:Label", "x:xmptk")}
    check(rest_a == rest_b, f"LR 的：调色、关键字按解析后的字段逐个不变（{len(rest_b)} 个）"
                            + ("" if rest_a == rest_b else f"：之前 {rest_b} 之后 {rest_a}"))
    for i, what in ((own_id, "自己写的"), (legacy_id, "culling-poc 写的"), (none_id, "原来没有 sidecar 的")):
        f_ = xmp_fields(open(side[i], "rb").read()) if os.path.exists(side[i]) else {}
        want_s, want_l = STARS.get(v.get(i)), LABELS.get(v.get(i))
        check(f_.get("x:xmptk") == "选片工具" and f_.get("xmp:Rating") == want_s and f_.get("xmp:Label") == want_l,
              f"{what}：整份写成现在的模板（x:xmptk=选片工具、星级 {f_.get('xmp:Rating')}、色标 {f_.get('xmp:Label')}，"
              f"判决 {v.get(i)}）")
    check(sha(side[resource_id]) == resource_before, "带 rdf:resource 的（合并不了）：字节不变")
    if not locked_readable:
        check(sha(side[locked_id]) == locked_before, "读不了的（chmod 000）：字节不变，没被当成没有 sidecar 整份覆盖")


# ---------------------------------------------------------------- 4 / 5. 去 GPS

def gps_section():
    print("4. --export-jpeg --scope top:2（精华）：去 GPS")
    gps = (31.2304, 121.4737)
    photos, data, ids = synth_session("gps", 4, gps=gps, datetime_original="2026:03:21 16:24:02", make="SYNTH",
                                      model="SYN-1")
    src = os.path.join(photos, ids[0] + ".JPG")
    check(sj.has_gps(open(src, "rb").read()), "前提：合成原片的 EXIF 里有 GPS")
    for label, extra, want in (("出厂默认", [], False), ("--keep-gps 对照组", ["--keep-gps"], True)):
        dest = os.path.join(WORK, f"top-{len(extra)}")
        os.makedirs(dest)
        r = run(["--export-jpeg", photos, "--dest", dest, "--scope", "top:2"] + extra, data)
        # 「  对照 <文件> → <id>」是交付对照（DeliveryLedger）那几行，不是逐张的文件属性行
        lines = [l.strip() for l in r.stdout.splitlines()
                 if l.startswith("  ") and ".jpg " in l and not l.strip().startswith("对照 ")]
        files = [os.path.join(dp, n) for dp, _, ns in os.walk(dest) for n in ns if n.lower().endswith(".jpg")]
        tags = ["有GPS" in l for l in lines]
        mine = [sj.has_gps(open(p, "rb").read()) for p in files]
        check(r.returncode == 0 and len(lines) == 2 and len(files) == 2,
              f"{label}：导出 2 张（退出码 {r.returncode}，{(r.stdout + r.stderr).strip()[-120:]!r}）")
        check(tags == [want] * 2 and mine == [want] * 2,
              f"{label}：输出{'带着' if want else '没有'} GPS（命令行说 {['有GPS' if x else '无GPS' for x in tags]}，"
              f"自己读 EXIF / XMP {mine}）")
    print("5. --watermark --config stripGPS")
    for strip in (True, False):
        out = os.path.join(WORK, f"wm-gps-{strip}.jpg")
        cfg = json.dumps({"stripGPS": strip, "exifText": {"enabled": True}})
        r = run(["--watermark", src, out, "--config", cfg], fresh_data("wm-gps"))
        ok = r.returncode == 0 and os.path.isfile(out)
        has = ok and sj.has_gps(open(out, "rb").read())
        check(ok and has == (not strip), f"stripGPS={str(strip).lower()}：输出{'没有' if strip else '还带着'} GPS"
                                         f"（退出码 {r.returncode}，GPS {has}）")


try:
    same_file_section()
    batch_section()
    xmp_section()
    gps_section()
    if not REAL_BEFORE:
        check(not os.path.exists(REAL_DATA), f"跑之前没有 {REAL_DATA}，跑完也没有（每条命令都走临时数据目录）")
finally:
    if KEEP:
        print(f"工作目录留着：{WORK}")
    else:
        for dp, dns, fns in os.walk(WORK):
            for n in fns:
                p = os.path.join(dp, n)
                if not os.path.islink(p):
                    try:
                        os.chmod(p, stat.S_IRUSR | stat.S_IWUSR)
                    except OSError:
                        pass
        shutil.rmtree(WORK, ignore_errors=True)

if FAILS:
    print(f"\n!! 交付回归 {len(FAILS)} 条 FAIL")
    sys.exit(1)
print("\n交付回归全部通过")
