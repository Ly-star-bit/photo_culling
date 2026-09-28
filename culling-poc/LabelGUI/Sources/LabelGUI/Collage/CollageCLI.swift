import Foundation
import AppKit
import PDFKit
import SwiftUI

/// 无头拼图：LabelGUI --collage <photo_dir> [选项]
///
///   选片   --ids a,b,c | --auto N（默认 6，按分数+多样性从精选/可用里挑）
///   画布   --canvas 3:4 | 1:1 | grid9 | 4:5 | 9:16 | 16:9 | carousel3 | a4 | album30 | album25 | album20 | album3020 | 宽x高
///   版式   --template <名字> | --alt K（第 K 个备选，默认 0）| --list（打印前 12 个备选）
///   样式   --style grid|white|dark|editorial|chinese|film|polaroid|gallery|tinted
///          --margin 0.045 --gutter 0.011 --no-tight --title 标题 --seed N --tries N
///   相册   --album [--spreads N] [--pdf] [--marks] [--no-dedupe]
///   输出   --out 文件或目录（九宫格/轮播/相册写目录）  --debug 叠人脸框/安全区/路人/切缝
///
/// 只读分析结果、只写 --out；不碰 UserDefaults。
enum CollageCLI {

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        let pool = store.items.filter { $0.verdict != .reject }.compactMap(CollageBridge.ref(from:))
        guard !pool.isEmpty else {
            print("没有可用的照片（先 --analyze）")
            exit(1)
        }

        var project = CollageProject()
        project.photos = pool
        project.canvas = canvas(option("--canvas") ?? "3:4")
        project.style = CollageStyles.preset(option("--style") ?? "grid")
        if let v = option("--margin").flatMap(Double.init) { project.style.margin = v }
        if let v = option("--gutter").flatMap(Double.init) { project.style.gutter = v }
        if args.contains("--no-tight") { project.style.tightSmallCells = false }
        project.title = option("--title") ?? ""
        let out = URL(fileURLWithPath: option("--out") ?? "collage.jpg")
        let debug = args.contains("--debug")
        let seed = UInt64(option("--seed") ?? "7") ?? 7
        let tries = Int(option("--tries") ?? "20000") ?? 20000
        var photoMap: [String: CollagePhotoRef] = [:]
        for p in pool { photoMap[p.id] = p }

        if args.contains("--album") {
            runAlbum(project: project, photoMap: photoMap, out: out, debug: debug, seed: seed,
                     spreads: Int(option("--spreads") ?? "0") ?? 0,
                     pdf: args.contains("--pdf"), marks: args.contains("--marks"),
                     dedupe: !args.contains("--no-dedupe"))
        }

        // --sim：打印候选两两的画面距离（校准相似度扣分用）。
        if args.contains("--sim") {
            let head = pool.sorted { $0.score > $1.score }.prefix(20)
            print("       " + head.map { String($0.id.suffix(4)) }.joined(separator: "  "))
            for a in head {
                let row = head.map { b -> String in
                    guard a.id != b.id, let d = CollageVision.distance(a, b) else { return "  - " }
                    return String(format: "%4.2f", d)
                }
                print("\(a.id.suffix(4))  " + row.joined(separator: " "))
            }
            exit(0)
        }

        let chosen: [CollagePhotoRef]
        if let list = option("--ids") {
            chosen = list.split(separator: ",").compactMap { photoMap[String($0)] }
        } else {
            let t0 = Date()
            chosen = CollageSelect.pick(Int(option("--auto") ?? "6") ?? 6, from: pool)
            print(String(format: "挑片 %.2fs", Date().timeIntervalSince(t0)))
        }
        guard !chosen.isEmpty else {
            print("没选中任何照片")
            exit(1)
        }
        let hero = chosen.max { $0.score < $1.score }!
        print("选中 \(chosen.map(\.id).joined(separator: " ")) · 主图 \(hero.id)")

