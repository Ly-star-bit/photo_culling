import Foundation

/// 受系统隐私保护的位置（DESIGN §10.4 第 4 条、§9.6c 第 1 条、§4.3）：照片文件夹落在这些地方时，第一次访问会以
/// 访问者（--mcp 就是宿主终端）的名义弹系统授权框，所以 `--mcp` 连 stat 都不做。
/// **只按字符串判断，不碰文件系统**：不 stat、不 realpath、不解析 bookmark —— 连 `standardizedFileURL`、
/// `NSString.standardizingPath`、不带 isDirectory 的 `URL(fileURLWithPath:)` 都不用，它们都会去文件系统里查一下
/// （S2 拿 sandbox-exec 实测过）。没有任何依赖（只用 Foundation 的 NFC 和大小写折叠），cull_list_sessions（MCPPaths.folderOnline）、
/// cull.preview、session.open 三处共用；`--mcp` 用它预检，app 一侧是权威判断。
///
/// 受保护的：home 下的 Desktop、Documents、Downloads、Library（整个算：iCloud 云盘 Mobile Documents、第三方网盘
/// CloudStorage、其他 app 的容器）；根下的 /Volumes（外置盘、网络卷、其他分区）、/Network、/net；根下所有 `.` 开头的
/// （/.vol 按 inode 能指到任何文件，/.nofollow/…、/.resolve/<n>/… 是内核认的前缀，后面接的就是真路径：
/// /.nofollow/Users/x/Desktop 就是桌面）；任何 .photoslibrary（照片图库包本身和里面）。
/// - 不分大小写，而且按 APFS 的规矩比：先 NFC，再做 Unicode 完整的大小写折叠（`folding(.caseInsensitive)`），
///   不是 `lowercased()` —— APFS 把 ſ 当 s、ß 当 ss、ﬆ 当 st（S2 在 APFS 上建目录再 lstat 各种写法实测，
///   和 folding 的结果一致；İ、全角字母两边都不折），/Users/x/Deſktop 就是桌面。`//`、`.`、结尾的 `/` 去掉；
///   `..` 按内核走路径的顺序看：一段段走过去（`..` 回到上一层），**走过的任何一处**落进受保护位置就算 ——
///   /Users/x/Desktop/../y 最后落在 /Users/x/y，可内核要先进一趟桌面。
/// - /System/Volumes/Data/… 是数据卷的 firmlink，/private/var、/private/tmp、/private/etc 和 /var、/tmp、/etc 是一回事：
///   去掉前缀再看一遍。
/// - /Users/<任何人>/Desktop… 也算（不只自己的 home）：宁可多算，home 取得不对时也不会漏。
/// - 判断不了的一律算受保护（不是绝对路径、`~别人/…`、空串）：这个函数的用处是"不去碰"，多算只是少一次在线检查。
/// - 管不到的：路径中间的符号链接（/Users/x/Pictures/shoot → /Volumes/SD）光看字符串看不出来，
///   MCPPaths.folderOnline 逐段 lstat 时每一段、每个链接目标都再过一次这里。
enum ProtectedPaths {
    /// home 下受保护的几个目录（折叠后比较，ASCII 折叠就是小写）。
    static let homeFolders: Set<String> = ["desktop", "documents", "downloads", "library"]
    /// 根下整个受保护的目录（折叠后比较）；另外根下 `.` 开头的一律算（protectedKeys）。
    static let rootFolders: Set<String> = ["volumes", "network", "net"]

    /// 默认用的 home：NSHomeDirectory()（实测不认 $HOME，取的是用户记录里的家目录）；$HOME 不一样时两个都算。
    static var defaultHomes: [String] {
        var homes = [NSHomeDirectory()]
        if let env = ProcessInfo.processInfo.environment["HOME"], env.hasPrefix("/"), !homes.contains(env) {
            homes.append(env)
        }
        return homes
    }

    static func isProtected(_ path: String) -> Bool {
        isProtected(path, homes: defaultHomes)
    }

