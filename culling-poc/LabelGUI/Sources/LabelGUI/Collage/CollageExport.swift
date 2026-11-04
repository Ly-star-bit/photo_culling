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
        /// 第几页（从 1 起）的 JPEG 读不了、放不进 PDF。
        case pdfPage(Int)
        /// 写完读回来校验没过（盘满、拔盘：CGContext 的 PDF 接口不报写盘错误）：临时文件已经删了。
        case pdfIncomplete(String)
        /// 正式名上已经有文件了（不覆盖）。
        case pdfExists(String)

        var errorDescription: String? {
            switch self {
            case .encode(let name): return "写入「\(name)」失败 (检查输出目录权限/磁盘空间)"
            case .pdf: return "生成 PDF 失败"
            case .pdfPage(let n): return "生成 PDF 失败：第 \(n) 页读不了"
            case .pdfIncomplete(let why): return "PDF 没写完整（\(why)），没留下 (检查输出目录的磁盘空间)"
            case .pdfExists(let name): return "「\(name)」已经有了，PDF 没覆盖它"
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
        tileRects(width: image.width, height: image.height, rows: rows, cols: cols).compactMap { image.cropping(to: $0) }
    }

    /// 切片的整数边界（阅读顺序）：导出切图和拼图整页水印「每片一个」共用，水印落在哪片和切出来的一致。
    static func tileRects(width w: Int, height h: Int, rows: Int, cols: Int) -> [CGRect] {
        var rects: [CGRect] = []
        for r in 0..<max(1, rows) {
            let y0 = Int((Double(h) * Double(r) / Double(rows)).rounded())
            let y1 = Int((Double(h) * Double(r + 1) / Double(rows)).rounded())
            for c in 0..<max(1, cols) {
                let x0 = Int((Double(w) * Double(c) / Double(cols)).rounded())
                let x1 = Int((Double(w) * Double(c + 1) / Double(cols)).rounded())
                rects.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        return rects
    }

    // MARK: - PDF（相册印刷）

    private static func boxData(_ rect: CGRect) -> CFData {
        var box = rect
        return Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
    }

    /// 进 PDF 的一页 JPEG：编码好的数据，或者已经写在盘上的文件（相册 JPEG 格式时就是那个跨页的成品：写 PDF 时
    /// 逐页从盘上读，不用把几十个跨页的 JPEG 都攒在内存里）。
    enum PDFPage: Sendable {
        case data(Data)
        case file(URL)
    }

    static func writePDF(jpegPages: [Data], canvas: CollageCanvas, to url: URL, title: String,
                         cropMarks: Bool, overwrite: Bool = true) throws {
        try writePDF(pages: jpegPages.map { .data($0) }, canvas: canvas, to: url, title: title, cropMarks: cropMarks,
                     overwrite: overwrite)
    }

    /// 先写到同目录的隐藏临时文件（.<名字>.<随机>.tmp），写完读回来校验（大小 > 0、结尾有 %%EOF、CGPDFDocument 打得开、
    /// 页数 = pages.count），过了才改成正式名；没过删掉临时文件、抛错。CGContext 的 PDF 接口不报写盘错误（closePDF 是
    /// Void），盘满、拔盘只能这样查出来，不然一份截断的 PDF 会顶着正式名当成功。
    /// overwrite = false：正式名上已经有文件就不改名、报错（导出按钮：名字是这次新起的，中途冒出同名的也不覆盖）。
    /// afterClose：自检用，临时文件写完、校验之前调一次（模拟写一半盘满）。
    static func writePDF(pages: [PDFPage], canvas: CollageCanvas, to url: URL, title: String, cropMarks: Bool,
                         overwrite: Bool = true, afterClose: ((URL) -> Void)? = nil) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        var committed = false
        defer { if !committed { try? fm.removeItem(at: tmp) } }
        // 上下文在池子里放掉：文件要关上（数据都落进文件）以后才能读回来校验。
        try autoreleasepool {
            try drawPDF(pages: pages, canvas: canvas, to: tmp, title: title, cropMarks: cropMarks)
        }
        afterClose?(tmp)
        if let why = verifyPDF(at: tmp, pages: pages.count) { throw ExportError.pdfIncomplete(why) }
        do {
            if overwrite, fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                // moveItem 目标已存在就失败（不覆盖）；exFAT、SMB 上也能用（不靠 RENAME_EXCL）。
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            if !overwrite, fm.fileExists(atPath: url.path) { throw ExportError.pdfExists(url.lastPathComponent) }
            throw ExportError.pdfIncomplete("改名失败：\(error.localizedDescription)")
        }
        committed = true
    }

    /// 读回来核对一份 PDF：nil = 没问题，否则说哪里不对。只看结构（大小、结尾、页数），不解码图像。
    static func verifyPDF(at url: URL, pages expected: Int) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return "文件是空的" }
        // 结尾没有 %%EOF = 没写完：CoreGraphics 打开截断的 PDF 会自己修，光看页数不一定看得出来。
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return "读不回来" }
        defer { try? handle.close() }
        let tailLength = min(size, 1024)
        let tail: Data
        do {
            try handle.seek(toOffset: UInt64(size - tailLength))
            tail = try handle.readToEnd() ?? Data()
        } catch {
            return "读不回来"
        }
        guard tail.range(of: Data("%%EOF".utf8)) != nil else { return "结尾不完整" }
        guard let doc = CGPDFDocument(url as CFURL) else { return "打不开" }
        guard doc.numberOfPages == expected else { return "只有 \(doc.numberOfPages) 页，应该是 \(expected) 页" }
        return nil
    }

    /// 每页 = 一张带出血的跨页（已编码好的 JPEG，原样嵌入 PDF）。MediaBox 在出血外再留
    /// 裁切线的空白；BleedBox/TrimBox 写进页面字典，印厂的 PDF 检查器按它们识别成品尺寸。
    /// 收的是 JPEG 而不是位图：一个 30×30cm 跨页位图 ~100MB，40 页攒着就是 4GB。
    /// 哪一页的 JPEG 读不了就停下、抛错（以前那一页留白照样出 PDF）。
    private static func drawPDF(pages: [PDFPage], canvas: CollageCanvas, to url: URL, title: String,
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
        for (i, page) in pages.enumerated() {
            let provider: CGDataProvider?
            switch page {
            case .data(let data): provider = CGDataProvider(data: data as CFData)
            case .file(let file): provider = CGDataProvider(url: file as CFURL)
            }
            guard let provider,
                  let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                     intent: .defaultIntent) else {
                ctx.closePDF()
                throw ExportError.pdfPage(i + 1)
            }
            ctx.beginPDFPage(pageInfo as CFDictionary)
            ctx.draw(jpeg, in: bleedBox)
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
