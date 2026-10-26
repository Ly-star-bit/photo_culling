import Foundation

/// 「报纸风」风格：中文现代头版、民国竖排、英文复古、大字报。规格见 reports/杂志风格调研_2026-10-23/DESIGN.md §3 K4。
///
/// 注册钩子：templates 按 CollageTemplates.builtin 里的位置进模板库（category 写「报纸风」）；presets 拼在
/// CollageStyles.all 末尾。模板名全库唯一，模板名、分类名都不能包含别的分类名（--template-sheet --only、
/// 门禁按「包含」匹配）。积木用 CollageTemplates.photo / row / col / text，样式用 CollageStyles.make { s in … } ——
/// 这里的 static let 里别读 CollageStyles.all / preset(…) 和 CollageTemplates.builtin / find(…)：它们正拼着这两个
/// 数组，回头读自己会在初始化时卡死。只改这个文件（和同前缀的新文件），地基要改的在交付报告里单独列出。
/// 不预置任何真实刊名、胶片 / 滤镜品牌名（DESIGN.md §0.4）；不印刊号、ISSN，只用「第 {issue} 期」。
///
/// 默认正文全由占位符拼成（R5 §6 第 2 条）：每一句都只说这一页上真有的事 —— 日期、星期、农历干支是这一页最早那张
/// 的拍摄日；{count} 是这一页上的照片张数；器材和参数是这一页「评分最高的那一幅」的 EXIF（CollageTypeset.variables
/// 就是按分数取的，所以正文里直接这么叫，换了格子也不会说错）。不写 {make} / {brand}（品牌名），只写机型；读不到
/// EXIF 的照片（截图、去了信息的导出）每一项退成「未记录」，不留「以  拍摄」这种半句；没有拍摄时间的，日期、星期、
/// 农历那几句用 [[…]] 整段不印（不剩「农历　第1期」「本报讯 ，，农历。」「No. 1 · , ,」），通栏标题换成「影像纪事」。今日头版的正文是通栏 5 栏
/// （DESIGN §3 K4），真话只有一百来字，所以平衡分栏（CollageBody.balanced）：各栏行数平均分，不会排满前两栏、后面
/// 三栏空着；不编字、不默认灰条（要灰条就在检视器里清空正文，5 栏都成灰条）。
/// 正文格按最长的数据（自检第 7 段）排得下来定高：一般的数据只比它少一行，正文和下面的照片之间不会空出一大块。
enum CollageStyleNewspaper {

    // MARK: - 颜色（R5 §4 实测 / 风格化）

    /// 风格化的米色新闻纸（今日头版、大字报）。
    static let paper = CollageColor.rice
    /// 实测新闻纸（IFRA26 纸白，民国竖排、英文复古）。
    static let newsprint = CollageColor(hex: 0xDAD4CB)
    /// 墨：字和网点都用风格化的暖黑（实测的 #5B564F 在 9px 的小字上太灰，读不清）。
    static let ink = CollageColor.ink
    /// 印出来的红（M100 + Y100 印在新闻纸上），不是屏幕红 #E60012。
    static let red = CollageColor(hex: 0xCC5D57)

    // MARK: - 默认正文（只用真数据）

    /// 今日头版「本报讯」：通栏 5 栏、平衡分栏，每栏 10 个字。导语交代何时、哪一期、几幅图（标题、期号报头和日期栏里
    /// 也有，正文再说一遍是报纸的写法），第二段是评分最高那一幅的器材和参数。photot 这种一般的数据排 10 行 = 每栏
    /// 2 行；最长的数据（11 个字的标题、第 128 期、iPhone 15 Pro Max、1/32000、ISO 102400、闰冬月）13 行 = 每栏
    /// 最多 3 行（自检第 7 段）。焦距是镜头上的实际焦距 {focal_mm}（{focal} 是 35mm 等效，17-70 的镜头会印成 92mm）；
    /// 光圈写 f/5.0（{fstop}，没记录时整项「未记录」）。「第 1 期」「4 幅」的数字和量词之间夹不断行符（U+2060，
    /// 不占宽、没有字形）：栏窄，不在「第1」和「期」中间换栏。
    static let frontCopy = "本报讯　[[{date_cn_full}，{weekday_cn}，农历{lunar}。]]本期题为《{title}》，第\u{2060}{issue_n}\u{2060}期，"
        + "本版刊图{count}\u{2060}幅。\n"
        + "评分最高的一幅，拍摄器材：{model|未记录}；焦距{focal_mm|未记录}，光圈{fstop|未记录}，"
        + "快门{shutter|未记录}，感光度{iso|未记录}。"

