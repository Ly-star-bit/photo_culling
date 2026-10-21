import SwiftUI
import AppKit

// MARK: - 水印页离屏快照（不开 GUI：禁止激活、窗口从不显示）

/// LABELGUI_DATA_DIR=<临时目录> LabelGUI --watermark-ui <photo_dir> <out.png> [--width 1100] [--height 820] [--light]
///     [--signature <sig.png>] [--count N] [--output <目录>] [--exif] [--ax-dump]
/// 和 --collage-ui 同一套：用 app 里一模一样的 WatermarkView 在一个从不显示的无边框窗口里布局、渲染成 PNG。
/// 照片目录里的图导进列表（--count 只要前 N 张），批量页切到同一个目录（「导入选片结果 (N)」有数）；
/// 水印页的设置从数据目录里读（watermark/state.json），--signature / --exif / --output 再往上改。
/// 打印顶栏的理想宽度：比窗口宽 = 顶栏挤得要截字了（窗口能缩到 960 左右，新按钮加在顶栏上要看这个）。
enum WatermarkUISnapshot {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        guard args.count > flagIndex + 2 else {
            print("用法: --watermark-ui <photo_dir> <out.png> [--width 1100] [--light]")
            exit(1)
        }
        // 水印页会把设置写回 watermark/state.json，批量页切目录会写 sessions.json：只在临时数据目录里跑。
        CollageCLI.requireIsolatedDataDir("--watermark-ui")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let out = URL(fileURLWithPath: args[flagIndex + 2])
        let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        batch.switchSession(to: dir)
        let store = WatermarkStore(dataDir: appDataDir)
        if let sig = option("--signature") {
            store.signatureURL = URL(fileURLWithPath: sig)
            store.config.signatureEnabled = true
        }
        if args.contains("--exif") { store.config.exifText.enabled = true }
        if let output = option("--output") { store.outputDir = URL(fileURLWithPath: output) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        let photos = files.filter { WatermarkStore.inputExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        let count = option("--count").flatMap(Int.init) ?? photos.count
        store.addPhotos(Array(photos.prefix(max(0, count))))

        func spin(_ seconds: Double, until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                if done() { break }
            }
        }

        let width = Double(option("--width") ?? "1100") ?? 1100
        let height = Double(option("--height") ?? "820") ?? 820
        let size = NSSize(width: width, height: height)
        // 离屏截图里 AppKit 控件底色会画成白的：--light 用浅色看控件（和 --collage-ui 一样）。
        let light = args.contains("--light")
        let view = WatermarkView(store: store, batchStore: batch)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, light ? .light : .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // 预览是后台解码 + 合成的，等它回来；缩略图也是后台解的。
        spin(15) { store.previewImage != nil && !store.previewStale }
        host.layoutSubtreeIfNeeded()
        spin(1.5)

        // 顶栏不受窗口宽度限制时要多宽（按钮、文字都不截）：和窗口宽比。
        let bar = NSHostingView(rootView: WatermarkView(store: store, batchStore: batch).topBar.fixedSize()
            .environment(\.colorScheme, light ? .light : .dark))
        let idealBar = bar.fittingSize.width

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("快照失败")
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try data.write(to: out)
        } catch {
            print("写不出 \(out.path)")
            exit(1)
        }
        if args.contains("--ax-dump") { SnapshotAX.dump(host) }
        let fits = idealBar <= size.width ? "放得下" : "挤了"
        let signature = store.signatureURL?.lastPathComponent ?? "无"
        print("顶栏理想宽 \(Int(idealBar.rounded()))pt · 窗口 \(Int(size.width))pt · \(fits)")
        print("水印页快照 \(Int(size.width))x\(Int(size.height)) · 照片 \(store.photos.count) 张 · 签名 \(signature)"
              + " · 能带进拼图 \(store.canSendToCollage ? "是" : "否") · 预览 \(store.previewImage == nil ? "没出来" : "有")"
              + " · \(out.path)")
        exit(0)
    }
}
