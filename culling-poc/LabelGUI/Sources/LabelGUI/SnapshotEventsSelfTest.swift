import SwiftUI
import AppKit

// MARK: - LabelGUI --events-selftest [<Fixtures/photot-session>]
//
// 离屏假事件（SnapshotEvents.swift）到底送不送得到，每次实测：
//   甲. 一个最小的 SwiftUI 视图（系统按钮、plain 按钮、单击 / 双击手势、onHover、滚动区、右键菜单），挨个发、数回调。
//   乙. 给了 fixture：真的批量页网格 —— 点一下格子焦点变到那张；悬停一格悬停条出现、挪开消失。
// 窗口从不上屏（NeverShownWindow + 挪到屏幕外 + 全透明）。

/// 最小实验的计数（视图回调往里记）。
@MainActor
final class EventProbe: ObservableObject {
    var systemButton = 0
    var plainButton = 0
    var tap = 0
    var doubleTap = 0
    var hoverIn = 0
    var hoverOut = 0
    var menuAction = 0
    @Published var hovering = false
}

struct EventProbeView: View {
    @ObservedObject var probe: EventProbe

    static let size = NSSize(width: 640, height: 420)
    static let systemButton = CGPoint(x: 90, y: 40)
    static let plainButton = CGPoint(x: 260, y: 40)
    static let tapArea = CGPoint(x: 90, y: 130)
    static let hoverArea = CGPoint(x: 260, y: 130)
    static let menuArea = CGPoint(x: 430, y: 130)
    static let scrollArea = CGPoint(x: 140, y: 300)
    static let empty = CGPoint(x: 560, y: 380)

    var body: some View {
        ZStack {
            Color(white: 0.12)
            Button("系统按钮") { probe.systemButton += 1 }
                .position(Self.systemButton)
            Button { probe.plainButton += 1 } label: {
                Text("plain 按钮").frame(width: 120, height: 40).background(Color.gray).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(Self.plainButton)
            // 和批量页的格子同一种写法：双击手势 + 同时识别的单击。
            Color.blue.frame(width: 120, height: 60)
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { probe.doubleTap += 1 })
                .simultaneousGesture(TapGesture().onEnded { probe.tap += 1 })
                .position(Self.tapArea)
            (probe.hovering ? Color.yellow : Color.green).frame(width: 120, height: 60)
                .onHover { inside in
                    if inside { probe.hoverIn += 1 } else { probe.hoverOut += 1 }
                    probe.hovering = inside
                }
                .position(Self.hoverArea)
            Color.orange.frame(width: 120, height: 60)
                .contextMenu {
                    Button("菜单甲") { probe.menuAction += 1 }
                    Button("菜单乙") { probe.menuAction += 1 }
                }
                .position(Self.menuArea)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<60, id: \.self) { i in
                        Text("第 \(i) 行").frame(width: 200, height: 30)
                    }
                }
            }
            .frame(width: 220, height: 200)
            .background(Color(white: 0.2))
            .position(Self.scrollArea)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

