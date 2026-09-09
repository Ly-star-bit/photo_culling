import Foundation
import SwiftUI
import AppKit
import ImageIO

/// State for the 水印 tab: photo list, signature, live config, presets, and
/// the batch export pipeline. Rendering itself lives in WatermarkEngine.
@MainActor
final class WatermarkStore: ObservableObject {

    // MARK: - Published state

    @Published var photos: [URL] = []
    @Published var selectedPhoto: URL?
    @Published var signatureURL: URL? { didSet { loadSignature(); schedulePreview(); scheduleSave() } }
    @Published var config = WatermarkEngine.Config() { didSet { schedulePreview(); scheduleSave() } }
    @Published var options = WatermarkEngine.ExportOptions() { didSet { scheduleSave() } }
    @Published var outputDir: URL? { didSet { scheduleSave() } }
    @Published private(set) var presets: [String: WatermarkEngine.Config] = [:]

    @Published var previewImage: NSImage?
    /// 切换照片后、新预览渲染完成前为 true：旧图上盖一层转圈，而不是只在
    /// previewImage == nil 时才有反馈。
    @Published private(set) var previewStale = false
    /// 预览阶段发现的非错误提示（签名比画布还大之类），显示在预览区。
    @Published private(set) var previewHint: String?

    @Published private(set) var isExporting = false
    /// 导出进度（只属于导出）。
    @Published private(set) var progressText = ""
    @Published private(set) var progressFraction: Double?
    /// 导入/预设这类一次性通知，和导出进度分开：否则"已导入 3 张"会一直挂着。
    /// 下一次操作或几秒后自动清掉。
    @Published private(set) var notice: String?
    @Published var lastError: String?

    // MARK: - Private state

    private var signatureImage: CGImage?
    private var previewTask: Task<Void, Never>?
    /// 每次 schedulePreview 递增；合成结果回来时不是最新一代就丢弃。
    private var previewGeneration = 0
    private var noticeTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    /// 批量导出的取消开关：几百张全尺寸重编码要跑很久，选错输出目录时
    /// 之前只能干等或强退 app。
    private var exportCancelled = false
    private let stateDir: URL

    /// 预览底图缓存：1600px 正向解码 + 全尺寸宽 + EXIF 标签，按 URL 存；
    /// 解码与合成分开，滑块每 tick 只重跑合成。
    struct PreviewBase {
        let image: CGImage
        let fullWidth: Int
        let tags: WatermarkEngine.ExifTags
    }
    private var previewCache: [URL: PreviewBase] = [:]
    /// LRU 顺序：末尾最近用过。
    private var previewOrder: [URL] = []
    private let previewCacheLimit = 8
    /// 进行中的解码按 URL 合并：连点同一张不会起 N 个并发全解码。
    private var previewDecodes: [URL: Task<PreviewBase?, Never>] = [:]

    struct PersistState: Codable {
        var config = WatermarkEngine.Config()
        var options = WatermarkEngine.ExportOptions()
        var signaturePath: String?
        var outputPath: String?
        var presets: [String: WatermarkEngine.Config] = [:]

        init(config: WatermarkEngine.Config, options: WatermarkEngine.ExportOptions,
             signaturePath: String?, outputPath: String?, presets: [String: WatermarkEngine.Config]) {
            self.config = config
            self.options = options
            self.signaturePath = signaturePath
            self.outputPath = outputPath
            self.presets = presets
        }

