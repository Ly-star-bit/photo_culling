import SwiftUI

struct ContentView: View {
    /// store 和当前 tab 都在 AppModel 里（App 级，见 AppModel.swift）。
    @ObservedObject var model: AppModel
    // 五个 store 照旧各自观察：哪个一变 body 就重算，和以前一模一样（拼图预览每重渲一次也算一次）。
    @ObservedObject var store: LabelStore
    @ObservedObject var batchStore: BatchStore
    @ObservedObject var cardCenter: CardImportCenter
    @ObservedObject private var watermarkStore: WatermarkStore
    @ObservedObject private var collageStore: CollageStore

    init(model: AppModel) {
        self.model = model
        store = model.labels
        batchStore = model.batch
        cardCenter = model.cardCenter
        watermarkStore = model.watermark
        collageStore = model.collage
    }

    var body: some View {
        TabView(selection: $model.tab) {
            BatchView(store: batchStore)
                .tabItem { Label("批量处理", systemImage: "square.grid.3x3") }
                .tag(AppTab.batch)

            WatermarkView(store: watermarkStore, batchStore: batchStore)
                .tabItem { Label("水印", systemImage: "signature") }
                .tag(AppTab.watermark)

            CollageView(store: collageStore, batchStore: batchStore, watermarkStore: watermarkStore)
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
            model.openCollage(batchIDs: ids)
        }
        // 水印页「拼图 (N) →」/「套到当前拼图」：原图 + 水印设置交给拼图页（水印在拼图里实时画）。
        .onChange(of: watermarkStore.collageRequest) { _, request in
            guard let request else { return }
            watermarkStore.collageRequest = nil
            model.openCollage(watermark: request)
        }
        // 插了相机存储卡：问要不要导入（导入的进度在批量页顶栏，点「导入」就切过去）。
        .sheet(item: $cardCenter.offer) { _ in
            CardImportSheet(center: cardCenter, store: batchStore) { model.tab = .batch }
        }
        .onAppear { cardCenter.start() }
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
