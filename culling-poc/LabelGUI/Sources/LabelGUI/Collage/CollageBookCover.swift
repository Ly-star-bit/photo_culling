import Foundation
import CoreGraphics

// MARK: - 相册封面（C1：模型和尺寸）
//
// 精装相册的封面是一整张：封底 | 书脊 | 封面，四周再加包边（封面纸翻过板边包到里面的那一圈）和出血。
// 尺寸从画布的单页宽高算（跨页画布宽的一半 × 高），书脊宽照印厂给的数填，没填就按页数估一个（界面写明是估的）。
// 封面那一块是一棵切分树（照片 / 文字 / 留白，和跨页同一套 CollageNode），编辑时 CollageStore.editingCover
// 把选格子、换照片、改字都指到它上面；封面不进 pages，也不进跨页 PDF（印厂一般要封面单独一份）。
// 和 CollageCover（杂志封面的人物挡字）不是一回事：那个管的是一格照片上的字压在人后面。
//
// 渲染、导出在 CollageBookCoverRender.swift；store 的接口、ops、文档面板在 CollageBookCoverStore.swift。

struct CollageBookCover: Codable, Hashable {
    /// 编辑封面时当「页 id」用：文字编辑器迟到的提交（CollageTextTarget.cell 带的 pageID）按它认是不是还在封面上。
    var id = UUID()
    /// 封面那一块（一页大小）的切分树。
    var front: CollageNode
    /// 封底：留白，或者一张小照片 + 一行字。
    var back = CollageBookCoverBack()
    /// 书脊宽（mm），照印厂给的数填；nil = 按页数估（estimatedSpineMM，界面上写明是估的）。
    var spineMM: Double?
    /// 包边（mm）：封面纸翻过板边包到里面的那一圈。15mm 是精装常见的量级，照印厂的模板改。
    var wrapMM = CollageBookCover.defaultWrapMM
    /// 封面板厚（mm）：只用来估书脊（前后两块板）。
    var boardMM = CollageBookCover.defaultBoardMM
    /// 每一张内页（正反两面 = 2P）多厚（mm）：只用来估书脊。默认按装订给一个量级（defaultSheetMM），不是哪家印厂的数。
    var sheetMM = CollageBookCover.defaultSheetMM(.layflat)
    /// 书脊上的字：标题、日期，可以用 {title}、{date} 这些占位符（同文字格）。空 = 那一段不印。
    var spineTitle = "{title}"
    var spineDate = "{date}"

    init(front: CollageNode) { self.front = front }

    // MARK: 默认值和范围

    static let defaultWrapMM = 15.0
    static let defaultBoardMM = 2.0
    /// 书脊窄于这个就不印字（字号再小印出来也看不清、对不齐书脊），界面和导出都提示一句。
    static let minSpineTextMM = 6.0
    static let wrapRange: ClosedRange<Double> = 0...40
    static let boardRange: ClosedRange<Double> = 0...10
    static let sheetRange: ClosedRange<Double> = 0.02...3
    static let spineRange: ClosedRange<Double> = 0...150

    /// 每张内页厚度的默认值（mm），只是估书脊的起点，偏保守的量级：
    /// - 胶装 / 锁线：一般印刷用的铜版纸、哑粉纸一张 0.1–0.2mm，取 0.15；
    /// - 平铺对裱：每张是两面照片纸裱在一起（常夹一层卡纸），明显厚得多，取 0.6。
    /// 都不是哪家印厂的数：各家纸、裱法差得很远，书脊宽一律以印厂给的为准（spineMM）。
    static func defaultSheetMM(_ binding: CollageBinding) -> Double {
        binding == .layflat ? 0.6 : 0.15
    }

    // MARK: 书脊

    /// 印厂说的「P」：一个跨页 = 2P。
    static func pageCount(spreads: Int) -> Int { max(0, spreads) * 2 }

    /// 按「P 数 × 每张纸厚 ÷ 2 + 2 × 板厚」估的书脊宽（mm）。只是估：界面上写清楚，照印厂给的数改。
    func estimatedSpineMM(spreads: Int) -> Double {
        Double(Self.pageCount(spreads: spreads)) * sheetMM / 2 + 2 * boardMM
    }

