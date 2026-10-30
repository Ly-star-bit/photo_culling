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
    /// 给 AI 的实时桥（DESIGN §9.2.1、§5 第 7 层）：GUI 传 `.gui`（真实的 socket 目录，按设置开桥），--live-host 传
    /// `.testHost`（测试自己的 socket 根目录和测试开关，桥总是开着），--app-ui 传 `.none`（不拿锁、不建 socket 目录、不 bind）。
    /// 前两种是同一个 LiveServer、同一套代码。
    enum Bridge {
        case gui
        case testHost(LiveTestOptions)
        case none
    }

    let batch: BatchStore
    let labels: LabelStore
    /// 插卡检测：跟着 app 活（不放在某个 tab 里 —— 没打开的 tab 不一定被建出来）。
    let cardCenter: CardImportCenter
    let watermark: WatermarkStore
    let collage: CollageStore
    @Published var tab: AppTab = .batch
    /// 实时桥（bridge: .none 时是 nil）。
    private(set) var live: LiveServer?
    /// 用户此刻是不是正在 app 里操作（§9.6b）：桥在执行写之前问它。GUI 开桥时才去看 AppKit，别的时候只看 store。
    let interaction = LiveInteraction()
    /// AI 经桥做过的写（app_undo 只撤 AI 自己那一步，§9.3）。
    var aiLog = LiveAILog()

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
        // 实时桥第 1 步：建 store 之前先拿 .live.lock（§9.2.1，R6 §3.2：保证读到的是别人写完的盘）。.gui 最多阻塞 3 s；
        // 拿不到也照常往下建，只是不开桥。.none 什么都不做。
        let live: LiveServer?
        switch bridge {
        case .gui: live = LiveServer.prepare(.gui, dataDir: dataDir)
        case .testHost(let options): live = LiveServer.prepare(.testHost(options), dataDir: dataDir)
        case .none: live = nil
        }
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
        // store 都建好了：写锁文件那一行、设置开着才开 socket（§9.2.1 第 3–5 步）
        model.live = live
        live?.attach(model)
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
