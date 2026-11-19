import Foundation
import SwiftUI

// MARK: - 导出 JPG 的具名预设、「一次导出勾选的几套」（优化分析 GP-09）

/// 以前导出 JPG 面板一次只能出一套：给客户原尺寸、自己发小红书和朋友圈要开三遍面板、改三遍尺寸。现在照水印页预设的样子：
/// 把面板上这套设置（尺寸、锐化、色彩、质量、体积上限、去 GPS、文件名）起个名字存下来（名字随便起，同名先问覆不覆盖，
/// 删之前问一句），点名字套用到面板上；每个预设前面一个勾，勾上的几套点一次导出就都导，每套进以预设名命名的子文件夹
/// （导出JPG/小红书/、导出JPG/朋友圈/），交付对照每套记一次。一个都没勾 = 和以前一样按面板上的设置导一套。
///
/// 存在数据目录的 delivery/jpeg_presets.json（和水印页的 watermark/state.json 一样跟着数据目录走，不进 UserDefaults）：
/// `{"presets": {名字: 设置}, "checked": [勾着的名字]}`。设置逐字段宽松解码（DeliveryOptions），以后加字段老文件照样读；
/// 整个文件解不开就挪成 jpeg_presets.json.bak、提示一句，不拿空的盖掉。精华 Top N、水印页不用它（水印页的预设本身带导出设置）。
@MainActor
final class JPEGPresetStore: ObservableObject {
    struct FileState: Codable {
        var presets: [String: DeliveryOptions] = [:]
        var checked: [String] = []

        init(presets: [String: DeliveryOptions], checked: [String]) {
            self.presets = presets
            self.checked = checked
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            presets = (try? c.decodeIfPresent([String: DeliveryOptions].self, forKey: .presets)) ?? nil ?? [:]
            checked = (try? c.decodeIfPresent([String].self, forKey: .checked)) ?? nil ?? []
        }
    }

    @Published private(set) var presets: [String: DeliveryOptions] = [:]
    @Published private(set) var checked: Set<String> = []
    /// 读 / 写不进去时的那一句（面板上显示）。
    @Published private(set) var problem: String?
    let path: URL

    init(dataDir: URL) {
        path = dataDir.appendingPathComponent("delivery", isDirectory: true).appendingPathComponent("jpeg_presets.json")
        load()
    }

    /// 按名字排（导出也按这个顺序一套一套导）。
    var names: [String] { presets.keys.sorted() }
    /// 勾着的（按名字排）。
    var checkedNames: [String] { names.filter(checked.contains) }

    /// 面板上的设置正好是哪个预设（打勾）。
    func activeName(for options: DeliveryOptions) -> String? { names.first { presets[$0] == options } }

    /// 勾着的几套（导出按这个顺序）。
    var checkedSets: [(name: String, options: DeliveryOptions)] {
        checkedNames.compactMap { name in presets[name].map { (name: name, options: $0) } }
    }

    /// 面板底下那一行。没勾 = 以前那句一个字不变；勾了 = 「共 5 张 × 2 套（原尺寸、小红书）· 每套进自己的子文件夹」。
    func countLine(_ count: Int) -> String {
        let folder = ImageLoader.jpegExportSubfolder
        let sets = checkedNames
        guard !sets.isEmpty else {
            return "共 \(count) 张 · 重编码，保留 EXIF · 默认导出到 拍摄文件夹/\(folder)/ (不参与分析)"
        }
        let subs = Self.folderNames(sets).map { $0 + "/" }.joined(separator: "、")
        return "共 \(count) 张 × \(sets.count) 套（\(sets.joined(separator: "、"))）· 每套进自己的子文件夹：\(folder)/ 下的 \(subs)"
    }

    /// 主按钮：没勾 = 「导出到 导出JPG/」；勾了 = 「导出 2 套到 导出JPG/」。
    var exportTitle: String {
        let folder = ImageLoader.jpegExportSubfolder
        let n = checkedNames.count
        return n == 0 ? "导出到 \(folder)/" : "导出 \(n) 套到 \(folder)/"
    }

