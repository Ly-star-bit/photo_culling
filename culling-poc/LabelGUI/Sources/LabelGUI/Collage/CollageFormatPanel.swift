import SwiftUI
import AppKit

// MARK: - 检视器「格式」：选中什么显示什么（照 Keynote 的「格式」、Canva 选中后的工具条）
//
// 选中照片格：这一格（锁定 / 删除 / 移跨页 / 这张不加水印）→ 取景 → 形状与抠图 → 色调（这一格）→ 照片上的字。
// 选中文字格：这一格 → 文字编辑器。选中手写字：图层 → 文字编辑器。选中贴纸、相纸：图层。
// 什么都没选：这一页（版式操作、这一页的色调、存成模板）、印样。
// 所有改动都走 store 的方法（进撤销栈）。

private func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

struct CollageFormatPanel: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        let _ = CollagePerf.body("格式面板")
        if let item = store.selectedItemValue {
            itemBoxes(item)
        } else if let path = store.selection, let cell = store.selectedCell {
            cellBoxes(path: path, cell: cell)
        } else {
            CollagePageBox(store: store)
            if let sheet = store.page?.contactSheet {
                // 印样：没有格子、没有缝，版式由规格和帧定。
                CollageContactBox(store: store, sheet: sheet)
                    .collageSpot(.contact, store.nav)
            }
        }
    }

    // 选中的图层

    @ViewBuilder
    private func itemBoxes(_ item: CollageItem) -> some View {
        // 换了图层就换一个面板实例：输入框迟到的提交只会写回它自己那张（按 id 认）。
        CollageItemBox(store: store, item: item)
            .id(item.id)
        if item.kind == .photo, let id = item.photoID {
            CollageSkipMarkToggle(store: store, photoID: id)
        }
        if item.kind == .text, let text = item.text {
            VStack(alignment: .leading, spacing: 12) {
                CollageTextEditor(store: store, text: text, target: .item(item.id))
                    .id(CollageTextTarget.item(item.id))
            }
            .collageSpot(.textEditor, store.nav)
        }
    }

    // 选中的格子

    @ViewBuilder
    private func cellBoxes(path: [Int], cell: CollageCell) -> some View {
        CollageCellBox(store: store, cell: cell)
        // 换一张（S6）：同连拍、同场、画面相似的一排候选（编辑封面时没有：封面那块换照片从托盘拖）。
        if cell.kind == .photo, let id = cell.photoID,
           CollageAlbumRules.allows(.replacePhoto, editingCover: store.editingCover) {
            CollageReplaceBox(store: store, path: path, photoID: id)
                .id(id)
        }
        if cell.kind == .photo, cell.photoID != nil {
            CollagePhotoCellBoxes(store: store, cell: cell, path: path)
        }
        if cell.kind == .text, let text = cell.text {
            // 编辑器绑定到这一格的路径；换了格子就换一个编辑器实例（旧的文字框迟到的提交只会写回它自己那一格）。
            VStack(alignment: .leading, spacing: 12) {
                CollageTextEditor(store: store, text: text, target: .cell(path, store.page?.id))
                    .id(CollageTextTarget.cell(path, store.page?.id))
            }
            .collageSpot(.textEditor, store.nav)
        } else if cell.kind == .photo {
            // 空照片格也能压字（模板的占位格）。
            VStack(alignment: .leading, spacing: 12) {
                overlayBoxes(path: path, cell: cell)
            }
            .collageSpot(.overlays, store.nav)
        }
    }

    @ViewBuilder
    private func overlayBoxes(path: [Int], cell: CollageCell) -> some View {
        CollageOverlayBox(store: store, path: path, overlays: cell.overlays)
        let list = cell.overlays
        if !list.isEmpty {
            // 编辑器绑定到「这一格的第几块」：切了字块就换一个编辑器实例（迟到的提交只写回它自己那一块）。
            let i = max(0, min(store.overlayIndex, list.count - 1))
            let overlay = list[i]
            CollageTextEditor(store: store, text: overlay.text,
                              target: .overlay(path, cell.photoID, store.page?.id, i),
                              alignFollowsAnchor: overlay.anchor != .custom && overlay.anchor != .bottomBand
                                && !overlay.text.isTall,
                              isOverlay: true)
                .id(CollageTextTarget.overlay(path, cell.photoID, store.page?.id, i))
        }
    }
}

