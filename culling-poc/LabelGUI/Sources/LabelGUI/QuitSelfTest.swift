import AppKit
import Foundation

/// 长任务和退出的自检（全项目审查 S05b / S05c / S05d / S05e）：
///     LABELGUI_DATA_DIR=<空的临时目录> LABELGUI_NO_GUI=1 LabelGUI --quit-selftest
/// 不要照片：假的 uv（/bin/sh 脚本，转发 / 不转发 SIGTERM / 子进程不理 SIGTERM 三种）走 BatchStore 同一个 runProcess、同一个
/// processBox，核对 willTerminate 以后子进程整组都没了、python 那一层只收到一次 SIGTERM；阈值防抖里排着的那次退出时写掉、
/// 没排着的不写；防睡眠的 activity 在 pmset 里真的有、放掉就没，分析（合成的色块 JPEG）跑完 / 取消、VLM 提前返回都放掉；
/// ⌘Q 确认的判断表（QuitGuard）和流程（QuitCoordinator，弹框、回 AppKit 都换成假的，在 modal panel 模式里等停下）；
/// ⌘Q 也看拼图工程、标注存上没有（真的 AppModel、场次目录 / collage.json chmod 成写不进、读不出）；
/// 「上次分析没跑完」的标记（开跑写、跑完 / 取消 / 出错删，留下的下次打开这一场提示）。
/// 会写数据目录：只在临时目录里跑。每条打一行 PASS / FAIL，有 FAIL 退出码 1。不弹任何框。
enum QuitSelfTest {
    @MainActor
    static func run() -> Never {
        let flag = "--quit-selftest"
        CollageCLI.requireIsolatedDataDir(flag, "会建场次、写阈值")
        AppUISnapshot.requireNotRealDataDir(flag)
        let t = QuitSelfTestHarness(dataDir: appDataDir)
        t.groupSafetyTable()
        t.vlmChildStopsOnQuit()
        t.cancelSignalsOnlyUV()
        t.thresholdFlushOnQuit()
        t.sleepGuardDuringLongTasks()
        t.quitDecisionTable()
        t.quitCoordinatorFlows()
        t.quitChecksCollageAndLabels()
        t.unfinishedAnalysisMarker()
        print("quit-selftest: \(t.passed) 通过 \(t.failed) 失败")
        exit(t.failed == 0 ? 0 : 1)
    }
}

@MainActor
final class QuitSelfTestHarness {
    let dataDir: URL
    let work: URL
    private(set) var passed = 0
    private(set) var failed = 0
    let fm = FileManager.default

    init(dataDir: URL) {
        self.dataDir = dataDir
        work = dataDir.appendingPathComponent("quit-selftest", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    }

    func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if ok { passed += 1 } else { failed += 1 }
    }

    func newStore() -> BatchStore {
        // 新开的 store 不自动打开上一场：各条用例互不串。
        try? fm.removeItem(at: dataDir.appendingPathComponent("sessions.json"))
        return BatchStore(dataDir: dataDir, pythonRoot: work)
    }

    func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - S05b 退出时 VLM 子进程整组停掉

    func groupSafetyTable() {
        print("— S05b 整组发信号的护栏：只对子进程自己当组长的那一组发，绝不对 0 / 1 / 自己这一组发")
        let own = getpgrp()
        let rows: [(child: pid_t, group: pid_t, expect: Bool, what: String)] = [
            (4321, 4321, true, "子进程自己当组长"),
            (4321, 4000, false, "子进程在别人的组里"),
            (own, own, false, "组号是我们自己这一组"),
            (1, 1, false, "pid 1"),
            (0, 0, false, "pid 0（kill(0) 会打到自己这一组）"),
            (-1, -1, false, "getpgid 失败的 -1（kill(-1) 会打到所有进程）"),
        ]
        for row in rows {
            let got = SubprocessGroup.ownsGroup(child: row.child, group: row.group, ownGroup: own)
            check(got == row.expect, "\(row.what) → \(got ? "整组发" : "不整组发")")
        }
        check(!SubprocessGroup.alive(0) && !SubprocessGroup.alive(1) && !SubprocessGroup.alive(-1),
              "alive 对 0 / 1 / -1 一律 false（不会去 kill(0) / kill(-1)）")
    }

    /// 假的 uv：$3 = forward（像 uv 0.13：收到 SIGTERM 转给 python、等它退）| noforward（老版本那种：自己被 SIGTERM 结束，
    /// python 留下）| hung（转发，但 python 不理 SIGTERM）。uv 那一层写 uv <pid>。
    static let fakeUV = """
    py="$1"; marker="$2"; mode="$3"
    if [ "$mode" != noforward ]; then
      trap 'kill -TERM $child 2>/dev/null; wait $child; exit 143' TERM
    fi
    /bin/sh "$py" "$marker" "$mode" &
    child=$!
    echo "uv $$" >> "$marker"
    wait $child
    """

    /// 假的 python：起来写 start <pid>，收到 SIGTERM 写一行 term 再退（模拟 layer2 的 on_sigterm 落盘）；hung 不理 SIGTERM。
    static let fakePython = """
    marker="$1"; mode="$2"
    if [ "$mode" = hung ]; then trap '' TERM; else trap 'echo term >> "$marker"; exit 143' TERM; fi
    echo "start $$" >> "$marker"
    while :; do sleep 0.05; done
    """

    struct FakeRun {
        let marker: URL
        let done: DispatchSemaphore
        let result: ResultBox
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Void, Never>.ProcessOutcome?
        func set(_ r: Result<Void, Never>.ProcessOutcome) { lock.lock(); stored = r; lock.unlock() }
        var value: Result<Void, Never>.ProcessOutcome? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// 在后台线程走 BatchStore.runProcess（和 VLM 同一个函数、同一个 processBox），等假的 python 起来。
    func startFake(_ mode: String, box: ProcessBox) -> FakeRun? {
        let script = work.appendingPathComponent("fake-uv.sh")
        let python = work.appendingPathComponent("fake-python.sh")
        let marker = work.appendingPathComponent("marker-\(mode).txt")
        try? fm.removeItem(at: marker)
        guard (try? Self.fakeUV.write(to: script, atomically: true, encoding: .utf8)) != nil,
              (try? Self.fakePython.write(to: python, atomically: true, encoding: .utf8)) != nil else { return nil }
        let run = FakeRun(marker: marker, done: DispatchSemaphore(value: 0), result: ResultBox())
        let cwd = work
        box.resetCancellation()
        DispatchQueue.global().async {
            let r = BatchStore.runProcess(executable: "/bin/sh", arguments: [script.path, python.path, marker.path, mode],
                                          cwd: cwd, box: box)
            run.result.set(r)
            run.done.signal()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            // 两行都在：uv 的 trap 已经装好、python 也起来了。
            let seen = lines(marker)
            if seen.contains(where: { $0.hasPrefix("start ") }) && seen.contains(where: { $0.hasPrefix("uv ") }) { return run }
            usleep(20_000)
        }
        return nil
    }

