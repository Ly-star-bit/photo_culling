import SwiftUI
import AppKit

// MARK: - 相册界面的状态和规则（相册 A + B 第 2 波 · U）
//
// 整本概览、跨页条拖动、⌘← ⌘→、封面卡、「这个跨页」那几个按钮、「换一张」、「移到第…个跨页」共用的东西：
// - CollageAlbumUI：界面状态（概览开没开、概览里选了哪几个跨页、拖照片经过跨页条落在哪张卡片上）。单独一个对象，只有跨页条、
//   画布区、概览订阅：概览里点一下选中，检视器、托盘不跟着重算。
// - CollageAlbumRules：纯函数（换跨页到头、编辑封面时哪些不能做、多选、拖动的插入位置、「移到第…个」怎么分组、按键），
//   --album-selftest 直接测（CollageAlbumUISelfTest）。
// - 按键监听（⌘← ⌘→、G）：输入框里打字时 ⌘← ⌘→ 是挪光标，不抢（同 ? 键，见 ShortcutsPanel.swift）。
// - 画布右键菜单（「移到第…个跨页」）：SwiftUI 的 contextMenu 不知道点在哪一格，用一层只接右键的 NSView 现点现建。

/// 相册界面状态（CollageStore.albumUI）。
@MainActor
final class CollageAlbumUI: ObservableObject {
    /// 整本概览开着：画布区换成网格（CollageAlbumOverview）。只对相册。
    @Published var overviewShown = false
    /// 概览里选中的跨页（按页 id：挪、删以后下标会变，id 不变）。
    @Published var overviewSelection: Set<UUID> = []
    /// ⇧ 连选从哪一个算起（最近一次单击 / ⌘ 点的那一个）。
    var overviewAnchor: UUID?
    /// 概览里每张缩略图多宽（pt，滑杆）。缩略图用跨页条那一份（长边 260 像素），再大就虚了：上限 260。
    @Published var overviewCardWidth: Double = 180
    /// 画布上拖一格照片经过跨页条：指着第几个跨页的卡片（nil = 没指着卡片）。松手 = moveCells。
    @Published var stripHover: Int?
    /// 托盘照片拖到卡片上、画布的格子拖到卡片上以后在排的那一页（页 id）：那张卡片上转圈（store.isSolving 落下来就停）。
    @Published var pendingPage: UUID?

    /// 跨页条在窗口里的位置（.global；不发布：画布拖照片时现查，跨页条每次排版写一次）。
    var stripViewport: CGRect = .zero
    var stripContent: CGRect = .zero
    var stripMetrics = CollageAlbumRules.GridMetrics(columns: 1, cell: CGSize(width: 104, height: 70), spacing: 8)
    /// 跨页条最前面几张不是跨页（相册的封面卡 = 1）。
    var stripLeadingSlots = 0
    var stripPageCount = 0

    static let cardWidthRange: ClosedRange<Double> = 110...260

    /// 开 / 关整本概览（跨页条左边的「整本」、G 键）。打开时退出裁切（画布不在了，裁切模式收不了尾）。
    func toggleOverview(_ store: CollageStore) {
        if overviewShown {
            overviewShown = false
        } else {
            guard store.isAlbum else { return }
            if store.cropEditing { store.exitCropEdit() }
            overviewShown = true
        }
    }

    /// 概览里选中的跨页下标（按现在的顺序，挪删之后照样对）。
    func selectedIndices(_ pages: [CollagePage]) -> IndexSet {
        CollageAlbumRules.indices(of: overviewSelection, in: pages)
    }

    /// 画布上拖的那一点（窗口坐标，.global）指着跨页条上的第几个跨页；没指着卡片（在缝里、封面卡、+ 号、条外面）= nil。
    func stripTarget(at point: CGPoint) -> Int? {
        guard stripViewport.contains(point), stripContent.contains(point) else { return nil }
        let local = CGPoint(x: point.x - stripContent.minX, y: point.y - stripContent.minY)
        let slots = stripLeadingSlots + stripPageCount
        guard let slot = CollageAlbumRules.hitSlot(at: local, slots: slots, metrics: stripMetrics) else { return nil }
        let page = slot - stripLeadingSlots
        return page >= 0 && page < stripPageCount ? page : nil
    }
}

