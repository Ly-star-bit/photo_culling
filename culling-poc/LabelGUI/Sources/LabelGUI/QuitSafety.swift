import Foundation
import Darwin

// 长任务和退出（全项目审查 S05）：VLM 子进程不变孤儿（S05b）、长任务防闲置睡眠（S05c）。

/// VLM / 复审跑的是 `uv run python layer2.py`：Foundation 的 Process 让 uv 自己当进程组长，uv 起的 python 在同一组
/// （本机 uv 0.13 实测：组号 = uv 的 pid）。app 退出时没人给它们发信号的话，父进程一退 layer2 打下一行进度就 BrokenPipe、
/// 不再落盘，可线程池会把事先提交的照片全部发给 Ollama 跑完才退 —— 白占 GPU 和电量，重开再点 VLM 还要和它抢。
///
/// 退出和「取消」都只给 uv 发 SIGTERM（ProcessBox.signalLeader，kill(pid)）：uv 转给 python 一次，layer2 的 on_sigterm 落盘后
/// os._exit，一般几十毫秒整组就没了。等不到（老版本 uv 不转发、自己先被 SIGTERM 结束；python 卡住）才给整组补刀。
/// 不一上来就整组发（Foundation 的 Process.terminate() 在 macOS 上就是整组发）：uv 活着时整组发，python 会收到两次
/// （直接一次、uv 转发一次），第二次嵌套进 on_sigterm、正好打断第一次的落盘。
enum SubprocessGroup {
    enum Outcome: String {
        case exited = "收到 SIGTERM 自己退了"
        case terminated = "等不到，整组补发 SIGTERM 后退了"
        case killed = "整组 SIGKILL"
        case stuck = "SIGKILL 以后还在"
        case notOwnGroup = "不是它自己的进程组，只给 uv 发了 SIGTERM"
    }

    /// 能不能整组发信号：组号就是这个子进程自己（它当组长），不是 0 / 1，也不是我们自己这一组 ——
    /// 不然 kill(-组号) 会打到别的进程（终端里一起起来的、launchd 底下的，甚至我们自己）。
    static func ownsGroup(child: pid_t, group: pid_t, ownGroup: pid_t) -> Bool {
        child > 1 && group == child && group != ownGroup
    }

    /// 这一组里还有进程吗（刚退、还没被收的僵尸也算 —— Foundation 在后台很快收掉 uv，python 归 launchd 收）。
    static func alive(_ group: pid_t) -> Bool {
        guard group > 1 else { return false }
        if kill(-group, 0) == 0 { return true }
        return errno != ESRCH  // EPERM：组里还有，只是轮不到我们发
    }

    /// 等到这一组没人了（true），或者超时（false）。
    static func waitGone(_ group: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while alive(group) {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }

    /// SIGTERM 已经发给 uv 了（ProcessBox.terminateForQuit）。等 grace；还有活着的就整组补一个 SIGTERM（这时 uv 一般已经不在，
    /// python 只收到这一次），再等 termGrace，还在就整组 SIGKILL。最多阻塞 grace + termGrace + 0.5 s。
    static func reap(child: pid_t, group: pid_t, grace: TimeInterval = 1.5, termGrace: TimeInterval = 0.5) -> Outcome {
        guard ownsGroup(child: child, group: group, ownGroup: getpgrp()) else { return .notOwnGroup }
        if waitGone(group, timeout: grace) { return .exited }
        kill(-group, SIGTERM)
        if waitGone(group, timeout: termGrace) { return .terminated }
        kill(-group, SIGKILL)
        return waitGone(group, timeout: 0.5) ? .killed : .stuck
    }
}

// MARK: - 分析、VLM、复审、导卡、导出 / 复制期间防闲置睡眠（S05c）

/// 哪一种长任务（退出确认框按它说话）。导卡、导出 JPG / 精华、复制原片、复制高 ISO RAW 以前没拿（优化分析 NR1）：
/// 导一整张婚礼卡、往外接盘复制几百个 RAW 都要十几分钟，人一走开 Mac 闲置睡眠，复制就停在半路。
/// 选片确认表、写 XMP、移废片几秒就完，不拿（退出确认框照旧按「还有任务在跑」说）。
enum LongTaskKind: String, Sendable, CaseIterable {
    case analysis, vlm, appeal
    case cardImport, jpegExport, highlights, copyOriginals, highISO

    var label: String {
        switch self {
        case .analysis: return "分析照片"
        case .vlm: return "精审幸存照片"
        case .appeal: return "复审废片"
        case .cardImport: return "从存储卡导入"
        case .jpegExport: return "导出 JPG"
        case .highlights: return "导出精华"
        case .copyOriginals: return "复制原片"
        case .highISO: return "复制高 ISO RAW"
        }
    }