    func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// marker 里记下的 uv、python 的 pid。
    func pids(_ url: URL) -> [pid_t] {
        lines(url).compactMap { line -> pid_t? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0] == "uv" || parts[0] == "start" else { return nil }
            return pid_t(parts[1])
        }
    }

    /// marker 里假 python 的 pid（按 start 那一行认，不按行的先后：uv 那一行可能先写也可能后写）。
    func pythonPid(_ url: URL) -> pid_t? {
        lines(url).first { $0.hasPrefix("start ") }.flatMap { pid_t($0.dropFirst("start ".count)) }
    }

    func allGone(_ pids: [pid_t]) -> Bool {
        pids.allSatisfy { kill($0, 0) != 0 && errno == ESRCH }
    }

    func isCancelled(_ r: Result<Void, Never>.ProcessOutcome?) -> Bool {
        if case .cancelled? = r { return true }
        return false
    }

    func vlmChildStopsOnQuit() {
        print("— S05b 退出（willTerminate）时 VLM 的 uv / python 子进程跟着停，不在后台把剩下的照片跑完")
        let store = newStore()
        check(store.prepareForQuit() == nil, "没在跑 VLM：退出时什么都不发")

        // 1. 像 uv 0.13：只给 uv 发 SIGTERM，它转给 python —— 走 willTerminate 通知（和真退出同一条路）。
        if let run = startFake("forward", box: store.processBox) {
            let ids = pids(run.marker)
            let start = Date()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            let took = Date().timeIntervalSince(start)
            let finished = run.done.wait(timeout: .now() + 5) == .success
            let terms = lines(run.marker).filter { $0 == "term" }.count
            check(terms == 1, "uv 转发：python 收到 SIGTERM 正好一次（落盘一次，没被第二个信号打断）→ \(terms) 次")
            check(finished && isCancelled(run.result.value), "uv 转发：runProcess 当成取消收场（不报「VLM 分析失败」）")
            check(ids.count == 2 && allGone(ids), "uv 转发：uv 和 python 都没了（\(ids)）")
            check(took < 1.4, String(format: "uv 转发：willTerminate 里没等满补刀的时限（%.2f s）", took))
        } else {
            check(false, "假的 uv（forward）起得来")
        }

        // 2. 老版本 uv 不转发：自己被 SIGTERM 结束，python 留成孤儿 → 等不到就整组补一个 SIGTERM。
        if let run = startFake("noforward", box: store.processBox) {
            let ids = pids(run.marker)
            let outcome = store.prepareForQuit()
            _ = run.done.wait(timeout: .now() + 5)
            let terms = lines(run.marker).filter { $0 == "term" }.count
            check(outcome == .terminated, "uv 不转发：等不到就整组补发 SIGTERM → \(outcome?.rawValue ?? "nil")")
            check(terms == 1, "uv 不转发：留下的 python 也只收到一次 SIGTERM、照样落盘 → \(terms) 次")
            check(ids.count == 2 && allGone(ids), "uv 不转发：一个都不剩（\(ids)）")
        } else {
            check(false, "假的 uv（noforward）起得来")
        }

        // 3. python 不理 SIGTERM（卡死）：补发也不退 → 整组 SIGKILL，willTerminate 不会无限等。
        if let run = startFake("hung", box: store.processBox) {
            let ids = pids(run.marker)
            let start = Date()
            let outcome = store.prepareForQuit()
            let took = Date().timeIntervalSince(start)
            _ = run.done.wait(timeout: .now() + 5)
            check(outcome == .killed, "python 卡住：最后整组 SIGKILL → \(outcome?.rawValue ?? "nil")")
            check(ids.count == 2 && allGone(ids), "python 卡住：一个都不剩（\(ids)）")
            check(took < 3.5, String(format: "python 卡住：最多阻塞三秒左右（%.2f s）", took))
        } else {
            check(false, "假的 uv（hung）起得来")
        }
    }

    /// 「取消」和退出发的是同一个信号：只给 uv（不是 Process.terminate() 那种整组发 —— 那样 python 收到两次，第二次打断落盘）。
    func cancelSignalsOnlyUV() {
        print("— S05b 取消 VLM：SIGTERM 只发给 uv（由它转给 python 一次），等不到才整组补刀；进程还没起来就点了取消也算数")
        let store = newStore()
        if let run = startFake("noforward", box: store.processBox) {
            let ids = pids(run.marker)
            store.cancel()
            usleep(300_000)
            let python = pythonPid(run.marker)
            let pythonAlive = ids.count == 2 && python.map { kill($0, 0) == 0 } == true
            let uvGone = run.done.wait(timeout: .now() + 3) == .success
            check(pythonAlive, "取消：python 没被直接打到（不是整组发；uv 不转发时它还活着）")
            check(uvGone && isCancelled(run.result.value), "取消：uv 收到 SIGTERM 退了，runProcess 当成取消")
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline, !allGone(ids) { usleep(50_000) }
            let terms = lines(run.marker).filter { $0 == "term" }.count
            check(allGone(ids) && terms == 1, "取消：后台等不到就整组补一个 SIGTERM，留下的 python 收到一次、退了（\(terms) 次）")
        } else {
            check(false, "假的 uv（noforward）起得来")
        }
        if let run = startFake("forward", box: store.processBox) {
            let ids = pids(run.marker)
            store.cancel()
            let finished = run.done.wait(timeout: .now() + 3) == .success
            usleep(200_000)
            let terms = lines(run.marker).filter { $0 == "term" }.count
            check(finished && terms == 1 && allGone(ids), "取消（uv 转发）：python 收到一次、整组都退了（\(terms) 次）")
        } else {
            check(false, "假的 uv（forward）起得来")
        }

        // 先点了取消、进程才起来（VLM 探 Ollama 那两秒里点的）：起来马上停，不白跑整批。
        let box = ProcessBox()
        box.resetCancellation()
        box.terminate()
        let script = work.appendingPathComponent("fake-uv.sh")
        let python = work.appendingPathComponent("fake-python.sh")
        let marker = work.appendingPathComponent("marker-early.txt")
        try? fm.removeItem(at: marker)
        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let cwd = work
        DispatchQueue.global().async {
            result.set(BatchStore.runProcess(executable: "/bin/sh", arguments: [script.path, python.path, marker.path, "forward"],
                                             cwd: cwd, box: box))
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 5) == .success
        check(finished && isCancelled(result.value), "进程起来之前就点了取消：一起来就停，runProcess 当成取消（没有跑下去）")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, !allGone(pids(marker)) { usleep(50_000) }
        check(allGone(pids(marker)), "进程起来之前就点了取消：一个都不剩（\(pids(marker))）")
    }

