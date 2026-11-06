import SwiftUI
import AppKit

/// 暗房工作台（状态和规则见 CollageDarkroom.swift）。整页换掉拼图页（和批量页的审片、连拍挑选一样：画布不在
/// 视图树里，它的 ←→「换一版」就不会和这里的 ←→ 抢），强制深色。
///
/// 视觉（R8 §3.3 方向 A「石墨工作台」，用户 2026-11-05 选的；第一版的胶带、齿孔、计数窗、斜放被嫌丑）：
/// 照片是唯一的颜色 —— 外壳中性近黑，图片四周中性灰（四周染了色，看色调会偏）；只有一个点缀色琥珀，只表示
/// 「现在套着的」（2pt 框 + 勾，色盲也认得出）；系统字体，数值用等宽数字、不补前导零；样张用这一页的主图，
/// 名字在图外；不拟物，「暗房」只留在用词和试条里。R7 的「红色只表示选中」改成了琥珀框加勾，红色不再用。
/// 片名：色调名和用途都是通用词；光谱色调用了哪支胶片的数据写成右栏、悬停提示里的「参考：…」，右栏底下配一句
/// 免责声明（用户 2026-11-05 定的）。
struct CollageDarkroomView: View {
    @ObservedObject var model: CollageDarkroom
    @ObservedObject var store: CollageStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            DarkroomTopBar(model: model, store: store)
            DarkroomHairline()
            HStack(spacing: 0) {
                DarkroomSwatches(model: model)
                    .frame(width: 300)
                DarkroomHairline(vertical: true)
                DarkroomPreview(model: model)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                DarkroomHairline(vertical: true)
                DarkroomControls(model: model, store: store)
                    .frame(width: 280)
            }
            DarkroomHairline()
            DarkroomPageStrip(model: model, store: store)
                .frame(height: 96)
        }
        .background(DarkroomPalette.shell)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.moveFocus(-1); return .handled }
        .onKeyPress(.rightArrow) { model.moveFocus(1); return .handled }
        .onKeyPress(.upArrow) { model.moveFocus(-model.tab.columns); return .handled }
        .onKeyPress(.downArrow) { model.moveFocus(model.tab.columns); return .handled }
        .onKeyPress(.return) { model.apply(model.focus); return .handled }
        .onKeyPress(.space, phases: [.down, .up]) { press in
            model.showOriginal = press.phase == .down
            return .handled
        }
    }
}

// MARK: - 设计语言

enum DarkroomPalette {
    /// 外壳、侧栏、浮起的控件、发丝线：中性灰，不带色。
    static let shell = Color(white: 0x11 / 255.0)
    static let sidebar = Color(white: 0x1A / 255.0)
    static let raised = Color(white: 0x24 / 255.0)
    static let hairline = Color(white: 0x2A / 255.0)
    /// 大预览、样张四周。
    static let surround = Color(white: 0x2E / 255.0)
    static let track = Color(white: 0x3A / 255.0)
    static let text = Color(white: 0xED / 255.0)
    static let secondary = Color(white: 0xA3 / 255.0)
    static let tertiary = Color(white: 0x6B / 255.0)
    /// 唯一的点缀色：现在套着的（#FFB340，#1A1A1A 上约 9:1）。
    static let accent = Color(red: 1, green: 0.702, blue: 0.251)
}

private struct DarkroomHairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(DarkroomPalette.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// 分组小标题：加一点字距，右边可以带一句说明。
private struct DarkroomSectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(DarkroomPalette.secondary)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing).font(.system(size: 11)).monospacedDigit().foregroundStyle(DarkroomPalette.tertiary)
            }
        }
    }
}

/// 分段控件：一排按钮，选中的浮起一层。（系统的分段控件不能单独灰掉一段。）
private struct DarkroomSegmented: View {
    struct Item: Identifiable {
        let id: String
        let label: String
        let selected: Bool
        var enabled = true
        var help = ""
    }
    let items: [Item]
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button {
                    pick(item.id)
                } label: {
                    Text(item.label)
                        .font(.system(size: 12, weight: item.selected ? .semibold : .regular))
                        .foregroundStyle(item.selected ? DarkroomPalette.text : DarkroomPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(item.selected ? DarkroomPalette.raised : .clear)
                            .shadow(color: .black.opacity(item.selected ? 0.35 : 0), radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!item.enabled)
                .opacity(item.enabled ? 1 : 0.4)
                .help(item.help)
                .accessibilityAddTraits(item.selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DarkroomPalette.hairline, lineWidth: 1))
    }
}

