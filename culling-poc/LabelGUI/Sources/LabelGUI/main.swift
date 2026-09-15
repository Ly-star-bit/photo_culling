import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// Analysis artifacts (previews, manifest/layer JSONs, labels.csv, settings.json)
/// live in Application Support — always writable by the app, no TCC prompt, works
/// when launched from /Applications, independent of username.
let appDataDir: URL = {
    // CI 的无头回归用临时目录，别碰 runner 上的 Application Support。
    if let override = ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"], !override.isEmpty {
        let dir = URL(fileURLWithPath: override)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("选片工具")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

/// The Python pipeline (layer2.py etc.) ships INSIDE the app bundle
/// (Contents/Resources/culling-poc) and is synced to App Support on every
/// launch. Two reasons: uv needs to create .venv beside the scripts and the
/// signed bundle is read-only; and scripts must never version-skew from the
/// app again (new app + stale runtime once broke --backend).
func syncEmbeddedPipeline(to dataDir: URL) {
    let fm = FileManager.default
    guard let embedded = Bundle.main.resourceURL?.appendingPathComponent("culling-poc"),
          fm.fileExists(atPath: embedded.path) else { return }  // bare dev binary: keep using the checkout
    let dest = dataDir.appendingPathComponent("runtime/culling-poc")
    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
    // Replace everything except .venv — uv's environment survives app updates
    // and gets reconciled by uv itself when the lockfile changed.
    if let stale = try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil) {
        for url in stale where url.lastPathComponent != ".venv" {
            try? fm.removeItem(at: url)
        }
    }
    if let fresh = try? fm.contentsOfDirectory(at: embedded, includingPropertiesForKeys: nil) {
        for url in fresh {
            try? fm.copyItem(at: url, to: dest.appendingPathComponent(url.lastPathComponent))
        }
    }
}

syncEmbeddedPipeline(to: appDataDir)

let appConfig = AppConfig.load(from: appDataDir)

// Headless mode for testing/automation: LabelGUI --analyze <photo_dir>
// runs the native engine and exits without launching the window.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--analyze"),
   CommandLine.arguments.count > flagIndex + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    do {
        let start = Date()
        // Same per-shoot session dir the GUI uses, so headless runs show up there.
        let sessionDir = appDataDir.appendingPathComponent("sessions/\(BatchStore.sessionKey(for: dir))")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let summary = try AnalysisEngine.analyzeFolder(dir, dataDir: sessionDir) { message in
            print(message)
        }
        // 登记到 sessions.json：否则下次 GUI 分析任何文件夹时，
        // pruneOrphanedSessions 会把这次跑出来的预览和结果整个删掉。
        BatchStore.registerSession(dataDir: appDataDir, folder: dir,
                                   photoCount: summary.analyzed + summary.reused)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "Done: %d analyzed, %d reused in %.1fs (%.2fs/photo)",
                     summary.analyzed, summary.reused, elapsed, elapsed / Double(max(1, summary.analyzed))))
        if !summary.failed.isEmpty {
            print("Failed (\(summary.failed.count)): \(summary.failed.joined(separator: ", "))")
        }
        print("Artifacts: \(sessionDir.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("analyze failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless watermark smoke test:
// LabelGUI --watermark <photo> <out.jpg> [signature.png]
// Renders with EXIF text + frame enabled so the whole pipeline gets exercised.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--watermark"),
   CommandLine.arguments.count > flagIndex + 2 {
    let photo = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    var signature: CGImage?
    if CommandLine.arguments.count > flagIndex + 3 {
        let sigURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 3])
        if let src = CGImageSourceCreateWithURL(sigURL as CFURL, nil) {
            signature = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
    }
    var config = WatermarkEngine.Config()
    config.tintEnabled = true
    config.tint = .white
    config.exifText.enabled = true
    config.frame.enabled = true
    let ok = WatermarkEngine.exportPhoto(source: photo, to: out, signature: signature,
                                         config: config, options: .init())
    print(ok ? "watermark OK: \(out.path)" : "watermark FAILED")
    exit(ok ? 0 : 1)
}

// LabelGUI --session-key <photo_dir>：打印该文件夹对应的 sessions/<key>，
// 回归脚本用它把 fixture 放到 store 会去找的位置。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--session-key"),
   CommandLine.arguments.count > flagIndex + 1 {
    print(BatchStore.sessionKey(for: URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])))
    exit(0)
}

