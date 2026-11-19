import CoreGraphics
import Foundation

/// 闭眼 EAR 按两眼连线转平（FaceAnalyzer.levelledEyeAspectRatio，优化分析 2026-11-18 VQ-05 / VQ-08）：LabelGUI --ear-selftest。
/// 纯几何，不跑 Vision、不读写任何文件：画两只椭圆的眼睛轮廓（睁 0.34、闭 0.06），整组绕原点转各种角度，转平后的读数
/// 要和正着的一样；同时核对老量法（直接在坐标轴上取外接框）在歪 20° 时确实把闭着的眼读过了 0.22 —— 证明测的是那个坑。
/// Vision 在真图上的那一半（合成 emoji 转 20°、EXIF 方向写错脸横躺）在 Scripts/native_analysis_smoke.py 第 7 段。
enum EyeLevelSelfTest {
    /// 一只眼的轮廓：中心 (cx, 0)，半宽 1、半高 halfHeight，8 个点（含正上、正下、最左、最右），高宽比 = halfHeight。
    static func eye(centerX: Double, halfHeight: Double) -> [CGPoint] {
        var points: [CGPoint] = []
        for k in 0..<8 {
            let t = Double(k) * .pi / 4
            points.append(CGPoint(x: centerX + cos(t), y: halfHeight * sin(t)))
        }
        return points
    }

    static func rotate(_ points: [CGPoint], degrees: Double) -> [CGPoint] {
        let a = degrees * .pi / 180
        let c = cos(a), s = sin(a)
        var out: [CGPoint] = []
        for p in points {
            let x = Double(p.x), y = Double(p.y)
            out.append(CGPoint(x: x * c - y * s, y: x * s + y * c))
        }
        return out
    }

    /// 老量法：两只眼各自在坐标轴上取外接框的高宽比，取平均。
    static func axisAligned(_ left: [CGPoint], _ right: [CGPoint]) -> Double {
        func ratio(_ pts: [CGPoint]) -> Double {
            let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
            return (ys.max()! - ys.min()!) / (xs.max()! - xs.min()!)
        }
        return (ratio(left) + ratio(right)) / 2
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
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "nil" }

        let angles: [Double] = [-30, -20, -10, -5, 0, 5, 10, 12.4, 20, 23, 30, 45, 90, 135, 180, 270]
        for (name, h) in [("睁眼 0.34", 0.34), ("闭眼 0.06", 0.06)] {
            let left = eye(centerX: -1.6, halfHeight: h), right = eye(centerX: 1.6, halfHeight: h)
            var worst = 0.0, detail: [String] = []
            for a in angles {
                let got = FaceAnalyzer.levelledEyeAspectRatio(left: rotate(left, degrees: a), right: rotate(right, degrees: a))
                worst = max(worst, abs((got ?? -1) - h))
                detail.append("\(a)°=\(fmt(got))")
            }
            check(worst < 1e-9, "\(name)：整组转 -30°…270°（含 90° 横躺、180° 倒着）转平后读数不变", detail.joined(separator: " "))
        }

        // 老量法在歪 20° 时把闭着的眼读成了 0.22 以上（判决层以前一律算睁眼）；转平后 < 地板 0.08。
        let closedL = rotate(eye(centerX: -1.6, halfHeight: 0.06), degrees: 20)
        let closedR = rotate(eye(centerX: 1.6, halfHeight: 0.06), degrees: 20)
        let old = axisAligned(closedL, closedR)
        let levelled = FaceAnalyzer.levelledEyeAspectRatio(left: closedL, right: closedR)
        check(old >= 0.22, "前提：老量法歪 20° 的闭眼读数 ≥ 0.22（这就是 VQ-05 的坑）", fmt(old))
        check((levelled ?? 1) < BatchStore.earAbsoluteFloor,
              "歪 20° 的闭眼转平后 < 地板 \(BatchStore.earAbsoluteFloor)", fmt(levelled))
        // 脸横躺（EXIF 方向写错）：老量法读成 1 以上（VQ-08 说的 2–3.5），转平后照旧。
        let sideL = rotate(eye(centerX: -1.6, halfHeight: 0.34), degrees: 90)
        let sideR = rotate(eye(centerX: 1.6, halfHeight: 0.34), degrees: 90)
        let oldSide = axisAligned(sideL, sideR)
        let newSide = FaceAnalyzer.levelledEyeAspectRatio(left: sideL, right: sideR)
        check(oldSide > 1, "前提：老量法横躺的睁眼读数 > 1", fmt(oldSide))
        check(abs((newSide ?? -1) - 0.34) < 1e-9, "横躺的睁眼转平后 0.34", fmt(newSide))