    func save(named raw: String, options: DeliveryOptions) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        presets[name] = options
        write()
    }

    func delete(named name: String) {
        guard presets.removeValue(forKey: name) != nil else { return }
        checked.remove(name)
        write()
    }

    func setChecked(_ name: String, _ on: Bool) {
        guard presets[name] != nil, checked.contains(name) != on else { return }
        if on { checked.insert(name) } else { checked.remove(name) }
        write()
    }

    /// 「加三套常用的」：原尺寸（给客户，GPS 照面板）、小红书 3:4、朋友圈长边 1080（这两套去 GPS）；锐化、质量、文件名照面板上的。
    /// 已经有同名的不动。
    func addStarters(from base: DeliveryOptions) {
        for (name, size, strip) in Self.starters where presets[name] == nil {
            var o = base
            o.size = size.spec
            o.color = nil
            if strip { o.stripGPS = true }
            presets[name] = o
        }
        write()
    }

    static let starters: [(name: String, size: DeliverySize, stripGPS: Bool)] = [
        ("原尺寸", .original, false),
        ("小红书", .box(1080, 1440), true),
        ("朋友圈", .long(1080), true),
    ]

    /// 每套的子文件夹名：预设名去掉 / : 和控制字符、首尾空白、开头的点（不然是隐藏文件夹），空了叫「预设」，
    /// 太长截到 80 字节；两个预设出来一样（不分大小写，APFS 默认不分）的第二个加 -2。
    nonisolated static func folderNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { raw in
            var name = DeliveryNaming.sanitized(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasPrefix(".") { name.removeFirst() }
            if name.isEmpty { name = "预设" }
            while name.utf8.count > 80 { name.removeLast() }
            var out = name
            var n = 2
            while used.contains(out.lowercased()) {
                out = "\(name)-\(n)"
                n += 1
            }
            used.insert(out.lowercased())
            return out
        }
    }

    /// 预设那一行的小字：尺寸（规格表里的名字），再带上和默认不一样的几样（去 GPS、锐化、质量、体积上限）。
    nonisolated static func summary(_ o: DeliveryOptions) -> String {
        var parts = [WatermarkStore.sizeLabel(o.sizeValue)]
        if o.sizeValue != .original && o.sharpen != .standard { parts.append(o.sharpen.label) }
        parts.append("质量 \(Int((o.quality * 100).rounded()))")
        if o.limitSize { parts.append("≤\(String(format: "%g", o.maxMB)) MB") }
        if o.stripGPS { parts.append("去 GPS") }
        return parts.joined(separator: " · ")
    }

    private func load() {
        guard let data = try? Data(contentsOf: path) else { return }
        guard let state = try? JSONDecoder().decode(FileState.self, from: data) else {
            // 整个文件解不开（不是 JSON / 被截断）：挪到一边，下次存的时候不拿空的盖掉里面的预设。
            let backup = path.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: path, to: backup)
            problem = "导出预设文件解不开，已挪成 \(backup.lastPathComponent)，这次从空的开始"
            return
        }
        presets = state.presets
        checked = Set(state.checked.filter { state.presets[$0] != nil })
    }

    /// 预设是人主动存的：马上写（原子写）。
    private func write() {
        let state = FileState(presets: presets, checked: checkedNames)
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: path, options: .atomic)
            problem = nil
        } catch {
            problem = "导出预设没存上：\(Diagnostics.describeIO(error))"
        }
    }
}

// MARK: - 导出 JPG 面板上的「预设」一节

