import Foundation
import Combine
import Darwin

/// 拼图页刷新计数（只给 `--collage-ui … --perf <场景>` 用）：一个操作下来，哪个视图的 body 重算了几次、
/// store 和预览、缩略图对象各发了几次 objectWillChange、出了几张预览。
/// 平常 enabled = false，body 里那一行只读一个 Bool。
/// 数的是离屏窗口里 SwiftUI 重算了几次 —— 证明「刷新得少了」，证明不了手感（手感要在真 app 上试）。
/// 不量主线程卡顿：离屏、不激活的进程定时器被系统节流，量出来的间隔是节流不是卡（sample 看主线程 98% 在等）。
/// 拖缝、滑杆、裁切平移这几个一下一下拖的场景另报活有多少（行尾「主线程 … 百万条指令」）：主线程自己的指令数
/// （thread_selfcounts，后台渲预览、解缩略图的不算在里面）、主线程 CPU、整个进程的指令数，都是 30 下合计和每下平均。
/// 每下隔的那一帧里 SwiftUI 整个刷一遍，所以「每下」是每帧的上限（真鼠标 120 Hz 拖动时几下会合到一帧里）。
@MainActor
enum CollagePerf {
    static var enabled = false
    /// 托盘点选那套（CollagePerfTray）每一下自己清零。
    static var bodies: [String: Int] = [:]
    /// 拖的那一段（不含场景开头的准备）用掉的活和下数：step 里量，run 打在行尾。
    private static var measured: (cost: Cost, steps: Int)?

    /// 一段时间里用掉的活：主线程指令（百万；取不到 = nil）、主线程 CPU 毫秒、整个进程的指令（百万）。
    struct Cost {
        var main: Double?
        var cpu: Double
        var process: Double

        static func -(a: Cost, b: Cost) -> Cost {
            Cost(main: a.main.flatMap { x in b.main.map { x - $0 } }, cpu: a.cpu - b.cpu, process: a.process - b.process)
        }

        func line(steps: Int) -> String {
            let n = Double(max(1, steps))
            let mainText = main.map { String(format: "%.0f 百万条指令（每下 %.1f）", $0, $0 / n) } ?? "— 百万条指令"
            return " · 主线程 " + mainText
                + String(format: "、CPU %.0f ms（每下 %.1f）· 进程 %.0f 百万条（每下 %.1f）", cpu, cpu / n, process, process / n)
        }
    }

    /// 当前线程执行了多少条指令（百万）：libsystem_kernel 的 thread_selfcounts（没有公开头文件，dlsym 取；
    /// 取不到、调用失败 = nil）。只算这一个线程：后台渲预览、解缩略图的不算 —— 拖动跟不跟手看的是主线程。
    static func threadInstructionsM() -> Double? {
        guard let fn = threadSelfCounts else { return nil }
        var counts: (UInt64, UInt64) = (0, 0)   // 指令、周期（THSC_CPI = 1）
        let rc = withUnsafeMutableBytes(of: &counts) { fn(1, $0.baseAddress, $0.count) }
        return rc == 0 ? Double(counts.0) / 1e6 : nil
    }

