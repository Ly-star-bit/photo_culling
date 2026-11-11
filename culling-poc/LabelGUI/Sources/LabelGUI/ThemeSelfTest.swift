import Foundation

/// LabelGUI --theme-selftest：六套主题的颜色表（AppTheme.swift）逐套核对 —— 字读不读得清、点缀色认不认得出、会不会和判决色撞。
/// 纯函数，不读写任何文件，不建窗口。
enum ThemeSelfTest {
    static func rgb(_ v: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// WCAG 相对亮度。
    static func luminance(_ v: UInt32) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let c = rgb(v)
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// 色相（度）和饱和度（HSV）。
    static func hueSat(_ v: UInt32) -> (hue: Double, sat: Double) {
        let c = rgb(v)
        let hi = max(c.r, c.g, c.b), lo = min(c.r, c.g, c.b), d = hi - lo
        guard d > 0 else { return (0, 0) }
        var h: Double
        if hi == c.r { h = (c.g - c.b) / d } else if hi == c.g { h = 2 + (c.b - c.r) / d } else { h = 4 + (c.r - c.g) / d }
        h *= 60
        if h < 0 { h += 360 }
        return (h, d / hi)
    }

    static func hueGap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// 通道最大差（0…255）：这个灰带了多少色。
    static func tint(_ v: UInt32) -> Int {
        let c = [Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF)]
        return c.max()! - c.min()!
    }

    static func run() -> Never {
        var failed = 0, checked = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            checked += 1
            if !ok { failed += 1; print("FAIL \(what())") }
        }
        // 判决和状态占着的色相：系统红、绿、蓝、紫（深色外观下的值）。
        let taken: [(String, Double)] = [("废片红", 3), ("精选绿", 135), ("可用蓝", 211), ("客户紫", 280)]

        for theme in AppThemeID.allCases {
            let colors = theme.colors
            let h = colors.hex
            func c(_ key: String) -> UInt32 { h[key]! }
            let name = theme.title
            // 字：正文在栏、卡片、顶栏上 ≥ 7:1，二级字 ≥ 4.5:1，三级字 ≥ 3:1。
            for surface in ["bar", "panel", "card"] {
                check(contrast(c("text"), c(surface)) >= 7, "\(name)：正文在 \(surface) 上 \(contrast(c("text"), c(surface)))")
                check(contrast(c("secondary"), c(surface)) >= 4.5, "\(name)：二级字在 \(surface) 上 \(contrast(c("secondary"), c(surface)))")
            }
            check(contrast(c("tertiary"), c("panel")) >= 3, "\(name)：三级字在 panel 上 \(contrast(c("tertiary"), c("panel")))")
            // 点缀色：在栏、卡片、放照片的底上都要认得出（非文字 ≥ 3:1）；上面的字 ≥ 4.5:1。
            for surface in ["bar", "panel", "card", "canvas"] {
                check(contrast(c("accent"), c(surface)) >= 3, "\(name)：点缀色在 \(surface) 上 \(contrast(c("accent"), c(surface)))")
                check(contrast(c("warning"), c(surface)) >= 3, "\(name)：待处理色在 \(surface) 上 \(contrast(c("warning"), c(surface)))")
            }
            check(contrast(c("onAccent"), c("accent")) >= 4.5, "\(name)：主按钮上的字 \(contrast(c("onAccent"), c("accent")))")
            // 点缀色带色的话，离判决色、待处理色的色相都要够远。
            let accent = hueSat(c("accent")), warning = hueSat(c("warning"))
            if accent.sat > 0.15 {
                for (label, hue) in taken {
                    check(hueGap(accent.hue, hue) >= 20, "\(name)：点缀色色相 \(Int(accent.hue))° 离\(label)（\(Int(hue))°）太近")
                }
                check(hueGap(accent.hue, warning.hue) >= 12, "\(name)：点缀色 \(Int(accent.hue))° 离待处理色 \(Int(warning.hue))° 太近")
            }
            check(hueGap(warning.hue, 3) >= 8 && warning.hue > 3, "\(name)：待处理色 \(Int(warning.hue))° 离废片红太近")
            // 层次：壳 → 栏 → 卡片一级比一级亮；发丝线在栏上看得见。
            check(luminance(c("bar")) <= luminance(c("panel")) && luminance(c("panel")) < luminance(c("card")),
                  "\(name)：bar / panel / card 不是一级比一级亮")
            check(contrast(c("hairline"), c("panel")) >= 1.12, "\(name)：发丝线在 panel 上 \(contrast(c("hairline"), c("panel")))")
            // 放照片的底、暗房四周：带的色不超过外壳，而且很淡。
            for key in ["canvas", "surround"] {
                check(tint(c(key)) <= max(tint(c("panel")), 1) && tint(c(key)) <= 10, "\(name)：\(key) 带色 \(tint(c(key)))（panel \(tint(c("panel")))）")
            }
            check(colors.dark == (luminance(c("panel")) < 0.2), "\(name)：dark 标记和栏的亮度对不上")
            // 浅色主题的判决色压深了：小字 ≥ 4.5:1。
            if !colors.dark {
                for key in ["pick", "usable", "reject"] {
                    check(h[key].map { contrast($0, c("panel")) >= 4.5 } ?? false, "\(name)：\(key) 在 panel 上不够 4.5:1")
                }
            }
            check(!theme.title.isEmpty && !theme.subtitle.isEmpty, "\(name)：没有名字")
        }
        // 默认主题的数值不能动：v1.30 起发出去的就是这一套。
        let g = AppThemeID.graphite.colors.hex
        let frozen: [String: UInt32] = ["bar": 0x111111, "panel": 0x1A1A1A, "card": 0x242424, "hairline": 0x2A2A2A, "canvas": 0x212121,
                                        "surround": 0x2E2E2E, "track": 0x3A3A3A, "text": 0xEDEDED, "secondary": 0xA3A3A3,
                                        "tertiary": 0x6B6B6B, "accent": 0xFFB340, "onAccent": 0x141414, "warning": 0xFF7A38]
        check(g == frozen, "石墨的数值变了")
        // 存进设置的名字不能改；无头时不读设置，默认石墨。
        check(AppThemeID.allCases.map(\.rawValue) == ["graphite", "neutral", "walnut", "midnight", "black", "paper"], "主题的 rawValue 变了")
        check(Set(AppThemeID.allCases.map(\.title)).count == AppThemeID.allCases.count, "主题名字有重复")
        if ProcessInfo.processInfo.environment[ThemeCenter.envKey] == nil {
            check(ThemeCenter.shared.id == .graphite, "无头时默认主题不是石墨")
        }
        print("theme selftest: \(checked - failed)/\(checked) 通过")
        exit(failed == 0 ? 0 : 1)
    }
}
