import Foundation
import CoreGraphics
import CoreImage

/// LABELGUI_DATA_DIR=<临时> LabelGUI --film-looks-selftest
///
/// 光谱胶片色调（CollageFilmLUTs，spektrafilm 烘的表）的自测，不要照片：
/// 1. 表都在：每个光谱色调读得到 32³ 的表（.app 里是 Resources/film-luts，裸二进制往上找 third_party/film-luts），
///    值都在 0…1；目录里还有 SPEKTRAFILM_LICENSE.txt、CHANGELOG.txt（CC BY-SA 的署名和改动说明）；每张 .cube
///    文件头写着署名和许可。
/// 2. 名字：中文名不超过 4 个字（色块下面放得下）、和别的色调不重名；中文名、rawValue 里没有胶片品牌。
/// 3. 取样：格点上 map() 就是表里的值；灰阶从黑到白亮度不往回走（反转片印到相纸上会整条反过来，这条能抓到）；
///    强度 1 的 cube 确实不是原样，强度 0 的 grade() 是原样。
/// 4. 读坏的表：格点数不对、有非数字、空文件都是 nil；空目录里读不到；读不到时 map() 原样返回。
/// 5. 渲染：一块纯色走 CollageLooks.apply（CIColorCubeWithColorSpace，sRGB）出来的颜色和 CPU 上 grade() 算的差 ≤ 3/255
///    —— 预览、导出（GPU）和主图取色、压字判深浅（CPU）用的是同一个颜色。
/// 6. 存档：新色调存进 CollageLookSetting 再读回来不变。
/// 7. 颗粒、晕光（CollageFilmEffects）：每个光谱色调的 film / print 表和 .json 都读得到；两项都是 0 时和
///    CollageLooks.apply 逐字节一样；一块灰上开颗粒，均值不动（≤ 0.004 线性）、每个通道的标准差和 CPU 按
///    print 表斜率 × σ(密度) / 像素边长 × 0.65 像素模糊算的差 35% 以内，颗粒跟着像素尺寸变（像素小一半 → 颗粒
///    大约大一倍）；同一张照片渲两次逐字节一样、换一张照片噪声不一样；灰底白圆开晕光，圆外的红抬得比绿多、
///    绿比蓝多，晕光 0 时原样；CollageStyle 里的颗粒、晕光存了读回来不变，旧 JSON 没有这两项是 0、坏值收到 0…1。
/// 全过退出 0，否则 1。
enum CollageFilmLooksSelfTest {

    static func run() -> Never {
        CollageCLI.requireIsolatedDataDir("--film-looks-selftest")
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }
        let spectral = CollageLook.allCases.filter(\.isSpectral)
        let fm = FileManager.default

