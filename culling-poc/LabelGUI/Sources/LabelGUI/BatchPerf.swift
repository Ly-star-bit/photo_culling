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
    static let order = ["批量页", "顶栏", "状态栏", "右栏", "网格", "格子", "悬停条", "缩略图", "时间轴", "直方图"]

    static func run(_ scenario: String, store: BatchStore, viewport: GridViewport, spin: (Double) -> Void) {
        guard scenario == "grid" else {
            print("不认识的场景（grid）")
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
        // 第一下 → 从「没有焦点」落到第一张；之后每下挪一格。← 再走回来。
        let keyStep: (String) -> () -> Void = { key in { keys.send(key) } }
        measure("→ 键", Array(repeating: "→", count: 13).map(keyStep), idle: idle, spin: spin)
        measure("← 键", Array(repeating: "←", count: 12).map(keyStep), idle: idle, spin: spin)
        // 数字键：焦点那张改判（按判决分区时它跳到别的区，焦点落到原来紧挨着的下一张）。1 2 3 轮着按。
        let digits: [Verdict] = [.pick, .usable, .reject]
        measure("数字键", (0..<12).map { keyStep(["1", "2", "3"][$0 % 3]) }, idle: idle, spin: spin)
        // 同样改 12 张，不走按键：直接 store.setOverrideBatch，一遍套着按键那个 0.2 秒的改判动画、一遍不套 —— 分得清
        // 贵的是改判本身（store 重算 + 整页重画）、按键那一套（焦点、滚动），还是动画那几帧。照网格的顺序（精选、可用、废片）
        // 从前往后各改一张。
        let order = [Verdict.pick, .usable, .reject].flatMap { v in store.items.filter { $0.verdict == v }.map(\.id) }
        let targets = Array(order.prefix(24))
        func setStep(_ k: Int, animated: Bool) -> () -> Void {
            let id = targets[k % max(1, targets.count)], verdict = digits[k % 3]
            return {
                if animated {
                    withAnimation(.easeInOut(duration: 0.2)) { store.setOverrideBatch([id], verdict) }
                } else {
                    store.setOverrideBatch([id], verdict)
                }
            }
        }
        // 场次里一张照片都没有就不量这两组（targets 空着取下标会崩）。
        if !targets.isEmpty {
            measure("直接改判 带动画", (0..<12).map { setStep($0, animated: true) }, idle: idle, spin: spin)
            measure("直接改判 不带动画", (12..<24).map { setStep($0, animated: false) }, idle: idle, spin: spin)
        }
        print("perf grid：完了以后 \(store.manualOverrideCount) 张人工改判 · 挂着的格子 \(viewport.mountedCells) 个")
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
    private static func instructionsM() -> Double {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Double(info.ri_instructions) / 1e6 : 0
    }

    private static func idleCost(spin: (Double) -> Void) -> (instr: Double, ms: Double) {
        var instr: [Double] = [], ms: [Double] = []
        for _ in 0..<5 {
            let i = instructionsM(), c = cpuMS()
            spin(0.3)
            instr.append(instructionsM() - i)
            ms.append(cpuMS() - c)
        }
        return (instr.sorted()[instr.count / 2], ms.sorted()[ms.count / 2])
    }

    /// 依次做这些步（按一个键、改一张），每步之后空转 0.3 秒让 SwiftUI 刷完（滚动、改判的动画 0.2 秒）。第一下单列，
    /// 其余取中位数和范围。
    private static func measure(_ label: String, _ steps: [() -> Void], idle: (instr: Double, ms: Double),
                                spin: (Double) -> Void) {
        var instr: [Double] = [], cpu: [Double] = []
        var counts: [[String: Int]] = []
        for step in steps {
            bodies = [:]
            enabled = true
            let i = instructionsM(), c = cpuMS()
            step()
            spin(0.3)
            instr.append(max(0, instructionsM() - i - idle.instr))
            cpu.append(max(0, cpuMS() - c - idle.ms))
            enabled = false
            counts.append(bodies)
        }
        guard counts.count > 1 else { return }
        let restI = instr.dropFirst().sorted(), rest = cpu.dropFirst().sorted()
        print(String(format: "perf %@：%d 下 · 第 1 下 %.1f 百万条指令（主线程 %.1f ms），之后中位数 %.1f 百万条"
                     + "（%.1f–%.1f）· 主线程 %.1f ms（%.1f–%.1f）", label, instr.count, instr[0], cpu[0],
                     restI[restI.count / 2], restI.first ?? 0, restI.last ?? 0,
                     rest[rest.count / 2], rest.first ?? 0, rest.last ?? 0))
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
}
