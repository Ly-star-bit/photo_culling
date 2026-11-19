import AppKit
import SwiftUI

// MARK: - LabelGUI --grid-scale-selftest
//
// 批量页网格在大场次 / 大场上的形状（优化分析 2026-11-18 批量页性能那几条）。造一场假的拍摄（FollowupSelfTest.makeDupShoot：
// 只有小文件和手写的 manifest / layer1，没有预览图 —— 格子是灰的，比例一律按 2:3），离屏拼出真的批量页（窗口从不上屏）：
//   甲. 一场 150 张（相邻 2 秒，一个场）按分组：这一场拆成一行一块（TakeShelves.splitRows），挂着的格子只有眼前那几行（以前
//       一场有几张就一次铺几格）；↓ 一路走到最后一行，每一下焦点那一格都铺出来了；从最后一行跳回中间某张、跳回第一张（AI 的
//       「给我看这几张」那条路：scrollGrid → 没铺出来 → 先滚到它那一行那一块 → 再对准这一格），都落得到。
// 只写数据目录（要临时的 LABELGUI_DATA_DIR），退出前删掉造出来的照片文件夹。
@MainActor
enum GridScaleSelfTest {
    static let flag = "--grid-scale-selftest"
    private static var failures = 0
    private static var total = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok {
            print("PASS " + what)
        } else {
            failures += 1
            let extra = detail()
            print("FAIL " + what + (extra.isEmpty ? "" : "（" + extra + "）"))
        }
    }

    static func run() -> Never {
        CollageCLI.requireIsolatedDataDir(flag, "会在数据目录里造假的拍摄")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = appDataDir.appendingPathComponent("grid-scale-selftest-" + String(UUID().uuidString.prefix(8)))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bigTake(root.appendingPathComponent("big"))
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "网格大场次自检：全部通过（\(total) 条）" : "网格大场次自检：\(failures) / \(total) 条失败")
        exit(failures == 0 ? 0 : 1)
    }

    /// 一场 n 张，相邻 2 秒（一个场），各自一个近似重复组（不去重），锐度错开（场里有一张精选）。
    private static func oneTake(_ dir: URL, count: Int) -> BatchStore {
        let start = Date(timeIntervalSince1970: 1_774_087_200)  // 2026-03-21 10:00:00 UTC，只要是同一天连着的就行
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let photos: [FollowupSelfTest.DupFake] = (0..<count).map { k in
            let id = String(format: "B%04d", k)
            let time = parser.string(from: start.addingTimeInterval(Double(2 * k)))
            return FollowupSelfTest.DupFake(id: id, file: id + ".JPG", time: time, subsec: nil, group: k,
                                            sharpness: 60 + Double((k * 37) % 40))
        }
        return FollowupSelfTest.makeDupShoot(dir, photos)
    }

    /// 离屏拼出批量页（按分组、默认缩略图），转一会儿让 Lazy 栈铺好。
    private static func host(_ store: BatchStore, viewport: GridViewport) -> SnapshotEvents.Mouse {
        AppRuntime.viewDefaults.set(BatchView.GridMode.byGroup.rawValue, forKey: "batch.gridMode")
        let size = NSSize(width: 1440, height: 900)
        let view = BatchView(store: store, viewport: viewport)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            .appTheme()
        let (window, host) = SnapshotEvents.offscreenWindow(view, size: size)
        let mouse = SnapshotEvents.Mouse(window: window, host: host)
        mouse.pump(1.5)
        return mouse
    }

    // MARK: 甲. 一个大场

    private static func bigTake(_ dir: URL) {
        print("— 甲. 一场 150 张按分组：拆成一行一块，只铺眼前几行；↓ 走到底、跳回中间和开头都落得到")
        let count = 150
        let store = oneTake(dir, count: count)
        let ids = store.items.map(\.id)
        check(store.items.count == count && store.takeRows.count == 1 && store.takeRows.first?.indices.count == count,
              "造的一场 \(count) 张是一个场", "照片 \(store.items.count) · 场 \(store.takeRows.map(\.indices.count))")
        guard store.items.count == count else { return }
        let viewport = GridViewport()
        let mouse = host(store, viewport: viewport)
        let opened = viewport.mountedCells
        check(opened > 0 && opened < count / 2, "刚打开只铺眼前几行（挂着的格子 \(opened) 个，不是整场 \(count) 个）",
              "挂着的格子 \(opened)")

        func press(_ key: String) -> String? {
            BatchPerf.keys.send(key)
            mouse.pump(0.15)
            return SnapshotPreview.gridFocus
        }
        var focus = press("→")
        var steps = 0, unmounted: [String] = [], most = viewport.mountedCells
        while steps < 60, let now = focus {
            if !viewport.isMounted(now) { unmounted.append(now) }
            most = max(most, viewport.mountedCells)
            let next = press("↓")
            steps += 1
            if next == now { break }
            focus = next
        }
        let last = focus.flatMap { ids.firstIndex(of: $0) } ?? -1
        check(steps >= 10 && last >= count - 12, "↓ 一路走到最后一行（\(steps) 下，停在第 \(last + 1) 张）",
              "焦点 \(focus ?? "无")")
        check(unmounted.isEmpty, "↓ 每一下焦点那一格都铺出来了", "没铺出来的：\(unmounted.prefix(5))")
        check(most < count / 2, "一路往下挂着的格子最多 \(most) 个（只有眼前几行，铺过的滚出去就收起来）", "最多 \(most)")

        /// AI 的「给我看这一张」（cull_show_photos 那条路）：焦点落到它、滚过去。
        func show(_ id: String) -> Bool {
            store.viewRequest = BatchStore.ViewRequest(token: UUID(), session: store.sessionDir.lastPathComponent,
                                                       ids: [id], select: false)
            mouse.pump(0.8)
            return viewport.isMounted(id)
        }
        let middle = ids[count / 2]
        let farBefore = !viewport.isMounted(middle)
        check(farBefore, "跳之前：中间那张（\(middle)）离得远、没铺出来（不然下一条验不到什么）")
        check(show(middle), "从最后一行跳回中间那张：滚到它那一行、这一格铺出来了", "挂着的 \(viewport.mountedCells) 个")
        check(show(ids[0]), "再跳回第一张：落在第一行（带组头的那一块）", "挂着的 \(viewport.mountedCells) 个")
        check(press("→") == ids[1], "跳完 → 从那张接着走（焦点跟着跳过去了）", "焦点 \(SnapshotPreview.gridFocus ?? "无")")
    }
}
