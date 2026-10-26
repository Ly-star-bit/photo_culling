import Foundation

/// 「留白杂志」风格：大留白、细衬线、四边边距。规格见 reports/杂志风格调研_2026-10-23/DESIGN.md §3 K3。
///
/// 注册钩子：templates 按 CollageTemplates.builtin 里的位置进模板库（category 写「留白杂志」）；presets 拼在
/// CollageStyles.all 末尾。模板名全库唯一，模板名、分类名都不能包含别的分类名（--template-sheet --only、
/// 门禁按「包含」匹配）。积木用 CollageTemplates.photo / row / col / text，样式用 CollageStyles.make { s in … } ——
/// 这里的 static let 里别读 CollageStyles.all / preset(…) 和 CollageTemplates.builtin / find(…)：它们正拼着这两个
/// 数组，回头读自己会在初始化时卡死。只改这个文件（和同前缀的新文件），地基要改的在交付报告里单独列出。
/// 不预置任何真实刊名、胶片 / 滤镜品牌名（DESIGN.md §0.4）。
///
/// 五种页型照 R4 §A2 实测的比例（页宽 W、页高 H；画布是小红书 3:4，1440×1920，短边 S = W）：
/// 悬浮单图（图宽 50%W，订口侧 28.7%、切口侧 21%，上下各约 22%H）、白边封面（上白边 11%H 放刊名、宽 73%W，
/// 照片 75%H 左右满版，下白边 14%H 三栏小字）、小图标题（41%W × 41%H 贴订口上角，图下通栏细线，标题、页底导语）、
/// 巨字开篇（首字母占照片区大半高，人站在字前面）、窄栏文字（栏从切口量起 47.8%W 处开始、栏宽 40%W，
/// 标题块落在约 75%H 的黄金分割点附近）。单页没有订口：字靠哪边，哪边就当订口。
/// 字号照 R4 §A5 的社交画布下限：要读的字 ≥ 0.028 S，标题 ≥ 0.06 S，只起装饰作用的加字距小字 ≥ 0.024 S
/// （--minimal-selftest 按渲染出来的实际字号核对，见 CollageStyleMinimalSelfTest.swift）。
/// 跟着照片走的信息（月份年份、日期、农历、机身参数）都写成可省略的 {key|}：没有 EXIF、没有拍摄时间时那一段连同
/// 「 · 」不印（CollageTypeset.fillDroppingEmpty 只认 {key|}，别的模板的字照旧）。
/// 焦距印镜头上的实际焦距 {focal_mm|}（{focal} 是 35mm 等效，17-70 的镜头会印成 92mm）；英文日期的日子用不补零的 {day_n|}。
enum CollageStyleMinimal {
    static let templates: [CollageTemplate] = [floating, whiteBandCover, smallPhotoTitle, giantInitial, narrowColumn]

    static let presets: [CollageStyles.Preset] = [
        CollageStyles.Preset(key: "minimal", name: "留白杂志", style: presetStyle),
    ]

    /// 模板库里的分类名（自测核对模板名、分类名不撞别的分类）。
    static let category = "留白杂志"

    // MARK: - 颜色、字号

    /// 暖象牙纸（R4 §A3 的建议值；和默认的纸白同一个色）、暖黑墨、三级灰（一级就是墨）、一种低饱和的强调色
    /// （只上栏目小标签：一页最多一处）。
    static let paper = CollageColor(hex: 0xF4F1EA)
    static let ink = CollageColor.ink
    static let grey = CollageColor(hex: 0x7A756E)
    static let faint = CollageColor(hex: 0xA59F96)
    static let accent = CollageColor(hex: 0x8C6A52)

    /// 标题（社交画布下限 0.06 S）、要读的字（下限 0.028 S）、加字距的装饰小字（下限 0.024 S）。
    /// 印刷画布照样用这几档：比杂志原样大，但比例不变（模板不按画布换字号）。
    static let titleSize = 0.062
    static let readSize = 0.029
    static let labelSize = 0.025

    // MARK: - 字

    /// 加字距的无衬线小字（Avenir Next Regular；细体是 UltraLight，加了字距的小字会细得发虚）。
    static func label(_ s: String, color: CollageColor = grey, size: Double = labelSize) -> CollageTextLine {
        var l = CollageTextLine(s, font: .avenir, weight: .regular, size: size, tracking: 0.22, color: color)
        l.textCase = .upper
        return l
    }

