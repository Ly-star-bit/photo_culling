import Foundation

/// --mcp-selftest 的 S2 部分（MCPSelfTest.run 调）：
/// 5. ProtectedPaths：手写期望值的路径表（大小写、结尾斜杠、`..` 进出受保护目录、Desktopx 这种邻居、iCloud / 网盘、
///    /Volumes 本身、.PhotosLibrary、NFC / NFD、非 ASCII 的 home、/private 别名、firmlink、相对路径）。
/// 6. session 参数：解析（key / 路径 / 都不是）、key 和 BatchStore.sessionKey(for:) 对照、按路径比（NFC、大小写、符号链接）。
/// 7. 逐段解析（MCPPaths.walk）：在假的文件系统上走，断言受保护的路径一次都没被 lstat 过；WalkJob 拿一个卡住的假 lstat
///    测「同一个路径共用一次」「等不到回 null」「做完再要是新的一次」。
/// 8. collage_list_templates 的静态表：和 CollageTemplates.builtin 一致、照片格数对得上、画布别名正好盖住全部画布。
/// 只有第 6 组对照 key 时调了 MCPPaths.appSessionKey（就是 BatchStore.sessionKey(for:)，它会查文件系统），用的是根下
/// 不存在的 /nonexistent-xp-mcp-selftest/…；其余都是纯函数。
extension MCPSelfTest {
    typealias Check = (Bool, @autoclosure () -> String) -> Void

    /// --json 时每条受保护路径的判断打一行（kind=protected），mcp_smoke.py 数条数、看有没有失败的。
    static func pathChecks(_ check: Check, dump: Bool) {
        protectedPathChecks(check, dump: dump)
        sessionChecks(check)
        walkChecks(check)
        walkJobChecks(check)
        templateChecks(check)
    }

    // MARK: 5. ProtectedPaths

    private static let home = "/Users/tester"

    private static let protectedCases: [(String, Bool)] = [
        ("/Users/tester/Desktop", true), ("/Users/tester/Desktop/", true), ("/Users/tester/Desktop/20261021/a.jpg", true),
        ("/Users/tester//Desktop///x", true), ("/Users/tester/./Desktop/x", true), ("/Users/tester/desktop/x", true),
        ("/USERS/TESTER/DESKTOP", true), ("/Users/tester/Documents/x", true), ("/Users/tester/Downloads", true),
        ("/Users/tester/Library", true), ("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/shoot", true),
        ("/Users/tester/Library/CloudStorage/Dropbox-个人/shoot", true), ("/Users/tester/Library/Containers/com.x/Data", true),
        ("/Users/tester/Desktopx/a", false), ("/Users/tester/Desktop2", false), ("/Users/tester/MyDesktop", false),
        ("/Users/tester/Desktop /x", false), ("/Users/tester/Pictures/20261021", false), ("/Users/tester", false),
        ("/Users/tester/", false), ("/Users", false), ("/", false), ("//", false),
    ]

    private static let protectedDotCases: [(String, Bool)] = [
        ("/Users/tester/Pictures/../Desktop/x", true), ("/Users/tester/Desktop/../Pictures/x", true),
        ("/Users/tester/Pictures/a/../../Downloads", true), ("/Users/tester/Pictures/./a/../b", false),
        ("/../Users/tester/Desktop", true), ("/../../Users/tester/Pictures", false), ("/Users/tester/Pictures/..", false),
        ("/Volumes", true), ("/Volumes/", true), ("/Volumes/SD/DCIM/100", true), ("/volumes/sd", true), ("/VolumesX/a", false),
        ("/Volumes/../Users/tester/Pictures", true), ("/Network/Servers/nas/photos", true), ("/net/nas/photos", true),
        ("/network2/x", false), ("/netx", false), ("/.vol/16777220/2", true),
        // 根下 `.` 开头的一律算：/.nofollow、/.resolve/<n> 是内核认的前缀，后面接的就是真路径
        ("/.nofollow/Users/tester/Desktop/x", true), ("/.nofollow/private/tmp/x", true), ("/.resolve/1/Users/tester/Pictures", true),
        ("/.file/id=1.2", true), ("/x/../.nofollow/y", true), ("/System/Volumes/Data/.nofollow/x", true),
        ("/Users/tester/Pictures/.hidden/x", false), ("/Users/tester/.x/Desktop", false),
    ]

