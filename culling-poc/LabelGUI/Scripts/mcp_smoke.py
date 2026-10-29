#!/usr/bin/env python3
"""MCP 冒烟（v1，DESIGN §10.7 的 1–7 组）：没有 app、不起宿主，只测 `LabelGUI --mcp` 自己。

用法: python3 -I Scripts/mcp_smoke.py <LabelGUI 可执行文件> --ci [--protocol-only] [--work <目录>] [--keep]
  --ci             必须带：只用临时数据目录和合成的 fixture（v1 的 mcp_smoke 没有本地照片模式）
  --protocol-only  给 build_app.sh 打出来的 app 里的二进制用：不跑第 2 组（fixture 场次、工具语义）和第 7 组（RSS），
                   其余照跑 —— sync、设置域、Bundle 这几条只有 app 里的二进制才走得到
1 协议（握手、tools/list 和 schema、错误码、stdout 纯净、并发、busy、取消、压力、客户端 fd 的怪样子、退出） 2 没有 app
（S2：fixture 场次的各个字段、最多 15 场、sessions.json 坏了 / 缺字段 / 没有；受保护位置（含换个写法的：ſ、ﬆ、K、
/.nofollow/…）拿 sandbox-exec 证明一次都没碰；
模板 / 分类数和源码里的模板库、画布别名和 CLI 的表、style / look / kit 和 schema 的 enum 对得上；category / include / 截断）
3 只读不变量  4 不建目录  5 无界面  6 不进程序坞  7 RSS

不碰用户：每个进程都带 LABELGUI_NO_GUI=1 和 `--` 开头的无头参数，LABELGUI_DATA_DIR、LABELGUI_LIVE_SOCK_ROOT 和
LABELGUI_MCP_OUT 都是自己的临时目录（指到真实数据目录就退出 2）；只杀自己起的子进程。会开界面的反向用例（写错的参数、管道起）
只在 CI 上跑（--ci 而且 GITHUB_ACTIONS=true）；本地靠 --mcp-selftest 拿假输入测那道闸的判断。
"不设 LABELGUI_DATA_DIR" 的用例也只在 CI 上跑（$HOME 改不掉 Application Support 的位置，DESIGN §10.5）。
原型：R3 的 client/mcp_client_test.py（协议、泄漏、取消）和 client/stress.py（并发大响应）。
"""
import base64, collections, glob, hashlib, json, os, pwd, re, select, shutil, signal, subprocess, sys, tempfile, threading, time
import unicodedata

ARGS = sys.argv[1:]
if not ARGS or ARGS[0].startswith("-"):
    print(__doc__)
    sys.exit(2)
BIN = os.path.abspath(ARGS[0])
CI = "--ci" in ARGS
PROTOCOL_ONLY = "--protocol-only" in ARGS
KEEP = "--keep" in ARGS
ON_GITHUB = os.environ.get("GITHUB_ACTIONS") == "true"
SLACK = 4.0 if ON_GITHUB else 1.0          # macos runner 是虚拟机：时间阈值放宽 4 倍（§6.1）
if not CI:
    print("mcp_smoke.py 只有 --ci 模式（临时数据目录 + 合成 fixture），请带 --ci")
    sys.exit(2)
if not os.access(BIN, os.X_OK):
    print(f"不是可执行文件：{BIN}")
    sys.exit(2)
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # culling-poc/LabelGUI
SRC = os.path.join(ROOT, "Sources", "LabelGUI")
FIX = os.path.join(ROOT, "Fixtures", "photot-session")
REAL_DATA = os.path.expanduser("~/Library/Application Support/选片工具")

if "--work" in ARGS:
    WORK = os.path.abspath(ARGS[ARGS.index("--work") + 1])
    WORK_MARK = os.path.join(WORK, ".mcp_smoke-work")
    # 开头、结尾都要整个删掉它：只认不存在的、空的、或者带着本脚本上次留下的标记文件的目录。
    # `--work .`、`--work ~/Pictures/…` 这种手误一律不碰。
    if os.path.lexists(WORK) and not (os.path.isdir(WORK) and not os.path.islink(WORK)
                                      and (not os.listdir(WORK) or os.path.isfile(WORK_MARK))):
        print(f"--work {WORK} 不是空目录，也不是 mcp_smoke.py 自己建的（没有 .mcp_smoke-work 标记）：不删它，不跑")
        sys.exit(2)
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    open(WORK_MARK, "w").close()
else:
    WORK = tempfile.mkdtemp(prefix="mcp_smoke.")
# socket 根目录要短（sun_path 只有 104 字节），单独放在 /tmp 下。v1 的 S1 还不连 app，设上它是为了以后也不会碰到真实的 SockDir。
SOCK_ROOT = tempfile.mkdtemp(prefix="xpms.", dir="/tmp")

failures = []
counts = {"ok": 0}


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg, flush=True)
    if cond:
        counts["ok"] += 1
    else:
        failures.append(msg)


def same_dir(a, b):
    try:
        sa, sb = os.stat(a), os.stat(b)
        return (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino)
    except OSError:
        return os.path.realpath(a) == os.path.realpath(b)


MCP_OUT = os.path.join(WORK, "mcp-out")


def env_for(data_dir, **extra):
    """子进程的环境：总是带 LABELGUI_NO_GUI=1、自己的数据目录和 socket 根目录。data_dir=None 只给 CI 上那一条用。"""
    env = {k: v for k, v in os.environ.items() if not k.startswith("LABELGUI_")}
    env["LABELGUI_NO_GUI"] = "1"
    env["LABELGUI_LIVE_SOCK_ROOT"] = SOCK_ROOT
    # 预览输出目录（§10.3）：测试绝不碰 ~/Pictures/xuanpian-mcp；这里没有 app、存不了图，所以它一直不该被建出来
    env["LABELGUI_MCP_OUT"] = MCP_OUT
    if data_dir is not None:
        if same_dir(data_dir, REAL_DATA) or os.path.realpath(data_dir) == os.path.realpath(REAL_DATA):
            print(f"LABELGUI_DATA_DIR 指到了真实数据目录 {REAL_DATA}：不跑")
            sys.exit(2)
        env["LABELGUI_DATA_DIR"] = data_dir
    for k, v in extra.items():
        if v is None:
            env.pop(k, None)
        else:
            env[k] = v
    return env


def run_cli(args, data_dir, timeout=20, stdin=subprocess.DEVNULL, wrap=(), **extra):
    """wrap：套在 LabelGUI 前面的命令（第 2 组的 sandbox-exec）。LabelGUI 自己的参数照样必须 -- 开头。"""
    assert args and args[0].startswith("--"), "本地起的进程必须带 -- 开头的无头参数"
    return subprocess.run([*wrap, BIN, *args], env=env_for(data_dir, **extra), stdin=stdin, capture_output=True,
                          timeout=timeout, cwd=WORK)


class Server:
    """起一个 `--mcp`：stdout 按需读（不读就是给服务器背压），stderr 后台收。"""

    def __init__(self, data_dir, args=("--mcp",), wrap=(), **extra):
        assert args and args[0].startswith("--"), "本地起的进程必须带 -- 开头的无头参数"
        self.spawned = time.time()
        self.proc = subprocess.Popen([*wrap, BIN, *args], env=env_for(data_dir, **extra), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, cwd=WORK)
        self.fd = self.proc.stdout.fileno()
        self.buf = b""
        self.backlog = []       # 读到了、还没被 wait_for 取走的消息
        self.raw = {}           # id → 原始帧（压力测试比字节）
        self.leaks = []         # stdout 上解析不了的行
        self.stderr = []
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _drain_stderr(self):
        for line in self.proc.stderr:
            self.stderr.append(line.decode("utf-8", "replace").rstrip("\n"))

    def send(self, obj):
        self.send_raw((json.dumps(obj, ensure_ascii=False) + "\n").encode())

    def send_raw(self, data):
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def request(self, i, method, params=None):
        msg = {"jsonrpc": "2.0", "id": i, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)

    def call(self, i, name, arguments=None):
        self.request(i, "tools/call", {"name": name, "arguments": {} if arguments is None else arguments})

    def read_msg(self, timeout):
        """读下一帧；超时或 EOF 回 None。"""
        end = time.time() + timeout
        while b"\n" not in self.buf:
            left = end - time.time()
            if left <= 0 or not select.select([self.fd], [], [], left)[0]:
                return None
            chunk = os.read(self.fd, 1 << 20)
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        try:
            msg = json.loads(line)
        except Exception:
            self.leaks.append(line[:200])
            return self.read_msg(max(0.0, end - time.time()))
        if isinstance(msg, dict) and "id" in msg:
            self.raw.setdefault(json.dumps(msg.get("id")), []).append(line)
        return msg

    def wait_for(self, pred, timeout=10):
        for i, m in enumerate(self.backlog):
            if pred(m):
                return self.backlog.pop(i)
        end = time.time() + timeout
        while time.time() < end:
            m = self.read_msg(end - time.time())
            if m is None:
                return None
            if pred(m):
                return m
            self.backlog.append(m)
        return None

    def reply(self, i, timeout=10):
        return self.wait_for(lambda m: isinstance(m, dict) and m.get("id") == i and ("result" in m or "error" in m), timeout)

    def initialize(self, version="2025-11-25", name="smoke"):
        t0 = time.time()
        self.request("init", "initialize", {"protocolVersion": version, "capabilities": {"roots": {"listChanged": True}},
                                            "clientInfo": {"name": name, "version": "0"}})
        r = self.reply("init", 10)
        rtt = time.time() - t0
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return r, rtt

    def tool(self, i, name, arguments=None, timeout=10):
        """调一个工具，回 (result 对象, text 解析出来的 JSON)。"""
        self.call(i, name, arguments)
        r = self.reply(i, timeout)
        res = (r or {}).get("result") or {}
        texts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
        try:
            body = json.loads(texts[0]) if texts else None
        except Exception:
            body = None
        return res, body, (texts[0] if texts else "")

    def close(self, timeout=5):
        """关 stdin，等它自己退；回 (退出码, 用了几秒)。不退就杀掉（只杀自己起的这个）。"""
        t0 = time.time()
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            rc = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            rc = None
        return rc, time.time() - t0

    def drain(self, timeout=0.3):
        out = []
        while True:
            m = self.read_msg(timeout)
            if m is None:
                return out
            out.append(m)


def tree_manifest(path):
    """整棵目录树：每一项的类型、大小、mtime_ns、文件的 sha256（目录的 mtime 也算：建了又删的文件会动它）。"""
    rows = []
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames.sort()
        for name in sorted(dirnames) + sorted(filenames):
            p = os.path.join(dirpath, name)
            st = os.lstat(p)
            digest = ""
            if os.path.isfile(p) and not os.path.islink(p):
                with open(p, "rb") as f:
                    digest = hashlib.sha256(f.read()).hexdigest()
            rows.append((os.path.relpath(p, path), st.st_mode, st.st_size, st.st_mtime_ns, digest))
    st = os.stat(path)
    rows.append((".", st.st_mode, 0, st.st_mtime_ns, ""))
    return rows


def defaults_export(domain):
    r = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
    return (r.returncode, r.stdout if r.returncode == 0 else b"")


def labelgui_processes():
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    procs = {}
    for line in out.splitlines():
        line = line.strip()
        pid, _, cmd = line.partition(" ")
        if cmd.startswith(BIN):
            procs[int(pid)] = cmd
    return procs


