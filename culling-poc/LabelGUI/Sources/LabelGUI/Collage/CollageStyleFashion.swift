import Foundation

/// 「时尚刊」风格：时尚刊（封面人物挡字 + 内页）。规格见 reports/杂志风格调研_2026-10-23/DESIGN.md §3 K1。
///
/// 注册钩子：templates 按 CollageTemplates.builtin 里的位置进模板库（category 写「时尚刊」）；presets 拼在
/// CollageStyles.all 末尾。模板名全库唯一，模板名、分类名都不能包含别的分类名（--template-sheet --only、
/// 门禁按「包含」匹配）。积木用 CollageTemplates.photo / row / col / text，样式用 CollageStyles.make { s in … } ——
/// 这里的 static let 里别读 CollageStyles.all / preset(…) 和 CollageTemplates.builtin / find(…)：它们正拼着这两个
/// 数组，回头读自己会在初始化时卡死。只改这个文件（和同前缀的新文件），地基要改的在交付报告里单独列出。
/// 不预置任何真实刊名、胶片 / 滤镜品牌名（DESIGN.md §0.4）。
///
/// 尺寸都照 R1：画布 3:4（1440×1920），字号以画布短边计（size × 0.75 × 字高 em = 字高占页高）。
/// - 刊头：{masthead_short}（= {masthead}，没填刊头、标题转出来超过 12 个字母时截短：CHUNRI），Bodoni 72 Bold 铺满 95% 宽、压窄 0.85；8 个字母（拾光 → SHIGUANG）字高约 12.4%H，
///   短词到 20%H 就不再放大、改加字距两端对齐（spreadShort，字距最多 0.45em，还铺不满就居中）；字墨的顶定在 2.5%H（inkTop：
///   字框上面那截上伸部的空不算）；人后、定在上方、封面取景。
/// - 封面字层级（R1 §3 的表）：主卖点 4.5–6%H、次级 1.8–2.5%H、引导词 1.2–1.8%H；要读的字 ≥ 2.2%W（size 0.022）：
///   自动挑大小不往下缩，太长的标题自己缩、再断成两行（干净的字，CollageStyleFashionType）。
///   期号日期 0.7–1%H 只当纹理，和条码成组放右下（条码在遮挡带里、期号叠在条码上面）；封面字（clearBottom）和人脸不进。
/// - 细线下限（R1 §1）：Didot 只用在 size ≥ 0.069（巨字、大引号、主题字）；小的衬线字用 Bodoni 72 Book（≥ 0.04），
///   再小的用 Futura。
/// - 干净的字（scrim = false）：不垫雾面；深浅按每个字形底下最不利的地方挑，「刊头在后 · 无衬线」的封面字统一深浅
///   （matchTone）；还看不清就沿字边落一圈很淡的光晕；「一句话」底部那行主卖点配一道平滑的底部压暗（fade）。
///   刊头、巨字不加投影。
/// - 文案：中文每条 ≤ 12 字、都是真的（月份、农历、拍摄日期、焦距光圈来自照片，没有 EXIF 的那段不印）；
///   英文只用固定词（ISSUE、VOL.、PORTRAIT、SPECIAL EDITION、月份、星期）。
enum CollageStyleFashion {
    static let category = "时尚刊"

    static let templates: [CollageTemplate] = [
        coverSans, coverSerifRight, coverFrench, coverOneLine, spreadFull, spreadQuote, spreadOpener,
    ]

    static let presets: [CollageStyles.Preset] = [
        CollageStyles.Preset(key: "fashion", name: "时尚刊", style: style),
    ]

    /// 风格预设「时尚刊」：白、零边距、轻统一色调。
    static let style: CollageStyle = CollageStyles.make { s in
        s.background = .white
        s.margin = 0
        s.gutter = 0
        s.harmonize = 0.25
    }

    static let canvas = CollageCanvas.social[0]

    // MARK: - 积木

    /// 封面字的字体：西文全大写几何无衬线（Futura）、中文黑体（苹方）、宋体、小衬线（Bodoni 72 Book）。
    private static func sans(_ text: String, size: Double, tracking: Double = 0.2, weight: CollageWeight = .regular)
        -> CollageTextLine {
        var line = CollageTextLine(text, font: .futura, weight: weight, size: size, tracking: tracking, color: .white)
        line.textCase = .upper
        return line
    }