    /// 实际用的书脊宽（mm）：填了用填的，没填用估的。
    func spineWidthMM(spreads: Int) -> Double { spineMM ?? estimatedSpineMM(spreads: spreads) }

    /// 书脊够不够宽印字。
    static func spineFitsText(_ mm: Double) -> Bool { mm + 1e-9 >= minSpineTextMM }

    /// 书脊上有没有要印的字（标题、日期至少一段不空）。
    var hasSpineText: Bool {
        !spineTitle.trimmingCharacters(in: .whitespaces).isEmpty || !spineDate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 界面、ops、导出提示用的几句：书脊是估的（怎么估的）、书脊太窄没印字。
    func notes(spreads: Int) -> [String] {
        var out: [String] = []
        let spine = spineWidthMM(spreads: spreads)
        if spineMM == nil {
            out.append(String(format: "书脊 %.1f mm 是估的：%dP × 每张 %.2f mm ÷ 2 + 两块板 2 × %.1f mm，照印厂给的数改",
                              spine, Self.pageCount(spreads: spreads), sheetMM, boardMM))
        }
        if hasSpineText, !Self.spineFitsText(spine) {
            out.append(String(format: "书脊只有 %.1f mm，放不下字（至少 %.0f mm）：书脊上没印字", spine, Self.minSpineTextMM))
        }
        return out
    }

    // MARK: 脸离书脊、包边折线太近

    /// 书脊那一侧让出多宽（mm）：精装封面板和书脊之间有一道沟，翻开时那一条会折进去。取和胶装中缝带一样的 12mm
    /// （CollageCanvas.foldBand）—— 不是哪家印厂的数，照印厂的模板改版式。
    static let hingeMM = 12.0

    /// 封面那一页上压到书脊那一侧（hingeMM 以内）、或者出了安全区（离包边折线太近）的脸：每张照片一句。取景和渲染同一个
    /// （CollageCrop.window，人物挡字的封面取景格不算）。版式本身保证脸只在封面这一页里（不会进书脊、包边），这里管的是
    /// 贴边那几毫米：零边距铺满时脸贴着书脊、贴着折线最容易出事。
    func faceWarnings(project: CollageProject, hints: [String: CollageCrop.Hints]) -> [String] {
        faceWarningItems(project: project, hints: hints).map(\.text)
    }

    /// 同 faceWarnings，带上是哪张照片（导出前检查要）。
    func faceWarningItems(project: CollageProject, hints: [String: CollageCrop.Hints]) -> [(photo: String, text: String)] {
        let canvas = Self.frontCanvas(project.canvas)
        let style = project.style
        let w = Double(canvas.width)
        let h = Double(canvas.height)
        let hinge = max(Double(canvas.safe), canvas.pixels(mm: Self.hingeMM))
        let safe = Double(canvas.safe)
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        let frames = CollageLayout.pageGeometry(front, canvas: canvas, style: style).frames
        var out: [(photo: String, text: String)] = []
        for frame in frames where frame.cell.kind == .photo && !CollageCover.applies(to: frame.cell) {
            guard let id = frame.cell.photoID, let photo = photos[id] else { continue }
            let area = CollageCrop.photoArea(cell: frame.cell, rect: frame.rect.cgRect, style: style)
            let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: frames, photos: photos,
                                                         tight: style.tightSmallCells)
            let window = CollageCrop.window(for: photo, cell: frame.cell, cellAspect: CollageCrop.aspect(of: area),
                                            framing: framing, hints: hints[id])
            let drawn = CollageCrop.drawnRect(window: window, photo: photo, cell: frame.cell, in: area)
            let faces = CollageCrop.faceBoxes(photo: photo, window: window, in: drawn).map { $0.intersection(area) }
                .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            if faces.contains(where: { Double($0.minX) < hinge }) {
                out.append((id, String(format: "%@ 的脸离书脊不到 %.0f mm（翻开时折进书脊那道沟）：在封面里换个取景或往右挪",
                                       id, Self.hingeMM)))
            } else if faces.contains(where: { Double($0.minY) < safe || Double($0.maxY) > h - safe || Double($0.maxX) > w - safe }) {
                out.append((id, "\(id) 的脸出了安全区（离包边折线太近，裁切、包边会切到）：在封面里换个取景"))
            }
        }
        return out
    }

