import SwiftUI
import AppKit

// MARK: - 整本概览（相册 A + B 第 2 波 · U1）
//
// 跨页条左边「整本」（或 G）：画布区换成网格，摊开全部跨页（封面排第一张、不能拖），缩略图大小有滑杆。
// 单击选中、⌘ 点加减、⇧ 点连选；拖动排序（插入的位置画一条竖线，多选了拖其中一个 = 整批一起挪）；右键锁住 / 解锁 /
// 镜像 / 删除；双击回到编辑这一页（封面 = 编辑封面）；托盘的照片拖到某个跨页上 = 加进那个跨页（addPhotos，F5 照旧）。
// Esc、G、再点「整本」回编辑。缩略图用跨页条那一份（store.thumbs.pages），不另渲。
// 排序用自己的拖动手势（不是系统拖放）：知道拖的是哪几个跨页，插入线跟手；托盘照片走系统拖放（文字 = 照片 id）。

struct CollageAlbumOverview: View {
    @ObservedObject var store: CollageStore
    @ObservedObject var ui: CollageAlbumUI
    @ObservedObject var thumbs: CollageThumbs
    /// 正在拖着排序：拖的是哪几个跨页、指针在网格里的位置。
    @State private var drag: PageDrag?
    @FocusState private var focused: Bool

    private struct PageDrag: Equatable {
        var ids: Set<UUID>
        var location: CGPoint
    }

    init(store: CollageStore) {
        self.store = store
        self.ui = store.albumUI
        self.thumbs = store.thumbs
    }

