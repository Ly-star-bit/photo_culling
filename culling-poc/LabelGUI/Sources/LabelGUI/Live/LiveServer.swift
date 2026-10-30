import Foundation
import AppKit
import Combine

/// 测试宿主（--live-host）才有的开关，LiveHost 从 LABELGUI_LIVE_TEST_* 读进来；GUI 进程不读这些变量（§9.8.1）。
struct LiveTestOptions {
    /// LABELGUI_LIVE_SOCK_ROOT：测试自己的 socket 根目录（LiveHost 已经拒绝了解析到真实 SockDir 的）。
    var sockRoot: String
    /// LABELGUI_LIVE_TEST_PROTO=min,max：假装别的协议区间（§9.8.2 第 16 条）。
    var proto: (min: Int, max: Int)?
    /// LABELGUI_LIVE_TEST_DROP_CAP=<方法>：假装旧版 app 少一个方法。
    var dropCapability: String?
    /// LABELGUI_LIVE_TEST_SELFCHECK_MS：自检间隔，默认 10 s，测试设 500。
    var selfCheckMs: Int?
    /// LABELGUI_LIVE_TEST_SIGPIPE：只给 sigpipe 矩阵单独开某一层（R6 §4.3），默认三层全开。
    var sigpipe = LiveServer.SigpipeLayers.all
    /// LABELGUI_LIVE_TEST_REJECT_PEERS=1：把所有对端都当成别的 uid，走拒绝那条路（R6 T14）。
    var rejectPeers = false
    /// LABELGUI_LIVE_TEST_PROTECTED_PREFIX=<目录>：cull.preview 把它当成受保护前缀（§10.7 第 33 条：合成图目录
    /// 假装在桌面上，证明受保护位置不读原图）。
    var protectedPrefix: String?
    /// LABELGUI_LIVE_TEST_CONNECTED_MS / LABELGUI_LIVE_TEST_JUSTDID_MS：标题栏「已连接」（120 s）、「刚做完」（10 s）
    /// 留多久（§9.8.2 第 21 条：测试把它们缩短，不用干等两分钟）。
    var connectedMs: Double?
    var justDidMs: Double?
}

/// 实时桥的服务端（DESIGN §9.2–§9.4，原型 R6 的 Server.swift）。
/// GUI（`.gui`）和 --live-host（`.testHost`）是同一个类、同一套代码，只差 socket 根目录、测试开关和窗口状态从哪来；
/// --app-ui（bridge: .none）根本不建它：不拿锁、不建 SockDir、不 bind（§5 第 7 层）。
///
/// 线程：accept 线程（poll + accept，500 ms，外加一根唤醒管道）→ 每个连接一个读线程（阻塞读、按行切）和一条串行写队列
/// → hello / ping 在读线程上直接回（不经主线程：主线程卡住时 hello 照样秒回，客户端由此分清「忙」和「死」，R6 T3b、T9）
/// → 其余请求 `Task { @MainActor }`：读直接执行，写排进主线程上的一条 FIFO（上一个写落地之前下一个不开始，§9.2.3）
/// → 结果交回这个连接自己的写队列，JSON 编码和写 socket 都不在主线程上。
/// 桥上永远不调任何会激活 app、把窗口拉到前面、取消最小化 / 隐藏的方法（§9.5.6；禁用词见 §5 第 7 层，live_smoke / mcp_smoke 的 grep）。
final class LiveServer: @unchecked Sendable {
    enum Mode {
        case gui
        case testHost(LiveTestOptions)
    }

    /// SIGPIPE 三层（§9.2.4，R6 §4.3 矩阵）：只在 accept 之后设 SO_NOSIGPIPE 不够 —— 客户端在 accept 之前就走了时
    /// setsockopt 回 EINVAL，接着一写整个 app 就被 SIGPIPE 杀掉。所以监听 socket 上设（accept 出来的继承）、accept 后再设一次
    /// 并查返回值（失败就关，一个字节都不写）、所有写都 send(…, MSG_NOSIGNAL)。只有 sigpipe 矩阵的测试宿主会关掉其中几层。
    struct SigpipeLayers: Equatable {
        var listen = true
        var accepted = true
        var noSignal = true
        /// accept 后那一次设失败就关（只在三层全开时；单开「accept 后」那一层时照原型的写法，失败也接着用）。
        var closeOnFailure = true

        static let all = SigpipeLayers()

        static func named(_ name: String) -> SigpipeLayers? {
            switch name {
            case "all": return .all
            case "none": return SigpipeLayers(listen: false, accepted: false, noSignal: false, closeOnFailure: false)
            case "accepted_only": return SigpipeLayers(listen: false, accepted: true, noSignal: false, closeOnFailure: false)
            case "listen_inherit": return SigpipeLayers(listen: true, accepted: false, noSignal: false, closeOnFailure: false)
            case "msg_nosignal": return SigpipeLayers(listen: false, accepted: false, noSignal: true, closeOnFailure: false)
            default: return nil
            }
        }
    }

    /// 桥现在的样子（hello 的 bridge、锁文件那一行、测试宿主的 ready 行）。
    enum Bridge: Equatable {
        case on
        /// 设置里关了 / test.set_bridge：socket 关掉删掉，锁照常持有（§9.2.1 末尾）。
        case off(String)
        /// 开不了：数据目录、socket 路径太长、SockDir 不安全、bind 失败、另一个实例占着、等锁、锁丢了。
        case unavailable(String)

        var word: String {
            switch self {
            case .on: return "on"
            case .off: return "off"
            case .unavailable: return "unavailable"
            }
        }

        var reason: String? {
            switch self {
            case .on: return nil
            case .off(let r), .unavailable(let r): return r
            }
        }
    }

    /// 桥不是 on 时，已经连上的连接上来的读写回什么（第 5 步，读在 execute 里）。bridge_off 只给菜单开关（.off）：
    /// 别的（锁丢了、开桥 / 重新 bind 失败）不是用户关的，回 app_unreachable（和 `--mcp` 新探测时从锁文件那一行判出来的
    /// 同一个码，§10.2），message / hint 说真正的原因和标题栏上那一句（LiveBridgeNotice）。纯函数，--mcp-selftest 逐行测。
    static func bridgeDownReply(_ b: Bridge) -> Reply? {
        switch b {
        case .on:
            return nil
        case .off:
            return .failure("bridge_off", "用户在选片工具菜单里关了「允许 AI 实时操作」：这次没有执行",
                            ["executed": false, "hint": "请用户在选片工具菜单里打开它；MCP 不会替用户打开"])
        case .unavailable(let r):
            let why = LiveBridgeNotice.explain(r)
                ?? ("选片工具的实时桥现在没开（\(r)）。", "过几秒再调；一直这样就请用户重开选片工具")
            var data: [String: Any] = ["executed": false, "reason": r]
            data["hint"] = why.hint
            return .failure("app_unreachable", why.message + "这次没有执行。", data)
        }
    }

    /// 标题栏上「桥停了」的那一条（§9.2.4）：锁丢了 → 那一句；开桥 / 重新 bind 失败 → 带原因的那一句；别的没有。
    static func indicatorProblem(_ b: Bridge) -> LiveBridgeProblem? {
        guard case .unavailable(let r) = b else { return nil }
        if r == "lock_lost" { return .lockLost }
        return LiveBridgeNotice.failed(r).map { LiveBridgeProblem.failed($0) }
    }

    enum MethodKind {
        case read, write
    }

    /// 一个请求（主线程上的方法拿到的）。`clientGone`：这个连接的读线程读到 EOF 就置上（§10.2 的取消，STEP 3a 用）。
    struct Request: @unchecked Sendable {
        let method: String
        let params: [String: Any]
        let opID: String?
        let deadlineMs: Int
        let received: Double
        let clientGone: LiveFlag
    }

    enum Reply: @unchecked Sendable {
        case result([String: Any])
        case failure(String, String, [String: Any]?)