    private static func hei(_ text: String, size: Double, weight: CollageWeight = .regular, tracking: Double = 0.06)
        -> CollageTextLine {
        CollageTextLine(text, font: .pingfang, weight: weight, size: size, tracking: tracking, color: .white)
    }

    private static func song(_ text: String, size: Double, weight: CollageWeight = .bold, tracking: Double = 0.04)
        -> CollageTextLine {
        CollageTextLine(text, font: .songti, weight: weight, size: size, tracking: tracking, color: .white)
    }

    /// 小衬线（Bodoni 72 Book，可斜体）：R1 的细线下限是 size 0.04（横杠 ≥ 1.5 px），比这小的别用衬线。
    private static func bodoni(_ text: String, size: Double, italic: Bool = false, tracking: Double = 0)
        -> CollageTextLine {
        CollageTextLine(text, font: .bodoni, weight: .regular, size: max(0.04, size), tracking: tracking,
                        color: .white, italic: italic)
    }

    /// 刊头：人后、定在上方、字墨的顶在 2.5%H（R1：字顶 1–4%H；字框上面的上伸部留白不算）。
    static func masthead() -> CollageOverlay {
        // size 0.38 = 短词的上限（字高 20%H，DESIGN 15–20%H 的上沿）；长刊头按宽度铺满，用不到这个上限。
        var line = CollageTextLine("{masthead_short}", font: .bodoni, weight: .bold, size: 0.38, tracking: -0.01, color: .white)
        line.fitWidth = true
        line.widthScale = 0.85
        line.spreadShort = true
        let t = CollageText(lines: [line], vertical: false, alignH: .center, alignV: .leading)
        var o = CollageOverlay(text: t)
        o.anchor = .top
        o.inset = 0
        o.inkTop = 0.025
        o.maxWidth = 0.95
        o.shadow = 0
        o.layer = .behindSubject
        o.depth = 0.2
        return o
    }

    /// 封面字一栏：沿左 / 右边找位置（躲脸、躲刊头、挑每个字都看得清的地方），不进底部遮挡带。
    /// matchTone = 和同一格里别的 matchTone 字块统一深浅。
    private static func column(_ anchor: CollageAnchor, _ lines: [CollageTextLine], spacing: Double = 0.42,
                               width: Double = 0.4, matchTone: Bool = false) -> CollageOverlay {
        var t = CollageText(lines: lines, vertical: false, alignH: anchor == .rightColumn ? .trailing : .leading,
                            alignV: .leading)
        t.lineSpacing = spacing
        var o = CollageOverlay(text: t)
        o.anchor = anchor
        o.inset = 0.04
        o.maxWidth = width
        o.shadow = softShadow
        o.scrim = false
        o.matchTone = matchTone
        o.clearBottom = bottomBand
        return o
    }

    /// 期号日期一行（印刷比例的小字，只当纹理）：右下角（R6：期号、条码成组放右下）。有条码时叠在条码上面
    /// （aboveBarcode），没有时贴着下边、在遮挡带里。
    private static func issueLine(_ text: String = "ISSUE {issue} · {month_en} {year}", aboveBarcode: Bool = false)
        -> CollageOverlay {
        let t = CollageText(lines: [sans(text, size: 0.016, tracking: 0.32)], vertical: false,
                            alignH: .trailing, alignV: .leading)
        var o = CollageOverlay(text: t)
        o.anchor = .bottomTrailing
        o.inset = 0.035
        o.maxWidth = 0.6
        o.shadow = softShadow
        o.scrim = false
        if aboveBarcode { o.clearBottom = barcodeTop + 0.008 }
        return o
    }

    /// 人前的字：浅字落一点很淡的投影；看不清时（干净的字）投影变浓、深字落白晕。不垫雾面（scrim = false）。
    static let softShadow = 0.35

    /// 小红书封面底部被标题、头像挡住的那一截（R6：150 px / 1440 高 = 10.4%）。
    static let bottomBand = 0.104

    /// 条码：宽 15%W、高 9.5%W（= 7.1%H），离右边 3.5%W、离底边 3%H；条码顶离底边多高（页高的比例）。
    static let barcodeWidth = 0.15
    static let barcodeHeight = 0.095
    static let barcodeTop: Double = 0.03 + barcodeHeight * 0.75

