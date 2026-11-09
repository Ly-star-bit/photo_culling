import SwiftUI

// MARK: - 拼图页里「去那儿」
//
// 左栏托盘三个页签（照片 / 模板 / 素材）、右栏检视器三个页签（格式 / 样式 / 文档）、顶栏的暗房和「导出 ▾」、底下的方案栏：
// 指路的字（「在「样式 › 边框」里」）点了走这里，「这一版新增」的「带我去」也走这里（AppModel.go）。
// 去一个地方 = 切页签 + 滚到那一块 + 那一块描一圈强调色、1.6 秒后淡掉。

/// 左栏托盘的页签。
enum CollageTrayTab: String, CaseIterable, Identifiable {
    case photos, templates, assets
    var id: String { rawValue }
    var label: String {
        switch self {
        case .photos: return "照片"
        case .templates: return "模板"
        case .assets: return "素材"
        }
    }
}

/// 能去的那几块。rawValue 是命令行 --go 的写法，也是滚动用的锚点。
enum CollageSpot: String, CaseIterable, Identifiable {
    // 左栏
    case photos, kits, templates, saveTemplate, assets, textCells, stickers, contactSheet
    // 右栏「格式」：选中的那一样（没选中 = 这一页）
    case format, textEditor, overlays, cellLook
    // 右栏「格式」里只有没选中时才有的（去之前先取消选中）
    case page, pageLook, contact
    // 右栏「样式」
    case presets, looks, spacing, background, frame
    // 右栏「文档」
    case canvas, titles, watermark
    // 顶栏、底栏
    case darkroom, export, variants

    var id: String { rawValue }

    /// 在哪一栏：滚动只归那一栏的 ScrollViewReader 管。
    enum Area { case tray, inspector, bar }

    var area: Area {
        if tray != nil { return .tray }
        if inspector != nil { return .inspector }
        return .bar
    }

    /// 左栏的哪个页签（nil = 不在左栏）。
    var tray: CollageTrayTab? {
        switch self {
        case .photos: return .photos
        case .kits, .templates, .saveTemplate: return .templates
        case .assets, .textCells, .stickers, .contactSheet: return .assets
        default: return nil
        }
    }

    /// 右栏的哪个页签（nil = 不在右栏）。
    var inspector: CollageInspector.Tab? {
        switch self {
        case .format, .textEditor, .overlays, .cellLook, .page, .pageLook, .contact: return .format
        case .presets, .looks, .spacing, .background, .frame: return .style
        case .canvas, .titles, .watermark: return .document
        default: return nil
        }
    }

    /// 「格式」只在什么都没选时显示这一页：去这几块之前先取消选中。
    var needsNothingSelected: Bool { self == .page || self == .pageLook || self == .contact }

    /// 指路的字里怎么叫它（「样式 › 边框」）。
    var label: String {
        switch self {
        case .photos: return "托盘 › 照片"
        case .kits: return "模板 › 一键成套"
        case .templates: return "模板"
        case .saveTemplate: return "模板 › 我的模板"
        case .assets: return "素材"
        case .textCells: return "素材 › 文字格"
        case .stickers: return "素材 › 贴纸与手写"
        case .contactSheet: return "素材 › 印样"
        case .format: return "格式"
        case .textEditor: return "格式 › 排版"
        case .overlays: return "格式 › 照片上的字"
        case .cellLook: return "格式 › 色调"
        case .page: return "格式 › 这一页"
        case .pageLook: return "格式 › 这一页 › 色调"
        case .contact: return "格式 › 印样"
        case .presets: return "样式 › 风格"
        case .looks: return "样式 › 色调"
        case .spacing: return "样式 › 留白与形状"
        case .background: return "样式 › 底色"
        case .frame: return "样式 › 边框与投影"
        case .canvas: return "文档 › 画布"
        case .titles: return "文档 › 标题和刊头"
        case .watermark: return "文档 › 水印"
        case .darkroom: return "顶栏 › 暗房"
        case .export: return "顶栏 › 导出"
        case .variants: return "方案栏"
        }
    }
}

