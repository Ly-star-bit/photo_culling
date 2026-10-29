import Foundation

/// 预览输出目录（DESIGN §10.3「输出目录」，照 §4.2 只用其中的 `previews/`）：`--mcp` 唯一会写的地方（§10.0 第 3 条）。
/// - 根：LABELGUI_MCP_OUT（必须是绝对路径），默认 ~/Pictures/xuanpian-mcp。启动时不检查、不建（启动不做重活）；
///   第一次存图时才建、才查：不在受系统隐私保护的位置（写进桌面会以终端的名义弹授权框）、逐段解析符号链接以后也不指进去，
///   不在数据目录、不在任何「最近场次」的照片文件夹里面，能写；根上要有 `.xuanpian-mcp` 标记 —— 空目录就写一个，
///   不空又没有标记就不用它（用户把它指到 ~/Pictures 这种自己的目录，清理会删到用户的文件）。
/// - 文件名都由服务器起，按内容寻址：`previews/<key>/<字节 SHA-1 前 16 位>-<id>-<长边>-<full|face>.jpg`、
///   `previews/<key>/<SHA-1 前 16 位>-collage.jpg`；已经有了就不写；先写临时文件（O_EXCL|O_NOFOLLOW）再改名。
/// - 清理只在带标记的根上做，只删 `previews/<16 位十六进制>/` 下面名字符合上面规则的普通文件（和一小时前的临时文件）：
///   7 天以前的，或者总量超过 1 GB 时从最旧的删。回完 initialize 以后在后台做一次（MCPServerMain 接上的）。
/// 这是 MCP/ 里四个许碰文件的地方之一（§10.5）；照片文件夹只按字符串比，不碰。
enum MCPOutput {
    struct Unusable: Error, Equatable {
        let message: String
        let hint: String
    }

    static let marker = ".xuanpian-mcp"
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let tempMaxAge: TimeInterval = 3600
    static let maxBytes: Int64 = 1 << 30

    /// 根的路径（只算，不碰文件系统）。nil = LABELGUI_MCP_OUT 不是绝对路径。
    static var rootPath: String? {
        if let raw = ProcessInfo.processInfo.environment["LABELGUI_MCP_OUT"], !raw.isEmpty {
            return raw.hasPrefix("/") ? raw : nil
        }
        return MCPPaths.outputRoot.path
    }

    private static let lock = NSLock()
    private static var ready: String?

    // MARK: - 第一次存图时的检查

    /// 检查通过的根（逐段解析过符号链接的路径）。成功的结果记住，之后不再查；失败的每次都重查（用户可能改好了）。
    static func prepare() -> Result<String, Unusable> {
        lock.lock()
        defer { lock.unlock() }
        if let ready { return .success(ready) }
        let r = check(create: true)
        if case .success(let root) = r { ready = root }
        return r
    }

    /// 存图失败（目录被删了之类）以后忘掉之前的检查结果，下次重新建、重新查。
    static func forget() {
        lock.lock()
        ready = nil
        lock.unlock()
    }

    static func check(create: Bool) -> Result<String, Unusable> {
        guard let raw = rootPath else {
            return .failure(Unusable(message: "LABELGUI_MCP_OUT 不是绝对路径。", hint: "在 MCP 配置里把它写成绝对路径，或者不设（用 ~/Pictures/xuanpian-mcp）"))
        }
        let protectedHint = "把 LABELGUI_MCP_OUT 设到不受保护的地方，比如 ~/Pictures/xuanpian-mcp"
        if ProtectedPaths.isProtected(raw) {
            return .failure(Unusable(message: "预览输出目录 \(raw) 在受系统隐私保护的位置（桌面、文稿、下载、资源库、外置盘……）：往那里写会弹系统授权框。",
                                     hint: protectedHint))
        }
        var walked = MCPPaths.walk(raw, probe: MCPPaths.lstatNode)
        if case .missing(let resolved) = walked, create {
            // 先查再建：在数据目录、照片文件夹里面的话一级都不建（§10.0 第 3 条）；建完下面按解析后的路径再查一遍
            if let problem = insideForbidden(resolved, raw: raw) { return .failure(problem) }
            do {
                try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
            } catch {
                return .failure(Unusable(message: "建不了预览输出目录 \(raw)：\(error.localizedDescription)", hint: "换一个能写的目录（LABELGUI_MCP_OUT）"))
            }
            walked = MCPPaths.walk(raw, probe: MCPPaths.lstatNode)
        }
        let root: String
        switch walked {
        case .found(let p, let isDirectory):
            guard isDirectory else {
                return .failure(Unusable(message: "预览输出目录 \(raw) 不是文件夹。", hint: "换一个目录（LABELGUI_MCP_OUT）"))
            }
            root = p
        case .missing:
            return .failure(Unusable(message: "预览输出目录 \(raw) 还不存在。", hint: "第一次存图时会建它"))
        case .protected:
            return .failure(Unusable(message: "预览输出目录 \(raw) 经符号链接指进了受系统隐私保护的位置。", hint: protectedHint))
        case .failed:
            return .failure(Unusable(message: "预览输出目录 \(raw) 解析不了（符号链接太多、没有权限或者路径太长）。", hint: "换一个目录（LABELGUI_MCP_OUT）"))
        }
        if let problem = insideForbidden(root, raw: raw) { return .failure(problem) }
        guard access(root, W_OK | X_OK) == 0 else {
            return .failure(Unusable(message: "预览输出目录 \(root) 不能写。", hint: "换一个能写的目录（LABELGUI_MCP_OUT）"))
        }
        return markRoot(root, create: create)
    }