    /// 标题：中文细宋（STSongti-SC-Light；西文字形也在里面，中英混排不跳字体）。
    static func title(_ s: String, size: Double = titleSize) -> CollageTextLine {
        CollageTextLine(s, font: .songti, weight: .light, size: size, tracking: 0.04, color: ink)
    }

    /// 要读的中文小字（导语、图注）：细宋。
    static func reading(_ s: String, color: CollageColor = ink) -> CollageTextLine {
        CollageTextLine(s, font: .songti, weight: .light, size: readSize, tracking: 0.05, color: color)
    }

    /// 要读的西文小字：细衬线斜体（Athelas，没有退 Charter，再没有退 New York）。
    static func serifItalic(_ s: String, color: CollageColor = ink, size: Double = readSize) -> CollageTextLine {
        CollageTextLine(s, font: .athelas, weight: .regular, size: size, tracking: 0.02, color: color, italic: true)
    }

    static func block(_ lines: [CollageTextLine], alignH: CollageAlign = .leading, alignV: CollageAlign = .leading,
                      spacing: Double = 0.45) -> CollageText {
        var t = CollageText(lines: lines, vertical: false, alignH: alignH, alignV: alignV)
        t.lineSpacing = spacing
        return t
    }

    /// 页脚（刊名、页码）：文字图层，放在边距里（切分树管不到边距）。edgeX = 字块贴住的那条边（左齐 = 左边、
    /// 右齐 = 右边，相对画布宽），cy = 字块中心（相对画布高）；字号是加字距的装饰小字。
    /// 图层的宽高按画布短边算：竖版画布宽 = 短边，所以「往里半个宽」直接是 width / 2。
    /// width = 这一行能占多宽：给到它底下那一栏的宽（字放不下才整行缩，栏宽够的话长刊头也是原字号；
    /// 字一样宽时贴着 edgeX 排，和宽度无关，出图不变）。
    static func footer(_ s: String, edgeX: Double, cy: Double, align: CollageAlign, width: Double = 0.34) -> CollageItem {
        var item = CollageItem(kind: .text)
        item.text = block([label(s, color: faint)], alignH: align, alignV: .center)
        let half: Double = width / 2
        item.cx = align == .trailing ? edgeX - half : edgeX + half
        item.cy = cy
        item.width = width
        item.height = 0.05
        return item
    }

    // MARK: - 样式

    /// 模板共用的底：暖象牙纸、哑光色调（不提亮中间调、保留暗部）、统一到主图一点、无边框无投影；
    /// 边距由各模板自己定（四边边距或切分树里的留白格）。
    static func pageStyle(insets: CollageInsets? = nil, gutter: Double = 0) -> CollageStyle {
        CollageStyles.make { s in
            s.background = paper
            s.margin = 0
            s.gutter = gutter
            s.insets = insets
            s.look = .muted
            s.lookStrength = 0.85
            s.harmonize = 0.35
        }
    }

    /// 风格预设「留白杂志」：任何版式套上都像一本留白杂志的内页 —— 四边不一样的边距（上 8%、下 12% 的
    /// 底边加重，订口侧比切口侧宽），缝宽一点，暖象牙纸、哑光色调。
    static let presetStyle: CollageStyle = pageStyle(
        insets: CollageInsets(top: 0.08, bottom: 0.12, inner: 0.10, outer: 0.07), gutter: 0.026)

    private static let xhs = CollageCanvas.social[0]

    /// 切分比例按 3:4 画布上的像素目标算（第一块占这一段的多少）。
    private static func split(_ first: Double, of total: Double) -> Double { first / total }

    // MARK: - 模板

