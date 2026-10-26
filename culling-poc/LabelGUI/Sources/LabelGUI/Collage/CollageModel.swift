import Foundation
import CoreGraphics

// MARK: - 拼图文档模型
//
// 版式 = 一棵带显式 ratio 的切分树（CollageNode）。求解器、模板、手动拖缝改的都是这棵
// 树；渲染器和画布只读 ratio + 缝宽 + 边距，从不回头问求解器。所以「换一版」换的是整棵
// 树，画布/缝宽改了按比例缩放，「贴合原比例」是一个显式动作。
//
// 所有结构逐字段容错解码（同水印）：模板/预设存进 state.json，模型以后加字段不能让旧
// 模板失效。Decodable 的 init 写在 extension 里，结构体保留逐成员初始化器。

struct CollageColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    func cgColor(alpha: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func mixed(with other: CollageColor, _ t: Double) -> CollageColor {
        CollageColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    static let paper = CollageColor(hex: 0xF4F1EA)
    static let white = CollageColor(hex: 0xFFFFFF)
    static let ink = CollageColor(hex: 0x2B2926)
    static let charcoal = CollageColor(hex: 0x1D1D1F)
    static let warmGrey = CollageColor(hex: 0x70685E)
    static let rule = CollageColor(hex: 0xA0978A)
    static let seal = CollageColor(hex: 0xA62C26)
    static let rice = CollageColor(hex: 0xEFE8D8)
}

// MARK: - 照片引用（文档自带，不依赖批量页还开着哪个场次）

struct CollagePhotoRef: Codable, Hashable, Identifiable {
    var id: String
    /// 全分辨率解码源（RAW+JPEG 配对时是 JPEG）。
    var path: String
    /// 1024 预览的绝对路径；外部拖进来的文件没有。
    var previewPath: String?
    /// 转正后的全尺寸像素。
    var width: Int
    var height: Int
    /// 主体人脸框（已外扩 15%，归一化，左上原点），最大的在前。
    var faces: [[Double]] = []
    /// 挑主图、挑片用：越大越好。
    var score: Double = 0
    var isPick = false
    var take: Int?
    var chapter: Int?
    var captureTime: Date?
    /// 主脸未外扩的面积占比 —— 景别信号。
    var faceAreaPct: Double?
    // 下面这些从批量页带过来（进拼图 tab、分析做完时按 id 刷新，见 CollageBridge.refresh）；外部文件大多没有。
    /// 近似重复组（引擎的 burst_group：同机身 2 秒内 + 画面几乎一样）。
    var burstGroup: Int?
    /// 场内名次 1…3（批量页缩略图上的 #1 #2 #3；废片不排、单张的场没有）。
    var takeRank: Int?
    /// 帧号 = 原文件名末尾的数字（DSCF7207 → "7207"），印样、片边用；文件名没有数字 = nil。
    var frameNo: String?
    /// 拍摄时间的小数秒（captureTime 只到整秒）：同一秒的连拍按它排先后。
    var captureSubsec: Double?
    /// 判决（批量页那边的精选 / 可用 / 废片）；外部文件 = nil。
    var verdict: CollageVerdict?
    /// 判决是手动定的（不是自动推荐 / 接受的推荐）。
    var isManual = false
    /// 睁眼（批量页按连拍相对基线判的结果）；没有能判的脸 = nil。
    var eyesOpen: Bool?
    /// 镜头、焦距、光圈、快门、ISO（分析时从 EXIF 读的那份）。
    var exif: ExifMeta?
    /// 机身 key（型号，同型号两台时带序列号）：双机位分卷用。
    var body: String?
    /// 黑白照片（1024 预览算，和路人信息一起算：CollageVision.hints）；还没算 = nil。
    var isMonochrome: Bool?
    /// 平均亮度 0…1（同上）：左右页亮度差、暗调整章用。
    var meanLuma: Double?

    init(id: String, path: String, previewPath: String? = nil, width: Int, height: Int) {
        self.id = id
        self.path = path
        self.previewPath = previewPath
        self.width = width
        self.height = height
    }

    var aspect: Double { height > 0 && width > 0 ? Double(width) / Double(height) : 1.5 }
    var isPortrait: Bool { height > width }
    /// 预览存在就用预览（界面快），否则原图。
    var quickPath: String { previewPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? path }
}

/// 批量页的判决（存英文名：Verdict 的原值是中文、也不是 Codable）。
enum CollageVerdict: String, Codable, Hashable {
    case pick, usable, reject
}

// MARK: - 切分树

enum CollageAxis: String, Codable, Hashable {
    /// 左右并排（竖缝）
    case row
    /// 上下堆叠（横缝）
    case column

    var flipped: CollageAxis { self == .row ? .column : .row }
}

enum CollageFraming: String, Codable, CaseIterable, Hashable {
    case auto, full, half, close
    /// 封面：头顶压进刊头（人后的那块定死位置的字）底部，眼睛落在刊头字高中下部或基线下面一点（CollageCover 解）。
    /// 旧版本读到它退回「自动」。
    case cover

    var label: String {
        switch self {
        case .auto: return "自动"
        case .full: return "全身"
        case .half: return "半身"
        case .close: return "特写"
        case .cover: return "封面"
        }
    }

    /// 自由相纸能选的（封面取景要有刊头那一格的几何，只给网格格子用）。
    static let itemCases: [CollageFraming] = [.auto, .full, .half, .close]
}

enum CollageShape: String, Codable, CaseIterable, Hashable {
    case rect, rounded, arch, circle

    var label: String {
        switch self {
        case .rect: return "矩形"
        case .rounded: return "圆角"
        case .arch: return "拱窗"
        case .circle: return "月洞门"
        }
    }
}

enum CollageRole: String, Codable, Hashable {
    case auto, hero, support
}

/// 手动裁切：窗口中心（照片归一化坐标）+ 相对「最大窗口」的放大倍数。
struct CollageCropOverride: Codable, Hashable {
    var cx: Double
    var cy: Double
    var zoom: Double
}

struct CollageCell: Codable, Hashable {
    enum Kind: String, Codable, Hashable { case photo, text, empty }

    var kind: Kind = .empty
    var photoID: String?
    var text: CollageText?
    var framing: CollageFraming = .auto
    var crop: CollageCropOverride?
    var locked = false
    /// nil = 跟随样式。
    var shape: CollageShape?
    var role: CollageRole = .auto
    /// 完整显示、不裁：照片按原比例放进格子正中，四周留底色（单张竖图占一页、「这张不许裁」）。
    var contain = false
    /// 完整显示时四周不留底色，用这张照片自己大幅模糊铺满（横格里放竖图的常见做法）。
    var containBlur = false
    /// 压在这张照片上的字（跟着照片走：互换、挪格子、换一批都带着）。多个字块时这是第一个（刊头，最先摆）。
    var overlay: CollageOverlay?
    /// 同一张照片上的其余字块（封面的左栏、右栏、底部……），按顺序摆在 overlay 之后、依次让着前面的。
    /// 旧版本只认 overlay：读到新工程只剩第一个字块，不会读坏。
    var extraOverlays: [CollageOverlay] = []
    /// 这一格单独的色调；nil = 跟页面（页面也没设 = 跟整个工程）。
    var look: CollageLookSetting?
    /// 抠图：只画主体（主体蒙版切出来），背景透出页面；nil = 照常画整张。没有蒙版时照常画整张。
    var cutout: CollageCutout?
    /// 「封面」取景是人物挡字开关顺手换的（原来是「自动」）：关掉人物挡字时换回自动。用户自己选的封面（或换了景别）
    /// 这里是 false，不动。
    var coverAuto = false

    init(kind: Kind = .empty) { self.kind = kind }

    /// 这张照片上全部字块，按摆位顺序（第 0 个 = overlay）。写回时第一个进 overlay、其余进 extraOverlays。
    var overlays: [CollageOverlay] {
        get { (overlay.map { [$0] } ?? []) + extraOverlays }
        set {
            overlay = newValue.first
            extraOverlays = Array(newValue.dropFirst())
        }
    }

    static func photo(_ id: String?, role: CollageRole = .auto) -> CollageCell {
        var cell = CollageCell(kind: .photo)
        cell.photoID = id
        cell.role = role
        return cell
    }

    static func text(_ text: CollageText) -> CollageCell {
        var cell = CollageCell(kind: .text)
        cell.text = text
        return cell
    }
}

/// 抠图格的样子：白色贴纸描边（相对画布短边，0 = 不描）、投影（0…1）。
struct CollageCutout: Codable, Hashable {
    var stroke = 0.0
    var shadow = 0.0
    /// 抠出来的人得一直延伸到成品底边、被成品边切掉（瑞士风巨型数字：人从纸上「站」起来）：这一格不贴着成品底边
    /// （相册跨页留了边距），或者照片里人的下沿到不了格子底边（被栏杆挡住、全身照脚在格子里）—— 人就浮在纸上，
    /// 这一张不抠，整张照片照放（人后的字照样按蒙版压在人后）。CollageCover 定、预览导出同一个决定。旧工程 = false。
    var toEdge = false

    init(stroke: Double = 0, shadow: Double = 0, toEdge: Bool = false) {
        self.stroke = stroke
        self.shadow = shadow
        self.toEdge = toEdge
    }
}

struct CollageNode: Codable, Hashable {
    var axis: CollageAxis = .row
    /// 第一个孩子占「去掉缝之后的长度」的比例。
    var ratio: Double = 0.5
    /// 切分节点正好两个孩子；叶子为空。
    var children: [CollageNode] = []
    var cell: CollageCell?

    init() {}

    static func leaf(_ cell: CollageCell) -> CollageNode {
        var node = CollageNode()
        node.cell = cell
        return node
    }

    static func split(_ axis: CollageAxis, _ ratio: Double, _ first: CollageNode, _ second: CollageNode) -> CollageNode {
        var node = CollageNode()
        node.axis = axis
        node.ratio = ratio
        node.children = [first, second]
        return node
    }

    var isLeaf: Bool { children.count != 2 }

    func node(at path: [Int]) -> CollageNode? {
        var current = self
        for index in path {
            guard !current.isLeaf, index >= 0, index < 2 else { return nil }
            current = current.children[index]
        }
        return current
    }

    /// 就地改某个节点；路径无效什么都不做，返回是否改到了。
    @discardableResult
    mutating func update(at path: [Int], _ body: (inout CollageNode) -> Void) -> Bool {
        guard let first = path.first else {
            body(&self)
            return true
        }
        guard !isLeaf, first >= 0, first < 2 else { return false }
        return children[first].update(at: Array(path.dropFirst()), body)
    }

    /// 叶子路径，按阅读顺序（先第一个孩子）。
    func leafPaths(prefix: [Int] = []) -> [[Int]] {
        if isLeaf { return [prefix] }
        return children[0].leafPaths(prefix: prefix + [0]) + children[1].leafPaths(prefix: prefix + [1])
    }

    var leaves: [CollageCell] {
        if isLeaf { return cell.map { [$0] } ?? [] }
        return children[0].leaves + children[1].leaves
    }

    var photoIDs: [String] { leaves.compactMap { $0.kind == .photo ? $0.photoID : nil } }

    /// 子树里有没有照片格（没有 = 纯文字/留白，排版时可以当弹性格吸收余量）。
    var hasPhotoLeaf: Bool { leaves.contains { $0.kind == .photo } }
    var hasTextLeaf: Bool { leaves.contains { $0.kind == .text } }

    /// 结构签名：只看形状和轴，不看照片 —— 备选去重、相册相邻跨页避免同一版用。
    var signature: String {
        if isLeaf { return cell?.kind == .text ? "T" : "P" }
        let r = Int((ratio * 20).rounded())
        return "\(axis == .row ? "R" : "C")\(r)(\(children[0].signature),\(children[1].signature))"
    }

    /// 形状类：不看左右/上下顺序、不看比例 —— 镜像出来的版算同一类，备选条每类只留两个。
    var shapeClass: String {
        if isLeaf { return cell?.kind == .text ? "T" : "P" }
        let a = children[0].shapeClass
        let b = children[1].shapeClass
        let pair = a < b ? "\(a),\(b)" : "\(b),\(a)"
        return "\(axis == .row ? "R" : "C")(\(pair))"
    }
}

// MARK: - 文字

/// 字体（声明顺序 = 字体菜单的顺序；存的是 rawValue，顺序随便挪）。新加的每一个都在本机按 PostScript 名解析过，
/// 系统里按需下载的那几个（隶书、魏碑、仿宋、兰亭黑……）没下载时落到同类的系统字体（CollageTypeset.postScriptNames）。
enum CollageFont: String, Codable, CaseIterable, Hashable {
    case songti, songtiTC, kaiti, fangsong, lishu, weibei, pingfang, lantinghei
    case didot, bodoni, newYork, baskerville, bigCaslon, athelas, charter, timesNewRoman, georgia, superclarendon
    case optima, avenir, gillSans, futura, helveticaNeue, helveticaCondensed, dinAlternate, dinCondensed, impact
    case copperplate, fraktur
    case hanzipen, bradley, snell, typewriter

    var label: String {
        switch self {
        case .songti: return "宋体"
        case .songtiTC: return "宋体繁"
        case .kaiti: return "楷体"
        case .fangsong: return "仿宋"
        case .lishu: return "隶书"
        case .weibei: return "魏碑"
        case .pingfang: return "苹方"
        case .lantinghei: return "兰亭黑"
        case .didot: return "Didot"
        case .bodoni: return "Bodoni"
        case .newYork: return "New York"
        case .baskerville: return "Baskerville"
        case .bigCaslon: return "Big Caslon"
        case .athelas: return "Athelas"
        case .charter: return "Charter"
        case .timesNewRoman: return "Times New Roman"
        case .georgia: return "Georgia"
        case .superclarendon: return "Superclarendon"
        case .optima: return "Optima"
        case .avenir: return "Avenir"
        case .gillSans: return "Gill Sans"
        case .futura: return "Futura"
        case .helveticaNeue: return "Helvetica Neue"
        case .helveticaCondensed: return "Helvetica 窄体"
        case .dinAlternate: return "DIN"
        case .dinCondensed: return "DIN 窄体"
        case .impact: return "Impact"
        case .copperplate: return "Copperplate"
        case .fraktur: return "哥特体"
        case .hanzipen: return "手写"
        case .bradley: return "Bradley 手写"
        case .snell: return "Snell 花体"
        case .typewriter: return "打字机"
        }
    }

    /// 中文字体（全缺时落到苹方，而不是系统的西文字体）。
    var isChinese: Bool {
        switch self {
        case .songti, .songtiTC, .kaiti, .fangsong, .lishu, .weibei, .pingfang, .lantinghei, .hanzipen: return true
        default: return false
        }
    }
}

/// 字重。heavy / black 只有部分字体有（Helvetica 窄体、Charter、Superclarendon、兰亭黑、宋体……），
/// 没有的落到这个字体最粗的那一档。
enum CollageWeight: String, Codable, CaseIterable, Hashable {
    case light, regular, bold, heavy, black

    var label: String {
        switch self {
        case .light: return "细"
        case .regular: return "常规"
        case .bold: return "粗"
        case .heavy: return "特粗"
        case .black: return "最粗"
        }
    }

    /// bold 及以上（解析时 heavy / black 先找自己那档，找不到当 bold）。
    var isBoldish: Bool { self == .bold || self == .heavy || self == .black }
}

enum CollageAlign: String, Codable, CaseIterable, Hashable {
    /// 横排 = 左 / 竖排 = 上
    case leading
    case center
    /// 横排 = 右 / 竖排 = 下
    case trailing
}

/// 花字：描边、投影 / 发光、底条、渐变。每一项 0（渐变 nil）= 不加，可以叠。尺寸都相对本行字号。
struct CollageTextEffect: Codable, Hashable {
    /// 描边粗细；描在字外面一圈（字本身不变细）。
    var stroke = 0.0
    var strokeColor: CollageColor = .white
    /// 投影 / 发光的浓淡 0…1。
    var shadow = 0.0
    var shadowColor = CollageColor(r: 0, g: 0, b: 0)
    /// 投影的模糊。
    var shadowBlur = 0.12
    /// 投影往右下落多远；0 = 四周一圈（发光）。
    var shadowOffset = 0.06
    /// 底条不透明度 0…1。
    var band = 0.0
    var bandColor: CollageColor = .white
    /// 底条圆角 0…1：1 = 两头全圆。
    var bandRound = 0.3
    /// 渐变：字色在上、这个颜色在下。
    var gradient: CollageColor?

    init() {}

    var isEmpty: Bool { stroke <= 0.0001 && shadow <= 0.0001 && band <= 0.0001 && gradient == nil }
    var hasBand: Bool { band > 0.0001 }
}

struct CollageTextLine: Codable, Hashable {
    /// 支持 {title} {date} {date_cn} {year} {month} {model} {lens} 等占位符。
    var text: String
    var font: CollageFont = .songti
    var weight: CollageWeight = .regular
    var italic = false
    /// 字号，相对画布短边。
    var size: Double = 0.04
    /// 字距，em。
    var tracking: Double = 0
    var color: CollageColor = .ink
    /// 沿阅读方向的起始缩进，相对本行字号（竖排的小字往下错开一截）。
    var indent: Double = 0
    /// 花字；nil = 普通字。
    var effect: CollageTextEffect?
    /// 铺满宽度（刊头）：字号放大 / 缩小到正好占满字块能用的宽（竖排 = 高），size 只当起点。
    var fitWidth = false
    /// 横向压窄（0.85…1）：长刊名铺满宽度后字太矮时，宁可压窄一点也不再缩字号（再窄竖干就细得垮了）。
    var widthScale = 1.0
    /// 大小写：占位符展开之后再改（瑞士风默认小写、刊头大写）。
    var textCase: CollageTextCase = .none
    /// 这一行在字块里放不下宽度时怎么办：block = 整块一起缩（原来的样子）；wrap = 在词缝（中文按字）折到下一行，
    /// 字号不变；shrink = 只缩这一行，别的行字号不动。旧工程 = block。
    var overflow: CollageLineOverflow = .block
    /// 只缩字形不缩行（0.1…1）：字按 size × glyphScale 画，行框、行距、细线还按 size 排（基线留在格线上）。
    /// 排版时 overflow = shrink 放不下才填（CollageTypeset.overflowed），存盘的都是 1。
    var glyphScale = 1.0
    /// 铺满宽度的短词（≤ 4 个字母的刊头）：字号放大到 size 就不再放，剩下的宽用加大字距两端对齐（R1：短刊名
    /// 走大字距，不然 3、4 个字母铺满 94% 宽字高要到 20–25%H）。size 这时是上限。只对 fitWidth 的行起作用。
    var spreadShort = false
    /// 颜色从照片取（时尚刊的强调色）：按这块字底下的亮度，在主体（蒙版里衣服、嘴唇）的几种颜色里挑最鲜艳、
    /// 对比够 3:1 的那个；取不到（没有蒙版、照片太素）就用 color。深浅翻转不管它（挑的时候已经按底下的亮度挑了）。
    var accentFromPhoto = false
    /// 这一行是别的格子里那个值的小标签：这个占位符（键名，如 "model"）展开是空的时候整行不印（留白杂志 · 白边封面
    /// 的 CAMERA / DATE：没有 EXIF、没有拍摄时间的照片不在空的值上面留一个标签；报纸风 · 今日头版报头下面的拼音刊名
    /// 看 {masthead_alt}：刊头和标题是同一串字时不印）。nil = 照常印（旧工程、别的模板）。
    var onlyWhenFilled: String?

    init(_ text: String, font: CollageFont = .songti, weight: CollageWeight = .regular,
         size: Double = 0.04, tracking: Double = 0, color: CollageColor = .ink,
         italic: Bool = false, indent: Double = 0, effect: CollageTextEffect? = nil) {
        self.text = text
        self.font = font
        self.weight = weight
        self.size = size
        self.tracking = tracking
        self.color = color
        self.italic = italic
        self.indent = indent
        self.effect = effect
    }
}

struct CollageSeal: Codable, Hashable {
    /// 1–4 个字；4 个字按传统右起竖读排成 2×2。
    var text: String = "春"
    var color: CollageColor = .seal
    /// 边长，相对画布短边。
    var size: Double = 0.035
}

/// 一行字放不下宽度时：整块缩 / 折行 / 只缩这一行（CollageTextLine.overflow）。
enum CollageLineOverflow: String, Codable, CaseIterable, Hashable {
    case block, wrap, shrink
}

/// 一行字的大小写（占位符展开之后再改：{month_en} 是全大写，「首字母大写」就成了 October）。
/// traditional / traditionalRTL（报纸风民国竖排）：简转繁（Hans-Hant，用户打的简体标题也跟着转）；右起 = 再把字序
/// 倒过来，横排从右往左读（民国报纸的横排标题条），西文、数字那一段不拆。旧版本读到这两个值退回「原样」。
enum CollageTextCase: String, Codable, CaseIterable, Hashable {
    case none, upper, lower, title
    case traditional, traditionalRTL

    var label: String {
        switch self {
        case .none: return "原样"
        case .upper: return "全大写"
        case .lower: return "全小写"
        case .title: return "首字母大写"
        case .traditional: return "繁体"
        case .traditionalRTL: return "繁体右起"
        }
    }
}

/// 细线怎么画（rule 打开才画）。旧工程只有 rule 开关 = short；旧版本读到别的样式也照 short 画。
enum CollageRuleStyle: String, Codable, CaseIterable, Hashable {
    /// 字块后面一小截（原来那种）。
    case short
    /// 和字块一样宽。
    case full
    /// 每行下面一条，和这一栏一样宽（瑞士风）。
    case underEachLine
    /// 报头下面的粗细双线（上粗下细），和这一栏一样宽。
    case thickThin
    /// 细线框：整块字外面一圈细线、字退进框里（报纸的报眼）。旧版本读到这个值退回短线。
    case box

    var label: String {
        switch self {
        case .short: return "短线"
        case .full: return "通栏"
        case .underEachLine: return "每行下面"
        case .thickThin: return "粗细双线"
        case .box: return "细线框"
        }
    }
}

/// 正文：多栏排的一段段文字（报纸正文、杂志内文）。排在标题那几行的下面（竖排标题时在左边），占满剩下的地方。
/// 文字为空 = 画「灰条」：每行一条墨色细条，看着像正文、不假装有字（社交尺寸上 9px 的字本来也只是纹理）。
struct CollageBody: Codable, Hashable {
    /// 支持占位符；换行分段。
    var text = ""
    var columns = 2
    /// 两端对齐（段末一行照常齐头）。
    var justified = true
    /// 栏与栏之间一条细线。
    var columnRule = false
    /// 首字下沉几行；0 = 不下沉（竖排不下沉）。
    var dropCap = 0
    var font: CollageFont = .songti
    var weight: CollageWeight = .regular
    /// 字号，相对画布短边。
    var size = 0.012
    /// 行高，相对字号。
    var leading = 1.45
    /// 段首缩进，em。
    var firstLineIndent = 1.0
    /// 栏距，em。
    var gap = 1.2
    var color: CollageColor = .ink
    /// 竖排：栏是一条条横带，带里的字一列列从右往左竖着排（民国报纸）。
    var vertical = false
    /// 这段字是占位的（模板带的千字文之类）：印刷导出时提示换成自己的字。在检视器里改过字就清掉。
    var filler = false
    /// 简转繁（Hans-Hant，占位符展开之后再转；民国竖排）。
    var traditional = false
    /// 平衡分栏：各栏行数平均分（前几栏多一行），不是排满一栏再接下一栏（报纸头版一段短的「本报讯」排成 5 栏）。
    /// 首字下沉时不平衡。
    var balanced = false

    init(text: String = "", columns: Int = 2) {
        self.text = text
        self.columns = columns
    }
}

struct CollageText: Codable, Hashable {
    var lines: [CollageTextLine] = []
    /// 竖排：每行是一列，右起。
    var vertical = false
    var alignH: CollageAlign = .leading
    var alignV: CollageAlign = .leading
    /// 行（列）间距，相对该行字号；最小 −0.15（瑞士紧排，上下两行的字框叠一点）。
    var lineSpacing: Double = 0.35
    /// 文字后面一条细线（竖排是竖线）。
    var rule = false
    /// 细线的样式（rule 打开才看）。
    var ruleStyle: CollageRuleStyle = .short
    var seal: CollageSeal?
    /// 整块字转 90°（顺时针，从上往下读）/ −90°（逆时针，从下往上读）/ 0。量尺寸时宽高互换。
    var rotation = 0
    /// 正文（多栏）；nil = 没有。
    var body: CollageBody?
    /// 文字格的字色跟着页面底色翻深浅：模板按自己的底色配的字（墨黑纸上的白字），套了别的样式、进了相册
    /// （整本的纸色）之后和底色对比不到 3:1 的那几行翻成深 / 浅（强调色本来就够的不动）。只管文字格；旧工程 = false。
    var paperTone = false

    init(lines: [CollageTextLine] = [], vertical: Bool = false,
         alignH: CollageAlign = .leading, alignV: CollageAlign = .leading) {
        self.lines = lines
        self.vertical = vertical
        self.alignH = alignH
        self.alignV = alignV
    }

    var isRotated: Bool { rotation != 0 }
    /// 字块在页面上是竖长的（竖排，或横排转了 90°）：放压字时宽高的上限按竖的给。
    var isTall: Bool { vertical != isRotated }
}


// MARK: - 压字：照片上的字

/// 字块贴在照片的哪一处。auto = 按人脸、画面空处自动挑；custom = 拖过，按 x/y 放。
enum CollageAnchor: String, Codable, CaseIterable, Hashable {
    case auto
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing
    case custom
    /// 贴着左边 / 右边的一栏（封面字）、贴着底边的一条：边是定的，在那一边上下挪着找位置（照样躲脸、躲前面的字块）。
    case leftColumn, rightColumn, bottomBand

    var label: String {
        switch self {
        case .auto: return "自动"
        case .leftColumn: return "左栏"
        case .rightColumn: return "右栏"
        case .bottomBand: return "底栏"
        case .topLeading: return "左上"
        case .top: return "上"
        case .topTrailing: return "右上"
        case .leading: return "左"
        case .center: return "中"
        case .trailing: return "右"
        case .bottomLeading: return "左下"
        case .bottom: return "下"
        case .bottomTrailing: return "右下"
        case .custom: return "手动"
        }
    }

    /// 九宫格位置（列, 行），0…2。
    var cell: (col: Int, row: Int)? {
        switch self {
        case .topLeading: return (0, 0)
        case .top: return (1, 0)
        case .topTrailing: return (2, 0)
        case .leading: return (0, 1)
        case .center: return (1, 1)
        case .trailing: return (2, 1)
        case .bottomLeading: return (0, 2)
        case .bottom: return (1, 2)
        case .bottomTrailing: return (2, 2)
        case .auto, .custom, .leftColumn, .rightColumn, .bottomBand: return nil
        }
    }

    static let grid: [CollageAnchor] = [.topLeading, .top, .topTrailing, .leading, .center, .trailing,
                                        .bottomLeading, .bottom, .bottomTrailing]
    /// 定一条边、沿那条边找位置的几种（封面字）。
    static let sides: [CollageAnchor] = [.leftColumn, .rightColumn, .bottomBand]
    var isSide: Bool { self == .leftColumn || self == .rightColumn || self == .bottomBand }
}

/// 字色：自动 = 看字块底下的画面亮暗换深字/浅字。
enum CollageTone: String, Codable, CaseIterable, Hashable {
    case auto, light, dark

    var label: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅字"
        case .dark: return "深字"
        }
    }
}

