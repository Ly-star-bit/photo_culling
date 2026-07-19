import SwiftUI

struct ContentView: View {
    @ObservedObject var store: LabelStore
    @ObservedObject var batchStore: BatchStore

    var body: some View {
        // 迁移 is a once-a-year utility — it lives in its own window (窗口菜单 →
        // 迁移), not as a permanent top-level tab.
        TabView {
            BatchView(store: batchStore)
                .tabItem { Label("批量处理", systemImage: "square.grid.3x3") }

            labelingTab
                .tabItem { Label("标注校准", systemImage: "checklist") }
        }
    }

    private var labelingTab: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            if let error = store.loadError {
                Text(error).foregroundStyle(.red).padding()
            } else if let photo = store.currentPhoto {
                DetailView(store: store, photo: photo)
                    .id(photo.id)
            } else {
                Text("没有照片，先在批量处理页跑一次分析")
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("已标注 \(store.labeledCount) / \(store.photos.count)")
            }
        }
        .navigationTitle("选片工具")
    }
}