        // 左右眼认反、整体放大、平移：都不影响。
        let l = rotate(eye(centerX: -1.6, halfHeight: 0.25), degrees: 17)
        let r = rotate(eye(centerX: 1.6, halfHeight: 0.25), degrees: 17)
        let base = FaceAnalyzer.levelledEyeAspectRatio(left: l, right: r)
        let swapped = FaceAnalyzer.levelledEyeAspectRatio(left: r, right: l)
        var scaled: [[CGPoint]] = []
        for pts in [l, r] {
            var s: [CGPoint] = []
            for p in pts { s.append(CGPoint(x: p.x * 37 + 500, y: p.y * 37 - 120)) }
            scaled.append(s)
        }
        let moved = FaceAnalyzer.levelledEyeAspectRatio(left: scaled[0], right: scaled[1])
        check(abs((base ?? -1) - 0.25) < 1e-9 && abs((swapped ?? -1) - 0.25) < 1e-9 && abs((moved ?? -1) - 0.25) < 1e-9,
              "左右眼认反、放大 37 倍再平移，读数都是 0.25", "\(fmt(base)) \(fmt(swapped)) \(fmt(moved))")

        // 两只眼不一样大（一只眯）：各量各的再平均，轴照样是质心连线。
        let squintL = rotate(eye(centerX: -1.6, halfHeight: 0.30), degrees: -23)
        let squintR = rotate(eye(centerX: 1.6, halfHeight: 0.10), degrees: -23)
        let mixed = FaceAnalyzer.levelledEyeAspectRatio(left: squintL, right: squintR)
        check(abs((mixed ?? -1) - 0.20) < 1e-9, "一只 0.30、一只 0.10，歪 -23°：平均 0.20", fmt(mixed))

        // 一只眼点不够（< 4 个）：只用另一只，轴照样有（质心一个点也算得出）。一只眼一个点都没有：没有轴，退回老量法。
        let few = Array(rotate(eye(centerX: -1.6, halfHeight: 0.3), degrees: 20).prefix(3))
        let oneEye = FaceAnalyzer.levelledEyeAspectRatio(left: few, right: rotate(eye(centerX: 1.6, halfHeight: 0.3), degrees: 20))
        check(oneEye != nil && abs(oneEye! - 0.3) < 0.02, "一只眼只有 3 个点：用另一只，按两个质心的连线转平（≈ 0.30）", fmt(oneEye))
        let lone = rotate(eye(centerX: 1.6, halfHeight: 0.3), degrees: 20)
        let noAxis = FaceAnalyzer.levelledEyeAspectRatio(left: [], right: lone)
        check(abs((noAxis ?? -1) - axisAligned(lone, lone)) < 1e-9, "一只眼没有点：没有连线，退回坐标轴上量", fmt(noAxis))
        check(FaceAnalyzer.levelledEyeAspectRatio(left: [], right: []) == nil, "两只眼都没有点：nil")

        print(failed == 0 ? "EAR 转平自检通过：\(total) 条" : "!! EAR 转平自检 \(failed) / \(total) 条失败")
        exit(failed == 0 ? 0 : 1)
    }
}
