import SwiftUI
import AppKit

// MARK: - LabelGUI --view-prefs-selftest [<Fixtures/photot-session>]
//
// 无头拨控件不碰设置域（AppRuntime.viewDefaults；优化分析 2026-11-18 perf-ui 复核「漏-1」：以前 --events 点一下「按分组」、
// 拖一下缩略图滑杆，batch.gridMode / batch.thumbSize 就写进裸二进制的 LabelGUI 域，之后所有不传参的 --batch-ui、BatchPerf
// 都按它画，数对不上也不报错）。
//   甲. 本进程：无头时视图设置不是 UserDefaults.standard、在系统临时目录里；往里写一个键读得回来、.standard 读不到，
//       app 自己的设置域跑前跑后一样；设置域里本来就有的键（这台机器上以前存过的）透不过来（只看参数域和代码默认）。
//   乙. 给了 fixture：把自己拷一份、换个随机的名字 —— 裸二进制的设置域就是可执行文件名，于是拷贝用的是一个跑之前不存在的
//       新域：就算坏了也只写它，不碰 LabelGUI / local.culling.labelgui（临时 HOME 隔离不了：cfprefsd 照样写真的
//       ~/Library/Preferences，实测）。拷贝里真的拼出批量页，走 --events 那条路点「按分组」、点缩略图滑杆，再跑一遍
//       --perf grid（BatchPerf）。拷贝退出以后，那个新域还不存在才算过；拷贝说的「网格变成按分组、缩略图变了」也要对
//       （证明控件真拨到了、没被钉死）。坏了的话那个新域删掉再报 FAIL。
// 拷贝靠环境变量（LABELGUI_VIEW_PREFS_PROBE=1）认出自己是被拷的那个；它只在设置域确实是自己那个新名字时才拨控件。

