import AppKit
import Combine
import Darwin

/// `--collage-ui … --perf trayclick`：托盘点选（单击换一张）。每一下哪些 body 重算了几次、主线程上的活有多少，
/// 21 张的托盘和复制成 315 张的大托盘（婚礼相册的量）各来一遍；最后核对「单击换一张：网格 0 次、格子最多 2 格」。
/// 主要看指令数（进程的 ri_instructions，减掉同样空转一段的）：不随核的种类、频率变，同一份二进制几次跑差不到 2%。
/// 主线程 CPU 毫秒只作参考：离屏、不激活的进程主线程有时被放到能效核上，同一份二进制能差 3–5 倍（开了
/// latencyCritical、把主线程 QoS 设成 user-interactive 也压不住）。不量间隔：定时器被节流（CollagePerf 顶上说的那个坑）。
/// 合成鼠标事件到不了离屏窗口里的 SwiftUI 手势（窗口没上屏、进程不激活），所以「按下 / 松开到选中」等不等
/// 量不了，只能在真 app 上试。
@MainActor
extension CollagePerf {
    static func trayClicks(store: CollageStore, spin: (Double) -> Void) {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "托盘点选计时")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        spin(4)
        let idle = idleCost(spin: spin)
        print(String(format: "perf trayclick：空转 0.3 秒 进程 %.2f 百万条指令、主线程 %.2f ms（下面的都已减掉）",
                     idle.instr, idle.ms))

        var ok = clicks("托盘点选", store: store, idle: idle, spin: spin)
        if let path = store.root?.leafPaths().first {
            // 画布上选着一格：右键菜单多一项「放进选中的格子」（placeTarget 不是 nil）。
            store.selection = path
            spin(1)
            ok = clicks("选着画布一格时点托盘", store: store, idle: idle, spin: spin) && ok
            store.selection = nil
            spin(1)
        }

        // 大托盘：同一批照片复制 15 份（id 加后缀，路径不变 = 缩略图缓存命中），版式不动。
        let base = store.project
        var big = base
        big.photos = (0..<15).flatMap { k in base.photos.map { p -> CollagePhotoRef in
            var q = p
            if k > 0 { q.id = p.id + "~\(k)" }
            return q
        } }
        store.loadForTesting(big)
        store.tray.reset()
        spin(4)
        print("perf trayclick：大托盘 \(store.project.photos.count) 张")
        ok = clicks("大托盘点选", store: store, idle: idle, spin: spin) && ok
        // ⌘A 之后的第一下：多选变单选，右键菜单要换（网格重算一次、取消的那些格子都重画），之后同上。
        store.tray.selectAll(store.project.photos.map(\.id))
        spin(1)
        ok = clicks("大托盘 ⌘A 之后点选", store: store, idle: idle, spin: spin) && ok
        print((ok ? "PASS" : "FAIL") + " 单击换一张：托盘网格不重算、托盘格最多重算 2 格（选上的和取消的）")
    }

    /// 当前线程（主线程）用掉的 CPU 毫秒。
    private static func cpuMS() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    /// 整个进程到现在执行了多少条指令（百万）。后台线程空着（缩略图、预览都落下来了）时基本就是主线程的。
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

    private static let watched = ["托盘", "托盘网格", "托盘格", "拼图页", "画布", "检视器"]

    /// 依次单击前 12 张（只选它，和网格里点一下走同一个 tray.click），每下之后空转 0.3 秒让 SwiftUI 刷完。
    /// 第一下常带着「已选 N 张」那一条出现、整列重排，单列；其余取中位数。返回第 2 下起是否都只重算了该重算的。
    private static func clicks(_ label: String, store: CollageStore, idle: (instr: Double, ms: Double),
                               spin: (Double) -> Void) -> Bool {
        let tray = store.tray
        let order = tray.visible(store.project.photos, usage: store.photoUsage).map(\.id)
        var instr: [Double] = [], cpu: [Double] = []
        var counts: [[String: Int]] = []
        for id in order.prefix(12) {
            bodies = [:]
            enabled = true
            let i = instructionsM(), c = cpuMS()
            tray.click(id, command: false, shift: false, order: order)
            spin(0.3)
            instr.append(max(0, instructionsM() - i - idle.instr))
            cpu.append(max(0, cpuMS() - c - idle.ms))
            enabled = false
            counts.append(bodies)
        }
        guard counts.count > 1 else { return false }
        let restI = instr.dropFirst().sorted(), rest = cpu.dropFirst().sorted()
        print(String(format: "perf %@：%d 下 · 第 1 下 %.1f 百万条指令（主线程 %.1f ms），之后中位数 %.1f 百万条"
                     + "（%.1f–%.1f）· 主线程 %.1f ms（%.1f–%.1f）", label, instr.count, instr[0], cpu[0],
                     restI[restI.count / 2], restI.first ?? 0, restI.last ?? 0,
                     rest[rest.count / 2], rest.first ?? 0, rest.last ?? 0))
        func line(_ b: [String: Int]) -> String { watched.map { "\($0) \(b[$0] ?? 0)" }.joined(separator: " · ") }
        print("  第 1 下 body：" + line(counts[0]))
        let others = Set(counts.dropFirst().map(line))
        print("  " + (others.count == 1 ? "之后每下 body：" : "第 2 下 body：") + line(counts[1]))
        return counts.dropFirst().allSatisfy { ($0["托盘网格"] ?? 0) == 0 && ($0["托盘格"] ?? 0) <= 2 }
    }
}