# ---------------------------------------------------------------- 准备

TOOLS_18 = ["app_status", "cull_list_sessions", "collage_list_templates", "cull_session_overview", "cull_list_photos",
            "cull_get_photos", "cull_list_groups", "cull_preview_photos", "collage_get_state", "app_open_session",
            "cull_set_verdicts", "cull_show_photos", "collage_apply_template", "collage_run_kit", "collage_next_cover",
            "collage_set_text", "collage_set_style", "app_undo"]
ALWAYS = TOOLS_18[:3]
APP_TOOLS = TOOLS_18[3:]
# 描述里出现的 app_* / cull_* / collage_* 名字里，这些是错误码不是工具。
ERROR_CODES = {"app_not_running", "app_unreachable", "app_unresponsive", "app_version_mismatch", "app_outcome_unknown",
               "app_restarted", "app_too_old"}
FIXTURE_PHOTOS = "/tmp/labelgui-fixture-photot"   # 和 verdict_regression.sh 同一个约定：这个文件夹不存在
print(f"二进制: {BIN}\n工作目录: {WORK}\nsocket 根目录: {SOCK_ROOT}\n模式: {'--protocol-only' if PROTOCOL_ONLY else '--ci'}"
      f"{'（GitHub Actions）' if ON_GITHUB else '（本地）'}")

defaults_before = {d: defaults_export(d) for d in ("LabelGUI", "local.culling.labelgui")}
# fixture 数据目录：sessions.json 一条 + 这一场的 manifest / layer1（照 §6.1 第 2 组、verdict_regression.sh）。
# key 用二进制自己算（--session-key），在另一个临时数据目录里跑，fixture 目录里只有脚本放进去的东西。
KEYCALC = os.path.join(WORK, "keycalc")
r = run_cli(["--session-key", FIXTURE_PHOTOS], KEYCALC)
KEY = r.stdout.decode().strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
check(re.fullmatch(r"[0-9a-f]{16}", KEY) is not None, f"--session-key 算出 16 位 key：{KEY!r}")
# 对照：同一个二进制走普通 CLI 会建数据目录、注册字体（app 里的二进制还会同步 runtime/）；后面 --mcp* 的数据目录里就不能有这些。
check(os.path.isdir(os.path.join(KEYCALC, "fonts")),
      f"对照：普通 CLI 在它的数据目录里建了 fonts/（{sorted(os.listdir(KEYCALC)) if os.path.isdir(KEYCALC) else '目录没建'}）")


def session_key(path):
    """BatchStore.sessionKey(for:)：FNV-1a 算在文件 URL 的 path 上，那是分解形式（NFD；这里的路径都是 ASCII 和汉字，两种一样）。"""
    h = 0xcbf29ce484222325
    for b in unicodedata.normalize("NFD", path).encode():
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


check(session_key(FIXTURE_PHOTOS) == KEY, f"脚本自己算的 key 和 --session-key 一样（{session_key(FIXTURE_PHOTOS)}）")
# 受保护位置的 key 只能脚本自己算：--session-key 走 standardizedFileURL，会去 stat 那个路径。
# 这些路径本脚本也一次都不 stat（os.path.exists、realpath 都不调）：桌面上的那个一碰就可能以终端的名义弹授权框。
HOME = pwd.getpwuid(os.getuid()).pw_dir            # 和 NSHomeDirectory() 一样取用户记录里的，不看 $HOME
TAG = f"xp-mcp_smoke-{os.getpid()}-{int(time.time())}"
DESK_GHOST = os.path.join(HOME, "Desktop", TAG, "never")
VOL_GHOST = os.path.join("/Volumes", TAG)
ONLINE = os.path.join(WORK, "在线照片")
LINK_DESK = os.path.join(WORK, "link-to-desktop")   # 符号链接 → 桌面上那个：光看字符串不受保护，逐段走才看得出来
LINK_ONLINE = os.path.join(WORK, "link-online")
A_FILE = os.path.join(WORK, "a-file.jpg")           # 在，但不是文件夹
os.makedirs(ONLINE)
os.symlink(DESK_GHOST, LINK_DESK)
os.symlink(ONLINE, LINK_ONLINE)
open(A_FILE, "wb").close()


def entry(path, count, **kw):
    e = {"key": session_key(path), "path": path, "name": os.path.basename(path),
         "lastAnalyzed": "2026-10-26T17:00:00Z", "photoCount": count}
    e.update(kw)
    return {k: v for k, v in e.items() if v is not None}


# (sessions.json 里的一条, 期望的 folder_online, 期望的 protected_location)；顺序就是 app「最近场次」的顺序
SESSIONS = [
    (entry(FIXTURE_PHOTOS, 21, key=KEY, name="labelgui-fixture-photot", bookmark=base64.b64encode(b"not-a-bookmark").decode()),
     False, False),
    (entry(DESK_GHOST, 3), None, True),
    (entry(VOL_GHOST, 4), None, True),
    (entry(ONLINE, 5), True, False),
    (entry(LINK_DESK, 6), None, True),
    (entry(LINK_ONLINE, 7), True, False),
    (entry(A_FILE, 8), False, False),
]
FIXTURE = os.path.join(WORK, "data-fixture")
os.makedirs(os.path.join(FIXTURE, "sessions", KEY))
if os.path.isdir(FIX):
    for name in ("manifest.json", "layer1_results.json"):
        shutil.copy(os.path.join(FIX, name), os.path.join(FIXTURE, "sessions", KEY, name))
with open(os.path.join(FIXTURE, "sessions.json"), "w") as f:
    json.dump([e for e, _, _ in SESSIONS], f, ensure_ascii=False)
# 另外三个数据目录：17 场（app 只认前 15）、sessions.json 坏了、sandbox 的对照（那一场在 sandbox 禁掉的非受保护位置）
MANY = os.path.join(WORK, "data-many")
os.makedirs(MANY)
with open(os.path.join(MANY, "sessions.json"), "w") as f:
    json.dump([entry(os.path.join(WORK, "many", f"shoot{i:02d}"), i) for i in range(17)], f)
BAD = os.path.join(WORK, "data-bad")
os.makedirs(BAD)
with open(os.path.join(BAD, "sessions.json"), "w") as f:
    f.write('[{"key": "0123456789abcdef", "path": ')
CTL_GHOST = os.path.join(WORK, "ctl-ghost", "never")
CTL = os.path.join(WORK, "data-ctl")
os.makedirs(CTL)
with open(os.path.join(CTL, "sessions.json"), "w") as f:
    json.dump([entry(CTL_GHOST, 1)], f)
# 一条缺 name：app 的 JSONDecoder 整个解不出来（「最近场次」是空的），MCP 也只能列空的；数据目录在、没有 sessions.json
NONAME = os.path.join(WORK, "data-noname")
os.makedirs(NONAME)
with open(os.path.join(NONAME, "sessions.json"), "w") as f:
    json.dump([entry(ONLINE, 5), entry(os.path.join(WORK, "noname"), 1, name=None)], f, ensure_ascii=False)
NOINDEX = os.path.join(WORK, "data-noindex")
os.makedirs(NOINDEX)

# 换个写法指进受保护位置（S2 评审）：APFS 按 Unicode 完整的大小写折叠比名字（ſ = s、ﬆ = st、K = k），根下的
# /.nofollow/、/.resolve/<n>/ 是内核认的前缀。只会 lowercased() 的判断会把这些当成普通路径去 lstat，落点就是真的桌面。
# 折成 ASCII 的字符用 Python 自己的 Unicode 表找（和 Swift 的 Foundation 是两份实现），每个先在 WORK 里实测：建 ASCII
# 名字的目录，换了字符的写法 lstat 必须找得到（APFS 真把它们当成同一个名字），不然这条 ghost 指不进去，证明不了什么。
# 这几条指的是假 home 里的桌面、文稿、下载（子进程 HOME 指过去，ProtectedPaths 认 $HOME）：哪天判断又漏了，被 sandbox
# 杀掉的也只是对假 home 的访问，不会以终端的名义去碰真的桌面。/Volumes 用真的（和 VOL_GHOST 一样，根下的查找）。
FOLD_CHARS = {}
for cp in range(0x80, 0x110000):
    folded = unicodedata.normalize("NFC", unicodedata.normalize("NFC", chr(cp)).casefold())
    if folded and all("a" <= x <= "z" for x in folded):
        FOLD_CHARS[chr(cp)] = folded
APFS_PROBE = os.path.join(WORK, "apfs-fold")
apfs_distinct = []
for i, (ch, folded) in enumerate(sorted(FOLD_CHARS.items())):
    os.makedirs(os.path.join(APFS_PROBE, f"{i}-{folded}-x"))
    if not os.path.lexists(os.path.join(APFS_PROBE, f"{i}-{ch}-x")):
        apfs_distinct.append(ch)
check(len(FOLD_CHARS) >= 8 and not apfs_distinct,
      f"APFS 和 Unicode 完整折叠一致：{len(FOLD_CHARS)} 个折成 ASCII 的字符（{''.join(sorted(FOLD_CHARS))}）换进名字里都找得到 {apfs_distinct}")
FAKEHOME = os.path.join(WORK, "fakehome")
for d in ("Desktop", "Documents", "Downloads"):
    os.makedirs(os.path.join(FAKEHOME, d))
REAL_FAKEHOME = os.path.realpath(FAKEHOME)


def fold_variants(name):
    """name 里第一处能被某个字符折出来的子串换成那个字符，每个字符一种写法。"""
    out = []
    for ch, folded in sorted(FOLD_CHARS.items()):
        i = name.lower().find(folded)
        if i >= 0:
            out.append(name[:i] + ch + name[i + len(folded):])
    return out


FOLD_GHOSTS = []      # (路径, 能不能拿 /bin/test -e 对照：落点在 sandbox 禁掉的地方)
for d in ("Desktop", "Documents", "Downloads"):
    FOLD_GHOSTS += [(os.path.join(FAKEHOME, v, TAG, "never"), True) for v in fold_variants(d)]
FOLD_GHOSTS += [(os.path.join("/", v, TAG), True) for v in fold_variants("Volumes")]
FOLD_GHOSTS += [("/" + v + "/Volumes/Data" + os.path.join(REAL_FAKEHOME, "Desktop", TAG, "never"), True)
                for v in fold_variants("System")]
FOLD_GHOSTS += [("/.nofollow" + os.path.join(REAL_FAKEHOME, "Desktop", TAG, "never"), True),
                ("/.resolve/1" + os.path.join(REAL_FAKEHOME, "Desktop", TAG, "never"), False)]
FOLD_GHOSTS += [(os.path.join(WORK, v, "a"), False) for v in fold_variants("x.photoslibrary")]
FOLD_DIRS = []        # sessions.json 一份最多 15 条（app 只认前 15），多了分几份
for i in range(0, len(FOLD_GHOSTS), 15):
    d = os.path.join(WORK, f"data-fold{i // 15}")
    os.makedirs(d)
    with open(os.path.join(d, "sessions.json"), "w") as f:
        json.dump([entry(g, 1) for g, _ in FOLD_GHOSTS[i:i + 15]], f, ensure_ascii=False)
    FOLD_DIRS.append(d)
fixture_before = {d: tree_manifest(d) for d in (FIXTURE, MANY, BAD, CTL, NONAME, NOINDEX, *FOLD_DIRS)}
procs_before = labelgui_processes()