    /// §4.2：不能在数据目录里面，不能在任何已登记的照片文件夹里面（~/Library/Application Support 整个是受保护位置，上面已经拦了）。
    /// 照片文件夹只按字符串比（§10.0 第 2 条：`--mcp` 对照片文件夹最多看一眼在不在）。
    static func insideForbidden(_ root: String, raw: String) -> Unusable? {
        let mine = [root, raw].compactMap { ProtectedPaths.comparisonKey($0, home: NSHomeDirectory()) }
        var data = [MCPPaths.dataDir.path]
        if !ProtectedPaths.isProtected(MCPPaths.dataDir.path),
           case .found(let p, _) = MCPPaths.walk(MCPPaths.dataDir.path, probe: MCPPaths.lstatNode) {
            data.append(p)
        }
        let dataKeys = data.compactMap { ProtectedPaths.comparisonKey($0, home: NSHomeDirectory()) }
        if mine.contains(where: { m in dataKeys.contains { inside(m, $0) } }) {
            return Unusable(message: "预览输出目录在选片工具的数据目录里面。", hint: "换一个目录（LABELGUI_MCP_OUT）")
        }
        for e in MCPPaths.readSessionsIndex().entries {
            guard let f = ProtectedPaths.comparisonKey(e.folder, home: NSHomeDirectory()) else { continue }
            if mine.contains(where: { inside($0, f) }) {
                return Unusable(message: "预览输出目录在照片文件夹「\(e.name)」里面。", hint: "换一个不在照片文件夹里的目录（LABELGUI_MCP_OUT）")
            }
        }
        return nil
    }

    static func inside(_ child: String, _ parent: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    /// 标记：有就行；没有而目录是空的（.DS_Store 不算）就写一个；不空又没有标记就不用（清理会删到用户的文件）。
    static func markRoot(_ root: String, create: Bool) -> Result<String, Unusable> {
        let path = root + "/" + marker
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                return .failure(Unusable(message: "\(path) 不是普通文件。", hint: "换一个目录（LABELGUI_MCP_OUT）"))
            }
            return .success(root)
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? ["?"]
        guard entries.allSatisfy({ $0 == ".DS_Store" }) else {
            return .failure(Unusable(message: "预览输出目录 \(root) 不是空的，也没有 \(marker) 标记：MCP 不往用户自己的目录里写、也不在那里清理。",
                                     hint: "换一个空目录，或者在它下面建个子目录（LABELGUI_MCP_OUT）"))
        }
        guard create else { return .failure(Unusable(message: "预览输出目录还没用过。", hint: "")) }
        let text = "选片工具 MCP 的预览输出目录（自动清理 7 天以前的预览）。删掉这个文件，MCP 就不再往这里写、也不再清理。\n"
        guard writeExclusive(path, Data(text.utf8)) else {
            return .failure(Unusable(message: "写不了 \(path)。", hint: "换一个能写的目录（LABELGUI_MCP_OUT）"))
        }
        return .success(root)
    }

    // MARK: - 存

