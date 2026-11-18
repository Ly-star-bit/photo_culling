import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 选片确认表的水印（客户菜单「导出选片确认表」里的「带水印（用水印页的签名）」，默认关）

/// 确认表小样上的水印：水印页的签名和文字，裁成一个低调的左下角标 —— 右上角压着客户点的 ♥，斜纹平铺 / 居中会挡脸，
/// 客户就挑不了片了。相框、画布比例会改画布尺寸，强制关（和带进拼图一样只收签名和文字）。
/// 主线程从水印页拍快照（WatermarkStore.proofWatermark()），交给后台每张 800px 小样在内存里画一遍：
/// 预览文件（previewPath）一个字节不动，编号、表号、proof_sheets.json 也都不受影响。
/// @unchecked：CGImage 不是 Sendable，可拍完快照以后谁都不改它。
struct ProofWatermark: @unchecked Sendable {
    let config: WatermarkEngine.Config
    let signature: CGImage?

    /// 不透明度最高到这（水印页设得再实，确认表上也是淡淡的一个角标）。
    static let opacityCap = 0.5
    /// 签名最宽占短边的比例（水印页默认 0.15）。
    static let sizeRatioCap = 0.2
    /// 读不到原片尺寸时按这个长边算像素边距（常见相机 6000×4000）。
    static let assumedLongEdge = 6000

    /// 水印页的设置 → 确认表的角标：签名、文字都挪到左下，不平铺，淡一点；frame、canvasRatio 关掉。
    /// 签名关着、或者签名图读不出来就只画文字；两样都没有 = nil（没东西可画）。
    static func make(config: WatermarkEngine.Config, signature: CGImage?) -> ProofWatermark? {
        var c = config
        c.frame.enabled = false
        c.canvasRatio.enabled = false
        c.tile.enabled = false
        c.position = .bottomLeft
        c.landscapeOverrideEnabled = false
        c.opacity = min(c.opacity, opacityCap)
        c.sizeRatio = min(c.sizeRatio, sizeRatioCap)
        c.exifText.position = .bottomLeft
        c.exifText.opacity = min(c.exifText.opacity, opacityCap)
        let sig = c.signatureEnabled ? signature : nil
        c.signatureEnabled = sig != nil
        guard c.signatureEnabled || c.exifText.enabled else { return nil }
        return ProofWatermark(config: c, signature: sig)
    }

    /// 在一张小样上画（不改 `image`，返回新的一张；画不上 = nil）。`original` = 原片路径：水印页的像素边距是按原片给的，
    /// 按「小样长边 / 原片长边」缩；文字模板（{model} 这些）的 EXIF 也从原片读（1024 预览不一定带 EXIF）。都只读文件头。
    /// 真画上了东西才算画上：只开了 EXIF 文字模板、原片读不到（外接盘没插）或者没有 EXIF 时模板填出来是空的，一个字都不画；
    /// 签名比画面还大被跳过的也一样 —— 都返回 nil（这张不放进确认表），以前照样把干净的小样交回去、状态栏还写「带水印」。
    /// `referenceLong` = 这张图对应原片上多长（像素）：脸部特写（GP-03）是原片上的一块，边距按那一块缩，不按整张原片；
    /// nil = 整张原片（读文件头）。
    func apply(to image: CGImage, original: String, referenceLong: Int? = nil) -> CGImage? {
        let source = original.isEmpty ? nil : CGImageSourceCreateWithURL(URL(fileURLWithPath: original) as CFURL, nil)
        let full = referenceLong == nil ? source.flatMap { WatermarkEngine.uprightSize(of: $0) } : nil
        let baseLong = max(image.width, image.height)
        let fullLong = referenceLong ?? full.map { max($0.width, $0.height) } ?? Self.assumedLongEdge
        let scale = CGFloat(baseLong) / CGFloat(max(fullLong, baseLong))
        let needsTags = config.exifText.enabled && config.exifText.customText.isEmpty
        let tags = WatermarkEngine.ExifTags(source: needsTags ? source : nil)
        let text = drawsText(tags)
        if signature == nil && !text { return nil }
        guard let composed = WatermarkEngine.compose(base: image, signature: signature, config: config, tags: tags,
                                                     scale: scale) else { return nil }
        guard text || !composed.signatureSkipped else { return nil }
        return composed.image
    }