    /// 悬浮单图：竖图照 R4 —— 50%W × 2:3（720×1080），订口（左）28.7%、切口（右）21.3%，上下各 420px（21.9%H，
    /// R4 量的是 23%：2:3 的照片比 54%H 高一点）。照片完整显示（不裁）、宽跟照片比例走（贴合原比例），左沿不动：
    /// 横图不缩在竖图那个框里（那样只有 720×480、一页 12% 是照片），往切口那边长到 883 宽（排到 86% 那条线，
    /// 3:2 成 883×589，切口还剩 10%W），在 1080 高的框里上下居中 —— 照 R4「垂直居中、偏向切口」。
    /// 上边距里一块小标题和照片左沿对齐；页脚「刊名 · 页码」一行也贴照片左沿 —— 横图往切口那边长，右沿不固定，
    /// 页码放右沿就对不上任何东西，左沿是竖图、横图共用的那条线（标题、照片、页脚一条轴）。
    static let floating: CollageTemplate = {
        // 上边距 420px 里：小标签（字底落在 165）、标题各占一格 —— 用户填的长标题放不下时只缩标题，不连累小标签
        // 缩到看不清（drawShort 是整块一起缩的）。标题格右边到切口边距（101px）为止。
        let kicker = CollageTemplates.text(block([label("{month_en|} · {year|}")], alignV: .trailing))
        let caption = CollageTemplates.col(split(165, of: 420), kicker, CollageTemplates.text(block([title("{title}")])))
        let top = CollageTemplates.row(0.287, CollageTemplates.empty(),
                                       CollageTemplates.row(split(926, of: 1027), caption, CollageTemplates.empty()))
        // 贴合原比例按「照片 | 纸」那一刀解：照片高 1080 不动，宽拿它自然的宽（高 × 比例），封顶这一段（订口右边
        // 1027px）的 86%（CollageLayout.refit）。竖图 2:3 → 720，和没贴合的模板一样；横图要 1620 → 883，格子
        // 883×1080，照片完整显示成 883×589、上下居中。也只有这一刀能动：竖着解的话框宽定死，横图又是 720 宽。
        let framed = CollageTemplates.row(split(720, of: 1027), CollageTemplates.photo(.hero, contain: true),
                                          CollageTemplates.empty())
        let photoRow = CollageTemplates.row(0.287, CollageTemplates.empty(), framed)
        let body = CollageTemplates.col(split(1080, of: 1500), photoRow, CollageTemplates.empty())
        let root = CollageTemplates.col(split(420, of: 1920), top, body)
        let photoLeft: Double = 413.0 / 1440
        // 页脚从照片左沿排到切口边距（1339px）：0.34 宽的话「SPRING AFTERNOON IN SUZHOU · 01」这种西文标题
        // 转出来的刊头缩到 0.013 S（手机上 5pt）。
        let footerWidth: Double = (1339.0 - 413.0) / 1440
        return CollageTemplate(
            name: "留白杂志 · 悬浮单图", root: root, style: pageStyle(), canvas: xhs,
            fitAspects: true, builtin: true, category: category,
            items: [footer("{masthead} · {no}", edgeX: photoLeft, cy: 0.954, align: .leading, width: footerWidth)])
    }()

