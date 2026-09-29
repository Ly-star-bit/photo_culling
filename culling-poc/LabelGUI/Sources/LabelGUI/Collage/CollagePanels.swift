import SwiftUI
import AppKit

// 检视器里的几块：模板缩略图、色调、照片上的字、贴纸、选中的图层。
// 所有改动都走 store 的方法（进撤销栈）；滑杆连续拖动用 coalesce 合成一步。

private func percentText(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

// MARK: - 模板缩略图

/// 模板库：按分类分组的缩略图网格。托盘照片、样式、画布、模板变了就重渲缩略图（store 里按键去重）。
struct CollageTemplateGallery: View {
    @ObservedObject var store: CollageStore
    let onDelete: (String) -> Void

    /// 分组：内置按出场顺序，自己存的放最后。
    private var groups: [(String, [CollageTemplate])] {
        var order: [String] = []
        var groups: [String: [CollageTemplate]] = [:]
        for t in store.allTemplates {
            let key = t.builtin ? (t.category.isEmpty ? "基础" : t.category) : "我的模板"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(t)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.0) { group in
                section(group.0, group.1)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: store.project.photos.count) { _, _ in refresh() }
        .onChange(of: store.userTemplates) { _, _ in refresh() }
        .onChange(of: store.hintsVersion) { _, _ in refresh() }
        .onChange(of: store.project.style) { _, _ in refresh() }
        .onChange(of: store.project.canvas) { _, _ in refresh() }
    }

    private func refresh() { store.renderTemplateThumbs() }

    private func section(_ title: String, _ templates: [CollageTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 10) {
                ForEach(templates, id: \.name) { t in
                    CollageTemplateTile(store: store, template: t) { onDelete(t.name) }
                }
            }
        }
    }
}

struct CollageTemplateTile: View {
    @ObservedObject var store: CollageStore
    let template: CollageTemplate
    let onDelete: () -> Void

    private var aspect: CGFloat {
        let c = template.canvas ?? store.project.canvas
        return CGFloat(c.width) / CGFloat(max(1, c.height))
    }

    var body: some View {
        Button {
            store.applyTemplate(template)
        } label: {
            VStack(spacing: 3) {
                thumb
                    .frame(height: 104)
                    .frame(maxWidth: .infinity)
                Text(template.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.project.photos.isEmpty)
        .help("\(template.name) · \(template.photoSlots) 张" + (template.canvas.map { " · \($0.name)" } ?? "")
              + (store.project.photos.isEmpty ? "（先带照片进托盘）" : ""))
        .contextMenu {
            if !template.builtin {
                Button("删除「\(template.name)」", role: .destructive, action: onDelete)
            }
        }
    }

    @ViewBuilder
    private var thumb: some View {
        if let image = store.templateThumbs[template.name] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.18))
                .aspectRatio(aspect, contentMode: .fit)
        }
    }
}

// MARK: - 色调

struct CollageLookBox: View {
    @ObservedObject var store: CollageStore

    private func binding(_ keyPath: WritableKeyPath<CollageStyle, Double>) -> Binding<Double> {
        Binding(get: { store.project.style[keyPath: keyPath] },
                set: { v in
                    var s = store.project.style
                    s[keyPath: keyPath] = v
                    store.setStyle(s)
                })
    }

    var body: some View {
        GroupBox("色调") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], spacing: 8) {
                    ForEach(CollageLook.allCases, id: \.self) { look in
                        swatch(look)
                    }
                }
                CollageSlider(label: "强度", value: binding(\.lookStrength), range: 0...1,
                              display: percentText(store.project.style.lookStrength))
                    .disabled(store.project.style.look == .none)
                CollageSlider(label: "统一色温", value: binding(\.harmonize), range: 0...1,
                              display: percentText(store.project.style.harmonize))
                    .help("其余照片的色温、明暗往主图靠：不同时间、不同光线拍的放在一起才像一组")
                Text("整组照片套同一个色调；导出和预览一样。黑白、旧照的强度只管影调。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
        .onAppear { store.renderLookThumbs() }
        .onChange(of: store.pageIndex) { _, _ in store.renderLookThumbs() }
        .onChange(of: store.project.photos.count) { _, _ in store.renderLookThumbs() }
    }

    private func swatch(_ look: CollageLook) -> some View {
        let active = store.project.style.look == look
        return Button {
            var s = store.project.style
            s.look = look
            store.setStyle(s)
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let image = store.lookThumbs[look] {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.2))
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 2.5))
                Text(look.label).font(.caption2).foregroundStyle(active ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(look == .none ? "不调色" : "整组套「\(look.label)」")
    }
}

