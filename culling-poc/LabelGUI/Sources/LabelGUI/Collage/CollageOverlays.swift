import Foundation
import CoreGraphics

/// 照片上的字：放在哪（自动避开人脸、身体、画面最乱的地方）、用深字还是浅字。
///
/// 位置和字色全部按成品尺寸（1 倍）的几何、固定分辨率的预览统计算 —— 界面预览、画布上的
/// 选中框、导出三处算出来是同一个位置（以前景别按缩略图几何判，预览和导出翻过车）。
enum CollageOverlays {

    struct Placement {
        /// 字块外框（成品坐标，不含出血）。
        var rect: CGRect
        /// 放得下之后的字号基准（CollageTypeset 的 short）。
        var short: Double
        /// 按位置调好对齐、按底下画面调好颜色的字。
        var text: CollageText
        var light: Bool
        var anchor: CollageAnchor
        /// 字底下画面太花、反差不够时字后面垫的雾面有多实（0 = 不垫）：深字衬白、浅字衬黑。
        var halo: Double = 0
    }

    /// area = 照片实际画的区域（成品坐标）；window/drawn 用来把字块映射回照片坐标看底下是什么。
    static func place(_ overlay: CollageOverlay, area: CGRect, drawn: CGRect, canvas: CollageCanvas,
                      photo: CollagePhotoRef?, window: CollageCrop.Window?, hints: CollageCrop.Hints?,
                      vars: [String: String], background: CollageColor,
                      look: CollageLook = .none, lookStrength: Double = 0) -> Placement? {
        let short = canvas.shortSide
        var avail = area
        // 印刷：字不出安全区（裁切有误差，贴边的字会被切掉）。
        if canvas.safe > 0 {
            let safe = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
                .insetBy(dx: CGFloat(canvas.safe), dy: CGFloat(canvas.safe))
            let clipped = avail.intersection(safe)
            if !clipped.isNull, clipped.width > 8, clipped.height > 8 { avail = clipped }
        }
        let m = Double(min(area.width, area.height))
        let inset = CGFloat(overlay.inset * m)
        var inner = avail.insetBy(dx: inset, dy: inset)
        if inner.width < 8 || inner.height < 8 { inner = avail }
        guard inner.width > 4, inner.height > 4 else { return nil }

        let vertical = overlay.text.vertical
        let maxW = Double(inner.width) * (vertical ? 0.55 : overlay.maxWidth)
        let maxH = Double(inner.height) * (vertical ? overlay.maxWidth : 0.55)
        let fitted = CollageTypeset.fit(overlay.text, in: CGSize(width: maxW, height: maxH), short: short, vars: vars)
        let size = CGSize(width: ceil(fitted.size.width) + 1, height: ceil(fitted.size.height) + 1)
        guard size.width > 1, size.height > 1 else { return nil }

        let grid = photo.flatMap { p in window.flatMap { w in luminanceGrid(p, window: w) } }
        let mapper = Mapper(drawn: drawn, window: window)
        let seams = CollageLayout.seamLines(canvas)

        var chosen: CollageAnchor
        var rect: CGRect
        var fit = fitted
        switch overlay.anchor {
        case .custom:
            chosen = .custom
            let cx = Double(area.minX) + overlay.x * Double(area.width)
            let cy = Double(area.minY) + overlay.y * Double(area.height)
            rect = clampRect(CGRect(x: cx - Double(size.width) / 2, y: cy - Double(size.height) / 2,
                                    width: Double(size.width), height: Double(size.height)), into: avail)
        case .auto:
            // 九个位置 × 三档大小里挑：上方只剩一小块干净的天空时，小一号放在天上比大字压在栏杆花纹上
            // 好认（缩小有代价，不会无故缩）。
            var best = (anchor: CollageAnchor.top, rect: CGRect.zero, fit: fitted, cost: Double.infinity)
            for s in autoScales {
                let f = s == 1 ? fitted : CollageTypeset.fit(overlay.text, in: CGSize(width: maxW, height: maxH),
                                                            short: short * s, vars: vars)
                let sz = CGSize(width: ceil(f.size.width) + 1, height: ceil(f.size.height) + 1)
                let shrink: Double = max(0, 1 - f.short / max(1e-6, fitted.short))
                for a in CollageAnchor.grid {
                    let r = anchored(a, size: sz, in: inner)
                    let base: Double = cost(r, anchor: a, vertical: vertical, photo: photo, hints: hints, grid: grid,
                                            mapper: mapper, tone: overlay.tone)
                    let c: Double = base + seamCost(r, seams: seams) + shrinkCost * shrink
                    if c < best.cost { best = (a, r, f, c) }
                }
            }
            chosen = best.anchor
            rect = best.rect
            fit = best.fit
        default:
            chosen = overlay.anchor
            rect = clearOfSeams(anchored(overlay.anchor, size: size, in: inner), canvas: canvas, within: inner)
        }

        // 字贴着哪条边就向哪边对齐（左下角的字左对齐、右上角的右对齐）；手动拖的保留原对齐。
        var text = overlay.text
        if !vertical, let cell = chosen.cell {
            text.alignH = cell.col == 0 ? .leading : (cell.col == 1 ? .center : .trailing)
        }
        text.alignV = .leading

        let sampled = meanLuminance(rect, grid: grid, mapper: mapper)
        var lum = sampled ?? background.luminance
        // 网格是调色前的亮度：套了色调（日系提亮、复古抬黑位）要按调完的亮度判深字浅字。
        // 字落在留白底色上（取不到照片）时不调：底色本身不过色调。
        if sampled != nil, look != .none, lookStrength > 0 {
            let m = CollageLooks.map(look, lum, lum, lum)
            let after: Double = 0.2126 * m.0 + 0.7152 * m.1 + 0.0722 * m.2
            lum += (after - lum) * min(1, lookStrength)
        }
        let light: Bool
        switch overlay.tone {
        case .auto: light = lum < 0.56
        case .light: light = true
        case .dark: light = false
        }
        text.lines = text.lines.map { line in
            var l = line
            l.color = toned(line.color, light: light)
            // 花字跟着翻：描边、底条和字反着来（浅字配深边深底、深字配浅边浅底），渐变下端跟字一起翻。
            if var fx = l.effect {
                fx.strokeColor = toned(fx.strokeColor, light: !light)
                fx.bandColor = toned(fx.bandColor, light: !light)
                if let g = fx.gradient { fx.gradient = toned(g, light: light) }
                l.effect = fx
            }
            return l
        }
        // 衬：按最后落的位置底下有多花、反差够不够定（干净的天空上 = 0，什么都不加）。
        var halo = 0.0
        if let box = mapper.toPhoto(rect), let stats = grid?.stats(in: box) {
            let busy: Double = min(1, max(0, (stats.busy - 0.22) / 0.4))
            halo = max(busy, illegibility(stats, light: light))
        }
        return Placement(rect: rect, short: fit.short, text: text, light: light, anchor: chosen, halo: halo)
    }

