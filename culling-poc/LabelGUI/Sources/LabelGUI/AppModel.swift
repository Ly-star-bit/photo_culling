import Foundation
import Combine

/// 窗口里的四个 tab。
enum AppTab: Hashable {
    case batch, watermark, collage, labeling
}

/// App 级的状态：五个 store 和当前 tab，整个进程只有一份（LabelGUIApp 建；--app-ui 离屏快照也走同一个 `make`）。
/// 以前批量、标注、插卡在 LabelGUIApp 里，水印、拼图、tab 在 ContentView 里：窗口外面的代码够不着拼图工程和当前 tab。
@MainActor
final class AppModel: ObservableObject {
    /// 给 AI 的实时桥（DESIGN §9.2.1、§5 第 7 层）：GUI 传 `.gui`（真实的 socket 目录，按设置开桥），--live-host 传
    /// `.testHost`（测试自己的 socket 根目录和测试开关，桥总是开着），--app-ui 传 `.none`（不拿锁、不建 socket 目录、不 bind）。
    /// 前两种是同一个 LiveServer、同一套代码。
    enum Bridge {
        case gui
        case testHost(LiveTestOptions)
        case none
    }

    let batch: BatchStore
    let labels: LabelStore
    /// 插卡检测：跟着 app 活（不放在某个 tab 里 —— 没打开的 tab 不一定被建出来）。
    let cardCenter: CardImportCenter
    let watermark: WatermarkStore
    let collage: CollageStore
    @Published var tab: AppTab = .batch
    /// 「这一版新增」弹框开着（升级后第一次打开、「帮助 › 这一版新增」，见 WhatsNew.swift）。
    @Published var whatsNewShown = false
    /// 实时桥（bridge: .none 时是 nil）。
    private(set) var live: LiveServer?
    /// 用户此刻是不是正在 app 里操作（§9.6b）：桥在执行写之前问它。GUI 开桥时才去看 AppKit，别的时候只看 store。
    let interaction = LiveInteraction()
    /// AI 经桥做过的写（app_undo 只撤 AI 自己那一步，§9.3）。
    var aiLog = LiveAILog()
    /// 标题栏副标题的 AI 指示和菜单开关的勾（§9.6a）。没有桥（--app-ui）时文字一直是空的。
    let indicator = LiveIndicator()

    /// 批量页的长任务（导卡、分析、VLM、导出 JPG、复制原片……）在用户不在批量页时跑完 / 出错了：「批量处理」页签上写一句，
    /// 切回批量页就清（优化分析 NU11）。正在跑的进度直接看 batch 的 isRunning / progressFraction，不另记。
    @Published var batchTaskEnd: BatchTaskEnd?
    enum BatchTaskEnd: Equatable { case done, failed }
    /// 长任务开跑那一刻的红字、导入提醒：跑完时变了（多了一条）才算这一次出错，不把早先没关掉的那条算进来。
    private var batchErrorAtStart: String?
    private var batchNoticeAtStart: String?
    private var batchRunWatch: AnyCancellable?
    private var tabWatch: AnyCancellable?

    /// 批量页切场次 → 拼图工程跟着换。
    private var photoDirWatch: AnyCancellable?
    /// 拼图里在用的照片 → 批量页（「废片移到废纸篓」默认不动它们）。
    private var collageInUseWatch: AnyCancellable?

    private init(batch: BatchStore, labels: LabelStore, cardCenter: CardImportCenter,
                 watermark: WatermarkStore, collage: CollageStore) {
        self.batch = batch
        self.labels = labels
        self.cardCenter = cardCenter
        self.watermark = watermark
        self.collage = collage
    }

