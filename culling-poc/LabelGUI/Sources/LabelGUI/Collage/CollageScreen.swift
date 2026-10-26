import Foundation
import CoreGraphics
import CoreImage

/// 照片加网（报纸风，R5 §4）：cellImage 里色调之后、替代锐化的一步。
///
/// 管线：去色 → CILinearToSRGBToneCurve（在 sRGB 数值上加网：线性光里 sRGB 128 要盖 84% 的墨，整张发闷）→
/// 压到 [0.06, 0.94]（不压的话暗部、高光整块变死）→ 网点增大曲线（新闻纸 IFRA26 实测，按 gain 混一半）→
/// CIDotScreen / CILineScreen（宽 = 点距像素，中心 = 这一格的左上角）→ CISRGBToneCurveToLinear →
/// CIFalseColor（0 = 墨色，1 = 纸色）。
///
/// 点距按画布短边的比例给（预览、导出、印刷看起来一样粗），实际不到 3 像素时（预览缩得小、缩略图、相册跨页预览）
/// 不出点，只调影调：同一条曲线算到「这一片平均有多少纸露出来」，墨色纸色按这个比例在线性光里混 —— 和出点时
/// 远看的明暗一样，只是没有点（不出点是为了不起摩尔纹；预览和导出在小尺寸下因此不同，是有意的）。
enum CollageScreening {

    /// 一张照片这次怎么加网：调用方按画布、渲染缩放、页面底色定好，交给 cellImage。
    struct Spec: Hashable {
        var halftone: CollageHalftone
        /// 这次渲染的实际点距（像素）= pitch × 画布短边 × 渲染缩放。
        var pitchPx: Double
        /// 纸色（halftone.paper 没设 = 页面底色；深色页上换成纸白，见 paper(_:background:)）。
        var paper: CollageColor

        /// 点距够不够出点；不够 = 只调影调。
        var screened: Bool { pitchPx >= minPitch }

        /// 切图向导（Shown.guide）、缓存键用：加网的 tile 和不加网的不是同一张。
        var key: String {
            let h = halftone
            return String(format: "ht:%@:%.4f:%.2f:%.3f:%.3f:%@:%@", h.screen.rawValue, pitchPx, h.angle, h.sharpness,
                          h.gain, hex(h.ink), hex(paper))
        }
    }

    /// 点距下限（像素）：再细 CIDotScreen 就开始混叠出摩尔纹。
    static let minPitch = 3.0

    /// 这一页的加网参数；样式没开网点 = nil（cellImage 照旧锐化，逐像素不变）。
    static func spec(_ halftone: CollageHalftone?, canvas: CollageCanvas, scale: Double,
                     background: CollageColor) -> Spec? {
        guard let halftone else { return nil }
        let pitchPx: Double = halftone.pitch * canvas.shortSide * scale
        return Spec(halftone: halftone, pitchPx: pitchPx, paper: paper(halftone, background: background))
    }

    /// 纸色和墨色至少差这么多亮度（0…1），不够就不跟页面底色走。
    static let minPaperContrast = 0.35

    /// 实际用的纸色：设了就用设的；没设跟页面底色（白页上照片的白就是这张纸的白；模糊底、渐变底时调用方给的是
    /// 盖在照片底上的那层底色块，不是算出来的平均色，见 render(page:)）。但深色页（墨黑、暖黑、电影）
    /// 配默认的深墨，墨和纸几乎一个颜色，照片整张黑在黑上看不见 —— 这时纸换成纸白，像一张剪报放在深色台面上。
    /// 只在墨是深色时换：墨浅纸深出来的是负片（CIFalseColor 0 → 墨、1 → 纸），浅墨是用户自己挑的，照他的来。
    static func paper(_ halftone: CollageHalftone, background: CollageColor) -> CollageColor {
        if let paper = halftone.paper { return paper }
        let inkLuma = halftone.ink.luminance
        let gap: Double = abs(background.luminance - inkLuma)
        guard gap < minPaperContrast, inkLuma < 0.5 else { return background }
        return .paper
    }

    // MARK: - 管线

