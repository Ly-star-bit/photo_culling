import SwiftUI

/// Analysis artifacts (previews, manifest/layer JSONs, labels.csv, settings.json)
/// live in Application Support — always writable by the app, no TCC prompt, works
/// when launched from /Applications, independent of username.
let appDataDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("选片工具")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

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
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "Done: %d photos in %.1fs (%.2fs/photo)",
                     summary.analyzed, elapsed, elapsed / Double(max(1, summary.analyzed))))
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

struct LabelGUIApp: App {
    @StateObject private var batchStore: BatchStore
    @StateObject private var labelStore: LabelStore
    @StateObject private var migrationStore: MigrationStore

    init() {
        let batch = BatchStore(
            dataDir: appDataDir,
            pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir)
        )
        _batchStore = StateObject(wrappedValue: batch)
        _labelStore = StateObject(wrappedValue: LabelStore(dataDir: batch.sessionDir))
        _migrationStore = StateObject(wrappedValue: MigrationStore(dataDir: appDataDir, batchStore: batch))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: labelStore, batchStore: batchStore)
        }
        .defaultSize(width: 1280, height: 850)

        // Rarely-used utility, reachable via 窗口 menu → 迁移.
        Window("迁移", id: "migration") {
            MigrationView(store: migrationStore, batchStore: batchStore)
                .frame(minWidth: 480, minHeight: 420)
        }
    }
}

LabelGUIApp.main()