/// 压字在主体前还是后：后 = 人物挡字（刊头压在人身后，S3 的主体蒙版切出来盖在字上）。
enum CollageTextLayer: String, Codable, CaseIterable, Hashable {
    case front, behindSubject

    var label: String { self == .front ? "在人前" : "在人后" }
}

struct CollageOverlay: Codable, Hashable {
    var text: CollageText
    var anchor: CollageAnchor = .auto
    /// custom：字块中心在照片区里的位置（0…1）。
    var x = 0.5
    var y = 0.5
    /// 离照片边多远，相对照片区短边。
    var inset = 0.06
    var tone: CollageTone = .auto
    /// 浅字的投影 0…1（深字不加）。
    var shadow = 0.45
    /// 字块最宽占照片区多少，放不下整体缩（铺满宽度的行按它放大）。
    var maxWidth = 0.86
    /// 字在人前（默认）还是人后。
    var layer: CollageTextLayer = .front
    /// 人物挡字的压字深度 t：头顶落在这块字（最大那一行）字顶往下多少字高（0…0.3，封面取景用）。
    var depth = 0.2
    /// 人物挡字最多挡掉多少墨迹（0.05…0.33；超过 0.33 一律不行）。
    var maxOcclusion = 0.25
    /// 人物挡字按什么规矩判：刊名（首末字母、过半的字母都管）/ 装饰大字（只管总量：人站在巨型数字前面）。
    var occlusionRule: CollageOcclusionRule = .masthead
    /// 封面取景最多拉近几倍（相对这一格放得下的最大窗口；nil = 不限，只受放大上限管）。巨字开篇用：字高占半张照片，
    /// 眼睛要落进字里，全身照会被拉成半身（拉近四倍多），1024 的主体蒙版跟着放大，软边成了头外一圈背景色。
    var maxZoom: Double?
    /// 人后时主体那圈边压利落（同抠图：软边压陡，按蒙版放大倍数多收一圈）。纸色大字大面积压在头后面时，
    /// 蒙版软边里的背景色（天空、深色木构）会成一圈光晕；默认 false（头发丝留着半透明）。
    var tightEdge = false
    /// 照片区最下面空出多少不进（照片区高的比例，0…0.4；手动拖的位置不管）：自动、沿边的在上面找位置，定死在下方的
    /// 往上抬。小红书封面底部 10.4% 会被标题和头像挡住，封面字不放进去（条码、期号可以进，它们这个设 0）。
    var clearBottom = 0.0
    /// 底下太花、反差不够时字后面垫雾面（shadow > 0 时）。false = 干净的字（时尚刊：一层层叠出来的雾面在大块字底下
    /// 看得出一圈圈的边、发脏）：不垫雾面；深浅按每个字形底下最不利的地方挑，还不够清楚就沿字边落一圈很淡的光晕；
    /// 自动挑大小不缩到要读的字号（2.2%W）以下，太长的一行自己缩、再不行断成两行；「 · 」隔开的几段里占位符没有值的
    /// 那段整段不印（没有 EXIF 的照片不印「F/」）。实现在 CollageStyleFashionType.swift。
    var scrim = true
    /// 同一格里 matchTone 的字块统一深浅（时尚刊「刊头在后 · 无衬线」的封面字全白或全黑）：两种深浅各摆一遍，
    /// 取这几块加起来看得最清楚的那遍（每块按字形底下算的 score：差的字形平均差多少 + 最差那个的三成）。
    /// 只管深浅是「自动」的、干净的字（scrim = false）。
    var matchTone = false
    /// 底部渐变（0…0.7，最深多黑）：从这块字上面一点到照片区底边一道平滑的压暗，字一律用浅字；只压到字看得清为止
    /// （底下本来就暗 = 不压）。0 = 不要。
    var fade = 0.0
    /// 定在上方时，字墨的顶离照片区上边多远（照片区高的比例，0…0.2）：大字刊头的字框上面还有一截上伸部的空，
    /// 按字框贴边字顶会落到 5%H。0 = 按字框（以前的样子）。
    var inkTop = 0.0

