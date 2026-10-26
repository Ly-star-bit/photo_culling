import SwiftUI
import AppKit

// MARK: - 批量页 / 连拍挑选离屏快照（不开 GUI：禁止激活、窗口从不显示）

/// LabelGUI --batch-ui <photo_dir> <out.png> [--size 1440x900] [--light]
/// LabelGUI --compare-ui <photo_dir> <out.png> [--take N | --select a,b] [--keys "2,cmd:<id>,..."] [--zoom [--person N]] [--size 1440x900] [--light]
/// LabelGUI --batch-ui <photo_dir> <out.png> --timeline-only [--hover N] [--pending]   （只画时间轴 + 悬停卡片）
/// LabelGUI --batch-ui <photo_dir> <out.png> [--client-only] [--client-import-ui <回复.txt>]   （只看客户选中 / 导入客户选择对话框）
/// LabelGUI --batch-ui <photo_dir> <out.png> --delivery-ui jpeg|highlights|watermark [--delivery-json '{"size":"long:3000"}']
///     （导出 JPG / 精华 Top N / 水印页的导出设置那一段）
/// LabelGUI --batch-ui <photo_dir> <out.png> --body-clock-ui   （状态栏「N 台机身」点开的按机身对时面板）
/// 都可以加 --ax-dump：截图前打印辅助功能树（输入框、滑杆这类 AppKit 控件带着值），按文字断言。
///
/// 和 --collage-ui 同一套：用 app 里一模一样的视图在一个从不显示的无边框窗口里布局、
/// 渲染成 PNG。界面不能开，排布有没有挤、时间轴会不会压到别的区域，只能这样看。
/// 视图偏好（@AppStorage）用命令行参数域传，比如 `-batch.gridMode 按分组` —— 参数域只活在
/// 这个进程里，不会写进任何人的设置。
/// 离屏快照里假装鼠标停在这张上（离屏窗口收不到鼠标，悬停才出现的按钮只能这样看）。界面运行时永远是 nil。
enum SnapshotPreview {
    @MainActor static var hoverID: String?
    /// 拼图检视器「印样 › 逐帧」一开始就展开（--collage-ui --contact-frames）。界面运行时永远是 false。
    @MainActor static var contactFramesOpen = false
}

