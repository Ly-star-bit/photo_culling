import AppKit
import Foundation

// 退出确认（全项目审查 S05d，和 S01a 的「判决没存上」共用；拼图工程、标注没存上也问，见 QuitSaveCheck）：分析、VLM、导卡、
// 导出 JPG / 精华、复制原片、复制高 ISO RAW 在跑，或者水印页、拼图页正在导出时按 ⌘Q / 程序坞退出先问一句；
// 选「停下并退出」走现有的 cancel()（水印页、拼图页走它们自己的 cancelExport()），等它把已完成的写完再真的退（.terminateLater）—— willTerminate 是同步的，
// 等不到后台引擎写盘，只确认一句「确定退出」照样丢掉这一轮。注销、重启、关机不弹框，直接停下保存再放行。
// 判断全在纯函数（QuitGuard）和可注入的流程（QuitCoordinator）里，--quit-selftest 断言；弹框只在 AppDelegate 这一条路上，
// 而 AppDelegate 只有开界面的 LabelGUIApp 才装（命令行、--live-host、--app-ui 都在 LabelGUIApp.main() 之前 exit）。
// 退出真的放行以后才发 willTerminate：LiveServer、LabelStore、WatermarkStore、CollageStore、BatchStore 的那几个照旧各自落盘。

enum QuitGuard {
    /// 谁让退的：用户（⌘Q、程序坞、菜单）还是系统（注销、重启、关机 —— 不能弹框挡住系统）。
    enum Reason: Equatable { case user, system }

    /// 顶栏那一个进度条在跑什么。
    enum Job: Equatable {
        case analysis, vlm, appeal
        /// 存储卡导入；queued = 后面还有几张卡排着队。
        case cardImport(queued: Int)
        /// 拿着防睡眠的那几种导出 / 复制（导出 JPG、精华、复制原片、复制高 ISO RAW）：确认框按它的 label 说话（优化分析 NR1）。
        case task(LongTaskKind)
        /// 批量页闲着，水印页 / 拼图页正在导出（优化分析 NR5：以前 ⌘Q 只看批量页，导到一半直接退）。
        case pageExport([ExportPage])
        /// 选片确认表、写 XMP、移废片……（几秒就完的，不拿防睡眠）
        case other
    }

    /// 批量页以外自己有导出进度的页：顶栏那一个进度条、isRunning 都管不到它们（QuitExportTarget）。
    enum ExportPage: String, Equatable, CaseIterable {
        case watermark, collage

        var label: String {
            switch self {
            case .watermark: return "水印页"
            case .collage: return "拼图页"
            }
        }

        static func labels(_ pages: [ExportPage]) -> String { pages.map(\.label).joined(separator: "、") }
    }

    /// 导出 / 复制这几种长任务（runningJob 按这个先后认；分析、VLM、复审、导卡另有自己的那一支）。
    static let exportKinds: [LongTaskKind] = [.jpegExport, .highlights, .copyOriginals, .highISO]

    struct State: Equatable {
        var running: Job?
        /// 判决、客户选中、对时没存上（BatchStore.persistError），拼图工程、标注没存上（QuitSaveCheck）—— 都已经重试过一次还是失败。
        var unsaved: String?
        /// 水印页 / 拼图页正在导出的（NR5）。
        var pageExports: [ExportPage] = []
    }

    enum Decision: Equatable {
        case quit
        /// 问：停下并退出 / 继续。also = 批量页的任务以外，另外还在导出、要一起停下的页（NR5）。
        case askStop(Job, also: [ExportPage] = [])
        /// 系统要退：不问，停下保存再退（also 同上）。
        case stopThenQuit(Job, also: [ExportPage] = [])
        /// 问：不退出 / 仍然退出（丢掉没存上的）。
        case askUnsaved(String)
    }

    static func decide(headless: Bool, state: State, reason: Reason) -> Decision {
        if headless { return .quit }
        // 批量页的任务优先说；水印页、拼图页同时在导出的，一起停下、确认框里补一句（also）。批量页闲着就只说那几页。
        let pages = state.pageExports
        let job: Job? = state.running ?? (pages.isEmpty ? nil : .pageExport(pages))
        if let job {
            let also: [ExportPage] = state.running == nil ? [] : pages
            return reason == .system ? .stopThenQuit(job, also: also) : .askStop(job, also: also)
        }
        // 系统要退时不弹框：willTerminate 里还会再写一次（BatchStore.retryPersist），写不上也只能这样了。
        if let unsaved = state.unsaved, reason == .user { return .askUnsaved(unsaved) }
        return .quit
    }

