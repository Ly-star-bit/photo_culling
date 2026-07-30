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
    private let lock = NSLock()
    func set(_ p: Process?) { lock.lock(); process = p; lock.unlock() }
    func terminate() { lock.lock(); process?.terminate(); lock.unlock() }
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
        let resolved = restoreAccess(to: folder)
        photoDir = resolved
        // Session key from the URL the caller had (the recents entry's path):
        // keeps existing results reachable even if the bookmark resolved the
        // folder to a renamed location.
        sessionDir = dataDir.appendingPathComponent("sessions/\(Self.sessionKey(for: folder))")
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        overrides = [:]
        loadOverrides()
        loadResults()
        applyThresholds()
        NotificationCenter.default.post(name: .analysisDidFinish, object: nil, userInfo: ["dir": sessionDir])
    }

    private func loadSessionsIndex() {
        guard let data = try? Data(contentsOf: sessionsIndexPath),
              let entries = try? JSONDecoder().decode([SessionEntry].self, from: data) else { return }
        recentSessions = entries
    }

    private func touchSessionIndex() {
        guard let folder = photoDir else { return }
        let key = Self.sessionKey(for: folder)
        // Fresh bookmark while we demonstrably have access; keep the old one if
        // creation fails (shouldn't, but a stale bookmark beats none).
        let bookmark = Self.makeBookmark(for: folder)
            ?? recentSessions.first(where: { $0.key == key })?.bookmark
        var entries = recentSessions.filter { $0.key != key }
        entries.insert(SessionEntry(
            key: key, path: folder.path, name: folder.lastPathComponent,
            lastAnalyzed: ISO8601DateFormatter().string(from: Date()),
            photoCount: items.count,
            bookmark: bookmark
        ), at: 0)
        recentSessions = Array(entries.prefix(15))
        if let data = try? JSONEncoder().encode(recentSessions) {
            try? data.write(to: sessionsIndexPath)
        }
        pruneOrphanedSessions()
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

    /// Batch form (⌘-click multi-select): one save + one recompute for the lot.
    func setOverrideBatch(_ ids: some Collection<String>, _ verdict: Verdict?) {
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

    func runAnalysis() {
        guard let dir = photoDir else { return }
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        cancelFlag = AnalysisEngine.CancelFlag()
        let flag = cancelFlag
        let data = sessionDir

        Task.detached { [weak self] in
            // Runs natively (ImageIO/Vision) — no Python, no external deps.
            // Artifacts keep the prepare.py/layer1.py format so the VLM stage and
            // evaluate.py stay unchanged.
            await MainActor.run { [weak self] in self?.progressText = "分析中..." }
            let summary: AnalysisEngine.Summary
            do {
                summary = try AnalysisEngine.analyzeFolder(dir, dataDir: data, cancel: flag) { message in
                    let fraction = Self.parseFraction(message)
                    Task { @MainActor [weak self] in
                        self?.progressText = message
                        self?.progressFraction = fraction
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "分析失败: \(error.localizedDescription)"
                    self?.isRunning = false
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                if summary.cancelled {
                    self.progressText = "已取消"
                    self.isRunning = false
                    return
                }
                self.loadResults()
                self.applyThresholds()
                if summary.failed.isEmpty {
                    self.progressText = "完成: \(summary.analyzed) 张"
                } else {
                    self.progressText = "完成: \(summary.analyzed) 张"
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
        if let onStdoutLine {
            // print(..., flush=True) on the Python side writes whole lines per
            // write(), so splitting availableData on newlines is reliable enough
            // for short progress lines.
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") {
                    onStdoutLine(String(line))
                }
            }
        }
        do {
            try process.run()
            box?.set(process)
            defer { box?.set(nil) }
            process.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            if process.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?.suffix(500) ?? "exit \(process.terminationStatus)"
                return .failure(String(message))
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
                    for url in urls where fm.fileExists(atPath: url.path) {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    }
                    trashedIDs.insert(job.id)
                    try? fm.removeItem(at: URL(fileURLWithPath: job.previewPath))
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
    func exportJPEGs(to folder: URL, includeUsable: Bool, quality: Double) {
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
                                                 quality: quality))
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
    nonisolated static func writeJPEG(from source: URL, to dest: URL, quality: Double) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
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
            var failed: [String] = []
            for (index, job) in jobs.enumerated() {
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
            let failedIds = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                if failedIds.isEmpty {
                    self.progressText = "XMP 完成: \(writtenCount) 个已写入原图目录"
                } else {
                    self.lastError = "XMP: \(writtenCount) 个成功, \(failedIds.count) 个失败 (\(failedIds.prefix(3).joined(separator: ", ")))"
                }
            }
        }
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
    }
}
