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
        // 张数上限只防小图把条目塞满；真正管内存的是下面的字节上限。以前 64 张：模板库、跨页条、大图预览各要一份
        // 不同大小的解码，三十个跨页的相册一刷新就互相挤掉，大图又得回去解原片。
        c.countLimit = 256
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
        /// 画工程里的水印（project.watermark）。默认不画：只有界面预览、导出、命令行 renderclean /
        /// renderexport 打开 —— 缩略图、样张一律不画。
        var watermark = false
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
        /// 这一页画了哪些水印、落在哪（命令行出图核对用；界面预览不收）。
        var marks: [MarkRecord] = []
        /// 每个文字块（压字、文字格、文字图层）和每格照片的取景：.marks.json 的 texts / crops、ops 的 dumptexts。
        var texts: [TextRecord] = []
        var crops: [CropRecord] = []
        /// 用到主体蒙版的格子（人物挡字、封面取景、抠图）：.marks.json 的 masks。
        var masks: [MaskRecord] = []
        /// 加了网的照片（格子、相纸）：实际点距、出没出点（.marks.json 的 halftone）。
        var halftone: [HalftoneRecord] = []
        /// 印样页：每帧的帧号、照片、位置、转没转、记号（.marks.json 的 contactSheet）；别的页 = nil。
        var contactSheet: CollageContact.Record?
    }

    /// 一张照片这次怎么加的网。pitchPx = 这次渲染的实际点距（像素，跟着渲染缩放）；screened = false 是点距
    /// 不到 3 像素、只调了影调没出点（预览缩得小、缩略图）。ink / paper = 实际用的墨色、纸色（hex；纸色没设时
    /// 跟页面底色，深色页上换成纸白）。
    struct HalftoneRecord {
        var owner: String
        var photoID: String
        var screen: String
        var pitchPx: Double
        var screened: Bool
        var angle: Double
        var ink: String
        var paper: String
    }

    /// 一个文字块画在哪、多大、展开成了什么字。rect = 字块外框（成品坐标，未缩放、不含出血）；
    /// 位置、字号都按成品尺寸（1 倍）算 —— 和压字摆位一样，预览、导出记下的是同一组数。
    struct TextRecord {
        /// 格子路径（"01"，根 = "r"）或 "item3"（第几个页上图层）。
        var owner: String
        /// "overlay"（照片上压的字）/ "cell"（文字格）/ "item"（文字图层）。
        var kind: String
        /// "front"（压在照片上）/ "behindSubject"（人物挡字，主体压在字上）。
        var layer = "front"
        var rect: CGRect
        /// 文字图层转过之后字块的四个角（从左上顺时针）；rect 是它们的外接框。
        var corners: [CGPoint]? = nil
        /// 第一行的字体（CollageFont 的 rawValue）、实际字号（成品像素，缩到放得下之后）。
        var font: String
        var size: Double
        /// 展开占位符之后的每一行（空行不画也不记），和每行的实际字号。
        var lines: [String]
        var sizes: [Double]
        var vertical: Bool
        /// 整块转了多少度（0 / 90 / −90）。
        var rotation = 0
        /// 带正文时：正文是 "bars"（灰条）/ "filler"（占位字）/ "text"；没有正文 = nil。
        var body: String? = nil
        /// 要求在人后的字块：遮挡量和决定（CollageCover）；别的 = nil。
        var occlusion: OcclusionRecord? = nil

        /// 正文是灰条或占位字（印刷导出时要提示）。
        var hasFillerBody: Bool { body == "bars" || body == "filler" }
    }

    /// 人物挡字的一块字：被挡掉多少、怎么定的（.marks.json 的 texts[].occlusion）。
    struct OcclusionRecord {
        /// 量了没有（没有蒙版、合影直接退回的没量）。
        var measured: Bool
        var total: Double
        var perLetter: [Double]
        /// 每一行被挡掉多少（第 0 行通常是刊头；期号日期小字被脸挡住时在这里看得见）。
        var perLine: [Double]
        var first: Double
        var last: Double
        var heavy: Int
        /// "behind" / "shifted" / "pulledBack" / "shrunk" / "front"。
        var decision: String
        var requested: String
        var reason: String?
        var limit: Double
        var depth: Double
        var eyesClear: Bool?
        var band: Bool
        var faces: Int
        var headTopSource: String
        /// "masthead"（刊名规矩）/ "total"（装饰大字只管总量）。
        var rule = "masthead"
        /// 退回人前时压着头、挪到了自动位置。
        var moved = false
        /// 主行是第几行（perLine 的下标；别的行是期号日期这种小字，每行单独限）。
        var mainLine = 0
        /// 刊头（封面取景、在人后）：眼睛在主行基线下多远（格高的比例）、是不是远过了 8%。
        var eyeBelow: Double?
        var eyeFar = false
        /// 眼睛远是被什么卡住的（"bottom" 照片下沿 / "top" 头顶上面天不够 / "face" 脸太大）；不远 = nil。
        var eyeClamp: String?
    }

    /// 一格用到的主体蒙版（.marks.json 的 masks）。
    struct MaskRecord {
        var owner: String
        var photoID: String
        var key: String
        var size: [Int]
        var coverage: Double
        var headTop: [Double]
        var instances: Int
        var selected: [Int]
        var cutout: Bool
        var behind: Bool
        /// 主体以外的人（照片坐标框，CollageMasks.Mask.people）：封面字躲开的那些。
        var people: [[Double]] = []
    }

    /// 一格照片这次实际怎么取的景：窗口（归一化照片坐标，铺出血外延之后的）、照片画在哪（成品坐标，
    /// 铺进出血时会超出 0…宽高）、主脸眼线和头顶落在哪一行。
    struct CropRecord {
        var owner: String
        var photoID: String
        /// 生效的景别（自动按格子大小定过之后的）。
        var framing: String
        var window: CGRect
        var drawn: CGRect
        var cutsFace: Bool
        var contain: Bool
        var faces: Int
        /// 主脸眼线：脸框上沿 + 0.42 脸高（和 CollageCrop 取景用的同一个定义）。y = 成品坐标，frac = 在照片画出来那块里的比例。
        var eyeY: Double?
        var eyeFrac: Double?
        /// 头顶：现在是估计（脸框上沿 − 0.3 脸高，同 CollageCrop.safeRegion）。有主体蒙版之后改成实测，source 跟着变。
        var headTopY: Double?
        var headTopFrac: Double?
        var headTopSource = "estimate"
    }

    /// 一个水印块。rect / region 都是成品坐标（未缩放、不含出血）；相纸上的是转过之后的外接框。
    struct MarkRecord {
        /// "photo"（每张照片层）/ "page"（整页层）。
        var layer: String
        /// 格子路径（"01"，根 = "r"）、"item3"、"page"、"tile5"、"left" / "right"。
        var owner: String
        /// "signature" / "text" / "tile"（平铺 = 整块区域）；没画 = nil。
        var kind: String?
        var rect: CGRect?
        /// 这一块水印能用的区域（切带、安全区、形状都处理过之后）。
        var region: CGRect?
        /// 没画的原因（"格子太小" / "签名读不了" / "签名放不下" / "字放不下" / 相纸上的 "压缝" / "出安全区" …）；
        /// "压字冲突未解" = 照画了但躲不开压字。
        var skipped: String?
        /// 核对用的几何：格子 / 相纸外接框 / 整页、照片实际画出来的那块、形状。
        var cell: CGRect?
        var visible: CGRect?
        var shape: String?
        /// 这一格压字的字块（躲让的对象）；同一张照片上第 2 个起的字块在 avoidMore。
        var avoid: CGRect?
        var avoidMore: [CGRect] = []
        /// 字的实际字号（成品像素；只有 kind == "text" 有）。
        var font: Double? = nil
        /// 实际用的深浅："original" / "light" / "dark"（「自动」在这两个里选定之后的结果）；没画 = nil。
        var contrast: String? = nil
        /// 整页层放进了版心外的留白带。
        var inMargin = false
        /// 相纸上的（rect 是转过之后的外接框）：没转之前的大小 —— 签名宽的下限按它核对；
        /// 转过之后的四个角（成品坐标，从左上顺时针）—— 被后画的图层盖住多少按它核对。
        var local: CGSize? = nil
        var corners: [CGPoint]? = nil
    }

    static let ciContext = CIContext(options: [.cacheIntermediates: false])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - 主入口

    static func render(root: CollageNode, project: CollageProject, hints: [String: CollageCrop.Hints],
                       options: Options) -> CGImage? {
        render(page: CollagePage(root: root), project: project, hints: hints, options: options)
    }

    static func render(page: CollagePage, project base: CollageProject, hints: [String: CollageCrop.Hints],
                       options: Options) -> CGImage? {
        // 这一页单独设了色调：换进样式，下面所有读 style.look 的（照片、取色底、压字深浅、水印深浅）都按它。
        let project = CollageLooks.project(base, page: page)
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
        let colorOps = CollageLooks.ops(style: style, pagePhotoIDs: pagePhotoIDs, photos: photos)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: fullW, height: fullH))
        // 照片做底（模糊、渐变）：盖在纯色上、纸纹下面，铺满出血；和照片同一套调色。
        if style.backgroundMode.usesPaperTint, let hero = heroPhoto(pagePhotoIDs, photos: photos) {
            drawBackdrop(ctx, style: style, hero: hero, ops: colorOps[hero.id], width: fullW, height: fullH)
        }
        if style.grain > 0 {
            drawGrain(ctx, width: fullW, height: fullH, intensity: style.grain, scale: scale)
        }

        var content = CollageLayout.contentRect(canvas: canvas, style: style, scale: scale)
        content = offset(content, bleed)
        let gutter = CollageLayout.gutterPixels(canvas: canvas, style: style, scale: scale)
        let geo = CollageLayout.geometry(root, in: content, gutter: gutter,
                                         foldGap: CollageLayout.foldGap(canvas: canvas, style: style, scale: scale))
        // 自动景别、压字位置都按成品尺寸的几何判（缩略图里整数面积四舍五入会让半身/全身翻转）。
        let framingFrames = CollageLayout.pageGeometry(root, canvas: canvas, style: style).frames
        let trim = CollageLayout.IntRect(x0: bleed, y0: bleed, x1: bleed + trimW, y1: bleed + trimH)
        // 零边距印刷：贴着成品边的照片铺进出血。四边边距时哪条边是 0 就那条边铺（bleedEdges 只扩贴边的那几条）。
        let fullBleed = bleed > 0 && (style.insets.map { min($0.top, $0.bottom, $0.inner, $0.outer) <= 0.0001 }
            ?? (style.margin <= 0.0001))
        let vars = CollageTypeset.variables(project: project, root: root, photos: photos, pagePhotoIDs: pagePhotoIDs,
                                            pageID: page.id)
        let sharpenRadius = canvas.dpi >= 200 ? 1.3 * scale : 0.8
        // 照片加网（报纸风）：点距按这次渲染的缩放换成像素；纸色没设就是这一页的底色。没开网点 = nil。
        // 模糊底、渐变底时 bg 只是照片底的平均色（常是一块中灰），照片的白跟它走整张发闷：跟底色块（盖在
        // 照片底上的那层纸色，usesPaperTint）走；纸纹压照片乘的纸色同理。纯色、主图取色的 bg 就是页面上真实的
        // 那一块颜色，照旧。
        let paperBase = style.backgroundMode.usesPaperTint ? style.background : bg
        let screen = CollageScreening.spec(style.halftone, canvas: canvas, scale: scale, background: paperBase)
        let keyline = style.border == .mat ? Keyline(canvas: canvas, scale: scale) : nil
        // 纸纹压在照片上：格子都画完之后一遍，只压在照片画出来的那块（字、人物切图、水印一起压，像印在纸上）。
        var paperClips: [CGPath] = []
        // 工程里的水印（只有预览、导出、命令行出图打开；缩略图、样张 = nil，什么都不画）。整页层先排好
        // （每张照片的水印让着它），页上图层在哪先记下（水印不躲进它们底下）。
        let marks = CollageWatermarks.Painter(project: project, options: options, bleed: bleed) {
            markPaper(project: project, pagePhotoIDs: pagePhotoIDs, photos: photos, background: bg, colorOps: colorOps)
        }
        marks?.prepare(page: page, pagePhotoIDs: pagePhotoIDs, photos: photos, vars: vars, frames: framingFrames)

        // 每格这次实际用的取景（调试层画人脸框用：封面取景的格子不是 CollageCrop.window 算出来的那个）。
        var windows: [[Int]: CollageCrop.Window] = [:]
        if let sheet = page.contactSheet {
            // 印样 / 底片条：整页按片条画（切分树是一个空叶子，不画）。
            let env = CollageContact.Context(photos: photos, hints: hints, colorOps: colorOps, vars: vars, options: options,
                                             style: style, canvas: canvas, scale: scale, bleed: bleed,
                                             sharpenRadius: sharpenRadius, screen: screen, background: bg)
            let record = CollageContact.draw(sheet, ctx: ctx, env: env)
            // 纸纹压照片：帧里的照片和格子照片一样压（record.paperClips 已经是这次渲染的坐标）。
            if style.paperOverPhotos > 0 { paperClips += record.paperClips }
            options.report?.contactSheet = record
        } else if !page.freeform {
            for frame in geo.frames {
                guard !frame.rect.isEmpty else { continue }
                let rect = frame.rect.cgRect
                switch frame.cell.kind {
                case .photo:
                    let unscaled = framingFrames.first { $0.path == frame.path }
                    guard let id = frame.cell.photoID, let photo = photos[id] else {
                        // 空格子：预览画占位（压字也画上，提醒这里有字），导出不印孤零零的一行字。
                        if options.placeholders { drawPlaceholder(ctx, rect: rect, short: short, dark: bg.luminance < 0.4) }
                        if !frame.cell.overlays.isEmpty, let unscaled, options.placeholders {
                            drawOverlays(cell: frame.cell, path: frame.path, unscaled: unscaled, ctx: ctx, project: project,
                                         photo: nil, framing: .auto, hints: nil, vars: vars, background: bg,
                                         scale: scale, bleed: bleed, canvasHeight: fullH, report: options.report)
                        }
                        continue
                    }
                    let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: framingFrames,
                                                                 photos: photos, tight: style.tightSmallCells)
                    // 零边距印刷：只有普通矩形照片格铺进出血；文字、月洞门/拱窗、带框的格子不动。
                    let extend = fullBleed && canBleed(frame.cell, style: style)
                        ? bleedEdges(rect, trim: trim.cgRect, bleed: CGFloat(bleed)) : nil
                    // 这一格自己的占位符（{frame} 帧号）：压字、出图记录、每张照片的水印用同一份。
                    let cellVars = CollageTypeset.cellVariables(vars, photo: photo)
                    // 人物挡字、封面取景、抠图格：先要 CollageCover 的决定（取景、哪几块字真在人后、刊头缩没缩）。
                    // 别的格子 = nil，下面一步都不多走（逐像素不变）。
                    let decided = unscaled.flatMap {
                        CollageCover.resolve(cell: frame.cell, frameRect: $0.rect.cgRect, project: project, photo: photo,
                                             framing: framing, hints: hints[id], vars: cellVars, background: bg)
                    }
                    // 抠图格贴不到成品底边（CollageCutout.toEdge）的退回整张照片：cutoutDropped。
                    let cutoutMask = frame.cell.cutout != nil && decided?.cutoutDropped != true ? decided?.mask : nil
                    if let decided { windows[frame.path] = decided.window }
                    let shown = drawPhoto(ctx, cell: frame.cell, rect: rect, photo: photo, framing: framing, style: style,
                                          short: short, hints: hints[id], background: bg, sharpenRadius: sharpenRadius,
                                          options: options, extend: extend,
                                          color: CollageLooks.ops(colorOps[id], cell: frame.cell),
                                          window: decided?.window, subjectOnly: cutoutMask != nil,
                                          screen: screen, keyline: keyline)
                    if let shown, style.paperOverPhotos > 0, cutoutMask == nil { paperClips.append(shown.clip) }
                    if let report = options.report, let screen, shown != nil {
                        report.halftone.append(halftoneRecord(screen, owner: ownerName(frame.path), photoID: photo.id))
                    }
                    if let report = options.report, let shown {
                        report.crops.append(cropRecord(photo: photo, cell: frame.cell, path: frame.path, framing: framing,
                                                       window: shown.window, drawn: shown.drawn, scale: scale,
                                                       bleed: bleed, decided: decided))
                        if let decided, let mask = decided.mask {
                            report.masks.append(maskRecord(mask, photo: photo, path: frame.path, decided: decided,
                                                           cutout: cutoutMask != nil))
                        }
                    }
                    // 主体切图压在人后的字上：照片 → 人后的字 → 主体 → 人前的字 → 本格水印。
                    let subject = (decided?.hasBehind ?? false) || cutoutMask != nil
                    if subject, let decided, let mask = decided.mask, let shown, let unscaled {
                        let placed = frame.cell.overlays.isEmpty ? []
                            : drawOverlays(cell: frame.cell, path: frame.path, unscaled: unscaled, ctx: ctx,
                                           project: project, photo: photo, framing: framing, hints: hints[id],
                                           vars: cellVars, background: bg, scale: scale, bleed: bleed,
                                           canvasHeight: fullH, report: nil, decided: decided, layer: .behindSubject)
                        let region = cutoutMask != nil ? nil
                            : subjectRegion(placed, decided: decided, cell: frame.cell, unscaled: unscaled,
                                            project: project, photo: photo, framing: framing, hints: hints[id],
                                            scale: scale, bleed: bleed)
                        let tight = frame.cell.overlays.contains { $0.layer == .behindSubject && $0.tightEdge }
                        let ink = cutoutMask != nil ? nil
                            : subjectInk(placed, decided: decided, cell: frame.cell, vars: cellVars, scale: scale,
                                         bleed: bleed)
                        drawSubject(ctx, shown: shown, mask: mask, scale: scale, short: short, region: region,
                                    cutout: cutoutMask != nil ? frame.cell.cutout : nil, tight: tight, ink: ink)
                        if !frame.cell.overlays.isEmpty {
                            drawOverlays(cell: frame.cell, path: frame.path, unscaled: unscaled, ctx: ctx, project: project,
                                         photo: photo, framing: framing, hints: hints[id], vars: cellVars,
                                         background: bg, scale: scale, bleed: bleed, canvasHeight: fullH,
                                         report: options.report, decided: decided, layer: .front)
                        }
                    } else if !frame.cell.overlays.isEmpty, let unscaled {
                        drawOverlays(cell: frame.cell, path: frame.path, unscaled: unscaled, ctx: ctx, project: project,
                                     photo: photo, framing: framing, hints: hints[id], vars: cellVars,
                                     background: bg, scale: scale, bleed: bleed, canvasHeight: fullH,
                                     report: options.report, decided: decided)
                    }
                    if let marks, let unscaled {
                        marks.drawCell(frame.cell, path: frame.path, frameRect: unscaled.rect.cgRect, photo: photo,
                                       framing: framing, hints: hints[id], vars: cellVars, background: bg, ctx: ctx)
                    }
                case .text:
                    if let own = frame.cell.text {
                        // 字色跟着页面底色翻深浅（CollageText.paperTone，CollageStyleSwissTypeset.swift；别的文字格原样）。
                        let text = own.paperTone ? paperToned(own, background: bg) : own
                        // 印刷：文字格贴着成品边时退进安全区（裁切有 ±1mm 误差，字贴边会被切掉）。
                        let safe = CGFloat(Double(canvas.safe) * scale)
                        let area = safe > 0 ? insetFromTrim(rect, trim: trim.cgRect, by: safe) : rect
                        CollageTypeset.draw(text, in: area, ctx: ctx, short: short, vars: vars, canvasHeight: fullH,
                                            owner: barOwner(vars, path: frame.path))
                        if let report = options.report, let unscaled = framingFrames.first(where: { $0.path == frame.path }) {
                            report.texts.append(textCellRecord(text, path: frame.path, rect: unscaled.rect.cgRect,
                                                               canvas: canvas, vars: vars))
                        }
                    }
                case .empty:
                    // 留白格是版式的一部分（错落、电影黑边），不画「待放照片」的虚线框。
                    break
                }
            }
        }

        if !paperClips.isEmpty {
            drawPaperOver(ctx, clips: paperClips, intensity: style.paperOverPhotos, paper: paperBase,
                          tint: screen == nil, scale: scale)
        }

        if !page.items.isEmpty {
            let dc = CollageItems.DrawContext(canvas: canvas, scale: scale, bleed: Double(bleed), photos: photos,
                                              hints: hints, colorOps: colorOps, vars: vars, options: options,
                                              sharpenRadius: sharpenRadius, sharpen: style.sharpen, canvasHeight: fullH,
                                              marks: marks, screen: screen, paperOver: style.paperOverPhotos,
                                              background: paperBase)
            CollageItems.draw(page.items, ctx: ctx, dc: dc)
            if let report = options.report {
                // 和 CollageItems.draw 一样：导出不印没分到照片的相纸（和贴在上面的东西）。
                let skipped = options.placeholders ? [] : CollageItems.unprinted(page.items, photos: photos)
                for (i, item) in page.items.enumerated() where item.kind == .text && !skipped.contains(item.id) {
                    guard let text = item.text else { continue }
                    report.texts.append(itemTextRecord(text, item: item, index: i, canvas: canvas, vars: vars))
                }
            }
        }
        marks?.drawPage(ctx: ctx)

        if options.guides {
            drawGuides(ctx, canvas: canvas, scale: scale, trim: trim.cgRect, bleed: bleed)
        }
        if options.debug {
            drawDebug(ctx, geo: page.freeform || page.contactSheet != nil ? CollageLayout.Geometry() : geo,
                      framingFrames: framingFrames,
                      photos: photos, hints: hints, style: style, canvas: canvas, scale: scale, trim: trim.cgRect,
                      bleed: bleed, windows: windows)
        }
        return ctx.makeImage()
    }

    // MARK: - 压字

    /// 一张照片上全部字块的位置（成品尺寸、unscaled 那一格算，再按缩放映射到这次渲染），和 cell.overlays 一一对应
    /// （放不下的是 nil）。定死位置的（九宫格里点的、手动拖过的）先摆 —— 它们不挪，谁都得让着；自动的、沿边的
    /// 再按数组顺序摆（刊头先）：每一块让开已经摆好的所有字块（外扩一点当已占用）。
    /// 渲染器、画布上的虚线框和拖字、水印避让都调这一个 —— 三处摆出来是同一组位置。
    /// 人物挡字 / 封面取景的格子先问 CollageCover 要决定（取景窗口、刊头缩没缩），再按它摆。
    static func overlayPlacements(cell: CollageCell, frameRect: CGRect, project: CollageProject,
                                  photo: CollagePhotoRef?, framing: CollageFraming, hints: CollageCrop.Hints?,
                                  vars: [String: String], background: CollageColor) -> [CollageOverlays.Placement?] {
        guard !cell.overlays.isEmpty else { return [] }
        let decided = CollageCover.resolve(cell: cell, frameRect: frameRect, project: project, photo: photo,
                                           framing: framing, hints: hints, vars: vars, background: background)
        return rawPlacements(cell: cell, frameRect: frameRect, project: project, photo: photo, framing: framing,
                             hints: hints, vars: vars, background: background, window: decided?.window,
                             maxHeights: decided?.maxHeights ?? [:],
                             mask: decided?.cutoutDropped == true ? nil : decided?.mask,
                             moved: decided?.moved ?? [:])
    }

    /// 照片格这次实际用的取景：人物挡字 / 封面取景的格子按 CollageCover 的决定，别的同 CollageCrop.window。
    /// 界面上的人脸框、切脸角标、放大倍数、裁切起点都按它（和渲染器画出来的是同一块）。
    static func cellWindow(cell: CollageCell, frameRect: CGRect, project: CollageProject, photo: CollagePhotoRef,
                           framing: CollageFraming, hints: CollageCrop.Hints?, vars: [String: String],
                           background: CollageColor) -> CollageCrop.Window {
        if let decided = CollageCover.resolve(cell: cell, frameRect: frameRect, project: project, photo: photo,
                                              framing: framing, hints: hints, vars: vars, background: background) {
            return decided.window
        }
        let area = CollageCrop.photoArea(cell: cell, rect: frameRect, style: project.style)
        return CollageCrop.window(for: photo, cell: cell, cellAspect: CollageCrop.aspect(of: area), framing: framing,
                                  hints: hints)
    }

    /// 摆位本身（不问 CollageCover）：window = 取景（nil = 照常算）；maxHeights = 哪几块限高（刊头缩到头顶上方）。
    /// mask = 这张照片的主体蒙版（只有抠图格用：字底下透出的是页面底色）；moved = 退回人前、要挪开头的字块
    /// （下标 → 要躲开的头，成品坐标）：改成自动位置，把头当成已占用。CollageCover 试各种取景时直接调它。
    static func rawPlacements(cell: CollageCell, frameRect: CGRect, project: CollageProject,
                              photo: CollagePhotoRef?, framing: CollageFraming, hints: CollageCrop.Hints?,
                              vars: [String: String], background: CollageColor, window: CollageCrop.Window?,
                              maxHeights: [Int: Double], mask: CollageMasks.Mask? = nil,
                              moved: [Int: [CGRect]] = [:]) -> [CollageOverlays.Placement?] {
        var list = cell.overlays
        guard !list.isEmpty else { return [] }
        for i in moved.keys where list.indices.contains(i) { list[i].anchor = .auto }
        let g = overlayGeometry(cell: cell, frameRect: frameRect, style: project.style, photo: photo,
                                framing: framing, hints: hints, window: window)
        // 字的深浅按这一格实际的色调判（格子单独设了用格子的；页级色调已经换进 project.style）。
        let look = CollageLooks.setting(style: project.style, cell: cell)
        let pad = CGFloat(project.canvas.shortSide * siblingPad)
        let matte = cell.cutout != nil ? mask : nil
        func run(_ list: [CollageOverlay]) -> [CollageOverlays.Placement?] {
            func place(_ i: Int, _ occupied: [CGRect]) -> CollageOverlays.Placement? {
                CollageOverlays.place(list[i], area: g.textArea, drawn: g.drawn, canvas: project.canvas, photo: photo,
                                      window: g.window, hints: hints, vars: vars, background: background,
                                      look: look.look, lookStrength: look.strength,
                                      occupied: occupied + (moved[i] ?? []), maxHeight: maxHeights[i], matte: matte,
                                      subject: mask,
                                      siblingSides: Set(list.indices.filter { $0 != i && list[$0].anchor.isSide }
                                          .map { list[$0].anchor }))
            }
            let pinned = list.map { $0.anchor != .auto && !$0.anchor.isSide }
            var out = [CollageOverlays.Placement?](repeating: nil, count: list.count)
            var occupied: [CGRect] = []
            for i in list.indices where pinned[i] {
                out[i] = place(i, [])
                if let p = out[i] { occupied.append(p.rect.insetBy(dx: -pad, dy: -pad)) }
            }
            for i in list.indices where !pinned[i] {
                out[i] = place(i, occupied)
                if let p = out[i] { occupied.append(p.rect.insetBy(dx: -pad, dy: -pad)) }
            }
            return out
        }
        // 统一深浅（matchTone、干净的字、深浅自动；时尚刊封面字全白或全黑）：两种深浅各摆一遍（摆位跟着深浅挑），
        // 比那几块摆位的总代价（看不看得清 + 压没压人身上、脸边、栏的高度 —— 只比看不看得清时，「深字压在白袖子上」
        // 赢过「白字落在深木头上」）；还压在人身上的（这一遍没找到不压人的位置）每块再加 bodyPenalty，摆不下的加 missPenalty。
        // 没有这种字块 = 只摆一遍（以前的样子）。
        let matched = list.indices.filter { list[$0].matchTone && !list[$0].scrim && list[$0].tone == .auto }
        guard matched.count > 1 else { return run(list) }
        var best: (out: [CollageOverlays.Placement?], cost: Double)?
        for tone in [CollageTone.light, .dark] {
            var trial = list
            for i in matched { trial[i].tone = tone }
            let out = run(trial)
            var total = 0.0
            for i in matched {
                guard let p = out[i] else {
                    total += missPenalty
                    continue
                }
                total += p.cost + (p.onBody > CollageOverlays.bodyMax ? bodyPenalty : 0)
            }
            if best == nil || total < best!.cost - 1e-9 { best = (out, total) }
        }
        return best?.out ?? run(list)
    }

    /// 字块之间至少隔多远（相对画布短边）。
    static let siblingPad = 0.012
    /// 统一深浅比较两遍时：一块字还压在人身上、一块字摆不下各加多少（看不看得清那一项最多 6）。
    private static let bodyPenalty = 8.0
    private static let missPenalty = 20.0

    /// 灰条种子用的「这块字是谁」：页码 + 格子路径（+ 第几块）。只用字串不用坐标，预览、导出一样。
    static func barOwner(_ vars: [String: String], path: [Int], index: Int? = nil) -> String {
        let at = path.map(String.init).joined(separator: ".")
        return "\(vars["no"] ?? "")|\(at)" + (index.map { "|\($0)" } ?? "")
    }

    /// 压字的几何：字能放的范围、照片实际画在哪、取景窗口。渲染器和画布上的拖字、虚线框共用这一个函数。
    struct OverlayGeometry {
        var textArea: CGRect
        var drawn: CGRect
        var window: CollageCrop.Window?
    }

    /// 字能放的范围 = 形状里面最大的矩形 ∩ 照片实际画出来的区域。形状裁在哪和 drawPhoto 一样：
    /// 有边框裁外框，没边框裁照片实际画的区域（「完整显示」时比格子小 —— 以前按整格算，字会跑到圆外）。
    /// window = 已经定好的取景（CollageCover 的决定）；nil = 照常算。
    static func overlayGeometry(cell: CollageCell, frameRect: CGRect, style: CollageStyle, photo: CollagePhotoRef?,
                                framing: CollageFraming, hints: CollageCrop.Hints?,
                                window decided: CollageCrop.Window? = nil) -> OverlayGeometry {
        let area = CollageCrop.photoArea(cell: cell, rect: frameRect, style: style)
        var window: CollageCrop.Window?
        var drawn = area
        if let photo {
            let w = decided ?? CollageCrop.window(for: photo, cell: cell, cellAspect: CollageCrop.aspect(of: area),
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

    /// 这张照片上的字块按顺序摆好、一个个画（后面的压在前面的上面），出图记录按同样的顺序记（全部画完再记，
    /// 分两层画时也是数组顺序）。layer = 只画实际在这一层的（人物挡字分两遍：人后的、人前的）；nil = 全画。
    /// 返回摆好的位置（和 cell.overlays 一一对应）。
    @discardableResult
    private static func drawOverlays(cell: CollageCell, path: [Int], unscaled: CollageLayout.Frame, ctx: CGContext,
                                     project: CollageProject, photo: CollagePhotoRef?, framing: CollageFraming,
                                     hints: CollageCrop.Hints?, vars: [String: String], background: CollageColor,
                                     scale: Double, bleed: Int, canvasHeight: Int, report: RenderReport?,
                                     decided: CollageCover.Resolution? = nil,
                                     layer: CollageTextLayer? = nil) -> [CollageOverlays.Placement?] {
        let list = cell.overlays
        let placements = overlayPlacements(cell: cell, frameRect: unscaled.rect.cgRect, project: project, photo: photo,
                                           framing: framing, hints: hints, vars: vars, background: background)
        for (i, placed) in placements.enumerated() {
            guard let p = placed else { continue }
            if let layer, effectiveLayer(i, decided) != layer { continue }
            drawOverlay(p, overlay: list[i], cell: cell, unscaled: unscaled, ctx: ctx, project: project, photo: photo,
                        framing: framing, hints: hints, vars: vars, scale: scale, bleed: bleed,
                        canvasHeight: canvasHeight, owner: barOwner(vars, path: path, index: i), window: decided?.window)
        }
        if let report {
            for (i, placed) in placements.enumerated() {
                guard let p = placed else { continue }
                let block = decided.flatMap { $0.blocks.indices.contains(i) ? $0.blocks[i] : nil }
                report.texts.append(overlayRecord(p, overlay: list[i], path: path, index: i, vars: vars, block: block,
                                                  decided: decided))
            }
        }
        return placements
    }

    /// 第 i 块字实际画在哪一层：CollageCover 定过的按它，没定过的（普通字块）在人前。
    private static func effectiveLayer(_ i: Int, _ decided: CollageCover.Resolution?) -> CollageTextLayer {
        guard let decided, decided.blocks.indices.contains(i), let block = decided.blocks[i] else { return .front }
        return block.layer
    }

    private static func drawOverlay(_ p: CollageOverlays.Placement, overlay: CollageOverlay, cell: CollageCell,
                                    unscaled: CollageLayout.Frame, ctx: CGContext, project: CollageProject,
                                    photo: CollagePhotoRef?, framing: CollageFraming, hints: CollageCrop.Hints?,
                                    vars: [String: String], scale: Double, bleed: Int, canvasHeight: Int,
                                    owner: String, window: CollageCrop.Window? = nil) {
        let s = CGFloat(scale)
        let rect = CGRect(x: p.rect.minX * s + CGFloat(bleed), y: p.rect.minY * s + CGFloat(bleed),
                          width: p.rect.width * s, height: p.rect.height * s)
        // 底下太花、反差不够（栏杆石雕、屋檐）：字后面先垫一块羽化的雾面，深字衬白、浅字衬黑；
        // 干净的天空上 halo = 0，什么都不垫。「衬底」滑杆管它的深浅，拖到 0 就不垫。只垫在照片上
        // （剪到照片实际画的区域和形状里），不漫到缝和边距上。
        if overlay.shadow > 0, overlay.scrim, p.halo > 0.05 {
            let g = overlayGeometry(cell: cell, frameRect: unscaled.rect.cgRect, style: project.style, photo: photo,
                                    framing: framing, hints: hints, window: window)
            let drawn = CGRect(x: g.drawn.minX * s + CGFloat(bleed), y: g.drawn.minY * s + CGFloat(bleed),
                               width: g.drawn.width * s, height: g.drawn.height * s)
            let corner = CGFloat(project.style.corner * project.canvas.shortSide * scale)
            ctx.saveGState()
            ctx.addPath(shapePath(cell.shape ?? project.style.shape, rect: drawn, corner: corner))
            ctx.clip()
            drawScrim(ctx, around: rect, light: p.light, strength: p.halo * overlay.shadow / 0.45)
            ctx.restoreGState()
        }
        // 干净的字（时尚刊）：底部一道平滑的压暗（只在需要时有），剪到照片实际画的区域里。
        if !overlay.scrim, let fade = p.fade {
            let g = overlayGeometry(cell: cell, frameRect: unscaled.rect.cgRect, style: project.style, photo: photo,
                                    framing: framing, hints: hints, window: window)
            let drawn = CGRect(x: g.drawn.minX * s + CGFloat(bleed), y: g.drawn.minY * s + CGFloat(bleed),
                               width: g.drawn.width * s, height: g.drawn.height * s)
            let corner = CGFloat(project.style.corner * project.canvas.shortSide * scale)
            ctx.saveGState()
            ctx.addPath(shapePath(cell.shape ?? project.style.shape, rect: drawn, corner: corner))
            ctx.clip()
            drawFade(ctx, fade, scale: s, bleed: CGFloat(bleed), drawn: drawn)
            ctx.restoreGState()
        }
        // 干净的字看不清时：沿字形一圈光晕（浅字深晕、深字白晕），画在字下面（CollageStyleFashionType）。
        if !overlay.scrim, overlay.shadow > 0 {
            CollageOverlays.drawGlow(p, in: rect, ctx: ctx, short: p.short * scale, vars: vars)
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
                                      canvasHeight: canvasHeight, owner: owner)
            ctx.endTransparencyLayer()
        } else {
            CollageTypeset.drawFitted(p.text, in: rect, ctx: ctx, short: p.short * scale, vars: vars,
                                      canvasHeight: canvasHeight, owner: owner)
        }
        ctx.restoreGState()
    }

    /// 底部压暗（干净的字）：一条连续的线性渐变（64 段 smoothstep，不是一圈圈叠的方块），from 处透明、to 处最深，
    /// 再往下到照片底边一样深。坐标是成品坐标，按这次渲染的倍数、出血换算；铺满照片画出来的宽。
    private static func drawFade(_ ctx: CGContext, _ fade: CollageOverlays.Fade, scale: CGFloat, bleed: CGFloat,
                                 drawn: CGRect) {
        let top: CGFloat = CGFloat(fade.from) * scale + bleed
        let full: CGFloat = CGFloat(fade.to) * scale + bleed
        guard full > top, fade.alpha > 0 else { return }
        let steps = 64
        var colors: [CGColor] = []
        var stops: [CGFloat] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let eased: Double = t * t * (3 - 2 * t)
            colors.append(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: fade.alpha * eased))
            stops.append(CGFloat(t))
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                        locations: stops) else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: drawn.minX, y: max(drawn.minY, top), width: drawn.width,
                            height: max(0, drawn.maxY - max(drawn.minY, top))))
        ctx.drawLinearGradient(gradient, start: CGPoint(x: drawn.midX, y: top), end: CGPoint(x: drawn.midX, y: full),
                               options: [.drawsAfterEndLocation])
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

    // MARK: - 出图记录（.marks.json 的 texts / crops，ops 的 dumptexts）

    private static func ownerName(_ path: [Int]) -> String {
        path.isEmpty ? "r" : path.map(String.init).joined()
    }

    private static func textRecord(owner: String, kind: String, rect: CGRect, text: CollageText, short: Double,
                                   vars: [String: String]) -> TextRecord {
        let lines = CollageTypeset.expandedLines(text, vars: vars)
        let sizes = lines.map { $0.line.size * $0.line.glyphScale * short }
        var record = TextRecord(owner: owner, kind: kind, rect: rect, font: lines.first?.line.font.rawValue ?? "",
                                size: sizes.first ?? 0, lines: lines.map(\.text), sizes: sizes, vertical: text.vertical)
        record.rotation = text.rotation
        record.body = text.body.map { CollageTypeset.bodyKind($0, vars: vars) }
        return record
    }

    /// 压字：摆位本来就按成品尺寸算（p.rect、p.short 都是 1 倍）。同一张照片上第 2 个起的字块 owner 是 "00.1"、"00.2"……
    /// 人物挡字的字块：layer 记实际画在哪一层（退回人前的记 front），occlusion 记量出来的和为什么。
    private static func overlayRecord(_ p: CollageOverlays.Placement, overlay: CollageOverlay, path: [Int], index: Int,
                                      vars: [String: String], block: CollageCover.Block? = nil,
                                      decided: CollageCover.Resolution? = nil) -> TextRecord {
        let owner = ownerName(path) + (index > 0 ? ".\(index)" : "")
        var record = textRecord(owner: owner, kind: "overlay", rect: p.rect, text: p.text, short: p.short, vars: vars)
        record.layer = overlay.layer.rawValue
        if let block {
            record.layer = block.layer.rawValue
            let o = block.occlusion
            record.occlusion = OcclusionRecord(measured: o != nil, total: o?.total ?? 0, perLetter: o?.perLetter ?? [],
                                               perLine: o?.perLine ?? [], first: o?.first ?? 0, last: o?.last ?? 0, heavy: o?.heavy ?? 0,
                                               decision: block.step.rawValue, requested: overlay.layer.rawValue,
                                               reason: block.reason, limit: block.limit, depth: block.depth,
                                               eyesClear: block.eyesClear, band: block.band, faces: decided?.faces ?? 0,
                                               headTopSource: decided?.headTopSource ?? "estimate",
                                               rule: block.rule.rawValue, moved: block.moved,
                                               mainLine: o?.mainLine ?? 0, eyeBelow: block.eyeBelow,
                                               eyeFar: block.eyeFar, eyeClamp: block.eyeClamp)
        }
        return record
    }

    private static func maskRecord(_ mask: CollageMasks.Mask, photo: CollagePhotoRef, path: [Int],
                                   decided: CollageCover.Resolution, cutout: Bool) -> MaskRecord {
        MaskRecord(owner: ownerName(path), photoID: photo.id, key: mask.key, size: [mask.width, mask.height],
                   coverage: mask.coverage, headTop: mask.headTop, instances: mask.instances, selected: mask.selected,
                   cutout: cutout, behind: decided.hasBehind, people: mask.people)
    }

    /// 文字格：按成品尺寸重算一遍 draw 的缩字和对齐（退进安全区那一步也照做）。
    private static func textCellRecord(_ text: CollageText, path: [Int], rect: CGRect, canvas: CollageCanvas,
                                       vars: [String: String]) -> TextRecord {
        let safe = CGFloat(canvas.safe)
        let trim = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let area = safe > 0 ? insetFromTrim(rect, trim: trim, by: safe) : rect
        let laid = CollageTypeset.prepared(text, in: area, short: canvas.shortSide, vars: vars)
        let block = CollageTypeset.blockRect(laid.text, in: area, short: laid.short, vars: vars)
        return textRecord(owner: ownerName(path), kind: "cell", rect: block, text: laid.text, short: laid.short, vars: vars)
    }

    /// 文字图层：在图层局部坐标里排（和 CollageItems.draw 一样），字块四个角再转到成品坐标。
    private static func itemTextRecord(_ text: CollageText, item: CollageItem, index: Int, canvas: CollageCanvas,
                                       vars: [String: String]) -> TextRecord {
        let local = CollageItems.localRect(item, canvas: canvas)
        let laid = CollageTypeset.prepared(text, in: local, short: canvas.shortSide, vars: vars)
        let short = laid.short
        let block = CollageTypeset.blockRect(laid.text, in: local, short: short, vars: vars)
        let t = CollageItems.transform(item, canvas: canvas)
        let corners = [CGPoint(x: block.minX, y: block.minY), CGPoint(x: block.maxX, y: block.minY),
                       CGPoint(x: block.maxX, y: block.maxY), CGPoint(x: block.minX, y: block.maxY)].map { $0.applying(t) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let bounds = CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
        var record = textRecord(owner: "item\(index)", kind: "item", rect: bounds, text: laid.text, short: short,
                                vars: vars)
        record.corners = corners
        return record
    }

    /// 取景：这次渲染的 drawn（带缩放、出血偏移）换回成品坐标；眼线、头顶按窗口投到 drawn 上。
    /// 走了 CollageCover 的格子（人物挡字、封面、抠图）头顶用它定的那个（有蒙版 = 实测）。
    private static func cropRecord(photo: CollagePhotoRef, cell: CollageCell, path: [Int], framing: CollageFraming,
                                   window: CollageCrop.Window, drawn: CGRect, scale: Double, bleed: Int,
                                   decided: CollageCover.Resolution? = nil) -> CropRecord {
        let s = CGFloat(scale)
        let b = CGFloat(bleed)
        let trimDrawn = CGRect(x: (drawn.minX - b) / s, y: (drawn.minY - b) / s,
                               width: drawn.width / s, height: drawn.height / s)
        var record = CropRecord(owner: ownerName(path), photoID: photo.id, framing: framing.rawValue, window: window.rect,
                                drawn: trimDrawn, cutsFace: window.cutsFace, contain: cell.contain,
                                faces: photo.faces.filter(CollageCrop.isValidBox).count)
        if let f = photo.faces.first(where: CollageCrop.isValidBox), window.h > 0 {
            let fh = f[3] - f[1]
            let eye: Double = f[1] + 0.42 * fh
            let top: Double = decided?.headTop ?? max(0, f[1] - 0.3 * fh)
            if let decided { record.headTopSource = decided.headTopSource }
            let eyeFrac: Double = (eye - window.y) / window.h
            let topFrac: Double = (top - window.y) / window.h
            let y0 = Double(trimDrawn.minY)
            let h = Double(trimDrawn.height)
            record.eyeFrac = eyeFrac
            record.eyeY = y0 + eyeFrac * h
            record.headTopFrac = topFrac
            record.headTopY = y0 + topFrac * h
        }
        return record
    }

    // MARK: - 照片格

    /// 一格照片画出来的样子：tile = 调好色、锐化过的那张（pw×ph）、drawn = 画在哪、window = 取景、clip = 照片裁在
    /// 什么形状里（都是铺出血外延、取整之后的，这次渲染的坐标）。主体切图拿同一张 tile、同一个取景，和照片严丝合缝。
    struct Shown {
        var tile: CGImage
        var drawn: CGRect
        var window: CollageCrop.Window
        var clip: CGPath
        /// tile 是怎么做出来的（照片、调色、锐化、预览还是原图）：切图 alpha 以 tile 为向导放大，缓存键要带上它 ——
        /// 换了色调 tile 变了，别拿旧 tile 导出来的 alpha。
        var guide = ""
    }

    /// 没画出来 = nil。window = 已经定好的取景（CollageCover 的决定；nil = 照常算）。subjectOnly = 抠图格：
    /// 照片、框、投影、细线都不画（只准备好 tile，主体切图之后再画），背景透出页面。
    @discardableResult
    private static func drawPhoto(_ ctx: CGContext, cell: CollageCell, rect: CGRect, photo: CollagePhotoRef,
                                  framing: CollageFraming, style: CollageStyle, short: Double,
                                  hints: CollageCrop.Hints?, background: CollageColor, sharpenRadius: Double,
                                  options: Options, extend: Edges?, color: CollageLooks.Ops?,
                                  window base: CollageCrop.Window? = nil, subjectOnly: Bool = false,
                                  screen: CollageScreening.Spec? = nil, keyline: Keyline? = nil) -> Shown? {
        let shape = cell.shape ?? style.shape
        let outer = CollageCrop.outerArea(cell: cell, rect: rect, style: style)
        let framed = CollageCrop.isFramed(cell: cell, style: style)
        let inner = CollageCrop.photoArea(cell: cell, rect: rect, style: style)
        guard inner.width >= 2, inner.height >= 2 else { return nil }

        var window = base ?? CollageCrop.window(for: photo, cell: cell, cellAspect: CollageCrop.aspect(of: inner),
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
            if fits {
                window = w2
            } else if base != nil, w2.w <= 1 + 1e-6, w2.h <= 1 + 1e-6 {
                // 定好的取景（封面）外延出了照片：整块平移回照片里（差的不过出血那几毫米），不重新取景 ——
                // 重新取景就不是预览里那个决定了。
                w2.x = min(max(0, w2.x), max(0, 1 - w2.w))
                w2.y = min(max(0, w2.y), max(0, 1 - w2.h))
                window = w2
            } else {
                window = CollageCrop.window(for: photo, cell: cell, cellAspect: CollageCrop.aspect(of: grown),
                                            framing: framing, hints: hints)
            }
            drawn = grown.integral
        }
        let corner = CGFloat(style.corner * short)
        // 完整显示 + 本图模糊填：整格（含铺出血的那几条边）都是这张照片的模糊底，清楚的那张居中浮在上面。
        let blurFill = cell.contain && cell.containBlur
        var fillRect = inner
        if blurFill, let e = extend {
            fillRect = CGRect(x: inner.minX - e.left, y: inner.minY - e.top,
                              width: inner.width + e.left + e.right, height: inner.height + e.top + e.bottom)
        }
        // 卡纸 + 完整显示（不是模糊填）：卡纸贴着照片裁（上、左右 = 格子短边 × matWidth，底边加宽），不涂满整格 ——
        // 照片比格子窄 / 扁时整格涂成卡纸色，就是一块浮着照片的板子（卡纸色和纸色不同时一眼就看得出来）。
        var frameRect = outer
        if style.border == .mat, framed, cell.contain, !blurFill {
            let side = inner.minX - outer.minX
            let top = inner.minY - outer.minY
            let bottom = outer.maxY - inner.maxY
            frameRect = CGRect(x: drawn.minX - side, y: drawn.minY - top,
                               width: drawn.width + 2 * side, height: drawn.height + top + bottom)
        }
        let outerPath = shapePath(shape, rect: framed ? frameRect : (blurFill ? fillRect : drawn), corner: corner)
        let clip = framed ? CGPath(rect: drawn, transform: nil) : shapePath(shape, rect: drawn, corner: corner)
        let guide = tileGuide(photo, color: color, sharpen: style.sharpen, radius: sharpenRadius, export: options.export,
                              screen: screen)
        if subjectOnly {
            let pw = max(1, Int(drawn.width.rounded()))
            let ph = max(1, Int(drawn.height.rounded()))
            guard let tile = cellImage(photo: photo, window: window, width: pw, height: ph, sharpen: style.sharpen,
                                       radius: sharpenRadius, export: options.export, report: options.report,
                                       color: color, screen: screen) else { return nil }
            return Shown(tile: tile, drawn: drawn, window: window, clip: clip, guide: guide)
        }

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

        if blurFill, let backdrop = blurredBackdrop(photo, ops: color) {
            ctx.saveGState()
            ctx.addPath(framed ? CGPath(rect: inner, transform: nil) : shapePath(shape, rect: fillRect, corner: corner))
            ctx.clip()
            ctx.interpolationQuality = .high
            drawImageTopLeft(ctx, backdrop, aspectFill(Double(backdrop.width) / Double(max(1, backdrop.height)), in: fillRect))
            // 盖一层很薄的底色：模糊底退后一点，清楚的那张更跳。
            ctx.setFillColor(background.cgColor(alpha: 0.16))
            ctx.fill(fillRect)
            // 清楚的那张落一点影子，从模糊底上浮起来（照片马上盖住填的底色，只剩影子）。
            ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(short) * 0.003), blur: CGFloat(short) * 0.014,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
            ctx.setFillColor(background.cgColor)
            ctx.fill(drawn)
            ctx.restoreGState()
        }

        let pw = max(1, Int(drawn.width.rounded()))
        let ph = max(1, Int(drawn.height.rounded()))
        guard let tile = cellImage(photo: photo, window: window, width: pw, height: ph, sharpen: style.sharpen,
                                   radius: sharpenRadius, export: options.export, report: options.report,
                                   color: color, screen: screen) else { return nil }
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        drawImageTopLeft(ctx, tile, drawn)
        ctx.restoreGState()

        if style.border == .mat, framed, let keyline {
            drawKeyline(ctx, photo: blurFill ? inner : drawn, outer: outer, inner: inner, short: short, keyline: keyline,
                        style: style)
        }

        if style.border == .hairline {
            let lw = max(1, CGFloat(short) / 1400)
            ctx.saveGState()
            ctx.addPath(shapePath(shape, rect: (blurFill ? inner : drawn).insetBy(dx: lw / 2, dy: lw / 2), corner: corner))
            ctx.setStrokeColor(style.borderColor.cgColor(alpha: 0.9))
            ctx.setLineWidth(lw)
            ctx.strokePath()
            ctx.restoreGState()
        }
        return Shown(tile: tile, drawn: drawn, window: window, clip: clip, guide: guide)
    }

    /// Shown.guide：同一张照片、同一套调色和锐化、同是预览或原图 = 同一张 tile（取景、尺寸另在缓存键里）。
    static func tileGuide(_ photo: CollagePhotoRef, color: CollageLooks.Ops?, sharpen: Double, radius: Double,
                          export: Bool, screen: CollageScreening.Spec? = nil) -> String {
        let base = CollageVision.cacheKey(photo) + "#" + opsKey(color) + "|\(sharpen)|\(radius)|\(export)"
        return screen.map { base + "|" + $0.key } ?? base
    }

    // MARK: - 主体切图（人物挡字、抠图）

    /// 主体切图要盖住的地方：人后那几块字的框，外扩到字的投影、雾面、花字描边伸出去的地方（这次渲染的坐标）。
    /// 主体切图的像素就是照片本身，离字远的地方画不画都一样 —— 只在字附近画，蒙版有误差也只影响字上那一圈。
    private static func subjectRegion(_ placed: [CollageOverlays.Placement?], decided: CollageCover.Resolution,
                                      cell: CollageCell, unscaled: CollageLayout.Frame, project: CollageProject,
                                      photo: CollagePhotoRef, framing: CollageFraming, hints: CollageCrop.Hints?,
                                      scale: Double, bleed: Int) -> CGPath? {
        let list = cell.overlays
        let s = CGFloat(scale)
        let b = CGFloat(bleed)
        let short = CGFloat(project.canvas.shortSide * scale)
        let path = CGMutablePath()
        for (i, placedItem) in placed.enumerated() where effectiveLayer(i, decided) == .behindSubject {
            guard let p = placedItem, list.indices.contains(i) else { continue }
            let o = list[i]
            let r = CGRect(x: p.rect.minX * s + b, y: p.rect.minY * s + b, width: p.rect.width * s,
                           height: p.rect.height * s)
            var grow: CGFloat = short * 0.01 + 2
            if o.shadow > 0, o.scrim, p.halo > 0.05 { grow = max(grow, min(r.width, r.height) * 0.73 + 3) }
            if p.light, o.shadow > 0 {
                let k = CGFloat(o.shadow)
                grow = max(grow, short * 0.04 * k + 2)
            }
            grow = max(grow, CollageTypeset.effectOverhang(p.text, short: p.short * scale) + 2)
            path.addRect(r.insetBy(dx: -grow, dy: -grow))
        }
        return path.isEmpty ? nil : path
    }

    /// 人后那几块字的墨（每个字形的轮廓，这次渲染的坐标）：主体切图在墨上换去污染过的颜色。没有 = nil。
    private static func subjectInk(_ placed: [CollageOverlays.Placement?], decided: CollageCover.Resolution,
                                   cell: CollageCell, vars: [String: String], scale: Double, bleed: Int) -> CGPath? {
        let s = CGFloat(scale)
        let b = CGFloat(bleed)
        let path = CGMutablePath()
        for (i, placedItem) in placed.enumerated() where effectiveLayer(i, decided) == .behindSubject {
            guard let p = placedItem else { continue }
            let r = CGRect(x: p.rect.minX * s + b, y: p.rect.minY * s + b, width: p.rect.width * s,
                           height: p.rect.height * s)
            for g in CollageTypeset.glyphOutlines(p.text, in: r, short: p.short * scale, vars: vars) {
                path.addPath(g.path)
            }
        }
        return path.isEmpty ? nil : path
    }

    /// 主体切图：同一张 tile 按蒙版再画一遍（裁到格子形状 ∩ region）。抠图格（cutout）不给 region：整个主体，
    /// 只裁到照片那块矩形（不裁形状），可选白色贴纸边、投影。
    /// 散落版的抠图贴纸（CollageItems）也走这里：在相纸的局部坐标里画，short 给这次渲染的像素。
    static func drawSubject(_ ctx: CGContext, shown: Shown, mask: CollageMasks.Mask, scale: Double,
                            short: Double, region: CGPath?, cutout: CollageCutout?, tight: Bool = false,
                            ink: CGPath? = nil) {
        guard let alpha = subjectAlpha(mask: mask, shown: shown, scale: scale, hard: cutout != nil,
                                       tight: tight) else { return }
        let rect = shown.drawn
        let local = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        // 人物挡字：软边那一圈的颜色是「头发 + 照片背景」混出来的，按软 alpha 叠到白字上就是一圈脏边（深色木头、红柱子
        // 透出来，加网时更明显）。字的墨上：颜色换成去污染过的（边上用里面实心那片的颜色往外推），alpha 再收紧一点
        // （软边窄一半，发丝照样半透明）；墨外面照旧（底下本来就是这张照片，原 tile 按原 alpha 叠上去一像素不变）。
        var image = shown.tile
        var matte = alpha
        if cutout == nil, let ink,
           let clean = decontaminated(shown: shown, alpha: alpha, mask: mask, scale: scale, tight: tight),
           let mixed = inkMixed(shown: shown, alpha: alpha, clean: clean, ink: ink, mask: mask, scale: scale,
                                tight: tight) {
            image = mixed.image
            matte = mixed.alpha
        }
        let stroke = cutout?.stroke ?? 0
        let shadow = cutout?.shadow ?? 0
        let s = CGFloat(short)
        func setShadow() {
            let k = CGFloat(shadow)
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006 * k), blur: s * 0.022 * k,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.38 * Double(k)))
        }
        ctx.saveGState()
        // 抠图格不裁到格子形状（圆、拱窗）：背景不画，形状本身看不见，裁出来只是人身上一道看不见的弧；
        // 只裁到照片画的那块矩形。人物挡字照旧裁到形状（照片本来就只在形状里）。
        if cutout != nil {
            ctx.clip(to: rect)
        } else {
            ctx.addPath(shown.clip)
            ctx.clip()
        }
        if let region {
            ctx.addPath(region)
            ctx.clip()
        }
        // 白色贴纸边：蒙版往外长 stroke，填白；有投影就让这一层落影子。
        if stroke > 0, let sticker = silhouette(alpha, grow: stroke * short, scale: scale) {
            ctx.saveGState()
            if shadow > 0 { setShadow() }
            drawImageTopLeft(ctx, sticker, rect)
            ctx.restoreGState()
        }
        ctx.saveGState()
        let ownShadow = stroke <= 0 && shadow > 0
        if ownShadow {
            setShadow()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: local, mask: matte)
        ctx.draw(image, in: local)
        ctx.restoreGState()
        if ownShadow { ctx.endTransparencyLayer() }
        ctx.restoreGState()
        ctx.restoreGState()
    }

    private static let alphaLock = NSLock()
    private static var alphaCache: [String: CGImage] = [:]

    /// 切图缓存（alpha、去污染、墨上混合）只收这么大以内的 tile：缓存是给预览拖缝、刷新用的；印刷导出的 tile
    /// （A4 300dpi 一格 900 万像素，三份缓存一项合起来约 90MB，各留 9 项）很少重渲，进缓存只是把内存压着。
    static let cutCacheMaxPixels = 4_000_000

    /// 蒙版 → 这一格 tile 大小的 alpha（8 位灰度，和 tile 同一个取景）：按取景裁 1024 蒙版 → 以 tile 为向导
    /// CIEdgePreserveUpsampleFilter 放大（发丝跟着照片里的边走，软边留着）→ 收 1px×scale（去掉背景色的毛边）
    /// → 羽化 0.6px×scale。tile 比蒙版那块还小（缩略图）时直接缩。按蒙版、取景、尺寸缓存：拖别的缝不重算。
    /// hard = 抠图格：贴纸要利落的边 —— 多收一点（2px×scale）、软边压陡（边上那一圈带着背景色，贴到别的底色上
    /// 会露一道色边）。人物挡字不压：头发丝留着半透明。
    /// tight = 人物挡字也压利落（CollageOverlay.tightEdge）：软边压陡，收的那一圈至少一个蒙版像素
    /// （蒙版被放大几倍，收 1px 等于没收）。
    static func subjectAlpha(mask: CollageMasks.Mask, shown: Shown, scale: Double, hard: Bool = false,
                             tight: Bool = false) -> CGImage? {
        let pw = shown.tile.width
        let ph = shown.tile.height
        let w = shown.window
        let key = "\(mask.signature)|\(w.x),\(w.y),\(w.w),\(w.h)|\(pw)x\(ph)|\(scale)|\(hard)|\(tight)|\(shown.guide)"
        alphaLock.lock()
        let hit = alphaCache[key]
        alphaLock.unlock()
        if let hit { return hit }
        let mw = Double(mask.width)
        let mh = Double(mask.height)
        let sw: Double = w.w * mw
        let sh: Double = w.h * mh
        guard sw > 0.5, sh > 0.5, pw > 0, ph > 0 else { return nil }
        // CoreImage 左下原点：窗口下沿在蒙版里的 y。
        let x0: Double = w.x * mw
        let y0: Double = mh - w.y * mh - sh
        let iw = max(1, Int(sw.rounded()))
        let ih = max(1, Int(sh.rounded()))
        let small = CIImage(cgImage: mask.image).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -x0, y: -y0))
            .transformed(by: CGAffineTransform(scaleX: Double(iw) / sw, y: Double(ih) / sh))
            .cropped(to: CGRect(x: 0, y: 0, width: iw, height: ih))
        let target = CGRect(x: 0, y: 0, width: pw, height: ph)
        var up: CIImage
        if iw < pw, ih < ph, let f = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            f.setValue(CIImage(cgImage: shown.tile), forKey: kCIInputImageKey)
            f.setValue(small, forKey: "inputSmallImage")
            up = f.outputImage ?? small.transformed(by: CGAffineTransform(scaleX: Double(pw) / Double(iw),
                                                                          y: Double(ph) / Double(ih)))
        } else {
            up = small.transformed(by: CGAffineTransform(scaleX: Double(pw) / Double(iw), y: Double(ph) / Double(ih)))
        }
        up = up.cropped(to: target)
        // 一个蒙版像素在 tile 上有多宽（tile 已经是这次渲染的尺寸，不再乘 scale）。
        let maskPixel: Double = Double(pw) / sw
        let erode = tight ? max(2.0 * scale, maskPixel) : (hard ? 2.0 : 1.0) * scale
        if erode >= 0.5 {
            up = up.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: erode])
                .cropped(to: target)
        }
        if hard || tight { up = steepened(up, gain: 2, offset: -0.6).cropped(to: target) }
        let feather = 0.6 * scale
        if feather >= 0.3 {
            up = up.clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: target)
        }
        guard let out = ciContext.createCGImage(up, from: target, format: .L8,
                                                colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        guard pw * ph <= cutCacheMaxPixels else { return out }
        alphaLock.lock()
        if alphaCache.count > 8 { alphaCache.removeAll() }
        alphaCache[key] = out
        alphaLock.unlock()
        return out
    }

    private static var decontCache: [String: CGImage] = [:]

    /// 软边去污染（人物挡字的主体切图用）：软边上的像素 I = a·F + (1 − a)·B，B 是照片里人后面的背景 —— 叠到字上时
    /// 这层 B 就是那圈脏边。估前景色 F：只拿「实心」的像素（a > 0.5，越实越算数）按高斯权重往外推（预乘 alpha 模糊再
    /// 反预乘 = 加权平均），里面（a ≥ 0.9）照旧用原 tile，边上换成 F，中间渐变。alpha 不动（发丝照样半透明，字透得出来）。
    /// 推多远按蒙版放大了几倍定（软边大约 2 个蒙版像素宽）。按蒙版、取景、tile、缩放缓存。
    /// tight = 这份 alpha 是按 tightEdge 收过的（同 subjectAlpha 的键：两种 alpha 去污染出来不一样，不能共用缓存）。
    static func decontaminated(shown: Shown, alpha: CGImage, mask: CollageMasks.Mask, scale: Double,
                               tight: Bool = false) -> CGImage? {
        let pw = shown.tile.width
        let ph = shown.tile.height
        let w = shown.window
        let key = "\(mask.signature)|\(w.x),\(w.y),\(w.w),\(w.h)|\(pw)x\(ph)|\(scale)|\(tight)|\(shown.guide)"
        alphaLock.lock()
        let hit = decontCache[key]
        alphaLock.unlock()
        if let hit { return hit }
        let target = CGRect(x: 0, y: 0, width: pw, height: ph)
        let maskPx: Double = max(1, w.w * Double(mask.width))
        let factor: Double = Double(pw) / maskPx
        let sigma: Double = max(1.5, 2.2 * factor)
        let tile = CIImage(cgImage: shown.tile)
        let a = CIImage(cgImage: alpha)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: target)
        let weight = steepened(a, gain: 2, offset: -1).cropped(to: target)
        let weighted = tile.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear,
                                                                           kCIInputMaskImageKey: weight])
        let pushed = weighted.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: target)
            .unpremultiplyingAlpha().settingAlphaOne(in: target)
        let inner = steepened(a, gain: 2.5, offset: -1.25).cropped(to: target)
        let out = tile.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: pushed,
                                                                      kCIInputMaskImageKey: inner]).cropped(to: target)
        guard let image = ciContext.createCGImage(out, from: target, format: .RGBA8, colorSpace: srgb) else { return nil }
        guard pw * ph <= cutCacheMaxPixels else { return image }
        alphaLock.lock()
        if decontCache.count > 8 { decontCache.removeAll() }
        decontCache[key] = image
        alphaLock.unlock()
        return image
    }

    /// 字的墨（这次渲染的坐标）栅格化成 tile 大小的灰度蒙版，拿它把去污染的颜色、收紧的 alpha 只换在墨上：
    /// 颜色 = 墨上 clean、别处原 tile；alpha = 墨上 clamp(2a − 0.5)（软边窄一半）、别处原 alpha。一次画完（分两遍按墨裁会在字边留缝）。
    /// 按墨的轮廓（每个点）+ tile、alpha 的键缓存 8 张：同一页反复重渲（拖别的缝、预览刷新）不重算。
    private static func inkMixed(shown: Shown, alpha: CGImage, clean: CGImage, ink: CGPath, mask: CollageMasks.Mask,
                                 scale: Double, tight: Bool = false) -> (image: CGImage, alpha: CGImage)? {
        let pw = shown.tile.width
        let ph = shown.tile.height
        let rect = shown.drawn
        let w = shown.window
        let key = "\(inkSignature(ink))|\(w.x),\(w.y),\(w.w),\(w.h)|\(pw)x\(ph)|\(rect.minX),\(rect.minY),"
            + "\(rect.width),\(rect.height)|\(shown.guide)|\(mask.signature)|\(scale)|\(tight)"
        alphaLock.lock()
        let hit = inkCache[key]
        alphaLock.unlock()
        if let hit { return hit }
        guard rect.width > 0, rect.height > 0,
              let bitmap = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // 渲染坐标（左上原点）→ tile 位图（左下原点，第 0 行在上）。
        let sx: CGFloat = CGFloat(pw) / rect.width
        let sy: CGFloat = CGFloat(ph) / rect.height
        bitmap.translateBy(x: 0, y: CGFloat(ph))
        bitmap.scaleBy(x: sx, y: -sy)
        bitmap.translateBy(x: -rect.minX, y: -rect.minY)
        bitmap.addPath(ink)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fillPath()
        guard let inkImage = bitmap.makeImage() else { return nil }
        let target = CGRect(x: 0, y: 0, width: pw, height: ph)
        let inkMask = CIImage(cgImage: inkImage)
        let a = CIImage(cgImage: alpha)
        let color = CIImage(cgImage: clean).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: shown.tile), kCIInputMaskImageKey: inkMask]).cropped(to: target)
        let choked = steepened(a, gain: 2, offset: -0.5).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: inkMask]).cropped(to: target)
        guard let image = ciContext.createCGImage(color, from: target, format: .RGBA8, colorSpace: srgb),
              let matte = ciContext.createCGImage(choked, from: target, format: .L8,
                                                  colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        guard pw * ph <= cutCacheMaxPixels else { return (image, matte) }
        alphaLock.lock()
        if inkCache.count > 8 { inkCache.removeAll() }
        inkCache[key] = (image, matte)
        alphaLock.unlock()
        return (image, matte)
    }

    private static var inkCache: [String: (image: CGImage, alpha: CGImage)] = [:]

    /// 墨的轮廓指纹：每个路径点（FNV-1a，按确切值）—— 字、字号、位置变了键就变。
    private static func inkSignature(_ path: CGPath) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ v: Double) {
            var bits = v.bitPattern
            for _ in 0..<8 {
                h ^= bits & 0xff
                h = h &* 0x100000001b3
                bits >>= 8
            }
        }
        path.applyWithBlock { element in
            let e = element.pointee
            mix(Double(e.type.rawValue))
            let n: Int
            switch e.type {
            case .moveToPoint, .addLineToPoint: n = 1
            case .addQuadCurveToPoint: n = 2
            case .addCurveToPoint: n = 3
            default: n = 0
            }
            for i in 0..<n {
                mix(Double(e.points[i].x))
                mix(Double(e.points[i].y))
            }
        }
        return String(h, radix: 16)
    }

    /// 软边压陡：a' = clamp(gain·a + offset)（灰度蒙版三个通道一样）。
    private static func steepened(_ image: CIImage, gain: Double, offset: Double) -> CIImage {
        let g = CGFloat(gain)
        let o = CGFloat(offset)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0), "inputBiasVector": CIVector(x: o, y: o, z: o, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    /// 白色贴纸剪影：alpha 往外长 grow 像素、边压利落（贴纸是剪出来的，不是一圈光晕），填白（RGBA，带 alpha）。
    private static func silhouette(_ alpha: CGImage, grow: Double, scale: Double) -> CGImage? {
        let target = CGRect(x: 0, y: 0, width: alpha.width, height: alpha.height)
        let grown = CIImage(cgImage: alpha).clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(0.5, grow)])
        let a = steepened(grown, gain: 3, offset: -1).applyingGaussianBlur(sigma: max(0.3, 0.6 * scale))
            .cropped(to: target)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: target)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: target)
        let out = white.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear,
                                                                       kCIInputMaskImageKey: a])
        return ciContext.createCGImage(out, from: target, format: .RGBA8, colorSpace: srgb)
    }

    struct Edges {
        var left: CGFloat = 0
        var top: CGFloat = 0
        var right: CGFloat = 0
        var bottom: CGFloat = 0
    }

    /// 能铺出血的：普通矩形照片格，没有相纸/胶片框、细线（细线会被裁掉），不是完整显示 ——
    /// 完整显示 + 本图模糊填可以：铺进出血的是模糊底，清楚的照片还在成品区里。
    private static func canBleed(_ cell: CollageCell, style: CollageStyle) -> Bool {
        (cell.shape ?? style.shape) == .rect && style.border == .none && (!cell.contain || cell.containBlur)
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

    /// 这一格导出时取景往出血外延多少（CollageCover 定取景时先留出来）：和 render 里算 extend、drawPhoto 外延是同一套
    /// 判断，只是按成品尺寸（1 倍）算、和这次带不带出血无关 —— 预览、导出留的一样，所以是同一个决定。
    /// 多留 1 像素（导出放大时出血按缩放取整，会比 1 倍的大半个像素）。不外延 = 空。
    static func bleedReserve(cell: CollageCell, frameRect: CGRect, project: CollageProject) -> CollageCrop.Reserve {
        let canvas = project.canvas
        let style = project.style
        let fullBleed = style.insets.map { min($0.top, $0.bottom, $0.inner, $0.outer) <= 0.0001 }
            ?? (style.margin <= 0.0001)
        guard canvas.bleed > 0, fullBleed, canBleed(cell, style: style), !cell.contain else { return .init() }
        let trim = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        guard let e = bleedEdges(frameRect, trim: trim, bleed: CGFloat(canvas.bleed)) else { return .init() }
        let area = CollageCrop.photoArea(cell: cell, rect: frameRect, style: style)
        let aw = max(1, Double(area.width))
        let ah = max(1, Double(area.height))
        func share(_ v: CGFloat, _ side: Double) -> Double { v > 0 ? (Double(v) + 1) / side : 0 }
        return CollageCrop.Reserve(left: share(e.left, aw), top: share(e.top, ah), right: share(e.right, aw),
                                   bottom: share(e.bottom, ah))
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

    /// 卡纸上那道细线离照片多远（这次渲染的像素）：印刷画布照装裱的 3–6 mm 取 4.5 mm，社交画布按短边 0.8%
    /// （1440 宽约 12 像素）。画的时候再收到卡纸宽的一半多一点以内（缩略图里卡纸只有几像素宽，线不能画到照片外面去）。
    struct Keyline {
        var gap: CGFloat
        /// 印刷画布：细线离照片至少 3mm（装裱露边 3–6mm 的下限）；社交画布 = nil（按卡纸宽收）。
        var minGap: CGFloat?
        /// 放到 3mm 之后细线外面至少还要剩多少卡纸（1.5mm，且不少于卡纸宽的三成）：剩得太少，细线就成了卡纸的外框，
        /// 不像双层卡纸露边 —— 那样宁可照旧按卡纸宽收。
        var minOutside: CGFloat?

        init(canvas: CollageCanvas, scale: Double) {
            let base: Double = canvas.isPrint ? canvas.pixels(mm: 4.5) : canvas.shortSide * 0.008
            gap = CGFloat(base * scale)
            minGap = canvas.isPrint ? CGFloat(canvas.pixels(mm: 3) * scale) : nil
            minOutside = canvas.isPrint ? CGFloat(canvas.pixels(mm: 1.5) * scale) : nil
        }
    }

    /// 卡纸窗口的细线：照片外一圈（假双层卡纸露边），细线色；深色卡纸上用卡纸色提亮一截。
    private static func drawKeyline(_ ctx: CGContext, photo: CGRect, outer: CGRect, inner: CGRect, short: Double,
                                    keyline: Keyline, style: CollageStyle) {
        let lw = max(1, CGFloat(short) / 1600)
        let side = min(inner.minX - outer.minX, inner.minY - outer.minY, outer.maxX - inner.maxX)
        let room = side * 0.55 - lw
        guard room >= 1 else { return }
        var gap = min(keyline.gap, room)
        // 印刷画布的小格子：卡纸窄，按「卡纸一半」收会把线收到照片外 3mm 以内（A4 小格子 2.2mm，婚礼相册的三联小图也是）。
        // 放到 3mm 之后线外面还剩得下一截卡纸（≥ 1.5mm、≥ 卡纸宽的三成）才放；更窄的卡纸照旧收（不然线就贴着卡纸外沿，
        // 成了卡纸的描边）。和缩放无关：预览、导出同一个位置。
        if let floor = keyline.minGap, let rest = keyline.minOutside, gap < floor {
            let outside: CGFloat = side - floor - lw
            if outside >= max(rest, side * 0.3) { gap = floor }
        }
        let mat = style.borderColor
        let color = mat.luminance < 0.35 ? mat.mixed(with: .white, 0.32) : CollageColor.rule
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor(alpha: 0.9))
        ctx.setLineWidth(lw)
        ctx.stroke(photo.insetBy(dx: -(gap + lw / 2), dy: -(gap + lw / 2)))
        ctx.restoreGState()
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

    /// screen = 照片加网（CollageScreening）：色调之后加网、不再锐化；nil = 照旧锐化（和以前逐像素一样）。
    static func cellImage(photo: CollagePhotoRef, window: CollageCrop.Window, width: Int, height: Int,
                          sharpen: Double, radius: Double, export: Bool, report: RenderReport? = nil,
                          color: CollageLooks.Ops? = nil, screen: CollageScreening.Spec? = nil) -> CGImage? {
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
        if let screen {
            // 加网替代锐化：锐化会在网点边上起白边，网点本身就是最硬的边。
            output = CollageScreening.apply(output, spec: screen, extent: target)
        } else if sharpen > 0, let usm = CIFilter(name: "CIUnsharpMask") {
            usm.setValue(output.clampedToExtent(), forKey: kCIInputImageKey)
            usm.setValue(radius, forKey: kCIInputRadiusKey)
            usm.setValue(sharpen, forKey: kCIInputIntensityKey)
            if let sharpened = usm.outputImage?.cropped(to: target) { output = sharpened }
        }
        return ciContext.createCGImage(output, from: target, format: .RGBA8, colorSpace: srgb)
    }

    // MARK: - 背景

    /// 这一页的主图 = 分数最高的那张（底色取色、模糊底、渐变底、统一色调都认它）。
    static func heroPhoto(_ ids: [String], photos: [String: CollagePhotoRef]) -> CollagePhotoRef? {
        ids.compactMap { photos[$0] }.max { $0.score < $1.score }
    }

    /// 页面底色（模糊底、渐变底时是它们的代表色）：占位框深浅、压字落在留白上时判深字浅字、
    /// 投影底下垫的颜色都按它。拖缝、拖字每一帧都会问，只用缓存过的小样统计。
    static func backgroundColor(project: CollageProject, pagePhotoIDs ids: [String],
                                photos: [String: CollagePhotoRef]) -> CollageColor {
        let style = project.style
        guard style.backgroundMode != .solid, let hero = heroPhoto(ids, photos: photos) else { return style.background }
        switch style.backgroundMode {
        case .solid:
            return style.background
        case .fromPhoto:
            // 取的是调色之后的主图颜色（套了黑白，底色不能还带着原图的暖色）。
            guard let avg = gradedAverage(hero, style: style) else { return style.background }
            // 往纸白靠、压饱和：只要一点点色温呼应，不能把底色染成照片的颜色。
            let grey = (avg.r + avg.g + avg.b) / 3
            let muted = avg.mixed(with: CollageColor(r: grey, g: grey, b: grey), 0.45)
            if style.background.luminance < 0.4 {
                return style.background.mixed(with: muted, 0.22)
            }
            return style.background.mixed(with: muted, 0.16)
        case .blurPhoto:
            guard let avg = gradedAverage(hero, style: style) else { return style.background }
            return avg.mixed(with: style.background, washShare(paper: style.background, photo: avg,
                                                              minimum: blurWashMinimum))
        case .gradient:
            guard let colors = gradientColors(hero, style: style) else { return style.background }
            return colors.top.mixed(with: colors.bottom, 0.5)
        }
    }

    /// 模糊底上至少盖多少纸色（再少照片就抢戏了）。
    static let blurWashMinimum = 0.35

    /// 照片色上要盖多少纸色（0…0.9）：至少 minimum；照片比浅纸暗太多、或比深纸亮太多时多盖一点 ——
    /// 版面上的字是按纸色配的（浅纸深字、深纸浅字），换成照片底也得看得清。
    static func washShare(paper: CollageColor, photo: CollageColor, minimum: Double) -> Double {
        let p = paper.luminance
        let c = photo.luminance
        let tolerance = 0.2
        var share = minimum
        if p >= 0.5 {
            let target = p - tolerance
            if c < target { share = max(share, (target - c) / max(1e-3, p - c)) }
        } else {
            let target = p + tolerance
            if c > target { share = max(share, (c - target) / max(1e-3, c - p)) }
        }
        return min(0.9, max(0, share))
    }

    /// 照片做底（盖在纯色上、纸纹下面，铺满出血）：主图大幅模糊 + 一层纸色（毛玻璃），或主图上下两截
    /// 颜色的竖向渐变。
    private static func drawBackdrop(_ ctx: CGContext, style: CollageStyle, hero: CollagePhotoRef,
                                     ops: CollageLooks.Ops?, width: Int, height: Int) {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        switch style.backgroundMode {
        case .blurPhoto:
            guard let blurred = blurredBackdrop(hero, ops: ops) else { return }
            ctx.saveGState()
            ctx.interpolationQuality = .high
            drawImageTopLeft(ctx, blurred, aspectFill(Double(blurred.width) / Double(max(1, blurred.height)), in: full))
            ctx.restoreGState()
            if let avg = gradedAverage(hero, style: style) {
                let wash = washShare(paper: style.background, photo: avg, minimum: blurWashMinimum)
                ctx.setFillColor(style.background.cgColor(alpha: wash))
                ctx.fill(full)
            }
        case .gradient:
            guard let colors = gradientColors(hero, style: style),
                  let gradient = CGGradient(colorsSpace: srgb, colors: [colors.top.cgColor, colors.bottom.cgColor] as CFArray,
                                            locations: [0, 1]) else { return }
            ctx.saveGState()
            ctx.clip(to: full)
            // 左上原点：y = 0 是上沿。
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(height)),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        case .solid, .fromPhoto:
            break
        }
    }

    /// 水印「自动深浅」看的页底亮度（CollageWatermarks.Paper）。只有整页层开着自动、底是主图模糊 / 渐变时才
    /// 按位置算（drawBackdrop 同一套：模糊图按铺法铺满带出血的整页、盖 washShare 那么多纸色；渐变从出血上沿到
    /// 下沿）；别的时候整页就是代表色那一个亮度。
    static func markPaper(project: CollageProject, pagePhotoIDs: [String], photos: [String: CollagePhotoRef],
                          background: CollageColor, colorOps: [String: CollageLooks.Ops]) -> CollageWatermarks.Paper {
        var paper = CollageWatermarks.Paper(flat: background.luminance)
        let style = project.style
        guard project.watermark?.page?.contrast == .auto, style.backgroundMode.usesPaperTint,
              let hero = heroPhoto(pagePhotoIDs, photos: photos) else { return paper }
        let canvas = project.canvas
        let b = CGFloat(canvas.bleed)
        let full = CGRect(x: -b, y: -b, width: CGFloat(canvas.width) + 2 * b, height: CGFloat(canvas.height) + 2 * b)
        switch style.backgroundMode {
        case .blurPhoto:
            guard let blurred = blurredBackdrop(hero, ops: colorOps[hero.id]),
                  let grid = backdropGrid(blurred, key: CollageVision.cacheKey(hero) + "#" + opsKey(colorOps[hero.id]))
            else { return paper }
            let rect = aspectFill(Double(blurred.width) / Double(max(1, blurred.height)), in: full)
            let wash = gradedAverage(hero, style: style)
                .map { washShare(paper: style.background, photo: $0, minimum: blurWashMinimum) } ?? 0
            paper.blur = (grid, rect, wash, style.background.luminance)
        case .gradient:
            guard let colors = gradientColors(hero, style: style) else { return paper }
            paper.gradient = (colors.top.luminance, colors.bottom.luminance, full.minY, full.maxY)
        case .solid, .fromPhoto:
            break
        }
        return paper
    }

    private static var backdropGrids: [String: CollageOverlays.Grid] = [:]

    /// 模糊底那张图（已调色、已模糊）的亮度网格，按同一个键缓存：拖缝每帧都要问，不能每次都缩一遍。
    private static func backdropGrid(_ image: CGImage, key: String) -> CollageOverlays.Grid? {
        backdropLock.lock()
        let hit = backdropGrids[key]
        backdropLock.unlock()
        if let hit { return hit }
        guard let grid = CollageOverlays.grid(of: image, window: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return nil }
        backdropLock.lock()
        if backdropGrids.count > 24 { backdropGrids.removeAll() }
        backdropGrids[key] = grid
        backdropLock.unlock()
        return grid
    }

    /// 铺满 rect（多出来的裁掉），居中。
    static func aspectFill(_ aspect: Double, in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0, aspect > 0 else { return rect }
        let rectAspect = Double(rect.width / rect.height)
        if aspect > rectAspect {
            let w = Double(rect.height) * aspect
            return CGRect(x: Double(rect.midX) - w / 2, y: Double(rect.minY), width: w, height: Double(rect.height))
        }
        let h = Double(rect.width) / aspect
        return CGRect(x: Double(rect.minX), y: Double(rect.midY) - h / 2, width: Double(rect.width), height: h)
    }

    private static let backdropLock = NSLock()
    private static var backdropCache: [String: CGImage] = [:]

    /// 主图（调过色）缩到 512、大幅高斯模糊、稍微降饱和 —— 整页模糊底和「完整显示」格子的模糊填充共用。
    /// 只在小图上算：预览、导出一个样子；放大铺满也看不出颗粒（模糊半径比放大倍数大得多）。按照片 +
    /// 调色缓存：拖缝、拖字每一帧重画都不会重新解码。
    static func blurredBackdrop(_ photo: CollagePhotoRef, ops: CollageLooks.Ops?) -> CGImage? {
        let key = CollageVision.cacheKey(photo) + "#" + opsKey(ops)
        backdropLock.lock()
        let hit = backdropCache[key]
        backdropLock.unlock()
        if let hit { return hit }
        guard let image = CollageImages.preview(photo, need: 512) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sigma = Double(max(image.width, image.height)) * 0.045
        let graded = CollageLooks.apply(CIImage(cgImage: image), ops: ops)
        let blurred = graded.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
        guard let out = ciContext.createCGImage(blurred, from: extent, format: .RGBA8, colorSpace: srgb) else { return nil }
        backdropLock.lock()
        if backdropCache.count > 24 { backdropCache.removeAll() }
        backdropCache[key] = out
        backdropLock.unlock()
        return out
    }

    private static func opsKey(_ ops: CollageLooks.Ops?) -> String {
        guard let ops, !ops.isIdentity else { return "-" }
        let gains = ops.gains.map { $0.map { String(Int(($0 * 1000).rounded())) }.joined(separator: ",") } ?? ""
        return "\(ops.look.rawValue)|\(Int((ops.strength * 20).rounded()))|\(gains)"
    }

    /// 主图（调过色）的平均色。
    private static func gradedAverage(_ hero: CollagePhotoRef, style: CollageStyle) -> CollageColor? {
        guard let raw = averageColor(hero) else { return nil }
        let g = CollageLooks.grade(raw.r, raw.g, raw.b, look: style.look, strength: style.lookStrength)
        return CollageColor(r: g.0, g: g.1, b: g.2)
    }

    /// 渐变的上下两色：主图上、下两截的代表色（调过色），压一点饱和，再按「字看得清」往纸色靠。
    static func gradientColors(_ hero: CollagePhotoRef, style: CollageStyle) -> (top: CollageColor, bottom: CollageColor)? {
        guard let bands = bandColors(hero) else { return nil }
        func prepare(_ c: CollageColor) -> CollageColor {
            let g = CollageLooks.grade(c.r, c.g, c.b, look: style.look, strength: style.lookStrength)
            var color = CollageColor(r: g.0, g: g.1, b: g.2)
            let grey = (color.r + color.g + color.b) / 3
            color = color.mixed(with: CollageColor(r: grey, g: grey, b: grey), 0.15)
            return color.mixed(with: style.background, washShare(paper: style.background, photo: color, minimum: 0.35))
        }
        return (prepare(bands.top), prepare(bands.bottom))
    }

    /// 一截画面的代表色：有颜色的像素按色相分 12 档、按色度平方投票，取最重的一档（连两边邻档）的平均，
    /// 再和整截的平均色按 6:4 混 —— 成片的天空、衣服的颜色出得来，不会被灰石头平均成一片泥灰；
    /// 整截都是灰的就是平均色。
    private static func representative(_ px: [(Double, Double, Double)]) -> CollageColor {
        var mean = (0.0, 0.0, 0.0)
        for p in px {
            mean.0 += p.0
            mean.1 += p.1
            mean.2 += p.2
        }
        let n = Double(max(1, px.count))
        let avg = CollageColor(r: mean.0 / n, g: mean.1 / n, b: mean.2 / n)
        var weight = [Double](repeating: 0, count: 12)
        var sum = [[Double]](repeating: [0, 0, 0], count: 12)
        for (r, g, b) in px {
            let mx = max(r, g, b)
            let mn = min(r, g, b)
            let c = mx - mn
            guard c > 0.08 else { continue }
            var h: Double
            if mx == r {
                h = ((g - b) / c).truncatingRemainder(dividingBy: 6)
            } else if mx == g {
                h = (b - r) / c + 2
            } else {
                h = (r - g) / c + 4
            }
            if h < 0 { h += 6 }
            let bin = min(11, max(0, Int(h * 2)))
            let w = c * c
            weight[bin] += w
            sum[bin][0] += r * w
            sum[bin][1] += g * w
            sum[bin][2] += b * w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else { return avg }
        var total = 0.0
        var acc = [0.0, 0.0, 0.0]
        for d in [-1, 0, 1] {
            let i = (best + d + 12) % 12
            total += weight[i]
            for k in 0..<3 { acc[k] += sum[i][k] }
        }
        let dominant = CollageColor(r: acc[0] / total, g: acc[1] / total, b: acc[2] / total)
        return avg.mixed(with: dominant, 0.6)
    }

    private static let averageLock = NSLock()
    private static var averageCache: [String: CollageColor] = [:]
    private static var bandCache: [String: (top: CollageColor, bottom: CollageColor)] = [:]

    /// 主图上、下两截（各约三分之一）的代表色（按照片缓存）。
    private static func bandColors(_ photo: CollagePhotoRef) -> (top: CollageColor, bottom: CollageColor)? {
        let key = CollageVision.cacheKey(photo)
        averageLock.lock()
        let hit = bandCache[key]
        averageLock.unlock()
        if let hit { return hit }
        let side = 16
        guard let pixels = sampleGrid(photo, side: side) else { return nil }
        // 位图内存第 0 行是图的上沿。
        func band(_ rows: Range<Int>) -> CollageColor {
            var px: [(Double, Double, Double)] = []
            for y in rows {
                for x in 0..<side {
                    let i = (y * side + x) * 4
                    px.append((Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255))
                }
            }
            return representative(px)
        }
        let bands = (top: band(0..<5), bottom: band((side - 5)..<side))
        averageLock.lock()
        if bandCache.count > 512 { bandCache.removeAll() }
        bandCache[key] = bands
        averageLock.unlock()
        return bands
    }

    /// 主图缩成 8×8 的 RGBA 小样（256 预览来的）。
    private static func sample8(_ photo: CollagePhotoRef) -> [UInt8]? {
        sampleGrid(photo, side: 8)
    }

    private static func sampleGrid(_ photo: CollagePhotoRef, side: Int) -> [UInt8]? {
        guard let image = CollageImages.preview(photo, need: 256) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? pixels : nil
    }

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
        guard let pixels = sample8(photo) else { return nil }
        let side = 8
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

    /// 纸纹压在照片上（style.paperOverPhotos）：照片的白往纸色乘一点（像印在这张纸上；加了网的照片白已经是纸色，
    /// 不再乘；深色底不乘），再把页面那块纸纹柔光叠上去（同一张纸纹、同样跟着缩放，和底下的纸纹接得上）。
    /// clips = 照片画出来的那块（这次渲染的坐标）；在相纸图层里画时是图层的局部坐标，tileScale 另给。
    static func drawPaperOver(_ ctx: CGContext, clips: [CGPath], intensity: Double, paper: CollageColor, tint: Bool,
                              scale: Double, tileScale: Double? = nil) {
        let s = min(1, max(0, intensity))
        guard s > 0, !clips.isEmpty else { return }
        ctx.saveGState()
        for c in clips { ctx.addPath(c) }
        ctx.clip()
        let bounds = ctx.boundingBoxOfClipPath
        if tint, paper.luminance > 0.55 {
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(paper.cgColor(alpha: s * 0.6))
            ctx.fill(bounds)
        }
        if let tile = grainTile {
            let k: Double = tileScale ?? max(0.2, min(1, scale))
            let side = CGFloat(Double(tile.width) * k)
            ctx.setBlendMode(.softLight)
            ctx.setAlpha(CGFloat(s * 0.55))
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
        }
        ctx.restoreGState()
    }

    static func halftoneRecord(_ screen: CollageScreening.Spec, owner: String, photoID: String) -> HalftoneRecord {
        HalftoneRecord(owner: owner, photoID: photoID, screen: screen.halftone.screen.rawValue, pitchPx: screen.pitchPx,
                       screened: screen.screened, angle: screen.halftone.angle,
                       ink: CollageScreening.hex(screen.halftone.ink), paper: CollageScreening.hex(screen.paper))
    }

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
        // 相册中缝：避让带的两条边（淡一点）—— 脸、字、相纸都不进这条带；胶装比平铺宽。
        if canvas.seams == .fold, let fold = CollageLayout.seamLines(canvas).first {
            let s = fold.applying(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                .offsetBy(dx: CGFloat(bleed), dy: CGFloat(bleed))
            ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.75, blue: 0.9, alpha: 0.38))
            for x in [s.minX, s.maxX] {
                ctx.move(to: CGPoint(x: x, y: s.minY))
                ctx.addLine(to: CGPoint(x: x, y: s.maxY))
            }
            ctx.strokePath()
        }
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
                                  scale: Double, trim: CGRect, bleed: Int, windows: [[Int]: CollageCrop.Window] = [:]) {
        let lw = max(2, CGFloat(canvas.shortSide * scale) / 500)
        ctx.saveGState()
        ctx.setLineWidth(lw)
        let short = canvas.shortSide * scale
        for frame in geo.frames where frame.cell.kind == .photo {
            guard let id = frame.cell.photoID, let photo = photos[id] else { continue }
            let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: framingFrames,
                                                         photos: photos, tight: style.tightSmallCells)
            let inner = CollageCrop.photoArea(cell: frame.cell, rect: frame.rect.cgRect, style: style)
            let window = windows[frame.path]
                ?? CollageCrop.window(for: photo, cell: frame.cell, cellAspect: CollageCrop.aspect(of: inner),
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
