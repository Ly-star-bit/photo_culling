import SwiftUI

// MARK: - 菜单栏「文件」里的选片命令（优化分析 2026-11-18 UX-08）
//
// 以前菜单栏里一条选片命令都没有：开头（选文件夹、开始分析）和结尾（导出）只能拿鼠标点顶栏，翻菜单栏、「帮助」里的
// 搜索框（它搜的是菜单项）都找不到。复核：只补三条带 ⌘ 的（做法乙，S）——
//   打开文件夹… ⌘O、开始 / 重新分析 ⌘R、导出 JPG… ⇧⌘E（导出菜单里最常用的那一项；写 XMP、精华、高 ISO 照旧在顶栏「导出」里）。
// 放进系统自带的「文件」菜单（CommandGroup(replacing: .newItem)，原来那一组是空的：没有「新建窗口」），不另开一个和
// 「File」并排的菜单。
//
// 同一个键在不同页做对应的事：
//   - ⌘O：批量页 = 打开文件夹；水印页的「导入照片…」按钮自己挂着 ⌘O（WatermarkView），菜单在水印页不出这一项 ——
//     同一个键两处注册，谁先接说不准；拼图、标注校准页灰着（那两页没有「打开」）。
//   - ⌘R、⇧⌘E：只在批量页能用。拼图页 ⌘E 是拼图导出，⇧⌘E 不能落到批量页的导出上。
// 动作发通知给批量页（BatchView 收；和「从存储卡导入…」的 .cardImportRequested 同一个办法）。能不能点由批量页算好同步过来
// （BatchMenuState）：正在审片、挑连拍、看单张、开着导出框 / 确认框 / 选文件夹时都灰着，收到了批量页也再看一遍。
// 菜单是 App 场景建的，无头（--app-ui 等）不经过这里：能点不能点、键和快捷键一览对不对在 --ux-selftest 里核对，
// 菜单真的长什么样、按键真的走到哪，进手点清单。
// 已知没管的：系统恢复出两个主窗口时（没有 ⌘N，只有恢复才会有），两个批量页都会收到通知。

enum BatchMenuCommand: String, CaseIterable, Sendable {
    case openFolder, analyze, exportJPEG
}

extension Notification.Name {
    /// object = BatchMenuCommand 的 rawValue。
    static let batchMenuCommand = Notification.Name("batchMenuCommand")
}

/// 菜单项能不能点、分析那一项叫什么。批量页在这几样变了的时候写进来（onChange），菜单不跟着批量页每次重算。
@MainActor
final class BatchMenuState: ObservableObject {
    static let shared = BatchMenuState()

    struct Flags: Equatable {
        var canOpen = false
        var canAnalyze = false
        var analyzeTitle = "开始分析"
        var canExport = false

        /// 纯函数（--ux-selftest 核对）。和顶栏的按钮同一套条件：文件夹菜单分析中灰着；「开始分析」要有文件夹；
        /// 「导出 JPG…」这一场有照片就能点（和顶栏的按钮一样：没有精选也能在面板里选范围导选中的、客户选中的，UX-03）。busy = 审片 / 挑连拍 / 看单张，或者开着导出框、
        /// 确认框、选文件夹、对时面板 —— 这时候弹选文件夹、开导出框会叠在它们上面。
        static func make(running: Bool, hasFolder: Bool, empty: Bool, busy: Bool) -> Flags {
            let free: Bool = !running && !busy
            return Flags(canOpen: free,
                         canAnalyze: free && hasFolder,
                         analyzeTitle: empty ? "开始分析" : "重新分析",
                         canExport: free && !empty)
        }
    }

    @Published private(set) var flags = Flags()

    func update(_ new: Flags) {
        if flags != new { flags = new }
    }

    /// 菜单项被点（或按了键）：发给批量页。
    static func post(_ command: BatchMenuCommand) {
        NotificationCenter.default.post(name: .batchMenuCommand, object: command.rawValue)
    }

    /// 批量页收到的是哪条（object 不是这几条之一 = nil）。
    static func command(of note: Notification) -> BatchMenuCommand? {
        (note.object as? String).flatMap(BatchMenuCommand.init(rawValue:))
    }
}