enum SnapshotEventsSelfTest {
    @MainActor
    final class Tally {
        var failed = 0
        var total = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            total += 1
            if ok {
                print("PASS " + name)
            } else {
                failed += 1
                print("FAIL " + name + " " + detail())
            }
        }
    }

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        NSApplication.shared.setActivationPolicy(.prohibited)
        let tally = Tally()
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") { tally.check(ok, name, detail()) }
        // 解析
        let parsed = SnapshotEvents.parse("move:10,20; click:10,20;dblclick:1.5,2;rclick:3,4;scroll:5,6,-120;wait:0.2")
        check(parsed == .success([.move(CGPoint(x: 10, y: 20)), .click(CGPoint(x: 10, y: 20)), .dblclick(CGPoint(x: 1.5, y: 2)),
                                  .rclick(CGPoint(x: 3, y: 4)), .scroll(CGPoint(x: 5, y: 6), dy: -120), .wait(0.2)]),
              "--events 解析：六种都认")
        for bad in ["click:1", "tap:1,2", "click:a,b", "drag:1,2,3,4", "pinch:1,2,1.5", "wait:99"] {
            if case .success = SnapshotEvents.parse(bad) { check(false, "--events 解析：「\(bad)」该报错") }
        }
        check(true, "--events 解析：写错的、拖放、捏合都报错，不悄悄跳过")

        probe(tally)
        if args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") {
            grid(fixture: URL(fileURLWithPath: args[flagIndex + 1]), tally)
        } else {
            print("没给 fixture：批量页网格那两条（点格子、悬停条）没跑")
        }
        print(tally.failed == 0 ? "离屏假事件自检通过：\(tally.total) 条" : "离屏假事件自检 \(tally.failed)/\(tally.total) 条没过")
        exit(tally.failed == 0 ? 0 : 1)
    }

    // MARK: 甲. 最小实验

    @MainActor
    private static func probe(_ tally: Tally) {
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") { tally.check(ok, name, detail()) }
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let s = view as? NSScrollView { return s }
            for sub in view.subviews { if let found = scrollView(sub) { return found } }
            return nil
        }

        // 对照组：悬停只发 mouseMoved 给窗口（不按跟踪区补进入 / 离开）。只打印，不断言 —— 记下系统自己送不送。
        do {
            let p = EventProbe()
            let (window, host) = SnapshotEvents.offscreenWindow(EventProbeView(probe: p), size: EventProbeView.size)
            let mouse = SnapshotEvents.Mouse(window: window, host: host)
            mouse.hoverByWindowOnly = true
            mouse.pump(0.3)
            mouse.run(.move(EventProbeView.hoverArea))
            mouse.run(.move(EventProbeView.empty))
            print("对照：只给窗口发 mouseMoved → onHover 进 \(p.hoverIn) 次、出 \(p.hoverOut) 次"
                  + (p.hoverIn == 0 ? "（系统不替离屏窗口发进入 / 离开，所以要自己按跟踪区补）" : ""))
        }

        let p = EventProbe()
        let (window, host) = SnapshotEvents.offscreenWindow(EventProbeView(probe: p), size: EventProbeView.size)
        let mouse = SnapshotEvents.Mouse(window: window, host: host)
        mouse.pump(0.3)

        // 点击：链接 macOS 15 SDK 的构建（发版、CI）必须全中；链接 26 SDK 的构建上 SwiftUI 收不到（SnapshotEvents.swift 文件头），
        // 照样发一遍、把实际结果打出来，不算过也不算没过。
        let clicks = SnapshotEvents.clicksReachSwiftUI
        func clickCheck(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if clicks {
                check(ok, name, detail())
            } else {
                print((ok ? "送到了 " : "没送到 ") + name + " " + detail())
            }
        }
        if !clicks { print("跳过点击的断言：" + SnapshotEvents.clickSDKNote) }
        let hitButton = mouse.run(.click(EventProbeView.systemButton))
        clickCheck(p.systemButton == 1, "点击 → SwiftUI 系统样式的 Button（底下是 AppKit 按钮）", "回调 \(p.systemButton) 次 · \(hitButton.line)")
        mouse.run(.click(EventProbeView.plainButton))
        clickCheck(p.plainButton == 1, "点击 → plain 样式的 Button", "回调 \(p.plainButton) 次")
        mouse.run(.click(EventProbeView.tapArea))
        clickCheck(p.tap == 1 && p.doubleTap == 0, "点击 → TapGesture（单击 1 次、双击 0 次）", "单 \(p.tap) 双 \(p.doubleTap)")
        mouse.run(.click(EventProbeView.tapArea), settle: 0.05)
        clickCheck(p.tap == 2 && p.doubleTap == 0, "紧接着再单击一次：还是单击，不被并成双击", "单 \(p.tap) 双 \(p.doubleTap)")
        let tapsBefore = p.tap
        mouse.run(.dblclick(EventProbeView.tapArea))
        clickCheck(p.doubleTap == 1, "双击 → TapGesture(count: 2)", "单 \(p.tap - tapsBefore) 双 \(p.doubleTap)")
        let counted = (p.systemButton, p.plainButton, p.tap, p.doubleTap)
        mouse.run(.click(EventProbeView.empty))
        check(counted == (p.systemButton, p.plainButton, p.tap, p.doubleTap), "点在空白处：谁都不响")

        let before = SnapshotEvents.bitmap(host)
        mouse.run(.move(EventProbeView.hoverArea))
        let during = SnapshotEvents.bitmap(host)
        check(p.hoverIn == 1 && p.hoverOut == 0 && p.hovering, "悬停 → onHover(true)", "进 \(p.hoverIn) 出 \(p.hoverOut)")
        let changed = before.flatMap { b in during.flatMap { SnapshotEvents.changedRect(b, $0) } }
        check(changed.map { $0.contains(EventProbeView.hoverArea) && $0.width <= 122 && $0.height <= 62 } ?? false,
              "悬停后重画了：截图里只有那一块变了颜色", "\(String(describing: changed))")
        mouse.run(.move(CGPoint(x: EventProbeView.hoverArea.x + 20, y: EventProbeView.hoverArea.y)))
        check(p.hoverIn == 1 && p.hoverOut == 0, "在同一块里挪：不重复进入", "进 \(p.hoverIn) 出 \(p.hoverOut)")
        mouse.run(.move(EventProbeView.empty))
        check(p.hoverIn == 1 && p.hoverOut == 1 && !p.hovering, "挪开 → onHover(false)", "进 \(p.hoverIn) 出 \(p.hoverOut)")

        let scroll = scrollView(host)
        let y0 = scroll?.contentView.bounds.origin.y ?? -1
        let hitScroll = mouse.run(.scroll(EventProbeView.scrollArea, dy: 240))
        let y1 = scroll?.contentView.bounds.origin.y ?? -1
        check(scroll != nil && abs((y1 - y0) - 240) < 1, "滚轮 → ScrollView 滚了 240pt", "\(y0) → \(y1) · \(hitScroll.line)")
        mouse.run(.scroll(EventProbeView.scrollArea, dy: -100))
        let y2 = scroll?.contentView.bounds.origin.y ?? -1
        check(abs((y2 - y1) + 100) < 1, "滚轮往回 100pt", "\(y1) → \(y2)")
        mouse.run(.scroll(EventProbeView.empty, dy: 100))
        check(scroll?.contentView.bounds.origin.y == y2, "滚轮落在滚动区外面：不滚")

        let menu = mouse.run(.rclick(EventProbeView.menuArea))
        print("右键：\(menu.line)")
        let none = mouse.run(.rclick(EventProbeView.empty))
        check(none.menu == nil, "右键落在没有菜单的地方：报没有菜单", none.line)
        check(menu.menu == ["菜单甲", "菜单乙"], "右键 → 读得到 .contextMenu 的两项（不弹）", menu.line)
        capabilities(menuWorks: menu.menu == ["菜单甲", "菜单乙"])
        check(p.menuAction == 0 && !window.isVisible && NSApp.windows.allSatisfy { !$0.isVisible },
              "全程没有窗口上过屏、没弹过菜单")
    }

    /// 实测下来的能力表（打印；--events 的用法、手点清单里的记号以它为准）。
    @MainActor
    private static func capabilities(menuWorks: Bool) {
        print("链接的 SDK：macOS \(SnapshotEvents.linkedSDKMajor)")
        print("能送到：move（按跟踪区补进入 / 离开，onHover）· scroll（事件交给落点视图；NSScrollView 不认，直接滚内容）"
              + (SnapshotEvents.clicksReachSwiftUI ? " · click / dblclick（直接交给落点视图的 mouseDown / mouseUp；Button、TapGesture、AppKit 按钮）" : ""))
        if !SnapshotEvents.clicksReachSwiftUI { print("click / dblclick：" + SnapshotEvents.clickSDKNote) }
        print(menuWorks
              ? "rclick：只读得到这里的右键菜单有哪几项（menu(for:)），不弹、也点不了菜单项"
              : "rclick：这一版系统上 .contextMenu 从 menu(for:) 问不出来 —— 等于不支持")
        print("送不到 / 不造：拖放（.onDrag / onDrop，要系统的拖放会话）· 捏合、旋转、触控板手势（没有公开的事件构造）· 靠事件监听接鼠标的地方（拼图画布的 ⌘滚轮、右键）· 会弹真窗口的按钮（菜单、sheet、文件框，绊线拦下）")
    }

    // MARK: 乙. 批量页网格

    @MainActor
    private static func grid(fixture: URL, _ tally: Tally) {
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") { tally.check(ok, name, detail()) }
        CollageCLI.requireIsolatedDataDir("--events-selftest <fixture>")
        AppUISnapshot.requireNotRealDataDir("--events-selftest <fixture>")
        // 和 --cull-mcp-selftest 同一个办法：fixture 的 JSON 放到 store 会去找的场次目录里（没有预览图，格子是灰的）。
        let photoDir = CullMCPSelfTest.photoDir
        let sessionDir = appDataDir.appendingPathComponent("sessions/\(BatchStore.sessionKey(for: photoDir))")
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        for name in ["manifest.json", "layer1_results.json"] where !fm.fileExists(atPath: sessionDir.appendingPathComponent(name).path) {
            do {
                try fm.copyItem(at: fixture.appendingPathComponent(name), to: sessionDir.appendingPathComponent(name))
            } catch {
                print("拷不了 fixture 的 \(name)：\(error.localizedDescription)")
                exit(2)
            }
        }
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: photoDir)
        let size = NSSize(width: 1440, height: 900)
        let view = BatchView(store: store, viewport: GridViewport())
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            .appTheme()
        let (window, host) = SnapshotEvents.offscreenWindow(view, size: size)
        let mouse = SnapshotEvents.Mouse(window: window, host: host)
        mouse.pump(1.5)

        // 悬停：指针挪到一格上，格子下沿冒出悬停条（★ ● ✕）；挪开就没了。左上那一片里撒点，截图比前后 ——
        // 指针下面不远多出一小条（比整个网格小得多）就是悬停条。找到的这个点下面点击也用。
        mouse.run(.move(CGPoint(x: 2, y: 2)))
        mouse.pump(0.4)
        let idle = SnapshotEvents.bitmap(host)
        func barRect(at p: CGPoint) -> CGRect? {
            mouse.run(.move(p))
            mouse.pump(0.25)
            guard let idle, let now = SnapshotEvents.bitmap(host), let rect = SnapshotEvents.changedRect(idle, now) else { return nil }
            let isBar = rect.width >= 30 && rect.width <= 400 && rect.height >= 12 && rect.height <= 120
                && abs(rect.midX - p.x) <= 250 && rect.midY >= p.y - 60 && rect.midY <= p.y + 420
            return isBar ? rect : nil
        }
        var tiles: [(point: CGPoint, bar: CGRect)] = []
        scan: for y in stride(from: 150.0, through: 700.0, by: 70.0) {
            for x in stride(from: 80.0, through: 900.0, by: 90.0) {
                let p = CGPoint(x: x, y: y)
                guard let bar = barRect(at: p) else { continue }
                // 同一格上的两个点悬停条是同一条：只留不同的格子。
                if tiles.contains(where: { $0.bar.intersects(bar) }) { continue }
                tiles.append((p, bar))
                if tiles.count == 2 { break scan }
            }
        }
        check(tiles.count == 2, "悬停一格 → 悬停条出现（截图里指针下面多出一小条）；换一格，条在另一格上",
              "只在 \(tiles.count) 格上看到悬停条")
        mouse.run(.move(CGPoint(x: 2, y: 2)))
        mouse.pump(0.4)
        let left = idle.flatMap { a in SnapshotEvents.bitmap(host).flatMap { SnapshotEvents.changedRect(a, $0) } }
        check(left == nil, "挪开 → 悬停条消失（截图和悬停之前一样）", "还不一样的范围 \(String(describing: left))")
        for tile in tiles {
            print("悬停 \(Int(tile.point.x)),\(Int(tile.point.y)) → 悬停条 x \(Int(tile.bar.minX))–\(Int(tile.bar.maxX)) · y \(Int(tile.bar.minY))–\(Int(tile.bar.maxY))")
        }
        guard tiles.count == 2 else { return }

        /// 按一下网格的键（--press 那个入口），回来读焦点。
        func press(_ key: String) -> String? {
            BatchPerf.keys.send(key)
            mouse.pump(0.12)
            return SnapshotPreview.gridFocus
        }
        // 网格的先后：从头一路按 →，按到不动为止（焦点只能从按键这个入口读）。
        var order: [String] = []
        while let id = press("→"), order.last != id, order.count < 500 { order.append(id) }
        check(order.count == store.items.count && order.count >= 8, "先用 → 走一遍，拿到网格的先后（\(order.count) 张）",
              "store 里 \(store.items.count) 张")
        guard order.count >= 8 else { return }

        /// 点一下 p 以后焦点在哪张：点完按一次 →，焦点是「被点那张的下一张」，倒推回去。点之前先把焦点停到第 park 张上
        /// （没点中格子的话，→ 是从那里走的，推出来的就是第 park 张）。点的时候不带悬停：悬停条一出来，点可能落在
        /// ★ ● ✕ 上，那是改判不是选中。两次单击之间假鼠标自己会等过一个双击间隔（不然第二下算双击、打开检视器）。
        func focusAfterClick(_ p: CGPoint, park: Int) -> String? {
            while let id = press("←"), id != order[0] {}
            for _ in 0..<park { _ = press("→") }
            mouse.hoverBeforeClick = false
            defer { mouse.hoverBeforeClick = true }
            mouse.run(.click(p))
            guard let next = press("→"), let i = order.firstIndex(of: next), i > 0 else { return nil }
            return order[i - 1]
        }
        // 两格各点两次，一次从第 6 张出发、一次从第 3 张出发：点完都落在同一张（不是出发的那张），两格落在不同的两张。
        let first = (focusAfterClick(tiles[0].point, park: 5), focusAfterClick(tiles[0].point, park: 2))
        let second = (focusAfterClick(tiles[1].point, park: 5), focusAfterClick(tiles[1].point, park: 2))
        let firstOK = first.0 != nil && first.0 == first.1
        let secondOK = second.0 != nil && second.0 == second.1 && second.0 != first.0
        let detail = "第一格 \(first.0 ?? "无") / \(first.1 ?? "无")，第二格 \(second.0 ?? "无") / \(second.1 ?? "无")"
        if SnapshotEvents.clicksReachSwiftUI {
            check(firstOK, "点一下格子 → 焦点变到那张（从两个不同的地方出发，点完都落在同一张）", detail)
            check(secondOK, "点另一个格子 → 焦点变到另一张", detail)
            check(store.overrides.isEmpty, "这些点击没有改掉任何判决", "overrides \(store.overrides.count) 条")
            if firstOK, secondOK {
                print("点 \(Int(tiles[0].point.x)),\(Int(tiles[0].point.y)) → 焦点 \(first.0 ?? "")；点 \(Int(tiles[1].point.x)),\(Int(tiles[1].point.y)) → 焦点 \(second.0 ?? "")")
            }
        } else {
            print("跳过「点一下格子焦点变到那张」的断言（\(firstOK && secondOK ? "这次送到了" : "没送到")：\(detail)）")
        }
        check(!window.isVisible && NSApp.windows.allSatisfy { !$0.isVisible }, "批量页这一段也没有窗口上过屏")
    }
}