/// 相册界面的纯函数（不碰界面、不碰 store）。
enum CollageAlbumRules {

    // MARK: 编辑封面时哪些不能做

    /// 界面上的入口（按钮、菜单、按键、拖放）。
    enum Action: String, CaseIterable {
        // 编辑封面时不能做的
        case scatter, contactSheet, freeItems, darkroom, pageLook, moveToSpread, replacePhoto, sideLayout, mirror, lockSpread
        case saveTemplate
        // 封面那一块照常能做的
        case selectCell, placePhoto, editText, textCell, refit, cellLook, crop, regenerate

        var label: String {
            switch self {
            case .scatter: return "散落版"
            case .contactSheet: return "印样"
            case .freeItems: return "贴纸、手写字"
            case .darkroom: return "暗房"
            case .pageLook: return "这一页的色调"
            case .moveToSpread: return "移到别的跨页"
            case .replacePhoto: return "换一张"
            case .sideLayout: return "左页、右页换版式"
            case .mirror: return "镜像"
            case .lockSpread: return "锁住这个跨页"
            case .saveTemplate: return "存成模板"
            case .selectCell: return "选格子"
            case .placePhoto: return "放照片"
            case .editText: return "改字"
            case .textCell: return "加文字格"
            case .refit: return "贴合原比例"
            case .cellLook: return "这一格的色调"
            case .crop: return "调裁切"
            case .regenerate: return "换一批"
            }
        }
    }

    /// 编辑封面时这一样能不能做。封面那块是一棵切分树（照片 / 文字 / 留白）：没有散落版、印样、图层；暗房、页色调、
    /// 存模板都按「当前跨页」做，会改到封面底下那个跨页上；挪到别的跨页、换一张、左右页换版式、镜像、锁都是跨页的事。
    static func allows(_ action: Action, editingCover: Bool) -> Bool {
        guard editingCover else { return true }
        switch action {
        case .scatter, .contactSheet, .freeItems, .darkroom, .pageLook, .moveToSpread, .replacePhoto, .sideLayout,
             .mirror, .lockSpread, .saveTemplate:
            return false
        case .selectCell, .placePhoto, .editText, .textCell, .refit, .cellLook, .crop, .regenerate:
            return true
        }
    }

    // MARK: ⌘← ⌘→ 换跨页

    /// 换到哪：封面，或第几个跨页。
    enum Target: Equatable {
        case cover
        case page(Int)
    }

    /// ⌘← / ⌘→（delta = −1 / +1）从现在的位置换到哪。封面排在第一个跨页前面（同跨页条）：第一个跨页按 ⌘← 到封面，
    /// 封面按 ⌘→ 到第一个跨页；到头了 = nil（不动）。
    static func step(_ delta: Int, current: Int, editingCover: Bool, hasCover: Bool, count: Int) -> Target? {
        guard delta != 0 else { return nil }
        if editingCover {
            return delta > 0 && count > 0 ? .page(min(count - 1, delta - 1)) : nil
        }
        // 没在编辑封面时 current 就是 pageIndex（正常总在范围里；夹一下防空工程）。
        guard count > 0 else { return nil }
        let t = min(max(current, 0), count - 1) + delta
        if t < 0 { return hasCover ? .cover : nil }
        return t < count ? .page(t) : nil
    }

    // MARK: 按键（整个拼图页的监听）

    enum KeyAction: Equatable {
        case step(Int)
        case overview
    }