/// 一个拼图 store 一份（CollageStore.nav）：检视器、左栏各自订阅，画布不订阅。
@MainActor
final class CollageNav: ObservableObject {
    @Published var inspectorTab: CollageInspector.Tab = .format
    @Published var trayTab: CollageTrayTab = .photos
    /// 顶栏「导出 ▾」弹出来没有。
    @Published var exportShown = false
    /// 等着滚过去的那一块：哪一栏的 ScrollViewReader 先出现 / 先收到就由它滚、清掉（切页签时那一页还没建出来，
    /// 只能等它 onAppear）。
    @Published private(set) var pendingScroll: CollageSpot?
    /// 正在描边的那一块：单独一个对象，只有带记号的那几块订阅（换页签、滚动不让它们跟着重算）。
    let flash = Flash()

    final class Flash: ObservableObject {
        @Published var spot: CollageSpot?
    }

    private var flashToken = 0
    /// 描边亮多久（秒）。
    static let flashDuration = 1.6

    /// 选中了画布上的东西：右栏切到「格式」（NU3）。点空白处不切：「格式」本来就显示这一页。
    func showFormat() {
        if inspectorTab != .format { inspectorTab = .format }
    }

    /// 切页签、滚过去、描一圈。`flash: false` = 只去不描（离屏快照要稳定的画面）。
    /// 取消选中、关暗房由 CollageStore.go 先做，这里只管界面状态。
    func go(_ spot: CollageSpot, flash: Bool = true) {
        if let tab = spot.inspector, inspectorTab != tab { inspectorTab = tab }
        if let tab = spot.tray, trayTab != tab { trayTab = tab }
        if spot == .export { exportShown = true }
        if spot.area != .bar { pendingScroll = spot }
        guard flash else { return }
        flashToken += 1
        let token = flashToken
        // 等新的页签建出来、滚完再亮（不然描边先亮在看不见的地方）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flash.spot = spot
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 + Self.flashDuration) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flash.spot = nil
        }
    }

    /// 某一栏的 ScrollViewReader 出现 / 收到新的请求时调：是这一栏的就交给它滚、清掉。
    func takeScroll(for area: CollageSpot.Area) -> CollageSpot? {
        guard let spot = pendingScroll, spot.area == area else { return nil }
        pendingScroll = nil
        return spot
    }

    // MARK: 命令行 --collage-ui --tab

    /// --tab 认的写法：新名字（格式 / 样式 / 文档 / 照片 / 模板 / 素材）和老名字（版式 / 文字 / 水印 / 导出，映射到
    /// 现在最接近的位置）。nil = 不认识。
    struct SnapshotTab: Equatable {
        var inspector: CollageInspector.Tab?
        var tray: CollageTrayTab?
        /// 滚到这一块（老名字「水印」= 文档里的水印那一段）。
        var spot: CollageSpot?
        /// 「导出 ▾」摊开（离屏截不到弹出框：快照里画在顶栏下面）。
        var export = false
    }

    static func snapshotTab(_ name: String, hasSelection: Bool) -> SnapshotTab? {
        if let tab = CollageInspector.Tab(rawValue: name) { return SnapshotTab(inspector: tab) }
        if let tray = CollageTrayTab.allCases.first(where: { $0.label == name }) { return SnapshotTab(tray: tray) }
        switch name {
        // 以前的「版式」：画布 → 选中的格子 / 图层 → 版式操作；现在选中的、这一页的版式操作都在「格式」
        case "版式": return SnapshotTab(inspector: .format)
        // 以前的「文字」：标题那一块 + 选中的文字编辑器；选中了东西就是「格式」，没选中就是「文档」的标题和刊头
        case "文字": return hasSelection ? SnapshotTab(inspector: .format) : SnapshotTab(inspector: .document, spot: .titles)
        case "水印": return SnapshotTab(inspector: .document, spot: .watermark)
        case "导出": return SnapshotTab(export: true)
        default: return nil
        }
    }

    /// --tab 的用法里列的名字（新的在前）。
    static let snapshotTabNames = "格式|样式|文档|照片|模板|素材（老名字 版式|文字|水印|导出 照样认）"
}