    // MARK: - S05c 分析、VLM、复审期间防闲置睡眠

    /// 合成照片文件夹：count 张 width×height 的色块 JPEG（每张底色、色块都不一样；原生引擎当真照片分析）。
    func makePhotoFolder(_ name: String, count: Int, width: Int = 360, height: Int = 240) -> URL {
        let folder = work.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var seed: UInt32 = 12345
        func next() -> CGFloat {
            seed = seed &* 1_103_515_245 &+ 12345
            return CGFloat((seed >> 16) & 0x7FFF) / 32767
        }
        let w = CGFloat(width), h = CGFloat(height)
        for i in 0..<count {
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            let tint = CGFloat(i % 7) / 7
            ctx.setFillColor(CGColor(red: tint, green: 0.4, blue: 1 - tint, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for _ in 0..<60 {
                ctx.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
                let rect = CGRect(x: next() * w, y: next() * h, width: next() * w / 4, height: next() * h / 4)
                ctx.fill(rect)
            }
            guard let image = ctx.makeImage() else { continue }
            _ = ProofSheetSelfTest.writeJPEG(image, to: folder.appendingPathComponent(String(format: "QS%04d.jpg", i)))
        }
        return folder
    }

    func pmsetAssertions() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let out = Pipe()
        p.standardOutput = out
        // stderr 不接 Pipe：没人读的管道写满以后 pmset 就卡住，readDataToEndOfFile 跟着永远等（CI 上自检超时）
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 本进程有没有一条名字里带 tag 的 PreventUserIdleSystemSleep 断言（nil = pmset 用不了）。
    func preventsIdleSleep(_ tag: String) -> Bool? {
        guard let text = pmsetAssertions(), text.contains("Listed by owning process") else { return nil }
        let me = "pid \(getpid())("
        return text.split(separator: "\n").contains {
            $0.contains(me) && $0.contains("PreventUserIdleSystemSleep") && $0.contains(tag)
        }
    }

    func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() >= deadline { return false }
            usleep(100_000)
        }
        return true
    }

    /// Ollama 有没有在本机跑着（在跑的话不起 VLM：不拿真的模型跑自检）。
    func ollamaUp(_ store: BatchStore) -> Bool {
        final class Flag: @unchecked Sendable { var up = false; var done = false }
        let flag = Flag()
        Task.detached {
            let up = await store.checkVLMServer()
            await MainActor.run { flag.up = up; flag.done = true }
        }
        spin(5) { flag.done }
        return flag.up
    }

    func sleepGuardDuringLongTasks() {
        print("— S05c 分析、VLM、复审期间不让 Mac 闲置睡眠（无头只记账），所有出口都放掉")
        let options = LongTaskRegistry.activityOptions
        check(options.contains(.idleSystemSleepDisabled) && options.contains(.userInitiated),
              "选项是 .userInitiated + .idleSystemSleepDisabled（不是实时桥那种 AllowingIdleSystemSleep）")
        check(LongTaskRegistry.holdsSystemActivity(headless: false) && !LongTaskRegistry.holdsSystemActivity(headless: true),
              "开界面才拿系统的 activity；命令行、测试宿主不拿")

        let reg = LongTaskRegistry()
        let a = reg.begin(.analysis)
        let v = reg.begin(.vlm)
        check(reg.active == [.analysis, .vlm] && !a.holdsSystemActivity, "无头：只记账（\(reg.active.map(\.rawValue))），不拿系统的")
        a.end()
        a.end()
        check(reg.active == [.vlm], "end 两次也只放一次")
        do { _ = reg.begin(.appeal) }
        check(reg.active == [.vlm], "token 丢了（忘了 end）释放时也放掉")
        v.end()
        check(reg.active.isEmpty, "都放掉了")

        let forced = LongTaskRegistry()
        forced.forceSystemActivity = true
        let tag = LongTaskKind.vlm.reason
        if preventsIdleSleep(tag) == nil {
            print("SKIP pmset -g assertions 用不了：不核对系统里的电源断言")
        } else {
            let token = forced.begin(.vlm)
            let held = waitFor(3) { preventsIdleSleep(tag) == true }
            check(held && token.holdsSystemActivity, "拿着时 pmset 里有本进程的 PreventUserIdleSystemSleep「\(LongTaskKind.vlm.reason)」")
            token.end()
            check(waitFor(3) { preventsIdleSleep(tag) == false }, "放掉以后 pmset 里没有了")
            let control = "LabelGUI quit-selftest control"
            let bridgeStyle = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: control)
            usleep(500_000)
            check(preventsIdleSleep(control) == false, "对照：实时桥那种 .userInitiatedAllowingIdleSystemSleep 不挡闲置睡眠（以前全仓只有它）")
            ProcessInfo.processInfo.endActivity(bridgeStyle)
        }

