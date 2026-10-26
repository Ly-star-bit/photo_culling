import Foundation
import CoreGraphics

/// 照片上的字：放在哪（自动避开人脸、身体、画面最乱的地方）、用深字还是浅字。
///
/// 位置和字色全部按成品尺寸（1 倍）的几何、固定分辨率的预览统计算 —— 界面预览、画布上的
/// 选中框、导出三处算出来是同一个位置（以前景别按缩略图几何判，预览和导出翻过车）。
enum CollageOverlays {

    struct Placement {
        /// 字块外框（成品坐标，不含出血）。
        var rect: CGRect
        /// 放得下之后的字号基准（CollageTypeset 的 short）。
        var short: Double
        /// 按位置调好对齐、按底下画面调好颜色的字。
        var text: CollageText
        var light: Bool
        var anchor: CollageAnchor
        /// 字底下画面太花、反差不够时字后面垫的雾面有多实（0 = 不垫）：深字衬白、浅字衬黑。
        var halo: Double = 0
        /// 干净的字（scrim = false）：沿字边的光晕多浓（0…1）、底部压暗、最不清楚的字形还差多少对比（统一深浅比较用）。
        var glow: Double = 0
        var fade: Fade?
        var deficit: Double?
        /// 干净的字、自动 / 沿边找的位置：挑中那个候选的总代价、盖住主体多少（统一深浅比较两遍用；别的 = 0）。
        var cost: Double = 0
        var onBody: Double = 0
    }