    init(text: CollageText) { self.text = text }
}

/// 人物挡字的规矩。刊名要认得出来：首字母 ≤ 5%、末字母 ≤ 15%、过半的字母有数；装饰大字（瑞士风巨型数字、
/// 巨字开篇）本来就是让人挡住一截，只管总量（maxOcclusion，硬上限 33% 照旧）。
enum CollageOcclusionRule: String, Codable, CaseIterable, Hashable {
    case masthead, total

    var label: String { self == .masthead ? "刊名" : "装饰大字" }
}

// MARK: - 样式

enum CollageBorder: String, Codable, CaseIterable, Hashable {
    /// mat = 卡纸窗口（婚礼 fine-art）：照片四周一圈卡纸（style.matWidth，底边加宽），照片外几毫米一道细线。
    case none, hairline, polaroid, film, mat

    var label: String {
        switch self {
        case .none: return "无"
        case .hairline: return "细线"
        case .polaroid: return "相纸"
        case .film: return "胶片"
        case .mat: return "卡纸"
        }
    }
}

/// 整组统一的色调（程序生成的 3D LUT，不带任何胶片/滤镜品牌名）。新的接在后面：色调总览、缩略图里旧的位置不变。
enum CollageLook: String, Codable, CaseIterable, Hashable {
    case none, film, airy, faded, cinema, cool, mono, sepia
    /// 报纸黑白（墨不纯黑、纸不纯白）、高反差黑白（瑞士网格）、哑光（留白杂志）、雅致（婚礼 fine-art）。
    case newsprint, contrastMono, muted, fineArt

    /// 黑白、旧照、报纸、高反差：去色永远是全的，强度只管影调（强度 0 也是黑白）。
    var isMonochrome: Bool {
        switch self {
        case .mono, .sepia, .newsprint, .contrastMono: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .none: return "原色"
        case .film: return "胶片"
        case .airy: return "日系"
        case .faded: return "复古"
        case .cinema: return "电影"
        case .cool: return "冷淡"
        case .mono: return "黑白"
        case .sepia: return "旧照"
        case .newsprint: return "报纸"
        case .contrastMono: return "高反差"
        case .muted: return "哑光"
        case .fineArt: return "雅致"
        }
    }
}

/// 网点的网型：圆点（CIDotScreen，报纸照片）/ 线网（CILineScreen，老报纸、木刻感）。
enum CollageScreen: String, Codable, CaseIterable, Hashable {
    case dot, line

    var label: String { self == .dot ? "圆点" : "线网" }
}

