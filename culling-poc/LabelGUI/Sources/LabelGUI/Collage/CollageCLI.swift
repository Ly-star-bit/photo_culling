import Foundation
import AppKit
import PDFKit
import CoreText
import SwiftUI

/// 无头拼图：LabelGUI --collage <photo_dir> [选项]
///
///   选片   --ids a,b,c | --auto N（默认 6，按分数+多样性从精选/可用里挑）
///   画布   --canvas 3:4 | 1:1 | grid9 | 4:5 | 9:16 | 16:9 | carousel3 | a4 | album30 | album25 | album20 | album3020 | 宽x高
///   版式   --template <名字> | --alt K（第 K 个备选，默认 0）| --list（打印前 12 个备选）
///   样式   --style grid|white|dark|editorial|chinese|film|polaroid|gallery|tinted
///          --margin 0.045 --gutter 0.011 --no-tight --title 标题 --seed N --tries N
///   色调   --look film|airy|faded|cinema|cool|mono|sepia [--look-strength 0.8] [--harmonize 0.6]
///   压字   --overlay masthead|corner|subtitle|vertical|number|script|handwrite [--overlay-at 路径] [--anchor top…]
///          --subtitle 副标题
///   散落   --scatter [--frame polaroid|white|none|film|mounts] [--tilt 6] [--tape 0.6]
///   贴纸   --sticker washi@0.5,0.1,20（种类@中心x,y,旋转；可多次）
///   模板册 --template-sheet 出图.jpg（全部内置模板套这组照片，拼成一张总览）
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
        applyLookOptions(&project.style, option: option)
        if let m = option("--bg").flatMap(CollageBackgroundMode.init(rawValue:)) { project.style.backgroundMode = m }
        project.title = option("--title") ?? ""
        project.subtitle = option("--subtitle") ?? ""
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
                     dedupe: !args.contains("--no-dedupe"),
                     binding: option("--binding").flatMap(CollageBinding.init(rawValue:)) ?? .layflat)
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

        if let sheet = option("--look-sheet") {
            lookSheet(project: project, photos: chosen, hints: hints, out: URL(fileURLWithPath: sheet))
        }
        if let sheet = option("--template-sheet") {
            templateSheet(project: project, photos: chosen, photoMap: photoMap, hints: hints,
                          out: URL(fileURLWithPath: sheet), only: option("--only"))
        }

        var page = CollagePage(root: .leaf(CollageCell()))
        let root: CollageNode
        if let name = option("--template") {
            guard let template = CollageTemplates.find(name) else {
                print("没有模板「\(name)」：" + CollageTemplates.builtin.map(\.name).joined(separator: " / "))
                exit(1)
            }
            if let s = template.style, option("--style") == nil {
                project.style = s
                applyLookOptions(&project.style, option: option)
            }
            if let c = template.canvas, option("--canvas") == nil { project.canvas = c }
            // 照片不够模板的格子：和界面里套模板一样，从池子里按分数补（九宫格要 8、9 张）。
            let extra = Array(pool.filter { p in !chosen.contains { $0.id == p.id } }
                .sorted { $0.score > $1.score }.prefix(max(0, template.photoSlots - chosen.count)))
            for p in extra { hints[p.id] = CollageVision.hints(for: p) }
            let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap,
                                            hints: hints, heroID: nil)
            page = CollageTemplates.apply(template, photos: chosen + extra, context: ctx, seed: seed)
            root = page.root
            let s = page.freeform
                ? CollageLayout.Scored(root: root, score: CollageScatter.score(page.items, canvas: project.canvas,
                                                                              photos: photoMap, hints: hints).score,
                                       m: 1, signature: "S", cutFaces: 0, seamFaces: 0)
                : CollageLayout.score(root, m: nil, context: ctx)
            print("模板「\(template.name)」 分 \(fmt(s.score)) · 切脸 \(s.cutFaces) · 缝压脸 \(s.seamFaces)")
        } else if args.contains("--scatter") {
            var spec = CollageScatterSpec()
            if let f = option("--frame").flatMap(CollageItemFrame.init(rawValue:)) { spec.frame = f }
            if let v = option("--tilt").flatMap(Double.init) { spec.tilt = v }
            if let v = option("--tape").flatMap(Double.init) { spec.tape = v }
            let t2 = Date()
            let results = CollageScatter.generate(photos: chosen, spec: spec, context: context, seed: seed)
            guard !results.isEmpty else {
                print("散落版没生成出来")
                exit(1)
            }
            print(String(format: "散落 %.2fs · 备选 %d 个 · 最优分 %.3f · 脸被压 %d · 脸压缝 %d", Date().timeIntervalSince(t2),
                         results.count, results[0].score, results[0].cutFaces, results[0].seamFaces))
            if args.contains("--list") {
                for (i, r) in results.prefix(12).enumerated() {
                    print(String(format: "  #%d 分 %.3f 被压 %d  %@", i, r.score, r.cutFaces, r.signature))
                }
            }
            let alt = max(0, min(results.count - 1, Int(option("--alt") ?? "0") ?? 0))
            root = results[alt].root
            page = CollagePage(root: root, items: results[alt].items ?? [], freeform: true, scatter: spec)
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
            page = CollagePage(root: root)
        }
        // 压字：放在主图那一格（或 --overlay-at 指定的格）。
        if let key = option("--overlay"), var overlay = CollageOverlays.preset(key), !page.freeform {
            if let a = option("--anchor").flatMap(CollageAnchor.init(rawValue:)) { overlay.anchor = a }
            let target = option("--overlay-at").map { $0.compactMap { $0.wholeNumberValue } }
                ?? heroPath(page.root, photoMap: photoMap)
            if let target { page.root.update(at: target) { $0.cell?.overlay = overlay } }
        }
        for raw in args.indices.filter({ args[$0] == "--sticker" && $0 + 1 < args.count }).map({ args[$0 + 1] }) {
            let parts = raw.split(separator: "@").map(String.init)
            guard let first = parts.first, let kind = CollageSticker(rawValue: first) else {
                print("--sticker 参数不对，跳过: \(raw)")
                continue
            }
            let nums = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            var item = CollageItem(kind: .sticker)
            item.sticker = kind
            item.color = kind.defaultColor
            item.width = kind.defaultSize.w
            item.height = kind.defaultSize.h
            item.cx = nums.count > 0 ? nums[0] : 0.5
            item.cy = nums.count > 1 ? nums[1] : 0.5
            item.rotation = nums.count > 2 ? nums[2] : 0
            page.items.append(item)
        }
        project.pages = [page]
        printTable(page.root, project: project, hints: hints)
        if !page.items.isEmpty { printItems(page.items, project: project, hints: hints) }

        // --bench N：界面预览同款渲染（缓存预热后、半尺寸、不走导出解码）跑 N 次的平均耗时。
        if let n = option("--bench").flatMap(Int.init), n > 0 {
            for scale in [0.5, 0.8] {
                var preview = CollageRender.Options(scale: scale)
                preview.includeBleed = false
                _ = CollageRender.render(page: page, project: project, hints: hints, options: preview)
                let t = Date()
                for _ in 0..<n { _ = CollageRender.render(page: page, project: project, hints: hints, options: preview) }
                print(String(format: "预览渲染 scale %.1f · 平均 %.1f ms", scale, Date().timeIntervalSince(t) / Double(n) * 1000))
            }
        }

        var opts = CollageRender.Options(scale: 1)
        opts.debug = debug
        opts.export = true
        let t3 = Date()
        guard let image = CollageRender.render(page: page, project: project, hints: hints, options: opts) else {
            print("渲染失败")
            exit(1)
        }
        print(String(format: "渲染 %dx%d · %.2fs", image.width, image.height, Date().timeIntervalSince(t3)))
        write(image, project: project, out: out)
        exit(0)
    }

    /// --collage-ui / --collage-ops 会改拼图工程（清托盘、换模式、存全局设置）：只在 LABELGUI_DATA_DIR
    /// 指的临时目录里跑 —— 照 README 直接跑会把这个文件夹真实的拼图工程清掉。
    static func requireIsolatedDataDir(_ flag: String) {
        let dir = ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? ""
        guard dir.isEmpty else { return }
        print("\(flag) 会改写拼图工程和全局设置：先设 LABELGUI_DATA_DIR=<临时目录> 再跑（不能碰真实数据）")
        exit(2)
    }

    // MARK: - 相册

    @MainActor
    private static func runAlbum(project base: CollageProject, photoMap: [String: CollagePhotoRef], out: URL,
                                 debug: Bool, seed: UInt64, spreads limit: Int, pdf: Bool, marks: Bool,
                                 dedupe: Bool, binding: CollageBinding) -> Never {
        var project = base
        if project.canvas.seams != .fold { project.canvas = CollageCanvas.albums[0] }
        project.canvas.binding = binding
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

    static func applyLookOptions(_ style: inout CollageStyle, option: (String) -> String?) {
        if let look = option("--look").flatMap(CollageLook.init(rawValue:)) { style.look = look }
        if let v = option("--look-strength").flatMap(Double.init) { style.lookStrength = v }
        if let v = option("--harmonize").flatMap(Double.init) { style.harmonize = v }
    }

    /// 面积最大的照片格。
    static func heroPath(_ root: CollageNode, photoMap: [String: CollagePhotoRef]) -> [Int]? {
        let geo = CollageLayout.geometry(root, in: CollageLayout.IntRect(x0: 0, y0: 0, x1: 10000, y1: 10000), gutter: 0)
        return geo.frames.filter { $0.cell.kind == .photo }.max { $0.rect.area < $1.rect.area }?.path
    }

    /// 自由图层：每个一行（种类、位置、大小、角度；照片带脸有没有被压）。
    private static func printItems(_ items: [CollageItem], project: CollageProject, hints: [String: CollageCrop.Hints]) {
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos { photos[p.id] = p }
        for (i, item) in items.enumerated() {
            let kind: String
            switch item.kind {
            case .photo: kind = "照片 \(item.photoID ?? "空") \(item.frame.label)" + (item.role == .hero ? " 主图" : "")
            case .text: kind = "文字"
            case .sticker: kind = item.sticker.label
            }
            var flag = ""
            if item.kind == .photo {
                let faces = CollageItems.faceSamples(item, canvas: project.canvas, photos: photos, hints: hints)
                let hidden = faces.flatMap { $0 }.filter { p in
                    items[(i + 1)...].contains { CollageItems.contains($0, point: p, canvas: project.canvas) }
                }.count
                if hidden > 0 { flag = " !!脸被压 \(hidden) 点" }
            }
            print(String(format: "  #%d %@ 中心(%.2f,%.2f) %.2fx%.2f %.1f°%@", i, kind, item.cx, item.cy,
                         item.width, item.height, item.rotation, flag))
        }
    }

    /// 全部内置模板套同一组照片，拼成一张总览（每格下面写模板名）。
    @MainActor
    private static func templateSheet(project base: CollageProject, photos: [CollagePhotoRef],
                                      photoMap: [String: CollagePhotoRef], hints: [String: CollageCrop.Hints],
                                      out: URL, only: String?) -> Never {
        let templates = CollageTemplates.builtin.filter { t in
            guard let only else { return true }
            return t.category.contains(only) || t.name.contains(only)
        }
        let cellW = 560
        let cellH = 700
        let cols = 5
        let rows = (templates.count + cols - 1) / cols
        let labelH = 44
        guard let ctx = CollageRender.makeContext(width: cellW * cols, height: (cellH + labelH) * rows) else { exit(1) }
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: (cellH + labelH) * rows))
        let pool = project(base, photos: photos)
        for (i, template) in templates.enumerated() {
            var project = pool
            if let s = template.style { project.style = s }
            if let c = template.canvas { project.canvas = c }
            let ctxLayout = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap,
                                                  hints: hints, heroID: nil)
            let ordered = photos.count >= template.photoSlots ? photos
                : photos + base.photos.filter { p in !photos.contains { $0.id == p.id } }.sorted { $0.score > $1.score }
            let page = CollageTemplates.apply(template, photos: Array(ordered.prefix(max(template.photoSlots, 1))),
                                              context: ctxLayout, seed: 7)
            project.pages = [page]
            let scale = min(Double(cellW - 20) / Double(project.canvas.width),
                            Double(cellH - 20) / Double(project.canvas.height))
            var opts = CollageRender.Options(scale: scale)
            opts.includeBleed = false
            opts.placeholders = true
            let t0 = Date()
            guard let image = CollageRender.render(page: page, project: project, hints: hints, options: opts) else { continue }
            let col = i % cols
            let row = i / cols
            // CG 左下原点：第 0 行在最上面。
            let x = col * cellW + (cellW - image.width) / 2
            let yTop = row * (cellH + labelH) + (cellH - image.height) / 2
            let y = (cellH + labelH) * rows - yTop - image.height
            ctx.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
            let label = "\(i + 1). [\(template.category)] \(template.name) · \(template.photoSlots) 张"
            let spec = CollageTextLine(label, font: .pingfang, weight: .regular, size: 1, color: .white)
            let font = CollageTypeset.font(spec.font, spec.weight, italic: false, size: 20)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
            ctx.textPosition = CGPoint(x: col * cellW + 14, y: (cellH + labelH) * rows - (row + 1) * (cellH + labelH) + 12)
            CTLineDraw(line, ctx)
            print(String(format: "%2d %@ · %@ · %.0fms", i + 1, template.category, template.name,
                         Date().timeIntervalSince(t0) * 1000))
        }
        guard let image = ctx.makeImage() else { exit(1) }
        try? CollageExport.write(image, to: out, format: .jpeg, quality: 0.86, dpi: 72)
        print("模板总览 \(templates.count) 个 → \(out.path)")
        exit(0)
    }

    /// 每个色调套在同一组照片上并排（调色调用）。
    private static func lookSheet(project base: CollageProject, photos: [CollagePhotoRef],
                                  hints: [String: CollageCrop.Hints], out: URL) -> Never {
        let looks = CollageLook.allCases
        let cellW = 520
        var project = base
        project.canvas = CollageCanvas(name: "look", width: 1200, height: 1500)
        project.style.margin = 0
        project.style.gutter = 0.006
        let ids = photos.prefix(2).map(\.id)
        let root: CollageNode = ids.count >= 2
            ? .split(.column, 0.5, .leaf(.photo(ids[0])), .leaf(.photo(ids[1])))
            : .leaf(.photo(ids.first))
        let page = CollagePage(root: root)
        project.pages = [page]
        let scale = Double(cellW) / 1200
        let cellH = Int(1500 * scale)
        let cols = 4
        let rows = (looks.count + cols - 1) / cols
        let labelH = 36
        guard let ctx = CollageRender.makeContext(width: cellW * cols, height: (cellH + labelH) * rows) else { exit(1) }
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: (cellH + labelH) * rows))
        for (i, look) in looks.enumerated() {
            project.style.look = look
            var opts = CollageRender.Options(scale: scale)
            opts.includeBleed = false
            guard let image = CollageRender.render(page: page, project: project, hints: hints, options: opts) else { continue }
            let col = i % cols
            let row = i / cols
            let y = (cellH + labelH) * rows - row * (cellH + labelH) - image.height
            ctx.draw(image, in: CGRect(x: col * cellW, y: y, width: image.width, height: image.height))
            let font = CollageTypeset.font(.pingfang, .regular, italic: false, size: 20)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1),
            ]
            let text = "\(look.label) \(look.rawValue) · 强度 \(String(format: "%.1f", project.style.lookStrength))"
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            ctx.textPosition = CGPoint(x: col * cellW + 12, y: y - 26)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { exit(1) }
        try? CollageExport.write(image, to: out, format: .jpeg, quality: 0.88, dpi: 72)
        print("色调总览 → \(out.path)")
        exit(0)
    }

    private static func project(_ base: CollageProject, photos: [CollagePhotoRef]) -> CollageProject {
        var p = base
        p.pages = []
        return p
    }

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
        CollageCLI.requireIsolatedDataDir("--collage-ui")
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
        if let style = option("--layout") {
            store.setLayoutStyle(style == "scatter" ? .scatter : .grid)
            spin(60) { !store.isSolving }
        }
        if let name = option("--template"), let template = CollageTemplates.find(name) {
            store.applyTemplate(template)
            spin(3)
        }
        if let title = option("--title") { store.setTitle(title) }
        if let sub = option("--subtitle") { store.setSubtitle(sub) }
        if let look = option("--look").flatMap(CollageLook.init(rawValue:)) {
            var st = store.project.style
            st.look = look
            store.setStyle(st)
        }
        if let key = option("--overlay"), let overlay = CollageOverlays.preset(key), let root = store.root,
           let hero = CollageCLI.heroPath(root, photoMap: store.photoMap) {
            store.setOverlay(overlay, at: hero)
            store.selection = hero
        }
        if let root = store.root {
            let kinds = root.leafPaths().map { p -> String in
                let cell = root.node(at: p)?.cell
                let kind = cell?.kind == .text ? "文字" : (cell?.photoID ?? "空")
                return p.map(String.init).joined() + "=" + kind
            }
            print("格子: " + kinds.joined(separator: " "))
        }
        // --page N：相册看第 N 个跨页（从 0 起）；选格子要在换页之后（换页会清掉选中）。
        if let p = option("--page").flatMap(Int.init), store.project.pages.indices.contains(p) {
            store.pageIndex = p
        }
        if let sel = option("--select") {
            store.selection = sel.compactMap { $0.wholeNumberValue }
            if args.contains("--crop"), let path = store.selection { store.enterCropEdit(path) }
        }
        if let i = option("--select-item").flatMap(Int.init), store.items.indices.contains(i) {
            store.selectItem(store.items[i].id)
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

/// LABELGUI_DATA_DIR=<临时目录> LabelGUI --collage-ops <photo_dir> --ops "swap:00>10,move:00>11:left,remove:10,
///     flip:r,ratio:0=0.4,lock:00,regen,framing:10=half,shape:10=circle,contain:10,crop:10=0.5;0.4;2,
///     text:00=bottom,place:DSCF7209>11:top,undo,redo,savetpl:名字,applytpl:名字,exporttpl:/path.json,
///     importtpl:/path.json,frombatch:DSCF7209;DSCF7211,render:文件名" [--out 目录] [--count 6]
/// 路径写成数字串（"10" = 根的第二个孩子的第一个孩子），根节点写 r；一步里的几个数用分号分（逗号分步）。
/// 每步打印版式树、图层（~ 自动撒的，@7232 贴在那张相纸上）和撤销栈。出图不走导出：renderclean = 界面
/// 预览同款，renderexport = 导出同款（成品尺寸带出血）。必须设 LABELGUI_DATA_DIR（起手会清托盘）。
enum CollageOpsScript {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        CollageCLI.requireIsolatedDataDir("--collage-ops")
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
                if cell?.contain == true { tag += cell?.containBlur == true ? "/完整+模糊" : "/完整" }
                if let c = cell?.crop { tag += String(format: "/裁%.2f,%.2f×%.1f", c.cx, c.cy, c.zoom) }
                if let o = cell?.overlay { tag += "/压字(\(o.anchor.label))" }
                return (p.isEmpty ? "r" : p.map(String.init).joined()) + "=" + tag
            }
            let all = store.items
            let items = all.enumerated().map { (i, it) -> String in
                var name: String
                switch it.kind {
                case .photo: name = (it.photoID.map { String($0.suffix(4)) } ?? "空") + it.frame.label
                case .text: name = it.sourceCell.map { "字格\($0)" } ?? "手写"
                case .sticker: name = it.sticker.label
                }
                // ~ = 自动撒的；@7232 = 贴在那张相纸上
                if it.generated { name = "~" + name }
                if let a = it.attach {
                    let host = all.first { $0.id == a.to }?.photoID.map { String($0.suffix(4)) } ?? "?"
                    name += "@" + host
                }
                let sel = it.id == store.selectedItem ? "*" : ""
                return String(format: "%@%d:%@(%.2f,%.2f %.0f°)", sel, i, name, it.cx, it.cy, it.rotation)
            }
            var head = store.isFreeform ? "散落" : root.signature + "  |  " + leaves.joined(separator: " ")
            if store.isFreeform, let spec = store.page?.scatter { head += "[\(spec.frame.label)]" }
            if store.page?.gridRoot != nil { head += "(记着网格)" }
            if store.layoutStyle != store.effectiveLayoutStyle { head += "(偏好\(store.layoutStyle.label))" }
            return head + (items.isEmpty ? "" : "  || 图层 " + items.joined(separator: " "))
        }
        func itemID(_ s: String) -> UUID? {
            guard let i = Int(s), store.items.indices.contains(i) else { return nil }
            return store.items[i].id
        }

        // 读回来的工程是什么画布（核对旧工程的容错解码 / 升级，下面马上会重置）。
        let loaded = store.project.canvas
        print("载入  \(loaded.name) \(loaded.width)x\(loaded.height) seams=\(loaded.seams.rawValue) · \(store.project.pages.count) 页")

        // 起手：单张 3:4、托盘 = 精选+可用，排一版（每次都从头来，脚本结果可复现）。
        store.clearTray()
        store.setMode(.single)
        store.setLayoutStyle(.grid)
        store.setCanvas(CollageCanvas.social[0])
        store.setStyle(CollageStyle())
        store.setTitle(option("--title") ?? "")
        store.setSubtitle(option("--subtitle") ?? "")
        store.importVerdicts(batch: batch, includeUsable: true)
        spin(20) { !store.project.photos.isEmpty && store.busyText == nil }
        store.solve(photoIDs: ["DSCF7232", "DSCF7208", "DSCF7222", "DSCF7215", "DSCF7212", "DSCF7214"]
            .prefix(Int(option("--count") ?? "6") ?? 6).map { $0 })
        idle()
        print("起始  " + describe())

        // 参数写错一个字：打印出来跳过这一步，不能下标越界整个崩掉。
        func at(_ a: [String], _ i: Int) -> String? { a.indices.contains(i) ? a[i] : nil }
        func nums(_ s: String?) -> [Double] { (s ?? "").split(separator: ";").compactMap { Double($0) } }
        func pair(_ s: String, _ sep: Character) -> (String, String)? {
            let kv = s.split(separator: sep, maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }
        let edges: [String: CollageLayout.Edge] = ["left": .left, "right": .right, "top": .top, "bottom": .bottom]

        for raw in (option("--ops") ?? "").split(separator: ",") {
            let op = raw.trimmingCharacters(in: .whitespaces)
            guard !op.isEmpty else { continue }
            let parts = op.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""
            var ok = true
            switch name {
            case "swap":
                if let (a, b) = pair(arg, ">") { store.swap(path(a), path(b)) } else { ok = false }
            case "move":
                if let (a, rest) = pair(arg, ">"), let (b, e) = pair(rest, ":"), let edge = edges[e] {
                    store.move(from: path(a), to: path(b), edge: edge)
                } else { ok = false }
            case "place":
                if let (id, rest) = pair(arg, ">"), let target = at(rest.split(separator: ":").map(String.init), 0) {
                    let tail = rest.split(separator: ":").map(String.init)
                    store.place(photoID: id, at: path(target), edge: at(tail, 1).flatMap { edges[$0] })
                } else { ok = false }
            case "remove":
                store.removeCell(path(arg))
            case "flip":
                store.flipGutter(path(arg))
            case "refit":
                store.refit()
            case "ratio":
                if let (p, v) = pair(arg, "="), let r = Double(v) {
                    store.beginContinuousEdit()
                    store.setRatio(r, at: path(p))
                    store.endContinuousEdit()
                } else { ok = false }
            case "lock":
                store.selection = path(arg)
                store.toggleLock()
            case "sel":
                store.selection = path(arg)
            case "regen":
                store.regenerate()
                idle()
            case "framing":
                if let (p, v) = pair(arg, "="),
                   let f = ["auto": CollageFraming.auto, "full": .full, "half": .half, "close": .close][v] {
                    store.selection = path(p)
                    store.setFraming(f)
                } else { ok = false }
            case "shape":
                if let (p, v) = pair(arg, "=") {
                    store.selection = path(p)
                    store.setShape(CollageShape(rawValue: v))
                } else { ok = false }
            case "contain":
                store.selection = path(arg)
                store.setContain(true)
            case "effect":
                // effect:路径=预设[@行号]：文字格（或照片上压的字）第几行（默认 0）套花字。预设：none outline
                // outline-dark shadow glow neon tape pill gold
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                let spec = (at(kv, 1) ?? "").split(separator: "@").map(String.init)
                let lineIndex = Int(at(spec, 1) ?? "0") ?? 0
                if let p = at(kv, 0), let preset = at(spec, 0).flatMap(CollageTextEffects.preset),
                   let cell = store.root?.node(at: path(p))?.cell {
                    // 和界面里点预设走同一个入口（照片上的字会连深浅一起定）。
                    if cell.kind == .text {
                        store.applyTextEffect(preset, line: lineIndex, target: .cell(path(p), store.page?.id))
                    } else if cell.overlay != nil {
                        store.applyTextEffect(preset, line: lineIndex,
                                              target: .overlay(path(p), cell.photoID, store.page?.id))
                    } else { ok = false }
                } else { ok = false }
            case "margin":
                // margin:0（外边距，相对短边；0 = 零边距，照片铺进出血）
                if let v = Double(arg) {
                    var st = store.project.style
                    st.margin = v
                    store.setStyle(st, coalesce: false)
                } else { ok = false }
            case "containblur":
                // containblur:10 = 那一格完整显示，四周用本图模糊填
                store.selection = path(arg)
                store.setContainBlur(true)
            case "bg":
                // bg:solid | fromPhoto | blurPhoto | gradient（可带纸色 bg:blurPhoto=FFFFFF）
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if let m = at(kv, 0).flatMap(CollageBackgroundMode.init(rawValue:)) {
                    var st = store.project.style
                    st.backgroundMode = m
                    if let hex = at(kv, 1).flatMap({ UInt32($0, radix: 16) }) { st.background = CollageColor(hex: hex) }
                    store.setStyle(st, coalesce: false)
                } else { ok = false }
            case "crop":
                let n = nums(pair(arg, "=")?.1)
                if let (p, _) = pair(arg, "="), n.count == 3 {
                    store.enterCropEdit(path(p))
                    store.setCrop(CollageCropOverride(cx: n[0], cy: n[1], zoom: n[2]), at: path(p))
                    store.exitCropEdit()
                } else { ok = false }
            case "text":
                if let (p, e) = pair(arg, "=") {
                    store.selection = p == "none" ? nil : path(p)
                    let edge = edges[e] ?? .bottom
                    store.addTextCell(edge: edge, vertical: edge == .left || edge == .right)
                } else { ok = false }
            case "overlay":
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if let p = at(kv, 0) {
                    store.selection = path(p)
                    let key = at(kv, 1) ?? "none"
                    store.setOverlay(key != "none" ? CollageOverlays.preset(key) : nil, at: path(p))
                } else { ok = false }
            case "anchor":
                if let (p, v) = pair(arg, "="), let a = CollageAnchor(rawValue: v) {
                    store.updateOverlay(at: path(p)) { $0.anchor = a }
                } else { ok = false }
            case "overlaypos":
                let n = nums(pair(arg, "=")?.1)
                if let (p, _) = pair(arg, "="), n.count == 2 {
                    store.beginContinuousEdit()
                    store.setOverlayPosition(x: n[0], y: n[1], at: path(p))
                    store.endContinuousEdit()
                } else { ok = false }
            case "overlaytext":
                if let (p, v) = pair(arg, "="), let o = store.root?.node(at: path(p))?.cell?.overlay {
                    var t = o.text
                    if !t.lines.isEmpty { t.lines[0].text = v }
                    let pid = store.root?.node(at: path(p))?.cell?.photoID
                    store.updateText(t, target: .overlay(path(p), pid, store.page?.id))
                } else { ok = false }
            case "look":
                var st = store.project.style
                st.look = CollageLook(rawValue: arg) ?? .none
                store.setStyle(st)
            case "strength":
                var st = store.project.style
                st.lookStrength = Double(arg) ?? st.lookStrength
                store.setStyle(st)
            case "harmonize":
                var st = store.project.style
                st.harmonize = Double(arg) ?? 0
                store.setStyle(st)
            case "subtitle":
                store.setSubtitle(arg)
            case "layout":
                store.setLayoutStyle(arg == "scatter" ? .scatter : .grid)
                idle()
            case "layoutnowait":
                store.setLayoutStyle(arg == "scatter" ? .scatter : .grid)
            case "wait":
                idle()
            case "autolayout":
                store.autoLayout(count: Int(arg) ?? 6)
                idle()
            case "autolayoutnowait":
                store.autoLayout(count: Int(arg) ?? 6)
            case "relayout":
                store.relayout(photoIDs: (store.page?.photoIDs ?? []) + arg.split(separator: ";").map(String.init))
                idle()
            case "untray":
                store.removeFromTray(arg)
            case "frombatch":
                // 批量页多选「拼图 (N)」：frombatch:DSCF7209;DSCF7211（相册里应该新开一个跨页）。
                store.importFromBatch(ids: arg.split(separator: ";").map(String.init), batch: batch, layout: true)
                spin(20) { store.busyText == nil }
                idle()
            case "sticker":
                if let k = CollageSticker(rawValue: arg) { store.addSticker(k) } else { ok = false }
            case "itemtext":
                store.addItemText()
            case "additem":
                let ab = arg.split(separator: "@").map(String.init)
                let n = nums(at(ab, 1) ?? "0.5;0.5")
                if let id = at(ab, 0), n.count == 2 {
                    store.addPhotoItem(id, at: CGPoint(x: n[0], y: n[1]))
                } else { ok = false }
            case "selitem":
                store.selectItem(itemID(arg))
            case "itemmove":
                let n = nums(pair(arg, "=")?.1)
                if let (i, _) = pair(arg, "="), let id = itemID(i), n.count == 2 {
                    store.beginContinuousEdit()
                    store.setItemGeometry(id) { $0.cx = n[0]; $0.cy = n[1] }
                    store.endContinuousEdit()
                } else { ok = false }
            case "itemrot":
                if let (i, v) = pair(arg, "="), let id = itemID(i), let deg = Double(v) {
                    store.updateItem(id) { $0.rotation = deg }
                } else { ok = false }
            case "itemsize":
                if let (i, v) = pair(arg, "="), let id = itemID(i), let k = Double(v) {
                    store.updateItem(id) { $0.width *= k; $0.height *= k }
                } else { ok = false }
            case "itemfront":
                if let id = itemID(arg) { store.moveItemInStack(id, toFront: true) } else { ok = false }
            case "itemback":
                if let id = itemID(arg) { store.moveItemInStack(id, toFront: false) } else { ok = false }
            case "itemdel":
                if let id = itemID(arg) { store.deleteItem(id) } else { ok = false }
            case "itemdup":
                if let id = itemID(arg) { store.duplicateItem(id) } else { ok = false }
            case "tplthumbs":
                store.renderTemplateThumbs()
                spin(120) { !store.templateThumbsBusy && store.templateThumbs.count >= store.allTemplates.count }
                print("  模板缩略图 \(store.templateThumbs.count)/\(store.allTemplates.count)")
                // 抽两个自带画布的模板看比例（相册里应该是跨页的比例）。
                for name in ["封面 · 刊头大图", "手账 · 黑卡相角"] {
                    if let img = store.templateThumbs[name] {
                        print("  「\(name)」缩略图 \(Int(img.size.width))x\(Int(img.size.height))")
                    }
                }
            case "altthumb":
                // altthumb:序号=文件名：把第几个备选的缩略图存下来（核对和点下去的一致）。
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                spin(15) { !store.alternatives.isEmpty && store.alternativeThumbs.count == store.alternatives.count }
                if let i = at(kv, 0).flatMap(Int.init), let file = at(kv, 1), store.alternativeThumbs.indices.contains(i),
                   let cg = store.alternativeThumbs[i].cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    try? CollageExport.write(cg, to: outDir.appendingPathComponent(file + ".png"), format: .png,
                                             quality: 1, dpi: 72)
                    print("  备选缩略图 \(i) → \(file).png（共 \(store.alternativeThumbs.count) 个）")
                } else { ok = false }
            case "undo":
                store.undo()
            case "redo":
                store.redo()
            case "savetpl":
                store.saveTemplate(named: arg, fitAspects: true)
            case "applytpl":
                if let t = store.allTemplates.first(where: { $0.name == arg }) { store.applyTemplate(t) } else { ok = false }
            case "exporttpl":
                store.exportTemplates(to: URL(fileURLWithPath: arg))
            case "importtpl":
                store.importTemplates(from: URL(fileURLWithPath: arg))
            case "mode":
                store.setMode(arg == "album" ? .album : .single)
            case "canvas":
                store.setCanvas(CollageCLI.canvas(arg))
            case "binding":
                // binding:glued | binding:layflat（相册装订方式）
                if let b = CollageBinding(rawValue: arg) {
                    store.setBinding(b)
                    print("  装订 \(store.project.canvas.binding.label) · 中缝带每侧 "
                          + String(format: "%.0fpx（%.1fmm）", store.project.canvas.foldBand,
                                   store.project.canvas.foldBand / store.project.canvas.dpi * 25.4)
                          + (store.notice.map { " · 提示: \($0)" } ?? ""))
                } else { ok = false }
            case "upscale":
                // upscale 或 upscale:1.0（阈值，默认 1.2）：打印放大超过阈值的照片（全部页）。
                let limit = Double(arg) ?? CollageStore.upscaleLimit
                let issues = store.upscaleIssues(limit: limit)
                print("  放大超过 \(Int((limit * 100).rounded()))%: " + (issues.isEmpty ? "无" : issues.map {
                    "第\($0.page + 1)页 \($0.photoID.suffix(4)) \(Int(($0.factor * 100).rounded()))%"
                }.joined(separator: " · ")))
            case "crossfold":
                let pages = store.crossFoldPages()
                print("  压中缝的跨页: " + (pages.isEmpty ? "无" : pages.map { "\($0 + 1)" }.joined(separator: " ")))
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
                if let (a, b) = pair(arg, "="), let i = Int(a), let d = Int(b) { store.movePage(i, by: d) } else { ok = false }
            case "tonext":
                store.selection = path(arg)
                store.moveSelectedPhoto(toPage: store.pageIndex + 1)
            case "exportname":
                store.exportName = arg
            case "export":
                // 走导出全流程（无头模式下不会在访达里弹窗口）。
                store.exportOptions.outputPath = arg
                store.export()
                spin(300) { !store.isExporting }
                print("  " + store.progressText)
                let found = (try? FileManager.default.subpathsOfDirectory(atPath: arg)) ?? []
                print("  输出: " + found.sorted().joined(separator: " "))
            case "render", "renderclean", "renderexport":
                // render = 半尺寸 + 调试框；renderclean = 和界面预览一样（占位、不带出血）；
                // renderexport = 和导出一样（成品尺寸、带出血、不画占位）。
                var opts = CollageRender.Options(scale: name == "renderexport" ? 1 : 0.5)
                opts.includeBleed = name == "renderexport"
                opts.debug = name == "render"
                opts.placeholders = name == "renderclean"
                opts.export = name == "renderexport"
                if let page = store.page,
                   let image = CollageRender.render(page: page, project: store.project, hints: store.hints, options: opts) {
                    let url = outDir.appendingPathComponent(arg + ".jpg")
                    try? CollageExport.write(image, to: url, format: .jpeg, quality: 0.85, dpi: 72)
                    let vars = CollageTypeset.variables(project: store.project, root: page.root, photos: store.photoMap,
                                                        pagePhotoIDs: page.photoIDs, pageID: page.id)
                    print("  出图 \(url.lastPathComponent) · 第 \(store.pageIndex + 1)/\(store.project.pages.count) 页 · {no}=\(vars["no"] ?? "")")
                }
            default:
                print("未知操作 \(op)")
                continue
            }
            if !ok {
                print("参数不对，跳过: \(op)")
                continue
            }
            let flags = "撤销\(store.undoDepth) 重做\(store.canRedo ? "✓" : "✗")"
            let pages = store.isAlbum
                ? "  跨页 \(store.pageIndex + 1)/\(store.project.pages.count): " + store.project.pages.map { "\($0.photoIDs.count)" }.joined(separator: "-")
                : ""
            print("\(op)  →  " + describe() + "  [\(flags)]" + pages + (store.lastError.map { "  错误: \($0)" } ?? ""))
        }
        store.flushSaves()
        exit(0)
    }
}
