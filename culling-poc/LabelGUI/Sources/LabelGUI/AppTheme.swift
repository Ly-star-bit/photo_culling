import SwiftUI
import AppKit
import Observation

// MARK: - 全 app 一套设计语言（从暗房铺开）
//
// 暗房（CollageDarkroomView 的 DarkroomPalette）是先做出来的那一页：石墨灰的外壳、一种点缀色。批量页、水印页、拼图页以前各用
// 系统默认的材质和系统蓝，和暗房不像一个产品；蓝色还同时表示「可用」这个判决和「选中」。这里把暗房那几个灰和那个琥珀色
// 提出来给全 app 用：
//   - 顶栏、状态栏 = bar，两边的栏 = panel，栏里的卡片 = card，放照片的那一块 = canvas；
//   - 点缀色只有一个（accent）：选中、现在套着的、这一页的下一步。判决的颜色（绿 / 蓝 / 红）、客户的紫只表示它们自己。
//   - 主按钮是琥珀底深色字（系统的 borderedProminent 是白字，琥珀底上白字只有 1.9:1）。
//   - 「待处理 / 警告」另有一个偏红的橙（warning），不用系统橙：系统橙和琥珀几乎同色。
//
// 只管界面的颜色：导出的图一个像素不碰。

enum AppPalette {
    private static var c: ThemeColors { ThemeCenter.shared.colors }
    /// 顶栏、底下的状态栏、方案条。
    static var bar: Color { c.bar }
    /// 两边的栏（筛选、检视器、托盘、文件列表）。
    static var panel: Color { c.panel }
    /// 栏里的卡片、浮起来的控件。
    static var card: Color { c.card }
    static var hairline: Color { c.hairline }
    /// 放照片的那一块（网格、预览）：比两边的栏亮一点的中性灰，照片的黑不会和底糊在一起。
    static var canvas: Color { c.canvas }
    /// 唯一的点缀色。
    static var accent: Color { c.accent }
    /// 点缀色上面的字。
    static var onAccent: Color { c.onAccent }
    /// 「待处理 / 警告」：偏红的橙（石墨主题 #FF7A38）。不用系统橙：系统橙（深色下 #FF9F0A，色相 37°）和琥珀（#FFB340，36°）
    /// 几乎同色，分不出哪个是「该做的下一步 / 选中」、哪个是「还没处理」（优化分析 2026-11-10 R6）。这个色相 20°，夹在琥珀和
    /// 废片的系统红（3°）正中间；亮度也在中间，色弱时靠明暗也分得开。只表示「待处理 / 警告」，不当点缀色用。
    static var warning: Color { c.warning }
    /// 界面底色上叠的一层淡淡的亮 / 暗（卡片描边、未选中的胶囊底、悬停）：深色主题是白，浅色主题是黑，用的时候带 opacity。
    /// 只给界面底色上的东西用；压在照片上的字和黑底胶囊照旧写死黑白（照片不跟主题变）。
    static var ink: Color { c.dark ? .white : .black }
    /// 凹下去的槽（分段控件的底、九宫格的底）：深色主题压暗一档，浅色主题只压一点。
    static var well: Color { c.dark ? Color.black.opacity(0.35) : Color.black.opacity(0.07) }
    /// 判决的三个颜色：精选绿、可用蓝、废片红（摄影师的习惯色，每个主题都是这三个色相）。深色主题就是系统的绿 / 蓝 / 红；
    /// 浅色主题压深一档 —— 系统绿的小字在浅底上只有 2.2:1。
    static var pick: Color { c.pick }
    static var usable: Color { c.usable }
    static var reject: Color { c.reject }
}

// MARK: - 主题

/// 一套主题的颜色。只管界面：导出的图、照片本身、判决的绿 / 蓝 / 红、客户的紫都不跟着变。
struct ThemeColors: Equatable {
    var dark: Bool
    var bar, panel, card, hairline, canvas: Color
    /// 暗房：大预览四周、滑杆的槽。
    var surround, track: Color
    var text, secondary, tertiary: Color
    var accent, onAccent, warning: Color
    var pick = Color.green, usable = Color.blue, reject = Color.red
    /// 自检算对比度用的原始值（0xRRGGBB），和上面的 Color 一一对应。
    var hex: [String: UInt32]

