import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 拼图成品落盘：单张、九宫格、轮播、相册跨页（JPEG + PDF）。
enum CollageExport {

    enum Format: String, Codable, CaseIterable, Hashable {
        case jpeg, png, tiff

        var ext: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .tiff: return "tif"
            }
        }

        var label: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            case .tiff: return "TIFF"
            }
        }

        var uti: CFString {
            switch self {
            case .jpeg: return UTType.jpeg.identifier as CFString
            case .png: return UTType.png.identifier as CFString
            case .tiff: return UTType.tiff.identifier as CFString
            }
        }
    }

    enum ExportError: LocalizedError {
        case encode(String)
        case pdf

        var errorDescription: String? {
            switch self {
            case .encode(let name): return "写入「\(name)」失败 (检查输出目录权限/磁盘空间)"
            case .pdf: return "生成 PDF 失败"
            }
        }
    }

    static func encode(_ image: CGImage, format: Format, quality: Double, dpi: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.uti, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL, format: Format, quality: Double, dpi: Double) throws {
        guard let data = encode(image, format: format, quality: quality, dpi: dpi) else {
            throw ExportError.encode(url.lastPathComponent)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.encode(url.lastPathComponent)
        }
    }

    /// 去掉出血，只留成品区。
    static func trimmed(_ image: CGImage, bleed: Int) -> CGImage? {
        guard bleed > 0 else { return image }
        let rect = CGRect(x: bleed, y: bleed, width: image.width - bleed * 2, height: image.height - bleed * 2)
        return image.cropping(to: rect)
    }

    /// 按整数边界切 rows×cols 块，阅读顺序（先行后列）。
    static func split(_ image: CGImage, rows: Int, cols: Int) -> [CGImage] {
        let w = image.width
        let h = image.height
        var tiles: [CGImage] = []
        for r in 0..<max(1, rows) {
            let y0 = Int((Double(h) * Double(r) / Double(rows)).rounded())
            let y1 = Int((Double(h) * Double(r + 1) / Double(rows)).rounded())
            for c in 0..<max(1, cols) {
                let x0 = Int((Double(w) * Double(c) / Double(cols)).rounded())
                let x1 = Int((Double(w) * Double(c + 1) / Double(cols)).rounded())
                if let tile = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) {
                    tiles.append(tile)
                }
            }
        }
        return tiles
    }

    // MARK: - PDF（相册印刷）

    private static func boxData(_ rect: CGRect) -> CFData {
        var box = rect
        return Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
    }

    /// 每页 = 一张带出血的跨页（已编码好的 JPEG 数据，原样嵌入 PDF）。MediaBox 在出血外再留
    /// 裁切线的空白；BleedBox/TrimBox 写进页面字典，印厂的 PDF 检查器按它们识别成品尺寸。
    /// 收的是 JPEG 数据而不是位图：一个 30×30cm 跨页位图 ~100MB，40 页攒着就是 4GB。
    static func writePDF(jpegPages: [Data], canvas: CollageCanvas, to url: URL, title: String,
                         cropMarks: Bool) throws {
        let ptPerPx = 72.0 / max(1, canvas.dpi)
        let trimW = Double(canvas.width) * ptPerPx
        let trimH = Double(canvas.height) * ptPerPx
        let bleed = Double(canvas.bleed) * ptPerPx
        let slug = cropMarks ? 10.0 / 25.4 * 72 : 0
        var media = CGRect(x: 0, y: 0, width: trimW + bleed * 2 + slug * 2, height: trimH + bleed * 2 + slug * 2)
        let bleedBox = CGRect(x: slug, y: slug, width: trimW + bleed * 2, height: trimH + bleed * 2)
        let trimBox = bleedBox.insetBy(dx: bleed, dy: bleed)
        let info: [CFString: Any] = [
            kCGPDFContextCreator: "选片工具",
            kCGPDFContextTitle: title.isEmpty ? "相册" : title,
        ]
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else { throw ExportError.pdf }
        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: boxData(media),
            kCGPDFContextBleedBox: boxData(bleedBox),
            kCGPDFContextTrimBox: boxData(trimBox),
        ]
        for data in jpegPages {
            ctx.beginPDFPage(pageInfo as CFDictionary)
            if let provider = CGDataProvider(data: data as CFData),
               let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) {
                ctx.draw(jpeg, in: bleedBox)
            }
            if cropMarks { drawCropMarks(ctx, trim: trimBox, bleed: bleed, slug: slug) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// 四角裁切线：沿成品边延伸到出血外，不伸进出血区。
    private static func drawCropMarks(_ ctx: CGContext, trim: CGRect, bleed: Double, slug: Double) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(0.3)
        let gap = bleed + 2
        let length = max(4, slug - 3)
        let xs = [trim.minX, trim.maxX]
        let ys = [trim.minY, trim.maxY]
        for x in xs {
            for y in ys {
                let dx: CGFloat = x == trim.minX ? -1 : 1
                let dy: CGFloat = y == trim.minY ? -1 : 1
                ctx.move(to: CGPoint(x: x + dx * CGFloat(gap), y: y))
                ctx.addLine(to: CGPoint(x: x + dx * CGFloat(gap + length), y: y))
                ctx.move(to: CGPoint(x: x, y: y + dy * CGFloat(gap)))
                ctx.addLine(to: CGPoint(x: x, y: y + dy * CGFloat(gap + length)))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
