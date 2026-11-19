import Foundation

/// 主体曝光裁切只数人（Metrics.personClipping，优化分析 2026-11-18 VQ-01）：LabelGUI --clip-selftest。
/// 纯数组，不跑 Vision、不读写任何文件：200×100 的灰图（128），右边一条竖的「人」（分割蒙版 100×50，半分辨率，顺带核对蒙版
/// 按像素中心对到分析图上），主体矩形比人宽。逐条摆出合成集里那几种情况：
///   - 白底：人外面全是死白 → 0（矩形 ∩ 人里没有死白）；
///   - 逆光连进来：左下一大片死白（中间有暗的栏杆缝）一直连进人的左下角 —— 只取交集（修法 B）会算 12.5%，块判法整块扔掉；
///   - 人身上被围住的一块死白（白袖子）照算；
///   - 脸芯打爆（整张过曝）→ max(矩形, 矩形 ∩ 人)；
///   - 黑底不算、人身上的死黑照算；
///   - 蒙版是空的 / 尺寸不对 / 没有矩形 → nil（调用方照旧用矩形）。
/// Vision 那一半（真分割在合成白底 / 逆光 / 整体过曝上的数）在交接记录的前后对照表里，CI 里没有 —— 分割模型认不出合成的色块人。
enum PersonClipSelfTest {
    static let width = 200, height = 100
    /// 人：x 120..<160，整条竖的。矩形：x 100..<180，y 0..<100。脸：x 130..<150，y 5..<25。
    static let body: [[Double]] = [[0.5, 0.0, 0.9, 1.0]]
    static let face: [[Double]] = [[0.65, 0.05, 0.75, 0.25]]

    static func personMask() -> Metrics.PersonMask {
        var v = [UInt8](repeating: 0, count: 100 * 50)
        for y in 0..<50 {
            for x in 60..<80 { v[y * 100 + x] = 255 }
        }
        return Metrics.PersonMask(width: 100, height: 50, values: v)
    }

    static func isPerson(_ x: Int) -> Bool { x >= 120 && x < 160 }

    final class Canvas {
        var rgba = [UInt8](repeating: 128, count: PersonClipSelfTest.width * PersonClipSelfTest.height * 4)
        func set(_ x: Int, _ y: Int, _ v: UInt8) {
            let i = (y * PersonClipSelfTest.width + x) * 4
            rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v
        }
        func fill(x: Range<Int>, y: Range<Int>, _ v: UInt8) {
            for yy in y { for xx in x { set(xx, yy, v) } }
        }
        /// 左下的逆光背景：x 0..<130、y 50..<100 死白，人外面那部分每 3 像素留一个暗点（栏杆缝 / 背景纹理）。x 120..<130 是连进人里的那截。
        func backlitLeak() {
            fill(x: 0..<130, y: 50..<100, 255)
            for yy in 50..<100 where yy % 3 == 1 {
                for xx in 0..<120 where xx % 3 == 1 { set(xx, yy, 60) }
            }
        }
    }

    /// 直接数：矩形 / 矩形 ∩ 人 里的高光、暗部裁切比例（不分块）。
    static func plain(_ c: Canvas, personOnly: Bool) -> (Double, Double) {
        var n = 0, hi = 0, lo = 0
        for y in 0..<height {
            for x in 100..<180 where !personOnly || isPerson(x) {
                let v = c.rgba[(y * width + x) * 4]
                n += 1
                if v >= Metrics.highlightClipValue { hi += 1 }
                if v <= Metrics.shadowClipValue { lo += 1 }
            }
        }
        return (Double(hi) / Double(n), Double(lo) / Double(n))
    }

    static func measure(_ c: Canvas, mask: Metrics.PersonMask = personMask(),
                        bodies: [[Double]] = body) -> (highlightPct: Double, shadowPct: Double)? {
        Metrics.personClipping(rgba: c.rgba, width: width, height: height,
                               bodies: Metrics.spans(of: bodies, width: width, height: height), faces: face, mask: mask)
    }