        func frame(id: Any) -> [String: Any] {
            switch self {
            case .result(let r):
                return ["id": id, "result": r]
            case .failure(let code, let message, let data):
                var e: [String: Any] = ["code": code, "message": message]
                if let data { e["data"] = data }
                return ["id": id, "error": e]
            }
        }
    }

    struct MainMethod: @unchecked Sendable {
        let kind: MethodKind
        let run: @MainActor (Request) async -> Reply
    }

    /// 在连接线程上直接回的方法（只有测试宿主的 test.pause_accept 这类不碰 store 的）。
    typealias DirectMethod = ([String: Any]) -> Reply

    /// hello 的内容：主线程在场次、tab、窗口、分析状态变化时更新，连接线程加锁读（§9.2.2）。
    private struct Snapshot {
        var ready = false
        var windows = 0
        var windowState = "no_window"
        var tab = "batch"
        var openSession: [String: Any]?
        var analysisRunning = false
        var progressText = ""
        var mainBeat = LiveWire.nowMs()
        var helloCount = 0
        var lastHelloMs: Double?
        var lastClient: String?
    }

    let mode: Mode
    let paths: LivePaths?
    let protoMin: Int
    let protoMax: Int
    let selfCheckMs: Int
    let layers: SigpipeLayers
    let rejectPeers: Bool
    let dropCapability: String?
    let maxConnections = 16
    let helloTimeoutMs = 2_000
    let idleTimeoutMs = 120_000
    let started = ISO8601DateFormatter().string(from: Date())

    var isTestHost: Bool {
        if case .testHost = mode { return true }
        return false
    }

    /// 测试宿主的假受保护前缀（LiveHandlers.isProtectedFolder 用；GUI 永远是 nil）。
    var testProtectedPrefix: String? {
        if case .testHost(let o) = mode { return o.protectedPrefix }
        return nil
    }

    // 下面这些由 `state` 锁着（accept 线程、连接线程、自检队列、主线程都会碰）。
    private let state = NSLock()
    private var lock: LiveLock?
    private var bridge: Bridge
    /// 锁出过事（自检里，§9.2.4）：「lock_lost」被别的程序拿走过（一直留着，重开 app 才恢复）；「lock_reopen_failed」
    /// 锁文件重新 open 不了（拿回来就清掉）。和桥的状态分开记：菜单关着时桥是 .off（--mcp 回 bridge_off，菜单说了算），
    /// 再打开菜单时 openBridge 看到它就不开桥、桥回到 .unavailable(这个原因)。
    private var lockTrouble: String?
    private var listenFd: Int32 = -1
    private var boundIno: UInt64 = 0
    /// 换下来的监听 fd：drain = 重新 bind 以后旧 fd 上已经排队的连接照常 accept 完再关；否则直接关（桥关掉了）。
    private var retired: [(fd: Int32, drain: Bool)] = []
    private var pausedUntil = 0.0
    private var connections = 0
    private var nextConnID = 0
    private var snap = Snapshot()
    private var mainMethods: [String: MainMethod] = [:]
    private var directMethods: [String: DirectMethod] = [:]
    private var counters: [String: Int] = [:]
    private var wakeR: Int32 = -1
    private var wakeW: Int32 = -1
    private var acceptStarted = false
    private var shuttingDown = false
    private var selfCheckTimer: DispatchSourceTimer?
    private var lockRetryTimer: DispatchSourceTimer?
    private let selfCheckQueue = DispatchQueue(label: "xuanpian.live.selfcheck")
    /// 开桥、关桥、自检一次只做一个（主线程上的菜单 / test.set_bridge 和自检队列会同时来）：不然自检刚看到「桥开着、
    /// socket 不在」，菜单那边把桥关了，自检又把它重新开起来。可重入：自检里会调 openBridge。
    private let bridgeOps = NSRecursiveLock()

    // 主线程上的（和 store 同一个隔离域）。
    @MainActor private weak var model: AppModel?
    @MainActor private var writeTail: Task<Void, Never>?
    /// op_id → 当时的结果（最近 256 个，§9.2.3）：客户端超时 / 断线后带同一个 op_id 重发，拿到的是第一次的结果。
    @MainActor private var opCache: [String: [String: Any]] = [:]
    @MainActor private var opOrder: [String] = []
    @MainActor private var opRunning: [String: Task<Reply, Never>] = [:]
    /// 排着队或正在落地的写（读的结果里带 pending_writes，§9.2.3）。
    @MainActor private(set) var pendingWrites = 0
    /// 测试宿主模拟最小化 / 别的桌面（test.set_window_state）：只改报出去的值，不碰任何窗口。
    @MainActor var windowOverride: String?
    /// 测试宿主的「菜单开关」（test.set_bridge）：只在内存里，宿主从不读写 UserDefaults（§9.8.1）。
    @MainActor private var testBridgeAllowed = true
    @MainActor private var observers: [AnyCancellable] = []
    @MainActor private var tokens: [NSObjectProtocol] = []
    @MainActor private var heartbeat: DispatchSourceTimer?

    private init(mode: Mode, dataDir: URL) {
        self.mode = mode
        var sockRoot: String?
        var proto = (min: LiveWire.protoMin, max: LiveWire.protoMax)
        var layers = SigpipeLayers.all
        var reject = false
        var drop: String?
        var interval = 10_000
        if case .testHost(let o) = mode {
            sockRoot = o.sockRoot
            proto = o.proto ?? proto
            layers = o.sigpipe
            reject = o.rejectPeers
            drop = o.dropCapability
            interval = max(100, o.selfCheckMs ?? interval)
        }
        protoMin = proto.min
        protoMax = proto.max
        self.layers = layers
        rejectPeers = reject
        dropCapability = drop
        selfCheckMs = interval
        switch LivePaths.resolve(dataDir: dataDir.path, sockRoot: sockRoot) {
        case .success(let p):
            paths = p
            bridge = .unavailable("starting")
        case .failure(let problem):
            paths = nil
            bridge = .unavailable(problem == .noTempDir ? "no_temp_dir" : "data_dir")
        }
    }

    static func log(_ text: String) {
        MCPLog.stderr("[live \(getpid())] \(text)\n")
    }

    // MARK: - 启动（AppModel.make 里两步：建 store 之前 prepare 拿锁，建好以后 attach 开桥）

    /// §9.2.1 第 1 步：open + flock(LOCK_EX|LOCK_NB)。拿不到就对 S 发一次 hello、等 500 ms：有回复 = 另一个 app 实例占着
    /// 这个数据目录，本实例照常启动、不开桥；没回复 = 锁在无头写者（v2）或另一个正在启动的实例手里，每 100 ms 重试，
    /// 最多 3 s；还拿不到就照常启动、先不开桥，attach 以后后台每 1 s 重试（R6 §3.2）。阻塞的是调用方（GUI 的主线程）。
    static func prepare(_ mode: Mode, dataDir: URL) -> LiveServer {
        let server = LiveServer(mode: mode, dataDir: dataDir)
        server.acquireAtStartup()
        return server
    }

    private func acquireAtStartup() {
        guard let paths else { return }
        let start = LiveWire.nowMs()
        while true {
            switch LiveLock.tryAcquire(paths.lockPath) {
            case .acquired(let l):
                setLocked { lock = l }
                return
            case .failed(let why):
                Self.log("拿不到 \(paths.lockPath)：\(why)；不开桥")
                setLocked { bridge = .unavailable("lock_failed") }
                return
            case .busy:
                if Self.answersHello(paths) {
                    Self.log("另一个选片工具正在用这个数据目录（它回了 hello）：本实例不开桥")
                    setLocked { bridge = .unavailable("another_instance") }
                    return
                }
                if LiveWire.nowMs() - start > 3_000 {
                    Self.log("等锁 3 s 还没拿到：先不开桥，后台每 1 s 再试")
                    setLocked { bridge = .unavailable("waiting_for_lock") }
                    return
                }
                usleep(100_000)
            }
        }
    }

