import Foundation
import CoreText

/// 「瑞士网格」风格：栅格、巨字、高反差黑白。规格见 reports/杂志风格调研_2026-10-23/DESIGN.md §3 K5，
/// 栅格公式照 R4 §B3（Grid）。
///
/// 注册钩子：templates 按 CollageTemplates.builtin 里的位置进模板库（category 写「瑞士网格」）；presets 拼在
/// CollageStyles.all 末尾。模板名全库唯一，模板名、分类名都不能包含别的分类名（--template-sheet --only、
/// 门禁按「包含」匹配）。积木用 CollageTemplates.photo / row / col / text，样式用 CollageStyles.make { s in … } ——
/// 这里的 static let 里别读 CollageStyles.all / preset(…) 和 CollageTemplates.builtin / find(…)：它们正拼着这两个
/// 数组，回头读自己会在初始化时卡死。只改这个文件（和同前缀的新文件），地基要改的在交付报告里单独列出。
/// 不预置任何真实刊名、胶片 / 滤镜品牌名（DESIGN.md §0.4）。默认字只用占位符（日期、刊头、EXIF 的机身 / 焦距 /
/// 光圈 / 快门 / ISO）和几个通用英文词：不用 {make} / {brand}（会展开成相机厂牌）；也不用 {lens}（副厂镜头的型号串
/// 很长，小写之后像乱码，还会把整栏字挤小）。EXIF、日期都包在 [[…]] 里（CollageTypeset.fill：里面的占位符是空的
/// 整段不印）：没有 EXIF、没有拍摄时间的照片（截图、微信转过的图）上不留「f/ · s · iso」「, 」这种残渣。
/// 文字格都设 paperTone：套了别的样式、进了相册（整本的纸色），白字落到浅纸上会翻成近黑。
///
/// 规矩（DESIGN §3 K5）：6 栏（3:4）/ 4 栏（1:1），边距 5%W，基线 = 小字行距，格高吸附整数行；≤ 3 种字号，
/// 大字是小字的 7–18 倍；默认小写、左齐右不齐；照片高反差黑白（contrastMono）；一种强调色，只上字；每行下细线。
enum CollageStyleSwiss {

    static let category = "瑞士网格"

    // MARK: - 颜色（R4 §B3：纸 #F2F1EC、墨 #111111，强调色只取一种）

    static let paper = CollageColor(hex: 0xF2F1EC)
    static let ink = CollageColor(hex: 0x111111)
    /// 印刷红（默认，浅纸上的小字 4.4:1）/ 橙红（取自 Weniger Lärm 的色相；浅纸上只有 3.2:1，只给黑底上的字用）：
    /// 一页只用一种，只上字（字的面积远小于 20%）。
    static let red = CollageColor(hex: 0xD7261E)
    static let orange = CollageColor(hex: 0xF04E23)

    // MARK: - 栅格（R4 §B3）

    /// 一张画布上的瑞士栅格，全部是成品像素（1 倍）：
    ///
    ///     m  = 0.05·W                      边距
    ///     b  = 1.1·s                       基线 = 小字行距（紧排）
    ///     g  = b                           格间距 = 1 行
    ///     cw = (W − 2m − (c−1)·g) / c      栏宽
    ///     r  = round((H − 2m − t) / (cw + g))
    ///     mh = floor(((H − 2m − t − (r−1)·g) / r) / b) · b   格高吸附到整数行
    ///
    /// s（小字字号）在给定范围里挑：b 只取整数像素（导出时缝、格子、基线都落在整像素上），再挑格高吸附之后
    /// 剩得最少的那个（剩下的不到一行，并进下边距）。版式里的格子都按「几栏 × 几格（几行）」从这里算比例，
    /// 不手调。
    struct Grid: Hashable {
        let width: Double
        let height: Double
        /// 栏数 c。
        let columns: Int
        /// 顶部空带 t（0 / 0.15H / 0.25H）。
        let band: Double
        /// m。
        let margin: Double
        /// s：小字字号。
        let size: Double
        /// b：基线（= 格间距 g）。
        let baseline: Double
        /// cw。
        let column: Double
        /// r。
        let rows: Int
        /// mh / b：一格几行。
        let lines: Int
        /// 吸附之后排版区剩下的高（< 1 行，并进下边距）。
        let leftover: Double

