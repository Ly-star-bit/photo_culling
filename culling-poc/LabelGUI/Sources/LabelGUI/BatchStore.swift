import Foundation
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Verdict for one photo under the current slider thresholds. Recomputed live on
/// every slider move — cheap, because the expensive analysis numbers (sharpness,
/// clip pcts, VLM scores) were produced once by the Python pipeline and cached in
/// the JSON files this reads.
enum Verdict: String, CaseIterable {
    case reject = "废片"
    case usable = "可用"
    case pick = "精选"

    /// ONE place for the verdict palette — it used to be re-declared in four
    /// views. Green/blue/red is the photographer convention; the symbol is the
    /// colour-blind fallback (a red and a green dot look alike to 8% of men).
    var color: Color {
        switch self {
        case .pick: return .green
        case .usable: return .blue
        case .reject: return .red
        }
    }

    var symbol: String {
        switch self {
        case .pick: return "star.fill"
        case .usable: return "circle.fill"
        case .reject: return "xmark"
        }
    }
}

extension Notification.Name {
    /// Posted after a batch analysis finishes writing fresh manifest/layer JSONs,
    /// so other stores (labeling tab) reload without an app restart.
    static let analysisDidFinish = Notification.Name("cullingAnalysisDidFinish")
}

struct BatchItem: Identifiable {
    let id: String
    let previewPath: String
    let rawPath: String
    /// Fast full-res decode source (JPEG of a RAW+JPEG pair, else the file itself).
    let decodePath: String
    let sharpness: Double
    let worstClipPct: Double
    /// Engine's absolute-threshold eye call — only a fallback for sessions
    /// analyzed by older builds. Current verdicts come from `dynamicEyeClosed`.
    let eyeClosed: Bool?
    /// Apple FaceCaptureQuality 0-1 (nil when no face) — learned "how well was
    /// this face captured", robust to content differences that fool Laplacian.
    let faceQuality: Double?
    /// Subject-sized faces in frame (background bystanders excluded).
    let faceCount: Int
    /// Primary face bbox [x0, y0, x1, y1] normalized top-left, for image overlays.
    let faceBbox: [Double]?
    /// Primary face's unpadded area fraction — 景别 signal for quality thresholds.
    let faceAreaPct: Double?
    /// Every subject face (bbox + eye state + raw EAR + area). eyeClosed here is
    /// REWRITTEN by applyThresholds with the burst-relative decision so the
    /// face-crop strip badges agree with the verdict.
    var faces: [FaceInfo]
    let burstGroup: Int
    let expressionScore: Int?
    let vlmReject: Bool
    let vlmCompositionIssues: [String]
    let vlmReason: String?
    /// Appeal-court verdicts (nil = that charge was never re-examined).
    let appealClosedEyes: Bool?
    let appealSubjectSharp: Bool?
    let appealIntentionalExposure: Bool?
    let appealReason: String?
    let captureTime: Date?
    let exif: ExifMeta?
    let horizonDeg: Double?
    /// Time-gap chapter (仪式/晚宴/外景...) — a >15min shooting pause starts a new one.
    var chapter: Int = 0
    /// 机身型号。双机位婚礼两台机器同一秒各拍一张，是两个角度不是重复 —— 「场」
    /// 必须按机身分开切，否则纯时间会把它们并进同一堆。
    var camera: String?
    /// 「场」(take)：连续按快门的一串，间隔超过 takeGapSec 就换一场。
    ///
    /// 和 `burstGroup` 是两个不同的东西，不要混用：
    /// - `burstGroup`（引擎算的，2s + phash 汉明≤10）= **近似重复**，几乎同一张。
    ///   组内相对闭眼基线、人脸质量对比、自动「只留最佳」都挂在它上面，动它会
    ///   静默改掉所有历史场次的判决，所以它不动。
    /// - `take`（这里，纯拍摄时间 + 机身）= **一场**，人在动、表情在变的那种重复。
    ///   堆栈网格、只看待处理、保留选中·其余废片、检视器同组条都用它。
    ///
    /// 为什么不能用 phash 划场：64 位 DCT phash 在无关图像之间的期望汉明距离是 32，
    /// 而实测同一场里相邻两张就能跑到 18-36（`photot`：时间窗内 10 对相邻照片，
    /// 6 对被 phash 拦掉）。判别力恰好在"重复"这个区间饱和，划不动场。
    var take: Int = 0
    var verdict: Verdict = .usable
    var rejectReasons: [String] = []
    /// Charges the VLM appeal cleared this photo of ("虚焦"/"闭眼"/"曝光裁切") —
    /// shown as the 平反 badge so the photographer sees WHY it walked.
    var vlmRescued: [String] = []
    /// Burst-relative eye decision computed by applyThresholds (nil = no
    /// judgment: no usable face, or all faces too small to read reliably).
    var dynamicEyeClosed: Bool?
    /// Position in the manifest (folder listing order) — the 文件名 sort key.
    var order: Int = 0

    /// Below the safety-shutter rule — motion blur likely; info badge, not a reject.
    var slowShutter: Bool { exif?.slowShutter ?? false }
    /// Noticeably tilted horizon; info badge, not a reject (Vision guesses on
    /// horizon-less scenes).
    var tilted: Bool { horizonDeg.map { abs($0) > 3.0 } ?? false }
}

/// Shared mutable slot so the UI can terminate a Python subprocess started from a
/// detached task.
final class ProcessBox: @unchecked Sendable {
    private var process: Process?
    private var terminatedByUs = false
    private let lock = NSLock()
    func set(_ p: Process?) { lock.lock(); process = p; lock.unlock() }
    func terminate() {
        lock.lock(); terminatedByUs = true; process?.terminate(); lock.unlock()
    }
    /// 用户点了“取消”吗？terminate() 让退出码非 0，不加区分就会把用户主动取消
    /// 报成“VLM 分析失败 (服务在跑吗?)”。
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return terminatedByUs }
    func resetCancellation() { lock.lock(); terminatedByUs = false; lock.unlock() }
}