// MARK: - 这一格：是什么、锁定 / 删除 / 移跨页、这张不加水印

struct CollageCellBox: View {
    @ObservedObject var store: CollageStore
    let cell: CollageCell
    /// 「移到第…个跨页 › 填跨页号…」的小框。
    @State private var askNumber = false

    var body: some View {
        GroupBox("选中的格子") {
            VStack(alignment: .leading, spacing: 8) {
                Text(cellTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if cell.kind == .photo, cell.photoID == nil {
                    Text("空格子：从托盘拖一张照片进来").font(.caption).foregroundStyle(.secondary)
                } else if cell.kind == .empty {
                    Text("留白格：从托盘拖一张照片进来就变成照片格").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                // 编辑封面时没有：封面那块的照片不属于哪个跨页（store 也拦）。
                if store.isAlbum, cell.photoID != nil,
                   CollageAlbumRules.allows(.moveToSpread, editingCover: store.editingCover) {
                    moveRow
                }
                if cell.kind == .photo, let id = cell.photoID {
                    CollageSkipMarkToggle(store: store, photoID: id, boxed: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .collageSpot(.format, store.nav)
        .collageMoveNumberAlert(store: store, isPresented: $askNumber, path: nil)
    }

    /// 移到上一 / 下一跨页、移到第…个（每 10 个一组；画布上右键这一格是同一份菜单）。
    private var moveRow: some View {
        HStack(spacing: 6) {
            Button { store.moveSelectedPhoto(toPage: store.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(store.pageIndex == 0)
                .help("移到上一个跨页")
            Button { store.moveSelectedPhoto(toPage: store.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(store.pageIndex >= store.project.pages.count - 1)
                .help("移到下一个跨页")
            if let path = store.selection {
                CollageMoveMenu(store: store, path: path, askNumber: $askNumber)
            }
        }
        .font(.caption)
    }

    private var cellTitle: String {
        switch cell.kind {
        case .photo: return cell.photoID.map { "照片 \(CollageMarkLayerBox.photoName($0, photos: store.project.photos))" } ?? "空照片格"
        case .text: return "文字格"
        case .empty: return "留白格"
        }
    }
}

/// 「这张不加水印」：工程开着「每张照片」水印时才有（和「文档 › 水印 › 每张照片」里的「这张不加」是同一个开关，
/// 按照片记：互换位置、换一批都跟着这张走）。
struct CollageSkipMarkToggle: View {
    @ObservedObject var store: CollageStore
    let photoID: String
    /// 单独一块（选中相纸时）还是放在「选中的格子」里面。
    var boxed = true

    var body: some View {
        if store.project.watermark?.layer(.photos) != nil {
            if boxed {
                GroupBox { toggle.frame(maxWidth: .infinity, alignment: .leading).padding(4) }
            } else {
                toggle
            }
        }
    }

    private var toggle: some View {
        let name = CollageMarkLayerBox.photoName(photoID, photos: store.project.photos)
        return Toggle("这张不加水印", isOn: Binding(
            get: { store.project.watermark?.skipPhotoIDs.contains(photoID) ?? false },
            set: { on in
                store.updateWatermark { wm in
                    var ids = wm.skipPhotoIDs
                    if on { ids.insert(photoID) } else { ids.remove(photoID) }
                    wm.skipPhotoIDs = ids
                }
            }))
        .help("\(name)：「每张照片」那层水印跳过这一张（按照片记，互换位置、换一批都跟着它走）")
    }
}

// MARK: - 照片格：取景、形状与抠图、色调

struct CollagePhotoCellBoxes: View {
    @ObservedObject var store: CollageStore
    let cell: CollageCell
    let path: [Int]

    var body: some View {
        framingBox
        shapeBox
        lookBox
    }

    // 取景

    private var framingBox: some View {
        GroupBox("取景") {
            VStack(alignment: .leading, spacing: 8) {
                // 标签自己占一行宽（fixedSize）：五段（多了「封面」）在 300pt 宽的检视器里会把「景别」挤成竖着两行。
                HStack(spacing: 8) {
                    Text("景别").fixedSize()
                    Picker("景别", selection: Binding(get: { cell.framing }, set: { store.setFraming($0) })) {
                        ForEach(CollageFraming.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .help("按人脸一键取景：全身 = 尽量大；半身 = 腰以上；特写 = 头肩；封面 = 头顶压进刊头底部（刊头设成人物挡字）。"
                      + "自动 = 小格收近景")
                HStack {
                    if store.cropEditing {
                        Button("完成裁切") { store.exitCropEdit() }
                            .keyboardShortcut(.return, modifiers: [])
                    } else {
                        Button("调整裁切…") { store.enterCropEdit(path) }
                            .help("也可以双击格子：拖动平移、捏合缩放")
                    }
                    Button("还原自动") { store.resetCrop() }
                        .disabled(cell.crop == nil)
                }
                if store.cropEditing { zoomSlider }
                Toggle("完整显示，不裁", isOn: Binding(get: { cell.contain }, set: { store.setContain($0) }))
                    .help("照片按原比例整张放进格子，四周留底色")
                if cell.contain {
                    Toggle("四周用本图模糊填", isOn: Binding(get: { cell.containBlur }, set: { store.setContainBlur($0) }))
                        .help("不留底色：这张照片自己大幅模糊铺满整格，清楚的那张浮在正中（横格放竖图常用）")
                }
                warnings
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if selectedWindow?.hitsBystander == true {
            Label("取景里有路人：双击格子拖一拖，或者换「半身」「特写」", systemImage: "person.2.fill")
                .font(.caption2).foregroundStyle(AppPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if store.project.canvas.isPrint, let up = selectedUpscale, up > CollageStore.upscaleLimit {
            Label("这张要放大到 \(Int((up * 100).rounded()))% 才铺得满，超过 120% 印出来会软：少裁一点、换「完整显示」，或者给它小一点的格子",
                  systemImage: "plus.magnifyingglass")
                .font(.caption2).foregroundStyle(AppPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var frame: CollageLayout.Frame? { store.geometry.frames.first(where: { $0.path == path }) }

    /// 这一格印出来要放大多少。
    private var selectedUpscale: Double? { frame.flatMap { store.upscale(for: $0) } }

    /// 这一格现在的取景（看有没有路人）。
    private var selectedWindow: CollageCrop.Window? { frame.flatMap { store.window(for: $0) } }

    private var zoomSlider: some View {
        let base = frame.flatMap { store.cropBaseline(for: $0) }
        let path = self.path
        let binding = Binding<Double>(
            get: { base?.zoom ?? 1 },
            set: { z in
                guard let base else { return }
                store.setCrop(CollageCropOverride(cx: base.cx, cy: base.cy, zoom: z), at: path)
            })
        return CollageSlider(label: "缩放", value: binding, range: 1...6,
                             display: String(format: "%.1f×", base?.zoom ?? 1))
    }

    // 形状与抠图

    private var shapeBox: some View {
        GroupBox("形状与抠图") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("形状", selection: Binding(get: { cell.shape }, set: { store.setShape($0) })) {
                    Text("跟随样式").tag(CollageShape?.none)
                    ForEach(CollageShape.allCases, id: \.self) { Text($0.label).tag(CollageShape?.some($0)) }
                }
                .help("只给这一格换形状；「跟随样式」= 用「样式 › 留白与形状」里整组的形状")
                cutoutControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// 抠图：只画主体（主体蒙版切出来），背景透出页面；可选白色贴纸边、投影。认不出主体时照常画整张。
    @ViewBuilder
    private var cutoutControls: some View {
        let path = self.path
        Toggle("抠图（只留人，背景透出页面）", isOn: Binding(get: { cell.cutout != nil }, set: { on in
            store.setCutout(on ? CollageCutout() : nil, at: path)
        }))
        .help("用主体蒙版只画人（或主体），格子的其余地方露出页面底色；可以压在大字上（字设成「人物挡字」）。"
              + CollageMasks.cutoutCaveat)
        if let cutout = cell.cutout {
            // 这一张不抠（认不出主体、贴不到成品底边）：白边、投影没有东西可画，灰掉（和压字深度一样）。
            let decided = frame.flatMap { store.coverResolution(for: $0) }
            let refused = decided.map { $0.mask == nil || $0.cutoutReason != nil } ?? false
            Text(CollageMasks.cutoutCaveat)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("人要贴着成品底边", isOn: Binding(get: { cutout.toEdge }, set: { v in
                var c = cutout
                c.toEdge = v
                store.setCutout(c, at: path)
            }))
            .font(.caption)
            .help("开着：取景底边那一条要是人（身子、腿），贴不上就不抠、整张照片照放（巨型数字的做法）；关掉 = 照样抠")
            CollageSlider(label: "白边",
                          value: Binding(get: { cutout.stroke }, set: { v in
                              var c = cutout
                              c.stroke = v
                              store.setCutout(c, at: path, coalesce: true)
                          }),
                          range: 0...0.02, display: String(format: "%.1f%%", cutout.stroke * 100))
                .help("贴纸那样的一圈白边（相对画布短边）")
                .disabled(refused)
                .opacity(refused ? 0.45 : 1)
            CollageSlider(label: "投影",
                          value: Binding(get: { cutout.shadow }, set: { v in
                              var c = cutout
                              c.shadow = v
                              store.setCutout(c, at: path, coalesce: true)
                          }),
                          range: 0...1, display: String(format: "%.2f", cutout.shadow))
                .disabled(refused)
                .opacity(refused ? 0.45 : 1)
            if let decided {
                if decided.mask == nil {
                    Text("这张照片认不出主体，照常画整张").font(.caption2).foregroundStyle(AppPalette.warning)
                } else if let why = decided.cutoutReason {
                    Text(why).font(.caption2).foregroundStyle(AppPalette.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // 色调（这一格）

    private var lookBox: some View {
        GroupBox("色调（这一格）") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("色调", selection: Binding(get: { cell.look?.look }, set: { look in
                    store.setCellLook(look.map { CollageLookSetting(look: $0, strength: store.project.style.lookStrength) })
                })) {
                    Text("跟着页面").tag(CollageLook?.none)
                    Divider()
                    ForEach(CollageLook.allCases, id: \.self) { Text($0.label).tag(CollageLook?.some($0)) }
                }
                .help("只给这一格换色调（彩色里放一张黑白）；字的深浅、水印的自动深浅跟着它")
                CollageDarkroomButton(store: store, scope: .cell, title: "在暗房里挑…")
                    .help("进暗房只改这一格：大样张悬停就在大预览里看，拖竖线比原图")
                CollageJumpText(store: store, lead: "整组的色调在", spot: .looks, tail: "，这一页的点画布空白处")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .collageSpot(.cellLook, store.nav)
    }
}

/// 进暗房（套用到 = scope）。顶栏的「暗房」、样式页的「进暗房…」是整组；这里的是这一格 / 这一页。
/// 暗房自己的「套用到」还能再换；选中没了（换页）它自己退回上一级。
struct CollageDarkroomButton: View {
    let store: CollageStore
    let scope: CollageDarkroom.Scope
    let title: String
    var prominent = false

    var body: some View {
        Button {
            store.openDarkroom()
            store.darkroom?.scope = scope
        } label: {
            Label(title, systemImage: "film")
                .frame(maxWidth: prominent ? .infinity : nil)
        }
        .controlSize(prominent ? .large : .regular)
        .buttonStyle(.bordered)
        .tint(CollageDarkroomButton.amber)
        // 编辑封面时不进暗房：暗房按「当前跨页」套色调，会改到封面底下那个跨页上。
        .disabled(store.page == nil || !CollageAlbumRules.allows(.darkroom, editingCover: store.editingCover))
    }

    /// 暗房的琥珀色（安全灯）：顶栏按钮、样式页的大按钮同一个颜色。
    static var amber: Color { AppPalette.accent }

    /// 整组进暗房的悬停（顶栏「暗房」、样式页「进暗房…」同一句；以前两处各说各的）。
    static let projectHelp = "整页的看片台：大样张分胶片 / 滤镜两页，悬停就在大预览里看，拖竖线比原图；强度试条、颗粒、晕光、1:1 细节都在一处。"
        + "从这里进改整组，进去以后顶上「套用到」能换成这一页（相册）、这一格；只想调一格，也可以选中它在「格式 › 色调」里进"
}

// MARK: - 这一页（什么都没选）

struct CollagePageBox: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        if store.editingCover {
            // 编辑封面：画布上是整张封面，没有「这个跨页」的那些（色调、存模板、镜像、锁都是跨页的事）。
            CollageCoverEditBox(store: store)
        } else if store.page == nil {
            emptyBox
        } else {
            GroupBox(store.isAlbum ? "这个跨页" : "这一页") {
                VStack(alignment: .leading, spacing: 10) {
                    layoutRows
                    // 相册：镜像、左页 / 右页换版式、锁住这个跨页（相册 A + B · U4）。
                    if store.isAlbum {
                        CollageSpreadActions(store: store)
                    }
                    Divider()
                    lookRows
                    Divider()
                    templateRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .collageSpot(.page, store.nav)
        }
    }

    private var emptyBox: some View {
        GroupBox("这一页") {
            VStack(alignment: .leading, spacing: 8) {
                Text("画布上还没有版式。").font(.caption).foregroundStyle(.secondary)
                CollageJumpText(store: store, lead: "到左栏", spot: .templates, tail: "里套一个，")
                Text(store.isAlbum ? "或者点顶栏的「自动编排」把托盘编成跨页。" : "或者点顶栏的「自动排版」。")
                    .collageHint()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .collageSpot(.page, store.nav)
    }

    // 版式操作

    @ViewBuilder
    private var layoutRows: some View {
        if store.isContactSheet {
            Text("这一页是印样：规格、排法、记号在下面「印样」里；改回网格也在那里。")
                .collageHint()
                .fixedSize(horizontal: false, vertical: true)
        } else if store.isFreeform {
            Text("散落版：托盘里的照片拖进画布 = 放一张照片。选中后拖动挪位置，拖上方圆点旋转、右下圆点缩放；[ ] 微调角度。")
                .collageHint()
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                Button("贴合原比例") { store.refit() }
                    .disabled(store.root == nil)
                    .help("结构不变，按照片原比例重算每条缝的位置（手动拖过的缝会被重算）")
                if !store.alternatives.isEmpty {
                    Text(store.alternativeIndex < 0 ? "备选 \(store.alternatives.count) 个"
                         : "第 \(store.alternativeIndex + 1)/\(store.alternatives.count) 个备选")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("画布上：拖缝调大小 · ⌥点缝横竖翻转 · 拖格子到另一格中间互换、到边上劈开插入 · 双击调裁切")
                .collageHint()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 这一页的色调

    private var lookRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("色调").font(.caption).frame(width: 56, alignment: .leading)
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
                .help("只给这一页换色调（整章黑白、一期杂志里的一页黑白）；格子还能选中以后单独设")
                Spacer(minLength: 0)
            }
            CollageDarkroomButton(store: store, scope: .page, title: "在暗房里挑…")
                .help("进暗房只改这一页：大样张悬停就在大预览里看，拖竖线比原图")
            CollageJumpText(store: store, lead: "整组的色调在", spot: .looks)
        }
        .collageSpot(.pageLook, store.nav)
    }

    // 存成模板

    private var templateRow: some View {
        HStack {
            Button("存成模板…") { store.go(.saveTemplate) }
                .disabled(store.root == nil)
                .help("把这一页的版式存进左栏「模板 › 我的模板」：起个名字，以后一点就套")
            Spacer(minLength: 0)
        }
    }
}
