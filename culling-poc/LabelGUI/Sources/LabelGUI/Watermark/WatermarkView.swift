import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 水印 tab: 左照片列表 · 中实时预览 · 右参数面板。
/// watermark_photographer (Tauri) 的原生 Swift 重写，与选片流程打通 —
/// 一键把当前批次的精选拉进来签名后交付。
struct WatermarkView: View {
    @ObservedObject var store: WatermarkStore
    @ObservedObject var batchStore: BatchStore
    @State private var presetName = ""
    @State private var presetToDelete: String?
    @State private var presetToOverwrite: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                photoList
                    .frame(minWidth: 200, maxWidth: 280)
                previewPane
                    .frame(minWidth: 400)
                settingsPanel
                    .frame(width: 330)
            }
            Divider()
            statusBar
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("导入照片...") { pickPhotos() }
                .keyboardShortcut("o", modifiers: .command)
                .help("导入照片或文件夹 (⌘O)")
            Button("导入选片结果 (\(keeperCount))") {
                store.importFromBatch(batchStore, includeUsable: true)
            }
            .disabled(keeperCount == 0)
            .help("把批量处理页当前的精选+可用照片拉进来 (RAW 自动用配对 JPG)")
            Button("清空") { store.clearPhotos() }
                .disabled(store.photos.isEmpty || store.isExporting)
            Spacer()
            Button {
                pickOutputDir()
            } label: {
                Label {
                    Text(store.outputDir?.lastPathComponent ?? "输出目录...")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .frame(maxWidth: 220)
            }
            .help(store.outputDir?.path ?? "选择导出目录")
            if store.isExporting {
                Button("取消") { store.cancelExport() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("停止排新的照片，已写出的保留 (Esc)")
            }
            Button("批量导出 (\(store.photos.count))") { store.exportAll() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.canExport)
                .help(store.exportBlockedReason ?? "把列表里的照片全部加水印后写到输出目录 (⌘⏎)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var keeperCount: Int {
        let counts = batchStore.verdictCounts
        return counts.pick + counts.usable
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let error = store.lastError {
                HStack(spacing: 4) {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                    Button {
                        store.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                }
            }
            Spacer()
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if !store.progressText.isEmpty {
                Text(store.progressText).font(.caption).foregroundStyle(.secondary)
            }
            if let fraction = store.progressFraction {
                ProgressView(value: fraction).frame(width: 140)
            }
        }
        .animation(.default, value: store.notice)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - 左: 照片列表 (可拖拽)

    private var photoList: some View {
        Group {
            if store.photos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("拖拽照片/文件夹到这里\n或点「导入照片」")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.photos, id: \.self, selection: Binding(
                    get: { store.selectedPhoto },
                    set: { if let url = $0 { store.selectPhoto(url) } }
                )) { url in
                    HStack(spacing: 8) {
                        ThumbnailView(path: url.path, maxPixel: 128)
                            .frame(width: 48, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                            .help(url.path)
                        Spacer()
                        Button {
                            store.removePhoto(url)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("从列表移除 (Delete)")
                    }
                    .tag(url)
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    if let selected = store.selectedPhoto { store.removePhoto(selected) }
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(3)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            // 先把所有 provider 的 URL 收齐，按拖入顺序一次性导入：逐个回调会
            // 触发 N 次导入 + N 次预览，而且回调顺序不保证。
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.loadURL(from: provider) { urls.append(url) }
                }
                store.addPhotos(urls)
            }
            return true
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - 中: 预览

    private var previewPane: some View {
        ZStack {
            Color(white: 0.13)
            if let image = store.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .opacity(store.previewStale ? 0.55 : 1)
            } else if store.selectedPhoto != nil {
                ProgressView()
            } else {
                Text("导入照片后在这里实时预览").foregroundStyle(.secondary)
            }
            // 切换照片时旧图还在，新图在渲染：盖一层转圈而不是让人以为没反应。
            if store.previewStale, store.previewImage != nil {
                ProgressView().controlSize(.large)
            }
        }
        .overlay(alignment: .bottom) {
            if let hint = store.previewHint {
                Label(hint, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 14)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 右: 参数面板

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                signatureBox
                exifTextBox
                frameBox
                tileBox
                canvasRatioBox
                exportBox
                presetBox
            }
            .padding(10)
        }
    }

    private var signatureBox: some View {
        let tiling = store.config.tile.enabled
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("签名图水印", isOn: $store.config.signatureEnabled).bold()
                    .help("关掉后不画签名图，签名文件仍然记着")
                if store.config.signatureEnabled {
                    HStack {
                        Button {
                            pickSignature()
                        } label: {
                            Text(store.signatureURL?.lastPathComponent ?? "选择 PNG 签名...")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 200)
                        }
                        .help(store.signatureURL?.path ?? "选择带透明通道的 PNG 签名图")
                        if store.signatureURL != nil {
                            Button {
                                store.signatureURL = nil
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .help("清除签名图")
                        }
                    }
                    // 平铺模式下九宫格/边距/横构图位置都不参与计算，灰掉说明。
                    Group {
                        gridPicker(selection: $store.config.position)
                        labeledSlider("边距 X", value: $store.config.marginX, in: 0...300,
                                      display: "\(Int(store.config.marginX))px")
                        labeledSlider("边距 Y", value: $store.config.marginY, in: 0...300,
                                      display: "\(Int(store.config.marginY))px")
                    }
                    .disabled(tiling)
                    .opacity(tiling ? 0.45 : 1)
                    .help(tiling ? "平铺开启时位置和边距不生效" : "")
                    if tiling {
                        Text("平铺开启中：位置、边距、横构图位置不生效")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    labeledSlider("大小", value: $store.config.sizeRatio, in: 0.03...0.6,
                                  display: "\(Int(store.config.sizeRatio * 100))%")
                    labeledSlider("不透明度", value: $store.config.opacity, in: 0.05...1,
                                  display: "\(Int(store.config.opacity * 100))%")

                    // 着色: 原色 / 白 / 米白 / 灰 / 黑 / 自定义
                    HStack(spacing: 6) {
                        Text("颜色").font(.caption)
                        tintSwatch(nil, label: "原", name: "签名原色")
                        tintSwatch(WatermarkEngine.RGB(r: 255, g: 255, b: 255), label: "白", name: "白色")
                        tintSwatch(WatermarkEngine.RGB(r: 245, g: 240, b: 230), label: "米", name: "米白")
                        tintSwatch(WatermarkEngine.RGB(r: 128, g: 128, b: 128), label: "灰", name: "灰色")
                        tintSwatch(WatermarkEngine.RGB(r: 0, g: 0, b: 0), label: "黑", name: "黑色")
                        ColorPicker("", selection: rgbBinding(
                            get: { store.config.tint },
                            set: { store.config.tint = $0; store.config.tintEnabled = true }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 34)
                        .help("自定义着色")
                    }
                    Group {
                        Toggle("横构图用不同位置", isOn: $store.config.landscapeOverrideEnabled)
                            .font(.caption)
                        if store.config.landscapeOverrideEnabled {
                            gridPicker(selection: $store.config.landscapeOverride)
                        }
                    }
                    .disabled(tiling)
                    .opacity(tiling ? 0.45 : 1)
                }
            }
            .padding(6)
        }
    }

    private var exifTextBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("EXIF 文字水印", isOn: $store.config.exifText.enabled).bold()
                if store.config.exifText.enabled {
                    TextField("模板", text: $store.config.exifText.template)
                        .font(.caption)
                        .help("占位符: {make} {model} {lens} {fnumber} {shutter} {iso} {focal} {date}；照片里没有的字段会连同前面的标签一起省略")
                    TextField("自定义文字 (留空则用模板)", text: $store.config.exifText.customText)
                        .font(.caption)
                    gridPicker(selection: $store.config.exifText.position)
                    labeledSlider("字号", value: $store.config.exifText.fontSizeRatio, in: 0.01...0.08,
                                  display: String(format: "%.1f%%", store.config.exifText.fontSizeRatio * 100))
                    labeledSlider("不透明度", value: $store.config.exifText.opacity, in: 0.1...1,
                                  display: "\(Int(store.config.exifText.opacity * 100))%")
                    HStack {
                        Text("文字").font(.caption)
                        ColorPicker("", selection: rgbBinding(
                            get: { store.config.exifText.color },
                            set: { store.config.exifText.color = $0 }
                        ), supportsOpacity: false).labelsHidden()
                        Toggle("底色", isOn: $store.config.exifText.backgroundEnabled).font(.caption)
                        Toggle("通栏", isOn: $store.config.exifText.fullWidth).font(.caption)
                            .help("背景条铺满整幅图片宽度")
                    }
                }
            }
            .padding(6)
        }
    }

    private var frameBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("相框参数条", isOn: $store.config.frame.enabled).bold()
                    .help("白/黑边框 + 底部相机参数条 (莱卡/Canon 风)")
                if store.config.frame.enabled {
                    Picker("边框", selection: Binding(
                        get: { store.config.frame.borderColor.r > 128 },
                        set: { store.config.frame = Self.framePalette(white: $0, base: store.config.frame) }
                    )) {
                        Text("白").tag(true)
                        Text("黑").tag(false)
                    }
                    .pickerStyle(.segmented)
                    labeledSlider("边框宽", value: $store.config.frame.borderRatio, in: 0...0.08,
                                  display: String(format: "%.1f%%", store.config.frame.borderRatio * 100))
                    labeledSlider("参数条高", value: $store.config.frame.bottomBarRatio, in: 0.06...0.25,
                                  display: String(format: "%.0f%%", store.config.frame.bottomBarRatio * 100))
                    Toggle("显示品牌名", isOn: $store.config.frame.showBrand).font(.caption)
                        .help("居中品牌名；三块文字挤不下时会自动先隐藏它")
                    Toggle("竖分隔线 (Canon 风)", isOn: $store.config.frame.showDivider).font(.caption)
                    frameField("左上", $store.config.frame.leftLine1)
                    frameField("左下", $store.config.frame.leftLine2)
                    frameField("右上", $store.config.frame.rightLine1)
                    frameField("右下", $store.config.frame.rightLine2)
                    Text("支持 {model} {lens} {focal} {fnumber} {shutter} {iso} {date} 等占位符，留空不显示")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(6)
        }
    }

    /// 相框四个文本框：带位置标签，填了内容后也分得清哪个是哪个。
    private func frameField(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            TextField("留空不显示", text: text).font(.caption)
        }
    }

    private var tileBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("全图平铺 (样片防盗)", isOn: $store.config.tile.enabled).bold()
                    .help("用签名图铺满整张图；需要签名图水印开启")
                if store.config.tile.enabled {
                    labeledSlider("角度", value: $store.config.tile.angleDeg, in: 0...90,
                                  display: "\(Int(store.config.tile.angleDeg))°")
                    labeledSlider("间距", value: $store.config.tile.gapRatio, in: 0...2,
                                  display: String(format: "%.1f", store.config.tile.gapRatio))
                    if !store.config.signatureEnabled || store.signatureURL == nil {
                        Text("平铺用的是签名图：请先开启签名图水印并选择 PNG")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .padding(6)
        }
    }

    private static let ratioChoices = ["1:1", "2:3", "3:4", "4:5", "4:3", "9:16", "16:9"]
    private static let customRatioTag = "自定义"

    private var currentRatioKey: String {
        let key = String(format: "%g:%g", store.config.canvasRatio.ratioW, store.config.canvasRatio.ratioH)
        return Self.ratioChoices.contains(key) ? key : Self.customRatioTag
    }

    private var canvasRatioBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("画布比例扩展 (补白)", isOn: $store.config.canvasRatio.enabled).bold()
                if store.config.canvasRatio.enabled {
                    Picker("比例", selection: Binding(
                        get: { currentRatioKey },
                        set: { value in
                            let parts = value.split(separator: ":").compactMap { Double($0) }
                            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                                store.config.canvasRatio.ratioW = parts[0]
                                store.config.canvasRatio.ratioH = parts[1]
                            }
                        }
                    )) {
                        ForEach(Self.ratioChoices, id: \.self) { Text($0).tag($0) }
                        // 预设里带来的比例不在列表里时显示为"自定义"，而不是一个空白分段控件。
                        if currentRatioKey == Self.customRatioTag {
                            Text(String(format: "%g:%g (自定义)", store.config.canvasRatio.ratioW,
                                        store.config.canvasRatio.ratioH))
                                .tag(Self.customRatioTag)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    Picker("底色", selection: Binding(
                        get: { store.config.canvasRatio.fillColor.r > 128 },
                        set: { store.config.canvasRatio.fillColor = $0 ? .white : .black }
                    )) {
                        Text("白").tag(true)
                        Text("黑").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(6)
        }
    }

    private var exportBox: some View {
        GroupBox("导出设置") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("尺寸", selection: $store.options.maxLongSide) {
                    Text("原尺寸").tag(0)
                    Text("长边 2048").tag(2048)
                    Text("长边 4096").tag(4096)
                }
                .pickerStyle(.segmented)
                .help("含相框/画布扩展后的成品长边")
                labeledSlider("质量", value: $store.options.quality, in: 0.6...1,
                              display: "\(Int(store.options.quality * 100))")
                HStack(spacing: 6) {
                    Text("后缀").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                    TextField("文件名后缀", text: $store.options.filenameSuffix).font(.caption)
                        .help("追加在原文件名后；\"/\" 和 \":\" 会被去掉")
                }
                Toggle("去除位置信息 (GPS)", isOn: $store.options.stripGPS).font(.caption)
                    .help("交付给客户或发到公开平台时去掉拍摄地点")
                Text(store.options.stripGPS
                     ? "输出 JPEG · 保留 EXIF 拍摄参数与 XMP 版权/关键词 · 去除 GPS · 方向已烘焙进像素"
                     : "输出 JPEG · 保留 EXIF 拍摄参数、GPS 与 XMP 版权/关键词 · 方向已烘焙进像素")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(6)
        }
    }

    private var presetBox: some View {
        GroupBox("预设") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("预设名 (社交/交付/展览...)", text: $presetName)
                        .onSubmit { savePresetTapped() }
                    Button("保存") { savePresetTapped() }
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(store.presets.keys.sorted(), id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                            .opacity(store.activePresetName == name ? 1 : 0)
                            .frame(width: 12)
                        Button(name) { store.applyPreset(named: name) }
                            .buttonStyle(.link)
                            .help(store.activePresetName == name ? "当前参数就是这个预设" : "应用预设「\(name)」")
                        Spacer()
                        Button {
                            presetToDelete = name
                        } label: { Image(systemName: "trash").font(.caption) }
                            .buttonStyle(.plain)
                            .help("删除预设")
                    }
                }
                if store.presets.isEmpty {
                    Text("把当前全部参数存成预设，下次一键套用").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(6)
        }
        .confirmationDialog("删除预设？", isPresented: Binding(
            get: { presetToDelete != nil },
            set: { if !$0 { presetToDelete = nil } }
        ), presenting: presetToDelete) { name in
            Button("删除「\(name)」", role: .destructive) { store.deletePreset(named: name) }
            Button("取消", role: .cancel) {}
        } message: { name in
            Text("预设「\(name)」删除后无法恢复。")
        }
        .alert("覆盖已有预设？", isPresented: Binding(
            get: { presetToOverwrite != nil },
            set: { if !$0 { presetToOverwrite = nil } }
        ), presenting: presetToOverwrite) { name in
            Button("覆盖", role: .destructive) {
                store.savePreset(named: name)
                presetName = ""
            }
            Button("取消", role: .cancel) {}
        } message: { name in
            Text("预设「\(name)」已存在，保存会用当前参数替换它。")
        }
    }

    private func savePresetTapped() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if store.presets[name] != nil {
            presetToOverwrite = name
        } else {
            store.savePreset(named: name)
            presetName = ""
        }
    }

    /// 白框/黑框一键切换：边框、文字、副文字三色一起换，避免黑底黑字。
    private static func framePalette(white: Bool, base: WatermarkEngine.FrameConfig) -> WatermarkEngine.FrameConfig {
        var config = base
        if white {
            config.borderColor = WatermarkEngine.RGB(r: 250, g: 250, b: 250)
            config.textColor = WatermarkEngine.RGB(r: 30, g: 30, b: 30)
            config.subtextColor = WatermarkEngine.RGB(r: 110, g: 110, b: 110)
        } else {
            config.borderColor = WatermarkEngine.RGB(r: 18, g: 18, b: 18)
            config.textColor = WatermarkEngine.RGB(r: 235, g: 235, b: 235)
            config.subtextColor = WatermarkEngine.RGB(r: 150, g: 150, b: 150)
        }
        return config
    }

    // MARK: - 小组件

    /// 3×3 九宫格锚点选择。
    private func gridPicker(selection: Binding<WatermarkEngine.GridPosition>) -> some View {
        let rows: [[WatermarkEngine.GridPosition]] = [
            [.topLeft, .topCenter, .topRight],
            [.middleLeft, .center, .middleRight],
            [.bottomLeft, .bottomCenter, .bottomRight],
        ]
        return VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(rows[row], id: \.self) { pos in
                        Button {
                            selection.wrappedValue = pos
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selection.wrappedValue == pos
                                      ? Color.accentColor : Color.gray.opacity(0.25))
                                .frame(width: 26, height: 18)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func labeledSlider(_ label: String, value: Binding<Double>,
                               in range: ClosedRange<Double>, display: String) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: value, in: range)
            Text(display).font(.caption).monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func tintSwatch(_ rgb: WatermarkEngine.RGB?, label: String, name: String) -> some View {
        let isActive = rgb == nil ? !store.config.tintEnabled
            : (store.config.tintEnabled && store.config.tint == rgb)
        return Button {
            if let rgb {
                store.config.tint = rgb
                store.config.tintEnabled = true
            } else {
                store.config.tintEnabled = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(rgb.map { Color($0.nsColor) } ?? Color.clear)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(isActive ? Color.accentColor : .gray.opacity(0.4),
                                             lineWidth: isActive ? 2 : 1))
                if rgb == nil {
                    Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }

    private func rgbBinding(get: @escaping () -> WatermarkEngine.RGB,
                            set: @escaping (WatermarkEngine.RGB) -> Void) -> Binding<Color> {
        Binding<Color>(
            get: { Color(get().nsColor) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                set(WatermarkEngine.RGB(r: ns.redComponent * 255,
                                        g: ns.greenComponent * 255,
                                        b: ns.blueComponent * 255))
            }
        )
    }

    // MARK: - 文件选择

    private func pickPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            store.addPhotos(panel.urls)
        }
    }

    private func pickSignature() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.signatureURL = url
        }
    }

    private func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择输出目录"
        if panel.runModal() == .OK, let url = panel.url {
            store.outputDir = url
        }
    }
}