    /// `homes` 里的每一个都当成 home（`~` 用第一个展开）。
    static func isProtected(_ path: String, homes: [String]) -> Bool {
        guard let raw = rawComponents(path, home: homes.first ?? "") else { return true }
        let homeKeys: [[String]] = homes.compactMap { h -> [String]? in
            guard let parts = rawComponents(h, home: "") else { return nil }
            let k = Array(dropPrivate(keys(resolveDots(parts))[...]))
            return k.isEmpty ? nil : k
        }
        // 每段只折叠一次；走过的每一处都要看，但 .photoslibrary 只用看刚走进去的那一段（之前的早看过了）
        var walked: [String] = []
        for part in raw {
            if part == ".." {
                if !walked.isEmpty { walked.removeLast() }
                continue
            }
            let k = key(part)
            if k.hasSuffix(".photoslibrary") { return true }
            walked.append(k)
            if protectedKeys(walked[...], homes: homeKeys) { return true }
        }
        return false
    }

    /// 只按字符串标准化成绝对路径：`~`、`~/…` 用 home 展开，去掉 `//`、`.`、结尾的 `/`，按字符串消掉 `..`（不解析符号链接，
    /// 根上的 `..` 停在根上）。原来的 Unicode 形式不动（session key 是按原始字节算的）。判断不了（不是绝对路径、`~别人`）回 nil。
    static func standardized(_ path: String, home: String) -> String? {
        guard let raw = rawComponents(path, home: home) else { return nil }
        return "/" + resolveDots(raw).joined(separator: "/")
    }

    /// 比较用的形式：标准化 + 和 APFS 一样折叠（key(_:)）。两个路径这个相同，就当成同一个文件夹（APFS 默认不分大小写）。
    static func comparisonKey(_ path: String, home: String) -> String? {
        standardized(path, home: home).map { key(Substring($0)) }
    }

    /// 一段（或整条）路径比较用的形式：NFC → 大小写完整折叠 → 再 NFC（折出来的结果也按同一种形式比）。
    static func key(_ s: Substring) -> String {
        String(s).precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    // MARK: - 内部

    /// 展开 `~` 以后按 `/` 切开，去掉空段和 `.`，`..` 原样留着。nil = 判断不了。
    static func rawComponents(_ path: String, home: String) -> [Substring]? {
        var p = Substring(path)
        if p == "~" || p.hasPrefix("~/") {
            guard home.hasPrefix("/") else { return nil }
            p = Substring(home + "/" + p.dropFirst())
        } else if p.hasPrefix("~") {
            return nil  // ~别人：要查用户记录才知道在哪，不猜
        }
        guard p.hasPrefix("/") else { return nil }
        return p.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
    }

    /// 按字符串消掉 `..`：上一段弹出，根上的停在根上。
    static func resolveDots(_ parts: [Substring]) -> [Substring] {
        var out: [Substring] = []
        for part in parts {
            if part == ".." {
                if !out.isEmpty { out.removeLast() }
            } else {
                out.append(part)
            }
        }
        return out
    }

    private static func keys(_ parts: [Substring]) -> [String] {
        parts.map(key)
    }

    /// /private/var、/private/tmp、/private/etc → /var、/tmp、/etc。用切片，不复制。
    private static func dropPrivate(_ c: ArraySlice<String>) -> ArraySlice<String> {
        guard c.count >= 2, c[c.startIndex] == "private" else { return c }
        return ["var", "tmp", "etc"].contains(c[c.startIndex + 1]) ? c.dropFirst() : c
    }

    /// 一个已经消掉 `..` 的路径（折叠过的各段）是不是落在受保护位置。.photoslibrary 由调用方逐段看。
    private static func protectedKeys(_ path: ArraySlice<String>, homes: [[String]]) -> Bool {
        let c = dropPrivate(path)
        guard let first = c.first else { return false }  // 根本身不算
        if rootFolders.contains(first) || first.hasPrefix(".") { return true }
        let i = c.startIndex
        if c.count >= 3, first == "system", c[i + 1] == "volumes", c[i + 2] == "data" {
            return protectedKeys(c.dropFirst(3), homes: homes)
        }
        if c.count >= 3, first == "users", homeFolders.contains(c[i + 2]) { return true }
        for h in homes where c.count > h.count && c.prefix(h.count).elementsEqual(h) {
            if homeFolders.contains(c[i + h.count]) { return true }
        }
        return false
    }
}