/// 后台线程持续收集子进程 stderr。必须边跑边收：只在进程退出后才读的话，
/// layer2.py 的 tqdm 进度条会写满 16-64KB 的管道缓冲区，Python 卡在 write、
/// 我们卡在 waitUntilExit，界面永远停在“VLM 分析中”。
final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        // 只有末尾会展示给用户，别让刷屏的 traceback 撑大内存。
        if data.count > 64_000 { data.removeFirst(data.count - 64_000) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@MainActor
final class BatchStore: ObservableObject {
    @Published var photoDir: URL?
    @Published var items: [BatchItem] = []
    @Published var isRunning = false
    @Published var progressText = ""
    /// 0...1 while a long task reports progress; nil hides the bar.
    @Published var progressFraction: Double?
    @Published var lastError: String?
    /// nil = show everything; otherwise only the chosen verdict group.
    @Published var verdictFilter: Verdict?
    /// When set, the 废片 section shows only rejects carrying this reason —
    /// "audit every 闭眼 kill in one pass" instead of hunting badges.
    @Published var reasonFilter: String?
    /// Show only photos within ±15% of an active threshold — the ones on the
    /// knife's edge, worth eyeballing after a slider change. Runtime hedge for
    /// thresholds that were never calibrated against real bad photos.
    @Published var borderlineFilter = false
    /// Photographer's final say: id → forced verdict, wins over every threshold.
    /// Persisted so re-opening the app keeps manual decisions.
    @Published private(set) var overrides: [String: Verdict] = [:]

    // Slider thresholds. Sharpness below → reject; worst clip pct above → reject;
    // face quality below → reject (0 disables; only applies to photos with a face).
    // Sharpness is the Tenengrad RMS-gradient metric (feature-ROI, Gaussian
    // pre-blur) — measured 68-93 on the all-sharp test set; the old Laplacian
    // numbers (253-647) do NOT transfer.
    @Published var sharpnessThreshold: Double = 45 { didSet { onThresholdEdited() } }
    @Published var exposureThreshold: Double = 0.15 { didSet { onThresholdEdited() } }
    @Published var faceQualityThreshold: Double = 0 { didSet { onThresholdEdited() } }

    /// 「同一场最大间隔」。超过这个间隔就算换了一场。
    ///
    /// 做成滑杆而不是写死常数，是因为它量的是**摄影师的按快门节奏**，不是画质
    /// 严格度：宴会厅抓拍和影棚摆拍差一个数量级，而且 `photot`（21 张、单场）
    /// 这点数据不足以支撑任何一个"科学的"固定值。所以给默认值 + 实时组数反馈，
    /// 让用户自己拧。也正因为是节奏不是严格度，它不进 CullPreset。
    /// 每章节最少保留几张（0 = 只在全灭时警告，即以前的行为）。Aftershoot 的
    /// "每场景最少选 N"；对我们来说是 coverage protection 的可调版本：仪式只留了
    /// 2 张不是废片多，是交付事故。
    @Published var minKeepersPerChapter: Int =
        UserDefaults.standard.integer(forKey: "batch.minKeepersPerChapter") {
        didSet {
            UserDefaults.standard.set(minKeepersPerChapter, forKey: "batch.minKeepersPerChapter")
            applyThresholds()
        }
    }

    static let defaultTakeGapSec: Double = 8
    @Published var takeGapSec: Double = defaultTakeGapSec { didSet { onTakeGapEdited() } }

    /// 连拍去重：开启后每个连拍组只留下最佳的那张，组内其余**未被人工改判**的照片
    /// 自动带上「连拍重复」理由淘汰。这是规则式的（不写进 overrides），关掉开关
    /// 整组立刻全部回来——和手动的「保留选中·其余废片」正好互补，后者是永久的。
    /// 默认关：老场次重新打开时废片数不该无声无息地翻倍。
    @Published var rejectBurstDuplicates: Bool =
        UserDefaults.standard.bool(forKey: "batch.rejectBurstDuplicates") {
        didSet {
            UserDefaults.standard.set(rejectBurstDuplicates, forKey: "batch.rejectBurstDuplicates")
            applyThresholds()
        }
    }

    // MARK: Threshold persistence (per shoot, plus a "last used" default)

    /// Thresholds are a per-shoot decision (a dim banquet needs a looser
    /// sharpness line than a studio day), so they live in the session dir and
    /// come back with it. They used to reset to the defaults on every launch:
    /// yesterday's 废片 count was different this morning and nobody knew why.
    private struct ThresholdState: Codable {
        var sharpness: Double
        var exposure: Double
        var faceQuality: Double
        /// 可选：老的 thresholds.json 没有这个键，解码后回落到默认值。
        var takeGap: Double?
    }

    private var thresholdSaveTask: Task<Void, Never>?
    /// Set while a preset/session load assigns all three at once, so the
    /// didSet chain recomputes and saves once instead of three times.
    private var batchingThresholds = false

    private func thresholdsPath(in dir: URL) -> URL { dir.appendingPathComponent("thresholds.json") }

    private func loadThresholds() {
        let candidates = [thresholdsPath(in: sessionDir), thresholdsPath(in: dataDir)]
        let state = candidates.lazy
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(ThresholdState.self, from: $0) }
            .first ?? ThresholdState(sharpness: 45, exposure: 0.15, faceQuality: 0, takeGap: nil)
        batchingThresholds = true
        sharpnessThreshold = state.sharpness
        exposureThreshold = state.exposure
        faceQualityThreshold = state.faceQuality
        takeGapSec = state.takeGap ?? Self.defaultTakeGapSec
        batchingThresholds = false
    }

    /// Debounced: a slider drag fires once per pixel. Writes the session copy
    /// and the app-wide "last used" copy that seeds brand-new shoots.
    private func scheduleThresholdSave() {
        thresholdSaveTask?.cancel()
        let state = ThresholdState(sharpness: sharpnessThreshold, exposure: exposureThreshold,
                                   faceQuality: faceQualityThreshold, takeGap: takeGapSec)
        let targets = [thresholdsPath(in: dataDir)] + (photoDir != nil ? [thresholdsPath(in: sessionDir)] : [])
        thresholdSaveTask = Task { [targets] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(state) else { return }
            for url in targets { try? data.write(to: url, options: .atomic) }
        }
    }

    /// One-knob presets so a first-time user never faces three raw sliders with
    /// opaque units. Any manual slider move flips the selection to 自定义 (nil).
    enum CullPreset: String, CaseIterable {
        case loose = "宽松"
        case standard = "标准"
        case strict = "严格"

        /// (sharpness, exposureClipPct, minFaceQuality). Sharpness values are in
        /// the NEW Tenengrad scale, provisionally set from the all-sharp test
        /// set's 68-93 spread (no true blur samples yet — tighten against real
        /// bad frames when a shoot provides them). minFaceQuality is the
        /// CLOSE-UP threshold; the 景别 curve relaxes it for small faces, and
        /// burst groups use intra-group comparison instead.
        var thresholds: (Double, Double, Double) {
            switch self {
            case .loose: return (25, 0.30, 0)
            case .standard: return (45, 0.15, 0.30)
            case .strict: return (60, 0.08, 0.45)
            }
        }
    }

    /// Derived from the slider values (nil = 自定义) instead of stored: a stored
    /// flag started every launch at 自定义 even when the numbers matched 标准.
    var currentPreset: CullPreset? {
        CullPreset.allCases.first {
            $0.thresholds == (sharpnessThreshold, exposureThreshold, faceQualityThreshold)
        }
    }

    func applyPreset(_ preset: CullPreset) {
        batchingThresholds = true
        let (sharp, exposure, quality) = preset.thresholds
        sharpnessThreshold = sharp
        exposureThreshold = exposure
        faceQualityThreshold = quality
        batchingThresholds = false
        onThresholdEdited()
    }

    private func onThresholdEdited() {
        guard !batchingThresholds else { return }
        applyThresholds()
        scheduleThresholdSave()
    }

    /// 换了间隔就地重切「场」。不碰 burstGroup，所以判决一个字都不会变 ——
    /// 变的只有堆栈怎么分堆。
    private func onTakeGapEdited() {
        guard !batchingThresholds else { return }
        var updated = items
        Self.assignTakes(&updated, gapSec: takeGapSec)
        items = updated
        rebuildGroupSizes()
        // 判决不受影响（场不参与任何判决规则），但 pendingTakeCount 住在 Derived
        // 里，得跟着重算一次。
        applyThresholds()
        scheduleThresholdSave()
    }

    // MARK: - Derived snapshot (rebuilt once per verdict pass, read by every render)

    /// Everything the status bar, top bar, chips and sliders display. These
    /// were computed properties over `items`; a single body pass read
    /// verdictCounts nine times and each arrow-key repeat re-filtered 3000
    /// large structs a dozen times over. Now applyThresholds builds this once.
    struct Derived {
        var verdictCounts: (reject: Int, usable: Int, pick: Int) = (0, 0, 0)
        var reasonCounts: [String: Int] = [:]
        var chapterSegments: [ChapterSegment] = []
        var chapterWarnings: [String] = []
        var borderlineCount = 0
        /// 还需要人取舍的「场」数：留下 2 张以上没被淘汰的。一场里已经定成
        /// 1 张精选、其余废片的，活儿干完了，不该再占着网格。顶栏每次重绘都读它,
        /// 所以和 verdictCounts 一起在 rebuildDerived 里算一次,别做成 O(n) 计算属性。
        var pendingTakeCount = 0
        /// 场内排名（1 起，只排没被淘汰的）：缩略图上的 #1 #2 #3。用户常从一场里
        /// 挑 3 张 —— 这告诉他算法眼里的前三是哪几张，他只需要否决而不是从零找。
        /// 纯展示，不碰判决。
        var takeRank: [String: Int] = [:]
        var thresholdSuggestions: [ThresholdSuggestion] = []
        /// 每场的成员下标（场按 id 递增 = 时间序，场内按拍摄顺序）。分组网格以前每次
        /// 按键都对 3000 张做一遍 Dictionary(grouping:) + 每场排序 —— 现在这里算一次，
        /// 视图只做 O(n) 的筛选。下标指向 `items`，只在 rebuildDerived 之后有效。
        var takeRows: [(take: Int, indices: [Int])] = []
        var recommendationSummary: (takes: Int, rejects: Int) = (0, 0)
        /// 按判决模式三个分区的成员下标（items 顺序）。以前 sectionItems 每次按键把
        /// 3000 张过滤三遍；现在只对本分区做临界/理由筛选。
        var byVerdict: [Verdict: [Int]] = [:]
        /// 控制面板四张直方图的分箱。以前每次重绘 `store.items.map(\.sharpness)` 出
        /// 3000 元素数组再进 Canvas 分箱 —— 按一下方向键就是 4 次。
        var sharpnessBins: [Int] = []
        var exposureBins: [Int] = []
        var faceQualityBins: [Int] = []
        /// Rejects with no manual override — the appeal court's docket.
        var autoRejectCount = 0
        /// Photos with no burst sibling carrying a face-quality score: the only
        /// ones the ABSOLUTE face-quality line applies to (grouped photos are
        /// judged relative to their group's best), so the slider histogram
        /// shows just these instead of implying the line kills burst frames.
        var faceQualityAbsoluteValues: [Double] = []
        var indexByID: [String: Int] = [:]
    }

    @Published private(set) var derived = Derived()

    var verdictCounts: (reject: Int, usable: Int, pick: Int) { derived.verdictCounts }
    var reasonCounts: [String: Int] { derived.reasonCounts }
    var chapterSegments: [ChapterSegment] { derived.chapterSegments }
    var chapterWarnings: [String] { derived.chapterWarnings }
    var borderlineCount: Int { derived.borderlineCount }
    var pendingTakeCount: Int { derived.pendingTakeCount }
    var takeRank: [String: Int] { derived.takeRank }
    var thresholdSuggestions: [ThresholdSuggestion] { derived.thresholdSuggestions }
    var takeRows: [(take: Int, indices: [Int])] { derived.takeRows }
    var byVerdict: [Verdict: [Int]] { derived.byVerdict }
    var sharpnessBins: [Int] { derived.sharpnessBins }
    var exposureBins: [Int] { derived.exposureBins }
    var faceQualityBins: [Int] { derived.faceQualityBins }

    // 直方图的坐标轴。视图和分箱必须用同一组，否则线画错位置。
    static let histogramBinCount = 40
    static let sharpnessHistRange = 0.0...150.0
    static let exposureHistRange = 0.005...0.5
    static let faceQualityHistRange = 0.0...1.0
    static let captureGapHistRange = 0.0...60.0

    static func histogramBins(_ values: [Double], range: ClosedRange<Double>, sqrtScale: Bool) -> [Int] {
        var bins = [Int](repeating: 0, count: histogramBinCount)
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return bins }
        for v in values {
            var f = max(0, min(1, (v - range.lowerBound) / span))
            if sqrtScale { f = f.squareRoot() }
            bins[min(histogramBinCount - 1, Int(f * Double(histogramBinCount)))] += 1
        }
        return bins
    }
    var autoRejectCount: Int { derived.autoRejectCount }

    func item(withID id: String) -> BatchItem? {
        // The index is rebuilt by applyThresholds; guard against an `items`
        // assignment that ever skips it so a stale index can't go out of bounds.
        guard let idx = derived.indexByID[id], idx < items.count, items[idx].id == id else {
            return items.first { $0.id == id }
        }
        return items[idx]
    }

    /// burst_group -> member count. 只给"近似重复"用（相对基线是否成立、自动
    /// 只留最佳），堆栈的 ×N 角标看的是 takeSizes。
    /// Cached: group membership only changes when a new analysis loads, but the
    /// grid re-renders on every slider tick / focus change and reads this 3×.
    private(set) var groupSizes: [Int: Int] = [:]
    /// take -> member count，堆栈 ×N 角标和「多张场」统计。
    private(set) var takeSizes: [Int: Int] = [:]

    /// 每台机身上相邻两张的拍摄间隔（秒），用来画「同一场最大间隔」滑杆下面那张
    /// 直方图 —— 摄影师按快门的节奏分布，一眼能看出该把线画在哪。
    private(set) var captureGaps: [Double] = []
    /// 拍摄间隔直方图的分箱，随 captureGaps 一起算。
    private(set) var captureGapBins: [Int] = []

    private func rebuildGroupSizes() {
        var sizes: [Int: Int] = [:]
        var takes: [Int: Int] = [:]
        for item in items {
            sizes[item.burstGroup, default: 0] += 1
            takes[item.take, default: 0] += 1
        }
        groupSizes = sizes
        takeSizes = takes

        var gaps: [Double] = []
        let byCamera = Dictionary(grouping: items.filter { $0.captureTime != nil },
                                  by: { $0.camera ?? "" })
        for (_, shots) in byCamera {
            let times = shots.compactMap(\.captureTime).sorted()
            for i in 1..<max(1, times.count) {
                gaps.append(times[i].timeIntervalSince(times[i - 1]))
            }
        }
        captureGaps = gaps
        captureGapBins = Self.histogramBins(gaps, range: Self.captureGapHistRange, sqrtScale: true)
    }

    private func rebuildDerived(groupQCount: [Int: Int]) {
        var d = Derived()
        var r = 0, u = 0, p = 0
        d.indexByID.reserveCapacity(items.count)
        for (idx, item) in items.enumerated() {
            d.indexByID[item.id] = idx
            switch item.verdict {
            case .reject: r += 1
            case .usable: u += 1
            case .pick: p += 1
            }
            for reason in item.rejectReasons { d.reasonCounts[reason, default: 0] += 1 }
            if isBorderline(item) { d.borderlineCount += 1 }
            if item.verdict == .reject, overrides[item.id] == nil { d.autoRejectCount += 1 }
            if let q = item.faceQuality, (groupQCount[item.burstGroup] ?? 0) < 2 {
                d.faceQualityAbsoluteValues.append(q)
            }
        }
        var aliveByTake: [Int: [BatchItem]] = [:]
        for item in items where item.verdict != .reject { aliveByTake[item.take, default: []].append(item) }
        d.pendingTakeCount = aliveByTake.values.filter { $0.count > 1 }.count
        for (_, alive) in aliveByTake where alive.count > 1 {
            let ranked = alive.sorted { Self.scoreKey($0) > Self.scoreKey($1) }
            for (i, item) in ranked.prefix(3).enumerated() { d.takeRank[item.id] = i + 1 }
        }
        d.verdictCounts = (r, u, p)
        for (idx, item) in items.enumerated() { d.byVerdict[item.verdict, default: []].append(idx) }
        d.sharpnessBins = Self.histogramBins(items.map(\.sharpness), range: Self.sharpnessHistRange, sqrtScale: false)
        d.exposureBins = Self.histogramBins(items.map(\.worstClipPct), range: Self.exposureHistRange, sqrtScale: true)
        d.faceQualityBins = Self.histogramBins(d.faceQualityAbsoluteValues, range: Self.faceQualityHistRange, sqrtScale: false)
        (d.chapterSegments, d.chapterWarnings) = Self.chapterSummary(items, minKeepers: minKeepersPerChapter)
        d.thresholdSuggestions = computeThresholdSuggestions()
        let order = items.indices.sorted { a, b in
            let ia = items[a], ib = items[b]
            if ia.take != ib.take { return ia.take < ib.take }
            let ta = ia.captureTime ?? .distantPast, tb = ib.captureTime ?? .distantPast
            return ta != tb ? ta < tb : ia.id < ib.id
        }
        var rows: [(take: Int, indices: [Int])] = []
        for idx in order {
            if rows.last?.take == items[idx].take { rows[rows.count - 1].indices.append(idx) }
            else { rows.append((items[idx].take, [idx])) }
        }
        d.takeRows = rows
        var recTakes = 0, recRejects = 0
        for (_, alive) in aliveByTake where alive.contains(where: { $0.verdict == .pick }) {
            let losers = alive.filter { $0.verdict == .usable && overrides[$0.id] == nil }.count
            if losers > 0 { recTakes += 1; recRejects += losers }
        }
        d.recommendationSummary = (recTakes, recRejects)
        derived = d
    }

    // MARK: - Sort order (拍摄时间 / 文件名)

    enum SortOrder: String, CaseIterable {
        case captureTime = "拍摄时间"
        case filename = "文件名"
        /// 评分高的在前（表情 > 人脸质量 > 锐度，同 scoreKey）—— 交付前过最终
        /// 选片时精选区最好的排最前。
        case score = "评分"
    }

    /// Two-camera weddings interleave DSCF/_DSC by filename; capture time is
    /// what the photographer means by "in order". Persisted app-wide.
    @Published var sortOrder: SortOrder = SortOrder(
        rawValue: UserDefaults.standard.string(forKey: "batch.sortOrder") ?? "") ?? .captureTime {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "batch.sortOrder")
            var sorted = items
            Self.sort(&sorted, by: sortOrder)
            items = sorted
            applyThresholds()
        }
    }

    /// Stable: ties (and undated photos, which sort last) fall back to the
    /// manifest order so two runs never disagree.
    private static func sort(_ array: inout [BatchItem], by order: SortOrder) {
        switch order {
        case .filename:
            array.sort { $0.order < $1.order }
        case .score:
            array.sort { a, b in
                let ka = scoreKey(a), kb = scoreKey(b)
                return ka == kb ? a.order < b.order : ka > kb
            }
        case .captureTime:
            array.sort { a, b in
                switch (a.captureTime, b.captureTime) {
                case let (ta?, tb?) where ta != tb: return ta < tb
                case (nil, .some): return false
                case (.some, nil): return true
                default: return a.order < b.order
                }
            }
        }
    }

    /// App Support root (settings.json, runtime/, sessions/ live here).
    let dataDir: URL
    /// The culling-poc Python checkout, needed only for the optional VLM step.
    /// Mutable: the migration import repoints it at the imported runtime copy.
    @Published var pythonRoot: URL
    private var cancelFlag = AnalysisEngine.CancelFlag()
    private let processBox = ProcessBox()

    // MARK: - Sessions (one shoot = one folder = one persistent dataset)

    struct SessionEntry: Codable, Identifiable, Hashable {
        let key: String
        let path: String
        let name: String
        var lastAnalyzed: String
        var photoCount: Int
        /// Security-scoped bookmark of the photo folder — re-grants file access
        /// after relaunch for TCC-protected locations (桌面/文稿/外置盘), where a
        /// bare path would open the session but fail on XMP/导出 writes.
        /// Optional so pre-bookmark sessions.json files still decode.
        var bookmark: Data? = nil
        var id: String { key }
    }

    @Published private(set) var recentSessions: [SessionEntry] = []
    /// Artifacts for the CURRENT shoot (manifest/layer JSONs, previews, overrides).
    private(set) var sessionDir: URL

    private var sessionsIndexPath: URL { dataDir.appendingPathComponent("sessions.json") }

    /// Stable FNV-1a hash of the folder path — survives restarts (Swift's
    /// hashValue doesn't), filesystem-safe, collision-irrelevant at this scale.
    nonisolated static func sessionKey(for folder: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in folder.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    init(dataDir: URL, pythonRoot: URL) {
        self.dataDir = dataDir
        self.pythonRoot = pythonRoot
        self.sessionDir = dataDir.appendingPathComponent("sessions/default")
        loadSessionsIndex()
        // Reopen the most recent shoot so relaunching the app doesn't lose context.
        if let last = recentSessions.first {
            switchSession(to: URL(fileURLWithPath: last.path))
        } else {
            loadThresholds()
            loadOverrides()
            loadResults()
            applyThresholds()
        }
    }

    // MARK: - Folder access persistence

    /// Folder currently held open via a resolved security-scoped bookmark.
    /// In this non-sandboxed build start/stop are harmless no-ops, but the
    /// bookmarks make folder access survive a future sandboxed/notarized build
    /// and folder renames today.
    private var accessedFolder: URL?

    /// The key naming the open session's directory, and the path it was derived
    /// from. Both are pinned by switchSession and must never be recomputed from
    /// `photoDir` — that one tracks renames, these must not.
    private var currentSessionKey = "default"
    private var currentSessionPath = ""

    nonisolated private static func makeBookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope,
                               includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    /// Swap security-scoped access from the previous folder to this one, using
    /// the stored bookmark when there is one. Returns the resolved URL (tracks
    /// a folder that was renamed/moved since last time); falls back to the
    /// given URL when no bookmark exists or resolution fails.
    private func restoreAccess(to folder: URL) -> URL {
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
        guard let bookmark = recentSessions
            .first(where: { $0.key == Self.sessionKey(for: folder) })?.bookmark else { return folder }
        var stale = false
        let resolved = (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let resolved else { return folder }
        if resolved.startAccessingSecurityScopedResource() {
            accessedFolder = resolved
        }
        return resolved
    }

    /// Point the store at the session for this folder: existing results load
    /// instantly (no re-analysis); a new folder starts empty until 开始分析.
    func switchSession(to folder: URL) {
        // 处理中切换会把 A 的流式结果灌进 B 的网格（同名文件还会顶掉 B 的行），
        // 而 isRunning 永远停在 true —— 之后 runAnalysis 的 guard 让“重新分析”
        // 静默失效，用户点了毫无反应。先取消，再切。
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再切换文件夹"
            return
        }
        let resolved = restoreAccess(to: folder)
        photoDir = resolved
        // Session key from the URL the caller had (the recents entry's path):
        // keeps existing results reachable even if the bookmark resolved the
        // folder to a renamed location. It is PINNED for as long as this session
        // is open — recomputing it from `photoDir` (the resolved, possibly
        // renamed path) made runAnalysis write into sessions/<old key> while the
        // index recorded <new key>: results vanished and were later pruned.
        currentSessionKey = Self.sessionKey(for: folder)
        currentSessionPath = folder.path
        sessionDir = dataDir.appendingPathComponent("sessions/\(currentSessionKey)")
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        overrides = [:]
        overrideUndoStack = []
        reasonFilter = nil
        borderlineFilter = false
        // 判决筛选也要跟着清：留着"只看废片"切到新场次，网格里只有废片，
        // 看起来像是"照片少了一大半"。
        verdictFilter = nil
        lastError = nil
        loadReviewPosition()
        loadThresholds()
        loadOverrides()
        loadResults()
        applyThresholds()
        // Cached results load happily from a folder that no longer exists — say
        // so up front instead of letting 导出/分析 fail silently later.
        if !FileManager.default.fileExists(atPath: resolved.path) {
            lastError = "「\(folder.lastPathComponent)」的照片文件夹已不存在 (被删除、改名或所在硬盘未挂载)。" +
                        "下面是上次分析的缓存结果，重新分析/导出/写 XMP 都会失败。"
        }
        // Register a session that HAS cached results as soon as it's opened, not
        // just after an analysis: pruneOrphanedSessions deletes every
        // sessions/<key> missing from this index, so a session that was only
        // ever opened (and manually re-judged — overrides.json lives in there)
        // used to be wiped the next time any other folder was analyzed.
        // Empty ones stay out — a mistaken pick shouldn't land in the menu
        // forever, or evict (and delete) the oldest real session at the 15 cap.
        if !items.isEmpty { touchSessionIndex() }
        refreshSessionAvailability()
        postResultsChanged(previewsChanged: false)
    }

    /// One notification for "results on disk changed". `previewsChanged` is
    /// true only after an analysis rewrote previews/*.jpg — that is the only
    /// case the thumbnail caches must be dropped (they used to be wiped on
    /// every session switch, VLM pass and trash run, re-decoding everything).
    private func postResultsChanged(previewsChanged: Bool) {
        NotificationCenter.default.post(name: .analysisDidFinish, object: nil,
                                        userInfo: ["dir": sessionDir, "previewsChanged": previewsChanged])
    }

    /// Register a session written outside the GUI (the `--analyze` CLI path) so
    /// pruneOrphanedSessions treats it as live instead of deleting its previews
    /// and results the next time the app analyzes anything.
    nonisolated static func registerSession(dataDir: URL, folder: URL, photoCount: Int) {
        let indexPath = dataDir.appendingPathComponent("sessions.json")
        let key = sessionKey(for: folder)
        var entries = (try? Data(contentsOf: indexPath))
            .flatMap { try? JSONDecoder().decode([SessionEntry].self, from: $0) } ?? []
        entries.removeAll { $0.key == key }
        entries.insert(SessionEntry(
            key: key, path: folder.standardizedFileURL.path, name: folder.lastPathComponent,
            lastAnalyzed: ISO8601DateFormatter().string(from: Date()),
            photoCount: photoCount,
            bookmark: makeBookmark(for: folder)
        ), at: 0)
        if let data = try? JSONEncoder().encode(Array(entries.prefix(15))) {
            try? data.write(to: indexPath, options: .atomic)
        }
    }

    private func loadSessionsIndex() {
        guard let data = try? Data(contentsOf: sessionsIndexPath),
              let entries = try? JSONDecoder().decode([SessionEntry].self, from: data) else { return }
        // 同样封顶 15：写入端一直在截断，读取端不截断的话，一个手改过的
        // sessions.json 就能让菜单无限长下去。
        recentSessions = Array(entries.prefix(15))
        refreshSessionAvailability()
    }

    private func saveSessionsIndex() {
        if let data = try? JSONEncoder().encode(recentSessions) {
            try? data.write(to: sessionsIndexPath, options: .atomic)
        }
    }

    private func touchSessionIndex() {
        guard let folder = photoDir, !currentSessionPath.isEmpty else { return }
        // The PINNED key/path from switchSession, never recomputed from the
        // resolved folder — see the comment there. `name` does follow the
        // resolved folder so a renamed shoot shows its new name in the menu.
        let key = currentSessionKey
        // Fresh bookmark while we demonstrably have access; keep the old one if
        // creation fails (shouldn't, but a stale bookmark beats none).
        let bookmark = Self.makeBookmark(for: folder)
            ?? recentSessions.first(where: { $0.key == key })?.bookmark
        var entries = recentSessions.filter { $0.key != key }
        entries.insert(SessionEntry(
            key: key, path: currentSessionPath, name: folder.lastPathComponent,
            lastAnalyzed: ISO8601DateFormatter().string(from: Date()),
            photoCount: items.count,
            bookmark: bookmark
        ), at: 0)
        recentSessions = Array(entries.prefix(15))
        saveSessionsIndex()
        pruneOrphanedSessions()
        refreshSessionAvailability(force: true)
    }

    /// Delete session dirs that fell out of the recents index — one big shoot's
    /// previews run to hundreds of MB and nothing else ever removes them.
    private func pruneOrphanedSessions() {
        let keep = Set(recentSessions.map(\.key))
        let root = dataDir.appendingPathComponent("sessions")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs
        where dir.hasDirectoryPath
            && dir.lastPathComponent != "default"
            && !keep.contains(dir.lastPathComponent) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Recents housekeeping

    /// Recents whose photo folder is gone from disk. Their cached verdicts still
    /// open fine (previews live in the session dir, not next to the originals),
    /// which is exactly the trap: the grid looks healthy while 分析/导出/XMP/
    /// 废纸篓/全图缩放 all fail on the missing originals. Menu greys these out.
    @Published private(set) var missingSessionKeys: Set<String> = []

    /// Bytes each cached session occupies on disk. Previews run ~190KB/photo, so
    /// a 3000-photo shoot is ~570MB and a full 15-entry menu can reach several
    /// GB — the menu showed no hint of that, and 移除/清除 were the only way to
    /// reclaim it. Measured off-main because it walks every preview directory.
    @Published private(set) var sessionSizes: [String: Int64] = [:]

    var totalSessionBytes: Int64 { sessionSizes.values.reduce(0, +) }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshSessionSizes() {
        let root = dataDir.appendingPathComponent("sessions")
        let keys = recentSessions.map(\.key)
        Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for key in keys {
                sizes[key] = Self.directorySize(root.appendingPathComponent(key))
            }
            let result = sizes
            await MainActor.run { [weak self] in self?.sessionSizes = result }
        }
    }

    /// Where this shoot's folder actually is right now: the recorded path if it
    /// still exists, else wherever the bookmark says it moved to. nil = deleted
    /// (or on an unmounted volume). A rename/move is NOT missing — the bookmark
    /// tracks it and the session key stays keyed to the original path.
    nonisolated private static func liveFolder(for entry: SessionEntry) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: entry.path) { return URL(fileURLWithPath: entry.path) }
        guard let bookmark = entry.bookmark else { return nil }
        var stale = false
        let resolved = (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let resolved, fm.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    private var lastAvailabilityRefresh = Date.distantPast

    /// Recompute which recents point at folders that no longer exist. Runs off
    /// the main thread: fileExists on an unmounted network volume can block for
    /// seconds, and this fires on every app activation. Throttled so alt-tabbing
    /// back and forth doesn't re-walk 15 session directories each time.
    func refreshSessionAvailability(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastAvailabilityRefresh) > 20 else { return }
        lastAvailabilityRefresh = Date()
        let entries = recentSessions
        Task.detached(priority: .utility) {
            let missing = Set(entries.filter { Self.liveFolder(for: $0) == nil }.map(\.key))
            await MainActor.run { [weak self] in self?.missingSessionKeys = missing }
        }
        refreshSessionSizes()
    }

    /// Drop one shoot from the menu and delete its cached analysis (previews,
    /// layer results, overrides). The photos themselves are never touched.
    /// Removing the shoot that's currently open also clears the view — its
    /// previews are about to vanish, so leaving it on screen would show holes.
    func removeSession(_ entry: SessionEntry) {
        // 引擎正在往这个目录里写预览图时把目录删掉 = 分析中途报错。
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再移除历史记录"
            return
        }
        recentSessions.removeAll { $0.key == entry.key }
        saveSessionsIndex()
        if photoDir != nil, currentSessionKey == entry.key {
            resetToNoSession()
        }
        try? FileManager.default.removeItem(
            at: dataDir.appendingPathComponent("sessions/\(entry.key)"))
        refreshSessionAvailability(force: true)
        progressText = "已从列表移除「\(entry.name)」(照片本身未动)"
    }

    /// Empty the menu and wipe every cached session. Originals untouched —
    /// reopening a folder just means analyzing it again.
    func clearRecentSessions() {
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再清除历史记录"
            return
        }
        let count = recentSessions.count
        recentSessions = []
        saveSessionsIndex()
        resetToNoSession()
        pruneOrphanedSessions()     // empty keep-set: removes every session dir
        refreshSessionAvailability(force: true)
        progressText = "已清除 \(count) 条历史记录 (照片本身未动)"
    }

    /// Back to the launch state with no shoot loaded: `sessions/default` holds
    /// no manifest, so loadResults() empties the grid.
    private func resetToNoSession() {
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
        photoDir = nil
        currentSessionKey = "default"
        currentSessionPath = ""
        sessionDir = dataDir.appendingPathComponent("sessions/default")
        overrides = [:]
        overrideUndoStack = []
        reasonFilter = nil
        borderlineFilter = false
        verdictFilter = nil
        lastError = nil
        loadReviewPosition()
        loadThresholds()
        loadOverrides()
        loadResults()
        applyThresholds()
    }

    // MARK: - Review position (续审: 3000 张分两晚审完)

    /// Last photo the user was on in 审片模式 — entering review mode with no
    /// grid focus resumes here instead of photo 1.
    private(set) var lastReviewedID: String?

    private var reviewStatePath: URL { sessionDir.appendingPathComponent("review_state.json") }

    func saveReviewPosition(_ id: String) {
        lastReviewedID = id
        if let data = try? JSONEncoder().encode(["last": id]) {
            try? data.write(to: reviewStatePath, options: .atomic)
        }
    }

    private func loadReviewPosition() {
        lastReviewedID = (try? Data(contentsOf: reviewStatePath))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["last"]
    }

    // MARK: - VLM server management (MiniCPM-V 4.6 via Ollama)

    /// q4 quant (the `latest` tag, 1.6GB): the user's daily machine is a fanless
    /// MacBook Air — half the weights/bandwidth of f16 runs cooler and faster,
    /// and our yes/no culling questions don't feel the quantization.
    nonisolated static let ollamaModel = "minicpm-v4.6"

    /// uv lives in the Homebrew prefix — /opt/homebrew on Apple Silicon,
    /// /usr/local on Intel Macs. Resolved once at first use.
    nonisolated static let uvExecutable: String =
        ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/uv"

    nonisolated func checkVLMServer() async -> Bool {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/version")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Ollama runs as a login item / menu-bar app; `open -a Ollama` starts the
    /// daemon if it's not up and is a no-op if it is.
    func startVLMServer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Ollama"]
        do {
            try process.run()
            progressText = "Ollama 启动中..."
            Task { [weak self] in
                for _ in 0..<10 {
                    try? await Task.sleep(for: .seconds(1))
                    if await self?.checkVLMServer() == true {
                        self?.progressText = "VLM 服务已就绪 (MiniCPM-V 4.6)"
                        return
                    }
                }
                self?.lastError = "Ollama 启动超时 — 装了 Ollama.app 吗? 模型: ollama pull \(Self.ollamaModel)"
            }
        } catch {
            lastError = "启动 Ollama 失败: \(error.localizedDescription)"
        }
    }

    func cancel() {
        cancelFlag.set()
        processBox.terminate()
        progressText = "正在取消..."
    }

    // MARK: - Manual overrides

    private var overridesPath: URL { sessionDir.appendingPathComponent("overrides.json") }

    func setOverride(_ id: String, _ verdict: Verdict?) {
        setOverrideBatch([id], verdict)
    }

    /// Undo stack for verdict overrides: one entry per user action, holding each
    /// touched id's PREVIOUS override (nil = was automatic). ⌘Z pops — a
    /// mis-keyed digit in tag-and-advance review mode costs one keystroke, not
    /// a hunt back through the filmstrip.
    @Published private var overrideUndoStack: [[(id: String, previous: Verdict?)]] = []

    var canUndoOverride: Bool { !overrideUndoStack.isEmpty }

    func undoLastOverride() {
        guard let last = overrideUndoStack.popLast() else { return }
        for (id, previous) in last {
            if let previous {
                overrides[id] = previous
            } else {
                overrides.removeValue(forKey: id)
            }
        }
        saveOverrides()
        applyThresholds()
    }

    /// Batch form (⌘-click multi-select): one save + one recompute for the lot.
    func setOverrideBatch(_ ids: some Collection<String>, _ verdict: Verdict?) {
        overrideUndoStack.append(ids.map { ($0, overrides[$0]) })
        if overrideUndoStack.count > 100 { overrideUndoStack.removeFirst() }
        for id in ids {
            if let verdict {
                overrides[id] = verdict
            } else {
                overrides.removeValue(forKey: id)
            }
        }
        saveOverrides()
        applyThresholds()
    }

    /// 连拍组定案：`keepers` 留下，`candidates` 里其余的全部设为废片。
    ///
    /// 整组只压**一条**撤销记录——拆成两次 setOverrideBatch 的话 ⌘Z 要按两下才
    /// 能把组恢复原状，中间那一步还是个没人想要的半成品状态。
    ///
    /// 留下的那几张明确写成 override（默认精选），而不是"恢复自动"：用户挑中的
    /// 那张要是正好卡在闭眼/虚焦线下面，"恢复自动"会让它当场掉回废片里，
    /// 等于这次定案白点了。
    func keepOnly(_ keepers: some Collection<String>,
                  among candidates: some Collection<String>,
                  keeperVerdict: Verdict = .pick) {
        let all = Array(candidates)
        guard !all.isEmpty else { return }
        let keep = Set(keepers)
        overrideUndoStack.append(all.map { ($0, overrides[$0]) })
        if overrideUndoStack.count > 100 { overrideUndoStack.removeFirst() }
        for id in all {
            overrides[id] = keep.contains(id) ? keeperVerdict : .reject
        }
        saveOverrides()
        applyThresholds()
    }

    /// 一个「场」的全部成员 id，按当前网格顺序。
    func takeMemberIDs(_ take: Int) -> [String] {
        items.filter { $0.take == take }.map(\.id)
    }

    /// 有 2 张以上的「场」数 / 这些场里的照片总数 —— 回答"这场拍摄到底有多少
    /// 重复要取舍"。滑杆旁边实时显示，用户拧间隔时能立刻看到分堆变化。
    var takeStats: (takes: Int, photos: Int) {
        var t = 0, p = 0
        for (_, count) in takeSizes where count > 1 { t += 1; p += count }
        return (t, p)
    }

    /// 有 2 张以上成员的**近似重复**组数 / 照片数 —— 自动「只留最佳」作用的范围，
    /// 和上面的「场」不是一回事。
    var burstGroupStats: (groups: Int, photos: Int) {
        var g = 0, p = 0
        for (_, count) in groupSizes where count > 1 { g += 1; p += count }
        return (g, p)
    }

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: overridesPath),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        overrides = raw.compactMapValues(Verdict.init(rawValue:))
    }

    private func saveOverrides() {
        let raw = overrides.mapValues(\.rawValue)
        if let data = try? JSONEncoder().encode(raw) {
            // .atomic: a crash mid-write here used to cost every manual verdict
            // of the shoot.
            try? data.write(to: overridesPath, options: .atomic)
        }
    }

    /// Canonical display order for reject-reason chips and slider kill-counts.
    static let reasonOrder = ["连拍重复", "闭眼", "虚焦", "曝光裁切", "人脸质量低", "VLM建议淘汰"]

    /// Within ±15% of any ACTIVE threshold — the photos a small slider nudge
    /// would flip either way.
    func isBorderline(_ item: BatchItem) -> Bool {
        let sharp = sharpnessThreshold
        if sharp > 0, abs(item.sharpness - sharp) <= sharp * 0.15 { return true }
        let clip = exposureThreshold
        if abs(item.worstClipPct - clip) <= clip * 0.15 { return true }
        if faceQualityThreshold > 0, let quality = item.faceQuality {
            let threshold = Self.compensatedQualityThreshold(
                slider: faceQualityThreshold, faceAreaPct: item.faceAreaPct)
            if abs(quality - threshold) <= threshold * 0.15 { return true }
        }
        return false
    }

    // MARK: - Pipeline invocation

    /// Streaming buffer: analysis results accumulate here (main actor) and are
    /// flushed into `items` in small batches, so the grid fills as the engine
    /// works instead of appearing all at once after minutes on a big shoot.
    private var provisionalBuffer: [BatchItem] = []
    private var provisionalCount = 0

    private func appendProvisional(_ analysis: AnalysisEngine.PhotoAnalysis) {
        guard isRunning else { return }  // late arrivals after cancel/error
        provisionalCount += 1
        provisionalBuffer.append(Self.provisionalItem(from: analysis, group: -provisionalCount))
        // Batched: per-photo @Published mutation would make SwiftUI diff the
        // whole grid ~25×/s. Every 20 photos keeps it visibly "live" and cheap.
        if provisionalBuffer.count >= 20 { flushProvisional() }
    }

    private func flushProvisional() {
        guard !provisionalBuffer.isEmpty else { return }
        // Re-analyzed photos replace their stale rows in place; new ones append.
        let incoming = Set(provisionalBuffer.map(\.id))
        var updated = items
        // Keep a re-analyzed photo's slot in the folder order; brand-new ones
        // go after the last known position so the grid doesn't shuffle mid-run.
        let oldOrder = Dictionary(updated.map { ($0.id, $0.order) }, uniquingKeysWith: { a, _ in a })
        var nextOrder = (updated.map(\.order).max() ?? -1) + 1
        updated.removeAll { incoming.contains($0.id) }
        for var fresh in provisionalBuffer {
            if let known = oldOrder[fresh.id] {
                fresh.order = known
            } else {
                fresh.order = nextOrder
                nextOrder += 1
            }
            updated.append(fresh)
        }
        Self.assignTakes(&updated, gapSec: takeGapSec)
        Self.sort(&updated, by: sortOrder)
        items = updated
        provisionalBuffer.removeAll()
        rebuildGroupSizes()
        applyThresholds()
    }

    /// BatchItem from an in-flight engine result. Burst group is a unique
    /// NEGATIVE placeholder (no siblings yet → no false group dynamics); the
    /// real groups arrive with loadResults() when the run finishes.
    private static func provisionalItem(from a: AnalysisEngine.PhotoAnalysis, group: Int) -> BatchItem {
        BatchItem(
            id: a.id,
            previewPath: a.previewRelPath,
            rawPath: a.rawPath,
            decodePath: a.decodePath,
            sharpness: a.sharpness,
            worstClipPct: max(a.highlightClipPct, a.shadowClipPct),
            eyeClosed: a.eyeClosed,
            faceQuality: a.faceQuality,
            faceCount: a.subjectFaceCount,
            faceBbox: a.faceBbox,
            faceAreaPct: a.faceAreaPct,
            faces: a.subjectFaces.map {
                FaceInfo(bbox: $0.bbox, eyeClosed: $0.eyeClosed, ear: $0.ear, areaPct: $0.areaPct)
            },
            burstGroup: group,
            expressionScore: nil,
            vlmReject: false,
            vlmCompositionIssues: [],
            vlmReason: nil,
            appealClosedEyes: nil,
            appealSubjectSharp: nil,
            appealIntentionalExposure: nil,
            appealReason: nil,
            captureTime: a.captureTime,
            exif: ExifMeta(shutterSec: a.shutterSec, aperture: a.aperture, iso: a.iso,
                           focal35: a.focal35, lens: a.lensModel),
            horizonDeg: a.horizonDeg,
            camera: a.cameraModel
        )
    }

    func runAnalysis() {
        guard let dir = photoDir else { return }
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag
        let data = sessionDir
        // Old items STAY on screen: with incremental reuse most of them are
        // still valid, and re-analyzed photos stream in as in-place
        // replacements (flushProvisional swaps by id).
        provisionalBuffer = []
        provisionalCount = 0

        Task.detached { [weak self] in
            // Runs natively (ImageIO/Vision) — no Python, no external deps.
            // Artifacts keep the prepare.py/layer1.py format so the VLM stage and
            // evaluate.py stay unchanged.
            await MainActor.run { [weak self] in self?.progressText = "分析中..." }
            let summary: AnalysisEngine.Summary
            do {
                summary = try AnalysisEngine.analyzeFolder(
                    dir, dataDir: data, cancel: flag,
                    onPhoto: { analysis in
                        Task { @MainActor [weak self] in
                            self?.appendProvisional(analysis)
                        }
                    }
                ) { message in
                    let fraction = Self.parseFraction(message)
                    Task { @MainActor [weak self] in
                        self?.progressText = message
                        self?.progressFraction = fraction
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastError = "分析失败: \(error.localizedDescription)"
                    self.isRunning = false
                    self.provisionalBuffer = []
                    self.loadResults()      // restore whatever the disk still has
                    self.applyThresholds()
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.provisionalBuffer = []
                self.loadResults()          // authoritative results (real burst groups)
                self.applyThresholds()
                if summary.cancelled {
                    // The engine now writes what it finished, so the partial set
                    // is on disk and reusable by the next run.
                    self.progressText = "已取消: 已保存 \(summary.analyzed + summary.reused) 张结果，下次分析直接复用"
                } else {
                    self.progressText = summary.reused > 0
                        ? "完成: 分析 \(summary.analyzed) 张 · 复用 \(summary.reused) 张未变"
                        : "完成: \(summary.analyzed) 张"
                    if !summary.failed.isEmpty {
                        self.lastError = "\(summary.failed.count) 张无法解析被跳过 (文件损坏或仍在拷贝中): \(summary.failed.prefix(5).joined(separator: ", "))\(summary.failed.count > 5 ? "..." : "")"
                    }
                }
                self.isRunning = false
                if !self.items.isEmpty { self.touchSessionIndex() }
                self.postResultsChanged(previewsChanged: true)
            }
        }
    }

    /// VLM judges only the photos that survive the CURRENT thresholds + manual
    /// overrides — no tokens wasted on photos already rejected. Run it after
    /// tuning the sliders; results merge in and refine picks/rejects.
    func runVLMOnSurvivors() {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        lastError = nil
        processBox.resetCancellation()
        let data = sessionDir
        let root = pythonRoot
        let box = processBox
        let survivors = items.filter { $0.verdict != .reject }.map(\.id)
        let count = survivors.count
        let summaryBox = SummaryBox()
        let backendArgs = ["--backend", "ollama",
                           "--base-url", "http://localhost:11434",
                           "--model", Self.ollamaModel]

        Task.detached { [weak self] in
            guard let self else { return }
            // Preflight: fail in 2s with an actionable message instead of letting
            // the Python subprocess time out against a server that isn't there.
            guard await self.checkVLMServer() else {
                await MainActor.run { [weak self] in
                    self?.lastError = "Ollama 服务未运行 — 先点“启动 VLM 服务” (模型: ollama pull \(Self.ollamaModel))"
                    self?.isRunning = false
                }
                return
            }
            await MainActor.run { [weak self] in self?.progressText = "VLM 分析 \(count) 张幸存照片 (每张约6秒)..." }
            let idsFile = data.appendingPathComponent("vlm_ids.txt")
            do {
                try survivors.joined(separator: "\n").write(to: idsFile, atomically: true, encoding: .utf8)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "写入待分析清单失败: \(error.localizedDescription)"
                    self?.isRunning = false
                }
                return
            }
            let result = Self.runProcess(
                executable: Self.uvExecutable,
                arguments: ["run", "python", "layer2.py"]
                    + backendArgs
                    + ["--manifest", data.appendingPathComponent("manifest.json").path,
                       "--layer1", data.appendingPathComponent("layer1_results.json").path,
                       "--out", data.appendingPathComponent("layer2_results.json").path,
                       "--no-layer1-filter",
                       "--ids-file", idsFile.path,
                       "--progress",
                       "--concurrency", "2"],
                cwd: root,
                box: box,
                onStdoutLine: { line in
                    if let s = Self.parseSummary(line) { summaryBox.set(s); return }
                    guard line.hasPrefix("PROGRESS ") else { return }
                    let parts = line.dropFirst("PROGRESS ".count).split(separator: "/")
                    guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.progressText = "VLM 分析中 \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            )
            let summary = summaryBox.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                switch result {
                case .success:
                    self.loadResults()
                    self.applyThresholds()
                    self.progressText = "VLM 完成"
                    self.warnOnPartialVLMFailure(summary, label: "VLM")
                    self.postResultsChanged(previewsChanged: false)
                case .failure(let message):
                    self.lastError = "VLM 分析失败 (服务在跑吗? 先点“启动 VLM 服务”): \(message)"
                case .cancelled:
                    self.loadResults()   // 已判完的那部分留下来
                    self.applyThresholds()
                    self.progressText = "VLM 已取消 (已完成的判决已保留)"
                }
                self.isRunning = false
            }
        }
    }

    /// layer2.py's closing `SUMMARY ok=<n> err=<n> total=<n>` line. The exit
    /// code alone only says "at least one photo worked": 199 of 200 failing
    /// after Ollama fell over mid-run used to show as a clean "VLM 完成".
    struct VLMSummary: Sendable { let ok: Int; let err: Int; let total: Int }

    final class SummaryBox: @unchecked Sendable {
        private var stored: VLMSummary?
        private let lock = NSLock()
        func set(_ s: VLMSummary) { lock.lock(); stored = s; lock.unlock() }
        var value: VLMSummary? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    nonisolated static func parseSummary(_ line: String) -> VLMSummary? {
        guard line.hasPrefix("SUMMARY ") else { return nil }
        var fields: [String: Int] = [:]
        for token in line.dropFirst("SUMMARY ".count).split(separator: " ") {
            let kv = token.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let n = Int(kv[1]) { fields[String(kv[0])] = n }
        }
        guard let ok = fields["ok"], let err = fields["err"], let total = fields["total"] else { return nil }
        return VLMSummary(ok: ok, err: err, total: total)
    }

    private func warnOnPartialVLMFailure(_ summary: VLMSummary?, label: String) {
        guard let summary, summary.err > 0 else { return }
        lastError = "\(label): \(summary.ok) 张成功, \(summary.err) 张失败 (服务中途出错或超时?)。失败的照片保持原判决，可再点一次续跑"
    }

    /// Appeal court: re-examine AUTO-rejected photos (manual rejects are the
    /// photographer's word — not appealed), asking the VLM only about the
    /// specific charges each photo was rejected for. Clears flow back through
    /// applyThresholds, which drops cleared charges and lets the photo walk.
    func runAppealOnRejects() {
        guard !isRunning, !items.isEmpty else { return }
        let accused = items.filter { $0.verdict == .reject && overrides[$0.id] == nil
            && !$0.rejectReasons.isEmpty }
        guard !accused.isEmpty else {
            progressText = "没有可复审的自动废片"
            return
        }
        isRunning = true
        lastError = nil
        processBox.resetCancellation()
        let data = sessionDir
        let root = pythonRoot
        let box = processBox
        let count = accused.count
        let summaryBox = SummaryBox()

        Task.detached { [weak self] in
            guard let self else { return }
            guard await self.checkVLMServer() else {
                await MainActor.run { [weak self] in
                    self?.lastError = "Ollama 服务未运行 — 先点“启动 VLM 服务” (模型: ollama pull \(Self.ollamaModel))"
                    self?.isRunning = false
                }
                return
            }
            await MainActor.run { [weak self] in self?.progressText = "复审 \(count) 张废片..." }
            let idsFile = data.appendingPathComponent("appeal_ids.txt")
            let reasonsFile = data.appendingPathComponent("appeal_reasons.json")
            do {
                try accused.map(\.id).joined(separator: "\n")
                    .write(to: idsFile, atomically: true, encoding: .utf8)
                let reasons = Dictionary(uniqueKeysWithValues: accused.map { ($0.id, $0.rejectReasons) })
                let json = try JSONSerialization.data(withJSONObject: reasons, options: [.sortedKeys])
                try json.write(to: reasonsFile)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "写入复审清单失败: \(error.localizedDescription)"
                    self?.isRunning = false
                }
                return
            }
            let result = Self.runProcess(
                executable: Self.uvExecutable,
                arguments: ["run", "python", "layer2.py",
                            "--backend", "ollama", "--mode", "appeal",
                            "--base-url", "http://localhost:11434",
                            "--model", Self.ollamaModel,
                            "--manifest", data.appendingPathComponent("manifest.json").path,
                            "--layer1", data.appendingPathComponent("layer1_results.json").path,
                            "--out", data.appendingPathComponent("appeal_results.json").path,
                            "--no-layer1-filter",
                            "--ids-file", idsFile.path,
                            "--appeal-file", reasonsFile.path,
                            "--progress",
                            "--concurrency", "2"],
                cwd: root,
                box: box,
                onStdoutLine: { line in
                    if let s = Self.parseSummary(line) { summaryBox.set(s); return }
                    guard line.hasPrefix("PROGRESS ") else { return }
                    let parts = line.dropFirst("PROGRESS ".count).split(separator: "/")
                    guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.progressText = "复审中 \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            )
            let summary = summaryBox.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                switch result {
                case .success:
                    let before = self.verdictCounts.reject
                    self.loadResults()
                    self.applyThresholds()
                    let freed = before - self.verdictCounts.reject
                    self.progressText = freed > 0 ? "复审完成: 平反 \(freed) 张" : "复审完成: 维持原判"
                    self.warnOnPartialVLMFailure(summary, label: "复审")
                    self.postResultsChanged(previewsChanged: false)
                case .failure(let message):
                    self.lastError = "复审失败 (服务在跑吗? 先点“启动服务”): \(message)"
                case .cancelled:
                    self.loadResults()
                    self.applyThresholds()
                    self.progressText = "复审已取消 (已完成的部分已保留)"
                }
                self.isRunning = false
            }
        }
    }

    /// Extracts "done/total" from progress messages like "分析中 15/210..." so both
    /// the native engine and the VLM subprocess feed the same progress bar.
    nonisolated static func parseFraction(_ message: String) -> Double? {
        guard let slash = message.firstIndex(of: "/") else { return nil }
        let before = message[..<slash].reversed().prefix(while: \.isNumber).reversed()
        let after = message[message.index(after: slash)...].prefix(while: \.isNumber)
        guard let done = Int(String(before)), let total = Int(String(after)), total > 0 else { return nil }
        return Double(done) / Double(total)
    }

    nonisolated static func runProcess(executable: String, arguments: [String], cwd: URL,
                                       box: ProcessBox? = nil,
                                       onStdoutLine: (@Sendable (String) -> Void)? = nil) -> Result<Void, Never>.ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardError = pipe
        let outPipe = Pipe()
        process.standardOutput = outPipe
        // 两个管道都必须边跑边排空，否则子进程写满缓冲区就永远阻塞在 write 上。
        let stderrCollector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrCollector.append(chunk)
        }
        // print(..., flush=True) on the Python side writes whole lines per
        // write(), so splitting availableData on newlines is reliable enough
        // for short progress lines.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let onStdoutLine, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                onStdoutLine(String(line))
            }
        }
        do {
            try process.run()
            box?.set(process)
            defer { box?.set(nil) }
            process.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            pipe.fileHandleForReading.readabilityHandler = nil
            // handler 拆掉后管道里可能还剩最后一截
            if let tail = try? pipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
                stderrCollector.append(tail)
            }
            if process.terminationStatus != 0 {
                if box?.wasCancelled == true { return .cancelled }
                let text = stderrCollector.text
                let message = text.isEmpty ? "exit \(process.terminationStatus)" : String(text.suffix(500))
                return .failure(message)
            }
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Results loading

    /// Photos in the manifest that have no usable layer1 row (decode failed,
    /// or the file was mid-copy when analyzed). They are invisible in the
    /// grid, so the count is shown permanently in the status bar — the
    /// one-time "N 张无法解析" toast after analysis was easy to miss.
    @Published private(set) var unparsedCount = 0

    func loadResults() {
        let decoder = JSONDecoder()

        guard let manifestData = try? Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(Manifest.self, from: manifestData) else {
            items = []
            unparsedCount = 0
            rebuildGroupSizes()
            return
        }

        var l1ById: [String: Layer1Result] = [:]
        if let data = try? Data(contentsOf: sessionDir.appendingPathComponent("layer1_results.json")),
           let file = try? decoder.decode(Layer1File.self, from: data) {
            for r in file.results where r.error == nil { l1ById[r.id] = r }
        }

        var l2ById: [String: Layer2Result] = [:]
        if let data = try? Data(contentsOf: sessionDir.appendingPathComponent("layer2_results.json")),
           let file = try? decoder.decode(Layer2File.self, from: data) {
            for r in file.results where r.error == nil { l2ById[r.id] = r }
        }

        var appealById: [String: AppealResult] = [:]
        if let data = try? Data(contentsOf: sessionDir.appendingPathComponent("appeal_results.json")),
           let file = try? decoder.decode(AppealFile.self, from: data) {
            for r in file.results where r.error == nil { appealById[r.id] = r }
        }

        let isoParser = DateFormatter()
        isoParser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        isoParser.locale = Locale(identifier: "en_US_POSIX")

        var loaded = manifest.photos.enumerated().compactMap { index, photo -> BatchItem? in
            guard let l1 = l1ById[photo.id], let sharpness = l1.sharpness, let group = l1.burstGroup else { return nil }
            let l2 = l2ById[photo.id]
            var item = BatchItem(
                id: photo.id,
                previewPath: LabelStore.resolve(photo.previewPath, against: sessionDir),
                rawPath: photo.rawPath,
                decodePath: photo.decodePath ?? photo.rawPath,
                sharpness: sharpness,
                worstClipPct: max(l1.highlightClipPct ?? 0, l1.shadowClipPct ?? 0),
                eyeClosed: l1.eyeClosed,
                faceQuality: l1.faceQuality,
                faceCount: l1.faceCount ?? (l1.faceFound == true ? 1 : 0),
                faceBbox: l1.faceBbox,
                faceAreaPct: l1.faceAreaPct,
                faces: l1.faces ?? [],
                burstGroup: group,
                expressionScore: l2?.expressionScore ?? appealById[photo.id]?.expressionScore,
                vlmReject: l2?.rejectRecommended ?? false,
                vlmCompositionIssues: l2?.compositionIssues ?? [],
                vlmReason: l2?.reason,
                appealClosedEyes: appealById[photo.id]?.closedEyes,
                appealSubjectSharp: appealById[photo.id]?.subjectSharp,
                appealIntentionalExposure: appealById[photo.id]?.intentionalExposure,
                appealReason: appealById[photo.id]?.reason,
                captureTime: photo.captureTime.flatMap(isoParser.date(from:)),
                exif: photo.exif,
                horizonDeg: l1.horizonDeg
            )
            item.order = index
            item.camera = photo.camera
            return item
        }
        Self.assignChapters(&loaded)
        Self.assignTakes(&loaded, gapSec: takeGapSec)
        Self.sort(&loaded, by: sortOrder)
        items = loaded
        unparsedCount = manifest.photos.count - loaded.count
        rebuildGroupSizes()
    }

    // MARK: - Chapters (coverage protection)

    /// A shooting pause longer than this starts a new chapter (仪式→晚宴...).
    static let chapterGapSec: TimeInterval = 15 * 60

    /// Works on a local array: element-wise writes into the @Published `items`
    /// fired one objectWillChange per photo.
    private static func assignChapters(_ array: inout [BatchItem]) {
        let datedIndices = array.indices
            .filter { array[$0].captureTime != nil }
            .sorted { array[$0].captureTime! < array[$1].captureTime! }
        var chapter = 0
        var prevTime: Date?
        for idx in datedIndices {
            let t = array[idx].captureTime!
            if let prev = prevTime, t.timeIntervalSince(prev) > chapterGapSec {
                chapter += 1
            }
            array[idx].chapter = chapter
            prevTime = t
        }
        // Undated photos join chapter 0 rather than spawning fake chapters.
    }

    // MARK: - Takes (场)

    /// 按拍摄时间把连续按快门的一串切成「场」，每台机身各切各的。
    ///
    /// 和 assignChapters 是同一套形状，只是粒度细一级（章节 15 分钟 / 场 ~8 秒），
    /// 三层：章节 > 场 > 近似重复(burstGroup)。
    ///
    /// 只看时间不看画面：phash 在这个尺度上判别力已经饱和（见 BatchItem.take 的
    /// 注释）。真正需要画面信号来拦的，是"没停快门就转向另一个主体"——但那种
    /// 情况下机身和时间通常也一起变，先不为它加复杂度。
    ///
    /// 没有拍摄时间的照片（EXIF 缺失）各自成场，不会被塞进邻居那一堆。
    ///
    /// 切完再**按开始时间统一重新编号**：分桶是按机身的，边切边编会编成
    /// "A 机全部的场，然后 B 机全部的场"，堆栈网格按 take 排序就变成两台机器
    /// 各排一段，时间线整个乱掉 —— 而按机身分桶本来就是为双机位加的。
    static func assignTakes(_ array: inout [BatchItem], gapSec: Double) {
        var segments: [(start: Date, members: [Int])] = []
        // 按机身分桶：双机位同一秒的两张是两个角度，不是重复。
        let byCamera = Dictionary(grouping: array.indices.filter { array[$0].captureTime != nil },
                                  by: { array[$0].camera ?? "" })
        for key in byCamera.keys.sorted() {
            let indices = byCamera[key]!.sorted { array[$0].captureTime! < array[$1].captureTime! }
            var current: [Int] = []
            var prevTime: Date?
            for idx in indices {
                let t = array[idx].captureTime!
                if let prev = prevTime, t.timeIntervalSince(prev) <= gapSec {
                    current.append(idx)
                } else {
                    if !current.isEmpty { segments.append((array[current[0]].captureTime!, current)) }
                    current = [idx]
                }
                prevTime = t
            }
            if !current.isEmpty { segments.append((array[current[0]].captureTime!, current)) }
        }
        segments.sort { $0.start < $1.start }
        var take = 0
        for segment in segments {
            take += 1
            for idx in segment.members { array[idx].take = take }
        }
        // 没有拍摄时间的排在最后，各自成场。
        for idx in array.indices where array[idx].captureTime == nil {
            take += 1
            array[idx].take = take
        }
    }

    /// Recomputed on every status-bar render — DateFormatter construction is
    /// milliseconds-expensive, so it must not happen per call.
    private static let chapterTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// One timeline segment per chapter: size + verdict makeup + time range.
    /// Backs the clickable chapter bar above the grid (empty unless the shoot
    /// actually has 2+ chapters).
    struct ChapterSegment: Identifiable {
        let chapter: Int
        let count: Int
        let pick: Int
        let usable: Int
        let reject: Int
        let timeRange: String
        /// 留下的张数低于「每章节最少保留」。和 allRejected 分开：那个驱动时间轴
        /// 上的红色"全灭"块，这个只是橙色提醒。
        let underMin: Bool
        var id: Int { chapter }
        var allRejected: Bool { pick + usable == 0 }
    }

    /// Segments plus the all-rejected warnings in one pass (they used to be two
    /// computed properties doing the same grouping on every render). Warnings:
    /// chapters where culling left NOTHING — losing a whole scene is a delivery
    /// accident, a few extra keepers is just waste.
    private static func chapterSummary(_ items: [BatchItem], minKeepers: Int) -> ([ChapterSegment], [String]) {
        var byChapter: [Int: [BatchItem]] = [:]
        for item in items { byChapter[item.chapter, default: []].append(item) }
        guard byChapter.count > 1 else { return ([], []) }
        var segments: [ChapterSegment] = []
        var warnings: [String] = []
        for (chapter, members) in byChapter.sorted(by: { $0.key < $1.key }) {
            let times = members.compactMap(\.captureTime)
            let range = times.isEmpty ? "" :
                "\(chapterTimeFormatter.string(from: times.min()!))-\(chapterTimeFormatter.string(from: times.max()!))"
            var pick = 0, usable = 0, reject = 0
            for member in members {
                switch member.verdict {
                case .pick: pick += 1
                case .usable: usable += 1
                case .reject: reject += 1
                }
            }
            let keepers = pick + usable
            let segment = ChapterSegment(chapter: chapter, count: members.count,
                                         pick: pick, usable: usable, reject: reject, timeRange: range,
                                         underMin: keepers > 0 && keepers < minKeepers)
            segments.append(segment)
            let where_ = "章节\(chapter + 1)\(range.isEmpty ? "" : " (\(range))")"
            if segment.allRejected {
                warnings.append("\(where_) 的 \(members.count) 张全部被淘汰")
            } else if segment.underMin {
                warnings.append("\(where_) 只留了 \(keepers) 张 (<\(minKeepers))")
            }
        }
        return (segments, warnings)
    }

    // MARK: - Keeper-rate stats (拍摄复盘)

    struct StatBucket: Identifiable {
        let label: String
        let total: Int
        let keepers: Int
        var id: String { label }
        var ratePct: Int { total > 0 ? Int(Double(keepers) / Double(total) * 100) : 0 }
    }

    private func buckets(_ groups: [(String, [BatchItem])]) -> [StatBucket] {
        groups.compactMap { label, members in
            guard members.count >= 3 else { return nil }  // too few to mean anything
            return StatBucket(label: label, total: members.count,
                              keepers: members.filter { $0.verdict != .reject }.count)
        }
    }

    var focalStats: [StatBucket] {
        let groups = Dictionary(grouping: items.filter { $0.exif?.focal35 != nil }) { item -> String in
            let f = item.exif!.focal35!
            switch f {
            case ..<25: return "≤24mm"
            case 25...50: return "25-50mm"
            case 51...85: return "51-85mm"
            case 86...135: return "86-135mm"
            default: return ">135mm"
            }
        }
        return buckets(groups.sorted { $0.key < $1.key })
    }

    var isoStats: [StatBucket] {
        let groups = Dictionary(grouping: items.filter { $0.exif?.iso != nil }) { item -> String in
            let iso = item.exif!.iso!
            switch iso {
            case ..<401: return "≤400"
            case 401...1600: return "401-1600"
            case 1601...6400: return "1601-6400"
            default: return ">6400"
            }
        }
        return buckets(groups.sorted { $0.key < $1.key })
    }

    // MARK: - Contact sheet (客户选片确认)

    /// Single-file HTML gallery of the picks — numbered, with ids, sendable over
    /// WeChat as one file. Preview JPEGs are embedded base64 (they're already
    /// ~1024px files on disk; no re-encode).
    func exportContactSheet(to url: URL, includeUsable: Bool) {
        guard !isRunning else { return }
        let chosen = items.filter { $0.verdict == .pick || (includeUsable && $0.verdict == .usable) }
            .map { (id: $0.id, previewPath: $0.previewPath, pick: $0.verdict == .pick) }
        guard !chosen.isEmpty else {
            lastError = "没有可导出的照片"
            return
        }
        isRunning = true
        lastError = nil
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag
        let title = photoDir?.lastPathComponent ?? ""
        let total = chosen.count

        // Off the main thread: reading + base64-encoding hundreds of ~190KB
        // previews took seconds of beachball. The 1024px previews are
        // re-encoded at 800px/q0.72 so a 300-photo sheet stays WeChat-sized.
        Task.detached(priority: .userInitiated) { [weak self] in
            var cells = ""
            for (index, item) in chosen.enumerated() {
                if flag.isSet { break }
                guard let data = Self.contactSheetJPEG(path: item.previewPath) else { continue }
                let b64 = data.base64EncodedString()
                cells += """
                <div class="cell"><img src="data:image/jpeg;base64,\(b64)">
                <div class="cap">#\(index + 1) · \(item.id)\(item.pick ? " ★" : "")</div></div>\n
                """
                let done = index + 1
                if done % 20 == 0 || done == total {
                    await MainActor.run { [weak self] in
                        self?.progressText = "生成选片确认表 \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            }
            let dateString = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
            let html = """
            <!doctype html><html lang="zh"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>选片确认 · \(title)</title>
            <style>
            body{font-family:-apple-system,sans-serif;background:#111;color:#eee;margin:1rem}
            h1{font-size:1.1rem} .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:10px}
            .cell img{width:100%;border-radius:6px;display:block}
            .cap{font-size:.8rem;color:#bbb;padding:4px 2px}
            </style></head><body>
            <h1>选片确认 · \(title) · \(total) 张 · \(dateString)</h1>
            <p style="color:#999;font-size:.85rem">★ = 摄影师精选。请回复需要精修的编号。</p>
            <div class="grid">\(cells)</div></body></html>
            """
            let cancelled = flag.isSet
            var writeError: String?
            if !cancelled {
                do { try html.write(to: url, atomically: true, encoding: .utf8) }
                catch { writeError = error.localizedDescription }
            }
            let failure = writeError
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                if cancelled {
                    self.progressText = "已取消导出选片确认表"
                } else if let failure {
                    self.lastError = "联系表导出失败: \(failure)"
                } else {
                    self.progressText = "选片确认表已导出: \(total) 张 → \(url.lastPathComponent)"
                }
            }
        }
    }

    nonisolated private static func contactSheetJPEG(path: String) -> Data? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Live verdict computation (port of rate.py logic)

    // Eye thresholds. The main rule is RELATIVE: within a burst group, an eye is
    // closed if its EAR falls below 70% of the group's best — each person's own
    // open-eye shape is the baseline, so narrow eyes stop reading as blinks.
    /// Fraction of the group's best EAR below which an eye counts as closed.
    static let earRelativeFactor = 0.7
    /// Unconditional closed floor — catches the relative rule's blind spot where
    /// the WHOLE burst is blinks (group best is itself a closed eye).
    static let earAbsoluteFloor = 0.08
    /// Unconditionally open above this — guards the opposite blind spot, where a
    /// wide-open group best (0.4+) drags the 70% line up into open-eye territory.
    static let earOpenGuard = 0.22
    /// Absolute fallback when the group has no siblings to compare against
    /// (same value the engine bakes into its legacy boolean).
    static let earSingleThreshold = 0.15
    /// Faces smaller than this fraction of the frame are EAR-immune: too few
    /// pixels for reliable eye landmarks (全景里的小人闭不闭眼看不清也不该杀片).
    /// 0.3% area ≈ a 170px face box on the 3072px analysis decode — measured
    /// floor of readable landmarks. NOT the plan's original 2%: on the real test
    /// set every normal environmental portrait sits at 0.4-1.5% area, so a 2%
    /// floor would have immunized ALL of them and killed eye detection outright.
    static let minEarFaceAreaPct = 0.003
    /// Quality is judged group-relative too: suspect only when this far below
    /// the group's best FaceCaptureQuality (its designed use — ranking captures
    /// of the same subject). No global kill-line for grouped photos.
    static let qualityGroupGap = 0.15

    /// Photo-level EAR for group comparison: the WORST eye among faces big
    /// enough to judge. nil = no judgment possible (legacy data without raw
    /// EARs, or every face under the size floor).
    static func effectiveEar(_ item: BatchItem) -> Double? {
        item.faces.compactMap { face -> Double? in
            guard let ear = face.ear else { return nil }
            if let area = face.areaPct, area < minEarFaceAreaPct { return nil }
            return ear
        }.min()
    }

    /// 景别 compensation for photos with no burst siblings: the slider value is
    /// the threshold for a close-up (face ≥10% of frame); it relaxes linearly to
    /// 4/9 of that for a tiny face in a wide shot (0.45→0.2 in preset terms) —
    /// Apple's quality score naturally runs lower on small faces, and a wide
    /// environmental portrait shouldn't be graded like a headshot.
    static func compensatedQualityThreshold(slider: Double, faceAreaPct: Double?) -> Double {
        guard let area = faceAreaPct else { return slider }  // legacy data: old behavior
        let tiny = 0.005, closeUp = 0.10
        let fraction = min(1.0, max(0.0, (area - tiny) / (closeUp - tiny)))
        let floor = slider * (0.2 / 0.45)
        return floor + (slider - floor) * fraction
    }

    private static func eyeVerdict(ear: Double, groupBest: Double?, groupEarCount: Int) -> Bool {
        if ear < earAbsoluteFloor { return true }
        if ear >= earOpenGuard { return false }
        if groupEarCount >= 2, let best = groupBest, best > 0 {
            return ear < best * earRelativeFactor
        }
        return ear < earSingleThreshold
    }

    /// 组/场内排名：先看 VLM 表情分，再看 Apple 的 FaceCaptureQuality（它被设计出来
    /// 就是干这个的——给同一个主体的多张抓拍排序），锐度只作最后的抢七 / 无人脸时的
    /// 兜底。返回 nil = 没有候选。
    private static func bestIndex(_ indices: [Int], in items: [BatchItem]) -> Int? {
        indices.max { scoreKey(items[$0]) < scoreKey(items[$1]) }
    }

    /// 同一把尺子给三处用：场内自动提名、「按评分」排序、缩略图上的 #1 #2 #3。
    /// 三处用的不是同一个排序的话，标着 #1 的那张不是精选，用户会怀疑软件。
    static func scoreKey(_ item: BatchItem) -> (Int, Double, Double) {
        (item.expressionScore ?? -1, item.faceQuality ?? -1, item.sharpness)
    }

    func applyThresholds() {
        // Everything below works on a LOCAL copy and assigns `items` once at the
        // end. Writing `items[i].x = ...` on the @Published array fired one
        // objectWillChange per write — five per photo, ~15k per slider tick on
        // a 3000-photo shoot — which is what made the sliders feel sticky.
        var updated = items

        // Pass 1: per-burst-group baselines (best EAR, best face quality).
        var groupBestEar: [Int: Double] = [:]
        var groupEarCount: [Int: Int] = [:]
        var groupBestQ: [Int: Double] = [:]
        var groupQCount: [Int: Int] = [:]
        for item in updated {
            if let ear = Self.effectiveEar(item) {
                groupBestEar[item.burstGroup] = max(groupBestEar[item.burstGroup] ?? 0, ear)
                groupEarCount[item.burstGroup, default: 0] += 1
            }
            if let q = item.faceQuality {
                groupBestQ[item.burstGroup] = max(groupBestQ[item.burstGroup] ?? 0, q)
                groupQCount[item.burstGroup, default: 0] += 1
            }
        }

        var rejected = Set<String>()
        for i in updated.indices {
            let group = updated[i].burstGroup
            let earCount = groupEarCount[group] ?? 0

            // Dynamic eye state: photo-level for the verdict, then the same rule
            // per face so the strip badges tell the same story.
            let eyeClosed: Bool?
            if let ear = Self.effectiveEar(updated[i]) {
                eyeClosed = Self.eyeVerdict(ear: ear, groupBest: groupBestEar[group],
                                            groupEarCount: earCount)
            } else if updated[i].faces.contains(where: { $0.ear != nil }) {
                eyeClosed = nil  // faces exist but all EAR-immune (too small)
            } else {
                eyeClosed = updated[i].eyeClosed  // legacy session without raw EARs
            }
            updated[i].dynamicEyeClosed = eyeClosed
            for f in updated[i].faces.indices {
                let face = updated[i].faces[f]
                guard let ear = face.ear else { continue }
                let closed: Bool?
                if let area = face.areaPct, area < Self.minEarFaceAreaPct {
                    closed = nil
                } else {
                    closed = Self.eyeVerdict(ear: ear, groupBest: groupBestEar[group],
                                             groupEarCount: earCount)
                }
                if closed != face.eyeClosed {
                    updated[i].faces[f] = FaceInfo(bbox: face.bbox, eyeClosed: closed,
                                                   ear: face.ear, areaPct: face.areaPct)
                }
            }

            var reasons: [String] = []
            if eyeClosed == true { reasons.append("闭眼") }
            if updated[i].sharpness < sharpnessThreshold { reasons.append("虚焦") }
            if updated[i].worstClipPct >= exposureThreshold { reasons.append("曝光裁切") }
            if faceQualityThreshold > 0, let q = updated[i].faceQuality {
                if (groupQCount[group] ?? 0) >= 2, let best = groupBestQ[group] {
                    // Burst siblings exist: only a clear intra-group loser is suspect.
                    if q < best - Self.qualityGroupGap { reasons.append("人脸质量低") }
                } else if q < Self.compensatedQualityThreshold(slider: faceQualityThreshold,
                                                               faceAreaPct: updated[i].faceAreaPct) {
                    reasons.append("人脸质量低")
                }
            }
            if updated[i].vlmReject { reasons.append("VLM建议淘汰") }

            // Appeal court: the VLM can only clear the SPECIFIC charge it
            // re-examined; a photo walks when no charges remain. Verdicts stay
            // valid across slider moves — "the subject IS sharp" doesn't depend
            // on where the threshold sits.
            var rescued: [String] = []
            func clear(_ charge: String, when verdict: Bool?) {
                guard verdict == true, reasons.contains(charge) else { return }
                reasons.removeAll { $0 == charge }
                rescued.append(charge)
            }
            clear("闭眼", when: updated[i].appealClosedEyes.map { !$0 })
            clear("虚焦", when: updated[i].appealSubjectSharp)
            clear("曝光裁切", when: updated[i].appealIntentionalExposure)
            updated[i].vlmRescued = rescued
            updated[i].rejectReasons = reasons

            // Manual override wins over every threshold: a manual non-reject keeps
            // the photo alive no matter what the sliders say, and vice versa.
            let auto: Verdict = reasons.isEmpty ? .usable : .reject
            let effective = overrides[updated[i].id] ?? auto
            updated[i].verdict = effective
            if effective == .reject { rejected.insert(updated[i].id) }
        }

        // 两趟，作用在两个不同的层上 —— 别合并回一趟：
        //   A. 去重挂在**近似重复**(burstGroup) 上：只有"几乎同一张"才敢自动扔。
        //   B. 精选提名挂在**场**(take) 上：一场 10 张出 1 张最佳，才是摄影师说的
        //      "这条里这张最好"。以前提名也挂在 burstGroup 上，于是 10 张的场里
        //      会冒出 2 张精选（各自赢下自己那对近似重复），既不直观也没用。
        // 顺序不能反：先去重，被扔掉的重复张就不该再参与本场的最佳评选。

        // A. 近似重复去重。分组本来只用来"提名"，组内其余照片原封不动留在可用里
        // ——一组全清晰全睁眼时等于什么都没做。开关打开后，没赢下这一组、又没被
        // 人工改判过的，带着「连拍重复」进废片，和闭眼/虚焦一样能用理由 chip 回查。
        // 人工改判过的一律不碰（手判永远压过规则）。
        if rejectBurstDuplicates {
            var dupGroups: [Int: [Int]] = [:]
            for (idx, item) in updated.enumerated() where !rejected.contains(item.id) {
                dupGroups[item.burstGroup, default: []].append(idx)
            }
            for (_, indices) in dupGroups where indices.count >= 2 {
                // 组里有人工精选就以它为准，不另外自动挑一张。
                let manualPicks = indices.filter { overrides[updated[$0].id] == .pick }
                var winners = Set(manualPicks)
                if manualPicks.isEmpty,
                   let best = Self.bestIndex(indices.filter { overrides[updated[$0].id] == nil },
                                             in: updated) {
                    winners.insert(best)
                }
                for idx in indices where !winners.contains(idx) && overrides[updated[idx].id] == nil {
                    updated[idx].rejectReasons.append("连拍重复")
                    updated[idx].verdict = .reject
                    rejected.insert(updated[idx].id)
                }
            }
        }

        // B. 精选提名，按「场」，且只在还剩 2 张以上存活时 —— 精选必须是赢过真实
        // 对手来的，不能只是没人跟它抢。
        var takeGroups: [Int: [Int]] = [:]
        for (idx, item) in updated.enumerated() where !rejected.contains(item.id) {
            takeGroups[item.take, default: []].append(idx)
        }
        for (_, indices) in takeGroups where indices.count >= 2 {
            // 场里有人工精选就让给它，不在旁边再自动挑一张。
            if indices.contains(where: { overrides[updated[$0].id] == .pick }) { continue }
            if let best = Self.bestIndex(indices.filter { overrides[updated[$0].id] == nil },
                                         in: updated) {
                updated[best].verdict = .pick
            }
        }

        items = updated
        rebuildDerived(groupQCount: groupQCount)
    }

    // MARK: - 接受全部推荐（Aftershoot 的一键过）

    /// 还没定的场里，会被「接受全部推荐」动到的：场数 / 会变废片的张数。
    /// 住 Derived：顶栏按钮的 disabled 和确认框标题都读它，每次重绘对 3000 张
    /// 重新分组就是刚从 groupedItems 里清掉的那个坑。
    var recommendationSummary: (takes: Int, rejects: Int) { derived.recommendationSummary }

    /// 每个有精选的待处理场：精选留下（写成人工精选，否则砍完对手它会掉回可用），
    /// 其余**没被人工改判**的可用设为废片。人工标过可用的一律不碰 —— 那是用户
    /// 亲手做的决定。整个操作一条撤销记录，⌘Z 一次全部回来。
    @discardableResult
    func acceptAllRecommendations() -> Int {
        var changes: [(id: String, verdict: Verdict)] = []
        var takes = 0
        for (_, members) in Dictionary(grouping: items, by: \.take) {
            let picks = members.filter { $0.verdict == .pick }
            guard !picks.isEmpty else { continue }
            let losers = members.filter { $0.verdict == .usable && overrides[$0.id] == nil }
            guard !losers.isEmpty else { continue }
            takes += 1
            for p in picks where overrides[p.id] != .pick { changes.append((p.id, .pick)) }
            for l in losers { changes.append((l.id, .reject)) }
        }
        guard !changes.isEmpty else { return 0 }
        overrideUndoStack.append(changes.map { ($0.id, overrides[$0.id]) })
        if overrideUndoStack.count > 100 { overrideUndoStack.removeFirst() }
        for c in changes { overrides[c.id] = c.verdict }
        saveOverrides()
        applyThresholds()
        return takes
    }

    // MARK: - 精华 Top N (Aftershoot 的 Sneak Peek)

    /// 全场评分最高的 N 张：精选优先，不够再从可用里按评分补。`fromUsable` 是补了
    /// 几张 —— 界面上要说清楚，别让人以为精华全是精选。
    func topPicks(_ n: Int) -> (ids: [String], fromUsable: Int) {
        let picks = items.filter { $0.verdict == .pick }.sorted { Self.scoreKey($0) > Self.scoreKey($1) }
        if picks.count >= n { return (picks.prefix(n).map(\.id), 0) }
        let fill = items.filter { $0.verdict == .usable }.sorted { Self.scoreKey($0) > Self.scoreKey($1) }
            .prefix(n - picks.count)
        return (picks.map(\.id) + fill.map(\.id), fill.count)
    }

    // MARK: - 阈值建议（从你的改判反推，不是机器学习）

    /// 只做三个有滑杆的理由。闭眼是组内相对 EAR、VLM 没有滑杆 —— 那两个不编建议。
    struct ThresholdSuggestion: Identifiable {
        enum Kind: String { case sharpness = "锐度下限", exposure = "曝光裁切上限", faceQuality = "人脸质量下限" }
        let kind: Kind
        /// 被这条线判死、又被你放行的张数（放行 = 有人工改判且不是废片）。
        let released: Int
        /// 建议的那条线能救回其中几张。不追求全救：一张硬留的纪念照会把线拖到地板。
        let rescued: Int
        let current: Double
        let suggested: Double
        var id: String { kind.rawValue }
        var currentText: String { Self.format(kind, current) }
        var suggestedText: String { Self.format(kind, suggested) }
        static func format(_ kind: Kind, _ v: Double) -> String {
            switch kind {
            case .sharpness: return "\(Int(v))"
            case .exposure: return String(format: "%.1f%%", v * 100)
            case .faceQuality: return String(format: "%.2f", v)
            }
        }
    }

    /// 至少 3 张样本才开口。建议值 = 能救回 ≥75% 放行张的那条线（再退一格滑杆
    /// 步长），不是"救回全部"—— 第一版用放行里最差的那张，你放行的 4 张虚焦里
    /// 有一张锐度 20 的纪念照，建议就变成"降到 15"，按这个拧全场虚焦全放进来。
    private func computeThresholdSuggestions() -> [ThresholdSuggestion] {
        func released(_ reason: String) -> [BatchItem] {
            items.filter { item in
                item.rejectReasons.contains(reason) && overrides[item.id].map { $0 != .reject } == true
            }
        }
        /// 排好序的值里，覆盖 ≥75% 的那个分位点。`lineIsMinimum` = 这条线是下限
        /// （锐度/人脸质量：值 ≥ 线才放行），否则是上限（曝光：值 ≤ 线才放行）。
        func robust(_ values: [Double], lineIsMinimum: Bool) -> Double {
            let sorted = values.sorted()
            let keep = Int((Double(sorted.count) * 0.75).rounded(.up))
            return lineIsMinimum ? sorted[sorted.count - keep] : sorted[keep - 1]
        }
        var out: [ThresholdSuggestion] = []
        let blur = released("虚焦")
        if blur.count >= 3 {
            let values = blur.map(\.sharpness)
            let suggested = max(0, (robust(values, lineIsMinimum: true) / 5).rounded(.down) * 5 - 5)
            if suggested < sharpnessThreshold {
                out.append(.init(kind: .sharpness, released: blur.count,
                                 rescued: values.filter { $0 >= suggested }.count,
                                 current: sharpnessThreshold, suggested: suggested))
            }
        }
        let clip = released("曝光裁切")
        if clip.count >= 3 {
            let values = clip.map(\.worstClipPct)
            let suggested = min(0.5, (robust(values, lineIsMinimum: false) * 200).rounded(.up) / 200 + 0.005)
            if suggested > exposureThreshold {
                out.append(.init(kind: .exposure, released: clip.count,
                                 rescued: values.filter { $0 < suggested }.count,
                                 current: exposureThreshold, suggested: suggested))
            }
        }
        if faceQualityThreshold > 0 {
            let face = released("人脸质量低").filter { $0.faceQuality != nil }
            if face.count >= 3 {
                let values = face.compactMap(\.faceQuality)
                let suggested = max(0, ((robust(values, lineIsMinimum: true) - 0.05) * 20).rounded(.down) / 20)
                if suggested < faceQualityThreshold {
                    out.append(.init(kind: .faceQuality, released: face.count,
                                     rescued: values.filter { $0 >= suggested }.count,
                                     current: faceQualityThreshold, suggested: suggested))
                }
            }
        }
        return out
    }

    /// 「应用」：把滑杆拧到建议值。走 didSet → applyThresholds + 保存 + 预设变自定义。
    func applySuggestion(_ s: ThresholdSuggestion) {
        switch s.kind {
        case .sharpness: sharpnessThreshold = s.suggested
        case .exposure: exposureThreshold = s.suggested
        case .faceQuality: faceQualityThreshold = s.suggested
        }
    }

    /// 你手动废掉、但当前滑杆一个理由都没给的张数 —— 滑杆漏掉的。只报数，不编建议：
    /// 没有信号说明是哪条线该收紧。
    var manualRejectsWithoutReason: Int {
        items.filter { overrides[$0.id] == .reject && $0.rejectReasons.isEmpty }.count
    }

    // MARK: - Trash rejects

    /// Moves every 废片's files to the TRASH (never permanent deletion — a wrong
    /// threshold or a mis-click must always be recoverable from the Finder trash).
    /// A RAW+JPEG pair goes together, along with its .xmp sidecar, and the photo
    /// disappears from the session + persisted artifacts so it doesn't resurface
    /// as a broken entry.
    func trashRejects() {
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再移动废片"
            return
        }
        let rejects = items.filter { $0.verdict == .reject }
        guard !rejects.isEmpty else { return }
        // 照片文件夹不在了就别开工：一张也移不动，却会把这些 id 从结果里抹掉。
        if let dir = photoDir, !FileManager.default.fileExists(atPath: dir.path) {
            lastError = "照片文件夹「\(dir.lastPathComponent)」不存在 (被删除、改名或硬盘未挂载)，无法移动废片"
            return
        }
        isRunning = true
        lastError = nil
        // trashItem is a Finder-level operation (~ms each); hundreds of rejects
        // would beachball the UI if done here — file work goes off-main, only
        // the bookkeeping comes back.
        let jobs = rejects.map {
            (id: $0.id, rawPath: $0.rawPath, decodePath: $0.decodePath, previewPath: $0.previewPath)
        }
        let total = jobs.count
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag

        Task.detached { [weak self] in
            let fm = FileManager.default
            var trashedIDs: Set<String> = []
            var failed: [String] = []
            for (index, job) in jobs.enumerated() {
                if flag.isSet { break }
                var urls = [URL(fileURLWithPath: job.rawPath)]
                if job.decodePath != job.rawPath {
                    urls.append(URL(fileURLWithPath: job.decodePath))
                }
                let xmp = URL(fileURLWithPath: job.rawPath).deletingPathExtension().appendingPathExtension("xmp")
                if fm.fileExists(atPath: xmp.path) { urls.append(xmp) }
                do {
                    var movedAny = false
                    for url in urls where fm.fileExists(atPath: url.path) {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                        movedAny = true
                    }
                    // 一个文件都没找到（外置盘没挂载、照片已被别处移走）不算成功：
                    // 计入 trashedIDs 会把它从 manifest/VLM 结果里永久剔除，
                    // 而原图其实一张都没动，提示却说"已移到废纸篓 (可恢复)"。
                    if movedAny {
                        trashedIDs.insert(job.id)
                        try? fm.removeItem(at: URL(fileURLWithPath: job.previewPath))
                    } else {
                        failed.append(job.id)
                    }
                } catch {
                    failed.append(job.id)
                }
                let done = index + 1
                if done % 10 == 0 || done == total {
                    await MainActor.run { [weak self] in
                        self?.progressText = "移到废纸篓 \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            }

            let trashed = trashedIDs
            let failedIds = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.items.removeAll { trashed.contains($0.id) }
                for id in trashed { self.overrides.removeValue(forKey: id) }
                self.saveOverrides()
                self.rebuildGroupSizes()
                self.purgeFromArtifacts(ids: trashed)
                self.applyThresholds()
                self.touchSessionIndex()
                self.isRunning = false
                self.postResultsChanged(previewsChanged: false)
                if flag.isSet {
                    self.progressText = "已取消: \(trashed.count) 张已移到废纸篓 (可恢复)，其余未动"
                } else if failedIds.isEmpty {
                    self.progressText = "已把 \(trashed.count) 张废片移到废纸篓 (可恢复)"
                } else {
                    self.lastError = "移到废纸篓: \(trashed.count) 成功, \(failedIds.count) 失败 (\(failedIds.prefix(3).joined(separator: ", ")))"
                }
            }
        }
    }

    /// Removes trashed ids from manifest/layer JSONs so reopening the app doesn't
    /// resurrect entries whose files are gone.
    private func purgeFromArtifacts(ids: Set<String>) {
        func filterFile(_ name: String, arrayKey: String) {
            let url = sessionDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let array = json[arrayKey] as? [[String: Any]] else { return }
            json[arrayKey] = array.filter { entry in
                guard let id = entry["id"] as? String else { return true }
                return !ids.contains(id)
            }
            if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: url, options: .atomic)
            }
        }
        filterFile("manifest.json", arrayKey: "photos")
        filterFile("layer1_results.json", arrayKey: "results")
        filterFile("layer2_results.json", arrayKey: "results")
        filterFile("appeal_results.json", arrayKey: "results")
    }

    // MARK: - JPG export (交付用: 精选/可用全尺寸重编码, Capture One 式质量设置)

    /// Full-resolution JPEG export of the keepers. Decodes from `decodePath`
    /// (the JPEG half of a RAW+JPEG pair, else the RAW itself via ImageIO's
    /// vendor decoders) and re-encodes at the chosen quality, carrying the
    /// source metadata (EXIF/GPS/orientation) into the output.
    /// maxPixel nil = full resolution; otherwise long-edge cap (2048 for
    /// WeChat-able 选片小图, 4096 for screen delivery).
    /// Default JPG output folder: a subfolder of the shoot that listPhotos
    /// skips, so exporting never feeds the outputs back into the next analysis.
    var defaultJPEGExportFolder: URL? {
        photoDir?.appendingPathComponent(ImageLoader.jpegExportSubfolder)
    }

    /// `overwrite` false = files already in the target are left alone and
    /// counted (a re-export at another quality wants true; an accidental second
    /// click, or a folder that already holds the client's retouched files, does
    /// not).
    /// `ids` 给定时只导这些（精华 Top N 走这里），否则按判决选。同一条通道：
    /// isRunning 守卫、并发上限、跳过/覆盖、进度文字全部复用。
    func exportJPEGs(to folder: URL, includeUsable: Bool, quality: Double, maxPixel: Int? = nil,
                     overwrite: Bool = false, ids: Set<String>? = nil) {
        guard !isRunning else { return }
        let chosen = ids.map { wanted in items.filter { wanted.contains($0.id) } }
            ?? items.filter { $0.verdict == .pick || (includeUsable && $0.verdict == .usable) }
        guard !chosen.isEmpty else {
            lastError = "没有可导出的照片"
            return
        }
        isRunning = true
        lastError = nil
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag
        let total = chosen.count

        Task.detached { [weak self] in
            enum Outcome { case ok, skipped, failed }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "无法创建导出文件夹: \(error.localizedDescription)"
                    self?.isRunning = false
                }
                return
            }
            await MainActor.run { [weak self] in self?.progressText = "导出 JPG 0/\(total)..." }
            // Full-res decodes are big (a 60MP RAW is ~160MB unpacked), so cap
            // concurrency lower than the analysis pass. Width-limited TaskGroup:
            // seed `workers` tasks, add one more as each finishes.
            let workers = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 4))
            var failed: [String] = []
            var skipped = 0
            var done = 0
            var iterator = chosen.makeIterator()
            await withTaskGroup(of: (String, Outcome).self) { group in
                func addNext() {
                    guard !flag.isSet, let item = iterator.next() else { return }
                    group.addTask {
                        let dest = folder.appendingPathComponent("\(item.id).jpg")
                        if !overwrite, FileManager.default.fileExists(atPath: dest.path) {
                            return (item.id, .skipped)
                        }
                        let ok = Self.writeJPEG(from: URL(fileURLWithPath: item.decodePath), to: dest,
                                                quality: quality, maxPixel: maxPixel)
                        return (item.id, ok ? .ok : .failed)
                    }
                }
                for _ in 0..<workers { addNext() }
                for await (id, outcome) in group {
                    switch outcome {
                    case .ok: break
                    case .skipped: skipped += 1
                    case .failed: failed.append(id)
                    }
                    done += 1
                    let doneNow = done
                    await MainActor.run { [weak self] in
                        self?.progressText = "导出 JPG \(doneNow)/\(total)..."
                        self?.progressFraction = Double(doneNow) / Double(total)
                    }
                    addNext()
                }
            }

            let failedIds = failed
            let skippedCount = skipped
            let doneCount = done
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                let written = doneCount - skippedCount - failedIds.count
                let skipNote = skippedCount > 0 ? " · \(skippedCount) 张已存在跳过" : ""
                if flag.isSet {
                    self.progressText = "导出已取消: 已写出 \(written) 张\(skipNote)"
                } else if failedIds.isEmpty {
                    self.progressText = "JPG 导出完成: \(written) 张 → \(folder.lastPathComponent)\(skipNote)"
                } else {
                    self.lastError = "JPG 导出: \(written) 成功, \(failedIds.count) 失败 (\(failedIds.prefix(3).joined(separator: ", ")))\(skipNote)"
                }
            }
        }
    }

    /// Explicit decode → re-encode (NOT CGImageDestinationAddImageFromSource,
    /// which may copy the compressed stream and silently ignore the quality
    /// setting for JPEG→JPEG). Source properties ride along so EXIF, GPS and
    /// the orientation tag survive; pixels are written un-rotated with the tag,
    /// exactly like the camera did.
    nonisolated static func writeJPEG(from source: URL, to dest: URL, quality: Double,
                                      maxPixel: Int? = nil) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality

        let image: CGImage?
        if let maxPixel {
            // Resized path: thumbnail WITH transform bakes the rotation into the
            // pixels, so the orientation tag must be stripped — keeping it would
            // double-rotate in every viewer.
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
            props.removeValue(forKey: kCGImagePropertyOrientation)
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let image else { return false }
        CGImageDestinationAddImage(out, image, props as CFDictionary)
        return CGImageDestinationFinalize(out)
    }

    // MARK: - 高ISO RAW export (降噪流程: PureRAW / LR AI 降噪只吃 RAW)

    /// Photos matching the high-ISO export criteria: RAWs to copy + the count of
    /// matching JPEG-only photos (surfaced as "won't be copied" info). ONE
    /// implementation shared by the sheet's live numbers and the actual export,
    /// so the preview count can never drift from what gets copied.
    func highISOMatches(minISO: Int, keepersOnly: Bool) -> (raws: [BatchItem], jpegOnly: Int) {
        var raws: [BatchItem] = []
        var jpegOnly = 0
        for item in items {
            guard let iso = item.exif?.iso, iso >= minISO else { continue }
            if keepersOnly && item.verdict == .reject { continue }
            if ImageLoader.rawExtensions.contains(URL(fileURLWithPath: item.rawPath).pathExtension.lowercased()) {
                raws.append(item)
            } else {
                jpegOnly += 1
            }
        }
        return (raws, jpegOnly)
    }

    /// COPIES (never moves — the session's paths must stay valid) the RAW of
    /// every photo at/above `minISO` into "<拍摄文件夹>/高ISO降噪". That subfolder
    /// is excluded from analysis scans, so re-running 开始分析 won't double-count.
    func exportHighISORaws(minISO: Int, keepersOnly: Bool) {
        guard !isRunning, let photoDir else { return }
        let (raws, jpegOnly) = highISOMatches(minISO: minISO, keepersOnly: keepersOnly)
        guard !raws.isEmpty else {
            lastError = "没有 ISO ≥ \(minISO) 的 RAW"
                + (jpegOnly > 0 ? " (\(jpegOnly) 张符合但只有 JPG)" : "")
            return
        }
        isRunning = true
        lastError = nil
        let destDir = photoDir.appendingPathComponent(ImageLoader.denoiseSubfolder)
        let sources = raws.map { URL(fileURLWithPath: $0.rawPath) }
        let total = sources.count
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag

        Task.detached { [weak self] in
            let fm = FileManager.default
            var copied = 0, existed = 0
            var failed: [String] = []
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                func size(_ url: URL) -> Int? {
                    ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
                }
                for (index, src) in sources.enumerated() {
                    if flag.isSet { break }
                    let dest = destDir.appendingPathComponent(src.lastPathComponent)
                    if fm.fileExists(atPath: dest.path), let s = size(src), size(dest) == s {
                        existed += 1  // complete copy from a previous run: skip
                    } else {
                        do {
                            // Size mismatch = a copy interrupted mid-file last
                            // time; replace it instead of trusting it forever.
                            if fm.fileExists(atPath: dest.path) {
                                try fm.removeItem(at: dest)
                            }
                            try fm.copyItem(at: src, to: dest)
                            copied += 1
                        } catch {
                            failed.append(src.lastPathComponent)
                        }
                    }
                    let done = index + 1
                    await MainActor.run { [weak self] in
                        self?.progressText = "复制 RAW \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "创建 \(ImageLoader.denoiseSubfolder) 文件夹失败: \(error.localizedDescription)"
                    self?.isRunning = false
                }
                return
            }

            let copiedCount = copied
            let existedCount = existed
            let summaryFailed = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                var parts = [(flag.isSet ? "已取消: 已复制 " : "已复制 ") + "\(copiedCount) 个 RAW → \(ImageLoader.denoiseSubfolder)/"]
                if existedCount > 0 { parts.append("\(existedCount) 个已存在跳过") }
                if jpegOnly > 0 { parts.append("\(jpegOnly) 张只有 JPG 未复制") }
                if summaryFailed.isEmpty {
                    self.progressText = parts.joined(separator: " · ")
                    NSWorkspace.shared.activateFileViewerSelecting([destDir])
                } else {
                    self.lastError = "高ISO RAW: \(copiedCount) 成功, \(summaryFailed.count) 失败 (\(summaryFailed.prefix(3).joined(separator: ", ")))"
                }
            }
        }
    }

    // MARK: - XMP export (native — writes sidecars directly, manual overrides included)

    func exportXMP() {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        lastError = nil
        // Verdicts/overrides live on the main actor, so the sidecar contents are
        // derived here; the detached task is pure file IO (thousands of atomic
        // writes on a big shoot would otherwise freeze the UI for seconds).
        let jobs: [(id: String, url: URL, content: String)] = items.map { item in
            let stars: Int
            let label: String?
            switch item.verdict {
            case .reject:
                stars = -1        // Bridge/LR read -1 as "rejected"; C1 filters by the red label instead
                label = "Red"     // the cross-app 淘汰 color — filterable in LR AND Capture One
            case .pick:
                stars = item.expressionScore ?? 4
                label = "Green"
            case .usable:
                stars = item.expressionScore.map { max(1, $0 - 1) } ?? 3
                label = nil
            }
            let xmpURL = URL(fileURLWithPath: item.rawPath).deletingPathExtension().appendingPathExtension("xmp")
            let reason = item.verdict == .reject ? item.rejectReasons.joined(separator: "; ") : ""
            return (item.id, xmpURL, Self.xmpContent(rating: stars, label: label, reason: reason))
        }
        let total = jobs.count
        // Lightroom Classic only reads .xmp sidecars for proprietary RAW; for
        // JPEG/TIFF/DNG it expects the metadata embedded. Capture One reads
        // sidecars for everything. Say so instead of reporting a clean success.
        let jpegOnly = items.filter {
            !ImageLoader.rawExtensions.contains(URL(fileURLWithPath: $0.rawPath).pathExtension.lowercased())
        }.count
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag

        Task.detached { [weak self] in
            var written = 0
            var preserved: [String] = []
            var failed: [String] = []
            for (index, job) in jobs.enumerated() {
                if flag.isSet { break }
                // Lightroom 把调色参数、关键字、GPS 都存在同名 .xmp 里。别人的
                // sidecar 一律不碰 —— 覆盖成我们这份只有星级的模板 = 整场调色报废。
                if FileManager.default.fileExists(atPath: job.url.path),
                   let existing = try? String(contentsOf: job.url, encoding: .utf8),
                   !existing.contains(Self.xmpMarker) {
                    preserved.append(job.id)
                    continue
                }
                do {
                    try job.content.write(to: job.url, atomically: true, encoding: .utf8)
                    written += 1
                } catch {
                    failed.append(job.id)
                }
                let done = index + 1
                if done % 50 == 0 || done == total {
                    await MainActor.run { [weak self] in
                        self?.progressText = "写入 XMP \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            }

            let writtenCount = written
            let preservedIds = preserved
            let failedIds = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                if failedIds.isEmpty {
                    var summary = flag.isSet ? "XMP 已取消: 已写入 \(writtenCount) 个" : "XMP 完成: \(writtenCount) 个已写入原图目录"
                    if !preservedIds.isEmpty {
                        summary += "；\(preservedIds.count) 个已有其它软件的 XMP (可能含 Lightroom 调色)，已保留未覆盖"
                    }
                    if jpegOnly > 0 {
                        summary += "；注意 \(jpegOnly) 张是纯 JPG：Lightroom 不读 JPG 旁的 .xmp (Capture One 可读)"
                    }
                    self.progressText = summary
                } else {
                    self.lastError = "XMP: \(writtenCount) 个成功, \(failedIds.count) 个失败 (\(failedIds.prefix(3).joined(separator: ", ")))"
                }
            }
        }
    }

    /// 我们自己写的 sidecar 的指纹 —— Lightroom 写的是 x:xmptk="Adobe XMP Core ..."。
    /// 靠它区分“上次是我们写的，可以安全覆盖”和“别人的数据，碰不得”。
    nonisolated static let xmpMarker = #"x:xmptk="选片工具""#

    /// Standard xmp:Rating (-1 rejected, 1-5 stars) + xmp:Label color, readable by
    /// Lightroom/Bridge/Capture One.
    static func xmpContent(rating: Int, label labelName: String?, reason: String) -> String {
        let escaped = reason
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let label = labelName.map { "   <xmp:Label>\($0)</xmp:Label>\n" } ?? ""
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="选片工具">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmp:Rating="\(rating)">
        \(label)   <dc:description xmlns:dc="http://purl.org/dc/elements/1.1/">
            <rdf:Alt>
             <rdf:li xml:lang="x-default">\(escaped)</rdf:li>
            </rdf:Alt>
           </dc:description>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}

extension Result where Success == Void, Failure == Never {
    enum ProcessOutcome {
        case success
        case failure(String)
        /// 用户点了取消 —— 不是错误，别报“服务在跑吗?”
        case cancelled
    }
}