    /// 民国竖排「本報訊」：固定字直接写繁体（ICU 会把「农历」转成「農歷」，这里写对的「農曆」），正文另开 traditional
    /// 转占位符的值（臘月、閏）和用户自己改的字。竖排里西文、数字是一个个立着排的（X / - / T / 5 / 0 立成一串，
    /// 老报纸是把西文横躺着排），所以正文里只放一定是汉字的值：不放机型、参数，也不放 {title}（用户的标题可能是
    /// 「Spring Portraits」，标题条是横排的，那里印）；张数、期号用中文数字（{count_cn}、{issue_cn}：二幀、第一期）。
    static let minguoCopy = "本報訊　[[{ganzhi}年{lunar}，即公曆{date_cn_full}，{weekday_cn}。\n]]"
        + "是為第{issue_cn}期，本版刊圖{count_cn}幀。"

    /// 英文复古：日期行用不补零的 {day_n}（March 3，不是 March 03）；张数写成「: N」免得 1 张时冒出 photographs。
    /// 期号、刊头在报头和日期行里，正文不重复（叠题下面只有五行的地方）。机型只在正文里说一次；焦距是实际焦距，
    /// 光圈写 f/4.5。
    static let englishCopy = "[[{month_en_title} {day_n}, {year}.—]]Photographs on this page: {count}. Particulars of the "
        + "highest-rated among them: camera, {model|unrecorded}; focal length, {focal_mm|unrecorded}; aperture, "
        + "{fstop|unrecorded}; shutter, {shutter|unrecorded}; ISO, {iso|unrecorded}."

    // MARK: - 积木

    private static func line(_ text: String, _ font: CollageFont, _ weight: CollageWeight, _ size: Double,
                             tracking: Double = 0, color: CollageColor = ink, italic: Bool = false,
                             indent: Double = 0, fit: Bool = false, textCase: CollageTextCase = .none,
                             effect: CollageTextEffect? = nil) -> CollageTextLine {
        var l = CollageTextLine(text, font: font, weight: weight, size: size, tracking: tracking, color: color,
                                italic: italic, indent: indent, effect: effect)
        l.fitWidth = fit
        l.textCase = textCase
        return l
    }

    private static func block(_ lines: [CollageTextLine], vertical: Bool = false, alignH: CollageAlign = .leading,
                              alignV: CollageAlign = .leading, spacing: Double = 0.35,
                              rule: CollageRuleStyle? = nil, body: CollageBody? = nil) -> CollageText {
        var t = CollageText(lines: lines, vertical: vertical, alignH: alignH, alignV: alignV)
        t.lineSpacing = spacing
        if let rule {
            t.rule = true
            t.ruleStyle = rule
        }
        t.body = body
        return t
    }

    private static func column(_ text: String, font: CollageFont, size: Double, leading: Double, indent: Double,
                               justified: Bool = true, vertical: Bool = false,
                               traditional: Bool = false) -> CollageBody {
        var b = CollageBody(text: text, columns: 1)
        b.font = font
        b.size = size
        b.leading = leading
        b.firstLineIndent = indent
        b.justified = justified
        b.color = ink
        b.vertical = vertical
        b.traditional = traditional
        return b
    }

    private static func photo(_ role: CollageRole = .support, framing: CollageFraming = .auto) -> CollageNode {
        var cell = CollageCell.photo(nil, role: role)
        cell.framing = framing
        return .leaf(cell)
    }

    /// 照片 + 下面一行图说（图说用和正文不同的字：楷体 / 斜体，齐照片左边）。切分比例都在 0.04…0.96 里（排版和
    /// 解码都收在这个范围：写 0.962 存盘再读回来就成了 0.96）。
    private static func captioned(_ node: CollageNode, _ caption: CollageText, share: Double) -> CollageNode {
        CollageTemplates.col(share, node, CollageTemplates.text(caption))
    }

