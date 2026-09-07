import Foundation
import SwiftUI
import AppKit
import ImageIO

/// State for the 水印 tab: photo list, signature, live config, presets, and
/// the batch export pipeline. Rendering itself lives in WatermarkEngine.
@MainActor
final class WatermarkStore: ObservableObject {
    @Published var photos: [URL] = []
    @Published var selectedPhoto: URL?
    @Published var signatureURL: URL? { didSet { loadSignature(); schedulePreview() } }
    @Published var config = WatermarkEngine.Config() { didSet { schedulePreview(); scheduleSave() } }
    @Published var options = WatermarkEngine.ExportOptions() { didSet { scheduleSave() } }
    @Published var outputDir: URL?
    @Published var previewImage: NSImage?
    @Published var isExporting = false
    /// 批量导出的取消开关：几百张全尺寸重编码要跑很久，选错输出目录时
    /// 之前只能干等或强退 app。
    private var exportCancelled = false

    func cancelExport() {
        guard isExporting else { return }
        exportCancelled = true
        progressText = "正在取消导出..."
    }
    @Published var progressText = ""
    @Published var progressFraction: Double?
    @Published var lastError: String?
    @Published private(set) var presets: [String: WatermarkEngine.Config] = [:]

    private var signatureImage: CGImage?
    private var previewTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private let stateDir: URL

    /// Small preview decode cache: (url → 1600px CGImage + full pixel width).
    private var previewCache: [URL: (image: CGImage, fullWidth: Int)] = [:]

    struct PersistState: Codable {
        var config: WatermarkEngine.Config
        var options: WatermarkEngine.ExportOptions
        var signaturePath: String?
        var outputPath: String?
        var presets: [String: WatermarkEngine.Config]
    }

    init(dataDir: URL) {
        stateDir = dataDir.appendingPathComponent("watermark")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        loadState()
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
        if selectedPhoto == nil { selectedPhoto = photos.first }
        if added > 0 {
            progressText = "已导入 \(added) 张"
        } else if !urls.isEmpty {
            // 一张都没进来时说清楚，别让按钮显示着数量、列表却纹丝不动。
            progressText = "没有可导入的照片 (格式不支持，或已经在列表里)"
        }
        schedulePreview()
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
        photos.removeAll { $0 == url }
        previewCache.removeValue(forKey: url)
        if selectedPhoto == url { selectedPhoto = photos.first }
        schedulePreview()
    }

    func clearPhotos() {
        photos.removeAll()
        previewCache.removeAll()
        selectedPhoto = nil
        previewImage = nil
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
        selectedPhoto = url
        schedulePreview()
    }