    /// 锁的主人回不回 hello（500 ms 内有任何一行回复都算活着）。
    private static func answersHello(_ paths: LivePaths) -> Bool {
        guard !paths.socketTooLong, case .connected(let fd) = LiveConnect.connect(paths.socketPath, timeoutMs: 500) else { return false }
        defer { close(fd) }
        var client: [String: Any] = ["name": "选片工具", "pid": Int(getpid())]
        client["uuid"] = LiveBuildInfo.uuid
        var params: [String: Any] = ["proto": LiveWire.proto, "data_dir": paths.dataDir, "data_dir_id": paths.dataDirID]
        params["client"] = client
        let frame: [String: Any] = ["id": 0, "method": "hello", "params": params]
        if case .line = LiveConnect.exchange(fd, frame, timeoutMs: 500, maxLine: LiveWire.maxReplyLine) { return true }
        return false
    }

    /// store 建好以后（AppModel.make 的最后）：方法表、观察 store、主线程心跳；拿到了锁就写那一行，设置开着才开 socket
    /// （§9.2.1 第 3–5 步）。
    @MainActor
    func attach(_ model: AppModel) {
        self.model = model
        LiveHandlers.register(self, model: model)
        observe(model)
        if case .gui = mode {
            observeWindows()
            // 忙信号里 AppKit 的那几样（按下在本 app 里、输入框、模态窗口）只有 GUI 看（§9.6b）
            model.interaction.startWatchingAppKit()
        }
        refreshSnapshot()
        startHeartbeat()
        // 标题栏指示（§9.6a）：菜单那一项的勾按设置来；另一个实例占着这个数据目录时副标题说一句
        if case .testHost(let o) = mode { model.indicator.configure(connectedMs: o.connectedMs, justDidMs: o.justDidMs) }
        model.indicator.setBridgeEnabled(bridgeAllowed)
        if bridgeState == .unavailable("another_instance") { model.indicator.setAnotherInstance(true) }
        let (held, waiting) = withState { (lock != nil, bridge == .unavailable("waiting_for_lock")) }
        if held {
            enableBridgeIfAllowed()
        } else if waiting {
            startLockRetry()
        }
        // 开桥失败（SockDir 不安全、bind 失败、锁文件打不开……）的那一句：这里已经在主线程上，当场设好
        syncIndicator()
    }

    /// GUI：UserDefaults 里的 live.bridgeEnabled，没有这个键 = 开（§9.6a）。这里只读；写它的只有 main.swift 里的菜单开关。
    /// 测试宿主不读也不写这个键（§9.8.1：.app 里的二进制和用户的 app 共用设置域），用内存里的 testBridgeAllowed
    /// （默认开，test.set_bridge 改它）。
    @MainActor
    private var bridgeAllowed: Bool {
        switch mode {
        case .gui:
            guard !AppRuntime.headless, ProcessInfo.processInfo.environment["LABELGUI_NO_GUI"] != "1" else { return false }
            return UserDefaults.standard.object(forKey: "live.bridgeEnabled") as? Bool ?? true
        case .testHost:
            return testBridgeAllowed
        }
    }

    /// 「允许 AI 实时操作（MCP）」开关（§9.6a；GUI 的菜单和测试宿主的 test.set_bridge 都经 AppModel.setLiveBridge 到这里）。
    /// 关：关监听 fd、删自己的 socket、锁文件写 bridge:"off"，锁继续持有（§9.2.1 末尾）；`--mcp` 读写都回 bridge_off，
    /// app 照常开着。开：重做 §9.2.1 第 4、5 步。没拿到锁（另一个实例占着、启动时还在等锁）时只记下开关：
    /// 拿到锁时 enableBridgeIfAllowed 照它开不开。GUI 的设置（UserDefaults）由菜单先写好，这里不碰。
    /// 关的那一刻已经过了第 6a 步的写（还在算的一键成套 / 换封面）照常落地、照常记 aiLog：和用户自己点的一样一步 ⌘Z 撤得掉；
    /// 排在后面的、正在等用户停手的写，轮到时在第 5 / 6a 步回 bridge_off（§9.6a、§10.8 第 8 条只说关了以后来的调用）。
    /// 锁丢了以后（§9.2.4）菜单照样说了算：关 → 桥变成 .off，锁文件那一行写 bridge:"off"，--mcp 回 bridge_off（标题栏这时
    /// 什么都不显示，不能让模型说「标题栏上写着锁被拿走了」）；再开 → openBridge 看到 lockTrouble 不开桥，桥回到
    /// .unavailable("lock_lost")，那一句回到标题栏。整段在 bridgeOps 里：和自检发现锁丢了的那一下不交错。
    @MainActor
    func setBridgeEnabled(_ on: Bool) {
        if case .testHost = mode { testBridgeAllowed = on }
        model?.indicator.setBridgeEnabled(on)
        bridgeOps.lock()
        defer { bridgeOps.unlock() }
        guard withState({ lock != nil && !shuttingDown }) else { return }
        switch bridgeState {
        case .off:
            if on { openBridge() }
        case .on:
            if !on { closeBridge("disabled_in_settings") }
        case .unavailable(let r) where Self.retryable.contains(r) || r == "lock_lost":
            // 开桥失败、自检在重试的那几种，还有锁丢了：关掉就是 .off（别再重试，--mcp 回 bridge_off）；开着就让自检接着试
            if !on { closeBridge("disabled_in_settings") }
        case .unavailable:
            break
        }
    }

    /// 开桥失败以后自检接着重试的原因（路径太长、另一个实例、锁丢了这些不试）。lock_reopen_failed：锁文件重新 open 不了，
    /// 自检每轮再 open 一次，拿回来了再开桥。
    static let retryable: Set<String> = ["bind_failed", "sock_dir_unsafe", "socket_path_occupied", "lock_reopen_failed"]

    /// 拿着锁就开自检定时器，不管桥开没开成：开桥失败（SockDir 不安全、bind 失败）靠它下一轮再试，
    /// 桥关着时锁文件被删也靠它重建（§9.2.4）。只在 openBridge 成功时才开的话，这两种都永远不会被发现。
    @MainActor
    private func enableBridgeIfAllowed() {
        if bridgeAllowed {
            openBridge()
        } else {
            setLocked { bridge = .off("disabled_in_settings") }
            writeLockInfo()
        }
        startSelfCheck()
    }

