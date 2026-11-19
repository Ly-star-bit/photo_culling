import AppKit
import Combine
import Darwin
import SwiftUI

/// 批量页刷新计数（只给 `--batch-ui <photo_dir> <out.png> --perf grid` 用，照拼图托盘那套：CollagePerf、CollagePerfTray）。
/// 网格里按 → ← 和数字键（1 / 2 / 3 判决、0 恢复自动）各若干下，每一下哪个视图的 body 重算了几次、主线程 CPU 毫秒、
/// 整个进程的指令数（减掉同样空转一段的）。平常 enabled = false，body 里那一行只读一个 Bool；按键的管道界面运行时从不发。
///
/// 按键不走合成的键盘事件：离屏、不激活的窗口拿不到键盘焦点，SwiftUI 的 onKeyPress 收不到（CollagePerfTray 说的同一个坑）。
/// BatchView 在 ScrollViewReader 里订阅 `keys`，收到以后调的是真按键那一段（moveFocus、applyDigit），带着真的 proxy。
/// 指令数不随核的种类、频率变，主要看它；主线程毫秒离屏时可能落到能效核上，只作参考。数的是离屏窗口里 SwiftUI 重算了
/// 几次 —— 证明「刷新得少了」，证明不了手感（手感要在真 app 上试）。
///
/// 量多少格：测试数据只有几十张时加 `--copies 15`，先把这一场复制成几百张（expand），窗口 1440×900（默认缩略图，
/// 一屏三十来格）和 2560×1440 + `-batch.thumbSize 90`（5K 全屏的点数、最小缩略图，一屏两百多格）各跑一遍。
@MainActor
enum BatchPerf {
    static var enabled = false
    static var bodies: [String: Int] = [:]

    /// 放在 body 第一行：`let _ = BatchPerf.body("格子")`。
    static func body(_ name: String) {
        guard enabled else { return }
        bodies[name, default: 0] += 1
    }

    /// 网格按键："→" "←" "1" "2" "3" "0"。BatchView 收到后走和真按键同一段代码。
    static let keys = PassthroughSubject<String, Never>()

    /// 报告里按这个顺序列（没数到的写 0）。格子 = 网格里一格（缩略图 + 角标 + 文件名那一条），悬停条 = 包在格子外面的
    /// 悬停判决条，缩略图 = 里面的图；顶栏、状态栏、右栏是批量页 body 的一部分，单独拆成视图以后才单独数。
    /// 右键菜单 = 格子右键菜单的内容（GP-07）：只该在菜单弹出时算，按键时应该一直是 0。
    static let order = ["批量页", "顶栏", "状态栏", "右栏", "网格", "格子", "悬停条", "缩略图", "时间轴", "直方图", "右键菜单"]