/// 细滑杆：2pt 轨道、琥珀填充、14pt 白钮，只在 0 / 50 / 100 有刻度；右边写百分比（不补前导零）。
/// 无障碍那边是一根普通的 Slider。
private struct DarkroomSlider: View {
    let label: String
    let value: Double
    let set: (Double) -> Void
    var help: String = ""

    var body: some View {
        let v = min(1, max(0, value))
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(DarkroomPalette.text)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                let knob: CGFloat = 14
                let travel = max(1, geo.size.width - knob)
                let x = CGFloat(v) * travel
                ZStack(alignment: .leading) {
                    ForEach([0.0, 0.5, 1.0], id: \.self) { t in
                        Rectangle().fill(DarkroomPalette.tertiary)
                            .frame(width: 1, height: 4)
                            .offset(x: knob / 2 + CGFloat(t) * travel - 0.5, y: 9)
                    }
                    Capsule().fill(DarkroomPalette.track).frame(height: 2)
                    Capsule().fill(DarkroomPalette.accent).frame(width: x + knob / 2, height: 2)
                    Circle().fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
                        .offset(x: x)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    set(Double(min(1, max(0, (g.location.x - knob / 2) / travel))))
                })
            }
            .frame(height: 24)
            Text("\(Int((v * 100).rounded()))%")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(DarkroomPalette.secondary)
                .frame(width: 38, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .help(help)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: set), in: 0...1) { Text(label) }
        }
    }
}

/// 现在套着的：琥珀圆底黑勾。
private struct DarkroomCheck: View {
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(Color.black)
            .frame(width: size, height: size)
            .background(Circle().fill(DarkroomPalette.accent))
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

// MARK: - 顶栏

private struct DarkroomTopBar: View {
    @ObservedObject var model: CollageDarkroom
    @ObservedObject var store: CollageStore

    var body: some View {
        let scopes: [CollageDarkroom.Scope] = model.pageAvailable ? [.project, .page, .cell] : [.project, .cell]
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("暗房").font(.system(size: 13, weight: .semibold)).foregroundStyle(DarkroomPalette.text)
                Text("·").foregroundStyle(DarkroomPalette.tertiary)
                Text(model.effectiveScope.label + (store.isAlbum ? " · 跨页 \(store.pageIndex + 1)" : ""))
                    .font(.system(size: 13)).foregroundStyle(DarkroomPalette.secondary)
            }
            .frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: 12)
            Text("套用到").font(.system(size: 12)).foregroundStyle(DarkroomPalette.tertiary)
            DarkroomSegmented(items: scopes.map { s in
                let enabled = s != .cell || model.cellAvailable
                return .init(id: s.rawValue, label: s.label, selected: model.effectiveScope == s, enabled: enabled,
                             help: s == .cell && !enabled ? "先在底下这一页的小样里点一格" : "色调和强度改「\(s.label)」")
            }) { id in
                if let s = CollageDarkroom.Scope(rawValue: id) { model.scope = s }
            }
            .frame(width: CGFloat(scopes.count) * 76)
            Spacer(minLength: 12)
            Text("原图")
                .font(.system(size: 12, weight: model.showOriginal ? .semibold : .regular))
                .foregroundStyle(model.showOriginal ? DarkroomPalette.text : DarkroomPalette.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(model.showOriginal ? DarkroomPalette.raised : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DarkroomPalette.hairline, lineWidth: 1))
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                    model.showOriginal = pressing
                })
                .help("按住看原图（空格）")
                .accessibilityAddTraits(.isButton)
            Button {
                store.closeDarkroom()
            } label: {
                Text("完成").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.black)
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DarkroomPalette.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("回到拼图（Esc）。暗房里的改动都已经套上了，⌘Z 一步步撤")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(DarkroomPalette.sidebar)
    }
}

// MARK: - 左栏：样张

