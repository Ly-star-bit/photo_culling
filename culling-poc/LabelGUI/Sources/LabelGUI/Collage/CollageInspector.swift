import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 右侧检视器：格式 / 样式 / 文档（照 Keynote：选中什么「格式」就显示什么，样式管整组，文档管整个工程）。
/// 模板、素材在左栏，导出设置在顶栏「导出 ▾」。所有改动都走 store 的方法（进撤销栈）。
struct CollageInspector: View {
    enum Tab: String, CaseIterable {
        /// 选中的照片格 / 文字 / 图层；什么都没选 = 这一页（CollageFormatPanel.swift）。
        case format = "格式"
        /// 整组：风格、色调、留白、底色、边框。
        case style = "样式"
        /// 整个工程：画布、标题和刊头、水印。
        case document = "文档"
    }

    let store: CollageStore
    /// 页签、「去那儿」的滚动（store.nav）：换页签只重算检视器。
    @ObservedObject var nav: CollageNav
    let watermarkStore: WatermarkStore

    init(store: CollageStore, watermarkStore: WatermarkStore) {
        self.store = store
        self.nav = store.nav
        self.watermarkStore = watermarkStore
    }

    var body: some View {
        let _ = CollagePerf.body("检视器")
        VStack(spacing: 0) {
            // 页签居中，最右边是收起右栏的按钮（⌥⌘S；收起以后画布右上角有一个按钮摊开），左边留一样宽的空当。
            HStack(spacing: 4) {
                Color.clear.frame(width: 22, height: 1)
                Spacer(minLength: 0)
                Picker("", selection: $nav.inspectorTab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("格式：选中的照片、文字、贴纸（没选中 = 这一页）；样式：整组的风格、色调、留白；文档：画布、标题、水印")
                Spacer(minLength: 0)
                CollagePaneToggle(edge: .trailing, shown: true) { store.workspace.inspectorHidden = true }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch nav.inspectorTab {
                        case .format: CollageFormatPanel(store: store)
                        case .style: CollageStylePanel(store: store)
                        case .document: CollageDocumentPanel(store: store, watermarkStore: watermarkStore)
                        }
                    }
                    .padding(10)
                }
                .collageScrollTarget(.inspector, nav: nav, proxy: proxy)
            }
        }
        // 滑杆松手 = 这一次拖动结束（CollageSlider 读它，CollageStore.endCoalescing）。
        .environment(\.collageUndo, store)
    }
}

// MARK: - 小组件

/// 滑杆松手时要告诉的 store（检视器、暗房在最外层放进环境）：松手 = 一次拖动结束，再拖同一根滑杆是新的一步撤销
/// （CollageStore.endCoalescing）。放 store 本身不放闭包：闭包每次重算 body 都是新的，读它的滑杆就跟着全部重算。
private struct CollageUndoKey: EnvironmentKey {
    static var defaultValue: CollageStore? { nil }
}

extension EnvironmentValues {
    var collageUndo: CollageStore? {
        get { self[CollageUndoKey.self] }
        set { self[CollageUndoKey.self] = newValue }
    }
}

struct CollageSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    @Environment(\.collageUndo) private var undo

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 56, alignment: .leading)
            Slider(value: $value, in: range) { editing in
                if !editing { undo?.endCoalescing() }
            }
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

// MARK: - 文档：画布 → 标题和刊头 → 水印

struct CollageDocumentPanel: View {
    let store: CollageStore
    let watermarkStore: WatermarkStore

    var body: some View {
        let _ = CollagePerf.body("文档面板")
        CollageCanvasBox(store: store)
            .collageSpot(.canvas, store.nav)
        CollageTitleBox(store: store)
            .collageSpot(.titles, store.nav)
        // 相册封面（CollageBookCoverPanel.swift）：只在相册时出现。
        CollageBookCoverBox(store: store)
            .collageSpot(.cover, store.nav)
        VStack(alignment: .leading, spacing: 12) {
            Text("水印").font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            CollageWatermarkPanel(store: store, watermarkStore: watermarkStore)
        }
        .collageSpot(.watermark, store.nav)
    }
}

// 画布

struct CollageCanvasBox: View {
    @ObservedObject var store: CollageStore
    @State private var customW = ""
    @State private var customH = ""

