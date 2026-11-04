import AppKit

// MARK: - GUI 启动门控（审查 S13：第二个实例照常启动，两边整份覆盖同一批场次文件）

/// 同一个数据目录只开一个选片工具：GUI 启动时（main.swift 里 syncEmbeddedPipeline 之前，什么都还没写）探一下
/// `<数据目录>/.live.lock`。锁被另一个活着的选片工具拿着 → 弹框「选片工具已经在运行（路径…）」，给「切换过去 / 退出」，
/// 这一个不建 store、不换 runtime/culling-poc 就退出。Lightroom Classic 目录被占用时也是直接拒绝打开，不给只读。
///
/// - 只探不拿：O_RDONLY 打开、LOCK_SH 探一下就放（和 LiveClient.probeLockFile 同一套），拿锁仍是 AppModel.make 里
///   LiveServer.prepare 的事（同一个进程另开一个 fd 拿着锁，LiveServer 会被自己挡住）。
/// - 认人看锁文件那一行（LiveServer.writeLockInfo：role=app、pid、exe，桥开没开都写）+ kill(pid, 0) 确认活着
///   + proc_pidpath 确认那个 pid 跑的就是那一行写的程序（pid 被别的进程重用时不认）。不靠 hello：对方关了
///   「允许 AI 实时操作」时 socket 不监听，但那一行照样在。也不靠 NSRunningApplication 拦：它认不出裸二进制，
///   还会把 --live-host 这类测试宿主当成 app。
/// - 锁被拿着但那一行还认不出人（对方正在启动、那一行还是上一次的）：每 100 ms 再看，最多 3 s（和 LiveServer 等锁一样长）；
///   还认不出就弹框说明、只给「退出」。
/// - 测试宿主（--live-host / --app-ui）、无头命令、带不认识的 `--` 参数、LABELGUI_NO_GUI=1 都不过这道门（isGUILaunch）：
///   测试宿主的 another_instance / waiting_for_lock 语义不变（live_smoke 断言的就是它）。
/// - 拿到锁以后、v1.20 以前不拿锁的旧版还认不出来：这一版不管（DESIGN 第 25 条）。
///
/// 判断都是纯函数（isGUILaunch、decide、sameProgram、displayPath、Holder），--mcp-selftest 第 24 组逐行测；
/// 探锁、认人那一半用 --launch-gate-probe 无头跑（只打印结论、不弹框），cli_guard_regression.py 拿一个真的 --live-host
/// 当「另一个实例」核对。
enum LaunchGate {
    /// 锁文件那一行里认人用的三样。
    struct Holder: Equatable {
        var role: String?
        var pid: Int?
        var exe: String?

        init(_ info: [String: Any]?) {
            role = info?["role"] as? String
            pid = LiveWire.int(info?["pid"])
            exe = info?["exe"] as? String
        }

        init(role: String?, pid: Int?, exe: String?) {
            self.role = role
            self.pid = pid
            self.exe = exe
        }
    }

    /// 探一下锁文件的结果。
    enum Probe: Equatable {
        /// 没有锁文件：从没有带桥的 app 在这个数据目录上跑过。
        case missing
        /// LOCK_SH 拿得到：没人持有 LOCK_EX（--mcp 探锁拿的也是 LOCK_SH，不挡）。
        case free
        /// 打不开 / 探不了（没权限、锁路径被换成符号链接）：交给 LiveServer 照旧报 lock_failed，这里不拦。
        case denied(Int32)
        /// 有人持有 LOCK_EX，带上那一行。
        case held(Holder)
    }

    enum Step: Equatable {
        case proceed
        case retry
        /// 另一个选片工具活着、拿着这个数据目录：弹框，能切就给「切换过去」。
        case running(pid: Int32, path: String)
        /// 锁被拿着，等满了还认不出是谁：弹框说明，只给「退出」。
        case unknown(pid: Int?)
    }

    static let budgetMs = 3_000
    static let retryMs = 100

    /// 这次启动会不会走到开界面那一句（main.swift 最后一行）：不带无头参数、不带任何 `--` 参数（不认识的那种走到
    /// 分派后面会 exit(2)）、开界面的最后一道闸（NoGUIGate .last）放行。只有这时才过门控。
    static func isGUILaunch(argv: [String], env: [String: String], ppid: pid_t, stdinIsTTY: Bool) -> Bool {
        let args = argv.dropFirst()
        if args.contains(where: { AppRuntime.headlessFlags.contains($0) || $0.hasPrefix("--") }) { return false }
        return NoGUIGate.decide(stage: .last, argv: argv, env: env, ppid: ppid, stdinIsTTY: stdinIsTTY) == .proceed
    }

    /// 探了一次以后怎么办。`pidAlive`、`procPath` 是那一行的 pid 查出来的（活着没有、跑的是哪个可执行文件，查不到是 nil）。
    static func decide(_ probe: Probe, pidAlive: Bool, procPath: String?, selfPid: Int32,
                       elapsedMs: Int, budgetMs: Int) -> Step {
        switch probe {
        case .missing, .free, .denied:
            return .proceed
        case .held(let h):
            if h.role == "app", let pid = h.pid, pid > 1, let p = Int32(exactly: pid), p != selfPid,
               pidAlive, sameProgram(procPath, exe: h.exe) {
                return .running(pid: p, path: displayPath(procPath ?? h.exe ?? ""))
            }
            return elapsedMs >= budgetMs ? .unknown(pid: h.pid) : .retry
        }
    }

