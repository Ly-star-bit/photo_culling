import Foundation

/// `app_status`（title：状态自检，DESIGN §3.1，按 §10.1 第 1 行改）：进程内，不读照片，在任何状态下都正常返回。
/// live 对象取自 hello（LiveClient.probe，不经 app 主线程：app 卡住时照样秒回）；不是 live 时 warnings 写原因和 hint。
/// gui_running 按锁判断：锁被 role=app 的进程占着，或者 hello 成功（开发版裸二进制开的 GUI 也认得出来）；
/// 旧版 app（old_app）是 NSRunningApplication 认出来的，只在默认数据目录时看（§9.1）；设了 LABELGUI_DATA_DIR 时它只用来
/// 加 §6.3 那一句 warning（gui_running、live.state 都不改）。
enum MCPStatus {
    static let writesReason = "v1 只有实时：app 开着时读和改都交给 app；app 没开时只能看状态、列场次和模板"

    static func appStatus(_ call: MCPStdioServer.Call) -> MCPStdioServer.ToolResult {
        if let extra = call.arguments.keys.sorted().first {
            return .error("invalid_argument", "app_status 不收参数（收到了 \(extra)）。", hint: "参数传 {}")
        }
        let dir = MCPPaths.dataDirState()
        let index = MCPPaths.readSessionsIndex()
        // 先探测：data_dir_unreadable 那一句要看锁到底看没看到（warnings 的顺序不变）
        let probe = LiveClient.probe(client: call.client)
        var warnings: [[String: Any]] = []

        var server: [String: Any] = ["name": "xuanpian", "version": MCPConfig.version, "build": MCPConfig.build]
        server["protocol"] = call.client?.answered ?? NSNull()
        server["binary"] = Bundle.main.executablePath ?? CommandLine.arguments[0]

        var out: [String: Any] = ["server": server]
        out["data_dir"] = MCPPaths.dataDir.path
        out["data_dir_override"] = MCPPaths.dataDirOverridden
        out["data_dir_exists"] = dir.exists
        out["data_dir_readable"] = dir.readable
        out["sessions"] = index.entries.count

        if !dir.exists {
            warnings.append(warning("data_dir_missing",
                                    "数据目录不存在：这台机器上还没打开过选片工具（或者 LABELGUI_DATA_DIR 指错了）。",
                                    hint: "请用户自己打开选片工具、分析一场；MCP 不会建这个目录。"))
        } else if !dir.readable {
            warnings.append(dataDirUnreadableWarning(lockUnseen: LiveClient.lockUnseen(probe), sessionsDenied: index.denied))
        }
        if let problem = index.problem {
            warnings.append(warning("sessions_index_unreadable", problem, hint: "请用户在选片工具里打开一次任意场次，app 会重写这个文件"))
        }

        let state = probe.state.rawValue
        out["live"] = liveObject(probe)
        out["gui_running"] = guiRunning(probe)
        warnings.append(contentsOf: probe.warnings)
        switch probe.state {
        case .live:
            if probe.hello?["exact_build_match"] as? Bool == false { warnings.append(buildMismatchWarning(probe.hello)) }
            if probe.openSession == nil {
                warnings.append(warning("no_open_session", "选片工具开着，但没有打开任何场次。",
                                        hint: "cull_list_sessions 找到要处理的那一场，再 app_open_session（或者请用户在 app 里打开）"))
            }
        case .disabled:
            warnings.append(warning("live_disabled", "这个服务器设了 LABELGUI_MCP_LIVE=0：不连正在运行的 app。",
                                    hint: "只能看状态、列场次和模板；要实时操作，去掉这个环境变量再重连 MCP 服务器"))
        case .notRunning where probe.reason == "data_dir_missing":
            break  // 上面已经有 data_dir_missing
        case .unreachable where LiveClient.lockUnseen(probe) && !dir.readable:
            break  // 上面已经有 data_dir_unreadable（说了看不出开没开）
        default:
            let (message, hint) = LiveClient.explain(probe)
            warnings.append(warning(probe.state == .notRunning ? "app_not_running" : probe.state.rawValue, message, hint: hint))
        }
        let env = ProcessInfo.processInfo.environment
        if let w = dataDirOverrideWarning(envDataDir: env["LABELGUI_DATA_DIR"], state: probe.state,
                                          appRunning: appRunningForOverrideCheck(env)) {
            warnings.append(w)
        }

        out["output_root"] = MCPPaths.outputRoot.path
        // 预览缓存（§10.3）：只数带标记的输出目录里服务器起名的文件；目录不在就是 0，不建
        out["preview_cache_bytes"] = MCPOutput.cacheBytes()
        var limits: [String: Any] = ["deadline_sec": MCPConfig.deadlineCap, "inline_kb": MCPConfig.inlineKB]
        limits["max_edge"] = MCPConfig.maxEdge
        limits["text_max_chars"] = MCPJSON.textMax
        out["limits"] = limits
        out["writes"] = ["live": probe.state == .live, "headless": false, "reason": writesReason] as [String: Any]
        if let client = call.client {
            out["client"] = ["name": client.name, "version": client.version, "requested_protocol": client.requested]
        } else {
            out["client"] = NSNull()
        }
        out["warnings"] = warnings
        // next 跟着 live.state 走（§10.1）：live → cull_session_overview（STEP 2 起才会有）；disabled（LABELGUI_MCP_LIVE=0）
        // 时开 app 也没用，指向这时能用的 cull_list_sessions；宿主的沙箱挡着（LiveClient.isSandboxDenied）时开 app 也没用
        // （app 可能本来就开着），指向放行 —— 这两条有意偏离 §10.1 字面上的「否则」；其余让用户自己开 app。
        let next: String
        switch state {
        case "live": next = "cull_session_overview"
        case "disabled": next = "cull_list_sessions"
        default: next = LiveClient.isSandboxDenied(probe) ? sandboxNext : "请用户自己打开选片工具"
        }
        out["next"] = next
        return .json(out)
    }

