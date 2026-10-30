#!/usr/bin/env python3
"""实时桥冒烟（DESIGN §9.8.2、§10.7；STEP 2：桥本身，STEP 3a：读和图片，STEP 3b：写）：起 --live-host（.prohibited，
窗口从不显示），经脚本自己起的 --mcp 驱动；test.* 直接连宿主的 socket。

用法: python3 -I Scripts/live_smoke.py <LabelGUI> --ci [--work <目录>] [--keep] [--only A,B,…] [--plan]
                                        [--view auto|require|no-view] [--force-no-view]
      python3 -I Scripts/live_smoke.py <LabelGUI> --photos <照片目录> --data <已分析的数据目录> [--collage-data <目录>]
                                        [--work …] [--keep] [--only …]
  --ci      Fixtures 场次（照片文件夹不存在，和 verdict_regression.sh 同一个约定）+ sips 合成图
  --photos / --data  本地 photot 模式：数据目录每个宿主拷一份新的
  --collage-data     （本地）有拼图工程的同一场的数据目录（STEP 0 的 data-seeded）：collage_get_state 的预览用它
  --work    工作目录（不存在、空的、或者本脚本上次建的才用；socket 也放在这下面，经 /tmp 下一个短的符号链接接过去）
  --plan    只打印这次会跑哪几组（app 里的二进制会跳过哪些）就退出，不起任何进程（自检用）
  --view    （只配 --ci）带不带视图：auto（默认，见下）；require = 必须带，探针探不过记一条 FAIL（照样改 --no-view 跑完其余的）；
            no-view = 不探，全程 --no-view
  --force-no-view  （只配 --ci，自检用）让开跑前的视图探针真的失败一次（探针宿主的快照目录给一个不存在的），
                   走一遍 CI 上的 --no-view 退路（配 --view require 时走 FAIL 那一条）。只有选了要起宿主的组（B–H）才探，
                   --only A 时它不起作用

带视图还是 --no-view（§9.8.1、§10.6 STEP 4：CI 上能不能建离屏窗口、cacheDisplay，第一次推才知道）：--ci 开跑前起一个
带标题栏的探针宿主（--titled，离屏窗口的超集），拍一张快照、同一个状态拍两条标题栏（要逐字节相同），再经 --mcp-call 让副标题变成
「AI 已连接」拍第三条（要不一样）—— H 组靠的就是这几样。都过 → 全程照常带视图；起不来、拍不出、卡住、标题栏不跟着变 →
全程 --no-view，日志里打一行「CI 用 --no-view：<原因>」（GitHub Actions 上同时是一条 warning），要窗口的那几条（快照、标题栏、
AppKit 窗口的副标题、批量页消费选中、E 组的 --app-ui）记 skip，其余照跑。所以第一次推不用改 yaml；第一次跑出来以后用 --view 钉住
（带视图 → require：以后哪次探不过就红，不会悄悄少测一截）。--view auto 只在 GitHub Actions 上会退到 --no-view：本机一定建得了
离屏窗口，探不过就是回归，和 require 一样记 FAIL（只有 --force-no-view 自检时例外）。本地 photot 模式不探，总是带视图。

组：A 没有宿主  B 起宿主（R6 T1–T4、T10、T11、T13、T17，hello、积压、连接上限、桥关、自愈、窗口、取消、截止时间……）
    C 杀掉 / 重起 / 抢锁（R6 T5–T9、T12、T14、T16、T18，CLOEXEC）  D SIGPIPE 矩阵（R6 §4.3 五行）  E --app-ui 不开桥
    F 读和图片（§10.7 第 31–36、38 条：fixture 读和 --verdicts 对账、cursor、预览、受保护位置不读原图、并发、取消、NaN、
      输出目录）
    G 写（§9.8.2 第 3–12、25–27、29 条，§10.7 第 8、9、13、16、33、35–37 条：一个请求恰好一步撤销、app_undo 回到原样、
      op_id 重放、忙信号、切场次、受保护位置、一键成套 / 换封面、找模板、取消、kill -9 → app_outcome_unknown）
    H 标题栏指示和菜单开关（§9.6a、§9.8.2 第 21 条、§10.8 第 1、2、8 条）：没有 AI 不显示 → 「Claude Code 已连接」→
      等用户停手时不变 →「AI 正在操作…」→ 那一页的提示 → 淡掉；带标题栏的宿主（--titled）里 AppKit 窗口的副标题跟着走；
      菜单开关关掉 → 读写都 bridge_off、进程内的照常、不写 UserDefaults，打开 → 恢复；另一个实例的那一句；
      桥停了（§9.2.4）：真的抢锁 → 关桥、「数据目录的锁被别的程序拿走了…」一直留着、读写 app_unreachable（不说菜单）；
      重新 bind 失败 / 一启动就开不了桥 → 带原因的那一句，开好了消失
每个 --mcp 都带自己的 LABELGUI_MCP_OUT（工作目录里），绝不写 ~/Pictures/xuanpian-mcp。

不碰用户（§9.8.2 的四道闸，一条不改；第 4 道 2026-10-29 收紧）：
1. 每个宿主、每个 --mcp 都带临时的 LABELGUI_DATA_DIR（realpath 或 dev:ino 等于真实数据目录就 exit 2）和 LABELGUI_NO_GUI=1；
2. socket 根目录是工作目录下自己建的 0700 目录（经 /tmp/xpls.* 这个短链接接过去：sun_path 只有 104 字节），
   等于真实的 $(getconf DARWIN_USER_TEMP_DIR)xuanpian-live 就 exit 2；那个真实目录只 ls、跑前跑后比，绝不进去建东西；
3. 连上以后先看 hello 的 app.pid，必须是脚本自己起的宿主，否则立刻断开、exit 2；
4. 路径（原样的或者解析了符号链接的）在 *.app/Contents/MacOS/ 下面的二进制，只有 --ci 而且 GITHUB_ACTIONS=true 才收，
   否则起任何进程之前就 exit 2。原因：.app 里的二进制崩了 / 被杀了，系统会在用户屏幕上弹「选片工具 意外退出」，
   框上的「重新打开」会以用户的真实数据开出一个 app（2026-10-29 真出过）；它的设置域也就是用户真 app 的
   local.culling.labelgui。CI 上收了，也不跑故意杀进程 / sandbox 对照的那几组（C、D 整组，A、F、G 里的 sandbox、kill -9）。
只给脚本自己起的进程发信号（按 Popen 拿到的 pid），从不 pkill。跑前跑后 defaults export LabelGUI / local.culling.labelgui 不变。
原型：R6 的 tests.py（T1–T18）、sigpipe_matrix.py。
"""
import base64, ctypes, errno, fcntl, hashlib, json, os, pwd, random, re, select, shutil, signal, socket, struct, subprocess, sys
import tempfile, threading, time, unicodedata, uuid

ARGS = sys.argv[1:]
if not ARGS or ARGS[0].startswith("-"):
    print(__doc__)
    sys.exit(2)
BIN = os.path.abspath(ARGS[0])
CI = "--ci" in ARGS
KEEP = "--keep" in ARGS
ON_GITHUB = os.environ.get("GITHUB_ACTIONS") == "true"
SLACK = 4.0 if ON_GITHUB else 1.0


def opt(name):
    return ARGS[ARGS.index(name) + 1] if name in ARGS and ARGS.index(name) + 1 < len(ARGS) else None


ONLY = set((opt("--only") or "ABCDEFGH").upper().replace(",", ""))
PHOTOS_SRC, DATA_SRC = opt("--photos"), opt("--data")
COLLAGE_SRC = opt("--collage-data")
# 自检用：让 --ci 的视图探针真的失败一次（probe_view），证明 CI 上的 --no-view 退路走得通
FORCE_NO_VIEW = "--force-no-view" in ARGS
# 带不带视图（§10.6 STEP 4）：auto 由探针定（GitHub 上探不过退到 --no-view），require 探不过就 FAIL，no-view 不探
VIEW_MODE = opt("--view") or "auto"


def in_app_bundle(path):
    """路径在某个 .app 的 Contents/MacOS/ 下面（不分大小写：APFS 默认不分，LaunchServices 也不分）。"""
    return re.search(r"\.app/Contents/MacOS/", path, re.I) is not None


# 闸 4（2026-10-29 收紧）：原样的路径和解析了符号链接的路径，只要有一个在 .app 里，就只在 CI（--ci 且 GITHUB_ACTIONS=true）
# 上收。放在一切之前：不建工作目录、不起任何进程（连 --session-key 都不跑）
BUNDLE = in_app_bundle(os.path.abspath(ARGS[0])) or in_app_bundle(os.path.realpath(ARGS[0]))
if BUNDLE and not (CI and ON_GITHUB):
    print(f"{ARGS[0]} 在 .app 里面（原样或解析符号链接以后）：只有 CI（--ci 且 GITHUB_ACTIONS=true）才收 app 里的二进制，"
          f"本机一律用裸二进制（.build/release/LabelGUI 这类）。不跑，什么都没起")
    sys.exit(2)
# app 里的二进制（只可能是 CI）：故意杀进程、sandbox 对照（会被 SIGKILL）的整组不跑，其余组里的那几段也跳过
NO_KILL = BUNDLE
if NO_KILL:
    ONLY -= {"C", "D"}
if "--plan" in ARGS:
    print(f"plan bundle={int(BUNDLE)} no_kill={int(NO_KILL)} groups={''.join(sorted(ONLY))}")
    sys.exit(0)
if not CI and not (PHOTOS_SRC and DATA_SRC):
    print("要么 --ci，要么 --photos <照片目录> --data <已分析的数据目录>")
    sys.exit(2)
if FORCE_NO_VIEW and not CI:
    print("--force-no-view 只配 --ci（本地 photot 模式不探，总是带视图）")
    sys.exit(2)
if VIEW_MODE not in ("auto", "require", "no-view") or ("--view" in ARGS and not CI):
    print("--view 只配 --ci，取值 auto、require、no-view（本地 photot 模式不探，总是带视图）")
    sys.exit(2)
if not os.access(BIN, os.X_OK):
    print(f"不是可执行文件：{BIN}")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "Sources", "LabelGUI")
FIX = os.path.join(ROOT, "Fixtures", "photot-session")
HOME = pwd.getpwuid(os.getuid()).pw_dir
REAL_DATA = os.path.join(HOME, "Library", "Application Support", "选片工具")
TEMP = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
REAL_SOCK = os.path.join(TEMP, "xuanpian-live")

if opt("--work"):
    WORK = os.path.abspath(opt("--work"))
    mark = os.path.join(WORK, ".live_smoke-work")
    if os.path.lexists(WORK) and not (os.path.isdir(WORK) and not os.path.islink(WORK)
                                      and (not os.listdir(WORK) or os.path.isfile(mark))):
        print(f"--work {WORK} 不是空目录，也不是 live_smoke.py 自己建的（没有 .live_smoke-work 标记）：不删它，不跑")
        sys.exit(2)
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    open(mark, "w").close()
elif ON_GITHUB:
    # GitHub 上放 /tmp 下（解析成 /private/tmp/…，和本地给 --work 时同一种写法）：第 22 条（/tmp ↔ /private/tmp 两种写法）
    # 要工作目录在 /private/tmp 下，默认的 $TMPDIR（/var/folders/…）下面那一条只能 skip
    WORK = os.path.realpath(tempfile.mkdtemp(prefix="live_smoke.", dir="/tmp"))
else:
    WORK = tempfile.mkdtemp(prefix="live_smoke.")
SOCKS = os.path.join(WORK, "socks")
os.makedirs(SOCKS, mode=0o700)
LINK = tempfile.mktemp(prefix="xpls.", dir="/tmp")  # 短链接：/tmp/xpls.xxxxxxxx → <工作目录>/socks
os.symlink(SOCKS, LINK)
# G 组 bookmark 那条用：照片文件夹的路径不能以 /private 开头（BatchStore.sessionKey 走 standardizedFileURL，/private/tmp/…
# 存在时算成 /tmp/…、挪走以后又算回 /private/tmp/…，key 一变 app 就找不到 bookmark，测不出跟不跟它）。用完删掉
BM_LINK = tempfile.mktemp(prefix="xpbm.", dir="/tmp")
os.makedirs(os.path.join(WORK, "bm"))
os.symlink(os.path.join(WORK, "bm"), BM_LINK)
SNAPS = os.path.join(WORK, "snaps")
os.makedirs(SNAPS)

failures = []
counts = {"ok": 0, "skip": 0}
PROCS = []
# 宿主带不带视图（离屏窗口）：--ci 开跑前由 probe_view() 定，本地 photot 模式总是带（§9.8.1、§10.6 STEP 4）
VIEW = True


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg, flush=True)
    if cond:
        counts["ok"] += 1
    else:
        failures.append(msg)
    return cond


def skip(msg):
    counts["skip"] += 1
    print("  skip " + msg, flush=True)


def view_check(cond, msg):
    """要窗口才测得出来的（快照、标题栏、AppKit 窗口的副标题、批量页消费选中）：CI 用 --no-view 时记 skip，不算通过。"""
    if VIEW:
        return check(cond, msg)
    skip(f"{msg}（CI 用 --no-view：宿主没有窗口，这一条看本地）")
    return True


def W(subtitle):
    """AppKit 窗口副标题的期望值：CI 用 --no-view 时宿主没有窗口，test.state 里 window_subtitle 是 null。"""
    return subtitle if VIEW else None


def host_args(args):
    """CI 定了用 --no-view（VIEW 为假）：--titled 去掉、补上 --no-view —— 每个宿主都不建窗口。"""
    if VIEW:
        return tuple(args)
    return tuple(a for a in args if a not in ("--titled", "--no-view")) + ("--no-view",)


def same_dir(a, b):
    try:
        sa, sb = os.stat(a), os.stat(b)
        return (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino)
    except OSError:
        return os.path.realpath(a) == os.path.realpath(b)


def real_sock_state():
    """真实 SockDir 只 ls：在不在、里面有什么（和 mtime）。"""
    if not os.path.lexists(REAL_SOCK):
        return None
    try:
        return sorted(os.listdir(REAL_SOCK)), os.lstat(REAL_SOCK).st_mtime_ns
    except OSError as e:
        return repr(e)


def defaults_export(domain):
    r = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
    return (r.returncode, r.stdout if r.returncode == 0 else b"")


SOCK_N = [0]


def sock_root(label):
    """一个宿主一个 socket 根目录（0700，工作目录里的真目录，经短链接接过去）。"""
    SOCK_N[0] += 1
    name = f"r{SOCK_N[0]}"
    d = os.path.join(SOCKS, name)
    os.makedirs(d, mode=0o700)
    os.chmod(d, 0o700)
    root = os.path.join(LINK, name)
    if same_dir(root, REAL_SOCK) or os.path.realpath(root) == os.path.realpath(REAL_SOCK) \
            or os.path.realpath(root).startswith(os.path.realpath(REAL_SOCK) + "/"):
        print(f"socket 根目录 {root} 落到了真实的 {REAL_SOCK}：不跑")
        sys.exit(2)
    return root


def session_key(path):
    """BatchStore.sessionKey(for:)：FNV-1a 算在文件 URL 的 path 上（NFD）。"""
    h = 0xcbf29ce484222325
    for b in unicodedata.normalize("NFD", path).encode():
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


# ---------------------------------------------------------------- 照片和数据目录

if CI:
    PHOTO_DIR = "/tmp/labelgui-fixture-photot"   # 不存在（verdict_regression.sh 同一个约定）；manifest 里的 21 张照样认
    KEY = session_key(PHOTO_DIR)
    FIXTURE = os.path.join(WORK, "fixture")
    os.makedirs(os.path.join(FIXTURE, "sessions", KEY))
    for name in ("manifest.json", "layer1_results.json"):
        shutil.copy(os.path.join(FIX, name), os.path.join(FIXTURE, "sessions", KEY, name))
    with open(os.path.join(FIXTURE, "sessions.json"), "w") as f:
        json.dump([{"key": KEY, "path": PHOTO_DIR, "name": "labelgui-fixture-photot", "lastAnalyzed": "2026-10-26T17:00:00Z",
                    "photoCount": 21}], f, ensure_ascii=False)
    DATA_TEMPLATE = FIXTURE
else:
    PHOTO_DIR = os.path.abspath(PHOTOS_SRC)
    DATA_TEMPLATE = os.path.abspath(DATA_SRC)
    KEY = session_key(PHOTO_DIR)
EMPTY_PHOTOS = os.path.join(WORK, "空文件夹")
os.makedirs(EMPTY_PHOTOS)
DATA_N = [0]


def fresh_data(label):
    """每个宿主一份新的数据目录（闸 1：解析到真实数据目录就不跑）。"""
    DATA_N[0] += 1
    d = os.path.join(WORK, f"data-{DATA_N[0]}-{label}")
    shutil.copytree(DATA_TEMPLATE, d, symlinks=True)
    for dp, dns, fns in os.walk(d):
        for n in dns + fns:
            p = os.path.join(dp, n)
            if not os.path.islink(p):
                os.chmod(p, os.stat(p).st_mode | 0o200)
    os.chmod(d, os.stat(d).st_mode | 0o200)
    guard_data(d)
    return d


def guard_data(d):
    if same_dir(d, REAL_DATA) or os.path.realpath(d) == os.path.realpath(REAL_DATA):
        print(f"LABELGUI_DATA_DIR {d} 指到了真实数据目录：不跑")
        sys.exit(2)


def base_env(data, root, **extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith("LABELGUI_") and not k.startswith("DYLD_")}
    env["LABELGUI_NO_GUI"] = "1"
    if data is not None:
        if os.path.isabs(data):
            guard_data(data)
        env["LABELGUI_DATA_DIR"] = data
    env["LABELGUI_LIVE_SOCK_ROOT"] = root
    # 预览输出目录（§10.3）：测试绝不写 ~/Pictures/xuanpian-mcp
    env["LABELGUI_MCP_OUT"] = os.path.join(WORK, "mcp-out")
    # §6.3 那条 warning（设了 LABELGUI_DATA_DIR、not_running、选片工具却开着）要看「选片工具开着」：钉成没开，
    # 结果不跟着用户的真 app 开没开变，--mcp 也不去查用户的进程表
    env["LABELGUI_MCP_TEST_GUI_RUNNING"] = "0"
    for k, v in extra.items():
        if v is None:
            env.pop(k, None)
        else:
            env[k] = str(v)
    return env


# ---------------------------------------------------------------- 宿主

READY = re.compile(r"^ready sock=(\S+) pid=(\d+) data_dir_id=(\S+) bridge=(\S+) reason=(\S+)$")


class Host:
    def __init__(self, label, data=None, root=None, photos=None, args=(), wait=True, env_extra=None, wrap=(), **extra):
        self.label = label
        self.data = data or fresh_data(label)
        self.root = root or sock_root(label)
        self.err_path = os.path.join(WORK, f"host-{label}-{len(PROCS)}.err")
        env = base_env(self.data, self.root, LABELGUI_STABLE_SEEDS="1", LABELGUI_LIVE_TEST_OUT=SNAPS,
                       LABELGUI_LIVE_TEST_SELFCHECK_MS="500", **extra)
        env.update(env_extra or {})
        self.t0 = time.monotonic()
        args = host_args(args)
        self.proc = subprocess.Popen([*wrap, BIN, "--live-host", photos or PHOTO_DIR, *args], env=env, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=open(self.err_path, "w"), cwd=WORK)
        PROCS.append(self)
        self.sock = self.data_dir_id = self.bridge = self.reason = None
        self.ready_ms = None
        if wait:
            self.wait_ready()

    @property
    def pid(self):
        return self.proc.pid

    def wait_ready(self, timeout=30):
        deadline = time.monotonic() + timeout * SLACK
        line = b""
        while time.monotonic() < deadline and self.proc.poll() is None:
            r, _, _ = select.select([self.proc.stdout], [], [], 0.2)
            if not r:
                continue
            chunk = os.read(self.proc.stdout.fileno(), 4096)
            if not chunk:
                break
            line += chunk
            for l in line.decode(errors="replace").splitlines():
                m = READY.match(l.strip())
                if m:
                    self.sock, pid, self.data_dir_id, self.bridge, self.reason = m.groups()
                    self.ready_ms = (time.monotonic() - self.t0) * 1000
                    if int(pid) != self.proc.pid:
                        print(f"宿主 ready 行里的 pid {pid} 不是脚本起的 {self.proc.pid}：不跑")
                        sys.exit(2)
                    return True
        return False

    def alive(self):
        return self.proc.poll() is None

    def signal(self, sig):
        if self.alive():
            os.kill(self.proc.pid, sig)

    def term(self, timeout=5):
        if self.alive():
            os.kill(self.proc.pid, signal.SIGCONT)
            os.kill(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.kill(self.proc.pid, signal.SIGKILL)
                self.proc.wait(timeout=5)
        return self.proc.returncode

    def kill9(self):
        if self.alive():
            os.kill(self.proc.pid, signal.SIGKILL)
            self.proc.wait(timeout=5)

    def log(self):
        try:
            return open(self.err_path, encoding="utf-8", errors="replace").read()
        except OSError:
            return ""

    def env(self, **extra):
        """经这个宿主的数据目录和 socket 根目录起 --mcp 的环境。"""
        return base_env(self.data, self.root, **extra)


# ---------------------------------------------------------------- 直接连宿主的 socket（test.*、对抗性用例）

class Raw:
    def __init__(self, host, timeout=10, hello=True, client=None):
        self.host = host
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect(host.sock)
        self.buf = b""
        self.nid = 0
        self.hello_reply = None
        if hello:
            self.hello_reply = self.hello(client=client)
            res = self.hello_reply.get("result") or {}
            # 闸 3：对端必须是脚本自己起的宿主
            if (res.get("app") or {}).get("pid") != host.pid:
                self.s.close()
                print(f"hello 回的 app.pid {(res.get('app') or {}).get('pid')} 不是脚本起的宿主 {host.pid}：断开、不跑")
                sys.exit(2)

    def send(self, obj):
        self.s.sendall((json.dumps(obj, ensure_ascii=False) + "\n").encode())

    def recv(self):
        while b"\n" not in self.buf:
            c = self.s.recv(1 << 20)
            if not c:
                raise EOFError
            self.buf += c
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def hello(self, proto=1, data_dir_id=None, client=None):
        params = {"proto": proto, "data_dir": self.host.data, "data_dir_id": data_dir_id or self.host.data_dir_id,
                  "client": client or {"name": "live_smoke", "pid": os.getpid()}}
        self.send({"id": 0, "method": "hello", "params": params})
        return self.recv()

    def req(self, method, params=None, deadline=10000, op_id=None):
        self.nid += 1
        m = {"id": self.nid, "method": method, "params": params or {}, "deadline_ms": deadline}
        if op_id:
            m["op_id"] = op_id
        self.send(m)
        return self.nid

    def call(self, method, params=None, deadline=10000, op_id=None):
        i = self.req(method, params, deadline, op_id)
        while True:
            m = self.recv()
            if m.get("id") == i:
                return m

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def test_call(host, method, params=None, **kw):
    r = Raw(host)
    try:
        return r.call(method, params, **kw)
    finally:
        r.close()


def state(host):
    return test_call(host, "test.state").get("result") or {}


def just_after_selfcheck(host, timeout=3):
    """等宿主刚做完一次自检（测试 500 ms 一次）再动手：接下来约 500 ms 里它不会自愈，「被删以后立刻是什么状态」才测得准。"""
    n0 = state(host)["counters"].get("selfchecks", 0)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if state(host)["counters"].get("selfchecks", 0) != n0:
            return True
        time.sleep(0.01)
    return False


# ---------------------------------------------------------------- --mcp

def mcp_call(env, tool, args=None, timeout=30):
    t = time.monotonic()
    r = subprocess.run([BIN, "--mcp-call", tool, json.dumps(args or {}, ensure_ascii=False)], env=env, capture_output=True,
                       timeout=timeout * SLACK, cwd=WORK, stdin=subprocess.DEVNULL)
    ms = (time.monotonic() - t) * 1000
    body = None
    try:
        out = json.loads(r.stdout.decode().strip().splitlines()[-1])
        body = json.loads(out["content"][0]["text"])
    except Exception:
        pass
    return r.returncode, body, ms


def status(env):
    _, body, ms = mcp_call(env, "app_status")
    return body or {}, ms


def err_code(body):
    return ((body or {}).get("error") or {}).get("code")


APP_TOOLS = ["cull_session_overview", "cull_list_photos", "cull_get_photos", "cull_list_groups", "cull_preview_photos",
             "collage_get_state", "app_open_session", "cull_set_verdicts", "cull_show_photos", "collage_apply_template",
             "collage_run_kit", "collage_next_cover", "collage_set_text", "collage_set_style", "app_undo"]
# hello 里的 capabilities（§10.4 的 12 个，按名字排）
ALL_CAPS = sorted(["cull.read", "cull.preview", "collage.state", "session.open", "cull.set_verdicts", "cull.show",
                   "collage.apply_template", "collage.run_kit", "collage.next_cover", "collage.set_text", "collage.set_style",
                   "undo"])


def minimal_args(tool, session):
    """够过参数校验和 session 核对的最小参数（读写都在 live 时先查参数）。写工具只在 app 没开 / 连不上时这样调（不会真执行）。"""
    a = {"session": session}
    if tool == "app_undo":
        a = {"target": "collage"}
    if tool in ("cull_get_photos", "cull_preview_photos", "cull_set_verdicts", "cull_show_photos"):
        a["ids"] = ["DSCF7208"]
    if tool == "cull_set_verdicts":
        a["verdict"] = "pick"
    if tool == "cull_list_groups":
        a["kind"] = "scene"
    if tool == "collage_apply_template":
        a["template"] = "时尚刊"
    if tool == "collage_run_kit":
        a["kit"] = "fashionIssue"
    if tool == "collage_set_text":
        a["title"] = "x"
    if tool == "collage_set_style":
        a["look_strength"] = 0.5
    return a


def all_tools(env, session):
    return {t: err_code(mcp_call(env, t, minimal_args(t, session))[1]) for t in APP_TOOLS}


class Mcp:
    """一个常驻的 --mcp（取消、LIVE=0 的 tools/list、initialize 报的 clientInfo）。"""

    def __init__(self, env):
        self.p = subprocess.Popen([BIN, "--mcp"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, cwd=WORK)
        PROCS.append(self)
        self.buf = b""
        self.frames = []

    @property
    def pid(self):
        return self.p.pid

    def send(self, obj):
        self.p.stdin.write((json.dumps(obj, ensure_ascii=False) + "\n").encode())
        self.p.stdin.flush()

    def pump(self, timeout):
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            return
        chunk = os.read(self.p.stdout.fileno(), 1 << 20)
        self.buf += chunk
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            if line.strip():
                self.frames.append(json.loads(line))

    def wait_id(self, i, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for f in self.frames:
                if f.get("id") == i:
                    return f
            self.pump(0.05)
        return None

    def initialize(self, name="claude-code", version="2.1.303"):
        self.send({"jsonrpc": "2.0", "id": "init", "method": "initialize",
                   "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": name, "version": version}}})
        r = self.wait_id("init")
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return r

    def call(self, i, name, args=None):
        self.send({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args or {}}})

    def tool(self, i, name, args=None, timeout=15):
        self.call(i, name, args)
        f = self.wait_id(i, timeout)
        try:
            return json.loads(f["result"]["content"][0]["text"])
        except Exception:
            return None

    def alive(self):
        return self.p.poll() is None

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.kill(self.p.pid, signal.SIGKILL)
            self.p.wait(timeout=3)

    def term(self, timeout=3):
        if self.alive():
            self.close()


# ---------------------------------------------------------------- STEP 3a：读工具、合成图（F 组用）

V_CN = {"精选": "pick", "可用": "usable", "废片": "reject"}


def parse_verdicts(text):
    """`--verdicts [--per-photo]` 的输出 → 计数、近似重复、场、理由、「场 N」那几行、每张的判决和理由。"""
    out = {"reasons": {}, "scene_lines": [], "per_photo": {}}
    m = re.search(r"^照片 (\d+) · 精选 (\d+) · 可用 (\d+) · 废片 (\d+)$", text, re.M)
    out["counts"] = tuple(int(x) for x in m.groups()) if m else None
    m = re.search(r"^近似重复 (\d+) 组 / (\d+) 张", text, re.M)
    out["dups"] = tuple(int(x) for x in m.groups()) if m else None
    m = re.search(r"^场 \(间隔≤\d+s\) (\d+) 个多张场 / (\d+) 张 · 待处理 (\d+)$", text, re.M)
    out["scenes"] = tuple(int(x) for x in m.groups()) if m else None
    for r_, n in re.findall(r"^  理由 (\S+): (\d+)$", text, re.M):
        out["reasons"][r_] = int(n)
    for take, members in re.findall(r"^  场 (\d+) \(\d+ 张\): (.+)$", text, re.M):
        row = []
        for tok in members.split():
            mm = re.match(r"^(.+)=(精选|可用|废片)(?:#(\d+))?$", tok)
            row.append((mm.group(1), V_CN[mm.group(2)], int(mm.group(3)) if mm.group(3) else None))
        out["scene_lines"].append((int(take), row))
    if re.search(r"^阈值: ", text, re.M):
        for pid, v, reasons in re.findall(r"^  (\S+) (精选|可用|废片) (\S+)", text, re.M):
            out["per_photo"][pid] = (V_CN[v], reasons)
    return out if out["counts"] else None


