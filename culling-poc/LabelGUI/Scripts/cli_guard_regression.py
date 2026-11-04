#!/usr/bin/env python3
"""启动和无头命令的护栏回归（审查 S13、S36）：
  A–D 会写数据目录的命令，没设 LABELGUI_DATA_DIR、或者设了但指到真实数据目录时都退出码 2，什么都不写；临时目录照常跑。
  E   batch.*（去重、每章最少保留、排序）钉在内存里：--verdicts --dedupe 照样生效，跑完 LabelGUI 设置域逐字节不变。
  F   GUI 启动门控的探锁、认人（--launch-gate-probe，只打印、不弹框）：真的 --live-host 拿着锁 → 认出来；
      旧的一行、pid 不是 LabelGUI、空的一行 → 等满以后 unknown；只拿 LOCK_SH 的不挡。
  G   main.swift 顶层分派的参数和 AppRuntime.headlessFlags 两边对得上。

用法: python3 -I cli_guard_regression.py <LabelGUI 裸二进制> [工作目录]
「真实数据目录」一律用 CFFIXED_USER_HOME 换成假的家目录下那个（card_import_regression G 段、live_smoke 同一招）：
判断哪天失灵，写的也是假的家目录，碰不到用户。第一步先确认假的家目录真的生效，没生效就不往下跑。
不开界面：每条命令都带 LABELGUI_NO_GUI=1，不跑 .app 里的二进制。工作目录不给就用临时目录，跑完删掉。
"""
import fcntl, json, os, re, select, shutil, signal, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1])
if ".app/" in BIN.lower():
    print("只跑裸二进制（.build/…/LabelGUI），不跑 .app 里的那份")
    sys.exit(2)
WORK = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="cli-guard-")
CLEANUP = len(sys.argv) <= 2
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources", "LabelGUI")
FIX = os.path.join(ROOT, "Fixtures", "photot-session")
FAKE_HOME = os.path.join(WORK, "假的家目录")
FAKE_REAL = os.path.join(FAKE_HOME, "Library", "Application Support", "选片工具")
SOCK = tempfile.mkdtemp(prefix="cli-guard-sock-")   # socket 根目录要短（sun_path 103 字节）
OUT = os.path.join(WORK, "out")
PHOTOS = os.path.join(WORK, "photos")
CARD = os.path.join(WORK, "card")
for d in (FAKE_HOME, OUT, PHOTOS, os.path.join(CARD, "DCIM", "100CANON"), os.path.join(WORK, "mcp-out")):
    os.makedirs(d, exist_ok=True)
failures = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


def env_for(data=None, **extra):
    """干净的环境：去掉所有 LABELGUI_*，家目录换成假的；data=None 就是不设 LABELGUI_DATA_DIR。"""
    env = {k: v for k, v in os.environ.items() if not k.startswith("LABELGUI_") and k != "CFFIXED_USER_HOME"}
    env.update(CFFIXED_USER_HOME=FAKE_HOME, HOME=FAKE_HOME, LABELGUI_NO_GUI="1", LABELGUI_LIVE_SOCK_ROOT=SOCK,
               LABELGUI_MCP_OUT=os.path.join(WORK, "mcp-out"))
    if data is not None:
        env["LABELGUI_DATA_DIR"] = data
    env.update(extra)
    return env


