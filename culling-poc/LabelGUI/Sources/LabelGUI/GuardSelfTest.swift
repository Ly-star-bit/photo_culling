import Foundation

/// --mcp-selftest 的第 24 组（MCPSelfTest.run 调）：启动和无头命令的护栏，全是纯函数，不碰文件、不起进程。
/// 24a. DataDirGuard.isRealDataDir：LABELGUI_DATA_DIR 解析完是不是真实数据目录（同一个 dev/ino、大小写、结尾斜杠、NFC / NFD、
///      /System/Volumes/Data 那条路、子目录和父目录不算）。
/// 24b. LaunchGate（GUI 启动门控）：哪些启动过门控（isGUILaunch）、探锁的结论 → 放行 / 再等 / 认出对方 / 认不出
///      （decide，含 pid 是自己、pid ≤ 1、pid 被别的程序重用、那一行是旧的、role 不是 app、等满 3 s）、
///      对方跑的是不是那一行写的程序（sameProgram）、弹框里报的路径（displayPath）、锁文件那一行的解析（Holder）。
///      真的弹框那一步不测（不能弹）；探锁、认人的那一半由 --launch-gate-probe + cli_guard_regression.py 拿真的宿主核对。
/// 放在 MCP/ 外面：这些判断属于 GUI 启动和无头命令，不是 MCP 这一层。
extension MCPSelfTest {
    static func guardChecks(_ check: Check) {
        dataDirGuardChecks(check)
        launchGateChecks(check)
    }

    // MARK: 24b. GUI 启动门控

