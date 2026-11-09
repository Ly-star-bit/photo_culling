import Foundation
import CoreGraphics
import CoreText
import ImageIO

// MARK: - 看版 PDF（相册 B · P5）
//
// 给客户看的低清合并 PDF：每个跨页一页（长边约 2000 px、JPEG 0.75），页脚印「跨页 7 / 20 · 标题」和这一页的照片文件名
// （阅读顺序）—— 客户回「第 7 页把 DSCF7212 换掉」能直接对上。不带出血、裁切线、参考线、占位框；水印照这个拼图的
// 「导出带水印」（看版通常要带）。永远 sRGB（客户在屏幕上看）。文件名「名_看版.pdf」，同名加 -2 不覆盖（exportBase）。
// 页脚的字用 CoreText 直接画在 PDF 页上（不烙进图里），PDFKit 读得出来（自检按它断言）。

enum CollageProofPDF {
    /// 每页画面的长边（像素）。
    static let longSide = 2000.0
    static let quality = 0.75
    /// 画面在 PDF 上的点数 / 像素（144 dpi：2000 px 宽的跨页 = 1000 pt，看版 PDF 的页面不用太大）。
    static let pointsPerPixel = 0.5

    /// 一页：画面（JPEG）+ 页脚。
    struct Page: Sendable {
        var jpeg: Data
        var pixelWidth: Int
        var pixelHeight: Int
        /// 第一行：「跨页 7 / 20 · 标题」（封面那一页由封面自己给）。
        var heading: String
        /// 第二行起：这一页的照片文件名（阅读顺序）。
        var names: [String]
    }

    /// 看版文件名（「名_看版.pdf」）。
    static func fileName(base: String) -> String { "\(base)_看版.pdf" }

    /// 页脚第一行。
    static func heading(index: Int, count: Int, title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "跨页 \(index + 1) / \(count)" + (t.isEmpty ? "" : " · \(t)")
    }

    /// 这一页的照片文件名，按阅读顺序：相册先左页、再右页（看中心落在哪一边），同一页先上后下、先左后右（上沿差不到
    /// 画布高的 2% 算同一行）；相纸（自由图层）按中心排在一起。印样页按帧的顺序。同一张出现两次就列两次（客户看得到）。
    static func photoNames(page: CollagePage, project: CollageProject) -> [String] {
        let canvas = project.canvas
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        func fileName(_ id: String) -> String? {
            guard let p = photos[id] else { return nil }
            let name = URL(fileURLWithPath: p.path).lastPathComponent
            return name.isEmpty ? p.id : name
        }
        if let sheet = page.contactSheet {
            return Array(sheet.frames.prefix(sheet.frameLimit)).compactMap(fileName)
        }
        var spots: [(id: String, rect: CGRect)] = []
        if !page.freeform {
            for f in CollageLayout.pageGeometry(page.root, canvas: canvas, style: project.style).frames
            where f.cell.kind == .photo && !f.rect.isEmpty {
                if let id = f.cell.photoID { spots.append((id, f.rect.cgRect)) }
            }
        }
        for item in page.items where item.kind == .photo {
            if let id = item.photoID { spots.append((id, CollageItems.bounds(item, canvas: canvas))) }
        }
        let half = CGFloat(canvas.width) / 2
        let rowTolerance = CGFloat(canvas.height) * 0.02
        let fold = canvas.seams == .fold
        let sorted = spots.sorted { a, b in
            let sa = fold && a.rect.midX >= half ? 1 : 0
            let sb = fold && b.rect.midX >= half ? 1 : 0
            if sa != sb { return sa < sb }
            if abs(a.rect.minY - b.rect.minY) > rowTolerance { return a.rect.minY < b.rect.minY }
            return a.rect.minX < b.rect.minX
        }
        return sorted.compactMap { fileName($0.id) }
    }

