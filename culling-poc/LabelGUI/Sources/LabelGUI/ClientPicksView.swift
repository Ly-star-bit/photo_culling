import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 「导入客户选择…」对话框

/// 粘贴客户的回复（或者打开 .txt / .csv），边打字边预览认出几张、哪些没认出，确认后标成「客户选中」。
/// 导入是加上去，不清掉原来的（客户常常分几次回）；要重来先「清除客户选中」。都能 ⌘Z。
struct ClientImportSheet: View {
    @ObservedObject var store: BatchStore
    @Binding var isPresented: Bool
    @State private var text: String

    init(store: BatchStore, isPresented: Binding<Bool>, text: String = "") {
        self.store = store
        _isPresented = isPresented
        _text = State(initialValue: text)
    }

    static let intro = "粘贴客户发回来的：确认表里「复制我的选择」的那段、微信里回的文件名或编号（12、35、78 · 12-15 · 7221），" +
        "或者 Pixieset 等导出的 .csv、Lightroom 文件名清单。认出来的标成「客户选中」（紫心、XMP 紫色标），不改判决。"

    var body: some View {
        let resolution = store.resolveClientReply(text)
        let lines = ClientReply.summary(resolution, existing: store.clientPicks)
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            Text("导入客户选择").font(.headline)
            Text(Self.intro).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            HStack {
                Button("打开 .txt / .csv 文件...") { openFile() }
                Spacer()
                if store.clientPickCount > 0 {
                    Button("清除客户选中 (\(store.clientPickCount))") { store.clearClientPicks() }
                        .help("把这一场的客户选中全部清掉再导（⌘Z 能撤回）")
                }
            }
            if !empty {
                preview(lines, hasUnknown: !resolution.unknown.isEmpty)
            }
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("标记为客户选中 (\(resolution.ids.count))") {
                    store.importClientPicks(resolution.ids)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolution.ids.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func preview(_ lines: [String], hasUnknown: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .callout.bold() : .caption)
                    .foregroundStyle(index == 0 && hasUnknown ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let content = ClientReply.decode(data) else {
            store.lastError = "读不了 \(url.lastPathComponent)"
            return
        }
        text = content
    }
}

extension ClientReply {
    /// 文本文件：先当 UTF-8；不是的话多半是中文 Windows / Excel 存的 GBK（GB18030 兼容它）。
    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb))
    }
}

// MARK: - 无头测试入口（只给测试 / 自动化用，不开界面）
//
// LABELGUI_DATA_DIR=<临时> LabelGUI --proof-sheet <照片文件夹> --out <x.html> [--scope picks|picks+usable] [--ids a,b]
// LABELGUI_DATA_DIR=<临时> LabelGUI --client-import <照片文件夹> (--text <回复.txt> | --clear) [--apply] [--undo]
// LABELGUI_DATA_DIR=<临时> LabelGUI --copy-list <照片文件夹> --format lr|c1|lines [--scope all|picks|usable|client] [--ids a,b]
// LABELGUI_DATA_DIR=<临时> LabelGUI --copy-originals <照片文件夹> --dest <目录> [--scope ...] [--ids a,b]
// 都会读写这一场的会话目录（确认表记录、客户选中、复制目标），所以必须给临时数据目录。
enum ClientPicksCLI {
    static let flags = ["--proof-sheet", "--client-import", "--copy-list", "--copy-originals"]

