import Foundation

/// 要 app 的 15 个工具怎么路由（DESIGN §10.2，取代 §9.1 的三列表）：每次调用探一次（LiveClient.probe，不缓存），
/// 只在 `live`、方法在 hello 的 capabilities 里、场次对得上时转给 app；其余情况一律回那个状态的错误码。服务器绝不启动 app。
/// 顺序：探测 → 方法在不在 → 参数校验（和 app 同一份 MCPArgs；app 没开时不管参数，一律 app_not_running）→ 场次核对 → 转发。
/// 6 个读工具（STEP 3a）：cull.read（overview / photos / get / groups，结果就是 app 里 MCPReadModel 产出的 JSON，这里只补
/// warnings）、cull.preview、collage.state。图片字节在这里只核对（FF D8 开头、长度对得上）、存进输出目录（MCPOutput），
/// 再原样作为 image 块转发 —— 这个进程不解码任何图片（§10.0 第 2 条）。
/// 9 个写工具（STEP 3b）：每次调用一个 op_id（模型给了就用它的），断线 / 超时同一个 op_id 自动重发一次（LiveClient.write），
/// 还不行回 app_outcome_unknown（带 op_id）；拼图写的结果里带 app 当前画面的预览，和 collage_get_state 一样存一份、内联转发。
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

    /// 会转发的桥方法（§10.4 的 12 个；app 的 capabilities 里没有的回 app_version_mismatch / app_too_old）。
    static let wired: Set<String> = ["cull.read", "cull.preview", "collage.state", "session.open", "cull.set_verdicts", "cull.show",
                                     "collage.apply_template", "collage.run_kit", "collage.next_cover", "collage.set_text",
                                     "collage.set_style", "undo"]

    /// 结果里带拼图预览的写（和 collage_get_state 一样处理：存一份、内联）。
    static let collageWrites: Set<String> = ["collage.apply_template", "collage.run_kit", "collage.next_cover", "collage.set_text",
                                             "collage.set_style", "undo"]

    /// cull.read 的四个工具 → kind（§10.4）。
    static let readKinds: [String: String] = [
        "cull_session_overview": "overview", "cull_list_photos": "photos", "cull_get_photos": "get", "cull_list_groups": "groups",
    ]

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
        // 参数（和 app 同一份 MCPArgs，§9.2.3）：app 那一侧还会再查一遍
        if MCPArgs.specs[name] != nil, let p = MCPArgs.check(name, call.arguments, deadlineCap: MCPConfig.deadlineCap) {
            probe.closeConnection()
            return .error("invalid_argument", p.message, hint: p.hint.isEmpty ? "参数照 tools/list 里这个工具的 inputSchema 写" : p.hint)
        }
        var params: [String: Any] = [:]
        var sessionKey: String?
        switch checkSession(route.session, call.arguments["session"], open: probe.openSession) {
        case .failure(let problem):
            probe.closeConnection()
            return problem.result
        case .success(let key):
            if let key { params["session"] = key }
            sessionKey = key
        }
        guard wired.contains(route.method) else {
            probe.closeConnection()
            return .error("internal", "\(name) 的实时部分还没接上。", hint: "这是服务器的 bug：MCP 和 app 应该是同一次构建")
        }
        if route.write {
            return write(name, route, call, probe: probe, sessionKey: sessionKey)
        }
        var deadlineMs = route.deadlineMs
        switch route.method {
        case "cull.read":
            var args = call.arguments
            args["session"] = nil
            params["kind"] = readKinds[name] ?? ""
            params["args"] = args
            params["text_max"] = MCPJSON.textMax
        case "cull.preview":
            for k in ["ids", "crop", "max_edge"] { if let v = call.arguments[k] { params[k] = v } }
            // 内联预算（LABELGUI_MCP_INLINE_KB）只有这个进程看得到，交给 app 照着截（§10.3 第 2 步）；inline:false 时
            // 不内联，预算就只剩单张上限（4 张 × 350 KB），全部存成文件 —— 图片超限时的退路就是它（§10.3「输出目录」）
            let inline = call.arguments["inline"] as? Bool ?? true
            params["budget_kb"] = inline ? MCPConfig.inlineKB : 4 * MCPConfig.perImageKB
            if let sec = call.arguments["deadline_seconds"].flatMap(MCPArgs.integer) { deadlineMs = sec * 1_000 }
        case "collage.state":
            for k in ["include_preview", "max_edge"] { if let v = call.arguments[k] { params[k] = v } }
        default:
            break
        }
        let (outcome, after) = LiveClient.read(probe, method: route.method, params: params, deadlineMs: deadlineMs, call: call)
        let result: [String: Any]
        switch unwrap(outcome, probe: after, first: probe) {
        case .failure(let error): return error.result
        case .success(let r): result = r
        }
        let inline = call.arguments["inline"] as? Bool ?? true
        switch route.method {
        case "cull.preview":
            return previewResult(result, session: sessionKey ?? "", face: call.arguments["crop"] as? String == "face", inline: inline)
        case "collage.state":
            let include = call.arguments["include_preview"] as? Bool ?? true
            return collageResult(result, inline: inline && include)
        default:
            return .json(result)
        }
    }

    // MARK: - 写（§9.3、§10.2）

    /// 写工具：参数原样转给 app（session 换成 app 认的 key；app_open_session 的 session 是要打开的那一场，原样给），
    /// op_id / inline 不进 params（op_id 在帧上，inline 只有这一侧用）。
    static func write(_ name: String, _ route: Route, _ call: MCPStdioServer.Call, probe: LiveClient.Probe,
                      sessionKey: String?) -> MCPStdioServer.ToolResult {
        var params = call.arguments
        params["op_id"] = nil
        params["inline"] = nil
        params["deadline_seconds"] = nil
        params["session"] = nil
        if route.session == .target {
            let raw = call.arguments["session"] as? String ?? ""
            // 早点给错：受保护位置只按字符串判断（app 一侧是权威的那一遍，§10.4 第 4 条）；key 先在 sessions.json 里查路径。
            // 已经是 app 当前那一场（用户自己从侧栏点开的）就不挡，交给 app 回 already_open（§9.3 先判它）
            let open = probe.openSession
            let openKey = open?["session"] as? String ?? ""
            let openFolder = open?["folder"] as? String ?? ""
            let alreadyOpen: Bool = open != nil && MCPPaths.parseSession(raw).map {
                MCPPaths.session($0, matches: openKey, folder: openFolder, resolve: { _ in nil })
            } == true
            if !alreadyOpen, let folder = targetFolder(raw), ProtectedPaths.isProtected(folder) {
                probe.closeConnection()
                return .error("protected_location",
                              "「\(folder)」在系统隐私保护的位置（桌面 / 文稿 / 下载 / iCloud 云盘 / 外置盘或网络卷）。让 app 为 AI 去读它可能弹出系统授权框，AI 不会替你点。",
                              hint: "请用户自己在 app 侧栏「最近场次」里点开它", data: ["folder": folder])
            }
            params["session"] = raw
        } else if let sessionKey {
            params["session"] = sessionKey
        }
        var deadlineMs = route.deadlineMs
        if let sec = call.arguments["deadline_seconds"].flatMap(MCPArgs.integer) { deadlineMs = sec * 1_000 }
        let opID = call.arguments["op_id"] as? String ?? UUID().uuidString.lowercased()
        let outcome: LiveClient.Outcome
        switch LiveClient.write(probe, method: route.method, params: params, deadlineMs: deadlineMs, opID: opID, call: call) {
        case .done(let o):
            outcome = o
        case .outcomeUnknown(let op):
            // cull_show_photos 不收 op_id（§9.3：它只改选中和焦点，再调一次也一样），hint 不能叫模型带 op_id 重来
            let takesOpID = MCPArgs.specs[name]?.props["op_id"] != nil
            let hint = takesOpID ? "用同一个 op_id 原样再调一次同一个工具（不要换工具）；app 那边做过就会回 replayed:true"
                                 : "这个工具只改 app 里的选中和焦点，再调一次结果一样：原样再调一次（它不收 op_id）"
            return .error("app_outcome_unknown", "写请求发出去以后连接断了（或者超时了），不知道 app 做了没有。",
                          hint: hint, data: ["op_id": op])
        case .restarted(let op):
            return .error("app_restarted", "重发时选片工具已经重启过（pid 变了），之前那一次做没做不知道。",
                          hint: "先 collage_get_state / cull_list_photos 看现在的状态再决定", data: ["op_id": op])
        }
        var result: [String: Any]
        switch unwrap(outcome, probe: probe, first: probe) {
        case .failure(let error): return error.result
        case .success(let r): result = r
        }
        if result["preview_omitted"] as? Bool == true {
            var warnings = result["warnings"] as? [[String: Any]] ?? []
            warnings.append(MCPStatus.warning("preview_omitted", "这是同一个 op_id 的重放（app 之前已经做过），结果里不带预览图。",
                                              hint: "要看现在的画面调 collage_get_state"))
            result["warnings"] = warnings
            result["preview_omitted"] = nil
        }
        guard collageWrites.contains(route.method) else { return .json(result) }
        return collageResult(result, inline: call.arguments["inline"] as? Bool ?? true)
    }

    /// app_open_session 的目标在哪个文件夹（只按字符串）：绝对路径就是它；key 在 sessions.json 里查（§10.0 第 2 条：
    /// 数据目录里只读 sessions.json）。查不到 = nil（交给 app 判断）。
    static func targetFolder(_ raw: String) -> String? {
        switch MCPPaths.parseSession(raw) {
        case .path(let p, _):
            return p
        case .key(let k):
            return MCPPaths.readSessionsIndex().entries.first { $0.key == k }?.folder
        case nil:
            return nil
        }
    }

    // MARK: - 图片（§10.3「--mcp 一侧」）

    /// 一段 base64 是不是一张完整的 JPEG：解得出来、FF D8 开头、长度等于 app 说的 bytes。不对就丢掉这张、加 warning。
    static func jpeg(_ b64: Any?, bytes: Any?) -> Data? {
        guard let s = b64 as? String, let data = Data(base64Encoded: s), let n = bytes.flatMap(MCPArgs.integer),
              data.count == n, data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return nil }
        return data
    }

    static func imageBlock(_ data: Data) -> [String: Any] {
        ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]
    }

    /// cull_preview_photos 的结果：text 里每张 {index, id, verdict, file, width, height, bytes, source, crop, original_path}，
    /// 后面依次是 image 块（index 对应它的顺序）。inline:false 只给文件路径；输出目录不能用时 inline 照常、file 是 null。
    static func previewResult(_ r: [String: Any], session: String, face: Bool, inline: Bool) -> MCPStdioServer.ToolResult {
        var warnings = r["warnings"] as? [[String: Any]] ?? []
        var rows: [[String: Any]] = []
        var blocks: [[String: Any]] = []
        var outputProblem: MCPOutput.Unusable?
        for img in r["images"] as? [[String: Any]] ?? [] {
            let id = img["id"] as? String ?? ""
            var row: [String: Any] = ["id": id, "index": NSNull(), "file": NSNull()]
            for k in ["verdict", "width", "height", "bytes", "source", "crop", "original_path", "faces"] { row[k] = img[k] ?? NSNull() }
            guard img["jpeg_b64"] != nil else {
                // 超出这一次的预算：app 没给字节（§10.3 第 2 步）
                row["truncated"] = true
                rows.append(row)
                continue
            }
            guard let data = jpeg(img["jpeg_b64"], bytes: img["bytes"]) else {
                warnings.append(MCPStatus.warning("bad_jpeg", "\(id) 的图片字节不对（不是 JPEG，或者长度和 bytes 对不上），丢掉了。",
                                                  hint: "再调一次；还不行就是 app 的 bug"))
                continue
            }
            let edge = max(MCPArgs.integer(img["width"] ?? 0) ?? 0, MCPArgs.integer(img["height"] ?? 0) ?? 0)
            let name = MCPOutput.previewName(sha: MCPCursor.sha1Data(data), id: id, edge: edge, face: face)
            switch MCPOutput.save(data, key: session, name: name) {
            case .success(let path): row["file"] = path
            case .failure(let u): outputProblem = u
            }
            if inline {
                row["index"] = blocks.count
                blocks.append(imageBlock(data))
            }
            rows.append(row)
        }
        if let u = outputProblem {
            if !inline { return .error("output_dir_unusable", u.message, hint: u.hint) }
            warnings.append(MCPStatus.warning("output_dir_unusable", u.message + " 图照常内联，只是没存文件。", hint: u.hint))
        }
        if rows.allSatisfy({ $0["file"] is NSNull && $0["index"] is NSNull }) && !(r["truncated"] as? Bool ?? false) {
            return .error("internal", "app 给的图片都核对不过（不是完整的 JPEG）。", hint: "再调一次；还不行就是 app 的 bug")
        }
        var out: [String: Any] = ["images": rows, "inline": inline, "truncated": r["truncated"] as? Bool ?? false]
        out["missing_ids"] = r["missing_ids"] ?? []
        out["failed"] = r["failed"] ?? []
        out["pending_writes"] = r["pending_writes"] ?? 0
        out["warnings"] = warnings
        let text: [String: Any] = ["type": "text", "text": MCPJSON.string(out)]
        return MCPStdioServer.ToolResult(content: [text] + blocks)
    }

    /// collage_get_state 的结果：preview_jpeg_b64 换成 preview {file, width, height, bytes, index}，后面跟 image 块。
    static func collageResult(_ r: [String: Any], inline: Bool) -> MCPStdioServer.ToolResult {
        var out = r
        var warnings = out["warnings"] as? [[String: Any]] ?? []
        let b64 = out.removeValue(forKey: "preview_jpeg_b64")
        let width = out.removeValue(forKey: "preview_width")
        let height = out.removeValue(forKey: "preview_height")
        let bytes = out.removeValue(forKey: "preview_bytes")
        var blocks: [[String: Any]] = []
        if b64 != nil {
            if let data = jpeg(b64, bytes: bytes) {
                var preview: [String: Any] = ["width": width ?? NSNull(), "height": height ?? NSNull(), "bytes": data.count]
                preview["file"] = NSNull()
                preview["index"] = NSNull()
                // 没打开任何场次时没有 key：只内联，不存
                if let key = out["session"] as? String {
                    switch MCPOutput.save(data, key: key, name: MCPOutput.collageName(sha: MCPCursor.sha1Data(data))) {
                    case .success(let path): preview["file"] = path
                    case .failure(let u):
                        warnings.append(MCPStatus.warning("output_dir_unusable", u.message + " 预览照常内联，只是没存文件。", hint: u.hint))
                    }
                }
                if inline {
                    preview["index"] = 0
                    blocks.append(imageBlock(data))
                }
                out["preview"] = preview
            } else {
                warnings.append(MCPStatus.warning("bad_jpeg", "拼图预览的字节不对，丢掉了。", hint: "再调一次"))
            }
        }
        out["warnings"] = warnings
        let text: [String: Any] = ["type": "text", "text": MCPJSON.string(out)]
        return MCPStdioServer.ToolResult(content: [text] + blocks)
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

    /// `app`：app 回的 data（写的时候等用户停手、用户切了场次：reason=session_switched_while_waiting、executed:false），原样带上。
    static func sessionNotOpen(_ open: [String: Any]?, app: [String: Any]? = nil, message appMessage: String? = nil) -> MCPStdioServer.ToolResult {
        let message = appMessage ?? (open == nil ? "选片工具开着，但没有打开任何场次。" : "这一场不是选片工具当前打开的那一场。")
        var data = app ?? [:]
        data["hint"] = nil
        data["open_session"] = open ?? NSNull()
        return .error("session_not_open", message,
                      hint: "先 app_status 看 live.open_session；要换场次用 app_open_session（会清掉 app 里这一场的撤销记录，先问用户）",
                      data: data)
    }

    /// 不是 live（或者重探以后不是 live）：回那个状态的错误码（§10.2；读写都一样）。
    static func stateError(_ probe: LiveClient.Probe) -> MCPStdioServer.ToolResult {
        let (message, hint) = LiveClient.explain(probe)
        var data: [String: Any] = ["live_state": probe.state.rawValue]
        if let r = probe.reason { data["reason"] = r }
        if probe.state == .protoMismatch { data["reason"] = "proto_mismatch" }
        return .error(LiveClient.errorCode(probe.state), message, hint: hint, data: data)
    }

    struct ToolError: Error {
        let result: MCPStdioServer.ToolResult
    }

    /// 桥的回复 → 结果对象（补上 probe 的 warnings）或者 §10.2 的错误。app 回的错误里 data.hint 挪到 hint。
    private static func unwrap(_ outcome: LiveClient.Outcome, probe: LiveClient.Probe,
                               first: LiveClient.Probe) -> Result<[String: Any], ToolError> {
        switch outcome {
        case .result(var r):
            var warnings = (r["warnings"] as? [[String: Any]]) ?? []
            warnings.append(contentsOf: first.warnings)
            if first.hello?["exact_build_match"] as? Bool == false { warnings.append(MCPStatus.buildMismatchWarning(first.hello)) }
            r["warnings"] = warnings
            return .success(r)
        case .failure(let code, let message, let data):
            switch code {
            case "session_not_open":
                let open = data?["open_session"] as? [String: Any]
                let switched = data?["reason"] != nil
                return .failure(ToolError(result: sessionNotOpen(open, app: data, message: switched ? message : nil)))
            case "unknown_method":
                return .failure(ToolError(result: .error("app_version_mismatch", "开着的选片工具版本较旧，没有这个功能。",
                                                         hint: "请用户更新选片工具", data: ["reason": "app_too_old"])))
            case "expired":
                return .failure(ToolError(result: .error("expired", message.isEmpty ? "在 app 主线程上排队超过了截止时间，没有执行。" : message,
                                                         hint: "可以直接重试", data: data)))
            default:
                var rest = data ?? [:]
                let hint = rest.removeValue(forKey: "hint") as? String
                return .failure(ToolError(result: .error(code, message.isEmpty ? "选片工具回了错误 \(code)。" : message, hint: hint,
                                                         data: rest.isEmpty ? nil : rest)))
            }
        case .gone:
            // 读：重探以后不是 live（app 刚被关掉 / 杀掉）就回那个状态；重探是 live 而重发又断了，按连不上算
            return .failure(ToolError(result: probe.state == .live
                ? .error("app_unreachable", "连上了选片工具，但请求发出去以后连接断了两次。", hint: "过一会儿再调")
                : stateError(probe)))
        case .timeout:
            if probe.state == .live {
                return .failure(ToolError(result: .error("deadline_exceeded", "选片工具没在截止时间内回复（hello 还能秒回：app 主线程正忙）。",
                                                         hint: "app 主线程正忙，过一会儿再调")))
            }
            return .failure(ToolError(result: stateError(probe)))
        case .cancelled:
            return .failure(ToolError(result: .error("cancelled", "调用被取消了。")))
        }
    }
}