    /// 文字会不会画出来：自定义文字不是空的，或者模板按这张的 EXIF 填出来不是空的（和 WatermarkEngine.layoutExifText 同一个判断）。
    func drawsText(_ tags: WatermarkEngine.ExifTags) -> Bool {
        guard config.exifText.enabled else { return false }
        let custom = config.exifText.customText
        let text = custom.isEmpty ? tags.fillStripMissing(template: config.exifText.template) : custom
        return !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 只靠 EXIF 文字模板（没签名、没写自定义文字）：画什么要看每张原片里的相机参数，原片读不到、没有 EXIF 的画不上。
    var needsOriginalEXIF: Bool { signature == nil && config.exifText.enabled && config.exifText.customText.isEmpty }

    /// 有几张画不上水印时状态栏上说的原因。
    var skipReason: String {
        needsOriginalEXIF
            ? "水印只开了 EXIF 参数文字，要读原片里的相机参数：原片读不到（外接盘没插？）或没有 EXIF 的画不上 —— " +
              "插上原片所在的盘，或在水印页写一句自定义文字 / 选签名"
            : "预览读不出来或水印画不上"
    }
}

// MARK: - 确认表的脸部特写（优化分析 GP-03）

/// 确认表小样是 800px，全身照里客户的脸只有五六十到一百来个像素（photot 21 张中位 78），手机一列时显示出来约 42pt：
/// 看不清眼睛、表情，客户就回头要原图，或者选完又改。导出时按分析出来的人脸框从**原片**裁一块特写（边长 360px），
/// 放进这张的「放大」层（ProofSheetPage）。800px 小样本身不变（11-04 的 M06：小样故意不大，免得直接拿去当成片用）。
///
/// - 只给小样里脸宽不到 160px 的脸加（大于这个在小样上就看得清）；一张最多 4 张脸（面积大的 4 张，按从左到右排）。
/// - 裁的那块 = 脸框（分析时已外扩 15%）再放大到 1.5 倍的正方形：带上头发和下巴；贴着边的往里挪，不压扁。
/// - 原片按 JPEG 的 DCT 档（1/8、1/4、1/2、整幅）解够用的最小一档（裁出来够 360 的 3/4 就行，宁可特写小一点也不整幅解：
///   整幅 4 路 peak 多好几百 MB），40MP 的多半解一半；转正（框是按转正后的图给的）。
///   纯 RAW 的只用相机内嵌的 JPEG 预览（不做一张张 demosaic：几百张的确认表会从几秒变成几分钟），内嵌的太小、比例不对就不加。
/// - 原片读不到（外接盘没插）、裁出来没比小样上清楚多少：这张不加特写，照常导出。
/// - 带水印的确认表：特写上也画同一个左下角标（边距按特写在原片上那一块算）；画不上就不加这张的特写。
/// - 转成 sRGB 再编码：微信内置浏览器不一定认 JPEG 里的 ICC。
enum ProofFaceCrops {
    /// 确认表小样的长边（BatchStore.contactSheetJPEG）。
    static let sampleEdge = 800
    /// 小样里脸宽不到这个才加特写。
    static let smallFaceInSample = 160.0
    /// 特写的边长（像素）。photot 21 张（每张一张小脸）实测：400 / q0.72 整份确认表 +43%，360 / q0.7 +32%（每张特写平均
    /// 约 29 KB、base64 后约 40 KB），320 / q0.7 +27% 但睫毛、发丝明显糊。取 360。见 ProofSheetPage.faceBytesPerPhoto。
    static let outputEdge = 360
    /// 解原片时裁出来的那块够 outputEdge 的这个比例就行（不够再上一档 DCT）。
    static let minDecodedFraction = 0.75
    static let maxFaces = 4
    /// 脸框外再放大的倍数（框本身已经外扩了 15%）。
    static let contextScale = 1.5
    static let quality = 0.7

    struct Result {
        var crops: [Data] = []
        /// 原片读不到（没这个文件、不是图）：状态栏点出来。
        var originalMissing = false
    }

    /// 这张照片要裁哪几张脸：小样里脸宽不到 160px 的，面积大的前 4 张，按从左到右。`width` / `height` = 原片转正后的尺寸。
    static func pick(_ faces: [[Double]], width: Int, height: Int) -> [[Double]] {
        let long = Double(max(width, height))
        guard long > 0 else { return [] }
        let scale = Double(sampleEdge) / long
        let small = faces.filter { b in
            b.count == 4 && b[2] > b[0] && b[3] > b[1] && (b[2] - b[0]) * Double(width) * scale < smallFaceInSample
        }
        let biggest = small.sorted { ($0[2] - $0[0]) * ($0[3] - $0[1]) > ($1[2] - $1[0]) * ($1[3] - $1[1]) }.prefix(maxFaces)
        return biggest.sorted { $0[0] + $0[2] < $1[0] + $1[2] }
    }

