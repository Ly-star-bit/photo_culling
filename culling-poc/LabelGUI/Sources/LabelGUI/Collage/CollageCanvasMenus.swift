import SwiftUI
import AppKit

// MARK: - 画布右键菜单：点到什么给什么
//
// 以前单张拼图里右键没有任何菜单，相册里只有「移到第…个跨页」：锁定、删除、调裁切、完整显示、换一张、进暗房都只能去右栏找。
// 现在右键先选中点到的那一样（看得见点的是哪个），菜单里是它最常用的那几样 —— 都调 store 现成的方法（和右栏「格式」同一条路，
// 进撤销栈）。菜单是点的时候现建的（CollageContextMenuAnchor），所以勾、灰都是当时的状态。
//
// 这里只拼菜单（标题、勾、灰、点了调什么），不碰界面：命令行 `--collage-ui … --menu-at` 把同一份菜单打印出来核对。

extension CollageCanvasMenu {
    /// 带勾的一项。
    @MainActor
    private static func check(_ title: String, on: Bool, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = CollageMenuItem(title, enabled: enabled, handler: handler)
        item.state = on ? .on : .off
        return item
    }

    @MainActor
    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    /// 右键点在一格上（已经选中它）。editText：去右栏改字（文字格 = 排版，照片 = 照片上的字）；ask：弹「填跨页号」小框。
    @MainActor
    static func cell(store: CollageStore, frame: CollageLayout.Frame, editText: @escaping (CollageSpot) -> Void,
                     ask: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let cell = frame.cell
        let path = frame.path
        let cover = store.editingCover
        switch cell.kind {
        case .photo where cell.photoID != nil:
            menu.addItem(CollageMenuItem("调整裁切…") { store.enterCropEdit(path) })
            menu.addItem(submenu("景别", CollageFraming.allCases.map { framing in
                check(framing.label, on: cell.framing == framing) { store.setFraming(framing) }
            }))
            menu.addItem(check("完整显示，不裁", on: cell.contain) { store.setContain(!cell.contain) })
            menu.addItem(CollageMenuItem("还原自动取景", enabled: cell.crop != nil) { store.resetCrop() })
            menu.addItem(.separator())
            if CollageAlbumRules.allows(.replacePhoto, editingCover: cover) {
                menu.addItem(CollageMenuItem("换一张…") { store.go(.format) })
            }
            menu.addItem(CollageMenuItem("在照片上加字…") { editText(.overlays) })
            if CollageAlbumRules.allows(.darkroom, editingCover: cover) {
                menu.addItem(CollageMenuItem("在暗房里调这一格…") {
                    store.openDarkroom()
                    store.darkroom?.scope = .cell
                })
            }
            menu.addItem(.separator())
            menu.addItem(check("锁定（换一批时不动）", on: cell.locked) { store.toggleLock() })
            if let id = cell.photoID, store.project.watermark?.layer(.photos) != nil {
                let skipped = store.project.watermark?.skipPhotoIDs.contains(id) ?? false
                menu.addItem(check("这张不加水印", on: skipped) {
                    store.updateWatermark { wm in
                        var ids = wm.skipPhotoIDs
                        if skipped { ids.remove(id) } else { ids.insert(id) }
                        wm.skipPhotoIDs = ids
                    }
                })
            }
            // 相册：移到第…个跨页（原来右键唯一的那两项）。
            if let move = build(store: store, path: path, ask: ask) {
                menu.addItem(.separator())
                for item in move.items {
                    move.removeItem(item)
                    menu.addItem(item)
                }
            }
        case .text:
            menu.addItem(CollageMenuItem("改字…") { editText(.textEditor) })
            menu.addItem(.separator())
            menu.addItem(check("锁定（换一批时不动）", on: cell.locked) { store.toggleLock() })
        default:
            let hint = NSMenuItem(title: "空格子：从托盘拖一张照片进来", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(check("锁定（换一批时不动）", on: cell.locked) { store.toggleLock() })
        }
        menu.addItem(.separator())
        menu.addItem(CollageMenuItem("删除格子") { store.removeCell(path) })
        return menu
    }

    /// 右键点在贴纸、手写字、相纸上（已经选中它）。
    @MainActor
    static func item(store: CollageStore, item: CollageItem, editText: @escaping (CollageSpot) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if item.kind == .text {
            menu.addItem(CollageMenuItem("改字…") { editText(.textEditor) })
            menu.addItem(.separator())
        }
        menu.addItem(CollageMenuItem("复制一份") { store.duplicateItem(item.id) })
        menu.addItem(CollageMenuItem("移到最上面") { store.moveItemInStack(item.id, toFront: true) })
        menu.addItem(CollageMenuItem("移到最下面") { store.moveItemInStack(item.id, toFront: false) })
        if abs(item.rotation) > 0.01 {
            menu.addItem(CollageMenuItem("摆正") { store.updateItem(item.id, coalesce: false) { $0.rotation = 0 } })
        }
        menu.addItem(.separator())
        menu.addItem(CollageMenuItem("删除") { store.deleteItem(item.id) })
        return menu
    }

    /// 右键点在一条缝上。
    @MainActor
    static func gutter(store: CollageStore, gutter: CollageLayout.Gutter) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(CollageMenuItem("这条缝横竖翻转（⌥ 点缝）") { store.flipGutter(gutter.path) })
        return menu
    }