def verdicts_cli():
    """本地 photot：在同一份数据的另一个拷贝上跑 `--verdicts --per-photo`。它会给 batch.* 两个设置赋值（didSet 写裸二进制的
    LabelGUI 域），所以只在那两个键已经是 0 时跑（verdict_regression.sh 每次都写同样的值）；收尾照样比 defaults export。"""
    vals = [subprocess.run(["defaults", "read", "LabelGUI", k], capture_output=True, text=True).stdout.strip()
            for k in ("batch.rejectBurstDuplicates", "batch.minKeepersPerChapter")]
    if vals != ["0", "0"]:
        skip(f"LabelGUI 域的 batch.* 不是 0 / 0（{vals}）：不跑 --verdicts，免得改用户的设置")
        return None
    d = fresh_data("F-verdicts")
    r = subprocess.run([BIN, "--verdicts", PHOTO_DIR, "--per-photo"], env=base_env(d, sock_root("F-verdicts")),
                       capture_output=True, timeout=120, cwd=WORK, stdin=subprocess.DEVNULL)
    return parse_verdicts(r.stdout.decode(errors="replace")) if r.returncode == 0 else None


def fresh_copy(src, label):
    """别的数据目录拷一份（和 fresh_data 一样补上写权限：STEP 0 留下的那份是只读的）。"""
    DATA_N[0] += 1
    d = os.path.join(WORK, f"data-{DATA_N[0]}-{label}")
    shutil.copytree(src, d, symlinks=True, ignore=shutil.ignore_patterns(".live.lock"))
    for dp, dns, fns in os.walk(d):
        for n in dns + fns:
            p_ = os.path.join(dp, n)
            if not os.path.islink(p_):
                os.chmod(p_, os.stat(p_).st_mode | 0o200)
    os.chmod(d, os.stat(d).st_mode | 0o200)
    guard_data(d)
    return d


def mcp_full(env, tool, args=None, timeout=60):
    """--mcp-call 的整个结果（content 里的 image 块也要）+ text 解出来的对象。"""
    t = time.monotonic()
    r = subprocess.run([BIN, "--mcp-call", tool, json.dumps(args or {}, ensure_ascii=False)], env=env, capture_output=True,
                       timeout=timeout * SLACK, cwd=WORK, stdin=subprocess.DEVNULL)
    ms = (time.monotonic() - t) * 1000
    try:
        out = json.loads(r.stdout.decode().strip().splitlines()[-1])
        return out, json.loads(out["content"][0]["text"]), ms
    except Exception:
        return None, None, ms


def image_blocks(out):
    return [base64.b64decode(c["data"]) for c in (out or {}).get("content", [])[1:] if c.get("type") == "image"]


def cur_first(env):
    _, p_, _ = mcp_call(env, "cull_list_photos", {"session": KEY, "limit": 1})
    return (p_ or {}).get("next_cursor") or "x"


def make_bmp(path, w, h, seed, amp=16):
    """24 位 BMP：四个象限四种颜色（左上红、右上绿、左下蓝、右下黄）+ 噪声，JPEG 才有一两百 KB（纯色只有几 KB，测不出什么）。"""
    rnd = random.Random(seed)
    rb = w * 3
    pad = (4 - rb % 4) % 4
    table = bytes((b * amp) // 256 for b in range(256))
    half = w // 2
    tl, tr, bl, br = bytes((40, 40, 200)), bytes((40, 180, 40)), bytes((200, 60, 40)), bytes((40, 190, 200))
    top = int.from_bytes(tl * half + tr * (w - half), "big")
    bot = int.from_bytes(bl * half + br * (w - half), "big")
    body = bytearray()
    for y in range(h):              # BMP 从下往上
        base = bot if y < h // 2 else top
        noise = int.from_bytes(rnd.randbytes(rb).translate(table), "big")
        body += (base + noise).to_bytes(rb, "big") + b"\0" * pad
    hdr = struct.pack("<2sIHHI", b"BM", 54 + len(body), 0, 0, 54)
    hdr += struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(body), 2835, 2835, 0, 0)
    with open(path, "wb") as f:
        f.write(hdr + body)


def to_jpeg(bmp, jpg):
    r = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80", bmp, "--out", jpg], capture_output=True)
    os.unlink(bmp)
    return r.returncode == 0 and os.path.isfile(jpg)


SYN_IDS = None
SYN_CACHE = os.path.join(WORK, "合成图缓存")


def synth_session(label, photos_dir=None):
    """合成图场次：照片文件夹（原图 1800×1200）+ 一份新数据目录（sessions/<key>/ 下 manifest、layer1（fixture 前 6 张的，
    带人脸框）、previews/<id>.jpg 1024×683）。manifest 带 body_serial：打开时不去读原图补序列号。"""
    global SYN_IDS
    man = json.load(open(os.path.join(FIX, "manifest.json")))
    l1 = json.load(open(os.path.join(FIX, "layer1_results.json")))
    photos = man["photos"][:6]
    SYN_IDS = [p["id"] for p in photos]
    if not os.path.isdir(SYN_CACHE):
        os.makedirs(os.path.join(SYN_CACHE, "orig"))
        os.makedirs(os.path.join(SYN_CACHE, "prev"))
        for i, p in enumerate(photos):
            for kind, (w, h) in (("orig", (1800, 1200)), ("prev", (1024, 683))):
                bmp = os.path.join(SYN_CACHE, kind, p["id"] + ".bmp")
                make_bmp(bmp, w, h, seed=i * 2 + (kind == "prev"))
                if not to_jpeg(bmp, os.path.join(SYN_CACHE, kind, p["id"] + ".jpg")):
                    print("sips 转不出 JPEG：合成图场次做不出来")
                    sys.exit(2)
    pdir = photos_dir or os.path.join(WORK, f"syn-{label}")
    if not os.path.isdir(pdir):
        shutil.copytree(os.path.join(SYN_CACHE, "orig"), pdir)
    # key 让二进制自己算（BatchStore.sessionKey 走 standardizedFileURL：/private/tmp/… 会变成 /tmp/…，Python 这边算不准）
    r = subprocess.run([BIN, "--session-key", pdir], env=base_env(os.path.join(WORK, "session-key-data"), LINK),
                       capture_output=True, text=True, timeout=30, cwd=WORK, stdin=subprocess.DEVNULL)
    key = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
    if not re.match(r"^[0-9a-f]{16}$", key):
        print(f"--session-key 算不出 {pdir} 的 key：{r.stdout!r} {r.stderr[-300:]!r}")
        sys.exit(2)
    data = os.path.join(WORK, f"data-syn-{label}")
    sdir = os.path.join(data, "sessions", key)
    shutil.copytree(os.path.join(SYN_CACHE, "prev"), os.path.join(sdir, "previews"))
    rows = []
    for p in photos:
        q = dict(p)
        q["raw_path"] = q["decode_path"] = os.path.join(pdir, p["id"] + ".jpg")
        q["preview_path"] = f"previews/{p['id']}.jpg"
        q["body_serial"] = "SYN0001"
        rows.append(q)
    json.dump({"photo_dir": pdir, "photos": rows}, open(os.path.join(sdir, "manifest.json"), "w"), ensure_ascii=False)
    keep = set(SYN_IDS)
    l1o = dict(l1)
    l1o["results"] = [r for r in l1["results"] if r["id"] in keep]
    json.dump(l1o, open(os.path.join(sdir, "layer1_results.json"), "w"), ensure_ascii=False)
    json.dump([{"key": key, "path": pdir, "name": os.path.basename(pdir), "lastAnalyzed": "2026-10-29T10:00:00Z",
                "photoCount": len(rows)}], open(os.path.join(data, "sessions.json"), "w"), ensure_ascii=False)
    guard_data(data)
    syn_keys[pdir] = key
    return {"dir": pdir, "key": key, "data": data, "ids": SYN_IDS}


syn_keys = {}


# ---------------------------------------------------------------- STEP 3b：写（G 组用）

def session_key_of(path):
    """二进制自己算的 session key（Python 算不准 /private/tmp ↔ /tmp 这类）。"""
    r = subprocess.run([BIN, "--session-key", path], env=base_env(os.path.join(WORK, "session-key-data"), LINK),
                       capture_output=True, text=True, timeout=30, cwd=WORK, stdin=subprocess.DEVNULL)
    key = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
    if not re.match(r"^[0-9a-f]{16}$", key):
        print(f"--session-key 算不出 {path} 的 key：{r.stdout!r}")
        sys.exit(2)
    return key


def register_sessions(data, folders):
    """往数据目录的 sessions.json 后面追加几场（只登记，不分析）：app_open_session 只能打开「最近场次」里的（§10.4）。"""
    path = os.path.join(data, "sessions.json")
    rows = json.load(open(path)) if os.path.exists(path) else []
    for f in folders:
        rows.append({"key": session_key_of(f), "path": f, "name": os.path.basename(f), "lastAnalyzed": "2026-10-29T10:00:00Z",
                     "photoCount": 0})
    json.dump(rows, open(path, "w"), ensure_ascii=False)


def warn_codes(body):
    return [w.get("code") for w in (body or {}).get("warnings") or []]


def edata(body):
    return ((body or {}).get("error") or {}).get("data") or {}


# ---------------------------------------------------------------- 第 4 道闸自己的自检：假的 .app 路径，脚本必须在起任何进程之前 exit 2

def bundle_gate_selfcheck():
    """拿一个假的「二进制」（两行 sh：真被启动就留下标记文件）放在 X.app/Contents/MacOS/ 下面，用三种写法（路径本身在 .app 里、
    外面的符号链接指进 .app、.APP 大写）调本脚本自己：没有 GITHUB_ACTIONS 时都必须 exit 2、标记文件不出现；
    --plan 加上 GITHUB_ACTIONS=true（CI 上收 app 里的二进制）时只打印计划：杀进程 / sandbox 的组不在里面。绝不起真的 LabelGUI。"""
    root = os.path.join(WORK, "fake-bundle")
    marker = os.path.join(root, "ran")
    os.makedirs(root)
    # 自检一完就删掉这棵假 .app 树（--keep 也删）：工作目录里不留任何 X.app / Y.APP
    try:
        stub = os.path.join(root, "stub.sh")
        open(stub, "w").write("#!/bin/sh\ntouch '" + marker.replace("'", "") + "'\nexit 0\n")
        os.chmod(stub, 0o755)
        inside = os.path.join(root, "X.app", "Contents", "MacOS", "LabelGUI")
        os.makedirs(os.path.dirname(inside))
        os.symlink(stub, inside)                       # 原样的路径在 .app 里，解析以后不在
        upper = os.path.join(root, "Y.APP", "Contents", "MacOS", "LabelGUI")
        os.makedirs(os.path.dirname(upper))
        shutil.copy(stub, upper)
        outside = os.path.join(root, "link-into-bundle")
        os.symlink(upper, outside)                     # 原样的路径不在 .app 里，解析以后在
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS" and not k.startswith("LABELGUI_")}
        me = os.path.abspath(__file__)
        rcs = []
        for path in (inside, upper, outside):
            for extra in (["--ci"], ["--photos", PHOTO_DIR, "--data", DATA_TEMPLATE]):
                r = subprocess.run([sys.executable, "-I", me, path, *extra], env=env, capture_output=True, timeout=60, cwd=WORK)
                rcs.append(r.returncode)
        plan = subprocess.run([sys.executable, "-I", me, inside, "--ci", "--plan"], env=dict(env, GITHUB_ACTIONS="true"),
                              capture_output=True, text=True, timeout=60, cwd=WORK).stdout.strip()
        # 这一次跑的二进制本身：裸的 → 计划里有全部组；app 里的（只可能在 CI 上）→ 去掉 GITHUB_ACTIONS 就 exit 2
        rb = subprocess.run([sys.executable, "-I", me, BIN, "--ci", "--plan"], env=env, capture_output=True, text=True,
                            timeout=60, cwd=WORK)
        bare = rb.stdout.strip() if not BUNDLE else ("exit 2" if rb.returncode == 2 else f"exit {rb.returncode}")
        check(rcs == [2] * 6 and not os.path.exists(marker),
              f"第 4 道闸：假 .app 路径（符号链接在 .app 里 / .APP 大写 / 外面的链接指进 .app）× (--ci、本地) 都在起进程之前 exit 2 "
              f"{rcs}，假二进制一次都没被启动")
        check(plan == "plan bundle=1 no_kill=1 groups=ABEFGH"
              and (bare == "exit 2" if BUNDLE else bare.startswith("plan bundle=0 no_kill=0 groups=ABCDEFGH")),
              f"CI 上收 app 里的二进制时不跑杀进程 / sandbox 的组（{plan!r}；裸二进制 {bare!r}）")
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ---------------------------------------------------------------- 带视图还是 --no-view（§9.8.1、§10.6 STEP 4）：--ci 开跑前探一次

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def probe_view():
    """起一个带标题栏的探针宿主（--titled：NSHostingView 放进带标题栏的离屏窗口，test.snapshot 和 test.chrome 都有），探 H 组要的
    那几样：页面拍得出来（PNG，>10 KB，和 E 组 --app-ui 同一个下限）；同一个状态拍两条标题栏逐字节相同；一次 app_status
    （--mcp-call，没有 initialize →「AI 已连接」）以后 AppKit 窗口的副标题换上、标题栏拍出来和之前不一样。都过回 None；
    宿主起不来 / 中途没了、方法回错、卡住、标题栏不跟着变，回一句原因。等的时间都跟着 SLACK 放宽：runner 慢、但拍得出来时
    不能被误判成「建不了窗口」（那样整个 CI 会悄悄少测一截）。H 组自己的 wait_ms 不放宽：它有「刚做完」1.5 s 这类窗口要赶。
    --force-no-view：探针宿主的快照目录给一个不存在的（宿主只查是不是绝对路径），test.snapshot 真的写不出 → 走同一条退路。"""
    extra = {"LABELGUI_LIVE_TEST_OUT": os.path.join(WORK, "no-such-dir", "snaps")} if FORCE_NO_VIEW else None
    h = None

    def take(method, params):
        """拍一张，回 (PNG 字节, 结果)；拍不出来回 (None, 原因)。"""
        raw_ = Raw(h, timeout=10 * SLACK)
        try:
            r = raw_.call(method, params, deadline=int(10_000 * SLACK))
        finally:
            raw_.close()
        res, err = r.get("result") or {}, r.get("error") or {}
        if err or not res.get("file"):
            return None, f"{method} 拍不出来（{err.get('code')}：{err.get('message')}）"
        data = open(res["file"], "rb").read()
        if not data.startswith(PNG_MAGIC) or (method == "test.snapshot" and len(data) <= 10_000):
            return None, f"{method} 拍出来的不像一张页面（{len(data)} 字节）"
        return data, res

    try:
        h = Host("view-probe", args=("--titled",), wait=False, env_extra=extra)
        if not h.wait_ready(timeout=15):
            rc = h.proc.poll()
            last = (h.log().strip().splitlines() or ["stderr 是空的"])[-1][:160]
            return (f"带视图的宿主退出了（退出码 {rc}）" if rc is not None else f"带视图的宿主 {15 * SLACK:.0f} s 没就绪") + f"：{last}"
        page, why = take("test.snapshot", {"name": "view-probe", "tab": "批量处理", "wait_ms": int(800 * SLACK)})
        if page is None:
            return why
        c1, why = take("test.chrome", {"name": "view-probe-chrome-1", "wait_ms": int(300 * SLACK)})
        if c1 is None:
            return why
        c2, why = take("test.chrome", {"name": "view-probe-chrome-2", "wait_ms": int(300 * SLACK)})
        if c2 is None:
            return why
        if c1 != c2:
            return f"同一个状态拍两条标题栏不一样（{len(c1)}、{len(c2)} 字节）：H 组的逐字节比对在这台机器上做不了"
        mcp_call(h.env(), "app_status")
        deadline = time.monotonic() + 5 * SLACK
        sub = state(h).get("window_subtitle")
        while sub != "AI 已连接" and time.monotonic() < deadline:
            time.sleep(0.05)
            sub = state(h).get("window_subtitle")
        c3, res3 = take("test.chrome", {"name": "view-probe-chrome-3", "wait_ms": int(300 * SLACK)})
        if c3 is None:
            return res3
        if sub != "AI 已连接" or res3.get("subtitle") != "AI 已连接" or c3 == c1:
            return (f"副标题换成「{res3.get('subtitle')}」（test.state 里「{sub}」）以后标题栏"
                    f"{'和之前逐字节相同' if c3 == c1 else '拍出来了'}：标题栏不跟着副标题变")
        return None if h.alive() else f"探针宿主拍完就没了（退出码 {h.proc.poll()}）"
    except Exception as e:      # 连不上、读到一半断了（宿主在 cacheDisplay 里崩了）、socket 超时
        return f"带视图的宿主拍快照时出错：{e!r}"[:200]
    finally:
        if h is not None:
            h.term()


# ---------------------------------------------------------------- 进程的 fd（CLOEXEC 从外面看）

LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
PROC_PIDLISTFDS, PROC_PIDFDVNODEPATHINFO, PROC_PIDFDSOCKETINFO = 1, 2, 3
PROX_FDTYPE_VNODE, PROX_FDTYPE_SOCKET = 1, 2
PROC_FP_CLEXEC = 2


def proc_fds(pid):
    """[(fd, 类型, fi_status, vnode 路径或 None)]：proc_pidinfo(PROC_PIDLISTFDS) + proc_pidfdinfo，fi_status 是
    struct proc_fileinfo 的第二个 uint32（所有 *_fdinfo 都以它开头）。"""
    buf = ctypes.create_string_buffer(8 * 4096)
    n = LIBPROC.proc_pidinfo(pid, PROC_PIDLISTFDS, ctypes.c_uint64(0), buf, len(buf))
    out = []
    for i in range(0, max(0, n), 8):
        fd = int.from_bytes(buf.raw[i:i + 4], "little", signed=True)
        kind = int.from_bytes(buf.raw[i + 4:i + 8], "little")
        if kind not in (PROX_FDTYPE_VNODE, PROX_FDTYPE_SOCKET):
            out.append((fd, kind, None, None))
            continue
        info = ctypes.create_string_buffer(4096)
        flavor = PROC_PIDFDVNODEPATHINFO if kind == PROX_FDTYPE_VNODE else PROC_PIDFDSOCKETINFO
        got = LIBPROC.proc_pidfdinfo(pid, fd, flavor, info, len(info))
        if got <= 0:
            out.append((fd, kind, None, None))
            continue
        status_ = int.from_bytes(info.raw[4:8], "little")
        path = None
        if kind == PROX_FDTYPE_VNODE:
            raw = info.raw[176:176 + 1024]
            path = raw.split(b"\0", 1)[0].decode(errors="replace")
        out.append((fd, kind, status_, path))
    return out


# ---------------------------------------------------------------- 开跑

print(f"二进制: {BIN}\n工作目录: {WORK}\nsocket 根目录: {LINK} → {SOCKS}\n照片: {PHOTO_DIR}（key {KEY}）\n"
      f"模式: {'--ci' if CI else '本地 photot'}{'（GitHub Actions）' if ON_GITHUB else ''}")
defaults_before = {d: defaults_export(d) for d in ("LabelGUI", "local.culling.labelgui")}
real_sock_before = real_sock_state()
print(f"真实 SockDir（只 ls）：{REAL_SOCK} → {real_sock_before}")