    /// 系统里这条电源断言的名字（pmset -g assertions 看得到，自检按它认）。只能用 ASCII：带中文的整个名字会变成空串（实测）。
    var reason: String { "LabelGUI \(rawValue): long task running, idle system sleep disabled" }
}

/// 分析、VLM、复审、导卡、导出 / 复制期间拿着 ProcessInfo 的 activity：夜里挂着跑几小时的 VLM，人一走开 Mac 闲置睡眠，
/// Python 和 Ollama 一起停住，早上一看没跑完（审查 S05c）。以前全仓只有实时桥拿了一个 .userInitiatedAllowingIdleSystemSleep，等于没防。
/// 合盖照样睡（那是用户自己的选择）；显示器照样可以灭。无头（命令行、测试宿主）不拿，只记账（退出确认框和自检看）。
/// 每次 begin 拿到一个 token，任务的 Task.detached 第一行 defer { token.end() } —— 所有出口（探 Ollama 失败、写清单失败、
/// 成功、失败、取消）都放掉，不然 app 开着期间 Mac 一直不睡。
final class LongTaskRegistry: @unchecked Sendable {
    /// .userInitiated 本身就含 .idleSystemSleepDisabled，写出来是为了看得见；也顺带不让 App Nap 给进程内的分析降速、
    /// 不让系统趁空闲悄悄把 app 结束（sudden / automatic termination）。
    static let activityOptions: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]

    /// 无头不拿：测试脚本跑分析不该让 runner 不睡；--live-host / --app-ui 也不是用户在等。
    static func holdsSystemActivity(headless: Bool) -> Bool { !headless }

    private let lock = NSLock()
    private var running: [(id: Int, kind: LongTaskKind)] = []
    private var nextID = 0
    /// nil = 按 AppRuntime.headless 定；自检设 true，走真的 beginActivity 去 pmset 里核对。
    var forceSystemActivity: Bool?

    /// 正在跑的长任务（按开始的先后）。
    var active: [LongTaskKind] {
        lock.lock(); defer { lock.unlock() }
        return running.map(\.kind)
    }

    func begin(_ kind: LongTaskKind) -> LongTaskToken {
        let hold = forceSystemActivity ?? Self.holdsSystemActivity(headless: AppRuntime.headless)
        let activity = hold ? ProcessInfo.processInfo.beginActivity(options: Self.activityOptions, reason: kind.reason) : nil
        lock.lock()
        nextID += 1
        let id = nextID
        running.append((id, kind))
        lock.unlock()
        return LongTaskToken(registry: self, id: id, activity: activity)
    }

    fileprivate func finish(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        running.removeAll { $0.id == id }
    }
}

/// 一次长任务的凭据。end() 可以在任何线程调、调几次都行；忘了调，释放时也会放掉（兜底，别指望它）。
final class LongTaskToken: @unchecked Sendable {
    private let lock = NSLock()
    private let registry: LongTaskRegistry
    private let id: Int
    private var activity: NSObjectProtocol?
    private var ended = false
    /// 真的拿了系统的 activity（GUI）还是只记账（无头）。
    let holdsSystemActivity: Bool

    fileprivate init(registry: LongTaskRegistry, id: Int, activity: NSObjectProtocol?) {
        self.registry = registry
        self.id = id
        self.activity = activity
        holdsSystemActivity = activity != nil
    }

    func end() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let held = activity
        activity = nil
        lock.unlock()
        if let held { ProcessInfo.processInfo.endActivity(held) }
        registry.finish(id)
    }

    deinit { end() }
}

// MARK: - 「上次分析没跑完」（审查 S05d 的尾巴）

/// 分析开跑时在场次目录写一个小标记，跑完、取消、出错时删掉（BatchStore.runAnalysis，都在 isRunning 落下之前）。app 崩溃、
/// 被强制退出、被系统杀掉、断电，或者退出时叫停以后等满时限照样放行（QuitCoordinator.tick）—— 这几种删不到，下次打开这一场
/// （switchSession；启动时重开上一场也走它）看到它还在，就在状态栏说一句。不拿「预览比行多」判断（误报多）。
/// 标记里的开始时间和 pid 只给人看（诊断包里列得到），判断只看文件在不在。VLM、复审不写：layer2 每 10 张落一次盘，再点一次接着跑。
enum UnfinishedAnalysis {
    static let fileName = "analysis_in_progress.json"
    static let notice = "上次分析没跑完（app 退出或崩溃），点「重新分析」补上"

    static func marker(in sessionDir: URL) -> URL { sessionDir.appendingPathComponent(fileName) }

    /// 开跑：写标记。写不上（场次目录只读、盘满）不挡分析，只是这一次崩了下次不会提示。
    @discardableResult
    static func begin(in sessionDir: URL, now: Date = Date()) -> Bool {
        let body: [String: Any] = ["kind": "analysis", "started": ISO8601DateFormatter().string(from: now),
                                   "pid": Int(getpid())]
        do {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            try data.write(to: marker(in: sessionDir), options: .atomic)
            return true
        } catch {
            SessionFiles.log.error("写「分析在跑」标记失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 跑完、取消、出错：删标记（没有也不要紧）。
    static func end(in sessionDir: URL) {
        try? FileManager.default.removeItem(at: marker(in: sessionDir))
    }

    static func leftOver(in sessionDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: marker(in: sessionDir).path)
    }
}

extension BatchStore {
    /// switchSession 读完以后：上次分析没跑完就在状态栏说一句。已经有更要紧的话（文件夹不在了、manifest 改不过来、
    /// 预览清掉了 —— 后两种也是让点「重新分析」）就不盖它。标记留着，直到下一次分析跑完、取消或出错。
    func noteUnfinishedAnalysis() {
        guard lastError == nil, UnfinishedAnalysis.leftOver(in: sessionDir) else { return }
        lastError = UnfinishedAnalysis.notice
    }
}