    /// 白边封面：上白边 11%H 放刊名（细衬线大写加字距，铺满 73%W 的字块，白边的高把字高限在约 6%H），照片左右
    /// 满版占 75%H，下白边 14%H：一行期号月份，下面三栏「加字距小标签 + 一行值」。三栏写的都是真的：标题、
    /// 机身、拍摄日期（镜头名太长，窄栏里会把整块字缩到看不清，不放；值是空的那一栏小标签也不印）。
    /// 三个值同一款细宋、同一字号 —— 标题默认是中文，
    /// Athelas 斜体没有汉字；字体不一样基线就差七八个像素（R4 的「斜体小字」这里不用）。值的格子和字框一样高、
    /// 底对齐：用户填的长标题缩小了，字底还和另外两栏差不多齐（顶对齐会往上漂十来个像素）。
    /// 期号月份那行用加字距的 Avenir（和三栏的小标签一套）：Athelas 只有旧式数字（没有 Number Case 特性），
    /// 「ISSUE 01」排出来像「ISSUE oI」、2026 沉到大写字母下面，和下面细宋的 2026.03.21 两种数字混着。
    /// 刊头仍用 Athelas（默认刊头是拼音，没有数字；用户刊头里写了数字就是旧式数字 —— 已知弱点）。
    /// 下白边里三行字（期号一行、小标签、值）整块上下居中：离照片和离裁切边都是 50px 上下。
    static let whiteBandCover: CollageTemplate = {
        var mastLine = CollageTextLine("{masthead}", font: .athelas, weight: .regular, size: 0.13, tracking: 0.14,
                                       color: ink)
        mastLine.fitWidth = true
        let mast = block([mastLine], alignH: .center, alignV: .center)
        let mastInner = CollageTemplates.row(split(1051, of: 1246), CollageTemplates.text(mast), CollageTemplates.empty())
        let mastRow = CollageTemplates.row(0.135, CollageTemplates.empty(), mastInner)

        // 期号月份比三栏的小标签大一档、用墨色：是这一条白边的头一行。
        let headSize = 0.027
        let head = block([label("{month_en|} {year|} · ISSUE {issue}", color: ink, size: headSize)],
                         alignH: .center, alignV: .trailing)
        // 一栏 = 小标签（字底贴这一栏上面 73px 处）+ 一行值，各占一格：标题填得很长时只缩值那一行，小标签不跟着缩。
        // 值的格子 60px（细宋 0.029 的字框 58.5px），底对齐，下面一格空着。
        // 值是空的（没有 EXIF 的照片没有机身、没有拍摄时间）小标签也不印（onlyWhenFilled，三栏同一个规则）：
        // 不在空格子上面留一个 CAMERA / DATE。剩下的栏不挪位置。
        func column(_ name: String, key: String) -> CollageNode {
            let value = reading("{\(key)}")
            var tag = label(name)
            tag.onlyWhenFilled = key
            let valueRow = CollageTemplates.col(split(60, of: 102),
                                                CollageTemplates.text(block([value], alignH: .center, alignV: .trailing)),
                                                CollageTemplates.empty())
            return CollageTemplates.col(split(73, of: 175),
                                        CollageTemplates.text(block([tag], alignH: .center, alignV: .trailing)),
                                        valueRow)
        }
        let three = CollageTemplates.row(0.3334, column("PORTRAIT", key: "title"),
                                         CollageTemplates.row(0.5, column("CAMERA", key: "model"),
                                                              column("DATE", key: "date")))
        let threeRow = CollageTemplates.row(0.07, CollageTemplates.empty(),
                                            CollageTemplates.row(split(1238, of: 1339), three, CollageTemplates.empty()))
        // 下白边 269px：期号那一行的格子 94（字底贴格底），下面 175 是三栏。
        let band = CollageTemplates.col(split(94, of: 269), CollageTemplates.text(head), threeRow)
        let lower = CollageTemplates.col(split(1440, of: 1709), CollageTemplates.photo(.hero), band)
        let root = CollageTemplates.col(split(211, of: 1920), mastRow, lower)
        return CollageTemplate(
            name: "留白杂志 · 白边封面", root: root, style: pageStyle(), canvas: xhs,
            fitAspects: false, builtin: true, category: category)
    }()

    /// 小图标题：照片贴订口（左）上角，高 41%H、宽按照片原比例（竖图约 36%W，横图最宽到排版区的 86%）；
    /// 图下一行加字距小标签，下面一条和排版区同宽的细线；细宋标题；页底两行导语：拍摄日期、星期、农历，
    /// 机身、焦距、光圈、快门、ISO —— 每一句都是这张照片的真信息。四边边距：订口 9.7%W、切口 7%W、上 7%H、下 6%H。
    /// 照片格「完整显示」：3:2 的横图比 86% 那条线宽，在 1031×785 的格子里显示成 1031×687（上下各 49px 纸），不裁 ——
    /// 裁的话取景要躲画边上的路人，预览（按缩放取整的格子）和导出的格子比例差一点点，躲没躲就会不一样。
    static let smallPhotoTitle: CollageTemplate = {
        var kicker = block([label("{month_en|} · {year|}", color: accent)], alignV: .trailing)
        kicker.rule = true
        kicker.ruleStyle = .underEachLine
        let lede = block([reading("{date_cn_full|} · {weekday_cn|} · 农历{lunar|}"),
                          reading("{model|} · {focal_mm|} · f/{fnumber|} · {shutter|}s · ISO {iso|}", color: grey)],
                         alignV: .trailing, spacing: 0.55)
        // 排版区 1199×1671（像素按 3:4 画布）：照片 785 高；小标签 100（字落在底下，上面留出和照片的间距）；
        // 标题 130、副标题 130（各占一格：长标题只缩标题）；剩下的导语贴底。
        let subtitle = CollageTemplates.text(block([reading("{subtitle}", color: grey)]))
        let lower = CollageTemplates.col(split(130, of: 786), CollageTemplates.text(block([title("{title}")])),
                                         CollageTemplates.col(split(130, of: 656), subtitle,
                                                              CollageTemplates.text(lede)))
        let text = CollageTemplates.col(split(100, of: 886), CollageTemplates.text(kicker), lower)
        let photoRow = CollageTemplates.row(0.6, CollageTemplates.photo(.hero, contain: true), CollageTemplates.empty())
        let root = CollageTemplates.col(split(785, of: 1671), photoRow, text)
        let insets = CollageInsets(top: 0.093, bottom: 0.08, inner: 0.097, outer: 0.07)
        return CollageTemplate(
            name: "留白杂志 · 小图标题", root: root, style: pageStyle(insets: insets), canvas: xhs,
            fitAspects: true, builtin: true, category: category)
    }()