        // 真的流程（无头 store：只记账）。
        let store = newStore()
        let folder = makePhotoFolder("photos-s05c", count: 12)
        _ = store.switchSession(to: folder)
        store.runAppealOnRejects()
        check(store.longTasks.active.isEmpty && !store.isRunning, "没有可复审的废片：直接返回，不拿")
        store.runAnalysis()
        check(store.longTasks.active == [.analysis], "分析一开始就拿着")
        spin(60) { !store.isRunning && store.longTasks.active.isEmpty }
        check(!store.isRunning && store.longTasks.active.isEmpty && store.progressText.hasPrefix("完成"),
              "分析跑完放掉（\(store.progressText)，\(store.items.count) 张）")
        store.runAnalysis()
        store.cancel()
        spin(60) { !store.isRunning && store.longTasks.active.isEmpty }
        check(!store.isRunning && store.longTasks.active.isEmpty && store.progressText.contains("已取消"),
              "分析中途取消也放掉（\(store.progressText)）")
        if ollamaUp(store) {
            // 本机 Ollama 在跑：不起真的 VLM。场次目录设成只读，走「写清单失败就返回」那个出口（CI 上没有 Ollama，走下面那个）。
            let dir = store.sessionDir.path
            _ = chmod(dir, 0o500)
            store.runVLMOnSurvivors()
            check(store.longTasks.active == [.vlm], "VLM 一开始就拿着")
            spin(15) { !store.isRunning && store.longTasks.active.isEmpty }
            _ = chmod(dir, 0o755)
            check(!store.isRunning && store.longTasks.active.isEmpty && (store.lastError ?? "").contains("写入待分析清单失败"),
                  "写不了待分析清单提前返回也放掉（\(store.lastError ?? "")）")
        } else {
            store.runVLMOnSurvivors()
            check(store.longTasks.active == [.vlm], "VLM 一开始就拿着")
            spin(15) { !store.isRunning && store.longTasks.active.isEmpty }
            check(!store.isRunning && store.longTasks.active.isEmpty && (store.lastError ?? "").contains("Ollama"),
                  "探不到 Ollama 提前返回也放掉（\(store.lastError ?? "")）")
        }
    }

    // MARK: - S05d 退出确认（纯函数 + 注入的弹框，从不真弹）

    func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    func quitDecisionTable() {
        print("— S05d 退出确认的判断：在跑就问「停下并退出 / 继续」，系统注销重启不问直接停下保存，没存上的问一句，无头一律直接退")
        let jobs: [QuitGuard.Job] = [.analysis, .vlm, .appeal, .cardImport(queued: 1), .other]
        var wrong: [String] = []
        for headless in [false, true] {
            for reason in [QuitGuard.Reason.user, .system] {
                for running in [nil] + jobs.map(Optional.some) {
                    for unsaved in [nil, "判决没存上"] as [String?] {
                        let got = QuitGuard.decide(headless: headless,
                                                   state: QuitGuard.State(running: running, unsaved: unsaved), reason: reason)
                        let expect: QuitGuard.Decision
                        if headless {
                            expect = .quit
                        } else if let running {
                            expect = reason == .system ? .stopThenQuit(running) : .askStop(running)
                        } else if let unsaved, reason == .user {
                            expect = .askUnsaved(unsaved)
                        } else {
                            expect = .quit
                        }
                        if got != expect { wrong.append("headless=\(headless) \(reason) \(String(describing: running)) \(unsaved ?? "-") → \(got)") }
                    }
                }
            }
        }
        check(wrong.isEmpty, "判断表 \(2 * 2 * 6 * 2) 种组合都对" + (wrong.isEmpty ? "" : "：\(wrong.prefix(3))"))

        let mapping: [(Bool, Bool, Bool, Int, [LongTaskKind], QuitGuard.Job?, String)] = [
            (false, false, false, 0, [], nil, "没在跑"),
            (true, true, false, 0, [.analysis], .analysis, "分析"),
            (true, false, false, 0, [.vlm], .vlm, "VLM"),
            (true, false, false, 0, [.appeal], .appeal, "复审"),
            (true, false, true, 2, [], .cardImport(queued: 2), "导卡（后面排着 2 张）"),
            (true, false, false, 0, [], .other, "导出 / 复制 / 写 XMP"),
            (false, false, false, 0, [.vlm], nil, "isRunning 已经落下、防睡眠还没放（defer 晚一拍）= 不在跑"),
        ]
        for (running, analyzing, importing, queued, long, expect, what) in mapping {
            let got = QuitGuard.runningJob(isRunning: running, analyzing: analyzing, importing: importing,
                                           queuedCards: queued, longTasks: long)
            check(got == expect, "在跑什么：\(what) → \(got.map { "\($0)" } ?? "nil")")
        }

        let codes = ["logo", "rlgo", "rrst", "rest", "rsdn", "shut"].map(fourCC)
        check(Set(codes) == QuitGuard.systemQuitReasons, "注销 / 重启 / 关机六种 kAEQuitReason 都认（logo rlgo rrst rest rsdn shut）")
        check(codes.allSatisfy { QuitGuard.reason(quitReasonCode: $0) == .system }, "系统要退的原因 → 不弹框")
        check(QuitGuard.reason(quitReasonCode: nil) == .user && QuitGuard.reason(quitReasonCode: fourCC("quit")) == .user,
              "⌘Q（没有 Apple 事件）、程序坞退出（不带原因）→ 用户退的")

        let analysis = QuitGuard.prompt(for: .askStop(.analysis))
        check(analysis?.primaryQuits == true && analysis?.primary == "停下并退出" && analysis?.secondary == "继续分析"
              && (analysis?.message.contains("已经分析完的照片存好") ?? false),
              "分析在跑：「停下并退出」（回车）/「继续分析」（Esc），说清已分析的会存好")
        let vlm = QuitGuard.prompt(for: .askStop(.vlm))
        check((vlm?.message.contains("Python 进程一起停掉") ?? false) && vlm?.secondary == "继续判片", "VLM 在跑：说清后台 Python 一起停")
        let card = QuitGuard.prompt(for: .askStop(.cardImport(queued: 2)))
        check((card?.message.contains("另外 2 张卡") ?? false) && (card?.message.contains("先别格式化") ?? false)
              && (card?.message.contains("不留半截") ?? false),
              "导卡在跑：已校验的留着、不留半截、排着的卡不导、先别格式化")
        let unsaved = QuitGuard.prompt(for: .askUnsaved("「婚礼」的判决没存上（盘满了）"))
        check(unsaved?.primaryQuits == false && unsaved?.quitIsDestructive == true && unsaved?.primary == "不退出"
              && (unsaved?.message.contains("「婚礼」的判决没存上（盘满了）") ?? false),
              "没存上：默认「不退出」，「仍然退出」标成破坏性，原因原样带上")
        check(QuitGuard.prompt(for: .quit) == nil && QuitGuard.prompt(for: .stopThenQuit(.vlm)) == nil, "直接退、系统要退：没有弹框")
    }

    /// 自检里假的 store。
    final class FakeTarget: QuitTarget {
        var isRunning = false
        var analyzing = false
        var importing = false
        var queuedCardImports = 0
        var runningLongTasks: [LongTaskKind] = []
        var persistError: String?
        var cancelRequested = false
        var cancels = 0
        var retries = 0
        var onCancel: ((FakeTarget) -> Void)?
        func cancel() { cancels += 1; cancelRequested = true; onCancel?(self) }
        func retryPersist() -> Bool { retries += 1; return persistError == nil }
    }

    final class Recorder {
        var asked: [QuitGuard.Decision] = []
        var replies: [Bool] = []
        var answer: (QuitGuard.Decision) -> Bool = { _ in true }
    }

    func coordinator(_ target: QuitTarget, _ rec: Recorder, headless: Bool = false,
                     saveChecks: @escaping () -> [QuitSaveCheck] = { [] }) -> QuitCoordinator {
        QuitCoordinator(target: target, headless: headless, saveChecks: saveChecks,
                        ask: { rec.asked.append($0); return rec.answer($0) },
                        reply: { rec.replies.append($0) })
    }

    /// 自检里假的拼图 / 标注存盘。
    final class FakeSaveCheck: QuitSaveCheck {
        var problem: String?
        var calls = 0
        init(_ problem: String?) { self.problem = problem }
        func unsavedForQuit() -> String? { calls += 1; return problem }
    }

    /// AppKit 在 .terminateLater 期间跑的那种模式。
    func spinModal(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            if !RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02)) { usleep(5_000) }
        }
    }

    final class Hits { var main = false; var actor = false; var after = false }

    func quitCoordinatorFlows() {
        print("— S05d 退出确认的流程：选「停下并退出」先叫停、等写完再放行（在 modal run loop 里也走得到），选「继续」照常跑")
        // 和开界面时一样有 NSApplication（.prohibited：不进程序坞、不开窗口），NSModalPanelRunLoopMode 才是 common mode。
        NSApplication.shared.setActivationPolicy(.prohibited)
        let hits = Hits()
        DispatchQueue.main.async { hits.main = true }
        Task { @MainActor in hits.actor = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { hits.after = true }
        spinModal(3) { hits.main && hits.actor && hits.after }
        check(hits.main && hits.actor && hits.after,
              "modal panel 模式下主队列、MainActor 任务、asyncAfter 都跑得到（.terminateLater 期间等停下靠它们）")

        // 真的 store、真的分析（合成色块 JPEG）。
        let store = newStore()
        let photoCount = 150  // 够多：快的机器上按 ⌘Q 那一下也还没分析完
        let folderA = makePhotoFolder("photos-s05d-a", count: photoCount, width: 1600, height: 1066)
        let folderB = makePhotoFolder("photos-s05d-b", count: 30)
        _ = store.switchSession(to: folderA)
        let idle = Recorder()
        check(coordinator(store, idle).shouldTerminate(reason: .user) == .terminateNow && idle.asked.isEmpty,
              "没在跑、都存上了：直接退，不问")

        let stop = Recorder()
        let c1 = coordinator(store, stop)
        store.runAnalysis()
        // 等分析完几张再按 ⌘Q：核对的是「已经分析完的存好」，不是一张没跑就停。
        spin(20) { (store.progressFraction ?? 0) > 0 || !store.isRunning }
        let r1 = c1.shouldTerminate(reason: .user)
        check(r1 == .terminateLater && stop.asked == [.askStop(.analysis)] && store.cancelRequested,
              "分析中 ⌘Q、选「停下并退出」：叫停、回 .terminateLater（先不退）")
        withExtendedLifetime(c1) { spinModal(30) { !stop.replies.isEmpty } }
        let saved = store.progressText.split(separator: " ").dropFirst(2).first.flatMap { Int($0) } ?? -1
        check(stop.replies == [true] && !store.isRunning && store.progressText.hasPrefix("已取消: 已保存"),
              "停下、写完才放行退出（\(store.progressText)）")
        check(!fm.fileExists(atPath: UnfinishedAnalysis.marker(in: store.sessionDir).path),
              "放行之前「分析在跑」的标记已经删掉（自己叫停的，下次打开不说「上次没跑完」）")
        let layer1 = store.sessionDir.appendingPathComponent("layer1_results.json")
        let rows = (try? Data(contentsOf: layer1))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["results"] as? [Any] }?.count ?? -1
        check(saved > 0 && rows == saved,
              "放行之前已经分析完的 \(saved) 张写进了 layer1_results.json（\(rows) 行，下次复用）")
        print("     （共 \(photoCount) 张，叫停时还没分析的 \(photoCount - saved) 张下次再分析）")

        let keep = Recorder()
        keep.answer = { _ in false }
        store.runAnalysis()
        let r2 = coordinator(store, keep).shouldTerminate(reason: .user)
        check(r2 == .terminateCancel && keep.asked == [.askStop(.analysis)] && !store.cancelRequested,
              "选「继续分析」：不退、不叫停")
        // 核对的是「选了继续，分析照常往下跑、没被叫停」：进度往前走了（或者已经跑完）就算，不等整批 150 张跑完 ——
        // CI 的 runner 是虚拟机，分析慢好几倍，等跑完要好几分钟（以前在这里 60 秒等不完就红）。核对完自己叫停，省时间。
        let atDecision = store.progressFraction ?? 0
        spin(60) { !store.isRunning || (store.progressFraction ?? 0) > atDecision + 0.02 }
        let moved = store.isRunning ? (store.progressFraction ?? 0) > atDecision + 0.02 : store.progressText.hasPrefix("完成")
        check(moved && !store.cancelRequested && keep.replies.isEmpty,
              "分析照常往下跑（选的时候 \(Int(atDecision * 100))%，现在 \(store.progressText)）")
        if store.isRunning {
            store.cancel()
            spin(60) { !store.isRunning }
        }

        _ = store.switchSession(to: folderB)
        let system = Recorder()
        store.runAnalysis()
        let c3 = coordinator(store, system)  // AppDelegate 一直拿着它；这里也得拿着，不然等停下的那一拍找不到它
        let r3 = c3.shouldTerminate(reason: .system)
        check(r3 == .terminateLater && system.asked.isEmpty && store.cancelRequested, "注销 / 重启时分析在跑：不弹框，直接叫停")
        withExtendedLifetime(c3) { spinModal(30) { !system.replies.isEmpty } }
        check(system.replies == [true] && !store.isRunning, "停下保存完放行，不挡系统")

        // 判决没存上（场次目录只读 = 写不进去，和盘满走同一条路）。
        _ = store.switchSession(to: folderA)
        if let id = store.items.first?.id {
            let dir = store.sessionDir.path
            _ = chmod(dir, 0o500)
            store.setOverride(id, .reject)
            check(store.persistError != nil, "只读场次目录：改判没存上，有红条")
            let stay = Recorder()
            stay.answer = { _ in false }
            let r4 = coordinator(store, stay).shouldTerminate(reason: .user)
            let askedUnsaved: Bool
            if case .askUnsaved? = stay.asked.first { askedUnsaved = true } else { askedUnsaved = false }
            check(r4 == .terminateCancel && stay.asked.count == 1 && askedUnsaved, "先重试一次还是没存上：问一句，选「不退出」就不退")
            let anyway = Recorder()
            check(coordinator(store, anyway).shouldTerminate(reason: .user) == .terminateNow && anyway.asked.count == 1,
                  "选「仍然退出」：退")
            let sys = Recorder()
            check(coordinator(store, sys).shouldTerminate(reason: .system) == .terminateNow && sys.asked.isEmpty,
                  "系统要退：不弹框（willTerminate 里还会再写一次）")
            _ = chmod(dir, 0o755)
            let fixed = Recorder()
            check(coordinator(store, fixed).shouldTerminate(reason: .user) == .terminateNow && fixed.asked.isEmpty
                  && store.persistError == nil, "腾出空间以后：退出前那次重试写上了，不问、直接退")
        } else {
            check(false, "分析完有照片（\(store.items.count) 张）")
        }

        // 假的 store：等不到、排队的下一张卡、再按一次 ⌘Q、停下后还没存上、无头。
        let stuck = FakeTarget()
        stuck.isRunning = true
        let rs = Recorder()
        let cs = coordinator(stuck, rs)
        cs.userStopTimeout = 0.4
        let start = Date()
        check(cs.shouldTerminate(reason: .user) == .terminateLater, "停不下来的任务：先 .terminateLater")
        check(cs.shouldTerminate(reason: .user) == .terminateCancel && rs.asked.count == 1,
              "等的时候又按了一次 ⌘Q：不另起一轮、不再弹框")
        withExtendedLifetime(cs) { spinModal(3) { !rs.replies.isEmpty } }
        let waited = Date().timeIntervalSince(start)
        check(rs.replies == [true] && waited >= 0.35 && waited < 2.5, String(format: "等满时限照样放行（%.2f s）", waited))

        let queue = FakeTarget()
        queue.isRunning = true
        queue.importing = true
        queue.queuedCardImports = 1
        queue.onCancel = { t in
            if t.cancels == 1 {
                // 这张停下，排着的下一张接着开始导（换了一面新的旗子）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { t.cancelRequested = false; t.importing = true }
            } else {
                t.isRunning = false
                t.importing = false
            }
        }
        let rq = Recorder()
        let cq = coordinator(queue, rq)
        _ = cq.shouldTerminate(reason: .user)
        withExtendedLifetime(cq) { spinModal(5) { !rq.replies.isEmpty } }
        check(rq.asked == [.askStop(.cardImport(queued: 1))] && queue.cancels == 2 && rq.replies == [true],
              "导卡时退出：排着的下一张刚开始也叫停（叫停 \(queue.cancels) 次），都停了才退")

        let both = FakeTarget()
        both.isRunning = true
        both.persistError = "判决没存上（盘满了）"
        both.onCancel = { t in t.isRunning = false }
        let rb = Recorder()
        rb.answer = { if case .askStop = $0 { return true } else { return false } }
        let cb = coordinator(both, rb)
        _ = cb.shouldTerminate(reason: .user)
        withExtendedLifetime(cb) { spinModal(3) { !rb.replies.isEmpty } }
        check(rb.asked == [.askStop(.other), .askUnsaved("判决没存上（盘满了）")] && rb.replies == [false],
              "又在跑又没存上：先问停不停，停完还写不上再问一句，选「不退出」就不退")

        let headlessTarget = FakeTarget()
        headlessTarget.isRunning = true
        let rh = Recorder()
        check(coordinator(headlessTarget, rh, headless: true).shouldTerminate(reason: .user) == .terminateNow
              && rh.asked.isEmpty && headlessTarget.cancels == 0, "无头：直接退，不问、不叫停")

        // 装在 app 上的那一个：无头时一律直接退（弹框还有第二道闸 QuitAlert.mayShow）。前提不对就不调，免得真弹框。
        if AppRuntime.headless && !QuitAlert.mayShow {
            AppDelegate.batch = store
            store.runAnalysis()
            let reply = AppDelegate().applicationShouldTerminate(NSApplication.shared)
            check(reply == .terminateNow && !store.cancelRequested, "AppDelegate 在无头进程里：直接退、不叫停、不弹框")
            check(QuitAlert.ask(.askStop(.analysis)), "QuitAlert 在无头进程里不弹框，直接当成退出那一边")
            spin(60) { !store.isRunning }
            AppDelegate.batch = nil
        } else {
            check(false, "自检进程是无头的（AppRuntime.headless），QuitAlert 不会弹框")
        }
    }

    // MARK: - ⌘Q 也看拼图工程、标注存上没有

    /// collage.json 盘上那一份的缝宽（读不出来 = nil）。
    func diskGutter(_ url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url),
              let project = try? JSONDecoder().decode(CollageProject.self, from: data) else { return nil }
        return Double(project.style.gutter)
    }

    /// 改一下拼图（缝宽），不 flush：防抖里排着、还没到点写。
    func nudgeCollage(_ store: CollageStore) {
        var style = store.project.style
        style.gutter += 0.002
        store.setStyle(style, coalesce: false)
    }

    func isAskUnsaved(_ d: QuitGuard.Decision?, containing text: String) -> Bool {
        if case .askUnsaved(let message)? = d { return message.contains(text) }
        return false
    }

    func quitChecksCollageAndLabels() {
        print("— ⌘Q 也看拼图工程、标注存上没有：写失败（盘满）问一句，腾出空间以后退出前那次重写写上了就不问；原件读坏了但没改过的不误问")
        // 判断表：判决、拼图、标注没存上的原因合在一起问；又在跑又没存上，先问停不停，停完再问。
        let fakeTarget = FakeTarget()
        let collageFail = FakeSaveCheck("「婚礼」的拼图没存上：拼图项目保存失败: 盘满了")
        let labelsOK = FakeSaveCheck(nil)
        let r0 = Recorder()
        r0.answer = { _ in false }
        let c0 = coordinator(fakeTarget, r0, saveChecks: { [collageFail, labelsOK] })
        check(c0.shouldTerminate(reason: .user) == .terminateCancel
              && r0.asked == [.askUnsaved("「婚礼」的拼图没存上：拼图项目保存失败: 盘满了")] && collageFail.calls == 1 && labelsOK.calls == 1,
              "判断表：拼图写失败 → 问「有改动没存上」，选「不退出」就不退（标注那边也看了）")
        collageFail.problem = nil
        let r0b = Recorder()
        check(coordinator(fakeTarget, r0b, saveChecks: { [collageFail, labelsOK] }).shouldTerminate(reason: .user) == .terminateNow
              && r0b.asked.isEmpty, "判断表：拼图 / 标注都存上了（原件读坏了但没改过的也报 nil）→ 直接退")
        collageFail.problem = "拼图没存上"
        let r0c = Recorder()
        check(coordinator(fakeTarget, r0c, saveChecks: { [collageFail] }).shouldTerminate(reason: .system) == .terminateNow
              && r0c.asked.isEmpty, "判断表：系统要退（注销、关机）时拼图没存上：不弹框")
        let both = FakeTarget()
        both.persistError = "判决没存上"
        let r0d = Recorder()
        r0d.answer = { _ in false }
        _ = coordinator(both, r0d, saveChecks: { [collageFail, FakeSaveCheck("标注没存上")] }).shouldTerminate(reason: .user)
        check(r0d.asked == [.askUnsaved("判决没存上\n拼图没存上\n标注没存上")], "判决、拼图、标注都没存上：一个框里一行一样说全（\(r0d.asked)）")
        let busy = FakeTarget()
        busy.isRunning = true
        busy.onCancel = { t in t.isRunning = false }
        let r0e = Recorder()
        r0e.answer = { if case .askStop = $0 { return true } else { return false } }
        let c0e = coordinator(busy, r0e, saveChecks: { [collageFail] })
        let callsBefore = collageFail.calls
        _ = c0e.shouldTerminate(reason: .user)
        withExtendedLifetime(c0e) { spinModal(3) { !r0e.replies.isEmpty } }
        check(r0e.asked == [.askStop(.other), .askUnsaved("拼图没存上")] && r0e.replies == [false] && collageFail.calls - callsBefore == 2,
              "又在跑、拼图又没存上：先问停不停，停完再写一次拼图，还没存上再问，选「不退出」就不退")

        // 真的 AppModel（和 app 同一套接线，不开实时桥）、真的 CollageStore。
        try? fm.removeItem(at: dataDir.appendingPathComponent("sessions.json"))
        let model = AppModel.make(dataDir: dataDir, pythonRoot: work, bridge: .none)
        let folder = work.appendingPathComponent("photos-quit-collage", isDirectory: true)
        let other = work.appendingPathComponent("photos-quit-collage-other", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        _ = model.batch.switchSession(to: folder)
        model.ensureCollageAttached()
        let collage = model.collage
        let dir = model.batch.sessionDir
        let project = dir.appendingPathComponent("collage.json")

        AppDelegate.model = nil
        let unwired = AppDelegate.saveChecks()
        AppDelegate.model = model
        let wired = AppDelegate.saveChecks()
        check(unwired.isEmpty && wired.count == 2 && wired.first === collage && wired.last === model.labels,
              "AppDelegate 退出前看 AppModel 里的拼图工程和标注（LabelGUIApp.init 设 AppDelegate.model；没设时不看）")
        func quit(_ reason: QuitGuard.Reason = .user, answer: Bool = false) -> (reply: NSApplication.TerminateReply, asked: [QuitGuard.Decision]) {
            let rec = Recorder()
            rec.answer = { _ in answer }
            let reply = coordinator(model.batch, rec, saveChecks: { AppDelegate.saveChecks() }).shouldTerminate(reason: reason)
            return (reply, rec.asked)
        }

        let clean = quit()
        check(clean.reply == .terminateNow && clean.asked.isEmpty, "拼图没改过：直接退，不问")
        nudgeCollage(collage)
        let pending = quit()
        let wantGutter = Double(collage.project.style.gutter)
        check(pending.reply == .terminateNow && pending.asked.isEmpty && diskGutter(project) == wantGutter,
              "刚改完拼图（防抖还没到点）就 ⌘Q：退出前写上了，不问（盘上缝宽 \(diskGutter(project).map { "\($0)" } ?? "nil")）")

        // 写失败（场次目录只读 = 写不进去，和盘满走同一条路）。root 跑时 chmod 挡不住写，这一段测不了。
        _ = chmod(dir.path, 0o500)
        let probe = dir.appendingPathComponent("quit-probe")
        let chmodBlocks = (try? Data().write(to: probe)) == nil
        try? fm.removeItem(at: probe)
        if chmodBlocks {
            nudgeCollage(collage)
            let stay = quit(answer: false)
            let name = "「\(folder.lastPathComponent)」的拼图没存上"
            check(stay.reply == .terminateCancel && stay.asked.count == 1 && isAskUnsaved(stay.asked.first, containing: name)
                  && isAskUnsaved(stay.asked.first, containing: "保存失败"),
                  "拼图写不进去：⌘Q 问「有改动没存上」（说是哪一场的拼图、原话），选「不退出」就不退：\(stay.asked)")
            check(collage.projectSaveProblem != nil && diskGutter(project) != Double(collage.project.style.gutter),
                  "（对照）这时盘上的 collage.json 确实是旧的，CollageStore 也记着写失败")
            let anyway = quit(answer: true)
            check(anyway.reply == .terminateNow && anyway.asked.count == 1, "选「仍然退出」：退")
            let system = quit(.system)
            check(system.reply == .terminateNow && system.asked.isEmpty, "系统要退：不弹框")
            _ = chmod(dir.path, 0o755)
            let fixed = quit()
            check(fixed.reply == .terminateNow && fixed.asked.isEmpty && collage.projectSaveProblem == nil
                  && diskGutter(project) == Double(collage.project.style.gutter),
                  "腾出空间以后、没再改拼图：退出前那次重写写上了，不问、直接退（盘上是最新的）")
        } else {
            _ = chmod(dir.path, 0o755)
            print("SKIP root 跑时 chmod 挡不住写：拼图写失败那一段测不了")
        }

        // 原件读不出来（这一场的拼图先不存盘）：没改过不误问，改过才问。
        let original = (try? Data(contentsOf: project)) ?? Data("{\"pages\":[]}".utf8)
        try? original.write(to: project)
        _ = chmod(project.path, 0o000)
        let unreadable = (try? Data(contentsOf: project)) == nil
        model.batch.confirmDiscardRefused = { _, _ in true }
        if unreadable {
            _ = model.batch.switchSession(to: other)
            model.ensureCollageAttached()
            _ = model.batch.switchSession(to: folder)
            model.ensureCollageAttached()
            check(collage.projectSaveProblem != nil && !collage.hasRefusedEdits,
                  "（对照）collage.json 读不出来：projectSaveProblem 不是 nil（直接拿它当「没存上」，每次 ⌘Q 都会误问）")
            let untouched = quit()
            check(untouched.reply == .terminateNow && untouched.asked.isEmpty, "拼图原件读不出来、一下没动过：⌘Q 不问")
            nudgeCollage(collage)
            let edited = quit(answer: false)
            check(edited.reply == .terminateCancel && isAskUnsaved(edited.asked.first, containing: "拼图没存上")
                  && isAskUnsaved(edited.asked.first, containing: "读不出来"),
                  "拼图原件读不出来、这次打开以后又改过（改动只在内存里）：⌘Q 问一句：\(edited.asked)")
        } else {
            print("SKIP root 跑时 chmod 000 挡不住读：拼图原件读不出来那一段测不了")
        }
        _ = chmod(project.path, 0o644)
        _ = model.batch.switchSession(to: other)
        model.ensureCollageAttached()

        // 标注（labels.csv）：flush 以后还有 saveError = 改过、没写上。标注页自己的写盘不在这里测，直接设 saveError。
        model.labels.saveError = "保存 labels.csv 失败: 盘满了"
        let labels = quit(answer: false)
        check(labels.reply == .terminateCancel && isAskUnsaved(labels.asked.first, containing: "标注没存上：保存 labels.csv 失败"),
              "标注没存上：⌘Q 一样问：\(labels.asked)")
        model.labels.saveError = nil
        let labelsOK2 = quit()
        check(labelsOK2.reply == .terminateNow && labelsOK2.asked.isEmpty, "标注存上了：直接退")
        AppDelegate.model = nil
    }

    // MARK: - 「上次分析没跑完」

    func unfinishedAnalysisMarker() {
        print("— 上次分析没跑完：开跑时在场次目录写标记，跑完 / 取消 / 出错删掉；崩溃、强退留下的，下次打开这一场提示「点重新分析补上」")
        let store = newStore()
        let folder = makePhotoFolder("photos-unfinished", count: 40, width: 1200, height: 800)
        let other = work.appendingPathComponent("photos-unfinished-other", isDirectory: true)
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        _ = store.switchSession(to: folder)
        let dir = store.sessionDir
        let marker = UnfinishedAnalysis.marker(in: dir)
        check(!fm.fileExists(atPath: marker.path) && store.lastError == nil, "新场次：没有标记、不提示")

        store.runAnalysis()
        let during = fm.fileExists(atPath: marker.path) && store.isRunning
        let body = (try? Data(contentsOf: marker)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let fields: Bool = body?["kind"] as? String == "analysis" && body?["pid"] as? Int == Int(getpid()) && body?["started"] is String
        check(during && fields, "分析一开跑：场次目录里就有 \(UnfinishedAnalysis.fileName)（种类、开始时间、pid）")
        spin(90) { !store.isRunning }
        check(store.progressText.hasPrefix("完成") && !fm.fileExists(atPath: marker.path), "跑完：标记删掉（\(store.progressText)）")

        store.runAnalysis()
        store.cancel()
        spin(60) { !store.isRunning }
        check(store.progressText.contains("已取消") && !fm.fileExists(atPath: marker.path), "中途取消：标记删掉（\(store.progressText)）")

        // 崩溃、强退、退出时等满时限照样放行：删标记那一步走不到 —— 手写一个，和进程半路没了留下的一样。
        UnfinishedAnalysis.begin(in: dir)
        _ = store.switchSession(to: other)
        check(store.lastError == nil, "别的场次不提示（标记一场一个）")
        _ = store.switchSession(to: folder)
        check(store.lastError == UnfinishedAnalysis.notice, "切回这一场：状态栏说「\(store.lastError ?? "nil")」")
        let relaunched = BatchStore(dataDir: dataDir, pythonRoot: work)
        check(relaunched.sessionDir.standardizedFileURL.path == dir.standardizedFileURL.path
              && relaunched.lastError == UnfinishedAnalysis.notice,
              "重开 app（BatchStore.init 自动打开上一场）：一样提示（\(relaunched.lastError ?? "nil")）")
        check(fm.fileExists(atPath: marker.path), "只是打开、没重新分析：标记留着（下次打开还提示）")

        store.runAnalysis()
        check(store.lastError == nil, "点「重新分析」：提示收起来")
        spin(90) { !store.isRunning }
        _ = store.switchSession(to: other)
        _ = store.switchSession(to: folder)
        check(!fm.fileExists(atPath: marker.path) && store.lastError == nil, "重新分析跑完：标记删掉，再打开不提示")

        // 分析出错（文件夹里一张照片都没有）：用户看到了「分析失败」，不是没跑完 —— 也删掉。
        let empty = work.appendingPathComponent("photos-unfinished-empty", isDirectory: true)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        _ = store.switchSession(to: empty)
        let emptyMarker = UnfinishedAnalysis.marker(in: store.sessionDir)
        store.runAnalysis()
        spin(20) { !store.isRunning }
        check((store.lastError ?? "").hasPrefix("分析失败") && !fm.fileExists(atPath: emptyMarker.path),
              "分析出错：标记也删掉（\(store.lastError ?? "nil")）")

        // 更要紧的话不盖：照片文件夹不在了。
        let gone = makePhotoFolder("photos-unfinished-gone", count: 2)
        _ = store.switchSession(to: gone)
        UnfinishedAnalysis.begin(in: store.sessionDir)
        try? fm.removeItem(at: gone)
        _ = store.switchSession(to: other)
        _ = store.switchSession(to: gone)
        check((store.lastError ?? "").contains("已不存在"), "照片文件夹不在了：照旧说文件夹不在（不被「没跑完」盖掉）")
        _ = store.switchSession(to: other)
    }

    // MARK: - S05e 阈值防抖里排着的那次，退出时写掉

    func sharpness(_ url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["sharpness"] as? Double
    }

    func thresholdFlushOnQuit() {
        print("— S05e 松开滑杆半秒内退出：这次阈值照样存上；没改的不在退出时重写")
        let folder = work.appendingPathComponent("photos-thresholds", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = newStore()
        _ = store.switchSession(to: folder)
        let own = store.sessionDir.appendingPathComponent("thresholds.json")
        let global = dataDir.appendingPathComponent("thresholds.json")
        check(fm.fileExists(atPath: own.path), "打开场次时定下了这一场的 thresholds.json")

        store.sharpnessThreshold = 33
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        check(sharpness(own) == 33, "刚拖完就退出：这一场的 thresholds.json 写进了 33 → \(sharpness(own).map { "\($0)" } ?? "nil")")
        check(sharpness(global) == 33, "刚拖完就退出：上次用的那份（数据目录里的）也写进了 33")

        // 退出那一下写过以后，防抖任务被取消，不会再写一遍；之后什么都没排着，再退出也不碰文件。
        let sentinel = #"{"sharpness":77,"exposure":0.15,"faceQuality":0.3}"#
        try? sentinel.write(to: own, atomically: true, encoding: .utf8)
        spin(0.8) { false }
        check(sharpness(own) == 77, "退出时写掉以后，原来那个防抖任务不再补写")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        check(sharpness(own) == 77, "什么都没排着：退出时不拿当前值去盖 thresholds.json")

        // 防抖自己写完了的：排着的记录跟着清掉，退出时不再写。
        store.sharpnessThreshold = 44
        spin(2) { sharpness(own) == 44 }
        check(sharpness(own) == 44, "半秒防抖照常写盘（44）")
        try? sentinel.write(to: own, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        check(sharpness(own) == 77, "防抖已经写过的：退出时不再写一遍")
    }
}
