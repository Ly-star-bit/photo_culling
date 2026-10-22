import SwiftUI
import ImageIO

// MARK: - 交付导出设置（三个 JPG 出口共用的一段界面）

/// 导出 JPG、精华 Top N 两个面板和水印页「导出设置」共用：尺寸 / 锐化 / 色彩 / 质量 / 体积上限 / GPS / 文件名。
/// 每一行拆成自己的小 view：CI 的 Xcode 16 对长 body 类型检查会超时。
struct DeliveryOptionsSection: View {
    @Binding var options: DeliveryOptions
    /// 第一张导出来叫什么（出口自己算：带着序号、精华的名次）。
    let namePreview: String
    /// 水印页是在 sRGB 画布上合成的，没有色彩这一行。
    var showsColor = true
    var tokensHint = DeliveryNaming.tokensHint
    var sizeHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DeliverySizeRow(options: $options, hint: sizeHint)
            DeliverySharpenRow(options: $options)
            if showsColor { DeliveryColorRow(options: $options) }
            DeliveryQualityRow(options: $options)
            DeliveryLimitRow(options: $options)
            Toggle("去掉 GPS 位置", isOn: $options.stripGPS)
                .help("交付给客户或发到公开平台时去掉拍摄地点（上门拍摄时就是客户家的地址）；拍摄时间、机身镜头、版权照留")
            DeliveryNameRow(options: $options, preview: namePreview, hint: tokensHint)
        }
    }
}

private struct DeliverySizeRow: View {
    @Binding var options: DeliveryOptions
    let hint: String?
    private static let customLong = "custom-long"
    private static let customShort = "custom-short"
    /// 点过「自定义长边 / 短边」就记着：长边 2048 选「自定义长边」时尺寸值没变（还是 long:2048），
    /// 只看尺寸值的话菜单会弹回「长边 2048」、像素框也不出来；自定义里填 1080 也不会跳成朋友圈。
    @State private var customMode: String?

    private var selection: Binding<String> {
        Binding(get: {
            let size = options.sizeValue
            switch (customMode, size) {
            case (Self.customLong?, .long): return Self.customLong
            case (Self.customShort?, .short): return Self.customShort
            default: break
            }
            if let preset = DeliverySize.presets.first(where: { $0.size == size }) { return preset.id }
            if case .short = size { return Self.customShort }
            return Self.customLong
        }, set: { id in
            let edge = customEdge
            customMode = id == Self.customLong || id == Self.customShort ? id : nil
            // 换了尺寸，色彩回到跟着尺寸走（原尺寸保留、其余 sRGB）。
            options.color = nil
            if id == Self.customLong {
                options.size = DeliverySize.long(edge).spec
            } else if id == Self.customShort {
                options.size = DeliverySize.short(edge).spec
            } else if let preset = DeliverySize.presets.first(where: { $0.id == id }) {
                options.size = preset.size.spec
            }
        })
    }

    /// 自定义的边长；从预设切过来时沿用它的长边，原尺寸 / 框切过来给 3000。
    private var customEdge: Int {
        switch options.sizeValue {
        case .long(let n), .short(let n): return n
        default: return 3000
        }
    }

    private var isCustom: Bool {
        let id = selection.wrappedValue
        return id == Self.customLong || id == Self.customShort
    }

