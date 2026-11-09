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
/// σ_h = 片基厚度给的 65 µm（照相片）/ 50 µm（电影片），A = 滑杆² × 上游「没有防光晕层」那一档（0.30, 0.10, 0.015）。
/// 平方刻度：真片的晕光都很弱（防光晕层 strong 的红 0.015 ≈ 滑杆 22%，weak 的 0.08 ≈ 52%），线性刻度时有用的那段
/// 全挤在滑杆最左边一小截，拉满是去掉防光晕层的电影片那种红光（reports/胶片模拟调研_2026-11-05/R8 §1.7）。
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
        /// 从「没有光谱色调」换进这一款时颗粒 / 晕光的起始值（滑杆刻度；烘焙脚本 RECIPES 的 defaults）。
        let defaultGrain: Double
        let defaultHalation: Double
        /// film / print 两半表的密度范围（物理单位）：冷暖的滤色、颗粒 σ 的换算要用。
        let splitLo: [Double]
        let splitHi: [Double]
        /// 冷暖滑杆 ±1 = ±几个 CC 的黄滤色、品滤色跟着走的比例（.json 的 develop；旧表没有 = 冷暖不起作用）。
        let warmthCCMax: Double
        let warmthMRatio: Double
        /// 胶片曝光用的放宽两半表（只有负片、电影负片有）。
        let ext: Ext?
        /// 反转片：冷暖的密度偏移反过来加（正片的密度直接挡光，负片还要经过相纸反一次）。
        let positive: Bool
    }

    /// 输入放宽到 head 倍线性光的两半表（film_e / print_e）。
    struct Ext {
        let film: CollageFilmLUTs.Table
        let print: CollageFilmLUTs.Table
        let filmCube: Data
        let printCube: Data
        let head: Double
        /// 冲扫店把中灰的密度位移补回多少（0.5 = 一半）。
        let compensation: Double
        let lo: [Double]
        let hi: [Double]
    }

    /// 冲印区的两个参数（CollageStyle.filmExposure / filmWarmth），量化到 0.1 档 / 5%：色调表按它缓存，CPU 取色和
    /// GPU 颗粒用的是同一个值。
    struct Printing: Hashable {
        var exposure: Double
        var warmth: Double

        init(exposure: Double = 0, warmth: Double = 0) {
            self.exposure = (min(2, max(-1, exposure.isFinite ? exposure : 0)) * 10).rounded() / 10
            self.warmth = (min(1, max(-1, warmth.isFinite ? warmth : 0)) * 20).rounded() / 20
        }

        var isNeutral: Bool { exposure == 0 && warmth == 0 }
    }

    /// 冲印区落到密度上的样子。CPU 算一次，CPU 取色（developed）和 GPU 颗粒（grainPrints）都用它，免得两边推导得不一样。
    struct Develop {
        /// true = 走放宽的两半表（胶片曝光 ≠ 0）。
        let ext: Bool
        /// 线性光进 film 表之前乘的：放宽表 = 2^EV / head，否则 1。
        let inputScale: Double
        /// film 表出来的归一化密度再加的：冲扫店补回的中灰位移 + 冷暖的滤色，按所用那张表的归一化单位。
        let bias: [Double]
        /// 颗粒 σ 表按普通 film 表的归一化密度查：所用那张表的密度 d → a·d + b 再查；查出来的 σ 再 × c 换回所用的单位。
        let sigmaA: [Double]
        let sigmaB: [Double]
        let sigmaC: [Double]

        var isIdentity: Bool { !ext && bias.allSatisfy { $0 == 0 } }
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
        struct Defaults: Decodable {
            let grain: Double
            let halation: Double
        }
        /// 第一版的表没有这一项。
        let defaults: Defaults?
        let d_lo: [Double]?
        let d_hi: [Double]?
        struct DevelopMeta: Decodable {
            let warmth_cc_max: Double?
            let warmth_m_ratio: Double?
            let ext_head: Double?
            let exposure_compensation: Double?
            let e_lo: [Double]?
            let e_hi: [Double]?
        }
        /// 第二版之前的表没有这一项（冲印区不起作用）。
        let develop: DevelopMeta?
    }

    private static let lock = NSLock()
    private static var cache: [CollageLook: Extras] = [:]
    private static var missing: Set<CollageLook> = []

    /// 自检用：清掉读过的数据和「读不到」的记录（同 CollageFilmLUTs.resetForTesting）。
    static func resetForTesting() {
        lock.lock()
        cache.removeAll()
        missing.removeAll()
        lock.unlock()
    }

    /// 这个光谱色调的颗粒、晕光数据（<rawValue>.film.cube / .print.cube / .json）。读不到 = nil（两项都不做）。
    /// 读不到、或者负片 / 电影负片缺胶片曝光的放宽表时记一行日志，每款只记一次（同 CollageFilmLUTs.table）。
    static func extras(_ look: CollageLook) -> Extras? {
        guard look.isSpectral else { return nil }
        lock.lock()
        if let hit = cache[look] {
            lock.unlock()
            return hit
        }
        if missing.contains(look) {
            lock.unlock()
            return nil
        }
        lock.unlock()
        // 读一款要解析四张表、十几万行文本（几十毫秒）：不拿着锁读。以前读的时候整把锁占着，暗房悬停到一款新胶片，
        // 后台渲大预览在读它，主线程上右栏问「这款能不能调胶片曝光」（supportsExposure）也得等这把锁，界面卡一下。
        // 两个线程同时读同一款就各读一遍（读出来一样），先放进去的那份留着。
        let dir = CollageFilmLUTs.directory
        let loaded = dir.flatMap { load(look, from: $0) }
        lock.lock()
        if let hit = cache[look] {
            lock.unlock()
            return hit
        }
        var first = false
        if let loaded {
            cache[look] = loaded
        } else {
            first = missing.insert(look).inserted
        }
        lock.unlock()
        let name = "光谱色调「\(look.label)」（\(look.rawValue)）"
        if first {
            let files = [".film.cube", ".print.cube", ".json"].map { look.rawValue + $0 }
            AppLog.warning("film", name + "的颗粒、晕光、冲印区数据没读到，这三样不起作用（色调表照常）："
                           + CollageFilmLUTs.missingReason(files, in: dir))
        } else if let loaded, loaded.ext == nil, !look.isReversal {
            // 读到了、只缺放宽表（负片、电影负片才有）：胶片曝光不起作用。进缓存的只有这一次，不会重复记。
            let files = [".film_e.cube", ".print_e.cube", ".json"].map { look.rawValue + $0 }
            AppLog.warning("film", name + "的胶片曝光放宽表没读到，胶片曝光不起作用（.json 里没有 develop.ext_head 也算）："
                           + CollageFilmLUTs.missingReason(files, in: dir))
        }
        return loaded
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
        let dev = meta.develop
        var ext: Ext?
        if let head = dev?.ext_head, head > 1, let lo = dev?.e_lo, let hi = dev?.e_hi, lo.count == 3, hi.count == 3,
           zip(lo, hi).allSatisfy({ $1 > $0 }), let fe = table(".film_e.cube"), let pe = table(".print_e.cube"),
           fe.size == pe.size {
            ext = Ext(film: fe, print: pe, filmCube: rgba(fe), printCube: rgba(pe), head: head,
                      compensation: min(1, max(0, dev?.exposure_compensation ?? 0.5)), lo: lo, hi: hi)
        }
        let splitLo = meta.d_lo?.count == 3 ? meta.d_lo! : [0, 0, 0]
        let splitHi = meta.d_hi?.count == 3 && zip(splitLo, meta.d_hi!).allSatisfy({ $1 > $0 }) ? meta.d_hi! : [1, 1, 1]
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
                      halationBounces: max(1, min(6, meta.halation.bounces)), halationDecay: meta.halation.bounce_decay,
                      defaultGrain: unit(meta.defaults?.grain), defaultHalation: unit(meta.defaults?.halation),
                      splitLo: splitLo, splitHi: splitHi,
                      warmthCCMax: max(0, dev?.warmth_cc_max ?? 0), warmthMRatio: max(0, dev?.warmth_m_ratio ?? 0),
                      ext: ext, positive: look.isReversal)
    }

    private static func unit(_ v: Double?) -> Double {
        guard let v, v.isFinite else { return 0 }
        return min(1, max(0, v))
    }

    /// 套用这个光谱色调时颗粒 / 晕光的起始值；不是光谱色调、读不到数据 = nil。
    static func defaults(_ look: CollageLook) -> (grain: Double, halation: Double)? {
        guard let fx = extras(look) else { return nil }
        return (fx.defaultGrain, fx.defaultHalation)
    }

    /// 这款能不能调胶片曝光（负片、电影负片有放宽表；反转片没有冲扫补偿这一层，过曝就是发白）。
    static func supportsExposure(_ look: CollageLook) -> Bool { extras(look)?.ext != nil }

    /// 冲印区 → 密度上的偏移（见 Develop）。曝光 ≠ 0 而这款没有放宽表（反转片）：只当冷暖。
    static func develop(_ fx: Extras, _ p: Printing) -> Develop {
        // 滑杆 + = 暖 = 黄、品滤色都少加（物理单位：1 CC = 0.01 密度，CMY 的顺序同 cmy_film）。反转片反过来：
        // 黄、品密度加上去，挡掉蓝、绿光，画面才往暖走。
        let cc = (fx.positive ? 1 : -1) * p.warmth * fx.warmthCCMax
        let filter = [0, cc * fx.warmthMRatio / 100, cc / 100]
        let split = (0..<3).map { fx.splitHi[$0] - fx.splitLo[$0] }
        if p.exposure != 0, let e = fx.ext {
            let range = (0..<3).map { e.hi[$0] - e.lo[$0] }
            func density(_ lin: Double) -> [Double] {
                let u = encode(min(1, lin / e.head))
                let v = CollageFilmLUTs.sample(e.film, u, u, u)
                return [decode(v.0), decode(v.1), decode(v.2)]
            }
            // 中灰（线性 0.184）的密度位移，冲扫店补回 compensation 那么多。
            let d0 = density(0.184)
            let d1 = density(0.184 * pow(2, p.exposure))
            return Develop(ext: true, inputScale: pow(2, p.exposure) / e.head,
                           bias: (0..<3).map { -e.compensation * (d1[$0] - d0[$0]) + filter[$0] / range[$0] },
                           sigmaA: (0..<3).map { range[$0] / split[$0] },
                           sigmaB: (0..<3).map { (e.lo[$0] - fx.splitLo[$0]) / split[$0] },
                           sigmaC: (0..<3).map { split[$0] / range[$0] })
        }
        return Develop(ext: false, inputScale: 1, bias: (0..<3).map { filter[$0] / split[$0] },
                       sigmaA: [1, 1, 1], sigmaB: [0, 0, 0], sigmaC: [1, 1, 1])
    }

    /// 光谱色调的一个颜色加上冲印区（sRGB 伽马值进出）：底色表 + [print(d₁) − print(d₀)]，d₀ = 原来的密度、
    /// d₁ = 曝光后的密度 + 偏移（同颗粒：只用两半表的差，底色还是一步到位那张表）。冲印区不动 = 底色表原样。
    static func developed(_ look: CollageLook, _ r: Double, _ g: Double, _ b: Double,
                          printing: Printing) -> (Double, Double, Double) {
        Developer(look, printing: printing).apply(r, g, b)
    }

    /// developed 拆成两半：表、Develop 先备好一次，apply 再一个颜色一个颜色算。色调表（CollageLooks.cube）32³ 个格点
    /// 都是同一个色调、同一组冲印区：以前每个格点都重新查一遍表（两把锁）、重推一遍 develop（中灰过两次 film 表、
    /// 两次 pow），再分配四个小数组，一张表 3 万多遍 —— 拖胶片曝光、冷暖每换一档要 26 ms（release）。
    /// apply 和原来一步步一样（同样的运算、同样的先后），逐位相同（--film-looks-selftest 拿逐点 grade 的表核对，
    /// 门禁拿渲染出来的图和改之前逐像素比）。
    struct Developer {
        /// 一步到位那张底色表（读不到 = 原样）。
        let table: CollageFilmLUTs.Table?
        /// 冲印区用的 film / print 两半表（胶片曝光 ≠ 0 时是放宽表）；冲印区不起作用（不是光谱色调、冲印区不动、
        /// 读不到颗粒数据、偏移全是 0）= nil，只走底色表。
        private let film: CollageFilmLUTs.Table?
        private let print: CollageFilmLUTs.Table?
        /// 放宽表：线性光 ÷ head 进 film 表；nil = 普通两半表（sRGB 直接进）。
        private let head: Double?
        private let inputScale: Double
        private let bias: (Double, Double, Double)

        init(_ look: CollageLook, printing: Printing) {
            table = CollageFilmLUTs.table(look)
            var film: CollageFilmLUTs.Table?, print: CollageFilmLUTs.Table?, head: Double?
            var inputScale = 1.0, bias = (0.0, 0.0, 0.0)
            if !printing.isNeutral, let fx = extras(look) {
                let dv = develop(fx, printing)
                if !dv.isIdentity {
                    let ext = dv.ext ? fx.ext : nil
                    film = ext?.film ?? fx.film
                    print = ext?.print ?? fx.print
                    head = ext?.head
                    inputScale = dv.inputScale
                    bias = (dv.bias[0], dv.bias[1], dv.bias[2])
                }
            }
            self.film = film
            self.print = print
            self.head = head
            self.inputScale = inputScale
            self.bias = bias
        }

        /// 借出来的表的内存和冲印区的几个数（只在 withMemory 的闭包里有效）：格点上只碰它，不碰带数组的 Developer。
        struct Memory {
            let table: UnsafeBufferPointer<Float>?
            let tableSize: Int
            let film: UnsafeBufferPointer<Float>?
            let filmSize: Int
            let print: UnsafeBufferPointer<Float>?
            let printSize: Int
            let head: Double?
            let inputScale: Double
            let bias: (Double, Double, Double)
        }

        /// 表的内存借出来一次，整张色调表的格点都在里面算：几个线程一起算时不在每个格点上动共享数组的引用计数。
        func withMemory<R>(_ body: (Memory) -> R) -> R {
            func lend(_ t: CollageFilmLUTs.Table?, _ next: (UnsafeBufferPointer<Float>?) -> R) -> R {
                guard let t else { return next(nil) }
                return t.rgb.withUnsafeBufferPointer { next($0) }
            }
            return lend(table) { tb in
                lend(film) { fb in
                    lend(print) { pb in
                        body(Memory(table: tb, tableSize: table?.size ?? 0, film: fb, filmSize: film?.size ?? 0,
                                    print: pb, printSize: print?.size ?? 0, head: head, inputScale: inputScale,
                                    bias: bias))
                    }
                }
            }
        }

        func apply(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            withMemory { Self.apply(r, g, b, $0) }
        }

        static func apply(_ r: Double, _ g: Double, _ b: Double, _ m: Memory) -> (Double, Double, Double) {
            let base = m.table.map { CollageFilmLUTs.sample($0, size: m.tableSize, r, g, b) } ?? (r, g, b)
            guard let film = m.film, let print = m.print else { return base }
            var in0 = (r, g, b)
            var in1 = (r, g, b)
            if let head = m.head {
                let lin = (decode(r), decode(g), decode(b))
                in0 = (encode(min(1, lin.0 / head)), encode(min(1, lin.1 / head)), encode(min(1, lin.2 / head)))
                in1 = (encode(min(1, lin.0 * m.inputScale)), encode(min(1, lin.1 * m.inputScale)),
                       encode(min(1, lin.2 * m.inputScale)))
            }
            let f0 = CollageFilmLUTs.sample(film, size: m.filmSize, in0.0, in0.1, in0.2)
            let f1 = CollageFilmLUTs.sample(film, size: m.filmSize, in1.0, in1.1, in1.2)
            let p0 = CollageFilmLUTs.sample(print, size: m.printSize, decode(f0.0), decode(f0.1), decode(f0.2))
            let p1 = CollageFilmLUTs.sample(print, size: m.printSize, decode(f1.0) + m.bias.0, decode(f1.1) + m.bias.1,
                                            decode(f1.2) + m.bias.2)
            func out(_ base: Double, _ a: Double, _ b: Double) -> Double {
                encode(min(1, max(0, decode(base) + b - a)))
            }
            return (out(base.0, p0.0, p1.0), out(base.1, p0.1, p1.1), out(base.2, p0.2, p1.2))
        }
    }

    static func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((max(0, v) + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Double) -> Double {
        let c = min(1, max(0, v))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// 工程里有没有哪一级（整组 / 页 / 格）用着光谱色调。
    static func usesSpectral(_ p: CollageProject) -> Bool {
        if p.style.look.isSpectral { return true }
        return p.pages.contains { page in
            page.look?.look.isSpectral == true
                || page.root.leafPaths().contains { page.root.node(at: $0)?.cell?.look?.look.isSpectral == true }
        }
    }

    /// 工程里哪一级（整组 / 页 / 格）用着的光谱色调。
    static func spectralLooks(_ p: CollageProject) -> Set<CollageLook> {
        var out: Set<CollageLook> = []
        if p.style.look.isSpectral { out.insert(p.style.look) }
        for page in p.pages {
            if let look = page.look?.look, look.isSpectral { out.insert(look) }
            for path in page.root.leafPaths() {
                if let look = page.root.node(at: path)?.cell?.look?.look, look.isSpectral { out.insert(look) }
            }
        }
        return out
    }

    /// 整组的颗粒、晕光、冷暖、画幅（texture）和胶片曝光（exposure）起不起作用 —— 检视器、暗房灰不灰掉这几根滑杆
    /// 用同一个口径：它们都记在整组上（CollageStyle），哪一级用着光谱色调就作用到哪一级（相册某几页、某几格单独套
    /// 光谱色调，整组是滤镜，颗粒照样加在那几页上）。以前检视器只看整组的色调，这种时候颗粒带着却关不掉；暗房只看
    /// 「套用到」那一级。胶片曝光要用着的光谱色调里有一款能调（负片、电影负片；反转片没有）。
    struct FilmControls {
        /// 颗粒、晕光、冷暖、画幅：用着任何一款光谱色调。
        let texture: Bool
        /// 胶片曝光：用着的里有一款能调。
        let exposure: Bool
        /// 用着的全是反转片（胶片曝光灰掉是因为这个，不是数据没读到）。
        let reversalOnly: Bool
    }

    static func filmControls(_ p: CollageProject) -> FilmControls {
        let looks = spectralLooks(p)
        return FilmControls(texture: !looks.isEmpty, exposure: looks.contains(where: supportsExposure),
                            reversalOnly: !looks.isEmpty && looks.allSatisfy(\.isReversal))
    }

    /// 从「没有光谱色调」换进光谱色调（哪一级都算）、颗粒晕光都还是 0：颗粒 / 晕光设成这一款的起始值（R8：整张看就
    /// 隐约看得见颗粒是胶片味最强的信号之一，以前默认 0，换上去看不出是胶片）。store 套用和暗房的悬停预览都走这里，
    /// 看到的就是点下去的。已经在用光谱色调时不动：颗粒拉回 0 以后在光谱色调之间换来换去不会再加回来。
    static func adoptDefaults(before: CollageProject, into after: inout CollageProject, look: CollageLook?) {
        guard let look, look.isSpectral, after.style.filmGrain == 0, after.style.filmHalation == 0,
              !usesSpectral(before), let d = defaults(look) else { return }
        after.style.filmGrain = d.grain
        after.style.filmHalation = d.halation
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
        // 画幅：底片越大，同一张照片的像素对应的底片越大，颗粒相对画面越细、晕光越窄。
        let pixelUM = (ops.formatMM ?? fx.filmFormatMM) * 1000 / frameLongEdge
        var lin = CollageLooks.applyGains(image, ops: ops)
        if ops.halation > 0.001 {
            lin = halate(lin, fx: fx, pixelUM: pixelUM, amount: ops.halation, extent: extent)
        }
        let base = CollageLooks.applyCube(lin, ops: ops)
        guard ops.grain > 0.001,
              let (p1, p2) = grainPrints(lin, fx: fx, pixelUM: pixelUM, amount: ops.grain, seed: seed, extent: extent,
                                         develop: develop(fx, ops.printing))
        else { return base }
        // base + s·(p2 − p1)。
        let s = ops.strength
        return add(scale(p1, -s, -s, -s), onto: add(scale(p2, s, s, s), onto: base, extent: extent), extent: extent)
    }

    /// 片基反射的晕光，线性光进、线性光出。
    static func halate(_ lin: CIImage, fx: Extras, pixelUM: Double, amount: Double, extent: CGRect) -> CIImage {
        let s = min(1, max(0, amount))
        let a = fx.halationStrengthMax.map { $0 * s * s }
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

    /// 颗粒：print(d)、print(d + δ) 两张（线性光）；颗粒 = 两张之差（均值约 0）。冲印区不动时 d = film(线性光)；
    /// 动了：d = 曝光后的密度 + 偏移（develop，和 CPU 取色同一套），底色那边的冲印区已经烘进色调表了。
    /// σ 按胶片实际的密度（曝光后、补回之前）查：补回中灰是印放那一步的事，不改底片上的颗粒。
    static func grainPrints(_ lin: CIImage, fx: Extras, pixelUM: Double, amount: Double, seed: String,
                            extent: CGRect, develop dv: Develop) -> (CIImage, CIImage)? {
        let ext = dv.ext ? fx.ext : nil
        let input = dv.inputScale == 1 ? lin : scale(lin, dv.inputScale, dv.inputScale, dv.inputScale)
        guard let film = cube(input, ext?.filmCube ?? fx.filmCube, fx.size, colorSpace: CollageRender.srgb)
        else { return nil }
        // film 表按 sRGB 编码存的归一化密度：CIColorCubeWithColorSpace 出来回到线性工作空间，正好是归一化密度。
        let k = 2 * min(1, max(0, amount)) / pixelUM
        let sigmaIn = ext == nil ? film : scale(film, dv.sigmaA[0], dv.sigmaA[1], dv.sigmaA[2], biases: dv.sigmaB)
        guard let sigmaRaw = cube(sigmaIn, fx.sigmaCube, fx.size, colorSpace: nil) else { return nil }
        let sigma = scale(sigmaRaw, k * dv.sigmaC[0], k * dv.sigmaC[1], k * dv.sigmaC[2])
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
        let developed = dv.bias.allSatisfy({ $0 == 0 }) ? film : scale(film, 1, 1, 1, biases: dv.bias)
        let shifted = add(delta, onto: developed, extent: extent)
        let printCube = ext?.printCube ?? fx.printCube
        guard let p1 = cube(developed, printCube, fx.size, colorSpace: nil),
              let p2 = cube(shifted, printCube, fx.size, colorSpace: nil) else { return nil }
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
    private static func scale(_ image: CIImage, _ r: Double, _ g: Double, _ b: Double, bias: Double = 0,
                              biases: [Double]? = nil) -> CIImage {
        guard let m = CIFilter(name: "CIColorMatrix") else { return image }
        m.setValue(image, forKey: kCIInputImageKey)
        m.setValue(CIVector(x: CGFloat(r), y: 0, z: 0, w: 0), forKey: "inputRVector")
        m.setValue(CIVector(x: 0, y: CGFloat(g), z: 0, w: 0), forKey: "inputGVector")
        m.setValue(CIVector(x: 0, y: 0, z: CGFloat(b), w: 0), forKey: "inputBVector")
        let v = biases ?? [bias, bias, bias]
        m.setValue(CIVector(x: CGFloat(v[0]), y: CGFloat(v[1]), z: CGFloat(v[2]), w: 0), forKey: "inputBiasVector")
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
