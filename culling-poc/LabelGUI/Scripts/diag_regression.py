#!/usr/bin/env python3
"""诊断这一组的端到端回归（审查 D03）：真命令行跑一遍，全部合成数据和临时目录。
进程内的那一半（提示历史、日志轮转、诊断包、失败原因、文件夹权限）在 `--diag-selftest`（Scripts/selftests.sh 里跑）；
这里验它们在命令行出口上接上了：

1. --diag-export：造一个数据目录（sessions.json 带客户名的场次文件夹和 bookmark、场次 JSON、客户备注、预览图、带路径的日志）
   和一个崩溃报告目录 → zip 里有说明 / 诊断信息 / 提示 / 场次概况 / 目录结构 / 日志 / 最近的崩溃报告；没有图片文件、
   没有客户原话、bookmark、场次文件夹名、家目录；日志里的路径换成了 <场次 N>。
2. --analyze 一个 chmod 000 的照片文件夹 → 退出码 1，说「没有权限读这个文件夹」并点名「系统设置 › 隐私与安全性 › 文件与文件夹」，
   不说「没有支持的图片文件」；空文件夹的对照组照旧说「没有支持的图片文件」。
3. --export-xmp：照片文件夹 chmod 555（写不进 .xmp）→ 「N 个失败 … ；原因：没有权限」，一个 .xmp 都没写出来。
4. --export-jpeg：导出目录 chmod 555 → 「JPG 导出: 0 成功, N 失败 (…)；原因：没有权限」；精华 Top N 建不了子文件夹 →
   「无法创建导出文件夹「Top…」: 没有权限」。

每条命令都带临时 LABELGUI_DATA_DIR、LABELGUI_NO_GUI=1。root 跑时 chmod 拦不住，2–4 记 skip。
用法: python3 -I Scripts/diag_regression.py <LabelGUI> [--keep]
"""
import importlib.util, json, os, re, shutil, stat, subprocess, sys, tempfile, zipfile

ARGS = sys.argv[1:]
if not ARGS or ARGS[0].startswith("-"):
    print(__doc__)
    sys.exit(2)
BIN = os.path.abspath(ARGS[0])
if ".app/" in BIN.lower():
    print("只跑裸二进制（.build/…/LabelGUI），不跑 .app 里的那份")
    sys.exit(2)
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
WORK = tempfile.mkdtemp(prefix="diag-reg-")
os.makedirs(os.path.join(WORK, "mcp-out"))
FAILS = []
LOCKED = []
IS_ROOT = os.geteuid() == 0


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)
        if ON_GITHUB:
            print(f"::error title=诊断回归::{msg}")
    return cond


def lock(path, mode):
    os.chmod(path, mode)
    LOCKED.append(path)


def unlock_all():
    for p in LOCKED:
        try:
            os.chmod(p, stat.S_IRWXU)
        except OSError:
            pass


def fresh_data(label):
    return tempfile.mkdtemp(prefix=f"data-{label}-", dir=WORK)


def run(args, data, timeout=120):
    sock = tempfile.mkdtemp(prefix="sock-", dir=WORK)
    env = {k: v for k, v in os.environ.items() if not k.startswith("LABELGUI_")}
    env.update(LABELGUI_DATA_DIR=data, LABELGUI_NO_GUI="1", LABELGUI_LIVE_SOCK_ROOT=sock,
               LABELGUI_MCP_OUT=os.path.join(WORK, "mcp-out"))
    return subprocess.run([BIN] + args, env=env, capture_output=True, text=True, timeout=timeout * SLACK,
                          stdin=subprocess.DEVNULL, cwd=WORK)


def make_jpeg(path, seed, w=600, h=400):
    bmp = os.path.join(WORK, f"tmp-{seed}.bmp")
    sj.bmp_quadrants(bmp, w, h, seed=seed)
    sj.to_jpeg(bmp, path)
    os.unlink(bmp)


def session_key(path):
    r = run(["--session-key", path], fresh_data("key"))
    key = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
    if not re.match(r"^[0-9a-f]{16}$", key):
        print(f"--session-key 算不出 {path} 的 key：{r.stdout!r} {r.stderr[-300:]!r}")
        sys.exit(2)
    return key


def synth_session(label, n):
    """照片文件夹（n 张合成图，文件名用 fixture 的 id）+ 数据目录（fixture 前 n 行的 manifest、layer1：判决确定，全是精选 / 可用）。"""
    man = json.load(open(os.path.join(FIX, "manifest.json")))
    l1 = json.load(open(os.path.join(FIX, "layer1_results.json")))
    photos = os.path.join(WORK, f"photos-{label}")
    os.makedirs(photos)
    rows = []
    for i, p in enumerate(man["photos"][:n]):
        path = os.path.join(photos, p["id"] + ".JPG")
        make_jpeg(path, seed=200 + i)
        rows.append(dict(p, raw_path=path, decode_path=path, preview_path=f"previews/{p['id']}.jpg", body_serial=""))
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


