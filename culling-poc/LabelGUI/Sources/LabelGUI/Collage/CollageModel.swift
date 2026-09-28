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

    init(_ text: String, font: CollageFont = .songti, weight: CollageWeight = .regular,
         size: Double = 0.04, tracking: Double = 0, color: CollageColor = .ink,
         italic: Bool = false, indent: Double = 0) {
        self.text = text
        self.font = font
        self.weight = weight
        self.size = size
        self.tracking = tracking
        self.color = color
        self.italic = italic
        self.indent = indent
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

enum CollageBackgroundMode: String, Codable, CaseIterable, Hashable {
    /// 用 style.background
    case solid
    /// 从主图取色（压低饱和、往纸白靠）
    case fromPhoto
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
        CollageCanvas(name: "九宫格 1:1", width: 2160, height: 2160, seams: .grid9),
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

// MARK: - 项目 / 页 / 模板

enum CollageMode: String, Codable, Hashable {
    case single, album
}

struct CollagePage: Codable, Hashable, Identifiable {
    var id = UUID()
    var root: CollageNode

    init(root: CollageNode) { self.root = root }
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

    init() {}

    func photo(_ id: String?) -> CollagePhotoRef? {
        guard let id else { return nil }
        return photos.first { $0.id == id }
    }

    /// 已经上了任何一页的照片 id。
    var usedPhotoIDs: Set<String> { Set(pages.flatMap { $0.root.photoIDs }) }
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

    init(name: String, root: CollageNode, style: CollageStyle? = nil, canvas: CollageCanvas? = nil,
         fitAspects: Bool = true, builtin: Bool = false) {
        self.name = name
        self.root = root
        self.style = style
        self.canvas = canvas
        self.fitAspects = fitAspects
        self.builtin = builtin
    }

    var photoSlots: Int { root.leaves.filter { $0.kind == .photo }.count }
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
    }
}

extension CollagePage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        root = c.soft(.root, CollageNode.leaf(CollageCell()))
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
    }
}
