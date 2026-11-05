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
        check(spectral.count == 10, "10 个光谱色调", "\(spectral.count) 个")
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
        }

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
            check(max(black.0, black.1, black.2) < 0.1 && min(white.0, white.1, white.2) > 0.75,
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

        print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    /// 一块 8×8 的纯色走 CollageLooks.apply（强度 0.8），读回中间那个像素（sRGB 0…1）。
    private static func renderSolid(_ c: (Double, Double, Double), look: CollageLook) -> (Double, Double, Double)? {
        guard let color = CIColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1,
                                  colorSpace: CollageRender.srgb) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        let solid = CIImage(color: color).cropped(to: rect)
        let graded = CollageLooks.apply(solid, ops: CollageLooks.Ops(gains: nil, look: look, strength: 0.8))
        guard let cg = CollageRender.ciContext.createCGImage(graded, from: rect, format: .RGBA8, colorSpace: CollageRender.srgb),
              let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        let o = 4 * cg.bytesPerRow + 4 * 4
        return (Double(p[o]) / 255, Double(p[o + 1]) / 255, Double(p[o + 2]) / 255)
    }
}
