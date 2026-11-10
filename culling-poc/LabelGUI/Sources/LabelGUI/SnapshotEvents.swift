import SwiftUI
import AppKit
import MachO

// MARK: - 离屏假事件（--batch-ui / --app-ui 的 --events）
//
// 离屏快照的窗口从不显示，窗口服务器不会给它送鼠标。这里自己造 NSEvent（鼠标按下 / 抬起 / 移动；滚轮用 CGEvent 造再转
// NSEvent），放进 app 的事件队列再取出来交给那个窗口的 sendEvent —— 和真事件走同一条分派（NSApp.currentEvent 也对，
// 双击保护 ClickGuard 读的就是它）。每个事件后转一下 runloop，打印它落在哪个视图上（hitTest 的类名），最后照常截图。
//
//   --events "move:x,y;click:x,y;dblclick:x,y;rclick:x,y;scroll:x,y,dy;wait:0.2"
//
// 坐标是截图上的点：原点在左上角，x 向右、y 向下，单位 pt（截图是 1 倍的，就是像素）。
//
// 实测下来（--events-selftest 每次都在一个最小的 SwiftUI 视图上重测一遍，CI 里也跑）：
//   - click / dblclick：送得到。但 `window.sendEvent` 对没上屏的窗口不分派鼠标按下 / 抬起（事件进去就没了），所以是直接调
//     hitTest 出来的视图的 mouseDown / mouseUp。SwiftUI 的 Button、TapGesture、底下是 AppKit 控件的按钮都响。
//     SwiftUI 按真的时钟数连击：两次单击之间假鼠标会真的等过一个双击间隔（约 0.6 秒）。
//     **点击和 SDK**：上面说的是链接 macOS 15 SDK 的构建（发版、CI、照发版外观截图用的 SDKROOT=…MacOSX15.4.sdk 都是）。
//     链接 macOS 26 SDK 的构建（这台机器上不带 SDKROOT 的 `swift build`）里，SwiftUI 不再从 NSHostingView 的 mouseDown 接点击，
//     改走窗口的手势环境（NSWindow.gestureEnvironment，私有）；直接调视图、window.sendEvent、NSApp.sendEvent、让窗口自称
//     可见 / 是主窗口，试下来都送不到。所以这种构建上 click / dblclick 照发、但打印一句「送不到」，自检里点击那几条跳过不算。
//     以后发版换到 26 的 SDK，点击这一段要重做。
//   - move：窗口服务器不替离屏窗口发「进入 / 离开」，只发 mouseMoved 的话 onHover 一次都不响。这里按视图上的跟踪区
//     （NSTrackingArea）自己补进入 / 离开 / 移动，onHover 就响了、悬停才出现的按钮也画出来。
//   - scroll：造出来的滚轮事件交给落点的视图（自己接 scrollWheel 的视图收得到）；NSScrollView 不认它（带不带相位、按行按像素
//     都一样），所以它没动时直接滚它的内容，打印的那一行里会写明。
//   - rclick：不发右键按下（SwiftUI 会弹一个真菜单）。只问落点的视图「这里的右键菜单是什么」（menu(for:)），打印各项的标题；
//     .contextMenu 问得出来，菜单项点不了。
//
// 不做的：
//   - 拖放（.onDrag / .draggable / onDrop）：要系统的拖放会话（NSDraggingSession），它跟的是真鼠标、拖影画在真屏幕上。不造。
//   - 捏合、旋转、触控板手势（MagnificationGesture / magnify(with:)）：NSEvent 没有公开的构造办法。不造。
//   - 靠事件监听（NSEvent.addLocalMonitorForEvents）接鼠标的地方：监听只在 NSApp 分派真事件时才被叫到。拼图画布的 ⌘滚轮缩放
//     （CollageScrollAnchor）、画布右键菜单（CollageContextMenuAnchor）都是这样接的，--events 碰不到它们。
//   - 键盘：不在这里，用 --press（批量页网格）/ --keys（连拍挑选）。
//   - 会弹出真窗口的点击：菜单按钮、弹出框、sheet、提示框、文件选择框。点下去之前先看落点是不是弹出菜单那一类控件，
//     是就不发；另外有一道绊线（Tripwire）：一旦有菜单开始跟踪、有窗口变成可见，立刻收掉、退出码 3。
//     绊线是兜底，可能已经闪了一下 —— 这类按钮别用 --events 去点。