def section_export():
    print("1. --diag-export：zip 里该有的都有，照片、客户原话、路径都没有")
    data = fresh_data("diag")
    home = os.path.expanduser("~")
    client = "/Volumes/T7/客户李四婚礼"
    desk = os.path.join(home, "Desktop", "赵六订婚")
    bookmark = "Ym9va21hcmstZGlhZy1yZWdyZXNzaW9u"
    k1 = session_key(client)
    k2 = session_key(desk)
    sessions = [{"key": k1, "path": client, "name": "客户李四婚礼", "lastAnalyzed": "2026-11-01", "photoCount": 3,
                 "bookmark": bookmark},
                {"key": k2, "path": desk, "name": "赵六订婚", "lastAnalyzed": "2026-11-02", "photoCount": 7}]
    json.dump(sessions, open(os.path.join(data, "sessions.json"), "w"), ensure_ascii=False)
    sdir = os.path.join(data, "sessions", k1)
    os.makedirs(os.path.join(sdir, "previews"))
    json.dump({"photos": [{"id": "DSCF0001", "raw_path": client + "/DSCF0001.RAF"}]},
              open(os.path.join(sdir, "manifest.json"), "w"), ensure_ascii=False)
    json.dump({"DSCF0001": "客户回复：眼袋去掉，背景路人修掉"}, open(os.path.join(sdir, "client_notes.json"), "w"),
              ensure_ascii=False)
    make_jpeg(os.path.join(sdir, "previews", "DSCF0001.jpg"), seed=7)
    os.makedirs(os.path.join(data, "logs"))
    with open(os.path.join(data, "logs", "app.log"), "w") as f:
        f.write(f"2026-11-04 10:00:00.000 -0800 GUI[1] error batch: 照片文件夹「客户李四婚礼」不存在 ⏎ {client}/DSCF0001.RAF\n")
        f.write(f"2026-11-04 10:00:01.000 -0800 GUI[1] notice app: 启动：数据目录：{home}/Library/Application Support/选片工具\n")
    crash = os.path.join(WORK, "crash")
    os.makedirs(crash)
    with open(os.path.join(crash, "LabelGUI-2026-11-03-101010.ips"), "w") as f:
        f.write('{"procPath":"' + home + '/Applications/选片工具.app"}')
    with open(os.path.join(crash, "Finder-2026-11-03-101010.ips"), "w") as f:
        f.write("别的程序的")
    out = os.path.join(WORK, "诊断.zip")
    r = run(["--diag-export", out, "--crash-dir", crash], data)
    if not check(r.returncode == 0 and os.path.isfile(out), f"退出码 0、写出 zip（{r.returncode}：{(r.stdout + r.stderr)[-300:]!r}）"):
        return
    with zipfile.ZipFile(out) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        texts = {n: z.read(n).decode("utf-8", "replace") for n in names}
    top = {n.split("/")[0] for n in names}
    check(len(top) == 1 and next(iter(top)).startswith("xuanpian-diagnostics-"), f"最外层一个「xuanpian-diagnostics-时间」文件夹：{sorted(top)}")
    rel = sorted(n.split("/", 1)[1] for n in names)
    want = sorted(["README.txt", "info.txt", "recent-messages.txt", "sessions.txt", "data-dir.txt", "logs/app.log",
                   "crash-reports/LabelGUI-2026-11-03-101010.ips"])
    check(rel == want, f"文件正好是这几个（场次 JSON、sessions.json、别的程序的崩溃报告不放）：{rel}")
    listed = [l.strip() for l in r.stdout.splitlines() if l.startswith("  ")]
    check(sorted(listed) == sorted(names), "命令行打印的就是 zip 里的")
    images = [n for n in names if os.path.splitext(n)[1].lower() in (".jpg", ".jpeg", ".png", ".heic", ".raf", ".dng")]
    check(not images, f"没有图片文件：{images}")
    blob = "\n".join(texts.values())
    leaked = [s for s in ["客户李四婚礼", "赵六订婚", "眼袋", "路人", bookmark, home + "/", "DSCF0001.jpg"] if s in blob]
    check(not leaked, f"没有客户原话、bookmark、场次文件夹名、家目录、预览图名字：漏了 {leaked}")
    log = next((t for n, t in texts.items() if n.endswith("logs/app.log")), "")
    check("照片文件夹「<场次 1>」不存在 ⏎ <场次 1>/DSCF0001.RAF" in log and "~/Library/Application Support/选片工具" in log,
          "日志里的路径和「文件夹名」换成 <场次 N>，家目录换成 ~")
    summary = next((t for n, t in texts.items() if n.endswith("sessions.txt")), "")
    check(f"<场次 1>  key {k1} · 3 张" in summary and f"<场次 2>  key {k2} · 7 张" in summary, "场次概况：代号、key、张数")
    tree = next((t for n, t in texts.items() if n.endswith("data-dir.txt")), "")
    check(f"sessions/{k1}/client_notes.json" in tree and f"sessions/{k1}/previews/  （1 个文件" in tree,
          "目录结构：文件只列名字和大小，预览目录只说个数")


