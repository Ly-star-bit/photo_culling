import SwiftUI

/// 窗口标题栏副标题上的 AI 指示（DESIGN §9.6a），和 app 菜单里「允许 AI 实时操作（MCP）」那一项的勾。
/// 显示什么（从上往下，先对上的那一条）：
///
/// | 状态 | 副标题 |
/// |---|---|
/// | 菜单里关了 | 不显示（那一项没打勾就是状态；关着的时候 socket 不在，app 也不知道有没有人来连过） |
/// | 本实例没拿到锁，另一个选片工具占着这个数据目录 | 「另一个选片工具正在用这个数据目录：AI 只连那一个」 |
/// | 锁被别的程序拿走了（§9.2.4 自检，桥已经关了） | 「数据目录的锁被别的程序拿走了：AI 实时操作已停，重开 app 恢复」（一直留着） |
/// | 开桥 / 重新 bind 失败（§9.2.4「任何一步失败：不开桥，标题栏提示」），锁文件重新 open 不了（数据目录被挪走……） | 「AI 实时操作的连接开不起来（原因）：已暂停，每 10 秒自动再试」，开好了就消失 |
/// | 有在途的写（§9.4.3 第 8 步：等过用户停手、核对过以后才算；成套 / 换封面从等路人信息起算） | 「AI 正在操作：套模板…」（短词见 LiveHandlers.workingLabel） |
/// | 刚做完（10 s） | 和受影响那一页的提示同一句话（「AI：套了模板「…」· 在拼图页 ⌘Z 撤销」），四个 tab 都看得到 |
/// | 120 s 内有过 MCP 的 hello | 「Claude Code 已连接」（名字取自 hello 的 mcp_client；不认识就写「AI 已连接」） |
/// | 其他 | 不显示：不用 AI 的人看不到任何变化 |
///
/// 每次 MCP 调用都是新连接（R6），所以「已连接」的意思是「最近 120 s 内来过」，到点自己淡掉。
/// 只认 `--mcp` 的 hello（client.name = xuanpian-mcp）：另一个实例启动时的探测、测试脚本直接连 socket 的都不算。
/// 这里只改文字，不激活 app、不碰任何窗口、不弹任何东西；读请求不改它（第 8 步只在写的流水线里）。
/// 桥停了的那两条由 LiveServer 从自检队列 / 开桥那里转到主线程来设（setBridgeProblem），文字在 LiveBridgeNotice。
@MainActor
final class LiveIndicator: ObservableObject {
    enum State: Equatable {
        case none
        case anotherInstance
        case lockLost
        case bridgeFailed(String)
        case working(String)
        case justDid(String)
        case connected(String)
    }

    /// 副标题此刻的文字（"" = 不显示）。只在变了的时候发，ContentView 的副标题不跟着空转。
    @Published private(set) var text = ""
    /// 菜单那一项的勾。GUI 启动时取 UserDefaults 的 live.bridgeEnabled（没有这个键 = 开），之后跟着菜单；
    /// 测试宿主只在内存里（test.set_bridge），从不读写 UserDefaults。
    @Published private(set) var bridgeEnabled = true
    private(set) var state = State.none

    /// 「已连接」留多久、「刚做完」留多久（测试宿主可以用 LABELGUI_LIVE_TEST_CONNECTED_MS / _JUSTDID_MS 缩短）。
    private(set) var connectedMs = 120_000.0
    private(set) var justDidMs = 10_000.0

    private var anotherInstance = false
    private var problem: LiveBridgeProblem?
    private var lastHello: (ms: Double, name: String)?
    private var working: String?
    private var justDid: (text: String, until: Double)?
    private var timer: Task<Void, Never>?

    func configure(connectedMs: Double?, justDidMs: Double?) {
        if let connectedMs { self.connectedMs = connectedMs }
        if let justDidMs { self.justDidMs = justDidMs }
        refresh()
    }

    /// `--mcp` 的 hello（连接线程经主线程转过来）。`client` 是 hello 里的 mcp_client（「claude-code 2.1.3」这样），
    /// `--mcp-call` 没有 initialize，就没有它。
    func sawHello(client: String?) {
        guard bridgeEnabled else { return }
        lastHello = (LiveWire.nowMs(), Self.displayName(client))
        refresh()
    }

    /// 第 8 步：等过用户停手、第 6a 步核对过，马上要执行了。
    func began(_ title: String) {
        working = title
        justDid = nil
        refresh()
    }

