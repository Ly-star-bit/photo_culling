import Foundation
import CoreGraphics

// MARK: - 相册封面：store 的接口（C2、C4）
//
// 编辑封面（editingCover，在 CollageStore 里）时，选格子、换照片、改字走跨页同一套入口：selection 指封面那块的树，
// updateSelectedCell / updateText(target: .cell(路径, 封面 id)) / setOverlay / swap / move / removeCell / setCrop 都落到
// 封面上，place 转给 placeOnCover（封面能用已经上了跨页的照片：「同一张照片不上两个跨页」管不着封面）。画布坐标：geometry
// 是封面那一页自己的（左上原点，宽高 = CollageBookCover.frontCanvas）；画布上那张预览是整张封面（带包边、出血），封面那一页
// 在整张里的位置 = coverLayout.front.origin（成品像素，乘 previewState.scale 是预览像素）。
// 书脊、包边、板厚、封底只在检视器里改（下面这些 set…）；都是一步撤销。
extension CollageStore {

    /// 现在编辑的那一页用哪张画布：编辑封面 = 封面那一页（单页宽高、没有中缝）；平常 = 工程的画布。
    var editCanvas: CollageCanvas {
        editingCover ? CollageBookCover.frontCanvas(project.canvas) : project.canvas
    }

    /// 取景、压字摆位用的工程：编辑封面时画布换成封面那一页（和渲染封面时同一份）。
    var editProject: CollageProject {
        guard editingCover else { return project }
        var p = project
        p.canvas = editCanvas
        return p
    }

    /// 整张封面的几何（成品像素，左上原点）：整张宽高、封底 / 书脊 / 封面三块、包边、出血。没有封面 = nil。
    var coverLayout: CollageBookCover.Layout? {
        guard isAlbum, let cover = project.bookCover else { return nil }
        return cover.layout(canvas: project.canvas, spreads: project.pages.count)
    }

    /// 书脊估的那一句、书脊太窄没印字那一句（界面、ops 共用）。
    var coverNotes: [String] { project.bookCover?.notes(spreads: project.pages.count) ?? [] }

    /// 封面上贴着书脊、出了安全区的脸（界面标橙、ops 打印；导出不拦）。
    var coverFaceWarnings: [String] {
        guard isAlbum, let cover = project.bookCover else { return [] }
        return cover.faceWarnings(project: project, hints: hints)
    }

    // MARK: 做、去掉

    /// 「做封面」（C2）：主图用扉页那张（没有就分数最高、有人脸的），标题、日期照扉页。已经有封面时 replace = true 才重做
    /// （按现在的扉页重新出封面那块，书脊、包边这些设置留着）。一步撤销。返回做没做。
    @discardableResult
    func makeCover(replace: Bool = false) -> Bool {
        guard isAlbum else {
            setNotice("封面只有相册有：先切到相册")
            return false
        }
        if project.bookCover != nil, !replace {
            setNotice("已经有封面了：在「文档 › 封面」里改，或者先去掉再做")
            return false
        }
        guard var made = CollageBookCover.make(project: project) else {
            setNotice("托盘是空的：先带照片进来再做封面")
            return false
        }
        if let old = project.bookCover {
            // 重做只换封面那块；书脊、包边、板厚、纸厚、书脊字、封底照旧，id 也留着（文字编辑器认它）。
            var kept = old
            kept.front = made.front
            made = kept
        }
        let hero = made.front.photoIDs.first ?? ""
        updateBookCover { $0 = made }
        let spine = made.spineWidthMM(spreads: project.pages.count)
        setNotice("做好封面：主图 \(hero)，书脊 " + String(format: "%.1f", spine) + " mm"
                  + (made.spineMM == nil ? "（估的，照印厂给的数改）" : "") + " · ⌘Z 撤销")
        return true
    }

    func removeCover() {
        guard project.bookCover != nil else { return }
        updateBookCover { $0 = nil }
        setNotice("去掉了封面 · ⌘Z 撤销")
    }

    // MARK: 书脊、包边、板厚、纸厚（检视器的数字框；连着敲合成一步撤销）

    /// 书脊宽（mm）：印厂给的数；nil = 按估算。
    func setCoverSpine(_ mm: Double?) {
        let v = mm.flatMap { $0.isFinite ? min(CollageBookCover.spineRange.upperBound,
                                               max(CollageBookCover.spineRange.lowerBound, $0)) : nil }
        updateBookCover(coalesce: true, key: "coverSpine") { $0?.spineMM = v }
    }

