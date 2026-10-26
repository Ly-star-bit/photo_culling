import Foundation
import AppKit
import CoreText
import ImageIO

/// 花字的现成搭配：只是可选的第一步 —— 直接打字不用先选它，套完每一项还能单独调。
enum CollageTextEffects {
    struct Preset: Identifiable {
        let key: String
        let name: String
        /// 换了字色的预设：照片上的字深浅定成这个（nil = 不换字色，深浅还按原来的）。
        var tone: CollageTone? = nil
        /// 改这一行（花字，有的连字色一起换）。
        let apply: (inout CollageTextLine) -> Void
        var id: String { key }
    }

    static let presets: [Preset] = [
        Preset(key: "none", name: "无花字") { $0.effect = nil },
        Preset(key: "outline", name: "白字黑边", tone: .light) { line in
            line.color = .white
            var fx = CollageTextEffect()
            fx.stroke = 0.09
            fx.strokeColor = .charcoal
            line.effect = fx
        },
        Preset(key: "outline-dark", name: "黑字白边", tone: .dark) { line in
            line.color = .ink
            var fx = CollageTextEffect()
            fx.stroke = 0.11
            fx.strokeColor = .white
            line.effect = fx
        },
        Preset(key: "shadow", name: "柔和投影") { line in
            var fx = line.effect ?? CollageTextEffect()
            fx.shadow = 0.55
            fx.shadowColor = CollageColor(r: 0, g: 0, b: 0)
            fx.shadowBlur = 0.15
            fx.shadowOffset = 0.05
            line.effect = fx
        },
        Preset(key: "glow", name: "发光") { line in
            var fx = line.effect ?? CollageTextEffect()
            fx.shadow = 0.9
            fx.shadowColor = line.color.luminance > 0.5 ? CollageColor(hex: 0xFFD27A) : .white
            fx.shadowBlur = 0.35
            fx.shadowOffset = 0
            line.effect = fx
        },
        Preset(key: "neon", name: "霓虹", tone: .light) { line in
            line.color = .white
            var fx = CollageTextEffect()
            fx.shadow = 1
            fx.shadowColor = CollageColor(hex: 0xFF4FA3)
            fx.shadowBlur = 0.35
            fx.shadowOffset = 0
            line.effect = fx
        },
        Preset(key: "tape", name: "胶带底条", tone: .dark) { line in
            line.color = .ink
            var fx = CollageTextEffect()
            fx.band = 0.9
            fx.bandColor = CollageColor(hex: 0xF2D4C9)
            fx.bandRound = 0.08
            line.effect = fx
        },
        Preset(key: "pill", name: "黑底白字", tone: .light) { line in
            line.color = .white
            var fx = CollageTextEffect()
            fx.band = 0.85
            fx.bandColor = .charcoal
            fx.bandRound = 1
            line.effect = fx
        },
        Preset(key: "gold", name: "金色渐变", tone: .light) { line in
            line.color = CollageColor(hex: 0xF6E2A8)
            var fx = CollageTextEffect()
            fx.gradient = CollageColor(hex: 0xB8862B)
            fx.shadow = 0.35
            fx.shadowBlur = 0.1
            fx.shadowOffset = 0.04
            line.effect = fx
        },
    ]

    static func preset(_ key: String) -> Preset? { presets.first { $0.key == key } }
}

/// 拼图里的文字：字体解析、占位符、横排/竖排、细线、印章。
///
/// 画在「已翻转成左上原点」的 context 里；CTLineDraw 需要未翻转的坐标系，
/// 每一行局部翻回去（同 WatermarkEngine.drawCTLine）。
enum CollageTypeset {

    // MARK: - 字体

    /// PostScript 名按优先级。系统里没有的（楷体在部分 Mac 上要另行下载）会落到下一个。
    /// 旧的几个字体：heavy / black 先找自己有的那档（宋体 Black、Avenir Next Heavy），没有就和 bold 一样 ——
    /// 下面 `w` 把它们折成 bold，light / regular / bold 的结果和加字重之前逐字相同。
    static func postScriptNames(_ font: CollageFont, _ weight: CollageWeight, italic: Bool) -> [String] {
        let w: CollageWeight = weight.isBoldish ? .bold : weight
        let heavy = weight == .heavy || weight == .black
        switch font {
        case .songti:
            switch w {
            case .light: return ["STSongti-SC-Light", "STSongti-SC-Regular", "STSong"]
            case .regular: return ["STSongti-SC-Regular", "STSong"]
            default:
                return heavy ? ["STSongti-SC-Black", "STSongti-SC-Bold", "STSongti-SC-Regular"]
                             : ["STSongti-SC-Bold", "STSongti-SC-Black", "STSongti-SC-Regular"]
            }
        case .songtiTC:
            // 宋体繁（系统自带的 Songti TC，没有 Black）：缺了落到简体宋体。
            switch w {
            case .light: return ["STSongti-TC-Light", "STSongti-TC-Regular"] + postScriptNames(.songti, .light, italic: false)
            case .regular: return ["STSongti-TC-Regular"] + postScriptNames(.songti, .regular, italic: false)
            default: return ["STSongti-TC-Bold", "STSongti-TC-Regular"] + postScriptNames(.songti, weight, italic: false)
            }
        case .kaiti:
            let kai = w == .bold ? ["STKaitiSC-Bold", "STKaitiSC-Regular"] : ["STKaitiSC-Regular", "STKaiti"]
            return kai + postScriptNames(.songti, weight, italic: false)
        case .fangsong:
            // 华文仿宋要在字体册里另行下载（AssetsV2）：没有落到楷体，再落到细宋。
            return ["STFangsong"] + postScriptNames(.kaiti, .regular, italic: false)
        case .lishu:
            // 隶变（Libian SC）是按需下载的字体：没有落到魏碑、粗宋（同样厚重的标题字）。
            return ["STLibianSC-Regular", "WeibeiSC-Bold"] + postScriptNames(.songti, .bold, italic: false)
        case .weibei:
            // 魏碑（Weibei SC）按需下载：没有落到粗宋。
            return ["WeibeiSC-Bold"] + postScriptNames(.songti, .bold, italic: false)
        case .pingfang:
            switch w {
            case .light: return ["PingFangSC-Light", "PingFangSC-Regular"]
            case .regular: return ["PingFangSC-Regular"]
            default: return ["PingFangSC-Semibold", "PingFangSC-Medium"]
            }
        case .lantinghei:
            // 兰亭黑（按需下载）。三个码不按字重排：FZLTTHK = Heavy、FZLTZHK = Demibold、FZLTXHK = Extralight
            // （本机 CTFontCopyName 的样式名核对过）。没有落到苹方。
            switch weight {
            case .light: return ["FZLTXHK--GBK1-0"] + postScriptNames(.pingfang, .light, italic: false)
            case .regular, .bold: return ["FZLTZHK--GBK1-0"] + postScriptNames(.pingfang, .bold, italic: false)
            case .heavy, .black: return ["FZLTTHK--GBK1-0", "FZLTZHK--GBK1-0"] + postScriptNames(.pingfang, .bold, italic: false)
            }
        case .didot:
            if italic { return ["Didot-Italic", "Didot"] }
            return w == .bold ? ["Didot-Bold", "Didot"] : ["Didot"]
        case .bodoni:
            if italic { return ["BodoniSvtyTwoITCTT-BookIta", "BodoniSvtyTwoITCTT-Book"] }
            return w == .bold ? ["BodoniSvtyTwoITCTT-Bold", "BodoniSvtyTwoITCTT-Book"] : ["BodoniSvtyTwoITCTT-Book"]
        case .newYork:
            return []
        case .baskerville:
            if italic { return w == .bold ? ["Baskerville-SemiBoldItalic", "Baskerville-Italic"] : ["Baskerville-Italic"] }
            return w == .bold ? ["Baskerville-SemiBold", "Baskerville"] : ["Baskerville"]
        case .bigCaslon:
            // 只有一个字重（Medium）。
            return ["BigCaslon-Medium"] + postScriptNames(.baskerville, weight, italic: italic)
        case .athelas:
            // 细衬线（留白杂志）：没有细体，light 用常规。
            // 斜体退 Charter 斜体（DESIGN：Athelas → Charter → New York）；都缺落到系统衬线的斜体。
            if italic { return (w == .bold ? ["Athelas-BoldItalic"] : []) + ["Athelas-Italic"] + postScriptNames(.charter, weight, italic: true) }
            return (w == .bold ? ["Athelas-Bold"] : []) + ["Athelas-Regular"] + postScriptNames(.charter, weight, italic: false)
        case .charter:
            if heavy { return italic ? ["Charter-BlackItalic", "Charter-BoldItalic"] : ["Charter-Black", "Charter-Bold"] }
            if italic { return w == .bold ? ["Charter-BoldItalic", "Charter-Italic"] : ["Charter-Italic", "Charter-Roman"] }
            return w == .bold ? ["Charter-Bold", "Charter-Roman"] : ["Charter-Roman"]
        case .timesNewRoman:
            // 报纸正文。系统的 Times 做退路。
            if italic {
                return w == .bold ? ["TimesNewRomanPS-BoldItalicMT", "Times-BoldItalic"] : ["TimesNewRomanPS-ItalicMT", "Times-Italic"]
            }
            return w == .bold ? ["TimesNewRomanPS-BoldMT", "Times-Bold"] : ["TimesNewRomanPSMT", "Times-Roman"]
        case .georgia:
            if italic { return w == .bold ? ["Georgia-BoldItalic", "Georgia-Italic"] : ["Georgia-Italic", "Georgia"] }
            return w == .bold ? ["Georgia-Bold", "Georgia"] : ["Georgia"]
        case .superclarendon:
            switch weight {
            case .light: return italic ? ["Superclarendon-LightItalic", "Superclarendon-Light"] : ["Superclarendon-Light", "Superclarendon-Regular"]
            case .regular: return italic ? ["Superclarendon-Italic", "Superclarendon-Regular"] : ["Superclarendon-Regular"]
            case .bold: return italic ? ["Superclarendon-BoldItalic", "Superclarendon-Bold"] : ["Superclarendon-Bold"]
            case .heavy, .black:
                return italic ? ["Superclarendon-BlackItalic", "Superclarendon-BoldItalic"] : ["Superclarendon-Black", "Superclarendon-Bold"]
            }
        case .optima:
            if italic { return ["Optima-Italic", "Optima-Regular"] }
            return w == .bold ? ["Optima-Bold", "Optima-Regular"] : ["Optima-Regular"]
        case .avenir:
            switch w {
            case .light: return italic ? ["AvenirNext-UltraLightItalic", "AvenirNext-UltraLight"] : ["AvenirNext-UltraLight", "AvenirNext-Regular"]
            case .regular: return italic ? ["AvenirNext-Italic", "AvenirNext-Regular"] : ["AvenirNext-Regular"]
            default:
                if heavy { return italic ? ["AvenirNext-HeavyItalic", "AvenirNext-BoldItalic"] : ["AvenirNext-Heavy", "AvenirNext-Bold"] }
                return italic ? ["AvenirNext-DemiBoldItalic", "AvenirNext-DemiBold"] : ["AvenirNext-DemiBold", "AvenirNext-Bold"]
            }
        case .gillSans:
            switch w {
            case .light: return italic ? ["GillSans-LightItalic", "GillSans-Light"] : ["GillSans-Light", "GillSans"]
            case .regular: return italic ? ["GillSans-Italic", "GillSans"] : ["GillSans"]
            default: return italic ? ["GillSans-SemiBoldItalic", "GillSans-SemiBold"] : ["GillSans-SemiBold", "GillSans"]
            }
        case .futura:
            if italic { return ["Futura-MediumItalic", "Futura-Medium"] }
            return w == .bold ? ["Futura-Bold", "Futura-Medium"] : ["Futura-Medium"]
        case .helveticaNeue:
            // 瑞士网格的主力字。没有 Heavy / Black（那是窄体），粗都用 Bold。
            switch w {
            case .light: return italic ? ["HelveticaNeue-LightItalic", "HelveticaNeue-Light"] : ["HelveticaNeue-Light", "HelveticaNeue"]
            case .regular: return italic ? ["HelveticaNeue-Italic", "HelveticaNeue"] : ["HelveticaNeue", "Helvetica"]
            default: return italic ? ["HelveticaNeue-BoldItalic", "HelveticaNeue-Bold"] : ["HelveticaNeue-Bold", "Helvetica-Bold"]
            }
        case .helveticaCondensed:
            // Helvetica Neue 窄体只有 Bold、Black 两档：细、常规也用 Bold。
            return heavy ? ["HelveticaNeue-CondensedBlack", "HelveticaNeue-CondensedBold"]
                         : ["HelveticaNeue-CondensedBold", "HelveticaNeue-CondensedBlack"]
        case .dinAlternate:
            return ["DINAlternate-Bold", "DINCondensed-Bold"] + postScriptNames(.helveticaNeue, .bold, italic: false)
        case .dinCondensed:
            return ["DINCondensed-Bold", "DINAlternate-Bold"] + postScriptNames(.helveticaCondensed, weight, italic: false)
        case .impact:
            return ["Impact"] + postScriptNames(.helveticaCondensed, .black, italic: false)
        case .copperplate:
            switch w {
            case .light: return ["Copperplate-Light", "Copperplate"]
            case .regular: return ["Copperplate"]
            default: return ["Copperplate-Bold", "Copperplate"]
            }
        case .fraktur:
            // 哥特体刊头：程序内置的 OFL 字体（CollageEmbeddedFonts），一定有；万一解不出落到粗衬线。
            return [CollageEmbeddedFonts.unifrakturCook, "BigCaslon-Medium", "Didot-Bold"]
        case .hanzipen:
            // 翩翩体在部分 Mac 上要在字体册里另行下载：没有就落到楷体、宋体。
            let pen = w == .bold ? ["HanziPenSC-W5", "HanziPenSC-W3"] : ["HanziPenSC-W3", "HanziPenSC-W5"]
            return pen + postScriptNames(.kaiti, w == .bold ? .bold : .regular, italic: false)
        case .bradley:
            return ["BradleyHandITCTT-Bold", "Noteworthy-Light"]
        case .snell:
            return w == .bold ? ["SnellRoundhand-Bold", "SnellRoundhand"] : ["SnellRoundhand", "SnellRoundhand-Bold"]
        case .typewriter:
            switch w {
            case .light: return ["AmericanTypewriter-Light", "AmericanTypewriter", "Courier"]
            case .regular: return ["AmericanTypewriter", "Courier"]
            default: return ["AmericanTypewriter-Semibold", "AmericanTypewriter-Bold", "Courier-Bold"]
            }
        }
    }