    static func runningJob(isRunning: Bool, analyzing: Bool, importing: Bool, queuedCards: Int,
                            longTasks: [LongTaskKind]) -> Job? {
        guard isRunning else { return nil }
        if importing || longTasks.contains(.cardImport) { return .cardImport(queued: queuedCards) }
        if analyzing || longTasks.contains(.analysis) { return .analysis }
        if longTasks.contains(.vlm) { return .vlm }
        if longTasks.contains(.appeal) { return .appeal }
        if let kind = exportKinds.first(where: longTasks.contains) { return .task(kind) }
        return .other
    }

    /// 导出 / 复制叫停以后留下什么（「停下并退出」后面那半句）。JPG 每张编码完整份原子写，复制走 .part 再改名（CardImporter.copyOne），
    /// 叫停时正在写的那一个都不留半截。
    static func taskStopNote(_ kind: LongTaskKind) -> String {
        switch kind {
        case .jpegExport, .highlights:
            return "先停下（已经导出的 JPG 留着，每张写完才落盘，不留半截），再退出。"
        case .copyOriginals:
            return "先停下（已经复制、校验过的原片留着，正在复制的那一个不留半截），再退出；下次再复制，目标里一模一样的会跳过。"
        case .highISO:
            return "先停下（已经复制好的 RAW 留着，正在复制的那一个不留半截），再退出；下次再点，复制好的会跳过。"
        case .analysis, .vlm, .appeal, .cardImport:
            return "先停下（已经写好的文件留着），再退出。"
        }
    }

    /// 退出 Apple 事件里的 kAEQuitReason：注销、重启、关机（含系统先弹确认框的那两种）算系统要退；没有这个属性
    /// （⌘Q 根本没有 Apple 事件；程序坞「退出」是不带原因的 quit 事件）算用户。
    static let systemQuitReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAERestart),
        OSType(kAEShowShutdownDialog), OSType(kAEShutDown),
    ]

    static func reason(quitReasonCode code: OSType?) -> Reason {
        guard let code else { return .user }
        return systemQuitReasons.contains(code) ? .system : .user
    }

    /// 正在处理的这一次退出是谁发起的（只在 applicationShouldTerminate 里调）。
    @MainActor
    static func currentReason() -> Reason {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let code = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        return reason(quitReasonCode: code)
    }

    /// 弹框上的字。primary 是默认按钮（回车）；primaryQuits = 按它是不是退出。
    struct Prompt: Equatable {
        let title: String
        let message: String
        let primary: String
        let secondary: String
        let primaryQuits: Bool
        /// 退出那一边是「丢东西」的（标成破坏性按钮）。
        let quitIsDestructive: Bool
    }

    static func prompt(for decision: Decision) -> Prompt? {
        switch decision {
        case .quit, .stopThenQuit:
            return nil
        case .askUnsaved(let text):
            return Prompt(title: "有改动没存上，现在退出会丢",
                          message: text + "\n\n现在退出，这些改动就没了。",
                          primary: "不退出", secondary: "仍然退出", primaryQuits: false, quitIsDestructive: true)
        case .askStop(let job, let also):
            let base = stopPrompt(job)
            guard !also.isEmpty else { return base }
            // 批量页在跑、水印页 / 拼图页也在导出：一起停下，补一句。
            let more = "\n\n\(ExportPage.labels(also))正在导出，也一起停下（已经写出的文件留着）。"
            return Prompt(title: base.title, message: base.message + more, primary: base.primary,
                          secondary: base.secondary, primaryQuits: base.primaryQuits, quitIsDestructive: base.quitIsDestructive)
        }
    }

    /// 「停下并退出 / 继续」那种确认框的字（只看批量页这一样，或者只有水印页、拼图页在导出）。
    static func stopPrompt(_ job: Job) -> Prompt {
        let stop = "「停下并退出」："
        switch job {
        case .analysis:
            return Prompt(title: "正在分析照片，现在退出会中断",
                          message: stop + "先停下，已经分析完的照片存好（下次分析直接复用，不用从头来），再退出。",
                          primary: "停下并退出", secondary: "继续分析", primaryQuits: true, quitIsDestructive: false)
        case .vlm, .appeal:
            let what = job == .vlm ? "精审幸存照片" : "复审废片"
            let short = job == .vlm ? "精审" : "复审"
            return Prompt(title: "本地模型正在\(what)，现在退出会中断",
                          message: stop + "先停下，已经判完的存好（下次再点「\(what)」从没判的接着跑），"
                              + "后台的 Python 进程一起停掉，再退出。",
                          primary: "停下并退出", secondary: "继续\(short)", primaryQuits: true, quitIsDestructive: false)
        case .cardImport(let queued):
            let rest = queued > 0 ? "排着队的另外 \(queued) 张卡也先不导了。" : ""
            return Prompt(title: "正在从存储卡导入，现在退出会中断",
                          message: stop + "已经拷完、校验过的照片留着，正在拷的那一张不留半截；下次插卡再导入，"
                              + "导过的不会重复拷。" + rest + "导完之前先别格式化存储卡。",
                          primary: "停下并退出", secondary: "继续导入", primaryQuits: true, quitIsDestructive: false)
        case .task(let kind):
            return Prompt(title: "正在\(kind.label)，现在退出会中断",
                          message: stop + taskStopNote(kind),
                          primary: "停下并退出", secondary: "继续\(kind.label)", primaryQuits: true, quitIsDestructive: false)
        case .pageExport(let pages):
            return Prompt(title: "\(ExportPage.labels(pages))正在导出，现在退出会中断",
                          message: stop + "先停下（已经写出的文件留着），再退出。",
                          primary: "停下并退出", secondary: "继续导出", primaryQuits: true, quitIsDestructive: false)
        case .other:
            return Prompt(title: "还有任务在跑，现在退出会中断",
                          message: stop + "先停下（已经写好的文件留着），再退出。",
                          primary: "停下并退出", secondary: "继续", primaryQuits: true, quitIsDestructive: false)
        }
    }
}

