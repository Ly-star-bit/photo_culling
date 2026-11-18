import Foundation

/// LabelGUI --theme-selftest：六套主题的颜色表（AppTheme.swift）逐套核对 —— 字读不读得清、点缀色认不认得出、会不会和判决色撞、
/// 选中框压在白纸上看不看得见、放照片的底带不带色。核对的是界面上实际画出来的颜色：深色主题的判决色 / 提醒黄 / 客户紫没有
/// 自己的值（就是系统色），按系统色在 macOS 15 和 26 上的实际值算（`systemDark`）；相纸用它自己压深过的值。
/// 纯函数，不读写任何文件，不建窗口。
///
/// 管不到的（这里通过不等于界面上没问题）：
///   - 页面到底用没用这些出口：说明字写成 SwiftUI 的 `.secondary`、废片红写成 `.red`、提醒写成 `.yellow`，这里照样通过
///     （优化分析 2026-11-18 V-01：相纸下系统的二级字只有 3.8:1，自检核对的 `secondary` 那时除了暗房没人用）。
///   - 深色主题判决色 / 客户紫的对比度：那是系统色，石墨也不许动，这里只核对色相。灰卡的栏和卡片是中灰，系统蓝 / 红 / 紫在上面
///     偏暗（卡片上 2.9–3.3:1、栏上 3.4–4.4:1）；其余四套深色在栏上 ≥ 4.7:1、卡片上 ≥ 4.1:1。
enum ThemeSelfTest {
    static func rgb(_ v: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    /// WCAG 相对亮度。
    static func luminance(_ v: UInt32) -> Double {
        let c = rgb(v)
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
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

    /// CIELAB 的彩度 C*（D65 白点）：这个灰带了多少色。人眼对「四周偏冷 / 偏暖」的感觉跟 C* 走，不跟 RGB 通道差走
    /// （同样差 10，亮的偏色比暗的显眼）。中性灰是 0；C* 1 以内看不出来。
    static func chroma(_ v: UInt32) -> Double {
        let c = rgb(v)
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double {
            let e = 6.0 / 29.0
            return t > e * e * e ? cbrt(t) : t / (3 * e * e) + 4.0 / 29.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        let a = 500 * (fx - fy)
        let bb = 200 * (fy - fz)
        return (a * a + bb * bb).squareRoot()
    }

    /// 前景以 alpha 叠在背景上（逐通道在 sRGB 值上混合，和 Core Graphics 默认一样）。
    static func blend(_ fg: UInt32, _ alpha: Double, over bg: UInt32) -> UInt32 {
        let f = rgb(fg), b = rgb(bg)
        func mix(_ x: Double, _ y: Double) -> UInt32 { UInt32((x * alpha + y * (1 - alpha)) * 255 + 0.5) }
        return (mix(f.r, b.r) << 16) | (mix(f.g, b.g) << 8) | mix(f.b, b.b)
    }

    /// 判决色、提醒黄、客户紫：深色主题没有自己的值，画出来的是系统色。
    static let markKeys = ["pick", "usable", "reject", "caution", "client"]

    /// 系统色在深色外观下的实际值。macOS 15 以前是 Apple HIG 里 macOS 的深色值；macOS 26 改过一次（红 3° → 359°、蓝 210° → 206°、
    /// 紫 280° → 293°），是在 26.5 上用 NSColor 在 darkAqua 下取的。两代都要过。
    static let systemDark: [(os: String, colors: [String: UInt32])] = [
        ("macOS 15", ["pick": 0x32D74B, "usable": 0x0A84FF, "reject": 0xFF453A, "caution": 0xFFD60A, "client": 0xBF5AF2]),
        ("macOS 26", ["pick": 0x30D158, "usable": 0x0091FF, "reject": 0xFF4245, "caution": 0xFFD600, "client": 0xDB34F2]),
    ]

    /// 选中框可能压着的东西：拼图成品的纸白（默认「极简纸白」）、纯白、墨黑（「墨黑」风格）、纯黑（审片四周、深色照片）。
    static let productPapers: [(String, UInt32)] = [("纸白", 0xF4F1EA), ("纯白", 0xFFFFFF), ("墨黑", 0x1D1D1F), ("纯黑", 0x000000)]

    static func run() -> Never {
        var failed = 0, checked = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            checked += 1
            if !ok { failed += 1; print("FAIL \(what())") }
        }
        func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

        for theme in AppThemeID.allCases {
            let colors = theme.colors
            let h = colors.hex
            func c(_ key: String) -> UInt32 { h[key]! }
            let name = theme.title
            let surfaces = ["bar", "panel", "card", "canvas"]

            // 字：正文在栏、卡片、顶栏上 ≥ 7:1；二级字（说明字、文件名、时间轴的标签）在这三处和放照片的底上 ≥ 4.5:1；
            // 三级字只在栏上 ≥ 3:1。
            for surface in ["bar", "panel", "card"] {
                check(contrast(c("text"), c(surface)) >= 7, "\(name)：正文在 \(surface) 上 \(fmt(contrast(c("text"), c(surface))))")
            }
            for surface in surfaces {
                let r = contrast(c("secondary"), c(surface))
                check(r >= 4.5, "\(name)：二级字在 \(surface) 上 \(fmt(r))")
            }
            for surface in ["bar", "panel"] {
                let r = contrast(c("tertiary"), c(surface))
                check(r >= 3, "\(name)：三级字在 \(surface) 上 \(fmt(r))")
            }

            // 点缀色：在栏、卡片、放照片的底上都要认得出（非文字 ≥ 3:1）；上面的字 ≥ 4.5:1。
            // 待处理色也当字用（状态栏、组头、ISO）：≥ 4.5:1；实心胶囊上的字（onWarning = onAccent）≥ 4.5:1。
            for surface in surfaces {
                check(contrast(c("accent"), c(surface)) >= 3, "\(name)：点缀色在 \(surface) 上 \(fmt(contrast(c("accent"), c(surface))))")
                check(contrast(c("warning"), c(surface)) >= 4.5, "\(name)：待处理色在 \(surface) 上 \(fmt(contrast(c("warning"), c(surface))))")
            }
            check(contrast(c("onAccent"), c("accent")) >= 4.5, "\(name)：主按钮上的字 \(fmt(contrast(c("onAccent"), c("accent"))))")
            check(contrast(c("onAccent"), c("warning")) >= 4.5, "\(name)：待处理胶囊上的字 \(fmt(contrast(c("onAccent"), c("warning"))))")

            // 判决色、提醒黄、客户紫实际画出来的值：浅色主题必须自己给（系统色是照深色底调的，系统黄在相纸上 1.1:1），
            // 小字在栏、卡片、放照片的底上 ≥ 4.5:1；深色主题没给的按系统色两代的值算。
            let own = h.filter { markKeys.contains($0.key) }
            let markSets: [(os: String, colors: [String: UInt32])]
            if colors.dark {
                markSets = systemDark.map { sys in (sys.os, sys.colors.merging(own) { _, mine in mine }) }
            } else {
                check(own.count == markKeys.count, "\(name)：浅色主题没给全判决色 / 提醒黄 / 客户紫（缺 \(markKeys.filter { own[$0] == nil })）")
                markSets = [("", own)]
                for key in markKeys {
                    guard let v = own[key] else { continue }
                    for surface in surfaces {
                        let r = contrast(v, c(surface))
                        check(r >= 4.5, "\(name)：\(key) 在 \(surface) 上 \(fmt(r))")
                    }
                }
            }

            let accent = hueSat(c("accent")), warning = hueSat(c("warning"))
            for set in markSets {
                guard let rejectHex = set.colors["reject"] else { continue }
                let os = set.os.isEmpty ? "" : "（\(set.os)）"
                // 点缀色带色的话，离判决色、客户紫的色相都要够远，离待处理色也要够远。提醒黄不算：琥珀和系统黄只差 14°，
                // 两个都表示「看这里」，靠亮度和用法分。
                if accent.sat > 0.15 {
                    for key in ["pick", "usable", "reject", "client"] {
                        guard let v = set.colors[key] else { continue }
                        let gap = hueGap(accent.hue, hueSat(v).hue)
                        check(gap >= 20, "\(name)\(os)：点缀色色相 \(Int(accent.hue))° 离 \(key)（\(Int(hueSat(v).hue))°）只有 \(Int(gap))°")
                    }
                    check(hueGap(accent.hue, warning.hue) >= 12, "\(name)：点缀色 \(Int(accent.hue))° 离待处理色 \(Int(warning.hue))° 太近")
                }
                // 待处理色和这一套自己的废片红（TA-06）：色相差 ≥ 15°，亮度比 ≥ 1.2（色弱时靠明暗分）。以前比的是写死的 3°，
                // 不查亮度：相纸的橙和红色相差 10°、亮度比 1.05:1 也过了。
                let rejectHue = hueSat(rejectHex).hue
                let gap = hueGap(warning.hue, rejectHue)
                check(gap >= 15, "\(name)\(os)：待处理色 \(Int(warning.hue))° 离废片红 \(Int(rejectHue))° 只有 \(Int(gap))°")
                let lum = contrast(c("warning"), rejectHex)
                check(lum >= 1.2, "\(name)\(os)：待处理色和废片红亮度比 \(fmt(lum))")
            }

            // 层次：壳 → 栏 → 卡片一级比一级亮；发丝线在栏上看得见。
            check(luminance(c("bar")) <= luminance(c("panel")) && luminance(c("panel")) < luminance(c("card")),
                  "\(name)：bar / panel / card 不是一级比一级亮")
            check(contrast(c("hairline"), c("panel")) >= 1.12, "\(name)：发丝线在 panel 上 \(fmt(contrast(c("hairline"), c("panel"))))")

            // 放照片的底（TB-07，按 CIELAB C* 算）：canvas 带的色不超过外壳的 3/4、而且 ≤ 5；暗房里照片四周不带色（C* ≤ 1）。
            // 以前比的是 RGB 通道差、只要求「≤ 外壳、≤ 10」，相纸的暗房四周比栏还带色也过了。
            let panelC = chroma(c("panel")), canvasC = chroma(c("canvas")), surroundC = chroma(c("surround"))
            check(canvasC <= max(0.75 * panelC, 1) && canvasC <= 5, "\(name)：canvas 带色 C* \(fmt(canvasC))（panel \(fmt(panelC))）")
            check(surroundC <= 1, "\(name)：暗房四周 surround 带色 C* \(fmt(surroundC))")
            check(colors.dark == (luminance(c("panel")) < 0.2), "\(name)：dark 标记和栏的亮度对不上")

            // 选中框（TB-01 / TA-05）：点缀色和两侧的 keyline 至少有一个在成品纸色、画布、卡片上 ≥ 3:1 —— 点缀色是白的那两套，
            // 压在纸白上靠 keyline。
            let keylineAlpha = AppPalette.selectionKeylineOpacity
            let backgrounds = productPapers + [("canvas", c("canvas")), ("card", c("card"))]
            for (label, bg) in backgrounds {
                let keyline = blend(c("onAccent"), keylineAlpha, over: bg)
                let best = max(contrast(c("accent"), bg), contrast(keyline, bg))
                check(best >= 3, "\(name)：选中框压在\(label)上 \(fmt(best))")
            }
            // 焦点框（TA-03）：深色白、浅色黑，0.95 不透明，画在放照片的底、栏（审片胶片条）、卡片上 ≥ 3:1。
            let ink: UInt32 = colors.dark ? 0xFFFFFF : 0x000000
            for surface in ["canvas", "bar", "card"] {
                let focus = blend(ink, 0.95, over: c(surface))
                check(contrast(focus, c(surface)) >= 3, "\(name)：焦点框在 \(surface) 上 \(fmt(contrast(focus, c(surface))))")
            }
            // 浅色主题的直方图（TA-09）：槽是卡片 / 栏压一点黑，留下的柱子、检视器的亮度柱、阈值线（ink 0.9）、
            // 被线淘汰的红柱（废片红 0.8）对槽都 ≥ 3:1。深色主题照旧是 v1.32.0 的写法，不在这里核对。
            if !colors.dark {
                let light = AppPalette.lightHistogram
                for surface in ["card", "panel"] {
                    let trough = blend(0x000000, light.trough, over: c(surface))
                    let marks: [(String, UInt32)] = [("留下的柱子", blend(0x000000, light.bar, over: trough)),
                                                     ("亮度柱", blend(0x000000, light.luma, over: trough)),
                                                     ("阈值线", blend(0x000000, 0.9, over: trough)),
                                                     ("红柱", blend(own["reject"] ?? 0xFF0000, 0.8, over: trough))]
                    for (label, mark) in marks {
                        check(contrast(mark, trough) >= 3, "\(name)：直方图\(label)在 \(surface) 的槽上 \(fmt(contrast(mark, trough)))")
                    }
                }
            }
            check(!theme.title.isEmpty && !theme.subtitle.isEmpty, "\(name)：没有名字")
        }
        // 默认主题的数值不能动：v1.30 起发出去的就是这一套。判决色、提醒黄、客户紫也不能给值（一直是系统色）。
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