# ---------------------------------------------------------------- 0. 受保护位置（门禁：先跑）
# 后面几组都拿这份 fixture 不在 sandbox 里跑（列场次、压力、RSS）。万一 --mcp 真去碰了桌面，不在 sandbox 里就是以终端的
# 名义碰，可能弹授权框 —— 所以这一组放在最前面，没过就不往下跑。

def call_body(r):
    """--mcp-call 的结果：text 块解析出来的 JSON；不是一行 JSON 就是 None。"""
    try:
        return json.loads(json.loads(r.stdout.decode().splitlines()[0])["content"][0]["text"])
    except Exception:
        return None


def check_session_rows(res, ls, label):
    """fixture 的 7 场：顺序、folder_online / protected_location、字段（S2，§3.1）。"""
    rows_ = (ls or {}).get("sessions", [])
    got = [(r_.get("session"), r_.get("folder"), r_.get("folder_online"), r_.get("protected_location")) for r_ in rows_]
    want = [(e["key"], e["path"], online, prot) for e, online, prot in SESSIONS]
    check(not res.get("isError") and (ls or {}).get("total") == len(SESSIONS) and (ls or {}).get("truncated") is False
          and got == want,
          f"{label} cull_list_sessions：{len(SESSIONS)} 场按顺序；桌面、/Volumes、指进桌面的符号链接 → folder_online:null + "
          f"protected_location:true；在线的、指向在线的链接 → true；不存在的、是个文件的 → false" + ("" if got == want else f"：{got}"))
    keys = {"session", "folder", "name", "photo_count", "last_analyzed", "in_recent_list", "folder_online", "protected_location"}
    check(rows_ and all(set(r_) == keys for r_ in rows_),
          f"{label} 每一行恰好这些字段（没有 open_in_app、bookmark）：{[sorted(set(r_) ^ keys) for r_ in rows_]}")
    check([r_.get("name") for r_ in rows_] == [e["name"] for e, _, _ in SESSIONS]
          and [r_.get("photo_count") for r_ in rows_] == [e["photoCount"] for e, _, _ in SESSIONS]
          and all(r_.get("in_recent_list") is True and r_.get("last_analyzed") == "2026-10-26T17:00:00Z" for r_ in rows_),
          f"{label} name、photo_count、last_analyzed、in_recent_list")
    check(not (ls or {}).get("warnings"), f"{label} 没有 warning：{(ls or {}).get('warnings')}")


# 受保护位置一次都没碰：在 sandbox-exec 里跑，规则是「碰到这些路径（读、写、连查一下在不在都算）就 SIGKILL」。
# file-test-existence 管的正是对不存在路径的 stat / lstat / access（S2 实测：只禁 file-read* 时，stat 一个不存在的
# 路径不会触发；加上它以后，不存在的路径本身、更深的子路径、经符号链接、换大小写都会触发）。规则在系统调用进内核时
# 判断，不管调用来自 Foundation 还是 libc、走哪个函数名，都绕不过去（DYLD 插桩做不到这一点）。
# 对照：同一条 deny 里还放了一个不受保护、只是被规则禁掉的 CTL_GHOST；只有那一场的数据目录上，同一个二进制被杀，
# 证明这条规则确实生效、而且抓得到 folderOnline 真正用的那个系统调用。所以 FIXTURE 上没被杀 = 从没碰过桌面、文稿、
# 下载、/Volumes、/Network、/net 下的任何路径（包括指进桌面的那个符号链接的目标）。
print("0. 受保护位置一次都没碰（sandbox-exec，碰一下就 SIGKILL；所有模式都先跑这一组）")
gate_start = len(failures)
SANDBOX = "/usr/bin/sandbox-exec"
sb_str = lambda p_: '"' + p_.replace("\\", "\\\\").replace('"', '\\"') + '"'
# sandbox 的路径规则比的是内核解析完的真实路径（WORK 在 /var/folders 下，内核看到的是 /private/var/folders/…：
# 第一次写成 WORK 原样，对照那一条就没被杀 —— 这正是对照要抓的「规则没生效」）。所以规则里的路径都先 realpath：
# HOME 本身可以 realpath（碰的是家目录，不是桌面），桌面、文稿、下载只按字符串接在后面，不去 realpath 它们。
# 对照禁的是 ctl-ghost 这一段：逐段走到第一个不存在的段就停，禁它下面的 never 抓不到。
REAL_HOME = os.path.realpath(HOME)
DENY = ([os.path.join(h_, d) for h_ in (REAL_HOME, REAL_FAKEHOME) for d in ("Desktop", "Documents", "Downloads")]
        + ["/Volumes", "/Network", "/net"] + [os.path.join(os.path.realpath(WORK), "ctl-ghost")])
# 经 firmlink 走进去（/System/Volumes/Data/Users/x/Desktop/…）时，sandbox 比的是这个写法，不是 /Users/x/Desktop（S2 实测）：
# 两种都禁。
DENY += ["/System/Volumes/Data" + d for d in DENY]
PROFILE = ("(version 1)(allow default)(deny file-read* file-write* file-test-existence "
           + " ".join(f"(subpath {sb_str(d)})" for d in DENY) + " (with send-signal SIGKILL))")
SB = (SANDBOX, "-p", PROFILE)
if not os.access(SANDBOX, os.X_OK):
    check(False, f"找不到 {SANDBOX}：「受保护位置一次都没碰」这一条证明不了")
else:
    r = run_cli(["--mcp-call", "cull_list_sessions", "{}"], CTL, wrap=SB)
    check(r.returncode == -signal.SIGKILL,
          f"对照：同一份规则下，那一场在被禁掉的（不受保护的）不存在路径上 → 进程被 SIGKILL（退出码 {r.returncode}）")
    r = run_cli(["--mcp-call", "cull_list_sessions", "{}"], FIXTURE, wrap=SB)
    body = call_body(r)
    check(r.returncode == 0 and body is not None, f"sandbox 里 --mcp-call cull_list_sessions 正常跑完（退出码 {r.returncode}，被杀是 -9）")
    check_session_rows({}, body, "sandbox 里 --mcp-call")
    r = run_cli(["--mcp-call", "app_status", "{}"], FIXTURE, wrap=SB)
    check(r.returncode == 0 and (call_body(r) or {}).get("sessions") == len(SESSIONS), f"sandbox 里 --mcp-call app_status（退出码 {r.returncode}）")
    s = Server(FIXTURE, wrap=SB)
    s.initialize()
    s.request("sbl", "tools/list")
    tl_sb = s.reply("sbl")
    _, st_sb, _ = s.tool("sb1", "app_status")
    res_sb, ls_sb, _ = s.tool("sb2", "cull_list_sessions")
    _, ls_sb2, _ = s.tool("sb3", "cull_list_sessions", {"limit": 5})
    _, lt_sb, _ = s.tool("sb4", "collage_list_templates")
    _, b_sb, _ = s.tool("sb5", "cull_session_overview", {"session": DESK_GHOST})
    rc, dt = s.close()
    check(rc == 0 and tl_sb is not None and st_sb is not None and ls_sb2 is not None and lt_sb is not None
          and (b_sb or {}).get("error", {}).get("code") == "app_not_running",
          f"sandbox 里的 --mcp：握手、tools/list、app_status、两次 cull_list_sessions、collage_list_templates、session 填桌面"
          f"路径的 cull_session_overview（app_not_running）都照常回，EOF 退出码 {rc}（被杀是 -9）")
    check_session_rows(res_sb, ls_sb, "sandbox 里的 --mcp")
    # 换写法的 ghost：先拿 /bin/test -e 在同一份规则下对照（被杀 = 这个写法真的落进被禁的位置），再看 --mcp-call 没被杀、
    # 每一行都是 protected_location:true、folder_online:null。/.resolve/1/… 和 .photoſlibrary 对照不了（后者不在禁的地方），
    # 只看行。
    not_killed = []
    for g, ctl in FOLD_GHOSTS:
        if ctl and subprocess.run([*SB, "/bin/test", "-e", g], env=env_for(None), cwd=WORK).returncode != -signal.SIGKILL:
            not_killed.append(g)
    check(not not_killed, f"对照：{sum(c for _, c in FOLD_GHOSTS)} 条换写法的路径（Deſktop、DesKtop、Volumeſ、Syﬆem/…、/.nofollow/…）"
          f"同一份规则下 /bin/test -e 被杀，说明内核确实把它们解析进了被禁的位置 {not_killed}")
    fold_rows, fold_rc = [], []
    for d in FOLD_DIRS:
        r = run_cli(["--mcp-call", "cull_list_sessions", '{"limit":100}'], d, wrap=SB, HOME=FAKEHOME)
        fold_rc.append(r.returncode)
        fold_rows += (call_body(r) or {}).get("sessions", [])
    bad_rows = [(r_.get("folder"), r_.get("folder_online"), r_.get("protected_location")) for r_ in fold_rows
                if r_.get("folder_online") is not None or r_.get("protected_location") is not True]
    check(set(fold_rc) == {0} and [r_.get("folder") for r_ in fold_rows] == [g for g, _ in FOLD_GHOSTS] and not bad_rows,
          f"sandbox 里 {len(FOLD_GHOSTS)} 条换写法的场次：没被杀（退出码 {fold_rc}），全部 protected_location:true、"
          f"folder_online:null {bad_rows}")

gate_failed = failures[gate_start:]
if gate_failed:
    print("受保护位置这一组没过：后面的用例不跑（不在 sandbox 里再跑，就可能真的以终端的名义去碰桌面）")
    for f in gate_failed:
        print("  FAIL " + f)
    shutil.rmtree(SOCK_ROOT, ignore_errors=True)
    if not KEEP:
        shutil.rmtree(WORK, ignore_errors=True)
    sys.exit(1)

# ---------------------------------------------------------------- 1. 协议

print("1. 协议")
# 握手：先 server/discover（Claude Code 就是这么探的）→ 立刻 -32601；四种请求的版本各起一个进程。
for asked, answered in (("2025-11-25", "2025-11-25"), ("2025-06-18", "2025-06-18"),
                        ("2025-03-26", "2025-11-25"), ("1999-01-01", "2025-11-25")):
    s = Server(FIXTURE)
    t0 = time.time()
    s.request("d0", "server/discover", {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                                  "io.modelcontextprotocol/clientCapabilities": {}}})
    d = s.reply("d0", 5)
    check(d is not None and d.get("error", {}).get("code") == -32601 and time.time() - t0 < 1.0 * SLACK,
          f"server/discover 立刻回 -32601（{(time.time() - t0) * 1000:.0f} ms）")
    r, rtt = s.initialize(asked)
    res = (r or {}).get("result", {})
    check(res.get("protocolVersion") == answered, f"initialize 请求 {asked} → 回 {res.get('protocolVersion')}（期望 {answered}）")
    if asked == "2025-11-25":
        cold = time.time() - s.spawned
        check(rtt < 1.0 * SLACK and cold < 1.0 * SLACK,
              f"initialize 往返 {rtt * 1000:.0f} ms，从起进程算 {cold * 1000:.0f} ms，都 < {1000 * SLACK:.0f} ms")
        si = res.get("serverInfo", {})
        check(si.get("name") == "xuanpian" and si.get("title") == "选片工具" and si.get("version"),
              f"serverInfo：{si}")
        check(res.get("capabilities") == {"tools": {"listChanged": False}}, f"capabilities：{res.get('capabilities')}")
        INSTRUCTIONS = res.get("instructions", "")
    s.request("p1", "ping")
    p = s.reply("p1", 5)
    check(p is not None and p.get("result") == {}, "ping 回 {}")
    rc, dt = s.close()
    check(any(f"initialize client=smoke 0 requested={asked} answered={answered}" in l for l in s.stderr),
          f"stderr 里有 initialize 那一行（{asked}）")
    check(not s.leaks, f"stdout 上只有 JSON（{asked}）：{s.leaks[:3]}")