    /// area = 照片实际画的区域（成品坐标）；window/drawn 用来把字块映射回照片坐标看底下是什么。
    /// occupied = 同一张照片上前面已经摆好的字块（外扩过一点）：自动位置、左栏 / 右栏 / 底栏都让开它们。
    /// maxHeight = 字块最多多高（成品像素；人物挡字退让「刊头缩到头顶上方的净空」用）：铺满宽度的行跟着收，nil = 不管。
    /// matte = 抠图格的主体蒙版：照片只画主体、别的地方透出页面底色 —— 字底下有多亮、多花按蒙版把照片和底色混起来算
    /// （定深浅、垫雾面、自动摆位躲花的地方都按它）。nil = 照片整张都画（普通格子一步都不多走）。
    /// subject = 这一格的主体蒙版（CollageCover 定过的格子才有）：干净的字（scrim = false）自动摆位时躲开人身上。
    /// siblingSides = 同一格里别的字块定的左栏 / 右栏：干净的字的栏换边时，换到那边要多算 stackCost（两栏挤到同一边）。
    static func place(_ overlay: CollageOverlay, area: CGRect, drawn: CGRect, canvas: CollageCanvas,
                      photo: CollagePhotoRef?, window: CollageCrop.Window?, hints: CollageCrop.Hints?,
                      vars: [String: String], background: CollageColor,
                      look: CollageLook = .none, lookStrength: Double = 0,
                      occupied: [CGRect] = [], maxHeight: Double? = nil,
                      matte: CollageMasks.Mask? = nil, subject: CollageMasks.Mask? = nil,
                      siblingSides: Set<CollageAnchor> = []) -> Placement? {
        let short = canvas.shortSide
        var avail = area
        // 印刷：字不出安全区（裁切有误差，贴边的字会被切掉）。
        if canvas.safe > 0 {
            let safe = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
                .insetBy(dx: CGFloat(canvas.safe), dy: CGFloat(canvas.safe))
            let clipped = avail.intersection(safe)
            if !clipped.isNull, clipped.width > 8, clipped.height > 8 { avail = clipped }
        }
        let m = Double(min(area.width, area.height))
        let inset = CGFloat(overlay.inset * m)
        var inner = avail.insetBy(dx: inset, dy: inset)
        if inner.width < 8 || inner.height < 8 { inner = avail }
        guard inner.width > 4, inner.height > 4 else { return nil }
        // 字不进照片区最下面那一截（小红书底部的遮挡带）：自动、沿边的在上面找位置，定死在下方的往上抬；手动拖的不管。
        if overlay.clearBottom > 0, overlay.anchor != .custom {
            let floorY = area.maxY - CGFloat(overlay.clearBottom) * area.height
            if floorY < inner.maxY, floorY - inner.minY > 8 { inner.size.height = floorY - inner.minY }
        }

        // 竖排、横排转了 90° 的字块在页面上是竖长的：宽高上限按竖的给。
        let vertical = overlay.text.isTall
        // 铺满宽度的行（刊头）：另一个方向的上限放开（大字刊头本来就占得高）；左栏 / 右栏最宽 40%（中间留给人）。
        let cross: Double = overlay.text.lines.contains { $0.fitWidth } ? 1 : 0.55
        let side = overlay.anchor == .leftColumn || overlay.anchor == .rightColumn
        let wide = Double(inner.width) * (vertical ? cross : overlay.maxWidth)
        let maxW = side ? min(wide, Double(inner.width) * columnShare) : wide
        let tall = Double(inner.height) * (vertical ? overlay.maxWidth : cross)
        let maxH = maxHeight.map { min(tall, max(4, $0)) } ?? tall
        let limit = CGSize(width: maxW, height: maxH)
        // 干净的字（时尚刊，CollageStyleFashionType）：缺值的段去掉、太长的行自己缩或断成两行。
        let prepared = overlay.scrim ? overlay.text : cleanTypeText(overlay.text, width: maxW, short: short, vars: vars)
        let source = CollageTypeset.fittingWidth(prepared, in: limit, short: short, vars: vars)
        let fitted = CollageTypeset.fit(source, in: limit, short: short, vars: vars)
        let size = boxSize(fitted.size, text: source, limit: limit)
        guard size.width > 1, size.height > 1 else { return nil }

        var grid = photo.flatMap { p in window.flatMap { w in luminanceGrid(p, window: w) } }
        // 抠图格：网格换成「主体是照片（调完色）、别处是页面底色」的那一份；底色本身不过色调，下面定深浅时不再调一次。
        var matted = false
        if let matte, let p = photo, let g = grid {
            grid = mattedGrid(g, photo: p, matte: matte, background: background, look: look, strength: lookStrength)
            matted = true
        }
        let mapper = Mapper(drawn: drawn, window: window)
        let seams = CollageLayout.seamLines(canvas)
        // 干净的字：候选位置按每个字形底下看清不清楚；自动挑大小不缩到要读的字号以下（原大小那档总在）。
        let clean: CleanType? = overlay.scrim ? nil
            : CleanType(grid: grid, mapper: mapper, look: look, strength: lookStrength, matted: matted, vars: vars,
                        subject: subject, faces: photo?.faces ?? [], bystanders: hints?.bystanders ?? [],
                        column: side ? area : nil)
        let smallest = overlay.scrim ? 0 : smallestLine(source, vars: vars)
        // 几档大小（原大小那档总在）：整块按比例缩（short × 档）。shrink = 缩了多少（代价按它算）；
        // lines = 干净的字每个非空行的实际字号（每个候选位置都要，先算好：展开占位符不便宜）。
        typealias Size = (text: CollageText, fit: (short: Double, size: CGSize), shrink: Double, lines: [Double])
        func sized(_ t: CollageText, _ f: (short: Double, size: CGSize), _ shrink: Double) -> Size {
            (t, f, shrink, overlay.scrim ? [] : lineSizes(t, scale: f.short / short, vars: vars))
        }
        var sizes: [Size] = []
        var perLine: [Double] = []
        for s in autoScales {
            if s == 1 {
                sizes.append(sized(source, fitted, 0))
            } else if overlay.scrim || smallest * s >= readableSize {
                let f = CollageTypeset.fit(source, in: limit, short: short * s, vars: vars)
                sizes.append(sized(source, f, max(0, 1 - f.short / max(1e-6, fitted.short))))
            } else {
                perLine.append(s)
            }
        }
        // 干净的字整块缩会把最小那行缩破要读的字号的那几档：改成按行缩（shrunkLines：每行 × 档、不低于要读的字号，
        // 原来就比它小的行不动）—— 右栏衬线最小那行 VOL. 01 是 0.024，整块缩一档就破 2.2%W，以前三档里只剩原大小，
        // 栏想缩一号躲开人都缩不了。只在原来那几档挑不出不碰人的位置时才算（「先小一号、再换边、最后才压人」；
        // 没碰到人的照片一步不多走、摆位和以前一样）。按行缩完还得整块再缩才放得下的那档不要。
        func perLineSizes() -> [Size] {
            perLine.compactMap { s in
                let t = shrunkLines(source, by: s)
                let f = CollageTypeset.fit(t, in: limit, short: short, vars: vars)
                guard f.short >= short * (1 - 1e-9) else { return nil }
                return sized(t, f, 1 - s)
            }
        }
        func cleanCost(_ v: Size, _ r: CGRect, _ align: CollageAlign) -> (cost: Double, onBody: Double, people: Double) {
            guard let clean else { return (0, 0, 0) }
            var t = v.text
            t.alignH = align
            t.alignV = .leading
            return clean.cost(t, size: r.size, short: v.fit.short, at: r.origin, tone: overlay.tone, sizes: v.lines)
        }

        var chosen: CollageAnchor
        var rect: CGRect
        var fit = fitted
        var sideAlign = source.alignH
        // 挑中的那一档的字（按行缩过的那几档字号不一样；定死位置、手动的 = 原样）。
        var chosenText = source
        // 干净的字挑中的那个候选：总代价、压人最多的那一行压了多少（定死位置的 = 0）。
        var picked = (cost: 0.0, onBody: 0.0)
        switch overlay.anchor {
        case .custom:
            chosen = .custom
            let cx = Double(area.minX) + overlay.x * Double(area.width)
            let cy = Double(area.minY) + overlay.y * Double(area.height)
            rect = clampRect(CGRect(x: cx - Double(size.width) / 2, y: cy - Double(size.height) / 2,
                                    width: Double(size.width), height: Double(size.height)), into: avail)
        case .auto:
            // 九个位置 × 三档大小里挑：上方只剩一小块干净的天空时，小一号放在天上比大字压在栏杆花纹上
            // 好认（缩小有代价，不会无故缩）。
            var best = (anchor: CollageAnchor.top, rect: CGRect.zero, fit: fitted, cost: Double.infinity, onBody: 0.0,
                        text: source)
            // 压着前面已经摆好的字块的位置只在一个不压的都没有时才用（以前只是加代价：底下全是亮栏杆时，
            // 叠在别的字块上反倒「便宜」，底栏 SPECIAL EDITION 压住了左栏的期号）。没有已占用时和以前一样。
            var free = best
            // 干净的字再多一层：不压人身上（压人最多的那一行 ≤ bodyMax）的位置优先，一个都没有才压到人身上（别的字块没有这层）。
            var clear = best
            func scanGrid(_ list: [Size]) {
                for v in list {
                    let f = v.fit
                    let sz = boxSize(f.size, text: v.text, limit: limit)
                    for a in CollageAnchor.grid {
                        let r = anchored(a, size: sz, in: inner)
                        let base: Double = cost(r, prior: prior(a, vertical: vertical), photo: photo, hints: hints,
                                                grid: grid, mapper: mapper, tone: overlay.tone)
                        let col = a.cell?.col ?? 1
                        let along: CollageAlign = col == 0 ? .leading : (col == 1 ? .center : .trailing)
                        let legible = clean == nil ? (cost: 0.0, onBody: 0.0, people: 0.0) : cleanCost(v, r, along)
                        let c: Double = base + seamCost(r, seams: seams) + occupiedCost(r, occupied: occupied)
                            + shrinkCost * v.shrink + legible.cost
                        // 干净的字：压脸（外扩 10%）也算不开放（同压着别的字块）。
                        let open = !hitsOccupied(r, occupied) && !(clean?.hitsFace(r) ?? false)
                        if c < best.cost { best = (a, r, f, c, legible.onBody, v.text) }
                        if c < free.cost, open { free = (a, r, f, c, legible.onBody, v.text) }
                        if clean != nil, c < clear.cost, open, legible.onBody <= bodyMax {
                            clear = (a, r, f, c, legible.onBody, v.text)
                        }
                    }
                }
            }
            scanGrid(sizes)
            // 干净的字：原来那几档里没有不碰人的位置，再试按行缩的小一号。
            if clean != nil, !perLine.isEmpty, !clear.cost.isFinite || clear.onBody > peopleTouch {
                scanGrid(perLineSizes())
            }
            if clear.cost.isFinite { best = clear } else if free.cost.isFinite { best = free }
            chosen = best.anchor
            rect = best.rect
            fit = best.fit
            chosenText = best.text
            if clean != nil { picked = (best.cost, best.onBody) }
        case .leftColumn, .rightColumn, .bottomBand:
            // 边是定的，沿那条边找：躲脸、躲身体、躲前面的字块、挑底下干净的地方，和自动一样三档大小。
            var best = (rect: CGRect.zero, fit: fitted, cost: Double.infinity, align: source.alignH, onBody: 0.0,
                        anchor: overlay.anchor, text: source)
            var free = best
            var clear = best
            // 不算压人那几项时最便宜的不压别的字块的位置：它碰到人 = 这一栏是被人挤开的（右栏衬线 7227：最想落的
            // 22.8–50%H 底下两行压着伸出来的指尖，算上压人代价之后挑的是照片最下面一截又花又出了 R1 范围的地方）。
            var natural = (cost: Double.infinity, onBody: 0.0)
            let along: CollageAlign = overlay.anchor == .leftColumn ? .leading
                : (overlay.anchor == .rightColumn ? .trailing : source.alignH)
            // 干净的字的底栏：左右两头都试（人站在左边就放右边），换到另一头的稍贵一点。
            var ends: [(align: CollageAlign, extra: Double)] = [(along, 0)]
            if clean != nil, overlay.anchor == .bottomBand, along != .center {
                ends.append((along == .leading ? .trailing : .leading, 0.05))
            }
            func scan(_ edge: CollageAnchor, _ ends: [(align: CollageAlign, extra: Double)], _ list: [Size]) {
                for v in list {
                    let f = v.fit
                    let sz = boxSize(f.size, text: v.text, limit: limit)
                    for end in ends {
                        for (r, p) in sideCandidates(edge, size: sz, in: inner, alignH: end.align) {
                            let base: Double = cost(r, prior: p + end.extra, photo: photo, hints: hints, grid: grid,
                                                    mapper: mapper, tone: overlay.tone)
                            let legible = clean == nil ? (cost: 0.0, onBody: 0.0, people: 0.0)
                                : cleanCost(v, r, end.align)
                            let c: Double = base + seamCost(r, seams: seams) + occupiedCost(r, occupied: occupied)
                                + shrinkCost * v.shrink + legible.cost
                            let open = !hitsOccupied(r, occupied) && !(clean?.hitsFace(r) ?? false)
                            if open, edge == overlay.anchor, c - legible.people < natural.cost {
                                natural = (c - legible.people, legible.onBody)
                            }
                            if c < best.cost { best = (r, f, c, end.align, legible.onBody, edge, v.text) }
                            if c < free.cost, open { free = (r, f, c, end.align, legible.onBody, edge, v.text) }
                            if clean != nil, c < clear.cost, open, legible.onBody <= bodyMax {
                                clear = (r, f, c, end.align, legible.onBody, edge, v.text)
                            }
                        }
                    }
                }
            }
            scan(overlay.anchor, ends, sizes)
            // 干净的字碰到人了：这一边不算压人代价时最便宜的位置碰到人（人把栏从它最想落的地方挤开了）、
            // 不压人的位置也还碰到人、或者一个不压人身上的位置都没有（人站满了这一边）。
            // 依次：这一边按行缩的小一号（和原来几档一起比代价，缩小有代价）→ 左栏 / 右栏到另一边也找一遍（贵一点：
            // 版式上本来是这一边），两边不压人的位置一起比代价 → 统一深浅的另一种深浅（CollageRender.rawPlacements
            // 两遍比总代价）→ 那边也没有才压到人身上（照旧在这一边挑）。
            let touching = !clear.cost.isFinite || clear.onBody > peopleTouch
                || (natural.cost.isFinite && natural.onBody > peopleTouch)
            let smaller: [Size] = clean != nil && touching ? perLineSizes() : []
            if !smaller.isEmpty { scan(overlay.anchor, ends, smaller) }
            if clean != nil, touching, overlay.anchor == .leftColumn || overlay.anchor == .rightColumn {
                let other: CollageAnchor = overlay.anchor == .leftColumn ? .rightColumn : .leftColumn
                let keep = (best: best, free: free)
                // 那边本来就是同一格另一栏的地方（刊头在后 · 无衬线的左右两栏）：再贵一点，免得两栏无故挤到同一边。
                let extra: Double = flipCost + (siblingSides.contains(other) ? stackCost : 0)
                scan(other, [(other == .leftColumn ? .leading : .trailing, extra)], sizes + smaller)
                // 另一边只拿「不压人」的那个：压人的位置还是在原来那边挑。
                best = keep.best
                free = keep.free
            }
            // 同自动位置：有不压别的字块的位置就只在那些里挑；干净的字再先挑不压人身上的（小一号的也在里面）。
            if clear.cost.isFinite { best = clear } else if free.cost.isFinite { best = free }
            chosen = best.anchor
            rect = best.rect
            fit = best.fit
            sideAlign = best.align
            chosenText = best.text
            if clean != nil { picked = (best.cost, best.onBody) }
        default:
            chosen = overlay.anchor
            rect = clearOfSeams(anchored(overlay.anchor, size: size, in: inner), canvas: canvas, within: inner)
            // 字墨的顶定在照片区上边往下 inkTop（大字刊头：字框上面那截上伸部的空不算）。字框可以伸出照片区，墨不出。
            if overlay.inkTop > 0, overlay.anchor.cell?.row == 0, !source.vertical, !source.isRotated {
                let glyphs = CollageTypeset.glyphOutlines(source, in: rect, short: fitted.short, vars: vars)
                if let ink = glyphs.map({ $0.bounds.minY }).min() {
                    let want: CGFloat = area.minY + CGFloat(overlay.inkTop) * area.height
                    rect.origin.y += want - ink
                }
            }
        }

        // 字贴着哪条边就向哪边对齐（左下角的字左对齐、右上角的右对齐；左栏左齐、右栏右齐）；手动拖的、
        // 底栏保留原对齐。铺满宽度的行已经按框宽定好字号（摆位、出图记录、画都用这一份）。
        // 只管没转过的横排字（竖排的 alignH 管的是列往哪边排、转过的字对齐在它自己的阅读方向上）。
        let upright = !chosenText.vertical && !chosenText.isRotated
        var text = chosenText
        if upright, let cell = chosen.cell {
            text.alignH = cell.col == 0 ? .leading : (cell.col == 1 ? .center : .trailing)
        }
        if upright, chosen == .leftColumn { text.alignH = .leading }
        if upright, chosen == .rightColumn { text.alignH = .trailing }
        if upright, chosen == .bottomBand, clean != nil { text.alignH = sideAlign }
        text.alignV = .leading

        let sampled = meanLuminance(rect, grid: grid, mapper: mapper)
        // 字落在留白底色上（取不到照片）时不调：底色本身不过色调。
        let lum = sampled.map { matted ? $0 : graded($0, look: look, strength: lookStrength) } ?? background.luminance
        // 干净的字：深浅按每个字形底下最不利的地方定，顺带算光晕、底部压暗（取不到照片的照旧按平均亮度）。
        let verdict = clean?.judge(text, rect: rect, short: fit.short, tone: overlay.tone, fade: overlay.fade,
                                   area: area, sizes: lineSizes(text, scale: fit.short / short, vars: vars))
        let light = verdict?.light ?? tone(lum, overlay.tone)
        text.lines = text.lines.map { line in
            var l = line
            l.color = toned(line.color, light: light)
            // 花字跟着翻：描边、底条和字反着来（浅字配深边深底、深字配浅边浅底），渐变下端跟字一起翻。
            if var fx = l.effect {
                fx.strokeColor = toned(fx.strokeColor, light: !light)
                fx.bandColor = toned(fx.bandColor, light: !light)
                if let g = fx.gradient { fx.gradient = toned(g, light: light) }
                l.effect = fx
            }
            return l
        }
        // 强调色从照片取的行（时尚刊）：按这一行字形底下最不利的亮度（干净的字；别的按整块平均）挑主体里最鲜艳、
        // 对比够 3:1 的那个颜色；挑不出来用翻过深浅的原色，原色也不够就用白 / 墨。
        if let photo, text.lines.contains(where: { $0.accentFromPhoto }) {
            for i in text.lines.indices where text.lines[i].accentFromPhoto {
                let under = runIndex(text, line: i, vars: vars).flatMap { verdict?.worstLum[$0] } ?? lum
                text.lines[i].color = CollageStyleFashion.accent(for: photo, under: under, light: light)
                    ?? CollageStyleFashion.accentFallback(text.lines[i].color, under: under, light: light)
            }
        }
        // 正文（多栏字、灰条）跟着一起翻深浅。
        if var body = text.body {
            body.color = toned(body.color, light: light)
            text.body = body
        }
        // 衬：按最后落的位置底下有多花、反差够不够定（干净的天空上 = 0，什么都不加）。
        var halo = 0.0
        if let box = mapper.toPhoto(rect), let stats = grid?.stats(in: box) {
            let busy: Double = min(1, max(0, (stats.busy - 0.22) / 0.4))
            halo = max(busy, illegibility(stats, light: light))
        }
        var placed = Placement(rect: rect, short: fit.short, text: text, light: light, anchor: chosen, halo: halo)
        if let verdict {
            placed.glow = verdict.glow
            placed.fade = verdict.fade
            placed.deficit = verdict.deficit
        }
        placed.cost = picked.cost
        placed.onBody = picked.onBody
        return placed
    }