    /// 写做完了（不管成没成）。`notice` 是受影响那一页的那句提示（结果里的 live.notice）；没改出东西、出错时是 nil。
    /// 菜单里关着的时候做完的（关之前就开始了的那一个）不留：再打开时不说关着的时候的事。
    func finished(notice: String?) {
        guard working != nil else { return }
        working = nil
        if let notice, bridgeEnabled { justDid = (notice, LiveWire.nowMs() + justDidMs) }
        refresh()
    }

    /// 菜单开关（GUI）/ test.set_bridge（宿主）/ 启动时按设置。关掉的时候把「来过谁、刚做了什么」忘掉：
    /// 再打开时不拿关之前的 hello 说「已连接」。
    func setBridgeEnabled(_ on: Bool) {
        if bridgeEnabled != on { bridgeEnabled = on }
        if !on {
            lastHello = nil
            justDid = nil
        }
        refresh()
    }

    /// 启动时没拿到锁，而且锁的主人回了 hello（另一个选片工具实例，LiveServer.acquireAtStartup）。
    func setAnotherInstance(_ on: Bool) {
        anotherInstance = on
        refresh()
    }

    /// 桥停了（LiveServer.indicatorProblem 从桥的状态算出来，经主线程转过来）：锁丢了一直留着（重开 app 才恢复）；
    /// 开桥失败的那条在桥开好时清掉（nil）。「来过谁、刚做了什么」不忘：桥重新开好以后「已连接」照常接着显示。
    func setBridgeProblem(_ p: LiveBridgeProblem?) {
        guard problem != p else { return }
        problem = p
        refresh()
    }

    /// mcp_client 的第一个词是 MCP 客户端在 initialize 里报的名字；认识的写成产品名，别的一律「AI」（不把原样的名字
    /// 放到用户的标题栏上）。
    static func displayName(_ client: String?) -> String {
        let id = client?.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let known: [String: String] = ["claude-code": "Claude Code", "claude-ai": "Claude"]
        return known[id] ?? "AI"
    }

    static func text(_ state: State) -> String {
        switch state {
        case .none: return ""
        case .anotherInstance: return "另一个选片工具正在用这个数据目录：AI 只连那一个"
        case .lockLost: return LiveBridgeNotice.lockLost
        case .bridgeFailed(let notice): return notice
        case .working(let title): return "AI 正在操作：\(title)…"
        case .justDid(let notice): return notice
        case .connected(let name): return "\(name) 已连接"
        }
    }

    /// 给 test.state 看的名字。
    var stateName: String {
        switch state {
        case .none: return "none"
        case .anotherInstance: return "another_instance"
        case .lockLost: return "lock_lost"
        case .bridgeFailed: return "bridge_failed"
        case .working: return "working"
        case .justDid: return "just_did"
        case .connected: return "connected"
        }
    }

    private func refresh() {
        let now = LiveWire.nowMs()
        if let j = justDid, j.until <= now { justDid = nil }
        if let h = lastHello, h.ms + connectedMs <= now { lastHello = nil }
        let next: State
        if !bridgeEnabled {
            next = .none
        } else if anotherInstance {
            next = .anotherInstance
        } else if problem == .lockLost {
            next = .lockLost
        } else if case .failed(let notice) = problem {
            next = .bridgeFailed(notice)
        } else if let w = working {
            next = .working(w)
        } else if let j = justDid {
            next = .justDid(j.text)
        } else if let h = lastHello {
            next = .connected(h.name)
        } else {
            next = .none
        }
        state = next
        let t = Self.text(next)
        if text != t { text = t }
        schedule(now)
    }

    /// 到下一个点（「刚做完」或「已连接」到期）再算一次。
    private func schedule(_ now: Double) {
        timer?.cancel()
        timer = nil
        let ends: [Double] = [justDid?.until, lastHello.map { $0.ms + connectedMs }].compactMap { $0 }
        guard let end = ends.min() else { return }
        // 最多睡 1 小时再看一次（时长是外面给的，换成纳秒之前先夹住，免得 UInt64 溢出）
        let ms: Double = min(max(0, end - now), 3_600_000)
        let ns = UInt64(ms * 1_000_000) + 5_000_000
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}

/// 桥停了的两种（§9.2.4）：锁被别的程序拿走（一直停着，重开 app 恢复）；开桥 / 重新 bind 失败（带标题栏那一句，
/// 自检接着试的那几种开好了就清掉）。由 LiveServer.indicatorProblem 从桥的状态算出来。
enum LiveBridgeProblem: Equatable, Sendable {
    case lockLost
    case failed(String)
}

/// 桥停了时标题栏上的那一句（§9.2.4）。`--mcp` 给模型的说明（LiveClient.explain）引用同一份字：模型转述给用户的，
/// 和用户在标题栏上看到的是同一句话。
enum LiveBridgeNotice {
    /// §9.2.4 原话。
    static let lockLost = "数据目录的锁被别的程序拿走了：AI 实时操作已停，重开 app 恢复"

