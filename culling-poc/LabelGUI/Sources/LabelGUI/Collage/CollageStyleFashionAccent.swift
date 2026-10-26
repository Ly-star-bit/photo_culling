import Foundation
import CoreGraphics

/// 时尚刊的强调色从照片取（DESIGN §3 K1「右栏衬线」「法式左栏」，R1 §3 的提案）：在主体蒙版里的衣服、嘴唇上
/// 做 k-means（Lab，5 类），取彩度最高、和这一行字形底下最不利的亮度对比 ≥ 3:1 的那个颜色（浅字要比底亮、深字要比底暗）；
/// 都不够就把彩度最高的那个往亮 / 往暗推到够为止（最多推 25，推完彩度还得 ≥ 15，不然就是粉白、酱黑、发灰的灰青，不算强调色）；
/// 主体太素（最鲜艳的一类彩度不到 15）、没有蒙版 = nil（用模板写的颜色，那个也不够 3:1 就用白 / 墨）。
///
/// 全按 1024 预览缩到 192 的像素和蒙版算：预览、导出、缩略图挑出来是同一个颜色（CollageOverlays.place 里调）。
/// 只用已经有的蒙版（内存、磁盘），不在摆位里现算 Vision：封面格的人物挡字先要蒙版（CollageCover 已经算好），
/// 别的格子蒙版预热完（masksVersion 变）重画一遍就有了。
extension CollageStyleFashion {

    /// 一类颜色：Lab 中心和占主体多少（0…1）。
    struct Swatch: Hashable {
        var l: Double
        var a: Double
        var b: Double
        var share: Double

        var chroma: Double { (a * a + b * b).squareRoot() }
    }

    /// 最少多鲜艳才算强调色（Lab 彩度）；一类至少占主体多少才算数（嘴唇单独算，不受这条限）。
    static let accentMinChroma = 15.0
    static let accentMinShare = 0.035
    /// 和底下的对比度下限（WCAG 那种）。
    static let accentContrast = 3.0
    /// 亮度最多推多少（Lab L）：嘴唇的红推到 L 85 是粉白、推到 L 20 是近黑的酱色，都不像强调色了，不如用模板色。
    static let accentMaxShift = 25.0

    private static let accentLock = NSLock()
    private static var paletteCache: [String: [Swatch]] = [:]

    /// 这张照片当强调色用的颜色。under = 这一行字形底下最不利的亮度（和 CollageOverlays 的网格同一个尺度：sRGB 编码
    /// 0…1；浅字看的是最亮的、深字看的是最暗的）；light = 这块字是浅字。照原色就够 3:1 的里面挑最鲜艳的；都不够就挑
    /// 「亮度推得最少就够」的那个推过去（颜色离照片里的最近），色相不变；推完出了色域、彩度掉到 15 以下的、要推 25 以上的不要。
    static func accent(for photo: CollagePhotoRef, under: Double, light: Bool) -> CollageColor? {
        let swatches = palette(for: photo).filter { $0.chroma >= accentMinChroma }.sorted { a, b in
            a.chroma == b.chroma ? a.l < b.l : a.chroma > b.chroma
        }
        guard !swatches.isEmpty else { return nil }
        let bg = CollageLooks.linear(min(1, max(0, under)))
        for s in swatches {
            let c = srgb(l: s.l, a: s.a, b: s.b)
            if usable(c, bg, light: light) { return c }
        }
        // 浅字往亮推、深字往暗推（出了色域按 sRGB 夹住）。
        var best: (shift: Double, color: CollageColor)?
        for s in swatches {
            var l = s.l
            for _ in 0..<40 {
                l += light ? 2 : -2
                guard l > 2, l < 98, abs(l - s.l) <= accentMaxShift else { break }
                let c = srgb(l: l, a: s.a, b: s.b)
                guard usable(c, bg, light: light) else { continue }
                let shift = abs(l - s.l)
                if best == nil || shift < best!.shift - 1e-9 { best = (shift, c) }
                break
            }
        }
        return best?.color
    }

