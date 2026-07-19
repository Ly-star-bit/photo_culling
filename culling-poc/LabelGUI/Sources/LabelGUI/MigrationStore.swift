import Foundation
import SwiftUI

/// One-click export of everything another Mac needs (app + Python pipeline)
/// and one-click import on the target machine. The import writes machine-local
/// paths into AppConfig, so no rebuild is needed on the target. The VLM model
/// itself is NOT bundled: it comes from Ollama (`ollama pull minicpm-v4.6:f16`,
/// 2.6GB) on the target machine — a one-line, resumable download beats hauling
/// weights inside a zip.
@MainActor
final class MigrationStore: ObservableObject {
    @Published var isWorking = false
    @Published var statusText = ""
    @Published var lastError: String?

    let dataDir: URL
    private weak var batchStore: BatchStore?

    init(dataDir: URL, batchStore: BatchStore) {
        self.dataDir = dataDir
        self.batchStore = batchStore
    }

    // MARK: - Export

    /// Builds the package in a temp staging folder, then zips it into ONE file.
    func exportPackage(to zipDestination: URL) {
        guard !isWorking, let batchStore else { return }
        isWorking = true
        lastError = nil
        let pythonRoot = batchStore.pythonRoot
        let appBundle = URL(fileURLWithPath: Bundle.main.bundlePath)

        Task.detached { [weak self] in
            func status(_ s: String) {
                Task { @MainActor [weak self] in self?.statusText = s }
            }
            let fm = FileManager.default
            let stagingParent = fm.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
            let staging = stagingParent.appendingPathComponent("选片工具迁移包")
            defer { try? fm.removeItem(at: stagingParent) }
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)

                status("复制 App...")
                try fm.copyItem(at: appBundle, to: staging.appendingPathComponent("选片工具.app"))

                status("复制 Python 流水线...")
                try Self.copyDirectory(from: pythonRoot, to: staging.appendingPathComponent("culling-poc"),
                                       excluding: [".venv", ".git", "LabelGUI", "data", "__pycache__"])

                try Self.readmeText.write(to: staging.appendingPathComponent("安装说明.md"),
                                          atomically: true, encoding: .utf8)

                status("压缩为单个 zip...")
                try? fm.removeItem(at: zipDestination)
                let zip = Process()
                zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                zip.arguments = ["-r", "-q", zipDestination.path, "选片工具迁移包"]
                zip.currentDirectoryURL = stagingParent
                try zip.run()
                zip.waitUntilExit()
                guard zip.terminationStatus == 0 else {
                    throw NSError(domain: "Migration", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "zip 退出码 \(zip.terminationStatus)"])
                }

                status("打包完成: \(zipDestination.path)")
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "打包失败: \(error.localizedDescription)"
                    self?.statusText = ""
                }
            }
            Task { @MainActor [weak self] in self?.isWorking = false }
        }
    }

    // MARK: - Import

    /// Copies the runtime folders into Application Support (a stable, always-
    /// writable, username-independent location) and points AppConfig at them.
    /// Accepts either the zip the export produces or an already-extracted folder.
    func importPackage(from source: URL) {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        let runtimeDir = dataDir.appendingPathComponent("runtime")

        Task.detached { [weak self] in
            func status(_ s: String) {
                Task { @MainActor [weak self] in self?.statusText = s }
            }
            let fm = FileManager.default
            var extractTemp: URL?
            defer { if let extractTemp { try? fm.removeItem(at: extractTemp) } }
            do {
                var packageDir = source
                if source.pathExtension.lowercased() == "zip" {
                    status("解压迁移包 (约1-2分钟)...")
                    let temp = fm.temporaryDirectory.appendingPathComponent("migration-import-\(UUID().uuidString)")
                    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
                    extractTemp = temp
                    let unzip = Process()
                    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    unzip.arguments = ["-q", source.path, "-d", temp.path]
                    try unzip.run()
                    unzip.waitUntilExit()
                    guard unzip.terminationStatus == 0 else {
                        throw NSError(domain: "Migration", code: 5,
                                      userInfo: [NSLocalizedDescriptionKey: "unzip 退出码 \(unzip.terminationStatus)"])
                    }
                    // The zip wraps everything in one root folder; find it.
                    let extracted = try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
                        .filter { !$0.lastPathComponent.hasPrefix("__MACOSX") }
                    if extracted.count == 1 {
                        packageDir = extracted[0]
                    } else {
                        packageDir = temp
                    }
                }

                let pySrc = packageDir.appendingPathComponent("culling-poc")
                guard fm.fileExists(atPath: pySrc.path) else {
                    throw NSError(domain: "Migration", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "所选内容不是迁移包 (缺少 culling-poc)",
                    ])
                }

                try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

                status("导入 Python 流水线...")
                let pyDest = runtimeDir.appendingPathComponent("culling-poc")
                try? fm.removeItem(at: pyDest)
                try fm.copyItem(at: pySrc, to: pyDest)

                let uvPresent = fm.fileExists(atPath: "/opt/homebrew/bin/uv")

                await MainActor.run { [weak self] in
                    guard let self, let batchStore = self.batchStore else { return }
                    batchStore.pythonRoot = pyDest
                    var config = AppConfig.load(from: self.dataDir)
                    config.pythonRoot = pyDest.path
                    config.save(to: self.dataDir)
                    self.statusText = uvPresent
                        ? "导入完成。还需 Ollama: 装 Ollama.app 后运行 ollama pull \(BatchStore.ollamaModel)"
                        : "导入完成。还需安装 uv (brew install uv) 和 Ollama (ollama pull \(BatchStore.ollamaModel))"
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "导入失败: \(error.localizedDescription)"
                    self?.statusText = ""
                }
            }
            Task { @MainActor [weak self] in self?.isWorking = false }
        }
    }

    // MARK: - Helpers

    /// Recursive copy skipping the given directory/file names at every level.
    nonisolated static func copyDirectory(from src: URL, to dst: URL, excluding: Set<String>) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for entry in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = entry.lastPathComponent
            if excluding.contains(name) { continue }
            let target = dst.appendingPathComponent(name)
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try copyDirectory(from: entry, to: target, excluding: excluding)
            } else {
                try fm.copyItem(at: entry, to: target)
            }
        }
    }

    nonisolated static let readmeText = """
    # 选片工具迁移包 安装说明

    目标机器要求: Apple Silicon Mac (M1 及以上), macOS 14+

    1. 解压 zip (双击即可)，把 `选片工具.app` 拖到「应用程序」文件夹
    2. 首次打开: 右键 → 打开 (绕过 Gatekeeper 的未验证开发者提示)
    3. 打开 App → 「迁移」页 → 「导入迁移包」→ 选择 zip 或解压后的文件夹
       (会把 Python 流水线复制到 App 自己的数据目录并自动配置路径)
    4. VLM 语义分析功能还需要 (不用 VLM 可跳过):
       - Ollama: 从 https://ollama.com 下载安装 Ollama.app，
         然后终端运行 `ollama pull minicpm-v4.6:f16` (约2.6GB)
       - uv (Python 包管理器): `brew install uv`
         第一次跑 VLM 时会自动创建 Python 虚拟环境并安装依赖 (需要网络)
    5. 「批量处理」页 → 「启动 VLM 服务」→ 「对幸存照片跑 VLM」

    不用 VLM 的话，装完 App 直接用: 分析/筛选/JPG 导出/XMP 导出完全不依赖任何外部环境。
    """
}