def run(args, env, timeout=60):
    try:
        return subprocess.run([BIN, *args], env=env, capture_output=True, text=True, timeout=timeout,
                              cwd=WORK, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None


def finish():
    print()
    print("无头护栏回归全部通过" if not failures else f"无头护栏回归 {len(failures)} 项失败")
    shutil.rmtree(SOCK, ignore_errors=True)
    if CLEANUP and not failures:
        shutil.rmtree(WORK, ignore_errors=True)
    sys.exit(1 if failures else 0)


print("A. 假的家目录生效（不生效就不往下跑：后面的命令要是闸失灵，会写到真的家目录）")
r = run(["--session-key", PHOTOS], env_for())
check(r is not None and r.returncode == 0 and os.path.isdir(os.path.join(FAKE_REAL, "fonts")),
      f"--session-key 不设 LABELGUI_DATA_DIR：数据目录建在假的家目录下（{FAKE_REAL}）")
if failures:
    finish()

# 会写数据目录的命令 × 各自的参数形状（参数给全，保证走到各自的闸；闸失灵时写的也只是假的家目录）
o = lambda name: os.path.join(OUT, name)
WRITERS = [
    # 审查 S36 新加闸的四条
    ["--compare", PHOTOS, "--keys", "enter"],
    ["--compare", PHOTOS, "--auto", "--keys", "1"],
    ["--compare", PHOTOS, "--keys", "undo"],
    ["--verdicts", PHOTOS, "--accept-all"],
    ["--verdicts", PHOTOS, "--accept-all", "--undo"],
    ["--verdicts", PHOTOS, "--clear-recents"],
    ["--collage", PHOTOS, "--auto", "4", "--out", o("c.jpg")],
    ["--collage", PHOTOS, "--album", "--out", o("album")],
    ["--compare-crop", PHOTOS, "IMG_0001", o("crop.jpg")],
    # 本来就有闸的（统一成 requireIsolatedDataDir 以后照样拦）
    ["--export-xmp", PHOTOS],
    ["--body-offset", PHOTOS, "--body", "x", "--seconds", "+60"],
    ["--proof-sheet", PHOTOS, "--out", o("proof.pdf")],
    ["--client-import", PHOTOS, "--file", o("picks.txt"), "--apply"],
    ["--copy-list", PHOTOS, "--format", "lines"],
    ["--copy-originals", PHOTOS, "--dest", o("orig")],
    ["--ingest", CARD, "--dest", o("ingest")],
    ["--collage-ops", PHOTOS, "--ops", "clear"],
    ["--collage-ui", PHOTOS, o("cu.png")],
    ["--batch-ui", PHOTOS, o("bu.png")],
    ["--compare-ui", PHOTOS, o("cmpu.png")],
    ["--watermark-ui", PHOTOS, o("wu.png")],
    ["--watermark-batch", PHOTOS, o("wb")],
    ["--export-jpeg", PHOTOS, "--dest", o("jpeg")],
    ["--card-ui", CARD, o("card.png"), "--dest", o("cd")],
    ["--app-ui", PHOTOS, o("app.png")],
    ["--live-host", PHOTOS, "--no-view"],
    ["--mask-selftest", PHOTOS],
    ["--film-selftest", PHOTOS, "--out", o("film")],
    ["--fashion-selftest", PHOTOS],
    ["--newspaper-selftest", PHOTOS],
    ["--album-selftest", PHOTOS, "--out", o("album-st")],
    # 诊断（审查 D03）：打包会读数据目录里的日志、自检会建 logs/ 和假场次
    ["--diag-export", o("diag.zip")],
    ["--diag-selftest"],
]
SESSIONS = os.path.join(FAKE_REAL, "sessions")


def expect_refused(args, env, label):
    shutil.rmtree(SESSIONS, ignore_errors=True)
    r = run(args, env)
    rc = "超时" if r is None else r.returncode
    leaked = os.path.exists(SESSIONS)
    check(r is not None and r.returncode == 2 and not leaked,
          f"{label}：{' '.join(a.replace(WORK, '…') for a in args)} → 退出码 {rc}"
          + ("，假的家目录下出现了 sessions/" if leaked else "，没有 sessions/"))


print("B. 不设 LABELGUI_DATA_DIR：会写数据目录的命令都退出码 2，假的家目录下不出现 sessions/")
for args in WRITERS:
    expect_refused(args, env_for(), "没设")

print("C. LABELGUI_DATA_DIR 指到真实数据目录（原样 / 符号链接 / 大小写不同 / 结尾斜杠）也退出码 2")
link = os.path.join(WORK, "指过去的链接")
os.symlink(FAKE_REAL, link)
variants = [("原样", FAKE_REAL), ("符号链接", link), ("大写", FAKE_REAL.replace("Application Support", "APPLICATION SUPPORT")),
            ("结尾斜杠", FAKE_REAL + "/")]
for label, path in variants:
    for args in (["--compare", PHOTOS, "--keys", "enter"], ["--verdicts", PHOTOS, "--accept-all"],
                 ["--collage", PHOTOS, "--auto", "4", "--out", o("c.jpg")], ["--collage-ops", PHOTOS, "--ops", "clear"],
                 ["--body-offset", PHOTOS], ["--ingest", CARD, "--dest", o("ingest")], ["--export-xmp", PHOTOS]):
        expect_refused(args, env_for(path), label)

print("D. 临时数据目录照常跑（闸不多拦）")
fixture = "/tmp/labelgui-fixture-photot"   # 和 verdict_regression.sh 同一个路径（不需要存在，session key 从它算）


def fixture_data(label):
    """新的临时数据目录，灌好 photot 的分析结果（和 verdict_regression.sh 一样）。"""
    d = os.path.join(WORK, f"data-{label}")
    os.makedirs(d)
    key = run(["--session-key", fixture], env_for(d)).stdout.strip()
    os.makedirs(os.path.join(d, "sessions", key))
    for name in ("manifest.json", "layer1_results.json"):
        shutil.copyfile(os.path.join(FIX, name), os.path.join(d, "sessions", key, name))
    return d


data = fixture_data("ok")
r = run(["--verdicts", fixture], env_for(data))
expected = open(os.path.join(FIX, "expected_verdicts.txt"), encoding="utf-8").read()
check(r is not None and r.returncode == 0 and r.stdout == expected, "--verdicts（只读）：退出码 0，输出和 expected_verdicts.txt 一样")
r = run(["--compare", fixture], env_for(data))
check(r is not None and r.returncode == 0, f"--compare 不给 --keys：退出码 {None if r is None else r.returncode}")
r = run(["--compare", fixture, "--keys", "enter"], env_for(data))
check(r is not None and r.returncode == 0, f"--compare --keys enter（临时目录）：退出码 {None if r is None else r.returncode}")
r = run(["--verdicts", fixture, "--accept-all", "--undo"], env_for(data))
check(r is not None and r.returncode == 0 and "接受全部推荐" in r.stdout,
      f"--verdicts --accept-all（临时目录）：退出码 {None if r is None else r.returncode}")
check(not os.path.exists(SESSIONS), "这几条都没碰假的家目录")

print("E. batch.* 钉在内存里、不落盘：--verdicts --dedupe 照样生效，跑完设置域一个字节都不变，下一条不跟着漂")


def defaults_export():
    r_ = subprocess.run(["defaults", "export", "LabelGUI", "-"], capture_output=True, text=True)
    return r_.returncode, r_.stdout


# 这两条用真的家目录（数据目录照样是临时的）：假的家目录下 CFPreferences 可能写到别处，比 defaults export 就比不出来了。
# 裸二进制的设置域是 LabelGUI（不是 app 的 local.culling.labelgui）；闸没失灵时一个字节都不写。
data = fixture_data("settings")   # D 里按过 ⏎、接受过全部推荐，那份的判决已经变了
real_home_env = {k: v for k, v in env_for(data).items() if k not in ("CFFIXED_USER_HOME", "HOME")}
real_home_env["HOME"] = os.environ.get("HOME", "")
before = defaults_export()
r = run(["--verdicts", fixture, "--dedupe"], real_home_env)
check(r is not None and r.returncode == 0 and "连拍去重: 开" in r.stdout and r.stdout != expected,
      "--verdicts --dedupe：去重开着（钉进 argument domain 生效），判决和不去重时不一样")
check(defaults_export() == before, "--verdicts --dedupe 跑完，LabelGUI 设置域和跑之前逐字节一样（以前会留下 rejectBurstDuplicates=1）")
r = run(["--verdicts", fixture], real_home_env)
check(r is not None and r.returncode == 0 and r.stdout == expected, "紧接着不带 --dedupe：和 expected_verdicts.txt 一样（没留下去重开关）")
check(defaults_export() == before, "再跑一条，设置域还是一样")
r = run(["--verdicts", fixture, "--dedupe"], env_for(data))
check(r is not None and r.returncode == 0 and not os.path.exists(os.path.join(FAKE_HOME, "Library", "Preferences", "LabelGUI.plist")),
      "假的家目录下跑 --verdicts --dedupe：假的家目录里也没有 LabelGUI.plist")

print("F. GUI 启动门控的探锁、认人（--launch-gate-probe：和 GUI 同一段代码，只打印结论、绝不弹框）")


def gate(data, budget=300):
    r_ = run(["--launch-gate-probe", "--budget-ms", str(budget)], env_for(data))
    return "超时" if r_ is None else (r_.stdout.strip() if r_.returncode == 0 else f"退出码 {r_.returncode}")


def gate_dir(label):
    d = os.path.join(WORK, f"gate-{label}")
    os.makedirs(d)
    return d


def hold(data, line, mode=fcntl.LOCK_EX):
    """本脚本自己拿着 <data>/.live.lock（假装是别的进程），写好那一行。"""
    fd = os.open(os.path.join(data, ".live.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, mode | fcntl.LOCK_NB)
    os.ftruncate(fd, 0)
    os.pwrite(fd, line.encode(), 0)
    return fd


check(gate(gate_dir("empty")) == "launch-gate proceed", "没有锁文件 → proceed")
r = run(["--launch-gate-probe"], env_for())
check(r is not None and r.returncode == 2, "--launch-gate-probe 不设 LABELGUI_DATA_DIR → 退出码 2")
# 一个真的 --live-host 当「另一个实例」：它拿着锁、写了那一行（role=app、pid、exe）
hd = gate_dir("host")
snaps = os.path.join(WORK, "snaps")
os.makedirs(snaps)
host = subprocess.Popen([BIN, "--live-host", PHOTOS, "--no-view"], env=env_for(hd, LABELGUI_LIVE_TEST_OUT=snaps),
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=open(os.path.join(WORK, "host.err"), "w"),
                        cwd=WORK)
ready, buf, deadline = False, b"", time.monotonic() + 40
while not ready and time.monotonic() < deadline and host.poll() is None:
    if select.select([host.stdout], [], [], 0.2)[0]:
        chunk = os.read(host.stdout.fileno(), 4096)
        if not chunk:
            break
        buf += chunk
        ready = any(l.startswith("ready ") for l in buf.decode(errors="replace").splitlines())
check(ready, f"宿主就绪（pid {host.pid}）")
try:
    if ready:
        want = f"launch-gate running pid={host.pid} path={os.path.realpath(BIN)}"
        got = gate(hd)
        check(got == want, f"宿主拿着这个数据目录的锁 → 认出来是它（{got}）")
        # 对方关了「允许 AI 实时操作」时 socket 不监听、hello 不回，但那一行照样在：门控不靠 hello。这里拿脚本自己拿着锁、
        # 那一行写宿主的 pid / exe、bridge=off 来演（真的关桥要走 socket 上的 test.set_bridge）
        bd = gate_dir("bridge-off")
        fd = hold(bd, json.dumps({"role": "app", "pid": host.pid, "exe": os.path.realpath(BIN), "bridge": "off",
                                  "reason": "disabled_in_settings"}) + "\n")
        got = gate(bd)
        os.close(fd)
        check(got == want, f"那一行写着 bridge=off（没有 socket）：照样认出来（{got}）")
finally:
    if host.poll() is None:
        host.send_signal(signal.SIGTERM)
        try:
            host.wait(timeout=10)
        except subprocess.TimeoutExpired:
            host.kill()
            host.wait(timeout=5)
check(gate(hd) == "launch-gate proceed", "宿主退出以后锁就放了 → proceed")
# 锁被拿着、那一行认不出人：等满 --budget-ms 以后 unknown（GUI 弹框只给「退出」）
dead = subprocess.Popen(["/usr/bin/true"])
dead.wait()
for label, line, want in [
    ("pid 是本脚本、exe 写的是 app（pid 跑的不是 LabelGUI）",
     json.dumps({"role": "app", "pid": os.getpid(), "exe": "/Applications/选片工具.app/Contents/MacOS/LabelGUI"}),
     f"launch-gate unknown pid={os.getpid()}"),
    ("那一行是旧的（pid 已经退出）", json.dumps({"role": "app", "pid": dead.pid, "exe": os.path.realpath(BIN)}),
     f"launch-gate unknown pid={dead.pid}"),
    ("那一行是空的", "", "launch-gate unknown pid=-"),
]:
    d = gate_dir(f"held-{len(os.listdir(WORK))}")
    fd = hold(d, line)
    got = gate(d)
    os.close(fd)
    check(got == want, f"{label} → {got}")
d = gate_dir("shared")
fd = hold(d, "", fcntl.LOCK_SH)
got = gate(d)
os.close(fd)
check(got == "launch-gate proceed", f"别人只拿着 LOCK_SH（--mcp 探锁那种）不挡 → {got}")

print("G. 分派的每个参数都登记在 AppRuntime.headlessFlags 里（漏登记：脚本里跑会被 NoGUIGate 拦下，终端里跑 headless=false）")
main_src = open(os.path.join(SRC, "main.swift"), encoding="utf-8").read()
runtime_src = open(os.path.join(SRC, "AppRuntime.swift"), encoding="utf-8").read()
picks_src = open(os.path.join(SRC, "ClientPicksView.swift"), encoding="utf-8").read()
mcp_src = open(os.path.join(SRC, "MCP", "MCPServerMain.swift"), encoding="utf-8").read()
m = re.search(r"headlessFlags: Set<String> = \[(.*?)\]", runtime_src, re.S)
registered = set(re.findall(r'"(--[\w-]+)"', m.group(1))) if m else set()
dispatched = set()
for line in main_src.splitlines():
    if not line.startswith(("if ", "for flag in ")):   # 只看顶层分派（缩进的是各自的子选项）
        continue
    dispatched |= set(re.findall(r'(?:firstIndex\(of: |contains\()"(--[\w-]+)"', line))
    if line.startswith("for flag in ["):
        dispatched |= set(re.findall(r'"(--[\w-]+)"', line))
pm = re.search(r"static let flags = \[(.*?)\]", picks_src)
dispatched |= set(re.findall(r'"(--[\w-]+)"', pm.group(1))) if pm else set()
dispatched |= {f for f in re.findall(r'"(--mcp[\w-]*)"', mcp_src)}
check(bool(registered) and len(dispatched) > 30, f"读到了 headlessFlags（{len(registered)} 个）和顶层分派（{len(dispatched)} 个）")
check(dispatched <= registered, f"分派了却没登记：{sorted(dispatched - registered)}")
check(registered <= dispatched, f"登记了却没有分派：{sorted(registered - dispatched)}")

finish()
