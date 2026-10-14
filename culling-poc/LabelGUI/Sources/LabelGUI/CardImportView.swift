import SwiftUI
import AppKit
import Combine

// MARK: - 插卡检测 + 确认框（导入本身在 CardImport.swift）

extension Notification.Name {
    /// 文件夹菜单「从存储卡导入…」：看看现在插着哪些卡。
    static let cardImportRequested = Notification.Name("cardImportRequested")
}

/// 跟着 app 活的：听挂载 / 卸载通知，有相机存储卡就排队弹确认框；点了「导入」的卡也在这里排队，
/// 一张导完接下一张。只在真开界面时 `start()`（无头模式根本走不到 LabelGUIApp）。
@MainActor
final class CardImportCenter: ObservableObject {
    struct Offer: Identifiable {
        let volume: CardImporter.Volume
        var plan: CardImporter.Plan?
        var error: String?
        var includeImported = false
        /// 读卡时的进度话（要逐字节核对目标里已有的同名文件时可能读很久）。
        var planningNote: String?
        var id: String { volume.id }
        var planning: Bool { plan == nil && error == nil }
    }

    /// 点了「导入」、还没开始的（前面有导入或分析在跑）。
    struct Pending {
        let plan: CardImporter.Plan
        let analyzeAfter: Bool
    }

    @Published var offer: Offer?
    /// 排队等着导的卡。有排队的，前一张导完先不分析（BatchStore.queuedCardImports），最后一张导完再分析。
    @Published private(set) var pending: [Pending] = [] {
        didSet { store?.queuedCardImports = pending.count }
    }
    private var queue: [CardImporter.Volume] = []
    private var observers: [NSObjectProtocol] = []
    /// 每次重新读卡加一：「以前导入过的也再导一遍」来回点时，晚到的旧结果不算。
    private var planToken = 0
    /// 正在读卡出计划的取消旗：关掉确认框、卡拔了、重读时举旗 —— 别让后台还在把整张卡读一遍。
    private var planCancel: AnalysisEngine.CancelFlag?
    /// 启动时悄悄读的卡（有新照片才弹），卡拔了就停。
    private var launchScans: [String: AnalysisEngine.CancelFlag] = [:]
    /// 排队的卡等前面的导入 / 分析停下来。
    private var idleWatch: AnyCancellable?
    private weak var store: BatchStore?

    /// 启动时插着的卡点过「不导入」就记一笔（卡 + 这批新照片），下次启动别再问；重新插卡照样问。
    private static let dismissedKey = "cardImport.dismissed"

    init(store: BatchStore) {
        self.store = store
    }