def section_analyze():
    print("2. --analyze 读不了的照片文件夹：说没有权限、点名系统设置")
    if IS_ROOT:
        print("  skip root 跑：chmod 000 拦不住")
        return
    locked = os.path.join(WORK, "photos-locked")
    os.makedirs(locked)
    make_jpeg(os.path.join(locked, "DSCF0001.JPG"), seed=11)
    lock(locked, 0)
    r = run(["--analyze", locked], fresh_data("locked"))
    err = r.stdout + r.stderr
    check(r.returncode == 1 and "没有权限读这个文件夹「photos-locked」" in err
          and "系统设置 › 隐私与安全性 › 文件与文件夹" in err and "没有支持的图片文件" not in err,
          f"chmod 000：退出码 1，权限 + 系统设置，不说没有图片：{err.strip()[-300:]!r}")
    empty = os.path.join(WORK, "photos-empty")
    os.makedirs(empty)
    r = run(["--analyze", empty], fresh_data("empty"))
    err = r.stdout + r.stderr
    check(r.returncode == 1 and "没有支持的图片文件" in err and "没有权限" not in err, "空文件夹的对照组照旧说没有图片")


def section_xmp():
    print("3. --export-xmp 写不进照片文件夹：逐个失败说原因")
    if IS_ROOT:
        print("  skip root 跑：chmod 555 拦不住")
        return
    photos, data, ids = synth_session("xmp", 4)
    lock(photos, stat.S_IRUSR | stat.S_IXUSR | stat.S_IRGRP | stat.S_IXGRP)
    r = run(["--export-xmp", photos], data)
    out = r.stdout + r.stderr
    check(f"XMP: 0 个成功, {len(ids)} 个失败" in out and "；原因：没有权限" in out,
          f"「0 个成功, {len(ids)} 个失败 (…)；原因：没有权限」：{out.strip()[-400:]!r}")
    written = [n for n in os.listdir(photos) if n.lower().endswith(".xmp")]
    check(not written, f"一个 .xmp 都没写出来：{written}")


def section_jpeg():
    print("4. --export-jpeg 写不进导出目录：逐张失败说原因")
    if IS_ROOT:
        print("  skip root 跑：chmod 555 拦不住")
        return
    photos, data, ids = synth_session("jpeg", 3)
    dest = os.path.join(WORK, "导出-只读")
    os.makedirs(dest)
    lock(dest, stat.S_IRUSR | stat.S_IXUSR | stat.S_IRGRP | stat.S_IXGRP)
    r = run(["--export-jpeg", photos, "--dest", dest, "--scope", "picks+usable"], data)
    out = r.stdout + r.stderr
    check(r.returncode == 1 and f"JPG 导出: 0 成功, {len(ids)} 失败 (" in out and "；原因：没有权限" in out,
          f"逐张：「0 成功, {len(ids)} 失败 (…)；原因：没有权限」：{out.strip()[-400:]!r}")
    r = run(["--export-jpeg", photos, "--dest", dest, "--scope", "top:2"], data)
    out = r.stdout + r.stderr
    check(re.search(r"无法创建导出文件夹「Top2_[^」]+」: 没有权限", out) is not None,
          f"精华建不了子文件夹：「无法创建导出文件夹「Top2_…」: 没有权限」：{out.strip()[-300:]!r}")
    check(os.listdir(dest) == [], "导出目录里什么都没写")


try:
    section_export()
    section_analyze()
    section_xmp()
    section_jpeg()
finally:
    unlock_all()

if not REAL_BEFORE and os.path.exists(REAL_DATA):
    check(False, f"跑之前没有 {REAL_DATA}，跑完有了：哪条命令没走临时数据目录")
print()
print("诊断回归全部通过" if not FAILS else f"诊断回归 {len(FAILS)} 项失败")
if KEEP:
    print(f"工作目录留着：{WORK}")
else:
    shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILS else 0)
