import Foundation
import AppKit
import CoreText
import ImageIO

/// 拼图里的文字：字体解析、占位符、横排/竖排、细线、印章。
///
/// 画在「已翻转成左上原点」的 context 里；CTLineDraw 需要未翻转的坐标系，
/// 每一行局部翻回去（同 WatermarkEngine.drawCTLine）。
enum CollageTypeset {

    // MARK: - 字体

    /// PostScript 名按优先级。系统里没有的（楷体在部分 Mac 上要另行下载）会落到下一个。
    static func postScriptNames(_ font: CollageFont, _ weight: CollageWeight, italic: Bool) -> [String] {
        switch font {
        case .songti:
            switch weight {
            case .light: return ["STSongti-SC-Light", "STSongti-SC-Regular", "STSong"]
            case .regular: return ["STSongti-SC-Regular", "STSong"]
            case .bold: return ["STSongti-SC-Bold", "STSongti-SC-Black", "STSongti-SC-Regular"]
            }
        case .kaiti:
            let kai = weight == .bold ? ["STKaitiSC-Bold", "STKaitiSC-Regular"] : ["STKaitiSC-Regular", "STKaiti"]
            return kai + postScriptNames(.songti, weight, italic: false)
        case .pingfang:
            switch weight {
            case .light: return ["PingFangSC-Light", "PingFangSC-Regular"]
            case .regular: return ["PingFangSC-Regular"]
            case .bold: return ["PingFangSC-Semibold", "PingFangSC-Medium"]
            }
        case .didot:
            if italic { return ["Didot-Italic", "Didot"] }
            return weight == .bold ? ["Didot-Bold", "Didot"] : ["Didot"]
        case .bodoni:
            if italic { return ["BodoniSvtyTwoITCTT-BookIta", "BodoniSvtyTwoITCTT-Book"] }
            return weight == .bold ? ["BodoniSvtyTwoITCTT-Bold", "BodoniSvtyTwoITCTT-Book"] : ["BodoniSvtyTwoITCTT-Book"]
        case .newYork:
            return []
        case .baskerville:
            if italic { return weight == .bold ? ["Baskerville-SemiBoldItalic", "Baskerville-Italic"] : ["Baskerville-Italic"] }
            return weight == .bold ? ["Baskerville-SemiBold", "Baskerville"] : ["Baskerville"]
        case .optima:
            if italic { return ["Optima-Italic", "Optima-Regular"] }
            return weight == .bold ? ["Optima-Bold", "Optima-Regular"] : ["Optima-Regular"]
        case .avenir:
            switch weight {
            case .light: return italic ? ["AvenirNext-UltraLightItalic", "AvenirNext-UltraLight"] : ["AvenirNext-UltraLight", "AvenirNext-Regular"]
            case .regular: return italic ? ["AvenirNext-Italic", "AvenirNext-Regular"] : ["AvenirNext-Regular"]
            case .bold: return italic ? ["AvenirNext-DemiBoldItalic", "AvenirNext-DemiBold"] : ["AvenirNext-DemiBold", "AvenirNext-Bold"]
            }
        case .gillSans:
            switch weight {
            case .light: return italic ? ["GillSans-LightItalic", "GillSans-Light"] : ["GillSans-Light", "GillSans"]
            case .regular: return italic ? ["GillSans-Italic", "GillSans"] : ["GillSans"]
            case .bold: return italic ? ["GillSans-SemiBoldItalic", "GillSans-SemiBold"] : ["GillSans-SemiBold", "GillSans"]
            }
        case .futura:
            if italic { return ["Futura-MediumItalic", "Futura-Medium"] }
            return weight == .bold ? ["Futura-Bold", "Futura-Medium"] : ["Futura-Medium"]
        case .hanzipen:
            // 翩翩体在部分 Mac 上要在字体册里另行下载：没有就落到楷体、宋体。
            let pen = weight == .bold ? ["HanziPenSC-W5", "HanziPenSC-W3"] : ["HanziPenSC-W3", "HanziPenSC-W5"]
            return pen + postScriptNames(.kaiti, weight == .bold ? .bold : .regular, italic: false)
        case .bradley:
            return ["BradleyHandITCTT-Bold", "Noteworthy-Light"]
        case .snell:
            return weight == .bold ? ["SnellRoundhand-Bold", "SnellRoundhand"] : ["SnellRoundhand", "SnellRoundhand-Bold"]
        case .typewriter:
            switch weight {
            case .light: return ["AmericanTypewriter-Light", "AmericanTypewriter", "Courier"]
            case .regular: return ["AmericanTypewriter", "Courier"]
            case .bold: return ["AmericanTypewriter-Semibold", "AmericanTypewriter-Bold", "Courier-Bold"]
            }
        }
    }