        var short: Double { min(width, height) }
        var gap: Double { baseline }
        /// mh。
        var module: Double { Double(lines) * baseline }

        /// 跨 k 栏的宽（k 栏 + 中间 k − 1 道缝）。
        func span(_ k: Int) -> Double {
            let cols = Double(max(1, k))
            return cols * column + (cols - 1) * gap
        }

        /// 跨 n 格的高（n 格 + 中间 n − 1 道缝）。
        func rowsHeight(_ n: Int) -> Double {
            let k = Double(max(1, n))
            return k * module + (k - 1) * gap
        }

        /// 第 i 格的上沿（成品 y）：边距 + 顶部空带 + i 个（格 + 缝）。
        func rowTop(_ i: Int) -> Double {
            let pitch: Double = module + gap
            return margin + band + Double(i) * pitch
        }

        /// 第 j 栏的左沿（成品 x）。
        func columnLeft(_ j: Int) -> Double {
            let pitch: Double = column + gap
            return margin + Double(j) * pitch
        }

        /// 切分比例：一条缝把 total 分成 first 和 total − first − gap（CollageLayout 的 ratio 是去掉缝之后的比例）。
        func ratio(_ first: Double, of total: Double) -> Double {
            let avail: Double = total - gap
            return avail > 0 ? first / avail : 0.5
        }

        /// 左右并排：前 k 栏 / 后 n − k 栏。
        func columnSplit(_ k: Int, of n: Int) -> Double { ratio(span(k), of: span(n)) }

        /// 上下堆叠：前 a 格 / 后 n − a 格。
        func rowSplit(_ a: Int, of n: Int) -> Double { ratio(rowsHeight(a), of: rowsHeight(n)) }

        /// 四边边距（相对短边）：上 = m + 顶部空带，下 = m + 吸附剩下的（bleedBottom = 照片出血到底边：0），
        /// 左右 = m。排版区正好就是 r 格 × c 栏。
        func insets(bleedBottom: Bool = false) -> CollageInsets {
            let top: Double = (margin + band) / short
            let bottom: Double = bleedBottom ? 0 : (margin + leftover) / short
            return CollageInsets(top: top, bottom: bottom, inner: margin / short, outer: margin / short)
        }

        /// 公式（R4 §B3）。sizes = 小字字号的范围（相对短边，夹在实测区间 0.026–0.047 里）；columns = nil 按画布：
        /// 竖版 6 栏、方的 4 栏（横版也 6 栏）。
        static func solve(canvas: CollageCanvas, columns: Int? = nil, band: Double = 0,
                          sizes: ClosedRange<Double>) -> Grid {
            let W = Double(canvas.width)
            let H = Double(canvas.height)
            let S = min(W, H)
            let square = abs(W - H) < 1
            let c = max(1, columns ?? (square ? 4 : 6))
            let m: Double = 0.05 * W
            let lo: Double = max(sizeRange.lowerBound, sizes.lowerBound)
            let hi: Double = min(sizeRange.upperBound, max(lo, sizes.upperBound))
            let bLo = Int((1.1 * lo * S).rounded(.up))
            let bHi = max(bLo, Int((1.1 * hi * S).rounded(.down)))
            let mid: Double = 1.1 * (lo + hi) / 2 * S
            var best: Grid?
            var bestKey = (Double.infinity, Double.infinity)
            for bi in bLo...bHi {
                guard let g = make(W: W, H: H, c: c, m: m, t: band, b: Double(bi)) else { continue }
                // 剩得少的优先（按行算），差不多时挑离范围中间近的。
                let key = ((g.leftover / g.baseline * 4).rounded(), abs(g.baseline - mid))
                if key < bestKey {
                    bestKey = key
                    best = g
                }
            }
            return best ?? make(W: W, H: H, c: c, m: m, t: band, b: (1.1 * lo * S).rounded())
                ?? Grid(width: W, height: H, columns: c, band: band, margin: m, size: lo * S, baseline: 1.1 * lo * S,
                        column: (W - 2 * m) / Double(c), rows: 1, lines: 1, leftover: 0)
        }