    /// 自动位置试的几档大小、缩小的代价（缩到 0.72 ≈ 1.7）。
    private static let autoScales: [Double] = [1, 0.85, 0.72]
    private static let shrinkCost = 6.0

    /// 自动字色：底下平均亮度 0.56 以下用浅字（和最后真正上色用同一条线）。
    private static func tone(_ mean: Double, _ tone: CollageTone) -> Bool {
        switch tone {
        case .auto: return mean < 0.56
        case .light: return true
        case .dark: return false
        }
    }

    /// 字和底的对比度（WCAG 那种，1…21），按底下最不利的那一片算：浅字看底下偏亮的、深字看偏暗的。
    static func contrast(_ stats: Grid.Stats, light: Bool) -> Double {
        let sigma: Double = stats.spread / 2
        let bg: Double = light ? min(1, stats.mean + sigma) : max(0, stats.mean - sigma)
        let lb: Double = CollageLooks.linear(bg)
        let lt: Double = light ? 0.9 : 0.02
        return (max(lb, lt) + 0.05) / (min(lb, lt) + 0.05)
    }

    /// 0 = 反差足够（≥ 4.5），1 = 几乎看不清（≤ 1.5）。
    static func illegibility(_ stats: Grid.Stats, light: Bool) -> Double {
        min(1, max(0, (4.5 - contrast(stats, light: light)) / 3))
    }

