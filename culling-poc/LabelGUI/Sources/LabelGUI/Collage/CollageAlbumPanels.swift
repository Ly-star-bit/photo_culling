import SwiftUI
import AppKit

// MARK: - 检视器「格式」里相册的几块（相册 A + B 第 2 波 · U4 / U5 / U6 / U8）
//
// 「这个跨页」（什么都没选时）：镜像、左页 ‹ ›、右页 ‹ ›、锁住这个跨页（CollageSpreadActions）。
// 选中照片格：「换一张」一排候选（CollageReplaceBox）、「移到第…个跨页」菜单（CollageMoveMenu，画布右键同一份分组）。
// 编辑封面时「这个跨页」换成「封面」那块（CollageCoverEditBox）：书脊、封底在「文档 › 封面」。

/// 「这个跨页」里的跨页操作。左页 / 右页换版式第一次要在后台算一会儿（store.isSolving 时按钮灰着、旁边转圈）。
struct CollageSpreadActions: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        if let page = store.page {
            VStack(alignment: .leading, spacing: 8) {
                if !page.freeform, page.contactSheet == nil, store.project.canvas.seams == .fold {
                    sideRow
                }
                HStack(spacing: 8) {
                    if page.contactSheet == nil { mirrorButton }
                    Spacer(minLength: 4)
                    lockToggle(page)
                }
            }
        }
    }

    /// 左页 ‹ ›  右页 ‹ ›：只重切这一边（照片不变、不跨中缝），几种切法里轮。
    private var sideRow: some View {
        HStack(spacing: 6) {
            sideStepper(.left, keys: "Q / A")
            Spacer(minLength: 4)
            if store.isSolving { ProgressView().controlSize(.small) }
            Spacer(minLength: 4)
            sideStepper(.right, keys: "W / S")
        }
    }

    private func sideStepper(_ side: CollageSpreadSide, keys: String) -> some View {
        HStack(spacing: 2) {
            Text(side.label).font(.caption)
            Button { store.cycleSideLayout(side, step: -1) } label: { Image(systemName: "chevron.left") }
            Button { store.cycleSideLayout(side, step: 1) } label: { Image(systemName: "chevron.right") }
        }
        .controlSize(.small)
        .disabled(store.isSolving)
        .help("\(side.label)换一种切法（照片不变、不跨中缝，另一页不动；⌘Z 撤回）。点一下画布以后 \(keys) = 上一种 / 下一种")
    }

    private var mirrorButton: some View {
        Button {
            store.mirrorPage(store.pageIndex)
        } label: {
            Label("镜像", systemImage: "arrow.left.and.right")
        }
        .controlSize(.small)
        .help("左右翻过来：左页的版式换到右边（照片本身不翻、取景不变，字的对齐不变）；再点一次翻回来")
    }

    private func lockToggle(_ page: CollagePage) -> some View {
        Toggle("锁住这个跨页", isOn: Binding(get: { page.locked }, set: { on in
            store.setPagesLocked(IndexSet(integer: store.pageIndex), on)
        }))
        .toggleStyle(.checkbox)
        .font(.caption)
        .help("锁住的跨页「自动编排」时原样留着，上面的照片不参与编排；照样能挪、能删、能改")
    }
}