    func start() {
        guard observers.isEmpty, !AppRuntime.headless else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil,
                                               queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.probe(url) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil,
                                               queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.unmounted(url) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .cardImportRequested, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanMounted(manual: true) }
        })
        // 开 app 之前就插着的卡：有新照片才问（导过的卡一直插着，别每次启动都弹）。
        scanMounted(manual: false)
    }

    /// 插上一个盘：是相机存储卡就问（读卡在后台 —— 第一次访问可移除宗卷会等系统授权框）。
    private func probe(_ root: URL) {
        Task.detached(priority: .userInitiated) {
            guard let volume = CardImporter.cardVolume(at: root) else { return }
            await MainActor.run { [weak self] in self?.enqueue(volume) }
        }
    }

    private func scanMounted(manual: Bool) {
        Task.detached(priority: .userInitiated) {
            let cards = CardImporter.mountedCards()
            let denied = manual && cards.isEmpty && CardImporter.removableAccessDenied()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if cards.isEmpty {
                    if denied {
                        self.store?.lastError = "插着的卡读不了：系统设置 › 隐私与安全性 › 文件与文件夹 › 选片工具 › 打开「可移除的宗卷」"
                    } else if manual {
                        self.store?.lastError = "没找到相机存储卡（插上之后根目录要有 DCIM 文件夹）"
                    }
                    return
                }
                for card in cards {
                    if manual { self.enqueue(card) } else { self.offerIfNew(card) }
                }
            }
        }
    }

    /// 启动时用：先在后台读完卡，有新照片、而且这批没被「不导入」过才弹。
    private func offerIfNew(_ volume: CardImporter.Volume) {
        let ledgerURL = appDataDir.appendingPathComponent(CardImporter.ledgerFileName)
        let dest = CardImporter.defaultDestination()
        let flag = AnalysisEngine.CancelFlag()
        launchScans[volume.root.path] = flag
        Task.detached(priority: .utility) {
            let plan = try? CardImporter.plan(source: volume.root, destination: dest,
                                              ledger: CardImporter.Ledger.load(from: ledgerURL),
                                              includeImported: false, cancel: flag)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.launchScans[volume.root.path] = nil
                guard let plan, !flag.isSet, !plan.copies.isEmpty, !Self.wasDismissed(volume, plan) else { return }
                self.enqueue(volume, plan: plan)
            }
        }
    }

    private func enqueue(_ volume: CardImporter.Volume, plan: CardImporter.Plan? = nil) {
        if offer?.volume == volume || queue.contains(volume) { return }
        // 已经点了导入（排着队 / 正在导）的卡：启动时那次慢慢读卡的结果晚到了，别再问一遍（审查发现）。
        if pending.contains(where: { $0.plan.source.path == volume.root.path })
            || store?.importingSource?.path == volume.root.path { return }
        if offer == nil {
            present(volume, plan: plan)
        } else {
            queue.append(volume)
        }
    }

    private func present(_ volume: CardImporter.Volume, plan: CardImporter.Plan? = nil) {
        // 这张卡启动时那次后台读卡不用再等了（框已经弹出来，会自己重读）。
        launchScans[volume.root.path]?.set()
        offer = Offer(volume: volume, plan: plan)
        if plan == nil { replan(includeImported: false) }
        // 在别的 app 里插的卡：Dock 图标跳一下。
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// 读卡出计划（「以前导入过的也再导一遍」切换时重读）。
    func replan(includeImported: Bool) {
        guard var current = offer else { return }
        planCancel?.set()
        let flag = AnalysisEngine.CancelFlag()
        planCancel = flag
        planToken += 1
        let token = planToken
        let volume = current.volume
        current.plan = nil
        current.error = nil
        current.planningNote = nil
        current.includeImported = includeImported
        offer = current
        let ledgerURL = appDataDir.appendingPathComponent(CardImporter.ledgerFileName)
        let dest = CardImporter.defaultDestination()
        Task.detached(priority: .userInitiated) {
            let result: Result<CardImporter.Plan, Error> = Result {
                try CardImporter.plan(source: volume.root, destination: dest,
                                      ledger: CardImporter.Ledger.load(from: ledgerURL),
                                      includeImported: includeImported, cancel: flag) { note in
                    Task { @MainActor [weak self] in
                        guard let self, token == self.planToken, self.offer?.volume == volume else { return }
                        self.offer?.planningNote = note
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, token == self.planToken, self.offer?.volume == volume, !flag.isSet else { return }
                switch result {
                case .success(let plan): self.offer?.plan = plan
                case .failure(let error): self.offer?.error = Self.explain(error)
                }
            }
        }
    }

    /// 「不导入」/「好」。卡上有读不出来的地方就不记「不导入」：那次看到的不全，下次启动还要问。
    func dismiss() {
        planCancel?.set()
        if let offer, let plan = offer.plan, !plan.copies.isEmpty, plan.scanProblems.isEmpty {
            Self.rememberDismissed(offer.volume, plan)
        }
        offer = nil
        showNext()
    }

    /// 「导入」：关掉框、排进队（进度条、取消都在批量页顶栏）。
    func confirm(analyzeAfter: Bool) {
        guard let plan = offer?.plan, store != nil else { return }
        offer = nil
        pending.append(Pending(plan: plan, analyzeAfter: analyzeAfter))
        pump()
        showNext()
    }

    /// 排在最前面的那张能开始就开始：闲着 → 导；在分析 → 停下分析再导（已分析的下次直接复用，导完会
    /// 再分析 —— 确认框上写的是「停下分析并导入」）；在导别的卡、或者做别的事（导出、VLM）→ 等它做完。
    /// 以前只有一个等待位：分析停下来的那一会儿又确认了一张卡，前一张就悄悄没了（审查发现）。
    private func pump() {
        guard let store, let next = pending.first else {
            idleWatch = nil
            return
        }
        if store.isRunning {
            if store.analyzing { store.cancel() }
            guard idleWatch == nil else { return }
            // $isRunning 在赋值之前发值：等它真落成 false 的下一拍再看。
            idleWatch = store.$isRunning.filter { !$0 }.first().sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.idleWatch = nil
                    self?.pump()
                }
            }
            return
        }
        pending.removeFirst()
        store.importFromCard(next.plan, analyzeAfter: next.analyzeAfter)
        // 后面还有排队的：这张导完 isRunning 落回 false 时接着来。
        if !pending.isEmpty { pump() }
    }

    private func showNext() {
        guard offer == nil, !queue.isEmpty else { return }
        present(queue.removeFirst())
    }

    private func unmounted(_ url: URL) {
        queue.removeAll { $0.root.path == url.path }
        launchScans[url.path]?.set()
        // 排着队还没开始导的卡被拔了：不导了，说一声（不然轮到它时报「卡不见了」，用户不知道是哪张）。
        let dropped = pending.filter { $0.plan.source.path == url.path }
        if !dropped.isEmpty {
            pending.removeAll { $0.plan.source.path == url.path }
            for d in dropped {
                store?.addImportNotice("存储卡「\(d.plan.sourceName)」排着队等导入的时候被拔掉了，没导")
            }
        }
        if offer?.volume.root.path == url.path {
            planCancel?.set()
            offer = nil
            showNext()
        }
    }

    private static func explain(_ error: Error) -> String {
        if let code = CardImporter.posixCode(error), code == EPERM || code == EACCES {
            return "没有读存储卡的权限：系统设置 › 隐私与安全性 › 文件与文件夹 › 选片工具 › 打开「可移除的宗卷」"
        }
        return "读不了这张卡：\(CardImporter.describe(error))"
    }

    // 「不导入」的记忆：卡的 UUID（没有就用卷名）+ 这批新照片的个数和大小。

    private static func dismissSignature(_ volume: CardImporter.Volume, _ plan: CardImporter.Plan) -> String {
        "\(volume.uuid ?? volume.name)|\(plan.copies.count)|\(plan.totalBytes)"
    }

    private static func wasDismissed(_ volume: CardImporter.Volume, _ plan: CardImporter.Plan) -> Bool {
        (UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).contains(dismissSignature(volume, plan))
    }

    private static func rememberDismissed(_ volume: CardImporter.Volume, _ plan: CardImporter.Plan) {
        var list = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        list.removeAll { $0.hasPrefix((volume.uuid ?? volume.name) + "|") }
        list.append(dismissSignature(volume, plan))
        UserDefaults.standard.set(Array(list.suffix(30)), forKey: dismissedKey)
    }
}

