import SwiftUI
import AppKit

// MARK: - 全 app 一套设计语言（从暗房铺开）
//
// 暗房（CollageDarkroomView 的 DarkroomPalette）是先做出来的那一页：石墨灰的外壳、一种点缀色。批量页、水印页、拼图页以前各用
// 系统默认的材质和系统蓝，和暗房不像一个产品；蓝色还同时表示「可用」这个判决和「选中」。这里把暗房那几个灰和那个琥珀色
// 提出来给全 app 用：
//   - 顶栏、状态栏 = bar，两边的栏 = panel，栏里的卡片 = card，放照片的那一块 = canvas；
//   - 点缀色只有一个（accent）：选中、现在套着的、这一页的下一步。判决的颜色（绿 / 蓝 / 红）、客户的紫只表示它们自己。
//   - 主按钮是琥珀底深色字（系统的 borderedProminent 是白字，琥珀底上白字只有 1.9:1）。
//
// 只管界面的颜色：导出的图一个像素不碰。

enum AppPalette {
    /// 顶栏、底下的状态栏、方案条。
    static let bar = DarkroomPalette.shell
    /// 两边的栏（筛选、检视器、托盘、文件列表）。
    static let panel = DarkroomPalette.sidebar
    /// 栏里的卡片、浮起来的控件。
    static let card = DarkroomPalette.raised
    static let hairline = DarkroomPalette.hairline
    /// 放照片的那一块（网格、预览）：比两边的栏亮一点的中性灰，照片的黑不会和底糊在一起。
    static let canvas = Color(white: 0x21 / 255.0)
    /// 唯一的点缀色。
    static let accent = DarkroomPalette.accent
    /// 点缀色上面的字。
    static let onAccent = Color(white: 0x14 / 255.0)
}

// MARK: - 卡片

/// 全 app 的 GroupBox：一律撑满栏宽的石墨卡片。系统默认的 GroupBox 按内容收宽 —— 水印页四张只有一个开关的卡片各有各的宽度，
/// 批量页「本地模型」只有上面那张的一半宽，右边缘参差。
struct AppCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            configuration.content
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .foregroundStyle(isEnabled ? AppPalette.onAccent : Color.white.opacity(0.32))
                .padding(.horizontal, m.h)
                .padding(.vertical, m.v)
                .background(isEnabled ? AppPalette.accent.opacity(configuration.isPressed ? 0.78 : 1) : Color.white.opacity(0.08),
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

    /// 一页的根上挂一次：点缀色、卡片样式。弹出框、sheet 跟着环境走。
    func appTheme() -> some View {
        tint(AppPalette.accent).groupBoxStyle(AppCardGroupBoxStyle())
    }
}
