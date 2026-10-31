import Foundation
import AppKit
import Combine

/// 拼图页刷新计数（只给 `--collage-ui … --perf <场景>` 用）：一个操作下来，哪个视图的 body 重算了几次、
/// store 发了几次 objectWillChange、主线程最长卡了多久。平常 enabled = false，body 里那一行只读一个 Bool。
/// 数的是离屏窗口里 SwiftUI 重算了几次 —— 证明「刷新得少了」，证明不了手感（手感要在真 app 上试）。
@MainActor
enum CollagePerf {
    static var enabled = false
    private(set) static var bodies: [String: Int] = [:]

    /// 放在 body 第一行：`let _ = CollagePerf.body("托盘")`。
    static func body(_ name: String) {
        guard enabled else { return }
        bodies[name, default: 0] += 1
    }

    /// 报告里按这个顺序列（没数到的写 0）。
    static let order = ["拼图页", "托盘", "托盘格", "画布", "叠加层", "检视器", "版式面板", "模板库", "模板格", "备选条", "页条"]

    /// 跑一个场景：settle 之后清零、跑、再等 `tail` 秒让后台的缩略图、预览都落下来，打印一行。
    /// spin 是快照那边的同一个（跑主线程 run loop）。
    static func run(_ scenario: String, store: CollageStore, spin: (Double) -> Void) {
        let names = scenario == "all" ? ["place", "gutter", "slider", "title"] : [scenario]
        for name in names {
            spin(1.5)
            var publishes = 0
            let sub = store.objectWillChange.sink { _ in publishes += 1 }
            var maxGap = 0.0
            var last = CACurrentMediaTime()
            let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
                let now = CACurrentMediaTime()
                maxGap = max(maxGap, now - last)
                last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            bodies = [:]
            enabled = true
            let start = CACurrentMediaTime()
            let note = step(name, store: store, spin: spin)
            spin(3)
            enabled = false
            timer.invalidate()
            sub.cancel()
            let counts = order.map { "\($0) \(bodies[$0] ?? 0)" }.joined(separator: " · ")
            print(String(format: "perf %@：%@ · store 发 %d 次 · body %@ · 主线程最长卡 %.0f ms · 用时 %.1f s",
                         name, note, publishes, counts, maxGap * 1000, CACurrentMediaTime() - start))
        }
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
            guard let g = store.geometry.gutters.first else { return "没有缝" }
            store.beginContinuousEdit()
            for i in 0..<30 {
                store.setRatio(0.35 + Double(i) * 0.01, at: g.path)
                spin(0.016)
            }
            store.endContinuousEdit()
            return "缝 \(g.path.map(String.init).joined()) 拖 30 下"
        case "slider":
            // 拖样式滑杆（边距）：30 下、每下隔 16 ms，和检视器滑杆一样 coalesce。
            for i in 0..<30 {
                var st = store.project.style
                st.margin = 0.02 + Double(i) * 0.001
                store.setStyle(st, coalesce: true)
                spin(0.016)
            }
            return "边距滑杆 30 下"
        case "title":
            store.setTitle("刷新计数 \(store.project.title.count)")
            return "改标题"
        default:
            return "不认识的场景（place / gutter / slider / title / all）"
        }
    }
}