    static func color(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    init(dark: Bool, bar: UInt32, panel: UInt32, card: UInt32, hairline: UInt32, canvas: UInt32, surround: UInt32, track: UInt32,
         text: UInt32, secondary: UInt32, tertiary: UInt32, accent: UInt32, onAccent: UInt32, warning: UInt32,
         verdicts: (pick: UInt32, usable: UInt32, reject: UInt32)? = nil) {
        let color = Self.color
        self.dark = dark
        self.bar = color(bar); self.panel = color(panel); self.card = color(card); self.hairline = color(hairline)
        self.canvas = color(canvas); self.surround = color(surround); self.track = color(track)
        self.text = color(text); self.secondary = color(secondary); self.tertiary = color(tertiary)
        self.accent = color(accent); self.onAccent = color(onAccent); self.warning = color(warning)
        hex = ["bar": bar, "panel": panel, "card": card, "hairline": hairline, "canvas": canvas, "surround": surround,
               "track": track, "text": text, "secondary": secondary, "tertiary": tertiary, "accent": accent,
               "onAccent": onAccent, "warning": warning]
        if let verdicts {
            pick = color(verdicts.pick); usable = color(verdicts.usable); reject = color(verdicts.reject)
            hex["pick"] = verdicts.pick; hex["usable"] = verdicts.usable; hex["reject"] = verdicts.reject
        }
    }
}

/// 能选的主题。rawValue 存进 UserDefaults（`ui.theme`），别改。
///
/// 怎么定的颜色：
///   - 每套只有一个点缀色。色相环上判决和状态已经占了红 3°、待处理 20°、绿 135°、蓝 211°、紫 280°，点缀色只落在空位上
///     （琥珀 / 黄铜 36°–40°、冰青 190°），或者干脆不带色（灰卡、纯黑是白）。
///   - 外壳可以带一点冷暖，放照片的那一块（canvas）只带外壳一半的色偏：四周的颜色会带偏人眼对照片冷暖的判断。
///   - 壳 → 栏 → 卡片一级比一级亮（浅色主题一样：卡片最白），每级差得不多，靠发丝线分开。
enum AppThemeID: String, CaseIterable, Identifiable {
    case graphite, neutral, walnut, midnight, black, paper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphite: return "石墨"
        case .neutral: return "灰卡"
        case .walnut: return "胡桃"
        case .midnight: return "午夜"
        case .black: return "纯黑"
        case .paper: return "相纸"
        }
    }

    var subtitle: String {
        switch self {
        case .graphite: return "默认 · 安全灯的琥珀"
        case .neutral: return "中灰 · 界面不带一点颜色"
        case .walnut: return "暖灰 · 黄铜"
        case .midnight: return "蓝灰 · 冰青"
        case .black: return "关了灯看片"
        case .paper: return "浅色 · 纸和赭石"
        }
    }

    var colors: ThemeColors {
        switch self {
        case .graphite:
            // v1.30 起的默认：纯中性的石墨灰 + 琥珀（暗房安全灯）。数值一个没动。
            return ThemeColors(dark: true, bar: 0x111111, panel: 0x1A1A1A, card: 0x242424, hairline: 0x2A2A2A, canvas: 0x212121,
                               surround: 0x2E2E2E, track: 0x3A3A3A, text: 0xEDEDED, secondary: 0xA3A3A3, tertiary: 0x6B6B6B,
                               accent: 0xFFB340, onAccent: 0x141414, warning: 0xFF7A38)
        case .neutral:
            // 灰卡：Lightroom / Capture One 那一路的中灰，点缀色也是灰白。界面上除了照片和判决没有别的颜色，看曝光、看肤色最稳。
            return ThemeColors(dark: true, bar: 0x2A2A2A, panel: 0x343434, card: 0x3F3F3F, hairline: 0x4A4A4A, canvas: 0x3C3C3C,
                               surround: 0x484848, track: 0x5A5A5A, text: 0xF4F4F4, secondary: 0xC4C4C4, tertiary: 0x969696,
                               accent: 0xF4F4F4, onAccent: 0x1C1C1C, warning: 0xFF8A4C)
        case .walnut:
            // 胡桃：带棕的深灰 + 黄铜，老暗房的木头和铜件。点缀色没用红铜：红铜（色相 17°）和「待处理」的橙（20°）撞色。
            return ThemeColors(dark: true, bar: 0x15110E, panel: 0x1F1A16, card: 0x2B2520, hairline: 0x362E28, canvas: 0x24211F,
                               surround: 0x2E2B29, track: 0x483E36, text: 0xF2EBE3, secondary: 0xB5A99D, tertiary: 0x7D7065,
                               accent: 0xE6BC74, onAccent: 0x1C150C, warning: 0xFF7A38)
        case .midnight:
            // 午夜：带蓝的深灰 + 冰青。青（色相 190°）落在「精选」的绿和「可用」的蓝中间，比两者都亮、都淡，不会认成判决。
            return ThemeColors(dark: true, bar: 0x0D1117, panel: 0x151A22, card: 0x1E2530, hairline: 0x28313D, canvas: 0x1B1E24,
                               surround: 0x282B30, track: 0x384250, text: 0xE6ECF2, secondary: 0x9AA7B5, tertiary: 0x66737F,
                               accent: 0x86DFEA, onAccent: 0x08181D, warning: 0xFF7A38)
        case .black:
            // 纯黑：关了灯在 OLED / XDR 上看片，屏幕上只剩照片。栏比底只亮一点，点缀色是白。
            return ThemeColors(dark: true, bar: 0x000000, panel: 0x0B0B0B, card: 0x171717, hairline: 0x232323, canvas: 0x000000,
                               surround: 0x101010, track: 0x2E2E2E, text: 0xEBEBEB, secondary: 0x9C9C9C, tertiary: 0x666666,
                               accent: 0xFFFFFF, onAccent: 0x000000, warning: 0xFF7A38)
        case .paper:
            // 相纸：纤维相纸的暖白、白卡片、墨色的字，点缀色是赭石。琥珀在浅底上读不出来（#FFB340 在白底上只有 1.8:1），压深了
            // 就是赭石；判决的绿 / 蓝 / 红、待处理的橙也各压深一档。
            return ThemeColors(dark: false, bar: 0xE8E4DB, panel: 0xF2EFE8, card: 0xFDFCF9, hairline: 0xD9D4C9, canvas: 0xDEDCD7,
                               surround: 0xD5D2CB, track: 0xC3BEB4, text: 0x22201C, secondary: 0x5E5A53, tertiary: 0x858078,
                               accent: 0xA65C10, onAccent: 0xFFFFFF, warning: 0xC8380A,
                               verdicts: (pick: 0x187A3A, usable: 0x0B63CE, reject: 0xC92A1E))
        }
    }
}