    /// 按键 → 做什么。typing = 焦点在能打字的地方（输入框里 ⌘← ⌘→ 是挪到行首行尾，G 是打字）：一律不接。
    /// ⌘← ⌘→ 只认单按 ⌘（⇧⌘← 在别处是选到行首，⌥⌘、⌃⌘ 留给系统）；G 不带修饰键（大小写锁定不算）。
    static func keyAction(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                          typing: Bool) -> KeyAction? {
        guard !typing else { return nil }
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        switch keyCode {
        case 123: return mods == [.command] ? .step(-1) : nil
        case 124: return mods == [.command] ? .step(1) : nil
        default: break
        }
        if mods.isEmpty, characters?.lowercased() == "g" { return .overview }
        return nil
    }

    /// 画布上的 Q / A（左页上一种 / 下一种切法）、W / S（右页）。带 ⌘ ⌃ ⌥ 的不接（⇧ 不管：大写也认）。
    static func sideKey(_ characters: String, modifiers: EventModifiers) -> (side: CollageSpreadSide, step: Int)? {
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch characters.lowercased() {
        case "q": return (.left, -1)
        case "a": return (.left, 1)
        case "w": return (.right, -1)
        case "s": return (.right, 1)
        default: return nil
        }
    }

    // MARK: 概览里的选中

