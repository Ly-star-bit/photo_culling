import Foundation

/// 另外两个进程内工具（DESIGN §3.1，按 §10.1 第 2、3 行改）：不探测 app、不读照片。
/// - cull_list_sessions：只读 sessions.json（MCPPaths.readSessionsIndex）；照片文件夹只看在不在（MCPPaths.foldersOnline），
///   受保护位置只按字符串标 protected_location:true、folder_online:null，连 stat 都不做。open_in_app 只在
///   live.state=live 时才有（取自 hello 的 open_session，§3.1）；app 开着却连不上时照常列，加一条 warning（§10.2）。
/// - collage_list_templates：代码里的静态表（CollageTemplates.builtin、CollageKitID、CollageStyles.all、CollageLook、
///   CLI 的画布别名），不碰任何文件。
enum MCPInProcessTools {
    static func listSessions(_ call: MCPStdioServer.Call) -> MCPStdioServer.ToolResult {
        if let extra = call.arguments.keys.sorted().first(where: { $0 != "limit" }) {
            return .error("invalid_argument", "cull_list_sessions 不认参数 \(extra)。", hint: "只有 limit（1–100）")
        }
        var limit = 30
        if let raw = call.arguments["limit"] {
            guard let n = integer(raw), (1...100).contains(n) else {
                return .error("invalid_argument", "limit 要是 1–100 的整数。", hint: "比如 {\"limit\":30}")
            }
            limit = n
        }
        let index = MCPPaths.readSessionsIndex()
        let dir = MCPPaths.dataDirState()
        // 先探测：data_dir_unreadable 那一句要看锁到底看没看到（warnings 的顺序不变）
        let probe = LiveClient.probe(client: call.client)
        var warnings: [[String: Any]] = []
        if !dir.exists {
            warnings.append(MCPStatus.warning("data_dir_missing", "数据目录不存在：这台机器上还没有分析过的场次。",
                                              hint: "请用户自己打开选片工具分析一场"))
        } else if !dir.readable {
            warnings.append(MCPStatus.dataDirUnreadableWarning(lockUnseen: LiveClient.lockUnseen(probe), sessionsDenied: index.denied))
        } else if index.missing {
            warnings.append(MCPStatus.warning("sessions_index_missing", "数据目录里没有 sessions.json：选片工具里还没有「最近场次」。",
                                              hint: "请用户在选片工具里分析或打开一场"))
        }
        if let problem = index.problem {
            warnings.append(MCPStatus.warning("sessions_index_unreadable", problem, hint: "请用户在选片工具里打开一次任意场次"))
        }
        let shown = Array(index.entries.prefix(limit))
        let checks = MCPPaths.foldersOnline(shown.map(\.folder))
        let openKey: String? = probe.state == .live ? probe.openSession?["session"] as? String : nil
        switch probe.state {
        case .live, .notRunning, .disabled:
            break
        case .unreachable where LiveClient.lockUnseen(probe) && !dir.readable:
            break  // 上面已经有 data_dir_unreadable（说了看不出开没开）
        default:
            let (message, hint) = LiveClient.explain(probe)
            warnings.append(MCPStatus.warning(probe.state.rawValue, message + "照常列出场次（读的是磁盘上的 sessions.json），open_in_app 不知道。",
                                              hint: hint))
        }
        let rows: [[String: Any]] = zip(shown, checks).map { e, check in
            var row: [String: Any] = ["session": e.key, "folder": e.folder, "name": e.name]
            row["photo_count"] = e.photoCount
            row["last_analyzed"] = e.lastAnalyzed
            row["in_recent_list"] = true
            row["folder_online"] = check.online.map { $0 as Any } ?? NSNull()
            row["protected_location"] = check.protected
            if probe.state == .live { row["open_in_app"] = e.key == openKey }
            return row
        }
        if checks.contains(where: { $0.online == nil && !$0.protected }) {
            warnings.append(MCPStatus.warning("folder_check_incomplete",
                                              "有的照片文件夹查不出来在不在（1 秒内没回、没权限，或者符号链接绕成了环），folder_online 记成 null。",
                                              hint: "不影响列场次；要用那一场，请用户在 app 里打开它"))
        }
        var out: [String: Any] = ["sessions": rows, "total": index.entries.count]
        out["truncated"] = index.entries.count > rows.count
        out["warnings"] = warnings
        return MCPStdioServer.ToolResult(content: [["type": "text", "text": MCPJSON.fitting(out, list: "sessions")]])
    }