/// 三条命令的键：菜单照它挂，快捷键一览（ShortcutsTable.batchOther）照它写，自检核对两边一致、不和各页绑着的键撞。
enum FileMenuTable {
    struct Item {
        let command: BatchMenuCommand
        /// 快捷键一览里那一行的按键（一字不差）。
        let keys: String
        let key: KeyEquivalent
        let modifiers: EventModifiers
    }

    static let items: [Item] = [
        Item(command: .openFolder, keys: "⌘O", key: "o", modifiers: .command),
        Item(command: .analyze, keys: "⌘R", key: "r", modifiers: .command),
        Item(command: .exportJPEG, keys: "⇧⌘E", key: "e", modifiers: [.command, .shift]),
    ]

    static func item(_ command: BatchMenuCommand) -> Item {
        items.first { $0.command == command } ?? items[0]
    }

    /// 这一项在哪一页出现在菜单里：⌘O 在水印页不出（水印页按钮自己挂着 ⌘O）。
    static func shows(_ command: BatchMenuCommand, on tab: AppTab) -> Bool {
        !(command == .openFolder && tab == .watermark)
    }

    /// 这一项现在能不能点：只在批量页、并且批量页说能点。
    static func enabled(_ command: BatchMenuCommand, on tab: AppTab, flags: BatchMenuState.Flags, appModal: Bool) -> Bool {
        guard tab == .batch, !appModal else { return false }
        switch command {
        case .openFolder: return flags.canOpen
        case .analyze: return flags.canAnalyze
        case .exportJPEG: return flags.canExport
        }
    }
}

/// 「文件」菜单里那三项（LabelGUIApp 的 CommandGroup(replacing: .newItem) 里挂）。
struct FileMenuItems: View {
    @ObservedObject var model: AppModel
    /// 插卡的导入框开着（ContentView 上的 sheet）：这时候不弹选文件夹、不开导出框。
    @ObservedObject var cardCenter: CardImportCenter
    @ObservedObject var state: BatchMenuState = .shared

    var body: some View {
        let tab = model.tab
        let appModal: Bool = model.whatsNewShown || cardCenter.offer != nil
        if FileMenuTable.shows(.openFolder, on: tab) {
            item(.openFolder, "打开文件夹…", tab: tab, appModal: appModal)
            Divider()
        }
        item(.analyze, state.flags.analyzeTitle, tab: tab, appModal: appModal)
        Divider()
        item(.exportJPEG, "导出 JPG…", tab: tab, appModal: appModal)
    }

    private func item(_ command: BatchMenuCommand, _ title: String, tab: AppTab, appModal: Bool) -> some View {
        let spec = FileMenuTable.item(command)
        return Button(title) { BatchMenuState.post(command) }
            .keyboardShortcut(spec.key, modifiers: spec.modifiers)
            .disabled(!FileMenuTable.enabled(command, on: tab, flags: state.flags, appModal: appModal))
    }
}

/// 批量页那一头：能不能点同步给菜单、收菜单发来的命令。单独一个只按 flags 比的视图（批量页那边 `.equatable()`）：
/// 批量页每重算一次（方向键一下就是一次）不跟着重比、重订通知 —— 直接挂在批量页上时 release 量出来方向键每下多约
/// 0.5 百万条指令。run 是建它那一刻的批量页的方法：点下去时（不在 body 里）读的 @State、store 都是现在的。
struct BatchMenuBridge: View, Equatable {
    let flags: BatchMenuState.Flags
    let run: (BatchMenuCommand) -> Void

    static func == (a: BatchMenuBridge, b: BatchMenuBridge) -> Bool { a.flags == b.flags }

