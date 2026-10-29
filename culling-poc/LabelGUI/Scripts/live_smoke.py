#!/usr/bin/env python3
"""实时桥冒烟（DESIGN §9.8.2、§10.7；STEP 2：桥本身，STEP 3a：读和图片）：起 --live-host（.prohibited，窗口从不显示），
经脚本自己起的 --mcp 驱动；test.* 直接连宿主的 socket。

用法: python3 -I Scripts/live_smoke.py <LabelGUI> --ci [--work <目录>] [--keep] [--only A,B,…]
      python3 -I Scripts/live_smoke.py <LabelGUI> --photos <照片目录> --data <已分析的数据目录> [--collage-data <目录>]
                                        [--work …] [--keep] [--only …]
  --ci      Fixtures 场次（照片文件夹不存在，和 verdict_regression.sh 同一个约定）+ sips 合成图；app 里的二进制只在 --ci 下收
  --photos / --data  本地 photot 模式：数据目录每个宿主拷一份新的
  --collage-data     （本地）有拼图工程的同一场的数据目录（STEP 0 的 data-seeded）：collage_get_state 的预览用它
  --work    工作目录（不存在、空的、或者本脚本上次建的才用；socket 也放在这下面，经 /tmp 下一个短的符号链接接过去）

组：A 没有宿主  B 起宿主（R6 T1–T4、T10、T11、T13、T17，hello、积压、连接上限、桥关、自愈、窗口、取消、截止时间……）
    C 杀掉 / 重起 / 抢锁（R6 T5–T9、T12、T14、T16、T18，CLOEXEC）  D SIGPIPE 矩阵（R6 §4.3 五行）  E --app-ui 不开桥
    F 读和图片（§10.7 第 31–36、38 条：fixture 读和 --verdicts 对账、cursor、预览、受保护位置不读原图、并发、取消、NaN、
      输出目录）
每个 --mcp 都带自己的 LABELGUI_MCP_OUT（工作目录里），绝不写 ~/Pictures/xuanpian-mcp。

不碰用户（§9.8.2 的四道闸，一条不改）：
1. 每个宿主、每个 --mcp 都带临时的 LABELGUI_DATA_DIR（realpath 或 dev:ino 等于真实数据目录就 exit 2）和 LABELGUI_NO_GUI=1；
2. socket 根目录是工作目录下自己建的 0700 目录（经 /tmp/xpls.* 这个短链接接过去：sun_path 只有 104 字节），
   等于真实的 $(getconf DARWIN_USER_TEMP_DIR)xuanpian-live 就 exit 2；那个真实目录只 ls、跑前跑后比，绝不进去建东西；
3. 连上以后先看 hello 的 app.pid，必须是脚本自己起的宿主，否则立刻断开、exit 2；
4. 本地只收裸二进制（路径在 *.app/Contents/MacOS/ 下面就 exit 2）。
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


ONLY = set((opt("--only") or "ABCDEF").upper().replace(",", ""))
PHOTOS_SRC, DATA_SRC = opt("--photos"), opt("--data")
COLLAGE_SRC = opt("--collage-data")
if not CI and not (PHOTOS_SRC and DATA_SRC):
    print("要么 --ci，要么 --photos <照片目录> --data <已分析的数据目录>")
    sys.exit(2)
if not os.access(BIN, os.X_OK):
    print(f"不是可执行文件：{BIN}")
    sys.exit(2)
# 闸 4：.app 里的二进制的设置域就是用户真 app 的 local.culling.labelgui，本地只收裸二进制
if not CI and re.search(r"\.app/Contents/MacOS/", os.path.realpath(BIN)):
    print(f"本地模式只收裸二进制（.build/release/LabelGUI 这类），{BIN} 在 .app 里面：不跑")
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
else:
    WORK = tempfile.mkdtemp(prefix="live_smoke.")
SOCKS = os.path.join(WORK, "socks")
os.makedirs(SOCKS, mode=0o700)
LINK = tempfile.mktemp(prefix="xpls.", dir="/tmp")  # 短链接：/tmp/xpls.xxxxxxxx → <工作目录>/socks
os.symlink(SOCKS, LINK)
SNAPS = os.path.join(WORK, "snaps")
os.makedirs(SNAPS)

failures = []
counts = {"ok": 0, "skip": 0}
PROCS = []


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


def minimal_args(tool, session):
    """够过参数校验和 session 核对的最小参数（STEP 3a 起读工具在 live 时先查参数；写工具在 STEP 3b）。"""
    a = {"session": session}
    if tool == "app_undo":
        a = {"target": "collage"}
    if tool in ("cull_get_photos", "cull_preview_photos"):
        a["ids"] = ["DSCF7208"]
    if tool == "cull_list_groups":
        a["kind"] = "scene"
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
    # ============================================================ A. 没有宿主
    if "A" in ONLY:
        print("A. 没有宿主")
        data = fresh_data("A")
        root = sock_root("A")
        env = base_env(data, root)
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
        if not os.access(sandbox, os.X_OK):
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
              and live.get("capabilities") == ["collage.state", "cull.preview", "cull.read"] and live.get("window_state") == "visible"
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
        # 路由：collage_get_state 转给 app；session 填 key / 路径 / 别的；6 个读工具转给 app，9 个写 → app_version_mismatch（app_too_old）
        _, cs, ms = mcp_call(env, "collage_get_state")
        check((cs or {}).get("source") == "app" and cs.get("session") == KEY and cs.get("window_visible") is True
              and cs.get("pending_writes") == 0 and "undo" in cs and "busy" in cs,
              f"collage_get_state 不带 session：app 当前那一场的工程摘要（{ms:.0f} ms）")
        _, cs2, _ = mcp_call(env, "collage_get_state", {"session": PHOTO_DIR + "/"})
        check((cs2 or {}).get("session") == KEY, "collage_get_state 填照片文件夹路径（带结尾斜杠）也认")
        _, cs3, _ = mcp_call(env, "collage_get_state", {"session": "0123456789abcdef"})
        check(err_code(cs3) == "session_not_open" and (cs3["error"].get("data") or {}).get("open_session", {}).get("session") == KEY,
              f"别的场次 → session_not_open，data.open_session 对（{err_code(cs3)}）")
        codes = all_tools(env, KEY)
        reads = {t: codes.pop(t) for t in APP_TOOLS[:6]}
        bad = {t: c for t, c in codes.items() if c != "app_version_mismatch"}
        check(not bad, f"9 个写工具：app 的 capabilities 里还没有它们的方法（STEP 3b）→ app_version_mismatch {bad}")
        # --ci 的 fixture 没有分析预览、照片文件夹也不存在：预览回 preview_missing（正是 §10.3 那一条），其余照常
        want_prev = "preview_missing" if CI else None
        check(reads.pop("cull_preview_photos") == want_prev and set(reads.values()) == {None},
              f"6 个读工具带最小参数都照常回（--ci 的预览是 preview_missing）{reads}")
        _, body, _ = mcp_call(env, "cull_set_verdicts", {"session": KEY, "ids": ["x"], "verdict": "pick"})
        check(((body or {}).get("error") or {}).get("data", {}).get("reason") == "app_too_old", "data.reason = app_too_old（§10.2）")
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
        lock_line = json.loads(open(os.path.join(h.data, ".live.lock")).read().splitlines()[0])
        sock_gone = not os.path.exists(h.sock)
        time.sleep(3.5)
        st_on, _ = status(env)
        check((st_off.get("live") or {}).get("state") == "bridge_off" and err_code(cs_off) == "bridge_off" and err_code(rd_off) == "bridge_off"
              and lock_line.get("bridge") == "off" and sock_gone and (st_on.get("live") or {}).get("state") == "live",
              "桥关着：bridge_off（读写都是），socket 删了、锁文件写 bridge:off；3 s 后自己开回来 → live")
        # socket 被删（R6 T15）：立刻 unreachable；自检（500 ms）以后恢复
        just_after_selfcheck(h)
        t_un = time.monotonic()
        os.unlink(h.sock)
        st_u, _ = status(env)
        _, cs_u, _ = mcp_call(env, "collage_get_state")
        _, rd_u, _ = mcp_call(env, "cull_session_overview", {"session": KEY})
        probe_ms = (time.monotonic() - t_un) * 1000
        time.sleep(1.2)
        st_h, _ = status(env)
        check((st_u.get("live") or {}).get("state") == "unreachable" and err_code(cs_u) == "app_unreachable" and err_code(rd_u) == "app_unreachable"
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
        # LABELGUI_MCP_LIVE=0（§9.8.2 第 28 条）：tools/list 3 个、disabled、一次都不连
        n0 = state(h)["hello_count"]
        m = Mcp(h.env(LABELGUI_MCP_LIVE="0"))
        m.initialize()
        m.send({"jsonrpc": "2.0", "id": "tl", "method": "tools/list"})
        tl = m.wait_id("tl")
        st0 = m.tool("s0", "app_status")
        m.tool("s1", "cull_list_sessions")
        m.close()
        n1 = state(h)["hello_count"] - 1   # 减去刚才这次 state 自己的 hello
        check(len(tl["result"]["tools"]) == 3 and (st0 or {}).get("live", {}).get("state") == "disabled" and n1 == n0,
              f"LABELGUI_MCP_LIVE=0：tools/list 3 个、live.state=disabled、宿主的 hello_count 没变（{n0} → {n1}）")
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
        h.signal(signal.SIGCONT)
        time.sleep(0.3)
        st2, _ = status(env)
        check((st.get("live") or {}).get("state") == "unresponsive" and 950 < ms < 2500 * SLACK and err_code(cs) == "app_unresponsive"
              and err_code(rd9) == "app_unresponsive"
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
        check((st.get("live") or {}).get("state") == "headless_writer" and st.get("gui_running") is False
              and "headless_writer" in [w.get("code") for w in (ls16 or {}).get("warnings", [])],
              "T16 无头写者占着锁：app_status headless_writer；cull_list_sessions 照常列、带 warning")
        check(err_code(busy) == "busy" and err_code(busy_r) == "busy"
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
        check((st.get("live") or {}).get("state") == "proto_mismatch" and err_code(cs) == "app_version_mismatch"
              and err_code(rd12) == "app_version_mismatch"
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
        check((st.get("live") or {}).get("state") == "live" and (st.get("live") or {}).get("capabilities") == ["cull.preview", "cull.read"]
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
    if "E" in ONLY:
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
        sandbox = "/usr/bin/sandbox-exec"
        if not os.access(sandbox, os.X_OK):
            skip("找不到 sandbox-exec：第 33 条只有 test.state 的原图打开记录作证")
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
        skip("33 的 app_open_session 那一半（切到受保护前缀下的场次 → protected_location）在 STEP 3b")

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

    # ============================================================ grep：Live/ 的禁用词（§5 第 7 层、§9.5.6）
    print("grep")
    LIVE_DIR = os.path.join(SRC, "Live")
    LIVE_BANNED = [r"NSApp\.activate", r"\bactivate\(", "activateIgnoringOtherApps", "makeKeyAndOrderFront", r"makeKey\w*\(",
                   r"makeMain\w*\(", r"becomeKey\(", "orderFront", "deminiaturize", r"\bunhide", "requestUserAttention",
                   "NSOpenPanel", "NSSavePanel", "NSAlert", "runModal", "beginSheet", "openWindow", "NSWorkspace",
                   "/usr/bin/open", "revealInFinder", "startVLMServer", "CardImportCenter", r"export\(", "posix_spawn",
                   r"\bfork\(", r"\bsystem\(", r"\bpopen\(", r"setIsVisible\("]
    hits = []
    for f in sorted(os.listdir(LIVE_DIR)) if os.path.isdir(LIVE_DIR) else []:
        if f.endswith(".swift"):
            for n, line in enumerate(open(os.path.join(LIVE_DIR, f), encoding="utf-8"), 1):
                hits += [f"{f}:{n} {p}" for p in LIVE_BANNED if re.search(p, line)]
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
    try:
        os.unlink(LINK)      # 中途出错也不留 /tmp/xpls.* 这个链接
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