    /// 那个 pid 跑的是不是那一行写的程序：路径一样，或者文件名一样（符号链接、/private/tmp 这类写法不同）。
    /// 查不到路径（别的用户的进程）不拿它否掉；那一行没写 exe 时只认叫 LabelGUI 的。
    static func sameProgram(_ procPath: String?, exe: String?) -> Bool {
        guard let procPath, !procPath.isEmpty else { return true }
        let name = (procPath as NSString).lastPathComponent
        guard let exe, !exe.isEmpty else { return name == "LabelGUI" }
        return procPath == exe || name == (exe as NSString).lastPathComponent
    }

    /// 弹框里给用户看的路径：.app 里的可执行文件报 .app 本身（「/Applications/选片工具.app」），裸二进制原样。
    static func displayPath(_ exe: String) -> String {
        if let r = exe.range(of: ".app/Contents/MacOS/", options: [.backwards, .caseInsensitive]) {
            return String(exe[..<r.lowerBound]) + ".app"
        }
        return exe
    }

    // MARK: 探锁、认人（查文件系统和进程表；不弹任何东西）

    static func probe(_ lockPath: String) -> Probe {
        let fd = open(lockPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let e = errno
            return e == ENOENT ? .missing : .denied(e)
        }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return .free
        }
        let e = errno
        guard e == EWOULDBLOCK else { return .denied(e) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        return .held(Holder(n > 0 ? LiveLock.parseInfo(Data(buf[0..<n])) : nil))
    }

    /// kill(pid, 0)：0 或 EPERM（别的用户的进程）= 活着。pid ≤ 1 一律不查（kill(0 / -1, 0) 是整个进程组 / 所有进程）。
    static func pidAlive(_ pid: Int?) -> Bool {
        guard let pid, pid > 1, let p = Int32(exactly: pid) else { return false }
        return kill(p, 0) == 0 || errno == EPERM
    }

    static func processPath(_ pid: Int?) -> String? {
        guard let pid, pid > 1, let p = Int32(exactly: pid) else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(p, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// 探到有结论为止：没人拿着、认出了对方、或者等满 budgetMs。
    static func detect(lockPath: String, budgetMs: Int = budgetMs) -> Step {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            let p = probe(lockPath)
            var holderPid: Int?
            if case .held(let h) = p { holderPid = h.pid }
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
            let elapsedMs = Int(elapsedNs / 1_000_000)
            let step = decide(p, pidAlive: pidAlive(holderPid), procPath: processPath(holderPid), selfPid: getpid(),
                              elapsedMs: elapsedMs, budgetMs: budgetMs)
            if step != .retry { return step }
            usleep(UInt32(retryMs * 1_000))
        }
    }

    // MARK: GUI：认出来了就弹框、退出

    @MainActor
    static func enforce(dataDir: URL) {
        guard case .success(let paths) = LivePaths.resolve(dataDir: dataDir.path, sockRoot: nil) else { return }
        switch detect(lockPath: paths.lockPath) {
        case .proceed, .retry:
            return
        case .running(let pid, let path):
            refuse(switchTo: pid, message: "选片工具已经在运行",
                   detail: "正在运行的是：\(path)\n\n同一个数据目录同时只能开一个选片工具：两个都开着，改判、客户选中和拼图会被另一个整份盖掉。"
                       + "切换到已经开着的那个继续用就行；要换成这一个，先退出那一个再打开。")
        case .unknown(let pid):
            let who = pid.map { "进程 \($0)" } ?? "别的程序"
            refuse(switchTo: nil, message: "数据目录正被另一个程序占用",
                   detail: "\(paths.dataDir) 的锁被\(who)拿着，认不出是哪个选片工具（可能还在启动）。\n\n"
                       + "为了不互相覆盖改判和拼图，这一个先不打开：等一会儿再开，或者先退出那一个。")
        }
    }

    @MainActor
    private static func refuse(switchTo pid: Int32?, message: String, detail: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        let target = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        if target != nil { alert.addButton(withTitle: "切换过去") }
        alert.addButton(withTitle: "退出")
        let response = alert.runModal()
        if let target, response == .alertFirstButtonReturn {
            target.unhide()
            target.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        }
        exit(0)
    }

    // MARK: 无头：只打印结论（测试用）

    /// LABELGUI_DATA_DIR=<临时> LabelGUI --launch-gate-probe [--budget-ms N]：对这个数据目录走一遍 GUI 门控的探锁、认人，
    /// 打一行 `launch-gate proceed` / `launch-gate running pid=<pid> path=<路径>` / `launch-gate unknown pid=<pid|->`，退出码 0。
    /// 只读：不拿锁、不写锁文件，绝不弹框。
    static func runProbe() -> Never {
        CollageCLI.requireIsolatedDataDir("--launch-gate-probe", "要探的是数据目录的锁")
        let args = CommandLine.arguments
        var budget = budgetMs
        if let i = args.firstIndex(of: "--budget-ms"), args.count > i + 1, let n = Int(args[i + 1]), n >= 0 { budget = n }
        guard case .success(let paths) = LivePaths.resolve(dataDir: appDataDir.path, sockRoot: nil) else {
            print("launch-gate proceed（数据目录解析不了）")
            exit(0)
        }
        switch detect(lockPath: paths.lockPath, budgetMs: budget) {
        case .proceed, .retry:
            print("launch-gate proceed")
        case .running(let pid, let path):
            print("launch-gate running pid=\(pid) path=\(path)")
        case .unknown(let pid):
            print("launch-gate unknown pid=\(pid.map(String.init) ?? "-")")
        }
        exit(0)
    }
}
