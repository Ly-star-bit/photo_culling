import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MigrationView: View {
    @ObservedObject var store: MigrationStore
    @ObservedObject var batchStore: BatchStore

    var body: some View {
        Form {
            Section("打包 (在这台机器上)") {
                Text("把 App + VLM 运行环境 + 模型权重打成一个 zip (~8GB)，拷给另一台 Apple Silicon Mac。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(store.isWorking ? "打包中..." : "打包为 zip...") { pickExportDestination() }
                    .disabled(store.isWorking)
            }

            Section("导入 (在新机器上)") {
                Text("选择拷过来的迁移包 zip：运行环境会复制到 App 数据目录并自动配置路径，无需重新编译。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(store.isWorking ? "导入中..." : "导入迁移包...") { pickImportSource() }
                    .disabled(store.isWorking)
            }

            Section("当前路径配置") {
                LabeledContent("Python 流水线") {
                    Text(batchStore.pythonRoot.path).font(.caption).textSelection(.enabled)
                }
                LabeledContent("VLM 模型") {
                    Text("Ollama · \(BatchStore.ollamaModel)").font(.caption).textSelection(.enabled)
                }
            }

            if !store.statusText.isEmpty {
                Text(store.statusText).font(.caption)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func pickExportDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "选片工具迁移包.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.prompt = "打包"
        if panel.runModal() == .OK, let url = panel.url {
            store.exportPackage(to: url)
        }
    }

    private func pickImportSource() {
        let panel = NSOpenPanel()
        // zip is the normal path; a bare folder (already-extracted package) works too.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        if panel.runModal() == .OK, let url = panel.url {
            store.importPackage(from: url)
        }
    }
}
