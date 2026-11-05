import SwiftUI
import AppKit

/// 暗房工作台（状态和规则见 CollageDarkroom.swift）。整页换掉拼图页（和批量页的审片、连拍挑选一样：画布不在
/// 视图树里，它的 ←→「换一版」就不会和这里的 ←→ 抢），强制深色。
///
/// 视觉：老暗房 —— 打字机字 + 宋体标题、琥珀安全灯、看片台上的底片条 / 片框 / 相纸小样、红色蜡笔圈选、遮蔽胶带
/// 标签、带刻度的滑杆和机械计数窗、圆形放大镜，外壳上一层很淡的颗粒。
/// 颜色规矩：图片四周一律中性灰（四周染了色，看色调会偏）；琥珀只用在灯、片边字、读数上（彩色相纸的暗房用琥珀灯，
/// 红灯是黑白的）；红色只表示「选中」，配对勾（红色盲、强调色是红的用户也认得出）。
/// 形态：135 底片条的齿孔、反转片的片框、电影片的方齿孔和声带都是通用的功能形态；不画胶卷盒、不画色带、
/// 不用粗体大写字标，片边只印 ▶帧号 + 名字和 SAFETY FILM（商标红线，reports/胶片模拟调研_2026-11-05/R7）。
struct CollageDarkroomView: View {
    @ObservedObject var model: CollageDarkroom
    @ObservedObject var store: CollageStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            DarkroomTopBar(model: model, store: store)
            DarkroomRule()
            HStack(spacing: 0) {
                DarkroomLightTable(model: model)
                    .frame(width: 344)
                DarkroomRule(vertical: true)
                DarkroomPreview(model: model)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                DarkroomRule(vertical: true)
                DarkroomControls(model: model, store: store)
                    .frame(width: 304)
            }
            DarkroomRule()
            DarkroomReel(model: model, store: store)
                .frame(height: 146)
        }
        .background(DarkroomChrome(color: DarkroomPalette.room))
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.moveFocus(-1); return .handled }
        .onKeyPress(.rightArrow) { model.moveFocus(1); return .handled }
        .onKeyPress(.upArrow) { model.moveFocus(-2); return .handled }
        .onKeyPress(.downArrow) { model.moveFocus(2); return .handled }
        .onKeyPress(.return) { model.apply(model.focus); return .handled }
        .onKeyPress(.space, phases: [.down, .up]) { press in
            model.showOriginal = press.phase == .down
            return .handled
        }
    }
}

// MARK: - 设计语言

enum DarkroomPalette {
    /// 外壳：带一点暖的近黑（像暗房的墙），图片四周不用它。
    static let room = Color(red: 0.055, green: 0.05, blue: 0.046)
    static let panel = Color(red: 0.083, green: 0.077, blue: 0.072)
    /// 看片台、预览四周：中性灰，不带色。
    static let table = Color(white: 0.15)
    static let surround = Color(white: 0.19)
    /// 片基：印样上是黑的，带一点暖。
    static let rebate = Color(red: 0.05, green: 0.045, blue: 0.04)
    /// 齿孔透着看片台的光。
    static let hole = Color(red: 0.84, green: 0.82, blue: 0.77)
    /// 安全灯、片边字、读数（#FFB340；深色底上 9:1）。
    static let amber = Color(red: 1, green: 0.702, blue: 0.251)
    static let amberDim = Color(red: 0.62, green: 0.45, blue: 0.2)
    /// 红色蜡笔：只表示选中（#FF453A；深色底上 4.9:1，配对勾）。
    static let pen = Color(red: 1, green: 0.271, blue: 0.227)
    /// 幻灯片框（通用灰白塑料，不带字标）。
    static let mount = Color(red: 0.86, green: 0.85, blue: 0.81)
    /// 相纸小样的白边。
    static let paper = Color(red: 0.94, green: 0.925, blue: 0.89)
    /// 遮蔽胶带。
    static let tape = Color(red: 0.9, green: 0.86, blue: 0.75)
    static let tapeInk = Color(red: 0.22, green: 0.19, blue: 0.14)
    static let text = Color(white: 0.9)
    static let dim = Color(white: 0.55)
}

enum DarkroomFont {
    /// 宋体标题（印刷品的味道）。
    static func title(_ size: CGFloat) -> Font { .custom("Songti SC", size: size).weight(.bold) }
    /// 打字机字：英文小标、片边、标签。
    static func type(_ size: CGFloat) -> Font { .custom("American Typewriter", size: size) }
    /// 读数：等宽数字。
    static func digits(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
    static func label(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
}

/// 外壳底色 + 一层很淡的颗粒（只铺在外壳上，不压任何图片）。
private struct DarkroomChrome: View {
    let color: Color
    var body: some View {
        ZStack {
            color
            Image(nsImage: DarkroomGrain.tile)
                .resizable(resizingMode: .tile)
                .opacity(0.07)
                .blendMode(.screen)
                .allowsHitTesting(false)
        }
    }
}

enum DarkroomGrain {
    /// 160² 的灰度噪声（种子固定：每次一样）。
    static let tile: NSImage = {
        let n = 160
        var rng = SeededRandom(seed: 19_861_105)
        var bytes = [UInt8](repeating: 0, count: n * n)
        for i in 0..<(n * n) { bytes[i] = UInt8(truncatingIfNeeded: Int(rng.next() % 256)) }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: n, height: n))
    }()
}