    static let space = "albumOverview"
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 14
    /// 卡片下面一行字（跨页号、张数、锁）的高度。
    static let captionHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            selectionBar
            Divider()
            GeometryReader { geo in
                ScrollView(.vertical) {
                    grid(width: geo.size.width)
                }
            }
        }
        .background(Color(white: 0.14))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            pruneSelection()
        }
        .onChange(of: store.project.pages.map(\.id)) { _, _ in pruneSelection() }
        .onKeyPress(.escape) {
            ui.overviewShown = false
            return .handled
        }
        .onKeyPress(.delete) { deleteSelected() }
        .onKeyPress(.deleteForward) { deleteSelected() }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            ui.overviewSelection = Set(store.project.pages.map(\.id))
            ui.overviewAnchor = store.project.pages.first?.id
        }
    }

    // MARK: 顶上：整本 · 几个跨页 · 滑杆 · 回到编辑

    private var header: some View {
        let count = store.project.pages.count
        // 画布区最窄 420pt：张数那句放不下就截尾巴（悬停看全），滑杆跟着缩，「回到编辑」不截。
        let summary = "\(count) 个跨页 · \(count * 2)P" + (store.project.bookCover != nil ? " + 封面" : "")
        return HStack(spacing: 8) {
            Label("整本", systemImage: "square.grid.3x3.fill").font(.headline).fixedSize()
            Text(summary)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).truncationMode(.tail)
                .help(summary)
            Spacer(minLength: 4)
            Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $ui.overviewCardWidth, in: CollageAlbumUI.cardWidthRange)
                .frame(minWidth: 56, maxWidth: 120)
                .help("缩略图大小")
            Image(systemName: "photo").font(.body).foregroundStyle(.secondary)
            Button("回到编辑") { ui.overviewShown = false }
                .fixedSize()
                .help("回到画布编辑现在这个跨页（Esc、G 也行）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    /// 选中了几个：一排操作（右键里也有）；没选中：一句操作提示。一直占着位置（选上第一个时网格不往下跳）。
    private var selectionBar: some View {
        let picked = ui.selectedIndices(store.project.pages)
        return HStack(spacing: 8) {
            if picked.isEmpty {
                Text("单击选中 · ⌘ 加减 · ⇧ 连选 · 拖动排序 · 双击编辑 · 托盘的照片拖到跨页上 = 加进那个跨页")
                    .collageHint()
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            } else {
                Text("已选 \(picked.count) 个跨页").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 4)
                actionButtons(picked)
                Button {
                    ui.overviewSelection = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("取消选择")
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionButtons(_ picked: IndexSet) -> some View {
        let allLocked = picked.allSatisfy { store.project.pages[$0].locked }
        Group {
            Button(allLocked ? "解锁" : "锁住") { store.setPagesLocked(picked, !allLocked) }
                .help(allLocked ? "解锁：「自动编排」时照常重排" : "锁住：「自动编排」时原样留着，上面的照片不参与编排")
            Button("镜像") { store.mirrorPages(picked) }
                .help("左右翻过来（照片本身不翻；⌘Z 一次撤回）")
            Button("删除", role: .destructive) { store.deletePages(picked) }
                .help("删掉选中的跨页（⌫；⌘Z 一次撤回）")
        }
        .controlSize(.small)
    }

    // MARK: 网格

    private func metrics(width: CGFloat) -> CollageAlbumRules.GridMetrics {
        let w = CGFloat(ui.overviewCardWidth)
        let c = store.project.canvas
        let thumbH = (w * CGFloat(c.height) / CGFloat(max(1, c.width))).rounded()
        let cols = CollageAlbumRules.columns(width: width, cardWidth: w, spacing: Self.spacing, padding: Self.padding)
        return CollageAlbumRules.GridMetrics(columns: cols, cell: CGSize(width: w, height: thumbH + Self.captionHeight),
                                             spacing: Self.spacing, origin: CGPoint(x: Self.padding, y: Self.padding))
    }

    /// 前面几格不是跨页：封面一张（没做封面时是「+ 封面」）。
    private var leadingSlots: Int { 1 }

    private func grid(width: CGFloat) -> some View {
        let m = metrics(width: width)
        let pages = store.project.pages
        let slots = leadingSlots + pages.count
        let rows = CollageAlbumRules.rows(slots: slots, columns: m.columns)
        let height = Self.padding * 2 + CGFloat(rows) * m.pitchY
        return ZStack(alignment: .topLeading) {
            // 点在卡片之间的空白：取消选择。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    focused = true
                    ui.overviewSelection = []
                }
            coverTile(m)
            ForEach(Array(pages.enumerated()), id: \.element.id) { item in
                pageTile(item.offset, item.element, metrics: m, slots: slots)
            }
            insertionLine(m, slots: slots)
            dragBadge
        }
        .frame(width: width, height: max(height, 1), alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private func coverTile(_ m: CollageAlbumRules.GridMetrics) -> some View {
        let r = CollageAlbumRules.slotRect(0, metrics: m)
        return CollageOverviewCoverCard(store: store, size: r.size, captionHeight: Self.captionHeight)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .onTapGesture { tapCover() }
    }

    private func pageTile(_ index: Int, _ page: CollagePage, metrics m: CollageAlbumRules.GridMetrics,
                          slots: Int) -> some View {
        let r = CollageAlbumRules.slotRect(leadingSlots + index, metrics: m)
        let over = store.project.albumBudget.map { index >= $0.spreads } ?? false
        let pending = ui.pendingPage == page.id && store.isSolving
        let card = CollageOverviewCard(thumb: thumbs.pages[page.id], number: index + 1, photos: page.photoIDs.count,
                                       locked: page.locked, selected: ui.overviewSelection.contains(page.id),
                                       current: index == store.pageIndex && !store.editingCover, over: over,
                                       pending: pending, captionHeight: Self.captionHeight,
                                       onDropPhoto: { id in CollageAlbumDrops.photo(id, onPage: page.id, store: store) })
        return card
            .frame(width: r.width, height: r.height)
            .opacity(drag?.ids.contains(page.id) == true ? 0.35 : 1)
            .contentShape(Rectangle())
            .onTapGesture { tap(page.id, index: index) }
            .gesture(reorder(page.id, metrics: m, slots: slots))
            .contextMenu { menu(page.id, index: index) }
            .help(tileHelp(index, page))
            .offset(x: r.minX, y: r.minY)
    }

    private func tileHelp(_ index: Int, _ page: CollagePage) -> String {
        let lock = page.locked ? " · 锁住" : ""
        return "第 \(index + 1) 个跨页 · \(page.photoIDs.count) 张\(lock)（双击编辑；拖动排序；右键锁住、镜像、删除）"
    }

    // MARK: 点、双击

    /// 正在处理的这下鼠标是第几击（同画布：单击马上选中，双击的第二下在这里按双击处理，不等双击超时）。
    private static func clickCount() -> Int {
        guard let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .leftMouseUp else { return 1 }
        return e.clickCount
    }

    private func tap(_ id: UUID, index: Int) {
        focused = true
        if Self.clickCount() >= 2 {
            open(.page(index))
            return
        }
        let flags = NSEvent.modifierFlags
        let next = CollageAlbumRules.click(id, command: flags.contains(.command), shift: flags.contains(.shift),
                                           selection: ui.overviewSelection, anchor: ui.overviewAnchor,
                                           order: store.project.pages.map(\.id))
        ui.overviewSelection = next.selection
        ui.overviewAnchor = next.anchor
    }

    /// 封面：单击 / 双击都去编辑封面（封面不参与选中、挪、删）；没做封面时「+ 封面」= 做一张再编辑。
    private func tapCover() {
        focused = true
        if store.project.bookCover == nil {
            guard store.makeCover() else { return }
        }
        open(.cover)
    }

    private func open(_ target: CollageAlbumRules.Target) {
        CollageAlbumKeys.open(target, store: store)
        ui.overviewShown = false
    }

    private func deleteSelected() -> KeyPress.Result {
        let picked = ui.selectedIndices(store.project.pages)
        guard !picked.isEmpty else { return .ignored }
        store.deletePages(picked)
        return .handled
    }

    private func pruneSelection() {
        let live = Set(store.project.pages.map(\.id))
        if !ui.overviewSelection.isSubset(of: live) { ui.overviewSelection.formIntersection(live) }
    }

    // MARK: 右键

    @ViewBuilder
    private func menu(_ id: UUID, index: Int) -> some View {
        let targets = CollageAlbumRules.targets(for: id, selection: ui.overviewSelection, pages: store.project.pages)
        let n = targets.count
        let what = n > 1 ? "这 \(n) 个跨页" : "这个跨页"
        let allLocked = targets.allSatisfy { store.project.pages.indices.contains($0) && store.project.pages[$0].locked }
        Button("编辑这个跨页") { open(.page(index)) }
        Divider()
        Button(allLocked ? "解锁\(what)" : "锁住\(what)") { store.setPagesLocked(targets, !allLocked) }
        Button("镜像\(what)") { store.mirrorPages(targets) }
        Divider()
        Button("删除\(what)", role: .destructive) { store.deletePages(targets) }
    }

    // MARK: 拖动排序

    private func reorder(_ id: UUID, metrics m: CollageAlbumRules.GridMetrics, slots: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    focused = true
                    // 拖的不在选中里：只拖它，选中换成它（同访达）。
                    if !ui.overviewSelection.contains(id) {
                        ui.overviewSelection = [id]
                        ui.overviewAnchor = id
                    }
                    drag = PageDrag(ids: ui.overviewSelection, location: value.location)
                } else {
                    drag?.location = value.location
                }
            }
            .onEnded { value in
                defer { drag = nil }
                guard let moving = drag?.ids else { return }
                let pages = store.project.pages
                let indices = CollageAlbumRules.indices(of: moving, in: pages)
                let slot = CollageAlbumRules.insertion(at: value.location, slots: slots, metrics: m).slot
                let dest = CollageAlbumRules.pageDestination(slot: slot, leadingSlots: leadingSlots, pageCount: pages.count)
                guard CollageAlbumRules.moveChangesOrder(indices, to: dest, count: pages.count) else { return }
                store.movePages(indices, to: dest)
            }
    }

    /// 插在哪：那个缝里一条竖线（挪了顺序不变 = 不画）。插在封面前面的算插在第一个跨页前面（封面不能动）。
    @ViewBuilder
    private func insertionLine(_ m: CollageAlbumRules.GridMetrics, slots: Int) -> some View {
        if let drag {
            let pages = store.project.pages
            let indices = CollageAlbumRules.indices(of: drag.ids, in: pages)
            let raw = CollageAlbumRules.insertion(at: drag.location, slots: slots, metrics: m).slot
            let dest = CollageAlbumRules.pageDestination(slot: raw, leadingSlots: leadingSlots, pageCount: pages.count)
            if CollageAlbumRules.moveChangesOrder(indices, to: dest, count: pages.count) {
                let line = Self.lineRect(slot: dest + leadingSlots, slots: slots, metrics: m)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: line.width, height: line.height)
                    .offset(x: line.minX, y: line.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 插在第 slot 格前面的竖线：画在那一格左边的缝里；slot 是一行的头（换行了）时画在上一行最后一格的右边，
    /// 和指针在的那一行对得上（指针在行尾）。
    static func lineRect(slot: Int, slots: Int, metrics m: CollageAlbumRules.GridMetrics) -> CGRect {
        let cols = max(1, m.columns)
        let thumbH = m.cell.height - captionHeight
        if slot > 0, slot % cols == 0 || slot >= slots {
            let prev = CollageAlbumRules.slotRect(slot - 1, metrics: m)
            return CGRect(x: prev.maxX + m.spacing / 2 - 2, y: prev.minY, width: 4, height: thumbH)
        }
        let r = CollageAlbumRules.slotRect(slot, metrics: m)
        return CGRect(x: r.minX - m.spacing / 2 - 2, y: r.minY, width: 4, height: thumbH)
    }

    /// 跟着指针的小牌子：挪几个跨页。
    @ViewBuilder
    private var dragBadge: some View {
        if let drag {
            Text(drag.ids.count > 1 ? "挪 \(drag.ids.count) 个跨页" : "挪这个跨页")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
                .fixedSize()
                .offset(x: drag.location.x + 12, y: drag.location.y + 10)
                .allowsHitTesting(false)
        }
    }
}

/// 概览里一个跨页：缩略图（跨页条那一份）、下面一行「3 · 4 张 · 锁」；选中描粗边、正在编辑的那个描细边。
/// 托盘照片拖上来描边（系统拖放：文字 = 照片 id）。
private struct CollageOverviewCard: View {
    let thumb: NSImage?
    let number: Int
    let photos: Int
    let locked: Bool
    let selected: Bool
    let current: Bool
    /// 超出目标跨页数（页码标橙，同跨页条）。
    let over: Bool
    let pending: Bool
    let captionHeight: CGFloat
    let onDropPhoto: (String) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 2) {
            image
            caption
        }
        .onDrop(of: [.text], isTargeted: $targeted) { providers in
            CollageAlbumDrops.loadText(providers, onDropPhoto)
        }
    }

    private var image: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.22))
            if let thumb {
                Image(nsImage: thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
            if pending { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .overlay(alignment: .topLeading) {
            if locked { CollageLockBadge() }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(borderColor, lineWidth: selected || targeted ? 3 : 1.5)
                .padding(-3)
        }
    }

    private var borderColor: Color {
        if targeted || selected { return .accentColor }
        return current ? Color.white.opacity(0.55) : .clear
    }

    private var caption: some View {
        HStack(spacing: 4) {
            Text("\(number)").fontWeight(.semibold).foregroundStyle(over ? Color.orange : Color.primary)
            Text("· " + CollageAlbumRules.photoCountLabel(photos)).foregroundStyle(.secondary)
            if locked { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
            if current { Text("· 在编辑").foregroundStyle(.tertiary) }
        }
        .font(.caption2)
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: captionHeight - 2)
    }
}

/// 概览的第一张：封面（整张封面的小图），没做封面时是「+ 封面」。不能选中、不能拖。
private struct CollageOverviewCoverCard: View {
    @ObservedObject var store: CollageStore
    let size: CGSize
    let captionHeight: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if store.project.bookCover != nil {
                    Rectangle().fill(Color(white: 0.22))
                    CollageCoverThumb(store: store, longEdge: 520)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    Label("封面", systemImage: "plus").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(store.editingCover ? Color.white.opacity(0.55) : Color.clear, lineWidth: 1.5)
                    .padding(-3)
            }
            Text(store.project.bookCover == nil ? "还没有封面" : "封面")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(height: captionHeight - 2)
        }
        .contentShape(Rectangle())
        .help(store.project.bookCover == nil ? "做一张封面（主图用扉页那张），做好就编辑它"
              : "编辑封面（封面不算在跨页数里、不能拖；书脊、封底在「文档 › 封面」）")
    }
}

/// 卡片左上角的锁（跨页条、概览共用）。
struct CollageLockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(3)
            .background(.black.opacity(0.65), in: Circle())
            .padding(3)
    }
}