s = Server(FIXTURE)
s.initialize()
# 未知通知：什么都不回（JSON-RPC 不许回通知）。之后的第一条消息必须是 ping 的回应。
s.send({"jsonrpc": "2.0", "method": "notifications/roots/list_changed"})
s.send({"jsonrpc": "2.0", "method": "notifications/whatever", "params": {"x": 1}})
s.request("p2", "ping")
first = s.read_msg(5)
check(first is not None and first.get("id") == "p2", f"未知通知没有回应（下一条就是 ping 的回应：{json.dumps(first)[:120]}）")

# tools/list
s.request("tl", "tools/list")
tl = s.reply("tl")
tools = (tl or {}).get("result", {}).get("tools", [])
names = [t.get("name") for t in tools]
check(names == TOOLS_18, f"tools/list 恰好 18 个、顺序同 §10.1：{names}")
TL_LIVE = tools


def schema_problems(schema, where):
    """够用的 JSON Schema 检查（只用标准库）：关键字都认识、type 合法、enum / default / 范围 / required 自洽。"""
    known = {"type", "properties", "required", "additionalProperties", "items", "enum", "default", "description",
             "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "uniqueItems", "pattern"}
    types = {"object", "array", "string", "integer", "number", "boolean"}
    out = []
    if not isinstance(schema, dict):
        return [f"{where} 不是对象"]
    for k in schema:
        if k not in known:
            out.append(f"{where} 有不认识的关键字 {k}")
    t = schema.get("type")
    if t not in types:
        out.append(f"{where} 的 type 是 {t!r}")

    def fits(v):
        return {"object": isinstance(v, dict), "array": isinstance(v, list), "string": isinstance(v, str),
                "integer": isinstance(v, int) and not isinstance(v, bool),
                "number": isinstance(v, (int, float)) and not isinstance(v, bool),
                "boolean": isinstance(v, bool)}.get(t, False)
    if "enum" in schema:
        e = schema["enum"]
        if not isinstance(e, list) or not e or len(set(map(json.dumps, e))) != len(e) or not all(fits(v) for v in e):
            out.append(f"{where} 的 enum 不对：{e}")
    if "default" in schema and (not fits(schema["default"]) or ("enum" in schema and schema["default"] not in schema["enum"])):
        out.append(f"{where} 的 default 不合 type/enum")
    for lo, hi in (("minimum", "maximum"), ("minLength", "maxLength"), ("minItems", "maxItems")):
        if lo in schema and hi in schema and schema[lo] > schema[hi]:
            out.append(f"{where} 的 {lo} > {hi}")
    if "default" in schema and t in ("integer", "number"):
        if schema["default"] < schema.get("minimum", float("-inf")) or schema["default"] > schema.get("maximum", float("inf")):
            out.append(f"{where} 的 default 不在范围里")
    if "pattern" in schema:
        try:
            re.compile(schema["pattern"])
        except re.error:
            out.append(f"{where} 的 pattern 编不过")
    if t == "object":
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is not False:
            out.append(f"{where} 要 additionalProperties:false")
        for r_ in schema.get("required", []):
            if r_ not in props:
                out.append(f"{where} required 里的 {r_} 不在 properties 里")
        for k, v in props.items():
            if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", k):
                out.append(f"{where}.{k} 不是 snake_case")
            out += schema_problems(v, f"{where}.{k}")
    if t == "array":
        out += schema_problems(schema.get("items"), f"{where}[]")
    return out


def tool_names_in(text):
    return set(re.findall(r"\b(?:app|cull|collage)_[a-z_]+\b", text))


def check_tool_list(tools, instructions, expect, label):
    names = [t.get("name") for t in tools]
    check(names == expect, f"{label}：tools/list = {len(names)} 个，顺序对")
    problems = []
    for t in tools:
        n = t.get("name", "?")
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", n):
            problems.append(f"名字 {n}")
        root = t.get("inputSchema", {})
        if any(k in root for k in ("anyOf", "oneOf", "allOf")) or root.get("type") != "object":
            problems.append(f"{n} 根部要是 object，不能有 anyOf/oneOf/allOf")
        problems += schema_problems(root, n)
        if not t.get("title") or not t.get("description") or len(t["description"]) > 2000:
            problems.append(f"{n} 的 title / description（≤2000 字）")
        a = t.get("annotations", {})
        if not isinstance(a.get("readOnlyHint"), bool) or a.get("openWorldHint") is not False:
            problems.append(f"{n} 的 annotations：{a}")
        if "description_disabled" in t:
            problems.append(f"{n} 漏出 description_disabled")
        flat = json.dumps(t, ensure_ascii=False)
        if '"$' in flat or "{{" in flat:
            problems.append(f"{n} 有没填的占位")
        stray = tool_names_in(t.get("description", "") + json.dumps(root, ensure_ascii=False)) - set(names) - ERROR_CODES
        if stray:
            problems.append(f"{n} 的描述提到了这一次没有的工具 {sorted(stray)}")
        want_meta = n in ("app_status", "cull_list_sessions")
        meta = t.get("_meta", {})
        if want_meta != (meta.get("anthropic/alwaysLoad") is True and meta.get("antigravity/alwaysLoad") is True):
            problems.append(f"{n} 的 _meta alwaysLoad")
    check(not problems, f"{label}：每个 schema 都是合法的 JSON Schema、根部 additionalProperties:false、描述只提列表里的工具"
                        + (f"：{problems[:6]}" if problems else ""))
    first = instructions.split("\n", 1)[0]
    stray = tool_names_in(instructions) - set(names) - ERROR_CODES
    check(0 < len(instructions) <= 4096 and len(first) <= 512 and not stray,
          f"{label}：instructions {len(instructions)} 字、第一段 {len(first)} 字、提到的工具都在列表里 {sorted(stray)}")


check_tool_list(TL_LIVE, INSTRUCTIONS, TOOLS_18, "LIVE")
by_name = {t["name"]: t for t in TL_LIVE}
ro = {n for n, t in by_name.items() if t["annotations"]["readOnlyHint"]}
check(ro == set(TOOLS_18[:9]), f"只读的是第 1–9 个：{sorted(ro)}")
check([n for n, t in by_name.items() if t["annotations"]["destructiveHint"]] == ["app_open_session"], "只有 app_open_session 是 destructive")

# 错误码（§1.2）
s.send_raw(b'{"jsonrpc":"2.0","id":10,"method":\n')
r = s.wait_for(lambda m: "error" in m and m.get("id") is None, 5)
check(r is not None and r["error"]["code"] == -32700, f"坏 JSON → -32700、id:null：{json.dumps(r)[:100]}")
s.send({"id": 11, "method": "ping"})
r = s.reply(11, 5)
check(r is not None and r.get("error", {}).get("code") == -32600, "缺 jsonrpc → -32600")
s.send({"jsonrpc": "2.0", "id": None, "method": "ping"})
r = s.wait_for(lambda m: m.get("error", {}).get("code") == -32600 and m.get("id") is None, 5)
check(r is not None, "id:null → -32600")
s.send([{"jsonrpc": "2.0", "id": 12, "method": "ping"}])
r = s.wait_for(lambda m: m.get("error", {}).get("code") == -32600 and m.get("id") is None, 5)
check(r is not None, "batch 数组 → -32600")
s.request(13, "tools/call", {"name": "app_status", "arguments": [1, 2]})
r = s.reply(13, 5)
check(r is not None and r.get("error", {}).get("code") == -32602, "arguments 不是对象 → -32602")
s.request(14, "tools/call", {"name": "no_such_tool", "arguments": {}})
r = s.reply(14, 5)
check(r is not None and r.get("error", {}).get("code") == -32602, "未知工具 → -32602")
s.request(15, "nope/method")
r = s.reply(15, 5)
check(r is not None and r.get("error", {}).get("code") == -32601, "未知方法 → -32601")
s.request(16, "tools/call", ["app_status"])
r = s.reply(16, 5)
check(r is not None and r.get("error", {}).get("code") == -32602, "tools/call 的 params 不是对象 → -32602")
s.request(17, "initialize", [1])
r = s.reply(17, 5)
s.request(18, "ping", [1])
r2 = s.reply(18, 5)
check(r is not None and r.get("error", {}).get("code") == -32602 and r2 is not None
      and r2.get("error", {}).get("code") == -32602, "initialize / ping 的 params 不是对象 → -32602（哪个方法都一样）")
s.request(19, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "again", "version": "9"}})
r = s.reply(19, 5)
check(r is not None and r.get("error", {}).get("code") == -32600, "第二个 initialize → -32600（握手只有一次）")
s.send({"jsonrpc": "2.0", "id": 191, "method": "ping", "params": None})
r = s.reply(191, 5)
check(r is not None and r.get("result") == {}, "params:null 当作没给（ping 照常回 {}）")

# app_status、一个要 app 的工具（§10.2：app 没开 → app_not_running）
res, st, text = s.tool(20, "app_status")
check(st is not None and st["live"]["state"] == "not_running" and st["writes"] == {
    "live": False, "headless": False, "reason": "v1 只有实时：app 开着时读和改都交给 app；app 没开时只能看状态、列场次和模板"},
    f"app_status：live.state=not_running、writes 照 §10.1")
check("\\/" not in text, "text 块里没有 \\/（路径不转义）")
for k in ("server", "data_dir", "data_dir_override", "data_dir_exists", "data_dir_readable", "sessions", "gui_running",
          "live", "output_root", "preview_cache_bytes", "limits", "writes", "client", "warnings", "next"):
    if st is None or k not in st:
        check(False, f"app_status 缺字段 {k}")
check(st is not None and not any(k in st for k in ("analysis_version", "renders_bytes", "protected_locations_allowed"))
      and "max_workers" not in st.get("limits", {}), "app_status 没有 §10.1 删掉的字段")
check(st is not None and st["client"] == {"name": "smoke", "version": "0", "requested_protocol": "2025-11-25"}
      and st["server"]["protocol"] == "2025-11-25",
      f"app_status.client / server.protocol 是第一次握手的（后面那两个 initialize 没改掉它）：{(st or {}).get('client')}")
check(st is not None and st["next"] == "请用户自己打开选片工具" and st["live"] == {"state": "not_running"},
      "app_status.next 让用户自己开 app")
res, body, _ = s.tool(21, "cull_session_overview", {"session": KEY})
check(res.get("isError") is True and (body or {}).get("error", {}).get("code") == "app_not_running"
      and "MCP 不会启动它" in body["error"].get("hint", ""), "要 app 的工具 → app_not_running，带 hint")

# 并发：一口气发 8 个，各回各的、帧完整
mix = ["app_status", "cull_list_sessions", "collage_list_templates", "cull_list_photos"] * 2
for i, n in enumerate(mix):
    s.call(f"c{i}", n, {"session": KEY} if n == "cull_list_photos" else {})