    /// JSON 里的整数（true / false、带小数的都不算；JSONSerialization 把 Bool 也解成 NSNumber）。
    static func integer(_ raw: Any) -> Int? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 1e15 else { return nil }
        return Int(d)
    }

    // MARK: - collage_list_templates

    static let templateParts = ["templates", "kits", "styles", "looks", "canvases"]

    static func listTemplates(_ call: MCPStdioServer.Call) -> MCPStdioServer.ToolResult {
        if let extra = call.arguments.keys.sorted().first(where: { $0 != "category" && $0 != "include" }) {
            return .error("invalid_argument", "collage_list_templates 不认参数 \(extra)。", hint: "只有 category、include")
        }
        var include = Set(templateParts)
        if let raw = call.arguments["include"] {
            guard let list = raw as? [String], !list.isEmpty, list.allSatisfy({ templateParts.contains($0) }) else {
                return .error("invalid_argument", "include 要是这几个里挑（至少一个）：\(templateParts.joined(separator: "、"))。",
                              hint: "比如 {\"include\":[\"styles\"]}；不给就是全部")
            }
            include = Set(list)
        }
        var templates = CollageTemplates.builtin
        if let raw = call.arguments["category"] {
            guard let q = raw as? String, !q.isEmpty, q.count <= 40 else {
                return .error("invalid_argument", "category 要是 1–40 字的字符串。", hint: "比如 {\"category\":\"时尚刊\"}")
            }
            // 分类名一样、分类名或模板名里含这几个字（「杂志」= 日系杂志、留白杂志和名字里带杂志的）
            templates = templates.filter { $0.category == q || $0.category.contains(q) || $0.name.contains(q) }
            guard !templates.isEmpty else {
                return .error("invalid_argument", "没有分类或名字里含「\(q)」的模板。",
                              hint: "分类有：\(MCPToolDefs.templateCategories.joined(separator: "、"))；不给 category 就列全部")
            }
        }
        var out: [String: Any] = [:]
        if include.contains("templates") {
            out["categories"] = categories
            let names = Set(templates.map(\.name))
            out["templates"] = templateRows.filter { names.contains($0["name"] as? String ?? "") }
        }
        if include.contains("kits") {
            out["kits"] = CollageKitID.allCases.map { k -> [String: Any] in ["id": k.rawValue, "name": k.name, "summary": k.summary] }
        }
        if include.contains("styles") {
            out["styles"] = CollageStyles.all.map { p -> [String: Any] in ["key": p.key, "name": p.name] }
        }
        if include.contains("looks") {
            out["looks"] = CollageLook.allCases.map { l -> [String: Any] in ["key": l.rawValue, "name": l.label] }
        }
        if include.contains("canvases") {
            out["canvases"] = canvasAliases.map { alias -> [String: Any] in
                let c = CollageCLI.canvas(alias)
                var row: [String: Any] = ["key": alias, "name": c.name]
                row["width"] = c.width
                row["height"] = c.height
                return row
            }
        }
        return MCPStdioServer.ToolResult(content: [["type": "text", "text": MCPJSON.fitting(out, list: "templates")]])
    }

    /// 内置模板的分类和每类几个，按模板库里的顺序（第一次出现的位置）。
    static let categories: [[String: Any]] = MCPToolDefs.templateCategories.map { name -> [String: Any] in
        ["name": name, "count": CollageTemplates.builtin.filter { $0.category == name }.count]
    }

    /// CLI --canvas 的别名，照 CollageCLI.canvas(_:) 的 switch 抄（名字、尺寸从它那里取；mcp_smoke 拿源码核对这张表，
    /// --mcp-selftest 核对它正好盖住 CollageCanvas.social + .albums）。v1 没有改画布的工具，列出来是让模型知道
    /// app 里有哪些画布，要换请用户自己在 app 里换。
    static let canvasAliases = ["3:4", "1:1", "grid9", "4:5", "9:16", "16:9", "carousel3", "a4",
                                "album30", "album25", "album20", "album3020"]

    /// 每个内置模板一行（按 CollageTemplates.builtin 的顺序：collage_apply_template 按分类名套「这个分类的第一个」就是按它）。
    static let templateRows: [[String: Any]] = CollageTemplates.builtin.map { t -> [String: Any] in
        var row: [String: Any] = ["name": t.name, "category": t.category, "photo_slots": t.photoSlots]
        // fit_aspects 和代码里的 CollageTemplate.fitAspects 同义：true = 套用时按照片原比例重算格子（智能模板）；
        // false = 固定比例，照片按格裁。几张横图 / 竖图在 photo_cells。
        row["fit_aspects"] = t.fitAspects
        row["photo_cells"] = photoCells(t).map { $0 as Any } ?? NSNull()
        row["scatter"] = t.scatter != nil || t.freeform
        row["contact_sheet"] = t.contactSheet != nil
        return row
    }

    /// 照片格排出来是横的、竖的还是方的（长宽差不到一成算方的）：按模板自带的画布（没有就是默认的小红书 3:4）和自带的
    /// 样式排；fit_aspects 的模板套用时还会按照片比例再调，这里是它本来的样子。散落、印样（套用时按照片现排）回 nil。
    static func photoCells(_ t: CollageTemplate) -> [String: Int]? {
        guard t.scatter == nil, t.contactSheet == nil, !t.freeform else { return nil }
        let canvas = t.canvas ?? CollageCanvas()
        let style = t.style ?? CollageStyle()
        let frames = CollageLayout.pageGeometry(t.root, canvas: canvas, style: style).frames
        var aspects: [Double] = frames.filter { $0.cell.kind == .photo }.map { $0.rect.aspect }
        // 模板自带的相纸图层（宽高都按画布短边算）
        for item in t.items where item.kind == .photo && item.height > 0 {
            aspects.append(item.width / item.height)
        }
        var counts: [String: Int] = ["landscape": 0, "portrait": 0, "square": 0]
        for a in aspects {
            let shape = a > 1.1 ? "landscape" : (a < 1 / 1.1 ? "portrait" : "square")
            counts[shape, default: 0] += 1
        }
        return counts
    }
}