private struct DarkroomSwatches: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        let groups = CollageDarkroom.groups.filter { ($0.kind == .filter) == (model.tab == .filter) }
        VStack(spacing: 0) {
            DarkroomSegmented(items: CollageDarkroom.Tab.allCases.map { t in
                .init(id: t.rawValue, label: t.label, selected: model.tab == t,
                      help: t == .film ? "光谱胶片：有颗粒、晕光" : "相纸滤镜：没有颗粒、晕光")
            }) { id in
                if let t = CollageDarkroom.Tab(rawValue: id) { model.tab = t }
            }
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            DarkroomSectionTitle(title: group.title,
                                                 trailing: group.kind == .filter ? "无颗粒 · 无晕光" : "\(group.looks.count)")
                            let columns = group.kind == .filter
                                ? Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3)
                                : Array(repeating: GridItem(.fixed(132), spacing: 12, alignment: .top), count: 2)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(group.looks, id: \.self) { look in
                                    DarkroomSwatch(model: model, look: look, small: group.kind == .filter)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .background(DarkroomPalette.sidebar)
    }
}

/// 一张样张：悬停 = 预览，点 = 套用；现在套着的是 2pt 琥珀框 + 勾，键盘焦点是一圈淡白框。
private struct DarkroomSwatch: View {
    @ObservedObject var model: CollageDarkroom
    let look: CollageLook
    let small: Bool

    var body: some View {
        let applied = model.current.look == look
        let focused = model.focus == look && !applied
        let hovered = model.hover == look
        let corner: CGFloat = small ? 5 : 6
        let border: Color = applied ? DarkroomPalette.accent
            : focused ? Color.white.opacity(0.6) : hovered ? Color.white.opacity(0.3) : DarkroomPalette.hairline
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                DarkroomPalette.surround
                if let image = model.frames[look] {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(border, lineWidth: applied ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if applied { DarkroomCheck(size: small ? 14 : 16).padding(small ? 4 : 5) }
            }
            Text(look.label)
                .font(.system(size: small ? 11 : 12, weight: applied ? .semibold : .regular))
                .foregroundStyle(applied || hovered ? DarkroomPalette.text : DarkroomPalette.secondary)
                .lineLimit(1)
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: model.frames[look] != nil)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hover = look } else if model.hover == look { model.hover = nil }
        }
        .onTapGesture { model.apply(look) }
        .help("\(look.label)：\(CollageDarkroom.blurb(look))" + (look.referenceStock.map { "（参考 \($0)）" } ?? "")
              + "。悬停预览，点一下套用")
        .accessibilityElement()
        .accessibilityLabel("\(look.label)，\(CollageDarkroom.kindLabel(look))，\(CollageDarkroom.blurb(look))"
                            + (look.referenceStock.map { "，参考 \($0)" } ?? "")
                            + (applied ? "，现在套着" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.apply(look) }
    }
}

// MARK: - 大预览