    private static func halftone(_ screen: CollageScreen, pitch: Double, sharpness: Double = 0.7,
                                 gain: Double) -> CollageHalftone {
        var h = CollageHalftone(screen: screen, pitch: pitch)
        h.angle = 45
        h.sharpness = sharpness
        h.ink = ink
        h.gain = gain
        return h
    }

    /// 报纸的样式：纸色、纸纹、网点、纸纹压照片。网点开着时色调不用「报纸」（会和网点的压范围叠两次，整张发灰，
    /// S4a §2.1），网点自己就去色了；实测新闻纸（两个老报纸）配「高反差」：纸本来就灰，不拉开的话照片灰在灰上。
    /// 不统一色调（每张照片照它自己的明暗印）。小格照旧收成半身（tightSmallCells）：报纸上的小图人太小，加了网
    /// 就只剩一团点。
    private static func paperStyle(_ background: CollageColor, margin: Double, gutter: Double, grain: Double,
                                   screen: CollageHalftone, paperOver: Double,
                                   look: CollageLook = .none, lookStrength: Double = 0.7) -> CollageStyle {
        CollageStyles.make { s in
            s.background = background
            s.look = look
            if look != .none { s.lookStrength = lookStrength }
            s.margin = margin
            s.gutter = gutter
            s.grain = grain
            s.halftone = screen
            s.paperOverPhotos = paperOver
        }
    }

    // MARK: - 今日头版（中文现代横排）

    /// 「报纸」预设就是这一套：米色纸、圆点 45°、点距 4.5‰（1440 宽约 6.5 像素，R5「可见」档；0.4 倍预览不到 3 像素，
    /// 只调影调不出点）、网点增大三成半（社交图上按一半太闷）、纸纹压照片三成。
    static let frontStyle = paperStyle(paper, margin: 0.045, gutter: 0.014, grain: 0.18,
                                       screen: halftone(.dot, pitch: 0.0045, gain: 0.35), paperOver: 0.3)

    private static func frontCaption(_ s: String) -> CollageText {
        block([line(s, .kaiti, .regular, 0.0135, tracking: 0.05)])
    }