/// 现在套着哪个主题。`AppPalette` / `DarkroomPalette` 的每个颜色都从这里读；视图的 body 里读过，换主题时就跟着重画
/// （Observation：不用宏，自己记 access / mutation，命令行工具链也编得过）。
///
/// 开界面时从 UserDefaults 的 `ui.theme` 读、换了就写回去。无头（快照、自检、门禁）不读也不写 UserDefaults：
/// 一律石墨，除非环境变量 `LABELGUI_THEME=<id>` 指定。
final class ThemeCenter: Observable, @unchecked Sendable {
    static let shared = ThemeCenter()
    static let defaultsKey = "ui.theme"
    static let envKey = "LABELGUI_THEME"

    private let registrar = ObservationRegistrar()
    private var _id: AppThemeID
    private var _colors: ThemeColors

    private init() {
        let env = ProcessInfo.processInfo.environment[Self.envKey].flatMap(AppThemeID.init(rawValue:))
        let saved = AppRuntime.headless ? nil : UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(AppThemeID.init(rawValue:))
        _id = env ?? saved ?? .graphite
        _colors = _id.colors
    }

    var id: AppThemeID {
        get { registrar.access(self, keyPath: \.id); return _id }
        set {
            guard newValue != _id else { return }
            registrar.withMutation(of: self, keyPath: \.id) {
                _id = newValue
                _colors = newValue.colors
            }
            if !AppRuntime.headless { UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey) }
        }
    }

    var colors: ThemeColors {
        registrar.access(self, keyPath: \.id)
        return _colors
    }

    /// 离屏快照验「开着的时候换主题」：`LABELGUI_THEME_THEN=<id>` → 第一遍画完以后换成这个主题再截。截出来的图应该和直接
    /// 用 `LABELGUI_THEME=<id>` 起的一模一样；不一样的地方就是换主题时没跟着重画的（颜色读在了 body 外面、烤进了缓存）。
    @MainActor
    static func switchForSnapshot(window: NSWindow) -> Bool {
        guard let then = ProcessInfo.processInfo.environment["LABELGUI_THEME_THEN"].flatMap(AppThemeID.init(rawValue:)) else { return false }
        shared.id = then
        window.appearance = shared.appearance
        // 从不上屏的窗口换外观后，AppKit 的控件（复选框、分段控件）不会自己重画：真窗口会。这里手动标脏。
        func dirty(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(dirty) }
        window.contentView.map(dirty)
        return true
    }

    var scheme: ColorScheme { colors.dark ? .dark : .light }
    var appearance: NSAppearance? { NSAppearance(named: colors.dark ? .darkAqua : .aqua) }
}