enum ViewPrefsSelfTest {
    static let probeEnv = "LABELGUI_VIEW_PREFS_PROBE"
    static let probePrefix = "LabelGUIPrefsProbe-"

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        let fixture: URL? = args.count > flagIndex + 1 && !args[flagIndex + 1].hasPrefix("--")
            ? URL(fileURLWithPath: args[flagIndex + 1]) : nil
        if ProcessInfo.processInfo.environment[probeEnv] == "1" { probe(fixture: fixture) }
        let tally = Tally()
        local(tally)
        if let fixture {
            viaCopy(fixture: fixture, tally)
        } else {
            print("没给 fixture：拷贝里拨批量页控件、跑 --perf grid 那段没跑")
        }
        print(tally.failed == 0 ? "视图设置不碰设置域：\(tally.total) 条都过"
              : "视图设置不碰设置域：\(tally.failed)/\(tally.total) 条没过")
        exit(tally.failed == 0 ? 0 : 1)
    }

    final class Tally {
        var total = 0
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            total += 1
            if ok {
                print("PASS " + name)
            } else {
                failed += 1
                print("FAIL " + name + "：" + detail())
            }
        }
    }

    /// app 自己的设置域（裸二进制 = 可执行文件名）。
    static var prefsDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    static func describe(_ domain: [String: Any]?) -> String {
        guard let domain else { return "不存在" }
        return domain.keys.sorted().map { "\($0) = \(domain[$0] ?? "")" }.joined(separator: "，")
    }

    // MARK: 甲. 本进程

    @MainActor
    private static func local(_ tally: Tally) {
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") { tally.check(ok, name, detail()) }
        let defaults = AppRuntime.viewDefaults
        let isolated = defaults !== UserDefaults.standard
        check(isolated, "无头时视图设置（@AppStorage）用的不是 UserDefaults.standard", "就是 .standard")
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let dir = AppRuntime.headlessViewDefaultsDir.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        check(dir?.hasPrefix(tmp + "/") == true, "它落在系统临时目录里（退出时整个删掉）", dir ?? "nil")
        // 不是隔离的那份就别往里写：会写进设置域。
        guard isolated else { return }

        let domain = prefsDomain
        let before = UserDefaults.standard.persistentDomain(forName: domain)
        let key = "batch.gridMode"
        let standardBefore = UserDefaults.standard.object(forKey: key) as? NSObject
        defaults.set(BatchView.GridMode.byGroup.rawValue, forKey: key)
        check(defaults.string(forKey: key) == BatchView.GridMode.byGroup.rawValue, "写进视图设置的 \(key) 读得回来",
              defaults.string(forKey: key) ?? "nil")
        check(UserDefaults.standard.object(forKey: key) as? NSObject == standardBefore, "UserDefaults.standard 读不到它",
              "\(String(describing: UserDefaults.standard.object(forKey: key)))")
        defaults.removeObject(forKey: key)
        let after = UserDefaults.standard.persistentDomain(forName: domain)
        check(NSDictionary(dictionary: before ?? [:]).isEqual(to: after ?? [:]), "app 自己的设置域（\(domain)）跑前跑后一样",
              describe(before) + " → " + describe(after))

        // 设置域里本来就有的键透不过来（参数域、全局域里也有的除外：那两处本来就该读得到）。CI 的 runner 上这个域多半不存在，空过。
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let saved = (before ?? [:]).keys.filter { arguments[$0] == nil && global[$0] == nil }
        let leaked = saved.filter { defaults.object(forKey: $0) != nil }.sorted()
        check(leaked.isEmpty, "设置域里本来就有的 \(saved.count) 个键，视图设置一个也读不到", leaked.joined(separator: "，"))
    }

    // MARK: 乙. 拷成新名字，在拷贝里真拨控件

    @MainActor
    private static func viaCopy(fixture: URL, _ tally: Tally) {
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") { tally.check(ok, name, detail()) }
        let fm = FileManager.default
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            check(false, "找得到自己的可执行文件", "Bundle.main.executableURL 是 nil")
            return
        }
        let name = probePrefix + String(UUID().uuidString.prefix(8))
        let work = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let copy = work.appendingPathComponent(name)
        let log = work.appendingPathComponent("probe.log")
        do {
            try fm.createDirectory(at: work.appendingPathComponent("data"), withIntermediateDirectories: true)
            try fm.copyItem(at: exe, to: copy)  // APFS 上是 clonefile，不占地方
            fm.createFile(atPath: log.path, contents: nil)
        } catch {
            check(false, "把自己拷成 \(name)", error.localizedDescription)
            return
        }
        let plist = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
        let fresh = UserDefaults.standard.persistentDomain(forName: name) == nil && !fm.fileExists(atPath: plist.path)
        check(fresh, "拷贝的设置域（\(name)）跑之前不存在", describe(UserDefaults.standard.persistentDomain(forName: name)))
        guard fresh else { return }

        let process = Process()
        process.executableURL = copy
        process.arguments = ["--view-prefs-selftest", fixture.path]
        var env = ProcessInfo.processInfo.environment
        env[probeEnv] = "1"
        env["LABELGUI_DATA_DIR"] = work.appendingPathComponent("data").path
        env["LABELGUI_NO_GUI"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        guard let out = try? FileHandle(forWritingTo: log) else {
            check(false, "开得了拷贝的日志", log.path)
            return
        }
        process.standardOutput = out
        process.standardError = out
        do {
            try process.run()
        } catch {
            check(false, "起得来拷贝", error.localizedDescription)
            return
        }
        // 拷贝里 --perf grid 自己要二十来秒；CI 的虚拟机慢几倍。selftests.sh 每条限 300 秒，这里 240 秒到了先停掉它。
        let deadline = Date().addingTimeInterval(240)
        while process.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? out.close()
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            print("  │ " + line)
        }

        check(!timedOut && process.terminationReason == .exit && process.terminationStatus == 0, "拷贝跑完、退出码 0",
              timedOut ? "240 秒没跑完" : "退出码 \(process.terminationStatus)")
        check(output.contains("PROBE 网格 " + BatchView.GridMode.byGroup.rawValue),
              "拷贝里点「按分组」以后视图设置变成按分组（控件没被钉死）", "日志里没有那一行")
        check(output.contains("PROBE 缩略图 变了"), "拷贝里点缩略图滑杆以后缩略图大小变了", "日志里没有那一行")
        check(output.contains("perf 视图：" + BatchView.GridMode.byGroup.rawValue) && output.contains("perf grid：完了以后"),
              "拷贝里 --perf grid 按拨过的视图（按分组）跑完了", "日志里没有 perf 的头尾")
        // 拷贝退出以后再看（cfprefsd 是另一个进程，拷贝自己最后看的那一眼只作参考）：一个键都没写。
        let written = UserDefaults.standard.persistentDomain(forName: name)
        check(written?.isEmpty ?? true, "拷贝跑完，它的设置域（\(name)）还是空的：点控件、--perf 一个键都没写进设置域",
              describe(written))
        check(!fm.fileExists(atPath: plist.path), "~/Library/Preferences 里也没有 \(name).plist", plist.path)
        // 坏了：把拷贝写出来的那个新域删掉（只删这个随机名字的）。cfprefsd 删完域以后过一会儿还会落一个空 plist
        // （实测约在一秒内）：同步一下、等一秒再删文件。
        if written != nil || fm.fileExists(atPath: plist.path) {
            UserDefaults.standard.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            try? fm.removeItem(at: plist)
        }
    }

    // MARK: 拷贝那一头

    /// 被拷出来的那个进程：先确认自己的设置域就是自己那个新名字（不是就一个控件都不拨），再拼批量页、拨控件、跑 --perf grid。
    @MainActor
    private static func probe(fixture: URL?) -> Never {
        let name = ProcessInfo.processInfo.processName
        let domain = prefsDomain
        guard domain == name, name.hasPrefix(probePrefix), let fixture else {
            print("PROBE 不拨：设置域是 \(domain)，不是拷贝自己的新域（或者没给 fixture）")
            exit(2)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        CollageCLI.requireIsolatedDataDir("--view-prefs-selftest（拷贝）")
        // 和 --events-selftest 乙同一个办法：fixture 的 JSON 放到 store 会去找的场次目录里（没有预览图，格子是灰的）。
        let photoDir = CullMCPSelfTest.photoDir
        let sessionDir = appDataDir.appendingPathComponent("sessions/\(BatchStore.sessionKey(for: photoDir))")
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        for name in ["manifest.json", "layer1_results.json"] where !fm.fileExists(atPath: sessionDir.appendingPathComponent(name).path) {
            do {
                try fm.copyItem(at: fixture.appendingPathComponent(name), to: sessionDir.appendingPathComponent(name))
            } catch {
                print("PROBE 拷不了 fixture 的 \(name)：\(error.localizedDescription)")
                exit(2)
            }
        }
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: photoDir)
        let viewport = GridViewport()
        let size = NSSize(width: 1440, height: 900)
        let view = BatchView(store: store, viewport: viewport)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            .appTheme()
        let (window, host) = SnapshotEvents.offscreenWindow(view, size: size)
        let mouse = SnapshotEvents.Mouse(window: window, host: host)
        mouse.pump(1.5)
        let defaults = AppRuntime.viewDefaults

        func controls<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { controls(type, in: $0) }
        }
        /// 控件上按比例的一个点（fx：0 = 最左、1 = 最右），换成 --events 的截图坐标（左上原点）。
        func point(_ control: NSView, fx: Double) -> CGPoint {
            let r = control.convert(control.bounds, to: nil)
            return CGPoint(x: r.minX + r.width * fx, y: host.bounds.height - r.midY)
        }

        // 1. 顶栏「按判决 | 按分组」：先走 --events 的点击；这个构建点不到（链接 macOS 26 SDK 的那种）就用控件自己的 action ——
        //    都是经 SwiftUI 的绑定写 @AppStorage，要验的是写到哪。
        let group = BatchView.GridMode.byGroup.rawValue
        guard let seg = controls(NSSegmentedControl.self, in: host).first(where: { s in
                  (0..<s.segmentCount).contains { s.label(forSegment: $0) == group } }),
              let index = (0..<seg.segmentCount).first(where: { seg.label(forSegment: $0) == group }) else {
            print("PROBE 找不到「按判决 | 按分组」那个分段控件")
            exit(1)
        }
        let segPoint = point(seg, fx: (Double(index) + 0.5) / Double(max(1, seg.segmentCount)))
        print(mouse.run(.click(segPoint)).line)
        mouse.pump(0.5)
        if defaults.string(forKey: "batch.gridMode") != group {
            print("PROBE 点击没送到这个构建，改用分段控件自己的 action")
            seg.selectedSegment = index
            _ = seg.sendAction(seg.action, to: seg.target)
            mouse.pump(0.5)
        }
        print("PROBE 网格 " + (defaults.string(forKey: "batch.gridMode") ?? "没设"))

        // 2. 状态栏右下的缩略图滑杆：SwiftUI 的滑杆底下都是 0…1 的 NSSlider，认不出范围，认位置 —— 批量页里最靠下的那根
        //    （右栏的阈值滑杆都在上面）。点在靠右 85% 的地方。
        let sliders = controls(NSSlider.self, in: host)
        guard let slider = sliders.min(by: { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }),
              slider.convert(slider.bounds, to: nil).minY < 60 else {
            print("PROBE 找不到状态栏的缩略图滑杆")
            for s in sliders {
                print("PROBE 滑杆 \(type(of: s)) = \(s.doubleValue) · \(s.convert(s.bounds, to: nil))")
            }
            exit(1)
        }
        let thumbBefore = defaults.object(forKey: "batch.thumbSize") == nil ? 140 : defaults.double(forKey: "batch.thumbSize")
        print(mouse.run(.click(point(slider, fx: 0.85))).line)
        mouse.pump(0.5)
        if defaults.object(forKey: "batch.thumbSize") == nil {
            print("PROBE 点击没送到滑杆，改用滑杆自己的 action")
            slider.doubleValue = 0.82  // 0…1：90 + 0.82 × 170 ≈ 230
            _ = slider.sendAction(slider.action, to: slider.target)
            mouse.pump(0.5)
        }
        let thumbAfter = defaults.double(forKey: "batch.thumbSize")
        let moved = defaults.object(forKey: "batch.thumbSize") != nil && abs(thumbAfter - thumbBefore) > 1
        print("PROBE 缩略图 " + (moved ? "变了" : "没变") + String(format: "：%.1f → %.1f", thumbBefore, thumbAfter))

        // 3. --perf grid：和 --batch-ui --perf grid 同一段（按键、改判、带不带动画）。
        func spin(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        }
        BatchPerf.run("grid", store: store, viewport: viewport, spin: spin)
        let after = UserDefaults.standard.persistentDomain(forName: domain)
        print("PROBE 拷贝自己看一眼设置域（\(domain)）：" + describe(after))
        exit(0)
    }
}
