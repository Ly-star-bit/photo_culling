import Foundation
import CoreGraphics

// MARK: - 导出前检查（相册 B · P3）
//
// 一本相册交出去之前要看的几样，一条一条列出来，点一下跳到那个跨页、选中那一格（CollageStore.reveal）。
// 拦（导出按钮先确认）：空照片格、原图读不了、放大超过 150%、页数不合规（套了印厂规格的）、同一张用了两次、胶装时
// 脸压中缝 / 照片横跨中缝 / 字压进中缝带；相册封面上的空照片格、放大超过 150%、书脊宽是按别的页数填的。
// 提醒（只列在「导出 ▾」里；导出完成那句后面带一句「还有 N 条提醒」）：放大 120–150%、没套规格时的页数、平铺时脸压中缝、
// 字出安全区 / 平铺时压进中缝带、贴边的照片没铺进出血、首尾单页那半边有东西、印刷画布上正文还是灰条；封面放大
// 120–150%、书脊是估的（整本导出时另问一次，见 exportConfirmation）/ 太窄、脸贴书脊。
// 同一份结果给导出按钮的确认框、「导出 ▾」的清单、命令行 ops 的 preflight；MCP collage_export 的 warnings 以后也接这一份
// （CollagePreflight.run 吃 project + hints，不碰界面状态，后台线程也能跑）。

struct CollagePreflightIssue: Hashable, Identifiable {
    enum Kind: String, CaseIterable, Hashable {
        /// 空照片格（导出来是一块底色）。
        case emptySlot
        /// 原图读不了（移动硬盘没插、文件挪走了）：导出会退回 1024 预览、或者那一格空着，印出来是糊的（优化分析 A1）。
        case source
        /// 放大：超过 150% 拦，120–150% 提醒。
        case upscale
        /// 页数不合规（印厂规格的页数规则）。
        case pageCount
        /// 同一张照片用了两次。
        case duplicate
        /// 脸压在中缝带里：胶装拦（书脊会吃掉），平铺提醒。
        case foldFace
        /// 胶装：照片横跨中缝（书脊吃掉中间一条；优化分析 A3）。平铺对裱跨中缝是正常做法，不报。
        case foldCross
        /// 字出了安全区、或压进了中缝带（胶装压进中缝带 = 拦：书脊会吃掉）。
        case textSafe
        /// 贴着成品边的照片没铺进出血（裁切差一点边上露底色）。
        case bleed
        /// 首尾单页：第 1 个跨页的左页、最后一个跨页的右页贴在封板上，上面有东西。
        case singleEnd
        /// 印刷画布上正文还是灰条 / 占位字。
        case fillerBody
        /// 相册封面（CollageBookCover.preflightIssues）：空照片格、放大超过 150% 拦；放大 120–150%、书脊宽还是估的、
        /// 书脊太窄印不下字、脸贴着书脊 / 出了安全区提醒。page = nil，path 是封面那一块的格子。
        case cover
        /// 封面书脊宽对不上现在的页数（优化分析 A4）：填的时候是 xP、现在 yP = 拦；还是估的 = 提醒（整本导出时另问一次）。
        /// page = nil；点了去「文档 › 封面」。
        case spine

        var label: String {
            switch self {
            case .emptySlot: return "空照片格"
            case .source: return "原图读不了"
            case .upscale: return "放大"
            case .pageCount: return "页数"
            case .duplicate: return "用了两次"
            case .foldFace: return "脸压中缝"
            case .foldCross: return "照片跨中缝"
            case .textSafe: return "字出安全区"
            case .bleed: return "没铺出血"
            case .singleEnd: return "首尾单页"
            case .fillerBody: return "占位正文"
            case .cover: return "封面"
            case .spine: return "书脊"
            }
        }
    }

    enum Severity: String, Hashable {
        /// 拦：导出按钮先弹确认框。
        case block
        /// 提醒：只列在清单里。
        case warn

        var label: String { self == .block ? "拦" : "提醒" }
    }

