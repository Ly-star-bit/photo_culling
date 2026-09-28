import SwiftUI

struct ContentView: View {
    @ObservedObject var store: LabelStore
    @ObservedObject var batchStore: BatchStore
    @StateObject private var watermarkStore = WatermarkStore(dataDir: appDataDir)
    @StateObject private var collageStore = CollageStore(dataDir: appDataDir)
    @State private var tab: AppTab = .batch

    enum AppTab: Hashable {
        case batch, watermark, collage, labeling
    }

    var body: some View {
        TabView(selection: $tab) {
            BatchView(store: batchStore)
                .tabItem { Label("批量处理", systemImage: "square.grid.3x3") }
                .tag(AppTab.batch)

            WatermarkView(store: watermarkStore, batchStore: batchStore)
                .tabItem { Label("水印", systemImage: "signature") }
                .tag(AppTab.watermark)

            CollageView(store: collageStore, batchStore: batchStore)
                .tabItem { Label("拼图", systemImage: "rectangle.3.offgrid") }
                .tag(AppTab.collage)

            labelingTab
                .tabItem { Label("标注校准", systemImage: "checklist") }
                .tag(AppTab.labeling)
        }
        // 批量页多选「拼图」：切到拼图页、带照片进托盘、直接排一版。
        .onChange(of: batchStore.collageRequest) { _, request in
            guard let ids = request, !ids.isEmpty else { return }
            batchStore.collageRequest = nil
            collageStore.attach(sessionDir: batchStore.photoDir == nil ? nil : batchStore.sessionDir,
                                photoDir: batchStore.photoDir)
            collageStore.importFromBatch(ids: ids, batch: batchStore, layout: true)
            tab = .collage
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
