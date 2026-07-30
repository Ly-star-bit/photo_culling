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

    static let inputExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "webp", "bmp", "heic", "heif"]

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
        if added > 0 { progressText = "已导入 \(added) 张" }
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
                        fullW = max((props?[kCGImagePropertyPixelWidth] as? Int) ?? thumb.width, thumb.width)
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
        isExporting = true
        lastError = nil
        let jobs = photos
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
                    guard let src = iterator.next() else { return }
                    group.addTask {
                        let stem = src.deletingPathExtension().lastPathComponent
                        let dest = outputDir.appendingPathComponent("\(stem)\(opts.filenameSuffix).jpg")
                        return (src.lastPathComponent,
                                WatermarkEngine.exportPhoto(source: src, to: dest, signature: sig,
                                                            config: cfg, options: opts))
                    }
                }
                for _ in 0..<workers { addNext() }
                for await (name, ok) in group {
                    if !ok { failed.append(name) }
                    done += 1
                    let doneNow = done
                    await MainActor.run { [weak self] in
                        self?.progressText = "导出 \(doneNow)/\(total)..."
                        self?.progressFraction = Double(doneNow) / Double(total)
                    }
                    addNext()
                }
            }
            let failedNames = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isExporting = false
                if failedNames.isEmpty {
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
