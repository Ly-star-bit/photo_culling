import Foundation

/// 判虚焦的「对焦」（Metrics.focusRatio）和 thresholds.json 按档迁移（优化分析 2026-11-18 VQ-02 / VQ-06）：LabelGUI --focus-selftest。
/// 纯数组 + 纯函数，不跑 Vision、不读写任何文件。真照片上的那一半（合成集的判废率、photot 21 张判决不变）在交接记录里，
/// 判决层的整条路在 Fixtures/synthetic-rejects 的 A02 / A03 / S 组（verdict_regression.sh）。
/// - 对焦随模糊单调往下走；亮度、反差怎么变都不动（比值把反差约掉了）；只有一个方向的运动模糊也压得下去；
///   平的区域给 0、区域贴着画面边、只有几像素都不崩。
/// - 旧刻度（锐度）的线按档迁移：三档 25 / 45 / 60 → 45 / 60 / 70，两档之间的落在两档之间；离谱值夹到滑杆两头不崩（EC-04）；
///   同一个映射用在老结果的每张照片上，「折算后的锐度 < 折算后的线」和「锐度 < 线」逐个相同（老场次判决不因升级变）。
enum FocusSelfTest {
    /// 确定性的「五官」纹理：中灰底上叠一堆随机的亮 / 暗矩形和细线（边缘一像素陡），0–255。
    static func texture(width: Int, height: Int, seed: UInt64) -> [Float] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        var img = [Float](repeating: 128, count: width * height)
        for _ in 0..<160 {
            let w = 1 + Int(next() * Double(width) / 6), h = 1 + Int(next() * Double(height) / 6)
            let x0 = Int(next() * Double(width - 1)), y0 = Int(next() * Double(height - 1))
            let v = Float(30 + next() * 195)
            for y in y0..<min(height, y0 + h) {
                for x in x0..<min(width, x0 + w) { img[y * width + x] = v }
            }
        }
        return img
    }

    /// 可分离高斯模糊（σ 像素，核半径 3σ，边上夹到最近的像素）。
    static func blur(_ img: [Float], _ w: Int, _ h: Int, sigma: Double) -> [Float] {
        let r = max(1, Int((3 * sigma).rounded(.up)))
        var kernel: [Float] = []
        for k in -r...r { kernel.append(Float(exp(-Double(k * k) / (2 * sigma * sigma)))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var tmp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for k in -r...r { acc += kernel[k + r] * img[y * w + min(w - 1, max(0, x + k))] }
                tmp[y * w + x] = acc
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for k in -r...r { acc += kernel[k + r] * tmp[min(h - 1, max(0, y + k)) * w + x] }
                out[y * w + x] = acc
            }
        }
        return out
    }

    /// 只沿横向的箱式模糊（长度 `length` 像素）：一个方向的运动模糊。
    static func motion(_ img: [Float], _ w: Int, _ h: Int, length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        let half = length / 2
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for k in 0..<length { acc += img[y * w + min(w - 1, max(0, x - half + k))] }
                out[y * w + x] = acc / Float(length)
            }
        }
        return out
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
        func fmt(_ v: Double) -> String { String(format: "%.4f", v) }

        // 一块 240 × 80 的「眼眉带」放在 320 × 160 的画面里（四周有别的纹理，量的只是那一块）。
        let w = 320, h = 160
        let sharp = texture(width: w, height: h, seed: 7)
        func ratio(_ img: [Float]) -> Double {
            Metrics.focusRatio(gray: img, width: w, height: h, x0: 40, y0: 40, x1: 280, y1: 120)
        }
        let r0 = ratio(sharp)
        var chain = [r0]
        for sigma in [0.7, 1.2, 2.0, 3.2] { chain.append(ratio(blur(sharp, w, h, sigma: sigma))) }
        let monotone = zip(chain, chain.dropFirst()).allSatisfy { $0 > $1 }
        check(monotone && chain.last! < 0.5 * r0, "模糊越重对焦越低（σ 0 / 0.7 / 1.2 / 2 / 3.2）",
              chain.map(fmt).joined(separator: " "))

        // 亮度、反差：整块乘 0.4（暗一档多）再加 20，比值不动 —— 锐度（tenengrad）会跟着掉 60%。
        let dim = sharp.map { $0 * 0.4 + 20 }
        let rDim = ratio(dim)
        let tSharp = Metrics.tenengrad(gray: sharp, width: w, height: h, x0: 40, y0: 40, x1: 280, y1: 120)
        let tDim = Metrics.tenengrad(gray: dim, width: w, height: h, x0: 40, y0: 40, x1: 280, y1: 120)
        check(abs(rDim - r0) < 1e-4 * r0 && tDim < 0.45 * tSharp, "暗下去、反差小了：对焦不变，锐度掉一半多",
              "对焦 \(fmt(r0)) → \(fmt(rDim))，锐度 \(fmt(tSharp)) → \(fmt(tDim))")

        // 只横向的运动模糊：横竖分开取最小，压得下去（各向同性的比值几乎不动）。
        let moved = ratio(motion(sharp, w, h, length: 9))
        check(moved < 0.6 * r0, "横向运动模糊 9 像素：对焦掉到 6 成以下", "\(fmt(r0)) → \(fmt(moved))")

        // 平的区域 = 0（和以前锐度 ≈ 0 一样判糊）；贴着画面边、只有几个像素、整张都不崩，结果都是有限的非负数。
        let flat = [Float](repeating: 128, count: w * h)
        check(Metrics.focusRatio(gray: flat, width: w, height: h, x0: 10, y0: 10, x1: 100, y1: 60) == 0, "纯灰的区域：0")
        // 平滑渐变（每像素 1/8 个灰阶，存成 8 位只剩量化台阶，没有一处细节）：也是 0 —— 不然台阶的二阶导把它量成「清楚」。
        var ramp = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { ramp[y * w + x] = Float(30 + 40 * x / (w - 1)) } }
        let rampFocus = Metrics.focusRatio(gray: ramp, width: w, height: h, x0: 40, y0: 40, x1: 280, y1: 120)
        check(rampFocus == 0, "平滑渐变（只剩 8 位量化台阶）：0", fmt(rampFocus))
        let edgeCases: [Double] = [
            Metrics.focusRatio(gray: sharp, width: w, height: h, x0: 0, y0: 0, x1: 60, y1: 20),
            Metrics.focusRatio(gray: sharp, width: w, height: h, x0: w - 30, y0: h - 12, x1: w + 50, y1: h + 50),
            Metrics.focusRatio(gray: sharp, width: w, height: h, x0: 100, y0: 100, x1: 103, y1: 103),
            Metrics.focusRatio(gray: sharp, width: w, height: h),
            Metrics.focusRatio(gray: [Float](repeating: 9, count: 16), width: 4, height: 4),
        ]
        check(edgeCases.allSatisfy { $0.isFinite && $0 >= 0 }, "贴边、越界、3×3、整张、4×4 的小图：有限、非负",
              edgeCases.map(fmt).joined(separator: " "))

        // 按档迁移：老 thresholds.json 只有 sharpness。
        func decoded(_ json: String) -> BatchStore.ThresholdState? {
            try? JSONDecoder().decode(BatchStore.ThresholdState.self, from: Data(json.utf8))
        }
        for preset in BatchStore.CullPreset.allCases {
            let json = "{\"sharpness\":\(preset.legacySharpness),\"exposure\":0.15,\"faceQuality\":0}"
            let got = decoded(json)?.resolvedFocus
            check(got == preset.thresholds.0, "旧刻度\(preset.rawValue) \(preset.legacySharpness) → 新刻度 \(preset.thresholds.0)",
                  got.map(fmt) ?? "解不开")
        }
        let between = decoded("{\"sharpness\":50,\"exposure\":0.15,\"faceQuality\":0}")?.resolvedFocus ?? -1
        let standard = BatchStore.CullPreset.standard.thresholds.0, strict = BatchStore.CullPreset.strict.thresholds.0
        check(between > standard && between < strict, "旧 50（标准和严格之间）→ 新刻度标准和严格之间", fmt(between))
        let wild: [(String, Double)] = [
            ("{\"sharpness\":1e19,\"exposure\":0.15,\"faceQuality\":0}", BatchStore.focusRange.upperBound),
            ("{\"sharpness\":-1e30,\"exposure\":0.15,\"faceQuality\":0}", 0),
            ("{\"sharpness\":0,\"exposure\":0.15,\"faceQuality\":0}", 0),
            ("{\"sharpness\":45,\"focus\":1e19,\"exposure\":0.15,\"faceQuality\":0}", BatchStore.focusRange.upperBound),
            ("{\"sharpness\":45,\"focus\":-3,\"exposure\":0.15,\"faceQuality\":0}", 0),
            ("{\"sharpness\":45,\"focus\":55,\"exposure\":0.15,\"faceQuality\":0}", 55),
        ]
        for (json, want) in wild {
            let got = decoded(json)?.resolvedFocus
            check(got == want, "\(json) → 对焦线 \(want)（有 focus 就用它，离谱的夹到滑杆两头）", got.map(fmt) ?? "解不开")
        }
        // 新写的文件两个键都有：focus 是新刻度，sharpness 折回旧刻度（退回旧版本时还能用）。
        let state = BatchStore.ThresholdState(focus: strict, exposure: 0.08, faceQuality: 0.45, takeGap: nil)
        let encoded = (try? JSONEncoder().encode(state))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        check(encoded["focus"] as? Double == strict && encoded["sharpness"] as? Double == 60,
              "写出去：focus \(strict)、sharpness 60（严格档的旧线）", "\(encoded)")

        // 老结果（没有 focus_ratio）：锐度和线都过同一个严格单调的映射，判不判虚焦逐个和升级前一样（含正好等于线）。
        let oldLines: [Double] = [5, 10, 25, 30, 40, 44, 45, 46, 50, 52.5, 60, 75, 120, 150]
        var mismatches: [String] = []
        var roundTrip = 0.0
        for t in oldLines {
            for k in 0...400 {
                let x = Double(k) * 0.5
                let before = x < t
                let after = BatchStore.legacyFocus(fromSharpness: x) < BatchStore.legacyFocus(fromSharpness: t)
                if before != after { mismatches.append("锐度 \(x) / 线 \(t)") }
                roundTrip = max(roundTrip, abs(BatchStore.legacySharpness(fromFocus: BatchStore.legacyFocus(fromSharpness: x)) - x))
            }
        }
        check(mismatches.isEmpty, "老结果：折算后比和直接比，14 条线 × 401 个锐度一个不差", mismatches.prefix(5).joined(separator: "，"))
        check(roundTrip < 1e-9, "折过去再折回来还是原值", fmt(roundTrip))

        print(failed == 0 ? "对焦自检通过：\(total) 条" : "!! 对焦自检 \(failed) / \(total) 条失败")
        exit(failed == 0 ? 0 : 1)
    }
}
