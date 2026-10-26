import Foundation
import Combine

/// 窗口里的四个 tab。
enum AppTab: Hashable {
    case batch, watermark, collage, labeling
}

/// App 级的状态：五个 store 和当前 tab，整个进程只有一份（LabelGUIApp 建；--app-ui 离屏快照也走同一个 `make`）。
/// 以前批量、标注、插卡在 LabelGUIApp 里，水印、拼图、tab 在 ContentView 里：窗口外面的代码够不着拼图工程和当前 tab。
@MainActor
final class AppModel: ObservableObject {
    /// 给 AI 的实时桥：GUI 传 `.gui`，--app-ui 传 `.none`（永远不开桥）。桥还没做，现在两个都什么也不做。
    enum Bridge {
        case gui, none
    }

    let batch: BatchStore
    let labels: LabelStore
    /// 插卡检测：跟着 app 活（不放在某个 tab 里 —— 没打开的 tab 不一定被建出来）。
    let cardCenter: CardImportCenter
    let watermark: WatermarkStore
    let collage: CollageStore
    @Published var tab: AppTab = .batch

    /// 批量页切场次 → 拼图工程跟着换。
    private var photoDirWatch: AnyCancellable?

    private init(batch: BatchStore, labels: LabelStore, cardCenter: CardImportCenter,
                 watermark: WatermarkStore, collage: CollageStore) {
        self.batch = batch
        self.labels = labels
        self.cardCenter = cardCenter
        self.watermark = watermark
        self.collage = collage
    }

    static func make(dataDir: URL, pythonRoot: URL, bridge: Bridge) -> AppModel {
        // 建的顺序和以前一样：批量 → 标注 → 插卡（以前在 LabelGUIApp.init）→ 水印 → 拼图（以前是 ContentView 里
        // 两个 @StateObject，水印在前）。CollageStore.init 会设水印资源目录这类进程级的全局变量，顺序别动。
        let batch = BatchStore(dataDir: dataDir, pythonRoot: pythonRoot)
        let labels = LabelStore(dataDir: batch.sessionDir)
        let cardCenter = CardImportCenter(store: batch)
        let watermark = WatermarkStore(dataDir: dataDir)
        let collage = CollageStore(dataDir: dataDir)
        let model = AppModel(batch: batch, labels: labels, cardCenter: cardCenter,
                             watermark: watermark, collage: collage)
        // 拼图工程启动起就挂到当前场次上（以前要等第一次点开拼图 tab），之后每次切场次跟着换：
        // 不点开拼图 tab，拼图工程也是这一场的。
        model.ensureCollageAttached()
        // receive(on:) 不能省：@Published 在赋值之前就发，回调里直接读 batch.sessionDir 拿到的还是上一场。
        model.photoDirWatch = batch.$photoDir.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak model] _ in
                MainActor.assumeIsolated { model?.ensureCollageAttached() }
            }
        return model
    }

    /// 拼图工程挂到批量页当前的场次（同一场再挂只按批量页刷一遍托盘）。和 CollageView.attachSession() 同两行。
    func ensureCollageAttached() {
        let dir = batch.photoDir
        collage.attach(sessionDir: dir == nil ? nil : batch.sessionDir, photoDir: dir, batch: batch)
    }

    /// 批量页多选「拼图」：切到拼图页、带照片进托盘、直接排一版。
    func openCollage(batchIDs ids: [String]) {
        collage.attach(sessionDir: batch.photoDir == nil ? nil : batch.sessionDir,
                       photoDir: batch.photoDir, batch: batch)
        collage.importFromBatch(ids: ids, batch: batch, layout: true)
        tab = .collage
    }

    /// 水印页「拼图 (N) →」/「套到当前拼图」：原图 + 水印设置交给拼图页（水印在拼图里实时画）。
    func openCollage(watermark request: WatermarkCollageRequest) {
        CollageHandoff.fromWatermark(request, batch: batch, collage: collage)
        tab = .collage
    }
}