        let t1 = Date()
        var hints: [String: CollageCrop.Hints] = [:]
        for p in chosen { hints[p.id] = CollageVision.hints(for: p) }
        print(String(format: "路人/主体 %.2fs · 有路人 %d 张", Date().timeIntervalSince(t1),
                     hints.values.filter { !$0.bystanders.isEmpty }.count))
        let context = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap,
                                            hints: hints, heroID: nil)

        let root: CollageNode
        if let name = option("--template") {
            guard let template = CollageTemplates.builtin.first(where: { $0.name.contains(name) }) else {
                print("没有模板「\(name)」：" + CollageTemplates.builtin.map(\.name).joined(separator: " / "))
                exit(1)
            }
            if let s = template.style, option("--style") == nil { project.style = s }
            if let c = template.canvas, option("--canvas") == nil { project.canvas = c }
            let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap,
                                            hints: hints, heroID: nil)
            root = CollageTemplates.apply(template, photos: chosen, context: ctx)
            let s = CollageLayout.score(root, m: nil, context: ctx)
            print("模板「\(template.name)」 分 \(fmt(s.score)) · 切脸 \(s.cutFaces) · 缝压脸 \(s.seamFaces)")
        } else {
            let t2 = Date()
            let results = CollageLayout.solve(CollageLayout.Request(photos: chosen, context: context,
                                                                    tries: tries, keep: 24, seed: seed))
            guard !results.isEmpty else {
                print("没解出任何版式")
                exit(1)
            }
            let best = results[0]
            let stretch: Double = max(best.m, 1 / best.m)
            let cropPercent: Double = 100 * (1 - 1 / stretch)
            let elapsed: Double = Date().timeIntervalSince(t2)
            print(String(format: "求解 %.2fs · 备选 %d 个 · 最优分 %.3f · m=%.3f（裁掉 %.0f%%）",
                         elapsed, results.count, best.score, best.m, cropPercent))
            if args.contains("--list") {
                for (i, r) in results.prefix(12).enumerated() {
                    print(String(format: "  #%d 分 %.3f m=%.3f 切脸 %d 缝压脸 %d  %@", i, r.score, r.m,
                                 r.cutFaces, r.seamFaces, r.signature))
                }
            }
            let alt = max(0, min(results.count - 1, Int(option("--alt") ?? "0") ?? 0))
            root = results[alt].root
        }
        project.pages = [CollagePage(root: root)]
        printTable(root, project: project, hints: hints)

        // --bench N：界面预览同款渲染（缓存预热后、半尺寸、不走导出解码）跑 N 次的平均耗时。
        if let n = option("--bench").flatMap(Int.init), n > 0 {
            for scale in [0.5, 0.8] {
                var preview = CollageRender.Options(scale: scale)
                preview.includeBleed = false
                _ = CollageRender.render(root: root, project: project, hints: hints, options: preview)
                let t = Date()
                for _ in 0..<n { _ = CollageRender.render(root: root, project: project, hints: hints, options: preview) }
                print(String(format: "预览渲染 scale %.1f · 平均 %.1f ms", scale, Date().timeIntervalSince(t) / Double(n) * 1000))
            }
        }

        var opts = CollageRender.Options(scale: 1)
        opts.debug = debug
        opts.export = true
        let t3 = Date()
        guard let image = CollageRender.render(root: root, project: project, hints: hints, options: opts) else {
            print("渲染失败")
            exit(1)
        }
        print(String(format: "渲染 %dx%d · %.2fs", image.width, image.height, Date().timeIntervalSince(t3)))
        write(image, project: project, out: out)
        exit(0)
    }

    // MARK: - 相册

    @MainActor
    private static func runAlbum(project base: CollageProject, photoMap: [String: CollagePhotoRef], out: URL,
                                 debug: Bool, seed: UInt64, spreads limit: Int, pdf: Bool, marks: Bool,
                                 dedupe: Bool) -> Never {
        var project = base
        if project.canvas.seams != .fold { project.canvas = CollageCanvas.albums[0] }
        var hints: [String: CollageCrop.Hints] = [:]
        for p in project.photos { hints[p.id] = CollageVision.hints(for: p) }
        let context = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap,
                                            hints: hints, heroID: nil)
        let plan = CollageAlbum.plan(project.photos, dedupe: dedupe)
        let used = plan.spreads.reduce(0) { $0 + $1.photos.count }
        print("相册 \(project.canvas.name) · \(project.canvas.width)x\(project.canvas.height)px · 出血 \(project.canvas.bleed)px · \(project.photos.count) 张 → 用 \(used) 张（相似拿掉 \(plan.dropped.count)）→ \(plan.spreads.count) 个跨页")
        if !plan.dropped.isEmpty { print("  拿掉: " + plan.dropped.map(\.id).joined(separator: " ")) }
        let pages = CollageAlbum.build(plan, context: context, seed: seed)
        for (i, spread) in plan.spreads.enumerated() {
            let s = CollageLayout.score(pages[i].root, m: nil, context: context)
            print("  跨页 \(i + 1) [\(spread.kind.rawValue)]: \(spread.photos.map(\.id).joined(separator: " ")) · 切脸 \(s.cutFaces) · 中缝压脸 \(s.seamFaces)")
        }
        project.pages = pages
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let count = limit > 0 ? min(limit, pages.count) : pages.count
        var jpegPages: [Data] = []
        for i in 0..<count {
            var opts = CollageRender.Options(scale: 1)
            opts.export = true
            opts.debug = debug
            let report = CollageRender.RenderReport()
            opts.report = report
            let t0 = Date()
            guard let image = CollageRender.render(root: pages[i].root, project: project, hints: hints, options: opts),
                  let data = CollageExport.encode(image, format: .jpeg, quality: 0.92, dpi: project.canvas.dpi) else {
                print("跨页 \(i + 1) 渲染失败")
                continue
            }
            if !report.lowRes.isEmpty || !report.missing.isEmpty {
                print("  跨页 \(i + 1) 退化: 用预览 \(report.lowRes) 空着 \(report.missing)")
            }
            let url = out.appendingPathComponent(String(format: "spread_%02d.jpg", i + 1))
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print(error.localizedDescription)
            }
            jpegPages.append(data)
            print(String(format: "  写出 %@ %dx%d · %.2fs", url.lastPathComponent, image.width, image.height,
                         Date().timeIntervalSince(t0)))
        }
        if pdf, !jpegPages.isEmpty {
            let url = out.appendingPathComponent("album.pdf")
            do {
                try CollageExport.writePDF(jpegPages: jpegPages, canvas: project.canvas, to: url, title: project.title,
                                           cropMarks: marks)
                // 读回来核对，不信写入端。
                if let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    print("PDF \(doc.pageCount) 页 · \(size / 1024) KB")
                    for box in [PDFDisplayBox.mediaBox, .bleedBox, .trimBox] {
                        let r = page.bounds(for: box)
                        print(String(format: "  %@ %.1f×%.1f pt @(%.1f,%.1f) = %.1f×%.1f cm", boxName(box),
                                     r.width, r.height, r.minX, r.minY, r.width / 72 * 2.54, r.height / 72 * 2.54))
                    }
                } else {
                    print("PDF 读回失败")
                }
            } catch {
                print(error.localizedDescription)
            }
        }
        exit(0)
    }

    private static func boxName(_ box: PDFDisplayBox) -> String {
        switch box {
        case .mediaBox: return "MediaBox"
        case .bleedBox: return "BleedBox"
        case .trimBox: return "TrimBox"
        default: return "Box"
        }
    }

    // MARK: - 输出

    private static func write(_ image: CGImage, project: CollageProject, out: URL) {
        let canvas = project.canvas
        let base = out.deletingPathExtension()
        // 切九宫格/轮播只切成品区（有出血的画布不能把出血切进第一格和最后一格）。
        let trimmed = CollageExport.trimmed(image, bleed: canvas.bleed) ?? image
        do {
            switch canvas.seams {
            case .grid9:
                try CollageExport.write(image, to: out, format: .jpeg, quality: 0.93, dpi: canvas.dpi)
                let tiles = CollageExport.split(trimmed, rows: 3, cols: 3)
                for (i, t) in tiles.enumerated() {
                    let url = URL(fileURLWithPath: base.path + "_\(i + 1).jpg")
                    try CollageExport.write(t, to: url, format: .jpeg, quality: 0.93, dpi: canvas.dpi)
                }
                print("写出 \(out.path) + 九宫格 \(tiles.count) 张 (\(tiles.first?.width ?? 0)x\(tiles.first?.height ?? 0))")
            case .carousel:
                try CollageExport.write(image, to: out, format: .jpeg, quality: 0.93, dpi: canvas.dpi)
                let tiles = CollageExport.split(trimmed, rows: 1, cols: max(1, canvas.slides))
                for (i, t) in tiles.enumerated() {
                    let url = URL(fileURLWithPath: base.path + "_\(i + 1).jpg")
                    try CollageExport.write(t, to: url, format: .jpeg, quality: 0.93, dpi: canvas.dpi)
                }
                print("写出 \(out.path) + 轮播 \(tiles.count) 张 (\(tiles.first?.width ?? 0)x\(tiles.first?.height ?? 0))")
            default:
                try CollageExport.write(image, to: out, format: .jpeg, quality: 0.93, dpi: canvas.dpi)
                print("写出 \(out.path)")
            }
        } catch {
            print(error.localizedDescription)
        }
    }

    /// 每格一行：路径、照片、格子尺寸、景别、取景窗口、裁掉多少、切脸/路人。
    private static func printTable(_ root: CollageNode, project: CollageProject, hints: [String: CollageCrop.Hints]) {
        let canvas = project.canvas
        let style = project.style
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos { photos[p.id] = p }
        let geo = CollageLayout.geometry(root, in: CollageLayout.contentRect(canvas: canvas, style: style),
                                         gutter: CollageLayout.gutterPixels(canvas: canvas, style: style))
        print("画布 \(canvas.width)x\(canvas.height) · 边距 \(CollageLayout.contentRect(canvas: canvas, style: style).x0)px · 缝 \(CollageLayout.gutterPixels(canvas: canvas, style: style))px · \(root.signature)")
        for f in geo.frames {
            let path = f.path.map(String.init).joined()
            switch f.cell.kind {
            case .photo:
                guard let id = f.cell.photoID, let p = photos[id] else {
                    print("  [\(path)] 空照片格 \(f.rect.width)x\(f.rect.height)")
                    continue
                }
                let framing = CollageLayout.effectiveFraming(path: f.path, cell: f.cell, in: geo.frames,
                                                             photos: photos, tight: style.tightSmallCells)
                let area = CollageCrop.photoArea(cell: f.cell, rect: f.rect.cgRect, style: style)
                let w = CollageCrop.window(for: p, cell: f.cell, cellAspect: CollageCrop.aspect(of: area),
                                           framing: framing, hints: hints[id])
                let kept = w.w * w.h
                let flags = (w.cutsFace ? " !!切脸" : "") + (w.hitsBystander ? " 路人" : "")
                print("  [\(path)] \(id) \(f.rect.width)x\(f.rect.height) \(framing.label) 窗口 \(fmt(w.w))x\(fmt(w.h)) 裁掉 \(Int(((1 - kept) * 100).rounded()))%\(flags)")
            case .text:
                print("  [\(path)] 文字 \(f.rect.width)x\(f.rect.height)")
            case .empty:
                print("  [\(path)] 留白 \(f.rect.width)x\(f.rect.height)")
            }
        }
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    static func canvas(_ spec: String) -> CollageCanvas {
        let social = CollageCanvas.social
        switch spec.lowercased() {
        case "3:4": return social[0]
        case "1:1": return social[1]
        case "grid9": return social[2]
        case "4:5": return social[3]
        case "9:16": return social[4]
        case "16:9": return social[5]
        case "carousel3": return social[6]
        case "a4": return social[7]
        case "album30": return CollageCanvas.albums[0]
        case "album25": return CollageCanvas.albums[1]
        case "album20": return CollageCanvas.albums[2]
        case "album3020": return CollageCanvas.albums[3]
        default:
            let parts = spec.lowercased().split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts[0] > 63, parts[1] > 63 {
                return CollageCanvas(name: "自定义", width: parts[0], height: parts[1])
            }
            return social[0]
        }
    }
}