    /// 取不到强调色：深字用模板写的颜色（#B0574A 这种砖红）够 3:1 就用它，不够用墨；浅字一律白 ——
    /// 模板色翻成浅字是一层粉白，压在中间调的石头上发灰，不像强调色。
    static func accentFallback(_ color: CollageColor, under: Double, light: Bool) -> CollageColor {
        if light { return .white }
        let bg = CollageLooks.linear(min(1, max(0, under)))
        return contrast(color, bg) >= accentContrast ? color : .ink
    }

    /// 能当强调色：在字该在的那一边（浅字比底亮、深字比底暗）、对比够 3:1、还看得出颜色（彩度 ≥ 15）。
    private static func usable(_ c: CollageColor, _ bgLinear: Double, light: Bool) -> Bool {
        let y = linearLuminance(c)
        guard light ? y > bgLinear : y < bgLinear else { return false }
        guard contrast(c, bgLinear) >= accentContrast else { return false }
        let lab = Self.lab(c.r, c.g, c.b)
        let chroma: Double = (lab.1 * lab.1 + lab.2 * lab.2).squareRoot()
        return chroma >= accentMinChroma
    }

    /// 主体里的几类颜色（按占比从大到小，嘴唇那一类放在最后）。衣服 = 蒙版里、脸框外，像皮肤的颜色（手、脖子）不算
    /// （肤色当强调色发灰发脏）；嘴唇 = 脸框下半截中间那块里偏红的像素，单独算一类。按照片 + 蒙版内容缓存。
    static func palette(for photo: CollagePhotoRef) -> [Swatch] {
        guard let mask = CollageMasks.cachedMask(for: photo) else { return [] }
        let key = CollageVision.cacheKey(photo) + "|" + mask.signature
        accentLock.lock()
        if let hit = paletteCache[key] {
            accentLock.unlock()
            return hit
        }
        accentLock.unlock()
        let picked = samples(photo: photo, mask: mask)
        var out = cluster(picked.cloth)
        if picked.lips.count >= 8 {
            let n = Double(picked.lips.count)
            let l = picked.lips.reduce(0) { $0 + $1.l } / n
            let a = picked.lips.reduce(0) { $0 + $1.a } / n
            let b = picked.lips.reduce(0) { $0 + $1.b } / n
            out.append(Swatch(l: l, a: a, b: b, share: n / Double(max(1, picked.cloth.count))))
        }
        accentLock.lock()
        if paletteCache.count > 64 { paletteCache.removeAll() }
        paletteCache[key] = out
        accentLock.unlock()
        return out
    }

    /// 像不像皮肤（Lab：偏暖的橙粉、中等彩度、不太暗）。
    private static func skinLike(_ l: Double, _ a: Double, _ b: Double) -> Bool {
        let hue = atan2(b, a) * 180 / .pi
        let chroma = (a * a + b * b).squareRoot()
        return l > 30 && l < 92 && chroma > 6 && chroma < 45 && hue > 20 && hue < 78
    }

    private struct Sample {
        var l: Double
        var a: Double
        var b: Double
        var w: Double
    }

