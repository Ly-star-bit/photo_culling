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
                Text(hint).hintText()
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
              : "缩小后补一刀输出锐化，补回缩小损失的那点清晰度；原图本来就比目标小的不锐化")
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
                .hintText()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 导出 JPG 的范围（优化分析 UX-03）

/// 导出 JPG 导哪几张。以前面板上只有「包含可用」一个开关（整场精选 / 精选 + 可用）：选中的、客户选中的、只看这一章的
/// 都导不了，只能绕水印页（还必须带水印）。选中的、当前筛选两档和「复制原片 / 复制文件名」同一套（BatchView.deliveryScopeIDs）。
/// 精华 Top N 不走这里。
enum JPEGExportScope: String, CaseIterable, Sendable {
    /// 整场精选 / 精选 + 可用（引擎按判决挑，以前那个开关；这两档记住上次的）。
    case picks, picksUsable
    /// 网格里选中的，按网格顺序。
    case selected
    /// 客户选中的（导入过客户选择才有），按网格顺序。
    case client
    /// 当前筛选（判决、只看客户选中、只看这一章、临界、废片理由）下的全部，和复制原片没选中照片时一样。
    case filtered
}

/// 面板上的一档：名字里带张数（预先拼好，不在 ViewBuilder 里拼：CI 的 Xcode 16 类型检查慢）。
struct JPEGScopeChoice: Identifiable, Equatable {
    let scope: JPEGExportScope
    let title: String
    let count: Int
    var id: JPEGExportScope { scope }

    /// 开着的筛选：`label` 是「复制原片」菜单上那一截（「本章·精选 12 张」），`onlyClient` = 只开了「只看客户选中」。
    struct Filter: Equatable {
        let label: String
        let count: Int
        let onlyClient: Bool
    }

    /// 列哪几档：精选、精选 + 可用一直有；选中的（选了才有）、客户选中（有客户选中才有）、当前筛选（开着筛选才有；
    /// 只开了「只看客户选中」时和客户选中那档一模一样，不重复列）。
    static func choices(picks: Int, usable: Int, selected: Int, client: Int, filter: Filter?) -> [JPEGScopeChoice] {
        var out = [JPEGScopeChoice(scope: .picks, title: "精选 (\(picks) 张)", count: picks),
                   JPEGScopeChoice(scope: .picksUsable, title: "精选 + 可用 (\(picks + usable) 张)", count: picks + usable)]
        if selected > 0 {
            out.append(JPEGScopeChoice(scope: .selected, title: "选中的 \(selected) 张", count: selected))
        }
        if client > 0 {
            out.append(JPEGScopeChoice(scope: .client, title: "客户选中 \(client) 张", count: client))
        }
        if let filter, !filter.onlyClient {
            out.append(JPEGScopeChoice(scope: .filtered, title: "当前筛选：" + filter.label, count: filter.count))
        }
        return out
    }

    /// 打开面板时默认哪档：选了照片 = 选中的（UX-03 的建议）；否则上次的精选 / 精选 + 可用。不默认当前筛选：
    /// 开着「废片」筛选时会悄悄导出一堆废片。
    static func defaultScope(selected: Int, includeUsable: Bool) -> JPEGExportScope {
        selected > 0 ? .selected : (includeUsable ? .picksUsable : .picks)
    }

    /// `scope` 不在这几档里（选中的被清掉了……）就退回默认那档。
    static func resolve(_ scope: JPEGExportScope, in choices: [JPEGScopeChoice], includeUsable: Bool) -> JPEGExportScope {
        if choices.contains(where: { $0.scope == scope }) { return scope }
        return includeUsable ? .picksUsable : .picks
    }
}

/// 导出 JPG 面板最上面的「范围」一行（离屏快照 --delivery-ui jpeg 也画它）。
struct JPEGScopeRow: View {
    let choices: [JPEGScopeChoice]
    @Binding var selection: JPEGExportScope

    var body: some View {
        Picker("范围", selection: $selection) {
            ForEach(choices) { choice in
                Text(choice.title).tag(choice.scope)
            }
        }
        .help("选中的、客户选中的、当前筛选（只看这一章、按判决筛……）和「复制原片」是同一套范围；精选 / 精选 + 可用是整场")
    }
}

