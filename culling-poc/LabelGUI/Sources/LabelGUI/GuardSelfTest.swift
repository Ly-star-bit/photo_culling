import Foundation

/// --mcp-selftest 的第 24 组（MCPSelfTest.run 调）：启动和无头命令的护栏，全是纯函数，不碰文件、不起进程。
/// 24a. DataDirGuard.isRealDataDir：LABELGUI_DATA_DIR 解析完是不是真实数据目录（同一个 dev/ino、大小写、结尾斜杠、NFC / NFD、
///      /System/Volumes/Data 那条路、子目录和父目录不算）。
/// 放在 MCP/ 外面：这些判断属于 GUI 启动和无头命令，不是 MCP 这一层。
extension MCPSelfTest {
    static func guardChecks(_ check: Check) {
        dataDirGuardChecks(check)
    }

    // MARK: 24a. 真实数据目录

    private static func dataDirGuardChecks(_ check: Check) {
        typealias R = DataDirGuard.Resolved
        let realPath = "/Users/tester/Library/Application Support/选片工具"
        let real = R(path: realPath, dev: 16_777_230, ino: 4242)
        let realUnstat = R(path: realPath, dev: nil, ino: nil)
        let cases: [(String, R, R, Bool)] = [
            ("同一个路径、同一个 dev/ino", R(path: realPath, dev: 16_777_230, ino: 4242), real, true),
            ("临时目录", R(path: "/private/var/folders/xx/T/tmp.abc", dev: 16_777_230, ino: 99), real, false),
            ("/System/Volumes/Data 那条路：路径不同、dev/ino 一样",
             R(path: "/System/Volumes/Data" + realPath, dev: 16_777_230, ino: 4242), real, true),
            ("符号链接 / 大小写写法 stat 出来是同一个目录", R(path: "/Users/tester/link-to-real", dev: 16_777_230, ino: 4242), real, true),
            ("都 stat 不了：只差大小写", R(path: "/users/TESTER/library/application support/选片工具", dev: nil, ino: nil), realUnstat, true),
            ("都 stat 不了：结尾多了斜杠", R(path: realPath + "//", dev: nil, ino: nil), realUnstat, true),
            ("真实目录还不存在、候选存在：路径一样也算", R(path: realPath, dev: 1, ino: 2), realUnstat, true),
            ("NFD 写法的家目录", R(path: "/Users/Jose\u{301}/Library/Application Support/选片工具", dev: nil, ino: nil),
             R(path: "/Users/Jos\u{E9}/Library/Application Support/选片工具", dev: nil, ino: nil), true),
            ("真实目录里的子目录不算", R(path: realPath + "/sessions", dev: 16_777_230, ino: 777), real, false),
            ("父目录不算", R(path: "/Users/tester/Library/Application Support", dev: 16_777_230, ino: 100), real, false),
            ("邻居「选片工具 2」不算", R(path: realPath + " 2", dev: 16_777_230, ino: 101), real, false),
            ("同一个卷、不同 inode、不同路径", R(path: "/Users/tester/tmp-data", dev: 16_777_230, ino: 4243), real, false),
            ("不同卷、同一个 inode 号", R(path: "/Volumes/X/data", dev: 16_777_231, ino: 4242), real, false),
            ("只有一边 stat 得到、路径不同", R(path: "/tmp/x", dev: nil, ino: nil), real, false),
        ]
        for (name, candidate, realDir, expected) in cases {
            let got = DataDirGuard.isRealDataDir(candidate, real: realDir)
            check(got == expected, "真实数据目录判断「\(name)」：期望 \(expected)，实际 \(got)")
        }
    }
}