enum SnapshotEvents {
    enum Step: Equatable {
        case move(CGPoint)
        case click(CGPoint)
        case dblclick(CGPoint)
        case rclick(CGPoint)
        case scroll(CGPoint, dy: Double)
        case wait(Double)

        var name: String {
            switch self {
            case .move: return "move"
            case .click: return "click"
            case .dblclick: return "dblclick"
            case .rclick: return "rclick"
            case .scroll: return "scroll"
            case .wait: return "wait"
            }
        }
    }

    /// 这个可执行文件链接的 macOS SDK 的主版本号（Mach-O 的 LC_BUILD_VERSION；读不到 = 0）。
    static let linkedSDKMajor: Int = {
        guard let header = _dyld_get_image_header(0) else { return 0 }
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == UInt32(LC_BUILD_VERSION) {
                return Int(cursor.assumingMemoryBound(to: build_version_command.self).pointee.sdk >> 16)
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return 0
    }()

    /// 点击送不送得到 SwiftUI（见文件头「点击和 SDK」）。发版、CI 的构建链接的是 macOS 15 的 SDK：送得到。
    static var clicksReachSwiftUI: Bool { linkedSDKMajor > 0 && linkedSDKMajor < 26 }

    static let clickSDKNote = "这个构建链接的是 macOS \(linkedSDKMajor) 的 SDK：SwiftUI 的按钮和手势改走窗口的手势环境，离屏窗口上点击送不到"
        + "（悬停、滚动、右键菜单照常）。要验点击就照发版的办法构建：SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk swift build"

    static let usage = "--events \"move:x,y;click:x,y;dblclick:x,y;rclick:x,y;scroll:x,y,dy;wait:秒\""
        + "（坐标 = 截图上的点，左上角是原点；scroll 的 dy 正数 = 内容往下走、看到更下面；"
        + "rclick 只打印这里的右键菜单有哪几项，不弹；拖放、捏合造不出来）"

    /// "move:10,20;click:10,20;wait:0.2" → 步骤。写错了返回哪里错（调用方退出码 2，不悄悄跳过）。
    static func parse(_ spec: String) -> Result<[Step], ParseError> {
        var steps: [Step] = []
        for raw in spec.split(separator: ";") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            let numbers = pieces.count > 1
                ? pieces[1].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                : []
            guard !numbers.contains(where: { $0 == nil || !$0!.isFinite }) else {
                return .failure(ParseError(message: "「\(part)」里有不是数字的"))
            }
            let n = numbers.compactMap { $0 }
            func point() -> CGPoint { CGPoint(x: n[0], y: n[1]) }
            switch (pieces[0], n.count) {
            case ("move", 2): steps.append(.move(point()))
            case ("click", 2): steps.append(.click(point()))
            case ("dblclick", 2): steps.append(.dblclick(point()))
            case ("rclick", 2): steps.append(.rclick(point()))
            case ("scroll", 3): steps.append(.scroll(point(), dy: n[2]))
            case ("wait", 1) where n[0] >= 0 && n[0] <= 30: steps.append(.wait(n[0]))
            case ("drag", _), ("drop", _), ("pinch", _), ("magnify", _), ("rotate", _):
                return .failure(ParseError(message: "「\(pieces[0])」造不出来（拖放要系统的拖放会话、捏合没有公开的事件构造）"))
            default:
                return .failure(ParseError(message: "看不懂「\(part)」"))
            }
        }
        return .success(steps)
    }

    struct ParseError: Error, Equatable { let message: String }

    /// 命令行上的 --events：解析（写错退出码 2）。没给 = nil。
    static func fromCommandLine(_ args: [String] = CommandLine.arguments) -> [Step]? {
        guard let i = args.firstIndex(of: "--events") else { return nil }
        guard args.count > i + 1 else {
            print("用法: " + usage)
            exit(2)
        }
        switch parse(args[i + 1]) {
        case .success(let steps): return steps
        case .failure(let error):
            print("--events：\(error.message)。用法: " + usage)
            exit(2)
        }
    }

    /// 一步的结果（打印的那一行、自检断言用）。
    struct Outcome {
        let step: Step
        /// 落在哪个视图上（hitTest 的类名）；wait、没点中 = nil。
        var hit: String?
        /// rclick：这里的右键菜单各项的标题（没有菜单 = nil）。
        var menu: [String]?
        /// 没发出去的原因（落点会弹真菜单之类）。
        var refused: String?
        /// 发了，但要说明的（滚轮是直接滚的内容）。
        var note: String?

