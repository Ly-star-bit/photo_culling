import Foundation
import CoreGraphics
import CoreText
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// Native Swift port of watermark_photographer's Rust pipeline
/// (src-tauri/src/{watermark,position,exif_text,frame,canvas_expand,batch}.rs).
/// Pure CoreGraphics/CoreText/ImageIO — no dependencies. All ratio semantics
/// match the original: signature width scales off the SHORT edge, EXIF text
/// font off the LONG edge, frame bars off the short edge.
enum WatermarkEngine {

    // MARK: - Config models
    //
    // JSON keys are the Swift property names (camelCase); only GridPosition's
    // raw values are snake_case, mirroring the Rust presets. Every struct
    // decodes field-by-field with defaults (see `lenient`) so adding a property
    // later never invalidates a saved preset or state.json.

    enum GridPosition: String, Codable, CaseIterable {
        case topLeft = "top_left"
        case topCenter = "top_center"
        case topRight = "top_right"
        case middleLeft = "middle_left"
        case center = "center"
        case middleRight = "middle_right"
        case bottomLeft = "bottom_left"
        case bottomCenter = "bottom_center"
        case bottomRight = "bottom_right"
    }

    struct RGB: Codable, Equatable {
        var r: Double
        var g: Double
        var b: Double
        var color: CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        var nsColor: NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        static let white = RGB(r: 255, g: 255, b: 255)
        static let black = RGB(r: 0, g: 0, b: 0)
    }