    /// 导出前检查（CollagePreflight）里封面的几条（不指到哪个跨页：page = nil，格子路径是封面那一块的）：
    /// - 拦：封面上的空照片格（导出来是一块底色，同跨页的空格）、放大超过 150%；
    /// - 提醒：放大 120–150%、书脊宽还是估的、书脊太窄印不下字、脸贴着书脊 / 出了安全区。
    /// 以前只有后面那几样提醒：封面上一格空着、或者放大到糊，导出时一声不吭（R2#3）。没有封面 = 空。
    static func preflightIssues(project: CollageProject, hints: [String: CollageCrop.Hints]) -> [CollagePreflightIssue] {
        guard project.mode == .album, let cover = project.bookCover else { return [] }
        var out = cover.photoIssues(project: project, hints: hints)
        let notes = cover.notes(spreads: project.pages.count).map { (photo: String?.none, text: $0) }
        let faces = cover.faceWarningItems(project: project, hints: hints).map { (photo: Optional($0.photo), text: $0.text) }
        out += (notes + faces).map {
            CollagePreflightIssue(kind: .cover, severity: .warn, page: nil, photoID: $0.photo, message: "封面：" + $0.text)
        }
        return out
    }

    /// 封面那一块的空照片格（照片格里没放照片、或者放的照片不在托盘里 —— 同 CollageStore.emptyPhotoSlots 的判断）和
    /// 放大倍数（同跨页：印刷画布上 > 120% 提醒、> 150% 拦；取景和封面渲染同一个：画布换成 frontCanvas、pages 清空）。
    func photoIssues(project: CollageProject, hints: [String: CollageCrop.Hints]) -> [CollagePreflightIssue] {
        var frontProject = project
        frontProject.canvas = Self.frontCanvas(project.canvas)
        frontProject.pages = []
        let canvas = frontProject.canvas
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        var out: [CollagePreflightIssue] = []
        let frames = CollageLayout.pageGeometry(front, canvas: canvas, style: project.style).frames
        for f in frames where f.cell.kind == .photo && !f.rect.isEmpty {
            if let id = f.cell.photoID, photos[id] != nil { continue }
            out.append(CollagePreflightIssue(kind: .cover, severity: .block, page: nil, path: f.path,
                                             message: "封面：有一个空照片格，导出来是一块底色：从托盘拖照片进去，或者删掉那一格"))
        }
        guard project.canvas.isPrint else { return out }
        let placed = CollagePreflight.placements(page: editPage, index: 0, project: frontProject, photos: photos, hints: hints)
        for p in placed {
            let k = CollageCrop.upscale(photo: p.photo, window: p.window, drawn: p.drawn)
            guard k > CollageStore.upscaleLimit else { continue }
            let pct = Int((k * 100).rounded())
            let block = k > CollagePreflight.upscaleBlock
            let file = URL(fileURLWithPath: p.photo.path).deletingPathExtension().lastPathComponent
            let name = file.isEmpty ? p.photo.id : file
            let tail = block ? "印出来会糊" : "印出来会软"
            out.append(CollagePreflightIssue(kind: .cover, severity: block ? .block : .warn, page: nil, path: p.path,
                                             photoID: p.photo.id,
                                             message: "封面：\(name) 放大到 \(pct)%：\(tail)，少裁一点或缩小那一格"))
        }
        return out
    }

    // MARK: 照片

    /// 封面上用到的照片（封面那块的格子 + 封底那张）。
    var photoIDs: [String] { front.photoIDs + (back.photoID.map { [$0] } ?? []) }

    /// 拿出托盘的照片：格子变成空格（同跨页，留着占位）、封底那张去掉。
    mutating func clearPhotos(_ gone: Set<String>) {
        for path in front.leafPaths() where front.node(at: path)?.cell?.photoID.map(gone.contains) == true {
            front.update(at: path) {
                $0.cell?.photoID = nil
                $0.cell?.crop = nil
            }
        }
        if let id = back.photoID, gone.contains(id) { back.photoID = nil }
    }