private struct DarkroomPreview: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        GeometryReader { geo in
            let area = CGSize(width: max(10, geo.size.width - 64), height: max(10, geo.size.height - 76))
            ZStack {
                DarkroomPalette.surround
                if let image = model.processed {
                    printView(image, fit(image.size, in: area))
                        .offset(y: -8)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay(alignment: .top) {
                // 有渲染在跑：顶上一条细线（不遮图）。
                Rectangle().fill(DarkroomPalette.accent.opacity(0.75)).frame(height: 2)
                    .opacity(model.busy ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: model.busy)
            }
            .overlay(alignment: .bottom) {
                Text("←→ 换一款 · ⏎ 套用 · 按住空格看原图 · 点图换 1:1 细节的位置 · Esc 完成")
                    .font(.system(size: 11)).foregroundStyle(DarkroomPalette.tertiary)
                    .padding(.bottom, 12)
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
        .overlay(alignment: .topLeading) {
            if model.showOriginal || model.split > 0.08 { tag("原图").padding(10) }
        }
        .overlay(alignment: .topTrailing) {
            if !model.showOriginal && model.split < 0.92 {
                tag(model.hover.map { "预览 · \($0.label)" } ?? model.current.look.label).padding(10)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }

    /// 图上角的小标签：半透明黑底白字。
    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .allowsHitTesting(false)
    }

    private func report(_ size: CGSize) {
        let s = NSScreen.main?.backingScaleFactor ?? 2
        model.previewPixels = CGSize(width: (size.width - 64) * s, height: (size.height - 76) * s)
    }

    private func fit(_ image: CGSize, in area: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return area }
        let k = min(area.width / image.width, area.height / image.height)
        return CGSize(width: image.width * k, height: image.height * k)
    }

    /// 对比竖线：1pt 白线 + 20pt 圆把手，拖着走，左边原图、右边成片；拖到最左 = 全是成片。
    private func divider(_ fitted: CGSize) -> some View {
        let x = fitted.width * model.split
        return ZStack {
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1)
                .shadow(color: .black.opacity(0.5), radius: 1)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white))
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        }
        .frame(width: 28, height: fitted.height)
        .contentShape(Rectangle())
        .offset(x: x - 14)
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            model.split = min(1, max(0, (x + v.translation.width) / fitted.width))
        })
        .opacity(model.split > 0.001 ? 1 : 0.6)
        .help("拖竖线对比：左边原图、右边成片；拖到最左就全是成片")
        .accessibilityLabel("对比竖线")
        .accessibilityValue("原图占 \(Int(model.split * 100))%")
    }

    /// 1:1 细节看的位置：一圈琥珀细环。
    private func loupeMarker(_ fitted: CGSize) -> some View {
        let c = model.store.project.canvas
        let p = model.loupeCenter
        return Circle().strokeBorder(DarkroomPalette.accent, lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .shadow(color: .black.opacity(0.7), radius: 1)
            .offset(x: p.x / Double(max(1, c.width)) * fitted.width - 8,
                    y: p.y / Double(max(1, c.height)) * fitted.height - 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - 右栏：强度、质感、1:1 细节

private struct DarkroomControls: View {
    @ObservedObject var model: CollageDarkroom
    @ObservedObject var store: CollageStore

    var body: some View {
        let setting = model.current
        let spectral = setting.look.isSpectral
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(setting.look.label).font(.system(size: 20, weight: .semibold)).foregroundStyle(DarkroomPalette.text)
                    Text(CollageDarkroom.blurb(setting.look)).font(.system(size: 12)).foregroundStyle(DarkroomPalette.secondary)
                    if let stock = setting.look.referenceStock {
                        Text("参考：\(stock)").font(.system(size: 11)).foregroundStyle(DarkroomPalette.tertiary)
                    }
                    Text("\(CollageDarkroom.kindLabel(setting.look)) · \(model.effectiveScope.label)"
                         + (model.ownsSetting ? "" : " · 跟着上一级"))
                        .font(.system(size: 11)).foregroundStyle(DarkroomPalette.tertiary)
                        .padding(.top, 2)
                    if model.effectiveScope != .project, model.ownsSetting {
                        Button("这一级不单独设，跟着上一级") { model.followParent() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(DarkroomPalette.accent)
                    }
                    if let note = model.overriddenBelow {
                        Text(note).font(.system(size: 11)).foregroundStyle(DarkroomPalette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    DarkroomSectionTitle(title: "强度")
                    DarkroomTestStrip(model: model)
                    DarkroomSlider(label: "强度", value: setting.strength, set: { model.setStrength($0) },
                                   help: "色调的强度（「套用到」那一级）")
                        .disabled(setting.look == .none)
                        .opacity(setting.look == .none ? 0.4 : 1)
                }

                VStack(alignment: .leading, spacing: 10) {
                    DarkroomSectionTitle(title: "质感", trailing: "对整组")
                    Group {
                        DarkroomSlider(label: "颗粒", value: store.project.style.filmGrain,
                                       set: { model.setStyleValue(\.filmGrain, $0) },
                                       help: "spektrafilm 的颗粒模型：50% ≈ 这款胶片在 35mm 底片上的真实颗粒，100% 是两倍")
                        DarkroomSlider(label: "晕光", value: store.project.style.filmHalation,
                                       set: { model.setStyleValue(\.filmHalation, $0) },
                                       help: "高光边上泛红的光晕：20% 上下是有防光晕层的真片，拉满是没有防光晕层的底片")
                    }
                    .disabled(!spectral)
                    .opacity(spectral ? 1 : 0.4)
                    DarkroomSlider(label: "统一色温", value: store.project.style.harmonize,
                                   set: { model.setStyleValue(\.harmonize, $0) },
                                   help: "其余照片的色温、明暗往主图靠（对整组）")
                    if !spectral {
                        Text("「\(setting.look.label)」是相纸滤镜，没有颗粒、晕光：在「胶片」页签里换一款。")
                            .font(.system(size: 11)).foregroundStyle(DarkroomPalette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    DarkroomSectionTitle(title: "1:1 细节", trailing: "导出尺寸")
                    DarkroomLoupe(model: model)
                    Text("颗粒、晕光在这里看得清。点大预览换位置。")
                        .font(.system(size: 11)).foregroundStyle(DarkroomPalette.tertiary)
                }

                Text("色调和强度改「套用到」选的那一级；颗粒、晕光、统一色温对整组。每一下都是一步撤销（⌘Z）。")
                    .font(.system(size: 10.5)).foregroundStyle(DarkroomPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("「参考」写的是色调用了哪支胶片的公开数据（经 spektrafilm 模拟、再按扫描调过色），不代表原厂效果；"
                     + "片名是各自所有者的商标，本软件与它们没有关联。")
                    .font(.system(size: 10.5)).foregroundStyle(DarkroomPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(DarkroomPalette.sidebar)
    }
}

/// 强度试条：同一张照片 0 / 25 / 50 / 75 / 100%（暗房的阶梯曝光），点哪格就设到哪格，琥珀竖线标出现在的强度。
private struct DarkroomTestStrip: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        let steps = CollageDarkroom.stripSteps
        VStack(spacing: 4) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let w = (geo.size.width - gap * CGFloat(steps.count - 1)) / CGFloat(steps.count)
                ZStack(alignment: .topLeading) {
                    HStack(spacing: gap) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                            ZStack {
                                DarkroomPalette.surround
                                if model.testStrip.indices.contains(i) {
                                    Image(nsImage: model.testStrip[i]).resizable().aspectRatio(contentMode: .fill)
                                }
                            }
                            .frame(width: w, height: geo.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .contentShape(Rectangle())
                            .onTapGesture { model.setStrength(s, coalesce: false) }
                            .accessibilityElement()
                            .accessibilityLabel("强度 \(Int(s * 100))%")
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                    Capsule().fill(DarkroomPalette.accent)
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: max(0, min(geo.size.width - 2, geo.size.width * model.current.strength - 1)), y: -3)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 44)
            HStack(spacing: 0) {
                ForEach(steps, id: \.self) { s in
                    Text("\(Int(s * 100))").font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(DarkroomPalette.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .help("试条：同一张照片 0 / 25 / 50 / 75 / 100% 强度，点哪格就设到哪格")
    }
}

/// 1:1 细节：导出尺寸渲整页、裁一块（1 个导出像素 = 1 pt），圆角方块、1px 发丝边；重渲时旧图压暗。
private struct DarkroomLoupe: View {
    @ObservedObject var model: CollageDarkroom

    var body: some View {
        let side = CGFloat(CollageDarkroom.loupeSide)
        ZStack {
            DarkroomPalette.surround
            if let image = model.loupe {
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: side, height: side)
                    .opacity(model.loupeStale ? 0.45 : 1)
            }
            if model.loupe == nil || model.loupeStale {
                Text("渲染中…").font(.system(size: 11)).foregroundStyle(DarkroomPalette.text)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DarkroomPalette.hairline, lineWidth: 1))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("1:1 细节")
    }
}

// MARK: - 底下：这一页的小样

private struct DarkroomPageStrip: View {
    @ObservedObject var model: CollageDarkroom
    @ObservedObject var store: CollageStore

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("这一页").font(.system(size: 12, weight: .semibold)).foregroundStyle(DarkroomPalette.text)
                Text("点一格：只改这一格").font(.system(size: 11)).foregroundStyle(DarkroomPalette.tertiary)
            }
            .frame(width: 110, alignment: .leading)
            if model.reel.isEmpty {
                Text(store.isContactSheet || store.isFreeform ? "这一页没有格子（印样 / 散落），按整组或这一页改。" : "这一页还没有照片。")
                    .font(.system(size: 11)).foregroundStyle(DarkroomPalette.tertiary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.reel.enumerated()), id: \.element.id) { i, frame in
                            VStack(spacing: 4) {
                                thumb(frame, index: i)
                                Text("\(i + 1)").font(.system(size: 10)).monospacedDigit()
                                    .foregroundStyle(DarkroomPalette.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(DarkroomPalette.sidebar)
    }

    private func thumb(_ frame: CollageDarkroom.ReelFrame, index: Int) -> some View {
        let selected = store.selection == frame.path && model.effectiveScope == .cell
        return ZStack {
            DarkroomPalette.surround
            if let image = frame.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 99, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(selected ? DarkroomPalette.accent : DarkroomPalette.hairline, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if selected { DarkroomCheck(size: 14).padding(4) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectCell(frame.path) }
        .help("只改这一格的色调")
        .accessibilityElement()
        .accessibilityLabel("这一页的第 \(index + 1) 格照片" + (selected ? "，已选中" : ""))
        .accessibilityAddTraits(.isButton)
    }
}
