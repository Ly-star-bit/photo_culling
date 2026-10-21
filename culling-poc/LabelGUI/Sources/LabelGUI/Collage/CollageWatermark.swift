import Foundation
import CoreGraphics
import ImageIO

// MARK: - 拼图水印：和水印页设置之间的换算
//
// 水印页的边距是原图像素、字号相对原图长边；拼图里同一份设置要套到大小不一的格子、整页上，
// 所以存成「相对区域短边」的比例，画的时候按区域现算回像素（engineConfig），引擎照旧画。
// 相框和画布比例会改画布尺寸，不进拼图。

/// 水印套到哪一层：每张照片各一个 / 整页一个。
enum CollageMarkLayerKind: String, CaseIterable, Hashable {
    case photos, page

    var label: String { self == .photos ? "每张照片" : "整页" }
}

extension CollageWatermark {
    func layer(_ kind: CollageMarkLayerKind) -> CollageMarkLayer? {
        kind == .photos ? photos : page
    }

    mutating func setLayer(_ kind: CollageMarkLayerKind, _ layer: CollageMarkLayer?) {
        if kind == .photos { photos = layer } else { page = layer }
    }

    /// 这一层开着、而且真有东西可画（签名开着且有签名，或者有字）。
    func layerHasContent(_ kind: CollageMarkLayerKind) -> Bool {
        layer(kind)?.hasContent(signature: signature != nil) ?? false
    }

    var hasContent: Bool { layerHasContent(.photos) || layerHasContent(.page) }

    /// 至少开着一层（导出页的「导出带水印」开关、「（不带水印）」只在这时说）。
    var anyLayerOn: Bool { photos != nil || page != nil }

    /// 一行摘要（命令行 describe、载入行用）：「每张 右下 15% 字｜整页 右下 字」。只写和默认值不一样的。
    var summary: String {
        var parts: [String] = []
        for kind in CollageMarkLayerKind.allCases {
            guard let layer = layer(kind) else { continue }
            var s = (kind == .photos ? "每张 " : "整页 ") + layer.position.label
            if layer.signatureOn {
                s += signature == nil ? " 无签名" : " \(Int((layer.sizeRatio * 100).rounded()))%"
            }
            if layer.text != nil { s += " 字" }
            if layer.tile != nil { s += " 平铺" }
            if layer.contrast != .original { s += " " + layer.contrast.label }
            if kind == .page, !layer.preferMargin { s += " 不进留白" }
            parts.append(s)
        }
        var extras: [String] = []
        if !skipPhotoIDs.isEmpty { extras.append("跳过\(skipPhotoIDs.count)") }
        if tiles == .eachTile { extras.append("每片一个") }
        if albumSides == .both { extras.append("两页") }
        if !exportEnabled { extras.append("导出不带") }
        let head = parts.isEmpty ? "无" : parts.joined(separator: "｜")
        return extras.isEmpty ? head : head + "·" + extras.joined(separator: "·")
    }
}

extension CollageMarkLayer {
    /// 水印页的设置 → 拼图的一层。`refShort` = 水印页那张照片（转正后）的短边：像素边距按它折成比例。
    init(config: WatermarkEngine.Config, refShort: Double) {
        self.init()
        let ref = max(1, refShort)
        signatureOn = config.signatureEnabled
        position = config.position
        landscapePosition = config.landscapeOverrideEnabled ? config.landscapeOverride : nil
        sizeRatio = config.sizeRatio
        opacity = config.opacity
        marginRatio = Self.ratio(margins: config.marginX, config.marginY, refShort: ref)
        if config.tintEnabled {
            tint = CollageColor(r: config.tint.r / 255, g: config.tint.g / 255, b: config.tint.b / 255)
        }
        if config.tile.enabled {
            var t = CollageMarkTile()
            t.angleDeg = config.tile.angleDeg
            t.gapRatio = config.tile.gapRatio
            tile = t
        }
        if config.exifText.enabled {
            text = CollageMarkText(config: config.exifText, refShort: ref)
        }
    }

    /// 检视器滑杆的范围：大小和水印页的大小滑杆一样，边距和从水印页折算过来的上限一样 —— 拿进来的值
    /// 不会落在滑杆外头（一碰就被夹回去）。
    static let sizeRange: ClosedRange<Double> = 0.03...0.6
    static let marginRange: ClosedRange<Double> = 0...0.2

    /// 两个方向的像素边距取平均、折成相对短边的比例（0…0.2）。
    static func ratio(margins x: Double, _ y: Double, refShort: Double) -> Double {
        let r = (x + y) / 2 / max(1, refShort)
        return r.isFinite ? min(marginRange.upperBound, max(0, r)) : 0.02
    }

    /// 签名开着且有签名，或者有字。
    func hasContent(signature: Bool) -> Bool {
        (signatureOn && signature) || text != nil
    }

    /// 按区域现算回引擎的设置：边距 = 比例 × 区域短边（像素，画的时候 scale 传 1）；相框、画布比例关。
    func engineConfig(areaShort: Double) -> WatermarkEngine.Config {
        var c = WatermarkEngine.Config()
        c.signatureEnabled = signatureOn
        c.position = position
        c.landscapeOverrideEnabled = landscapePosition != nil
        c.landscapeOverride = landscapePosition ?? position
        c.sizeRatio = sizeRatio
        c.opacity = opacity
        c.marginX = marginRatio * areaShort
        c.marginY = c.marginX
        c.tintEnabled = tint != nil
        if let tint { c.tint = WatermarkEngine.RGB(r: tint.r * 255, g: tint.g * 255, b: tint.b * 255) }
        c.tile.enabled = tile != nil
        if let tile {
            c.tile.angleDeg = tile.angleDeg
            c.tile.gapRatio = tile.gapRatio
        }
        if let text { c.exifText = text.engineConfig(areaShort: areaShort) }
        return c
    }
}

extension CollageMarkText {
    /// 检视器字号滑杆的范围（和水印页的字号滑杆一样）。
    static let fontSizeRange: ClosedRange<Double> = 0.01...0.08

    init(config: WatermarkEngine.ExifTextConfig, refShort: Double) {
        self.init()
        template = config.template
        customText = config.customText
        fontSizeRatio = config.fontSizeRatio
        position = config.position
        marginRatio = CollageMarkLayer.ratio(margins: config.marginX, config.marginY, refShort: refShort)
        opacity = config.opacity
        color = CollageColor(r: config.color.r / 255, g: config.color.g / 255, b: config.color.b / 255)
        backgroundEnabled = config.backgroundEnabled
        backgroundColor = CollageColor(r: config.backgroundColor.r / 255, g: config.backgroundColor.g / 255,
                                       b: config.backgroundColor.b / 255)
        backgroundAlpha = config.backgroundAlpha
        fullWidth = config.fullWidth
    }

    func engineConfig(areaShort: Double) -> WatermarkEngine.ExifTextConfig {
        var t = WatermarkEngine.ExifTextConfig()
        t.enabled = true
        t.template = template
        t.customText = customText
        t.fontSizeRatio = fontSizeRatio
        t.position = position
        t.marginX = marginRatio * areaShort
        t.marginY = t.marginX
        t.opacity = opacity
        t.color = WatermarkEngine.RGB(r: color.r * 255, g: color.g * 255, b: color.b * 255)
        t.backgroundEnabled = backgroundEnabled
        t.backgroundColor = WatermarkEngine.RGB(r: backgroundColor.r * 255, g: backgroundColor.g * 255,
                                                b: backgroundColor.b * 255)
        t.backgroundAlpha = backgroundAlpha
        t.fullWidth = fullWidth
        return t
    }
}

extension CollageMarkContrast {
    var label: String {
        switch self {
        case .original: return "原色"
        case .auto: return "自动"
        case .light: return "白"
        case .dark: return "黑"
        }
    }
}

extension WatermarkEngine.GridPosition {
    /// 九宫格位置的中文简称（拼图检视器、命令行摘要用）。
    var label: String {
        switch self {
        case .topLeft: return "左上"
        case .topCenter: return "上"
        case .topRight: return "右上"
        case .middleLeft: return "左"
        case .center: return "中"
        case .middleRight: return "右"
        case .bottomLeft: return "左下"
        case .bottomCenter: return "下"
        case .bottomRight: return "右下"
        }
    }
}

extension WatermarkEngine.GridPosition {
    /// 列：-1 左 / 0 中 / 1 右。
    var column: Int {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: return -1
        case .topCenter, .center, .bottomCenter: return 0
        case .topRight, .middleRight, .bottomRight: return 1
        }
    }

    /// 行：-1 上 / 0 中 / 1 下。
    var row: Int {
        switch self {
        case .topLeft, .topCenter, .topRight: return -1
        case .middleLeft, .center, .middleRight: return 0
        case .bottomLeft, .bottomCenter, .bottomRight: return 1
        }
    }

    static func at(row: Int, column: Int) -> Self {
        let grid: [[Self]] = [[.topLeft, .topCenter, .topRight],
                              [.middleLeft, .center, .middleRight],
                              [.bottomLeft, .bottomCenter, .bottomRight]]
        return grid[max(0, min(2, row + 1))][max(0, min(2, column + 1))]
    }

    /// 左右镜像（中间那列不动）/ 上下镜像（中间那行不动）。
    var mirroredH: Self { .at(row: row, column: -column) }
    var mirroredV: Self { .at(row: -row, column: column) }
}

extension CollageMarkLayer {
    /// 整层翻过去（压字躲让用）：签名、横向区域的位置、文字一起翻。
    func mirrored(h: Bool, v: Bool) -> CollageMarkLayer {
        func flip(_ p: WatermarkEngine.GridPosition) -> WatermarkEngine.GridPosition {
            let a = h ? p.mirroredH : p
            return v ? a.mirroredV : a
        }
        var out = self
        out.position = flip(position)
        out.landscapePosition = landscapePosition.map(flip)
        if let p = text?.position { out.text?.position = flip(p) }
        return out
    }
}