    /// 编辑封面时 store 当「当前页」用的那一页：封面那块的树，id 是封面自己的（不在 pages 里）。
    var editPage: CollagePage {
        var page = CollagePage(root: front)
        page.id = id
        return page
    }

    // MARK: 尺寸（成品像素）

    /// 单页宽（像素）：相册跨页画布宽的一半；不是跨页（理论上相册都是）就是整个宽。
    static func pageWidth(_ canvas: CollageCanvas) -> Int {
        canvas.seams == .fold ? canvas.width / 2 : canvas.width
    }

    /// 封面那一块当成一页画布：单页宽高、同 dpi、同安全区，没有中缝、没有出血（包边和出血在拼整张时补，见
    /// CollageBookCoverRender.mirrorEdges）。文字格按它的安全区退、取景按这一格算 —— 字和脸只会落在封面这一页里，
    /// 不压书脊、不进包边。
    static func frontCanvas(_ canvas: CollageCanvas) -> CollageCanvas {
        var c = CollageCanvas(name: "封面", width: max(64, pageWidth(canvas)), height: canvas.height, dpi: canvas.dpi,
                              bleed: 0, safe: canvas.safe, seams: .none)
        c.binding = canvas.binding
        return c
    }

    /// 整张封面的几何（scale = 1 是成品像素；预览、缩略图按缩放后的整数像素算，和 CollageRender 同一种取整）。
    struct Layout: Hashable {
        var pageW: Int
        var pageH: Int
        var spine: Int
        var wrap: Int
        var bleed: Int
        /// 每边往外延多少：包边 + 出血。
        var extent: Int { wrap + bleed }
        var width: Int { 2 * extent + 2 * pageW + spine }
        var height: Int { 2 * extent + pageH }
        /// 封底 | 书脊 | 封面（翻开平放看得见的那块 = 板子；四条边是包边往里折的折线）。左上原点。
        /// 封面 PDF 的 TrimBox 不是它，是 wrapRect（封面纸在包边外沿裁）。
        var trim: CGRect { CGRect(x: extent, y: extent, width: 2 * pageW + spine, height: pageH) }
        var back: CGRect { CGRect(x: extent, y: extent, width: pageW, height: pageH) }
        var spineRect: CGRect { CGRect(x: extent + pageW, y: extent, width: spine, height: pageH) }
        var front: CGRect { CGRect(x: extent + pageW + spine, y: extent, width: pageW, height: pageH) }
        /// 包边外沿以内（出血以内）：板子 + 四周包边。封面纸在这里裁（封面 PDF 的 TrimBox、四角裁切线）；包边从 trim 的
        /// 四条边往里折到板子背面。
        var wrapRect: CGRect { CGRect(x: bleed, y: bleed, width: width - 2 * bleed, height: height - 2 * bleed) }
    }

    /// 这张画布、这个封面、这么多跨页时整张封面的几何。scale：渲染缩放（宽高按和 CollageRender 一样的取整）。
    func layout(canvas: CollageCanvas, spreads: Int, scale: Double = 1) -> Layout {
        let front = Self.frontCanvas(canvas)
        func px(_ mm: Double) -> Int { Int((canvas.pixels(mm: mm) * scale).rounded()) }
        return Layout(pageW: Int((Double(front.width) * scale).rounded()),
                      pageH: Int((Double(front.height) * scale).rounded()),
                      spine: px(spineWidthMM(spreads: spreads)),
                      wrap: px(wrapMM),
                      bleed: Int((Double(canvas.bleed) * scale).rounded()))
    }

    // MARK: C2 做封面

    /// 「做封面」一键：主图用扉页那张（第一个跨页是「一张照片 + 字」的扉页），没有就挑分数最高、有人脸的
    /// （废片不要，客户选中的废片可以）；标题、日期照扉页的字（字体、字号、颜色），扉页没有字就用居中标题。
    /// 每张纸厚按现在的装订给默认值。托盘里一张照片都没有 = nil。
    static func make(project: CollageProject) -> CollageBookCover? {
        let opener = openerParts(project)
        guard let hero = opener?.photo ?? heroCandidate(project) else { return nil }
        var cover = CollageBookCover(front: frontTree(hero: hero, texts: opener?.texts ?? []))
        cover.sheetMM = defaultSheetMM(project.canvas.binding)
        return cover
    }