/// 「显示」菜单里的「主题」。
struct ThemeMenu: View {
    var body: some View {
        Picker("主题", selection: Binding(get: { ThemeCenter.shared.id }, set: { ThemeCenter.shared.id = $0 })) {
            ForEach(AppThemeID.allCases) { Text("\($0.title)　\($0.subtitle)").tag($0) }
        }
    }
}

/// 状态栏右下角的主题按钮：点开是六张小样，点哪张立刻换（框不关，可以挨个试）。
struct ThemeButton: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "circle.lefthalf.filled") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("主题：\(ThemeCenter.shared.id.title)")
            .accessibilityLabel("主题")
            .popover(isPresented: $shown, arrowEdge: .top) { ThemePicker().appTheme() }
    }
}

/// 六张小样。每张是这个主题下窗口的缩影：顶栏、放照片的那一块、右边的栏和卡片、选中框、主按钮、三个判决色。
struct ThemePicker: View {
    var body: some View {
        let current = ThemeCenter.shared.id
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("主题").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("只换界面的颜色，照片和导出的图不变").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(ThemeSwatch.size.width), spacing: 12), count: 3), spacing: 12) {
                ForEach(AppThemeID.allCases) { theme in
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { ThemeCenter.shared.id = theme }
                    } label: {
                        ThemeSwatchCard(theme: theme, selected: theme == current)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.title)，\(theme.subtitle)")
                    .accessibilityAddTraits(theme == current ? .isSelected : [])
                }
            }
        }
        .padding(16)
        .background(AppPalette.panel)
    }
}