/// 分隔线：一道暗、一道亮，像钣金接缝。
private struct DarkroomRule: View {
    var vertical = false
    var body: some View {
        if vertical {
            HStack(spacing: 0) {
                Color.black.frame(width: 1)
                Color.white.opacity(0.05).frame(width: 1)
            }
        } else {
            VStack(spacing: 0) {
                Color.black.frame(height: 1)
                Color.white.opacity(0.05).frame(height: 1)
            }
        }
    }
}

/// 琥珀安全灯（亮着）。
private struct DarkroomLamp: View {
    var body: some View {
        ZStack {
            Circle().fill(DarkroomPalette.amber.opacity(0.25)).frame(width: 22, height: 22).blur(radius: 5)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.88, blue: 0.6), DarkroomPalette.amber,
                                              Color(red: 0.6, green: 0.32, blue: 0.05)],
                                     center: UnitPoint(x: 0.38, y: 0.35), startRadius: 0, endRadius: 7))
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
        }
        .accessibilityHidden(true)
    }
}

/// 小标题：序号（琥珀）+ 宋体中文 + 打字机英文。
private struct DarkroomHeading: View {
    let number: String?
    let title: String
    let english: String
    var trailing: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let number {
                    Text(number).font(DarkroomFont.digits(10)).foregroundStyle(DarkroomPalette.amber)
                }
                Text(title).font(DarkroomFont.title(15)).foregroundStyle(DarkroomPalette.text)
                Text(english).font(DarkroomFont.type(9.5)).tracking(2.2).foregroundStyle(DarkroomPalette.dim)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(DarkroomFont.type(9.5)).foregroundStyle(DarkroomPalette.dim)
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.5)
                .mask(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 遮蔽胶带标签：米色、两头撕口、打字机字、歪一点。
private struct DarkroomTape: View {
    let text: String
    var angle: Double = -2

    var body: some View {
        Text(text)
            .font(DarkroomFont.type(11))
            .foregroundStyle(DarkroomPalette.tapeInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 3.5)
            .background(TapeShape().fill(DarkroomPalette.tape.opacity(0.94)))
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            .rotationEffect(.degrees(angle))
    }
}

/// 胶带：左右两头是撕出来的锯齿。
private struct TapeShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let teeth = max(3, Int(r.height / 3))
        let step = r.height / CGFloat(teeth)
        p.move(to: CGPoint(x: r.minX + 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2, y: r.minY))
        for i in 0..<teeth {
            let y = r.minY + CGFloat(i) * step
            p.addLine(to: CGPoint(x: r.maxX - (i % 2 == 0 ? 0 : 2.5), y: y + step * 0.5))
            p.addLine(to: CGPoint(x: r.maxX - 2, y: y + step))
        }
        p.addLine(to: CGPoint(x: r.minX + 2, y: r.maxY))
        for i in 0..<teeth {
            let y = r.maxY - CGFloat(i) * step
            p.addLine(to: CGPoint(x: r.minX + (i % 2 == 0 ? 0 : 2.5), y: y - step * 0.5))
            p.addLine(to: CGPoint(x: r.minX + 2, y: y - step))
        }
        p.closeSubpath()
        return p
    }
}

/// 红色蜡笔圈：手画的不规整方框（四边各歪一点、角上出头），seed 定死同一格每次一样。
private struct GreasePencilFrame: Shape {
    var seed: Int

    func path(in r: CGRect) -> Path {
        func j(_ i: Int) -> CGFloat {
            var h = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ i &* 40_503)
            h ^= h >> 13
            h = h &* 0x5bd1e995
            h ^= h >> 15
            return CGFloat(Int(h % 1000)) / 1000 * 4 - 2
        }
        var p = Path()
        p.move(to: CGPoint(x: r.minX - 3, y: r.minY + j(0)))
        p.addQuadCurve(to: CGPoint(x: r.maxX + 2.5, y: r.minY + j(1)),
                       control: CGPoint(x: r.midX, y: r.minY - 1.2 + j(2)))
        p.move(to: CGPoint(x: r.maxX + j(3), y: r.minY - 3))
        p.addQuadCurve(to: CGPoint(x: r.maxX + j(4), y: r.maxY + 2.5),
                       control: CGPoint(x: r.maxX + 1.2 + j(5), y: r.midY))
        p.move(to: CGPoint(x: r.maxX + 3, y: r.maxY + j(6)))
        p.addQuadCurve(to: CGPoint(x: r.minX - 2, y: r.maxY + j(7)),
                       control: CGPoint(x: r.midX, y: r.maxY + 1.2 + j(8)))
        p.move(to: CGPoint(x: r.minX + j(9), y: r.maxY + 3))
        p.addQuadCurve(to: CGPoint(x: r.minX + j(10), y: r.minY - 1),
                       control: CGPoint(x: r.minX - 1.2 + j(11), y: r.midY))
        return p
    }
}