    /// 自动位置试的几档大小、缩小的代价（缩到 0.72 ≈ 1.7）。
    private static let autoScales: [Double] = [1, 0.85, 0.72]
    private static let shrinkCost = 6.0
    /// 左栏 / 右栏最多占照片区多宽（封面字的栏在 2–33%W、70–97%W，中间留给人）。
    static let columnShare = 0.4
    /// 干净的字的栏换到另一边（这一边全压在人身上）多算的代价。
    private static let flipCost = 1.5
    /// 换到的那一边已经是同一格另一栏的位置，再多算的代价。
    private static let stackCost = 6.0

    /// 字块占的框：量出来的尺寸取整 +1；带正文的占满能用的框（正文铺满剩下的地方）。
    private static func boxSize(_ measured: CGSize, text: CollageText, limit: CGSize) -> CGSize {
        if text.body != nil { return CGSize(width: floor(limit.width), height: floor(limit.height)) }
        return CGSize(width: ceil(measured.width) + 1, height: ceil(measured.height) + 1)
    }

    /// 自动字色：底下平均亮度 0.56 以下用浅字（和最后真正上色用同一条线；拼图水印的「自动深浅」也用它）。
    static func tone(_ mean: Double, _ tone: CollageTone) -> Bool {
        switch tone {
        case .auto: return mean < 0.56
        case .light: return true
        case .dark: return false
        }
    }