    /// 后台每 1 s 再拿一次锁（启动时等了 3 s 没拿到的那种）；拿到了就照常开桥。
    private func startLockRetry() {
        guard let paths else { return }
        let timer = DispatchSource.makeTimerSource(queue: selfCheckQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard case .acquired(let l) = LiveLock.tryAcquire(paths.lockPath) else { return }
            self.setLocked {
                self.lock = l
                self.bridge = .unavailable("starting")
            }
            self.lockRetryTimer?.cancel()
            Self.log("后台拿到了锁")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.enableBridgeIfAllowed() }
            }
        }
        setLocked { lockRetryTimer = timer }
        timer.resume()
    }

    // MARK: - 开桥、关桥、重新 bind（§9.2.1 第 4、5 步，§9.2.4 自愈）

    /// 开桥：建 / 检查 SockDir → 删掉自己的残留 socket → bind → 写锁文件那一行 → accept 线程和自检定时器。
    /// 任何一步不行就不开桥（bridge = unavailable，带原因），下一次自检再试（路径太长、另一个实例那几种不试）。
    @discardableResult
    func openBridge() -> Bool {
        bridgeOps.lock()
        defer { bridgeOps.unlock() }
        guard let paths, withState({ lock != nil && !shuttingDown }) else { return false }
        // 开成了 → 清掉「开不起来」那一句；没开成 → 标题栏提示（§9.2.4「任何一步失败：不开桥，标题栏提示」）
        defer { publishBridge() }
        // 锁出过事（锁丢了 / 锁文件重新 open 不了）：菜单再打开也不开桥，桥回到那个原因（标题栏那一句跟着回来）
        if let trouble = withState({ lockTrouble }) {
            setLocked { bridge = .unavailable(trouble) }
            writeLockInfo()
            return false
        }
        if paths.socketTooLong {
            Self.log("socket 路径 \(paths.socketPath.utf8.count) 字节，超过 sun_path 的 \(LiveSockAddr.maxPathBytes) 字节：不开桥")
            setLocked { bridge = .unavailable("socket_path_too_long") }
            writeLockInfo()
            return false
        }
        if let why = Self.ensureSockDir(paths.sockDir) {
            Self.log("socket 目录不能用：\(why)；不开桥")
            setLocked { bridge = .unavailable("sock_dir_unsafe") }
            writeLockInfo()
            return false
        }
        guard Self.removeStaleSocket(paths.socketPath) else {
            setLocked { bridge = .unavailable("socket_path_occupied") }
            writeLockInfo()
            return false
        }
        let fd: Int32
        let ino: UInt64
        switch bindNew(paths.socketPath) {
        case .success(let pair):
            (fd, ino) = pair
        case .failure(let why):
            Self.log(why.text)
            setLocked { bridge = .unavailable("bind_failed") }
            writeLockInfo()
            return false
        }
        setLocked {
            if listenFd >= 0 { retired.append((listenFd, true)) }
            listenFd = fd
            boundIno = ino
            bridge = .on
            snap.ready = true
        }
        writeLockInfo()
        startAcceptThread()
        startSelfCheck()
        wakeAcceptThread()
        Self.log("桥开了：\(paths.socketPath)")
        return true
    }

    /// 关桥（设置关掉 / test.set_bridge；自检发现锁丢了 / 锁文件重新 open 不了也走这里）：关监听 fd、删自己那个 socket、
    /// 锁文件写 bridge:"off"，锁继续持有（§9.2.1 末尾）。
    /// `final`：关完以后桥的样子，默认 .off（菜单）；锁出了事是 .unavailable("lock_lost" / "lock_reopen_failed")。在同一次加锁里设好：
    /// 中间没有一段「.off」让第 5 步回成 bridge_off「用户在菜单里关了」。
    func closeBridge(_ reason: String, final: Bridge? = nil) {
        bridgeOps.lock()
        defer { bridgeOps.unlock() }
        setLocked {
            if listenFd >= 0 { retired.append((listenFd, false)) }
            listenFd = -1
            bridge = final ?? .off(reason)
            snap.ready = false
        }
        unlinkOwnSocket()
        writeLockInfo()
        wakeAcceptThread()
        publishBridge()
    }

    /// 桥的状态 → 标题栏（§9.2.4 的两句）。开桥 / 关桥 / 自检在自检队列上、也在主线程上（菜单、启动），一律转到主线程
    /// 再算：到主线程那一刻读桥的状态，先后颠倒的两次转发也落在最新的那个上。只改文字，不碰窗口。
    private func publishBridge() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.syncIndicator() }
        }
    }

    @MainActor
    private func syncIndicator() {
        model?.indicator.setBridgeProblem(Self.indicatorProblem(bridgeState))
    }

    /// 退出（GUI 的 willTerminate、测试宿主的 SIGTERM / test.quit）：ready=false、关监听 fd、socket 的 inode 还是自己那个才删；
    /// 锁由内核在进程退出时放掉。
    func shutdown() {
        bridgeOps.lock()
        defer { bridgeOps.unlock() }
        setLocked {
            shuttingDown = true
            snap.ready = false
            if listenFd >= 0 { retired.append((listenFd, false)) }
            listenFd = -1
        }
        unlinkOwnSocket()
        wakeAcceptThread()
    }

    private func unlinkOwnSocket() {
        guard let paths else { return }
        let ino = withState { boundIno }
        var st = stat()
        if lstat(paths.socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == geteuid(), UInt64(st.st_ino) == ino {
            unlink(paths.socketPath)
        }
    }

    /// SockDir 不存在就以 0700 建；存在的话必须是目录（lstat：不是符号链接）、属主是自己、组和其他人不可写。
    private static func ensureSockDir(_ dir: String) -> String? {
        var st = stat()
        if lstat(dir, &st) != 0 {
            if mkdir(dir, 0o700) != 0 && errno != EEXIST { return "mkdir \(dir)：\(LiveWire.errnoText())" }
            if lstat(dir, &st) != 0 { return "lstat \(dir)：\(LiveWire.errnoText())" }
        }
        if (st.st_mode & S_IFMT) != S_IFDIR { return "\(dir) 不是目录（可能是符号链接）" }
        if st.st_uid != geteuid() { return "\(dir) 的属主不是当前用户" }
        if (st.st_mode & 0o022) != 0 { return "\(dir) 对组或其他用户可写" }
        return nil
    }

    /// lstat(S)：不存在 → 好；是 socket、属主是自己 → unlink（我持有锁，它一定是残留）；是别的东西 → 不碰，不开桥。
    private static func removeStaleSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return true }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == geteuid() else {
            log("\(path) 已经有了，又不是自己的 socket：不删，不开桥")
            return false
        }
        unlink(path)
        log("stale socket replaced：\(path)")
        return true
    }

    private struct BindError: Error {
        let text: String
    }

    /// socket → CLOEXEC → 监听 socket 上 SO_NOSIGPIPE → bind → chmod 0600 → listen(64)。chmod 在 listen 之前，
    /// 中间没有能连进来的窗口。积压 64（§9.1 第二轮：macOS 积压满了 connect 直接 ECONNREFUSED），同时在线另限 16 个。
    private func bindNew(_ path: String) -> Result<(Int32, UInt64), BindError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return .failure(BindError(text: "socket：\(LiveWire.errnoText())")) }
        LiveFD.setCloexec(fd)
        if layers.listen { LiveFD.setNoSigpipe(fd) }
        guard let rc = LiveSockAddr.with(path, { bind(fd, $0, $1) }) else {
            close(fd)
            return .failure(BindError(text: "socket 路径超过 \(LiveSockAddr.maxPathBytes) 字节：\(path)"))
        }
        if rc != 0 {
            let e = LiveWire.errnoText()
            close(fd)
            return .failure(BindError(text: "bind \(path)：\(e)"))
        }
        chmod(path, 0o600)
        if listen(fd, 64) != 0 {
            let e = LiveWire.errnoText()
            close(fd)
            unlink(path)
            return .failure(BindError(text: "listen：\(e)"))
        }
        var st = stat()
        lstat(path, &st)
        return .success((fd, UInt64(st.st_ino)))
    }

    /// 锁文件那一行（§9.2.1 第 3 步）：谁持有、桥开没开、版本。
    func writeLockInfo() {
        let (l, b) = withState { (lock, bridge) }
        guard let l else { return }
        l.writeInfo(lockInfo(b))
    }

    private func lockInfo(_ b: Bridge) -> [String: Any] {
        var info: [String: Any] = ["role": "app", "pid": Int(getpid()), "bridge": b.word]
        if let r = b.reason { info["reason"] = r }
        info["proto"] = [protoMin, protoMax]
        info["version"] = LiveBuildInfo.version
        info["build"] = LiveBuildInfo.build
        info["uuid"] = LiveBuildInfo.uuid
        info["exe"] = LiveBuildInfo.exe
        info["started"] = started
        info["socket"] = paths?.socketPath ?? ""
        return info
    }

    /// 每 10 s 一次（测试宿主可以改，§9.2.4）：
    /// - 锁：inode 对不上 / 锁文件不在了 → 重新建、重新拿；别人拿着就关桥，标题栏说「数据目录的锁被别的程序拿走了…」
    ///   （§9.2.4）。之后桥不再开（别人放掉以后锁照样拿回来，拿回来之前 1 s 查一次），重开 app 才恢复；
    ///   重新 open 不了（数据目录被挪走、锁路径成了符号链接……）不是别人拿走：关桥、标题栏带原因说一句，每轮再试，拿回来就开桥；
    /// - socket 还在、inode 没变 → utimes(S) 和 utimes(SockDir)（防 dirhelper 按「3 天没访问」清，connect 不刷新 atime）；
    ///   不在了 / 被换了 → 整段重做开桥那一步（SockDir 也可能被整个清掉，照样重建、照样检查）；
    /// - 开桥失败过的（bind、SockDir）这里再试一次。重新 bind 失败时标题栏带原因说一句，开好了就消失（openBridge 里转主线程）。
    private func startSelfCheck() {
        let already = withState { selfCheckTimer != nil }
        guard !already else { return }
        let timer = DispatchSource.makeTimerSource(queue: selfCheckQueue)
        timer.schedule(deadline: .now() + .milliseconds(selfCheckMs), repeating: .milliseconds(selfCheckMs))
        timer.setEventHandler { [weak self] in self?.selfCheck() }
        setLocked { selfCheckTimer = timer }
        timer.resume()
    }

    /// 换自检的节奏（锁丢了、还没拿回来时最多 1 s 一次；拿回来改回 selfCheckMs）。定时器不用重建，换个 schedule 就行。
    private func rescheduleSelfCheck(_ ms: Int) {
        let timer = withState { selfCheckTimer }
        timer?.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
    }

    private func selfCheck() {
        bridgeOps.lock()
        defer { bridgeOps.unlock() }
        guard let paths else { return }
        let (l, b, stopping, trouble) = withState { (lock, bridge, shuttingDown, lockTrouble) }
        guard let l, !stopping else { return }
        bump("selfchecks")
        switch l.selfCheck(info: lockInfo(b)) {
        case .ok:
            // 数据目录挪回来了（还是原来那个锁文件）：清掉，下面按 lock_reopen_failed 那一条重新开桥
            if trouble == "lock_reopen_failed" {
                setLocked { lockTrouble = nil }
                Self.log("锁文件又在原来的位置了：重新开桥")
            }
        case .reacquired:
            bump("lock_reacquired")
            if trouble == "lock_lost" {
                // 锁丢过的：别人放掉以后照样拿回来（app 还开着，还是唯一写者；锁文件那一行写着 lock_lost，菜单关着时写 off，
                // --mcp 由此说清原因），但桥不再开：那段时间里别人可能改过盘，app 内存里的可能已经旧了，重开 app 才恢复
                // （标题栏那一句一直留着）。自检回到原来的间隔
                Self.log("锁丢过、现在又拿回来了：桥照样停着，重开 app 才恢复")
                rescheduleSelfCheck(selfCheckMs)
                return
            }
            setLocked { lockTrouble = nil }
            Self.log("锁文件被删 / 换过：重新建好、重新拿到了")
        case .lost(let why):
            // 已经停了（锁还在别人手里）：不再关一次、不再记一笔
            guard trouble != "lock_lost" else { return }
            bump("lock_lost")
            Self.log("锁丢了（\(why)）：AI 实时操作停了，重开 app 恢复")
            setLocked { lockTrouble = "lock_lost" }
            // 别人放掉锁到这里拿回来之间，--mcp 只看到一个空锁（判成 not_running / old_app）：拿回来之前 1 s 查一次
            rescheduleSelfCheck(min(selfCheckMs, 1_000))
            // 菜单关着：桥本来就是 .off，照旧（--mcp 回 bridge_off，菜单说了算）；再打开时 openBridge 看到 lockTrouble 不开桥
            if case .off = b { return }
            closeBridge("lock_lost", final: .unavailable("lock_lost"))
            return
        case .reopenFailed(let why):
            // 锁文件重新 open 不了：没有别的程序拿着锁（旧 fd 上的 flock 还在），不说「被别的程序拿走了」。锁文件已经不在 L 上，
            // 「锁是唯一判据」不成立：照样关桥，标题栏带原因说一句（lock_reopen_failed），每轮再 open，拿回来了上面那两条开桥。
            // 锁丢过的不改口
            guard trouble == nil else { return }
            bump("lock_reopen_failed")
            Self.log("锁文件重新 open 不了（\(why)）：先停桥，每轮自检再试")
            setLocked { lockTrouble = "lock_reopen_failed" }
            if case .off = b { return }
            closeBridge("lock_reopen_failed", final: .unavailable("lock_reopen_failed"))
            return
        }
        switch b {
        case .on:
            break
        case .unavailable(let r) where Self.retryable.contains(r):
            _ = openBridge()
            return
        default:
            return
        }
        let ino = withState { boundIno }
        var st = stat()
        if lstat(paths.socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, UInt64(st.st_ino) == ino {
            utimes(paths.socketPath, nil)
            utimes(paths.sockDir, nil)
            return
        }
        Self.log("socket 文件不在了或被换了：重新 bind")
        bump("rebinds")
        if openBridge() {
            Self.log("重新 bind 好了")
        }
    }

    // MARK: - accept

    private func startAcceptThread() {
        let start: Bool = withState {
            if acceptStarted { return false }
            acceptStarted = true
            var fds: [Int32] = [-1, -1]
            if pipe(&fds) == 0 {
                LiveFD.setCloexec(fds[0])
                LiveFD.setCloexec(fds[1])
                _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
                _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
                wakeR = fds[0]
                wakeW = fds[1]
            }
            return true
        }
        guard start else { return }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "xuanpian.live.accept"
        thread.start()
    }

    private func wakeAcceptThread() {
        let w = withState { wakeW }
        guard w >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(w, &byte, 1)
    }

    private func acceptLoop() {
        var drainBuf = [UInt8](repeating: 0, count: 64)
        while true {
            let (lfd, old, paused, wr, stop) = withState { () -> (Int32, [(fd: Int32, drain: Bool)], Double, Int32, Bool) in
                let o = retired
                retired = []
                return (listenFd, o, pausedUntil, wakeR, shuttingDown)
            }
            for item in old {
                if item.drain { drainQueued(item.fd) }
                close(item.fd)
            }
            if stop && lfd < 0 { return }
            let now = LiveWire.nowMs()
            if paused > now || lfd < 0 {
                // 暂停 accept（test.pause_accept）或桥关着：只等唤醒管道，积压留在内核里
                var pfd = pollfd(fd: wr, events: Int16(POLLIN), revents: 0)
                let wait = lfd < 0 ? Int32(500) : Int32(max(1, min(500, paused - now)))
                _ = poll(&pfd, wr >= 0 ? 1 : 0, wait)
                if pfd.revents != 0 { _ = read(wr, &drainBuf, drainBuf.count) }
                continue
            }
            var pfds = [pollfd(fd: lfd, events: Int16(POLLIN), revents: 0), pollfd(fd: wr, events: Int16(POLLIN), revents: 0)]
            let pr = poll(&pfds, wr >= 0 ? 2 : 1, 500)
            if pr <= 0 { continue }
            if wr >= 0 && pfds[1].revents != 0 {
                _ = read(wr, &drainBuf, drainBuf.count)
                continue
            }
            if pfds[0].revents != 0 {
                let cfd = accept(lfd, nil, nil)
                if cfd >= 0 { handleAccepted(cfd) }
            }
        }
    }

    /// 换下来的旧监听 fd：上面已经排队的连接照常 accept 完（§9.2.4 第二轮补）。
    private func drainQueued(_ fd: Int32) {
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return }
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { return }
            handleAccepted(cfd)
        }
    }

    private func handleAccepted(_ cfd: Int32) {
        LiveFD.setCloexec(cfd)
        let inherited = LiveFD.noSigpipe(cfd)
        if layers.accepted && LiveFD.setNoSigpipe(cfd) != 0 {
            // 对端已经断了（典型：客户端 hello 超时走了，这边才 accept）。三层全开时一个字节都不写，直接关。
            Self.log("accept 后 setsockopt(SO_NOSIGPIPE) 失败：\(LiveWire.errnoText()) inherited=\(inherited)")
            if layers.closeOnFailure {
                bump("sigpipe_closed")
                close(cfd)
                return
            }
        }
        // 对端检查：读任何一个字节之前。
        var uid: uid_t = 0
        var gid: gid_t = 0
        let okPeer = getpeereid(cfd, &uid, &gid) == 0 && uid == geteuid() && !rejectPeers
        var peerPid: pid_t = 0
        var plen = socklen_t(MemoryLayout<pid_t>.size)
        _ = getsockopt(cfd, SOL_LOCAL, LOCAL_PEERPID, &peerPid, &plen)
        if !okPeer {
            Self.log("reject peer uid=\(uid) pid=\(peerPid)")
            bump("rejected_peers")
            close(cfd)
            return
        }
        let (full, cid): (Bool, Int) = withState {
            let full = connections >= maxConnections
            if !full {
                connections += 1
                nextConnID += 1
            }
            return (full, nextConnID)
        }
        if full {
            bump("too_many_connections")
            let frame: [String: Any] = ["id": NSNull(), "error": ["code": "too_many_connections", "message": "同时在线的连接已满 \(maxConnections) 个"]]
            _ = LiveFD.sendAll(cfd, LiveWire.encode(frame), noSignal: layers.noSignal)
            close(cfd)
            return
        }
        let conn = LiveConnection(id: cid, fd: cfd, peerUID: Int(uid), peerPID: Int(peerPid), server: self)
        let thread = Thread { conn.run() }
        thread.name = "xuanpian.live.conn.\(cid)"
        thread.start()
    }

    fileprivate func connectionClosed() {
        setLocked { connections -= 1 }
    }

    /// test.pause_accept：accept 线程停 ms 毫秒（把积压塞满，测 §9.1 的 ECONNREFUSED 重连）。
    func pauseAccept(ms: Int) {
        setLocked { pausedUntil = LiveWire.nowMs() + Double(ms) }
        wakeAcceptThread()
    }

    // MARK: - 方法表

    /// 注册一个主线程上的方法（GUI 和测试宿主都有的在 attach 里注册；test.* 只有 LiveHost 会注册）。
    func register(_ name: String, kind: MethodKind, _ run: @escaping @MainActor (Request) async -> Reply) {
        setLocked { mainMethods[name] = MainMethod(kind: kind, run: run) }
    }

    func registerDirect(_ name: String, _ run: @escaping DirectMethod) {
        setLocked { directMethods[name] = run }
    }

    /// hello 里的 capabilities（§10.4）：注册了的方法，去掉 test.*（不是给 MCP 的）和测试宿主假装没有的那一个。
    /// ping 是协议本身的，不列。v1 是 12 个：3 个读（cull.read、cull.preview、collage.state）和 9 个写。
    func capabilities() -> [String] {
        withState { mainMethods.keys.filter { !$0.hasPrefix("test.") && $0 != dropCapability }.sorted() }
    }

    fileprivate enum Lookup {
        case main(MainMethod)
        case direct(DirectMethod)
        case unknown
    }

    fileprivate func lookup(_ name: String) -> Lookup {
        withState {
            if name == dropCapability { return .unknown }
            if let m = mainMethods[name] { return .main(m) }
            if let d = directMethods[name] { return .direct(d) }
            return .unknown
        }
    }

    /// 连接线程 → 主线程。App Nap：活动在跳主线程之前就开（§9.4.3 第 1 步），回复写出去以后再关。
    fileprivate func dispatch(_ method: MainMethod, name: String, id: Any, params: [String: Any],
                              deadlineMs: Int, opID: String?, conn: LiveConnection) {
        let received = LiveWire.nowMs()
        let activity = LiveBox(ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                     reason: "AI 操作"))
        conn.beginRequest()
        let box = LiveBox((id, params))
        Task { @MainActor [self] in
            let (id, params) = box.value
            let req = Request(method: name, params: params, opID: opID, deadlineMs: deadlineMs,
                              received: received, clientGone: conn.gone)
            let reply = await self.execute(method, req)
            conn.send(reply.frame(id: id)) {
                ProcessInfo.processInfo.endActivity(activity.value)
            }
            conn.endRequest()
        }
    }

    /// §9.4.3 第 3、4 步：deadline 超了 → expired（不执行）；写请求排进 FIFO、查 op_id 缓存。
    @MainActor
    private func execute(_ method: MainMethod, _ req: Request) async -> Reply {
        guard method.kind == .write else {
            if let e = expired(req) { return e }
            if let g = clientGone(req) { return g }
            // 桥关了 / 停了（菜单、锁丢了、重新 bind 失败）：已经连上的连接上排着的读也不做（写由 LiveHandlers 第 5、6a 步挡）。
            // test.* 不挡：测试脚本的连接跨过这些照样能看状态
            if !req.method.hasPrefix("test."), let down = Self.bridgeDownReply(bridgeState) { return down }
            return await method.run(req)
        }
        guard let op = req.opID, !op.isEmpty, op.utf8.count <= 128 else {
            return .failure("invalid_argument", "写请求必须带 op_id（1–128 字节）", nil)
        }
        if let cached = opCache[op] { return replayed(cached) }
        if let running = opRunning[op] {
            // 同一个 op_id 正在执行：等它做完，回同一份结果，不会做两遍
            let r = await running.value
            if case .result(let dict) = r { return replayed(dict) }
            return r
        }
        pendingWrites += 1
        let previous = writeTail
        let task = Task { @MainActor [self] () -> Reply in
            await previous?.value
            if let cached = opCache[op] { return replayed(cached) }
            if let e = expired(req) { return e }
            if let g = clientGone(req) { return g }
            let r = await method.run(req)
            if case .result(let dict) = r { remember(op, dict) }
            return r
        }
        opRunning[op] = task
        writeTail = Task { @MainActor in _ = await task.value }
        let r = await task.value
        opRunning[op] = nil
        pendingWrites -= 1
        return r
    }

    /// 也给写方法在等用户不忙之后再查一次（§9.4.3 第 6a 步）。
    @MainActor
    func expired(_ req: Request) -> Reply? {
        let queued = LiveWire.nowMs() - req.received
        guard queued > Double(req.deadlineMs) else { return nil }
        var data: [String: Any] = ["executed": false, "queued_ms": Int(queued)]
        data["deadline_ms"] = req.deadlineMs
        return .failure("expired", "在 app 主线程上排队 \(Int(queued)) ms，超过了截止时间 \(req.deadlineMs) ms：没有执行", data)
    }

    /// §10.2 的取消：这个连接的读线程已经读到 EOF（`--mcp` 收到 notifications/cancelled 就关连接，或者它自己死了）
    /// → 轮到主线程时**不执行**（还没开始的写不会生效，读也不白算）。回复写不出去，只记一笔给 test.state 看。
    /// 和 op_id 重发不冲突：连接断了而请求还没开始，app 就没做，重发时照常做。
    @MainActor
    func clientGone(_ req: Request) -> Reply? {
        guard req.clientGone.isSet else { return nil }
        bump("skipped_client_gone")
        return .failure("client_gone", "客户端已经断开，没有执行", ["executed": false])
    }

    @MainActor
    private func replayed(_ dict: [String: Any]) -> Reply {
        var r = dict
        r["replayed"] = true
        if var live = r["live"] as? [String: Any] {
            live["replayed"] = true
            r["live"] = live
        }
        return .result(r)
    }

    /// 缓存的结果不带预览图（STEP 2 审查：256 个拼图写的结果各带一张几百 KB 的 base64，会在用户的 app 里常驻上百 MB）。
    /// 重放时没有图，--mcp 那边加一句「要看现在的画面调 collage_get_state」。
    @MainActor
    private func remember(_ op: String, _ dict: [String: Any]) {
        var slim = dict
        if slim.removeValue(forKey: "preview_jpeg_b64") != nil {
            for k in ["preview_width", "preview_height", "preview_bytes"] { slim[k] = nil }
            slim["preview_omitted"] = true
        }
        opCache[op] = slim
        opOrder.append(op)
        if opOrder.count > 256 { opCache[opOrder.removeFirst()] = nil }
    }

    // MARK: - hello 的快照

    static func tabName(_ tab: AppTab) -> String {
        switch tab {
        case .batch: return "batch"
        case .watermark: return "watermark"
        case .collage: return "collage"
        case .labeling: return "labeling"
        }
    }

    @MainActor
    func openSessionObject(_ model: AppModel) -> [String: Any]? {
        let batch = model.batch
        guard let dir = batch.photoDir else { return nil }
        var open: [String: Any] = ["session": batch.sessionDir.lastPathComponent, "folder": dir.path]
        open["name"] = dir.lastPathComponent
        open["photo_count"] = batch.items.count
        return open
    }

    /// 场次、tab、分析状态、窗口：主线程上取，放进加锁的快照（hello 在连接线程上读它）。
    @MainActor
    func refreshSnapshot() {
        guard let model else { return }
        let open = openSessionObject(model)
        let tab = Self.tabName(model.tab)
        let running = model.batch.isRunning
        let progress = model.batch.progressText
        let (count, ws) = windowState()
        setLocked {
            snap.openSession = open
            snap.tab = tab
            snap.analysisRunning = running
            snap.progressText = progress
            snap.windows = count
            snap.windowState = ws
        }
    }

    /// 窗口的样子（§9.5.6）：hidden（⌘H）> minimized（全部最小化）> occluded（没有一个窗口可见：被挡住、在别的桌面、
    /// 全屏 app 占着当前桌面，AppKit 不区分）> visible；没有窗口是 no_window。只看，不动任何窗口。
    /// 测试宿主的窗口从不 order front，真算的话永远是 occluded / no_window：固定报 visible、1 个窗口，
    /// 只有 test.set_window_state 能改（§9.8.1 第二轮补）。
    @MainActor
    func windowState() -> (Int, String) {
        if isTestHost { return (1, windowOverride ?? "visible") }
        // AppModel.make 在 LabelGUIApp.init 里跑，那时应用对象可能还没建好：不碰它，当作还没有窗口
        guard let app = NSApp else { return (0, "no_window") }
        let mains = app.windows.filter { $0.canBecomeMain }
        let shown = mains.filter { $0.isVisible || $0.isMiniaturized }
        if app.isHidden { return (mains.count, "hidden") }
        if shown.isEmpty { return (0, "no_window") }
        if shown.allSatisfy({ $0.isMiniaturized }) { return (shown.count, "minimized") }
        if !shown.contains(where: { $0.occlusionState.contains(.visible) }) { return (shown.count, "occluded") }
        return (shown.count, "visible")
    }

    /// LiveHandlers 的订阅跟着桥活（attach 里先注册方法、再 observe，所以 observe 是往里加，不是换掉）。
    @MainActor
    func retain(_ subscription: AnyCancellable) {
        observers.append(subscription)
    }

    @MainActor
    private func observe(_ model: AppModel) {
        let batch = model.batch
        let changes: [AnyPublisher<Void, Never>] = [
            model.$tab.map { _ in () }.eraseToAnyPublisher(),
            batch.$photoDir.map { _ in () }.eraseToAnyPublisher(),
            batch.$items.map { _ in () }.eraseToAnyPublisher(),
            batch.$isRunning.map { _ in () }.eraseToAnyPublisher(),
            batch.$progressText.map { _ in () }.eraseToAnyPublisher(),
        ]
        // receive(on:) 不能省：@Published 在赋值之前就发，回调里直接读拿到的还是旧值。
        observers += changes.map { change in
            change.receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSnapshot() }
            }
        }
    }

    /// GUI：窗口状态变化时更新快照（只是观察，不做任何动作）。被挡住、换桌面都走遮挡通知；
    /// §9.5.6 里那个「当前桌面换了」的通知是工作区对象发的，Live/ 里整个禁用那个类，不用 —— 换桌面时窗口的遮挡状态
    /// 本来就会变，真窗口里是不是每次都发，留给验收第 9 条。另外每 0.5 s 的心跳也会顺手重算一次。
    @MainActor
    private func observeWindows() {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSWindow.didBecomeMainNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // willClose 的时候窗口还在列表里：下一轮再算
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.refreshSnapshot() }
                }
            }
            tokens.append(token)
        }
        let quit = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.shutdown()
        }
        tokens.append(quit)
    }

    /// 主线程 0.5 s 心跳：main_beat_ms 只作诊断（App Nap 下定时器会被合并，数会变大，但 app 没卡，§9.2.2）。
    @MainActor
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setLocked { self.snap.mainBeat = LiveWire.nowMs() }
                if !self.isTestHost { self.refreshSnapshot() }
            }
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - hello（连接线程上回）

    fileprivate func helloReply(_ params: [String: Any], peerUID: Int, peerPID: Int) -> (ok: Bool, body: [String: Any]) {
        let client = params["client"] as? [String: Any] ?? [:]
        let s: Snapshot = withState {
            snap.helloCount += 1
            snap.lastHelloMs = LiveWire.nowMs()
            // 只记报了 MCP 客户端名字的（标题栏「Claude Code 已连接」用它，STEP 3b）；测试脚本的裸连接不报，不盖掉它
            if let name = client["mcp_client"] as? String { snap.lastClient = name }
            return snap
        }
        var app: [String: Any] = ["name": "选片工具", "version": LiveBuildInfo.version, "build": LiveBuildInfo.build]
        app["uuid"] = LiveBuildInfo.uuid
        app["pid"] = Int(getpid())
        app["exe"] = LiveBuildInfo.exe
        var base: [String: Any] = ["proto_min": protoMin, "proto_max": protoMax, "app": app]
        base["data_dir"] = paths?.dataDir ?? ""
        base["data_dir_id"] = paths?.dataDirID ?? ""
        let proto = LiveWire.int(params["proto"]) ?? -1
        guard proto >= protoMin && proto <= protoMax else {
            let message = "选片工具的桥协议是 \(protoMin)–\(protoMax)，MCP 是 \(proto)"
            return (false, ["code": "proto_mismatch", "message": message, "data": base])
        }
        guard let id = params["data_dir_id"] as? String, id == paths?.dataDirID else {
            let message = "选片工具的数据目录是 \(paths?.dataDir ?? "?")（\(paths?.dataDirID ?? "?")），MCP 说的不是同一个"
            return (false, ["code": "data_dir_mismatch", "message": message, "data": base])
        }
        var body = base
        body["proto"] = proto
        body["exact_build_match"] = (client["uuid"] as? String) == LiveBuildInfo.uuid
        body["peer"] = ["uid": peerUID, "pid": peerPID]
        body["ready"] = s.ready
        body["bridge"] = "on"
        body["windows"] = s.windows
        body["window_state"] = s.windowState
        body["tab"] = s.tab
        body["open_session"] = s.openSession ?? NSNull()
        body["analysis"] = ["running": s.analysisRunning, "progress_text": s.progressText]
        body["main_beat_ms"] = Int(LiveWire.nowMs() - s.mainBeat)
        body["capabilities"] = capabilities()
        return (true, body)
    }

    /// 标题栏「Claude Code 已连接」（§9.6a）：只认 `--mcp` 的 hello（LiveClient.hello 报的 client.name）；另一个实例启动时的
    /// 探测（answersHello）、测试脚本直接连 socket 的都不算。连接线程上调，经主线程转给指示，hello 本身不等这一跳。
    fileprivate func noteHello(_ params: [String: Any]) {
        let client = params["client"] as? [String: Any] ?? [:]
        guard client["name"] as? String == "xuanpian-mcp" else { return }
        let name = client["mcp_client"] as? String
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model?.indicator.sawHello(client: name) }
        }
    }

    // MARK: - 给测试宿主看的（test.state）

    /// 计数、fd 的 CLOEXEC（F_GETFD 自报，live_smoke 另外从外面用 proc_pidfdinfo 核对）、桥、连接数、hello 次数。
    func debugState() -> [String: Any] {
        withState {
            var out: [String: Any] = ["bridge": bridge.word, "bridge_reason": bridge.reason ?? NSNull()]
            out["connections"] = connections
            out["hello_count"] = snap.helloCount
            out["counters"] = counters
            out["socket"] = paths?.socketPath ?? NSNull()
            out["lock_path"] = paths?.lockPath ?? NSNull()
            out["data_dir_id"] = paths?.dataDirID ?? NSNull()
            var fds: [String: Any] = [:]
            if let l = lock { fds["lock"] = ["fd": Int(l.fd), "cloexec": LiveFD.isCloexec(l.fd)] }
            if listenFd >= 0 { fds["listen"] = ["fd": Int(listenFd), "cloexec": LiveFD.isCloexec(listenFd)] }
            if wakeR >= 0 { fds["wake"] = ["fd": [Int(wakeR), Int(wakeW)], "cloexec": LiveFD.isCloexec(wakeR) && LiveFD.isCloexec(wakeW)] }
            out["fds"] = fds
            out["last_client"] = snap.lastClient ?? NSNull()
            return out
        }
    }

    /// 测试宿主 ready 行用：桥开没开、为什么。
    var bridgeState: Bridge { withState { bridge } }

    // MARK: - 锁着改 / 读

    private func withState<T>(_ body: () -> T) -> T {
        state.lock()
        defer { state.unlock() }
        return body()
    }

    private func setLocked(_ body: () -> Void) {
        state.lock()
        body()
        state.unlock()
    }

    private func bump(_ key: String) {
        setLocked { counters[key, default: 0] += 1 }
    }
}