    var kind: Kind
    var severity: Severity
    /// 第几个跨页 / 页（从 0 起）；整本的事（页数）= nil。
    var page: Int?
    /// 格子路径（网格页的叶子）；不是某一格的 = nil。
    var path: [Int]?
    /// 自由图层（相纸、文字图层）的 id。
    var item: UUID?
    /// 哪张照片。
    var photoID: String?
    /// 一句话（带上第几个跨页，清单里单独看得懂）。
    var message: String

    var id: String {
        let at = page.map(String.init) ?? "-"
        let cell = path.map { $0.map(String.init).joined() } ?? (item?.uuidString ?? "-")
        return "\(kind.rawValue)|\(at)|\(cell)|\(photoID ?? "-")|\(message)"
    }
}

enum CollagePreflight {
    /// 放大超过这个就拦（印出来会糊；SmartAlbums 一类的建议也是别过 150%）。120% 起提醒（CollageStore.upscaleLimit）。
    static let upscaleBlock = 1.5

    /// 一张照片实际画在成品上的哪一块：网格格子（path、cell、格子框）或自由图层的相纸（item）。坐标是成品像素（1 倍、
    /// 不含出血）。取景和渲染器同一个：封面取景、人物挡字的格子按 CollageCover 的决定（CollageStore.upscaleIssues 以前
    /// 自己算的那一套，搬到这里两边共用）。
    struct Placement {
        var page: Int
        var path: [Int]?
        var item: UUID?
        var cell: CollageCell?
        var photo: CollagePhotoRef
        var window: CollageCrop.Window
        /// 照片画出来的那块：格子 = 成品坐标；相纸 = 相纸的局部坐标（以中心为原点、没转），放大倍数只看大小。
        var drawn: CGRect
        /// 相纸局部坐标 → 成品坐标（转过的）；格子 = nil。
        var toCanvas: CGAffineTransform?

        /// 画出来的那块在成品上占的外接框。
        var canvasRect: CGRect { toCanvas.map { drawn.applying($0) } ?? drawn }

        /// 画出来的脸（成品坐标的外接框）。
        var faces: [CGRect] {
            let boxes = CollageCrop.faceBoxes(photo: photo, window: window, in: drawn)
            guard let toCanvas else { return boxes }
            return boxes.map { $0.applying(toCanvas) }
        }
    }

    /// 全部页里画出来的照片（网格格子按阅读顺序、再是自由图层；印样页不算）。
    static func placements(project: CollageProject, hints: [String: CollageCrop.Hints]) -> [Placement] {
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        var out: [Placement] = []
        for (i, page) in project.pages.enumerated() {
            out += placements(page: page, index: i, project: project, photos: photos, hints: hints)
        }
        return out
    }