    static func run(_ scenario: String, store: BatchStore, viewport: GridViewport, spin: (Double) -> Void) {
        // set = 只量「直接改判 不带动画」，连改 240 下：拿 sample 采样找这一下贵在哪时用（grid 里它只有 12 下，采不到几个样本）。
        // thresh = 右栏阈值滑杆拖一格（锐度、曝光各 12 下，PI-04）；sel = 网格里选着 3 张时按方向键（批量栏每次 body 都在，PI-06）。
        // 这两个单列，不进 grid：grid 的几行要和以前的基线（base-1.32.0/perf-batch.txt）逐行比。
        guard ["grid", "set", "thresh", "sel"].contains(scenario) else {
            print("不认识的场景（grid / set / thresh / sel）")
            return
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "批量页网格计时")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        spin(3)
        let idle = idleCost(spin: spin)
        print(String(format: "perf grid：%d 张 · 挂着的格子 %d 个 · 空转 0.3 秒 进程 %.2f 百万条指令、主线程 %.2f ms（下面的都已减掉）",
                     store.items.count, viewport.mountedCells, idle.instr, idle.ms))
        print("perf 视图：" + viewSettings())
        print("perf 动画：" + AppMotion.summary)
        // 第一下 → 从「没有焦点」落到第一张；之后每下挪一格。← 再走回来。
        let keyStep: (String) -> () -> Void = { key in { keys.send(key) } }
        if scenario == "thresh" {
            // 和滑杆的绑定同一条路：设属性 → didSet 重判。对焦滑杆一格是 5（step: 5），曝光滑杆没有格、拖一下约 0.01。来回拖。
            // 设属性那一句本身（store 同步重判 + 派生）另记一份：measure 那一行减掉它，剩下的是 SwiftUI 重画（PI-04 拆账）。
            let focus = store.focusThreshold, clip = store.exposureThreshold
            var sync: [Double] = [], rejudged: [Int] = [], fast = 0
            func timed(_ change: @escaping () -> Void) -> () -> Void {
                return {
                    let runs = store.thresholdFastPathRuns, i = instructionsM()
                    change()
                    sync.append(instructionsM() - i)
                    if store.thresholdFastPathRuns > runs {
                        fast += 1
                        rejudged.append(store.thresholdFastPathRejudged)
                    }
                }
            }
            measure("对焦滑杆一格", (0..<12).map { k in timed { store.focusThreshold = focus + (k % 2 == 0 ? 5 : 0) } },
                    idle: idle, spin: spin)
            printSync(sync, fast: fast, rejudged: rejudged)
            sync = []; rejudged = []; fast = 0
            measure("曝光滑杆一格", (0..<12).map { k in timed { store.exposureThreshold = clip + (k % 2 == 0 ? 0.01 : 0) } },
                    idle: idle, spin: spin)
            printSync(sync, fast: fast, rejudged: rejudged)
            return
        }
        if scenario == "sel" {
            keys.send("select:3")
            spin(0.5)
            measure("选着 3 张 → 键", Array(repeating: "→", count: 13).map(keyStep), idle: idle, spin: spin)
            measure("选着 3 张 ← 键", Array(repeating: "←", count: 12).map(keyStep), idle: idle, spin: spin)
            return
        }
        if scenario == "set" {
            let ids = store.items.map(\.id)
            guard !ids.isEmpty else { return }
            let all: [Verdict] = [.pick, .usable, .reject]
            measure("直接改判 不带动画", (0..<240).map { k in { quietly { store.setOverrideBatch([ids[(k * 37) % ids.count]], all[k % 3]) } } },
                    idle: idle, spin: spin)
            return
        }
        measure("→ 键", Array(repeating: "→", count: 13).map(keyStep), idle: idle, spin: spin)
        measure("← 键", Array(repeating: "←", count: 12).map(keyStep), idle: idle, spin: spin)
        // 数字键：焦点那张改判（按判决分区时它跳到别的区，焦点落到原来紧挨着的下一张）。1 2 3 轮着按。
        let digits: [Verdict] = [.pick, .usable, .reject]
        measure("数字键", (0..<12).map { keyStep(["1", "2", "3"][$0 % 3]) }, idle: idle, spin: spin, animated: true)
        // 同样改 12 张，不走按键：直接 store.setOverrideBatch，一遍套着 v1.32.0 按键那个 0.2 秒的整格挪位动画、一遍不套 —— 分得清
        // 贵的是改判本身（store 重算 + 整页重画）、按键那一套（焦点、滚动），还是动画那几帧。照网格的顺序（精选、可用、废片）
        // 从前往后各改一张。PI-01 以后 app 里默认不再套这个动画（AppMotion.reflow = nil，「数字键」那行量的是现在的样子）；
        // 「直接改判 带动画」照旧套着它：看得出改回去（AppMotion.reflow 那一行）要多花多少。
        let order = [Verdict.pick, .usable, .reject].flatMap { v in store.items.filter { $0.verdict == v }.map(\.id) }
        let targets = Array(order.prefix(24))
        func setStep(_ k: Int, animated: Bool) -> () -> Void {
            let id = targets[k % max(1, targets.count)], verdict = digits[k % 3]
            return {
                if animated {
                    withAnimation(.easeInOut(duration: 0.2)) { store.setOverrideBatch([id], verdict) }
                } else {
                    quietly { store.setOverrideBatch([id], verdict) }
                }
            }
        }
        // 场次里一张照片都没有就不量这两组（targets 空着取下标会崩）。
        if !targets.isEmpty {
            measure("直接改判 带动画", (0..<12).map { setStep($0, animated: true) }, idle: idle, spin: spin, animated: true)
            measure("直接改判 不带动画", (12..<24).map { setStep($0, animated: false) }, idle: idle, spin: spin)
        }
        print("perf grid：完了以后 \(store.manualOverrideCount) 张人工改判 · 挂着的格子 \(viewport.mountedCells) 个")
    }