/// 红色蜡笔圈：两遍（第二遍细一点、错开一点），像蜡笔在相纸上描的。
private struct DarkroomCrayonMark: View {
    let seed: Int
    var body: some View {
        ZStack {
            GreasePencilFrame(seed: seed)
                .stroke(DarkroomPalette.pen, style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            GreasePencilFrame(seed: seed &+ 101)
                .stroke(DarkroomPalette.pen.opacity(0.55), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .offset(x: 0.8, y: -0.6)
        }
        .shadow(color: .black.opacity(0.45), radius: 1)
        .allowsHitTesting(false)
    }
}

/// 蜡笔打的勾。
private struct GreasePencilCheck: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.minX + r.width * 0.55, y: r.midY))
        return p
    }
}

/// 带刻度的推子 + 机械计数窗（琥珀数字）。无障碍那边是一根普通的 Slider。
private struct DarkroomSlider: View {
    let label: String
    let value: Double
    let set: (Double) -> Void
    var help: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(DarkroomFont.label(12)).foregroundStyle(DarkroomPalette.text)
                .frame(width: 54, alignment: .leading)
            GeometryReader { geo in
                let knob: CGFloat = 11
                let travel = max(1, geo.size.width - knob)
                let x = CGFloat(min(1, max(0, value))) * travel
                ZStack(alignment: .leading) {
                    Canvas { ctx, size in
                        for i in 0...10 {
                            let tx = knob / 2 + CGFloat(i) / 10 * travel
                            let major = i % 5 == 0
                            ctx.fill(Path(CGRect(x: tx - 0.5, y: major ? 0 : 2, width: 1, height: major ? 5 : 3)),
                                     with: .color(.white.opacity(major ? 0.5 : 0.22)))
                        }
                    }
                    .frame(height: 5)
                    .offset(y: -11)
                    Capsule().fill(Color.black.opacity(0.75)).frame(height: 5)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
                    Capsule()
                        .fill(LinearGradient(colors: [DarkroomPalette.amberDim, DarkroomPalette.amber],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: x + knob / 2, height: 3)
                        .padding(.leading, 1)
                        .opacity(0.85)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.5), Color(white: 0.62)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: knob, height: 19)
                        .overlay(VStack(spacing: 2.5) {
                            ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.35)).frame(width: 6, height: 0.8) }
                        })
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.6), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1.5)
                        .offset(x: x)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    set(Double(min(1, max(0, (v.location.x - knob / 2) / travel))))
                })
            }
            .frame(height: 30)
            DarkroomCounter(value: value)
        }
        .help(help)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: set), in: 0...1) { Text(label) }
        }
    }
}