    /// 点一下以后选中哪些（同托盘：单击只选这一个，⌘ 点加减，⇧ 点从上次点的那个连到这个，⌘⇧ 点把这一段加进去）。
    /// 返回新的选中和新的起点。
    static func click<ID: Hashable>(_ id: ID, command: Bool, shift: Bool, selection: Set<ID>, anchor: ID?,
                                    order: [ID]) -> (selection: Set<ID>, anchor: ID?) {
        if shift, let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            let range = Set(order[min(i, j)...max(i, j)])
            return (command ? selection.union(range) : range, anchor)
        }
        var next = selection
        if command {
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
        } else {
            next = [id]
        }
        return (next, id)
    }

    /// 选中的页 id → 现在的下标（不在了的不管）。
    static func indices(of ids: Set<UUID>, in pages: [CollagePage]) -> IndexSet {
        IndexSet(pages.indices.filter { ids.contains(pages[$0].id) })
    }

    /// 拖动 / 右键要动的那几个跨页：点在多选里的一个 = 整批；点在没选的那个上 = 只它自己。
    static func targets(for id: UUID, selection: Set<UUID>, pages: [CollagePage]) -> IndexSet {
        if selection.contains(id), selection.count > 1 { return indices(of: selection, in: pages) }
        return indices(of: [id], in: pages)
    }

    // MARK: 网格（概览）和一排（跨页条）的几何、插入位置

    /// 一格一格等大排开：columns 列，每格 cell 大，格间距 spacing，左上角 origin。跨页条 = 一行（columns ≥ 格数）。
    struct GridMetrics: Equatable {
        var columns: Int
        var cell: CGSize
        var spacing: CGFloat
        var origin: CGPoint = .zero

        var pitchX: CGFloat { cell.width + spacing }
        var pitchY: CGFloat { cell.height + spacing }
    }

    /// 这么宽的地方放几列（至少 1 列）。
    static func columns(width: CGFloat, cardWidth: CGFloat, spacing: CGFloat, padding: CGFloat) -> Int {
        let usable = width - padding * 2 + spacing
        return max(1, Int(usable / max(1, cardWidth + spacing)))
    }

    static func rows(slots: Int, columns: Int) -> Int {
        slots <= 0 ? 0 : (slots + max(1, columns) - 1) / max(1, columns)
    }

    /// 第几格的框。
    static func slotRect(_ slot: Int, metrics m: GridMetrics) -> CGRect {
        let cols = max(1, m.columns)
        let row = slot / cols
        let col = slot % cols
        return CGRect(x: m.origin.x + CGFloat(col) * m.pitchX, y: m.origin.y + CGFloat(row) * m.pitchY,
                      width: m.cell.width, height: m.cell.height)
    }

    /// 点在哪一格上（只算格子本身，缝里、最后一格后面 = nil）。
    static func hitSlot(at p: CGPoint, slots: Int, metrics m: GridMetrics) -> Int? {
        guard slots > 0, m.pitchX > 0, m.pitchY > 0 else { return nil }
        let x = p.x - m.origin.x
        let y = p.y - m.origin.y
        guard x >= 0, y >= 0 else { return nil }
        let col = Int(x / m.pitchX)
        let row = Int(y / m.pitchY)
        guard col < max(1, m.columns), x - CGFloat(col) * m.pitchX <= m.cell.width,
              y - CGFloat(row) * m.pitchY <= m.cell.height else { return nil }
        let slot = row * max(1, m.columns) + col
        return slot < slots ? slot : nil
    }

    /// 拖动时插在哪：第几行、这一行的第几个缝（0 = 这一行最前面，columns = 最后面），合起来是「插在第 slot 格前面」
    /// （slot = 格数 = 插在最后）。行按指针的高度算（夹在已有的行里），缝按指针离哪个缝近（格子中线以左插在它前面）。
    static func insertion(at p: CGPoint, slots: Int, metrics m: GridMetrics) -> (slot: Int, row: Int, gap: Int) {
        let cols = max(1, m.columns)
        let rowCount = max(1, rows(slots: slots, columns: cols))
        let row = min(rowCount - 1, max(0, Int(floor((p.y - m.origin.y + m.spacing / 2) / max(1, m.pitchY)))))
        let inRow = min(cols, max(0, slots - row * cols))
        // 中线在指针左边的格子有几个（第 k 格的中线在 k × pitch + w / 2）：x 在第 0 格中线左边 = 0。
        let x = p.x - m.origin.x
        let gap = min(inRow, max(0, Int(floor((x - m.cell.width / 2) / max(1, m.pitchX))) + 1))
        return (row * cols + gap, row, gap)
    }

    /// 插入位置（第几格前面）→ movePages 的 destination：前面 lead 格不是跨页（封面卡），插在它们前面也算插在第一个跨页前。
    static func pageDestination(slot: Int, leadingSlots lead: Int, pageCount: Int) -> Int {
        min(pageCount, max(0, slot - lead))
    }

    /// 这几页挪到 destination 以后顺序变不变（不变就不画插入线、不记撤销）。
    static func moveChangesOrder(_ indices: IndexSet, to destination: Int, count: Int) -> Bool {
        let order = Array(0..<count)
        return CollageAlbum.moved(order, from: indices, to: destination) != order
    }

    // MARK: 「移到第…个跨页」

    struct MoveGroup: Equatable {
        /// 子菜单的名字（只有一组时空着：直接列出来）。
        var title: String
        var pages: [Int]
    }

    /// 跨页不多（≤ flatLimit）直接列；多了每 groupSize 个一组（「第 1–10 个」「第 11–20 个」…）。
    static func moveGroups(count: Int, groupSize: Int = 10, flatLimit: Int = 12) -> [MoveGroup] {
        guard count > 0 else { return [] }
        guard count > flatLimit else { return [MoveGroup(title: "", pages: Array(0..<count))] }
        let size = max(1, groupSize)
        return stride(from: 0, to: count, by: size).map { start in
            let end = min(count, start + size)
            return MoveGroup(title: "第 \(start + 1)–\(end) 个", pages: Array(start..<end))
        }
    }

    /// 填号的小框：「7」→ 第 7 个（下标 6）。认全角数字、前后空格、「第 7 个」；越界、就是这一个、认不出 = 说一句。
    static func parseSpreadNumber(_ text: String, count: Int, current: Int) -> Result<Int, MoveError> {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let digits = half.filter(\.isNumber)
        guard !digits.isEmpty, let n = Int(digits) else { return .failure(MoveError(message: "填一个数（1–\(count)）")) }
        guard n >= 1, n <= count else { return .failure(MoveError(message: "只有 \(count) 个跨页：填 1–\(count)")) }
        guard n - 1 != current else { return .failure(MoveError(message: "这张已经在第 \(n) 个跨页上了")) }
        return .success(n - 1)
    }

    struct MoveError: Error, Equatable {
        let message: String
    }

    // MARK: 文字

    /// 「4 张」「空」：卡片下面那行。
    static func photoCountLabel(_ n: Int) -> String { n == 0 ? "空" : "\(n) 张" }

    /// 「换一张」候选的角标：在第几个跨页上（就是这一页 = 「这一页」；单张拼图只有一页 = 「已用」）。
    static func usedBadge(page: Int?, current: Int, album: Bool, pageCount: Int) -> String? {
        guard let page else { return nil }
        if page == current { return "这一页" }
        if !album, pageCount <= 1 { return "已用" }
        return album ? "第 \(page + 1) 跨页" : "第 \(page + 1) 页"
    }
}