// MARK: - 确认框

struct CardImportSheet: View {
    @ObservedObject var center: CardImportCenter
    @ObservedObject var store: BatchStore
    /// 点了「导入」（ContentView 切到批量页看进度）。
    var onImport: () -> Void = {}
    @AppStorage("cardImport.analyzeAfter") private var analyzeAfter = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let offer = center.offer {
                header(offer)
                details(offer)
                Divider()
                footer(offer)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func header(_ offer: CardImportCenter.Offer) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("发现存储卡「\(offer.volume.name)」").font(.title3.bold())
                Text(headline(offer)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func headline(_ offer: CardImportCenter.Offer) -> String {
        if offer.error != nil { return "读卡出了问题" }
        guard let plan = offer.plan else { return "正在读取存储卡…" }
        if !plan.copies.isEmpty { return "要把照片导入到这台电脑吗？" }
        if plan.cardFiles == 0 { return "卡上没有照片" }
        return plan.skippedImported > 0 ? "这张卡上的照片都导入过了" : "这些照片目标文件夹里都已经有了"
    }

    @ViewBuilder
    private func details(_ offer: CardImportCenter.Offer) -> some View {
        if let error = offer.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let plan = offer.plan {
            VStack(alignment: .leading, spacing: 10) {
                if !plan.copies.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(plan.shotCount) 张新照片").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        Text(fileLine(plan)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    row("folder", "导入到 " + CardImporter.displayPath(plan.destination) +
                        (plan.existingInDest > 0 ? "（已有 \(plan.existingInDest) 个文件，放在一起）" : ""))
                }
                notes(plan)
                if !plan.copies.isEmpty && !plan.enoughSpace {
                    Label("空间不够：要 \(BatchStore.sizeText(plan.totalBytes))，这块盘只剩 \(BatchStore.sizeText(plan.freeBytes ?? 0))（还得留 1 GB 余量）",
                          systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                options(offer, plan: plan)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(offer.planningNote ?? "数照片、和以前导入过的比对…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    // 前面在忙什么、这张会怎么样。都单独成属性：三元 + 插值写在视图构建器里，Xcode 16 类型检查会超时。

    /// 前面有卡在导、或者有卡排着队：这张排在后面。
    private var queuesBehind: Bool { store.importing || !center.pending.isEmpty }
    /// 在分析（而且没有排队的卡）：可以「停下分析并导入」。
    private var stopsAnalysis: Bool { store.isRunning && store.analyzing && center.pending.isEmpty }
    /// 在做别的事（导出、VLM）：等它做完，或者自己点「停下当前任务」。
    private var blockedByOtherTask: Bool { store.isRunning && !queuesBehind && !store.analyzing }

    private var busyText: String {
        let what = store.progressText.isEmpty ? "处理中" : store.progressText
        if queuesBehind { return "正在导入另一张卡（\(what)），这张排在它后面，导完接着导" }
        if store.analyzing { return "\(what)。停下分析没关系：已分析的下次直接复用，导完会一起分析" }
        return "正在处理别的任务（\(what)），做完才能导入"
    }

    private func importTitle(_ plan: CardImporter.Plan?) -> String {
        let count = plan?.shotCount ?? 0
        if queuesBehind { return "排队导入 \(count) 张" }
        if stopsAnalysis { return "停下分析并导入 \(count) 张" }
        return "导入 \(count) 张"
    }

    private func fileLine(_ plan: CardImporter.Plan) -> String {
        let files = plan.copies.count
        let raw = plan.rawCount
        var parts: [String] = []
        if files != plan.shotCount { parts.append("\(files) 个文件") }
        if raw > 0 && raw < files { parts.append("RAW \(raw) · JPG 等 \(files - raw)") } else if raw == files { parts.append("全是 RAW") }
        parts.append(BatchStore.sizeText(plan.totalBytes))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func notes(_ plan: CardImporter.Plan) -> some View {
        // 卡上有读不出来的地方：放最前面、橙色 —— 照片可能比上面数的多（卡坏了一块的样子）。
        if let problems = plan.scanProblemText {
            Label {
                Text(problems + "，那里的照片导不进来。先别格式化这张卡").fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
        }
        if plan.skippedImported > 0 {
            row("checkmark.circle", "\(plan.skippedImported) 张以前导入过" + previousText(plan) + "，这次跳过")
        }
        if plan.skippedInDest > 0 {
            row("equal.circle", "\(plan.skippedInDest) 张目标文件夹里已经有一模一样的，不再复制")
        }
        if plan.renamedShots > 0 {
            // 别用 textformat.abc：中文系统下这个符号画成「甲乙丙」。
            row("pencil", "\(plan.renamedShots) 张和目标里别的照片重名，整组改名（如 IMG_0001_2），RAW+JPG 还是一对")
        }
        if plan.videoCount > 0 {
            row("video.slash", "卡上还有 \(plan.videoCount) 个视频，不导入（只导照片）")
        }
        if let other = plan.otherFilesText {
            row("doc.questionmark", "卡上还有 " + other)
        }
    }

    private func previousText(_ plan: CardImporter.Plan) -> String {
        guard let first = plan.previousFolders.first else { return "" }
        let more = plan.previousFolders.count > 1 ? " 等" : ""
        // 以前导到的文件夹已经删了 / 挪走了：「都导入过了」读着像没事，其实电脑上已经没有了。
        let gone = plan.previousFolderGone ? "，那个文件夹已经不在了，要重新导就勾下面" : ""
        return "（在 \(CardImporter.displayPath(URL(fileURLWithPath: first)))\(more)\(gone)）"
    }

    private func row(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func options(_ offer: CardImportCenter.Offer, plan: CardImporter.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !plan.copies.isEmpty && plan.enoughSpace {
                Toggle("导入完直接开始分析", isOn: $analyzeAfter)
            }
            if plan.skippedImported > 0 || offer.includeImported {
                Toggle("以前导入过的也再导一遍", isOn: Binding(
                    get: { offer.includeImported },
                    set: { center.replan(includeImported: $0) }))
                    .help("比如以前导到的文件夹已经删了。导进同一个文件夹时，内容一模一样的还是不会重复复制")
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func footer(_ offer: CardImportCenter.Offer) -> some View {
        let canImport = offer.plan.map { !$0.copies.isEmpty && $0.enoughSpace } ?? false
        // 前面有卡在导 / 排着队：排在后面。在分析：「停下分析并导入」。别的任务（导出、VLM）：等它，或自己停。
        if canImport && (store.isRunning || !center.pending.isEmpty) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass").foregroundStyle(.orange)
                Text(busyText)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if blockedByOtherTask {
                    Button("停下当前任务") { store.cancel() }.controlSize(.small)
                }
            }
        }
        HStack {
            Text("只复制，不会删除或改动存储卡上的任何文件")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if canImport {
                Button("不导入") { center.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importTitle(offer.plan)) {
                    onImport()
                    center.confirm(analyzeAfter: analyzeAfter)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(blockedByOtherTask)
            } else {
                Button(offer.planning ? "不导入" : "好") { center.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - 离屏快照

/// LABELGUI_DATA_DIR=<临时> LabelGUI --card-ui <card_dir> <out.png> --dest <dir> [--reimport] [--running | --importing]
///   [--planning] [--free-bytes N] [--name 卷名]
/// 用假卡读出真的计划，把确认框画成 PNG（界面不能开）。--running = 假装正在分析；--importing = 假装在导另一张卡；
/// --planning = 还在读卡；--free-bytes = 假装目标盘只剩这么多。
enum CardImportSnapshot {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        guard args.count > flagIndex + 2, let destPath = option("--dest") else {
            print("用法: --card-ui <card_dir> <out.png> --dest <dir>")
            exit(1)
        }
        CollageCLI.requireIsolatedDataDir("--card-ui")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let card = URL(fileURLWithPath: args[flagIndex + 1])
        let out = URL(fileURLWithPath: args[flagIndex + 2])
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        let center = CardImportCenter(store: store)
        let volume = CardImporter.Volume(root: card, name: option("--name") ?? "EOS_DIGITAL", uuid: nil)
        var offer = CardImportCenter.Offer(volume: volume)
        if !args.contains("--planning") {
            do {
                offer.plan = try CardImporter.plan(source: card, destination: URL(fileURLWithPath: destPath),
                                                   ledger: .load(from: appDataDir.appendingPathComponent(CardImporter.ledgerFileName)),
                                                   includeImported: args.contains("--reimport"))
                offer.includeImported = args.contains("--reimport")
            } catch {
                offer.error = "读不了这张卡：\(error.localizedDescription)"
            }
        }
        // --free-bytes N：假装目标盘只剩 N 字节（看「空间不够」那一行）。
        if let free = option("--free-bytes").flatMap(Int64.init) { offer.plan?.freeBytes = free }
        center.offer = offer
        if args.contains("--running") {
            store.isRunning = true
            store.analyzing = true
            store.progressText = "分析中 120/400"
        }
        if args.contains("--importing") {
            store.isRunning = true
            store.importing = true
            store.progressText = "导入中 120/624 个文件 · 3.1 GB/18.4 GB"
        }
        let view = CardImportSheet(center: center, store: store)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: out)) != nil else {
            print("写不出 \(out.path)")
            exit(1)
        }
        if let plan = offer.plan { print(CardImportCLI.describe(plan)) }
        print("确认框快照 \(Int(size.width))x\(Int(size.height)) · \(out.path)")
        exit(0)
    }
}

// MARK: - 排队自检

/// LABELGUI_DATA_DIR=<临时> LabelGUI --card-queue-selftest <cardA> <cardB> --dest <dir>
/// 两张假卡走 CardImportCenter 的确认 / 排队 / 停下分析（界面上点不到，只能这样验）：
/// 1. A 导完、正在分析时确认 B →「停下分析并导入」：B 导完、再分析一次；
/// 2. A 还在导时又确认 B → B 排在后面：A 导完先不分析，B 导完只分析一次。
/// 每一拍都像 BatchView 闲着时那样，有导完的就打开。
enum CardImportQueueSelftest {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        guard let destIndex = args.firstIndex(of: "--dest"), args.count > destIndex + 1 else {
            print("用法: --card-queue-selftest <cardA> <cardB> --dest <dir>")
            exit(2)
        }
        CollageCLI.requireIsolatedDataDir("--card-queue-selftest")
        let cardA = URL(fileURLWithPath: args[flagIndex + 1]).standardizedFileURL
        let cardB = URL(fileURLWithPath: args[flagIndex + 2]).standardizedFileURL
        let root = URL(fileURLWithPath: args[destIndex + 1]).standardizedFileURL
        let ledgerURL = appDataDir.appendingPathComponent(CardImporter.ledgerFileName)
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        let center = CardImportCenter(store: store)
        var analysisStarts = 0
        let watch = store.$analyzing.sink { if $0 { analysisStarts += 1 } }
        var ok = true
        func expect(_ cond: Bool, _ what: String) {
            print((cond ? "  ok   " : "  FAIL ") + what)
            if !cond { ok = false }
        }
        // 和 BatchView 一样：每导完（或没导成）一张的那一刻看要不要打开 —— 而且是同步地看，比排队的下一张
        // 先跑（BatchView 的 onChange 实测就是这个顺序，审查发现的那个坑就出在这个顺序上）。
        let openWatch = store.$importCompletions.dropFirst().sink { _ in
            store.openFinishedImportIfReady(userBusy: false)
        }
        func spin(until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if done() { return true }
            }
            return false
        }
        /// includeImported：几轮导进不同的文件夹，账本里已经有了，默认按「以前导入过的也再导一遍」出计划。
        func offer(_ card: URL, into dest: URL, includeImported: Bool = true) {
            guard let plan = try? CardImporter.plan(source: card, destination: dest,
                                                    ledger: .load(from: ledgerURL), includeImported: includeImported) else {
                print("读不了 \(card.path)")
                exit(1)
            }
            center.offer = CardImportCenter.Offer(volume: CardImporter.Volume(root: card, name: card.lastPathComponent, uuid: nil),
                                                  plan: plan)
        }
        func fileCount(_ dir: URL) -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
        }
        func photoCount(_ card: URL) -> Int {
            let e = FileManager.default.enumerator(at: card.appendingPathComponent("DCIM"), includingPropertiesForKeys: nil)
            var n = 0
            while let url = e?.nextObject() as? URL {
                if CardImporter.photoExtensions.contains(url.pathExtension.lowercased()) { n += 1 }
            }
            return n
        }
        let expected = photoCount(cardA) + photoCount(cardB)
        let allDone = { center.pending.isEmpty && !store.isRunning && !store.importing && store.finishedImport == nil }
        /// 打开的是不是这个文件夹（/tmp 和 /private/tmp 是同一个，解析软链接再比）。
        func opened(_ dir: URL) -> Bool {
            store.photoDir?.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path
        }

        print("情形 1：A 导完正在分析，确认 B（停下分析并导入）")
        let stopDir = root.appendingPathComponent("stop")
        let before0 = analysisStarts
        offer(cardA, into: stopDir)
        center.confirm(analyzeAfter: true)
        // 数「开始过几次」而不是看 analyzing：照片解不开时分析一眨眼就完，轮询会错过（发布版上就错过过）。
        expect(spin { analysisStarts > before0 }, "A 导完自动打开、开始分析")
        let before1 = analysisStarts
        // 分析还在跑就走「停下分析并导入」，已经跑完就直接导 —— 两条路最后的样子一样，只把走了哪条打出来。
        print(store.analyzing ? "  （分析还在跑：停下分析并导入）" : "  （分析已经跑完：直接导入）")
        offer(cardB, into: stopDir)
        center.confirm(analyzeAfter: true)
        expect(spin(until: allDone), "B 导完、分析跑完")
        expect(fileCount(stopDir) == expected, "A、B 都在 stop/（\(fileCount(stopDir))/\(expected) 个文件）")
        expect(analysisStarts - before1 == 1, "B 导完又分析了一次（\(analysisStarts - before1) 次）")
        expect(store.progressText.hasPrefix("完成"), "最后那次分析跑完了（\(store.progressText)）")
        expect(opened(stopDir), "打开的是 stop/（\(store.photoDir?.path ?? "-")）")

        print("情形 2：A 还在导，又确认 B（排在后面）")
        let queueDir = root.appendingPathComponent("queue")
        let before2 = analysisStarts
        offer(cardA, into: queueDir)
        center.confirm(analyzeAfter: true)
        offer(cardB, into: queueDir)
        center.confirm(analyzeAfter: true)
        expect(store.importing && center.pending.count == 1, "B 排在 A 后面")
        expect(spin(until: allDone), "两张都导完、分析跑完")
        expect(fileCount(queueDir) == expected, "A、B 都在 queue/（\(fileCount(queueDir))/\(expected) 个文件）")
        expect(analysisStarts - before2 == 1, "只在最后分析了一次（\(analysisStarts - before2) 次）")
        expect(opened(queueDir), "打开的是 queue/（\(store.photoDir?.path ?? "-")）")

        // 后面那张没导成 / 没东西可导 / 不要分析：前面导完的那批照样要打开、分析（审查发现以前会没人管）。
        func tailCase(_ title: String, _ name: String, second: (URL) -> Void, extra: (() -> Void)? = nil) {
            print(title)
            let dir = root.appendingPathComponent(name)
            let before = analysisStarts
            offer(cardA, into: dir)
            center.confirm(analyzeAfter: true)
            second(dir)
            extra?()
            expect(spin(until: allDone), "都跑完了")
            expect(opened(dir), "前面那批的文件夹打开了（\(store.photoDir?.path ?? "-")）")
            expect(analysisStarts - before == 1, "分析了一次（\(analysisStarts - before) 次）")
            expect(store.progressText.hasPrefix("完成"), "分析跑完了（\(store.progressText)）")
        }
        let cardC = root.appendingPathComponent("cardC")
        try? FileManager.default.copyItem(at: cardB, to: cardC)
        let lockedDCIM = cardC.appendingPathComponent("DCIM")
        if getuid() != 0 {
            tailCase("情形 3：后面那张卡读不了", "failB", second: { dir in
                offer(cardC, into: dir)
                center.confirm(analyzeAfter: true)
            }, extra: {
                // 确认之后、轮到它之前，卡变得读不了（坏卡 / 没权限）。
                try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedDCIM.path)
            })
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDCIM.path)
            expect((store.importNotice ?? "").contains("cardC"), "提醒里说了 cardC 没导")
        }
        tailCase("情形 4：后面那张没有新照片（同一张卡又点了一次导入）", "zeroB", second: { dir in
            offer(cardA, into: dir, includeImported: false)
            center.confirm(analyzeAfter: true)
        })
        tailCase("情形 5：后面那张没勾「导完分析」", "noAnalyzeB", second: { dir in
            offer(cardB, into: dir)
            center.confirm(analyzeAfter: false)
        })
        if let notice = store.importNotice { print("  导入提醒：\(notice)") }
        withExtendedLifetime(watch) {}
        withExtendedLifetime(openWatch) {}
        print(ok ? "排队自检通过" : "排队自检失败")
        exit(ok ? 0 : 1)
    }
}