    static func warning(_ code: String, _ message: String, hint: String) -> [String: Any] {
        ["code": code, "message": message, "hint": hint]
    }

    /// 数据目录读不了时的 hint（app_status、cull_list_sessions 的 data_dir_unreadable，要 app 的工具的 app_unreachable）。
    /// 多半是宿主的沙箱不让读 ~/Library/Application Support（Antigravity 文档说它的终端沙箱这样做，§8）；socket 在本用户的
    /// 临时目录里，也要放行。不再建议用 LABELGUI_DATA_DIR 指到副本：v1 只做实时，副本上连不了 app（§6.3）。
    static let sandboxHint = "请用户在宿主（AI 客户端）的沙箱设置里放行数据目录和本用户临时目录里的 xuanpian-live；选片工具其实开着的话，放行以后就能实时操作"

    /// 宿主的沙箱挡着时 app_status 的 next。
    static let sandboxNext = "请用户在宿主（AI 客户端）里放行数据目录和 xuanpian-live（见 warnings）"

    /// 数据目录 access 不过（data_dir_unreadable）。后半句只说真的发生了的：`lockUnseen` 锁文件也没看到（看不出 app 开没开，
    /// 探测是 unreachable，LiveClient.lockUnseen）；`sessionsDenied` sessions.json 也读不了。目录只有 x 没有 r 时两样都还看得到，
    /// 只剩前半句 —— 不能和同一份 warnings 里的「选片工具没开」、列出来的场次打架。
    static func dataDirUnreadableWarning(lockUnseen: Bool, sessionsDenied: Bool) -> [String: Any] {
        let what = (lockUnseen ? ["看不出选片工具开没开"] : []) + (sessionsDenied ? ["列不出场次"] : [])
        let tail = what.isEmpty ? "。" : "：" + what.joined(separator: "，也") + "。"
        return warning("data_dir_unreadable", "读不了数据目录（多半是宿主的沙箱不让读）" + tail, hint: sandboxHint)
    }

    /// §6.3：MCP 配置的 env 里设了 LABELGUI_DATA_DIR（多半照抄了「从源码构建」里的调试写法），socket 和锁都是那个目录的，
    /// 探出来是 not_running，选片工具却开着：状态不改（还是 not_running），warnings 加这一句。
    /// `appRunning` 只在前两个条件都成立时才求值。纯函数，--mcp-selftest 逐行测。
    static func dataDirOverrideWarning(envDataDir: String?, state: LiveState, appRunning: @autoclosure () -> Bool) -> [String: Any]? {
        guard let envDataDir, !envDataDir.isEmpty, state == .notRunning, appRunning() else { return nil }
        return warning("data_dir_override",
                       "选片工具开着，但 MCP 用的数据目录是 LABELGUI_DATA_DIR=\(envDataDir)，不是 app 的那个：去掉这个环境变量才能实时操作。",
                       hint: "请用户从 MCP 配置的 env 里删掉 LABELGUI_DATA_DIR，再在客户端里重连 MCP 服务器（Claude Code 用 /mcp）")
    }

