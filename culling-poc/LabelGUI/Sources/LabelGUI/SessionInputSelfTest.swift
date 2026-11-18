import Foundation

/// 场次文件里不规矩的输入（优化分析 2026-11-18 edge 维度）：LabelGUI --session-input-selftest。
/// 纯函数，不读写任何文件；要真文件、真分析的那一半（解不开 / 取消没轮到的照片计数、一行坏了重新分析补回、长文件名、
/// 改名认回 id、thresholds.json 离谱值 --verdicts 不崩）在 Scripts/photo_id_regression.py 的 J–M 组。
/// - EC-04：thresholds.json 里四条线都夹到滑杆范围，1e19 / -1e30 / 缺键不崩、不越界；正常值一个不改。
enum SessionInputSelfTest {
    @MainActor
    static func run() -> Never {
        let c = Checker()
        thresholds(c)
        print(c.failed == 0 ? "场次输入自检通过：\(c.total) 条" : "!! 场次输入自检 \(c.failed) / \(c.total) 条失败")
        exit(c.failed == 0 ? 0 : 1)
    }

    final class Checker {
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
    }

    // MARK: - EC-04 thresholds.json 的离谱值

    static func thresholds(_ c: Checker) {
        func decoded(_ json: String) -> BatchStore.ThresholdState? {
            try? JSONDecoder().decode(BatchStore.ThresholdState.self, from: Data(json.utf8))
        }
        func line(_ s: BatchStore.ThresholdState) -> String {
            "对焦 \(s.resolvedFocus) 曝光 \(s.resolvedExposure) 人脸 \(s.resolvedFaceQuality) 间隔 \(s.resolvedTakeGap)"
        }
        // (json, 对焦, 曝光, 人脸质量, 间隔)
        let cases: [(String, Double, Double, Double, Double)] = [
            ("{\"sharpness\":45,\"faceQuality\":0.3,\"exposure\":0.15,\"takeGap\":1e19}", 60, 0.15, 0.3, 60),
            ("{\"sharpness\":45,\"faceQuality\":0.3,\"exposure\":0.15,\"takeGap\":-1e30}", 60, 0.15, 0.3, 1),
            ("{\"sharpness\":45,\"faceQuality\":99,\"exposure\":-5,\"takeGap\":-3}", 60, 0.005, 1, 1),
            ("{\"sharpness\":1e19,\"faceQuality\":-1e30,\"exposure\":1e19}", 150, 0.5, 0, 8),
            ("{\"sharpness\":45,\"faceQuality\":0.3,\"exposure\":0.15}", 60, 0.15, 0.3, 8),
            ("{\"sharpness\":45,\"focus\":72.5,\"faceQuality\":0.42,\"exposure\":0.07,\"takeGap\":13}", 72.5, 0.07, 0.42, 13),
        ]
        for (json, focus, exposure, quality, gap) in cases {
            guard let s = decoded(json) else {
                c.check(false, json, "解不开")
                continue
            }
            let ok = s.resolvedFocus == focus && s.resolvedExposure == exposure
                && s.resolvedFaceQuality == quality && s.resolvedTakeGap == gap
            c.check(ok, "\(json) → 对焦 \(focus) 曝光 \(exposure) 人脸 \(quality) 间隔 \(gap)", line(s))
        }
        // 三档预设、滑杆两头：原样（夹住不改任何 app 自己写得出的值）。
        for preset in BatchStore.CullPreset.allCases {
            let (focus, exposure, quality) = preset.thresholds
            let s = BatchStore.ThresholdState(focus: focus, exposure: exposure, faceQuality: quality, takeGap: 1)
            c.check(s.resolvedFocus == focus && s.resolvedExposure == exposure && s.resolvedFaceQuality == quality
                  && s.resolvedTakeGap == 1, "预设\(preset.rawValue)原样", line(s))
        }
        let edges = BatchStore.ThresholdState(focus: 150, exposure: 0.5, faceQuality: 1, takeGap: 60)
        c.check(edges.resolvedFocus == 150 && edges.resolvedExposure == 0.5 && edges.resolvedFaceQuality == 1
              && edges.resolvedTakeGap == 60, "滑杆最右边原样", line(edges))
        // 非有限（JSONDecoder 不收 NaN / Infinity，只能是代码里来的）：给默认，不越界。
        let weird = BatchStore.ThresholdState(focus: .nan, exposure: .infinity, faceQuality: -.infinity, takeGap: .nan)
        c.check(weird.resolvedFocus == 60 && weird.resolvedExposure == 0.15 && weird.resolvedFaceQuality == 0.3
              && weird.resolvedTakeGap == BatchStore.defaultTakeGapSec, "NaN / ±∞ → 标准那一份", line(weird))
        // 1e400 超出 Double：要么整份解不开（走 thresholds.corrupt 那条路），要么读成有限的范围内的数，不能崩。
        if let huge = decoded("{\"sharpness\":45,\"faceQuality\":0.3,\"exposure\":0.15,\"takeGap\":1e400}") {
            c.check(BatchStore.takeGapRange.contains(huge.resolvedTakeGap), "takeGap 1e400：读成范围内的数", line(huge))
        } else {
            c.check(true, "takeGap 1e400：整份解不开（走挪开 .corrupt 那条路）")
        }
    }
}