got = [s.reply(f"c{i}", 10) for i in range(8)]
check(all(g is not None and "result" in g for g in got) and not s.leaks, "8 个并发调用都回了、stdout 没有坏帧")
check(all(not g["result"].get("isError") for g, n in zip(got, mix) if n != "cull_list_photos"), "8 个并发里进程内工具都成功")
check(any("stdout 已接管" in l for l in s.stderr), "共用代码的 print 落在 stderr（启动那一行），stdout 上只有 JSON")
rc, dt = s.close()
check(rc == 0 and not s.leaks, f"stdout 全程只有 JSON 帧（{len(s.leaks)} 行坏的）")

# busy：客户端先不读 stdout，把管道塞满，写被堵住；这时候在途的调用写不出去、一直算在途 → 第 9 个起回 busy
s = Server(FIXTURE)
s.initialize()
for i in range(10):
    s.request(f"fill{i}", "tools/list")
time.sleep(0.5)
for i in range(12):
    s.call(f"b{i}", "app_status")
time.sleep(0.5)
got = {}
end = time.time() + 15
while len(got) < 22 and time.time() < end:
    m = s.read_msg(end - time.time())
    if m is None:
        break
    if isinstance(m, dict) and "id" in m:
        got[m["id"]] = m
fills = [got.get(f"fill{i}") for i in range(10)]
oks = [i for i in range(12) if got.get(f"b{i}") and not got[f"b{i}"]["result"].get("isError")]
busy = [i for i in range(12) if got.get(f"b{i}") and "\"busy\"" in got[f"b{i}"]["result"]["content"][0]["text"]]
check(all(f and len(f["result"]["tools"]) == 18 for f in fills), "管道塞满时 10 个 tools/list 最后都完整收到")
check(len(oks) == 8 and len(busy) == 4 and oks == list(range(8)), f"同时在途最多 8 个：成功 {oks}，busy {busy}")
check(len(set(map(lambda k: len(s.raw[k]), s.raw))) == 1, "每个 id 恰好一帧")
rc, dt = s.close()

# 取消：写被堵住时发 notifications/cancelled → 那个 id 一个字也不再发；不认识的 id 的取消被忽略；之后照常回 ping
s = Server(FIXTURE)
s.initialize()
for i in range(10):
    s.request(f"fill{i}", "tools/list")
time.sleep(0.5)
s.call("victim", "app_status")
time.sleep(0.3)
s.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "victim", "reason": "smoke"}})
s.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "nobody"}})
s.call("kept", "app_status")
s.request("after", "ping")
msgs = []
end = time.time() + 15
while time.time() < end:
    m = s.read_msg(min(1.0, end - time.time()))
    if m is None:
        break
    msgs.append(m)
ids = [m.get("id") for m in msgs if isinstance(m, dict)]
check("victim" not in ids, "取消以后这个 id 没有任何消息")
check("kept" in ids and "after" in ids and all(f"fill{i}" in ids for i in range(10)),
      "取消不影响别的请求：后面的调用和 ping 照常回")
s.call("done1", "app_status")
s.reply("done1", 5)
s.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "done1"}})
s.request("after2", "ping")
nxt = s.read_msg(5)
check(nxt is not None and nxt.get("id") == "after2", "取消一个已经回完的 id：什么都不发")
rc, dt = s.close()
check(rc == 0 and not s.leaks, "取消、busy 两段 stdout 都只有 JSON")

# 压力（源自 R3 client/stress.py）：每轮 8 个调用 + 2 个 tools/list，客户端先停读 0.2 s，帧不能交错、损坏
s = Server(FIXTURE)
s.initialize()
good = bad = 0
tl_frames = set()
for rnd in range(25):
    ids = []
    for k in range(8):
        i = f"r{rnd}-{k}"
        s.call(i, ALWAYS[k % 3], {})
        ids.append(i)
    for k in range(2):
        s.request(f"r{rnd}-tl{k}", "tools/list")
        ids.append(f"r{rnd}-tl{k}")
    time.sleep(0.2)
    pending = set(ids)
    end = time.time() + 10
    while pending and time.time() < end:
        m = s.read_msg(end - time.time())
        if m is None:
            break
        i = m.get("id") if isinstance(m, dict) else None
        if i in pending:
            pending.discard(i)
            ok = ("result" in m) and (not m["result"].get("isError"))
            good += ok
            bad += not ok
    bad += len(pending)
for k, frames in s.raw.items():
    if "-tl" in k:
        # 帧开头是各自的 id（键排过序，"id" 在最前），去掉它以后整帧逐字节比
        tl_frames.update(re.sub(rb'^\{"id":"[^"]*",', b"{", f) for f in frames)
rc, dt = s.close()
check(bad == 0 and good == 250 and not s.leaks, f"压力 25 轮 × 10：好 {good}，坏或缺 {bad}，坏帧 {len(s.leaks)}")
check(len(tl_frames) == 1, f"50 次 tools/list 的帧逐字节相同（{len(tl_frames)} 种）")

# 客户端那几个 fd 的怪样子：stderr 起来就是关着的、stderr 读端中途关掉、继承来的 O_NONBLOCK、管道一次灌完就关 stdin
INIT_LINE = (json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "fd", "version": "0"}}})
             + "\n").encode()
ONESHOT = INIT_LINE + b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n' \
    + b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"app_status","arguments":{}}}\n'


def frames_of(raw):
    """stdout 的每一行都要是 JSON；回 (id 列表, 解析不了的行)。"""
    ids, junk = [], []
    for line in raw.splitlines():
        try:
            ids.append(json.loads(line).get("id"))
        except Exception:
            junk.append(line[:120])
    return ids, junk


def oneshot_ok(raw):
    ids, junk = frames_of(raw)
    if ids != [1, 2] or junk:
        return False
    body = json.loads(json.loads(raw.splitlines()[1])["result"]["content"][0]["text"])
    return body.get("live", {}).get("state") == "not_running"


# 管道一次灌进请求就关 stdin（排错时常这么试）：在途的调用回完再退，结果不丢（3 次都要收到）
runs = [subprocess.run([BIN, "--mcp"], input=ONESHOT, env=env_for(FIXTURE), capture_output=True, timeout=10, cwd=WORK)
        for _ in range(3)]
check(all(x.returncode == 0 and oneshot_ok(x.stdout) for x in runs),
      f"管道一次灌完就关 stdin：3 次都收到 initialize 和 app_status 的结果 {[frames_of(x.stdout)[0] for x in runs]}")
# fd 2 起来就是关着的（`2>&-`）：print 不能落进协议管道，进程也不能 abort
p = subprocess.run(["/bin/sh", "-c", 'exec "$0" --mcp 2>&-', BIN], input=ONESHOT, env=env_for(FIXTURE),
                   stdout=subprocess.PIPE, timeout=10, cwd=WORK)
check(p.returncode == 0 and oneshot_ok(p.stdout), f"stderr 起来就关着：stdout 只有两帧 JSON、退出码 {p.returncode}（{frames_of(p.stdout)}）")
# 客户端不要日志、把 stderr 读端关了：写日志回 EPIPE 不能把进程弄死（以前 FileHandle 抛异常，SIGABRT）
p = subprocess.Popen([BIN, "--mcp"], env=env_for(FIXTURE), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, bufsize=0, cwd=WORK)
time.sleep(0.3)
p.stderr.close()
p.stdin.write(ONESHOT)
p.stdin.flush()
got_raw = b""
end = time.time() + 5
while got_raw.count(b"\n") < 2 and time.time() < end and select.select([p.stdout], [], [], end - time.time())[0]:
    chunk = os.read(p.stdout.fileno(), 1 << 20)
    if not chunk:
        break
    got_raw += chunk
p.stdin.close()
try:
    rc = p.wait(5)
except subprocess.TimeoutExpired:
    p.kill()
    rc = p.wait()
check(rc == 0 and oneshot_ok(got_raw), f"stderr 读端关掉以后照常回 initialize 和 app_status，EOF 退出码 {rc}")
# 继承来的 stdin / stdout 带 O_NONBLOCK：read 回 EAGAIN 不当 EOF，write 回 EAGAIN 不当客户端走了
r_in, w_in = os.pipe()
r_out, w_out = os.pipe()
os.set_blocking(r_in, False)
os.set_blocking(w_out, False)
p = subprocess.Popen([BIN, "--mcp"], env=env_for(FIXTURE), stdin=r_in, stdout=w_out, stderr=subprocess.DEVNULL, cwd=WORK)
os.close(r_in)
os.close(w_out)
time.sleep(0.3)                       # 这时候服务器的 read 碰上的是 EAGAIN
try:
    os.write(w_in, INIT_LINE + b"".join(b'{"jsonrpc":"2.0","id":"nb%d","method":"tools/list"}\n' % i for i in range(10)))
except BrokenPipeError:
    pass                              # 服务器已经把 EAGAIN 当成 EOF 退了：下面的断言会报
time.sleep(0.5)                       # 先不读：10 个 tools/list 塞满管道，服务器的 write 碰上 EAGAIN
got_raw = b""
end = time.time() + 10
while got_raw.count(b"\n") < 11 and time.time() < end and select.select([r_out], [], [], end - time.time())[0]:
    chunk = os.read(r_out, 1 << 20)
    if not chunk:
        break
    got_raw += chunk
os.close(w_in)
try:
    rc = p.wait(5)
except subprocess.TimeoutExpired:
    p.kill()
    rc = p.wait()
os.close(r_out)
ids, junk = frames_of(got_raw)
check(rc == 0 and not junk and ids == [1] + [f"nb{i}" for i in range(10)],
      f"stdin / stdout 带 O_NONBLOCK：11 帧都完整收到（{len(ids)} 帧、坏的 {len(junk)}），EOF 退出码 {rc}")

# --mcp-tools / --mcp-call：stdout 恰好一行 JSON
r = run_cli(["--mcp-tools"], FIXTURE)
lines = r.stdout.decode().splitlines()
mt = json.loads(lines[0]) if len(lines) == 1 else {}
check(r.returncode == 0 and len(lines) == 1 and [t["name"] for t in mt.get("tools", [])] == TOOLS_18
      and mt.get("tools") == TL_LIVE and mt.get("instructions") == INSTRUCTIONS,
      "--mcp-tools：一行 JSON，和 tools/list、instructions 一样")
r = run_cli(["--mcp-call", "app_status", "{}"], FIXTURE)
lines = r.stdout.decode().splitlines()
ok = r.returncode == 0 and len(lines) == 1
body = json.loads(json.loads(lines[0])["content"][0]["text"]) if ok else {}
check(ok and body.get("live", {}).get("state") == "not_running" and body.get("client") is None,
      "--mcp-call app_status '{}'：一行 JSON，退出码 0")
r = run_cli(["--mcp-call", "cull_set_verdicts", '{"session":"x","ids":["a"],"verdict":"pick"}'], FIXTURE)
check(r.returncode == 1 and b"app_not_running" in r.stdout, "--mcp-call 要 app 的工具 → app_not_running，退出码 1")
r = run_cli(["--mcp-call", "no_such_tool"], FIXTURE)
check(r.returncode == 2 and r.stdout == b"", "--mcp-call 未知工具 → 退出码 2，stdout 空")

