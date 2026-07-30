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
            Button("导入选片结果 (\(keeperCount))") {
                store.importFromBatch(batchStore, includeUsable: true)
            }
            .disabled(keeperCount == 0)
            .help("把批量处理页当前的精选+可用照片拉进来 (RAW 自动用配对 JPG)")
            Button("清空") { store.clearPhotos() }
                .disabled(store.photos.isEmpty)
            Spacer()
            Button {
                pickOutputDir()
            } label: {
                Label(store.outputDir?.lastPathComponent ?? "输出目录...", systemImage: "folder")
            }
            Button("批量导出 (\(store.photos.count))") { store.exportAll() }
                .buttonStyle(.borderedProminent)
                .disabled(store.photos.isEmpty || store.isExporting || store.outputDir == nil)
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
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
            }
            Spacer()
            if !store.progressText.isEmpty {
                Text(store.progressText).font(.caption).foregroundStyle(.secondary)
            }
            if let fraction = store.progressFraction {
                ProgressView(value: fraction).frame(width: 140)
            }
        }
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
                        Spacer()
                        Button {
                            store.removePhoto(url)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .tag(url)
                }
                .listStyle(.sidebar)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in store.addPhotos([url]) }
                    }
                }
            }
            return true
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
            } else if store.selectedPhoto != nil {
                ProgressView()
            } else {
                Text("导入照片后在这里实时预览").foregroundStyle(.secondary)
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
        GroupBox("签名图水印") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(store.signatureURL == nil ? "选择 PNG 签名..." : store.signatureURL!.lastPathComponent) {
                        pickSignature()
                    }
                    .lineLimit(1)
                    if store.signatureURL != nil {
                        Button {
                            store.signatureURL = nil
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                }
                gridPicker(selection: $store.config.position)
                labeledSlider("大小", value: $store.config.sizeRatio, in: 0.03...0.6,
                              display: "\(Int(store.config.sizeRatio * 100))%")
                labeledSlider("不透明度", value: $store.config.opacity, in: 0.05...1,
                              display: "\(Int(store.config.opacity * 100))%")
                labeledSlider("边距 X", value: $store.config.marginX, in: 0...300,
                              display: "\(Int(store.config.marginX))px")
                labeledSlider("边距 Y", value: $store.config.marginY, in: 0...300,
                              display: "\(Int(store.config.marginY))px")

                // 着色: 原色 / 白 / 米白 / 灰 / 黑 / 自定义
                HStack(spacing: 6) {
                    Text("颜色").font(.caption)
                    tintSwatch(nil, label: "原")
                    tintSwatch(WatermarkEngine.RGB(r: 255, g: 255, b: 255), label: "白")
                    tintSwatch(WatermarkEngine.RGB(r: 245, g: 240, b: 230), label: "米")
                    tintSwatch(WatermarkEngine.RGB(r: 128, g: 128, b: 128), label: "灰")
                    tintSwatch(WatermarkEngine.RGB(r: 0, g: 0, b: 0), label: "黑")
                    ColorPicker("", selection: rgbBinding(
                        get: { store.config.tint },
                        set: { store.config.tint = $0; store.config.tintEnabled = true }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 34)
                }
                Toggle("横构图用不同位置", isOn: $store.config.landscapeOverrideEnabled)
                    .font(.caption)
                if store.config.landscapeOverrideEnabled {
                    gridPicker(selection: $store.config.landscapeOverride)
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
                        .help("占位符: {make} {model} {lens} {fnumber} {shutter} {iso} {focal} {date}")
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
                    Toggle("竖分隔线 (Canon 风)", isOn: $store.config.frame.showDivider).font(.caption)
                    TextField("左上", text: $store.config.frame.leftLine1).font(.caption)
                    TextField("左下", text: $store.config.frame.leftLine2).font(.caption)
                    TextField("右上", text: $store.config.frame.rightLine1).font(.caption)
                    TextField("右下", text: $store.config.frame.rightLine2).font(.caption)
                }
            }
            .padding(6)
        }
    }

    private var tileBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("全图平铺 (样片防盗)", isOn: $store.config.tile.enabled).bold()
                if store.config.tile.enabled {
                    labeledSlider("角度", value: $store.config.tile.angleDeg, in: 0...90,
                                  display: "\(Int(store.config.tile.angleDeg))°")
                    labeledSlider("间距", value: $store.config.tile.gapRatio, in: 0...2,
                                  display: String(format: "%.1f", store.config.tile.gapRatio))
                }
            }
            .padding(6)
        }
    }

    private var canvasRatioBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("画布比例扩展 (补白)", isOn: $store.config.canvasRatio.enabled).bold()
                if store.config.canvasRatio.enabled {
                    Picker("比例", selection: Binding(
                        get: { "\(Int(store.config.canvasRatio.ratioW)):\(Int(store.config.canvasRatio.ratioH))" },
                        set: { value in
                            let parts = value.split(separator: ":").compactMap { Double($0) }
                            if parts.count == 2 {
                                store.config.canvasRatio.ratioW = parts[0]
                                store.config.canvasRatio.ratioH = parts[1]
                            }
                        }
                    )) {
                        ForEach(["1:1", "3:4", "4:3", "9:16", "16:9"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
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
                labeledSlider("质量", value: $store.options.quality, in: 0.6...1,
                              display: "\(Int(store.options.quality * 100))")
                TextField("文件名后缀", text: $store.options.filenameSuffix).font(.caption)
                Text("输出 JPEG · EXIF/拍摄参数保留").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(6)
        }
    }

    private var presetBox: some View {
        GroupBox("预设") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("预设名 (社交/交付/展览...)", text: $presetName)
                    Button("保存") {
                        store.savePreset(named: presetName)
                        presetName = ""
                    }
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(store.presets.keys.sorted(), id: \.self) { name in
                    HStack {
                        Button(name) { store.applyPreset(named: name) }
                            .buttonStyle(.link)
                        Spacer()
                        Button {
                            store.deletePreset(named: name)
                        } label: { Image(systemName: "trash").font(.caption) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(6)
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

    private func tintSwatch(_ rgb: WatermarkEngine.RGB?, label: String) -> some View {
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
        .help(rgb == nil ? "签名原色" : label)
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