    struct ExifTextConfig: Codable, Equatable {
        var enabled = false
        var template = "{make} {model} · {lens} · f/{fnumber} · {shutter}s · ISO {iso}"
        var customText: String = ""      // 非空 = 直接用此文本，忽略 EXIF
        var fontSizeRatio: Double = 0.03 // 相对长边
        var position: GridPosition = .bottomLeft
        var marginX: Double = 40
        var marginY: Double = 40
        var opacity: Double = 0.85
        var color: RGB = .white
        var backgroundEnabled = true
        var backgroundColor: RGB = .black
        var backgroundAlpha: Double = 80 / 255.0
        var fullWidth = false

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            enabled = c.lenient(.enabled, d.enabled)
            template = c.lenient(.template, d.template)
            customText = c.lenient(.customText, d.customText)
            fontSizeRatio = c.lenient(.fontSizeRatio, d.fontSizeRatio)
            position = c.lenient(.position, d.position)
            marginX = c.lenient(.marginX, d.marginX)
            marginY = c.lenient(.marginY, d.marginY)
            opacity = c.lenient(.opacity, d.opacity)
            color = c.lenient(.color, d.color)
            backgroundEnabled = c.lenient(.backgroundEnabled, d.backgroundEnabled)
            backgroundColor = c.lenient(.backgroundColor, d.backgroundColor)
            backgroundAlpha = c.lenient(.backgroundAlpha, d.backgroundAlpha)
            fullWidth = c.lenient(.fullWidth, d.fullWidth)
        }
    }

    struct TileConfig: Codable, Equatable {
        var enabled = false
        var angleDeg: Double = 30
        var gapRatio: Double = 0.6

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            enabled = c.lenient(.enabled, d.enabled)
            angleDeg = c.lenient(.angleDeg, d.angleDeg)
            gapRatio = c.lenient(.gapRatio, d.gapRatio)
        }
    }

    struct CanvasRatioConfig: Codable, Equatable {
        var enabled = false
        var ratioW: Double = 1
        var ratioH: Double = 1
        var fillColor: RGB = .white

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            enabled = c.lenient(.enabled, d.enabled)
            ratioW = c.lenient(.ratioW, d.ratioW)
            ratioH = c.lenient(.ratioH, d.ratioH)
            fillColor = c.lenient(.fillColor, d.fillColor)
        }
    }

    struct FrameConfig: Codable, Equatable {
        var enabled = false
        var borderColor = RGB(r: 250, g: 250, b: 250)
        var borderRatio: Double = 0.02      // 相对短边，上/左/右等宽
        var bottomBarRatio: Double = 0.12   // 参数条高度，相对短边
        var textColor = RGB(r: 30, g: 30, b: 30)
        var subtextColor = RGB(r: 110, g: 110, b: 110)
        var leftLine1 = "{model}"
        var leftLine2 = "{lens}"
        var rightLine1 = "{focal}  f/{fnumber}  {shutter}s  ISO {iso}"
        var rightLine2 = "{date}"
        var showBrand = true
        var fontSizeRatio: Double = 0.22    // 相对参数条高度
        var brandSizeRatio: Double = 0.42
        var showDivider = false

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            enabled = c.lenient(.enabled, d.enabled)
            borderColor = c.lenient(.borderColor, d.borderColor)
            borderRatio = c.lenient(.borderRatio, d.borderRatio)
            bottomBarRatio = c.lenient(.bottomBarRatio, d.bottomBarRatio)
            textColor = c.lenient(.textColor, d.textColor)
            subtextColor = c.lenient(.subtextColor, d.subtextColor)
            leftLine1 = c.lenient(.leftLine1, d.leftLine1)
            leftLine2 = c.lenient(.leftLine2, d.leftLine2)
            rightLine1 = c.lenient(.rightLine1, d.rightLine1)
            rightLine2 = c.lenient(.rightLine2, d.rightLine2)
            showBrand = c.lenient(.showBrand, d.showBrand)
            fontSizeRatio = c.lenient(.fontSizeRatio, d.fontSizeRatio)
            brandSizeRatio = c.lenient(.brandSizeRatio, d.brandSizeRatio)
            showDivider = c.lenient(.showDivider, d.showDivider)
        }
    }

    struct Config: Codable, Equatable {
        var signatureEnabled = true
        var position: GridPosition = .bottomRight
        var sizeRatio: Double = 0.15        // 签名宽度占短边比例
        var opacity: Double = 0.8
        var marginX: Double = 30
        var marginY: Double = 30
        var landscapeOverrideEnabled = false
        var landscapeOverride: GridPosition = .bottomRight
        var tintEnabled = false
        var tint: RGB = .white
        var exifText = ExifTextConfig()
        var frame = FrameConfig()
        var tile = TileConfig()
        var canvasRatio = CanvasRatioConfig()

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            signatureEnabled = c.lenient(.signatureEnabled, d.signatureEnabled)
            position = c.lenient(.position, d.position)
            sizeRatio = c.lenient(.sizeRatio, d.sizeRatio)
            opacity = c.lenient(.opacity, d.opacity)
            marginX = c.lenient(.marginX, d.marginX)
            marginY = c.lenient(.marginY, d.marginY)
            landscapeOverrideEnabled = c.lenient(.landscapeOverrideEnabled, d.landscapeOverrideEnabled)
            landscapeOverride = c.lenient(.landscapeOverride, d.landscapeOverride)
            tintEnabled = c.lenient(.tintEnabled, d.tintEnabled)
            tint = c.lenient(.tint, d.tint)
            exifText = c.lenient(.exifText, d.exifText)
            frame = c.lenient(.frame, d.frame)
            tile = c.lenient(.tile, d.tile)
            canvasRatio = c.lenient(.canvasRatio, d.canvasRatio)
        }
    }

    /// 导出设置和「导出 JPG」「精华 Top N」共用一份（尺寸、锐化、去 GPS、文件名模板、体积上限、质量）。
    /// 旧 state.json / --config 里的 maxLongSide、filenameSuffix 照样认（换算成 size、nameTemplate）。
    typealias ExportOptions = DeliveryOptions

    // MARK: - EXIF tag extraction (ImageIO 代替 Rust 的裸 EXIF 解析)

    struct ExifTags {
        var values: [String: String] = [:]
        /// 文件属性真的读到了（文件不在、打不开 = false）。values 空不等于没读到：截图、PNG 本来就没有 EXIF。
        private(set) var readOK = false

        init(source: CGImageSource?) {
            guard let source,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
            readOK = true
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

            if let make = tiff[kCGImagePropertyTIFFMake] as? String {
                values["make"] = make.trimmingCharacters(in: .whitespaces)
            }
            if let model = tiff[kCGImagePropertyTIFFModel] as? String {
                values["model"] = model.trimmingCharacters(in: .whitespaces)
            }
            if let lens = exif[kCGImagePropertyExifLensModel] as? String {
                values["lens"] = lens.trimmingCharacters(in: .whitespaces)
            }
            if let f = exif[kCGImagePropertyExifFNumber] as? Double {
                values["fnumber"] = String(format: "%.1f", f)
            }
            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArr.first {
                values["iso"] = "\(iso)"
            }
            if let focal = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
                values["focal"] = "\(focal)mm"
            } else if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                values["focal"] = String(format: "%.0fmm", focal)
            }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                // ≥1s 用 %g：1.5s 保持 1.5，2s 保持 2（%.0f 会把 1.5 印成 2）。
                values["shutter"] = t >= 1 ? String(format: "%g", t) : "1/\(Int((1 / t).rounded()))"
            }
            if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                values["datetime"] = dt
                values["date"] = String(dt.prefix(10)).replacingOccurrences(of: ":", with: "-")
            }
            if let make = values["make"] {
                values["brand"] = Self.normalizeBrand(make)
            }
        }

        /// 品牌归一化（frame.rs 的映射表）。
        static func normalizeBrand(_ make: String) -> String {
            let upper = make.uppercased()
            let table: [(String, String)] = [
                ("FUJI", "FUJIFILM"), ("SONY", "SONY"), ("CANON", "Canon"),
                ("NIKON", "NIKON"), ("LEICA", "LEICA"), ("PANASONIC", "LUMIX"),
                ("LUMIX", "LUMIX"), ("HASSELBLAD", "HASSELBLAD"), ("OLYMPUS", "OLYMPUS"),
                ("PENTAX", "PENTAX"), ("RICOH", "RICOH"), ("SIGMA", "SIGMA"),
                ("APPLE", "iPhone"), ("XIAOMI", "Xiaomi"), ("HUAWEI", "HUAWEI"),
            ]
            for (needle, brand) in table where upper.contains(needle) { return brand }
            return make
        }

        /// exif_text 语义：找不到的 {key} 原样保留。
        func fill(template: String) -> String {
            var out = template
            for (key, value) in values {
                out = out.replacingOccurrences(of: "{\(key)}", with: value)
            }
            return out
        }

        private static let placeholderRegex = try! NSRegularExpression(pattern: "\\{([a-z_]+)\\}")

        static func placeholders(in text: String) -> [String] {
            let ns = text as NSString
            return placeholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) }
        }

        /// 找不到的 {key} 按 token 粒度删除：占位符本身、它所在的词
        /// （"f/{fnumber}"、"{shutter}s"）、前面的裸标签词（"ISO {iso}"、
        /// "Shot on {model}"），最后再清掉悬空的分隔符（"·" "|" "-"）。
        /// 所有键都齐全的模板直接走 fill()，间距逐字节不变。
        /// 只删占位符会在无 EXIF 的图（PNG/截图/被微信剥过的 JPEG）上留下
        /// "f/  s  ISO" 这种残渣；旧版按双空格分段，模板一改成单空格就失效。
        func fillStripMissing(template: String) -> String {
            let keys = Self.placeholders(in: template)
            guard keys.contains(where: { values[$0] == nil }) else { return fill(template: template) }

            struct Token {
                var text: String
                var trailing: String
                var isPlaceholder: Bool { text.contains("{") && text.contains("}") }
                var isSeparator: Bool {
                    !text.isEmpty && !text.contains(where: { $0.isLetter || $0.isNumber || $0 == "{" })
                }
                var isLiteral: Bool { !isPlaceholder && !isSeparator }
            }
            var tokens: [Token] = []
            var text = "", trailing = ""
            for ch in template {
                if ch == " " || ch == "\t" {
                    trailing.append(ch)
                } else {
                    if !trailing.isEmpty {
                        if !text.isEmpty { tokens.append(Token(text: text, trailing: trailing)) }
                        text = ""
                        trailing = ""
                    }
                    text.append(ch)
                }
            }
            if !text.isEmpty { tokens.append(Token(text: text, trailing: trailing)) }

            var keep = [Bool](repeating: true, count: tokens.count)
            for (i, token) in tokens.enumerated() where token.isPlaceholder {
                let tokenKeys = Self.placeholders(in: token.text)
                let missing = tokenKeys.filter { values[$0] == nil }
                guard !missing.isEmpty else { continue }
                if missing.count < tokenKeys.count {
                    // 一词多键、部分缺失：只抠掉缺的那个
                    for key in missing { tokens[i].text = tokens[i].text.replacingOccurrences(of: "{\(key)}", with: "") }
                    continue
                }
                keep[i] = false
                var j = i - 1
                while j >= 0, keep[j], tokens[j].isLiteral {
                    keep[j] = false
                    j -= 1
                }
            }

            // 分隔符收尾：开头/结尾的、以及连续重复的都去掉。
            var kept: [Token] = []
            for (i, token) in tokens.enumerated() where keep[i] {
                if token.isSeparator, kept.isEmpty || kept.last!.isSeparator { continue }
                kept.append(token)
            }
            while let last = kept.last, last.isSeparator { kept.removeLast() }

            return kept.map { fill(template: $0.text) + $0.trailing }
                .joined()
                .trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - 定位 (position.rs)

    /// 短边基准：横竖构图签名视觉大小一致。
    static func targetWatermarkWidth(imgW: Int, imgH: Int, sizeRatio: Double) -> Int {
        max(1, Int((Double(min(imgW, imgH)) * sizeRatio).rounded()))
    }

    /// 九宫格 + 边距 → 左上角坐标（TOP-LEFT 坐标系），clamp 防越界。
    static func computePosition(imgW: Int, imgH: Int, wmW: Int, wmH: Int,
                                anchor: GridPosition, marginX: Double, marginY: Double) -> CGPoint {
        let iw = Double(imgW), ih = Double(imgH)
        let ww = Double(wmW), wh = Double(wmH)
        let mx = marginX, my = marginY
        var x: Double, y: Double
        switch anchor {
        case .topLeft: (x, y) = (mx, my)
        case .topCenter: (x, y) = ((iw - ww) / 2, my)
        case .topRight: (x, y) = (iw - ww - mx, my)
        case .middleLeft: (x, y) = (mx, (ih - wh) / 2)
        case .center: (x, y) = ((iw - ww) / 2, (ih - wh) / 2)
        case .middleRight: (x, y) = (iw - ww - mx, (ih - wh) / 2)
        case .bottomLeft: (x, y) = (mx, ih - wh - my)
        case .bottomCenter: (x, y) = ((iw - ww) / 2, ih - wh - my)
        case .bottomRight: (x, y) = (iw - ww - mx, ih - wh - my)
        }
        return CGPoint(x: x.clamped(0, max(0, iw - ww)), y: y.clamped(0, max(0, ih - wh)))
    }

    // MARK: - 解码

    /// ImageIO 缩略图路径解出的正向图：JPEG 走 DCT 域降采样，方向已烘焙。
    /// `fullWidth/fullHeight` 是正向后的全尺寸，像素单位参数按
    /// image.width / fullWidth 缩放即可 WYSIWYG。
    struct DecodedBase {
        let image: CGImage
        let fullWidth: Int
        let fullHeight: Int
    }

    /// 正向后的全尺寸（编码宽高 + EXIF 方向 ≥5 时交换）。
    static func uprightSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    static func decodeUpright(_ source: CGImageSource, maxPixel: Int) -> DecodedBase? {
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) else { return nil }
        // kCGImagePropertyPixelWidth 是编码宽度（方向变换之前）；缩略图已经转正。
        // 竖拍（存 6000×4000 + 方向 6）若不交换，scale 会是 1067/6000 而不是
        // 1067/4000，预览的边距和字号全小三分之一。
        let full = uprightSize(of: source)
        return DecodedBase(image: thumb,
                           fullWidth: max(full?.width ?? 0, thumb.width),
                           fullHeight: max(full?.height ?? 0, thumb.height))
    }

    // MARK: - 合成主入口

    struct Composition {
        let image: CGImage
        /// 非平铺模式下签名比画布还大，跳过没画。
        let signatureSkipped: Bool
        /// 文字放不下 / 压签名，自动缩了字号或挪了位置（fitText 的说明）；没动 = nil。
        var textFit: String? = nil
    }

    /// 完整合成管线。`scale` 让像素单位的参数（边距）在降采样图上保持视觉一致：
    /// 传 base.width / fullWidth（全尺寸导出即 1.0）。
    static func compose(base: CGImage, signature: CGImage?, config: Config,
                        tags: ExifTags, scale: CGFloat = 1.0) -> Composition? {
        let w = base.width, h = base.height
        // 不透明画布 + 白底：JPEG 没有 alpha，带透明区域的源图（PNG/WebP）在这里
        // 直接压到白上，编码时不再需要额外一次拷贝。
        guard let ctx = makeContext(width: w, height: h, opaque: true) else { return nil }
        // 全程 TOP-LEFT 坐标系：翻转一次，后面所有 y 直接用设计坐标。
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawImageTopLeft(ctx, base, CGRect(x: 0, y: 0, width: w, height: h))

        // 签名 + EXIF 文字（拼图里每格 / 整页画的也是这一段；字放不下的自动缩只在整张图这里做，
        // 拼图有自己那套躲让）
        let fit = fitText(config, width: w, height: h, signature: signature, tags: tags, scale: scale)
        let signatureSkipped = drawMarks(in: ctx, width: w, height: h, signature: signature,
                                         config: fit.config, tags: tags, scale: scale)

        guard var composed = ctx.makeImage() else { return nil }

        // 相框（画布扩大，最后包装）
        if config.frame.enabled, let framed = applyFrame(composed, config: config.frame, tags: tags) {
            composed = framed
        }
        // 画布比例扩展（相框之后）
        if config.canvasRatio.enabled,
           let expanded = expandToRatio(composed, config: config.canvasRatio) {
            composed = expanded
        }
        return Composition(image: composed, signatureSkipped: signatureSkipped, textFit: fit.note)
    }

    /// 整张图上的 EXIF 文字放不下就自动缩字。字号按长边 3% 算、不封顶：默认模板 + 长镜头名，横图截在
    /// 「1/2000s · IS」、竖图（字号同样按长边）截在「RXD B」，光圈快门全丢；默认的左下文字还会伸到
    /// 右下签名底下，签名被半透明底条盖住。
    /// - 压着签名：先让到签名旁边（字靠哪边让哪边，居中的两边对称让）；旁边不到这一条的 35%，就叠到
    ///   签名上方（字在下排）/ 下方（字在上排）/ 上下空得多的那边（字在中排，和签名同一列时旁边没地方）。
    /// - 伸出画面：缩到左右各留边距放得下。
    /// 放得下、不压签名的一个参数都不改（用户自己调的字号原样画）。最小 8px（layoutExifText 的下限）。
    static func fitText(_ config: Config, width w: Int, height h: Int, signature: CGImage?,
                        tags: ExifTags, scale: CGFloat) -> (config: Config, note: String?) {
        guard config.exifText.enabled else { return (config, nil) }
        var sig: CGRect?
        if config.signatureEnabled, let signature {
            let place = placeSignature(width: w, height: h, signatureSize: CGSize(width: signature.width, height: signature.height),
                                       config: config, scale: scale)
            sig = place.origin.map { CGRect(origin: $0, size: CGSize(width: place.width, height: place.height)) }
        }
        let gap = max(2, Double(config.marginX * scale))
        var fitted = config
        var notes: [String] = []
        func note(_ text: String) { if !notes.contains(text) { notes.append(text) } }
        for _ in 0..<4 {
            guard let text = layoutExifText(config: fitted.exifText, tags: tags, imgW: w, imgH: h, scale: scale),
                  text.natural.width > 0, text.natural.height > 0 else { break }
            let t = fitted.exifText
            let margin = Double(t.marginX * scale)
            var target = Double(w) - margin * 2
            if let sig, sig.intersects(text.block) {
                let beside = t.fullWidth ? 0 : besideWidth(sig, column: t.position.column, width: Double(w),
                                                           margin: margin, gap: gap)
                if beside >= target * 0.35 {
                    target = beside
                    note("让开签名")
                } else {
                    // 叠到签名外侧：下排的字挪到签名上面，上排的挪到签名下面（marginY 存的是没缩放的像素）。
                    // 中排的 marginY 不起作用（computePosition 中排只管居中），换成同一列的上 / 下排再定
                    // marginY：签名下面空得多就叠到下面，否则叠到上面。
                    let row = t.position.row
                    let below = row < 0 || (row == 0 && Double(h) - Double(sig.maxY) >= Double(sig.minY))
                    if row == 0 { fitted.exifText.position = .at(row: below ? -1 : 1, column: t.position.column) }
                    let edge = below ? Double(sig.maxY) + gap : Double(h) - Double(sig.minY) + gap
                    fitted.exifText.marginY = edge / Double(scale)
                    note("叠到签名\(below ? "下方" : "上方")")
                    continue
                }
            } else {
                // 没压签名：真伸出画面才缩（满宽时看字本身的右端，不满宽看底框）—— 只是边距窄点的不动。
                let glyphEnd = text.textX + text.natural.width - text.padding * 2
                let clipped = t.fullWidth ? glyphEnd > Double(w) : text.natural.width > Double(w)
                guard clipped || text.natural.height > Double(h) else { break }
                note("放不下")
            }
            let k = min(target / text.natural.width, Double(h) / text.natural.height)
            // k ≥ 1：已经放得下（取整误差）；字已经到 8px 下限：缩不动了。
            guard k < 1, k > 0, Double(max(w, h)) * t.fontSizeRatio > 8 else { break }
            fitted.exifText.fontSizeRatio = t.fontSizeRatio * k * 0.98
        }
        guard fitted != config else { return (config, nil) }
        let percent = Int((fitted.exifText.fontSizeRatio / config.exifText.fontSizeRatio * 100).rounded())
        let why = notes.isEmpty ? "自动缩字" : notes.joined(separator: "、")
        return (fitted, why + "，字号 \(percent)%")
    }

    /// 文字和签名在同一条上时，字这一侧还剩多宽（字靠左让到签名左边，靠右让到右边，居中的两边对称让）。
    private static func besideWidth(_ sig: CGRect, column: Int, width: Double, margin: Double, gap: Double) -> Double {
        let minX = Double(sig.minX), maxX = Double(sig.maxX)
        let sigOnRight = Double(sig.midX) > width / 2
        switch column {
        case -1: return sigOnRight ? minX - gap - margin : 0
        case 1: return sigOnRight ? 0 : width - margin - maxX - gap
        default:
            let half: Double = sigOnRight ? minX - gap - width / 2 : width / 2 - maxX - gap
            return max(0, half * 2)
        }
    }

    /// 相框/画布扩展后的输出尺寸（不含四舍五入），用来倒推导出时该解多大的底图。
    static func predictedOutputSize(baseW: Double, baseH: Double, config: Config) -> (width: Double, height: Double) {
        var w = baseW, h = baseH
        if config.frame.enabled {
            let short = min(w, h)
            let border = short * config.frame.borderRatio
            w += border * 2
            h += border + short * config.frame.bottomBarRatio
        }
        if config.canvasRatio.enabled, config.canvasRatio.ratioW > 0, config.canvasRatio.ratioH > 0 {
            let target = config.canvasRatio.ratioW / config.canvasRatio.ratioH
            if w / h > target { h = w / target } else { w = h * target }
        }
        return (w, h)
    }

    // MARK: - 签名 + 文字（水印页整张图、拼图每格 / 整页共用）

    /// 签名和文字各落在哪（区域左上原点）。平铺时 signature = nil、tiled = true；
    /// 签名关了 / 没签名 / 比区域还大被跳过时 signature = nil、tiled = false。
    /// text = 文字块（开了背景就是背景框），已裁到区域内；没开文字或字是空的 = nil。
    struct MarkLayout {
        var signature: CGRect?
        var text: CGRect?
        var tiled: Bool
        /// 文字块本来要多大（最宽一行 + 内边距 × 2、总高；满宽时也只算字）。比区域大 = 字伸出去被裁了，
        /// 拼图按它把字号缩到放得下。
        var textSize: CGSize? = nil
    }

    /// 签名的目标尺寸和左上角；origin = nil：平铺（tiled）或放不下（跳过）。
    private struct SignaturePlacement {
        let width: Int
        let height: Int
        let origin: CGPoint?
        let tiled: Bool
    }

    private static func placeSignature(width w: Int, height h: Int, signatureSize: CGSize,
                                       config: Config, scale: CGFloat) -> SignaturePlacement {
        let targetW = targetWatermarkWidth(imgW: w, imgH: h, sizeRatio: config.sizeRatio)
        let targetH = max(1, Int((Double(signatureSize.height) * Double(targetW) / Double(signatureSize.width)).rounded()))
        if config.tile.enabled {
            return SignaturePlacement(width: targetW, height: targetH, origin: nil, tiled: true)
        }
        guard targetW <= w && targetH <= h else {
            return SignaturePlacement(width: targetW, height: targetH, origin: nil, tiled: false)
        }
        let landscape = w >= h
        let anchor = (landscape && config.landscapeOverrideEnabled)
            ? config.landscapeOverride : config.position
        let origin = computePosition(imgW: w, imgH: h, wmW: targetW, wmH: targetH,
                                     anchor: anchor,
                                     marginX: config.marginX * scale,
                                     marginY: config.marginY * scale)
        return SignaturePlacement(width: targetW, height: targetH, origin: origin, tiled: false)
    }

    /// 在 ctx 当前坐标系（左上原点、已翻转、原点 = 区域左上角）里画签名和文字；调用方负责平移和裁剪。
    /// 返回 signatureSkipped。`scale` 同 compose：像素单位的边距乘它（拼图里边距已是区域像素，传 1）。
    @discardableResult
    static func drawMarks(in ctx: CGContext, width: Int, height: Int, signature: CGImage?, config: Config,
                          tags: ExifTags, scale: CGFloat) -> Bool {
        // drawExifText 会改 fill color：整段包起来，不漏给调用方后面的绘制。
        ctx.saveGState()
        defer { ctx.restoreGState() }

        var signatureSkipped = false
        // 签名图
        if config.signatureEnabled, let signature {
            let place = placeSignature(width: width, height: height,
                                       signatureSize: CGSize(width: signature.width, height: signature.height),
                                       config: config, scale: scale)
            let wm = preparedSignature(signature, width: place.width, height: place.height,
                                       tint: config.tintEnabled ? config.tint : nil)
            if place.tiled {
                drawTiled(ctx, wm, canvasW: width, canvasH: height, tile: config.tile, opacity: config.opacity)
            } else if let origin = place.origin {
                ctx.saveGState()
                ctx.setAlpha(config.opacity)
                drawImageTopLeft(ctx, wm, CGRect(origin: origin, size: CGSize(width: place.width, height: place.height)))
                ctx.restoreGState()
            } else {
                signatureSkipped = true
            }
        }

        // EXIF 文字水印
        if config.exifText.enabled,
           let text = layoutExifText(config: config.exifText, tags: tags, imgW: width, imgH: height, scale: scale) {
            drawExifText(ctx, text, config: config.exifText, imgH: height)
        }
        return signatureSkipped
    }

    /// 只算位置不画（拼图的压字躲让、无头断言用），和 drawMarks 同一套计算。
    /// `signatureSize` = 签名原图尺寸，nil = 没有签名。
    static func layoutMarks(width: Int, height: Int, signatureSize: CGSize?, config: Config,
                            tags: ExifTags, scale: CGFloat) -> MarkLayout {
        var layout = MarkLayout(signature: nil, text: nil, tiled: false)
        if config.signatureEnabled, let signatureSize, signatureSize.width > 0, signatureSize.height > 0 {
            let place = placeSignature(width: width, height: height, signatureSize: signatureSize,
                                       config: config, scale: scale)
            layout.tiled = place.tiled
            if let origin = place.origin {
                layout.signature = CGRect(origin: origin, size: CGSize(width: place.width, height: place.height))
            }
        }
        if config.exifText.enabled,
           let text = layoutExifText(config: config.exifText, tags: tags, imgW: width, imgH: height, scale: scale) {
            // 字比区域还宽时块会伸出去：画出来的只有区域里那部分。
            let visible = text.block.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            layout.text = visible.isNull || visible.isEmpty ? nil : visible
            layout.textSize = text.natural
        }
        return layout
    }

    // MARK: - 签名处理

    /// 签名按目标尺寸缩放并着色后的小图，按 (原图, 尺寸, 颜色) 缓存。
    /// 预览每个 tick、批量导出每一张都会要同一份：以前是每次在原尺寸上着色，
    /// 平铺时还逐格重采样原图。
    private struct PreparedSignature {
        let source: CGImage      // 强引用，保证 === 比较的地址不会被回收复用
        let width: Int
        let height: Int
        let tint: RGB?
        let image: CGImage
    }
    private static var signatureCache: [PreparedSignature] = []
    private static let signatureCacheLock = NSLock()
    /// 拼图里每格尺寸都不一样（一页十几格 × 每张照片层 + 整页层），8 个会来回抖。
    private static let signatureCacheLimit = 48

    /// 非透明像素 RGB 替换为目标色，alpha 边缘保留（apply_tint 语义）：
    /// sourceIn 混合 = 用 alpha 蒙版填色。缩放与着色一次完成。
    static func preparedSignature(_ source: CGImage, width: Int, height: Int, tint: RGB?) -> CGImage {
        signatureCacheLock.lock()
        if let index = signatureCache.firstIndex(where: {
            $0.source === source && $0.width == width && $0.height == height && $0.tint == tint
        }) {
            let hit = signatureCache.remove(at: index)
            signatureCache.append(hit)   // LRU：最近用过的挪到末尾
            signatureCacheLock.unlock()
            return hit.image
        }
        signatureCacheLock.unlock()

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ctx = makeContext(width: width, height: height, opaque: false) else { return source }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: rect)
        if let tint {
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(tint.color)
            ctx.fill(rect)
        }
        guard let image = ctx.makeImage() else { return source }

        signatureCacheLock.lock()
        signatureCache.append(PreparedSignature(source: source, width: width, height: height,
                                                tint: tint, image: image))
        if signatureCache.count > signatureCacheLimit {
            signatureCache.removeFirst(signatureCache.count - signatureCacheLimit)
        }
        signatureCacheLock.unlock()
        return image
    }

    /// 平铺（overlay_tiled）：旋转不裁切，从负一个步长开始铺满四角。
    /// `wm` 已经是目标尺寸的小图，逐格 1:1 贴，不再重采样。
    private static func drawTiled(_ ctx: CGContext, _ wm: CGImage,
                                  canvasW: Int, canvasH: Int, tile: TileConfig, opacity: Double) {
        let wmW = Double(wm.width), wmH = Double(wm.height)
        // 旋转后的包围盒尺寸
        let rad = tile.angleDeg * .pi / 180
        let cosA = abs(cos(rad)), sinA = abs(sin(rad))
        let tw = wmW * cosA + wmH * sinA
        let th = wmW * sinA + wmH * cosA
        guard tw > 0, th > 0 else { return }
        let stepX = max(1.0, tw * (1.0 + max(0, tile.gapRatio)))
        let stepY = max(1.0, th * (1.0 + max(0, tile.gapRatio)))

        ctx.saveGState()
        ctx.setAlpha(opacity)
        var y = -stepY
        while y < Double(canvasH) {
            var x = -stepX
            while x < Double(canvasW) {
                ctx.saveGState()
                // tile 中心 → 旋转 → 画签名（居中）
                let cx = x + tw / 2, cy = y + th / 2
                ctx.translateBy(x: cx, y: cy)
                ctx.rotate(by: -rad)  // top-left 翻转坐标系里角度取反，视觉方向与原版一致
                drawImageTopLeft(ctx, wm, CGRect(x: -wmW / 2, y: -wmH / 2, width: wmW, height: wmH))
                ctx.restoreGState()
                x += stepX
            }
            y += stepY
        }
        ctx.restoreGState()
    }

    // MARK: - EXIF 文字水印 (exif_text.rs)

    /// 文字一次排版的结果：画的时候直接用，不再重新量字（layoutMarks 只取 block）。
    private struct ExifTextLayout {
        let lines: [CTLine]
        let ascender: Double
        let lineHeight: Double
        let padding: Double
        /// computePosition 给的块左上角（满宽时 x 不用它）。
        let origin: CGPoint
        /// 背景框（没开背景时 = 文字块），左上原点坐标。
        let block: CGRect
        let textX: Double
        /// 最宽一行 + 内边距 × 2、总高（不管满宽）。
        let natural: CGSize
    }

    /// 量字 + 定位；字是空的 = nil。
    private static func layoutExifText(config: ExifTextConfig, tags: ExifTags,
                                       imgW: Int, imgH: Int, scale: CGFloat) -> ExifTextLayout? {
        let text = config.customText.isEmpty ? tags.fillStripMissing(template: config.template) : config.customText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let longSide = Double(max(imgW, imgH))
        let fontSize = max(longSide * config.fontSizeRatio, 8.0)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let lines = text.components(separatedBy: "\n")
        let ctLines: [(line: CTLine, width: Double)] = lines.map { lineText in
            let attr = NSAttributedString(string: lineText, attributes: [
                .font: font,
                .foregroundColor: config.color.nsColor.withAlphaComponent(config.opacity),
            ])
            let line = CTLineCreateWithAttributedString(attr)
            return (line, CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let textW = ctLines.map(\.width).max() ?? 0
        let padding = config.backgroundEnabled ? (fontSize * 0.3).rounded(.up) : 0
        let blockW = config.fullWidth ? Double(imgW) : textW + padding * 2
        let blockH = lineHeight * Double(lines.count) + padding * 2

        let origin = computePosition(imgW: imgW, imgH: imgH,
                                     wmW: Int(blockW.rounded()), wmH: Int(blockH.rounded()),
                                     anchor: config.position,
                                     marginX: config.fullWidth ? 0 : config.marginX * scale,
                                     marginY: config.marginY * scale)
        let blockX = config.fullWidth ? 0 : origin.x
        // full_width 时文字仍按 margin_x 缩进
        let textX = config.fullWidth ? Double(config.marginX) * scale + padding : Double(origin.x) + padding
        return ExifTextLayout(lines: ctLines.map(\.line), ascender: Double(font.ascender),
                              lineHeight: Double(lineHeight), padding: padding, origin: origin,
                              block: CGRect(x: blockX, y: origin.y, width: blockW, height: blockH),
                              textX: textX, natural: CGSize(width: textW + padding * 2, height: blockH))
    }

    /// 按 layoutExifText 的结果画背景框和每一行。canvasH 传区域高度：drawCTLine 只在局部翻转，
    /// ctx 外面平移过也没关系。
    private static func drawExifText(_ ctx: CGContext, _ layout: ExifTextLayout, config: ExifTextConfig, imgH: Int) {
        if config.backgroundEnabled {
            ctx.setFillColor(config.backgroundColor.nsColor
                .withAlphaComponent(config.backgroundAlpha).cgColor)
            ctx.fill(layout.block)
        }
        for (index, line) in layout.lines.enumerated() {
            let baselineY = Double(layout.origin.y) + layout.padding + layout.lineHeight * Double(index) + layout.ascender
            drawCTLine(ctx, line, x: layout.textX, baselineTopY: baselineY, canvasH: imgH)
        }
    }

    // MARK: - 相框 (frame.rs)

    private struct MeasuredLine {
        let line: CTLine
        let width: Double
    }

    /// 参数条一次排版的结果：三块文字 + 是否放得下。
    private struct BarLayout {
        var mainFont: NSFont
        var subFont: NSFont
        var brandFont: NSFont
        var left1: MeasuredLine?
        var left2: MeasuredLine?
        var right1: MeasuredLine?
        var right2: MeasuredLine?
        var brand: MeasuredLine?
        var leftW: Double { max(left1?.width ?? 0, left2?.width ?? 0) }
        var rightW: Double { max(right1?.width ?? 0, right2?.width ?? 0) }

        func fits(in available: Double, gap: Double) -> Bool {
            var needed = leftW + rightW
            if let brand {
                needed += brand.width + gap * 2
            } else if leftW > 0, rightW > 0 {
                needed += gap
            }
            return needed <= available
        }
    }

    private static func applyFrame(_ photo: CGImage, config: FrameConfig, tags: ExifTags) -> CGImage? {
        let pw = photo.width, ph = photo.height
        let short = Double(min(pw, ph))
        let border = (short * config.borderRatio).rounded()
        let barH = (short * config.bottomBarRatio).rounded()
        let newW = pw + Int(border) * 2
        let newH = ph + Int(border) + Int(barH)
        guard let ctx = makeContext(width: newW, height: newH, opaque: true) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(newH))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(config.borderColor.color)
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        drawImageTopLeft(ctx, photo, CGRect(x: border, y: border, width: Double(pw), height: Double(ph)))

        let barTop = border + Double(ph)
        // 参数条上方细分隔线
        let sepH = max(barH * 0.015, 1)
        ctx.setFillColor(darken(config.borderColor, 0.85).color)
        ctx.fill(CGRect(x: border, y: barTop, width: Double(newW) - border * 2, height: sepH))

        let innerPad = (barH * 0.15).rounded()
        let available = Double(newW) - border * 2 - innerPad * 2

        func measure(_ text: String, _ font: NSFont, _ color: RGB) -> MeasuredLine? {
            guard !text.isEmpty else { return nil }
            let attr = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color.nsColor,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            return MeasuredLine(line: line, width: CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        let texts = (
            left1: tags.fillStripMissing(template: config.leftLine1),
            left2: tags.fillStripMissing(template: config.leftLine2),
            right1: tags.fillStripMissing(template: config.rightLine1),
            right2: tags.fillStripMissing(template: config.rightLine2)
        )
        let brandText: String? = {
            guard config.showBrand, let brand = tags.values["brand"], !brand.isEmpty else { return nil }
            return brand
        }()

        func layout(fontScale: Double, brand: String?) -> BarLayout {
            let mainSize = max(barH * config.fontSizeRatio * fontScale, 10)
            let subSize = mainSize * 0.85
            let brandSize = max(barH * config.brandSizeRatio * fontScale, 12)
            let mainFont = NSFont.systemFont(ofSize: mainSize, weight: .semibold)
            let subFont = NSFont.systemFont(ofSize: subSize, weight: .regular)
            let brandFont = NSFont.systemFont(ofSize: brandSize, weight: .bold)
            return BarLayout(
                mainFont: mainFont, subFont: subFont, brandFont: brandFont,
                left1: measure(texts.left1, mainFont, config.textColor),
                left2: measure(texts.left2, subFont, config.subtextColor),
                right1: measure(texts.right1, mainFont, config.textColor),
                right2: measure(texts.right2, subFont, config.subtextColor),
                brand: brand.flatMap { measure($0, brandFont, config.textColor) })
        }

        // 碰撞处理：竖构图上三块文字挤不下时，先收品牌名，再逐步缩字号。
        var fontScale = 1.0
        var brand = brandText
        var bar = layout(fontScale: fontScale, brand: brand)
        if !bar.fits(in: available, gap: innerPad), brand != nil {
            brand = nil
            bar = layout(fontScale: fontScale, brand: nil)
        }
        while !bar.fits(in: available, gap: innerPad), fontScale > 0.5 {
            fontScale *= 0.9
            bar = layout(fontScale: fontScale, brand: brand)
        }

        // 行高按字体 ascent+descent 算，块整体在参数条里垂直居中
        //（之前按字号估行高，视觉整体偏下）。
        let mainH = Double(bar.mainFont.ascender - bar.mainFont.descender)
        let subH = Double(bar.subFont.ascender - bar.subFont.descender)
        let lineGap = Double(bar.mainFont.pointSize) * 0.15
        let blockH = mainH + lineGap + subH
        let textY0 = barTop + (barH - blockH) / 2
        let baseline1 = textY0 + Double(bar.mainFont.ascender)
        let baseline2 = textY0 + mainH + lineGap + Double(bar.subFont.ascender)

        // 左块两行
        if let entry = bar.left1 {
            drawCTLine(ctx, entry.line, x: border + innerPad, baselineTopY: baseline1, canvasH: newH)
        }
        if let entry = bar.left2 {
            drawCTLine(ctx, entry.line, x: border + innerPad, baselineTopY: baseline2, canvasH: newH)
        }

        // 右块两行（右对齐）
        let rightEdge = Double(newW) - border - innerPad
        if let entry = bar.right1 {
            drawCTLine(ctx, entry.line, x: rightEdge - entry.width, baselineTopY: baseline1, canvasH: newH)
        }
        if let entry = bar.right2 {
            drawCTLine(ctx, entry.line, x: rightEdge - entry.width, baselineTopY: baseline2, canvasH: newH)
        }

        // 右块左侧竖分隔线（Canon 风）
        if config.showDivider, bar.rightW > 0 {
            let thickness = max(barH * 0.02, 1)
            let dividerMargin = (barH * 0.2).rounded()
            let x = rightEdge - bar.rightW - innerPad
            ctx.setFillColor(darken(config.borderColor, 0.7).color)
            ctx.fill(CGRect(x: x, y: barTop + dividerMargin,
                            width: thickness, height: barH - dividerMargin * 2))
        }

        // 中央品牌名：按大写字高居中，而不是按字号盒子居中。
        if let entry = bar.brand {
            let baseline = barTop + (barH + Double(bar.brandFont.capHeight)) / 2
            drawCTLine(ctx, entry.line, x: (Double(newW) - entry.width) / 2,
                       baselineTopY: baseline, canvasH: newH)
        }
        return ctx.makeImage()
    }

    // MARK: - 画布比例扩展 (canvas_expand.rs)

    private static func expandToRatio(_ image: CGImage, config: CanvasRatioConfig) -> CGImage? {
        guard config.ratioW > 0, config.ratioH > 0 else { return image }
        let w = Double(image.width), h = Double(image.height)
        let target = config.ratioW / config.ratioH
        let current = w / h
        var newW = image.width, newH = image.height
        if abs(current - target) < 0.0001 { return image }
        if current > target {
            newH = Int((w / target).rounded())
        } else {
            newW = Int((h * target).rounded())
        }
        guard let ctx = makeContext(width: newW, height: newH, opaque: true) else { return nil }
        ctx.setFillColor(config.fillColor.color)
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        ctx.draw(image, in: CGRect(x: (Double(newW) - w) / 2, y: (Double(newH) - h) / 2,
                                   width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - 导出 (batch.rs 管线)

    enum ExportError: LocalizedError {
        case sameFile
        case unreadable
        case decodeFailed
        case composeFailed
        case encodeFailed
        /// 压到最低质量还是超过体积上限（文件照最低质量写出去了）。
        case overLimit(Double)

        var errorDescription: String? {
            switch self {
            case .sameFile: return "输出路径与原片相同"
            case .unreadable: return "无法打开源文件"
            case .decodeFailed: return "解码失败 (文件损坏或格式不支持)"
            case .composeFailed: return "合成失败"
            case .encodeFailed: return "写入 JPEG 失败 (检查输出目录权限/磁盘空间)"
            case .overLimit(let mb):
                return "压到最低质量 \(Int(DeliveryEncoder.floorQuality * 100)) 还是超过 \(String(format: "%g", mb)) MB（已按最低质量写出）"
            }
        }
    }

    /// 单张导出：按目标尺寸解码 → compose → JPEG 编码。
    /// 元数据走 CGImageMetadata：EXIF/TIFF/GPS IFD 和 XMP（版权、关键词）一起
    /// 保留；方向和像素尺寸已烘焙进像素所以剥掉；可选去除 GPS。
    /// 返回文字自动缩 / 挪的说明（没动 = nil），无头冒烟测试打出来。
    @discardableResult
    static func export(source: URL, to dest: URL, signature: CGImage?,
                       config: Config, options: ExportOptions) throws -> String? {
        // 绝不写回源文件：后缀被清空 + 输出目录选成照片原目录时 dest == source，
        // 原片会被带水印的版本静默替换掉（不可恢复）。
        guard !isSameFile(source, dest) else { throw ExportError.sameFile }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw ExportError.unreadable }

        // "长边 2048" 直接解到目标大小再合成，而不是全尺寸合成后缩小
        // （61MP × 4 worker 就是 4GB）。相框/画布会把成品撑大，先倒推底图该多大。
        // 尺寸规格（长边 / 短边 / 放进框）都是对成品说的：按预测的成品尺寸折成长边再倒推。
        let size = options.sizeValue
        var maxPixel = 20000
        var downscaled = false
        if let full = uprightSize(of: src) {
            let predicted = predictedOutputSize(baseW: Double(full.width), baseH: Double(full.height), config: config)
            if let cap = size.longEdgeCap(width: predicted.width, height: predicted.height) {
                let growth = max(predicted.width, predicted.height) / Double(max(full.width, full.height))
                maxPixel = max(1, Int((Double(cap) / growth).rounded()))
                downscaled = maxPixel < max(full.width, full.height)
            }
        }
        // 缩小了就先给照片本身补一刀输出锐化，再往上合成签名 / 文字 —— 水印不能跟着被锐化出白边。
        // 不锐化 = 以前那条 ImageIO 缩略图，一个字节不变。
        let sharpened = downscaled && options.sharpen != .off
            ? SharpRenderer.deliveryDownscale(src, longEdge: maxPixel, sharpen: options.sharpen, keepColor: false) : nil
        guard let base = sharpened ?? decodeUpright(src, maxPixel: maxPixel) else { throw ExportError.decodeFailed }
        let scale = CGFloat(base.image.width) / CGFloat(base.fullWidth)

        let tags = ExifTags(source: src)
        guard let composition = compose(base: base.image, signature: signature, config: config,
                                        tags: tags, scale: scale) else { throw ExportError.composeFailed }
        var composed = composition.image

        // 四舍五入偶尔多出一两个像素：这时才补一次（此时图已经很小）缩放。
        if let ratio = size.shrinkRatio(width: composed.width, height: composed.height) {
            let nw = max(1, Int((Double(composed.width) * ratio).rounded()))
            let nh = max(1, Int((Double(composed.height) * ratio).rounded()))
            if let ctx = makeContext(width: nw, height: nh, opaque: true) {
                ctx.interpolationQuality = .high
                ctx.draw(composed, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                if let resized = ctx.makeImage() { composed = resized }
            }
        }

        let metadata = sanitizedMetadata(src, url: source, stripGPS: options.stripGPS)
        let outcome = DeliveryEncoder.write(to: dest, quality: options.quality, maxBytes: options.maxBytes) { out, quality in
            let destOptions = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            if let metadata {
                CGImageDestinationAddImageAndMetadata(out, composed, metadata, destOptions)
            } else {
                CGImageDestinationAddImage(out, composed, destOptions)
            }
        }
        switch outcome {
        case .failed: throw ExportError.encodeFailed
        case .overLimit: throw ExportError.overLimit(options.maxMB)
        case .ok: return composition.textFit
        }
    }

    /// Bool 版入口（main.swift 的 --watermark 冒烟测试用）。
    static func exportPhoto(source: URL, to dest: URL, signature: CGImage?,
                            config: Config, options: ExportOptions) -> Bool {
        do {
            if let fit = try export(source: source, to: dest, signature: signature, config: config, options: options) {
                print("文字自动调整: \(fit)")
            }
            return true
        } catch ExportError.overLimit {
            print("体积: \(ExportError.overLimit(options.maxMB).localizedDescription)")
            return true
        } catch {
            FileHandle.standardError.write("watermark: \(dest.lastPathComponent): \(error.localizedDescription)\n".data(using: .utf8)!)
            return false
        }
    }

    /// 源文件元数据（EXIF/TIFF/GPS/XMP 合一的 CGImageMetadata 树），去掉方向和
    /// 像素尺寸；stripGPS 时连 exif:GPS* 一起去掉。
    private static func sanitizedMetadata(_ source: CGImageSource, url: URL, stripGPS: Bool) -> CGImageMetadata? {
        guard let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let metadata = CGImageMetadataCreateMutableCopy(original) else { return nil }

        // ImageIO 合并树里 IFD0 的 Artist/Copyright 会盖掉 XMP 的 dc:creator /
        // dc:rights；Fuji 机身把这两个字段写成一串空格，LR 填的版权就这样丢了。
        // 从原始 XMP 包把描述类命名空间（dc/xmpRights/photoshop/Iptc4xmp/lr…）
        // 的字段找回来；相机字段（exif/tiff）仍以 IFD 为准。
        if let packet = rawXMPPacket(of: url),
           let xmpTree = metadataTree(fromXMP: packet),
           let tags = CGImageMetadataCopyTags(xmpTree) as? [CGImageMetadataTag] {
            for tag in tags {
                guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                      let name = CGImageMetadataTagCopyName(tag) as String?,
                      !["exif", "exifEX", "tiff"].contains(prefix) else { continue }
                if let namespace = CGImageMetadataTagCopyNamespace(tag) {
                    CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix as CFString, nil)
                }
                CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString, tag)
            }
        }

        var doomed = ["tiff:Orientation", "exif:PixelXDimension", "exif:PixelYDimension"]
        if stripGPS, let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            for tag in tags {
                guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                      let name = CGImageMetadataTagCopyName(tag) as String?,
                      name.hasPrefix("GPS") else { continue }
                doomed.append("\(prefix):\(name)")
            }
        }
        for path in doomed {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
        return metadata
    }

    /// ImageIO 的 XMP 解析器不认单引号属性（exiftool 写出的包就是单引号，Adobe
    /// 的是双引号）；直接解析失败时用 XMLDocument 重新序列化一遍再喂。
    static func metadataTree(fromXMP packet: Data) -> CGImageMetadata? {
        if let tree = CGImageMetadataCreateFromXMPData(packet as CFData) { return tree }
        guard let doc = try? XMLDocument(data: packet, options: []),
              let root = doc.rootElement(),
              let data = root.xmlString(options: []).data(using: .utf8) else { return nil }
        return CGImageMetadataCreateFromXMPData(data as CFData)
    }

    /// JPEG APP1 段里的原始 XMP 包（不含扩展包）；非 JPEG 或没有 XMP 返回 nil。
    private static func rawXMPPacket(of url: URL) -> Data? {
        jpegSegment(of: url, marker: 0xE1, header: Data("http://ns.adobe.com/xap/1.0/\0".utf8))
    }

    /// JPEG 里 `marker`（0xE1 = APP1、0xE2 = APP2…）段、payload 以 `header` 开头的第一段，去掉 header 返回；
    /// 非 JPEG 或没有这段返回 nil。只走到 SOS（元数据段都在图像数据前面）。
    static func jpegSegment(of url: URL, marker wanted: UInt8, header: Data) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count > 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= data.count {
            guard data[i] == 0xFF else { return nil }
            let marker = data[i + 1]
            if marker == 0xFF { i += 1; continue }                       // 填充
            if marker == 0xD9 || marker == 0xDA { return nil }           // EOI / SOS：元数据段到此为止
            if (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }  // 无长度的独立 marker
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard length >= 2, i + 2 + length <= data.count else { return nil }
            if marker == wanted {
                let payload = data[(i + 4)..<(i + 2 + length)]
                if payload.starts(with: header) { return Data(payload.dropFirst(header.count)) }
            }
            i += 2 + length
        }
        return nil
    }

    /// 同一个文件？先比标准化路径，两边都存在时再比文件系统 id —— 大小写不敏感
    /// 的卷、符号链接、`/tmp` 这类软链目录都骗不过 id 比较。
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.path == b.standardizedFileURL.path { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let ida = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
              let idb = try? b.resourceValues(forKeys: keys).fileResourceIdentifier else { return false }
        return ida.isEqual(idb)
    }

    // MARK: - 绘制辅助

    /// opaque = 成品画布（noneSkipLast，先铺白），JPEG 直接编码不用再拍平；
    /// 非 opaque 只给需要 alpha 的签名小图。
    private static func makeContext(width: Int, height: Int, opaque: Bool) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: alpha.rawValue) else { return nil }
        if opaque {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return ctx
    }

    /// 在"已翻转为 top-left"的 context 里画图：CG 的 draw 期望 bottom-left rect，
    /// 且翻转坐标系会让图像上下颠倒，这里局部再翻回来。rect 按当前变换解释，
    /// 所以平铺时把原点挪到 tile 中心后传相对 rect 也行。
    private static func drawImageTopLeft(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// 在翻转 context 里画一行 CoreText。baselineTopY = top-left 坐标系里的基线 y。
    private static func drawCTLine(_ ctx: CGContext, _ line: CTLine, x: Double, baselineTopY: Double, canvasH: Int) {
        ctx.saveGState()
        // CTLineDraw 需要未翻转的坐标系（否则字形上下颠倒）
        ctx.translateBy(x: 0, y: CGFloat(canvasH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: Double(canvasH) - baselineTopY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func darken(_ color: RGB, _ factor: Double) -> RGB {
        RGB(r: color.r * factor, g: color.g * factor, b: color.b * factor)
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}

private extension KeyedDecodingContainer {
    /// 字段缺失或类型不对 → 用默认值。预设必须扛得住模型后续加字段。
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