    /// 16 位十六进制的 session key（previews/<key>/ 这一层只认它）。
    static func isKey(_ s: String) -> Bool {
        s.utf8.count == 16 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// 照片 id 放进文件名：只留 [A-Za-z0-9_-.]，其余换成 _，不许 `.` 开头，最长 64。
    static func safeID(_ id: String) -> String {
        var out = String(id.unicodeScalars.map { c -> Character in
            let ok = (c.value >= 48 && c.value <= 57) || (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122)
                || c == "_" || c == "-" || c == "."
            return ok ? Character(c) : "_"
        }.prefix(64))
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "photo" : out
    }

    static func previewName(sha: String, id: String, edge: Int, face: Bool) -> String {
        "\(sha.prefix(16))-\(safeID(id))-\(edge)-\(face ? "face" : "full").jpg"
    }

    static func collageName(sha: String) -> String {
        "\(sha.prefix(16))-collage.jpg"
    }

    /// 存进 previews/<key>/<name>（已经有了就不写），回完整路径。
    static func save(_ data: Data, key: String, name: String) -> Result<String, Unusable> {
        guard isKey(key), isServerName(name) else {
            return .failure(Unusable(message: "预览文件名不对（\(key)/\(name)）。", hint: "这是服务器的 bug"))
        }
        var lastProblem = Unusable(message: "存不了预览。", hint: "")
        for attempt in 0..<2 {
            let root: String
            switch prepare() {
            case .success(let r): root = r
            case .failure(let u): return .failure(u)
            }
            let dir = root + "/previews/" + key
            let final = dir + "/" + name
            var st = stat()
            if lstat(final, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { return .success(final) }
            if ensureDir(root + "/previews"), ensureDir(dir) {
                let temp = dir + "/." + name + ".tmp-\(getpid())-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
                if writeExclusive(temp, data) {
                    if rename(temp, final) == 0 { return .success(final) }
                    unlink(temp)
                }
            }
            lastProblem = Unusable(message: "预览存不进 \(dir)（\(String(cString: strerror(errno)))）。", hint: "换一个能写的目录（LABELGUI_MCP_OUT）")
            // 目录可能刚被删掉：忘掉检查结果，重新建、重新查一次
            if attempt == 0 { forget() }
        }
        return .failure(lastProblem)
    }

    /// 是文件夹（不是符号链接）就行；没有就建（0755）。
    static func ensureDir(_ path: String) -> Bool {
        var st = stat()
        if lstat(path, &st) == 0 { return (st.st_mode & S_IFMT) == S_IFDIR }
        return mkdir(path, 0o755) == 0 || (errno == EEXIST && lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// O_CREAT|O_EXCL|O_NOFOLLOW：不跟符号链接、不覆盖任何已有的文件。
    static func writeExclusive(_ path: String, _ data: Data) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        var ok = true
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    return
                }
                off += n
            }
        }
        if close(fd) != 0 { ok = false }
        if !ok { unlink(path) }
        return ok
    }

    // MARK: - 清理、统计（只认服务器起的名字）

    static let serverName = try! NSRegularExpression(pattern: #"^[0-9a-f]{16}-(collage|[A-Za-z0-9_.-]{1,64}-[0-9]{1,5}-(full|face))\.jpg$"#)
    static let tempName = try! NSRegularExpression(pattern: #"^\.[0-9a-f]{16}-.{1,90}\.jpg\.tmp-[0-9]+-[0-9a-f]{8}$"#)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func isServerName(_ name: String) -> Bool { matches(serverName, name) }

    struct CacheFile {
        let path: String
        let size: Int64
        let mtime: TimeInterval
        let temp: Bool
    }

    /// 带标记的根下面、服务器起名的文件（不建任何东西；根不在、没有标记就是空的）。符号链接一律不跟。
    static func listCache() -> [CacheFile] {
        guard let raw = rootPath, !ProtectedPaths.isProtected(raw),
              case .found(let root, true) = MCPPaths.walk(raw, probe: MCPPaths.lstatNode) else { return [] }
        var st = stat()
        guard lstat(root + "/" + marker, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return [] }
        let previews = root + "/previews"
        guard lstat(previews, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return [] }
        var out: [CacheFile] = []
        for key in (try? FileManager.default.contentsOfDirectory(atPath: previews)) ?? [] where isKey(key) {
            let dir = previews + "/" + key
            guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let server = isServerName(name)
                guard server || matches(tempName, name) else { continue }
                let path = dir + "/" + name
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                out.append(CacheFile(path: path, size: Int64(st.st_size), mtime: mtime, temp: !server))
            }
        }
        return out
    }

    /// app_status 的 preview_cache_bytes。
    static func cacheBytes() -> Int64 {
        listCache().filter { !$0.temp }.reduce(0) { $0 + $1.size }
    }

    /// 7 天以前的、一小时以前的临时文件删掉；剩下的超过 1 GB 就从最旧的删。回删掉的个数。
    @discardableResult
    static func cleanup(now: Date = Date()) -> Int {
        let files = listCache()
        let t = now.timeIntervalSince1970
        var removed = 0
        var kept: [CacheFile] = []
        for f in files {
            let old = f.temp ? t - f.mtime > tempMaxAge : t - f.mtime > maxAge
            if old {
                if unlink(f.path) == 0 { removed += 1 }
            } else if !f.temp {
                kept.append(f)
            }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.size }
        for f in kept.sorted(by: { $0.mtime < $1.mtime }) where total > maxBytes {
            if unlink(f.path) == 0 {
                removed += 1
                total -= f.size
            }
        }
        if removed > 0 { MCPLog.stderr("xuanpian mcp：预览缓存清掉 \(removed) 个文件\n") }
        return removed
    }
}