/// 机械计数窗：黑底、琥珀数字、三位。
private struct DarkroomCounter: View {
    let value: Double
    var body: some View {
        HStack(spacing: 1) {
            Text(String(format: "%03d", Int((min(1, max(0, value)) * 100).rounded())))
                .font(DarkroomFont.digits(11.5))
                .foregroundStyle(DarkroomPalette.amber)
                .shadow(color: DarkroomPalette.amber.opacity(0.5), radius: 2)
            Text("%").font(DarkroomFont.digits(8.5)).foregroundStyle(DarkroomPalette.amberDim)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        .background(RoundedRectangle(cornerRadius: 2.5).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7))
        .frame(width: 50, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

// MARK: - 顶栏

private struct DarkroomTopBar: View {
    @ObservedObject var model: CollageDarkroom
    @ObservedObject var store: CollageStore

    var body: some View {
        HStack(spacing: 14) {
            DarkroomLamp()
            VStack(alignment: .leading, spacing: 0) {
                Text("暗房").font(DarkroomFont.title(18)).foregroundStyle(DarkroomPalette.text)
                Text(store.isAlbum ? "DARKROOM · SPREAD \(String(format: "%02d", store.pageIndex + 1))" : "DARKROOM")
                    .font(DarkroomFont.type(8.5)).tracking(2.6).foregroundStyle(DarkroomPalette.amberDim)
            }
            Spacer(minLength: 16)
            Text("套用到").font(DarkroomFont.type(11)).foregroundStyle(DarkroomPalette.dim)
            DarkroomScopePicker(model: model)
            Spacer(minLength: 16)
            DarkroomReadout(model: model)
            Button {
                store.closeDarkroom()
            } label: {
                Text("完成").font(DarkroomFont.label(12.5))
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DarkroomPalette.amber.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("回到拼图（Esc）。暗房里的改动都已经套上了，⌘Z 一步步撤")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(DarkroomChrome(color: DarkroomPalette.panel))
    }
}

/// 「套用到」：一排拨杆，选中的那个亮琥珀小灯。
private struct DarkroomScopePicker: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        let scopes: [CollageDarkroom.Scope] = model.pageAvailable ? [.project, .page, .cell] : [.project, .cell]
        HStack(spacing: 2) {
            ForEach(scopes) { s in
                let on = model.effectiveScope == s
                let enabled = s != .cell || model.cellAvailable
                Button {
                    model.scope = s
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(on ? DarkroomPalette.amber : Color(white: 0.22))
                            .frame(width: 6, height: 6)
                            .shadow(color: on ? DarkroomPalette.amber : .clear, radius: 3)
                        Text(s.label).font(DarkroomFont.label(12))
                            .foregroundStyle(on ? DarkroomPalette.text : DarkroomPalette.dim)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(on ? Color.white.opacity(0.07) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help(s == .cell && !enabled ? "先在底下的底片条里点一格" : "色调和强度改「\(s.label)」")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7))
    }
}

/// 读数窗：像暗房计时器 —— 现在看的那一款、强度。
private struct DarkroomReadout: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        let look = model.hover ?? model.current.look
        let number = CollageDarkroom.frameNumber(look).map { String(format: "▶%02d", $0) } ?? "▶--"
        HStack(spacing: 8) {
            Text(model.hover == nil ? "ON" : "VIEW")
                .font(DarkroomFont.type(8)).tracking(1.5).foregroundStyle(DarkroomPalette.amberDim)
            Text("\(number) \(look.label)")
                .font(DarkroomFont.digits(12))
                .foregroundStyle(DarkroomPalette.amber)
                .shadow(color: DarkroomPalette.amber.opacity(0.55), radius: 2.5)
            Text(String(format: "%03d%%", Int((model.current.strength * 100).rounded())))
                .font(DarkroomFont.digits(10)).foregroundStyle(DarkroomPalette.amberDim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("现在：\(look.label)，强度 \(Int((model.current.strength * 100).rounded()))%")
    }
}

// MARK: - 看片台

private struct DarkroomLightTable: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(CollageDarkroom.groups) { group in
                    VStack(alignment: .leading, spacing: 9) {
                        DarkroomHeading(number: nil, title: group.title, english: english(group.kind),
                                        trailing: group.kind == .filter ? "无颗粒 · 无晕光" : String(format: "%02d", group.looks.count))
                        switch group.kind {
                        case .negative:
                            ForEach(Array(stride(from: 0, to: group.looks.count, by: 2)), id: \.self) { i in
                                // 手放在看片台上的：每条歪一点点。
                                DarkroomFilmStrip(model: model, looks: Array(group.looks[i..<min(i + 2, group.looks.count)]))
                                    .rotationEffect(.degrees([-0.35, 0.25, -0.15][(i / 2) % 3]))
                            }
                        case .slide:
                            HStack(spacing: 9) {
                                ForEach(Array(group.looks.enumerated()), id: \.element) { i, look in
                                    DarkroomSlideMount(model: model, look: look)
                                        .rotationEffect(.degrees([-1.2, 0.6, -0.4][i % 3]))
                                }
                            }
                        case .cine:
                            DarkroomCineStrip(model: model, look: group.looks[0])
                                .rotationEffect(.degrees(0.3))
                        case .filter:
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                                ForEach(group.looks, id: \.self) { look in
                                    DarkroomPrintTile(model: model, look: look)
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(
            LinearGradient(colors: [Color(white: 0.165), Color(white: 0.135)], startPoint: .top, endPoint: .bottom)
        )
    }

    private func english(_ kind: CollageDarkroom.Kind) -> String {
        switch kind {
        case .negative: return "NEGATIVE"
        case .slide: return "REVERSAL"
        case .cine: return "MOTION PICTURE"
        case .filter: return "PRINTS"
        }
    }
}

/// 一格样张：悬停 = 预览（抬起来一点），点 = 套用；选中是红色蜡笔圈 + 勾，键盘焦点是白色虚线。
private struct DarkroomFrameImage: View {
    @ObservedObject var model: CollageDarkroom
    let look: CollageLook
    var corner: CGFloat = 1.5
    var aspect: CGFloat = 3 / 2

    var body: some View {
        let applied = model.current.look == look
        let focused = model.focus == look && !applied
        let hovered = model.hover == look
        ZStack {
            DarkroomPalette.surround
            if let image = model.frames[look] {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: corner + 1)
                    .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .padding(-2.5)
            }
        }
        .overlay {
            if applied {
                DarkroomCrayonMark(seed: look.rawValue.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
                    .padding(-3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if applied {
                GreasePencilCheck()
                    .stroke(DarkroomPalette.pen, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 13, height: 10)
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.55)).frame(width: 20, height: 20))
                    .padding(3)
            }
        }
        .scaleEffect(hovered ? 1.035 : 1)
        .shadow(color: .black.opacity(hovered ? 0.6 : 0), radius: hovered ? 6 : 0, y: hovered ? 3 : 0)
        .zIndex(hovered ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hover = look } else if model.hover == look { model.hover = nil }
        }
        .onTapGesture { model.apply(look) }
        .help("\(look.label)（\(CollageDarkroom.kindLabel(look))）：悬停预览，点一下套用")
        .accessibilityElement()
        .accessibilityLabel("\(look.label)，\(CollageDarkroom.kindLabel(look))"
                            + (CollageDarkroom.frameNumber(look).map { "，第 \($0) 帧" } ?? "")
                            + (applied ? "，已选中" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.apply(look) }
    }
}

/// 135 底片条：上下一排齿孔，片边印 ▶帧号 名字，末尾 SAFETY FILM。
private struct DarkroomFilmStrip: View {
    @ObservedObject var model: CollageDarkroom
    let looks: [CollageLook]

    var body: some View {
        VStack(spacing: 3) {
            DarkroomSprockets(square: false)
            HStack(spacing: 9) {
                ForEach(looks, id: \.self) { look in
                    DarkroomFrameImage(model: model, look: look)
                }
                if looks.count < 2 { Color.clear.aspectRatio(3 / 2, contentMode: .fit) }
            }
            .padding(.horizontal, 7)
            HStack(spacing: 9) {
                ForEach(looks, id: \.self) { look in
                    DarkroomEdgeText(CollageDarkroom.edgeText(look))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if looks.count < 2 { Spacer() }
            }
            .padding(.horizontal, 9)
            .overlay(alignment: .trailing) {
                DarkroomEdgeText(CollageDarkroom.rebateText).opacity(0.5).padding(.trailing, 9)
            }
            DarkroomSprockets(square: false)
        }
        .padding(.vertical, 4)
        .background(DarkroomPalette.rebate)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
    }
}

/// 片边字：琥珀、打字机小字。
private struct DarkroomEdgeText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DarkroomFont.type(9.5))
            .tracking(0.8)
            .foregroundStyle(DarkroomPalette.amber)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

/// 一排齿孔：135 是竖长的圆角孔，电影片是方孔、更密。孔里透着看片台的光（上亮下暗一点）。
private struct DarkroomSprockets: View {
    let square: Bool

    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = square ? 4.2 : 5.2
            let h: CGFloat = square ? 4.2 : 6.6
            let pitch: CGFloat = square ? 7.6 : 11
            var x: CGFloat = 5
            let shading = Gradient(colors: [DarkroomPalette.hole, DarkroomPalette.hole.opacity(0.72)])
            while x + w < size.width - 3 {
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: square ? 0.6 : 1.3),
                         with: .linearGradient(shading, startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                               endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                x += pitch
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// 反转片：装在通用的灰白片框里，框下沿打字机写 ▶帧号 名字。
private struct DarkroomSlideMount: View {
    @ObservedObject var model: CollageDarkroom
    let look: CollageLook

    var body: some View {
        VStack(spacing: 5) {
            DarkroomFrameImage(model: model, look: look, corner: 1)
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.85)))
                .padding(.horizontal, 7)
                .padding(.top, 8)
            Text(CollageDarkroom.edgeText(look))
                .font(DarkroomFont.type(9.5))
                .foregroundStyle(Color(white: 0.3))
                .lineLimit(1)
                .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [DarkroomPalette.mount, Color(red: 0.76, green: 0.75, blue: 0.71)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.5), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
    }
}

/// 电影负片：方齿孔、左边一道变面积声带，画面宽一点。
private struct DarkroomCineStrip: View {
    @ObservedObject var model: CollageDarkroom
    let look: CollageLook

    var body: some View {
        VStack(spacing: 3) {
            DarkroomSprockets(square: true)
            HStack(spacing: 7) {
                DarkroomSoundtrack().frame(width: 11)
                DarkroomFrameImage(model: model, look: look, aspect: 1.85)
            }
            .padding(.horizontal, 7)
            HStack {
                DarkroomEdgeText(CollageDarkroom.edgeText(look))
                Spacer()
                DarkroomEdgeText(CollageDarkroom.rebateText).opacity(0.5)
            }
            .padding(.horizontal, 9)
            DarkroomSprockets(square: true)
        }
        .padding(.vertical, 4)
        .background(DarkroomPalette.rebate)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
    }
}

/// 变面积光学声带：一道左右对称起伏的亮带。
private struct DarkroomSoundtrack: View {
    var body: some View {
        Canvas { ctx, size in
            let mid = size.width / 2
            var y: CGFloat = 0
            var i = 0
            while y < size.height {
                let a = (sin(Double(i) * 0.9) * 0.5 + sin(Double(i) * 0.37) * 0.35 + 0.15) * 0.5 + 0.5
                let half = CGFloat(a) * (size.width / 2 - 1)
                ctx.fill(Path(CGRect(x: mid - half, y: y, width: half * 2, height: 1.4)),
                         with: .color(DarkroomPalette.hole.opacity(0.55)))
                y += 1.6
                i += 1
            }
        }
        .accessibilityHidden(true)
    }
}

/// 滤镜：相纸小样（白边），不穿底片的外衣 —— 一眼看得出它不是胶片、没有颗粒晕光。
private struct DarkroomPrintTile: View {
    @ObservedObject var model: CollageDarkroom
    let look: CollageLook

    var body: some View {
        VStack(spacing: 4) {
            DarkroomFrameImage(model: model, look: look, corner: 0.5)
                .padding(3)
                .background(DarkroomPalette.paper)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1.5)
            Text(look.label).font(DarkroomFont.type(9.5)).foregroundStyle(DarkroomPalette.dim).lineLimit(1)
        }
    }
}

// MARK: - 大预览

private struct DarkroomPreview: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        GeometryReader { geo in
            let area = CGSize(width: max(10, geo.size.width - 72), height: max(10, geo.size.height - 92))
            ZStack {
                RadialGradient(colors: [Color(white: 0.2), Color(white: 0.085)], center: .center,
                               startRadius: 40, endRadius: max(geo.size.width, geo.size.height) * 0.72)
                if let image = model.processed {
                    let fitted = fit(image.size, in: area)
                    VStack(spacing: 18) {
                        printView(image, fitted)
                        Text("悬停预览 · ←→ 换片 · ⏎ 套用 · 按住空格看原图 · Esc 回拼图")
                            .font(DarkroomFont.type(10)).tracking(0.6).foregroundStyle(DarkroomPalette.dim)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("冲洗中…").font(DarkroomFont.type(11)).foregroundStyle(DarkroomPalette.dim)
                    }
                }
            }
            .onAppear { report(geo.size) }
            .onChange(of: geo.size) { report(geo.size) }
        }
    }

    private func printView(_ image: NSImage, _ fitted: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image).resizable().interpolation(.high)
            if let original = model.original, model.showOriginal || model.split > 0.001 {
                Image(nsImage: original).resizable().interpolation(.high)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: fitted.width * (model.showOriginal ? 1 : model.split))
                    }
            }
            loupeMarker(fitted)
        }
        .frame(width: fitted.width, height: fitted.height)
        .onTapGesture(coordinateSpace: .local) { p in
            let c = model.store.project.canvas
            model.loupeAnchor = CGPoint(x: p.x / fitted.width * Double(c.width), y: p.y / fitted.height * Double(c.height))
        }
        .overlay(alignment: .leading) {
            if !model.showOriginal { divider(fitted) }
        }
        .shadow(color: .black.opacity(0.65), radius: 14, y: 6)
        .background(CropMarks().stroke(Color.white.opacity(0.35), lineWidth: 0.8).padding(-14))
        .overlay(alignment: .topLeading) {
            if model.showOriginal || model.split > 0.08 {
                DarkroomTape(text: "原图", angle: -3).offset(x: -10, y: -12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !model.showOriginal && model.split < 0.92 {
                DarkroomTape(text: model.hover.map { "预览 · \($0.label)" } ?? "成片 · \(model.current.look.label)",
                             angle: 2.5)
                    .offset(x: 10, y: -12)
            }
        }
    }

    private func report(_ size: CGSize) {
        let s = NSScreen.main?.backingScaleFactor ?? 2
        model.previewPixels = CGSize(width: (size.width - 72) * s, height: (size.height - 92) * s)
    }

    private func fit(_ image: CGSize, in area: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return area }
        let k = min(area.width / image.width, area.height / image.height)
        return CGSize(width: image.width * k, height: image.height * k)
    }