    /// 5 栏网格（版心 1310.4：一栏 245.95、栏距 20.16）：报头（左上红色宋体 {title}，下面一行拼音刊名）+ 报眼细线框
    /// （星期、农历、干支）→ 日期栏 + 粗细双线 → 通栏一行标题（5 栏 = 1 行，Harrower）→ 主图 4 栏 + 右边 1 栏
    /// 竖幅图二 → 通栏 5 栏「本报讯」（平衡分栏、四成墨的栏线，R5 §2）→ 下排 2 栏 | 3 栏两张。切分比例按栏算准
    /// （4 栏 = (4×245.95 + 3×20.16) / (1310.4 − 20.16) = 0.809，2 栏 = 0.397），右栏的边、下排的缝、正文的栏都落在栏线上。
    static let front: CollageTemplate = {
        // 报头下面那行拼音刊名：刊头和标题是同一串字（西文标题没填刊头）时不印（onlyWhenFilled → {masthead_alt}），
        // 不在「Spring Portraits」下面再印一行「SPRING PORTRAITS」。
        var pinyin = line("{masthead}", .didot, .regular, 0.012, tracking: 0.7)
        pinyin.onlyWhenFilled = "masthead_alt"
        let masthead = block([line("{title}", .songti, .black, 0.16, tracking: 0.05, color: red, fit: true), pinyin],
                             alignV: .center, spacing: 0.08)
        let ear = block([line("{weekday_cn}", .songti, .bold, 0.033, tracking: 0.2),
                         line("[[农历{lunar}]]", .songti, .regular, 0.019, tracking: 0.12),
                         line("[[{ganzhi}年]]", .songti, .regular, 0.016, tracking: 0.3)],
                        alignH: .center, alignV: .center, spacing: 0.45, rule: .box)
        let dateline = block([line("[[{date_cn_full}　{weekday_cn}　农历{lunar}　]]第{issue_n}期", .songti, .regular, 0.0165,
                                   tracking: 0.06)], rule: .thickThin)
        let headline = block([line("[[影像里的{month_cn}{day_cn}||影像纪事]]", .songti, .black, 0.064, tracking: 0.02)],
                             alignV: .center)
        // 正文 5 栏：栏距 = 页面的栏距（20.16 / 24.48 = 0.8235 em），每栏都对着上面网格的一栏。机型、f/5.0、1/2000 的
        // 连字符和斜杠在占位符展开时夹了不断行符（bodyText），不会断成「X-」「T50」。不用 CoreText 的两端对齐：它在
        // 窄栏里把字距摊进西文里（「X - T 5 0」），改成字号 = 栏宽 / 10 再略小一点（1440 宽 24.48 px，10 个字
        // 244.8 px < 栏宽 245.95）：全是汉字的行左右都齐，只有带西文、数字的行右边差不到一个字。
        var copy = column(frontCopy, font: .songti, size: 0.017, leading: 1.6, indent: 2, justified: false)
        copy.columns = 5
        copy.gap = 0.8235
        copy.columnRule = true
        copy.balanced = true
        let lead = block([], body: copy)
        // 图二：右边一栏的竖幅，和主图一样高、收成半身：一栏宽（246 px）的格子里全身人头顶到眼睛只有 35–41 px，
        // 加网后才五六条网线，脸是一团点；半身 103 px，认得出脸。窄栏切掉两边胳膊是报纸常见的裁法。
        // 不用 .auto：它按小格隔一个收半身，图二算进去以后图四会翻成全身。图说格和图一的一样高，
        // 「▲ 图一」「▲ 图二」在一条线上。
        let heroRow = CollageTemplates.row(0.809, captioned(photo(.hero), frontCaption("▲ 图一"), share: 0.956),
                                           captioned(photo(framing: .half), frontCaption("▲ 图二"), share: 0.956))
        // 下排小图收成半身（加了网的小格里全身人只剩一团点）。
        let bottom = CollageTemplates.row(0.397, captioned(photo(framing: .half), frontCaption("▲ 图三"), share: 0.92),
                                          captioned(photo(), frontCaption("▲ 图四"), share: 0.92))
        // 正文格 = 3 行（1.6 倍行高 117.5 px）再留一点：最长的数据每栏 3 行，一般的数据每栏 2 行。
        let story = CollageTemplates.col(0.232, CollageTemplates.text(lead), bottom)
        let flag = CollageTemplates.row(0.76, CollageTemplates.text(masthead), CollageTemplates.text(ear))
        let rest = CollageTemplates.col(0.082, CollageTemplates.text(headline), CollageTemplates.col(0.56, heroRow, story))
        let root = CollageTemplates.col(0.15, flag, CollageTemplates.col(0.04, CollageTemplates.text(dateline), rest))
        return CollageTemplate(name: "报纸风 · 今日头版", root: root, style: frontStyle, canvas: CollageCanvas.social[0],
                               fitAspects: false, builtin: true, category: "报纸风")
    }()

    // MARK: - 民国竖排

    /// 实测新闻纸、线网（CILineScreen，45°，像铜版雕刻）、纸纹重一点。线网整片看比圆点网暗：网点增大只给两成、
    /// 高反差 0.6，亮的地方露出纸来。线距、线边都不收紧：5 px 的线、0.8 以上的硬边在手机上缩小看（0.75、0.67 倍
    /// 缩图实测）会起一道道摩尔纹，6.5 px、0.75 不会。
    static let minguoStyle = paperStyle(newsprint, margin: 0.05, gutter: 0.016, grain: 0.3,
                                        screen: halftone(.line, pitch: 0.0045, sharpness: 0.75, gain: 0.2),
                                        paperOver: 0.35, look: .contrastMono, lookStrength: 0.6)