    @MainActor
    static func run(flag: String, flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        guard !(ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? "").isEmpty else {
            print("\(flag) 会改这一场的会话文件：先设 LABELGUI_DATA_DIR=<临时目录>")
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        guard !store.items.isEmpty else {
            print("这一场没有分析结果（先 --analyze）：\(dir.path)")
            exit(1)
        }
        switch flag {
        case "--proof-sheet": proofSheet(store)
        case "--client-import": clientImport(store)
        case "--copy-list": copyList(store)
        default: copyOriginals(store)
        }
    }

    private static func option(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
        return args[i + 1]
    }

    /// --ids 给了就是「选中的这几张」；否则按 --scope 设筛选（和界面上的筛选一样），取「当前筛选」。
    @MainActor
    private static func scopeIDs(_ store: BatchStore) -> [String] {
        if let ids = option("--ids") { return ids.split(separator: ",").map(String.init) }
        switch option("--scope") ?? "all" {
        case "client": store.clientPickFilter = true
        case "picks": store.verdictFilter = .pick
        case "usable": store.verdictFilter = .usable
        default: break
        }
        return store.filteredItems().map(\.id)
    }

    @MainActor
    private static func waitAndReport(_ store: BatchStore) {
        let deadline = Date().addingTimeInterval(300)
        while store.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(store.progressText)
        if let error = store.lastError { print("提醒: " + error) }
    }

    @MainActor
    private static func proofSheet(_ store: BatchStore) -> Never {
        guard let out = option("--out") else { print("--proof-sheet 要 --out <x.html>"); exit(1) }
        let ids = option("--ids").map { $0.split(separator: ",").map(String.init) }
        let previous = store.proofSheets.last?.id
        store.exportContactSheet(to: URL(fileURLWithPath: out), includeUsable: option("--scope") == "picks+usable", ids: ids)
        waitAndReport(store)
        // 这次没记下新的一张（导出失败、取消）就算失败，别把上一张当成这次的。
        guard let sheet = store.proofSheets.last, sheet.id != previous else { exit(1) }
        print("表号 \(sheet.id) · \(sheet.scope) · \(sheet.ids.count) 张: " + sheet.ids.joined(separator: " "))
        exit(0)
    }

    @MainActor
    private static func printPicks(_ store: BatchStore, _ label: String) {
        let picks = store.items.map(\.id).filter(store.clientPicks.contains)
        print("\(label): 客户选中 \(store.clientPickCount) 张 · XMP 过期 \(store.xmpStaleCount) 张 · 能撤销 \(store.canUndoOverride ? "是" : "否")")
        print("  客户选中: " + (picks.isEmpty ? "-" : picks.joined(separator: " ")))
    }

    @MainActor
    private static func clientImport(_ store: BatchStore) -> Never {
        let args = CommandLine.arguments
        printPicks(store, "导入前")
        if args.contains("--clear") {
            if args.contains("--apply") { store.clearClientPicks() }
        } else {
            guard let path = option("--text"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let text = ClientReply.decode(data) else {
                print("--client-import 要 --text <文件>（或 --clear）")
                exit(1)
            }
            let r = store.resolveClientReply(text)
            for line in ClientReply.summary(r, existing: store.clientPicks) { print("预览: " + line) }
            print("认出: " + (r.ids.isEmpty ? "-" : r.ids.joined(separator: " ")))
            print("没认出: " + (r.unknown.isEmpty ? "-" : r.unknown.joined(separator: " | ")))
            print("编号表: " + (r.sheet?.id ?? "-") + (r.usedSheet ? "（用到了）" : ""))
            if args.contains("--apply") { store.importClientPicks(r.ids) }
        }
        if args.contains("--apply") {
            printPicks(store, "导入后")
            print(store.progressText)
        }
        if args.contains("--undo") {
            let touched = store.undoLastOverride()
            printPicks(store, "撤销后")
            print("  撤销动到: \(touched.count) 张")
        }
        let counts = store.verdictCounts
        print("判决: 精选 \(counts.pick) · 可用 \(counts.usable) · 废片 \(counts.reject) · overrides \(store.overrides.count)")
        // 「废片移到废纸篓」菜单和确认框上的张数（客户选中的废片不移）。
        let kept = store.clientPickRejectCount
        print("废片移到废纸篓: \(store.trashableRejectCount) 张" + (kept > 0 ? "（客户选中的 \(kept) 张废片不动）" : ""))
        print("  要移的: " + (store.trashableRejects.isEmpty ? "-" : store.trashableRejects.map(\.id).joined(separator: " ")))
        exit(0)
    }

    @MainActor
    private static func copyList(_ store: BatchStore) -> Never {
        guard let format = option("--format").flatMap(FilenameList.Format.init(rawValue:)) else {
            print("--copy-list 要 --format lr|c1|lines")
            exit(1)
        }
        let wanted = Set(scopeIDs(store))
        let chosen = store.items.filter { wanted.contains($0.id) }
        let list = FilenameList.make(chosen, format: format)
        // 清单原样打到 stdout（界面上是放进剪贴板），说明打到 stderr。
        FileHandle.standardOutput.write(Data(list.text.utf8))
        var note = "\(list.count) 个文件名（\(format.title)）"
        if let caveat = FilenameList.caveat(chosen, all: store.items, format: format) { note += "；" + caveat }
        FileHandle.standardError.write(Data((note + "\n").utf8))
        exit(0)
    }

    @MainActor
    private static func copyOriginals(_ store: BatchStore) -> Never {
        guard let dest = option("--dest") else { print("--copy-originals 要 --dest <目录>"); exit(1) }
        let ids = scopeIDs(store)
        print("复制 \(ids.count) 张: " + ids.joined(separator: " "))
        store.copyOriginals(ids, to: URL(fileURLWithPath: dest))
        waitAndReport(store)
        exit(store.lastError == nil ? 0 : 1)
    }
}