        /// 按公式算一套；格高吸附到不了 2 行（太挤）= nil。
        private static func make(W: Double, H: Double, c: Int, m: Double, t: Double, b: Double) -> Grid? {
            let g = b
            let cols = Double(c)
            let cw: Double = (W - 2 * m - (cols - 1) * g) / cols
            let avail: Double = H - 2 * m - t
            guard cw > 0, avail > 0 else { return nil }
            let r = max(1, Int((avail / (cw + g)).rounded()))
            let rows = Double(r)
            let raw: Double = (avail - (rows - 1) * g) / rows
            let lines = Int((raw / b).rounded(.down))
            guard lines >= 2 else { return nil }
            let used: Double = rows * Double(lines) * b + (rows - 1) * g
            return Grid(width: W, height: H, columns: c, band: t, margin: m, size: b / 1.1, baseline: b, column: cw,
                        rows: r, lines: lines, leftover: avail - used)
        }

        /// 小字字号的实测区间（R4 §B3：0.026–0.047 S）。
        static let sizeRange: ClosedRange<Double> = 0.026...0.047
    }

    // MARK: - 行距（基线吸附）

    /// 每行下面有细线时，CollageTypeset 每行多占的高（字号的倍数，和那边的 eachLineRuleRoom 同一个数：
    /// 自测按真排出来的基线核对，两边对不上会报）。
    static let ruleRoom = 0.32

    /// 一块字的 lineSpacing：让相邻两行基线正好隔 pitch（成品像素，b 或 2b）。按这款字的上下沿（Latin 行的
    /// 字身，和 CollageTypeset.makeRun 量的同一个）反推；放不下（比 −0.15 还紧）就取 −0.15，自测会报。
    static func spacing(font: CollageFont, weight: CollageWeight, size: Double, pitch: Double, ruled: Bool) -> Double {
        let body = lineBody(font: font, weight: weight, size: size)
        let extra: Double = ruled ? ruleRoom * size : 0
        let ls: Double = (pitch - body - extra) / max(1, size)
        return max(-0.15, ls)
    }

    /// 一行西文的字身高（上沿 + 下沿），成品像素。
    static func lineBody(font: CollageFont, weight: CollageWeight, size: Double) -> Double {
        let f = CollageTypeset.font(font, weight, italic: false, size: CGFloat(size))
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hxgy0", attributes: attrs))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Double(ascent + descent)
    }

    // MARK: - 积木

    /// 小写、左齐的一行（字号是成品像素，换成相对短边）。overflow = 放不下宽度时：刊头、副标题折行（单字号）
    /// 或者只缩这一行（六格细线的刊头），别的行照栅格的字号、照基线格。
    static func line(_ text: String, size: Double, grid: Grid, font: CollageFont = .helveticaNeue,
                     weight: CollageWeight = .regular, color: CollageColor = ink,
                     textCase: CollageTextCase = .lower, tracking: Double = 0,
                     overflow: CollageLineOverflow = .block) -> CollageTextLine {
        var l = CollageTextLine(text, font: font, weight: weight, size: size / grid.short, tracking: tracking,
                                color: color)
        l.textCase = textCase
        l.overflow = overflow
        return l
    }

    /// 一栏小字：同字号、同字重，左齐右不齐，基线隔 pitch（不画细线 = b；每行下面细线 = 2b，线压在字下面）。
    /// 字色跟着页面底色翻深浅（paperTone）。
    static func block(_ lines: [CollageTextLine], grid: Grid, ruled: Bool,
                      font: CollageFont = .helveticaNeue, weight: CollageWeight = .regular) -> CollageText {
        var t = CollageText(lines: lines, vertical: false, alignH: .leading, alignV: .leading)
        t.paperTone = true
        let pitch: Double = ruled ? 2 * grid.baseline : grid.baseline
        t.lineSpacing = spacing(font: font, weight: weight, size: grid.size, pitch: pitch, ruled: ruled)
        if ruled {
            t.rule = true
            t.ruleStyle = .underEachLine
        }
        return t
    }