    /// APFS 的大小写折叠（不是 lowercased）：ſ→s、ß→ss、ﬆ/ﬅ→st、K→k；İ、全角字母不折（S2 在 APFS 上实测过这几种）。
    private static let protectedFoldCases: [(String, Bool)] = [
        ("/Users/tester/De\u{17F}ktop/x", true), ("/Users/tester/DE\u{17F}KTOP", true), ("/Users/tester/Documen\u{17F}", false),
        ("/Users/tester/Downloa\u{17F}/x", false), ("/Users/tester/Do\u{17F}uments", false),
        ("/Users/tester/Documents\u{17F}", false), ("/U\u{17F}ers/tester/Documents/x", true), ("/U\u{17F}ers/other/Downloads", true),
        ("/Volume\u{17F}/SD", true), ("/Network\u{17F}", false), ("/Net\u{212A}/x", false), ("/Networ\u{212A}/x", true),
        ("/Users/tester/Des\u{212A}top", true), ("/Users/tester/Pictures/X.photo\u{17F}library/a", true),
        ("/Sy\u{FB06}em/Volumes/Data/Users/tester/Desktop/x", true), ("/Sy\u{FB05}em/Volumes/Data/Volumes/SD", true),
        ("/Sy\u{17F}tem/Volume\u{17F}/Data/Users/tester/Download\u{17F}", true),
        ("/Users/tester/Deskto\u{FF50}", false), ("/Users/tester/L\u{130}brary", false), ("/\u{FF56}olumes/x", false),
    ]

    private static let protectedMiscCases: [(String, Bool)] = [
        ("/Users/tester/Pictures/Photos Library.photoslibrary", true),
        ("/Users/tester/Pictures/Photos Library.photoslibrary/originals/A/1.heic", true),
        ("/Users/tester/Pictures/X.PhotosLibrary/a", true), ("/Users/tester/Pictures/photoslibrary/a", false),
        ("/Users/tester/Pictures/a.photoslibrary.bak/x", false),
        ("/System/Volumes/Data/Users/tester/Desktop/x", true), ("/System/Volumes/Data/Users/tester/Pictures/x", false),
        ("/System/Volumes/Data/Volumes/SD", true), ("/system/volumes/data/users/tester/documents", true),
        ("/System/Volumes/Preboot/x", false), ("/Users/someoneelse/Desktop/x", true), ("/Users/someoneelse/Pictures/x", false),
        ("/private/tmp/shoot", false), ("/tmp/shoot", false), ("/private/var/folders/x/T/shoot", false),
        ("~/Desktop/x", true), ("~/Pictures/x", false), ("~", false), ("~/", false), ("~/Pictures/../Documents", true),
        ("~someone/Desktop", true), ("~someone/Pictures", true), ("relative/Desktop", true), ("Pictures/x", true),
        ("", true), ("./x", true), (" /Users/tester/Pictures", true),
    ]

    /// 自己给 home 的：非 ASCII、NFC / NFD 两边不一样、/private 别名、多个 home、没有 home、home 是根。
    private static let protectedHomeCases: [(String, [String], Bool)] = [
        ("/Users/张三/Desktop/x", ["/Users/张三"], true), ("/Users/张三/Pictures/x", ["/Users/张三"], false),
        ("/home/Jose\u{301}/Desktop/x", ["/home/Jos\u{e9}"], true), ("/home/Jos\u{e9}/Downloads", ["/home/Jose\u{301}"], true),
        ("/home/JOS\u{c9}/desktop", ["/home/jos\u{e9}"], true), ("/home/jose/Desktop", ["/home/jos\u{e9}"], false),
        ("/var/root/Desktop/x", ["/var/root"], true), ("/private/var/root/Desktop/x", ["/var/root"], true),
        ("/var/root/Desktop/x", ["/private/var/root"], true), ("/var/root/Pictures/x", ["/var/root"], false),
        ("/home/a/Desktop", ["/Users/tester", "/home/a"], true), ("~/Desktop", ["/home/a"], true), ("~/x", ["/home/a"], false),
        ("/home/a/Desktop", [], false), ("~/Desktop", [], true), ("/x/Desktop", ["/"], false), ("/Desktop", ["/"], false),
        ("/home/a/Library/Mobile Documents", ["/home/a/"], true), ("/home/a/Library", ["/home//a/."], true),
    ]

