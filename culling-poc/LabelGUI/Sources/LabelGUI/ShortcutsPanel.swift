import SwiftUI
import AppKit

// MARK: - 快捷键一览

/// 快捷键一览按页分（Lightroom 的 ⌘/ 也是只列当前模块的）：批量处理、水印、拼图、暗房。
/// 批量页（网格 / 审片 / 连拍挑选）、拼图页、水印页、暗房的状态栏 / 顶栏键盘按钮和 ? 键弹的都是它，翻到所在的那一页；
/// 「帮助 › 快捷键一览」开的窗口也是它，翻到主窗口现在在的那一页。
enum ShortcutsPage: String, CaseIterable, Identifiable, Sendable {
    case batch = "批量处理"
    case watermark = "水印"
    case collage = "拼图"
    case darkroom = "暗房"

    var id: String { rawValue }

    /// 主窗口现在在哪一页（标注校准没有自己的快捷键，给批量处理那页）。
    @MainActor
    static func current(_ model: AppModel) -> ShortcutsPage {
        switch model.tab {
        case .batch, .labeling: return .batch
        case .watermark: return .watermark
        case .collage: return model.collage.darkroom != nil ? .darkroom : .collage
        }
    }
}

/// 一节：标题 + 若干行（按键、做什么）。按键照代码里实际绑的写（拼图的在 CollageView / CollageCanvas / 托盘，
/// 暗房的在 CollageDarkroomView，水印的在 WatermarkView），改了键记得改这里。
struct ShortcutsSection: Sendable {
    struct Row: Sendable {
        let keys: String
        let action: String
        init(_ keys: String, _ action: String) {
            self.keys = keys
            self.action = action
        }
    }

    let title: String
    let rows: [Row]
    init(_ title: String, _ rows: [Row]) {
        self.title = title
        self.rows = rows
    }
}

/// 每页两列（并排四列比 1280 的窗口还宽，从状态栏弹出来会出界）。一节一个 static let：
/// 一整张大字面量在 CI 的 Swift 6.1.2 上类型检查会超时。
enum ShortcutsTable {
    typealias Row = ShortcutsSection.Row

    static func columns(_ page: ShortcutsPage) -> (left: [ShortcutsSection], right: [ShortcutsSection]) {
        switch page {
        case .batch: return ([grid, timeline, batchOther], [pick, review, detail])
        case .watermark: return ([watermarkPhotos], [watermarkExport, other])
        case .collage: return ([collageTopBar, canvas, layers], [crop, tray, strips, other])
        case .darkroom: return ([darkroomLooks, darkroomViewing], [darkroomAdjust, darkroomOther])
        }
    }

    // MARK: 批量处理