// MARK: - 界面离屏快照（不开 GUI：禁止激活、窗口从不显示）

/// LabelGUI --collage-ui <photo_dir> <out.png> [--album] [--tab 版式|样式|文字|导出] [--select 路径如 10]
/// [--crop] [--size 1440x900]
/// 用和 app 一模一样的 CollageView 在离屏窗口里布局、渲染成 PNG —— 我不能打开界面，
/// 用它看排布、控件有没有挤、画布叠加层对不对。
enum CollageUISnapshot {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        guard args.count > flagIndex + 2 else {
            print("用法: --collage-ui <photo_dir> <out.png>")
            exit(1)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let out = URL(fileURLWithPath: args[flagIndex + 2])
        let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        batch.switchSession(to: dir)
        let store = CollageStore(dataDir: appDataDir)
        store.attach(sessionDir: batch.sessionDir, photoDir: dir)

        func spin(_ seconds: Double, until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                if done() { break }
            }
        }

        if store.project.photos.isEmpty {
            store.importVerdicts(batch: batch, includeUsable: true)
            spin(20) { !store.project.photos.isEmpty && store.busyText == nil }
        }
        if args.contains("--album") {
            store.setMode(.album)
            store.autoArrangeAlbum(dedupe: true)
            spin(60) { !store.project.pages.isEmpty && store.busyText == nil }
        } else if store.root == nil || args.contains("--relayout") {
            store.autoLayout(count: Int(option("--count") ?? "6") ?? 6)
            spin(60) { store.root != nil && !store.isSolving && store.busyText == nil }
        }
        if let name = option("--template"),
           let template = CollageTemplates.builtin.first(where: { $0.name.contains(name) }) {
            store.applyTemplate(template)
            spin(3)
        }
        if let title = option("--title") { store.setTitle(title) }
        if let root = store.root {
            let kinds = root.leafPaths().map { p -> String in
                let cell = root.node(at: p)?.cell
                let kind = cell?.kind == .text ? "文字" : (cell?.photoID ?? "空")
                return p.map(String.init).joined() + "=" + kind
            }
            print("格子: " + kinds.joined(separator: " "))
        }
        if let sel = option("--select") {
            store.selection = sel.compactMap { $0.wholeNumberValue }
            if args.contains("--crop"), let path = store.selection { store.enterCropEdit(path) }
        }
        let tab: CollageInspector.Tab = CollageInspector.Tab.allCases.first { $0.rawValue == option("--tab") } ?? .layout
        let sizeParts = (option("--size") ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        let size = NSSize(width: sizeParts.first ?? 1440, height: sizeParts.count > 1 ? sizeParts[1] : 900)

        // 离屏截图里 AppKit 面板底色会画成白的，深色模式的白字就看不见了：--light 用浅色看控件。
        let light = args.contains("--light")
        let view = CollageSnapshotHost(store: store, batchStore: batch, tab: tab)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, light ? .light : .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // 等备选缩略图、预览渲染、跨页缩略图都出来。
        spin(4)
        host.layoutSubtreeIfNeeded()
        spin(1.5)
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
        print("界面快照 \(Int(size.width))x\(Int(size.height)) · 托盘 \(store.project.photos.count) 张 · \(store.project.pages.count) 页 · 备选 \(store.alternatives.count) · \(out.path)")
        exit(0)
    }
}