    func setCoverWrap(_ mm: Double) {
        guard mm.isFinite else { return }
        let r = CollageBookCover.wrapRange
        updateBookCover(coalesce: true, key: "coverWrap") { $0?.wrapMM = min(r.upperBound, max(r.lowerBound, mm)) }
    }

    func setCoverBoard(_ mm: Double) {
        guard mm.isFinite else { return }
        let r = CollageBookCover.boardRange
        updateBookCover(coalesce: true, key: "coverBoard") { $0?.boardMM = min(r.upperBound, max(r.lowerBound, mm)) }
    }

    func setCoverSheet(_ mm: Double) {
        guard mm.isFinite else { return }
        let r = CollageBookCover.sheetRange
        updateBookCover(coalesce: true, key: "coverSheet") { $0?.sheetMM = min(r.upperBound, max(r.lowerBound, mm)) }
    }

    /// 书脊字（打字：连着敲合成一步）。nil = 那一段不改。
    func setCoverSpineText(title: String? = nil, date: String? = nil) {
        updateBookCover(coalesce: true, key: "coverSpineText") { cover in
            if let title { cover?.spineTitle = title }
            if let date { cover?.spineDate = date }
        }
    }

    /// 封底那张小照片（nil = 不放）。不在托盘里的照片不收。
    func setCoverBackPhoto(_ id: String?) {
        if let id, photoMap[id] == nil { return }
        updateBookCover { $0?.back.photoID = id }
    }

    func setCoverBackText(_ text: String) {
        updateBookCover(coalesce: true, key: "coverBackText") { $0?.back.text = text }
    }

    /// 封底照片的候选（检视器的菜单）：封面上的、第一个跨页上的，再按分数补托盘里的（废片不要），最多 limit 张。
    func coverBackCandidates(limit: Int = 12) -> [CollagePhotoRef] {
        var ids = project.bookCover?.front.photoIDs ?? []
        ids += project.pages.first?.photoIDs ?? []
        ids += project.photos.filter { $0.verdict != .reject || $0.clientPick }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.map(\.id)
        var seen = Set<String>()
        let map = photoMap
        return ids.filter { seen.insert($0).inserted }.compactMap { map[$0] }.prefix(limit).map { $0 }
    }

    // MARK: 换照片（编辑封面时 place 转到这里）

    /// 照片放进封面那块：中间 = 替换这一格，边上 = 劈开插入；已经在封面上的 = 挪过去（中间对调）。跨页上有没有这张不管
    /// （封面常用书里的一张）。一步撤销；编辑封面时选中放进去的那一格（插入的不选：路径变了）。
    func placeOnCover(photoID: String, at target: [Int], edge: CollageLayout.Edge?) {
        guard photoMap[photoID] != nil, let root = project.bookCover?.front,
              root.node(at: target)?.isLeaf == true else { return }
        var next = root
        var select: [Int]? = target
        if let existing = root.leafPaths().first(where: { root.node(at: $0)?.cell?.photoID == photoID }) {
            guard existing != target else {
                if editingCover { selection = target }
                return
            }
            if let edge, var cell = root.node(at: existing)?.cell {
                // 先插后删（同 move）：插入只改写 target 那一格，existing 的路径不变。
                cell.crop = nil
                cell.locked = false
                next = CollageLayout.remove(at: existing, from: CollageLayout.insert(cell, at: target, edge: edge, into: root))
                select = nil
            } else {
                next = CollageLayout.swapLeaves(root, existing, target)
            }
        } else if let edge {
            next = CollageLayout.insert(.photo(photoID), at: target, edge: edge, into: root)
            select = nil
        } else {
            next.update(at: target) { node in
                var cell = node.cell ?? CollageCell()
                cell.kind = .photo
                cell.photoID = photoID
                cell.text = nil
                cell.crop = nil
                node.cell = cell
            }
        }
        updateBookCover { $0?.front = next }
        if editingCover { selection = select }
    }

    // MARK: 画布预览（编辑封面时 startRenderLoop 渲这一张）

    struct CoverPreviewJob {
        var project: CollageProject
        var hints: [String: CollageCrop.Hints]
        var scale: Double
        var guides: Bool

        func render() -> CGImage? {
            var opts = CollageRender.Options(scale: scale)
            opts.includeBleed = true
            opts.guides = guides
            opts.placeholders = true
            // 预览 = 导出：水印一直画（同跨页的预览）。
            opts.watermark = true
            return CollageBookCoverRender.render(project: project, hints: hints, options: opts)
        }
    }