    /// 渲一个跨页（成品区、不带出血，长边 2000 px）、编成 JPEG 0.75。渲不出来 = nil。
    static func render(_ index: Int, project: CollageProject, hints: [String: CollageCrop.Hints]) -> Page? {
        guard project.pages.indices.contains(index) else { return nil }
        let page = project.pages[index]
        let canvas = project.canvas
        var opts = CollageRender.Options(scale: min(1, longSide / Double(max(1, max(canvas.width, canvas.height)))))
        opts.includeBleed = false
        opts.export = true
        opts.watermark = project.watermark?.exportEnabled ?? true
        guard let image = CollageRender.render(page: page, project: project, hints: hints, options: opts),
              let jpeg = CollageExport.encode(image, format: .jpeg, quality: quality, dpi: 144) else { return nil }
        return Page(jpeg: jpeg, pixelWidth: image.width, pixelHeight: image.height,
                    heading: heading(index: index, count: project.pages.count, title: project.title),
                    names: photoNames(page: page, project: project))
    }

    // MARK: 写 PDF

    private static func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func attributed(_ text: String, size: CGFloat, bold: Bool = false, gray: CGFloat) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    /// 页脚排在宽 width 里要多高（点）。
    private static func footerHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(size.height)
    }

    private static func footerText(_ page: Page) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: attributed(page.heading, size: 13, bold: true, gray: 0.12))
        if !page.names.isEmpty {
            text.append(attributed("\n" + page.names.joined(separator: "   "), size: 11, gray: 0.3))
        }
        return text
    }

    /// 写看版 PDF：每页画面在上、页脚在下（白底）。先写同目录的隐藏临时文件（.<名字>.pdf.<8 位大写十六进制>.tmp，
    /// 和 CollageExport.writePDF 同一种：sweepStalePDFTemps 认得、崩溃留下的会被清掉），读回来核对（结尾 %%EOF、页数对）
    /// 再改成正式名；正式名上已经有文件就报错、不覆盖。pages 要按顺序给全（封面在最前，见 CollageStore.startProofPDF）。
    static func write(_ pages: [Page], to url: URL, title: String) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        var committed = false
        defer { if !committed { try? fm.removeItem(at: tmp) } }
        try autoreleasepool {
            try draw(pages, to: tmp, title: title)
        }
        if let why = CollageExport.verifyPDF(at: tmp, pages: pages.count) {
            throw CollageExport.ExportError.pdfIncomplete(why)
        }
        do {
            try fm.moveItem(at: tmp, to: url)
        } catch {
            if fm.fileExists(atPath: url.path) { throw CollageExport.ExportError.pdfExists(url.lastPathComponent) }
            throw CollageExport.ExportError.pdfIncomplete("改名失败：\(error.localizedDescription)")
        }
        committed = true
    }

    private static func draw(_ pages: [Page], to url: URL, title: String) throws {
        let info: [CFString: Any] = [
            kCGPDFContextCreator: "选片工具",
            kCGPDFContextTitle: title.isEmpty ? "看版" : "\(title) · 看版",
        ]
        var first = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &first, info as CFDictionary) else {
            throw CollageExport.ExportError.pdf
        }
        let margin: CGFloat = 18
        for (i, page) in pages.enumerated() {
            guard let provider = CGDataProvider(data: page.jpeg as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else {
                ctx.closePDF()
                throw CollageExport.ExportError.pdfPage(i + 1)
            }
            let imageW = CGFloat(page.pixelWidth) * pointsPerPixel
            let imageH = CGFloat(page.pixelHeight) * pointsPerPixel
            let text = footerText(page)
            let textW = imageW - margin * 2
            let footerH = footerHeight(text, width: textW) + margin * 2
            var media = CGRect(x: 0, y: 0, width: imageW, height: imageH + footerH)
            let boxInfo: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(boxInfo as CFDictionary)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(media)
            // PDF 原点在左下：画面在上、页脚在下。
            ctx.draw(image, in: CGRect(x: 0, y: footerH, width: imageW, height: imageH))
            let path = CGPath(rect: CGRect(x: margin, y: margin, width: textW, height: footerH - margin * 2), transform: nil)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),
                                                 CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
