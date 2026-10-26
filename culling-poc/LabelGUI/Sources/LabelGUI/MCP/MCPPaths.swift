import Foundation

/// `--mcp` 碰数据目录的唯一口子（DESIGN §10.0 第 2、3 条，§10.5「有名字的口子」）：只看数据目录在不在、能不能读，
/// 只读 `sessions.json`；不建目录、不写一个字节、不读任何设置域。grep 检查 `Data(contentsOf:`、`FileManager.default`
/// 这类调用在 MCP/ 里只出现在这里、MCPOutput、LiveClient、StdioTakeover 四个文件。
/// `appDataDir`（main.swift）现在只是路径，不建目录（§10.5）。
/// S1 只有 app_status、cull_list_sessions 要用的这几样；§4.2 的 session 解析在 S2 加。
enum MCPPaths {
    static var dataDir: URL { appDataDir }

    /// 用的是 LABELGUI_DATA_DIR 指的目录，不是默认的 ~/Library/Application Support/选片工具。
    static var dataDirOverridden: Bool {
        !(ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? "").isEmpty
    }

    /// 数据目录在不在（是目录才算）、能不能读。只 stat / access，不建、不改。
    static func dataDirState() -> (exists: Bool, readable: Bool) {
        var st = stat()
        guard stat(dataDir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return (false, false) }
        return (true, access(dataDir.path, R_OK | X_OK) == 0)
    }

    /// sessions.json 里的一条（app 侧栏「最近场次」，最多 15 条，BatchStore.SessionEntry）。bookmark 不解析、不往外给。
    struct SessionEntry {
        let key: String
        let folder: String
        let name: String
        let photoCount: Int
        let lastAnalyzed: String
    }

    /// `entries` 按 sessions.json 的顺序（最近打开的在前）；`problem` 是读不了 / 解析不了时的原因。
    /// 数据目录或 sessions.json 不存在都当作空列表，不算问题（从没开过 app 的机器就是这样）。
    static func readSessionsIndex() -> (entries: [SessionEntry], problem: String?) {
        guard dataDirState().exists else { return ([], nil) }
        let url = dataDir.appendingPathComponent("sessions.json")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return ([], nil)
        } catch {
            return ([], "读不了 sessions.json：\(error.localizedDescription)")
        }
        // 逐条宽松地取字段：app 用 atomic rename 写这个文件，但旧版本的条目可能少字段，坏一条不连累别的。
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return ([], "sessions.json 不是场次列表")
        }
        let entries: [SessionEntry] = list.compactMap { e in
            guard let key = e["key"] as? String, let path = e["path"] as? String else { return nil }
            let name = e["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent
            return SessionEntry(key: key, folder: path, name: name,
                                photoCount: e["photoCount"] as? Int ?? 0,
                                lastAnalyzed: e["lastAnalyzed"] as? String ?? "")
        }
        return (entries, nil)
    }

    /// 预览输出目录（§10.3）：LABELGUI_MCP_OUT，默认 ~/Pictures/xuanpian-mcp。这里只算路径：第一次存图时才建、
    /// 才做 §4.2 的检查（STEP 3a 的 MCPOutput）。
    static var outputRoot: URL {
        if let out = ProcessInfo.processInfo.environment["LABELGUI_MCP_OUT"], !out.isEmpty {
            return URL(fileURLWithPath: out)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures/xuanpian-mcp")
    }
}