    /// image = 调完色的那一格（范围 = extent，左下原点）。返回裁到 extent 的结果。
    static func apply(_ image: CIImage, spec: Spec, extent: CGRect) -> CIImage {
        let h = spec.halftone
        var out = image
        if let desat = CIFilter(name: "CIColorControls") {
            desat.setValue(out, forKey: kCIInputImageKey)
            desat.setValue(0, forKey: kCIInputSaturationKey)
            if let o = desat.outputImage { out = o }
        }
        out = filtered("CILinearToSRGBToneCurve", out)
        guard spec.screened else {
            // 不出点：压范围、网点增大之后照网屏的曲线算平均露纸比例，墨、纸在线性光里按它混（和出点时远看一样亮）。
            return cube(out, data: toneCube(spec)).cropped(to: extent)
        }
        out = cube(out, data: gainCube(h.gain))
        let name = h.screen == .line ? "CILineScreen" : "CIDotScreen"
        if let screen = CIFilter(name: name) {
            screen.setValue(out, forKey: kCIInputImageKey)
            screen.setValue(spec.pitchPx, forKey: kCIInputWidthKey)
            screen.setValue(h.angle * Double.pi / 180, forKey: kCIInputAngleKey)
            screen.setValue(h.sharpness, forKey: kCIInputSharpnessKey)
            // 网的原点 = 这一格的左上角（CI 是左下原点）：同一格预览、导出网点的相位一样。
            screen.setValue(CIVector(x: extent.minX, y: extent.maxY), forKey: kCIInputCenterKey)
            if let o = screen.outputImage { out = o }
        }
        out = filtered("CISRGBToneCurveToLinear", out)
        if let falseColor = CIFilter(name: "CIFalseColor") {
            falseColor.setValue(out, forKey: kCIInputImageKey)
            falseColor.setValue(CIColor(cgColor: h.ink.cgColor), forKey: "inputColor0")
            falseColor.setValue(CIColor(cgColor: spec.paper.cgColor), forKey: "inputColor1")
            if let o = falseColor.outputImage { out = o }
        }
        return out.cropped(to: extent)
    }

    /// 压范围 + 网点增大（逐像素）：用 CIColorCube 在手里的数值上直接查。不用 CIToneCurve —— 它自己会先把工作空间的
    /// 线性值转成 sRGB 再套曲线（实测 0.5 → 0.344 而不是 0.370），这里的数值已经是 sRGB 数值了，再转一次就过了头。
    private static func gainCube(_ gain: Double) -> Data? {
        let bucket = Int((min(1, max(0, gain)) * 50).rounded())
        let key = "gain#\(bucket)"
        return cached(key) {
            lut { x in
                let g: Double = gainCurve(compress(x), gain: Double(bucket) / 50)
                return (g, g, g)
            }
        }
    }