    /// 巨字开篇：一个首字母（{initial} = 刊头的第一个字母：拾光 → SHIGUANG → S），细衬线、纸色，铺满宽度的行
    /// （最宽 55%；字号先按宽放大，再按行高收进照片区 —— 管住字号的是高：Athelas 一行连上下伸部约 1.12 em，
    /// 照片区 1398px 高、减去上下的边，字号到 1197px 为止，S 的大写字高只有 0.67 em ≈ 805px = 42%H。R4 的 60%H
    /// 是整页白纸上的首字母，要字出照片上沿才做得到），定在上方居中、在人后；照片用「封面」取景 ——
    /// 头顶压进字母上半截，人站在字前面。按「装饰大字」的规矩只限总遮挡（最多 33%，首末字母不单独管）：挡多了
    /// 先横向挪取景、再拉远；合影、认不出主体时退回人前并躲开头（S3 的退让链，原因在检视器里）。
    /// 照片四边留 6% 的纸，下面一块：小标签、细宋标题、一行日期。字后面不垫雾面（衬底 0）：留白杂志不要脏的那一块。
    /// 字色定死浅字（纸色）：自动深浅在亮天空、浅石桥上会翻成近黑的字。代价是字落在很白的底上（过曝的天、白墙）
    /// 时对比弱，那种照片在检视器里把字色换成深字。
    /// 封面取景最多拉近 1.6 倍（maxZoom）、人的边压利落（tightEdge）：不限的话全身照会被拉成半身（拉近四倍多），
    /// 1024 的主体蒙版跟着放大，软边里的天空、深色木构在纸色字上成了头外 15–25px 的一圈光晕，取景角上还会留一小截
    /// 亭子的木框。1.6 倍时全身照是七分身，头仍压在字的下半截；边按蒙版放大倍数收、软边压陡，光晕没有了。
    static let giantInitial: CollageTemplate = {
        var letter = CollageTextLine("{initial}", font: .athelas, weight: .regular, size: 0.9, color: paper)
        letter.fitWidth = true
        var overlay = CollageOverlay(text: block([letter], alignH: .center, alignV: .leading))
        overlay.anchor = .top
        overlay.inset = 0.02
        overlay.maxWidth = 0.55
        overlay.shadow = 0
        overlay.tone = .light
        overlay.layer = .behindSubject
        overlay.occlusionRule = .total
        overlay.maxOcclusion = 0.33
        overlay.maxZoom = 1.6
        overlay.tightEdge = true
        var cell = CollageCell.photo(nil, role: .hero)
        cell.framing = .cover
        cell.overlays = [overlay]
        // 照片下面 350px：小标签（字底落在 110，和照片空开 60px）、标题、日期各占一格（长标题只缩标题）。
        let kicker = CollageTemplates.text(block([label("{month_en|} · {year|}")], alignV: .trailing))
        let date = CollageTemplates.text(block([reading("{date_cn_full|} · {weekday_cn|}", color: grey)]))
        let heading = CollageTemplates.col(split(110, of: 350), kicker,
                                           CollageTemplates.col(split(148, of: 240),
                                                                CollageTemplates.text(block([title("{title}")])), date))
        let root = CollageTemplates.col(0.8, .leaf(cell), heading)
        let insets = CollageInsets(top: 0.06, bottom: 0.06, inner: 0.06, outer: 0.06)
        return CollageTemplate(
            name: "留白杂志 · 巨字开篇", root: root, style: pageStyle(insets: insets), canvas: xhs,
            fitAspects: false, builtin: true, category: category)
    }()