    var body: some View {
        GroupBox("画布") {
            VStack(alignment: .leading, spacing: 8) {
                if store.isAlbum {
                    // 相册：印厂规格（尺寸、出血、装订、页数、色彩一起换），自定义尺寸填单页的 cm（CollagePrintPanels）。
                    CollagePrintSpecMenu(store: store)
                    CollagePageSizeFields(store: store)
                } else {
                    Menu {
                        ForEach(CollageCanvas.social, id: \.name) { preset in
                            Button(preset.name) { store.setCanvas(preset) }
                        }
                    } label: {
                        Text(store.project.canvas.name).lineLimit(1)
                    }
                    .help("换画布：版式按比例缩放；想让照片重新贴合原比例，点画布空白处，在「格式 › 这一页」里点「贴合原比例」")
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
                }
                if store.project.canvas.seams == .grid9 {
                    Text("导出时另存 3×3 九张（每张 \(store.project.canvas.width / 3)×\(store.project.canvas.height / 3)），发朋友圈按顺序选图；脸不会压在切线上")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if store.project.canvas.seams == .carousel {
                    Text("导出时切成 \(store.project.canvas.slides) 张轮播，照片可以跨页连着；脸不会压在页缝上")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if store.project.canvas.seams == .fold {
                    foldControls
                    // 印厂规格里像素装不下的那几样：页数、首尾单页、中缝带、色彩、JPEG（CollagePrintPanels）。
                    Divider()
                    CollagePrintRulesBox(store: store)
                    // 目标跨页数、每跨页张数（CollageAlbumBudget.swift）。
                    Divider()
                    CollageAlbumBudgetControls(store: store)
                }
                if store.isAlbum || store.project.canvas.bleed > 0 {
                    CollageJumpText(store: store, lead: "出血、安全区、印刷 PDF 在顶栏", spot: .export, tail: "里",
                                    title: "导出 ▾")
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
        // 婚礼 fine-art 的编排从不跨缝（平铺也一样）。
        let rule = canvas.binding == .glued || store.project.albumTheme == .fineArt
            ? "照片不跨中缝，中缝两侧各 \(band) 不放脸" + (canvas.binding == .glued ? "" : "（婚礼相册编排不跨缝）")
            : "横图可以铺满两页，中缝两侧各 \(band) 不放脸"
        Text("\(rule)；出血 \(mm(canvas.bleed)) · 安全区 \(mm(canvas.safe))")
            .collageHint()
            .fixedSize(horizontal: false, vertical: true)
        if canvas.binding == .glued {
            let crossing = store.crossFoldPages()
            if !crossing.isEmpty {
                Label("第 " + crossing.map { "\($0 + 1)" }.joined(separator: "、") + " 页有照片压在中缝上：到那一页点备选条的「换一批」",
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
}

// MARK: - 样式

struct CollageStylePanel: View {
    @ObservedObject var store: CollageStore
    /// 风格预设样张在 store.thumbs 里。
    @ObservedObject var thumbs: CollageThumbs
    /// 「风格」摊没摊开（store.workspace）。
    @ObservedObject var workspace: CollageWorkspace

    init(store: CollageStore) {
        self.store = store
        self.thumbs = store.thumbs
        self.workspace = store.workspace
    }

    /// 「风格」收着时显示几个（两排）。
    static let collapsedPresetCount = 6

    /// 收着时显示哪几个预设（下标）：前 limit 个；正在用的那个排在后面就顶掉最后一个（收着也看得见现在用的是哪个）。
    nonisolated static func collapsedPresets(count: Int, active: Int?, limit: Int) -> [Int] {
        guard count > limit else { return Array(0..<count) }
        var shown = Array(0..<limit)
        if let active, active >= limit, active < count { shown[limit - 1] = active }
        return shown
    }

    private let swatches: [(String, CollageColor)] = [
        ("纸白", .paper), ("纯白", .white), ("米色", .rice), ("浅灰", CollageColor(hex: 0xE6E4E0)),
        ("墨黑", .charcoal), ("暖黑", CollageColor(hex: 0x2A2826)),
    ]

    var body: some View {
        let _ = CollagePerf.body("样式面板")
        presetBox
            .collageSpot(.presets, store.nav)
        CollageLookBox(store: store)
            .collageSpot(.looks, store.nav)
        spacingBox
            .collageSpot(.spacing, store.nav)
        backgroundBox
            .collageSpot(.background, store.nav)
        frameBox
            .collageSpot(.frame, store.nav)
    }

    private func styleBinding(_ keyPath: WritableKeyPath<CollageStyle, Double>) -> Binding<Double> {
        Binding(get: { store.project.style[keyPath: keyPath] },
                set: { v in
                    var s = store.project.style
                    s[keyPath: keyPath] = v
                    // 连拖合成一步只和同一根滑杆合并（key 是这一项）。
                    store.setStyle(s, key: keyPath)
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
        // 默认只摆两排（以前二十来个预设一口气排下去超过一屏，色调、留白、底色、边框都要滚过它才看得到）。
        let all = CollageStyles.all
        let active = all.firstIndex { isActive($0) }
        let shown = workspace.presetsExpanded ? Array(all.indices)
            : Self.collapsedPresets(count: all.count, active: active, limit: Self.collapsedPresetCount)
        return GroupBox("风格") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(shown, id: \.self) { i in
                        presetTile(all[i], active: i == active)
                    }
                }
                if all.count > Self.collapsedPresetCount {
                    Button {
                        workspace.presetsExpanded.toggle()
                    } label: {
                        Label(workspace.presetsExpanded ? "收起" : "全部 \(all.count) 个风格",
                              systemImage: workspace.presetsExpanded ? "chevron.up" : "chevron.down")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .help(workspace.presetsExpanded ? "只留两排（正在用的那个一直看得见）" : "摊开全部风格预设")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .onAppear { store.renderStyleThumbs() }
        .onChange(of: store.styleThumbSource) { _, _ in store.renderStyleThumbs() }
    }

    /// 正在用这个预设（拖过滑杆就哪个都不是了）。婚礼 fine-art 的预设按册子尺寸重算过边距（setStyle）：按重算后的比。
    private func isActive(_ preset: CollageStyles.Preset) -> Bool {
        store.project.style == (CollageStyleFineArt.adapted(preset.style, to: store.project.canvas) ?? preset.style)
    }

    private func presetTile(_ preset: CollageStyles.Preset, active: Bool) -> some View {
        Button {
            store.setStyle(preset.style, coalesce: false)
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let image = thumbs.styles[preset.key] {
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
            .collageHint()
            .fixedSize(horizontal: false, vertical: true)
    }

    private var spacingBox: some View {
        GroupBox("留白与形状") {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let insets = store.project.style.insets {
                        insetsControls(insets)
                    } else {
                        CollageSlider(label: "外边距", value: styleBinding(\.margin), range: 0...0.14,
                                      display: percent(store.project.style.margin))
                    }
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
                .disabled(store.isFreeform || store.isContactSheet)
                if store.isFreeform { gridOnlyHint("散落版没有格子：上面几项只管网格版。") }
                if store.isContactSheet {
                    CollageJumpText(store: store, lead: "印样没有格子：留白、倾斜在", spot: .contact, tail: "里调。")
                }
                CollageSlider(label: "输出锐化", value: styleBinding(\.sharpen), range: 0...1,
                              display: String(format: "%.2f", store.project.style.sharpen))
                    // 加了网的照片不锐化（锐化会在网点边上起白边）。
                    .disabled(store.project.style.halftone != nil)
                    .help(store.project.style.halftone != nil ? "照片加了网（报纸风）不锐化：锐化会在网点边上起白边"
                          : "照片缩到格子大小之后补的锐化（预览和导出一样）")
                // 灰掉的滑杆说一句为什么（禁用控件上的悬停提示不一定出得来）。
                if store.project.style.halftone != nil {
                    gridOnlyHint("照片加了网（报纸风）：输出锐化不起作用，锐化会在网点边上起白边。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// 四边边距（留白杂志、婚礼相册的预设带的）：四边各一根滑杆（以前只印一行读数，300pt 宽时后两个数截掉，
    /// 也改不了，只能「改回统一」）。单页左 = 内、右 = 外；相册跨页的内在中缝两侧、外是跨页左右两头
    /// （CollageLayout.contentRect / foldGap）。范围同读工程文件、ops insets: 的 0…0.4。
    @ViewBuilder
    private func insetsControls(_ insets: CollageInsets) -> some View {
        let spread = store.project.canvas.seams == .fold
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("四边边距分开设（样式预设带的）")
                .collageHint()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("改回统一") {
                var s = store.project.style
                s.insets = nil
                store.setStyle(s, coalesce: false)
            }
            .font(.caption)
            .help("四边用同一个外边距（一根滑杆）")
        }
        CollageSlider(label: "上边距", value: insetBinding(\.top), range: 0...0.4, display: percent(insets.top))
        CollageSlider(label: "下边距", value: insetBinding(\.bottom), range: 0...0.4, display: percent(insets.bottom))
        CollageSlider(label: spread ? "中缝两侧" : "左边距", value: insetBinding(\.inner), range: 0...0.4,
                      display: percent(insets.inner))
            .help(spread ? "订口：每页靠中缝那一侧留多宽（中缝两边各留这么宽）" : "单页的内边距 = 左边")
        CollageSlider(label: spread ? "左右两头" : "右边距", value: insetBinding(\.outer), range: 0...0.4,
                      display: percent(insets.outer))
            .help(spread ? "切口：跨页最左、最右两头留多宽" : "单页的外边距 = 右边")
    }

    private func insetBinding(_ keyPath: WritableKeyPath<CollageInsets, Double>) -> Binding<Double> {
        Binding(get: { store.project.style.insets?[keyPath: keyPath] ?? 0 },
                set: { v in
                    var s = store.project.style
                    s.insets?[keyPath: keyPath] = min(0.4, max(0, v))
                    store.setStyle(s, key: keyPath)
                })
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
                    .collageHint()
                    .fixedSize(horizontal: false, vertical: true)
                CollageSlider(label: "纸纹", value: styleBinding(\.grain), range: 0...1,
                              display: String(format: "%.2f", store.project.style.grain))
                CollageSlider(label: "压照片", value: styleBinding(\.paperOverPhotos), range: 0...1,
                              display: String(format: "%.2f", store.project.style.paperOverPhotos))
                    .help("纸纹也压在照片上，照片的白往纸色靠一点：像印在这张纸上（报纸风、婚礼相册）")
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
                if store.isFreeform { gridOnlyHint("散落版的相框、投影按张调：点画布上的一张照片，在「格式」里。") }
                if store.isContactSheet { gridOnlyHint("印样的片条自己有片边，不加边框、投影。") }
                frameControls.disabled(store.isFreeform || store.isContactSheet)
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
        if store.project.style.border == .mat {
            // 和解码、ops 的 mat: 同一个范围（0.01…0.3），模板里的值不会一拖就被滑杆截掉。
            CollageSlider(label: "卡纸宽", value: styleBinding(\.matWidth), range: 0.01...0.3,
                          display: String(format: "%.0f%%", store.project.style.matWidth * 100))
                .help("每边卡纸占格子短边多少；底边再宽两成（装裱的惯例，不然照片看起来往下掉）。照片外几毫米一道细线")
        }
        if [.hairline, .polaroid, .mat].contains(store.project.style.border) {
            ColorPicker(store.project.style.border == .mat ? "卡纸颜色" : "边框颜色", selection: Binding(
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

// MARK: - 标题和刊头（文档）

/// 标题 / 副标题 / 刊头 / 期号：模板里的 {title} {subtitle} {masthead} {issue}。占位符说明收进 ⓘ 弹出框
/// （以前 567 个字常驻在这一块里，选中的文字编辑器被挤到下面）。选中的文字格、照片上的字在「格式」里改。
struct CollageTitleBox: View {
    @ObservedObject var store: CollageStore
    @State private var title = ""
    @State private var subtitle = ""
    @State private var masthead = ""
    @State private var issue = ""
    @State private var helpShown = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                TextField("拾光", text: $title)
                    .onSubmit { store.setTitle(title) }
                    .onChange(of: title) { _, v in store.setTitle(v) }
                TextField("副标题 / 地点", text: $subtitle)
                    .onChange(of: subtitle) { _, v in store.setSubtitle(v) }
                HStack(spacing: 6) {
                    // 刊头不预置任何刊名：空着就用标题（拉丁字母转大写，中文转拼音大写）。
                    // 占位字要在 300pt 宽里放得下（旁边还有 96pt 的期号）：{masthead} 这个键在 ⓘ 的占位符说明里有，
                    // 这里留「空着会怎样」。
                    TextField("刊头（空 = 标题拼音）", text: $masthead)
                        .onChange(of: masthead) { _, v in store.setMasthead(v) }
                        .help("{masthead}：刊头。空着 = 用标题（拉丁字母转大写，中文转拼音大写）")
                    TextField("期号", text: $issue)
                        .onChange(of: issue) { _, v in store.setIssue(v) }
                        .frame(width: 96)
                }
                if CollageTypeset.mastheadLooksReal(masthead: store.project.masthead, title: store.project.title) {
                    // 不拦：只提醒一句（自己的作品集、内部用都可以）。
                    Text("这个刊头像是真实杂志的名字：发出去前确认能用")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("模板里的 {title} {subtitle} {masthead} {issue} 就是这几行；选中画布上的字，在「格式」里改字体、字号、花字。")
                    .collageHint()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            HStack(spacing: 4) {
                Text("标题和刊头")
                Button {
                    helpShown.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("其他占位符和写法")
                .popover(isPresented: $helpShown, arrowEdge: .leading) {
                    Text(Self.placeholderHelp)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(width: 340)
                        .padding(12)
                }
            }
        }
        .onAppear {
            title = store.project.title
            subtitle = store.project.subtitle
            masthead = store.project.masthead
            issue = store.project.issue
        }
        .onChange(of: store.project.title) { _, v in if v != title { title = v } }
        .onChange(of: store.project.subtitle) { _, v in if v != subtitle { subtitle = v } }
        .onChange(of: store.project.masthead) { _, v in if v != masthead { masthead = v } }
        .onChange(of: store.project.issue) { _, v in if v != issue { issue = v } }
    }

    /// 占位符说明（ⓘ 弹出框）：一字不改搬过来的。
    static let placeholderHelp = "模板里的 {title} {subtitle} {masthead} {issue} 就是这几行。其他占位符：{initial} 刊头首字母 {masthead_short} 截短的刊头（时尚刊）{masthead_alt} 和标题不是同一串字时的刊头（同一串时为空）{no} 页码 {date} {date_cn} {date_cn_full} {year} {weekday_cn} {weekday_en} {lunar} 农历 {ganzhi} 干支 {year_roman} {month_en} {month_en_title} {day_n} 不补零的日 {issue_n} 不补零的期号 {issue_cn} 中文期号 {count_cn} 中文张数 {frame} 帧号 {model} {lens} {focal} 35mm 等效焦距（相机没写等效时是实际焦距） {focal_mm} 实际焦距 {fnumber} {fstop} f/光圈 {shutter} {iso}。写法：{model|未记录} 没有值时印竖线后面的字；{model|} 可省略：「 · 」隔开的一段里这种占位符全空，连同分隔点不印；[[…]] 里面有占位符是空的，整段不印（没有拍摄时间的照片不剩半句）；[[甲||乙]] 甲印不出来就印乙"
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
                        .collageHint()
                        .fixedSize(horizontal: false, vertical: true)
                } else if isOverlay {
                    if !text.vertical { horizontalPicker }
                } else {
                    alignPickers
                }
                CollageSlider(label: text.vertical ? "列距" : "行距",
                              value: Binding(get: { text.lineSpacing }, set: { v in update { $0.lineSpacing = v } }),
                              range: -0.15...2, display: String(format: "%.2f", text.lineSpacing))
                    .help("小于 0 = 紧排（上下两行的字框叠一点，瑞士海报那种）")
                Picker("转向", selection: Binding(get: { text.rotation }, set: { v in update { $0.rotation = v } })) {
                    Text("不转").tag(0)
                    Text("顺转 90°").tag(90)
                    Text("逆转 90°").tag(-90)
                }
                .pickerStyle(.segmented)
                .help("整块字转 90°：顺转从上往下读，逆转从下往上读（贴着长边的巨字）")
                HStack(spacing: 6) {
                    Toggle("细线", isOn: Binding(get: { text.rule }, set: { v in update { $0.rule = v } }))
                    if text.rule {
                        Picker("", selection: Binding(get: { text.ruleStyle }, set: { v in update { $0.ruleStyle = v } })) {
                            ForEach(CollageRuleStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .help("短线 = 字后一小截；通栏 = 和字块一样宽；每行下面 = 瑞士海报；粗细双线 = 报头下面")
                    }
                }
                sealControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        bodyBox
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

    /// 正文：多栏排的一段段字；不打字就是灰条（看着像报纸正文，不假装有字）。
    @ViewBuilder
    private var bodyBox: some View {
        GroupBox("正文") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("多栏正文", isOn: Binding(get: { text.body != nil }, set: { on in
                    update { $0.body = on ? ($0.body ?? CollageBody()) : nil }
                }))
                .help("排在标题下面（竖排标题时在左边），占满剩下的地方")
                if let body = text.body {
                    TextField("正文（换行分段；空着 = 灰条）", text: Binding(get: { body.text }, set: { v in
                        update { t in
                            t.body?.text = v
                            // 自己打过字就不再是占位字了。
                            t.body?.filler = false
                        }
                    }), axis: .vertical)
                    .lineLimit(3...8)
                    if body.text.isEmpty || body.filler {
                        Text(body.text.isEmpty ? "现在画的是灰条：印刷导出会提醒换成自己的字" : "这是占位字：印刷导出会提醒换成自己的字")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Stepper("\(body.columns) 栏", value: Binding(get: { body.columns }, set: { v in
                            update { $0.body?.columns = min(12, max(1, v)) }
                        }), in: 1...12)
                        Toggle("两端对齐", isOn: Binding(get: { body.justified }, set: { v in update { $0.body?.justified = v } }))
                        Toggle("平衡", isOn: Binding(get: { body.balanced }, set: { v in update { $0.body?.balanced = v } }))
                            .help("平衡分栏：各栏行数平均分，不是排满一栏再接下一栏（首字下沉时不平衡）")
                    }
                    .font(.caption)
                    HStack(spacing: 6) {
                        Toggle("栏线", isOn: Binding(get: { body.columnRule }, set: { v in update { $0.body?.columnRule = v } }))
                        Toggle("首字下沉", isOn: Binding(get: { body.dropCap > 0 }, set: { v in update { $0.body?.dropCap = v ? 3 : 0 } }))
                            .disabled(body.vertical)
                        Toggle("竖排", isOn: Binding(get: { body.vertical }, set: { v in update { $0.body?.vertical = v } }))
                    }
                    .font(.caption)
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(get: { body.font }, set: { v in update { $0.body?.font = v } })) {
                            ForEach(CollageFont.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        ColorPicker("", selection: Binding(get: { body.color.swiftUIColor }, set: { c in
                            update { $0.body?.color = CollageColor(c) }
                        }), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 34)
                        Toggle("繁体", isOn: Binding(get: { body.traditional }, set: { v in update { $0.body?.traditional = v } }))
                            .font(.caption)
                            .help("简转繁：打简体也印成繁体（民国竖排）")
                    }
                    CollageSlider(label: "字号", value: Binding(get: { body.size }, set: { v in update { $0.body?.size = v } }),
                                  range: 0.005...0.04, display: percent(body.size))
                    CollageSlider(label: "行高", value: Binding(get: { body.leading }, set: { v in update { $0.body?.leading = v } }),
                                  range: 1...2.2, display: String(format: "%.2f", body.leading))
                    CollageSlider(label: "段首缩进", value: Binding(get: { body.firstLineIndent }, set: { v in
                        update { $0.body?.firstLineIndent = v }
                    }), range: 0...3, display: String(format: "%.1f", body.firstLineIndent))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
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
                              range: 0.008...0.45, display: percent(line.size))
                    .disabled(line.fitWidth)
                    .help(line.fitWidth ? "铺满宽度时字号跟着框宽走" : "")
                HStack(spacing: 6) {
                    Toggle("铺满宽度", isOn: Binding(get: { line.fitWidth }, set: { v in update { $0.lines[index].fitWidth = v } }))
                        .help("字号放大 / 缩小到正好占满字块能用的宽（刊头）；照片上的字按「最宽」那一格算")
                    Spacer(minLength: 0)
                    Picker("", selection: Binding(get: { line.textCase }, set: { v in update { $0.lines[index].textCase = v } })) {
                        ForEach(CollageTextCase.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .help("大小写：占位符展开之后再改（{month_en} 选「首字母大写」= October）；繁体 = 简转繁，繁体右起 = 再从右往左排（民国横排标题条）")
                }
                .font(.caption)
                CollageSlider(label: "压窄", value: Binding(get: { line.widthScale }, set: { v in update { $0.lines[index].widthScale = v } }),
                              range: 0.85...1, display: percent(line.widthScale))
                    .help("横向压窄（最多到 85%）：长刊名铺满宽度后字太矮时，宁可压窄一点也不再缩字号")
                CollageSlider(label: "字距", value: Binding(get: { line.tracking }, set: { v in update { $0.lines[index].tracking = v } }),
                              range: 0...0.8, display: String(format: "%.2f", line.tracking))
                if text.vertical {
                    CollageSlider(label: "下沉", value: Binding(get: { line.indent }, set: { v in update { $0.lines[index].indent = v } }),
                                  range: 0...12, display: String(format: "%.1f", line.indent))
                }
                HStack {
                    // 「颜色从照片取」开着时（时尚刊的标题 / 导语）画的是照片里挑出来的颜色，这个色块只是挑不出来时的
                    // 备用色：挑一个颜色 = 改用挑的（同一步撤销里把「从照片取」关掉），不然挑了也看不出变化。
                    ColorPicker("颜色", selection: Binding(get: { line.color.swiftUIColor }, set: { c in
                        update {
                            $0.lines[index].color = CollageColor(c)
                            $0.lines[index].accentFromPhoto = false
                        }
                    }), supportsOpacity: false)
                    .font(.caption)
                    Toggle("从照片取", isOn: Binding(get: { line.accentFromPhoto }, set: { v in
                        update { $0.lines[index].accentFromPhoto = v }
                    }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("颜色从照片取：挑主体里最鲜艳、和字底下对比够 3:1 的颜色（挑不出来用左边的颜色）；挑一个颜色就改用挑的")
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
                if line.accentFromPhoto {
                    Text("现在用照片里的颜色；关掉「从照片取」或挑一个颜色，才用左边那个")
                        .collageHint()
                        .fixedSize(horizontal: false, vertical: true)
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
            Menu("搭配") {
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

// MARK: - 导出（顶栏「导出 ▾」弹出来的那一块）

struct CollageExportPanel: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        GroupBox("文件") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("文件名（留空 = 导出时间，精确到秒）", text: $store.exportName)
                    .textFieldStyle(.roundedBorder)
                    .help("直接写进输出目录，不另建文件夹；目录里有同名的自动加 -2、-3，不会覆盖")
                Picker("文件格式", selection: $store.exportOptions.format) {
                    ForEach(CollageExport.Format.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.exportOptions.format == .jpeg {
                    CollageSlider(label: "质量", value: $store.exportOptions.quality, range: 0.7...1,
                                  display: "\(Int(store.exportOptions.quality * 100))")
                }
                scalePicker
                watermarkToggle
                // 相册：全部 / 当前跨页 / 自定义（CollagePrintPanels）。
                if store.isAlbum { CollageExportRangeBox(store: store) }
                Text(summary).collageHint()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        if store.isAlbum || store.project.canvas.bleed > 0 {
            printBox
        }
        // 相册、印刷画布：交出去之前那几样，一条一条列出来、点了跳过去（放大、空格、页数、脸压中缝、字出安全区……）。
        if store.isAlbum || store.project.canvas.isPrint {
            CollagePreflightBox(store: store)
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
            store.nav.exportShown = false
            store.export()
        } label: {
            Label(store.isAlbum ? "导出相册" : "导出", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.exportBlockedReason != nil)
        .help(store.exportBlockedReason ?? "⌘E")
    }

    /// 工程里开着水印层就显示（开关跟着这个拼图存，别的拼图不受影响）：关掉 = 导出一版干净的（预览照样显示
    /// 水印，水印设置也不动）。关着的时候写一行，免得忘了。两层都关了就不显示（本来就没水印可带）。
    @ViewBuilder
    private var watermarkToggle: some View {
        if Self.showsWatermarkToggle(store.project.watermark) {
            Toggle("导出带水印", isOn: exportWatermarkBinding)
                .help("只管这个拼图：关掉 = 导出时不带水印（预览里照样显示，「文档 › 水印」里的设置不动）")
            if store.project.watermark?.exportEnabled == false {
                Text("这个拼图导出时不带水印（预览照常显示）")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 清晰度：标准 = 画布的平台尺寸；2 / 3 倍 = 版式不变、像素按倍数放大。只列这张画布放得下的倍数
    /// （九宫格、轮播最多 2 倍）；印刷画布本来就是 300 dpi 成品尺寸，不显示。选的倍数记在导出设置里，换到放不下的
    /// 画布时显示实际用的那一档，换回来还是原来选的。
    @ViewBuilder
    private var scalePicker: some View {
        let most = CollageStore.maxExportScale(store.project.canvas)
        if most > 1 {
            Picker("清晰度", selection: scaleBinding) {
                ForEach(1...most, id: \.self) { k in
                    Text(k == 1 ? "标准" : "\(k) 倍").tag(k)
                }
            }
            .pickerStyle(.segmented)
            .help("标准 = 社交平台的尺寸（平台上传时还会再压缩）；2 倍、3 倍版式不变、像素按倍数放大，适合留底、发给客户、打印。"
                  + "原图不够大的照片会被放大：不比标准的更糊，只是不会更清楚。")
        }
    }

    private var scaleBinding: Binding<Int> {
        Binding(get: { CollageStore.exportScale(canvas: store.project.canvas, options: store.exportOptions) },
                set: { store.exportOptions.scale = $0 })
    }

    /// 导出设置里显示「导出带水印」开关：至少开着一层水印（--collage-ui --tab 导出 按同一个判断打印「导出面板」行）。
    static func showsWatermarkToggle(_ wm: CollageWatermark?) -> Bool { wm?.anyLayerOn == true }

    private var exportWatermarkBinding: Binding<Bool> {
        Binding(get: { store.project.watermark?.exportEnabled ?? true },
                set: { on in store.updateWatermark { $0.exportEnabled = on } })
    }

    private var summary: String {
        let c = store.project.canvas
        let ext = store.exportOptions.format.ext
        let typed = CollageStore.cleanFileName(store.exportName, ext: ext)
        let name = typed.isEmpty ? CollageStore.stampFormatter.string(from: Date()) : typed
        let example = typed.isEmpty ? "（例）" : ""
        if store.isAlbum {
            // 部分导出不出 PDF（拆成单独的 let：整串插值太长 CI 的 Xcode 16 会类型检查超时）。
            let partial: Bool = (try? store.exportPageSelection.get()).flatMap { $0 } != nil
            let pdf: String = store.exportOptions.pdf && !partial ? " + \(name).pdf" : ""
            let fullW: Int = c.width + c.bleed * 2
            let fullH: Int = c.height + c.bleed * 2
            let color: String = c.exportColorSpace.label
            return "\(name)_跨页_01.\(ext)…\(pdf)\(example)：每个跨页 \(fullW)×\(fullH)px（含出血）；\(color)"
        }
        // 单张模式里有好几页（出一期、按卷出印样）：每页一个文件，名字后面加 _01…_NN（exportPlan）。
        let pages = store.project.pages.count
        let base = pages > 1 ? "\(name)_01…_\(String(format: "%02d", pages))" : name
        let perPage = pages > 1 ? "（\(pages) 页，每页一份）" : ""
        // 按清晰度乘过的成品像素（拆成单独的 Int：整串插值太长 CI 的 Xcode 16 会类型检查超时）。
        let k = CollageStore.exportScale(canvas: c, options: store.exportOptions)
        let w: Int = c.width * k
        let h: Int = c.height * k
        let slideW: Int = w / max(1, c.slides)
        switch c.seams {
        case .grid9: return "\(base).\(ext) + \(base)_九宫格_1…9\(example)\(perPage)：整张 \(w)×\(h)px + 九宫格 9 张（每张 \(w / 3)×\(h / 3)）；sRGB"
        case .carousel: return "\(base).\(ext) + \(base)_轮播_1…\(c.slides)\(example)\(perPage)：每张 \(slideW)×\(h)px；sRGB"
        default: return "\(base).\(ext)\(example)\(perPage)：\(w)×\(h)px；sRGB"
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
                // 放大超过 120% 的照片以前在这里汇总一句，现在一条条列在下面的「导出前检查」里（点了跳过去）。
                if store.isAlbum { CollageProofButton(store: store) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
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
        // 选到拍摄文件夹里面（下次分析会扫到）就不换、lastError 说清楚（审查 S11）
        if panel.runModal() == .OK, let url = panel.url { store.chooseOutputFolder(url) }
    }
}