    /// 照片格（role、景别、抠图、压字）。mono = 这一格自己带高反差黑白（格级色调）：红字压在照片上的两款
    /// （巨型数字、满版巨字）换了样式、进了相册（整本的色调）照片也还是黑白 —— 红字压在彩色照片上（红灯笼、
    /// 红柱子）就看不清了；要彩色在检视器里改这一格的色调。记成模板自带的（fromTemplate）：换别的模板时
    /// 不跟着照片走（不然换到彩色版式里会剩一张黑白）。
    static func photoCell(_ role: CollageRole = .support, framing: CollageFraming = .auto,
                          cutout: CollageCutout? = nil, overlays: [CollageOverlay] = [],
                          mono: Bool = false) -> CollageNode {
        var cell = CollageCell.photo(nil, role: role)
        cell.framing = framing
        cell.cutout = cutout
        cell.overlays = overlays
        if mono { cell.look = CollageLookSetting(look: .contrastMono, strength: 1, fromTemplate: true) }
        return .leaf(cell)
    }

    /// 瑞士风的照片上的字：不垫雾面、不加投影（平的）。深浅由模板定：浅纸上的红字用 .dark（「自动深浅」会把
    /// 深色字在暗处翻成浅色，红就成了粉）。
    static func overlay(_ text: CollageText, anchor: CollageAnchor, inset: Double, maxWidth: Double,
                        tone: CollageTone) -> CollageOverlay {
        var o = CollageOverlay(text: text)
        o.anchor = anchor
        o.inset = inset
        o.maxWidth = maxWidth
        o.tone = tone
        o.shadow = 0
        return o
    }

    /// 样式：纸 #F2F1EC、照片高反差黑白、零投影零边框、矩形格；边距 / 缝 / 四边边距按栅格。
    static func style(_ grid: Grid, bleedBottom: Bool = false) -> CollageStyle {
        CollageStyles.make { s in
            s.background = paper
            s.margin = grid.margin / grid.short
            s.gutter = grid.gap / grid.short
            s.insets = grid.insets(bleedBottom: bleedBottom)
            s.shape = .rect
            s.border = .none
            s.shadow = 0
            s.grain = 0
            s.look = .contrastMono
            s.lookStrength = 1
            s.harmonize = 0
            // 等大的格子不分主次：关掉「小格自动收成半身」（一排六格有的全身有的半身就乱了）。
            s.tightSmallCells = false
        }
    }

    private static let xhs = CollageCanvas.social[0]
    private static let square = CollageCanvas.social[1]

    // MARK: - 栅格（每个模板一套，自测按它核对）

    /// 巨型数字：3:4，小字 0.033–0.037 S（b = 57 px，8 格 × 3 行）。
    static let numberGrid = Grid.solve(canvas: xhs, sizes: 0.033...0.037)
    /// 单字号海报：1:1，4 栏，字号往大里取 0.041–0.045 S（只有这一种字，接近 musica viva 的 0.049 S；
    /// b = 102 px，4 × 4 格、每格 4 行）。
    static let typeGrid = Grid.solve(canvas: square, sizes: 0.041...0.045)
    /// 竖排巨字：3:4，小字 0.027–0.030 S（b = 45 px：左边两栏 402 px 正好装下巨字的字身）。
    static let wordGrid = Grid.solve(canvas: xhs, sizes: 0.027...0.030)
    /// 六格细线：3:4，小字 0.027–0.030 S（b = 45 px，8 格 × 4 行）。
    static let sixGrid = Grid.solve(canvas: xhs, sizes: 0.027...0.030)

    // MARK: - 模板

    static let templates: [CollageTemplate] = [giantNumber, singleSize, rotatedWord, fullBleedWord, sixModules]

