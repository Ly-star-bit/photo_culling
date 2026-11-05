import Foundation
import CoreImage

/// 光谱胶片的颗粒和晕光：照着 spektrafilm（Andrea Volpato，github.com/andreavolpato/spektrafilm）的模型，
/// 用 Core Image 的现成滤镜拼出来。只在光谱色调（CollageLook.isSpectral）、照片格里（CollageRender.cellImage）做；
/// 两项都是 0 = 原样走 CollageLooks.apply，和没有这两项时逐像素一样。
///
/// 尺寸都按「一张照片 = 一张 35mm 底片」换算：像素边长 = 底片宽 / 照片在这次渲染里的长边像素。所以颗粒、晕光是
/// 跟输出像素走的 —— 小预览里几乎看不见，导出、放大预览才看得清（和加网一样，有意的，CollageScreen.swift 开头）。
///
/// 晕光（片基反射，上游 apply_halation_um 的第 2 步）：在线性光上
///   x' = (x + A ⊙ Σ_k w_k · G(σ_h·√k) * x) / (1 + A)，三次反弹，w_k ∝ 0.5^(k-1)，
/// σ_h = 片基厚度给的 65 µm（照相片）/ 50 µm（电影片），A = 滑杆 × 上游「没有防光晕层」那一档（0.30, 0.10, 0.015）。
/// 近似：上游是在胶片的曝光量上做（光谱感光度之后），这里直接用照片的线性 sRGB；乳剂里几微米的散射在拼图的
/// 像素尺寸下看不出来，不做。晕光改的是喂给色调表的光，所以底色跟着变（高光边上泛红）。
///
/// 颗粒（上游 apply_grain_to_density_layers）：在胶片密度上加噪声，密度是 spektrafilm 在 cmy_film 这一步给的。
/// 表拆成两半（Scripts/bake_film_luts.py）：film = sRGB → 归一化密度，print = 密度 → 线性光；
///   颗粒 = print(d + δ) − print(d)，δ = σ(d) / 像素边长 × 噪声（噪声模糊 0.65 像素）；
/// σ(d) 是泊松-二项模型的解析标准差（烘焙时和上游真抽样对过，差 1% 以内）。颗粒是零均值的增量，按色调强度
/// 加在一步到位那张色调表的结果上：底色还是那张表（CPU 上取色、判字色深浅都不受影响）。
/// 滑杆 0.5 = 这款胶片在 35mm 底片上的真实颗粒，1 = 两倍。噪声按照片 id 定位置（FNV，不用 hashValue）：同一张照片
/// 每次导出一样。
enum CollageFilmEffects {

    struct Extras {
        let size: Int
        /// CIColorCube 要的 RGBA Float32：film 表（值 = 归一化密度按 sRGB 编码）、print 表（值 = 线性光）、
        /// σ 表（可分离：每个通道只看自己的归一化密度，值 = 1 µm 像素上的标准差）。
        let filmCube: Data
        let printCube: Data
        let sigmaCube: Data
        let film: CollageFilmLUTs.Table
        let print: CollageFilmLUTs.Table
        /// 每个通道 256 个点：归一化密度 0…1 上的 σ（1 µm 像素，归一化单位）。
        let sigmaUnit: [[Double]]
        let filmFormatMM: Double
        let grainBlurPx: Double
        let halationSigmaUM: Double
        let halationStrengthMax: [Double]
        let halationBounces: Int
        let halationDecay: Double
    }

    private struct Meta: Decodable {
        let split_size: Int
        let film_format_mm: Double
        let grain_blur_px: Double
        let grain_sigma_unit: [[Double]]
        struct Halation: Decodable {
            let sigma_um: Double
            let strength_max: [Double]
            let bounces: Int
            let bounce_decay: Double
        }
        let halation: Halation
    }

    private static let lock = NSLock()
    private static var cache: [CollageLook: Extras] = [:]
    private static var missing: Set<CollageLook> = []

    /// 这个光谱色调的颗粒、晕光数据（<rawValue>.film.cube / .print.cube / .json）。读不到 = nil（两项都不做）。
    static func extras(_ look: CollageLook) -> Extras? {
        guard look.isSpectral else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[look] { return hit }
        if missing.contains(look) { return nil }
        if let dir = CollageFilmLUTs.directory, let e = load(look, from: dir) {
            cache[look] = e
            return e
        }
        missing.insert(look)
        return nil
    }