/// 照片加网（报纸风）：去色 → 转到 sRGB 数值上加网（线性光里加网中间调会发闷）→ 压到 [0.06, 0.94]（不然暗部、
/// 高光整块变死）→ 网点增大曲线 → 加网 → 转回线性 → 墨色 / 纸色上色（R5 §4）。点距按画布短边的比例定，
/// 预览、导出、印刷一样粗；实际不到 3 像素（预览缩得小、缩略图）只调影调不出点，免得摩尔纹。
struct CollageHalftone: Codable, Hashable {
    var screen: CollageScreen = .dot
    /// 点距，相对画布短边（0.004：1440 宽约 5.8 像素、A4 300dpi 约 9.9 像素 —— 看得见的网点）。
    var pitch = 0.004
    /// 网角（度）：黑版 45°。
    var angle = 45.0
    /// 网点边缘锐度 0…1（0.6–0.75 像油墨洇开，0.9 以上是波普风的硬点）。
    var sharpness = 0.7
    /// 墨色。
    var ink: CollageColor = .ink
    /// 纸色；nil = 跟着页面底色（照片里的白就是这张纸的颜色）。
    var paper: CollageColor?
    /// 网点增大（印报纸时中间调发暗的那一截）0…1：1 = 按新闻纸实测曲线，0.5 = 一半。
    var gain = 0.5

    /// 点距能取的范围（解码、halftone:、检视器滑杆同一个）：0.5‰ 反正退成只调影调，50‰ 已经是几个大黑点。
    static let pitchRange: ClosedRange<Double> = 0.0005...0.05

    init(screen: CollageScreen = .dot, pitch: Double = 0.004) {
        self.screen = screen
        self.pitch = pitch
    }
}

/// 一页 / 一格单独的色调（成套、整章黑白、黑白彩色混排）：优先级 格 > 页 > 工程（style.look）。
struct CollageLookSetting: Codable, Hashable {
    var look: CollageLook = .none
    /// 强度 0…1。
    var strength = 0.8
    /// 模板自带的（比如红字压在照片上的模板给照片格配的黑白），不是用户设的：换模板时不跟着照片带进新版式
    /// （CollageLayout.carryCellLooks）。旧工程 = false。
    var fromTemplate = false

    init(look: CollageLook = .none, strength: Double = 0.8, fromTemplate: Bool = false) {
        self.look = look
        self.strength = strength
        self.fromTemplate = fromTemplate
    }
}

/// 四边边距（相对画布短边）：上、下、内（订口）、外（切口）。单页时内 = 左、外 = 右；相册跨页的内 = 每页靠
/// 中缝的那一侧（中缝两边各留这么宽），外 = 跨页左右两头。
struct CollageInsets: Codable, Hashable {
    var top: Double
    var bottom: Double
    var inner: Double
    var outer: Double

    init(top: Double, bottom: Double, inner: Double, outer: Double) {
        self.top = top
        self.bottom = bottom
        self.inner = inner
        self.outer = outer
    }

    /// 四边都是 0（零边距：照片铺进出血）。
    var isZero: Bool { max(top, bottom, inner, outer) <= 0.0001 }
}

enum CollageBackgroundMode: String, Codable, CaseIterable, Hashable {
    /// 用 style.background
    case solid
    /// 从主图取色（压低饱和、往纸白靠）
    case fromPhoto
    /// 主图大幅模糊铺满整页，上面盖一层底色（毛玻璃）；盖多少按版面上的字看得清自动定。
    case blurPhoto
    /// 主图上下两截的颜色做竖向渐变（压低饱和、往底色靠）。
    case gradient

    var label: String {
        switch self {
        case .solid: return "纯色"
        case .fromPhoto: return "主图取色"
        case .blurPhoto: return "主图模糊"
        case .gradient: return "主图渐变"
        }
    }

    /// 底色块（纸白、墨黑……）在这个模式里是不是还起作用：模糊、渐变时它是盖在上面的那层纸色。
    var usesPaperTint: Bool { self == .blurPhoto || self == .gradient }
}

struct CollageStyle: Codable, Hashable {
    /// 外边距，相对画布短边。
    var margin: Double = 0.045
    /// 缝宽，相对画布短边。
    var gutter: Double = 0.011
    /// 圆角半径（shape == .rounded 时），相对短边。
    var corner: Double = 0.012
    var shape: CollageShape = .rect
    var background: CollageColor = .paper
    var backgroundMode: CollageBackgroundMode = .solid
    /// 纸纹 0…1。
    var grain: Double = 0
    var border: CollageBorder = .none
    var borderColor: CollageColor = .white
    /// 投影 0…1。
    var shadow: Double = 0
    /// 输出锐化强度（CIUnsharpMask intensity）。
    var sharpen: Double = 0.4
    /// 自动景别：面积排在后一半的小格按人脸收成半身近景（原型里明显更高级的那一版）。
    var tightSmallCells = true
    /// 整组照片套同一个色调。
    var look: CollageLook = .none
    /// 色调强度 0…1。
    var lookStrength = 0.8
    /// 统一到主图：其余照片的色温、明暗往主图靠，0 = 不动。
    var harmonize = 0.0
    /// 四边不一样的边距（留白杂志、婚礼相册）；nil = 四边都是 margin（旧行为）。
    var insets: CollageInsets?
    /// 照片加网（报纸风）；nil = 不加。加网的照片不再锐化（锐化会在网点边上起白边）。
    var halftone: CollageHalftone?
    /// 卡纸边（border == .mat）每边多宽，相对格子短边；底边再加宽两成（装裱的 bottom weighting）。
    var matWidth = 0.07
    /// 纸纹压在照片上 0…1（报纸、fine-art：照片像印在这张纸上）：纸纹柔光叠上去、照片的白往纸色乘一点。
    /// 0 = 照片上不叠（旧行为：纸纹只在格子底下）。
    var paperOverPhotos = 0.0

    init() {}
}

// MARK: - 画布

enum CollageSeams: String, Codable, CaseIterable, Hashable {
    /// 单张
    case none
    /// 朋友圈九宫格：1:1 切 3×3
    case grid9
    /// 小红书轮播：横向切 slides 张
    case carousel
    /// 相册跨页：中缝
    case fold
}

/// 相册装订：决定照片能不能跨中缝、中缝两边让出多宽。
enum CollageBinding: String, Codable, CaseIterable, Hashable {
    /// 平铺对裱 / 对裱精装：整个跨页摊平，全景大图可以铺满两页（中缝两侧仍不放脸）。
    case layflat
    /// 胶装 / 锁线：书脊会吃掉中间一条，照片不跨缝，中缝两侧各让 12mm。
    case glued

    var label: String {
        switch self {
        case .layflat: return "平铺对裱"
        case .glued: return "胶装锁线"
        }
    }
}

struct CollageCanvas: Codable, Hashable {
    var name: String = "小红书 3:4"
    /// 成品（裁切后）像素。
    var width: Int = 1440
    var height: Int = 1920
    var dpi: Double = 72
    /// 每边出血像素（印刷）。
    var bleed: Int = 0
    /// 安全区内缩像素（印刷：文字和脸别出这条线）。
    var safe: Int = 0
    var seams: CollageSeams = .none
    /// 轮播张数。
    var slides: Int = 1
    /// 相册跨页的装订方式（只对 seams == .fold 有意义）。
    var binding: CollageBinding = .layflat

    init() {}

    init(name: String, width: Int, height: Int, dpi: Double = 72, bleed: Int = 0, safe: Int = 0,
         seams: CollageSeams = .none, slides: Int = 1) {
        self.name = name
        self.width = width
        self.height = height
        self.dpi = dpi
        self.bleed = bleed
        self.safe = safe
        self.seams = seams
        self.slides = slides
    }

    var shortSide: Double { Double(min(width, height)) }
    var aspect: Double { Double(width) / Double(max(1, height)) }
    var isPrint: Bool { dpi >= 150 }

    /// 毫米 → 成品像素（按这张画布的 dpi）。
    func pixels(mm: Double) -> Double { mm / 25.4 * dpi }

    /// 中缝每一侧让出多宽（成品像素）：脸、相纸、字都不压进这条带。平铺 = 短边 2%（30×30cm 约 6mm）；
    /// 胶装再放宽到至少 12mm（书脊吃掉的一条加裁切误差）。只对相册跨页有意义。
    var foldBand: Double {
        let base = shortSide * 0.02
        guard binding == .glued else { return base }
        return max(base, pixels(mm: 12))
    }

    /// 照片能不能横跨中缝（整版全景大图）：只有平铺对裱可以。
    var allowsCrossFold: Bool { seams != .fold || binding == .layflat }

    /// 厘米 → 像素。
    static func px(cm: Double, dpi: Double) -> Int { Int((cm / 2.54 * dpi).rounded()) }

    /// 相册对开跨页：单页 pageCM × pageCM（方册）或自定义宽高，跨页宽 ×2。
    static func spread(name: String, pageWidthCM: Double, pageHeightCM: Double, dpi: Double = 300,
                       bleedMM: Double = 3, safeMM: Double = 5) -> CollageCanvas {
        CollageCanvas(name: name,
                      width: px(cm: pageWidthCM * 2, dpi: dpi),
                      height: px(cm: pageHeightCM, dpi: dpi),
                      dpi: dpi,
                      bleed: px(cm: bleedMM / 10, dpi: dpi),
                      safe: px(cm: safeMM / 10, dpi: dpi),
                      seams: .fold)
    }

    static let social: [CollageCanvas] = [
        CollageCanvas(name: "小红书 3:4", width: 1440, height: 1920),
        CollageCanvas(name: "朋友圈 1:1", width: 2160, height: 2160),
        // 3240² 切出来每张 1080×1080：微信朋友圈超过 1080 才压，以前 2160² 每张只有 720。
        CollageCanvas(name: "九宫格 1:1", width: 3240, height: 3240, seams: .grid9),
        CollageCanvas(name: "Instagram 4:5", width: 1728, height: 2160),
        CollageCanvas(name: "故事 9:16", width: 1440, height: 2560),
        CollageCanvas(name: "横幅 16:9", width: 2560, height: 1440),
        CollageCanvas(name: "轮播 3 张 3:4", width: 4320, height: 1920, seams: .carousel, slides: 3),
        CollageCanvas(name: "A4 竖 300dpi", width: 2480, height: 3508, dpi: 300,
                      bleed: px(cm: 0.3, dpi: 300), safe: px(cm: 0.5, dpi: 300)),
    ]

    static let albums: [CollageCanvas] = [
        spread(name: "相册 30×30cm 跨页", pageWidthCM: 30, pageHeightCM: 30),
        spread(name: "相册 25×25cm 跨页", pageWidthCM: 25, pageHeightCM: 25),
        spread(name: "相册 20×20cm 跨页", pageWidthCM: 20, pageHeightCM: 20),
        spread(name: "相册 30×20cm 横版跨页", pageWidthCM: 30, pageHeightCM: 20),
    ]
}


// MARK: - 自由图层（手账：斜放的相纸、胶带、贴纸、手写字）
//
// 切分树之外的一层，按数组顺序从下往上画。散落版的页面整页都是这一层（freeform）；
// 网格版上面也可以贴胶带、加手写字。位置用画布比例、大小用画布短边，换画布比例不变形。

enum CollageItemKind: String, Codable, Hashable {
    case photo, text, sticker
}

enum CollageItemFrame: String, Codable, CaseIterable, Hashable {
    case polaroid, white, none, film, mounts

    var label: String {
        switch self {
        case .polaroid: return "相纸"
        case .white: return "白边"
        case .none: return "无框"
        case .film: return "胶片"
        case .mounts: return "相角"
        }
    }
}

