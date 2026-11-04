import AppKit
import Foundation

/// 长任务和退出的自检（全项目审查 S05b / S05c / S05d / S05e）：
///     LABELGUI_DATA_DIR=<空的临时目录> LABELGUI_NO_GUI=1 LabelGUI --quit-selftest
/// 不要照片：假的 uv（/bin/sh 脚本，转发 / 不转发 SIGTERM / 子进程不理 SIGTERM 三种）走 BatchStore 同一个 runProcess、同一个
/// processBox，核对 willTerminate 以后子进程整组都没了、python 那一层只收到一次 SIGTERM；阈值防抖里排着的那次退出时写掉、
/// 没排着的不写；防睡眠的 activity 在 pmset 里真的有、放掉就没，分析（合成的色块 JPEG）跑完 / 取消、VLM 提前返回都放掉；
/// ⌘Q 确认的判断表（QuitGuard）和流程（QuitCoordinator，弹框、回 AppKit 都换成假的，在 modal panel 模式里等停下）。
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
            let pythonAlive = ids.count == 2 && kill(ids[1], 0) == 0
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
        p.standardError = Pipe()
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

    func coordinator(_ target: QuitTarget, _ rec: Recorder, headless: Bool = false) -> QuitCoordinator {
        QuitCoordinator(target: target, headless: headless,
                        ask: { rec.asked.append($0); return rec.answer($0) },
                        reply: { rec.replies.append($0) })
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
        let photoCount = 48
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
        let layer1 = store.sessionDir.appendingPathComponent("layer1_results.json")
        let rows = (try? Data(contentsOf: layer1))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["results"] as? [Any] }?.count ?? -1
        check(saved > 0 && saved < photoCount && rows == saved,
              "放行之前已经分析完的 \(saved) 张写进了 layer1_results.json（\(rows) 行，下次复用），没跑完的 \(photoCount - saved) 张下次再分析")

        let keep = Recorder()
        keep.answer = { _ in false }
        store.runAnalysis()
        let r2 = coordinator(store, keep).shouldTerminate(reason: .user)
        check(r2 == .terminateCancel && keep.asked == [.askStop(.analysis)] && !store.cancelRequested,
              "选「继续分析」：不退、不叫停")
        spin(60) { !store.isRunning }
        check(store.progressText.hasPrefix("完成") && keep.replies.isEmpty, "分析照常跑完（\(store.progressText)）")

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
