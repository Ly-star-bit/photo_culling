import AppKit
import SwiftUI

// MARK: - 网格照片拖出去（优化分析 GP-07）
//
// 从网格里按住一张拖出去：拖到访达（把原片复制过去）、拖到 Capture One / Lightroom / Photoshop 的程序坞图标上（交给它
// 打开）、拖进微信的聊天窗口。按住的这张在选中里 = 选中的全部（GridSelectionRules.menuTargets，和右键菜单同一个规则）；
// 给的是原片的文件（GridHandoff.originals：RAW+JPG 两个都给，和「复制原片到…」同一个规则）。
//
// 为什么不用 SwiftUI 的 .onDrag / .draggable：一次只能给一个 NSItemProvider，拖不了多张；挂在格子上还会拖慢单击选中
// （拼图托盘就是这样，手点清单里有那一条）。这里照拼图画布右键（CollageContextMenuAnchor）的办法：网格底下垫一个看不见的
// NSView（hitTest 一律 nil，点击穿过去），挂一个只看本窗口的鼠标监听：
//   - 左键按下：记下按在哪一张上（GridHover：格子悬停条的 onHover 记的「指针现在在哪一格」）。按在滚动条上、不在网格里的不算。
//   - 按着挪过 5pt：开一个 AppKit 的拖放会话（beginDraggingSession），每个文件一个 NSDraggingItem。事件照常往下传 ——
//     SwiftUI 的单击手势看到挪远了自己作废，不会顺带选中；拖完松手由拖放会话接走。
//   - 抬起：忘掉。
// 单击、双击、⌘ / ⇧ 选、悬停条的按钮都不经过它；没拖的时候它什么都不做，格子上一样东西都没加。
//
// 只给「复制」（GridDragOut.operations）：拖到同一块盘上的访达文件夹，访达默认是「移动」—— 要是给了 .move / .generic，
// 原片就被挪出拍摄文件夹了。拖回本程序自己（网格收文件 = 打开那个文件夹）一律不收。存储卡上的一场照样能拖：复制，卡上不动。
//
// 离屏假事件（--events）送不到这里：监听只在 NSApp 分派真事件时才被叫到（SnapshotEvents.swift 文件头）。只能真机手点；
// 无头验得了的是「按在哪一张上」（GridHover，--events-selftest）和「只给复制」（--ux-selftest）。

/// 指针现在停在网格的哪一格上（nil = 不在格子上）。格子悬停条的 onHover 记、格子消失时清；拖出靠它认按下去的是哪张。
@MainActor
enum GridHover {
    static private(set) var id: String?

    static func hover(_ id: String, _ inside: Bool) {
        if inside {
            self.id = id
        } else if self.id == id {
            self.id = nil
        }
    }

    static func gone(_ id: String) {
        if self.id == id { self.id = nil }
    }
}

enum GridDragOut {
    /// 拖出去允许的操作：出了本程序只给复制（不给移动 / 让对方定 —— 访达同一块盘上默认是移动）；本程序里面不收。
    static func operations(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// 按下以后挪多远才算拖（pt）。
    static let threshold: CGFloat = 5
    /// 拖影最多画几张（多出来的照样拖走，系统在拖影上标总数）。
    static let shownImages = 6
}

/// 垫在网格底下的拖出锚点。`files`：按在这一张上拖出去，给哪些文件（每个带一张预览的路径，拖影用）；空 = 不拖。
struct GridDragOutAnchor: NSViewRepresentable {
    let files: (String) -> [(url: URL, preview: String)]

    final class AnchorView: NSView, NSDraggingSource {
        var files: ((String) -> [(url: URL, preview: String)])?
        /// 只给 --events-selftest：设了就不开拖放会话，改成告诉它「这时候会拖起哪一张」（离屏开拖放会话会跟着真鼠标走）。
        var startProbe: ((String) -> Void)?
        private var token: Any?
        /// 左键按在哪一张上、按下的位置（窗口坐标）。
        private var pressed: (id: String, at: NSPoint)?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        private func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            pressed = nil
        }

        /// 监听收到的每个左键事件（自检直接拿造的事件调它：离屏窗口上监听收不到假事件）。
        func handle(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown:
                pressed = nil
                guard let window, event.window === window, !isHiddenOrHasHiddenAncestor, let id = GridHover.id else { return }
                guard bounds.contains(convert(event.locationInWindow, from: nil)), !onScroller(event, in: window) else { return }
                pressed = (id, event.locationInWindow)
            case .leftMouseDragged:
                guard let press = pressed, event.window === window else { return }
                let dx = event.locationInWindow.x - press.at.x, dy = event.locationInWindow.y - press.at.y
                guard dx * dx + dy * dy >= GridDragOut.threshold * GridDragOut.threshold else { return }
                pressed = nil
                if let startProbe {
                    startProbe(press.id)
                } else {
                    startDrag(press.id, event: event)
                }
            default:
                pressed = nil
            }
        }

        /// 按在滚动条上（悬浮的滚动条盖在格子上面，GridHover 还记着底下那一格）：那是要拖滚动条。
        private func onScroller(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let content = window.contentView else { return false }
            var view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
            while let v = view {
                if v is NSScroller { return true }
                view = v.superview
            }
            return false
        }

        private func startDrag(_ id: String, event: NSEvent) {
            guard let list = files?(id), !list.isEmpty else { return }
            let p = convert(event.locationInWindow, from: nil)
            let side: CGFloat = 96
            let items: [NSDraggingItem] = list.enumerated().map { index, file in
                let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
                let shown = index < GridDragOut.shownImages
                let image: NSImage? = shown
                    ? (ThumbCache.cached(file.preview, 512) ?? NSWorkspace.shared.icon(forFile: file.url.path)) : nil
                let size = Self.fit(image?.size ?? NSSize(width: side, height: side), side: side)
                let offset = CGFloat(min(index, GridDragOut.shownImages - 1)) * 4
                let frame = NSRect(x: p.x - size.width / 2 + offset, y: p.y - size.height / 2 + offset,
                                   width: size.width, height: size.height)
                item.setDraggingFrame(frame, contents: image)
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
        }

        /// 长边缩到 side，保持比例。
        private static func fit(_ size: NSSize, side: CGFloat) -> NSSize {
            let long = max(size.width, size.height)
            guard long > 0 else { return NSSize(width: side, height: side) }
            let k = side / long
            return NSSize(width: size.width * k, height: size.height * k)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            GridDragOut.operations(for: context)
        }

        /// 按着 ⌘ / ⌥ 拖也不变成移动 / 替身：只给复制。
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.files = files
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.files = files
    }
}