/// 编辑封面时「格式」里没选中东西：说清楚画布上是什么、书脊和封底去哪改、怎么回到跨页。
struct CollageCoverEditBox: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        GroupBox("封面") {
            VStack(alignment: .leading, spacing: 8) {
                Text("画布上是整张封面（封底 | 书脊 | 封面）。封面那一块照常点格子选中、从托盘拖照片进来换、双击改字。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CollageJumpText(store: store, lead: "书脊宽、书脊上的字、封底在", spot: .cover, tail: "里改。")
                ForEach(store.coverNotes, id: \.self) { note in
                    Text(note).collageHint()
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("贴合原比例") { store.refit() }
                        .help("结构不变，按照片原比例重算每条缝的位置")
                    Spacer()
                    Button("回到跨页") { CollageAlbumKeys.open(.page(store.pageIndex), store: store) }
                        .help("回到第 \(store.pageIndex + 1) 个跨页（点跨页条上任何一个跨页、⌘→ 也行）")
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .collageSpot(.page, store.nav)
    }
}

// MARK: - 换一张（S6）

/// 选中照片格：托盘里能换它的照片（同连拍 > 同场 > 画面相似，没上版的在前，废片最后），点一下换进这一格。
/// 候选不在 body 里算（要走一遍托盘、查画面距离）：照片、工程、路人信息变了才在 .task 里重算。
struct CollageReplaceBox: View {
    @ObservedObject var store: CollageStore
    let path: [Int]
    let photoID: String
    @State private var candidates: [CollageReplacement] = []
    @State private var loadedKey: String?

    private var key: String { "\(photoID)|\(store.projectRevision)|\(store.hintsVersion)" }

    var body: some View {
        GroupBox("换一张") {
            VStack(alignment: .leading, spacing: 6) {
                if candidates.isEmpty {
                    Text(loadedKey == nil ? "在找…" : "托盘里没有和它同连拍、同一场、画面相似的照片")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    strip
                }
                Text(footnote)
                    .collageHint()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .task(id: key) {
            candidates = store.replacementCandidates(forPhoto: photoID)
            loadedKey = key
        }
    }

    private var footnote: String {
        "点一下换进这一格（取景回到自动，⌘Z 撤回）" + (store.isAlbum ? "；在别的跨页上的两格对调" : "")
    }

    private var strip: some View {
        let map = store.photoMap
        let album = store.isAlbum
        let current = store.pageIndex
        let count = store.project.pages.count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(candidates, id: \.photoID) { c in
                    if let photo = map[c.photoID] {
                        CollageReplaceTile(candidate: c, photo: photo,
                                           badge: CollageAlbumRules.usedBadge(page: c.page, current: current, album: album,
                                                                               pageCount: count)) {
                            store.replacePhoto(at: path, with: c.photoID)
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }
}

/// 「换一张」的一格：缩略图、理由（同连拍 / 同场 / 相似）、在哪个跨页上（角标）、客户选中（紫心）、废片（压暗）。
private struct CollageReplaceTile: View {
    let candidate: CollageReplacement
    let photo: CollagePhotoRef
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                thumb
                Text(candidate.reason.label)
                    .font(.system(size: 9))
                    .foregroundStyle(candidate.reason == .similar ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var thumb: some View {
        ThumbnailView(path: photo.quickPath, maxPixel: 256)
            .frame(width: 62, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(candidate.reject ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(2)
                }
            }
            .overlay(alignment: .topLeading) {
                if candidate.clientPick {
                    Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(.purple)
                        .padding(3).shadow(radius: 1)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if candidate.reject {
                    Text("废片").font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(2)
                }
            }
    }

    private var helpText: String {
        var parts = [photo.id, candidate.reason.label, String(format: "分数 %.2f", candidate.score)]
        if candidate.clientPick { parts.append("客户选中") }
        if candidate.reject { parts.append("废片") }
        if let badge { parts.append("用在" + badge + "（换过来两格对调）") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 移到第…个跨页

/// 「移到第…个跨页」菜单（选中的格子那块；画布右键是同一份分组的 NSMenu，见 CollageCanvasView.contextMenu）。
/// 跨页多了每 10 个一组。最后一项「填跨页号…」弹小框。
struct CollageMoveMenu: View {
    @ObservedObject var store: CollageStore
    let path: [Int]
    @Binding var askNumber: Bool

    var body: some View {
        let count = store.project.pages.count
        let current = store.pageIndex
        Menu("移到第…个跨页") {
            ForEach(CollageAlbumRules.moveGroups(count: count), id: \.title) { group in
                if group.title.isEmpty {
                    items(group.pages, current: current)
                } else {
                    Menu(group.title) { items(group.pages, current: current) }
                }
            }
            Divider()
            Button("填跨页号…") { askNumber = true }
        }
        .fixedSize()
        .disabled(count < 2)
        .help("这张照片挪到别的跨页：两边都重排（锁定的格子不动），一步撤销；也可以把格子直接拖到底下跨页条的卡片上")
    }

    @ViewBuilder
    private func items(_ pages: [Int], current: Int) -> some View {
        ForEach(pages, id: \.self) { i in
            Button(i == current ? "第 \(i + 1) 个（这一个）" : "第 \(i + 1) 个跨页") {
                store.moveCells([path], toPage: i)
            }
            .disabled(i == current)
        }
    }
}

/// 「填跨页号」小框（格子那块的菜单、画布右键共用）：挂在弹它的视图上。
struct CollageMoveNumberAlert: ViewModifier {
    let store: CollageStore
    @Binding var isPresented: Bool
    /// 挪哪一格（nil = 选中的那一格）。
    let path: [Int]?
    @State private var text = ""

    func body(content: Content) -> some View {
        content.alert("移到第几个跨页？", isPresented: $isPresented) {
            TextField("1–\(store.project.pages.count)", text: $text)
            Button("移过去") { commit() }
            Button("取消", role: .cancel) { text = "" }
        } message: {
            Text("现在在第 \(store.pageIndex + 1) 个（共 \(store.project.pages.count) 个）。挪过去两边都重排，⌘Z 撤回。")
        }
    }

    private func commit() {
        defer { text = "" }
        guard let path = path ?? store.selection else { return }
        switch CollageAlbumRules.parseSpreadNumber(text, count: store.project.pages.count, current: store.pageIndex) {
        case .success(let target): store.moveCells([path], toPage: target)
        case .failure(let bad): store.setNotice(bad.message)
        }
    }
}

extension View {
    func collageMoveNumberAlert(store: CollageStore, isPresented: Binding<Bool>, path: [Int]?) -> some View {
        modifier(CollageMoveNumberAlert(store: store, isPresented: isPresented, path: path))
    }
}

// MARK: - 画布右键「移到第…个跨页」（NSMenu 版，CollageContextMenuAnchor 现建）

@MainActor
enum CollageCanvasMenu {
    /// 右键点在 path 那一格（照片格）上的菜单；不是相册 / 编辑封面 / 只有一个跨页 = nil（不弹）。ask = 弹「填跨页号」小框。
    static func build(store: CollageStore, path: [Int], ask: @escaping () -> Void) -> NSMenu? {
        guard store.isAlbum, CollageAlbumRules.allows(.moveToSpread, editingCover: store.editingCover),
              store.project.pages.count > 1 else { return nil }
        let count = store.project.pages.count
        let current = store.pageIndex
        let menu = NSMenu()
        menu.autoenablesItems = false
        let move = NSMenuItem(title: "移到第…个跨页", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for group in CollageAlbumRules.moveGroups(count: count) {
            let target: NSMenu
            if group.title.isEmpty {
                target = sub
            } else {
                let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                let inner = NSMenu()
                inner.autoenablesItems = false
                item.submenu = inner
                sub.addItem(item)
                target = inner
            }
            for i in group.pages {
                let title = i == current ? "第 \(i + 1) 个（这一个）" : "第 \(i + 1) 个跨页"
                target.addItem(CollageMenuItem(title, enabled: i != current) { store.moveCells([path], toPage: i) })
            }
        }
        move.submenu = sub
        menu.addItem(move)
        menu.addItem(CollageMenuItem("移到第…个跨页（填号）…", handler: ask))
        return menu
    }
}