    static func make(dataDir: URL, pythonRoot: URL, bridge: Bridge) -> AppModel {
        // 实时桥第 1 步：建 store 之前先拿 .live.lock（§9.2.1，R6 §3.2：保证读到的是别人写完的盘）。.gui 最多阻塞 3 s；
        // 拿不到也照常往下建，只是不开桥。.none 什么都不做。
        let live: LiveServer?
        switch bridge {
        case .gui: live = LiveServer.prepare(.gui, dataDir: dataDir)
        case .testHost(let options): live = LiveServer.prepare(.testHost(options), dataDir: dataDir)
        case .none: live = nil
        }
        // 建的顺序和以前一样：批量 → 标注 → 插卡（以前在 LabelGUIApp.init）→ 水印 → 拼图（以前是 ContentView 里
        // 两个 @StateObject，水印在前）。CollageStore.init 会设水印资源目录这类进程级的全局变量，顺序别动。
        let batch = BatchStore(dataDir: dataDir, pythonRoot: pythonRoot)
        let labels = LabelStore(dataDir: batch.sessionDir)
        let cardCenter = CardImportCenter(store: batch)
        let watermark = WatermarkStore(dataDir: dataDir)
        // 水印页导出的文件名记进当前场次的交付对照（DeliveryLedger.swift）。
        watermark.recordDeliveries(into: batch)
        // 批量页这一场开在存储卡上时，水印副本也不写到卡上（审查 S07）。
        watermark.cardRefusal = { [weak batch] in batch?.cardDestinationRefusal($0) }
        let collage = CollageStore(dataDir: dataDir)
        let model = AppModel(batch: batch, labels: labels, cardCenter: cardCenter,
                             watermark: watermark, collage: collage)
        // 批量页的长任务跑完时用户在别的页：记下来，「批量处理」页签上写「完成 / 出错」，切回批量页就清（NU11）。
        // receive(on:) 和下面一样：@Published 在赋值之前就发，跑完那一拍的红字、导入提醒还没写上。
        model.batchRunWatch = batch.$isRunning.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak model] running in
                MainActor.assumeIsolated { model?.batchRunningChanged(running) }
            }
        model.tabWatch = model.$tab.removeDuplicates()
            .sink { [weak model] tab in
                MainActor.assumeIsolated { if tab == .batch { model?.batchTaskEnd = nil } }
            }
        // 拼图工程启动起就挂到当前场次上（以前要等第一次点开拼图 tab），之后每次切场次跟着换：
        // 不点开拼图 tab，拼图工程也是这一场的。
        model.ensureCollageAttached()
        // receive(on:) 不能省：@Published 在赋值之前就发，回调里直接读 batch.sessionDir 拿到的还是上一场。
        model.photoDirWatch = batch.$photoDir.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak model] _ in
                MainActor.assumeIsolated { model?.ensureCollageAttached() }
            }
        // 「废片移到废纸篓」默认不动拼图各页、印样帧、方案里用到的照片：读内存里的拼图工程（collage.json 是防抖保存的，
        // 读盘可能是旧的）。菜单上的张数跟着工程变（攒 0.3 s 再算再推：拖动时不每帧算）；点菜单、真移之前再现取一次，
        // 那时先让拼图挂到这一场（换场次的那一下工程还是上一场的）。
        // 工程这次没读进来（读不出来、解不开，内存里是空的）：带上原因，批量页默认一张都不移（说不清哪些在拼图里用）。
        batch.collageInUseSource = { [weak model] in
            guard let model else { return (ids: [], unknown: nil) }
            model.ensureCollageAttached()
            return (ids: model.collage.project.photoIDsInUseIncludingVariants, unknown: model.collage.projectLoadProblem)
        }
        // 拼图原件读不出来、这次打开以后又改过：批量页切场次前和判决那边一起问（BatchStore.persistBeforeLeaving）。
        batch.collageHasRefusedEdits = { [weak collage] in collage?.hasRefusedEdits == true }
        // 拼图写失败（盘满）、离开前再写一次也写不上：批量页切场次 / 移除 / 清历史一样拦下（不然相册改动切走就丢）。
        batch.collageUnsavedWrite = { [weak collage] in collage?.projectUnsavedForLeaving() }
        // 不 removeDuplicates：换到另一场空工程时 id 一样是空的，「没读进来」却变了；setCollageInUse 自己只在变了时才设。
        model.collageInUseWatch = collage.$project
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .map(\.photoIDsInUseIncludingVariants)
            .sink { [weak batch, weak collage] ids in
                MainActor.assumeIsolated { batch?.setCollageInUse(ids, unknown: collage?.projectLoadProblem) }
            }
        // store 都建好了：写锁文件那一行、设置开着才开 socket（§9.2.1 第 3–5 步）
        model.live = live
        live?.attach(model)
        return model
    }

    /// 「允许 AI 实时操作（MCP）」开关（§9.6a）：GUI 的菜单和测试宿主的 test.set_bridge 走这同一条。关掉 = socket 关掉删掉、
    /// 锁照常持有、锁文件写 bridge:"off"，`--mcp` 读写都回 bridge_off；app 照常开着。设置（UserDefaults）只由 GUI 的菜单写，
    /// 这里不碰。
    func setLiveBridge(_ on: Bool) {
        live?.setBridgeEnabled(on)
    }

    /// 拼图工程挂到批量页当前的场次（同一场再挂只按批量页刷一遍托盘）。和 CollageView.attachSession() 同两行。
    func ensureCollageAttached() {
        let dir = batch.photoDir
        collage.attach(sessionDir: dir == nil ? nil : batch.sessionDir, photoDir: dir, batch: batch)
    }

    /// 批量页多选「拼图」：切到拼图页、带照片进托盘、直接排一版。
    func openCollage(batchIDs ids: [String]) {
        collage.attach(sessionDir: batch.photoDir == nil ? nil : batch.sessionDir,
                       photoDir: batch.photoDir, batch: batch)
        collage.importFromBatch(ids: ids, batch: batch, layout: true)
        tab = .collage
    }

    /// 批量页多选「进托盘」：切到拼图页、带照片进托盘，不排版（做相册：之后点「自动编排」）。
    func openCollageTray(batchIDs ids: [String]) {
        ensureCollageAttached()
        collage.importFromBatch(ids: ids, batch: batch, layout: false)
        tab = .collage
    }

    /// 水印页「拼图 (N) →」/「套到当前拼图」：原图 + 水印设置交给拼图页（水印在拼图里实时画）。
    func openCollage(watermark request: WatermarkCollageRequest) {
        CollageHandoff.fromWatermark(request, batch: batch, collage: collage)
        tab = .collage
    }
}

