import AppKit

/// 进程怎么跑的：命令行无头模式（--analyze、--collage-ops……）下，任何会弹到屏幕上的动作都不做。
enum AppRuntime {
    /// 命令行无头参数；main.swift 分派之前按它们设 `headless`。
    static let headlessFlags: Set<String> = [
        "--analyze", "--watermark", "--session-key", "--verdicts", "--sharp", "--focus", "--compare",
        "--collage", "--collage-ui", "--collage-ops", "--compare-crop",
    ]

    /// true = 无头跑（测试、自动化）。
    static var headless = false

    /// 导出完在访达里选中结果。无头模式不弹：脚本里跑几十次导出就会弹几十个访达窗口。
    static func revealInFinder(_ urls: [URL]) {
        guard !headless, !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
