import Foundation
import CoreGraphics

// MARK: - 印厂规格（相册 B · P1）
//
// 一本相册交给印厂之前要对上的那几样：单页尺寸、dpi、出血、安全区、装订和中缝带、页数规则、首尾单页、色彩、JPEG。
// 只用通用名字（「方册 30×30 平铺」），不写任何印厂、品牌、产品名。各家印厂的真实数值拿不到，内置的都是保守默认，
// 界面上写「照印厂给的改」—— 不编「某某印厂要求」。
//
// 画布上的像素（CollageCanvas.width / height / dpi / bleed / safe / binding）仍是渲染唯一认的数；规格里的 cm、mm 只用来
// 新建画布、显示、「存成规格…」。像素装不下的那几样挂在 CollageCanvas.printRules 上。

/// 导出用哪个 RGB。渲染一律在 sRGB 里做（CollageRender.makeContext）；Adobe RGB 只在写文件那一刻转（CollageExport.converted）。
enum CollageColorSpace: String, Codable, CaseIterable, Hashable {
    case sRGB
    case adobeRGB

    var label: String {
        switch self {
        case .sRGB: return "sRGB"
        case .adobeRGB: return "Adobe RGB (1998)"
        }
    }

    /// 分段控件上的短名。
    var shortLabel: String { self == .sRGB ? "sRGB" : "Adobe RGB" }

    /// 写文件用的色彩空间（ImageIO 照它嵌 ICC：Adobe RGB 嵌 APP2，sRGB 不嵌、读的人按 sRGB 认）。
    var cgSpace: CGColorSpace? {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
        case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        }
    }
}

/// 印厂规格里画布像素装不下的那几样。挂在 CollageCanvas.printRules；nil 的画布按 standard 查页数（只有相册查）。
struct CollagePrintRules: Codable, Hashable {
    /// 页数（印厂说的「P」= 单页；1 个跨页 = 2P）：最少、最多、每次加几 P。
    var minPages = 20
    var maxPages = 60
    var pageStep = 2
    /// 首尾是单页（有的平铺册第一页、最后一页贴在封板上）：第 1 个跨页的左页、最后一个跨页的右页印不出来。
    /// 只用来提醒（导出前检查）；P 数照「跨页 × 2」算 —— 各家怎么数首尾不一样，照印厂的算法核对。
    var singleEnds = false
    /// 中缝带每侧多宽（mm），平铺、胶装各一个；nil = 自动（平铺 = 短边 2%，胶装至少 12mm —— 和以前一样）。
    var layflatFoldMM: Double?
    var gluedFoldMM: Double?
    /// 导出的跨页图、印刷 PDF 用的色彩。
    var colorSpace: CollageColorSpace = .sRGB
    /// 导出 JPEG 的质量；nil = 跟导出设置里的滑杆。
    var jpegQuality: Double?

    /// 保守默认：20–60P、每次加 2P、sRGB、中缝带自动。没套规格的相册也按它查页数。
    static let standard = CollagePrintRules()