    /// Citroën 1958 式：上面三行红字、每行下面一条通栏细线；下面一个铺满六栏的巨型日期（月.日），
    /// 抠出来的人站在它前面 —— 头顶压进数字上部三成、肩膀挡住基线（人物挡字 + 抠图格，装饰大字只限总量）；
    /// 人往下一直出血到底边，左右沿栅格线切掉。数字的字顶落在基线格上：照片格（数字贴着它的上沿）往上
    /// 挪到「字顶 = 第 N 行」，N 取放得下三行细线字的最小那个（数字的数位等宽，月.日的宽和字号与日期无关）。
    static let giantNumber: CollageTemplate = {
        let g = numberGrid
        let s = g.size
        let info = block([
            line("{masthead}", size: s, grid: g, color: red),
            line("[[{weekday_en}, {day_n} {month_en} {year}]]", size: s, grid: g, color: red),
            line(cameraLine, size: s, grid: g, color: red),
        ], grid: g, ruled: true)
        // 没有拍摄时间（截图、微信转过的图）：日期换成期号（no.01，和 03.21 一样五个字形，字号差不多），
        // 不会只剩一个点被铺满宽度放成一块红方块。
        var number = CollageText(lines: [
            line("[[{month}.{day}||no.{issue}]]", size: 0.4 * g.short, grid: g, weight: .bold, color: red,
                 textCase: .none, tracking: -0.03),
        ], vertical: false, alignH: .leading, alignV: .leading)
        number.lines[0].fitWidth = true
        var big = overlay(number, anchor: .topLeading, inset: 0, maxWidth: 1, tone: .dark)
        big.layer = .behindSubject
        big.occlusionRule = .total
        big.maxOcclusion = 0.3
        big.depth = 0.3
        let total: Double = g.height - g.margin - g.band
        let bandHeight = numberBand(info: info, number: number, grid: g, cellHeight: total)
        // 抠图要贴着成品底边（toEdge）：人被前景挡住、下沿到不了底边（托盘默认主图 7232 站在石栏杆后面），或者
        // 进了相册（底下留了边距）—— 抠出来会浮在纸上，这一张就整张照片照放，数字照样压在人后。
        let root = CollageTemplates.col(g.ratio(bandHeight, of: total), CollageTemplates.text(info),
                                        photoCell(.hero, framing: .cover, cutout: CollageCutout(toEdge: true),
                                                  overlays: [big], mono: true))
        return CollageTemplate(name: "瑞士网格 · 巨型数字", root: root, style: style(g, bleedBottom: true), canvas: xhs,
                               fitAspects: false, builtin: true, category: category)
    }()

    /// 巨型数字那一版上面字格的高：字格下面隔一道缝是照片格，数字贴着照片格的上沿、铺满六栏；要让数字的字顶
    /// （大写 / 数字高）正好落在第 N 行基线格上，N 取放得下字格那几行的最小值。按样例变量量（数位等宽，
    /// 换日期宽度不变；用户改成别的字只是字顶不再落在格线上）。
    static func numberBand(info: CollageText, number: CollageText, grid g: Grid, cellHeight: Double) -> Double {
        let S = g.short
        let textH = Double(CollageTypeset.measure(info, short: S, vars: sampleVars).height)
        let box = CGSize(width: g.span(g.columns), height: cellHeight)
        let fitted = CollageTypeset.fittingWidth(number, in: box, short: S, vars: sampleVars)
        let size: Double = (fitted.lines.first?.size ?? 0.3) * S
        let gap: Double = capGap(font: .helveticaNeue, weight: .bold, size: size)
        let need: Double = textH + g.gap + gap
        let n = (need / g.baseline).rounded(.up)
        return n * g.baseline - g.gap - gap
    }