# LABELGUI_MCP_LIVE=0：只有 3 个，instructions 换成短的那版，描述里不提别的工具
s = Server(FIXTURE, LABELGUI_MCP_LIVE="0")
r, _ = s.initialize()
instr0 = (r or {}).get("result", {}).get("instructions", "")
s.request("tl0", "tools/list")
tl0 = (s.reply("tl0") or {}).get("result", {}).get("tools", [])
check_tool_list(tl0, instr0, ALWAYS, "LIVE=0")
check(instr0.startswith("xuanpian 是本机「选片工具」的接口。这个服务器设了 LABELGUI_MCP_LIVE=0"), "LIVE=0 的 instructions")
res, st0, _ = s.tool("s0", "app_status")
check(st0 is not None and st0["live"]["state"] == "disabled" and st0["next"] == "cull_list_sessions", "LIVE=0：live.state=disabled")
s.call("x0", "cull_set_verdicts", {"session": KEY, "ids": ["a"], "verdict": "pick"})
r = s.reply("x0")
check(r is not None and r.get("error", {}).get("code") == -32602, "LIVE=0：要 app 的工具没注册（-32602）")
rc, dt = s.close()

# 不开界面那道闸的判断表（纯函数，假的 argv / ppid / tty / 环境变量）：二进制自己的期望 + 这里再用自己的规则核一遍
LABELS = {  # label → (argv[1] 算拼错, 有写对的无头参数)
    "no-args": (False, False), "--mcp": (False, True), "--mcp-call": (False, True), "--collage-ui": (False, True),
    "-mcp": (True, False), "mcp": (True, False), "em-dash-mcp": (True, False), "en-dash-mcp": (True, False),
    "double-em-dash-mcp": (True, False), "fullwidth-mcp": (True, False), "space-mcp": (True, False),
    "mcp-trailing-space": (True, False), "MCP-upper": (True, False), "mcp-server": (True, False),
    "--mcp-server": (True, False), "-collage-ui": (True, False), "em-dash-app-ui": (True, False), "app-ui": (True, False),
    "serve": (False, False), "--bogus": (False, False), "-NSDocumentRevisionsDebugMode": (False, False),
    "-psn": (False, False), "photo-dir": (False, False), "title-mcp": (False, True),
    "--live-host": (False, True), "em-dash-live-host": (True, False),
}
r = run_cli(["--mcp-selftest", "--json"], os.path.join(WORK, "never-selftest"))
rows = [json.loads(l) for l in r.stdout.decode().splitlines() if l.startswith("{")]
prot_rows = [x for x in rows if x.get("kind") == "protected"]
rows = [x for x in rows if "kind" not in x]
prot_bad = [x["path"] for x in prot_rows if x["expected"] != x["actual"]]
check(len(prot_rows) >= 80 and not prot_bad,
      f"--mcp-selftest 的受保护位置表：{len(prot_rows)} 条手写期望值全对 {prot_bad[:4]}（另有 session 解析、逐段解析、模板表几组，见退出码）")
mismatch = []
for row in rows:
    typo, headless = LABELS.get(row["label"], (None, None))
    if typo is None:
        mismatch.append(f"不认识的用例 {row['label']}")
        continue
    from_client = row["ppid"] != 1 and not row["tty"] and not row["allow_gui"]
    if typo:
        want = "refuse"
    elif row["stage"] == "early" and headless:
        want = "proceed"
    elif row["no_gui"] or from_client:
        want = "refuse"
    else:
        want = "proceed"
    if row["decision"] != want:
        mismatch.append(f"{row['stage']} {row['label']} ppid={row['ppid']} tty={row['tty']} no_gui={row['no_gui']} "
                        f"allow={row['allow_gui']}：{row['decision']}，应该 {want}")
check(r.returncode == 0 and b"\xe5\x85\xa8\xe9\x83\xa8\xe9\x80\x9a\xe8\xbf\x87" in r.stdout,  # 「全部通过」
      f"--mcp-selftest 退出码 0：{r.stdout.decode().splitlines()[-1] if r.stdout else r.stderr[-200:]}")
check(len(rows) == len(LABELS) * 32 and not mismatch, f"不开界面的闸：{len(rows)} 种组合和这里的规则一致 {mismatch[:4]}")
check(not os.path.exists(os.path.join(WORK, "never-selftest")), "--mcp-selftest 不建数据目录")
# 几条关键的，直接点名：访达 / 程序坞起（ppid 1，没参数）放行；终端里直接跑放行；管道起、没参数拦下；拼错的永远拦下
pick = {(x["label"], x["stage"], x["ppid"], x["tty"], x["no_gui"], x["allow_gui"]): x["decision"] for x in rows}
check(pick.get(("no-args", "last", 1, False, False, False)) == "proceed", "访达 / 程序坞起的 app（父进程 launchd）照常开")
check(pick.get(("no-args", "last", 4242, True, False, False)) == "proceed", "终端里直接跑照常开")
check(pick.get(("no-args", "early", 4242, False, False, False)) == "refuse", "MCP 客户端漏了 args（管道起、没参数）不开")
check(pick.get(("serve", "early", 4242, False, False, True)) == "proceed", "LABELGUI_ALLOW_GUI=1 绕过「像是客户端起的」")
check(pick.get(("serve", "last", 4242, True, True, True)) == "refuse", "LABELGUI_NO_GUI=1 压过 LABELGUI_ALLOW_GUI=1")
check(all(v == "refuse" for k, v in pick.items() if k[0] in ("-mcp", "em-dash-mcp", "space-mcp")), "拼错的 --mcp 任何情况都不开")

# ---------------------------------------------------------------- 2. 没有 app


def source_templates():
    """源码里的模板库：每个 `builtin: true, category: …` 算一个（category 写成常量的，取这个文件的 static let category）。"""
    counts = collections.Counter()
    total = 0
    for f in sorted(glob.glob(os.path.join(SRC, "Collage", "*.swift"))):
        text = open(f, encoding="utf-8").read()
        const = re.search(r'static let category = "([^"]+)"', text)
        total += len(re.findall(r"\bbuiltin:\s*true\b", text))
        for m in re.finditer(r'\bbuiltin:\s*true,\s*category:\s*(?:"([^"]*)"|(category)\b)', text):
            counts[m.group(1) if m.group(1) is not None else (const.group(1) if const else "?")] += 1
    return counts, total


def source_canvas_aliases():
    """CollageCLI.canvas(_:) 的 switch 里的别名，按源码顺序。"""
    text = open(os.path.join(SRC, "Collage", "CollageCLI.swift"), encoding="utf-8").read()
    body = text[text.index("static func canvas(_ spec: String)"):]
    return re.findall(r'case "([^"]+)": return', body[:body.index("default:")])


def check_templates(s, lt, text):
    """collage_list_templates：数目和描述、源码对得上；enum；字段；category / include；参数不对（S2，§3.1）。"""
    lt = lt or {}
    field = lambda x, k: x.get(k) if isinstance(x, dict) else None   # 旧格式（字符串列表）要判失败，不能把脚本弄崩
    tpls = [t for t in lt.get("templates", []) if isinstance(t, dict)]
    cats = [c for c in lt.get("categories", []) if isinstance(c, dict)]
    desc = by_name["collage_list_templates"]["description"]
    m = re.search(r"现在 (\d+) 个，(\d+) 个分类：([^）]+)）", desc)
    by_cat = collections.Counter(t.get("category") for t in tpls)
    print(f"  模板 {len(tpls)} 个、{len(cats)} 个分类：" + "、".join(f"{c.get('name')} {c.get('count')}" for c in cats))
    check(m is not None and len(tpls) == int(m[1]) and len(cats) == int(m[2]) and [c["name"] for c in cats] == m[3].split("、")
          and {c["name"]: c["count"] for c in cats} == dict(by_cat) and sum(c["count"] for c in cats) == len(tpls),
          "collage_list_templates 的模板数、分类和每类个数，和描述里的数字、templates 自己数出来的一致")
    if os.path.isdir(os.path.join(SRC, "Collage")):
        src, total = source_templates()
        check(total == sum(src.values()) and dict(src) == dict(by_cat) and len(tpls) == total,
              f"和源码里的模板库对得上：{total} 个 builtin: true、{len(src)} 个分类"
              + ("，每类个数一样" if dict(src) == dict(by_cat) else f"：源码 {dict(src)}"))
        aliases = source_canvas_aliases()
        canv = lt.get("canvases", [])
        check(aliases and [field(c, "key") for c in canv] == aliases
              and all(field(c, "name") and (field(c, "width") or 0) > 0 and (field(c, "height") or 0) > 0 for c in canv),
              f"canvases 的 key 就是 CollageCLI.canvas(_:) 里的 {len(aliases)} 个别名，带名字和尺寸")
    else:
        print(f"  skip 找不到源码目录 {SRC}，模板数没和源码对")
    props = lambda tool: by_name[tool]["inputSchema"]["properties"]
    styles, looks, kits = lt.get("styles", []), lt.get("looks", []), lt.get("kits", [])
    check([field(x, "key") for x in styles] == props("collage_set_style")["style"]["enum"]
          and [field(x, "key") for x in looks] == props("collage_set_style")["look"]["enum"]
          and [field(x, "id") for x in kits] == props("collage_run_kit")["kit"]["enum"]
          and all(field(x, "name") for x in styles + looks + kits),
          f"styles / looks / kits 和 schema 的 enum 一致、都有中文名（{len(styles)} 个样式、{len(looks)} 个色调、{len(kits)} 套）")
    keys = {"name", "category", "photo_slots", "fit_aspects", "photo_cells", "scatter", "contact_sheet"}
    bad = [t.get("name") for t in tpls
           if set(t) != keys or not isinstance(t["photo_slots"], int) or not isinstance(t["fit_aspects"], bool)
           or (t["photo_cells"] is None) != (t["scatter"] or t["contact_sheet"])
           or (t["photo_cells"] is not None and (set(t["photo_cells"]) != {"landscape", "portrait", "square"}
                                                 or sum(t["photo_cells"].values()) != t["photo_slots"]))]
    check(tpls and not bad and len({t["name"] for t in tpls}) == len(tpls),
          f"每个模板字段齐、没有重名；网格模板的 photo_cells（横 / 竖 / 方）加起来等于 photo_slots，散落和印样是 null {bad[:4]}")
    check(len(text) <= 20000 and "\\/" not in text, f"collage_list_templates 的 text {len(text)} 字（≤ 20000）")
    res, f1, _ = s.tool("tc1", "collage_list_templates", {"category": "时尚刊", "include": ["templates"]})
    n1 = by_cat.get("时尚刊", 0)
    check(f1 is not None and set(f1) == {"categories", "templates"} and n1 > 0 and len(f1["templates"]) == n1
          and all(t["category"] == "时尚刊" for t in f1["templates"]), f"category=时尚刊：{n1} 个，只有 categories + templates")
    res, f2, _ = s.tool("tc2", "collage_list_templates", {"category": "杂志"})
    rows2 = [t for t in (f2 or {}).get("templates", []) if isinstance(t, dict)]
    got2 = [t.get("name") for t in rows2]
    want2 = [t["name"] for t in tpls if "杂志" in t["category"] or "杂志" in t["name"]]
    check(got2 == want2 and {"日系杂志", "留白杂志"} <= {t.get("category") for t in rows2},
          f"category=杂志：分类或名字里含「杂志」的 {len(want2)} 个，按模板库的顺序")
    res, f3, _ = s.tool("tc3", "collage_list_templates", {"include": ["looks", "looks"]})
    check(f3 is not None and set(f3) == {"looks"}, "include=[looks, looks]：去重，只给 looks")
    wrong_args = []
    for i, a in enumerate(({"category": "__没有这个__"}, {"category": ""}, {"category": 3}, {"include": []},
                           {"include": ["bogus"]}, {"include": "styles"}, {"x": 1})):
        res, b, _ = s.tool(f"tc4-{i}", "collage_list_templates", a)
        if not (res.get("isError") and (b or {}).get("error", {}).get("code") == "invalid_argument" and b["error"].get("hint")):
            wrong_args.append(a)
    check(not wrong_args, f"参数不对 → invalid_argument + hint {wrong_args}")
    res, b, _ = s.tool("tc5", "collage_list_templates", {"category": "__没有这个__"})
    hint = ((b or {}).get("error") or {}).get("hint", "")
    check(bool(cats) and all(c.get("name", "") in hint for c in cats), "找不到这个分类：hint 里列出全部分类")
    r = run_cli(["--mcp-call", "collage_list_templates", "{}"], FIXTURE, LABELGUI_MCP_TEXT_MAX="5000")
    cut = call_body(r) or {}
    txt = json.loads(r.stdout.decode().splitlines()[0])["content"][0]["text"] if cut else ""
    check(len(txt) <= 5000 and cut.get("truncated") is True and 0 < len(cut.get("templates", [])) < len(tpls)
          and [t["name"] for t in cut["templates"]] == [t["name"] for t in tpls[:len(cut["templates"])]],
          f"LABELGUI_MCP_TEXT_MAX=5000：text {len(txt)} 字，模板从尾部截掉（留 {len(cut.get('templates', []))} 个）、truncated:true")