        var line: String {
            var text = "--events \(describe(step))"
            if let hit { text += " → \(hit)" }
            if let menu { text += " · 右键菜单：" + (menu.isEmpty ? "（空）" : menu.joined(separator: " | ")) }
            if case .rclick = step, menu == nil, refused == nil { text += " · 这里没有右键菜单" }
            if let note { text += " · \(note)" }
            if let refused { text += " · 没发：\(refused)" }
            return text
        }
    }

    static func describe(_ step: Step) -> String {
        func p(_ pt: CGPoint) -> String { "\(format(pt.x)),\(format(pt.y))" }
        switch step {
        case .move(let pt): return "move:\(p(pt))"
        case .click(let pt): return "click:\(p(pt))"
        case .dblclick(let pt): return "dblclick:\(p(pt))"
        case .rclick(let pt): return "rclick:\(p(pt))"
        case .scroll(let pt, let dy): return "scroll:\(p(pt)),\(format(dy))"
        case .wait(let s): return "wait:\(format(s))"
        }
    }

    static func format(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.2f", x)
    }

    // MARK: - 发事件

    /// 一个离屏窗口上的假鼠标。`host` 是窗口的 contentView（NSHostingView）。
    @MainActor
    final class Mouse {
        let window: NSWindow
        let host: NSView
        private var eventNumber = 1
        /// 指针现在在哪些跟踪区里（悬停靠它：离屏窗口不会自己收到进入 / 离开）。
        private var inside: [NSTrackingArea] = []
        private let tripwire = Tripwire()

        /// 点之前先把指针挪过去（真鼠标就是这样：悬停才出现的按钮这时已经在指针底下了）。自检找格子时关掉。
        var hoverBeforeClick = true
        /// 实验开关（--events-selftest 的对照组用）：悬停只发 mouseMoved 给窗口，不按跟踪区补进入 / 离开。
        var hoverByWindowOnly = false

        init(window: NSWindow, host: NSView) {
            self.window = window
            self.host = host
            // 三道保险，哪一道都不让它上屏：挪到所有屏幕外面、全透明；NeverShownWindow 再把 orderFront 这一类全吞掉。
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.alphaValue = 0
            tripwire.arm(allowing: window)
        }

        /// 截图坐标（左上原点）→ 窗口坐标（左下原点）。
        func windowPoint(_ p: CGPoint) -> NSPoint {
            NSPoint(x: p.x, y: host.bounds.height - p.y)
        }

        func hitView(_ p: CGPoint) -> NSView? {
            let inWindow = windowPoint(p)
            // hitTest 要父视图坐标系里的点；contentView 的父视图（主题框）和窗口同一个坐标系。
            let point = host.superview?.convert(inWindow, from: nil) ?? inWindow
            return (host.superview ?? host).hitTest(point)
        }

        static func className(_ view: NSView?) -> String {
            guard let view else { return "（没点中任何视图）" }
            // NSHostingView<ModifiedContent<…一长串…>> 只留到第一个尖括号。
            let name = String(describing: type(of: view))
            return name.firstIndex(of: "<").map { name[..<$0] + "<…>" } ?? name
        }

        /// 转一下 runloop，顺手把队列里的事件取出来分派（SwiftUI 的状态更新、动画、异步回调都在这里落下）。
        func pump(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                drain()
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            } while Date() < deadline
            drain()
        }

        private func drain() {
            // 系统发给进程的杂事件、控件自己放回队列的事件：照常交给 NSApp。
            while let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }

        /// 上一次按下是什么时候（真的时钟）。SwiftUI 的 TapGesture 按真的时间数连击，不看事件上的时间戳、也不看 clickCount
        /// （实测：隔 0.1 秒的两次单击被并成一次双击，把事件的时间戳拉开也一样）。所以两次单击之间真的等过一个双击间隔。
        private var lastDown = Date.distantPast

        private func mouseEvent(_ type: NSEvent.EventType, at p: CGPoint, clicks: Int) -> NSEvent? {
            eventNumber += 1
            return NSEvent.mouseEvent(with: type, location: windowPoint(p), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: eventNumber, clickCount: clicks, pressure: clicks > 0 ? 1 : 0)
        }