    private var edgeBinding: Binding<Int> {
        Binding(get: { customEdge }, set: { value in
            let n = min(20000, max(16, value))
            if case .short = options.sizeValue {
                options.size = DeliverySize.short(n).spec
            } else {
                options.size = DeliverySize.long(n).spec
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("尺寸", selection: selection) {
                    ForEach(DeliverySize.presets) { preset in
                        Text(preset.label).tag(preset.id)
                    }
                    Text("自定义长边").tag(Self.customLong)
                    Text("自定义短边").tag(Self.customShort)
                }
                if isCustom {
                    TextField("像素", value: edgeBinding, format: .number.grouping(.never))
                        .frame(width: 60)
                    Text("px")
                }
            }
            .help("放进这个尺寸：不裁切、不放大（原图比它小就按原图）")
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DeliverySharpenRow: View {
    @Binding var options: DeliveryOptions

    var body: some View {
        let original = options.sizeValue == .original
        Picker("锐化", selection: $options.sharpen) {
            ForEach(DeliverySharpen.allCases, id: \.self) { level in
                Text(level.label).tag(level)
            }
        }
        .pickerStyle(.segmented)
        .disabled(original)
        .help(original
              ? "原尺寸不锐化：输出锐化只补缩小损失的那点清晰度"
              : "缩小后补一刀输出锐化（和检视器同一套 Lanczos + USM）；原图本来就比目标小的不锐化")
    }
}

private struct DeliveryColorRow: View {
    @Binding var options: DeliveryOptions

    var body: some View {
        Picker("色彩", selection: Binding(get: { options.effectiveColor }, set: { options.color = $0 })) {
            ForEach(DeliveryColor.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .help("网络 / 微信用 sRGB：Adobe RGB、P3 的原片真转换过去，平台丢了色彩描述也不发灰。给印厂的原尺寸保留原色彩空间")
    }
}

private struct DeliveryQualityRow: View {
    @Binding var options: DeliveryOptions

    var body: some View {
        let percent = Binding(get: { (options.quality * 100).rounded() },
                              set: { options.quality = $0 / 100 })
        HStack {
            Text("质量")
            Slider(value: percent, in: 60...100, step: 5)
            Text("\(Int(percent.wrappedValue))").monospacedDigit().frame(width: 30)
        }
    }
}

private struct DeliveryLimitRow: View {
    @Binding var options: DeliveryOptions

    var body: some View {
        HStack(spacing: 6) {
            Toggle("限制在", isOn: $options.limitSize)
            TextField("MB", value: $options.maxMB, format: .number)
                .frame(width: 48)
                .disabled(!options.limitSize)
            Text("MB 以内")
        }
        .help("超了就自动降质量（最低 \(Int(DeliveryEncoder.floorQuality * 100))），还放不下的照最低质量写出并点名告诉你")
    }
}

private struct DeliveryNameRow: View {
    @Binding var options: DeliveryOptions
    let preview: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("文件名")
                TextField(DeliveryNaming.originalToken, text: $options.nameTemplate)
            }
            Text("第一张：" + preview)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Text(hint + "；「:3」补零到 3 位，重名另存 -2")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 离屏快照用（--batch-ui <dir> <out.png> --delivery-ui jpeg|highlights|watermark [--delivery-json '{…}']）：
/// sheet 在离屏窗口里画不出来，按那个出口的默认（盖上 JSON 里的字段）单独画这一段，宽度和面板一样。
struct DeliveryOptionsPreview: View {
    @State var options: DeliveryOptions
    let preview: String
    var showsColor = true
    var tokensHint = DeliveryNaming.tokensHint
    var width: CGFloat = 460

    var body: some View {
        DeliveryOptionsSection(options: $options, namePreview: preview, showsColor: showsColor, tokensHint: tokensHint)
            .padding(20)
            .frame(width: width, alignment: .topLeading)
    }
}

// MARK: - 导出 JPG / 精华 Top N（无头）

/// LABELGUI_DATA_DIR=<临时目录> LabelGUI --export-jpeg <photo_dir> --dest <dir>
///     [--scope picks|picks+usable|top:N] [--size original|4096|2048|moments|xhs|ig|long:N|short:N|box:WxH]
///     [--sharpen off|std|high] [--color srgb|keep] [--strip-gps|--keep-gps] [--name '<模板>']
///     [--max-mb X] [--quality Q] [--overwrite]
/// 走界面上同一个 exportJPEGs / exportHighlights（top:N 时 --dest 就是「精华」那一层，里面新建 TopN_日期_时间）。
/// 没给的选项用界面的出厂默认（不读 UserDefaults：那是全局的，临时数据目录隔离不了）。
/// 打印写出的每个文件：名字、像素尺寸、方向、字节数。
enum JPEGExportCLI {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        CollageCLI.requireIsolatedDataDir("--export-jpeg")
        guard let destPath = option("--dest") else {
            print("--export-jpeg 要 --dest <目录>")
            exit(1)
        }
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let dest = URL(fileURLWithPath: destPath)
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        guard !store.items.isEmpty else {
            print("这一场没有分析结果（先 --analyze）：\(dir.path)")
            exit(1)
        }
        let scope = option("--scope") ?? "picks+usable"
        let top = scope.hasPrefix("top:") ? Int(scope.dropFirst(4)) : nil
        var options = top != nil ? DeliveryOptions.highlights(legacyMaxPixel: 2048)
            : DeliveryOptions.jpegExport(legacyMaxPixel: 0, legacyQuality: 90)
        apply(&options, option: option, flags: Set(args))
        print("设置: 尺寸 \(options.size) · 锐化 \(options.sharpen.rawValue) · 色彩 \(options.effectiveColor.rawValue)"
              + " · 去 GPS \(options.stripGPS ? "是" : "否") · 文件名 \(options.nameTemplate)"
              + " · 质量 \(Int((options.quality * 100).rounded()))" + (options.limitSize ? " · ≤\(options.maxMB) MB" : ""))
        if let top {
            store.exportHighlights(count: top, into: dest, options: options)
        } else {
            store.exportJPEGs(to: dest, includeUsable: scope != "picks", options: options,
                              overwrite: args.contains("--overwrite"))
        }
        let deadline = Date().addingTimeInterval(600)
        while store.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(store.progressText)
        if let error = store.lastError { print("提醒: " + error) }
        guard let report = store.lastJPEGExport else { exit(1) }
        print("文件夹 \(report.folder.path)")
        for url in report.written { print("  " + describe(url)) }
        exit(report.failed.isEmpty ? 0 : 1)
    }

    private static func apply(_ options: inout DeliveryOptions, option: (String) -> String?, flags: Set<String>) {
        if let size = option("--size") { options.size = DeliverySize(spec: size).spec }
        switch option("--sharpen") {
        case "off": options.sharpen = .off
        case "std", "standard": options.sharpen = .standard
        case "high": options.sharpen = .high
        default: break
        }
        if let color = option("--color") { options.color = color == "keep" ? .keep : .srgb }
        if flags.contains("--strip-gps") { options.stripGPS = true }
        if flags.contains("--keep-gps") { options.stripGPS = false }
        if let name = option("--name") { options.nameTemplate = name }
        if let mb = option("--max-mb").flatMap(Double.init) {
            options.limitSize = true
            options.maxMB = mb
        }
        // 0–1 或 60–100 都认。
        if let q = option("--quality").flatMap(Double.init) { options.quality = q > 1 ? q / 100 : q }
    }

    private static func describe(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return "\(url.lastPathComponent) 读不出来 \(bytes) B"
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        let gps = props[kCGImagePropertyGPSDictionary] != nil ? "有GPS" : "无GPS"
        let profile = (props[kCGImagePropertyProfileName] as? String) ?? "-"
        return "\(url.lastPathComponent) \(w)x\(h) 方向\(orientation) \(gps) \(profile) \(bytes) B"
    }
}
