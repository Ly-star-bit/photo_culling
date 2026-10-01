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

    var label: String {
        switch self {
        case .auto: return "自动"
        case .full: return "全身"
        case .half: return "半身"
        case .close: return "特写"
        }
    }
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
    /// 压在这张照片上的字（跟着照片走：互换、挪格子、换一批都带着）。
    var overlay: CollageOverlay?

    init(kind: Kind = .empty) { self.kind = kind }

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

enum CollageFont: String, Codable, CaseIterable, Hashable {
    case songti, kaiti, pingfang, didot, bodoni, newYork, baskerville, optima, avenir, gillSans, futura
    case hanzipen, bradley, snell, typewriter

    var label: String {
        switch self {
        case .songti: return "宋体"
        case .kaiti: return "楷体"
        case .pingfang: return "苹方"
        case .didot: return "Didot"
        case .bodoni: return "Bodoni"
        case .newYork: return "New York"
        case .baskerville: return "Baskerville"
        case .optima: return "Optima"
        case .avenir: return "Avenir"
        case .gillSans: return "Gill Sans"
        case .futura: return "Futura"
        case .hanzipen: return "手写"
        case .bradley: return "Bradley 手写"
        case .snell: return "Snell 花体"
        case .typewriter: return "打字机"
        }
    }
}

enum CollageWeight: String, Codable, CaseIterable, Hashable {
    case light, regular, bold

    var label: String {
        switch self {
        case .light: return "细"
        case .regular: return "常规"
        case .bold: return "粗"
        }
    }
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

struct CollageText: Codable, Hashable {
    var lines: [CollageTextLine] = []
    /// 竖排：每行是一列，右起。
    var vertical = false
    var alignH: CollageAlign = .leading
    var alignV: CollageAlign = .leading
    /// 行（列）间距，相对该行字号。
    var lineSpacing: Double = 0.35
    /// 文字后面一条细线（竖排是竖线）。
    var rule = false
    var seal: CollageSeal?

    init(lines: [CollageTextLine] = [], vertical: Bool = false,
         alignH: CollageAlign = .leading, alignV: CollageAlign = .leading) {
        self.lines = lines
        self.vertical = vertical
        self.alignH = alignH
        self.alignV = alignV
    }
}


// MARK: - 压字：照片上的字

/// 字块贴在照片的哪一处。auto = 按人脸、画面空处自动挑；custom = 拖过，按 x/y 放。
enum CollageAnchor: String, Codable, CaseIterable, Hashable {
    case auto
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing
    case custom

    var label: String {
        switch self {
        case .auto: return "自动"
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
        case .auto, .custom: return nil
        }
    }

    static let grid: [CollageAnchor] = [.topLeading, .top, .topTrailing, .leading, .center, .trailing,
                                        .bottomLeading, .bottom, .bottomTrailing]
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
    /// 字块最宽占照片区多少，放不下整体缩。
    var maxWidth = 0.86

    init(text: CollageText) { self.text = text }
}

// MARK: - 样式

enum CollageBorder: String, Codable, CaseIterable, Hashable {
    case none, hairline, polaroid, film

    var label: String {
        switch self {
        case .none: return "无"
        case .hairline: return "细线"
        case .polaroid: return "相纸"
        case .film: return "胶片"
        }
    }
}

/// 整组统一的色调（程序生成的 3D LUT，不带任何胶片/滤镜品牌名）。
enum CollageLook: String, Codable, CaseIterable, Hashable {
    case none, film, airy, faded, cinema, cool, mono, sepia

    /// 黑白、旧照：去色永远是全的，强度只管影调（强度 0 也是黑白）。
    var isMonochrome: Bool { self == .mono || self == .sepia }

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
        }
    }
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

    var label: String {
        switch self {
        case .washi: return "和纸胶带"
        case .stripe: return "条纹胶带"
        case .dots: return "圆点胶带"
        case .kraft: return "牛皮纸胶带"
        case .label: return "标签"
        case .postmark: return "邮戳"
        case .clip: return "回形针"
        }
    }

    var isTape: Bool { self == .washi || self == .stripe || self == .dots || self == .kraft }

    /// 默认宽、高（相对画布短边）。
    var defaultSize: (w: Double, h: Double) {
        switch self {
        case .washi, .stripe, .dots, .kraft: return (0.16, 0.042)
        case .label: return (0.2, 0.05)
        case .postmark: return (0.17, 0.17)
        case .clip: return (0.035, 0.1)
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
        }
    }
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
    // 文字
    var text: CollageText?
    // 贴纸
    var sticker: CollageSticker = .washi
    var color = CollageColor(hex: 0xE9C8B8)
    /// 标签、邮戳上的字（支持占位符）。
    var label = ""
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

    init(root: CollageNode) { self.root = root }

    init(root: CollageNode, items: [CollageItem], freeform: Bool, scatter: CollageScatterSpec? = nil,
         gridRoot: CollageNode? = nil) {
        self.root = root
        self.items = items
        self.freeform = freeform
        self.scatter = scatter
        self.gridRoot = gridRoot
    }

    /// 这一页用到的照片：散落版只看图层，网格版是格子 + 图层里的照片。
    var photoIDs: [String] {
        let fromItems = items.compactMap { $0.kind == .photo ? $0.photoID : nil }
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

    init(name: String, root: CollageNode, style: CollageStyle? = nil, canvas: CollageCanvas? = nil,
         fitAspects: Bool = true, builtin: Bool = false, category: String = "",
         items: [CollageItem] = [], scatter: CollageScatterSpec? = nil, freeform: Bool = false) {
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
    }

    var photoSlots: Int {
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
        lineSpacing = c.soft(.lineSpacing, 0.35)
        rule = c.soft(.rule, false)
        seal = c.softOptional(.seal)
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
        text = c.softOptional(.text)
        sticker = c.soft(.sticker, .washi)
        color = c.soft(.color, sticker.defaultColor)
        label = c.soft(.label, "")
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
    }
}