    @MainActor
    static func run() -> Never {
        var failed = 0
        var total = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            total += 1
            if ok {
                print("PASS " + name)
            } else {
                failed += 1
                print("FAIL " + name + " " + detail())
            }
        }
        func pct(_ v: Double?) -> String { v.map { String(format: "%.2f%%", $0 * 100) } ?? "nil" }
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-12 } ?? false }

        // 白底：人外面全死白。矩形 25%，只数人 0。
        let white = Canvas()
        white.fill(x: 0..<120, y: 0..<100, 255)
        white.fill(x: 160..<200, y: 0..<100, 255)
        let w = measure(white)
        check(plain(white, personOnly: false).0 >= 0.15, "前提：白底按矩形 ≥ 15%（以前判曝光裁切）", pct(plain(white, personOnly: false).0))
        check(near(w?.highlightPct, 0) && near(w?.shadowPct, 0), "白底：只数人 → 0", pct(w?.highlightPct))

        // 逆光连进来 + 人身上一块被围住的死白（x 140..<150、y 30..<50，200 像素）。
        let leak = Canvas()
        leak.backlitLeak()
        let leakOnly = measure(leak)
        check(plain(leak, personOnly: true).0 >= 0.1, "前提：逆光那片连进人里，只取交集（修法 B）≥ 10%",
              pct(plain(leak, personOnly: true).0))
        check(near(leakOnly?.highlightPct, 0), "逆光连进来的死白（外圈大多是背景）整块不算 → 0", pct(leakOnly?.highlightPct))
        leak.fill(x: 140..<150, y: 30..<50, 255)
        let both = measure(leak)
        // 人 4000 像素，死白 500（连进来的）+ 200（袖子）；扔掉 500 以后分母 3500。
        check(near(both?.highlightPct, 200.0 / 3500.0), "人身上被围住的死白照算：200 / 3500", pct(both?.highlightPct))

        // 脸芯打爆：整张过曝，块判法会把人身上的也扔掉 → 取 max(矩形, 矩形 ∩ 人)。
        let blown = Canvas()
        blown.backlitLeak()
        blown.fill(x: 140..<150, y: 30..<50, 255)
        blown.fill(x: 130..<150, y: 5..<25, 255)
        let b = measure(blown)
        let rect = plain(blown, personOnly: false), person = plain(blown, personOnly: true)
        check(near(b?.highlightPct, max(rect.0, person.0)) && near(b?.shadowPct, max(rect.1, person.1)),
              "脸芯打爆 → max(矩形, 矩形 ∩ 人)", "\(pct(b?.highlightPct)) 期望 \(pct(max(rect.0, person.0)))")
        // 脸芯里只有一个死白像素（< 2%）：不算打爆，照旧按块判。
        let speck = Canvas()
        speck.backlitLeak()
        speck.set(140, 15, 255)
        let s = measure(speck)
        check(near(s?.highlightPct, 1.0 / 3500.0), "脸芯里一个高光点（< 2%）不算打爆：连进来的照扔，高光点算 1 / 3500", pct(s?.highlightPct))

        // 黑底：人外面全死黑 → 不算；人身上一块死黑（x 145..<155、y 60..<80，200 像素）照算。
        let black = Canvas()
        black.fill(x: 0..<120, y: 0..<100, 0)
        black.fill(x: 160..<200, y: 0..<100, 0)
        check(plain(black, personOnly: false).1 >= 0.15, "前提：黑底按矩形 ≥ 15%", pct(plain(black, personOnly: false).1))
        let k = measure(black)
        check(near(k?.shadowPct, 0) && near(k?.highlightPct, 0), "黑底：只数人 → 0", pct(k?.shadowPct))
        black.fill(x: 145..<155, y: 60..<80, 0)
        let k2 = measure(black)
        check(near(k2?.shadowPct, 200.0 / 4000.0), "人身上的死黑照算：200 / 4000", pct(k2?.shadowPct))

        // 退回矩形的几种：蒙版里没有人、人只占矩形一小条（分割基本没认出人）、蒙版尺寸和像素数对不上、没有主体矩形。
        let empty = Metrics.PersonMask(width: 100, height: 50, values: [UInt8](repeating: 0, count: 5000))
        check(measure(white, mask: empty) == nil, "蒙版里没有人 → nil（照旧用矩形）")
        var thinValues = [UInt8](repeating: 0, count: 5000)
        for y in 0..<50 {
            for x in 60..<65 { thinValues[y * 100 + x] = 255 }
        }
        let thin = Metrics.PersonMask(width: 100, height: 50, values: thinValues)
        check(measure(white, mask: thin) == nil, "人只占矩形 12.5%（< \(Metrics.minPersonShare)）→ nil")
        let broken = Metrics.PersonMask(width: 100, height: 50, values: [UInt8](repeating: 255, count: 10))
        check(measure(white, mask: broken) == nil, "蒙版尺寸和像素数对不上 → nil")
        check(measure(white, bodies: []) == nil, "没有主体矩形 → nil")

        print(failed == 0 ? "主体裁切只数人自检通过：\(total) 条" : "!! 主体裁切只数人自检 \(failed) / \(total) 条失败")
        exit(failed == 0 ? 0 : 1)
    }
}