    /// 右键点在空白处（画布外面的灰底、散落版和印样的纸上）：这一页的版式操作和画布缩放。
    @MainActor
    static func page(store: CollageStore) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let zoom = store.workspace.zoom
        let grid = !store.isFreeform && !store.isContactSheet
        let fineArtAlbum = store.isAlbum && store.project.albumTheme == .fineArt
        if !fineArtAlbum {
            menu.addItem(CollageMenuItem("换一批", enabled: store.root != nil && !store.isSolving && !store.isContactSheet) {
                store.regenerate()
            })
        }
        menu.addItem(CollageMenuItem("贴合原比例", enabled: grid && store.root != nil) { store.refit() })
        menu.addItem(check("参考线", on: store.showGuides) {
            store.showGuides.toggle()
            store.setNeedsRender()
        })
        menu.addItem(.separator())
        menu.addItem(CollageMenuItem("放大", enabled: zoom.scale < zoom.maxScale - 0.001) { zoom.zoomIn() })
        menu.addItem(CollageMenuItem("缩小", enabled: !zoom.isFit) { zoom.zoomOut() })
        menu.addItem(CollageMenuItem("适应窗口", enabled: !zoom.isFit) { zoom.fit() })
        menu.addItem(CollageMenuItem("实际像素 100%") { zoom.actualPixels() })
        return menu
    }

    /// 菜单打成几行字（命令行核对用）：「✓ 标题」「  标题（灰）」「  标题 ▸ 子项 | 子项」「——」。
    @MainActor
    static func describe(_ menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "——" }
            var line = (item.state == .on ? "✓ " : "  ") + item.title + (item.isEnabled ? "" : "（灰）")
            if let sub = item.submenu {
                line += " ▸ " + sub.items.map { ($0.state == .on ? "✓" : "") + $0.title }.joined(separator: " | ")
            }
            return line
        }
    }
}

// MARK: - 空画布：直接能点的入口

/// 托盘还空着时画布中间的几个按钮：带精选进来、精选 + 可用、添加文件（以前只有一段灰字，叫人去点左上角的「带照片」菜单）。
/// 张数跟着批量页：只有这几个按钮订阅 BatchStore。
struct CollageEmptyActions: View {
    let store: CollageStore
    @ObservedObject var batch: BatchStore

    var body: some View {
        let picks = batch.verdictCounts.pick
        let usable = batch.verdictCounts.usable
        VStack(spacing: 8) {
            Button {
                store.importVerdicts(batch: batch, includeUsable: false)
            } label: {
                Label("带精选进来（\(picks) 张）", systemImage: "star.fill").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(picks == 0)
            .help(picks == 0 ? "批量页还没有精选：先在批量页分析、挑片，或者用下面两个" : "把批量页判成精选的照片带进托盘")
            HStack(spacing: 8) {
                Button("精选 + 可用（\(picks + usable) 张）") { store.importVerdicts(batch: batch, includeUsable: true) }
                    .disabled(batch.items.isEmpty)
                CollageAddFilesButton(store: store)
            }
        }
    }
}

/// 「添加文件…」：选照片或文件夹加进托盘（同托盘「带照片 › 添加文件…」）。
struct CollageAddFilesButton: View {
    let store: CollageStore

    var body: some View {
        Button("添加文件…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { store.addFiles(panel.urls) }
        }
        .help("选照片或文件夹加进托盘（也可以直接把文件拖进来）")
    }
}