    private typealias SelfCounts = @convention(c) (Int32, UnsafeMutableRawPointer?, Int) -> Int32
    private static let threadSelfCounts: SelfCounts? = {
        // RTLD_DEFAULT = (void *)-2（宏，Swift 里取不到）。
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "thread_selfcounts") else { return nil }
        return unsafeBitCast(sym, to: SelfCounts.self)
    }()

    /// 拖的那一段从这里量起（场景开头的准备做完以后），到 `endMeasure` 为止。
    private static func costNow() -> Cost { Cost(main: threadInstructionsM(), cpu: cpuMS(), process: instructionsM()) }
    private static func beginMeasure() -> Cost { costNow() }
    private static func endMeasure(_ start: Cost, steps: Int) { measured = (costNow() - start, steps) }

    /// 放在 body 第一行：`let _ = CollagePerf.body("托盘")`。
    static func body(_ name: String) {
        guard enabled else { return }
        bodies[name, default: 0] += 1
    }

    /// 报告里按这个顺序列（没数到的写 0）。
    static let order = ["拼图页", "托盘", "托盘网格", "托盘格", "画布", "叠加层", "检视器", "格式面板", "样式面板", "文档面板",
                        "模板页", "模板库", "模板格", "素材页", "备选条", "页条", "方案条"]

    /// 跑一个场景：settle 之后清零、跑、再等 `tail` 秒让后台的缩略图、预览都落下来，打印一行。
    /// spin 是快照那边的同一个（跑主线程 run loop）。
    static func run(_ scenario: String, store: CollageStore, spin: (Double) -> Void) {
        // 托盘点选单独一套（每一下分开报、托盘大小两档）：CollagePerfTray。
        if scenario == "trayclick" { return trayClicks(store: store, spin: spin) }
        // 暗房里拖滑杆、悬停：CollagePerfDarkroom。
        if scenario == "darkroom" { return darkroomScenario(store: store, spin: spin) }
        let names = scenario == "all" ? ["place", "gutter", "slider", "title"] : [scenario]
        for name in names {
            spin(1.5)
            var publishes = 0, previewPublishes = 0, thumbPublishes = 0
            var scales: [Double] = []
            let subs = [
                store.objectWillChange.sink { _ in publishes += 1 },
                store.previewState.objectWillChange.sink { _ in previewPublishes += 1 },
                store.thumbs.objectWillChange.sink { _ in thumbPublishes += 1 },
                store.previewState.$scale.dropFirst().sink { scales.append($0) },
            ]
            bodies = [:]
            measured = nil
            enabled = true
            let note = step(name, store: store, spin: spin)
            spin(3)
            enabled = false
            subs.forEach { $0.cancel() }
            let counts = order.map { "\($0) \(bodies[$0] ?? 0)" }.joined(separator: " · ")
            print("perf \(name)：\(note) · store 发 \(publishes) 次 · 预览对象 \(previewPublishes) · 缩略图对象 \(thumbPublishes)"
                  + " · body \(counts) · 出了 \(scales.count) 张预览" + (measured.map { $0.cost.line(steps: $0.steps) } ?? ""))
        }
    }

    /// 场景开头的准备（存方案、进裁切）做完、等界面刷完以后，计数从零数起（准备那几下的刷新不算在拖动里）。
    private static func settle(_ spin: (Double) -> Void) {
        spin(1.5)
        bodies = [:]
    }

    /// 拖缝 30 下、每下隔 16 ms（一帧）。gutter 和 variant 共用。
    private static func dragGutter(_ store: CollageStore, spin: (Double) -> Void) -> String {
        guard let g = store.geometry.gutters.first else { return "没有缝" }
        let start = beginMeasure()
        store.beginContinuousEdit()
        for i in 0..<30 {
            store.setRatio(0.35 + Double(i) * 0.01, at: g.path)
            spin(0.016)
        }
        store.endContinuousEdit()
        endMeasure(start, steps: 30)
        return "缝 \(g.path.map(String.init).joined()) 拖 30 下"
    }

    private static func step(_ name: String, store: CollageStore, spin: (Double) -> Void) -> String {
        switch name {
        case "place":
            // 托盘里一张还没上这一页的照片放进第一格（换照片：模板缩略图要重渲）。
            guard let root = store.root, let path = root.leafPaths().first,
                  let photo = store.project.photos.first(where: { !(store.page?.photoIDs ?? []).contains($0.id) })
            else { return "没有可放的照片" }
            store.selection = path
            store.place(photoID: photo.id, at: path, edge: nil)
            return "\(photo.id) 放进 \(path.map(String.init).joined())"
        case "gutter":
            // 拖一条缝：30 下、每下隔 16 ms（一帧）。
            return dragGutter(store, spin: spin)
        case "variant":
            // 先存一个方案（方案栏有一张卡片、描着蓝边），再拖缝 30 下：第一下起方案名后面标「改过」、蓝边去掉，
            // 之后每下方案栏都不该再变。
            guard case .saved(let v) = store.saveVariant() else { return "存不了方案" }
            settle(spin)
            let note = dragGutter(store, spin: spin)
            let marked = store.activeVariantID == v.id && store.activeVariantModified
            return "存了「\(v.name)」再" + note + " · 改过 " + (marked ? "标上了" : "没标上")
        case "variants":
            // 方案栏上 8 个方案（每存一个改一下边距，各不相同）再拖缝 30 下：比着挑的时候存好几个是常事。
            for i in 0..<8 {
                var st = store.project.style
                st.margin = 0.02 + Double(i) * 0.005
                store.setStyle(st, coalesce: false)
                store.saveVariant()
            }
            settle(spin)
            return "方案栏 \(store.variants.count) 个再" + dragGutter(store, spin: spin)
        case "bigtray":
            // 婚礼相册那么大的托盘（同一批照片复制 15 份 = 315 张，同 trayclick 的大托盘）再拖缝 30 下。
            let base = store.project
            var big = base
            big.photos = (0..<15).flatMap { k in base.photos.map { p -> CollagePhotoRef in
                var q = p
                if k > 0 { q.id = p.id + "~\(k)" }
                return q
            } }
            store.loadForTesting(big)
            spin(4)
            settle(spin)
            return "托盘 \(store.project.photos.count) 张、" + dragGutter(store, spin: spin)
        case "pan":
            // 拖照片：双击进裁切以后在格子里拖着挪取景（画布的 .pan 走 setCrop，每下改一次工程）：30 下、每下隔 16 ms。
            // 拖着整格照片去换位置（.move）不改工程（落点画在画布自己的 @State 里，指着跨页条时只改 albumUI），不用量。
            guard let f = store.geometry.frames.first(where: { $0.cell.photoID != nil }) else { return "没有照片格" }
            store.enterCropEdit(f.path)
            guard let base = store.cropBaseline(for: f) else { return "取不到取景" }
            settle(spin)
            let zoom = max(1.5, base.zoom)
            let start = beginMeasure()
            for i in 0..<30 {
                store.setCrop(CollageCropOverride(cx: base.cx - 0.1 + Double(i) * 0.007, cy: base.cy, zoom: zoom), at: f.path)
                spin(0.016)
            }
            endMeasure(start, steps: 30)
            store.exitCropEdit()
            return "格子 \(f.path.map(String.init).joined()) 里平移 30 下"
        case "slider":
            // 拖样式滑杆（边距）：30 下、每下隔 16 ms，和检视器滑杆一样 coalesce。
            let start = beginMeasure()
            for i in 0..<30 {
                var st = store.project.style
                st.margin = 0.02 + Double(i) * 0.001
                store.setStyle(st, coalesce: true)
                spin(0.016)
            }
            endMeasure(start, steps: 30)
            return "边距滑杆 30 下"
        case "exposure":
            // 检视器里拖胶片曝光：30 下、每下隔 16 ms，0 → +1.5 档（每 0.1 档一张新的色调表）。不是光谱色调先换上。
            if !store.project.style.look.isSpectral {
                var st = store.project.style
                st.look = .filmWarmSkin
                store.setStyle(st, coalesce: false)
                spin(1.5)
            }
            let start = beginMeasure()
            for i in 0..<30 {
                var st = store.project.style
                st.filmExposure = Double(i + 1) * 0.05
                store.setStyle(st, coalesce: true)
                spin(0.016)
            }
            endMeasure(start, steps: 30)
            return "胶片曝光滑杆 30 下"
        case "title":
            store.setTitle("刷新计数 \(store.project.title.count)")
            return "改标题"
        default:
            return "不认识的场景（place / gutter / variant / variants / bigtray / pan / slider / exposure / title / all / trayclick / darkroom）"
        }
    }
}
