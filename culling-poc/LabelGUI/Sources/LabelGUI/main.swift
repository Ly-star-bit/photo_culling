import SwiftUI
import ImageIO

/// Analysis artifacts (previews, manifest/layer JSONs, labels.csv, settings.json)
/// live in Application Support — always writable by the app, no TCC prompt, works
/// when launched from /Applications, independent of username.
let appDataDir: URL = {
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
