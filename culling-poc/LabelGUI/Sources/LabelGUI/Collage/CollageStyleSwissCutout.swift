import Foundation
import CoreGraphics

/// 抠图格「贴着成品底边」（CollageCutout.toEdge，瑞士网格巨型数字：人从纸上站起来、被成品底边切掉）。
/// CollageCover.resolve 里一行钩子调 edgeRule（进缓存之前：预览、导出、画布、出图记录同一个决定）；
/// coverdump 打印 edgeDump 那一行。别的格子（没设 toEdge）第一句就 return，一步都不多走。
extension CollageCover {

    /// 底边那一条盖住的宽度至少要有身子最宽处的几成，才算人一直延伸到格子底边。
    static let edgeShare = 0.5

    /// 抠出来的人在「贴着成品底边」的抠图格里浮不浮：格子底边不是成品底边（相册跨页的下边距），或者在定下来的
    /// 取景上，取景底边那一条（往上 0.2–1%）里蒙版盖住的宽度不到往上 5–25% 那一截（身子）最宽处的一半 ——
    /// 人在格子里就断了（被栏杆挡住的一刀齐、全身照的脚、只有头）。浮的就不抠：整张照片照放，人后的字照样按蒙版
    /// 压在人后。取景不变（量遮挡、摆字用的是同一个窗口）。
    static func edgeRule(_ res: inout Resolution, cell: CollageCell, frameRect: CGRect, canvas: CollageCanvas) {
        guard let cut = cell.cutout, cut.toEdge, let mask = res.mask else { return }
        if Double(frameRect.maxY) < Double(canvas.height) - 1 {
            res.cutoutDropped = true
            res.cutoutReason = "这一格不贴着成品底边（相册跨页留了下边距），抠出来的人会浮在纸上：这一张不抠，整张照片照放"
            return
        }
        let w = res.window
        guard w.w > 0, w.h > 0 else { return }
        // 一行里蒙版 ≥ 0.5 的占取景宽多少（横着取 96 个点）。
        func covered(_ v: Double) -> Double {
            let n = 96
            var hit = 0
            for i in 0..<n {
                let u: Double = w.x + (Double(i) + 0.5) / Double(n) * w.w
                if mask.value(u: u, v: v) >= 0.5 { hit += 1 }
            }
            return Double(hit) / Double(n)
        }
        let bottom: Double = w.y + w.h
        let edge: Double = [0.002, 0.006, 0.01].map { covered(bottom - $0 * w.h) }.max() ?? 0
        let body: Double = stride(from: 0.05, through: 0.25, by: 0.02).map { covered(bottom - $0 * w.h) }.max() ?? 0
        res.edgeCoverage = (edge, body)
        let need: Double = max(0.02, edgeShare * body)
        if edge < need {
            res.cutoutDropped = true
            res.cutoutReason = String(format: "抠出来的人到不了格子底边（底边那一条只盖住 %.0f%%，身子 %.0f%%：被前景挡住、"
                                      + "或者全身照的脚在格子里），会浮在纸上：这一张不抠，整张照片照放", edge * 100, body * 100)
        }
    }

    /// coverdump 的那一行（只给贴底边的抠图格）：抠不抠、底边 / 身子盖住多宽、为什么。
    static func edgeDump(cell: CollageCell, _ r: Resolution) -> String? {
        guard let c = cell.cutout, c.toEdge else { return nil }
        let e: String = r.edgeCoverage.map { String(format: " · 底边 %.0f%% 身子 %.0f%%", $0.edge * 100, $0.body * 100) } ?? ""
        let kept: String = r.mask == nil ? "没有蒙版" : "抠"
        let what: String = r.cutoutDropped ? "不抠" : kept
        let why: String = r.cutoutReason.map { " · " + $0 } ?? ""
        return "      抠图·贴底边 → " + what + e + why
    }
}