extension BatchStore {
    /// 客户选中的照片 id，按网格顺序（clientPicks 是 Set）。
    var clientPickIDsInOrder: [String] { items.map(\.id).filter(clientPicks.contains) }
}

/// 离屏快照用（--batch-ui <dir> <out.png> --delivery-ui jpeg|highlights|watermark [--delivery-json '{…}']）：
/// sheet 在离屏窗口里画不出来，按那个出口的默认（盖上 JSON 里的字段）单独画这一段，宽度和面板一样。
struct DeliveryOptionsPreview: View {
    @State var options: DeliveryOptions
    let preview: String
    var showsColor = true
    var tokensHint = DeliveryNaming.tokensHint
    var width: CGFloat = 460
    /// 导出 JPG 面板上面那行「范围」（空 = 不画；精华、水印页没有）。
    var scopes: [JPEGScopeChoice] = []
    @State var scope: JPEGExportScope = .picksUsable
    /// 导出 JPG 面板的「预设」一节（GP-09；nil = 不画，精华、水印页没有）。
    var presets: JPEGPresetStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !scopes.isEmpty { JPEGScopeRow(choices: scopes, selection: $scope) }
            DeliveryOptionsSection(options: $options, namePreview: preview, showsColor: showsColor, tokensHint: tokensHint)
            if let presets {
                JPEGPresetSection(presets: presets, options: $options)
                Text(presets.countLine(scopes.first { $0.scope == scope }?.count ?? 0))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") {}
                    Button("其他文件夹...") {}
                    Button(presets.exportTitle) {}.buttonStyle(.accentProminent)
                }
            }
        }
        .padding(20)
        .frame(width: width, alignment: .topLeading)
    }
}

// MARK: - 导出 JPG / 精华 Top N（无头）

