import Foundation

/// `app_status`（title：状态自检，DESIGN §3.1，按 §10.1 第 1 行改）：进程内，不读照片，在任何状态下都正常返回。
/// S1：live.state 固定报 not_running（LABELGUI_MCP_LIVE=0 时 disabled），不探测、不碰锁和 socket；
/// STEP 2 接上 LiveClient.probe() 以后，live 对象取自 hello，gui_running 按锁判断。
enum MCPStatus {
    static let writesReason = "v1 只有实时：app 开着时读和改都交给 app；app 没开时只能看状态、列场次和模板"

    static func appStatus(_ call: MCPStdioServer.Call) -> MCPStdioServer.ToolResult {
        if let extra = call.arguments.keys.sorted().first {
            return .error("invalid_argument", "app_status 不收参数（收到了 \(extra)）。", hint: "参数传 {}")
        }
        let live = MCPConfig.liveEnabled
        let dir = MCPPaths.dataDirState()
        let index = MCPPaths.readSessionsIndex()
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
        out["gui_running"] = false

        if !dir.exists {
            warnings.append(warning("data_dir_missing",
                                    "数据目录不存在：这台机器上还没打开过选片工具（或者 LABELGUI_DATA_DIR 指错了）。",
                                    hint: "请用户自己打开选片工具、分析一场；MCP 不会建这个目录。"))
        } else if !dir.readable {
            // 多半是宿主的沙箱不让读 ~/Library/Application Support（Antigravity 文档说它的终端沙箱这样做，§8）。
            warnings.append(warning("data_dir_unreadable", "读不了数据目录。",
                                    hint: "在宿主里放行这个目录，或者用 LABELGUI_DATA_DIR 指到能读的副本"))
        }
        if let problem = index.problem {
            warnings.append(warning("sessions_index_unreadable", problem, hint: "请用户在选片工具里打开一次任意场次，app 会重写这个文件"))
        }

        let state = live ? "not_running" : "disabled"
        out["live"] = ["state": state]
        if live {
            warnings.append(warning("app_not_running", "选片工具没开。",
                                    hint: "请用户自己打开选片工具，并在 app 里打开要处理的场次；MCP 不会启动它。"))
        } else {
            warnings.append(warning("live_disabled", "这个服务器设了 LABELGUI_MCP_LIVE=0：不连正在运行的 app。",
                                    hint: "只能看状态、列场次和模板；要实时操作，去掉这个环境变量再重连 MCP 服务器"))
        }

        out["output_root"] = MCPPaths.outputRoot.path
        out["preview_cache_bytes"] = 0  // STEP 3a 由输出目录（MCPOutput）统计；S1 还没有写预览的路径
        var limits: [String: Any] = ["deadline_sec": MCPConfig.deadlineCap, "inline_kb": MCPConfig.inlineKB]
        limits["max_edge"] = MCPConfig.maxEdge
        limits["text_max_chars"] = MCPJSON.textMax
        out["limits"] = limits
        out["writes"] = ["live": false, "headless": false, "reason": writesReason] as [String: Any]
        if let client = call.client {
            out["client"] = ["name": client.name, "version": client.version, "requested_protocol": client.requested]
        } else {
            out["client"] = NSNull()
        }
        out["warnings"] = warnings
        // next 跟着 live.state 走（§10.1）：live → cull_session_overview（STEP 2 起才会有）；disabled（LABELGUI_MCP_LIVE=0）
        // 时开 app 也没用，指向这时能用的 cull_list_sessions —— 有意偏离 §10.1 字面上的「否则」；其余让用户自己开 app。
        let next: String
        switch state {
        case "live": next = "cull_session_overview"
        case "disabled": next = "cull_list_sessions"
        default: next = "请用户自己打开选片工具"
        }
        out["next"] = next
        return .json(out)
    }

    static func warning(_ code: String, _ message: String, hint: String) -> [String: Any] {
        ["code": code, "message": message, "hint": hint]
    }
}