        /// 逐字段容错：任何一个字段坏了只丢它自己，预设不会跟着全没。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            config = (try? c.decodeIfPresent(WatermarkEngine.Config.self, forKey: .config)) ?? nil ?? config
            options = (try? c.decodeIfPresent(WatermarkEngine.ExportOptions.self, forKey: .options)) ?? nil ?? options
            signaturePath = (try? c.decodeIfPresent(String.self, forKey: .signaturePath)) ?? nil
            outputPath = (try? c.decodeIfPresent(String.self, forKey: .outputPath)) ?? nil
            presets = (try? c.decodeIfPresent([String: WatermarkEngine.Config].self, forKey: .presets)) ?? nil ?? presets
        }
    }

    init(dataDir: URL) {
        stateDir = dataDir.appendingPathComponent("watermark")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        loadState()
        // 退出时把 1 秒防抖里还没落盘的状态写掉；必须同步，app 随后就退了。
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
    }

    // MARK: - 派生状态

    /// 有没有任何会画到图上的东西。导出按钮的禁用条件和 exportAll 的守卫用同一个。
    var hasWatermarkContent: Bool {
        (config.signatureEnabled && signatureImage != nil) || config.exifText.enabled || config.frame.enabled
    }

    /// nil = 可以导出；否则是按钮 tooltip 里说明的原因。
    var exportBlockedReason: String? {
        if isExporting { return "正在导出" }
        if photos.isEmpty { return "先导入照片" }
        if outputDir == nil { return "先选择输出目录" }
        if !hasWatermarkContent { return "没有任何水印内容 — 选签名图或启用文字/相框" }
        return nil
    }

    var canExport: Bool { exportBlockedReason == nil }

    /// 当前参数与哪个预设完全一致（有就打勾）。
    var activePresetName: String? {
        presets.keys.sorted().first { presets[$0] == config }
    }

    // MARK: - 照片导入

    /// RAW 也收：解码走 ImageIO（导出流程本来就支持），漏掉它们会让"导入选片
    /// 结果"在纯 RAW 拍摄上一张都导不进来，而按钮还写着"(57)"。
    static let inputExtensions: Set<String> = ImageLoader.imageExtensions

    func addPhotos(_ urls: [URL]) {
        var added = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // 文件夹整个拖进来：收下里面所有支持的图
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for file in contents.sorted(by: { $0.path < $1.path })
                    where Self.inputExtensions.contains(file.pathExtension.lowercased())
                        && !photos.contains(file) {
                        photos.append(file)
                        added += 1
                    }
                }
            } else if Self.inputExtensions.contains(url.pathExtension.lowercased()), !photos.contains(url) {
                photos.append(url)
                added += 1
            }
        }
        if selectedPhoto == nil, let first = photos.first {
            selectedPhoto = first
            schedulePreview()
        }
        if added > 0 {
            lastError = nil
            setNotice("已导入 \(added) 张")
        } else if !urls.isEmpty {
            // 一张都没进来时说清楚，别让按钮显示着数量、列表却纹丝不动。
            setNotice("没有可导入的照片 (格式不支持，或已经在列表里)")
        }
    }

    /// 与选片流程打通：把当前批次的精选(+可用)直接拉进来加水印。
    /// RAW 用配对的 JPEG 解码路径 — 水印输出永远是 JPEG。
    func importFromBatch(_ batchStore: BatchStore, includeUsable: Bool) {
        let chosen = batchStore.items.filter {
            $0.verdict == .pick || (includeUsable && $0.verdict == .usable)
        }
        addPhotos(chosen.map { URL(fileURLWithPath: $0.decodePath) })
    }

    func removePhoto(_ url: URL) {
        guard let index = photos.firstIndex(of: url) else { return }
        photos.remove(at: index)
        evictPreview(url)
        clearNotice()
        if selectedPhoto == url {
            // 删掉选中的那张：选中它原来位置上的下一张，方便连按 Delete 清理。
            selectedPhoto = photos.isEmpty ? nil : photos[min(index, photos.count - 1)]
            previewStale = selectedPhoto != nil
            schedulePreview()
        }
    }

    func clearPhotos() {
        previewTask?.cancel()
        previewGeneration += 1
        photos.removeAll()
        previewCache.removeAll()
        previewOrder.removeAll()
        selectedPhoto = nil
        previewImage = nil
        previewStale = false
        previewHint = nil
        clearNotice()
    }

    // MARK: - 签名图

    private func loadSignature() {
        signatureImage = signatureURL.flatMap { url in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
    }

    // MARK: - 实时预览

    func selectPhoto(_ url: URL) {
        guard url != selectedPhoto else { return }
        selectedPhoto = url
        previewStale = true
        schedulePreview()
    }

    /// Debounced re-render: sliders fire continuously; only the settled value
    /// costs a compose. Preview decodes at 1600px and pixel-unit params scale by
    /// preview/full width so WYSIWYG holds against the full-res export.
    ///
    /// 解码（慢，按 URL 缓存 + 合并进行中的请求）和合成（快）分开；结果回来时
    /// 既要是最新一代、也要仍是当前选中的那张，否则丢弃。
    func schedulePreview() {
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        guard let url = selectedPhoto else {
            previewImage = nil
            previewStale = false
            previewHint = nil
            return
        }
        let cfg = config
        let sig = signatureImage
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            guard let base = await self.previewBase(for: url) else {
                if self.previewGeneration == generation, self.selectedPhoto == url {
                    self.previewImage = nil
                    self.previewStale = false
                    self.lastError = "无法解码「\(url.lastPathComponent)」"
                }
                return
            }
            guard !Task.isCancelled, self.previewGeneration == generation, self.selectedPhoto == url else { return }
            let scale = CGFloat(base.image.width) / CGFloat(base.fullWidth)
            let composition = await Task.detached(priority: .userInitiated) {
                WatermarkEngine.compose(base: base.image, signature: sig, config: cfg, tags: base.tags, scale: scale)
            }.value
            guard !Task.isCancelled, self.previewGeneration == generation, self.selectedPhoto == url,
                  let composition else { return }
            self.previewImage = NSImage(cgImage: composition.image,
                                        size: NSSize(width: composition.image.width, height: composition.image.height))
            self.previewStale = false
            self.previewHint = composition.signatureSkipped
                ? "签名图比画布还大，已跳过 — 调小「大小」比例" : nil
        }
    }

    /// 缓存命中直接返回；否则复用进行中的解码，或者新起一个。
    private func previewBase(for url: URL) async -> PreviewBase? {
        if let cached = previewCache[url] {
            touchPreview(url)
            return cached
        }
        if let inflight = previewDecodes[url] {
            return await inflight.value
        }
        let task = Task.detached(priority: .userInitiated) { () -> PreviewBase? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let decoded = WatermarkEngine.decodeUpright(src, maxPixel: 1600) else { return nil }
            return PreviewBase(image: decoded.image, fullWidth: decoded.fullWidth,
                               tags: WatermarkEngine.ExifTags(source: src))
        }
        previewDecodes[url] = task
        let result = await task.value
        previewDecodes.removeValue(forKey: url)
        if let result, photos.contains(url) {
            previewCache[url] = result
            touchPreview(url)
            while previewOrder.count > previewCacheLimit, let oldest = previewOrder.first {
                evictPreview(oldest)
            }
        }
        return result
    }

    private func touchPreview(_ url: URL) {
        previewOrder.removeAll { $0 == url }
        previewOrder.append(url)
    }

    private func evictPreview(_ url: URL) {
        previewCache.removeValue(forKey: url)
        previewOrder.removeAll { $0 == url }
    }

    // MARK: - 批量导出

    /// 文件名后缀里的路径字符（"/" ":"）会让 dest 跑到别的目录或在 Finder 里变成
    /// 另一个字符；在这里剥掉。
    static func sanitizedSuffix(_ suffix: String) -> String {
        suffix.filter { $0 != "/" && $0 != ":" && $0 != "\0" }
    }

    func exportAll() {
        guard !isExporting, !photos.isEmpty else { return }
        guard let outputDir else {
            lastError = "先选择输出目录"
            return
        }
        guard hasWatermarkContent else {
            lastError = "没有任何水印内容 — 选签名图或启用文字/相框"
            return
        }
        // 目标文件名在批次内去重：a.jpg + a.png、或两个子文件夹里的同名照片会算出
        // 同一个 dest，先写的那张被后写的顶掉，而两张都报"成功"。APFS 默认大小写
        // 不敏感，所以按小写路径去重。
        var used = Set<String>()
        var jobs: [(src: URL, dest: URL)] = []
        let suffix = Self.sanitizedSuffix(options.filenameSuffix)
        for src in photos {
            let base = src.deletingPathExtension().lastPathComponent + suffix
            var dest = outputDir.appendingPathComponent("\(base).jpg")
            var n = 2
            while used.contains(dest.standardizedFileURL.path.lowercased()) {
                dest = outputDir.appendingPathComponent("\(base)-\(n).jpg")
                n += 1
            }
            used.insert(dest.standardizedFileURL.path.lowercased())
            jobs.append((src, dest))
        }
        // 后缀为空 + 输出目录就是照片原目录 = 原片会被覆盖。引擎里也有兜底守卫，
        // 但那只会报"失败"；在这里拦下才能说清为什么。
        if let clash = jobs.first(where: { WatermarkEngine.isSameFile($0.src, $0.dest) }) {
            lastError = "输出会覆盖原片「\(clash.src.lastPathComponent)」—— 请填写文件名后缀，或换一个输出目录"
            return
        }
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            lastError = "无法创建输出目录: \(error.localizedDescription)"
            return
        }

        isExporting = true
        exportCancelled = false
        lastError = nil
        clearNotice()
        progressText = "导出 0/\(jobs.count)..."
        progressFraction = 0
        let sig = signatureImage
        let cfg = config
        let opts = options
        let total = jobs.count

        Task.detached { [weak self] in
            let workers = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 4))
            var failures: [(name: String, reason: String)] = []
            var done = 0
            var iterator = jobs.makeIterator()
            await withTaskGroup(of: (String, String?).self) { group in
                func addNext() {
                    guard let job = iterator.next() else { return }
                    group.addTask {
                        do {
                            try WatermarkEngine.export(source: job.src, to: job.dest, signature: sig,
                                                       config: cfg, options: opts)
                            return (job.src.lastPathComponent, nil)
                        } catch {
                            return (job.src.lastPathComponent, error.localizedDescription)
                        }
                    }
                }
                for _ in 0..<workers { addNext() }
                // 取消后不再排新的，但把已经在跑的等完再收尾：这样 done 就是
                // 真实写出的张数，而不是 break 时丢掉在途结果的近似值。
                for await (name, failure) in group {
                    if let failure { failures.append((name, failure)) }
                    done += 1
                    let doneNow = done
                    let firstFailure = failures.first
                    let stop = await MainActor.run { [weak self] () -> Bool in
                        guard let self else { return true }
                        self.progressFraction = Double(doneNow) / Double(total)
                        if !self.exportCancelled {
                            self.progressText = "导出 \(doneNow)/\(total)..."
                        }
                        if let firstFailure, self.lastError == nil {
                            self.lastError = "导出失败「\(firstFailure.name)」: \(firstFailure.reason)"
                        }
                        return self.exportCancelled
                    }
                    if !stop { addNext() }
                }
            }
            let failed = failures
            let completed = done
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isExporting = false
                let succeeded = completed - failed.count
                if self.exportCancelled {
                    // 已经写出的文件保留（撤销它们比留着更意外）。
                    self.exportCancelled = false
                    self.progressText = "导出已取消 (已写出 \(succeeded)/\(total) 张，保留在输出目录)"
                } else if failed.isEmpty {
                    self.progressText = "导出完成: \(total) 张 → \(outputDir.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([outputDir])
                } else {
                    self.progressText = "导出结束: \(succeeded) 成功, \(failed.count) 失败"
                    let names = failed.prefix(3).map(\.name).joined(separator: ", ")
                    self.lastError = "\(failed.count) 张导出失败 (\(names)\(failed.count > 3 ? "…" : "")) — 首个原因: \(failed[0].reason)"
                }
            }
        }
    }

    func cancelExport() {
        guard isExporting, !exportCancelled else { return }
        exportCancelled = true
        progressText = "正在取消导出..."
    }

    // MARK: - 预设

    func savePreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        presets[name] = config
        lastError = nil
        setNotice("预设「\(name)」已保存")
        flushSave()   // 预设是用户主动存的，不走 1 秒防抖
    }

    func applyPreset(named name: String) {
        guard let preset = presets[name] else { return }
        config = preset
        lastError = nil
        setNotice("已应用预设「\(name)」")
    }

    func deletePreset(named name: String) {
        guard presets.removeValue(forKey: name) != nil else { return }
        setNotice("预设「\(name)」已删除")
        flushSave()
    }

    // MARK: - 通知

    private func setNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    // MARK: - 持久化

    private var statePath: URL { stateDir.appendingPathComponent("state.json") }

    private func loadState() {
        guard let data = try? Data(contentsOf: statePath) else { return }
        guard let state = try? JSONDecoder().decode(PersistState.self, from: data) else {
            // 整个文件都解不出来（不是 JSON / 被截断）：挪到一边而不是等下次保存
            // 时用默认值盖掉 —— 里面可能有几十个预设。
            let backup = stateDir.appendingPathComponent("state.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: statePath, to: backup)
            lastError = "水印设置文件损坏，已备份为 state.json.bak，本次使用默认设置"
            return
        }
        config = state.config
        options = state.options
        presets = state.presets
        if let path = state.signaturePath, FileManager.default.fileExists(atPath: path) {
            signatureURL = URL(fileURLWithPath: path)
        }
        if let path = state.outputPath {
            outputDir = URL(fileURLWithPath: path)
        }
        // didSet 在 init 里不触发；上面这几行也没必要马上写回。
        saveTask?.cancel()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveState()
        }
    }

    /// 立刻落盘（预设保存、app 退出）。
    private func flushSave() {
        saveTask?.cancel()
        saveState()
    }

    private func saveState() {
        let state = PersistState(config: config, options: options,
                                 signaturePath: signatureURL?.path,
                                 outputPath: outputDir?.path,
                                 presets: presets)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: statePath, options: .atomic)
        } catch {
            lastError = "水印设置保存失败: \(error.localizedDescription)"
        }
    }
}