    /// 装饰条码（日期编成 Code 128，不是 EAN/UPC/ISSN）：右下角、整个在遮挡带里。
    static func barcode() -> CollageItem {
        var item = CollageItem(kind: .sticker)
        item.sticker = .barcode
        item.color = .white
        item.label = "{date}"
        item.width = barcodeWidth
        item.height = barcodeHeight
        // 离右边 3.5%W、离底边 3%H（中心坐标相对画布宽、高）。
        item.cx = 1 - (0.035 + barcodeWidth / 2)
        item.cy = 1 - (0.03 + barcodeHeight * 0.75 / 2)
        return item
    }

    private static func coverCell(_ overlays: [CollageOverlay]) -> CollageNode {
        var cell = CollageCell.photo(nil, role: .hero)
        cell.framing = .cover
        cell.overlays = overlays
        return .leaf(cell)
    }

    // MARK: - 封面 4 款

    /// 1. 刊头在后 · 无衬线（R1 §3 (a)）：左右两栏全大写几何无衬线，两栏统一深浅（全白或全黑），中间 35–40% 留给人；
    /// 期号日期右下。焦距（这里和满版大片的署名）印镜头上的实际焦距 {focal_mm}：{focal} 是 35mm 等效，17-70 的镜头
    /// 会印成 92MM，和报纸风正文的 62mm 对不上。英文日期的日子用不补零的 {day_n}（March 5，不是 March 05）。
    static let coverSans = CollageTemplate(
        name: "时尚刊 · 刊头在后 · 无衬线",
        root: coverCell([
            masthead(),
            column(.leftColumn, [
                sans("{month_en} ISSUE", size: 0.024, tracking: 0.3),
                hei("{title}", size: 0.078, weight: .bold, tracking: 0.08),
                hei("{month_cn}人像", size: 0.034, weight: .light),
            ], width: 0.36, matchTone: true),
            column(.rightColumn, [
                sans("PORTRAIT", size: 0.032, tracking: 0.28, weight: .bold),
                sans("{focal_mm} · F/{fnumber}", size: 0.024, tracking: 0.16),
                hei("农历{lunar}", size: 0.026, weight: .light),
            ], width: 0.36, matchTone: true),
            issueLine(),
        ]),
        style: style, canvas: canvas, fitAspects: false, builtin: true, category: category)

    /// 2. 右栏衬线（R1 §3 (b)）：只用右栏、右对齐；Bodoni 斜体引导词配宋体大标题，标题用照片里的强调色；期号日期右下。
    static let coverSerifRight: CollageTemplate = {
        var title = song("{title}", size: 0.086, weight: .bold, tracking: 0.06)
        title.accentFromPhoto = true
        title.color = CollageColor(hex: 0xB0574A)
        return CollageTemplate(
            name: "时尚刊 · 右栏衬线",
            root: coverCell([
                masthead(),
                column(.rightColumn, [
                    bodoni("Portrait", size: 0.042, italic: true),
                    title,
                    bodoni("{month_en_title}", size: 0.042, italic: true),
                    song("{month_cn}{day_cn}", size: 0.03, weight: .regular, tracking: 0.12),
                    sans("VOL. {issue}", size: 0.024, tracking: 0.3),
                ], spacing: 0.32, width: 0.3),
                issueLine(),
            ]),
            style: style, canvas: canvas, fitAspects: false, builtin: true, category: category)
    }()

    /// 3. 法式左栏（R1 §3 (c)）：左栏强调色无衬线大写引导词 + 宋体、Bodoni 斜体；底部一个大的斜体主题字（PORTRAIT 的
    /// 首字母大写，Didot Italic）；右下条码，期号日期叠在条码上面。
    static let coverFrench: CollageTemplate = {
        var lead = sans("SPECIAL EDITION", size: 0.024, tracking: 0.12, weight: .bold)
        lead.accentFromPhoto = true
        lead.color = CollageColor(hex: 0xB0574A)
        var theme = CollageText(lines: [CollageTextLine("Portrait", font: .didot, weight: .regular, size: 0.2,
                                                        color: .white, italic: true)],
                                vertical: false, alignH: .center, alignV: .leading)
        theme.lineSpacing = 0
        // 主题字定在底部（R1：底部条带 73–96%H），抬到右下那组期号、条码上面（定死位置的字块之间不互相让）；
        // 左栏的封面字让着它。
        var word = CollageOverlay(text: theme)
        word.anchor = .bottom
        word.inset = 0.04
        word.maxWidth = 0.9
        word.shadow = softShadow
        word.scrim = false
        word.clearBottom = barcodeTop + 0.008 + 0.034
        return CollageTemplate(
            name: "时尚刊 · 法式左栏",
            root: coverCell([
                masthead(),
                column(.leftColumn, [
                    lead,
                    song("{title}", size: 0.06, weight: .bold, tracking: 0.06),
                    bodoni("{month_en_title} {day_n}", size: 0.042, italic: true),
                    song("{month_cn}的光", size: 0.034, weight: .regular, tracking: 0.08),
                ], spacing: 0.38, width: 0.3),
                word,
                issueLine(aboveBarcode: true),
            ]),
            style: style, canvas: canvas, fitAspects: false, builtin: true, category: category,
            items: [barcode()])
    }()