    /// thresh 那两行的拆账：设属性那一句（store 同步重判 + 派生）之后几下的中位数（和 measure 一样不算第 1 下），快路径走了几下、
    /// 每下重判了几张（BatchStore.applyThresholdChange）。拆成几句拼：一长串格式化在 CI 的 Xcode 16 上类型检查慢。
    private static func printSync(_ sync: [Double], fast: Int, rejudged: [Int]) {
        let rest = sync.dropFirst().sorted()
        guard !rest.isEmpty else { return }
        let r = rejudged.sorted()
        let head: String = String(format: "  其中设属性那一句（store 重判 + 派生，同步）之后中位数 %.1f 百万条（%.1f–%.1f）",
                                  rest[rest.count / 2], rest.first ?? 0, rest.last ?? 0)
        let tail = "，快路径 \(fast) / \(sync.count) 下，每下重判中位数 \(r.isEmpty ? 0 : r[r.count / 2]) 张"
        print(head + tail)
    }

    /// 真的不带动画地改：PI-01 以后格子的判决色有 0.15 秒的过渡（隐式动画，AppMotion.verdictFade），改的那张在屏上时离屏
    /// 不限帧率地画它，「不带动画」那 0.3 秒的合计就成了「主线程忙满了」（一场 300 张、改的就在眼前时 1.7G，减少动态效果开着
    /// 0.17G）。以前改的多半不在屏上（照网格的先后挑的），看不出来。
    private static func quietly(_ change: () -> Void) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet, change)
    }

    /// 量的时候网格是什么样（数跟着它走：按分组比按判决贵、缩略图越小一屏格子越多）。读的是视图设置（AppRuntime.viewDefaults）：
    /// 无头时只有命令行 `-batch.gridMode` / `-batch.thumbSize` 和这一次 --events 拨过的，不会是以前哪次留在设置域里的。
    static func viewSettings() -> String {
        let defaults = AppRuntime.viewDefaults
        let mode = defaults.string(forKey: "batch.gridMode") ?? (BatchView.GridMode.byVerdict.rawValue + "（默认）")
        let thumb: String = defaults.object(forKey: "batch.thumbSize") == nil
            ? "140（默认）" : String(format: "%.1f", defaults.double(forKey: "batch.thumbSize"))
        return mode + " · 缩略图 " + thumb
    }

    /// `--copies N`：这一场的 manifest、layer1 每张复制成 N 份再读一遍（量刷新要几百张，测试数据只有几十张）。id 加 `_cNN`
    /// 后缀（第 0 份不变），原图、预览路径不变（缩略图缓存按路径命中）；第 k 份的拍摄时间整体往后挪 k 小时、近似重复组号错开，
    /// 章节、场照常切，不会把 N 份并成一场。改的是临时数据目录里这一场的文件（--batch-ui 本来就只在临时数据目录里跑）。
    static func expand(_ store: BatchStore, copies: Int) {
        guard copies > 1 else { return }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func shifted(_ value: Any?, hours: Int) -> Any? {
            guard let text = value as? String, let date = parser.date(from: text) else { return value }
            return parser.string(from: date.addingTimeInterval(Double(hours) * 3600))
        }
        func rewrite(_ name: String, rows key: String, _ copy: ([String: Any], Int) -> [String: Any]) {
            let url = store.sessionDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json[key] as? [[String: Any]] else { return }
            json[key] = (0..<copies).flatMap { k in rows.map { copy($0, k) } }
            if let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
                try? out.write(to: url, options: .atomic)
            }
        }
        func renamed(_ row: [String: Any], _ k: Int) -> [String: Any] {
            var row = row
            if k > 0, let id = row["id"] as? String { row["id"] = id + String(format: "_c%02d", k) }
            if let time = shifted(row["capture_time"], hours: k) { row["capture_time"] = time }
            return row
        }
        rewrite("manifest.json", rows: "photos", renamed)
        let groups = store.items.map(\.burstGroup).max().map { $0 + 1 } ?? 0
        rewrite("layer1_results.json", rows: "results") { row, k in
            var row = renamed(row, k)
            if let group = row["burst_group"] as? Int { row["burst_group"] = group + k * groups }
            return row
        }
        store.loadResults()
        store.applyThresholds()
    }

    /// 当前线程（主线程）用掉的 CPU 毫秒。
    private static func cpuMS() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    /// 整个进程到现在执行了多少条指令（百万）。后台线程空着（缩略图都落下来了）时基本就是主线程的。
    /// nonisolated：run loop 观察者（BatchPerfLoops）的回调里也要调。
    nonisolated static func instructionsM() -> Double {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Double(info.ri_instructions) / 1e6 : 0
    }

    /// 空转 0.3 秒的指令数、主线程毫秒（各取 5 遍的中位数，下面每一下都减掉它）；另外挂着 run loop 观察者再空转一遍，
    /// 看空转时一圈最多多少指令 —— 带动画那两行数「之后有活的圈」时，比它多 4 倍（至少 0.5 百万条）的才算一帧。
    struct Idle {
        var instr: Double
        var ms: Double
        var busyPass: Double
    }

    private static func idleCost(spin: (Double) -> Void) -> Idle {
        var instr: [Double] = [], ms: [Double] = []
        for _ in 0..<5 {
            let i = instructionsM(), c = cpuMS()
            spin(0.3)
            instr.append(instructionsM() - i)
            ms.append(cpuMS() - c)
        }
        let loops = BatchPerfLoops()
        let base = instructionsM()
        loops.start()
        spin(0.3)
        loops.stop()
        let passes = loops.passes(from: base)
        let idlePass = ([passes.first] + passes.rest).max() ?? 0
        return Idle(instr: instr.sorted()[instr.count / 2], ms: ms.sorted()[ms.count / 2], busyPass: max(0.5, 4 * idlePass))
    }

    /// 带动画那两行假设真屏上一下改判画几帧：改判动画 0.2 秒（BatchView.applyDigit、悬停条点判决都是 easeInOut 0.2），
    /// 120 Hz 的屏 24 帧、60 Hz 的屏 12 帧。
    static let framesAt120Hz = 24
    static let framesAt60Hz = 12

    /// 依次做这些步（按一个键、改一张），每步之后空转 0.3 秒让 SwiftUI 刷完（滚动、改判的动画 0.2 秒）。第一下单列，
    /// 其余取中位数和范围。
    ///
    /// animated = 这一下带改判动画（数字键、直接改判 带动画）：那 0.3 秒的合计量的不是这一下的活。离屏窗口没有垂直同步，
    /// 动画一圈 run loop 画一帧、一圈接一圈地画，0.3 秒里画了几十到几百帧，合计只说明「主线程这 0.3 秒忙满了」，跟着机器快慢走
    /// （优化分析 2026-11-18 PI-01 / PI-02：同一场景三次 2510 / 2660 / 3770 百万条）。所以这两行的头一个数改成**估计**：
    /// 首圈（这一下本身 + 第一帧）+ 之后每帧中位数 × 真屏上的帧数（120 Hz 24 帧；60 Hz 的 12 帧另报），按 run loop 观察者
    /// 一圈一圈记的指令数算；0.3 秒的合计挪到下一行，只作参考。
    private static func measure(_ label: String, _ steps: [() -> Void], idle: Idle,
                                spin: (Double) -> Void, animated: Bool = false) {
        var instr: [Double] = [], cpu: [Double] = []
        var counts: [[String: Int]] = []
        /// 带动画时每一下的首圈、之后有活的那几圈。
        var firsts: [Double] = [], frames: [[Double]] = []
        let loops = BatchPerfLoops()
        for step in steps {
            bodies = [:]
            enabled = true
            let i = instructionsM(), c = cpuMS()
            if animated { loops.start() }
            step()
            spin(0.3)
            if animated { loops.stop() }
            instr.append(max(0, instructionsM() - i - idle.instr))
            cpu.append(max(0, cpuMS() - c - idle.ms))
            enabled = false
            counts.append(bodies)
            if animated {
                let passes = loops.passes(from: i)
                firsts.append(passes.first)
                frames.append(passes.rest.filter { $0 > idle.busyPass })
            }
        }
        guard counts.count > 1 else { return }
        let restI = instr.dropFirst().sorted(), rest = cpu.dropFirst().sorted()
        let total = String(format: "第 1 下 %.1f 百万条指令（主线程 %.1f ms），之后中位数 %.1f 百万条"
                           + "（%.1f–%.1f）· 主线程 %.1f ms（%.1f–%.1f）", instr[0], cpu[0],
                           restI[restI.count / 2], restI.first ?? 0, restI.last ?? 0,
                           rest[rest.count / 2], rest.first ?? 0, rest.last ?? 0)
        if animated {
            printEstimate(label, steps: instr.count, firsts: firsts, frames: frames)
            print("  0.3 秒忙转合计（离屏不限帧率，跟着机器快慢走，只作参考、别拿来比）：" + total)
        } else {
            print("perf \(label)：\(instr.count) 下 · " + total)
        }
        func line(_ b: [String: Int]) -> String { order.map { "\($0) \(b[$0] ?? 0)" }.joined(separator: " · ") }
        print("  第 1 下 body：" + line(counts[0]))
        // 之后每一下的中位数（每个视图各取各的）。
        let median = Dictionary(uniqueKeysWithValues: order.map { name -> (String, Int) in
            let v = counts.dropFirst().map { $0[name] ?? 0 }.sorted()
            return (name, v[v.count / 2])
        })
        let most = Dictionary(uniqueKeysWithValues: order.map { name in
            (name, counts.dropFirst().map { $0[name] ?? 0 }.max() ?? 0)
        })
        print("  之后每下 body 中位数：" + line(median))
        print("  之后每下 body 最多：" + line(most))
    }

    /// 带动画那一行：估计真屏上这一下要多少指令 = 首圈 + 这一下之后每帧的中位数 × 帧数（帧数取 24 和离屏实际画了几帧里
    /// 小的那个）。和别的行同一个样子：第 1 下单列，之后取中位数和范围；下面再列每一下各自的估计（数字键 1 2 3 轮着按，
    /// 按 3 挪的格子多、每帧贵，看得出来）。拆成几句拼：一长串格式化在 CI 的 Xcode 16 上类型检查慢。
    private static func printEstimate(_ label: String, steps: Int, firsts: [Double], frames: [[Double]]) {
        func median(_ v: [Double]) -> Double {
            let sorted = v.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        func estimate(_ k: Int, _ frameCount: Int) -> Double {
            firsts[k] + median(frames[k]) * Double(min(frameCount, frames[k].count))
        }
        let ks = Array(1..<firsts.count)
        let rest120 = ks.map { estimate($0, framesAt120Hz) }.sorted()
        let est60 = median(ks.map { estimate($0, framesAt60Hz) })
        let first = median(ks.map { firsts[$0] })
        let perFrame = median(ks.map { median(frames[$0]) })
        let passes = median(ks.map { Double(frames[$0].count) })
        let head: String = String(format: "perf %@：%d 下 · 估计真机：第 1 下 %.1f 百万条（首圈 %.1f），之后中位数 %.1f 百万条（%.1f–%.1f）",
                                  label, steps, estimate(0, framesAt120Hz), firsts[0],
                                  median(rest120), rest120.first ?? 0, rest120.last ?? 0)
        let parts: String = String(format: " = 首圈 %.1f + 每帧 %.1f × %d 帧（120 Hz 下 0.2 秒的动画；60 Hz × %d 帧 ≈ %.1f）",
                                   first, perFrame, framesAt120Hz, framesAt60Hz, est60)
        print(head + parts)
        let each: [String] = (0..<firsts.count).map { k in
            String(format: "%.0f+%.1f×%d", firsts[k], median(frames[k]), min(framesAt120Hz, frames[k].count))
        }
        print("  各下估计（首圈+每帧×帧数）：" + each.joined(separator: " · "))
        print(String(format: "  估计的依据：离屏 0.3 秒里之后有活的圈中位数 %.0f 圈（真屏 0.2 秒最多 %d 帧），", passes, framesAt120Hz)
              + "首圈 = 这一下本身 + 第一帧；是估计，不是实测（离屏没有垂直同步）")
    }
}

/// 主线程 run loop 每走到一次 beforeWaiting / exit 记一下进程指令数（BatchPerf 带动画那两行用）。Core Animation 在这两处提交
/// 一帧，它的观察者排在前面，这里排在最后（order 最大）：记的是这一帧提交完以后的数。两次之间就是一圈 = 离屏的一帧。
/// 不放在 BatchPerf 里：BatchPerf 是 @MainActor，观察者的回调是普通闭包。
final class BatchPerfLoops {
    private(set) var marks: [Double] = []
    private var observer: CFRunLoopObserver?

    func start() {
        marks.removeAll(keepingCapacity: true)
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { [weak self] _, _ in
            self?.marks.append(BatchPerf.instructionsM())
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
    }

    /// 首圈（start 之前记的 base → 第一次记）和之后每圈各多少百万条。
    func passes(from base: Double) -> (first: Double, rest: [Double]) {
        guard let first = marks.first else { return (0, []) }
        return (first - base, zip(marks.dropFirst(), marks).map { $0 - $1 })
    }
}