/// 面板上「预设」那一节：存当前设置、每个预设一行（勾 = 一起导、点名字 = 套用、小字 = 尺寸等、删除）、一个都没有时
/// 「加三套常用的」。每一行拆成自己的小 view（CI 的 Xcode 16 对长 body 类型检查会超时）。
struct JPEGPresetSection: View {
    @ObservedObject var presets: JPEGPresetStore
    @Binding var options: DeliveryOptions
    @State private var newName = ""
    @State private var toDelete: String?
    @State private var toOverwrite: String?

    private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("预设")
                TextField("预设名（原尺寸 / 小红书 / 朋友圈…）", text: $newName)
                    .onSubmit { saveTapped() }
                Button("存当前设置") { saveTapped() }
                    .disabled(trimmed.isEmpty)
                    .help("把上面这套设置（尺寸、锐化、色彩、质量、体积上限、GPS、文件名）存成预设")
            }
            ForEach(presets.names, id: \.self) { name in
                JPEGPresetRow(name: name, presets: presets, options: $options, onDelete: { toDelete = name })
            }
            footer
        }
        .confirmationDialog("删除预设？", isPresented: Binding(
            get: { toDelete != nil },
            set: { if !$0 { toDelete = nil } }
        ), presenting: toDelete) { name in
            Button("删除「\(name)」", role: .destructive) { presets.delete(named: name) }
            Button("取消", role: .cancel) {}
        } message: { name in
            Text("预设「\(name)」删除后无法恢复。")
        }
        .alert("覆盖已有预设？", isPresented: Binding(
            get: { toOverwrite != nil },
            set: { if !$0 { toOverwrite = nil } }
        ), presenting: toOverwrite) { name in
            Button("覆盖", role: .destructive) {
                presets.save(named: name, options: options)
                newName = ""
            }
            Button("取消", role: .cancel) {}
        } message: { name in
            Text("预设「\(name)」已存在，保存会用当前设置替换它。")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let problem = presets.problem {
            Text(problem).font(.caption).foregroundStyle(AppPalette.warning)
        }
        if presets.names.isEmpty {
            HStack(spacing: 6) {
                Button("加三套常用的") { presets.addStarters(from: options) }
                    .controlSize(.small)
                    .help("原尺寸（给客户）、小红书 3:4、朋友圈长边 1080（这两套去 GPS）；锐化、质量、文件名照上面的")
                Text("原尺寸 / 小红书 / 朋友圈").font(.caption).foregroundStyle(AppPalette.secondary)
            }
        }
        Text("勾上的几套点一次导出就都导，每套进以预设名命名的子文件夹；一个都不勾就按上面的设置导一套")
            .hintText()
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveTapped() {
        let name = trimmed
        guard !name.isEmpty else { return }
        if presets.presets[name] != nil {
            toOverwrite = name
        } else {
            presets.save(named: name, options: options)
            newName = ""
        }
    }
}

/// 预设一行：勾（一起导）、打勾（面板上的设置就是它）、名字（点了套用）、小字、删除。
private struct JPEGPresetRow: View {
    let name: String
    @ObservedObject var presets: JPEGPresetStore
    @Binding var options: DeliveryOptions
    let onDelete: () -> Void

    var body: some View {
        let active = presets.activeName(for: options) == name
        let summary = presets.presets[name].map(JPEGPresetStore.summary) ?? ""
        let folder = JPEGPresetStore.folderNames([name]).first ?? name
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { presets.checked.contains(name) }, set: { presets.setChecked(name, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("勾上：点导出时这一套也导，进「\(folder)/」子文件夹")
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundStyle(AppPalette.accent)
                .opacity(active ? 1 : 0)
                .frame(width: 12)
            Button(name) {
                if let preset = presets.presets[name] { options = preset }
            }
            .buttonStyle(.link)
            .help(active ? "上面的设置就是这个预设" : "把这套设置套用到上面")
            Text(summary)
                .font(.caption2)
                .foregroundStyle(AppPalette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button(action: onDelete) { Image(systemName: "trash").font(.caption) }
                .buttonStyle(.plain)
                .help("删除预设")
        }
    }
}
