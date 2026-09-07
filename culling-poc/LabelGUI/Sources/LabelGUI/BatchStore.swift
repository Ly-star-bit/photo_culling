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
    var verdict: Verdict = .usable
    var rejectReasons: [String] = []
    /// Charges the VLM appeal cleared this photo of ("虚焦"/"闭眼"/"曝光裁切") —
    /// shown as the 平反 badge so the photographer sees WHY it walked.
    var vlmRescued: [String] = []
    /// Burst-relative eye decision computed by applyThresholds (nil = no
    /// judgment: no usable face, or all faces too small to read reliably).
    var dynamicEyeClosed: Bool?

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

    @Published var currentPreset: CullPreset?
    private var applyingPreset = false

    func applyPreset(_ preset: CullPreset) {
        applyingPreset = true
        let (sharp, exposure, quality) = preset.thresholds
        sharpnessThreshold = sharp
        exposureThreshold = exposure
        faceQualityThreshold = quality
        applyingPreset = false
        currentPreset = preset
    }

    private func onThresholdEdited() {
        if !applyingPreset { currentPreset = nil }
        applyThresholds()
    }

    /// burst_group -> member count, for the ×N stack badge on thumbnails.
    /// Cached: group membership only changes when a new analysis loads, but the
    /// grid re-renders on every slider tick / focus change and reads this 3×.
    private(set) var groupSizes: [Int: Int] = [:]

    private func rebuildGroupSizes() {
        var sizes: [Int: Int] = [:]
        for item in items { sizes[item.burstGroup, default: 0] += 1 }
        groupSizes = sizes
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
        NotificationCenter.default.post(name: .analysisDidFinish, object: nil, userInfo: ["dir": sessionDir])
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
        recentSessions = entries
        refreshSessionAvailability()
    }

    private func saveSessionsIndex() {
        if let data = try? JSONEncoder().encode(recentSessions) {
            try? data.write(to: sessionsIndexPath)
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
        refreshSessionAvailability()
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

    /// Recompute which recents point at folders that no longer exist. Cheap at
    /// 15 entries; call on launch, after analysis, and when the menu opens.
    func refreshSessionAvailability() {
        missingSessionKeys = Set(recentSessions
            .filter { Self.liveFolder(for: $0) == nil }
            .map(\.key))
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
        refreshSessionAvailability()
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
        refreshSessionAvailability()
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
            try? data.write(to: reviewStatePath)
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

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: overridesPath),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        overrides = raw.compactMapValues(Verdict.init(rawValue:))
    }

    private func saveOverrides() {
        let raw = overrides.mapValues(\.rawValue)
        if let data = try? JSONEncoder().encode(raw) {
            try? data.write(to: overridesPath)
        }
    }

    /// Canonical display order for reject-reason chips and slider kill-counts.
    static let reasonOrder = ["闭眼", "虚焦", "曝光裁切", "人脸质量低", "VLM建议淘汰"]

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

    var borderlineCount: Int { items.filter(isBorderline).count }

    /// How many photos carry each reject reason under the CURRENT thresholds
    /// (post-appeal, pre-override — the thresholds' own kill counts). Drives the
    /// "此线淘汰 N 张" labels and the 废片 filter chips.
    var reasonCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            for reason in item.rejectReasons { counts[reason, default: 0] += 1 }
        }
        return counts
    }

    var verdictCounts: (reject: Int, usable: Int, pick: Int) {
        var r = 0, u = 0, p = 0
        for item in items {
            switch item.verdict {
            case .reject: r += 1
            case .usable: u += 1
            case .pick: p += 1
            }
        }
        return (r, u, p)
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
        items.removeAll { incoming.contains($0.id) }
        items.append(contentsOf: provisionalBuffer)
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
            horizonDeg: a.horizonDeg
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
                if summary.cancelled {
                    self.progressText = "已取消"
                    self.isRunning = false
                    self.provisionalBuffer = []
                    self.loadResults()      // drop provisional rows, restore disk state
                    self.applyThresholds()
                    return
                }
                self.provisionalBuffer = []
                self.loadResults()          // authoritative results (real burst groups)
                self.applyThresholds()
                self.progressText = summary.reused > 0
                    ? "完成: 分析 \(summary.analyzed) 张 · 复用 \(summary.reused) 张未变"
                    : "完成: \(summary.analyzed) 张"
                if !summary.failed.isEmpty {
                    self.lastError = "\(summary.failed.count) 张无法解析被跳过: \(summary.failed.prefix(5).joined(separator: ", "))\(summary.failed.count > 5 ? "..." : "")"
                }
                self.isRunning = false
                self.touchSessionIndex()
                NotificationCenter.default.post(name: .analysisDidFinish, object: nil, userInfo: ["dir": self.sessionDir])
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
                    guard line.hasPrefix("PROGRESS ") else { return }
                    let parts = line.dropFirst("PROGRESS ".count).split(separator: "/")
                    guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.progressText = "VLM 分析中 \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                switch result {
                case .success:
                    self.loadResults()
                    self.applyThresholds()
                    self.progressText = "VLM 完成"
                    NotificationCenter.default.post(name: .analysisDidFinish, object: nil, userInfo: ["dir": self.sessionDir])
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
                    guard line.hasPrefix("PROGRESS ") else { return }
                    let parts = line.dropFirst("PROGRESS ".count).split(separator: "/")
                    guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.progressText = "复审中 \(done)/\(total)..."
                        self?.progressFraction = Double(done) / Double(total)
                    }
                }
            )
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
                    NotificationCenter.default.post(name: .analysisDidFinish, object: nil, userInfo: ["dir": self.sessionDir])
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

    func loadResults() {
        let decoder = JSONDecoder()

        guard let manifestData = try? Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(Manifest.self, from: manifestData) else {
            items = []
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

        items = manifest.photos.compactMap { photo -> BatchItem? in
            guard let l1 = l1ById[photo.id], let sharpness = l1.sharpness, let group = l1.burstGroup else { return nil }
            let l2 = l2ById[photo.id]
            return BatchItem(
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
        }
        assignChapters()
        rebuildGroupSizes()
    }

    // MARK: - Chapters (coverage protection)

    /// A shooting pause longer than this starts a new chapter (仪式→晚宴...).
    static let chapterGapSec: TimeInterval = 15 * 60

    private func assignChapters() {
        let datedIndices = items.indices
            .filter { items[$0].captureTime != nil }
            .sorted { items[$0].captureTime! < items[$1].captureTime! }
        var chapter = 0
        var prevTime: Date?
        for idx in datedIndices {
            let t = items[idx].captureTime!
            if let prev = prevTime, t.timeIntervalSince(prev) > Self.chapterGapSec {
                chapter += 1
            }
            items[idx].chapter = chapter
            prevTime = t
        }
        // Undated photos join chapter 0 rather than spawning fake chapters.
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
        var id: Int { chapter }
        var allRejected: Bool { pick + usable == 0 }
    }

    var chapterSegments: [ChapterSegment] {
        var byChapter: [Int: [BatchItem]] = [:]
        for item in items { byChapter[item.chapter, default: []].append(item) }
        guard byChapter.count > 1 else { return [] }
        return byChapter.sorted { $0.key < $1.key }.map { chapter, members in
            let times = members.compactMap(\.captureTime)
            let range = times.isEmpty ? "" :
                "\(Self.chapterTimeFormatter.string(from: times.min()!))-\(Self.chapterTimeFormatter.string(from: times.max()!))"
            var pick = 0, usable = 0, reject = 0
            for member in members {
                switch member.verdict {
                case .pick: pick += 1
                case .usable: usable += 1
                case .reject: reject += 1
                }
            }
            return ChapterSegment(chapter: chapter, count: members.count,
                                  pick: pick, usable: usable, reject: reject, timeRange: range)
        }
    }

    /// Chapters where culling left NOTHING (all rejected) — losing a whole scene
    /// is a delivery accident, a few extra keepers is just waste.
    var chapterWarnings: [String] {
        let formatter = Self.chapterTimeFormatter
        var byChapter: [Int: [BatchItem]] = [:]
        for item in items { byChapter[item.chapter, default: []].append(item) }
        guard byChapter.count > 1 else { return [] }
        var warnings: [String] = []
        for (chapter, members) in byChapter.sorted(by: { $0.key < $1.key }) {
            let survivors = members.filter { $0.verdict != .reject }
            if survivors.isEmpty {
                let times = members.compactMap(\.captureTime)
                let range = times.isEmpty ? "" :
                    " (\(formatter.string(from: times.min()!))-\(formatter.string(from: times.max()!)))"
                warnings.append("章节\(chapter + 1)\(range) 的 \(members.count) 张全部被淘汰")
            }
        }
        return warnings
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
        let chosen = items.filter { $0.verdict == .pick || (includeUsable && $0.verdict == .usable) }
        guard !chosen.isEmpty else {
            lastError = "没有可导出的照片"
            return
        }
        var cells = ""
        for (index, item) in chosen.enumerated() {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.previewPath)) else { continue }
            let b64 = data.base64EncodedString()
            cells += """
            <div class="cell"><img src="data:image/jpeg;base64,\(b64)">
            <div class="cap">#\(index + 1) · \(item.id)\(item.verdict == .pick ? " ★" : "")</div></div>\n
            """
        }
        let dateString = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        let html = """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>选片确认 · \(photoDir?.lastPathComponent ?? "")</title>
        <style>
        body{font-family:-apple-system,sans-serif;background:#111;color:#eee;margin:1rem}
        h1{font-size:1.1rem} .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:10px}
        .cell img{width:100%;border-radius:6px;display:block}
        .cap{font-size:.8rem;color:#bbb;padding:4px 2px}
        </style></head><body>
        <h1>选片确认 · \(photoDir?.lastPathComponent ?? "") · \(chosen.count) 张 · \(dateString)</h1>
        <p style="color:#999;font-size:.85rem">★ = 摄影师精选。请回复需要精修的编号。</p>
        <div class="grid">\(cells)</div></body></html>
        """
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            progressText = "联系表已导出: \(chosen.count) 张"
        } catch {
            lastError = "联系表导出失败: \(error.localizedDescription)"
        }
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

    func applyThresholds() {
        // Pass 1: per-burst-group baselines (best EAR, best face quality).
        var groupBestEar: [Int: Double] = [:]
        var groupEarCount: [Int: Int] = [:]
        var groupBestQ: [Int: Double] = [:]
        var groupQCount: [Int: Int] = [:]
        for item in items {
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
        for i in items.indices {
            let group = items[i].burstGroup
            let earCount = groupEarCount[group] ?? 0

            // Dynamic eye state: photo-level for the verdict, then the same rule
            // per face so the strip badges tell the same story.
            let eyeClosed: Bool?
            if let ear = Self.effectiveEar(items[i]) {
                eyeClosed = Self.eyeVerdict(ear: ear, groupBest: groupBestEar[group],
                                            groupEarCount: earCount)
            } else if items[i].faces.contains(where: { $0.ear != nil }) {
                eyeClosed = nil  // faces exist but all EAR-immune (too small)
            } else {
                eyeClosed = items[i].eyeClosed  // legacy session without raw EARs
            }
            items[i].dynamicEyeClosed = eyeClosed
            items[i].faces = items[i].faces.map { face in
                guard let ear = face.ear else { return face }
                let closed: Bool?
                if let area = face.areaPct, area < Self.minEarFaceAreaPct {
                    closed = nil
                } else {
                    closed = Self.eyeVerdict(ear: ear, groupBest: groupBestEar[group],
                                             groupEarCount: earCount)
                }
                return FaceInfo(bbox: face.bbox, eyeClosed: closed,
                                ear: face.ear, areaPct: face.areaPct)
            }

            var reasons: [String] = []
            if eyeClosed == true { reasons.append("闭眼") }
            if items[i].sharpness < sharpnessThreshold { reasons.append("虚焦") }
            if items[i].worstClipPct >= exposureThreshold { reasons.append("曝光裁切") }
            if faceQualityThreshold > 0, let q = items[i].faceQuality {
                if (groupQCount[group] ?? 0) >= 2, let best = groupBestQ[group] {
                    // Burst siblings exist: only a clear intra-group loser is suspect.
                    if q < best - Self.qualityGroupGap { reasons.append("人脸质量低") }
                } else if q < Self.compensatedQualityThreshold(slider: faceQualityThreshold,
                                                               faceAreaPct: items[i].faceAreaPct) {
                    reasons.append("人脸质量低")
                }
            }
            if items[i].vlmReject { reasons.append("VLM建议淘汰") }

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
            clear("闭眼", when: items[i].appealClosedEyes.map { !$0 })
            clear("虚焦", when: items[i].appealSubjectSharp)
            clear("曝光裁切", when: items[i].appealIntentionalExposure)
            items[i].vlmRescued = rescued
            items[i].rejectReasons = reasons

            // Manual override wins over every threshold: a manual non-reject keeps
            // the photo alive no matter what the sliders say, and vice versa.
            let auto: Verdict = reasons.isEmpty ? .usable : .reject
            let effective = overrides[items[i].id] ?? auto
            items[i].verdict = effective
            if effective == .reject { rejected.insert(items[i].id) }
        }

        // 精选 only within burst groups of 2+ survivors — a pick must have beaten
        // a real alternative, not merely been unopposed.
        var groups: [Int: [Int]] = [:]
        for (idx, item) in items.enumerated() where !rejected.contains(item.id) {
            groups[item.burstGroup, default: []].append(idx)
        }
        // Within-group ranking: VLM expression first, then Apple's FaceCaptureQuality
        // (its exact designed purpose — ranking captures of the same subject),
        // Laplacian sharpness only as the final tiebreak / no-face fallback.
        for (_, indices) in groups where indices.count >= 2 {
            // A manual 精选 in the group takes the slot; no auto-pick beside it.
            if indices.contains(where: { overrides[items[$0].id] == .pick }) { continue }
            let candidates = indices.filter { overrides[items[$0].id] == nil }
            guard candidates.count >= 1, indices.count >= 2 else { continue }
            let best = candidates.max { a, b in
                let ea = items[a].expressionScore ?? -1
                let eb = items[b].expressionScore ?? -1
                let qa = items[a].faceQuality ?? -1
                let qb = items[b].faceQuality ?? -1
                return (ea, qa, items[a].sharpness) < (eb, qb, items[b].sharpness)
            }
            if let best { items[best].verdict = .pick }
        }
    }

    // MARK: - Trash rejects

    /// Moves every 废片's files to the TRASH (never permanent deletion — a wrong
    /// threshold or a mis-click must always be recoverable from the Finder trash).
    /// A RAW+JPEG pair goes together, along with its .xmp sidecar, and the photo
    /// disappears from the session + persisted artifacts so it doesn't resurface
    /// as a broken entry.
    func trashRejects() {
        guard !isRunning else { return }
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

        Task.detached { [weak self] in
            let fm = FileManager.default
            var trashedIDs: Set<String> = []
            var failed: [String] = []
            for (index, job) in jobs.enumerated() {
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
                self.touchSessionIndex()
                self.isRunning = false
                NotificationCenter.default.post(name: .analysisDidFinish, object: nil, userInfo: ["dir": self.sessionDir])
                if failedIds.isEmpty {
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
                try? out.write(to: url)
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
    func exportJPEGs(to folder: URL, includeUsable: Bool, quality: Double, maxPixel: Int? = nil) {
        guard !isRunning else { return }
        let chosen = items.filter { $0.verdict == .pick || (includeUsable && $0.verdict == .usable) }
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
            await MainActor.run { [weak self] in self?.progressText = "导出 JPG 0/\(total)..." }
            // Full-res decodes are big (a 60MP RAW is ~160MB unpacked), so cap
            // concurrency lower than the analysis pass. Width-limited TaskGroup:
            // seed `workers` tasks, add one more as each finishes.
            let workers = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 4))
            var failed: [String] = []
            var done = 0
            var iterator = chosen.makeIterator()
            await withTaskGroup(of: (String, Bool).self) { group in
                func addNext() {
                    guard !flag.isSet, let item = iterator.next() else { return }
                    group.addTask {
                        (item.id, Self.writeJPEG(from: URL(fileURLWithPath: item.decodePath),
                                                 to: folder.appendingPathComponent("\(item.id).jpg"),
                                                 quality: quality, maxPixel: maxPixel))
                    }
                }
                for _ in 0..<workers { addNext() }
                for await (id, ok) in group {
                    if !ok { failed.append(id) }
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
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                if flag.isSet {
                    self.progressText = "导出已取消"
                } else if failedIds.isEmpty {
                    self.progressText = "JPG 导出完成: \(total) 张 → \(folder.lastPathComponent)"
                } else {
                    self.lastError = "JPG 导出: \(total - failedIds.count) 成功, \(failedIds.count) 失败 (\(failedIds.prefix(3).joined(separator: ", ")))"
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
                var parts = ["已复制 \(copiedCount) 个 RAW → \(ImageLoader.denoiseSubfolder)/"]
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

        Task.detached { [weak self] in
            var written = 0
            var preserved: [String] = []
            var failed: [String] = []
            for (index, job) in jobs.enumerated() {
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
                    var summary = "XMP 完成: \(writtenCount) 个已写入原图目录"
                    if !preservedIds.isEmpty {
                        summary += "；\(preservedIds.count) 个已有其它软件的 XMP (可能含 Lightroom 调色)，已保留未覆盖"
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
