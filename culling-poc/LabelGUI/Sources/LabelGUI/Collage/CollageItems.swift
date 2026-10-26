import Foundation
import CoreGraphics
import CoreText
import CoreImage

/// 自由图层：几何（中心 + 大小 + 旋转）、命中测试、绘制（相纸/白边/胶片/相角、胶带、标签、
/// 邮戳、回形针、手写字）。纯函数，任何线程都能跑。
///
/// 坐标：成品像素、左上原点（和格子一样）；旋转角顺时针。所有尺寸按画布短边换算，
/// 画布改比例时贴纸不会被拉扁。
enum CollageItems {

    // MARK: - 几何

    static func center(_ item: CollageItem, canvas: CollageCanvas) -> CGPoint {
        CGPoint(x: item.cx * Double(canvas.width), y: item.cy * Double(canvas.height))
    }

    static func size(_ item: CollageItem, canvas: CollageCanvas) -> CGSize {
        CGSize(width: item.width * canvas.shortSide, height: item.height * canvas.shortSide)
    }

    /// 以中心为原点的局部坐标 → 成品坐标。
    static func transform(_ item: CollageItem, canvas: CollageCanvas) -> CGAffineTransform {
        let c = center(item, canvas: canvas)
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(item.rotation * .pi / 180))
    }

    static func localRect(_ item: CollageItem, canvas: CollageCanvas) -> CGRect {
        let s = size(item, canvas: canvas)
        return CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height)
    }

    /// 四个角（成品坐标，顺时针从左上开始）。
    static func corners(_ item: CollageItem, canvas: CollageCanvas) -> [CGPoint] {
        let r = localRect(item, canvas: canvas)
        let t = transform(item, canvas: canvas)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(t) }
    }

    static func contains(_ item: CollageItem, point: CGPoint, canvas: CollageCanvas, slop: CGFloat = 0) -> Bool {
        let local = point.applying(transform(item, canvas: canvas).inverted())
        return localRect(item, canvas: canvas).insetBy(dx: -slop, dy: -slop).contains(local)
    }

    /// 画布上点选：油性笔的圈、叉、裁切线只有笔迹附近算点中（里面是空的，点进去选的是底下的照片格）。
    static func hits(_ item: CollageItem, point: CGPoint, canvas: CollageCanvas, slop: CGFloat = 0) -> Bool {
        guard contains(item, point: point, canvas: canvas, slop: slop) else { return false }
        guard item.kind == .sticker, item.sticker == .greasePencil else { return true }
        let local = point.applying(transform(item, canvas: canvas).inverted())
        let r = localRect(item, canvas: canvas)
        let u = abs(Double(local.x - r.midX) / max(1, Double(r.width) / 2))
        let v = abs(Double(local.y - r.midY) / max(1, Double(r.height) / 2))
        switch item.mark {
        case .dot:
            // 点是实心一团，整个外框都算。
            return true
        case .circle:
            let d = (u * u + v * v).squareRoot()
            return d >= 0.72 && d <= 1.15
        case .cross:
            // 只认两条对角线附近（u、v 取了绝对值，两条对角线都是 u = v，框角也在上面）；框边上没有墨，
            // 点下去选的是底下那一格。
            return abs(u - v) < 0.14
        case .cropLine:
            return max(u, v) >= 0.78
        }
    }

    /// 外接矩形（成品坐标）。
    static func bounds(_ item: CollageItem, canvas: CollageCanvas) -> CGRect {
        let pts = corners(item, canvas: canvas)
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    // MARK: - 贴在相纸上

    /// 按贴纸现在的位置记下它贴在相纸的哪儿（相纸局部坐标，相对相纸宽高）。
    static func attachment(of sticker: CollageItem, to photo: CollageItem, canvas: CollageCanvas) -> CollageAttachment {
        let s = size(photo, canvas: canvas)
        let local = center(sticker, canvas: canvas).applying(transform(photo, canvas: canvas).inverted())
        let x: Double = Double(local.x) / Double(max(1, s.width))
        let y: Double = Double(local.y) / Double(max(1, s.height))
        return CollageAttachment(to: photo.id, x: x, y: y, angle: sticker.rotation - photo.rotation)
    }

    /// 按相纸现在的位置、角度、大小把贴在上面的贴纸摆回去。
    static func pinned(_ sticker: CollageItem, to photo: CollageItem, canvas: CollageCanvas) -> CollageItem {
        guard let a = sticker.attach else { return sticker }
        let s = size(photo, canvas: canvas)
        let local = CGPoint(x: CGFloat(a.x) * s.width, y: CGFloat(a.y) * s.height)
        let p = local.applying(transform(photo, canvas: canvas))
        var out = sticker
        out.cx = Double(p.x) / Double(max(1, canvas.width))
        out.cy = Double(p.y) / Double(max(1, canvas.height))
        out.rotation = photo.rotation + a.angle
        return out
    }

    /// 贴着的贴纸全部跟着自己的相纸摆好；相纸已经不在这一页上的，贴纸一起拿掉。
    static func pinAll(_ items: [CollageItem], canvas: CollageCanvas) -> [CollageItem] {
        var photos: [UUID: CollageItem] = [:]
        for it in items where it.kind == .photo { photos[it.id] = it }
        return items.compactMap { it -> CollageItem? in
            guard let a = it.attach else { return it }
            guard let photo = photos[a.to] else { return nil }
            return pinned(it, to: photo, canvas: canvas)
        }
    }

    /// 图层改完之后：`moved` 是贴着的贴纸自己被挪/转了 → 按新位置重新记它贴在哪儿（拖离相纸就不再
    /// 贴着）；其余贴着的跟着相纸摆好。
    static func normalized(_ input: [CollageItem], moved: UUID?, canvas: CollageCanvas) -> [CollageItem] {
        var items = input
        if let moved, let i = items.firstIndex(where: { $0.id == moved }), items[i].kind == .sticker {
            let slop = CGFloat(canvas.shortSide * 0.05)
            let c = center(items[i], canvas: canvas)
            let canStick = items[i].sticker.isTape || items[i].sticker == .clip
            if let a = items[i].attach, let photo = items.first(where: { $0.id == a.to }),
               contains(photo, point: c, canvas: canvas, slop: slop) {
                // 还在原来那张上：记新位置。
                items[i].attach = attachment(of: items[i], to: photo, canvas: canvas)
            } else if canStick, let photo = items[..<i].last(where: {
                $0.kind == .photo && contains($0, point: c, canvas: canvas, slop: slop)
            }) {
                // 胶带、回形针拖到了（叠放顺序在它下面的）另一张相纸上：贴到那一张。
                items[i].attach = attachment(of: items[i], to: photo, canvas: canvas)
            } else {
                items[i].attach = nil
            }
        }
        return pinAll(items, canvas: canvas)
    }

    /// 一张相纸和贴在它上面的贴纸（叠放顺序里一起挪）。
    static func group(of id: UUID, in items: [CollageItem]) -> [Int] {
        items.indices.filter { items[$0].id == id || items[$0].attach?.to == id }
    }

    /// 换画布比例：整页图层按外接框等比缩放、居中放进新画布，四周留和原来一样的边（按短边比例）——
    /// 摆法、叠放、相对大小都不变，也不会出画；按外接框算，来回切比例能缩回原来的大小
    /// （位置按画布比例、大小按短边存，直接换比例会把散落版扯散、甩出画外）。
    static func refit(_ items: [CollageItem], from old: CollageCanvas, to new: CollageCanvas) -> [CollageItem] {
        guard let first = items.first else { return items }
        var box = bounds(first, canvas: old)
        for it in items.dropFirst() { box = box.union(bounds(it, canvas: old)) }
        guard box.width > 1, box.height > 1 else { return items }
        let ow = Double(old.width)
        let oh = Double(old.height)
        let nw = Double(max(1, new.width))
        let nh = Double(max(1, new.height))
        // 原来离画布边最近的那一边留了多少（按短边比例），新画布照留。
        let edges: [Double] = [Double(box.minX), ow - Double(box.maxX), Double(box.minY), oh - Double(box.maxY)]
        let margin: Double = max(0, min(0.2, (edges.min() ?? 0) / old.shortSide)) * new.shortSide
        let availW: Double = max(1, nw - 2 * margin)
        let availH: Double = max(1, nh - 2 * margin)
        // 跨页换跨页：以中缝为轴缩放，左半页的还在左半页（按外接框中心缩，不对称的摆法会被推过中缝）。
        let foldAnchor = old.seams == .fold && new.seams == .fold
        let bx: Double = foldAnchor ? ow / 2 : Double(box.midX)
        let halfW: Double = foldAnchor ? max(bx - Double(box.minX), Double(box.maxX) - bx) : Double(box.width) / 2
        let s: Double = min(availW / max(1, 2 * halfW), availH / Double(box.height))
        let sizeScale: Double = old.shortSide * s / new.shortSide
        let by = Double(box.midY)
        return items.map { it in
            var out = it
            let x: Double = (it.cx * ow - bx) * s + nw / 2
            let y: Double = (it.cy * oh - by) * s + nh / 2
            out.cx = x / nw
            out.cy = y / nh
            out.width = it.width * sizeScale
            out.height = it.height * sizeScale
            return out
        }
    }

    /// 照片在框里实际画的区域（局部坐标）。
    static func photoArea(_ frame: CollageItemFrame, outer: CGRect) -> CGRect {
        let m = min(outer.width, outer.height)
        switch frame {
        case .polaroid:
            return CollageCrop.borderInner(outer, .polaroid)
        case .film:
            return CollageCrop.borderInner(outer, .film)
        case .white:
            let b = m * 0.045
            return outer.insetBy(dx: b, dy: b)
        case .none, .mounts:
            return outer
        }
    }

    /// 照片（内框）比例 → 外框比例。放照片、生成散落版时按它定外框。
    static func outerAspect(inner: Double, frame: CollageItemFrame) -> Double {
        // 解 photoArea 的逆：外框宽 1、高 h，内框宽高比 = inner。
        switch frame {
        case .polaroid:
            // 竖（w ≤ h）：m = w。内 = (0.9w) × (h − 0.24w)
            let portrait = 1 / (0.9 / inner + 0.24)
            if portrait <= 1 { return portrait }
            // 横（h < w）：m = h。内 = (w − 0.1h) × 0.76h → w/h = 0.76·inner + 0.1
            return 0.76 * inner + 0.1
        case .white:
            // 四边等宽 0.045m
            if inner <= 1 { return 1 / ((1 - 0.09) / inner + 0.09) }
            return inner * 0.91 + 0.09
        case .film:
            // 齿孔带在外框的长边上：内框只能是 ≥1.22（横）或 ≤0.82（竖）。接近正方形的照片
            // 按横竖贴到最近的可行比例（最多多裁 18%），不能让分支选错了方向裁掉三成。
            if inner >= 1 { return max(1, inner * 0.8 / 0.976) }
            return min(0.999, 0.976 * inner / 0.8)
        case .none, .mounts:
            return inner
        }
    }

    // MARK: - 绘制

    struct DrawContext {
        var canvas: CollageCanvas
        var scale: Double
        var bleed: Double
        var photos: [String: CollagePhotoRef]
        var hints: [String: CollageCrop.Hints]
        var colorOps: [String: CollageLooks.Ops]
        var vars: [String: String]
        var options: CollageRender.Options
        var sharpenRadius: Double
        var sharpen: Double
        var canvasHeight: Int
        /// 水印（nil = 这次渲染不画水印）：「每张照片」层画在相纸上；整页层「自动深浅」要知道相纸在哪。
        var marks: CollageWatermarks.Painter?
        /// 照片加网（同格子：点距按这次渲染的缩放、纸色 = 页面底色）；nil = 不加。
        var screen: CollageScreening.Spec? = nil
        /// 纸纹压在照片上（style.paperOverPhotos）、纸色（页面底色；模糊底、渐变底时是盖在上面的底色块）。
        var paperOver = 0.0
        var background: CollageColor = .paper
    }

    /// 导出里不印的图层：没分到照片的相纸（照片不够、从托盘拿掉了）和贴在它上面的东西。
    static func unprinted(_ items: [CollageItem], photos: [String: CollagePhotoRef]) -> Set<UUID> {
        var blank = Set<UUID>()
        for it in items where it.kind == .photo && it.photoID.flatMap({ photos[$0] }) == nil {
            blank.insert(it.id)
        }
        return Set(items.filter { blank.contains($0.id) || $0.attach.map { blank.contains($0.to) } == true }.map(\.id))
    }

    /// 每个图层转过之后的四个角（成品坐标），顺序同 items；导出里不印的 = nil（预览里的灰色占位也算不印：
    /// 水印躲不躲它，预览和导出得一样）。
    /// 油性笔记号只是一道笔迹（圈、叉里面是空的）：不算盖住底下的照片，水印照常躲它的外框以外的东西。
    static func printedCorners(_ items: [CollageItem], photos: [String: CollagePhotoRef],
                               canvas: CollageCanvas) -> [[CGPoint]?] {
        let skip = unprinted(items, photos: photos)
        return items.map { it in
            return skip.contains(it.id) || isPencil(it) ? nil : corners(it, canvas: canvas)
        }
    }

    static func draw(_ items: [CollageItem], ctx: CGContext, dc: DrawContext) {
        // 没分到照片的相纸：预览里画成灰色占位提醒，导出不印空白相纸，贴在它上面的胶带也不印。
        let skipped = dc.options.placeholders ? [] : unprinted(items, photos: dc.photos)
        for (index, item) in items.enumerated() {
            if skipped.contains(item.id) { continue }
            ctx.saveGState()
            // 成品坐标 → 缩放 + 出血偏移 → 旋转到局部。
            ctx.translateBy(x: CGFloat(dc.bleed), y: CGFloat(dc.bleed))
            ctx.scaleBy(x: CGFloat(dc.scale), y: CGFloat(dc.scale))
            ctx.concatenate(transform(item, canvas: dc.canvas))
            let outer = localRect(item, canvas: dc.canvas)
            switch item.kind {
            case .photo:
                drawPhotoItem(item, index: index, outer: outer, ctx: ctx, dc: dc)
            case .text:
                if let text = item.text {
                    // 这里的 CTM 已经按渲染缩放 scaleBy 过、short 是成品尺寸：花字投影（设备空间）要再乘一次缩放，
                    // 不然预览里的投影比导出大 1/scale 倍。
                    CollageTypeset.draw(text, in: outer, ctx: ctx, short: dc.canvas.shortSide, vars: dc.vars,
                                        canvasHeight: dc.canvasHeight, shadowScale: dc.scale,
                                        owner: "\(dc.vars["no"] ?? "")|item\(index)")
                }
            case .sticker:
                drawSticker(item, outer: outer, ctx: ctx, dc: dc)
            }
            ctx.restoreGState()
        }
    }

    private static let paperWhite = CollageColor(hex: 0xFBFAF6)
    private static let penInk = CollageColor(hex: 0x2E3440)

    private static func drawPhotoItem(_ item: CollageItem, index: Int, outer: CGRect, ctx: CGContext,
                                      dc: DrawContext) {
        let short = dc.canvas.shortSide
        let inner = photoArea(item.frame, outer: outer)
        // 抠图贴纸：只画主体（主体蒙版同步拿，预览、导出一样），相纸框、底下的投影都不画；认不出主体照常画。
        let cutoutMask = item.cutout == nil ? nil
            : item.photoID.flatMap { dc.photos[$0] }.flatMap { CollageMasks.mask(for: $0) }
        // 投影：CG 的阴影偏移在设备空间（y 朝上，不跟旋转走）—— 光从上方来，影子永远往下落。
        let s = CGFloat(item.shadow)
        let px = CGFloat(dc.scale)
        if s > 0, cutoutMask == nil {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(short) * 0.005 * s * px),
                          blur: CGFloat(short) * 0.018 * s * px,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42 * Double(s)))
            ctx.setFillColor(frameFill(item.frame).cgColor)
            ctx.fill(item.frame == .none || item.frame == .mounts ? inner : outer)
            ctx.restoreGState()
        }
        if item.frame != .none && item.frame != .mounts, cutoutMask == nil {
            ctx.setFillColor(frameFill(item.frame).cgColor)
            ctx.fill(outer)
            if item.frame == .film {
                let bg = dc.options.debug ? CollageColor.white : CollageColor(hex: 0x3A3632)
                drawFilmHoles(ctx, outer: outer, inner: inner, color: bg)
            }
        }
        var window: CollageCrop.Window?
        if let id = item.photoID, let photo = dc.photos[id] {
            let framing: CollageFraming = item.framing == .auto ? .full : item.framing
            let w = CollageCrop.window(for: photo, cellAspect: CollageCrop.aspect(of: inner), framing: framing,
                                       override: nil, hints: dc.hints[id])
            window = w
            // 局部坐标按成品像素算，位图要按缩放后的像素要。
            let pw = max(1, Int((Double(inner.width) * dc.scale).rounded()))
            let ph = max(1, Int((Double(inner.height) * dc.scale).rounded()))
            if let tile = CollageRender.cellImage(photo: photo, window: w, width: pw, height: ph,
                                                  sharpen: dc.sharpen, radius: dc.sharpenRadius,
                                                  export: dc.options.export, report: dc.options.report,
                                                  color: dc.colorOps[id], screen: dc.screen) {
                if let report = dc.options.report, let screen = dc.screen {
                    report.halftone.append(CollageRender.halftoneRecord(screen, owner: "item\(index)", photoID: id))
                }
                if let cutoutMask {
                    let guide = CollageRender.tileGuide(photo, color: dc.colorOps[id], sharpen: dc.sharpen,
                                                        radius: dc.sharpenRadius, export: dc.options.export,
                                                        screen: dc.screen)
                    let shown = CollageRender.Shown(tile: tile, drawn: inner, window: w,
                                                    clip: CGPath(rect: inner, transform: nil), guide: guide)
                    CollageRender.drawSubject(ctx, shown: shown, mask: cutoutMask, scale: dc.scale, short: short * dc.scale,
                                              region: nil, cutout: item.cutout)
                } else {
                    ctx.saveGState()
                    ctx.clip(to: inner)
                    CollageRender.drawImageTopLeft(ctx, tile, inner)
                    ctx.restoreGState()
                    // 纸纹压在照片上：局部坐标已经按缩放放大过，纸纹块按设备像素和页面那层一样粗。
                    if dc.paperOver > 0 {
                        let k: Double = max(0.2, min(1, dc.scale)) / max(0.01, dc.scale)
                        CollageRender.drawPaperOver(ctx, clips: [CGPath(rect: inner, transform: nil)],
                                                    intensity: dc.paperOver, paper: dc.background,
                                                    tint: dc.screen == nil, scale: dc.scale, tileScale: k)
                    }
                }
            }
        } else if dc.options.placeholders {
            ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
            ctx.fill(inner)
        }
        // 这张相纸自己的占位符（{frame} 帧号）：下沿手写字、水印的字用它。
        let itemVars = CollageTypeset.cellVariables(dc.vars, photo: item.photoID.flatMap { dc.photos[$0] })
        if item.frame == .polaroid, !item.caption.isEmpty, cutoutMask == nil {
            let band = CGRect(x: inner.minX, y: inner.maxY, width: inner.width, height: outer.maxY - inner.maxY)
            let caption = CollageTypeset.fill(item.caption, vars: itemVars)
            if !caption.isEmpty, band.height > 4 {
                let sizeRel = Double(band.height) * 0.36 / short
                var t = CollageText(lines: [CollageTextLine(caption, font: .hanzipen, weight: .regular,
                                                            size: sizeRel, color: penInk)],
                                    vertical: false, alignH: .center, alignV: .center)
                t.lineSpacing = 0
                CollageTypeset.draw(t, in: band.insetBy(dx: band.width * 0.06, dy: band.height * 0.12), ctx: ctx,
                                    short: short, vars: itemVars, canvasHeight: dc.canvasHeight)
            }
        }
        if item.frame == .mounts, cutoutMask == nil { drawMounts(ctx, rect: inner, px: CGFloat(dc.scale)) }
        // 水印压在相角上面、跟着相纸转（区域躲开相角）。
        if let marks = dc.marks, let id = item.photoID, let photo = dc.photos[id], let window {
            marks.drawItem(item, index: index, inner: inner, photo: photo, window: window, vars: itemVars, ctx: ctx)
        }
    }

    private static func frameFill(_ frame: CollageItemFrame) -> CollageColor {
        switch frame {
        case .film: return CollageColor(hex: 0x161514)
        case .white: return .white
        default: return paperWhite
        }
    }

    private static func drawFilmHoles(_ ctx: CGContext, outer: CGRect, inner: CGRect, color: CollageColor) {
        let horizontal = outer.width >= outer.height
        let band = horizontal ? (inner.minY - outer.minY) : (inner.minX - outer.minX)
        let holeShort = band * 0.42
        let holeLong = holeShort * 1.35
        let length = horizontal ? outer.width : outer.height
        let pitch = holeLong * 2.1
        let count = max(2, Int(length / pitch))
        let start = (length - CGFloat(count) * pitch) / 2 + pitch / 2
        ctx.saveGState()
        ctx.setFillColor(color.mixed(with: .white, 0.2).cgColor(alpha: 0.9))
        for i in 0..<count {
            let along = start + CGFloat(i) * pitch
            for side in 0..<2 {
                let r: CGRect
                if horizontal {
                    let y = side == 0 ? outer.minY + (band - holeShort) / 2 : outer.maxY - band + (band - holeShort) / 2
                    r = CGRect(x: outer.minX + along - holeLong / 2, y: y, width: holeLong, height: holeShort)
                } else {
                    let x = side == 0 ? outer.minX + (band - holeShort) / 2 : outer.maxX - band + (band - holeShort) / 2
                    r = CGRect(x: x, y: outer.minY + along - holeLong / 2, width: holeShort, height: holeLong)
                }
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: holeShort * 0.18, cornerHeight: holeShort * 0.18, transform: nil))
            }
        }
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// 相角：四角各一个黑色三角贴片。
    /// px = 渲染缩放：CG 阴影的偏移和模糊是设备像素，不跟 CTM 缩放 —— 手动乘，预览和导出才一样。
    private static func drawMounts(_ ctx: CGContext, rect: CGRect, px: CGFloat) {
        let leg = min(rect.width, rect.height) * 0.14
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1), (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -leg * 0.03 * px), blur: leg * 0.12 * px,
                      color: CGColor(gray: 0, alpha: 0.35))
        for (p, sx, sy) in corners {
            // 贴片比照片角大一圈，斜边压在照片上。
            let o = CGPoint(x: p.x - sx * leg * 0.12, y: p.y - sy * leg * 0.12)
            ctx.move(to: o)
            ctx.addLine(to: CGPoint(x: o.x + sx * leg * 1.12, y: o.y))
            ctx.addLine(to: CGPoint(x: o.x, y: o.y + sy * leg * 1.12))
            ctx.closePath()
        }
        ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.12, blue: 0.12, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        // 斜边一道浅色反光：黑卡纸上的黑相角也看得出来是贴上去的。
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.32))
        ctx.setLineWidth(max(0.5, leg * 0.035))
        for (p, sx, sy) in corners {
            let o = CGPoint(x: p.x - sx * leg * 0.12, y: p.y - sy * leg * 0.12)
            ctx.move(to: CGPoint(x: o.x + sx * leg * 1.1, y: o.y + sy * leg * 0.02))
            ctx.addLine(to: CGPoint(x: o.x + sx * leg * 0.02, y: o.y + sy * leg * 1.1))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - 贴纸

    /// 0…1 的随机数（千分之一精度，够画纹理、定抖动）。
    static func unit(_ rng: inout SeededRandom) -> Double {
        let raw: UInt64 = rng.next() % 1000
        return Double(raw) / 1000
    }

    /// 按 id 定的随机数：同一张胶带每次画出来的纹理一样。门禁（AppRuntime.stableSeeds）按几何定：
    /// 新撒的图层每次运行 id 都不一样，两次出图要逐像素相同。
    static func seed(_ item: CollageItem) -> UInt64 {
        let source = AppRuntime.stableSeeds
            ? "\(item.sticker.rawValue)|\(item.cx)|\(item.cy)|\(item.width)|\(item.height)|\(item.rotation)"
            : item.id.uuidString
        var h: UInt64 = 1469598103934665603
        for b in source.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return h
    }

    private static func drawSticker(_ item: CollageItem, outer: CGRect, ctx: CGContext, dc: DrawContext) {
        switch item.sticker {
        case .washi, .stripe, .dots, .kraft:
            drawTape(item, outer: outer, ctx: ctx, px: CGFloat(dc.scale))
        case .label:
            drawLabel(item, outer: outer, ctx: ctx, dc: dc)
        case .postmark:
            drawPostmark(item, outer: outer, ctx: ctx, dc: dc)
        case .clip:
            drawClip(item, outer: outer, ctx: ctx, px: CGFloat(dc.scale))
        case .barcode:
            drawBarcode(item, outer: outer, ctx: ctx, dc: dc)
        case .greasePencil:
            CollagePencil.draw(item.mark, in: outer, color: item.color, seed: seed(item), ctx: ctx,
                               lineWidth: pencilLineWidth(item, outer: outer, canvas: dc.canvas))
        }
    }

    /// 油性笔贴纸的线宽（局部坐标 = 成品像素）：按记号大小定（帧高的 4–6%，R2 §7），但不超过画布短边的 1.7%
    /// （大照片上圈一圈也还是一支笔的粗细）：1440 宽上 24 像素，六宫格一格（约 586 像素）圈下来是帧高的 4.2%，
    /// 更大的帧才被这个上限压细。画和整页水印躲笔迹（inkBoxes）用同一个。
    static func pencilLineWidth(_ item: CollageItem, outer: CGRect, canvas: CollageCanvas) -> CGFloat {
        let short = CGFloat(canvas.shortSide)
        let lw = min(CollagePencil.defaultLineWidth(item.mark, in: outer), short * 0.017)
        return max(short * 0.0015, lw)
    }

    /// 油性笔贴纸：只是一道笔迹（圈、叉里面是空的），水印不把它的外框当成挡着的东西。
    static func isPencil(_ item: CollageItem) -> Bool { item.kind == .sticker && item.sticker == .greasePencil }

    /// 油性笔的笔迹在哪（成品坐标，一小段一个框，转过的取外接框）；别的图层 = 空。整页水印在留白带里挑哪一头时躲它
    /// （CollageWatermarks.inkObstacles）。
    static func inkBoxes(_ item: CollageItem, canvas: CollageCanvas) -> [CGRect] {
        guard isPencil(item) else { return [] }
        let outer = localRect(item, canvas: canvas)
        let t = transform(item, canvas: canvas)
        let lw = pencilLineWidth(item, outer: outer, canvas: canvas)
        return CollagePencil.inkBoxes(item.mark, in: outer, seed: seed(item), lineWidth: lw).map { $0.applying(t) }
    }

    /// 换油性笔记号：外框按两种记号对那一帧的倍数换算（圈 → 叉：外接椭圆缩回那一帧），中心不动。
    static func withMark(_ item: CollageItem, _ mark: CollagePencilMark) -> CollageItem {
        var out = item
        guard mark != item.mark else { return out }
        let k = mark.frameScale / item.mark.frameScale
        out.width = min(3, max(0.005, item.width * k))
        out.height = min(3, max(0.005, item.height * k))
        out.mark = mark
        return out
    }

    /// 装饰条码：白底、黑条、下面一行字。编的是 Code 128（日期或随机串），不是 EAN/UPC/ISBN/ISSN ——
    /// 只是封面角上的纹理，扫出来也只是这串字，不会被当成真实出版物的商品码。
    private static func drawBarcode(_ item: CollageItem, outer: CGRect, ctx: CGContext, dc: DrawContext) {
        let raw = CollageTypeset.fill(item.label, vars: dc.vars)
        let message = barcodeMessage(raw, seed: seed(item))
        guard let modules = barcodeModules(message), !modules.isEmpty else { return }
        ctx.saveGState()
        ctx.setFillColor(item.color.cgColor)
        ctx.fill(outer)
        let ink = item.color.luminance > 0.5 ? CollageColor(hex: 0x111111) : CollageColor.white
        let quiet = outer.width * 0.07
        let barsRect = CGRect(x: outer.minX + quiet, y: outer.minY + outer.height * 0.1,
                              width: outer.width - quiet * 2, height: outer.height * 0.62)
        let unit = barsRect.width / CGFloat(modules.count)
        ctx.setFillColor(ink.cgColor)
        var i = 0
        while i < modules.count {
            guard modules[i] else {
                i += 1
                continue
            }
            var j = i
            while j < modules.count, modules[j] { j += 1 }
            ctx.fill(CGRect(x: barsRect.minX + CGFloat(i) * unit, y: barsRect.minY,
                            width: CGFloat(j - i) * unit, height: barsRect.height))
            i = j
        }
        ctx.restoreGState()
        let band = CGRect(x: barsRect.minX, y: barsRect.maxY + outer.height * 0.03, width: barsRect.width,
                          height: outer.maxY - barsRect.maxY - outer.height * 0.06)
        guard band.height > 2 else { return }
        let sizeRel = Double(band.height) * 0.82 / dc.canvas.shortSide
        var t = CollageText(lines: [CollageTextLine(message, font: .typewriter, weight: .regular, size: sizeRel,
                                                    tracking: 0.14, color: ink)],
                            vertical: false, alignH: .center, alignV: .center)
        t.lineSpacing = 0
        CollageTypeset.draw(t, in: band, ctx: ctx, short: dc.canvas.shortSide, vars: [:], canvasHeight: dc.canvasHeight)
    }

    /// 条码上编的字：用户的字（展开占位符）只留 Code 128 能编的 ASCII；空 = 一串固定种子的随机数字。
    static func barcodeMessage(_ raw: String, seed s: UInt64) -> String {
        let ascii = String(raw.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        if !ascii.isEmpty { return String(ascii.prefix(24)) }
        var rng = SeededRandom(seed: s ^ 0xBA5C0DE)
        var digits = (0..<12).map { _ in Int(rng.next() % 10) }
        // 12 位数字碰巧过了 UPC-A 的校验位（十个种子里约一个）就是一个合法的 GTIN-12：最后一位故意错开一个
        // （DESIGN §0.4：装饰条码不能是合法的 EAN / UPC / ISBN / ISSN）。
        let odd = stride(from: 0, to: 11, by: 2).reduce(0) { $0 + digits[$1] }
        let even = stride(from: 1, to: 11, by: 2).reduce(0) { $0 + digits[$1] }
        let check = (10 - (odd * 3 + even) % 10) % 10
        if digits[11] == check { digits[11] = (check + 1) % 10 }
        return digits.map(String.init).joined()
    }

    private static let barcodeLock = NSLock()
    private static var barcodeCache: [String: [Bool]] = [:]

    /// Code 128 的模块（true = 黑条），CICode128BarcodeGenerator 出 1 像素一个模块、不留静区的图，读第一行。
    static func barcodeModules(_ message: String) -> [Bool]? {
        barcodeLock.lock()
        if let hit = barcodeCache[message] {
            barcodeLock.unlock()
            return hit
        }
        barcodeLock.unlock()
        guard let data = message.data(using: .ascii), let gen = CIFilter(name: "CICode128BarcodeGenerator") else { return nil }
        gen.setValue(data, forKey: "inputMessage")
        gen.setValue(0, forKey: "inputQuietSpace")
        gen.setValue(1, forKey: "inputBarcodeHeight")
        guard let image = gen.outputImage else { return nil }
        let extent = image.extent.integral
        let w = Int(extent.width)
        guard w > 0, w < 4096 else { return nil }
        var row = [UInt8](repeating: 255, count: w * 4)
        row.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            CollageRender.ciContext.render(image, toBitmap: base, rowBytes: w * 4,
                                           bounds: CGRect(x: extent.minX, y: extent.minY, width: CGFloat(w), height: 1),
                                           format: .RGBA8, colorSpace: CollageRender.srgb)
        }
        let modules = (0..<w).map { row[$0 * 4] < 128 }
        barcodeLock.lock()
        if barcodeCache.count > 64 { barcodeCache.removeAll() }
        barcodeCache[message] = modules
        barcodeLock.unlock()
        return modules
    }

    /// 胶带：两头撕口是锯齿，半透明能透出底下照片的边。
    static func tapePath(_ r: CGRect, seed s: UInt64) -> CGPath {
        var rng = SeededRandom(seed: s)
        let teeth = max(4, Int(r.height / max(1, r.height * 0.16)))
        let step = r.height / CGFloat(teeth)
        let depth = r.height * 0.09
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        for i in 0..<teeth {
            let y = r.minY + step * CGFloat(i)
            let jitter: CGFloat = CGFloat(unit(&rng)) * depth * 0.6
            path.addLine(to: CGPoint(x: r.maxX - depth - jitter, y: y + step / 2))
            path.addLine(to: CGPoint(x: r.maxX, y: y + step))
        }
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        for i in 0..<teeth {
            let y = r.maxY - step * CGFloat(i)
            let jitter: CGFloat = CGFloat(unit(&rng)) * depth * 0.6
            path.addLine(to: CGPoint(x: r.minX + depth + jitter, y: y - step / 2))
            path.addLine(to: CGPoint(x: r.minX, y: y - step))
        }
        path.closeSubpath()
        return path
    }

    private static func drawTape(_ item: CollageItem, outer: CGRect, ctx: CGContext, px: CGFloat) {
        let path = tapePath(outer, seed: seed(item))
        let alpha = item.sticker == .kraft ? 0.9 : 0.8
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -outer.height * 0.03 * px), blur: outer.height * 0.12 * px,
                      color: CGColor(gray: 0, alpha: 0.18))
        ctx.addPath(path)
        ctx.setFillColor(item.color.cgColor(alpha: alpha))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        var rng = SeededRandom(seed: seed(item) ^ 0x5eed)
        switch item.sticker {
        case .stripe:
            let w = outer.height * 0.22
            ctx.setFillColor(item.color.mixed(with: .white, 0.55).cgColor(alpha: 0.7))
            var x = outer.minX - outer.height
            while x < outer.maxX + outer.height {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x, y: outer.maxY))
                p.addLine(to: CGPoint(x: x + w, y: outer.maxY))
                p.addLine(to: CGPoint(x: x + w + outer.height, y: outer.minY))
                p.addLine(to: CGPoint(x: x + outer.height, y: outer.minY))
                p.closeSubpath()
                ctx.addPath(p)
                x += w * 2.2
            }
            ctx.fillPath()
        case .dots:
            let d = outer.height * 0.2
            let pitch = outer.height * 0.42
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.72))
            var row = 0
            var y = outer.minY + pitch * 0.5
            while y < outer.maxY {
                var x = outer.minX + (row % 2 == 0 ? pitch * 0.5 : pitch)
                while x < outer.maxX {
                    ctx.addEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
                    x += pitch
                }
                y += pitch * 0.5
                row += 1
            }
            ctx.fillPath()
        case .kraft, .washi:
            // 纤维：几十条很淡的细线。
            let n = Int(outer.width / max(1, outer.height) * 14)
            ctx.setLineWidth(max(0.5, outer.height * 0.012))
            for _ in 0..<n {
                let u: CGFloat = CGFloat(unit(&rng))
                let v: CGFloat = CGFloat(unit(&rng))
                let lenFrac: Double = 0.2 + 0.4 * unit(&rng)
                let x0: CGFloat = outer.minX + u * outer.width
                let y0: CGFloat = outer.minY + v * outer.height
                let len: CGFloat = outer.height * CGFloat(lenFrac)
                let dark = rng.next() % 2 == 0
                ctx.setStrokeColor(dark ? CGColor(gray: 0, alpha: 0.07) : CGColor(gray: 1, alpha: 0.18))
                ctx.move(to: CGPoint(x: x0, y: y0))
                ctx.addLine(to: CGPoint(x: x0 + len, y: y0 + len * 0.2))
                ctx.strokePath()
            }
        default:
            break
        }
        // 胶带边上一道高光：看起来是贴上去的，不是印上去的。
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        ctx.setLineWidth(max(0.5, outer.height * 0.04))
        ctx.move(to: CGPoint(x: outer.minX, y: outer.minY + outer.height * 0.04))
        ctx.addLine(to: CGPoint(x: outer.maxX, y: outer.minY + outer.height * 0.04))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawLabel(_ item: CollageItem, outer: CGRect, ctx: CGContext, dc: DrawContext) {
        let corner = outer.height * 0.12
        ctx.saveGState()
        let px = CGFloat(dc.scale)
        ctx.setShadow(offset: CGSize(width: 0, height: -outer.height * 0.04 * px), blur: outer.height * 0.14 * px,
                      color: CGColor(gray: 0, alpha: 0.2))
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(item.color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        let raw = item.label.isEmpty ? "{date}" : item.label
        let ink = item.color.luminance > 0.5 ? CollageColor(hex: 0x2B2926) : CollageColor.paper
        let sizeRel = Double(outer.height) * 0.42 / dc.canvas.shortSide
        let t = CollageText(lines: [CollageTextLine(raw, font: .typewriter, weight: .regular, size: sizeRel,
                                                    tracking: 0.12, color: ink)],
                            vertical: false, alignH: .center, alignV: .center)
        CollageTypeset.draw(t, in: outer.insetBy(dx: outer.height * 0.3, dy: outer.height * 0.12), ctx: ctx,
                            short: dc.canvas.shortSide, vars: dc.vars, canvasHeight: dc.canvasHeight)
    }

    /// 邮戳：左边双圈 + 日期，右边几道波浪注销线。
    private static func drawPostmark(_ item: CollageItem, outer: CGRect, ctx: CGContext, dc: DrawContext) {
        let d = min(outer.height, outer.width * 0.62)
        let circle = CGRect(x: outer.minX, y: outer.midY - d / 2, width: d, height: d)
        let lw = d * 0.035
        let ink = item.color.cgColor(alpha: 0.78)
        ctx.saveGState()
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(lw)
        ctx.strokeEllipse(in: circle.insetBy(dx: lw, dy: lw))
        ctx.setLineWidth(lw * 0.6)
        ctx.strokeEllipse(in: circle.insetBy(dx: d * 0.11, dy: d * 0.11))
        // 波浪线
        let waveX0 = circle.maxX + d * 0.04
        let waveX1 = outer.maxX
        if waveX1 - waveX0 > d * 0.2 {
            ctx.setLineWidth(lw * 0.8)
            for k in 0..<4 {
                let y = circle.minY + d * (0.27 + 0.155 * CGFloat(k))
                let amp = d * 0.035
                let period = d * 0.22
                ctx.move(to: CGPoint(x: waveX0, y: y))
                var x = waveX0
                while x < waveX1 {
                    let x1 = min(waveX1, x + period / 2)
                    let up = Int(((x - waveX0) / (period / 2)).rounded()) % 2 == 0
                    ctx.addQuadCurve(to: CGPoint(x: x1, y: y),
                                     control: CGPoint(x: (x + x1) / 2, y: y + (up ? -amp * 2 : amp * 2)))
                    x = x1
                }
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
        let inkColor = CollageColor(r: item.color.r, g: item.color.g, b: item.color.b)
        let raw = item.label.isEmpty ? "{date}" : item.label
        let shortSide = dc.canvas.shortSide
        let t = CollageText(lines: [
            CollageTextLine("POST", font: .typewriter, weight: .bold, size: Double(d) * 0.1 / shortSide,
                            tracking: 0.3, color: inkColor),
            CollageTextLine(raw, font: .typewriter, weight: .bold, size: Double(d) * 0.115 / shortSide,
                            tracking: 0.04, color: inkColor),
        ], vertical: false, alignH: .center, alignV: .center)
        ctx.saveGState()
        ctx.setAlpha(0.8)
        CollageTypeset.draw(t, in: circle.insetBy(dx: d * 0.2, dy: d * 0.24), ctx: ctx, short: shortSide,
                            vars: dc.vars, canvasHeight: dc.canvasHeight)
        ctx.restoreGState()
    }

    /// 回形针：两道同心圆角环，一道暗、一道高光。
    private static func drawClip(_ item: CollageItem, outer: CGRect, ctx: CGContext, px: CGFloat) {
        let w = outer.width
        let lw = w * 0.13
        let outerLoop = outer.insetBy(dx: lw / 2, dy: lw / 2)
        let innerLoop = CGRect(x: outer.minX + w * 0.27, y: outer.minY + outer.height * 0.2,
                               width: w * 0.46, height: outer.height * 0.66)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -lw * 0.4 * px), blur: lw * 1.2 * px, color: CGColor(gray: 0, alpha: 0.3))
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(item.color.cgColor)
        ctx.addPath(CGPath(roundedRect: outerLoop, cornerWidth: outerLoop.width / 2, cornerHeight: outerLoop.width / 2, transform: nil))
        ctx.addPath(CGPath(roundedRect: innerLoop, cornerWidth: innerLoop.width / 2, cornerHeight: innerLoop.width / 2, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setLineWidth(lw * 0.3)
        ctx.setStrokeColor(item.color.mixed(with: .white, 0.6).cgColor(alpha: 0.8))
        ctx.addPath(CGPath(roundedRect: outerLoop.offsetBy(dx: -lw * 0.18, dy: 0), cornerWidth: outerLoop.width / 2,
                           cornerHeight: outerLoop.width / 2, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - 人脸在成品上的位置（散落版打分、胶带避脸）

    /// 照片图层上每张人脸框的采样点（成品坐标）。
    static func faceSamples(_ item: CollageItem, canvas: CollageCanvas, photos: [String: CollagePhotoRef],
                            hints: [String: CollageCrop.Hints]) -> [[CGPoint]] {
        guard item.kind == .photo, let id = item.photoID, let photo = photos[id] else { return [] }
        let outer = localRect(item, canvas: canvas)
        let inner = photoArea(item.frame, outer: outer)
        let framing: CollageFraming = item.framing == .auto ? .full : item.framing
        let window = CollageCrop.window(for: photo, cellAspect: CollageCrop.aspect(of: inner), framing: framing,
                                        override: nil, hints: hints[id])
        let t = transform(item, canvas: canvas)
        return CollageCrop.faceBoxes(photo: photo, window: window, in: inner).map { box in
            var pts: [CGPoint] = []
            for i in 0..<4 {
                for j in 0..<4 {
                    let p = CGPoint(x: box.minX + box.width * (CGFloat(i) + 0.5) / 4,
                                    y: box.minY + box.height * (CGFloat(j) + 0.5) / 4)
                    pts.append(p.applying(t))
                }
            }
            return pts
        }
    }
}

// MARK: - 散落版生成

/// 先用切分树求解器排一个疏密合适的网格，再把每格变成一张相纸：放大一点、挪一点、斜一点，
/// 格子之间就自然叠上了。然后检查：谁的脸被上面那张压住、胶带压到脸 —— 扣分或换位置。
enum CollageScatter {

    /// `reserve`：页上已有的横排标题（手写字、网格文字格转来的）占着最上/最下一截，照片让开
    /// （画布高度比例；和模板写死的 reserveBottom 取大的）。
    static func generate(photos: [CollagePhotoRef], spec: CollageScatterSpec, context: CollageLayout.Context,
                         seed: UInt64, keep: Int = 12,
                         reserve: (top: Double, bottom: Double) = (0, 0)) -> [CollageLayout.Scored] {
        guard !photos.isEmpty else { return [] }
        let canvas = context.canvas
        // 外框比例：相纸下沿宽，照片比例太极端的收一收（相纸本来就不是 2:3）。
        var fake: [String: CollagePhotoRef] = [:]
        var outerAspects: [String: Double] = [:]
        for p in photos {
            let inner = min(1.45, max(0.72, p.aspect))
            let outer = CollageItems.outerAspect(inner: inner, frame: spec.frame)
            outerAspects[p.id] = outer
            var f = p
            f.width = 1000
            f.height = max(1, Int((1000 / outer).rounded()))
            fake[p.id] = f
        }
        var style = CollageStyle()
        style.margin = photos.count <= 2 ? 0.1 : 0.075
        style.gutter = 0.03
        style.tightSmallCells = false
        // 上下有标题（模板固定写的字、页上的手写字）：照片的网格只排在中间那一截，最后整体平移回画布坐标。
        let reserveTop: Double = min(0.35, max(0, reserve.top))
        let reserveBottom: Double = min(0.4, max(0, max(spec.reserveBottom, reserve.bottom)))
        let offsetY: Double = Double(canvas.height) * reserveTop
        var gridCanvas = canvas
        gridCanvas.height = max(64, Int((Double(canvas.height) * (1 - reserveTop - reserveBottom)).rounded()))
        // 九宫格的横切线跟着高度变了位置，留了上下就不按它排；中缝、轮播页缝是竖线，照旧避开。
        if reserveTop + reserveBottom > 0, gridCanvas.seams == .grid9 { gridCanvas.seams = .none }
        let gridContext = CollageLayout.Context(canvas: gridCanvas, style: style, photos: fake, hints: [:], heroID: nil)
        let grids = CollageLayout.solve(CollageLayout.Request(photos: photos.compactMap { fake[$0.id] },
                                                              context: gridContext, tries: 4000, keep: 10, seed: seed))
        guard !grids.isEmpty else { return [] }
        let hero = photos.max { $0.score < $1.score }
        var results: [CollageLayout.Scored] = []
        var rng = SeededRandom(seed: seed &* 31 &+ 7)
        for (gi, grid) in grids.enumerated() {
            // 同一个网格撒两次（不同的挪动和倾斜），留好的那次。
            var bestForGrid: CollageLayout.Scored?
            for _ in 0..<3 {
                let frames = CollageLayout.pageGeometry(grid.root, canvas: gridCanvas, style: style).frames
                var items: [CollageItem] = []
                var sign: Double = Bool.random(using: &rng) ? 1 : -1
                for f in frames {
                    guard let id = f.cell.photoID, let outerAspect = outerAspects[id] else { continue }
                    let r = f.rect.cgRect
                    let grow = spec.spread * (0.95 + 0.1 * CollageItems.unit(&rng))
                    var w = Double(r.width) * grow
                    var h = w / outerAspect
                    if h > Double(r.height) * grow {
                        h = Double(r.height) * grow
                        w = h * outerAspect
                    }
                    let jx = (CollageItems.unit(&rng) - 0.5) * 0.11 * Double(r.width)
                    let jy = (CollageItems.unit(&rng) - 0.5) * 0.11 * Double(r.height)
                    var item = CollageItem(kind: .photo)
                    item.photoID = id
                    item.frame = spec.frame
                    item.generated = true
                    item.cx = (Double(r.midX) + jx) / Double(canvas.width)
                    item.cy = (offsetY + Double(r.midY) + jy) / Double(canvas.height)
                    item.width = w / canvas.shortSide
                    item.height = h / canvas.shortSide
                    let tilt = spec.tilt * (0.35 + 0.65 * CollageItems.unit(&rng))
                    item.rotation = sign * tilt
                    sign = -sign
                    item.shadow = 0.55
                    if id == hero?.id {
                        item.role = .hero
                        if spec.frame == .polaroid { item.caption = spec.caption }
                    }
                    items.append(item)
                }
                // 叠放顺序：随机，主图压在最上面。
                items.shuffle(using: &rng)
                if let heroIndex = items.firstIndex(where: { $0.role == .hero }) {
                    let h = items.remove(at: heroIndex)
                    items.append(h)
                }
                items = keepInside(items, canvas: canvas)
                items = relieve(items, canvas: canvas, photos: context.photos, hints: context.hints)
                items = clearOfFold(keepInside(items, canvas: canvas), canvas: canvas)
                items = withTapes(items, spec: spec, canvas: canvas, photos: context.photos, hints: context.hints,
                                  rng: &rng)
                let s = score(items, canvas: canvas, photos: context.photos, hints: context.hints)
                let scored = CollageLayout.Scored(root: .leaf(CollageCell()), score: s.score, m: 1,
                                                  signature: "S" + grid.signature, cutFaces: s.covered,
                                                  seamFaces: s.seam, key: "scatter#\(gi)#\(seed)",
                                                  shapeClass: "S" + grid.shapeClass, items: items)
                if bestForGrid == nil || scored.score < bestForGrid!.score { bestForGrid = scored }
            }
            if let b = bestForGrid { results.append(b) }
        }
        return CollageLayout.diverse(results, keep: keep)
    }

    /// 相纸整张留在画布里、离边至少一小截（放大、挪动、推开压脸之后常常一角伸出画外，胶带也跟着出去）。
    /// 比画布还大的放不下就居中。
    static func keepInside(_ items: [CollageItem], canvas: CollageCanvas) -> [CollageItem] {
        let w = Double(canvas.width)
        let h = Double(canvas.height)
        let edge: Double = canvas.shortSide * 0.022
        func shift(_ lo: Double, _ hi: Double, _ size: Double) -> Double {
            if hi - lo > size - 2 * edge { return size / 2 - (lo + hi) / 2 }
            if lo < edge { return edge - lo }
            if hi > size - edge { return size - edge - hi }
            return 0
        }
        return items.map { it -> CollageItem in
            guard it.kind == .photo else { return it }
            let b = CollageItems.bounds(it, canvas: canvas)
            var out = it
            out.cx += shift(Double(b.minX), Double(b.maxX), w) / w
            out.cy += shift(Double(b.minY), Double(b.maxY), h) / h
            return out
        }
    }

    /// 相册跨页：放大、挪动之后相纸边伸进中缝那一条（装订会吃掉）就往自己那一侧挪出来；
    /// 挪了会出画的不动，整张横跨中缝的交给打分。
    static func clearOfFold(_ items: [CollageItem], canvas: CollageCanvas) -> [CollageItem] {
        guard canvas.seams == .fold else { return items }
        let w = Double(canvas.width)
        let fold: Double = w / 2
        let band: Double = canvas.foldBand
        return items.map { it -> CollageItem in
            guard it.kind == .photo else { return it }
            let b = CollageItems.bounds(it, canvas: canvas)
            let minX = Double(b.minX)
            let maxX = Double(b.maxX)
            guard minX < fold + band, maxX > fold - band else { return it }
            let center: Double = it.cx * w
            var out = it
            if center < fold {
                let dx: Double = maxX - (fold - band)
                guard minX - dx >= 0 else { return it }
                out.cx = (center - dx) / w
            } else {
                let dx: Double = (fold + band) - minX
                guard maxX + dx <= w else { return it }
                out.cx = (center + dx) / w
            }
            return out
        }
    }

    /// 压脸的：把压在上面的那张往外推一点、再不行就把被压的那张提到上面。
    static func relieve(_ input: [CollageItem], canvas: CollageCanvas, photos: [String: CollagePhotoRef],
                        hints: [String: CollageCrop.Hints]) -> [CollageItem] {
        var items = input
        for _ in 0..<4 {
            var changed = false
            for i in items.indices {
                let faces = CollageItems.faceSamples(items[i], canvas: canvas, photos: photos, hints: hints)
                guard !faces.isEmpty else { continue }
                for j in items.indices where j > i {
                    let above = items[j]
                    let hits = faces.flatMap { $0 }.filter { CollageItems.contains(above, point: $0, canvas: canvas) }
                    guard !hits.isEmpty else { continue }
                    // 沿两张中心连线把上面那张推开 3% 短边。
                    let ci = CollageItems.center(items[i], canvas: canvas)
                    let cj = CollageItems.center(above, canvas: canvas)
                    var dx = Double(cj.x - ci.x)
                    var dy = Double(cj.y - ci.y)
                    let len = max(1, (dx * dx + dy * dy).squareRoot())
                    dx /= len
                    dy /= len
                    let push = canvas.shortSide * 0.03
                    items[j].cx += dx * push / Double(canvas.width)
                    items[j].cy += dy * push / Double(canvas.height)
                    changed = true
                }
            }
            if !changed { break }
        }
        // 还压着：被压的挪到上面去（主图除外，主图始终在最上）。
        for i in items.indices.reversed() where items[i].role != .hero {
            let faces = CollageItems.faceSamples(items[i], canvas: canvas, photos: photos, hints: hints).flatMap { $0 }
            guard !faces.isEmpty else { continue }
            let covered = items[(i + 1)...].contains { above in
                faces.contains { CollageItems.contains(above, point: $0, canvas: canvas) }
            }
            if covered {
                let moved = items.remove(at: i)
                let heroAt = items.firstIndex { $0.role == .hero } ?? items.count
                items.insert(moved, at: heroAt)
            }
        }
        return items
    }

    /// 相纸下沿写了字的那一条（成品坐标采样点）：胶带不能贴在字上。
    static func captionSamples(_ item: CollageItem, canvas: CollageCanvas) -> [CGPoint] {
        guard item.kind == .photo, item.frame == .polaroid, !item.caption.isEmpty else { return [] }
        let outer = CollageItems.localRect(item, canvas: canvas)
        let inner = CollageItems.photoArea(.polaroid, outer: outer)
        let t = CollageItems.transform(item, canvas: canvas)
        var pts: [CGPoint] = []
        for i in 0..<6 {
            for j in 0..<2 {
                let x = inner.minX + inner.width * (0.15 + 0.7 * CGFloat(i) / 5)
                let y = inner.maxY + (outer.maxY - inner.maxY) * (0.3 + 0.4 * CGFloat(j))
                pts.append(CGPoint(x: x, y: y).applying(t))
            }
        }
        return pts
    }

    /// 每张照片的胶带紧跟在它后面（叠放顺序里就在它上面一层，被更上面的照片压住才真实）；
    /// 完全被上面照片盖住的胶带不要。
    static func withTapes(_ items: [CollageItem], spec: CollageScatterSpec, canvas: CollageCanvas,
                          photos: [String: CollagePhotoRef], hints: [String: CollageCrop.Hints],
                          rng: inout SeededRandom) -> [CollageItem] {
        let byItem = tapes(for: items, spec: spec, canvas: canvas, photos: photos, hints: hints, rng: &rng)
        var out: [CollageItem] = []
        for (i, item) in items.enumerated() {
            out.append(item)
            for tape in byItem[item.id] ?? [] {
                let c = CollageItems.center(tape, canvas: canvas)
                let hidden = items[(i + 1)...].contains { $0.kind == .photo && CollageItems.contains($0, point: c, canvas: canvas) }
                if !hidden { out.append(tape) }
            }
        }
        return out
    }

    /// 胶带：顶边正中一条，或两个上角各斜贴一条；压到任何人的脸、相纸上的字就换到底边，还压就不贴。
    static func tapes(for items: [CollageItem], spec: CollageScatterSpec, canvas: CollageCanvas,
                      photos: [String: CollagePhotoRef], hints: [String: CollageCrop.Hints],
                      rng: inout SeededRandom) -> [UUID: [CollageItem]] {
        guard spec.tape > 0, !spec.tapes.isEmpty else { return [:] }
        let allFaces = items.flatMap { CollageItems.faceSamples($0, canvas: canvas, photos: photos, hints: hints) }
            .flatMap { $0 } + items.flatMap { captionSamples($0, canvas: canvas) }
        var out: [UUID: [CollageItem]] = [:]
        for item in items where item.kind == .photo {
            let roll = CollageItems.unit(&rng)
            guard roll < spec.tape else { continue }
            let kind = spec.tapes[Int(rng.next() % UInt64(spec.tapes.count))]
            let w = min(0.2, max(0.07, item.width * 0.34))
            let h = w * 0.27
            let corners = rng.next() % 5 < 2
            let t = CollageItems.transform(item, canvas: canvas)
            let half = CollageItems.size(item, canvas: canvas)
            func tape(at local: CGPoint, angle: Double) -> CollageItem {
                let p = local.applying(t)
                var tp = CollageItem(kind: .sticker)
                tp.sticker = kind
                tp.color = kind.defaultColor
                tp.cx = Double(p.x) / Double(canvas.width)
                tp.cy = Double(p.y) / Double(canvas.height)
                tp.width = w
                tp.height = h
                tp.rotation = item.rotation + angle
                tp.generated = true
                tp.attach = CollageItems.attachment(of: tp, to: item, canvas: canvas)
                return tp
            }
            // 不压脸、不压相纸上的字，也不伸出画外（贴在画外的半截胶带像是被裁掉了）。
            let frame = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
            func clear(_ tp: CollageItem) -> Bool {
                frame.contains(CollageItems.bounds(tp, canvas: canvas))
                    && !allFaces.contains { CollageItems.contains(tp, point: $0, canvas: canvas, slop: 2) }
            }
            let jitter = (CollageItems.unit(&rng) - 0.5) * 14
            let cornerA = tape(at: CGPoint(x: -half.width / 2 + CGFloat(w * canvas.shortSide) * 0.2,
                                           y: -half.height / 2 + CGFloat(h * canvas.shortSide) * 0.3), angle: -38 + jitter * 0.3)
            let cornerB = tape(at: CGPoint(x: half.width / 2 - CGFloat(w * canvas.shortSide) * 0.2,
                                           y: -half.height / 2 + CGFloat(h * canvas.shortSide) * 0.3), angle: 38 + jitter * 0.3)
            let top = tape(at: CGPoint(x: 0, y: -half.height / 2), angle: jitter)
            // 两个上角 → 上沿正中 → 不贴（以前退到下沿：只在底边贴一条像是倒挂着）。
            var options: [[CollageItem]] = [[top]]
            if corners { options.insert([cornerA, cornerB], at: 0) } else { options.append([cornerA, cornerB]) }
            if let placed = options.first(where: { $0.allSatisfy(clear) }) { out[item.id] = placed }
        }
        return out
    }

    struct Score {
        var score: Double
        var covered: Int
        var seam: Int
    }

    /// 越低越好：脸被压、脸出画、脸压切缝，照片出画太多，画面空得太多。
    static func score(_ items: [CollageItem], canvas: CollageCanvas, photos: [String: CollagePhotoRef],
                      hints: [String: CollageCrop.Hints]) -> Score {
        var s = 0.0
        var covered = 0
        var seam = 0
        let trim = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let safe = trim.insetBy(dx: CGFloat(max(canvas.safe, 0)), dy: CGFloat(max(canvas.safe, 0)))
        let seams = CollageLayout.seamLines(canvas)
        for (i, item) in items.enumerated() where item.kind == .photo {
            for face in CollageItems.faceSamples(item, canvas: canvas, photos: photos, hints: hints) {
                let hidden = face.filter { p in
                    items[(i + 1)...].contains { CollageItems.contains($0, point: p, canvas: canvas) }
                }.count
                if hidden > 0 {
                    s += 8 * Double(hidden) / Double(face.count) + 2
                    covered += 1
                }
                let outside = face.filter { !safe.contains($0) }.count
                s += 6 * Double(outside) / Double(face.count)
                if seams.contains(where: { band in face.contains { band.contains($0) } }) {
                    s += 3
                    seam += 1
                }
            }
            // 照片出画：外接框在成品外的比例超过一成开始扣。
            let b = CollageItems.bounds(item, canvas: canvas)
            let inside = b.intersection(trim)
            let area = max(1, Double(b.width * b.height))
            let insideArea = inside.isNull ? 0 : Double(inside.width * inside.height)
            let out = 1 - insideArea / area
            if out > 0.1 { s += 4 * (out - 0.1) }
            // 相册：照片横跨中缝会被书脊吃掉一条（胶装根本不许跨，扣得重）。
            if canvas.seams == .fold {
                let fold = Double(canvas.width) / 2
                let band = canvas.foldBand
                let penalty: Double = canvas.allowsCrossFold ? 1.5 : 6
                if Double(b.minX) < fold - band, Double(b.maxX) > fold + band { s += penalty }
            }
        }
        // 大小悬殊：一张特别大、旁边一溜缩略图那么小的，撒出来不像一桌照片（最小的不到中位数一半、
        // 最大的超过中位数 2.6 倍开始扣）。
        let areas = items.filter { $0.kind == .photo }.map { $0.width * $0.height }.sorted()
        if areas.count >= 3 {
            let median = areas[areas.count / 2]
            s += 6 * max(0, 0.5 - areas[0] / max(1e-9, median))
            s += 1.5 * max(0, (areas[areas.count - 1] / max(1e-9, median)) - 2.6)
        }
        // 空处：画布上 12×12 个点有多少没被任何照片盖住。
        let n = 12
        var empty = 0
        let photoItems = items.filter { $0.kind == .photo }
        for gy in 0..<n {
            for gx in 0..<n {
                let p = CGPoint(x: (Double(gx) + 0.5) / Double(n) * Double(canvas.width),
                                y: (Double(gy) + 0.5) / Double(n) * Double(canvas.height))
                if !photoItems.contains(where: { CollageItems.contains($0, point: p, canvas: canvas) }) { empty += 1 }
            }
        }
        let emptyFrac = Double(empty) / Double(n * n)
        s += 2.5 * max(0, emptyFrac - 0.18)
        return Score(score: s, covered: covered, seam: seam)
    }

    /// 页上横排的字（手写标题、网格文字格转来的）占着最上或最下一截：撒照片时让开这一截，
    /// 不然照片会压在标题上。窄的（竖排、角落小字）不算。返回画布高度比例。
    static func reserveBands(for items: [CollageItem], canvas: CollageCanvas) -> (top: Double, bottom: Double) {
        let w = Double(canvas.width)
        let h = Double(max(1, canvas.height))
        let gap: Double = canvas.shortSide * 0.015
        var top = 0.0
        var bottom = 0.0
        for it in items where it.kind == .text {
            let b = CollageItems.bounds(it, canvas: canvas)
            guard Double(b.width) >= 0.3 * w else { continue }
            if Double(b.maxY) <= 0.35 * h {
                top = max(top, (Double(b.maxY) + gap) / h)
            } else if Double(b.minY) >= 0.65 * h {
                bottom = max(bottom, (h - Double(b.minY) + gap) / h)
            }
        }
        return (min(0.35, top), min(0.35, bottom))
    }

    /// 换一批（散落）：新撒的相纸和胶带 + 留下来的手写字、手动加的贴纸。贴在相纸上的手动贴纸换到
    /// 同一张照片的新相纸上，叠放顺序紧跟在那一组后面；那张照片这次没上版，贴纸也不要了。
    static func merge(fresh: [CollageItem], kept: [CollageItem], old: [CollageItem],
                      canvas: CollageCanvas) -> [CollageItem] {
        var photoOfOld: [UUID: String] = [:]
        for it in old where it.kind == .photo {
            if let p = it.photoID { photoOfOld[it.id] = p }
        }
        var freshByPhoto: [String: UUID] = [:]
        for it in fresh where it.kind == .photo {
            if let p = it.photoID, freshByPhoto[p] == nil { freshByPhoto[p] = it.id }
        }
        // 手动贴过胶带的照片：新撒的自动胶带不要了（两条叠在同一个上沿）。
        var hasManualTape = Set<UUID>()
        for it in kept where it.kind == .sticker && it.sticker.isTape {
            if let a = it.attach, let pid = photoOfOld[a.to], let target = freshByPhoto[pid] { hasManualTape.insert(target) }
        }
        var out = fresh.filter { !($0.generated && $0.kind == .sticker && $0.attach.map { hasManualTape.contains($0.to) } == true) }
        var loose: [CollageItem] = []
        for var it in kept {
            guard let a = it.attach else {
                loose.append(it)
                continue
            }
            guard let pid = photoOfOld[a.to], let target = freshByPhoto[pid] else { continue }
            it.attach?.to = target
            let end = out.lastIndex { $0.id == target || $0.attach?.to == target } ?? (out.count - 1)
            out.insert(it, at: min(out.count, end + 1))
        }
        return CollageItems.pinAll(out + loose, canvas: canvas)
    }
}