    static let pageLimit = 2...2000
    static let stepRange = 1...40
    static let foldRangeMM: ClosedRange<Double> = 0...40
    static let qualityRange: ClosedRange<Double> = 0.5...1

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollagePrintRules()
        let lo = Self.pageLimit
        minPages = min(lo.upperBound, max(lo.lowerBound, c.soft(.minPages, d.minPages)))
        maxPages = min(lo.upperBound, max(minPages, c.soft(.maxPages, d.maxPages)))
        pageStep = min(Self.stepRange.upperBound, max(Self.stepRange.lowerBound, c.soft(.pageStep, d.pageStep)))
        singleEnds = c.soft(.singleEnds, d.singleEnds)
        func mm(_ v: Double?) -> Double? {
            guard let v, v.isFinite else { return nil }
            return min(Self.foldRangeMM.upperBound, max(Self.foldRangeMM.lowerBound, v))
        }
        layflatFoldMM = mm(c.softOptional(.layflatFoldMM))
        gluedFoldMM = mm(c.softOptional(.gluedFoldMM))
        colorSpace = c.soft(.colorSpace, d.colorSpace)
        let q: Double? = c.softOptional(.jpegQuality)
        jpegQuality = q.flatMap { $0.isFinite ? min(Self.qualityRange.upperBound, max(Self.qualityRange.lowerBound, $0)) : nil }
    }

    /// 这本有几 P（n 个跨页）。
    func pages(spreads n: Int) -> Int { n * 2 }

    /// 「20–60P（10–30 个跨页）、每次加 2P」。
    var summary: String {
        "\(minPages)–\(maxPages)P（\(Self.spreads(minPages))–\(maxPages / 2) 个跨页）、每次加 \(pageStep)P"
    }

    /// P 数换成跨页数（往上取整：21P 也要 11 个跨页）。
    static func spreads(_ pages: Int) -> Int { (pages + 1) / 2 }

    /// n 个跨页合不合这条规则：合 = nil；不合 = 跨页条悬停、导出前检查那一句（两种单位都写）。
    /// 例：「印厂要 20–60P、每次加 2P；现在 34 个跨页 = 68P，多了 8P」。
    func pageProblem(spreads n: Int) -> String? {
        guard n > 0 else { return nil }
        let p = pages(spreads: n)
        let head = "印厂要 \(minPages)–\(maxPages)P、每次加 \(pageStep)P；现在 \(n) 个跨页 = \(p)P，"
        if p < minPages {
            let short = minPages - p
            return head + "少了 \(short)P（再加 \(Self.spreads(short)) 个跨页）"
        }
        if p > maxPages {
            let over = p - maxPages
            return head + "多了 \(over)P（少 \(Self.spreads(over)) 个跨页）"
        }
        let off = (p - minPages) % max(1, pageStep)
        if off != 0 {
            let up = pageStep - off
            let down = off
            var ways: [String] = []
            if p + up <= maxPages { ways.append("再加 \(up)P") }
            if p - down >= minPages { ways.append("减 \(down)P") }
            return head + "不是从 \(minPages)P 起每次加 \(pageStep)P 的数" + (ways.isEmpty ? "" : "：" + ways.joined(separator: "或"))
        }
        return nil
    }
}

/// 一套印厂规格：名字 + 单页尺寸、dpi、出血、安全区、装订 + 像素装不下的那几样（rules）。内置的在 builtin；用户
/// 「存成规格…」的存在拼图全局设置（state.json 的 printSpecs）。
struct CollagePrintSpec: Codable, Hashable, Identifiable {
    var name: String
    /// 单页宽、高（cm）：跨页宽 = 2 × 单页宽。
    var pageWidthCM: Double
    var pageHeightCM: Double
    var dpi: Double = 300
    var bleedMM: Double = 3
    var safeMM: Double = 5
    var binding: CollageBinding = .layflat
    var rules = CollagePrintRules()
    /// 命令行（ops 的 spec:）认的短名：内置的才有。
    var key: String?

    var id: String { name }

    init(name: String, pageWidthCM: Double, pageHeightCM: Double, dpi: Double = 300, bleedMM: Double = 3,
         safeMM: Double = 5, binding: CollageBinding = .layflat, rules: CollagePrintRules = CollagePrintRules(),
         key: String? = nil) {
        self.name = name
        self.pageWidthCM = pageWidthCM
        self.pageHeightCM = pageHeightCM
        self.dpi = dpi
        self.bleedMM = bleedMM
        self.safeMM = safeMM
        self.binding = binding
        self.rules = rules
        self.key = key
    }

    /// 「存成规格…」：从现在的画布量回来（像素按 dpi 换回 cm / mm，留两位小数）。再套回来得到的像素和现在一样
    /// （30×30cm 300dpi = 7087px，换回去还是 7087）。
    init(name: String, canvas: CollageCanvas) {
        func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        let dpi = max(1, canvas.dpi)
        self.init(name: name,
                  pageWidthCM: round2(Double(canvas.width) / 2 / dpi * 2.54),
                  pageHeightCM: round2(Double(canvas.height) / dpi * 2.54),
                  dpi: canvas.dpi,
                  bleedMM: round2(Double(canvas.bleed) / dpi * 25.4),
                  safeMM: round2(Double(canvas.safe) / dpi * 25.4),
                  binding: canvas.binding,
                  rules: canvas.printRules ?? .standard)
    }