    /// 网格是调色前的亮度：套了色调（日系提亮、复古抬黑位）要按调完的亮度判深浅。
    static func graded(_ lum: Double, look: CollageLook, strength: Double) -> Double {
        guard look != .none, strength > 0 else { return lum }
        let m = CollageLooks.map(look, lum, lum, lum)
        let after: Double = 0.2126 * m.0 + 0.7152 * m.1 + 0.0722 * m.2
        return lum + (after - lum) * min(1, strength)
    }

    /// 字和底的对比度（WCAG 那种，1…21），按底下最不利的那一片算：浅字看底下偏亮的、深字看偏暗的。
    static func contrast(_ stats: Grid.Stats, light: Bool) -> Double {
        let sigma: Double = stats.spread / 2
        let bg: Double = light ? min(1, stats.mean + sigma) : max(0, stats.mean - sigma)
        let lb: Double = CollageLooks.linear(bg)
        let lt: Double = light ? 0.9 : 0.02
        return (max(lb, lt) + 0.05) / (min(lb, lt) + 0.05)
    }

    /// 0 = 反差足够（≥ 4.5），1 = 几乎看不清（≤ 1.5）。
    static func illegibility(_ stats: Grid.Stats, light: Bool) -> Double {
        min(1, max(0, (4.5 - contrast(stats, light: light)) / 3))
    }