    /// 对比竖线：拖着走，左边原图、右边成片；拖到最左 = 全是成片。
    private func divider(_ fitted: CGSize) -> some View {
        let x = fitted.width * model.split
        return ZStack {
            Rectangle().fill(Color.white.opacity(0.92)).frame(width: 1.2)
                .shadow(color: .black.opacity(0.6), radius: 1.5)
            VStack(spacing: 0) {
                Image(systemName: "arrowtriangle.left.fill")
                Image(systemName: "arrowtriangle.right.fill")
            }
            .font(.system(size: 6.5))
            .foregroundStyle(DarkroomPalette.tapeInk)
            .padding(.horizontal, 3).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 2).fill(DarkroomPalette.tape))
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        }
        .frame(width: 26, height: fitted.height)
        .contentShape(Rectangle())
        .offset(x: x - 13)
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            model.split = min(1, max(0, (x + v.translation.width) / fitted.width))
        })
        .opacity(model.split > 0.001 ? 1 : 0.65)
        .help("拖竖线对比：左边原图、右边成片；拖到最左就全是成片")
        .accessibilityLabel("对比竖线")
        .accessibilityValue("原图占 \(Int(model.split * 100))%")
    }

    /// 放大镜看的位置：琥珀十字准星。
    private func loupeMarker(_ fitted: CGSize) -> some View {
        let c = model.store.project.canvas
        let p = model.loupeCenter
        return ZStack {
            Circle().strokeBorder(DarkroomPalette.amber, lineWidth: 1.2).frame(width: 18, height: 18)
            Rectangle().fill(DarkroomPalette.amber).frame(width: 1, height: 26)
            Rectangle().fill(DarkroomPalette.amber).frame(width: 26, height: 1)
            Circle().fill(Color.black.opacity(0.0)).frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.7), radius: 1)
        .offset(x: p.x / Double(max(1, c.width)) * fitted.width - 13,
                y: p.y / Double(max(1, c.height)) * fitted.height - 13)
        .frame(width: 26, height: 26)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 四角的裁切线（像放在放大机压纸板上的相纸）。
