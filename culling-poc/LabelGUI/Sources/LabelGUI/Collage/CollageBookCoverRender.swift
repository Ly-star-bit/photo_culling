import Foundation
import CoreGraphics
import CoreText
import ImageIO

// MARK: - 相册封面（C3：渲染、导出）
//
// 整张封面 = 封底 | 书脊 | 封面拼成看得见的那块（trim），四周再补包边 + 出血：
// - 封面那一页：CollageRender 照常渲（画布换成单页、没有中缝，CollageBookCover.frontCanvas），字按安全区退、
//   取景按格子算 —— 和编辑时画布上看到的是同一张；
// - 封底：留白，或者一张小照片（完整显示）+ 一行字，同样走 CollageRender（版心收窄、底色跟封面）；
// - 书脊：封面的底色 + 书脊字（中文一个个立着从上往下排，拉丁字母、数字整段转 90° 从上往下读）；
// - 包边、出血：把看得见的那块四条边往外补（mirrorEdges）：照片格贴着成品边（零边距铺满）的那几段镜像出去，别处铺底色。不让照片自己往外铺：包边 15mm 加出血 3mm 一边 18mm，照片往外延不够时渲染器会按放大后的格子重新取景
//   （CollageRender.drawPhoto 的铺出血），脸可能被挪进包边、看得见的那块也和预览不一样了。镜像不动看得见的那块（预览
//   什么样、印出来什么样），翻过板边接得上。底色那一段不镜像：边距比包边窄时（默认 30cm 册子边距 13.5mm < 18mm）
//   镜像会把照片的一条边翻到包边最外面，看着像出了错。
// 渲染只收值类型（工程、路人信息、选项），任何线程都能跑；store 的预览、导出、命令行、文档面板的缩略图都调这里。
enum CollageBookCoverRender {

    // MARK: 入口

    /// 渲染整张封面。options 和 CollageRender 同一套：scale（1 = 成品像素）、includeBleed（true = 带包边和出血的整张，
    /// false = 只要看得见的那块：封底 | 书脊 | 封面）、guides（编辑参考线：折线、书脊、安全区）、placeholders（空格子画虚线）、
    /// export、watermark（封面那一页的水印照工程；封底不画水印）、report（封面、封底的出图记录：缺图、用了预览图）。
    /// 工程不是相册、没有封面 = nil。看版 PDF（P5）要封面放第一页时就调这个。
    static func render(project: CollageProject, hints: [String: CollageCrop.Hints],
                       options: CollageRender.Options) -> CGImage? {
        guard project.mode == .album, let cover = project.bookCover else { return nil }
        return render(cover: cover, project: project, hints: hints, options: options)
    }

    /// failFront：自检用，封面那一页当成渲染失败。
    static func render(cover: CollageBookCover, project: CollageProject, hints: [String: CollageCrop.Hints],
                       options: CollageRender.Options, failFront: Bool = false) -> CGImage? {
        let canvas = project.canvas
        let spreads = project.pages.count
        let scale = options.scale
        let layout = cover.layout(canvas: canvas, spreads: spreads, scale: scale)
        guard layout.pageW > 0, layout.pageH > 0 else { return nil }
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }

        // 1. 封面那一页（画布换成单页）。pages 清空：占位符 {no} 按页 id、再按树找第几页 —— 封面不是哪个跨页，
        // 「按扉页重做」出来的树又常和扉页那一页一模一样，不清空 {no} 会印成那个跨页的页码。
        var frontProject = project
        frontProject.canvas = CollageBookCover.frontCanvas(canvas)
        frontProject.pages = []
        var pageOptions = options
        pageOptions.includeBleed = false
        pageOptions.guides = false
        pageOptions.debug = false
        pageOptions.region = nil
        let frontImage = failFront ? nil
            : CollageRender.render(page: cover.editPage, project: frontProject, hints: hints, options: pageOptions)
        // 导出时封面那一页渲不出来：不出一张只有底色和书脊字的「封面」（优化分析 A12：以前照常写文件、不报错，
        // 最容易直接发给印厂）。预览、缩略图照旧画剩下的（书脊、封底还看得到）。
        if frontImage == nil, options.export { return nil }
        // 书脊、封底的底色跟封面那一页（取色底时跟它的主图走）。
        let bg = CollageRender.backgroundColor(project: frontProject, pagePhotoIDs: cover.front.photoIDs, photos: photos)

        // 2. 封底（不画水印；读不了原图照样记进 report：导出要提示）。
        var backOptions = pageOptions
        backOptions.watermark = false
        let backImage = backPage(cover.back, project: frontProject, background: bg, hints: hints, options: backOptions)