    // MARK: - 候选位置

    static func anchored(_ anchor: CollageAnchor, size: CGSize, in inner: CGRect) -> CGRect {
        guard let cell = anchor.cell else {
            return CGRect(x: inner.midX - size.width / 2, y: inner.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        let x: CGFloat
        switch cell.col {
        case 0: x = inner.minX
        case 1: x = inner.midX - size.width / 2
        default: x = inner.maxX - size.width
        }
        let y: CGFloat
        switch cell.row {
        case 0: y = inner.minY
        case 1: y = inner.midY - size.height / 2
        default: y = inner.maxY - size.height
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func clampRect(_ r: CGRect, into box: CGRect) -> CGRect {
        let w = min(r.width, box.width)
        let h = min(r.height, box.height)
        let x = min(max(r.minX, box.minX), box.maxX - w)
        let y = min(max(r.minY, box.minY), box.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 版式上的偏好：标题最常见在上方、签名式小字在左下；正中间最后才考虑。
    private static func prior(_ anchor: CollageAnchor, vertical: Bool) -> Double {
        if vertical {
            switch anchor {
            case .topTrailing: return 0
            case .topLeading: return 0.05
            case .trailing, .leading: return 0.2
            case .bottomTrailing, .bottomLeading: return 0.3
            default: return 0.6
            }
        }
        switch anchor {
        case .top: return 0
        case .topLeading: return 0.04
        case .bottomLeading: return 0.06
        case .bottom: return 0.08
        case .topTrailing: return 0.1
        case .bottomTrailing: return 0.12
        case .leading, .trailing: return 0.3
        case .center: return 0.45
        default: return 0.5
        }
    }

    /// 定一条边的几种：左栏 / 右栏贴着那条边，从上到下 13 个位置；底栏贴着底边往上 9 个位置（最多抬到 40% 高），
    /// 横向按字自己的对齐。先验很轻（栏偏上一点、底栏越贴底越好）：真正挑位置的是躲脸、躲前面的字块、底下干不干净。
    private static func sideCandidates(_ anchor: CollageAnchor, size: CGSize, in inner: CGRect,
                                       alignH: CollageAlign) -> [(CGRect, Double)] {
        let w = Double(size.width)
        let h = Double(size.height)
        if anchor == .leftColumn || anchor == .rightColumn {
            let x: Double = anchor == .leftColumn ? Double(inner.minX) : Double(inner.maxX) - w
            let span: Double = max(0, Double(inner.height) - h)
            return (0...12).map { k in
                let t = Double(k) / 12
                let y: Double = Double(inner.minY) + span * t
                return (CGRect(x: x, y: y, width: w, height: h), 0.15 * t)
            }
        }
        let x: Double
        switch alignH {
        case .leading: x = Double(inner.minX)
        case .center: x = Double(inner.midX) - w / 2
        case .trailing: x = Double(inner.maxX) - w
        }
        let span: Double = max(0, min(Double(inner.height) * 0.4, Double(inner.height) - h))
        let bottom: Double = Double(inner.maxY) - h
        return (0...8).map { k in
            let t = Double(k) / 8
            return (CGRect(x: x, y: bottom - span * t, width: w, height: h), 0.3 * t)
        }
    }

    /// 越低越好：压脸最重，压身体次之，底下越乱、明暗越不均越差。prior = 版式上对这个位置的偏好。
    private static func cost(_ r: CGRect, prior: Double, photo: CollagePhotoRef?,
                             hints: CollageCrop.Hints?, grid: Grid?, mapper: Mapper, tone: CollageTone) -> Double {
        var c = prior
        guard let photo, let box = mapper.toPhoto(r) else { return c }
        let boxArea = max(1e-9, Double(box.width * box.height))
        for f in photo.faces where CollageCrop.isValidBox(f) {
            let face = CGRect(x: f[0], y: f[1], width: f[2] - f[0], height: f[3] - f[1])
            let faceArea = max(1e-9, Double(face.width * face.height))
            let hit = intersectionArea(box, face)
            if hit > 0 {
                let covered: Double = hit / min(faceArea, boxArea)
                c += 30 * covered + 3
            }
            // 身体：脸下方约五张脸高、左右各一张多脸宽。
            let fw = Double(face.width)
            let fh = Double(face.height)
            let body = CGRect(x: Double(face.midX) - 1.4 * fw, y: Double(face.maxY),
                              width: 2.8 * fw, height: 5 * fh)
            let bodyHit = intersectionArea(box, body)
            c += 4 * bodyHit / boxArea
        }
        if photo.faces.isEmpty, let s = hints?.subject, s.count == 4 {
            let subject = CGRect(x: s[0], y: s[1], width: s[2] - s[0], height: s[3] - s[1])
            c += 6 * intersectionArea(box, subject) / boxArea
        }
        if let grid, let stats = grid.stats(in: box) {
            c += 5 * stats.busy + 2 * stats.spread
            c += 3 * illegibility(stats, light: self.tone(stats.mean, tone))
        }
        return c
    }

    /// 压到相册中缝、轮播切缝、九宫格切线：印出来被书脊吃掉，或者一句字被切在两张图上。
    private static func seamCost(_ r: CGRect, seams: [CGRect]) -> Double {
        let area = max(1e-9, Double(r.width * r.height))
        var c = 0.0
        for band in seams {
            let hit = intersectionArea(r, band)
            if hit > 0 { c += 3 + 30 * hit / area }
        }
        return c
    }

    /// 压到前面已经摆好的字块（同一张照片上的刊头、左栏……）：和 seamCost 一个形状，压一点就 +3，压得越多越贵。
    /// 没有前面的字块时是 0（只有一个字块的照片和以前逐像素一样）。
    private static func occupiedCost(_ r: CGRect, occupied: [CGRect]) -> Double {
        guard !occupied.isEmpty else { return 0 }
        let area = max(1e-9, Double(r.width * r.height))
        var c = 0.0
        for box in occupied {
            let hit = intersectionArea(r, box)
            if hit > 0 { c += 3 + 30 * hit / area }
        }
        return c
    }

    /// 压没压着前面已经摆好的字块（已占用的框本来就外扩过一点）。
    private static func hitsOccupied(_ r: CGRect, _ occupied: [CGRect]) -> Bool {
        occupied.contains { intersectionArea(r, $0) > 0 }
    }

    /// 固定位置的字（下方字幕、上方居中）压在竖的切缝上：往字块中心那一侧挪开；两边都挪不开
    /// （字比半边还宽）就不动。手动拖的不管 —— 用户放哪就是哪。
    private static func clearOfSeams(_ r: CGRect, canvas: CollageCanvas, within box: CGRect) -> CGRect {
        guard canvas.seams == .fold || canvas.seams == .carousel else { return r }
        var out = r
        for band in CollageLayout.seamLines(canvas) where out.intersects(band) {
            let toLeft = band.minX - out.width
            let toRight = band.maxX
            let order = out.midX < band.midX ? [toLeft, toRight] : [toRight, toLeft]
            for x in order where x >= box.minX - 0.5 && x + out.width <= box.maxX + 0.5 {
                out.origin.x = x
                break
            }
        }
        return out
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        return i.isNull ? 0 : Double(i.width * i.height)
    }

    private static func meanLuminance(_ r: CGRect, grid: Grid?, mapper: Mapper) -> Double? {
        guard let grid, let box = mapper.toPhoto(r) else { return nil }
        return grid.stats(in: box)?.mean
    }

    // MARK: - 字色

    /// 浅底配深字、深底配浅字：只翻亮度，色相和层级（主字深、小字浅）保留。
    static func toned(_ color: CollageColor, light: Bool) -> CollageColor {
        var hsl = color.hsl
        if light {
            if color.luminance < 0.6 { hsl.l = 1 - hsl.l * 0.35 }
        } else {
            if color.luminance > 0.5 { hsl.l = 0.1 + (1 - hsl.l) * 0.35 }
        }
        return CollageColor(hsl: hsl)
    }

    // MARK: - 成品坐标 ↔ 照片坐标

    struct Mapper {
        var drawn: CGRect
        var window: CollageCrop.Window?

        func toPhoto(_ r: CGRect) -> CGRect? {
            guard let w = window, drawn.width > 0, drawn.height > 0 else { return nil }
            let clipped = r.intersection(drawn)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            let sx = w.w / Double(drawn.width)
            let sy = w.h / Double(drawn.height)
            let x0 = w.x + Double(clipped.minX - drawn.minX) * sx
            let y0 = w.y + Double(clipped.minY - drawn.minY) * sy
            return CGRect(x: x0, y: y0, width: Double(clipped.width) * sx, height: Double(clipped.height) * sy)
        }
    }

    // MARK: - 亮度网格（取景窗口里 48×48 的亮度，从 256 预览算，和渲染尺寸无关）
    //
    // 48 而不是 24：栏杆石雕、窗格这种笔画粗细的花纹，24 格一平均就看不出来了（字压上去照样难认）。

    struct Grid {
        static let side = 48
        /// 照片坐标里网格覆盖的范围（= 取景窗口）。
        var window: CGRect
        var lum: [Double]
        var grad: [Double]

        struct Stats {
            var mean: Double
            var spread: Double
            var busy: Double
        }

        func stats(in box: CGRect) -> Stats? {
            let n = Grid.side
            guard window.width > 0, window.height > 0 else { return nil }
            let u0 = Double((box.minX - window.minX) / window.width)
            let u1 = Double((box.maxX - window.minX) / window.width)
            let v0 = Double((box.minY - window.minY) / window.height)
            let v1 = Double((box.maxY - window.minY) / window.height)
            let i0 = max(0, min(n - 1, Int(u0 * Double(n))))
            let i1 = max(i0, min(n - 1, Int((u1 * Double(n)).rounded(.up)) - 1))
            let j0 = max(0, min(n - 1, Int(v0 * Double(n))))
            let j1 = max(j0, min(n - 1, Int((v1 * Double(n)).rounded(.up)) - 1))
            var sum = 0.0
            var sq = 0.0
            var g = 0.0
            var count = 0.0
            for j in j0...j1 {
                for i in i0...i1 {
                    let v = lum[j * n + i]
                    sum += v
                    sq += v * v
                    g += grad[j * n + i]
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            let mean = sum / count
            let variance = max(0, sq / count - mean * mean)
            return Stats(mean: mean, spread: variance.squareRoot() * 2, busy: min(1, g / count * 4))
        }
    }

    private static let gridLock = NSLock()
    private static var gridCache: [String: Grid] = [:]

    static func luminanceGrid(_ photo: CollagePhotoRef, window: CollageCrop.Window) -> Grid? {
        // 窗口按确切值记：取三位小数时相差不到 0.0005 的两个窗口共用一份，谁先算谁的留下，结果跟着先后顺序变。
        let key = CollageVision.cacheKey(photo) + "|\(window.x),\(window.y),\(window.w),\(window.h)"
        gridLock.lock()
        if let hit = gridCache[key] {
            gridLock.unlock()
            return hit
        }
        gridLock.unlock()
        guard let image = CollageImages.preview(photo, need: 256) else { return nil }
        let iw = Double(image.width)
        let ih = Double(image.height)
        let crop = CGRect(x: window.x * iw, y: window.y * ih, width: max(1, window.w * iw), height: max(1, window.h * ih)).integral
        guard let piece = image.cropping(to: crop),
              let g = grid(of: piece, window: CGRect(x: window.x, y: window.y, width: window.w, height: window.h))
        else { return nil }
        gridLock.lock()
        if gridCache.count > 256 { gridCache.removeAll() }
        gridCache[key] = g
        gridLock.unlock()
        return g
    }

    /// 一张图缩成 48×48 的亮度网格（不缓存，调用方自己缓存）。window = 这张图在照片坐标里是哪块。
    static func grid(of piece: CGImage, window: CGRect) -> Grid? {
        let n = Grid.side
        var pixels = [UInt8](repeating: 0, count: n * n)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(piece, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        // CG 位图第 0 行在上（和照片坐标一致）。
        let lum = pixels.map { Double($0) / 255 }
        return Grid(window: window, lum: lum, grad: gradients(lum))
    }

    /// 每一格和右边、下边那一格的亮度差（「乱不乱」）。
    private static func gradients(_ lum: [Double]) -> [Double] {
        let n = Grid.side
        var grad = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let v = lum[j * n + i]
                let right = i + 1 < n ? lum[j * n + i + 1] : v
                let down = j + 1 < n ? lum[(j + 1) * n + i] : v
                grad[j * n + i] = abs(right - v) + abs(down - v)
            }
        }
        return grad
    }

    private static var mattedCache: [String: Grid] = [:]

    /// 抠图格字底下的亮度网格：每一格按蒙版（格子里 3×3 个点的平均）把调完色的照片亮度和页面底色混起来，乱不乱
    /// 按混完的亮度重算（人形的边贴在底色上也是一道边）。底色和网格是同一个亮度尺度，不过色调。
    /// 按照片、取景、蒙版内容、底色、色调缓存（不进 gridCache：那个键里没有蒙版和底色）。
    static func mattedGrid(_ g: Grid, photo: CollagePhotoRef, matte: CollageMasks.Mask, background: CollageColor,
                           look: CollageLook, strength: Double) -> Grid {
        let w = g.window
        let key = CollageVision.cacheKey(photo) + "|\(w.minX),\(w.minY),\(w.width),\(w.height)|" + matte.signature
            + "|\(background.r),\(background.g),\(background.b)|\(look.rawValue)|\(strength)"
        gridLock.lock()
        if let hit = mattedCache[key] {
            gridLock.unlock()
            return hit
        }
        gridLock.unlock()
        let n = Grid.side
        let paper = background.luminance
        let x0 = Double(w.minX)
        let y0 = Double(w.minY)
        let cw: Double = Double(w.width) / Double(n)
        let ch: Double = Double(w.height) / Double(n)
        var lum = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                var m = 0.0
                for b in 0..<3 {
                    for a in 0..<3 {
                        let u: Double = x0 + (Double(i) + (Double(a) + 0.5) / 3) * cw
                        let v: Double = y0 + (Double(j) + (Double(b) + 0.5) / 3) * ch
                        m += matte.value(u: u, v: v)
                    }
                }
                m /= 9
                let shot = graded(g.lum[j * n + i], look: look, strength: strength)
                lum[j * n + i] = m * shot + (1 - m) * paper
            }
        }
        let out = Grid(window: w, lum: lum, grad: gradients(lum))
        gridLock.lock()
        if mattedCache.count > 64 { mattedCache.removeAll() }
        mattedCache[key] = out
        gridLock.unlock()
        return out
    }

    // MARK: - 预设：杂志小字层

    struct Preset: Identifiable {
        let key: String
        let name: String
        let overlay: CollageOverlay
        var id: String { key }
    }

    static let presets: [Preset] = [
        Preset(key: "masthead", name: "刊头大标题", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("{title}", font: .songti, weight: .bold, size: 0.1, tracking: 0.18, color: .ink),
                CollageTextLine("{month_en} · {year} · NO.{no}", font: .didot, weight: .regular, size: 0.016,
                                tracking: 0.45, color: .ink),
            ], vertical: false, alignH: .center, alignV: .leading)
            t.lineSpacing = 0.5
            // 自动：没有脸挡着就在上方（上方的先验分最低），压到脸才换地方。
            var o = CollageOverlay(text: t)
            o.inset = 0.05
            return o
        }()),
        Preset(key: "corner", name: "角标小字", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("No.{no}", font: .didot, weight: .regular, size: 0.03, color: .ink, italic: true),
                CollageTextLine("{date}", font: .avenir, weight: .regular, size: 0.012, tracking: 0.35, color: .ink),
                CollageTextLine("{subtitle}", font: .pingfang, weight: .light, size: 0.013, tracking: 0.2, color: .ink),
            ], vertical: false, alignH: .leading, alignV: .leading)
            t.lineSpacing = 0.55
            var o = CollageOverlay(text: t)
            o.inset = 0.06
            return o
        }()),
        Preset(key: "subtitle", name: "电影字幕", overlay: {
            let t = CollageText(lines: [
                // 没填副标题时先放一句（以前空着，点了什么都不出、也没有框可拖）。
                CollageTextLine("{subtitle|那天的风，吹得很温柔}", font: .pingfang, weight: .regular, size: 0.03,
                                tracking: 0.06, color: .white),
            ], vertical: false, alignH: .center, alignV: .leading)
            var o = CollageOverlay(text: t)
            o.anchor = .bottom
            o.tone = .light
            o.shadow = 0.75
            o.inset = 0.07
            return o
        }()),
        Preset(key: "vertical", name: "竖排题字", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("{title}", font: .songti, weight: .regular, size: 0.058, color: .ink),
                CollageTextLine("{date_cn}", font: .songti, weight: .regular, size: 0.016, color: .ink, indent: 5.5),
            ], vertical: true, alignH: .trailing, alignV: .leading)
            t.lineSpacing = 0.55
            t.seal = CollageSeal(text: "光", color: .seal, size: 0.026)
            var o = CollageOverlay(text: t)
            o.inset = 0.07
            return o
        }()),
        Preset(key: "number", name: "大号期数", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("{no}", font: .bodoni, weight: .regular, size: 0.2, color: .ink),
                CollageTextLine("{title}", font: .songti, weight: .light, size: 0.022, tracking: 0.5, color: .ink),
                CollageTextLine("{date}", font: .didot, weight: .regular, size: 0.011, tracking: 0.4, color: .ink),
            ], vertical: false, alignH: .leading, alignV: .leading)
            t.lineSpacing = 0.25
            var o = CollageOverlay(text: t)
            o.inset = 0.05
            return o
        }()),
        Preset(key: "script", name: "英文花体", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("Moments", font: .snell, weight: .bold, size: 0.075, color: .ink),
                CollageTextLine("{month_en} {day}, {year}", font: .didot, weight: .regular, size: 0.013,
                                tracking: 0.4, color: .ink, indent: 1.2),
            ], vertical: false, alignH: .leading, alignV: .leading)
            t.lineSpacing = 0.15
            var o = CollageOverlay(text: t)
            o.inset = 0.06
            return o
        }()),
        Preset(key: "handwrite", name: "手写一句", overlay: {
            let t = CollageText(lines: [
                CollageTextLine("今天的风很温柔", font: .hanzipen, weight: .regular, size: 0.05, color: .ink),
                CollageTextLine("{date}", font: .hanzipen, weight: .regular, size: 0.022, color: .ink),
            ], vertical: false, alignH: .leading, alignV: .leading)
            var o = CollageOverlay(text: t)
            o.inset = 0.06
            return o
        }()),
    ]

    static func preset(_ key: String) -> CollageOverlay? { presets.first { $0.key == key }?.overlay }
}

// MARK: - HSL（字色翻亮度用）

extension CollageColor {
    struct HSL {
        var h: Double
        var s: Double
        var l: Double
    }

    var hsl: HSL {
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-9 else { return HSL(h: 0, s: 0, l: l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        return HSL(h: h, s: s, l: l)
    }

    init(hsl: HSL) {
        let l = min(1, max(0, hsl.l))
        let s = min(1, max(0, hsl.s))
        guard s > 1e-9 else {
            self.init(r: l, g: l, b: l)
            return
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        self.init(r: channel(hsl.h + 1.0 / 3), g: channel(hsl.h), b: channel(hsl.h - 1.0 / 3))
    }
}