/// 跨线程的一个旗子（连接的 clientGone）。`link` 挂上的取消旗子（CompareZoom.load 用的那种）跟着一起置上。
final class LiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var linked: [AnalysisEngine.CancelFlag] = []
    func set() {
        lock.lock()
        value = true
        let flags = linked
        linked = []
        lock.unlock()
        for f in flags { f.set() }
    }

    /// 已经置上就立刻置 `flag`；否则等这个旗子置上时一起置。
    func link(_ flag: AnalysisEngine.CancelFlag) {
        lock.lock()
        if value {
            lock.unlock()
            flag.set()
            return
        }
        linked.append(flag)
        lock.unlock()
    }
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 一个连接：读线程按行切、串行写队列。fd 只在「读线程结束而且没有在途请求」之后才关：
/// 不然 fd 号被复用，迟到的回复会写进别人的连接（R6 §3.5）。
final class LiveConnection: @unchecked Sendable {
    let id: Int
    let fd: Int32
    let peerUID: Int
    let peerPID: Int
    let gone = LiveFlag()
    private unowned let server: LiveServer
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var alive = true
    private var closed = false
    private var pending = 0
    private var readerDone = false

    init(id: Int, fd: Int32, peerUID: Int, peerPID: Int, server: LiveServer) {
        self.id = id
        self.fd = fd
        self.peerUID = peerUID
        self.peerPID = peerPID
        self.server = server
        writeQueue = DispatchQueue(label: "xuanpian.live.conn.\(id).write", autoreleaseFrequency: .workItem)
    }

