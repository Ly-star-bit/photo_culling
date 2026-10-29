import Foundation

/// 要 app 的 15 个工具怎么路由（DESIGN §10.2，取代 §9.1 的三列表）：每次调用探一次（LiveClient.probe，不缓存），
/// 只在 `live`、方法在 hello 的 capabilities 里、场次对得上时转给 app；其余情况一律回那个状态的错误码。服务器绝不启动 app。
/// STEP 2 只接上了 collage_get_state → collage.state（先给工程摘要，预览在 STEP 3a）；app 这一步也只注册了它，
/// 所以其余 14 个在 live 时回 app_version_mismatch（app_too_old），这正是 §10.2「方法不在 capabilities 里」那一行。
/// 参数校验、结果加工在 STEP 3a / 3b 补进这里。
enum MCPLiveTools {
    enum SessionRule {
        /// 必填，必须是 app 当前打开的那一场（读工具、改判、定位、5 个拼图写工具）。
        case required
        /// 可选：给了就核对，不给就用 app 当前的（collage_get_state、app_undo）。
        case optional
        /// 不核对：要打开的就是别的场次（app_open_session）。
        case target
    }

    struct Route {
        let method: String
        let write: Bool
        let session: SessionRule
        /// 默认截止时间（§10.2：读 10 s、cull_preview_photos 30 s、成套 / 换封面 50 s、其他写 10 s）。
        let deadlineMs: Int
    }

    static let routes: [String: Route] = [
        "cull_session_overview": Route(method: "cull.read", write: false, session: .required, deadlineMs: 10_000),
        "cull_list_photos": Route(method: "cull.read", write: false, session: .required, deadlineMs: 10_000),
        "cull_get_photos": Route(method: "cull.read", write: false, session: .required, deadlineMs: 10_000),
        "cull_list_groups": Route(method: "cull.read", write: false, session: .required, deadlineMs: 10_000),
        "cull_preview_photos": Route(method: "cull.preview", write: false, session: .required, deadlineMs: 30_000),
        "collage_get_state": Route(method: "collage.state", write: false, session: .optional, deadlineMs: 10_000),
        "app_open_session": Route(method: "session.open", write: true, session: .target, deadlineMs: 10_000),
        "cull_set_verdicts": Route(method: "cull.set_verdicts", write: true, session: .required, deadlineMs: 10_000),
        "cull_show_photos": Route(method: "cull.show", write: true, session: .required, deadlineMs: 10_000),
        "collage_apply_template": Route(method: "collage.apply_template", write: true, session: .required, deadlineMs: 10_000),
        "collage_run_kit": Route(method: "collage.run_kit", write: true, session: .required, deadlineMs: 50_000),
        "collage_next_cover": Route(method: "collage.next_cover", write: true, session: .required, deadlineMs: 50_000),
        "collage_set_text": Route(method: "collage.set_text", write: true, session: .required, deadlineMs: 10_000),
        "collage_set_style": Route(method: "collage.set_style", write: true, session: .required, deadlineMs: 10_000),
        "app_undo": Route(method: "undo", write: true, session: .optional, deadlineMs: 10_000),
    ]

    /// 这一步真的会转发的桥方法；其余的在 STEP 3a / 3b 接上（app 这一步也不会在 capabilities 里报它们）。
    static let wired: Set<String> = ["collage.state"]

    static func handler(_ name: String) -> ((MCPStdioServer.Call) -> MCPStdioServer.ToolResult)? {
        guard let route = routes[name] else { return nil }
        return { call in run(name, route, call) }
    }

    static func run(_ name: String, _ route: Route, _ call: MCPStdioServer.Call) -> MCPStdioServer.ToolResult {
        var probe = LiveClient.probe(client: call.client, keep: true)
        if probe.state == .headlessWriter {
            // §10.2：等 2 s 重探一次；变成 live 就转，变成 not_running 就 app_not_running，还是这样就 busy
            probe.closeConnection()
            let until = Date().addingTimeInterval(2)
            while Date() < until && !call.cancel.isSet { usleep(50_000) }
            probe = LiveClient.probe(client: call.client, keep: true)
            if probe.state == .headlessWriter {
                return .error("busy", "另一个 MCP 正在写这个数据目录（等了 2 秒还没写完）。", hint: "等几秒再调",
                              data: ["reason": "headless_writer"])
            }
        }
        guard probe.state == .live else { return stateError(probe) }
        guard probe.capabilities.contains(route.method) else {
            probe.closeConnection()
            return .error("app_version_mismatch", "开着的选片工具版本较旧，没有 \(name) 要的功能（\(route.method)）。",
                          hint: "请用户更新选片工具，或者退出再重新打开", data: ["reason": "app_too_old", "method": route.method])
        }
        var params: [String: Any] = [:]
        switch checkSession(route.session, call.arguments["session"], open: probe.openSession) {
        case .failure(let problem):
            probe.closeConnection()
            return problem.result
        case .success(let key):
            if let key { params["session"] = key }
        }
        guard wired.contains(route.method) else {
            probe.closeConnection()
            return .error("internal", "\(name) 的实时部分还没接上。", hint: "这是服务器的 bug：MCP 和 app 应该是同一次构建")
        }
        let (outcome, after) = LiveClient.read(probe, method: route.method, params: params, deadlineMs: route.deadlineMs, call: call)
        return finish(outcome, probe: after, first: probe)
    }