    /// 4. 一句话：刊头 + 一行主卖点（左下、遮挡带上面，配一道平滑的底部压暗）+ 右下条码和期号，别的都不要（极简）。
    static let coverOneLine: CollageTemplate = {
        var t = CollageText(lines: [
            sans("PORTRAIT · {year}", size: 0.024, tracking: 0.42),
            hei("{month_cn}，{title}", size: 0.07, weight: .bold, tracking: 0.1),
        ], vertical: false, alignH: .leading, alignV: .leading)
        t.lineSpacing = 0.3
        var line = CollageOverlay(text: t)
        line.anchor = .bottomLeading
        line.inset = 0.05
        // 最宽到 58%：右边留给条码和期号那一组（长标题断成两行）。
        line.maxWidth = 0.58
        line.shadow = softShadow
        line.scrim = false
        line.fade = 0.55
        line.clearBottom = bottomBand
        var issue = issueLine(aboveBarcode: true)
        issue.tone = .light
        return CollageTemplate(
            name: "时尚刊 · 一句话",
            root: coverCell([masthead(), line, issue]),
            style: style, canvas: canvas, fitAspects: false, builtin: true, category: category,
            items: [barcode()])
    }()

    // MARK: - 内页 3 款

    /// 页脚 folio：「页码 · 刊头 · 月份年份」（R1 §4：页底角、不显眼，size 0.011–0.013）。
    /// inset 按 folio 所在格子的短边算：满页的格子 0.04（3:4 上 58px）；引语单图的照片格只有半页宽，给 0.08，
    /// 离页边还是 58px（0.04 的话只有 29px，出一期四页的页脚高低、远近对不齐）。
    private static func folio(_ anchor: CollageAnchor, inset: Double = 0.04) -> CollageOverlay {
        let t = CollageText(lines: [sans("{no} · {masthead_short} · {month_en} {year}", size: 0.012, tracking: 0.3)],
                            vertical: false, alignH: anchor == .bottomTrailing ? .trailing : .leading, alignV: .leading)
        var o = CollageOverlay(text: t)
        o.anchor = anchor
        o.inset = inset
        o.maxWidth = 0.7
        o.shadow = softShadow
        o.scrim = false
        return o
    }

    /// 5. 满版大片：一张照片满版 + 右下竖排小署名（拍摄参数，沿照片侧边从下往上读；没有 EXIF 的那段不印）+ 左下 folio。
    static let spreadFull: CollageTemplate = {
        var credit = CollageText(lines: [
            sans("{date} · {focal_mm} · F/{fnumber} · {shutter}S · ISO {iso}", size: 0.011, tracking: 0.22),
        ], vertical: false, alignH: .leading, alignV: .leading)
        credit.rotation = -90
        var o = CollageOverlay(text: credit)
        o.anchor = .bottomTrailing
        o.inset = 0.03
        o.maxWidth = 0.6
        o.shadow = softShadow
        o.scrim = false
        var cell = CollageCell.photo(nil, role: .hero)
        cell.overlays = [o, folio(.bottomLeading)]
        return CollageTemplate(name: "时尚刊 · 满版大片", root: .leaf(cell), style: style, canvas: canvas,
                               fitAspects: false, builtin: true, category: category)
    }()