    private static let fontLock = NSLock()
    private static var fontCache: [String: CTFont] = [:]

    static func font(_ family: CollageFont, _ weight: CollageWeight, italic: Bool, size: CGFloat) -> CTFont {
        let key = "\(family.rawValue)|\(weight.rawValue)|\(italic)|\(Int((size * 4).rounded()))"
        fontLock.lock()
        if let hit = fontCache[key] {
            fontLock.unlock()
            return hit
        }
        fontLock.unlock()
        let resolved = resolveFont(family, weight, italic: italic, size: size)
        fontLock.lock()
        if fontCache.count > 256 { fontCache.removeAll() }
        fontCache[key] = resolved
        fontLock.unlock()
        return resolved
    }

    private static func resolveFont(_ family: CollageFont, _ weight: CollageWeight, italic: Bool, size: CGFloat) -> CTFont {
        for name in postScriptNames(family, weight, italic: italic) {
            let f = CTFontCreateWithName(name as CFString, size, nil)
            if (CTFontCopyPostScriptName(f) as String) == name { return f }
        }
        let nsWeight: NSFont.Weight = weight == .light ? .light : (weight == .bold ? .semibold : .regular)
        let system = NSFont.systemFont(ofSize: size, weight: nsWeight)
        if family == .newYork, let serif = system.fontDescriptor.withDesign(.serif) {
            var descriptor = serif
            if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
            if let f = NSFont(descriptor: descriptor, size: size) { return f as CTFont }
        }
        // 中文字体全缺时：苹方一定在。
        if family == .songti || family == .kaiti || family == .pingfang || family == .hanzipen {
            let f = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
            return f
        }
        return system as CTFont
    }

    // MARK: - 占位符

    private static let exifLock = NSLock()
    private static var exifCache: [String: [String: String]] = [:]

    private static func exifValues(_ path: String) -> [String: String] {
        exifLock.lock()
        if let hit = exifCache[path] {
            exifLock.unlock()
            return hit
        }
        exifLock.unlock()
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        let values = WatermarkEngine.ExifTags(source: source).values
        exifLock.lock()
        exifCache[path] = values
        exifLock.unlock()
        return values
    }

    static func variables(project: CollageProject, root: CollageNode, photos: [String: CollagePhotoRef],
                          pagePhotoIDs: [String]? = nil, pageID: UUID? = nil) -> [String: String] {
        var vars: [String: String] = [:]
        // 没起标题时模板里的 {title} 也要有字：「拾光」是个不挑场合的占位。
        vars["title"] = project.title.isEmpty ? "拾光" : project.title
        vars["subtitle"] = project.subtitle
        // 期号 = 第几页（备选缩略图、单张都是 01）。按页 id 找；散落页的树全是同一个空叶子，
        // 按树比较会把第 2、3 页都认成第 1 页。
        let byID = pageID.flatMap { id in project.pages.firstIndex { $0.id == id } }
        let pageIndex = byID ?? project.pages.firstIndex { $0.root == root } ?? 0
        vars["no"] = String(format: "%02d", pageIndex + 1)
        let onPage = (pagePhotoIDs ?? root.photoIDs).compactMap { photos[$0] }
        vars["count"] = "\(onPage.count)"
        let pool = onPage.isEmpty ? project.photos : onPage
        if let hero = pool.max(by: { $0.score < $1.score }) {
            for (k, v) in exifValues(hero.path) { vars[k] = v }
        }
        if let first = pool.compactMap(\.captureTime).min() {
            for (k, v) in dateVariables(first) { vars[k] = v }
        }
        return vars
    }