    // MARK: - 候选位置

    static func anchored(_ anchor: CollageAnchor, size: CGSize, in inner: CGRect) -> CGRect {
        guard let cell = anchor.cell else {
            return CGRect(x: inner.midX - size.width / 2, y: inner.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        let x: CGFloat
        switch cell.col {
        case 0: x = inner.minX
        case 1: x = inner.midX - size.width / 2
        default: x = inner.maxX - size.width
        }
        let y: CGFloat
        switch cell.row {
        case 0: y = inner.minY
        case 1: y = inner.midY - size.height / 2
        default: y = inner.maxY - size.height
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func clampRect(_ r: CGRect, into box: CGRect) -> CGRect {
        let w = min(r.width, box.width)
        let h = min(r.height, box.height)
        let x = min(max(r.minX, box.minX), box.maxX - w)
        let y = min(max(r.minY, box.minY), box.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 版式上的偏好：标题最常见在上方、签名式小字在左下；正中间最后才考虑。
    private static func prior(_ anchor: CollageAnchor, vertical: Bool) -> Double {
        if vertical {
            switch anchor {
            case .topTrailing: return 0
            case .topLeading: return 0.05
            case .trailing, .leading: return 0.2
            case .bottomTrailing, .bottomLeading: return 0.3
            default: return 0.6
            }
        }
        switch anchor {
        case .top: return 0
        case .topLeading: return 0.04
        case .bottomLeading: return 0.06
        case .bottom: return 0.08
        case .topTrailing: return 0.1
        case .bottomTrailing: return 0.12
        case .leading, .trailing: return 0.3
        case .center: return 0.45
        default: return 0.5
        }
    }

    /// 越低越好：压脸最重，压身体次之，底下越乱、明暗越不均越差。
    private static func cost(_ r: CGRect, anchor: CollageAnchor, vertical: Bool, photo: CollagePhotoRef?,
                             hints: CollageCrop.Hints?, grid: Grid?, mapper: Mapper, tone: CollageTone) -> Double {
        var c = prior(anchor, vertical: vertical)
        guard let photo, let box = mapper.toPhoto(r) else { return c }
        let boxArea = max(1e-9, Double(box.width * box.height))
        for f in photo.faces where CollageCrop.isValidBox(f) {
            let face = CGRect(x: f[0], y: f[1], width: f[2] - f[0], height: f[3] - f[1])
            let faceArea = max(1e-9, Double(face.width * face.height))
            let hit = intersectionArea(box, face)
            if hit > 0 {
                let covered: Double = hit / min(faceArea, boxArea)
                c += 30 * covered + 3
            }
            // 身体：脸下方约五张脸高、左右各一张多脸宽。
            let fw = Double(face.width)
            let fh = Double(face.height)
            let body = CGRect(x: Double(face.midX) - 1.4 * fw, y: Double(face.maxY),
                              width: 2.8 * fw, height: 5 * fh)
            let bodyHit = intersectionArea(box, body)
            c += 4 * bodyHit / boxArea
        }
        if photo.faces.isEmpty, let s = hints?.subject, s.count == 4 {
            let subject = CGRect(x: s[0], y: s[1], width: s[2] - s[0], height: s[3] - s[1])
            c += 6 * intersectionArea(box, subject) / boxArea
        }
        if let grid, let stats = grid.stats(in: box) {
            c += 5 * stats.busy + 2 * stats.spread
            c += 3 * illegibility(stats, light: self.tone(stats.mean, tone))
        }
        return c
    }

    /// 压到相册中缝、轮播切缝、九宫格切线：印出来被书脊吃掉，或者一句字被切在两张图上。
    private static func seamCost(_ r: CGRect, seams: [CGRect]) -> Double {
        let area = max(1e-9, Double(r.width * r.height))
        var c = 0.0
        for band in seams {
            let hit = intersectionArea(r, band)
            if hit > 0 { c += 3 + 30 * hit / area }
        }
        return c
    }

    /// 固定位置的字（下方字幕、上方居中）压在竖的切缝上：往字块中心那一侧挪开；两边都挪不开
    /// （字比半边还宽）就不动。手动拖的不管 —— 用户放哪就是哪。
    private static func clearOfSeams(_ r: CGRect, canvas: CollageCanvas, within box: CGRect) -> CGRect {
        guard canvas.seams == .fold || canvas.seams == .carousel else { return r }
        var out = r
        for band in CollageLayout.seamLines(canvas) where out.intersects(band) {
            let toLeft = band.minX - out.width
            let toRight = band.maxX
            let order = out.midX < band.midX ? [toLeft, toRight] : [toRight, toLeft]
            for x in order where x >= box.minX - 0.5 && x + out.width <= box.maxX + 0.5 {
                out.origin.x = x
                break
            }
        }
        return out
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        return i.isNull ? 0 : Double(i.width * i.height)
    }

    private static func meanLuminance(_ r: CGRect, grid: Grid?, mapper: Mapper) -> Double? {
        guard let grid, let box = mapper.toPhoto(r) else { return nil }
        return grid.stats(in: box)?.mean
    }

    // MARK: - 字色

    /// 浅底配深字、深底配浅字：只翻亮度，色相和层级（主字深、小字浅）保留。
    static func toned(_ color: CollageColor, light: Bool) -> CollageColor {
        var hsl = color.hsl
        if light {
            if color.luminance < 0.6 { hsl.l = 1 - hsl.l * 0.35 }
        } else {
            if color.luminance > 0.5 { hsl.l = 0.1 + (1 - hsl.l) * 0.35 }
        }
        return CollageColor(hsl: hsl)
    }

    // MARK: - 成品坐标 ↔ 照片坐标

    struct Mapper {
        var drawn: CGRect
        var window: CollageCrop.Window?

        func toPhoto(_ r: CGRect) -> CGRect? {
            guard let w = window, drawn.width > 0, drawn.height > 0 else { return nil }
            let clipped = r.intersection(drawn)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            let sx = w.w / Double(drawn.width)
            let sy = w.h / Double(drawn.height)
            let x0 = w.x + Double(clipped.minX - drawn.minX) * sx
            let y0 = w.y + Double(clipped.minY - drawn.minY) * sy
            return CGRect(x: x0, y: y0, width: Double(clipped.width) * sx, height: Double(clipped.height) * sy)
        }
    }

    // MARK: - 亮度网格（取景窗口里 48×48 的亮度，从 256 预览算，和渲染尺寸无关）
    //
    // 48 而不是 24：栏杆石雕、窗格这种笔画粗细的花纹，24 格一平均就看不出来了（字压上去照样难认）。

    struct Grid {
        static let side = 48
        /// 照片坐标里网格覆盖的范围（= 取景窗口）。
        var window: CGRect
        var lum: [Double]
        var grad: [Double]

        struct Stats {
            var mean: Double
            var spread: Double
            var busy: Double
        }

        func stats(in box: CGRect) -> Stats? {
            let n = Grid.side
            guard window.width > 0, window.height > 0 else { return nil }
            let u0 = Double((box.minX - window.minX) / window.width)
            let u1 = Double((box.maxX - window.minX) / window.width)
            let v0 = Double((box.minY - window.minY) / window.height)
            let v1 = Double((box.maxY - window.minY) / window.height)
            let i0 = max(0, min(n - 1, Int(u0 * Double(n))))
            let i1 = max(i0, min(n - 1, Int((u1 * Double(n)).rounded(.up)) - 1))
            let j0 = max(0, min(n - 1, Int(v0 * Double(n))))
            let j1 = max(j0, min(n - 1, Int((v1 * Double(n)).rounded(.up)) - 1))
            var sum = 0.0
            var sq = 0.0
            var g = 0.0
            var count = 0.0
            for j in j0...j1 {
                for i in i0...i1 {
                    let v = lum[j * n + i]
                    sum += v
                    sq += v * v
                    g += grad[j * n + i]
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            let mean = sum / count
            let variance = max(0, sq / count - mean * mean)
            return Stats(mean: mean, spread: variance.squareRoot() * 2, busy: min(1, g / count * 4))
        }
    }

    private static let gridLock = NSLock()
    private static var gridCache: [String: Grid] = [:]

    static func luminanceGrid(_ photo: CollagePhotoRef, window: CollageCrop.Window) -> Grid? {
        let key = CollageVision.cacheKey(photo) + String(format: "|%.3f,%.3f,%.3f,%.3f", window.x, window.y, window.w, window.h)
        gridLock.lock()
        if let hit = gridCache[key] {
            gridLock.unlock()
            return hit
        }
        gridLock.unlock()
        guard let image = CollageImages.preview(photo, need: 256) else { return nil }
        let iw = Double(image.width)
        let ih = Double(image.height)
        let crop = CGRect(x: window.x * iw, y: window.y * ih, width: max(1, window.w * iw), height: max(1, window.h * ih)).integral
        guard let piece = image.cropping(to: crop) else { return nil }
        let n = Grid.side
        var pixels = [UInt8](repeating: 0, count: n * n)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(piece, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        // CG 位图第 0 行在上（和照片坐标一致）。
        let lum = pixels.map { Double($0) / 255 }
        var grad = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let v = lum[j * n + i]
                let right = i + 1 < n ? lum[j * n + i + 1] : v
                let down = j + 1 < n ? lum[(j + 1) * n + i] : v
                grad[j * n + i] = abs(right - v) + abs(down - v)
            }
        }
        let g = Grid(window: CGRect(x: window.x, y: window.y, width: window.w, height: window.h), lum: lum, grad: grad)
        gridLock.lock()
        if gridCache.count > 256 { gridCache.removeAll() }
        gridCache[key] = g
        gridLock.unlock()
        return g
    }

    // MARK: - 预设：杂志小字层

    struct Preset: Identifiable {
        let key: String
        let name: String
        let overlay: CollageOverlay
        var id: String { key }
    }

    static let presets: [Preset] = [
        Preset(key: "masthead", name: "刊头大标题", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("{title}", font: .songti, weight: .bold, size: 0.1, tracking: 0.18, color: .ink),
                CollageTextLine("{month_en} · {year} · NO.{no}", font: .didot, weight: .regular, size: 0.016,
                                tracking: 0.45, color: .ink),
            ], vertical: false, alignH: .center, alignV: .leading)
            t.lineSpacing = 0.5
            // 自动：没有脸挡着就在上方（上方的先验分最低），压到脸才换地方。
            var o = CollageOverlay(text: t)
            o.inset = 0.05
            return o
        }()),
        Preset(key: "corner", name: "角标小字", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("No.{no}", font: .didot, weight: .regular, size: 0.03, color: .ink, italic: true),
                CollageTextLine("{date}", font: .avenir, weight: .regular, size: 0.012, tracking: 0.35, color: .ink),
                CollageTextLine("{subtitle}", font: .pingfang, weight: .light, size: 0.013, tracking: 0.2, color: .ink),
            ], vertical: false, alignH: .leading, alignV: .leading)
            t.lineSpacing = 0.55
            var o = CollageOverlay(text: t)
            o.inset = 0.06
            return o
        }()),
        Preset(key: "subtitle", name: "电影字幕", overlay: {
            let t = CollageText(lines: [
                // 没填副标题时先放一句（以前空着，点了什么都不出、也没有框可拖）。
                CollageTextLine("{subtitle|那天的风，吹得很温柔}", font: .pingfang, weight: .regular, size: 0.03,
                                tracking: 0.06, color: .white),
            ], vertical: false, alignH: .center, alignV: .leading)
            var o = CollageOverlay(text: t)
            o.anchor = .bottom
            o.tone = .light
            o.shadow = 0.75
            o.inset = 0.07
            return o
        }()),
        Preset(key: "vertical", name: "竖排题字", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("{title}", font: .songti, weight: .regular, size: 0.058, color: .ink),
                CollageTextLine("{date_cn}", font: .songti, weight: .regular, size: 0.016, color: .ink, indent: 5.5),
            ], vertical: true, alignH: .trailing, alignV: .leading)
            t.lineSpacing = 0.55
            t.seal = CollageSeal(text: "光", color: .seal, size: 0.026)
            var o = CollageOverlay(text: t)
            o.inset = 0.07
            return o
        }()),
        Preset(key: "number", name: "大号期数", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("{no}", font: .bodoni, weight: .regular, size: 0.2, color: .ink),
                CollageTextLine("{title}", font: .songti, weight: .light, size: 0.022, tracking: 0.5, color: .ink),
                CollageTextLine("{date}", font: .didot, weight: .regular, size: 0.011, tracking: 0.4, color: .ink),
            ], vertical: false, alignH: .leading, alignV: .leading)
            t.lineSpacing = 0.25
            var o = CollageOverlay(text: t)
            o.inset = 0.05
            return o
        }()),
        Preset(key: "script", name: "英文花体", overlay: {
            var t = CollageText(lines: [
                CollageTextLine("Moments", font: .snell, weight: .bold, size: 0.075, color: .ink),
                CollageTextLine("{month_en} {day}, {year}", font: .didot, weight: .regular, size: 0.013,
                                tracking: 0.4, color: .ink, indent: 1.2),
            ], vertical: false, alignH: .leading, alignV: .leading)
            t.lineSpacing = 0.15
            var o = CollageOverlay(text: t)
            o.inset = 0.06
            return o
        }()),
        Preset(key: "handwrite", name: "手写一句", overlay: {
            let t = CollageText(lines: [
                CollageTextLine("今天的风很温柔", font: .hanzipen, weight: .regular, size: 0.05, color: .ink),
                CollageTextLine("{date}", font: .hanzipen, weight: .regular, size: 0.022, color: .ink),
            ], vertical: false, alignH: .leading, alignV: .leading)
            var o = CollageOverlay(text: t)
            o.inset = 0.06
            return o
        }()),
    ]

    static func preset(_ key: String) -> CollageOverlay? { presets.first { $0.key == key }?.overlay }
}

// MARK: - HSL（字色翻亮度用）

extension CollageColor {
    struct HSL {
        var h: Double
        var s: Double
        var l: Double
    }

    var hsl: HSL {
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-9 else { return HSL(h: 0, s: 0, l: l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        return HSL(h: h, s: s, l: l)
    }

    init(hsl: HSL) {
        let l = min(1, max(0, hsl.l))
        let s = min(1, max(0, hsl.s))
        guard s > 1e-9 else {
            self.init(r: l, g: l, b: l)
            return
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        self.init(r: channel(hsl.h + 1.0 / 3), g: channel(hsl.h), b: channel(hsl.h - 1.0 / 3))
    }
}