    /// 字身上沿到字顶（大写 / 数字高）有多远，成品像素。
    static func capGap(font: CollageFont, weight: CollageWeight, size: Double) -> Double {
        let f = CollageTypeset.font(font, weight, italic: false, size: CGFloat(size))
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: attrs))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Double(ascent - CTFontGetCapHeight(f))
    }

    /// 机身 · 焦距 · 光圈 · 快门 · ISO 一行：每一项包成可省的一段（缺哪项不印哪项，全没有整行不印）。
    /// 焦距印镜头上的实际焦距 {focal_mm}（{focal} 是水印那套「有 35mm 等效就用等效」：17-70 的镜头印成 92mm，
    /// 和报纸风正文的 62mm 对不上）；日期里的日子用不补零的 {day_n}（21 march、5 march，不是 05 march）。
    static let cameraLine = "[[{model}]][[ · {focal_mm}]][[ · f/{fnumber}]][[ · {shutter} s]][[ · iso {iso}]]"

    /// 量版式用的样例变量（只为算尺寸：全是西文、数位等宽；不进任何出图）。
    static let sampleVars: [String: String] = [
        "masthead": "SHIGUANG", "title": "拾光", "weekday_en": "SATURDAY", "day": "21", "day_n": "21", "month": "03",
        "month_en": "MARCH", "year": "2026", "model": "X-T50", "focal_mm": "35mm", "fnumber": "5.6",
        "shutter": "1/250", "iso": "400", "count": "6", "issue": "01", "no": "01", "date": "2026.03.21",
    ]

    /// musica viva 式：只有一种字号，全小写、左齐右不齐，刊头、副标题那两行用红；左边两栏三格一张竖图（0.65，
    /// 正好放竖拍），左下一格留白；右边两栏最上面一格空着（顶部空带），从第二格（约 28% 高）起一条字轴排到底：
    /// 两格是标题和日期，最后一格是相机那几行。
    static let singleSize: CollageTemplate = {
        let g = typeGrid
        let s = g.size
        // 刊头、副标题长了折到下一行（同一个字号、照基线格），不是整块字缩小。
        let main = block([
            line("{masthead}", size: s, grid: g, color: red, overflow: .wrap),
            line("{subtitle}", size: s, grid: g, color: red, overflow: .wrap),
            line("photographs", size: s, grid: g),
            line("[[{weekday_en},]]", size: s, grid: g),
            line("[[{day_n} {month_en} {year}]]", size: s, grid: g),
        ], grid: g, ruled: false)
        let camera = block([
            line("{model}", size: s, grid: g),
            line("[[{focal_mm}]][[, f/{fnumber}]]", size: s, grid: g),
            line("[[{shutter} s]][[, iso {iso}]]", size: s, grid: g),
        ], grid: g, ruled: false)
        let left = CollageTemplates.col(g.rowSplit(3, of: 4), photoCell(.hero), CollageTemplates.empty())
        let text = CollageTemplates.col(g.rowSplit(2, of: 3), CollageTemplates.text(main), CollageTemplates.text(camera))
        let right = CollageTemplates.col(g.rowSplit(1, of: 4), CollageTemplates.empty(), text)
        let root = CollageTemplates.row(g.columnSplit(2, of: 4), left, right)
        return CollageTemplate(name: "瑞士网格 · 单字号", root: root, style: style(g), canvas: square,
                               fitAspects: false, builtin: true, category: category)
    }()

    /// Giselle 1959 式：墨黑的纸，左边两栏是一个转 90° 的巨字（刊头，从下往上读，离底边留一个下边距加一道缝）和左上角几行小字
    /// （星期那一行用橙红：黑底上橙红比印刷红亮，5:1 看得清）；
    /// 右边四栏是高反差黑白照片，上沿对齐小字的第一行，往右、往下出血到成品边。巨字永远落在黑底上：
    /// 不压人、不压脸，什么照片都看得清（原作的巨字也是落在照片的黑底上）。
    static let rotatedWord: CollageTemplate = {
        let g = wordGrid
        let s = g.size
        let info = block([
            line("{weekday_en}", size: s, grid: g, color: orange),
            line("[[{day_n} {month_en} {year}]]", size: s, grid: g, color: .white),
            line("{model}[[, {focal_mm}]]", size: s, grid: g, color: .white),
            line("[[f/{fnumber}]][[, {shutter} s]]", size: s, grid: g, color: .white),
        ], grid: g, ruled: false)
        var word = CollageText(lines: [
            line("{masthead}", size: 0.25 * g.short, grid: g, weight: .bold, color: .white, tracking: -0.02),
        ], vertical: false, alignH: .leading, alignV: .leading)
        word.lines[0].fitWidth = true
        word.rotation = -90
        // 墨黑的纸是模板样式带的：套了「瑞士」「白」这类浅色样式、进了相册（整本的象牙纸），白字翻成近黑。
        word.paperTone = true
        // 左边那一栏：四行小字占 5 行（n 行字要 n − 1 个行距再加一行字身，比 n 行略多一点），下面隔一道缝给巨字；
        // 巨字下面隔一道缝是一块空格，高 = 栅格的下边距（m + 吸附剩下的，别的几款版心下面留的那么多）：巨字的尾
        // 离成品底边 ~150 px，看得出是留的，不是差十几像素没贴到边（字形左边的空让它贴不齐，出血要地基支持）。
        // 空格得 ≥ 4%（CollageLayout.minRatio），所以不能只留一道缝那么窄。四边边距 = 上 m、左 m，右、下 0（照片出血）。
        let total: Double = g.height - g.margin
        let infoHeight: Double = Double(info.lines.count + 1) * g.baseline
        let wordTop: Double = g.margin + infoHeight + g.gap
        let wordBottom: Double = g.height - (g.margin + g.leftover) - g.gap
        let below: Double = g.height - wordTop
        let wordCell = CollageTemplates.col(g.ratio(wordBottom - wordTop, of: below), CollageTemplates.text(word),
                                            CollageTemplates.empty())
        let leftColumn = CollageTemplates.col(g.ratio(infoHeight, of: total), CollageTemplates.text(info), wordCell)
        let width: Double = g.width - g.margin
        let root = CollageTemplates.row(g.ratio(g.span(2), of: width), leftColumn, photoCell(.hero))
        let st = CollageStyles.make { st in
            st.background = ink
            st.margin = g.margin / g.short
            st.gutter = g.gap / g.short
            st.insets = CollageInsets(top: g.margin / g.short, bottom: 0, inner: g.margin / g.short, outer: 0)
            st.shape = .rect
            st.border = .none
            st.shadow = 0
            st.look = .contrastMono
            st.lookStrength = 1
            st.harmonize = 0
            st.tightSmallCells = false
        }
        return CollageTemplate(name: "瑞士网格 · 竖排巨字", root: root, style: st, canvas: xhs,
                               fitAspects: false, builtin: true, category: category)
    }()

    /// Giselle 1959 式的满版那一版（DESIGN §3 K5「旋转 90° 巨字 + 满版高反差照片」）：高反差黑白照片铺满整页、
    /// 四边出血；右边一个转 −90°（从下往上读）的红色巨字（刊头），从右下角沿边距往上占到小字那一截下面，压在人后
    /// （人物挡字按刊名的规矩：首末字母、过半的字母都管，总量 ≤ 15% —— 这是标题字，挡掉一个字母就读错了；挡多了
    /// 退回人前，压在手、袖子上，不压脸）；四行小字（星期 / 日期 / 机身 / 光圈快门）贴着左边距，沿左边上下找
    /// 最干净的一段（躲脸、躲身子、躲花窗格和柱子，S2 的「左栏」锚点），墨 / 白按底下的明暗定（自动深浅）。
    /// 强调色只给巨字：小字固定在左上角时压在花窗格、黑屋檐、灰天上，红字在暗处、灰处都看不清（托盘默认那张
    /// 就是，模板库缩略图一团乱）。
    /// 巨字放右边：photot 的人多在画面中间偏左，放左边 21 张里 13 张挡字超过三成、退回人前压在身上。
    /// 栅格同竖排巨字（b = 45 px）：小字左沿、巨字右沿离成品边 m。
    static let fullBleedWord: CollageTemplate = {
        let g = wordGrid
        let s = g.size
        let short = g.short
        var info = block([
            line("{weekday_en}", size: s, grid: g),
            line("[[{day_n} {month_en} {year}]]", size: s, grid: g),
            line("{model}[[, {focal_mm}]]", size: s, grid: g),
            line("[[f/{fnumber}]][[, {shutter} s]]", size: s, grid: g),
        ], grid: g, ruled: false)
        info.paperTone = false
        var small = overlay(info, anchor: .leftColumn, inset: g.margin / short, maxWidth: 0.5, tone: .auto)
        small.layer = .front
        var word = CollageText(lines: [
            line("{masthead}", size: 0.25 * short, grid: g, weight: .bold, color: red, tracking: -0.02),
        ], vertical: false, alignH: .leading, alignV: .leading)
        word.lines[0].fitWidth = true
        word.rotation = -90
        // 巨字从底边距往上，顶和小字那一截下面隔一行（小字四行占 5 行、再空 1 行）：沿阅读方向的长 = 版心高 − 6b。
        let inner: Double = g.height - 2 * g.margin
        let reach: Double = (inner - 6 * g.baseline) / inner
        var big = overlay(word, anchor: .bottomTrailing, inset: g.margin / short, maxWidth: reach, tone: .dark)
        big.layer = .behindSubject
        big.occlusionRule = .masthead
        big.maxOcclusion = 0.15
        let st = CollageStyles.make { st in
            st.background = ink
            st.margin = 0
            st.gutter = g.gap / short
            st.insets = CollageInsets(top: 0, bottom: 0, inner: 0, outer: 0)
            st.shape = .rect
            st.border = .none
            st.shadow = 0
            st.look = .contrastMono
            st.lookStrength = 1
            st.harmonize = 0
            st.tightSmallCells = false
        }
        return CollageTemplate(name: "瑞士网格 · 满版巨字", root: photoCell(.hero, overlays: [small, big], mono: true), style: st,
                               canvas: xhs, fitAspects: false, builtin: true, category: category)
    }()

    /// 2 × 3 格照片：六栏、每张照片两栏宽三格高（0.64，正好放竖拍）；上面一格两栏细线字（日期在前、刊头用红，
    /// 细线跟第一行走 = 墨色），最下面一格的第 3 行一行页码（细线落在倒数第二行，和上面的线一样压在格线上）。
    /// 上面那两栏是 4 栏 + 2 栏（缝对着第三张照片的左沿）：刊头那栏宽，四十来个字母的标题照原字号放得下；
    /// 再长只缩刊头那一行（它在左栏最后一行，别的行、右栏照原字号，细线、基线还对齐）。
    static let sixModules: CollageTemplate = {
        let g = sixGrid
        let s = g.size
        let head = block([
            line("[[{weekday_en}, {day_n} {month_en} {year}]]", size: s, grid: g),
            line("{masthead}", size: s, grid: g, color: red, overflow: .shrink),
        ], grid: g, ruled: true)
        // 张数写成「标签: 数」：一张照片时也不会是「1 photographs」。
        let headRight = block([
            line("photographs: {count}", size: s, grid: g),
            line("{model}", size: s, grid: g),
        ], grid: g, ruled: true)
        let foot = block([line("no. {issue}", size: s, grid: g)], grid: g, ruled: true)
        func trio(hero: Bool) -> CollageNode {
            CollageTemplates.row(g.columnSplit(2, of: 6), photoCell(hero ? .hero : .support),
                                 CollageTemplates.row(g.columnSplit(2, of: 4), photoCell(), photoCell()))
        }
        let header = CollageTemplates.row(g.columnSplit(4, of: 6), CollageTemplates.text(head),
                                          CollageTemplates.text(headRight))
        // 最下面一格：空一行、隔一行缝，字从第 3 行起（和格高一样都是整行）。
        let footRow = CollageTemplates.col(g.ratio(g.baseline, of: g.module), CollageTemplates.empty(),
                                           CollageTemplates.text(foot))
        let lower = CollageTemplates.col(g.rowSplit(3, of: 4), trio(hero: false), footRow)
        let body = CollageTemplates.col(g.rowSplit(3, of: 7), trio(hero: true), lower)
        let root = CollageTemplates.col(g.rowSplit(1, of: 8), header, body)
        return CollageTemplate(name: "瑞士网格 · 六格细线", root: root, style: style(g), canvas: xhs,
                               fitAspects: false, builtin: true, category: category)
    }()

    // MARK: - 风格预设

    /// 「瑞士」：纸 #F2F1EC、高反差黑白、5% 边距、缝 = 一行基线（3:4、s 取 0.029–0.031 S 时 b = 49 px = 0.0340 S），
    /// 矩形零投影。
    static let presets: [CollageStyles.Preset] = [
        CollageStyles.Preset(key: "swiss", name: "瑞士", style: {
            let g = Grid.solve(canvas: CollageCanvas.social[0], sizes: 0.029...0.031)
            var s = style(g)
            // 预设套在任意版式上：只要边距和缝，四边边距（按某一个栅格算的）不带。
            s.insets = nil
            return s
        }()),
    ]
}