    static func dateVariables(_ date: Date) -> [String: String] {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 2026
        let m = c.month ?? 1
        let d = c.day ?? 1
        let monthsEN = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST",
                        "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]
        let monthEN = monthsEN[max(0, min(11, m - 1))]
        var v: [String: String] = [:]
        v["year"] = String(y)
        v["month"] = String(format: "%02d", m)
        v["day"] = String(format: "%02d", d)
        v["date"] = String(format: "%04d.%02d.%02d", y, m, d)
        v["date_iso"] = String(format: "%04d-%02d-%02d", y, m, d)
        v["year_cn"] = chineseDigits(y)
        v["month_cn"] = chineseNumber(m) + "月"
        v["day_cn"] = chineseNumber(d) + "日"
        v["date_cn"] = chineseDigits(y) + "年" + chineseNumber(m) + "月"
        v["date_cn_full"] = chineseDigits(y) + "年" + chineseNumber(m) + "月" + chineseNumber(d) + "日"
        v["year_roman"] = roman(y)
        v["month_en"] = monthEN
        v["month_en_short"] = String(monthEN.prefix(3))
        return v
    }

    /// 2026 → 二〇二六
    static func chineseDigits(_ n: Int) -> String {
        let digits: [Character] = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        return String(String(n).compactMap { ch in ch.wholeNumberValue.map { digits[$0] } })
    }