if not PROTOCOL_ONLY:
    print("2. 没有 app")
    s = Server(FIXTURE)
    s.initialize()
    res, st, _ = s.tool("a1", "app_status")
    check(st is not None and st["sessions"] == len(SESSIONS) and st["data_dir_exists"] and st["data_dir_readable"]
          and st["data_dir"] == FIXTURE and st["data_dir_override"] is True, f"app_status：fixture 数据目录、{len(SESSIONS)} 场")
    check(st is not None and [w["code"] for w in st["warnings"]] == ["app_not_running"], f"app_status.warnings：{(st or {}).get('warnings')}")
    res, ls, _ = s.tool("a2", "cull_list_sessions")
    rows_ = (ls or {}).get("sessions", [])
    check_session_rows(res, ls, "--mcp")
    res, ls2, _ = s.tool("a2b", "cull_list_sessions", {"limit": 2})
    check(ls2 is not None and [r_["session"] for r_ in ls2.get("sessions", [])] == [e["key"] for e, _, _ in SESSIONS[:2]]
          and ls2.get("total") == len(SESSIONS) and ls2.get("truncated") is True, "cull_list_sessions limit:2 → 前 2 场、total 7、truncated")
    # Claude Code 会并行调只读工具。这里一口气发 6 个，只能说明结果稳定：查一次只要几微秒，不一定真的重叠。
    # 「同一个文件夹共用一次查询、后来的等同一个结果、等不到记 null」由 --mcp-selftest 的 WalkJob 组拿卡住的假 lstat 确定地测。
    for i in range(6):
        s.call(f"par{i}", "cull_list_sessions")
    par = [s.reply(f"par{i}") for i in range(6)]
    want_par = [(o_, p_) for _, o_, p_ in SESSIONS]
    got_par = []
    for m_ in par:
        try:
            b_ = json.loads(m_["result"]["content"][0]["text"])
            got_par.append(([(r_["folder_online"], r_["protected_location"]) for r_ in b_["sessions"]], b_["warnings"]))
        except Exception:
            got_par.append(None)
    check(all(g_ == (want_par, []) for g_ in got_par),
          "6 个一口气发的 cull_list_sessions 结果都一样、没有 warning（不保证真的重叠；共用那条路径见 --mcp-selftest）")
    res, bad1, _ = s.tool("a3", "cull_list_sessions", {"limit": 0})
    res2, bad2, _ = s.tool("a4", "cull_list_sessions", {"limit": True})
    res3, bad3, _ = s.tool("a5", "app_status", {"x": 1})
    check(all(r_.get("isError") and b["error"]["code"] == "invalid_argument" for r_, b in ((res, bad1), (res2, bad2), (res3, bad3))),
          "参数不对 → invalid_argument（limit:0、limit:true、app_status 带参数）")
    res, lt, lt_text = s.tool("a6", "collage_list_templates")
    check_templates(s, lt, lt_text)
    # 15 个要 app 的工具：带合理参数、也带空参数，一律 app_not_running + hint（§10.2）
    sample = {"session": KEY, "ids": ["DSCF7208"], "kind": "scene", "verdict": "pick", "template": "时尚刊",
              "kit": "fashionIssue", "target": "collage"}
    wrong = []
    for n in APP_TOOLS:
        props = by_name[n]["inputSchema"]["properties"]
        for args in ({k: v for k, v in sample.items() if k in props}, {}):
            res, b, _ = s.tool(f"t-{n}-{len(args)}", n, args)
            if not (res.get("isError") and (b or {}).get("error", {}).get("code") == "app_not_running"
                    and (b or {}).get("error", {}).get("hint")):
                wrong.append(n)
    check(not wrong, f"15 个要 app 的工具都回 app_not_running、带 hint {sorted(set(wrong))}")
    rc, dt = s.close()
    socks = [os.path.join(dp, f) for dp, _, fs in os.walk(SOCK_ROOT) for f in fs]
    check(not socks, f"socket 根目录里什么都没有：{socks}")
    check(not os.path.exists(os.path.join(FIXTURE, ".live.lock")), "数据目录里没有 .live.lock")

    print("2c. 最多 15 场、sessions.json 坏了、text 截断")
    b = call_body(run_cli(["--mcp-call", "cull_list_sessions", '{"limit":100}'], MANY))
    st_many = call_body(run_cli(["--mcp-call", "app_status", "{}"], MANY))
    many_keys = [entry(os.path.join(WORK, "many", f"shoot{i:02d}"), i)["key"] for i in range(15)]
    check(b is not None and [r_["session"] for r_ in b["sessions"]] == many_keys and b["total"] == 15 and b["truncated"] is False
          and (st_many or {}).get("sessions") == 15, "sessions.json 有 17 条：和 app 一样只认前 15 条（列表、total、app_status.sessions）")
    for d, what in ((BAD, "sessions.json 坏了"), (NONAME, "有一条缺 name（app 的 JSONDecoder 整个解不出来）")):
        b = call_body(run_cli(["--mcp-call", "cull_list_sessions", "{}"], d))
        st_bad = call_body(run_cli(["--mcp-call", "app_status", "{}"], d))
        check(b is not None and b["sessions"] == [] and b["total"] == 0
              and [w["code"] for w in b["warnings"]] == ["sessions_index_unreadable"]
              and (st_bad or {}).get("sessions") == 0 and "sessions_index_unreadable" in [w["code"] for w in st_bad["warnings"]],
              f"{what}：空列表 + warning sessions_index_unreadable（cull_list_sessions 和 app_status）")
    b = call_body(run_cli(["--mcp-call", "cull_list_sessions", "{}"], NOINDEX))
    check(b is not None and b["sessions"] == [] and b["total"] == 0
          and [w["code"] for w in b["warnings"]] == ["sessions_index_missing"],
          f"数据目录在、没有 sessions.json：空列表 + warning sessions_index_missing（没有 data_dir_missing）{(b or {}).get('warnings')}")
    r = run_cli(["--mcp-call", "cull_list_sessions", "{}"], FIXTURE, LABELGUI_MCP_TEXT_MAX="1000")
    b = call_body(r) or {}
    txt = json.loads(r.stdout.decode().splitlines()[0])["content"][0]["text"] if b else ""
    check(len(txt) <= 1000 and b.get("truncated") is True and b.get("total") == len(SESSIONS)
          and 0 < len(b.get("sessions", [])) < len(SESSIONS), f"LABELGUI_MCP_TEXT_MAX=1000：cull_list_sessions 截到 {len(b.get('sessions', []))} 场、truncated:true")

# ---------------------------------------------------------------- 4. 不建目录（第 3 组放在最后，等所有进程都跑完再比）

print("4. 不建目录")
NEVER = os.path.join(WORK, "nothing-here", "never")
r1 = run_cli(["--mcp-tools"], NEVER)
r2 = run_cli(["--mcp-call", "app_status", "{}"], NEVER)
st = json.loads(json.loads(r2.stdout.decode().splitlines()[0])["content"][0]["text"]) if r2.returncode == 0 else {}
s = Server(NEVER)
s.initialize()
s.request("tl", "tools/list")
s.reply("tl")
_, st2, _ = s.tool("n1", "app_status")
_, ls2, _ = s.tool("n2", "cull_list_sessions")
_, lt2, _ = s.tool("n3", "collage_list_templates")
res, b, _ = s.tool("n4", "collage_get_state", {})
rc, dt = s.close()
check(r1.returncode == 0 and r2.returncode == 0 and rc == 0, "--mcp-tools、--mcp-call、--mcp 在不存在的数据目录上照常跑完")
check(not os.path.exists(NEVER) and not os.path.exists(os.path.dirname(NEVER)), f"跑完以后 {NEVER} 仍然不存在（连上一级也没建）")
for label, x in (("--mcp-call", st), ("--mcp", st2)):
    check(x.get("data_dir_exists") is False and x.get("sessions") == 0 and x.get("live", {}).get("state") == "not_running"
          and "data_dir_missing" in [w["code"] for w in x.get("warnings", [])],
          f"{label} app_status：data_dir_exists:false、sessions:0、not_running、warning data_dir_missing")
check(ls2 is not None and ls2.get("sessions") == [] and ls2.get("total") == 0
      and [w["code"] for w in ls2.get("warnings", [])] == ["data_dir_missing"], "cull_list_sessions：空列表 + warning data_dir_missing")
check(res.get("isError") and b["error"]["code"] == "app_not_running", "要 app 的工具：app_not_running")
if ON_GITHUB and os.path.exists(REAL_DATA) is False:
    # 只在 CI 上：不设 LABELGUI_DATA_DIR（runner 上没有真实数据目录），跑完那个目录仍然不存在。
    run_cli(["--mcp-tools"], None)
    run_cli(["--mcp-call", "app_status", "{}"], None)
    s = Server(None)
    s.initialize()
    s.tool("u1", "app_status")
    s.close()
    check(not os.path.exists(REAL_DATA), f"CI：不设 LABELGUI_DATA_DIR 跑完，{REAL_DATA} 仍然不存在")
else:
    print("  skip 不设 LABELGUI_DATA_DIR 的那一条只在 CI 上跑（GITHUB_ACTIONS=true 且真实数据目录不存在）")

# ---------------------------------------------------------------- 5. 无界面