// MARK: - 渲染（只有界面预览、导出、命令行 renderclean / renderexport 进来）
//
// 位置一律在成品坐标（未缩放、不含出血）里定：区域、跳不跳过、压字躲让都按成品尺寸算，画的时候 CTM
// 乘缩放、加出血偏移 —— 0.5 倍预览和 1 倍导出里水印落在同一处，预览 = 导出。

enum CollageWatermarks {
    private static let imageLock = NSLock()
    private static var images: [String: CGImage] = [:]
    /// <dataDir>/collage/assets（CollageStore 初始化时告诉这里）。
    private static var assetsDir: URL?

    /// 区域短边小于这个（成品像素）就不画：格子太小，水印只会糊成一团。
    static let minSide: CGFloat = 96

    /// 签名图读不了时导出完的提示（状态栏、命令行导出提示）。说清楚去哪儿改：拼图右边检视器的「水印」，
    /// 不是左边那个「水印」tab —— 那边选的签名不会改到已经存进拼图的这一份。
    static let signatureLostWarning = "签名图找不到了，导出里没有签名 —— 在右边「水印」里点「选择签名…」重新选一张"
    /// 同一件事，检视器签名框里的说法（按钮就在下面）。
    static let signatureLostPanelWarning = "签名图找不到了，预览和导出里都没有签名 —— 点下面「选择签名…」重新选一张"

    static func setAssetsDir(_ url: URL) {
        imageLock.lock()
        assetsDir = url
        imageLock.unlock()
    }

    /// 签名该读哪个文件：工程里存的绝对路径；它没了（数据目录挪过、拷到别处）就用资料目录里同一个
    /// sha1 的副本。两个都没有 = nil。
    static func signatureFile(_ sig: CollageSignature) -> String? {
        candidates(sig).first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func candidates(_ sig: CollageSignature) -> [String] {
        imageLock.lock()
        let dir = assetsDir
        imageLock.unlock()
        guard let local = dir?.appendingPathComponent("\(sig.key).png").path, local != sig.file else { return [sig.file] }
        return [sig.file, local]
    }

    /// 签名解码后的长边上限。拖缝、拖大小滑杆时每格每帧的目标尺寸都在变，引擎每次都从这张重新缩放：
    /// 6000px 的扫描签名一次要 ~10ms、一帧 6 格就掉帧，2048 的 ~1ms。签名宽 = 区域短边 × 大小（滑杆最大 60%）：
    /// A4 300dpi 整页开到 60% 是 1488px，最大的 30cm 跨页半页开到 60% 也才刚到 2048。
    static let signatureMaxPixel = 2048

    /// 签名解码（按内容 sha1 缓存）。同一个签名永远返回同一个 CGImage 实例：引擎的 preparedSignature
    /// 按 === 命中缓存，换了实例每格每帧都要重新缩放着色。先读存的路径，读不了再读资料目录里的副本；
    /// 都读不了 = nil，不记下来（重新导入同一张又能画）。长边超过上限的等比缩到上限（不放大），缓存的就是缩好的。
    static func signatureImage(_ sig: CollageSignature) -> CGImage? {
        imageLock.lock()
        let hit = images[sig.key]
        imageLock.unlock()
        if let hit { return hit }
        let decoded = candidates(sig).lazy.compactMap { path -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            return decodeBounded(source)
        }.first
        guard let image = decoded else { return nil }
        imageLock.lock()
        defer { imageLock.unlock() }
        // 两个渲染线程同时解了同一张：留先进来的那个实例。
        if let raced = images[sig.key] { return raced }
        if images.count > 16 { images.removeAll() }
        images[sig.key] = image
        return image
    }

    /// 不超过上限的照原样解（和以前逐像素一样）；超过的走缩略图解码直接解成上限大小（不转方向，同原样解）。
    private static func decodeBounded(_ source: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard max(w, h) > signatureMaxPixel else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: signatureMaxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// 画的时候交给引擎的设置：边距取整（靠边的位置落在整像素上；居中的那一向靠区域奇偶对齐，见 Painter.plan）；
    /// 自定义字当模板填（拼图里自定义字可以写 {title} {date}，缺的占位符连同分隔符一起去掉）。
    static func drawConfig(_ layer: CollageMarkLayer, areaShort: Double) -> WatermarkEngine.Config {
        var c = layer.engineConfig(areaShort: areaShort)
        c.marginX = c.marginX.rounded()
        c.marginY = c.marginY.rounded()
        c.exifText.marginX = c.exifText.marginX.rounded()
        c.exifText.marginY = c.exifText.marginY.rounded()
        if c.exifText.enabled, !c.exifText.customText.isEmpty {
            c.exifText.template = c.exifText.customText
            c.exifText.customText = ""
        }
        return c
    }

    // 大小的上下限（成品像素；阈值都在这里）。比下限还小的水印看不清，等于没加：
    // - 签名宽 ≥ max(24, 画布短边 × 3%)：手机全屏看整张拼图时约 11pt，签名笔画还分得开；24px 兜住小画布。
    //   比例算出来更小就先放大到下限，但最多占那块宽的 45%（不能把小格子整个盖住），还不够就不画。
    // - 签名装进一块时最多占那块宽的 90%（两边总得留点照片）。
    // - 字号 ≥ max(9, 画布短边 × 0.8%)：A4 300dpi 印出来约 5pt（印刷最小可读字号附近）；9px 是屏幕上
    //   汉字笔画还认得出的最小像素。低于它这一块不写字。
    // 「画布短边」按一眼看到的那一张算：九宫格发出去是九张、轮播是一张张划着看，按一片的短边。

    static func signatureFloor(_ canvas: CollageCanvas) -> CGFloat { max(24, viewShort(canvas) * 0.03) }
    static let signatureGrowCap: CGFloat = 0.45
    static let signatureFitCap: CGFloat = 0.9
    static func fontFloor(_ canvas: CollageCanvas) -> CGFloat { max(9, viewShort(canvas) * 0.008) }

    private static func viewShort(_ canvas: CollageCanvas) -> CGFloat {
        let w = CGFloat(canvas.width), h = CGFloat(canvas.height)
        switch canvas.seams {
        case .grid9: return min(w, h) / 3
        case .carousel: return min(h, w / CGFloat(max(1, canvas.slides)))
        case .fold, .none: return min(w, h)
        }
    }

    // 整页层放进版心外的留白带（preferMargin）：
    // - 带厚 ≥ 东西自然高度的 60% 才放（再薄就得缩到原来的四成以下，签名、字都太小，不如压在照片上）；
    // - 放进去按带厚的 72% 等比缩（不放大），上下各留 14%，不贴着照片边、也不贴着裁切边。
    static let bandMinFill: CGFloat = 0.6
    static let bandFill: CGFloat = 0.72

    /// 深浅的两种颜色：白、近黑（0x1D1D1F：纯黑压在照片上发死，和系统深色字同一个）。
    static func ink(_ tone: CollageMarkContrast) -> WatermarkEngine.RGB {
        tone == .dark ? WatermarkEngine.RGB(r: 0x1D, g: 0x1D, b: 0x1F) : WatermarkEngine.RGB(r: 255, g: 255, b: 255)
    }

    /// 被后画的图层（相纸、贴纸、手写字）盖住这么多（按面积）就不画了：剩下的露不出一半，签名认不出、字读不全。
    /// 盖住一点的只在挑位置时躲（四个方向都躲不开就照画）。
    static let hiddenMax = 0.5

    /// 页底在哪儿多亮（整页层「自动深浅」看框落在留白里的那部分）。纯色、取色的底处处一样；主图模糊底 =
    /// 模糊图按铺法对上去、再盖一层纸色；渐变底 = 上下两色按高度插。位置一律按导出（带出血）的铺法在成品
    /// 坐标里算 —— 预览不带出血、铺法差几像素，但预览和导出选的一样。
    struct Paper {
        /// 代表色的亮度（照片读不了、没有模糊图时都按它）。
        var flat: Double
        /// 模糊底：模糊图（调过色）的亮度网格、它铺在成品坐标里的哪块、盖了几成纸色、纸色亮度。
        var blur: (grid: CollageOverlays.Grid, rect: CGRect, wash: Double, paper: Double)?
        /// 渐变底：上沿、下沿的亮度和它们在成品坐标里的 y。
        var gradient: (top: Double, bottom: Double, y0: CGFloat, y1: CGFloat)?

        init(flat: Double) { self.flat = flat }

        /// 框（成品坐标）底下页底的平均亮度。亮度对颜色是线性的：盖纸色、渐变插值都能直接按亮度算。
        func lum(_ box: CGRect) -> Double {
            if let b = blur, b.rect.width > 0, b.rect.height > 0 {
                let unit = CGRect(x: (box.minX - b.rect.minX) / b.rect.width, y: (box.minY - b.rect.minY) / b.rect.height,
                                  width: box.width / b.rect.width, height: box.height / b.rect.height)
                if let stats = b.grid.stats(in: unit) { return stats.mean * (1 - b.wash) + b.paper * b.wash }
            }
            if let g = gradient, g.y1 > g.y0 {
                let t = Double(min(1, max(0, (box.midY - g.y0) / (g.y1 - g.y0))))
                return g.top + (g.bottom - g.top) * t
            }
            return flat
        }
    }

    /// 后画的图层盖在水印上：图层是转过的四边形（成品坐标），水印框按 map 映到成品坐标再比。
    enum Cover {
        static func quad(_ r: CGRect, _ map: CGAffineTransform) -> [CGPoint] {
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(map) }
        }

        /// 框和哪一个图层有交叠（只贴着边、差不到半个像素的不算）。
        static func touches(_ r: CGRect, _ map: CGAffineTransform, _ quads: [[CGPoint]]) -> Bool {
            let box = quad(r, map)
            return quads.contains { overlaps(box, $0) }
        }

        /// 框被盖住几成：框里均匀取 8×4 个点，落在任何一个图层里的占多少。
        static func hidden(_ r: CGRect, _ map: CGAffineTransform, _ quads: [[CGPoint]]) -> Double {
            guard !quads.isEmpty, r.width > 0, r.height > 0 else { return 0 }
            let nx = 8, ny = 4
            var covered = 0
            for j in 0..<ny {
                for i in 0..<nx {
                    let p = CGPoint(x: r.minX + r.width * (CGFloat(i) + 0.5) / CGFloat(nx),
                                    y: r.minY + r.height * (CGFloat(j) + 0.5) / CGFloat(ny)).applying(map)
                    if quads.contains(where: { inside(p, $0) }) { covered += 1 }
                }
            }
            return Double(covered) / Double(nx * ny)
        }

        /// 两个凸四边形有没有交叠（分离轴：任一条边的法向上投影分得开就没交叠）。
        private static func overlaps(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
            for poly in [a, b] {
                for i in poly.indices {
                    let p = poly[i], q = poly[(i + 1) % poly.count]
                    let len = max(1e-9, hypot(q.x - p.x, q.y - p.y))
                    let nx = (q.y - p.y) / len, ny = (p.x - q.x) / len
                    let pa = a.map { $0.x * nx + $0.y * ny }
                    let pb = b.map { $0.x * nx + $0.y * ny }
                    guard let a0 = pa.min(), let a1 = pa.max(), let b0 = pb.min(), let b1 = pb.max() else { return false }
                    if a1 <= b0 + 0.5 || b1 <= a0 + 0.5 { return false }
                }
            }
            return true
        }

        /// 点在凸四边形里（四条边的叉积同号）。
        private static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
            var sign: CGFloat = 0
            for i in poly.indices {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if cross == 0 { continue }
                if sign == 0 { sign = cross } else if (sign > 0) != (cross > 0) { return false }
            }
            return true
        }
    }