        // 3. 看得见的那块：封底 | 书脊 | 封面。
        let trimW = 2 * layout.pageW + layout.spine
        let trimH = layout.pageH
        guard let ctx = CollageRender.makeContext(width: trimW, height: trimH) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(trimH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: trimW, height: trimH))
        if let backImage {
            CollageRender.drawImageTopLeft(ctx, backImage, CGRect(x: 0, y: 0, width: layout.pageW, height: layout.pageH))
        }
        if let frontImage {
            CollageRender.drawImageTopLeft(ctx, frontImage, CGRect(x: layout.pageW + layout.spine, y: 0,
                                                                   width: layout.pageW, height: layout.pageH))
        }
        let spineLocal = CGRect(x: layout.pageW, y: 0, width: layout.spine, height: layout.pageH)
        let vars = spineVariables(cover: cover, project: frontProject, photos: photos)
        if let spine = spineLayout(cover: cover, vars: vars, rect: spineLocal, spineMM: cover.spineWidthMM(spreads: spreads),
                                   canvas: canvas, scale: scale) {
            drawSpine(spine, ctx: ctx, color: spineInk(bg))
        }
        guard let trim = ctx.makeImage() else { return nil }

        // 4. 包边、出血：镜像出去。
        let full: CGImage
        let offset: CGFloat
        if options.includeBleed, layout.extent > 0 {
            let spans = frontEdgeSpans(cover: cover, project: project, layout: layout, scale: scale)
            guard let sheet = mirrorEdges(trim, extent: layout.extent, background: bg, spans: spans) else { return nil }
            full = sheet
            offset = CGFloat(layout.extent)
        } else {
            full = trim
            offset = 0
        }
        guard options.guides else { return full }
        return drawGuides(full, layout: layout, offset: offset, canvas: canvas, scale: scale)
    }

    // MARK: 封底

    /// 封底的版：一张小照片（完整显示，版心收到页宽一半左右）+ 下面一行字；只有照片 / 只有字也行；留白 = nil（只有底色）。
    static func backTree(_ back: CollageBookCoverBack, ink: CollageColor) -> CollageNode? {
        let line = back.text.trimmingCharacters(in: .whitespaces)
        var photo = CollageCell.photo(back.photoID)
        photo.contain = true
        let text = CollageText(lines: [CollageTextLine(line, font: .songti, weight: .light, size: 0.016, tracking: 0.2,
                                                       color: ink)],
                               vertical: false, alignH: .center, alignV: .center)
        switch (back.photoID != nil, !line.isEmpty) {
        case (true, true): return .split(.column, 0.84, .leaf(photo), .leaf(.text(text)))
        case (true, false): return .leaf(photo)
        case (false, true): return .split(.column, 0.84, .leaf(CollageCell(kind: .empty)), .leaf(.text(text)))
        case (false, false): return nil
        }
    }

    /// 封底的样式：照工程的（色调、锐化、边框），版心四周收 26% 短边（小照片），底色定成封面那一页的（纯色）。
    static func backStyle(_ style: CollageStyle, background: CollageColor) -> CollageStyle {
        var s = style
        s.margin = 0.26
        s.insets = nil
        s.gutter = 0.02
        s.backgroundMode = .solid
        s.background = background
        return s
    }

    private static func backPage(_ back: CollageBookCoverBack, project frontProject: CollageProject, background: CollageColor,
                                 hints: [String: CollageCrop.Hints], options: CollageRender.Options) -> CGImage? {
        guard let root = backTree(back, ink: spineInk(background)) else { return nil }
        var p = frontProject
        p.style = backStyle(p.style, background: background)
        return CollageRender.render(page: CollagePage(root: root), project: p, hints: hints, options: options)
    }

    // MARK: 书脊

    /// 书脊字的颜色：深底用纸白，浅底用墨色。
    static func spineInk(_ background: CollageColor) -> CollageColor {
        background.luminance < 0.45 ? CollageColor.paper : CollageColor.ink
    }

    /// 书脊字展开占位符用的值：和封面那一页同一份（{title}、{date} 按封面的照片，没有照片按托盘；{no} = 01，见 render
    /// 里清空 pages 那一句）。
    static func spineVariables(cover: CollageBookCover, project: CollageProject,
                               photos: [String: CollagePhotoRef]) -> [String: String] {
        var p = project
        p.pages = []
        return CollageTypeset.variables(project: p, root: cover.front, photos: photos,
                                        pagePhotoIDs: cover.front.photoIDs, pageID: cover.id)
    }

    /// 一段字：立着排（中日韩文字，一个字一格）还是整段转 90°（拉丁字母、数字、标点、空格）。
    struct SpineRun: Equatable {
        var text: String
        var upright: Bool
    }

    /// 中日韩文字（汉字、假名、谚文、全角标点）立着排，其余（拉丁字母、数字、半角标点、空格）连成一段转 90°。
    static func isUpright(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { s in
            switch s.value {
            case 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x31BF, 0x31F0...0x31FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    /// 按立着 / 转着切段（首尾空白去掉；转着的那段里中间的空格留着）。
    static func spineRuns(_ s: String) -> [SpineRun] {
        var out: [SpineRun] = []
        for ch in s.trimmingCharacters(in: .whitespacesAndNewlines) where !ch.isNewline {
            let upright = isUpright(ch)
            if upright {
                out.append(SpineRun(text: String(ch), upright: true))
            } else if let last = out.last, !last.upright {
                out[out.count - 1].text.append(ch)
            } else {
                out.append(SpineRun(text: String(ch), upright: false))
            }
        }
        return out
    }

    /// 书脊上一个字 / 一段字画在哪（这次渲染的像素，左上原点）。upright：origin 是这个字的基线起点；转着的：origin 是
    /// 这一段基线的起点（最上面那一头），基线朝下、字头朝右（转 90° 从上往下读，封面在右边时字头冲着封面）。
    struct SpineGlyph {
        var text: String
        var upright: Bool
        var font: CTFont
        var origin: CGPoint
        /// 沿书脊（从上往下）占的长度、横着占的宽度。
        var length: CGFloat
        var thickness: CGFloat
        /// 这个字 / 这一段占的框（核对用：都在书脊里、从上往下排）。
        var frame: CGRect
    }

    struct SpineLayout {
        var glyphs: [SpineGlyph]
        var fontSize: CGFloat
    }

    /// 书脊字摆在哪：标题从书脊上头往下排，日期排在下头；两段放不下就一起缩小；书脊不到 6mm（或者没字）= nil。
    /// 字号 = 书脊宽的一半，最大不超过单页短边的 2.8%（书脊很厚时字也别太大）。上下各留安全区（至少书脊高的 6%）。
    /// spineMM：书脊实际多宽（按毫米判够不够印字，不按这次渲染取整后的像素：缩略图里差一个像素就翻过 6mm 那条线）。
    static func spineLayout(cover: CollageBookCover, vars: [String: String], rect: CGRect, spineMM: Double,
                            canvas: CollageCanvas, scale: Double) -> SpineLayout? {
        guard CollageBookCover.spineFitsText(spineMM), rect.height > 0, rect.width > 0 else { return nil }
        let title = spineRuns(CollageTypeset.fill(cover.spineTitle, vars: vars))
        let date = spineRuns(CollageTypeset.fill(cover.spineDate, vars: vars))
        guard !title.isEmpty || !date.isEmpty else { return nil }
        let pageShort = Double(min(CollageBookCover.pageWidth(canvas), canvas.height)) * scale
        var size = CGFloat(min(Double(rect.width) * 0.5, pageShort * 0.028))
        let margin = max(CGFloat(Double(canvas.safe) * scale), rect.height * 0.06)
        let room = rect.height - 2 * margin
        guard room > 0, size > 0 else { return nil }
        let dateRatio: CGFloat = 0.72
        func blockLength(_ runs: [SpineRun], _ s: CGFloat, _ weight: CollageWeight) -> CGFloat {
            runs.reduce(0) { $0 + measure($1, size: s, weight: weight).length }
        }
        // 两段加起来（中间至少空 1.5 个字）放不下：一起缩。
        let gap = (!title.isEmpty && !date.isEmpty) ? size * 1.5 : 0
        let need = blockLength(title, size, .regular) + blockLength(date, size * dateRatio, .light) + gap
        if need > room { size *= room / need }
        guard size >= 1 else { return nil }
        let cx = rect.midX
        var glyphs: [SpineGlyph] = []
        func place(_ runs: [SpineRun], from top: CGFloat, size s: CGFloat, weight: CollageWeight) {
            var y = top
            for run in runs {
                var g = measure(run, size: s, weight: weight)
                if run.upright {
                    // 一个字一格：字框居中在这一格里。
                    let ascent = CTFontGetAscent(g.font)
                    let descent = CTFontGetDescent(g.font)
                    let width = lineWidth(run.text, font: g.font, upright: true)
                    let baseline = y + (g.length - (ascent + descent)) / 2 + ascent
                    g.origin = CGPoint(x: cx - width / 2, y: baseline)
                    g.frame = CGRect(x: cx - g.thickness / 2, y: y, width: g.thickness, height: g.length)
                } else {
                    // 转 90°：字头朝 +x，基线朝 +y。字框（升部 + 降部）横着居中在书脊中线上。
                    let ascent = CTFontGetAscent(g.font)
                    let descent = CTFontGetDescent(g.font)
                    g.origin = CGPoint(x: cx - (ascent - descent) / 2, y: y)
                    g.frame = CGRect(x: g.origin.x - descent, y: y, width: ascent + descent, height: g.length)
                }
                glyphs.append(g)
                y += g.length
            }
        }
        place(title, from: rect.minY + margin, size: size, weight: .regular)
        let dateSize = size * dateRatio
        let dateLength = blockLength(date, dateSize, .light)
        place(date, from: rect.maxY - margin - dateLength, size: dateSize, weight: .light)
        return SpineLayout(glyphs: glyphs, fontSize: size)
    }

    private static func font(size: CGFloat, weight: CollageWeight) -> CTFont {
        CollageTypeset.font(.songti, weight, italic: false, size: size)
    }

    /// 不用 kCTVerticalFormsAttributeName：一个字一行横着画的时候，CoreText 会把竖排字形整个转 90°（那是给竖排的
    /// CTFrame 用的），书脊上的汉字就躺倒了。书脊标题里很少有括号、破折号，横排字形立着放就行。
    private static func attributed(_ s: String, font: CTFont, upright: Bool, color: CGColor? = nil) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return NSAttributedString(string: s, attributes: attrs)
    }

    private static func lineWidth(_ s: String, font: CTFont, upright: Bool) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(s, font: font, upright: upright))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 一段字沿书脊多长、横着多宽：立着的字一格 = 1.08 个字号（字与字之间留一点）；转着的 = 这一段的排版宽度。
    private static func measure(_ run: SpineRun, size: CGFloat, weight: CollageWeight) -> SpineGlyph {
        let f = font(size: size, weight: weight)
        let ascent = CTFontGetAscent(f)
        let descent = CTFontGetDescent(f)
        if run.upright {
            return SpineGlyph(text: run.text, upright: true, font: f, origin: .zero, length: size * 1.08,
                              thickness: max(size, lineWidth(run.text, font: f, upright: true)), frame: .zero)
        }
        return SpineGlyph(text: run.text, upright: false, font: f, origin: .zero,
                          length: lineWidth(run.text, font: f, upright: false), thickness: ascent + descent, frame: .zero)
    }

    /// 在左上原点（翻转过）的 context 里画书脊字。
    static func drawSpine(_ layout: SpineLayout, ctx: CGContext, color: CollageColor) {
        for g in layout.glyphs {
            let line = CTLineCreateWithAttributedString(attributed(g.text, font: g.font, upright: g.upright,
                                                                   color: color.cgColor))
            ctx.saveGState()
            if g.upright {
                // 回到 CoreText 的 y 朝上：(u, v) → (x + u, baseline − v)。
                ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: g.origin.x, ty: g.origin.y))
            } else {
                // 转 90°（从上往下读）：基线方向 u → +y，字头 v → +x。
                ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: g.origin.x, ty: g.origin.y))
            }
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: 包边、出血

    /// 看得见的那块四条边上，哪几段要镜像出去（其余铺底色）：下标是看得见的那块的像素（上、下边按 x，左、右边按 y），
    /// 四个角各自镜不镜。
    struct EdgeSpans: Equatable {
        var top: [Range<Int>] = []
        var bottom: [Range<Int>] = []
        var left: [Range<Int>] = []
        var right: [Range<Int>] = []
        var topLeft = false
        var topRight = false
        var bottomLeft = false
        var bottomRight = false

        /// 四条边、四个角全镜像（看得见的那块整张都是照片 / 照片做的底）。
        static func all(width: Int, height: Int) -> EdgeSpans {
            EdgeSpans(top: [0..<width], bottom: [0..<width], left: [0..<height], right: [0..<height],
                      topLeft: true, topRight: true, bottomLeft: true, bottomRight: true)
        }
    }

    /// 封面那一页上贴着成品边的照片格（零边距铺满）在看得见的那块的上、下、右边占的那几段 —— 只有这几段镜像出去，别处
    /// （边距里的底色、纸纹、格子之间的缝）铺底色。按格子算，不按像素认底色：纸纹（婚礼样式 grain 0.16）让底色那一圈每个
    /// 像素都不一样，按像素认就整圈镜像，把照片离边不到 18mm 的那一条翻到包边最外面。
    /// 模糊底、渐变底（照片做的底铺满封面那一页）：封面那一页的上、下、右边整段镜像。封底（版心收得很小）、书脊从不镜像。
    static func frontEdgeSpans(cover: CollageBookCover, project: CollageProject, layout: CollageBookCover.Layout,
                               scale: Double) -> EdgeSpans {
        let x0 = layout.pageW + layout.spine
        var spans = EdgeSpans()
        if project.style.backgroundMode.usesPaperTint {
            spans.top = [x0..<(x0 + layout.pageW)]
            spans.bottom = spans.top
            spans.right = [0..<layout.pageH]
            spans.topRight = true
            spans.bottomRight = true
            return spans
        }
        let canvas = CollageBookCover.frontCanvas(project.canvas)
        let frames = CollageLayout.pageGeometry(cover.front, canvas: canvas, style: project.style, scale: scale).frames
        for f in frames where f.cell.kind == .photo && !f.rect.isEmpty {
            let r = f.rect
            let top = r.y0 <= 1
            let bottom = r.y1 >= layout.pageH - 1
            let right = r.x1 >= layout.pageW - 1
            if top { spans.top.append((x0 + r.x0)..<(x0 + min(r.x1, layout.pageW))) }
            if bottom { spans.bottom.append((x0 + r.x0)..<(x0 + min(r.x1, layout.pageW))) }
            if right { spans.right.append(r.y0..<min(r.y1, layout.pageH)) }
            if top && right { spans.topRight = true }
            if bottom && right { spans.bottomRight = true }
        }
        return spans
    }

    /// 看得见的那块四条边各往外补 extent 像素（包边 + 出血）：spans 里的那几段（和挨着的角）镜像出去，翻过板边接得上；
    /// 别处铺 background。spans = nil：整圈镜像。
    static func mirrorEdges(_ trim: CGImage, extent e: Int, background: CollageColor, spans: EdgeSpans? = nil) -> CGImage? {
        let w = trim.width
        let h = trim.height
        guard e > 0, e <= w, e <= h, let ctx = CollageRender.makeContext(width: w + 2 * e, height: h + 2 * e) else {
            return e > 0 ? nil : trim
        }
        let s = spans ?? .all(width: w, height: h)
        let fullW = w + 2 * e
        let fullH = h + 2 * e
        ctx.interpolationQuality = .none
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: fullW, height: fullH))
        // 源、目标都按左上原点的像素坐标给；CGContext 本身是左下原点（y 朝上）。
        func put(_ src: CGRect, _ dst: CGRect, flipX: Bool, flipY: Bool) {
            guard src.width > 0, src.height > 0, let piece = trim.cropping(to: src) else { return }
            let y = CGFloat(fullH) - dst.maxY
            ctx.saveGState()
            ctx.translateBy(x: flipX ? dst.maxX : dst.minX, y: flipY ? y + dst.height : y)
            ctx.scaleBy(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
            ctx.draw(piece, in: CGRect(x: 0, y: 0, width: dst.width, height: dst.height))
            ctx.restoreGState()
        }
        let W = CGFloat(w), H = CGFloat(h), E = CGFloat(e)
        put(CGRect(x: 0, y: 0, width: W, height: H), CGRect(x: E, y: E, width: W, height: H), flipX: false, flipY: false)
        for r in s.top {
            let a = CGFloat(max(0, r.lowerBound)), n = CGFloat(min(w, r.upperBound)) - a
            put(CGRect(x: a, y: 0, width: n, height: E), CGRect(x: E + a, y: 0, width: n, height: E), flipX: false, flipY: true)
        }
        for r in s.bottom {
            let a = CGFloat(max(0, r.lowerBound)), n = CGFloat(min(w, r.upperBound)) - a
            put(CGRect(x: a, y: H - E, width: n, height: E), CGRect(x: E + a, y: E + H, width: n, height: E),
                flipX: false, flipY: true)
        }
        for r in s.left {
            let a = CGFloat(max(0, r.lowerBound)), n = CGFloat(min(h, r.upperBound)) - a
            put(CGRect(x: 0, y: a, width: E, height: n), CGRect(x: 0, y: E + a, width: E, height: n), flipX: true, flipY: false)
        }
        for r in s.right {
            let a = CGFloat(max(0, r.lowerBound)), n = CGFloat(min(h, r.upperBound)) - a
            put(CGRect(x: W - E, y: a, width: E, height: n), CGRect(x: E + W, y: E + a, width: E, height: n),
                flipX: true, flipY: false)
        }
        if s.topLeft { put(CGRect(x: 0, y: 0, width: E, height: E), CGRect(x: 0, y: 0, width: E, height: E), flipX: true, flipY: true) }
        if s.topRight {
            put(CGRect(x: W - E, y: 0, width: E, height: E), CGRect(x: E + W, y: 0, width: E, height: E), flipX: true, flipY: true)
        }
        if s.bottomLeft {
            put(CGRect(x: 0, y: H - E, width: E, height: E), CGRect(x: 0, y: E + H, width: E, height: E), flipX: true, flipY: true)
        }
        if s.bottomRight {
            put(CGRect(x: W - E, y: H - E, width: E, height: E), CGRect(x: E + W, y: E + H, width: E, height: E),
                flipX: true, flipY: true)
        }
        return ctx.makeImage()
    }

    // MARK: 参考线（只在编辑预览、缩略图里，不进导出）

    /// 折线（包边往里折的那一圈 = 看得见的那块的边）、书脊两条线、封面 / 封底的安全区、裁切线（包边外沿）。offset = 看得见的
    /// 那块在图里的左上角（带包边时 = 包边 + 出血）。
    private static func drawGuides(_ image: CGImage, layout: CollageBookCover.Layout, offset: CGFloat,
                                   canvas: CollageCanvas, scale: Double) -> CGImage? {
        guard let ctx = CollageRender.makeContext(width: image.width, height: image.height) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        let lw = max(1, CGFloat(Double(min(layout.pageW, layout.pageH))) / 700)
        ctx.setLineWidth(lw)
        func shifted(_ r: CGRect) -> CGRect {
            r.offsetBy(dx: offset - CGFloat(layout.extent), dy: offset - CGFloat(layout.extent))
        }
        // 折线、书脊：实线青色。
        ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.75, blue: 0.9, alpha: 0.85))
        ctx.stroke(shifted(layout.trim).insetBy(dx: lw / 2, dy: lw / 2))
        let spine = shifted(layout.spineRect)
        for x in [spine.minX, spine.maxX] {
            ctx.move(to: CGPoint(x: x, y: spine.minY))
            ctx.addLine(to: CGPoint(x: x, y: spine.maxY))
        }
        ctx.strokePath()
        // 裁切线（包边外沿：封面纸在这里裁，外面那一圈是出血）：品红虚线。
        if offset > 0, layout.bleed > 0 {
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 0.7))
            ctx.setLineDash(phase: 0, lengths: [lw * 5, lw * 4])
            ctx.stroke(layout.wrapRect.insetBy(dx: lw / 2, dy: lw / 2))
        }
        // 安全区：绿色虚线（封面、封底各一圈）。
        let safe = CGFloat(Double(canvas.safe) * scale)
        if safe > 0 {
            ctx.setStrokeColor(CGColor(srgbRed: 0.3, green: 0.8, blue: 0.4, alpha: 0.75))
            ctx.setLineDash(phase: 0, lengths: [lw * 5, lw * 4])
            for panel in [layout.back, layout.front] { ctx.stroke(shifted(panel).insetBy(dx: safe, dy: safe)) }
        }
        return ctx.makeImage()
    }
}