private struct CropMarks: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l: CGFloat = 12
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x, y: y + dy * l))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return p
    }
}

// MARK: - 右栏：印放、质感、放大镜

private struct DarkroomControls: View {
    @ObservedObject var model: CollageDarkroom
    @ObservedObject var store: CollageStore

    var body: some View {
        let setting = model.current
        let spectral = setting.look.isSpectral
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(CollageDarkroom.frameNumber(setting.look).map { String(format: "▶%02d", $0) } ?? "▶--")
                            .font(DarkroomFont.type(20))
                            .foregroundStyle(DarkroomPalette.amber)
                            .shadow(color: DarkroomPalette.amber.opacity(0.4), radius: 3)
                        Text(setting.look.label).font(DarkroomFont.title(26)).foregroundStyle(DarkroomPalette.text)
                    }
                    Text("\(CollageDarkroom.kindLabel(setting.look)) · \(model.effectiveScope.label)"
                         + (model.ownsSetting ? "" : " · 跟着上一级"))
                        .font(DarkroomFont.type(11)).tracking(0.6).foregroundStyle(DarkroomPalette.dim)
                    if model.effectiveScope != .project, model.ownsSetting {
                        Button("这一级不单独设，跟着上一级") { model.followParent() }
                            .buttonStyle(.plain)
                            .font(DarkroomFont.type(11))
                            .foregroundStyle(DarkroomPalette.amber)
                            .underline()
                    }
                    if let note = model.overriddenBelow {
                        Text(note).font(.caption).foregroundStyle(DarkroomPalette.amber)
                    }
                }

                VStack(alignment: .leading, spacing: 11) {
                    DarkroomHeading(number: "01", title: "印放", english: "PRINT")
                    DarkroomTestStrip(model: model)
                    DarkroomSlider(label: "强度", value: setting.strength, set: { model.setStrength($0) },
                                   help: "色调的强度（「套用到」那一级）")
                        .disabled(setting.look == .none)
                        .opacity(setting.look == .none ? 0.4 : 1)
                    DarkroomSlider(label: "统一色温", value: store.project.style.harmonize,
                                   set: { model.setStyleValue(\.harmonize, $0) },
                                   help: "配光：其余照片的色温、明暗往主图靠（对整组）")
                }

                VStack(alignment: .leading, spacing: 11) {
                    DarkroomHeading(number: "02", title: "质感", english: "TEXTURE", trailing: "对整组")
                    Group {
                        DarkroomSlider(label: "颗粒", value: store.project.style.filmGrain,
                                       set: { model.setStyleValue(\.filmGrain, $0) },
                                       help: "spektrafilm 的颗粒模型：50% ≈ 这款胶片在 35mm 底片上的真实颗粒，100% 是两倍")
                        DarkroomSlider(label: "晕光", value: store.project.style.filmHalation,
                                       set: { model.setStyleValue(\.filmHalation, $0) },
                                       help: "高光边上泛红的光晕：100% = 没有防光晕层的底片")
                    }
                    .disabled(!spectral)
                    .opacity(spectral ? 1 : 0.4)
                    if !spectral {
                        Text("「\(setting.look.label)」是相纸滤镜，没有颗粒、晕光：换一款负片、反转片或电影负片。")
                            .font(.caption).foregroundStyle(DarkroomPalette.amber)
                    }
                }

                VStack(alignment: .leading, spacing: 11) {
                    DarkroomHeading(number: "03", title: "放大镜", english: "GRAIN FOCUSER", trailing: "1:1")
                    HStack {
                        Spacer()
                        DarkroomLoupe(model: model)
                        Spacer()
                    }
                    Text("导出尺寸的 1:1，颗粒、晕光在这里才看得清。点大预览换位置。")
                        .font(.caption).foregroundStyle(DarkroomPalette.dim)
                }

                Text("色调和强度改「套用到」选的那一级；颗粒、晕光、统一色温对整组。每一下都是一步撤销（⌘Z）。")
                    .font(.caption2).foregroundStyle(DarkroomPalette.dim)
            }
            .padding(16)
        }
        .background(DarkroomChrome(color: DarkroomPalette.panel))
    }
}

