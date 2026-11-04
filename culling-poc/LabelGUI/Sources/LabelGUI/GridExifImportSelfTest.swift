import Foundation

/// `--ux-selftest` 里的几组纯函数用例：EXIF 拍摄参数（快门 0 / 极小正数不崩）。
/// 每条打 PASS / FAIL 一行，返回失败条数（main.swift 加到总数上）。
enum GridExifImportSelfTest {
    final class Tally {
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if !ok { failed += 1 }
            let head: String = ok ? "PASS " : "FAIL "
            let tail: String = ok ? "" : "（" + detail() + "）"
            print(head + name + tail)
        }
    }

    static func run() -> Int {
        let tally = Tally()
        exifCases(tally)
        return tally.failed
    }

    // MARK: - EXIF（S18）

    private static func exifCases(_ t: Tally) {
        func summary(_ shutter: Double?, aperture: Double? = 2.8, focal: Int? = 85) -> String {
            ExifMeta(shutterSec: shutter, aperture: aperture, iso: 800, focal35: focal, lens: nil).summary
        }
        let rest = "f/2.8 · ISO 800 · 85mm"
        // (说明, 快门秒数, 期望的 summary)
        let rows: [(String, Double?, String)] = [
            ("快门 0（EXIF 写 0/1）→ 跳过快门，不崩", 0, rest),
            ("快门是最小的非规格化小数 5e-324 → 1/s 溢出成 inf，跳过", 5e-324, rest),
            ("快门 1e-300 → 1/s 有限但远超 Int.max，跳过", 1e-300, rest),
            ("快门 1e-19 → 1/s ≈ 1e19 > Int.max，跳过", 1e-19, rest),
            ("快门 NaN → 跳过", Double.nan, rest),
            ("快门 +inf → 跳过（以前印成 infs）", Double.infinity, rest),
            ("快门负数 → 跳过（以前印成 1/-250）", -0.004, rest),
            ("快门 1/250 照常", 0.004, "1/250 · " + rest),
            ("快门 1/2 照常", 0.5, "1/2 · " + rest),
            ("快门 2s 照常", 2, "2s · " + rest),
            ("没有快门照常", nil, rest),
        ]
        for (name, shutter, want) in rows {
            let got = summary(shutter)
            t.check(got == want, "EXIF " + name, "得到 \(got)，期望 \(want)")
        }
        let zeroes = summary(0.004, aperture: 0, focal: 0)
        t.check(zeroes == "1/250 · ISO 800", "EXIF 光圈 0、焦距 0（老 manifest）→ 不印 f/0.0、0mm", "得到 \(zeroes)")

        // ImageLoader 读 EXIF 的清洗：只收有限正数；焦距回退不 trap。
        let positives: [(Double?, Double?)] = [
            (0, nil), (-1, nil), (.nan, nil), (.infinity, nil), (5e-324, 5e-324), (0.004, 0.004), (nil, nil),
        ]
        for (input, want) in positives {
            let got = ImageLoader.positiveFinite(input)
            let label: String = input.map { "\($0)" } ?? "nil"
            t.check(got == want, "EXIF 读入只收有限正数 positiveFinite(\(label))", "得到 \(String(describing: got))")
        }
        let focals: [(Double?, Int?)] = [
            (0, nil), (0.4, nil), (-35, nil), (.nan, nil), (.infinity, nil), (1e300, nil), (35.9, 35), (85, 85), (nil, nil),
        ]
        for (input, want) in focals {
            let got = ImageLoader.focalMillimeters(input)
            let label: String = input.map { "\($0)" } ?? "nil"
            t.check(got == want, "EXIF 焦距回退 focalMillimeters(\(label))（以前 Int(1e300) / Int(nan) 会崩）",
                    "得到 \(String(describing: got))")
        }
        let intOK: Bool = ImageLoader.positiveInt(0) == nil && ImageLoader.positiveInt(50) == 50
        t.check(intOK, "EXIF 35mm 等效焦距 0 = 未知，当没有（回退到实际焦距）")
    }
}
