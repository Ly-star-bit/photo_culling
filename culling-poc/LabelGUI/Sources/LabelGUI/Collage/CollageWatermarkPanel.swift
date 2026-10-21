import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 检视器「水印」页
//
// 拼图里的水印是工程自带的一份快照：改这里不动水印页，改水印页（包括它的预设）也不会悄悄改掉这里；
// 要同步就点「用水印页的设置」。水印在拼图里实时画（每张照片画在裁切后看得见的那块里），预览 = 导出。

struct CollageWatermarkPanel: View {
    @ObservedObject var store: CollageStore
    @ObservedObject var watermarkStore: WatermarkStore

    var body: some View {
        CollageSignatureBox(store: store, watermarkStore: watermarkStore)
        CollageMarkLayerBox(store: store, kind: .photos)
        CollageMarkLayerBox(store: store, kind: .page)
        CollageWatermarkAdoptBox(store: store, watermarkStore: watermarkStore)
        Text("相框和画布比例只在水印页单张导出时生效；拼图里要白边请用 样式 › 边框。水印不压中缝、切线和安全区，不躲进贴纸、相纸底下，每张照片的水印让着整页的：格子太小、签名或字放不下、怎么翻都躲不开时，那一处就不画。")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func percentText(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

// MARK: - 签名

/// 签名图（两层共用）：拷一份进拼图资料，原文件挪走也不影响已存的拼图。
struct CollageSignatureBox: View {
    @ObservedObject var store: CollageStore
    @ObservedObject var watermarkStore: WatermarkStore

    private var signature: CollageSignature? { store.project.watermark?.signature }

    var body: some View {
        GroupBox("签名") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    thumbnail
                    Text(signature?.sourceName ?? "还没有签名图（只加文字也行）")
                        .font(.caption)
                        .foregroundStyle(signature == nil ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                if lost {
                    Text(CollageWatermarks.signatureLostPanelWarning)
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// 签名文件哪儿都找不到（存的路径没了，资料目录里也没有那份副本）：预览、导出里都不会有签名。
    private var lost: Bool { Self.lost(signature) }

    static func lost(_ signature: CollageSignature?) -> Bool {
        signature.map { CollageWatermarks.signatureFile($0) == nil } ?? false
    }

    /// 签名多半是白字透明底：垫一块中灰，白的黑的都看得见。路径和渲染找的是同一个文件（存的路径没了就用
    /// 资料目录里的副本）。
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.5))
            if let signature, let file = CollageWatermarks.signatureFile(signature) {
                ThumbnailView(path: file, maxPixel: 256, fit: true)
                    .padding(4)
            } else if signature != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Image(systemName: "signature").foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 44)
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("选择签名…") { pickSignature() }
                .help("选一张带透明通道的 PNG")
            Button("用水印页的签名") { useWatermarkPageSignature() }
                .disabled(!watermarkStore.hasSignature)
                .help(watermarkStore.signatureURL?.lastPathComponent ?? "水印页还没选签名图")
            Spacer(minLength: 0)
            if signature != nil {
                Button {
                    setSignature(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("去掉签名图（只留文字）")
            }
        }
        .font(.caption)
    }

    /// 换签名（一步撤销）。工程里原来没有签名：开着的层顺手打开签名（之前没签名可画，开关只是摆设）；
    /// 换一张就不动各层的开关。
    private func setSignature(_ sig: CollageSignature?) {
        store.updateWatermark { wm in
            if wm.signature == nil, sig != nil {
                for kind in CollageMarkLayerKind.allCases {
                    guard var layer = wm.layer(kind) else { continue }
                    layer.signatureOn = true
                    wm.setLayer(kind, layer)
                }
            }
            wm.signature = sig
        }
    }

    private func pickSignature() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.prompt = "用这张签名"
        guard panel.runModal() == .OK, let url = panel.url,
              let sig = store.importSignature(from: url) else { return }
        setSignature(sig)
    }

    private func useWatermarkPageSignature() {
        guard let url = watermarkStore.signatureURL, let sig = store.importSignature(from: url) else { return }
        setSignature(sig)
    }
}

// MARK: - 一层（每张照片 / 整页）

/// 开关 + 签名一组（位置、边距、大小、不透明度、平铺）+ 文字一组（一行字、字的位置、字号）+ 深浅。
/// 签名那几样只管签名：签名关着、工程里没签名图时整组不显示，只剩文字。
/// 滑杆、输入框连续改合成一步撤销；开关、点位置每次一步。
struct CollageMarkLayerBox: View {
    @ObservedObject var store: CollageStore
    let kind: CollageMarkLayerKind

    private var watermark: CollageWatermark? { store.project.watermark }
    private var layer: CollageMarkLayer? { watermark?.layer(kind) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(kind.label, isOn: enabledBinding).bold()
                    .help(kind == .photos ? "每张照片各一个，画在裁切后看得见的那块里（换版式、换裁切都跟着走）"
                                          : "整张拼图一个（相册按半页、九宫格 / 轮播按片）")
                if let layer {
                    controls(layer)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private func controls(_ layer: CollageMarkLayer) -> some View {
        signatureRow(layer)
        if signatureDrawn(layer) {
            signatureControls(layer)
        }
        textRows(layer)
        contrastRows(layer)
        if kind == .photos, let id = selectedPhotoID {
            skipToggle(id)
        }
        if kind == .page {
            pageRows(layer)
        }
        if let name = layer.presetName {
            Text("来自水印页预设「\(name)」").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 签名真会画出来：开着，工程里也有签名图（签名那组控件只在这时显示）。
    static func signatureDrawn(_ layer: CollageMarkLayer, in watermark: CollageWatermark?) -> Bool {
        layer.signatureOn && watermark?.signature != nil
    }

    private func signatureDrawn(_ layer: CollageMarkLayer) -> Bool { Self.signatureDrawn(layer, in: watermark) }

    /// 没签名图时「签名」不显示成勾着（勾着也画不出东西）；选了签名图，开着的层自动打开签名（setSignature）。
    @ViewBuilder
    private func signatureRow(_ layer: CollageMarkLayer) -> some View {
        let hasSignature = watermark?.signature != nil
        Toggle("签名", isOn: Binding(get: { signatureDrawn(layer) }, set: { on in update { $0.signatureOn = on } }))
            .disabled(!hasSignature)
            .help(hasSignature ? "关掉只画文字（签名的位置、大小还记着）" : "先在上面选一张签名图")
        if !layer.hasContent(signature: hasSignature) {
            Text(Self.emptyWarning(hasSignature: hasSignature))
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 这一层什么都画不出来时怎么办：有签名图只是没勾 → 勾上；没签名图 → 去上面选一张。
    static func emptyWarning(hasSignature: Bool) -> String {
        hasSignature ? "还没东西可画：勾上「签名」，或者打开文字" : "还没东西可画：上面选一张签名图，或者打开文字"
    }

    /// 签名一组，顺序和水印页一样（位置、边距、大小、不透明度）。平铺时位置、边距不起作用：一起灰掉并说一句。
    @ViewBuilder
    private func signatureControls(_ layer: CollageMarkLayer) -> some View {
        let tiled = layer.tile != nil
        Group {
            positionRow(layer)
            CollageSlider(label: "边距", value: value(\.marginRatio),
                          range: Self.range(CollageMarkLayer.marginRange, including: layer.marginRatio),
                          display: percentText(layer.marginRatio))
        }
        .disabled(tiled)
        .opacity(tiled ? 0.45 : 1)
        if tiled {
            Text("平铺时位置和边距不起作用").font(.caption2).foregroundStyle(.tertiary)
        }
        CollageSlider(label: "大小", value: value(\.sizeRatio),
                      range: Self.range(CollageMarkLayer.sizeRange, including: layer.sizeRatio),
                      display: percentText(layer.sizeRatio))
        CollageSlider(label: "不透明度", value: value(\.opacity),
                      range: Self.range(0.05...1, including: layer.opacity), display: percentText(layer.opacity))
        Toggle("平铺（签名斜着铺满）", isOn: tileBinding)
            .help("样片防盗：签名铺满整块区域；位置、边距不起作用")
    }

    private func positionRow(_ layer: CollageMarkLayer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            positionGrid(layer.position) { p in
                update { l in
                    l.position = p
                    l.landscapePosition = nil
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("签名位置：\(layer.position.label)").font(.caption2).foregroundStyle(.secondary)
                if let landscape = layer.landscapePosition, layer.tile == nil {
                    Text("横的区域放「\(landscape.label)」（水印页带来的）；点左边统一成一个")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 3×3 位置格（签名、字各一个，样子一样）。
    private func positionGrid(_ current: WatermarkEngine.GridPosition,
                              pick: @escaping (WatermarkEngine.GridPosition) -> Void) -> some View {
        VStack(spacing: 3) {
            ForEach([-1, 0, 1], id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach([-1, 0, 1], id: \.self) { col in
                        positionButton(.at(row: row, column: col), current: current, pick: pick)
                    }
                }
            }
        }
    }

    private func positionButton(_ position: WatermarkEngine.GridPosition, current: WatermarkEngine.GridPosition,
                                pick: @escaping (WatermarkEngine.GridPosition) -> Void) -> some View {
        let active = position == current
        return Button {
            pick(position)
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(active ? Color.accentColor : Color.gray.opacity(0.25))
                .frame(width: 18, height: 14)
        }
        .buttonStyle(.plain)
        .help(position.label)
    }

    /// 文字：开关 + 一行字 + 字自己的位置和字号。留空用相机参数（EXIF）模板；写了就用这段（可带 {title} {date}）。
    @ViewBuilder
    private func textRows(_ layer: CollageMarkLayer) -> some View {
        Toggle("文字", isOn: textOnBinding)
        if let text = layer.text {
            TextField("留空 = 相机参数；可写 © 名字、{title} {date}", text: customTextBinding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            HStack(alignment: .top, spacing: 12) {
                positionGrid(text.position) { p in update { $0.text?.position = p } }
                Text("字的位置：\(text.position.label)").font(.caption2).foregroundStyle(.secondary)
            }
            CollageSlider(label: "字号", value: fontSizeBinding,
                          range: Self.range(CollageMarkText.fontSizeRange, including: text.fontSizeRatio),
                          display: String(format: "%.1f%%", text.fontSizeRatio * 100))
        }
    }

    /// 深浅：签名和字一起。「原色」= 签名原色（水印页带了着色就照着色）、字用设定的颜色。
    @ViewBuilder
    private func contrastRows(_ layer: CollageMarkLayer) -> some View {
        Picker("深浅", selection: Binding(get: { layer.contrast }, set: { v in update { $0.contrast = v } })) {
            ForEach(CollageMarkContrast.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("自动：底下亮用黑、暗用白（签名、字各看各的落点）；白 / 黑：签名和字都染成白 / 近黑（字带底色时底色换成反色）；原色：照签名本来的颜色")
        Text(Self.contrastNote(layer))
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func contrastNote(_ layer: CollageMarkLayer) -> String {
        let auto = "自动 = 看底下照片的深浅（带底色的字不变色）；白 / 黑 时字的底色换成反色"
        guard layer.contrast == .original, layer.tint != nil else { return auto }
        return auto + "。「原色」现在用水印页带来的着色"
    }

    /// 整页层：放不放进留白、九宫格 / 轮播 / 相册怎么分。
    @ViewBuilder
    private func pageRows(_ layer: CollageMarkLayer) -> some View {
        Toggle("有留白时放在留白里", isOn: Binding(get: { layer.preferMargin },
                                              set: { on in update { $0.preferMargin = on } }))
            .help("版心外的留白够宽（不窄于水印高度的六成）就画在留白里、不压照片；留白太窄或位置在正中，照旧压在照片上")
        CollageMarkSplitPicker(store: store)
    }

    private func skipToggle(_ id: String) -> some View {
        let name = Self.photoName(id, photos: store.project.photos)
        return Toggle(isOn: Binding(
            get: { watermark?.skipPhotoIDs.contains(id) ?? false },
            set: { on in
                store.updateWatermark { wm in
                    var ids = wm.skipPhotoIDs
                    if on { ids.insert(id) } else { ids.remove(id) }
                    wm.skipPhotoIDs = ids
                }
            })) {
            Text("这张不加（\(name)）").lineLimit(1).truncationMode(.middle)
        }
        .help("\(name)：按照片记，互换位置、换一批都跟着这张走")
    }

    /// 照片的文件名（不显示内部 id：外部文件的 id 是「file:」+ 整条路径）。
    static func photoName(_ id: String, photos: [CollagePhotoRef]) -> String {
        let path = photos.first { $0.id == id }?.path ?? id
        return (path as NSString).lastPathComponent
    }

    private var selectedPhotoID: String? { Self.selectedPhotoID(store) }

    /// 选中的照片（网格的照片格，或散落版的相纸）。
    @MainActor
    static func selectedPhotoID(_ store: CollageStore) -> String? {
        if let item = store.selectedItemValue {
            return item.kind == .photo ? item.photoID : nil
        }
        guard let cell = store.selectedCell, cell.kind == .photo else { return nil }
        return cell.photoID
    }

    /// 滑杆范围：平常是 base；工程里存的值在外头（命令行、手改的工程文件）就放宽到含它，不然一碰就被夹回去。
    static func range(_ base: ClosedRange<Double>, including v: Double) -> ClosedRange<Double> {
        min(base.lowerBound, v)...max(base.upperBound, v)
    }

    // 绑定

    /// 改这一层；没开就什么都不做（不凭空记一步撤销）。
    private func update(coalesce: Bool = false, _ body: (inout CollageMarkLayer) -> Void) {
        let kind = self.kind
        guard store.project.watermark?.layer(kind) != nil else { return }
        store.updateWatermark(coalesce: coalesce) { wm in
            guard var l = wm.layer(kind) else { return }
            body(&l)
            wm.setLayer(kind, l)
        }
    }

    private func value(_ keyPath: WritableKeyPath<CollageMarkLayer, Double>) -> Binding<Double> {
        Binding(get: { layer?[keyPath: keyPath] ?? 0 },
                set: { v in update(coalesce: true) { $0[keyPath: keyPath] = v } })
    }

    /// 开关一层：关掉再打开恢复原来的设置（不是默认值）；第一次打开、工程里还没签名就先开着文字。
    private var enabledBinding: Binding<Bool> {
        let kind = self.kind
        return Binding(get: { layer != nil }, set: { on in store.setMarkLayer(kind, on: on) })
    }

    /// 文字开关：关掉再打开恢复原来的字。
    private var textOnBinding: Binding<Bool> {
        let kind = self.kind
        return Binding(get: { layer?.text != nil }, set: { on in store.setMarkText(kind, on: on) })
    }

    private var customTextBinding: Binding<String> {
        Binding(get: { layer?.text?.customText ?? "" },
                set: { v in update(coalesce: true) { $0.text?.customText = v } })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { layer?.text?.fontSizeRatio ?? CollageMarkText().fontSizeRatio },
                set: { v in update(coalesce: true) { $0.text?.fontSizeRatio = v } })
    }

    private var tileBinding: Binding<Bool> {
        Binding(get: { layer?.tile != nil }, set: { on in
            update { l in l.tile = on ? (l.tile ?? CollageMarkTile()) : nil }
        })
    }
}

/// 整页层怎么分：九宫格 / 轮播 每片一个还是整张一次；相册 只放右页还是左右两页。别的画布不显示。
struct CollageMarkSplitPicker: View {
    @ObservedObject var store: CollageStore

    private var watermark: CollageWatermark? { store.project.watermark }

    var body: some View {
        let seams = store.project.canvas.seams
        if seams == .grid9 || seams == .carousel {
            Picker("切片", selection: Binding(get: { watermark?.tiles ?? .once },
                                             set: { v in store.updateWatermark { $0.tiles = v } })) {
                Text("每片一个").tag(CollageMarkTiles.eachTile)
                Text("整张一次").tag(CollageMarkTiles.once)
            }
            .pickerStyle(.segmented)
            if let hint = Self.onceHint(store.project, page: store.page) {
                Text(hint)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if seams == .fold {
            Picker("相册", selection: Binding(get: { watermark?.albumSides ?? .right },
                                             set: { v in store.updateWatermark { $0.albumSides = v } })) {
                Text("只放右页").tag(CollageMarkSides.right)
                Text("左右两页").tag(CollageMarkSides.both)
            }
            .pickerStyle(.segmented)
        }
    }

    /// 「整张一次」切开后落在哪一片：签名、字各说各的（九宫格从左上数第几片，轮播从左数第几张）。按渲染真排
    /// 出来的位置说（CollageWatermarks.pagePlacement）：留白带里让开贴纸换到另一头、签名图读不了（不画）都算进去，
    /// 不按锚点推。括号里九宫格是那一片在九宫格里的位置，轮播是落在那一张的哪儿。
    static func onceHint(_ project: CollageProject, page: CollagePage?) -> String? {
        let canvas = project.canvas
        guard let wm = project.watermark, wm.tiles == .once, wm.page != nil, let page,
              canvas.seams == .grid9 || canvas.seams == .carousel else { return nil }
        let grid = canvas.seams == .grid9
        let tiles = CollageExport.tileRects(width: canvas.width, height: canvas.height, rows: grid ? 3 : 1,
                                            cols: grid ? 3 : max(1, canvas.slides))
        func spot(_ r: CGRect) -> String? {
            let c = CGPoint(x: r.midX, y: r.midY)
            guard let i = tiles.firstIndex(where: { $0.contains(c) }) else { return nil }
            let t = tiles[i]
            let row = grid ? i / 3 - 1 : third(c.y, in: t.minY, t.height)
            let column = grid ? i % 3 - 1 : third(c.x, in: t.minX, t.width)
            return "第 \(i + 1) \(grid ? "片" : "张")（\(WatermarkEngine.GridPosition.at(row: row, column: column).label)）"
        }
        let placed = CollageWatermarks.pagePlacement(project: project, page: page)
        let text = placed.first { $0.kind == "text" }.flatMap { spot($0.rect) }
        if placed.contains(where: { $0.kind == "tile" }) {
            return "整张一次：签名平铺满整张，切开后每片都有" + (text.map { "；字只在\($0)" } ?? "")
        }
        var parts: [String] = []
        if let s = placed.first(where: { $0.kind == "signature" }).flatMap({ spot($0.rect) }) {
            parts.append("签名只在\(s)")
        }
        if let text { parts.append("字只在\(text)") }
        guard !parts.isEmpty else { return nil }
        return "整张一次：切开后" + parts.joined(separator: "、") + "，别的片上没有"
    }

    /// 在一段里落在前、中、后哪三分之一（-1 / 0 / 1）。
    private static func third(_ v: CGFloat, in start: CGFloat, _ length: CGFloat) -> Int {
        let u = (v - start) / max(1, length)
        return u < 1.0 / 3 ? -1 : (u > 2.0 / 3 ? 1 : 0)
    }
}

// MARK: - 文字核对（--collage-ui --tab 水印）

extension CollageWatermarkPanel {
    /// 面板上每层显示了什么，一层一行（和视图同一套判断）：离屏截图之外按文字断言用。
    @MainActor
    static func describe(_ store: CollageStore) -> [String] {
        guard let wm = store.project.watermark else { return ["水印面板 无水印"] }
        let lost = CollageSignatureBox.lost(wm.signature) ? " · " + CollageWatermarks.signatureLostPanelWarning : ""
        let head = "水印面板 签名：" + (wm.signature?.sourceName ?? "无") + lost
        return [head] + CollageMarkLayerKind.allCases.map { kind in
            guard let layer = wm.layer(kind) else { return "水印面板 \(kind.label)：关" }
            var parts = [signatureLine(layer, wm), textLine(layer), "深浅 " + layer.contrast.label]
            if !layer.hasContent(signature: wm.signature != nil) {
                parts.append(CollageMarkLayerBox.emptyWarning(hasSignature: wm.signature != nil))
            }
            if kind == .page {
                parts.append("留白" + (layer.preferMargin ? "✓" : "✗"))
                if let hint = CollageMarkSplitPicker.onceHint(store.project, page: store.page) { parts.append(hint) }
            }
            if kind == .photos, let id = CollageMarkLayerBox.selectedPhotoID(store) {
                let name = CollageMarkLayerBox.photoName(id, photos: store.project.photos)
                parts.append("这张不加（\(name)）" + (wm.skipPhotoIDs.contains(id) ? "✓" : "✗"))
            }
            return "水印面板 \(kind.label)：" + parts.joined(separator: " · ")
        }
    }

    private static func signatureLine(_ layer: CollageMarkLayer, _ wm: CollageWatermark) -> String {
        guard CollageMarkLayerBox.signatureDrawn(layer, in: wm) else { return "签名✗（签名那组不显示）" }
        let size = CollageMarkLayerBox.range(CollageMarkLayer.sizeRange, including: layer.sizeRatio)
        let margin = CollageMarkLayerBox.range(CollageMarkLayer.marginRange, including: layer.marginRatio)
        let tiled = layer.tile != nil ? " 平铺（位置、边距灰）" : ""
        return "签名✓ 签名位置\(layer.position.label) 大小 \(percentText(layer.sizeRatio))[\(rangeText(size))]"
            + " 边距 \(percentText(layer.marginRatio))[\(rangeText(margin))]" + tiled
    }

    private static func textLine(_ layer: CollageMarkLayer) -> String {
        guard let text = layer.text else { return "字✗" }
        let range = CollageMarkLayerBox.range(CollageMarkText.fontSizeRange, including: text.fontSizeRatio)
        return "字✓ 字的位置\(text.position.label) 字号 " + String(format: "%.1f%%", text.fontSizeRatio * 100)
            + "[\(rangeText(range))]"
    }

    private static func rangeText(_ r: ClosedRange<Double>) -> String {
        percentText(r.lowerBound) + "–" + percentText(r.upperBound)
    }
}

// MARK: - 从水印页拿设置

/// 「用水印页的设置 ▸ 每张照片 / 整页」「预设 ▸ 名字 ▸ …」：和水印页「套到当前拼图」走同一个函数。
struct CollageWatermarkAdoptBox: View {
    @ObservedObject var store: CollageStore
    @ObservedObject var watermarkStore: WatermarkStore

    var body: some View {
        GroupBox("从水印页拿") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    currentMenu
                    presetMenu
                    Spacer(minLength: 0)
                }
                .font(.caption)
                Text("拿过来的是一份快照：之后改水印页不会改掉这里。边距按水印页那张照片折成比例，每格成比例。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var currentMenu: some View {
        Menu("用水印页的设置") {
            layerButtons(preset: nil)
        }
        .fixedSize()
        .disabled(!watermarkStore.canSendToCollage)
        .help(watermarkStore.collageBlockedReason ?? "水印页现在的签名、位置、大小、文字套到这一层（相框、画布比例不带）")
    }

    private var presetMenu: some View {
        Menu("预设") {
            ForEach(watermarkStore.presets.keys.sorted(), id: \.self) { name in
                Menu(name) { layerButtons(preset: name) }
            }
        }
        .fixedSize()
        .disabled(watermarkStore.presets.isEmpty)
        .help(watermarkStore.presets.isEmpty ? "水印页还没存过预设" : "水印页存的预设套到这一层（签名图用水印页现在那张）")
    }

    private func layerButtons(preset: String?) -> some View {
        ForEach(CollageMarkLayerKind.allCases, id: \.self) { kind in
            Button("套到「\(kind.label)」") { adopt(kind, preset: preset) }
        }
    }

    private func adopt(_ kind: CollageMarkLayerKind, preset: String?) {
        let request = watermarkStore.makeCollageRequest(.applyToCurrent(kind), preset: preset)
        CollageHandoff.adopt(request, layer: kind, into: store)
    }
}