    private static let fontLock = NSLock()
    private static var fontCache: [String: CTFont] = [:]
    /// 每个（字体, 字重, 斜体）解析成了退路链里的哪个名字：换个字号不用再把退路链挨个试一遍。只记解析上的 ——
    /// 一个都没解出来（按需下载的隶书、魏碑、仿宋、兰亭黑还没下好）下次照样再试，下载好了下一个字号就能用上。
    private static var nameCache: [String: String] = [:]

    static func font(_ family: CollageFont, _ weight: CollageWeight, italic: Bool, size: CGFloat) -> CTFont {
        // 键用确切的字号。以前按 1/4 pt 一档：同一档里谁先要谁的字号就留下 —— 后台预览（约 0.47 倍）先要了
        // 15.85，导出要 15.84 拿到的就是 15.85 那个，出图跟着先后顺序变（门禁偶发不同就是这个）。
        let key = "\(family.rawValue)|\(weight.rawValue)|\(italic)|\(size)"
        fontLock.lock()
        if let hit = fontCache[key] {
            fontLock.unlock()
            return hit
        }
        fontLock.unlock()
        let resolved = resolveFont(family, weight, italic: italic, size: size)
        fontLock.lock()
        // 拖缝时字号一直在变：多留一些（CTFont 很小，字形数据是共享的）。
        if fontCache.count > 1024 { fontCache.removeAll() }
        fontCache[key] = resolved
        fontLock.unlock()
        return resolved
    }

    /// 按名字建（内置字体不进系统字体表：按名字直接从内嵌数据建）。
    private static func namedFont(_ name: String, size: CGFloat) -> CTFont {
        CollageEmbeddedFonts.font(named: name, size: size) ?? CTFontCreateWithName(name as CFString, size, nil)
    }

    private static func resolveFont(_ family: CollageFont, _ weight: CollageWeight, italic: Bool, size: CGFloat) -> CTFont {
        let nameKey = "\(family.rawValue)|\(weight.rawValue)|\(italic)"
        fontLock.lock()
        let known = nameCache[nameKey]
        fontLock.unlock()
        if let known { return namedFont(known, size: size) }
        for name in postScriptNames(family, weight, italic: italic) {
            let f = namedFont(name, size: size)
            guard (CTFontCopyPostScriptName(f) as String) == name else { continue }
            fontLock.lock()
            nameCache[nameKey] = name
            fontLock.unlock()
            return f
        }
        let nsWeight: NSFont.Weight = weight == .light ? .light : (weight.isBoldish ? .semibold : .regular)
        let system = NSFont.systemFont(ofSize: size, weight: nsWeight)
        // 细衬线（Athelas → Charter）全缺时退到系统的衬线 New York，不落成无衬线（留白杂志的标题、斜体小字）。
        if family == .newYork || family == .athelas || family == .charter,
           let serif = system.fontDescriptor.withDesign(.serif) {
            var descriptor = serif
            if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
            if let f = NSFont(descriptor: descriptor, size: size) { return f as CTFont }
        }
        // 中文字体全缺时：苹方一定在。
        if family.isChinese {
            let f = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
            return f
        }
        return system as CTFont
    }

    // MARK: - 占位符

    private static let exifLock = NSLock()
    private static var exifCache: [String: [String: String]] = [:]

    /// 一张照片的 EXIF 占位符（按路径缓存：拼图水印每格每帧都要，不能每次开文件）。原图读不了（移动硬盘没插）
    /// 不缓存，下次再试：插上盘之后的预览、导出就有字了（以前记下一个空的，整个会话都没字）。
    static func exifValues(_ path: String) -> [String: String] {
        exifLock.lock()
        if let hit = exifCache[path] {
            exifLock.unlock()
            return hit
        }
        exifLock.unlock()
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        let tags = WatermarkEngine.ExifTags(source: source)
        guard tags.readOK else { return tags.values }
        exifLock.lock()
        exifCache[path] = tags.values
        exifLock.unlock()
        return tags.values
    }

    private static var focalCache: [String: Double] = [:]

    /// 镜头上的实际焦距（EXIF FocalLength，毫米）。{focal} 是水印那套「相机写了 35mm 等效就用等效、没写用实际」，
    /// 报纸正文说「焦距」得是实际那个数（17-70 的镜头印不出 92mm）。同 exifValues：按路径缓存，读不了的不缓存。
    static func focalLength(_ path: String) -> Double? {
        exifLock.lock()
        if let hit = focalCache[path] {
            exifLock.unlock()
            return hit > 0 ? hit : nil
        }
        exifLock.unlock()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let focal = exif[kCGImagePropertyExifFocalLength] as? Double ?? 0
        exifLock.lock()
        focalCache[path] = focal
        exifLock.unlock()
        return focal > 0 ? focal : nil
    }

    /// 这个路径的 EXIF 有没有缓存下来（命令行 exifprobe 核对「读不了的不缓存」用）。
    static func exifCached(_ path: String) -> Bool {
        exifLock.lock()
        defer { exifLock.unlock() }
        return exifCache[path] != nil
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
        // 期号：填了用填的，没填 = 页码（一期杂志的封面、内页各是 01、02…）。
        vars["issue"] = project.issue.isEmpty ? vars["no"] : project.issue
        // 报纸的期号不补零：{issue_n} = 第 1 期（填了数字也去掉前面的 0，填的不是数字原样）；{issue_cn} = 第一期
        // （民国竖排：竖排里的阿拉伯数字一个个立着排）。
        let issueText = project.issue.trimmingCharacters(in: .whitespaces)
        let issueNumber: Int? = issueText.isEmpty ? pageIndex + 1 : Int(issueText) ?? issueDigits(issueText)
        vars["issue_n"] = issueNumber.map { String($0) } ?? project.issue
        vars["issue_cn"] = issueNumber.map { chineseCount($0) } ?? project.issue
        vars["masthead"] = mastheadText(project.masthead, title: vars["title"] ?? "")
        // {masthead_alt}：刊头和标题不是同一串字（不管大小写、空格）时 = 刊头，是同一串时空着。今日头版红字报头（{title}）
        // 下面那行小字只在它有值时印：中文标题下面是拼音、自己填了刊头印刊头；西文标题没填刊头（Spring Portraits →
        // SPRING PORTRAITS）不把标题大写再印一遍。
        let squeezedMasthead = (vars["masthead"] ?? "").filter { !$0.isWhitespace }.lowercased()
        let squeezedTitle = (vars["title"] ?? "").filter { !$0.isWhitespace }.lowercased()
        vars["masthead_alt"] = squeezedMasthead == squeezedTitle ? "" : vars["masthead"]
        // 刊头的首字母（巨字开篇）：拾光 → S；刊头填了中文也取拼音（拾光集 → S）。
        vars["initial"] = initialLetter(project.masthead, title: vars["title"] ?? "")
        // 时尚刊的刊头、folio：标题转出来太长时截短（CHUNRI），见 CollageStyleFashion.shortMasthead。
        vars["masthead_short"] = CollageStyleFashion.shortMasthead(project.masthead, title: vars["title"] ?? "")
        let onPage = (pagePhotoIDs ?? root.photoIDs).compactMap { photos[$0] }
        vars["count"] = "\(onPage.count)"
        vars["count_cn"] = chineseCount(onPage.count)
        let pool = onPage.isEmpty ? project.photos : onPage
        if let hero = pool.max(by: { $0.score < $1.score }) {
            for (k, v) in exifValues(hero.path) { vars[k] = v }
            // 正文里要分清的两项（水印那套键不动）：{focal_mm} 实际焦距（手机的 6.8mm 留一位小数）；
            // {fstop} = f/4.5（光圈没记录时整项没有，{fstop|未记录} 不会剩个「f/」）。
            if let focal = focalLength(hero.path) {
                vars["focal_mm"] = focal < 10 ? String(format: "%.1fmm", focal) : String(format: "%.0fmm", focal)
            }
            // 手动镜头不报光圈时 FNumber 写 0：当没记录。
            if let f = vars["fnumber"], let value = Double(f), value > 0 { vars["fstop"] = "f/" + f }
        }
        if let first = pool.compactMap(\.captureTime).min() {
            for (k, v) in dateVariables(first) { vars[k] = v }
        }
        return vars
    }

    /// 期号里写了别的字（「第3期」「Vol.3」「No. 12」）：取第一串数字当期号 —— 报纸的「第{issue_n}期」不会印成
    /// 「第第3期期」。一个数字都没有（「春季号」）= nil，照原样印。
    static func issueDigits(_ text: String) -> Int? {
        let digits = text.drop { !$0.isASCII || !$0.isNumber }.prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 一格照片自己的占位符（变量是按页算的一份）：{frame} = 这一格照片的帧号（片边、印样）。
    /// 照片没有帧号 / 空格子 = 原样（不加这个键，{frame} 展开成空）。
    static func cellVariables(_ vars: [String: String], photo: CollagePhotoRef?) -> [String: String] {
        guard let frame = photo?.frameNo else { return vars }
        var out = vars
        out["frame"] = frame
        return out
    }

    /// {masthead}：用户填了就用（转大写）；没填按标题 —— 带拉丁字母的转大写，没有拉丁字母的把汉字转拼音、
    /// 去声调、一段汉字之内去空格、大写（拾光 → SHIGUANG；标点、数字和用户自己的空格不动）。
    /// 不预置任何真实刊名：标题空着时是「拾光」的拼音。
    static func mastheadText(_ masthead: String, title: String) -> String {
        let own = masthead.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own.uppercased() }
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.unicodeScalars.contains(where: isLatinLetter) { return t.uppercased() }
        let out = romanized(t)
        // 标题全是转不出来的字（表情、生僻字）：当成没起标题，用「拾光」的拼音。
        let left = out.unicodeScalars.filter { !CharacterSet.whitespaces.union(.punctuationCharacters).contains($0) }
        return left.isEmpty ? romanized("拾光") : out
    }

