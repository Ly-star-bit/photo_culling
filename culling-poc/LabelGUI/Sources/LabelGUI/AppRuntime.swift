import AppKit

/// 进程怎么跑的：命令行无头模式（--analyze、--collage-ops……）下，任何会弹到屏幕上的动作都不做。
enum AppRuntime {
    /// 命令行无头参数；main.swift 分派之前按它们设 `headless`。= 下面的命令参数 + 自检登记表（SelfTestRegistry.swift）里的。
    static let headlessFlags: Set<String> = commandFlags.union(SelfTestRegistry.flags)

    /// 不是自检的无头命令参数（各自在 main.swift 里分派）。`--*-selftest` / `--*-probe` 不写在这里：只登在 SelfTestRegistry.all
    /// （cli_guard_regression.py 的 G 段核对这里一个都没有、和 main.swift 的顶层分派两边对得上）。
    static let commandFlags: Set<String> = [
        "--analyze", "--watermark", "--session-key", "--verdicts", "--sharp", "--focus", "--compare",
        "--collage", "--collage-ui", "--collage-ops", "--compare-crop", "--batch-ui", "--compare-ui", "--export-xmp",
        "--watermark-ui", "--watermark-batch",
        "--ingest", "--card-ui",
        "--proof-sheet", "--client-import", "--copy-list", "--copy-originals",
        "--export-jpeg", "--body-offset",
        "--app-ui", "--live-host",
        "--mcp", "--mcp-call", "--mcp-tools",
        "--diag-export",
    ]

    /// true = 无头跑（测试、自动化）。
    static var headless = false

    /// LABELGUI_STABLE_SEEDS=1（拼图门禁 Scripts/collage_gate.sh 设）：按图层 id 定的随机纹理（胶带撕口、
    /// 圆点条纹）改按图层自己的几何定。图层 id 每次运行都是新的 UUID，同一组命令跑两次胶带就对不上，
    /// 门禁没法逐像素比。平常不设：纹理照旧跟着 id 走（拖动时不变）。
    static let stableSeeds = ProcessInfo.processInfo.environment["LABELGUI_STABLE_SEEDS"] == "1"

    /// 导出完在访达里选中结果。无头模式不弹：脚本里跑几十次导出就会弹几十个访达窗口。
    static func revealInFinder(_ urls: [URL]) {
        guard !headless, !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