    /// 整页水印挪进留白带时要躲开的（成品坐标）：文字格、自由图层（贴纸、胶带、手写字、相纸，转过的取外接框）。
    static func obstacles(page: CollagePage, frames: [CollageLayout.Frame], canvas: CollageCanvas) -> [CGRect] {
        let cells = page.freeform ? [] : frames.filter { $0.cell.kind == .text }.map(\.rect.cgRect)
        return cells + page.items.map { CollageItems.bounds($0, canvas: canvas) }
    }

    /// 整页层在这一页上排在哪（不画、不着色）：检视器「整张一次切开后在第几片」按它说。和渲染走同一个
    /// Painter.prepare（同样的区域、留白带、文字格和图层、主图的字、缓存的签名），换到留白带另一头、签名读不了
    /// 都算进去。一样东西一个框（成品坐标）；平铺的签名 kind = "tile"。
    static func pagePlacement(project: CollageProject, page: CollagePage) -> [(kind: String, rect: CGRect)] {
        var options = CollageRender.Options()
        options.watermark = true
        guard project.watermark?.page != nil,
              let painter = Painter(project: project, options: options, bleed: 0, paper: { Paper(flat: 0.5) })
        else { return [] }
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        let canvas = project.canvas
        let style = project.style
        let frames = CollageLayout.geometry(page.root, in: CollageLayout.contentRect(canvas: canvas, style: style),
                                            gutter: CollageLayout.gutterPixels(canvas: canvas, style: style)).frames
        let vars = CollageTypeset.variables(project: project, root: page.root, photos: photos,
                                            pagePhotoIDs: page.photoIDs, pageID: page.id)
        painter.prepare(page: page, pagePhotoIDs: page.photoIDs, photos: photos, vars: vars, frames: frames)
        return painter.pagePlacement()
    }

