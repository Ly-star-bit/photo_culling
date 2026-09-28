import Foundation
import CoreGraphics

/// 版式几何 + 求解器。纯函数、不碰 AppKit，任何线程都能跑。
///
/// 求解思路（BRIC 式切分树，原型里验证过）：每个节点满足 w = m·A·h + B + m·C，
/// m 是所有照片叶子统一的比例伸缩。叶子 A = 原宽高比；并排节点 A、B、C 相加（B 多一条缝）；
/// 堆叠节点按调和方式合并。根节点代入画布宽高得到 m 的闭式解 —— |log m| 就是每张照片
/// 要裁掉的比例。随机生成几万棵树打分，留下最好的一批当备选。
enum CollageLayout {

    // MARK: - 几何：ratio → 整数像素矩形

    struct IntRect: Hashable {
        var x0: Int
        var y0: Int
        var x1: Int
        var y1: Int

        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }
        var area: Int { max(0, width) * max(0, height) }
        var aspect: Double { Double(max(1, width)) / Double(max(1, height)) }
        var cgRect: CGRect { CGRect(x: x0, y: y0, width: width, height: height) }
        var isEmpty: Bool { width <= 0 || height <= 0 }

        func inset(_ d: Int) -> IntRect { IntRect(x0: x0 + d, y0: y0 + d, x1: x1 - d, y1: y1 - d) }
    }

    struct Frame: Hashable {
        let path: [Int]
        let rect: IntRect
        let cell: CollageCell
    }

    struct Gutter: Hashable {
        /// 切分节点的路径。
        let path: [Int]
        let axis: CollageAxis
        /// 缝本身。
        let rect: IntRect
        /// 这个切分节点占的整块区域（拖缝时换算 ratio 用）。
        let region: IntRect
    }

    struct Geometry {
        var frames: [Frame] = []
        var gutters: [Gutter] = []
    }

    static let minRatio = 0.04

    /// 自顶向下整数切：缝宽恒为 gutter，舍入误差全落在格子上。
    static func geometry(_ root: CollageNode, in rect: IntRect, gutter: Int) -> Geometry {
        var g = Geometry()
        place(root, path: [], rect: rect, gutter: max(0, gutter), into: &g)
        return g
    }

    private static func place(_ node: CollageNode, path: [Int], rect: IntRect, gutter: Int, into g: inout Geometry) {
        if node.isLeaf {
            g.frames.append(Frame(path: path, rect: rect, cell: node.cell ?? CollageCell()))
            return
        }
        let ratio = min(1 - minRatio, max(minRatio, node.ratio))
        if node.axis == .row {
            let avail = Double(max(0, rect.width - gutter))
            let split = rect.x0 + Int((avail * ratio).rounded())
            let first = IntRect(x0: rect.x0, y0: rect.y0, x1: split, y1: rect.y1)
            let second = IntRect(x0: split + gutter, y0: rect.y0, x1: rect.x1, y1: rect.y1)
            let seam = IntRect(x0: split, y0: rect.y0, x1: split + gutter, y1: rect.y1)
            g.gutters.append(Gutter(path: path, axis: .row, rect: seam, region: rect))
            place(node.children[0], path: path + [0], rect: first, gutter: gutter, into: &g)
            place(node.children[1], path: path + [1], rect: second, gutter: gutter, into: &g)
        } else {
            let avail = Double(max(0, rect.height - gutter))
            let split = rect.y0 + Int((avail * ratio).rounded())
            let first = IntRect(x0: rect.x0, y0: rect.y0, x1: rect.x1, y1: split)
            let second = IntRect(x0: rect.x0, y0: split + gutter, x1: rect.x1, y1: rect.y1)
            let seam = IntRect(x0: rect.x0, y0: split, x1: rect.x1, y1: split + gutter)
            g.gutters.append(Gutter(path: path, axis: .column, rect: seam, region: rect))
            place(node.children[0], path: path + [0], rect: first, gutter: gutter, into: &g)
            place(node.children[1], path: path + [1], rect: second, gutter: gutter, into: &g)
        }
    }

    /// 拖缝：鼠标位置（与 region 同一坐标系）→ 新 ratio。两边都留至少 minPixels。
    static func ratio(forDrag position: Double, gutter: Gutter, gutterWidth: Int, minPixels: Double) -> Double {
        let r = gutter.region
        let isRow = gutter.axis == .row
        let origin = Double(isRow ? r.x0 : r.y0)
        let length = Double(isRow ? r.width : r.height) - Double(gutterWidth)
        guard length > 1 else { return 0.5 }
        let first = position - origin - Double(gutterWidth) / 2
        let lo = min(0.5, max(minRatio, minPixels / length))
        return min(1 - lo, max(lo, first / length))
    }

    // MARK: - 画布内的排版区

    /// 成品坐标系（不含出血）里的排版区：画布减外边距。
    static func contentRect(canvas: CollageCanvas, style: CollageStyle, scale: Double = 1) -> IntRect {
        let short = canvas.shortSide * scale
        let margin = Int((style.margin * short).rounded())
        let w = Int((Double(canvas.width) * scale).rounded())
        let h = Int((Double(canvas.height) * scale).rounded())
        return IntRect(x0: margin, y0: margin, x1: w - margin, y1: h - margin)
    }

    static func gutterPixels(canvas: CollageCanvas, style: CollageStyle, scale: Double = 1) -> Int {
        guard style.gutter > 0 else { return 0 }
        return max(1, Int((style.gutter * canvas.shortSide * scale).rounded()))
    }

    // MARK: - 求解用的轻量树

    indirect enum Shape {
        case leaf(Int)
        case split(CollageAxis, Shape, Shape)

        var leafIndices: [Int] {
            switch self {
            case .leaf(let i): return [i]
            case .split(_, let a, let b): return a.leafIndices + b.leafIndices
            }
        }
    }

    /// w = m·a·h + b + m·c
    struct Coeff {
        var a: Double
        var b: Double
        var c: Double
    }

    static func coeff(_ shape: Shape, _ aspects: [Double], _ g: Double) -> Coeff {
        switch shape {
        case .leaf(let i):
            return Coeff(a: aspects[i], b: 0, c: 0)
        case .split(let axis, let first, let second):
            let p = coeff(first, aspects, g)
            let q = coeff(second, aspects, g)
            if axis == .row {
                return Coeff(a: p.a + q.a, b: p.b + q.b + g, c: p.c + q.c)
            }
            let inv = 1 / p.a + 1 / q.a
            let a = 1 / inv
            let bSum = p.b / p.a + q.b / q.a
            let cSum = p.c / p.a + q.c / q.a - g
            return Coeff(a: a, b: a * bSum, c: a * cSum)
        }
    }

    /// 让整棵树正好填满 w×h 的统一伸缩 m；无解返回 nil。
    static func fitM(_ k: Coeff, width: Double, height: Double) -> Double? {
        let den = k.a * height + k.c
        guard den > 1e-9 else { return nil }
        let m = (width - k.b) / den
        guard m.isFinite, m > 0 else { return nil }
        return m
    }

    /// 轻量树 + m → 带 ratio 的文档树。cells[i] 是第 i 个叶子的内容。
    static func node(_ shape: Shape, _ aspects: [Double], _ g: Double, m: Double,
                     width: Double, height: Double, cells: [CollageCell]) -> CollageNode {
        switch shape {
        case .leaf(let i):
            return .leaf(cells[i])
        case .split(let axis, let first, let second):
            let p = coeff(first, aspects, g)
            if axis == .row {
                let firstW = m * p.a * height + p.b + m * p.c
                let avail = max(1e-6, width - g)
                let ratio = clampRatio(firstW / avail)
                let w1 = avail * ratio
                return .split(.row, ratio,
                              node(first, aspects, g, m: m, width: w1, height: height, cells: cells),
                              node(second, aspects, g, m: m, width: avail - w1, height: height, cells: cells))
            }
            let firstH = (width - p.b - m * p.c) / max(1e-9, m * p.a)
            let avail = max(1e-6, height - g)
            let ratio = clampRatio(firstH / avail)
            let h1 = avail * ratio
            return .split(.column, ratio,
                          node(first, aspects, g, m: m, width: width, height: h1, cells: cells),
                          node(second, aspects, g, m: m, width: width, height: avail - h1, cells: cells))
        }
    }

    private static func clampRatio(_ r: Double) -> Double {
        guard r.isFinite else { return 0.5 }
        return min(1 - minRatio, max(minRatio, r))
    }

    /// 文档树 → 轻量树（叶子按阅读顺序编号）。
    static func shape(of root: CollageNode) -> (shape: Shape, cells: [CollageCell]) {
        var cells: [CollageCell] = []
        func walk(_ n: CollageNode) -> Shape {
            if n.isLeaf {
                cells.append(n.cell ?? CollageCell())
                return .leaf(cells.count - 1)
            }
            let a = walk(n.children[0])
            let b = walk(n.children[1])
            return .split(n.axis, a, b)
        }
        let s = walk(root)
        return (s, cells)
    }

    static func randomShape(_ indices: [Int], using rng: inout SeededRandom) -> Shape {
        if indices.count == 1 { return .leaf(indices[0]) }
        let k = Int.random(in: 1..<indices.count, using: &rng)
        let axis: CollageAxis = Bool.random(using: &rng) ? .row : .column
        return .split(axis, randomShape(Array(indices[..<k]), using: &rng),
                      randomShape(Array(indices[k...]), using: &rng))
    }

    // MARK: - 叶子期望比例

    /// 照片 = 原宽高比；文字格 = 偏好比例（竖排窄高、横排扁宽）。
    static func preferredAspect(_ cell: CollageCell, photos: [String: CollagePhotoRef]) -> Double {
        switch cell.kind {
        case .photo:
            if let id = cell.photoID, let p = photos[id] {
                if cell.shape == .circle { return 1 }
                return p.aspect
            }
            return 2.0 / 3.0
        case .text:
            guard let t = cell.text else { return 1 }
            return t.vertical ? 0.32 : 3.2
        case .empty:
            return 1
        }
    }

    // MARK: - 评分

    struct Context {
        var canvas: CollageCanvas
        var style: CollageStyle
        var photos: [String: CollagePhotoRef]
        var hints: [String: CollageCrop.Hints] = [:]
        /// 必须最大的那张（nil = 按分数自动定）。
        var heroID: String?
    }

    struct Scored {
        var root: CollageNode
        var score: Double
        var m: Double
        var signature: String
        var cutFaces: Int
        var seamFaces: Int
        /// 结构 + 照片排列：同分时按它排，同一 seed 每次出同一组备选。
        var key: String = ""
        var shapeClass: String = ""
    }

    /// 分数越低越好。m 为 nil 表示不是按比例解出来的（模板、手动），不计裁切项。
    static func score(_ root: CollageNode, m: Double?, context: Context) -> Scored {
        let canvas = context.canvas
        let content = contentRect(canvas: canvas, style: context.style)
        let gutter = gutterPixels(canvas: canvas, style: context.style)
        let geo = geometry(root, in: content, gutter: gutter)
        let short = canvas.shortSide

        var s = 0.0
        if let m { s += 4.0 * abs(log(m)) }

        var photoFrames: [(frame: Frame, photo: CollagePhotoRef)] = []
        var baseCrop = 0.0
        for f in geo.frames where f.cell.kind == .photo {
            guard let id = f.cell.photoID, let p = context.photos[id] else { continue }
            photoFrames.append((f, p))
            // 格子比例和照片差多少就得裁多少（景别收紧是有意的，不算）。按实际画照片的区域算
            // （月洞门是正方形、相纸/胶片是框内）。
            if !f.cell.contain {
                let area = CollageCrop.photoArea(cell: f.cell, rect: f.rect.cgRect, style: context.style)
                let win = CollageCrop.maxWindow(photoAspect: p.aspect, cellAspect: CollageCrop.aspect(of: area))
                baseCrop += 1 - win.w * win.h
            }
            // 太小的格：缩略图大小，印出来就是一粒芝麻。
            let minSide = Double(min(f.rect.width, f.rect.height))
            if minSide < 0.06 * short { s += 6 }
            let a = f.rect.aspect
            if a > 2.4 || a < 0.42 { s += 2 }
        }
        // 模板/手动版没有 m，裁切量直接按格子算（按比例解出来的已经在 |log m| 里了）。
        if m == nil, !photoFrames.isEmpty {
            s += 3.0 * baseCrop / Double(photoFrames.count)
        }
        for f in geo.frames where f.cell.kind == .text {
            let a = f.rect.aspect
            let vertical = f.cell.text?.vertical ?? false
            if vertical && a > 0.9 { s += 1.5 }
            if !vertical && a < 1.2 { s += 1.5 }
            if Double(min(f.rect.width, f.rect.height)) < 0.05 * short { s += 4 }
        }

        // 主图：最大、占比合适；其余大小一致、不能有特别小的。
        var cutFaces = 0
        var seamFaces = 0
        if photoFrames.count >= 2 {
            let heroID = context.heroID ?? photoFrames.max { $0.photo.score < $1.photo.score }?.photo.id
            let areas = photoFrames.map { Double($0.frame.rect.area) }
            let total = areas.reduce(0, +)
            let heroIndex = photoFrames.firstIndex { $0.photo.id == heroID } ?? 0
            let heroArea = areas[heroIndex]
            var others = areas
            others.remove(at: heroIndex)
            let maxOther = others.max() ?? 1
            let meanOther = others.reduce(0, +) / Double(max(1, others.count))
            let n = Double(photoFrames.count)
            let target = min(0.5, 1.7 / n)
            s += 1.5 * abs(heroArea / max(1, total) - target)
            s += 2.0 * max(0, 1.25 - heroArea / max(1, maxOther))
            if others.count >= 2 {
                var variance = 0.0
                for v in others { variance += (v - meanOther) * (v - meanOther) }
                let cv = (variance / Double(others.count)).squareRoot() / max(1, meanOther)
                s += 1.0 * cv
                s += 3.0 * max(0, 0.45 - (others.min() ?? 0) / max(1, meanOther))
            }
        }

        // 相册：普通照片别横跨中缝（被书脊吃掉一条），要跨就只跨一张大图。
        if canvas.seams == .fold {
            let fold = Double(canvas.width) / 2
            let band = canvas.shortSide * 0.02
            let crossing = photoFrames.filter { Double($0.frame.rect.x0) < fold - band && Double($0.frame.rect.x1) > fold + band }
            if photoFrames.count >= 2 { s += 1.2 * Double(crossing.count) }
        }

        // 切脸 + 缝压脸
        let seams = seamLines(canvas)
        for (frame, photo) in photoFrames {
            let framing = effectiveFraming(path: frame.path, cell: frame.cell, in: geo.frames,
                                           photos: context.photos, tight: context.style.tightSmallCells)
            let area = CollageCrop.photoArea(cell: frame.cell, rect: frame.rect.cgRect, style: context.style)
            let window = CollageCrop.window(for: photo, cell: frame.cell, cellAspect: CollageCrop.aspect(of: area),
                                            framing: framing, hints: context.hints[photo.id])
            if window.cutsFace {
                s += 5
                cutFaces += 1
            }
            if !seams.isEmpty {
                let drawn = CollageCrop.drawnRect(window: window, photo: photo, cell: frame.cell, in: area)
                let boxes = CollageCrop.faceBoxes(photo: photo, window: window, in: drawn)
                for box in boxes {
                    for seam in seams where seam.intersects(box) {
                        s += 3
                        seamFaces += 1
                    }
                }
            }
        }

        // 差一点对齐：两条不同分支上的缝相距不到 1.5% 却不重合 —— 看起来就是没对齐。
        s += nearMissPenalty(geo.gutters, tolerance: 0.015 * short)

        return Scored(root: root, score: s, m: m ?? 1, signature: root.signature,
                      cutFaces: cutFaces, seamFaces: seamFaces,
                      key: arrangementKey(root), shapeClass: root.shapeClass)
    }

    private static func nearMissPenalty(_ gutters: [Gutter], tolerance: Double) -> Double {
        var xs: [Double] = []
        var ys: [Double] = []
        for g in gutters {
            if g.axis == .row { xs.append(Double(g.rect.x0)) } else { ys.append(Double(g.rect.y0)) }
        }
        var p = 0.0
        for list in [xs, ys] where list.count > 1 {
            for i in 0..<list.count {
                for j in (i + 1)..<list.count {
                    let d = abs(list[i] - list[j])
                    if d > 1.5 && d < tolerance { p += 0.35 }
                }
            }
        }
        return p
    }

    /// 九宫格三分线、轮播页缝、相册中缝（成品坐标，扩成一条窄带，脸不能压上去）。
    static func seamLines(_ canvas: CollageCanvas) -> [CGRect] {
        let w = Double(canvas.width)
        let h = Double(canvas.height)
        let band = max(4, canvas.shortSide * 0.004)
        var out: [CGRect] = []
        switch canvas.seams {
        case .none:
            break
        case .grid9:
            for k in 1...2 {
                let x = w * Double(k) / 3
                let y = h * Double(k) / 3
                out.append(CGRect(x: x - band, y: 0, width: band * 2, height: h))
                out.append(CGRect(x: 0, y: y - band, width: w, height: band * 2))
            }
        case .carousel:
            let n = max(1, canvas.slides)
            if n > 1 {
                for k in 1..<n {
                    let x = w * Double(k) / Double(n)
                    out.append(CGRect(x: x - band, y: 0, width: band * 2, height: h))
                }
            }
        case .fold:
            // 装订中缝：两边各让出一截，脸进去就被书脊吃掉。
            let fold = max(band, canvas.shortSide * 0.02)
            out.append(CGRect(x: w / 2 - fold, y: 0, width: fold * 2, height: h))
        }
        return out
    }

    /// auto 景别落到哪一档：小格（面积不到最大照片格 55%）里全身的照片，隔一个收成半身 ——
    /// 原型 c6_34_tight 那种远近节奏。
    static func effectiveFraming(path: [Int], cell: CollageCell, in frames: [Frame],
                                 photos: [String: CollagePhotoRef], tight: Bool) -> CollageFraming {
        guard cell.framing == .auto else { return cell.framing }
        guard tight, !cell.contain, cell.crop == nil else { return .full }
        let photoFrames = frames.filter { $0.cell.kind == .photo && $0.cell.photoID != nil }
        guard photoFrames.count >= 3 else { return .full }
        let maxArea = Double(photoFrames.map(\.rect.area).max() ?? 1)
        let small = photoFrames.filter { f in
            guard Double(f.rect.area) < 0.55 * maxArea, f.cell.framing == .auto, !f.cell.contain,
                  let p = f.cell.photoID.flatMap({ photos[$0] }), !p.faces.isEmpty else { return false }
            return (p.faceAreaPct ?? 0.01) < 0.03
        }
        guard let index = small.firstIndex(where: { $0.path == path }) else { return .full }
        return index % 2 == 0 ? .half : .full
    }

    // MARK: - 求解

    struct Request {
        var photos: [CollagePhotoRef]
        /// 额外的文字叶子（模板以外一般没有）。
        var textCells: [CollageCell] = []
        var context: Context
        var tries = 20000
        var keep = 24
        var seed: UInt64 = 1
    }

    /// 随机切分树 + 按比例闭式解，留下分数最好、结构互不相同的 keep 个。
    static func solve(_ req: Request) -> [Scored] {
        let photos = req.photos
        guard !photos.isEmpty else { return [] }
        var cells = photos.map { CollageCell.photo($0.id) }
        cells.append(contentsOf: req.textCells)
        let photoMap = req.context.photos
        let aspects = cells.map { preferredAspect($0, photos: photoMap) }
        let content = contentRect(canvas: req.context.canvas, style: req.context.style)
        let g = Double(gutterPixels(canvas: req.context.canvas, style: req.context.style))
        let width = Double(content.width)
        let height = Double(content.height)
        var rng = SeededRandom(seed: req.seed)

        if cells.count == 1 {
            let root = CollageNode.leaf(cells[0])
            return [score(root, m: nil, context: req.context)]
        }

        let indices = Array(0..<cells.count)
        func search(_ lo: Double, _ hi: Double, tries: Int) -> [String: Scored] {
            var best: [String: Scored] = [:]
            for _ in 0..<max(1, tries) {
                let order = indices.shuffled(using: &rng)
                let shape = randomShape(order, using: &rng)
                let k = coeff(shape, aspects, g)
                guard let m = fitM(k, width: width, height: height), m > lo, m < hi else { continue }
                let root = node(shape, aspects, g, m: m, width: width, height: height, cells: cells)
                let scored = score(root, m: m, context: req.context)
                let key = arrangementKey(root)
                if let existing = best[key], existing.score <= scored.score { continue }
                best[key] = scored
            }
            return best
        }
        var best = search(0.62, 1.6, tries: req.tries)
        // 画布比例和照片差太远（2 张竖图放横版 3:1 跨页、9:16 竖图放方册）：常规伸缩范围里
        // 一个解都没有。放宽再找一次 —— 裁得多，但 |log m| 项会挑裁得最少的；绝不能返回空，
        // 相册那边拿到空结果会把整个跨页连照片一起弄丢。
        if best.isEmpty { best = search(0.2, 5, tries: max(2000, req.tries / 2)) }
        return diverse(Array(best.values), keep: req.keep)
    }

    /// 结构 + 照片排列：同一结构换了照片位置也算不同的版。
    static func arrangementKey(_ root: CollageNode) -> String {
        root.signature + "|" + root.leaves.map { $0.photoID ?? ($0.kind == .text ? "T" : "_") }.joined(separator: ",")
    }

    /// 按分数取前 keep 个：同一结构只留一个，同一形状类（含镜像）最多两个 —— 备选条上
    /// 每一版都要看得出区别。同分按排列键排，结果和字典遍历顺序无关。
    static func diverse(_ all: [Scored], keep: Int) -> [Scored] {
        let sorted = all.sorted { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.key < b.key
        }
        var out: [Scored] = []
        var perSignature = Set<String>()
        var perClass: [String: Int] = [:]
        for s in sorted {
            if perSignature.contains(s.signature) { continue }
            let n = perClass[s.shapeClass, default: 0]
            if n >= 2 { continue }
            perSignature.insert(s.signature)
            perClass[s.shapeClass] = n + 1
            out.append(s)
            if out.count >= keep { break }
        }
        return out
    }

    /// 贴合原比例：结构不变，按照片原比例重算 ratio。
    ///
    /// 文字/留白子树是弹性的：和照片子树并排或堆叠时，照片先按原比例（m = 1）排满
    /// 横向（或纵向），剩下的都给文字 —— 以前把文字格也按统一的 m 伸缩，
    /// 「居中标题 + 三联」的三张竖图被挤成两边各裁四成的细条。
    static func refit(_ root: CollageNode, context: Context) -> CollageNode {
        let content = contentRect(canvas: context.canvas, style: context.style)
        let g = Double(gutterPixels(canvas: context.canvas, style: context.style))
        return refitNode(root, width: Double(content.width), height: Double(content.height), g: g, photos: context.photos)
    }

    private static func refitNode(_ n: CollageNode, width: Double, height: Double, g: Double,
                                  photos: [String: CollagePhotoRef]) -> CollageNode {
        if n.isLeaf { return n }
        // 纯照片子树：统一伸缩一次解完。
        if !n.hasTextLeaf {
            let (shape, cells) = self.shape(of: n)
            let aspects = cells.map { preferredAspect($0, photos: photos) }
            let k = coeff(shape, aspects, g)
            guard let m = fitM(k, width: width, height: height) else { return n }
            return node(shape, aspects, g, m: m, width: width, height: height, cells: cells)
        }
        let isRow = n.axis == .row
        let avail = max(1, (isRow ? width : height) - g)
        let flexFirst = !n.children[0].hasPhotoLeaf
        let flexSecond = !n.children[1].hasPhotoLeaf
        // 一边纯文字、一边纯照片：照片按原比例占它要的长度，文字拿剩下的（至少一成）。
        if flexFirst != flexSecond {
            let photoIndex = flexFirst ? 1 : 0
            let photoChild = n.children[photoIndex]
            if !photoChild.hasTextLeaf {
                let (shape, cells) = self.shape(of: photoChild)
                let aspects = cells.map { preferredAspect($0, photos: photos) }
                let k = coeff(shape, aspects, g)
                let natural = isRow ? (k.a * height + k.b + k.c) : ((width - k.b - k.c) / max(1e-9, k.a))
                // 文字至少留一成半：标题带太窄会顶着照片，显得挤。
                let photoLen = min(natural, avail * 0.86)
                if photoLen > avail * 0.25 {
                    let w = isRow ? photoLen : width
                    let h = isRow ? height : photoLen
                    if let m = fitM(k, width: w, height: h) {
                        var out = n
                        out.children[photoIndex] = node(shape, aspects, g, m: m, width: w, height: h, cells: cells)
                        out.ratio = clampRatio(photoIndex == 0 ? photoLen / avail : 1 - photoLen / avail)
                        return out
                    }
                }
            }
        }
        // 其余混合情况：这一刀的比例不动，分别往下贴合。
        var out = n
        let first = avail * min(1 - minRatio, max(minRatio, n.ratio))
        if isRow {
            out.children[0] = refitNode(n.children[0], width: first, height: height, g: g, photos: photos)
            out.children[1] = refitNode(n.children[1], width: avail - first, height: height, g: g, photos: photos)
        } else {
            out.children[0] = refitNode(n.children[0], width: width, height: first, g: g, photos: photos)
            out.children[1] = refitNode(n.children[1], width: width, height: avail - first, g: g, photos: photos)
        }
        return out
    }

    // MARK: - 锁定：锁住的格子位置不动，只重排其余区域

    /// 保留根到每个锁定叶子的路径（轴 + ratio），路径外的兄弟子树是「自由区」，
    /// 把没锁的照片按面积分给各自由区，各自随机求解，拼回去整体打分。
    static func solveKeepingLocks(current: CollageNode, context: Context, tries: Int = 6000,
                                  keep: Int = 16, seed: UInt64 = 1) -> [Scored] {
        let paths = current.leafPaths()
        let lockedPaths = paths.filter { current.node(at: $0)?.cell?.locked == true }
        guard !lockedPaths.isEmpty else {
            let photos = current.photoIDs.compactMap { context.photos[$0] }
            let texts = current.leaves.filter { $0.kind == .text }
            return solve(Request(photos: photos, textCells: texts, context: context, tries: tries, keep: keep, seed: seed))
        }

        // 自由区：不在任何锁定路径上的最大子树。
        var freePaths: [[Int]] = []
        func collect(_ path: [Int]) {
            let onLocked = lockedPaths.contains { $0.starts(with: path) }
            guard onLocked else {
                freePaths.append(path)
                return
            }
            guard let n = current.node(at: path), !n.isLeaf else { return }
            collect(path + [0])
            collect(path + [1])
        }
        collect([])
        guard !freePaths.isEmpty else { return [score(current, m: nil, context: context)] }

        let content = contentRect(canvas: context.canvas, style: context.style)
        let gutter = gutterPixels(canvas: context.canvas, style: context.style)
        let geo = geometry(current, in: content, gutter: gutter)
        // 自由区的像素矩形 = 其中所有叶子的外包框。
        var regionRects: [IntRect] = []
        for p in freePaths {
            let rects = geo.frames.filter { $0.path.starts(with: p) }.map(\.rect)
            guard let first = rects.first else { continue }
            var r = first
            for x in rects.dropFirst() {
                r = IntRect(x0: min(r.x0, x.x0), y0: min(r.y0, x.y0), x1: max(r.x1, x.x1), y1: max(r.y1, x.y1))
            }
            regionRects.append(r)
        }
        guard regionRects.count == freePaths.count else { return [score(current, m: nil, context: context)] }

        var movable: [CollageCell] = []
        for p in freePaths {
            if let n = current.node(at: p) { movable.append(contentsOf: n.leaves) }
        }
        guard movable.count >= freePaths.count else { return [score(current, m: nil, context: context)] }

        let photoMap = context.photos
        let aspects = movable.map { preferredAspect($0, photos: photoMap) }
        let g = Double(gutter)
        let areas = regionRects.map { Double($0.area) }
        let totalArea = max(1, areas.reduce(0, +))
        var rng = SeededRandom(seed: seed)
        var best: [String: Scored] = [:]
        // 常规伸缩范围；自由区只有一两张时形状就那一两种，常常一个都放不进去 —— 放宽再来。
        var mRange = (lo: 0.55, hi: 1.8)

        for attempt in 0..<(max(1, tries) * 2) {
            if attempt == max(1, tries) {
                guard best.isEmpty else { break }
                mRange = (0.2, 5)
            }
            // 每区至少一张，其余按面积比例 + 一点随机。
            var counts = [Int](repeating: 1, count: regionRects.count)
            var remaining = movable.count - regionRects.count
            while remaining > 0 {
                var pickIndex = 0
                var bestNeed = -Double.infinity
                for (i, a) in areas.enumerated() {
                    let want = Double(movable.count) * a / totalArea
                    let need = want - Double(counts[i]) + Double.random(in: 0..<0.9, using: &rng)
                    if need > bestNeed {
                        bestNeed = need
                        pickIndex = i
                    }
                }
                counts[pickIndex] += 1
                remaining -= 1
            }
            let order = Array(0..<movable.count).shuffled(using: &rng)
            var cursor = 0
            var assembled = current
            var ok = true
            for (i, rect) in regionRects.enumerated() {
                let slice = Array(order[cursor..<(cursor + counts[i])])
                cursor += counts[i]
                let shape = randomShape(slice, using: &rng)
                let k = coeff(shape, aspects, g)
                let w = Double(rect.width)
                let h = Double(rect.height)
                guard let m = fitM(k, width: w, height: h), m > mRange.lo, m < mRange.hi else {
                    ok = false
                    break
                }
                let sub = node(shape, aspects, g, m: m, width: w, height: h, cells: movable)
                assembled.update(at: freePaths[i]) { $0 = sub }
            }
            guard ok else { continue }
            let scored = score(assembled, m: nil, context: context)
            let key = arrangementKey(assembled)
            if let existing = best[key], existing.score <= scored.score { continue }
            best[key] = scored
        }
        return diverse(Array(best.values), keep: keep)
    }

    // MARK: - 编辑操作（纯函数，Store 包一层撤销）

    /// 两个叶子互换内容（照片/文字/裁切/景别一起换；锁定状态留在原位）。
    static func swapLeaves(_ root: CollageNode, _ a: [Int], _ b: [Int]) -> CollageNode {
        guard a != b, let na = root.node(at: a)?.cell, let nb = root.node(at: b)?.cell else { return root }
        var out = root
        var newA = nb
        var newB = na
        newA.locked = na.locked
        newB.locked = nb.locked
        newA.crop = nil
        newB.crop = nil
        out.update(at: a) { $0.cell = newA }
        out.update(at: b) { $0.cell = newB }
        return out
    }

    enum Edge { case left, right, top, bottom }

    /// 把 cell 插到某个叶子的一边：那个叶子劈成两半。
    static func insert(_ cell: CollageCell, at path: [Int], edge: Edge, into root: CollageNode) -> CollageNode {
        guard let target = root.node(at: path), target.isLeaf else { return root }
        let axis: CollageAxis = (edge == .left || edge == .right) ? .row : .column
        let newFirst = edge == .left || edge == .top
        let inserted = CollageNode.leaf(cell)
        let split = newFirst ? CollageNode.split(axis, 0.5, inserted, target)
                             : CollageNode.split(axis, 0.5, target, inserted)
        var out = root
        out.update(at: path) { $0 = split }
        return out
    }

    /// 删掉一个叶子：父节点被兄弟子树顶替（其余自动回流）。
    static func remove(at path: [Int], from root: CollageNode) -> CollageNode {
        guard let last = path.last else { return CollageNode.leaf(CollageCell()) }
        let parentPath = Array(path.dropLast())
        guard let parent = root.node(at: parentPath), !parent.isLeaf else { return root }
        let sibling = parent.children[1 - last]
        var out = root
        out.update(at: parentPath) { $0 = sibling }
        return out
    }

    /// ⌥点缝：横竖翻转。
    static func flip(at path: [Int], in root: CollageNode) -> CollageNode {
        var out = root
        out.update(at: path) { node in
            if !node.isLeaf { node.axis = node.axis.flipped }
        }
        return out
    }

    static func setRatio(_ ratio: Double, at path: [Int], in root: CollageNode) -> CollageNode {
        var out = root
        out.update(at: path) { node in
            if !node.isLeaf { node.ratio = min(1 - minRatio, max(minRatio, ratio)) }
        }
        return out
    }
}

// MARK: - 可复现的随机数（同一 seed 同一组备选，CLI 能逐字比对）

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        // splitmix64
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