enum CollageSticker: String, Codable, CaseIterable, Hashable {
    case washi, stripe, dots, kraft, label, postmark, clip
    /// 装饰条码（封面右下角那种；只是装饰，编的是日期或随机串，不是能扫的商品码 / 书号 / 刊号）。
    case barcode
    /// 油性笔记号（印样上圈片、打叉）：圈 / 叉 / 点 / 裁切线，手绘抖动，见 CollagePencil。
    case greasePencil

    var label: String {
        switch self {
        case .washi: return "和纸胶带"
        case .stripe: return "条纹胶带"
        case .dots: return "圆点胶带"
        case .kraft: return "牛皮纸胶带"
        case .label: return "标签"
        case .postmark: return "邮戳"
        case .clip: return "回形针"
        case .barcode: return "条码"
        case .greasePencil: return "油性笔"
        }
    }

    var isTape: Bool { self == .washi || self == .stripe || self == .dots || self == .kraft }

    /// 默认宽、高（相对画布短边）。条码：3:4 封面上约 17%W × 9%H（R6）；油性笔圈：圈住一格小照片那么大。
    var defaultSize: (w: Double, h: Double) {
        switch self {
        case .washi, .stripe, .dots, .kraft: return (0.16, 0.042)
        case .label: return (0.2, 0.05)
        case .postmark: return (0.17, 0.17)
        case .clip: return (0.035, 0.1)
        case .barcode: return (0.17, 0.11)
        case .greasePencil: return (0.26, 0.2)
        }
    }

    var defaultColor: CollageColor {
        switch self {
        case .washi: return CollageColor(hex: 0xE9C8B8)
        case .stripe: return CollageColor(hex: 0x9FB4C7)
        case .dots: return CollageColor(hex: 0xEFD9A7)
        case .kraft: return CollageColor(hex: 0xC4A27A)
        case .label: return CollageColor(hex: 0xF7F3EA)
        case .postmark: return CollageColor(hex: 0x3F5A86)
        case .clip: return CollageColor(hex: 0x9A9EA3)
        // 条码的颜色是底色（白底黑条）。
        case .barcode: return .white
        case .greasePencil: return CollagePencilMark.red
        }
    }
}

/// 油性笔画的是什么：圈（选中的那张）、叉（不要的）、点（小记号）、裁切线（放大时裁到哪）。
enum CollagePencilMark: String, Codable, CaseIterable, Hashable {
    case circle, cross, dot, cropLine

    var label: String {
        switch self {
        case .circle: return "圈"
        case .cross: return "叉"
        case .dot: return "点"
        case .cropLine: return "裁切线"
        }
    }

    /// 记号的外框是它标的那一帧（格子、相纸）的多少倍：圈是外接椭圆（R2：半轴 0.62–0.78 × 帧，取 1.4 倍），
    /// 叉就是那一帧，裁切线画在帧里面，点是帧上的一小团。换记号时按它换算大小。
    var frameScale: Double {
        switch self {
        case .circle: return 1.4
        case .cross: return 1.0
        case .cropLine: return 0.85
        case .dot: return 0.16
        }
    }

    /// 油性笔常见的几种颜色（R2 §7，建议值）：红是主流，深底上用白。
    static let red = CollageColor(hex: 0xC8302A)
    static let white = CollageColor(hex: 0xF0EDE4)
    static let orange = CollageColor(hex: 0xE07A1F)
    static let yellow = CollageColor(hex: 0xE8C547)
    static let green = CollageColor(hex: 0x3E8E4F)
    static let palette: [(name: String, color: CollageColor)] = [
        ("红", red), ("白", white), ("橙", orange), ("黄", yellow), ("绿", green),
    ]
}

struct CollageItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: CollageItemKind = .sticker
    /// 中心，相对画布宽、高（0…1，可以略出界）。
    var cx = 0.5
    var cy = 0.5
    /// 外框宽、高，相对画布短边。
    var width = 0.3
    var height = 0.3
    /// 顺时针，度。
    var rotation = 0.0
    // 照片
    var photoID: String?
    var frame: CollageItemFrame = .polaroid
    var framing: CollageFraming = .auto
    /// 相纸下沿的手写字（支持占位符）。
    var caption = ""
    /// 投影 0…1。
    var shadow = 0.5
    var role: CollageRole = .auto
    /// 抠图贴纸：只画主体（主体蒙版），不画相纸框；nil = 照常。认不出主体时照常画整张。
    var cutout: CollageCutout?
    // 文字
    var text: CollageText?
    // 贴纸
    var sticker: CollageSticker = .washi
    var color = CollageColor(hex: 0xE9C8B8)
    /// 标签、邮戳上的字、条码编的字（支持占位符）。
    var label = ""
    /// 油性笔画什么（sticker == .greasePencil）。
    var mark: CollagePencilMark = .circle
    /// 散落版自动撒出来的相纸、胶带：「换一批」时换新的；手动加的留着。
    var generated = false
    /// 贴在哪张相纸上（胶带、回形针）：相纸挪、转、缩放、换一批，它都跟着走。
    var attach: CollageAttachment?
    /// 网格切散落时由第几个文字格转来的字：切回网格时变回那个文字格。
    var sourceCell: Int?

    init(kind: CollageItemKind = .sticker) { self.kind = kind }
}

/// 贴纸贴在一张相纸上的位置：相纸局部坐标里的中心（相对相纸宽、高）和相对角度。
struct CollageAttachment: Codable, Hashable {
    /// 那张相纸的图层 id。
    var to: UUID
    var x: Double
    var y: Double
    /// 相对相纸的角度（度）。
    var angle: Double
}

/// 散落版的生成参数：模板带着它，「换一批」按它重新撒。
struct CollageScatterSpec: Codable, Hashable {
    var frame: CollageItemFrame = .polaroid
    /// 最大倾斜角（度）。
    var tilt = 6.0
    /// 贴胶带的照片比例 0…1。
    var tape = 0.6
    var tapes: [CollageSticker] = [.washi, .stripe, .kraft]
    /// 主图相纸下沿的手写字；空 = 不写。
    var caption = "{date}"
    /// 松散：1 = 刚好铺开、几乎不叠；越大叠得越多。
    var spread = 1.12
    /// 模板用：几张照片。
    var count = 5
    /// 底部留给模板固定文字的高度（画布比例）。
    var reserveBottom = 0.0

    init() {}
}

// MARK: - 水印（工程自带的快照）
//
// 水印页的设置带进拼图时换算成这里的结构（Collage/CollageWatermark.swift）：边距、字号都存成相对
// 区域的比例，同一份设置套到大小不一的格子、整页上都成比例。相框和画布比例不进来（会改画布尺寸）。

/// 拼图里的水印：工程自带的快照（不跟水印页联动；改水印页预设不会悄悄改掉已存的拼图）。
struct CollageWatermark: Codable, Hashable {
    /// 每张照片各一个，画在裁切后看得见的那块里。nil = 关。
    var photos: CollageMarkLayer?
    /// 整页一个（相册按半页、九宫格按片）。nil = 关。
    var page: CollageMarkLayer?
    /// 签名图副本（两层共用）。
    var signature: CollageSignature?
    /// 这些照片不加「每张照片」水印（按照片 id：互换、换一批都跟着照片走）。
    var skipPhotoIDs: Set<String> = []
    /// 九宫格 / 轮播的整页层：每片一个 / 整张一次。默认整张一次（「整张拼图加一个」就是一个）。
    var tiles: CollageMarkTiles = .once
    /// 相册的整页层：只放右页 / 左右两页。
    var albumSides: CollageMarkSides = .right
    /// 导出带水印。跟着这个拼图存（以前是全局设置：关过一次，之后别的拼图预览有水印、导出却没有）。
    var exportEnabled = true

    init() {}
}

enum CollageMarkTiles: String, Codable, CaseIterable, Hashable {
    case eachTile, once
}

enum CollageMarkSides: String, Codable, CaseIterable, Hashable {
    case right, both
}

/// 水印的深浅：原色 / 自动（按落点底下的亮度在白、黑里选）/ 白 / 黑。
enum CollageMarkContrast: String, Codable, CaseIterable, Hashable {
    case original, auto, light, dark
}

struct CollageSignature: Codable, Hashable {
    /// <dataDir>/collage/assets/<sha1>.png 的绝对路径（导入时拷一份，原文件挪走也不影响）。
    var file: String
    /// 内容 sha1（hex），解码缓存的键。
    var key: String
    /// 原文件名，只用来显示。
    var sourceName: String
}

/// 平铺：签名斜着铺满整块区域。
struct CollageMarkTile: Codable, Hashable {
    var angleDeg = 30.0
    /// 间距，相对签名尺寸。
    var gapRatio = 0.6

    init() {}
}

struct CollageMarkLayer: Codable, Hashable {
    var signatureOn = true
    var position: WatermarkEngine.GridPosition = .bottomRight
    /// 横向区域（宽 ≥ 高）用的位置；nil = 同 position。按「区域」的宽高判断，不按原图。
    var landscapePosition: WatermarkEngine.GridPosition?
    /// 签名宽 = 区域短边 × sizeRatio（与 targetWatermarkWidth 同一公式）。
    var sizeRatio = 0.15
    var opacity = 0.8
    /// 边距 = 区域短边 × marginRatio。
    var marginRatio = 0.02
    /// nil = 签名原色。
    var tint: CollageColor?
    var tile: CollageMarkTile?
    var text: CollageMarkText?
    /// 从哪个预设来的（只显示）。
    var presetName: String?
    /// 深浅。original = 签名原色（tint 非 nil 就照 tint 染）、字用设定颜色；light / dark = 签名和字都是白 /
    /// 近黑（不看 tint）；auto = 按落点底下的亮度在 light / dark 里选。新建的、从水印页拿来的都是 original：
    /// 和水印页看到的一样，彩色 logo 也不会被默认染成纯白 / 纯黑。
    var contrast: CollageMarkContrast = .original
    /// 整页层：版心外的留白够宽就放进留白里，不压照片（每张照片层不看这个）。
    var preferMargin = true

    init() {}
}

struct CollageMarkText: Codable, Hashable {
    var template = "{make} {model} · {lens} · f/{fnumber} · {shutter}s · ISO {iso}"
    /// 非空 = 直接用这段字（可含 {title} {date} 等占位符），忽略 template。
    var customText = ""
    /// × 区域长边。
    var fontSizeRatio = 0.03
    var position: WatermarkEngine.GridPosition = .bottomLeft
    /// 边距 = 区域短边 × marginRatio。
    var marginRatio = 0.02
    var opacity = 0.85
    var color = CollageColor.white
    var backgroundEnabled = true
    var backgroundColor = CollageColor(r: 0, g: 0, b: 0)
    var backgroundAlpha = 80.0 / 255
    var fullWidth = false

    init() {}
}

// MARK: - 印样 / 底片条（整页由 CollageContact 画，切分树不画，同散落版）

/// 胶片规格。尺寸照 R2 §1、§4（mm）：135 片宽 34.975、每帧 8 个齿孔；120 片宽 61.2、没有齿孔。
enum CollageFilmFormat: String, Codable, CaseIterable, Hashable {
    case f135 = "135", f645 = "645", f66 = "66", f67 = "67"

    var label: String {
        switch self {
        case .f135: return "135"
        case .f645: return "6×4.5"
        case .f66: return "6×6"
        case .f67: return "6×7"
        }
    }