    /// 往里取整到整像素（区域左上角、宽高都是整数）。
    static func snapped(_ r: CGRect) -> CGRect {
        let x0 = (r.minX - 1e-6).rounded(.up)
        let y0 = (r.minY - 1e-6).rounded(.up)
        let x1 = (r.maxX + 1e-6).rounded(.down)
        let y1 = (r.maxY + 1e-6).rounded(.down)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// 一块水印的落点：区域（整像素）、引擎设置、签名 / 文字框（区域本地坐标）。签名和字落在不同块时
    /// 各一个（一个只开签名、一个只开字）。
    struct Plan {
        var region: CGRect
        var config: WatermarkEngine.Config
        var layout: WatermarkEngine.MarkLayout
        /// 平铺只画在这几块里（和 region 同一坐标系：区域减去切带）；空 = 整个 region。
        var clips: [CGRect] = []
        /// 躲不开压字，照原位置画了。
        var conflict = false
        /// 实际用的深浅（签名、字各一个；「自动」选定之后是 light / dark）。
        var signatureTone = CollageMarkContrast.original
        var textTone = CollageMarkContrast.original
        /// 放进了版心外的留白带（整页层）。
        var inMargin = false

        /// 签名、文字框（region 所在的坐标系）。平铺的签名满区域都是，不算。
        var boxes: [CGRect] {
            [layout.signature, layout.text].compactMap { $0?.offsetBy(dx: region.minX, dy: region.minY) }
        }
    }

    /// 一层水印在一块区域里的结果：要画的几块，和没画成的原因（「签名放不下」「字放不下」「压缝」…）。
    struct Marks {
        var plans: [Plan] = []
        var notes: [String] = []

        var boxes: [CGRect] { plans.flatMap(\.boxes) }

        /// 压着不该压的（why 给出原因）那样不画、记下原因；另一样照画（引擎排签名和排字互不影响）。
        func dropping(_ why: (CGRect) -> String?) -> Marks {
            var out = self
            for i in out.plans.indices {
                let o = out.plans[i].region.origin
                if let s = out.plans[i].layout.signature, let reason = why(s.offsetBy(dx: o.x, dy: o.y)) {
                    out.plans[i].config.signatureEnabled = false
                    out.plans[i].layout.signature = nil
                    out.notes.append(reason)
                }
                if let t = out.plans[i].layout.text, let reason = why(t.offsetBy(dx: o.x, dy: o.y)) {
                    out.plans[i].config.exifText.enabled = false
                    out.plans[i].layout.text = nil
                    out.notes.append(reason)
                }
            }
            return out
        }
    }

    /// 字要怎么调才放得下、不压签名。
    private enum TextFix {
        /// 字号乘这个。
        case shrink(CGFloat)
        /// 字那一边的上下边距改成这个（叠到签名上面 / 下面）。
        case stack(Double)
        /// 怎么调都不行，这一块不写字。
        case drop
    }

    /// 这一页上照片画在哪（按画的顺序记）：整页层「自动深浅」看框底下压着哪张照片。
    private final class Underlay {
        struct Spot {
            /// 成品坐标 → 照片所在的坐标（格子 = 不变；相纸 = 转回相纸本地）。
            var toLocal: CGAffineTransform
            /// drawn = 照片画的那块（toLocal 那一侧的坐标）。
            var mapper: CollageOverlays.Mapper
            var photo: CollagePhotoRef
        }
        var spots: [Spot] = []
    }

    /// 画格子之前备好的（Painter.prepare）：整页层的落点（只按页面几何排，还没着色），和页上图层的位置。
    private final class Sheet {
        /// 整页层的 tags（主图的 EXIF 盖在版面占位符上）、每块区域的落点。
        var tags = WatermarkEngine.ExifTags(source: nil)
        var pageAreas: [(owner: String, area: CGRect, marks: Marks?)] = []
        /// 整页层的签名、字框（成品坐标；平铺的满页都是，不算）：每张照片层的水印让着它。
        var pageBoxes: [CGRect] = []
        /// 页上图层（相纸、贴纸、手写字）转过之后的四个角，顺序同 page.items；导出里不印的 = nil。
        /// 它们都画在格子之后、相纸按顺序一张压一张：水印不躲进后画的图层底下。
        var items: [[CGPoint]?] = []
    }

    /// 一次渲染里画水印要的东西（render() 开头备好一次）。
    struct Painter {
        let project: CollageProject
        let watermark: CollageWatermark
        let signature: CGImage?
        let scale: CGFloat
        let bleed: CGFloat
        /// 切带（相册中缝、九宫格 / 轮播切线，和参考线同一套几何）：水印不跨、不压。
        let seams: [CGRect]
        let report: CollageRender.RenderReport?
        /// 页底的亮度：「自动深浅」框落在留白里（或者照片读不了）时按它。
        let paper: Paper
        /// 整页层开着「自动深浅」才记照片落点（drawCell / drawItem 记、drawPage 用）。
        private let underlay: Underlay?
        private let sheet = Sheet()

        /// paper：只在真要画水印时才算（主图模糊底要读模糊图）。
        init?(project: CollageProject, options: CollageRender.Options, bleed: Int, paper: () -> Paper) {
            guard options.watermark, let wm = project.watermark, wm.photos != nil || wm.page != nil else { return nil }
            self.project = project
            watermark = wm
            signature = wm.signature.flatMap(CollageWatermarks.signatureImage)
            scale = CGFloat(options.scale)
            self.bleed = CGFloat(bleed)
            seams = CollageLayout.seamLines(project.canvas)
            report = options.report
            self.paper = paper()
            underlay = wm.page?.contrast == .auto ? Underlay() : nil
        }

        /// 画格子之前：记下页上图层在哪，整页层先排好（每张照片层要让着它）。整页层只按页面几何排（区域、
        /// 留白带、文字格和图层、主图的字），和每张照片层画在哪无关 —— 检视器说「整张一次落在第几片」用的
        /// 也是这里（pagePlacement），说的就是画出来的。
        func prepare(page: CollagePage, pagePhotoIDs: [String], photos: [String: CollagePhotoRef],
                     vars: [String: String], frames: [CollageLayout.Frame]) {
            sheet.items = CollageItems.printedCorners(page.items, photos: photos, canvas: canvas)
            guard let layer = watermark.page else { return }
            var values = vars
            if let hero = CollageRender.heroPhoto(pagePhotoIDs, photos: photos) {
                for (k, v) in CollageTypeset.exifValues(hero.path) { values[k] = v }
            }
            var tags = WatermarkEngine.ExifTags(source: nil)
            tags.values = values
            sheet.tags = tags
            let obstacles = CollageWatermarks.obstacles(page: page, frames: frames, canvas: canvas)
            sheet.pageAreas = pageAreas().map { owner, area in
                let banded = layer.preferMargin ? marginMarks(layer, in: area, tags: tags, obstacles: obstacles) : nil
                return (owner, area, banded ?? layout(layer, in: area, cut: true, tags: tags))
            }
            sheet.pageBoxes = sheet.pageAreas.flatMap { $0.marks?.boxes ?? [] }
        }

        /// prepare 排好的整页层，一样东西一个框（成品坐标）；平铺的签名记整块区域、kind = "tile"。
        func pagePlacement() -> [(kind: String, rect: CGRect)] {
            sheet.pageAreas.flatMap { entry in
                (entry.marks?.plans ?? []).flatMap { plan -> [(kind: String, rect: CGRect)] in
                    let o = plan.region.origin
                    var out: [(kind: String, rect: CGRect)] = []
                    if plan.layout.tiled { out.append(("tile", plan.region)) }
                    if let s = plan.layout.signature { out.append(("signature", s.offsetBy(dx: o.x, dy: o.y))) }
                    if let t = plan.layout.text { out.append(("text", t.offsetBy(dx: o.x, dy: o.y))) }
                    return out
                }
            }
        }

        /// 成品坐标里的框压着整页层的签名 / 字：每张照片层让开（整页那一个是用户摆的位置，不挪它）。
        private func yields(_ box: CGRect) -> String? {
            sheet.pageBoxes.contains { $0.intersects(box) } ? "让整页水印" : nil
        }

        private var canvas: CollageCanvas { project.canvas }

        /// 成品区，有安全区就往里收。
        private var safeRect: CGRect {
            let full = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
            let safe = CGFloat(max(0, canvas.safe))
            return safe > 0 ? full.insetBy(dx: safe, dy: safe) : full
        }

        /// 成品坐标 → 这次渲染的像素（加出血、乘缩放）。
        private func toCanvas(_ ctx: CGContext) {
            ctx.translateBy(x: bleed, y: bleed)
            ctx.scaleBy(x: scale, y: scale)
        }

        // MARK: 每张照片 —— 网格格子

        /// drawPhoto、drawOverlay 之后。frameRect = 这一格的成品坐标；区域和压字用同一套几何（月洞门 /
        /// 拱窗取内接、完整显示只取照片本身、相纸 / 胶片取内框），不用 drawPhoto 里铺进出血的那块。
        func drawCell(_ cell: CollageCell, path: [Int], frameRect: CGRect, photo: CollagePhotoRef,
                      framing: CollageFraming, hints: CollageCrop.Hints?, vars: [String: String],
                      background: CollageColor, ctx: CGContext) {
            guard watermark.photos != nil || underlay != nil else { return }
            let style = project.style
            let g = CollageRender.overlayGeometry(cell: cell, frameRect: frameRect, style: style, photo: photo,
                                                  framing: framing, hints: hints)
            let mapper = CollageOverlays.Mapper(drawn: g.drawn, window: g.window)
            underlay?.spots.append(.init(toLocal: .identity, mapper: mapper, photo: photo))
            guard let layer = watermark.photos else { return }
            let owner = path.isEmpty ? "r" : path.map(String.init).joined()
            let shape = cell.shape ?? style.shape
            var geo = Geometry(cell: frameRect, visible: g.drawn, shape: shape.rawValue)
            guard !watermark.skipPhotoIDs.contains(photo.id) else {
                note(layer: "photo", owner: owner, region: nil, skipped: "这张不加", geo: geo)
                return
            }
            let corner = CGFloat(style.corner * canvas.shortSide)
            var area = g.textArea
            // 圆角：四角各让 0.3 × 圆角（45° 方向圆弧离直角 0.293r），框角不会被圆角切掉。
            if shape == .rounded { area = area.insetBy(dx: corner * 0.3, dy: corner * 0.3) }
            area = area.intersection(safeRect)
            let avoid = cell.overlay.flatMap {
                CollageRender.overlayPlacement($0, cell: cell, frameRect: frameRect, project: project, photo: photo,
                                               framing: framing, hints: hints, vars: vars,
                                               background: background)?.rect
            }
            let tags = photoTags(photo, vars: vars)
            geo.avoid = avoid
            // 页上的图层都画在格子之后：压在它们底下的水印看不见。
            let covers = sheet.items.compactMap { $0 }
            let placed = place(layer, area: area, cut: true, tags: tags) { box in
                (avoid.map(box.intersects) ?? false) || yields(box) != nil || Cover.touches(box, .identity, covers)
            }
            var marks = placed?.marks
            // 四个方向都躲不开：压着整页水印的、大半被图层盖住的那样不画（记下原因）；压字的照原位置画，
            // 压着的那块记「压字冲突未解」。
            if placed?.stuck == true {
                marks = marks?.dropping { box in
                    yields(box) ?? (Cover.hidden(box, .identity, covers) >= CollageWatermarks.hiddenMax ? "被盖住" : nil)
                }
            }
            if placed?.stuck == true, let avoid, var m = marks {
                for i in m.plans.indices where m.plans[i].boxes.contains(where: { $0.intersects(avoid) }) {
                    m.plans[i].conflict = true
                }
                marks = m
            }
            marks = toned(marks, layer) { photoLum($0, photo: photo, mapper: mapper) ?? paper.flat }
            record(marks, layer: "photo", owner: owner, area: area, geo: geo)
            guard let marks, !marks.plans.isEmpty else { return }
            ctx.saveGState()
            toCanvas(ctx)
            let framed = CollageCrop.isFramed(cell: cell, style: style)
            ctx.addPath(framed ? CGPath(rect: g.drawn, transform: nil)
                               : CollageRender.shapePath(shape, rect: g.drawn, corner: corner))
            ctx.clip()
            for plan in marks.plans { paint(plan, tags: tags, ctx: ctx) }
            ctx.restoreGState()
        }

        // MARK: 每张照片 —— 自由 / 散落相纸

        /// ctx 已在相纸本地坐标（单位 = 成品像素，CTM 乘过缩放、转过角度）；水印跟着相纸一起转。
        /// inner = 照片画的那块（本地坐标）。相纸不按切带切（它是斜的），改成按转过之后的外接框查：
        /// 压到切带、出了安全区（散落版只让脸躲开切线，手动摆的还能拖到页边外）、压着整页水印，或者被后画的
        /// 图层（压在上面的相纸、胶带、手写字）盖着，就翻到另一边；四个方向都不行，压缝 / 出安全区 / 压着整页
        /// 水印 / 大半被盖住的那样不画（记下原因），只被盖住一角的照画。
        func drawItem(_ item: CollageItem, index: Int, inner: CGRect, photo: CollagePhotoRef,
                      window: CollageCrop.Window, vars: [String: String], ctx: CGContext) {
            let toPage = CollageItems.transform(item, canvas: canvas)
            let mapper = CollageOverlays.Mapper(drawn: inner, window: window)
            underlay?.spots.append(.init(toLocal: toPage.inverted(), mapper: mapper, photo: photo))
            guard let layer = watermark.photos else { return }
            let owner = "item\(index)"
            let outer = CollageItems.localRect(item, canvas: canvas).applying(toPage)
            let geo = Geometry(cell: outer, visible: inner.applying(toPage), shape: "item")
            guard !watermark.skipPhotoIDs.contains(photo.id) else {
                note(layer: "photo", owner: owner, region: nil, skipped: "这张不加", geo: geo)
                return
            }
            var area = inner
            // 相角压着四个角：斜边离角 0.44 × 腿长，收 0.6 × 腿长就躲开了。
            if item.frame == .mounts {
                let leg = min(inner.width, inner.height) * 0.14
                area = area.insetBy(dx: leg * 0.6, dy: leg * 0.6)
            }
            let tags = photoTags(photo, vars: vars)
            let offence = { (box: CGRect) in self.offence(box.applying(toPage)) }
            // 后画的图层（导出里也印的）：这张相纸之后的那些。
            let above = sheet.items.count > index + 1 ? sheet.items[(index + 1)...].compactMap { $0 } : []
            let placed = place(layer, area: area, cut: false, tags: tags) {
                offence($0) != nil || Cover.touches($0, toPage, above)
            }
            let kept = placed?.stuck == true ? placed?.marks.dropping { box in
                offence(box) ?? (Cover.hidden(box, toPage, above) >= CollageWatermarks.hiddenMax ? "被盖住" : nil)
            } : placed?.marks
            let marks = toned(kept, layer) { photoLum($0, photo: photo, mapper: mapper) ?? paper.flat }
            record(marks, layer: "photo", owner: owner, area: area, geo: geo, map: toPage)
            for plan in marks?.plans ?? [] { paint(plan, tags: tags, ctx: ctx) }
        }

        /// 成品坐标里的一个框压到切带 / 出了安全区 / 压着整页水印：原因；没事 = nil。
        private func offence(_ box: CGRect) -> String? {
            if seams.contains(where: { $0.intersects(box) }) { return "压缝" }
            guard safeRect.insetBy(dx: -0.01, dy: -0.01).contains(box) else { return "出安全区" }
            return yields(box)
        }

        // MARK: 整页

        /// items 之后、参考线之前，画 prepare 排好的：相册按半页、九宫格 / 轮播每片一个时按片（和导出切图同一套
        /// 整数边界）；整张一次时整页一块，切带由 layout 再切（签名、字各落在自己所在的那一片）。
        /// tags = 主图的 EXIF 盖在版面占位符上（{date} 和水印页一样是 yyyy-MM-dd）。整页层不躲压字、不躲每张
        /// 照片的水印（那边让它）；版心外有够宽的留白就放进留白里（躲开文字格、自由图层）。深浅在这里定：
        /// 「自动」要看照片都画在哪（格子、相纸画完才知道）。
        func drawPage(ctx: CGContext) {
            guard let layer = watermark.page else { return }
            let full = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
            let geo = Geometry(cell: full, visible: full, shape: "page")
            for (owner, area, planned) in sheet.pageAreas {
                let marks = toned(planned, layer) { pageLum($0) }
                record(marks, layer: "page", owner: owner, area: area, geo: geo)
                guard let marks, !marks.plans.isEmpty else { continue }
                ctx.saveGState()
                toCanvas(ctx)
                for plan in marks.plans { paint(plan, tags: sheet.tags, ctx: ctx) }
                ctx.restoreGState()
            }
        }

        /// 整页层的各块（成品坐标，已收安全区；切带由 layout 再切）。
        private func pageAreas() -> [(String, CGRect)] {
            let base = safeRect
            switch canvas.seams {
            case .fold:
                let mid = CGFloat(canvas.width) / 2
                let fold = seams.first ?? CGRect(x: mid, y: 0, width: 0, height: CGFloat(canvas.height))
                let left = CGRect(x: base.minX, y: base.minY, width: fold.minX - base.minX, height: base.height)
                let right = CGRect(x: fold.maxX, y: base.minY, width: base.maxX - fold.maxX, height: base.height)
                return watermark.albumSides == .both ? [("left", left), ("right", right)] : [("right", right)]
            case .grid9, .carousel:
                guard watermark.tiles == .eachTile else { return [("page", base)] }
                let grid = canvas.seams == .grid9
                let tiles = CollageExport.tileRects(width: canvas.width, height: canvas.height, rows: grid ? 3 : 1,
                                                    cols: grid ? 3 : max(1, canvas.slides))
                return tiles.enumerated().map { ("tile\($0.offset + 1)", $0.element.intersection(base)) }
            case .none:
                return [("page", base)]
            }
        }

        // MARK: 整页 —— 留白带

        /// 一样东西（签名或字）放进留白带：哪条带（已 ∩ 区域）、锚点（换到另一头时跟着换）、缩成原来的多少。
        private struct BandFit {
            var band: CGRect
            var anchor: WatermarkEngine.GridPosition
            var scale: CGFloat
            var flipped = false

            /// 上 / 下带（锚点在上排 / 下排）；不然是左 / 右带。
            var horizontal: Bool { anchor.row != 0 }
            /// 带里的位置：上下带竖着居中、横着照锚点；左右带两向都居中（锚点本来就在中排）。
            var position: WatermarkEngine.GridPosition { horizontal ? .at(row: 0, column: anchor.column) : .center }
            /// 同一条带的另一头：只有上下带的左右两头能换（居中的、换过一次的没有）。
            var otherEnd: BandFit? {
                guard horizontal, anchor.column != 0, !flipped else { return nil }
                var out = self
                out.anchor = anchor.mirroredH
                out.flipped = true
                return out
            }
        }

        /// 锚点那条边的留白带（版心外、安全区里，∩ 这块区域）放不放得下：带厚 ≥ 自然大小 × bandMinFill 才放，
        /// 放进去缩到带厚 × bandFill（不放大）。上下带比高，左右带比宽（东西横着摆，横跨左右带的是宽）。
        /// 正中、没有留白（margin = 0、留白全落在安全区里）、这块区域不贴着那条边 = nil。
        private func bandFit(_ anchor: WatermarkEngine.GridPosition, area: CGRect, natural: CGSize) -> BandFit? {
            guard anchor.row != 0 || anchor.column != 0, natural.width > 0, natural.height > 0 else { return nil }
            let content = CollageLayout.contentRect(canvas: canvas, style: project.style).cgRect
            let s = safeRect
            let horizontal = anchor.row != 0
            let thick = anchor.row > 0 ? s.maxY - content.maxY : anchor.row < 0 ? content.minY - s.minY
                : anchor.column > 0 ? s.maxX - content.maxX : content.minX - s.minX
            guard thick > 0 else { return nil }
            let y0 = anchor.row > 0 ? content.maxY : s.minY
            let x0 = anchor.column > 0 && !horizontal ? content.maxX : s.minX
            let band = CGRect(x: x0, y: y0, width: horizontal ? s.width : thick, height: horizontal ? thick : s.height)
                .intersection(area)
            guard !band.isNull, band.width > 0, band.height > 0 else { return nil }
            let room = horizontal ? band.height : band.width
            let extent = horizontal ? natural.height : natural.width
            guard room >= extent * CollageWatermarks.bandMinFill else { return nil }
            return BandFit(band: band, anchor: anchor, scale: min(1, room * CollageWatermarks.bandFill / extent))
        }

        /// 整页层「有留白时放在留白里」：签名、字各看自己锚点那条边的留白带（bandFit），大小先按压在照片上时
        /// 一样算（整块区域），再按带缩、仍受下限；放进去的竖着居中、横着照锚点和边距。挡着文字格、自由图层
        /// （obstacles）就换到同一条带的另一头，还挡着、或者带里排不下，就照旧压在照片上。放不进去的那样照旧排
        /// （layout），和带里的叠了就整层照旧排。一样都放不进 = nil。
        private func marginMarks(_ layer: CollageMarkLayer, in rawArea: CGRect, tags: WatermarkEngine.ExifTags,
                                 obstacles: [CGRect]) -> Marks? {
            let area = CollageWatermarks.snapped(rawArea)
            let areaShort = min(area.width, area.height)
            let areaLong = max(area.width, area.height)
            guard areaShort >= CollageWatermarks.minSide else { return nil }
            var base = CollageWatermarks.drawConfig(layer, areaShort: Double(areaShort))
            base.landscapeOverrideEnabled = false
            let anchor = area.width >= area.height ? (layer.landscapePosition ?? layer.position) : layer.position
            var sig: (fit: BandFit, w: Int)?
            if layer.signatureOn, layer.tile == nil, watermark.signature != nil, signature != nil,
               let w = signatureWidth(layer.sizeRatio, areaShort: areaShort, room: area, margin: 0, fit: false),
               let fit = bandFit(anchor, area: area, natural: CGSize(width: w, height: signatureHeight(w))) {
                let scaled = Int((CGFloat(w) * fit.scale).rounded(.down))
                if CGFloat(scaled) >= CollageWatermarks.signatureFloor(canvas).rounded(.up) { sig = (fit, scaled) }
            }
            var text: (fit: BandFit, font: CGFloat)?
            if let t = layer.text {
                let font = CGFloat(t.fontSizeRatio) * areaLong
                if let size = textSize(base, font: font, in: area, tags: tags),
                   let fit = bandFit(t.position, area: area, natural: size),
                   font * fit.scale >= CollageWatermarks.fontFloor(canvas) {
                    text = (fit, font * fit.scale)
                }
            }
            // 挡着东西 / 带里排不下：先换另一头，再不行就不进留白（每次至少改掉一样，一定停得下来）。
            func box(_ plans: [Plan], _ part: (WatermarkEngine.MarkLayout) -> CGRect?) -> CGRect? {
                plans.compactMap { p in part(p.layout).map { $0.offsetBy(dx: p.region.minX, dy: p.region.minY) } }.first
            }
            func blocked(_ r: CGRect?) -> Bool { r.map { b in obstacles.contains { $0.intersects(b) } } ?? true }
            var marks = Marks()
            while sig != nil || text != nil {
                marks = Marks()
                marks.plans = bandPlans(sig: sig, text: text, base: base, tags: tags, notes: &marks.notes)
                let sigBox = box(marks.plans, \.signature)
                let textBox = box(marks.plans, \.text)
                let sigBad = sig != nil && blocked(sigBox)
                let textBad = text != nil && blocked(textBox)
                guard sigBad || textBad else { break }
                if sigBad { sig = sigBox == nil ? nil : sig.flatMap { s in s.fit.otherEnd.map { ($0, s.w) } } }
                if textBad { text = textBox == nil ? nil : text.flatMap { t in t.fit.otherEnd.map { ($0, t.font) } } }
            }
            guard sig != nil || text != nil else { return nil }
            for i in marks.plans.indices { marks.plans[i].inMargin = true }
            var rest = layer
            if sig != nil { rest.signatureOn = false }
            if text != nil { rest.text = nil }
            guard rest.hasContent(signature: watermark.signature != nil) else { return marks }
            guard let other = layout(rest, in: rawArea, cut: true, tags: tags) else { return nil }
            let mine = marks.boxes
            if other.boxes.contains(where: { b in mine.contains { $0.intersects(b) } }) { return nil }
            marks.plans += other.plans
            marks.notes += other.notes
            return marks
        }

        /// 字照这个字号（成品像素）排出来的自然大小（最宽一行 + 内边距、总高）；字是空的 = nil。
        private func textSize(_ base: WatermarkEngine.Config, font: CGFloat, in area: CGRect,
                              tags: WatermarkEngine.ExifTags) -> CGSize? {
            var c = base
            c.signatureEnabled = false
            c.exifText.fontSizeRatio = Double(font) / Double(max(area.width, area.height))
            return measure(area, c, tags).textSize
        }

        /// 放进留白带的签名（宽 w）、字（字号 font）排出来：落在带里同一块（切带切开之后）的一起排（字让签名），
        /// 不在一块的各排各的。带里竖着居中（那一向的边距不用），横着的边距照整块区域算。
        private func bandPlans(sig: (fit: BandFit, w: Int)?, text: (fit: BandFit, font: CGFloat)?,
                               base: WatermarkEngine.Config, tags: WatermarkEngine.ExifTags,
                               notes: inout [String]) -> [Plan] {
            var config = base
            if let s = sig {
                config.position = s.fit.position
                config.marginY = 0
                if !s.fit.horizontal { config.marginX = 0 }
            }
            if let t = text {
                config.exifText.position = t.fit.position
                config.exifText.marginY = 0
                if !t.fit.horizontal { config.exifText.marginX = 0 }
            }
            let sigPiece = sig.flatMap { piece(of: $0.fit.band, anchor: $0.fit.position, cut: true, thin: true) }
            let textPiece = text.flatMap { piece(of: $0.fit.band, anchor: $0.fit.position, cut: true, thin: true) }
            // 签名沿着带也得装得下（同 signatureWidth 的 90%、两头边距）；装不下、缩到下限以下就不排。
            func width(in piece: CGRect) -> Int? {
                guard let s = sig else { return nil }
                let along = s.fit.horizontal ? piece.width : piece.height
                let room = min(along * CollageWatermarks.signatureFitCap, along - 2 * CGFloat(config.marginX))
                let w = min(CGFloat(s.w), room.rounded(.down))
                return w >= CollageWatermarks.signatureFloor(canvas).rounded(.up) ? Int(w) : nil
            }
            var plans: [Plan] = []
            // 同一头（都在右头 / 都在左头）：带里叠不了，字排在签名里侧，隔一个边距。
            if let sp = sigPiece, sp == textPiece, let s = sig, let t = text, s.fit.horizontal,
               s.fit.position == t.fit.position, s.fit.position.column != 0 {
                guard let w = width(in: sp), let sp0 = plan(in: sp, base: config, sigW: w, font: nil, tags: tags,
                                                           notes: &notes) else { return plans }
                plans.append(sp0)
                guard let box = sp0.boxes.first else { return plans }
                let gap = max(CGFloat(config.marginX), 2)
                let right = s.fit.position.column > 0
                let x0 = right ? sp.minX + CGFloat(config.marginX) : box.maxX + gap
                let x1 = right ? box.minX - gap : sp.maxX - CGFloat(config.marginX)
                var c = config
                c.exifText.marginX = 0
                let room = CGRect(x: x0, y: sp.minY, width: max(0, x1 - x0), height: sp.height)
                if room.width >= CollageWatermarks.minSide,
                   let p = plan(in: room, base: c, sigW: nil, font: t.font, tags: tags, notes: &notes) {
                    plans.append(p)
                }
                return plans
            }
            if let sp = sigPiece, sp == textPiece {
                if let p = plan(in: sp, base: config, sigW: width(in: sp), font: text?.font, tags: tags, notes: &notes) {
                    plans.append(p)
                }
                return plans
            }
            if let sp = sigPiece, let w = width(in: sp),
               let p = plan(in: sp, base: config, sigW: w, font: nil, tags: tags, notes: &notes) {
                plans.append(p)
            }
            if let tp = textPiece, let t = text,
               let p = plan(in: tp, base: config, sigW: nil, font: t.font, tags: tags, notes: &notes) {
                plans.append(p)
            }
            return plans
        }

        // MARK: 深浅

        /// 深浅（original 不动：tint 照 engineConfig 染）。light / dark = 签名染白 / 近黑、字白 / 近黑；auto = 看框
        /// 底下多亮（lum 收框在成品坐标或相纸本地坐标里的位置，和这次渲染的缩放无关 —— 预览、导出选的一样），按压字
        /// 同一条线在白、黑里挑。字带背景框时 auto 不改字色（框托着字，设定的颜色本来就配那个框）；明确选了白 / 黑
        /// 而底色和字是一个深浅（默认的深色底配黑字），底色换成反色 —— 不然黑字压在深色底上看不见。
        private func toned(_ marks: Marks?, _ layer: CollageMarkLayer, lum: (CGRect) -> Double) -> Marks? {
            guard var out = marks, layer.contrast != .original else { return marks }
            for i in out.plans.indices {
                let plan = out.plans[i]
                let o = plan.region.origin
                func pick(_ box: CGRect?) -> CollageMarkContrast {
                    guard layer.contrast == .auto else { return layer.contrast }
                    guard let box else { return .light }
                    return CollageOverlays.tone(lum(box.offsetBy(dx: o.x, dy: o.y)), .auto) ? .light : .dark
                }
                if plan.config.signatureEnabled {
                    // 平铺满区域都是：按整块区域的亮度。
                    let tone = pick(plan.layout.tiled ? CGRect(origin: .zero, size: plan.region.size) : plan.layout.signature)
                    out.plans[i].signatureTone = tone
                    out.plans[i].config.tintEnabled = true
                    out.plans[i].config.tint = CollageWatermarks.ink(tone)
                }
                if plan.config.exifText.enabled, layer.contrast != .auto || !plan.config.exifText.backgroundEnabled {
                    let tone = pick(plan.layout.text)
                    out.plans[i].textTone = tone
                    out.plans[i].config.exifText.color = CollageWatermarks.ink(tone)
                    let box = plan.config.exifText.backgroundColor
                    if plan.config.exifText.backgroundEnabled, Self.isLight(box) == (tone == .light) {
                        out.plans[i].config.exifText.backgroundColor = CollageWatermarks.ink(tone == .light ? .dark : .light)
                    }
                }
            }
            return out
        }

        /// 颜色（0…255）算浅色（亮度过半）。
        private static func isLight(_ c: WatermarkEngine.RGB) -> Bool {
            (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255 >= 0.5
        }

        /// 框（mapper 那一侧的坐标）底下照片的平均亮度（按这一页的色调调过）；照片读不了 = nil。
        /// 用整张照片的亮度网格，不按取景：拖缝时取景每帧都变，按取景缓存的网格每帧都得重算。
        private func photoLum(_ box: CGRect, photo: CollagePhotoRef, mapper: CollageOverlays.Mapper) -> Double? {
            guard let grid = CollageOverlays.luminanceGrid(photo, window: .whole), let p = mapper.toPhoto(box),
                  let stats = grid.stats(in: p) else { return nil }
            return CollageOverlays.graded(stats.mean, look: project.style.look, strength: project.style.lookStrength)
        }

        /// 整页层的框底下多亮：压着的照片按面积摊（上面的先算），剩下的按框那儿的页底（模糊底、渐变底各处不一样）。
        private func pageLum(_ box: CGRect) -> Double {
            let total = box.width * box.height
            let paper = self.paper.lum(box)
            guard total > 0, let spots = underlay?.spots else { return paper }
            var covered: CGFloat = 0
            var sum = 0.0
            for spot in spots.reversed() where covered < total {
                let local = box.applying(spot.toLocal).intersection(spot.mapper.drawn)
                guard !local.isNull, !local.isEmpty,
                      let lum = photoLum(local, photo: spot.photo, mapper: spot.mapper) else { continue }
                let share = min(local.width * local.height, total - covered)
                sum += Double(share) * lum
                covered += share
            }
            return (sum + Double(total - covered) * paper) / Double(total)
        }

        // MARK: 落点

        /// 先按原位置排；有框压到不该压的（bad：压字 / 切带 / 出安全区）就左右翻、上下翻、两个都翻再试
        /// （翻过去少画了一样的不算躲开）。都不行 = 原位置的落点 + stuck，调用方决定照画还是不画。
        /// 区域太小 = nil。
        private func place(_ layer: CollageMarkLayer, area: CGRect, cut: Bool, tags: WatermarkEngine.ExifTags,
                           bad: (CGRect) -> Bool) -> (marks: Marks, stuck: Bool)? {
            guard let marks = layout(layer, in: area, cut: cut, tags: tags) else { return nil }
            let boxes = marks.boxes
            guard boxes.contains(where: bad) else { return (marks, false) }
            for (h, v) in [(true, false), (false, true), (true, true)] {
                let alt = layer.mirrored(h: h, v: v)
                guard alt != layer, let m = layout(alt, in: area, cut: cut, tags: tags) else { continue }
                let altBoxes = m.boxes
                if altBoxes.count >= boxes.count, !altBoxes.contains(where: bad) { return (m, false) }
            }
            return (marks, true)
        }

        /// 一层在一块区域里的落点（区域在成品坐标或相纸本地坐标里；cut = 按切带切）：
        /// - 签名大小、边距、字号、横竖一律按整块区域算：同样大的照片不管切带怎么穿过，水印都一样大、在同一角；
        /// - 切带只决定落在哪一块：签名、字各按自己的锚点挑，同一块就一起排（字让着签名，两样不叠）；
        /// - 平铺铺满整块区域、只裁掉切带，字另排；
        /// - 签名小于下限放大、装不下缩小，还比下限小就不画；字号低于下限不写（都记下来）。
        /// 区域短边不够 minSide = nil（格子太小）。
        private func layout(_ layer: CollageMarkLayer, in rawArea: CGRect, cut: Bool,
                            tags: WatermarkEngine.ExifTags) -> Marks? {
            guard !rawArea.isNull, !rawArea.isEmpty else { return nil }
            let area = CollageWatermarks.snapped(rawArea)
            let areaShort = min(area.width, area.height)
            let areaLong = max(area.width, area.height)
            guard areaShort >= CollageWatermarks.minSide else { return nil }
            // 横竖按整块区域定，定好的位置直接交给引擎（不让它按切开的那块再判一次）。
            var base = CollageWatermarks.drawConfig(layer, areaShort: Double(areaShort))
            base.position = area.width >= area.height ? (layer.landscapePosition ?? layer.position) : layer.position
            base.landscapeOverrideEnabled = false
            var marks = Marks()
            var sigOn = layer.signatureOn && watermark.signature != nil
            if sigOn, signature == nil {
                marks.notes.append("签名读不了")
                sigOn = false
            }
            let font = layer.text.map { CGFloat($0.fontSizeRatio) * areaLong }
            if sigOn, layer.tile != nil {
                sigOn = false
                if let tile = tiled(layer, area: area, base: base, cut: cut, tags: tags) {
                    marks.plans.append(tile)
                } else {
                    marks.notes.append("签名放不下")
                }
            }
            let sigPiece = sigOn ? piece(of: area, anchor: base.position, cut: cut) : nil
            let textPiece = layer.text.flatMap { piece(of: area, anchor: $0.position, cut: cut) }
            if sigOn, sigPiece == nil { marks.notes.append("签名放不下") }
            if layer.text != nil, textPiece == nil { marks.notes.append("字放不下") }
            let margin = CGFloat(base.marginX)
            func width(in piece: CGRect) -> Int? {
                let w = signatureWidth(layer.sizeRatio, areaShort: areaShort, room: piece, margin: margin, fit: true)
                if w == nil { marks.notes.append("签名放不下") }
                return w
            }
            if let sp = sigPiece, sp == textPiece {
                let w = width(in: sp)
                if let p = plan(in: sp, base: base, sigW: w, font: font, tags: tags, notes: &marks.notes) {
                    marks.plans.append(p)
                }
                return marks
            }
            if let sp = sigPiece, let w = width(in: sp),
               let p = plan(in: sp, base: base, sigW: w, font: nil, tags: tags, notes: &marks.notes) {
                marks.plans.append(p)
            }
            if let tp = textPiece, let p = plan(in: tp, base: base, sigW: nil, font: font, tags: tags,
                                                notes: &marks.notes) {
                marks.plans.append(p)
            }
            return marks
        }

        /// 平铺：铺满整块区域（签名按区域短边定大小），切带那几条裁掉；字另排一块。签名比下限还小 = nil。
        private func tiled(_ layer: CollageMarkLayer, area: CGRect, base: WatermarkEngine.Config, cut: Bool,
                           tags: WatermarkEngine.ExifTags) -> Plan? {
            let short = min(area.width, area.height)
            let clips = cut ? pieces(of: area) : [area]
            guard !clips.isEmpty,
                  let w = signatureWidth(layer.sizeRatio, areaShort: short, room: area, margin: 0, fit: false)
            else { return nil }
            var config = base
            config.exifText.enabled = false
            config.sizeRatio = Double(w) / Double(short)
            return Plan(region: area, config: config, layout: measure(area, config, tags), clips: clips)
        }

        /// 签名宽（成品像素）：比例 × 区域短边；比下限小就放大到下限（最多这块宽的 45%）；装不进这块
        /// （超过宽的 90%、或连边距放不下）就缩到装得下。最后还比下限小 = nil（不画）。
        private func signatureWidth(_ ratio: Double, areaShort: CGFloat, room: CGRect, margin: CGFloat,
                                    fit: Bool) -> Int? {
            guard let sig = signature, sig.width > 0, sig.height > 0 else { return nil }
            let floor = CollageWatermarks.signatureFloor(canvas).rounded(.up)
            var w = max(1, (areaShort * CGFloat(ratio)).rounded())
            if w < floor { w = min(floor, (room.width * CollageWatermarks.signatureGrowCap).rounded(.down)) }
            if fit {
                let aspect = CGFloat(sig.height) / CGFloat(sig.width)
                let maxW = min(room.width * CollageWatermarks.signatureFitCap, room.width - 2 * margin)
                let maxH = (room.height - 2 * margin) / aspect
                w = min(w, maxW.rounded(.down), maxH.rounded(.down))
            }
            return w >= floor ? Int(w) : nil
        }

        /// 引擎按宽算签名高的同一个公式（WatermarkEngine.placeSignature）。
        private func signatureHeight(_ w: Int) -> Int {
            guard let s = signature, s.width > 0 else { return 1 }
            return max(1, Int((Double(s.height) * Double(w) / Double(s.width)).rounded()))
        }

        /// 一块里排签名（宽 sigW 成品像素，nil = 不画）和字（字号 font 成品像素，nil = 不写）。
        /// 引擎按区域现算大小：比例按这块换算回去，画出来就是按整块区域定的大小。两样都没有 = nil。
        private func plan(in piece: CGRect, base: WatermarkEngine.Config, sigW: Int?, font: CGFloat?,
                          tags: WatermarkEngine.ExifTags, notes: inout [String]) -> Plan? {
            guard sigW != nil || font != nil else { return nil }
            var region = CollageWatermarks.snapped(piece)
            var config = base
            config.signatureEnabled = sigW != nil
            config.exifText.enabled = font != nil
            let sigCol = sigW != nil && base.position.column == 0
            let sigRow = sigW != nil && base.position.row == 0
            // 签名居中的那一向：区域和签名的宽（高）奇偶一致，引擎 (区域 − 签名) / 2 才是整像素（1 倍导出不发虚）。
            if let w = sigW {
                region = Self.evenOut(region, w: sigCol ? w : nil, h: sigRow ? signatureHeight(w) : nil)
            }
            var fontPx = font ?? 0
            func measured() -> WatermarkEngine.MarkLayout {
                let short = Double(min(region.width, region.height))
                let long = Double(max(region.width, region.height))
                if let w = sigW { config.sizeRatio = Double(w) / short }
                config.exifText.fontSizeRatio = Double(fontPx) / long
                return measure(region, config, tags)
            }
            var marks = measured()
            // 字是空的（占位符全缺）：当没开字，不算放不下。
            if font != nil, marks.textSize == nil {
                guard sigW != nil else { return nil }
                config.exifText.enabled = false
                marks = measured()
            }
            guard config.exifText.enabled else { return Plan(region: region, config: config, layout: marks) }
            // 字：同一条上有签名先让开（让在旁边，让不开就叠到签名上面 / 下面），再缩到放得下。
            // 量一次调一次，取整误差再补几轮。
            var stacked = false
            var drop = false
            for _ in 0..<4 {
                guard let fix = textFix(marks, config: config, region: region, baseMarginY: base.exifText.marginY,
                                        stacked: stacked) else { break }
                switch fix {
                case .shrink(let k): fontPx *= k
                case .stack(let my): config.exifText.marginY = my; stacked = true
                case .drop: drop = true
                }
                if drop { break }
                marks = measured()
            }
            // 字居中的那一向也对齐奇偶（签名已经占了的那一向不动），背景框边不发虚。
            if !drop, !config.exifText.fullWidth, let size = marks.textSize {
                let t = config.exifText.position
                let even = Self.evenOut(region, w: t.column == 0 && !sigCol ? Int(size.width.rounded()) : nil,
                                        h: t.row == 0 && !sigRow ? Int(size.height.rounded()) : nil)
                if even != region {
                    region = even
                    marks = measured()
                }
            }
            // 缩到下限还放不下、或者还压着签名：这一块不写字（记下来），总比半截字、字压签名强。
            if drop || !textSettled(marks, config: config, region: region, baseMarginY: base.exifText.marginY,
                                    stacked: stacked, fontPx: fontPx) {
                config.exifText.enabled = false
                marks = measured()
                notes.append("字放不下")
                if sigW == nil { return nil }
            }
            return Plan(region: region, config: config, layout: marks)
        }

        /// 字排完了：字号不低于下限、放得下（取整误差 3% 以内不算）、不压签名。
        private func textSettled(_ marks: WatermarkEngine.MarkLayout, config: WatermarkEngine.Config, region: CGRect,
                                 baseMarginY: Double, stacked: Bool, fontPx: CGFloat) -> Bool {
            guard marks.text != nil, fontPx >= CollageWatermarks.fontFloor(canvas) else { return false }
            if let s = marks.signature, let t = marks.text, s.intersects(t) { return false }
            switch textFix(marks, config: config, region: region, baseMarginY: baseMarginY, stacked: stacked) {
            case nil: return true
            case .shrink(let k): return k >= 0.97 * 0.98
            default: return false
            }
        }

        /// 字要怎么调：nil = 放得下、不压签名。和签名在同一条上：让在旁边（字靠哪边就让哪边，居中的两边对称让）；
        /// 让出来不到这块的 35%、或者挤在旁边字号就低于下限，改叠到签名上面（字在下排）/ 下面（字在上排），
        /// 中排叠不了就不写；再按剩下的地方算字号要乘多少。
        private func textFix(_ marks: WatermarkEngine.MarkLayout, config: WatermarkEngine.Config, region: CGRect,
                             baseMarginY: Double, stacked: Bool) -> TextFix? {
            guard let natural = marks.textSize, natural.width > 0, natural.height > 0 else { return nil }
            guard let text = marks.text else { return .drop }
            let t = config.exifText
            let roomW = region.width - CGFloat(t.marginX) * 2
            let roomH = region.height - CGFloat(t.marginY + baseMarginY)
            func fit(_ w: CGFloat) -> CGFloat { min(w / natural.width, roomH / natural.height) }
            var availW = roomW
            if let sig = marks.signature, sig.minY < text.maxY, sig.maxY > text.minY {
                let gap = max(CGFloat(config.marginX), 2)
                let beside = t.fullWidth ? 0 : Self.besideWidth(sig, column: t.position.column, width: region.width,
                                                                margin: CGFloat(t.marginX), gap: gap)
                let font = CGFloat(t.fontSizeRatio) * max(region.width, region.height)
                let readable = min(1, fit(beside)) * 0.98 * font >= CollageWatermarks.fontFloor(canvas)
                let canStack = !stacked && t.position.row != 0
                if beside >= roomW * 0.35, readable || !canStack {
                    availW = beside
                } else if canStack {
                    let my = t.position.row > 0 ? region.height - sig.minY + gap : sig.maxY + gap
                    return .stack(Double(my))
                } else {
                    return .drop
                }
            }
            guard availW > 0, roomH > 0 else { return .drop }
            let k = fit(availW)
            return k < 0.999 ? .shrink(k * 0.98) : nil
        }

        /// 字在这一列、要让开同一条上的签名时最多能多宽（字块 = 从边距起 / 居中 W/2 ± 宽/2）。
        private static func besideWidth(_ sig: CGRect, column: Int, width: CGFloat, margin: CGFloat,
                                        gap: CGFloat) -> CGFloat {
            if column < 0 { return sig.minX - gap - margin }
            if column > 0 { return width - margin - sig.maxX - gap }
            let half = sig.midX >= width / 2 ? sig.minX - gap - width / 2 : width / 2 - sig.maxX - gap
            return half * 2
        }

        /// 居中的那一向：区域比东西多出来的是奇数就收掉 1 像素，(区域 − 东西) / 2 落在整像素上。
        private static func evenOut(_ r: CGRect, w: Int?, h: Int?) -> CGRect {
            var out = r
            if let w, (Int(r.width) - w) % 2 != 0 { out.size.width -= 1 }
            if let h, (Int(r.height) - h) % 2 != 0 { out.size.height -= 1 }
            return out
        }

        private func measure(_ region: CGRect, _ config: WatermarkEngine.Config,
                             _ tags: WatermarkEngine.ExifTags) -> WatermarkEngine.MarkLayout {
            let size = signature.map { CGSize(width: $0.width, height: $0.height) }
            return WatermarkEngine.layoutMarks(width: Int(region.width), height: Int(region.height),
                                               signatureSize: size, config: config, tags: tags, scale: 1)
        }

        // MARK: 切带

        /// 区域按切带切开的各段（横向、竖向两组）。
        private func spans(of area: CGRect) -> (xs: [(CGFloat, CGFloat)], ys: [(CGFloat, CGFloat)]) {
            var xs = [(area.minX, area.maxX)]
            var ys = [(area.minY, area.maxY)]
            for band in seams {
                if band.height >= band.width {
                    xs = Self.cut(xs, band.minX, band.maxX)
                } else {
                    ys = Self.cut(ys, band.minY, band.maxY)
                }
            }
            return (xs, ys)
        }

        /// 锚点落在切开后的哪一块（不切 = 整块）；挑出来的那块比 minSide 还窄 = nil。
        /// thin = 留白带：本来就薄，只看沿着带的那一向够不够长。
        private func piece(of area: CGRect, anchor: WatermarkEngine.GridPosition, cut: Bool,
                           thin: Bool = false) -> CGRect? {
            guard cut else { return area }
            let (xs, ys) = spans(of: area)
            guard let x = Self.pick(xs, anchor.column, mid: area.midX),
                  let y = Self.pick(ys, anchor.row, mid: area.midY) else { return nil }
            let r = CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
            let side = thin ? max(r.width, r.height) : min(r.width, r.height)
            return side >= CollageWatermarks.minSide ? r : nil
        }

        /// 区域减去切带剩下的各块（平铺只画在这些里），取整；贴着切带的几像素细条不要。
        private func pieces(of area: CGRect) -> [CGRect] {
            let (xs, ys) = spans(of: area)
            return ys.flatMap { y in
                xs.map { x in CollageWatermarks.snapped(CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)) }
            }.filter { min($0.width, $0.height) >= 8 }
        }

        private static func cut(_ spans: [(CGFloat, CGFloat)], _ lo: CGFloat, _ hi: CGFloat) -> [(CGFloat, CGFloat)] {
            spans.flatMap { s -> [(CGFloat, CGFloat)] in
                guard lo < s.1, hi > s.0 else { return [s] }
                return [(s.0, min(s.1, lo)), (max(s.0, hi), s.1)].filter { $0.1 - $0.0 > 0.5 }
            }
        }

        /// 一向上挑哪一段：靠边的取那一侧的（它窄得放不下就往里找下一段够宽的）；居中的取含区域中点的那段，
        /// 中点落在切带里就取中心离中点最近的；都不够宽才退回最宽的。
        private static func pick(_ spans: [(CGFloat, CGFloat)], _ side: Int, mid: CGFloat) -> (CGFloat, CGFloat)? {
            func wide(_ s: (CGFloat, CGFloat)) -> Bool { s.1 - s.0 >= CollageWatermarks.minSide }
            if side != 0 {
                let ordered = side < 0 ? spans : spans.reversed()
                return ordered.first(where: wide) ?? ordered.first
            }
            if let s = spans.first(where: { wide($0) && $0.0 <= mid && mid <= $0.1 }) { return s }
            func distance(_ s: (CGFloat, CGFloat)) -> CGFloat { abs((s.0 + s.1) / 2 - mid) }
            if let s = spans.filter(wide).min(by: { distance($0) < distance($1) }) { return s }
            return spans.max { $0.1 - $0.0 < $1.1 - $1.0 }
        }

        /// 每张照片自己的 EXIF；整页的占位符（{title}{subtitle}{no}{count}）照片里没有，补上（自定义字里能写）。
        private func photoTags(_ photo: CollagePhotoRef, vars: [String: String]) -> WatermarkEngine.ExifTags {
            var values = CollageTypeset.exifValues(photo.path)
            for k in ["title", "subtitle", "no", "count"] where values[k] == nil { values[k] = vars[k] }
            var tags = WatermarkEngine.ExifTags(source: nil)
            tags.values = values
            return tags
        }

        /// ctx 在成品坐标（或相纸本地坐标）里：裁到区域（平铺再裁掉切带）、平移到区域左上角，交给引擎画。
        private func paint(_ plan: Plan, tags: WatermarkEngine.ExifTags, ctx: CGContext) {
            ctx.saveGState()
            ctx.clip(to: plan.region)
            if !plan.clips.isEmpty { ctx.clip(to: plan.clips) }
            ctx.translateBy(x: plan.region.minX, y: plan.region.minY)
            WatermarkEngine.drawMarks(in: ctx, width: Int(plan.region.width), height: Int(plan.region.height),
                                      signature: signature, config: plan.config, tags: tags, scale: 1)
            ctx.restoreGState()
        }

        // MARK: 记账（命令行核对用；界面预览没有 report，什么都不记）

        /// 记账带上的几何（成品坐标）：格子 / 相纸 / 整页、照片实际画出来的那块、形状名。
        private struct Geometry {
            var cell: CGRect
            var visible: CGRect
            var shape: String
            var avoid: CGRect?
        }

        private func note(layer: String, owner: String, region: CGRect?, skipped: String, geo: Geometry) {
            report?.marks.append(CollageRender.MarkRecord(layer: layer, owner: owner, kind: nil, rect: nil,
                                                          region: region, skipped: skipped, cell: geo.cell,
                                                          visible: geo.visible, shape: geo.shape, avoid: geo.avoid))
        }

        /// map = 相纸本地 → 成品坐标（记转过之后的外接框，另记没转之前的大小 local：下限按它核对）。
        /// 平铺按裁剪后的每一块各记一条（都不压切带）。
        private func record(_ marks: Marks?, layer: String, owner: String, area: CGRect, geo: Geometry,
                            map: CGAffineTransform = .identity) {
            guard let report else { return }
            func box(_ r: CGRect) -> CGRect? { r.isNull || r.isEmpty ? nil : r.applying(map) }
            guard let marks else {
                note(layer: layer, owner: owner, region: box(area), skipped: "格子太小", geo: geo)
                return
            }
            for plan in marks.plans {
                let flag = plan.conflict ? "压字冲突未解" : nil
                let region = box(plan.region)
                let o = plan.region.origin
                let long = Double(max(plan.region.width, plan.region.height))
                func add(_ kind: String, _ r: CGRect, tone: CollageMarkContrast, font: Double? = nil) {
                    report.marks.append(CollageRender.MarkRecord(layer: layer, owner: owner, kind: kind, rect: box(r),
                                                                 region: region, skipped: flag, cell: geo.cell,
                                                                 visible: geo.visible, shape: geo.shape,
                                                                 avoid: geo.avoid, font: font, contrast: tone.rawValue,
                                                                 inMargin: plan.inMargin,
                                                                 local: map.isIdentity ? nil : r.size,
                                                                 corners: map.isIdentity ? nil : Cover.quad(r, map)))
                }
                if plan.layout.tiled {
                    for clip in plan.clips.isEmpty ? [plan.region] : plan.clips {
                        add("tile", clip, tone: plan.signatureTone)
                    }
                }
                if let s = plan.layout.signature {
                    add("signature", s.offsetBy(dx: o.x, dy: o.y), tone: plan.signatureTone)
                }
                if let t = plan.layout.text {
                    add("text", t.offsetBy(dx: o.x, dy: o.y), tone: plan.textTone,
                        font: max(long * plan.config.exifText.fontSizeRatio, 8))
                }
            }
            for reason in marks.notes { note(layer: layer, owner: owner, region: box(area), skipped: reason, geo: geo) }
        }
    }
}