    /// Debounced re-render: sliders fire continuously; only the settled value
    /// costs a compose. Preview decodes at 1600px and pixel-unit params scale by
    /// preview/full width so WYSIWYG holds against the full-res export.
    func schedulePreview() {
        previewTask?.cancel()
        guard let url = selectedPhoto else {
            previewImage = nil
            return
        }
        let cfg = config
        let sig = signatureImage
        let cached = previewCache[url]
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let result: (image: NSImage, base: CGImage, fullWidth: Int)? =
                await Task.detached(priority: .userInitiated) {
                    let base: CGImage
                    let fullW: Int
                    if let cached {
                        (base, fullW) = cached
                    } else {
                        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceThumbnailMaxPixelSize: 1600,
                                  kCGImageSourceCreateThumbnailWithTransform: true,
                              ] as CFDictionary) else { return nil }
                        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                        base = thumb
                        // kCGImagePropertyPixelWidth is the ENCODED width, before
                        // EXIF orientation; the thumbnail above already had the
                        // rotation baked in. On a portrait frame (stored 6000×4000)
                        // that made scale 1067/6000 instead of 1067/4000, so the
                        // preview's margins and type were a third too small —
                        // the export looked nothing like what you saw.
                        let encodedW = (props?[kCGImagePropertyPixelWidth] as? Int) ?? thumb.width
                        let encodedH = (props?[kCGImagePropertyPixelHeight] as? Int) ?? thumb.height
                        // Thumb is already upright: match its aspect to decide
                        // whether width and height were swapped by the rotation.
                        let rotated = (thumb.width < thumb.height) != (encodedW < encodedH)
                        fullW = max(rotated ? encodedH : encodedW, thumb.width)
                    }
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    let tags = WatermarkEngine.ExifTags(source: src)
                    let scale = CGFloat(base.width) / CGFloat(fullW)
                    guard let composed = WatermarkEngine.compose(
                        base: base, signature: sig, config: cfg, tags: tags, scale: scale) else { return nil }
                    let image = NSImage(cgImage: composed,
                                        size: NSSize(width: composed.width, height: composed.height))
                    return (image, base, fullW)
                }.value
            guard !Task.isCancelled, let self, let result else { return }
            self.previewCache[url] = (result.base, result.fullWidth)
            if self.previewCache.count > 8 {
                for key in self.previewCache.keys.prefix(4) where key != url {
                    self.previewCache.removeValue(forKey: key)
                }
            }
            self.previewImage = result.image
        }
    }

    // MARK: - 批量导出

    func exportAll() {
        guard !isExporting, !photos.isEmpty else { return }
        guard let outputDir else {
            lastError = "先选择输出目录"
            return
        }
        guard signatureImage != nil || config.exifText.enabled || config.frame.enabled else {
            lastError = "没有任何水印内容 — 选签名图或启用文字/相框"
            return
        }
        // 目标文件名在批次内去重：a.jpg + a.png、或两个子文件夹里的同名照片会算出
        // 同一个 dest，先写的那张被后写的顶掉，而两张都报“成功”。
        var used = Set<String>()
        var jobs: [(src: URL, dest: URL)] = []
        for src in photos {
            let base = src.deletingPathExtension().lastPathComponent + options.filenameSuffix
            var dest = outputDir.appendingPathComponent("\(base).jpg")
            var n = 2
            while used.contains(dest.standardizedFileURL.path) {
                dest = outputDir.appendingPathComponent("\(base)-\(n).jpg")
                n += 1
            }
            used.insert(dest.standardizedFileURL.path)
            jobs.append((src, dest))
        }
        // 后缀为空 + 输出目录就是照片原目录 = 原片会被覆盖。引擎里也有兜底守卫，
        // 但那只会报“失败”；在这里拦下才能说清为什么。
        if let clash = jobs.first(where: { WatermarkEngine.isSameFile($0.src, $0.dest) }) {
            lastError = "输出会覆盖原片「\(clash.src.lastPathComponent)」—— 请填写文件名后缀，或换一个输出目录"
            return
        }

        isExporting = true
        exportCancelled = false
        lastError = nil
        let sig = signatureImage
        let cfg = config
        let opts = options
        let total = jobs.count

        Task.detached { [weak self] in
            await MainActor.run { [weak self] in self?.progressText = "导出 0/\(total)..." }
            let workers = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 4))
            var failed: [String] = []
            var done = 0
            var iterator = jobs.makeIterator()
            await withTaskGroup(of: (String, Bool).self) { group in
                func addNext() {
                    guard let job = iterator.next() else { return }
                    group.addTask {
                        (job.src.lastPathComponent,
                         WatermarkEngine.exportPhoto(source: job.src, to: job.dest, signature: sig,
                                                     config: cfg, options: opts))
                    }
                }
                for _ in 0..<workers { addNext() }
                for await (name, ok) in group {
                    if !ok { failed.append(name) }
                    done += 1
                    let doneNow = done
                    let stop = await MainActor.run { [weak self] () -> Bool in
                        self?.progressText = "导出 \(doneNow)/\(total)..."
                        self?.progressFraction = Double(doneNow) / Double(total)
                        return self?.exportCancelled ?? true
                    }
                    // 已经写出的文件保留（撤销它们比留着更意外），只是不再排新的。
                    if stop { break }
                    addNext()
                }
                group.cancelAll()
            }
            let failedNames = failed
            let completed = done
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isExporting = false
                if self.exportCancelled {
                    self.exportCancelled = false
                    self.progressText = "导出已取消 (已写出 \(completed)/\(total) 张，保留在输出目录)"
                } else if failedNames.isEmpty {
                    self.progressText = "导出完成: \(total) 张 → \(outputDir.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([outputDir])
                } else {
                    self.lastError = "导出: \(total - failedNames.count) 成功, \(failedNames.count) 失败 (\(failedNames.prefix(3).joined(separator: ", ")))"
                }
            }
        }
    }

    // MARK: - 预设

    func savePreset(named name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        presets[name] = config
        scheduleSave()
        progressText = "预设「\(name)」已保存"
    }

    func applyPreset(named name: String) {
        guard let preset = presets[name] else { return }
        config = preset
        progressText = "已应用预设「\(name)」"
    }

    func deletePreset(named name: String) {
        presets.removeValue(forKey: name)
        scheduleSave()
    }

    // MARK: - 持久化

    private var statePath: URL { stateDir.appendingPathComponent("state.json") }

    private func loadState() {
        guard let data = try? Data(contentsOf: statePath),
              let state = try? JSONDecoder().decode(PersistState.self, from: data) else { return }
        config = state.config
        options = state.options
        presets = state.presets
        if let path = state.signaturePath, FileManager.default.fileExists(atPath: path) {
            signatureURL = URL(fileURLWithPath: path)
        }
        if let path = state.outputPath {
            outputDir = URL(fileURLWithPath: path)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveState()
        }
    }

    private func saveState() {
        let state = PersistState(config: config, options: options,
                                 signaturePath: signatureURL?.path,
                                 outputPath: outputDir?.path,
                                 presets: presets)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: statePath)
        }
    }
}