    /// 1948 年那种：顶上一块墨底反白的横排标题条（右起，{title} 转繁体再倒过来排）→ 干支日期一行（也右起）+
    /// 粗细双线 → 通栏线网大图 → 下面左边一张图，右边一篇竖排文章：魏碑标题贴右边、旁边一列日期、粗细双竖线，
    /// 正文竖排从右往左一列列读。正文只有两句真话：文章格收窄到四成（照片六成），正文字号放大到 0.0215（1440 宽
    /// 31 px，一列 20 个字，第二句一列排得下，不剩「幀。」一个字落单）：一般的数据排 3 列、最长的数据 4 列，
    /// 占正文那块地方的大半，不会只在右边排几列、左边空一大片。
    static let minguo: CollageTemplate = {
        var plate = CollageTextEffect()
        plate.band = 1
        plate.bandColor = ink
        plate.bandRound = 0
        let band = block([line("{title}", .weibei, .bold, 0.11, tracking: 0.35, color: paper, textCase: .traditionalRTL,
                               effect: plate)], alignH: .center, alignV: .center)
        let folio = block([line("[[{ganzhi}年{lunar}　]]第{issue_cn}期", .songtiTC, .regular, 0.017, tracking: 0.12,
                                textCase: .traditionalRTL)], alignH: .center, rule: .thickThin)
        let article = block([line("影像紀事", .weibei, .bold, 0.058, tracking: 0.05, textCase: .traditional),
                             line("[[{weekday_cn}　公曆{date_cn_full}]]", .songtiTC, .regular, 0.016, tracking: 0.05,
                                  indent: 1.2, textCase: .traditional)],
                            vertical: true, alignH: .trailing, spacing: 0.5, rule: .thickThin,
                            body: column(minguoCopy, font: .songtiTC, size: 0.0215, leading: 1.55, indent: 2,
                                         vertical: true, traditional: true))
        // 下面那张收成特写（上面通栏是远景，下面一张近的）：线网的线距一定，全身照里脸只有五六条线宽、半身也才十几条，
        // 特写才认得出是谁（近景原片收特写也不切头，photot 的近景实测）。
        let lower = CollageTemplates.row(0.6, photo(framing: .close), CollageTemplates.text(article))
        let main = CollageTemplates.col(0.56, photo(.hero), lower)
        let root = CollageTemplates.col(0.13, CollageTemplates.text(band),
                                        CollageTemplates.col(0.04, CollageTemplates.text(folio), main))
        return CollageTemplate(name: "报纸风 · 民国竖排", root: root, style: minguoStyle, canvas: CollageCanvas.social[0],
                               fitAspects: false, builtin: true, category: "报纸风")
    }()

    // MARK: - 英文复古

    static let englishStyle = paperStyle(newsprint, margin: 0.04, gutter: 0.012, grain: 0.25,
                                         screen: halftone(.dot, pitch: 0.0042, gain: 0.4), paperOver: 0.3,
                                         look: .contrastMono)

    private static func plate(_ s: String) -> CollageText {
        block([line(s, .timesNewRoman, .regular, 0.012, tracking: 0.03, italic: true)])
    }