    static let grid = ShortcutsSection("网格", [
        Row("点击", "选中这张（数字键改的就是它）"),
        Row("双击 / 空格 / ⏎", "打开大图"),
        Row("← → ↑ ↓", "移动"),
        Row("[  ]", "上一章 / 下一章"),
        Row("1  2  3  0", "精选 · 可用 · 废片 · 恢复自动（选了多张就作用于选中的，改完取消选择）"),
        Row("⌘点  ⇧点  ⌘A", "多选 · 连选 · 全选"),
        Row("⌘⏎", "保留选中，同场其余废片（选了连拍里的照片时）"),
        Row("C  D  F", "连拍挑选 · 跳到下一个待处理的场（切到按分组）· 审片"),
        Row("-  =", "缩略图小一号 / 大一号"),
        Row("⌥⌘S", "收起 / 显示右侧筛选面板"),
        Row("⌘Z  Esc", "撤销 · 取消选择"),
    ])
    static let pick = ShortcutsSection("连拍挑选", [
        Row("点照片", "只留这张（同一场其余废）"),
        Row("右上角 精选/可用/废", "只改这一张"),
        Row("⌘点  ⇧空格", "多留 / 取消"),
        Row("1–9  空格", "只留第几张（开了「选完直接下一组」就顺便确认）· 只留高亮那张"),
        Row("0", "恢复推荐"),
        Row("← →  ↑ ↓", "移动高亮 · 上一组 / 下一组"),
        Row("⏎", "确认并下一组"),
        Row("Z  [ ]  P", "放大到脸 · 放大时换人 · 对焦高亮"),
        Row("⌘Z  Esc", "撤销 · 先退出放大，再返回（网格；从审片来的回审片）"),
    ])
    static let review = ShortcutsSection("审片", [
        Row("1  2  3", "精选 · 可用 · 废片（判完自动下一张）"),
        Row("0", "恢复自动"),
        Row("← →", "上一张 / 下一张"),
        Row("Z  P", "放大 · 对焦高亮"),
        Row("C", "这张是连拍：去挑这一场（⏎ 定完自动回到审片）"),
        Row("⌘Z  Esc", "撤销 · 先退出放大，再退出审片"),
    ])
    static let detail = ShortcutsSection("大图（双击打开）", [
        Row("← →", "上一张 / 下一张"),
        Row("1  2  3  0", "精选 · 可用 · 废片 · 恢复自动"),
        Row("C  P", "挑选本场 · 对焦高亮（放大时）"),
        Row("⌘Z  Esc", "撤销 · 关闭"),
    ])
    static let timeline = ShortcutsSection("时间轴", [
        Row("点一段", "跳到这一章"),
        Row("右键", "只看这一章（已经在看这一章：显示全部章节）"),
        Row("⇧Esc", "显示全部章节"),
    ])
    static let batchOther = ShortcutsSection("其他", [
        Row("拖文件夹进窗口", "打开这场拍摄（拖照片 = 打开它所在的文件夹）"),
        Row("插相机存储卡", "问要不要导入到「图片 › 今天日期」，导完直接分析"),
        Row("?", "这张表"),
    ])

    // MARK: 水印

    static let watermarkPhotos = ShortcutsSection("照片列表", [
        Row("⌘O", "导入照片或文件夹"),
        Row("拖进左边列表", "照片、文件夹按拖进来的顺序导入"),
        Row("点一张", "选中，中间预览这张"),
        Row("⌫", "从列表移除选中的那张（先点一下列表）"),
    ])
    static let watermarkExport = ShortcutsSection("导出和预设", [
        Row("⌘⏎", "批量导出列表里的全部照片"),
        Row("Esc", "正在导出时：停下（已写出的保留）"),
        Row("预设名里 ⏎", "存成预设（同名的先问要不要覆盖）"),
    ])

    // MARK: 拼图