        /// 一次按下 + 抬起，直接交给落点的视图。
        ///
        /// 实测：`window.sendEvent` 对一个没上屏的窗口不分派鼠标按下 / 抬起 / 滚轮（事件进去就没了，SwiftUI 的手势、
        /// AppKit 的按钮都收不到），所以这里跳过窗口那一层，调 hitTest 出来的视图的 mouseDown / mouseUp —— 窗口本来也是这么转的。
        /// 两个细节照着真事件来：
        ///   - 事件先进 app 的队列再取出来：`NSApp.currentEvent` 才是这一下（ClickGuard 靠它认双击的第二下）。
        ///   - 抬起在调 mouseDown **之前**就放进队列：AppKit 的按钮在 mouseDown 里自己开一个循环从队列里等抬起，
        ///     队列里没有它就永远等下去。SwiftUI 的手势不开循环，mouseDown 一回来，抬起还在队列里，取出来交给同一个视图。
        private func press(_ target: NSView?, at p: CGPoint, clicks: Int) {
            if clicks == 1 {
                let gap = NSEvent.doubleClickInterval + 0.1 - Date().timeIntervalSince(lastDown)
                if gap > 0 { pump(gap) }
            }
            lastDown = Date()
            guard let target, let down = mouseEvent(.leftMouseDown, at: p, clicks: clicks),
                  let up = mouseEvent(.leftMouseUp, at: p, clicks: clicks) else { return }
            NSApp.postEvent(down, atStart: false)
            let current = NSApp.nextEvent(matching: .leftMouseDown, until: nil, inMode: .default, dequeue: true) ?? down
            NSApp.postEvent(up, atStart: false)
            target.mouseDown(with: current)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: nil, inMode: .default, dequeue: true) {
                target.mouseUp(with: pending)
            }
            drain()
        }

        @discardableResult
        func run(_ step: Step, settle: Double = 0.15) -> Outcome {
            var outcome = Outcome(step: step)
            switch step {
            case .wait(let seconds):
                pump(seconds)
                return outcome
            case .move(let p):
                move(to: p)
                outcome.hit = Self.className(hitView(p))
            case .click(let p), .dblclick(let p):
                let target = hitView(p)
                outcome.hit = Self.className(target)
                if let why = Self.opensRealWindow(target) {
                    outcome.refused = why
                    break
                }
                if hoverBeforeClick { move(to: p) }
                press(target, at: p, clicks: 1)
                if case .dblclick = step { press(hitView(p), at: p, clicks: 2) }
                // 发还是照发（落点是真的 AppKit 控件时照样响），只是把话说在前面。
                if !SnapshotEvents.clicksReachSwiftUI { outcome.note = SnapshotEvents.clickSDKNote }
            case .rclick(let p):
                // 真发右键按下，SwiftUI 会 popUp 一个真菜单（真窗口，还卡在菜单的跟踪循环里）。只问「这里的右键菜单是什么」。
                let target = hitView(p)
                outcome.hit = Self.className(target)
                move(to: p)
                if let event = mouseEvent(.rightMouseDown, at: p, clicks: 1) {
                    var view = target
                    while let v = view {
                        if let menu = v.menu(for: event) {
                            // SwiftUI 的菜单项是打开时才填的。
                            menu.update()
                            menu.delegate?.menuNeedsUpdate?(menu)
                            outcome.menu = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                            break
                        }
                        view = v.superview
                    }
                }
            case .scroll(let p, let dy):
                let target = hitView(p)
                outcome.hit = Self.className(target)
                move(to: p)
                let scroller = target?.enclosingScrollView ?? (target as? NSScrollView)
                let before = scroller?.contentView.bounds.origin
                // 直接交给落点的视图（自己接 scrollWheel 的视图在这里收到；不接的顺着响应链传到外面的 NSScrollView）。
                // 造不出事件（没有窗口服务器的环境）就只走下面直接滚内容那一步。
                if let event = scrollEvent(at: p, dy: dy) {
                    target?.scrollWheel(with: event)
                    pump(0.05)
                } else if scroller == nil {
                    outcome.refused = "造不出滚轮事件，这里也没有滚动区"
                }
                // 实测：没上屏的窗口里，NSScrollView 收到造出来的滚轮事件不滚（带不带相位、按行按像素、挂不挂窗口号都一样）。
                // 它没动就直接滚它的内容 —— 和 --scroll-test 同一个办法，滚完 SwiftUI 的 Lazy 栈照常铺新的行。
                if let scroller, let before, scroller.contentView.bounds.origin == before, let document = scroller.documentView {
                    let clip = scroller.contentView
                    let maxY = max(0, document.frame.height - clip.bounds.height)
                    let step = document.isFlipped ? dy : -dy
                    let y = min(max(before.y + step, 0), maxY)
                    if y != before.y {
                        clip.scroll(to: NSPoint(x: before.x, y: y))
                        scroller.reflectScrolledClipView(clip)
                        outcome.note = "NSScrollView 不认造出来的滚轮，直接把内容滚了 \(SnapshotEvents.format(abs(y - before.y)))pt"
                    } else {
                        outcome.note = "已经到头，没动"
                    }
                }
            }
            pump(settle)
            if let trip = tripwire.tripped {
                print("--events \(SnapshotEvents.describe(step))：\(trip)，已收掉。这类会弹真窗口的别用 --events 点")
                exit(3)
            }
            return outcome
        }

        // MARK: 悬停

        /// 把指针挪到这里：先照常发一个 mouseMoved；再自己按跟踪区补进入 / 离开 / 移动 ——
        /// 进入和离开本来是窗口服务器看着真指针发的，离屏窗口等不到。
        func move(to p: CGPoint) {
            let location = windowPoint(p)
            guard let moved = mouseEvent(.mouseMoved, at: p, clicks: 0) else { return }
            if hoverByWindowOnly {
                window.sendEvent(moved)
                drain()
                return
            }
            var now: [NSTrackingArea] = []
            func collect(_ view: NSView) {
                guard !view.isHidden else { return }
                let local = view.convert(location, from: nil)
                for area in view.trackingAreas {
                    let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                    if rect.contains(local) { now.append(area) }
                }
                view.subviews.forEach(collect)
            }
            collect(host)
            for area in inside where !now.contains(where: { $0 === area }) {
                guard area.options.contains(.mouseEnteredAndExited), let owner = area.owner as? NSResponder,
                      let event = crossing(.mouseExited, at: location, area: area) else { continue }
                owner.mouseExited(with: event)
            }
            for area in now where !inside.contains(where: { $0 === area }) {
                guard area.options.contains(.mouseEnteredAndExited), let owner = area.owner as? NSResponder,
                      let event = crossing(.mouseEntered, at: location, area: area) else { continue }
                owner.mouseEntered(with: event)
            }
            for area in now where area.options.contains(.mouseMoved) {
                (area.owner as? NSResponder)?.mouseMoved(with: moved)
            }
            inside = now
            drain()
        }

        private func crossing(_ type: NSEvent.EventType, at location: NSPoint, area: NSTrackingArea) -> NSEvent? {
            eventNumber += 1
            // trackingNumber 给跟踪区自己的地址：AppKit 按它把 event.trackingArea 找回来。
            let number = Int(bitPattern: Unmanaged.passUnretained(area).toOpaque())
            return NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: eventNumber, trackingNumber: number, userData: nil)
        }

        // MARK: 滚轮

        /// CGEvent 造（NSEvent 没有滚轮的构造办法）再转 NSEvent。dy 正数 = 看到更下面的内容（和网页的 deltaY 一个方向）。
        private func scrollEvent(at p: CGPoint, dy: Double) -> NSEvent? {
            // CGEvent 的滚轮：正数 = 内容往下挪（看到上面）；这里反过来。
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: Int32(-dy.rounded()), wheel2: 0, wheel3: 0) else { return nil }
            // 转出来的 NSEvent 不属于任何窗口（window 是 nil、locationInWindow 就是全局坐标）：把全局坐标设成窗口坐标的那个数，
            // 自己接 scrollWheel 的视图按 locationInWindow 换算时落点才对。
            let inWindow = windowPoint(p)
            let screenHeight = NSScreen.screens.first?.frame.height ?? window.frame.height
            cg.location = CGPoint(x: inWindow.x, y: screenHeight - inWindow.y)
            return NSEvent(cgEvent: cg)
        }

        // MARK: 不点的东西

        /// 点下去会弹真菜单 / 真面板的 AppKit 控件：不发。SwiftUI 的 Button 自己会不会开 sheet、文件框看不出来，靠绊线兜底。
        static func opensRealWindow(_ view: NSView?) -> String? {
            var current = view
            while let v = current {
                if v is NSPopUpButton || v is NSComboBox || v is NSColorWell || v is NSDatePicker || v is NSPathControl {
                    return "落点是 \(className(v))，点下去会弹真菜单 / 真面板"
                }
                if let segmented = v as? NSSegmentedControl,
                   (0..<segmented.segmentCount).contains(where: { segmented.menu(forSegment: $0) != nil }) {
                    return "落点是带菜单的分段控件，点下去会弹真菜单"
                }
                if let button = v as? NSButton, button.menu != nil || String(describing: type(of: button)).contains("Menu") {
                    return "落点是菜单按钮（\(className(v))），点下去会弹真菜单"
                }
                current = v.superview
            }
            return nil
        }
    }

    // MARK: - 绊线：弹出了真窗口 / 真菜单就收掉

    /// 假点击万一点到了会开菜单、sheet、提示框、文件框的按钮：菜单一开始跟踪就取消；除了离屏窗口自己以外有窗口可见、
    /// 有模态窗口，就全部收掉。定时器挂在 common modes 上，模态循环、菜单跟踪循环里也会跑。
    @MainActor
    final class Tripwire {
        private(set) var tripped: String?
        private var observers: [NSObjectProtocol] = []
        private var timer: Timer?
        private weak var allowed: NSWindow?

        func arm(allowing window: NSWindow) {
            allowed = window
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    menu?.cancelTrackingWithoutAnimation()
                    self?.trip("弹了菜单")
                }
            })
            for name in [NSWindow.willBeginSheetNotification, NSWindow.didBecomeKeyNotification, NSPopover.willShowNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sweep(because: "要弹出窗口（\(name.rawValue)）") }
                })
            }
            let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep(because: nil) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func trip(_ what: String) {
            if tripped == nil { tripped = what }
        }

        /// 有不该有的窗口就收掉；卡在模态循环里的直接退出（回不到发事件的那一行了）。
        private func sweep(because reason: String?) {
            let visible = NSApp.windows.filter { $0.isVisible }
            let modal = NSApp.modalWindow
            guard !visible.isEmpty || modal != nil || reason != nil else { return }
            for window in visible { window.orderOut(nil) }
            if let allowed, let sheet = allowed.attachedSheet { allowed.endSheet(sheet) }
            trip(reason ?? (modal != nil ? "弹了模态窗口" : "有窗口变成可见（\(visible.map { String(describing: type(of: $0)) }.joined(separator: ", "))）"))
            if modal != nil {
                NSApp.abortModal()
                print("--events：弹了模态窗口，已收掉并退出。这类会弹真窗口的别用 --events 点")
                exit(3)
            }
        }

        deinit {
            timer?.invalidate()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// 收假事件的离屏窗口：和快照用的无边框窗口一样，另外把「上屏」这一类调用全吞掉 —— AppKit 收到鼠标按下时可能想把
    /// 窗口叫到前面来，这个窗口永远不上屏。带 --events 时快照用它；不带时照旧是普通的 NSWindow（门禁的截图不变）。
    final class NeverShownWindow: NSWindow {
        override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
            if place == .out { super.order(place, relativeTo: otherWin) }
        }
        override func orderFront(_ sender: Any?) {}
        override func orderFrontRegardless() {}
        override func makeKeyAndOrderFront(_ sender: Any?) {}
        override func orderBack(_ sender: Any?) {}
    }

    /// 快照的窗口：给了 --events 就用 NeverShownWindow。
    @MainActor
    static func snapshotWindow(contentRect: NSRect, events: Bool) -> NSWindow {
        events
            ? NeverShownWindow(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
    }

    /// 一个从不显示的无边框窗口（和 --batch-ui / --app-ui 同一种）。窗口要拿着：放掉它，视图就没有窗口可画了。
    @MainActor
    static func offscreenWindow<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = snapshotWindow(contentRect: host.frame, events: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// 截一张（自检里比前后两张哪里变了）。
    @MainActor
    static func bitmap(_ host: NSView) -> NSBitmapImageRep? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 两张截图不一样的像素的外框（截图坐标，左上原点）；一样 = nil。
    static func changedRect(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGRect? {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
              let pa = a.bitmapData, let pb = b.bitmapData else { return nil }
        let bpp = max(1, a.bitsPerPixel / 8)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<a.pixelsHigh {
            let rowA = pa + y * a.bytesPerRow, rowB = pb + y * b.bytesPerRow
            if memcmp(rowA, rowB, a.pixelsWide * bpp) == 0 { continue }
            for x in 0..<a.pixelsWide where memcmp(rowA + x * bpp, rowB + x * bpp, bpp) != 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = CGFloat(a.pixelsWide) / max(1, a.size.width)
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