    private static func protectedPathChecks(_ check: Check, dump: Bool) {
        var rows: [(String, [String], Bool)] = []
        for (path, want) in protectedCases + protectedDotCases + protectedMiscCases + protectedFoldCases {
            rows.append((path, [home], want))
        }
        rows += protectedHomeCases
        for (path, homes, want) in rows {
            let got = ProtectedPaths.isProtected(path, homes: homes)
            check(got == want, "受保护位置 \(path.debugDescription)（home \(homes)）：期望 \(want)，实际 \(got)")
            if dump {
                var row: [String: Any] = ["kind": "protected", "path": path, "homes": homes]
                row["expected"] = want
                row["actual"] = got
                print(MCPJSON.string(row))
            }
        }
        // 默认的 home（NSHomeDirectory，再加 $HOME）
        let realHome = NSHomeDirectory()
        check(ProtectedPaths.isProtected(realHome + "/Desktop/x") && ProtectedPaths.isProtected("~/Documents"),
              "默认 home 下的桌面、文稿算受保护（\(realHome)）")
        check(!ProtectedPaths.isProtected(realHome + "/Pictures/x"), "默认 home 下的 Pictures 不算")
        // 按字符串标准化
        check(ProtectedPaths.standardized("/Users/t//a/./b/../c/", home: home) == "/Users/t/a/c", "standardized 去掉 // . .. 结尾 /")
        check(ProtectedPaths.standardized("~/x", home: "/Users/t") == "/Users/t/x", "standardized 展开 ~")
        check(ProtectedPaths.standardized("/../..", home: home) == "/", "standardized：根上的 .. 停在根上")
        check(ProtectedPaths.standardized("x/y", home: home) == nil && ProtectedPaths.standardized("~u/x", home: home) == nil,
              "standardized：相对路径、~别人 → nil")
        check(ProtectedPaths.standardized("/a/Jos\u{e9}", home: home)?.unicodeScalars.count == 7,
              "standardized 不改 Unicode 形式（key 按原字节算）")
        let nfc = ProtectedPaths.comparisonKey("/Users/T/Jos\u{e9}", home: home)
        let nfd = ProtectedPaths.comparisonKey("/users/t/JOSE\u{301}/", home: home)
        check(nfc != nil && nfc == nfd, "comparisonKey：NFC / NFD、大小写、结尾斜杠都当成一样")
        let fold1 = ProtectedPaths.comparisonKey("/a/Stra\u{DF}e/De\u{17F}k", home: home)
        let fold2 = ProtectedPaths.comparisonKey("/A/STRASSE/desk", home: home)
        check(fold1 != nil && fold1 == fold2, "comparisonKey 按 APFS 折叠：ß = ss、ſ = s")
        check(ProtectedPaths.comparisonKey("/a/\u{130}x", home: home) != ProtectedPaths.comparisonKey("/a/ix", home: home),
              "comparisonKey：İ 和 i 不一样（APFS 也不一样）")
    }

    // MARK: 6. session 参数

