import Foundation
import Combine

/// --ux-selftest 的拼图「去那儿」部分（检视器重排，2026-11-08 第二轮 B）：纯状态，不建 store、不开界面、不碰文件。
///   1. 每个 CollageSpot 只在一栏里：左栏的有托盘页签、右栏的有检视器页签，顶栏 / 底栏的两样都没有；名字不空、不重复。
///   2. nav.go：切到对的页签、只给那一栏留滚动请求（顶栏的不留）、「导出」摊开导出设置；takeScroll 只交给那一栏、取一次就没了。
///   3. 选中画布上的东西 → 右栏切到「格式」；已经在「格式」不重复设（不多发一次通知）。
///   4. --collage-ui --tab 的新名字、老名字（版式 / 文字 / 水印 / 导出）都映射到最近的位置；不认识的给 nil。
///   5. 样式页色调分「胶片 / 滤镜」两节（NU9）：两节合起来正好是全部色调、不重不漏，胶片节全是光谱色调。
/// 返回没过的条数。
@MainActor
enum CollageNavSelfTest {
    static func run() -> Int {
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if !ok { failed += 1 }
            let tail = ok ? "" : "（\(detail())）"
            print((ok ? "PASS " : "FAIL ") + "拼图去那儿：" + name + tail)
        }

        // 1. 每一块只在一栏里
        let labels = CollageSpot.allCases.map(\.label)
        check(Set(labels).count == labels.count && !labels.contains(""), "每一块都有名字、不重名", labels.joined(separator: " "))
        let misplaced = CollageSpot.allCases.filter { spot in
            switch spot.area {
            case .tray: return spot.tray == nil || spot.inspector != nil
            case .inspector: return spot.inspector == nil || spot.tray != nil
            case .bar: return spot.tray != nil || spot.inspector != nil
            }
        }
        check(misplaced.isEmpty, "左栏的有托盘页签、右栏的有检视器页签、顶栏底栏的都没有",
              misplaced.map(\.rawValue).joined(separator: ","))
        let pageOnly = CollageSpot.allCases.filter(\.needsNothingSelected)
        check(pageOnly.allSatisfy { $0.inspector == .format }, "要先取消选中的几块都在「格式」",
              pageOnly.map(\.rawValue).joined(separator: ","))

        // 2. go
        let nav = CollageNav()
        nav.go(.looks, flash: false)
        check(nav.inspectorTab == .style && nav.trayTab == .photos && nav.pendingScroll == .looks,
              "去「样式 › 色调」：右栏切到样式、左栏不动、等着滚", "\(nav.inspectorTab) \(nav.trayTab) \(String(describing: nav.pendingScroll))")
        check(nav.takeScroll(for: .tray) == nil && nav.pendingScroll == .looks, "左栏拿不走右栏的滚动请求")
        check(nav.takeScroll(for: .inspector) == .looks && nav.takeScroll(for: .inspector) == nil,
              "右栏拿一次就没了")
        nav.go(.kits, flash: false)
        check(nav.trayTab == .templates && nav.inspectorTab == .style && nav.pendingScroll == .kits,
              "去「一键成套」：左栏切到模板、右栏不动")
        _ = nav.takeScroll(for: .tray)
        nav.go(.export, flash: false)
        check(nav.exportShown && nav.pendingScroll == nil, "去「导出」：导出设置摊开，没有滚动请求")
        nav.exportShown = false
        nav.go(.watermark, flash: false)
        check(nav.inspectorTab == .document && nav.takeScroll(for: .inspector) == .watermark, "去「文档 › 水印」")
        nav.go(.contact, flash: false)
        check(nav.inspectorTab == .format && CollageSpot.contact.needsNothingSelected, "去「格式 › 印样」（要先取消选中）")
        _ = nav.takeScroll(for: .inspector)

        // 3. 选中 → 格式
        nav.inspectorTab = .document
        var publishes = 0
        let sub = nav.objectWillChange.sink { _ in publishes += 1 }
        nav.showFormat()
        check(nav.inspectorTab == .format && publishes == 1, "选中画布上的东西：右栏切到「格式」", "\(publishes)")
        nav.showFormat()
        check(publishes == 1, "已经在「格式」：不再发通知", "\(publishes)")
        sub.cancel()

        // 4. --tab
        typealias T = CollageNav.SnapshotTab
        let cases: [(String, Bool, T?)] = [
            ("格式", false, T(inspector: .format)),
            ("样式", false, T(inspector: .style)),
            ("文档", false, T(inspector: .document)),
            ("模板", false, T(tray: .templates)),
            ("素材", false, T(tray: .assets)),
            ("照片", false, T(tray: .photos)),
            ("版式", false, T(inspector: .format)),
            ("文字", false, T(inspector: .document, spot: .titles)),
            ("文字", true, T(inspector: .format)),
            ("水印", false, T(inspector: .document, spot: .watermark)),
            ("导出", false, T(export: true)),
            ("排版", false, nil),
        ]
        for (name, selected, want) in cases {
            let got = CollageNav.snapshotTab(name, hasSelection: selected)
            check(got == want, "--tab \(name)" + (selected ? "（选中了东西）" : ""), "\(String(describing: got))")
        }

        // 5. 色调分两节
        let film = CollageDarkroom.looks(in: .film)
        let filter = CollageDarkroom.looks(in: .filter)
        let all = film + filter
        check(Set(all) == Set(CollageLook.allCases) && all.count == CollageLook.allCases.count,
              "色调「胶片 / 滤镜」两节合起来正好 \(CollageLook.allCases.count) 个、不重不漏", "\(film.count) + \(filter.count)")
        check(film.allSatisfy(\.isSpectral) && !filter.contains(where: \.isSpectral) && filter.first == CollageLook.none,
              "胶片节全是光谱色调，滤镜节第一个是不调色")
        return failed
    }
}
