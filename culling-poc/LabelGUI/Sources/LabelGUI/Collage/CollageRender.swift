import Foundation
import AppKit
import CoreGraphics
import CoreImage
import ImageIO

/// 解码：按需要的长边从原图（或 1024 预览）解一张转正后的图。预览渲染走缓存，
/// 导出的大解码不进缓存（一张 40MP 的 5000px 解码 ~100MB）。
enum CollageImages {
    static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 64
        c.totalCostLimit = ThumbCache.budget(fraction: 0.04, cap: 500_000_000)
        return c
    }()

    /// 长边按 256 取整：拖缝时格子大小一直在变，不能每个像素都重解一次。
    static func bucket(_ pixels: Int) -> Int { max(256, Int((Double(pixels) / 256).rounded(.up)) * 256) }

    static func decode(path: String, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// 预览用：需要的不超过 1024 就解预览文件，否则解原图；都进缓存。
    static func preview(_ photo: CollagePhotoRef, need: Int) -> CGImage? {
        let fullLong = max(photo.width, photo.height)
        let wanted = min(bucket(need), max(256, fullLong))
        let usePreview = wanted <= ImageLoader.previewMaxPixel && photo.previewPath != nil
        let path = usePreview ? photo.quickPath : photo.path
        let key = "\(path)#\(wanted)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = decode(path: path, maxPixel: wanted) ?? decode(path: photo.path, maxPixel: wanted) else { return nil }
        cache.setObject(image, forKey: key, cost: image.width * image.height * 4)
        return image
    }

    /// 导出用：原图按需解，不缓存。
    static func full(_ photo: CollagePhotoRef, need: Int) -> CGImage? {
        let fullLong = max(photo.width, photo.height)
        return decode(path: photo.path, maxPixel: min(max(256, need), max(256, fullLong)))
    }
}

enum CollageRender {

    struct Options {
        /// 1 = 成品像素；界面预览 < 1。
        var scale: Double = 1
        /// 印刷导出带出血；界面预览不带。
        var includeBleed = true
        /// 叠人脸框/安全区/路人/切缝（CLI --debug）。
        var debug = false
        /// 编辑器参考线：安全区、中缝、九宫格/轮播切线。不会出现在导出里。
        var guides = false
        /// 空格子画虚线占位。
        var placeholders = false
        /// true = 导出（原图解码不走缓存）。
        var export = false
        /// 导出时收集读不了原图的照片（用了预览图 / 整格空着），导出结束要报出来。
        var report: RenderReport?

        init(scale: Double = 1) { self.scale = scale }
    }

    /// 一次渲染里出的问题。每次渲染自己一个，不跨线程共享。
    final class RenderReport {
        /// 原图读不了、退回 1024 预览（印刷会糊）。
        var lowRes: [String] = []
        /// 连预览都读不了，格子空着。
        var missing: [String] = []
    }

    static let ciContext = CIContext(options: [.cacheIntermediates: false])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - 主入口

    static func render(root: CollageNode, project: CollageProject, hints: [String: CollageCrop.Hints],
                       options: Options) -> CGImage? {
        render(page: CollagePage(root: root), project: project, hints: hints, options: options)
    }

    static func render(page: CollagePage, project: CollageProject, hints: [String: CollageCrop.Hints],
                       options: Options) -> CGImage? {
        let root = page.root
        let canvas = project.canvas
        let style = project.style
        let scale = options.scale
        let bleed = options.includeBleed ? Int((Double(canvas.bleed) * scale).rounded()) : 0
        let trimW = Int((Double(canvas.width) * scale).rounded())
        let trimH = Int((Double(canvas.height) * scale).rounded())
        let fullW = trimW + bleed * 2
        let fullH = trimH + bleed * 2
        guard fullW > 0, fullH > 0, let ctx = makeContext(width: fullW, height: fullH) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(fullH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        let short = canvas.shortSide * scale
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        let pagePhotoIDs = page.photoIDs

        let bg = backgroundColor(project: project, pagePhotoIDs: pagePhotoIDs, photos: photos)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: fullW, height: fullH))
        if style.grain > 0 {
            drawGrain(ctx, width: fullW, height: fullH, intensity: style.grain, scale: scale)
        }