/// 退出确认要看的那几样（BatchStore；自检里另有假的）。
@MainActor
protocol QuitTarget: AnyObject {
    var isRunning: Bool { get }
    var analyzing: Bool { get }
    var importing: Bool { get }
    var queuedCardImports: Int { get }
    var runningLongTasks: [LongTaskKind] { get }
    var persistError: String? { get }
    /// 这一次任务已经叫停了（排队的下一张卡开始导时它又变回 false，要再叫停一次）。
    var cancelRequested: Bool { get }
    func cancel()
    func retryPersist() -> Bool
}

extension BatchStore: QuitTarget {
    var runningLongTasks: [LongTaskKind] { longTasks.active }
}

/// 批量页以外自己有导出进度的页（水印页、拼图页）：⌘Q 要看它们是不是正在导出，「停下并退出」时调它们自己的取消，
/// 等 isExporting 落下再放行（优化分析 NR5：以前 runningJob 只看 BatchStore，这两页的 isExporting 没人看，⌘Q 直接退、
/// 导到一半）。AppDelegate 从 AppModel 拿，自检里另有假的。
@MainActor
protocol QuitExportTarget: AnyObject {
    var quitExportPage: QuitGuard.ExportPage { get }
    var isExporting: Bool { get }
    func cancelExport()
}

extension WatermarkStore: QuitExportTarget {
    var quitExportPage: QuitGuard.ExportPage { .watermark }
}

extension CollageStore: QuitExportTarget {
    var quitExportPage: QuitGuard.ExportPage { .collage }
}

/// 判决以外，退出前还要看的存盘：拼图工程（collage.json）、标注（labels.csv）。现在写一次（防抖里还没到点的、上次写失败的），
/// 返回还没存上的原因（nil = 盘上是最新的）。以前 ⌘Q 只看判决那条红条：拼图写不进去（盘满）时直接退，willTerminate 里
/// 再写一次也失败，相册改动就没了。
@MainActor
protocol QuitSaveCheck: AnyObject {
    func unsavedForQuit() -> String?
}