    /// 汉字转拼音、去声调、一段汉字之内去空格、大写；别的字符原样大写（{masthead} 用：拾光 → SHIGUANG）。
    static func romanized(_ t: String) -> String {
        // 转拼音要建 ICU 转写器（每次零点几毫秒）：每帧预览都要展开占位符，按标题缓存。
        pinyinLock.lock()
        let hit = pinyinCache[t]
        pinyinLock.unlock()
        if let hit { return hit }
        // 只转汉字那几段，每段的音节之间去空格；用户自己的空格、标点、数字原样留着
        // （「拾光·春日 2026」→ SHIGUANG·CHUNRI 2026，以前整句去空格成了 CHUNRI2026）。
        // 转不出来的不印：ICU 不认的生僻字（扩展 D 区，转完还是原字，刊头的西文字体里没有它、画成一个缺字方框）去掉；
        // 假名、谚文这类别的文字转成拉丁字母（の → NO），和汉字连在一起；表情、符号去掉（刊头字体里没有，
        // 人物挡字也量不出它挡了多少）。整句转完什么都不剩：{masthead} 当成没起标题（mastheadText）。
        func isIdeograph(_ ch: Character) -> Bool { ch.unicodeScalars.contains { $0.properties.isIdeographic } }
        var out = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            let latin = run.applyingTransform(.mandarinToLatin, reverse: false) ?? run
            let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
            out += plain.filter { !$0.isWhitespace && !isIdeograph($0) }.uppercased()
            run = ""
        }
        for ch in t {
            if isIdeograph(ch) {
                run.append(ch)
            } else if ch.isLetter, !ch.unicodeScalars.contains(where: isLatinLetter) {
                // 假名、谚文、西里尔……：转拉丁字母，转不出 ASCII 字母的不要。
                flush()
                let latin = String(ch).applyingTransform(.toLatin, reverse: false) ?? ""
                let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
                out += plain.filter { $0.isASCII && $0.isLetter }.uppercased()
            } else if ch.isSymbol, (ch.unicodeScalars.first?.value ?? 0) >= 0x100 {
                // 表情、Latin-1 以外的符号：刊头字体里没有。+ $ ° © 这种照旧印。
                flush()
            } else {
                flush()
                out += String(ch).uppercased()
            }
        }
        flush()
        pinyinLock.lock()
        if pinyinCache.count > 64 { pinyinCache.removeAll() }
        pinyinCache[t] = out
        pinyinLock.unlock()
        return out
    }

    private static let pinyinLock = NSLock()
    private static var pinyinCache: [String: String] = [:]

    /// {initial}：刊头（没填 = 标题）里第一个字母或数字，转成一个大写的西文字母 / 数字 —— 汉字取拼音的首字母
    /// （拾光集 → S，「拾光 Vol.2」也是 S），带音调的去掉音调（Été → E），假名这类转拉丁字母（さくら → S）。
    /// 巨字开篇拿 Athelas 画它：Athelas 没有汉字，汉字会落到粗黑体的方块字上。一个都取不到 = 空（不画）。
    static func initialLetter(_ masthead: String, title: String) -> String {
        let own = masthead.trimmingCharacters(in: .whitespaces)
        let source = own.isEmpty ? title : own
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "" }
        func ascii(_ s: String) -> String? {
            s.first { $0.isASCII && ($0.isLetter || $0.isNumber) }.map { String($0).uppercased() }
        }
        let ch = String(first)
        if let hit = ascii(ch) { return hit }
        if first.unicodeScalars.contains(where: { $0.properties.isIdeographic }), let hit = ascii(romanized(ch)) { return hit }
        let latin = ch.applyingTransform(.toLatin, reverse: false) ?? ch
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return ascii(plain.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? plain) ?? ""
    }

    /// 用户填的刊头是不是真实刊名（检视器只提示一句、不拦；成套、模板自检也拿它查默认文字）。这张表只用来比对，
    /// 不进任何默认值、占位文字、模板名（DESIGN.md §0.4）。比的是去掉空格、标点之后的大写。
    static func looksLikeRealMasthead(_ text: String) -> Bool {
        let key = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !key.isEmpty else { return false }
        if realMastheads.contains(key) { return true }
        // 刊名后面跟了别的词（「Vogue Spring」「Kinfolk Notes」「ELLE 春日」）：按词再查一遍，连着的两三个词拼起来
        // 也查（「Vanity Fair Spring」）。一两个字母的刊名（W、ID、GQ）只认整句，免得「W 系列」这种误报。
        let words = mastheadWords(text)
        guard words.count > 1 else { return false }
        for i in words.indices {
            var joined = ""
            for j in i..<min(words.count, i + 3) {
                joined += words[j]
                if joined.count >= 3, realMastheads.contains(joined) { return true }
            }
        }
        return false
    }

    /// 刊头拆成词（大写）：按空格、标点拆，西文和汉字之间也拆开（「ELLE春日」→ ELLE、春日）。
    private static func mastheadWords(_ text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var wordIsHan = false
        for ch in text.uppercased() {
            guard ch.isLetter || ch.isNumber else {
                if !word.isEmpty { words.append(word) }
                word = ""
                continue
            }
            let han = ch.unicodeScalars.contains { $0.properties.isIdeographic }
            if !word.isEmpty, han != wordIsHan {
                words.append(word)
                word = ""
            }
            word.append(ch)
            wordIsHan = han
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    /// 检视器那句提示看的是实际印出来的刊头：刊头空着时按标题生成（标题填 Vogue，{masthead} 印出来就是 VOGUE）；
    /// 中文刊名转成拼音就对不上表了，刊头空着时标题原文也查一遍。
    static func mastheadLooksReal(masthead: String, title: String) -> Bool {
        if looksLikeRealMasthead(mastheadText(masthead, title: title)) { return true }
        // 时尚刊印的是截短的刊头（{masthead_short}：长西文标题只留第一个词），那个词也查一遍。
        if looksLikeRealMasthead(CollageStyleFashion.shortMasthead(masthead, title: title)) { return true }
        return masthead.trimmingCharacters(in: .whitespaces).isEmpty && looksLikeRealMasthead(title)
    }

    private static let realMastheads: Set<String> = [
        "VOGUE", "ELLE", "BAZAAR", "HARPERSBAZAAR", "MUSE", "W", "GQ", "TIME", "KINFOLK", "CEREAL", "MARIECLAIRE",
        "COSMOPOLITAN", "LOFFICIEL", "NUMERO", "NUMÉRO", "ID", "DAZED", "VANITYFAIR", "ESQUIRE", "INSTYLE", "TATLER",
        "ALLURE", "GLAMOUR", "VOGUECHINA", "ELLECHINA", "PORTER", "APARTAMENTO", "MONOCLE", "WALLPAPER", "NEWYORKER",
        "THENEWYORKER", "LIFE", "NATIONALGEOGRAPHIC", "时尚芭莎", "芭莎", "嘉人", "世界时装之苑", "智族", "时尚",
        "服饰与美容", "悦己", "红秀", "大都市", "周末画报", "人物", "三联生活周刊", "新周刊",
    ]

    /// A–Z、带变音符号的拉丁字母（É、Ü……）。
    private static func isLatinLetter(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || ((0xC0...0x24F).contains(v) && v != 0xD7 && v != 0xF7)
    }

    static func dateVariables(_ date: Date) -> [String: String] {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: date)
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
        // 不补零的日（英文日期 MARCH 5, 2026 不写 05）。
        v["day_num"] = String(d)
        // 不补零的日子（英文日期行：March 3, 2026，不是 March 03）。
        v["day_n"] = String(d)
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
        v["month_en_title"] = String(monthEN.prefix(1)) + monthEN.dropFirst().lowercased()
        // 星期：Calendar 的 weekday 1 = 星期日（和日期同一个日历、同一个时区）。
        let weekday = max(1, min(7, c.weekday ?? 1))
        v["weekday_cn"] = "星期" + ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
        v["weekday_en"] = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"][weekday - 1]
        for (k, value) in lunarVariables(date, timeZone: cal.timeZone) { v[k] = value }
        return v
    }

    /// 农历日期（九月十四、闰六月初一）和干支纪年（丙午）。用系统的农历日历算，干支按六十甲子查表 ——
    /// 不用依赖 locale 的「U」格式；也不能按公历年份算：农历新年前的一、二月还是上一年的干支。
    static func lunarVariables(_ date: Date, timeZone: TimeZone) -> [String: String] {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = timeZone
        let c = chinese.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day,
              (1...12).contains(month), (1...30).contains(day) else { return [:] }
        let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let digits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        let dayText: String
        switch day {
        case 1...10: dayText = "初" + digits[day]
        case 11...19: dayText = "十" + digits[day - 10]
        case 20: dayText = "二十"
        case 21...29: dayText = "廿" + digits[day - 20]
        default: dayText = "三十"
        }
        let leap = c.isLeapMonth == true ? "闰" : ""
        // 农历日历的 year 是六十甲子里的第几年（1 = 甲子）。
        let stems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
        let branches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
        let cycle = ((year - 1) % 60 + 60) % 60
        return ["lunar": leap + months[month - 1] + dayText, "ganzhi": stems[cycle % 10] + branches[cycle % 12]]
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

    /// 0…9999 → 〇 / 七 / 十二 / 一百零五 / 一百二十八 / 二千零一十（期号、张数）；超出范围照写阿拉伯数字。
    static func chineseCount(_ n: Int) -> String {
        guard n >= 0, n < 10000 else { return String(n) }
        if n == 0 { return "〇" }
        if n < 100 { return chineseNumber(n) }
        let digits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        var out = ""
        var gap = false
        for (unit, name) in [(1000, "千"), (100, "百"), (10, "十"), (1, "")] {
            let d = (n / unit) % 10
            if d == 0 {
                gap = !out.isEmpty
                continue
            }
            // 中间空了一位或几位读一个「零」（一百零五、一千零五），末尾的零不读（一百一十）。
            if gap { out += "零" }
            gap = false
            out += digits[d] + name
        }
        return out
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

    static let placeholderRegex = try! NSRegularExpression(pattern: "\\{([a-z_0-9]+)(?:\\|([^{}]*))?\\}")

    /// {key} 换成值；没有的键换成空串（不留 "{lens}" 这种字样）。{key|默认} = 没有值时用默认那句
    /// （电影字幕：没填副标题也有一句字，不然点了什么都不出）。带 [[…]]（可省的一段）的走 fillOptional
    /// （CollageStyleSwissTypeset.swift），别的照老规矩只换占位符。
    static func fill(_ template: String, vars: [String: String]) -> String {
        template.contains("[[") ? fillOptional(template, vars: vars) : substitute(template, vars: vars)
    }

    /// 只换占位符（fill 的老规矩）。
    static func substitute(_ template: String, vars: [String: String]) -> String {
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

    /// 一行字（模板里的一行、正文里的一行）展开占位符：按「 · 」分段，段里的占位符都写成「可省略」的 {key|}
    /// （竖线后面什么都不写）、而且全是空的那一段连同它的分隔点一起不印 —— 没有 EXIF 的照片不剩「 ·  · f/ · s · ISO」，
    /// 手动镜头（没有焦距、光圈）是「X-T50 · 1/250s · ISO 200」。一段都不剩 = 空串（这一行不排）。
    /// 只认 {key|}：没写它的字（旧模板、别的套件的 {key}、{key|替代}）一个字都不丢，就是 fill 原样（逐字一样）。
    static func fillDroppingEmpty(_ template: String, vars: [String: String]) -> String {
        fill(withoutEmptySegments(template, vars: vars) ?? template, vars: vars)
    }

    /// 正文展开占位符：一行一行去掉 {key|} 全空的段，整行都去掉了的那一行连换行一起去掉（本来就空的行留着分段）。
    static func fillBody(_ text: String, vars: [String: String]) -> String {
        var changed = false
        let lines = text.components(separatedBy: "\n").compactMap { line -> String? in
            guard let trimmed = withoutEmptySegments(line, vars: vars) else { return line }
            changed = true
            return trimmed.isEmpty ? nil : trimmed
        }
        guard changed else { return fill(text, vars: vars) }
        // 去掉的是开头几行（没有拍摄时间）：分段的空行不能留在最前面，把正文往下顶一行。
        return fill(lines.joined(separator: "\n"), vars: vars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉 {key|} 全空的段之后的模板；没有要去的 = nil。
    private static func withoutEmptySegments(_ line: String, vars: [String: String]) -> String? {
        guard line.contains("|}") else { return nil }
        let parts = line.components(separatedBy: " · ")
        let kept = parts.filter { !optionalSegmentEmpty($0, vars: vars) }
        return kept.count == parts.count ? nil : kept.joined(separator: " · ")
    }

    /// 这段字里有占位符，每个都写成 {key|}（竖线后面是空的 =「可省略」），而且都展开成空。
    private static func optionalSegmentEmpty(_ s: String, vars: [String: String]) -> Bool {
        let ns = s as NSString
        let matches = placeholderRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return false }
        return matches.allSatisfy { match in
            let marker = match.range(at: 2)
            guard marker.location != NSNotFound, marker.length == 0 else { return false }
            return (vars[ns.substring(with: match.range(at: 1))] ?? "").isEmpty
        }
    }

    // MARK: - 排版

    private struct Run {
        let line: CTLine
        let width: Double
        let ascent: Double
        let descent: Double
        let size: Double
        let indent: Double
        /// 花字（nil = 普通字）；color = 字色（渐变的上端）。
        var effect: CollageTextEffect? = nil
        var color: CollageColor = .ink

        var hasBand: Bool { effect?.hasBand ?? false }
        /// 底条比字左右各宽出、上下各高出多少（横排）。量字块尺寸和画都算上，fit 不会把放得下的字缩小。
        var bandPadX: Double { hasBand ? size * 0.32 : 0 }
        var bandPadY: Double { hasBand ? size * 0.14 : 0 }
    }

    private static func makeRun(_ string: String, _ spec: CollageTextLine, size: Double) -> Run {
        // 只缩字不缩行（CollageTextLine.glyphScale，overflow = shrink 放不下时 overflowed 填的）：字形按缩小的字号排，
        // 行框（上下沿）、行距、细线还按原字号 —— 基线、细线留在原来的格线上。没缩 = 原样（逐像素不变）。
        let shrink = spec.glyphScale < 0.9999
        let glyph: Double = shrink ? size * spec.glyphScale : size
        var font = self.font(spec.font, spec.weight, italic: spec.italic, size: CGFloat(glyph))
        // 横向压窄：字形和字宽一起按比例收（字体矩阵），量出来的宽就是画出来的宽，花字的轮廓也跟着窄。
        if spec.widthScale < 0.9999 {
            var matrix = CGAffineTransform(scaleX: CGFloat(spec.widthScale), y: 1)
            font = CTFontCreateCopyWithAttributes(font, CGFloat(glyph), &matrix, nil)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): spec.color.cgColor,
            NSAttributedString.Key(kCTKernAttributeName as String): NSNumber(value: spec.tracking * glyph),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        // 末字后面的字距不算宽度，否则居中/右对齐会偏。
        let trimmed = max(0, width - spec.tracking * glyph)
        // 上下沿按原字号（字体的上下沿和字号成正比）。
        let box: Double = shrink ? 1 / spec.glyphScale : 1
        return Run(line: line, width: trimmed, ascent: Double(ascent) * box, descent: Double(descent) * box,
                   size: size, indent: spec.indent * size,
                   effect: spec.effect.flatMap { $0.isEmpty ? nil : $0 }, color: spec.color)
    }

    /// 一行真正要排的字：展开占位符、再改大小写（画、量、出图记录、铺满宽度都走这一个，记下的和画的一样）。
    /// 标了 onlyWhenFilled 的小标签：它管的那个值是空的就整行不印。
    static func lineString(_ spec: CollageTextLine, vars: [String: String]) -> String {
        if let key = spec.onlyWhenFilled, (vars[key] ?? "").isEmpty { return "" }
        return cased(fillDroppingEmpty(spec.text, vars: vars), spec.textCase)
    }

    static func cased(_ s: String, _ textCase: CollageTextCase) -> String {
        switch textCase {
        case .none: return s
        case .upper: return s.uppercased()
        case .lower: return s.lowercased()
        // 按固定的西文规则（不跟系统语言走）：每个词首字母大写、其余小写 —— {month_en} 的 OCTOBER 成 October。
        case .title: return s.capitalized(with: Locale(identifier: "en_US_POSIX"))
        case .traditional: return traditional(s)
        case .traditionalRTL: return rightToLeft(traditional(s))
        }
    }

    /// 简转繁（ICU Hans-Hant，按字带常用词：公历 → 公曆、头发 → 頭髮；「农历」会转成「農歷」，模板里的固定字直接写繁体）。
    /// 每帧预览都要展开，按原文缓存（同拼音刊头）。
    static func traditional(_ s: String) -> String {
        guard !s.isEmpty, s.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return s }
        hantLock.lock()
        let hit = hantCache[s]
        hantLock.unlock()
        if let hit { return hit }
        let out = s.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? s
        hantLock.lock()
        if hantCache.count > 256 { hantCache.removeAll() }
        hantCache[s] = out
        hantLock.unlock()
        return out
    }

    private static let hantLock = NSLock()
    private static var hantCache: [String: String] = [:]

    /// 右起横排（民国报纸的标题条）：字序倒过来、照常从左往右画，读的人从右往左读。西文、数字连成的一段
    /// （Vol.2、ISO 125）不拆、不倒；括号、引号换成反向的那一个（「《拾光》」倒过来读还是开口朝里）。
    static func rightToLeft(_ s: String) -> String {
        let mirror: [Character: Character] = ["《": "》", "》": "《", "「": "」", "」": "「", "『": "』", "』": "『",
                                              "（": "）", "）": "（", "〈": "〉", "〉": "〈", "【": "】", "】": "【",
                                              "“": "”", "”": "“", "‘": "’", "’": "‘", "(": ")", ")": "("]
        func latin(_ c: Character) -> Bool { c.isASCII && !c.isWhitespace && c != "(" && c != ")" }
        var units: [String] = []
        var run = ""
        var spaces = ""
        for c in s {
            if latin(c) {
                // 西文段里夹的空格（ISO 125）跟着这一段走；段前段后的空格单独算一格。
                run += spaces + String(c)
                spaces = ""
            } else if c == " ", !run.isEmpty {
                spaces += " "
            } else {
                if !run.isEmpty { units.append(run) }
                run = ""
                units += spaces.map { String($0) }
                spaces = ""
                units.append(String(mirror[c] ?? c))
            }
        }
        if !run.isEmpty { units.append(run) }
        units += spaces.map { String($0) }
        return units.reversed().joined()
    }

    /// 正文里不能断开的占位符：相机 EXIF 来的值（ExifTags 的键 + {focal_mm}{fstop}）和 ISO 日期。
    private static let unbreakableKeys = ["make", "brand", "model", "lens", "fnumber", "fstop", "focal", "focal_mm",
                                          "shutter", "iso", "datetime", "date_iso"]

    /// 正文真正要排的字：展开占位符，要繁体的再转（画、灰条判断、出图记录同一个）。相机写的那几项（机型、镜头、
    /// 参数、日期）里的连字符、斜杠前后夹零宽不断行符（U+2060 WJ，不占宽、不出字形）：X-T50、f/5.0、1/2000 不会在
    /// 「X-」「f/」后面断到下一行。标题、副标题这些用户自己打的字（「日系/胶片/人像」）照常能断，模板里的字也不动。
    static func bodyText(_ body: CollageBody, vars: [String: String]) -> String {
        var joined = vars
        for key in unbreakableKeys {
            guard let v = vars[key], v.contains("-") || v.contains("/") else { continue }
            joined[key] = v.replacingOccurrences(of: "-", with: "\u{2060}-\u{2060}")
                .replacingOccurrences(of: "/", with: "\u{2060}/\u{2060}")
        }
        // 竖排正文（民国竖排）：中文日期的年、月、日每一组之内也夹不断行符，「二〇二六年」不会拆成「二〇二」和
        // 「六年」排在两列上（组与组之间照常能换列）；星期也不拆（1:1 时「星期」和「六。」不再分在两列）。
        // 横排的照旧（一行能放下的多，拆开也还在同一行附近）。
        if body.vertical {
            for key in ["date_cn_full", "date_cn", "weekday_cn"] {
                guard let v = vars[key] else { continue }
                joined[key] = dateGroupsJoined(v)
            }
        }
        // 展开走 fillBody（{key|} 全空的段连同分隔点不印、整行空了连换行去掉；没写竖线的 = fill 原样）。
        let s = fillBody(body.text, vars: joined)
        return body.traditional ? traditional(s) : s
    }

    /// 二〇二六年三月二十一日 → 每个字之间夹 U+2060，只在「年」「月」后面留可以换列的口子。
    static func dateGroupsJoined(_ v: String) -> String {
        var out = ""
        var previous: Character?
        for ch in v {
            if let p = previous, p != "年", p != "月" { out += "\u{2060}" }
            out.append(ch)
            previous = ch
        }
        return out
    }

    /// 字块在 1 倍（字号按 short 换算）时的外包尺寸。转了 ±90° 的宽高互换：就是它在页面上占的框。
    static func measure(_ text: CollageText, short: Double, vars: [String: String]) -> CGSize {
        let s = upright(text, short: short, vars: vars)
        return text.isRotated ? CGSize(width: s.height, height: s.width) : s
    }

    /// 没转之前（按阅读方向摆正）的尺寸。
    private static func upright(_ text: CollageText, short: Double, vars: [String: String]) -> CGSize {
        // 细线框：框里的字照常量，四边各加一份退进去的距离。
        if let pad = boxInset(text, short: short, vars: vars) {
            let inner = upright(unboxed(text), short: short, vars: vars)
            return CGSize(width: Double(inner.width) + 2 * pad, height: Double(inner.height) + 2 * pad)
        }
        return text.vertical ? measureVertical(text, short: short, vars: vars)
            : measureHorizontal(text, short: short, vars: vars)
    }

    /// 细线框（报眼）的框线粗细（相对短边，画的时候不少于 1 像素）。
    private static let boxRule = 0.0013

    /// 细线框：字从框线往里退多少（框线 + 0.55 个首行字号）；不是细线框 = nil。
    private static func boxInset(_ text: CollageText, short: Double, vars: [String: String]) -> Double? {
        guard text.rule, text.ruleStyle == .box else { return nil }
        let firstLine = text.lines.first { !lineString($0, vars: vars).isEmpty }
        // 框里一行字都没有（报眼的星期、农历、干支都靠拍摄时间，照片没记）：框也不画，不留一个空方框。
        if firstLine == nil, text.body == nil { return nil }
        let first = firstLine?.size ?? 0.04
        return max(1, short * boxRule) + first * short * 0.55
    }

    /// 框里的字：同一块字去掉框（框单独画，里面照常排）。
    private static func unboxed(_ text: CollageText) -> CollageText {
        var t = text
        t.rule = false
        return t
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

    /// 「铺满宽度」的行（刊头）：字号放大或缩小到正好占满 box 的阅读方向（横排 = 宽、竖排 = 高；转了 90° 的反过来）。
    /// 只改带 fitWidth 的行，其余原样；一行都没有时原样返回（旧版式逐像素不变）。宽和字号成正比（字距、缩进、
    /// 底条都按字号算）：按比例放一次、再量一次修掉字形取整的误差。留 0.2% 的余量：fit 量出来比框宽一丝就会整块再缩 2%。
    static func fittingWidth(_ text: CollageText, in box: CGSize, short: Double, vars: [String: String]) -> CollageText {
        guard text.lines.contains(where: { $0.fitWidth }) else { return text }
        // 按阅读方向摆正之后的框：横排的「宽」是阅读方向、「高」是行往下摞的方向；竖排反过来。细线框里的字铺满框里面。
        let pad: Double = boxInset(text, short: short, vars: vars) ?? 0
        let turned = text.isRotated ? CGSize(width: box.height, height: box.width) : box
        let frame = CGSize(width: max(0, Double(turned.width) - 2 * pad), height: max(0, Double(turned.height) - 2 * pad))
        let along = text.vertical ? frame.height : frame.width
        let room = Double(text.vertical ? frame.width : frame.height)
        let target = Double(along) * 0.998
        guard target > 1, short > 0 else { return text }
        var out = text
        for i in out.lines.indices where out.lines[i].fitWidth {
            let spec = out.lines[i]
            let s = lineString(spec, vars: vars)
            guard !s.isEmpty, spec.size > 0 else { continue }
            var size = spec.size
            for _ in 0..<2 {
                let extent = lineExtent(s, spec, size: size * short, vertical: text.vertical)
                guard extent > 0 else { break }
                size *= target / extent
            }
            // 短词（≤ 4 个字母的刊头）：放大到 size（上限）为止，剩下的宽加大字距两端对齐（末字后面的字距本来就不算宽）。
            // 字距最多 spreadMax（R1：四个字母的短刊名实测约 +0.4em；再大就读成一个个分开的字母「A  Y  A」），还铺不满就比框窄、居中。
            if spec.spreadShort, size > spec.size, !text.vertical, s.count > 1 {
                size = spec.size
                var flat = spec
                flat.tracking = 0
                let base = lineExtent(s, flat, size: size * short, vertical: false)
                let gaps = Double(s.count - 1)
                let t: Double = (target - base) / max(1e-6, size * short * gaps)
                out.lines[i].tracking = max(spec.tracking, min(spreadMax, t))
            }
            out.lines[i].size = size
        }
        // 另一个方向放不下（文字格不够高）：只把铺满宽度的行往回收，别的行字号不动 —— 不然 drawShort 会把日期这种
        // 小字一起按比例缩没了。别的行自己就放不下时收不动，交给 drawShort 整体缩。
        let block = upright(out, short: short, vars: vars)
        let total = Double(text.vertical ? block.width : block.height)
        if total > room {
            var rest = out
            for i in rest.lines.indices where rest.lines[i].fitWidth { rest.lines[i].size *= 1e-4 }
            let restSize = upright(rest, short: short, vars: vars)
            let others = Double(text.vertical ? restSize.width : restSize.height)
            let k: Double = (room - others) / max(1e-6, total - others) * 0.995
            if k > 0, k < 1 {
                for i in out.lines.indices where out.lines[i].fitWidth { out.lines[i].size *= k }
            }
        }
        return out
    }

    /// 短词刊头（spreadShort）两端对齐时字距的上限（em）。
    static let spreadMax = 0.45

    /// 一行沿阅读方向占多长（横排 = 宽 + 缩进 + 底条两头；竖排 = 下沉 + 字数 × 字距 + 底条上下）。
    static func lineExtent(_ s: String, _ spec: CollageTextLine, size: Double, vertical: Bool) -> Double {
        if vertical {
            let advance: Double = size * (1.14 + spec.tracking)
            let band: Double = (spec.effect?.hasBand ?? false) ? size * 0.6 : 0
            return spec.indent * size + Double(s.count) * advance + band
        }
        let r = makeRun(s, spec, size: size)
        return r.width + r.indent + 2 * r.bandPadX
    }

    /// 已经按 fit 算好字号：原样画进 rect（不再缩）。转了 90° 的绕 rect 中心转。
    /// owner = 这块字是谁（页码 + 格子路径 + 第几块）：只给灰条定种子用，同一页上两块参数一样的正文不会画成同一个样子。
    static func drawFitted(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                           vars: [String: String], canvasHeight: Int, owner: String = "") {
        guard rect.width > 1, rect.height > 1 else { return }
        if text.isRotated {
            ctx.saveGState()
            rotate(ctx, text, about: rect)
            drawUpright(text, in: uprightRect(rect, text), ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight,
                        owner: owner)
            ctx.restoreGState()
        } else {
            drawUpright(text, in: rect, ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight, owner: owner)
        }
    }

    /// shadowScale：花字投影的偏移、模糊在设备空间（不跟 CTM 走），字是在缩放过的 CTM 里画的（自由图层按
    /// 渲染缩放 scaleBy 之后画，short 是成品尺寸）就要把这次渲染的缩放传进来，不然预览里投影大 1/scale 倍。
    /// 文字格、压字的 short 已经乘过缩放，CTM 只翻了个面，用默认 1。owner 同 drawFitted（灰条的种子）。
    static func draw(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                     vars: [String: String], canvasHeight: Int, shadowScale: Double = 1, owner: String = "") {
        guard rect.width > 2, rect.height > 2 else { return }
        let laid = prepared(text, in: rect, short: short, vars: vars)
        let text = laid.text
        let fitted = laid.short
        ctx.saveGState()
        // 只防字溢到隔壁格；花字的描边、投影、发光往外伸多少就多留多少，不能被切成一刀齐。
        let overhang = effectOverhang(text, short: fitted)
        ctx.clip(to: rect.insetBy(dx: -2 - overhang, dy: -2 - overhang))
        if text.isRotated { rotate(ctx, text, about: rect) }
        drawUpright(text, in: uprightRect(rect, text), ctx: ctx, short: fitted, vars: vars, canvasHeight: canvasHeight,
                    shadowScale: shadowScale, owner: owner)
        ctx.restoreGState()
    }

    /// draw 真正排的字和字号基准：先把「铺满宽度」的行放到框宽，再按 drawShort 整体缩到放得下。
    /// 出图记录（文字格、文字图层）用同一个，记下的和画出来的不会差。
    static func prepared(_ text: CollageText, in rect: CGRect, short: Double,
                         vars: [String: String]) -> (text: CollageText, short: Double) {
        // 先按每行的 overflow 折行 / 只缩这一行（CollageStyleSwissTypeset.swift；没设的原样）。
        let broken = overflowed(text, in: rect.size, short: short, vars: vars)
        let filled = fittingWidth(broken, in: rect.size, short: short, vars: vars)
        return (filled, drawShort(filled, in: rect, short: short, vars: vars))
    }

    private static func drawUpright(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                                    vars: [String: String], canvasHeight: Int, shadowScale: Double = 1,
                                    owner: String) {
        if let pad = boxInset(text, short: short, vars: vars) {
            // 细线框：框贴着 rect（文字格 = 整格，压字 = 字块），线画在框里面；字退进去照常排。
            let t = max(1, short * boxRule)
            let color = text.lines.first?.color ?? .rule
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor(alpha: 0.9))
            ctx.setLineWidth(CGFloat(t))
            ctx.stroke(rect.insetBy(dx: CGFloat(t / 2), dy: CGFloat(t / 2)))
            ctx.restoreGState()
            drawUpright(unboxed(text), in: rect.insetBy(dx: CGFloat(pad), dy: CGFloat(pad)), ctx: ctx, short: short,
                        vars: vars, canvasHeight: canvasHeight, shadowScale: shadowScale, owner: owner)
            return
        }
        if text.vertical {
            drawVertical(text, in: rect, ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight,
                         shadowScale: shadowScale, owner: owner)
        } else {
            drawHorizontal(text, in: rect, ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight,
                           shadowScale: shadowScale, owner: owner)
        }
    }

    /// 转 ±90° 的字排在「转回去」的框里：同一个中心、宽高互换；画的时候绕中心转回来正好盖住 rect。
    static func uprightRect(_ rect: CGRect, _ text: CollageText) -> CGRect {
        guard text.isRotated else { return rect }
        return CGRect(x: rect.midX - rect.height / 2, y: rect.midY - rect.width / 2, width: rect.height, height: rect.width)
    }

    /// 绕 rect 中心转（左上原点、y 朝下的坐标里正角 = 顺时针：90° 从上往下读，−90° 从下往上读，和自由图层同一个方向）。
    private static func rotate(_ ctx: CGContext, _ text: CollageText, about rect: CGRect) {
        let angle = CGFloat(Double(text.rotation) * .pi / 180)
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: angle)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
    }

    /// draw 实际用的字号基准：先按 1 倍排一次，放不下就整体按比例缩（用户打了很长的标题也不出界）。
    /// 出图记录（.marks.json 的 texts、dumptexts）用同一个，记下的字号和画出来的不会差。
    static func drawShort(_ text: CollageText, in rect: CGRect, short: Double, vars: [String: String]) -> Double {
        var fitScale = 1.0
        for _ in 0..<3 {
            let size = measure(text, short: short * fitScale, vars: vars)
            let fx = Double(rect.width) / max(1, size.width)
            let fy = Double(rect.height) / max(1, size.height)
            let f = min(fx, fy)
            if f >= 1 { break }
            fitScale *= f * 0.98
        }
        return short * fitScale
    }

    /// 字块按 alignH / alignV 落在 rect 里的外框（和 drawHorizontal / drawVertical 同一套对齐）。short = 已经放得下的字号基准。
    /// 有正文的字块占满整个 rect（正文铺满剩下的地方）；转了 90° 的在转回去的框里对齐、再转回页面。
    static func blockRect(_ text: CollageText, in rect: CGRect, short: Double, vars: [String: String]) -> CGRect {
        if text.body != nil { return rect }
        let frame = uprightRect(rect, text)
        let block = upright(text, short: short, vars: vars)
        let w = Double(block.width)
        let h = Double(block.height)
        let x: Double
        switch text.alignH {
        case .leading: x = Double(frame.minX)
        case .center: x = Double(frame.midX) - w / 2
        case .trailing: x = Double(frame.maxX) - w
        }
        let y: Double
        switch text.alignV {
        case .leading: y = Double(frame.minY)
        case .center: y = Double(frame.midY) - h / 2
        case .trailing: y = Double(frame.maxY) - h
        }
        let r = CGRect(x: x, y: y, width: w, height: h)
        guard text.isRotated else { return r }
        let angle = CGFloat(Double(text.rotation) * .pi / 180)
        let t = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: angle)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        return r.applying(t)
    }

    // MARK: - 字形轮廓（人物挡字：量每个字母被挡掉多少）

    /// 一个字形：第几行（空行不算，和 expandedLines 同一个下标）、轮廓和外框（成品坐标、左上原点，就是 drawFitted
    /// 把字画在 rect 里的位置）、这一行的基线（横排没转过时是页面上的 y；别的情况是转回去之前的）。
    struct Glyph {
        var line: Int
        var path: CGPath
        var bounds: CGRect
        var baseline: Double
    }

    /// drawFitted(text, in: rect, short:) 画出来的每个字形的轮廓：只有字本身（细线、印章、正文、底条、描边、投影都不算）。
    /// 位置照搬 drawHorizontal / drawVertical 的算法（那边改了这里要一起改；--mask-selftest 拿真画出来的墨核对重合）。
    static func glyphOutlines(_ text: CollageText, in rect: CGRect, short: Double, vars: [String: String]) -> [Glyph] {
        guard rect.width > 1, rect.height > 1 else { return [] }
        var frame = uprightRect(rect, text)
        var inner = text
        if let pad = boxInset(text, short: short, vars: vars) {
            frame = frame.insetBy(dx: CGFloat(pad), dy: CGFloat(pad))
            inner = unboxed(text)
        }
        let upright = inner.vertical ? verticalGlyphs(inner, in: frame, short: short, vars: vars)
                                     : horizontalGlyphs(inner, in: frame, short: short, vars: vars)
        guard text.isRotated else { return upright }
        let angle = CGFloat(Double(text.rotation) * .pi / 180)
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: angle)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        return upright.compactMap { g in
            guard let path = g.path.copy(using: &t) else { return nil }
            return Glyph(line: g.line, path: path, bounds: path.boundingBoxOfPath, baseline: g.baseline)
        }
    }

    /// 一行（CTLine）在 (x, 基线) 处的每个字形轮廓：CoreText 坐标（y 朝上）翻成左上原点。
    private static func lineGlyphs(_ line: CTLine, x: Double, baseline: Double, index: Int) -> [Glyph] {
        var out: [Glyph] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let value = attrs[kCTFontAttributeName as String] else { continue }
            let font = value as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            // 位置在「文字空间」：压窄（字体矩阵）的那一行，画的时候位置也乘这个矩阵（字形轮廓本身已经带着它）。
            let matrix = CTRunGetTextMatrix(run)
            for i in 0..<count {
                let at = positions[i].applying(matrix)
                let tx = CGFloat(x) + at.x
                let ty = CGFloat(baseline) - at.y
                var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: tx, ty: ty)
                guard let path = CTFontCreatePathForGlyph(font, glyphs[i], &t), !path.isEmpty else { continue }
                let box = path.boundingBoxOfPath
                guard box.width > 0, box.height > 0 else { continue }
                out.append(Glyph(line: index, path: path, bounds: box, baseline: baseline))
            }
        }
        return out
    }

    /// 同 drawHorizontal 的排法（只走到字，不画别的）。
    private static func horizontalGlyphs(_ text: CollageText, in rect: CGRect, short: Double,
                                         vars: [String: String]) -> [Glyph] {
        let runs = horizontalRuns(text, short: short, vars: vars)
        let block = measureHorizontal(text, short: short, vars: vars)
        var y: Double
        switch text.alignV {
        case .leading: y = Double(rect.minY)
        case .center: y = Double(rect.midY) - Double(block.height) / 2
        case .trailing: y = Double(rect.maxY) - Double(block.height)
        }
        if text.body != nil { y = Double(rect.minY) }
        func x(for width: Double, indent: Double) -> Double {
            switch text.alignH {
            case .leading: return Double(rect.minX) + indent
            case .center: return Double(rect.midX) - width / 2
            case .trailing: return Double(rect.maxX) - width - indent
            }
        }
        let underEach = text.rule && text.ruleStyle == .underEachLine
        var out: [Glyph] = []
        for (i, r) in runs.enumerated() {
            let boxW = r.width + 2 * r.bandPadX
            let boxH = r.ascent + r.descent + 2 * r.bandPadY
            let boxX = x(for: boxW, indent: r.indent)
            out += lineGlyphs(r.line, x: boxX + r.bandPadX, baseline: y + r.bandPadY + r.ascent, index: i)
            y += boxH
            if underEach { y += r.size * eachLineRuleRoom }
            if i < runs.count - 1 { y += text.lineSpacing * r.size }
        }
        return out
    }

    /// 同 drawVertical 的排法（只走到字）。
    private static func verticalGlyphs(_ text: CollageText, in rect: CGRect, short: Double,
                                       vars: [String: String]) -> [Glyph] {
        let cols = columns(text, short: short, vars: vars)
        guard !cols.isEmpty else { return [] }
        let block = measureVertical(text, short: short, vars: vars)
        var right: Double
        switch text.alignH {
        case .leading: right = Double(rect.minX) + Double(block.width)
        case .center: right = Double(rect.midX) + Double(block.width) / 2
        case .trailing: right = Double(rect.maxX)
        }
        var top: Double
        switch text.alignV {
        case .leading: top = Double(rect.minY)
        case .center: top = Double(rect.midY) - Double(block.height) / 2
        case .trailing: top = Double(rect.maxY) - Double(block.height)
        }
        if text.body != nil {
            right = Double(rect.maxX)
            top = Double(rect.minY)
        }
        let underEach = text.rule && text.ruleStyle == .underEachLine
        var out: [Glyph] = []
        for (i, col) in cols.enumerated() {
            let center = right - col.width / 2
            var y = top + col.indent + col.padY
            for ch in col.chars {
                let glyphH = ch.ascent + ch.descent
                let baseline = y + (col.advance - glyphH) / 2 + ch.ascent
                out += lineGlyphs(ch.line, x: center - ch.width / 2, baseline: baseline, index: i)
                y += col.advance
            }
            if underEach { right -= col.size * eachLineRuleRoom }
            right -= col.width + text.lineSpacing * col.size
        }
        return out
    }

    /// 每行展开占位符之后的字（空行不画、也不记）。
    static func expandedLines(_ text: CollageText, vars: [String: String]) -> [(line: CollageTextLine, text: String)] {
        text.lines.compactMap { spec in
            let s = lineString(spec, vars: vars)
            return s.isEmpty ? nil : (spec, s)
        }
    }

    // 细线的尺寸（相对字号 / 短边）。每行下面那条：贴着这一行字框下面 0.1 字高，这一行多占 0.32 字高。
    private static let eachLineRuleRoom = 0.32
    private static let hairline = 0.0012
    private static let swissHairline = 0.0015
    /// 粗细双线：粗、间隔、细（相对短边；画的时候各自不少于 2 / 1 / 1 像素）。
    private static let thickRule = 0.0045
    private static let thickThinGap = 0.0025
    private static let thinRule = 0.0015
    /// 标题和正文之间空多少（相对第一行字号）。
    private static let bodyGap = 0.6

    /// 字块末尾的细线占多高（横排）/ 多宽（竖排的通栏、双线）。每行下面那种算在每一行里，这里是 0。
    private static func ruleRoom(_ text: CollageText, first: Double, short: Double) -> Double {
        guard text.rule else { return 0 }
        switch text.ruleStyle {
        case .short, .full: return first * 0.9
        case .underEachLine: return 0
        case .thickThin: return first * 0.6 + short * (thickRule + thickThinGap + thinRule)
        // 细线框不占行后面的地方（四边的退让在 upright 里加）。
        case .box: return 0
        }
    }

    /// 正文最少占多大（两行）：字块只有这么点地方时标题照样缩，正文不会被挤没。
    private static func bodyMinimum(_ body: CollageBody, short: Double) -> Double {
        body.size * short * body.leading * 2
    }

    private static func fillRule(_ ctx: CGContext, _ rect: CGRect, color: CollageColor, alpha: Double) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColor(alpha: alpha))
        ctx.fill(rect)
        ctx.restoreGState()
    }

    // 横排：逐行按 alignH 对齐；细线、印章跟在最后一行下面；正文在最下面占满剩下的地方。

    private static func horizontalRuns(_ text: CollageText, short: Double, vars: [String: String]) -> [Run] {
        text.lines.compactMap { spec in
            let s = lineString(spec, vars: vars)
            guard !s.isEmpty else { return nil }
            return makeRun(s, spec, size: spec.size * short)
        }
    }

    private static func measureHorizontal(_ text: CollageText, short: Double, vars: [String: String]) -> CGSize {
        let runs = horizontalRuns(text, short: short, vars: vars)
        let underEach = text.rule && text.ruleStyle == .underEachLine
        var h = 0.0
        var w = 0.0
        for (i, r) in runs.enumerated() {
            h += r.ascent + r.descent + 2 * r.bandPadY
            if underEach { h += r.size * eachLineRuleRoom }
            if i < runs.count - 1 { h += text.lineSpacing * r.size }
            w = max(w, r.width + r.indent + 2 * r.bandPadX)
        }
        let first = runs.first?.size ?? short * 0.04
        if text.rule { h += ruleRoom(text, first: first, short: short) }
        if let seal = text.seal { h += first * 0.6 + sealSide(seal, short: short) }
        if let body = text.body {
            h += bodyMinimum(body, short: short) + (runs.isEmpty ? 0 : first * bodyGap)
        }
        return CGSize(width: w, height: max(0, h))
    }

    private static func drawHorizontal(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                                       vars: [String: String], canvasHeight: Int, shadowScale: Double = 1,
                                       owner: String) {
        let runs = horizontalRuns(text, short: short, vars: vars)
        let block = measureHorizontal(text, short: short, vars: vars)
        var y: Double
        switch text.alignV {
        case .leading: y = Double(rect.minY)
        case .center: y = Double(rect.midY) - Double(block.height) / 2
        case .trailing: y = Double(rect.maxY) - Double(block.height)
        }
        // 有正文：标题从顶上排起，正文占满下面剩下的地方（垂直对齐无从谈起）。
        if text.body != nil { y = Double(rect.minY) }
        func x(for width: Double, indent: Double) -> Double {
            switch text.alignH {
            case .leading: return Double(rect.minX) + indent
            case .center: return Double(rect.midX) - width / 2
            case .trailing: return Double(rect.maxX) - width - indent
            }
        }
        let underEach = text.rule && text.ruleStyle == .underEachLine
        let color = runs.isEmpty ? CollageColor.rule : (text.lines.first?.color ?? .rule)
        for (i, r) in runs.enumerated() {
            // 一行的外框 = 字 + 底条的边（没有底条就是字本身）。
            let boxW = r.width + 2 * r.bandPadX
            let boxH = r.ascent + r.descent + 2 * r.bandPadY
            let boxX = x(for: boxW, indent: r.indent)
            if let fx = r.effect, fx.hasBand {
                drawBand(fx, rect: CGRect(x: boxX, y: y, width: boxW, height: boxH), ctx: ctx)
            }
            drawStyledLine(r, x: boxX + r.bandPadX, baseline: y + r.bandPadY + r.ascent, ctx: ctx,
                           canvasHeight: canvasHeight, shadowScale: shadowScale)
            y += boxH
            if underEach {
                // 每行下面一条，和这一栏一样宽（瑞士风：通栏细线，字压在线上）。
                let t = max(1, short * swissHairline)
                fillRule(ctx, CGRect(x: Double(rect.minX), y: y + r.size * 0.1, width: Double(rect.width), height: t),
                         color: color, alpha: 0.9)
                y += r.size * eachLineRuleRoom
            }
            if i < runs.count - 1 { y += text.lineSpacing * r.size }
        }
        let first = runs.first?.size ?? short * 0.04
        if text.rule {
            switch text.ruleStyle {
            case .short:
                y += first * 0.45
                let len = min(Double(rect.width) * 0.3, first * 2.4)
                let thickness = max(1, short * 0.0012)
                ctx.setFillColor(color.cgColor(alpha: 0.55))
                ctx.fill(CGRect(x: x(for: len, indent: 0), y: y, width: len, height: thickness))
                y += first * 0.45
            case .full:
                // 和字块一样宽。
                y += first * 0.45
                let len = Double(block.width)
                let thickness = max(1, short * hairline)
                fillRule(ctx, CGRect(x: x(for: len, indent: 0), y: y, width: len, height: thickness), color: color,
                         alpha: 0.9)
                y += first * 0.45
            case .underEachLine:
                break
            case .thickThin:
                // 报头下面：上粗下细，和这一栏一样宽。
                y += first * 0.3
                let thick = max(2, short * thickRule)
                let gap = max(1, short * thickThinGap)
                let thin = max(1, short * thinRule)
                let x0 = Double(rect.minX)
                let w = Double(rect.width)
                fillRule(ctx, CGRect(x: x0, y: y, width: w, height: thick), color: color, alpha: 1)
                fillRule(ctx, CGRect(x: x0, y: y + thick + gap, width: w, height: thin), color: color, alpha: 1)
                y += thick + gap + thin + first * 0.3
            case .box:
                // 细线框在 drawUpright 里画（这里拿到的是去掉框的字）。
                break
            }
        }
        if let seal = text.seal {
            y += first * 0.6
            let side = sealSide(seal, short: short)
            drawSeal(seal, rect: CGRect(x: x(for: side, indent: 0), y: y, width: side, height: side),
                     ctx: ctx, canvasHeight: canvasHeight)
            y += side
        }
        if let body = text.body {
            let top = y + (runs.isEmpty ? 0 : first * bodyGap)
            let area = CGRect(x: Double(rect.minX), y: top, width: Double(rect.width), height: max(0, Double(rect.maxY) - top))
            drawBody(body, in: area, ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight, owner: owner)
        }
    }

    // 竖排：每行一列，从右往左；字一个一个竖着码。短细线、印章在第一列下方；通栏、双线、每列一条在列的左边；
    // 正文在最左边占满剩下的地方。

    private struct Column {
        let chars: [Run]
        let size: Double
        let advance: Double
        let indent: Double
        var height: Double { indent + Double(chars.count) * advance }
        /// 一列的字是同一行拆出来的，花字也是同一个。
        var effect: CollageTextEffect? { chars.first?.effect }
        var hasBand: Bool { effect?.hasBand ?? false }
        /// 竖排底条：列左右各宽出、上下各高出多少。
        var padX: Double { hasBand ? size * 0.24 : 0 }
        var padY: Double { hasBand ? size * 0.3 : 0 }
        /// 这一列占的宽（字宽 + 底条两边）。
        var width: Double { size + 2 * padX }
        /// 这一列从顶到底（下沉 + 字 + 底条上下）。
        var extent: Double { height + 2 * padY }
    }

    private static func columns(_ text: CollageText, short: Double, vars: [String: String]) -> [Column] {
        text.lines.compactMap { spec in
            let s = lineString(spec, vars: vars)
            guard !s.isEmpty else { return nil }
            let size = spec.size * short
            let chars = s.map { makeRun(String($0), spec, size: size) }
            let advance = size * (1.14 + spec.tracking)
            return Column(chars: chars, size: size, advance: advance, indent: spec.indent * size)
        }
    }

    private static func measureVertical(_ text: CollageText, short: Double, vars: [String: String]) -> CGSize {
        let cols = columns(text, short: short, vars: vars)
        let underEach = text.rule && text.ruleStyle == .underEachLine
        var w = 0.0
        var h = 0.0
        for (i, c) in cols.enumerated() {
            w += c.width
            if underEach { w += c.size * eachLineRuleRoom }
            if i < cols.count - 1 { w += text.lineSpacing * c.size }
            h = max(h, c.extent)
        }
        if let first = cols.first {
            var tail = first.extent
            if text.rule && text.ruleStyle == .short { tail += first.size * 1.9 }
            if text.rule && text.ruleStyle != .short { w += ruleRoom(text, first: first.size, short: short) }
            if let seal = text.seal { tail += first.size * 0.35 + sealSide(seal, short: short) }
            h = max(h, tail)
            if let seal = text.seal { w = max(w, sealSide(seal, short: short)) }
        }
        if let body = text.body {
            w += bodyMinimum(body, short: short) + (cols.first.map { $0.size * bodyGap } ?? 0)
        }
        return CGSize(width: max(0, w), height: h)
    }

    private static func drawVertical(_ text: CollageText, in rect: CGRect, ctx: CGContext, short: Double,
                                     vars: [String: String], canvasHeight: Int, shadowScale: Double = 1,
                                     owner: String) {
        let cols = columns(text, short: short, vars: vars)
        if cols.isEmpty {
            // 只有正文：占满整个框。
            if let body = text.body {
                drawBody(body, in: rect, ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight, owner: owner)
            }
            return
        }
        let block = measureVertical(text, short: short, vars: vars)
        var right: Double
        switch text.alignH {
        case .leading: right = Double(rect.minX) + Double(block.width)
        case .center: right = Double(rect.midX) + Double(block.width) / 2
        case .trailing: right = Double(rect.maxX)
        }
        var top: Double
        switch text.alignV {
        case .leading: top = Double(rect.minY)
        case .center: top = Double(rect.midY) - Double(block.height) / 2
        case .trailing: top = Double(rect.maxY) - Double(block.height)
        }
        // 有正文：标题贴右上排，正文在左边占满剩下的地方。
        if text.body != nil {
            right = Double(rect.maxX)
            top = Double(rect.minY)
        }
        let underEach = text.rule && text.ruleStyle == .underEachLine
        let color = text.lines.first?.color ?? .rule
        var firstCenter = right - cols[0].width / 2
        var left = right
        for (i, col) in cols.enumerated() {
            let center = right - col.width / 2
            if i == 0 { firstCenter = center }
            if let fx = col.effect, fx.hasBand {
                drawBand(fx, rect: CGRect(x: right - col.width, y: top + col.indent, width: col.width,
                                          height: Double(col.chars.count) * col.advance + 2 * col.padY), ctx: ctx)
            }
            var y = top + col.indent + col.padY
            for ch in col.chars {
                let glyphH = ch.ascent + ch.descent
                let baseline = y + (col.advance - glyphH) / 2 + ch.ascent
                drawStyledLine(ch, x: center - ch.width / 2, baseline: baseline, ctx: ctx, canvasHeight: canvasHeight,
                               shadowScale: shadowScale)
                y += col.advance
            }
            left = right - col.width
            if underEach {
                // 每列左边一条竖线（竖排的「每行下面」），和整块一样高。
                let t = max(1, short * swissHairline)
                let room = col.size * eachLineRuleRoom
                fillRule(ctx, CGRect(x: left - col.size * 0.1 - t, y: top, width: t, height: Double(block.height)),
                         color: color, alpha: 0.9)
                left -= room
                right -= room
            }
            right -= col.width + text.lineSpacing * col.size
        }
        let first = cols[0]
        var y = top + first.extent
        if text.rule {
            switch text.ruleStyle {
            case .short:
                y += first.size * 0.3
                let len = first.size * 1.3
                let thickness = max(1, short * 0.0012)
                ctx.setFillColor(color.cgColor(alpha: 0.55))
                ctx.fill(CGRect(x: firstCenter - thickness / 2, y: y, width: thickness, height: len))
                y += len + first.size * 0.3
            case .full:
                // 整块左边一条竖线，和整块一样高。
                let t = max(1, short * hairline)
                fillRule(ctx, CGRect(x: left - first.size * 0.45 - t, y: top, width: t, height: Double(block.height)),
                         color: color, alpha: 0.9)
                left -= first.size * 0.9
            case .underEachLine:
                break
            case .thickThin:
                // 整块左边：靠字的是粗线，外面一条细线。
                let thick = max(2, short * thickRule)
                let gap = max(1, short * thickThinGap)
                let thin = max(1, short * thinRule)
                let x0 = left - first.size * 0.3 - thick
                let h = Double(block.height)
                fillRule(ctx, CGRect(x: x0, y: top, width: thick, height: h), color: color, alpha: 1)
                fillRule(ctx, CGRect(x: x0 - gap - thin, y: top, width: thin, height: h), color: color, alpha: 1)
                left = x0 - gap - thin - first.size * 0.3
            case .box:
                break
            }
        }
        if let seal = text.seal {
            y += first.size * 0.35
            let side = sealSide(seal, short: short)
            drawSeal(seal, rect: CGRect(x: firstCenter - side / 2, y: y, width: side, height: side),
                     ctx: ctx, canvasHeight: canvasHeight)
        }
        if let body = text.body {
            let edge = left - first.size * bodyGap
            let area = CGRect(x: Double(rect.minX), y: Double(rect.minY), width: max(0, edge - Double(rect.minX)),
                              height: Double(rect.height))
            drawBody(body, in: area, ctx: ctx, short: short, vars: vars, canvasHeight: canvasHeight, owner: owner)
        }
    }

    // MARK: - 正文（多栏）

    /// 正文是灰条 / 占位字 / 真的字（出图记录、印刷导出提示用）。
    static func bodyKind(_ body: CollageBody, vars: [String: String]) -> String {
        if bodyText(body, vars: vars).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "bars" }
        return body.filler ? "filler" : "text"
    }

    /// 每一栏的框（左上原点坐标）：横排是竖条、从左到右；竖排是横带、从上到下。
    static func bodyColumns(_ body: CollageBody, in rect: CGRect, short: Double) -> [CGRect] {
        let n = max(1, body.columns)
        let gap: Double = body.gap * body.size * short
        let gaps: Double = Double(n - 1) * gap
        if body.vertical {
            let bandH: Double = (Double(rect.height) - gaps) / Double(n)
            guard bandH > 1 else { return [rect] }
            return (0..<n).map { i in
                let y: Double = Double(rect.minY) + Double(i) * (bandH + gap)
                return CGRect(x: Double(rect.minX), y: y, width: Double(rect.width), height: bandH)
            }
        }
        let colW: Double = (Double(rect.width) - gaps) / Double(n)
        guard colW > 1 else { return [rect] }
        return (0..<n).map { i in
            let x: Double = Double(rect.minX) + Double(i) * (colW + gap)
            return CGRect(x: x, y: Double(rect.minY), width: colW, height: Double(rect.height))
        }
    }

    /// 正文排进 rect：CTFramesetter 一栏一栏往下接（上一栏放不下的从下一栏接着排）；文字为空画灰条。
    private static func drawBody(_ body: CollageBody, in rect: CGRect, ctx: CGContext, short: Double,
                                 vars: [String: String], canvasHeight: Int, owner: String) {
        let size = body.size * short
        guard size > 0.3, rect.width > CGFloat(size * 2), rect.height > CGFloat(size) else { return }
        let cols = bodyColumns(body, in: rect, short: short)
        let text = bodyText(body, vars: vars)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drawBars(body, columns: cols, ctx: ctx, short: short, owner: owner)
        } else {
            drawBodyText(fittedBody(body, text, columns: cols, short: short), text, columns: cols, ctx: ctx, short: short,
                         canvasHeight: canvasHeight)
        }
        guard body.columnRule, cols.count > 1 else { return }
        // 栏线：在栏距正中，墨色四成（报纸的栏线是细的、浅的）。
        let t = max(1, short * hairline)
        for i in 0..<(cols.count - 1) {
            let a = cols[i]
            let b = cols[i + 1]
            let line: CGRect
            if body.vertical {
                let mid = Double(a.maxY + b.minY) / 2
                line = CGRect(x: Double(rect.minX), y: mid - t / 2, width: Double(rect.width), height: t)
            } else {
                let mid = Double(a.maxX + b.minX) / 2
                line = CGRect(x: mid - t / 2, y: Double(rect.minY), width: t, height: Double(rect.height))
            }
            fillRule(ctx, line, color: body.color, alpha: 0.4)
        }
    }

    /// 正文排不下（格子比排版时想的矮：换了画布比例，「报纸风 · 英文复古」1:1 时正文格只装得下 3 行、要 5 行）：
    /// 字号一档档缩（每档 5%，最小 75%）到排得下，不悄悄丢掉后面的字（以前停在「focal length,」，后面的参数没了）。
    /// 栏的位置、栏距照原字号（对着上面的网格），只缩字。排得下 = 原样（一个像素都不变）；首字下沉的正文照旧不缩。
    static func fittedBody(_ body: CollageBody, _ text: String, columns cols: [CGRect], short: Double) -> CollageBody {
        guard body.dropCap == 0, !cols.isEmpty else { return body }
        func fits(_ b: CollageBody) -> Bool {
            let attributed = bodyString(b, text, size: b.size * short, capFirst: false)
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let total = attributed.length
            var location = 0
            var attrs: [CFString: Any] = [:]
            if b.vertical { attrs[kCTFrameProgressionAttributeName] = CTFrameProgression.rightToLeft.rawValue }
            for col in cols where location < total {
                let path = CGPath(rect: CGRect(origin: .zero, size: col.size), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), path,
                                                     attrs as CFDictionary)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { break }
                location += visible.length
            }
            return location >= total
        }
        guard !fits(body) else { return body }
        var b = body
        for step in 1...5 {
            let factor: Double = 1 - 0.05 * Double(step)
            b.size = body.size * factor
            if fits(b) { return b }
        }
        return b
    }

    /// 正文的段落样式：固定行高（栏与栏的行对得齐）、段首缩进、两端对齐。capFirst = 第一段有首字下沉，不再缩进。
    private static func bodyString(_ body: CollageBody, _ text: String, size: Double, capFirst: Bool) -> NSAttributedString {
        let font = self.font(body.font, body.weight, italic: false, size: CGFloat(size))
        func style(indent: Double) -> CTParagraphStyle {
            var alignment: CTTextAlignment = body.justified ? .justified : .natural
            var first = CGFloat(indent)
            var lineHeight = CGFloat(body.leading * size)
            var lineHeightMax = lineHeight
            return withUnsafePointer(to: &alignment) { pa in
                withUnsafePointer(to: &first) { pf in
                    withUnsafePointer(to: &lineHeight) { pmin in
                        withUnsafePointer(to: &lineHeightMax) { pmax in
                            let settings = [
                                CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                        value: pa),
                                CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size,
                                                        value: pf),
                                CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size,
                                                        value: pmin),
                                CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size,
                                                        value: pmax),
                            ]
                            return CTParagraphStyleCreate(settings, settings.count)
                        }
                    }
                }
            }
        }
        // 竖排：CoreText 在竖排的框里不认段首缩进，改成每段前面垫全角空格（中文竖排本来就是空两格）。
        var string = text
        var indent = body.firstLineIndent * size
        if body.vertical {
            let pad = String(repeating: "\u{3000}", count: Int(body.firstLineIndent.rounded()))
            string = text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : pad + $0 }.joined(separator: "\n")
            indent = 0
        }
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): body.color.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style(indent: indent),
        ]
        // 竖排：中文字立着排（西文横躺）。
        if body.vertical { attrs[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true }
        let out = NSMutableAttributedString(string: string, attributes: attrs)
        if capFirst {
            let ns = string as NSString
            let end = ns.range(of: "\n").location
            let length = end == NSNotFound ? ns.length : end
            out.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style(indent: 0),
                             range: NSRange(location: 0, length: length))
        }
        return out
    }

    private static func drawBodyText(_ body: CollageBody, _ text: String, columns cols: [CGRect], ctx: CGContext,
                                     short: Double, canvasHeight: Int) {
        let size = body.size * short
        let lineH = body.leading * size
        // 首字下沉（横排）：第一个字单独拿出来放大，压住开头几行，正文绕开它。
        var string = text
        var cap: String?
        if body.dropCap > 0, !body.vertical,
           let i = string.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) {
            cap = String(string[i])
            string = String(string[string.index(after: i)...])
        }
        let attributed = bodyString(body, string, size: size, capFirst: cap != nil)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let total = attributed.length
        let h = CGFloat(canvasHeight)
        // 平衡分栏：每栏排几行（nil = 照旧一栏排满再接下一栏）。
        let quota = cap == nil ? balancedQuota(body, setter: setter, columns: cols, lineHeight: lineH) : nil
        var location = 0
        ctx.saveGState()
        // CoreText 的坐标（y 朝上）：和 drawLine 同一个翻法，左上原点的 rect (x, y) 换成 (x, h − y − 高)。
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        for (i, col) in cols.enumerated() where location < total {
            var box = CGRect(x: col.minX, y: h - col.maxY, width: col.width, height: col.height)
            // 平衡：这一栏的框收到正好装下分给它的几行（多留半行，装不下下一行），顶边 / 右边不动；最后一栏照旧整栏，
            // 万一断行和量的时候差一行也不会丢字（分到 0 行的栏也照旧整栏）。CoreText 照样从上一栏停下的地方接着排
            // （段中接排、两端对齐都和不平衡时一样）。
            if let quota, i < cols.count - 1, quota[i] > 0 {
                let keep: Double = (Double(quota[i]) + 0.5) * lineH
                if body.vertical {
                    let w: Double = min(Double(box.width), keep)
                    box = CGRect(x: Double(box.maxX) - w, y: Double(box.minY), width: w, height: Double(box.height))
                } else {
                    let tall: Double = min(Double(box.height), keep)
                    box = CGRect(x: Double(box.minX), y: Double(box.maxY) - tall, width: Double(box.width), height: tall)
                }
            }
            var attrs: [CFString: Any] = [:]
            if body.vertical { attrs[kCTFrameProgressionAttributeName] = CTFrameProgression.rightToLeft.rawValue }
            var capLine: CTLine?
            // 首字基线比第 N 行基线高多少（中文）、首字往左挪多少（墨的左边贴栏边）。
            var capLift = 0.0
            var capInkLeft = 0.0
            let lines = Double(body.dropCap)
            if i == 0, let cap {
                var spec = CollageTextLine(cap, font: body.font, weight: body.weight, size: 1, color: body.color)
                spec.tracking = 0
                let capSize: Double
                if isCJK(cap) {
                    // 中文的墨在基线上下都有（宋体约 −0.17…0.78 字）：按「大写字高顶到基线」算会整个往下掉、
                    // 戳进第 N+1 行。拿几个顶天立地的常用字量出这套字一行墨的上下沿（字面），首字按同一个字面放大：
                    // 墨顶齐第 1 行的墨顶、墨底齐第 N 行的墨底。按字面不按首字自己的墨 ——「一」这种扁字不会被拉成 N 行高。
                    let measured = CTLineGetBoundsWithOptions(makeRun("永本报", spec, size: size).line, .useGlyphPathBounds)
                    // 量不出来（字体里一个字形都没有）就按常见的字面 −0.12…0.88。
                    let face = measured.isNull ? CGRect(x: 0, y: -0.12 * size, width: size, height: size) : measured
                    let faceH: Double = max(0.5, Double(face.height) / size)
                    let faceBottom: Double = Double(face.minY) / size
                    let reach: Double = (lines - 1) * lineH / faceH
                    capSize = size + reach
                    capLift = -faceBottom * reach
                } else {
                    // 西文：大写字高占满下沉的几行，首行字顶到第 N 行基线。
                    let capFont = self.font(body.font, body.weight, italic: false, size: CGFloat(size))
                    let ratio: Double = max(0.5, Double(CTFontGetCapHeight(capFont)) / size)
                    let span: Double = (lines - 1) * lineH + ratio * size
                    capSize = span / ratio
                }
                let run = makeRun(cap, spec, size: capSize)
                capLine = run.line
                // 没有墨的字（BOM、零宽字符打头）量出来是 null：按字宽算，别让坐标变成无穷大。
                let inkBounds = CTLineGetBoundsWithOptions(run.line, .useGlyphPathBounds)
                let ink = inkBounds.isNull ? CGRect(x: 0, y: 0, width: run.width, height: 0) : inkBounds
                capInkLeft = Double(ink.minX)
                // 挖掉的那块：宽 = 首字的墨 + 小半个字的空；高只挖到第 N 行的半中间 —— 第 N 行和它相交（让开），
                // 第 N+1 行碰不到。正好挖 N 行高的话第 N+1 行的行框上沿贴着挖口下沿，让不让全看浮点误差，
                // 预览（0.3、0.5）和导出排出来的断行就不一样了。
                let roomW: Double = Double(ink.maxX) - capInkLeft + size * 0.45
                let roomH: Double = (lines - 0.5) * lineH
                let room = CGRect(x: Double(col.minX), y: Double(h - col.minY) - roomH, width: roomW, height: roomH)
                attrs[kCTFrameClippingPathsAttributeName] = [
                    [kCTFramePathClippingPathAttributeName: CGPath(rect: room, transform: nil)] as CFDictionary,
                ] as CFArray
            }
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0),
                                                 CGPath(rect: box, transform: nil), attrs as CFDictionary)
            CTFrameDraw(frame, ctx)
            if let capLine, CFArrayGetCount(CTFrameGetLines(frame)) > 0 {
                // 第 N 行的基线 = 第 1 行的行原点（相对栏框左下角）往下 N − 1 个行高（行高是定死的）：
                // 正文不到 N 行时首字也照样占 N 行的位置。
                var first = CGPoint.zero
                CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 1), &first)
                let baseline: Double = Double(box.minY + first.y) - (lines - 1) * lineH + capLift
                ctx.textPosition = CGPoint(x: Double(box.minX) - capInkLeft, y: baseline)
                CTLineDraw(capLine, ctx)
            }
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
        }
        ctx.restoreGState()
    }

    /// 平衡分栏：整段先排进一栏宽、不限长的框里数出几行（栏都一样宽，分开排时断行和这里一样），再平均分给各栏，
    /// 前几栏多一行。不平衡、只有一栏、一行都没有，或者分得最多的那栏装不下（行高定死，按行数 × 行高算）= nil，
    /// 照旧一栏排满再接下一栏。
    private static func balancedQuota(_ body: CollageBody, setter: CTFramesetter, columns cols: [CGRect],
                                      lineHeight: Double) -> [Int]? {
        guard body.balanced, cols.count > 1, let first = cols.first, lineHeight > 0 else { return nil }
        let far: Double = 1_000_000
        let along = Double(body.vertical ? first.height : first.width)
        // 横排：栏宽、往下不限高；竖排：带高、往左不限宽（一列列从右往左）。
        let probe = body.vertical ? CGRect(x: 0, y: 0, width: far, height: along)
            : CGRect(x: 0, y: 0, width: along, height: far)
        var attrs: [CFString: Any] = [:]
        if body.vertical { attrs[kCTFrameProgressionAttributeName] = CTFrameProgression.rightToLeft.rawValue }
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: probe, transform: nil),
                                             attrs as CFDictionary)
        let count = CFArrayGetCount(CTFrameGetLines(frame))
        let n = cols.count
        let base = count / n
        let extra = count % n
        let most = base + (extra > 0 ? 1 : 0)
        let room = Double(body.vertical ? first.width : first.height)
        guard count > 0, Double(most) * lineHeight <= room else { return nil }
        return (0..<n).map { base + ($0 < extra ? 1 : 0) }
    }

    /// 汉字、假名、谚文、全角标点：首字下沉按字面对齐（墨在基线上下都有），别的按大写字高。
    private static func isCJK(_ s: String) -> Bool {
        guard let u = s.unicodeScalars.first else { return false }
        if u.properties.isIdeographic { return true }
        switch u.value {
        case 0x3000...0x31FF, 0xAC00...0xD7AF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }

    /// 灰条：每行一条墨色细条（西文 = x 字高、中文和竖排 = 半个字），四成墨。段首缩进、段末一行 30–90% 宽、
    /// 段间空一行，段落 3–8 行（R5 §6）。段落长短的种子看正文自己的参数（栏数、字体、字号、行高、横竖）和 owner
    /// （这块字在第几页、哪一格、第几块）：预览、导出、每次运行都一样，同一页上两块参数一样的正文也各是各的样子。
    private static func drawBars(_ body: CollageBody, columns cols: [CGRect], ctx: CGContext, short: Double,
                                 owner: String) {
        let size = body.size * short
        let lineH = body.leading * size
        guard lineH > 0.5 else { return }
        let font = self.font(body.font, body.weight, italic: false, size: CGFloat(size))
        let xHeight = max(Double(CTFontGetXHeight(font)), size * 0.35)
        let bar: Double = body.font.isChinese || body.vertical ? size * 0.5 : xHeight
        var rng = BarRandom(seed: barSeed(body, owner: owner))
        var remaining = 0
        var blank = false
        ctx.saveGState()
        ctx.setFillColor(body.color.cgColor(alpha: 0.4))
        for col in cols {
            let across = Double(body.vertical ? col.width : col.height)
            let along = Double(body.vertical ? col.height : col.width)
            let count = Int(floor(across / lineH))
            guard count > 0 else { continue }
            for k in 0..<count {
                if blank {
                    blank = false
                    continue
                }
                let starts = remaining == 0
                if starts { remaining = 3 + Int(rng.next() % 6) }
                let last = remaining == 1
                let indent = starts ? body.firstLineIndent * size : 0
                var length = along - indent
                if last { length *= 0.3 + 0.6 * rng.unit() }
                let offset = Double(k) * lineH
                let r: CGRect
                if body.vertical {
                    // 从右往左一列列：条在这一列正中。
                    let x = Double(col.maxX) - offset - (lineH + bar) / 2
                    r = CGRect(x: x, y: Double(col.minY) + indent, width: bar, height: max(0, length))
                } else {
                    // 条落在 x 字高那一带：行框正中略往下。
                    let y = Double(col.minY) + offset + (lineH - bar) / 2 + size * 0.08
                    r = CGRect(x: Double(col.minX) + indent, y: y, width: max(0, length), height: bar)
                }
                ctx.fill(r)
                remaining -= 1
                if last { blank = true }
            }
        }
        ctx.restoreGState()
    }

    private static func barSeed(_ body: CollageBody, owner: String) -> UInt64 {
        // FNV-1a：同一组参数永远同一个种子（不用 hashValue，那个每次进程启动都不一样）。
        // owner 是字串（页码、路径），不是框的坐标：坐标在不同缩放下有浮点误差，预览和导出会对不上。
        let key = "\(body.columns)|\(body.font.rawValue)|\(Int((body.size * 100_000).rounded()))|"
            + "\(Int((body.leading * 100).rounded()))|\(body.vertical)|\(owner)"
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }

    /// SplitMix64：灰条段落长短用，种子定了结果就定了。
    private struct BarRandom {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        /// 0…1。
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
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

    // MARK: - 花字

    /// 花字往字形外面伸出多少（描边 + 投影的模糊和下落），裁剪框要多留出来。
    static func effectOverhang(_ text: CollageText, short: Double) -> CGFloat {
        let reach = text.lines.compactMap { line -> Double? in
            guard let fx = line.effect, !fx.isEmpty else { return nil }
            let shadow = fx.shadow > 0.0001 ? fx.shadowBlur + fx.shadowOffset : 0
            return (fx.stroke + shadow) * line.size * short
        }.max() ?? 0
        return CGFloat(reach)
    }

    /// 带花字的一行（竖排是一个字）：投影 / 发光 → 描边（字形外面一圈）→ 字（纯色或上下渐变）。
    /// 没有花字就是原来的 drawLine。投影套在透明图层上落一次：描边和字不会各投各的。
    /// shadowScale = 这次渲染的缩放（只有在缩放过的 CTM 里画的自由图层才不是 1，见 draw）。
    private static func drawStyledLine(_ run: Run, x: Double, baseline: Double, ctx: CGContext, canvasHeight: Int,
                                       shadowScale: Double = 1) {
        guard let fx = run.effect else {
            drawLine(run.line, x: x, baseline: baseline, ctx: ctx, canvasHeight: canvasHeight)
            return
        }
        let size = run.size
        ctx.saveGState()
        // 回到 CoreText 的坐标（y 朝上），原点放在这一行的基线起点。
        ctx.translateBy(x: 0, y: CGFloat(canvasHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(x), y: CGFloat(Double(canvasHeight) - baseline))
        let shadowed = fx.shadow > 0.0001
        if shadowed {
            // 阴影偏移在设备空间（y 朝上）：往右下落 = (+, −)。size 是用户空间的字号，乘上 CTM 的缩放才是设备像素。
            let off = CGFloat(fx.shadowOffset * size * shadowScale)
            let blur = CGFloat(fx.shadowBlur * size * shadowScale)
            ctx.setShadow(offset: CGSize(width: off * 0.6, height: -off), blur: blur,
                          color: fx.shadowColor.cgColor(alpha: min(1, fx.shadow)))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        let outline = (fx.stroke > 0.0001 || fx.gradient != nil) ? glyphPath(run.line) : nil
        if fx.stroke > 0.0001, let outline, !outline.path.isEmpty {
            // 线宽 2× 描边粗细、居中描在轮廓上：里面那半被后画的字盖住，看到的就是字外面一圈。
            ctx.addPath(outline.path)
            ctx.setLineWidth(CGFloat(fx.stroke * size * 2))
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(fx.strokeColor.cgColor)
            ctx.strokePath()
        }
        if let to = fx.gradient, let outline, outline.complete, !outline.path.isEmpty,
           let gradient = CGGradient(colorsSpace: CollageRender.srgb, colors: [run.color.cgColor, to.cgColor] as CFArray,
                                     locations: [0, 1]) {
            ctx.saveGState()
            ctx.addPath(outline.path)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: run.ascent), end: CGPoint(x: 0, y: -run.descent),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        } else {
            // 纯色；或者行里有彩色字形（emoji，没有轮廓剪不出渐变）就按原样画。
            ctx.textPosition = .zero
            CTLineDraw(run.line, ctx)
        }
        if shadowed { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    /// 一行字的字形轮廓（CoreText 坐标：基线 y = 0、y 朝上）。complete = false：有彩色 / 位图字形没有轮廓。
    private static func glyphPath(_ line: CTLine) -> (path: CGPath, complete: Bool) {
        let path = CGMutablePath()
        var complete = true
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let value = attrs[kCTFontAttributeName as String] else {
                complete = false
                continue
            }
            let font = value as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            // 位置在「文字空间」：压窄（字体矩阵）的行画的时候位置要乘 run 的文字矩阵，不然描边、渐变的轮廓
            // 一个字比一个字往右错（S2 的压窄 + 花字描边就错过）。不压窄时是单位矩阵，结果和以前一样。
            let matrix = CTRunGetTextMatrix(run)
            for i in 0..<count {
                let at = positions[i].applying(matrix)
                var t = CGAffineTransform(translationX: at.x, y: at.y)
                if let g = CTFontCreatePathForGlyph(font, glyphs[i], &t) {
                    path.addPath(g)
                } else {
                    complete = false
                }
            }
        }
        return (path, complete)
    }

    /// 底条（左上原点坐标里的外框）。
    private static func drawBand(_ fx: CollageTextEffect, rect: CGRect, ctx: CGContext) {
        guard fx.hasBand, rect.width > 0, rect.height > 0 else { return }
        let r = min(rect.width, rect.height) / 2 * CGFloat(min(1, max(0, fx.bandRound)))
        ctx.saveGState()
        ctx.setFillColor(fx.bandColor.cgColor(alpha: min(1, fx.band)))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
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