    static let collageTopBar = ShortcutsSection("顶栏", [
        Row("⌘Z  ⇧⌘Z", "撤销 · 重做"),
        Row("⇧⌘S", "存成方案（底下方案栏里点一下切回来）"),
        Row("⌘E", "导出（按导出设置写到输出目录）"),
        Row("Esc", "正在导出时：停止导出"),
    ])
    static let canvas = ShortcutsSection("画布（按键先点一下画布）", [
        Row("点", "选中格子、照片上的字、贴纸（右栏切到「格式」）· 点画布外面取消"),
        Row("双击", "照片格：调裁切 · 文字格、手写字：改字 · 照片上的字：去「照片上的字」"),
        Row("⌥点缝", "这条缝横竖翻转"),
        Row("拖缝", "调两边格子的大小"),
        Row("拖格子", "拖到另一格中间：互换 · 拖到边上：劈开插进去"),
        Row("← →", "上一个 / 下一个备选（还没有备选时 → 出一批）"),
        Row("⌫", "删掉选中的格子（其余自动补位）、贴纸或手写字"),
        Row("Esc", "取消选中（先贴纸，再裁切，再格子）"),
    ])
    static let layers = ShortcutsSection("贴纸、散落的照片、手写字（选中以后）", [
        Row("拖", "挪位置 · 拖上方圆点旋转 · 拖右下圆点缩放"),
        Row("← → ↑ ↓", "微调位置"),
        Row("[  ]", "转 2°"),
    ])
    static let crop = ShortcutsSection("调裁切（双击照片格）", [
        Row("拖  捏合", "平移 · 缩放"),
        Row("+  -", "放大 / 缩小"),
        Row("← → ↑ ↓", "微调"),
        Row("Esc  ⏎", "完成裁切"),
    ])
    static let tray = ShortcutsSection("托盘（左栏「照片」；按键先点一下托盘）", [
        Row("点  ⌘点  ⇧点", "选中 · 加减 · 连选"),
        Row("⌘A  Esc", "全选（按现在的筛选）· 取消选择"),
        Row("⌫", "从托盘移除选中的（用到的格子留空，⌘Z 撤回）"),
        Row("拖进画布", "放进格子：中间替换、边上插入（散落版是放一张照片）"),
        Row("右键", "用选中的几张重新排一版 · 加进当前版 · 移除"),
        Row("拖文件进左栏", "照片、文件夹加进托盘"),
    ])
    static let strips = ShortcutsSection("底下几条", [
        Row("点方案", "切到这个方案（⌘Z 回来）· 右键覆盖、改名、删除"),
        Row("点页", "换到这一页 · 右键往前 / 往后挪、删除"),
        Row("点备选", "用这个备选 · 右键去掉、清空"),
    ])

    // MARK: 暗房

    static let darkroomLooks = ShortcutsSection("换色调", [
        Row("← →", "换一款（只在大预览里看，不套用）"),
        Row("↑ ↓", "上一行 / 下一行"),
        Row("悬停样张", "在大预览里看"),
        Row("⏎  点样张", "套用（套到「套用到」选的整组 / 这一页 / 这一格）"),
    ])
    static let darkroomViewing = ShortcutsSection("看", [
        Row("按住空格", "看原图，松开回来（顶栏「原图」按住也行）"),
        Row("拖竖线", "对比：左边原图、右边成片"),
        Row("点大预览", "换 1:1 细节的位置"),
    ])
    static let darkroomAdjust = ShortcutsSection("调", [
        Row("点试条", "强度设到那一格（0 / 25 / 50 / 75 / 100%）"),
        Row("拖滑杆", "强度、颗粒、晕光……拖一次是一步撤销"),
        Row("点底下小样", "只改这一格"),
    ])
    static let darkroomOther = ShortcutsSection("其他", [
        Row("⌘←  ⌘→", "上一 / 下一跨页（有好几页时）"),
        Row("⌘Z  ⇧⌘Z", "撤销 · 重做"),
        Row("Esc", "完成，回到拼图"),
        Row("?", "这张表"),
    ])

    static let other = ShortcutsSection("其他", [
        Row("?", "这张表"),
    ])
}

/// 快捷键一览：顶上按页切，底下两列。高度跟着这一页走（水印、暗房那页短：不按最高的批量处理页留一大块空白）。
struct ShortcutsPanel: View {
    @State private var page: ShortcutsPage

    init(page: ShortcutsPage = .batch) {
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("页", selection: $page) {
                ForEach(ShortcutsPage.allCases) { p in Text(p.rawValue).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ShortcutsPageView(page: page)
        }
        .padding(16)
    }
}

/// 一页：两列。
private struct ShortcutsPageView: View {
    let page: ShortcutsPage

    var body: some View {
        let columns = ShortcutsTable.columns(page)
        HStack(alignment: .top, spacing: 24) {
            ShortcutsColumn(sections: columns.left)
            ShortcutsColumn(sections: columns.right)
        }
    }
}

private struct ShortcutsColumn: View {
    let sections: [ShortcutsSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title).font(.headline)
                    ForEach(section.rows, id: \.keys) { row in
                        ShortcutsRow(row: row)
                    }
                }
            }
        }
        .frame(width: 330, alignment: .leading)
    }
}