/// 离屏快照的辅助功能树（--ax-dump）：AppKit 那几样控件（滑杆、分段、输入框、菜单按钮）带着值和能不能点，
/// 能按文字断言（滑杆的值是在滑杆范围里的比例：0 = 最左、1 = 最右）。SwiftUI 自己画的开关、文字不在树里。
/// 走老的按属性名取值（AXRole、AXChildren…）：新的协议方法在没接辅助功能客户端时，SwiftUI 的宿主视图
/// 不给子节点；按名字动态调，不引用已废弃的声明。
enum SnapshotAX {
    @MainActor
    static func dump(_ root: NSView) {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        func get(_ node: NSObject, _ attribute: String) -> Any? {
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector, with: attribute)?.takeUnretainedValue()
        }
        func walk(_ node: NSObject, depth: Int) {
            guard depth < 60 else { return }
            let role = get(node, "AXRole").map { "\($0)" } ?? "?"
            let name = [get(node, "AXDescription"), get(node, "AXTitle")]
                .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: "|")
            var line = String(repeating: " ", count: depth) + role
            if !name.isEmpty { line += " 「\(name)」" }
            if let v = get(node, "AXValue") as? NSNumber {
                line += String(format: " 值=%.4f", v.doubleValue)
            } else if let v = get(node, "AXValue") as? String {
                line += " 值=「\(v)」"
            }
            if (get(node, "AXEnabled") as? NSNumber)?.boolValue == false { line += " 灰" }
            print("AX " + line)
            for child in (get(node, "AXChildren") as? [Any]) ?? [] {
                if let child = child as? NSObject { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
    }
}

enum BatchUISnapshot {
    @MainActor
    static func run(flagIndex: Int, compare: Bool) -> Never {
        let args = CommandLine.arguments
        let flag = compare ? "--compare-ui" : "--batch-ui"
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        guard args.count > flagIndex + 2 else {
            print("用法: \(flag) <photo_dir> <out.png>")
            exit(1)
        }
        // switchSession 会写 sessions.json、清掉索引外的场次目录：只在临时数据目录里跑。
        CollageCLI.requireIsolatedDataDir(flag)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let out = URL(fileURLWithPath: args[flagIndex + 2])
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        if let gap = option("--gap").flatMap(Double.init) { store.takeGapSec = gap }
        // --chapter N：先开「只看这一章」（章节号从 1 数，和界面上一样）。
        if let n = option("--chapter").flatMap(Int.init) { store.chapterFilter = n - 1 }
        // --client-only：先开「只看客户选中」（客户选中先用 --client-import --apply 导进同一个数据目录）。
        if args.contains("--client-only") { store.clientPickFilter = true }
        // 存储卡导入的两条横幅：--import-notice "文字" 假装有导入提醒；--finished-import 假装导完一批还没打开
        // （同时假装有任务在跑，不然 BatchView 一出来就把它打开了）。
        if let notice = option("--import-notice") { store.importNotice = notice }
        if args.contains("--finished-import") {
            store.finishedImport = CardImporter.FinishedImport(folder: dir, analyze: true, shots: 128)
            store.isRunning = true
            store.progressText = "导出 JPG 12/40"
        }

        func spin(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        }

        let sizeParts = (option("--size") ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        let size = NSSize(width: sizeParts.first ?? 1440, height: sizeParts.count > 1 ? sizeParts[1] : 900)
        let light = args.contains("--light")

        let viewport = GridViewport()
        SnapshotPreview.hoverID = option("--hover-tile")
        let root: AnyView
        // --review-ui / --inspector-ui：审片模式 / 检视器，停在 --id 那张（默认第一张）。
        let sections: [Verdict] = [.pick, .usable, .reject]
        var order: [String] = []
        for v in sections { order += store.items.filter { $0.verdict == v }.map(\.id) }
        let startID = option("--id") ?? order.first ?? ""
        if args.contains("--shortcuts-ui") {
            root = AnyView(ShortcutsPanel().background(Color(white: 0.16)))
        } else if let kind = option("--delivery-ui") {
            root = AnyView(deliveryPreview(kind, store: store, json: option("--delivery-json") ?? "")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(white: 0.16)))
        } else if let path = option("--client-import-ui") {
            // 导入客户选择对话框（sheet 在离屏窗口里画不出来，单独当根视图画），框里预先放好这段回复。
            let text = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(ClientReply.decode) ?? ""
            root = AnyView(ClientImportSheet(store: store, isPresented: .constant(true), text: text)
                .background(Color(white: 0.16)))
        } else if args.contains("--body-clock-ui") {
            // 按机身对时面板（sheet 在离屏窗口里画不出来，单独当根视图画）。
            root = AnyView(BodyClockSheet(store: store, isPresented: .constant(true))
                .background(Color(white: 0.16)))
        } else if args.contains("--review-ui") {
            let skippable = order.contains { store.item(withID: $0).map { $0.verdict != .reject } ?? false }
            root = AnyView(ReviewView(store: store, orderIDs: order, rejectsSkippable: skippable,
                                      focusedID: .constant(startID), reviewMode: .constant(true)))
        } else if args.contains("--inspector-ui") {
            root = AnyView(PhotoInspector(store: store, inspectedID: .constant(startID), gridOrder: order,
                                          initialID: startID, onPickTake: { _ in }))
        } else if args.contains("--timeline-only") {
            // 只画时间轴 + 悬停卡片（--hover N = 第 N 段），下面垫一块网格色看卡片压在网格上的样子。
            let hover = option("--hover").flatMap(Int.init)
            root = AnyView(VStack(spacing: 0) {
                ChapterTimeline(segments: store.chapterSegments, viewport: GridViewport(),
                                showPending: args.contains("--pending"), minKeepers: store.minKeepersPerChapter,
                                filtered: store.activeChapterFilter, previewHover: hover) { _ in true }
                    .padding(.horizontal, 14).padding(.top, 8)
                    .zIndex(1)
                Color(white: 0.13)
            }.background(Color(white: 0.13)))
            for (i, seg) in store.chapterSegments.enumerated() {
                print("段 \(i): 章节 \(seg.chapter) · \(seg.count) 张 · \(seg.timeRange) · 待处理 \(seg.pendingTakes)\(seg.undated ? " · 无时间" : "")")
            }
        } else if compare {
            let request: PickRequest
            if let list = option("--select") {
                guard let r = PickRequest.forSelection(list.split(separator: ",").map(String.init), store: store) else {
                    print("--select 至少要 2 张")
                    exit(1)
                }
                request = r
            } else if let take = option("--take").flatMap(Int.init) {
                request = .take(take)
            } else if let first = store.pendingTakes.first {
                request = .take(first)
            } else {
                print("没有待处理的场")
                exit(1)
            }
            let session = PickSession(store: store, request: request, sortByScore: false)
            SnapshotPreview.hoverID = option("--hover-tile")
            for raw in (option("--keys") ?? "").split(separator: ",") {
                let key = raw.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { session.handle(key) }
            }
            print(session.describe())
            root = AnyView(PickView(store: store, session: session, zoom: args.contains("--zoom"),
                                    person: option("--person").flatMap(Int.init), onExit: { _ in }))
        } else {
            root = AnyView(BatchView(store: store, viewport: viewport))
        }
        let view = root
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, light ? .light : .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // 缩略图 / 大图都是后台解的，等它们回来。
        spin(Double(option("--wait") ?? "3") ?? 3)
        host.layoutSubtreeIfNeeded()
        spin(1)
        // --scroll-test：把网格（最高的那个 NSScrollView）滚到几个位置，打印时间轴认为「看得见」的章节 ——
        // 验证 Lazy 网格把滚出去的格子注销了（onDisappear），白线不会只增不减。
        if args.contains("--scroll-test") {
            func scrollViews(_ v: NSView) -> [NSScrollView] {
                (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews)
            }
            let grids = scrollViews(host).filter { ($0.documentView?.frame.height ?? 0) > $0.bounds.height }
            guard let grid = grids.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
                  let doc = grid.documentView else {
                print("没找到可滚的网格")
                exit(1)
            }
            let maxY = max(0, doc.frame.height - grid.contentView.bounds.height)
            print("网格内容高 \(Int(doc.frame.height))pt，可视 \(Int(grid.contentView.bounds.height))pt")
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0, 0.0] {
                let y = doc.isFlipped ? maxY * fraction : maxY * (1 - fraction)
                grid.contentView.scroll(to: NSPoint(x: 0, y: y))
                grid.reflectScrolledClipView(grid.contentView)
                for _ in 0..<4 { host.layoutSubtreeIfNeeded(); spin(0.3) }
                let chapters = viewport.chapters.sorted().map { $0 == BatchStore.ChapterSegment.undatedID ? "无时间" : "\($0 + 1)" }
                print(String(format: "滚到 %3.0f%%：看得见的章节 ", fraction * 100) + chapters.joined(separator: ","))
            }
        }
        if args.contains("--ax-dump") { SnapshotAX.dump(host) }
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
        print("界面快照 \(Int(size.width))x\(Int(size.height)) · \(store.items.count) 张 · 章节 \(store.chapterSegments.count) · \(out.path)")
        exit(0)
    }

    /// 导出 JPG / 精华 Top N / 水印页导出设置那一段（--delivery-ui），按各自的默认、盖上 --delivery-json。
    @MainActor
    private static func deliveryPreview(_ kind: String, store: BatchStore, json: String) -> DeliveryOptionsPreview {
        switch kind {
        case "highlights":
            let options = DeliveryOptions.load(json, defaults: .highlights(legacyMaxPixel: 2048))
            let ids = store.topPicks(20).ids
            return DeliveryOptionsPreview(options: options,
                                          preview: store.jpegNamePreview(options, includeUsable: true, ids: ids, ranked: true),
                                          tokensHint: DeliveryNaming.rankTokenHint)
        case "watermark":
            let options = DeliveryOptions.load(json, defaults: DeliveryOptions())
            return DeliveryOptionsPreview(options: options, preview: "DSCF7207_wm.jpg", showsColor: false, width: 310)
        default:
            let options = DeliveryOptions.load(json, defaults: .jpegExport(legacyMaxPixel: 0, legacyQuality: 90))
            return DeliveryOptionsPreview(options: options,
                                          preview: store.jpegNamePreview(options, includeUsable: true))
        }
    }
}
