import Foundation

/// 另外两个进程内工具（DESIGN §3.1，按 §10.1 第 2、3 行改）。
/// S1 先给最小的真结果（读 sessions.json、读代码里的名单），不探测、不碰照片文件夹；S2 补全：
/// cull_list_sessions 的 folder_online / protected_location（ProtectedPaths）、open_in_app，
/// collage_list_templates 的模板、分类、画布和 category 筛选。
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
        var warnings: [[String: Any]] = []
        if !MCPPaths.dataDirState().exists {
            warnings.append(MCPStatus.warning("data_dir_missing", "数据目录不存在：这台机器上还没有分析过的场次。",
                                              hint: "请用户自己打开选片工具分析一场"))
        }
        if let problem = index.problem {
            warnings.append(MCPStatus.warning("sessions_index_unreadable", problem, hint: "请用户在选片工具里打开一次任意场次"))
        }
        let rows: [[String: Any]] = index.entries.prefix(limit).map { e in
            var row: [String: Any] = ["session": e.key, "folder": e.folder, "name": e.name]
            row["photo_count"] = e.photoCount
            row["last_analyzed"] = e.lastAnalyzed
            row["in_recent_list"] = true
            return row
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

    static func listTemplates(_ call: MCPStdioServer.Call) -> MCPStdioServer.ToolResult {
        let parts = ["templates", "kits", "styles", "looks", "canvases"]
        if let extra = call.arguments.keys.sorted().first(where: { $0 != "category" && $0 != "include" }) {
            return .error("invalid_argument", "collage_list_templates 不认参数 \(extra)。", hint: "只有 category、include")
        }
        var include = Set(parts)
        if let raw = call.arguments["include"] {
            guard let list = raw as? [String], list.allSatisfy({ parts.contains($0) }) else {
                return .error("invalid_argument", "include 要是这几个里挑：\(parts.joined(separator: "、"))。", hint: "比如 {\"include\":[\"styles\"]}")
            }
            include = Set(list)
        }
        var out: [String: Any] = [:]
        if include.contains("kits") {
            out["kits"] = CollageKitID.allCases.map { k -> [String: Any] in ["id": k.rawValue, "name": k.name, "summary": k.summary] }
        }
        if include.contains("styles") {
            out["styles"] = CollageStyles.all.map { p -> [String: Any] in ["key": p.key, "name": p.name] }
        }
        if include.contains("looks") {
            out["looks"] = MCPToolDefs.lookKeys
        }
        return .json(out)
    }
}
