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
    /// 高光 / 暗部裁切里更糟的那个。新结果按主体区域（脸 → 头 + 上半身）算，老结果（analysis_version 1）
    /// 只有整张的，就用整张的。
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
    /// 拍摄时间，已经加上这台机身的对时偏移（`clockOffset`，没对过 = EXIF 原值）。章节、场、
    /// 按拍摄时间排序、时间轴都用它 —— 两台机器的钟差几分钟，混在一起的顺序才对得上。
    var captureTime: Date?
    /// 这台机身对时加的秒数（captureTime 里已经含着它）。换偏移时先减掉旧的再加新的。
    var clockOffset = 0
    let exif: ExifMeta?
    let horizonDeg: Double?
    /// Time-gap chapter (仪式/晚宴/外景...) — a >15min shooting pause starts a new one.
    var chapter: Int = 0
    /// 机身型号（EXIF Model）。导出文件名的 {相机} 用它；分「场」按下面的 `body`。
    var camera: String?
    /// 机身序列号（nil / "" = 没有）。两台同型号机身（主摄副摄都用 X-T50）只能靠它分开。
    var bodySerial: String?
    /// 机身 key（CameraBody.keys：型号，同型号有两台时带序列号）。双机位婚礼两台机器同一秒
    /// 各拍一张，是两个角度不是重复 —— 「场」必须按机身分开切，对时偏移也按它存。
    var body = ""
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
    /// Charges the VLM appeal cleared this photo of ("虚焦"/"闭眼"/"曝光裁切"/"欠曝"/"过曝") —
    /// shown as the 平反 badge so the photographer sees WHY it walked.
    var vlmRescued: [String] = []
    /// Burst-relative eye decision computed by applyThresholds (nil = no
    /// judgment: no usable face, or all faces too small to read reliably).
    var dynamicEyeClosed: Bool?
    /// Position in the manifest (folder listing order) — the 文件名 sort key.
    var order: Int = 0
    /// JPEG 截断（读卡出错、拷贝中断，解出来缺的那截是灰的）：带「文件损坏」判废片，复审也不送。
    var fileCorrupt = false
    /// 欠曝 / 过曝的依据（0–255 亮度）：主体脸的中位数（没有脸 = nil），整张的中位数和 p99。
    /// 老版本分析的全是 nil = 不判。
    var faceLuma: Double?
    var frameLuma: Double?
    var frameLumaP99: Double?
    /// 拍摄时间的小数秒（layer1 的 capture_subsec）：captureTime 只到整秒，同一秒连拍的先后看它。没有 = nil。
    var captureSubsec: Double?

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
    /// isRunning 里具体是哪两种（存储卡确认框据此决定：分析可以「停下并导入」，另一张卡在导就等它）。
    /// 只有 runAnalysis 写（离屏快照 --card-ui --running 也写，假装在分析）。
    @Published var analyzing = false
    @Published var importing = false
    /// 存储卡导入出的问题（有文件没导进来、卡上有读不出来的地方）：「先别格式化存储卡」这句话不能被
    /// 随后的切场次、分析清掉（lastError 会被清 —— 审查发现），单独放、用户自己点掉才没。
    @Published var importNotice: String?
    /// 导完、还没打开的那批（BatchView 闲着就马上打开；正在挑片 / 审片就留一条横幅等用户点）。
    @Published var finishedImport: CardImporter.FinishedImport?
    /// 还在排队等着导的卡（CardImportCenter 维护）：有排队的，导完这张先不打开、不分析，等最后一张导完再一起。
    @Published var queuedCardImports = 0
    /// 正在导的那张卡（CardImportCenter 据此不再为同一张卡弹确认框）。
    @Published var importingSource: URL?
    /// 每导完（或导失败）一张加一：BatchView 按这个时刻决定要不要打开 finishedImport。不按 isRunning 落下来
    /// 判断 —— 用户自己跑完一次分析也会落下来，那时候把他拽去导入的文件夹就莫名其妙了。
    @Published var importCompletions = 0
    @Published var progressText = ""
    /// 0...1 while a long task reports progress; nil hides the bar.
    @Published var progressFraction: Double?
    @Published var lastError: String?
    /// nil = show everything; otherwise only the chosen verdict group.
    @Published var verdictFilter: Verdict?
    /// When set, the 废片 section shows only rejects carrying this reason —
    /// "audit every 闭眼 kill in one pass" instead of hunting badges.
    @Published var reasonFilter: String?
    /// 时间轴「只看这一章」（ChapterSegment.chapter；nil = 全部章节）。只管网格显示和连拍挑选的范围，
    /// 不碰判决、不碰导出。换场次清掉。
    @Published var chapterFilter: Int?

    /// 生效中的「只看这一章」：那一章已经不在了（重新分析后章节变了、单章拍摄没有时间轴）就当没有，
    /// 不然网格会莫名其妙一张都不剩。
    var activeChapterFilter: Int? {
        guard let f = chapterFilter, chapterSegments.contains(where: { $0.chapter == f }) else { return nil }
        return f
    }
    /// 网格多选的「拼图」：把这几张的 id 交给拼图 tab（ContentView 收到后切过去、清空）。
    /// 网格选中状态是 BatchView 私有的，只能这样递过去。
    @Published var collageRequest: [String]?
    /// 网格多选的「进托盘」：只带进拼图托盘、不排版（筛「客户选中」⌘A 之后做相册用：拼图 (N) 会把 N 张排进一页）。
    @Published var collageTrayRequest: [String]?
    /// AI 的「在 app 里定位照片」（cull_show_photos，DESIGN §9.3）：反过来的那一条 —— 网格选中是 BatchView 私有的，
    /// 桥只能把要选的 id 递过去。BatchView 消费（选中、焦点、滚过去）以后置回 nil；用户停在别的 tab 时，等批量页
    /// 下次出现再消费。只改视图状态：不进撤销、不改筛选、不开检视器，也不会把 app 拉到前台。
    @Published var viewRequest: ViewRequest?
    /// BatchView 消费 viewRequest 以后回报的结果（桥读：选中了哪些、哪些被筛选藏起来了）。不发布。
    var viewApplied: ViewApplied?
    /// AI 改判 / 撤销改判以后批量页的一句提示（§9.4.3 第 11 步，桥写，10 s 后桥自己清掉；BatchView 的状态栏显示）。
    @Published var externalNotice: String?
    /// 批量页此刻开着哪些「一直忙」的东西（BatchView 写，桥读，§9.6b）。不发布：界面不跟着它重画。
    var liveUI = LiveUIFlags()

    struct ViewRequest: Equatable {
        let token: UUID
        /// 发请求时的场次 key：消费时场次换了就不认。
        let session: String
        let ids: [String]
        /// true = 选中这些（焦点落到第一张）；false = 只把焦点移到第一张。
        let select: Bool
    }

    struct ViewApplied {
        let token: UUID
        let selected: [String]
        let focus: String?
        /// 被当前筛选（只看废片、只看某章、客户选中……）藏起来的。
        let hidden: [String]
    }

    /// busyWithPhotos 拆成三样（§9.6b 第二轮改）：审片 / 检视器开着不挡改判，只挡切场次和定位照片。
    struct LiveUIFlags: Equatable {
        /// 确认框、导出框、选文件夹、对时面板、导入客户选择这类 sheet。
        var sheet = false
        /// 连拍挑选开着（它有自己的撤销记录）。
        var pick = false
        /// 审片模式或检视器开着。
        var viewing = false
    }
    /// Show only photos within ±15% of an active threshold — the ones on the
    /// knife's edge, worth eyeballing after a slider change. Runtime hedge for
    /// thresholds that were never calibrated against real bad photos.
    @Published var borderlineFilter = false
    /// Photographer's final say: id → forced verdict, wins over every threshold.
    /// Persisted so re-opening the app keeps manual decisions.
    @Published private(set) var overrides: [String: Verdict] = [:]
    /// 「接受推荐」（全部 / 本章）写进 overrides 的那些：得钉住（不然砍完对手的精选会掉回可用、
    /// 待处理的场永远定不下来），但那是算法的结果，不是你改的 —— ✋、「人工改判 N」、复盘统计
    /// （阈值建议、滑杆漏掉）都不算它们。你之后亲手改过的那张就从这里拿掉。存 accepted.json。
    /// 不单独发布：每次改它后面都跟着 applyThresholds（items / derived 会刷新界面）。
    private(set) var acceptedIDs: Set<String> = []

    /// 这张的判决是你亲手改的（不是「接受推荐」钉住的）。
    func isManual(_ id: String) -> Bool { overrides[id] != nil && !acceptedIDs.contains(id) }

    /// AI 经实时桥（cull_set_verdicts）改的判决的出处：id → 哪一次、哪个工具、什么时候、改之前、AI 判的。判决照样钉住、照样
    /// isManual（✋、「人工改判 N」、拼图挑片都不变），只是阈值建议、「滑杆漏掉」不拿它们当你纠错的样本，状态栏「人工改判 N
    /// （其中 AI M）」和 MCP 行的 changed_by 分得出来。你之后亲手改过（改判、定案、接受推荐）就拿掉。存 ai_overrides.json。
    private(set) var aiOverrides: [String: AIOverride] = [:]

    struct AIOverride: Codable, Equatable {
        let opID: String
        let tool: String
        let at: Date
        /// AI 第一次动这张之前的判决（Verdict.rawValue；nil = 自动判的）。AI 改了好几次也留最早那次之前的。
        let previous: String?
        /// AI 判的（Verdict.rawValue）。读回来时和 overrides 里的对不上 = 之后被别的（老版本 app）改过，丢掉。
        let aiVerdict: String

        enum CodingKeys: String, CodingKey {
            case opID = "op_id", tool, at, previous, aiVerdict = "ai_verdict"
        }

        /// previous 是 nil（原来是自动判的）也写出来（null），不省掉这个键。
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(opID, forKey: .opID)
            try c.encode(tool, forKey: .tool)
            try c.encode(at, forKey: .at)
            try c.encode(previous, forKey: .previous)
            try c.encode(aiVerdict, forKey: .aiVerdict)
        }
    }

    /// 这张现在的判决是 AI 改的（有出处、还是人工改判）。
    func aiOverride(_ id: String) -> AIOverride? { isManual(id) ? aiOverrides[id] : nil }

    /// 客户选中（「导入客户选择…」：客户在确认表里点的、微信里回的文件名 / 编号）。和判决是两回事：
    /// 不改判决、不进 overrides，只多一个标记 —— 缩略图上的紫心、「只看客户选中」、XMP 紫色标。
    /// 存 client_picks.json。改它的地方都压撤销记录（和改判同一条 ⌘Z）。
    @Published private(set) var clientPicks: Set<String> = []
    /// 「只看客户选中」：和判决筛选叠加；复制文件名 / 复制原片没选中照片时就按它定范围。换场次清掉。
    @Published var clientPickFilter = false
    /// 客户在确认表上给照片写的备注（修图要求：「去路人」「瘦脸」），照片 id → 原话。导入客户选择时和客户选中一起进来、
    /// 同一步 ⌘Z；存 client_notes.json。复制原片时写成「精修要求.csv」。不写进 XMP（dc:description 放的是判决理由）。
    @Published private(set) var clientNotes: [String: String] = [:]

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
            // 无头（命令行、测试宿主）只改内存：设置域和用户界面共用（从 .app 里跑就是用户真实的那份）。
            if !AppRuntime.headless { UserDefaults.standard.set(minKeepersPerChapter, forKey: "batch.minKeepersPerChapter") }
            applyThresholds()
        }
    }

    static let defaultTakeGapSec: Double = 8
    @Published var takeGapSec: Double = defaultTakeGapSec { didSet { onTakeGapEdited() } }

    /// 连拍去重：开启后每个连拍组只留下最佳的那张，组内其余**未被人工改判**的照片
    /// 自动带上「连拍重复」理由淘汰。这是规则式的（不写进 overrides），关掉开关
    /// 整组立刻全部回来——和手动的「保留选中·其余废片」正好互补，后者是永久的。
    /// 默认关：老场次重新打开时废片数不该无声无息地翻倍。
    ///
    /// 按场次存（thresholds.json 的 rejectBurstDuplicates，审查 S20a）：以前是全局的 UserDefaults，在一场里拨一下，
    /// 别的场次下次打开时没定完的近似重复组就被重新判（精选掉成可用、写过 XMP 的冒出「待更新」）。现在拨开关只改这一场，
    /// 连同阈值一起写进这一场和数据目录里「上次用的」那份（新场次照它打底）；**不再写 UserDefaults**：
    /// batch.rejectBurstDuplicates 冻在升级前的值，只给还没有这个键的老场次回落用（见 loadThresholds），
    /// 不然在新场次拨一下，还没打开过的老场次第一次打开时照样跟着变。
    @Published var rejectBurstDuplicates: Bool = BatchStore.globalRejectBurstDuplicates {
        didSet {
            guard !batchingThresholds else { return }
            // 命令行钉着（--verdicts --dedupe）时只在内存里：这一场存的值不动
            if AppRuntime.pinnedRejectBurstDuplicates == nil { sessionRejectBurstDuplicates = rejectBurstDuplicates }
            applyThresholds()
            scheduleThresholdSave()
        }
    }

    /// 升级前那个全局开关（UserDefaults 的 batch.rejectBurstDuplicates）：没存这个键的老场次回落到它、新场次没有「上次用的」时
    /// 照它打底。界面不再写它。无头入口钉在 argument domain 里（AppRuntime.pinBatchSettings），读到的是钉的值。
    nonisolated static var globalRejectBurstDuplicates: Bool {
        UserDefaults.standard.bool(forKey: "batch.rejectBurstDuplicates")
    }

    /// 这一场 thresholds.json 里该写的去重开关：nil = 文件里没有这个键（老场次、还没回落写回），写的时候照样不写这个键。
    /// 和 rejectBurstDuplicates 分开记，是因为命令行钉的值只在内存里，不能顺着拖滑杆、--gap 写进这一场。
    private var sessionRejectBurstDuplicates: Bool?

    /// 老场次（thresholds.json 里没有去重这个键）第一次打开时，把回落到的全局值写回这一场，以后就按它、不再跟着全局走。
    /// 无头入口不写：它们读到的全局值是钉在内存里的（默认关），不是用户界面里的那个，写回去就把老场次冻成了错的值。
    /// --persist-selftest 打开它来验界面那条路。
    var writesBackLegacyDedupe = !AppRuntime.headless

    // MARK: Threshold persistence (per shoot, plus a "last used" default)

    /// Thresholds are a per-shoot decision (a dim banquet needs a looser
    /// sharpness line than a studio day), so they live in the session dir and
    /// come back with it. They used to reset to the defaults on every launch:
    /// yesterday's 废片 count was different this morning and nobody knew why.
    struct ThresholdState: Codable {
        var sharpness: Double
        var exposure: Double
        var faceQuality: Double
        /// 可选：老的 thresholds.json 没有这个键，解码后回落到默认值。
        var takeGap: Double?
        /// 「近似重复只留最佳」（按场次存，审查 S20a）。可选：老的 thresholds.json 没有这个键，打开时回落到升级前的全局开关并写回
        /// 这一场（loadThresholds）。只保得住升级那天看到的判决，保不住当初写 XMP 时用的那个值。
        var rejectBurstDuplicates: Bool?
    }

    private var thresholdSaveTask: Task<Void, Never>?
    /// Set while a preset/session load assigns all three at once, so the
    /// didSet chain recomputes and saves once instead of three times.
    private var batchingThresholds = false

    private func thresholdsPath(in dir: URL) -> URL { dir.appendingPathComponent("thresholds.json") }

    nonisolated private static func readThresholds(_ dir: URL) -> ThresholdState? {
        (try? Data(contentsOf: dir.appendingPathComponent("thresholds.json")))
            .flatMap { try? JSONDecoder().decode(ThresholdState.self, from: $0) }
    }

    /// 什么都没设过时的默认 = 「标准」预设（以前是 45/0.15/0，不属于任何预设：第一次打开就显示「自定义」，
    /// 连拍组内的人脸质量比较也不跑）。
    nonisolated static let freshThresholds = ThresholdState(sharpness: 45, exposure: 0.15, faceQuality: 0.30, takeGap: nil)
    /// 升级前的默认值。已经分析过、但从没存过阈值的老场次按它来，判决不因为升级悄悄变。
    nonisolated static let legacyThresholds = ThresholdState(sharpness: 45, exposure: 0.15, faceQuality: 0, takeGap: nil)

    /// 这一场的阈值。场次目录里还没有 thresholds.json 时当场定一份写进去，以后就按它（不再每次猜）：
    /// 上次用的那份（数据目录里的）优先，和以前一样给新场次打底；没有的话，已经有分析结果的老场次用升级前
    /// 的默认值，全新的场次用「标准」。命令行 --analyze 不经过 BatchStore，分析前也先调它，和界面一致。
    @discardableResult
    nonisolated static func sessionThresholds(sessionDir: URL, dataDir: URL) -> ThresholdState {
        sessionThresholdsChecked(sessionDir: sessionDir, dataDir: dataDir).state
    }

    /// 同上，另外报一句这一场的 thresholds.json 出了什么事（nil = 没事）。以前解不开就悄悄换成「上次用的」并写回去，
    /// 这一场的自动判决跟着变、原件也没了（审查 S02）：现在解不开的先挪成 thresholds.corrupt-<时间>.json，再照原来的
    /// 回落顺序定一份；读不出来、挪不开的照样回落，但不写回去。
    nonisolated static func sessionThresholdsChecked(sessionDir: URL, dataDir: URL) -> (state: ThresholdState, notice: String?) {
        let ownURL = sessionDir.appendingPathComponent("thresholds.json")
        var problem: String?
        var writable = true
        switch SessionFiles.read(ThresholdState.self, at: ownURL) {
        case .ok(let own): return (own, nil)
        case .missing: break
        case .corrupt(let moved?):
            problem = "阈值文件 thresholds.json 解不开（被手改过或写坏了），原件已挪成 \(moved.lastPathComponent)"
        case .corrupt(nil):
            problem = "阈值文件 thresholds.json 解不开、也挪不开（先不写回去）"
            writable = false
        case .unreadable(let why):
            problem = "阈值文件 thresholds.json 读不出来（\(why)，先不写回去）"
            writable = false
        }
        let fm = FileManager.default
        let analyzed = ["layer1_results.json", "manifest.json"].contains {
            fm.fileExists(atPath: sessionDir.appendingPathComponent($0).path)
        }
        let lastUsed = readThresholds(dataDir)
        var state = lastUsed ?? (analyzed ? legacyThresholds : freshThresholds)
        // 去重开关：全新的场次照「上次用的」；已经分析过的老场次不跟「上次用的」走（那是升级以后别的场次拨的），
        // 留空，打开时回落到升级前的全局开关（loadThresholds），和它一直看到的判决一样。
        if analyzed { state.rejectBurstDuplicates = nil }
        if writable, let data = try? JSONEncoder().encode(state) {
            SessionFiles.writeLogged(data, to: ownURL)
        }
        guard let problem else { return (state, nil) }
        let fallback = lastUsed != nil ? "上次用的阈值" : (analyzed ? "升级前的默认阈值" : "「标准」预设")
        return (state, problem + "，这一场先按\(fallback)判：判决可能和上次不一样，看一眼右侧的滑杆")
    }

    private func loadThresholds() {
        // 没开文件夹（sessions/default）不落盘，和 scheduleThresholdSave 一样。
        let state: ThresholdState
        var fileIsSound = false
        if photoDir != nil {
            let checked = Self.sessionThresholdsChecked(sessionDir: sessionDir, dataDir: dataDir)
            state = checked.state
            fileIsSound = checked.notice == nil
            if let notice = checked.notice { addDataNotice(sessionLabel + notice) }
        } else {
            state = Self.readThresholds(dataDir) ?? Self.freshThresholds
        }
        // 去重开关按场次（审查 S20a）：这一场存的优先；没存（老场次）回落到全局开关 —— 读 UserDefaults，
        // 不用内存里上一场的值，不然从开着的那场切过来，老场次就跟着上一场变了。
        let globalDedupe = Self.globalRejectBurstDuplicates
        sessionRejectBurstDuplicates = state.rejectBurstDuplicates
        if state.rejectBurstDuplicates == nil, photoDir != nil, fileIsSound, writesBackLegacyDedupe {
            // 只写这一场那份（不经 scheduleThresholdSave：打开老场次不算「用过」，数据目录里「上次用的」不动）
            var migrated = state
            migrated.rejectBurstDuplicates = globalDedupe
            if let data = try? JSONEncoder().encode(migrated),
               SessionFiles.writeLogged(data, to: thresholdsPath(in: sessionDir)) {
                sessionRejectBurstDuplicates = globalDedupe
            }
        }
        let storedDedupe: Bool = sessionRejectBurstDuplicates ?? globalDedupe
        batchingThresholds = true
        sharpnessThreshold = state.sharpness
        exposureThreshold = state.exposure
        faceQualityThreshold = state.faceQuality
        takeGapSec = state.takeGap ?? Self.defaultTakeGapSec
        // 命令行钉的（--verdicts --dedupe）盖过这一场存的，只在内存里
        rejectBurstDuplicates = AppRuntime.pinnedRejectBurstDuplicates ?? storedDedupe
        batchingThresholds = false
    }

    /// Debounced: a slider drag fires once per pixel. Writes the session copy
    /// and the app-wide "last used" copy that seeds brand-new shoots.
    /// 去重开关写的是这一场存的那个（sessionRejectBurstDuplicates）：命令行钉的值不落盘，老场次没回落写回时照样不写这个键。
    private func scheduleThresholdSave() {
        thresholdSaveTask?.cancel()
        let state = ThresholdState(sharpness: sharpnessThreshold, exposure: exposureThreshold,
                                   faceQuality: faceQualityThreshold, takeGap: takeGapSec,
                                   rejectBurstDuplicates: sessionRejectBurstDuplicates)
        let targets = [thresholdsPath(in: dataDir)] + (photoDir != nil ? [thresholdsPath(in: sessionDir)] : [])
        thresholdSaveTask = Task { [targets] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(state) else { return }
            // 写不上只记日志：下次打开按「上次用的」打底，丢的只是这一次拖的滑杆（审查 S01）。
            for url in targets { SessionFiles.writeLogged(data, to: url) }
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
        /// 还需要人取舍的「场」数（定义见 isPendingTake）。一场里已经定成 1 张精选、
        /// 其余废片的，活儿干完了，不该再占着网格。顶栏每次重绘都读它,
        /// 所以和 verdictCounts 一起在 rebuildDerived 里算一次,别做成 O(n) 计算属性。
        var pendingTakeCount = 0
        /// 待处理的场号，升序（= 时间顺序）。连拍挑选的 ⏎ 找下一组、网格的 D 跳场用，每次按键不再扫全部照片。
        var pendingTakes: [Int] = []
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
        /// 真正经你手改过的张数（overrides 去掉「接受推荐」钉的）：状态栏「人工改判 N」。
        var manualOverrideCount = 0
        /// 其中 AI 经实时桥改的（aiOverrides）：状态栏「人工改判 N（其中 AI M）」。
        var aiOverrideCount = 0
        /// 上次写 XMP 之后判决变了的张数（从没写过 = 0，不提醒）。Lightroom / C1 看的是 XMP，
        /// 在这里改完忘了重写，那边还是旧结果。
        var xmpStaleCount = 0
        /// 客户选中里还在这一场的张数（状态栏、顶栏「客户选中 N」）。
        var clientPickCount = 0
        /// 判成废片、可客户点名要了的张数：「废片移到废纸篓」不动它们。
        var clientPickRejectCount = 0
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
    var manualOverrideCount: Int { derived.manualOverrideCount }
    var aiOverrideCount: Int { derived.aiOverrideCount }
    /// 状态栏那一句：「人工改判 N」，其中有 AI 经实时桥改的再带「（其中 AI M）」。
    var manualOverrideLabel: String {
        let ai = aiOverrideCount
        let tail = ai > 0 ? "（其中 AI \(ai)）" : ""
        return "人工改判 \(manualOverrideCount)" + tail
    }
    var pendingTakes: [Int] { derived.pendingTakes }

    /// 「待处理」的场：还留着 2 张以上没淘汰，而且其中还有没经你手的（自动判的）。
    /// 以前只看"存活 ≥2"：K 勾两张定案（两张手判精选、其余手判废片）的场永远算待处理，
    /// D 和连拍挑选的 ⏎ 会一直绕回这些早就定完的场。全经你手定过的就是定完了。
    func isPendingTake(alive: [BatchItem]) -> Bool {
        alive.count >= 2 && alive.contains { overrides[$0.id] == nil }
    }
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
    var xmpStaleCount: Int { derived.xmpStaleCount }
    /// 这一场写过 XMP 没有（xmp_state.json 在）：没写过时 xmpStaleCount 永远是 0，MCP 的概览要分得清「没过期」和「没写过」。
    var xmpEverWritten: Bool { xmpState != nil }
    var clientPickCount: Int { derived.clientPickCount }
    var clientPickRejectCount: Int { derived.clientPickRejectCount }
    /// 「废片移到废纸篓」默认真会移的张数：废片里去掉客户选中的（客户点名要精修的照片不扔）、拼图里在用的
    /// （不挖空拼图页、印样帧、存好的方案，见 collageInUseIDs）。
    var trashableRejectCount: Int { verdictCounts.reject - clientPickRejectCount - collageProtectedRejectCount }
    /// 「废片移到废纸篓」默认要移的那些照片（和上面的张数是同一个条件）。
    var trashableRejects: [BatchItem] {
        items.filter { $0.verdict == .reject && !clientPicks.contains($0.id) && !collageInUseIDs.contains($0.id) }
    }
    /// 确认框里点「连这些一起移」时要移的：拼图里在用的也算上，客户选中的照样不动。
    var trashableRejectsIncludingCollage: [BatchItem] {
        items.filter { $0.verdict == .reject && !clientPicks.contains($0.id) }
    }

    // MARK: - 拼图在用的照片（「废片移到废纸篓」默认不动）

    /// 拼图各页（格子、图层、印样帧）和方案栏各方案用到的照片 id。AppModel 从内存里的 CollageStore 推过来（不读防抖
    /// 保存的 collage.json）；没接（--verdicts、--client-import 这类只开批量页的无头入口）= 空。只在托盘里的不算。
    @Published private(set) var collageInUseIDs: Set<String> = []
    /// 现取一次（先让拼图工程挂到这一场再读）：AppModel 设。点「废片移到废纸篓」和真移之前走 refreshCollageInUse()。
    var collageInUseSource: (() -> Set<String>)?

    func setCollageInUse(_ ids: Set<String>) {
        if ids != collageInUseIDs { collageInUseIDs = ids }
    }

    func refreshCollageInUse() {
        if let source = collageInUseSource { setCollageInUse(source()) }
    }

    /// 废片里客户没选中、但拼图里在用的张数：默认不移，确认框里可以选「连这些一起移」。只查拼图那一份 id，不扫整场。
    var collageProtectedRejectCount: Int {
        collageInUseIDs.reduce(0) { n, id in
            guard let item = item(withID: id), item.verdict == .reject, !clientPicks.contains(id) else { return n }
            return n + 1
        }
    }

    /// 写进 XMP 的那几样：判决（色标 / -1 废片）、星级（判决定档，VLM 表情分只在档内排先后），
    /// 客户选中（紫色标）。`c` 只在客户选中时是 true，其余一律 nil（不是 false）：老的 xmp_state.json
    /// 没有这个键，没选中的照片比对起来和以前一模一样，升级后不会整场变「XMP 过期」。
    struct XMPMark: Codable, Equatable {
        let v: String
        let s: Int
        var c: Bool? = nil
    }

    /// 这一场写过的 XMP（xmp_state.json）：每张最后一次**真正写进去**的样子，加上别的软件写的、
    /// 我们没碰的那些。nil = 这一场还没写过，不提醒。
    private struct XMPState: Codable {
        var marks: [String: XMPMark] = [:]
        var foreign: Set<String> = []
        /// foreign 已按现在的归属规则复查过。旧版本存的没有这个字段（见 recheckForeignSidecars）。
        var foreignRechecked: Bool?
        /// 上次写 XMP 时认出来的同名冲突（几张照片共用一个 .xmp，整组没写）。旧版本没有这个字段 = nil。
        var sharedSidecar: Set<String>?
    }
    private var xmpState: XMPState?
    private var xmpStatePath: URL { sessionDir.appendingPathComponent("xmp_state.json") }

    private func loadXMPState() {
        guard let data = try? Data(contentsOf: xmpStatePath) else {
            xmpState = nil
            return
        }
        xmpState = try? JSONDecoder().decode(XMPState.self, from: data)
    }

    /// 旧版本把本工具更早写的 sidecar（rate.py 的 culling-poc 标记）也记成了「别人的」，「XMP 过期」
    /// 从来不算它们 —— 升级后不重新导一次，改判了也不提醒，LR/C1 一直是旧星级。打开场次时按现在的规则
    /// 复查一次：是我们自己的就从 foreign 拿出来（没有 marks = 没写过，算过期，下次写 XMP 整份重写）。
    /// 只查一次（记 foreignRechecked），大场次别每次打开都读几千个 sidecar；照片文件夹不在（硬盘没插）先不查。
    private func recheckForeignSidecars() {
        guard var state = xmpState, state.foreignRechecked != true,
              let dir = photoDir, FileManager.default.fileExists(atPath: dir.path) else { return }
        let paths = Dictionary(items.map { ($0.id, $0.rawPath) }, uniquingKeysWith: { first, _ in first })
        for id in state.foreign {
            guard let raw = paths[id] else { continue }
            let url = URL(fileURLWithPath: raw).deletingPathExtension().appendingPathExtension("xmp")
            if let data = try? Data(contentsOf: url), XMPSidecar.isOwn(data) { state.foreign.remove(id) }
        }
        saveXMPState(state)
    }

    private func saveXMPState(_ state: XMPState) {
        var state = state
        // 这里写下的 foreign 都是按现在的规则判的（导出时逐张判过，或者刚复查过）。
        state.foreignRechecked = true
        xmpState = state
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: xmpStatePath, options: .atomic)
        }
    }

    /// 和 XMP 对不上的张数：写过的按「判决 + 星级」比；从没写进去的（新照片、上次写失败的）也算；
    /// 别的软件的 XMP 我们不碰，不算。
    private func xmpStale(in items: [BatchItem]) -> Int {
        guard let state = xmpState else { return 0 }
        var n = 0
        for item in items where Self.xmpNeedsWrite(item, state: state, clientPick: clientPicks.contains(item.id)) {
            n += 1
        }
        return n
    }

    /// 这一张要不要（重）写 XMP：别的软件的、合并不了的不算（菜单「全部重写 XMP」才再试）；记下的样子和现在的
    /// 不一样（含从没写进去的）就要。状态栏「XMP 待更新 N 张」的 N 和点它时「只写改了的」挑哪几张都用这一个判断，
    /// 两边不会算岔。不查 sidecar 在不在：xmpStale 在派生数据重算里跑（拖滑杆也算），丢了的、被别的软件整份
    /// 覆盖的交给菜单里的全部重写。
    private static func xmpNeedsWrite(_ item: BatchItem, state: XMPState, clientPick: Bool) -> Bool {
        !state.foreign.contains(item.id) && state.marks[item.id] != xmpMark(item, clientPick: clientPick)
    }

    /// 这一场写过 XMP 没有（菜单上叫「写入 XMP」还是「全部重写 XMP」）。
    var hasWrittenXMP: Bool { xmpState != nil }

    /// 「XMP 待更新」里因为同名共用一个 .xmp 写不了的张数（上次写 XMP 时认出来的、还在这一场、还算待更新的）。
    var xmpSharedSidecarCount: Int {
        guard let state = xmpState, let shared = state.sharedSidecar else { return 0 }
        return shared.reduce(0) { n, id in
            guard let item = item(withID: id) else { return n }
            return n + (Self.xmpNeedsWrite(item, state: state, clientPick: clientPicks.contains(id)) ? 1 : 0)
        }
    }

    /// XMP 里的星级和色标。导出和「XMP 过期」比对共用这一份，两边不会算岔。
    /// 判决定星级档：精选 4–5、可用 2–3、废片 -1 —— 精选永远比可用星多，LR 里按「≥4 星」筛精修
    /// 不会漏掉你亲手定的精选。VLM 表情分只在档内排先后（表情好的精选 5 星、表情差的可用 2 星）；
    /// 以前星级直接等于表情分，表情分 1 的精选只有 1 星，排在 4 星的可用后面。
    /// 没跑过 VLM 的：精选 4、可用 3，和以前一样（老场次不会因此全变「XMP 过期」）。
    /// 客户选中的色标是紫色（压过判决的绿 / 红），星级照判决不变。
    static func xmpRating(_ item: BatchItem, clientPick: Bool = false) -> (stars: Int, label: String?) {
        let stars: Int
        switch item.verdict {
        case .reject: stars = -1    // Bridge/LR read -1 as "rejected"; C1 filters by the red label instead
        case .pick: stars = (item.expressionScore ?? 0) >= 4 ? 5 : 4
        case .usable: stars = (item.expressionScore ?? 3) >= 3 ? 3 : 2
        }
        return (stars, clientPick ? clientPickLabel : xmpLabel(item.verdict))
    }

    /// 客户选中的色标：LR / C1 里按紫色一筛就是要精修的那些。
    static let clientPickLabel = "Purple"

    /// 上次写进这张 XMP 的色标（xmp_state.json 里记的那份）：客户选中 = 紫，否则按判决。
    /// 别人的 sidecar 里色标还是它才算「我们写的」，这次不要了才拿掉（XMPSidecar.merged 的 lastLabel）。
    static func writtenLabel(_ mark: XMPMark) -> String? {
        if mark.c == true { return clientPickLabel }
        return Verdict(rawValue: mark.v).flatMap(xmpLabel)
    }

    /// 判决对应的色标：精选绿、废片红（LR 和 C1 都能按色标筛），可用不带。
    static func xmpLabel(_ verdict: Verdict) -> String? {
        switch verdict {
        case .reject: return "Red"
        case .pick: return "Green"
        case .usable: return nil
        }
    }

    static func xmpMark(_ item: BatchItem, clientPick: Bool = false) -> XMPMark {
        XMPMark(v: item.verdict.rawValue, s: xmpRating(item).stars, c: clientPick ? true : nil)
    }

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
        let byCamera = Dictionary(grouping: items.filter { $0.captureTime != nil }, by: \.body)
        for (_, shots) in byCamera {
            let times = shots.compactMap(\.captureTime).sorted()
            for i in 1..<max(1, times.count) {
                gaps.append(times[i].timeIntervalSince(times[i - 1]))
            }
        }
        captureGaps = gaps
        captureGapBins = Self.histogramBins(gaps, range: Self.captureGapHistRange, sqrtScale: true)
        bodies = Self.bodySummary(items, offsets: bodyOffsets)
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
            if clientPicks.contains(item.id) {
                d.clientPickCount += 1
                if item.verdict == .reject { d.clientPickRejectCount += 1 }
            }
            if let q = item.faceQuality, (groupQCount[item.burstGroup] ?? 0) < 2 {
                d.faceQualityAbsoluteValues.append(q)
            }
        }
        var aliveByTake: [Int: [BatchItem]] = [:]
        for item in items where item.verdict != .reject { aliveByTake[item.take, default: []].append(item) }
        d.pendingTakes = aliveByTake.filter { isPendingTake(alive: $0.value) }.map(\.key).sorted()
        d.pendingTakeCount = d.pendingTakes.count
        for (_, alive) in aliveByTake where alive.count > 1 {
            let ranked = alive.sorted { Self.scoreKey($0) > Self.scoreKey($1) }
            for (i, item) in ranked.prefix(3).enumerated() { d.takeRank[item.id] = i + 1 }
        }
        d.verdictCounts = (r, u, p)
        d.manualOverrideCount = overrides.keys.filter { !acceptedIDs.contains($0) }.count
        d.aiOverrideCount = aiOverrides.keys.filter { isManual($0) }.count
        for (idx, item) in items.enumerated() { d.byVerdict[item.verdict, default: []].append(idx) }
        d.sharpnessBins = Self.histogramBins(items.map(\.sharpness), range: Self.sharpnessHistRange, sqrtScale: false)
        d.exposureBins = Self.histogramBins(items.map(\.worstClipPct), range: Self.exposureHistRange, sqrtScale: true)
        d.faceQualityBins = Self.histogramBins(d.faceQualityAbsoluteValues, range: Self.faceQualityHistRange, sqrtScale: false)
        // 时间轴上每章标「还有几场连拍没定」：场不会跨章（场内相邻两张 ≤ 几十秒，章节之间
        // 隔着 15 分钟以上），所以拿任意一张成员的章节就是整场的章节。
        var takeChapter: [Int: Int] = [:]
        for item in items { takeChapter[item.take] = Self.timelineChapter(of: item) }
        var pendingByChapter: [Int: Int] = [:]
        for take in d.pendingTakes {
            if let chapter = takeChapter[take] { pendingByChapter[chapter, default: 0] += 1 }
        }
        (d.chapterSegments, d.chapterWarnings) = Self.chapterSummary(items, minKeepers: minKeepersPerChapter,
                                                                     pendingByChapter: pendingByChapter)
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
        d.xmpStaleCount = xmpStale(in: items)
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
            if !AppRuntime.headless { UserDefaults.standard.set(sortOrder.rawValue, forKey: "batch.sortOrder") }
            var sorted = items
            Self.sort(&sorted, by: sortOrder)
            items = sorted
            applyThresholds()
        }
    }

    /// Stable: ties (and undated photos, which sort last) fall back to the
    /// manifest order so two runs never disagree.
    static func sort(_ array: inout [BatchItem], by order: SortOrder) {
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
        // 退出时把没存上的判决、客户选中、对时再写一次（审查 S01）。拦住退出要 NSApplicationDelegateAdaptor，不在这里做。
        persistTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.retryPersist() }
        }
        loadSessionsIndex()
        // Reopen the most recent shoot so relaunching the app doesn't lose context.
        if let last = recentSessions.first {
            switchSession(to: URL(fileURLWithPath: last.path))
        } else {
            loadThresholds()
            loadOverrides()
            loadClientPicks()
            loadClientNotes()
            loadXMPState()
            loadBodyOffsets()
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
    /// `followBookmark: false`（实时桥的 app_open_session）：不解析 bookmark，原样用给的路径 —— 文件夹被挪进
    /// 桌面 / 外置盘以后，bookmark 会把 app 带到那里去读，绕过 AI 那一侧只按字符串做的受保护位置检查（§10.4）。
    private func restoreAccess(to folder: URL, followBookmark: Bool = true) -> URL {
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
        guard followBookmark, let bookmark = recentSessions
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
    /// `followBookmark` 只有实时桥传 false（见 restoreAccess）：挪走了的文件夹就照常提示「照片文件夹已不存在」。
    /// 返回 false = 没切（正在处理中，或者这一场还有改动没存上）：调用方别接着「分析新文件夹」「报已打开」。
    @discardableResult
    func switchSession(to folder: URL, followBookmark: Bool = true) -> Bool {
        // 处理中切换会把 A 的流式结果灌进 B 的网格（同名文件还会顶掉 B 的行），
        // 而 isRunning 永远停在 true —— 之后 runAnalysis 的 guard 让“重新分析”
        // 静默失效，用户点了毫无反应。先取消，再切。
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再切换文件夹"
            return false
        }
        // 判决、客户选中、对时还有没存上的（盘满了）：再写一次，还不行就不切（审查 S01）。
        guard persistBeforeLeaving("切场次") else { return false }
        let resolved = restoreAccess(to: folder, followBookmark: followBookmark)
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
        acceptedIDs = []
        overrideUndoStack = []
        reasonFilter = nil
        borderlineFilter = false
        chapterFilter = nil
        clientPickFilter = false
        // 判决筛选也要跟着清：留着"只看废片"切到新场次，网格里只有废片，
        // 看起来像是"照片少了一大半"。
        verdictFilter = nil
        lastError = nil
        loadReviewPosition()
        loadThresholds()
        loadOverrides()
        loadAIOverrides()
        loadClientPicks()
        loadClientNotes()
        loadXMPState()
        loadBodyOffsets()
        loadResults()
        recheckForeignSidecars()
        applyThresholds()
        // Cached results load happily from a folder that no longer exists — say
        // so up front instead of letting 导出/分析 fail silently later.
        if !FileManager.default.fileExists(atPath: resolved.path) {
            lastError = "「\(folder.lastPathComponent)」的照片文件夹已不存在 (被删除、改名或所在硬盘未挂载)。" +
                        "下面是上次分析的缓存结果，重新分析/导出/写 XMP 都会失败。"
        } else if previewsPruned {
            lastError = "这一场的预览图已清理省空间（掉出了最近 15 场，或者从「移除历史记录」里移除过），判决和人工改判都还在。" +
                        "点「重新分析」补回预览：没变的照片只重做预览，人工改判不会动"
        }
        // Register a session that HAS cached results as soon as it's opened, not
        // just after an analysis: pruneOrphanedSessions clears the previews of
        // every sessions/<key> missing from this index (it used to delete the
        // whole dir, overrides.json included), so a session that was only ever
        // opened would lose its previews the next time any other folder was analyzed.
        // Empty ones stay out — a mistaken pick shouldn't land in the menu
        // forever, or push the oldest real session (and its previews) out at the 15 cap.
        if !items.isEmpty { touchSessionIndex() }
        refreshSessionAvailability()
        postResultsChanged(previewsChanged: false)
        return true
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
    /// pruneOrphanedSessions treats it as live instead of clearing its previews
    /// the next time the app analyzes anything.
    /// 读的时候和 app 一样一条一条解（SessionsIndexFile，审查 S02c：以前 `?? []` 再整份覆盖，一条坏了全没）：
    /// 读不懂的那几条原样留着；整份解不开的先挪成 sessions.corrupt-<时间>.json；读不出来的不写。
    nonisolated static func registerSession(dataDir: URL, folder: URL, photoCount: Int) {
        let indexPath = dataDir.appendingPathComponent("sessions.json")
        let key = sessionKey(for: folder)
        func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        var index = SessionsIndexFile()
        if FileManager.default.fileExists(atPath: indexPath.path) {
            guard let data = try? Data(contentsOf: indexPath) else {
                say("sessions.json 读不出来：这一场没登记进「最近场次」（没改写它）")
                return
            }
            if let decoded = SessionsIndexFile.decode(data) {
                index = decoded
            } else if let moved = SessionFiles.moveAside(indexPath) {
                say("sessions.json 解不开，原件已挪成 \(moved.lastPathComponent)，重新建一份")
            } else {
                say("sessions.json 解不开、也挪不开：这一场没登记进「最近场次」（没改写它）")
                return
            }
        }
        index.entries.removeAll { $0.key == key }
        index.unknown.removeAll { $0.key == key }
        index.entries.insert(SessionEntry(
            key: key, path: folder.standardizedFileURL.path, name: folder.lastPathComponent,
            lastAnalyzed: ISO8601DateFormatter().string(from: Date()),
            photoCount: photoCount,
            bookmark: makeBookmark(for: folder)
        ), at: 0)
        index.entries = Array(index.entries.prefix(15))
        if let data = try? index.encoded() { SessionFiles.writeLogged(data, to: indexPath) }
    }

    /// sessions.json 这次启动没读全（整份解不开、读不出来）：哪些场次还在菜单里不知道，pruneOrphanedSessions 这次
    /// 启动不跑 —— 跑了就是把它们全当成掉出了菜单，删掉十几场的预览（审查 S02c，最要紧的一条）。
    private var pruneDisabled = false
    /// sessions.json 在、却读不出来（或者解不开又挪不开）：这次启动不改写它。
    private var sessionsIndexReadOnly = false
    /// sessions.json 里读不懂的那几条：原样写回去，不进菜单，它们的场次也不清预览。
    private var sessionsIndexUnknown: [SessionsIndexFile.Unknown] = []

    private func loadSessionsIndex() {
        guard FileManager.default.fileExists(atPath: sessionsIndexPath.path) else { return }
        let stillThere = "这次「最近场次」是空的（判决、拼图都还在各场次里，从「选择文件夹…」打开那个文件夹就回来），" +
                         "这次启动不清旧场次的预览"
        guard let data = try? Data(contentsOf: sessionsIndexPath) else {
            pruneDisabled = true
            sessionsIndexReadOnly = true
            addDataNotice("「最近场次」的索引 sessions.json 读不出来：" + stillThere + "，也不改写它（文件在 \(dataDir.path)）")
            return
        }
        guard let index = SessionsIndexFile.decode(data) else {
            pruneDisabled = true
            if let moved = SessionFiles.moveAside(sessionsIndexPath) {
                addDataNotice("「最近场次」的索引 sessions.json 解不开（被手改过或写坏了），原件已挪成 \(moved.lastPathComponent)：" +
                              stillThere + "（文件在 \(dataDir.path)）")
            } else {
                sessionsIndexReadOnly = true
                addDataNotice("「最近场次」的索引 sessions.json 解不开、也挪不开：" + stillThere + "，也不改写它（文件在 \(dataDir.path)）")
            }
            return
        }
        // 同样封顶 15：写入端一直在截断，读取端不截断的话，一个手改过的
        // sessions.json 就能让菜单无限长下去。
        recentSessions = Array(index.entries.prefix(15))
        sessionsIndexUnknown = index.unknown
        let recoverable = index.unknown.filter { $0.key != nil }.count
        if recoverable > 0 {
            addDataNotice("「最近场次」的索引 sessions.json 里有 \(recoverable) 条读不懂（可能被手改过），原样留在文件里：" +
                          "这几场不进菜单、预览也不清，从「选择文件夹…」重新打开那个文件夹就回来")
        }
        refreshSessionAvailability()
    }

    private func saveSessionsIndex() {
        guard !sessionsIndexReadOnly else { return }
        let index = SessionsIndexFile(entries: recentSessions, unknown: sessionsIndexUnknown)
        // 写不上只记日志：丢的是菜单里的一条，判决都在场次目录里（审查 S01）。
        if let data = try? index.encoded() { SessionFiles.writeLogged(data, to: sessionsIndexPath) }
    }

    /// 写之前重读一遍盘上的、按 key 合进来（审查 S02c）：GUI 开着时命令行 --analyze 登记的那一场，不被这次整份覆盖、
    /// 紧接着清掉预览。只在 touchSessionIndex 里合并（命令行那边是 registerSession 自己重读）：放进 saveSessionsIndex
    /// 的话，「移除」「全部清除」刚从内存里删掉的又会从盘上合并回来。
    private func mergeSessionsIndexFromDisk() {
        guard !sessionsIndexReadOnly, let data = try? Data(contentsOf: sessionsIndexPath),
              let disk = SessionsIndexFile.decode(data) else { return }
        for unknown in disk.unknown where !sessionsIndexUnknown.contains(unknown) {
            sessionsIndexUnknown.append(unknown)
        }
        let known = Set(recentSessions.map(\.key))
        let extra = disk.entries.filter { !known.contains($0.key) }
        guard !extra.isEmpty else { return }
        // 按最近一次打开 / 分析的时间排（内存里本来就是这个顺序；ISO 8601 的 UTC 时间按字符串比就对），一样的保持原顺序。
        let merged = (recentSessions + extra).enumerated().sorted { a, b in
            if a.element.lastAnalyzed != b.element.lastAnalyzed { return a.element.lastAnalyzed > b.element.lastAnalyzed }
            return a.offset < b.offset
        }
        recentSessions = merged.map(\.element)
    }

    private func touchSessionIndex() {
        guard let folder = photoDir, !currentSessionPath.isEmpty else { return }
        mergeSessionsIndexFromDisk()
        // The PINNED key/path from switchSession, never recomputed from the
        // resolved folder — see the comment there. `name` does follow the
        // resolved folder so a renamed shoot shows its new name in the menu.
        let key = currentSessionKey
        // 读不懂的那一条（如果是这一场的）被下面这条新的取代。
        sessionsIndexUnknown.removeAll { $0.key == key }
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

    /// 掉出最近 15 场的场次只清预览图 —— 一场大拍摄的预览几百 MB，别的地方不会去删它。
    /// 以前是整个 sessions/<key> 删掉：人工改判 (overrides.json)、阈值、XMP 记录、审到哪、
    /// 拼图工程、VLM 结果全跟着没了，一点提示都没有（第 16 场一分析，最早那场的选片就丢了）。
    /// 现在这些 KB 级的东西一律留着：菜单只是「最近」，不是「保留期限」；重新打开那个文件夹，
    /// 判决原样回来，点「重新分析」补回预览（分析结果没变的照片只重做预览，几秒钟）。
    /// `force`：「全部清除」（用户在确认框里点过，掉出菜单的只清预览写在确认框里），sessions.json 没读全也照样清。
    private func pruneOrphanedSessions(force: Bool = false) {
        guard force || !pruneDisabled else { return }
        // sessions.json 里读不懂、原样留着的那几条也算「还在」（审查 S02c）。
        let keep = Set(recentSessions.map(\.key)).union(sessionsIndexUnknown.compactMap(\.key))
        let root = dataDir.appendingPathComponent("sessions")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs
        where dir.hasDirectoryPath
            && dir.lastPathComponent != "default"
            && !keep.contains(dir.lastPathComponent) {
            Self.clearSessionCache(dir)
        }
    }

    /// 一场只清能重新生成的：预览图、拼图主体蒙版（进拼图 tab 会按需重算）。判决、客户选中、对时、拼图工程和方案
    /// 这些 KB 级的文件一律留着。掉出最近 15 场（上面）和「移除历史记录」（removeSession）都走这里。
    nonisolated private static func clearSessionCache(_ dir: URL) {
        let fm = FileManager.default
        for name in sessionCacheDirs {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        // 什么都没剩（只打开过、从没分析过的空场次）才连目录一起删。打开时就写下的 thresholds.json 不算。
        let left = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0 != "thresholds.json" }
        if left?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
    }

    /// 场次目录里能删、删了能重新生成的那几样（菜单上报的「能释放多少」只算它们）。
    nonisolated static let sessionCacheDirs = ["previews", "collage_masks"]

    /// 这一场的预览图被上面清掉了（判决还在）：网格会是一片灰，得说清楚怎么补回来。
    private var previewsPruned: Bool {
        guard let first = items.first else { return false }
        return !FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("previews").path)
            && !FileManager.default.fileExists(atPath: first.previewPath)
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
    /// 只算「移除历史记录」真会删的（预览图 + 拼图蒙版，sessionCacheDirs）：判决、拼图这些小文件移除时留着，
    /// 算进去菜单报的数就和实际释放的对不上。
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

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshSessionSizes() {
        let root = dataDir.appendingPathComponent("sessions")
        let keys = recentSessions.map(\.key)
        Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for key in keys {
                let dir = root.appendingPathComponent(key)
                sizes[key] = Self.sessionCacheDirs.reduce(Int64(0)) { $0 + Self.directorySize(dir.appendingPathComponent($1)) }
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

    /// 从菜单里拿掉一场，只清它能重新生成的缓存（预览图、拼图蒙版，和掉出最近 15 场一样走 clearSessionCache）。
    /// 人工改判、接受推荐、客户选中、确认表、机身对时、拼图工程和存着的方案都留着：重新打开这个文件夹就原样回来。
    /// 以前是整个 sessions/<key> 删掉，不确认、不进废纸篓（审查 S06）—— 想腾地方清掉一场已交付的，几周后客户回来
    /// 改相册才发现拼图、改判全没了。照片本身从来不碰。
    /// Removing the shoot that's currently open also clears the view — its
    /// previews are about to vanish, so leaving it on screen would show holes.
    func removeSession(_ entry: SessionEntry) {
        // 引擎正在往这个目录里写预览图时把目录删掉 = 分析中途报错。
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再移除历史记录"
            return
        }
        let isCurrent = photoDir != nil && currentSessionKey == entry.key
        // 移除当前这一场会清掉界面（内存里的判决跟着没了）：还有没存上的先拦住（审查 S01）。
        if isCurrent, !persistBeforeLeaving("移除这一场") { return }
        let freed = sessionSizes[entry.key]
        recentSessions.removeAll { $0.key == entry.key }
        saveSessionsIndex()
        if isCurrent {
            resetToNoSession()
        }
        Self.clearSessionCache(dataDir.appendingPathComponent("sessions/\(entry.key)"))
        refreshSessionAvailability(force: true)
        let size = freed.map { "（\(Self.sizeText($0))）" } ?? ""
        progressText = "已从列表移除「\(entry.name)」：清掉了预览图\(size)。判决、人工改判、客户选中、拼图和方案都还留着，" +
                       "重新打开这个文件夹就回来 (照片本身未动)"
    }

    /// Empty the menu and wipe the cached sessions it listed. Originals untouched —
    /// reopening a folder just means analyzing it again.
    func clearRecentSessions() {
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再清除历史记录"
            return
        }
        let count = recentSessions.count
        let listed = recentSessions.map(\.key)
        // 当前这一场不在要删的里面（没分析过、没进菜单）又有没存上的：照切场次一样先拦住。在里面的反正整份删掉。
        if photoDir != nil, !listed.contains(currentSessionKey), !persistBeforeLeaving("清除历史记录") { return }
        recentSessions = []
        // sessions.json 里读不懂、原样留着的那几条也一起清出索引（它们不在菜单里，场次目录照下面只清预览）。
        sessionsIndexUnknown = []
        saveSessionsIndex()
        resetToNoSession()
        // 用户在确认框里点过的「全部清除」：菜单里列着的这几场整份删，判决、人工改判、客户选中、拼图和方案一起
        // （确认框里一样样写着）。只想腾空间、判决留着的，用「移除历史记录」里的单场（removeSession）。
        // 掉出菜单的更早的场次确认框里没列，不能顺手把它们的判决也删了：只清预览（pruneOrphanedSessions，
        // 这时 keep 集是空的），判决这些 KB 级的小文件照旧留着。
        for key in listed {
            try? FileManager.default.removeItem(at: dataDir.appendingPathComponent("sessions/\(key)"))
        }
        pruneOrphanedSessions(force: true)
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
        acceptedIDs = []
        overrideUndoStack = []
        reasonFilter = nil
        borderlineFilter = false
        chapterFilter = nil
        clientPickFilter = false
        verdictFilter = nil
        lastError = nil
        // 走到这里的：没有挂着的（removeSession 先拦过），或者这一场刚被「全部清除」整份删掉 —— 没存上的也就不用存了。
        persistFailures = [:]
        updatePersistError()
        loadReviewPosition()
        loadThresholds()
        loadOverrides()
        loadAIOverrides()
        loadClientPicks()
        loadClientNotes()
        loadXMPState()
        loadBodyOffsets()
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

    /// 别的长任务（存储卡导入）共用顶栏的「取消」：换一面新旗子交出去。
    func freshCancelFlag() -> AnalysisEngine.CancelFlag {
        cancelFlag = AnalysisEngine.CancelFlag()
        return cancelFlag
    }

    // MARK: - Manual overrides

    private var overridesPath: URL { sessionDir.appendingPathComponent("overrides.json") }

    // MARK: 场次文件读坏了（审查 S02）

    /// 场次里的文件读坏了、已经挪开保住原件：批量页顶上一条橙色提醒，用户自己点掉才没（像 importNotice）。不放
    /// lastError：switchSession 读完这些文件以后会用「文件夹不存在」「预览已清理」改写它，分析也会清它。
    @Published var dataNotice: String?

    /// 场次里那几份整份重写的文件。
    enum PersistFile: CaseIterable {
        case overrides, clientPicks, bodyOffsets

        var label: String {
            switch self {
            case .overrides: return "判决"
            case .clientPicks: return "客户选中"
            case .bodyOffsets: return "机身对时"
            }
        }
    }

    /// 原件在、却读不出来（或者解不开又挪不开）的：这一场不写它 —— 拿内存里的空的去盖，原件就没了。重新打开这一场再读。
    private var persistRefused: Set<PersistFile> = []
    /// 这次打开这一场以后已经备份过（<名字>.bak）的文件。
    private var backedUpPaths: Set<String> = []

    /// 加一条读坏文件的提醒（几场、几个文件各有问题时攒着，最多 4 条）。
    func addDataNotice(_ text: String) {
        var lines = dataNotice.map { $0.components(separatedBy: "\n") } ?? []
        lines.append(text)
        dataNotice = lines.suffix(4).joined(separator: "\n")
    }

    /// 提醒里说是哪一场。
    private var sessionLabel: String { photoDir.map { "「\($0.lastPathComponent)」" } ?? "" }

    /// 读坏文件那条提醒的尾巴：在哪个目录、为什么先别写 XMP。
    private var corruptNoticeTail: String {
        "。先别写 XMP：现在是自动判决，写进去会盖掉 LR 里的星级（文件在 \(sessionDir.path)）"
    }

    private func refusePersist(_ file: PersistFile, _ text: String) {
        persistRefused.insert(file)
        addDataNotice(text)
    }

    /// 打开这一场以后第一次改写某个文件之前复制一份 .bak（照 LabelStore 的 backedUpSinceLoad）。
    private func backupOnce(_ url: URL) {
        guard !backedUpPaths.contains(url.path) else { return }
        if SessionFiles.backup(url) { backedUpPaths.insert(url.path) }
    }

    // MARK: 判决、客户选中、对时没存上（审查 S01）

    /// 判决、客户选中、机身对时写盘失败（现实里只有盘满）：批量页顶上一条常驻红条 + 「重试」，同一个文件下一次写成功
    /// 才消失。以前全是 try? 吞掉，界面、日志都没有；切场次时 loadOverrides 从盘上读，内存里没存上的改判当场就没了。
    /// 不放 lastError：切场次、分析都会清它。
    @Published private(set) var persistError: String?
    /// 没写成的文件 → 原因（CardImporter.describe）。每次都整份重写，所以下一次改判本身就是重试；另外红条上的
    /// 「重试」、切场次之前、退出（willTerminate）时都再写一遍。
    private var persistFailures: [PersistFile: String] = [:]
    private var persistTerminateObserver: NSObjectProtocol?

    /// 写这一份，顺手把之前没写成的也再写一遍。
    private func persist(_ file: PersistFile) {
        for f in PersistFile.allCases where f == file || persistFailures[f] != nil {
            attemptWrite(f)
        }
        updatePersistError()
    }

    private func attemptWrite(_ file: PersistFile) {
        // 原件读不出来、挪不开的（S02）：不写，免得拿内存里的空的盖掉它。
        guard !persistRefused.contains(file) else { return }
        do {
            // 场次目录被别的程序删了（访达里删、清理工具）：建回来再写，不然「文件不见了」永远重试不成、切不了场次。
            if !FileManager.default.fileExists(atPath: sessionDir.path) {
                try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            }
            switch file {
            case .overrides: try writeOverrides()
            case .clientPicks: try writeClientPicks()
            case .bodyOffsets: try writeBodyOffsets()
            }
            persistFailures[file] = nil
        } catch {
            let why = CardImporter.describe(error)
            persistFailures[file] = why
            SessionFiles.log.error("写\(file.label, privacy: .public)失败：\(why, privacy: .public)")
        }
    }

    /// 红条上的「重试」、切场次之前、退出时：没写成的再写一遍。true = 都存上了（本来就没有挂着的也是 true）。
    @discardableResult
    func retryPersist() -> Bool {
        for f in PersistFile.allCases where persistFailures[f] != nil {
            attemptWrite(f)
        }
        updatePersistError()
        return persistFailures.isEmpty
    }

    /// 离开这一场（切场次、移除当前这一场）之前：还有没存上的就再写一次，还写不上就拦住 —— 不然 switchSession 的
    /// loadOverrides 从盘上读，内存里没存上的改判当场就没了。
    private func persistBeforeLeaving(_ action: String) -> Bool {
        guard !persistFailures.isEmpty, !retryPersist() else { return true }
        lastError = "这一场还有改动没存上：先腾出磁盘空间、点顶上红条的「重试」，存上以后再\(action)"
        return false
    }

    private func updatePersistError() {
        let failed = PersistFile.allCases.filter { persistFailures[$0] != nil }
        guard !failed.isEmpty else {
            if persistError != nil { persistError = nil }
            return
        }
        let reasons = Set(failed.compactMap { persistFailures[$0] }).sorted().joined(separator: "、")
        let what = failed.map(\.label).joined(separator: "、")
        let text = "\(sessionLabel)的\(what)没存上（\(reasons)）：改动还在，但只在内存里。" +
                   "腾出磁盘空间后点「重试」；存上之前切不了场次，也先别退出"
        if persistError != text { persistError = text }
    }

    func setOverride(_ id: String, _ verdict: Verdict?) {
        setOverrideBatch([id], verdict)
    }

    /// ⌘Z 的一步：一次改判（每张原来的判决、原来是不是「接受推荐」钉的、原来是不是 AI 改的），或者一次导入 / 清除
    /// 客户选中（之前的整份）。两种放在同一条栈里：导入客户选择 → 改判 → ⌘Z ⌘Z 按时间倒着撤。
    private enum UndoStep {
        case verdicts([(id: String, previous: Verdict?, accepted: Bool, ai: AIOverride?)])
        case clientPicks(Set<String>)
        /// 一次导入带备注的客户回复 / 连备注一起清除：之前的整份客户选中和整份客户备注。
        case clientReply(picks: Set<String>, notes: [String: String])
        /// 按机身对时之前的整份偏移。
        case bodyOffsets([String: Int])
    }

    /// Undo stack for verdict overrides: one entry per user action, holding each
    /// touched id's PREVIOUS override (nil = was automatic). ⌘Z pops — a
    /// mis-keyed digit in tag-and-advance review mode costs one keystroke, not
    /// a hunt back through the filmstrip.
    @Published private var overrideUndoStack: [UndoStep] = []
    /// 真压进判决撤销栈的次数（改判、客户选中、对时都算）：只增不减，栈满丢掉最旧的也不回退。实时桥的 app_undo
    /// 拿它判断 AI 那一步之后用户又动过没有 —— 在 pushUndoStep 里数而不是 pushUndo(ids)：对时也压这条栈，
    /// 只数改判的话，用户对完时 AI 会把用户的对时当成自己那一步撤掉（§9.5.1 第二轮补）。
    private(set) var overrideUndoPushes = 0
    /// 判决撤销栈有几步（栈本身是私有的）。
    var overrideUndoDepth: Int { overrideUndoStack.count }

    var canUndoOverride: Bool { !overrideUndoStack.isEmpty }
    /// 上一步是对时（对时面板里的「撤销」只撤它，不去撤网格里的改判）。
    var canUndoBodyOffsets: Bool {
        if case .bodyOffsets = overrideUndoStack.last { return true }
        return false
    }

    /// 动手之前压一条撤销记录：每张原来的判决，和它原来是不是「接受推荐」钉的、是不是 AI 改的（⌘Z 连出处一起回去）。
    private func pushUndo(_ ids: some Collection<String>) {
        pushUndoStep(.verdicts(ids.map { ($0, overrides[$0], acceptedIDs.contains($0), aiOverrides[$0]) }))
    }

    private func pushUndoStep(_ step: UndoStep) {
        overrideUndoPushes += 1
        overrideUndoStack.append(step)
        if overrideUndoStack.count > 100 { overrideUndoStack.removeFirst() }
    }

    /// 返回这次撤销动到的照片 id —— 连拍挑选据此跳回出事的那一组。
    @discardableResult
    func undoLastOverride() -> [String] {
        guard let step = overrideUndoStack.popLast() else { return [] }
        guard case .verdicts(let last) = step else {
            if case .clientPicks(let previous) = step { return restoreClientPicks(previous) }
            if case .clientReply(let picks, let notes) = step { return restoreClientReply(picks: picks, notes: notes) }
            if case .bodyOffsets(let previous) = step { restoreBodyOffsets(previous) }
            return []
        }
        for (id, previous, accepted, ai) in last {
            if let previous {
                overrides[id] = previous
            } else {
                overrides.removeValue(forKey: id)
            }
            if accepted { acceptedIDs.insert(id) } else { acceptedIDs.remove(id) }
            aiOverrides[id] = ai
        }
        saveOverrides()
        saveAIOverrides()
        applyThresholds()
        return last.map(\.id)
    }

    /// Batch form (⌘-click multi-select): one save + one recompute for the lot.
    func setOverrideBatch(_ ids: some Collection<String>, _ verdict: Verdict?) {
        pushUndo(ids)
        for id in ids {
            acceptedIDs.remove(id)
            if let verdict {
                overrides[id] = verdict
            } else {
                overrides.removeValue(forKey: id)
            }
        }
        dropAIMarks(ids)
        saveOverrides()
        applyThresholds()
    }

    /// 实时桥（AI 的 cull_set_verdicts）改判：一组判决（nil = 恢复自动）一次写进去，一条撤销记录、一次保存、一次重算。
    /// 和 setOverrideBatch 一样算人工改判（判决钉住、✋），另外记下出处（aiOverrides → ai_overrides.json）；
    /// 恢复自动的那几张没有判决可记，出处一起拿掉。用户亲手改判走 setOverrideBatch，不走这里。
    func applyAIOverrides(_ changes: [(id: String, verdict: Verdict?)], opID: String, tool: String) {
        guard !changes.isEmpty else { return }
        pushUndo(changes.map(\.id))
        let now = Date()
        for (id, verdict) in changes {
            acceptedIDs.remove(id)
            guard let verdict else {
                overrides.removeValue(forKey: id)
                aiOverrides.removeValue(forKey: id)
                continue
            }
            // AI 改了好几次：previous 留 AI 第一次动它之前的（以后「撤销 AI 的全部改判」要回到那里）
            let first: String?
            if let mark = aiOverrides[id] { first = mark.previous } else { first = overrides[id]?.rawValue }
            overrides[id] = verdict
            aiOverrides[id] = AIOverride(opID: opID, tool: tool, at: now, previous: first, aiVerdict: verdict.rawValue)
        }
        saveOverrides()
        saveAIOverrides()
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
        pushUndo(all)
        for id in all {
            overrides[id] = keep.contains(id) ? keeperVerdict : .reject
            acceptedIDs.remove(id)
        }
        dropAIMarks(all)
        saveOverrides()
        applyThresholds()
    }

    /// 一组判决一次写进去：一条撤销记录、一次保存、一次重算。连拍挑选的 ⏎、分组行的
    /// 「接受推荐」/「只留这张」都走这里 —— 一组 8 张拆成 8 次 setOverride 的话，⌘Z 要按 8 下。
    /// `accepted`：分组行的「接受推荐」—— 原来是自动判的那几张记成「接受推荐」钉住的，不算人工改判
    /// （你亲手判过的照旧算你的）。
    func applyOverrides(_ changes: [String: Verdict], accepted: Bool = false) {
        guard !changes.isEmpty else { return }
        let ids = changes.keys.sorted()
        pushUndo(ids)
        for id in ids {
            if accepted, overrides[id] == nil || acceptedIDs.contains(id) {
                acceptedIDs.insert(id)
            } else {
                acceptedIDs.remove(id)
            }
            overrides[id] = changes[id]
        }
        dropAIMarks(ids)
        saveOverrides()
        applyThresholds()
    }

    /// 一场的「推荐结果」：现在的精选留（自动提名的或你按 1 的），你手动标过可用的留作可用，
    /// 其余废。连拍挑选的初始草稿和分组行的「接受推荐」是同一个结果（「全部接受推荐」判决上也一样，
    /// 只是它不给本来就废的照片补写人工判决）。
    func recommendedDecision(for members: [BatchItem]) -> [String: Verdict] {
        var decision: [String: Verdict] = [:]
        for m in members {
            if m.verdict == .pick {
                decision[m.id] = .pick
            } else if m.verdict == .usable, overrides[m.id] == .usable {
                decision[m.id] = .usable
            } else {
                decision[m.id] = .reject
            }
        }
        return decision
    }

    /// 一场的全部成员，按拍摄顺序。走 Derived 里分好的 takeRows（二分找到这一场）：连拍挑选和
    /// 分组行每次重绘都要问，每次对全部照片 filter + sort 就是之前从网格里清掉的那个坑。
    func members(ofTake take: Int) -> [BatchItem] {
        let rows = takeRows
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].take < take { lo = mid + 1 } else { hi = mid }
        }
        if lo < rows.count, rows[lo].take == take,
           rows[lo].indices.allSatisfy({ $0 < items.count && items[$0].take == take }) {
            return rows[lo].indices.map { items[$0] }
        }
        // 下标和 items 对不上（换了 items 还没重算的那一帧）就老老实实扫一遍。
        return items.filter { $0.take == take }.sorted { a, b in
            let ta = a.captureTime ?? .distantPast, tb = b.captureTime ?? .distantPast
            return ta != tb ? ta < tb : a.id < b.id
        }
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

    /// overrides.json 的格式不动（老版本照样读得懂），「接受推荐」的来源另存一份。
    private var acceptedPath: URL { sessionDir.appendingPathComponent("accepted.json") }

    /// 读这一场的改判。以前读不出、解不开都直接 return（和「没有这个文件」一条路），之后随便改一张，saveOverrides
    /// 就拿内存里那几条把原文件整份盖掉，accepted.json 也被 isEmpty 那支删掉（审查 S02）。
    private func loadOverrides() {
        persistRefused.remove(.overrides)
        backedUpPaths.subtract([overridesPath.path, acceptedPath.path])
        let stamp = SessionFiles.timestamp()
        switch SessionFiles.read([String: String].self, at: overridesPath, stamp: stamp) {
        case .missing:
            return
        case .ok(let raw):
            overrides = raw.compactMapValues(Verdict.init(rawValue:))
        case .corrupt(let moved?):
            // accepted.json 只对得上原来那份判决：一起挪开（同一个时间，好配对），别让下一次保存把它删掉。
            var aside = ""
            if FileManager.default.fileExists(atPath: acceptedPath.path) {
                guard let acceptedMoved = SessionFiles.moveAside(acceptedPath, stamp: stamp) else {
                    refusePersist(.overrides, "\(sessionLabel)的人工改判文件 overrides.json 解不开，原件已挪成 \(moved.lastPathComponent)；" +
                                  "accepted.json 挪不开，为免覆盖，这一场的改判先不存盘" + corruptNoticeTail)
                    return
                }
                aside = "（accepted.json 一起挪成 \(acceptedMoved.lastPathComponent)）"
            }
            addDataNotice("\(sessionLabel)的人工改判文件 overrides.json 解不开（被手改过或写坏了），原件已挪成 " +
                          "\(moved.lastPathComponent)\(aside)，这一场的判决先按自动的显示" + corruptNoticeTail)
            return
        case .corrupt(nil):
            refusePersist(.overrides, "\(sessionLabel)的人工改判文件 overrides.json 解不开、也挪不开，为免覆盖，这一场的改判先不存盘" +
                          "（修好或移走这个文件后重新打开这一场）" + corruptNoticeTail)
            return
        case .unreadable(let why):
            refusePersist(.overrides, "\(sessionLabel)的人工改判文件 overrides.json 读不出来（\(why)），为免覆盖，这一场的改判先不存盘" +
                          "（重新打开这一场再读一次）" + corruptNoticeTail)
            return
        }
        switch SessionFiles.read([String].self, at: acceptedPath, stamp: stamp) {
        case .missing:
            break
        case .ok(let accepted):
            acceptedIDs = Set(accepted).filter { overrides[$0] != nil }
        case .corrupt(let moved?):
            addDataNotice("\(sessionLabel)的 accepted.json 解不开，原件已挪成 \(moved.lastPathComponent)：" +
                          "「接受推荐」钉住的那几张这回算成人工改判（判决本身没变）")
        case .corrupt(nil), .unreadable:
            refusePersist(.overrides, "\(sessionLabel)的 accepted.json 读不出来、也挪不开，为免覆盖，这一场的改判先不存盘" +
                          "（修好或移走这个文件后重新打开这一场）")
        }
    }

    private func saveOverrides() { persist(.overrides) }

    private func writeOverrides() throws {
        let data = try JSONEncoder().encode(overrides.mapValues(\.rawValue))
        backupOnce(overridesPath)
        // .atomic: a crash mid-write here used to cost every manual verdict
        // of the shoot.
        try data.write(to: overridesPath, options: .atomic)
        if acceptedIDs.isEmpty {
            guard FileManager.default.fileExists(atPath: acceptedPath.path) else { return }
            backupOnce(acceptedPath)
            try SessionFiles.remove(acceptedPath)
        } else {
            let accepted = try JSONEncoder().encode(acceptedIDs.sorted())
            backupOnce(acceptedPath)
            try accepted.write(to: acceptedPath, options: .atomic)
        }
    }

    /// AI 改判的出处也另存一份（和 accepted.json 一样挨着 overrides.json，overrides.json 的格式不动）：
    /// {id: {op_id, tool, at, previous, ai_verdict}}，老版本 app 不认它也不碍事。
    private var aiOverridesPath: URL { sessionDir.appendingPathComponent("ai_overrides.json") }

    /// 在 loadOverrides 之后调。只留现在判决还等于 AI 判的、也不是「接受推荐」钉的：老版本 app 打开过这一场、改了判决又
    /// 不维护这份文件，对不上的就丢掉（比 accepted.json 只看「在不在」严）。
    private func loadAIOverrides() {
        aiOverrides = [:]
        guard let data = try? Data(contentsOf: aiOverridesPath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode([String: AIOverride].self, from: data) else { return }
        aiOverrides = raw.filter { id, mark in overrides[id]?.rawValue == mark.aiVerdict && !acceptedIDs.contains(id) }
    }

    private func saveAIOverrides() {
        guard !aiOverrides.isEmpty else {
            try? FileManager.default.removeItem(at: aiOverridesPath)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(aiOverrides) {
            try? data.write(to: aiOverridesPath, options: .atomic)
        }
    }

    /// 你亲手动过的这几张不再算 AI 改的（改判、定案、接受推荐、移进废纸篓都走这里）；真拿掉了才写文件。
    private func dropAIMarks(_ ids: some Collection<String>) {
        var dropped = false
        for id in ids where aiOverrides.removeValue(forKey: id) != nil { dropped = true }
        if dropped { saveAIOverrides() }
    }

    // MARK: - 客户选中（client_picks.json）

    private var clientPicksPath: URL { sessionDir.appendingPathComponent("client_picks.json") }

    private func loadClientPicks() {
        persistRefused.remove(.clientPicks)
        backedUpPaths.remove(clientPicksPath.path)
        var loaded: [String] = []
        defer { clientPicks = Set(loaded) }
        switch SessionFiles.read([String].self, at: clientPicksPath) {
        case .missing:
            break
        case .ok(let ids):
            loaded = ids
        case .corrupt(let moved?):
            addDataNotice("\(sessionLabel)的客户选中 client_picks.json 解不开（被手改过或写坏了），原件已挪成 " +
                          "\(moved.lastPathComponent)，这一场先当没有客户选中" + corruptNoticeTail)
        case .corrupt(nil):
            refusePersist(.clientPicks, "\(sessionLabel)的客户选中 client_picks.json 解不开、也挪不开，为免覆盖，这一场的客户选中先不存盘" +
                          "（修好或移走这个文件后重新打开这一场）")
        case .unreadable(let why):
            refusePersist(.clientPicks, "\(sessionLabel)的客户选中 client_picks.json 读不出来（\(why)），为免覆盖，这一场的客户选中先不存盘" +
                          "（重新打开这一场再读一次）")
        }
    }

    private func saveClientPicks() { persist(.clientPicks) }

    private func writeClientPicks() throws {
        backupOnce(clientPicksPath)
        if clientPicks.isEmpty {
            try SessionFiles.remove(clientPicksPath)
        } else {
            try JSONEncoder().encode(clientPicks.sorted()).write(to: clientPicksPath, options: .atomic)
        }
    }

    /// 换成这一份客户选中（导入 = 加上去，清除 = 空集）：一条撤销记录、一次保存，再重算一遍
    /// （客户选中数、「XMP 过期」都在 Derived 里；判决不受影响）。和原来一样就什么都不做。
    func setClientPicks(_ picks: Set<String>) {
        guard picks != clientPicks else { return }
        pushUndoStep(.clientPicks(clientPicks))
        clientPicks = picks
        saveClientPicks()
        applyThresholds()
    }

    /// ⌘Z 撤回一次导入 / 清除。返回这次变了的照片（按网格顺序）。
    private func restoreClientPicks(_ previous: Set<String>) -> [String] {
        let touched = clientPicks.symmetricDifference(previous)
        clientPicks = previous
        saveClientPicks()
        applyThresholds()
        return items.map(\.id).filter(touched.contains)
    }

    // MARK: - 客户备注（client_notes.json）

    private var clientNotesPath: URL { sessionDir.appendingPathComponent("client_notes.json") }

    private func loadClientNotes() {
        clientNotes = (try? Data(contentsOf: clientNotesPath))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func saveClientNotes() {
        if clientNotes.isEmpty {
            try? FileManager.default.removeItem(at: clientNotesPath)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            try encoder.encode(clientNotes).write(to: clientNotesPath, options: .atomic)
        } catch {
            lastError = "客户备注没存上: \(error.localizedDescription)"
        }
    }

    /// 客户选中和客户备注一起换（导入带备注的回复；清除客户选中时备注一起清）：一条撤销记录，⌘Z 两样一起回去。
    func setClientReply(picks: Set<String>, notes: [String: String]) {
        guard picks != clientPicks || notes != clientNotes else { return }
        pushUndoStep(.clientReply(picks: clientPicks, notes: clientNotes))
        clientPicks = picks
        clientNotes = notes
        saveClientPicks()
        saveClientNotes()
        applyThresholds()
    }

    /// ⌘Z 撤回一次带备注的导入 / 清除：选中变了的、备注变了的都算动到（按网格顺序）。
    private func restoreClientReply(picks: Set<String>, notes: [String: String]) -> [String] {
        let renoted = Set(clientNotes.keys).union(notes.keys).filter { clientNotes[$0] != notes[$0] }
        clientNotes = notes
        saveClientNotes()
        let touched = Set(restoreClientPicks(picks)).union(renoted)
        return items.map(\.id).filter(touched.contains)
    }

    /// Canonical display order for reject-reason chips and slider kill-counts.
    static let reasonOrder = ["文件损坏", "连拍重复", "闭眼", "虚焦", "曝光裁切", "欠曝", "过曝", "人脸质量低", "VLM建议淘汰"]

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
        Self.applyBodyClock(&updated, offsets: bodyOffsets)
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
            worstClipPct: max(a.subjectHighlightClipPct, a.subjectShadowClipPct),
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
            camera: a.cameraModel,
            bodySerial: a.bodySerial,
            fileCorrupt: a.fileCorrupt,
            faceLuma: a.faceLuma,
            frameLuma: a.frameLuma,
            frameLumaP99: a.frameLumaP99,
            captureSubsec: a.captureSubsec
        )
    }

    func runAnalysis() {
        guard let dir = photoDir else { return }
        guard !isRunning else { return }
        isRunning = true
        analyzing = true
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
                    self.analyzing = false
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
                    // 拆开拼：一长串插值 + 三元在 CI 的 Xcode 16 上类型检查会慢。
                    func names(_ ids: [String]) -> String {
                        ids.prefix(5).joined(separator: ", ") + (ids.count > 5 ? "..." : "")
                    }
                    var problems: [String] = []
                    if !summary.failed.isEmpty {
                        problems.append("\(summary.failed.count) 张无法解析被跳过 (文件损坏或仍在拷贝中): " + names(summary.failed))
                    }
                    // 坏文件照样在网格里（看得到缺的那截），判废片；要紧的是别把卡格式化了。
                    if !summary.corrupt.isEmpty {
                        problems.append("\(summary.corrupt.count) 张文件损坏 (不完整，可能读卡出错或拷贝中断)，已判废片: "
                                        + names(summary.corrupt) + " —— 卡先别格式化，从卡上重新拷一次")
                    }
                    if !problems.isEmpty { self.lastError = problems.joined(separator: "；") }
                }
                self.isRunning = false
                self.analyzing = false
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
        // 文件损坏的不送：VLM 只能平反闭眼 / 虚焦 / 曝光（裁切、欠曝、过曝），坏文件送去也平反不了，白跑。
        let accused = items.filter { $0.verdict == .reject && overrides[$0.id] == nil
            && !$0.rejectReasons.isEmpty && !$0.fileCorrupt }
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
                let reasons = Dictionary(uniqueKeysWithValues: accused.map { ($0.id, Self.appealCharges($0)) })
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
                worstClipPct: max(l1.subjectHighlightClipPct ?? l1.highlightClipPct ?? 0,
                                  l1.subjectShadowClipPct ?? l1.shadowClipPct ?? 0),
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
            item.bodySerial = photo.bodySerial
            item.fileCorrupt = l1.fileCorrupt ?? false
            item.faceLuma = l1.faceLuma
            item.frameLuma = l1.frameLuma
            item.frameLumaP99 = l1.frameLumaP99
            item.captureSubsec = l1.captureSubsec
            return item
        }
        Self.applyBodyClock(&loaded, offsets: bodyOffsets)
        Self.assignChapters(&loaded)
        Self.assignTakes(&loaded, gapSec: takeGapSec)
        Self.sort(&loaded, by: sortOrder)
        items = loaded
        unparsedCount = manifest.photos.count - loaded.count
        rebuildGroupSizes()
        backfillBodySerials(manifest.photos)
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
        // 按机身分桶：双机位同一秒的两张是两个角度，不是重复。同型号的两台靠序列号分开（BatchItem.body）。
        let byCamera = Dictionary(grouping: array.indices.filter { array[$0].captureTime != nil },
                                  by: { array[$0].body })
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

    // MARK: - 机身（双机位）与按机身对时

    /// 每张的机身 key（CameraBody.keys，按这一场全部照片一起算）+ 这台机身的对时偏移。
    /// captureTime 里原来带着的偏移先减掉再加新的：重复调用、换偏移都不会越加越多。
    static func applyBodyClock(_ array: inout [BatchItem], offsets: [String: Int]) {
        let keys = CameraBody.keys(models: array.map(\.camera), serials: array.map(\.bodySerial))
        let slots = offsets.isEmpty ? [:] : bodyOffsetSlots(array, keys: keys, stored: offsets)
        for i in array.indices {
            array[i].body = keys[i]
            let offset = slots[keys[i]]?.seconds ?? 0
            guard offset != array[i].clockOffset else { continue }
            array[i].captureTime = array[i].captureTime?.addingTimeInterval(Double(offset - array[i].clockOffset))
            array[i].clockOffset = offset
        }
    }

    /// 一台机身的偏移在 body_offsets.json 里存在哪、现在用的是多少。
    struct BodyOffsetSlot {
        /// 改偏移时写到这个 key 下：读得到序列号就是「型号 #序列号」（和这一场有几台同型号无关），读不到就是型号。
        let home: String
        let seconds: Int
        /// 这次是从哪个 key 读到的（nil = 没对过）。和 home 不同 = 借的纯型号那条。
        let source: String?
    }

    /// 机身 key → 偏移存在哪、用多少。机身 key 会跟着这一场的照片变：老场次补上序列号、或者后来又拷进
    /// 一台同型号的，两台才分开（「X-T50」→「X-T50 #5B008966」「X-T50 #SECOND-BODY-0002」）；同型号一台的
    /// 照片全进了废纸篓，剩下那台又退回「X-T50」。所以存的时候只要有序列号就带上，查的时候自己名下没有，
    /// 再认没读到序列号时存的纯型号（那时两台算一台，对的就是两台一起）—— 对过的时不会因为 key 变了悄悄丢掉。
    static func bodyOffsetSlots(_ array: [BatchItem], keys: [String], stored: [String: Int]) -> [String: BodyOffsetSlot] {
        var model: [String: String] = [:]
        var serial: [String: String] = [:]
        for (item, key) in zip(array, keys) {
            model[key] = item.camera ?? ""
            if let s = item.bodySerial, !s.isEmpty { serial[key] = s }
        }
        var slots: [String: BodyOffsetSlot] = [:]
        for (key, m) in model {
            let home = serial[key].map { "\(m) #\($0)" } ?? key
            var sources = [home]
            // 纯型号那条归这台：它自己就叫纯型号，或者这一场没有叫纯型号的机身（没序列号的那几张）。
            if home != m && (key == m || model[m] == nil) { sources.append(m) }
            let source = sources.first { stored[$0] != nil }
            slots[key] = BodyOffsetSlot(home: home, seconds: source.flatMap { stored[$0] } ?? 0, source: source)
        }
        return slots
    }

    /// 状态栏「N 台机身」和对时面板里的一行。
    struct BodyInfo: Identifiable {
        let key: String
        let name: String
        let count: Int
        /// 对时之后的第一张 / 最后一张（没有拍摄时间的不算）。
        let first: Date?
        let last: Date?
        let offset: Int
        let slot: BodyOffsetSlot
        var id: String { key }
    }

    /// 这一场的机身，照片多的在前（第一台当主机位：「对成同一时刻」以它为准）。没有型号的不算一台。
    private(set) var bodies: [BodyInfo] = []

    private static func bodySummary(_ items: [BatchItem], offsets: [String: Int]) -> [BodyInfo] {
        let byBody = Dictionary(grouping: items.filter { !$0.body.isEmpty }, by: \.body)
        let names = CameraBody.displayNames(byBody.map { key, members in
            let model = members[0].camera ?? ""
            return (key, model, key == model ? "" : members[0].bodySerial ?? "")
        })
        let slots = bodyOffsetSlots(items, keys: items.map(\.body), stored: offsets)
        let infos = byBody.map { key, members -> BodyInfo in
            let times = members.compactMap(\.captureTime)
            let slot = slots[key] ?? BodyOffsetSlot(home: key, seconds: 0, source: nil)
            return BodyInfo(key: key, name: names[key] ?? key, count: members.count,
                            first: times.min(), last: times.max(), offset: slot.seconds, slot: slot)
        }
        return infos.sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    /// 按机身对时（body_offsets.json：机身 → 秒，key 见 BodyOffsetSlot.home）。没对过 = 空，文件也不写。
    private(set) var bodyOffsets: [String: Int] = [:]
    private var bodyOffsetsPath: URL { sessionDir.appendingPathComponent("body_offsets.json") }

    private func loadBodyOffsets() {
        persistRefused.remove(.bodyOffsets)
        backedUpPaths.remove(bodyOffsetsPath.path)
        var stored: [String: Int] = [:]
        switch SessionFiles.read([String: Int].self, at: bodyOffsetsPath) {
        case .missing:
            break
        case .ok(let offsets):
            stored = offsets
        case .corrupt(let moved?):
            addDataNotice("\(sessionLabel)的机身对时 body_offsets.json 解不开（被手改过或写坏了），原件已挪成 " +
                          "\(moved.lastPathComponent)，这一场先按没对过时显示（章节、拍摄顺序可能和上次不一样）")
        case .corrupt(nil):
            refusePersist(.bodyOffsets, "\(sessionLabel)的机身对时 body_offsets.json 解不开、也挪不开，为免覆盖，这一场的对时先不存盘" +
                          "（修好或移走这个文件后重新打开这一场）")
        case .unreadable(let why):
            refusePersist(.bodyOffsets, "\(sessionLabel)的机身对时 body_offsets.json 读不出来（\(why)），为免覆盖，这一场的对时先不存盘" +
                          "（重新打开这一场再读一次）")
        }
        // 手改坏的、超过 ±48 小时的不认（不用 abs：Int.min 取绝对值会崩）。
        let allowed = -BodyClock.maxOffset...BodyClock.maxOffset
        bodyOffsets = stored.filter { allowed.contains($0.value) }
    }

    private func saveBodyOffsets() { persist(.bodyOffsets) }

    private func writeBodyOffsets() throws {
        backupOnce(bodyOffsetsPath)
        if bodyOffsets.isEmpty {
            try SessionFiles.remove(bodyOffsetsPath)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bodyOffsets).write(to: bodyOffsetsPath, options: .atomic)
    }

    /// 改对时偏移（机身 key → 秒，一台或几台一起）：一条撤销记录、一次保存，然后整场重排时间。
    /// 0 = 去掉这台的偏移。和现在一样的不算改（面板里什么都没改按「完成」不留撤销记录）。
    func setBodyOffsets(_ changes: [String: Int]) {
        let byKey = Dictionary(uniqueKeysWithValues: bodies.map { ($0.key, $0) })
        let effective = changes.filter { key, seconds in (byKey[key]?.offset ?? 0) != seconds }
        guard !effective.isEmpty else { return }
        var next = bodyOffsets
        // 借纯型号那条的先改存到自己名下：不然把这台改成 0（删掉这一条）又会借回纯型号的偏移。
        for body in bodies {
            guard let source = body.slot.source, source != body.slot.home else { continue }
            next[source] = nil
            next[body.slot.home] = body.offset
        }
        for (key, seconds) in effective { next[byKey[key]?.slot.home ?? key] = seconds == 0 ? nil : seconds }
        guard next != bodyOffsets else { return }
        pushUndoStep(.bodyOffsets(bodyOffsets))
        restoreBodyOffsets(next)
    }

    private func restoreBodyOffsets(_ offsets: [String: Int]) {
        bodyOffsets = offsets
        saveBodyOffsets()
        // 章节号可能整体挪了：留着「只看第 3 章」会悄悄换成另一章。
        chapterFilter = nil
        reflowCaptureTimes(items)
    }

    /// 机身 key 或对时偏移变了：重算拍摄时间，章节、场、排序、时间轴跟着重来。判决规则不看时间，
    /// 但精选提名按场 —— 场变了提名跟着变，所以要重判一遍。
    private func reflowCaptureTimes(_ array: [BatchItem]) {
        var updated = array
        Self.applyBodyClock(&updated, offsets: bodyOffsets)
        Self.assignChapters(&updated)
        Self.assignTakes(&updated, gapSec: takeGapSec)
        Self.sort(&updated, by: sortOrder)
        items = updated
        rebuildGroupSizes()
        applyThresholds()
    }

    /// 「把这两张对成同一时刻」：两台机身同一瞬间各拍的一张（同一次闪光、同一个动作）。以 bodies 里
    /// 排在前面的（照片多的）为准，算出另一台的新偏移。同一台、没有型号、没有拍摄时间的、
    /// 算出来超过 ±48 小时的（BodyClock.maxOffset，多半选错了照片）= nil。
    func alignment(_ a: String, _ b: String) -> (reference: BodyInfo, moved: BodyInfo, offset: Int)? {
        guard let x = item(withID: a), let y = item(withID: b), x.body != y.body,
              let rx = bodies.firstIndex(where: { $0.key == x.body }),
              let ry = bodies.firstIndex(where: { $0.key == y.body }) else { return nil }
        let (ref, moved) = rx < ry ? (x, y) : (y, x)
        guard let tRef = ref.captureTime, let tMoved = moved.captureTime else { return nil }
        // 先用 Double 算、卡住范围再转 Int：转换本身不会溢出。
        let offset = Double(moved.clockOffset) + tRef.timeIntervalSince(tMoved).rounded()
        guard abs(offset) <= Double(BodyClock.maxOffset) else { return nil }
        return (bodies[min(rx, ry)], bodies[max(rx, ry)], Int(offset))
    }

    /// 正在后台补序列号的场次（同一场别重复起）。
    private var serialBackfillSession: URL?

    /// 这一版之前分析的场次，manifest 里没有机身序列号：照片文件夹还在的话只读文件头补上（不解码、
    /// 不重新分析），写回 manifest，下次打开不用再读。补出同型号两台机身才重新分场、排序；单机身、
    /// 不同型号的补完 key 还是型号，什么都不动。界面上在后台读（3000 张 RAW 在移动硬盘上要好几秒），
    /// 无头模式读完再往下走，输出才确定。
    private func backfillBodySerials(_ photos: [Photo]) {
        let missing = photos.filter { $0.bodySerial == nil }.map { (id: $0.id, path: $0.decodePath ?? $0.rawPath) }
        guard !missing.isEmpty, serialBackfillSession != sessionDir,
              let dir = photoDir, FileManager.default.fileExists(atPath: dir.path) else { return }
        let target = sessionDir
        serialBackfillSession = target
        if AppRuntime.headless {
            finishSerialBackfill(Self.readBodySerials(missing), sessionDir: target)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let found = Self.readBodySerials(missing)
            await MainActor.run { [weak self] in self?.finishSerialBackfill(found, sessionDir: target) }
        }
    }

    /// id → 序列号（"" = 读得了、没有；文件读不了的不在结果里，下次打开再补）。
    nonisolated private static func readBodySerials(_ photos: [(id: String, path: String)]) -> [String: String] {
        var serials = [String?](repeating: nil, count: photos.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: photos.count) { i in
            let serial = ImageLoader.bodySerial(of: URL(fileURLWithPath: photos[i].path))
            lock.lock(); serials[i] = serial; lock.unlock()
        }
        var found: [String: String] = [:]
        for (i, photo) in photos.enumerated() { if let s = serials[i] { found[photo.id] = s } }
        return found
    }

    private func finishSerialBackfill(_ found: [String: String], sessionDir target: URL) {
        if serialBackfillSession == target { serialBackfillSession = nil }
        // 读的时候换了场次，或者开始重新分析了（引擎自己会补、会重写 manifest）：这份作废。
        guard target == sessionDir, !isRunning, !found.isEmpty else { return }
        let url = target.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: url),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let photos = json["photos"] as? [[String: Any]] {
            json["photos"] = photos.map { entry -> [String: Any] in
                guard entry["body_serial"] == nil, let id = entry["id"] as? String, let serial = found[id] else { return entry }
                var entry = entry
                entry["body_serial"] = serial
                return entry
            }
            if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: url, options: .atomic)
            }
        }
        var updated = items
        for i in updated.indices {
            if let serial = found[updated[i].id] { updated[i].bodySerial = serial }
        }
        let keys = CameraBody.keys(models: updated.map(\.camera), serials: updated.map(\.bodySerial))
        guard keys != items.map(\.body) else { return }
        reflowCaptureTimes(updated)
    }

    /// Recomputed on every status-bar render — DateFormatter construction is
    /// milliseconds-expensive, so it must not happen per call.
    /// 固定格式必须钉 en_US_POSIX：系统偏好 12 小时制时 "HH" 会变成「下午5」，时间轴上
    /// 一段写成「上午8:32-下午5:08」，又长又被截断。
    static let chapterTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 时间轴上这张照片算哪一段。没有拍摄时间的照片在数据上归章节 0（assignChapters
    /// 不给它们造假章节），可网格把它们排在最后 —— 时间轴上也单独一段放最后，
    /// 别让它们混进第一章的张数和时间里。
    static func timelineChapter(of item: BatchItem) -> Int {
        item.captureTime == nil ? ChapterSegment.undatedID : item.chapter
    }

    /// One timeline segment per chapter: size + verdict makeup + time range.
    /// Backs the clickable chapter bar above the grid (empty unless the shoot
    /// actually has 2+ chapters).
    struct ChapterSegment: Identifiable, Equatable {
        /// 没有拍摄时间的那一段的编号（排在最后）。
        static let undatedID = -1

        let chapter: Int
        let count: Int
        let pick: Int
        let usable: Int
        let reject: Int
        /// 这一章第一张 / 最后一张的拍摄时间（无时间那段为 nil）。
        let start: Date?
        let end: Date?
        let timeRange: String
        /// 留下的张数低于「每章节最少保留」。和 allRejected 分开：那个驱动时间轴
        /// 上的红色"全灭"块，这个只是橙色提醒。
        let underMin: Bool
        /// 这一章里还没定的连拍场数（定义同 isPendingTake）。
        let pendingTakes: Int
        /// 悬停卡片上的代表照片（预览路径，最多 4 张）：精选优先、再可用，各自按评分 —— 和照片 App
        /// 按日期分组时给的那几张缩略图一样，一眼认出是仪式还是晚宴。
        let covers: [String]
        var id: Int { chapter }
        var allRejected: Bool { pick + usable == 0 }
        var undated: Bool { chapter == Self.undatedID }
    }

    private static func coverRank(_ v: Verdict) -> Int {
        switch v {
        case .pick: return 2
        case .usable: return 1
        case .reject: return 0
        }
    }

    /// Segments plus the all-rejected warnings in one pass (they used to be two
    /// computed properties doing the same grouping on every render). Warnings:
    /// chapters where culling left NOTHING — losing a whole scene is a delivery
    /// accident, a few extra keepers is just waste.
    private static func chapterSummary(_ items: [BatchItem], minKeepers: Int,
                                       pendingByChapter: [Int: Int]) -> ([ChapterSegment], [String]) {
        var byChapter: [Int: [BatchItem]] = [:]
        for item in items { byChapter[timelineChapter(of: item), default: []].append(item) }
        guard byChapter.count > 1 else { return ([], []) }
        var segments: [ChapterSegment] = []
        var warnings: [String] = []
        // 有时间的章节按编号（= 时间顺序），无时间那段（-1）放最后。
        let order = byChapter.keys.sorted { a, b in
            if (a == ChapterSegment.undatedID) != (b == ChapterSegment.undatedID) { return b == ChapterSegment.undatedID }
            return a < b
        }
        for chapter in order {
            let members = byChapter[chapter]!
            let times = members.compactMap(\.captureTime)
            let start = times.min(), end = times.max()
            let range = start.map { "\(chapterTimeFormatter.string(from: $0))-\(chapterTimeFormatter.string(from: end!))" } ?? ""
            var pick = 0, usable = 0, reject = 0
            // 代表照片：线性挑前 4（每次滑杆都会重算，别为它整章排序）。
            var top: [BatchItem] = []
            func better(_ a: BatchItem, _ b: BatchItem) -> Bool {
                let ra = coverRank(a.verdict), rb = coverRank(b.verdict)
                return ra != rb ? ra > rb : scoreKey(a) > scoreKey(b)
            }
            for member in members {
                switch member.verdict {
                case .pick: pick += 1
                case .usable: usable += 1
                case .reject: reject += 1
                }
                // 每场最多一张：前 4 名很可能是同一个连拍的 4 帧，那样卡片上四张长得一样。
                if let same = top.firstIndex(where: { $0.take == member.take }) {
                    guard better(member, top[same]) else { continue }
                    top.remove(at: same)
                } else if top.count >= 4, !better(member, top[top.count - 1]) {
                    continue
                }
                let at = top.firstIndex { better(member, $0) } ?? top.count
                top.insert(member, at: at)
                if top.count > 4 { top.removeLast() }
            }
            let keepers = pick + usable
            let undated = chapter == ChapterSegment.undatedID
            let segment = ChapterSegment(chapter: chapter, count: members.count,
                                         pick: pick, usable: usable, reject: reject,
                                         start: start, end: end, timeRange: range,
                                         // 无时间的那堆不是一个场景，「整章全灭」的漏交保护不适用。
                                         underMin: !undated && keepers > 0 && keepers < minKeepers,
                                         pendingTakes: pendingByChapter[chapter] ?? 0,
                                         covers: top.map(\.previewPath))
            segments.append(segment)
            guard !undated else { continue }
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
    /// WeChat as one file. Preview JPEGs are embedded base64 (re-encoded at 800px/q0.72).
    /// 客户在页面上点选、「复制我的选择」发回文件名清单（见 ProofSheetPage）；这次导出的照片顺序
    /// 记进 proof_sheets.json，客户只回编号时按对的那张表认。`ids` 给定时只导这几张（选中的照片，
    /// 大场次分批发），否则按判决选。`quota` = 套餐张数（页面上「已选 12 / 30 张」，选超了只提示；nil = 不限），
    /// 跟着这张表记下来，导入客户选择时说超没超。`watermark` = 每张小样上画的角标（水印页的签名 / 文字，主线程拍好的
    /// 快照）；nil = 不画，和以前一模一样。水印只画在内存里那张 800px 上，预览文件不动。
    func exportContactSheet(to url: URL, includeUsable: Bool, ids: [String]? = nil, quota: Int? = nil,
                            watermark: ProofWatermark? = nil) {
        guard !isRunning else { return }
        let wanted = ids.map(Set.init)
        let chosen = items.filter { item in
            if let wanted { return wanted.contains(item.id) }
            return item.verdict == .pick || (includeUsable && item.verdict == .usable)
        }.map { (id: $0.id, previewPath: $0.previewPath, pick: $0.verdict == .pick, original: $0.decodePath) }
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
        let scope = ids != nil ? "选中的照片" : (includeUsable ? "精选 + 可用" : "仅精选")
        let sheetID = ProofSheet.newID()

        // Off the main thread: reading + base64-encoding hundreds of ~190KB
        // previews took seconds of beachball. The 1024px previews are
        // re-encoded at 800px/q0.72 so a 300-photo sheet stays WeChat-sized.
        Task.detached(priority: .userInitiated) { [weak self] in
            var cells = ""
            // 真正放进表里的（预览读不出来的跳过）：编号 #n 就是这里的第 n 张，记进 proof_sheets.json。
            var shown: [String] = []
            for (index, item) in chosen.enumerated() {
                if flag.isSet { break }
                guard let data = Self.contactSheetJPEG(path: item.previewPath, watermark: watermark,
                                                       original: item.original) else { continue }
                shown.append(item.id)
                cells += ProofSheetPage.cell(number: shown.count, id: item.id, pick: item.pick, jpeg: data)
                let done = index + 1
                if done % 20 == 0 || done == total {
                    await MainActor.run { [weak self] in
                        self?.progressText = "生成选片确认表 \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            }
            let dateString = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
            let html = ProofSheetPage.html(title: title, sheetID: sheetID, count: shown.count,
                                           date: dateString, cells: cells, quota: quota)
            let cancelled = flag.isSet
            var writeError: String?
            if !cancelled {
                do { try html.write(to: url, atomically: true, encoding: .utf8) }
                catch { writeError = error.localizedDescription }
            }
            let failure = writeError
            let bytes = Int64(html.utf8.count)
            let sheet = ProofSheet(id: sheetID, date: Date(), scope: scope, ids: shown,
                                   lists: ProofSheet.lists(quota: quota))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                if cancelled {
                    self.progressText = "已取消导出选片确认表"
                } else if let failure {
                    self.lastError = "联系表导出失败: \(failure)"
                } else {
                    self.recordProofSheet(sheet)
                    let marked = watermark == nil ? "" : "（带水印）"
                    self.progressText = "选片确认表已导出\(marked): \(sheet.ids.count) 张 · \(Self.sizeText(bytes)) → \(url.lastPathComponent)"
                    if bytes > ProofSheetPage.largeBytes { self.lastError = ProofSheetPage.largeNote(bytes) }
                    // 带水印时少了的（预览读不出来、水印画不上）说出来：不悄悄少几张。
                    if watermark != nil, sheet.ids.count < total {
                        let missing = "有 \(total - sheet.ids.count) 张没放进确认表（预览读不出来或水印画不上）"
                        self.lastError = [self.lastError, missing].compactMap { $0 }.joined(separator: "；")
                    }
                }
            }
        }
    }

    /// 确认表里的一张：预览缩到 800px、q0.72。`watermark` 给了就在这张内存里的小样上画（`original` = 原片，水印按它换算
    /// 边距、读 EXIF），画不上 = nil（这张不放，不放没水印的）；预览文件只读。
    nonisolated static func contactSheetJPEG(path: String, watermark: ProofWatermark? = nil, original: String = "") -> Data? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
              ] as CFDictionary) else { return nil }
        var cg = thumb
        if let watermark {
            guard let marked = watermark.apply(to: thumb, original: original) else { return nil }
            cg = marked
        }
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
    static let minEarFaceAreaPct = FaceAnalyzer.smallFaceAreaPct
    /// 合影小脸在原图分辨率上重量过 EAR 的（earFullRes），免检线放到 0.05%：4000 万像素的原图上
    /// 这么大的脸约 140px 见方，和 3072 分析图上 0.3% 的脸一样多像素（引擎那边按像素数把关）。
    static let minFullResEarFaceAreaPct = 0.0005

    /// 这张脸太小、眼睛读不准，闭眼判定跳过它。PickSession 的眯眼 / 最佳眼睛也用这一条。
    static func earImmune(_ face: FaceInfo) -> Bool {
        guard let area = face.areaPct else { return false }
        return area < (face.earFullRes == true ? minFullResEarFaceAreaPct : minEarFaceAreaPct)
    }
    /// Quality is judged group-relative too: suspect only when this far below
    /// the group's best FaceCaptureQuality (its designed use — ranking captures
    /// of the same subject). No global kill-line for grouped photos.
    static let qualityGroupGap = 0.15

    /// Photo-level EAR for group comparison: the WORST eye among faces big
    /// enough to judge. nil = no judgment possible (legacy data without raw
    /// EARs, or every face under the size floor).
    static func effectiveEar(_ item: BatchItem) -> Double? {
        item.faces.compactMap { face -> Double? in
            guard let ear = face.ear, !earImmune(face) else { return nil }
            return ear
        }.min()
    }

    /// 闭眼是合影小脸在原图上判出来的（earFullRes 的脸判了闭眼）：VLM 复审从 1024 的预览图裁脸，这种脸
    /// 在预览上只有二三十像素宽，而且 layer2 不裁小于 0.3% 的脸，会退回去裁主脸 —— 主脸睁着眼就把整张
    /// 放了。所以这条闭眼复审撤销不了，也不拿去问。要在 applyThresholds 之后看（faces 的 eyeClosed 是那里重算的）。
    nonisolated static func eyesBeyondAppeal(_ item: BatchItem) -> Bool {
        item.faces.contains { $0.earFullRes == true && $0.eyeClosed == true }
    }

    /// 写给 layer2 复审的罪名：合影小脸在原图上判的闭眼不问（问了也是看错脸），别的罪名照问。
    nonisolated static func appealCharges(_ item: BatchItem) -> [String] {
        guard eyesBeyondAppeal(item) else { return item.rejectReasons }
        return item.rejectReasons.filter { $0 != "闭眼" }
    }

    // 整体欠曝 / 过曝：固定常数，不做滑杆。判断看脸，不看整张 —— 低调人像整张很暗、脸是正常的
    // （DSCF7221：整张亮度中位数 47，脸 167）。但只看脸又会冤枉深肤色 / 背光里的正常片，所以欠曝还要
    // 整张「没有一处是亮的」（p99 低）：闪光灯没闪那种是脸和整张一起黑。实测（photot 21 张；DSCF7207 / 7225
    // 按线性光压暗）：脸 正常 134–180、-2EV 86–88、-3EV 61–62；整张 p99 正常 211–229、-2EV 116–120、
    // -3EV 83–86。-2EV 及以内不判，-3EV 起判。
    static let underexposedFaceLuma = 80.0
    static let underexposedFrameP99 = 100.0
    /// 没有脸时看整张中位数，线低得多 —— 没有脸，亮暗多半是画面内容不是曝光：正常亮度的桥景原片 152、
    /// -2EV 79、-4EV 38；本来就暗的屋檐原片 44、-1EV 29（p99 115，靠 p99 那条放过）。
    static let underexposedFrameLuma = 40.0
    /// 脸的亮度中位数到这里皮肤就没层次了（+1EV 216–221、+1.5EV 239–243、+2EV 251–252）。只看有脸的：
    /// 白色无缝背景的静物整张本来就在 245 上下，按整张判会误杀。
    static let overexposedFaceLuma = 240.0

    /// 「欠曝」/「过曝」/ nil。老版本分析的没有亮度数据，不判。
    static func toneReason(_ item: BatchItem) -> String? {
        guard let p99 = item.frameLumaP99 else { return nil }
        if let face = item.faceLuma {
            if face >= overexposedFaceLuma { return "过曝" }
            return face < underexposedFaceLuma && p99 < underexposedFrameP99 ? "欠曝" : nil
        }
        guard let frame = item.frameLuma else { return nil }
        return frame < underexposedFrameLuma && p99 < underexposedFrameP99 ? "欠曝" : nil
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
                if Self.earImmune(face) {
                    closed = nil
                } else {
                    closed = Self.eyeVerdict(ear: ear, groupBest: groupBestEar[group],
                                             groupEarCount: earCount)
                }
                if closed != face.eyeClosed {
                    updated[i].faces[f] = FaceInfo(bbox: face.bbox, eyeClosed: closed, ear: face.ear,
                                                   areaPct: face.areaPct, earFullRes: face.earFullRes)
                }
            }

            var reasons: [String] = []
            if updated[i].fileCorrupt { reasons.append("文件损坏") }
            if eyeClosed == true { reasons.append("闭眼") }
            if updated[i].sharpness < sharpnessThreshold { reasons.append("虚焦") }
            if updated[i].worstClipPct >= exposureThreshold { reasons.append("曝光裁切") }
            if let tone = Self.toneReason(updated[i]) { reasons.append(tone) }
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
            if !Self.eyesBeyondAppeal(updated[i]) {
                clear("闭眼", when: updated[i].appealClosedEyes.map { !$0 })
            }
            clear("虚焦", when: updated[i].appealSubjectSharp)
            clear("曝光裁切", when: updated[i].appealIntentionalExposure)
            // 欠曝 / 过曝问的是同一个问题（是不是刻意的低调 / 高调、剪影），答案一并清。
            clear("欠曝", when: updated[i].appealIntentionalExposure)
            clear("过曝", when: updated[i].appealIntentionalExposure)
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

    /// 每个有精选的待处理场：精选留下（钉成精选，否则砍完对手它会掉回可用），
    /// 其余**没被人工改判**的可用设为废片。人工标过可用的一律不碰 —— 那是用户
    /// 亲手做的决定。写进去的都记在 acceptedIDs：判决钉住了，但不算「人工改判」。
    /// 整个操作一条撤销记录，⌘Z 一次全部回来。
    /// chapter 非 nil = 只动这一章（时间轴「只看这一章」开着时的「本章接受推荐」）。
    @discardableResult
    func acceptAllRecommendations(inChapter chapter: Int? = nil) -> Int {
        var changes: [(id: String, verdict: Verdict)] = []
        var takes = 0
        let scope = chapter.map { c in items.filter { Self.timelineChapter(of: $0) == c } } ?? items
        for (_, members) in Dictionary(grouping: scope, by: \.take) {
            let picks = members.filter { $0.verdict == .pick }
            guard !picks.isEmpty else { continue }
            let losers = members.filter { $0.verdict == .usable && overrides[$0.id] == nil }
            guard !losers.isEmpty else { continue }
            takes += 1
            for p in picks where overrides[p.id] != .pick { changes.append((p.id, .pick)) }
            for l in losers { changes.append((l.id, .reject)) }
        }
        guard !changes.isEmpty else { return 0 }
        pushUndo(changes.map(\.id))
        for c in changes {
            overrides[c.id] = c.verdict
            acceptedIDs.insert(c.id)
        }
        dropAIMarks(changes.map(\.id))
        saveOverrides()
        applyThresholds()
        return takes
    }

    /// 某一章里「接受推荐」会动到的：场数 / 会变废片的张数（和 Derived 里全场那份同一个算法）。
    /// 只在「只看这一章」开着时算，不进 Derived。
    func recommendationSummary(inChapter chapter: Int) -> (takes: Int, rejects: Int) {
        var alive: [Int: [BatchItem]] = [:]
        for item in items where item.verdict != .reject && Self.timelineChapter(of: item) == chapter {
            alive[item.take, default: []].append(item)
        }
        var takes = 0, rejects = 0
        for (_, members) in alive where members.contains(where: { $0.verdict == .pick }) {
            let losers = members.filter { $0.verdict == .usable && overrides[$0.id] == nil }.count
            if losers > 0 { takes += 1; rejects += losers }
        }
        return (takes, rejects)
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
    /// AI 经实时桥放行的（aiOverrides）也不算：那是模型的判断，不是你在纠正滑杆。
    private func computeThresholdSuggestions() -> [ThresholdSuggestion] {
        func released(_ reason: String) -> [BatchItem] {
            items.filter { item in
                item.rejectReasons.contains(reason) && overrides[item.id].map { $0 != .reject } == true
                    && !acceptedIDs.contains(item.id) && aiOverrides[item.id] == nil
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
    /// 没有信号说明是哪条线该收紧。「接受推荐」废掉的落选张不算：那是算法自己的推荐，不是你在纠错；AI 经实时桥废掉的也不算。
    var manualRejectsWithoutReason: Int {
        items.filter {
            overrides[$0.id] == .reject && $0.rejectReasons.isEmpty && !acceptedIDs.contains($0.id) && aiOverrides[$0.id] == nil
        }.count
    }

    // MARK: - Trash rejects

    /// Moves every 废片's files to the TRASH (never permanent deletion — a wrong
    /// threshold or a mis-click must always be recoverable from the Finder trash).
    /// A RAW+JPEG pair goes together, along with its .xmp sidecar, and the photo
    /// disappears from the session + persisted artifacts so it doesn't resurface
    /// as a broken entry.
    /// 客户选中的废片不动：客户点名要精修的，判成废片也留着（菜单、确认框上的张数也不算它们）。
    /// 拼图页、印样帧、存好的方案里用到的默认也不动（`includeCollage` = 确认框里的「连这些一起移」，格子会空）。
    func trashRejects(includeCollage: Bool = false) {
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再移动废片"
            return
        }
        // 真移之前现取一次拼图在用的（拼图工程先挂到这一场）：菜单上的张数是之前推过来的，这期间可能又排了一版。
        refreshCollageInUse()
        let rejects = includeCollage ? trashableRejectsIncludingCollage : trashableRejects
        let keptForClient = clientPickRejectCount
        let keptForCollage = includeCollage ? 0 : collageProtectedRejectCount
        let inCollage = includeCollage ? collageInUseIDs : []
        guard !rejects.isEmpty else {
            if keptForCollage > 0 {
                let client = keptForClient > 0 ? "客户选中的 (\(keptForClient) 张) 或" : ""
                lastError = "废片都是" + client + "拼图 / 印样 / 方案里用到的 (\(keptForCollage) 张)，默认不移" +
                    " —— 要连拼图里的一起移，在确认框里点「连这些一起移」"
            } else if keptForClient > 0 {
                lastError = "废片都是客户选中的 (\(keptForClient) 张)，没有要移的"
            }
            return
        }
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
        // 旁边的 .xmp 只在共用它的照片（按整场算，不只看要移的）这次全都移走时才带走：同名的另一张还留着（HEIC 废了、
        // JPG 留着），它的星级、LR 调色就在这个文件里。主线程按完整的 items 算好再交给后台。
        let sidecars = SidecarSharing.trashSidecars(moving: rejects.map { ($0.id, $0.rawPath) },
                                                    all: items.map { ($0.id, $0.rawPath) })
        let jobs = rejects.map {
            (id: $0.id, rawPath: $0.rawPath, decodePath: $0.decodePath, previewPath: $0.previewPath,
             xmp: sidecars.carry[$0.id]?.xmp, xmpAfter: sidecars.carry[$0.id]?.after ?? [])
        }
        let keptSidecars = sidecars.kept
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
                // 共用这个 .xmp 的另几张都移成了才带走它（排在前面，已经处理过）。
                if let xmp = job.xmp, job.xmpAfter.allSatisfy(trashedIDs.contains), fm.fileExists(atPath: xmp.path) {
                    urls.append(xmp)
                }
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
            let keptShared = keptSidecars.filter { fm.fileExists(atPath: $0.path) }.count
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.items.removeAll { trashed.contains($0.id) }
                for id in trashed {
                    self.overrides.removeValue(forKey: id)
                    self.acceptedIDs.remove(id)
                }
                self.dropAIMarks(trashed)
                self.saveOverrides()
                if !self.clientPicks.isDisjoint(with: trashed) {
                    self.clientPicks.subtract(trashed)
                    self.saveClientPicks()
                }
                self.rebuildGroupSizes()
                self.purgeFromArtifacts(ids: trashed)
                self.applyThresholds()
                self.touchSessionIndex()
                self.isRunning = false
                self.postResultsChanged(previewsChanged: false)
                if flag.isSet {
                    self.progressText = "已取消: \(trashed.count) 张已移到废纸篓 (可恢复)，其余未动"
                } else if failedIds.isEmpty {
                    // 一段一段拼：一长串 + 和三元在 CI 的 Xcode 16 上类型检查会慢。
                    let hollowed = trashed.intersection(inCollage).count
                    var parts = ["已把 \(trashed.count) 张废片移到废纸篓 (可恢复)"]
                    if keptForClient > 0 { parts.append("客户选中的 \(keptForClient) 张废片没动") }
                    if keptForCollage > 0 { parts.append("拼图 / 印样 / 方案里用到的 \(keptForCollage) 张没动") }
                    if hollowed > 0 { parts.append("其中 \(hollowed) 张用在拼图里，那些格子会空着（从废纸篓「放回原处」就回来）") }
                    if keptShared > 0 { parts.append("\(keptShared) 个 .xmp 同名的另一张照片还在用，留着没移") }
                    self.progressText = parts.joined(separator: "；")
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

    // MARK: - JPG export (交付用: 精选/可用重编码, 尺寸/锐化/色彩/去 GPS/文件名模板)

    /// Default JPG output folder: a subfolder of the shoot that listPhotos
    /// skips, so exporting never feeds the outputs back into the next analysis.
    var defaultJPEGExportFolder: URL? {
        photoDir?.appendingPathComponent(ImageLoader.jpegExportSubfolder)
    }

    /// 上一次 JPG / 精华导出写了什么（无头 --export-jpeg 打印用）。
    struct JPEGExportReport {
        let folder: URL
        let written: [URL]
        let overLimit: [String]
        let failed: [String]
    }
    private(set) var lastJPEGExport: JPEGExportReport?

    /// 文件名模板要的字段：原名就是 id（以前固定的 {id}.jpg），日期 = 拍摄时间，星级 = 写进 XMP 的那个。
    func nameFields(_ item: BatchItem, index: Int, rank: Int?) -> DeliveryNaming.Fields {
        DeliveryNaming.Fields(original: item.id, index: index, date: item.captureTime, rank: rank,
                              camera: item.camera,
                              stars: Self.xmpRating(item, clientPick: clientPicks.contains(item.id)).stars)
    }

    /// 按判决（或给定 ids）选出要导的照片，保持顺序（精华按名次）。
    private func jpegExportItems(includeUsable: Bool, ids: [String]?) -> [BatchItem] {
        ids.map { $0.compactMap { item(withID: $0) } }
            ?? items.filter { $0.verdict == .pick || (includeUsable && $0.verdict == .usable) }
    }

    /// 文件名框旁边的预览：第一张导出来叫什么。
    func jpegNamePreview(_ options: DeliveryOptions, includeUsable: Bool, ids: [String]? = nil, ranked: Bool = false) -> String {
        guard let first = jpegExportItems(includeUsable: includeUsable, ids: ids).first else { return "（没有可导出的照片）" }
        return DeliveryNaming.render(options.nameTemplate, nameFields(first, index: 1, rank: ranked ? 1 : nil)) + ".jpg"
    }

    /// 精华 Top N：每次导到「精华/」下面一个新文件夹（Top20_2026-10-21_1530，重名加 -2）。以前固定写进
    /// 「精华/」、同名跳过、不清旧的：改了判决再导一次，掉出前 N 的还混在里面，而这个文件夹是要整个发出去的。
    /// 不删任何东西。
    func exportHighlights(count: Int, into base: URL, options: DeliveryOptions) {
        guard !isRunning else { return }
        let top = topPicks(count).ids
        guard !top.isEmpty else {
            lastError = "没有可导出的照片"
            return
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        let name = "Top\(top.count)_\(stamp.string(from: Date()))"
        var folder = base.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = base.appendingPathComponent("\(name)-\(n)")
            n += 1
        }
        exportJPEGs(to: folder, includeUsable: true, options: options, ids: top, ranked: true,
                    label: base.lastPathComponent + "/" + folder.lastPathComponent)
    }

    /// Decodes from `decodePath` (the JPEG half of a RAW+JPEG pair, else the RAW itself via ImageIO's
    /// vendor decoders) and re-encodes with the delivery options (size / sharpen / color / GPS / quality).
    /// 文件名按模板（默认 {原名} = 以前的 {id}.jpg）；批内重名、目标里已有的另存 -2、-3（旧文件不动），
    /// 只有 `overwrite` 开着才覆盖目标里的同名文件（重新导一遍换个质量）。
    /// `ids` 给定时只导这些、按给的顺序（精华 Top N 走这里，`ranked` = {名次} 按这个顺序），否则按判决选。
    /// 同一条通道：isRunning 守卫、并发上限、进度文字全部复用。
    func exportJPEGs(to folder: URL, includeUsable: Bool, options: DeliveryOptions, overwrite: Bool = false,
                     ids: [String]? = nil, ranked: Bool = false, label: String? = nil) {
        guard !isRunning else { return }
        let chosen = jpegExportItems(includeUsable: includeUsable, ids: ids)
        guard !chosen.isEmpty else {
            lastError = "没有可导出的照片"
            return
        }
        // 拍摄文件夹本身（选文件夹的面板一打开就在这儿）或里面会被分析扫到的子文件夹：勾了覆盖，{原名}.jpg
        // 在不分大小写的 APFS 上就是原片 DSCF7207.JPG，原片被缩小版盖掉；不勾也会写进一堆 -2，下次分析当成新照片。
        // 「导出JPG/」和它下面（精华）不参与分析，照常。
        if let photoDir, OriginalsCopier.insideAnalysis(folder, shoot: photoDir) {
            lastError = "不能导出到拍摄文件夹里面：勾了覆盖会把原片换成导出的 JPG，不勾下次分析也会把它们当成新照片。" +
                "请用「导出到 \(ImageLoader.jpegExportSubfolder)/」，或选拍摄文件夹外面的文件夹"
            return
        }
        // 目标路径在开工前一次排好（并发的 worker 各自算会撞名）。
        let names = chosen.enumerated().map { index, item in
            DeliveryNaming.render(options.nameTemplate, nameFields(item, index: index + 1, rank: ranked ? index + 1 : nil))
        }
        let plan = DeliveryNaming.plan(names, in: folder, overwrite: overwrite)
        let jobs = zip(chosen, plan.dests).map { (id: $0.0.id, source: URL(fileURLWithPath: $0.0.decodePath), dest: $0.1) }
        // 再兜一道：要覆盖的目标里有哪个就是原片（软链接过去的文件夹之类），整个不导。不覆盖时目标都是新名字。
        if overwrite, let hit = Self.firstOriginal(among: jobs.map(\.dest), originals: chosen) {
            lastError = "导出目标 \(hit.lastPathComponent) 就是原片，没有导出：请换一个文件夹"
            return
        }
        let renamed = plan.renamed
        let folderLabel = label ?? folder.lastPathComponent
        let isHighlights = ranked
        // 交付对照（DeliveryLedger.swift）：收尾时把写出去的文件名 → 哪一张、原片在哪记进这一场的 exports.json。
        let originals = Dictionary(chosen.map { ($0.id, $0.rawPath) }, uniquingKeysWith: { first, _ in first })
        let ledger = deliveryLedgerPath
        isRunning = true
        lastError = nil
        lastJPEGExport = nil
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag
        let total = jobs.count

        Task.detached { [weak self] in
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
            var overLimit: [String] = []
            var written: [URL] = []
            var done = 0
            var iterator = jobs.makeIterator()
            await withTaskGroup(of: (String, URL, DeliveryEncoder.Outcome).self) { group in
                func addNext() {
                    guard !flag.isSet, let job = iterator.next() else { return }
                    group.addTask {
                        (job.id, job.dest, Self.writeJPEG(from: job.source, to: job.dest, options: options))
                    }
                }
                for _ in 0..<workers { addNext() }
                for await (id, dest, outcome) in group {
                    switch outcome {
                    case .ok: written.append(dest)
                    case .overLimit: written.append(dest); overLimit.append(id)
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
            let overIds = overLimit
            let writtenFiles = written.sorted { $0.lastPathComponent < $1.lastPathComponent }
            // 按导出顺序（精华按名次）；取消了也记已经写出去的那些，文件都在。
            let writtenPaths = Set(written.map(\.path))
            let delivered = jobs.filter { writtenPaths.contains($0.dest.path) }.map {
                DeliveryRecord.File(file: $0.dest.lastPathComponent, id: $0.id, original: originals[$0.id] ?? $0.source.path)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                self.lastJPEGExport = JPEGExportReport(folder: folder, written: writtenFiles, overLimit: overIds,
                                                       failed: failedIds)
                let count = writtenFiles.count
                let kept = renamed > 0 ? "（\(renamed) 张目标里已有同名，另存为 -2、-3…，旧文件没动）" : ""
                if flag.isSet {
                    self.progressText = "导出已取消: 已写出 \(count) 张 → \(folderLabel)"
                } else if failedIds.isEmpty {
                    let title = isHighlights ? "精华导出完成" : "JPG 导出完成"
                    self.progressText = "\(title): \(count) 张 → \(folderLabel)" + kept
                    if !overIds.isEmpty { self.lastError = DeliveryEncoder.overLimitNote(overIds, maxMB: options.maxMB) }
                } else {
                    self.lastError = "JPG 导出: \(count) 成功, \(failedIds.count) 失败 (\(failedIds.prefix(3).joined(separator: ", ")))"
                }
                self.recordDelivery(isHighlights ? .highlights : .jpeg, folder: folder, files: delivered, into: ledger)
            }
        }
    }

    /// `dests` 里第一个和某张原片（RAW 或 JPG）是同一个文件的；按设备号 + inode 比，大小写、软链接都骗不过。
    /// 原片先 stat 一遍放进集合，几千张也只是几千次 stat。
    private static func firstOriginal(among dests: [URL], originals: [BatchItem]) -> URL? {
        func fileID(_ path: String) -> String? {
            var st = stat()
            return stat(path, &st) == 0 ? "\(st.st_dev):\(st.st_ino)" : nil
        }
        let ids = Set(originals.flatMap { [$0.rawPath, $0.decodePath] }.compactMap(fileID))
        return dests.first { fileID($0.path).map(ids.contains) ?? false }
    }

    /// Explicit decode → re-encode (NOT CGImageDestinationAddImageFromSource,
    /// which may copy the compressed stream and silently ignore the quality
    /// setting for JPEG→JPEG). Source properties ride along so EXIF and
    /// the orientation tag survive (GPS too unless stripGPS); pixels are written
    /// un-rotated with the tag, exactly like the camera did.
    ///
    /// 不锐化 + 保留色彩 + 不去 GPS + 不限体积 = 以前那条路，一个字节不变。缩小且要锐化时走 SharpRenderer
    /// （Lanczos + USM，渲染时直接出 sRGB 或源色彩空间）；不锐化但要 sRGB 的，解出来再真转换一次。
    nonisolated static func writeJPEG(from source: URL, to dest: URL, options: DeliveryOptions) -> DeliveryEncoder.Outcome {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(src) > 0
        else { return .failed }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        // 属性字典这条路，ImageIO 按 EXIF/TIFF 现编 XMP，原图的 XMP 包不跟过来 —— 拿掉 {GPS} 就是全拿掉了。
        // 拍摄时间、机身、镜头、版权、方向都留着。
        if options.stripGPS { props.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        let keepColor = options.effectiveColor == .keep
        // 相机直出的 Adobe RGB（没嵌 ICC）转 sRGB 前先认回 Adobe RGB；保留原色彩空间时原样不动（和以前一样）。
        let assumed = keepColor ? nil : SharpRenderer.cameraAdobeRGB(src, url: source, props: props)

        let image: CGImage?
        var rendered = false
        let full = WatermarkEngine.uprightSize(of: src)
        let size = options.sizeValue
        if let maxPixel = size.longEdgeCap(width: Double(full?.width ?? 0), height: Double(full?.height ?? 0)) {
            let downscaled = full.map { maxPixel < max($0.width, $0.height) } ?? false
            // 缩小了才锐化（原图本来就比框小的不放大、不锐化）。
            let sharpened = downscaled && options.sharpen != .off
                ? SharpRenderer.deliveryDownscale(src, longEdge: maxPixel, sharpen: options.sharpen, keepColor: keepColor,
                                                  assumeSpace: assumed)?.image
                : nil
            rendered = sharpened != nil
            // Resized path: thumbnail WITH transform bakes the rotation into the
            // pixels, so the orientation tag must be stripped — keeping it would
            // double-rotate in every viewer.
            image = sharpened ?? CGImageSourceCreateThumbnailAtIndex(src, 0, [
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
        guard var image else { return .failed }
        // 锐化那条已经在渲染时认过、转过了。
        if !rendered { image = SharpRenderer.retagged(image, as: assumed) }
        // 网络 / 微信：Adobe RGB、P3 真转换成 sRGB（平台丢了 ICC 按 sRGB 显示也不发灰），EXIF 色彩空间跟着改。
        if !keepColor, SharpRenderer.needsSRGBConversion(image.colorSpace) {
            guard let converted = SharpRenderer.convertedToSRGB(image) else { return .failed }
            image = converted
        }
        if !keepColor, image.colorSpace?.name == CGColorSpace.sRGB,
           var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           (exif[kCGImagePropertyExifColorSpace] as? Int) != 1 {
            exif[kCGImagePropertyExifColorSpace] = 1
            props[kCGImagePropertyExifDictionary] = exif
            props.removeValue(forKey: kCGImagePropertyProfileName)
        }
        let finalImage = image
        return DeliveryEncoder.write(to: dest, quality: options.quality, maxBytes: options.maxBytes) { out, quality in
            props[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(out, finalImage, props as CFDictionary)
        }
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
    /// 平铺，同名不同内容的另存 -2（不同子文件夹里同名的 RAW 不再互相顶掉）；一模一样的跳过；目标里的文件一个不删
    /// （见 HighISOCopier）。只复制 RAW 本身。
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
            var renamed: [String] = []
            var partialLeftovers = 0
            var failed: [String] = []
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "创建 \(ImageLoader.denoiseSubfolder) 文件夹失败: \(error.localizedDescription)"
                    self?.isRunning = false
                }
                return
            }
            for (index, src) in sources.enumerated() {
                if flag.isSet { break }
                let (outcome, partialLeftover) = HighISOCopier.copy(src, to: destDir, cancel: flag)
                switch outcome {
                case .copied(let name, let wasRenamed):
                    copied += 1
                    if wasRenamed { renamed.append(name) }
                    if partialLeftover { partialLeftovers += 1 }
                case .existed:
                    existed += 1  // 上次复制的、一模一样：跳过
                case .failed(let why):
                    failed.append(why)
                case .cancelled:
                    break      // flag 已经立起来，下一轮就停
                }
                let done = index + 1
                await MainActor.run { [weak self] in
                    self?.progressText = "复制 RAW \(done)/\(total)..."
                    self?.progressFraction = Double(done) / Double(total)
                }
            }

            let copiedCount = copied
            let existedCount = existed
            let renamedNames = renamed
            let partialCount = partialLeftovers
            let summaryFailed = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                var parts = [(flag.isSet ? "已取消: 已复制 " : "已复制 ") + "\(copiedCount) 个 RAW → \(ImageLoader.denoiseSubfolder)/"]
                if existedCount > 0 { parts.append("\(existedCount) 个已存在跳过") }
                if !renamedNames.isEmpty {
                    let shown = renamedNames.prefix(3).joined(separator: ", ") + (renamedNames.count > 3 ? "…" : "")
                    parts.append("\(renamedNames.count) 个和文件夹里的同名文件内容不一样，另存为 \(shown)" +
                                 "（多半是不同子文件夹里同名的 RAW）")
                }
                if partialCount > 0 {
                    parts.append("其中 \(partialCount) 个原名的文件是旧版复制中断留下的半截，没删，核对后可以删掉")
                }
                if jpegOnly > 0 { parts.append("\(jpegOnly) 张只有 JPG 未复制") }
                if summaryFailed.isEmpty {
                    self.progressText = parts.joined(separator: " · ")
                    AppRuntime.revealInFinder([destDir])
                } else {
                    self.lastError = "高ISO RAW: \(copiedCount) 成功, \(summaryFailed.count) 失败 (\(summaryFailed.prefix(3).joined(separator: ", ")))"
                }
            }
        }
    }

    // MARK: - XMP export (native — writes sidecars directly, manual overrides included)

    /// 写 XMP 写哪些。`.all`：整场（菜单「全部重写 XMP」，也补被删掉、被别的软件整份覆盖的 sidecar，合并不了的再试一次）；
    /// `.changed`：只写和上次写进去的不一样的（状态栏「XMP 待更新 N 张」，挑法同 xmpNeedsWrite）—— 其余的一个字节不碰，
    /// 在 LR / C1 里改过星级、这边没动的照片不会被盖回去，几千张的场次也不用整场重读重写。
    enum XMPExportScope {
        case all, changed
    }

    func exportXMP(_ scope: XMPExportScope = .all) {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        lastError = nil
        // 只写改了的：和「XMP 待更新」同一个判断。从没写过（xmpState == nil）时状态栏不提醒，走到这里就按整场写。
        let chosen: [BatchItem]
        if scope == .changed, let state = xmpState {
            chosen = items.filter { Self.xmpNeedsWrite($0, state: state, clientPick: clientPicks.contains($0.id)) }
        } else {
            chosen = items
        }
        let untouched = items.count - chosen.count
        // 同一个 .xmp 对应好几张（同目录同名、各自成片：HEIC+JPG、RAF 旁边的 DNG、JPG+TIF）：写哪张的星级色标都会盖掉
        // 另一张，整组不写、点名。按整场找（只写改了的也一样：改了的那张和没改的那张共用一个文件）。
        let sharedGroups = SidecarSharing.sharedGroups(items.map { ($0.id, $0.rawPath) })
        let sharedIDs = Set(sharedGroups.flatMap { $0 })
        let chosenIDs = Set(chosen.map(\.id))
        let sharedInScope = sharedGroups.filter { $0.contains(where: chosenIDs.contains) }
        let sharedNames: [String] = sharedInScope.map { group in
            group.compactMap { item(withID: $0).map { URL(fileURLWithPath: $0.rawPath).lastPathComponent } }
                .joined(separator: " + ")
        }
        let sharedPhotoCount = sharedInScope.reduce(0) { $0 + $1.count }
        // 只写改了的不重试上次旁边是别的软件的 XMP、合并不了的那些（它们不算「待更新」），完成时说一声。
        let foreignLeft: Int
        if scope == .changed, let state = xmpState, !state.foreign.isEmpty {
            foreignLeft = items.filter { state.foreign.contains($0.id) }.count
        } else {
            foreignLeft = 0
        }
        // Verdicts/overrides live on the main actor, so the sidecar contents are
        // derived here; the detached task is pure file IO (thousands of atomic
        // writes on a big shoot would otherwise freeze the UI for seconds).
        let jobs: [XMPJob] = chosen.filter { !sharedIDs.contains($0.id) }.map { item in
            // Red = the cross-app 淘汰 color — filterable in LR AND Capture One.
            // 客户选中的是紫色（压过绿 / 红），星级不变。
            let (stars, label) = Self.xmpRating(item, clientPick: clientPicks.contains(item.id))
            let xmpURL = URL(fileURLWithPath: item.rawPath).deletingPathExtension().appendingPathExtension("xmp")
            let reason = item.verdict == .reject ? item.rejectReasons.joined(separator: "; ") : ""
            // 上次写进去的色标（精选绿 / 废片红 / 客户选中紫）：这次没有色标时，别人的 sidecar 里还是这个色就拿掉；
            // 已经是别的色（你后来在 LR 里改的）就不动。
            let lastLabel = xmpState?.marks[item.id].flatMap(Self.writtenLabel)
            return XMPJob(id: item.id, url: xmpURL, content: Self.xmpContent(rating: stars, label: label, reason: reason),
                          stars: stars, label: label, lastLabel: lastLabel,
                          lightroomBlind: SidecarSharing.lightroomBlindFormat(rawPath: item.rawPath))
        }
        let total = jobs.count
        // 写完记下「每张这次写进去的是什么」，之后判决 / 星级 / 客户选中再变就提醒重写（状态栏）。
        let marks = Dictionary(chosen.map { ($0.id, Self.xmpMark($0, clientPick: clientPicks.contains($0.id))) },
                               uniquingKeysWith: { first, _ in first })
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag
        // 开头就把进度条立起来：以前要等第 50 张自己的 sidecar 写完才第一次刷新，整场都是别的软件的 XMP 时一直没有进度条。
        progressText = "写入 XMP 0/\(total)..."
        progressFraction = total > 0 ? 0 : nil

        Task.detached { [weak self] in
            var written = 0
            var merged = 0
            var unchanged = 0
            // Lightroom Classic only reads .xmp sidecars for proprietary RAW; for
            // JPEG/TIFF/DNG it expects the metadata embedded. Capture One reads
            // sidecars for everything. Say so instead of reporting a clean success.
            // 按这次真写进去（或本来就对）的数，格式记下来点名。
            var lightroomBlind = 0
            var blindFormats = Set<String>()
            var writtenIDs: [String] = []
            var preserved: [String] = []
            var failed: [String] = []
            for (index, job) in jobs.enumerated() {
                if flag.isSet { break }
                // 合并、原样保留、写失败、没变都走到下面同一个进度更新（以前合并和保留两路 continue 跳过了它）。
                let outcome = Self.writeSidecar(job)
                switch outcome {
                case .written:
                    written += 1
                    writtenIDs.append(job.id)
                case .merged:
                    merged += 1
                    writtenIDs.append(job.id)
                case .unchanged:
                    // 盘上已经是这一份：照样记成已同步，只是没重写（文件时间不变）。
                    unchanged += 1
                    writtenIDs.append(job.id)
                case .preserved:
                    preserved.append(job.id)
                case .failed:
                    failed.append(job.id)
                }
                if let format = job.lightroomBlind, outcome != .preserved, outcome != .failed {
                    lightroomBlind += 1
                    blindFormats.insert(format)
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
            let mergedCount = merged
            let unchangedCount = unchanged
            let blindCount = lightroomBlind
            let blindNames = blindFormats.sorted().joined(separator: "/")
            let writtenIds = writtenIDs
            let preservedIds = preserved
            let failedIds = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                // 只记真正写进去的（合并了星级色标的也算；取消、个别写失败也照记已写的那些）；
                // 合并不了、没碰的那些记成「不归我们管」，不算过期 —— 这次结果里点名说了。
                // 共用 .xmp 的那几张：不记成已同步（以前的版本给两张都记过），也不当别人的 —— 一直算「待更新」、每次点名，
                // 直到挪开其中一张；单独记一份，状态栏说清楚这几张是写不了、不是忘了写。
                let sharedChanged = sharedIDs != (self.xmpState?.sharedSidecar ?? [])
                if !writtenIds.isEmpty || !preservedIds.isEmpty || sharedChanged {
                    var state = self.xmpState ?? XMPState()
                    for id in writtenIds {
                        state.marks[id] = marks[id]
                        state.foreign.remove(id)
                    }
                    for id in preservedIds {
                        state.marks[id] = nil
                        state.foreign.insert(id)
                    }
                    for id in sharedIDs {
                        state.marks[id] = nil
                        state.foreign.remove(id)
                    }
                    state.sharedSidecar = sharedIDs.isEmpty ? nil : sharedIDs
                    self.saveXMPState(state)
                }
                // 写的这段时间里判决可能又变了：按现在的判决重数一遍。
                self.derived.xmpStaleCount = self.xmpStale(in: self.items)
                let done = writtenCount + mergedCount + unchangedCount
                let mergedNote = "其中 \(mergedCount) 个是其它软件的 XMP，只改了星级/色标，调色、关键字等原样保留"
                // 没写进去的要说出来，不能混在「完成」里、也不能被写失败的提示盖掉：这几张在 LR/C1 里还是旧星级。
                var keptNote: String?
                if !preservedIds.isEmpty {
                    let names = preservedIds.prefix(3).joined(separator: ", ") + (preservedIds.count > 3 ? "…" : "")
                    keptNote = "\(preservedIds.count) 张没写星级 (\(names))：旁边已有其它软件的 XMP，" +
                        "格式读不全、合并怕写丢调色，原样保留了 —— 这几张请在 LR/C1 里自己标"
                }
                // 同名冲突单独一条，不混进「没写星级」「失败」：原因和办法都不一样。
                var sharedNote: String?
                if sharedPhotoCount > 0 {
                    let shown = sharedNames.prefix(3).joined(separator: "、") + (sharedNames.count > 3 ? "…" : "")
                    sharedNote = "同名冲突 \(sharedPhotoCount) 张没写 XMP (\(shown))：同一个文件夹里同名不同格式的照片共用一个 .xmp，" +
                        "写哪张的星级色标都会盖掉另一张 —— 这几张请在 LR/C1 里自己标，或者把其中一张挪到别的文件夹再重新分析"
                }
                let warning = [keptNote, sharedNote].compactMap { $0 }.joined(separator: "；")
                var notes: [String] = []
                if unchangedCount > 0 && scope == .changed {
                    notes.append("其中 \(unchangedCount) 个盘上本来就是这样，没重写")
                }
                if mergedCount > 0 { notes.append(mergedNote) }
                if foreignLeft > 0 {
                    notes.append("上次没写进去的 \(foreignLeft) 张（旁边是其它软件的 XMP、合并不了）这次没重试，" +
                                 "「导出 › 全部重写 XMP」会再试")
                }
                if blindCount > 0 {
                    notes.append("注意 \(blindCount) 张是 \(blindNames)：Lightroom Classic 不读这些格式旁边的 .xmp" +
                                 "（它只认文件里内嵌的元数据；Capture One 能读）—— 要在 LR 里按判决筛，" +
                                 "用「导出 › 复制文件名」粘到图库筛选器「文本 › 文件名」")
                }
                if failedIds.isEmpty {
                    var summary: String
                    if scope == .changed {
                        summary = flag.isSet ? "XMP 已取消: 已更新 \(done) 张" : "XMP 已更新 \(done) 张，其余 \(untouched) 张没动"
                    } else if flag.isSet {
                        summary = "XMP 已取消: 已写入 \(done) 个"
                    } else if unchangedCount > 0 {
                        let rewritten = writtenCount + mergedCount
                        summary = "XMP 完成: \(done) 个都已对上（重写 \(rewritten) 个，\(unchangedCount) 个本来就对、没动）"
                    } else {
                        summary = "XMP 完成: \(done) 个已写入原图目录"
                    }
                    for note in notes { summary += "；" + note }
                    self.progressText = summary
                    self.lastError = warning.isEmpty ? nil : warning
                } else {
                    let failedNames = failedIds.prefix(3).joined(separator: ", ")
                    var message = "XMP: \(done) 个成功, \(failedIds.count) 个失败 (\(failedNames))"
                    for note in notes { message += "；" + note }
                    if !warning.isEmpty { message += "；" + warning }
                    self.lastError = message
                }
            }
        }
    }

    /// 一张 sidecar 这次是怎么落的。
    private enum XMPWriteOutcome: Sendable {
        /// 我们自己的整份模板写进去了（新建的，或者原来是我们写的、内容变了）。
        case written
        /// 别的软件的 sidecar，只合并了星级 / 色标。
        case merged
        /// 盘上已经是要写的这一份（自己的模板字节一样，或者合并出来和原来一样）：没写，文件时间不变。
        case unchanged
        /// 别的软件的 sidecar，读不全、合并不了：没碰。
        case preserved
        case failed
    }

    /// 写一张（后台线程，纯文件 IO）。别人的 sidecar 只合并星级 / 色标，合并不了的不碰；自己的写整份模板。
    /// 要写的和盘上的字节一模一样就不写 ——「全部重写」也不白改几千个文件的修改时间（LR / C1 按它判「外部改过」）。
    nonisolated private static func writeSidecar(_ job: XMPJob) -> XMPWriteOutcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: job.url.path) {
            // Lightroom 把调色参数、关键字、GPS 都存在同名 .xmp 里。别人的 sidecar 不能整份
            // 覆盖成我们这份只有星级的模板 = 整场调色报废；只合并星级 / 色标，合并不了的不碰。
            // 读不出来（权限、坏文件）也当别人的：以前读失败会落到下面整份覆盖。
            let existing = try? Data(contentsOf: job.url)
            if existing.map(XMPSidecar.isOwn) != true {
                guard let existing,
                      let data = XMPSidecar.merged(existing, rating: job.stars, label: job.label,
                                                   lastLabel: job.lastLabel) else {
                    return .preserved
                }
                if data == existing { return .unchanged }
                do {
                    try data.write(to: job.url, options: .atomic)
                } catch {
                    return .failed
                }
                return .merged
            }
            if existing == Data(job.content.utf8) { return .unchanged }
        }
        do {
            try job.content.write(to: job.url, atomically: true, encoding: .utf8)
        } catch {
            return .failed
        }
        return .written
    }

    /// 一张照片的 sidecar 要写什么：我们自己的整份模板，或者合并进别人 sidecar 的星级 / 色标。
    private struct XMPJob: Sendable {
        let id: String
        let url: URL
        let content: String
        let stars: Int
        let label: String?
        /// 上次写进这张的色标（没写过 / 可用 = nil；客户选中的是 Purple）。
        let lastLabel: String?
        /// Lightroom Classic 不读这种格式旁边的 .xmp（DNG、JPG……）：格式名，结尾提醒用；LR 读的 = nil。
        let lightroomBlind: String?
    }

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