/// 托盘照片拖到跨页卡片上（跨页条、概览共用）。
@MainActor
enum CollageAlbumDrops {
    /// 拖放来的文字（托盘拖出来的是照片 id）：读出来交给 body（主线程）。拖放回调不保证在主线程，照 CollageCanvasDropDelegate
    /// 的写法：读完再回主线程，不在回调里碰 store。
    nonisolated static func loadText(_ providers: [NSItemProvider], _ body: @escaping (String) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            Task { @MainActor in body(text) }
        }
        return true
    }

    /// 托盘里的一张拖到第 pageID 个跨页上：拖的是托盘多选里的一张 = 整批（按托盘的先后）。照片已经在别的跨页上 = 不放
    /// （F5，store 说一句）。在后台排，那张卡片上转圈。
    static func photo(_ id: String, onPage pageID: UUID, store: CollageStore) {
        guard store.photoMap[id] != nil, let index = store.project.pages.firstIndex(where: { $0.id == pageID }) else { return }
        let picked = store.tray.selection
        let ids = picked.contains(id) && picked.count > 1 ? store.project.photos.map(\.id).filter(picked.contains) : [id]
        store.addPhotos(ids, toPage: index)
        store.albumUI.pendingPage = store.isSolving ? pageID : nil
    }
}