extension CollageStore {
    /// 去那一块（指路的字、「带我去」）：要「这一页」的先取消选中；暗房开着就先关（拼图页的编辑区不在视图树里）。
    func go(_ spot: CollageSpot, flash: Bool = true) {
        if darkroom != nil { closeDarkroom() }
        var spot = spot
        // 「格式」的锚点挂在「选中的格子」那块上：什么都没选时格式页显示的是「这一页」，去那块（不然页签不变、滚动和描边
        // 都落空 ——「这一版新增」第一条「带我去」刚启动时就是这样）。选中贴纸、手写字时只切页签。
        if spot == .format, selection == nil, selectedItem == nil { spot = .page }
        // 「格式 › 印样」只有印样页才有：别的页去了只会清掉选中、退出裁切，什么也指不到 —— 改去「这一页」。
        if spot == .contact, !isContactSheet { spot = .page }
        if spot.needsNothingSelected {
            if cropEditing { exitCropEdit() }
            selection = nil
            selectItem(nil)
        }
        nav.go(spot, flash: flash)
    }
}

// MARK: - 描边记号

/// 能被「去那儿」找到的一块：滚动的锚点 + 描边。描边只订阅 nav.flash。
private struct CollageSpotMark: ViewModifier {
    let spot: CollageSpot
    @ObservedObject var flash: CollageNav.Flash

    func body(content: Content) -> some View {
        let on = flash.spot == spot
        content
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2.5)
                    .padding(-3)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.3), value: on)
            .id(spot)
    }
}

extension View {
    /// 这一块是「去那儿」的一个目的地（CollageSpot）。别加在本来就靠 .id 换实例的视图上（套一层容器再加）。
    func collageSpot(_ spot: CollageSpot, _ nav: CollageNav) -> some View {
        modifier(CollageSpotMark(spot: spot, flash: nav.flash))
    }

    /// 一栏的 ScrollViewReader 接「去那儿」：出现时、收到新请求时，是这一栏的就滚过去。
    func collageScrollTarget(_ area: CollageSpot.Area, nav: CollageNav, proxy: ScrollViewProxy) -> some View {
        modifier(CollageScrollTarget(area: area, nav: nav, proxy: proxy))
    }
}

private struct CollageScrollTarget: ViewModifier {
    let area: CollageSpot.Area
    @ObservedObject var nav: CollageNav
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content
            .onAppear { scroll() }
            .onChange(of: nav.pendingScroll) { _, _ in scroll() }
    }

    private func scroll() {
        guard let spot = nav.takeScroll(for: area) else { return }
        // 新页签这一帧才建出来：等它排好再滚。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(spot, anchor: .top) }
        }
    }
}

// MARK: - 指路的字

/// 「在「样式 › 边框」里」那种指路：整句灰字，目的地那几个字是链接色、点了就去（NU4）。
/// 一整个 Text（链接是其中一段）：长句子照常折行，不会拆成左右几栏。
struct CollageJumpText: View {
    let store: CollageStore
    /// 前半句（目的地之前的字），可以空。
    let lead: String
    let spot: CollageSpot
    /// 后半句。
    var tail = ""
    /// 链接上写什么（nil = spot.label）。
    var title: String?

    /// 链接的地址：collage-go:<spot>（只在这个视图里接，不会交给系统去开）。
    static let scheme = "collage-go"

    var body: some View {
        Text(Self.attributed(lead: lead, link: title ?? spot.label, spot: spot, tail: tail))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.scheme, let target = CollageSpot(rawValue: url.absoluteString
                    .replacingOccurrences(of: Self.scheme + ":", with: "")) else { return .discarded }
                store.go(target)
                return .handled
            })
    }

    static func attributed(lead: String, link: String, spot: CollageSpot, tail: String) -> AttributedString {
        var out = AttributedString(lead)
        var part = AttributedString("「\(link)」")
        part.link = URL(string: "\(scheme):\(spot.rawValue)")
        part.foregroundColor = .accentColor
        out += part
        out += AttributedString(tail)
        return out
    }
}