// MARK: - 按键监听：⌘← ⌘→ 换跨页、G 整本概览

extension View {
    /// 拼图编辑区在窗口里时接 ⌘← ⌘→、G（输入框里打字时不接，见 CollageAlbumRules.keyAction）。
    func collageAlbumKeys(store: CollageStore) -> some View {
        modifier(CollageAlbumKeysModifier(store: store))
    }
}

private struct CollageAlbumKeysModifier: ViewModifier {
    let store: CollageStore
    @State private var monitor = CollageAlbumKeyMonitor()

    func body(content: Content) -> some View {
        content
            .background(CollageAlbumKeyAnchor(monitor: monitor))
            .onAppear { monitor.start(store) }
            .onDisappear { monitor.stop() }
    }
}

/// 只认挂着它的视图所在的那个窗口（不是挂在上面的弹出框、快捷键一览：导出设置里的输入框照常挪光标）；视图不在窗口里
/// （暗房盖住了拼图页、切到别的页签）不接。
@MainActor
private final class CollageAlbumKeyMonitor {
    weak var view: NSView?
    private var token: Any?
    private weak var store: CollageStore?

    func start(_ store: CollageStore) {
        self.store = store
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let code = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                self?.handle(keyCode: code, characters: characters, modifiers: modifiers, windowNumber: windowNumber) ?? false
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private func handle(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor, let store,
              let target = NSApp.window(withWindowNumber: windowNumber), target === window,
              let action = CollageAlbumRules.keyAction(keyCode: keyCode, characters: characters, modifiers: modifiers,
                                                       typing: ShortcutsKey.isTyping(target.firstResponder)) else {
            return false
        }
        return CollageAlbumKeys.perform(action, store: store)
    }
}

/// 按键做的事（按键监听、--collage-ui 都走这里）。返回做没做（到头了 = 没做，按键照常往下传）。
@MainActor
enum CollageAlbumKeys {
    static func perform(_ action: CollageAlbumRules.KeyAction, store: CollageStore) -> Bool {
        switch action {
        case .overview:
            guard store.isAlbum else { return false }
            store.albumUI.toggleOverview(store)
            return true
        case .step(let delta):
            return go(delta, store: store)
        }
    }

    /// ⌘← / ⌘→：换到上一个 / 下一个跨页（封面在第一个跨页前面）。
    @discardableResult
    static func go(_ delta: Int, store: CollageStore) -> Bool {
        let hasCover = store.isAlbum && store.project.bookCover != nil
        guard let target = CollageAlbumRules.step(delta, current: store.pageIndex, editingCover: store.editingCover,
                                                  hasCover: hasCover, count: store.project.pages.count) else { return false }
        open(target, store: store)
        return true
    }