    /// 1…99 → 一 / 十 / 十一 / 二十一
    static func chineseNumber(_ n: Int) -> String {
        let digits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        guard n > 0, n < 100 else { return String(n) }
        if n < 10 { return digits[n] }
        let tens = n / 10
        let ones = n % 10
        return (tens == 1 ? "" : digits[tens]) + "十" + digits[ones]
    }

    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = max(0, n)
        var out = ""
        for (value, symbol) in table {
            while rest >= value {
                out += symbol
                rest -= value
            }
        }
        return out
    }

    private static let placeholderRegex = try! NSRegularExpression(pattern: "\\{([a-z_0-9]+)(?:\\|([^{}]*))?\\}")

    /// {key} 换成值；没有的键换成空串（不留 "{lens}" 这种字样）。{key|默认} = 没有值时用默认那句
    /// （电影字幕：没填副标题也有一句字，不然点了什么都不出）。
    static func fill(_ template: String, vars: [String: String]) -> String {
        let ns = template as NSString
        var out = ""
        var cursor = 0
        for match in placeholderRegex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let key = ns.substring(with: match.range(at: 1))
            let value = vars[key] ?? ""
            if value.isEmpty, match.range(at: 2).location != NSNotFound {
                out += ns.substring(with: match.range(at: 2))
            } else {
                out += value
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 排版

    private struct Run {
        let line: CTLine
        let width: Double
        let ascent: Double
        let descent: Double
        let size: Double
        let indent: Double
    }

    private static func makeRun(_ string: String, _ spec: CollageTextLine, size: Double) -> Run {
        let font = self.font(spec.font, spec.weight, italic: spec.italic, size: CGFloat(size))
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): spec.color.cgColor,
            NSAttributedString.Key(kCTKernAttributeName as String): NSNumber(value: spec.tracking * size),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        // 末字后面的字距不算宽度，否则居中/右对齐会偏。
        let trimmed = max(0, width - spec.tracking * size)
        return Run(line: line, width: trimmed, ascent: Double(ascent), descent: Double(descent),
                   size: size, indent: spec.indent * size)
    }

    /// 字块在 1 倍（字号按 short 换算）时的外包尺寸。
    static func measure(_ text: CollageText, short: Double, vars: [String: String]) -> CGSize {
        text.vertical ? measureVertical(text, short: short, vars: vars) : measureHorizontal(text, short: short, vars: vars)
    }

    /// 放进 size 里要缩到多少：返回缩放后的 short 和字块尺寸（放得下就是原样）。
    static func fit(_ text: CollageText, in size: CGSize, short: Double, vars: [String: String]) -> (short: Double, size: CGSize) {
        var fitScale = 1.0
        var measured = measure(text, short: short, vars: vars)
        for _ in 0..<3 {
            let fx = Double(size.width) / max(1, Double(measured.width))
            let fy = Double(size.height) / max(1, Double(measured.height))
            let f = min(fx, fy)
            if f >= 1 { break }
            fitScale *= f * 0.98
            measured = measure(text, short: short * fitScale, vars: vars)
        }
        return (short * fitScale, measured)
    }

    /// 已经按 fit 算好字号：原样画进 rect（不再缩）。
    static func drawFitted(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                           vars: [String: String], canvasHeight: Int) {
        guard rect.width > 1, rect.height > 1 else { return }
        if text.vertical {
            drawVertical(text, in: rect, ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight)
        } else {
            drawHorizontal(text, in: rect, ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight)
        }
    }

    static func draw(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                     vars: [String: String], canvasHeight: Int) {
        guard rect.width > 2, rect.height > 2 else { return }
        // 先按 1 倍排一次，放不下就整体按比例缩（用户打了很长的标题也不出界）。
        var fitScale = 1.0
        for _ in 0..<3 {
            let size = text.vertical
                ? measureVertical(text, short: short * fitScale, vars: vars)
                : measureHorizontal(text, short: short * fitScale, vars: vars)
            let fx = Double(rect.width) / max(1, size.width)
            let fy = Double(rect.height) / max(1, size.height)
            let f = min(fx, fy)
            if f >= 1 { break }
            fitScale *= f * 0.98
        }
        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: -2, dy: -2))
        if text.vertical {
            drawVertical(text, in: rect, ctx: ctx, short: short * fitScale, vars: vars, canvasHeight: canvasHeight)
        } else {
            drawHorizontal(text, in: rect, ctx: ctx, short: short * fitScale, vars: vars, canvasHeight: canvasHeight)
        }
        ctx.restoreGState()
    }

    // 横排：逐行按 alignH 对齐；细线、印章跟在最后一行下面。

    private static func horizontalRuns(_ text: CollageText, short: Double, vars: [String: String]) -> [Run] {
        text.lines.compactMap { spec in
            let s = fill(spec.text, vars: vars)
            guard !s.isEmpty else { return nil }
            return makeRun(s, spec, size: spec.size * short)
        }
    }

    private static func measureHorizontal(_ text: CollageText, short: Double, vars: [String: String]) -> CGSize {
        let runs = horizontalRuns(text, short: short, vars: vars)
        var h = 0.0
        var w = 0.0
        for (i, r) in runs.enumerated() {
            h += r.ascent + r.descent
            if i < runs.count - 1 { h += text.lineSpacing * r.size }
            w = max(w, r.width + r.indent)
        }
        let first = runs.first?.size ?? short * 0.04
        if text.rule { h += first * 0.9 }
        if let seal = text.seal { h += first * 0.6 + sealSide(seal, short: short) }
        return CGSize(width: w, height: h)
    }

    private static func drawHorizontal(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                                       vars: [String: String], canvasHeight: Int) {
        let runs = horizontalRuns(text, short: short, vars: vars)
        let block = measureHorizontal(text, short: short, vars: vars)
        var y: Double
        switch text.alignV {
        case .leading: y = Double(rect.minY)
        case .center: y = Double(rect.midY) - Double(block.height) / 2
        case .trailing: y = Double(rect.maxY) - Double(block.height)
        }
        func x(for width: Double, indent: Double) -> Double {
            switch text.alignH {
            case .leading: return Double(rect.minX) + indent
            case .center: return Double(rect.midX) - width / 2
            case .trailing: return Double(rect.maxX) - width - indent
            }
        }
        for (i, r) in runs.enumerated() {
            let baseline = y + r.ascent
            drawLine(r.line, x: x(for: r.width, indent: r.indent), baseline: baseline, ctx: ctx, canvasHeight: canvasHeight)
            y += r.ascent + r.descent
            if i < runs.count - 1 { y += text.lineSpacing * r.size }
        }
        let first = runs.first?.size ?? short * 0.04
        let color = runs.isEmpty ? CollageColor.rule : (text.lines.first?.color ?? .rule)
        if text.rule {
            y += first * 0.45
            let len = min(Double(rect.width) * 0.3, first * 2.4)
            let thickness = max(1, short * 0.0012)
            ctx.setFillColor(color.cgColor(alpha: 0.55))
            ctx.fill(CGRect(x: x(for: len, indent: 0), y: y, width: len, height: thickness))
            y += first * 0.45
        }
        if let seal = text.seal {
            y += first * 0.6
            let side = sealSide(seal, short: short)
            drawSeal(seal, rect: CGRect(x: x(for: side, indent: 0), y: y, width: side, height: side),
                     ctx: ctx, canvasHeight: canvasHeight)
        }
    }

    // 竖排：每行一列，从右往左；字一个一个竖着码。细线、印章在第一列下方。

    private struct Column {
        let chars: [Run]
        let size: Double
        let advance: Double
        let indent: Double
        var height: Double { indent + Double(chars.count) * advance }
    }

    private static func columns(_ text: CollageText, short: Double, vars: [String: String]) -> [Column] {
        text.lines.compactMap { spec in
            let s = fill(spec.text, vars: vars)
            guard !s.isEmpty else { return nil }
            let size = spec.size * short
            let chars = s.map { makeRun(String($0), spec, size: size) }
            let advance = size * (1.14 + spec.tracking)
            return Column(chars: chars, size: size, advance: advance, indent: spec.indent * size)
        }
    }

    private static func measureVertical(_ text: CollageText, short: Double, vars: [String: String]) -> CGSize {
        let cols = columns(text, short: short, vars: vars)
        var w = 0.0
        var h = 0.0
        for (i, c) in cols.enumerated() {
            w += c.size
            if i < cols.count - 1 { w += text.lineSpacing * c.size }
            h = max(h, c.height)
        }
        if let first = cols.first {
            var tail = first.height
            if text.rule { tail += first.size * 1.9 }
            if let seal = text.seal { tail += first.size * 0.35 + sealSide(seal, short: short) }
            h = max(h, tail)
            if let seal = text.seal { w = max(w, sealSide(seal, short: short)) }
        }
        return CGSize(width: w, height: h)
    }

    private static func drawVertical(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                                     vars: [String: String], canvasHeight: Int) {
        let cols = columns(text, short: short, vars: vars)
        guard !cols.isEmpty else { return }
        let block = measureVertical(text, short: short, vars: vars)
        var right: Double
        switch text.alignH {
        case .leading: right = Double(rect.minX) + Double(block.width)
        case .center: right = Double(rect.midX) + Double(block.width) / 2
        case .trailing: right = Double(rect.maxX)
        }
        let top: Double
        switch text.alignV {
        case .leading: top = Double(rect.minY)
        case .center: top = Double(rect.midY) - Double(block.height) / 2
        case .trailing: top = Double(rect.maxY) - Double(block.height)
        }
        var firstCenter = right - cols[0].size / 2
        for (i, col) in cols.enumerated() {
            let center = right - col.size / 2
            if i == 0 { firstCenter = center }
            var y = top + col.indent
            for ch in col.chars {
                let glyphH = ch.ascent + ch.descent
                let baseline = y + (col.advance - glyphH) / 2 + ch.ascent
                drawLine(ch.line, x: center - ch.width / 2, baseline: baseline, ctx: ctx, canvasHeight: canvasHeight)
                y += col.advance
            }
            right -= col.size + text.lineSpacing * col.size
        }
        let first = cols[0]
        var y = top + first.height
        let color = text.lines.first?.color ?? .rule
        if text.rule {
            y += first.size * 0.3
            let len = first.size * 1.3
            let thickness = max(1, short * 0.0012)
            ctx.setFillColor(color.cgColor(alpha: 0.55))
            ctx.fill(CGRect(x: firstCenter - thickness / 2, y: y, width: thickness, height: len))
            y += len + first.size * 0.3
        }
        if let seal = text.seal {
            y += first.size * 0.35
            let side = sealSide(seal, short: short)
            drawSeal(seal, rect: CGRect(x: firstCenter - side / 2, y: y, width: side, height: side),
                     ctx: ctx, canvasHeight: canvasHeight)
        }
    }

    // MARK: - 印章

    /// 印章边长：字越多印越大（两字、四字印按单字印的 1.35 倍），字才看得清。
    static func sealSide(_ seal: CollageSeal, short: Double) -> Double {
        let n = seal.text.prefix(4).count
        return seal.size * short * (n >= 2 ? 1.35 : 1)
    }

    static func drawSeal(_ seal: CollageSeal, rect: CGRect, ctx: CGContext, canvasHeight: Int) {
        let chars = Array(seal.text.prefix(4)).map(String.init)
        guard !chars.isEmpty, rect.width > 4 else { return }
        ctx.saveGState()
        let corner = rect.width * 0.06
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(seal.color.cgColor)
        ctx.fillPath()
        let ink = CollageColor.paper
        var cells: [(String, CGRect)] = []
        switch chars.count {
        case 1:
            cells = [(chars[0], rect)]
        case 2:
            let h = rect.height / 2
            cells = [(chars[0], CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)),
                     (chars[1], CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: h))]
        case 3:
            let h = rect.height / 3
            cells = (0..<3).map { (chars[$0], CGRect(x: rect.minX, y: rect.minY + h * CGFloat($0), width: rect.width, height: h)) }
        default:
            // 传统右起竖读：右列上下 = 第 1、2 字，左列 = 第 3、4 字。
            let w = rect.width / 2
            let h = rect.height / 2
            cells = [(chars[0], CGRect(x: rect.minX + w, y: rect.minY, width: w, height: h)),
                     (chars[1], CGRect(x: rect.minX + w, y: rect.minY + h, width: w, height: h)),
                     (chars[2], CGRect(x: rect.minX, y: rect.minY, width: w, height: h)),
                     (chars[3], CGRect(x: rect.minX, y: rect.minY + h, width: w, height: h))]
        }
        for (ch, cell) in cells {
            let size = Double(min(cell.width, cell.height)) * (chars.count == 1 ? 0.7 : 0.78)
            var spec = CollageTextLine(ch, font: .kaiti, weight: .bold, size: 1, color: ink)
            spec.tracking = 0
            let run = makeRun(ch, spec, size: size)
            let baseline = Double(cell.midY) - (run.ascent + run.descent) / 2 + run.ascent
            drawLine(run.line, x: Double(cell.midX) - run.width / 2, baseline: baseline, ctx: ctx, canvasHeight: canvasHeight)
        }
        ctx.restoreGState()
    }

    // MARK: - 底层

    static func drawLine(_ line: CTLine, x: Double, baseline: Double, ctx: CGContext, canvasHeight: Int) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(canvasHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: Double(canvasHeight) - baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 调试标签：深底白字。
    static func drawLabel(_ string: String, at point: CGPoint, size: Double, ctx: CGContext, canvasHeight: Int) {
        let spec = CollageTextLine(string, font: .pingfang, weight: .bold, size: 1, color: .white)
        let run = makeRun(string, spec, size: size)
        let pad = size * 0.3
        let box = CGRect(x: Double(point.x), y: Double(point.y), width: run.width + pad * 2,
                         height: run.ascent + run.descent + pad * 2)
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65))
        ctx.fill(box)
        ctx.restoreGState()
        drawLine(run.line, x: Double(point.x) + pad, baseline: Double(point.y) + pad + run.ascent, ctx: ctx,
                 canvasHeight: canvasHeight)
    }
}
