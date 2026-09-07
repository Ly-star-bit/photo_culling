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

    // MARK: - Config models (Codable, snake_case to stay preset-compatible)

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
    }

    struct TileConfig: Codable, Equatable {
        var enabled = false
        var angleDeg: Double = 30
        var gapRatio: Double = 0.6
    }

    struct CanvasRatioConfig: Codable, Equatable {
        var enabled = false
        var ratioW: Double = 1
        var ratioH: Double = 1
        var fillColor: RGB = .white
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
    }

    struct Config: Codable, Equatable {
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
    }

    struct ExportOptions: Codable, Equatable {
        var maxLongSide: Int = 0            // 0 = 原尺寸
        var quality: Double = 0.95
        var filenameSuffix = "_wm"
    }

    // MARK: - EXIF tag extraction (ImageIO 代替 Rust 的裸 EXIF 解析)

    struct ExifTags {
        var values: [String: String] = [:]

        init(source: CGImageSource?) {
            guard let source,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
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
                values["shutter"] = t >= 1 ? String(format: "%.0f", t) : "1/\(Int((1 / t).rounded()))"
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

        /// frame 语义：找不到的 {key} 删除，参数条保持干净。
        func fillStripMissing(template: String) -> String {
            var out = fill(template: template)
            while let open = out.range(of: "{"), let close = out.range(of: "}", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            }
            return out.trimmingCharacters(in: .whitespaces)
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

    // MARK: - 合成主入口

    /// 完整合成管线。`scale` 让像素单位的参数（边距）在降采样预览上保持视觉一致：
    /// 预览传 previewW / fullW，导出传 1.0。
    static func compose(base: CGImage, signature: CGImage?, config: Config,
                        tags: ExifTags, scale: CGFloat = 1.0) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        // 全程 TOP-LEFT 坐标系：翻转一次，后面所有 y 直接用设计坐标。
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawImageTopLeft(ctx, base, CGRect(x: 0, y: 0, width: w, height: h), canvasH: h)

        // 签名图
        if let signature {
            let targetW = targetWatermarkWidth(imgW: w, imgH: h, sizeRatio: config.sizeRatio)
            let targetH = max(1, Int((Double(signature.height) * Double(targetW) / Double(signature.width)).rounded()))
            let tinted = config.tintEnabled ? tint(signature, color: config.tint) : signature

            if config.tile.enabled {
                drawTiled(ctx, tinted, wmW: targetW, wmH: targetH,
                          canvasW: w, canvasH: h, tile: config.tile, opacity: config.opacity)
            } else if targetW <= w && targetH <= h {
                let landscape = w >= h
                let anchor = (landscape && config.landscapeOverrideEnabled)
                    ? config.landscapeOverride : config.position
                let origin = computePosition(imgW: w, imgH: h, wmW: targetW, wmH: targetH,
                                             anchor: anchor,
                                             marginX: config.marginX * scale,
                                             marginY: config.marginY * scale)
                ctx.saveGState()
                ctx.setAlpha(config.opacity)
                drawImageTopLeft(ctx, tinted,
                                 CGRect(origin: origin, size: CGSize(width: targetW, height: targetH)),
                                 canvasH: h)
                ctx.restoreGState()
            }
        }

        // EXIF 文字水印
        if config.exifText.enabled {
            drawExifText(ctx, config: config.exifText, tags: tags, imgW: w, imgH: h, scale: scale)
        }

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
        return composed
    }

    // MARK: - 签名处理

    /// 非透明像素 RGB 替换为目标色，alpha 边缘保留（apply_tint 语义）。
    /// CG 实现：sourceIn 混合 = 用 alpha 蒙版填色。
    static func tint(_ image: CGImage, color: RGB) -> CGImage {
        guard let ctx = makeContext(width: image.width, height: image.height) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color.color)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// 平铺（overlay_tiled）：旋转不裁切，从负一个步长开始铺满四角。
    private static func drawTiled(_ ctx: CGContext, _ wm: CGImage, wmW: Int, wmH: Int,
                                  canvasW: Int, canvasH: Int, tile: TileConfig, opacity: Double) {
        // 旋转后的包围盒尺寸
        let rad = tile.angleDeg * .pi / 180
        let cosA = abs(cos(rad)), sinA = abs(sin(rad))
        let tw = Double(wmW) * cosA + Double(wmH) * sinA
        let th = Double(wmW) * sinA + Double(wmH) * cosA
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
                drawImageTopLeftRelative(ctx, wm, CGRect(x: -Double(wmW) / 2, y: -Double(wmH) / 2,
                                                         width: Double(wmW), height: Double(wmH)))
                ctx.restoreGState()
                x += stepX
            }
            y += stepY
        }
        ctx.restoreGState()
    }

    // MARK: - EXIF 文字水印 (exif_text.rs)

    private static func drawExifText(_ ctx: CGContext, config: ExifTextConfig, tags: ExifTags,
                                     imgW: Int, imgH: Int, scale: CGFloat) {
        let text = config.customText.isEmpty ? tags.fill(template: config.template) : config.customText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

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

        if config.backgroundEnabled {
            ctx.setFillColor(config.backgroundColor.nsColor
                .withAlphaComponent(config.backgroundAlpha).cgColor)
            ctx.fill(CGRect(x: blockX, y: origin.y, width: blockW, height: blockH))
        }
        // full_width 时文字仍按 margin_x 缩进
        let textX = config.fullWidth ? Double(config.marginX) * scale + padding : Double(origin.x) + padding
        for (index, entry) in ctLines.enumerated() {
            let baselineY = Double(origin.y) + padding + lineHeight * Double(index) + Double(font.ascender)
            drawCTLine(ctx, entry.line, x: textX, baselineTopY: baselineY, canvasH: imgH)
        }
    }

    // MARK: - 相框 (frame.rs)

    private static func applyFrame(_ photo: CGImage, config: FrameConfig, tags: ExifTags) -> CGImage? {
        let pw = photo.width, ph = photo.height
        let short = Double(min(pw, ph))
        let border = (short * config.borderRatio).rounded()
        let barH = (short * config.bottomBarRatio).rounded()
        let newW = pw + Int(border) * 2
        let newH = ph + Int(border) + Int(barH)
        guard let ctx = makeContext(width: newW, height: newH) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(newH))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(config.borderColor.color)
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        drawImageTopLeft(ctx, photo, CGRect(x: border, y: border, width: Double(pw), height: Double(ph)),
                         canvasH: newH)

        let barTop = border + Double(ph)
        // 参数条上方细分隔线
        let sepH = max(barH * 0.015, 1)
        ctx.setFillColor(darken(config.borderColor, 0.85).color)
        ctx.fill(CGRect(x: border, y: barTop, width: Double(newW) - border * 2, height: sepH))

        let innerPad = (barH * 0.15).rounded()
        let mainSize = max(barH * config.fontSizeRatio, 10)
        let subSize = mainSize * 0.85
        let mainFont = NSFont.systemFont(ofSize: mainSize, weight: .semibold)
        let subFont = NSFont.systemFont(ofSize: subSize, weight: .regular)
        let blockH = mainSize + subSize * 0.2 + subSize
        let textY0 = barTop + (barH - blockH) / 2

        func makeLine(_ text: String, _ font: NSFont, _ color: RGB) -> (CTLine, Double)? {
            guard !text.isEmpty else { return nil }
            let attr = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color.nsColor,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            return (line, CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        // 左块两行
        let left1 = makeLine(tags.fillStripMissing(template: config.leftLine1), mainFont, config.textColor)
        let left2 = makeLine(tags.fillStripMissing(template: config.leftLine2), subFont, config.subtextColor)
        if let (line, _) = left1 {
            drawCTLine(ctx, line, x: border + innerPad,
                       baselineTopY: textY0 + Double(mainFont.ascender), canvasH: newH)
        }
        if let (line, _) = left2 {
            drawCTLine(ctx, line, x: border + innerPad,
                       baselineTopY: textY0 + mainSize * 1.15 + Double(subFont.ascender), canvasH: newH)
        }

        // 右块两行（右对齐）
        let right1 = makeLine(tags.fillStripMissing(template: config.rightLine1), mainFont, config.textColor)
        let right2 = makeLine(tags.fillStripMissing(template: config.rightLine2), subFont, config.subtextColor)
        let rightEdge = Double(newW) - border - innerPad
        var maxRightW = 0.0
        if let (line, width) = right1 {
            maxRightW = max(maxRightW, width)
            drawCTLine(ctx, line, x: rightEdge - width,
                       baselineTopY: textY0 + Double(mainFont.ascender), canvasH: newH)
        }
        if let (line, width) = right2 {
            maxRightW = max(maxRightW, width)
            drawCTLine(ctx, line, x: rightEdge - width,
                       baselineTopY: textY0 + mainSize * 1.15 + Double(subFont.ascender), canvasH: newH)
        }

        // 右块左侧竖分隔线（Canon 风）
        if config.showDivider, maxRightW > 0 {
            let thickness = max(barH * 0.02, 1)
            let dividerMargin = (barH * 0.2).rounded()
            let x = rightEdge - maxRightW - innerPad
            ctx.setFillColor(darken(config.borderColor, 0.7).color)
            ctx.fill(CGRect(x: x, y: barTop + dividerMargin,
                            width: thickness, height: barH - dividerMargin * 2))
        }

        // 中央品牌名
        if config.showBrand, let brand = tags.values["brand"], !brand.isEmpty {
            let brandSize = max(barH * config.brandSizeRatio, 12)
            let brandFont = NSFont.systemFont(ofSize: brandSize, weight: .bold)
            if let (line, width) = makeLine(brand, brandFont, config.textColor) {
                let y = barTop + (barH - brandSize) / 2
                drawCTLine(ctx, line, x: (Double(newW) - width) / 2,
                           baselineTopY: y + Double(brandFont.ascender), canvasH: newH)
            }
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
        guard let ctx = makeContext(width: newW, height: newH) else { return nil }
        ctx.setFillColor(config.fillColor.color)
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        ctx.draw(image, in: CGRect(x: (Double(newW) - w) / 2, y: (Double(newH) - h) / 2,
                                   width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - 导出 (batch.rs 管线)

    /// 单张导出：解码全尺寸 → compose → 可选长边缩放 → JPEG 编码（EXIF 保留，
    /// orientation 已烘焙进像素所以剥掉标签）。
    static func exportPhoto(source: URL, to dest: URL, signature: CGImage?,
                            config: Config, options: ExportOptions) -> Bool {
        // 绝不写回源文件：后缀被清空 + 输出目录选成照片原目录时 dest == source，
        // 原片会被带水印的版本静默替换掉（不可恢复）。
        guard !isSameFile(source, dest) else { return false }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let base = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 20000,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return false }

        let tags = ExifTags(source: src)
        guard var composed = compose(base: base, signature: signature, config: config,
                                     tags: tags, scale: 1.0) else { return false }

        if options.maxLongSide > 0 {
            let long = max(composed.width, composed.height)
            if long > options.maxLongSide {
                let scale = Double(options.maxLongSide) / Double(long)
                let nw = max(1, Int((Double(composed.width) * scale).rounded()))
                let nh = max(1, Int((Double(composed.height) * scale).rounded()))
                if let ctx = makeContext(width: nw, height: nh) {
                    ctx.interpolationQuality = .high
                    ctx.draw(composed, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                    if let resized = ctx.makeImage() { composed = resized }
                }
            }
        }

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = options.quality
        props.removeValue(forKey: kCGImagePropertyOrientation)
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(out, composed, props as CFDictionary)
        return CGImageDestinationFinalize(out)
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

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 在"已翻转为 top-left"的 context 里画图：CG 的 draw 期望 bottom-left rect，
    /// 且翻转坐标系会让图像上下颠倒，这里局部再翻回来。
    private static func drawImageTopLeft(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect, canvasH: Int) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// 平铺用：当前变换原点已在 tile 中心，rect 是相对坐标。
    private static func drawImageTopLeftRelative(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect) {
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