/// 快照用：CollageView 的检视器 tab 是 @State，外面设不进去 —— 这里包一层直接给初值。
private struct CollageSnapshotHost: View {
    let store: CollageStore
    let batchStore: BatchStore
    let tab: CollageInspector.Tab

    var body: some View {
        // 离屏没有窗口底色：不垫一层，透明处存成 PNG 是黑的，黑字就看不见了。
        CollageView(store: store, batchStore: batchStore, initialTab: tab)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 编辑操作脚本（验证拖缝/换位/劈开/锁定/撤销这些手势背后的逻辑）

/// LabelGUI --collage-ops <photo_dir> --ops "swap:00>10,move:00>11:left,remove:10,flip:r,ratio:0=0.4,
///     lock:00,regen,framing:10=half,shape:10=circle,contain:10,crop:10=0.5,0.4,2,text:00=bottom,
///     place:DSCF7209>11:top,undo,redo,savetpl:名字,applytpl:名字,exporttpl:/path.json,importtpl:/path.json,
///     render:文件名" [--out 目录] [--count 6]
/// 路径写成数字串（"10" = 根的第二个孩子的第一个孩子），根节点写 r。每步打印版式树和撤销栈。
enum CollageOpsScript {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let outDir = URL(fileURLWithPath: option("--out") ?? ".")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        batch.switchSession(to: dir)
        let store = CollageStore(dataDir: appDataDir)
        store.attach(sessionDir: batch.sessionDir, photoDir: dir)

        func spin(_ seconds: Double, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if done() { break }
            }
        }
        func idle() { spin(60) { !store.isSolving && store.busyText == nil } }
        func path(_ s: String) -> [Int] { s == "r" ? [] : s.compactMap { $0.wholeNumberValue } }
        func describe() -> String {
            guard let root = store.root else { return "（空）" }
            let leaves = root.leafPaths().map { p -> String in
                let cell = root.node(at: p)?.cell
                var tag = cell?.kind == .text ? "文字" : (cell?.photoID.map { String($0.suffix(4)) } ?? "空")
                if cell?.locked == true { tag += "🔒" }
                if let f = cell?.framing, f != .auto { tag += "/" + f.label }
                if let s = cell?.shape { tag += "/" + s.label }
                if cell?.contain == true { tag += "/完整" }
                if let c = cell?.crop { tag += String(format: "/裁%.2f,%.2f×%.1f", c.cx, c.cy, c.zoom) }
                return (p.isEmpty ? "r" : p.map(String.init).joined()) + "=" + tag
            }
            return root.signature + "  |  " + leaves.joined(separator: " ")
        }

        // 起手：单张 3:4、托盘 = 精选+可用，排一版（每次都从头来，脚本结果可复现）。
        store.clearTray()
        store.setMode(.single)
        store.setCanvas(CollageCanvas.social[0])
        store.setStyle(CollageStyle())
        store.importVerdicts(batch: batch, includeUsable: true)
        spin(20) { !store.project.photos.isEmpty && store.busyText == nil }
        store.solve(photoIDs: ["DSCF7232", "DSCF7208", "DSCF7222", "DSCF7215", "DSCF7212", "DSCF7214"]
            .prefix(Int(option("--count") ?? "6") ?? 6).map { $0 })
        idle()
        print("起始  " + describe())

        for raw in (option("--ops") ?? "").split(separator: ",") {
            let op = raw.trimmingCharacters(in: .whitespaces)
            guard !op.isEmpty else { continue }
            let parts = op.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""
            switch name {
            case "swap":
                let ab = arg.split(separator: ">").map(String.init)
                store.swap(path(ab[0]), path(ab[1]))
            case "move":
                let ab = arg.split(separator: ">").map(String.init)
                let tail = ab[1].split(separator: ":").map(String.init)
                let edge: CollageLayout.Edge = ["left": .left, "right": .right, "top": .top, "bottom": .bottom][tail[1]] ?? .left
                store.move(from: path(ab[0]), to: path(tail[0]), edge: edge)
            case "place":
                let ab = arg.split(separator: ">").map(String.init)
                let tail = ab[1].split(separator: ":").map(String.init)
                let edge: CollageLayout.Edge? = tail.count > 1 ? (["left": .left, "right": .right, "top": .top, "bottom": .bottom][tail[1]]) : nil
                store.place(photoID: ab[0], at: path(tail[0]), edge: edge)
            case "remove":
                store.removeCell(path(arg))
            case "flip":
                store.flipGutter(path(arg))
            case "ratio":
                let kv = arg.split(separator: "=").map(String.init)
                store.beginContinuousEdit()
                store.setRatio(Double(kv[1]) ?? 0.5, at: path(kv[0]))
                store.endContinuousEdit()
            case "lock":
                store.selection = path(arg)
                store.toggleLock()
            case "regen":
                store.regenerate()
                idle()
            case "framing":
                let kv = arg.split(separator: "=").map(String.init)
                store.selection = path(kv[0])
                let f: CollageFraming = ["auto": .auto, "full": .full, "half": .half, "close": .close][kv[1]] ?? .auto
                store.setFraming(f)
            case "shape":
                let kv = arg.split(separator: "=").map(String.init)
                store.selection = path(kv[0])
                store.setShape(CollageShape(rawValue: kv[1]))
            case "contain":
                store.selection = path(arg)
                store.setContain(true)
            case "crop":
                let kv = arg.split(separator: "=").map(String.init)
                let nums = kv[1].split(separator: ";").compactMap { Double($0) }
                store.enterCropEdit(path(kv[0]))
                if nums.count == 3 {
                    store.setCrop(CollageCropOverride(cx: nums[0], cy: nums[1], zoom: nums[2]), at: path(kv[0]))
                }
                store.exitCropEdit()
            case "text":
                let kv = arg.split(separator: "=").map(String.init)
                store.selection = kv[0] == "none" ? nil : path(kv[0])
                let edge: CollageLayout.Edge = ["left": .left, "right": .right, "top": .top, "bottom": .bottom][kv[1]] ?? .bottom
                store.addTextCell(edge: edge, vertical: edge == .left || edge == .right)
            case "undo":
                store.undo()
            case "redo":
                store.redo()
            case "savetpl":
                store.saveTemplate(named: arg, fitAspects: true)
            case "applytpl":
                if let t = store.allTemplates.first(where: { $0.name == arg }) { store.applyTemplate(t) }
            case "exporttpl":
                store.exportTemplates(to: URL(fileURLWithPath: arg))
            case "importtpl":
                store.importTemplates(from: URL(fileURLWithPath: arg))
            case "mode":
                store.setMode(arg == "album" ? .album : .single)
            case "canvas":
                store.setCanvas(CollageCLI.canvas(arg))
            case "arrange":
                store.autoArrangeAlbum(dedupe: arg != "all")
                spin(60) { store.busyText == nil && !store.project.pages.isEmpty }
            case "page":
                store.pageIndex = Int(arg) ?? 0
            case "addpage":
                store.addPage()
            case "delpage":
                store.deletePage(Int(arg) ?? 0)
            case "movepage":
                let kv = arg.split(separator: "=").map(String.init)
                store.movePage(Int(kv[0]) ?? 0, by: Int(kv[1]) ?? 1)
            case "tonext":
                store.selection = path(arg)
                store.moveSelectedPhoto(toPage: store.pageIndex + 1)
            case "export":
                store.exportOptions.outputPath = arg
                store.export()
                spin(300) { !store.isExporting }
                print("  " + store.progressText)
                let found = (try? FileManager.default.subpathsOfDirectory(atPath: arg)) ?? []
                print("  输出: " + found.sorted().joined(separator: " "))
            case "render":
                var opts = CollageRender.Options(scale: 0.5)
                opts.includeBleed = false
                opts.debug = true
                if let root = store.root,
                   let image = CollageRender.render(root: root, project: store.project, hints: store.hints, options: opts) {
                    let url = outDir.appendingPathComponent(arg + ".jpg")
                    try? CollageExport.write(image, to: url, format: .jpeg, quality: 0.85, dpi: 72)
                    print("  出图 \(url.lastPathComponent)")
                }
            default:
                print("未知操作 \(op)")
                continue
            }
            let flags = "撤销\(store.canUndo ? "✓" : "✗") 重做\(store.canRedo ? "✓" : "✗")"
            let pages = store.isAlbum
                ? "  跨页 \(store.pageIndex + 1)/\(store.project.pages.count): " + store.project.pages.map { "\($0.root.photoIDs.count)" }.joined(separator: "-")
                : ""
            print("\(op)  →  " + describe() + "  [\(flags)]" + pages + (store.lastError.map { "  错误: \($0)" } ?? ""))
        }
        exit(0)
    }
}