/// 强度试条：一条相纸上同一张照片 0 / 25 / 50 / 75 / 100%（暗房的阶梯曝光），点哪格就设到哪格，红色蜡笔标出现在的强度。
private struct DarkroomTestStrip: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        let steps = CollageDarkroom.stripSteps
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width / CGFloat(steps.count)
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                            ZStack {
                                DarkroomPalette.surround
                                if model.testStrip.indices.contains(i) {
                                    Image(nsImage: model.testStrip[i]).resizable().aspectRatio(contentMode: .fill)
                                }
                            }
                            .frame(width: w, height: geo.size.height)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { model.setStrength(s, coalesce: false) }
                            .accessibilityElement()
                            .accessibilityLabel("强度 \(Int(s * 100))%")
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                    // 现在的强度：一道红蜡笔竖线。
                    Capsule().fill(DarkroomPalette.pen)
                        .frame(width: 2.6, height: geo.size.height + 8)
                        .offset(x: max(0, min(geo.size.width - 2.6, geo.size.width * model.current.strength - 1.3)), y: -4)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 50)
            HStack(spacing: 0) {
                ForEach(steps, id: \.self) { s in
                    Text("\(Int(s * 100))").font(DarkroomFont.type(8.5)).foregroundStyle(Color(white: 0.35))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(5)
        .background(DarkroomPalette.paper)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
        .rotationEffect(.degrees(-0.6))
        .help("试条：同一张照片 0 / 25 / 50 / 75 / 100% 强度，点哪格就设到哪格")
    }
}

