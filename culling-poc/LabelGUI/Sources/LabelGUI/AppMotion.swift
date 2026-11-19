import SwiftUI
import AppKit

// MARK: - 改判动画、减少动态效果（PI-01 / UX-12）

/// 批量页、看大图、连拍挑选里的动画都从这里取。
///
/// **改判动画（PI-01）**：以前每次改判（数字键、悬停条 ★●✕、批量栏、右键、接受推荐、只留这张）都包一层 0.2 秒的
/// `withAnimation`，整屏看得见的格子跟着挪位、行跟着重排，每帧把整屏格子的图层同步一遍、变了大小的缩略图每帧重画
/// （真机估 0.37–1.25G 指令一下，离屏量的「25 倍」是没有垂直同步的假象，见优化分析 2026-11-18 perf-ui 及复核）。
/// 复核员量过真机开销不大，这一条是按观感改的：格子、行立刻到位，只有被改那一格的判决图标 / 颜色有一下 0.15 秒的过渡。
/// **要改回 v1.32.0 的样子，只改 `reflow` 那一行**（写成 `.easeInOut(duration: 0.2)`）。
///
/// **减少动态效果（UX-12）**：系统「辅助功能 › 显示 › 减少动态效果」开着时，挪位、展开收起、滑出面板、滚动、放大这些
/// 会动的一律不做（直接到位）；提示条的淡入淡出照旧（Apple 的说法：减少动态效果是把移动、缩放换成淡入淡出，淡入淡出本身不算）。
/// 无头时环境变量 `LABELGUI_REDUCE_MOTION=1` 假装它开着（--perf grid 量「开着时改判多贵」用）。
enum AppMotion {
    /// 改判时整格网格挪位、行重排的动画。nil = 不做（PI-01）；改回 `.easeInOut(duration: 0.2)` 就是 v1.32.0。
    static let reflow: Animation? = nil
    /// 被改那一格的判决图标 / 颜色过渡（GridCell）。
    static let verdictFade: Animation = .easeOut(duration: 0.15)

    /// 无头时假装「减少动态效果」开着。
    static let forced: Bool = ProcessInfo.processInfo.environment["LABELGUI_REDUCE_MOTION"] == "1"

    /// 系统「减少动态效果」开着（或无头假装开着）。按下去那一刻读，不缓存：用户随时会去系统设置里拨。
    @MainActor static var reduce: Bool {
        forced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 给 `withAnimation` 用：减少动态效果开着就是 nil（直接到位）。
    @MainActor static func animation(_ base: Animation?) -> Animation? {
        reduce ? nil : base
    }

    /// 改判：`withAnimation(AppMotion.reverdict) { store.setOverrideBatch(…) }`。
    @MainActor static var reverdict: Animation? { animation(reflow) }

    /// 无头打印（BatchPerf 第二行）：现在用的是哪一套。
    @MainActor static var summary: String {
        let reflowText: String = reflow == nil ? "关" : "开"
        return "改判挪位动画 " + reflowText + " · 判决色过渡 0.15 秒 · 减少动态效果 " + (reduce ? "开" : "关")
    }
}