    /// 一页里画出来的照片（index = 记在 Placement.page 上的页号）。page 可以不在 project.pages 里：相册封面那一块
    /// （CollageBookCover.editPage，画布换成 frontCanvas、pages 清空，同封面渲染）也按这个算放大倍数。
    static func placements(page: CollagePage, index i: Int, project: CollageProject, photos: [String: CollagePhotoRef],
                           hints: [String: CollageCrop.Hints]) -> [Placement] {
        let canvas = project.canvas
        let style = project.style
        var out: [Placement] = []
        if !page.freeform {
            let frames = CollageLayout.pageGeometry(page.root, canvas: canvas, style: style).frames
            // 封面取景、人物挡字的格子按 CollageCover 的决定（封面会拉近，放大倍数要按它算）；
            // 这一页没有这种格子就照旧（不算占位符、底色）。
            let covered = frames.contains { CollageCover.applies(to: $0.cell) }
            let paged = CollageLooks.project(project, page: page)
            let ids = page.photoIDs
            let pageVars = covered ? CollageTypeset.variables(project: paged, root: page.root, photos: photos,
                                                              pagePhotoIDs: ids, pageID: page.id) : [:]
            let bg = covered ? CollageRender.backgroundColor(project: paged, pagePhotoIDs: ids, photos: photos)
                : style.background
            for f in frames where f.cell.kind == .photo {
                guard let id = f.cell.photoID, let photo = photos[id] else { continue }
                let framing = CollageLayout.effectiveFraming(path: f.path, cell: f.cell, in: frames, photos: photos,
                                                             tight: style.tightSmallCells)
                let area = CollageCrop.photoArea(cell: f.cell, rect: f.rect.cgRect, style: style)
                let window = CollageCover.applies(to: f.cell)
                    ? CollageRender.cellWindow(cell: f.cell, frameRect: f.rect.cgRect, project: paged, photo: photo,
                                               framing: framing, hints: hints[id],
                                               vars: CollageTypeset.cellVariables(pageVars, photo: photo),
                                               background: bg)
                    : CollageCrop.window(for: photo, cell: f.cell, cellAspect: CollageCrop.aspect(of: area),
                                         framing: framing, hints: hints[id])
                let drawn = CollageCrop.drawnRect(window: window, photo: photo, cell: f.cell, in: area)
                out.append(Placement(page: i, path: f.path, item: nil, cell: f.cell, photo: photo, window: window,
                                     drawn: drawn, toCanvas: nil))
            }
        }
        // 相纸（散落版整页、网格版上贴的）：和 CollageItems.drawPhotoItem 同一个取景。
        for item in page.items where item.kind == .photo {
            guard let id = item.photoID, let photo = photos[id] else { continue }
            let inner = CollageItems.photoArea(item.frame, outer: CollageItems.localRect(item, canvas: canvas))
            let framing: CollageFraming = item.framing == .auto ? .full : item.framing
            let window = CollageCrop.window(for: photo, cellAspect: CollageCrop.aspect(of: inner), framing: framing,
                                            override: nil, hints: hints[id])
            out.append(Placement(page: i, path: nil, item: item.id, cell: nil, photo: photo, window: window,
                                 drawn: inner, toCanvas: CollageItems.transform(item, canvas: canvas)))
        }
        return out
    }

