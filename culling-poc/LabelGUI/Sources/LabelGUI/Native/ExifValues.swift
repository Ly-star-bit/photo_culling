import Foundation

/// EXIF 数值的清洗：ExposureTime 写成 0/1（扫描件、转接手动镜头、部分软件导出）、
/// 或者读出非有限值时，往下一路（manifest、显示、MCP）都不该见到它。
extension ImageLoader {
    /// 只收有限的正数；0、负数、NaN、inf 一律当没有。
    static func positiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// 焦距回退（没有 35mm 等效时拿实际焦距）：只收有限正数、截成整数后还 > 0 的。
    /// `Int(focal)` 碰到 NaN / inf / 超出 Int 的数会直接 trap，`Int(exactly:)` 给 nil。
    static func focalMillimeters(_ value: Double?) -> Int? {
        guard let focal = positiveFinite(value), let mm = Int(exactly: focal.rounded(.towardZero)), mm > 0 else {
            return nil
        }
        return mm
    }

    /// 35mm 等效焦距（EXIF 里本来就是整数）：0 = 未知，当没有。
    static func positiveInt(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

extension ExifMeta {
    /// 快门那一段：≥1s 写「2s」，否则「1/250」。0、负数、非有限、或者 1/s 大到装不进 Int
    /// （非规格化小数）就返回 nil —— 以前 `Int((1 / s).rounded())` 在 s = 0 时是 `Int(+inf)`，直接崩。
    static func shutterText(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 1 { return String(format: "%.0fs", seconds) }
        let inverse: Double = (1 / seconds).rounded()
        guard let denominator = Int(exactly: inverse) else { return nil }
        return "1/\(denominator)"
    }
}