extension CollageStore: QuitSaveCheck {
    /// 原件读坏了、一下没动过的不算（见 projectUnsavedForQuit）。
    func unsavedForQuit() -> String? {
        guard let why = projectUnsavedForQuit() else { return nil }
        let name = photoDir.map { "「\($0.lastPathComponent)」的" } ?? ""
        return "\(name)拼图没存上：\(why)"
    }
}

extension LabelStore: QuitSaveCheck {
    /// flush 只在改过（dirty）时写，写失败的 dirty 留着，所以这一下就是重试。flush 以后 saveError 还在 = 改过、没写上
    /// （写失败，或者 labels.csv 读不出来、已禁用保存）；没改过的不会有 saveError。
    func unsavedForQuit() -> String? {
        flush()
        return saveError.map { "标注没存上：\($0)" }
    }
}

/// 一次退出请求怎么走：问不问、停不停、什么时候回 AppKit。弹框（ask）和回 AppKit（reply）都是注入的：
/// GUI 里是 NSAlert 和 NSApp.reply(toApplicationShouldTerminate:)，自检里是假的。
@MainActor
final class QuitCoordinator {
    let target: QuitTarget
    let headless: Bool
    /// 判决以外还要看的存盘（拼图工程、标注）：AppDelegate 给 AppModel 里的那两个，自检给假的。
    let saveChecks: () -> [QuitSaveCheck]
    /// 水印页、拼图页（正在导出就问、停下时叫停它们、等它们停下）：AppDelegate 给 AppModel 里的那两个，自检给假的。
    let exporters: () -> [QuitExportTarget]
    /// 弹框，返回 true = 选了退出那一边（停下并退出 / 仍然退出）。
    let ask: (QuitGuard.Decision) -> Bool
    let reply: (Bool) -> Void
    /// 叫停以后最多等多久（用户按的 / 系统要退）。等不到也放行：willTerminate 里 VLM 子进程照样整组停掉。
    var userStopTimeout: TimeInterval = 20
    var systemStopTimeout: TimeInterval = 10
    /// 已经在停了（.terminateLater 挂着）。
    private(set) var stopping = false

    init(target: QuitTarget, headless: Bool, saveChecks: @escaping () -> [QuitSaveCheck] = { [] },
         exporters: @escaping () -> [QuitExportTarget] = { [] },
         ask: @escaping (QuitGuard.Decision) -> Bool, reply: @escaping (Bool) -> Void) {
        self.target = target
        self.headless = headless
        self.saveChecks = saveChecks
        self.exporters = exporters
        self.ask = ask
        self.reply = reply
    }

    func state(unsaved: String?) -> QuitGuard.State {
        QuitGuard.State(
            running: QuitGuard.runningJob(isRunning: target.isRunning, analyzing: target.analyzing,
                                          importing: target.importing, queuedCards: target.queuedCardImports,
                                          longTasks: target.runningLongTasks),
            unsaved: unsaved,
            pageExports: exportingPages().map(\.quitExportPage))
    }

    /// 正在导出的水印页 / 拼图页。
    private func exportingPages() -> [QuitExportTarget] {
        exporters().filter(\.isExporting)
    }