    /// 整张封面（带包边、出血）放进画布视口的那个缩放。没在编辑封面 / 没有封面 = nil。
    func coverPreviewJob() -> CoverPreviewJob? {
        guard editingCover, let layout = coverLayout else { return nil }
        let vp = previewViewport
        let sx = Double(vp.width) / Double(max(1, layout.width))
        let sy = Double(vp.height) / Double(max(1, layout.height))
        return CoverPreviewJob(project: project, hints: hints, scale: max(0.05, min(1, min(sx, sy))), guides: showGuides)
    }
}

// MARK: - ops（--collage-ops 的 cover:…，C5）

/// cover:make（做封面，同「文档 › 封面」的按钮）、cover:remake（按现在的扉页重做封面那块，书脊这些留着）、cover:off（去掉）、
/// cover:edit / cover:done（进 / 出封面编辑：之后的 sel、place、swap、tset、renderexport… 都落在封面上）、
/// cover:spine=12.5|auto（书脊 mm；auto = 按估算）、cover:wrap=15、cover:board=2、cover:sheet=0.15（每张纸厚）、
/// cover:title=<书脊标题>、cover:date=<书脊日期>（可以用占位符，空 = 不印）、cover:back=<照片 id>|none、cover:backtext=<字>、
/// cover:dump（打印尺寸、书脊字怎么排、提示、封面那块的格子）。每个改动的 op 一步撤销。
@MainActor
enum CollageBookCoverCLI {

    static func apply(_ arg: String, store: CollageStore) -> Bool {
        let kv = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let key = kv.first ?? ""
        let value = kv.count > 1 ? kv[1] : nil
        switch key {
        case "make":
            print("  做封面：" + (store.makeCover() ? "做好了" : "没做（\(store.notice ?? "")）"))
        case "remake":
            print("  重做封面：" + (store.makeCover(replace: true) ? "做好了" : "没做（\(store.notice ?? "")）"))
        case "off":
            store.removeCover()
        case "edit":
            store.setEditingCover(true)
            print("  编辑封面：" + (store.editingCover ? "是" : "进不去（没有封面或不是相册）"))
        case "done":
            store.setEditingCover(false)
        case "spine":
            guard let v = value else { return false }
            if v == "auto" { store.setCoverSpine(nil) } else if let mm = Double(v) { store.setCoverSpine(mm) } else { return false }
        case "wrap", "board", "sheet":
            guard let v = value.flatMap(Double.init) else { return false }
            switch key {
            case "wrap": store.setCoverWrap(v)
            case "board": store.setCoverBoard(v)
            default: store.setCoverSheet(v)
            }
        case "title":
            store.setCoverSpineText(title: value ?? "")
            store.endCoalescing()
        case "date":
            store.setCoverSpineText(date: value ?? "")
            store.endCoalescing()
        case "back":
            guard let v = value else { return false }
            if v == "none" {
                store.setCoverBackPhoto(nil)
            } else {
                guard store.photoMap[v] != nil else { return false }
                store.setCoverBackPhoto(v)
            }
        case "backtext":
            store.setCoverBackText(value ?? "")
            store.endCoalescing()
        case "dump":
            for line in dump(store) { print("  " + line) }
        default:
            return false
        }
        // 数字框、打字合成一步撤销：ops 每步各算一步（脚本按撤销栈深度核对）。
        store.endCoalescing()
        return true
    }