// MARK: - 看版 PDF 的第一页（CollageProofPDF，P5）

extension CollageBookCoverRender {
    /// 看版 PDF 的封面页：看得见的那块（封底 | 书脊 | 封面，不带包边、出血、参考线），长边 2000 px、JPEG 0.75（同跨页那几页）；
    /// 页脚第一行「封面 · 标题」，下面是封面上的照片文件名（封面那一页先上后下、先左后右，再是封底那张）。没有封面 = nil。
    static func proofPage(project: CollageProject, hints: [String: CollageCrop.Hints]) -> CollageProofPDF.Page? {
        guard project.mode == .album, let cover = project.bookCover else { return nil }
        let full = cover.layout(canvas: project.canvas, spreads: project.pages.count)
        let long = Double(max(full.trim.width, full.trim.height))
        var opts = CollageRender.Options(scale: min(1, CollageProofPDF.longSide / max(1, long)))
        opts.includeBleed = false
        opts.export = true
        opts.watermark = project.watermark?.exportEnabled ?? true
        guard let image = render(cover: cover, project: project, hints: hints, options: opts),
              let jpeg = CollageExport.encode(image, format: .jpeg, quality: CollageProofPDF.quality, dpi: 144) else { return nil }
        let t = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CollageProofPDF.Page(jpeg: jpeg, pixelWidth: image.width, pixelHeight: image.height,
                                    heading: "封面" + (t.isEmpty ? "" : " · \(t)"), names: proofNames(cover, project: project))
    }