/// 圆形放大镜：导出尺寸渲整页、裁一块（1 个导出像素 = 1 pt），金属环、十字线；重渲时旧图压暗。
private struct DarkroomLoupe: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        let side = CGFloat(CollageDarkroom.loupeSide)
        ZStack {
            Circle().fill(DarkroomPalette.surround)
            if let image = model.loupe {
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: side, height: side)
                    .clipShape(Circle())
                    .opacity(model.loupeStale ? 0.4 : 1)
            }
            if model.loupe == nil || model.loupeStale {
                Text("冲洗中…").font(DarkroomFont.type(11)).foregroundStyle(DarkroomPalette.text)
            }
            // 十字线（中间留空）
            Group {
                Rectangle().frame(width: 0.8, height: side * 0.16).offset(y: -side * 0.14)
                Rectangle().frame(width: 0.8, height: side * 0.16).offset(y: side * 0.14)
                Rectangle().frame(width: side * 0.16, height: 0.8).offset(x: -side * 0.14)
                Rectangle().frame(width: side * 0.16, height: 0.8).offset(x: side * 0.14)
            }
            .foregroundStyle(Color.white.opacity(0.55))
            Circle()
                .strokeBorder(AngularGradient(colors: [Color(white: 0.75), Color(white: 0.3), Color(white: 0.6),
                                                       Color(white: 0.25), Color(white: 0.75)], center: .center),
                              lineWidth: 8)
            Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1.2).padding(8)
            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6)
        }
        .frame(width: side + 16, height: side + 16)
        .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
        .accessibilityLabel("1:1 放大镜")
    }
}

// MARK: - 底下：这一页的底片条

private struct DarkroomReel: View {
    @ObservedObject var model: CollageDarkroom
    @ObservedObject var store: CollageStore

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("这一页").font(DarkroomFont.title(15)).foregroundStyle(DarkroomPalette.text)
                Text("THIS PAGE").font(DarkroomFont.type(8.5)).tracking(2.4).foregroundStyle(DarkroomPalette.amberDim)
                Text("点一格：只改这一格").font(.caption2).foregroundStyle(DarkroomPalette.dim).padding(.top, 4)
            }
            .frame(width: 112, alignment: .leading)
            if model.reel.isEmpty {
                Text(store.isContactSheet || store.isFreeform ? "这一页没有格子（印样 / 散落），按整组或这一页改。" : "这一页还没有照片。")
                    .font(.caption).foregroundStyle(DarkroomPalette.dim)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 3) {
                        DarkroomSprockets(square: false)
                        HStack(spacing: 9) {
                            ForEach(Array(model.reel.enumerated()), id: \.element.id) { i, frame in
                                VStack(spacing: 3) {
                                    reelFrame(frame, index: i)
                                    DarkroomEdgeText("▶\(i + 1)A").frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(width: 120)
                            }
                            DarkroomEdgeText(CollageDarkroom.rebateText).opacity(0.5).padding(.horizontal, 6)
                        }
                        .padding(.horizontal, 8)
                        DarkroomSprockets(square: false)
                    }
                    .padding(.vertical, 4)
                    .background(DarkroomPalette.rebate)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DarkroomChrome(color: DarkroomPalette.panel))
    }

    private func reelFrame(_ frame: CollageDarkroom.ReelFrame, index: Int) -> some View {
        let selected = store.selection == frame.path && model.effectiveScope == .cell
        return ZStack {
            DarkroomPalette.surround
            if let image = frame.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 120, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
        .overlay {
            if selected {
                DarkroomCrayonMark(seed: index * 7 + 3).padding(-3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectCell(frame.path) }
        .help("只改这一格的色调")
        .accessibilityElement()
        .accessibilityLabel("这一页的第 \(index + 1) 格照片" + (selected ? "，已选中" : ""))
        .accessibilityAddTraits(.isButton)
    }
}