private struct ThemeSwatchCard: View {
    let theme: AppThemeID
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThemeSwatch(colors: theme.colors)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? AppPalette.accent : AppPalette.ink.opacity(hovered ? 0.35 : 0.14),
                                  lineWidth: selected ? 2 : 1))
                .padding(selected ? 0 : 0)
            HStack(spacing: 5) {
                Text(theme.title).font(.system(size: 12, weight: .semibold))
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(AppPalette.accent)
                }
            }
            Text(theme.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// 一个主题的缩影（纯画出来的，不读当前主题）。三张「照片」每个主题都是同一组颜色：看的是同样的照片放在这套底上什么样。
struct ThemeSwatch: View {
    let colors: ThemeColors
    static let size = CGSize(width: 148, height: 94)

    private static let photos: [(top: UInt32, bottom: UInt32)] = [
        (0x6FA3C7, 0xD9C3A0), (0x2B3340, 0xB5543C), (0x8FB3A0, 0x3D4A45),
    ]

    var body: some View {
        let ink = colors.dark ? Color.white : Color.black
        VStack(spacing: 0) {
            // 顶栏：左边两个控件，右边那一个主按钮。
            HStack(spacing: 4) {
                Capsule().fill(ink.opacity(0.22)).frame(width: 22, height: 5)
                Capsule().fill(ink.opacity(0.12)).frame(width: 14, height: 5)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(colors.accent).frame(width: 24, height: 8)
                    .overlay(Capsule().fill(colors.onAccent.opacity(0.85)).frame(width: 12, height: 2))
            }
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(colors.bar)
            Rectangle().fill(colors.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                // 放照片的那一块：三张照片、判决的小点，第一张选中。
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(LinearGradient(colors: [ThemeColors.color(Self.photos[i].top), ThemeColors.color(Self.photos[i].bottom)],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(height: 48)
                                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(i == 0 ? colors.accent : .clear, lineWidth: 1.5).padding(-2))
                            HStack(spacing: 3) {
                                Circle().fill([colors.pick, colors.usable, colors.reject][i]).frame(width: 4, height: 4)
                                Capsule().fill(colors.secondary.opacity(0.7)).frame(width: 14, height: 2.5)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(colors.canvas)
                Rectangle().fill(colors.hairline).frame(width: 0.5)
                // 右边的栏：一张卡片，里面一行字、一根滑杆；下面一行待处理。
                VStack(alignment: .leading, spacing: 5) {
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(colors.text.opacity(0.9)).frame(width: 20, height: 2.5)
                        Capsule().fill(colors.secondary.opacity(0.8)).frame(width: 28, height: 2.5)
                        ZStack(alignment: .leading) {
                            Capsule().fill(colors.track).frame(height: 2)
                            Capsule().fill(colors.accent).frame(width: 16, height: 2)
                            Circle().fill(Color.white).frame(width: 6, height: 6).offset(x: 13)
                                .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
                        }
                        .frame(height: 6)
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.card, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    HStack(spacing: 3) {
                        Capsule().fill(colors.warning).frame(width: 12, height: 5)
                        Capsule().fill(colors.tertiary).frame(width: 14, height: 2.5)
                    }
                    .padding(.leading, 2)
                }
                .padding(5)
                .frame(width: 46)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(colors.panel)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - 卡片

/// 全 app 的 GroupBox：一律撑满栏宽的石墨卡片。系统默认的 GroupBox 按内容收宽 —— 水印页四张只有一个开关的卡片各有各的宽度，
/// 批量页「本地模型」只有上面那张的一半宽，右边缘参差。
struct AppCardGroupBoxStyle: GroupBoxStyle {
    var card: Color = AppPalette.card
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            configuration.content
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - 主按钮

/// 这一页的下一步：琥珀底、深色字。大小跟着 controlSize（和旁边系统的按钮一样高）。
struct AccentProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        private var metrics: (font: Font, h: CGFloat, v: CGFloat, radius: CGFloat) {
            switch controlSize {
            case .mini: return (.system(size: 10, weight: .semibold), 6, 1.5, 4)
            case .small: return (.system(size: 11, weight: .semibold), 8, 2.5, 5)
            case .large, .extraLarge: return (.system(size: 13, weight: .semibold), 14, 6.5, 7)
            default: return (.system(size: 13, weight: .semibold), 10, 3, 6)
            }
        }

        var body: some View {
            let m = metrics
            configuration.label
                .font(m.font)
                .lineLimit(1)
                .foregroundStyle(isEnabled ? AppPalette.onAccent : AppPalette.ink.opacity(0.32))
                .padding(.horizontal, m.h)
                .padding(.vertical, m.v)
                .background(isEnabled ? AppPalette.accent.opacity(configuration.isPressed ? 0.78 : 1) : AppPalette.ink.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        }
    }
}

extension ButtonStyle where Self == AccentProminentButtonStyle {
    /// 代替 `.borderedProminent`。
    static var accentProminent: AccentProminentButtonStyle { AccentProminentButtonStyle() }
}

// MARK: - 说明字、整页的主题

extension View {
    /// 面板里的说明字：11pt 二级灰（以前到处是 10pt 三级灰，深色底上几乎读不出来）。
    func hintText() -> some View {
        font(.system(size: 11)).foregroundStyle(.secondary)
    }

    /// 一页的根上挂一次：点缀色、卡片样式、深 / 浅。弹出框、sheet 跟着环境走。
    func appTheme() -> some View { modifier(AppThemeModifier()) }

    /// 窗口的根上挂一次（只有真开界面的那几处）：窗口的标题栏、系统控件跟着主题的深 / 浅走，不跟随系统外观。
    func themedWindow() -> some View { modifier(ThemedWindowModifier()) }
}

private struct AppThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        let center = ThemeCenter.shared
        content
            .tint(center.colors.accent)
            .groupBoxStyle(AppCardGroupBoxStyle(card: center.colors.card))
            .environment(\.colorScheme, center.scheme)
    }
}

private struct ThemedWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.preferredColorScheme(ThemeCenter.shared.scheme)
    }
}