    /// 6. 引语单图（R1 §4 B）：左边一半留白放一段大引语（Didot 大引号 + 宋体两行、字号 0.072 + 小字落款日期，
    /// 左边距 7%W），右边一张竖图。照片格用「封面」景别：没有刊头时它就是「脸在格子正中、眼睛在上三分之一、不拉近」
    /// （自动景别按照片中线取，窄高的格子里人会被推到接缝上）。folio 在图的右下。
    /// 成套里四页共用一套样式（零边距），所以左边距靠每行的缩进给（缩进按本行字号算）。
    static let spreadQuote: CollageTemplate = {
        let left = 0.07
        func indented(_ line: CollageTextLine) -> CollageTextLine {
            var l = line
            l.indent = left / line.size
            return l
        }
        // 落款日期：照片没有拍摄时间时整行不印（不剩「—  ,」）。
        var byline = sans("[[— {month_en} {day_n}, {year}]]", size: 0.022, tracking: 0.24)
        byline.color = .warmGrey
        var quote = CollageText(lines: [
            indented(CollageTextLine("“", font: .didot, weight: .regular, size: 0.13, color: .rule)),
            indented(CollageTextLine("那天的光，", font: .songti, weight: .light, size: 0.072, tracking: 0.06,
                                     color: .ink)),
            indented(CollageTextLine("还在这里。", font: .songti, weight: .light, size: 0.072, tracking: 0.06,
                                     color: .ink)),
            indented(byline),
        ], vertical: false, alignH: .leading, alignV: .center)
        quote.lineSpacing = 0.34
        var cell = CollageCell.photo(nil, role: .hero)
        cell.framing = .cover
        // 照片格是半页宽（row 0.5）：folio 的边距按格子短边算要加倍，才和满页的内页一样离页边 0.04 页宽。
        cell.overlays = [folio(.bottomTrailing, inset: 0.08)]
        return CollageTemplate(
            name: "时尚刊 · 引语单图",
            root: CollageTemplates.row(0.5, CollageTemplates.text(quote), .leaf(cell)),
            style: style, canvas: canvas, fitAspects: false, builtin: true, category: category)
    }()

    /// 7. 巨字开篇（R1 §4 C）：一个巨大的单词（月份，字高约 15%H）横在照片上、人站在字前面（装饰大字只限总量）；
    /// 底边一段开篇小字（标题 + 哪个月的一组人像 + 拍于哪天，挑每个字都看得清的地方），右下 folio。
    static let spreadOpener: CollageTemplate = {
        var word = CollageTextLine("{month_en}", font: .bodoni, weight: .bold, size: 0.27, tracking: 0.02, color: .white)
        word.fitWidth = true
        var big = CollageOverlay(text: CollageText(lines: [word], vertical: false, alignH: .center, alignV: .leading))
        // 横在照片区 36% 高（字身 24–48%）：全身照这一截是头、脖子，人最窄，挡掉的墨不到三分之一，人才站得到字前面。
        // photot 21 张实测：放正中（胸口，汉服袖子张开最宽）8 张挡掉 35% 以上退回人前、压在身上；放 60%（胯，袖子垂下来）11 张；
        // 36% 一张都不退。
        big.anchor = .custom
        big.x = 0.5
        big.y = 0.36
        big.inset = 0
        big.maxWidth = 0.94
        big.shadow = 0
        big.layer = .behindSubject
        big.occlusionRule = .total
        big.maxOcclusion = 0.33
        var t = CollageText(lines: [
            song("{title}", size: 0.05, weight: .bold, tracking: 0.08),
            hei("{month_cn}的一组人像", size: 0.024, weight: .regular, tracking: 0.06),
            hei("摄于{date_cn_full}", size: 0.024, weight: .regular, tracking: 0.06),
        ], vertical: false, alignH: .leading, alignV: .leading)
        t.lineSpacing = 0.45
        var standfirst = CollageOverlay(text: t)
        standfirst.anchor = .bottomBand
        standfirst.inset = 0.05
        standfirst.maxWidth = 0.6
        standfirst.shadow = softShadow
        standfirst.scrim = false
        standfirst.clearBottom = 0.04
        var cell = CollageCell.photo(nil, role: .hero)
        cell.overlays = [big, standfirst, folio(.bottomTrailing)]
        return CollageTemplate(name: "时尚刊 · 巨字开篇", root: .leaf(cell), style: style, canvas: canvas,
                               fitAspects: false, builtin: true, category: category)
    }()

    // 一键成套「出一期」、挑主图、换封面在 CollageStyleFashionIssue.swift。
}