        var content = CollageLayout.contentRect(canvas: canvas, style: style, scale: scale)
        content = offset(content, bleed)
        let gutter = CollageLayout.gutterPixels(canvas: canvas, style: style, scale: scale)
        let geo = CollageLayout.geometry(root, in: content, gutter: gutter)
        // 自动景别、压字位置都按成品尺寸的几何判（缩略图里整数面积四舍五入会让半身/全身翻转）。
        let framingFrames = CollageLayout.geometry(root, in: CollageLayout.contentRect(canvas: canvas, style: style),
                                                   gutter: CollageLayout.gutterPixels(canvas: canvas, style: style)).frames
        let trim = CollageLayout.IntRect(x0: bleed, y0: bleed, x1: bleed + trimW, y1: bleed + trimH)
        let fullBleed = bleed > 0 && style.margin <= 0.0001
        let vars = CollageTypeset.variables(project: project, root: root, photos: photos, pagePhotoIDs: pagePhotoIDs,
                                            pageID: page.id)
        let sharpenRadius = canvas.dpi >= 200 ? 1.3 * scale : 0.8
        let colorOps = CollageLooks.ops(style: style, pagePhotoIDs: pagePhotoIDs, photos: photos)

        if !page.freeform {
            for frame in geo.frames {
                guard !frame.rect.isEmpty else { continue }
                let rect = frame.rect.cgRect
                switch frame.cell.kind {
                case .photo:
                    let unscaled = framingFrames.first { $0.path == frame.path }
                    guard let id = frame.cell.photoID, let photo = photos[id] else {
                        // 空格子：预览画占位（压字也画上，提醒这里有字），导出不印孤零零的一行字。
                        if options.placeholders { drawPlaceholder(ctx, rect: rect, short: short, dark: bg.luminance < 0.4) }
                        if let overlay = frame.cell.overlay, let unscaled, options.placeholders {
                            drawOverlay(overlay, cell: frame.cell, unscaled: unscaled, ctx: ctx, project: project,
                                        photo: nil, framing: .auto, hints: nil, vars: vars, background: bg,
                                        scale: scale, bleed: bleed, canvasHeight: fullH)
                        }
                        continue
                    }
                    let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: framingFrames,
                                                                 photos: photos, tight: style.tightSmallCells)
                    // 零边距印刷：只有普通矩形照片格铺进出血；文字、月洞门/拱窗、带框的格子不动。
                    let extend = fullBleed && canBleed(frame.cell, style: style)
                        ? bleedEdges(rect, trim: trim.cgRect, bleed: CGFloat(bleed)) : nil
                    drawPhoto(ctx, cell: frame.cell, rect: rect, photo: photo, framing: framing, style: style,
                              short: short, hints: hints[id], background: bg, sharpenRadius: sharpenRadius,
                              options: options, extend: extend, color: colorOps[id])
                    if let overlay = frame.cell.overlay, let unscaled {
                        drawOverlay(overlay, cell: frame.cell, unscaled: unscaled, ctx: ctx, project: project,
                                    photo: photo, framing: framing, hints: hints[id], vars: vars, background: bg,
                                    scale: scale, bleed: bleed, canvasHeight: fullH)
                    }
                case .text:
                    if let text = frame.cell.text {
                        // 印刷：文字格贴着成品边时退进安全区（裁切有 ±1mm 误差，字贴边会被切掉）。
                        let safe = CGFloat(Double(canvas.safe) * scale)
                        let area = safe > 0 ? insetFromTrim(rect, trim: trim.cgRect, by: safe) : rect
                        CollageTypeset.draw(text, in: area, ctx: ctx, short: short, vars: vars, canvasHeight: fullH)
                    }
                case .empty:
                    // 留白格是版式的一部分（错落、电影黑边），不画「待放照片」的虚线框。
                    break
                }
            }
        }

        if !page.items.isEmpty {
            let dc = CollageItems.DrawContext(canvas: canvas, scale: scale, bleed: Double(bleed), photos: photos,
                                              hints: hints, colorOps: colorOps, vars: vars, options: options,
                                              sharpenRadius: sharpenRadius, sharpen: style.sharpen, canvasHeight: fullH)
            CollageItems.draw(page.items, ctx: ctx, dc: dc)
        }

        if options.guides {
            drawGuides(ctx, canvas: canvas, scale: scale, trim: trim.cgRect, bleed: bleed)
        }
        if options.debug {
            drawDebug(ctx, geo: page.freeform ? CollageLayout.Geometry() : geo, framingFrames: framingFrames,
                      photos: photos, hints: hints, style: style, canvas: canvas, scale: scale, trim: trim.cgRect,
                      bleed: bleed)
        }
        return ctx.makeImage()
    }

    // MARK: - 压字

    /// 压字的位置按成品尺寸（unscaled 那一格）算，再按缩放映射到这次渲染。
    static func overlayPlacement(_ overlay: CollageOverlay, cell: CollageCell, frameRect: CGRect,
                                 project: CollageProject, photo: CollagePhotoRef?, framing: CollageFraming,
                                 hints: CollageCrop.Hints?, vars: [String: String],
                                 background: CollageColor) -> CollageOverlays.Placement? {
        let g = overlayGeometry(cell: cell, frameRect: frameRect, style: project.style, photo: photo,
                                framing: framing, hints: hints)
        return CollageOverlays.place(overlay, area: g.textArea, drawn: g.drawn, canvas: project.canvas, photo: photo,
                                     window: g.window, hints: hints, vars: vars, background: background,
                                     look: project.style.look, lookStrength: project.style.lookStrength)
    }

    /// 压字的几何：字能放的范围、照片实际画在哪、取景窗口。渲染器和画布上的拖字、虚线框共用这一个函数。
    struct OverlayGeometry {
        var textArea: CGRect
        var drawn: CGRect
        var window: CollageCrop.Window?
    }

    /// 字能放的范围 = 形状里面最大的矩形 ∩ 照片实际画出来的区域。形状裁在哪和 drawPhoto 一样：
    /// 有边框裁外框，没边框裁照片实际画的区域（「完整显示」时比格子小 —— 以前按整格算，字会跑到圆外）。
    static func overlayGeometry(cell: CollageCell, frameRect: CGRect, style: CollageStyle, photo: CollagePhotoRef?,
                                framing: CollageFraming, hints: CollageCrop.Hints?) -> OverlayGeometry {
        let area = CollageCrop.photoArea(cell: cell, rect: frameRect, style: style)
        var window: CollageCrop.Window?
        var drawn = area
        if let photo {
            let w = CollageCrop.window(for: photo, cell: cell, cellAspect: CollageCrop.aspect(of: area),
                                       framing: framing, hints: hints)
            window = w
            drawn = CollageCrop.drawnRect(window: w, photo: photo, cell: cell, in: area)
        }
        let shape = cell.shape ?? style.shape
        let framed = CollageCrop.isFramed(cell: cell, style: style)
        let shapeRect = framed ? CollageCrop.outerArea(cell: cell, rect: frameRect, style: style) : drawn
        let inside = inscribed(shapeRect, shape: shape)
        var textArea = inside.intersection(drawn)
        if textArea.isNull || textArea.width < 8 || textArea.height < 8 { textArea = inside }
        return OverlayGeometry(textArea: textArea, drawn: drawn, window: window)
    }

    /// 形状里面最大的轴对齐矩形（和 shapePath 同一套几何）。
    static func inscribed(_ rect: CGRect, shape: CollageShape) -> CGRect {
        switch shape {
        case .circle:
            let k: CGFloat = 1 - 1 / CGFloat(2).squareRoot()
            let d = min(rect.width, rect.height)
            let inset = d * k / 2
            let square = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
            return square.insetBy(dx: inset, dy: inset)
        case .arch:
            // 拱顶两角是半径 r 的圆弧：顶边往下 t，两边就得往里收 r − √(r² − (r − t)²)。
            // 在 t ∈ [0, r] 里挑面积最大的那个（以前只把顶边往下挪、两边不收，上面两个角在拱外面）。
            let r = min(rect.width / 2, rect.height)
            var best = CGRect(x: rect.minX, y: rect.minY + r, width: rect.width, height: max(1, rect.height - r))
            var bestArea: CGFloat = best.width * best.height
            for i in 0..<16 {
                let t = r * CGFloat(i) / 16
                let dy = r - t
                let inset = r - max(0, r * r - dy * dy).squareRoot()
                let w = rect.width - 2 * inset
                let h = rect.height - t
                guard w > 1, h > 1, w * h > bestArea else { continue }
                bestArea = w * h
                best = CGRect(x: rect.minX + inset, y: rect.minY + t, width: w, height: h)
            }
            return best
        case .rect, .rounded:
            return rect
        }
    }

    private static func drawOverlay(_ overlay: CollageOverlay, cell: CollageCell, unscaled: CollageLayout.Frame,
                                    ctx: CGContext, project: CollageProject, photo: CollagePhotoRef?,
                                    framing: CollageFraming, hints: CollageCrop.Hints?, vars: [String: String],
                                    background: CollageColor, scale: Double, bleed: Int, canvasHeight: Int) {
        guard let p = overlayPlacement(overlay, cell: cell, frameRect: unscaled.rect.cgRect, project: project,
                                       photo: photo, framing: framing, hints: hints, vars: vars,
                                       background: background) else { return }
        let s = CGFloat(scale)
        let rect = CGRect(x: p.rect.minX * s + CGFloat(bleed), y: p.rect.minY * s + CGFloat(bleed),
                          width: p.rect.width * s, height: p.rect.height * s)
        // 底下太花、反差不够（栏杆石雕、屋檐）：字后面先垫一块羽化的雾面，深字衬白、浅字衬黑；
        // 干净的天空上 halo = 0，什么都不垫。「衬底」滑杆管它的深浅，拖到 0 就不垫。只垫在照片上
        // （剪到照片实际画的区域和形状里），不漫到缝和边距上。
        if overlay.shadow > 0, p.halo > 0.05 {
            let g = overlayGeometry(cell: cell, frameRect: unscaled.rect.cgRect, style: project.style, photo: photo,
                                    framing: framing, hints: hints)
            let drawn = CGRect(x: g.drawn.minX * s + CGFloat(bleed), y: g.drawn.minY * s + CGFloat(bleed),
                               width: g.drawn.width * s, height: g.drawn.height * s)
            let corner = CGFloat(project.style.corner * project.canvas.shortSide * scale)
            ctx.saveGState()
            ctx.addPath(shapePath(cell.shape ?? project.style.shape, rect: drawn, corner: corner))
            ctx.clip()
            drawScrim(ctx, around: rect, light: p.light, strength: p.halo * overlay.shadow / 0.45)
            ctx.restoreGState()
        }
        ctx.saveGState()
        if p.light, overlay.shadow > 0 {
            let k = CGFloat(overlay.shadow)
            let short = CGFloat(project.canvas.shortSide * scale)
            ctx.setShadow(offset: CGSize(width: 0, height: -short * 0.0015 * k), blur: short * 0.012 * k,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55 * Double(k)))
            // 整块字画完再落一次投影：逐行（竖排逐字）各投各的，后一行的影子会压到前一行的字上。
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            CollageTypeset.drawFitted(p.text, in: rect, ctx: ctx, short: p.short * scale, vars: vars,
                                      canvasHeight: canvasHeight)
            ctx.endTransparencyLayer()
        } else {
            CollageTypeset.drawFitted(p.text, in: rect, ctx: ctx, short: p.short * scale, vars: vars,
                                      canvasHeight: canvasHeight)
        }
        ctx.restoreGState()
    }

    /// 字后面的羽化雾面：一层层由外往里叠，中心最实、边缘渐隐（不用模糊滤镜：预览、导出同一套几何，
    /// 缩放多少都一样）。strength 0…1+，深字衬白最多六成、浅字衬黑最多四成。
    private static func drawScrim(_ ctx: CGContext, around rect: CGRect, light: Bool, strength: Double) {
        let peak: Double = light ? min(0.42, 0.6 * strength) : min(0.62, 0.85 * strength)
        guard peak > 0.01, rect.width > 1, rect.height > 1 else { return }
        let pad: CGFloat = min(rect.width, rect.height) * 0.18 + 1
        let feather: CGFloat = min(rect.width, rect.height) * 0.55 + 2
        let steps = 14
        let layer: Double = 1 - pow(1 - peak, 1 / Double(steps))
        ctx.saveGState()
        ctx.setFillColor(light ? CGColor(gray: 0, alpha: layer) : CGColor(gray: 1, alpha: layer))
        for i in 0..<steps {
            let grow: CGFloat = pad + feather * CGFloat(steps - 1 - i) / CGFloat(steps)
            let r = rect.insetBy(dx: -grow, dy: -grow)
            let corner: CGFloat = min(r.width, r.height) * 0.45
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: - 照片格

    private static func drawPhoto(_ ctx: CGContext, cell: CollageCell, rect: CGRect, photo: CollagePhotoRef,
                                  framing: CollageFraming, style: CollageStyle, short: Double,
                                  hints: CollageCrop.Hints?, background: CollageColor, sharpenRadius: Double,
                                  options: Options, extend: Edges?, color: CollageLooks.Ops?) {
        let shape = cell.shape ?? style.shape
        let outer = CollageCrop.outerArea(cell: cell, rect: rect, style: style)
        let framed = CollageCrop.isFramed(cell: cell, style: style)
        let inner = CollageCrop.photoArea(cell: cell, rect: rect, style: style)
        guard inner.width >= 2, inner.height >= 2 else { return }

        var window = CollageCrop.window(for: photo, cell: cell, cellAspect: CollageCrop.aspect(of: inner),
                                        framing: framing, hints: hints)
        var drawn = CollageCrop.drawnRect(window: window, photo: photo, cell: cell, in: inner).integral
        // 铺出血：取景仍按成品区算（和预览一致），再按比例往出血那边外延；照片那边没余量了
        // 就按外延后的比例重新取景（总比拉伸强）。
        if let e = extend, !cell.contain {
            let grown = CGRect(x: drawn.minX - e.left, y: drawn.minY - e.top,
                               width: drawn.width + e.left + e.right, height: drawn.height + e.top + e.bottom)
            let sx = window.w / Double(max(1, drawn.width))
            let sy = window.h / Double(max(1, drawn.height))
            var w2 = window
            w2.x = window.x - Double(e.left) * sx
            w2.y = window.y - Double(e.top) * sy
            w2.w = window.w + Double(e.left + e.right) * sx
            w2.h = window.h + Double(e.top + e.bottom) * sy
            let fits = w2.x >= -1e-6 && w2.y >= -1e-6 && w2.x + w2.w <= 1 + 1e-6 && w2.y + w2.h <= 1 + 1e-6
            window = fits ? w2 : CollageCrop.window(for: photo, cell: cell, cellAspect: CollageCrop.aspect(of: grown),
                                                    framing: framing, hints: hints)
            drawn = grown.integral
        }
        let corner = CGFloat(style.corner * short)
        let outerPath = shapePath(shape, rect: framed ? outer : drawn, corner: corner)

        // 投影：先用底色/边框色把形状填一遍带阴影，照片再盖上去。CG 的阴影偏移在设备空间
        // （y 朝上），不跟翻转的 CTM 走：往下落要给负值。
        if style.shadow > 0 {
            let s = CGFloat(style.shadow)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(short) * 0.006 * s),
                          blur: CGFloat(short) * 0.022 * s,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.38 * Double(s)))
            ctx.addPath(outerPath)
            ctx.setFillColor(framed ? frameColor(style).cgColor : background.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        if framed {
            ctx.addPath(outerPath)
            ctx.setFillColor(frameColor(style).cgColor)
            ctx.fillPath()
            if style.border == .film { drawSprockets(ctx, outer: outer, inner: inner, background: background) }
        }

        let pw = max(1, Int(drawn.width.rounded()))
        let ph = max(1, Int(drawn.height.rounded()))
        guard let tile = cellImage(photo: photo, window: window, width: pw, height: ph, sharpen: style.sharpen,
                                   radius: sharpenRadius, export: options.export, report: options.report,
                                   color: color) else { return }
        ctx.saveGState()
        let clip = framed ? CGPath(rect: drawn, transform: nil) : shapePath(shape, rect: drawn, corner: corner)
        ctx.addPath(clip)
        ctx.clip()
        drawImageTopLeft(ctx, tile, drawn)
        ctx.restoreGState()

        if style.border == .hairline {
            let lw = max(1, CGFloat(short) / 1400)
            ctx.saveGState()
            ctx.addPath(shapePath(shape, rect: drawn.insetBy(dx: lw / 2, dy: lw / 2), corner: corner))
            ctx.setStrokeColor(style.borderColor.cgColor(alpha: 0.9))
            ctx.setLineWidth(lw)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    struct Edges {
        var left: CGFloat = 0
        var top: CGFloat = 0
        var right: CGFloat = 0
        var bottom: CGFloat = 0
    }

    /// 能铺出血的：普通矩形照片格，没有相纸/胶片框、细线（细线会被裁掉），不是完整显示。
    private static func canBleed(_ cell: CollageCell, style: CollageStyle) -> Bool {
        (cell.shape ?? style.shape) == .rect && style.border == .none && !cell.contain
    }

    /// 贴着成品边（或离得比安全区还近）的那几条边往里收到安全区。
    private static func insetFromTrim(_ rect: CGRect, trim: CGRect, by safe: CGFloat) -> CGRect {
        let minX = max(rect.minX, trim.minX + safe)
        let minY = max(rect.minY, trim.minY + safe)
        let maxX = min(rect.maxX, trim.maxX - safe)
        let maxY = min(rect.maxY, trim.maxY - safe)
        guard maxX > minX, maxY > minY else { return rect }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 贴着成品边的那几条边各往外扩多少（零边距印刷）。
    private static func bleedEdges(_ rect: CGRect, trim: CGRect, bleed: CGFloat) -> Edges? {
        let tol: CGFloat = 1.5
        var e = Edges()
        if abs(rect.minX - trim.minX) < tol { e.left = bleed }
        if abs(rect.minY - trim.minY) < tol { e.top = bleed }
        if abs(rect.maxX - trim.maxX) < tol { e.right = bleed }
        if abs(rect.maxY - trim.maxY) < tol { e.bottom = bleed }
        return (e.left + e.top + e.right + e.bottom) > 0 ? e : nil
    }

    private static func frameColor(_ style: CollageStyle) -> CollageColor {
        style.border == .film ? CollageColor(hex: 0x161514) : style.borderColor
    }

    /// 胶片齿孔：通用样式，不带任何品牌字样。
    private static func drawSprockets(_ ctx: CGContext, outer: CGRect, inner: CGRect, background: CollageColor) {
        let horizontal = outer.width >= outer.height
        let bandThickness = horizontal ? (inner.minY - outer.minY) : (inner.minX - outer.minX)
        let holeShort = bandThickness * 0.42
        let holeLong = holeShort * 1.35
        let length = horizontal ? outer.width : outer.height
        let pitch = holeLong * 2.1
        let count = max(2, Int(length / pitch))
        let startOffset = (length - CGFloat(count) * pitch) / 2 + pitch / 2
        ctx.saveGState()
        ctx.setFillColor(background.mixed(with: .white, 0.25).cgColor(alpha: 0.92))
        for i in 0..<count {
            let along = startOffset + CGFloat(i) * pitch
            for side in 0..<2 {
                let r: CGRect
                if horizontal {
                    let y = side == 0 ? outer.minY + (bandThickness - holeShort) / 2
                                      : outer.maxY - bandThickness + (bandThickness - holeShort) / 2
                    r = CGRect(x: outer.minX + along - holeLong / 2, y: y, width: holeLong, height: holeShort)
                } else {
                    let x = side == 0 ? outer.minX + (bandThickness - holeShort) / 2
                                      : outer.maxX - bandThickness + (bandThickness - holeShort) / 2
                    r = CGRect(x: x, y: outer.minY + along - holeLong / 2, width: holeShort, height: holeLong)
                }
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: holeShort * 0.18, cornerHeight: holeShort * 0.18, transform: nil))
            }
        }
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// 形状路径（左上原点坐标系里也成立：只用切线圆弧，不依赖顺/逆时针）。
    static func shapePath(_ shape: CollageShape, rect: CGRect, corner: CGFloat) -> CGPath {
        switch shape {
        case .rect:
            return CGPath(rect: rect, transform: nil)
        case .rounded:
            let r = min(corner, min(rect.width, rect.height) / 2)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .circle:
            let d = min(rect.width, rect.height)
            return CGPath(ellipseIn: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d), transform: nil)
        case .arch:
            let r = min(rect.width / 2, rect.height)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    // MARK: - 取景：解码 → 裁窗口 → Lanczos → 输出锐化

    /// 需要的解码长边：窗口在解码图上至少要有 width×height 那么多像素。
    static func neededLongEdge(photo: CollagePhotoRef, window: CollageCrop.Window, width: Int, height: Int) -> Int {
        let a = photo.aspect
        let wFrac = max(1e-4, window.w * min(1, a))
        let hFrac = max(1e-4, window.h * min(1, 1 / a))
        let need = max(Double(width) / wFrac, Double(height) / hFrac) * 1.08
        return Int(need.rounded(.up))
    }

    static func cellImage(photo: CollagePhotoRef, window: CollageCrop.Window, width: Int, height: Int,
                          sharpen: Double, radius: Double, export: Bool, report: RenderReport? = nil,
                          color: CollageLooks.Ops? = nil) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let need = neededLongEdge(photo: photo, window: window, width: width, height: height)
        var decoded = export ? CollageImages.full(photo, need: need) : CollageImages.preview(photo, need: need)
        if decoded == nil, export {
            // 原图读不了（卷没挂、机型 RAW 不支持）：退回预览，别在成品里留个窟窿；导出后报出来。
            decoded = CollageImages.preview(photo, need: min(need, ImageLoader.previewMaxPixel))
            if decoded != nil { report?.lowRes.append(photo.id) }
        }
        guard let image = decoded else {
            report?.missing.append(photo.id)
            return nil
        }
        let dw = Double(image.width)
        let dh = Double(image.height)
        let sx = window.x * dw
        let sy = window.y * dh
        let sw = max(1, window.w * dw)
        let sh = max(1, window.h * dh)
        // CoreImage 是左下原点。不先 cropped(to:)：窗口坐标是小数，裁出来最后半个像素半透明，
        // 再 clampedToExtent 会把它抹开 —— 每格上边、右边一条底色细线。整图钳边后平移，
        // Lanczos 输出再裁到目标尺寸，窗口里全是实像素。
        let ciRect = CGRect(x: sx, y: dh - sy - sh, width: sw, height: sh)
        let source = CIImage(cgImage: image).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        let scaleY = Double(height) / sh
        let scaleX = Double(width) / sw
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        lanczos.setValue(source, forKey: kCIInputImageKey)
        lanczos.setValue(scaleY, forKey: kCIInputScaleKey)
        lanczos.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
        guard var output = lanczos.outputImage?.cropped(to: target) else { return nil }
        // 调色在锐化之前（锐化放大的是调完色的边缘）。
        output = CollageLooks.apply(output, ops: color).cropped(to: target)
        if sharpen > 0, let usm = CIFilter(name: "CIUnsharpMask") {
            usm.setValue(output.clampedToExtent(), forKey: kCIInputImageKey)
            usm.setValue(radius, forKey: kCIInputRadiusKey)
            usm.setValue(sharpen, forKey: kCIInputIntensityKey)
            if let sharpened = usm.outputImage?.cropped(to: target) { output = sharpened }
        }
        return ciContext.createCGImage(output, from: target, format: .RGBA8, colorSpace: srgb)
    }

    // MARK: - 背景

    static func backgroundColor(project: CollageProject, pagePhotoIDs ids: [String],
                                photos: [String: CollagePhotoRef]) -> CollageColor {
        let style = project.style
        guard style.backgroundMode == .fromPhoto else { return style.background }
        let hero = ids.compactMap { photos[$0] }.max { $0.score < $1.score }
        guard let hero, let raw = averageColor(hero) else { return style.background }
        // 取的是调色之后的主图颜色（套了黑白，底色不能还带着原图的暖色）。
        let graded = CollageLooks.grade(raw.r, raw.g, raw.b, look: style.look, strength: style.lookStrength)
        let avg = CollageColor(r: graded.0, g: graded.1, b: graded.2)
        // 往纸白靠、压饱和：只要一点点色温呼应，不能把底色染成照片的颜色。
        let grey = (avg.r + avg.g + avg.b) / 3
        let muted = avg.mixed(with: CollageColor(r: grey, g: grey, b: grey), 0.45)
        if style.background.luminance < 0.4 {
            return style.background.mixed(with: muted, 0.22)
        }
        return style.background.mixed(with: muted, 0.16)
    }

    private static let averageLock = NSLock()
    private static var averageCache: [String: CollageColor] = [:]

    /// 主图平均色（按照片缓存：画布上移动鼠标、拖字每一帧都会问到底色）。
    private static func averageColor(_ photo: CollagePhotoRef) -> CollageColor? {
        let key = CollageVision.cacheKey(photo)
        averageLock.lock()
        let hit = averageCache[key]
        averageLock.unlock()
        if let hit { return hit }
        guard let color = computeAverageColor(photo) else { return nil }
        averageLock.lock()
        if averageCache.count > 512 { averageCache.removeAll() }
        averageCache[key] = color
        averageLock.unlock()
        return color
    }

    private static func computeAverageColor(_ photo: CollagePhotoRef) -> CollageColor? {
        guard let image = CollageImages.preview(photo, need: 256) else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        var r = 0.0
        var g = 0.0
        var b = 0.0
        for i in 0..<(side * side) {
            r += Double(pixels[i * 4])
            g += Double(pixels[i * 4 + 1])
            b += Double(pixels[i * 4 + 2])
        }
        let n = Double(side * side) * 255
        return CollageColor(r: r / n, g: g / n, b: b / n)
    }

    /// 纸纹：固定种子的灰噪声小块平铺，柔光叠在底色上（只在格子下面）。
    private static let grainTile: CGImage? = {
        let side = 256
        var rng = SeededRandom(seed: 20260928)
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            let v = UInt8(truncatingIfNeeded: 96 + Int(rng.next() % 64))
            pixels[i * 4] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    /// 纹理颗粒跟着缩放走：预览和导出看到的纸纹粗细一致。
    private static func drawGrain(_ ctx: CGContext, width: Int, height: Int, intensity: Double, scale: Double) {
        guard let tile = grainTile else { return }
        let side = CGFloat(Double(tile.width) * max(0.2, min(1, scale)))
        ctx.saveGState()
        ctx.setBlendMode(.softLight)
        ctx.setAlpha(CGFloat(min(1, max(0, intensity)) * 0.55))
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
        ctx.restoreGState()
    }

    // MARK: - 参考线 / 调试层

    private static func drawPlaceholder(_ ctx: CGContext, rect: CGRect, short: Double, dark: Bool) {
        ctx.saveGState()
        let lw = max(1, CGFloat(short) / 700)
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.35) : CGColor(gray: 0, alpha: 0.25))
        ctx.setLineWidth(lw)
        ctx.setLineDash(phase: 0, lengths: [lw * 6, lw * 4])
        ctx.stroke(rect.insetBy(dx: lw, dy: lw))
        ctx.restoreGState()
    }

    private static func drawGuides(_ ctx: CGContext, canvas: CollageCanvas, scale: Double, trim: CGRect, bleed: Int) {
        ctx.saveGState()
        let lw = max(1, CGFloat(canvas.shortSide * scale) / 900)
        ctx.setLineWidth(lw)
        ctx.setLineDash(phase: 0, lengths: [lw * 5, lw * 4])
        ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.75, blue: 0.9, alpha: 0.8))
        for seam in CollageLayout.seamLines(canvas) {
            let s = seam.applying(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                .offsetBy(dx: CGFloat(bleed), dy: CGFloat(bleed))
            if s.width < s.height {
                ctx.move(to: CGPoint(x: s.midX, y: s.minY))
                ctx.addLine(to: CGPoint(x: s.midX, y: s.maxY))
            } else {
                ctx.move(to: CGPoint(x: s.minX, y: s.midY))
                ctx.addLine(to: CGPoint(x: s.maxX, y: s.midY))
            }
        }
        ctx.strokePath()
        if canvas.safe > 0 {
            let inset = CGFloat(Double(canvas.safe) * scale)
            ctx.setStrokeColor(CGColor(srgbRed: 0.3, green: 0.8, blue: 0.4, alpha: 0.75))
            ctx.stroke(trim.insetBy(dx: inset, dy: inset))
        }
        ctx.restoreGState()
    }

    private static func drawDebug(_ ctx: CGContext, geo: CollageLayout.Geometry, framingFrames: [CollageLayout.Frame],
                                  photos: [String: CollagePhotoRef],
                                  hints: [String: CollageCrop.Hints], style: CollageStyle, canvas: CollageCanvas,
                                  scale: Double, trim: CGRect, bleed: Int) {
        let lw = max(2, CGFloat(canvas.shortSide * scale) / 500)
        ctx.saveGState()
        ctx.setLineWidth(lw)
        let short = canvas.shortSide * scale
        for frame in geo.frames where frame.cell.kind == .photo {
            guard let id = frame.cell.photoID, let photo = photos[id] else { continue }
            let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: framingFrames,
                                                         photos: photos, tight: style.tightSmallCells)
            let inner = CollageCrop.photoArea(cell: frame.cell, rect: frame.rect.cgRect, style: style)
            let window = CollageCrop.window(for: photo, cell: frame.cell, cellAspect: CollageCrop.aspect(of: inner),
                                            framing: framing, hints: hints[id])
            let drawn = CollageCrop.drawnRect(window: window, photo: photo, cell: frame.cell, in: inner)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.15, blue: 0.1, alpha: 1))
            for box in CollageCrop.faceBoxes(photo: photo, window: window, in: drawn) { ctx.stroke(box) }
            if let safe = CollageCrop.safeRegion(photo.faces),
               let r = CollageCrop.project([Double(safe.minX), Double(safe.minY), Double(safe.maxX), Double(safe.maxY)],
                                           window: window, into: drawn) {
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.6, blue: 0, alpha: 0.9))
                ctx.stroke(r.insetBy(dx: -lw, dy: -lw))
            }
            ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 1, alpha: 0.95))
            for b in hints[id]?.bystanders ?? [] {
                if let r = CollageCrop.project(b, window: window, into: drawn) { ctx.stroke(r) }
            }
            if window.cutsFace || window.hitsBystander {
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0.6, alpha: 1))
                ctx.setLineWidth(lw * 2.5)
                ctx.stroke(drawn.insetBy(dx: lw * 1.5, dy: lw * 1.5))
                ctx.setLineWidth(lw)
            }
            let label = "\(frame.path.map(String.init).joined()) \(photo.id) \(framing.label)"
                + (window.cutsFace ? " 切脸" : "") + (window.hitsBystander ? " 路人" : "")
            CollageTypeset.drawLabel(label, at: CGPoint(x: drawn.minX + lw * 2, y: drawn.minY + lw * 2),
                                     size: max(12, short * 0.016), ctx: ctx, canvasHeight: ctx.height)
        }
        // 切缝带
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.9, blue: 1, alpha: 0.28))
        for seam in CollageLayout.seamLines(canvas) {
            let s = seam.applying(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                .offsetBy(dx: CGFloat(bleed), dy: CGFloat(bleed))
            ctx.fill(s)
        }
        if bleed > 0 {
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 0.9))
            ctx.stroke(trim)
        }
        if canvas.safe > 0 {
            let inset = CGFloat(Double(canvas.safe) * scale)
            ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.3, alpha: 0.9))
            ctx.stroke(trim.insetBy(dx: inset, dy: inset))
        }
        ctx.restoreGState()
    }

    // MARK: - 绘制辅助

    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// 在已翻转成左上原点的 context 里画图（CG 的 draw 期望左下原点，局部翻回来）。
    static func drawImageTopLeft(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func offset(_ r: CollageLayout.IntRect, _ d: Int) -> CollageLayout.IntRect {
        CollageLayout.IntRect(x0: r.x0 + d, y0: r.y0 + d, x1: r.x1 + d, y1: r.y1 + d)
    }

}