    /// 封面上的照片文件名（看版页脚）：封面那一页按阅读顺序（上沿差不到页高 2% 算同一行），再是封底那张。
    static func proofNames(_ cover: CollageBookCover, project: CollageProject) -> [String] {
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        func fileName(_ id: String) -> String? {
            guard let p = photos[id] else { return nil }
            let name = URL(fileURLWithPath: p.path).lastPathComponent
            return name.isEmpty ? p.id : name
        }
        let canvas = CollageBookCover.frontCanvas(project.canvas)
        let tolerance = CGFloat(canvas.height) * 0.02
        let spots = CollageLayout.pageGeometry(cover.front, canvas: canvas, style: project.style).frames
            .filter { $0.cell.kind == .photo && !$0.rect.isEmpty && $0.cell.photoID != nil }
            .map { (id: $0.cell.photoID ?? "", rect: $0.rect.cgRect) }
            .sorted { a, b in
                abs(a.rect.minY - b.rect.minY) > tolerance ? a.rect.minY < b.rect.minY : a.rect.minX < b.rect.minX
            }
        return (spots.map(\.id) + (cover.back.photoID.map { [$0] } ?? [])).compactMap(fileName)
    }
}

// MARK: - 导出（C3）：「名_封面.<格式>」+「名_封面.pdf」

