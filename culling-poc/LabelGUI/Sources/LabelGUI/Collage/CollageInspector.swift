import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 右侧检视器：版式 / 样式 / 文字 / 导出。所有改动都走 store 的方法（进撤销栈）。
struct CollageInspector: View {
    enum Tab: String, CaseIterable {
        case layout = "版式"
        case style = "样式"
        case text = "文字"
        case export = "导出"
    }

    @ObservedObject var store: CollageStore
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .layout: CollageLayoutPanel(store: store)
                    case .style: CollageStylePanel(store: store)
                    case .text: CollageTextPanel(store: store)
                    case .export: CollageExportPanel(store: store)
                    }
                }
                .padding(10)
            }
        }
    }
}

// MARK: - 小组件

struct CollageSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 56, alignment: .leading)
            Slider(value: $value, in: range)
            Text(display).font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}

extension CollageColor {
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}

private func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

// MARK: - 版式

struct CollageLayoutPanel: View {
    @ObservedObject var store: CollageStore
    @State private var templateName = ""
    @State private var templateFits = true
    @State private var customW = ""
    @State private var customH = ""
    @State private var templateToDelete: String?

    var body: some View {
        canvasBox
        if let item = store.selectedItemValue {
            // 换了图层就换一个面板实例：输入框迟到的提交只会写回它自己那张（按 id 认）。
            CollageItemBox(store: store, item: item)
                .id(item.id)
        } else if store.selectedCell != nil {
            cellBox
        }
        if !store.isFreeform { layoutBox }
        CollageDecorBox(store: store)
        templateBox
    }

    // 画布