// MARK: - 「批量处理」页签上的进度（优化分析 NU11）

extension AppModel {
    /// 批量页的 isRunning 变了（已经回到主线程、那一拍写完了）。开跑：清掉上一次的「完成」，记下现在的红字和导卡提示；
    /// 「出错」不清 —— 留到用户回批量页看过（排队的第二张卡一开跑，第一张的「先别格式化」不能被盖成「完成」）。
    /// 跑完：用户这时不在批量页才记（在批量页的话底栏就看得见）。新的红字、新的导卡提示里有出了问题的（没导、先别格式化）
    /// 算「出错」；只是告知的（同名改名导入、导到了还没打开）不算。
    fileprivate func batchRunningChanged(_ running: Bool) {
        if running {
            if batchTaskEnd == .done { batchTaskEnd = nil }
            batchErrorAtStart = batch.lastError
            batchNoticeAtStart = batch.importNotice
            return
        }
        guard tab != .batch else { return }
        batchTaskEnd = Self.batchTaskEnd(previous: batchTaskEnd, errorAtStart: batchErrorAtStart, error: batch.lastError,
                                         noticeAtStart: batchNoticeAtStart, notice: batch.importNotice)
    }

    /// 跑完以后页签上记什么（纯函数，`--ux-selftest` 测）。
    nonisolated static func batchTaskEnd(previous: BatchTaskEnd?, errorAtStart: String?, error: String?,
                                         noticeAtStart: String?, notice: String?) -> BatchTaskEnd {
        if previous == .failed { return .failed }
        if let error, error != errorAtStart { return .failed }
        let before = Set((noticeAtStart ?? "").components(separatedBy: "\n"))
        let fresh = (notice ?? "").components(separatedBy: "\n").filter { !$0.isEmpty && !before.contains($0) }
        return fresh.contains(where: importNoticeIsProblem) ? .failed : .done
    }

    /// 导卡提示里哪一条是出了问题：没导（卡读不了、排队时被拔了、有文件没导进来）、要用户先别格式化卡的。
    /// 别的（同名改名导入、导到了还没打开）只是告知。和 BatchStore.addImportNotice 挑留哪几行用的是同一个记号。
    nonisolated static func importNoticeIsProblem(_ line: String) -> Bool {
        line.contains("先别格式化") || line.contains("没导")
    }

    /// 「批量处理」页签上的字（纯函数，`--ux-selftest` 测）：长任务在跑时带上在做什么、几成（没有进度的写「…」）；
    /// 用户不在批量页时跑完 / 出错了说一句。以前进度条、结果只在批量页底栏：去拼图页、水印页干别的就看不见导卡、
    /// 分析、导出跑完没有。`job` = QuitGuard.runningJob（⌘Q 的确认框按同一个分类说话）。
    nonisolated static func batchTabTitle(job: QuitGuard.Job?, fraction: Double?, ended: BatchTaskEnd?) -> String {
        let name = "批量处理"
        if let job {
            let what: String
            switch job {
            case .analysis: what = "分析"
            case .vlm: what = "精审"
            case .appeal: what = "复审"
            case .cardImport: what = "导卡"
            case .task(let kind): what = kind.label
            case .pageExport, .other: what = "处理中"
            }
            guard let fraction, fraction.isFinite else { return name + " · " + what + "…" }
            // 按 5% 一档跳：分析每张照片回调一次进度，页签按字的宽度排，每 1% 换一次字整排页签就左右挪一下。
            let pct = Int((min(1, max(0, fraction)) * 100).rounded(.down)) / 5 * 5
            return name + " · " + what + " \(pct)%"
        }
        switch ended {
        case .done?: return name + " · 完成"
        case .failed?: return name + " · 出错"
        case nil: return name
        }
    }

    /// 现在这一刻的页签字（ContentView 用；离屏快照 --app-ui 也打印它）。
    var batchTabTitle: String {
        let job = QuitGuard.runningJob(isRunning: batch.isRunning, analyzing: batch.analyzing, importing: batch.importing,
                                       queuedCards: batch.queuedCardImports, longTasks: batch.runningLongTasks)
        return Self.batchTabTitle(job: job, fraction: batch.progressFraction, ended: batchTaskEnd)
    }
}