    static func load(_ look: CollageLook, from dir: URL) -> Extras? {
        func table(_ suffix: String) -> CollageFilmLUTs.Table? {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(look.rawValue + suffix), encoding: .utf8)
            else { return nil }
            return CollageFilmLUTs.parse(text)
        }
        guard let film = table(".film.cube"), let print = table(".print.cube"), film.size == print.size,
              let json = try? Data(contentsOf: dir.appendingPathComponent(look.rawValue + ".json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: json),
              meta.split_size == film.size, meta.grain_sigma_unit.count == 3,
              meta.grain_sigma_unit.allSatisfy({ $0.count >= 2 && $0.allSatisfy { $0.isFinite && $0 >= 0 } }),
              meta.halation.strength_max.count == 3, meta.film_format_mm > 0
        else { return nil }
        let n = film.size
        // σ 表：可分离的 3D 表，R 最快、B 最慢（和 CIColorCube 一样）。
        var sigma = [Float](repeating: 0, count: n * n * n * 4)
        func at(_ c: Int, _ t: Double) -> Double {
            let s = meta.grain_sigma_unit[c]
            let x = min(1, max(0, t)) * Double(s.count - 1)
            let i = min(Int(x), s.count - 2)
            return s[i] + (s[i + 1] - s[i]) * (x - Double(i))
        }
        var k = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    sigma[k] = Float(at(0, Double(ri) / Double(n - 1)))
                    sigma[k + 1] = Float(at(1, Double(gi) / Double(n - 1)))
                    sigma[k + 2] = Float(at(2, Double(bi) / Double(n - 1)))
                    sigma[k + 3] = 1
                    k += 4
                }
            }
        }
        return Extras(size: n, filmCube: rgba(film), printCube: rgba(print),
                      sigmaCube: sigma.withUnsafeBufferPointer { Data(buffer: $0) },
                      film: film, print: print, sigmaUnit: meta.grain_sigma_unit,
                      filmFormatMM: meta.film_format_mm, grainBlurPx: meta.grain_blur_px,
                      halationSigmaUM: meta.halation.sigma_um, halationStrengthMax: meta.halation.strength_max,
                      halationBounces: max(1, min(6, meta.halation.bounces)), halationDecay: meta.halation.bounce_decay)
    }

    private static func rgba(_ t: CollageFilmLUTs.Table) -> Data {
        var out = [Float](repeating: 1, count: t.size * t.size * t.size * 4)
        for i in 0..<(t.size * t.size * t.size) {
            out[i * 4] = t.rgb[i * 3]
            out[i * 4 + 1] = t.rgb[i * 3 + 1]
            out[i * 4 + 2] = t.rgb[i * 3 + 2]
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - 渲染

    /// 照片格的调色：光谱色调开了颗粒 / 晕光就走这里，否则就是 CollageLooks.apply。
    /// frameLongEdge = 整张照片（不是格子里露出来的那块）在这次渲染里的长边像素；seed = 照片 id（定噪声位置）。
    static func apply(_ image: CIImage, ops: CollageLooks.Ops?, frameLongEdge: Double, seed: String,
                      extent: CGRect) -> CIImage {
        guard let ops, ops.look.isSpectral, ops.strength > 0.001, ops.grain > 0.001 || ops.halation > 0.001,
              frameLongEdge.isFinite, frameLongEdge >= 1, let fx = extras(ops.look)
        else { return CollageLooks.apply(image, ops: ops) }
        let pixelUM = fx.filmFormatMM * 1000 / frameLongEdge
        var lin = CollageLooks.applyGains(image, ops: ops)
        if ops.halation > 0.001 {
            lin = halate(lin, fx: fx, pixelUM: pixelUM, amount: ops.halation, extent: extent)
        }
        let base = CollageLooks.applyCube(lin, ops: ops)
        guard ops.grain > 0.001,
              let (p1, p2) = grainPrints(lin, fx: fx, pixelUM: pixelUM, amount: ops.grain, seed: seed, extent: extent)
        else { return base }
        // base + s·(p2 − p1)。
        let s = ops.strength
        return add(scale(p1, -s, -s, -s), onto: add(scale(p2, s, s, s), onto: base, extent: extent), extent: extent)
    }

    /// 片基反射的晕光，线性光进、线性光出。
    static func halate(_ lin: CIImage, fx: Extras, pixelUM: Double, amount: Double, extent: CGRect) -> CIImage {
        let a = fx.halationStrengthMax.map { $0 * min(1, max(0, amount)) }
        let sigma0 = fx.halationSigmaUM / pixelUM
        guard sigma0 > 0.05, a.contains(where: { $0 > 0 }) else { return lin }
        let weights = (0..<fx.halationBounces).map { pow(fx.halationDecay, Double($0)) }
        let total = weights.reduce(0, +)
        let clamped = lin.clampedToExtent()
        var sum: CIImage?
        for (i, w) in weights.enumerated() {
            let sigma = sigma0 * Double(i + 1).squareRoot()
            let blurred = clamped.applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            let part = scale(blurred, w / total, w / total, w / total)
            sum = sum.map { add(part, onto: $0, extent: extent) } ?? part
        }
        guard let h = sum else { return lin }
        let raised = add(scale(h, a[0], a[1], a[2]), onto: lin, extent: extent)
        return scale(raised, 1 / (1 + a[0]), 1 / (1 + a[1]), 1 / (1 + a[2])).cropped(to: extent)
    }

    /// 颗粒：print(d)、print(d + δ) 两张（线性光）；颗粒 = 两张之差（均值约 0）。
    static func grainPrints(_ lin: CIImage, fx: Extras, pixelUM: Double, amount: Double, seed: String,
                            extent: CGRect) -> (CIImage, CIImage)? {
        guard let film = cube(lin, fx.filmCube, fx.size, colorSpace: CollageRender.srgb) else { return nil }
        // film 表按 sRGB 编码存的归一化密度：CIColorCubeWithColorSpace 出来回到线性工作空间，正好是归一化密度。
        let k = 2 * min(1, max(0, amount)) / pixelUM
        guard let sigmaRaw = cube(film, fx.sigmaCube, fx.size, colorSpace: nil) else { return nil }
        let sigma = scale(sigmaRaw, k, k, k)
        let (ox, oy) = offset(seed)
        let twelve = 12.0.squareRoot()
        // 噪声：每个通道独立的均匀分布，挪到均值 0、方差 1。CIRandomGenerator 的 alpha 也是随机的，
        // 先 settingAlphaOne（不动 RGB）；直接用 CIColorMatrix 改 alpha 会先除以那个随机 alpha。
        let uniform = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
            .cropped(to: extent).settingAlphaOne(in: extent)
        guard let uniform else { return nil }
        let noise = scale(uniform, twelve, twelve, twelve, bias: -0.5 * twelve)
        guard let multiply = CIFilter(name: "CIMultiplyCompositing") else { return nil }
        multiply.setValue(sigma, forKey: kCIInputImageKey)
        multiply.setValue(noise, forKey: kCIInputBackgroundImageKey)
        guard var delta = multiply.outputImage?.cropped(to: extent) else { return nil }
        if fx.grainBlurPx > 0.05 {
            delta = delta.clampedToExtent().applyingGaussianBlur(sigma: fx.grainBlurPx).cropped(to: extent)
        }
        let shifted = add(delta, onto: film, extent: extent)
        guard let p1 = cube(film, fx.printCube, fx.size, colorSpace: nil),
              let p2 = cube(shifted, fx.printCube, fx.size, colorSpace: nil) else { return nil }
        return (p1.cropped(to: extent), p2.cropped(to: extent))
    }

    /// 照片 id → 噪声图上的位置（FNV-1a，跨进程稳定）。
    static func offset(_ seed: String) -> (Double, Double) {
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return (Double(h % 8192) * 3, Double((h >> 20) % 8192) * 3)
    }

    // MARK: - 小工具（都在线性工作空间里、alpha 都是 1）

    private static func cube(_ image: CIImage, _ data: Data, _ size: Int, colorSpace: CGColorSpace?) -> CIImage? {
        let filter = CIFilter(name: colorSpace == nil ? "CIColorCube" : "CIColorCubeWithColorSpace")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(size, forKey: "inputCubeDimension")
        filter?.setValue(data, forKey: "inputCubeData")
        if let colorSpace { filter?.setValue(colorSpace, forKey: "inputColorSpace") }
        return filter?.outputImage
    }

    /// 逐通道乘再加（alpha 不动）。输入的 alpha 要是 1：CIColorMatrix 会先除以 alpha。
    private static func scale(_ image: CIImage, _ r: Double, _ g: Double, _ b: Double, bias: Double = 0) -> CIImage {
        guard let m = CIFilter(name: "CIColorMatrix") else { return image }
        m.setValue(image, forKey: kCIInputImageKey)
        m.setValue(CIVector(x: CGFloat(r), y: 0, z: 0, w: 0), forKey: "inputRVector")
        m.setValue(CIVector(x: 0, y: CGFloat(g), z: 0, w: 0), forKey: "inputGVector")
        m.setValue(CIVector(x: 0, y: 0, z: CGFloat(b), w: 0), forKey: "inputBVector")
        m.setValue(CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 0), forKey: "inputBiasVector")
        return m.outputImage ?? image
    }

    /// 背景 + 前景，有正有负、超过 1 都照算，alpha 保持 1。Core Image 的混合模式（CILinearDodgeBlendMode、
    /// CISubtractBlendMode）会把结果夹到 0…1（颗粒的负半边、蓝天上 base + print 超过 1 的那截都会丢）；合成算子
    /// CIAdditionCompositing 不夹，但 alpha 也相加成 2，所以加完 settingAlphaOne（只改 alpha、不动 RGB）。
    private static func add(_ top: CIImage, onto bottom: CIImage, extent: CGRect) -> CIImage {
        guard let f = CIFilter(name: "CIAdditionCompositing") else { return bottom }
        f.setValue(top, forKey: kCIInputImageKey)
        f.setValue(bottom, forKey: kCIInputBackgroundImageKey)
        return (f.outputImage ?? bottom).cropped(to: extent).settingAlphaOne(in: extent)
    }
}