private struct ShortcutsRow: View {
    let row: ShortcutsSection.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.keys).font(.caption.monospaced().bold())
                .frame(width: 128, alignment: .leading)
            Text(row.action).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - ? 键

/// 拼图页、水印页的 ? 键。批量页（网格 / 审片 / 连拍挑选）和暗房的键盘焦点一直在页面上，用 onKeyPress 接；这两页的焦点
/// 散在画布、托盘、列表、输入框里，刚切过来谁都没点过时谁也不接键盘，所以用一个只看本窗口的按键监听：
/// 本页在窗口里、按的是 ?（不带 ⌘ ⌃ ⌥）、焦点不在输入框里 → 开 / 关快捷键一览，这一下不再往下传；
/// 正在输入框里打字（标题、预设名、水印文字……）时原样放过，? 照样打进去。
enum ShortcutsKey {
    /// 判断表（--ux-selftest 核对）：typing = 第一响应者是能打字的文本框（输入框的字段编辑器、可编辑的文本视图）。
    static func opens(characters: String?, modifiers: NSEvent.ModifierFlags, typing: Bool) -> Bool {
        guard !typing, characters == "?" else { return false }
        return modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// 焦点在不在能打字的地方（和实时桥判断「用户在打字」同一个条件，见 LiveInteraction.appKitReasons）。
    static func isTyping(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSTextView else { return false }
        return text.isFieldEditor || text.isEditable
    }
}

extension View {
    /// 本页在窗口里时按 ? 开关 `isPresented`（见 ShortcutsKey）。
    func shortcutsHotkey(isPresented: Binding<Bool>) -> some View {
        modifier(ShortcutsHotkeyModifier(isPresented: isPresented))
    }
}

private struct ShortcutsHotkeyModifier: ViewModifier {
    @Binding var isPresented: Bool
    @State private var monitor = ShortcutsKeyMonitor()

    func body(content: Content) -> some View {
        content
            .background(ShortcutsKeyAnchor(monitor: monitor))
            .onAppear { monitor.start { isPresented.toggle() } }
            .onDisappear { monitor.stop() }
    }
}

/// 按键监听本身。只认挂着它的那个视图所在的窗口：视图不在窗口里（切到别的页签、暗房盖住了拼图页）、
/// 按键落在别的窗口（快捷键一览窗口、弹框）都不接 —— onDisappear 漏了也不会在别的页上抢 ?。
@MainActor
private final class ShortcutsKeyMonitor {
    weak var view: NSView?
    private var token: Any?
    private var action: (@MainActor () -> Void)?

    func start(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let characters = event.characters
            let modifiers = event.modifierFlags
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                self?.handle(characters: characters, modifiers: modifiers, windowNumber: windowNumber) ?? false
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private func handle(characters: String?, modifiers: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
        guard let view, let window = view.window, window.windowNumber == windowNumber,
              !view.isHiddenOrHasHiddenAncestor,
              ShortcutsKey.opens(characters: characters, modifiers: modifiers,
                                 typing: ShortcutsKey.isTyping(window.firstResponder)) else { return false }
        action?()
        return true
    }
}

/// 一个看不见的 NSView，让监听知道本页在不在窗口里、在哪个窗口。铺在整页底下：点击一律穿过去（hitTest 给 nil），
/// 不跟画布、托盘、列表抢鼠标。
private struct ShortcutsKeyAnchor: NSViewRepresentable {
    let monitor: ShortcutsKeyMonitor

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        monitor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        monitor.view = nsView
    }
}

// MARK: - 自检

/// --ux-selftest 的快捷键一览部分：纯函数和数据表，不开界面。
///   1. ? 键的判断表：? / ⇧? 接；正在输入框里打字、带 ⌘ ⌃ ⌥、别的字不接；能打字的文本框才算「在打字」。
///   2. 每页都有、每节有行、按键和说明不空；同一页节名不重、同一节按键不重（ForEach 拿它们当 id）；每页都有 ? 这一行。
///   3. 拼图、暗房、水印页列了代码里实际绑着的那几个键（改键忘了改表就红）。
/// 返回没过的条数。
@MainActor
enum ShortcutsSelfTest {
    static func run() -> Int {
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if !ok { failed += 1 }
            let tail = ok ? "" : "（\(detail())）"
            print((ok ? "PASS " : "FAIL ") + "快捷键一览：" + name + tail)
        }