    /// 一卷几张（R2 §4）：135 = 36，6×4.5 = 16（15–16），6×6 = 12，6×7 = 10。印样没给「条数 × 每条帧数」时
    /// 一页最多排这么多帧（一页 = 一卷）。
    var rollLength: Int {
        switch self {
        case .f135: return 36
        case .f645: return 16
        case .f66: return 12
        case .f67: return 10
        }
    }
}

/// 印样（白相纸上一块黑场、片条排在里面、白边手写卷号）/ 底片条（一条条放在页面底色上、带投影：社交图、深色底）。
enum CollageContactLayout: String, Codable, CaseIterable, Hashable {
    case sheet, strip

    var label: String { self == .sheet ? "印样" : "底片条" }
}

/// 一页放不下全部照片时上哪几帧（CollageContactSheet.choice）。
enum CollageContactChoice: String, Codable, CaseIterable, Hashable {
    case roll, best

    var label: String { self == .roll ? "按拍摄先后" : "每场最好的一张" }
}

/// 一页印样：一卷的帧、规格、排法、记号、片边字。帧按顺序排进片条（帧号在卷内连续）。
struct CollageContactSheet: Codable, Hashable {
    var format: CollageFilmFormat = .f135
    var layout: CollageContactLayout = .sheet
    /// 这一卷的帧（照片 id，按拍摄先后；托盘里没有的照片画成没曝光的黑帧）。
    var frames: [String] = []
    /// 每条几帧、几条：0 = 按帧数和页面自动（帧越大越好）。条数给定时页面按这么多条留位置（短卷下面空着）。
    var perStrip = 0
    var strips = 0
    /// 竖片立起来（易读）：默认 false = 和真的印样一样，竖拍转 90° 躺在条里（6×4.5 反过来转横片）。
    var uprightPortraits = false
    /// 裁满画幅（按人脸取景）：默认 false = 比例不符加黑边（没曝光的片基），不裁掉照片。
    var fillFrames = false
    /// 自动记号：每场（take）最好的那张精选画圈（手动的优先），一页最多 maxCircles 个。
    var marks = true
    /// 一页最多自动圈几个（R2 §7：每页最多 6 个圈）；0 = 不限。同一场只圈一个，不同场之间不再限密度。
    var maxCircles = 6
    /// 废片打叉。
    var crossRejects = true
    /// 手动定的记号：照片 id → circle / cross / dot / cropLine / none（不画）。没写的按上面两条自动。
    var markOverrides: [String: String] = [:]
    /// 油性笔颜色（圈、叉、手写注记）。默认红，深色底上常用白。
    var markColor = CollagePencilMark.red
    /// 卷号：nil = 页码。
    var roll: Int?
    /// 白边上的手写注记（占位符：{roll} {date} {first} {last} {frames} 和页面的占位符）；空 = 不写。
    var note = "ROLL {roll} · {date} · {first}–{last}"
    /// 片边字：只印通用字样（不印任何胶片品牌、片种代码，不画 DX 码）+ ISO 数字；帧号、▶ 另外印。
    var edgeText = "SAFETY FILM"
    var iso = "400"
    /// 片边字、帧号印不印。
    var edgePrint = true
    /// 每条随机微转 ±0.3–0.8°、横向错位 ±1–2 mm（种子固定）：不排成完美网格。
    var jitter = true
    /// 整体倾斜（度）：底片条斜放。
    var tilt = 0.0
    /// 纸张四周留白（画布短边的比例）。
    var margin = 0.05
    /// 条与条之间的缝（片宽的比例）；nil = 按排法：印样 2%（压片玻璃下挨着的一道细缝，DESIGN 1–3%），
    /// 底片条 18%（一条条分开放在页面上，给投影留地方）。
    var stripGap: Double?
    /// 这一页的纸（印样的相纸、底片条垫的纸）：设了就是这一页的底色（纯色，盖过工程的底色 / 取色底），
    /// nil = 跟着工程的底色。检视器里换「排法」时换成那种排法的纸（CollageContact.defaultPaper）。
    var paper: CollageColor?
    /// 照片比一页放得下的多时上哪几帧：roll = 按拍摄先后的前 N 张（一卷从头印）；best = 每场挑一张最好的
    /// （精选、手动的优先），凑够 N 张再按拍摄先后排（社交底片条：三帧就是三个不同的瞬间）。
    var choice: CollageContactChoice = .roll

    init() {}

    init(format: CollageFilmFormat, layout: CollageContactLayout = .sheet, perStrip: Int = 0, strips: Int = 0) {
        self.format = format
        self.layout = layout
        self.perStrip = perStrip
        self.strips = strips
    }

    /// 一页放得下几帧（条数、每条帧数都给定时）；nil = 自动排（最多一卷，见 frameLimit）。
    var capacity: Int? { perStrip > 0 && strips > 0 ? perStrip * strips : nil }

    /// 一页最多放几帧：条数、每条帧数都给定 = 那么多格；否则 = 一卷的长度（135 36 张，120 按画幅 16 / 12 / 10 张）。
    /// 再多的记成放不下（overflow）：托盘两百张不会排成一卷两百帧、帧号 ▶200A 的「135」。
    var frameLimit: Int { capacity ?? format.rollLength }

    /// 整体倾斜的范围：±90°（−90 = 竖着放的一条：竖片转回来正好立着，帧从下往上排）。
    static let tiltRange: ClosedRange<Double> = -90...90
    static let marginRange: ClosedRange<Double> = 0...0.25
    static let stripGapRange: ClosedRange<Double> = 0...0.4
    static let maxCirclesRange: ClosedRange<Int> = 0...36

    /// 实际用的条缝（片宽的比例）。
    var effectiveStripGap: Double { stripGap ?? (layout == .sheet ? 0.02 : 0.18) }
}

// MARK: - 项目 / 页 / 模板

enum CollageMode: String, Codable, Hashable {
    case single, album
}

struct CollagePage: Codable, Hashable, Identifiable {
    var id = UUID()
    var root: CollageNode
    /// 切分树上面的自由图层（从下往上）。
    var items: [CollageItem] = []
    /// 散落版：整页都是自由图层，切分树不画。
    var freeform = false
    /// 散落版「换一批」用的参数（切回网格也留着，再切散落照原来的撒法）。
    var scatter: CollageScatterSpec?
    /// 散落版记着切过来之前的网格：切回网格时文字格、照片上的字照着恢复。
    var gridRoot: CollageNode?
    /// 这一页单独的色调（整章黑白、成套里每页不同）；nil = 跟工程。格子自己设了的以格子为准。
    var look: CollageLookSetting?
    /// 印样 / 底片条：整页由它画（CollageContact），切分树不画（同散落版）；nil = 普通页。
    var contactSheet: CollageContactSheet?
    /// 这一页是套固定比例的模板（fitAspects = false，严格栅格）来的：存成「我的模板」时「按照片比例自适应」
    /// 默认关，存出来的格子比例和原来一样。旧工程 = false。
    var fixedAspects = false

    init(root: CollageNode) { self.root = root }

    init(root: CollageNode, items: [CollageItem], freeform: Bool, scatter: CollageScatterSpec? = nil,
         gridRoot: CollageNode? = nil) {
        self.root = root
        self.items = items
        self.freeform = freeform
        self.scatter = scatter
        self.gridRoot = gridRoot
    }

    /// 这一页用到的照片：散落版只看图层，网格版是格子 + 图层里的照片，印样是画得出来的帧 + 图层里的照片。
    /// 印样一页放不下的帧（超过 frameLimit，CollageContact.layout 记成 overflow）不算：托盘里不标成用过，
    /// 相册别的跨页能用，也不进页面的 {date}、取色底、统一色调。帧数组里照样记着（改大容量还在）。
    var photoIDs: [String] {
        let fromItems = items.compactMap { $0.kind == .photo ? $0.photoID : nil }
        if let contactSheet { return Array(contactSheet.frames.prefix(contactSheet.frameLimit)) + fromItems }
        return freeform ? fromItems : root.photoIDs + fromItems
    }
}

struct CollageProject: Codable, Hashable {
    var mode: CollageMode = .single
    /// 托盘：带进来的全部照片（顺序 = 带进来的顺序）。
    var photos: [CollagePhotoRef] = []
    var pages: [CollagePage] = []
    var canvas = CollageCanvas()
    var style = CollageStyle()
    /// {title} 占位符。
    var title = ""
    /// {subtitle} 占位符：地点、系列名。
    var subtitle = ""
    /// {masthead} 刊头：空 = 用标题（拉丁字母转大写，纯中文转拼音大写）。不预置任何真实刊名。
    var masthead = ""
    /// {issue} 期号：空 = 用页码 {no}。
    var issue = ""
    /// 水印（每张照片 / 整页）；nil = 没加过。
    var watermark: CollageWatermark?
    /// 相册「自动编排」用哪套规则（一键成套「整本婚礼相册」设成 fineArt）；旧工程 = 默认。
    var albumTheme: CollageAlbumTheme = .classic
    /// fine-art 编排的「整章黑白」：一章里黑白照片占三分之一以上，整章都转黑白。
    var albumChapterMono = true

    init() {}

    func photo(_ id: String?) -> CollagePhotoRef? {
        guard let id else { return nil }
        return photos.first { $0.id == id }
    }

    /// 已经上了任何一页的照片 id（格子和自由图层）。
    var usedPhotoIDs: Set<String> { Set(pages.flatMap(\.photoIDs)) }
}

struct CollageTemplate: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    /// 照片叶子只带角色，photoID 为空。
    var root: CollageNode
    var style: CollageStyle?
    var canvas: CollageCanvas?
    /// 套用时按照片原比例重算 ratio（智能模板）；false = 固定比例、照片按格裁（严格网格、月洞门）。
    var fitAspects = true
    var builtin = false
    /// 模板库里的分组（小红书封面、日系杂志……）。
    var category = ""
    /// 固定的自由图层（胶带、贴纸、手写字；自己存的散落版连照片位置一起）。
    var items: [CollageItem] = []
    /// 散落版：套用时按这组参数现撒（照片张数、比例随你的照片）。
    var scatter: CollageScatterSpec?
    /// 存的是散落版（items 里的照片就是版面）。
    var freeform = false
    /// 自己存的散落版原来的撒法：套用时照原样摆，之后「换一批」按它重撒（相角、不贴胶带、底部留字）。
    var pageScatter: CollageScatterSpec?
    /// 存的时候画布的宽高比：散落版套到比例差得多的画布上（单张存的套进相册跨页）要按撒法重撒。
    var savedAspect: Double?
    /// 印样 / 底片条模板：套用时托盘照片按拍摄先后排进去（frames 存的时候清空）。
    var contactSheet: CollageContactSheet?

    init(name: String, root: CollageNode, style: CollageStyle? = nil, canvas: CollageCanvas? = nil,
         fitAspects: Bool = true, builtin: Bool = false, category: String = "",
         items: [CollageItem] = [], scatter: CollageScatterSpec? = nil, freeform: Bool = false,
         contactSheet: CollageContactSheet? = nil) {
        self.name = name
        self.root = root
        self.style = style
        self.canvas = canvas
        self.fitAspects = fitAspects
        self.builtin = builtin
        self.category = category
        self.items = items
        self.scatter = scatter
        self.freeform = freeform || scatter != nil
        self.contactSheet = contactSheet
    }

    var photoSlots: Int {
        // 印样：一卷能放多少放多少（条数、每条帧数给定 = 那么多格；自动 = 一卷：135 36 张，120 16 / 12 / 10 张）。
        if let contactSheet { return contactSheet.frameLimit }
        if let scatter { return scatter.count }
        let inItems = items.filter { $0.kind == .photo }.count
        if freeform { return inItems }
        return root.leaves.filter { $0.kind == .photo }.count + inItems
    }
}

