import Foundation
import AppKit
import PDFKit
import CoreText
import SwiftUI
import CryptoKit

/// 无头拼图：LabelGUI --collage <photo_dir> [选项]
///
///   选片   --ids a,b,c | --auto N（默认 6，按分数+多样性从精选/可用里挑）
///   画布   --canvas 3:4 | 1:1 | grid9 | 4:5 | 9:16 | 16:9 | carousel3 | a4 | album30 | album25 | album20 | album3020 | 宽x高
///   版式   --template <名字> | --alt K（第 K 个备选，默认 0）| --list（打印前 12 个备选）
///   样式   --style grid|white|dark|editorial|chinese|film|polaroid|gallery|tinted|frosted|gradient|airy|cinema|journal|cover
///          |fashion|minimal|newspaper|swiss|weddingFineArt|weddingCanon（时尚刊、留白杂志、报纸、瑞士、婚礼 fine-art、古典版心；
///          两个婚礼预设按画布 / 册子尺寸算边距）
///          --margin 0.045 --gutter 0.011 --no-tight --title 标题 --seed N --tries N
///          --bg solid|fromPhoto|blurPhoto|gradient（底色：纯色 / 主图取色 / 主图模糊 / 渐变）
///   色调   --look film|airy|faded|cinema|cool|mono|sepia|newsprint|contrastMono|muted|fineArt [--look-strength 0.8]
///          [--harmonize 0.6]
///   压字   --overlay masthead|corner|subtitle|vertical|number|script|handwrite [--overlay-at 路径] [--anchor top…]
///          [--overlay-behind]（这块字在人后：人物挡字；定死位置时「自动」取景顺手换成「封面」，打印每块字的决定）
///          --overlay-front（所有字块放回人前）--subtitle 副标题
///   散落   --scatter [--frame polaroid|white|none|film|mounts] [--tilt 6] [--tape 0.6]
///   贴纸   --sticker washi@0.5,0.1,20（种类@中心x,y,旋转；可多次；另有 barcode 装饰条码、greasePencil 油性笔圈）
///   模板册 --template-sheet 出图.jpg [--only 分类或名字里的几个字]（全部内置模板套这组照片，拼成一张总览）
///          --look-sheet 出图.jpg（每个色调套这组照片并排）
///   相册   --album [--spreads N] [--pdf] [--marks] [--no-dedupe] [--binding layflat|glued]（装订：平铺对裱 / 胶装锁线）
///          [--album-theme classic|fineArt]（fineArt = 婚礼 fine-art 编排：章节开篇、疏密、呼吸页、竖图成对；没给 --style
///          就用 fine-art 样式按册子尺寸算边距）[--no-chapter-mono]（不整章转黑白）
///   刊头   --masthead 刊名（空 = 标题转大写 / 拼音）--issue 期号（空 = 页码）
///   成套   --kit fashionIssue|contactRoll|weddingAlbum（或 出一期 / 按卷出印样 / 整本婚礼相册）：出全部页 名_01…
///          --cover-step N（出一期：封面用第 N+1 个主图候选，「换封面」同一套候选；负数按 0）
///   输出   --out 文件或目录（九宫格/轮播/相册写目录）  --debug 叠人脸框/安全区/路人/切缝
///   调试   --sim（打印分数最高 20 张两两的画面距离就退出）--bench N（预览同款渲染跑 N 次的平均耗时）
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
        // 主体蒙版缓存和界面同一个地方（场次目录下 collage_masks/）。
        CollageMasks.setDirectory(store.sessionDir.appendingPathComponent("collage_masks"))
        let facts = CollageBridge.Facts(batch: store)
        let pool = store.items.filter { $0.verdict != .reject }.compactMap { CollageBridge.ref(from: $0, facts: facts) }
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
        project.masthead = option("--masthead") ?? ""
        project.issue = option("--issue") ?? ""
        let out = URL(fileURLWithPath: option("--out") ?? "collage.jpg")
        let debug = args.contains("--debug")
        let seed = UInt64(option("--seed") ?? "7") ?? 7
        let tries = Int(option("--tries") ?? "20000") ?? 20000
        var photoMap: [String: CollagePhotoRef] = [:]
        for p in pool { photoMap[p.id] = p }

        if args.contains("--album") {
            if let t = option("--album-theme") {
                guard let theme = CollageAlbumTheme(rawValue: t) else {
                    print("没有编排主题「\(t)」：" + CollageAlbumTheme.allCases.map(\.rawValue).joined(separator: " / "))
                    exit(1)
                }
                project.albumTheme = theme
            }
            project.albumChapterMono = !args.contains("--no-chapter-mono")
            runAlbum(project: project, photoMap: photoMap, out: out, debug: debug, seed: seed,
                     style: option("--style") == nil,
                     spreads: Int(option("--spreads") ?? "0") ?? 0,
                     pdf: args.contains("--pdf"), marks: args.contains("--marks"),
                     dedupe: !args.contains("--no-dedupe"),
                     binding: option("--binding").flatMap(CollageBinding.init(rawValue:)) ?? .layflat)
        }

        if let name = option("--kit") {
            guard let kit = CollageKitID.find(name) else {
                print("没有成套「\(name)」：" + CollageKitID.allCases.map { "\($0.rawValue)（\($0.name)）" }.joined(separator: " / "))
                exit(1)
            }
            runKit(kit, project: project, batch: store, out: out, seed: seed,
                   coverStep: max(0, Int(option("--cover-step") ?? "0") ?? 0))
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
        // 压字：放在主图那一格（或 --overlay-at 指定的格）。--overlay-behind = 这块字放到人后（人物挡字）：
        // 和检视器的开关同一条规矩 —— 定死位置的字、这一格还是「自动」取景且没裁过，顺手换成「封面」取景。
        if let key = option("--overlay"), var overlay = CollageOverlays.preset(key), !page.freeform {
            if let a = option("--anchor").flatMap(CollageAnchor.init(rawValue:)) { overlay.anchor = a }
            let behind = args.contains("--overlay-behind")
            if behind { overlay.layer = .behindSubject }
            let fixed = overlay.anchor != .auto && !overlay.anchor.isSide
            let target = option("--overlay-at").map { $0.compactMap { $0.wholeNumberValue } }
                ?? heroPath(page.root, photoMap: photoMap)
            if let target {
                page.root.update(at: target) { node in
                    guard var cell = node.cell else { return }
                    cell.overlay = overlay
                    if behind, fixed, cell.framing == .auto, cell.crop == nil, !cell.contain {
                        cell.framing = .cover
                        cell.coverAuto = true
                    }
                    node.cell = cell
                }
            }
        }
        // --overlay-front：所有字块都放到人前（关掉模板里的人物挡字，对照用）。
        if args.contains("--overlay-front") {
            for leaf in page.root.leafPaths() {
                page.root.update(at: leaf) { node in
                    guard var cell = node.cell, !cell.overlays.isEmpty else { return }
                    cell.overlays = cell.overlays.map { o in
                        var out = o
                        out.layer = .front
                        return out
                    }
                    node.cell = cell
                }
            }
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
        printTable(page, project: project, hints: hints)
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
        // 走人物挡字 / 封面取景 / 抠图的格子：出图时记下每块字的决定，打印出来（别的出图不挂记录，和以前一样）。
        let covered = page.root.leafPaths().contains { path in
            page.root.node(at: path)?.cell.map(CollageCover.applies(to:)) ?? false
        }
        let report: CollageRender.RenderReport? = covered ? CollageRender.RenderReport() : nil
        opts.report = report
        let t3 = Date()
        guard let image = CollageRender.render(page: page, project: project, hints: hints, options: opts) else {
            print("渲染失败")
            exit(1)
        }
        print(String(format: "渲染 %dx%d · %.2fs", image.width, image.height, Date().timeIntervalSince(t3)))
        for t in report?.texts ?? [] {
            guard let o = t.occlusion else { continue }
            print("  [\(t.owner)] \(t.layer) · " + occlusionLine(o))
        }
        for c in report?.crops ?? [] where c.framing == CollageFraming.cover.rawValue {
            let w = c.window
            print(String(format: "  [%@] 封面取景 %.3f,%.3f %.3fx%.3f", c.owner, w.minX, w.minY, w.width, w.height))
        }
        write(image, project: project, out: out)
        exit(0)
    }

    /// 人物挡字一块字的读数（ops 的 dumptexts、--collage 单张出图共用）。
    static func occlusionLine(_ o: CollageRender.OcclusionRecord) -> String {
        let per = o.perLetter.map { String(format: "%.0f", $0 * 100) }.joined(separator: " ")
        let lines = o.perLine.map { String(format: "%.0f", $0 * 100) }.joined(separator: " ")
        let head = o.measured
            ? String(format: "人物挡字：总 %.1f%%（上限 %.0f%%%@）首 %.1f%% 末 %.1f%% 过半 %d/%d 个 · 每个字母 [%@] · 每行 [%@]",
                     o.total * 100, o.limit * 100, o.rule == "total" ? "，只限总量" : "", o.first * 100, o.last * 100,
                     o.heavy, o.perLetter.count, per, lines)
            : "人物挡字：没量"
        let eyes = o.eyesClear.map { $0 ? " · 眼睛没被字压" : " · 眼睛被字压了" } ?? ""
        let clamp = o.eyeClamp.map { ["bottom": "，照片下沿卡住", "top": "，头顶上面天不够", "face": "，脸太大"][$0] ?? "" } ?? ""
        let below = o.eyeBelow.map { String(format: " · 眼睛在基线下 %.1f%%%@", $0 * 100, o.eyeFar ? "（远\(clamp)）" : "") } ?? ""
        return head + " → \(o.decision)\(o.moved ? "·挪开头" : "")（要求 \(o.requested)）" + eyes + below
            + (o.reason.map { " · " + $0 } ?? "")
            + " · 头顶 \(o.headTopSource) · \(o.faces) 张脸"
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
                                 debug: Bool, seed: UInt64, style: Bool = false, spreads limit: Int, pdf: Bool,
                                 marks: Bool, dedupe: Bool, binding: CollageBinding) -> Never {
        var project = base
        if project.canvas.seams != .fold { project.canvas = CollageCanvas.albums[0] }
        project.canvas.binding = binding
        var hints: [String: CollageCrop.Hints] = [:]
        for p in project.photos { hints[p.id] = CollageVision.hints(for: p) }
        // fine-art 编排：没指定样式就用 fine-art 样式（边距按这本册子算）；亮度、黑白从路人信息补进 ref。
        var photos = project.photos
        var photoMap = photoMap
        // --style weddingFineArt / weddingCanon：边距按这本册子重算（预设里是 30×30 的数）；别的样式原样。
        project.style = CollageStyleFineArt.adapted(project.style, to: project.canvas) ?? project.style
        if project.albumTheme == .fineArt {
            if style { project.style = CollageStyleFineArt.style(for: project.canvas) }
            for i in photos.indices {
                photos[i].meanLuma = photos[i].meanLuma ?? hints[photos[i].id]?.meanLuma
                photos[i].isMonochrome = photos[i].isMonochrome ?? hints[photos[i].id]?.isMonochrome
                photoMap[photos[i].id] = photos[i]
            }
            project.photos = photos
        }
        let context = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap,
                                            hints: hints, heroID: nil)
        let plan = CollageAlbum.plan(photos, dedupe: dedupe, theme: project.albumTheme,
                                     chapterMono: project.albumChapterMono, title: project.title)
        let used = plan.spreads.reduce(0) { $0 + $1.photos.count }
        // fine-art：拿掉的分开说（同一场只留精选一直开着，「相似」才是 --no-dedupe 关的那个）。
        let droppedText = plan.theme == .fineArt ? CollageStyleFineArt.droppedNote(photos, plan: plan)
            : "相似拿掉 \(plan.dropped.count)"
        print("相册 \(project.canvas.name) · \(project.canvas.width)x\(project.canvas.height)px · 出血 \(project.canvas.bleed)px · \(project.photos.count) 张 → 用 \(used) 张（\(droppedText)）→ \(plan.spreads.count) 个跨页")
        if !plan.dropped.isEmpty { print("  拿掉: " + plan.dropped.map(\.id).joined(separator: " ")) }
        let pages = CollageAlbum.build(plan, context: context, seed: seed)
        for (i, spread) in plan.spreads.enumerated() {
            let s = CollageLayout.score(pages[i].root, m: nil, context: context)
            let kind = spread.fineArt.map { "\(spread.kind.rawValue)/\($0.kind.rawValue) 第\($0.chapter + 1)章" } ?? spread.kind.rawValue
            print("  跨页 \(i + 1) [\(kind)]: \(spread.photos.map(\.id).joined(separator: " ")) · 切脸 \(s.cutFaces) · 中缝压脸 \(s.seamFaces)"
                  + (pages[i].look.map { " · 色调 \($0.look.rawValue)" } ?? ""))
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
            // 整页渲染（不是只画版式树）：带自由图层的跨页也不丢东西（相册编排以后会生成图层）。
            guard let image = CollageRender.render(page: pages[i], project: project, hints: hints, options: opts),
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

    // MARK: - 一键成套

    /// --kit：和界面里「一键成套」同一个生成函数；出全部页（单页 = --out，多页 = 名_01、名_02…；相册跨页
    /// 也按页写）。还没做的成套打印一句、退出码 1。
    @MainActor
    private static func runKit(_ kit: CollageKitID, project base: CollageProject, batch: BatchStore, out: URL,
                               seed: UInt64, coverStep: Int = 0) -> Never {
        var hints: [String: CollageCrop.Hints] = [:]
        for p in base.photos { hints[p.id] = CollageVision.hints(for: p) }
        let items = batch.items
        let context = CollageKits.Context(project: base, tray: base.photos, batchItems: { items },
                                          facts: CollageBridge.Facts(batch: batch), hints: hints, seed: seed,
                                          coverStep: coverStep)
        let t0 = Date()
        guard let project = kit.generate(context), !project.pages.isEmpty else {
            print("成套「\(kit.name)」没出来（托盘里没有能用的照片），没有出图")
            exit(1)
        }
        print(String(format: "成套「%@」%d 页 · %@ · %.2fs", kit.name, project.pages.count, project.canvas.name,
                     Date().timeIntervalSince(t0)))
        for p in project.photos where hints[p.id] == nil { hints[p.id] = CollageVision.hints(for: p) }
        let stem = out.deletingPathExtension()
        let ext = out.pathExtension.isEmpty ? "jpg" : out.pathExtension
        for (i, page) in project.pages.enumerated() {
            var opts = CollageRender.Options(scale: 1)
            opts.export = true
            let url = project.pages.count == 1 ? out : URL(fileURLWithPath: stem.path + String(format: "_%02d.", i + 1) + ext)
            printTable(page, project: project, hints: hints)
            if !page.items.isEmpty { printItems(page.items, project: project, hints: hints) }
            guard let image = CollageRender.render(page: page, project: project, hints: hints, options: opts) else {
                print("第 \(i + 1) 页渲染失败")
                continue
            }
            write(image, project: project, out: url)
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
    private static func printTable(_ page: CollagePage, project: CollageProject, hints: [String: CollageCrop.Hints]) {
        let root = page.root
        let canvas = project.canvas
        let style = project.style
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos { photos[p.id] = p }
        let geo = CollageLayout.pageGeometry(root, canvas: canvas, style: style)
        // 封面取景、人物挡字、抠图的格子：取景按 CollageCover 的决定（真画出来的那个，同 CollageStore.upscaleIssues）；
        // 这一页没有这种格子就照旧（不算占位符、底色）。
        let covered = geo.frames.contains { CollageCover.applies(to: $0.cell) }
        let paged = covered ? CollageLooks.project(project, page: page) : project
        let ids = page.photoIDs
        let pageVars = covered ? CollageTypeset.variables(project: paged, root: root, photos: photos, pagePhotoIDs: ids,
                                                          pageID: page.id) : [:]
        let bg = covered ? CollageRender.backgroundColor(project: paged, pagePhotoIDs: ids, photos: photos)
            : style.background
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
                let w = CollageCover.applies(to: f.cell)
                    ? CollageRender.cellWindow(cell: f.cell, frameRect: f.rect.cgRect, project: paged, photo: p,
                                               framing: framing, hints: hints[id],
                                               vars: CollageTypeset.cellVariables(pageVars, photo: p), background: bg)
                    : CollageCrop.window(for: p, cell: f.cell, cellAspect: CollageCrop.aspect(of: area),
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

/// LabelGUI --collage-ui <photo_dir> <out.png> [--album] [--tab 版式|样式|文字|水印|导出] [--select 路径如 10]
/// [--crop] [--overlay-index N] [--size 1440x900] [--adopt photos|page[:水印页预设名]] [--inspector-width 300] [--notice 提示文字]
/// [--contact-frames]（印样的「逐帧」一开始就展开）[--light]（浅色外观）[--ax-dump]
/// [--tray-filter all|unused|used] [--tray-select ID,ID]（托盘的筛选、多选）
/// [--perf place|gutter|slider|title|all]（截完图接着跑这个场景，打印每个视图 body 重算几次、
/// store / 预览 / 缩略图各发了几次 objectWillChange、出了几张预览：CollagePerf）
/// 截图前先改工程（都可选）：--relayout [--count 6]（托盘重新自动排版，几张；工程里还没有版式时也排）、
/// --layout grid|scatter、--template <模板名>、--title 标题、--subtitle 副标题、--look <色调>、
/// --overlay <压字预设>（放在主图那一格并选中它）、--page N（相册第 N 个跨页，从 0 起；先换页再选格子）、
/// --select-item N（选中第 N 个自由图层）。
/// --inspector-width N：只截检视器、宽 N pt（高取 --size 的高）—— 窗口里检视器能拖到 300…380，
/// 分栏视图给多宽外面定不准，单独截才能逐个宽度看有没有挤出去。
/// --tab 水印 时另外打印面板上每层显示什么（「水印面板」行）；--ax-dump 打印辅助功能树（滑杆、分段、输入框）。
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
        store.attach(sessionDir: batch.sessionDir, photoDir: dir, batch: batch)

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
            // --overlay-index N：选中照片上第 N 个字块（检视器的字块列表、画布上实一点的那个虚框）。
            if let i = option("--overlay-index").flatMap(Int.init) { store.overlayIndex = max(0, i) }
        }
        if let i = option("--select-item").flatMap(Int.init), store.items.indices.contains(i) {
            store.selectItem(store.items[i].id)
        }
        // --tray-filter all|unused|used、--tray-select ID,ID：截托盘的筛选和多选（离屏点不了）。
        if let f = option("--tray-filter").flatMap(CollageTrayState.Filter.init(rawValue:)) { store.tray.filter = f }
        if let ids = option("--tray-select") { store.tray.selection = Set(ids.split(separator: ",").map(String.init)) }
        // 检视器「水印」页读水印页的签名和预设：和 app 一样从同一个数据目录读。
        let watermarkStore = WatermarkStore(dataDir: appDataDir)
        // --adopt photos|page[:预设名]：走检视器「用水印页的设置 / 预设 ▸」同一条路把水印页设置套进来。
        if let spec = option("--adopt") {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if let kind = parts.first.flatMap(CollageMarkLayerKind.init(rawValue:)) {
                let preset = parts.count > 1 ? parts[1] : nil
                CollageHandoff.adopt(watermarkStore.makeCollageRequest(.applyToCurrent(kind), preset: preset),
                                     layer: kind, into: store)
                print("套用水印页设置 → \(kind.label)：" + (store.project.watermark?.summary ?? "无")
                      + " · 提示：" + (store.notice ?? "无"))
            }
        }
        // --contact-frames：印样的「逐帧」一开始就展开（离屏点不了展开箭头）。
        SnapshotPreview.contactFramesOpen = args.contains("--contact-frames")
        let tab: CollageInspector.Tab = CollageInspector.Tab.allCases.first { $0.rawValue == option("--tab") } ?? .layout
        let sizeParts = (option("--size") ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        let size = NSSize(width: sizeParts.first ?? 1440, height: sizeParts.count > 1 ? sizeParts[1] : 900)

        // 离屏截图里 AppKit 面板底色会画成白的，深色模式的白字就看不见了：--light 用浅色看控件。
        let light = args.contains("--light")
        let inspectorWidth = option("--inspector-width").flatMap(Double.init).map { CGFloat($0) }
        let view = CollageSnapshotHost(store: store, batchStore: batch, watermarkStore: watermarkStore, tab: tab,
                                       inspectorWidth: inspectorWidth)
            .frame(width: inspectorWidth ?? size.width, height: size.height)
            .environment(\.colorScheme, light ? .light : .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: inspectorWidth ?? size.width, height: size.height))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // 等备选缩略图、预览渲染、跨页缩略图都出来。
        spin(4)
        // --notice <字>：状态栏提示（平常 5 秒就清掉，等不到截图）—— 截图前放上，核对长提示不把状态栏撑高。
        if let text = option("--notice") { store.setNotice(text) }
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
        if tab == .watermark {
            for line in CollageWatermarkPanel.describe(store) { print(line) }
        }
        if tab == .export {
            let wm = store.project.watermark
            let shown = CollageExportPanel.showsWatermarkToggle(wm)
            print("导出面板 「导出带水印」" + (shown ? "显示" : "不显示")
                  + (shown && wm?.exportEnabled == false ? " · 「这个拼图导出时不带水印」说明行" : ""))
        }
        if args.contains("--ax-dump") { SnapshotAX.dump(host) }
        if let scenario = option("--perf") { CollagePerf.run(scenario, store: store) { spin($0) } }
        print("界面快照 \(Int(host.frame.width))x\(Int(size.height)) · 托盘 \(store.project.photos.count) 张 · \(store.project.pages.count) 页 · 备选 \(store.alternatives.count) · \(out.path)")
        exit(0)
    }
}

/// 快照用：CollageView 的检视器 tab 是 @State，外面设不进去 —— 这里包一层直接给初值。
private struct CollageSnapshotHost: View {
    let store: CollageStore
    let batchStore: BatchStore
    let watermarkStore: WatermarkStore
    let tab: CollageInspector.Tab
    /// 只截检视器（--inspector-width）。
    let inspectorWidth: CGFloat?

    var body: some View {
        // 离屏没有窗口底色：不垫一层，透明处存成 PNG 是黑的，黑字就看不见了。
        Group {
            if inspectorWidth != nil {
                CollageInspector(store: store, watermarkStore: watermarkStore, tab: .constant(tab))
            } else {
                CollageView(store: store, batchStore: batchStore, watermarkStore: watermarkStore, initialTab: tab)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 编辑操作脚本（验证拖缝/换位/劈开/锁定/撤销这些手势背后的逻辑）

/// LABELGUI_DATA_DIR=<临时目录> LabelGUI --collage-ops <photo_dir> --ops "swap:00>10,move:00>11:left,remove:10,
///     flip:r,ratio:0=0.4,lock:00,regen,framing:10=half,shape:10=circle,contain:10,crop:10=0.5;0.4;2,
///     text:00=bottom,place:DSCF7209>11:top,undo,redo,savetpl:名字,applytpl:名字,exporttpl:/path.json,
///     importtpl:/path.json,frombatch:DSCF7209;DSCF7211,render:文件名" [--out 目录] [--count 6] [--title 标题] [--subtitle 副标题]
/// 起手：清托盘、单张 3:4、默认样式、没有水印，托盘 = 精选 + 可用，按固定的几张（DSCF7232、7208、7222…前 --count 张）
/// 排一版；标题 / 副标题用 --title / --subtitle（不给 = 空）。
/// 路径写成数字串（"10" = 根的第二个孩子的第一个孩子），根节点写 r；一步里的几个数用分号分（逗号分步）。
/// 每步打印版式树、图层（~ 自动撒的，@7232 贴在那张相纸上）和撤销栈。出图不走导出：renderclean = 界面
/// 预览同款，renderexport = 导出同款（成品尺寸带出血）。必须设 LABELGUI_DATA_DIR（起手会清托盘）。
/// renderclean:<文件名>@0.3 按这个缩放出预览；bench:<次数>:<缩放> / benchdrag:<次数>:<缩放>[:<缝>] 量预览渲染耗时；
/// exifprobe:<路径> 核对水印用的 EXIF 缓存；toneprobe:<路径;…> 打印亮度和黑白判定（CollageVision.tone）。
/// renderclean / renderexport 每次都在旁边写 <文件名>.marks.json（水印、页上图层、texts = 每个文字块、
/// crops = 每格取景；见 CollageWatermarkCLI.writeMarks）。出图、dumptexts、bench 之前先等后台的路人信息算完，
/// 起手那一版也等（出图不随机器快慢变）；每格单独的色调打印成 /色调mono，这一页的打印成（这一页色调sepia）。
/// style:<预设 key>（同 --style）、title:<标题>、subtitle:<副标题>、masthead:<刊头>、issue:<期号>（空 = 清掉）；
/// kit:<成套 key 或中文名>（一键成套，同界面菜单；先等路人信息算完）；nextcover[:N]（出一期「换封面」：主图候选往后轮 N 张，
/// N 不到 1 按 1；只换封面那张）；herodump（出一期挑封面的候选、罚分、原因）；albumtheme:classic|fineArt、chaptermono:on|off（相册自动编排的主题、
/// fine-art 的整章黑白；arrange 按它编）；pagelook:<色调>[@强度]|none、celllook:<路径>=<色调>[@强度]|none
/// （页级、格级色调）；insets:上;下;内;外|none（四边边距，相对短边）；datevars:2026-10-23（打印这一天的日期占位符）；
/// fonts（每个字体 × 字重实际解析成哪个 PostScript 名、在哪）；photofacts（托盘每张照片从批量页带来的字段）；
/// applytpl:<模板名 | 分类名 | 名字里的几个字>；dumptexts = 打印每页所有文字块展开后的字、字体字号、位置。
/// 一张照片多个字块：overlay:P[.i]=KEY|none、anchor:P[.i]=RAW（另有 leftColumn / rightColumn / bottomBand）、
/// overlaypos:P[.i]=x;y、overlaytext:P[.i]=字、effect:P[.i]=预设[@行]（00.1 = 00 那张照片上第 2 块；不写 = 第 1 块）、
/// overlayadd:P=KEY（再加一块，让着已有的）、overlaydel:P.i；tset:目标=键=值;…（文字格 / 照片字块 / itemN 的参数：
/// 转向、细线样式、行距、铺满宽度、压窄、大小写、多栏正文……，键表见 applyTextSettings；值里的逗号写 %2C）。
/// 人物挡字（CollageCover）：overlayfront:P[.i]=on|off（off = 字在人后）、depth:P[.i]=0.2（压字深度 0…0.3）、
/// framing:P=cover（封面取景）、cutout:P=on|off[;白边;投影][;edge]（抠图格；edge = 人得延伸到成品底边，浮在纸上就整张照放；
/// cutoutdrag:P=白边;投影 = 拖滑杆的一格，连着拖记一步撤销）、
/// itemcutout:N=on|off[;白边;投影]（抠图贴纸）、tset 的 depth / maxOcclusion /
/// occlusionRule=masthead|total（total = 装饰大字只限总量，不管首末字母）/ maxZoom=1.5（封面取景最多拉近几倍，0 = 不限）/ tightEdge=on（人后主体的边压利落）；coverdump（每格的
/// 取景、头顶、每块字的遮挡和决定）、maskdump[:<目录>]（托盘每张的主体蒙版，给了目录就拷 PNG）、
/// fakefaces:ID=x0;y0;x1;y1/…（合成数据：改托盘里这张的人脸框，验合影退让）。
/// 时尚刊的字块参数：tset 行级 L<n>.spreadShort=on（短刊头加字距不放大）、L<n>.accent=on（颜色从照片取），
/// 字块级 clearBottom=0.104（不进底部遮挡带）、scrim=off（干净的字：不垫雾面，按字形定深浅、看不清落光晕）、
/// matchTone=on（同一格里这几块统一深浅）、fade=0.55（底部平滑压暗，最深多黑）、inkTop=0.025（字墨的顶离上边）。
/// 渲染件：halftone:dot|line[;点距;网角;锐度;网点增大;墨色;纸色|page]|none（照片加网，点距相对短边；实际不到 3 像素只调影调；
/// page = 纸色跟页面底色（模糊底、渐变底时跟底色块），深色页配深墨时换成纸白；.marks.json 的 halftone 记每张的实际点距、出没出点、墨色纸色）、border:none|hairline|polaroid|film|mat[=卡纸色]、mat:0.07（卡纸宽，
/// 顺手换成卡纸边）、paperover:0.5（纸纹压在照片上）、grain:0.4（底下的纸纹）；贴纸 sticker:barcode / sticker:greasePencil
/// （先 sel:路径 选中照片格 = 圈住那一格）、itemmark:N=circle|cross|dot|cropLine（换记号，外框按记号换算）、
/// itemcolor:N=hex、itemlabel:N=字（标签、邮戳、条码上的字）。
/// 印样 / 底片条：contact:135|645|66|67|auto[;每条帧数;条数;sheet|strip]（这一页改成印样，托盘按拍摄先后排成一卷；
/// 已经是印样的只改给了的几项）| contact:off（改回网格）；contactset:键=值;…（format layout perStrip strips upright fill
/// marks cross color roll note edge iso edgeprint jitter tilt margin circles gap paper choice；改 layout 时纸跟着换）；
/// contactmark:ID=circle|cross|dot|cropLine|none|auto；
/// contactframes:ID;ID;…|tray；contactdump（每帧帧号 ↔ 照片、记号、转没转；.marks.json 的 contactSheet 是同一份）。
/// 水印：wm:photos:/sig.png、wmpos:photos:top_left、wmadopt:page:/水印页state.json、
///     wmhandoff:/水印页state.json;/原图1;/原图2 …（wmhandoffnowait = 发起就走、不等照片读完，之后用 wait 等）、
///     wmdump（整个水印的 JSON）（wm* 全部见 CollageWatermarkCLI）。
/// 上面没列的：
/// 版式：refit（贴合原比例：结构不变、按照片原比例重算缝）、sel:P（选中格子）、containblur:P（完整显示、四周用本图模糊填）、margin:0（外边距，相对短边）、
///     bg:solid|fromPhoto|blurPhoto|gradient[=底色 hex]、look:<色调>、strength:0.8（色调强度）、harmonize:0.6（统一色温）、
///     layout:grid|scatter、autolayout:N（托盘前 N 张重新自动排版）、relayout:ID;ID（这一页的照片再加这几张重排）；
///     layoutnowait / autolayoutnowait = 同上但不等排版落下，wait = 等排版落下。
/// 托盘多选：untray:ID;ID;…（一次移除几张，一步撤销）、untrayunused（移除没用上的）、untraydropped（移除相似拿掉的）、
///     trayfilter:all|unused|used、trayclick:ID[+cmd][+shift]、trayall（⌘A）、trayremove（⌫）、trayusage（每张上了几次）。
/// 托盘 / 批量页：untray:ID、cleartray、waittray:N（等托盘有 N 张再等排版）、spintray:N（等到 N 张就走，不等排版）、
///     addfiles:/a.jpg;/b.jpg（托盘「添加文件…」）、batchverdict:ID=pick|usable|reject（批量页手动改判）、
///     reattach（同一场再 attach 一次 = 从批量页切回拼图 tab）、batchswitch（批量页重新载入这一场）。
/// 自由图层（N = 第几个图层，从 0 起）：itemtext（加一个文字图层）、additem:ID@x;y（加一张相纸）、selitem:N、itemmove:N=x;y、
///     itemrot:N=角度、itemsize:N=倍数、itemfront:N / itemback:N（叠放顺序）、itemdel:N、itemdup:N。
/// 相册：mode:album|single、canvas:<同 --canvas>、binding:layflat|glued、arrange[:all]（自动编排；all = 不去重）、page:N、
///     addpage、delpage:N、movepage:N=±k、tonext:P（这一格的照片挪到下一个跨页）、upscale[:1.2]（打印放大超过阈值的照片）、
///     crossfold（打印压中缝的跨页）。
/// 核对：notice（打印状态栏提示）、digest（整个工程的指纹，核对撤销）、tplthumbs[:前缀]（模板缩略图，给了前缀就存 PNG）、
///     altthumb:序号=文件名（存第几个备选的缩略图）、render:<文件名>（半尺寸 + 调试框）。
/// export:<目录> = 走导出全流程（无头模式不弹访达；会真的写出文件，测试脚本用 renderexport）；exportname:<名字>（导出文件名）。
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
        store.attach(sessionDir: batch.sessionDir, photoDir: dir, batch: batch)

        func spin(_ seconds: Double, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if done() { break }
            }
        }
        // 路人信息是后台一张张算的（每张一次 Vision）：出图、排版要等它算完，不然用到的是「算到第几张」的
        // 那一份 —— 裁切避路人、主图挑哪张跟着机器快慢变，同一段脚本两次出图对不上（门禁偶发变红就是这个）。
        // 等满 60 秒还没算完就照常往下走，但留一行字：门禁哪天又对不上，日志里看得出是这里。
        func noteHintsTimeout() {
            if store.hintsPending { print("  路人信息 60 秒没算完，照常往下走（这一步的出图可能跟着机器快慢变）") }
        }
        func hintsSettled() {
            // 先看一眼：已经算完就不转 runloop（spin 先转 20 ms 再查，以前每次出图白等 20 ms —— 门禁里老模板
            // 「慢了 4–12%」全是这个）。计数是排任务时同步加的（computeHints / prewarmMasks），没排上的不会漏等。
            // 只改这一处：idle() 等的「正在排版 / 忙」没逐个核对是不是排任务时同步设上，那边照旧先转一下。
            guard store.hintsPending else { return }
            spin(60) { !store.hintsPending }
            noteHintsTimeout()
        }
        func idle() {
            spin(60) { !store.isSolving && store.busyText == nil && !store.hintsPending }
            noteHintsTimeout()
        }
        func path(_ s: String) -> [Int] { s == "r" ? [] : s.compactMap { $0.wholeNumberValue } }
        // 「路径.第几个字块」：00.1 = 00 那张照片上的第 2 个字块；不写点 = 第 1 个（刊头 / 唯一那个）。
        func block(_ s: String) -> (path: [Int], index: Int) {
            let parts = s.split(separator: ".", maxSplits: 1).map(String.init)
            return (path(parts.first ?? ""), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
        func describe() -> String {
            // 水印标签（没有就不加）：每步都看得出「接着拼，水印还在」。
            let mark = store.project.watermark.map { "  ‖ 水印[\($0.summary)]" } ?? ""
            guard let root = store.root else { return "（空）" + mark }
            let leaves = root.leafPaths().map { p -> String in
                let cell = root.node(at: p)?.cell
                var tag = cell?.kind == .text ? "文字" : (cell?.photoID.map { String($0.suffix(4)) } ?? "空")
                if cell?.locked == true { tag += "🔒" }
                if let f = cell?.framing, f != .auto { tag += "/" + f.label }
                if let s = cell?.shape { tag += "/" + s.label }
                if cell?.contain == true { tag += cell?.containBlur == true ? "/完整+模糊" : "/完整" }
                if let c = cell?.crop { tag += String(format: "/裁%.2f,%.2f×%.1f", c.cx, c.cy, c.zoom) }
                if let list = cell?.overlays, !list.isEmpty {
                    tag += "/压字(" + list.map { $0.anchor.label + ($0.layer == .front ? "" : "·人后") }.joined(separator: "+") + ")"
                }
                if let l = cell?.look { tag += "/色调" + l.look.rawValue }
                if let c = cell?.cutout { tag += c.toEdge ? "/抠图·贴底边" : "/抠图" }
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
                // ~ = 自动撒的；@7232 = 贴在那张相纸上；✂ = 抠图贴纸
                if it.generated { name = "~" + name }
                if it.cutout != nil { name += "✂" }
                if let a = it.attach {
                    let host = all.first { $0.id == a.to }?.photoID.map { String($0.suffix(4)) } ?? "?"
                    name += "@" + host
                }
                let sel = it.id == store.selectedItem ? "*" : ""
                return String(format: "%@%d:%@(%.2f,%.2f %.0f°)", sel, i, name, it.cx, it.cy, it.rotation)
            }
            var head = store.isFreeform ? "散落" : root.signature + "  |  " + leaves.joined(separator: " ")
            if let cs = store.page?.contactSheet {
                // 帧数只算画得出来的（放不下的另报「放不下N」，同检视器、CollagePage.photoIDs）。
                let left = max(0, cs.frames.count - cs.frameLimit)
                head = "印样[\(cs.format.label) \(cs.layout.label) \(cs.frames.count - left) 帧"
                    + " 每条\(cs.perStrip == 0 ? "自动" : "\(cs.perStrip)") × \(cs.strips == 0 ? "自动" : "\(cs.strips)") 条"
                    + (left > 0 ? " 放不下\(left)" : "") + "]"
            }
            if store.isFreeform, let spec = store.page?.scatter { head += "[\(spec.frame.label)]" }
            if store.page?.gridRoot != nil { head += "(记着网格)" }
            if let l = store.page?.look { head += "(这一页色调\(l.look.rawValue))" }
            if store.layoutStyle != store.effectiveLayoutStyle { head += "(偏好\(store.layoutStyle.label))" }
            return head + (items.isEmpty ? "" : "  || 图层 " + items.joined(separator: " ")) + mark
        }
        func itemID(_ s: String) -> UUID? {
            guard let i = Int(s), store.items.indices.contains(i) else { return nil }
            return store.items[i].id
        }
        // dumptexts：每一页的所有文字块（压字、文字格、文字图层）—— 展开占位符之后的字、字体、实际字号、
        // 字块外框（成品坐标）。和 .marks.json 的 texts 同一份记录：按预览的规矩（空格子上的压字也算）小尺寸渲染一遍收。
        func dumpTexts() {
            let pages = store.project.pages
            for (i, page) in pages.enumerated() {
                var opts = CollageRender.Options(scale: 0.25)
                opts.includeBleed = false
                opts.placeholders = true
                let report = CollageRender.RenderReport()
                opts.report = report
                _ = CollageRender.render(page: page, project: store.project, hints: store.hints, options: opts)
                let current = i == store.pageIndex ? "（当前）" : ""
                print("  第 \(i + 1)/\(pages.count) 页\(current) · 文字块 \(report.texts.count) 个")
                for t in report.texts {
                    let r = t.rect
                    let sizes = t.sizes.map { String(format: "%.0f", $0) }.joined(separator: "/")
                    let extra = (t.vertical ? " 竖排" : "") + (t.rotation != 0 ? " 转\(t.rotation)°" : "")
                        + (t.body.map { " 正文=" + $0 } ?? "")
                    let head = String(format: "    [%@] %@/%@ (%.0f,%.0f,%.0f,%.0f) %@ %@px%@：", t.owner, t.kind, t.layer,
                                      r.minX, r.minY, r.width, r.height, t.font, sizes, extra)
                    print(head + t.lines.joined(separator: " ⏎ "))
                    if let o = t.occlusion { print("      " + CollageCLI.occlusionLine(o)) }
                }
            }
        }

        // contactdump：这一页印样每帧的帧号 ↔ 照片、场、判决、记号、转没转、黑边，每条的转角，片边字印没印。
        // 和 .marks.json 的 contactSheet 同一份记录（按预览的规矩、成品尺寸渲染一遍收）。
        func dumpContact() {
            guard let page = store.page, page.contactSheet != nil else {
                print("  这一页不是印样")
                return
            }
            // 按成品尺寸渲一遍（片边字缩得太小不印：0.25 倍的预览里常常不印，看不出导出印没印）。
            var opts = CollageRender.Options(scale: 1)
            opts.includeBleed = false
            opts.placeholders = true
            let report = CollageRender.RenderReport()
            opts.report = report
            _ = CollageRender.render(page: page, project: store.project, hints: store.hints, options: opts)
            guard let r = report.contactSheet else { return }
            print(String(format: "  印样 %@ · %@ · 卷 %@ · 每毫米 %.2f px · 每条 %d 帧 × %d 条 · 帧号偏 %.2f 帧距 · 片边字%@",
                         r.format, r.layout, r.roll, r.unit, r.perStrip, r.strips, r.numberOffset,
                         r.edgePrinted ? "印了" : "没印（太小）"))
            for st in r.stripRecords {
                print(String(format: "    条 %d：%d 帧 · 转 %.2f° · 齿孔 %d", st.index, st.frames, st.angle, st.holes))
            }
            for f in r.frames {
                let flags = (f.rotated ? " 转90°" : "") + (f.letterboxed ? " 黑边" : "") + (f.drawn == nil ? " 没画出" : "")
                let take = f.take.map { "场\($0)" } ?? "—"
                print(String(format: "    %@ → %@ · %@ · %@ · 记号 %@ · (%.0f,%.0f,%.0f,%.0f)%@", f.label, f.photoID, take,
                             f.verdict ?? "—", f.mark ?? "—", f.rect.minX, f.rect.minY, f.rect.width, f.rect.height, flags))
            }
            if !r.overflow.isEmpty { print("    放不下：" + r.overflow.joined(separator: " ")) }
            // 一帧都没有时两个框都是 nil：打「—」。
            func box(_ b: CGRect?) -> String {
                guard let b, !b.isNull else { return "—" }
                return String(format: "(%.0f,%.0f,%.0f,%.0f)", b.minX, b.minY, b.width, b.height)
            }
            print("    片条外框 \(box(r.bounds)) · 圈留到 \(box(r.inkBounds))")
            let note = r.noteRect.map { String(format: " (%.0f,%.0f,%.0f,%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? ""
            print("    注记：" + (r.note ?? "（没写）") + note)
        }

        func dumpMasks(_ photos: [CollagePhotoRef], copyTo dir: URL?) {
            if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            let folder = CollageMasks.currentDirectory?.path ?? "（只在内存）"
            print("  蒙版目录 \(folder) · maskVersion \(CollageMasks.maskVersion)")
            for p in photos {
                guard let m = CollageMasks.mask(for: p) else {
                    print("    \(p.id) 认不出主体")
                    continue
                }
                let heads = m.headTop.map { $0 < 0 ? "—" : String(format: "%.3f", $0) }.joined(separator: ",")
                let faceTop = p.faces.first.map { String(format: "%.3f", $0[1]) } ?? "—"
                print(String(format: "    %@ %dx%d 覆盖 %.3f 头顶 [%@]（脸框上沿 %@）实例 %d 选 %@ · %@ %.0f ms · %@",
                             p.id, m.width, m.height, m.coverage, heads, faceTop, m.instances,
                             m.selected.map(String.init).joined(separator: "+"), m.fromDisk ? "读盘" : "现算", m.millis,
                             m.key))
                if !m.people.isEmpty {
                    let boxes = m.people.map { b in "[" + b.map { String(format: "%.3f", $0) }.joined(separator: " ") + "]" }
                    print("      别的人 \(m.people.count)：" + boxes.joined(separator: " "))
                }
                if let dir, let src = CollageMasks.file(for: p), FileManager.default.fileExists(atPath: src.path) {
                    let dest = dir.appendingPathComponent("mask_\(p.id).png")
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: src, to: dest)
                }
            }
        }
        func dumpCover() {
            guard store.page != nil else { return }
            for frame in store.geometry.frames {
                guard let r = store.coverResolution(for: frame) else { continue }
                let w = r.window
                let tag = frame.path.isEmpty ? "r" : frame.path.map(String.init).joined()
                print(String(format: "  [%@] %@ 取景 %.3f,%.3f %.3fx%.3f%@ · 头顶 %@ %@ · 蒙版 %@ · %d 张脸", tag,
                             frame.cell.photoID ?? "-", w.x, w.y, w.w, w.h, w.cutsFace ? " 切脸" : "",
                             r.headTop.map { String(format: "%.3f", $0) } ?? "—", r.headTopSource,
                             r.mask.map { String(format: "覆盖 %.3f", $0.coverage) } ?? "无", r.faces))
                if let up = store.upscale(for: frame) { print(String(format: "      放大 %.2f×", up)) }
                if let line = CollageCover.edgeDump(cell: frame.cell, r) { print(line) }
                for (i, b) in r.blocks.enumerated() {
                    guard let b else { continue }
                    let occ = b.occlusion.map { o in
                        String(format: "总 %.1f%% 首 %.1f%% 末 %.1f%% 过半 %d/%d", o.total * 100, o.first * 100,
                               o.last * 100, o.heavy, o.letters)
                    } ?? "没量"
                    let h = r.maxHeights[i].map { String(format: " 限高 %.0fpx", $0) } ?? ""
                    let tags = (b.rule == .total ? " 只限总量" : "") + (b.moved ? " 挪开头" : "")
                    print("      第 \(i + 1) 块\(b.band ? "（刊头）" : "") → \(b.layer.rawValue)/\(b.step.rawValue)\(tags) · \(occ)\(h)"
                          + (b.reason.map { " · " + $0 } ?? ""))
                }
            }
        }

        // 检视器「文字」页那句不拦截的提示（刊头像真实刊名）会不会出现：title: / masthead: 之后打印。
        func printMastheadHint() {
            guard CollageTypeset.mastheadLooksReal(masthead: store.project.masthead, title: store.project.title) else { return }
            let shown = CollageTypeset.mastheadText(store.project.masthead, title: store.project.title)
            print("  检视器提示：刊头「\(shown)」像是真实杂志的名字（不拦）")
        }

        // 读回来的工程是什么画布、带没带水印（核对旧工程的容错解码 / 升级、水印存盘，下面马上会重置）。
        let loaded = store.project.canvas
        let loadedMark = store.project.watermark.map { "水印[\($0.summary)]" } ?? "无水印"
        // 「导出带水印」跟着拼图存：没有水印就无所谓开关（—）。
        let loadedExport = store.project.watermark.map { $0.exportEnabled ? "开" : "关" } ?? "—"
        // 托盘里有帧号的 = attach 时按批量页刷新过（旧工程存的快照里没有帧号）。
        let framed = store.project.photos.filter { $0.frameNo != nil }.count
        print("载入  \(loaded.name) \(loaded.width)x\(loaded.height) seams=\(loaded.seams.rawValue) · \(store.project.pages.count) 页 · \(loadedMark) · 导出带水印 \(loadedExport) · 托盘 \(store.project.photos.count) 张（带帧号 \(framed)）")
        if let wm = store.project.watermark { print("  读回水印 " + CollageWatermarkCLI.json(wm)) }

        // 起手：单张 3:4、托盘 = 精选+可用，排一版（每次都从头来，脚本结果可复现）。
        store.clearTray()
        store.setMode(.single)
        store.setLayoutStyle(.grid)
        store.setCanvas(CollageCanvas.social[0])
        store.setStyle(CollageStyle())
        store.setTitle(option("--title") ?? "")
        store.setSubtitle(option("--subtitle") ?? "")
        store.setWatermark(nil)
        store.importVerdicts(batch: batch, includeUsable: true)
        spin(20) { !store.project.photos.isEmpty && store.busyText == nil }
        // 起手这一版也等路人信息：求解打分看它（裁切压不压路人）。
        hintsSettled()
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

        // tset：读出目标那块字 → 逐个键改 → 走界面同一个入口写回（照片上字块自己的参数走 updateOverlay）。
        // 键：vertical alignH alignV lineSpacing rule ruleStyle rotation lines（只留前 N 行）seal；
        //     L<n>.text|font|weight|italic|size|tracking|color|indent|fitWidth|widthScale|textCase|spreadShort|accent|effect
        //     （n = 行数时加一行）；
        //     body=on|off、body.text|file|columns|justified|columnRule|dropCap|font|weight|size|leading|indent|gap|color|
        //     vertical|filler|traditional|balanced；照片上的字块另有 anchor maxWidth inset tone shadow layer x y、
        //     人物挡字的 depth maxOcclusion occlusionRule maxZoom tightEdge、时尚刊的 clearBottom scrim matchTone fade inkTop。
        //     写错一个键整步算「参数不对」。
        func applyTextSettings(_ arg: String) -> Bool {
            guard let (target, rest) = pair(arg, "=") else { return false }
            // 值可以是空的（body.text= 清空正文成灰条、L0.text= 清空一行）：等号后面的空串要留着。
            let settings: [(String, String)] = rest.split(separator: ";").compactMap { item in
                let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard kv.count == 2 else { return nil }
                return (kv[0], kv[1].removingPercentEncoding ?? kv[1])
            }
            guard !settings.isEmpty else { return false }
            func flag(_ v: String) -> Bool? {
                ["1": true, "on": true, "true": true, "yes": true, "0": false, "off": false, "false": false, "no": false][v]
            }
            func color(_ v: String) -> CollageColor? {
                UInt32(v.hasPrefix("#") ? String(v.dropFirst()) : v, radix: 16).map { CollageColor(hex: $0) }
            }
            // 目标：文字图层 / 文字格 / 照片上的第 i 个字块。
            var text: CollageText
            let textTarget: CollageTextTarget
            var overlayIndex: Int?
            let b = block(target)
            if target.hasPrefix("item"), let id = itemID(String(target.dropFirst(4))),
               let item = store.items.first(where: { $0.id == id }), let t = item.text {
                text = t
                textTarget = .item(id)
            } else if let cell = store.root?.node(at: b.path)?.cell, cell.kind == .text, let t = cell.text {
                text = t
                textTarget = .cell(b.path, store.page?.id)
            } else if let cell = store.root?.node(at: b.path)?.cell, cell.overlays.indices.contains(b.index) {
                text = cell.overlays[b.index].text
                textTarget = .overlay(b.path, cell.photoID, store.page?.id, b.index)
                overlayIndex = b.index
            } else {
                return false
            }
            var overlayEdits: [(inout CollageOverlay) -> Void] = []
            func setLine(_ i: Int, _ key: String, _ v: String) -> Bool {
                guard i >= 0, i <= text.lines.count else { return false }
                if i == text.lines.count {
                    var line = text.lines.last ?? CollageTextLine("")
                    line.text = ""
                    line.fitWidth = false
                    text.lines.append(line)
                }
                var line = text.lines[i]
                switch key {
                case "text": line.text = v.replacingOccurrences(of: "\\n", with: "\n")
                case "font": guard let f = CollageFont(rawValue: v) else { return false }; line.font = f
                case "weight": guard let w = CollageWeight(rawValue: v) else { return false }; line.weight = w
                case "italic": guard let x = flag(v) else { return false }; line.italic = x
                case "size": guard let x = Double(v), x > 0 else { return false }; line.size = x
                case "tracking": guard let x = Double(v) else { return false }; line.tracking = x
                case "color": guard let c = color(v) else { return false }; line.color = c
                case "indent": guard let x = Double(v) else { return false }; line.indent = x
                case "fitWidth": guard let x = flag(v) else { return false }; line.fitWidth = x
                case "widthScale": guard let x = Double(v) else { return false }; line.widthScale = min(1, max(0.85, x))
                case "textCase": guard let c = CollageTextCase(rawValue: v) else { return false }; line.textCase = c
                case "spreadShort": guard let x = flag(v) else { return false }; line.spreadShort = x
                case "accent": guard let x = flag(v) else { return false }; line.accentFromPhoto = x
                case "effect":
                    guard let preset = CollageTextEffects.preset(v) else { return false }
                    preset.apply(&line)
                default: return false
                }
                text.lines[i] = line
                return true
            }
            func setBody(_ key: String, _ v: String) -> Bool {
                var body = text.body ?? CollageBody()
                switch key {
                case "text": body.text = v.replacingOccurrences(of: "\\n", with: "\n")
                case "file":
                    guard let s = try? String(contentsOfFile: v, encoding: .utf8) else { return false }
                    body.text = s
                case "columns": guard let n = Int(v), n >= 1 else { return false }; body.columns = min(12, n)
                case "justified": guard let x = flag(v) else { return false }; body.justified = x
                case "columnRule": guard let x = flag(v) else { return false }; body.columnRule = x
                case "dropCap": guard let n = Int(v), n >= 0 else { return false }; body.dropCap = min(6, n)
                case "font": guard let f = CollageFont(rawValue: v) else { return false }; body.font = f
                case "weight": guard let w = CollageWeight(rawValue: v) else { return false }; body.weight = w
                case "size": guard let x = Double(v), x > 0 else { return false }; body.size = x
                case "leading": guard let x = Double(v), x >= 0.8 else { return false }; body.leading = x
                case "indent": guard let x = Double(v), x >= 0 else { return false }; body.firstLineIndent = x
                case "gap": guard let x = Double(v), x > 0 else { return false }; body.gap = x
                case "color": guard let c = color(v) else { return false }; body.color = c
                case "vertical": guard let x = flag(v) else { return false }; body.vertical = x
                case "filler": guard let x = flag(v) else { return false }; body.filler = x
                case "traditional": guard let x = flag(v) else { return false }; body.traditional = x
                case "balanced": guard let x = flag(v) else { return false }; body.balanced = x
                default: return false
                }
                text.body = body
                return true
            }
            for (key, v) in settings {
                var good = true
                if key.hasPrefix("L"), let dot = key.firstIndex(of: "."), let i = Int(key[key.index(after: key.startIndex)..<dot]) {
                    good = setLine(i, String(key[key.index(after: dot)...]), v)
                } else if key.hasPrefix("body.") {
                    good = setBody(String(key.dropFirst(5)), v)
                } else {
                    switch key {
                    case "vertical": if let x = flag(v) { text.vertical = x } else { good = false }
                    case "alignH": if let a = CollageAlign(rawValue: v) { text.alignH = a } else { good = false }
                    case "alignV": if let a = CollageAlign(rawValue: v) { text.alignV = a } else { good = false }
                    case "lineSpacing": if let x = Double(v) { text.lineSpacing = max(-0.15, x) } else { good = false }
                    case "rule": if let x = flag(v) { text.rule = x } else { good = false }
                    case "ruleStyle": if let r = CollageRuleStyle(rawValue: v) { text.ruleStyle = r } else { good = false }
                    case "rotation":
                        if let r = Int(v), [0, 90, -90].contains(r) { text.rotation = r } else { good = false }
                    case "lines": if let n = Int(v), n >= 1 { text.lines = Array(text.lines.prefix(n)) } else { good = false }
                    case "seal": text.seal = v == "none" ? nil : CollageSeal(text: String(v.prefix(4)))
                    case "body":
                        if let x = flag(v) { text.body = x ? (text.body ?? CollageBody()) : nil } else { good = false }
                    case "anchor", "maxWidth", "inset", "tone", "shadow", "layer", "x", "y", "depth", "maxOcclusion",
                         "occlusionRule", "maxZoom", "tightEdge", "clearBottom", "scrim", "matchTone", "fade", "inkTop":
                        guard overlayIndex != nil else { good = false; break }
                        switch key {
                        case "anchor": if let a = CollageAnchor(rawValue: v) { overlayEdits.append { $0.anchor = a } } else { good = false }
                        case "scrim": if let x = flag(v) { overlayEdits.append { $0.scrim = x } } else { good = false }
                        case "matchTone": if let x = flag(v) { overlayEdits.append { $0.matchTone = x } } else { good = false }
                        case "occlusionRule":
                            if let r = CollageOcclusionRule(rawValue: v) { overlayEdits.append { $0.occlusionRule = r } } else { good = false }
                        case "tone": if let t = CollageTone(rawValue: v) { overlayEdits.append { $0.tone = t } } else { good = false }
                        case "layer": if let l = CollageTextLayer(rawValue: v) { overlayEdits.append { $0.layer = l } } else { good = false }
                        case "tightEdge": if let x = flag(v) { overlayEdits.append { $0.tightEdge = x } } else { good = false }
                        default:
                            guard let x = Double(v) else { good = false; break }
                            switch key {
                            case "maxWidth": overlayEdits.append { $0.maxWidth = min(1, max(0.2, x)) }
                            case "inset": overlayEdits.append { $0.inset = min(0.3, max(0, x)) }
                            case "shadow": overlayEdits.append { $0.shadow = min(1, max(0, x)) }
                            case "depth": overlayEdits.append { $0.depth = min(0.3, max(0, x)) }
                            case "maxOcclusion": overlayEdits.append { $0.maxOcclusion = min(0.33, max(0.05, x)) }
                            case "maxZoom": overlayEdits.append { $0.maxZoom = x >= 1 ? min(8, x) : nil }  // 0 = 不限
                            case "clearBottom": overlayEdits.append { $0.clearBottom = min(0.4, max(0, x)) }
                            case "fade": overlayEdits.append { $0.fade = min(0.7, max(0, x)) }
                            case "inkTop": overlayEdits.append { $0.inkTop = min(0.2, max(0, x)) }
                            case "x": overlayEdits.append { $0.x = min(1, max(0, x)) }
                            default: overlayEdits.append { $0.y = min(1, max(0, x)) }
                            }
                        }
                    default: good = false
                    }
                }
                if !good {
                    print("  tset 认不得 \(key)=\(v)")
                    return false
                }
            }
            store.updateText(text, target: textTarget)
            if let i = overlayIndex, !overlayEdits.isEmpty {
                store.updateOverlay(at: b.path, index: i) { o in for edit in overlayEdits { edit(&o) } }
            }
            return true
        }

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
                   let f = ["auto": CollageFraming.auto, "full": .full, "half": .half, "close": .close,
                            "cover": .cover][v] {
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
                if let p = at(kv, 0).map(block), let preset = at(spec, 0).flatMap(CollageTextEffects.preset),
                   let cell = store.root?.node(at: p.path)?.cell {
                    // 和界面里点预设走同一个入口（照片上的字会连深浅一起定）。路径.第几个字块 = 照片上别的字块。
                    if cell.kind == .text {
                        store.applyTextEffect(preset, line: lineIndex, target: .cell(p.path, store.page?.id))
                    } else if cell.overlays.indices.contains(p.index) {
                        store.applyTextEffect(preset, line: lineIndex,
                                              target: .overlay(p.path, cell.photoID, store.page?.id, p.index))
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
                // overlay:P[.i]=KEY|none：换掉（none = 删掉）这张照片上的第 i 个字块；i 超出 = 加在最后。
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if let p = at(kv, 0).map(block) {
                    store.selection = p.path
                    let key = at(kv, 1) ?? "none"
                    let preset = key != "none" ? CollageOverlays.preset(key) : nil
                    if key != "none", preset == nil { ok = false } else {
                        store.setOverlay(preset, at: p.path, index: p.index)
                    }
                } else { ok = false }
            case "overlayadd":
                // overlayadd:P=KEY：在这张照片上再加一个字块（摆在已有的之后、让着它们）。
                if let (p, key) = pair(arg, "="), let preset = CollageOverlays.preset(key),
                   store.root?.node(at: path(p))?.cell?.kind == .photo {
                    store.selection = path(p)
                    store.addOverlay(preset, at: path(p))
                } else { ok = false }
            case "overlaydel":
                // overlaydel:P.i：删掉第 i 个字块（后面的往前挪）。
                let p = block(arg)
                if store.root?.node(at: p.path)?.cell?.overlays.indices.contains(p.index) == true {
                    store.setOverlay(nil, at: p.path, index: p.index)
                } else { ok = false }
            case "anchor":
                if let (p, v) = pair(arg, "="), let a = CollageAnchor(rawValue: v) {
                    let b = block(p)
                    store.updateOverlay(at: b.path, index: b.index) { $0.anchor = a }
                } else { ok = false }
            case "overlaypos":
                let n = nums(pair(arg, "=")?.1)
                if let (p, _) = pair(arg, "="), n.count == 2 {
                    let b = block(p)
                    store.beginContinuousEdit()
                    store.setOverlayPosition(x: n[0], y: n[1], at: b.path, index: b.index)
                    store.endContinuousEdit()
                } else { ok = false }
            case "overlaytext":
                // overlaytext:P[.i]=TEXT：第 i 个字块的第一行。
                if let (p, v) = pair(arg, "="), case let b = block(p),
                   let list = store.root?.node(at: b.path)?.cell?.overlays, list.indices.contains(b.index) {
                    var t = list[b.index].text
                    if !t.lines.isEmpty { t.lines[0].text = v }
                    let pid = store.root?.node(at: b.path)?.cell?.photoID
                    store.updateText(t, target: .overlay(b.path, pid, store.page?.id, b.index))
                } else { ok = false }
            case "tset":
                // tset:目标=键=值;键=值…：直接改一个文字块的参数（样张、自测用）。目标 = 文字格路径、照片路径[.i]
                // （照片上第 i 个字块）、item<N>（第 N 个文字图层）。值里的逗号、分号写成 %2C、%3B。
                ok = applyTextSettings(arg)
            case "overlayfront":
                // overlayfront:P[.i]=on|off：on = 这块字在人前（关掉人物挡字），off = 在人后（同检视器的开关：
                // 定死位置的字块、「自动」取景时顺手换成封面取景；关掉时、别的字块也不在人后，换回自动）。
                if let (p, v) = pair(arg, "="), v == "on" || v == "off", case let b = block(p),
                   store.root?.node(at: b.path)?.cell?.overlays.indices.contains(b.index) == true {
                    store.setOverlayLayer(v == "on" ? .front : .behindSubject, at: b.path, index: b.index)
                } else { ok = false }
            case "depth":
                // depth:P[.i]=0.2：压字深度（头顶落在字顶下多少字高，0…0.3）。
                if let (p, v) = pair(arg, "="), let x = Double(v), case let b = block(p),
                   store.root?.node(at: b.path)?.cell?.overlays.indices.contains(b.index) == true {
                    store.updateOverlay(at: b.path, index: b.index) { $0.depth = min(0.3, max(0, x)) }
                } else { ok = false }
            case "cutout":
                // cutout:P=on|off[;描边;投影][;edge]：抠图格（只画主体，背景透出页面）；描边相对短边、投影 0…1；
                // edge = 人得延伸到成品底边（CollageCutout.toEdge，浮在纸上就不抠）。
                if let (p, v) = pair(arg, "=") {
                    let bits = v.split(separator: ";").map(String.init)
                    let n = bits.dropFirst().compactMap(Double.init)
                    if bits.first == "on" {
                        store.setCutout(CollageCutout(stroke: n.first ?? 0, shadow: n.count > 1 ? n[1] : 0,
                                                      toEdge: bits.contains("edge")), at: path(p))
                    } else if bits.first == "off" {
                        store.setCutout(nil, at: path(p))
                    } else { ok = false }
                } else { ok = false }
            case "cutoutdrag":
                // cutoutdrag:P=白边;投影：同检视器拖白边 / 投影滑杆的一格（连着拖只记一步撤销）。格子得已经是抠图格。
                if let (p, v) = pair(arg, "="), let old = store.root?.node(at: path(p))?.cell?.cutout {
                    let n = v.split(separator: ";").compactMap { Double(String($0)) }
                    if n.count == 2 {
                        var c = old
                        c.stroke = n[0]
                        c.shadow = n[1]
                        store.setCutout(c, at: path(p), coalesce: true)
                    } else { ok = false }
                } else { ok = false }
            case "maskdump":
                // maskdump[:<出图目录>]：托盘每张照片的主体蒙版（覆盖率、每张脸的头顶、实例、耗时、文件）；
                // 给了目录就把蒙版 PNG 也拷过去（读图看）。蒙版没有就现算。
                hintsSettled()
                dumpMasks(store.project.photos, copyTo: arg.isEmpty ? nil : URL(fileURLWithPath: arg))
            case "fakefaces":
                // fakefaces:ID=x0;y0;x1;y1/x0;y0;x1;y1/…：合成数据 —— 直接改托盘里这张照片的人脸框（验多人合影的
                // 退让）。不进撤销；reattach、batchswitch 会按批量页刷回去。
                if let (id, v) = pair(arg, "=") {
                    let boxes = v.split(separator: "/").map { nums(String($0)) }.filter { $0.count == 4 }
                    ok = !boxes.isEmpty && store.overrideFacesForTesting(id, faces: boxes)
                } else { ok = false }
            case "coverdump":
                // coverdump：当前页每个走人物挡字 / 封面取景的格子：取景、头顶、每块字的决定和原因（同检视器读数）。
                hintsSettled()
                dumpCover()
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
            case "title":
                // title:<文字>：标题（{title}、刊头预设用的就是它）。逗号是分步符，文字里不能带。
                store.setTitle(arg)
                printMastheadHint()
            case "style":
                // style:<预设 key>：整页换成那个风格预设（同样式页点预设；key 同 --style）。写错的 key 不悄悄退回默认。
                if CollageStyles.all.contains(where: { $0.key == arg }) {
                    store.setStyle(CollageStyles.preset(arg), coalesce: false)
                } else { ok = false }
            case "herodump":
                // herodump：出一期挑封面的主图候选（按真套上封面的决定打分，罚分从低到高）和原因。
                hintsSettled()
                let base = CollageStyleFashion.issueBase(store.project)
                let picks = CollageStyleFashion.heroCandidates(store.project.photos.filter { $0.verdict != .reject },
                                                               hints: store.hints, base: base)
                for (k, h) in picks.enumerated() {
                    let occ = h.block?.occlusion.map { String(format: "挡 %.1f%%", $0.total * 100) } ?? "没量"
                    let layer = h.block.map { $0.layer.rawValue + "/" + $0.step.rawValue } ?? "—"
                    print(String(format: "  %2d %@ 罚分 %.2f · %@ · %@", k + 1, h.photo.id, h.penalty, layer, occ)
                          + (h.notes.isEmpty ? "" : " · " + h.notes.joined(separator: "、")))
                }
            case "nextcover":
                // nextcover[:N]：「换封面」（出一期）—— 主图候选里往后轮 N 张（默认 1），只换封面那张，内页留着。
                var landed = false
                hintsSettled()
                store.applyKit(.fashionIssue, coverStep: max(1, Int(arg) ?? 1)) { landed = true }
                spin(300) { landed }
                idle()
                print("  换封面 · 封面 \(CollageStyleFashion.coverPhotoID(store.project) ?? "—") · 提示: " + (store.notice ?? "无"))
            case "masthead":
                // masthead:<刊头>（{masthead}；空 = 按标题生成：拉丁字母转大写、中文转拼音大写）。
                store.setMasthead(arg)
                printMastheadHint()
            case "issue":
                // issue:<期号>（{issue}；空 = 页码）。
                store.setIssue(arg)
            case "kit":
                // kit:<成套>：和界面「一键成套 ▾」同一个入口；还没做的只打印提示（这一步不算失败）。
                if let kit = CollageKitID.find(arg) {
                    var landed = false
                    hintsSettled()
                    store.applyKit(kit) { landed = true }
                    spin(300) { landed }
                    idle()
                    print("  成套「\(kit.name)」· \(store.project.pages.count) 页 · 提示: " + (store.notice ?? "无")
                          + (store.albumDropped.isEmpty ? "" : " · 托盘标「拿掉」\(store.albumDropped.count) 张"))
                } else { ok = false }
            case "pagelook", "celllook":
                // pagelook:mono@0.6 | pagelook:none；celllook:10=sepia@0.8 | celllook:10=none
                let kv = name == "celllook" ? arg.split(separator: "=", maxSplits: 1).map(String.init) : ["", arg]
                let spec = (at(kv, 1) ?? "").split(separator: "@").map(String.init)
                let key = at(spec, 0) ?? ""
                let strength = at(spec, 1).flatMap(Double.init) ?? 0.8
                let look: CollageLookSetting?? = key == "none" ? .some(nil)
                    : CollageLook(rawValue: key).map { CollageLookSetting(look: $0, strength: strength) }
                if let look {
                    if name == "pagelook" {
                        store.setPageLook(look)
                    } else if let p = at(kv, 0) {
                        store.selection = path(p)
                        store.setCellLook(look)
                    } else { ok = false }
                } else { ok = false }
            case "halftone":
                // halftone:none | halftone:dot[;点距;网角;锐度;网点增大;墨色;纸色]（点距相对短边，默认 0.004；
                // 墨色、纸色写 hex，纸色写 page 或不写 = 跟页面底色，深色页配深墨时换成纸白）。line = 线网。
                var st = store.project.style
                let bits = arg.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                if arg == "none" {
                    st.halftone = nil
                    store.setStyle(st, coalesce: false)
                } else if let kind = at(bits, 0).flatMap(CollageScreen.init(rawValue:)) {
                    var h = st.halftone ?? CollageHalftone()
                    h.screen = kind
                    var good = true
                    func num(_ i: Int, _ apply: (Double) -> Void) {
                        guard let raw = at(bits, i), !raw.isEmpty else { return }
                        if let v = Double(raw), v.isFinite { apply(v) } else { good = false }
                    }
                    let pitchRange = CollageHalftone.pitchRange
                    num(1) { h.pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound, $0)) }
                    num(2) { h.angle = $0 }
                    num(3) { h.sharpness = min(1, max(0, $0)) }
                    num(4) { h.gain = min(1, max(0, $0)) }
                    if let raw = at(bits, 5), !raw.isEmpty {
                        if let hex = UInt32(raw, radix: 16) { h.ink = CollageColor(hex: hex) } else { good = false }
                    }
                    if let raw = at(bits, 6), !raw.isEmpty {
                        if raw == "page" { h.paper = nil } else if let hex = UInt32(raw, radix: 16) {
                            h.paper = CollageColor(hex: hex)
                        } else { good = false }
                    }
                    if good {
                        st.halftone = h
                        store.setStyle(st, coalesce: false)
                    } else { ok = false }
                } else { ok = false }
            case "border":
                // border:none|hairline|polaroid|film|mat（可带颜色 border:mat=F6F1E7）
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if let b = at(kv, 0).flatMap(CollageBorder.init(rawValue:)) {
                    var st = store.project.style
                    st.border = b
                    if let hex = at(kv, 1).flatMap({ UInt32($0, radix: 16) }) { st.borderColor = CollageColor(hex: hex) }
                    store.setStyle(st, coalesce: false)
                } else { ok = false }
            case "mat":
                // mat:0.07（卡纸宽，相对格子短边；顺手把边框换成卡纸）
                if let v = Double(arg), v.isFinite {
                    var st = store.project.style
                    st.border = .mat
                    st.matWidth = min(0.3, max(0.01, v))
                    store.setStyle(st, coalesce: false)
                } else { ok = false }
            case "paperover", "grain":
                // paperover:0.5（纸纹压在照片上 0…1）；grain:0.4（底下的纸纹）
                if let v = Double(arg), v.isFinite {
                    var st = store.project.style
                    if name == "grain" { st.grain = min(1, max(0, v)) } else { st.paperOverPhotos = min(1, max(0, v)) }
                    store.setStyle(st, coalesce: false)
                } else { ok = false }
            case "contact":
                // contact:135|645|66|67|auto[;每条帧数;条数;sheet|strip]：这一页改成印样，托盘照片按拍摄先后排成一卷
                // （auto = 按照片比例挑规格；0 = 自动）。已经是印样的只改给了的几项，帧不动。contact:off = 改回网格。
                if arg == "off" {
                    if store.isContactSheet {
                        store.leaveContactSheet()
                        idle()
                    } else { ok = false }
                } else {
                    let bits = arg.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                    let head = at(bits, 0) ?? ""
                    let format = CollageFilmFormat(rawValue: head)
                    let per = at(bits, 1).flatMap { Int($0) }
                    let strips = at(bits, 2).flatMap { Int($0) }
                    let layoutRaw = at(bits, 3) ?? ""
                    let layout = CollageContactLayout(rawValue: layoutRaw)
                    if (head != "auto" && format == nil) || (!layoutRaw.isEmpty && layout == nil) {
                        ok = false
                    } else if store.isContactSheet {
                        store.updateContactSheet { s in
                            if let format { s.format = format }
                            if let per { s.perStrip = min(12, max(0, per)) }
                            if let strips { s.strips = min(12, max(0, strips)) }
                            // 换排法 = 换纸、笔配新纸（同检视器的「排法」）。
                            if let layout { CollageContact.switchLayout(&s, to: layout) }
                        }
                    } else {
                        var spec = CollageContactSheet(format: format ?? CollageContact.suggestedFormat(store.project.photos))
                        spec.perStrip = min(12, max(0, per ?? 0))
                        spec.strips = min(12, max(0, strips ?? 0))
                        if let layout { spec.layout = layout }
                        store.makeContactSheet(spec)
                    }
                }
            case "contactset":
                // contactset:键=值;…（这一页印样的设置）：format layout perStrip strips upright fill marks cross
                // color=C8302A roll=3|auto note=字 edge=字 iso=400 edgeprint jitter tilt=-8 margin=0.05
                // circles=6（一页最多自动圈几个，0 = 不限）gap=0.02|auto（条缝，片宽的比例）
                // paper=F7F6F2|page（这一页的纸；page = 跟着工程底色）choice=roll|best（放不下时上哪几帧，下次按托盘重排时用）；
                // 改 layout 时纸跟着换成那种排法的纸、笔配新纸（同检视器），同一步给了 paper / color 就按给的。
                // 开关写 on/off；字里的逗号、分号写 %2C、%3B。写错一个键整步算「参数不对」。
                let settings: [(String, String)] = arg.split(separator: ";").compactMap { item in
                    let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard kv.count == 2 else { return nil }
                    return (kv[0], kv[1].removingPercentEncoding ?? kv[1])
                }
                guard var sheet = store.page?.contactSheet, !settings.isEmpty else {
                    ok = false
                    break
                }
                func flag(_ v: String) -> Bool? {
                    ["1": true, "on": true, "true": true, "yes": true, "0": false, "off": false, "false": false, "no": false][v]
                }
                for (k, v) in settings {
                    switch k {
                    case "format": if let f = CollageFilmFormat(rawValue: v) { sheet.format = f } else { ok = false }
                    case "layout":
                        if let l = CollageContactLayout(rawValue: v) {
                            if l != sheet.layout, !settings.contains(where: { $0.0 == "paper" }) {
                                sheet.paper = CollageContact.defaultPaper(l)
                                // 笔配新纸（白笔换到白相纸上换回红笔）；同一步给了 color 就按给的。
                                if !settings.contains(where: { $0.0 == "color" }) { CollageContact.fitPen(&sheet) }
                            }
                            sheet.layout = l
                        } else { ok = false }
                    case "paper":
                        if v == "page" || v.isEmpty {
                            sheet.paper = nil
                        } else if let hex = UInt32(v.hasPrefix("#") ? String(v.dropFirst()) : v, radix: 16) {
                            sheet.paper = CollageColor(hex: hex)
                        } else { ok = false }
                    case "choice": if let c = CollageContactChoice(rawValue: v) { sheet.choice = c } else { ok = false }
                    case "perStrip": if let n = Int(v) { sheet.perStrip = min(12, max(0, n)) } else { ok = false }
                    case "strips": if let n = Int(v) { sheet.strips = min(12, max(0, n)) } else { ok = false }
                    case "upright": if let x = flag(v) { sheet.uprightPortraits = x } else { ok = false }
                    case "fill": if let x = flag(v) { sheet.fillFrames = x } else { ok = false }
                    case "marks": if let x = flag(v) { sheet.marks = x } else { ok = false }
                    case "cross": if let x = flag(v) { sheet.crossRejects = x } else { ok = false }
                    case "edgeprint": if let x = flag(v) { sheet.edgePrint = x } else { ok = false }
                    case "jitter": if let x = flag(v) { sheet.jitter = x } else { ok = false }
                    case "color":
                        if let hex = UInt32(v.hasPrefix("#") ? String(v.dropFirst()) : v, radix: 16) {
                            sheet.markColor = CollageColor(hex: hex)
                        } else { ok = false }
                    case "roll":
                        if v == "auto" || v.isEmpty { sheet.roll = nil } else if let n = Int(v) { sheet.roll = min(999, max(1, n)) } else { ok = false }
                    case "note": sheet.note = v
                    case "edge": sheet.edgeText = v
                    case "iso": sheet.iso = v
                    case "tilt":
                        let range = CollageContactSheet.tiltRange
                        if let x = Double(v), x.isFinite { sheet.tilt = min(range.upperBound, max(range.lowerBound, x)) } else { ok = false }
                    case "margin":
                        let range = CollageContactSheet.marginRange
                        if let x = Double(v), x.isFinite { sheet.margin = min(range.upperBound, max(range.lowerBound, x)) } else { ok = false }
                    case "circles":
                        let range = CollageContactSheet.maxCirclesRange
                        if let n = Int(v) { sheet.maxCircles = min(range.upperBound, max(range.lowerBound, n)) } else { ok = false }
                    case "gap":
                        let range = CollageContactSheet.stripGapRange
                        if v == "auto" || v.isEmpty {
                            sheet.stripGap = nil
                        } else if let x = Double(v), x.isFinite {
                            sheet.stripGap = min(range.upperBound, max(range.lowerBound, x))
                        } else { ok = false }
                    default: ok = false
                    }
                }
                if ok {
                    let final = sheet
                    store.updateContactSheet { $0 = final }
                }
            case "contactmark":
                // contactmark:照片 id=circle|cross|dot|cropLine|none|auto（手动定这一帧的记号；auto = 回到自动）。
                if let (id, v) = pair(arg, "="), store.page?.contactSheet?.frames.contains(id) == true,
                   v == "auto" || v == "none" || CollagePencilMark(rawValue: v) != nil {
                    store.updateContactSheet { s in s.markOverrides[id] = v == "auto" ? nil : v }
                } else { ok = false }
            case "contactframes":
                // contactframes:ID;ID;…（这一卷的帧，照给的顺序）| contactframes:tray（托盘照片按拍摄先后重排）。
                if !store.isContactSheet {
                    ok = false
                } else if arg == "tray" {
                    store.makeContactSheet()
                } else {
                    let ids = arg.split(separator: ";").map(String.init)
                    if ids.isEmpty || ids.contains(where: { store.photoMap[$0] == nil }) {
                        ok = false
                    } else {
                        store.updateContactSheet { $0.frames = ids }
                    }
                }
            case "contactdump":
                hintsSettled()
                dumpContact()
            case "insets":
                // insets:0.05;0.08;0.06;0.04（上;下;内;外，相对短边）| insets:none（回到统一外边距）
                let n = nums(arg)
                var st = store.project.style
                if arg == "none" {
                    st.insets = nil
                    store.setStyle(st, coalesce: false)
                } else if n.count == 4, n.allSatisfy(\.isFinite) {
                    // 和读工程文件一样收到 0…0.4（nan、inf、1e300 以前一渲染就崩：边距换算成整数像素时溢出）。
                    let c = n.map { min(0.4, max(0, $0)) }
                    st.insets = CollageInsets(top: c[0], bottom: c[1], inner: c[2], outer: c[3])
                    store.setStyle(st, coalesce: false)
                } else { ok = false }
            case "datevars":
                // datevars:2026-10-23[T10:00:00]：这一天的日期占位符（和压字、文字格展开用的是同一个函数）。
                let parser = DateFormatter()
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.dateFormat = arg.contains("T") ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd"
                if let date = parser.date(from: arg) {
                    let v = CollageTypeset.dateVariables(date)
                    let keys = ["date", "date_cn_full", "weekday_cn", "weekday_en", "month_en", "month_en_title",
                                "day", "day_num", "lunar", "ganzhi", "year_roman"]
                    print("  " + arg + " → " + keys.map { "{\($0)}=\(v[$0] ?? "")" }.joined(separator: " "))
                } else { ok = false }
            case "fonts":
                // fonts：每个字体、每个字重（含斜体）实际解析成哪个 PostScript 名 —— 首选 / 退路、系统自带 /
                // 按需下载（AssetsV2）/ 程序内置。字体菜单里的每一项都在这里过一遍。
                for font in CollageFont.allCases {
                    var cells: [String] = []
                    for weight in CollageWeight.allCases {
                        for italic in [false, true] {
                            let wanted = CollageTypeset.postScriptNames(font, weight, italic: italic)
                            let f = CollageTypeset.font(font, weight, italic: italic, size: 20)
                            let got = CTFontCopyPostScriptName(f) as String
                            let url = CTFontCopyAttribute(f, kCTFontURLAttribute) as? URL
                            let place = url == nil ? "内置" : (url!.path.contains("/AssetsV2/") ? "下载" : "系统")
                            let rank = wanted.firstIndex(of: got).map { $0 == 0 ? "" : "↓\($0)" } ?? "!系统字体"
                            cells.append("\(weight.rawValue)\(italic ? "i" : "")=\(got)\(rank)[\(place)]")
                        }
                    }
                    print("  \(font.rawValue)（\(font.label)）: " + cells.joined(separator: " "))
                }
                print("  内置字体: " + CollageEmbeddedFonts.loadedNames.joined(separator: " "))
                // 启动时注册进了本进程的字体表：按名字找（CoreText、NSFont）也要找得到。
                for name in CollageEmbeddedFonts.loadedNames {
                    let ct = CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 20, nil)) as String
                    let ns = NSFont(name: name, size: 20)?.fontName ?? "nil"
                    print("  进程字体表: \(name) 按名字 CoreText → \(ct) · NSFont → \(ns)"
                          + (ct == name && ns == name ? "（已注册）" : "（没注册上）"))
                }
            case "photofacts":
                // photofacts：托盘每张照片从批量页带来的字段（帧号、场、场内名次、判决、手动、近似重复组、小数秒、
                // 睁眼、黑白、亮度、EXIF、机身）—— 核对 CollageBridge.refresh 和路人信息里顺手算的那两项。
                // 路人信息是后台一张张算的：等这一批都算完（最多 60 秒）再打印。解不出预览的照片没有亮度，不卡。
                hintsSettled()
                // photofacts:DSCF7207 = 只看这一张。
                for p in store.project.photos where arg.isEmpty || p.id == arg {
                    let exif = p.exif?.summary ?? "-"
                    let luma = p.meanLuma.map { String(format: "%.3f", $0) } ?? "-"
                    let subsec = p.captureSubsec.map { String(format: "%.2f", $0) } ?? "-"
                    print("  \(p.id) 帧\(p.frameNo ?? "-") 场\(p.take.map(String.init) ?? "-")#\(p.takeRank.map(String.init) ?? "-") "
                          + "\(p.verdict?.rawValue ?? "-")\(p.isManual ? "(手动)" : "") 组\(p.burstGroup.map(String.init) ?? "-") "
                          + "秒+\(subsec) 睁眼\(p.eyesOpen.map { $0 ? "是" : "否" } ?? "-") "
                          + "黑白\(p.isMonochrome.map { $0 ? "是" : "否" } ?? "-") 亮度\(luma) \(exif) 机身\(p.body ?? "-")")
                }
            case "dumptexts":
                hintsSettled()
                dumpTexts()
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
                // untray:ID 或 untray:ID;ID;…（托盘多选一次移除，记一步撤销）
                store.removeFromTray(arg.split(separator: ";").map(String.init))
                print("  托盘 \(store.project.photos.count) 张 · 提示: " + (store.notice ?? "无"))
            case "untrayunused":
                // 「带照片」菜单的「移除没用上的」
                store.removeFromTray(store.unusedTrayIDs)
                print("  托盘 \(store.project.photos.count) 张 · 提示: " + (store.notice ?? "无"))
            case "untraydropped":
                // 「移除相似拿掉的」（相册去重 / fine-art 编排拿掉、现在也没上版的）
                store.removeFromTray(store.droppedTrayIDs)
                print("  托盘 \(store.project.photos.count) 张 · 提示: " + (store.notice ?? "无"))
            case "trayfilter":
                // trayfilter:all|unused|used（托盘顶上的筛选）
                guard let f = CollageTrayState.Filter(rawValue: arg) else { ok = false; break }
                store.tray.filter = f
                let shown = store.tray.visible(store.project.photos, usage: store.photoUsage)
                store.tray.prune(to: Set(shown.map(\.id)))
                print("  托盘显示 \(shown.count) 张: " + shown.map(\.id).joined(separator: " "))
            case "trayclick":
                // trayclick:ID[+cmd][+shift]（托盘里点一张：单击 / ⌘ / ⇧，按现在显示的顺序）；打印选中的
                let parts = arg.split(separator: "+").map(String.init)
                guard let id = parts.first else { ok = false; break }
                let shown = store.tray.visible(store.project.photos, usage: store.photoUsage).map(\.id)
                store.tray.click(id, command: parts.contains("cmd"), shift: parts.contains("shift"), order: shown)
                print("  托盘选中: " + shown.filter(store.tray.selection.contains).joined(separator: " "))
            case "trayall":
                // ⌘A：选中显示的全部
                let shown = store.tray.visible(store.project.photos, usage: store.photoUsage).map(\.id)
                store.tray.selectAll(shown)
                print("  托盘选中 \(store.tray.selection.count) 张")
            case "trayremove":
                // ⌫：移除选中的（按托盘顺序）
                store.removeFromTray(store.project.photos.map(\.id).filter(store.tray.selection.contains))
                print("  托盘 \(store.project.photos.count) 张 · 选中 \(store.tray.selection.count) · 提示: " + (store.notice ?? "无"))
            case "trayusage":
                // 每张上了几次（托盘角标：1 次打勾，多次标次数）
                let usage = store.photoUsage
                print("  上版次数: " + store.project.photos.map { "\($0.id)=\(usage[$0.id] ?? 0)" }.joined(separator: " "))
            case "cleartray":
                store.clearTray()
            case "waittray":
                // waittray:<张数>：等托盘里有这么多张（后台还在读的交接落下来了）再往下走，最多 60 秒。
                guard let n = Int(arg) else { ok = false; break }
                spin(60) { store.project.photos.count >= n }
                idle()
            case "spintray":
                // spintray:<张数>：等托盘里有这么多张就往下走，不等排版 —— 交接排版还在算的时候改东西（撤销核对用）。
                guard let n = Int(arg) else { ok = false; break }
                spin(60) { store.project.photos.count >= n }
                print("  托盘 \(store.project.photos.count) 张 · 排版" + (store.isSolving ? "还在算" : "已落下"))
            case "batchverdict":
                // batchverdict:DSCF7207=pick|usable|reject：在批量页改判（手动）—— 核对拼图托盘跟着刷新。
                let verdicts: [String: Verdict] = ["pick": .pick, "usable": .usable, "reject": .reject]
                if let (id, v) = pair(arg, "="), let verdict = verdicts[v], batch.item(withID: id) != nil {
                    batch.applyOverrides([id: verdict])
                } else { ok = false }
            case "reattach":
                // reattach：同一个场次再 attach 一次（= 从批量页切回拼图 tab），托盘按批量页现状刷新。
                store.attach(sessionDir: batch.sessionDir, photoDir: dir, batch: batch)
            case "batchswitch":
                // batchswitch：批量页重新载入这个场次（会发「分析结果变了」的通知，拼图托盘跟着刷新）。
                batch.switchSession(to: dir)
                spin(1) { false }
            case "addfiles":
                // addfiles:/图1.jpg;/图2.jpg：托盘「添加文件…」（外部照片：现场跑人脸，帧号按文件名）。
                let before = store.project.photos.count
                store.addFiles(arg.split(separator: ";").map { URL(fileURLWithPath: String($0)) })
                spin(60) { store.project.photos.count > before && store.busyText == nil }
                idle()
            case "frombatch":
                // 批量页多选「拼图 (N)」：frombatch:DSCF7209;DSCF7211（相册里应该新开一个跨页）。
                store.importFromBatch(ids: arg.split(separator: ";").map(String.init), batch: batch, layout: true)
                spin(20) { store.busyText == nil }
                idle()
            case "sticker":
                if let k = CollageSticker(rawValue: arg) { store.addSticker(k) } else { ok = false }
            case "itemmark":
                // itemmark:N=circle|cross|dot|cropLine：第 N 个图层（油性笔）画什么。
                if let (n, v) = pair(arg, "="), let id = itemID(n), let m = CollagePencilMark(rawValue: v) {
                    store.updateItem(id) { it in it = CollageItems.withMark(it, m) }
                } else { ok = false }
            case "itemcolor":
                // itemcolor:N=C8302A：贴纸颜色（油性笔的墨、条码的底、胶带的颜色）。
                if let (n, v) = pair(arg, "="), let id = itemID(n), let hex = UInt32(v, radix: 16) {
                    store.updateItem(id) { $0.color = CollageColor(hex: hex) }
                } else { ok = false }
            case "itemlabel":
                // itemlabel:N=字：标签、邮戳、条码上的字（占位符照常展开；空 = 默认）。
                if let (n, v) = pair(arg, "="), let id = itemID(n) {
                    store.updateItem(id) { $0.label = v }
                } else { ok = false }
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
            case "itemcutout":
                // itemcutout:N=on[;白边;投影]|off：第 N 个图层（相纸）做成抠图贴纸。
                if let (n, v) = pair(arg, "="), let id = itemID(n) {
                    let bits = v.split(separator: ";").map(String.init)
                    let k = bits.dropFirst().compactMap(Double.init)
                    if bits.first == "on" {
                        let c = CollageCutout(stroke: k.first ?? 0.006, shadow: k.count > 1 ? k[1] : 0.5)
                        store.updateItem(id) { $0.cutout = c }
                    } else if bits.first == "off" {
                        store.updateItem(id) { $0.cutout = nil }
                    } else { ok = false }
                } else { ok = false }
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
                // tplthumbs:前缀 = 每个模板缩略图存成 前缀_序号.png（序号按模板名排序；核对缩略图不画水印）。
                if !arg.isEmpty {
                    let names = store.templateThumbs.keys.sorted()
                    for (i, name) in names.enumerated() {
                        guard let cg = store.templateThumbs[name]?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                        try? CollageExport.write(cg, to: outDir.appendingPathComponent("\(arg)_\(i).png"), format: .png,
                                                 quality: 1, dpi: 72)
                    }
                    print("  模板缩略图存了 \(names.count) 张 → \(arg)_*.png")
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
            case "wm", "wmlayer", "wmpos", "wmsize", "wmopacity", "wmmargin", "wmtext", "wmtexton", "wmexif", "wmtile",
                 "wmtiles", "wmsides", "wmskip", "exportwm", "wmcontrast", "wmmarginpref", "wmsigfile", "wmtextpos",
                 "wmtextsize", "wmsig":
                ok = CollageWatermarkCLI.apply(name, arg, store: store)
            case "notice":
                print("  提示: " + (store.notice ?? "无"))
            case "wmdump":
                // wmdump：整个水印的 JSON（核对关掉再打开恢复的是不是原来那份）。
                print("  水印 " + (store.project.watermark.map(CollageWatermarkCLI.json) ?? "无"))
            case "bench", "benchdrag":
                // bench:<次数>:<缩放>：界面预览同款渲染（占位、不带出血、画水印）的耗时，先热两次缓存；
                // benchdrag:<次数>:<缩放>[:<缝的路径>]：每帧把那条缝从 0.35 拖到 0.65 再渲染（= 拖缝）。
                // 打印中位数 / p90（毫秒）：性能门禁拿水印开 / 关各跑一次比。
                let bp = arg.split(separator: ":").map(String.init)
                let frames = max(1, at(bp, 0).flatMap(Int.init) ?? 30)
                let scale = at(bp, 1).flatMap(Double.init) ?? 0.3
                let divider = path(at(bp, 2) ?? "r")
                // 后台还在跑 Vision 的话量出来的是抢 CPU 的时间。
                hintsSettled()
                func timed() -> Double {
                    guard let page = store.page else { return 0 }
                    var opts = CollageRender.Options(scale: scale)
                    opts.includeBleed = false
                    opts.placeholders = true
                    opts.watermark = true
                    let t = Date()
                    _ = CollageRender.render(page: page, project: store.project, hints: store.hints, options: opts)
                    return Date().timeIntervalSince(t) * 1000
                }
                _ = timed()
                _ = timed()
                var times: [Double] = []
                if name == "benchdrag" { store.beginContinuousEdit() }
                for i in 0..<frames {
                    if name == "benchdrag" { store.setRatio(0.35 + 0.3 * Double(i) / Double(frames), at: divider) }
                    times.append(timed())
                }
                if name == "benchdrag" { store.endContinuousEdit() }
                times.sort()
                print(String(format: "  %@ 缩放 %.2f · %d 帧 · 中位 %.2f ms · p90 %.2f · 最慢 %.2f", name, scale, frames,
                             times[frames / 2], times[min(frames - 1, Int(Double(frames) * 0.9))], times[frames - 1]))
            case "exifprobe":
                // exifprobe:<路径>（相对 --out 目录也行）：读一次水印用的 EXIF，打印读到几项、记没记进缓存
                // （读不了的不能缓存：插上移动硬盘之后还得读得到）。
                let file = arg.hasPrefix("/") ? arg : outDir.appendingPathComponent(arg).path
                let values = CollageTypeset.exifValues(file)
                print("  EXIF \(values.count) 项 · " + (CollageTypeset.exifCached(file) ? "缓存了" : "没缓存")
                      + (values["model"].map { " · \($0)" } ?? ""))
            case "toneprobe":
                // toneprobe:/a.jpg;/b.jpg：按 1024 解（同路人信息用的预览尺寸），打印亮度、黑白和判定用的三个量
                // （去偏色后色度 95 分位 < 0.05 / 色相一致度 ≥ 0.95 且按亮度拟合的残差 < 0.08）。
                for file in arg.split(separator: ";").map(String.init) {
                    guard let image = CollageImages.decode(path: file, maxPixel: 1024),
                          let t = CollageVision.tone(of: image) else {
                        print("  \(file) 解不出")
                        continue
                    }
                    print(String(format: "  %@ 亮度 %.3f 色度 %.4f 色相一致 %.3f 残差 %.4f → %@",
                                 (file as NSString).lastPathComponent, t.luma, t.spread, t.hueAlign, t.lumaResidual,
                                 t.mono ? "黑白" : "彩色"))
                }
            case "digest":
                // digest：整个工程（托盘、每页版式、水印）的指纹 —— 撤销之后核对「全都回去了」。
                print("  工程指纹 " + CollageWatermarkCLI.digest(store.project)
                      + " · 托盘 \(store.project.photos.count) 张 · \(store.project.pages.count) 页 · 第 \(store.pageIndex + 1) 页")
            case "wmadopt":
                // wmadopt:<photos|page>:<水印页 state.json>：「套到当前拼图」（和界面同一个交接函数）。
                if let (k, file) = pair(arg, ":"), let kind = CollageMarkLayerKind(rawValue: k) {
                    let refShort = store.project.photos.first.map { Double(min($0.width, $0.height)) } ?? 4000
                    if let req = CollageWatermarkCLI.request(.applyToCurrent(kind), state: file, refShort: refShort) {
                        let before = store.notice
                        CollageHandoff.fromWatermark(req, batch: batch, collage: store)
                        let notice = store.notice.flatMap { $0 == before ? nil : $0 }
                        CollageWatermarkCLI.report(store, refShort: refShort, notices: notice.map { [$0] } ?? [])
                    } else { ok = false }
                } else { ok = false }
            case "wmhandoff", "wmhandoffnowait":
                // wmhandoff:<水印页 state.json>;<原图1>;<原图2>…：水印页「拼图 (N) →」（和界面同一个交接函数）。
                // wmhandoffnowait：发起就走、不等照片读完（核对读照片期间又交接 / 手动改水印）；之后用 wait 等。
                let parts = arg.split(separator: ";").map(String.init)
                let urls = parts.dropFirst().map { URL(fileURLWithPath: $0) }
                let refShort = WatermarkCollageRequest.refShort(of: urls.first)
                if name == "wmhandoffnowait", let file = at(parts, 0),
                   let req = CollageWatermarkCLI.request(.newCollage(urls), state: file, refShort: refShort) {
                    CollageHandoff.fromWatermark(req, batch: batch, collage: store)
                    print("  交接已发起（不等）：\(urls.count) 张")
                } else if name == "wmhandoff", let file = at(parts, 0),
                   let req = CollageWatermarkCLI.request(.newCollage(urls), state: file, refShort: refShort) {
                    // 提示一个槽、5 秒就清：边等边记下新出现的每一条（上一步留下的不算）。
                    var last = store.notice
                    var notices: [String] = []
                    func watch() {
                        guard let n = store.notice, n != last else { return }
                        notices.append(n)
                        last = n
                    }
                    CollageHandoff.fromWatermark(req, batch: batch, collage: store)
                    spin(30) { watch(); return store.busyText == nil }
                    spin(60) { watch(); return !store.isSolving && store.busyText == nil }
                    CollageWatermarkCLI.report(store, refShort: refShort, notices: notices)
                } else { ok = false }
            case "undo":
                store.undo()
            case "redo":
                store.redo()
            case "savetpl":
                // 同界面开关的默认：套固定比例的模板来的页存出来也是固定比例。
                store.saveTemplate(named: arg, fitAspects: !(store.page?.fixedAspects ?? false))
            case "applytpl":
                // 先按全名找，找不到再按名字里含这几个字找（同 --template）；套了哪个打印出来。
                // 写分类名（时尚刊、九宫格…）= 套这个分类的第一个。
                if let t = store.allTemplates.first(where: { $0.name == arg })
                    ?? store.allTemplates.first(where: { $0.builtin && $0.category == arg })
                    ?? store.allTemplates.first(where: { $0.name.contains(arg) }) {
                    store.applyTemplate(t)
                    if t.name != arg { print("  套用「\(t.name)」（\(t.builtin ? t.category : "我的模板")）") }
                } else { ok = false }
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
            case "albumtheme":
                // albumtheme:classic|fineArt（相册自动编排的主题；arrange 按它编）。
                if let t = CollageAlbumTheme(rawValue: arg) {
                    store.setAlbumTheme(t)
                    print("  编排主题 \(t.label)")
                } else { ok = false }
            case "chaptermono":
                // chaptermono:on|off（fine-art 编排的「整章黑白」）。
                if arg == "on" || arg == "off" {
                    store.setAlbumTheme(store.project.albumTheme, chapterMono: arg == "on")
                } else { ok = false }
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
                // renderclean:<文件名>@0.3：按这个缩放出预览（界面预览的缩放跟着窗口大小变，常见 0.3 左右）。
                // 只等路人信息（输入），不等排版：「…nowait」那几步就是要在排版落下之前出图核对。
                hintsSettled()
                let sep = name == "renderclean" ? arg.lastIndex(of: "@") : nil
                let previewScale = sep.flatMap { Double(arg[arg.index(after: $0)...]) }
                let file = previewScale == nil ? arg : String(arg[..<(sep ?? arg.endIndex)])
                var opts = CollageRender.Options(scale: name == "renderexport" ? 1 : previewScale ?? 0.5)
                opts.includeBleed = name == "renderexport"
                opts.debug = name == "render"
                opts.placeholders = name == "renderclean"
                opts.export = name == "renderexport"
                // 水印：renderclean 同预览（一直画），renderexport 同导出（看这个拼图的「导出带水印」）；调试图不画。
                let exportMarks = store.project.watermark?.exportEnabled ?? true
                opts.watermark = name == "renderclean" || (name == "renderexport" && exportMarks)
                let report = CollageRender.RenderReport()
                opts.report = report
                if let page = store.page,
                   let image = CollageRender.render(page: page, project: store.project, hints: store.hints, options: opts) {
                    // 名字以 .png 结尾就存 PNG（逐像素核对水印用：JPEG 会把差异抹到整个 8×8 块）。
                    let png = file.hasSuffix(".png")
                    let url = outDir.appendingPathComponent(png ? file : file + ".jpg")
                    // 加了网的照片 JPEG 质量低了网点边上起振铃：同导出，至少 0.9（没开网点的照旧 0.85，门禁不变）。
                    let quality = store.project.style.halftone != nil ? 0.92 : 0.85
                    try? CollageExport.write(image, to: url, format: png ? .png : .jpeg, quality: quality, dpi: 72)
                    let vars = CollageTypeset.variables(project: store.project, root: page.root, photos: store.photoMap,
                                                        pagePhotoIDs: page.photoIDs, pageID: page.id)
                    print("  出图 \(url.lastPathComponent) · 第 \(store.pageIndex + 1)/\(store.project.pages.count) 页 · {no}=\(vars["no"] ?? "")")
                    // 导出完会弹的提示（同一个函数）：格子空着、签名图找不到……
                    if name == "renderexport", let warning = CollageStore.exportWarning(
                        missing: report.missing, lowRes: report.lowRes, signatureLost: CollageStore.signatureLost(report),
                        fillerBody: CollageStore.fillerBody(report, canvas: store.project.canvas)) {
                        print("  导出提示: " + warning)
                    }
                    // .marks.json 每次都写（以前只有带水印才写）：文字块、取景也在里面，断言脚本不用先开水印。
                    if name != "render" {
                        if store.project.watermark != nil { print("  " + CollageWatermarkCLI.marksSummary(report.marks)) }
                        let stem = png ? String(file.dropLast(4)) : file
                        CollageWatermarkCLI.writeMarks(report, image: image, opts: opts, project: store.project,
                                                       page: page, to: outDir.appendingPathComponent(stem + ".marks.json"))
                    }
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

// MARK: - 水印 op（--collage-ops）

/// --collage-ops 里改拼图水印的 op（<层> = photos | page）：
///   wm:<层>[:签名.png]（打开这一层，默认值；给了路径就导入签名）· wm:off（整个关掉）
///   wmlayer:<层>:off|on（同检视器的开关：关掉记下设置，再开恢复）
///   wmpos:<层>:bottom_right 等 · wmsize:<层>:0.15 · wmopacity:<层>:0.8 · wmmargin:<层>:0.02
///   wmtext:<层>:<文字>（空 = 关文字，同检视器的开关会记下原来的字；逗号是分步符，文字里不能带）
///   wmtexton:<层>（同检视器打开「文字」：恢复关掉前的字）· wmexif:<层>（用 EXIF 模板）· wmtile:<层>:on|off
///   wmtextpos:<层>:<bottom_left 等 raw>（字的位置）· wmtextsize:<层>:<0.03>（字号 × 区域长边）
///   wmsig:<层>:on|off（同检视器的「签名」勾选框：关掉只画字，签名的设置还记着）
///   wmtiles:each|once · wmsides:right|both · wmskip:<照片 id>（切换）· exportwm:on|off（这个拼图导出带不带）
///   wmcontrast:<层>:original|auto|light|dark · wmmarginpref:<层>:on|off（整页层优先放留白）
///   wmsigfile:<路径>[;<sha1>]（直接改签名记录：核对签名文件找不到时的退路和提示）
/// 每个 op 一步撤销（不合并连续调整），脚本按撤销栈深度核对。
@MainActor
enum CollageWatermarkCLI {

    static func apply(_ name: String, _ arg: String, store: CollageStore) -> Bool {
        let kv = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let kind = kv.first.flatMap(CollageMarkLayerKind.init(rawValue:))
        let value = kv.count > 1 ? kv[1] : ""
        switch name {
        case "wm":
            if arg == "off" {
                store.setWatermark(nil)
                return true
            }
            guard let kind else { return false }
            var signature: CollageSignature?
            if !value.isEmpty {
                guard let sig = store.importSignature(from: URL(fileURLWithPath: value)) else { return false }
                signature = sig
            }
            store.updateWatermark { wm in
                if wm.layer(kind) == nil { wm.setLayer(kind, CollageMarkLayer()) }
                if let signature { wm.signature = signature }
            }
        case "wmlayer":
            guard let kind, value == "off" || value == "on", store.project.watermark != nil else { return false }
            store.setMarkLayer(kind, on: value == "on")
        case "wmpos":
            guard let pos = WatermarkEngine.GridPosition(rawValue: value) else { return false }
            return edit(kind, store) { $0.position = pos }
        case "wmsize":
            guard let v = Double(value) else { return false }
            return edit(kind, store) { $0.sizeRatio = min(1, max(0.01, v)) }
        case "wmopacity":
            guard let v = Double(value) else { return false }
            return edit(kind, store) { $0.opacity = min(1, max(0, v)) }
        case "wmmargin":
            guard let v = Double(value) else { return false }
            return edit(kind, store) { $0.marginRatio = min(0.2, max(0, v)) }
        case "wmtext":
            guard !value.isEmpty else {
                guard let kind, store.project.watermark?.layer(kind) != nil else { return false }
                store.setMarkText(kind, on: false)
                return true
            }
            return edit(kind, store) { layer in
                var t = layer.text ?? CollageMarkText()
                t.customText = value
                layer.text = t
            }
        case "wmtexton":
            guard let kind, store.project.watermark?.layer(kind) != nil else { return false }
            store.setMarkText(kind, on: true)
        case "wmexif":
            return edit(kind, store) { layer in
                var t = layer.text ?? CollageMarkText()
                t.customText = ""
                layer.text = t
            }
        case "wmtextpos":
            guard let pos = WatermarkEngine.GridPosition(rawValue: value),
                  let kind, store.project.watermark?.layer(kind)?.text != nil else { return false }
            return edit(kind, store) { $0.text?.position = pos }
        case "wmtextsize":
            guard let v = Double(value), let kind, store.project.watermark?.layer(kind)?.text != nil else { return false }
            return edit(kind, store) { $0.text?.fontSizeRatio = min(0.2, max(0.001, v)) }
        case "wmsig":
            guard value == "on" || value == "off" else { return false }
            return edit(kind, store) { $0.signatureOn = value == "on" }
        case "wmtile":
            guard value == "on" || value == "off" else { return false }
            return edit(kind, store) { $0.tile = value == "on" ? ($0.tile ?? CollageMarkTile()) : nil }
        case "wmtiles":
            guard let tiles = ["each": CollageMarkTiles.eachTile, "once": .once][arg] else { return false }
            store.updateWatermark { $0.tiles = tiles }
        case "wmsides":
            guard let sides = CollageMarkSides(rawValue: arg) else { return false }
            store.updateWatermark { $0.albumSides = sides }
        case "wmskip":
            guard !arg.isEmpty else { return false }
            store.updateWatermark { wm in
                if wm.skipPhotoIDs.remove(arg) == nil { wm.skipPhotoIDs.insert(arg) }
            }
        case "exportwm":
            // 跟着拼图存（一步撤销）；没有水印就无所谓带不带。
            guard arg == "on" || arg == "off", store.project.watermark != nil else { return false }
            store.updateWatermark { $0.exportEnabled = arg == "on" }
        case "wmcontrast":
            guard let contrast = CollageMarkContrast(rawValue: value) else { return false }
            return edit(kind, store) { $0.contrast = contrast }
        case "wmmarginpref":
            guard value == "on" || value == "off" else { return false }
            return edit(kind, store) { $0.preferMargin = value == "on" }
        case "wmsigfile":
            // wmsigfile:<路径>[;<sha1>]：直接改签名记录（核对存的路径没了时按 sha1 找副本、都找不到时的提示）。
            let fk = arg.split(separator: ";", maxSplits: 1).map(String.init)
            guard let file = fk.first, store.project.watermark?.signature != nil else { return false }
            store.updateWatermark { wm in
                wm.signature?.file = file
                if fk.count > 1 { wm.signature?.key = fk[1] }
            }
        default:
            return false
        }
        return true
    }

    /// 改已经开着的一层；没开（或层名写错）= 参数不对。
    private static func edit(_ kind: CollageMarkLayerKind?, _ store: CollageStore,
                             _ body: (inout CollageMarkLayer) -> Void) -> Bool {
        guard let kind, store.project.watermark?.layer(kind) != nil else { return false }
        store.updateWatermark { wm in
            guard var layer = wm.layer(kind) else { return }
            body(&layer)
            wm.setLayer(kind, layer)
        }
        return true
    }

    /// 水印页的 state.json → 交接请求（和水印页 requestCollage 一样：签名文件在、开着签名才带）。
    static func request(_ action: WatermarkCollageRequest.Action, state path: String,
                        refShort: Double) -> WatermarkCollageRequest? {
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? JSONDecoder().decode(WatermarkStore.PersistState.self, from: data) else {
            print("  读不了水印页设置 \(path)")
            return nil
        }
        let signature = state.signaturePath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        return WatermarkCollageRequest(action: action, config: state.config,
                                       signatureURL: state.config.signatureEnabled ? signature : nil,
                                       refShort: refShort,
                                       presetName: WatermarkStore.presetName(matching: state.config, in: state.presets))
    }

    /// 交接之后：托盘里的完整 id、每层换算出的比例、换回引擎的设置、签名副本、出现过的提示。
    static func report(_ store: CollageStore, refShort: Double, notices: [String]) {
        print(String(format: "  refShort %.0f · 托盘 ", refShort) + store.project.photos.map(\.id).joined(separator: " "))
        if let wm = store.project.watermark {
            for kind in CollageMarkLayerKind.allCases {
                guard let layer = wm.layer(kind) else { continue }
                print("  \(kind.label): " + detail(layer))
                let ec = layer.engineConfig(areaShort: 1000)
                print(String(format: "    → 引擎（区域短边 1000）: 签名边距 %.1fpx 文字边距 %.1fpx 相框%@ 画布比例%@",
                             ec.marginX, ec.exifText.marginX, ec.frame.enabled ? "开" : "关",
                             ec.canvasRatio.enabled ? "开" : "关"))
            }
            if let s = wm.signature {
                let exists = FileManager.default.fileExists(atPath: s.file)
                print("  签名 \(s.sourceName) sha1 \(s.key) 副本\(exists ? "在" : "不在") \(s.file)")
            }
        } else {
            print("  水印: 无")
        }
        print("  提示: " + (notices.isEmpty ? "无" : notices.joined(separator: " → ")))
    }

    private static func detail(_ l: CollageMarkLayer) -> String {
        var s = String(format: "签名%@ %@ 大小 %.3f 不透明 %.2f 边距 %.4f", l.signatureOn ? "开" : "关",
                       l.position.rawValue, l.sizeRatio, l.opacity, l.marginRatio)
        if let p = l.landscapePosition { s += " 横向区域 \(p.rawValue)" }
        if let t = l.tint { s += String(format: " 着色 %.2f,%.2f,%.2f", t.r, t.g, t.b) }
        if let t = l.tile { s += String(format: " 平铺 %.0f° 间距 %.2f", t.angleDeg, t.gapRatio) }
        if let t = l.text {
            s += String(format: " 字[%@ %@ 字号 %.3f 边距 %.4f]", t.customText.isEmpty ? "EXIF" : t.customText,
                        t.position.rawValue, t.fontSizeRatio, t.marginRatio)
        }
        if let p = l.presetName { s += " 预设「\(p)」" }
        if l.contrast != .original { s += " 深浅 \(l.contrast.rawValue)" }
        if !l.preferMargin { s += " 不进留白" }
        return s
    }

    /// 出图后的一行：「水印 N 个：photo@01 (x,y,w,h) … · 跳过 k（原因）」（成品坐标，未缩放、不含出血）。
    static func marksSummary(_ marks: [CollageRender.MarkRecord]) -> String {
        let drawn = marks.filter { $0.rect != nil }
        let items = drawn.map { m -> String in
            let r = m.rect ?? .zero
            let kind = m.kind == "text" ? "字" : (m.kind == "tile" ? "平铺" : "")
            // 只标和默认不一样的：放进了留白、深浅选成了白 / 黑。
            let tone = m.contrast == "light" ? "白" : (m.contrast == "dark" ? "黑" : "")
            let flag = (m.skipped.map { "[\($0)]" } ?? "") + (m.inMargin ? "[留白]" : "") + (tone.isEmpty ? "" : "[\(tone)]")
            return String(format: "%@@%@%@ (%.0f,%.0f,%.0f,%.0f)%@", m.layer, m.owner, kind, r.minX, r.minY,
                          r.width, r.height, flag)
        }
        let skipped = marks.filter { $0.rect == nil }
        var s = "水印 \(drawn.count) 个：" + (items.isEmpty ? "无" : items.joined(separator: " "))
        if !skipped.isEmpty {
            let reasons = Dictionary(grouping: skipped, by: { $0.skipped ?? "?" })
                .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: " ")
            s += " · 跳过 \(skipped.count)（\(reasons)）"
        }
        return s
    }

    /// 矩形 → [x, y, w, h]；nil、CGRect.null（空的外接框：x、y 是无穷大）、有不是有限数的分量 = null。
    /// JSONSerialization 碰到无穷大直接抛 Objective-C 异常（整个进程退出），所以一律在这里挡掉。
    static func rectJSON(_ r: CGRect?) -> Any {
        guard let r, !r.isNull else { return NSNull() }
        let v = [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
        return v.allSatisfy(\.isFinite) ? v : NSNull()
    }

    /// report → JSON（断言脚本读）：rect / region = [x, y, w, h]（成品坐标），外加这次出图的缩放、出血，
    /// 和画布的尺寸、安全区、切带、外边距，整页水印进留白时要躲的东西（obstacles；油性笔的笔迹另记 inkObstacles），
    /// 脚本不用再猜。
    /// texts = 每个文字块（压字 / 文字格 / 文字图层）、crops = 每格照片的取景（见 CollageRender.TextRecord / CropRecord）；
    /// masks（主体蒙版）、contactSheet（印样帧号）、halftone（网点）先占位，后面的功能填。
    static func writeMarks(_ report: CollageRender.RenderReport, image: CGImage, opts: CollageRender.Options,
                           project: CollageProject, page: CollagePage, to url: URL) {
        func arr(_ r: CGRect?) -> Any { rectJSON(r) }
        func points(_ ps: [CGPoint]?) -> Any { ps.map { $0.map { [Double($0.x), Double($0.y)] } } ?? NSNull() }
        let marks = report.marks
        let list: [[String: Any]] = marks.map { m in
            var entry: [String: Any] = [
                "layer": m.layer, "owner": m.owner, "kind": m.kind ?? NSNull(), "rect": arr(m.rect),
                "region": arr(m.region), "skipped": m.skipped ?? NSNull(), "cell": arr(m.cell),
                "visible": arr(m.visible), "shape": m.shape ?? NSNull(), "avoid": arr(m.avoid),
                "font": m.font ?? NSNull(), "contrast": m.contrast ?? NSNull(), "inMargin": m.inMargin,
                "local": m.local.map { [Double($0.width), Double($0.height)] } ?? NSNull(),
                "corners": m.corners.map { $0.map { [Double($0.x), Double($0.y)] } } ?? NSNull(),
            ]
            // 同一张照片上有好几个字块：第 2 个起的另起一个键（只有一个字块的旧出图一个键都不多）。
            if !m.avoidMore.isEmpty { entry["avoidMore"] = m.avoidMore.map { arr($0) } }
            return entry
        }
        // 页上图层按画的顺序（后面的压在前面的上面）：转过之后的四个角、导出里印不印。
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        let skip = CollageItems.unprinted(page.items, photos: photos)
        let items: [[String: Any]] = page.items.map { it in
            ["kind": it.kind.rawValue, "printed": !skip.contains(it.id),
             "corners": CollageItems.corners(it, canvas: project.canvas).map { [Double($0.x), Double($0.y)] }]
        }
        let c = project.canvas
        var canvas: [String: Any] = ["width": c.width, "height": c.height, "bleed": c.bleed, "safe": c.safe,
                                     "dpi": c.dpi, "corner": project.style.corner, "margin": project.style.margin,
                                     "seams": c.seams.rawValue, "slides": c.slides, "binding": c.binding.rawValue,
                                     "seamBands": CollageLayout.seamLines(c).map { arr($0) }]
        // 四边边距（上、下、内、外，相对短边）：设了才写 —— 没设的旧出图 canvas 一个键都不多，门禁照旧严格比。
        if let i = project.style.insets { canvas["insets"] = [i.top, i.bottom, i.inner, i.outer] }
        let frames = CollageLayout.pageGeometry(page.root, canvas: c, style: project.style).frames
        // 印样页：手写注记、圈叉的笔迹也算（和 Painter.prepare 同一份，占位符和渲染同一份）；别的页一个框都不多。
        let contact: (text: [CGRect], ink: [CGRect]) = page.contactSheet == nil ? ([], []) : CollageWatermarks.contactObstacles(
            page: page, canvas: c, photos: photos,
            vars: CollageTypeset.variables(project: CollageLooks.project(project, page: page), root: page.root,
                                           photos: photos, pagePhotoIDs: page.photoIDs, pageID: page.id))
        let obstacles = (CollageWatermarks.obstacles(page: page, frames: frames, canvas: c) + contact.text).map { arr($0) }
        let texts: [[String: Any]] = report.texts.map { t in
            var entry: [String: Any] = [
                "owner": t.owner, "kind": t.kind, "layer": t.layer, "rect": arr(t.rect), "corners": points(t.corners),
                "font": t.font, "size": t.size, "lines": t.lines, "sizes": t.sizes, "vertical": t.vertical,
                "occlusion": t.occlusion.map(occlusionJSON) ?? NSNull(),
            ]
            // 转了 90°、带正文的才多这两个键（旧出图的 texts 不变）。
            if t.rotation != 0 { entry["rotation"] = t.rotation }
            if let body = t.body { entry["body"] = body }
            return entry
        }
        let crops: [[String: Any]] = report.crops.map { r in
            ["owner": r.owner, "photoID": r.photoID, "framing": r.framing, "window": arr(r.window), "drawn": arr(r.drawn),
             "cutsFace": r.cutsFace, "contain": r.contain, "faces": r.faces,
             "eyeY": r.eyeY ?? NSNull(), "eyeFrac": r.eyeFrac ?? NSNull(),
             "headTopY": r.headTopY ?? NSNull(), "headTopFrac": r.headTopFrac ?? NSNull(), "headTopSource": r.headTopSource]
        }
        var obj: [String: Any] = ["scale": opts.scale, "includeBleed": opts.includeBleed, "watermark": opts.watermark,
                                  "image": [image.width, image.height], "canvas": canvas, "marks": list,
                                  "obstacles": obstacles, "items": items, "texts": texts, "crops": crops,
                                  "masks": report.masks.map(maskJSON),
                                  "contactSheet": report.contactSheet.map(contactJSON) ?? NSNull(),
                                  "halftone": report.halftone.map(halftoneJSON)]
        // 油性笔的笔迹（整页水印在留白带里能躲就躲的，一小段一个框）：页上有油性笔、印样上有圈叉才写，旧出图一个键都不多。
        let ink = CollageWatermarks.inkObstacles(page: page, canvas: c) + contact.ink
        if !ink.isEmpty { obj["inkObstacles"] = ink.map { arr($0) } }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }

    /// 印样（contactSheet）：每帧的帧号 ↔ 照片 id、画面四个角和外接框、照片实际画出来的那块、转没转、黑边、记号；
    /// 每条的四个角、转角、齿孔数；labels = 帧号 → 照片 id（断言用）。mmPx = 每毫米多少成品像素。
    /// markInk = 这一帧记号的笔迹实际画到哪儿；inkBounds = 排版给圈留的那一圈（圈都在它里面、它不出画布）。
    static func contactJSON(_ r: CollageContact.Record) -> [String: Any] {
        func arr(_ v: CGRect?) -> Any { rectJSON(v) }
        func points(_ ps: [CGPoint]) -> [[Double]] { ps.map { [Double($0.x), Double($0.y)] } }
        let frames: [[String: Any]] = r.frames.map { f in
            ["index": f.index, "label": f.label, "photoID": f.photoID, "strip": f.strip, "rect": arr(f.rect),
             "corners": points(f.corners), "rotated": f.rotated, "drawn": arr(f.drawn), "letterboxed": f.letterboxed,
             "mark": f.mark ?? NSNull(), "markInk": arr(f.markInk), "verdict": f.verdict ?? NSNull(),
             "take": f.take ?? NSNull()]
        }
        let strips: [[String: Any]] = r.stripRecords.map { s in
            ["index": s.index, "frames": s.frames, "angle": s.angle, "corners": points(s.corners), "holes": s.holes]
        }
        var labels: [String: String] = [:]
        for f in r.frames { labels[f.label] = f.photoID }
        return ["format": r.format, "layout": r.layout, "roll": r.roll, "mmPx": r.unit, "perStrip": r.perStrip,
                "strips": r.strips, "tilt": r.tilt, "edgePrinted": r.edgePrinted, "numberOffset": r.numberOffset,
                "frames": frames, "stripGeometry": strips, "labels": labels, "note": r.note ?? NSNull(),
                "noteRect": arr(r.noteRect), "overflow": r.overflow, "bounds": arr(r.bounds),
                "inkBounds": arr(r.inkBounds)]
    }

    /// 人物挡字一块字的遮挡量和决定（texts[].occlusion）。比例都是 0…1。
    static func occlusionJSON(_ o: CollageRender.OcclusionRecord) -> [String: Any] {
        ["measured": o.measured, "total": o.total, "perLetter": o.perLetter, "perLine": o.perLine, "first": o.first,
         "last": o.last,
         "heavy": o.heavy, "letters": o.perLetter.count, "decision": o.decision, "requested": o.requested,
         "reason": o.reason ?? NSNull(), "limit": o.limit, "depth": o.depth, "eyesClear": o.eyesClear ?? NSNull(),
         "band": o.band, "faces": o.faces, "headTopSource": o.headTopSource, "rule": o.rule, "moved": o.moved,
         "mainLine": o.mainLine, "eyeBelow": o.eyeBelow ?? NSNull(), "eyeFar": o.eyeFar,
         "eyeClamp": o.eyeClamp ?? NSNull()]
    }

    /// 一张加了网的照片（halftone）：实际点距（这次渲染的像素）、出没出点（不到 3 像素只调影调）、网型、网角、
    /// 实际用的墨色和纸色。
    static func halftoneJSON(_ h: CollageRender.HalftoneRecord) -> [String: Any] {
        ["owner": h.owner, "photoID": h.photoID, "screen": h.screen, "pitchPx": h.pitchPx, "screened": h.screened,
         "angle": h.angle, "ink": h.ink, "paper": h.paper]
    }

    /// 一格用到的主体蒙版（masks）：蒙版文件名、尺寸、覆盖率、每张脸的头顶、实例、主体以外的人（照片坐标框）。
    static func maskJSON(_ m: CollageRender.MaskRecord) -> [String: Any] {
        ["owner": m.owner, "photoID": m.photoID, "key": m.key, "size": m.size, "coverage": m.coverage,
         "headTop": m.headTop, "instances": m.instances, "selected": m.selected, "cutout": m.cutout,
         "behind": m.behind, "people": m.people]
    }

    /// 整个工程的指纹（键排序的 JSON 取 sha1 前 12 位）：同一次运行里撤销前后比对。
    static func digest(_ project: CollageProject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(project) else { return "?" }
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// 整个水印的 JSON（键排序）：载入行打印，两次运行逐字比对。
    static func json(_ wm: CollageWatermark) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(wm) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }
}