    /// session 参数和 hello 的 open_session 比（§10.2「session 怎么比」）：16 位 key 直接比，绝对路径按 §4.2 解析了再比；
    /// sessions.json 里有没有这一场不影响。对上了把 app 认的那个 key 发过去，app 执行前再核对一次。
    static func checkSession(_ rule: SessionRule, _ raw: Any?, open: [String: Any]?) -> Result<String?, SessionError> {
        let given = raw.flatMap { $0 is NSNull ? nil : $0 }
        if rule == .target { return .success(nil) }
        guard let given else {
            if rule == .required {
                return .failure(SessionError(.error("invalid_argument", "session 必填：要读或改的那一场。",
                                                    hint: "填 app 当前打开的那一场：先 app_status 看 live.open_session")))
            }
            return .success(nil)
        }
        guard let text = given as? String, let arg = MCPPaths.parseSession(text) else {
            return .failure(SessionError(.error("invalid_argument", "session 要填 16 位 session key，或者照片文件夹的绝对路径。",
                                                hint: "先 app_status 看 live.open_session，或者 cull_list_sessions")))
        }
        guard let open, let key = open["session"] as? String, let folder = open["folder"] as? String,
              MCPPaths.session(arg, matches: key, folder: folder) else {
            return .failure(SessionError(sessionNotOpen(open)))
        }
        return .success(key)
    }

    struct SessionError: Error {
        let result: MCPStdioServer.ToolResult
        init(_ result: MCPStdioServer.ToolResult) { self.result = result }
    }

    static func sessionNotOpen(_ open: [String: Any]?) -> MCPStdioServer.ToolResult {
        let message = open == nil ? "选片工具开着，但没有打开任何场次。" : "这一场不是选片工具当前打开的那一场。"
        return .error("session_not_open", message,
                      hint: "先 app_status 看 live.open_session；要换场次用 app_open_session（会清掉 app 里这一场的撤销记录，先问用户）",
                      data: ["open_session": open ?? NSNull()])
    }

    /// 不是 live（或者重探以后不是 live）：回那个状态的错误码（§10.2；读写都一样）。
    static func stateError(_ probe: LiveClient.Probe) -> MCPStdioServer.ToolResult {
        let (message, hint) = LiveClient.explain(probe)
        var data: [String: Any] = ["live_state": probe.state.rawValue]
        if let r = probe.reason { data["reason"] = r }
        if probe.state == .protoMismatch { data["reason"] = "proto_mismatch" }
        return .error(LiveClient.errorCode(probe.state), message, hint: hint, data: data)
    }

    private static func finish(_ outcome: LiveClient.Outcome, probe: LiveClient.Probe, first: LiveClient.Probe) -> MCPStdioServer.ToolResult {
        switch outcome {
        case .result(var r):
            var warnings = (r["warnings"] as? [[String: Any]]) ?? []
            warnings.append(contentsOf: first.warnings)
            if first.hello?["exact_build_match"] as? Bool == false { warnings.append(MCPStatus.buildMismatchWarning(first.hello)) }
            r["warnings"] = warnings
            return .json(r)
        case .failure(let code, let message, let data):
            switch code {
            case "session_not_open":
                return sessionNotOpen(data?["open_session"] as? [String: Any])
            case "unknown_method":
                return .error("app_version_mismatch", "开着的选片工具版本较旧，没有这个功能。", hint: "请用户更新选片工具",
                              data: ["reason": "app_too_old"])
            case "expired":
                return .error("expired", message.isEmpty ? "在 app 主线程上排队超过了截止时间，没有执行。" : message,
                              hint: "可以直接重试", data: data)
            default:
                return .error(code, message.isEmpty ? "选片工具回了错误 \(code)。" : message, hint: nil, data: data)
            }
        case .gone:
            // 读：重探以后不是 live（app 刚被关掉 / 杀掉）就回那个状态；重探是 live 而重发又断了，按连不上算
            return probe.state == .live
                ? .error("app_unreachable", "连上了选片工具，但请求发出去以后连接断了两次。", hint: "过一会儿再调")
                : stateError(probe)
        case .timeout:
            if probe.state == .live {
                return .error("deadline_exceeded", "选片工具没在截止时间内回复（hello 还能秒回：app 主线程正忙）。",
                              hint: "app 主线程正忙，过一会儿再调")
            }
            return stateError(probe)
        case .cancelled:
            return .error("cancelled", "调用被取消了。")
        }
    }
}
