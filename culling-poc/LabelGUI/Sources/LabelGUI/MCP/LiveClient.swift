import Foundation
import AppKit

/// app 开着没有、能不能实时操作（DESIGN §9.1、§10.2 的 `live.state`）。
enum LiveState: String {
    case live, notRunning = "not_running", bridgeOff = "bridge_off", unreachable, unresponsive
    case protoMismatch = "proto_mismatch", oldApp = "old_app", notReady = "not_ready"
    case dataDirMismatch = "data_dir_mismatch", peerRejected = "peer_rejected"
    case headlessWriter = "headless_writer", disabled
}

/// `--mcp` 这一侧的桥客户端（§9.1 的探测，§10.2 的请求和重发）。只用 POSIX 和 Live/ 里共用的线上格式；
/// 不建锁、不 bind、不建 socket 目录（§5 第 7 层）。启动时不探测，回完 initialize 也不探测：第一次需要路由的调用才探（§9.7），
/// 每次都探、不缓存。连接一次一个请求：connect → hello → 请求 → 断开。
/// 这是 MCP/ 里唯一打开 `.live.lock` 的文件，而且只在 `probeLockFile()` 里：O_RDONLY|O_NOFOLLOW|O_CLOEXEC，不带 O_CREAT，
/// LOCK_SH 探一下就放（几个 MCP 父进程同时探不互相挡；app 拿的是 LOCK_EX）。
enum LiveClient {
    /// 锁文件里那一行（只给报错信息和分支用，真相是 flock 本身）。
    struct LockHolder: Equatable {
        var role: String?
        var bridge: String?
        var reason: String?
        var pid: Int?

        init(_ info: [String: Any]?) {
            role = info?["role"] as? String
            bridge = info?["bridge"] as? String
            reason = info?["reason"] as? String
            pid = LiveWire.int(info?["pid"])
        }

        init(role: String?, bridge: String?, reason: String? = nil, pid: Int? = nil) {
            self.role = role
            self.bridge = bridge
            self.reason = reason
            self.pid = pid
        }
    }

    enum LockProbe: Equatable {
        /// ENOENT：从没有带桥的 app 在这个数据目录上跑过。
        case missing
        /// 打不开：EACCES / EPERM（多半是宿主沙箱）、ELOOP（锁路径被换成了符号链接）……不能当成「app 没开」（§8 第 27 条）。
        case denied(Int32)
        /// LOCK_SH 拿得到：没人持有 LOCK_EX。
        case free
        /// EWOULDBLOCK：有人持有 LOCK_EX。
        case held(LockHolder)
    }