    /// 判决那边没存上的先再写一次，拼图、标注现在写一次（还没到点的、上次写失败的），再汇总还没存上的（nil = 都存上了）。
    func unsavedAfterRetry() -> String? {
        if target.persistError != nil { _ = target.retryPersist() }
        let reasons: [String?] = [target.persistError] + saveChecks().map { $0.unsavedForQuit() }
        let text = reasons.compactMap { $0 }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    func shouldTerminate(reason: QuitGuard.Reason) -> NSApplication.TerminateReply {
        if headless { return .terminateNow }
        // 在停了还又按了一次 ⌘Q：不另起一轮，那一次的 terminateLater 还挂着，停完照样退。
        if stopping { return .terminateCancel }
        // 判决没存上的先再写一次、拼图和标注现在写一次，写上了就不用问。
        let decision = QuitGuard.decide(headless: false, state: state(unsaved: unsavedAfterRetry()), reason: reason)
        switch decision {
        case .quit:
            return .terminateNow
        case .askUnsaved:
            return ask(decision) ? .terminateNow : .terminateCancel
        case .askStop:
            guard ask(decision) else { return .terminateCancel }
            beginStopping(reason)
            return .terminateLater
        case .stopThenQuit:
            beginStopping(reason)
            return .terminateLater
        }
    }

    private func beginStopping(_ reason: QuitGuard.Reason) {
        stopping = true
        // 批量页闲着、只有水印页 / 拼图页在导出时不叫批量页的取消（它会把顶栏写成「正在取消...」）。
        if target.isRunning { target.cancel() }
        for page in exportingPages() { page.cancelExport() }
        let limit = reason == .system ? systemStopTimeout : userStopTimeout
        schedule(deadline: Date().addingTimeInterval(limit), reason: reason)
    }

    /// .terminateLater 期间 AppKit 跑的是 NSModalPanelRunLoopMode：默认模式的 Timer 不走，主队列的 asyncAfter 走（common modes）。
    private func schedule(deadline: Date, reason: QuitGuard.Reason) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.tick(deadline: deadline, reason: reason) }
        }
    }

    private func tick(deadline: Date, reason: QuitGuard.Reason) {
        let pages = exportingPages()
        if target.isRunning || !pages.isEmpty {
            if Date() < deadline {
                // 排着队的下一张卡刚开始导（它换了一面新的取消旗子）：一样叫停。
                if target.isRunning && !target.cancelRequested { target.cancel() }
                // 水印页 / 拼图页：等它们手上那一张 / 一页写完、isExporting 落下（叫停之后才开始的新导出也叫停）。
                for page in pages { page.cancelExport() }
                schedule(deadline: deadline, reason: reason)
                return
            }
            SessionFiles.log.error("退出：叫停以后等了 \(Int(reason == .system ? self.systemStopTimeout : self.userStopTimeout)) 秒还没停下，照样退出")
        }
        finish(reason)
    }

    private func finish(_ reason: QuitGuard.Reason) {
        stopping = false
        // 停下来以后判决、拼图、标注还有没存上的（盘满了）：再写一次，还不行而且是用户按的退出，再问一句。
        if let unsaved = unsavedAfterRetry(), reason == .user {
            reply(ask(.askUnsaved(unsaved)))
            return
        }
        reply(true)
    }
}

/// 只在开界面的 LabelGUIApp 上装（@NSApplicationDelegateAdaptor）。只实现 applicationShouldTerminate，别的照 SwiftUI 默认。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// LabelGUIApp.init 建好 AppModel 以后设。
    static weak var batch: BatchStore?
    /// 同一个 AppModel（拼图工程、标注退出前一起看存上没有；水印页、拼图页在不在导出）：和 batch 一起设。
    static weak var model: AppModel?
    private var coordinator: QuitCoordinator?

    /// 判决以外退出前要看的存盘：拼图工程、标注。
    static func saveChecks() -> [QuitSaveCheck] {
        guard let model else { return [] }
        return [model.collage, model.labels]
    }

    /// 批量页以外退出前要看在不在导出的页：水印页、拼图页（NR5）。
    static func exporters() -> [QuitExportTarget] {
        guard let model else { return [] }
        return [model.watermark, model.collage]
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppRuntime.headless, let batch = Self.batch else { return .terminateNow }
        let coordinator = self.coordinator ?? QuitCoordinator(
            target: batch, headless: false, saveChecks: { Self.saveChecks() }, exporters: { Self.exporters() },
            ask: QuitAlert.ask, reply: { NSApplication.shared.reply(toApplicationShouldTerminate: $0) })
        self.coordinator = coordinator
        return coordinator.shouldTerminate(reason: QuitGuard.currentReason())
    }
}

/// 退出确认框。无头一律不弹（直接当成「退出」那一边）—— 正常走不到这里（AppDelegate 先看了 headless），这是第二道闸。
@MainActor
enum QuitAlert {
    static var mayShow: Bool { !AppRuntime.headless }

    static func ask(_ decision: QuitGuard.Decision) -> Bool {
        guard mayShow, let prompt = QuitGuard.prompt(for: decision) else { return true }
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.primary)
        let secondary = alert.addButton(withTitle: prompt.secondary)
        if prompt.primaryQuits {
            secondary.keyEquivalent = "\u{1b}"  // Esc = 继续（不退出）
        } else if prompt.quitIsDestructive {
            secondary.hasDestructiveAction = true
        }
        let first = alert.runModal() == .alertFirstButtonReturn
        return first == prompt.primaryQuits
    }
}