    /// app 菜单里那一项的名字（和下面 LiveBridgeToggle 里 Toggle 的字面量一字不差）：菜单关了时回给模型的两处
    /// （app 在已经连上的连接上回的 bridge_off、`--mcp` 从锁文件那一行判出来的 bridge_off）都引用它，用户在菜单里找得到。
    static let menuTitle = "允许 AI 实时操作（MCP）"

    /// 开不了桥的原因 → 标题栏那一句；nil = 这个原因不在标题栏说（另一个实例有自己的那一句；等锁、启动中是一时的；
    /// 锁丢了是上面那句）。原因的代号不上标题栏，换成一句短话；自检接着试的（LiveServer.retryable）说会自己再试。
    static func failed(_ reason: String) -> String? {
        let causes: [String: String] = [
            "sock_dir_unsafe": "放连接的临时目录权限不对", "socket_path_occupied": "连接文件的位置被别的文件占着",
            "bind_failed": "连接建不起来", "socket_path_too_long": "连接文件的路径太长",
            "lock_failed": "数据目录的锁文件打不开", "data_dir": "数据目录解析不了", "no_temp_dir": "拿不到本机的临时目录",
            "lock_reopen_failed": "数据目录的锁文件不见了或打不开",
        ]
        guard let cause = causes[reason] else { return nil }
        if LiveServer.retryable.contains(reason) {
            return "AI 实时操作的连接开不起来（\(cause)）：已暂停，每 10 秒自动再试"
        }
        return "AI 实时操作的连接开不起来（\(cause)）：已停，重开 app 再试"
    }

    /// app 拿着锁时会写进锁文件那一行的原因。`--mcp` 只对这些按标题栏那一句说：data_dir、no_temp_dir、lock_failed 时 app
    /// 没拿到锁、写不了那一行，`--mcp` 自己算出来的 no_temp_dir 说的是它自己，不是 app 的标题栏。
    static let onLockLine: Set<String> = LiveServer.retryable.union(["lock_lost", "socket_path_too_long"])

    /// 桥停着时给模型的说明（app 在已经连上的连接上回的错误、`--mcp` 从锁文件那一行看到的 unreachable 都用它）：
    /// message 说是什么，hint 带上标题栏上的那一句和怎么恢复（模型转述给用户时，和用户眼前看到的对得上）。
    /// nil = 这个原因没有专门的说法。
    static func explain(_ reason: String) -> (message: String, hint: String)? {
        if reason == "lock_lost" {
            return ("选片工具的 AI 实时操作已停：数据目录的锁被别的程序拿走了，app 关了实时桥。",
                    "选片工具标题栏上写着「\(lockLost)」：请用户退出并重新打开选片工具；MCP 不会替用户重开")
        }
        guard let notice = failed(reason) else { return nil }
        let message = "选片工具开着，但实时桥开不起来（\(reason)）。"
        if LiveServer.retryable.contains(reason) {
            return (message, "选片工具标题栏上写着「\(notice)」：过一会儿再调；一直这样就请用户重开选片工具")
        }
        return (message, "选片工具标题栏上写着「\(notice)」：请用户重开选片工具")
    }
}

/// ContentView 根上的副标题（§9.6a：四个 tab 都在、不压任何内容）。单独一个 modifier 观察指示：
/// 指示变了只重算这一层，不让整个 ContentView 跟着重算。不连 AI 时文字是空的，窗口和以前一模一样。
struct LiveIndicatorSubtitle: ViewModifier {
    @ObservedObject var indicator: LiveIndicator

    func body(content: Content) -> some View {
        content.navigationSubtitle(indicator.text)
    }
}

/// app 菜单（「选片工具」菜单）里那一项带勾的开关（§9.6a）。`set` 由 main.swift 给：GUI 在那里写 UserDefaults，
/// 再走和 test.set_bridge 同一条 AppModel.setLiveBridge。
struct LiveBridgeToggle: View {
    @ObservedObject var indicator: LiveIndicator
    let set: (Bool) -> Void

    var body: some View {
        Toggle("允许 AI 实时操作（MCP）", isOn: Binding(get: { indicator.bridgeEnabled }, set: set))
    }
}