        // ---------------------------------------------------------------- 1. 表都在
        print("== 表")
        check(spectral.count == 15, "15 个光谱色调", "\(spectral.count) 个")
        let dir = CollageFilmLUTs.directory
        check(dir != nil, "找得到放表的目录", dir?.path ?? "nil")
        if let dir {
            check(fm.fileExists(atPath: dir.appendingPathComponent("SPEKTRAFILM_LICENSE.txt").path), "目录里有 SPEKTRAFILM_LICENSE.txt")
            check(fm.fileExists(atPath: dir.appendingPathComponent("CHANGELOG.txt").path), "目录里有 CHANGELOG.txt")
        }
        for look in spectral {
            guard let t = CollageFilmLUTs.table(look) else {
                check(false, "\(look.rawValue) 读得到表")
                continue
            }
            check(t.size == CollageLooks.cubeSize, "\(look.rawValue) 是 \(CollageLooks.cubeSize)³", "\(t.size)³")
            check(t.rgb.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(look.rawValue) 值都在 0…1")
            if let dir, let text = try? String(contentsOf: dir.appendingPathComponent(look.rawValue + ".cube"), encoding: .utf8) {
                let head = text.split(separator: "\n").prefix(8).joined(separator: "\n")
                check(head.contains("Andrea Volpato") && head.contains("CC BY-SA 4.0") && head.contains("github.com/andreavolpato/spektrafilm"),
                      "\(look.rawValue).cube 文件头有署名和许可")
            }
        }
        for look in CollageLook.allCases where !look.isSpectral {
            check(CollageFilmLUTs.table(look) == nil, "\(look.rawValue) 不是光谱色调、没有表")
        }

        // ---------------------------------------------------------------- 2. 名字
        print("== 名字")
        let brands = ["KODAK", "FUJI", "ILFORD", "PORTRA", "EKTAR", "GOLD", "VELVIA", "PROVIA", "EKTACHROME",
                      "KODACHROME", "VISION", "SUPERIA", "CINESTILL", "AGFA", "柯达", "富士", "伊尔福"]
        let labels = CollageLook.allCases.map(\.label)
        for look in spectral {
            check(look.label.count <= 4, "「\(look.label)」不超过 4 个字")
            check(labels.filter { $0 == look.label }.count == 1, "「\(look.label)」不和别的色调重名")
            let text = (look.label + " " + look.rawValue).uppercased()
            let hit = brands.filter { text.contains($0) }
            check(hit.isEmpty, "\(look.rawValue)「\(look.label)」不含胶片品牌", hit.joined(separator: " "))
            // 片名只进「参考」那一行（用户 2026-11-05 定的），每款光谱色调都有，写的是品牌 + 片名。
            let stock = look.referenceStock ?? ""
            check(brands.contains(where: { stock.uppercased().contains($0) }), "\(look.rawValue) 有参考片名", stock)
        }
        check(CollageLook.allCases.filter { !$0.isSpectral }.allSatisfy { $0.referenceStock == nil },
              "普通滤镜没有参考片名")

        // ---------------------------------------------------------------- 3. 取样
        print("== 取样")
        for look in spectral {
            guard let t = CollageFilmLUTs.table(look) else { continue }
            let n = t.size
            var worst = 0.0
            for (ri, gi, bi) in [(0, 0, 0), (n - 1, n - 1, n - 1), (5, 17, 29), (n - 1, 0, 0), (12, 12, 12)] {
                let v = CollageFilmLUTs.map(look, Double(ri) / Double(n - 1), Double(gi) / Double(n - 1), Double(bi) / Double(n - 1))
                let k = ((bi * n + gi) * n + ri) * 3
                worst = max(worst, abs(v.0 - Double(t.rgb[k])), abs(v.1 - Double(t.rgb[k + 1])), abs(v.2 - Double(t.rgb[k + 2])))
            }
            check(worst < 1e-5, "\(look.rawValue) 格点上 map() = 表", String(format: "最大差 %.2g", worst))
            var prev = -1.0
            var backwards = 0.0
            for i in 0...64 {
                let x = Double(i) / 64
                let v = CollageFilmLUTs.map(look, x, x, x)
                let y = 0.2126 * v.0 + 0.7152 * v.1 + 0.0722 * v.2
                backwards = max(backwards, prev - y)
                prev = max(prev, y)
            }
            check(backwards < 0.002, "\(look.rawValue) 灰阶亮度从黑到白不往回走", String(format: "最多回落 %.4f", backwards))
            let black = CollageFilmLUTs.map(look, 0, 0, 0)
            let white = CollageFilmLUTs.map(look, 1, 1, 1)
            // 第二版的表按「柯达 400」的扫描抬了黑位（淡雅到 L*≈14 ≈ sRGB 0.15）、白提到 L*≥93：这条只防表坏掉 / 反了。
            check(max(black.0, black.1, black.2) < 0.2 && min(white.0, white.1, white.2) > 0.85,
                  "\(look.rawValue) 黑是暗的、白是亮的",
                  String(format: "黑 %.3f 白 %.3f", max(black.0, black.1, black.2), min(white.0, white.1, white.2)))
            if let cube = CollageLooks.cube(look, strength: 1) {
                let f = cube.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var diff = 0.0
                for i in 0..<(n * n * n) {
                    let ri = i % n, gi = (i / n) % n, bi = i / (n * n)
                    diff += abs(Double(f[i * 4]) - Double(ri) / Double(n - 1))
                        + abs(Double(f[i * 4 + 1]) - Double(gi) / Double(n - 1))
                        + abs(Double(f[i * 4 + 2]) - Double(bi) / Double(n - 1))
                }
                diff /= Double(n * n * n * 3)
                check(diff > 0.01, "\(look.rawValue) 强度 1 不是原样", String(format: "平均差 %.3f", diff))
            } else {
                check(false, "\(look.rawValue) 生成得出 cube")
            }
            let g0 = CollageLooks.grade(0.3, 0.5, 0.7, look: look, strength: 0)
            check(abs(g0.0 - 0.3) + abs(g0.1 - 0.5) + abs(g0.2 - 0.7) < 1e-9, "\(look.rawValue) 强度 0 是原样")
        }

        // ---------------------------------------------------------------- 4. 读坏的表
        print("== 读坏的表")
        let good = "TITLE \"x\"\n# c\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
            + (0..<8).map { i in "\(Double(i % 2)) \(Double((i / 2) % 2)) \(Double(i / 4))" }.joined(separator: "\n") + "\n"
        let parsed = CollageFilmLUTs.parse(good)
        check(parsed?.size == 2 && parsed?.rgb.count == 24, "2³ 的身份表读得出来")
        if let parsed {
            let v = CollageFilmLUTs.sample(parsed, 0.25, 0.5, 0.75)
            check(abs(v.0 - 0.25) + abs(v.1 - 0.5) + abs(v.2 - 0.75) < 1e-6, "身份表取样还是原值")
        }
        check(CollageFilmLUTs.parse("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n") == nil, "格点数不够 = nil")
        check(CollageFilmLUTs.parse(good.replacingOccurrences(of: "1.0 1.0 1.0", with: "1.0 nan 1.0")) == nil, "有非数字 = nil")
        check(CollageFilmLUTs.parse("") == nil, "空文件 = nil")
        let empty = fm.temporaryDirectory.appendingPathComponent("film-looks-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        check(CollageFilmLUTs.load(.filmWarmSkin, from: empty) == nil, "空目录里读不到")
        try? fm.removeItem(at: empty)

        // ---------------------------------------------------------------- 5. 渲染
        print("== 渲染（GPU 和 CPU 同色）")
        let samples: [(Double, Double, Double)] = [(0.82, 0.62, 0.52), (0.25, 0.45, 0.7), (0.5, 0.5, 0.5), (0.12, 0.1, 0.08)]
        for look in spectral {
            var worst = 0.0
            for c in samples {
                guard let got = renderSolid(c, look: look) else { worst = 1; break }
                let want = CollageLooks.grade(c.0, c.1, c.2, look: look, strength: 0.8)
                worst = max(worst, abs(got.0 - want.0), abs(got.1 - want.1), abs(got.2 - want.2))
            }
            check(worst <= 3.0 / 255, "\(look.rawValue) 渲染出来和 grade() 一样", String(format: "最大差 %.1f/255", worst * 255))
        }

        // ---------------------------------------------------------------- 6. 存档
        print("== 存档")
        for look in spectral {
            let s = CollageLookSetting(look: look, strength: 0.65)
            let back = (try? JSONEncoder().encode(s)).flatMap { try? JSONDecoder().decode(CollageLookSetting.self, from: $0) }
            check(back?.look == look && abs((back?.strength ?? 0) - 0.65) < 1e-9, "\(look.rawValue) 存了读回来不变")
        }

        // ---------------------------------------------------------------- 7. 颗粒、晕光
        print("== 颗粒、晕光")
        for look in spectral {
            guard let fx = CollageFilmEffects.extras(look) else {
                check(false, "\(look.rawValue) 读得到 film / print 表和 .json")
                continue
            }
            check(fx.film.size == fx.size && fx.print.size == fx.size && fx.sigmaUnit.count == 3,
                  "\(look.rawValue) film / print 表 \(fx.size)³、σ 三个通道")
            check(fx.halationSigmaUM == 50 || fx.halationSigmaUM == 65, "\(look.rawValue) 晕光 σ 是片基给的 50 / 65 µm",
                  "\(fx.halationSigmaUM)")
            check((0.1...0.8).contains(fx.defaultGrain) && (0...0.6).contains(fx.defaultHalation),
                  "\(look.rawValue) 有颗粒 / 晕光的起始值", String(format: "颗粒 %.2f 晕光 %.2f", fx.defaultGrain, fx.defaultHalation))
        }
        grainAndHalation(check)
        styleCoding(check)
        filmDefaults(check)
        printingChecks(check)

        print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    private static let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!

    /// 渲成线性光的 Float RGBA。
    private static func readLinear(_ image: CIImage, _ rect: CGRect) -> [Float] {
        let w = Int(rect.width), h = Int(rect.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        CollageRender.ciContext.render(image, toBitmap: &buf, rowBytes: w * 16, bounds: rect, format: .RGBAf,
                                       colorSpace: linear)
        return buf
    }

    private static func stats(_ px: [Float], _ c: Int) -> (mean: Double, std: Double) {
        let n = px.count / 4
        var m = 0.0
        for i in 0..<n { m += Double(px[i * 4 + c]) }
        m /= Double(n)
        var v = 0.0
        for i in 0..<n { let d = Double(px[i * 4 + c]) - m; v += d * d }
        return (m, (v / Double(n)).squareRoot())
    }

    private static func grainAndHalation(_ check: (Bool, String, String) -> Void) {
        let look = CollageLook.filmWarmSkin
        guard let fx = CollageFilmEffects.extras(look),
              let grayColor = CIColor(red: 0.5, green: 0.45, blue: 0.4, alpha: 1, colorSpace: CollageRender.srgb)
        else { check(false, "颗粒自检的准备", ""); return }
        let rect = CGRect(x: 0, y: 0, width: 192, height: 192)
        let gray = CIImage(color: grayColor).cropped(to: rect)
        var ops = CollageLooks.Ops(gains: nil, look: look, strength: 1)
        let base = readLinear(CollageLooks.apply(gray, ops: ops), rect)
        let off = readLinear(CollageFilmEffects.apply(gray, ops: ops, frameLongEdge: 2000, seed: "a", extent: rect), rect)
        check(base == off, "颗粒、晕光都是 0：和 CollageLooks.apply 逐字节一样", "")

        // 灰块开颗粒 0.5，照片长边 2000 像素（像素 17.5 µm）。
        ops.grain = 0.5
        let long = 2000.0
        let grained = readLinear(CollageFilmEffects.apply(gray, ops: ops, frameLongEdge: long, seed: "a", extent: rect), rect)
        // CPU 预测：输入 → film 表（归一化密度）→ print 表在这一点的斜率 J；δ 的标准差 = σ(d) × 2·颗粒 / 像素边长 ×
        // 0.65 像素高斯模糊对白噪声的衰减（离散核平方和开方）。
        let pixelUM = fx.filmFormatMM * 1000 / long
        let enc = CollageFilmLUTs.sample(fx.film, 0.5, 0.45, 0.4)
        func dec(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let d = [dec(enc.0), dec(enc.1), dec(enc.2)]
        func sigmaAt(_ c: Int) -> Double {
            let s = fx.sigmaUnit[c]
            let x = min(1, max(0, d[c])) * Double(s.count - 1)
            let i = min(Int(x), s.count - 2)
            return s[i] + (s[i + 1] - s[i]) * (x - Double(i))
        }
        var kernel: [Double] = (-4...4).map { exp(-Double($0 * $0) / (2 * fx.grainBlurPx * fx.grainBlurPx)) }
        let ks = kernel.reduce(0, +)
        kernel = kernel.map { $0 / ks }
        let blur1D = kernel.map { $0 * $0 }.reduce(0, +)
        let atten = blur1D  // 二维可分离：方差衰减 = (Σw²)²，标准差衰减 = Σw²
        let hstep = 0.02
        func printAt(_ v: [Double]) -> [Double] {
            let o = CollageFilmLUTs.sample(fx.print, v[0], v[1], v[2])
            return [o.0, o.1, o.2]
        }
        var jac = [[Double]](repeating: [0, 0, 0], count: 3)
        for k in 0..<3 {
            var up = d, dn = d
            up[k] += hstep
            dn[k] -= hstep
            let pu = printAt(up), pd = printAt(dn)
            for c in 0..<3 { jac[c][k] = (pu[c] - pd[c]) / (2 * hstep) }
        }
        let sd = (0..<3).map { sigmaAt($0) * 2 * ops.grain / pixelUM * atten }
        for c in 0..<3 {
            let predicted = (0..<3).map { jac[c][$0] * sd[$0] }.map { $0 * $0 }.reduce(0, +).squareRoot()
            let b = stats(base, c), g = stats(grained, c)
            let name = ["R", "G", "B"][c]
            check(abs(g.mean - b.mean) <= 0.004, "颗粒 0.5：\(name) 均值不动",
                  String(format: "%.4f → %.4f", b.mean, g.mean))
            check(predicted > 0 && abs(g.std / predicted - 1) <= 0.35, "颗粒 0.5：\(name) 标准差和 spektrafilm 模型对得上",
                  String(format: "实测 %.4f 预测 %.4f", g.std, predicted))
        }
        // 亮的饱和色（蓝天）上开颗粒，均值也不动：中间有一步超过 1 被夹掉的话，这里会整片偏色。
        if let skyColor = CIColor(red: 0.55, green: 0.78, blue: 0.95, alpha: 1, colorSpace: CollageRender.srgb) {
            let sky = CIImage(color: skyColor).cropped(to: rect)
            let skyBase = readLinear(CollageLooks.apply(sky, ops: CollageLooks.Ops(gains: nil, look: look, strength: 1)), rect)
            let skyGrain = readLinear(CollageFilmEffects.apply(sky, ops: ops, frameLongEdge: long, seed: "a", extent: rect), rect)
            let shift = (0..<3).map { abs(stats(skyGrain, $0).mean - stats(skyBase, $0).mean) }.max() ?? 1
            check(shift <= 0.006, "蓝天上开颗粒：均值不动（没有哪一步被夹到 0…1）", String(format: "最大偏 %.4f", shift))
        }
        // 像素小一半（长边 4000）：颗粒大约大一倍。
        let fine = readLinear(CollageFilmEffects.apply(gray, ops: ops, frameLongEdge: 4000, seed: "a", extent: rect), rect)
        let ratio = stats(fine, 1).std / max(1e-9, stats(grained, 1).std)
        check(ratio > 1.6 && ratio < 2.4, "照片长边 2000 → 4000：颗粒的标准差约翻倍", String(format: "%.2f 倍", ratio))
        let again = readLinear(CollageFilmEffects.apply(gray, ops: ops, frameLongEdge: long, seed: "a", extent: rect), rect)
        check(again == grained, "同一张照片渲两次逐字节一样", "")
        let other = readLinear(CollageFilmEffects.apply(gray, ops: ops, frameLongEdge: long, seed: "b", extent: rect), rect)
        check(other != grained, "换一张照片（id 不同）噪声不一样", "")
        var weak = ops
        weak.strength = 0.5
        let half = readLinear(CollageFilmEffects.apply(gray, ops: weak, frameLongEdge: long, seed: "a", extent: rect), rect)
        let halfBase = readLinear(CollageLooks.apply(gray, ops: weak), rect)
        check(abs(stats(half, 1).std - stats(halfBase, 1).std - 0.5 * (stats(grained, 1).std - stats(base, 1).std)) < 0.35 * stats(grained, 1).std,
              "色调强度 50%：颗粒也减半", String(format: "%.4f / %.4f", stats(half, 1).std, stats(grained, 1).std))

        // 灰底白圆，晕光 1：σ = 65 µm / 像素 ≈ 8 像素。用灰底不用黑底：黑那一段在胶片的趾部，抬上去的光被压得几乎
        // 看不出来（物理上就是这样），灰底上色调表的斜率接近 1。
        let disc = CGRect(x: 0, y: 0, width: 256, height: 256)
        guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CollageRender.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
        ctx.fill(disc)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 88, y: 88, width: 80, height: 80))
        guard let cg = ctx.makeImage() else { return }
        let src = CIImage(cgImage: cg)
        var hops = CollageLooks.Ops(gains: nil, look: look, strength: 1)
        let plain = readLinear(CollageFilmEffects.apply(src, ops: hops, frameLongEdge: 4300, seed: "a", extent: disc), disc)
        hops.halation = 1
        let glow = readLinear(CollageFilmEffects.apply(src, ops: hops, frameLongEdge: 4300, seed: "a", extent: disc), disc)
        let i = (128 * 256 + 128 + 50) * 4  // 圆心往右 50 像素：圆外 10 像素
        let rise = (0..<3).map { Double(glow[i + $0] - plain[i + $0]) }
        check(rise[0] > 0.01 && rise[0] > rise[1] && rise[1] >= rise[2] - 1e-4,
              "晕光 1：圆外泛红（红抬得最多、绿次之、蓝最少）", String(format: "R +%.4f G +%.4f B +%.4f", rise[0], rise[1], rise[2]))
        let center = (128 * 256 + 128) * 4
        let centerShift = (0..<3).map { abs(Double(glow[center + $0] - plain[center + $0])) }.max() ?? 1
        check(centerShift < 0.01, "晕光 1：白圆中间不变暗（光是往外散，不是整体压暗）", String(format: "最大差 %.4f", centerShift))
        let far = (128 * 256 + 2) * 4
        check(abs(glow[far] - plain[far]) < 0.004, "晕光只在高光附近：离圆远的灰基本不动",
              String(format: "%.4f", glow[far] - plain[far]))
        // 平方刻度：滑杆 50% 的晕光强度是 100% 的四分之一（再除以 1 + A 归一，比 0.25 稍大）。
        hops.halation = 0.5
        let halfGlow = readLinear(CollageFilmEffects.apply(src, ops: hops, frameLongEdge: 4300, seed: "a", extent: disc), disc)
        let halfRise = Double(halfGlow[i] - plain[i]) / max(1e-6, rise[0])
        check(halfRise > 0.18 && halfRise < 0.4, "晕光滑杆是平方刻度：50% ≈ 100% 的四分之一", String(format: "%.2f", halfRise))
        hops.halation = 0
        let none = readLinear(CollageFilmEffects.apply(src, ops: hops, frameLongEdge: 4300, seed: "a", extent: disc), disc)
        check(none == plain, "晕光 0：原样", "")
    }

    /// 换进光谱色调时颗粒 / 晕光的起始值（CollageFilmEffects.adoptDefaults，store 和暗房预览共用）。
    private static func filmDefaults(_ check: (Bool, String, String) -> Void) {
        guard let d = CollageFilmEffects.defaults(.filmSunny) else { check(false, "暖阳有起始值", ""); return }
        var plain = CollageProject()
        plain.style.look = .film
        plain.pages = [CollagePage(root: .leaf(.photo("a")))]
        var next = plain
        next.style.look = .filmSunny
        CollageFilmEffects.adoptDefaults(before: plain, into: &next, look: .filmSunny)
        check(next.style.filmGrain == d.grain && next.style.filmHalation == d.halation,
              "从普通滤镜换进光谱色调：带上这一款的颗粒 / 晕光起始值", String(format: "%.2f / %.2f", next.style.filmGrain, next.style.filmHalation))
        var again = next
        again.style.look = .filmWarmSkin
        again.style.filmGrain = 0
        again.style.filmHalation = 0
        CollageFilmEffects.adoptDefaults(before: next, into: &again, look: .filmWarmSkin)
        check(again.style.filmGrain == 0 && again.style.filmHalation == 0,
              "已经在用光谱色调（颗粒拉回 0 了）：换一款光谱色调不再加回来", "")
        var explicit = plain
        explicit.style.look = .filmSunny
        explicit.style.filmGrain = 0.2
        CollageFilmEffects.adoptDefaults(before: plain, into: &explicit, look: .filmSunny)
        check(explicit.style.filmGrain == 0.2 && explicit.style.filmHalation == 0, "已经给了颗粒：照给的来", "")
        var filter = plain
        filter.style.look = .mono
        CollageFilmEffects.adoptDefaults(before: plain, into: &filter, look: .mono)
        check(filter.style.filmGrain == 0, "换普通滤镜：不加颗粒", "")
        var pageLevel = plain
        pageLevel.pages[0].look = CollageLookSetting(look: .cineDay, strength: 1)
        CollageFilmEffects.adoptDefaults(before: plain, into: &pageLevel, look: .cineDay)
        check(pageLevel.style.filmGrain == CollageFilmEffects.defaults(.cineDay)?.grain,
              "只给一页设光谱色调：起始值记在整组上（颗粒晕光是整组的）", "")
        check(CollageFilmEffects.usesSpectral(pageLevel) && !CollageFilmEffects.usesSpectral(plain),
              "认得出哪一级在用光谱色调（整组 / 页 / 格）", "")
    }

    private static func styleCoding(_ check: (Bool, String, String) -> Void) {
        var style = CollageStyle()
        style.look = .cineDay
        style.filmGrain = 0.3
        style.filmHalation = 0.7
        let back = (try? JSONEncoder().encode(style)).flatMap { try? JSONDecoder().decode(CollageStyle.self, from: $0) }
        check(back?.filmGrain == 0.3 && back?.filmHalation == 0.7 && back?.look == .cineDay, "颗粒、晕光存了读回来不变", "")
        let old = try? JSONDecoder().decode(CollageStyle.self, from: Data(#"{"look":"film"}"#.utf8))
        check(old?.filmGrain == 0 && old?.filmHalation == 0, "旧 JSON 没有颗粒、晕光：都是 0", "")
        let bad = try? JSONDecoder().decode(CollageStyle.self, from: Data(#"{"filmGrain":7,"filmHalation":-2}"#.utf8))
        check(bad?.filmGrain == 1 && bad?.filmHalation == 0, "坏值收到 0…1", "")
    }

    /// sRGB 伽马值 → CIELAB（D65），自检量冷暖、明暗用。
    private static func lab(_ c: (Double, Double, Double)) -> (L: Double, a: Double, b: Double) {
        let r = CollageFilmEffects.decode(c.0), g = CollageFilmEffects.decode(c.1), b = CollageFilmEffects.decode(c.2)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.9505
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.089
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// 冲印区（胶片曝光、冷暖）：CollageFilmEffects.Printing / develop / developed。
    private static func printingChecks(_ check: (Bool, String, String) -> Void) {
        print("== 冲印区")
        typealias P = CollageFilmEffects.Printing
        let gray: [Double] = [0.15, 0.46, 0.85]
        func L(_ look: CollageLook, _ v: Double, _ p: P) -> (L: Double, a: Double, b: Double) {
            lab(CollageLooks.grade(v, v, v, look: look, strength: 1, printing: p))
        }
        // 都不动：和没有冲印区时一模一样（色调表同一张、取色同一个值）。
        let neutralSame = CollageLooks.cube(.filmWarmSkin, strength: 0.8, printing: P())
            == CollageLooks.cube(.filmWarmSkin, strength: 0.8)
        let mapSame = CollageFilmEffects.developed(.filmWarmSkin, 0.6, 0.45, 0.4, printing: P())
            == CollageFilmLUTs.map(.filmWarmSkin, 0.6, 0.45, 0.4)
        check(neutralSame && mapSame, "冲印区都是 0：色调表、取色和以前一样", "")
        check(P(exposure: 0.04, warmth: 0.02).isNeutral && P(exposure: 7).exposure == 2 && P(exposure: -3).exposure == -1,
              "量化到 0.1 档 / 5%、曝光收在 −1…+2", "")
        // +1 档（冲扫店补回一半）：中灰明显亮、暗部基本不动、高光亮一点（被肩部压住）。
        for look in [CollageLook.filmWarmSkin, .cineDay] {
            let base = gray.map { L(look, $0, P()) }
            let up = gray.map { L(look, $0, P(exposure: 1)) }
            let down = gray.map { L(look, $0, P(exposure: -1)) }
            let dMid = up[1].L - base[1].L, dSh = up[0].L - base[0].L, dHi = up[2].L - base[2].L
            check(dMid > 5 && dMid < 20 && abs(dSh) < 7 && dHi > -3 && dHi < dMid,
                  "\(look.rawValue) 胶片曝光 +1 档：中灰亮、暗部基本不动、高光被肩部压住",
                  String(format: "ΔL 暗 %+.1f 中 %+.1f 亮 %+.1f", dSh, dMid, dHi))
            check(down[1].L < base[1].L - 3, "\(look.rawValue) 胶片曝光 −1 档：中灰暗下去",
                  String(format: "ΔL 中 %+.1f", down[1].L - base[1].L))
        }
        check(CollageFilmEffects.supportsExposure(.filmWarmSkin) && !CollageFilmEffects.supportsExposure(.slideClean),
              "负片能调胶片曝光，反转片不能", "")
        let slideSame = CollageFilmEffects.developed(.slideClean, 0.5, 0.4, 0.3, printing: P(exposure: 1))
            == CollageFilmLUTs.map(.slideClean, 0.5, 0.4, 0.3)
        check(slideSame, "反转片上胶片曝光是空操作（旧工程、AI 给了值也一样）", "")
        // 冷暖：+ 暖（中灰 b* 升、a* 不往绿走），− 冷。
        for look in [CollageLook.filmWarmSkin, .filmAmber, .slideClean] {
            let base = L(look, 0.46, P()), warm = L(look, 0.46, P(warmth: 0.5)), cool = L(look, 0.46, P(warmth: -0.5))
            check(warm.b > base.b + 1 && warm.a > base.a - 0.3 && cool.b < base.b - 1,
                  "\(look.rawValue) 冷暖：暖往橙走（b* 升、a* 不往绿）、冷往蓝",
                  String(format: "暖 Δa %+.1f Δb %+.1f · 冷 Δb %+.1f", warm.a - base.a, warm.b - base.b, cool.b - base.b))
        }
        // GPU 和 CPU 同色（Δn、偏移两边推导得一样才过）。
        let samples: [(Double, Double, Double)] = [(0.82, 0.62, 0.52), (0.25, 0.45, 0.7), (0.5, 0.5, 0.5), (0.12, 0.1, 0.08)]
        for (look, p) in [(CollageLook.filmWarmSkin, P(exposure: 1, warmth: 0.5)), (.cineTungsten, P(exposure: -1, warmth: -0.5)),
                          (.slideCool, P(warmth: 0.5))] {
            var worst = 0.0
            for c in samples {
                guard let got = renderSolid(c, look: look, printing: p) else { worst = 1; break }
                let want = CollageLooks.grade(c.0, c.1, c.2, look: look, strength: 0.8, printing: p)
                worst = max(worst, abs(got.0 - want.0), abs(got.1 - want.1), abs(got.2 - want.2))
            }
            check(worst <= 3.0 / 255, "\(look.rawValue) 曝光 \(p.exposure) 冷暖 \(p.warmth)：渲染出来和 grade() 一样",
                  String(format: "最大差 %.1f/255", worst * 255))
        }
        // 颗粒跟着曝光走：均值不动；画幅 6×4.5 的颗粒约是 135 的 35/56。
        guard let grayColor = CIColor(red: 0.5, green: 0.45, blue: 0.4, alpha: 1, colorSpace: CollageRender.srgb) else { return }
        let rect = CGRect(x: 0, y: 0, width: 192, height: 192)
        let img = CIImage(color: grayColor).cropped(to: rect)
        var ops = CollageLooks.Ops(gains: nil, look: .filmWarmSkin, strength: 1, printing: P(exposure: 1))
        let base = readLinear(CollageFilmEffects.apply(img, ops: ops, frameLongEdge: 2000, seed: "a", extent: rect), rect)
        ops.grain = 0.5
        let grained = readLinear(CollageFilmEffects.apply(img, ops: ops, frameLongEdge: 2000, seed: "a", extent: rect), rect)
        let shift = (0..<3).map { abs(stats(grained, $0).mean - stats(base, $0).mean) }.max() ?? 1
        check(shift <= 0.006 && stats(grained, 1).std > 0.002, "胶片曝光 +1 档上开颗粒：均值不动、颗粒还在",
              String(format: "最大偏 %.4f σ %.4f", shift, stats(grained, 1).std))
        ops.printing = P()
        let g135 = readLinear(CollageFilmEffects.apply(img, ops: ops, frameLongEdge: 2000, seed: "a", extent: rect), rect)
        ops.formatMM = CollageFilmFormat.f645.grainLongEdgeMM
        let g645 = readLinear(CollageFilmEffects.apply(img, ops: ops, frameLongEdge: 2000, seed: "a", extent: rect), rect)
        let flat = readLinear(CollageLooks.apply(img, ops: CollageLooks.Ops(gains: nil, look: .filmWarmSkin, strength: 1)), rect)
        let s135 = stats(g135, 1).std - stats(flat, 1).std, s645 = stats(g645, 1).std - stats(flat, 1).std
        let ratio = s645 / max(1e-9, s135)
        check(ratio > 0.5 && ratio < 0.75, "画幅 6×4.5：颗粒约是 135 的 35/56（0.63）", String(format: "%.2f 倍", ratio))
    }

    /// 一块 8×8 的纯色走 CollageLooks.apply（强度 0.8），读回中间那个像素（sRGB 0…1）。
    private static func renderSolid(_ c: (Double, Double, Double), look: CollageLook,
                                    printing: CollageFilmEffects.Printing = CollageFilmEffects.Printing()) -> (Double, Double, Double)? {
        guard let color = CIColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1,
                                  colorSpace: CollageRender.srgb) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        let solid = CIImage(color: color).cropped(to: rect)
        let graded = CollageLooks.apply(solid, ops: CollageLooks.Ops(gains: nil, look: look, strength: 0.8, printing: printing))
        guard let cg = CollageRender.ciContext.createCGImage(graded, from: rect, format: .RGBA8, colorSpace: CollageRender.srgb),
              let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        let o = 4 * cg.bytesPerRow + 4 * 4
        return (Double(p[o]) / 255, Double(p[o + 1]) / 255, Double(p[o + 2]) / 255)
    }
}
