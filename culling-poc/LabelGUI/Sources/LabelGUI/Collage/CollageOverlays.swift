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

        var chosen: CollageAnchor
        var rect: CGRect
        switch overlay.anchor {
        case .custom:
            chosen = .custom
            let cx = Double(area.minX) + overlay.x * Double(area.width)
            let cy = Double(area.minY) + overlay.y * Double(area.height)
            rect = clampRect(CGRect(x: cx - Double(size.width) / 2, y: cy - Double(size.height) / 2,
                                    width: Double(size.width), height: Double(size.height)), into: avail)
        case .auto:
            var best = (anchor: CollageAnchor.top, rect: CGRect.zero, cost: Double.infinity)
            for a in CollageAnchor.grid {
                let r = anchored(a, size: size, in: inner)
                let c = cost(r, anchor: a, vertical: vertical, photo: photo, hints: hints, grid: grid, mapper: mapper)
                if c < best.cost { best = (a, r, c) }
            }
            chosen = best.anchor
            rect = best.rect
        default:
            chosen = overlay.anchor
            rect = anchored(overlay.anchor, size: size, in: inner)
        }

        // 字贴着哪条边就向哪边对齐（左下角的字左对齐、右上角的右对齐）；手动拖的保留原对齐。
        var text = overlay.text
        if !vertical, let cell = chosen.cell {
            text.alignH = cell.col == 0 ? .leading : (cell.col == 1 ? .center : .trailing)
        }
        text.alignV = .leading

        var lum = meanLuminance(rect, grid: grid, mapper: mapper) ?? background.luminance
        // 网格是调色前的亮度：套了色调（日系提亮、复古抬黑位）要按调完的亮度判深字浅字。
        if grid != nil, look != .none, lookStrength > 0 {
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
            return l
        }
        return Placement(rect: rect, short: fitted.short, text: text, light: light, anchor: chosen)
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
                             hints: CollageCrop.Hints?, grid: Grid?, mapper: Mapper) -> Double {
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
        }
        return c
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

    // MARK: - 亮度网格（取景窗口里 24×24 的亮度，从 256 预览算，和渲染尺寸无关）

    struct Grid {
        static let side = 24
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
                CollageTextLine("{subtitle}", font: .pingfang, weight: .regular, size: 0.03, tracking: 0.06, color: .white),
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