    private static func cube(_ image: CIImage, data: Data?) -> CIImage {
        guard let data, let f = CIFilter(name: "CIColorCube") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(cubeSize, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        return f.outputImage ?? image
    }

    /// 32³ 的表：输入是灰的（去过色），三个分量取平均当 x；格点不在对角线上的也有个合理的值。
    private static func lut(_ map: (Double) -> (Double, Double, Double)) -> Data {
        let n = cubeSize
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let sum = Double(ri + gi + bi)
                    let x: Double = sum / Double(3 * (n - 1))
                    let v = map(x)
                    values[i] = Float(v.0)
                    values[i + 1] = Float(v.1)
                    values[i + 2] = Float(v.2)
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func compress(_ x: Double) -> Double {
        let k: Double = rangeHigh - rangeLow
        return rangeLow + k * min(1, max(0, x))
    }

    /// 加网前压到的范围。
    static let rangeLow = 0.06
    static let rangeHigh = 0.94

    /// 网点增大曲线的 5 个点（R5：IFRA26 的 K 梯尺按 Murray-Davies 换到 Y 上）；gain = 0 是直线，1 = 全量。
    static let fullGain: [Double] = [0, 0.083, 0.239, 0.529, 1]

    /// 曲线上任一点：5 个点之间用单调三次插值（Fritsch–Carlson，不会冲过头、不会倒着走）。
    static func gainCurve(_ x: Double, gain: Double) -> Double {
        let g = min(1, max(0, gain))
        let xs: [Double] = [0, 0.25, 0.5, 0.75, 1]
        let ys: [Double] = xs.indices.map { xs[$0] + (fullGain[$0] - xs[$0]) * g }
        let t = min(1, max(0, x))
        let i = min(3, Int(t / 0.25))
        // 各点的斜率：两边割线的调和平均（同号时），端点用单边割线。
        var d: [Double] = []
        for k in 0..<4 { d.append((ys[k + 1] - ys[k]) / 0.25) }
        var m: [Double] = [d[0]]
        for k in 1..<4 {
            let a = d[k - 1]
            let b = d[k]
            m.append(a * b <= 0 ? 0 : 2 * a * b / (a + b))
        }
        m.append(d[3])
        let h = 0.25
        let u: Double = (t - xs[i]) / h
        let u2: Double = u * u
        let u3: Double = u2 * u
        let h00: Double = 2 * u3 - 3 * u2 + 1
        let h10: Double = u3 - 2 * u2 + u
        let h01: Double = -2 * u3 + 3 * u2
        let h11: Double = u3 - u2
        let a0: Double = h00 * ys[i] + h01 * ys[i + 1]
        let a1: Double = (h10 * m[i] + h11 * m[i + 1]) * h
        return min(1, max(0, a0 + a1))
    }

    private static func filtered(_ name: String, _ image: CIImage) -> CIImage {
        guard let f = CIFilter(name: name) else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        return f.outputImage ?? image
    }

    // MARK: - 不出点：只调影调

    private static let cubeSize = 32
    private static let lock = NSLock()
    private static var coverageCache: [String: [Double]] = [:]
    private static var cubeCache: [String: Data] = [:]

    private static func cached(_ key: String, _ make: () -> Data) -> Data {
        lock.lock()
        if let hit = cubeCache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let data = make()
        lock.lock()
        // 一张表 512KB：几种墨色纸色来回换会攒，攒多了清掉重生成（几毫秒一张）。
        if cubeCache.count >= 12 { cubeCache.removeAll() }
        cubeCache[key] = data
        lock.unlock()
        return data
    }

    /// 数值 x → 压范围 → 网点增大 → 网屏的平均露纸比例 → 墨、纸在线性光里按它混（输出是工作空间的线性值）。
    private static func toneCube(_ spec: Spec) -> Data? {
        let h = spec.halftone
        let gainBucket = Int((min(1, max(0, h.gain)) * 50).rounded())
        let key = "tone#\(h.screen.rawValue)#\(sharpBucket(h.sharpness))#\(gainBucket)#\(hex(h.ink))#\(hex(spec.paper))"
        let table = coverage(h.screen, sharpness: h.sharpness)
        let ink = [CollageLooks.linear(h.ink.r), CollageLooks.linear(h.ink.g), CollageLooks.linear(h.ink.b)]
        let paper = [CollageLooks.linear(spec.paper.r), CollageLooks.linear(spec.paper.g),
                     CollageLooks.linear(spec.paper.b)]
        return cached(key) {
            lut { x in
                let g: Double = gainCurve(compress(x), gain: Double(gainBucket) / 50)
                let p = sample(table, g)
                let r: Double = ink[0] + (paper[0] - ink[0]) * p
                let gg: Double = ink[1] + (paper[1] - ink[1]) * p
                let b: Double = ink[2] + (paper[2] - ink[2]) * p
                return (r, gg, b)
            }
        }
    }

    private static func sharpBucket(_ s: Double) -> Int { Int((min(1, max(0, s)) * 50).rounded()) }

    /// 表上线性插值（表 = 0…1 等分的 33 个点）。
    private static func sample(_ table: [Double], _ x: Double) -> Double {
        guard table.count >= 2 else { return x }
        let t = min(1, max(0, x)) * Double(table.count - 1)
        let i = min(table.count - 2, Int(t))
        let f = t - Double(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    /// 网屏的「输入数值 → 平均露纸比例（线性光）」：拿平涂的灰块实际加一次网量出来（和点距无关，只跟网型、锐度有关），
    /// 按网型 + 锐度（2% 一档，按档的值生成、按档取）缓存。CIDotScreen 本身就不是直线：数值 0.5 只露 38% 的纸，
    /// 0.15 以下整块是墨 —— 只调影调时不照它算，预览会比导出亮一大截。
    static func coverage(_ screen: CollageScreen, sharpness: Double) -> [Double] {
        let bucket = sharpBucket(sharpness)
        let key = "\(screen.rawValue)#\(bucket)"
        lock.lock()
        if let hit = coverageCache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let table = measure(screen, sharpness: Double(bucket) / 50)
        lock.lock()
        coverageCache[key] = table
        lock.unlock()
        return table
    }

    private static func measure(_ screen: CollageScreen, sharpness: Double) -> [Double] {
        let side = 96
        let pitch = 8.0
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let space = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CollageRender.srgb
        var table: [Double] = []
        var row = [Float](repeating: 0, count: side * side * 4)
        for k in 0...32 {
            let v = Double(k) / 32
            // sRGB 灰 v 进工作空间是线性值，再过一次 CILinearToSRGBToneCurve 就是加网时手里的那个数值 v。
            let flat = CIImage(color: CIColor(cgColor: CGColor(srgbRed: v, green: v, blue: v, alpha: 1))).cropped(to: rect)
            var img = filtered("CILinearToSRGBToneCurve", flat)
            if let f = CIFilter(name: screen == .line ? "CILineScreen" : "CIDotScreen") {
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(pitch, forKey: kCIInputWidthKey)
                f.setValue(Double.pi / 4, forKey: kCIInputAngleKey)
                f.setValue(sharpness, forKey: kCIInputSharpnessKey)
                f.setValue(CIVector(x: 0, y: CGFloat(side)), forKey: kCIInputCenterKey)
                if let o = f.outputImage { img = o }
            }
            img = filtered("CISRGBToneCurveToLinear", img).cropped(to: rect)
            row.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress else { return }
                CollageRender.ciContext.render(img, toBitmap: base, rowBytes: side * 16, bounds: rect,
                                               format: .RGBAf, colorSpace: space)
            }
            var sum = 0.0
            for i in 0..<(side * side) { sum += Double(min(1, max(0, row[i * 4]))) }
            table.append(sum / Double(side * side))
        }
        // 量出来的应该单调不减（一点点渲染误差也别让它倒回去）。
        for i in 1..<table.count where table[i] < table[i - 1] { table[i] = table[i - 1] }
        return table
    }

    static func hex(_ c: CollageColor) -> String {
        let r = Int((c.r * 255).rounded())
        let g = Int((c.g * 255).rounded())
        let b = Int((c.b * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