// Headless verdict smoke test (连拍去重用):
// LabelGUI --verdicts <photo_dir> [--dedupe]
// 加载该场次的缓存结果，套用当前阈值，打印判决/理由统计和多张连拍组的组内判决。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--verdicts"),
   CommandLine.arguments.count > flagIndex + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let dedupe = CommandLine.arguments.contains("--dedupe")
    // --gap <秒> 覆盖「同一场最大间隔」，用来扫参数而不必动 GUI 里的滑杆。
    var gapOverride: Double?
    if let gi = CommandLine.arguments.firstIndex(of: "--gap"), CommandLine.arguments.count > gi + 1 {
        gapOverride = Double(CommandLine.arguments[gi + 1])
    }
    MainActor.assumeIsolated {
        let store = BatchStore(dataDir: appDataDir,
                               pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.rejectBurstDuplicates = dedupe
        // 章节警告受这个设置影响；固定成 0，CI 的期望输出不跟着 UserDefaults 漂。
        store.minKeepersPerChapter = 0
        store.switchSession(to: dir)
        if let gap = gapOverride { store.takeGapSec = gap }
        // --accept-all：跑一遍「全部只留精选」再打印（写进该数据目录的 overrides.json，
        // 所以只在临时 LABELGUI_DATA_DIR 下用）。--undo 紧接着撤销一次，验证单条撤销记录。
        if CommandLine.arguments.contains("--accept-all") {
            let n = store.acceptAllRecommendations()
            print("接受全部推荐: 动了 \(n) 场 · overrides \(store.overrides.count) 条")
            if CommandLine.arguments.contains("--undo") {
                store.undoLastOverride()
                print("撤销一次后: overrides \(store.overrides.count) 条")
            }
        }
        let counts = store.verdictCounts
        print("连拍去重: \(dedupe ? "开" : "关")")
        print("照片 \(store.items.count) · 精选 \(counts.pick) · 可用 \(counts.usable) · 废片 \(counts.reject)")
        let stats = store.burstGroupStats
        let takes = store.takeStats
        print("近似重复 \(stats.groups) 组 / \(stats.photos) 张 (phash 层，自动规则作用范围)")
        print("场 (间隔≤\(Int(store.takeGapSec))s) \(takes.takes) 个多张场 / \(takes.photos) 张 · 待处理 \(store.pendingTakeCount)")
        for reason in BatchStore.reasonOrder {
            if let n = store.reasonCounts[reason] { print("  理由 \(reason): \(n)") }
        }
        for w in store.chapterWarnings { print("  章节警告: \(w)") }
        for sug in store.thresholdSuggestions {
            print("  阈值建议: 放行 \(sug.released) 张「\(sug.kind.rawValue)」→ \(sug.currentText) → \(sug.suggestedText) (能救回 \(sug.rescued)/\(sug.released))")
        }
        if store.manualRejectsWithoutReason > 0 { print("  滑杆漏掉(手动废且无理由): \(store.manualRejectsWithoutReason)") }
        let byTake = Dictionary(grouping: store.items, by: \.take)
        for take in byTake.keys.sorted() where (byTake[take]?.count ?? 0) > 1 {
            let line = byTake[take]!
                .sorted { ($0.captureTime ?? .distantPast) < ($1.captureTime ?? .distantPast) }
                .map { "\($0.id)=\($0.verdict.rawValue)" + (store.takeRank[$0.id].map { "#\($0)" } ?? "") }
                .joined(separator: " ")
            print("  场 \(take) (\(byTake[take]!.count) 张): \(line)")
        }
    }
    exit(0)
}

// Headless sharpen smoke test (适应视图管线):
// LabelGUI --sharp <photo> <out.jpg> [longEdge]
// 走和检视器一模一样的 4096 解码 → Lanczos 缩到 longEdge → unsharp，落成 JPEG。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--sharp"),
   CommandLine.arguments.count > flagIndex + 2 {
    let photo = CommandLine.arguments[flagIndex + 1]
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    let edge = CommandLine.arguments.count > flagIndex + 3 ? Int(CommandLine.arguments[flagIndex + 3]) ?? 2560 : 2560
    let start = Date()
    guard let decoded = ThumbCache.load(path: photo, maxPixel: SharpImageView.fitMaxPixel) else {
        FileHandle.standardError.write("decode failed\n".data(using: .utf8)!); exit(1)
    }
    let t1 = Date()
    guard let rendered = SharpRenderer.render(decoded, longEdge: edge),
          let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("render failed\n".data(using: .utf8)!); exit(1)
    }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
    print(String(format: "decode %.0fx%.0f in %.2fs · render %dx%d in %.3fs · %@",
                 decoded.size.width, decoded.size.height, t1.timeIntervalSince(start),
                 cg.width, cg.height, Date().timeIntervalSince(t1), out.path))
    exit(0)
}

// Headless focus-peaking smoke test: LabelGUI --focus <photo> <out.png>
// 把对焦高亮遮罩叠在 ≤2048 的缩图上落成 PNG，肉眼看合焦区域标得对不对。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--focus"),
   CommandLine.arguments.count > flagIndex + 2 {
    let photo = CommandLine.arguments[flagIndex + 1]
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    guard let full = FullResCache.load(path: photo) else { FileHandle.standardError.write("decode failed\n".data(using: .utf8)!); exit(1) }
    let t0 = Date()
    guard let mask = FocusMask.compute(from: full, key: photo) else { FileHandle.standardError.write("mask failed\n".data(using: .utf8)!); exit(1) }
    let dt = Date().timeIntervalSince(t0)
    guard let base = ThumbCache.load(path: photo, maxPixel: FocusMask.maxEdge),
          let bcg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(data: nil, width: bcg.width, height: bcg.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
    let rect = CGRect(x: 0, y: 0, width: bcg.width, height: bcg.height)
    ctx.draw(bcg, in: rect); ctx.draw(mask, in: rect)
    guard let composed = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, composed, nil); CGImageDestinationFinalize(dest)
    print(String(format: "mask %dx%d in %.2fs · %@", mask.width, mask.height, dt, out.path))
    exit(0)
}

struct LabelGUIApp: App {
    @StateObject private var batchStore: BatchStore
    @StateObject private var labelStore: LabelStore

    init() {
        let batch = BatchStore(
            dataDir: appDataDir,
            pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir)
        )
        _batchStore = StateObject(wrappedValue: batch)
        _labelStore = StateObject(wrappedValue: LabelStore(dataDir: batch.sessionDir))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: labelStore, batchStore: batchStore)
                // 深色是产品的一部分，不跟随系统外观：照片必须在中性深底上
                // 判断，浅色系统下半白半黑的窗口曾被当成"主题坏了"报障。
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 850)
    }
}

LabelGUIApp.main()