    /// cover:dump 和出图时打印的几行：尺寸（mm、像素）、三块的位置、书脊字、提示、封面那块的格子。
    static func dump(_ store: CollageStore) -> [String] {
        guard let cover = store.project.bookCover, let layout = store.coverLayout else {
            return ["封面：没有" + (store.isAlbum ? "" : "（不是相册）")]
        }
        let canvas = store.project.canvas
        let spreads = store.project.pages.count
        func mm(_ px: Int) -> String { String(format: "%.1fmm", Double(px) / max(1, canvas.dpi) * 25.4) }
        func rect(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }
        var out: [String] = []
        let spine = cover.spineWidthMM(spreads: spreads)
        out.append("封面 \(layout.width)×\(layout.height)px（\(mm(layout.width))×\(mm(layout.height))）· 单页 \(layout.pageW)×\(layout.pageH)"
                   + " · 书脊 " + String(format: "%.2f", spine) + "mm=\(layout.spine)px"
                   + (cover.spineMM == nil ? "（估：\(CollageBookCover.pageCount(spreads: spreads))P × "
                      + String(format: "%.2f", cover.sheetMM) + " ÷ 2 + 2 × " + String(format: "%.1f", cover.boardMM) + "）" : "（填的）")
                   + " · 包边 \(mm(layout.wrap))=\(layout.wrap)px · 出血 \(layout.bleed)px")
        out.append("看得见 \(rect(layout.trim)) · 封底 \(rect(layout.back)) · 书脊 \(rect(layout.spineRect)) · 封面 \(rect(layout.front))")
        var photos: [String: CollagePhotoRef] = [:]
        for p in store.project.photos where photos[p.id] == nil { photos[p.id] = p }
        let vars = CollageBookCoverRender.spineVariables(cover: cover, project: store.project, photos: photos)
        if let s = CollageBookCoverRender.spineLayout(cover: cover, vars: vars, rect: layout.spineRect, spineMM: spine,
                                                      canvas: canvas, scale: 1) {
            let runs = s.glyphs.map { ($0.upright ? "立" : "转") + "「\($0.text)」" }.joined(separator: " ")
            let inside = s.glyphs.allSatisfy { layout.spineRect.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }
            let ordered = zip(s.glyphs, s.glyphs.dropFirst()).allSatisfy { $0.frame.minY <= $1.frame.minY }
            out.append("书脊字 " + String(format: "%.0fpx", Double(s.fontSize)) + "：" + runs
                       + " · " + (inside ? "都在书脊里" : "出了书脊") + " · " + (ordered ? "从上往下" : "顺序乱了"))
        } else {
            out.append("书脊字：没印（" + (cover.hasSpineText ? "书脊太窄" : "没有字") + "）")
        }
        for note in cover.notes(spreads: spreads) { out.append("提示：" + note) }
        for warning in store.coverFaceWarnings { out.append("提醒：" + warning) }
        let leaves = cover.front.leafPaths().map { p -> String in
            let cell = cover.front.node(at: p)?.cell
            let tag = cell?.kind == .text ? "文字" : (cell?.photoID ?? (cell?.kind == .empty ? "留白" : "空"))
            return (p.isEmpty ? "r" : p.map(String.init).joined()) + "=" + tag
        }
        out.append("封面那块：" + leaves.joined(separator: " ")
                   + " · 封底：" + (cover.back.photoID ?? "无照片") + (cover.back.text.isEmpty ? "" : "「\(cover.back.text)」"))
        return out
    }

    /// 编辑封面时的 render / renderclean / renderexport：出整张封面。renderexport = 导出同款（成品尺寸 × 导出倍数，带包边、
    /// 出血，不画占位、参考线）；renderclean[@缩放] / render = 画布预览同款（带参考线、占位）。名字以 .png 结尾存 PNG。
    static func render(_ name: String, _ arg: String, store: CollageStore, outDir: URL) -> Bool {
        let sep = name == "renderclean" ? arg.lastIndex(of: "@") : nil
        let previewScale = sep.flatMap { Double(arg[arg.index(after: $0)...]) }
        let file = previewScale == nil ? arg : String(arg[..<(sep ?? arg.endIndex)])
        guard !file.isEmpty else { return false }
        let export = name == "renderexport"
        let exportScale = CollageStore.exportScale(canvas: store.project.canvas, options: store.exportOptions)
        var opts = CollageRender.Options(scale: export ? Double(exportScale) : previewScale ?? 0.5)
        opts.includeBleed = true
        opts.export = export
        opts.guides = !export
        opts.placeholders = !export
        opts.watermark = !export || (store.project.watermark?.exportEnabled ?? true)
        let report = CollageRender.RenderReport()
        opts.report = report
        guard let image = CollageBookCoverRender.render(project: store.project, hints: store.hints, options: opts) else {
            print("  封面出图失败（没有封面？）")
            return false
        }
        let png = file.hasSuffix(".png")
        let url = outDir.appendingPathComponent(png ? file : file + ".jpg")
        try? CollageExport.write(image, to: url, format: png ? .png : .jpeg, quality: 0.85, dpi: 72)
        print("  出图 \(url.lastPathComponent) · 封面 \(image.width)×\(image.height)")
        for line in dump(store) { print("  " + line) }
        if export, let warning = CollageStore.exportWarning(missing: report.missing, lowRes: report.lowRes,
                                                            signatureLost: CollageStore.signatureLost(report)) {
            print("  导出提示: " + warning)
        }
        return true
    }

    /// --collage-ui 的 --cover：截图前先做封面（看「文档 › 封面」做好之后的样子）。
    static func prepareSnapshot(_ store: CollageStore) {
        _ = store.makeCover()
        for line in dump(store) { print(line) }
    }
}