/// LABELGUI_DATA_DIR=<临时目录> LabelGUI --export-jpeg <photo_dir> --dest <dir>
///     [--scope picks|picks+usable|client|top:N] [--ids a,b]（--ids = 面板上「选中的」那档，按给的顺序；client = 客户选中）
///     [--size original|4096|2048|moments|xhs|ig|long:N|short:N|box:WxH]
///     [--sharpen off|std|high] [--color srgb|keep] [--strip-gps|--keep-gps] [--name '<模板>']
///     [--max-mb X] [--quality Q] [--overwrite]
///     [--save-preset 名字]（把上面这套设置存成导出预设就退出，不导）
///     [--sets 名字,名字=尺寸,…]（面板上勾着的几套：存过的预设名，或「名字=尺寸」= 这套设置换个尺寸；每套进 --dest/名字/）
/// 走界面上同一个 exportJPEGs / exportJPEGSets / exportHighlights（top:N 时 --dest 就是「精华」那一层，里面新建 TopN_日期_时间）。
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
        // 存成导出预设（GP-09）：上面这套设置存进数据目录的 delivery/jpeg_presets.json，不导出。
        if let name = option("--save-preset") {
            let presets = JPEGPresetStore(dataDir: appDataDir)
            presets.save(named: name, options: options)
            if let problem = presets.problem { print(problem); exit(1) }
            print("预设「\(name)」已存: \(JPEGPresetStore.summary(options)) → \(presets.path.path)")
            exit(0)
        }
        // 面板上「范围」的后几档（UX-03）：--ids = 选中的这几张（按给的顺序），--scope client = 客户选中（网格顺序）。
        var ids: [String]?
        if let list = option("--ids") {
            ids = list.split(separator: ",").map(String.init)
            print("范围: 选中的 \(ids?.count ?? 0) 张")
        } else if scope == "client" {
            ids = store.clientPickIDsInOrder
            print("范围: 客户选中 \(ids?.count ?? 0) 张")
        }
        let ledgerBefore = store.deliveryRecords.last
        if let list = option("--sets") {
            runSets(list, store: store, dest: dest, base: options, scope: scope, ids: ids, overwrite: args.contains("--overwrite"))
        }
        if let top {
            store.exportHighlights(count: top, into: dest, options: options)
        } else {
            store.exportJPEGs(to: dest, includeUsable: scope != "picks", options: options,
                              overwrite: args.contains("--overwrite"), ids: ids)
        }
        let deadline = Date().addingTimeInterval(600)
        while store.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(store.progressText)
        if let error = store.lastError { print("提醒: " + error) }
        guard let report = store.lastJPEGExport else { exit(1) }
        print("文件夹 \(report.folder.path)")
        print("并发: " + report.concurrency)
        for url in report.written { print("  " + describe(url)) }
        // 界面上做完会在访达里选中它（UX-04）；无头不弹，打出来给脚本断言。
        if let revealed = store.lastJPEGRevealed { print("在访达中显示: \(revealed.path)") }
        // 交付对照：这次写出去的都要记进这一场的 exports.json（没记下就算失败，别把上一次的当成这次的）。
        let records = store.deliveryRecords
        guard let record = records.last, record != ledgerBefore else {
            print("交付对照: 没记下 → \(store.deliveryLedgerPath.path)")
            exit(report.written.isEmpty && report.failed.isEmpty ? 0 : 1)
        }
        print("交付对照 \(store.deliveryLedgerPath.path) · \(record.kind) · 共 \(records.count) 次 · 这次 \(record.files.count) 张")
        for file in record.files { print("  对照 \(file.file) → \(file.id)") }
        // 没写出去的全名单（EC-08：状态栏只列前 3 张）。
        if let failed = record.failed {
            print("交付对照里记的失败 \(failed.count) 张: " + failed.map(\.id).joined(separator: " "))
        }
        exit(report.failed.isEmpty && record.files.count == report.written.count ? 0 : 1)
    }

    /// --sets 名字,名字=尺寸,…（GP-09，面板上勾着的几套）：只写名字 = 数据目录里存的预设（--save-preset 存的）；
    /// 「名字=尺寸」= 上面这套设置换个尺寸。每套进 --dest 下以名字命名的子文件夹。打印每套写出的文件、交付对照每套一条。
    @MainActor
    private static func runSets(_ list: String, store: BatchStore, dest: URL, base: DeliveryOptions, scope: String,
                                ids: [String]?, overwrite: Bool) -> Never {
        let presets = JPEGPresetStore(dataDir: appDataDir)
        var sets: [(name: String, options: DeliveryOptions)] = []
        for item in list.split(separator: ",").map(String.init) {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                var o = base
                o.size = DeliverySize(spec: parts[1]).spec
                o.color = nil
                sets.append((parts[0], o))
            } else if let saved = presets.presets[item] {
                sets.append((item, saved))
            } else {
                print("没有叫「\(item)」的导出预设（先 --save-preset 存，或写成 名字=尺寸）")
                exit(1)
            }
        }
        for set in sets { print("套「\(set.name)」: \(JPEGPresetStore.summary(set.options))") }
        let recordsBefore = store.deliveryRecords.count
        store.exportJPEGSets(to: dest, sets: sets, includeUsable: scope != "picks", overwrite: overwrite, ids: ids)
        let deadline = Date().addingTimeInterval(600)
        while store.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(store.progressText)
        if let error = store.lastError { print("提醒: " + error) }
        guard let report = store.lastJPEGExport else { exit(1) }
        print("文件夹 \(report.folder.path)")
        for (name, part) in store.lastJPEGSets {
            print("套「\(name)」 \(part.folder.lastPathComponent)/ · \(part.written.count) 张 · 失败 \(part.failed.count) · 并发 \(part.concurrency)")
            for url in part.written { print("  " + describe(url)) }
        }
        if let revealed = store.lastJPEGRevealed { print("在访达中显示: \(revealed.path)") }
        let added = Array(store.deliveryRecords.dropFirst(recordsBefore))
        print("交付对照 \(store.deliveryLedgerPath.path) · 这次记了 \(added.count) 条")
        for record in added {
            print("  \(record.kind) \(record.folder) · \(record.files.count) 张")
        }
        let ok = report.failed.isEmpty && added.count == store.lastJPEGSets.filter { !$0.report.written.isEmpty }.count
        exit(ok ? 0 : 1)
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