extension CollageExport {
    /// 封面 PDF：一页 = 整张封面（带包边、出血的 JPEG，原样嵌入）。BleedBox = 整张；TrimBox = 包边外沿（精装封面纸在
    /// 这里裁，包边要折到板子背面，R2#8）—— 裁切线在它的四角、出血外面（同跨页 PDF）。板子的边（包边内沿：包边往里折的
    /// 那一圈）和封底 / 书脊 / 封面的分界另画折线记号（虚线，出血外面一小段，不进画面），不和裁切线混。先写临时文件、
    /// 读回来核对（verifyPDF）再改名，同 writePDF；overwrite = false 时正式名上已经有文件就报错不覆盖。
    static func writeCoverPDF(page: PDFPage, layout: CollageBookCover.Layout, dpi: Double, to url: URL, title: String,
                              cropMarks: Bool, overwrite: Bool = false) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        var committed = false
        defer { if !committed { try? fm.removeItem(at: tmp) } }
        try autoreleasepool {
            try drawCoverPDF(page: page, layout: layout, dpi: dpi, to: tmp, title: title, cropMarks: cropMarks)
        }
        if let why = verifyPDF(at: tmp, pages: 1) { throw ExportError.pdfIncomplete(why) }
        do {
            if overwrite, fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            if !overwrite, fm.fileExists(atPath: url.path) { throw ExportError.pdfExists(url.lastPathComponent) }
            throw ExportError.pdfIncomplete("改名失败：\(error.localizedDescription)")
        }
        committed = true
    }

    /// 封面 PDF 的几个框（点，左下原点）：media = 整张 + 四周裁切线留白，bleed = 整张，trim = 包边外沿（裁切的地方，
    /// = 版面几何的 wrapRect），board = 板子（封底 | 书脊 | 封面，翻开平放看得见的那块；它的四条边是包边往里折的折线），
    /// spine = 书脊两条折线的 x。
    static func coverPDFBoxes(layout: CollageBookCover.Layout, dpi: Double, cropMarks: Bool)
        -> (media: CGRect, bleed: CGRect, trim: CGRect, board: CGRect, spine: [CGFloat]) {
        let pt = 72.0 / max(1, dpi)
        let slug = cropMarks ? 10.0 / 25.4 * 72 : 0
        let w = Double(layout.width) * pt
        let h = Double(layout.height) * pt
        let media = CGRect(x: 0, y: 0, width: w + slug * 2, height: h + slug * 2)
        let bleed = CGRect(x: slug, y: slug, width: w, height: h)
        let b = Double(layout.bleed) * pt
        let trim = CGRect(x: slug + b, y: slug + b, width: Double(layout.width - 2 * layout.bleed) * pt,
                          height: Double(layout.height - 2 * layout.bleed) * pt)
        let e = Double(layout.extent) * pt
        let board = CGRect(x: slug + e, y: slug + e, width: Double(2 * layout.pageW + layout.spine) * pt,
                           height: Double(layout.pageH) * pt)
        let s0 = slug + e + Double(layout.pageW) * pt
        return (media, bleed, trim, board, [CGFloat(s0), CGFloat(s0 + Double(layout.spine) * pt)])
    }

    private static func coverBox(_ rect: CGRect) -> CFData {
        var box = rect
        return Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
    }

    private static func drawCoverPDF(page: PDFPage, layout: CollageBookCover.Layout, dpi: Double, to url: URL,
                                     title: String, cropMarks: Bool) throws {
        let boxes = coverPDFBoxes(layout: layout, dpi: dpi, cropMarks: cropMarks)
        var media = boxes.media
        let info: [CFString: Any] = [
            kCGPDFContextCreator: "选片工具",
            kCGPDFContextTitle: (title.isEmpty ? "相册" : title) + " 封面",
        ]
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else { throw ExportError.pdf }
        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: coverBox(media),
            kCGPDFContextBleedBox: coverBox(boxes.bleed),
            kCGPDFContextTrimBox: coverBox(boxes.trim),
        ]
        let provider: CGDataProvider?
        switch page {
        case .data(let data): provider = CGDataProvider(data: data as CFData)
        case .file(let file): provider = CGDataProvider(url: file as CFURL)
        }
        guard let provider,
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) else {
            ctx.closePDF()
            throw ExportError.pdfPage(1)
        }
        ctx.beginPDFPage(pageInfo as CFDictionary)
        ctx.draw(jpeg, in: boxes.bleed)
        if cropMarks {
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(0.3)
            let slug = boxes.bleed.minX
            let length = max(4, slug - 3)
            let trim = boxes.trim
            // 四角裁切线（实线）：沿包边外沿（TrimBox），从出血外 2pt 起往外。
            let gapX = trim.minX - boxes.bleed.minX + 2
            let gapY = trim.minY - boxes.bleed.minY + 2
            for x in [trim.minX, trim.maxX] {
                for y in [trim.minY, trim.maxY] {
                    let dx: CGFloat = x == trim.minX ? -1 : 1
                    let dy: CGFloat = y == trim.minY ? -1 : 1
                    ctx.move(to: CGPoint(x: x + dx * gapX, y: y))
                    ctx.addLine(to: CGPoint(x: x + dx * (gapX + length), y: y))
                    ctx.move(to: CGPoint(x: x, y: y + dy * gapY))
                    ctx.addLine(to: CGPoint(x: x, y: y + dy * (gapY + length)))
                }
            }
            ctx.strokePath()
            // 折线记号（虚线，和裁切线分开）：板子的四条边（包边往里折）、封底 / 书脊 / 封面的分界。竖的画在上下两头、
            // 横的画在左右两头，都在出血外面。
            ctx.setLineDash(phase: 0, lengths: [1.5, 1.2])
            let board = boxes.board
            for x in [board.minX] + boxes.spine + [board.maxX] {
                ctx.move(to: CGPoint(x: x, y: boxes.bleed.maxY + 2))
                ctx.addLine(to: CGPoint(x: x, y: boxes.bleed.maxY + 2 + length))
                ctx.move(to: CGPoint(x: x, y: boxes.bleed.minY - 2))
                ctx.addLine(to: CGPoint(x: x, y: boxes.bleed.minY - 2 - length))
            }
            for y in [board.minY, board.maxY] {
                ctx.move(to: CGPoint(x: boxes.bleed.minX - 2, y: y))
                ctx.addLine(to: CGPoint(x: boxes.bleed.minX - 2 - length, y: y))
                ctx.move(to: CGPoint(x: boxes.bleed.maxX + 2, y: y))
                ctx.addLine(to: CGPoint(x: boxes.bleed.maxX + 2 + length, y: y))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

extension CollageStore {
    struct CoverExportResult: Sendable {
        var files: [String] = []
        var error: String?
        var lowRes: [String] = []
        var missing: [String] = []
    }

    /// 导出时写封面（startExport 写完跨页 PDF 之后调）：后台渲成品尺寸 × scale、带包边出血的整张，写图，勾了 PDF 再写
    /// 封面 PDF（不进跨页 PDF：印厂一般要封面单独一份）。names = ExportPlan.cover（图在前、PDF 在后；空 = 什么都不写）。
    /// 色彩、JPEG 质量同跨页（writePage）：印厂规格选了 Adobe RGB 就转过去再写（嵌 ICC），规格定了 JPEG 质量就用它。
    /// 封面 / 封底有照片用的不是原图（优化分析 A1）：图照写，封面 PDF 不出（同跨页 PDF 的道理），error 里说清楚。
    /// fakeLowRes、failFront：自检用（这几张当成原图读不了；封面那一页当成渲染失败）。
    nonisolated static func exportCover(project: CollageProject, options: ExportOptions, names: [String], folder: URL,
                                        scale: Int, hints: [String: CollageCrop.Hints], fakeLowRes: Set<String> = [],
                                        failFront: Bool = false) async -> CoverExportResult {
        guard let imageName = names.first else { return CoverExportResult() }
        return await Task.detached(priority: .userInitiated) { () -> CoverExportResult in
            var result = CoverExportResult()
            var opts = CollageRender.Options(scale: Double(scale))
            opts.export = true
            opts.includeBleed = true
            opts.watermark = project.watermark?.exportEnabled ?? true
            let report = CollageRender.RenderReport()
            opts.report = report
            let canvas = project.canvas
            guard let cover = project.bookCover, project.mode == .album,
                  let rendered = CollageBookCoverRender.render(cover: cover, project: project, hints: hints, options: opts,
                                                               failFront: failFront),
                  let image = CollageExport.converted(rendered, to: canvas.exportColorSpace) else {
                result.error = "封面渲染失败，没有写封面文件"
                return result
            }
            result.lowRes = report.lowRes + cover.photoIDs.filter(fakeLowRes.contains)
            result.missing = report.missing
            var quality = canvas.printRules?.jpegQuality ?? options.quality
            if project.style.halftone != nil { quality = max(0.9, quality) }
            let url = folder.appendingPathComponent(imageName)
            do {
                try CollageExport.write(image, to: url, format: options.format, quality: quality, dpi: canvas.dpi)
            } catch {
                result.error = error.localizedDescription
                return result
            }
            result.files.append(imageName)
            guard names.count > 1 else { return result }
            guard result.lowRes.isEmpty, result.missing.isEmpty else {
                result.error = CollageStore.pdfDegradedNote(missing: result.missing, lowRes: result.lowRes, kept: "封面图")
                return result
            }
            let pdfName = names[1]
            let page: CollageExport.PDFPage
            if options.format == .jpeg {
                page = .file(url)
            } else if let jpeg = CollageExport.encode(image, format: .jpeg, quality: 0.93, dpi: canvas.dpi) {
                page = .data(jpeg)
            } else {
                result.error = CollageExport.ExportError.pdfEncode(imageName).localizedDescription
                return result
            }
            do {
                let layout = cover.layout(canvas: canvas, spreads: project.pages.count, scale: Double(scale))
                try CollageExport.writeCoverPDF(page: page, layout: layout, dpi: canvas.dpi * Double(scale),
                                                to: folder.appendingPathComponent(pdfName), title: project.title,
                                                cropMarks: options.cropMarks, overwrite: false)
                result.files.append(pdfName)
            } catch {
                result.error = error.localizedDescription
            }
            return result
        }.value
    }
}