    /// 还能往 fd 上写：没被判死，fd 也还没关（关了的 fd 号可能已经分给了别的连接）。
    private var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive && !closed
    }

    private func markDead() {
        lock.lock()
        alive = false
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
    }

    private func maybeClose() {
        lock.lock()
        let should = readerDone && pending == 0 && !closed
        if should { closed = true }
        lock.unlock()
        if should {
            close(fd)
            server.connectionClosed()
        }
    }

    func beginRequest() {
        lock.lock()
        pending += 1
        lock.unlock()
    }

    /// 在途计数在写队列上减：这时这个请求的回复（之前 send 排进同一个串行队列的）已经写完或丢掉了。
    /// 在调用方线程上减的话，读线程退出时排进去的 maybeClose 可能先跑，看到 pending == 0 就关了 fd，
    /// 回复接着写进关掉的 fd、甚至写进复用了这个 fd 号的别人的连接（审查实测：40 轮里 4 轮串到了别的客户端）。
    func endRequest() {
        writeQueue.async { [self] in
            lock.lock()
            pending -= 1
            lock.unlock()
            maybeClose()
        }
    }

    /// 编码和写都在这个连接自己的队列上（不在主线程）。写失败 = 客户端已经走了：丢掉这条回复、关连接；
    /// 写操作本身已经生效，靠 op_id 对齐（§9.2.3）。
    func send(_ frame: [String: Any], thenClose: Bool = false, done: (() -> Void)? = nil) {
        let box = LiveBox(frame)
        writeQueue.async { [self] in
            defer { done?() }
            guard isAlive else { return }
            let data = LiveWire.encode(box.value)
            if !LiveFD.sendAll(fd, data, noSignal: server.layers.noSignal) {
                LiveServer.log("conn \(id)：write failed（\(LiveWire.errnoText())）—— 客户端走了，丢掉这条回复")
                markDead()
            } else if thenClose {
                markDead()
            }
        }
    }

    func run() {
        let reader = LiveLineReader(fd: fd, maxLine: LiveWire.maxRequestLine)
        var helloDone = false
        loop: while isAlive {
            let timeout = helloDone ? server.idleTimeoutMs : server.helloTimeoutMs
            switch reader.next(timeoutMs: timeout) {
            case .eof:
                gone.set()
                break loop
            case .error:
                gone.set()
                break loop
            case .timeout:
                LiveServer.log("conn \(id)：\(helloDone ? "空闲" : "hello") 超时，关掉")
                break loop
            case .tooLong:
                let e: [String: Any] = ["code": "request_too_large", "message": "请求一行超过 \(LiveWire.maxRequestLine) 字节"]
                send(["id": NSNull(), "error": e], thenClose: true)
                break loop
            case .line(let line):
                guard let req = LiveWire.decode(line) else {
                    // 坏 JSON 只回 parse_error，连接继续可用（R6 T13）
                    send(["id": NSNull(), "error": ["code": "parse_error", "message": "不是 JSON 对象"]])
                    continue
                }
                let rid = req["id"] ?? NSNull()
                let method = req["method"] as? String ?? ""
                let params = req["params"] as? [String: Any] ?? [:]
                if method == "hello" {
                    let r = server.helloReply(params, peerUID: peerUID, peerPID: peerPID)
                    if r.ok {
                        helloDone = true
                        send(["id": rid, "result": r.body])
                        server.noteHello(params)
                    } else {
                        send(["id": rid, "error": r.body], thenClose: true)
                        break loop
                    }
                    continue
                }
                guard helloDone else {
                    send(["id": rid, "error": ["code": "hello_required", "message": "第一条必须是 hello"]], thenClose: true)
                    break loop
                }
                if method == "ping" {
                    send(["id": rid, "result": ["pong": true]])  // 不经主线程
                    continue
                }
                let deadline = min(max(LiveWire.int(req["deadline_ms"]) ?? 10_000, 1), 600_000)
                switch server.lookup(method) {
                case .unknown:
                    send(["id": rid, "error": ["code": "unknown_method", "message": "没有这个方法：\(method)"]])
                case .direct(let run):
                    send(run(params).frame(id: rid))
                case .main(let m):
                    server.dispatch(m, name: method, id: rid, params: params, deadlineMs: deadline,
                                    opID: req["op_id"] as? String, conn: self)
                }
            }
        }
        lock.lock()
        readerDone = true
        lock.unlock()
        // 读线程退出不等于连接作废：在途请求照样在主线程上执行完（写已经生效），回复写不出去就丢掉。
        writeQueue.async { [self] in maybeClose() }
    }
}