    /// 逐字段容错（读用户存的）：尺寸坏了整条不要，别的坏了用默认。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pageWidthCM = try c.decode(Double.self, forKey: .pageWidthCM)
        pageHeightCM = try c.decode(Double.self, forKey: .pageHeightCM)
        guard pageWidthCM.isFinite, pageHeightCM.isFinite, Self.pageCMRange.contains(pageWidthCM),
              Self.pageCMRange.contains(pageHeightCM), !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .pageWidthCM, in: c, debugDescription: "规格尺寸不对")
        }
        let dpiValue = c.soft(.dpi, 300.0)
        dpi = dpiValue.isFinite ? min(1200, max(150, dpiValue)) : 300
        bleedMM = min(10, max(0, c.soft(.bleedMM, 3.0)))
        safeMM = min(30, max(0, c.soft(.safeMM, 5.0)))
        binding = c.soft(.binding, .layflat)
        rules = c.soft(.rules, CollagePrintRules())
        key = nil
    }

    /// 单页能填的尺寸（cm）。
    static let pageCMRange: ClosedRange<Double> = 5...80

    /// 套到画布上：跨页画布（跨页宽 = 2 × 单页宽），装订和像素装不下的那几样一起带上。
    var canvas: CollageCanvas {
        var c = CollageCanvas.spread(name: name, pageWidthCM: pageWidthCM, pageHeightCM: pageHeightCM, dpi: dpi,
                                     bleedMM: bleedMM, safeMM: safeMM)
        c.binding = binding
        c.printRules = rules
        return c
    }

    /// 这张画布是不是正套着这一条（名字、尺寸、装订、规则都对得上）：菜单上打勾。
    func matches(_ c: CollageCanvas) -> Bool {
        let mine = canvas
        return c.name == mine.name && c.width == mine.width && c.height == mine.height && c.dpi == mine.dpi
            && c.bleed == mine.bleed && c.safe == mine.safe && c.binding == mine.binding
            && c.printRules == rules
    }

    /// 「30×30cm · 平铺 · 出血 3mm · 20–60P · sRGB」。
    var detail: String {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        return "单页 \(n(pageWidthCM))×\(n(pageHeightCM))cm · \(binding.label) · 出血 \(n(bleedMM))mm · "
            + "\(rules.minPages)–\(rules.maxPages)P · \(rules.colorSpace.shortLabel)"
    }

    // MARK: 内置（保守默认）

    /// 常见尺寸 × 两种装订。页数一律 20–60P、每次加 2P，出血 3mm、安全区 5mm、300dpi、sRGB、中缝带自动 —— 都是保守
    /// 默认，界面上写「照印厂给的改」。前四个尺寸就是以前的四个相册画布（同样的像素）。
    static let builtin: [CollagePrintSpec] = {
        let sizes: [(key: String, name: String, w: Double, h: Double)] = [
            ("sq30", "方册 30×30", 30, 30),
            ("sq25", "方册 25×25", 25, 25),
            ("sq20", "方册 20×20", 20, 20),
            ("land30x20", "横版 30×20", 30, 20),
            ("port20x30", "竖版 20×30", 20, 30),
            ("land40x30", "横版 40×30", 40, 30),
            ("sq15", "方册 15×15", 15, 15),
        ]
        var out: [CollagePrintSpec] = []
        for binding in CollageBinding.allCases {
            let suffix = binding == .layflat ? "平铺" : "胶装"
            let tag = binding == .layflat ? "flat" : "glued"
            for s in sizes {
                out.append(CollagePrintSpec(name: "\(s.name) \(suffix)", pageWidthCM: s.w, pageHeightCM: s.h,
                                            binding: binding, key: "\(s.key)-\(tag)"))
            }
        }
        return out
    }()

    /// 按短名或名字找（先内置、后用户的）。
    static func find(_ text: String, in user: [CollagePrintSpec]) -> CollagePrintSpec? {
        let t = text.trimmingCharacters(in: .whitespaces)
        return builtin.first { $0.key == t || $0.name == t } ?? user.first { $0.name == t }
    }

    /// 「存成规格…」填的名字：去掉首尾空白、换行，最长 40 个字；空的 = nil。
    static func cleanName(_ raw: String) -> String? {
        let name = String(raw.filter { !$0.isNewline }.trimmingCharacters(in: .whitespaces).prefix(40))
        return name.isEmpty ? nil : name
    }
}

extension CollageCanvas {
    /// 查页数、中缝带、色彩用的规则：没套过规格 = 保守默认。
    var effectivePrintRules: CollagePrintRules { printRules ?? .standard }

    /// 导出用的色彩（社交画布、没套规格的 = sRGB）。
    var exportColorSpace: CollageColorSpace { printRules?.colorSpace ?? .sRGB }

