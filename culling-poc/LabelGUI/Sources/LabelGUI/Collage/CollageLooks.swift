import Foundation
import CoreGraphics
import CoreImage

/// 整组统一色调：每个色调是一个纯函数 f(r,g,b)，按需生成 32³ 的 3D LUT（CIColorCube）；
/// 「统一到主图」是每张照片一组 RGB 增益（线性光里乘），把色温、明暗往主图拉一截。
///
/// 所有判断都来自固定分辨率的预览统计（256 预览缩到 16×16），和渲染缩放、导出解码无关 ——
/// 界面预览和导出的颜色一致。
enum CollageLooks {

    struct Ops: Hashable {
        /// 线性光 RGB 增益；nil = 不动。
        var gains: [Double]?
        var look: CollageLook = .none
        var strength = 0.8

        /// 黑白、旧照强度拖到 0 也还是黑白（以前 0 就变回彩色，1% 又全去色，滑杆在 0 附近跳）。
        var isIdentity: Bool { gains == nil && (look == .none || (strength <= 0.001 && !look.isMonochrome)) }
    }

    // MARK: - 每页每张照片的调色参数

    /// 主图 = 这一页分数最高的照片（和「主图取色」底色、评分里的主图是同一张）。
    static func ops(style: CollageStyle, pagePhotoIDs: [String],
                    photos: [String: CollagePhotoRef]) -> [String: Ops] {
        let onPage = pagePhotoIDs.compactMap { photos[$0] }
        guard !onPage.isEmpty else { return [:] }
        let base = Ops(gains: nil, look: style.look, strength: style.lookStrength)
        var out: [String: Ops] = [:]
        for p in onPage { out[p.id] = base }
        guard style.harmonize > 0.001, onPage.count >= 2,
              let hero = onPage.max(by: { $0.score < $1.score }),
              let target = stats(hero) else { return out }
        for p in onPage where p.id != hero.id {
            guard let s = stats(p) else { continue }
            var ops = base
            ops.gains = gains(from: s, to: target, amount: style.harmonize)
            out[p.id] = ops
        }
        return out
    }

    /// 平均色（线性光）。
    struct Stats: Hashable {
        var r: Double
        var g: Double
        var b: Double
        var lum: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    /// 色度（除掉亮度的颜色方向）往目标靠 amount×0.75，亮度只靠一半 —— 不能把夜景拉成白天。
    static func gains(from s: Stats, to t: Stats, amount: Double) -> [Double]? {
        let sl = max(1e-4, s.lum)
        let tl = max(1e-4, t.lum)
        let k = min(1, max(0, amount)) * 0.75
        let src = [s.r / sl, s.g / sl, s.b / sl]
        let dst = [t.r / tl, t.g / tl, t.b / tl]
        var g = [1.0, 1.0, 1.0]
        for i in 0..<3 {
            let ratio = max(1e-4, dst[i]) / max(1e-4, src[i])
            g[i] = min(1.22, max(0.82, pow(ratio, k)))
        }
        let lumGain = min(1.25, max(0.8, pow(tl / sl, k * 0.5)))
        let after = 0.2126 * s.r * g[0] + 0.7152 * s.g * g[1] + 0.0722 * s.b * g[2]
        let norm = lumGain * sl / max(1e-4, after)
        let out = g.map { $0 * norm }
        let change = out.map { abs($0 - 1) }.max() ?? 0
        return change < 0.004 ? nil : out
    }

    private static let statsLock = NSLock()
    private static var statsCache: [String: Stats] = [:]

    static func stats(_ photo: CollagePhotoRef) -> Stats? {
        let key = CollageVision.cacheKey(photo)
        statsLock.lock()
        if let hit = statsCache[key] {
            statsLock.unlock()
            return hit
        }
        statsLock.unlock()
        guard let image = CollageImages.preview(photo, need: 256) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CollageRender.srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        var r = 0.0
        var g = 0.0
        var b = 0.0
        var n = 0.0
        for i in 0..<(side * side) {
            let lr = linear(Double(pixels[i * 4]) / 255)
            let lg = linear(Double(pixels[i * 4 + 1]) / 255)
            let lb = linear(Double(pixels[i * 4 + 2]) / 255)
            // 死白、死黑（天空过曝、黑衣服）不参与：它们没有颜色信息，只会把增益带偏。
            let l = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
            if l > 0.92 || l < 0.004 { continue }
            r += lr
            g += lg
            b += lb
            n += 1
        }
        guard n >= 8 else { return nil }
        let s = Stats(r: r / n, g: g / n, b: b / n)
        statsLock.lock()
        if statsCache.count > 512 { statsCache.removeAll() }
        statsCache[key] = s
        statsLock.unlock()
        return s
    }