// MARK: - 容错解码

/// 数组里某一项坏了只丢那一项（一条照片缺 path 不能让整个托盘清空）。
private struct Failable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    /// 字段缺失或类型不对 → 用默认值。
    func soft<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func softOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

extension CollageColor {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = c.soft(.r, 1)
        g = c.soft(.g, 1)
        b = c.soft(.b, 1)
    }
}

extension CollagePhotoRef {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        previewPath = c.softOptional(.previewPath)
        width = max(1, c.soft(.width, 3))
        height = max(1, c.soft(.height, 2))
        faces = c.soft(.faces, [[Double]]()).filter(CollageCrop.isValidBox)
        score = c.soft(.score, 0)
        isPick = c.soft(.isPick, false)
        take = c.softOptional(.take)
        chapter = c.softOptional(.chapter)
        captureTime = c.softOptional(.captureTime)
        faceAreaPct = c.softOptional(.faceAreaPct)
        burstGroup = c.softOptional(.burstGroup)
        takeRank = c.softOptional(.takeRank)
        frameNo = c.softOptional(.frameNo)
        captureSubsec = c.softOptional(.captureSubsec)
        verdict = c.softOptional(.verdict)
        isManual = c.soft(.isManual, false)
        eyesOpen = c.softOptional(.eyesOpen)
        exif = c.softOptional(.exif)
        body = c.softOptional(.body)
        isMonochrome = c.softOptional(.isMonochrome)
        meanLuma = c.softOptional(.meanLuma)
    }
}

extension CollageCropOverride {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cx = c.soft(.cx, 0.5)
        cy = c.soft(.cy, 0.5)
        zoom = c.soft(.zoom, 1)
    }
}

extension CollageCell {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.soft(.kind, .empty)
        photoID = c.softOptional(.photoID)
        text = c.softOptional(.text)
        framing = c.soft(.framing, .auto)
        crop = c.softOptional(.crop)
        locked = c.soft(.locked, false)
        shape = c.softOptional(.shape)
        role = c.soft(.role, .auto)
        contain = c.soft(.contain, false)
        containBlur = c.soft(.containBlur, false)
        overlay = c.softOptional(.overlay)
        extraOverlays = c.soft(.extraOverlays, [Failable<CollageOverlay>]()).compactMap(\.value)
        // 手改过的 JSON 只有 extraOverlays、没有 overlay：第一个补进 overlay（旧版本至少还认得它）。
        if overlay == nil, !extraOverlays.isEmpty { overlay = extraOverlays.removeFirst() }
        look = c.softOptional(.look)
        cutout = c.softOptional(.cutout)
        coverAuto = c.soft(.coverAuto, false)
    }
}

extension CollageCutout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = c.soft(.stroke, 0.0)
        let d = c.soft(.shadow, 0.0)
        stroke = s.isFinite ? min(0.05, max(0, s)) : 0
        shadow = d.isFinite ? min(1, max(0, d)) : 0
        toEdge = c.soft(.toEdge, false)
    }
}

extension CollageNode {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        axis = c.soft(.axis, .row)
        let r = c.soft(.ratio, 0.5)
        ratio = r.isFinite ? min(0.96, max(0.04, r)) : 0.5
        children = c.soft(.children, [])
        cell = c.softOptional(.cell)
        if children.count != 2 {
            children = []
            if cell == nil { cell = CollageCell() }
        }
    }
}

extension CollageTextLine {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.soft(.text, "")
        font = c.soft(.font, .songti)
        weight = c.soft(.weight, .regular)
        italic = c.soft(.italic, false)
        size = c.soft(.size, 0.04)
        tracking = c.soft(.tracking, 0)
        color = c.soft(.color, .ink)
        indent = c.soft(.indent, 0)
        let fx: CollageTextEffect? = c.softOptional(.effect)
        effect = fx.flatMap { $0.isEmpty ? nil : $0 }
        fitWidth = c.soft(.fitWidth, false)
        let ws = c.soft(.widthScale, 1.0)
        widthScale = ws.isFinite ? min(1, max(0.85, ws)) : 1
        textCase = c.soft(.textCase, .none)
        overflow = c.soft(.overflow, .block)
        let gs = c.soft(.glyphScale, 1.0)
        glyphScale = gs.isFinite ? min(1, max(0.1, gs)) : 1
        spreadShort = c.soft(.spreadShort, false)
        accentFromPhoto = c.soft(.accentFromPhoto, false)
        let gate: String? = c.softOptional(.onlyWhenFilled)
        onlyWhenFilled = gate.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension CollageTextEffect {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageTextEffect()
        let finite: (Double, Double) -> Double = { v, fallback in v.isFinite ? v : fallback }
        stroke = min(0.5, max(0, finite(c.soft(.stroke, d.stroke), 0)))
        strokeColor = c.soft(.strokeColor, d.strokeColor)
        shadow = min(1, max(0, finite(c.soft(.shadow, d.shadow), 0)))
        shadowColor = c.soft(.shadowColor, d.shadowColor)
        shadowBlur = min(1, max(0, finite(c.soft(.shadowBlur, d.shadowBlur), d.shadowBlur)))
        shadowOffset = min(0.5, max(0, finite(c.soft(.shadowOffset, d.shadowOffset), d.shadowOffset)))
        band = min(1, max(0, finite(c.soft(.band, d.band), 0)))
        bandColor = c.soft(.bandColor, d.bandColor)
        bandRound = min(1, max(0, finite(c.soft(.bandRound, d.bandRound), d.bandRound)))
        gradient = c.softOptional(.gradient)
    }
}

extension CollageSeal {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.soft(.text, "春")
        color = c.soft(.color, .seal)
        size = c.soft(.size, 0.035)
    }
}

extension CollageText {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = c.soft(.lines, [])
        vertical = c.soft(.vertical, false)
        alignH = c.soft(.alignH, .leading)
        alignV = c.soft(.alignV, .leading)
        let spacing = c.soft(.lineSpacing, 0.35)
        lineSpacing = spacing.isFinite ? max(-0.15, spacing) : 0.35
        rule = c.soft(.rule, false)
        ruleStyle = c.soft(.ruleStyle, .short)
        seal = c.softOptional(.seal)
        // 只认 0 / 90 / −90（270 = −90）；别的角度当 0。
        let r = c.soft(.rotation, 0)
        rotation = r == 90 || r == -270 ? 90 : (r == -90 || r == 270 ? -90 : 0)
        body = c.softOptional(.body)
        paperTone = c.soft(.paperTone, false)
    }
}

extension CollageBody {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageBody()
        let finite: (Double, Double) -> Double = { v, fallback in v.isFinite ? v : fallback }
        text = c.soft(.text, "")
        columns = min(12, max(1, c.soft(.columns, d.columns)))
        justified = c.soft(.justified, d.justified)
        columnRule = c.soft(.columnRule, d.columnRule)
        dropCap = min(6, max(0, c.soft(.dropCap, 0)))
        font = c.soft(.font, d.font)
        weight = c.soft(.weight, d.weight)
        size = min(0.2, max(0.002, finite(c.soft(.size, d.size), d.size)))
        leading = min(4, max(0.8, finite(c.soft(.leading, d.leading), d.leading)))
        firstLineIndent = min(8, max(0, finite(c.soft(.firstLineIndent, d.firstLineIndent), d.firstLineIndent)))
        gap = min(8, max(0.2, finite(c.soft(.gap, d.gap), d.gap)))
        color = c.soft(.color, d.color)
        vertical = c.soft(.vertical, false)
        filler = c.soft(.filler, false)
        traditional = c.soft(.traditional, false)
        balanced = c.soft(.balanced, false)
    }
}

extension CollageStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageStyle()
        margin = c.soft(.margin, d.margin)
        gutter = c.soft(.gutter, d.gutter)
        corner = c.soft(.corner, d.corner)
        shape = c.soft(.shape, d.shape)
        background = c.soft(.background, d.background)
        backgroundMode = c.soft(.backgroundMode, d.backgroundMode)
        grain = c.soft(.grain, d.grain)
        border = c.soft(.border, d.border)
        borderColor = c.soft(.borderColor, d.borderColor)
        shadow = c.soft(.shadow, d.shadow)
        sharpen = c.soft(.sharpen, d.sharpen)
        tightSmallCells = c.soft(.tightSmallCells, d.tightSmallCells)
        look = c.soft(.look, d.look)
        lookStrength = min(1, max(0, c.soft(.lookStrength, d.lookStrength)))
        harmonize = min(1, max(0, c.soft(.harmonize, d.harmonize)))
        insets = c.softOptional(.insets)
        halftone = c.softOptional(.halftone)
        let mat = c.soft(.matWidth, d.matWidth)
        matWidth = mat.isFinite ? min(0.3, max(0.01, mat)) : d.matWidth
        let over = c.soft(.paperOverPhotos, d.paperOverPhotos)
        paperOverPhotos = over.isFinite ? min(1, max(0, over)) : 0
    }
}

extension CollageHalftone {
    /// 坏值按能画的范围收：点距太小没意义（反正退成只调影调），太大就成了几个大黑点。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageHalftone()
        let finite: (Double, Double) -> Double = { v, fallback in v.isFinite ? v : fallback }
        screen = c.soft(.screen, d.screen)
        let range = CollageHalftone.pitchRange
        pitch = min(range.upperBound, max(range.lowerBound, finite(c.soft(.pitch, d.pitch), d.pitch)))
        angle = finite(c.soft(.angle, d.angle), d.angle).truncatingRemainder(dividingBy: 360)
        sharpness = min(1, max(0, finite(c.soft(.sharpness, d.sharpness), d.sharpness)))
        ink = c.soft(.ink, d.ink)
        paper = c.softOptional(.paper)
        gain = min(1, max(0, finite(c.soft(.gain, d.gain), d.gain)))
    }
}

extension CollageLookSetting {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        look = c.soft(.look, .none)
        let v = c.soft(.strength, 0.8)
        strength = v.isFinite ? min(1, max(0, v)) : 0.8
        fromTemplate = c.soft(.fromTemplate, false)
    }
}

extension CollageInsets {
    /// 坏值（负数、NaN、大得离谱）按 0…0.4 收：四边加起来也不会把排版区挤没。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let clamp: (Double) -> Double = { v in v.isFinite ? min(0.4, max(0, v)) : 0 }
        top = clamp(c.soft(.top, 0))
        bottom = clamp(c.soft(.bottom, 0))
        inner = clamp(c.soft(.inner, 0))
        outer = clamp(c.soft(.outer, 0))
    }
}