    /// 扉页：第一个跨页只有一张照片、还有文字格（默认编排的「左页竖排标题 + 右页主图」、婚礼编排的「左页标题 +
    /// 日期、右页一张宽景」都是）。返回那张照片和文字格里的字（阅读顺序）。
    static func openerParts(_ project: CollageProject) -> (photo: String, texts: [CollageText])? {
        guard let first = project.pages.first, !first.freeform, first.contactSheet == nil else { return nil }
        let ids = first.root.photoIDs
        let texts = first.root.leaves.compactMap { $0.kind == .text ? $0.text : nil }
        guard ids.count == 1, !texts.isEmpty, project.photo(ids[0]) != nil else { return nil }
        return (ids[0], texts)
    }

    /// 没有扉页时的主图：分数最高、有人脸的；都没有人脸就分数最高的。废片不挑（客户选中的除外）。
    static func heroCandidate(_ project: CollageProject) -> String? {
        let usable = project.photos.filter { $0.verdict != .reject || $0.clientPick }
        let pool = usable.isEmpty ? project.photos : usable
        let ranked = pool.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        return (ranked.first { !$0.faces.isEmpty } ?? ranked.first)?.id
    }

    /// 封面那块的默认版式：竖排标题 → 照片在左（靠书脊）、字在右；横排 → 照片在上、字在下。扉页拆成上下两格的
    /// 标题 + 日期并回一块字。照片铺满它那一格（不完整显示）。
    static func frontTree(hero: String, texts: [CollageText]) -> CollageNode {
        let photo = CollageNode.leaf(.photo(hero, role: .hero))
        guard var text = texts.first else {
            return .split(.column, 0.8, photo, .leaf(.text(CollageTemplates.centeredTitle())))
        }
        if texts.count > 1 { text.lines += texts.dropFirst().flatMap(\.lines) }
        text.alignH = .center
        text.alignV = .center
        if text.isTall { return .split(.row, 0.72, photo, .leaf(.text(text))) }
        return .split(.column, 0.8, photo, .leaf(.text(text)))
    }
}

/// 封底：留白，或者一张小照片 + 一行字（都可以只有一样）。
struct CollageBookCoverBack: Codable, Hashable {
    var photoID: String?
    /// 一行字（可以用占位符）；空 = 不印。
    var text = ""

    init(photoID: String? = nil, text: String = "") {
        self.photoID = photoID
        self.text = text
    }

    var isBlank: Bool { photoID == nil && text.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - 容错解码（缺键 = 默认值，坏值夹回能用的范围；坏了只丢封面自己，工程照常读回）

private extension KeyedDecodingContainer {
    func coverSoft<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func coverOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

private func clampedMM(_ v: Double?, _ range: ClosedRange<Double>) -> Double? {
    guard let v, v.isFinite else { return nil }
    return min(range.upperBound, max(range.lowerBound, v))
}

extension CollageBookCover {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 封面那块的树是封面本身：读不出来就当这份封面坏了（CollageProject 那边 softOptional = 不做封面）。
        front = try c.decode(CollageNode.self, forKey: .front)
        id = c.coverSoft(.id, UUID())
        back = c.coverSoft(.back, CollageBookCoverBack())
        spineMM = clampedMM(c.coverOptional(.spineMM), Self.spineRange)
        wrapMM = clampedMM(c.coverSoft(.wrapMM, Self.defaultWrapMM), Self.wrapRange) ?? Self.defaultWrapMM
        boardMM = clampedMM(c.coverSoft(.boardMM, Self.defaultBoardMM), Self.boardRange) ?? Self.defaultBoardMM
        let sheetDefault = Self.defaultSheetMM(.layflat)
        sheetMM = clampedMM(c.coverSoft(.sheetMM, sheetDefault), Self.sheetRange) ?? sheetDefault
        spineTitle = c.coverSoft(.spineTitle, "{title}")
        spineDate = c.coverSoft(.spineDate, "{date}")
    }
}

extension CollageBookCoverBack {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photoID = c.coverOptional(.photoID)
        text = c.coverSoft(.text, "")
    }
}