    private static func sessionChecks(_ check: Check) {
        check(MCPPaths.parseSession("0123456789abcdef") == .key("0123456789abcdef"), "16 位十六进制当 key")
        check(MCPPaths.parseSession("0123456789ABCDEF") == .key("0123456789abcdef"), "大写的十六进制也认，转小写")
        let tooLong = "/" + String(repeating: "a/", count: 600)
        for bad in ["0123456789abcdeg", "0123456789abcde", "\u{ff10}123456789abcdef", "", "shoot", "Pictures/shoot", "~u/x", "/a\u{0}b", tooLong] {
            check(MCPPaths.parseSession(bad) == nil, "不是 key 也不是绝对路径：\(bad.debugDescription)")
        }
        let p = "/Users/t/Pictures/shoot"
        check(MCPPaths.parseSession(p + "/") == .path(p, key: MCPPaths.sessionKey(forPath: p)), "绝对路径：去掉结尾 / 再算 key")
        let homeShoot = NSHomeDirectory() + "/Pictures/shoot"
        check(MCPPaths.parseSession("~/Pictures/shoot") == .path(homeShoot, key: MCPPaths.sessionKey(forPath: homeShoot)), "~ 先展开")
        // key 和 BatchStore 同一个算法（fixture 那一场的 key 是 --session-key 算出来的）
        check(MCPPaths.sessionKey(forPath: "/tmp/labelgui-fixture-photot") == "0e8f164348cb21b4",
              "fixture 场次的 key 和 --session-key 一样")
        let clean: [String] = ["/nonexistent-xp-mcp-selftest/20261021", "/nonexistent-xp-mcp-selftest/婚礼 照片/第一天",
                               "/nonexistent-xp-mcp-selftest/Jos\u{e9}", "/nonexistent-xp-mcp-selftest/Jose\u{301}",
                               "/nonexistent-xp-mcp-selftest/한국어 사진", "/nonexistent-xp-mcp-selftest/ﬁ Å ǅ"]
        for path in clean {
            let mine = MCPPaths.sessionKey(forPath: path)
            let app = MCPPaths.appSessionKey(forPath: path)
            check(mine == app, "key 和 BatchStore.sessionKey 一样：\(path)（\(mine) / \(app)）")
        }
        check(MCPPaths.sessionKey(forPath: clean[2]) == MCPPaths.sessionKey(forPath: clean[3]), "NFC、NFD 两种写法同一个 key")

        // 按路径比：假的文件系统上解析符号链接
        let resolve: (String) -> String? = { path in
            MCPPaths.comparisonPath(MCPPaths.walk(path, homes: [home], probe: fakeProbe))
        }
        func matches(_ raw: String, _ folder: String) -> Bool {
            guard let arg = MCPPaths.parseSession(raw) else { return false }
            return MCPPaths.session(arg, matches: MCPPaths.sessionKey(forPath: folder), folder: folder, resolve: resolve)
        }
        let shoot = "/Users/tester/Pictures/shoot"
        check(matches(MCPPaths.sessionKey(forPath: shoot), shoot), "key 对得上")
        check(!matches("0123456789abcdef", shoot), "key 对不上")
        check(matches(shoot + "/", shoot) && matches("/Users/tester//Pictures/./shoot", shoot), "路径写法不一样（结尾 /、//、.）")
        check(matches("/users/tester/pictures/SHOOT", shoot), "大小写不一样（APFS 默认不分）")
        check(matches("/Users/tester/Pictures/Jose\u{301}", "/Users/tester/Pictures/Jos\u{e9}"), "NFD 对 NFC")
        check(matches("/private/tmp/x", "/tmp/x") && matches("/tmp/x", "/private/tmp/x"), "/tmp ↔ /private/tmp（解析符号链接）")
        check(matches("/Users/tester/Pictures/toShoot", shoot), "指向这一场的符号链接")
        check(!matches("/Users/tester/Pictures/other", shoot), "别的文件夹对不上")
        check(!matches("/Users/tester/Pictures/toSD", "/Volumes/SD/DCIM"), "指进受保护位置的链接不解析，只能按 key / 字符串对")
        check(matches("/Volumes/SD/DCIM", "/volumes/sd/dcim"), "受保护位置按字符串照样对得上（不碰文件系统）")
    }

    // MARK: 7. 逐段解析