    /// 上面那条的「选片工具开着」：NSRunningApplication 看得到本 bundle（§6.3；和 old_app 同一个查法，只读进程表，
    /// 不碰默认数据目录）。认不出开发版的裸二进制开的 GUI —— 那种情况本来就是开发者自己设的 LABELGUI_DATA_DIR。
    /// 测试用 LABELGUI_MCP_TEST_GUI_RUNNING=0 / 1 钉住（只有设了 LABELGUI_DATA_DIR 才会走到这里）：冒烟脚本的结果
    /// 不能跟着用户的真 app 开没开变，也不去查用户的进程表。
    static func appRunningForOverrideCheck(_ env: [String: String]) -> Bool {
        switch env["LABELGUI_MCP_TEST_GUI_RUNNING"] {
        case "0": return false
        case "1": return true
        default: return LiveClient.oldAppRunning()
        }
    }

    /// live 对象（§3.1）：live 时字段全部取自 hello；not_running 时只有 state；其余状态带 socket 和锁文件那一行里说的谁。
    static func liveObject(_ p: LiveClient.Probe) -> [String: Any] {
        var live: [String: Any] = ["state": p.state.rawValue]
        switch p.state {
        case .live:
            guard let h = p.hello else { return live }
            live["bridge"] = h["bridge"] ?? "on"
            if let app = h["app"] as? [String: Any] {
                var a: [String: Any] = ["version": app["version"] ?? NSNull(), "build": app["build"] ?? NSNull()]
                a["pid"] = app["pid"] ?? NSNull()
                a["uuid"] = app["uuid"] ?? NSNull()
                live["app"] = a
            }
            live["exact_build_match"] = h["exact_build_match"] ?? false
            live["proto"] = h["proto"] ?? NSNull()
            if let open = p.openSession {
                var o: [String: Any] = ["session": open["session"] ?? NSNull(), "folder": open["folder"] ?? NSNull()]
                o["name"] = open["name"] ?? NSNull()
                o["photo_count"] = open["photo_count"] ?? NSNull()
                live["open_session"] = o
            } else {
                live["open_session"] = NSNull()
            }
            live["tab"] = h["tab"] ?? NSNull()
            live["windows"] = h["windows"] ?? 0
            live["window_state"] = h["window_state"] ?? NSNull()
            if let a = h["analysis"] as? [String: Any] {
                live["analysis"] = ["running": a["running"] ?? false, "progress_text": a["progress_text"] ?? ""]
            }
            live["capabilities"] = p.capabilities
            live["main_beat_ms"] = h["main_beat_ms"] ?? NSNull()
            live["socket"] = p.paths?.socketPath ?? NSNull()
        case .notRunning, .disabled:
            break
        default:
            if let r = p.reason { live["reason"] = r }
            if let s = p.paths?.socketPath { live["socket"] = s }
            if let l = p.lock {
                var lock: [String: Any] = ["role": l.role ?? NSNull(), "bridge": l.bridge ?? NSNull()]
                lock["pid"] = l.pid ?? NSNull()
                live["lock"] = lock
            }
        }
        return live
    }

    /// 锁被 role=app 的进程占着、hello 成功过、或者认出了旧版 app，就算 GUI 开着。
    /// LABELGUI_MCP_LIVE=0（disabled）不碰锁：退回 NSRunningApplication（只认 .app，§9.1 表外那一段），
    /// 而且和 old_app 一样只在默认数据目录时看 —— 设了 LABELGUI_DATA_DIR 时，认出来的 app 多半用的是别的数据目录。
    static func guiRunning(_ p: LiveClient.Probe) -> Bool {
        switch p.state {
        case .live, .unresponsive, .protoMismatch, .oldApp, .notReady, .dataDirMismatch, .bridgeOff:
            return true
        case .unreachable:
            return p.lock?.role == "app"
        case .disabled:
            return !MCPPaths.dataDirOverridden && LiveClient.oldAppRunning()
        case .notRunning, .headlessWriter, .peerRejected:
            return false
        }
    }

    /// exact_build_match:false 但协议兼容：照常工作，提醒一句（§9.2.5）。
    static func buildMismatchWarning(_ hello: [String: Any]?) -> [String: Any] {
        let app: [String: Any] = hello?["app"] as? [String: Any] ?? [:]
        let version: String = app["version"] as? String ?? "?"
        let build: String = app["build"] as? String ?? "?"
        let message = "app 是 \(version) (\(build))，MCP 是 \(MCPConfig.version) (\(MCPConfig.build))：不是同一次构建。"
        return warning("build_mismatch", message, hint: "照常能用；建议请用户重开选片工具、在客户端里重连 MCP 服务器")
    }
}