    private static func launchGateChecks(_ check: Check) {
        // 哪些启动过门控：(说明, argv[1...], env, ppid, tty, 期望)
        let launches: [(String, [String], [String: String], pid_t, Bool, Bool)] = [
            ("访达 / 程序坞双击", [], [:], 1, false, true),
            ("终端里直接跑", [], [:], 4242, true, true),
            ("open 带系统参数", ["-NSDocumentRevisionsDebugMode", "YES"], [:], 1, false, true),
            ("老系统的 -psn_", ["-psn_0_12345"], [:], 1, false, true),
            ("管道起的（像 MCP 客户端）", [], [:], 4242, false, false),
            ("管道起的、设了 LABELGUI_ALLOW_GUI=1", [], ["LABELGUI_ALLOW_GUI": "1"], 4242, false, true),
            ("LABELGUI_NO_GUI=1", [], ["LABELGUI_NO_GUI": "1"], 1, false, false),
            ("--verdicts", ["--verdicts", "/p"], [:], 4242, true, false),
            ("--live-host 测试宿主", ["--live-host", "/p"], [:], 4242, true, false),
            ("--app-ui 测试宿主", ["--app-ui", "/p", "/o.png"], [:], 4242, true, false),
            ("--mcp", ["--mcp"], [:], 4242, false, false),
            ("--mcp-selftest", ["--mcp-selftest"], [:], 4242, true, false),
            ("--launch-gate-probe", ["--launch-gate-probe"], [:], 4242, true, false),
            ("不认识的 --bogus（后面 exit 2）", ["--bogus"], [:], 4242, true, false),
            ("拼错的 —mcp", ["—mcp"], [:], 4242, true, false),
            ("照片文件夹路径", ["/Users/x/Pictures/20261021"], [:], 1, false, true),
        ]
        for (name, args, env, ppid, tty, expected) in launches {
            let got = LaunchGate.isGUILaunch(argv: ["LabelGUI"] + args, env: env, ppid: ppid, stdinIsTTY: tty)
            check(got == expected, "启动门控 isGUILaunch「\(name)」：期望 \(expected ? "过门控" : "不过")，实际 \(got ? "过门控" : "不过")")
        }

        typealias H = LaunchGate.Holder
        let app = "/Applications/选片工具.app/Contents/MacOS/LabelGUI"
        let me: Int32 = 500
        let budget = LaunchGate.budgetMs
        // (说明, 探锁结果, 活着, 那个 pid 跑的程序, 已经等了多久, 期望)
        let steps: [(String, LaunchGate.Probe, Bool, String?, Int, LaunchGate.Step)] = [
            ("没有锁文件", .missing, false, nil, 0, .proceed),
            ("没人拿着锁", .free, false, nil, 0, .proceed),
            ("锁文件打不开（交给 LiveServer 报 lock_failed）", .denied(EACCES), false, nil, 0, .proceed),
            ("另一个 .app 活着", .held(H(role: "app", pid: 600, exe: app)), true, app, 0,
             .running(pid: 600, path: "/Applications/选片工具.app")),
            ("另一个裸二进制活着", .held(H(role: "app", pid: 601, exe: "/Users/x/.build/release/LabelGUI")), true,
             "/Users/x/.build/release/LabelGUI", 0, .running(pid: 601, path: "/Users/x/.build/release/LabelGUI")),
            ("写法不同（/tmp 和 /private/tmp）也认", .held(H(role: "app", pid: 602, exe: "/tmp/b/LabelGUI")), true,
             "/private/tmp/b/LabelGUI", 0, .running(pid: 602, path: "/private/tmp/b/LabelGUI")),
            ("查不到对方的路径：按那一行报", .held(H(role: "app", pid: 603, exe: app)), true, nil, 0,
             .running(pid: 603, path: "/Applications/选片工具.app")),
            ("那一行没写 exe、对方叫 LabelGUI", .held(H(role: "app", pid: 604, exe: nil)), true, "/x/LabelGUI", 0,
             .running(pid: 604, path: "/x/LabelGUI")),
            ("那一行是旧的（pid 已经死了）：再等", .held(H(role: "app", pid: 605, exe: app)), false, nil, 100, .retry),
            ("那一行是旧的、等满了", .held(H(role: "app", pid: 605, exe: app)), false, nil, budget, .unknown(pid: 605)),
            ("pid 被别的程序重用了：不认", .held(H(role: "app", pid: 606, exe: app)), true, "/usr/bin/python3", 100, .retry),
            ("pid 被重用、等满了", .held(H(role: "app", pid: 606, exe: app)), true, "/usr/bin/python3", budget, .unknown(pid: 606)),
            ("那一行没写 exe、对方不叫 LabelGUI", .held(H(role: "app", pid: 607, exe: nil)), true, "/bin/sleep", budget,
             .unknown(pid: 607)),
            ("那一行的 pid 是自己", .held(H(role: "app", pid: Int(me), exe: app)), true, app, 100, .retry),
            ("pid 是 1（launchd）", .held(H(role: "app", pid: 1, exe: app)), true, app, budget, .unknown(pid: 1)),
            ("pid 是 0", .held(H(role: "app", pid: 0, exe: app)), true, app, 100, .retry),
            ("pid 是负数", .held(H(role: "app", pid: -1, exe: app)), true, app, 100, .retry),
            ("pid 超出 Int32", .held(H(role: "app", pid: 1 << 40, exe: app)), true, app, budget, .unknown(pid: 1 << 40)),
            ("role 不是 app（以后的无头写者）", .held(H(role: "headless", pid: 608, exe: app)), true, app, budget,
             .unknown(pid: 608)),
            ("那一行是空的 / 解析不了：再等", .held(H(nil)), false, nil, 0, .retry),
            ("那一行是空的、等满了", .held(H(nil)), false, nil, budget + 50, .unknown(pid: nil)),
        ]
        for (name, probe, alive, procPath, elapsed, expected) in steps {
            let got = LaunchGate.decide(probe, pidAlive: alive, procPath: procPath, selfPid: me, elapsedMs: elapsed, budgetMs: budget)
            check(got == expected, "启动门控 decide「\(name)」：期望 \(expected)，实际 \(got)")
        }

        let paths: [(String, String)] = [
            (app, "/Applications/选片工具.app"),
            ("/Volumes/选片工具 1.22/选片工具.app/Contents/MacOS/LabelGUI", "/Volumes/选片工具 1.22/选片工具.app"),
            ("/Users/x/仓库/选片工具.APP/Contents/MacOS/LabelGUI", "/Users/x/仓库/选片工具.app"),
            ("/Users/x/server/culling-poc/LabelGUI/.build/release/LabelGUI", "/Users/x/server/culling-poc/LabelGUI/.build/release/LabelGUI"),
            ("", ""),
        ]
        for (exe, expected) in paths {
            let got = LaunchGate.displayPath(exe)
            check(got == expected, "启动门控 displayPath(\(exe))：期望 \(expected)，实际 \(got)")
        }

        // 锁文件那一行（LiveServer.lockInfo 的写法；pwrite 再 ftruncate，中间可能读到「新的一行 + 旧的尾巴」）
        let line = #"{"bridge":"off","exe":"/Applications/选片工具.app/Contents/MacOS/LabelGUI","pid":4321,"reason":"disabled_in_settings","role":"app"}"#
        let parsed = H(LiveLock.parseInfo(Data((line + "\n{\"pid\":1,\"role\":\"app\"}tail").utf8)))
        check(parsed == H(role: "app", pid: 4321, exe: app), "启动门控：锁文件那一行解析成 role/pid/exe（\(parsed)）")
        check(H(LiveLock.parseInfo(Data("not json\n".utf8))) == H(role: nil, pid: nil, exe: nil), "启动门控：解析不了的一行 → 全是 nil")
        check(H(LiveLock.parseInfo(Data(#"{"role":"app","pid":true}"#.utf8))).pid == nil, "启动门控：pid 是 true 不当成 1")
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