    /// 窄栏文字：照「左页」排（切口在左）。正文栏从切口量起 47.8%W 处开始、宽 40%W（右边留 12.2%W），贴顶；
    /// 正文默认是这张照片的拍摄手记，一句一行（日期、农历、干支纪年、星期，机身、焦距、光圈、快门、ISO，全是真的；
    /// 一句一行是为了窄栏里不在「二十一|日」「快|门」中间断行），右不齐；换成自己的一段话照样按栏排。
    /// 左半页下方一张照片（499×740，竖的 2:3，底边和标题块的底对齐），左上留白（R4 §A2「等于半页留空」）；
    /// 标题块贴着照片底边落在约 75%H（黄金分割点附近），和正文栏左沿对齐，下面一截文末短线。
    /// 左下角页脚刊名、右下角页码。
    /// 照片格比例固定（不贴合原比例）：横图按这个竖格裁（取景照常保脸、躲路人）。贴合的话横图只有 499×333、
    /// 缩在左下角，一页 85% 是空纸，像排坏了的页；左半页这一栏宽 587、和正文之间要留空，横图怎么贴合都大不过
    /// 505 宽。要整张横图：检视器里点「贴合原比例」（回到那张小横图），或者换「小图标题」「悬浮单图」。
    static let narrowColumn: CollageTemplate = {
        let lines = ["{date_cn_full|}", "农历{lunar|} · {ganzhi|}年", "{weekday_cn|}", "",
                     "{model|} · {focal_mm|}", "f/{fnumber|} · {shutter|} 秒 · ISO {iso|}"]
        var notes = CollageBody(text: lines.joined(separator: "\n"), columns: 1)
        notes.justified = false
        notes.font = .songti
        notes.weight = .light
        notes.size = readSize
        notes.leading = 1.85
        notes.firstLineIndent = 0
        notes.color = ink
        var column = CollageText(lines: [], vertical: false, alignH: .leading, alignV: .leading)
        column.body = notes
        var dated = block([label("{month_en|} {day_n|}, {year|}")], alignV: .trailing)
        dated.rule = true
        dated.ruleStyle = .short
        // 标题块：斜体小字、标题、日期 + 文末短线各占一格（长标题只缩标题），日期那格贴底、和照片底边齐。
        let notesKicker = CollageTemplates.text(block([serifItalic("Notes", color: grey)], alignV: .trailing))
        let heading = CollageTemplates.col(split(444, of: 664), notesKicker,
                                           CollageTemplates.col(split(130, of: 220),
                                                                CollageTemplates.text(block([title("{title}")])),
                                                                CollageTemplates.text(dated)))
        // 排版区 1163×1564（像素按 3:4 画布）：左半 587 宽，下面 860 高里放照片（照片 499×740：占 85% 宽、贴底，
        // 和正文栏之间空 88px）；右栏 576 宽：正文 900 高，下面一截标题块贴底（底边和照片齐）。
        // 页脚贴排版区的左右两沿（照片左沿、正文栏右沿），离照片底 100px 上下。
        let photoCol = CollageTemplates.col(split(120, of: 860), CollageTemplates.empty(), CollageTemplates.photo(.hero))
        let lowerLeft = CollageTemplates.row(0.85, photoCol, CollageTemplates.empty())
        let left = CollageTemplates.col(split(704, of: 1564), CollageTemplates.empty(), lowerLeft)
        let right = CollageTemplates.col(split(900, of: 1564), CollageTemplates.text(column), heading)
        let root = CollageTemplates.row(split(587, of: 1163), left, right)
        let insets = CollageInsets(top: 0.107, bottom: 0.14, inner: 0.07, outer: 0.122)
        // 左下的刊名页脚排到右下页码前面（排版区 0.808 宽，留 0.12 给两位页码和一段空）：长刊头不缩到看不清。
        let mastheadFooter: Double = 0.878 - 0.07 - 0.12
        return CollageTemplate(
            name: "留白杂志 · 窄栏文字", root: root, style: pageStyle(insets: insets), canvas: xhs,
            fitAspects: false, builtin: true, category: category,
            items: [footer("{masthead}", edgeX: 0.07, cy: 0.958, align: .leading, width: mastheadFooter),
                    footer("{no}", edgeX: 0.878, cy: 0.958, align: .trailing)])
    }()
}