    /// 1912 年那种（R5 §2 实测）：哥特体刊头 {masthead}（内置 UnifrakturCook，首字母大写）居中 → 期号日期一行 +
    /// 粗细双线 → 7 栏网格（版心 1324.8：一栏 174.45、栏距 17.28）：主图 5 栏，右边 2 栏是引题 + 窄体大写的叠题 +
    /// 一条通栏短线 + Georgia 正文 + 一张小图，下排 2 | 3 | 2 栏三张。图说斜体 Plate I.…V.。不印卷号（VOL. 是编的）。
    static let english: CollageTemplate = {
        let flag = block([line("{masthead}", .fraktur, .bold, 0.12, fit: true, textCase: .title)],
                         alignH: .center, alignV: .center)
        let folio = block([line("No. {issue_n}[[   ·   {weekday_en}, {month_en} {day_n}, {year}]]", .georgia, .regular,
                                0.0145, tracking: 0.12)], alignH: .center, rule: .thickThin)
        // 叠题：小字引题在上，窄体大写两行，下面一条通栏短线（线前后的空按第一行的字号算：引题在上，线贴着叠题）。
        let deck = block([line("A Page of Photographs", .georgia, .regular, 0.019, italic: true),
                          line("PICTURES", .dinCondensed, .bold, 0.052, tracking: 0.04),
                          line("OF THE DAY", .dinCondensed, .bold, 0.052, tracking: 0.04)],
                         alignH: .center, alignV: .trailing, spacing: 0.25, rule: .full)
        // 正文单独一格：窄栏不两端对齐（没有断字，两端对齐会拉出一道道白河）；格高 = 最长的数据 5 行再留小半行。
        let story = block([], body: column(englishCopy, font: .georgia, size: 0.0135, leading: 1.42, indent: 1.2,
                                           justified: false))
        let plate2 = captioned(photo(framing: .half), plate("Plate II."), share: 0.924)
        // 叠题格正好装下叠题（引题顶齐主图上沿）；正文格 = 5 行（最长的数据也是 5 行）再留小半行。
        let side = CollageTemplates.col(0.257, CollageTemplates.text(deck),
                                        CollageTemplates.col(0.23, CollageTemplates.text(story), plate2))
        let top = CollageTemplates.row(0.72, captioned(photo(.hero), plate("Plate I."), share: 0.96), side)
        // 下排 2 | 3 | 2 栏：3 栏 = (3×174.45 + 2×17.28) / (941.3 − 17.28) = 0.604，Plate V 的左边和上面 Plate II 对齐。
        let bottom = CollageTemplates.row(0.28, captioned(photo(framing: .half), plate("Plate III."), share: 0.92),
                                          CollageTemplates.row(0.604, captioned(photo(framing: .half), plate("Plate IV."),
                                                                                share: 0.92),
                                                               captioned(photo(framing: .half), plate("Plate V."),
                                                                         share: 0.92)))
        let root = CollageTemplates.col(0.115, CollageTemplates.text(flag),
                                        CollageTemplates.col(0.04, CollageTemplates.text(folio),
                                                             CollageTemplates.col(0.62, top, bottom)))
        return CollageTemplate(name: "报纸风 · 英文复古", root: root, style: englishStyle, canvas: CollageCanvas.social[0],
                               fitAspects: false, builtin: true, category: "报纸风")
    }()

    // MARK: - 大字报

    /// 米色纸、粗网点（7‰，1440 宽约 10 像素：0.4 倍预览里也出点，波普感）、硬一点的点边。
    static let posterStyle = paperStyle(paper, margin: 0.05, gutter: 0.02, grain: 0.25,
                                        screen: halftone(.dot, pitch: 0.007, sharpness: 0.85, gain: 0.35),
                                        paperOver: 0.35)

    /// 左边一列印出来的红竖排大字 {title}（粗宋，铺满这一栏的高），右边半身照，底下一行铺满宽的黑色大日期、
    /// 一行红色星期农历期号。只有标题和日期，不印标语口号。标题要是中文：竖排里西文一个字母一个字母立着排
    /// （S2 的竖排做法），「Spring Portraits」会成一溜小字母，大字就没了 —— 西文标题请用别的模板（报告「已知的弱点」）。
    static let poster: CollageTemplate = {
        let title = block([line("{title}", .songti, .black, 0.3, color: red, fit: true)], vertical: true,
                          alignH: .center, alignV: .center)
        let date = block([line("{date_cn_full}", .songti, .black, 0.06, tracking: 0.02, fit: true),
                          line("[[{weekday_cn}　农历{lunar}　]]第{issue_n}期", .songti, .bold, 0.03, tracking: 0.15,
                               color: red)],
                         alignV: .center, spacing: 0.3)
        let top = CollageTemplates.row(0.3, CollageTemplates.text(title), photo(.hero, framing: .half))
        let root = CollageTemplates.col(0.8, top, CollageTemplates.text(date))
        return CollageTemplate(name: "报纸风 · 大字报", root: root, style: posterStyle, canvas: CollageCanvas.social[0],
                               fitAspects: false, builtin: true, category: "报纸风")
    }()

    static let templates: [CollageTemplate] = [front, minguo, english, poster]

    /// 「报纸」：今日头版那一套纸和网点，套在任何版式上。
    static let presets: [CollageStyles.Preset] = [
        CollageStyles.Preset(key: "newspaper", name: "报纸", style: frontStyle),
    ]
}