    /// 打开封面 / 第几个跨页（跨页条、概览、按键共用）：点跨页卡片先退出封面编辑 —— 点的正好是封面底下那个跨页时 pageIndex
    /// 不变，didSet 不会替我们退出。
    static func open(_ target: CollageAlbumRules.Target, store: CollageStore) {
        switch target {
        case .cover:
            store.setEditingCover(true)
        case .page(let i):
            guard store.project.pages.indices.contains(i) else { return }
            if store.editingCover { store.setEditingCover(false) }
            store.pageIndex = i
        }
    }
}

/// 看不见的 NSView：告诉监听本页在哪个窗口。点击一律穿过去。
private struct CollageAlbumKeyAnchor: NSViewRepresentable {
    let monitor: CollageAlbumKeyMonitor

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

// MARK: - 画布右键菜单

/// 画布的右键菜单：SwiftUI 的 contextMenu 在 body 里就建好了，不知道点在哪一格。这里垫一个看不见的 NSView（铺在画布底下、
/// 点击一律穿过去，同 ? 键的那个），再挂一个只看本窗口的按键监听：右键（和 ⌃ 点）落在它的范围里 = 问 menu(at:) 要一个
/// 现建的菜单（点在哪一格、那一格是什么都现查），有菜单就吞掉这一下、下一轮弹出来（先让选中框画上，看得见点的是哪一格）；
/// 没有菜单照常往下传。左键、拖动、悬停完全不经过它，画布的手势照旧。
struct CollageContextMenuAnchor: NSViewRepresentable {
    /// 点在这一点（画布视图坐标，左上原点）：要显示的菜单；nil = 不弹。
    let menu: (CGPoint) -> NSMenu?

    final class AnchorView: NSView {
        var build: ((CGPoint) -> NSMenu?)?
        private var token: Any?
        private var pending: (menu: NSMenu, event: NSEvent)?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        private func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            let context = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard context, let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p), let menu = build?(p) else { return false }
            pending = (menu, event)
            perform(#selector(popPending), with: nil, afterDelay: 0)
            return true
        }

        @objc private func popPending() {
            guard let p = pending else { return }
            pending = nil
            NSMenu.popUpContextMenu(p.menu, with: p.event, for: self)
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.build = menu
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.build = menu
    }
}

/// 带闭包的菜单项（画布右键菜单用）。
final class CollageMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
        isEnabled = enabled
    }

    @objc private func fire() { handler?() }
}

// MARK: - 封面的小图（跨页条的封面卡、概览的第一张）

/// 整张封面的小图：后台渲（不在 body 里渲），工程里和封面有关的一变才重渲（同「文档 › 封面」的预览，CollageCoverPreview）。
struct CollageCoverThumb: View {
    @ObservedObject var store: CollageStore
    /// 渲多大（长边像素）。
    let longEdge: Double
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
        }
        .task(id: CollageCoverPreview.key(store)) {
            let done = await CollageCoverPreview.render(store, longEdge: longEdge, guides: false)
            guard !Task.isCancelled else { return }
            image = done
        }
    }
}

/// 封面预览的键和渲染（「文档 › 封面」的只读预览、跨页条的封面卡、概览共用）。
@MainActor
enum CollageCoverPreview {
    /// 预览跟着变的：封面本身、画布、样式、标题、跨页数（书脊估算）、封面用到的照片、路人信息和蒙版的版本。
    static func key(_ store: CollageStore) -> Int {
        var h = Hasher()
        let p = store.project
        h.combine(p.bookCover)
        h.combine(p.canvas)
        h.combine(p.style)
        h.combine(p.title)
        h.combine(p.subtitle)
        h.combine(p.pages.count)
        h.combine(p.watermark)
        let map = store.photoMap
        for id in p.bookCover?.photoIDs ?? [] { h.combine(map[id]) }
        h.combine(store.hintsVersion)
        h.combine(store.masksVersion)
        return h.finalize()
    }

    /// 整张封面（带包边、出血）渲成长边 longEdge 像素；guides = 折线、安全区参考线。没有封面 = nil。
    static func render(_ store: CollageStore, longEdge: Double, guides: Bool) async -> NSImage? {
        guard let layout = store.coverLayout else { return nil }
        let project = store.project
        let hints = store.hints
        let scale = min(1, longEdge / Double(max(1, layout.width, layout.height)))
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            var opts = CollageRender.Options(scale: scale)
            opts.includeBleed = true
            opts.guides = guides
            opts.placeholders = true
            opts.watermark = true
            return CollageBookCoverRender.render(project: project, hints: hints, options: opts)
        }.value
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}