print("5. 无界面")
s = Server(FIXTURE)
s.initialize()
rc, dt = s.close()
check(rc == 0 and dt < 0.5 * SLACK, f"stdin EOF 后 {dt * 1000:.0f} ms 退出，退出码 {rc}")
for sig, label in ((signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")):
    s = Server(FIXTURE)
    s.initialize()
    t0 = time.time()
    s.proc.send_signal(sig)
    try:
        rc = s.proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        s.proc.kill()
        rc = None
    dt = time.time() - t0
    check(rc == 0 and dt < 0.5 * SLACK, f"{label} 后 {dt * 1000:.0f} ms 退出，退出码 {rc}")
# 写被堵住的时候收到 EOF：也要在 0.5 s 内退（0.4 s 的兜底）
s = Server(FIXTURE)
s.initialize()
for i in range(10):
    s.request(f"fill{i}", "tools/list")
time.sleep(0.3)
rc, dt = s.close()
check(rc == 0 and dt < 0.5 * SLACK, f"stdout 没人读、写被堵住时 EOF：{dt * 1000:.0f} ms 退出，退出码 {rc}")
# 排队的帧超过 256 个（读线程停下等空位、读不到 EOF）时关 stdin：也要在 0.5 s 内退
s = Server(FIXTURE)
s.initialize()
for i in range(400):
    s.request(f"flood{i}", "tools/list")
time.sleep(0.5)
rc, dt = s.close()
check(rc == 0 and dt < 0.5 * SLACK, f"400 个 tools/list 没人读（排队超过 256 帧）时 EOF：{dt * 1000:.0f} ms 退出，退出码 {rc}")

if ON_GITHUB:
    # 只在 CI 上真起写错参数的进程（LABELGUI_NO_GUI=1 是第二道保险）：2 s 内 exit 2，不存在的数据目录仍然不存在。
    for bad in ("-mcp", "mcp", "—mcp", "–mcp", "-collage-ui", " --mcp", "serve"):
        nd = os.path.join(WORK, "neg", "never")
        p = subprocess.Popen([BIN, bad], env=env_for(nd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, cwd=WORK)
        try:
            out, err = p.communicate(timeout=2 * SLACK)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            rc = None
        check(rc == 2 and not os.path.exists(nd), f"CI 反向用例 {bad!r}：exit {rc}，数据目录没建")
else:
    print("  skip 写错参数的真进程只在 CI 上起（本地用 --mcp-selftest 的判断表代替）")

# grep：MCP/、Live/ 的禁用词（§5 第 3、7 层，§10.5），MCP/ 的文件访问只在四个有名字的文件里
MCP_DIR = os.path.join(SRC, "MCP")
LIVE_DIR = os.path.join(SRC, "Live")
MCP_BANNED = ["NSWorkspace", "NSApp", "NSApplication", "NSOpenPanel", "NSSavePanel", "NSAlert", "/usr/bin/open",
              "revealInFinder", "startVLMServer", "CardImportCenter", "UISnapshot", "LabelGUIApp", r"\bProcess\b",
              "CGImageSource", "CGImageDestination", "NSImage", "UserDefaults", "CFPreferences", r"BatchStore\(",
              r"CollageStore\(", "posix_spawn", r"\bfork\(", r"\bsystem\(", r"\bpopen\(",
              # 比 §10.5 严一点：stderr 读端关了它会抛异常、把进程 abort；MCP/ 里写日志只走 MCPLog.stderr
              r"standardError\.write\("]
# STEP 2 补：§9.5.6 窗口状态只看不动 —— 任何激活、变 key / main、取消隐藏、显示窗口的调用都不许（和 live_smoke.py 同一份）
LIVE_BANNED = [r"NSApp\.activate", r"\bactivate\(", "activateIgnoringOtherApps", "makeKeyAndOrderFront", r"makeKey\w*\(",
               r"makeMain\w*\(", r"becomeKey\(", "orderFront", "deminiaturize", r"\bunhide", "requestUserAttention",
               "NSOpenPanel", "NSSavePanel", "NSAlert", "runModal", "beginSheet", "openWindow", "NSWorkspace", "/usr/bin/open",
               "revealInFinder", "startVLMServer", "CardImportCenter", r"export\(", "posix_spawn", r"\bfork\(", r"\bsystem\(",
               r"\bpopen\(", r"setIsVisible\("]
FILE_ACCESS = [r"Data\(contentsOf:", "contentsOfDirectory", r"FileManager\.default", r"fopen\(", r"\.write\(to:", r"\bopen\("]
FILE_ACCESS_OK = {"MCPPaths.swift", "MCPOutput.swift", "LiveClient.swift", "StdioTakeover.swift"}
# S2 加（比 §10.5 严）：stat 一族、链接、在不在；还有几个会悄悄查文件系统的 Foundation 路径函数（S2 拿 sandbox-exec 实测）——
# 不带 isDirectory 的 URL(fileURLWithPath:) 和 appendingPathComponent(_:) 也只许在这四个文件里，而且要带 isDirectory；
# standardizedFileURL、NSString.standardizingPath、resolvingSymlinksInPath、fileSystemRepresentation（转不了会抛 ObjC 异常）
# 在 MCP/ 里一处都不许有。这几条只看代码，不看注释（注释里要写清楚为什么不用它们）。
FILE_ACCESS_S2 = [r"\blstat\(", r"\bstat\(", r"\bfstat\(", r"\bfstatat\(", r"\bstatfs\(", r"readlink\(", r"\brealpath\(",
                  r"\baccess\(", r"fileExists", "getattrlist", r"opendir\(", "attributesOfItem", "resourceValues",
                  "fileURLWithPath:", r"appendingPathComponent\(",
                  # S2 评审补的：别的读文件写法（String / NSData / NSDictionary(contentsOf…)，数组的 append / insert(contentsOf:)
                  # 不算；FileHandle、流、另起的 FileManager）
                  r"(?<!append)(?<!insert)\(contentsOf\w*:", r"FileHandle\(for", r"InputStream\(", r"OutputStream\(", r"FileManager\(\)",
                  r"contents\(atPath", "checkResourceIsReachable", r"\bopenat\(", r"\bmmap\("]
HIDDEN_FS = ["standardizedFileURL", "standardizingPath", "resolvingSymlinksInPath", "fileSystemRepresentation"]
NEEDS_ISDIR = ["fileURLWithPath:", r"appendingPathComponent\("]


def grep(dirpath, patterns, allowed=(), code_only=False, unless=None):
    """code_only：去掉 // 注释再看（行首的，和前面有空白的行尾注释）。unless：这一行里有它就不算。"""
    hits = []
    if not os.path.isdir(dirpath):
        return None
    for dp, _, fs in os.walk(dirpath):
        for f in sorted(fs):
            if not f.endswith(".swift") or f in allowed:
                continue
            for n, line in enumerate(open(os.path.join(dp, f), encoding="utf-8"), 1):
                if code_only:
                    line = re.sub(r"(^|\s)//.*$", "", line)
                if unless and re.search(unless, line):
                    continue
                for pat in patterns:
                    if re.search(pat, line):
                        hits.append(f"{f}:{n} {pat}")
    return hits


if os.path.isdir(MCP_DIR):
    h = grep(MCP_DIR, MCP_BANNED)
    check(not h, f"MCP/ 里没有禁用词 {h[:5]}")
    h = grep(MCP_DIR, FILE_ACCESS, FILE_ACCESS_OK)
    check(not h, f"MCP/ 的文件访问只在 MCPPaths / MCPOutput / LiveClient / StdioTakeover {h[:5]}")
    h = grep(MCP_DIR, FILE_ACCESS_S2, FILE_ACCESS_OK, code_only=True)
    check(not h, f"stat / lstat / readlink / access / fileExists / 路径 URL 也只在这四个文件里 {h[:5]}")
    h = grep(MCP_DIR, HIDDEN_FS, code_only=True)
    check(not h, f"MCP/ 里没有会悄悄查文件系统的 standardizedFileURL / standardizingPath / resolvingSymlinksInPath {h[:5]}")
    h = grep(MCP_DIR, NEEDS_ISDIR, code_only=True, unless=r"isDirectory:")
    check(not h, f"URL(fileURLWithPath:) / appendingPathComponent 都带 isDirectory（不带会先 stat 一下）{h[:5]}")
    h = grep(LIVE_DIR, LIVE_BANNED)
    check(h is not None and not h, f"Live/ 里没有禁用词 {h[:5] if h else h}")
    # MCP/ 里只有 LiveClient.probeLockFile() 能打开锁文件（§10.5）：LiveClient.swift 其余地方不许有 open(
    lc = open(os.path.join(MCP_DIR, "LiveClient.swift"), encoding="utf-8").read()
    fn = re.search(r"static func probeLockFile\(.*?\n    }\n", lc, re.S)
    outside = [l for l in lc.replace(fn.group(0), "").splitlines() if re.search(r"\bopen\(", re.sub(r"(^|\s)//.*$", "", l))] if fn else ["?"]
    check(fn is not None and "O_CREAT" not in fn.group(0) and not outside,
          f"LiveClient.swift 只在 probeLockFile() 里 open（不带 O_CREAT）{outside[:3]}")
else:
    print(f"  skip 找不到源码目录 {MCP_DIR}，grep 检查不跑")

# ---------------------------------------------------------------- 6. 不进程序坞

print("6. 不进程序坞")
s = Server(FIXTURE)
s.initialize()
s.tool("d1", "app_status")
apps = subprocess.run(["lsappinfo", "list"], capture_output=True, text=True).stdout
pid = s.proc.pid
check(re.search(rf"\bpid = {pid}\b", apps) is None, f"--mcp（pid {pid}）跑着的时候 lsappinfo list 里没有它")
s.close()

# ---------------------------------------------------------------- 7. RSS

if not PROTOCOL_ONLY:
    print("7. RSS")
    s = Server(FIXTURE)
    s.initialize()
    rss = []
    for i in range(100):
        s.tool(f"m{i}a", "app_status")
        s.tool(f"m{i}b", "cull_list_sessions")
        if i in (9, 99):
            rss.append(int(subprocess.run(["ps", "-o", "rss=", "-p", str(s.proc.pid)], capture_output=True,
                                          text=True).stdout.strip() or 0) / 1024)
    s.close()
    check(len(rss) == 2 and rss[1] < 60 and rss[1] - rss[0] < 5,
          f"100 次 app_status + cull_list_sessions：RSS {rss[0]:.1f} → {rss[1]:.1f} MB（< 60 MB、涨幅 < 5 MB）")

# ---------------------------------------------------------------- 3. 只读不变量（所有进程都跑完以后比）

print("3. 只读不变量")
for d, before in fixture_before.items():
    check(tree_manifest(d) == before, f"{os.path.basename(d)} 整棵树（大小、mtime、sha256）跑前跑后逐项相同；没有 runtime/、fonts/")
for d, before in defaults_before.items():
    check(defaults_export(d) == before, f"defaults export {d} 跑前跑后相同")
check(not os.path.lexists(MCP_OUT), f"预览输出目录 {MCP_OUT} 从没被建出来（只在第一次存图时建；没有 app 就没有图）")
procs_after = labelgui_processes()
extra = {p: c for p, c in procs_after.items() if p not in procs_before}
check(not extra, f"进程表里没有多出这个二进制的进程：{extra}")

shutil.rmtree(SOCK_ROOT, ignore_errors=True)
if not KEEP:
    shutil.rmtree(WORK, ignore_errors=True)
print(f"\nMCP 冒烟：{counts['ok']} 条通过，{len(failures)} 条失败")
if failures:
    for f in failures:
        print("  FAIL " + f)
    sys.exit(1)
print("MCP 冒烟全部通过")