    static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    // MARK: - 应用

    static func apply(_ image: CIImage, ops: Ops?) -> CIImage {
        guard let ops, !ops.isIdentity else { return image }
        var out = image
        if let g = ops.gains, g.count == 3, let matrix = CIFilter(name: "CIColorMatrix") {
            matrix.setValue(out, forKey: kCIInputImageKey)
            matrix.setValue(CIVector(x: CGFloat(g[0]), y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrix.setValue(CIVector(x: 0, y: CGFloat(g[1]), z: 0, w: 0), forKey: "inputGVector")
            matrix.setValue(CIVector(x: 0, y: 0, z: CGFloat(g[2]), w: 0), forKey: "inputBVector")
            if let o = matrix.outputImage { out = o }
        }
        if ops.look != .none, ops.strength > 0.001 || ops.look.isMonochrome,
           let data = cube(ops.look, strength: ops.strength),
           let filter = CIFilter(name: "CIColorCubeWithColorSpace") {
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(cubeSize, forKey: "inputCubeDimension")
            filter.setValue(data, forKey: "inputCubeData")
            filter.setValue(CollageRender.srgb, forKey: "inputColorSpace")
            if let o = filter.outputImage { out = o }
        }
        return out
    }

    // MARK: - 3D LUT

    static let cubeSize = 32
    private static let cubeLock = NSLock()
    private static var cubeCache: [String: Data] = [:]

    /// 强度按 5% 一档缓存（滑杆拖动时不每个值都生成一次）。
    static func cube(_ look: CollageLook, strength: Double) -> Data? {
        let bucket = Int((min(1, max(0, strength)) * 20).rounded())
        let key = "\(look.rawValue)#\(bucket)"
        cubeLock.lock()
        if let hit = cubeCache[key] {
            cubeLock.unlock()
            return hit
        }
        cubeLock.unlock()
        let s = Double(bucket) / 20
        let n = cubeSize
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    let g = Double(gi) / Double(n - 1)
                    let b = Double(bi) / Double(n - 1)
                    let out = grade(r, g, b, look: look, strength: s)
                    values[i] = Float(out.0)
                    values[i + 1] = Float(out.1)
                    values[i + 2] = Float(out.2)
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cubeLock.lock()
        // 一张 LUT 512KB：几个色调来回拖强度会攒到七八十 MB，攒多了清掉重生成（几毫秒一张）。
        if cubeCache.count >= 24 { cubeCache.removeAll() }
        cubeCache[key] = data
        cubeLock.unlock()
        return data
    }

    /// 一个颜色套上色调（sRGB 伽马值 0…1）：LUT 的每个格点、「主图取色」的底色都用它。
    /// 黑白、旧照：强度只管影调，去色永远是全的（半黑白的照片看起来像坏了）。
    static func grade(_ r: Double, _ g: Double, _ b: Double, look: CollageLook,
                      strength: Double) -> (Double, Double, Double) {
        guard look != .none else { return (r, g, b) }
        let s = min(1, max(0, strength))
        let m = map(look, r, g, b)
        let l = luma(r, g, b)
        let r0 = look.isMonochrome ? l : r
        let g0 = look.isMonochrome ? l : g
        let b0 = look.isMonochrome ? l : b
        return (clamp01(r0 + (m.0 - r0) * s), clamp01(g0 + (m.1 - g0) * s), clamp01(b0 + (m.2 - b0) * s))
    }

    /// 每个色调：输入输出都是 sRGB 伽马值 0…1。
    static func map(_ look: CollageLook, _ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = luma(r, g, b)
        let ws = (1 - l) * (1 - l)
        let wh = l * l
        switch look {
        case .none:
            return (r, g, b)
        case .film:
            // 暖、柔、黑位抬一点；暗部一丝青绿，高光奶油色。
            var c = [curve(r, lift: 0.06, gain: 0.97, contrast: 0.22),
                     curve(g, lift: 0.06, gain: 0.97, contrast: 0.22),
                     curve(b, lift: 0.06, gain: 0.97, contrast: 0.22)]
            c[0] = c[0] * 1.045 - 0.025 * ws + 0.02 * wh
            c[1] = c[1] + 0.018 * ws + 0.01 * wh
            c[2] = c[2] * 0.93 + 0.03 * ws - 0.03 * wh
            return saturate(c, 0.86)
        case .airy:
            // 日系清透：中间调提亮、反差放低、饱和降、偏一点青。
            var c = [r, g, b].map { v -> Double in
                let bright = 1 - pow(1 - v, 1.28)
                return curve(bright, lift: 0.05, gain: 1, contrast: -0.12)
            }
            c[0] -= 0.012
            c[1] += 0.006
            c[2] += 0.02
            return saturate(c, 0.78)
        case .faded:
            // 复古褪色：黑位灰、白位压、偏黄，暗部带点棕。
            var c = [curve(r, lift: 0.1, gain: 0.93, contrast: 0.1),
                     curve(g, lift: 0.1, gain: 0.93, contrast: 0.1),
                     curve(b, lift: 0.1, gain: 0.93, contrast: 0.1)]
            c[0] += 0.025 + 0.01 * ws
            c[1] += 0.012
            c[2] -= 0.035 + 0.01 * ws
            return saturate(c, 0.72)
        case .cinema:
            // 青橙：暗部往青、高光（肤色）往橙，反差大一点。
            var c = [curve(r, lift: 0.035, gain: 0.975, contrast: 0.38),
                     curve(g, lift: 0.035, gain: 0.975, contrast: 0.38),
                     curve(b, lift: 0.035, gain: 0.975, contrast: 0.38)]
            let wm: Double = 4 * l * (1 - l)
            c[0] += -0.1 * ws + 0.07 * wh + 0.025 * wm
            c[1] += 0.025 * ws + 0.02 * wh
            c[2] += 0.09 * ws - 0.09 * wh - 0.03 * wm
            return saturate(c, 0.9)
        case .cool:
            // 冷淡：低饱和、偏蓝、反差略低。
            var c = [curve(r, lift: 0.04, gain: 0.97, contrast: -0.05),
                     curve(g, lift: 0.04, gain: 0.97, contrast: -0.05),
                     curve(b, lift: 0.04, gain: 0.97, contrast: -0.05)]
            c[0] -= 0.015
            c[2] += 0.025
            return saturate(c, 0.62)
        case .mono:
            let v = curve(l, lift: 0.02, gain: 0.985, contrast: 0.25)
            return (v, v, v)
        case .sepia:
            let v = curve(l, lift: 0.07, gain: 0.94, contrast: 0.15)
            return (clamp01(v * 1.07 + 0.01), clamp01(v), clamp01(v * 0.86))
        }
    }

    private static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let lr: Double = 0.2126 * r
        let lg: Double = 0.7152 * g
        let lb: Double = 0.0722 * b
        return lr + lg + lb
    }

    /// 抬黑位 / 压白位 + S 曲线（contrast < 0 是反 S，降反差）。
    private static func curve(_ x: Double, lift: Double, gain: Double, contrast: Double) -> Double {
        let v = clamp01(x)
        let s: Double = v * v * (3 - 2 * v)
        let shaped: Double = v + (s - v) * contrast
        return lift + (gain - lift) * clamp01(shaped)
    }

    private static func saturate(_ c: [Double], _ amount: Double) -> (Double, Double, Double) {
        let l = luma(c[0], c[1], c[2])
        let r: Double = l + (c[0] - l) * amount
        let g: Double = l + (c[1] - l) * amount
        let b: Double = l + (c[2] - l) * amount
        return (clamp01(r), clamp01(g), clamp01(b))
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}