    /// 假的文件系统：路径 → lstat 的结果（没列出来的 = 不存在）。
    private static let fakeFS: [String: MCPPaths.Node] = [
        "/Users": .directory, "/Users/tester": .directory, "/Users/tester/Pictures": .directory,
        "/Users/tester/Pictures/shoot": .directory, "/Users/tester/Pictures/file.jpg": .other,
        "/Users/tester/Pictures/toSD": .symlink("/Volumes/SD/DCIM"), "/Users/tester/Pictures/toDesk": .symlink("../Desktop/shoot"),
        "/Users/tester/Pictures/toShoot": .symlink("shoot"), "/Users/tester/Pictures/toOpt": .symlink("/opt/data/real"),
        "/Users/tester/Pictures/tilde": .symlink("~/shoot"), "/Users/tester/Pictures/locked": .unreadable,
        "/Users/tester/Pictures/toLib": .symlink("/Users/tester/Pictures/Photos Library.photoslibrary/originals"),
        "/Users/tester/Pictures/toDeskCase": .symlink("/USERS/TESTER/DESKTOP"),
        "/Users/tester/Pictures/hop1": .symlink("hop2"), "/Users/tester/Pictures/hop2": .symlink("/tmp/x"),
        "/opt": .directory, "/opt/data": .directory, "/opt/data/real": .directory, "/opt/data/y": .directory,
        "/tmp": .symlink("private/tmp"), "/private": .directory, "/private/tmp": .directory, "/private/tmp/x": .directory,
        "/loopA": .symlink("/loopB"), "/loopB": .symlink("/loopA"),
    ]

    /// 和 APFS 默认一样不分大小写。
    private static let fakeFSLower: [String: MCPPaths.Node] =
        Dictionary(uniqueKeysWithValues: fakeFS.map { ($0.key.lowercased(), $0.value) })

    private static func fakeProbe(_ path: String) -> MCPPaths.Node {
        fakeFSLower[path.lowercased()] ?? .missing
    }

    private static let walkCases: [(String, MCPPaths.Walk)] = [
        ("/Users/tester/Pictures/shoot", .found("/Users/tester/Pictures/shoot", isDirectory: true)),
        ("/Users/tester/Pictures/shoot/", .found("/Users/tester/Pictures/shoot", isDirectory: true)),
        ("/Users/tester/Pictures/file.jpg", .found("/Users/tester/Pictures/file.jpg", isDirectory: false)),
        ("/Users/tester/Pictures/file.jpg/x", .missing("/Users/tester/Pictures/file.jpg/x")),
        ("/Users/tester/Pictures/nope/deeper", .missing("/Users/tester/Pictures/nope/deeper")),
        ("/Users/tester/Pictures/toSD", .protected), ("/Users/tester/Pictures/toSD/100", .protected),
        ("/Users/tester/Pictures/toDesk", .protected), ("/Users/tester/Pictures/toLib", .protected),
        ("/Users/tester/Pictures/toDeskCase", .protected), ("/Users/tester/Desktop/shoot", .protected),
        ("/Volumes/SD", .protected),
        ("/Users/tester/Pictures/toShoot", .found("/Users/tester/Pictures/shoot", isDirectory: true)),
        ("/Users/tester/Pictures/toOpt/../y", .found("/opt/data/y", isDirectory: true)),
        ("/Users/tester/Pictures/hop1", .found("/private/tmp/x", isDirectory: true)),
        ("/tmp/x", .found("/private/tmp/x", isDirectory: true)), ("/tmp/nope", .missing("/private/tmp/nope")),
        ("/Users/tester/Pictures/tilde", .missing("/Users/tester/Pictures/~/shoot")),
        ("/loopA", .failed), ("/Users/tester/Pictures/locked/x", .failed), ("relative/x", .failed), ("/", .found("/", isDirectory: true)),
    ]

    private static func walkChecks(_ check: Check) {
        var probed: [String] = []
        for (path, want) in walkCases {
            let got = MCPPaths.walk(path, homes: [home]) { p in
                probed.append(p)
                return fakeProbe(p)
            }
            check(got == want, "逐段解析 \(path)：期望 \(want)，实际 \(got)")
        }
        let touched = probed.filter { ProtectedPaths.isProtected($0, homes: [home]) }
        check(!probed.isEmpty && touched.isEmpty, "逐段解析从没 lstat 过受保护的路径（\(probed.count) 次 lstat）：\(touched)")
        // 每一段都是文件夹的假文件系统上走一条 2,000 字节的路径：走到超过 PATH_MAX 那一段就停（不 lstat 它）
        var deep = 0
        let long = MCPPaths.walk("/" + String(repeating: "ab/", count: 700), homes: [home]) { _ in
            deep += 1
            return .directory
        }
        check(long == .failed && deep == 341, "比 PATH_MAX 长：停在第 \(deep) 段（应为 341），回 failed")
    }

