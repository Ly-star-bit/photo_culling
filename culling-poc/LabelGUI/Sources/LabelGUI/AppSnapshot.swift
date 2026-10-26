import SwiftUI
import AppKit

// MARK: - 整窗离屏快照（测试用，不开 GUI：禁止激活、窗口从不显示）

/// LABELGUI_DATA_DIR=<临时目录> LabelGUI --app-ui <photo_dir> <out.png> [--tab 批量处理|水印|拼图|标注校准] [--size 1440x900] [--wait 4]
///
/// 和 --batch-ui / --collage-ui 同一套离屏画法，但画的是整个 ContentView（四个 tab 加上 tab 之间的接线），
/// store 走和 app 一模一样的 AppModel.make —— 那几个快照自己建 store、直接建单个页面，证明不了接线。
/// 窗口是无边框的，没有标题栏和工具栏（标注校准 tab 顶上那行「已标注 N / M」拍不到）。
/// 用户永远走不到这里：只认 `--` 开头的参数，必须设临时数据目录，不开桥。
enum AppUISnapshot {
    /// --tab 的写法 = 界面上 tab 的名字。
    static let tabNames: [(String, AppTab)] = [
        ("批量处理", .batch), ("水印", .watermark), ("拼图", .collage), ("标注校准", .labeling),
    ]

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        guard args.count > flagIndex + 2 else {
            print("用法: --app-ui <photo_dir> <out.png> [--tab 批量处理|水印|拼图|标注校准] [--size 1440x900] [--wait 4]")
            exit(1)
        }
        // 整套 store 都会写数据目录（sessions.json、拼图工程、水印设置）：只在临时数据目录里跑，
        // 而且临时目录不能就是真实的那个（LABELGUI_DATA_DIR 指回 Application Support 也拒绝）。
        CollageCLI.requireIsolatedDataDir("--app-ui")
        requireNotRealDataDir("--app-ui")
        var tab = AppTab.batch
        if let name = option("--tab") {
            guard let found = tabNames.first(where: { $0.0 == name }) else {
                print("--tab 只认 " + tabNames.map(\.0).joined(separator: "|") + "，没有「\(name)」")
                exit(1)
            }
            tab = found.1
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let out = URL(fileURLWithPath: args[flagIndex + 2])
        let model = AppModel.make(dataDir: appDataDir,
                                  pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir),
                                  bridge: .none)
        model.batch.switchSession(to: dir)
        model.tab = tab

        func spin(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        }

        let sizeParts = (option("--size") ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        let size = NSSize(width: sizeParts.first ?? 1440, height: sizeParts.count > 1 ? sizeParts[1] : 900)
        let (window, host) = offscreenWindow(model: model, size: size)
        host.layoutSubtreeIfNeeded()
        // 缩略图、大图、拼图预览都是后台出的，等它们回来。
        spin(Double(option("--wait") ?? "4") ?? 4)
        host.layoutSubtreeIfNeeded()
        spin(1)
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
        // 拼图工程不管拍的是哪个 tab 都打出来：拍批量处理 tab 时拼图页从没出现过，托盘里有照片 = 启动起就 attach 上了。
        let collage = model.collage
        let tabName = tabNames.first { $0.1 == model.tab }?.0 ?? "?"
        let layout: String = collage.root == nil ? "无版式" : "有版式"
        print("整窗快照 \(Int(size.width))x\(Int(size.height)) · tab \(tabName) · 批量 \(model.batch.items.count) 张"
              + " · 拼图托盘 \(collage.project.photos.count) 张 · \(collage.project.pages.count) 页 · \(layout)"
              + " · 窗口\(window.isVisible ? "可见" : "不可见") · \(out.path)")
        exit(0)
    }

    /// 把整个 ContentView 放进一个从不 order front 的无边框窗口（不 makeKey、不激活）。
    /// 窗口要拿着：放掉它，视图就没有窗口可画了。
    @MainActor
    static func offscreenWindow(model: AppModel, size: NSSize) -> (NSWindow, NSView) {
        let view = ContentView(model: model)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        return (window, host)
    }

    /// LABELGUI_DATA_DIR 解析到真实的默认数据目录（~/Library/Application Support/选片工具）就不跑：
    /// requireIsolatedDataDir 只看设没设，设成真实目录照样能把用户的场次和拼图工程改掉。
    /// 这里只算路径、不建目录。
    static func requireNotRealDataDir(_ flag: String) {
        let dir = ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? ""
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let real = base.appendingPathComponent("选片工具")
        func resolved(_ path: String) -> String {
            guard let p = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
            defer { free(p) }
            return String(cString: p)
        }
        // 解析完路径一样，或者 stat 出来是同一个目录（大小写不同的写法、/System/Volumes/Data 那条路）都算。
        var a = stat(), b = stat()
        let sameFile = stat(dir, &a) == 0 && stat(real.path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
        guard sameFile || resolved(dir) == resolved(real.path) else { return }
        print("\(flag) 的 LABELGUI_DATA_DIR 指到了真实数据目录 \(real.path)：换一个临时目录再跑（不能碰真实数据）")
        exit(2)
    }
}