    /// 整本过一遍。texts = 字出安全区、占位正文这两样要不要查（要按页低清渲一遍拿字块的位置，几十个跨页约一两秒：
    /// 导出按钮只要「拦」的，传 false；「导出 ▾」的清单在后台传 true）。结果按「拦」在前、再按页排。
    /// readable：这张照片的原图读不读得了（默认查盘：CollagePreflight.originalReadable；自检给假的）。
    static func run(project: CollageProject, hints: [String: CollageCrop.Hints], texts: Bool,
                    readable: (CollagePhotoRef) -> Bool = CollagePreflight.originalReadable) -> [CollagePreflightIssue] {
        guard !project.pages.isEmpty else { return [] }
        let canvas = project.canvas
        let album = project.mode == .album
        let fold = canvas.seams == .fold
        let many = project.pages.count > 1
        let unit = album ? "个跨页" : "页"
        func at(_ page: Int) -> String { many ? "第 \(page + 1) \(unit)" : "" }
        /// 句首带上第几个跨页、后面空一格（只有一页时什么都不带）。
        func lead(_ page: Int) -> String { many ? at(page) + " " : "" }
        func name(_ photo: CollagePhotoRef) -> String {
            let file = URL(fileURLWithPath: photo.path).deletingPathExtension().lastPathComponent
            return file.isEmpty ? photo.id : file
        }
        var out: [CollagePreflightIssue] = []

        // 空照片格（和导出确认、MCP 的 empty_slots 同一个判断）。
        for slot in CollageStore.emptyPhotoSlots(project: project) {
            out.append(CollagePreflightIssue(kind: .emptySlot, severity: .block, page: slot.page, path: slot.path,
                                             message: "\(at(slot.page))有一个空照片格：导出来是一块底色"))
        }

        // 页数（相册）。套了印厂规格的才拦；没套过的按保守默认看、只提醒，文案写明是「按常见的范围看」（优化分析 A9：
        // 以前没套规格的 12 个跨页的小册子也被「印厂要 20–60P」拦一下，没有哪家印厂这么要求过）。
        if album, fold, let problem = canvas.pageProblem(spreads: project.pages.count) {
            out.append(CollagePreflightIssue(kind: .pageCount, severity: canvas.printRules == nil ? .warn : .block,
                                             message: problem))
        }

        let placed = placements(project: project, hints: hints)
        var photoByID: [String: CollagePhotoRef] = [:]
        for p in project.photos where photoByID[p.id] == nil { photoByID[p.id] = p }
        // 原图读不了（优化分析 A1）：导出时渲染器退回 1024 预览（30×30 跨页上约等于放大 7 倍），预览也没有就空着 ——
        // 以前检查说「都没问题」，整本照常出 PDF，只在状态栏有一句。一张照片报一次（第一次用到它的那一页、那一格），
        // 印样页上的也算。封面上的在 CollageBookCover.preflightIssues。
        var sourceChecked = Set<String>()
        for (i, page) in project.pages.enumerated() {
            for id in page.photoIDs where !sourceChecked.contains(id) {
                guard let photo = photoByID[id] else { continue }
                sourceChecked.insert(id)
                guard !readable(photo) else { continue }
                let spot = placed.first { $0.page == i && $0.photo.id == id }
                out.append(CollagePreflightIssue(kind: .source, severity: .block, page: i, path: spot?.path,
                                                 item: spot?.item, photoID: id,
                                                 message: "\(lead(i))\(name(photo)) 的原图读不了（\(sourceWhy(photo))）：导出只能用小预览图，印出来是糊的。接上原图所在的盘再导"))
            }
        }
        // 放大（印刷画布才查：社交尺寸上的放大看不出来）。
        if canvas.isPrint {
            for p in placed {
                let k = CollageCrop.upscale(photo: p.photo, window: p.window, drawn: p.drawn)
                guard k > CollageStore.upscaleLimit else { continue }
                let pct = Int((k * 100).rounded())
                let block = k > upscaleBlock
                let tail = block ? "印出来会糊" : "印出来会软"
                out.append(CollagePreflightIssue(kind: .upscale, severity: block ? .block : .warn, page: p.page,
                                                 path: p.path, item: p.item, photoID: p.photo.id,
                                                 message: "\(lead(p.page))\(name(p.photo)) 放大到 \(pct)%：\(tail)，少裁一点或缩小那一格"))
            }
        }

        // 脸压中缝带（相册）：胶装会被书脊吃掉 = 拦；平铺摊得开 = 提醒。带宽同求解避脸（CollageLayout.seamLines）。
        if fold, let band = CollageLayout.seamLines(canvas).first {
            let glued = canvas.binding == .glued
            for p in placed {
                guard p.faces.contains(where: { $0.intersects(band) }) else { continue }
                let why = glued ? "胶装会被书脊吃掉" : "摊开时正好在折缝上"
                out.append(CollagePreflightIssue(kind: .foldFace, severity: glued ? .block : .warn, page: p.page,
                                                 path: p.path, item: p.item, photoID: p.photo.id,
                                                 message: "\(lead(p.page))\(name(p.photo)) 的脸压在中缝带里：\(why)，点备选条的「换一批」或挪一下取景"))
            }
        }

        // 胶装：照片横跨中缝（优化分析 A3）。和检视器橙字、换装订时那句提示同一个判断（CollageStore.crossFoldUses）——
        // 以前导出前检查只查脸：平铺排好的整版跨页换成胶装、或者手动把格子拖过中缝，导出时一声不吭。
        if fold, canvas.binding == .glued {
            for use in CollageStore.crossFoldUses(project: project) {
                let shown = photoByID[use.photoID].map(name) ?? use.photoID
                out.append(CollagePreflightIssue(kind: .foldCross, severity: .block, page: use.page, path: use.path,
                                                 item: use.item, photoID: use.photoID,
                                                 message: "\(lead(use.page))\(shown) 横跨中缝：胶装书脊会吃掉中间一条，点备选条的「换一批」重排，或把它收进一页里"))
            }
        }

        // 贴着成品边的照片没铺进出血：渲染器只在「有出血 + 零边距 + 普通矩形格（不带框、不是完整显示）」时把贴边的照片
        // 铺进出血（CollageRender.canBleed / bleedEdges）；拱形、圆形、完整显示的照片贴边，或者出血是 0，印出来裁切差一点
        // 边上就露底色。
        if canvas.isPrint {
            let style = project.style
            let trim = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
            let zeroMargin = style.insets.map { min($0.top, $0.bottom, $0.inner, $0.outer) <= 0.0001 }
                ?? (style.margin <= 0.0001)
            let tol: CGFloat = 1.5
            for p in placed {
                guard let cell = p.cell else { continue }
                let d = p.drawn
                let touches = abs(d.minX - trim.minX) < tol || abs(d.minY - trim.minY) < tol
                    || abs(d.maxX - trim.maxX) < tol || abs(d.maxY - trim.maxY) < tol
                guard touches else { continue }
                let bled = canvas.bleed > 0 && zeroMargin && CollageRender.canBleed(cell, style: style)
                guard !bled else { continue }
                let why = canvas.bleed == 0 ? "出血是 0" : "这一格的形状 / 完整显示不往出血里铺"
                out.append(CollagePreflightIssue(kind: .bleed, severity: .warn, page: p.page, path: p.path,
                                                 photoID: p.photo.id,
                                                 message: "\(lead(p.page))\(name(p.photo)) 贴着成品边、没铺进出血（\(why)）：裁切差一点边上会露底色"))
            }
        }

        // 同一张用了两次（相册；单张拼图一期杂志里封面图再用一次是常事，不管）。看格子和图层里的照片，印样页不算。
        if album {
            var seen: [String: Int] = [:]
            var pagesOf: [String: [Int]] = [:]
            var repeats: [(page: Int, path: [Int]?, item: UUID?, id: String)] = []
            let tray = Set(project.photos.map(\.id))
            for (i, page) in project.pages.enumerated() where page.contactSheet == nil {
                var uses: [(path: [Int]?, item: UUID?, id: String)] = []
                if !page.freeform {
                    for path in page.root.leafPaths() {
                        guard let cell = page.root.node(at: path)?.cell, cell.kind == .photo, let id = cell.photoID,
                              tray.contains(id) else { continue }
                        uses.append((path, nil, id))
                    }
                }
                for item in page.items where item.kind == .photo {
                    guard let id = item.photoID, tray.contains(id) else { continue }
                    uses.append((nil, item.id, id))
                }
                for use in uses {
                    seen[use.id, default: 0] += 1
                    pagesOf[use.id, default: []].append(i)
                    if (seen[use.id] ?? 0) > 1 { repeats.append((i, use.path, use.item, use.id)) }
                }
            }
            let photoMap = Dictionary(project.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for r in repeats {
                let listed = Array(Set(pagesOf[r.id] ?? [])).sorted().map { "\($0 + 1)" }.joined(separator: "、")
                let shown = photoMap[r.id].map(name) ?? r.id
                out.append(CollagePreflightIssue(kind: .duplicate, severity: .block, page: r.page, path: r.path,
                                                 item: r.item, photoID: r.id,
                                                 message: "\(shown) 用了 \(seen[r.id] ?? 2) 次（第 \(listed) 个跨页）：同一张印两遍，换一张或删掉一格"))
            }
        }

        // 首尾单页：第 1 个跨页的左页、最后一个跨页的右页贴在封板上（照片和字都看；字要 texts 才知道在哪）。
        let rules = canvas.effectivePrintRules
        var hidden: [(page: Int, rect: CGRect, side: String)] = []
        if album, fold, rules.singleEnds {
            let w = CGFloat(canvas.width)
            let h = CGFloat(canvas.height)
            hidden.append((0, CGRect(x: 0, y: 0, width: w / 2, height: h), "左页"))
            hidden.append((project.pages.count - 1, CGRect(x: w / 2, y: 0, width: w / 2, height: h), "右页"))
            for zone in hidden {
                for p in placed where p.page == zone.page && p.canvasRect.intersection(zone.rect).width > 1 {
                    out.append(CollagePreflightIssue(kind: .singleEnd, severity: .warn, page: p.page, path: p.path,
                                                     item: p.item, photoID: p.photo.id,
                                                     message: "\(at(p.page))的\(zone.side)贴在封板上、印不出来，\(name(p.photo)) 放在那半边"))
                }
            }
        }

        if texts { out += textIssues(project: project, hints: hints, hidden: hidden, at: at) }
        // 相册封面：和「文档 › 封面」标橙的是同几句（CollageBookCover.preflightIssues）。
        if album { out += CollageBookCover.preflightIssues(project: project, hints: hints, readable: readable) }

        // 拦在前；同一档按页（整本的事在最前）、再按种类。
        let kindOrder = Dictionary(uniqueKeysWithValues: CollagePreflightIssue.Kind.allCases.enumerated().map { ($1, $0) })
        return out.enumerated().sorted { a, b in
            let x = a.element
            let y = b.element
            if x.severity != y.severity { return x.severity == .block }
            if (x.page ?? -1) != (y.page ?? -1) { return (x.page ?? -1) < (y.page ?? -1) }
            if x.kind != y.kind { return (kindOrder[x.kind] ?? 0) < (kindOrder[y.kind] ?? 0) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// 字：每页低清渲一遍（照片一张都不解码：region 放在画面外，照片格不出图、字照常排），按渲染记下的字块位置
    /// （成品坐标，和导出排的是同一组数）查安全区、中缝带、首尾单页那半边、占位正文。
    private static func textIssues(project: CollageProject, hints: [String: CollageCrop.Hints],
                                   hidden: [(page: Int, rect: CGRect, side: String)],
                                   at: (Int) -> String) -> [CollagePreflightIssue] {
        let canvas = project.canvas
        let trim = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let safe = canvas.safe > 0 ? trim.insetBy(dx: CGFloat(canvas.safe), dy: CGFloat(canvas.safe)) : nil
        let band = canvas.seams == .fold ? CollageLayout.seamLines(canvas).first : nil
        let glued = canvas.binding == .glued
        let scale = min(1, 480 / Double(max(1, max(canvas.width, canvas.height))))
        var out: [CollagePreflightIssue] = []
        for (i, page) in project.pages.enumerated() {
            var opts = CollageRender.Options(scale: scale)
            opts.includeBleed = false
            opts.export = true
            opts.region = CGRect(x: -1_000_000, y: -1_000_000, width: 1, height: 1)
            let report = CollageRender.RenderReport()
            opts.report = report
            _ = CollageRender.render(page: page, project: project, hints: hints, options: opts)
            for t in report.texts where !t.rect.isEmpty {
                let (path, item) = owner(t.owner, page: page)
                let first = t.lines.first.map { String($0.prefix(12)) } ?? ""
                let quote = first.isEmpty ? "" : "「\(first)」"
                let tol: CGFloat = 0.5
                // 胶装时字压进中缝带（优化分析 A6）：书脊会吃掉那几个字 = 拦（和脸压中缝一个道理），出没出安全区都报；
                // 平铺摊得开，照旧只是提醒（出了安全区的只报安全区那一句）。
                let inBand = band.map { t.rect.intersects($0) } ?? false
                if inBand, glued {
                    out.append(CollagePreflightIssue(kind: .textSafe, severity: .block, page: i, path: path, item: item,
                                                     message: "\(at(i))的字\(quote)压进了中缝带：胶装书脊会吃掉，往一边挪开"))
                }
                if let safe, !safe.insetBy(dx: -tol, dy: -tol).contains(t.rect) {
                    let mm = String(format: "%.0f", Double(canvas.safe) / max(1, canvas.dpi) * 25.4)
                    out.append(CollagePreflightIssue(kind: .textSafe, severity: .warn, page: i, path: path, item: item,
                                                     message: "\(at(i))的字\(quote)出了安全区（离裁切边不到 \(mm)mm）：裁切时可能切到"))
                } else if inBand, !glued {
                    out.append(CollagePreflightIssue(kind: .textSafe, severity: .warn, page: i, path: path, item: item,
                                                     message: "\(at(i))的字\(quote)压进了中缝带：摊开时在折缝上"))
                }
                for zone in hidden where zone.page == i && t.rect.intersection(zone.rect).width > 1 {
                    out.append(CollagePreflightIssue(kind: .singleEnd, severity: .warn, page: i, path: path, item: item,
                                                     message: "\(at(i))的\(zone.side)贴在封板上、印不出来，字\(quote)放在那半边"))
                }
                if canvas.isPrint, t.hasFillerBody {
                    out.append(CollagePreflightIssue(kind: .fillerBody, severity: .warn, page: i, path: path, item: item,
                                                     message: "\(at(i))的正文还是灰条或占位字：印出来是要被人读的，在「格式 › 正文」里换成自己的字"))
                }
            }
        }
        return out
    }

    /// 渲染记账的 owner（"01" / "r" / "item3"）→ 格子路径或图层 id。
    private static func owner(_ owner: String, page: CollagePage) -> ([Int]?, UUID?) {
        if owner.hasPrefix("item"), let n = Int(owner.dropFirst(4)), page.items.indices.contains(n) {
            return (nil, page.items[n].id)
        }
        if owner == "r" { return ([], nil) }
        let digits = owner.compactMap(\.wholeNumberValue)
        return digits.count == owner.count ? (digits, nil) : (nil, nil)
    }

    /// 原图读不读得了：文件在、能读。只查得出「盘没插 / 文件挪走了 / 没权限」这几种（最常见的）；机型 RAW 解不了这类
    /// 要真解码才知道，导出时渲染器照样记账（RenderReport.lowRes / missing），startExport 按那个不出印刷 PDF。
    static func originalReadable(_ photo: CollagePhotoRef) -> Bool {
        FileManager.default.isReadableFile(atPath: photo.path)
    }

    /// 原图为什么读不了：照片所在的文件夹都不在 = 多半是盘没接上；文件夹在、文件不在 = 挪走或改名了。
    static func sourceWhy(_ photo: CollagePhotoRef) -> String {
        let url = URL(fileURLWithPath: photo.path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.deletingLastPathComponent().path) { return "它所在的文件夹不在：移动硬盘、存储卡没接上？" }
        if !fm.fileExists(atPath: url.path) { return "文件不在原来的位置：挪走或改名了？" }
        return "文件在、但打不开"
    }

    /// 清单上方那一行：「2 条拦、3 条提醒」/「都没问题」。
    static func summary(_ issues: [CollagePreflightIssue]) -> String {
        let blocks = issues.filter { $0.severity == .block }.count
        let warns = issues.count - blocks
        if issues.isEmpty { return "都没问题" }
        return [blocks > 0 ? "\(blocks) 条拦" : nil, warns > 0 ? "\(warns) 条提醒" : nil].compactMap { $0 }
            .joined(separator: "、")
    }
}

// MARK: - store：清单、跳过去、导出确认

extension CollageStore {
    /// 这一版的导出前检查（同步；texts 见 CollagePreflight.run）。
    func preflight(texts: Bool = true) -> [CollagePreflightIssue] {
        CollagePreflight.run(project: project, hints: hints, texts: texts, readable: preflightReadable)
    }

    /// 原图读不读得了用哪个判断：自检给了假的（testUnreadableOriginals）就用它，否则查盘。
    var preflightReadable: @Sendable (CollagePhotoRef) -> Bool {
        guard let fake = testUnreadableOriginals else { return { CollagePreflight.originalReadable($0) } }
        return { !fake.contains($0.id) }
    }

    /// 清单上点一条：换到那个跨页（走 pageIndex，同跨页条），选中那一格 / 那个图层，右栏切到「格式」。
    /// 暗房开着先关（编辑区不在视图树里），整本概览开着先收起（画布被它盖着），编辑封面时先退出（不然 pageIndex 没变时
    /// 还停在封面上、选中的路径也套到封面那块上）。整本的事（页数）不跳。
    /// 封面的几条（page == nil）：空照片格进封面编辑、选中那一格；别的（书脊、脸贴书脊、放大）去「文档 › 封面」。
    func reveal(_ issue: CollagePreflightIssue) {
        if issue.kind == .cover || issue.kind == .spine {
            revealCover(issue)
            return
        }
        guard let target = issue.page, project.pages.indices.contains(target) else { return }
        if darkroom != nil { closeDarkroom() }
        if albumUI.overviewShown { albumUI.overviewShown = false }
        if editingCover { setEditingCover(false) }
        if target != pageIndex { pageIndex = target }
        if let item = issue.item, items.contains(where: { $0.id == item }) {
            selectItem(item)
            nav.showFormat()
        } else if let path = issue.path, !isFreeform, !isContactSheet, root?.node(at: path)?.isLeaf == true {
            selection = path
            nav.showFormat()
        }
    }

    /// 封面那几条：带格子路径的（空照片格、放大）进封面编辑、选中那一格；别的去「文档 › 封面」（书脊宽、包边在那里改）。
    private func revealCover(_ issue: CollagePreflightIssue) {
        guard isAlbum, let cover = project.bookCover else { return }
        if darkroom != nil { closeDarkroom() }
        if albumUI.overviewShown { albumUI.overviewShown = false }
        if let path = issue.path, cover.front.node(at: path)?.isLeaf == true {
            setEditingCover(true)
            selection = path
            nav.showFormat()
        } else {
            go(.cover)
        }
    }

    /// 导出按钮要不要先问（只看「拦」的）：pages = 只导这几页时只看这几页上的（页数是整本的事，部分导出不拦）。
    /// 只有空照片格时标题、那句话和以前一字不差；有别的「拦」就列前几条。nil = 不用问。
    /// askEstimatedSpine（优化分析 A4）：整本导出、封面的书脊宽还是估的，也问一次（「书脊是估的」平时只是提醒；封面印出来
    /// 书脊差几毫米整张作废，不能不问就导）。store.export 问过一次、这本的页数和估出来的数没变就不再问
    /// （estimatedSpineAsked）；MCP 的 export_would_ask、命令行照实报。
    nonisolated static func exportConfirmation(_ issues: [CollagePreflightIssue], project: CollageProject,
                                               pages: [Int]?, askEstimatedSpine: Bool = true)
        -> (title: String, message: String)? {
        let picked = pages.map(Set.init)
        let blocks = issues.filter { issue in
            if issue.kind == .spine, issue.severity == .warn { return askEstimatedSpine && picked == nil }
            guard issue.severity == .block else { return false }
            guard let picked else { return true }
            return issue.page.map(picked.contains) ?? false
        }
        guard !blocks.isEmpty else { return nil }
        let slots = blocks.filter { $0.kind == .emptySlot }.map { EmptySlot(page: $0.page ?? 0, path: $0.path ?? []) }
        let others = blocks.filter { $0.kind != .emptySlot }
        let empty = emptySlotWarning(slots, project: project)
        let fix = "从托盘拖照片进去，或者选中那一格「删除格子」"
        if others.isEmpty, let empty {
            return ("有空照片格，仍要导出吗？", empty + "。" + fix + "。")
        }
        var lines: [String] = []
        if let empty { lines.append(empty) }
        let shown = 4
        lines += others.prefix(shown).map(\.message)
        if others.count > shown { lines.append("还有 \(others.count - shown) 条") }
        let message = lines.map { "· " + $0 }.joined(separator: "\n")
            + "\n\n「导出 ▾」里的「导出前检查」点一条就跳到那一格。"
        return ("导出前检查有 \(slots.count + others.count) 条没过，仍要导出吗？", message)
    }
}

// MARK: - 「导出 ▾」里的清单：后台算（要低清渲每一页拿字的位置）

/// 「导出 ▾」摊开时在后台过一遍（texts = true），工程改了、路人信息算好一批（取景跟着变）再过一遍，停手 0.3 秒才开始。
@MainActor
final class CollagePreflightRunner: ObservableObject {
    @Published private(set) var issues: [CollagePreflightIssue]?
    @Published private(set) var running = false
    private var key: Key?
    private var task: Task<Void, Never>?

    struct Key: Hashable {
        var revision: Int
        var hints: Int
    }

    static func key(_ store: CollageStore) -> Key { Key(revision: store.projectRevision, hints: store.hintsVersion) }

    func refresh(_ store: CollageStore) {
        let now = Self.key(store)
        guard now != key || issues == nil else { return }
        key = now
        let project = store.project
        let hints = store.hints
        let readable = store.preflightReadable
        task?.cancel()
        running = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                CollagePreflight.run(project: project, hints: hints, texts: true, readable: readable)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.issues = result
            self.running = false
        }
    }
}