    /// MCP/ 里唯一打开锁文件的地方。读那一行最多 4 KB（解析不了就当 role 未知）。
    static func probeLockFile(_ path: String) -> LockProbe {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let e = errno
            return e == ENOENT ? .missing : .denied(e)
        }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return .free
        }
        guard errno == EWOULDBLOCK else { return .denied(errno) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        let info = n > 0 ? LiveLock.parseInfo(Data(buf[0..<n])) : nil
        return .held(LockHolder(info))
    }

    // MARK: - 判定（纯函数，--mcp-selftest 拿假的输入逐行测；本机起不出来的状态靠它）

    enum Next: Equatable {
        case state(LiveState, reason: String?)
        /// 再 connect 一次（锁是 role=app 而 connect 是 ECONNREFUSED：macOS 上积压满了就是这个 errno，§9.1 第二轮实测）。
        case retryConnect
    }

    /// connect 失败以后看锁（§9.1 下半）。`oldAppRunning`：只在默认数据目录、锁是空的时候才去看 NSRunningApplication。
    static func afterConnectFailure(errno e: Int32, lock: LockProbe, oldAppRunning: Bool, budgetLeft: Bool) -> Next {
        switch lock {
        case .denied(let le):
            return .state(.unreachable, reason: "lock_unreadable:\(le)")
        case .missing, .free:
            return .state(oldAppRunning ? .oldApp : .notRunning, reason: nil)
        case .held(let h):
            switch h.role {
            case "app":
                if h.bridge == "off" { return .state(.bridgeOff, reason: h.reason) }
                if e == ECONNREFUSED && budgetLeft && h.bridge != "unavailable" { return .retryConnect }
                return .state(.unreachable, reason: h.bridge == "unavailable" ? (h.reason ?? "unavailable") : "connect:\(e)")
            case "headless":
                return .state(.headlessWriter, reason: nil)
            default:
                return .state(.unreachable, reason: "lock_role_unknown")
            }
        }
    }

    enum HelloOutcome {
        case reply([String: Any])
        case error(String)
        case timeout
        /// 一个字节没回就关了：服务端按 uid 拒绝对端时就是这样（§9.2.2）。
        case eof
        /// app 那边已经有 16 个连接（§9.1 表后第二轮补）：暂时的，在 hello 预算里每 50 ms 重连。
        case tooManyConnections
        case garbage
    }

    static func afterHello(_ outcome: HelloOutcome, dataDirID: String, budgetLeft: Bool) -> Next {
        switch outcome {
        case .timeout, .garbage:
            return .state(.unresponsive, reason: outcome.isTimeout ? "hello_timeout" : "hello_garbage")
        case .eof:
            return .state(.peerRejected, reason: "closed_before_hello_reply")
        case .tooManyConnections:
            return budgetLeft ? .retryConnect : .state(.unresponsive, reason: "too_many_connections")
        case .error(let code):
            switch code {
            case "proto_mismatch": return .state(.protoMismatch, reason: nil)
            case "data_dir_mismatch": return .state(.dataDirMismatch, reason: nil)
            default: return .state(.unreachable, reason: "hello_error:\(code)")
            }
        case .reply(let r):
            let lo = LiveWire.int(r["proto_min"]) ?? -1
            let hi = LiveWire.int(r["proto_max"]) ?? -1
            guard lo <= LiveWire.proto && LiveWire.proto <= hi, LiveWire.int(r["proto"]) == LiveWire.proto else {
                return .state(.protoMismatch, reason: nil)
            }
            guard (r["data_dir_id"] as? String) == dataDirID else { return .state(.dataDirMismatch, reason: nil) }
            guard r["ready"] as? Bool == true else { return .state(.notReady, reason: nil) }
            return .state(.live, reason: nil)
        }
    }

    // MARK: - 探测

    /// 一次探测的结果。`live` 而且要了 `keep` 时连接留着，紧接着发请求（每次工具调用一个连接）。
    final class Probe {
        let state: LiveState
        let reason: String?
        let hello: [String: Any]?
        let paths: LivePaths?
        let lock: LockHolder?
        var warnings: [[String: Any]]
        private(set) var fd: Int32

        init(state: LiveState, reason: String? = nil, hello: [String: Any]? = nil, paths: LivePaths? = nil,
             lock: LockHolder? = nil, warnings: [[String: Any]] = [], fd: Int32 = -1) {
            self.state = state
            self.reason = reason
            self.hello = hello
            self.paths = paths
            self.lock = lock
            self.warnings = warnings
            self.fd = fd
        }

        func closeConnection() {
            if fd >= 0 { close(fd) }
            fd = -1
        }

        deinit { closeConnection() }

        var capabilities: [String] { hello?["capabilities"] as? [String] ?? [] }
        var openSession: [String: Any]? { hello?["open_session"] as? [String: Any] }
        var appPID: Int? { LiveWire.int((hello?["app"] as? [String: Any])?["pid"]) }
    }

    /// §9.1 的判定过程：connect 300 ms（锁是 role=app 而 connect 被拒时每 20 ms 再连）→ 对端 uid → hello 1 s
    /// （too_many_connections 每 50 ms 重连）→ 看 hello；connect 不上就探锁。
    static func probe(client: MCPStdioServer.ClientInfo?, keep: Bool = false) -> Probe {
        guard MCPConfig.liveEnabled else { return Probe(state: .disabled) }
        let env = ProcessInfo.processInfo.environment
        let raw = env["LABELGUI_DATA_DIR"] ?? ""
        // realpath(3) 对相对路径按各自的 cwd 解析，--mcp 和 app 的 cwd 不一样：不探测（§9.2.1 第二轮补）
        if !raw.isEmpty && !raw.hasPrefix("/") {
            return Probe(state: .unreachable, reason: "data_dir_not_absolute",
                         warnings: [MCPStatus.warning("data_dir_not_absolute", "LABELGUI_DATA_DIR 不是绝对路径（\(raw)）：不连 app。",
                                                      hint: "在 MCP 配置里把它写成绝对路径，或者干脆不设（用默认数据目录）")])
        }
        let paths: LivePaths
        switch LivePaths.resolve(dataDir: MCPPaths.dataDir.path, sockRoot: LivePaths.clientSockRoot(env)) {
        case .success(let p):
            paths = p
        case .failure(.dataDir(let e)) where e == EACCES || e == EPERM:
            // 数据目录 realpath / stat 被拒（多半是宿主的沙箱连元数据都不让看）：看不出 app 开没开，不能当成「没开」
            // （§9.1 锁文件打不开也是 unreachable，§8 第 27 条）；data_dir_unreadable 由调用方按 MCPPaths 报
            return Probe(state: .unreachable, reason: Self.dataDirUnreadable + ":\(e)")
        case .failure(.dataDir):
            // 数据目录不存在：不建、不探锁（§10.5 第 4 条）；data_dir_missing 由调用方按 MCPPaths 报
            return Probe(state: .notRunning, reason: "data_dir_missing")
        case .failure(.noTempDir):
            return Probe(state: .unreachable, reason: "no_temp_dir",
                         warnings: [MCPStatus.warning("no_temp_dir", "拿不到本用户的临时目录（confstr），算不出 app 的 socket 在哪。",
                                                      hint: "这不该发生；重启电脑以后再试")])
        }
        var warnings: [[String: Any]] = []
        let tooLong = paths.socketTooLong
        if tooLong {
            warnings.append(MCPStatus.warning("socket_path_too_long",
                                              "socket 路径 \(paths.socketPath.utf8.count) 字节，超过系统上限 \(LiveSockAddr.maxPathBytes)：不 connect，只看锁。",
                                              hint: "只有测试用的 LABELGUI_LIVE_SOCK_ROOT 会这样；换一个短一点的目录"))
        }
        let defaultDataDir = raw.isEmpty
        let start = LiveWire.nowMs()
        var helloStart: Double?
        while true {
            let left = 300 - (LiveWire.nowMs() - start)
            let attempt: LiveConnect.Outcome = tooLong ? .failed(ENAMETOOLONG) : LiveConnect.connect(paths.socketPath, timeoutMs: Int(max(1, left)))
            switch attempt {
            case .timeout:
                return Probe(state: .unresponsive, reason: "connect_timeout", paths: paths, warnings: warnings)
            case .failed(let e):
                let lock = probeLockFile(paths.lockPath)
                var holder: LockHolder?
                if case .held(let h) = lock { holder = h }
                let free = lock == .missing || lock == .free
                let next = afterConnectFailure(errno: e, lock: lock, oldAppRunning: defaultDataDir && free && oldAppRunning(),
                                               budgetLeft: LiveWire.nowMs() - start < 300)
                switch next {
                case .retryConnect:
                    usleep(20_000)
                    continue
                case .state(let s, let reason):
                    return Probe(state: s, reason: reason, paths: paths, lock: holder, warnings: warnings)
                }
            case .connected(let fd):
                // 连上以后先核对对端：uid 是自己，socket 文件的属主也是自己（§9.2.2 客户端那条）
                var st = stat()
                guard LiveConnect.peerUID(fd) == geteuid(), lstat(paths.socketPath, &st) == 0, st.st_uid == geteuid() else {
                    close(fd)
                    return Probe(state: .peerRejected, reason: "peer_uid", paths: paths, warnings: warnings)
                }
                let hs = helloStart ?? LiveWire.nowMs()
                helloStart = hs
                let budget = Int(max(1, 1_000 - (LiveWire.nowMs() - hs)))
                let (outcome, reply) = hello(fd, paths: paths, client: client, timeoutMs: budget)
                let next = afterHello(outcome, dataDirID: paths.dataDirID, budgetLeft: LiveWire.nowMs() - hs < 1_000)
                switch next {
                case .retryConnect:
                    close(fd)
                    usleep(50_000)
                    continue
                case .state(let s, let reason):
                    if s == .live && keep {
                        return Probe(state: s, reason: reason, hello: reply, paths: paths, warnings: warnings, fd: fd)
                    }
                    close(fd)
                    return Probe(state: s, reason: reason, hello: reply, paths: paths, warnings: warnings)
                }
            }
        }
    }

    /// 锁是空的，但有还没有桥的旧版 app 在跑（§9.1）：只读 LaunchServices 的进程表，不建应用对象。判 old_app 只在默认数据目录时调
    /// （LABELGUI_MCP_LIVE=0 时 app_status.gui_running 也用它，§9.1 表外 disabled 那一段；设了 LABELGUI_DATA_DIR 而
    /// not_running 时，app_status 拿它决定加不加 §6.3 那一句，MCPStatus.appRunningForOverrideCheck）。
    /// 不算自己：app 里的二进制起的 --mcp 万一也被 LaunchServices 记进进程表，不能把自己认成开着的 app（本机不起 .app，测不了）。
    static func oldAppRunning() -> Bool {
        let me = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: "local.culling.labelgui").contains { $0.processIdentifier != me }
    }

    private static func hello(_ fd: Int32, paths: LivePaths, client: MCPStdioServer.ClientInfo?,
                              timeoutMs: Int) -> (HelloOutcome, [String: Any]?) {
        var me: [String: Any] = ["name": "xuanpian-mcp", "version": MCPConfig.version, "build": MCPConfig.build]
        me["uuid"] = LiveBuildInfo.uuid
        me["pid"] = Int(getpid())
        if let client { me["mcp_client"] = "\(client.name) \(client.version)" }
        var params: [String: Any] = ["proto": LiveWire.proto, "data_dir": paths.dataDir, "data_dir_id": paths.dataDirID]
        params["client"] = me
        let frame: [String: Any] = ["id": 0, "method": "hello", "params": params]
        switch LiveConnect.exchange(fd, frame, timeoutMs: timeoutMs, maxLine: LiveWire.maxReplyLine) {
        case .line(let line):
            // 第一行必须是对 id 0 的回复（或者 id 为 null 的错误：too_many_connections 是 accept 时就回的，那时还没读请求）。
            // 别的 id = 串进来的别人的回复（审查发现的 fd 复用），不能当 hello 解
            guard let msg = LiveWire.decode(line) else { return (.garbage, nil) }
            let idOK = msg["id"] is NSNull ? msg["error"] != nil : LiveWire.int(msg["id"]) == 0
            guard idOK else { return (.garbage, nil) }
            if let r = msg["result"] as? [String: Any] { return (.reply(r), r) }
            let code = (msg["error"] as? [String: Any])?["code"] as? String ?? "?"
            if code == "too_many_connections" { return (.tooManyConnections, nil) }
            let data = (msg["error"] as? [String: Any])?["data"] as? [String: Any]
            return (.error(code), data)
        case .timeout:
            return (.timeout, nil)
        case .eof, .error:
            return (.eof, nil)
        case .tooLong:
            return (.garbage, nil)
        }
    }

    // MARK: - 请求

    enum Outcome {
        case result([String: Any])
        case failure(code: String, message: String, data: [String: Any]?)
        /// 连接被断（EOF、ECONNRESET）：读可以重发，写结果未知。
        case gone
        /// 等了 deadline + 1 s 还没回。
        case timeout
        /// MCP 客户端发了 notifications/cancelled：连接已经关了，之后不为这个 id 发任何东西（§10.2）。
        case cancelled
    }

    /// 请求 id：每个请求一个随机的（不是固定的 1）。万一别的连接的回复串进来（fd 号被复用），id 对不上就不会被认领。
    static func requestID() -> Int {
        Int.random(in: 1...(1 << 40))
    }

    /// 在探测留下的那个连接上发一个请求，等它的回复（按 id 配对）；客户端等 deadline + 1 s（§9.2.3）。
    static func send(on probe: Probe, method: String, params: [String: Any], deadlineMs: Int, opID: String?,
                     cancel: MCPStdioServer.CancelFlag) -> Outcome {
        guard probe.fd >= 0 else { return .gone }
        defer { probe.closeConnection() }
        let rid = requestID()
        var frame: [String: Any] = ["id": rid, "method": method, "params": params, "deadline_ms": deadlineMs]
        if let opID { frame["op_id"] = opID }
        guard LiveFD.sendAll(probe.fd, LiveWire.encode(frame)) else { return .gone }
        let reader = LiveLineReader(fd: probe.fd, maxLine: LiveWire.maxReplyLine)
        let until = LiveWire.nowMs() + Double(deadlineMs + 1_000)
        while true {
            let left = Int(until - LiveWire.nowMs())
            if left <= 0 { return .timeout }
            switch reader.next(timeoutMs: left, stop: { cancel.isSet }) {
            case .line(let line):
                guard let msg = LiveWire.decode(line) else { return .gone }
                guard LiveWire.int(msg["id"]) == rid else { continue }
                if let r = msg["result"] as? [String: Any] { return .result(r) }
                let e = msg["error"] as? [String: Any] ?? [:]
                return .failure(code: e["code"] as? String ?? "internal", message: e["message"] as? String ?? "",
                                data: e["data"] as? [String: Any])
            case .timeout:
                return cancel.isSet ? .cancelled : .timeout
            case .eof, .error:
                return .gone
            case .tooLong:
                // 回复超过 8 MiB：app 那边的 bug，不能让它把 --mcp 的内存吃光
                return .failure(code: "internal", message: "app 的回复超过 \(LiveWire.maxReplyLine) 字节", data: nil)
            }
        }
    }

    /// 读请求（§10.2「请求发出去以后连接断了或超时」的读那一半）：
    /// 连接被断 → 重探一次，还是 live 就原样再发一次（读没有副作用），否则回那个状态；
    /// 超时而 hello 还能秒回 → 不重发，deadline_exceeded（app 主线程正忙）；hello 也不回了 → 那个状态（多半 unresponsive）。
    static func read(_ probe: Probe, method: String, params: [String: Any], deadlineMs: Int,
                     call: MCPStdioServer.Call) -> (Outcome, Probe) {
        let first = send(on: probe, method: method, params: params, deadlineMs: deadlineMs, opID: nil, cancel: call.cancel)
        switch first {
        case .gone:
            let again = LiveClient.probe(client: call.client, keep: true)
            guard again.state == .live else { return (.gone, again) }
            return (send(on: again, method: method, params: params, deadlineMs: deadlineMs, opID: nil, cancel: call.cancel), again)
        case .timeout:
            let again = LiveClient.probe(client: call.client)
            return (.timeout, again)
        default:
            return (first, probe)
        }
    }

    /// 写请求（§9.1「第四种情况」，STEP 3b 的写工具用）：断了或超时 → 新连接、新 hello，app 的 pid 和上次相同才用
    /// 同一个 op_id 重发一次（app 做过就回 replayed:true）；还不行 → app_outcome_unknown（带 op_id）；pid 变了 → app_restarted。
    /// 绝不改走无头。
    enum WriteOutcome {
        case done(Outcome)
        case outcomeUnknown(opID: String)
        case restarted(opID: String)
    }

    static func write(_ probe: Probe, method: String, params: [String: Any], deadlineMs: Int, opID: String,
                      call: MCPStdioServer.Call) -> WriteOutcome {
        let pid = probe.appPID
        let first = send(on: probe, method: method, params: params, deadlineMs: deadlineMs, opID: opID, cancel: call.cancel)
        switch first {
        case .gone, .timeout:
            let again = LiveClient.probe(client: call.client, keep: true)
            guard again.state == .live else { return .outcomeUnknown(opID: opID) }
            guard again.appPID == pid else { return .restarted(opID: opID) }
            let second = send(on: again, method: method, params: params, deadlineMs: deadlineMs, opID: opID, cancel: call.cancel)
            switch second {
            case .gone, .timeout: return .outcomeUnknown(opID: opID)
            default: return .done(second)
            }
        default:
            return .done(first)
        }
    }

    // MARK: - 状态 → 说明、错误码（§10.2、§4.5）

    /// 不是 live 时给模型看的那一句（app_status 的 warning、要 app 的工具的错误）。
    static func explain(_ p: Probe) -> (message: String, hint: String) {
        switch p.state {
        case .live:
            return ("选片工具开着，可以实时操作。", "")
        case .notRunning:
            // §10.2 那句后面补一句：锁被别的程序拿走、又放掉以后，app 下一次自检（1 s 内）拿回来之前锁是空的，这里分不出
            // 「没开」和「开着、标题栏写着锁被拿走了」（§9.2.4）
            return ("选片工具没开。", "请用户自己打开选片工具，并在 app 里打开要处理的场次，再调一次；MCP 不会启动它。" + Self.lockLostAside)
        case .bridgeOff:
            return ("选片工具开着，但用户在菜单里关了「\(LiveBridgeNotice.menuTitle)」。", "请用户在选片工具菜单里打开它；MCP 不会替用户打开。")
        case .unreachable where lockUnseen(p):
            // 数据目录连 stat 都被拒、或者锁文件打不开（EACCES / EPERM）：锁到底有没有人拿着都没看到，app 开着、没开都有可能。
            // 不能说成下面「锁被它占着」「10 秒内会自愈」那句
            let what = (p.reason ?? "").hasPrefix(dataDirUnreadable + ":") ? "数据目录" : "数据目录里的锁文件"
            return ("读不了\(what)（多半是宿主的沙箱不让读），看不出选片工具开没开，也就连不上它。", MCPStatus.sandboxHint)
        case .unreachable where isSandboxDenied(p):
            // 锁被 app 占着（app 开着），connect 被拒：宿主的沙箱不让连本用户临时目录里的 socket，等多久也不会自愈
            return ("选片工具开着（数据目录的锁被它占着），但连不上本用户临时目录里它的 socket（\(p.reason ?? "")，多半是宿主的沙箱不让连）。",
                    MCPStatus.sandboxHint)
        case .unreachable where p.reason == "lock_role_unknown":
            // 锁被占着、锁文件里却没有选片工具写的那一行：多半是锁被别的程序拿走了（app 开着时被拿走：自检关桥、标题栏说那一句，
            // §9.2.4；app 启动时就被占着：app 先不开桥、每秒再拿）；也可能是选片工具第一次启动、还没来得及写那一行。
            // 哪一种 --mcp 分不出来，所以 hint 只说「标题栏上要是写着那一句」
            return ("数据目录的锁被一个不认识的程序占着（锁文件里没有选片工具写的那一行）：选片工具要是开着，它的 AI 实时操作停着；"
                    + "也可能是选片工具刚启动、还没写那一行。",
                    "选片工具的标题栏上要是写着「\(LiveBridgeNotice.lockLost)」，请用户退出并重新打开选片工具；它刚启动的话过几秒再调")
        case .unreachable:
            // 锁文件那一行写着桥为什么停了（锁丢过、开桥 / 重新 bind 失败）：说法和 app 标题栏上的同一句话对得上。
            // 只认 app 会写进那一行的原因：--mcp 自己算出来的 no_temp_dir 和 app 的标题栏无关
            if let r = p.reason, LiveBridgeNotice.onLockLine.contains(r), let known = LiveBridgeNotice.explain(r) { return known }
            let why = p.reason.map { "（\($0)）" } ?? ""
            return ("选片工具开着（数据目录的锁被它占着），但连不上它的实时桥\(why)：socket 不在、被系统清掉还没自愈，或者两边算出的临时目录不一样。",
                    "10 秒内会自愈；不行就请用户重开选片工具")
        case .unresponsive:
            return ("选片工具开着，但 1 秒内没回应（app 被停住或者卡住了）。", "app 没响应，请用户看一下 app；过一会儿再调")
        case .protoMismatch:
            return ("选片工具的实时桥协议版本和这个 MCP 对不上（app 或 MCP 有一边更新过）。", "请用户退出并重新打开选片工具；还不行就是两边版本差太多，更新 app")
        case .oldApp:
            // 锁空着、默认数据目录、又有选片工具在跑：也可能是锁刚被别的程序放掉、app 还没拿回来（同上）
            return ("开着的是还没有实时桥的旧版选片工具。", "请用户更新 app，或者先退出它。" + Self.lockLostAside)
        case .notReady:
            return ("选片工具正在启动或者正在退出。", "过几秒再调")
        case .dataDirMismatch:
            return ("连上的选片工具用的不是这个数据目录（目录被换过，或者 LABELGUI_DATA_DIR 指的不是 app 用的那个）。", "请用户重开选片工具；MCP 配置里别设 LABELGUI_DATA_DIR")
        case .peerRejected:
            return ("实时桥的另一端不是当前用户的进程，或者它拒绝了这个连接。", "不要重试；请用户检查是不是有别的账户开着选片工具")
        case .headlessWriter:
            return ("另一个 MCP 正在写这个数据目录（无头写者占着锁）。", "等几秒再调")
        case .disabled:
            return ("这个服务器设了 LABELGUI_MCP_LIVE=0：不连正在运行的 app。", "只能看状态、列场次和模板；要实时操作，去掉这个环境变量再重连 MCP 服务器")
        }
    }

    /// 数据目录 realpath / stat 被拒（EACCES / EPERM）时 probe 的 reason 前缀，后面接 ":<errno>"。
    static let dataDirUnreadable = "data_dir_unreadable"

    /// 数据目录 realpath / stat 被拒，或者锁文件 open 被拒（EACCES / EPERM；ELOOP 是锁被换成了符号链接，不算）：
    /// 锁有没有人拿着都没看到，看不出 app 开没开（§9.1、§8 第 27 条）。
    static func lockUnseen(_ p: Probe) -> Bool {
        guard p.state == .unreachable, let r = p.reason else { return false }
        return r.hasPrefix(dataDirUnreadable + ":") || r == "lock_unreadable:\(EACCES)" || r == "lock_unreadable:\(EPERM)"
    }

    /// 多半是宿主的沙箱：上面那种，或者锁被 app 占着、connect 本用户临时目录里的 socket 被拒（EPERM / EACCES，§8 第 27 条；
    /// socket 在本用户自己的 0700 目录里，不是沙箱一般不会这样）。说明里不能说「10 秒内会自愈」，hint 是在宿主里放行。
    static func isSandboxDenied(_ p: Probe) -> Bool {
        lockUnseen(p) || (p.state == .unreachable && (p.reason == "connect:\(EPERM)" || p.reason == "connect:\(EACCES)"))
    }

    /// not_running / old_app 的 hint 后面那一句（锁是空的时候 --mcp 分不出是不是锁刚被别的程序放掉，§9.2.4）。
    static let lockLostAside = "选片工具其实开着、标题栏上写着「\(LiveBridgeNotice.lockLost)」的话：请用户退出并重新打开它。"

    /// 要 app 的工具在这个状态下回的错误码（§9.1 表后那一段 + §10.2）。
    static func errorCode(_ s: LiveState) -> String {
        switch s {
        case .notRunning: return "app_not_running"
        case .bridgeOff: return "bridge_off"
        case .unreachable: return "app_unreachable"
        case .unresponsive: return "app_unresponsive"
        case .protoMismatch: return "app_version_mismatch"
        case .oldApp: return "old_app"
        case .notReady: return "not_ready"
        case .dataDirMismatch: return "data_dir_mismatch"
        case .peerRejected: return "peer_rejected"
        case .headlessWriter: return "busy"
        case .live, .disabled: return "internal"
        }
    }
}

private extension LiveClient.HelloOutcome {
    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}