    /// 单页宽、高（cm）：相册是跨页的一半宽。
    var pageSizeCM: (width: Double, height: Double) {
        let dpi = max(1, self.dpi)
        let w = Double(width) / dpi * 2.54
        return (seams == .fold ? w / 2 : w, Double(height) / dpi * 2.54)
    }
}

// MARK: - 只导某几个跨页（P4）

/// 「导出 ▾」里的范围：全部 / 当前跨页 / 自定义（「1-3, 7」）。不存盘（同 exportName：每次导出自己选）。
enum CollageExportRange: Equatable {
    case all
    case current
    case custom(String)

    struct Bad: Error, Equatable {
        let message: String
    }

    /// 这次导哪几页（从 0 起、升序、不重复）；nil = 全部。写错 = 那句话。
    func resolve(pageCount: Int, current: Int) -> Result<[Int]?, Bad> {
        switch self {
        case .all:
            return .success(nil)
        case .current:
            guard (0..<pageCount).contains(current) else { return .failure(Bad(message: "还没有跨页")) }
            return .success([current])
        case .custom(let text):
            return Self.parse(text, count: pageCount).map { Optional($0) }
        }
    }

    /// 「1-3, 7」→ [0, 1, 2, 6]。分隔认逗号（中英文）、顿号、分号、空格；范围认 - – — ~ 和反着写的（3-1）。
    /// 跨页号从 1 起，超出 1…count、写了不是数的都算错（不悄悄扔掉）。
    static func parse(_ text: String, count: Int) -> Result<[Int], Bad> {
        let separators = CharacterSet(charactersIn: ",，、;；").union(.whitespacesAndNewlines)
        let tokens = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return .failure(Bad(message: "写要导的跨页号，比如 1-3, 7")) }
        guard count > 0 else { return .failure(Bad(message: "还没有跨页")) }
        var picked = Set<Int>()
        for token in tokens {
            let ends = token.split(omittingEmptySubsequences: false) { "-–—~～".contains($0) }.map(String.init)
            let numbers = ends.compactMap { Int($0) }
            guard (ends.count == 1 || ends.count == 2), numbers.count == ends.count else {
                return .failure(Bad(message: "「\(token)」不是跨页号：写成 1-3, 7"))
            }
            let lo = numbers.min() ?? 0
            let hi = numbers.max() ?? 0
            guard lo >= 1, hi <= count else {
                return .failure(Bad(message: "「\(token)」超出了：一共 \(count) 个跨页"))
            }
            for n in lo...hi { picked.insert(n - 1) }
        }
        return .success(picked.sorted())
    }

    /// [0, 1, 2, 6] →「1–3、7」（从 1 起，连着的并成一段）。
    static func label(_ pages: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        let sorted = Array(Set(pages)).sorted()
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(j > i ? "\(sorted[i] + 1)–\(sorted[j] + 1)" : "\(sorted[i] + 1)")
            i = j + 1
        }
        return parts.joined(separator: "、")
    }
}

// MARK: - 容错解码（CollageModel 里的 Failable、soft 是那个文件私有的，这里各备一份）

/// 数组里哪一条解不开只丢它自己（JSONDecoder 解失败不往后挪，所以包一层：这一层永远解得开）。
struct CollageLossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func softOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

// MARK: - 导出时转色彩（P6）

extension CollageExport {
    /// sRGB 里渲好的跨页转成规格要的色彩：画进那个色彩空间的位图，CoreGraphics 做色彩匹配（相对比色）。
    /// sRGB = 原样返回同一张图（不复制、不重画：sRGB 的输出和以前逐字节一样）。转不了 = nil（调用方报编码失败）。
    static func converted(_ image: CGImage, to space: CollageColorSpace) -> CGImage? {
        guard space != .sRGB else { return image }
        guard let cs = space.cgSpace,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.setRenderingIntent(.relativeColorimetric)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// JPEG 是不是基线（baseline，SOF0）：扫到第一个帧头看是 FFC0 还是 FFC2（渐进）。ImageIO 默认写基线（2026-11 实测
    /// macOS 26：FFC0，没有 FFC2），这里只给自检钉死；不是 JPEG / 没扫到帧头 = nil。
    static func jpegIsBaseline(_ data: Data) -> Bool? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xC0 { return true }
            if (0xC1...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { return false }
            if marker == 0xDA { return nil }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            i += 2 + length
        }
        return nil
    }
}