    var body: some View {
        Color.clear
            .onChange(of: flags, initial: true) { BatchMenuState.shared.update(flags) }
            .onReceive(NotificationCenter.default.publisher(for: .batchMenuCommand)) { note in
                if let command = BatchMenuState.command(of: note) { run(command) }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - 自检

/// --ux-selftest 的「文件」菜单部分（菜单本身无头看不到）：能不能点的判断表、各页出不出、键和快捷键一览一致、不和别处的键撞。
@MainActor
enum FileMenuSelfTest {
    static func run() -> Int {
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if !ok { failed += 1 }
            let tail: String = ok || detail.isEmpty ? "" : "（\(detail)）"
            print((ok ? "PASS " : "FAIL ") + "文件菜单：" + name + tail)
        }
        typealias F = BatchMenuState.Flags

        // 1. 能不能点
        let idle: F = F.make(running: false, hasFolder: true, empty: false, busy: false)
        check(idle.canOpen && idle.canAnalyze && idle.canExport && idle.analyzeTitle == "重新分析", "闲着、分析过：三项都能点，写「重新分析」")
        let first: F = F.make(running: false, hasFolder: false, empty: true, busy: false)
        check(first.canOpen && !first.canAnalyze && !first.canExport && first.analyzeTitle == "开始分析",
              "第一次打开（没文件夹）：只能打开文件夹，「开始分析」灰着")
        let picked: F = F.make(running: false, hasFolder: true, empty: true, busy: false)
        check(picked.canAnalyze && picked.analyzeTitle == "开始分析", "选了文件夹还没分析：「开始分析」能点")
        let running: F = F.make(running: true, hasFolder: true, empty: false, busy: false)
        check(!running.canOpen && !running.canAnalyze && !running.canExport, "分析中：三项都灰（⌘R 不会变成取消）")
        let busy: F = F.make(running: false, hasFolder: true, empty: false, busy: true)
        check(!busy.canOpen && !busy.canAnalyze && !busy.canExport, "审片 / 挑连拍 / 看单张 / 开着框：三项都灰")
        check(!picked.canExport, "选了文件夹还没分析（一张照片都没有）：导出 JPG 灰着")

        // 2. 各页
        for tab in [AppTab.watermark, .collage, .labeling] {
            let any = BatchMenuCommand.allCases.contains { FileMenuTable.enabled($0, on: tab, flags: idle, appModal: false) }
            check(!any, "\(tab) 页：三项都灰（⇧⌘E 不会落到批量导出上）")
        }
        check(!FileMenuTable.shows(.openFolder, on: .watermark), "水印页不出「打开文件夹…」（⌘O 留给水印页的「导入照片…」）")
        check(FileMenuTable.shows(.openFolder, on: .batch) && FileMenuTable.shows(.openFolder, on: .collage),
              "批量页、拼图页出「打开文件夹…」")
        check(BatchMenuCommand.allCases.allSatisfy { FileMenuTable.enabled($0, on: .batch, flags: idle, appModal: false) },
              "批量页闲着：三项都能点")
        check(!BatchMenuCommand.allCases.contains { FileMenuTable.enabled($0, on: .batch, flags: idle, appModal: true) },
              "插卡的导入框 / 这一版新增开着：三项都灰")

        // 3. 通知来回
        for command in BatchMenuCommand.allCases {
            let note = Notification(name: .batchMenuCommand, object: command.rawValue)
            check(BatchMenuState.command(of: note) == command, "通知认得出 \(command.rawValue)")
        }
        check(BatchMenuState.command(of: Notification(name: .batchMenuCommand, object: "x")) == nil, "认不出的通知不动")

        // 4. 键：每条命令一个、互不相同；快捷键一览「批量处理」页列着；不和代码里各页绑着的 ⌘ 键撞
        //    （批量 ⌘Z ⌘A ⌥⌘S ⌘⏎，拼图 ⌘E ⇧⌘S ⌃⌘S ⌥⌘S ⌘= ⌘- ⌘0 ⌘1 ⌘Z ⇧⌘Z ⌘← ⌘→，水印 ⌘⏎；水印的 ⌘O 见上面）。
        let keys: [String] = FileMenuTable.items.map(\.keys)
        check(Set(FileMenuTable.items.map(\.command)) == Set(BatchMenuCommand.allCases) && Set(keys).count == keys.count,
              "每条命令一个键、互不相同", keys.joined(separator: " "))
        let columns = ShortcutsTable.columns(.batch)
        let listed = Set((columns.left + columns.right).flatMap(\.rows).map(\.keys))
        let missing: [String] = keys.filter { !listed.contains($0) }
        check(missing.isEmpty, "快捷键一览「批量处理」页列了 \(keys.joined(separator: "、"))", "缺 \(missing.joined(separator: "、"))")
        let taken: Set<String> = ["⌘Z", "⌘A", "⌥⌘S", "⌘⏎", "⌘E", "⇧⌘S", "⌃⌘S", "⌘=", "⌘-", "⌘0", "⌘1", "⇧⌘Z", "⌘←", "⌘→"]
        let clash: [String] = keys.filter { taken.contains($0) }
        check(clash.isEmpty, "不和各页绑着的 ⌘ 键撞", clash.joined(separator: " "))
        return failed
    }
}
