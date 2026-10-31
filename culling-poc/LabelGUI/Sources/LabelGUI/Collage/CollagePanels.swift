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
        let _ = CollagePerf.body("模板库")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.0) { group in
                section(group.0, group.1)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: refreshKey) { _, _ in refresh() }
    }

    private func refresh() { store.renderTemplateThumbs() }

    /// 什么变了要问一次重渲（每个模板还要不要重渲，store 按它自己的键判）。合成一个键：一长串
    /// onChange 让 Xcode 16 的类型检查慢得要命。
    private struct RefreshKey: Equatable {
        var photos: Int
        var templates: [CollageTemplate]
        var hints: Int
        var style: CollageStyle
        var canvas: CollageCanvas
        var mode: CollageMode
        var title: String
        var subtitle: String
        var masthead: String
        var issue: String
        var pagePhotos: [String]
        /// 这一页、每格单独设的色调（套模板会留着它们，缩略图跟着）。
        var looks: String
    }

    private var refreshKey: RefreshKey {
        let p = store.project
        return RefreshKey(photos: p.photos.count, templates: store.userTemplates, hints: store.hintsVersion,
                          style: p.style, canvas: p.canvas, mode: p.mode, title: p.title, subtitle: p.subtitle,
                          masthead: p.masthead, issue: p.issue, pagePhotos: (store.page?.photoIDs ?? []).sorted(),
                          looks: CollageStore.lookSignature(store.page))
    }

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

    /// 相册里套模板不换画布：占位的比例也按相册跨页。
    private var aspect: CGFloat {
        let c = (store.isAlbum ? nil : template.canvas) ?? store.project.canvas
        return CGFloat(c.width) / CGFloat(max(1, c.height))
    }

    var body: some View {
        let _ = CollagePerf.body("模板格")
        Button {
            store.applyTemplate(template)
        } label: {
            tile
        }
        .buttonStyle(.plain)
        .disabled(store.project.photos.isEmpty)
        .help(helpText)
        .contextMenu {
            if !template.builtin {
                Button("删除「\(template.name)」", role: .destructive, action: onDelete)
            }
        }
    }

    private var tile: some View {
        VStack(spacing: 3) {
            // 高度跟着比例走：相册里的缩略图是 2:1 的跨页，固定 104 高上下空出一大截。
            thumb
                .frame(maxWidth: .infinity, maxHeight: 104)
            Text(template.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
    }

    private var helpText: String {
        let canvas = template.canvas.map { " · \($0.name)" } ?? ""
        let empty = store.project.photos.isEmpty ? "（先带照片进托盘）" : ""
        return "\(template.name) · \(template.photoSlots) 张" + canvas + empty
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
                HStack(spacing: 6) {
                    Text("这一页").font(.caption).frame(width: 56, alignment: .leading)
                    Menu(store.page?.look.map { $0.look.label } ?? "跟着整体") {
                        Button("跟着整体") { store.setPageLook(nil) }
                        Divider()
                        ForEach(CollageLook.allCases, id: \.self) { look in
                            Button(look.label) {
                                store.setPageLook(CollageLookSetting(look: look, strength: store.project.style.lookStrength))
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(store.page == nil)
                    .help("只给这一页换色调（整章黑白、一期杂志里的一页黑白）；格子还能在「版式」里单独设")
                }
                halftoneControls
                Text("整组照片套同一个色调；导出和预览一样。黑白、旧照的强度只管影调。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .onAppear { store.renderLookThumbs() }
        .onChange(of: store.pageIndex) { _, _ in store.renderLookThumbs() }
        .onChange(of: store.project.photos.count) { _, _ in store.renderLookThumbs() }
        // 开了加网，色调样张也按加网画（纸色跟页面底色，所以底色变了也要重画）。
        .onChange(of: store.project.style.halftone) { _, _ in store.renderLookThumbs() }
        .onChange(of: store.project.style.background) { _, _ in store.renderLookThumbs() }
    }

    /// 照片加网（报纸风）：开关、网型、点距、网点增大、墨色、纸色。纸色默认跟页面底色（深色页上换成纸白）。
    @ViewBuilder
    private var halftoneControls: some View {
        let ht = store.project.style.halftone
        Toggle("照片加网（报纸）", isOn: Binding(get: { ht != nil }, set: { on in
            var s = store.project.style
            s.halftone = on ? (s.halftone ?? CollageHalftone()) : nil
            store.setStyle(s, coalesce: false)
        }))
        .font(.caption)
        .help("照片变成墨色网点印在纸上（纸色跟页面底色，模糊底、渐变底时跟底色块；深色页上换成纸白，不然照片黑在黑上）。界面缩得小时只调明暗不出点，导出照常出点")
        if let ht {
            Picker("网型", selection: Binding(get: { ht.screen }, set: { v in
                var s = store.project.style
                s.halftone?.screen = v
                store.setStyle(s, coalesce: false)
            })) {
                ForEach(CollageScreen.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 点距按对数拖：范围和解码、halftone: 一样（0.5‰…50‰，两个数量级），线性拖的话常用的 1–12‰ 全挤在
            // 最左边一小截；对数刻度下 4‰ 在中间偏左。
            let pitchRange = CollageHalftone.pitchRange
            CollageSlider(label: "点距", value: Binding(get: {
                log10(min(pitchRange.upperBound, max(pitchRange.lowerBound, ht.pitch)))
            }, set: { v in
                var s = store.project.style
                s.halftone?.pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound, pow(10, v)))
                store.setStyle(s)
            }), range: log10(pitchRange.lowerBound)...log10(pitchRange.upperBound),
                          display: String(format: ht.pitch < 0.01 ? "%.1f‰" : "%.0f‰", ht.pitch * 1000))
                .help("点距占画布短边的千分之几：4‰ 在 1440 宽上约 6 像素；1‰ 接近真报纸，只适合大尺寸印刷；20‰ 以上是波普风的大点")
            // 网角、锐度以前只有 ops 的 halftone: 能改。网角按 0…180° 显示（线网转 180° 是同一个样子；点网 90° 一个周期）。
            let angle = Self.screenAngle(ht.angle)
            CollageSlider(label: "网角", value: Binding(get: { angle }, set: { v in
                var s = store.project.style
                s.halftone?.angle = min(180, max(0, v))
                store.setStyle(s)
            }), range: 0...180, display: String(format: "%.0f°", angle))
                .help("网点（网线）排的方向：黑版 45° 最不显网；线网 0° 是横线、90° 是竖线")
            CollageSlider(label: "锐度", value: halftoneBinding(\.sharpness), range: 0...1,
                          display: percentText(ht.sharpness))
                .help("网点的边：60–75% 像油墨在纸上洇开，90% 以上是波普风的硬点")
            CollageSlider(label: "网点增大", value: halftoneBinding(\.gain), range: 0...1,
                          display: percentText(ht.gain))
                .help("报纸上中间调印得比原稿暗的那一截：100% = 新闻纸实测，0 = 不加")
            HStack(spacing: 10) {
                ColorPicker("墨色", selection: Binding(get: { ht.ink.swiftUIColor }, set: { c in
                    var s = store.project.style
                    s.halftone?.ink = CollageColor(c)
                    store.setStyle(s)
                }), supportsOpacity: false)
                // 纸色没设时显示的是实际用的那个（页面底色，深色页上是纸白）；一改就定死成这个颜色。
                ColorPicker("纸色", selection: Binding(get: {
                    CollageScreening.paper(ht, background: store.project.style.background).swiftUIColor
                }, set: { c in
                    var s = store.project.style
                    s.halftone?.paper = CollageColor(c)
                    store.setStyle(s)
                }), supportsOpacity: false)
                if ht.paper != nil {
                    Button("跟页面") {
                        var s = store.project.style
                        s.halftone?.paper = nil
                        store.setStyle(s, coalesce: false)
                    }
                    .controlSize(.small)
                    .help("纸色回到跟着页面底色走（深色页上是纸白）")
                }
            }
            .font(.caption)
        }
    }

    /// 网角收到 0…180°（ops 给的 -15、200 照样能用，滑杆和读数按同一个方向显示）。
    private static func screenAngle(_ degrees: Double) -> Double {
        let a = degrees.truncatingRemainder(dividingBy: 180)
        return a < 0 ? a + 180 : a
    }

    private func halftoneBinding(_ keyPath: WritableKeyPath<CollageHalftone, Double>) -> Binding<Double> {
        Binding(get: { store.project.style.halftone?[keyPath: keyPath] ?? 0 },
                set: { v in
                    var s = store.project.style
                    s.halftone?[keyPath: keyPath] = v
                    store.setStyle(s)
                })
    }

    private func swatch(_ look: CollageLook) -> some View {
        let active = store.project.style.look == look
        return Button {
            var s = store.project.style
            s.look = look
            store.setStyle(s, coalesce: false)
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

/// 照片上的字块：一张照片可以压好几块（刊头、左栏、右栏、底栏……），按顺序摆、后面的让着前面的。
/// 上面一排切换编辑哪一块、＋ 再加一块；下面是当前这一块的位置、深浅、边距、最宽。
struct CollageOverlayBox: View {
    @ObservedObject var store: CollageStore
    let path: [Int]
    let overlays: [CollageOverlay]

    /// 正在编辑的那一块（删掉之后下标可能越界：落到最后一块）。
    private var index: Int { max(0, min(store.overlayIndex, overlays.count - 1)) }

    var body: some View {
        GroupBox("照片上的字") {
            VStack(alignment: .leading, spacing: 8) {
                if overlays.isEmpty {
                    Text("选一个样式压在这张照片上：自动避开脸和身体，深字浅字跟着底下的画面换。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    presetGrid
                } else {
                    blockList
                    controls(overlays[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 这张照片上的字块：点一块切过去编辑（画布上点它的虚框也行）；＋ 再加一块，自动摆在已有字块之外、照样躲脸。
    private var blockList: some View {
        // 展开占位符的值一格算一次（几块字共用）。
        let vars = store.overlayVariables(at: path)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(Array(overlays.enumerated()), id: \.offset) { item in
                blockButton(item.element, item.offset, vars: vars)
            }
            Menu {
                ForEach(CollageOverlays.presets) { preset in
                    Button(preset.name) { store.addOverlay(preset.overlay, at: path) }
                }
            } label: {
                Label("加一块", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .fixedSize()
            .help("在这张照片上再加一个字块：自动摆在已有字块之外，也躲开脸")
        }
    }

    private func blockButton(_ overlay: CollageOverlay, _ i: Int, vars: [String: String]) -> some View {
        let active = i == index
        let fill: Color = active ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.18)
        let ink: Color = active ? .white : .primary
        let tip = i == 0 ? "第一块最先摆（刊头放这里）" : "第 \(i + 1) 块：摆在前面几块之外"
        return Button {
            store.overlayIndex = i
        } label: {
            Text(blockName(overlay, i, vars: vars))
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(fill))
                .foregroundStyle(ink)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    /// 字块按钮上的名字：序号 + 展开占位符之后的第一行字（和画出来的一样：SHIGUANG、MARCH ISSUE、03.21）；
    /// 太长的按钮自己截尾巴。展开是空的（值都没有）退回模板里的字：[[…||备选]] 只留前一半、去掉 [[ ]]、
    /// {key|默认} 只留 key —— 不再是「[[month.」「masthead」这种半截占位符。
    private func blockName(_ overlay: CollageOverlay, _ i: Int, vars: [String: String]) -> String {
        let expanded = CollageTypeset.expandedLines(overlay.text, vars: vars).first?.text ?? ""
        var name = expanded.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            var raw = overlay.text.lines.first?.text ?? ""
            if let alt = raw.range(of: "||") { raw = String(raw[..<alt.lowerBound]) }
            raw = raw.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            raw = raw.replacingOccurrences(of: "\\{([^}|]*)(\\|[^}]*)?\\}", with: "$1", options: .regularExpression)
            name = raw.trimmingCharacters(in: .whitespaces)
        }
        return "\(i + 1) " + (name.isEmpty ? "字块" : String(name.prefix(24)))
    }

    /// 滑杆连续拖动合成一步撤销；点按钮、选选项每次一步（两次点选挨得近也不能并成一步）。
    private func update(coalesce: Bool = false, _ body: @escaping (inout CollageOverlay) -> Void) {
        store.updateOverlay(at: path, index: index, coalesce: coalesce, body)
    }

    @ViewBuilder
    private func controls(_ overlay: CollageOverlay) -> some View {
        HStack(alignment: .top, spacing: 12) {
            anchorGrid(overlay)
            VStack(alignment: .leading, spacing: 6) {
                Button("自动位置") { update { $0.anchor = .auto } }
                    .disabled(overlay.anchor == .auto)
                    .help("按人脸、身体和画面空处重新挑位置（同一张照片上的别的字块也让开）")
                Text(overlay.anchor == .custom ? "手动拖过" : "位置：\(overlay.anchor.label)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("画布上可以直接拖字").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        sideAnchors(overlay)
        layerControls(overlay)
        Picker("字色", selection: Binding(get: { overlay.tone }, set: { v in update { $0.tone = v } })) {
            ForEach(CollageTone.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        CollageSlider(label: "衬底",
                      value: Binding(get: { overlay.shadow }, set: { v in update(coalesce: true) { $0.shadow = v } }),
                      range: 0...1, display: String(format: "%.2f", overlay.shadow))
            .help("浅字的柔和投影；字底下画面太花时再垫一层雾面（深字衬白、浅字衬黑，干净的天空上不垫）。拖到 0 都不加")
        CollageSlider(label: "边距",
                      value: Binding(get: { overlay.inset }, set: { v in update(coalesce: true) { $0.inset = v } }),
                      range: 0...0.2, display: percentText(overlay.inset))
            .help("离照片边多远；铺满宽度的刊头可以拖到 2%")
        CollageSlider(label: "最宽",
                      value: Binding(get: { overlay.maxWidth }, set: { v in update(coalesce: true) { $0.maxWidth = v } }),
                      range: 0.3...1, display: percentText(overlay.maxWidth))
            .help("字块最多占照片多宽，放不下整体缩小；「铺满宽度」的行按它放大（刊头 0.96 左右）")
        HStack {
            Menu("换样式") {
                ForEach(CollageOverlays.presets) { preset in
                    Button(preset.name) { store.setOverlay(preset.overlay, at: path, index: index) }
                }
            }
            .fixedSize()
            Spacer()
            Button(overlays.count > 1 ? "删掉这一块" : "去掉压字", role: .destructive) {
                store.setOverlay(nil, at: path, index: index)
            }
        }
        .font(.caption)
    }

    // MARK: 人物挡字

    /// 这块字的人物挡字决定（和渲染器、导出同一个；蒙版预热完 masksVersion 变了视图跟着刷）。
    private var currentBlock: CollageCover.Block? {
        guard let frame = store.geometry.frames.first(where: { $0.path == path }),
              let decided = store.coverResolution(for: frame), decided.blocks.indices.contains(index) else { return nil }
        return decided.blocks[index]
    }

    /// 人物挡字：开关、压字深度、最多挡多少、读数（「刊名被挡 18%」）和退让原因。
    @ViewBuilder
    private func layerControls(_ overlay: CollageOverlay) -> some View {
        Toggle("人物挡字（字压在人后面）", isOn: Binding(get: { overlay.layer == .behindSubject }, set: { on in
            store.setOverlayLayer(on ? .behindSubject : .front, at: path, index: index)
        }))
        .help("主体（人）叠在这块字前面，像杂志刊头那样被头挡住一点。挡得太多会自动挪取景、拉远、缩字，"
              + "实在不行放回人前（压着头就挪到不压脸的地方）。定在上方的刊头打开时，这一格的「自动」取景会换成「封面」，"
              + "关掉时换回自动")
        if overlay.layer == .behindSubject {
            // 压字深度只管封面取景定头顶的那块（定在上方的刊头）：别的景别、自动位置的字拖了也没反应，灰掉。
            let block = currentBlock
            let depthLive = currentCell?.framing == .cover && (block?.band ?? true)
            CollageSlider(label: "压字深度",
                          value: Binding(get: { overlay.depth }, set: { v in update(coalesce: true) { $0.depth = v } }),
                          range: 0...0.3, display: percentText(overlay.depth))
                .disabled(!depthLive)
                .opacity(depthLive ? 1 : 0.45)
                .help(depthLive ? "封面取景时头顶压进刊头多深（刊头字高的比例，默认 20%）：越大头越低、挡得越少"
                      : "只在「封面」取景、位置定在上方的刊头上起作用（景别换成「封面」、位置点「上」）")
            CollageSlider(label: "最多挡",
                          value: Binding(get: { overlay.maxOcclusion },
                                         set: { v in update(coalesce: true) { $0.maxOcclusion = v } }),
                          range: 0.05...0.33, display: percentText(overlay.maxOcclusion))
                .help("刊名的墨最多被挡掉多少（默认 25%，超过 33% 一律不行）；首字母、末字母另有 5% / 15% 的限，"
                      + "同一块里的小字行（期号日期）每行最多挡 15% —— 想让头压着刊名、小字不受限，就把小字另起一块")
            Toggle("装饰大字（只限总量）", isOn: Binding(get: { overlay.occlusionRule == .total }, set: { on in
                update { $0.occlusionRule = on ? .total : .masthead }
            }))
            .help("巨型数字、巨字开篇这种本来就让人挡住一截的大字：只管总共挡掉多少，不管首字母、末字母、"
                  + "过半的字母（刊名别开：首末字母被挡就认不出来了）")
            if let block { layerReadout(block) }
        }
    }

    /// 这一格（景别、裁没裁）：压字深度滑杆看它。
    private var currentCell: CollageCell? {
        store.geometry.frames.first(where: { $0.path == path })?.cell
    }

    private func layerReadout(_ block: CollageCover.Block) -> some View {
        let what = block.rule == .total ? "大字" : (block.band ? "刊名" : "这块字")
        // 主行以外被挡到的行（期号日期小字）单独列：总量里几乎看不出来。
        let minor: String = block.occlusion.map { o in
            o.perLine.enumerated().filter { $0.offset != o.mainLine && $0.element >= 0.01 }
                .map { " · 第 \($0.offset + 1) 行 \(CollageCover.percent($0.element))" }.joined()
        } ?? ""
        let measured = block.occlusion.map { "\(what)被挡 \(CollageCover.percent($0.total))" + minor }
            ?? "还没量（没有主体蒙版）"
        let state = block.layer == .behindSubject ? measured
            : measured + (block.moved ? " · 放到人前、挪开了头" : " · 放到人前了")
        return VStack(alignment: .leading, spacing: 2) {
            Text(state)
                .font(.caption)
                .foregroundStyle(block.layer == .behindSubject ? Color.secondary : Color.orange)
            if let reason = block.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 定一条边、沿着它找位置（封面字）：左栏、右栏、底栏。
    private func sideAnchors(_ overlay: CollageOverlay) -> some View {
        HStack(spacing: 4) {
            Text("沿边").font(.caption).foregroundStyle(.secondary)
            ForEach(CollageAnchor.sides, id: \.self) { anchor in
                sideButton(anchor, active: overlay.anchor == anchor)
            }
            Spacer(minLength: 0)
        }
    }

    /// 选中的那个填强调色（和九宫格里选中的格子一个画法：窗口不在前台时也看得出选的是哪个）。
    private func sideButton(_ anchor: CollageAnchor, active: Bool) -> some View {
        let fill: Color = active ? Color.accentColor : Color.gray.opacity(0.25)
        let ink: Color = active ? .white : .primary
        return Button {
            update { $0.anchor = anchor }
        } label: {
            Text(anchor.label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(fill))
                .foregroundStyle(ink)
        }
        .buttonStyle(.plain)
        .help(sideHelp(anchor))
    }

    private func sideHelp(_ anchor: CollageAnchor) -> String {
        switch anchor {
        case .leftColumn: return "贴着左边一栏（封面字），上下自己找不压脸、不压别的字块的位置"
        case .rightColumn: return "贴着右边一栏（封面字），上下自己找不压脸、不压别的字块的位置"
        default: return "贴着底边一条，往上找不压脸、不压别的字块的位置"
        }
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
                     ? "散落版：托盘里的照片拖进画布 = 放一张相纸。选中后拖动挪位置，拖上方圆点旋转、右下圆点缩放；[ ] 微调角度。先选中一张相纸再加胶带、回形针，会贴在它上沿并跟着它走。"
                     : "贴纸浮在版面上。先选中一个照片格再加胶带，会贴在那一格的上沿。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

// MARK: - 印样 / 底片条

/// 这一页印样的设置：规格、排法、每条几帧、竖片、记号、笔色、片边字、卷号、手写注记。都走 updateContactSheet（进撤销栈；
/// 打字、拖滑杆连成一步）。
struct CollageContactBox: View {
    @ObservedObject var store: CollageStore
    let sheet: CollageContactSheet
    /// 「逐帧」那一栏展开没有（默认收起：一卷 36 帧一长串）。离屏快照 --contact-frames 让它一开始就展开。
    @State private var framesOpen = false

    /// 「21 帧 · 按拍摄先后 …」；超过一页放得下的（frameLimit）说没上几张。底片条模板（choice = best）托盘比格子多时
    /// 每场挑一张，「按托盘重排」也照这样挑：说出来，不然看着像随便拿了几张。
    private var frameSummary: String {
        let left = max(0, sheet.frames.count - sheet.frameLimit)
        let shown = sheet.frames.count - left
        let order = sheet.choice == .best ? "托盘多的时候每场挑最好的一张、按拍摄先后排" : "按拍摄先后"
        return "\(shown) 帧" + (left > 0 ? "（放不下的 \(left) 张没上）" : "") + " · \(order) · 托盘里的照片拖进画布接在这一卷最后"
            + sidewaysNote(shown)
    }

    /// 社交底片条上躺着的帧（横着拍的放进竖着的条、竖着拍的放进横着的条）：真的片条就这样，可发出去像放错了 ——
    /// 说一声几帧、怎么换（挑帧时立着的本来就优先，托盘里没有才上躺着的）。印样（看片用）不提。
    private func sidewaysNote(_ shown: Int) -> String {
        guard sheet.layout == .strip else { return "" }
        let film = CollageContact.film(sheet.format)
        let photos = store.photoMap
        let lying = sheet.frames.prefix(shown).compactMap { photos[$0] }.filter {
            !CollageContact.standsUpright($0, film: film, sheet: sheet)
        }.count
        guard lying > 0 else { return "" }
        return " · \(lying) 帧在片条上是躺着的（真的片条就这样）：托盘里多放几张同方向拍的，挑帧时会先用立着的"
    }

    var body: some View {
        GroupBox("印样") {
            VStack(alignment: .leading, spacing: 8) {
                formatControls
                Divider()
                markControls
                Divider()
                edgeControls
                Text(frameSummary)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                frameList
                HStack {
                    Button("按托盘重排") { store.makeContactSheet() }
                        .help("托盘的照片重新按拍摄先后排一卷（设置不变）")
                    Button("改回网格") { store.leaveContactSheet() }
                        .help("这一卷的精选（没有就前几帧）排一版网格")
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var formatControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("规格", selection: binding(\.format)) {
                ForEach(CollageFilmFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("135 每帧 8 个齿孔；120（6×4.5 / 6×6 / 6×7）没有齿孔")
            Picker("排法", selection: layoutBinding) {
                ForEach(CollageContactLayout.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("印样 = 白相纸上一块黑场、白边手写卷号；底片条 = 一条条放在深色底上（社交图）。换排法时纸跟着换，下面可以再挑")
            paperControls
            if sheet.layout == .sheet, darkPaper {
                // 自己挑了深色的纸（或者跟着偏深的工程底色）：黑场压在深色上分不出来。
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("印样印在白相纸上：现在的纸偏深，黑场和纸分不出来")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("换白相纸") { store.useWhitePaper() }
                        .font(.caption)
                        .help("只换这一页印样的纸（工程的底色、别的页不动）；撤销可以换回来")
                }
            }
            HStack(spacing: 10) {
                Stepper(sheet.perStrip == 0 ? "每条 自动" : "每条 \(sheet.perStrip) 帧", value: binding(\.perStrip), in: 0...12)
                Stepper(sheet.strips == 0 ? "条数 自动" : "\(sheet.strips) 条", value: binding(\.strips), in: 0...12)
            }
            .font(.caption)
            Toggle("竖片立起来", isOn: binding(\.uprightPortraits))
                .help("关 = 和真的印样一样，竖拍转 90° 躺在条里；开 = 好认，但条里会是一张立着的竖片加两边黑边")
            Toggle("裁满画幅（按人脸取景）", isOn: binding(\.fillFrames))
                .help("关 = 比例不符加黑边（没曝光的片基），不裁掉照片；6×6 放 3:2 的照片时开了更像方画幅")
            Toggle("条错位、微转", isOn: binding(\.jitter))
                .help("每条随机转 0.3–0.8°、横向错开 1–2 mm，不排成完美的网格")
            CollageSlider(label: "倾斜", value: binding(\.tilt, coalesce: true), range: CollageContactSheet.tiltRange,
                          display: String(format: "%.0f°", sheet.tilt))
            CollageSlider(label: "留白", value: binding(\.margin, coalesce: true), range: CollageContactSheet.marginRange,
                          display: String(format: "%.0f%%", sheet.margin * 100))
            CollageSlider(label: "条缝", value: gapBinding, range: CollageContactSheet.stripGapRange,
                          display: String(format: "%.0f%%", sheet.effectiveStripGap * 100))
                .help("条与条之间的缝（片宽的比例）：印样默认 2%（挨着的一道细缝），底片条默认 18%（给投影留地方）")
        }
        .font(.caption)
    }

    /// 排法：换的时候纸也换成那种排法的纸（印样 = 白相纸，底片条 = 暖黑）、笔配新纸（白笔换到白相纸上换回红笔），
    /// 一步撤销；下面的「纸」可以再挑。
    private var layoutBinding: Binding<CollageContactLayout> {
        Binding(get: { store.page?.contactSheet?.layout ?? sheet.layout },
                set: { v in
                    store.updateContactSheet { s in CollageContact.switchLayout(&s, to: v) }
                })
    }

    /// 这一页的纸：几张常用的（白相纸、米色纸、暖黑）+「跟着底色」（工程的底色 / 取色底）。
    private var paperControls: some View {
        HStack(spacing: 6) {
            Text("纸").font(.caption)
            ForEach(CollageContact.papers.indices, id: \.self) { i in
                let entry = CollageContact.papers[i]
                let on = sheet.paper == entry.color
                Button { store.updateContactSheet { $0.paper = entry.color } } label: {
                    RoundedRectangle(cornerRadius: 3).fill(entry.color.swiftUIColor).frame(width: 22, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(on ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: on ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(entry.name)
            }
            Button("跟着底色") { store.updateContactSheet { $0.paper = nil } }
                .font(.caption)
                .disabled(sheet.paper == nil)
                .help("用工程的底色（样式页里的底色、取色底）")
        }
    }

    /// 这一页的纸（页面底色，和渲染同一个算法）偏深：亮度不到 0.75（米色、纸白都在 0.9 以上，不提示）。
    private var darkPaper: Bool {
        guard let page = store.page else { return false }
        let project = CollageLooks.project(store.project, page: page)
        let paper = CollageRender.backgroundColor(project: project, pagePhotoIDs: page.photoIDs, photos: store.photoMap)
        return paper.luminance < 0.75
    }

    /// 条缝：没设过 = 跟排法的默认值（印样 2%、底片条 18%）；拖一下就记成自己的值。
    private var gapBinding: Binding<Double> {
        Binding(get: { store.page?.contactSheet?.effectiveStripGap ?? sheet.effectiveStripGap },
                set: { v in store.updateContactSheet(coalesce: true) { $0.stripGap = v } })
    }

    /// 逐帧：手动定记号（自动 / 圈 / 叉 / 点 / 裁切线 / 不画）、往前往后挪、移出这一卷。以前只有 ops 的 contactmark: /
    /// contactframes: 改得了，界面里只能把托盘的照片拖进来接在最后。帧号 = 片条上印的那个（第几帧）；放不下的灰着。
    private var frameList: some View {
        DisclosureGroup(isExpanded: $framesOpen) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(sheet.frames.enumerated()), id: \.offset) { item in
                    frameRow(item.element, item.offset)
                }
            }
            .padding(.top, 2)
        } label: {
            Text("逐帧：记号、先后、移出").font(.caption)
        }
        .help("一帧一行：记号（自动 = 每场最好的精选画圈、废片打叉）、往前 / 往后挪、移出这一卷（照片还在托盘里）")
        .onAppear { if SnapshotPreview.contactFramesOpen { framesOpen = true } }
    }

    private func frameRow(_ id: String, _ index: Int) -> some View {
        let override = sheet.markOverrides[id]
        let onSheet = index < sheet.frameLimit
        let last = sheet.frames.count - 1
        return HStack(spacing: 4) {
            Text("\(index + 1)").monospacedDigit()
                .frame(width: 20, alignment: .trailing)
                .foregroundStyle(onSheet ? .secondary : .tertiary)
            Text(id).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(onSheet ? .primary : .tertiary)
                .help(onSheet ? id : "\(id)：这一页放不下，没上")
            Spacer(minLength: 2)
            Menu(markName(override)) {
                Button("自动") { setMark(id, nil) }
                Divider()
                ForEach(CollagePencilMark.allCases, id: \.self) { mark in
                    Button(mark.label) { setMark(id, mark.rawValue) }
                }
                Button("不画") { setMark(id, "none") }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .help("这一帧的记号：自动 = 按精选、废片；手动定的不占「一页最多几个圈」的名额")
            Button { moveFrame(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("往前挪一帧")
            Button { moveFrame(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index >= last)
                .help("往后挪一帧")
            Button { removeFrame(id) } label: { Image(systemName: "xmark") }
                .help("移出这一卷（照片还在托盘里，拖回画布接在最后）")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    /// 手动记号的名字：nil = 自动，none = 不画（同 ops contactmark: 的 auto / none）。
    private func markName(_ raw: String?) -> String {
        guard let raw else { return "自动" }
        return CollagePencilMark(rawValue: raw)?.label ?? "不画"
    }

    private func setMark(_ id: String, _ raw: String?) {
        store.updateContactSheet { $0.markOverrides[id] = raw }
    }

    private func moveFrame(_ index: Int, by step: Int) {
        store.updateContactSheet { s in
            let target = index + step
            guard s.frames.indices.contains(index), s.frames.indices.contains(target) else { return }
            s.frames.swapAt(index, target)
        }
    }

    /// 移出：这一帧的手动记号一起清掉（再拖回来从自动开始）。
    private func removeFrame(_ id: String) {
        store.updateContactSheet { s in
            s.frames.removeAll { $0 == id }
            s.markOverrides[id] = nil
        }
    }

    private var markControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("精选画圈（每场最好的一张）", isOn: binding(\.marks))
                .help("手动定的精选优先；同一场只圈一张，一页最多圈几个在下面调")
            Stepper(sheet.maxCircles == 0 ? "一页最多 不限" : "一页最多 \(sheet.maxCircles) 个圈",
                    value: binding(\.maxCircles), in: CollageContactSheet.maxCirclesRange)
                .disabled(!sheet.marks)
                .help("超了按手动的、分数高的先圈；0 = 不限。印样上通常只圈几张（帧帧都圈一眼假）")
            Toggle("废片打叉", isOn: binding(\.crossRejects))
            HStack(spacing: 6) {
                Text("笔色").font(.caption)
                ForEach(CollagePencilMark.palette.indices, id: \.self) { i in
                    let entry = CollagePencilMark.palette[i]
                    let on = sheet.markColor == entry.color
                    Button { store.updateContactSheet { $0.markColor = entry.color } } label: {
                        Circle().fill(entry.color.swiftUIColor).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(on ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: on ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("油性笔 · \(entry.name)（圈、叉、手写注记同一支笔）")
                }
            }
        }
        .font(.caption)
    }

    private var edgeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("印片边字、帧号", isOn: binding(\.edgePrint))
            HStack(spacing: 6) {
                TextField("片边字", text: binding(\.edgeText, coalesce: true))
                    .help("只放通用字样或你自己的工作室名、卷名：不要印胶片品牌")
                TextField("ISO", text: binding(\.iso, coalesce: true))
                    .frame(width: 56)
            }
            HStack(spacing: 6) {
                Text("卷号").font(.caption)
                TextField("页码", text: rollBinding)
                    .frame(width: 56)
                    .help("空 = 用页码")
                Spacer()
            }
            TextField("白边手写（{roll} {date} {first} {last}；空 = 不写）", text: binding(\.note, coalesce: true))
        }
        .font(.caption)
    }

    private var rollBinding: Binding<String> {
        Binding(get: { (store.page?.contactSheet?.roll).map(String.init) ?? "" },
                set: { v in
                    let n = Int(v.trimmingCharacters(in: .whitespaces))
                    store.updateContactSheet(coalesce: true) { $0.roll = n.map { min(999, max(1, $0)) } }
                })
    }

    private func binding<T: Equatable>(_ key: WritableKeyPath<CollageContactSheet, T>,
                                       coalesce: Bool = false) -> Binding<T> {
        Binding(get: { store.page?.contactSheet?[keyPath: key] ?? sheet[keyPath: key] },
                set: { v in store.updateContactSheet(coalesce: coalesce) { $0[keyPath: key] = v } })
    }
}

// MARK: - 选中的图层

struct CollageItemBox: View {
    @ObservedObject var store: CollageStore
    let item: CollageItem

    /// 滑杆、输入框连续改合成一步撤销；点选项每次一步。
    private func update(coalesce: Bool = false, _ body: @escaping (inout CollageItem) -> Void) {
        store.updateItem(item.id, coalesce: coalesce, body)
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
                    CollageSlider(label: "投影",
                              value: Binding(get: { item.shadow }, set: { v in update(coalesce: true) { $0.shadow = v } }),
                              range: 0...1, display: String(format: "%.2f", item.shadow))
                    Toggle("抠图贴纸（只留人）", isOn: Binding(get: { item.cutout != nil }, set: { on in
                        update { $0.cutout = on ? CollageCutout(stroke: 0.006, shadow: 0.5) : nil }
                    }))
                    .help("用主体蒙版只画人，带一圈白边和投影，像剪下来的贴纸；认不出主体时照常画整张。"
                          + CollageMasks.cutoutCaveat)
                    if item.cutout != nil {
                        Text(CollageMasks.cutoutCaveat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { item.width }, set: { w in
            let ratio = item.height / max(1e-6, item.width)
            update(coalesce: true) { it in
                it.width = w
                it.height = w * ratio
            }
        })
    }

    private var rotationBinding: Binding<Double> {
        Binding(get: { max(-45, min(45, item.rotation)) }, set: { v in update(coalesce: true) { $0.rotation = v.rounded() } })
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
                ForEach(CollageFraming.itemCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if item.frame == .polaroid {
                TextField("相纸下沿的字（{date} {title}…）", text: Binding(get: { item.caption },
                                                                    set: { v in update(coalesce: true) { $0.caption = v } }))
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
                                                 set: { c in update(coalesce: true) { $0.color = CollageColor(c) } }),
                        supportsOpacity: false)
                .font(.caption)
            if item.sticker == .label || item.sticker == .postmark || item.sticker == .barcode {
                TextField(item.sticker == .barcode ? "条码编的字（{date}；空 = 随机数字）" : "上面的字（默认 {date}）",
                          text: Binding(get: { item.label }, set: { v in update(coalesce: true) { $0.label = v } }))
            }
            if item.sticker == .greasePencil {
                Picker("记号", selection: Binding(get: { item.mark }, set: { v in
                    update { it in it = CollageItems.withMark(it, v) }
                })) {
                    ForEach(CollagePencilMark.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 6) {
                    ForEach(CollagePencilMark.palette.indices, id: \.self) { i in
                        let entry = CollagePencilMark.palette[i]
                        Button { update { $0.color = entry.color } } label: {
                            Circle().fill(entry.color.swiftUIColor).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(item.color == entry.color ? Color.accentColor
                                                         : Color.gray.opacity(0.5), lineWidth: item.color == entry.color ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help("油性笔 · \(entry.name)")
                    }
                }
            }
        } else {
            Text("内容和字体在「文字」里改").font(.caption).foregroundStyle(.secondary)
        }
    }
}