    private var canvasBox: some View {
        GroupBox("画布") {
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    let presets = store.isAlbum ? CollageCanvas.albums : CollageCanvas.social
                    ForEach(presets, id: \.name) { preset in
                        Button(preset.name) {
                            // 相册换尺寸不换装订方式。
                            var c = preset
                            if store.isAlbum { c.binding = store.project.canvas.binding }
                            store.setCanvas(c)
                        }
                    }
                } label: {
                    Text(store.project.canvas.name).lineLimit(1)
                }
                .help("换画布：版式按比例缩放；想让照片重新贴合原比例，点下面的「贴合原比例」")
                HStack(spacing: 4) {
                    TextField("宽", text: $customW).frame(width: 64)
                    Text("×")
                    TextField("高", text: $customH).frame(width: 64)
                    Text("px").font(.caption).foregroundStyle(.secondary)
                    Button("应用") { applyCustomSize() }
                        .disabled(Int(customW) == nil || Int(customH) == nil)
                }
                .font(.caption)
                .onAppear { syncCustomFields() }
                .onChange(of: store.project.canvas) { _, _ in syncCustomFields() }
                if store.project.canvas.seams == .grid9 {
                    Text("导出时另存 3×3 九张（每张 \(store.project.canvas.width / 3)×\(store.project.canvas.height / 3)），发朋友圈按顺序选图；脸不会压在切线上")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if store.project.canvas.seams == .carousel {
                    Text("导出时切成 \(store.project.canvas.slides) 张轮播，照片可以跨页连着；脸不会压在页缝上")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if store.project.canvas.seams == .fold {
                    foldControls
                }
            }
            // 每一块都撑满检视器的宽（以前「画布」「输出目录」两块按内容收窄，和别的块对不齐）。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func mm(_ px: Int) -> String {
        String(format: "%.0fmm", Double(px) / max(1, store.project.canvas.dpi) * 25.4)
    }

    /// 相册跨页：装订方式 + 中缝说明；胶装下还有照片压中缝的页报出来。
    @ViewBuilder
    private var foldControls: some View {
        let canvas = store.project.canvas
        Picker("装订", selection: Binding(get: { canvas.binding }, set: { store.setBinding($0) })) {
            ForEach(CollageBinding.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("平铺对裱：摊开是平的，横图可以铺满两页；胶装锁线：书脊会吃掉中间一条，照片不跨中缝")
        let band = String(format: "%.0fmm", canvas.foldBand / max(1, canvas.dpi) * 25.4)
        let rule = canvas.binding == .glued ? "照片不跨中缝，中缝两侧各 \(band) 不放脸" : "横图可以铺满两页，中缝两侧各 \(band) 不放脸"
        Text("\(rule)；出血 \(mm(canvas.bleed)) · 安全区 \(mm(canvas.safe))")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if canvas.binding == .glued {
            let crossing = store.crossFoldPages()
            if !crossing.isEmpty {
                Label("第 " + crossing.map { "\($0 + 1)" }.joined(separator: "、") + " 页有照片压在中缝上：到那一页点「换一批」",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func syncCustomFields() {
        customW = "\(store.project.canvas.width)"
        customH = "\(store.project.canvas.height)"
    }

    private func applyCustomSize() {
        guard let w = Int(customW), let h = Int(customH), w >= 64, h >= 64, w <= 20000, h <= 20000 else { return }
        var c = store.project.canvas
        c.width = w
        c.height = h
        c.name = "自定义 \(w)×\(h)"
        store.setCanvas(c)
    }

    // 选中的格子

    private var cellBox: some View {
        GroupBox("选中的格子") {
            VStack(alignment: .leading, spacing: 8) {
                if let cell = store.selectedCell {
                    Text(cellTitle(cell)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if cell.kind == .photo, cell.photoID != nil {
                        photoCellControls(cell)
                        if selectedWindow?.hitsBystander == true {
                            Label("取景里有路人：双击格子拖一拖，或者换「半身」「特写」", systemImage: "person.2.fill")
                                .font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if store.project.canvas.isPrint, let up = selectedUpscale, up > CollageStore.upscaleLimit {
                            Label("这张要放大到 \(Int((up * 100).rounded()))% 才铺得满，超过 120% 印出来会软：少裁一点、换「完整显示」，或者给它小一点的格子",
                                  systemImage: "plus.magnifyingglass")
                                .font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(cell.overlay == nil ? "要在这张照片上压字：到「文字」里选一个样式" : "照片上压了字：在「文字」里改内容、位置、深浅")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if cell.kind == .text {
                        Text("在「文字」里编辑内容和字体").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("空格子：从托盘拖一张照片进来").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(cell.locked ? "解锁" : "锁定") { store.toggleLock() }
                            .help("锁定的格子在「换一批」时位置和大小都不动")
                        Spacer()
                        Button("删除格子", role: .destructive) {
                            if let path = store.selection { store.removeCell(path) }
                        }
                        .help("删掉这一格，其余自动补位 (Delete)")
                    }
                    if store.isAlbum, store.selectedCell?.photoID != nil {
                        HStack {
                            Button("移到上一跨页") { store.moveSelectedPhoto(toPage: store.pageIndex - 1) }
                                .disabled(store.pageIndex == 0)
                            Button("移到下一跨页") { store.moveSelectedPhoto(toPage: store.pageIndex + 1) }
                                .disabled(store.pageIndex >= store.project.pages.count - 1)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// 选中那一格印出来要放大多少。
    private var selectedUpscale: Double? {
        guard let path = store.selection, let frame = store.geometry.frames.first(where: { $0.path == path }) else {
            return nil
        }
        return store.upscale(for: frame)
    }

    /// 选中那一格现在的取景（看有没有路人）。
    private var selectedWindow: CollageCrop.Window? {
        guard let path = store.selection, let frame = store.geometry.frames.first(where: { $0.path == path }) else {
            return nil
        }
        return store.window(for: frame)
    }

    private func cellTitle(_ cell: CollageCell) -> String {
        switch cell.kind {
        case .photo: return cell.photoID.map { "照片 \($0)" } ?? "空照片格"
        case .text: return "文字格"
        case .empty: return "留白格"
        }
    }

    @ViewBuilder
    private func photoCellControls(_ cell: CollageCell) -> some View {
        Picker("景别", selection: Binding(get: { cell.framing }, set: { store.setFraming($0) })) {
            ForEach(CollageFraming.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("按人脸一键取景：全身 = 尽量大；半身 = 腰以上；特写 = 头肩。自动 = 小格收近景")
        Picker("形状", selection: Binding(get: { cell.shape }, set: { store.setShape($0) })) {
            Text("跟随样式").tag(CollageShape?.none)
            ForEach(CollageShape.allCases, id: \.self) { Text($0.label).tag(CollageShape?.some($0)) }
        }
        Toggle("完整显示，不裁", isOn: Binding(get: { cell.contain }, set: { store.setContain($0) }))
            .help("照片按原比例整张放进格子，四周留底色")
        if cell.contain {
            Toggle("四周用本图模糊填", isOn: Binding(get: { cell.containBlur }, set: { store.setContainBlur($0) }))
                .help("不留底色：这张照片自己大幅模糊铺满整格，清楚的那张浮在正中（横格放竖图常用）")
        }
        HStack {
            if store.cropEditing {
                Button("完成裁切") { store.exitCropEdit() }
                    .keyboardShortcut(.return, modifiers: [])
            } else {
                Button("调整裁切…") { if let p = store.selection { store.enterCropEdit(p) } }
                    .help("也可以双击格子：拖动平移、捏合缩放")
            }
            Button("还原自动") { store.resetCrop() }
                .disabled(cell.crop == nil)
        }
        if store.cropEditing, let path = store.selection {
            zoomSlider(path: path)
        }
    }

    private func zoomSlider(path: [Int]) -> some View {
        let frame = store.geometry.frames.first { $0.path == path }
        let base = frame.flatMap { store.cropBaseline(for: $0) }
        let binding = Binding<Double>(
            get: { base?.zoom ?? 1 },
            set: { z in
                guard let base else { return }
                store.setCrop(CollageCropOverride(cx: base.cx, cy: base.cy, zoom: z), at: path)
            })
        return CollageSlider(label: "缩放", value: binding, range: 1...6,
                             display: String(format: "%.1f×", base?.zoom ?? 1))
    }

    // 版式操作

    private var layoutBox: some View {
        GroupBox("版式") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("贴合原比例") { store.refit() }
                        .disabled(store.root == nil)
                        .help("结构不变，按照片原比例重算每条缝的位置（手动拖过的缝会被重算）")
                    if !store.alternatives.isEmpty {
                        Text("第 \(store.alternativeIndex + 1)/\(store.alternatives.count) 版")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("加文字格").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("上") { store.addTextCell(edge: .top, vertical: false) }
                    Button("下") { store.addTextCell(edge: .bottom, vertical: false) }
                    Button("左 · 竖排") { store.addTextCell(edge: .left, vertical: true) }
                    Button("右 · 竖排") { store.addTextCell(edge: .right, vertical: true) }
                }
                .font(.caption)
                .disabled(store.root == nil)
                .help("选中格子时加在那一格旁边，否则加在整版的这一边")
                Text("画布上：拖缝调大小 · ⌥点缝横竖翻转 · 拖格子到另一格中间互换、到边上劈开插入 · 双击调裁切")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // 模板

    private var templateBox: some View {
        GroupBox("模板") {
            VStack(alignment: .leading, spacing: 8) {
                CollageTemplateGallery(store: store) { templateToDelete = $0 }
                Divider()
                HStack {
                    TextField("把当前版存成模板…", text: $templateName)
                        .onSubmit { saveTemplate() }
                    Button("存") { saveTemplate() }
                        .disabled(templateName.trimmingCharacters(in: .whitespaces).isEmpty || store.root == nil)
                }
                Toggle("套用时按照片比例自适应", isOn: $templateFits)
                    .font(.caption)
                    .help("关掉 = 固定比例，照片按格子裁（严格网格、月洞门这种）；散落版总是原样摆放")
                HStack {
                    Button("导入模板…") { importTemplates() }
                    Button("导出我的模板…") { exportTemplates() }
                        .disabled(store.userTemplates.isEmpty)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .confirmationDialog("删除模板？", isPresented: Binding(
            get: { templateToDelete != nil },
            set: { if !$0 { templateToDelete = nil } }
        ), presenting: templateToDelete) { name in
            Button("删除「\(name)」", role: .destructive) { store.deleteTemplate(name) }
            Button("取消", role: .cancel) {}
        }
    }

    private func saveTemplate() {
        store.saveTemplate(named: templateName, fitAspects: templateFits)
        templateName = ""
    }

    private func importTemplates() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { store.importTemplates(from: url) }
    }

    private func exportTemplates() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "拼图模板.json"
        if panel.runModal() == .OK, let url = panel.url { store.exportTemplates(to: url) }
    }
}

// MARK: - 样式

struct CollageStylePanel: View {
    @ObservedObject var store: CollageStore

    private let swatches: [(String, CollageColor)] = [
        ("纸白", .paper), ("纯白", .white), ("米色", .rice), ("浅灰", CollageColor(hex: 0xE6E4E0)),
        ("墨黑", .charcoal), ("暖黑", CollageColor(hex: 0x2A2826)),
    ]

    var body: some View {
        presetBox
        CollageLookBox(store: store)
        spacingBox
        backgroundBox
        frameBox
    }

    private func styleBinding(_ keyPath: WritableKeyPath<CollageStyle, Double>) -> Binding<Double> {
        Binding(get: { store.project.style[keyPath: keyPath] },
                set: { v in
                    var s = store.project.style
                    s[keyPath: keyPath] = v
                    store.setStyle(s)
                })
    }

    private func styleBool(_ keyPath: WritableKeyPath<CollageStyle, Bool>) -> Binding<Bool> {
        Binding(get: { store.project.style[keyPath: keyPath] },
                set: { v in
                    var s = store.project.style
                    s[keyPath: keyPath] = v
                    store.setStyle(s, coalesce: false)
                })
    }

    /// 风格预设：这一页套上去的样子当按钮，正在用的那个描边（拖过滑杆就哪个都不是了）。
    private var presetBox: some View {
        GroupBox("风格") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(CollageStyles.all) { preset in
                    presetTile(preset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .onAppear { store.renderStyleThumbs() }
        .onChange(of: store.styleThumbSource) { _, _ in store.renderStyleThumbs() }
    }

    private func presetTile(_ preset: CollageStyles.Preset) -> some View {
        let active = store.project.style == preset.style
        return Button {
            store.setStyle(preset.style, coalesce: false)
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let image = store.styleThumbs[preset.key] {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.18))
                            .aspectRatio(store.project.canvas.aspect, contentMode: .fit)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(active ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: active ? 2.5 : 0.5))
                .frame(maxWidth: .infinity, maxHeight: 72)
                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "正在用「\(preset.name)」" : "整页换成「\(preset.name)」的纸、边距、缝、边框、色调")
    }

    /// 散落版没有格子：外边距、缝宽、形状、圆角、小格近景、边框、投影都不起作用 —— 灰掉，别让人拖了
    /// 半天画面不动还记一堆撤销。相框和投影在选中的相纸上按张调。
    private func gridOnlyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var spacingBox: some View {
        GroupBox("留白与形状") {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    CollageSlider(label: "外边距", value: styleBinding(\.margin), range: 0...0.14,
                                  display: percent(store.project.style.margin))
                    CollageSlider(label: "缝宽", value: styleBinding(\.gutter), range: 0...0.05,
                                  display: percent(store.project.style.gutter))
                    Picker("形状", selection: Binding(get: { store.project.style.shape }, set: { v in
                        var s = store.project.style
                        s.shape = v
                        store.setStyle(s, coalesce: false)
                    })) {
                        ForEach(CollageShape.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if store.project.style.shape == .rounded {
                        CollageSlider(label: "圆角", value: styleBinding(\.corner), range: 0...0.06,
                                      display: percent(store.project.style.corner))
                    }
                    Toggle("小格自动收近景", isOn: styleBool(\.tightSmallCells))
                        .help("小格子里的全身照隔一张收成半身：一张远景配几张近景，版面有节奏")
                }
                .disabled(store.isFreeform)
                if store.isFreeform { gridOnlyHint("散落版没有格子：上面几项只管网格版。") }
                CollageSlider(label: "输出锐化", value: styleBinding(\.sharpen), range: 0...1,
                              display: String(format: "%.2f", store.project.style.sharpen))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var backgroundBox: some View {
        GroupBox("底色") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(swatches, id: \.0) { item in
                        swatch(item.0, item.1)
                    }
                    ColorPicker("", selection: Binding(
                        get: { store.project.style.background.swiftUIColor },
                        set: { c in
                            var s = store.project.style
                            s.background = CollageColor(c)
                            // 模糊底、渐变底时这是盖在上面的纸色，不切回纯色。
                            if !s.backgroundMode.usesPaperTint { s.backgroundMode = .solid }
                            store.setStyle(s)
                        }), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 34)
                }
                Picker("底", selection: Binding(
                    get: { store.project.style.backgroundMode },
                    set: { mode in
                        var s = store.project.style
                        s.backgroundMode = mode
                        store.setStyle(s, coalesce: false)
                    })) {
                    ForEach(CollageBackgroundMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(backgroundHint)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CollageSlider(label: "纸纹", value: styleBinding(\.grain), range: 0...1,
                              display: String(format: "%.2f", store.project.style.grain))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var backgroundHint: String {
        switch store.project.style.backgroundMode {
        case .solid: return "整页一个颜色（上面的色块）"
        case .fromPhoto: return "底色往主图的色调上靠一点（压低饱和，不会染成照片的颜色）"
        case .blurPhoto: return "主图大幅模糊铺满整页，上面盖一层所选纸色；照片太暗或太亮时自动多盖一点，版面上的字照样看得清"
        case .gradient: return "主图上、下两截的颜色做竖向渐变（压低饱和、往所选纸色靠）"
        }
    }

    private func swatch(_ name: String, _ color: CollageColor) -> some View {
        let mode = store.project.style.backgroundMode
        let active = store.project.style.background == color && mode != .fromPhoto
        return Button {
            var s = store.project.style
            s.background = color
            // 模糊底、渐变底时色块换的是盖在上面的纸色。
            if !s.backgroundMode.usesPaperTint { s.backgroundMode = .solid }
            store.setStyle(s, coalesce: false)
        } label: {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(active ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: active ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var frameBox: some View {
        GroupBox("边框与投影") {
            VStack(alignment: .leading, spacing: 8) {
                if store.isFreeform { gridOnlyHint("散落版的相框、投影在「版式 › 选中的图层」里按张调。") }
                frameControls.disabled(store.isFreeform)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private var frameControls: some View {
        Picker("边框", selection: Binding(get: { store.project.style.border }, set: { v in
            var s = store.project.style
            s.border = v
            store.setStyle(s, coalesce: false)
        })) {
            ForEach(CollageBorder.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        if store.project.style.border == .hairline || store.project.style.border == .polaroid {
            ColorPicker("边框颜色", selection: Binding(
                get: { store.project.style.borderColor.swiftUIColor },
                set: { c in
                    var s = store.project.style
                    s.borderColor = CollageColor(c)
                    store.setStyle(s)
                }), supportsOpacity: false)
                .font(.caption)
        }
        CollageSlider(label: "投影", value: styleBinding(\.shadow), range: 0...1,
                      display: String(format: "%.2f", store.project.style.shadow))
    }
}

// MARK: - 文字

struct CollageTextPanel: View {
    @ObservedObject var store: CollageStore
    @State private var title = ""
    @State private var subtitle = ""

    var body: some View {
        GroupBox("标题") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("拾光", text: $title)
                    .onSubmit { store.setTitle(title) }
                    .onChange(of: title) { _, v in store.setTitle(v) }
                TextField("副标题 / 地点（{subtitle}）", text: $subtitle)
                    .onChange(of: subtitle) { _, v in store.setSubtitle(v) }
                Text("模板里的 {title} {subtitle} 就是这两行。其他占位符：{no} 期号 {date} {date_cn} {date_cn_full} {year_roman} {month_en} {model} {lens} {focal} {fnumber} {shutter} {iso}")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .onAppear {
            title = store.project.title
            subtitle = store.project.subtitle
        }
        .onChange(of: store.project.title) { _, v in if v != title { title = v } }
        .onChange(of: store.project.subtitle) { _, v in if v != subtitle { subtitle = v } }

        if let item = store.selectedItemValue {
            if item.kind == .text, let text = item.text {
                CollageTextEditor(store: store, text: text, target: .item(item.id))
                    .id(CollageTextTarget.item(item.id))
            } else {
                hint("选中的是贴纸 / 相纸：在「版式」里调")
            }
        } else if let path = store.selection, let cell = store.selectedCell {
            if cell.kind == .text, let text = cell.text {
                // 编辑器绑定到这一格的路径；换了格子就换一个编辑器实例（旧的文字框迟到的提交
                // 只会写回它自己那一格）。
                CollageTextEditor(store: store, text: text, target: .cell(path, store.page?.id))
                    .id(CollageTextTarget.cell(path, store.page?.id))
            } else if cell.kind == .photo {
                CollageOverlayBox(store: store, path: path, overlay: cell.overlay)
                if let overlay = cell.overlay {
                    CollageTextEditor(store: store, text: overlay.text,
                                      target: .overlay(path, cell.photoID, store.page?.id),
                                      alignFollowsAnchor: overlay.anchor != .custom, isOverlay: true)
                        .id(CollageTextTarget.overlay(path, cell.photoID, store.page?.id))
                }
            } else {
                addBox
            }
        } else {
            addBox
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private var addBox: some View {
        GroupBox("文字格") {
            VStack(alignment: .leading, spacing: 8) {
                Text("选中一张照片可以在照片上压字；选中文字格编辑内容；或者加一个：")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Group {
                        Button("上方横排") { store.addTextCell(edge: .top, vertical: false) }
                        Button("右侧竖排") { store.addTextCell(edge: .right, vertical: true) }
                    }
                    .disabled(store.root == nil || store.isFreeform)
                    .help(store.isFreeform ? "散落版没有格子：用「手写字」" : "")
                    Button("手写字") { store.addItemText() }
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// 一个文字格的全部参数：逐行字体/字号/字距/颜色，竖排、对齐、细线、印章。
struct CollageTextEditor: View {
    @ObservedObject var store: CollageStore
    let text: CollageText
    let target: CollageTextTarget
    /// 压字：对齐跟着位置走（贴左边就左对齐），没手动拖过时不给调。
    var alignFollowsAnchor = false
    /// 压字的字框就是字本身那么大：没有「垂直对齐」可言，横排多行才有「水平对齐」。
    var isOverlay = false

    private func update(_ body: (inout CollageText) -> Void) {
        var t = text
        body(&t)
        store.updateText(t, target: target)
    }

    var body: some View {
        GroupBox("排版") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("竖排（右起）", isOn: Binding(get: { text.vertical }, set: { v in update { $0.vertical = v } }))
                if alignFollowsAnchor {
                    Text("对齐跟着字的位置走：贴左边左对齐、居中居中、贴右边右对齐")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isOverlay {
                    if !text.vertical { horizontalPicker }
                } else {
                    alignPickers
                }
                CollageSlider(label: text.vertical ? "列距" : "行距",
                              value: Binding(get: { text.lineSpacing }, set: { v in update { $0.lineSpacing = v } }),
                              range: 0...2, display: String(format: "%.2f", text.lineSpacing))
                Toggle("细线", isOn: Binding(get: { text.rule }, set: { v in update { $0.rule = v } }))
                sealControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        ForEach(Array(text.lines.enumerated()), id: \.offset) { item in
            lineBox(index: item.offset, line: item.element)
        }
        HStack {
            Button("加一行") {
                update { t in
                    let size = (t.lines.last?.size ?? 0.04) * 0.5
                    t.lines.append(CollageTextLine("{date}", font: .didot, size: size, tracking: 0.3, color: .warmGrey))
                }
            }
            Spacer()
        }
        .font(.caption)
    }

    private var horizontalPicker: some View {
        Picker("水平", selection: Binding(get: { text.alignH }, set: { v in update { $0.alignH = v } })) {
            Text("左").tag(CollageAlign.leading)
            Text("中").tag(CollageAlign.center)
            Text("右").tag(CollageAlign.trailing)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var alignPickers: some View {
        horizontalPicker
        Picker("垂直", selection: Binding(get: { text.alignV }, set: { v in update { $0.alignV = v } })) {
            Text("上").tag(CollageAlign.leading)
            Text("中").tag(CollageAlign.center)
            Text("下").tag(CollageAlign.trailing)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var sealControls: some View {
        Toggle("印章", isOn: Binding(get: { text.seal != nil }, set: { on in
            update { $0.seal = on ? CollageSeal() : nil }
        }))
        if let seal = text.seal {
            HStack(spacing: 6) {
                TextField("印文（1–4 字）", text: Binding(get: { seal.text }, set: { v in
                    update { $0.seal?.text = String(v.prefix(4)) }
                }))
                ColorPicker("", selection: Binding(get: { seal.color.swiftUIColor }, set: { c in
                    update { $0.seal?.color = CollageColor(c) }
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34)
            }
            CollageSlider(label: "印章大小", value: Binding(get: { seal.size }, set: { v in update { $0.seal?.size = v } }),
                          range: 0.015...0.08, display: percent(seal.size))
        }
    }

    private func lineBox(index: Int, line: CollageTextLine) -> some View {
        GroupBox("第 \(index + 1) 行") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("文字或 {占位符}", text: Binding(get: { line.text }, set: { v in
                    update { $0.lines[index].text = v }
                }))
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { line.font }, set: { v in update { $0.lines[index].font = v } })) {
                        ForEach(CollageFont.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    Picker("", selection: Binding(get: { line.weight }, set: { v in update { $0.lines[index].weight = v } })) {
                        ForEach(CollageWeight.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    Toggle("斜", isOn: Binding(get: { line.italic }, set: { v in update { $0.lines[index].italic = v } }))
                        .toggleStyle(.button)
                        .help("斜体（西文字体有效）")
                }
                CollageSlider(label: "字号", value: Binding(get: { line.size }, set: { v in update { $0.lines[index].size = v } }),
                              range: 0.008...0.14, display: percent(line.size))
                CollageSlider(label: "字距", value: Binding(get: { line.tracking }, set: { v in update { $0.lines[index].tracking = v } }),
                              range: 0...0.8, display: String(format: "%.2f", line.tracking))
                if text.vertical {
                    CollageSlider(label: "下沉", value: Binding(get: { line.indent }, set: { v in update { $0.lines[index].indent = v } }),
                                  range: 0...12, display: String(format: "%.1f", line.indent))
                }
                HStack {
                    ColorPicker("颜色", selection: Binding(get: { line.color.swiftUIColor }, set: { c in
                        update { $0.lines[index].color = CollageColor(c) }
                    }), supportsOpacity: false)
                    .font(.caption)
                    Spacer()
                    Button(role: .destructive) {
                        update { t in
                            if t.lines.indices.contains(index) { t.lines.remove(at: index) }
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .disabled(text.lines.count <= 1)
                    .help("删掉这一行")
                }
                effectControls(index: index, line: line)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: 花字

    /// 花字：四个开关（描边 / 投影 / 底条 / 渐变）+ 现成搭配；开了哪个露出哪个的参数。全关 = 普通字，
    /// 打字从来不用先选样式。
    @ViewBuilder
    private func effectControls(index: Int, line: CollageTextLine) -> some View {
        let fx = line.effect ?? CollageTextEffect()
        HStack(spacing: 4) {
            Text("花字").frame(width: 30, alignment: .leading)
            effectToggle("描边", on: fx.stroke > 0.0001, index: index) { e, color, on in
                e.stroke = on ? 0.08 : 0
                if on { e.strokeColor = color.luminance > 0.5 ? .charcoal : .white }
            }
            effectToggle("投影", on: fx.shadow > 0.0001, index: index) { e, _, on in
                e.shadow = on ? 0.6 : 0
                if on {
                    e.shadowColor = CollageColor(r: 0, g: 0, b: 0)
                    e.shadowBlur = 0.12
                    e.shadowOffset = 0.06
                }
            }
            effectToggle("底条", on: fx.hasBand, index: index) { e, color, on in
                e.band = on ? 0.85 : 0
                if on {
                    e.bandColor = color.luminance > 0.5 ? .charcoal : .white
                    e.bandRound = 0.3
                }
            }
            effectToggle("渐变", on: fx.gradient != nil, index: index) { e, color, on in
                e.gradient = on ? (color.luminance > 0.5 ? CollageColor(hex: 0xE2B657) : CollageColor(hex: 0x3B5B8C)) : nil
            }
            Spacer(minLength: 0)
            Menu("样式") {
                ForEach(CollageTextEffects.presets) { preset in
                    Button(preset.name) { store.applyTextEffect(preset, line: index, target: target) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("套一个现成搭配（有的会换字色）；套完每一项还能单独调")
        }
        .font(.caption)
        if fx.stroke > 0.0001 {
            effectRow(CollageSlider(label: "描边", value: effectValue(index, \.stroke, fx), range: 0.02...0.3,
                                    display: percent(fx.stroke)),
                      color: effectColor(index, \.strokeColor, fx))
        }
        if fx.shadow > 0.0001 {
            effectRow(CollageSlider(label: "投影", value: effectValue(index, \.shadow, fx), range: 0.05...1,
                                    display: String(format: "%.2f", fx.shadow)),
                      color: effectColor(index, \.shadowColor, fx))
            CollageSlider(label: "模糊", value: effectValue(index, \.shadowBlur, fx), range: 0...0.6,
                          display: percent(fx.shadowBlur))
            CollageSlider(label: "下落", value: effectValue(index, \.shadowOffset, fx), range: 0...0.3,
                          display: fx.shadowOffset < 0.005 ? "发光" : percent(fx.shadowOffset))
                .help("拖到 0 = 四周一圈（发光），配浅色更像霓虹")
        }
        if fx.hasBand {
            effectRow(CollageSlider(label: "底条", value: effectValue(index, \.band, fx), range: 0.1...1,
                                    display: String(format: "%.2f", fx.band)),
                      color: effectColor(index, \.bandColor, fx))
            CollageSlider(label: "圆角", value: effectValue(index, \.bandRound, fx), range: 0...1,
                          display: String(format: "%.2f", fx.bandRound))
        }
        if let to = fx.gradient {
            ColorPicker("渐变到（下端）", selection: Binding(get: { to.swiftUIColor }, set: { c in
                updateEffect(index) { e, _ in e.gradient = CollageColor(c) }
            }), supportsOpacity: false)
            .font(.caption)
        }
    }

    private func effectRow(_ slider: CollageSlider, color: Binding<Color>) -> some View {
        HStack(spacing: 4) {
            slider
            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34)
        }
    }

    private func effectToggle(_ title: String, on: Bool, index: Int,
                              _ body: @escaping (inout CollageTextEffect, CollageColor, Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { v in
            updateEffect(index) { e, color in body(&e, color, v) }
        }))
        .toggleStyle(.button)
        .controlSize(.small)
    }

    /// 改这一行的花字（全关了就存成 nil，工程里不留一串 0）。
    private func updateEffect(_ index: Int, _ body: (inout CollageTextEffect, CollageColor) -> Void) {
        update { t in
            guard t.lines.indices.contains(index) else { return }
            var e = t.lines[index].effect ?? CollageTextEffect()
            body(&e, t.lines[index].color)
            t.lines[index].effect = e.isEmpty ? nil : e
        }
    }

    private func effectValue(_ index: Int, _ keyPath: WritableKeyPath<CollageTextEffect, Double>,
                             _ fx: CollageTextEffect) -> Binding<Double> {
        Binding(get: { fx[keyPath: keyPath] }, set: { v in updateEffect(index) { e, _ in e[keyPath: keyPath] = v } })
    }

    private func effectColor(_ index: Int, _ keyPath: WritableKeyPath<CollageTextEffect, CollageColor>,
                             _ fx: CollageTextEffect) -> Binding<Color> {
        Binding(get: { fx[keyPath: keyPath].swiftUIColor },
                set: { c in updateEffect(index) { e, _ in e[keyPath: keyPath] = CollageColor(c) } })
    }
}

// MARK: - 导出

struct CollageExportPanel: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        GroupBox("文件") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("文件名（留空 = 导出时间，精确到秒）", text: $store.exportName)
                    .textFieldStyle(.roundedBorder)
                    .help("直接写进输出目录，不另建文件夹；目录里有同名的自动加 -2、-3，不会覆盖")
                Picker("格式", selection: $store.exportOptions.format) {
                    ForEach(CollageExport.Format.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.exportOptions.format == .jpeg {
                    CollageSlider(label: "质量", value: $store.exportOptions.quality, range: 0.7...1,
                                  display: "\(Int(store.exportOptions.quality * 100))")
                }
                Text(summary).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        if store.isAlbum || store.project.canvas.bleed > 0 {
            printBox
        }
        GroupBox("输出目录") {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.outputFolder?.path ?? "先在批量页打开一个文件夹，或选一个输出目录")
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(store.outputFolder?.path ?? "")
                HStack {
                    Button("选择…") { pickFolder() }
                    Button("用默认") { store.exportOptions.outputPath = nil }
                        .disabled(store.exportOptions.outputPath == nil)
                        .help("默认 = 照片文件夹里的「拼图导出」（分析时自动跳过）")
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        Button {
            store.export()
        } label: {
            Label(store.isAlbum ? "导出相册" : "导出", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.exportBlockedReason != nil)
        .help(store.exportBlockedReason ?? "⌘E")
    }

    private var summary: String {
        let c = store.project.canvas
        let ext = store.exportOptions.format.ext
        let typed = CollageStore.cleanFileName(store.exportName, ext: ext)
        let name = typed.isEmpty ? CollageStore.stampFormatter.string(from: Date()) : typed
        let example = typed.isEmpty ? "（例）" : ""
        if store.isAlbum {
            let pdf = store.exportOptions.pdf ? " + \(name).pdf" : ""
            return "\(name)_跨页_01.\(ext)…\(pdf)\(example)：每个跨页 \(c.width + c.bleed * 2)×\(c.height + c.bleed * 2)px（含出血）；sRGB"
        }
        switch c.seams {
        case .grid9: return "\(name).\(ext) + \(name)_九宫格_1…9\(example)：整张 \(c.width)×\(c.height)px + 九宫格 9 张（每张 \(c.width / 3)×\(c.height / 3)）；sRGB"
        case .carousel: return "\(name).\(ext) + \(name)_轮播_1…\(c.slides)\(example)：每张 \(c.width / max(1, c.slides))×\(c.height)px；sRGB"
        default: return "\(name).\(ext)\(example)：\(c.width)×\(c.height)px；sRGB"
        }
    }

    private var printBox: some View {
        GroupBox("印刷") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("另出印刷 PDF", isOn: $store.exportOptions.pdf)
                    .disabled(!store.isAlbum)
                Toggle("PDF 带裁切线", isOn: $store.exportOptions.cropMarks)
                    .disabled(!store.isAlbum || !store.exportOptions.pdf)
                CollageSlider(label: "出血", value: mmBinding(\.bleed), range: 0...6,
                              display: String(format: "%.1fmm", mmValue(store.project.canvas.bleed)))
                CollageSlider(label: "安全区", value: mmBinding(\.safe), range: 0...12,
                              display: String(format: "%.1fmm", mmValue(store.project.canvas.safe)))
                Text("\(Int(store.project.canvas.dpi)) dpi · 成品 " + String(format: "%.1f×%.1fcm",
                     Double(store.project.canvas.width) / store.project.canvas.dpi * 2.54,
                     Double(store.project.canvas.height) / store.project.canvas.dpi * 2.54))
                    .font(.caption2).foregroundStyle(.secondary)
                if store.project.canvas.isPrint { upscaleSummary }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// 印刷前的分辨率检查：放大超过 120% 的照片有几张、在哪几页（画布上那几格也标了「放大」）。
    @ViewBuilder
    private var upscaleSummary: some View {
        let issues = store.upscaleIssues()
        if issues.isEmpty {
            Text("照片都没有放大到 120% 以上，印出来不会软")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            let pages = Set(issues.map(\.page)).sorted().map { "\($0 + 1)" }.joined(separator: "、")
            let worst = Int(((issues.first?.factor ?? 1) * 100).rounded())
            Label("\(issues.count) 张照片要放大到 120% 以上（最多 \(worst)%，在第 \(pages) 页）：印出来会软，少裁一点或缩小那一格",
                  systemImage: "plus.magnifyingglass")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mmValue(_ px: Int) -> Double { Double(px) / max(1, store.project.canvas.dpi) * 25.4 }

    private func mmBinding(_ keyPath: WritableKeyPath<CollageCanvas, Int>) -> Binding<Double> {
        Binding(get: { mmValue(store.project.canvas[keyPath: keyPath]) },
                set: { mm in
                    var c = store.project.canvas
                    c[keyPath: keyPath] = Int((mm / 25.4 * c.dpi).rounded())
                    store.setCanvas(c, coalesce: true)
                })
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择输出目录"
        if panel.runModal() == .OK, let url = panel.url { store.exportOptions.outputPath = url.path }
    }
}