extension CollageOverlay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.soft(.text, CollageText())
        anchor = c.soft(.anchor, .auto)
        x = min(1, max(0, c.soft(.x, 0.5)))
        y = min(1, max(0, c.soft(.y, 0.5)))
        inset = min(0.3, max(0, c.soft(.inset, 0.06)))
        tone = c.soft(.tone, .auto)
        shadow = min(1, max(0, c.soft(.shadow, 0.45)))
        maxWidth = min(1, max(0.2, c.soft(.maxWidth, 0.86)))
        layer = c.soft(.layer, .front)
        let t = c.soft(.depth, 0.2)
        depth = t.isFinite ? min(0.3, max(0, t)) : 0.2
        let m = c.soft(.maxOcclusion, 0.25)
        maxOcclusion = m.isFinite ? min(0.33, max(0.05, m)) : 0.25
        occlusionRule = c.soft(.occlusionRule, .masthead)
        let z: Double? = c.softOptional(.maxZoom)
        maxZoom = z.flatMap { $0.isFinite && $0 >= 1 ? min(8, $0) : nil }
        tightEdge = c.soft(.tightEdge, false)
        let cb = c.soft(.clearBottom, 0.0)
        clearBottom = cb.isFinite ? min(0.4, max(0, cb)) : 0
        scrim = c.soft(.scrim, true)
        matchTone = c.soft(.matchTone, false)
        let fd = c.soft(.fade, 0.0)
        fade = fd.isFinite ? min(0.7, max(0, fd)) : 0
        let it = c.soft(.inkTop, 0.0)
        inkTop = it.isFinite ? min(0.2, max(0, it)) : 0
    }
}

extension CollageItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        kind = c.soft(.kind, .sticker)
        let finite: (Double, Double) -> Double = { v, d in v.isFinite ? v : d }
        cx = min(1.5, max(-0.5, finite(c.soft(.cx, 0.5), 0.5)))
        cy = min(1.5, max(-0.5, finite(c.soft(.cy, 0.5), 0.5)))
        width = min(3, max(0.005, finite(c.soft(.width, 0.3), 0.3)))
        height = min(3, max(0.005, finite(c.soft(.height, 0.3), 0.3)))
        rotation = finite(c.soft(.rotation, 0), 0).truncatingRemainder(dividingBy: 360)
        photoID = c.softOptional(.photoID)
        frame = c.soft(.frame, .polaroid)
        framing = c.soft(.framing, .auto)
        caption = c.soft(.caption, "")
        shadow = min(1, max(0, c.soft(.shadow, 0.5)))
        role = c.soft(.role, .auto)
        cutout = c.softOptional(.cutout)
        text = c.softOptional(.text)
        sticker = c.soft(.sticker, .washi)
        color = c.soft(.color, sticker.defaultColor)
        label = c.soft(.label, "")
        mark = c.soft(.mark, .circle)
        // v1.12.0 存的没有这个键：那时的胶带基本都是撒出来的（手动贴的换一批也会被换掉）——
        // 按「自动」算，换一批时照旧换新，不会悬空留在新版面上。
        generated = c.contains(.generated) ? c.soft(.generated, false) : (kind == .sticker && sticker.isTape)
        attach = c.softOptional(.attach)
        sourceCell = c.softOptional(.sourceCell)
    }
}

extension CollageScatterSpec {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageScatterSpec()
        frame = c.soft(.frame, d.frame)
        tilt = min(25, max(0, c.soft(.tilt, d.tilt)))
        tape = min(1, max(0, c.soft(.tape, d.tape)))
        tapes = c.soft(.tapes, [Failable<CollageSticker>]()).compactMap(\.value).filter(\.isTape)
        if tapes.isEmpty { tapes = d.tapes }
        caption = c.soft(.caption, d.caption)
        spread = min(1.6, max(0.8, c.soft(.spread, d.spread)))
        count = min(16, max(1, c.soft(.count, d.count)))
        reserveBottom = min(0.4, max(0, c.soft(.reserveBottom, d.reserveBottom)))
    }
}

extension CollageCanvas {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageCanvas()
        name = c.soft(.name, d.name)
        width = min(30000, max(64, c.soft(.width, d.width)))
        height = min(30000, max(64, c.soft(.height, d.height)))
        let dpiValue = c.soft(.dpi, d.dpi)
        dpi = dpiValue.isFinite ? min(1200, max(36, dpiValue)) : d.dpi
        bleed = min(2000, max(0, c.soft(.bleed, d.bleed)))
        safe = min(4000, max(0, c.soft(.safe, d.safe)))
        seams = c.soft(.seams, d.seams)
        slides = min(24, max(1, c.soft(.slides, d.slides)))
        // 旧工程没有这个键：按平铺算（和以前的行为一样）。
        binding = c.soft(.binding, d.binding)
        // v1.13 以前的九宫格预设是 2160²（每张只有 720）：存下来的工程、模板、默认画布读回来升到 3240²。
        // 版式都按比例存，画布等比放大不改任何摆法；手填的「自定义」尺寸名字不一样，不动。
        if seams == .grid9, name == "九宫格 1:1", width == 2160, height == 2160 {
            width = 3240
            height = 3240
        }
    }
}

extension CollagePage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        root = c.soft(.root, CollageNode.leaf(CollageCell()))
        items = c.soft(.items, [Failable<CollageItem>]()).compactMap(\.value)
        freeform = c.soft(.freeform, false)
        scatter = c.softOptional(.scatter)
        gridRoot = c.softOptional(.gridRoot)
        look = c.softOptional(.look)
        contactSheet = c.softOptional(.contactSheet)
        fixedAspects = c.soft(.fixedAspects, false)
    }
}

extension CollageContactSheet {
    /// 坏值按能画的范围收（每条 0…12 帧、最多 12 条、倾斜 ±90°、留白 0…25%、圈 0…36 个、条缝 0…40%）；不认识的规格 = 135。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageContactSheet()
        let finite: (Double, Double) -> Double = { v, fallback in v.isFinite ? v : fallback }
        format = c.soft(.format, d.format)
        layout = c.soft(.layout, d.layout)
        frames = c.soft(.frames, [Failable<String>]()).compactMap(\.value)
        perStrip = min(12, max(0, c.soft(.perStrip, d.perStrip)))
        strips = min(12, max(0, c.soft(.strips, d.strips)))
        uprightPortraits = c.soft(.uprightPortraits, d.uprightPortraits)
        fillFrames = c.soft(.fillFrames, d.fillFrames)
        marks = c.soft(.marks, d.marks)
        let circlesRange = CollageContactSheet.maxCirclesRange
        maxCircles = min(circlesRange.upperBound, max(circlesRange.lowerBound, c.soft(.maxCircles, d.maxCircles)))
        crossRejects = c.soft(.crossRejects, d.crossRejects)
        markOverrides = c.soft(.markOverrides, d.markOverrides)
        markColor = c.soft(.markColor, d.markColor)
        roll = (c.softOptional(.roll) as Int?).map { min(999, max(1, $0)) }
        note = c.soft(.note, d.note)
        edgeText = c.soft(.edgeText, d.edgeText)
        iso = c.soft(.iso, d.iso)
        edgePrint = c.soft(.edgePrint, d.edgePrint)
        jitter = c.soft(.jitter, d.jitter)
        let tiltRange = CollageContactSheet.tiltRange
        tilt = min(tiltRange.upperBound, max(tiltRange.lowerBound, finite(c.soft(.tilt, d.tilt), d.tilt)))
        let marginRange = CollageContactSheet.marginRange
        margin = min(marginRange.upperBound, max(marginRange.lowerBound, finite(c.soft(.margin, d.margin), d.margin)))
        let gapRange = CollageContactSheet.stripGapRange
        stripGap = (c.softOptional(.stripGap) as Double?).flatMap { $0.isFinite ? $0 : nil }
            .map { min(gapRange.upperBound, max(gapRange.lowerBound, $0)) }
        paper = c.softOptional(.paper)
        choice = c.soft(.choice, d.choice)
    }
}

extension CollageProject {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.soft(.mode, .single)
        photos = c.soft(.photos, [Failable<CollagePhotoRef>]()).compactMap(\.value)
        pages = c.soft(.pages, [Failable<CollagePage>]()).compactMap(\.value)
        canvas = c.soft(.canvas, CollageCanvas())
        style = c.soft(.style, CollageStyle())
        title = c.soft(.title, "")
        subtitle = c.soft(.subtitle, "")
        masthead = c.soft(.masthead, "")
        issue = c.soft(.issue, "")
        // 旧工程没有这个键 = nil；坏了也只丢水印，页面照常读回。
        watermark = c.softOptional(.watermark)
        albumTheme = c.soft(.albumTheme, .classic)
        albumChapterMono = c.soft(.albumChapterMono, true)
    }
}

extension CollageWatermark {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photos = c.softOptional(.photos)
        page = c.softOptional(.page)
        signature = c.softOptional(.signature)
        skipPhotoIDs = Set(c.soft(.skipPhotoIDs, [Failable<String>]()).compactMap(\.value))
        // 旧工程存了 eachTile 的照旧读 eachTile；没存 / 坏了 = 新默认（整张一次）。
        tiles = c.soft(.tiles, .once)
        albumSides = c.soft(.albumSides, .right)
        exportEnabled = c.soft(.exportEnabled, true)
    }
}

extension CollageSignature {
    /// 文件和键缺一个就整个不要（没文件的签名画不出来，没键的缓存不住）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        key = try c.decode(String.self, forKey: .key)
        sourceName = c.soft(.sourceName, "")
    }
}

extension CollageMarkTile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageMarkTile()
        angleDeg = min(90, max(-90, c.soft(.angleDeg, d.angleDeg)))
        gapRatio = min(5, max(0, c.soft(.gapRatio, d.gapRatio)))
    }
}

extension CollageMarkLayer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageMarkLayer()
        signatureOn = c.soft(.signatureOn, d.signatureOn)
        position = c.soft(.position, d.position)
        landscapePosition = c.softOptional(.landscapePosition)
        sizeRatio = min(1, max(0.01, c.soft(.sizeRatio, d.sizeRatio)))
        opacity = min(1, max(0, c.soft(.opacity, d.opacity)))
        marginRatio = min(0.2, max(0, c.soft(.marginRatio, d.marginRatio)))
        tint = c.softOptional(.tint)
        tile = c.softOptional(.tile)
        text = c.softOptional(.text)
        presetName = c.softOptional(.presetName)
        contrast = c.soft(.contrast, d.contrast)
        preferMargin = c.soft(.preferMargin, d.preferMargin)
    }
}

extension CollageMarkText {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollageMarkText()
        template = c.soft(.template, d.template)
        customText = c.soft(.customText, d.customText)
        fontSizeRatio = min(0.3, max(0.003, c.soft(.fontSizeRatio, d.fontSizeRatio)))
        position = c.soft(.position, d.position)
        marginRatio = min(0.2, max(0, c.soft(.marginRatio, d.marginRatio)))
        opacity = min(1, max(0, c.soft(.opacity, d.opacity)))
        color = c.soft(.color, d.color)
        backgroundEnabled = c.soft(.backgroundEnabled, d.backgroundEnabled)
        backgroundColor = c.soft(.backgroundColor, d.backgroundColor)
        backgroundAlpha = min(1, max(0, c.soft(.backgroundAlpha, d.backgroundAlpha)))
        fullWidth = c.soft(.fullWidth, d.fullWidth)
    }
}

extension CollageTemplate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.soft(.name, "未命名模板")
        root = c.soft(.root, CollageNode.leaf(.photo(nil)))
        style = c.softOptional(.style)
        canvas = c.softOptional(.canvas)
        fitAspects = c.soft(.fitAspects, true)
        builtin = false   // 读回来的一律是用户模板；内置的在代码里
        category = c.soft(.category, "")
        items = c.soft(.items, [Failable<CollageItem>]()).compactMap(\.value)
        scatter = c.softOptional(.scatter)
        freeform = c.soft(.freeform, false) || scatter != nil
        pageScatter = c.softOptional(.pageScatter)
        let aspect: Double? = c.softOptional(.savedAspect)
        savedAspect = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        contactSheet = c.softOptional(.contactSheet)
    }
}