        // 1. ? 键
        let cases: [(String, String?, NSEvent.ModifierFlags, Bool, Bool)] = [
            ("? 开", "?", [], false, true),
            ("⇧? 开（? 本来就要按 ⇧）", "?", [.shift], false, true),
            ("在输入框里打字：? 照样打进去", "?", [.shift], true, false),
            ("⌘? 不接（留给菜单）", "?", [.command, .shift], false, false),
            ("⌥? 不接", "?", [.option], false, false),
            ("⌃? 不接", "?", [.control], false, false),
            ("/ 不接", "/", [], false, false),
            ("没有字符不接", nil, [], false, false),
        ]
        for (name, chars, mods, typing, expected) in cases {
            let got = ShortcutsKey.opens(characters: chars, modifiers: mods, typing: typing)
            check(got == expected, name, "期望 \(expected)，实际 \(got)")
        }
        let editable = NSTextView()
        let label = NSTextView()
        label.isEditable = false
        check(ShortcutsKey.isTyping(editable), "可编辑的文本视图算在打字")
        check(!ShortcutsKey.isTyping(label) && !ShortcutsKey.isTyping(NSView()) && !ShortcutsKey.isTyping(nil),
              "只读文本、普通视图、没有焦点不算在打字")

        // 2. 表的形状
        for page in ShortcutsPage.allCases {
            let columns = ShortcutsTable.columns(page)
            let sections = columns.left + columns.right
            let rows = sections.flatMap(\.rows)
            let titles = sections.map(\.title)
            let dupKeys = sections.filter { Set($0.rows.map(\.keys)).count != $0.rows.count }.map(\.title)
            check(!columns.left.isEmpty && !columns.right.isEmpty && sections.allSatisfy { !$0.rows.isEmpty },
                  "\(page.rawValue)：两列都有、每节都有行")
            check(rows.allSatisfy { !$0.keys.isEmpty && !$0.action.isEmpty }, "\(page.rawValue)：按键、说明都不空")
            check(Set(titles).count == titles.count && dupKeys.isEmpty, "\(page.rawValue)：节名不重、同一节按键不重",
                  "节 \(titles.joined(separator: " "))；按键重了的节 \(dupKeys.joined(separator: " "))")
            check(rows.contains { $0.keys == "?" }, "\(page.rawValue)：有 ? 这一行")
        }

        // 3. 代码里绑着的键都列了
        let expected: [(ShortcutsPage, [String])] = [
            (.collage, ["⌘Z  ⇧⌘Z", "⇧⌘S", "⌘E", "⌥点缝", "双击", "[  ]", "+  -", "⌘A  Esc", "⌫"]),
            (.darkroom, ["← →", "↑ ↓", "⏎  点样张", "按住空格", "拖竖线", "⌘←  ⌘→", "⌘Z  ⇧⌘Z", "Esc"]),
            (.watermark, ["⌘O", "⌘⏎", "Esc", "⌫"]),
            (.batch, ["C  D  F", "⌥⌘S", "⇧Esc"]),
        ]
        for (page, keys) in expected {
            let columns = ShortcutsTable.columns(page)
            let listed = Set((columns.left + columns.right).flatMap(\.rows).map(\.keys))
            let missing = keys.filter { !listed.contains($0) }
            check(missing.isEmpty, "\(page.rawValue)：列了 \(keys.joined(separator: "、"))", "缺 \(missing.joined(separator: "、"))")
        }
        return failed
    }
}