    /// 并行的调用（Claude Code 会并行调只读工具）共用同一次查询；卡住的查询等不到就回 null，不会越起越多。
    /// 假的 lstat 一直卡到放行为止，所以「在跑的时候」是确定的，不靠碰巧重叠。
    private static func walkJobChecks(_ check: Check) {
        let path = "/nonexistent-xp-mcp-selftest/walkjob-\(getpid())"
        let release = DispatchSemaphore(value: 0)
        let stuck: (String) -> MCPPaths.Node = { _ in
            release.wait()
            release.signal()  // 放行以后后面每一段都直接过
            return .directory
        }
        let first = WalkJob.shared(path, probe: stuck)
        let second = WalkJob.shared(path, probe: stuck)
        check(first === second, "同一个路径还在查的时候再要：拿到的是正在跑的那一个，不再起新的")
        check(first.wait(until: .now() + 0.05) == nil, "还没查完：等到 deadline 回 nil")
        let late = MCPPaths.foldersOnline([path], perFolder: 0.05, probe: stuck)
        check(late == [MCPPaths.FolderCheck(online: nil, protected: false)],
              "foldersOnline 等不到：folder_online 记 null、不算受保护（cull_list_sessions 这时加 folder_check_incomplete）")
        release.signal()
        let a = first.wait(until: .now() + 2)
        let b = second.wait(until: .now() + 2)
        check(a == .found(path, isDirectory: true) && a == b, "放行以后等着的两个拿到同一个结果：\(String(describing: a))")
        let third = WalkJob.shared(path) { _ in .missing }
        check(third !== first && third.wait(until: .now() + 2) == .missing(path), "查完以后再要：重新查一次")
    }

    // MARK: 8. collage_list_templates 的静态表

    private static func templateChecks(_ check: Check) {
        let rows = MCPInProcessTools.templateRows
        let builtin = CollageTemplates.builtin
        check(rows.count == builtin.count && rows.map { $0["name"] as? String ?? "" } == builtin.map(\.name),
              "模板行和 CollageTemplates.builtin 一样多、同顺序（\(rows.count) / \(builtin.count)）")
        check(Set(builtin.map(\.name)).count == builtin.count, "内置模板没有重名")
        let cats = MCPInProcessTools.categories
        let catTotal = cats.reduce(0) { $0 + ($1["count"] as? Int ?? 0) }
        check(cats.map { $0["name"] as? String ?? "" } == MCPToolDefs.templateCategories && catTotal == builtin.count,
              "分类和每类个数加起来等于模板数（\(cats.count) 类，\(catTotal) 个）")
        var bad: [String] = []
        var shapes: [String: Int] = [:]
        for (row, t) in zip(rows, builtin) {
            guard let cells = row["photo_cells"] as? [String: Int] else {
                if t.scatter == nil && t.contactSheet == nil { bad.append("\(t.name) 没有 photo_cells") }
                continue
            }
            let sum = cells.values.reduce(0, +)
            if sum != t.photoSlots { bad.append("\(t.name)：photo_cells 加起来 \(sum)，photo_slots \(t.photoSlots)") }
            for (k, v) in cells { shapes[k, default: 0] += v }
        }
        check(bad.isEmpty, "每个网格模板的 photo_cells 加起来等于 photo_slots \(bad.prefix(3))")
        check((shapes["landscape"] ?? 0) > 0 && (shapes["portrait"] ?? 0) > 0 && (shapes["square"] ?? 0) > 0,
              "横、竖、方的格子都有（\(shapes)）")
        let names = MCPInProcessTools.canvasAliases.map { CollageCLI.canvas($0).name }
        let all = (CollageCanvas.social + CollageCanvas.albums).map(\.name)
        check(names.count == all.count && Set(names) == Set(all) && Set(names).count == names.count,
              "画布别名正好盖住 CollageCanvas.social + .albums，每个一次（\(names.count) / \(all.count)）")
        let desc = MCPToolDefs.tools(live: true).first { $0["name"] as? String == "collage_list_templates" }?["description"] as? String ?? ""
        check(desc.contains("现在 \(builtin.count) 个，\(cats.count) 个分类"), "描述里的模板数、分类数是现算的")
    }
}