// MARK: - 照片上的字

struct CollageOverlayBox: View {
    @ObservedObject var store: CollageStore
    let path: [Int]
    let overlay: CollageOverlay?

    var body: some View {
        GroupBox("照片上的字") {
            VStack(alignment: .leading, spacing: 8) {
                if let overlay {
                    controls(overlay)
                } else {
                    Text("选一个样式压在这张照片上：自动避开脸和身体，深字浅字跟着底下的画面换。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    presetGrid
                }
            }
            .padding(4)
        }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
            ForEach(CollageOverlays.presets) { preset in
                Button(preset.name) { store.setOverlay(preset.overlay, at: path) }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func update(_ body: @escaping (inout CollageOverlay) -> Void) {
        store.updateOverlay(at: path, coalesce: true, body)
    }

    @ViewBuilder
    private func controls(_ overlay: CollageOverlay) -> some View {
        HStack(alignment: .top, spacing: 12) {
            anchorGrid(overlay)
            VStack(alignment: .leading, spacing: 6) {
                Button("自动位置") { update { $0.anchor = .auto } }
                    .disabled(overlay.anchor == .auto)
                    .help("按人脸、身体和画面空处重新挑位置")
                Text(overlay.anchor == .custom ? "手动拖过" : "位置：\(overlay.anchor.label)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("画布上可以直接拖字").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        Picker("字色", selection: Binding(get: { overlay.tone }, set: { v in update { $0.tone = v } })) {
            ForEach(CollageTone.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        CollageSlider(label: "投影", value: Binding(get: { overlay.shadow }, set: { v in update { $0.shadow = v } }),
                      range: 0...1, display: String(format: "%.2f", overlay.shadow))
            .help("浅字底下的柔和投影（深字不加）")
        CollageSlider(label: "边距", value: Binding(get: { overlay.inset }, set: { v in update { $0.inset = v } }),
                      range: 0...0.2, display: percentText(overlay.inset))
        CollageSlider(label: "最宽", value: Binding(get: { overlay.maxWidth }, set: { v in update { $0.maxWidth = v } }),
                      range: 0.3...1, display: percentText(overlay.maxWidth))
            .help("字块最多占照片多宽，放不下整体缩小")
        HStack {
            Menu("换样式") {
                ForEach(CollageOverlays.presets) { preset in
                    Button(preset.name) { store.setOverlay(preset.overlay, at: path) }
                }
            }
            .fixedSize()
            Spacer()
            Button("去掉压字", role: .destructive) { store.setOverlay(nil, at: path) }
        }
        .font(.caption)
    }

    private func anchorGrid(_ overlay: CollageOverlay) -> some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { col in
                        anchorButton(CollageAnchor.grid[row * 3 + col], current: overlay.anchor)
                    }
                }
            }
        }
    }

    private func anchorButton(_ anchor: CollageAnchor, current: CollageAnchor) -> some View {
        let active = anchor == current
        return Button {
            update { $0.anchor = anchor }
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(active ? Color.accentColor : Color.gray.opacity(0.25))
                .frame(width: 18, height: 14)
        }
        .buttonStyle(.plain)
        .help(anchor.label)
    }
}

// MARK: - 贴纸与手写

struct CollageDecorBox: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        GroupBox("贴纸与手写") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                    ForEach(CollageSticker.allCases, id: \.self) { kind in
                        Button(kind.label) { store.addSticker(kind) }
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    Button("加手写字") { store.addItemText() }
                        .font(.caption)
                    Spacer()
                }
                Text(store.isFreeform
                     ? "散落版：托盘里的照片拖进画布 = 放一张相纸。选中后拖动挪位置，拖上方圆点旋转、右下圆点缩放；[ ] 微调角度。"
                     : "贴纸浮在版面上。先选中一张相纸再加胶带，会贴在它的上沿。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }
}

// MARK: - 选中的图层

struct CollageItemBox: View {
    @ObservedObject var store: CollageStore
    let item: CollageItem

    private func update(_ body: @escaping (inout CollageItem) -> Void) {
        store.updateItem(item.id, coalesce: true, body)
    }

    private var title: String {
        switch item.kind {
        case .photo: return "相片 " + (item.photoID ?? "（空）")
        case .text: return "手写字"
        case .sticker: return item.sticker.label
        }
    }

    private var sizeRange: ClosedRange<Double> {
        switch item.kind {
        case .photo: return 0.08...1.0
        case .text: return 0.1...1.2
        case .sticker: return 0.02...0.6
        }
    }

    var body: some View {
        GroupBox("选中的图层") {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                kindControls
                CollageSlider(label: "大小", value: sizeBinding, range: sizeRange, display: percentText(item.width))
                CollageSlider(label: "角度", value: rotationBinding, range: -45...45,
                              display: String(format: "%.0f°", item.rotation))
                if item.kind == .photo {
                    CollageSlider(label: "投影", value: Binding(get: { item.shadow }, set: { v in update { $0.shadow = v } }),
                                  range: 0...1, display: String(format: "%.2f", item.shadow))
                }
                HStack(spacing: 6) {
                    Button("置顶") { store.moveItemInStack(item.id, toFront: true) }
                    Button("置底") { store.moveItemInStack(item.id, toFront: false) }
                    Button("复制") { store.duplicateItem(item.id) }
                    Spacer()
                    Button("删除", role: .destructive) { store.deleteItem(item.id) }
                        .help("Delete")
                }
                .font(.caption)
            }
            .padding(4)
        }
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { item.width }, set: { w in
            let ratio = item.height / max(1e-6, item.width)
            update { it in
                it.width = w
                it.height = w * ratio
            }
        })
    }

    private var rotationBinding: Binding<Double> {
        Binding(get: { max(-45, min(45, item.rotation)) }, set: { v in update { $0.rotation = v.rounded() } })
    }

    @ViewBuilder
    private var kindControls: some View {
        if item.kind == .photo {
            Picker("边框", selection: Binding(get: { item.frame }, set: { v in
                // 换边框：宽度不变，高度按照片比例和新边框重算（不然胶片的齿孔带会多裁一大截）。
                let aspect = item.photoID.flatMap { store.photoMap[$0] }?.aspect
                update { it in
                    it.frame = v
                    if let aspect {
                        let outer = CollageItems.outerAspect(inner: min(1.45, max(0.72, aspect)), frame: v)
                        it.height = it.width / outer
                    }
                }
            })) {
                ForEach(CollageItemFrame.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("景别", selection: Binding(get: { item.framing }, set: { v in update { $0.framing = v } })) {
                ForEach(CollageFraming.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if item.frame == .polaroid {
                TextField("相纸下沿的字（{date} {title}…）", text: Binding(get: { item.caption },
                                                                    set: { v in update { $0.caption = v } }))
            }
        } else if item.kind == .sticker {
            Picker("种类", selection: Binding(get: { item.sticker }, set: { v in
                update { it in
                    it.sticker = v
                    it.color = v.defaultColor
                    it.width = v.defaultSize.w
                    it.height = v.defaultSize.h
                }
            })) {
                ForEach(CollageSticker.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            ColorPicker("颜色", selection: Binding(get: { item.color.swiftUIColor },
                                                 set: { c in update { $0.color = CollageColor(c) } }),
                        supportsOpacity: false)
                .font(.caption)
            if item.sticker == .label || item.sticker == .postmark {
                TextField("上面的字（默认 {date}）", text: Binding(get: { item.label }, set: { v in update { $0.label = v } }))
            }
        } else {
            Text("内容和字体在「文字」里改").font(.caption).foregroundStyle(.secondary)
        }
    }
}
