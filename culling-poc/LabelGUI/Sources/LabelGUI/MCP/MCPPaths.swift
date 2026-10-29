import Foundation

/// `--mcp` 碰数据目录和照片文件夹的唯一口子（DESIGN §10.0 第 2、3 条，§10.5「有名字的口子」）：只看数据目录在不在、
/// 能不能读，只读 `sessions.json`；照片文件夹只看在不在（folderOnline），受保护位置连这个也不做。不建目录、不写一个字节、
/// 不读任何设置域。grep 检查 `Data(contentsOf:`、`FileManager.default`、`lstat(`、`readlink(` 这类调用在 MCP/ 里
/// 只出现在这里、MCPOutput、LiveClient、StdioTakeover 四个文件。
/// 有几个 Foundation 的路径函数会悄悄查文件系统（S2 拿 sandbox-exec 实测）：`standardizedFileURL`、
/// `NSString.standardizingPath`、不带 isDirectory 的 `URL(fileURLWithPath:)` 和 `appendingPathComponent(_:)`。
/// 照片文件夹的路径一律只当字符串处理（ProtectedPaths），这几个只用在数据目录上，或者干脆不用。
/// `appDataDir`（main.swift）现在只是路径，不建目录（§10.5）。
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

    // MARK: - sessions.json

    /// sessions.json 里的一条（app 侧栏「最近场次」，BatchStore.SessionEntry）。bookmark 不解析、不往外给。
    struct SessionEntry {
        let key: String
        let folder: String
        let name: String
        let photoCount: Int
        let lastAnalyzed: String
    }

    /// app 读 sessions.json 时也只认前 15 条（BatchStore.loadSessionsIndex），「最近场次」里就这么多。
    static let recentLimit = 15

    /// `entries` 按 sessions.json 的顺序（最近打开的在前），最多 15 条；`problem` 是读不了 / 解析不了时的原因；
    /// `missing`：数据目录或 sessions.json 不存在（从没开过 app 的机器就是这样），当作空列表，cull_list_sessions 加 warning（§10.1 第 2 行）。
    /// 解码和 app 一模一样（BatchStore.loadSessionsIndex：JSONDecoder 解 [SessionEntry]，一条坏了整个不认）：
    /// app 解不出来时「最近场次」是空的，这里也只能是空的 —— 列出 app 自己都不认的场次，STEP 2 打开时只会 session_not_found。
    static func readSessionsIndex() -> (entries: [SessionEntry], problem: String?, missing: Bool) {
        guard dataDirState().exists else { return ([], nil, true) }
        let url = dataDir.appendingPathComponent("sessions.json", isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return ([], nil, true)
        } catch {
            return ([], "读不了 sessions.json：\(error.localizedDescription)", false)
        }
        // bookmark 照样解成 Data（base64），不解析、不往外给
        guard let list = try? JSONDecoder().decode([BatchStore.SessionEntry].self, from: data) else {
            return ([], "sessions.json 解析不了（选片工具自己也读不出「最近场次」）", false)
        }
        let entries: [SessionEntry] = list.prefix(recentLimit).map { e in
            SessionEntry(key: e.key, folder: e.path, name: e.name, photoCount: e.photoCount, lastAnalyzed: e.lastAnalyzed)
        }
        return (entries, nil, false)
    }

    /// 预览输出目录（§10.3）：LABELGUI_MCP_OUT，默认 ~/Pictures/xuanpian-mcp。这里只算路径（isDirectory 显式给，
    /// 不去 stat）：第一次存图时才建、才做 §4.2 的检查（STEP 3a 的 MCPOutput）。
    static var outputRoot: URL {
        if let out = ProcessInfo.processInfo.environment["LABELGUI_MCP_OUT"], !out.isEmpty {
            return URL(fileURLWithPath: out, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Pictures/xuanpian-mcp", isDirectory: true)
    }

    // MARK: - session 参数（§4.2；v1 比的是 app 当前打开的那一场，§10.2「session 怎么比」）

    enum SessionArg: Equatable {
        /// 16 位十六进制（大写也认，转成小写）。
        case key(String)
        /// 按字符串标准化后的绝对路径（`~` 已展开），和按它算出来的 key。
        case path(String, key: String)
    }

    /// 16 位十六进制当 key；否则必须是绝对路径（`~` 开头的先展开）。只按字符串解析，不碰文件系统。nil = 两样都不是。
    static func parseSession(_ raw: String) -> SessionArg? {
        // 比 PATH_MAX 长的不可能是一个文件夹（lstat 也只会回 ENAMETOOLONG），不往下算
        guard raw.utf8.count <= Int(PATH_MAX) else { return nil }
        let hex = raw.utf8.count == 16 && raw.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        if hex { return .key(raw.lowercased()) }
        guard !raw.utf8.contains(0), let path = ProtectedPaths.standardized(raw, home: NSHomeDirectory()) else { return nil }
        return .path(path, key: sessionKey(forPath: path))
    }

    /// 和 BatchStore.sessionKey(for:) 同一个 FNV-1a，算在文件 URL 的 path 上（那是分解形式：NFC、NFD 两种写法得到同一个
    /// key，S2 实测），只是不经 `standardizedFileURL`（它会查文件系统）——路径已经按字符串标准化过了。没有 `/private/…`
    /// 这种要靠文件系统才定得下来的写法时，两边算出来一样（--mcp-selftest 对照）；对不上的由 session(_:matches:) 按路径再比。
    static func sessionKey(forPath path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in URL(fileURLWithPath: path, isDirectory: true).path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// app 自己怎么算 key（BatchStore.sessionKey(for:)，走 standardizedFileURL，会查文件系统）：只给 --mcp-selftest 对照用，
    /// 只拿根下不存在的路径调。
    static func appSessionKey(forPath path: String) -> String {
        BatchStore.sessionKey(for: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// 这个 session 参数是不是指 (key, folder) 那一场：key 相同；或者两边路径按字符串标准化、NFC、不分大小写以后相同
    /// （大小写不一样 key 就不一样，APFS 默认却是同一个文件夹）；再不行，两边都不在受保护位置时各自逐段解析符号链接
    /// 再比（模型常把 /tmp/x 写成 /private/tmp/x），每边最多等 1 s。受保护位置上的只按 key 和字符串比，不碰文件系统。
    static func session(_ arg: SessionArg, matches key: String, folder: String) -> Bool {
        session(arg, matches: key, folder: folder) { path in
            WalkJob.shared(path).wait(until: .now() + 1).flatMap(comparisonPath)
        }
    }

    /// 同上，符号链接怎么解析由 `resolve` 给（--mcp-selftest 用假的文件系统）。
    static func session(_ arg: SessionArg, matches key: String, folder: String, resolve: (String) -> String?) -> Bool {
        switch arg {
        case .key(let k):
            return k == key
        case .path(let path, let k):
            if k == key { return true }
            let home = NSHomeDirectory()
            guard let a = ProtectedPaths.comparisonKey(path, home: home),
                  let b = ProtectedPaths.comparisonKey(folder, home: home) else { return false }
            if a == b { return true }
            guard !ProtectedPaths.isProtected(path), !ProtectedPaths.isProtected(folder),
                  let ra = resolve(path), let rb = resolve(folder) else { return false }
            return ra == rb
        }
    }

    /// 逐段解析完的路径拿来比的形式；走进受保护位置、解析失败 = nil（不比）。
    static func comparisonPath(_ w: Walk) -> String? {
        switch w {
        case .found(let p, _), .missing(let p): return ProtectedPaths.comparisonKey(p, home: "")
        case .protected, .failed: return nil
        }
    }

    // MARK: - 照片文件夹在不在（cull_list_sessions 的 folder_online，§3.1、§10.5）

    struct FolderCheck: Equatable {
        /// true 在线（是个文件夹）；false 不在（或者那里是个文件）；nil 没查（受保护位置）、查不了或超时。
        let online: Bool?
        /// 落在受保护位置：字符串一看就是，或者逐段走的时候某个符号链接指了进去。
        let protected: Bool
    }

    static func folderOnline(_ folder: String) -> FolderCheck {
        foldersOnline([folder])[0]
    }

    /// 一次查一批（§3.1：每个文件夹 1 s、总共不超过 3 s，超时记 null）。先按字符串查受保护前缀，是就不碰；
    /// 其余各在后台逐段 lstat（walk）：每一段、每个符号链接的目标都先过一遍 ProtectedPaths，链接指进受保护位置就停下，
    /// 也算受保护 —— 光 fileExists 会跟着链接 stat 到外置盘上去。同时开始，所以一般 1 s 内就都有结果。
    /// `probe` 只有 --mcp-selftest 换（一个卡住的假 lstat，测等不到的那条路）。
    static func foldersOnline(_ folders: [String], perFolder: Double = 1, total: Double = 3,
                              probe: @escaping (String) -> Node = lstatNode) -> [FolderCheck] {
        let start = DispatchTime.now()
        let jobs: [WalkJob?] = folders.map { ProtectedPaths.isProtected($0) ? nil : WalkJob.shared($0, probe: probe) }
        let deadline = start + min(perFolder, total)
        return jobs.map { job -> FolderCheck in
            guard let job else { return FolderCheck(online: nil, protected: true) }
            switch job.wait(until: deadline) {
            case .found(_, let isDirectory): return FolderCheck(online: isDirectory, protected: false)
            case .missing: return FolderCheck(online: false, protected: false)
            case .protected: return FolderCheck(online: nil, protected: true)
            case .failed, .none: return FolderCheck(online: nil, protected: false)
            }
        }
    }

    // MARK: - 逐段解析（不用 realpath：它会跟着链接 stat 进受保护位置）

    /// 一段路径在文件系统里是什么（lstat，不跟链接）。
    enum Node: Equatable {
        case directory
        case other
        case symlink(String)
        case missing
        /// lstat 出别的错（没权限之类）、读不出链接目标。
        case unreadable
    }

    enum Walk: Equatable {
        /// 全部解析完：解析后的路径（没有符号链接），最后一段是不是文件夹。
        case found(String, isDirectory: Bool)
        /// 走到某一段不存在：已经解析的前缀 + 剩下没走的原样拼上。
        case missing(String)
        /// 某一段、或者某个链接的目标落进受保护位置：停在它前面，没碰它。
        case protected
        /// 链接太多（多半是环）、lstat 出错、不是绝对路径、比 PATH_MAX 长。
        case failed
    }

    /// 从根开始一段段走：每一段先查 ProtectedPaths 再 lstat；是符号链接就把目标拼回去接着走（绝对的从根重来，
    /// 最多 32 个）；`..` 回到上一层（已经解析过的前缀里没有链接，所以按字符串弹出就是对的）。
    /// `probe` 就是 lstat：--mcp-selftest 换成假的文件系统，断言受保护的路径一次都没被 probe 过。
    static func walk(_ path: String, homes: [String] = ProtectedPaths.defaultHomes, probe: (String) -> Node) -> Walk {
        guard let parts = ProtectedPaths.rawComponents(path, home: homes.first ?? "") else { return .failed }
        var pending: [Substring] = parts.reversed()
        var resolved: [Substring] = []
        var isDirectory = true
        var links = 0
        while let part = pending.popLast() {
            if part == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                isDirectory = true
                continue
            }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            // 超过 PATH_MAX 的 lstat 只会回 ENAMETOOLONG；先停下，也给每段都要过一遍的 isProtected 封个顶
            guard candidate.utf8.count <= Int(PATH_MAX) else { return .failed }
            if ProtectedPaths.isProtected(candidate, homes: homes) { return .protected }
            switch probe(candidate) {
            case .directory:
                resolved.append(part)
                isDirectory = true
            case .other:
                resolved.append(part)
                isDirectory = false
            case .missing:
                let rest: [Substring] = resolved + [part] + pending.reversed()
                return .missing("/" + rest.joined(separator: "/"))
            case .unreadable:
                return .failed
            case .symlink(let target):
                links += 1
                // 相对的目标接在链接所在的目录后面；`~` 在链接里只是一个普通的名字，前面补 "/" 就不会被当成 home
                guard links <= 32, let more = ProtectedPaths.rawComponents("/" + target, home: "") else { return .failed }
                if target.hasPrefix("/") { resolved = [] }
                pending.append(contentsOf: more.reversed())
            }
        }
        return .found("/" + resolved.joined(separator: "/"), isDirectory: isDirectory)
    }

    static func lstatNode(_ path: String) -> Node {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            return .directory
        case S_IFLNK:
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            let n = readlink(path, &buf, buf.count)
            guard n > 0 else { return .unreadable }
            return .symlink(String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self))
        default:
            return .other
        }
    }
}

/// 后台跑的一次逐段解析（MCPPaths.walk + lstat）。同一个路径同时只跑一个：并行的调用（Claude Code 会并行调只读工具）
/// 等同一个结果；卡在没响应的网络位置上的那个线程就让它卡着（杀不掉），再调也不会越积越多，等不到的记 null。
final class WalkJob: @unchecked Sendable {
    private static let registry = Registry()
    /// 进去一次、做完出来一次；DispatchGroup 可以有好几个人同时等。
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var value: MCPPaths.Walk?

    /// `probe` 只有 --mcp-selftest 换；同一个路径在跑的时候再要，拿到的是正在跑的那一个（不管传的 probe）。
    static func shared(_ path: String, probe: @escaping (String) -> MCPPaths.Node = MCPPaths.lstatNode) -> WalkJob {
        let (job, fresh) = registry.job(for: path)
        if fresh {
            DispatchQueue.global(qos: .userInitiated).async {
                let v = MCPPaths.walk(path, probe: probe)
                job.lock.lock()
                job.value = v
                job.lock.unlock()
                registry.finish(path)
                job.group.leave()
            }
        }
        return job
    }

    private init() { group.enter() }

    /// 到 deadline 还没做完回 nil。
    func wait(until deadline: DispatchTime) -> MCPPaths.Walk? {
        guard group.wait(timeout: deadline) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var running: [String: WalkJob] = [:]

        /// 这个路径正在跑就给那一个（fresh = false），没有就新建一个（fresh = true，调用方负责起它）。
        func job(for path: String) -> (WalkJob, Bool) {
            lock.lock()
            defer { lock.unlock() }
            if let job = running[path] { return (job, false) }
            let job = WalkJob()
            running[path] = job
            return (job, true)
        }

        func finish(_ path: String) {
            lock.lock()
            running[path] = nil
            lock.unlock()
        }
    }
}