try:
    print("0. 第 4 道闸（.app 里的二进制）")
    bundle_gate_selfcheck()
    check(not os.path.lexists(os.path.join(WORK, "fake-bundle")), "第 4 道闸自检完：假 .app 那棵树已经删掉（--keep 也不留）")

    # ============================================================ CI 用带视图的宿主还是 --no-view（§9.8.1、§10.6 STEP 4）
    # 第一次推 CI 就由这一行定下来，不用改 yaml：探得过就全程带视图，探不过就全程 --no-view、要窗口的那几条记 skip。
    # 定下来以后 yaml 里用 --view 钉住：钉了 require，以后哪次探不过（窗口、快照、标题栏的回归）就是一条 FAIL，不会悄悄变成
    # 「绿、少测 15 条」。本机（不在 GitHub 上）一定建得了离屏窗口：auto 也按 require 算，只有 --force-no-view 自检退路时不算
    if CI and ONLY & set("BCDEFGH"):
        require = VIEW_MODE == "require" or (VIEW_MODE == "auto" and not ON_GITHUB and not FORCE_NO_VIEW)
        why = "--view no-view 钉住了，不探" if VIEW_MODE == "no-view" else probe_view()
        VIEW = why is None
        line = ("CI 用带视图的 --live-host：探针宿主（--titled）拍出了页面快照和标题栏，标题栏跟着副标题变" if VIEW else
                f"CI 用 --no-view：{why}。所有宿主改成 --no-view，要窗口的那几条（快照、标题栏、AppKit 窗口的副标题、"
                f"批量页消费选中、E 组的 --app-ui）记 skip，其余照跑")
        # GitHub Actions 上同一行带 ::notice::（探不过退到 --no-view 是 ::warning::：少测了一截），在这次运行的摘要页上就看得到
        # （% 要转义，§workflow commands）
        if ON_GITHUB:
            line = ("::warning::" if not VIEW and VIEW_MODE != "no-view" else "::notice::") + line.replace("%", "%25")
        print(line, flush=True)
        if require and not VIEW:
            # 只在探不过时记一条（探得过不记）：CI 上 auto 和 require 探得过时条数一样
            check(False, f"要求带视图（{'--view require' if VIEW_MODE == 'require' else '本机的 --ci'}），探针宿主探不过：{why}")

    # ============================================================ A. 没有宿主
    if "A" in ONLY:
        print("A. 没有宿主")
        data = fresh_data("A")
        root = sock_root("A")
        env = base_env(data, root)
        # 没给照片文件夹：打用法提示、退出 1（测试用的 --titled 也列上，和 LiveHost.swift 文件头、main.swift 注释一致）
        r = subprocess.run([BIN, "--live-host"], env=base_env(fresh_data("A-usage"), root), capture_output=True,
                           timeout=30 * SLACK, cwd=WORK, stdin=subprocess.DEVNULL)
        check(r.returncode == 1 and "[--no-view | --titled]" in r.stdout.decode(errors="replace"),
              f"--live-host 不给照片文件夹：用法提示里有 [--no-view | --titled]，退出 {r.returncode}")
        st, ms = status(env)
        check((st.get("live") or {}) == {"state": "not_running"} and st.get("gui_running") is False
              and st.get("next") == "请用户自己打开选片工具", f"没有锁文件：live={st.get('live')}（{ms:.0f} ms）")
        codes = all_tools(env, KEY)
        check(set(codes.values()) == {"app_not_running"}, f"15 个要 app 的工具都回 app_not_running：{set(codes.values())}")
        check(not os.path.exists(os.path.join(data, ".live.lock")) and not os.listdir(os.path.join(SOCKS, os.path.basename(root))),
              "--mcp 跑完：数据目录里没有 .live.lock，socket 根目录里什么都没有（--mcp 不建锁、不建目录、不 bind）")
        # 锁文件在、但没人拿着（app 退了）
        open(os.path.join(data, ".live.lock"), "w").write('{"role":"app","pid":1,"bridge":"on"}\n')
        st, _ = status(env)
        check((st.get("live") or {}).get("state") == "not_running", f"锁文件在但空着：not_running（{st.get('live')}）")
        # socket 路径太长：不 connect、只看锁，warning socket_path_too_long
        long_root = os.path.join(WORK, "x" * 40, "很长的-socket-根目录-" + "y" * 40)
        os.makedirs(long_root, mode=0o700)
        env_long = base_env(data, long_root)
        st, _ = status(env_long)
        warns = [w.get("code") for w in st.get("warnings", [])]
        check((st.get("live") or {}).get("state") == "not_running" and "socket_path_too_long" in warns,
              f"socket 路径太长（{len(long_root) + 22} 字节）：not_running + socket_path_too_long {warns}")
        h = Host("A-long", root=long_root)
        check(h.bridge == "unavailable" and h.reason == "socket_path_too_long" and not os.listdir(long_root),
              f"宿主拿太长的 socket 根目录：不开桥（bridge={h.bridge} reason={h.reason}），目录里没有 socket")
        st, _ = status(h.env())
        check((st.get("live") or {}).get("state") == "unreachable" and (st.get("live") or {}).get("reason") == "socket_path_too_long",
              f"这时 --mcp：锁是 app、桥开不了 → unreachable（{st.get('live')}）")
        h.term()
        # 相对路径的数据目录：不探测
        rel = os.path.relpath(data, WORK)
        st, _ = status(base_env(rel, root))
        warns = [w.get("code") for w in st.get("warnings", [])]
        check((st.get("live") or {}).get("state") == "unreachable" and "data_dir_not_absolute" in warns,
              f"相对路径的 LABELGUI_DATA_DIR：unreachable + data_dir_not_absolute {warns}")
        # 宿主自己的闸：没有 socket 根目录 / 相对的 → exit 2，什么都不建
        env_h = base_env(data, "relative/root", LABELGUI_LIVE_TEST_OUT=SNAPS)
        r = subprocess.run([BIN, "--live-host", PHOTO_DIR], env=env_h, capture_output=True, timeout=20, cwd=WORK)
        env_h.pop("LABELGUI_LIVE_SOCK_ROOT")
        r2 = subprocess.run([BIN, "--live-host", PHOTO_DIR], env=env_h, capture_output=True, timeout=20, cwd=WORK)
        check(r.returncode == 2 and r2.returncode == 2 and not os.path.exists(os.path.join(WORK, "relative")),
              f"--live-host 的 LABELGUI_LIVE_SOCK_ROOT 是相对路径 / 没设：exit {r.returncode} / {r2.returncode}")
        # 数据目录的闸在建目录、注册字体之前（审查发现：以前先建目录、写 fonts/ 再查）：LABELGUI_DATA_DIR 指到「真实数据目录」
        # → exit 2，目录里一个文件都不多。「真实数据目录」用 CFFIXED_USER_HOME 换成假的家目录下那个（S2 实测它改得了
        # Application Support 的位置）：判断哪天失灵，写的也是假的家目录，碰不到用户。--app-ui 同一道闸。
        fake_home = os.path.join(WORK, "假的家目录")
        fake_real = os.path.join(fake_home, "Library", "Application Support", "选片工具")
        os.makedirs(fake_real)
        rcs_f = []
        for argv in (["--live-host", PHOTO_DIR], ["--app-ui", PHOTO_DIR, os.path.join(WORK, "never.png")]):
            env_f = base_env(fake_real, root, LABELGUI_LIVE_TEST_OUT=SNAPS, CFFIXED_USER_HOME=fake_home)
            try:
                r = subprocess.run([BIN, *argv], env=env_f, capture_output=True, timeout=30, cwd=WORK)
                rcs_f.append((r.returncode, "真实数据目录" in r.stdout.decode(errors="replace")))
            except subprocess.TimeoutExpired:
                rcs_f.append(("timeout", False))
        check(rcs_f == [(2, True), (2, True)] and not os.listdir(fake_real) and not os.path.exists(os.path.join(WORK, "never.png")),
              f"--live-host / --app-ui 的 LABELGUI_DATA_DIR 是（假的家目录下的）真实数据目录：建目录、写字体之前就 exit 2 {rcs_f}，"
              f"目录里没多东西 {os.listdir(fake_real)}")
        # --live-host 拒绝真实的 SockDir（各种写法）。在 sandbox-exec 里跑：往真实 SockDir 写任何东西（建目录、bind）就 SIGKILL，
        # 所以哪天判断失灵，宿主是被杀掉，而不是在用户的 xuanpian-live 里建出东西。对照：同一条规则禁掉一个测试目录，
        # 拿它当 socket 根目录的宿主一建目录就被杀（证明规则抓得到宿主开桥用的那几个系统调用）。规则比的是内核解析完的路径，
        # /private/var/… 和 firmlink 的 /System/Volumes/Data/… 两种写法都禁（S2 实测）。只禁写：判断时 realpath 要读它。
        sandbox = "/usr/bin/sandbox-exec"
        if NO_KILL:
            skip("app 里的二进制不跑 sandbox（规则抓到就 SIGKILL）：--live-host 拒绝真实 SockDir 这一条看裸二进制那一遍")
        elif not os.access(sandbox, os.X_OK):
            skip("找不到 sandbox-exec：--live-host 拒绝真实 SockDir 这一条只有 --mcp-selftest 的纯函数证据")
        else:
            real_rp = os.path.join(os.path.realpath(TEMP), "xuanpian-live")
            ctl = os.path.join(os.path.realpath(SOCKS), "ctl-never")
            deny = [real_rp, "/System/Volumes/Data" + real_rp, ctl]
            sb = lambda p_: '"' + p_.replace("\\", "\\\\").replace('"', '\\"') + '"'
            profile = ("(version 1)(allow default)(deny file-write* " + " ".join(f"(subpath {sb(d)})" for d in deny)
                       + " (with send-signal SIGKILL))")
            spellings = [REAL_SOCK, REAL_SOCK + "/", "/private" + REAL_SOCK, REAL_SOCK + "/sub", REAL_SOCK.upper(),
                         REAL_SOCK + "/../xuanpian-live"]
            rcs = []
            for sp in spellings:
                d_ = fresh_data("A-real")
                r = subprocess.run([sandbox, "-p", profile, BIN, "--live-host", PHOTO_DIR],
                                   env=base_env(d_, sp, LABELGUI_LIVE_TEST_OUT=SNAPS), capture_output=True, timeout=30, cwd=WORK)
                rcs.append((r.returncode, "真实的 socket 目录" in r.stdout.decode(errors="replace"),
                            os.path.exists(os.path.join(d_, ".live.lock"))))
            d_ = fresh_data("A-ctl")
            r = subprocess.run([sandbox, "-p", profile, BIN, "--live-host", PHOTO_DIR],
                               env=base_env(d_, os.path.join(LINK, "ctl-never"), LABELGUI_LIVE_TEST_OUT=SNAPS),
                               capture_output=True, timeout=30, cwd=WORK)
            check(r.returncode == -signal.SIGKILL and not os.path.exists(ctl),
                  f"（对照）sandbox 规则抓得到宿主开桥：拿被禁的测试目录当 socket 根目录的宿主被杀（{r.returncode}）")
            check(all(x == (2, True, False) for x in rcs) and real_sock_state() == real_sock_before,
                  f"--live-host 的 socket 根目录写成真实 SockDir 的 {len(spellings)} 种写法（结尾斜杠、/private、子目录、大写、..）："
                  f"都在 AppModel.make 之前 exit 2、没被杀、没拿锁，真实 SockDir 没变 {rcs}")

    # ============================================================ B. 起宿主
    if "B" in ONLY:
        print("B. 起宿主")
        h = Host("B")
        env = h.env()
        check(h.bridge == "on" and h.reason == "-", f"就绪 {h.ready_ms:.0f} ms：bridge={h.bridge}")
        st, ms = status(env)
        live = st.get("live") or {}
        if (live.get("app") or {}).get("pid") != h.pid:
            print(f"app_status 连到的 app pid {(live.get('app') or {}).get('pid')} 不是脚本起的宿主 {h.pid}：不跑")
            sys.exit(2)
        open_ = live.get("open_session") or {}
        check(live.get("state") == "live" and st.get("gui_running") is True and st.get("writes", {}).get("live") is True
              and st.get("next") == "cull_session_overview", f"app_status：live（{ms:.0f} ms）")
        check(live.get("socket") == h.sock, f"ready 行的 S 和 app_status.live.socket 逐字节相同（{h.sock}）")
        check(live.get("exact_build_match") is True and live.get("proto") == 1 and live.get("bridge") == "on"
              and live.get("capabilities") == ALL_CAPS and live.get("window_state") == "visible"
              and live.get("windows") == 1 and live.get("tab") == "batch" and live.get("analysis") == {"running": False, "progress_text": ""},
              f"live 对象的字段：{ {k: live.get(k) for k in ('exact_build_match', 'proto', 'capabilities', 'window_state', 'tab', 'analysis')} }")
        check(open_.get("session") == KEY and open_.get("folder") == PHOTO_DIR and open_.get("photo_count") == 21,
              f"open_session 是宿主打开的那一场：{open_}")
        pinned = state(h).get("settings")
        check(pinned == {"rejectBurstDuplicates": False, "minKeepersPerChapter": 0, "sortOrder": "拍摄时间"},
              f"三个 batch.* 设置钉成 false / 0 / 拍摄时间（argument domain，不落盘）：{pinned}")
        r = Raw(h)
        hr = r.hello_reply.get("result") or {}
        r.close()
        check(hr.get("data_dir_id") == h.data_dir_id and hr.get("peer", {}).get("uid") == os.getuid()
              and hr.get("peer", {}).get("pid") == os.getpid() and hr.get("ready") is True and hr.get("proto_min") == 1
              and hr.get("proto_max") == 1 and isinstance(hr.get("main_beat_ms"), int)
              and {"name", "version", "build", "uuid", "pid", "exe"} <= set(hr.get("app", {})),
              f"hello 字段齐：data_dir_id、peer（uid {os.getuid()}、pid 是脚本）、ready、proto 区间、app、main_beat_ms")
        # 路由：collage_get_state 转给 app；session 填 key / 路径 / 别的；6 个读工具转给 app（9 个写在 G 组）
        _, cs, ms = mcp_call(env, "collage_get_state")
        check((cs or {}).get("source") == "app" and cs.get("session") == KEY and cs.get("window_visible") is True
              and cs.get("pending_writes") == 0 and "undo" in cs and "busy" in cs,
              f"collage_get_state 不带 session：app 当前那一场的工程摘要（{ms:.0f} ms）")
        _, cs2, _ = mcp_call(env, "collage_get_state", {"session": PHOTO_DIR + "/"})
        check((cs2 or {}).get("session") == KEY, "collage_get_state 填照片文件夹路径（带结尾斜杠）也认")
        _, cs3, _ = mcp_call(env, "collage_get_state", {"session": "0123456789abcdef"})
        check(err_code(cs3) == "session_not_open" and (cs3["error"].get("data") or {}).get("open_session", {}).get("session") == KEY,
              f"别的场次 → session_not_open，data.open_session 对（{err_code(cs3)}）")
        reads = {t: err_code(mcp_call(env, t, minimal_args(t, KEY))[1]) for t in APP_TOOLS[:6]}
        # --ci 的 fixture 没有分析预览、照片文件夹也不存在：预览回 preview_missing（正是 §10.3 那一条），其余照常
        want_prev = "preview_missing" if CI else None
        check(reads.pop("cull_preview_photos") == want_prev and set(reads.values()) == {None},
              f"6 个读工具带最小参数都照常回（--ci 的预览是 preview_missing）{reads}")
        _, ls, _ = mcp_call(env, "cull_list_sessions")
        rows = (ls or {}).get("sessions") or []
        check(rows and all("open_in_app" in x for x in rows) and [x["open_in_app"] for x in rows if x["session"] == KEY] == [True],
              f"cull_list_sessions：live 时每行都有 open_in_app，宿主那一场是 true")

        # T1 写（test.write 走写 FIFO + op_id）、读回来
        r = Raw(h)
        w1 = r.call("test.write", {"key": "collage.template", "value": "magazine-03"}, op_id=str(uuid.uuid4()))
        w0 = r.call("test.write", {"key": "x", "value": "y"})
        st1 = r.call("test.state")["result"]
        r.close()
        check(w1.get("result", {}).get("applied") == 1 and st1["test_values"].get("collage.template") == "magazine-03"
              and err_code(w0) == "invalid_argument", "T1 握手 + 写 + 读回来；写请求不带 op_id → invalid_argument")
        # T2 2 MB × 5
        test_call(h, "test.reset_stats")
        oks = []
        t = time.monotonic()
        for _ in range(5):
            m = test_call(h, "test.blob", {"bytes": 2_000_000})["result"]
            oks.append(len(m["data"]) == 2_000_000 and hashlib.sha256(m["data"].encode()).hexdigest() == m["sha256"])
        per = (time.monotonic() - t) * 1000 / 5
        gap = state(h)["max_main_gap_ms"]
        check(all(oks), f"T2 2 MB 回复 × 5，SHA-256 都对（每次 {per:.1f} ms，主线程最大间隔 {gap} ms）")
        # T3 4 个客户端并发：每个流水线发 100 个写 + 3 个 2 MB 读
        test_call(h, "test.reset_stats")
        before = state(h)["test_applied"]
        errs, lat = [], []

        def worker(k):
            try:
                c = Raw(h, timeout=30)
                t0 = time.monotonic()
                ids = set()
                for i in range(100):
                    ids.add(c.req("test.write", {"key": f"c{k}.{i}", "value": str(i)}, op_id=f"t3-{k}-{i}"))
                    if i % 40 == 0:
                        ids.add(c.req("test.blob", {"bytes": 2_000_000}))
                while ids:
                    m = c.recv()
                    if "error" in m:
                        errs.append((k, m))
                    elif "data" in m["result"] and hashlib.sha256(m["result"]["data"].encode()).hexdigest() != m["result"]["sha256"]:
                        errs.append((k, "sha"))
                    ids.discard(m["id"])
                lat.append(round((time.monotonic() - t0) * 1000))
                c.close()
            except Exception as e:
                errs.append((k, repr(e)))

        th = [threading.Thread(target=worker, args=(k,)) for k in range(4)]
        [x.start() for x in th]
        [x.join() for x in th]
        st3 = state(h)
        check(not errs and st3["test_applied"] - before == 400,
              f"T3 4 个客户端并发（400 写 + 12 × 2 MB）：0 错误、正好 +400（每个 {lat} ms，主线程最大间隔 {st3['max_main_gap_ms']} ms）{errs[:2]}")
        # T3b 主线程被占 1.5 s：hello、ping 照样秒回，主线程上的读排队；app_status 也照样秒回
        r = Raw(h)
        r.req("test.block_main", {"ms": 1500})
        time.sleep(0.1)
        t = time.monotonic()
        r2 = Raw(h)
        hello_ms = (time.monotonic() - t) * 1000
        t = time.monotonic()
        r2.call("ping")
        ping_ms = (time.monotonic() - t) * 1000
        st, st_ms = status(env)
        t = time.monotonic()
        r2.call("collage.state")
        get_ms = (time.monotonic() - t) * 1000
        r.recv()
        r.close()
        r2.close()
        check(hello_ms < 50 * SLACK and ping_ms < 50 * SLACK and get_ms > 900 and (st.get("live") or {}).get("state") == "live"
              and st_ms < 900, f"T3b 主线程忙：connect+hello {hello_ms:.1f} ms、ping {ping_ms:.1f} ms、--mcp app_status {st_ms:.0f} ms"
              f"（live），collage.state 排了 {get_ms:.0f} ms")
        # T4 客户端半路断开：慢写开始以后就关；8 MB 回复只读 10 KB 就关。
        # STEP 3a 起读到 EOF 就置 clientGone（§10.2）：还没轮到的请求不执行 —— 包括在写 FIFO 里排在别的写后面的
        # （那一半见 F 组第 35 条）；已经开始的照常落地。所以这里一个一个来：等它开始（FIFO 空着，100 ms 足够）再关，
        # 等它落地再发下一个，断言的是「已经开始的写照样生效」。
        for i in range(3):
            c = Raw(h)
            c.req("test.write", {"key": f"t4.{i}", "value": "v", "async_ms": 300}, op_id=f"t4-{i}")
            time.sleep(0.1)
            c.close()
            time.sleep(0.3)
        for _ in range(3):
            c = Raw(h)
            c.req("test.blob", {"bytes": 8_000_000})
            c.s.recv(10_000)
            c.close()
        time.sleep(1.0)
        st4 = state(h)
        check(h.alive() and h.log().count("write failed") >= 3 and all(st4["test_values"].get(f"t4.{i}") == "v" for i in range(3)),
              f"T4 客户端半路断开：宿主活着，write failed {h.log().count('write failed')} 次；断开前发出的写照样生效")
        # T10 截止时间：主线程被占时，过期的写不执行
        base = state(h)["test_applied"]
        r = Raw(h)
        r.req("test.block_main", {"ms": 1500})
        time.sleep(0.1)
        r2 = Raw(h)
        late = r2.req("test.write", {"key": "late", "value": "x"}, deadline=300, op_id="t10-late")
        r3 = Raw(h)
        ontime = r3.call("test.write", {"key": "ontime", "value": "y"}, deadline=5000, op_id="t10-ontime")
        m_late = r2.recv()
        r.recv()
        [x.close() for x in (r, r2, r3)]
        st10 = state(h)
        check(err_code(m_late) == "expired" and (m_late["error"].get("data") or {}).get("executed") is False
              and "late" not in st10["test_values"] and st10["test_values"].get("ontime") == "y" and st10["test_applied"] - base == 1,
              f"T10 过期的写回 expired、没执行；同时发的 5 s 截止的那个照常执行（{m_late.get('error', {}).get('message')}）")
        # T11 op_id 重放；同一个 op_id 并发两次也只做一次
        a = test_call(h, "test.write", {"key": "verdict:IMG_2", "value": "reject"}, op_id="op-123")
        b = test_call(h, "test.write", {"key": "verdict:IMG_2", "value": "reject"}, op_id="op-123")
        check(a.get("result", {}).get("applied") == b.get("result", {}).get("applied") and b["result"].get("replayed") is True
              and "replayed" not in a["result"], "T11 同一个 op_id 发两次：第二次 replayed:true，只做了一次")
        base = state(h)["test_applied"]
        c1, c2 = Raw(h), Raw(h)
        c1.req("test.write", {"key": "dup", "value": "1", "async_ms": 400}, op_id="op-dup")
        time.sleep(0.05)
        c2.req("test.write", {"key": "dup", "value": "1", "async_ms": 400}, op_id="op-dup")
        m1, m2 = c1.recv(), c2.recv()
        c1.close()
        c2.close()
        check(m1["result"]["applied"] == m2["result"]["applied"] and m2["result"].get("replayed") is True
              and state(h)["test_applied"] - base == 1, "同一个 op_id 还在执行时又来一个：等它做完、回同一份结果（replayed），只做一次")
        # 写 FIFO：上一个写（异步落地）没结束，下一个不开始
        c1, c2 = Raw(h), Raw(h)
        t = time.monotonic()
        c1.req("test.write", {"key": "fifo1", "value": "a", "async_ms": 600}, op_id="fifo-1")
        time.sleep(0.05)
        c2.req("test.write", {"key": "fifo2", "value": "b"}, op_id="fifo-2")
        f2 = c2.recv()
        f2_ms = (time.monotonic() - t) * 1000
        f1 = c1.recv()
        c1.close()
        c2.close()
        check(f1["result"]["applied"] + 1 == f2["result"]["applied"] and f2_ms > 550,
              f"写 FIFO：第二个写等第一个异步落地（{f2_ms:.0f} ms）才开始")
        # T13 协议防御
        c = Raw(h, hello=False)
        no_hello = c.call("collage.state")
        c.close()
        c = Raw(h)

        def flood(s=c.s):
            try:
                s.sendall(b"x" * (2 << 20))
            except OSError:
                pass

        flood = threading.Thread(target=flood)
        try:
            flood.start()
            big = c.recv()
        except Exception as e:
            big = {"exc": repr(e)}
        flood.join(timeout=5)
        c.close()
        c = Raw(h)
        c.s.sendall(b"{not json\n")
        bad = c.recv()
        after_bad = c.call("ping")
        unknown = c.call("no.such.method")
        c.close()
        check(err_code(no_hello) == "hello_required" and err_code(big) == "request_too_large" and err_code(bad) == "parse_error"
              and after_bad.get("result") == {"pong": True} and err_code(unknown) == "unknown_method" and h.alive(),
              f"T13 不握手 → hello_required；2 MiB 一行 → request_too_large；坏 JSON → parse_error 之后连接照常；没有的方法 → unknown_method")
        # T17 时延：新连接 + hello + collage.state
        lat = []
        for _ in range(300):
            t = time.monotonic()
            c = Raw(h)
            c.call("collage.state")
            c.close()
            lat.append((time.monotonic() - t) * 1000)
        lat.sort()
        check(True, f"T17 时延（300 次新连接 + hello + collage.state）：p50 {lat[150]:.2f} ms、p95 {lat[285]:.2f} ms、max {lat[-1]:.2f} ms")
        # 同时在线最多 16 个：第 17 个回 too_many_connections；占满超过 1 s → --mcp 判 unresponsive（暂时的），放掉就 live
        held = [Raw(h) for _ in range(16)]
        time.sleep(0.1)
        c = socket.socket(socket.AF_UNIX)
        c.settimeout(5)
        c.connect(h.sock)
        extra = json.loads(c.recv(4096).split(b"\n")[0])
        c.close()
        st_full, ms_full = status(env)
        [x.close() for x in held]
        time.sleep(0.3)
        st_after, _ = status(env)
        check(err_code(extra) == "too_many_connections" and (st_full.get("live") or {}).get("state") == "unresponsive"
              and (st_full.get("live") or {}).get("reason") == "too_many_connections" and ms_full >= 900
              and (st_after.get("live") or {}).get("state") == "live",
              f"16 个连接占满：第 17 个 too_many_connections；--mcp 每 50 ms 重连 {ms_full:.0f} ms 后 unresponsive；放掉以后 live")
        # 积压满了（§9.1 第二轮）：accept 停 150 ms，70 个裸连接把积压塞满（100 ms 时全关）→ ECONNREFUSED → 每 20 ms 重连 → live
        test_call(h, "test.pause_accept", {"ms": 150})
        conns, refused = [], 0
        for _ in range(70):
            s_ = socket.socket(socket.AF_UNIX)
            s_.setblocking(False)
            try:
                s_.connect(h.sock)
                conns.append(s_)
            except (BlockingIOError, ConnectionRefusedError, OSError) as e:
                if getattr(e, "errno", None) == errno.ECONNREFUSED:
                    refused += 1
                s_.close()
        threading.Timer(0.1, lambda: [x.close() for x in conns]).start()
        st_b, ms_b = status(env)
        time.sleep(0.5)
        test_call(h, "test.pause_accept", {"ms": 2500})
        conns2 = []
        for _ in range(70):
            s_ = socket.socket(socket.AF_UNIX)
            s_.setblocking(False)
            try:
                s_.connect(h.sock)
                conns2.append(s_)
            except OSError:
                s_.close()
        st_c, ms_c = status(env)
        _, cs_c, _ = mcp_call(env, "collage_get_state")
        [x.close() for x in conns2]
        time.sleep(2.5)
        check(refused > 0 and (st_b.get("live") or {}).get("state") == "live",
              f"积压满了（{refused} 个裸连接被拒，macOS 不回 EAGAIN）：accept 停 150 ms → --mcp 重连以后 live（{ms_b:.0f} ms）")
        check((st_c.get("live") or {}).get("state") == "unreachable" and err_code(cs_c) == "app_unreachable",
              f"accept 停 2.5 s：300 ms 预算用完 → unreachable、collage_get_state 回 app_unreachable，绝不是 not_running（{ms_c:.0f} ms）")
        # T9b 连接被内核收下（积压没满）、一直没人 accept / 回 hello：1 s 后 unresponsive，不是 not_running
        test_call(h, "test.pause_accept", {"ms": 1800})
        st_m, ms_m = status(env)
        time.sleep(1.0)
        check((st_m.get("live") or {}).get("state") == "unresponsive" and (st_m.get("live") or {}).get("reason") == "hello_timeout"
              and 950 < ms_m < 1800 * SLACK, f"T9b 连接进了积压、没人回：hello 超时 → unresponsive（{ms_m:.0f} ms）")
        # 窗口状态（§9.5.6）：只改报出去的值
        test_call(h, "test.set_window_state", {"state": "minimized"})
        st_w, _ = status(env)
        _, cs_w, _ = mcp_call(env, "collage_get_state")
        test_call(h, "test.set_window_state", {"state": "visible"})
        check((st_w.get("live") or {}).get("window_state") == "minimized" and (cs_w or {}).get("window_visible") is False,
              "test.set_window_state minimized → app_status.live.window_state、collage_get_state.window_visible 跟着变")
        # 用户在侧栏切场次：open_session 跟着变；旧场次 → session_not_open
        sw = test_call(h, "test.switch_session", {"photo_dir": EMPTY_PHOTOS}).get("result") or {}
        st_s, _ = status(env)
        _, cs_s, _ = mcp_call(env, "collage_get_state", {"session": KEY})
        _, cs_e, _ = mcp_call(env, "collage_get_state", {"session": EMPTY_PHOTOS})
        o2 = (st_s.get("live") or {}).get("open_session") or {}
        check(o2.get("folder", "").endswith("/空文件夹") and o2.get("photo_count") == 0 and o2.get("session") == sw.get("session") != KEY
              and err_code(cs_s) == "session_not_open" and (cs_e or {}).get("session") == sw.get("session"),
              f"用户切到空文件夹：open_session 跟着变（{o2.get('session')}），旧场次 → session_not_open，新场次的路径认得出")
        test_call(h, "test.switch_session", {"photo_dir": PHOTO_DIR})
        # 桥关掉（§9.8.2 第 17 条）：期间 bridge_off，锁照常持有、锁文件写 bridge:"off"；3 s 后自动恢复
        test_call(h, "test.set_bridge", {"enabled": False, "for_ms": 3000})
        st_off, _ = status(env)
        _, cs_off, _ = mcp_call(env, "collage_get_state")
        _, rd_off, _ = mcp_call(env, "cull_list_groups", {"session": KEY, "kind": "scene"})
        _, wr_off, _ = mcp_call(env, "collage_set_text", {"session": KEY, "title": "桥关着"})
        lock_line = json.loads(open(os.path.join(h.data, ".live.lock")).read().splitlines()[0])
        sock_gone = not os.path.exists(h.sock)
        time.sleep(3.5)
        st_on, _ = status(env)
        check((st_off.get("live") or {}).get("state") == "bridge_off" and err_code(cs_off) == "bridge_off" and err_code(rd_off) == "bridge_off"
              and err_code(wr_off) == "bridge_off"
              and lock_line.get("bridge") == "off" and sock_gone and (st_on.get("live") or {}).get("state") == "live",
              "桥关着：bridge_off（读写都是），socket 删了、锁文件写 bridge:off；3 s 后自己开回来 → live")
        # socket 被删（R6 T15）：立刻 unreachable；自检（500 ms）以后恢复
        just_after_selfcheck(h)
        t_un = time.monotonic()
        os.unlink(h.sock)
        st_u, _ = status(env)
        _, cs_u, _ = mcp_call(env, "collage_get_state")
        _, rd_u, _ = mcp_call(env, "cull_session_overview", {"session": KEY})
        _, wr_u, _ = mcp_call(env, "cull_set_verdicts", {"session": KEY, "ids": ["DSCF7208"], "verdict": "pick"})
        probe_ms = (time.monotonic() - t_un) * 1000
        time.sleep(1.2)
        st_h, _ = status(env)
        check((st_u.get("live") or {}).get("state") == "unreachable" and err_code(cs_u) == "app_unreachable" and err_code(rd_u) == "app_unreachable"
              and err_code(wr_u) == "app_unreachable"
              and (st_h.get("live") or {}).get("state") == "live" and "重新 bind 好了" in h.log(),
              f"T15 socket 被删：立刻 unreachable（锁还在，不当成没开；两次探测共 {probe_ms:.0f} ms，在下一次自检之前），1.2 s 内自愈 → live")
        # socket 目录整个被删：自愈时按 0700 重建
        shutil.rmtree(os.path.join(SOCKS, os.path.basename(h.root)))
        time.sleep(1.2)
        st_d, _ = status(env)
        mode = oct(os.stat(os.path.join(SOCKS, os.path.basename(h.root))).st_mode & 0o777) if os.path.isdir(h.root) else None
        check((st_d.get("live") or {}).get("state") == "live" and mode == "0o700", f"socket 目录整个被删：自愈时重建（{mode}）、live")
        # 锁文件被删：10 s 自检（测试 500 ms）重新建、重新拿；app_status 照样 live
        os.unlink(os.path.join(h.data, ".live.lock"))
        time.sleep(1.2)
        st_l, _ = status(env)
        relock = os.path.exists(os.path.join(h.data, ".live.lock"))
        line = json.loads(open(os.path.join(h.data, ".live.lock")).read().splitlines()[0]) if relock else {}
        check(relock and line.get("pid") == h.pid and state(h)["counters"].get("lock_reacquired", 0) >= 1
              and (st_l.get("live") or {}).get("state") == "live", "锁文件被删：自检重新建好、重新拿到（那一行写回去了），照样 live")
        # 回复写完才关 fd（审查实测的竞态）：一个连接上连发 test.blob（300 KB）+ collage.state，马上 SHUT_WR、接收缓冲调小、
        # 晚 150 ms 才读；同时 6 个线程不停地连 + hello。以前在途计数在主线程上减，读线程退出时排进去的 maybeClose 可能抢在
        # 回复前面关 fd：回复写进关掉的 fd（write failed EBADF，丢了），或者写进复用了这个 fd 号的别人的连接（别的客户端
        # hello 读到的第一行不是 id 0）。20 轮：两条回复都要按顺序收到，宿主日志里没有新的 write failed，别人没收到串来的行。
        wf0 = h.log().count("write failed")
        stray, stop_h = [], threading.Event()

        def hammer():
            while not stop_h.is_set():
                try:
                    x = Raw(h, timeout=3, hello=False)
                    first = x.hello()
                    if first.get("id") != 0:
                        stray.append(first)
                    x.close()
                except (OSError, EOFError, ValueError):
                    pass

        ths = [threading.Thread(target=hammer, daemon=True) for _ in range(6)]
        [t.start() for t in ths]
        both = 0
        for _ in range(20):
            x = Raw(h, timeout=30)
            x.s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            x.send({"id": 11, "method": "test.blob", "params": {"bytes": 300_000}})
            x.send({"id": 12, "method": "collage.state"})
            # STEP 3a：读到 EOF 就当客户端走了（clientGone，§10.2），还没轮到的请求不执行。等两个都开始了再半关，
            # 300 KB 的回复写到一半时读线程退出，这条竞态才测得到
            time.sleep(0.05)
            x.s.shutdown(socket.SHUT_WR)
            time.sleep(0.15)
            ids = []
            try:
                while True:
                    f_ = x.recv()
                    # 两条都要是结果（不是 client_gone 之类的错误）：300 KB 的回复真的在和读线程退出赛跑
                    ids.append(f_.get("id") if "result" in f_ else ("error", f_.get("id")))
            except (EOFError, OSError):
                pass
            both += ids == [11, 12]
            x.close()
        stop_h.set()
        [t.join(timeout=10) for t in ths]
        wf1 = h.log().count("write failed")
        check(both == 20 and wf1 == wf0 and not stray,
              f"连发两条马上半关、慢慢读（旁边 6 个线程不停 hello）：20 轮里 {both} 轮两条回复都收到，新的 write failed {wf1 - wf0} 条，"
              f"串到别的连接 {len(stray)} 行")
        # 开桥失败以后自检照样跑（审查发现：以前自检定时器只在第一次开桥成功时才起）。SockDir 对组可写 → 不开桥
        # （sock_dir_unsafe）；这时锁文件被删 → 下一轮自检重新建好；SockDir 改回 0700 → 下一轮自检开桥 → live
        root_u = sock_root("B-unsafe")
        real_u = os.path.join(SOCKS, os.path.basename(root_u))
        os.chmod(real_u, 0o775)
        hu = Host("B-unsafe", root=root_u)
        env_u = hu.env()
        st_u1, _ = status(env_u)
        os.unlink(os.path.join(hu.data, ".live.lock"))
        time.sleep(1.2)
        relock_u = os.path.exists(os.path.join(hu.data, ".live.lock"))
        line_u = json.loads(open(os.path.join(hu.data, ".live.lock")).read().splitlines()[0]) if relock_u else {}
        os.chmod(real_u, 0o700)
        deadline = time.monotonic() + 2 * SLACK
        while time.monotonic() < deadline and not os.path.exists(hu.sock):
            time.sleep(0.05)
        st_u2, _ = status(env_u)
        check(hu.bridge == "unavailable" and hu.reason == "sock_dir_unsafe"
              and (st_u1.get("live") or {}).get("state") == "unreachable" and relock_u and line_u.get("pid") == hu.pid
              and line_u.get("bridge") == "unavailable" and (st_u2.get("live") or {}).get("state") == "live",
              f"SockDir 0775：不开桥（{hu.reason}，--mcp 看到 {(st_u1.get('live') or {}).get('state')}）；锁文件被删 → 自检重建"
              f"（{line_u.get('bridge')}）；改回 0700 → 自检开桥 → {(st_u2.get('live') or {}).get('state')}")
        hu.term()
        # 取消（§10.2）：主线程卡着时发 collage_get_state 再取消 → 这个 id 不再有任何消息，--mcp 照常答别的
        m = Mcp(env)
        m.initialize()
        r = Raw(h)
        r.req("test.block_main", {"ms": 3000})
        time.sleep(0.1)
        m.call("cx", "collage_get_state")
        time.sleep(0.3)
        m.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "cx", "reason": "test"}})
        pong = m.tool("after-cancel", "collage_list_templates", {"include": ["kits"]}, timeout=2)
        late = m.wait_id("cx", timeout=4)
        r.recv()
        r.close()
        st_m = m.tool("st", "app_status")
        last_client = state(h).get("last_client")
        m.close()
        check(late is None and pong is not None and (st_m or {}).get("live", {}).get("state") == "live",
              "取消：主线程卡着时取消一个 collage_get_state → 4 s 内这个 id 没有任何消息，别的调用照常")
        check(last_client == "claude-code 2.1.303", f"hello 里报了 MCP 客户端（initialize 的 clientInfo）：{last_client!r}")
        # 截止时间（§10.2）：主线程卡得比 deadline + 1 s 还久，而 hello 还能秒回 → deadline_exceeded（不重发）
        r = Raw(h)
        r.req("test.block_main", {"ms": 12_500})
        time.sleep(0.1)
        _, dl, dl_ms = mcp_call(env, "collage_get_state", timeout=40)
        r.recv()
        r.close()
        check(err_code(dl) == "deadline_exceeded" and 10_500 < dl_ms < 13_000 * SLACK,
              f"主线程卡 12.5 s：collage_get_state 等 deadline 10 s + 1 s 后回 deadline_exceeded（{dl_ms:.0f} ms）")
        # 没给 deadline_seconds 也受 LABELGUI_MCP_DEADLINE_SEC 管（和 tools/list 写的 default 一样）：上限 5 s 时
        # cull_preview_photos 的默认 30 s 截成 5 s，主线程卡 12.5 s → 5 + 1 s 就回 deadline_exceeded（截之前要等到宿主回过神来，
        # 照常回图、不是 deadline_exceeded）。上界不乘 SLACK、比 12.5 s 小：时间上也分得出「6 s 回」和「卡完才回」
        r = Raw(h)
        r.req("test.block_main", {"ms": 12_500})
        time.sleep(0.1)
        _, dl5, dl5_ms = mcp_call(h.env(LABELGUI_MCP_DEADLINE_SEC="5"), "cull_preview_photos",
                                  {"session": KEY, "ids": ["DSCF7208"]}, timeout=40)
        r.recv()
        r.close()
        check(err_code(dl5) == "deadline_exceeded" and 5_500 < dl5_ms < 12_000,
              f"LABELGUI_MCP_DEADLINE_SEC=5、没给 deadline_seconds：cull_preview_photos 5 + 1 s 后回 deadline_exceeded"
              f"（{err_code(dl5)}，{dl5_ms:.0f} ms）")
        # LABELGUI_MCP_LIVE=0（§9.8.2 第 28 条）：tools/list 3 个、disabled、一次都不连
        n0 = state(h)["hello_count"]
        m = Mcp(h.env(LABELGUI_MCP_LIVE="0"))
        m.initialize()
        m.send({"jsonrpc": "2.0", "id": "tl", "method": "tools/list"})
        tl = m.wait_id("tl")
        st0 = m.tool("s0", "app_status")
        m.tool("s1", "cull_list_sessions")
        m.call("s2", "cull_set_verdicts", {"session": KEY, "ids": ["DSCF7208"], "verdict": "pick"})
        w0 = m.wait_id("s2")
        m.close()
        n1 = state(h)["hello_count"] - 1   # 减去刚才这次 state 自己的 hello
        w0_err = (w0 or {}).get("error") or ((w0 or {}).get("result") or {}).get("isError")
        check(len(tl["result"]["tools"]) == 3 and (st0 or {}).get("live", {}).get("state") == "disabled" and n1 == n0 and w0_err,
              f"LABELGUI_MCP_LIVE=0：tools/list 3 个、live.state=disabled、写工具没注册（调了回错误），宿主的 hello_count 没变（{n0} → {n1}）")
        # 不进程序坞（§10.7 第 6、39 条）；宿主从不变成前台 / key
        m = Mcp(env)
        m.initialize()
        m.tool("d", "app_status")
        apps = subprocess.run(["lsappinfo", "list"], capture_output=True, text=True).stdout
        check(re.search(rf"\bpid = {m.pid}\b", apps) is None, f"lsappinfo list 里没有 --mcp（{m.pid}）：没注册成 app")
        # 宿主建了 NSApplication：.prohibited 也会向 LaunchServices 登记，lsappinfo 里是 type="BackgroundOnly"（没有程序坞图标、
        # 没有菜单栏、不能变成前台）。§10.7 第 39 条写的「lsappinfo 里没有它」做不到（--app-ui 一样），这里断言它只是后台的。
        line = re.search(rf"\bpid = {h.pid}\b.*", apps)
        check(line is None or 'type="BackgroundOnly"' in line.group(0),
              f"--live-host（{h.pid}，.prohibited）在 lsappinfo 里只是 BackgroundOnly：{line.group(0)[:80] if line else '不在'}")
        m.close()
        ns = state(h)["nsapp"]
        check(ns == {"active": False, "key_window": False, "main_window": False, "activation_policy": 2,
                     "visible_windows": 0, "host_window_visible": False, "host_window_key": False},
              f"宿主从不变成前台、没有 key / main 窗口、离屏窗口不可见、激活策略是 .prohibited：{ns}")
        # CLOEXEC（§9.2.4）：从外面看宿主的每个 fd —— 锁文件、所有 unix socket（监听的、连着的）都带 close-on-exec
        a_fd = os.open("/dev/null", os.O_RDONLY)
        os.set_inheritable(a_fd, True)
        b_fd = os.open("/dev/null", os.O_RDONLY)
        mine = {fd: st_ for fd, _, st_, _ in proc_fds(os.getpid())}
        calib = mine.get(a_fd) is not None and not (mine[a_fd] & PROC_FP_CLEXEC) and (mine.get(b_fd, 0) & PROC_FP_CLEXEC)
        os.close(a_fd)
        os.close(b_fd)
        keep = Raw(h)
        fds = proc_fds(h.pid)
        lock_fds = [x for x in fds if x[3] and x[3].endswith("/.live.lock")]
        socks = [x for x in fds if x[1] == PROX_FDTYPE_SOCKET]
        keep.close()
        self_report = state(h)["fds"]
        check(bool(calib), "（对照）proc_pidfdinfo 的 PROC_FP_CLEXEC 位：本脚本一个继承的 fd 没有、一个默认的有")
        check(len(lock_fds) == 1 and all(x[2] & PROC_FP_CLEXEC for x in lock_fds) and len(socks) >= 2
              and all(x[2] is not None and x[2] & PROC_FP_CLEXEC for x in socks),
              f"宿主的锁 fd（{[x[0] for x in lock_fds]}）和 {len(socks)} 个 socket fd 都带 CLOEXEC（从外面看）")
        check(all(v.get("cloexec") for v in self_report.values()) and {"lock", "listen", "wake"} <= set(self_report),
              f"宿主自己 F_GETFD 报的也是：{self_report}")
        h.term()
        check(not os.path.exists(h.sock), "SIGTERM：宿主删掉了自己的 socket")

    # ============================================================ C. 杀掉 / 重起 / 抢锁
    if "C" in ONLY:
        print("C. 杀掉 / 重起 / 抢锁")
        h = Host("C")
        env = h.env()
        # T5 请求进行中宿主被 kill -9：裸连接立刻读到 EOF；--mcp 的读重探一次 → app_not_running（不挂住、不改走别处）
        r = Raw(h)
        r.req("test.write", {"key": "k", "value": "v", "async_ms": 3000}, op_id="t5")
        r2 = Raw(h)
        r2.req("test.block_main", {"ms": 3000})
        result = {}

        def bg():
            result["v"] = mcp_call(env, "collage_get_state")

        th = threading.Thread(target=bg)
        th.start()
        time.sleep(0.5)
        t_kill = time.monotonic()
        h.kill9()
        try:
            r.recv()
            eof = False
        except (EOFError, ConnectionResetError, OSError):
            eof = True
        eof_ms = (time.monotonic() - t_kill) * 1000
        th.join(timeout=20)
        _, body, mcp_ms = result.get("v", (None, None, 0))
        r.close()
        r2.close()
        check(eof and eof_ms < 500 * SLACK, f"T5 请求进行中 kill -9：客户端 {eof_ms:.1f} ms 内读到断开")
        check(err_code(body) == "app_not_running", f"--mcp 那个在等的读：断了以后重探 → app_not_running（{err_code(body)}，共 {mcp_ms:.0f} ms）")
        # T5b 残留 socket：connect 被拒、锁是空的 → not_running
        stale = os.path.exists(h.sock)
        st, ms = status(env)
        codes = all_tools(env, KEY)
        check(stale and (st.get("live") or {}).get("state") == "not_running" and set(codes.values()) == {"app_not_running"},
              f"T5b 残留的 socket 文件还在：not_running（{ms:.0f} ms），15 个工具都 app_not_running")
        # T6 新宿主接手残留的 socket
        h2 = Host("C2", data=h.data, root=h.root)
        st, _ = status(env)
        check(h2.bridge == "on" and "stale socket replaced" in h2.log() and (st.get("live") or {}).get("app", {}).get("pid") == h2.pid,
              "T6 新宿主删掉残留的 socket、重新 bind（stale socket replaced），live 的是新 pid")
        # T7 同一个数据目录起第二个：它回了 hello → 不开桥（GUI 同一套：照常启动、不开桥）
        h3 = Host("C3", data=h.data, root=h.root)
        st, _ = status(env)
        check(h3.bridge == "unavailable" and h3.reason == "another_instance" and (st.get("live") or {}).get("app", {}).get("pid") == h2.pid,
              f"T7 第二个宿主：bridge={h3.bridge} reason={h3.reason}；live 的还是第一个")
        h3.term()
        h2.term()
        # T8 5 个宿主同时起：只有一个开桥
        data8, root8 = fresh_data("C8"), sock_root("C8")
        hs = [Host(f"C8-{i}", data=data8, root=root8, wait=False) for i in range(5)]
        for x in hs:
            x.wait_ready(timeout=40)
        winners = [x for x in hs if x.bridge == "on"]
        st, _ = status(hs[0].env())
        check(len(winners) == 1 and all(x.reason in ("another_instance", "waiting_for_lock") for x in hs if x not in winners)
              and (st.get("live") or {}).get("app", {}).get("pid") == winners[0].pid,
              f"T8 5 个宿主同时起：恰好 1 个开桥，其余 {sorted(x.reason for x in hs if x not in winners)}")
        [x.term() for x in hs]
        # T9 SIGSTOP：hello 1 s 超时 → unresponsive（读写都是），SIGCONT 以后恢复
        h = Host("C9")
        env = h.env()
        h.signal(signal.SIGSTOP)
        st, ms = status(env)
        _, cs, cs_ms = mcp_call(env, "collage_get_state")
        _, rd9, _ = mcp_call(env, "cull_preview_photos", {"session": KEY, "ids": ["DSCF7208"]})
        _, wr9, _ = mcp_call(env, "collage_set_text", {"session": KEY, "title": "停住的时候"})
        h.signal(signal.SIGCONT)
        time.sleep(0.3)
        st2, _ = status(env)
        check((st.get("live") or {}).get("state") == "unresponsive" and 950 < ms < 2500 * SLACK and err_code(cs) == "app_unresponsive"
              and err_code(rd9) == "app_unresponsive" and err_code(wr9) == "app_unresponsive"
              and (st2.get("live") or {}).get("state") == "live" and st.get("gui_running") is True,
              f"T9 SIGSTOP：app_status {ms:.0f} ms 后 unresponsive，collage_get_state → app_unresponsive；SIGCONT 后 live")
        # T16 无头写者占着锁：headless_writer；要 app 的工具等 2 s 重探；app 起来时等锁
        h.term()
        data16, root16 = fresh_data("C16"), sock_root("C16")
        env16 = base_env(data16, root16)
        lf = os.open(os.path.join(data16, ".live.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.ftruncate(lf, 0)
        os.write(lf, b'{"role":"headless","pid":%d}\n' % os.getpid())
        st, _ = status(env16)
        _, ls16, _ = mcp_call(env16, "cull_list_sessions")
        t = time.monotonic()
        _, busy, busy_ms = mcp_call(env16, "collage_get_state")
        _, busy_r, _ = mcp_call(env16, "cull_get_photos", {"session": KEY, "ids": ["DSCF7208"]})
        _, busy_w, _ = mcp_call(env16, "cull_set_verdicts", {"session": KEY, "ids": ["DSCF7208"], "verdict": "pick"})
        check((st.get("live") or {}).get("state") == "headless_writer" and st.get("gui_running") is False
              and "headless_writer" in [w.get("code") for w in (ls16 or {}).get("warnings", [])],
              "T16 无头写者占着锁：app_status headless_writer；cull_list_sessions 照常列、带 warning")
        check(err_code(busy) == "busy" and err_code(busy_r) == "busy" and err_code(busy_w) == "busy"
              and ((busy or {}).get("error") or {}).get("data", {}).get("reason") == "headless_writer"
              and busy_ms > 1900, f"要 app 的工具等 2 s 重探，还是这样 → busy（headless_writer，{busy_ms:.0f} ms）")
        threading.Timer(1.0, lambda: (fcntl.flock(lf, fcntl.LOCK_UN), os.close(lf))).start()
        _, nr, nr_ms = mcp_call(env16, "collage_get_state")
        check(err_code(nr) == "app_not_running", f"等的 2 s 里写者放了锁 → 重探 not_running → app_not_running（{nr_ms:.0f} ms）")
        lf = os.open(os.path.join(data16, ".live.lock"), os.O_RDWR)
        fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.ftruncate(lf, 0)
        os.write(lf, b'{"role":"headless"}\n')
        threading.Timer(1.5, lambda: (fcntl.flock(lf, fcntl.LOCK_UN), os.close(lf))).start()
        h = Host("C16h", data=data16, root=root16)
        check(h.bridge == "on" and h.ready_ms > 1400, f"无头写者占锁 1.5 s：宿主等它放锁才开桥（{h.ready_ms:.0f} ms 就绪）")
        h.term()
        # --no-view（CI 的退路，§9.8.1）：不建视图也照样 live；test.snapshot 没有；LABELGUI_LIVE_TEST_SETTINGS 改钉的值
        h = Host("Cnv", args=("--no-view",), LABELGUI_LIVE_TEST_SETTINGS="rejectBurstDuplicates=1,minKeepersPerChapter=2,sortOrder=filename")
        st, _ = status(h.env())
        snap = test_call(h, "test.snapshot", {"name": "x"})
        got = state(h).get("settings")
        check(h.bridge == "on" and (st.get("live") or {}).get("state") == "live" and err_code(snap) == "unknown_method"
              and got == {"rejectBurstDuplicates": True, "minKeepersPerChapter": 2, "sortOrder": "文件名"},
              f"--no-view：live、test.snapshot → unknown_method；LABELGUI_LIVE_TEST_SETTINGS 钉的值在 store 里生效 {got}")
        h.term()
        # T12 协议版本不符：app 声明 99–99
        h = Host("C12", LABELGUI_LIVE_TEST_PROTO="99,99")
        env = h.env()
        st, _ = status(env)
        _, cs, _ = mcp_call(env, "collage_get_state")
        _, rd12, _ = mcp_call(env, "cull_list_photos", {"session": KEY})
        _, wr12, _ = mcp_call(env, "collage_set_text", {"session": KEY, "title": "版本不对"})
        check((st.get("live") or {}).get("state") == "proto_mismatch" and err_code(cs) == "app_version_mismatch"
              and err_code(rd12) == "app_version_mismatch" and err_code(wr12) == "app_version_mismatch"
              and ((cs or {}).get("error") or {}).get("data", {}).get("reason") == "proto_mismatch",
              "T12 协议版本不符：proto_mismatch；读也回 app_version_mismatch（reason proto_mismatch）")
        h.term()
        # 少一个方法（旧版 app）：只有那个工具回 app_version_mismatch（app_too_old）
        h_r = Host("C12r", LABELGUI_LIVE_TEST_DROP_CAP="cull.read")
        codes_r = {t: err_code(mcp_call(h_r.env(), t, minimal_args(t, KEY))[1]) for t in APP_TOOLS[:6]}
        h_r.term()
        check(all(codes_r[t] == "app_version_mismatch" for t in APP_TOOLS[:4])
              and codes_r["cull_preview_photos"] == ("preview_missing" if CI else None) and codes_r["collage_get_state"] is None,
              f"旧版 app 少了 cull.read：只有那 4 个工具回 app_version_mismatch，预览、拼图照常 {codes_r}")
        h = Host("C12c", LABELGUI_LIVE_TEST_DROP_CAP="collage.state")
        env = h.env()
        st, _ = status(env)
        _, cs, _ = mcp_call(env, "collage_get_state")
        _, ov12, _ = mcp_call(env, "cull_session_overview", {"session": KEY})
        check((st.get("live") or {}).get("state") == "live"
              and (st.get("live") or {}).get("capabilities") == [c for c in ALL_CAPS if c != "collage.state"]
              and err_code(cs) == "app_version_mismatch" and cs["error"].get("data", {}).get("reason") == "app_too_old"
              and (ov12 or {}).get("photo_count") == 21,
              "旧版 app 少了 collage.state：照样 live，collage_get_state → app_version_mismatch（app_too_old），概览照常")
        # T12b 数据目录不符：宿主开着时数据目录被换成一个新目录（同一个路径、不同的 dev:ino）
        moved = h.data + ".moved"
        os.rename(h.data, moved)
        shutil.copytree(moved, h.data, ignore=shutil.ignore_patterns(".live.lock"))
        st, _ = status(env)
        _, cs, _ = mcp_call(env, "collage_get_state")
        check((st.get("live") or {}).get("state") == "data_dir_mismatch" and err_code(cs) == "data_dir_mismatch",
              "T12b 数据目录被换掉（路径一样、dev:ino 不一样）：data_dir_mismatch（读写都是）")
        h.term()
        # T14 拒绝对端：一个字节不回就关
        h = Host("C14", LABELGUI_LIVE_TEST_REJECT_PEERS="1")
        st, ms = status(h.env())
        _, cs, _ = mcp_call(h.env(), "collage_get_state")
        check((st.get("live") or {}).get("state") == "peer_rejected" and err_code(cs) == "peer_rejected" and "reject peer uid=" in h.log(),
              f"T14 宿主拒绝对端：peer_rejected（{ms:.0f} ms），宿主日志 reject peer uid=…")
        h.term()
        # 两边的 socket 路径一致（§9.8.2 第 22 条）：宿主写 /tmp/…，--mcp 写 /private/tmp/… 并改一个路径段的大小写
        if os.path.realpath(WORK).startswith("/private/tmp/"):
            d22 = fresh_data("C22")
            via_tmp = "/tmp/" + d22[len("/private/tmp/"):]
            parts = d22.split("/")
            parts[3] = parts[3].upper()          # /private/tmp/<这一段> 改大写（APFS 不分大小写）
            shouted = "/".join(parts)
            h = Host("C22", data=via_tmp)
            st, _ = status(base_env(shouted, h.root))
            check((st.get("live") or {}).get("state") == "live" and (st.get("live") or {}).get("socket") == h.sock,
                  f"宿主的数据目录写成 /tmp/…、--mcp 写成 /private/tmp/… 还改了大小写：仍然 live（realpath(3) 两边归一）")
            h.term()
        else:
            skip("第 22 条的 /tmp ↔ /private/tmp 写法：工作目录不在 /private/tmp 下")
        # T18 CLOEXEC（R6 §4.4）：宿主起的子进程不继承锁和 socket。子进程不由 Live/ 起（那里禁 posix_spawn）：
        # 测试注入一个小 dylib（DYLD_INSERT_LIBRARIES），收到信号文件后 posix_spawn /bin/sleep（不带 CLOEXEC_DEFAULT，
        # 继承所有没设 CLOEXEC 的 fd；另外故意开一个不带 CLOEXEC 的 /dev/null 做对照）。
        cc = shutil.which("cc")
        if not cc:
            skip("T18 注入子进程：没有 cc（只靠 B 组从外面看的 CLOEXEC 位）")
        else:
            src = os.path.join(WORK, "spawn_probe.c")
            lib = os.path.join(WORK, "spawn_probe.dylib")
            open(src, "w").write(r'''
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
static void *waiter(void *arg) {
    const char *trig = getenv("XP_SPAWN_TRIGGER"), *out = getenv("XP_SPAWN_OUT");
    struct stat st;
    while (stat(trig, &st) != 0) usleep(20000);
    int ctl = open("/dev/null", O_RDONLY);          /* 对照：不带 CLOEXEC，子进程应该继承 */
    pid_t pid = 0;
    char *argv[] = {"/bin/sleep", "300", NULL};
    char *envp[] = {NULL};
    int rc = posix_spawn(&pid, "/bin/sleep", NULL, NULL, argv, envp);
    FILE *f = fopen(out, "w");
    if (f) { fprintf(f, "%d %d %d\n", rc, (int)pid, ctl); fclose(f); }
    return NULL;
}
__attribute__((constructor)) static void init(void) {
    if (getenv("XP_SPAWN_TRIGGER") && getenv("XP_SPAWN_OUT")) { pthread_t t; pthread_create(&t, NULL, waiter, NULL); }
}
''')
            rc = subprocess.run([cc, "-dynamiclib", "-o", lib, src], capture_output=True).returncode
            trig, outp = os.path.join(WORK, "spawn.trigger"), os.path.join(WORK, "spawn.out")
            h = Host("C18", env_extra={"DYLD_INSERT_LIBRARIES": lib, "XP_SPAWN_TRIGGER": trig, "XP_SPAWN_OUT": outp}) if rc == 0 else None
            if not h or h.bridge != "on":
                skip(f"T18 注入子进程：dylib 编不出来或宿主没起来（cc rc={rc}）")
            else:
                keep = Raw(h)            # 有一个连着的连接：它的 fd 也不能被继承
                open(trig, "w").close()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and not (os.path.exists(outp) and open(outp).read().strip()):
                    time.sleep(0.05)
                parts = open(outp).read().split() if os.path.exists(outp) else []
                if len(parts) != 3 or parts[0] != "0":
                    skip(f"T18 注入子进程：posix_spawn 没成（{parts}）")
                    keep.close()
                    h.term()
                else:
                    child, ctl = int(parts[1]), int(parts[2])
                    PROCS.append(type("P", (), {"term": lambda self, c=child: os.kill(c, signal.SIGKILL) if pid_alive(c) else None})())
                    cfds = proc_fds(child)
                    inherited_ctl = any(fd == ctl for fd, *_ in cfds)
                    leaked = [x for x in cfds if x[1] == PROX_FDTYPE_SOCKET or (x[3] or "").endswith("/.live.lock")]
                    keep.close()
                    h.kill9()
                    st, _ = status(h.env())
                    os.kill(child, signal.SIGKILL)
                    check(inherited_ctl, f"（对照）不带 CLOEXEC 的 fd {ctl} 子进程继承了：这次 posix_spawn 确实会漏 fd")
                    check(not leaked and (st.get("live") or {}).get("state") == "not_running",
                          f"T18 宿主起的子进程没拿到锁和 socket（{leaked}）；宿主被杀以后子进程还活着，--mcp 看到的是 not_running")

    # ============================================================ D. SIGPIPE 矩阵（R6 §4.3）
    if "D" in ONLY:
        print("D. SIGPIPE 矩阵")
        want = {"none": ("DEAD(SIGPIPE)", "DEAD(SIGPIPE)"), "accepted_only": ("DEAD(SIGPIPE)", "alive"),
                "listen_inherit": ("alive", "alive"), "msg_nosignal": ("alive", "alive"), "all": ("alive", "alive")}

        def verdict(h):
            time.sleep(0.5)
            v = "alive" if h.alive() else f"DEAD({'SIGPIPE' if h.proc.returncode == -signal.SIGPIPE else h.proc.returncode})"
            h.term()
            return v

        got = {}
        for mode in want:
            # A：客户端在 accept 之前就走了（宿主被 SIGSTOP；hello 发出去 300 ms 没回就关）
            h = Host(f"D-{mode}-a", LABELGUI_LIVE_TEST_SIGPIPE=mode)
            h.signal(signal.SIGSTOP)
            s_ = socket.socket(socket.AF_UNIX)
            s_.connect(h.sock)
            s_.sendall((json.dumps({"id": 0, "method": "hello", "params": {"proto": 1, "data_dir_id": h.data_dir_id}}) + "\n").encode())
            time.sleep(0.3)
            s_.close()
            h.signal(signal.SIGCONT)
            a = verdict(h)
            # B：8 MB 回复写到一半客户端关掉（3 次）
            h = Host(f"D-{mode}-b", LABELGUI_LIVE_TEST_SIGPIPE=mode)
            for _ in range(3):
                try:
                    c = Raw(h)
                    c.req("test.blob", {"bytes": 8_000_000})
                    c.s.recv(10_000)
                    c.close()
                except (OSError, EOFError):
                    break           # 宿主已经被 SIGPIPE 杀了
            b = verdict(h)
            got[mode] = (a, b)
            check(got[mode] == want[mode], f"{mode:15s} accept 之前就走了：{a:14s} 写到一半关掉：{b}（R6：{want[mode]}）")

    # ============================================================ E. --app-ui 不开桥（§9.8.2 第 30 条）
    if "E" in ONLY and not VIEW:
        print("E. --app-ui 不开桥")
        skip("--app-ui 要建离屏窗口拍快照（和视图探针同一种窗口）：CI 用 --no-view，这一组看本地")
    elif "E" in ONLY:
        print("E. --app-ui 不开桥")
        data = fresh_data("E")
        root = sock_root("E")
        png = os.path.join(WORK, "app-ui.png")
        r = subprocess.run([BIN, "--app-ui", PHOTO_DIR, png, "--wait", "1"], env=base_env(data, root, LABELGUI_STABLE_SEEDS="1"),
                           capture_output=True, timeout=60 * SLACK, cwd=WORK, stdin=subprocess.DEVNULL)
        check(r.returncode == 0 and os.path.getsize(png) > 10_000, f"--app-ui 拍出来了（exit {r.returncode}）")
        check(not os.path.exists(os.path.join(data, ".live.lock")) and not os.listdir(os.path.join(SOCKS, os.path.basename(root))),
              "--app-ui 跑完：数据目录里没有 .live.lock，socket 根目录里什么都没有")
        check(not os.path.exists(os.path.join(data, "runtime")), "--app-ui 不同步 Python 运行时（没有 runtime/）")

    # ============================================================ F. 读和图片（STEP 3a：§10.7 第 31–36、38 条）
    if "F" in ONLY:
        print("F. 读和图片")
        # ---------- 31 fixture 读：概览 / 场 / 每张的判决和 --verdicts 的输出一样
        if CI:
            ref = parse_verdicts(open(os.path.join(FIX, "expected_verdicts.txt"), encoding="utf-8").read())
            ref_src = "expected_verdicts.txt"
        else:
            ref = verdicts_cli()
            ref_src = "--verdicts --per-photo（同一份数据的另一个拷贝）"
        h = Host("F31")
        env = h.env()
        _, ov, ov_ms = mcp_call(env, "cull_session_overview", {"session": KEY})
        ov = ov or {}
        vc = ov.get("verdict_counts") or {}
        check(ref is not None and (ov.get("photo_count"), vc.get("pick"), vc.get("usable"), vc.get("reject")) == ref["counts"],
              f"概览的计数 = {ref_src} 第 2 行 {ref and ref['counts']}：{(ov.get('photo_count'), vc)}（{ov_ms:.0f} ms）")
        nd, sc = ov.get("near_duplicates") or {}, ov.get("scenes") or {}
        check(ref is not None and (nd.get("groups"), nd.get("photos")) == ref["dups"]
              and (sc.get("multi_photo_scenes"), sc.get("photos"), sc.get("pending")) == ref["scenes"]
              and (ov.get("reason_counts") or {}) == ref["reasons"],
              f"近似重复 / 场 / 理由 = 第 3、4 行和理由行：{nd} {sc} {ov.get('reason_counts')}")
        check((ov.get("settings") or {}).get("source") == "app" and ov.get("analysis") == {"running": False}
              and ov.get("pending_writes") == 0 and not any(k in ov for k in ("recently_modified_sec", "dedupe")),
              "概览：settings.source=app、analysis.running、pending_writes；没有 §10.1 删掉的字段")
        groups, cur, pages = [], None, 0
        while pages < 20:
            a = {"session": KEY, "kind": "scene", "limit": 2}
            if cur:
                a["cursor"] = cur
            _, g, _ = mcp_call(env, "cull_list_groups", a)
            groups += (g or {}).get("groups") or []
            cur = (g or {}).get("next_cursor")
            pages += 1
            if not cur:
                break
        got_scenes = [(x["key"], [(m["id"], m["verdict"], m.get("rank")) for m in x["members"]]) for x in groups]
        check(ref is not None and got_scenes == ref["scene_lines"],
              f"cull_list_groups kind=scene（每页 2 组、{pages} 页）= 「场 N」那几行（id、判决、名次）：{len(got_scenes)} 组")
        if ref and ref.get("per_photo"):
            rows = []
            _, p_, _ = mcp_call(env, "cull_list_photos", {"session": KEY, "sort": "id", "limit": 100})
            rows = (p_ or {}).get("rows") or []
            mine = {r["id"]: (r["verdict"], ",".join(r["reasons"]) or "-") for r in rows}
            check(mine == ref["per_photo"], f"cull_list_photos 每张的判决和理由 = --per-photo（{len(mine)} 张）")
        # 翻页：limit=5，21 个 id 各出现一次；翻到一半在宿主里改判一张 → 下一页带 session_changed:true
        seen, cur, changed_at, n_pages = [], None, None, 0
        while n_pages < 10:
            a = {"session": KEY, "limit": 5}
            if cur:
                a["cursor"] = cur
            _, p_, _ = mcp_call(env, "cull_list_photos", a)
            p_ = p_ or {}
            seen += [r["id"] for r in p_.get("rows") or []]
            if p_.get("session_changed"):
                changed_at = changed_at or n_pages
            n_pages += 1
            cur = p_.get("next_cursor")
            if n_pages == 2:
                test_call(h, "test.set_override", {"id": seen[0], "verdict": "reject"})
            if not cur:
                break
        check(sorted(seen) == sorted(set(seen)) and len(seen) == 21 and changed_at == 2,
              f"cull_list_photos limit=5 顺着 cursor 翻 {n_pages} 页：21 个 id 各出现一次（{len(seen)} 个、{len(set(seen))} 个不同）；"
              f"第 2 页之后在宿主里改判一张 → 下一页 session_changed:true（第 {changed_at} 页）")
        _, p_, _ = mcp_call(env, "cull_list_photos", {"session": KEY, "manual_only": True})
        check([r["id"] for r in (p_ or {}).get("rows") or []] == [seen[0]] and p_["rows"][0]["verdict"] == "reject"
              and p_["rows"][0]["manual"] is True, "manual_only：刚才改判的那一张，reject、manual:true（读的是内存，不等落盘）")
        _, gp, _ = mcp_call(env, "cull_get_photos", {"session": KEY, "ids": ["DSCF7208", "NOPE-1", "DSCF7208"]})
        ph = ((gp or {}).get("photos") or [{}])[0]
        check((gp or {}).get("missing_ids") == ["NOPE-1"] and len(gp.get("photos") or []) == 1
              and {"original_path", "exif", "faces_detail", "capture_time", "scene", "chapter"} <= set(ph)
              and all(len(f["bbox"]) == 4 for f in ph.get("faces_detail") or []),
              f"cull_get_photos：重复的 id 去重、不存在的进 missing_ids，字段齐（{sorted(ph)[:6]}…）")
        _, gp2, _ = mcp_call(env, "cull_get_photos", {"session": KEY, "ids": ["NOPE-1"]})
        check(err_code(gp2) == "photo_not_found", f"全部 id 都不存在 → photo_not_found（{err_code(gp2)}）")
        bad = [mcp_call(env, t, a)[1] for t, a in (
            ("cull_list_photos", {"session": KEY, "limit": 0}), ("cull_list_photos", {"session": KEY, "verdict": ["good"]}),
            ("cull_list_photos", {"session": KEY, "bogus": 1}), ("cull_list_groups", {"session": KEY}),
            ("cull_get_photos", {"session": KEY, "ids": []}), ("cull_list_photos", {"session": KEY, "cursor": "garbage"}),
            ("cull_list_photos", {"session": KEY, "verdict": ["pick"], "cursor": cur_first(env)}),
            ("cull_preview_photos", {"session": KEY, "ids": ["a", "b", "c", "d", "e"]}),
            ("cull_preview_photos", {"session": KEY, "ids": ["DSCF7208"], "max_edge": 2000}),
            ("collage_get_state", {"max_edge": 1500}))]
        check(all(err_code(b) == "invalid_argument" for b in bad),
              f"参数不对 → invalid_argument（limit 0、verdict 不认、多余参数、缺 kind、ids 空、坏 cursor、换了条件的 cursor、"
              f"5 张、max_edge 2000、拼图 max_edge 1500）{[err_code(b) for b in bad]}")
        # text 上限（LABELGUI_MCP_TEXT_MAX）：截在 app 那一侧，next_cursor 接得上
        env_t = h.env(LABELGUI_MCP_TEXT_MAX="2000")
        seen_t, cur, n_t, trunc = [], None, 0, False
        while n_t < 30:
            a = {"session": KEY, "limit": 100}
            if cur:
                a["cursor"] = cur
            _, p_, _ = mcp_call(env_t, "cull_list_photos", a)
            p_ = p_ or {}
            trunc = trunc or p_.get("truncated") is True
            seen_t += [r["id"] for r in p_.get("rows") or []]
            cur = p_.get("next_cursor")
            n_t += 1
            if not cur:
                break
        check(trunc and sorted(seen_t) == sorted(set(seen_t)) and len(seen_t) == 21,
              f"LABELGUI_MCP_TEXT_MAX=2000：每页被截（truncated:true），顺着 next_cursor {n_t} 页还是 21 个各一次")
        # 38 NaN：宿主往 store 里塞非有限数，读工具回 null，宿主没闪退（app 端也经 MCPJSON.sanitize）
        test_call(h, "test.poke_nonfinite", {"id": "DSCF7209"})
        _, nan, _ = mcp_call(env, "cull_get_photos", {"session": KEY, "ids": ["DSCF7209"]})
        p9 = ((nan or {}).get("photos") or [{}])[0]
        check(h.alive() and all(p9.get(k, "missing") is None for k in ("face_luma", "frame_luma", "frame_luma_p99", "capture_subsec")),
              f"第 38 条：NaN / ±inf 塞进 store → cull_get_photos 那几个字段是 null，宿主活着 "
              f"{ {k: p9.get(k, 'missing') for k in ('face_luma', 'frame_luma', 'frame_luma_p99', 'capture_subsec')} }")
        _, ov2, _ = mcp_call(env, "cull_session_overview", {"session": KEY})
        check(h.alive() and (ov2 or {}).get("photo_count") == 21, "塞了非有限数以后概览照常回")
        # 36 场次：别的场次 → session_not_open；用户切到空文件夹以后旧场次的读也是 session_not_open
        reads = [("cull_session_overview", {}), ("cull_list_photos", {}), ("cull_get_photos", {"ids": ["DSCF7208"]}),
                 ("cull_list_groups", {"kind": "scene"}), ("cull_preview_photos", {"ids": ["DSCF7208"]}),
                 ("collage_get_state", {"include_preview": False})]
        other = [mcp_call(env, t, dict(a, session="0123456789abcdef"))[1] for t, a in reads]
        check(all(err_code(b) == "session_not_open" and ((b["error"].get("data") or {}).get("open_session") or {}).get("session") == KEY
                  for b in other), f"6 个读工具带别的场次 → session_not_open，data.open_session 对 {[err_code(b) for b in other]}")
        sw = test_call(h, "test.switch_session", {"photo_dir": EMPTY_PHOTOS}).get("result") or {}
        old = [mcp_call(env, t, dict(a, session=KEY))[1] for t, a in reads]
        _, ov_e, _ = mcp_call(env, "cull_session_overview", {"session": EMPTY_PHOTOS})
        check(all(err_code(b) == "session_not_open" for b in old) and (ov_e or {}).get("photo_count") == 0
              and ov_e.get("session") == sw.get("session"),
              f"用户切到没分析过的空文件夹：旧场次的读都 session_not_open；新场次能读、0 张（open_session 不是 null："
              f"STEP 2 的定义，只有一个文件夹都没开时才是 null）")
        test_call(h, "test.switch_session", {"photo_dir": PHOTO_DIR})
        h.term()

        # ---------- 合成图场次（32–35）：原图 1800×1200、分析预览 1024×683，四个象限四种颜色 + 噪声
        syn = synth_session("syn")
        hs = Host("F32", data=syn["data"], photos=syn["dir"])
        out = os.path.join(WORK, "F-out")
        env = hs.env(LABELGUI_MCP_OUT=out)
        st0, _ = status(env)
        check(not os.path.exists(out) and st0.get("preview_cache_bytes") == 0,
              f"输出目录启动时、app_status 时都不建（{out} 不存在，preview_cache_bytes 0）")
        sk = syn["key"]
        res, body, ms = mcp_full(env, "cull_preview_photos", {"session": sk, "ids": [syn["ids"][1]]})
        img = ((body or {}).get("images") or [{}])[0]
        blk = image_blocks(res)
        f1 = img.get("file")
        check(res is not None and len(blk) == 1 and blk[0][:2] == b"\xff\xd8" and img.get("index") == 0
              and max(img.get("width", 0), img.get("height", 0)) == 1024 and img.get("source") == "preview"
              and f1 and os.path.dirname(f1) == os.path.realpath(os.path.join(out, "previews", sk))
              and open(f1, "rb").read() == blk[0] and len(blk[0]) == img.get("bytes"),
              f"crop=full 单张：长边 1024、source preview、image 块是 JPEG、和 previews/<key>/ 下的文件逐字节相同（{ms:.0f} ms）")
        check(os.path.isfile(os.path.join(out, ".xuanpian-mcp")), "第一次存图才建输出目录，根上有 .xuanpian-mcp 标记")
        res2, body2, _ = mcp_full(env, "cull_preview_photos", {"session": sk, "ids": [syn["ids"][1]]})
        check(((body2 or {}).get("images") or [{}])[0].get("file") == f1, "同样的请求调两次：同一个文件（按内容寻址）")
        res, body, _ = mcp_full(env, "cull_preview_photos", {"session": sk, "ids": [syn["ids"][2]], "max_edge": 1568})
        img = ((body or {}).get("images") or [{}])[0]
        check(img.get("source") == "original" and max(img.get("width", 0), img.get("height", 0)) <= 1568
              and img.get("bytes", 0) <= 350 * 1024 and len(image_blocks(res)) == 1,
              f"max_edge=1568 单张：从原图解（source original），长边 {max(img.get('width', 0), img.get('height', 0))}、"
              f"{img.get('bytes', 0) // 1024} KB ≤ 350 KB")
        res, body, ms4 = mcp_full(env, "cull_preview_photos", {"session": sk, "ids": syn["ids"][:4]})
        imgs = (body or {}).get("images") or []
        blk = image_blocks(res)
        check(len(imgs) == 4 and len(blk) == 4 and all(max(i["width"], i["height"]) <= 768 for i in imgs)
              and sum(len(b) for b in blk) <= 600 * 1024 and [i["index"] for i in imgs] == [0, 1, 2, 3]
              and all(b[:2] == b"\xff\xd8" for b in blk),
              f"4 张：每张长边 ≤ 768、合计 {sum(len(b) for b in blk) // 1024} KB ≤ 600 KB、index 0–3 对应 image 块（{ms4:.0f} ms）")
        res, body, msf = mcp_full(env, "cull_preview_photos", {"session": sk, "ids": [syn["ids"][3]], "crop": "face"})
        img = ((body or {}).get("images") or [{}])[0]
        check(img.get("source") == "original" and img.get("crop") == "face" and len(image_blocks(res)) == 1
              and img.get("file", "").endswith("-face.jpg") and state(hs)["original_opens"]["count"] >= 2,
              f"crop=face：CompareZoom 裁原图（source original），文件名 …-face.jpg（{msf:.0f} ms）")
        res, body, _ = mcp_full(env, "cull_preview_photos", {"session": sk, "ids": syn["ids"][:2], "inline": False})
        check(not image_blocks(res) and all(os.path.isfile(i.get("file") or "") and i.get("index") is None
                                             for i in (body or {}).get("images") or []) and (body or {}).get("inline") is False,
              "inline:false：没有 image 块，只给文件路径（index 是 null）")
        res, body, _ = mcp_full(hs.env(LABELGUI_MCP_OUT=out, LABELGUI_MCP_INLINE_KB="150"), "cull_preview_photos",
                                {"session": sk, "ids": syn["ids"][:4]})
        imgs = (body or {}).get("images") or []
        given = [i for i in imgs if i.get("index") is not None]
        check((body or {}).get("truncated") is True and 1 <= len(given) < 4 and len(image_blocks(res)) == len(given)
              and all(i.get("truncated") and i.get("file") is None for i in imgs if i not in given)
              and "budget_truncated" in [w.get("code") for w in body.get("warnings") or []],
              f"LABELGUI_MCP_INLINE_KB=150：前 {len(given)} 张给图，后面的标 truncated、没有字节和文件，warning budget_truncated")
        _, nf, _ = mcp_call(env, "cull_preview_photos", {"session": sk, "ids": ["NOPE"]})
        check(err_code(nf) == "photo_not_found", "预览：id 都不存在 → photo_not_found")
        # 预览文件没有（掉出最近 15 场被清掉）→ 从原图现解，带 warning
        moved = os.path.join(syn["data"], "sessions", sk, "previews", syn["ids"][4] + ".jpg")
        os.rename(moved, moved + ".away")
        _, pm, _ = mcp_call(env, "cull_preview_photos", {"session": sk, "ids": [syn["ids"][4]]})
        os.rename(moved + ".away", moved)
        check(((pm or {}).get("images") or [{}])[0].get("source") == "original"
              and "preview_file_missing" in [w.get("code") for w in (pm or {}).get("warnings") or []],
              "分析预览不在了：从原图现解（source original）、warning preview_file_missing")
        # 34 并发：每轮同时发 4 个带 >120 KB 图的调用，5 轮，0 损坏（R3 #263 的场景，现在经过桥）
        m = Mcp(env)
        m.initialize()
        bad_frames, big, n_ok = [], 0, 0
        for rnd in range(5):
            ids_ = [f"c{rnd}-{i}" for i in range(4)]
            for i, cid in enumerate(ids_):
                m.call(cid, "cull_preview_photos", {"session": sk, "ids": [syn["ids"][(rnd + i) % len(syn["ids"])]],
                                                    "max_edge": 1024})
            for cid in ids_:
                f = m.wait_id(cid, timeout=60)
                try:
                    body_ = json.loads(f["result"]["content"][0]["text"])
                    data_ = base64.b64decode(f["result"]["content"][1]["data"])
                    im = body_["images"][0]
                    ok = data_[:2] == b"\xff\xd8" and len(data_) == im["bytes"] and open(im["file"], "rb").read() == data_
                    big += len(data_) > 120 * 1024
                    n_ok += ok
                    if not ok:
                        bad_frames.append(cid)
                except Exception as e:
                    bad_frames.append(f"{cid}:{e!r}")
        m.close()
        check(not bad_frames and n_ok == 20 and big == 20,
              f"34 并发：5 轮 × 4 个同时发，{n_ok}/20 帧完整（字节 = bytes、和文件相同、FF D8），{big} 张 > 120 KB，坏帧 {bad_frames[:3]}")
        # 35 取消：主线程卡 3 s 期间发一个读、一个写（test.write），各自断开 → 4 s 内这个 id 没有消息，ping 照常回；
        # 主线程恢复以后，这两个请求都没执行（clientGone，§10.2）
        st_before = state(hs)
        m = Mcp(env)
        m.initialize()
        r = Raw(hs)
        r.req("test.block_main", {"ms": 3000})
        time.sleep(0.1)
        m.call("cx", "cull_session_overview", {"session": sk})
        w_ = Raw(hs)
        w_.req("test.write", {"key": "gone", "value": "1"}, op_id=str(uuid.uuid4()))
        time.sleep(0.3)
        m.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "cx", "reason": "test"}})
        w_.close()
        pr = Raw(hs, timeout=2)
        t_p = time.monotonic()
        pong = pr.call("ping")
        ping_ms = (time.monotonic() - t_p) * 1000
        pr.close()
        late = m.wait_id("cx", timeout=4)
        r.recv()
        r.close()
        time.sleep(0.3)
        st_after = state(hs)
        m.close()
        skipped = st_after["counters"].get("skipped_client_gone", 0) - st_before["counters"].get("skipped_client_gone", 0)
        check(late is None and (pong.get("result") or {}).get("pong") is True and ping_ms < 500
              and st_after["test_applied"] == st_before["test_applied"] and "gone" not in st_after["test_values"]
              and skipped == 2,
              f"35 取消：卡着的时候取消一个读、断开一个写 → 这个 id 4 s 内没有消息，ping {ping_ms:.0f} ms 回；"
              f"恢复以后两个都没执行（skipped_client_gone +{skipped}，test.write 没生效）")
        hs.term()
        # 输出目录的规矩（§10.3、§4.2）：不空又没有标记 → 内联照常、不写文件；inline:false → output_dir_unusable；
        # 受保护位置、相对路径不用；清理只删服务器起名的旧文件
        hs = Host("F32o", data=syn["data"], photos=syn["dir"])
        foreign = os.path.join(WORK, "F-foreign")
        os.makedirs(foreign)
        open(os.path.join(foreign, "我的照片.jpg"), "wb").write(b"user")
        before = sorted(os.listdir(foreign))
        res, body, _ = mcp_full(hs.env(LABELGUI_MCP_OUT=foreign), "cull_preview_photos", {"session": sk, "ids": [syn["ids"][0]]})
        _, b_off, _ = mcp_call(hs.env(LABELGUI_MCP_OUT=foreign), "cull_preview_photos",
                               {"session": sk, "ids": [syn["ids"][0]], "inline": False})
        check(len(image_blocks(res)) == 1 and ((body or {}).get("images") or [{}])[0].get("file") is None
              and "output_dir_unusable" in [w.get("code") for w in (body or {}).get("warnings") or []]
              and err_code(b_off) == "output_dir_unusable" and sorted(os.listdir(foreign)) == before,
              "LABELGUI_MCP_OUT 不空又没有标记：图照常内联、不存文件、warning；inline:false → output_dir_unusable；目录里一个字节没多")
        fh = os.path.join(WORK, "F-家")
        os.makedirs(os.path.join(fh, "Desktop"))
        _, b_p, _ = mcp_call(hs.env(LABELGUI_MCP_OUT=os.path.join(fh, "Desktop", "out"), CFFIXED_USER_HOME=fh, HOME=fh),
                             "cull_preview_photos", {"session": sk, "ids": [syn["ids"][0]], "inline": False})
        _, b_r, _ = mcp_call(hs.env(LABELGUI_MCP_OUT="relative/out"), "cull_preview_photos",
                             {"session": sk, "ids": [syn["ids"][0]], "inline": False})
        check(err_code(b_p) == "output_dir_unusable" and not os.path.exists(os.path.join(fh, "Desktop", "out"))
              and err_code(b_r) == "output_dir_unusable" and not os.path.exists(os.path.join(WORK, "relative")),
              "输出目录在（假的家目录的）桌面 / 是相对路径：output_dir_unusable，什么都不建")
        # 还不存在的输出目录在数据目录 / 已登记的照片文件夹里面：先查再建，一级都不建（§10.0 第 3 条）
        made = []
        for base in (syn["data"], syn["dir"]):
            target = os.path.join(base, "never", "out")
            _, b_in, _ = mcp_call(hs.env(LABELGUI_MCP_OUT=target), "cull_preview_photos",
                                  {"session": sk, "ids": [syn["ids"][0]], "inline": False})
            res, b_in2, _ = mcp_full(hs.env(LABELGUI_MCP_OUT=target), "cull_preview_photos", {"session": sk, "ids": [syn["ids"][0]]})
            made.append((err_code(b_in), "output_dir_unusable" in [w.get("code") for w in (b_in2 or {}).get("warnings") or []],
                         len(image_blocks(res)), os.path.lexists(os.path.join(base, "never"))))
        check(all(m_ == ("output_dir_unusable", True, 1, False) for m_ in made),
              f"LABELGUI_MCP_OUT 是数据目录 / 照片文件夹里还不存在的子目录：inline:false → output_dir_unusable，"
              f"内联照常 + warning，never/ 没被建出来 {made}")
        hs.term()
        # 到这里输出目录里只有标记和服务器起名的预览（previews/<16 位十六进制>/<sha1 前 16>-….jpg），没有临时文件
        stray = [os.path.relpath(os.path.join(dp, f_), out) for dp, _, fs in os.walk(out) for f_ in fs
                 if not (dp == out and f_ == ".xuanpian-mcp")
                 and not (re.match(r"^[0-9a-f]{16}$", os.path.basename(dp)) and os.path.dirname(dp) == os.path.join(out, "previews")
                          and re.match(r"^[0-9a-f]{16}-.+-(full|face)\.jpg$", f_))]
        check(not stray and set(os.listdir(out)) == {".xuanpian-mcp", "previews"},
              f"输出目录里只有 .xuanpian-mcp 和 previews/<key>/ 下服务器起名的文件（没有临时文件、没有别的）{stray[:3]}")
        # 清理：只在带标记的根上、只删 previews/<16 位十六进制>/ 下面服务器起名的旧文件
        pdir = os.path.join(out, "previews", sk)
        old_server = os.path.join(pdir, "0123456789abcdef-OLD-768-full.jpg")
        old_temp = os.path.join(pdir, ".0123456789abcdef-T-768-full.jpg.tmp-1-0badf00d")
        keep_user = os.path.join(pdir, "my-notes.jpg")
        keep_other = os.path.join(out, "previews", "not-a-key", "0123456789abcdef-X-768-full.jpg")
        keep_link_target = os.path.join(WORK, "F-link-target.jpg")
        os.makedirs(os.path.dirname(keep_other))
        for p_ in (old_server, old_temp, keep_user, keep_other, keep_link_target):
            open(p_, "wb").write(b"\xff\xd8x")
        link = os.path.join(pdir, "fedcba9876543210-LINK-768-full.jpg")
        os.symlink(keep_link_target, link)
        old = time.time() - 8 * 86400
        for p_ in (old_server, old_temp, keep_user, keep_other, link):
            os.utime(p_, (old, old), follow_symlinks=False)
        fresh_files = [os.path.join(pdir, f_) for f_ in os.listdir(pdir) if re.match(r"^[0-9a-f]{16}-.+\.jpg$", f_)
                       and not f_.startswith("0123") and not os.path.islink(os.path.join(pdir, f_))]
        st_c, _ = status(base_env(syn["data"], sock_root("F-cl"), LABELGUI_MCP_OUT=out))
        m = Mcp(base_env(syn["data"], sock_root("F-cl2"), LABELGUI_MCP_OUT=out))
        m.initialize()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and os.path.exists(old_server):
            time.sleep(0.05)
        m.close()
        check(not os.path.exists(old_server) and not os.path.exists(old_temp) and os.path.exists(keep_user)
              and os.path.exists(keep_other) and os.path.lexists(link) and os.path.exists(keep_link_target)
              and all(os.path.exists(f_) for f_ in fresh_files) and fresh_files,
              f"回完 initialize 后台清理：删了 8 天前的服务器文件和临时文件；用户的文件、不是 key 的目录、符号链接、"
              f"新的 {len(fresh_files)} 个预览都还在")
        check(st_c.get("preview_cache_bytes", 0) >= sum(os.path.getsize(f_) for f_ in fresh_files) > 0,
              f"app_status.preview_cache_bytes 数的是服务器起名的文件：{st_c.get('preview_cache_bytes')}")

        # ---------- 33 受保护位置不读原图：sandbox-exec 里起宿主，读原图（文件内容）就 SIGKILL
        # （app 里的二进制不进 sandbox：规则抓到就 SIGKILL，系统会弹「意外退出」；只看原图打开记录）
        sandbox = "/usr/bin/sandbox-exec" if not NO_KILL else "/nonexistent/sandbox-exec"
        if not os.access(sandbox, os.X_OK):
            skip("没有 sandbox-exec（或者是 app 里的二进制）：第 33 条只有 test.state 的原图打开记录作证")
        sbq = lambda p_: '"' + p_.replace("\\", "\\\\").replace('"', '\\"') + '"'

        def deny_originals(d):
            rp = os.path.realpath(d)
            return ("(version 1)(allow default)(deny file-read-data (regex " + sbq("^" + re.escape(rp) + "/[^/]+\\.jpg$")
                    + ") (with send-signal SIGKILL))")

        def protected_case(label, photos_dir, data_dir, extra):
            if os.access(sandbox, os.X_OK):
                wrap = [sandbox, "-p", deny_originals(photos_dir)]
            else:
                wrap = []
            hp = Host(label, data=data_dir, photos=photos_dir, wrap=wrap, args=("--no-view",), **extra)
            envp = hp.env(LABELGUI_MCP_OUT=out, **{k: v for k, v in extra.items() if k in ("CFFIXED_USER_HOME", "HOME")})
            key_ = syn_keys[photos_dir]
            _, fb, _ = mcp_call(envp, "cull_preview_photos", {"session": key_, "ids": [syn["ids"][3]], "crop": "face"})
            _, bb, _ = mcp_call(envp, "cull_preview_photos", {"session": key_, "ids": [syn["ids"][2]], "max_edge": 1568})
            opens = (state(hp).get("original_opens") or {}).get("count") if hp.alive() else None
            alive = hp.alive()
            hp.term()
            fi = ((fb or {}).get("images") or [{}])[0]
            bi = ((bb or {}).get("images") or [{}])[0]
            ok = (alive and opens == 0 and fi.get("source") == "preview" and fi.get("crop") == "face"
                  and "protected_location" in [w.get("code") for w in (fb or {}).get("warnings") or []]
                  and bi.get("source") == "preview" and max(bi.get("width", 0), bi.get("height", 0)) == 1024)
            return ok, (alive, opens, fi.get("source"), bi.get("source"))

        ok_a, info_a = protected_case("F33-prefix", syn["dir"], fresh_copy(syn["data"], "F33a"),
                                      {"LABELGUI_LIVE_TEST_PROTECTED_PREFIX": syn["dir"]})
        check(ok_a, f"33 LABELGUI_LIVE_TEST_PROTECTED_PREFIX=合成图目录：crop=face → source preview + protected_location，"
                    f"max_edge 1568 → 1024 预览；原图打开记录 0、sandbox 里没被杀 {info_a}")
        fh = os.path.join(WORK, "F33-home")
        desk = os.path.join(fh, "Desktop", "syn")
        shutil.copytree(syn["dir"], desk)
        syn_d = synth_session("desk", photos_dir=desk)
        ok_b, info_b = protected_case("F33-desk", desk, syn_d["data"], {"CFFIXED_USER_HOME": fh, "HOME": fh})
        check(ok_b, f"33 照片在（假的家目录的）~/Desktop 下：同上，按真正的 ProtectedPaths 判成受保护 {info_b}")
        if os.access(sandbox, os.X_OK):
            hc = Host("F33-ctl", data=fresh_copy(syn["data"], "F33c"), photos=syn["dir"], args=("--no-view",),
                      wrap=[sandbox, "-p", deny_originals(syn["dir"])])
            up = hc.alive() and hc.bridge == "on"
            mcp_call(hc.env(LABELGUI_MCP_OUT=out), "cull_preview_photos", {"session": sk, "ids": [syn["ids"][3]], "crop": "face"})
            time.sleep(0.3)
            rc_c = hc.proc.poll()
            hc.term()
            check(up and rc_c == -signal.SIGKILL,
                  f"（对照）同一条 sandbox 规则、不当受保护：宿主起得来（{up}），crop=face 去读原图 → 宿主被杀（{rc_c}）")
        # 33 的 app_open_session 那一半（切到受保护前缀下的场次 → protected_location）在 G 组

        # ---------- collage_get_state：带预览（本地 photot 用 STEP 0 有拼图工程的那份数据；CI 没有，只看没有预览时的 warning）
        seeded = COLLAGE_SRC
        if seeded and not CI:
            hc = Host("F-collage", data=fresh_copy(seeded, "Fc"))
            envc = hc.env(LABELGUI_MCP_OUT=out)
            # 预览是 app 在后台渲的：宿主刚起来时可能还没有（warning no_preview，「过一秒再调」），等它出来
            tries = 0
            while True:
                tries += 1
                res, cs, ms = mcp_full(envc, "collage_get_state")
                if (cs or {}).get("preview") or tries >= 20:
                    break
                time.sleep(0.3)
            pv = (cs or {}).get("preview") or {}
            blk = image_blocks(res)
            check(cs and cs.get("pages", 0) >= 1 and len(blk) == 1 and blk[0][:2] == b"\xff\xd8"
                  and max(pv.get("width", 0), pv.get("height", 0)) <= 768 and pv.get("file", "").endswith("-collage.jpg")
                  and open(pv["file"], "rb").read() == blk[0] and cs.get("digest") == state(hc).get("edit_digest")
                  and len(cs.get("cells") or []) >= 1 and "preview_jpeg_b64" not in cs,
                  f"collage_get_state：{cs and cs.get('pages')} 页、{len((cs or {}).get('cells') or [])} 格，预览长边 ≤ 768、"
                  f"存成 …-collage.jpg，digest = test.state 的 edit_digest（第 {tries} 次有预览，{ms:.0f} ms）")
            res, cs2, _ = mcp_full(envc, "collage_get_state", {"include_preview": False})
            check(not image_blocks(res) and "preview" not in (cs2 or {}), "include_preview:false：没有图")
            hc.term()
        else:
            skip("collage_get_state 的预览：要一份有拼图工程的数据（本地给 --collage-data），CI 只看没有预览时的 warning")
            hc = Host("F-collage0")
            _, cs, _ = mcp_call(hc.env(LABELGUI_MCP_OUT=out), "collage_get_state")
            check(cs and cs.get("pages") == 0 and "no_preview" in [w.get("code") for w in cs.get("warnings") or []]
                  and "digest" in cs and cs.get("undo", {}).get("top_is_ai") is False,
                  "collage_get_state 没有拼图：pages 0、warning no_preview、有 digest、top_is_ai false")
            hc.term()

    # ============================================================ G. 写（STEP 3b）
    if "G" in ONLY:
        print("G. 写")
        gdata = fresh_data("G")
        prot_root = os.path.join(WORK, "受保护")
        prot_dir = os.path.join(prot_root, "某一场")
        unlisted = os.path.join(WORK, "没登记的文件夹")
        for d_ in (prot_dir, unlisted):
            os.makedirs(d_)
        # 第 8 条要切过去的那一场、第 33 条的受保护的那一场都得先登记在「最近场次」里（§10.4：v1 只能打开那里面的）。
        # 再加一场有分析结果的合成图场次（bookmark 那条：打开一次 app 才给它建 bookmark，之后把文件夹挪进受保护前缀）
        bm_dir = os.path.join(BM_LINK, "书签那一场")
        bm = synth_session("G-bm", photos_dir=bm_dir)
        shutil.copytree(os.path.join(bm["data"], "sessions", bm["key"]), os.path.join(gdata, "sessions", bm["key"]))
        register_sessions(gdata, [EMPTY_PHOTOS, prot_dir, bm_dir])
        EMPTY_KEY, PROT_KEY, BM_KEY = session_key_of(EMPTY_PHOTOS), session_key_of(prot_dir), bm["key"]
        h = Host("G", data=gdata, LABELGUI_LIVE_TEST_PROTECTED_PREFIX=prot_root)
        env = h.env()

        def st():
            return state(h)

        def steps(a, b):
            """两次 test.state 之间（判决栈, 拼图栈）各压了几步：只增不减的 push 计数（§9.5.1）。"""
            return (b["verdict_undo"]["pushes"] - a["verdict_undo"]["pushes"],
                    b["collage_undo"]["pushes"] - a["collage_undo"]["pushes"])

        def settled(timeout=60):
            """等路人信息算完（整工程指纹只在这之后比，§9.8.3）。"""
            deadline = time.monotonic() + timeout * SLACK
            s_ = st()
            while s_.get("hints_pending") and time.monotonic() < deadline:
                time.sleep(0.2)
                s_ = st()
            return s_

        def w(tool, args, timeout=60):
            out_, body_, ms_ = mcp_full(env, tool, args, timeout)
            return out_, body_ or {}, ms_

        def one_jpeg(out_):
            blk = image_blocks(out_)
            return len(blk) == 1 and blk[0][:2] == b"\xff\xd8"

        def mtime(p_):
            return os.stat(p_).st_mtime_ns if os.path.exists(p_) else None

        _, rows, _ = mcp_call(env, "cull_list_photos", {"session": KEY, "sort": "id", "limit": 100})
        rows = (rows or {}).get("rows") or []
        vid = next(r["id"] for r in rows if r["verdict"] != "pick" and not r.get("manual"))
        ids2 = [rows[0]["id"], rows[1]["id"]]

        # ---------- 第 3 条 改判：一步判决撤销、overrides.json 回复到达时已经写好、再发一次不动；app_undo 逐字节回去
        s0 = settled()
        ov_path = os.path.join(gdata, "sessions", KEY, "overrides.json")
        m0 = mtime(ov_path)
        _, b, ms = w("cull_set_verdicts", {"session": KEY, "ids": [vid, "NOPE-9"], "verdict": "pick"})
        m1 = mtime(ov_path)
        s1 = st()
        disk = json.load(open(ov_path)) if os.path.exists(ov_path) else {}
        check(b.get("changed") == [vid] and b.get("missing_ids") == ["NOPE-9"] and b.get("undo", {}).get("target") == "verdicts"
              and b["undo"].get("steps_added") == 1 and b["undo"].get("depth") == s0["verdict_undo"]["depth"] + 1
              and steps(s0, s1) == (1, 0) and s1["overrides"].get(vid) == "pick" and vid in s1["manual"]
              and m1 is not None and m1 != m0 and disk.get(vid) == "精选" and b.get("collage_tray_refreshed") is True
              and re.match(r"^[0-9a-f-]{36}$", b.get("live", {}).get("op_id") or "") and b["live"].get("replayed") is False
              and b["live"].get("tab") == "batch" and (s1.get("external_notice") or "").startswith("AI："),
              f"3 改判 {vid} → pick：判决栈 +1、拼图栈不动，overrides.json 回复到达时已写好，live.op_id 是这一次的（{ms:.0f} ms）")
        _, b2, _ = w("cull_set_verdicts", {"session": KEY, "ids": [vid], "verdict": "pick"})
        s2 = st()
        check(b2.get("changed") == [] and b2.get("unchanged") == [vid] and b2.get("undo", {}).get("steps_added") == 0
              and steps(s1, s2) == (0, 0), "同一个改判再发一次（新 op_id）：changed []、steps_added 0，两条栈都没动")
        _, u, _ = w("app_undo", {"target": "verdicts"})
        s3 = st()
        check(u.get("ids") == [vid] and s3["verdict_digest"] == s0["verdict_digest"] and s3["overrides"] == s0["overrides"]
              and s3["verdict_undo"]["depth"] == s0["verdict_undo"]["depth"] and steps(s2, s3) == (0, 0),
              "app_undo target=verdicts：判决逐字节回到改判之前（verdict_digest），撤销不压栈")
        _, u2, _ = w("app_undo", {"target": "verdicts"})
        check(err_code(u2) == "nothing_to_undo" and edata(u2).get("reason") == "already_undone", f"再撤 → nothing_to_undo（{edata(u2)}）")

        # ---------- 第 4、37 条 套模板：一步拼图撤销、collage.json 回复到达时已写好、带预览；三种写法找到的模板对
        _, lt, _ = mcp_call(env, "collage_list_templates", {"include": ["templates"]})
        tpls = (lt or {}).get("templates") or []
        cats = []
        for t_ in tpls:
            if t_["category"] not in cats:
                cats.append(t_["category"])
        names = [t_["name"] for t_ in tpls]
        full, full2 = names[2], names[5]
        cat = cats[1]
        want_cat = next(t_["name"] for t_ in tpls if t_["category"] == cat)
        frag = next(n_[1:3] for n_ in names[7:] if len(n_) >= 3 and n_[1:3] not in names and n_[1:3] not in cats)
        want_frag = next(n_ for n_ in names if frag in n_)
        cj = os.path.join(gdata, "sessions", KEY, "collage.json")
        s0 = settled()
        c0 = mtime(cj)
        out, b, ms = w("collage_apply_template", {"session": KEY, "template": full})
        c1 = mtime(cj)
        s1 = st()
        pv = b.get("preview") or {}
        check(b.get("template") == full and b.get("changed") is True and b.get("digest_before") == s0["edit_digest"]
              and b.get("digest_after") == s1["edit_digest"] != s0["edit_digest"] and steps(s0, s1) == (0, 1)
              and b.get("undo", {}).get("steps_added") == 1 and b["undo"].get("depth") == s0["collage_undo"]["depth"] + 1
              and c1 is not None and c1 != c0 and s1["disk_edit_digest"] == s1["edit_digest"]
              and one_jpeg(out) and (pv.get("file") or "").endswith("-collage.jpg") and max(pv.get("width", 0), pv.get("height", 0)) <= 768
              and (s1["collage"].get("notice") or "").startswith("AI：已套用"),
              f"4 套模板「{full}」：拼图栈 +1、判决栈不动，collage.json 回复到达时已写好（盘上的编辑指纹 = 内存的），"
              f"带一张 ≤768 的预览，状态栏「AI：已套用…」（{ms:.0f} ms）")
        out_u, u, _ = w("app_undo", {"target": "collage"})
        s2 = settled()
        # 撤回去的工程一页都没有（CI 的 fixture、没排过的场次）就没有预览
        pv_ok = one_jpeg(out_u) if s0["collage"]["pages"] > 0 else (not image_blocks(out_u) and "no_preview" in warn_codes(u))
        check(u.get("digest_after") == s0["edit_digest"] and s2["edit_digest"] == s0["edit_digest"]
              and s2["full_digest"] == s0["full_digest"] and s2["disk_edit_digest"] == s0["edit_digest"]
              and s2["collage_undo"]["depth"] == s0["collage_undo"]["depth"] and s2["collage_undo"]["can_redo"] is True
              and steps(s1, s2) == (0, 0) and pv_ok,
              f"app_undo target=collage：编辑指纹、整工程指纹、盘上的 collage.json 都回到套模板之前，重做栈里有它"
              f"（{s0['collage']['pages']} 页的工程{'，回复带预览' if s0['collage']['pages'] else '，没有预览、warning no_preview'}）"
              f" {[u.get('digest_after') == s0['edit_digest'], s2['edit_digest'] == s0['edit_digest'], s2['full_digest'] == s0['full_digest'], s2['disk_edit_digest'] == s0['edit_digest'], s2['collage_undo'], s0['collage_undo'], pv_ok]}")
        got37 = []
        for label, spelling, want in (("分类名", cat, want_cat), ("全名", full2, full2), ("名字片段", frag, want_frag)):
            _, b, _ = w("collage_apply_template", {"session": KEY, "template": spelling})
            got37.append((label, spelling, b.get("template"), want))
            w("app_undo", {"target": "collage"})
        _, bad, _ = w("collage_apply_template", {"session": KEY, "template": "没有这个模板-xyz"})
        check(all(g_ == w_ for _, _, g_, w_ in got37) and err_code(bad) == "invalid_argument",
              f"37 找模板：分类名套这个分类的第一个、全名、名字片段，和 collage_list_templates 的顺序推出来的一样；找不到 → "
              f"invalid_argument {got37}")

        # ---------- 第 5、6 条 不合并、撤销按 tab；没改出东西的写不挡后面的 app_undo
        s0 = st()
        _, a1, _ = w("collage_set_text", {"session": KEY, "title": "标题 A"})
        time.sleep(0.2)
        _, a2, _ = w("collage_set_text", {"session": KEY, "masthead": "刊头 B"})
        s1 = st()
        check(steps(s0, s1) == (0, 2) and s1["collage"]["title"] == "标题 A" and s1["collage"]["masthead"] == "刊头 B"
              and a2.get("live", {}).get("tab") == "batch" and "拼图页" in a2.get("undo", {}).get("how", ""),
              "5 改标题、200 ms 后改刊头：两步（不并成一步）；6 用户停在批量页，undo.how 点名拼图页")
        _, u, _ = w("app_undo", {"target": "collage"})
        s2 = st()
        check(s2["collage"]["title"] == "标题 A" and s2["collage"]["masthead"] == s0["collage"]["masthead"],
              "app_undo 只撤掉刊头，标题还在（6：用户停在批量页也照样撤拼图）")
        _, a3, _ = w("collage_set_text", {"session": KEY, "title": "标题 C", "masthead": "刊头 D"})
        _, a4, _ = w("collage_set_text", {"session": KEY, "title": "标题 C", "masthead": "刊头 D"})
        s3 = st()
        _, u, _ = w("app_undo", {"target": "collage"})
        s4 = st()
        check(steps(s2, s3) == (0, 2) and s3["collage_undo"]["depth"] == s2["collage_undo"]["depth"] + 1
              and a4.get("changed") is False and a4.get("undo", {}).get("steps_added") == 0 and "error" not in u
              and s4["collage"]["title"] == "标题 A",
              "同一个请求改标题和刊头：一步；原样再发一次 changed:false（空步撤掉了，计数 +1），紧接着的 app_undo 照样撤的是 AI 那一步")

        # ---------- 换样式：样式、色调、强度一次给齐也是一步；app_undo 编辑指纹回去
        _, sty, _ = mcp_call(env, "collage_list_templates", {"include": ["styles", "looks"]})
        style_key = ((sty or {}).get("styles") or [{}, {}])[1].get("key")
        look_key = ((sty or {}).get("looks") or [{}])[-1].get("key")
        s0 = settled()
        out, b, _ = w("collage_set_style", {"session": KEY, "style": style_key, "look": look_key, "look_strength": 0.35})
        s1 = st()
        _, u, _ = w("app_undo", {"target": "collage"})
        s2 = settled()
        check(b.get("changed") is True and b.get("style") == style_key and b.get("look") == look_key and b.get("look_strength") == 0.35
              and steps(s0, s1) == (0, 1) and s1["collage"]["look"] == look_key and s1["disk_edit_digest"] == s1["edit_digest"]
              and "error" not in u and s2["edit_digest"] == s0["edit_digest"] and s2["full_digest"] == s0["full_digest"]
              and s2["disk_edit_digest"] == s0["edit_digest"],
              f"换样式「{style_key}」+ 色调「{look_key}」+ 强度 0.35：一步；app_undo 以后编辑指纹、整工程指纹、collage.json 都回去")

        # ---------- 第 7 条 不是 AI 的那一步不撤；用户自己撤过 → already_undone_by_user；top_is_ai
        _, t1, _ = w("collage_apply_template", {"session": KEY, "template": full})
        _, cs1, _ = mcp_call(env, "collage_get_state", {"include_preview": False})
        test_call(h, "test.user_edit", {"op": "setTitle", "text": "用户自己的标题"})
        _, cs2, _ = mcp_call(env, "collage_get_state", {"include_preview": False})
        sa = st()
        _, u, _ = w("app_undo", {"target": "collage"})
        sb = st()
        check(cs1.get("undo", {}).get("top_is_ai") is True and cs2.get("undo", {}).get("top_is_ai") is False
              and err_code(u) == "undo_not_ours" and sb["collage_undo"]["depth"] == sa["collage_undo"]["depth"]
              and sb["edit_digest"] == sa["edit_digest"],
              "7 AI 套模板 → 用户改标题 → app_undo：undo_not_ours，深度没变（top_is_ai 先 true 后 false）")
        w("collage_apply_template", {"session": KEY, "template": full2})
        test_call(h, "test.user_edit", {"op": "undo"})
        _, u, _ = w("app_undo", {"target": "collage"})
        check(err_code(u) == "nothing_to_undo" and edata(u).get("reason") == "already_undone_by_user",
              f"用户自己 ⌘Z 撤过 AI 那一步 → nothing_to_undo（{edata(u).get('reason')}）")

        # ---------- 第 12 条 op_id 重放：第二次 replayed、只做一次，缓存的结果不带预览
        op = "g12-" + uuid.uuid4().hex[:12]
        s0 = st()
        out1, r1, _ = w("collage_set_text", {"session": KEY, "subtitle": "副标题 X", "op_id": op})
        out2, r2, _ = w("collage_set_text", {"session": KEY, "subtitle": "副标题 X", "op_id": op})
        s1 = st()
        check(r1.get("live", {}).get("op_id") == op and r1.get("changed") is True and r2.get("replayed") is True
              and r2.get("live", {}).get("replayed") is True and r2.get("changed") is True and steps(s0, s1) == (0, 1)
              and one_jpeg(out1) and not image_blocks(out2) and "preview_omitted" in warn_codes(r2)
              and r2.get("digest_after") == r1.get("digest_after"),
              "12 同一个 op_id 发两次：第二次 replayed:true（live 里也是）、拼图栈只 +1；缓存的结果不带预览、有 preview_omitted")

        # ---------- 第 11 条 过期：主线程卡着，300 ms 截止的写回 expired、没执行
        r = Raw(h)
        r.req("test.block_main", {"ms": 1500})
        time.sleep(0.1)
        r2_ = Raw(h)
        m_ = r2_.call("collage.set_text", {"session": KEY, "title": "过期的"}, deadline=300, op_id="g11-" + uuid.uuid4().hex[:12])
        r.recv()
        r.close()
        r2_.close()
        check(err_code(m_) == "expired" and (m_["error"].get("data") or {}).get("executed") is False
              and st()["collage"]["title"] != "过期的", "11 主线程卡 1.5 s、300 ms 截止的写：expired，没执行")

        # ---------- 第 10、26 条 忙信号：一时的等（等不到 → user_busy transient），一直的立刻回；读不受影响
        test_call(h, "test.set_busy", {"reasons": ["pointer"], "ms": 5000})
        _, rd, rd_ms = mcp_call(env, "collage_get_state", {"include_preview": False})
        s0 = st()
        _, b, ms = w("collage_set_text", {"session": KEY, "title": "按着鼠标的时候"})
        s1 = st()
        test_call(h, "test.set_busy", {"reasons": ["pointer"], "ms": 0})
        d_ = edata(b)
        check(err_code(b) == "user_busy" and d_.get("transient") is True and d_.get("executed") is False
              and d_.get("reasons") == ["pointer"] and 1800 <= d_.get("waited_ms", 0) <= 2600 and s1["edit_digest"] == s0["edit_digest"]
              and steps(s0, s1) == (0, 0) and "error" not in rd and rd_ms < 1500,
              f"10 按着鼠标 5 s：写等了 {d_.get('waited_ms')} ms 回 user_busy（transient、executed:false），指纹没变；读照常（{rd_ms:.0f} ms）")
        for reason, ms_busy in (("dragging", 800), ("typing", 600), ("menu", 500), ("continuous_edit", 700)):
            test_call(h, "test.set_busy", {"reasons": [reason], "ms": ms_busy})
            t0 = time.monotonic()
            _, b, _ = w("collage_set_text", {"session": KEY, "title": f"等 {reason} 停了以后"})
            took = (time.monotonic() - t0) * 1000
            check(b.get("changed") is True and took >= ms_busy * 0.8 and st()["collage"]["title"] == f"等 {reason} 停了以后",
                  f"{reason} {ms_busy} ms：写等它停了再执行（{took:.0f} ms）")
        test_call(h, "test.set_busy", {"reasons": ["continuous_edit"], "ms": 5000})
        t0 = time.monotonic()
        _, bv, _ = w("cull_set_verdicts", {"session": KEY, "ids": [vid], "verdict": "reject"})
        v_ms = (time.monotonic() - t0) * 1000
        rr = Raw(h)
        busy_raw = rr.call("collage.set_text", {"session": KEY, "title": "x", "busy_wait_ms": 300}, op_id="g10-" + uuid.uuid4().hex[:12])
        rr.close()
        test_call(h, "test.set_busy", {"reasons": ["continuous_edit"], "ms": 0})
        check(bv.get("changed") == [vid] and v_ms < 1500 and err_code(busy_raw) == "user_busy"
              and (busy_raw["error"].get("data") or {}).get("waited_ms", 0) >= 250,
              f"连续编辑只挡拼图写：改判照常（{v_ms:.0f} ms）；拼图写按请求的 busy_wait_ms=300 等完回 user_busy")
        persistent = [("modal", "collage_set_text", {"title": "对话框"}, True),
                      ("batch_viewing", "cull_set_verdicts", {"ids": [vid], "verdict": "usable"}, False),
                      ("batch_viewing", "cull_show_photos", {"ids": [vid]}, True),
                      ("pick_session", "cull_set_verdicts", {"ids": [vid], "verdict": "pick"}, True),
                      ("pick_session", "app_undo", {"target": "verdicts"}, True),
                      ("pick_session", "collage_set_text", {"title": "挑连拍的时候改拼图"}, False),
                      ("batch_sheet", "app_open_session", {"session": EMPTY_KEY, "confirm": True}, True),
                      ("crop_editing", "collage_set_style", {"look_strength": 0.4}, True),
                      ("exporting", "collage_run_kit", {"kit": "contactRoll"}, True)]
        got26 = []
        for reason, tool, args, blocked in persistent:
            test_call(h, "test.set_busy", {"reasons": [reason], "ms": 5000})
            a_ = dict(args)
            if tool not in ("app_undo", "app_open_session"):
                a_["session"] = KEY
            t0 = time.monotonic()
            _, b, _ = w(tool, a_)
            took = (time.monotonic() - t0) * 1000
            test_call(h, "test.set_busy", {"reasons": [reason], "ms": 0})
            d_ = edata(b)
            ok_ = (err_code(b) == "user_busy" and d_.get("transient") is False and d_.get("waited_ms") == 0 and took < 1000
                   and reason in d_.get("reasons", [])) if blocked else ("error" not in b or err_code(b) != "user_busy")
            got26.append((reason, tool, ok_, err_code(b), round(took)))
        check(all(x[2] for x in got26),
              f"26 一直的原因不等：对话框挡全部写，审片 / 检视器不挡改判、挡定位照片，连拍挑选挡判决和撤判决、不挡拼图，"
              f"批量页 sheet 挡切场次，裁切、导出挡拼图（都 <1 s、transient:false、waited_ms 0）{got26}")
        w("app_undo", {"target": "collage"})      # 「挑连拍的时候改拼图」那一步

        # ---------- 第 29 条 窗口看不见：照常成功，window_visible:false + warning
        test_call(h, "test.set_window_state", {"state": "minimized"})
        _, b, _ = w("collage_set_text", {"session": KEY, "issue": "No.7"})
        test_call(h, "test.set_window_state", {"state": "visible"})
        check(b.get("changed") is True and b.get("live", {}).get("window_visible") is False
              and b["live"].get("window_state") == "minimized" and "window_not_visible" in warn_codes(b),
              "29 窗口最小化：写照常成功，live.window_visible:false、window_state minimized，warning 说用户现在看不到")

        # ---------- cull_show_photos：选中、焦点；用户停在别的页时 pending，回到批量页时补上
        # CI 用 --no-view 时没有批量页来消费：每次都是 pending:true、请求留在 store 里（等于用户一直没切过来），消费的那一半看本地
        s0 = st()
        _, b, _ = w("cull_show_photos", {"session": KEY, "ids": ids2 + ["NOPE-1"]})
        s1 = st()
        consumed = (b.get("applied") is True and b.get("selected") == ids2 and b.get("focus") == ids2[0]
                    and b.get("hidden_by_filter") == [] and s1.get("view_request") is None)
        waiting = (b.get("applied") is False and b.get("pending") is True and b.get("focus") == ids2[0]
                   and s1.get("view_request") == {"ids": ids2, "select": True})
        check((consumed if VIEW else waiting)
              and b.get("missing_ids") == ["NOPE-1"] and b.get("live", {}).get("tab") == "batch" and steps(s0, s1) == (0, 0),
              f"cull_show_photos：{'批量页消费掉了（applied、selected、focus）' if VIEW else '没有批量页（--no-view）：pending:true、请求留着'}，"
              f"不存在的进 missing_ids，不进撤销 { {k: b.get(k) for k in ('applied', 'pending', 'selected', 'focus', 'hidden_by_filter')} }")
        w("collage_set_text", {"session": KEY, "title": "切到拼图页", "reveal": True})
        _, b, _ = w("cull_show_photos", {"session": KEY, "ids": [ids2[1]], "mode": "focus", "reveal": False})
        s2 = st()
        test_call(h, "test.snapshot", {"tab": "批量处理", "name": "g-show-back", "wait_ms": 500})
        s3 = st()
        # 停在拼图页时 TabView 不一定把批量页拿掉：消费掉了就是 applied（等用户切回来看到的就是选好的），没消费就是 pending，
        # 切回批量页时 onAppear 补上。两种都对，最后都要落到那一张上
        now_ok = b.get("applied") is True and s2.get("view_request") is None
        later_ok = b.get("applied") is False and b.get("pending") is True and s2.get("view_request") == {"ids": [ids2[1]], "select": False}
        check(((now_ok or later_ok) if VIEW else later_ok) and b.get("live", {}).get("tab") == "collage" and b.get("mode") == "focus",
              f"reveal:false 而用户停在拼图页：不切 tab；{'当场消费了（TabView 留着批量页）' if now_ok else 'pending:true，请求留着'}")
        view_check(s3.get("view_request") is None and (s3.get("view_applied") or {}).get("focus") == ids2[1]
                   and (s3.get("view_applied") or {}).get("selected") == [],
                   "切回批量页以后落到那一张上：mode=focus 只移焦点不改选中")

        # ---------- 第 25 条 等用户停手的时候用户切了场次 → session_not_open（没执行）；成套途中切场次 / 改版式 → superseded
        sv0 = st()
        test_call(h, "test.set_busy", {"reasons": ["pointer"], "ms": 1500})
        res = {}
        th = threading.Thread(target=lambda: res.update(v=w("cull_set_verdicts", {"session": KEY, "ids": [vid], "verdict": "pick"})))
        th.start()
        time.sleep(0.5)
        test_call(h, "test.switch_session", {"photo_dir": EMPTY_PHOTOS})
        th.join(30)
        se = st()
        test_call(h, "test.set_busy", {"reasons": ["pointer"], "ms": 0})
        test_call(h, "test.switch_session", {"photo_dir": PHOTO_DIR})
        sb = st()
        b = res.get("v", (None, {}, 0))[1]
        check(err_code(b) == "session_not_open" and edata(b).get("reason") == "session_switched_while_waiting"
              and edata(b).get("executed") is False and se["overrides"] == {} and sb["overrides"] == sv0["overrides"],
              f"25 等用户停手的 2 s 里用户切了场次：session_not_open（{edata(b).get('reason')}），两场的判决都没动 "
              f"{[b, se['overrides'], sb['overrides'] == sv0['overrides']]}")
        for who, act in (("session_switched", lambda: test_call(h, "test.switch_session", {"photo_dir": EMPTY_PHOTOS})),
                         ("user_edit", lambda: test_call(h, "test.user_edit", {"op": "applyTemplate", "template": full}))):
            s0 = st()
            test_call(h, "test.delay_next", {"ms": 1500})
            res = {}
            th = threading.Thread(target=lambda: res.update(v=w("collage_run_kit", {"session": KEY, "kit": "fashionIssue"}, 120)))
            th.start()
            time.sleep(0.8)
            act()
            th.join(120)
            b = res.get("v", (None, {}, 0))[1]
            s1 = st()
            _, u, _ = w("app_undo", {"target": "collage"})
            s2 = st()
            if who == "session_switched":
                test_call(h, "test.switch_session", {"photo_dir": PHOTO_DIR})
            # 作废的成套不记 AI 的一步（ai_log 没多），之后 app_undo → nothing_to_undo(session_switched)：前面切过场次，AI 之前的
            # 记录都不算了（§9.5.1）。切场次的那一次停在新场次上、两条栈都是空的；改版式的那一次栈顶是用户套模板那一步，没被撤
            if who == "session_switched":
                where = (s1["session"] == EMPTY_KEY and s1["verdict_undo"]["depth"] == 0 and s1["collage_undo"]["depth"] == 0
                         and steps(s0, s1) == (0, 0))
            else:
                where = s1["session"] == s0["session"] and steps(s0, s1) == (0, 1)
            ok_ = (err_code(b) == "superseded" and edata(b).get("reason") == who and edata(b).get("executed") is False
                   and err_code(u) == "nothing_to_undo" and edata(u).get("reason") == "session_switched"
                   and s2["collage_undo"] == s1["collage_undo"] and where
                   and len(s1["ai_log"]["collage"]) == len(s0["ai_log"]["collage"]))
            check(ok_, f"25 成套落地之前（test.delay_next 拖住）{'用户切了场次' if who == 'session_switched' else '用户套了别的模板'}："
                       f"superseded（{edata(b).get('reason')}），没落地、不记 AI 的一步，之后 app_undo → {err_code(u)}"
                       f"（{edata(u).get('reason')}），栈没动")

        # ---------- 第 36 条 用户切到别的场次以后：带旧场次的写都 session_not_open，app_undo → nothing_to_undo
        test_call(h, "test.switch_session", {"photo_dir": EMPTY_PHOTOS})
        codes36 = [err_code(w(t_, dict(a_, session=KEY))[1]) for t_, a_ in (
            ("cull_set_verdicts", {"ids": [vid], "verdict": "pick"}), ("cull_show_photos", {"ids": [vid]}),
            ("collage_apply_template", {"template": full}), ("collage_run_kit", {"kit": "fashionIssue"}),
            ("collage_next_cover", {}), ("collage_set_text", {"title": "x"}), ("collage_set_style", {"look_strength": 0.3}))]
        _, u1, _ = w("app_undo", {"target": "collage"})
        _, u2, _ = w("app_undo", {"target": "verdicts"})
        test_call(h, "test.switch_session", {"photo_dir": PHOTO_DIR})
        check(set(codes36) == {"session_not_open"} and err_code(u1) == "nothing_to_undo" and err_code(u2) == "nothing_to_undo",
              f"36 用户切走以后：7 个带旧场次的写都 session_not_open，app_undo 两边都 nothing_to_undo {codes36}")

        # ---------- 第 8、33 条 app_open_session：撤销栈不空先 confirm_required；带 confirm 才切；受保护的那一场拒绝，不去碰它
        w("collage_set_text", {"session": KEY, "title": "切场次之前"})
        w("cull_set_verdicts", {"session": KEY, "ids": [vid], "verdict": "reject"})
        s0 = st()
        _, c, _ = w("app_open_session", {"session": EMPTY_KEY})
        s1 = st()
        check(err_code(c) == "confirm_required" and edata(c).get("verdict_undo_steps") == s0["verdict_undo"]["depth"] > 0
              and edata(c).get("collage_undo_steps") == s0["collage_undo"]["depth"] > 0 and s1["session"] == KEY,
              f"8 撤销栈不空：confirm_required（判决 {edata(c).get('verdict_undo_steps')} 步、拼图 {edata(c).get('collage_undo_steps')} 步），没切")
        _, o, _ = w("app_open_session", {"session": EMPTY_PHOTOS, "confirm": True})
        s2 = st()
        _, u1, _ = w("app_undo", {"target": "collage"})
        _, u2, _ = w("app_undo", {"target": "verdicts"})
        check(o.get("opened") is True and o.get("session") == EMPTY_KEY and o.get("verdict_undo_cleared") == s0["verdict_undo"]["depth"]
              and o.get("collage_undo_cleared") == s0["collage_undo"]["depth"] and s2["session"] == EMPTY_KEY
              and s2["verdict_undo"]["depth"] == 0 and s2["collage_undo"]["depth"] == 0 and EMPTY_PHOTOS in s2["ai_log"]["opened"]
              and edata(u1).get("reason") == "session_switched" and edata(u2).get("reason") == "session_switched",
              "带 confirm:true（路径写法）：切过去，清掉的步数对得上；之后 app_undo 两边都 nothing_to_undo（session_switched）")
        _, ao, _ = w("app_open_session", {"session": EMPTY_KEY})
        _, nf, _ = w("app_open_session", {"session": unlisted})
        sp0 = st()
        _, pk, _ = w("app_open_session", {"session": PROT_KEY, "confirm": True})
        _, pp, _ = w("app_open_session", {"session": prot_dir, "confirm": True})
        sp1 = st()
        check(ao.get("opened") is False and ao.get("already_open") is True and err_code(nf) == "session_not_found",
              "已经是当前这一场 → already_open；不在「最近场次」里 → session_not_found")
        check(err_code(pk) == "protected_location" and err_code(pp) == "protected_location" and sp1["session"] == sp0["session"]
              and prot_dir not in sp1["ai_log"]["opened"] and sp1["verdict_undo"] == sp0["verdict_undo"]
              and sp1["collage_undo"] == sp0["collage_undo"],
              "33 受保护前缀下的那一场（key / 路径两种写法）→ protected_location：只按字符串判断，没走到 switchSession，场次和两条栈都没动")
        # --mcp 自己先按字符串挡（§10.4 第 4 条）：真实家目录下的桌面路径，只是字符串 —— 这个文件夹不存在，脚本也不去
        # stat 它（那会以终端的名义碰桌面）。它不在「最近场次」里，app 那边只会回 session_not_found，所以回 protected_location
        # 的只能是 --mcp 的预检；宿主的场次、桥切过的场次都没变
        desk = os.path.join(HOME, "Desktop", "xuanpian-live-smoke-never-" + uuid.uuid4().hex[:8])
        _, pd, _ = w("app_open_session", {"session": desk, "confirm": True})
        sp2 = st()
        check(err_code(pd) == "protected_location" and edata(pd).get("folder") == desk and sp2["session"] == sp1["session"]
              and sp2["ai_log"]["opened"] == sp1["ai_log"]["opened"],
              "--mcp 的预检：~/Desktop 下的路径（只是字符串）→ protected_location（data.folder 是它），没转给 app 去切")
        # bookmark 不能把 app 带进受保护位置：AI 打开过一次的场次（这时 app 给它建了 bookmark），文件夹之后被挪进受保护前缀，
        # AI 再打开它 —— app 只认登记的那个路径（字符串检查过的），不跟 bookmark 走；挪走了就是「照片文件夹已不存在」（app_says）
        _, o1, _ = w("app_open_session", {"session": BM_KEY, "confirm": True})
        _, o2, _ = w("app_open_session", {"session": EMPTY_KEY, "confirm": True})
        moved_to = os.path.join(prot_root, os.path.basename(bm_dir))
        os.rename(os.path.realpath(bm_dir), moved_to)
        _, o3, _ = w("app_open_session", {"session": BM_KEY, "confirm": True})
        _, ast, _ = mcp_call(env, "app_status")
        open_now = ((ast or {}).get("live") or {}).get("open_session") or {}
        check(o1.get("opened") is True and o2.get("opened") is True and o3.get("opened") is True
              and o3.get("folder") == bm_dir and open_now.get("folder") == bm_dir and open_now.get("session") == BM_KEY
              and "app_says" in warn_codes(o3) and not os.path.exists(bm_dir),
              f"33 打开过一次（建了 bookmark）、之后挪进受保护前缀的场次：AI 再打开，app 停在登记的路径上（{open_now.get('folder')}），"
              f"不跟 bookmark 进 {moved_to}；回复带 app_says（文件夹已不存在）")
        _, back, _ = w("app_open_session", {"session": KEY})
        check(back.get("opened") is True and st()["session"] == KEY, "空场次的撤销栈是空的：不用 confirm 直接切回来")

        # ---------- 第 9、27 条 一键成套、换封面（本地 photot：要真照片；CI 的 fixture 只跑得到 invalid_state 那一半）
        _, nc, _ = w("collage_next_cover", {"session": KEY})
        check(err_code(nc) == "invalid_state", f"9 不是出一期的工程上换封面 → invalid_state（{err_code(nc)}）")
        if not CI:
            s0 = settled()
            out, k, ms = w("collage_run_kit", {"session": KEY, "kit": "fashionIssue"}, 180)
            s1 = st()
            cover1 = k.get("cover_id")
            check(k.get("landing") == "landed" and k.get("pages") == 4 and cover1 and k.get("hints_settled") is True
                  and steps(s0, s1) == (0, 1) and one_jpeg(out) and s1["disk_edit_digest"] == s1["edit_digest"]
                  and s1["collage"]["cover_id"] == cover1,
                  f"9 collage_run_kit fashionIssue：4 页、封面 {cover1}、拼图栈 +1、带预览、collage.json 已写好（{ms:.0f} ms）")
            hk2 = Host("G-kit2", data=fresh_data("G-kit2"), args=("--no-view",))
            _, k2, _ = mcp_full(hk2.env(), "collage_run_kit", {"session": KEY, "kit": "fashionIssue"}, 180)
            hk2.term()
            check((k2 or {}).get("cover_id") == cover1, f"封面是确定的：另起一个宿主同样成套，封面也是 {(k2 or {}).get('cover_id')}（等路人信息算完才挑）")
            s1 = settled()
            out, n, _ = w("collage_next_cover", {"session": KEY}, 180)
            s2 = st()
            check(n.get("landing") == "landed" and n.get("cover_before") == cover1 and n.get("cover_id") not in (None, cover1)
                  and steps(s1, s2) == (0, 1) and one_jpeg(out),
                  f"collage_next_cover：封面 {cover1} → {n.get('cover_id')}，拼图栈 +1")
            w("app_undo", {"target": "collage"})
            s3 = settled()
            check(s3["collage"]["cover_id"] == cover1 and s3["edit_digest"] == s1["edit_digest"], "app_undo：封面换回来，编辑指纹回到换封面之前")
            # 27 编辑指纹：路人信息算完、改判刷新托盘都不让 if_digest 失效
            _, g, _ = mcp_call(env, "collage_get_state", {"include_preview": False})
            d0 = (g or {}).get("digest")
            cell = next((c_ for c_ in (g or {}).get("cells") or [] if c_.get("overlays", 0) > 0), None)
            s4 = settled()
            w("cull_set_verdicts", {"session": KEY, "ids": [cover1], "verdict": "usable"})
            s5 = st()
            _, ct, _ = w("collage_set_text", {"session": KEY, "if_digest": d0,
                                              "cell_text": {"path": (cell or {}).get("path", ""), "index": 0, "text": "AI 写的刊头"}})
            _, stale, _ = w("collage_set_text", {"session": KEY, "if_digest": d0, "title": "过时的 digest"})
            check(cell is not None and s4["edit_digest"] == d0 and s5["edit_digest"] == d0 and ct.get("changed") is True
                  and err_code(stale) == "stale_digest" and edata(stale).get("digest") == ct.get("digest_after"),
                  "27 编辑指纹：路人信息算完、改判刷新托盘以后不变；带原来的 if_digest 改格子里的字成功；之后再用旧的 → stale_digest")
        else:
            skip("9 成套 / 换封面、27 编辑指纹：只在本地 photot 跑（CI 的 fixture 没有照片）")

        # ---------- 第 35 条 取消一个真的写：主线程卡着时取消 → 这个 id 没有任何消息，恢复以后没执行
        s0 = st()
        m = Mcp(env)
        m.initialize()
        r = Raw(h)
        r.req("test.block_main", {"ms": 3000})
        time.sleep(0.1)
        m.call("cw", "cull_set_verdicts", {"session": KEY, "ids": [vid], "verdict": "pick"})
        time.sleep(0.3)
        m.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "cw", "reason": "test"}})
        late = m.wait_id("cw", timeout=4)
        r.recv()
        r.close()
        time.sleep(0.3)
        s1 = st()
        m.close()
        skipped = s1["counters"].get("skipped_client_gone", 0) - s0["counters"].get("skipped_client_gone", 0)
        check(late is None and s1["verdict_digest"] == s0["verdict_digest"] and steps(s0, s1) == (0, 0) and skipped >= 1,
              f"35 主线程卡着时取消一个改判：4 s 内这个 id 没有任何消息，恢复以后没执行（skipped_client_gone +{skipped}）")

        ns = st()["nsapp"]
        check(ns == {"active": False, "key_window": False, "main_window": False, "activation_policy": 2,
                     "visible_windows": 0, "host_window_visible": False, "host_window_key": False},
              f"这么多写以后，宿主仍然从不变成前台、没有 key / main 窗口：{ns}")
        h.term()

        # ---------- 第 16 条 旧版 app 少一个写方法：只有那个工具回 app_version_mismatch
        hd = Host("G-drop", LABELGUI_LIVE_TEST_DROP_CAP="collage.run_kit", args=("--no-view",))
        _, k, _ = mcp_full(hd.env(), "collage_run_kit", {"session": KEY, "kit": "fashionIssue"})
        _, t2, _ = mcp_full(hd.env(), "collage_set_text", {"session": KEY, "title": "旧版 app"})
        hd.term()
        check(err_code(k) == "app_version_mismatch" and edata(k).get("reason") == "app_too_old" and (t2 or {}).get("changed") is True,
              "16 旧版 app 少了 collage.run_kit：只有 collage_run_kit 回 app_version_mismatch（app_too_old），改字照常")

        # ---------- 第 13 条 写到一半 kill -9：app_outcome_unknown（带 op_id），之后读写都 app_not_running
        if NO_KILL:
            skip("13 kill -9：app 里的二进制不故意杀（看裸二进制那一遍）")
        else:
            hk = Host("G-kill", args=("--no-view",))
            test_call(hk, "test.delay_next", {"ms": 3000})
            res = {}
            th = threading.Thread(target=lambda: res.update(v=mcp_full(hk.env(), "collage_run_kit",
                                                                        {"session": KEY, "kit": "fashionIssue"}, 120)))
            th.start()
            time.sleep(1.0)
            hk.kill9()
            th.join(120)
            b = (res.get("v") or (None, None, 0))[1]
            st_k, _ = status(hk.env())
            _, w2, _ = mcp_call(hk.env(), "collage_set_text", {"session": KEY, "title": "x"})
            _, r2, _ = mcp_call(hk.env(), "collage_get_state", {})
            check(err_code(b) == "app_outcome_unknown" and re.match(r"^[0-9a-f-]{36}$", edata(b).get("op_id") or "")
                  and (st_k.get("live") or {}).get("state") == "not_running" and err_code(w2) == "app_not_running"
                  and err_code(r2) == "app_not_running",
                  f"13 一键成套落地之前 kill -9 宿主：app_outcome_unknown（data.op_id {edata(b).get('op_id')}），没改走别处；"
                  f"之后 not_running、读写都 app_not_running")

    # ============================================================ H. 标题栏指示、菜单开关（§9.6a、§9.8.2 第 21 条、§10.8 第 1、2、8 条）
    if "H" in ONLY:
        print("H. 标题栏指示、菜单开关")
        # 带标题栏的宿主（--titled，照样从不显示）：NSHostingView 管窗口的标题和副标题，test.state 的 window_subtitle 是 AppKit
        # 窗口上真的那个。「已连接」「刚做完」缩短成 6 s、1.5 s（§9.8.2 第 21 条：宿主认测试变量，不用干等 120 s）
        # CI 用 --no-view 时：没有窗口，window_subtitle 是 null（W()），标题栏 / 页面截图的那几条记 skip，指示的文字和状态照比
        CONN_MS, DID_MS = 6000, 1500
        hh = Host("H", args=("--titled",), LABELGUI_LIVE_TEST_CONNECTED_MS=str(CONN_MS), LABELGUI_LIVE_TEST_JUSTDID_MS=str(DID_MS))
        env = hh.env()
        defaults_h = {d: defaults_export(d) for d in ("LabelGUI", "local.culling.labelgui")}

        def ind(timeout=2):
            """(指示的文字, 状态, AppKit 窗口的副标题)。SwiftUI 把副标题交给窗口要等下一次更新：两边对上了、或者等满 timeout 才回。"""
            deadline = time.monotonic() + timeout * SLACK
            while True:
                s_ = state(hh)
                got = (s_.get("indicator"), s_.get("indicator_state"), s_.get("window_subtitle"))
                if got[0] == got[2] or not VIEW or time.monotonic() > deadline:
                    return got
                time.sleep(0.05)

        def wait_state(name, timeout=30):
            deadline = time.monotonic() + timeout * SLACK
            got = ind()
            while got[1] != name and time.monotonic() < deadline:
                time.sleep(0.05)
                got = ind()
            return got

        def chrome(name):
            r_ = test_call(hh, "test.chrome", {"name": name, "wait_ms": 300}).get("result") or {}
            return open(r_["file"], "rb").read() if r_.get("file") else None, r_

        def shot(name, tab):
            r_ = test_call(hh, "test.snapshot", {"name": name, "tab": tab, "wait_ms": 800}).get("result") or {}
            return open(r_["file"], "rb").read() if r_.get("file") else None

        # ---------- 没有 AI：副标题是空的（§10.8 第 1 条），菜单那一项打着勾；测试脚本自己连 socket 的 hello 不算
        s0 = state(hh)
        check(s0.get("indicator") == "" and s0.get("indicator_state") == "none" and s0.get("bridge_enabled") is True
              and s0.get("window_subtitle") == W("") and "标题栏指示：「」" in hh.log(),
              f"21 没有 AI：副标题空（指示「{s0.get('indicator')}」、AppKit 窗口「{s0.get('window_subtitle')}」），菜单那一项打着勾；"
              f"test.* 的裸连接不算 AI")
        c_none1, _ = chrome("h-chrome-none-1")
        c_none2, cr = chrome("h-chrome-none-2")
        b_none1, b_none2 = shot("h-batch-none-1", "批量处理"), shot("h-batch-none-2", "批量处理")
        k_none = shot("h-collage-none", "拼图")
        view_check(c_none1 is not None and c_none1 == c_none2 and b_none1 is not None and b_none1 == b_none2,
                   f"复现性：同一个状态拍两次，标题栏（{len(c_none1 or b'')} 字节）和批量页（{len(b_none1 or b'')} 字节）都逐字节相同")
        # ---------- Claude Code 连上来（initialize 报 claude-code）：「Claude Code 已连接」；读不改它
        m = Mcp(env)
        m.initialize("claude-code", "2.1.303")
        st1 = m.tool("h1", "app_status") or {}
        t1 = wait_state("connected", 3)
        m.tool("h2", "cull_session_overview", {"session": KEY})
        t1r = ind()
        c_conn, cr_conn = chrome("h-chrome-connected")
        check((st1.get("live") or {}).get("state") == "live" and t1 == ("Claude Code 已连接", "connected", W("Claude Code 已连接"))
              and t1r[1] == "connected",
              f"21 一次 app_status 以后：「{t1[0]}」，AppKit 窗口的副标题「{t1[2]}」；读（overview）不变成「正在操作」（{t1r[1]}）")
        view_check(c_conn is not None and c_conn != c_none1, "21「Claude Code 已连接」的标题栏和没有 AI 时不一样")
        # ---------- 等用户停手的时候还不算「正在操作」（第 8 步在等待之后），做成了 → 那一页的提示（§9.4.3 第 11 步）
        test_call(hh, "test.set_busy", {"reasons": ["pointer"], "ms": 1200})
        res = {}
        th = threading.Thread(target=lambda: res.update(v=m.tool("h3", "collage_set_text", {"session": KEY, "title": "标题栏指示"}, 30)))
        th.start()
        time.sleep(0.5)
        t_wait = ind()
        th.join(40)
        b3 = res.get("v") or {}
        t3 = ind()
        s3 = state(hh)
        note3 = (b3.get("live") or {}).get("notice")
        check(t_wait[1] == "connected" and b3.get("changed") is True and note3 and note3.startswith("AI：")
              and t3 == (note3, "just_did", W(note3)) and (s3.get("collage") or {}).get("notice") == note3,
              f"等用户停手的 1.2 s 里还是「{t_wait[0]}」；改了标题以后副标题 = 拼图页状态栏的那句 = live.notice「{note3}」")
        c_did, _ = chrome("h-chrome-justdid")
        k_did = shot("h-collage-notice", "拼图")
        view_check(c_did is not None and c_did not in (c_none1, c_conn) and k_did is not None and k_did != k_none,
                   "「刚做完」的标题栏、拼图页状态栏（有那句提示）和之前的样子不一样")
        # ---------- 「AI 正在操作：一键成套…」（短词，不是工具 title）：一键成套落地之前拖住（test.delay_next），窗口副标题跟着
        test_call(hh, "test.delay_next", {"ms": 2000})
        res = {}
        th = threading.Thread(target=lambda: res.update(v=m.tool("h4", "collage_run_kit", {"session": KEY, "kit": "fashionIssue"}, 120)))
        th.start()
        t4 = wait_state("working", 60)
        c_work, _ = chrome("h-chrome-working")
        th.join(130)
        b4 = res.get("v") or {}
        t4b = ind()
        note4 = (b4.get("live") or {}).get("notice")
        check(t4 == ("AI 正在操作：一键成套…", "working", W("AI 正在操作：一键成套…")),
              f"21 在途的写：「{t4[0]}」（AppKit 窗口「{t4[2]}」）")
        view_check(c_work not in (None, c_conn, c_did), "21 在途的写：标题栏的样子和「已连接」「刚做完」都不一样")
        if b4.get("landing") == "landed":
            check(note4 and t4b == (note4, "just_did", W(note4)), f"成套落地以后：副标题 = live.notice「{note4}」")
        else:
            check(t4b[1] == "connected", f"成套没落地（{b4.get('landing') or err_code(b4)}）：副标题直接回「{t4b[0]}」")
        # ---------- 没改出东西的写：直接回「已连接」，不留提示
        b5 = m.tool("h6", "collage_set_text", {"session": KEY, "title": "标题栏指示"}) or {}
        t5 = ind()
        check(b5.get("changed") is False and t5[1] == "connected" and t5[0] == "Claude Code 已连接",
              f"没改出东西的写（同样的标题）：changed false，副标题回到「{t5[0]}」")
        # ---------- 「刚做完」到点回「已连接」，「已连接」到点淡掉（这一次调用的 hello 是最后一次：从它算 CONN_MS）
        b6 = m.tool("h7", "cull_set_verdicts", {"session": KEY, "ids": ["DSCF7208"], "verdict": "reject"}) or {}
        t_ret = time.monotonic()
        note6 = (b6.get("live") or {}).get("notice")
        t6 = ind()
        s6 = state(hh)
        b_did = shot("h-batch-notice-1", "批量处理")
        b_did2 = shot("h-batch-notice-2", "批量处理")
        check(note6 and t6 == (note6, "just_did", W(note6)) and s6.get("external_notice") == note6 and "批量页" in note6,
              f"改判：副标题 = 批量页状态栏的那句「{note6}」")
        view_check(b_did is not None and b_did == b_did2 and b_did != b_none1,
                   "批量页状态栏有那句提示：拍两次逐字节相同，和没有 AI 时不一样")
        vd_did = s6.get("verdict_digest")
        time.sleep(max(0, t_ret + DID_MS / 1000 + 0.4 - time.monotonic()))
        t7 = ind()
        time.sleep(max(0, t_ret + CONN_MS / 1000 + 0.5 - time.monotonic()))
        t8 = ind()
        c_gone, _ = chrome("h-chrome-faded")
        check(t7 == ("Claude Code 已连接", "connected", W("Claude Code 已连接")) and t8 == ("", "none", W("")),
              f"21 「刚做完」{DID_MS} ms 后回「{t7[0]}」，最后一次 hello {CONN_MS} ms 后淡掉（「{t8[0]}」）")
        view_check(c_gone == c_none1, "21 淡掉以后的标题栏和没有 AI 时逐字节相同")
        # ---------- --mcp-call 没有 initialize（不知道是谁）：「AI 已连接」
        mcp_call(env, "app_status")
        t9 = wait_state("connected", 3)
        check(t9[0] == "AI 已连接", f"不知道客户端名字（--mcp-call）：「{t9[0]}」")
        # ---------- 标注校准 tab 自己有 .navigationTitle（§8 第 37 条）：副标题还在
        test_call(hh, "test.chrome", {"name": "h-chrome-labeling", "tab": "标注校准", "wait_ms": 500})
        s10 = state(hh)
        test_call(hh, "test.chrome", {"name": "h-chrome-batch", "tab": "批量处理", "wait_ms": 300})
        view_check(s10.get("window_subtitle") == "AI 已连接" and s10.get("tab") == "labeling",
                   f"37 标注校准 tab（自带 navigationTitle「{s10.get('window_title')}」）：AppKit 窗口的副标题还是「{s10.get('window_subtitle')}」")
        # ---------- 菜单开关（§10.8 第 8 条）：关 → 读写都 bridge_off、进程内的照常、副标题不显示；不写 UserDefaults；开 → 恢复
        raw = Raw(hh)  # 关之前就连上的连接：关了以后在它上面发的读写也不做
        r_off = test_call(hh, "test.set_bridge", {"enabled": False, "for_ms": 4000}).get("result") or {}
        t_off = time.monotonic()
        rr = raw.call("cull.read", {"session": KEY, "kind": "overview", "args": {}})
        rw = raw.call("collage.set_text", {"session": KEY, "title": "桥关着"}, op_id=str(uuid.uuid4()))
        rs = raw.call("test.state").get("result") or {}  # test.* 不挡：测试脚本的连接跨过开关照样能看状态
        raw.close()
        st_off, _ = status(env)
        _, ls_off, _ = mcp_call(env, "cull_list_sessions")
        _, lt_off, _ = mcp_call(env, "collage_list_templates")
        _, rd_off, _ = mcp_call(env, "cull_session_overview", {"session": KEY})
        _, pv_off, _ = mcp_call(env, "cull_preview_photos", {"session": KEY, "ids": ["DSCF7208"]})
        _, wr_off, _ = mcp_call(env, "collage_set_text", {"session": KEY, "title": "桥关着"})
        _, un_off, _ = mcp_call(env, "app_undo", {"target": "collage"})
        lock_off = json.loads(open(os.path.join(hh.data, ".live.lock")).read().splitlines()[0])
        live_off = st_off.get("live") or {}
        sess_off = [x.get("session") for x in (ls_off or {}).get("sessions") or []]
        check(r_off.get("bridge") == "off" and r_off.get("indicator") == "" and not os.path.exists(hh.sock)
              and lock_off.get("bridge") == "off" and lock_off.get("reason") == "disabled_in_settings" and hh.alive(),
              f"关掉：socket 删了，锁文件 bridge:off（{lock_off.get('reason')}），副标题「{r_off.get('indicator')}」，宿主照常活着")
        check(((rr.get("error") or {}).get("code"), (rw.get("error") or {}).get("code")) == ("bridge_off", "bridge_off")
              and rs.get("bridge") == "off" and rs.get("bridge_enabled") is False and rs.get("indicator") == "",
              f"关之前就连上的连接：之后发的读、写都 bridge_off（{(rr.get('error') or {}).get('code')}、{(rw.get('error') or {}).get('code')}），"
              f"test.state 照常回（bridge {rs.get('bridge')}、菜单的勾 {rs.get('bridge_enabled')}、副标题「{rs.get('indicator')}」）")
        check(live_off.get("state") == "bridge_off" and "菜单" in json.dumps(st_off, ensure_ascii=False)
              and KEY in sess_off and len((lt_off or {}).get("templates") or []) > 0
              and [err_code(x) for x in (rd_off, pv_off, wr_off, un_off)] == ["bridge_off"] * 4,
              f"8 关着：app_status 是 bridge_off（不是 not_running，说明里提到菜单），列场次 / 模板照常，"
              f"读、看图、写、撤销都 bridge_off {[err_code(x) for x in (rd_off, pv_off, wr_off, un_off)]}")
        menu = "「允许 AI 实时操作（MCP）」"   # 和菜单那一项一字不差（LiveBridgeToggle），用户照着找得到
        msg_app = (rr.get("error") or {}).get("message") or ""
        msg_mcp = ((wr_off or {}).get("error") or {}).get("message") or ""
        check(menu in msg_app and menu in msg_mcp, f"bridge_off 两处都写菜单那一项的全名：app「{msg_app}」，--mcp「{msg_mcp}」")
        time.sleep(max(0, 4.0 - (time.monotonic() - t_off)) + 0.6)
        s_on = state(hh)
        st_on, _ = status(env)
        _, wr_on, _ = mcp_call(env, "collage_set_text", {"session": KEY, "title": "桥开回来了"})
        check(s_on.get("bridge") == "on" and s_on.get("bridge_enabled") is True and s_on.get("indicator") == ""
              and (st_on.get("live") or {}).get("state") == "live" and (wr_on or {}).get("changed") is True,
              f"再打开：bridge on、副标题「{s_on.get('indicator')}」（关之前的 hello 不算），live，写照常（changed {(wr_on or {}).get('changed')}）")
        check(all(defaults_export(d) == defaults_h[d] for d in defaults_h),
              "宿主的开关只在内存里：关、开前后 defaults export LabelGUI / local.culling.labelgui 都没变")
        ns = state(hh)["nsapp"]
        check(ns.get("active") is False and ns.get("key_window") is False and ns.get("visible_windows") == 0
              and ns.get("host_window_visible") is False and ns.get("activation_policy") == 2,
              f"带标题栏的宿主也从不变成前台、窗口从不显示：{ns}")
        # ---------- 批量页状态栏那句提示真的画出来了：上面「和没有 AI 时不一样」被同一次改判（格子、顶栏计数）盖住，没有
        # 这一行的旧二进制也过。提示 10 s 后自己清掉（batchNotice 写死的，DID_MS 管不到；这时离改判已经过了 10 s 多），
        # 判决还是那时的（中间只有拼图写）：同一个判决状态，有那句提示和没有，批量页必须不一样。CI 用 --no-view 时整段不等不拍
        if VIEW:
            deadline = time.monotonic() + 15 * SLACK
            s_late = state(hh)
            while s_late.get("external_notice") is not None and time.monotonic() < deadline:
                time.sleep(0.2)
                s_late = state(hh)
            b_late1, b_late2 = shot("h-batch-notice-gone-1", "批量处理"), shot("h-batch-notice-gone-2", "批量处理")
            check(s_late.get("external_notice") is None and vd_did and s_late.get("verdict_digest") == vd_did
                  and b_late1 is not None and b_late1 == b_late2 and b_late1 != b_did,
                  f"那句提示清掉以后（判决没变：{s_late.get('verdict_digest') == vd_did}）批量页拍两次相同，和有提示时不一样：状态栏那一行真的画了")
        else:
            skip("那句提示清掉以后批量页和有提示时不一样（要拍批量页）：CI 用 --no-view：宿主没有窗口，这一条看本地")
        m.close()
        # ---------- 同一个数据目录的第二个实例：不开桥，副标题说一句（只能从它的日志看：它没有 socket）
        h2 = Host("H2", data=hh.data, root=hh.root, args=("--no-view",))
        log2 = h2.log()
        check(h2.bridge == "unavailable" and h2.reason == "another_instance"
              and "标题栏指示：「另一个选片工具正在用这个数据目录：AI 只连那一个」" in log2,
              f"另一个实例占着这个数据目录：第二个不开桥（{h2.reason}），副标题「另一个选片工具正在用这个数据目录：AI 只连那一个」")
        h2.term()
        hh.term()

        # ---------- 桥停了（§9.2.4）：锁被别的程序拿走 → 关桥、标题栏那一句（一直留着，重开 app 才恢复）；开桥 / 重新 bind
        # 失败 → 带原因的那一句，开好了就消失。已经连上的连接上来的读写回 app_unreachable 带真正的原因（不是 bridge_off「菜单」），
        # --mcp 看到的状态的 hint 里是标题栏上的同一句话
        LOST = "数据目录的锁被别的程序拿走了：AI 实时操作已停，重开 app 恢复"

        def hint_of(body):
            return ((body or {}).get("error") or {}).get("hint") or ""

        def warn_hints(st_):
            return " ".join(w.get("hint") or "" for w in (st_ or {}).get("warnings") or [])

        def keep_chrome(raw_, name):
            r_ = raw_.call("test.chrome", {"name": name, "wait_ms": 300}).get("result") or {}
            return open(r_["file"], "rb").read() if r_.get("file") else None, r_

        def keep_wait(raw_, cond, timeout=5):
            deadline = time.monotonic() + timeout * SLACK
            s_ = raw_.call("test.state").get("result") or {}
            while not cond(s_) and time.monotonic() < deadline:
                time.sleep(0.05)
                s_ = raw_.call("test.state").get("result") or {}
            return s_

        hl = Host("H-lost", args=("--titled",))
        env_l = hl.env()
        # 关桥以后 socket 就没了：test.state / test.chrome 只能走关之前连上的这一条（test.* 不挡）
        keep = Raw(hl)
        c_l0, _ = keep_chrome(keep, "h-lost-chrome-none")
        lock_p = os.path.join(hl.data, ".live.lock")
        listen_fd = ((keep.call("test.state").get("result") or {}).get("fds") or {}).get("listen", {}).get("fd")

        def listen_closed(timeout=2):
            """从进程外面看（proc_pidinfo）：开着桥时的那个监听 fd 号上已经没有 socket 了（accept 线程真的关了它）。"""
            deadline = time.monotonic() + timeout * SLACK
            while True:
                left = [f for f, kind, _, _ in proc_fds(hl.pid) if f == listen_fd and kind == PROX_FDTYPE_SOCKET]
                if not left or time.monotonic() > deadline:
                    return listen_fd is not None and not left
                time.sleep(0.05)

        just_after_selfcheck(hl)
        # 真的抢锁：删掉锁文件、马上建一个新的拿 LOCK_EX（app 的 fd 还指着旧的 inode）。下一轮自检 fstat / lstat 的 inode
        # 对不上 → 重新 open + flock → 拿不到 → 锁丢了
        os.unlink(lock_p)
        thief = os.open(lock_p, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(thief, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            s_l = keep_wait(keep, lambda x: x.get("indicator_state") == "lock_lost" and x.get("window_subtitle") == W(LOST))
            check(s_l.get("indicator") == LOST and s_l.get("indicator_state") == "lock_lost" and s_l.get("window_subtitle") == W(LOST)
                  and s_l.get("bridge") == "unavailable" and s_l.get("bridge_reason") == "lock_lost"
                  and (s_l.get("counters") or {}).get("lock_lost") == 1 and "listen" not in (s_l.get("fds") or {})
                  and listen_closed() and not os.path.exists(hl.sock) and hl.alive(),
                  f"9.2.4 锁被别的程序拿走（删掉锁文件、另建一个拿 LOCK_EX）：自检关桥（socket 删了；监听 fd {listen_fd} 从进程外面看也关了），"
                  f"副标题「{s_l.get('indicator')}」（AppKit 窗口「{s_l.get('window_subtitle')}」），bridge {s_l.get('bridge')}"
                  f"（{s_l.get('bridge_reason')}），宿主照常活着")
            rr = keep.call("cull.read", {"session": KEY, "kind": "overview", "args": {}})
            rw = keep.call("collage.set_text", {"session": KEY, "title": "锁丢了"}, op_id=str(uuid.uuid4()))
            errs = [(x.get("error") or {}) for x in (rr, rw)]
            check(all(e.get("code") == "app_unreachable" and (e.get("data") or {}).get("reason") == "lock_lost"
                      and (e.get("data") or {}).get("executed") is False and LOST in (e.get("data") or {}).get("hint", "")
                      and "菜单" not in e.get("message", "") + (e.get("data") or {}).get("hint", "") for e in errs),
                  f"锁丢了以后，之前连上的连接上来的读、写：app_unreachable（reason lock_lost，hint 带标题栏那一句），不说「菜单里关了」"
                  f"{[e.get('code') for e in errs]}")
            st_l, _ = status(env_l)
            _, rd_l, _ = mcp_call(env_l, "cull_session_overview", {"session": KEY})
            _, wr_l, _ = mcp_call(env_l, "collage_set_text", {"session": KEY, "title": "锁丢了"})
            live_l = st_l.get("live") or {}
            check(live_l.get("state") == "unreachable" and live_l.get("reason") == "lock_role_unknown" and LOST in warn_hints(st_l)
                  and [err_code(x) for x in (rd_l, wr_l)] == ["app_unreachable"] * 2 and LOST in hint_of(rd_l) and LOST in hint_of(wr_l),
                  f"这时 --mcp（锁在不认识的程序手里，锁文件是空的）：{live_l.get('state')}（{live_l.get('reason')}），读写都 "
                  f"{[err_code(x) for x in (rd_l, wr_l)]}，hint 带标题栏那一句")
            c_l1, cr_l1 = keep_chrome(keep, "h-lost-chrome-1")
            c_l2, _ = keep_chrome(keep, "h-lost-chrome-2")
            view_check(c_l1 is not None and c_l1 == c_l2 and c_l1 != c_l0 and cr_l1.get("subtitle") == LOST,
                       f"锁丢了的标题栏：拍两次逐字节相同（{len(c_l1 or b'')} 字节），和没有 AI 时不一样，副标题「{cr_l1.get('subtitle')}」")
            time.sleep(1.2)
            s_l2 = keep.call("test.state").get("result") or {}
            check((s_l2.get("counters") or {}).get("lock_lost") == 1 and s_l2.get("indicator_state") == "lock_lost"
                  and (s_l2.get("counters") or {}).get("selfchecks", 0) > (s_l.get("counters") or {}).get("selfchecks", 0) + 1,
                  f"锁一直在别人手里：之后的自检不再关一次、不再记一笔（lock_lost {(s_l2.get('counters') or {}).get('lock_lost')}），那一句还在")
        finally:
            fcntl.flock(thief, fcntl.LOCK_UN)
            os.close(thief)
        # 别人放掉锁：app 拿回来（还是唯一写者），锁文件那一行写 bridge:unavailable、reason lock_lost；桥照样停着
        s_l3 = keep_wait(keep, lambda x: (x.get("counters") or {}).get("lock_reacquired", 0) >= 1)
        line_l = json.loads(open(lock_p).read().splitlines()[0])
        st_l3, _ = status(env_l)
        _, wr_l3, _ = mcp_call(env_l, "cull_set_verdicts", {"session": KEY, "ids": ["DSCF7208"], "verdict": "pick"})
        live_l3 = st_l3.get("live") or {}
        check((s_l3.get("counters") or {}).get("lock_reacquired", 0) >= 1 and line_l.get("pid") == hl.pid
              and line_l.get("bridge") == "unavailable" and line_l.get("reason") == "lock_lost"
              and s_l3.get("indicator") == LOST and s_l3.get("bridge_reason") == "lock_lost" and not os.path.exists(hl.sock)
              and live_l3.get("state") == "unreachable" and live_l3.get("reason") == "lock_lost" and LOST in warn_hints(st_l3)
              and err_code(wr_l3) == "app_unreachable" and LOST in hint_of(wr_l3),
              f"别人放掉锁：app 拿回来、锁文件写 {line_l.get('bridge')}（{line_l.get('reason')}），桥照样停着、那一句还在；--mcp："
              f"{live_l3.get('state')}（{live_l3.get('reason')}），写 {err_code(wr_l3)}，hint 带标题栏那一句")
        # 锁丢了以后菜单照样说了算：关 → 桥 .off、锁文件那一行写 off，--mcp 和之前连上的连接都回 bridge_off（标题栏这时什么都
        # 不显示，不能让模型说「标题栏上写着锁被拿走了」）；再开 → 不开桥，那一句回来，--mcp 又是 unreachable（lock_lost）
        OFF_MS = int(3000 * SLACK)
        r_m = keep.call("test.set_bridge", {"enabled": False, "for_ms": OFF_MS}).get("result") or {}
        t_off = time.monotonic()
        line_off = json.loads(open(lock_p).read().splitlines()[0])
        st_off, _ = status(env_l)
        _, wr_off, _ = mcp_call(env_l, "collage_set_text", {"session": KEY, "title": "菜单关着"})
        rr_off = keep.call("cull.read", {"session": KEY, "kind": "overview", "args": {}})
        s_off = keep.call("test.state").get("result") or {}
        in_off = time.monotonic() - t_off < OFF_MS / 1000
        e_off = rr_off.get("error") or {}
        check(in_off and r_m.get("indicator") == "" and s_off.get("bridge") == "off" and s_off.get("indicator") == ""
              and line_off.get("bridge") == "off" and (st_off.get("live") or {}).get("state") == "bridge_off"
              and err_code(wr_off) == "bridge_off" and LOST not in hint_of(wr_off) + warn_hints(st_off)
              and e_off.get("code") == "bridge_off" and LOST not in json.dumps(e_off, ensure_ascii=False),
              f"锁丢了以后菜单关：桥 {s_off.get('bridge')}，标题栏「{s_off.get('indicator')}」，锁文件那一行 {line_off.get('bridge')}；"
              f"--mcp {(st_off.get('live') or {}).get('state')}、写 {err_code(wr_off)}，之前连上的连接上的读 {e_off.get('code')}："
              f"菜单说了算，不提标题栏上没有的那一句")
        s_l4 = keep_wait(keep, lambda x: x.get("bridge_enabled") is True and x.get("indicator") == LOST, timeout=OFF_MS / 1000 + 5)
        line_on = json.loads(open(lock_p).read().splitlines()[0])
        st_on, _ = status(env_l)
        live_on = st_on.get("live") or {}
        check(s_l4.get("indicator") == LOST and s_l4.get("bridge") == "unavailable" and s_l4.get("bridge_reason") == "lock_lost"
              and line_on.get("bridge") == "unavailable" and line_on.get("reason") == "lock_lost" and not os.path.exists(hl.sock)
              and live_on.get("state") == "unreachable" and live_on.get("reason") == "lock_lost" and LOST in warn_hints(st_on),
              f"再开 → 那一句回来、桥不重开（{s_l4.get('bridge')}，{s_l4.get('bridge_reason')}），锁文件那一行 {line_on.get('bridge')}；"
              f"--mcp 又是 {live_on.get('state')}（{live_on.get('reason')}）：重开 app 才恢复")
        keep.close()
        hl.term()

        # 反过来：菜单先关、锁再丢 → 桥照样是 .off（不改成 lock_lost），app 拿回锁以后锁文件那一行写 off，--mcp 回 bridge_off；
        # 菜单再开 → 那一句、不开桥、--mcp unreachable（lock_lost）
        ho = Host("H-lost-off", args=("--no-view",))
        env_o = ho.env()
        keep_o = Raw(ho)
        lock_o = os.path.join(ho.data, ".live.lock")
        OFF_MS2 = int(3000 * SLACK)
        keep_o.call("test.set_bridge", {"enabled": False, "for_ms": OFF_MS2})
        t_off2 = time.monotonic()
        os.unlink(lock_o)
        thief = os.open(lock_o, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(thief, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            s_o = keep_wait(keep_o, lambda x: (x.get("counters") or {}).get("lock_lost") == 1)
        finally:
            fcntl.flock(thief, fcntl.LOCK_UN)
            os.close(thief)
        s_o2 = keep_wait(keep_o, lambda x: (x.get("counters") or {}).get("lock_reacquired", 0) >= 1)
        line_o = json.loads(open(lock_o).read().splitlines()[0])
        st_o, _ = status(env_o)
        in_off2 = time.monotonic() - t_off2 < OFF_MS2 / 1000
        check(in_off2 and (s_o.get("counters") or {}).get("lock_lost") == 1 and s_o.get("bridge") == "off"
              and s_o.get("bridge_reason") == "disabled_in_settings" and s_o.get("indicator") == ""
              and (s_o2.get("counters") or {}).get("lock_reacquired", 0) >= 1 and line_o.get("pid") == ho.pid
              and line_o.get("bridge") == "off" and (st_o.get("live") or {}).get("state") == "bridge_off",
              f"菜单关着时锁丢了：桥还是 {s_o.get('bridge')}（{s_o.get('bridge_reason')}），标题栏「{s_o.get('indicator')}」；拿回锁以后"
              f"锁文件那一行 {line_o.get('bridge')}，--mcp {(st_o.get('live') or {}).get('state')}")
        s_o3 = keep_wait(keep_o, lambda x: x.get("bridge_enabled") is True and x.get("indicator") == LOST, timeout=OFF_MS2 / 1000 + 5)
        st_o3, _ = status(env_o)
        live_o3 = st_o3.get("live") or {}
        check(s_o3.get("indicator_state") == "lock_lost" and s_o3.get("bridge") == "unavailable" and s_o3.get("bridge_reason") == "lock_lost"
              and not os.path.exists(ho.sock) and live_o3.get("state") == "unreachable" and live_o3.get("reason") == "lock_lost"
              and LOST in warn_hints(st_o3),
              f"菜单再开：那一句（{s_o3.get('indicator_state')}），桥不开（{s_o3.get('bridge')}，{s_o3.get('bridge_reason')}），"
              f"--mcp {live_o3.get('state')}（{live_o3.get('reason')}），hint 带那一句")
        keep_o.close()
        ho.term()

        # 别人放掉锁到 app 拿回来之间，--mcp 只看到空锁（not_running / old_app）：锁丢了以后自检改成 1 s 一次，这段最多 1 s。
        # 自检本来 4 s 一次的宿主：放掉以后 3 s 内拿回来（不改节奏要等到下一个 4 s）
        hf = Host("H-fast", args=("--no-view",), env_extra={"LABELGUI_LIVE_TEST_SELFCHECK_MS": "4000"})
        keep_f = Raw(hf)
        lock_f = os.path.join(hf.data, ".live.lock")
        os.unlink(lock_f)
        thief = os.open(lock_f, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(thief, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            s_f = keep_wait(keep_f, lambda x: (x.get("counters") or {}).get("lock_lost") == 1, timeout=12)
        finally:
            fcntl.flock(thief, fcntl.LOCK_UN)
            os.close(thief)
            t_rel = time.monotonic()
        s_f2 = keep_wait(keep_f, lambda x: (x.get("counters") or {}).get("lock_reacquired", 0) >= 1, timeout=12)
        took = time.monotonic() - t_rel
        st_f, _ = status(hf.env())
        check((s_f.get("counters") or {}).get("lock_lost") == 1 and (s_f2.get("counters") or {}).get("lock_reacquired", 0) >= 1
              and took < 3.0 and (st_f.get("live") or {}).get("reason") == "lock_lost" and LOST in warn_hints(st_f),
              f"锁丢了以后 1 s 查一次：别人放掉 {took:.1f} s 后拿回来（自检本来 4 s 一次），--mcp "
              f"{(st_f.get('live') or {}).get('state')}（{(st_f.get('live') or {}).get('reason')}）")
        keep_f.close()
        hf.term()

        # 锁文件重新 open 不了（整个数据目录被挪走，没有别的程序拿锁）：不说「被别的程序拿走了」—— 标题栏带原因的那一句，
        # bridge unavailable（lock_reopen_failed），lock_lost 不记；挪回来 → 下一轮自检开好、那一句消失、--mcp 又是 live
        REOPEN = "AI 实时操作的连接开不起来（数据目录的锁文件不见了或打不开）：已暂停，每 10 秒自动再试"
        hm = Host("H-moved", args=("--no-view",))
        keep_m = Raw(hm)
        moved = hm.data + ".moved"
        just_after_selfcheck(hm)
        os.rename(hm.data, moved)
        try:
            s_m = keep_wait(keep_m, lambda x: x.get("bridge_reason") == "lock_reopen_failed" and x.get("indicator") == REOPEN)
            rr_m = keep_m.call("cull.read", {"session": KEY, "kind": "overview", "args": {}})
            time.sleep(1.2)
            s_m1 = keep_m.call("test.state").get("result") or {}
        finally:
            os.rename(moved, hm.data)
        e_m = rr_m.get("error") or {}
        cnt_m = s_m1.get("counters") or {}
        check(s_m.get("indicator_state") == "bridge_failed" and s_m.get("bridge") == "unavailable" and not os.path.exists(hm.sock)
              and not cnt_m.get("lock_lost") and cnt_m.get("lock_reopen_failed") == 1
              and e_m.get("code") == "app_unreachable" and (e_m.get("data") or {}).get("reason") == "lock_reopen_failed"
              and REOPEN in (e_m.get("data") or {}).get("hint", "") and "拿走" not in json.dumps(e_m, ensure_ascii=False)
              and "菜单" not in e_m.get("message", ""),
              f"数据目录被挪走（锁文件重新 open 不了）：副标题「{s_m.get('indicator')}」，桥 {s_m.get('bridge')}（{s_m.get('bridge_reason')}），"
              f"lock_lost {cnt_m.get('lock_lost')}、lock_reopen_failed {cnt_m.get('lock_reopen_failed')}（之后的自检不再记）；之前连上的连接上的读 "
              f"{e_m.get('code')}（{(e_m.get('data') or {}).get('reason')}），不说「拿走」")
        s_m2 = keep_wait(keep_m, lambda x: x.get("bridge") == "on" and x.get("indicator_state") == "none")
        st_m, _ = status(hm.env())
        check(s_m2.get("bridge") == "on" and s_m2.get("indicator") == "" and os.path.exists(hm.sock)
              and (st_m.get("live") or {}).get("state") == "live",
              f"挪回来：下一轮自检开好（{s_m2.get('bridge')}），那一句消失（「{s_m2.get('indicator')}」），--mcp {(st_m.get('live') or {}).get('state')}")
        keep_m.close()
        hm.term()

        # 重新 bind 失败（真的）：socket 被删、同一个位置放了一个普通文件 → 自检重新 bind 时不碰它、不开桥（socket_path_occupied）
        # → 标题栏带原因的那一句；文件拿走 → 下一轮自检开好 → 那一句消失，标题栏和没有 AI 时逐字节相同
        OCC = "AI 实时操作的连接开不起来（连接文件的位置被别的文件占着）：已暂停，每 10 秒自动再试"
        hr = Host("H-rebind", args=("--titled",))
        env_r = hr.env()
        keep_r = Raw(hr)
        c_r0, _ = keep_chrome(keep_r, "h-rebind-chrome-none")
        just_after_selfcheck(hr)
        os.unlink(hr.sock)
        open(hr.sock, "w").write("不是 socket\n")
        s_r = keep_wait(keep_r, lambda x: x.get("indicator_state") == "bridge_failed" and x.get("window_subtitle") == W(OCC))
        rr_r = keep_r.call("cull.read", {"session": KEY, "kind": "overview", "args": {}})
        e_r = rr_r.get("error") or {}
        st_r, _ = status(env_r)
        live_r = st_r.get("live") or {}
        c_r1, cr_r1 = keep_chrome(keep_r, "h-rebind-chrome-1")
        c_r2, _ = keep_chrome(keep_r, "h-rebind-chrome-2")
        check(s_r.get("indicator") == OCC and s_r.get("window_subtitle") == W(OCC) and s_r.get("bridge_reason") == "socket_path_occupied"
              and e_r.get("code") == "app_unreachable" and (e_r.get("data") or {}).get("reason") == "socket_path_occupied"
              and OCC in (e_r.get("data") or {}).get("hint", "") and "菜单" not in e_r.get("message", "")
              and live_r.get("state") == "unreachable" and live_r.get("reason") == "socket_path_occupied" and OCC in warn_hints(st_r),
              f"9.2.4 重新 bind 失败（socket 的位置被普通文件占着）：副标题「{s_r.get('indicator')}」；之前连上的连接上的读 "
              f"{e_r.get('code')}（{(e_r.get('data') or {}).get('reason')}）；--mcp {live_r.get('state')}（{live_r.get('reason')}），hint 带那一句")
        view_check(c_r1 is not None and c_r1 == c_r2 and c_r1 not in (c_r0, c_l1) and cr_r1.get("subtitle") == OCC,
                   f"开桥失败的标题栏：拍两次逐字节相同（{len(c_r1 or b'')} 字节），和没有 AI、锁丢了时都不一样")
        os.unlink(hr.sock)
        s_r2 = keep_wait(keep_r, lambda x: x.get("bridge") == "on" and x.get("indicator_state") == "none", timeout=5)
        c_r3, _ = keep_chrome(keep_r, "h-rebind-chrome-healed")  # 在 --mcp 的 hello 之前拍：之后就是「AI 已连接」了
        st_r2, _ = status(env_r)
        s_r3 = keep_wait(keep_r, lambda x: x.get("indicator_state") == "connected")
        check(s_r2.get("bridge") == "on" and s_r2.get("indicator") == "" and s_r2.get("window_subtitle") == W("")
              and (st_r2.get("live") or {}).get("state") == "live" and s_r3.get("indicator") == "AI 已连接",
              f"文件拿走：下一轮自检开好（{s_r2.get('bridge')}），那一句消失（「{s_r2.get('indicator')}」）；"
              f"--mcp {(st_r2.get('live') or {}).get('state')}，之后照常「{s_r3.get('indicator')}」")
        view_check(c_r3 == c_r0, "文件拿走以后的标题栏和没有 AI 时逐字节相同")
        keep_r.close()
        hr.term()

        # 一启动就开不了桥：SockDir 0775（自检接着试）→ 宿主就绪时副标题已经是那一句（ready 行之前在主线程上当场设好）；
        # 改回 0700 → 自检开好、那一句消失。socket 路径太长（不试）→「已停，重开 app 再试」
        UNSAFE = "AI 实时操作的连接开不起来（放连接的临时目录权限不对）：已暂停，每 10 秒自动再试"
        root_hu = sock_root("H-unsafe")
        real_hu = os.path.join(SOCKS, os.path.basename(root_hu))
        os.chmod(real_hu, 0o775)
        hu = Host("H-unsafe", root=root_hu, args=("--no-view",))
        st_hu, _ = status(hu.env())
        log_hu = hu.log()
        os.chmod(real_hu, 0o700)
        deadline = time.monotonic() + 3 * SLACK
        while time.monotonic() < deadline and not os.path.exists(hu.sock):
            time.sleep(0.05)
        s_hu = {}
        if os.path.exists(hu.sock):
            raw_hu = Raw(hu)
            s_hu = keep_wait(raw_hu, lambda x: x.get("indicator_state") == "none", timeout=3)
            raw_hu.close()
        ready_ind = re.search(r"标题栏指示：「(.*?)」", log_hu)
        check(hu.bridge == "unavailable" and hu.reason == "sock_dir_unsafe" and ready_ind and ready_ind.group(1) == UNSAFE
              and (st_hu.get("live") or {}).get("reason") == "sock_dir_unsafe" and UNSAFE in warn_hints(st_hu)
              and s_hu.get("bridge") == "on" and s_hu.get("indicator") == "",
              f"一启动 SockDir 就不安全：就绪时副标题「{ready_ind.group(1) if ready_ind else '?'}」，--mcp hint 带那一句；"
              f"改回 0700 → 开好（{s_hu.get('bridge')}），那一句消失（「{s_hu.get('indicator')}」）")
        hu.term()
        long_hl = os.path.join(WORK, "x" * 40, "很长的-socket-根目录-H-" + "y" * 40)
        os.makedirs(long_hl, mode=0o700)
        TOO_LONG = "AI 实时操作的连接开不起来（连接文件的路径太长）：已停，重开 app 再试"
        hlong = Host("H-long", root=long_hl, args=("--no-view",))
        st_long, _ = status(hlong.env())
        ready_long = re.search(r"标题栏指示：「(.*?)」", hlong.log())
        check(hlong.reason == "socket_path_too_long" and ready_long and ready_long.group(1) == TOO_LONG
              and TOO_LONG in warn_hints(st_long),
              f"socket 路径太长（自检不试）：就绪时副标题「{ready_long.group(1) if ready_long else '?'}」，--mcp hint 带它")
        hlong.term()

    # ============================================================ grep：Live/ 的禁用词（§5 第 7 层、§9.5.6）
    print("grep")
    LIVE_DIR = os.path.join(SRC, "Live")
    LIVE_BANNED = [r"NSApp\.activate", r"\bactivate\(", "activateIgnoringOtherApps", "makeKeyAndOrderFront", r"makeKey\w*\(",
                   r"makeMain\w*\(", r"becomeKey\(", "orderFront", "deminiaturize", r"\bunhide", "requestUserAttention",
                   "NSOpenPanel", "NSSavePanel", "NSAlert", "runModal", "beginSheet", "openWindow", "NSWorkspace",
                   "/usr/bin/open", "revealInFinder", "startVLMServer", "CardImportCenter", r"export\(", "posix_spawn",
                   r"\bfork\(", r"\bsystem\(", r"\bpopen\(", r"setIsVisible\("]
    hits = []
    # 整棵 Live/ 都看（STEP 4：以后加了子目录也逃不掉；和 mcp_smoke.py 一样 os.walk）
    for dp, _, fs in os.walk(LIVE_DIR):
        for f in sorted(fs):
            if f.endswith(".swift"):
                rel = os.path.relpath(os.path.join(dp, f), LIVE_DIR)
                for n, line in enumerate(open(os.path.join(dp, f), encoding="utf-8"), 1):
                    hits += [f"{rel}:{n} {p}" for p in LIVE_BANNED if re.search(p, line)]
    check(os.path.isdir(LIVE_DIR) and not hits, f"Live/ 里没有会激活 app、拉出窗口、起子进程的调用 {hits[:5]}")
    lc = os.path.join(SRC, "MCP", "LiveClient.swift")
    body = open(lc, encoding="utf-8").read()
    m_ = re.search(r"static func probeLockFile\(.*?\n    }\n", body, re.S)
    rest = body.replace(m_.group(0), "") if m_ else body
    opens = [l for l in rest.splitlines() if re.search(r"\bopen\(", re.sub(r"(^|\s)//.*$", "", l))]
    check(m_ is not None and re.search(r"\bopen\(", m_.group(0)) and "O_RDONLY | O_NOFOLLOW | O_CLOEXEC" in m_.group(0)
          and "O_CREAT" not in m_.group(0) and not opens,
          f"MCP/LiveClient.swift 只在 probeLockFile() 里 open（O_RDONLY|O_NOFOLLOW|O_CLOEXEC，不带 O_CREAT）{opens[:3]}")
finally:
    for p in PROCS:
        try:
            p.term()
        except Exception:
            pass
    for link in (LINK, BM_LINK):
        try:
            os.unlink(link)  # 中途出错也不留 /tmp/xpls.*、/tmp/xpbm.* 这两个链接
        except OSError:
            pass


print("收尾")
for d, before in defaults_before.items():
    check(defaults_export(d) == before, f"defaults export {d} 跑前跑后相同")
check(real_sock_state() == real_sock_before, f"真实的 {REAL_SOCK} 跑前跑后一样（只 ls）：{real_sock_state()}")
left = [p for p in PROCS if getattr(p, "alive", lambda: False)()]
check(not left, f"脚本起的进程都退了 {[p.pid for p in left]}")
socks_left = [os.path.join(dp, f) for dp, _, fs in os.walk(SOCKS) for f in fs if f.endswith(".sock")]
print(f"  （socket 根目录里剩下的 {len(socks_left)} 个 .sock 都是 kill -9 / SIGPIPE 用例故意留下的残留）")
if not KEEP:
    shutil.rmtree(WORK, ignore_errors=True)
print(f"\n实时桥冒烟：{counts['ok']} 条通过，{len(failures)} 条失败，{counts['skip']} 条跳过")
if failures:
    for f in failures:
        print("  FAIL " + f)
    sys.exit(1)
print("实时桥冒烟全部通过")