    /// 裁的那块（原片转正后的像素坐标，左上原点）：脸框中心不动、边长放大到 1.5 倍的正方形，贴边的往里挪，比原片还大就缩到原片短边。
    static func cropRect(_ b: [Double], width: Int, height: Int) -> CGRect {
        let w = Double(width), h = Double(height)
        let side = min(min(w, h), max((b[2] - b[0]) * w, (b[3] - b[1]) * h) * contextScale)
        let cx = (b[0] + b[2]) / 2 * w, cy = (b[1] + b[3]) / 2 * h
        let x = min(max(0, cx - side / 2), w - side), y = min(max(0, cy - side / 2), h - side)
        return CGRect(x: x, y: y, width: side, height: side).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// 解原片要解多大（长边）：让每一块都够 360 × 3/4 = 270px 的最小 DCT 档（1/8、1/4、1/2）；都不够 = 整幅。
    static func decodeEdge(for rects: [CGRect], long: Int) -> Int {
        let smallest = rects.map { min($0.width, $0.height) }.min() ?? 0
        guard smallest > 0 else { return long }
        let needed = Double(outputEdge) * minDecodedFraction * Double(long) / Double(smallest)
        for k in [3, 2, 1] where Double(long >> k) >= needed { return long >> k }
        return long
    }

    /// 给一张照片做特写。`original` = 原片（decodePath：RAW+JPG 是那张 JPG，纯 RAW 是 RAW）。
    static func make(original: String, faces: [[Double]], watermark: ProofWatermark?) -> Result {
        var result = Result()
        guard !faces.isEmpty else { return result }
        let url = URL(fileURLWithPath: original)
        guard !original.isEmpty, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = WatermarkEngine.uprightSize(of: src) else {
            result.originalMissing = true
            return result
        }
        let chosen = pick(faces, width: full.width, height: full.height)
        guard !chosen.isEmpty else { return result }
        let long = max(full.width, full.height)
        let rects = chosen.map { cropRect($0, width: full.width, height: full.height) }
        guard let decoded = decode(src, url: url, edge: decodeEdge(for: rects, long: long), full: full) else { return result }
        let k = Double(decoded.width) / Double(full.width)
        for rect in rects {
            let scaled = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).integral
            // 解出来的那块比小样上同一块大不到 1.6 倍：放进特写也不比小样清楚，不加。
            let sampleSide = Double(rect.width) * Double(sampleEdge) / Double(long)
            guard Double(min(scaled.width, scaled.height)) >= sampleSide * 1.6,
                  let piece = decoded.cropping(to: scaled),
                  var crop = srgbResized(piece, edge: min(outputEdge, Int(min(scaled.width, scaled.height))))
            else { continue }
            if let watermark {
                guard let marked = watermark.apply(to: crop, original: original, referenceLong: Int(rect.width)) else { continue }
                crop = marked
            }
            if let data = jpeg(crop) { result.crops.append(data) }
        }
        return result
    }

    /// 解原片（转正）。JPEG 等：解到 `edge`（DCT 档，UprightDecode 竖拍走 vImage 转）；纯 RAW：只要相机内嵌的预览，
    /// 比例和原片对不上（内嵌的是裁过的 16:9 之类）就不用。
    private static func decode(_ src: CGImageSource, url: URL, edge: Int,
                               full: (width: Int, height: Int)) -> CGImage? {
        guard ImageLoader.rawExtensions.contains(url.pathExtension.lowercased()) else {
            return UprightDecode.thumbnail(src, maxPixel: edge)
        }
        guard let embedded = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) else { return nil }
        let aspect = Double(full.width) / Double(full.height)
        let got = Double(embedded.width) / Double(max(1, embedded.height))
        return abs(got - aspect) <= aspect * 0.02 ? embedded : nil
    }

    /// 缩到边长 `edge` 的正方形、画进 sRGB（真转换：微信内置浏览器不一定认 ICC）。相机直出没嵌 ICC 的 Adobe RGB 这里
    /// 当 sRGB 画（和确认表小样一样，小样也是这么来的）。
    private static func srgbResized(_ image: CGImage, edge: Int) -> CGImage? {
        guard edge > 0, let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        return ctx.makeImage()
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - 导出选片确认表：保存面板下面的「套餐含 N 张」

/// 保存面板下面那一行：「套餐含 [  ] 张 · 选超了只提示、不拦」。默认填这一场上次导出那张表的张数（每单的套餐不一样，
/// 不跨场次记）；空着 = 不限。
@MainActor
final class ProofSheetSaveAccessory {
    let view: NSView
    private let field: NSTextField

    init(quota: Int?) {
        let label = NSTextField(labelWithString: "套餐含")
        field = NSTextField(string: quota.map(String.init) ?? "")
        field.placeholderString = "不限"
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let unit = NSTextField(labelWithString: "张 · 客户选超了只提示、不拦（超出的算加片），空着 = 不限")
        unit.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, field, unit])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        view = row
    }

    /// 填的张数；没填、不是正整数 = nil（不限）。
    var quota: Int? { Self.parse(field.stringValue) }

    nonisolated static func parse(_ text: String) -> Int? {
        let digits = ClientReply.halfwidth(text).trimmingCharacters(in: .whitespaces)
        guard let n = Int(digits), n > 0 else { return nil }
        return min(n, 9999)
    }
}
