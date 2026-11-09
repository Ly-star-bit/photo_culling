import AppKit
import Combine
import Foundation

/// 长任务和退出的自检（全项目审查 S05b / S05c / S05d / S05e）：
///     LABELGUI_DATA_DIR=<空的临时目录> LABELGUI_NO_GUI=1 LabelGUI --quit-selftest
/// 不要照片：假的 uv（/bin/sh 脚本，转发 / 不转发 SIGTERM / 子进程不理 SIGTERM 三种）走 BatchStore 同一个 runProcess、同一个
/// processBox，核对 willTerminate 以后子进程整组都没了、python 那一层只收到一次 SIGTERM；阈值防抖里排着的那次退出时写掉、
/// 没排着的不写；防睡眠的 activity 在 pmset 里真的有（每一种长任务都核对）、放掉就没，分析（合成的色块 JPEG）跑完 / 取消、
/// VLM 提前返回、导卡（导完 / 取消 / 卡被拔 / 排队的下一张）、导出 JPG / 精华、复制原片、复制高 ISO RAW（含提前返回）都放掉；
/// ⌘Q 确认的判断表（QuitGuard）和流程（QuitCoordinator，弹框、回 AppKit 都换成假的，在 modal panel 模式里等停下）；
/// ⌘Q 也看水印页、拼图页是不是正在导出（假的导出页：叫停、等停下、停不下来等满时限，AppDelegate 接的是 AppModel 里那两个）；
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
        t.sleepGuardDuringImportAndExports()
        t.quitDecisionTable()
        t.quitCoordinatorFlows()
        t.quitWaitsForPageExports()
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

    /// 本进程的 PreventUserIdleSystemSleep 断言那几行（nil = pmset 用不了）。
    func idleSleepAssertions() -> [Substring]? {
        guard let text = pmsetAssertions(), text.contains("Listed by owning process") else { return nil }
        let me = "pid \(getpid())("
        return text.split(separator: "\n").filter { $0.contains(me) && $0.contains("PreventUserIdleSystemSleep") }
    }

    /// 本进程有没有一条名字里带 tag 的 PreventUserIdleSystemSleep 断言（nil = pmset 用不了）。
    func preventsIdleSleep(_ tag: String) -> Bool? {
        idleSleepAssertions().map { lines in lines.contains { $0.contains(tag) } }
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

        let nonASCII = LongTaskKind.allCases.filter { !$0.reason.allSatisfy(\.isASCII) }.map(\.rawValue)
        check(nonASCII.isEmpty, "每一种长任务的断言名字都只有 ASCII（带中文的整个名字会变成空串，pmset 里认不出）：\(nonASCII)")

        let forced = LongTaskRegistry()
        forced.forceSystemActivity = true
        let kinds = LongTaskKind.allCases
        if idleSleepAssertions() == nil {
            print("SKIP pmset -g assertions 用不了：不核对系统里的电源断言")
        } else {
            // 每一种都进断言（导卡、导出 JPG / 精华、复制原片、复制高 ISO RAW 是 NR1 加的）：一起拿、一起等，不逐个等（省时间）。
            let tokens = kinds.map { forced.begin($0) }
            var missing = kinds.map(\.rawValue)
            let held = waitFor(3) {
                guard let lines = idleSleepAssertions() else { return false }
                missing = kinds.filter { kind in !lines.contains { $0.contains(kind.reason) } }.map(\.rawValue)
                return missing.isEmpty
            }
            check(held && tokens.allSatisfy(\.holdsSystemActivity),
                  "\(kinds.count) 种长任务拿着时 pmset 里各有一条本进程的 PreventUserIdleSystemSleep（缺：\(missing)）")
            tokens.forEach { $0.end() }
            var left: [String] = []
            let released = waitFor(3) {
                guard let lines = idleSleepAssertions() else { return false }
                left = kinds.filter { kind in lines.contains { $0.contains(kind.reason) } }.map(\.rawValue)
                return left.isEmpty
            }
            check(released && forced.active.isEmpty, "都放掉以后 pmset 里一条都没有了（还在：\(left)）")
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

    // MARK: - NR1 导卡、导出 JPG / 精华、复制原片、复制高 ISO RAW 期间防闲置睡眠

    func sleepGuardDuringImportAndExports() {
        print("— NR1 导卡（含排着队的下一张）、导出 JPG / 精华、复制原片、复制高 ISO RAW 期间也拿着防睡眠（无头只记账），所有出口都放掉")
        let store = newStore()

        // 导卡：假卡 = DCIM/100TEST 里几张色块 JPEG，导进 work 里的文件夹（不碰「图片」）。
        let card = work.appendingPathComponent("card-nr1", isDirectory: true)
        try? fm.removeItem(at: card)
        try? fm.createDirectory(at: card.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        try? fm.moveItem(at: makePhotoFolder("card-nr1-src", count: 4),
                         to: card.appendingPathComponent("DCIM/100TEST", isDirectory: true))
        let ledgerURL = dataDir.appendingPathComponent(CardImporter.ledgerFileName)
        func plan(_ source: URL, into name: String) -> CardImporter.Plan? {
            let dest = work.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: dest)
            return try? CardImporter.plan(source: source, destination: dest, ledger: .load(from: ledgerURL), includeImported: true)
        }
        func settled() -> Bool { !store.isRunning && store.longTasks.active.isEmpty }
        if let p = plan(card, into: "card-nr1-done") {
            store.importFromCard(p, analyzeAfter: false)
            check(store.longTasks.active == [.cardImport], "导卡一开始就拿着（\(store.longTasks.active.map(\.rawValue))）")
            spin(60, until: settled)
            check(settled() && store.progressText.hasPrefix("导入完成"), "导完放掉（\(store.progressText)）")
        } else {
            check(false, "假卡做得出导入计划")
        }
        if let p = plan(card, into: "card-nr1-cancel") {
            store.importFromCard(p, analyzeAfter: false)
            store.cancel()
            spin(60, until: settled)
            check(settled() && store.progressText.contains("取消"), "导卡中途取消也放掉（\(store.progressText)）")
        } else {
            check(false, "假卡做得出导入计划（取消那条）")
        }
        // 读卡失败（确认以后卡被拔了 = 重做计划时整张读不了）：走 catch 那个出口。
        let pulled = work.appendingPathComponent("card-nr1-pulled", isDirectory: true)
        try? fm.removeItem(at: pulled)
        try? fm.copyItem(at: card, to: pulled)
        if let p = plan(pulled, into: "card-nr1-pulled-dest") {
            try? fm.removeItem(at: pulled)
            store.importFromCard(p, analyzeAfter: false)
            spin(60, until: settled)
            check(settled() && (store.importNotice ?? "").contains("读不了"),
                  "卡被拔了、重做计划读不了也放掉（\(store.importNotice ?? "nil")）")
        } else {
            check(false, "假卡做得出导入计划（拔卡那条）")
        }
        // 排着队的下一张卡：CardImportCenter 在前一张导完、isRunning 落下以后再调一次 importFromCard，自己拿自己的。
        let center = CardImportCenter(store: store)
        final class Seen: @unchecked Sendable {
            var starts = 0
            var duringSecond: [LongTaskKind]?
        }
        let seen = Seen()
        let watch = store.$isRunning.filter { $0 }.sink { _ in
            seen.starts += 1
            // $isRunning 在赋值之前发：排到主线程下一拍再看（那时 importFromCard 已经拿了）。
            if seen.starts == 2 {
                DispatchQueue.main.async { MainActor.assumeIsolated { seen.duringSecond = store.longTasks.active } }
            }
        }
        if let a = plan(card, into: "card-nr1-queue"), let b = plan(card, into: "card-nr1-queue-b") {
            let volume = CardImporter.Volume(root: card, name: card.lastPathComponent, uuid: nil)
            center.offer = CardImportCenter.Offer(volume: volume, plan: a)
            center.confirm(analyzeAfter: false)
            center.offer = CardImportCenter.Offer(volume: volume, plan: b)
            center.confirm(analyzeAfter: false)
            check(store.importing && center.pending.count == 1 && store.longTasks.active == [.cardImport],
                  "两张卡：第一张在导、拿着，第二张排着队（\(center.pending.count) 张）")
            spin(60) { center.pending.isEmpty && settled() }
            let during = seen.duringSecond?.map(\.rawValue) ?? []
            check(seen.starts == 2 && seen.duringSecond?.contains(.cardImport) == true,
                  "排着队的那张开始导时也拿着（开始了 \(seen.starts) 张，那时 \(during)）")
            check(center.pending.isEmpty && settled(), "两张都导完：都放掉（\(store.longTasks.active.map(\.rawValue))）")
        } else {
            check(false, "假卡做得出导入计划（排队那条）")
        }
        withExtendedLifetime(watch) {}

        // 导出 / 复制：一场手写的假拍摄（3 张小 JPEG + 2 张 ISO 6400 的假 RAW），不跑分析。
        typealias Fake = FileSafetySelfTest.Fake
        let shoot = work.appendingPathComponent("photos-nr1-export", isDirectory: true)
        try? fm.removeItem(at: shoot)
        let shotStore = FileSafetySelfTest.makeShoot(shoot, [
            Fake(id: "N1", raw: "N1.JPG", jpeg: true), Fake(id: "N2", raw: "N2.JPG", jpeg: true),
            Fake(id: "N3", raw: "N3.JPG", jpeg: true),
            Fake(id: "R1", raw: "R1.ARW", iso: 6400), Fake(id: "R2", raw: "R2.ARW", iso: 6400),
        ])
        func done() -> Bool { !shotStore.isRunning && shotStore.longTasks.active.isEmpty }
        func run(_ kind: LongTaskKind, _ what: String, _ start: () -> Void) {
            start()
            let held = shotStore.longTasks.active
            spin(60, until: done)
            check(held == [kind] && done(), "\(what)：一开始就拿着「\(kind.rawValue)」、结束放掉（拿着的是 \(held.map(\.rawValue))；\(shotStore.lastError ?? shotStore.progressText)）")
        }
        let jpegs = ["N1", "N2", "N3"]
        let out = work.appendingPathComponent("nr1-out", isDirectory: true)
        try? fm.removeItem(at: out)
        run(.jpegExport, "导出 JPG") {
            shotStore.exportJPEGs(to: out.appendingPathComponent("jpg"), includeUsable: true, options: DeliveryOptions(), ids: jpegs)
        }
        run(.jpegExport, "导出 JPG 中途取消") {
            shotStore.exportJPEGs(to: out.appendingPathComponent("jpg-cancel"), includeUsable: true, options: DeliveryOptions(),
                                  ids: jpegs)
            shotStore.cancel()
        }
        // 建不了导出文件夹（那一级是个文件）：Task 里提前返回的那个出口。
        let blocker = out.appendingPathComponent("是个文件")
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: blocker)
        run(.jpegExport, "建不了导出文件夹、提前返回") {
            shotStore.exportJPEGs(to: blocker.appendingPathComponent("jpg"), includeUsable: true, options: DeliveryOptions(),
                                  ids: jpegs)
        }
        check((shotStore.lastError ?? "").contains("无法创建导出文件夹"), "（对照）确实走的是建不了文件夹那条：\(shotStore.lastError ?? "nil")")
        for id in jpegs { shotStore.setOverride(id, .pick) }
        run(.highlights, "导出精华") {
            shotStore.exportHighlights(count: 2, into: out.appendingPathComponent("精华"), options: DeliveryOptions())
        }
        run(.copyOriginals, "复制原片") {
            shotStore.copyOriginals(jpegs, to: out.appendingPathComponent("精修"))
        }
        run(.copyOriginals, "复制原片中途取消") {
            shotStore.copyOriginals(jpegs, to: out.appendingPathComponent("精修-取消"))
            shotStore.cancel()
        }
        defer { HighISOCopier.testHooks = HighISOCopier.TestHooks() }
        HighISOCopier.testHooks = HighISOCopier.TestHooks(noClone: true, freeBytes: 1 << 20)
        run(.highISO, "复制高 ISO RAW：空间不够、提前返回") {
            shotStore.exportHighISORaws(minISO: 3200, keepersOnly: false)
        }
        check((shotStore.lastError ?? "").contains("只剩"), "（对照）确实走的是空间不够那条：\(shotStore.lastError ?? "nil")")
        HighISOCopier.testHooks = HighISOCopier.TestHooks()
        run(.highISO, "复制高 ISO RAW") {
            shotStore.exportHighISORaws(minISO: 3200, keepersOnly: false)
        }
        check(shotStore.progressText.contains("已复制 2 个"), "（对照）2 个 RAW 复制了：\(shotStore.progressText)")
    }

    // MARK: - S05d 退出确认（纯函数 + 注入的弹框，从不真弹）

    func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    func quitDecisionTable() {
        print("— S05d 退出确认的判断：在跑就问「停下并退出 / 继续」，系统注销重启不问直接停下保存，没存上的问一句，无头一律直接退")
        // 导出 JPG / 精华、复制原片、复制高 ISO RAW 各是一种（NR1）。
        let jobs: [QuitGuard.Job] = [.analysis, .vlm, .appeal, .cardImport(queued: 1), .other]
            + QuitGuard.exportKinds.map { QuitGuard.Job.task($0) }
        // 水印页 / 拼图页在不在导出（NR5）：批量页闲着就按它们问，批量页也在跑就按批量页的问、确认框里补一句一起停下。
        let pageSets: [[QuitGuard.ExportPage]] = [[], [.watermark], [.collage], [.watermark, .collage]]
        var wrong: [String] = []
        for headless in [false, true] {
            for reason in [QuitGuard.Reason.user, .system] {
                for running in [nil] + jobs.map(Optional.some) {
                    for unsaved in [nil, "判决没存上"] as [String?] {
                        for pages in pageSets {
                            let state = QuitGuard.State(running: running, unsaved: unsaved, pageExports: pages)
                            let got = QuitGuard.decide(headless: headless, state: state, reason: reason)
                            let job: QuitGuard.Job? = running ?? (pages.isEmpty ? nil : .pageExport(pages))
                            let also: [QuitGuard.ExportPage] = running == nil ? [] : pages
                            let expect: QuitGuard.Decision
                            if headless {
                                expect = .quit
                            } else if let job {
                                expect = reason == .system ? .stopThenQuit(job, also: also) : .askStop(job, also: also)
                            } else if let unsaved, reason == .user {
                                expect = .askUnsaved(unsaved)
                            } else {
                                expect = .quit
                            }
                            if got != expect {
                                wrong.append("headless=\(headless) \(reason) \(String(describing: running)) \(unsaved ?? "-") \(pages) → \(got)")
                            }
                        }
                    }
                }
            }
        }
        let combos = 2 * 2 * (jobs.count + 1) * 2 * pageSets.count
        check(wrong.isEmpty, "判断表 \(combos) 种组合都对" + (wrong.isEmpty ? "" : "：\(wrong.prefix(3))"))

        var mapping: [(Bool, Bool, Bool, Int, [LongTaskKind], QuitGuard.Job?, String)] = [
            (false, false, false, 0, [], nil, "没在跑"),
            (true, true, false, 0, [.analysis], .analysis, "分析"),
            (true, false, false, 0, [.vlm], .vlm, "VLM"),
            (true, false, false, 0, [.appeal], .appeal, "复审"),
            (true, false, true, 2, [], .cardImport(queued: 2), "导卡（后面排着 2 张）"),
            (true, false, false, 1, [.cardImport], .cardImport(queued: 1), "导卡（只看防睡眠的记账也认得出）"),
            (true, false, false, 0, [], .other, "选片确认表 / 写 XMP / 移废片（不拿防睡眠的）"),
            (false, false, false, 0, [.vlm], nil, "isRunning 已经落下、防睡眠还没放（defer 晚一拍）= 不在跑"),
            (false, false, false, 0, [.copyOriginals], nil, "复制原片收尾时 isRunning 已经落下 = 不在跑"),
        ]
        for kind in QuitGuard.exportKinds {
            mapping.append((true, false, false, 0, [kind], .task(kind), kind.label))
        }
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
        for kind in QuitGuard.exportKinds {
            let p = QuitGuard.prompt(for: .askStop(.task(kind)))
            let ok = p?.title == "正在\(kind.label)，现在退出会中断" && p?.primary == "停下并退出"
                && p?.secondary == "继续\(kind.label)" && p?.primaryQuits == true && (p?.message.contains("留着") ?? false)
            check(ok, "\(kind.label)在跑：确认框按这一种说话（\(p?.title ?? "nil") / \(p?.secondary ?? "nil")）")
        }
        let copying = QuitGuard.prompt(for: .askStop(.task(.copyOriginals)))?.message ?? ""
        check(copying.contains("不留半截") && copying.contains("一模一样的会跳过"), "复制原片：说清正在复制的不留半截、下次一样的跳过")
        let wm = QuitGuard.prompt(for: .askStop(.pageExport([.watermark])))
        check(wm?.title == "水印页正在导出，现在退出会中断" && wm?.secondary == "继续导出" && wm?.primaryQuits == true
              && (wm?.message.contains("已经写出的文件留着") ?? false), "只有水印页在导出：「水印页正在导出」/「继续导出」（NR5）")
        let both = QuitGuard.prompt(for: .askStop(.pageExport([.watermark, .collage])))
        check(both?.title == "水印页、拼图页正在导出，现在退出会中断", "水印页、拼图页都在导出：一句说全（\(both?.title ?? "nil")）")
        let mixed = QuitGuard.prompt(for: .askStop(.analysis, also: [.collage]))
        check(mixed?.title == analysis?.title && mixed?.secondary == "继续分析"
              && (mixed?.message.contains("拼图页正在导出，也一起停下") ?? false),
              "分析在跑、拼图页也在导出：照分析问，补一句拼图页也一起停下")
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
                     saveChecks: @escaping () -> [QuitSaveCheck] = { [] },
                     exporters: @escaping () -> [QuitExportTarget] = { [] }) -> QuitCoordinator {
        QuitCoordinator(target: target, headless: headless, saveChecks: saveChecks, exporters: exporters,
                        ask: { rec.asked.append($0); return rec.answer($0) },
                        reply: { rec.replies.append($0) })
    }

    /// 自检里假的水印页 / 拼图页：叫停以后 stopAfter 秒 isExporting 落下（nil = 一直停不下来）。
    final class FakeExporter: QuitExportTarget {
        let quitExportPage: QuitGuard.ExportPage
        var isExporting = false
        var cancels = 0
        var stopAfter: Double? = 0.2
        /// isExporting 落下的那一刻（核对放行在它之后）。
        var stoppedAt: Date?
        init(_ page: QuitGuard.ExportPage) { quitExportPage = page }
        func cancelExport() {
            cancels += 1
            guard cancels == 1, let delay = stopAfter else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                isExporting = false
                stoppedAt = Date()
            }
        }
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
        // 张数够多：快的机器上按 ⌘Q 那一下也还没分析完（本机 16 核、8 路并发，叫停时才分析完一成左右）。
        // 尺寸小一点（以前 1600×1066，3072 以内分析不缩图、整张算）：这一条以前占 CI 自检步骤七成左右（优化分析 NE4）。
        let photoCount = 150
        let folderA = makePhotoFolder("photos-s05d-a", count: photoCount, width: 640, height: 426)
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
            // 核对完自己叫停（和上面「选继续」一样）：以前等它把剩下的一百多张跑完（最多等 60 秒），要核对的上面两行已经核对完了。
            if store.isRunning { store.cancel() }
            spin(60) { !store.isRunning }
            AppDelegate.batch = nil
        } else {
            check(false, "自检进程是无头的（AppRuntime.headless），QuitAlert 不会弹框")
        }
    }

    // MARK: - NR5 ⌘Q 也看水印页、拼图页是不是正在导出

    func quitWaitsForPageExports() {
        print("— NR5 ⌘Q 也看水印页、拼图页是不是正在导出：问「停下并退出 / 继续导出」，停下时叫它们自己的取消，等停下再放行")
        // 只有水印页在导出、批量页闲着。
        let idle = FakeTarget()
        let wm = FakeExporter(.watermark), col = FakeExporter(.collage)
        wm.isExporting = true
        let r1 = Recorder()
        final class AtReply { var exporting: Bool? }
        let atReply = AtReply()
        // 回 AppKit 的那一下记下水印页还在不在导（核对是停下以后才放行）。
        let c1 = QuitCoordinator(target: idle, headless: false, exporters: { [wm, col] },
                                 ask: { r1.asked.append($0); return r1.answer($0) },
                                 reply: { r1.replies.append($0); atReply.exporting = wm.isExporting })
        let reply1 = c1.shouldTerminate(reason: .user)
        check(reply1 == .terminateLater && r1.asked == [.askStop(.pageExport([.watermark]))] && wm.cancels == 1
              && col.cancels == 0 && idle.cancels == 0,
              "水印页在导出时 ⌘Q：问「水印页正在导出」，选「停下并退出」只叫停水印页（批量页闲着不叫它的取消）：\(r1.asked)")
        withExtendedLifetime(c1) { spinModal(5) { !r1.replies.isEmpty } }
        let seen = atReply.exporting.map { "\($0)" } ?? "nil"
        check(r1.replies == [true] && atReply.exporting == false && wm.stoppedAt != nil,
              "等水印页手上那一张写完、isExporting 落下才放行（放行那一下还在导：\(seen)）")

        // 选「继续导出」：不退、不叫停。
        let wm2 = FakeExporter(.watermark)
        wm2.isExporting = true
        let r2 = Recorder()
        r2.answer = { _ in false }
        check(coordinator(idle, r2, exporters: { [wm2] }).shouldTerminate(reason: .user) == .terminateCancel
              && wm2.cancels == 0 && wm2.isExporting, "选「继续导出」：不退、不叫停")

        // 批量页在跑、拼图页也在导出：照批量页问，补一句；两边都叫停，都停下才放行。
        let busy = FakeTarget()
        busy.isRunning = true
        busy.onCancel = { t in t.isRunning = false }
        let col3 = FakeExporter(.collage)
        col3.isExporting = true
        col3.stopAfter = 0.3
        let r3 = Recorder()
        let c3 = coordinator(busy, r3, exporters: { [FakeExporter(.watermark), col3] })
        _ = c3.shouldTerminate(reason: .user)
        withExtendedLifetime(c3) { spinModal(5) { !r3.replies.isEmpty } }
        check(r3.asked == [.askStop(.other, also: [.collage])] && busy.cancels == 1 && col3.cancels >= 1
              && r3.replies == [true] && !col3.isExporting,
              "批量页在跑、拼图页也在导出：问一次（拼图页一起停下），两边都叫停，拼图页也停下了才放行：\(r3.asked)")

        // 系统要退（注销、关机）：不问，直接叫停、等停下。
        let col4 = FakeExporter(.collage)
        col4.isExporting = true
        let r4 = Recorder()
        let c4 = coordinator(idle, r4, exporters: { [col4] })
        let reply4 = c4.shouldTerminate(reason: .system)
        withExtendedLifetime(c4) { spinModal(5) { !r4.replies.isEmpty } }
        check(reply4 == .terminateLater && r4.asked.isEmpty && col4.cancels >= 1 && r4.replies == [true],
              "注销 / 关机时拼图页在导出：不弹框，叫停、停下再放行")

        // 停不下来：等满时限照样放行（和批量页一样）。
        let stuck = FakeExporter(.watermark)
        stuck.isExporting = true
        stuck.stopAfter = nil
        let r5 = Recorder()
        let c5 = coordinator(idle, r5, exporters: { [stuck] })
        c5.userStopTimeout = 0.4
        let start5 = Date()
        _ = c5.shouldTerminate(reason: .user)
        withExtendedLifetime(c5) { spinModal(3) { !r5.replies.isEmpty } }
        let waited = Date().timeIntervalSince(start5)
        check(r5.replies == [true] && waited >= 0.35 && waited < 2.5, String(format: "水印页停不下来：等满时限照样放行（%.2f s）", waited))

        // 无头：直接退，不问、不叫停。
        let wm6 = FakeExporter(.watermark)
        wm6.isExporting = true
        let r6 = Recorder()
        check(coordinator(idle, r6, headless: true, exporters: { [wm6] }).shouldTerminate(reason: .user) == .terminateNow
              && r6.asked.isEmpty && wm6.cancels == 0, "无头：直接退，不问、不叫停")

        // 都没在导出：照旧直接退。
        let r7 = Recorder()
        check(coordinator(idle, r7, exporters: { [FakeExporter(.watermark), FakeExporter(.collage)] }).shouldTerminate(reason: .user)
              == .terminateNow && r7.asked.isEmpty, "水印页、拼图页都没在导出：直接退，不问")
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
        // 水印页、拼图页的导出（NR5）：同一个 AppModel 里的那两个 store。
        AppDelegate.model = nil
        let noPages = AppDelegate.exporters()
        AppDelegate.model = model
        let pages = AppDelegate.exporters()
        check(noPages.isEmpty && pages.count == 2 && pages.first === model.watermark && pages.last === collage
              && pages.map(\.quitExportPage) == [.watermark, .collage] && !pages.contains(where: \.isExporting),
              "AppDelegate 退出前看 AppModel 里的水印页、拼图页在不在导出（没设 model 时不看；这时都没在导）")
        func quit(_ reason: QuitGuard.Reason = .user, answer: Bool = false) -> (reply: NSApplication.TerminateReply, asked: [QuitGuard.Decision]) {
            let rec = Recorder()
            rec.answer = { _ in answer }
            let reply = coordinator(model.batch, rec, saveChecks: { AppDelegate.saveChecks() },
                                    exporters: { AppDelegate.exporters() }).shouldTerminate(reason: reason)
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
        // 只核对标记（开跑写、跑完 / 取消 / 出错删、留下的提示），和张数、尺寸无关：6 张小图就够（以前 40 张 1200×800）。
        let folder = makePhotoFolder("photos-unfinished", count: 6)
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