    private static func samples(photo: CollagePhotoRef, mask: CollageMasks.Mask) -> (cloth: [Sample], lips: [Sample]) {
        guard let image = CollageImages.preview(photo, need: 256) else { return ([], []) }
        let long = 192.0
        let k: Double = min(1, long / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * k).rounded()))
        let h = max(1, Int((Double(image.height) * k).rounded()))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return ([], []) }
        let faces = photo.faces.filter(CollageCrop.isValidBox)
        var cloth: [Sample] = []
        var lips: [Sample] = []
        cloth.reserveCapacity(w * h / 4)
        for j in 0..<h {
            for i in 0..<w {
                let u: Double = (Double(i) + 0.5) / Double(w)
                let v: Double = (Double(j) + 0.5) / Double(h)
                let o = (j * w + i) * 4
                let lab = Self.lab(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
                if let f = faces.first(where: { u >= $0[0] && u <= $0[2] && v >= $0[1] && v <= $0[3] }) {
                    // 脸上只要嘴唇：下半截中间、偏红（色相 < 40°、a > 15）。
                    let fx: Double = (u - f[0]) / max(1e-6, f[2] - f[0])
                    let fy: Double = (v - f[1]) / max(1e-6, f[3] - f[1])
                    let hue: Double = atan2(lab.2, lab.1) * 180 / .pi
                    if fx > 0.3, fx < 0.7, fy > 0.62, fy < 0.9, lab.1 > 15, hue < 40, hue > -20 {
                        lips.append(Sample(l: lab.0, a: lab.1, b: lab.2, w: 1))
                    }
                    continue
                }
                guard mask.value(u: u, v: v) >= 0.6, !skinLike(lab.0, lab.1, lab.2) else { continue }
                cloth.append(Sample(l: lab.0, a: lab.1, b: lab.2, w: 1))
            }
        }
        return (cloth, lips)
    }

    /// k-means（5 类，按亮度分位数起步，8 轮）：确定的，同一组像素每次分出一样的类。
    private static func cluster(_ pts: [Sample]) -> [Swatch] {
        guard pts.count >= 20 else { return [] }
        let k = 5
        let byL = pts.sorted { $0.l < $1.l }
        // 拆成循环和带类型的 let：Xcode 16（Swift 6.1）的类型检查器对闭包里这一串整数运算会超时
        var centres: [(Double, Double, Double)] = []
        for c in 0..<k {
            let rank: Int = (2 * c + 1) * byL.count / (2 * k)
            let p = byL[min(byL.count - 1, rank)]
            centres.append((p.l, p.a, p.b))
        }
        var assign = [Int](repeating: 0, count: pts.count)
        for _ in 0..<8 {
            for (n, p) in pts.enumerated() {
                var best = 0
                var bestD = Double.infinity
                for (c, m) in centres.enumerated() {
                    let dl = p.l - m.0
                    let da = p.a - m.1
                    let db = p.b - m.2
                    let d: Double = dl * dl + da * da + db * db
                    if d < bestD {
                        bestD = d
                        best = c
                    }
                }
                assign[n] = best
            }
            var sum = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: k)
            for (n, p) in pts.enumerated() {
                let c = assign[n]
                sum[c].0 += p.l * p.w
                sum[c].1 += p.a * p.w
                sum[c].2 += p.b * p.w
                sum[c].3 += p.w
            }
            for c in 0..<k where sum[c].3 > 0 {
                centres[c] = (sum[c].0 / sum[c].3, sum[c].1 / sum[c].3, sum[c].2 / sum[c].3)
            }
        }
        var weight = [Double](repeating: 0, count: k)
        for (n, p) in pts.enumerated() { weight[assign[n]] += p.w }
        let total = max(1e-9, weight.reduce(0, +))
        return (0..<k).map { c in
            Swatch(l: centres[c].0, a: centres[c].1, b: centres[c].2, share: weight[c] / total)
        }.filter { $0.share >= accentMinShare }.sorted { $0.share > $1.share }
    }

    // MARK: - 颜色换算（sRGB D65）

    private static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let lr = CollageLooks.linear(r)
        let lg = CollageLooks.linear(g)
        let lb = CollageLooks.linear(b)
        let x: Double = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y: Double = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z: Double = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let fx = f(x)
        let fy = f(y)
        let fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func srgb(l: Double, a: Double, b: Double) -> CollageColor {
        let fy: Double = (l + 16) / 116
        let fx: Double = fy + a / 500
        let fz: Double = fy - b / 200
        func inv(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116) / 7.787 }
        let x: Double = inv(fx) * 0.95047
        let y: Double = inv(fy)
        let z: Double = inv(fz) * 1.08883
        let lr: Double = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let lg: Double = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let lb: Double = 0.0557 * x - 0.2040 * y + 1.0570 * z
        func gamma(_ v: Double) -> Double {
            let c = min(1, max(0, v))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return CollageColor(r: gamma(lr), g: gamma(lg), b: gamma(lb))
    }

    /// 颜色和底下（线性亮度）的对比度。
    static func contrast(_ c: CollageColor, _ bgLinear: Double) -> Double {
        let y = linearLuminance(c)
        return (max(y, bgLinear) + 0.05) / (min(y, bgLinear) + 0.05)
    }

    static func linearLuminance(_ c: CollageColor) -> Double {
        let lr = CollageLooks.linear(c.r)
        let lg = CollageLooks.linear(c.g)
        let lb = CollageLooks.linear(c.b)
        return 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
    }
}
