import Foundation
import SwiftUI
import AppKit
import CryptoKit
import ImageIO

/// 拼图 tab 的状态：项目文档、选中、备选版式、撤销、预览、模板、导出、按场次存盘。
/// 渲染本身在 CollageRender，版式在 CollageLayout —— 这里只做编排和撤销。
@MainActor
final class CollageStore: ObservableObject {

    // MARK: - 文档

    @Published private(set) var project = CollageProject()
    @Published var pageIndex = 0 {
        didSet {
            guard pageIndex != oldValue else { return }
            finishCropEditForNavigation()
            selection = nil
            selectedItem = nil
            clearAlternatives()
            setNeedsRender()
        }
    }
    /// 选中的格子（当前页的叶子路径）。和选中的图层互斥。
    @Published var selection: [Int]? {
        didSet {
            if selection != nil, selectedItem != nil { selectedItem = nil }
            // 换了格子：从这张照片的第一个字块（刊头）编起。
            if selection != oldValue, overlayIndex != 0 { overlayIndex = 0 }
        }
    }
    /// 选中的照片上正在编辑第几个字块（0 = 刊头 / 唯一那个）：检视器的字块列表、画布上拖哪一个。
    @Published var overlayIndex = 0
    /// 选中的自由图层（相纸、胶带、手写字）。
    @Published var selectedItem: UUID? {
        didSet { if selectedItem != nil, selection != nil { selection = nil } }
    }
    /// 自动排版出网格还是散落版（单张拼图；存进全局设置）。
    @Published private(set) var layoutStyle: LayoutStyle = .grid

    enum LayoutStyle: String, Codable, CaseIterable {
        case grid, scatter

        var label: String { self == .grid ? "网格" : "散落" }
    }
    /// 双击进入的裁切模式：拖动平移、捏合/滑杆缩放。
    @Published var cropEditing = false
    /// 正在连续编辑（拖缝、拖字、拖图层）：beginContinuousEdit +1、endContinuousEdit −1，最低 0。
    /// 实时桥据此等用户松手再落 AI 的改动（§9.6b 的 continuous_edit）；以前「正在拖」没有任何可查的状态。
    @Published private(set) var continuousEditDepth = 0
    /// 画布上正在拖动 / 捏合（CollageCanvasView 写，实时桥读，§9.6b 的 dragging）。不发布：界面不跟着它重画。
    var liveCanvasDragging = false
    @Published var showGuides = true

    // MARK: - 备选版式

    @Published private(set) var alternatives: [CollageLayout.Scored] = []
    @Published private(set) var alternativeThumbs: [NSImage] = []
    @Published private(set) var alternativeIndex = 0
    @Published private(set) var isSolving = false
    private var solveSeed: UInt64 = 7
    /// 备选属于哪一页：页换了（删页、撤销、切页）就作废，别把别页的版套到这一页。
    private var alternativesPageID: UUID?
    /// 散落版备选用的参数（套用备选时写进页面，下次「换一批」接着用）。
    private var alternativesScatter: CollageScatterSpec?
    /// 每次求解 +1：后发先至时只认最新的那一次。
    private var solveGeneration = 0
    /// 每次换场次换一个：后台任务（导入、编排、求解）回来时场次变了就丢弃结果。
    private var sessionToken = UUID()
    /// 只有测试宿主（--live-host 的 test.delay_next）会设：下一次一键成套算完以后、落地之前多等几秒，
    /// 好在这期间模拟用户切场次 / 改版式（§9.8.2 第 25 条）。GUI 和命令行永远是 0。
    var testKitLandingDelay: Double = 0
    /// 进入裁切模式时不急着记撤销：第一次真的挪动/缩放才记，双击一下再 Esc 不留空步。
    private var cropUndoPending = false

    // MARK: - 预览

    @Published private(set) var preview: NSImage?
    /// 相册跨页条的缩略图（按页 id）。
    @Published private(set) var pageThumbs: [UUID: NSImage] = [:]
    private var thumbTask: Task<Void, Never>?
    /// 预览图对应的画布缩放（预览像素 / 成品像素）。
    @Published private(set) var previewScale: Double = 0.5
    private var viewportPixels = CGSize(width: 1200, height: 900)
    private var renderTask: Task<Void, Never>?
    private var renderDirty = false

    // MARK: - 视觉信息 / 模板 / 撤销

    private(set) var hints: [String: CollageCrop.Hints] = [:]
    /// 路人/主体算完一批就 +1：模板缩略图等着它重渲（裁切要避路人）。
    @Published private(set) var hintsVersion = 0
    /// 主体蒙版预热完一批就 +1（检视器的「刊名被挡」读数跟着刷新）。渲染自己同步拿蒙版，不等它。
    @Published private(set) var masksVersion = 0
    /// 色调样张（这一页的主图套每个色调）。
    @Published private(set) var lookThumbs: [CollageLook: NSImage] = [:]
    private var lookThumbKey = ""
    /// 风格预设样张（这一页套每个预设的样子；按预设 key）。
    @Published private(set) var styleThumbs: [String: NSImage] = [:]
    private var styleThumbKey = ""
    private var styleThumbTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    /// 还没跑完的路人信息批次（每次 computeHints 一批，跑完、作废都减一）。
    private var hintRunsPending = 0
    /// 主体蒙版预热（路人信息那一批抄完之后另起一个任务，一批接一批）：新的路人信息不用等它。
    private var maskTask: Task<Void, Never>?
    private var maskRunsPending = 0
    /// 路人信息（和蒙版预热）还在后台算：命令行出图、排版前等它归零 —— 不然算到第几张就用第几张的，出图跟着机器
    /// 快慢变（蒙版的头顶、覆盖率会抄进 Hints，挑主图看它）。
    var hintsPending: Bool { hintRunsPending > 0 || maskRunsPending > 0 }
    @Published private(set) var userTemplates: [CollageTemplate] = []
    /// 模板库缩略图（按模板名；用托盘里的照片现套现渲）。
    @Published private(set) var templateThumbs: [String: NSImage] = [:]
    private var templateThumbTask: Task<Void, Never>?
    /// 每个模板缩略图渲的时候用的键（照片、模板内容、用到的样式和画布）：键没变就不重渲。
    private var templateThumbKeys: [String: String] = [:]
    /// 模板缩略图还在后台渲（命令行脚本等它渲完再核对）。
    private(set) var templateThumbsBusy = false

    private var undoStack: [CollageProject] = []
    private var redoStack: [CollageProject] = []
    private var lastUndoPush = Date.distantPast
    private var lastPushCoalesced = false
    /// 几样改动合成一步撤销的期间（见 asOneUndoStep）：开头已经记过一步，这期间的 pushUndo 都不再记。
    private var undoGroupOpen = false
    /// 真记进撤销栈的次数（合并掉的、组里压住的不算）：不另记撤销的求解落下来时，看发起之后又记过几步。
    /// 只增不减（栈满丢掉最旧的也不回退）：实时桥的 app_undo 拿它判断 AI 那一步之后用户又改过没有（§9.3）。
    private(set) var undoPushes = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// 撤销栈深度（命令行脚本核对「一次操作记一步」用）。
    var undoDepth: Int { undoStack.count }

    // MARK: - 导出 / 提示

    struct ExportOptions: Codable, Equatable {
        var format: CollageExport.Format = .jpeg
        var quality: Double = 0.93
        var pdf = true
        var cropMarks = true
        var outputPath: String?
        // 「导出带水印」不在这里：它跟着拼图存（CollageWatermark.exportEnabled）。全局的一关，之后每个拼图
        // 都是预览有水印、导出没有。以前存过的 state.json 里那个 watermark 键读的时候直接忽略。

        init() {}

        /// 逐字段容错：哪个键缺了、坏了只丢它自己，输出目录、格式、质量不会因此全丢。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ExportOptions()
            format = (try? c.decodeIfPresent(CollageExport.Format.self, forKey: .format)) ?? nil ?? d.format
            quality = (try? c.decodeIfPresent(Double.self, forKey: .quality)) ?? nil ?? d.quality
            pdf = (try? c.decodeIfPresent(Bool.self, forKey: .pdf)) ?? nil ?? d.pdf
            cropMarks = (try? c.decodeIfPresent(Bool.self, forKey: .cropMarks)) ?? nil ?? d.cropMarks
            outputPath = (try? c.decodeIfPresent(String.self, forKey: .outputPath)) ?? nil
        }
    }

    @Published var exportOptions = ExportOptions() { didSet { scheduleStateSave() } }
    /// 导出的文件名（不带扩展名）；空 = 导出那一刻的时间，精确到秒。每次导出自己填，不存盘。
    @Published var exportName = ""
    @Published private(set) var isExporting = false
    @Published private(set) var progressText = ""
    @Published private(set) var progressFraction: Double?
    @Published var lastError: String?
    @Published private(set) var notice: String?
    @Published private(set) var busyText: String?
    /// 相册去重拿掉的照片（可以一键加回）。
    @Published private(set) var albumDropped: [CollagePhotoRef] = []
    private var exportCancelled = false
    private var noticeTask: Task<Void, Never>?

    // MARK: - 持久化

    private let stateDir: URL
    private var projectURL: URL?
    private(set) var photoDir: URL?
    private var projectSaveTask: Task<Void, Never>?
    private var stateSaveTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private var analysisObserver: NSObjectProtocol?
    /// 批量页（attach 时给）：托盘里批量页照片的判决、场、名次跟着它刷新；一键成套从它拿这一场的全部照片
    /// （印样要废片和整场的帧）。弱引用：两边都是整个 app 一份。
    private(set) weak var batch: BatchStore?

    init(dataDir: URL) {
        stateDir = dataDir.appendingPathComponent("collage")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // 签名存的绝对路径找不到时，渲染按 sha1 到这里找副本（渲染在后台线程，先于任何渲染设好）。
        CollageWatermarks.setAssetsDir(stateDir.appendingPathComponent("assets"))
        loadState()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushProjectSave()
                self?.flushStateSave()
            }
        }
        // 重新分析、重新判（VLM 复审、调阈值之后重载）：托盘里的判决、场、名次跟着换（只认同一个场次）。
        analysisObserver = NotificationCenter.default.addObserver(
            forName: .analysisDidFinish, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromBatch() }
        }
    }

    // MARK: - 派生

    var page: CollagePage? { project.pages.indices.contains(pageIndex) ? project.pages[pageIndex] : nil }
    var root: CollageNode? { page?.root }

    var photoMap: [String: CollagePhotoRef] {
        var map: [String: CollagePhotoRef] = [:]
        for p in project.photos where map[p.id] == nil { map[p.id] = p }
        return map
    }

    var context: CollageLayout.Context {
        CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap, hints: hints, heroID: nil)
    }

    /// 成品像素坐标里的几何（画布叠加层、拖缝、落点都用它）。散落版、印样没有格子。
    var geometry: CollageLayout.Geometry {
        guard let root, !isFreeform, !isContactSheet else { return CollageLayout.Geometry() }
        return CollageLayout.pageGeometry(root, canvas: project.canvas, style: project.style)
    }

    var selectedCell: CollageCell? {
        guard let selection else { return nil }
        return root?.node(at: selection)?.cell
    }

    var isFreeform: Bool { page?.freeform ?? false }
    /// 这一页是印样 / 底片条（整页按片条画，没有格子可选、可拖）。
    var isContactSheet: Bool { page?.contactSheet != nil }
    var items: [CollageItem] { page?.items ?? [] }

    var selectedItemValue: CollageItem? {
        guard let id = selectedItem else { return nil }
        return page?.items.first { $0.id == id }
    }

    var usedPhotoIDs: Set<String> { project.usedPhotoIDs }
    var isAlbum: Bool { project.mode == .album }

    /// 照片在这一格里实际画的区域（月洞门 = 正方形、相纸/胶片 = 框内），成品坐标。
    func photoArea(for frame: CollageLayout.Frame) -> CGRect {
        CollageCrop.photoArea(cell: frame.cell, rect: frame.rect.cgRect, style: project.style)
    }

    /// 当前页每格的取景（界面画人脸框、切脸警告用）—— 和渲染器同一个取景区域（封面取景、人物挡字的格子按
    /// CollageCover 的决定）。
    /// waitForMask = false（画布的角标、脸框：在 SwiftUI 的 body 里问）：封面取景、人物挡字、抠图格的蒙版还没算好
    /// （大托盘刚带进来、预热排在后面）就先按普通取景给，不在主线程上现跑 Vision（一张 35–270 ms）；蒙版算好
    /// masksVersion 一变，画布跟着刷新。
    func window(for frame: CollageLayout.Frame, waitForMask: Bool = true) -> CollageCrop.Window? {
        guard frame.cell.kind == .photo, let id = frame.cell.photoID, let photo = photoMap[id] else { return nil }
        let geo = geometry
        let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: geo.frames,
                                                     photos: photoMap, tight: project.style.tightSmallCells)
        if CollageCover.applies(to: frame.cell), waitForMask || CollageMasks.isSettled(photo),
           let decided = coverResolution(for: frame) {
            return decided.window
        }
        return CollageCrop.window(for: photo, cell: frame.cell, cellAspect: CollageCrop.aspect(of: photoArea(for: frame)),
                                  framing: framing, hints: hints[id])
    }

    /// 这一格的人物挡字 / 封面取景决定（检视器读数、取景都按它）；不走这一套的格子 = nil。
    func coverResolution(for frame: CollageLayout.Frame) -> CollageCover.Resolution? {
        guard frame.cell.kind == .photo, let page, let id = frame.cell.photoID else { return nil }
        let map = photoMap
        guard let photo = map[id] else { return nil }
        let ids = page.photoIDs
        let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: geometry.frames,
                                                     photos: map, tight: project.style.tightSmallCells)
        let project = CollageLooks.project(self.project, page: page)
        let vars = CollageTypeset.cellVariables(
            CollageTypeset.variables(project: project, root: page.root, photos: map, pagePhotoIDs: ids, pageID: page.id),
            photo: photo)
        let bg = CollageRender.backgroundColor(project: project, pagePhotoIDs: ids, photos: map)
        return CollageCover.resolve(cell: frame.cell, frameRect: frame.rect.cgRect, project: project, photo: photo,
                                    framing: framing, hints: hints[id], vars: vars, background: bg)
    }

    /// 压字能放的区域（照片实际画的区域 ∩ 月洞门、拱窗里面最大的矩形）：拖字按它换算位置 ——
    /// 和渲染器调的是同一个函数。
    func overlayArea(for frame: CollageLayout.Frame) -> CGRect {
        let map = photoMap
        let photo = frame.cell.photoID.flatMap { map[$0] }
        let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: geometry.frames,
                                                     photos: map, tight: project.style.tightSmallCells)
        return CollageRender.overlayGeometry(cell: frame.cell, frameRect: frame.rect.cgRect, style: project.style,
                                             photo: photo, framing: framing,
                                             hints: frame.cell.photoID.flatMap { hints[$0] }).textArea
    }

    /// 选中格子上第 index 个字块在成品上的位置（画布上的虚线框、拖字用）。
    func overlayPlacement(for frame: CollageLayout.Frame, index: Int = 0) -> CollageOverlays.Placement? {
        let all = overlayPlacements(for: frame)
        return all.indices.contains(index) ? all[index] : nil
    }

    /// 这一格全部字块的位置（和渲染器同一套算法、同一个先后：后面的让着前面的）。
    func overlayPlacements(for frame: CollageLayout.Frame) -> [CollageOverlays.Placement?] {
        guard !frame.cell.overlays.isEmpty, let page else { return [] }
        let map = photoMap
        let ids = page.photoIDs
        let photo = frame.cell.photoID.flatMap { map[$0] }
        let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: geometry.frames,
                                                     photos: map, tight: project.style.tightSmallCells)
        // 和渲染器一样：页级色调换进样式（底色取色、字的深浅按它），{frame} 按这一格的照片。
        let project = CollageLooks.project(self.project, page: page)
        let vars = CollageTypeset.cellVariables(
            CollageTypeset.variables(project: project, root: page.root, photos: map, pagePhotoIDs: ids, pageID: page.id),
            photo: photo)
        let bg = CollageRender.backgroundColor(project: project, pagePhotoIDs: ids, photos: map)
        return CollageRender.overlayPlacements(cell: frame.cell, frameRect: frame.rect.cgRect, project: project,
                                               photo: photo, framing: framing,
                                               hints: frame.cell.photoID.flatMap { hints[$0] }, vars: vars,
                                               background: bg)
    }

    /// 这一格照片上的字块展开占位符用的值（和 overlayPlacements、渲染器同一套：页级色调换进样式，{frame} 按这一格的
    /// 照片）：检视器字块按钮上的名字按展开后的字写（SHIGUANG、MARCH ISSUE，不是 masthead、[[month.）。
    func overlayVariables(at path: [Int]) -> [String: String] {
        guard let page else { return [:] }
        let map = photoMap
        let photo = page.root.node(at: path)?.cell?.photoID.flatMap { map[$0] }
        let project = CollageLooks.project(self.project, page: page)
        return CollageTypeset.cellVariables(
            CollageTypeset.variables(project: project, root: page.root, photos: map, pagePhotoIDs: page.photoIDs,
                                     pageID: page.id),
            photo: photo)
    }

    // MARK: - 场次

    /// 批量页换了场次：存当前的，读新场次的拼图项目。没打开文件夹时用一个默认项目文件，
    /// 那时做的拼图也不会丢。
    /// `batch`：批量页（托盘按它刷新判决、场、名次；成套从它拿全部照片）。不给 = 沿用上次给的。
    func attach(sessionDir: URL?, photoDir: URL?, batch: BatchStore? = nil) {
        if let batch { self.batch = batch }
        let newURL = sessionDir?.appendingPathComponent("collage.json")
            ?? stateDir.appendingPathComponent("scratch.json")
        guard newURL != projectURL else {
            // 同一个场次（切回拼图 tab）：批量页那边可能改过判决、调过场的间隔。
            refreshFromBatch()
            return
        }
        finishCropEditForNavigation()
        flushProjectSave()
        projectURL = newURL
        // 主体蒙版跟着工程放（场次目录 / 拼图资料目录下的 collage_masks/）。
        CollageMasks.setDirectory(newURL.deletingLastPathComponent().appendingPathComponent("collage_masks"))
        self.photoDir = photoDir
        sessionToken = UUID()
        solveGeneration += 1
        isSolving = false
        busyText = nil
        hintTask?.cancel()
        maskTask?.cancel()
        hints = [:]
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoFlags()
        // 换了工程：上一个工程里没收尾的拖动（手势被系统取消、没走到 endContinuousEdit）不再算「正在拖」
        continuousEditDepth = 0
        selection = nil
        selectedItem = nil
        clearAlternatives()
        albumDropped = []
        lookThumbKey = ""
        lookThumbs = [:]
        styleThumbTask?.cancel()
        styleThumbKey = ""
        styleThumbs = [:]
        templateThumbKeys = [:]
        templateThumbTask?.cancel()
        templateThumbsBusy = false
        templateThumbs = [:]
        // 换了工程：关掉时记下的水印层 / 文字是上一个拼图的，不能恢复到这里；还在等照片的交接也不再套水印。
        stashedMarkLayers = [:]
        stashedMarkTexts = [:]
        watermarkRevision += 1
        var loaded = CollageProject()
        loaded.canvas = defaultCanvas
        loaded.style = defaultStyle
        if let data = try? Data(contentsOf: newURL),
           let decoded = try? JSONDecoder().decode(CollageProject.self, from: data) {
            // 源文件暂时找不到（移动硬盘没插）也保留在托盘里：格子会空着，插上盘就回来了。
            // 以前在这里直接删掉，下一次保存就把它们永久抹掉了。
            loaded = decoded
        }
        project = loaded
        pageIndex = min(pageIndex, max(0, project.pages.count - 1))
        if project.pages.isEmpty { pageIndex = 0 }
        // 存盘时的快照会过时（之后重新判过、调过场的间隔）：按批量页现在的样子刷一遍。
        refreshFromBatch()
        computeHints(for: project.photos)
        setNeedsRender()
        schedulePageThumbs()
    }

    /// 托盘里批量页的照片按批量页现状刷新（判决、手动、场、场内名次、近似重复组、睁眼、EXIF、机身、帧号）。
    /// 只在批量页开着的就是这个工程的文件夹时做（换场次的通知先于 attach 到，别把上一场的同名照片刷进来）。
    /// 不进撤销；撤销栈里的旧工程一起刷 —— 撤销一步不会把旧判决带回来。
    func refreshFromBatch() {
        guard let batch, let photoDir, let batchDir = batch.photoDir,
              batchDir.standardizedFileURL.path == photoDir.standardizedFileURL.path,
              !project.photos.isEmpty else { return }
        let facts = CollageBridge.Facts(batch: batch)
        func refreshed(_ p: CollageProject) -> CollageProject? {
            var out = p
            var changed = false
            for i in out.photos.indices {
                guard let item = batch.item(withID: out.photos[i].id) else { continue }
                var ref = out.photos[i]
                CollageBridge.refresh(&ref, from: item, facts: facts)
                if ref != out.photos[i] {
                    out.photos[i] = ref
                    changed = true
                }
            }
            return changed ? out : nil
        }
        guard let now = refreshed(project) else { return }
        undoStack = undoStack.map { refreshed($0) ?? $0 }
        redoStack = redoStack.map { refreshed($0) ?? $0 }
        project = now
        scheduleProjectSave()
        setNeedsRender()
        schedulePageThumbs()
    }

    /// 路人信息里顺手算的亮度、黑白抄进托盘的照片（编排、成套看 CollagePhotoRef 就够，不用再翻 hints）。
    /// 撤销栈里的一起抄：撤销回去的工程照样带着。
    private func adoptHintFacts() {
        func adopted(_ p: CollageProject) -> CollageProject? {
            var out = p
            var changed = false
            for i in out.photos.indices {
                guard let h = hints[out.photos[i].id] else { continue }
                if out.photos[i].meanLuma != h.meanLuma || out.photos[i].isMonochrome != h.isMonochrome {
                    out.photos[i].meanLuma = h.meanLuma
                    out.photos[i].isMonochrome = h.isMonochrome
                    changed = true
                }
            }
            return changed ? out : nil
        }
        guard let now = adopted(project) else { return }
        undoStack = undoStack.map { adopted($0) ?? $0 }
        redoStack = redoStack.map { adopted($0) ?? $0 }
        project = now
        scheduleProjectSave()
    }

    // MARK: - 托盘：导入

    /// 从批量页带照片进来（网格多选的「拼这几张」、精选、精华 Top N）。已在托盘里的不重复加。
    /// `layout` = 带进来之后直接排一版。
    func importFromBatch(ids: [String], batch: BatchStore, layout: Bool) {
        let items = ids.compactMap { batch.item(withID: $0) }
        addRefs(from: items, layout: layout ? .solve(ids) : .none, facts: CollageBridge.Facts(batch: batch))
    }

    func importVerdicts(batch: BatchStore, includeUsable: Bool) {
        let items = batch.items.filter { $0.verdict == .pick || (includeUsable && $0.verdict == .usable) }
        addRefs(from: items, layout: .none, facts: CollageBridge.Facts(batch: batch))
    }

    func importTop(_ n: Int, batch: BatchStore) {
        let ids = batch.topPicks(n).ids
        addRefs(from: ids.compactMap { batch.item(withID: $0) }, layout: .none, facts: CollageBridge.Facts(batch: batch))
    }

    /// 水印页「拼图 (N) →」带过来的原图：认得出是批量页的照片按批量 id 进（带人脸、分数），认不出的按
    /// 文件进 —— 两种合起来只排一次版（分开导入会起两次求解，后回来的把先排的盖掉）。`order`：带过来的
    /// 顺序（批量 id 和 CollageBridge.fileID 穿插着）。张数有上限（handoffSingleLimit / handoffSpreadLimit）。
    /// `then(true)`：读完、排版发起之后再做（交接时套水印放这里，它的提示不会被「托盘加入 N 张」盖掉）；
    /// 一张都没带进来（都读不了、本来就没有）= `then(false)`（交接把占的号还回去）。进托盘、排版、then 里的
    /// 改动合成**一步撤销**：撤销一次回到交接之前。
    func importMixed(items: [BatchItem], files: [URL], order: [String], then: @escaping (Bool) -> Void) {
        addRefs(from: items, files: files, layout: .handoff(order, then: then))
    }

    private enum AfterImport {
        case none
        case solve([String])
        /// 水印页交接：排版有张数上限；进托盘 + 排版 + then 算一步撤销。
        case handoff([String], then: (Bool) -> Void)
    }

    /// `files`：外部文件（id 见 CollageBridge.fileID）。`facts`：场内名次、手动判的（不给 = 按 attach 时的批量页）。
    private func addRefs(from items: [BatchItem], files: [URL] = [], layout: AfterImport,
                         facts given: CollageBridge.Facts? = nil) {
        let facts = given ?? batch.map { CollageBridge.Facts(batch: $0) } ?? CollageBridge.Facts()
        guard !items.isEmpty || !files.isEmpty else {
            setNotice("没有可带进来的照片")
            if case .handoff(_, let then) = layout { then(false) }
            return
        }
        if items.isEmpty {
            busyText = "分析 \(files.count) 张照片的人脸…"
        } else {
            busyText = "读取 \(items.count + files.count) 张照片…"
        }
        let token = sessionToken
        // 带进来之后要排版的：读照片期间套了模板、撤销，读完就只进托盘、不再排（不能盖掉刚做的）。
        var ticket: SolveTicket?
        switch layout {
        case .none: break
        case .solve, .handoff: ticket = beginSolve()
        }
        // 交接张数超过单张拼图的上限：挑最好的几张排。挑片第一次要算特征（可能好几秒），和读照片一起放后台。
        var pickLimit: Int?
        if case .handoff(let ids, _) = layout, !isAlbum, Self.unique(ids).count > Self.handoffSingleLimit {
            pickLimit = Self.handoffSingleLimit
        }
        let limit = pickLimit
        Task { [weak self] in
            let (refs, picked) = await Task.detached(priority: .userInitiated) { () -> ([CollagePhotoRef], [String]?) in
                let refs = items.compactMap { CollageBridge.ref(from: $0, facts: facts) }
                    + files.compactMap(CollageBridge.ref(fromFile:))
                return (refs, limit.map { CollageSelect.pick($0, from: refs).map(\.id) })
            }.value
            guard let self, self.sessionToken == token else { return }
            self.busyText = nil
            switch layout {
            case .none:
                self.mergeIntoTray(refs)
            case .solve(let ids):
                self.mergeIntoTray(refs)
                if let ticket, ticket.generation == self.solveGeneration {
                    self.isSolving = false
                    self.layoutRequested(ids.filter { id in refs.contains { $0.id == id } })
                }
            case .handoff(let ids, let then):
                self.landHandoff(refs, order: ids, picked: picked, ticket: ticket, then: then)
            }
        }
    }

    // MARK: - 水印页交接

    /// 水印页「拼图 (N) →」一次最多排几张：单张拼图 9 张（再多格子太小，每张上的水印都看不清），相册一个
    /// 跨页 6 张。多的只进托盘。
    static let handoffSingleLimit = 9
    static let handoffSpreadLimit = 6

    /// 交接的照片读完了：进托盘、排版、then（套水印）合成一步撤销。排版是后台算完才落下来的，发起时就说好
    /// 不另记撤销（recordUndo: false），落下来也并进这一步。
    private func landHandoff(_ refs: [CollagePhotoRef], order: [String], picked: [String]?, ticket: SolveTicket?,
                             then: (Bool) -> Void) {
        let current = ticket.map { $0.generation == solveGeneration } ?? false
        if current { isSolving = false }
        guard !refs.isEmpty else {
            setNotice("带过来的照片都读不了")
            then(false)
            return
        }
        let loaded = Self.unique(order).filter { id in refs.contains { $0.id == id } }
        asOneUndoStep {
            mergeIntoTray(refs)
            // 读照片期间套了模板、撤销、又排了一版：只进托盘，不再排（同批量页）。
            if current { layoutHandoff(loaded, picked: picked) }
            then(true)
        }
    }

    /// 交接的排版。单张拼图超过上限：只排挑出来的那几张，其余留在托盘里。相册：新开一个跨页放；一个跨页
    /// 放不下就只进托盘 —— 不替用户点「自动编排」：它按托盘里全部照片把整本重排，已经排好的跨页都会换掉。
    private func layoutHandoff(_ ids: [String], picked: [String]?) {
        if isAlbum {
            let used = usedPhotoIDs
            let fresh = ids.filter { !used.contains($0) }
            guard fresh.count > Self.handoffSpreadLimit else {
                layoutRequested(ids, recordUndo: false)
                return
            }
            let hint = used.isEmpty ? "点「自动编排」排成相册" : "拖进跨页，或点「自动编排」用托盘里全部照片重排整本"
            setNotice("\(fresh.count) 张已放进托盘（一个跨页最多放 \(Self.handoffSpreadLimit) 张）：" + hint)
            return
        }
        guard ids.count > Self.handoffSingleLimit else {
            layoutRequested(ids, recordUndo: false)
            return
        }
        // 读照片时还是相册、读完切回了单张：没挑过，按带过来的顺序取前几张。
        let chosen = picked ?? Array(ids.prefix(Self.handoffSingleLimit))
        layoutRequested(chosen, recordUndo: false)
        setNotice("托盘放了 \(ids.count) 张，先排了挑出来的 \(chosen.count) 张，其余在托盘里")
    }

    /// 批量页「拼图 (N)」带进来的这几张：单张拼图按开关上的网格 / 散落排（以前一律排成网格）；相册在
    /// 当前跨页后面新开一个跨页放它们（以前直接把当前跨页换掉 —— 那一页原来的照片从书里没了，已经在
    /// 别的跨页上的照片还会出现两次），已经在相册里的不重复放。
    /// `recordUndo = false`：跟着别的操作一起（交接），排版落下来不另记撤销。
    private func layoutRequested(_ ids: [String], recordUndo: Bool = true) {
        guard !ids.isEmpty else { return }
        guard isAlbum else {
            layoutFresh(photoIDs: ids, recordUndo: recordUndo)
            return
        }
        let used = usedPhotoIDs
        let fresh = Self.unique(ids).filter { !used.contains($0) }
        guard !fresh.isEmpty else {
            setNotice("这几张已经都在相册的跨页里了")
            return
        }
        if recordUndo { pushUndo() }
        let at = min(project.pages.count, pageIndex + 1)
        project.pages.insert(CollagePage(root: CollageLayout.blankRoot(for: project.canvas)), at: at)
        pageIndex = at
        commitEdit()
        // 新跨页和排版算同一步撤销。
        solve(photoIDs: fresh, recordUndo: false)
        setNotice("在第 \(at + 1) 个跨页放了 \(fresh.count) 张" + (fresh.count < ids.count ? "（其余已经在相册里）" : ""))
    }

    /// `layout`：读完直接排一版（同批量页「拼图 (N)」）。
    func addFiles(_ urls: [URL], layout: Bool = false) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                              options: [.skipsHiddenFiles])) ?? []
                files += contents.filter { ImageLoader.imageExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.path < $1.path }
            } else if ImageLoader.imageExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        guard !files.isEmpty else {
            setNotice("没有可导入的照片（格式不支持）")
            return
        }
        addRefs(from: [], files: files, layout: layout ? .solve(files.map(CollageBridge.fileID)) : .none)
    }

    private func mergeIntoTray(_ refs: [CollagePhotoRef]) {
        let existing = Set(project.photos.map(\.id))
        let fresh = refs.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else {
            if !refs.isEmpty { setNotice("这些照片已经在托盘里了") }
            return
        }
        pushUndo()
        project.photos.append(contentsOf: fresh)
        scheduleProjectSave()
        computeHints(for: fresh)
        setNotice("托盘加入 \(fresh.count) 张")
    }

    /// 从托盘拿掉；用到它的格子变成空格（占位）。
    func removeFromTray(_ id: String) {
        cancelSolveIfRunning()
        pushUndo()
        project.photos.removeAll { $0.id == id }
        pruneMarkSkips()
        for i in project.pages.indices {
            var root = project.pages[i].root
            for path in root.leafPaths() where root.node(at: path)?.cell?.photoID == id {
                root.update(at: path) { $0.cell?.photoID = nil; $0.cell?.crop = nil }
            }
            project.pages[i].root = root
            project.pages[i].contactSheet?.frames.removeAll { $0 == id }
            project.pages[i].items.removeAll { $0.kind == .photo && $0.photoID == id }
            // 贴在那张相纸上的胶带一起拿掉（以前留在原地悬空）。
            project.pages[i].items = CollageItems.pinAll(project.pages[i].items, canvas: project.canvas)
        }
        commitEdit()
    }

    func clearTray() {
        cancelPendingSolve()
        pushUndo()
        project.photos.removeAll()
        project.pages.removeAll()
        pruneMarkSkips()
        pageIndex = 0
        clearAlternatives()
        albumDropped = []
        commitEdit()
    }

    /// 「这张不加」只记托盘里的照片：拿出托盘就忘掉（以后再带进来照常加水印，摘要也不再数它）。
    /// 直接改工程，和拿掉照片是同一步撤销。
    private func pruneMarkSkips() {
        guard let skips = project.watermark?.skipPhotoIDs, !skips.isEmpty else { return }
        let inTray = Set(project.photos.map(\.id))
        let kept = skips.filter { inTray.contains($0) }
        if kept.count != skips.count { project.watermark?.skipPhotoIDs = kept }
    }

    private func computeHints(for photos: [CollagePhotoRef]) {
        let todo = photos.filter { hints[$0.id] == nil }
        // 已经算过路人信息的（这一场早先进过托盘、拿出去又带回来）：亮度、黑白直接抄进新的托盘照片。以前只在一批
        // 算完时抄，都算过就不抄，再带进来的照片「黑白」「亮度」是空的，自动编排的整章黑白就没了。
        if todo.count < photos.count { adoptHintFacts() }
        guard !todo.isEmpty else { return }
        let previous = hintTask
        let token = sessionToken
        hintRunsPending += 1
        hintTask = Task { [weak self] in
            // 换了场次、作废了也算跑完（早退走这里）；正常跑完在抄完事实、+1 版本号之后才减。
            defer { self?.hintRunsPending -= 1 }
            await previous?.value
            for p in todo {
                if Task.isCancelled { return }
                let h = await Task.detached(priority: .utility) { CollageVision.hints(for: p) }.value
                guard let self, self.sessionToken == token else { return }
                self.hints[p.id] = h
            }
            self?.adoptHintFacts()
            self?.hintsVersion += 1
            self?.setNeedsRender()
            // 蒙版预热另起一个任务（在这一批减一之前排上，命令行等的计数不会中间断一下）。
            self?.prewarmMasks(todo, token: token)
        }
    }

    /// 主体蒙版预热：这一页的先算，其余按分数从高到低（多半是主图）。渲染用到时自己同步拿，这里只是先填好内存和
    /// 磁盘缓存；头顶、覆盖率抄进 Hints 给挑主图这类便宜的用处看。一批接一批（Vision 只有一个在算），不放在路人信息
    /// 的任务里：新加进托盘的照片不用等上一批蒙版（几十张 × 15–20 ms）算完才开始算路人。
    private func prewarmMasks(_ photos: [CollagePhotoRef], token: UUID) {
        let previous = maskTask
        maskRunsPending += 1
        maskTask = Task { [weak self] in
            defer { self?.maskRunsPending -= 1 }
            await previous?.value
            guard let order = self?.maskOrder(photos) else { return }
            for p in order {
                if Task.isCancelled { return }
                let m = await Task.detached(priority: .utility) { CollageMasks.mask(for: p) }.value
                guard let self, self.sessionToken == token else { return }
                if let m, var h = self.hints[p.id] {
                    h.headTop = m.headTop
                    h.maskCoverage = m.coverage
                    self.hints[p.id] = h
                }
            }
            self?.masksVersion += 1
            self?.setNeedsRender()
        }
    }

    /// 蒙版预热的先后：当前页上的照片先，其余按分数从高到低。
    private func maskOrder(_ photos: [CollagePhotoRef]) -> [CollagePhotoRef] {
        let onPage = Set(page?.photoIDs ?? [])
        return photos.sorted { a, b in
            let pa = onPage.contains(a.id)
            let pb = onPage.contains(b.id)
            if pa != pb { return pa }
            if a.score != b.score { return a.score > b.score }
            return a.id < b.id
        }
    }

    // MARK: - 排版

    /// 自动挑 n 张（分数 + 多样性）排一版；n 为空 = 托盘里全部（最多 12 张）。
    func autoLayout(count: Int?) {
        let pool = project.photos
        guard !pool.isEmpty else {
            setNotice("托盘是空的：先从批量页带照片进来")
            return
        }
        let n = min(count ?? min(pool.count, 12), pool.count)
        // 按开关上显示的排（撤销回网格之后开关显示网格，偏好可能还是散落）。
        let style = effectiveLayoutStyle
        busyText = "挑片中…"
        // 挑片也在作废机制里：挑片期间（第一次要算特征，可能好几秒）套了模板、撤销、换了模式，
        // 挑完不能再把它们盖掉。
        let ticket = beginSolve()
        Task { [weak self] in
            let chosen = await Task.detached(priority: .userInitiated) { CollageSelect.pick(n, from: pool) }.value
            guard let self, self.sessionToken == ticket.session else { return }
            if self.busyText == "挑片中…" { self.busyText = nil }
            guard ticket.generation == self.solveGeneration else { return }
            self.isSolving = false
            if style == .scatter, !self.isAlbum {
                self.scatter(photoIDs: chosen.map(\.id), spec: self.page?.scatter ?? CollageScatterSpec())
            } else {
                self.solve(photoIDs: chosen.map(\.id))
            }
        }
    }

    /// 开关上显示的：有版就看这一页是不是散落版（撤销、换场次之后也对得上），没版看偏好。
    var effectiveLayoutStyle: LayoutStyle {
        guard let page else { return layoutStyle }
        return page.freeform ? .scatter : .grid
    }

    /// 空画布上第一次排版（拖进第一张照片）：按开关上的网格 / 散落。
    func layoutFresh(photoIDs: [String], recordUndo: Bool = true) {
        if effectiveLayoutStyle == .scatter, !isAlbum {
            scatter(photoIDs: photoIDs, spec: page?.scatter ?? CollageScatterSpec(), recordUndo: recordUndo)
        } else {
            solve(photoIDs: photoIDs, recordUndo: recordUndo)
        }
    }

    /// 网格 ↔ 散落：同一组照片换一种排法（已经有版的话立刻重排）。网格的文字格、压字记在散落页上，
    /// 文字格变成同位置的手写字；切回网格时照着恢复。
    func setLayoutStyle(_ style: LayoutStyle) {
        if style != layoutStyle {
            layoutStyle = style
            scheduleStateSave()
        }
        // 相册的跨页由编排决定，这个开关只管单张拼图。
        guard !isAlbum, let page else { return }
        let toScatter = style == .scatter
        guard toScatter != page.freeform else { return }
        cancelPendingSolve()
        guard !page.photoIDs.isEmpty else {
            // 页上只有贴纸、手写字：不用重排，直接换页面类型（以前什么都不做，开关又弹回去）。
            pushUndo()
            var p = page
            p.freeform = toScatter
            if toScatter {
                p.scatter = p.scatter ?? CollageScatterSpec()
                p.items = itemsKeptForScatter(from: page)
                // 帧全拿掉了的印样：离开印样（不然一页又是散落又是印样，渲染走印样、拖进来的却放成相纸）；
                // 印样的切分树是个空叶子，没有网格可记。
                p.gridRoot = page.contactSheet == nil ? page.root : nil
                p.contactSheet = nil
                p.root = .leaf(CollageCell())
            } else if let grid = restoredGrid(from: page) {
                p.items = decorationsForGrid(from: page, consumed: consumedSourceItems(page))
                p.root = grid
                p.gridRoot = nil
            } else {
                // 记着的网格对不上了（照片全删了）：文字格回不去，那些字留成手写字。
                p.items = decorationsForGrid(from: page, consumed: [])
                p.root = CollageLayout.blankRoot(for: project.canvas)
                p.gridRoot = nil
            }
            setPage(p)
            commitEdit()
            return
        }
        if toScatter {
            scatter(photoIDs: page.photoIDs, spec: page.scatter ?? CollageScatterSpec())
        } else if let grid = restoredGrid(from: page) {
            // 照片没变：原样还原切过来之前的网格（重新求解会把顶上的标题横幅排成角落里的小格）。
            pushUndo()
            let decorations = decorationsForGrid(from: page, consumed: consumedSourceItems(page))
            var p = CollagePage(root: grid, items: decorations, freeform: false, scatter: page.scatter)
            p.id = page.id
            setPage(p)
            clearAlternatives()
            commitEdit()
        } else {
            solve(photoIDs: page.photoIDs)
        }
    }

    /// 散落切回网格、这页的照片还是那几张：还原切过来之前的网格 —— 手写字改过的写回对应文字格，
    /// 删掉了的文字格去掉。照片有增减就返回 nil（重新求解）。
    private func restoredGrid(from page: CollagePage) -> CollageNode? {
        guard page.freeform, var grid = page.gridRoot, Set(grid.photoIDs) == Set(page.photoIDs) else { return nil }
        var converted: [Int: CollageItem] = [:]
        for it in page.items {
            if let i = it.sourceCell, converted[i] == nil { converted[i] = it }
        }
        let textPaths = grid.leafPaths().filter { grid.node(at: $0)?.cell?.kind == .text }
        var removed: [Int] = []
        for (index, path) in textPaths.enumerated() {
            if let t = converted[index]?.text {
                grid.update(at: path) { $0.cell?.text = t }
            } else {
                removed.append(index)
            }
        }
        // 删文字格不改变剩下叶子的阅读顺序：按序号从小到大删，每删一个后面的序号减一。
        for (k, index) in removed.enumerated() {
            let paths = grid.leafPaths().filter { grid.node(at: $0)?.cell?.kind == .text }
            guard !grid.isLeaf, paths.indices.contains(index - k) else { break }
            grid = CollageLayout.remove(at: paths[index - k], from: grid)
        }
        return grid
    }

    /// 托盘菜单「只用这张 / 加进当前版」：按这一页现在的排法重排（散落版不能被换成网格）。
    func relayout(photoIDs: [String]) {
        if isFreeform {
            scatter(photoIDs: photoIDs, spec: page?.scatter ?? CollageScatterSpec())
        } else {
            solve(photoIDs: photoIDs)
        }
    }

    /// 散落版：同一组照片撒一批备选，当前页换成最好的那版。页上留下来的横排标题占着的上下一截让开。
    /// `recordUndo = false`：跟着别的操作一起的（切相册时重撒），和那个操作算同一步撤销。
    func scatter(photoIDs: [String], spec: CollageScatterSpec, recordUndo: Bool = true) {
        let map = photoMap
        let photos = Self.unique(photoIDs).compactMap { map[$0] }
        guard !photos.isEmpty else { return }
        solveSeed &+= 1
        let ctx = context
        let seed = solveSeed
        let kept = page.map { itemsKeptForScatter(from: $0) } ?? []
        let reserve = CollageScatter.reserveBands(for: kept, canvas: project.canvas)
        let ticket = beginSolve(recordUndo: recordUndo)
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                CollageScatter.generate(photos: photos, spec: spec, context: ctx, seed: seed, keep: 12, reserve: reserve)
            }.value
            self?.finishSolve(ticket, results, scatter: spec)
        }
    }

    /// 散落重撒时这一页留下来的图层：手写字、手动加的贴纸（自动撒的相纸和胶带换新的；相纸按这一页
    /// 的照片重新撒）。从网格切过来的：网格上的贴纸、手写字，再加上文字格转成的手写字。
    private func itemsKeptForScatter(from page: CollagePage) -> [CollageItem] {
        let loose = page.items.filter { $0.kind != .photo && !$0.generated }
        if page.freeform { return loose }
        // 网格上的胶带、回形针是贴在格子边上的：照片撒开以后它们没有着落，不带过去。
        let keep = loose.filter { !($0.kind == .sticker && ($0.sticker.isTape || $0.sticker == .clip)) }
        return keep + textItems(fromGrid: page.root)
    }

    /// 散落切回网格时，哪些「文字格转来的字」会变回文字格：记着的网格里有这一格、每一格认第一个
    /// （和 textCellsForGrid、restoredGrid 同一个规则）。其余的（复制出来的、网格已经没了的）留成手写字。
    private func consumedSourceItems(_ page: CollagePage) -> Set<UUID> {
        guard let grid = page.gridRoot else { return [] }
        let textCount = grid.leaves.filter { $0.kind == .text }.count
        var seen = Set<Int>()
        var out = Set<UUID>()
        for it in page.items {
            if let i = it.sourceCell, i < textCount, seen.insert(i).inserted { out.insert(it.id) }
        }
        return out
    }

    /// 散落 → 网格带过去的装饰：自动撒的相纸和胶带不要、贴在相纸上的不要（相纸变成格子了），
    /// 变回文字格的字不要；其余手写字、贴纸留着（不再是文字格转来的）。
    private func decorationsForGrid(from page: CollagePage, consumed: Set<UUID>) -> [CollageItem] {
        page.items
            .filter { $0.kind != .photo && !$0.generated && $0.attach == nil && !consumed.contains($0.id) }
            .map { item -> CollageItem in
                var out = item
                out.sourceCell = nil
                return out
            }
    }

    /// 网格的文字格变成同位置、同大小的手写字图层（散落版不画格子，标题不能凭空没了）。
    private func textItems(fromGrid root: CollageNode) -> [CollageItem] {
        let canvas = project.canvas
        let frames = CollageLayout.pageGeometry(root, canvas: canvas, style: project.style).frames
        let textPaths = root.leafPaths().filter { root.node(at: $0)?.cell?.kind == .text }
        var out: [CollageItem] = []
        for (index, path) in textPaths.enumerated() {
            guard let frame = frames.first(where: { $0.path == path }), let text = frame.cell.text else { continue }
            let r = frame.rect.cgRect
            var item = CollageItem(kind: .text)
            item.text = text
            item.sourceCell = index
            item.cx = Double(r.midX) / Double(max(1, canvas.width))
            item.cy = Double(r.midY) / Double(max(1, canvas.height))
            item.width = Double(r.width) / canvas.shortSide
            item.height = Double(r.height) / canvas.shortSide
            item.rotation = 0
            out.append(item)
        }
        return out
    }

    /// 重排网格时要带上的文字格：网格页就是它自己的文字格；散落页是切过来之前记着的那些 ——
    /// 内容按散落版上对应的手写字（可能改过），那行手写字删掉了的文字格也不要。
    private func textCellsForGrid(from page: CollagePage) -> [CollageCell] {
        guard page.freeform else { return page.root.leaves.filter { $0.kind == .text } }
        guard let grid = page.gridRoot else { return [] }
        var converted: [Int: CollageItem] = [:]
        for it in page.items {
            if let i = it.sourceCell, converted[i] == nil { converted[i] = it }
        }
        var out: [CollageCell] = []
        for (index, cell) in grid.leaves.filter({ $0.kind == .text }).enumerated() {
            guard let item = converted[index] else { continue }
            var c = cell
            if let t = item.text { c.text = t }
            out.append(c)
        }
        return out
    }

    /// 去重、保序：同一张照片复制过一份，重排时只排一次。
    nonisolated static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// 用这些照片（按给定顺序）求解一批备选，当前页换成最好的那版。这一页的文字格（散落页记着的
    /// 网格文字格）一起排进去 —— 以前托盘菜单「加进当前版」、切回网格都会把标题格丢掉。
    func solve(photoIDs: [String], recordUndo: Bool = true) {
        let map = photoMap
        let photos = Self.unique(photoIDs).compactMap { map[$0] }
        guard !photos.isEmpty else { return }
        solveSeed &+= 1
        let texts = page.map { textCellsForGrid(from: $0) } ?? []
        runSolve(photos: photos, texts: texts, seed: solveSeed, recordUndo: recordUndo)
    }

    /// 换一批：同一组照片、新的随机种子；有锁定的格子就只重排没锁的区域。最优解常常还是现在这个
    /// 结构（只换了照片位置，看起来等于没换）—— 落版时避开这一页最近出过的几种形状。
    func regenerate() {
        guard let root, let page else { return }
        if isAlbum, project.albumTheme == .fineArt {
            // fine-art 跨页是编排按版心算的（完整显示、卡纸留白、不跨缝），求解器的满铺网格会把它拆掉。
            setNotice("婚礼 fine-art 的跨页按编排出版式，没有「换一批」：想重排点「自动编排」，或把编排换回「默认」")
            return
        }
        if page.contactSheet != nil {
            // 印样的版式由帧和规格定（一卷就是一卷），没有「换一版」。
            setNotice("印样按拍摄先后排，没有别的版：改规格、每条帧数在「版式 › 印样」里")
            return
        }
        if page.freeform {
            scatter(photoIDs: page.photoIDs, spec: page.scatter ?? CollageScatterSpec())
            return
        }
        solveSeed &+= 1
        let avoid = noteShape(root)
        let hasLocks = root.leaves.contains { $0.locked }
        if hasLocks {
            let ctx = context
            let seed = solveSeed
            let ticket = beginSolve()
            Task { [weak self] in
                let results = await Task.detached(priority: .userInitiated) {
                    CollageLayout.solveKeepingLocks(current: root, context: ctx, tries: 6000, keep: 16, seed: seed)
                }.value
                self?.finishSolve(ticket, results, avoiding: avoid)
            }
        } else {
            let map = photoMap
            let photos = Self.unique(root.photoIDs).compactMap { map[$0] }
            let texts = root.leaves.filter { $0.kind == .text }
            runSolve(photos: photos, texts: texts, seed: solveSeed, avoiding: avoid)
        }
    }

    /// 换一批最近出过的形状（按页记；换了页重记）：连按几次不在同两版之间来回跳。
    private var recentShapes: (pageID: UUID?, classes: [String]) = (nil, [])

    private func noteShape(_ root: CollageNode) -> [String] {
        let id = page?.id
        if recentShapes.pageID != id { recentShapes = (id, []) }
        let shape = root.shapeClass
        recentShapes.classes.removeAll { $0 == shape }
        recentShapes.classes.append(shape)
        if recentShapes.classes.count > 3 { recentShapes.classes.removeFirst() }
        return recentShapes.classes
    }

    private func runSolve(photos: [CollagePhotoRef], texts: [CollageCell], seed: UInt64, avoiding: [String] = [],
                          recordUndo: Bool = true) {
        let ctx = context
        let ticket = beginSolve(recordUndo: recordUndo)
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                CollageLayout.solve(CollageLayout.Request(photos: photos, textCells: texts, context: ctx,
                                                          tries: 16000, keep: 18, seed: seed))
            }.value
            self?.finishSolve(ticket, results, avoiding: avoiding)
        }
    }

    /// 发起求解时记下：第几次、哪个场次、哪一页。回来时任何一样变了就丢弃 ——
    /// 算到一半点了别的跨页，结果不能盖到那一页上；换了场次更不能写进新场次的文件。
    private struct SolveTicket {
        let generation: Int
        let session: UUID
        let pageID: UUID?
        /// false = 结果落下来不另记撤销（和发起它的操作算同一步）。
        var recordUndo = true
        /// 发起时撤销栈记过几步（undoPushes）。
        var pushes = 0
    }

    /// 用户做了会整页换掉的操作（套模板、撤销、切网格/散落、换模式）：还在算的那次求解作废，
    /// 不能等它回来把用户刚做的覆盖掉。
    private func cancelPendingSolve() {
        solveGeneration += 1
        isSolving = false
    }

    /// 编辑这一页（挪格子、加贴纸、拖字、换画布……）：还在算的「换一批」作废 —— 后做的动作说了算，
    /// 算完回来不能把刚做的编辑盖掉（相册里还会让同一张照片出现在两个跨页上）。没在算就什么都不动
    /// （备选缩略图按代号认领，不能无故作废）。
    private func cancelSolveIfRunning() {
        guard isSolving else { return }
        cancelPendingSolve()
    }

    private func beginSolve(recordUndo: Bool = true) -> SolveTicket {
        solveGeneration += 1
        isSolving = true
        return SolveTicket(generation: solveGeneration, session: sessionToken, pageID: page?.id, recordUndo: recordUndo,
                           pushes: undoPushes)
    }

    private func finishSolve(_ ticket: SolveTicket, _ results: [CollageLayout.Scored],
                             scatter: CollageScatterSpec? = nil, avoiding: [String] = []) {
        guard ticket.generation == solveGeneration else { return }   // 更新的一次还在算
        isSolving = false
        guard ticket.session == sessionToken, ticket.pageID == page?.id else { return }
        let ordered = avoiding.isEmpty ? results : CollageLayout.preferringNewShape(results, avoiding: avoiding)
        adopt(ordered, scatter: scatter, recordUndo: ticket.recordUndo)
        if !ticket.recordUndo, !ordered.isEmpty { carryIntoLaterSteps(since: ticket.pushes) }
    }

    /// 不另记撤销的求解（交接、切相册重撒）算在发起它的那一步里；算的时候用户又做了不作废求解的改动（改水印、
    /// 样式、标题）、记了新的几步：这几步的快照里也换上排好的这一页 —— 撤销那个小改动只退那个改动，不连排版
    /// 一起退掉（不然交接排出来的版就再也回不来了）。
    private func carryIntoLaterSteps(since pushes: Int) {
        let later = min(undoPushes - pushes, undoStack.count)
        guard later > 0, let current = page else { return }
        for i in undoStack.indices.suffix(later) {
            guard let j = undoStack[i].pages.firstIndex(where: { $0.id == current.id }) else { continue }
            undoStack[i].pages[j] = current
        }
    }

    private func adopt(_ results: [CollageLayout.Scored], scatter: CollageScatterSpec? = nil, recordUndo: Bool = true) {
        guard let best = results.first else {
            setNotice(scatter == nil ? "没解出合适的版式：照片太多或比例差太远，试试换画布比例"
                                     : "散落版没撒出来：照片太多，试试少几张")
            return
        }
        if recordUndo { pushUndo() }
        alternativesScatter = scatter
        applyScored(best)
        alternatives = results
        alternativesPageID = page?.id
        alternativeIndex = 0
        commitEdit()
        renderAlternativeThumbs()
    }

    /// 一个备选落到当前页。
    private func applyScored(_ scored: CollageLayout.Scored) {
        setPage(pageFor(scored, replacing: page))
        selectedItem = nil
    }

    /// 一个备选落到页上会变成什么样 —— 套用和备选缩略图用同一个函数，看到的就是点下去的。
    /// 散落版：自动撒的相纸、胶带换新的；手写字、手动加的贴纸留着（贴在相纸上的跟到同一张照片的新相纸上）；
    /// 网格切过来的文字格变成手写字，网格本身记在页上。
    /// 网格版：换切分树，压字按照片带过去（散落切回来的从记着的网格里带），贴纸、手写字留着；
    /// 散落的撒法也留着，再切散落照原来的撒。
    private func pageFor(_ scored: CollageLayout.Scored, replacing old: CollagePage?) -> CollagePage {
        let canvas = project.canvas
        var out: CollagePage
        if let fresh = scored.items {
            let kept = old.map { itemsKeptForScatter(from: $0) } ?? []
            let items = CollageScatter.merge(fresh: fresh, kept: kept, old: old?.items ?? [], canvas: canvas)
            let grid: CollageNode? = old.flatMap { $0.freeform ? $0.gridRoot : $0.root }
            out = CollagePage(root: scored.root, items: items, freeform: true,
                              scatter: alternativesScatter ?? old?.scatter ?? CollageScatterSpec(), gridRoot: grid)
        } else {
            var root = scored.root
            let overlaySource: CollageNode? = old.flatMap { $0.freeform ? $0.gridRoot : $0.root }
            if let overlaySource {
                root = CollageLayout.carryOverlays(from: overlaySource, into: root)
            }
            let decorations: [CollageItem]
            if let old, old.freeform {
                // 散落 → 网格：相纸和胶带是按散落摆的，不要；变回文字格的字不要（求解时已经带上了）。
                decorations = decorationsForGrid(from: old, consumed: consumedSourceItems(old))
            } else {
                decorations = old?.items ?? []
            }
            out = CollagePage(root: root, items: decorations, freeform: false, scatter: old?.scatter)
        }
        out.id = old?.id ?? out.id
        // 这一页单独设的色调（整页黑白）是页的设置，换一批、换备选都留着。
        out.look = old?.look
        return out
    }

    private func clearAlternatives() {
        alternatives = []
        alternativeThumbs = []
        alternativesPageID = nil
        alternativesScatter = nil
        alternativeIndex = 0
    }

    func applyAlternative(_ index: Int) {
        guard alternatives.indices.contains(index) else { return }
        guard alternativesPageID == page?.id else {
            clearAlternatives()
            return
        }
        // 点的是上一批的备选、新的一批还在算：用户点的这版说了算，别让新结果回来盖掉。
        cancelSolveIfRunning()
        pushUndo()
        alternativeIndex = index
        applyScored(alternatives[index])
        selection = nil
        commitEdit()
    }

    func nextAlternative() {
        guard !alternatives.isEmpty else {
            if !isSolving { regenerate() }
            return
        }
        applyAlternative((alternativeIndex + 1) % alternatives.count)
    }

    func previousAlternative() {
        guard !alternatives.isEmpty else { return }
        applyAlternative((alternativeIndex - 1 + alternatives.count) % alternatives.count)
    }

    func refit() {
        guard let root else { return }
        pushUndo()
        setRoot(CollageLayout.refit(root, context: context))
        commitEdit()
    }

    private func renderAlternativeThumbs() {
        // 和 applyScored 同一个函数拼页：压字、贴纸、手写字都画上，缩略图就是点下去的样子。
        let current = page
        let items = alternatives.map { s -> CollagePage in pageFor(s, replacing: current) }
        let generation = solveGeneration
        let pageID = alternativesPageID
        var snapshot = project
        let hints = self.hints
        // 备选条上 64pt 高：按长边 150 渲，相册跨页（2:1）只有 75px 高，放到 128px 是糊的 —— 高度也要够。
        let c = project.canvas
        let scale = min(1, max(150 / Double(max(c.width, c.height)), 136 / Double(max(1, c.height))))
        Task { [weak self] in
            let thumbs = await Task.detached(priority: .utility) { () -> [NSImage] in
                // 渲染失败也占个位：下标必须和 alternatives 一一对应，点第 5 张就是第 5 版。
                items.map { page in
                    snapshot.pages = [page]
                    var opts = CollageRender.Options(scale: scale)
                    opts.includeBleed = false
                    guard let cg = CollageRender.render(page: page, project: snapshot, hints: hints, options: opts) else {
                        return NSImage(size: NSSize(width: 60, height: 60))
                    }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }.value
            guard let self, self.solveGeneration == generation, self.alternativesPageID == pageID,
                  self.alternatives.count == thumbs.count else { return }
            self.alternativeThumbs = thumbs
        }
    }

    // MARK: - 一键成套

    /// 一键成套：后台生成一整套，落下来替换当前工程（一步撤销）。生成期间套了模板、撤销、换了场次 = 作废。
    /// 还没做的（生成返回 nil）只提示，不动工程、不记撤销。`then`：落下来（或作废、没生成）之后（命令行等它）。
    /// coverStep：「换封面」（出一期）在主图候选里往后轮几张（0 = 照常出一套）。
    func applyKit(_ kit: CollageKitID, coverStep: Int = 0, then: (() -> Void)? = nil) {
        let done: ((KitOutcome) -> Void)? = then.map { t in { (_: KitOutcome) in t() } }
        applyKit(kit, coverStep: coverStep, outcome: done)
    }

    /// 一键成套的结局（实时桥要分清，DESIGN §10.6「STEP 1 不做了」第 1 条）：只看撤销计数分不出「被作废」和
    /// 「没出来 / 没变化」（都是 +0）。
    enum KitOutcome: Equatable {
        /// 落下来了（一步撤销）。
        case landed
        /// 和现在的一样，工程没动。
        case unchanged
        /// 托盘（和这一场）里没有能用的照片，没出来。
        case notGenerated
        /// 算的时候被作废：用户做了会整页换掉的操作，或者换了场次。没落地、没记撤销。
        case superseded(SupersededBy)
    }

    enum SupersededBy: Equatable {
        case userEdit, sessionSwitched
    }

    /// 带结局的版本：`outcome` 在每种结局里恰好调一次（托盘空时直接调，其余在落地任务的 defer 里）。
    /// 界面和命令行走上面 `then:` 那个，调的是同一份实现。
    func applyKit(_ kit: CollageKitID, coverStep: Int = 0, outcome: ((KitOutcome) -> Void)?) {
        let items = batch?.items ?? []
        let facts = batch.map { CollageBridge.Facts(batch: $0) } ?? CollageBridge.Facts()
        guard !project.photos.isEmpty || !items.isEmpty else {
            setNotice("托盘是空的：先带照片进来")
            outcome?(.notGenerated)
            return
        }
        cancelPendingSolve()
        solveSeed &+= 1
        let context = CollageKits.Context(project: project, tray: project.photos, batchItems: { items }, facts: facts,
                                          hints: hints, seed: solveSeed, coverStep: coverStep)
        let busy = "成套「\(kit.name)」…"
        busyText = busy
        let ticket = beginSolve()
        // 测试宿主的 test.delay_next：这一次算完以后、落地之前多等一会儿（GUI 从不设，永远是 0）
        let delay = testKitLandingDelay
        testKitLandingDelay = 0
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { kit.generate(context) }.value
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            var end = KitOutcome.superseded(.sessionSwitched)
            defer { outcome?(end) }
            guard let self, self.sessionToken == ticket.session else { return }
            if self.busyText == busy { self.busyText = nil }
            end = .superseded(.userEdit)
            guard ticket.generation == self.solveGeneration else { return }
            self.isSolving = false
            guard let generated = result, !generated.pages.isEmpty else {
                end = .notGenerated
                // 三套都做好了：没出来是因为没有能用的照片（整本婚礼相册只编托盘里的，不从这一场借）。
                let why = kit == .weddingAlbum && self.project.photos.isEmpty
                    ? "按托盘里的照片编：托盘是空的，先带精选进来" : "托盘（和这一场）里没有能用的照片"
                self.setNotice("「\(kit.name)」没出来：\(why)，工程没动")
                return
            }
            // 什么都没变（「换封面」没有别的主图候选、同一套又出一遍）：不记撤销，说一声。
            guard generated != self.project else {
                end = .unchanged
                self.setNotice(coverStep > 0 ? "「换封面」：没有别的主图候选，封面没换" : "「\(kit.name)」：和现在的一样，工程没动")
                return
            }
            end = .landed
            self.pushUndo()
            if generated.watermark != self.project.watermark { self.watermarkRevision += 1 }
            self.project = generated
            self.pageIndex = 0
            if generated.mode == .single, let first = generated.pages.first {
                self.layoutStyle = first.freeform ? .scatter : .grid
                self.scheduleStateSave()
            }
            self.clearAlternatives()
            self.selection = nil
            self.selectedItem = nil
            // fine-art 编排的成套相册（整本婚礼相册）：没上版的（同一场只留精选、相似拿掉的；废片不算）在托盘里标「拿掉」，
            // 和「自动编排」一样。别的成套（单张、印样……）没有「拿掉」这回事，照旧清空。
            let used = generated.usedPhotoIDs
            self.albumDropped = generated.mode == .album && generated.albumTheme == .fineArt
                ? generated.photos.filter { !used.contains($0.id) && $0.verdict != .reject } : []
            self.commitEdit()
            // 成套可能带进托盘里没有的照片（印样的废片、整场的帧）：补算路人信息。
            self.computeHints(for: generated.photos)
            let unit = generated.mode == .album ? "个跨页" : "页"
            let cover = coverStep > 0 ? CollageStyleFashion.coverPhotoID(generated) : nil
            self.setNotice(cover.map { "「换封面」：封面换成 \($0)（不满意可以撤销）" }
                           ?? "「\(kit.name)」：\(generated.pages.count) \(unit)（不满意可以撤销）")
        }
    }

    // MARK: - 模板

    var allTemplates: [CollageTemplate] { CollageTemplates.builtin + userTemplates }

    /// 套模板：照片 = 当前页上的（不够就从托盘按分数补）。模板带的画布/样式一起换上。
    func applyTemplate(_ template: CollageTemplate) {
        var ids = Self.unique(page?.photoIDs ?? [])
        if template.contactSheet != nil {
            // 印样：托盘的照片按拍摄先后排成一卷（不按分数挑；相册里别的跨页用了的不拿；跨页上放在右页）。
            ids = contactPool.map(\.id)
        } else if ids.count < template.photoSlots {
            // 相册：别的跨页已经用了的不拿（同一张不能出现在两个跨页上）。
            let used = Set(ids).union(isAlbum ? usedPhotoIDs : [])
            let extra = project.photos.filter { !used.contains($0.id) }.sorted { $0.score > $1.score }
            ids += extra.prefix(template.photoSlots - ids.count).map(\.id)
        }
        let map = photoMap
        let photos = ids.compactMap { map[$0] }
        cancelPendingSolve()
        pushUndo()
        // 相册的样式是整本共用的：套模板只换这一页的版式，不把其他跨页的底色、色调一起改了。单张模式里有好几页的
        // （出一期四页、按卷出印样一卷一页）同样：画布、样式是整套共用的，只换这一页 —— 以前在第 2 页套报纸风，
        // 没动过的封面也成了网点米色纸。
        let shared = isAlbum || project.pages.count > 1
        let otherCanvas: Bool = template.canvas.map { $0 != project.canvas } ?? false
        let otherStyle: Bool = template.style.map { $0 != project.style } ?? false
        let keptLook = !isAlbum && shared && (otherCanvas || otherStyle)
        if let canvas = template.canvas, !shared { project.canvas = canvas }
        if let style = template.style, !shared { project.style = style }
        solveSeed &+= 1
        var newPage = CollageTemplates.apply(template, photos: photos, context: context, seed: solveSeed)
        newPage.id = page?.id ?? newPage.id
        // 版式、压字跟模板走；这一页、这几张照片单独设的色调（整页黑白、彩色里那张黑白）留着。
        if newPage.look == nil { newPage.look = page?.look }
        if let old = page, !old.freeform, !newPage.freeform {
            newPage.root = CollageLayout.carryCellLooks(from: old.root, into: newPage.root)
        }
        setPage(newPage)
        if !isAlbum {
            layoutStyle = newPage.freeform ? .scatter : .grid
            scheduleStateSave()
        }
        clearAlternatives()
        selection = nil
        selectedItem = nil
        commitEdit()
        // 印样模板：一页最多一卷（或模板给的格数），托盘多出来的说一声。
        let dropped = template.contactSheet == nil ? 0 : photos.count - (newPage.contactSheet?.frames.count ?? 0)
        // 婚礼相册的跨页模板在单张模式里套：画布换成了 30×30 跨页，画布菜单里没有它 —— 说一声该去哪排整本。
        let spreadInSingle = !shared && template.category == CollageStyleFineArt.category
        let others = project.pages.count - 1
        setNotice("已套用「\(template.name)」" + (isAlbum && template.style != nil ? "（相册里只换版式，样式整本统一）" : "")
                  + (keptLook ? "（这一套有 \(others + 1) 页：只换这一页的版式，画布和样式各页共用、没跟着模板换，"
                     + "别的 \(others) 页没动；要整套换样式用「样式」里的预设）" : "")
                  + (dropped > 0 ? "（这一页放不下的 \(dropped) 张没上）" : "")
                  + (spreadInSingle ? "（这是相册跨页模板，画布换成了 30×30cm 跨页；排整本婚礼相册请切到「相册」模式）" : ""))
    }

    /// 和内置模板重名的用户模板自动加后缀：列表按名字当 id，重名会让 SwiftUI 列表错乱。
    private func userTemplateName(_ name: String) -> String {
        let builtin = Set(CollageTemplates.builtin.map(\.name))
        return builtin.contains(name) ? name + "（我的）" : name
    }

    func saveTemplate(named name: String, fitAspects: Bool) {
        let trimmed = userTemplateName(name.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty, let page else { return }
        let t = CollageTemplates.template(from: page, name: trimmed, style: project.style,
                                          canvas: isAlbum ? nil : project.canvas, aspect: project.canvas.aspect,
                                          fitAspects: fitAspects)
        userTemplates.removeAll { $0.name == trimmed }
        userTemplates.append(t)
        userTemplates.sort { $0.name < $1.name }
        flushStateSave(force: true)
        setNotice("模板「\(trimmed)」已保存")
    }

    func deleteTemplate(_ name: String) {
        userTemplates.removeAll { $0.name == name }
        flushStateSave(force: true)
    }

    func exportTemplates(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(userTemplates).write(to: url, options: .atomic)
            setNotice("导出 \(userTemplates.count) 个模板")
        } catch {
            lastError = "模板导出失败: \(error.localizedDescription)"
        }
    }

    func importTemplates(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            lastError = "读不了模板文件"
            return
        }
        var incoming: [CollageTemplate] = []
        if let list = try? JSONDecoder().decode([CollageTemplate].self, from: data) {
            incoming = list
        } else if let one = try? JSONDecoder().decode(CollageTemplate.self, from: data) {
            incoming = [one]
        }
        guard !incoming.isEmpty else {
            lastError = "不是拼图模板文件"
            return
        }
        for var t in incoming {
            t.name = userTemplateName(t.name)
            userTemplates.removeAll { $0.name == t.name }
            userTemplates.append(t)
        }
        userTemplates.sort { $0.name < $1.name }
        flushStateSave(force: true)
        setNotice("导入 \(incoming.count) 个模板")
    }

    // MARK: - 编辑（全部可撤销）

    private func setRoot(_ root: CollageNode) {
        if project.pages.isEmpty {
            project.pages = [CollagePage(root: root)]
            pageIndex = 0
        } else if project.pages.indices.contains(pageIndex) {
            project.pages[pageIndex].root = root
        }
    }

    /// 整页换掉（版式 + 图层 + 是不是散落版）；没有页就新建一页。
    private func setPage(_ newPage: CollagePage) {
        if project.pages.isEmpty {
            project.pages = [newPage]
            pageIndex = 0
        } else if project.pages.indices.contains(pageIndex) {
            project.pages[pageIndex] = newPage
        }
    }

    private func mutateRoot(coalesce: Bool = false, _ body: (CollageNode) -> CollageNode) {
        guard let root else { return }
        cancelSolveIfRunning()
        pushUndo(coalesce: coalesce)
        setRoot(body(root))
        commitEdit()
    }

    func swap(_ a: [Int], _ b: [Int]) {
        mutateRoot { CollageLayout.swapLeaves($0, a, b) }
        selection = b
    }

    /// 把一个格子挪到另一个格子的边上（劈开插入），原位置回流。
    func move(from source: [Int], to target: [Int], edge: CollageLayout.Edge) {
        guard source != target, let root, var cell = root.node(at: source)?.cell,
              root.node(at: target)?.isLeaf == true else { return }
        cell.crop = nil
        cell.locked = false
        // 先插后删。target 是叶子、source 是另一片叶子，所以插入只改写 target 自己那一格，
        // source 的路径不变；删 source 时它的兄弟子树（可能含刚插入的格子）整体上移。
        let inserted = CollageLayout.insert(cell, at: target, edge: edge, into: root)
        pushUndo()
        setRoot(CollageLayout.remove(at: source, from: inserted, canvas: project.canvas))
        selection = nil
        commitEdit()
    }

    /// 托盘里的照片拖到格子上：中间 = 替换，边上 = 劈开插入。已经在版里的照片 = 挪过去。
    func place(photoID: String, at target: [Int], edge: CollageLayout.Edge?) {
        // 画布收的是纯文本拖放：别的 app 拖进来一段字不能当成照片 id。
        guard photoMap[photoID] != nil else { return }
        if isContactSheet {
            addContactFrame(photoID)
            return
        }
        guard let root, !isFreeform else {
            if isFreeform { addPhotoItem(photoID, at: CGPoint(x: 0.5, y: 0.5)) } else { layoutFresh(photoIDs: [photoID]) }
            return
        }
        if let existing = root.leafPaths().first(where: { root.node(at: $0)?.cell?.photoID == photoID }) {
            if let edge {
                move(from: existing, to: target, edge: edge)
            } else {
                swap(existing, target)
            }
            return
        }
        if let edge {
            mutateRoot { CollageLayout.insert(CollageCell.photo(photoID), at: target, edge: edge, into: $0) }
        } else if root.isLeaf, root.cell?.kind != .text, !project.canvas.allowsCrossFold {
            // 胶装跨页整页只有一个格：照片放右页，左页留空格（放进整页那一格就横跨中缝了）。
            mutateRoot { _ in
                var out = CollageLayout.blankRoot(for: project.canvas)
                out.update(at: [1]) { $0.cell = CollageCell.photo(photoID) }
                return out
            }
            selection = [1]
        } else {
            mutateRoot { r in
                var out = r
                out.update(at: target) { node in
                    var cell = node.cell ?? CollageCell()
                    cell.kind = .photo
                    cell.photoID = photoID
                    cell.text = nil
                    cell.crop = nil
                    node.cell = cell
                }
                return out
            }
            selection = target
        }
    }

    func removeCell(_ path: [Int]) {
        guard let root else { return }
        if root.isLeaf {
            mutateRoot { _ in CollageLayout.blankRoot(for: project.canvas) }
        } else {
            mutateRoot { CollageLayout.remove(at: path, from: $0, canvas: project.canvas) }
        }
        selection = nil
        cropEditing = false
    }

    func flipGutter(_ path: [Int]) {
        mutateRoot { CollageLayout.flip(at: path, in: $0) }
    }

    /// 拖缝：开始时记一次撤销，拖动中只改 ratio 不进撤销栈。
    func beginContinuousEdit() {
        cancelSolveIfRunning()
        pushUndo(coalesce: false)
        continuousEditDepth += 1
    }

    func setRatio(_ ratio: Double, at path: [Int]) {
        guard let root else { return }
        setRoot(CollageLayout.setRatio(ratio, at: path, in: root))
        scheduleProjectSave()
        setNeedsRender()
    }

    func endContinuousEdit() {
        continuousEditDepth = max(0, continuousEditDepth - 1)
        commitEdit()
    }

    private func updateSelectedCell(coalesce: Bool = false, _ body: (inout CollageCell) -> Void) {
        guard let selection else { return }
        mutateRoot(coalesce: coalesce) { r in
            var out = r
            out.update(at: selection) { node in
                guard var cell = node.cell else { return }
                body(&cell)
                node.cell = cell
            }
            return out
        }
    }

    func setFraming(_ framing: CollageFraming) {
        updateSelectedCell { cell in
            cell.framing = framing
            cell.crop = nil
            cell.contain = false
            // 自己选过景别：关掉人物挡字时不再换回自动。
            cell.coverAuto = false
        }
    }

    func setShape(_ shape: CollageShape?) { updateSelectedCell { $0.shape = shape } }
    func setContain(_ on: Bool) {
        updateSelectedCell { cell in
            cell.contain = on
            if on { cell.crop = nil } else { cell.containBlur = false }
        }
    }

    /// 完整显示时四周用这张照片自己的模糊填（打开它就是完整显示）。
    func setContainBlur(_ on: Bool) {
        updateSelectedCell { cell in
            cell.containBlur = on
            if on {
                cell.contain = true
                cell.crop = nil
            }
        }
    }
    func toggleLock() { updateSelectedCell { $0.locked.toggle() } }
    func resetCrop() { updateSelectedCell { $0.crop = nil } }

    /// 裁切模式下拖动/缩放：整个裁切模式只记一次撤销（第一次真的改动时）。中心夹到有效
    /// 范围里 —— 渲染器反正会夹，不夹就会存一个越界的中心，之后的拖动/方向键有一段没反应。
    func setCrop(_ crop: CollageCropOverride, at path: [Int]) {
        guard let root, let frame = geometry.frames.first(where: { $0.path == path }),
              let id = frame.cell.photoID, let photo = photoMap[id] else { return }
        let zoom = min(8, max(1, crop.zoom))
        let maxW = CollageCrop.maxWindow(photoAspect: photo.aspect,
                                         cellAspect: CollageCrop.aspect(of: photoArea(for: frame)))
        let halfW = maxW.w / zoom / 2
        let halfH = maxW.h / zoom / 2
        let clamped = CollageCropOverride(cx: min(1 - halfW, max(halfW, crop.cx)),
                                          cy: min(1 - halfH, max(halfH, crop.cy)), zoom: zoom)
        if cropEditing, cropUndoPending {
            cancelSolveIfRunning()
            pushUndo()
            cropUndoPending = false
        }
        var out = root
        out.update(at: path) { node in
            node.cell?.crop = clamped
            node.cell?.contain = false
        }
        setRoot(out)
        scheduleProjectSave()
        setNeedsRender()
    }

    func enterCropEdit(_ path: [Int]) {
        guard root?.node(at: path)?.cell?.kind == .photo else { return }
        selection = path
        cropUndoPending = true
        cropEditing = true
    }

    func exitCropEdit() {
        guard cropEditing else { return }
        cropEditing = false
        let changed = !cropUndoPending
        cropUndoPending = false
        if changed { commitEdit() }
    }

    /// 换页、换场次之前：裁切模式里的改动先落盘（以前直接把 cropEditing 置 false，平移过的
    /// 裁切从来没排过保存，退出就丢）。
    private func finishCropEditForNavigation() {
        guard cropEditing else { return }
        cropEditing = false
        if !cropUndoPending { scheduleProjectSave() }
        cropUndoPending = false
    }

    /// 当前取景 → 手动裁切的起点（进入裁切模式后第一下拖动用）。
    func cropBaseline(for frame: CollageLayout.Frame) -> CollageCropOverride? {
        if let crop = frame.cell.crop { return crop }
        guard let id = frame.cell.photoID, let photo = photoMap[id], let w = window(for: frame) else { return nil }
        let maxW = CollageCrop.maxWindow(photoAspect: photo.aspect,
                                         cellAspect: CollageCrop.aspect(of: photoArea(for: frame)))
        let zoom = max(1, maxW.w / max(1e-6, w.w))
        return CollageCropOverride(cx: w.x + w.w / 2, cy: w.y + w.h / 2, zoom: zoom)
    }

    /// 文字框每敲一个字都会进来：0.6 秒内的连续修改只记一次撤销。按路径写回，而且那一格
    /// 必须还是文字格 —— 点了别的格子之后文字框迟到的提交，不能把那张照片格改成文字。
    func updateText(_ text: CollageText, at path: [Int]) {
        guard let root, root.node(at: path)?.cell?.kind == .text else { return }
        mutateRoot(coalesce: true) { r in
            var out = r
            out.update(at: path) { node in node.cell?.text = text }
            return out
        }
    }

    /// 文字编辑器的写回：文字格、照片上的字、自由图层里的字。目标已经不是原来那种了
    /// （点了别的格子之后迟到的提交）就什么都不做。
    func updateText(_ text: CollageText, target: CollageTextTarget) {
        switch target {
        case .cell(let path, let pageID):
            // 相册切了跨页：迟到的提交不能写进别页同一路径上的文字格。
            guard page?.id == pageID else { return }
            updateText(text, at: path)
        case .overlay(let path, let photoID, let pageID, let index):
            // 换一批之后压字跟着照片走了：路径上已经是另一张照片，迟到的提交不能写到它的字上。
            guard page?.id == pageID, let cell = root?.node(at: path)?.cell, cell.overlays.indices.contains(index),
                  cell.photoID == photoID else { return }
            updateOverlay(at: path, index: index, coalesce: true) { $0.text = text }
        case .item(let id):
            guard page?.items.contains(where: { $0.id == id && $0.kind == .text }) == true else { return }
            updateItem(id, coalesce: true) { $0.text = text }
        }
    }

    /// 一行字套花字预设（点一下记一步撤销）。照片上的字：预设换了字色就把深浅从「自动」定成跟它一致 ——
    /// 不然点了「白字黑边」，亮天空上又被自动翻成黑字白边。
    func applyTextEffect(_ preset: CollageTextEffects.Preset, line index: Int, target: CollageTextTarget) {
        switch target {
        case .cell(let path, let pageID):
            guard page?.id == pageID, root?.node(at: path)?.cell?.kind == .text,
                  var t = root?.node(at: path)?.cell?.text, t.lines.indices.contains(index) else { return }
            preset.apply(&t.lines[index])
            let updated = t
            mutateRoot { r in
                var out = r
                out.update(at: path) { node in node.cell?.text = updated }
                return out
            }
        case .overlay(let path, let photoID, let pageID, let block):
            guard page?.id == pageID, let cell = root?.node(at: path)?.cell, cell.photoID == photoID,
                  cell.overlays.indices.contains(block), cell.overlays[block].text.lines.indices.contains(index)
            else { return }
            updateOverlay(at: path, index: block) { o in
                preset.apply(&o.text.lines[index])
                if let tone = preset.tone { o.tone = tone }
            }
        case .item(let id):
            guard let item = page?.items.first(where: { $0.id == id && $0.kind == .text }),
                  var t = item.text, t.lines.indices.contains(index) else { return }
            preset.apply(&t.lines[index])
            let updated = t
            updateItem(id) { $0.text = updated }
        }
    }

    // MARK: - 照片上的字

    /// 换掉第 index 个字块；nil = 删掉它（后面的往前挪，第一个删了第二个就成了刊头）；index 超出 = 加在最后。
    func setOverlay(_ overlay: CollageOverlay?, at path: [Int], index: Int = 0) {
        guard root?.node(at: path)?.cell?.kind == .photo else { return }
        mutateRoot { r in
            var out = r
            out.update(at: path) { node in
                guard var cell = node.cell else { return }
                var list = cell.overlays
                if let overlay {
                    if list.indices.contains(index) { list[index] = overlay } else { list.append(overlay) }
                } else if list.indices.contains(index) {
                    list.remove(at: index)
                }
                cell.overlays = list
                node.cell = cell
            }
            return out
        }
        let count = root?.node(at: path)?.cell?.overlays.count ?? 0
        if overlayIndex >= count { overlayIndex = max(0, count - 1) }
    }

    /// 在这张照片上再加一个字块（摆在已有字块之后、让着它们），并切到它。
    func addOverlay(_ overlay: CollageOverlay, at path: [Int]) {
        guard let cell = root?.node(at: path)?.cell, cell.kind == .photo else { return }
        let index = cell.overlays.count
        setOverlay(overlay, at: path, index: index)
        if selection == path { overlayIndex = index }
    }

    func updateOverlay(at path: [Int], index: Int = 0, coalesce: Bool = false,
                       _ body: (inout CollageOverlay) -> Void) {
        guard let list = root?.node(at: path)?.cell?.overlays, list.indices.contains(index) else { return }
        let current = list[index]
        var overlay = current
        body(&overlay)
        // 点的是已经选中的那一项：不记空撤销、不清重做栈。
        guard overlay != current else { return }
        let updated = overlay
        mutateRoot(coalesce: coalesce) { r in
            var out = r
            out.update(at: path) { node in
                guard var cell = node.cell, cell.overlays.indices.contains(index) else { return }
                cell.overlays[index] = updated
                node.cell = cell
            }
            return out
        }
    }

    /// 人物挡字开关（第 index 块字在人后 / 人前）。打开时这一格还是「自动」取景、没手动裁过，就顺手换成「封面」
    /// 取景（头顶压进刊头），同一步撤销，并记下是顺手换的（coverAuto）；关掉时，别的字块也都不在人后、还是
    /// 那个没裁过的封面取景，就换回自动（用户自己选的封面不动）。
    func setOverlayLayer(_ layer: CollageTextLayer, at path: [Int], index: Int = 0) {
        guard let cell = root?.node(at: path)?.cell, cell.overlays.indices.contains(index),
              cell.overlays[index].layer != layer else { return }
        let fixed = cell.overlays[index].anchor != .auto && !cell.overlays[index].anchor.isSide
        let autoCover = layer == .behindSubject && fixed && cell.framing == .auto && cell.crop == nil && !cell.contain
        let othersBehind = cell.overlays.indices.contains { $0 != index && cell.overlays[$0].layer == .behindSubject }
        let backToAuto = layer == .front && cell.coverAuto && cell.framing == .cover && cell.crop == nil
            && !cell.contain && !othersBehind
        mutateRoot { r in
            var out = r
            out.update(at: path) { node in
                guard var c = node.cell, c.overlays.indices.contains(index) else { return }
                c.overlays[index].layer = layer
                if autoCover {
                    c.framing = .cover
                    c.coverAuto = true
                }
                if backToAuto {
                    c.framing = .auto
                    c.coverAuto = false
                }
                node.cell = c
            }
            return out
        }
    }

    /// 抠图格：只画主体，背景透出页面（nil = 照常画整张）。coalesce = 白边、投影滑杆拖动中（一次拖动记一步撤销）。
    func setCutout(_ cutout: CollageCutout?, at path: [Int], coalesce: Bool = false) {
        guard let cell = root?.node(at: path)?.cell, cell.kind == .photo, cell.cutout != cutout else { return }
        mutateRoot(coalesce: coalesce) { r in
            var out = r
            out.update(at: path) { node in node.cell?.cutout = cutout }
            return out
        }
    }

    /// 命令行合成数据：直接改托盘里这张照片的人脸框（验多人合影的退让；不进撤销，重新载入就恢复）。
    func overrideFacesForTesting(_ id: String, faces: [[Double]]) -> Bool {
        guard let i = project.photos.firstIndex(where: { $0.id == id }) else { return false }
        project.photos[i].faces = faces.filter(CollageCrop.isValidBox)
        hints[id]?.headTop = nil
        setNeedsRender()
        return true
    }

    /// 拖字：开始记一次撤销（beginContinuousEdit），拖动中只改位置。
    func setOverlayPosition(x: Double, y: Double, at path: [Int], index: Int = 0) {
        guard let root, let list = root.node(at: path)?.cell?.overlays, list.indices.contains(index) else { return }
        var overlay = list[index]
        // 第一次拖：把按位置定下的对齐（右上角 = 右对齐）存进字里，拖起来不会突然换对齐。
        if overlay.anchor != .custom, !overlay.text.vertical,
           let frame = geometry.frames.first(where: { $0.path == path }),
           let placed = overlayPlacement(for: frame, index: index) {
            overlay.text.alignH = placed.text.alignH
        }
        overlay.anchor = .custom
        overlay.x = min(1, max(0, x))
        overlay.y = min(1, max(0, y))
        var out = root
        let moved = overlay
        out.update(at: path) { node in
            guard var cell = node.cell, cell.overlays.indices.contains(index) else { return }
            cell.overlays[index] = moved
            node.cell = cell
        }
        setRoot(out)
        scheduleProjectSave()
        setNeedsRender()
    }

    // MARK: - 自由图层（相纸、胶带、贴纸、手写字）

    func selectItem(_ id: UUID?) {
        if cropEditing { exitCropEdit() }
        selectedItem = id
    }

    /// `createPage`：还没有页（空画布上加贴纸）就按当前网格/散落偏好建一页 —— 和加贴纸算同一步撤销
    /// （相册的跨页由编排决定，建的一律是网格页）。
    /// `moved`：改的是哪一个图层 —— 贴纸自己被挪、被转了，要按新位置重新记它贴在哪张相纸上。
    private func mutateItems(coalesce: Bool = false, createPage: Bool = false, moved: UUID? = nil,
                             _ body: (inout [CollageItem]) -> Void) {
        cancelSolveIfRunning()
        if project.pages.isEmpty, createPage {
            pushUndo(coalesce: coalesce)
            project.pages = [layoutStyle == .scatter && !isAlbum
                ? CollagePage(root: .leaf(CollageCell()), items: [], freeform: true, scatter: CollageScatterSpec())
                : CollagePage(root: CollageLayout.blankRoot(for: project.canvas))]
            pageIndex = 0
        } else {
            guard project.pages.indices.contains(pageIndex) else { return }
            pushUndo(coalesce: coalesce)
        }
        body(&project.pages[pageIndex].items)
        project.pages[pageIndex].items = CollageItems.normalized(project.pages[pageIndex].items, moved: moved,
                                                                 canvas: project.canvas)
        commitEdit()
    }

    func updateItem(_ id: UUID, coalesce: Bool = false, _ body: (inout CollageItem) -> Void) {
        guard let current = page?.items.first(where: { $0.id == id }) else { return }
        var probe = current
        body(&probe)
        // 点的是已经选中的那一项：不记空撤销、不清重做栈。
        guard probe != current else { return }
        mutateItems(coalesce: coalesce, moved: id) { items in
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            body(&items[i])
        }
    }

    /// 拖动、旋转、缩放过程中：不进撤销栈（开始时 beginContinuousEdit 记一次）。贴在相纸上的贴纸
    /// 跟着相纸一起动；拖的是贴纸本身就重新记它贴在哪儿。
    func setItemGeometry(_ id: UUID, _ body: (inout CollageItem) -> Void) {
        guard project.pages.indices.contains(pageIndex),
              let index = project.pages[pageIndex].items.firstIndex(where: { $0.id == id }) else { return }
        body(&project.pages[pageIndex].items[index])
        project.pages[pageIndex].items = CollageItems.normalized(project.pages[pageIndex].items, moved: id,
                                                                 canvas: project.canvas)
        scheduleProjectSave()
        setNeedsRender()
    }

    /// 新贴纸：选中了一张相纸，胶带、回形针贴在它上沿（之后跟着它走）；网格版选中了照片格，胶带贴在
    /// 那一格的上沿；否则放在画布上方或中间（相册放右半页 —— 正中是中缝）。稍微斜一点才像贴上去的。
    func addSticker(_ kind: CollageSticker) {
        var item = CollageItem(kind: .sticker)
        item.sticker = kind
        item.color = kind.defaultColor
        item.width = kind.defaultSize.w
        item.height = kind.defaultSize.h
        item.rotation = kind == .postmark ? -8 : (kind.isTape ? -6 : 0)
        if kind == .label || kind == .barcode { item.label = "{date}" }
        let canvas = project.canvas
        let short = canvas.shortSide
        if kind == .greasePencil, let anchor = selectedItemValue, anchor.kind == .photo {
            // 油性笔圈：圈住选中的那张相纸（外接椭圆 ≈ 相纸 × 1.4，跟着它的角度）。
            let half = CollageItems.size(anchor, canvas: canvas)
            item.cx = anchor.cx
            item.cy = anchor.cy
            item.width = min(1.2, Double(half.width) * item.mark.frameScale / short)
            item.height = min(1.2, Double(half.height) * item.mark.frameScale / short)
            item.rotation = anchor.rotation
        } else if kind == .greasePencil, !isFreeform, let path = selection,
                  let frame = geometry.frames.first(where: { $0.path == path }), frame.cell.kind == .photo {
            // 网格版选中了照片格：圈住那一格。
            let r = frame.rect.cgRect
            item.cx = Double(r.midX) / Double(canvas.width)
            item.cy = Double(r.midY) / Double(canvas.height)
            item.width = min(1.2, Double(r.width) * item.mark.frameScale / short)
            item.height = min(1.2, Double(r.height) * item.mark.frameScale / short)
        } else if kind.isTape || kind == .clip, let anchor = selectedItemValue, anchor.kind == .photo {
            let t = CollageItems.transform(anchor, canvas: canvas)
            let half = CollageItems.size(anchor, canvas: canvas)
            let p = CGPoint(x: kind == .clip ? half.width * 0.3 : 0, y: -half.height / 2).applying(t)
            item.cx = Double(p.x) / Double(canvas.width)
            item.cy = Double(p.y) / Double(canvas.height)
            item.rotation = anchor.rotation + (kind == .clip ? 0 : -4)
            item.attach = CollageItems.attachment(of: item, to: anchor, canvas: canvas)
        } else if kind.isTape, !isFreeform, let path = selection,
                  let frame = geometry.frames.first(where: { $0.path == path }), frame.cell.kind == .photo {
            let r = frame.rect.cgRect
            item.cx = Double(r.midX) / Double(canvas.width)
            item.cy = Double(r.minY) / Double(canvas.height)
        } else if kind == .barcode {
            // 条码放右下角（封面惯例：离边约 4% 短边），离的是版心（页边距 / 四边边距以内）的边：零边距封面上
            // 版心就是成品，照旧离成品边 4%；有页边距的版式上条码整块落在照片里，不会冲出照片右下角几像素。
            let w = Double(canvas.width)
            let h = Double(canvas.height)
            let content = CollageLayout.contentRect(canvas: canvas, style: project.style)
            let inset: Double = 0.04 * short
            let halfW: Double = item.width * short / 2
            let halfH: Double = item.height * short / 2
            let right: Double = Double(content.x1) - inset - halfW
            let bottom: Double = Double(content.y1) - inset - halfH
            item.cx = min(1, max(0, right / w))
            item.cy = min(1, max(0, bottom / h))
        } else {
            item.cx = canvas.seams == .fold ? 0.75 : 0.5
            item.cy = kind.isTape ? 0.12 : 0.5
        }
        mutateItems(createPage: true) { $0.append(item) }
        selectItem(item.id)
    }

    func addItemText() {
        var item = CollageItem(kind: .text)
        item.text = CollageText(lines: [
            CollageTextLine("{title}", font: .hanzipen, weight: .regular, size: 0.05, color: .ink),
        ], vertical: false, alignH: .center, alignV: .center)
        item.width = 0.5
        item.height = 0.1
        // 相册放右半页：正中是中缝。
        item.cx = project.canvas.seams == .fold ? 0.75 : 0.5
        item.cy = 0.88
        item.rotation = -3
        mutateItems(createPage: true) { $0.append(item) }
        selectItem(item.id)
    }

    /// 散落版上放一张相纸：按照片比例做一张相纸，落点即中心（夹回画布里；相册里不压中缝）。
    func addPhotoItem(_ photoID: String, at point: CGPoint) {
        guard let photo = photoMap[photoID] else { return }
        // 拖到画布外的留白里松手：照片不能放到画布外面去（看不见、以为没放上）。
        let p = CGPoint(x: min(0.92, max(0.08, point.x)), y: min(0.92, max(0.08, point.y)))
        // 已经在这一页上的同一张：挪过去（大小、角度不变，连同贴在上面的胶带提到最上面），不重复放。
        if let existing = page?.items.first(where: { $0.kind == .photo && $0.photoID == photoID }) {
            var target = existing
            target.cx = Double(p.x)
            target.cy = Double(p.y)
            target = clearOfFold(target)
            mutateItems { items in
                let group = CollageItems.group(of: existing.id, in: items)
                guard !group.isEmpty else { return }
                let set = Set(group)
                let block = group.map { items[$0].id == existing.id ? target : items[$0] }
                items = items.enumerated().filter { !set.contains($0.offset) }.map(\.element) + block
            }
            selectItem(existing.id)
            return
        }
        let item = clearOfFold(Self.photoItem(photo, frame: page?.scatter?.frame ?? .polaroid, at: p))
        mutateItems(createPage: true) { $0.append(item) }
        selectItem(item.id)
    }

    /// 相册跨页：相纸横在中缝上就挪到它中心所在的那一侧（书脊会吃掉中间一条）。
    private func clearOfFold(_ item: CollageItem) -> CollageItem {
        let canvas = project.canvas
        guard canvas.seams == .fold else { return item }
        let b = CollageItems.bounds(item, canvas: canvas)
        let w = Double(canvas.width)
        let band: Double = canvas.foldBand
        guard Double(b.minX) < w / 2 + band, Double(b.maxX) > w / 2 - band else { return item }
        let half = Double(b.width) / 2
        let x: Double = item.cx < 0.5 ? (w / 2 - band - half) : (w / 2 + band + half)
        var out = item
        out.cx = min(1, max(0, x / w))
        return out
    }

    /// 按照片比例做一张相纸（约占画布一成三面积），落点即中心，稍微斜一点。
    static func photoItem(_ photo: CollagePhotoRef, frame: CollageItemFrame, at point: CGPoint) -> CollageItem {
        var item = CollageItem(kind: .photo)
        item.photoID = photo.id
        item.frame = frame
        let outer = CollageItems.outerAspect(inner: min(1.45, max(0.72, photo.aspect)), frame: frame)
        let area = 0.13
        item.width = (area * outer).squareRoot()
        item.height = item.width / outer
        item.cx = Double(point.x)
        item.cy = Double(point.y)
        item.rotation = Double(Int.random(in: -6...6))
        item.shadow = 0.55
        return item
    }

    /// 删相纸时贴在它上面的胶带一起删（mutateItems 里按相纸还在不在收拾）。
    func deleteItem(_ id: UUID) {
        mutateItems { $0.removeAll { $0.id == id } }
        if selectedItem == id { selectedItem = nil }
    }

    func duplicateItem(_ id: UUID) {
        guard let item = page?.items.first(where: { $0.id == id }) else { return }
        var copy = item
        copy.id = UUID()
        copy.cx += 0.03
        copy.cy += 0.03
        // 复制出来的是用户自己的：不算自动撒的（换一批不换它），也不是哪个文字格转来的。
        copy.generated = false
        copy.sourceCell = nil
        // moved：复制出来的贴纸按新位置记它贴在哪张相纸上（不然会被按原来的位置摆回去叠在一起）。
        mutateItems(moved: copy.id) { $0.append(copy) }
        selectItem(copy.id)
    }

    /// 置顶 / 置底：相纸连同贴在上面的胶带一起挪（胶带要一直在它那张的上面一层）。
    func moveItemInStack(_ id: UUID, toFront: Bool) {
        mutateItems { items in
            let group = CollageItems.group(of: id, in: items)
            guard !group.isEmpty else { return }
            let set = Set(group)
            let block = group.map { items[$0] }
            let rest = items.enumerated().filter { !set.contains($0.offset) }.map(\.element)
            items = toFront ? rest + block : block + rest
        }
    }

    /// 在选中格子的某一边加一个文字格（没选中就加在整版下方）。
    func addTextCell(edge: CollageLayout.Edge, vertical: Bool) {
        // 散落版不画切分树：文字格加进去看不见。散落版用手写字。
        guard !isFreeform else {
            addItemText()
            return
        }
        let text = vertical ? CollageTemplates.verticalTitle(size: 0.06, seal: "光", date: true)
                            : CollageTemplates.centeredTitle()
        let target = selection ?? []
        let canvas = project.canvas
        mutateRoot { root in
            guard target.isEmpty else { return CollageLayout.insert(.text(text), at: target, edge: edge, into: root) }
            // 相册跨页：字只加在一页上（上、下横排加在右页，竖排加在那一边的那一页）—— 整个跨页加一条，
            // 居中的标题正好压在书脊上。
            if canvas.seams == .fold, let fold = CollageLayout.foldPath(root) {
                var out = root
                out.update(at: fold + [edge == .left ? 0 : 1]) { page in
                    page = Self.textBand(text, edge: edge, around: page, verticalShare: 0.3)
                }
                return out
            }
            return Self.textBand(text, edge: edge, around: root, verticalShare: 0.22)
        }
    }

    /// 在一棵子树的一边加一条文字：横排占一成四高，竖排占 verticalShare 宽。
    private static func textBand(_ text: CollageText, edge: CollageLayout.Edge, around node: CollageNode,
                                 verticalShare: Double) -> CollageNode {
        let axis: CollageAxis = (edge == .left || edge == .right) ? .row : .column
        let newFirst = edge == .left || edge == .top
        let leaf = CollageNode.leaf(.text(text))
        let share = axis == .row ? verticalShare : 0.14
        return newFirst ? .split(axis, share, leaf, node) : .split(axis, 1 - share, node, leaf)
    }

    /// `coalesce`：滑杆、取色器连续拖动合成一步；点色块、选预设、切开关每次一步。
    func setStyle(_ style: CollageStyle, coalesce: Bool = true) {
        // 婚礼 fine-art 的边距按这本册子算（预设里是 30×30 的数）；别的样式、自己改过边距的原样。
        let style = CollageStyleFineArt.adapted(style, to: project.canvas) ?? style
        guard style != project.style else { return }
        pushUndo(coalesce: coalesce)
        project.style = style
        // 下次新建拼图沿用：只在你改过之后才记（以前退出时把出厂值写回 state.json）。fine-art 的边距按新建时的画布记
        // （单张画布 = 预设本来的数），不把这本册子重算过的带到下一张拼图上。
        defaultStyle = CollageStyleFineArt.adapted(style, from: project.canvas, to: defaultCanvas) ?? style
        scheduleStateSave()
        commitEdit()
    }

    /// `coalesce`：出血/安全区滑杆拖一下几十个值，只记一次撤销。
    func setCanvas(_ canvas: CollageCanvas, coalesce: Bool = false) {
        guard canvas != project.canvas else { return }
        // 还在算的「换一批」是按旧画布算的：落到新画布上会出画、压切缝。
        cancelSolveIfRunning()
        pushUndo(coalesce: coalesce)
        let old = project.canvas
        project.canvas = canvas
        // 婚礼 fine-art：边距跟着册子尺寸重算，排好的页上的小字不小于 2.8mm（别的样式原样）。
        if let adapted = CollageStyleFineArt.adapted(project.style, from: old, to: canvas) {
            project.style = adapted
            project.pages = CollageStyleFineArt.readable(project.pages, on: canvas)
        }
        refitFreeformPages(from: old)
        if !isAlbum {
            defaultCanvas = canvas
            scheduleStateSave()
        }
        clearAlternatives()
        commitEdit()
        if abs(old.aspect - canvas.aspect) > 0.001, isFreeform {
            setNotice("散落版按新画布等比缩放了；想按新比例重新撒点「换一批」")
        }
    }

    /// 相册装订方式。换成胶装：整版铺满两页的单张改成「左页日期 + 右页大图」（同一步撤销），散落页的相纸
    /// 挪出更宽的中缝带；别的跨页里还压着中缝的照片报出来，让人点「换一批」。
    func setBinding(_ binding: CollageBinding) {
        guard project.canvas.seams == .fold, binding != project.canvas.binding else { return }
        cancelSolveIfRunning()
        pushUndo()
        project.canvas.binding = binding
        var fixed = 0
        if binding == .glued {
            let ctx = context   // 已经是新的装订方式：CollageAlbum.layout 不会再给整版跨页
            let map = photoMap
            for i in project.pages.indices {
                if project.pages[i].freeform {
                    project.pages[i].items = CollageScatter.clearOfFold(project.pages[i].items, canvas: project.canvas)
                    continue
                }
                let root = project.pages[i].root
                guard root.isLeaf, let cell = root.cell, cell.kind == .photo,
                      let id = cell.photoID, let photo = map[id] else { continue }
                var solo = CollageAlbum.layout(CollageAlbum.Spread(kind: .solo, photos: [photo]),
                                               previousSignature: "", context: ctx, seed: UInt64(i + 1))
                // 照片上压的字（全部字块）跟着照片走。
                if !cell.overlays.isEmpty,
                   let p = solo.leafPaths().first(where: { solo.node(at: $0)?.cell?.photoID == id }) {
                    solo.update(at: p) { $0.cell?.overlays = cell.overlays }
                }
                project.pages[i].root = solo
                fixed += 1
            }
        }
        clearAlternatives()
        selection = nil
        commitEdit()
        let crossing = crossFoldPages()
        var text = binding == .glued ? "胶装：照片不跨中缝，中缝两侧各留 12mm" : "平铺对裱：横图可以铺满两页"
        if fixed > 0 { text += "；\(fixed) 个整版跨页改成了单页大图" }
        if binding == .glued, !crossing.isEmpty {
            text += "；第 " + crossing.map { "\($0 + 1)" }.joined(separator: "、") + " 页还有照片压在中缝上，点「换一批」重排"
        }
        setNotice(text)
    }

    // MARK: - 水印（工程自带的快照，全部可撤销）

    /// 水印每改一次 +1（编辑、撤销 / 重做、换工程都算）；交接开始时也占一个号。交接的照片读完时号变了
    /// （又来了一次交接、或者等的时候在检视器里改过水印），旧请求就不再盖上去。
    private(set) var watermarkRevision = 0
    /// 最近一次交接占的号（号对不上时分得清是被新的交接取代了，还是手动改过）。
    private(set) var latestHandoffRevision = 0

    /// 交接占的号，连同占之前的两个号：这次交接一张都没带进来，就把号还回去（releaseWatermarkRevision）。
    struct WatermarkTicket {
        let revision: Int
        fileprivate let before: Int
        fileprivate let latestBefore: Int
    }

    func reserveWatermarkRevision() -> WatermarkTicket {
        let ticket = WatermarkTicket(revision: watermarkRevision + 1, before: watermarkRevision,
                                     latestBefore: latestHandoffRevision)
        watermarkRevision = ticket.revision
        latestHandoffRevision = ticket.revision
        return ticket
    }

    /// 交接一张照片都没带进来（都读不了）：它什么都没套，不能算「后面又来了一次交接」—— 号还回去，还在等照片
    /// 的上一次交接照常套水印。占号之后水印又改过、又来了交接（号已经不是它的了）就不动。
    func releaseWatermarkRevision(_ ticket: WatermarkTicket) {
        guard watermarkRevision == ticket.revision else { return }
        watermarkRevision = ticket.before
        latestHandoffRevision = ticket.latestBefore
    }

    /// 关掉一层 / 一层的文字时记下原来的设置（只在这次打开期间、只对当前工程，不存盘）：再打开时恢复，
    /// 不是变回默认值。
    private var stashedMarkLayers: [CollageMarkLayerKind: CollageMarkLayer] = [:]
    private var stashedMarkTexts: [CollageMarkLayerKind: CollageMarkText] = [:]

    /// `coalesce`：滑杆连续拖动合成一步；开关、换位置每次一步。水印跟着工程走，不记成下次新建的默认。
    func setWatermark(_ wm: CollageWatermark?, coalesce: Bool = false) {
        guard wm != project.watermark else { return }
        pushUndo(coalesce: coalesce)
        project.watermark = wm
        watermarkRevision += 1
        commitEdit()
    }

    /// 开 / 关一层（检视器的开关、命令行 wmlayer 都走这里）。关：整层拿掉，设置记下来；开：有记着的就原样
    /// 恢复，没有就用默认值 —— 工程里还没签名时先开着文字（开了马上看得见）。
    func setMarkLayer(_ kind: CollageMarkLayerKind, on: Bool) {
        guard on else {
            guard let layer = project.watermark?.layer(kind) else { return }
            stashedMarkLayers[kind] = layer
            updateWatermark { $0.setLayer(kind, nil) }
            return
        }
        guard project.watermark?.layer(kind) == nil else { return }
        var layer = CollageMarkLayer()
        // 记着的不删：开了又撤销（= 又关上）再开，还是这一份；下次真关掉时换成那时的设置。
        if let kept = stashedMarkLayers[kind] {
            layer = kept
        } else if project.watermark?.signature == nil {
            layer.text = CollageMarkText()
        }
        updateWatermark { $0.setLayer(kind, layer) }
    }

    /// 开 / 关一层的文字：关的时候记下这段字（自定义的字、字号、位置），再开时恢复。层没开 = 不动。
    func setMarkText(_ kind: CollageMarkLayerKind, on: Bool) {
        guard let layer = project.watermark?.layer(kind), (layer.text != nil) != on else { return }
        if let text = layer.text { stashedMarkTexts[kind] = text }
        let text = on ? (stashedMarkTexts[kind] ?? CollageMarkText()) : nil
        updateWatermark { wm in
            guard var l = wm.layer(kind) else { return }
            l.text = text
            wm.setLayer(kind, l)
        }
    }

    /// 改水印的某几样；还没加过水印就从默认值起。
    func updateWatermark(coalesce: Bool = false, _ body: (inout CollageWatermark) -> Void) {
        var wm = project.watermark ?? CollageWatermark()
        body(&wm)
        setWatermark(wm, coalesce: coalesce)
    }

    /// 签名图拷一份进 <dataDir>/collage/assets/<sha1>.png（原文件挪走、改名也不影响已存的拼图）。
    /// 解不成图的不收；同一张图只存一份。
    func importSignature(from url: URL) -> CollageSignature? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            setNotice("签名图读不了：\(url.lastPathComponent)")
            return nil
        }
        let key = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = stateDir.appendingPathComponent("assets")
        let dest = dir.appendingPathComponent("\(key).png")
        if !FileManager.default.fileExists(atPath: dest.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
            } catch {
                lastError = "签名图存不进拼图资料: \(error.localizedDescription)"
                return nil
            }
        }
        return CollageSignature(file: dest.path, key: key, sourceName: url.lastPathComponent)
    }

    /// 水印页的设置套进拼图的一层（一步撤销）：换算成比例、签名拷一份进来。签名开关跟水印页看到的
    /// 一致：水印页没签名（或读不了）这一层就不画签名，不会冒出工程里以前那张。相框、画布比例会改画布
    /// 尺寸，不带进来，开着就提示一句。既没签名也没字：提示，什么都不改。
    /// 返回套没套上。专门套了水印就是要它出现在导出里：这个拼图以前关掉的「导出带水印」重新打开（说一声）。
    @discardableResult
    func adoptWatermark(config: WatermarkEngine.Config, signatureURL: URL?, layer kind: CollageMarkLayerKind,
                        refShort: Double, presetName: String?) -> Bool {
        var layer = CollageMarkLayer(config: config, refShort: refShort)
        layer.presetName = presetName
        let signature = config.signatureEnabled ? signatureURL.flatMap { importSignature(from: $0) } : nil
        layer.signatureOn = signature != nil
        guard layer.hasContent(signature: signature != nil) else {
            setNotice(signatureURL != nil && config.signatureEnabled
                      ? "签名图读不了，水印页也没开文字：拼图的水印没改"
                      : "水印页没有签名也没有文字：没什么可带进拼图")
            return false
        }
        let exportWasOff = project.watermark?.exportEnabled == false
        updateWatermark { wm in
            wm.setLayer(kind, layer)
            if let signature { wm.signature = signature }
            wm.exportEnabled = true
        }
        // 套进来的设置取代了这一层关掉时记着的那份。
        stashedMarkLayers[kind] = nil
        stashedMarkTexts[kind] = nil
        var notes: [String] = []
        if config.signatureEnabled, signatureURL != nil, signature == nil { notes.append("签名图读不了，只带了文字") }
        if config.frame.enabled || config.canvasRatio.enabled {
            notes.append("相框 / 画布比例没有带进拼图（只在水印页单张导出时生效）")
        }
        if exportWasOff { notes.append("这个拼图的「导出带水印」重新打开了") }
        if !notes.isEmpty { setNotice(notes.joined(separator: "；")) }
        return true
    }

    // MARK: - 印刷放大

    /// 一张照片在成品上要放大多少。
    struct UpscaleIssue: Hashable {
        var page: Int
        var photoID: String
        var factor: Double
    }

    /// 超过这个倍数印出来会软（SmartAlbums 默认也是 120%；建议别过 150%、绝不过 200%）。
    nonisolated static let upscaleLimit = 1.2

    /// 当前页这一格的放大倍数（和渲染器同一个取景、同一块画出来的区域，成品像素）。
    func upscale(for frame: CollageLayout.Frame) -> Double? {
        guard frame.cell.kind == .photo, let id = frame.cell.photoID, let photo = photoMap[id],
              let window = window(for: frame) else { return nil }
        let drawn = CollageCrop.drawnRect(window: window, photo: photo, cell: frame.cell, in: photoArea(for: frame))
        return CollageCrop.upscale(photo: photo, window: window, drawn: drawn)
    }

    /// 全部页里放大超过 limit 的照片（网格格子 + 散落相纸），倍数大的在前。
    func upscaleIssues(limit: Double = CollageStore.upscaleLimit) -> [UpscaleIssue] {
        Self.upscaleIssues(project: project, hints: hints, limit: limit)
    }

    static func upscaleIssues(project: CollageProject, hints: [String: CollageCrop.Hints],
                              limit: Double = upscaleLimit) -> [UpscaleIssue] {
        let canvas = project.canvas
        let style = project.style
        var photos: [String: CollagePhotoRef] = [:]
        for p in project.photos where photos[p.id] == nil { photos[p.id] = p }
        var out: [UpscaleIssue] = []
        for (i, page) in project.pages.enumerated() {
            if !page.freeform {
                let frames = CollageLayout.pageGeometry(page.root, canvas: canvas, style: style).frames
                // 封面取景、人物挡字的格子按 CollageCover 的决定（封面会拉近，放大倍数要按它算）；
                // 这一页没有这种格子就照旧（不算占位符、底色）。
                let covered = frames.contains { CollageCover.applies(to: $0.cell) }
                let paged = CollageLooks.project(project, page: page)
                let ids = page.photoIDs
                let pageVars = covered ? CollageTypeset.variables(project: paged, root: page.root, photos: photos,
                                                                  pagePhotoIDs: ids, pageID: page.id) : [:]
                let bg = covered ? CollageRender.backgroundColor(project: paged, pagePhotoIDs: ids, photos: photos)
                    : style.background
                for f in frames where f.cell.kind == .photo {
                    guard let id = f.cell.photoID, let photo = photos[id] else { continue }
                    let framing = CollageLayout.effectiveFraming(path: f.path, cell: f.cell, in: frames, photos: photos,
                                                                 tight: style.tightSmallCells)
                    let area = CollageCrop.photoArea(cell: f.cell, rect: f.rect.cgRect, style: style)
                    let window = CollageCover.applies(to: f.cell)
                        ? CollageRender.cellWindow(cell: f.cell, frameRect: f.rect.cgRect, project: paged, photo: photo,
                                                   framing: framing, hints: hints[id],
                                                   vars: CollageTypeset.cellVariables(pageVars, photo: photo),
                                                   background: bg)
                        : CollageCrop.window(for: photo, cell: f.cell, cellAspect: CollageCrop.aspect(of: area),
                                             framing: framing, hints: hints[id])
                    let drawn = CollageCrop.drawnRect(window: window, photo: photo, cell: f.cell, in: area)
                    let k = CollageCrop.upscale(photo: photo, window: window, drawn: drawn)
                    if k > limit { out.append(UpscaleIssue(page: i, photoID: id, factor: k)) }
                }
            }
            // 相纸（散落版整页、网格版上贴的）：和 CollageItems.drawPhotoItem 同一个取景。
            for item in page.items where item.kind == .photo {
                guard let id = item.photoID, let photo = photos[id] else { continue }
                let inner = CollageItems.photoArea(item.frame, outer: CollageItems.localRect(item, canvas: canvas))
                let framing: CollageFraming = item.framing == .auto ? .full : item.framing
                let window = CollageCrop.window(for: photo, cellAspect: CollageCrop.aspect(of: inner), framing: framing,
                                                override: nil, hints: hints[id])
                let k = CollageCrop.upscale(photo: photo, window: window, drawn: inner)
                if k > limit { out.append(UpscaleIssue(page: i, photoID: id, factor: k)) }
            }
        }
        return out.sorted { $0.factor > $1.factor }
    }

    /// 有照片压在中缝上的跨页（页号从 0 起）：网格页看照片实际画的区域（完整显示按画出来的那块），
    /// 散落页看相纸外框。
    func crossFoldPages() -> [Int] {
        let canvas = project.canvas
        guard canvas.seams == .fold else { return [] }
        let mid = CGFloat(canvas.width) / 2
        let map = photoMap
        func crosses(_ r: CGRect) -> Bool { r.minX < mid - 1 && r.maxX > mid + 1 }
        var out: [Int] = []
        for (i, page) in project.pages.enumerated() {
            if page.freeform {
                let hit = page.items.contains { it in
                    it.kind == .photo && it.photoID.flatMap { map[$0] } != nil
                        && crosses(CollageItems.bounds(it, canvas: canvas))
                }
                if hit { out.append(i) }
                continue
            }
            let frames = CollageLayout.pageGeometry(page.root, canvas: canvas, style: project.style).frames
            let hit = frames.contains { f in
                guard f.cell.kind == .photo, let id = f.cell.photoID, let photo = map[id] else { return false }
                let area = CollageCrop.photoArea(cell: f.cell, rect: f.rect.cgRect, style: project.style)
                let drawn = f.cell.contain ? CollageCrop.aspectFit(photo.aspect, in: area) : area
                return crosses(drawn)
            }
            if hit { out.append(i) }
        }
        return out
    }

    /// 画布比例变了：散落页整页等比缩放放进新画布（摆法不变、不会出画）。网格页的切分树本来就按比例缩放。
    private func refitFreeformPages(from old: CollageCanvas) {
        let canvas = project.canvas
        guard abs(old.aspect - canvas.aspect) > 0.001 else { return }
        for i in project.pages.indices where project.pages[i].freeform {
            project.pages[i].items = CollageItems.refit(project.pages[i].items, from: old, to: canvas)
        }
    }

    func setTitle(_ title: String) {
        guard title != project.title else { return }
        pushUndo(coalesce: true)
        project.title = title
        commitEdit()
    }

    func setSubtitle(_ subtitle: String) {
        guard subtitle != project.subtitle else { return }
        pushUndo(coalesce: true)
        project.subtitle = subtitle
        commitEdit()
    }

    /// 刊头（{masthead}）：空 = 按标题生成（见 CollageTypeset.mastheadText）。
    func setMasthead(_ masthead: String) {
        guard masthead != project.masthead else { return }
        pushUndo(coalesce: true)
        project.masthead = masthead
        commitEdit()
    }

    /// 期号（{issue}）：空 = 页码。
    func setIssue(_ issue: String) {
        guard issue != project.issue else { return }
        pushUndo(coalesce: true)
        project.issue = issue
        commitEdit()
    }

    // MARK: - 分层色调

    /// 这一页单独的色调（nil = 跟整个工程）。
    func setPageLook(_ look: CollageLookSetting?, coalesce: Bool = false) {
        guard project.pages.indices.contains(pageIndex), project.pages[pageIndex].look != look else { return }
        pushUndo(coalesce: coalesce)
        project.pages[pageIndex].look = look
        commitEdit()
    }

    /// 选中格子单独的色调（nil = 跟页面）。只对照片格。
    func setCellLook(_ look: CollageLookSetting?, coalesce: Bool = false) {
        guard selectedCell?.kind == .photo, selectedCell?.look != look else { return }
        updateSelectedCell(coalesce: coalesce) { $0.look = look }
    }

    // MARK: - 印样 / 底片条

    /// 这一页改成印样：托盘照片按拍摄先后排成一卷（spec 给了就按它的规格、排法；没给 = 按照片比例挑规格）。
    /// 页上的贴纸、手写字留着；格子里的压字、文字格不要（印样没有格子）。一步撤销。
    func makeContactSheet(_ spec: CollageContactSheet? = nil) {
        let pool = contactPool
        guard !pool.isEmpty else {
            setNotice(project.photos.isEmpty ? "托盘是空的：先带照片进来" : "托盘里的照片都在别的跨页上了")
            return
        }
        cancelPendingSolve()
        pushUndo()
        var sheet = spec ?? CollageContactSheet(format: CollageContact.suggestedFormat(pool))
        if let old = page?.contactSheet, spec == nil { sheet = old }
        // 新建的印样（这一页原来不是印样）落在偏深的底色上：换成白相纸（黑场压在深色上分不出来）。
        // 底片条放在什么底上都行，照用页面底色；已经是印样的「按托盘重排」不动纸。
        if page?.contactSheet == nil, sheet.layout == .sheet, sheet.paper == nil, let current = page {
            let projected = CollageLooks.project(project, page: current)
            let bg = CollageRender.backgroundColor(project: projected, pagePhotoIDs: current.photoIDs, photos: photoMap)
            if !CollageContact.suitsSheet(bg) { sheet.paper = CollageContact.defaultPaper(.sheet) }
        }
        var newPage = CollageContact.page(photos: pool, spec: sheet)
        if let old = page {
            newPage.id = old.id
            newPage.look = old.look
            // 散落版的相纸（和贴在相纸上的胶带）是那一版的照片，不带过来。
            newPage.items = old.freeform ? old.items.filter { $0.kind != .photo && $0.attach == nil } : old.items
        }
        setPage(newPage)
        clearAlternatives()
        selection = nil
        commitEdit()
        let n = newPage.contactSheet?.frames.count ?? 0
        let dropped = pool.count - n
        // 底片条模板（choice = best）托盘比格子多时是每场挑一张（同检视器的帧数那一行）。
        let picked = newPage.contactSheet?.choice == .best && dropped > 0
        let order = picked ? "每场挑最好的一张、按拍摄先后排" : "按拍摄先后排"
        setNotice("印样：\(n) 帧\(order)" + (dropped > 0 ? "（这一页放不下的 \(dropped) 张没上）" : ""))
    }

    /// 印样换白相纸（检视器「印样」框在深色纸上提示）：只换这一页印样自己的纸（contactSheet.paper），
    /// 工程的底色、相册里别的页不动；一步撤销。
    func useWhitePaper() {
        updateContactSheet { $0.paper = CollageContact.defaultPaper(.sheet) }
    }

    /// 印样能用的照片：托盘全部（相册里别的跨页用了的不拿，同一张不出现在两个跨页上）。
    private var contactPool: [CollagePhotoRef] {
        guard isAlbum else { return project.photos }
        let here = Set(page?.photoIDs ?? [])
        let used = usedPhotoIDs.subtracting(here)
        return project.photos.filter { !used.contains($0.id) }
    }

    /// 改印样的设置（规格、排法、记号、片边字……）。coalesce：拖滑杆、打字连成一步撤销。
    func updateContactSheet(coalesce: Bool = false, _ body: (inout CollageContactSheet) -> Void) {
        guard project.pages.indices.contains(pageIndex), var sheet = project.pages[pageIndex].contactSheet else { return }
        let before = sheet
        body(&sheet)
        refillContactFrames(&sheet, from: before)
        guard sheet != project.pages[pageIndex].contactSheet else { return }
        pushUndo(coalesce: coalesce)
        project.pages[pageIndex].contactSheet = sheet
        commitEdit()
        // 容量变小（换成 120、改少了条数……）：放不下的帧照常记着（改回来还在），说一声没上的有几张。
        let left = max(0, sheet.frames.count - sheet.frameLimit)
        if left > max(0, before.frames.count - before.frameLimit) {
            setNotice("印样：这一页放得下 \(sheet.frameLimit) 帧，后面 \(left) 张没上")
        }
    }

    /// 容量变大（换规格、改每条帧数、条数，或者改成自动）而这一卷还是「托盘按拍摄先后的前 N 张」（帧没手动改过）
    /// 时，按新容量从托盘补齐：不然 6×6 模板建的 12 帧，换成 135 7×5 还是 12 帧，得再点一次「按托盘重排」。
    /// 这一步本身在改帧（拖进来一张、contactframes）、帧动过、容量变小，都不动帧（变小时放不下的照常记成放不下）。
    private func refillContactFrames(_ sheet: inout CollageContactSheet, from before: CollageContactSheet) {
        guard sheet.frames == before.frames else { return }
        let oldCapacity = before.frameLimit
        let newCapacity = sheet.frameLimit
        guard newCapacity > oldCapacity else { return }
        let roll = CollageContact.rollOrder(contactPool).map(\.id)
        let n = sheet.frames.count
        guard n < roll.count, Array(roll.prefix(n)) == sheet.frames else { return }
        sheet.frames = Array(roll.prefix(newCapacity))
    }

    /// 托盘里的一张拖进印样：接在这一卷最后（已经在卷里的不动）。一卷满了（frameLimit）不接：接上也画不出来。
    func addContactFrame(_ photoID: String) {
        if let sheet = page?.contactSheet, !sheet.frames.contains(photoID), sheet.frames.count >= sheet.frameLimit {
            setNotice("印样满了（这一页 \(sheet.frameLimit) 帧）：在「印样」里加条数、每条帧数再拖")
            return
        }
        updateContactSheet { sheet in
            guard !sheet.frames.contains(photoID) else { return }
            sheet.frames.append(photoID)
        }
    }

    /// 印样改回网格：这一卷的精选（没有就前几帧，最多 9 张）排一版；贴纸、手写字留着。
    func leaveContactSheet() {
        guard let sheet = page?.contactSheet else { return }
        let map = photoMap
        // 画得出来的那几帧（放不下的不算，同 CollagePage.photoIDs）。
        let frames = sheet.frames.prefix(sheet.frameLimit).filter { map[$0] != nil }
        let picks = frames.filter { map[$0]?.verdict == .pick || (map[$0]?.verdict == nil && map[$0]?.isPick == true) }
        let ids = Array((picks.isEmpty ? frames : picks).prefix(9))
        guard !ids.isEmpty else {
            pushUndo()
            if project.pages.indices.contains(pageIndex) { project.pages[pageIndex].contactSheet = nil }
            commitEdit()
            return
        }
        // solve 落下来时整页换成新的切分树（pageFor 不带 contactSheet），这一步就是撤销点。
        solve(photoIDs: ids)
    }

    // MARK: - 相册

    func setMode(_ mode: CollageMode) {
        guard mode != project.mode else { return }
        cancelPendingSolve()
        pushUndo()
        let oldCanvas = project.canvas
        // 相册切回单张：只留当前这个跨页（单张一页一张画布），留了第几个、原来几个 —— 提示一句（撤销找得回来）。
        var trimmed: (kept: Int, of: Int)?
        project.mode = mode
        if mode == .album {
            if project.canvas.seams != .fold { project.canvas = CollageCanvas.albums[0] }
        } else if project.canvas.seams == .fold {
            project.canvas = CollageCanvas.social[0]
            if project.pages.count > 1 {
                let kept = min(pageIndex, project.pages.count - 1)
                trimmed = (kept + 1, project.pages.count)
                project.pages = [project.pages[kept]]
            }
            pageIndex = 0
        }
        // 切到相册换了画布：婚礼 fine-art 的边距按册子重算（别的样式原样）。
        project.style = CollageStyleFineArt.adapted(project.style, from: oldCanvas, to: project.canvas) ?? project.style
        refitFreeformPages(from: oldCanvas)
        clearAlternatives()
        selection = nil
        commitEdit()
        // 散落页换到相册跨页（有中缝）或从跨页换回单张：按新画布重新撒一版，和切模式算同一步撤销
        // （等比缩放只是先顶着：单张的摆法缩进跨页正好横在中缝上）。
        if oldCanvas != project.canvas, let page, page.freeform, !page.photoIDs.isEmpty {
            scatter(photoIDs: page.photoIDs, spec: page.scatter ?? CollageScatterSpec(), recordUndo: false)
        }
        if let trimmed {
            setNotice("切回单张：只留了第 \(trimmed.kept) 个跨页（原来 \(trimmed.of) 个），别的跨页撤销可以找回")
        }
    }

    /// 相册编排主题（之后的「自动编排」按它编）、fine-art 的整章黑白。已经排好的跨页不动。
    func setAlbumTheme(_ theme: CollageAlbumTheme, chapterMono: Bool? = nil) {
        let mono = chapterMono ?? project.albumChapterMono
        guard theme != project.albumTheme || mono != project.albumChapterMono else { return }
        let what = theme != project.albumTheme ? "编排换成「\(theme.label)」" : "整章黑白" + (mono ? "开了" : "关了")
        pushUndo()
        project.albumTheme = theme
        project.albumChapterMono = mono
        commitEdit()
        if !project.pages.isEmpty { setNotice(what + "：点「自动编排」按它重排（已经排好的跨页没动）") }
    }

    /// 托盘里的全部照片自动编排成相册（去重可关）。
    func autoArrangeAlbum(dedupe: Bool) {
        let photos = project.photos
        guard !photos.isEmpty else {
            setNotice("托盘是空的：先带精选进来")
            return
        }
        let ctx = context
        // 编排主题跟着工程（「整本婚礼相册」之后再点自动编排还是 fine-art 的规则）。
        let theme = project.albumTheme
        let chapterMono = project.albumChapterMono
        let title = project.title
        busyText = "编排相册…"
        // 编排也在作废机制里：编排期间切回单张、撤销、套模板，结果回来不能盖掉。
        let ticket = beginSolve()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([CollagePage], [CollagePhotoRef], String?) in
                let plan = CollageAlbum.plan(photos, dedupe: dedupe, theme: theme, chapterMono: chapterMono, title: title)
                // fine-art：拿掉的分开说（同一场只留精选一直开着，「相似只留一张」只管画面相似的）。
                let note = theme == .fineArt && !plan.dropped.isEmpty ? CollageStyleFineArt.droppedNote(photos, plan: plan) : nil
                return (CollageAlbum.build(plan, context: ctx, seed: 11), plan.dropped, note)
            }.value
            // 编排期间换了场次：结果属于上一个场次，丢掉（不能写进新场次的项目）。
            guard let self, self.sessionToken == ticket.session else { return }
            if self.busyText == "编排相册…" { self.busyText = nil }
            guard ticket.generation == self.solveGeneration, self.isAlbum else { return }
            self.isSolving = false
            self.pushUndo()
            self.project.pages = result.0
            self.albumDropped = result.1
            self.pageIndex = 0
            self.clearAlternatives()
            self.commitEdit()
            if let note = result.2 {
                self.setNotice("编排好 \(result.0.count) 个跨页，\(note) 张（可在托盘里拖回）")
            } else {
                self.setNotice("编排好 \(result.0.count) 个跨页" + (result.1.isEmpty ? "" : "，相似的拿掉 \(result.1.count) 张（可在托盘里拖回）"))
            }
        }
    }

    func addPage() {
        pushUndo()
        let blank = CollagePage(root: CollageLayout.blankRoot(for: project.canvas))
        let at = min(project.pages.count, pageIndex + 1)
        project.pages.insert(blank, at: at)
        pageIndex = at
        commitEdit()
    }

    func deletePage(_ index: Int) {
        guard project.pages.indices.contains(index) else { return }
        pushUndo()
        let wasCurrent = index == pageIndex
        project.pages.remove(at: index)
        // 删的是前面的页：当前页往前挪一位，画面停在原来那一页上。
        if index < pageIndex { pageIndex -= 1 }
        pageIndex = max(0, min(pageIndex, project.pages.count - 1))
        if wasCurrent {
            finishCropEditForNavigation()
            selection = nil
            clearAlternatives()
        }
        commitEdit()
    }

    func movePage(_ index: Int, by delta: Int) {
        let target = index + delta
        guard project.pages.indices.contains(index), project.pages.indices.contains(target) else { return }
        pushUndo()
        project.pages.swapAt(index, target)
        pageIndex = target
        commitEdit()
    }

    /// 选中的照片挪到相邻跨页：插到那一页最大的照片格旁边（宽格往右劈、高格往下劈），
    /// 那一页的文字、完整显示、裁切都保留；想重排再点「换一批」。先算好目标页再从原页拿走，
    /// 任何一步不成立就什么都不动 —— 以前先删后解，解不出来照片就两头都没了。
    func moveSelectedPhoto(toPage target: Int) {
        guard let selection, let root, project.pages.indices.contains(target), target != pageIndex,
              var moved = root.node(at: selection)?.cell, moved.kind == .photo, moved.photoID != nil else { return }
        moved.crop = nil
        moved.locked = false
        moved.contain = false
        // 还在算的这一页「换一批」里带着这张照片：算完回来它就两个跨页上都有了。
        cancelSolveIfRunning()
        // 目标是散落版：放一张相纸（散落版不画切分树，插进树里就看不见了），放在相纸少的那半页正中
        // （跨页正中是中缝）。
        if project.pages[target].freeform, let id = moved.photoID, let photo = photoMap[id] {
            let others = project.pages[target].items.filter { $0.kind == .photo }
            let leftCount = others.filter { $0.cx < 0.5 }.count
            let x: Double = project.canvas.seams == .fold ? (leftCount <= others.count - leftCount ? 0.25 : 0.75) : 0.5
            let item = Self.photoItem(photo, frame: project.pages[target].scatter?.frame ?? .polaroid,
                                      at: CGPoint(x: x, y: 0.5))
            pushUndo()
            project.pages[target].items.append(item)
            project.pages[pageIndex].root = root.isLeaf ? CollageLayout.blankRoot(for: project.canvas)
                                                        : CollageLayout.remove(at: selection, from: root, canvas: project.canvas)
            self.selection = nil
            commitEdit()
            setNotice("已移到第 \(target + 1) 个跨页（放在照片少的那半页，拖到想要的位置）")
            return
        }
        let targetRoot = project.pages[target].root
        let frames = CollageLayout.pageGeometry(targetRoot, canvas: project.canvas, style: project.style).frames
        let newTarget: CollageNode
        var filledEmptySlot = false
        // 那一页有待放照片的空格（新开的跨页、胶装的空半页）：放进最大的那个空格，不在空格旁边再劈一刀。
        let emptySlot = frames.filter { $0.cell.kind == .photo && $0.cell.photoID == nil }
            .max(by: { $0.rect.area < $1.rect.area })
        if let slot = emptySlot {
            var t = targetRoot
            var path = slot.path
            // 整页一个空格、又是胶装：先按中缝分成左右两页，照片放右页（不能横跨中缝）。
            if t.isLeaf, !project.canvas.allowsCrossFold {
                t = CollageLayout.blankRoot(for: project.canvas)
                path = [1]
            }
            t.update(at: path) { $0.cell = moved }
            newTarget = t
            filledEmptySlot = true
        } else {
            let photoFrames = frames.filter { $0.cell.kind != .text }
            guard let anchor = (photoFrames.isEmpty ? frames : photoFrames).max(by: { $0.rect.area < $1.rect.area }) else { return }
            let edge: CollageLayout.Edge = anchor.rect.aspect >= 1 ? .right : .bottom
            newTarget = CollageLayout.insert(moved, at: anchor.path, edge: edge, into: targetRoot)
        }
        pushUndo()
        project.pages[target].root = newTarget
        project.pages[pageIndex].root = root.isLeaf ? CollageLayout.blankRoot(for: project.canvas)
                                                    : CollageLayout.remove(at: selection, from: root, canvas: project.canvas)
        self.selection = nil
        commitEdit()
        setNotice(filledEmptySlot ? "已移到第 \(target + 1) 个跨页（放进了那一页的空位）"
                                  : "已移到第 \(target + 1) 个跨页（插在最大那张旁边，想重排点「换一批」）")
    }

    // MARK: - 色调样张

    /// 这一页分数最高的照片（没有就托盘里最高的）套每个色调，方形小图。开了照片加网时样张也加网：
    /// 每个色调加网后的明暗不一样，彩色色调会变成同一副墨色纸色 —— 样张照实给看。
    func renderLookThumbs() {
        let map = photoMap
        let pool = (page?.photoIDs ?? []).compactMap { map[$0] }
        guard let hero = (pool.isEmpty ? project.photos : pool).max(by: { $0.score < $1.score }) else { return }
        // 样张 120 像素见方，点距一律不到 3 像素：只调影调不出点（点距不影响），纸色先按页面底色定死。
        var halftone = project.style.halftone
        if let h = halftone {
            halftone?.paper = CollageScreening.paper(h, background: project.style.background)
            halftone?.pitch = 0.001
        }
        let key = sessionToken.uuidString + hero.id + (halftone.map { "|\($0)" } ?? "")
        guard key != lookThumbKey else { return }
        lookThumbKey = key
        var base = project
        base.canvas = CollageCanvas(name: "look", width: 240, height: 240)
        base.style = CollageStyle()
        base.style.margin = 0
        base.style.halftone = halftone
        let page = CollagePage(root: .leaf(.photo(hero.id)))
        base.pages = [page]
        let hints = self.hints
        Task { [weak self] in
            let thumbs = await Task.detached(priority: .utility) { () -> [CollageLook: NSImage] in
                var out: [CollageLook: NSImage] = [:]
                for look in CollageLook.allCases {
                    var p = base
                    p.style.look = look
                    var opts = CollageRender.Options(scale: 0.5)
                    opts.includeBleed = false
                    if let cg = CollageRender.render(page: page, project: p, hints: hints, options: opts) {
                        out[look] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
                return out
            }.value
            guard let self, self.lookThumbKey == key else { return }
            self.lookThumbs = thumbs
        }
    }

    // MARK: - 风格预设样张

    /// 预设样张该不该重渲：这一页的版式和照片、画布、标题、路人信息。样式滑杆不算（每个预设有自己的样式）。
    var styleThumbSource: String {
        guard let page else { return "" }
        let c = project.canvas
        return "\(sessionToken)|\(page.id)|\(page.root.signature)|\(page.photoIDs.joined(separator: ","))|"
            + "\(page.items.count)|\(page.freeform)|\(c.width)x\(c.height)|\(hintsVersion)|\(project.title)"
            + "|\(project.masthead)|\(project.issue)|\(Self.lookSignature(page))"
            + (page.contactSheet.map { "|cs\($0.hashValue)" } ?? "")
    }

    /// 这一页单独设的色调 + 每格单独设的色调（切分树的 signature 不含它）：改了一页、一格的色调，预设样张、
    /// 模板缩略图要跟着重渲。散落页没有格子色调。
    static func lookSignature(_ page: CollagePage?) -> String {
        guard let page else { return "" }
        let own = page.look.map { "\($0.look.rawValue)\($0.strength)" } ?? "-"
        guard !page.freeform else { return own }
        let cells = page.root.leaves.map { $0.look.map { "\($0.look.rawValue)\($0.strength)" } ?? "" }
        return own + "|" + cells.joined(separator: ",")
    }

    /// 这一页套每个风格预设渲一张小图：预设按钮上直接看到「纸白、墨黑、相纸、画廊」是什么样（以前只有名字，
    /// 点了才知道）。停手 0.3 秒再渲，十几张小图一共几十毫秒。
    func renderStyleThumbs() {
        let key = styleThumbSource
        guard key != styleThumbKey else { return }
        styleThumbKey = key
        styleThumbTask?.cancel()
        guard let page else {
            styleThumbs = [:]
            return
        }
        var base = project
        base.pages = [page]
        let hints = self.hints
        let scale = min(1, 170 / Double(max(project.canvas.width, project.canvas.height)))
        styleThumbTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let thumbs = await Task.detached(priority: .utility) { () -> [String: NSImage] in
                var out: [String: NSImage] = [:]
                for preset in CollageStyles.all {
                    var p = base
                    p.style = preset.style
                    var opts = CollageRender.Options(scale: scale)
                    opts.includeBleed = false
                    opts.placeholders = true
                    if let cg = CollageRender.render(page: page, project: p, hints: hints, options: opts) {
                        out[preset.key] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
                return out
            }.value
            guard let self, !Task.isCancelled, self.styleThumbKey == key else { return }
            self.styleThumbs = thumbs
        }
    }

    // MARK: - 模板库缩略图

    /// 用这一页（不够从托盘按分数补）的照片把每个模板套一遍、渲小图。和点下去一样：相册里不套模板
    /// 的画布和样式、不拿别的跨页用过的照片。每个模板按自己的键判断要不要重渲 —— 自带样式和画布的
    /// 模板不跟着这边的样式滑杆重渲（以前拖一下滑杆 34 张全部重渲）。
    func renderTemplateThumbs() {
        let templates = allTemplates
        let album = isAlbum
        var ids = Self.unique(page?.photoIDs ?? [])
        let onPage = Set(ids)
        var otherPages = Set<String>()
        if album {
            for (i, p) in project.pages.enumerated() where i != pageIndex { otherPages.formUnion(p.photoIDs) }
        }
        ids += project.photos.filter { !onPage.contains($0.id) && !otherPages.contains($0.id) }
            .sorted { $0.score > $1.score }.map(\.id)
        let map = photoMap
        let photos = ids.prefix(16).compactMap { map[$0] }
        // 印样模板套用时拿托盘全部（按拍摄先后，相册里别的跨页用了的不拿，见 applyTemplate）：缩略图也拿这么多，
        // 不然「135 整卷」的缩略图只有 16 帧，套下去却是一整卷。
        let rollPhotos = CollageContact.rollOrder(project.photos.filter { !otherPages.contains($0.id) })
        let rollKey = "|roll" + rollPhotos.map(\.id).joined(separator: ",")
        // 按照片集合认（换一批、置顶只改顺序，不用整批重渲）；标题、副标题也算（模板里的 {title}，
        // 以前填了标题缩略图还写着「拾光」）。
        // 套下去会留着这一页、这几张照片单独设的色调（applyTemplate）：缩略图也带上，键里也算上。
        let pageLook = page?.look
        let lookSource = page.flatMap { $0.freeform ? nil : $0.root }
        let lookKey = Self.lookSignature(page)
        let photoKey = photos.map(\.id).sorted().joined(separator: ",") + "|\(hintsVersion)|\(album)"
            + "|\(project.title)|\(project.subtitle)|\(project.masthead)|\(project.issue)|\(lookKey)"
        let styleKey = "|s\(project.style.hashValue)"
        let canvasKey = "|c\(project.canvas.hashValue)"
        var todo: [(CollageTemplate, String)] = []
        for t in templates {
            var key = photoKey + "|\(t.hashValue)"
            if t.contactSheet != nil { key += rollKey }
            if album || t.style == nil { key += styleKey }
            if album || t.canvas == nil { key += canvasKey }
            if templateThumbKeys[t.name] != key { todo.append((t, key)) }
        }
        // 先作废还在渲的那一批（按撤销前的样式在渲的，渲完会把旧样式的图写回来）。
        templateThumbTask?.cancel()
        guard !todo.isEmpty else {
            templateThumbsBusy = false
            return
        }
        var base = project
        base.pages = []
        let hints = self.hints
        let token = sessionToken
        templateThumbsBusy = true
        templateThumbTask = Task { [weak self] in
            defer { if !Task.isCancelled { self?.templateThumbsBusy = false } }
            try? await Task.sleep(for: .milliseconds(200))
            for (template, key) in todo {
                if Task.isCancelled { return }
                let source = template.contactSheet != nil ? rollPhotos : photos
                let thumb = await Task.detached(priority: .utility) { () -> NSImage? in
                    Self.templateThumb(template, base: base, photos: source, hints: hints, album: album,
                                       pageLook: pageLook, lookSource: lookSource)
                }.value
                guard let self, self.sessionToken == token, !Task.isCancelled else { return }
                if let thumb {
                    self.templateThumbs[template.name] = thumb
                    self.templateThumbKeys[template.name] = key
                }
            }
        }
    }

    nonisolated private static func templateThumb(_ template: CollageTemplate, base: CollageProject,
                                                  photos: [CollagePhotoRef],
                                                  hints: [String: CollageCrop.Hints], album: Bool,
                                                  pageLook: CollageLookSetting? = nil,
                                                  lookSource: CollageNode? = nil) -> NSImage? {
        var project = base
        if !album {
            if let s = template.style { project.style = s }
            if let c = template.canvas { project.canvas = c }
        }
        var map: [String: CollagePhotoRef] = [:]
        for p in project.photos { map[p.id] = p }
        let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map, hints: hints, heroID: nil)
        // 印样自己按容量截（容量自动 = 整卷都上），不按 photoSlots 截。
        let given = template.contactSheet != nil ? photos : Array(photos.prefix(max(1, template.photoSlots)))
        var page = CollageTemplates.apply(template, photos: given, context: ctx, seed: 7)
        // 和 applyTemplate 一样留着页、格单独设的色调。
        if page.look == nil { page.look = pageLook }
        if let lookSource, !page.freeform { page.root = CollageLayout.carryCellLooks(from: lookSource, into: page.root) }
        project.pages = [page]
        let scale = min(1, 300 / Double(max(project.canvas.width, project.canvas.height)))
        var opts = CollageRender.Options(scale: scale)
        opts.includeBleed = false
        opts.placeholders = true
        guard let cg = CollageRender.render(page: page, project: project, hints: hints, options: opts) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - 撤销

    /// coalesce：滑杆连续拖动 0.6 秒内只记一次。只和紧挨着的上一次「也是连续调整」的合并 ——
    /// 刚点完「换一批」马上拖滑杆，不能把滑杆的改动并进换一批那一步（撤销会一次退两步）。
    private func pushUndo(coalesce: Bool = false) {
        guard !undoGroupOpen else { return }
        let now = Date()
        if coalesce, lastPushCoalesced, now.timeIntervalSince(lastUndoPush) < 0.6 {
            lastUndoPush = now
            return
        }
        lastPushCoalesced = coalesce
        lastUndoPush = now
        undoStack.append(project)
        undoPushes += 1
        if undoStack.count > 120 { undoStack.removeFirst(undoStack.count - 120) }
        redoStack.removeAll()
        updateUndoFlags()
    }

    /// 几样改动合成一步撤销（交接：进托盘 + 排版 + 套水印）：开头记一步，body 里同步发生的 pushUndo 都
    /// 不再记。body 里发起的求解要自己传 recordUndo: false —— 结果落下来时这里早结束了。什么都没变、
    /// 也没有排版在算：不留空步（重做栈照旧）。
    private func asOneUndoStep(_ body: () -> Void) {
        let before = project
        let redo = redoStack
        pushUndo()
        let generation = solveGeneration
        undoGroupOpen = true
        body()
        undoGroupOpen = false
        let pending = isSolving && solveGeneration != generation
        if !pending, project == before, undoStack.last == before {
            undoStack.removeLast()
            redoStack = redo
            updateUndoFlags()
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        restore(next)
    }

    private func restore(_ p: CollageProject) {
        cancelPendingSolve()
        let keepItem = selectedItem
        if p.watermark != project.watermark { watermarkRevision += 1 }
        project = p
        pageIndex = min(pageIndex, max(0, project.pages.count - 1))
        selection = nil
        // 选中的图层撤销之后还在：接着选着（以前一律清掉，再按 → 就变成「下一版」，整页重排）。
        if let keepItem, page?.items.contains(where: { $0.id == keepItem }) == true {
            selectedItem = keepItem
        } else {
            selectedItem = nil
        }
        cropEditing = false
        cropUndoPending = false
        // 撤销到托盘里有、但这份快照还没抄过亮度 / 黑白的照片（快照比路人信息早）：补上。
        adoptHintFacts()
        // 撤销回去的版不一定是备选里的任何一个：备选作废。
        clearAlternatives()
        lastUndoPush = .distantPast
        updateUndoFlags()
        scheduleProjectSave()
        setNeedsRender()
        schedulePageThumbs()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// 每次编辑之后：存盘 + 重渲。选中的路径如果已经不是一格（删格、换版之后结构变了），清掉。
    private func commitEdit() {
        if let s = selection, isFreeform || isContactSheet || root?.node(at: s)?.isLeaf != true {
            selection = nil
            cropEditing = false
        }
        if let id = selectedItem, page?.items.contains(where: { $0.id == id }) != true {
            selectedItem = nil
        }
        updateUndoFlags()
        scheduleProjectSave()
        setNeedsRender()
        schedulePageThumbs()
    }

    /// 相册跨页条：编辑停下 0.25 秒后把每页渲一张小图（一页几毫秒）。
    func schedulePageThumbs() {
        // 单张拼图有好几页（一键成套出的一期杂志、轮播组图）也要页条。
        guard isAlbum || project.pages.count > 1 else {
            if !pageThumbs.isEmpty { pageThumbs = [:] }
            return
        }
        thumbTask?.cancel()
        let snapshot = project
        let hints = self.hints
        thumbTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let thumbs = await Task.detached(priority: .utility) { () -> [UUID: NSImage] in
                let scale = min(1, 260 / Double(max(snapshot.canvas.width, snapshot.canvas.height)))
                var out: [UUID: NSImage] = [:]
                for page in snapshot.pages {
                    var opts = CollageRender.Options(scale: scale)
                    opts.includeBleed = false
                    opts.placeholders = true
                    guard let cg = CollageRender.render(page: page, project: snapshot, hints: hints, options: opts) else { continue }
                    out[page.id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                return out
            }.value
            guard !Task.isCancelled else { return }
            self?.pageThumbs = thumbs
        }
    }

    // MARK: - 预览渲染（只渲最新的那一次）

    func setViewport(pixels: CGSize) {
        guard pixels.width > 10, pixels.height > 10 else { return }
        let old = viewportPixels
        viewportPixels = pixels
        if abs(old.width - pixels.width) > 8 || abs(old.height - pixels.height) > 8 { setNeedsRender() }
    }

    private var targetScale: Double {
        let sx = Double(viewportPixels.width) / Double(max(1, project.canvas.width))
        let sy = Double(viewportPixels.height) / Double(max(1, project.canvas.height))
        return max(0.05, min(1, min(sx, sy)))
    }

    func setNeedsRender() {
        renderDirty = true
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while true {
                guard let self, self.renderDirty else { break }
                self.renderDirty = false
                guard let page = self.page else {
                    self.preview = nil
                    continue
                }
                let snapshot = self.project
                let hints = self.hints
                let scale = self.targetScale
                var opts = CollageRender.Options(scale: scale)
                opts.includeBleed = false
                opts.guides = self.showGuides
                opts.placeholders = true
                // 预览 = 导出：水印一直画（导出关了「导出带水印」才不画）。
                opts.watermark = true
                let image = await Task.detached(priority: .userInitiated) {
                    CollageRender.render(page: page, project: snapshot, hints: hints, options: opts)
                }.value
                if let image {
                    self.preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self.previewScale = scale
                }
            }
            self?.renderTask = nil
        }
    }

    // MARK: - 导出

    var defaultOutputFolder: URL? {
        photoDir?.appendingPathComponent(ImageLoader.collageExportSubfolder)
    }

    var outputFolder: URL? {
        exportOptions.outputPath.map { URL(fileURLWithPath: $0) } ?? defaultOutputFolder
    }

    var exportBlockedReason: String? {
        if isExporting { return "正在导出" }
        if project.pages.isEmpty { return "还没有版式" }
        if outputFolder == nil { return "先选择输出目录" }
        return nil
    }

    func export() {
        guard exportBlockedReason == nil, let folder = outputFolder else { return }
        let snapshot = project
        let hints = self.hints
        let options = exportOptions
        // 直接写进输出目录（以前每次先建一个「标题_时间」子目录再往里写）。
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = "无法创建输出目录: \(error.localizedDescription)"
            return
        }
        let base = exportBase(in: folder, project: snapshot, options: options)
        let plan = Self.exportPlan(base: base, project: snapshot, options: options)
        isExporting = true
        exportCancelled = false
        lastError = nil
        progressFraction = 0
        progressText = "导出 0/\(snapshot.pages.count)…"
        let wantPDF = snapshot.mode == .album && options.pdf
        Task { [weak self] in
            // 只攒每页编码好的 JPEG（~5MB），不攒位图（30×30cm 跨页 ~100MB 一张）。
            var pdfPages: [Data] = []
            var failure: String?
            var lowRes: [String] = []
            var missing: [String] = []
            var signatureLost = false
            var fillerBody = false
            for (i, page) in snapshot.pages.enumerated() {
                if self?.exportCancelled ?? true { break }
                let result = await Task.detached(priority: .userInitiated) { () -> PageResult in
                    var opts = CollageRender.Options(scale: 1)
                    opts.export = true
                    opts.includeBleed = true
                    // 「导出带水印」跟着这个拼图存。
                    opts.watermark = snapshot.watermark?.exportEnabled ?? true
                    let report = CollageRender.RenderReport()
                    opts.report = report
                    guard let image = CollageRender.render(page: page, project: snapshot, hints: hints, options: opts) else {
                        return PageResult(pdfData: nil, error: "第 \(i + 1) 页渲染失败", lowRes: [], missing: [])
                    }
                    do {
                        let data = try Self.writePage(image, files: plan.pages[i], project: snapshot,
                                                      options: options, dir: folder, wantPDF: wantPDF)
                        return PageResult(pdfData: data, error: nil, lowRes: report.lowRes, missing: report.missing,
                                          signatureLost: Self.signatureLost(report),
                                          fillerBody: Self.fillerBody(report, canvas: snapshot.canvas))
                    } catch {
                        return PageResult(pdfData: nil, error: error.localizedDescription, lowRes: [], missing: [])
                    }
                }.value
                if let data = result.pdfData { pdfPages.append(data) }
                if let f = result.error, failure == nil { failure = f }
                lowRes += result.lowRes
                missing += result.missing
                signatureLost = signatureLost || result.signatureLost
                fillerBody = fillerBody || result.fillerBody
                guard let self else { return }
                self.progressFraction = Double(i + 1) / Double(snapshot.pages.count)
                self.progressText = "导出 \(i + 1)/\(snapshot.pages.count)…"
            }
            if wantPDF, let pdfName = plan.pdf, !pdfPages.isEmpty, !(self?.exportCancelled ?? true) {
                self?.progressText = "生成 PDF…"
                let pdfURL = folder.appendingPathComponent(pdfName)
                let pages = pdfPages
                let pdfError = await Task.detached(priority: .userInitiated) { () -> String? in
                    do {
                        try CollageExport.writePDF(jpegPages: pages, canvas: snapshot.canvas, to: pdfURL,
                                                   title: snapshot.title, cropMarks: options.cropMarks)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let pdfError, failure == nil { failure = pdfError }
            }
            guard let self else { return }
            self.isExporting = false
            self.progressFraction = nil
            if self.exportCancelled {
                self.progressText = "导出已取消（已写出的保留）"
            } else if let failure {
                self.progressText = ""
                self.lastError = "导出失败: \(failure)"
            } else {
                let files = plan.pages.flatMap { $0 } + (plan.pdf.map { [$0] } ?? [])
                let main = plan.pdf ?? files.first ?? base
                let clean = snapshot.watermark.map { !$0.exportEnabled && $0.anyLayerOn } == true ? "（不带水印）" : ""
                self.progressText = "导出完成\(clean) → \(main)" + (files.count > 1 ? "（共 \(files.count) 个文件）" : "")
                AppRuntime.revealInFinder(files.map { folder.appendingPathComponent($0) })
            }
            if let warning = Self.exportWarning(missing: missing, lowRes: lowRes, signatureLost: signatureLost,
                                                fillerBody: fillerBody) {
                self.lastError = warning
            }
        }
    }

    /// 成品里有退化的地方：说清楚是哪几张、缺了什么（导出本身不算失败）。命令行 renderexport 也打印这一句。
    /// fillerBody = 印刷画布上的正文还是灰条 / 占位字（社交尺寸上那只是纹理，印出来是要被人读的）。
    static func exportWarning(missing: [String], lowRes: [String], signatureLost: Bool,
                              fillerBody: Bool = false) -> String? {
        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("\(Set(missing).count) 张照片读不了，格子空着：" + Set(missing).sorted().prefix(4).joined(separator: " "))
        } else if !lowRes.isEmpty {
            parts.append("\(Set(lowRes).count) 张原图读不了，用了 1024 预览（印刷会糊）：" + Set(lowRes).sorted().prefix(4).joined(separator: " "))
        }
        if signatureLost { parts.append(CollageWatermarks.signatureLostWarning) }
        if fillerBody { parts.append(fillerBodyWarning) }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    static let fillerBodyWarning = "正文还是灰条或占位字：印出来是要被人读的，在「文字」里换成自己的字"

    /// 印刷画布（≥ 150 dpi）上有正文是灰条 / 占位字。
    nonisolated static func fillerBody(_ report: CollageRender.RenderReport, canvas: CollageCanvas) -> Bool {
        canvas.isPrint && report.texts.contains { $0.hasFillerBody }
    }

    /// 这一页该有签名、签名图却读不了（渲染记账里的「签名读不了」）。
    nonisolated static func signatureLost(_ report: CollageRender.RenderReport) -> Bool {
        report.marks.contains { $0.skipped == "签名读不了" }
    }

    func cancelExport() {
        guard isExporting else { return }
        exportCancelled = true
        progressText = "正在取消…"
    }

    /// 固定格式必须钉 en_US_POSIX：系统偏好 12 小时制时，"HH" 会被换成「上午9」，
    /// 文件夹名就成了「春日宴_20260928-上午90228」。
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private struct PageResult {
        var pdfData: Data?
        var error: String?
        var lowRes: [String]
        var missing: [String]
        var signatureLost = false
        var fillerBody = false
    }

    /// 一页落盘：单张按画布切缝写九宫格/轮播；相册每个跨页一张（带出血）。
    /// `wantPDF` 时返回这一页进 PDF 用的 JPEG 数据（JPEG 格式就是写盘的同一份）。
    /// 文件名：手动填的，或者导出那一刻的时间（精确到秒）。输出目录里已经有同名的就加 -2、-3……
    /// （按这次要写的每一个文件查，不覆盖以前导出的）。
    private func exportBase(in folder: URL, project: CollageProject, options: ExportOptions) -> String {
        let typed = Self.cleanFileName(exportName, ext: options.format.ext)
        let root = typed.isEmpty ? Self.stampFormatter.string(from: Date()) : typed
        var candidate = root
        var n = 2
        while n < 1000 {
            let plan = Self.exportPlan(base: candidate, project: project, options: options)
            let names = plan.pages.flatMap { $0 } + (plan.pdf.map { [$0] } ?? [])
            let taken = names.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            if !taken { break }
            candidate = "\(root)-\(n)"
            n += 1
        }
        return candidate
    }

    /// 手填的名字：去掉路径符号、首尾空白、开头的点；顺手去掉多打的扩展名。
    nonisolated static func cleanFileName(_ raw: String, ext: String) -> String {
        var name = raw.filter { $0 != "/" && $0 != ":" && !$0.isNewline }
            .trimmingCharacters(in: .whitespaces)
        for suffix in [".\(ext)", ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".pdf"]
        where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        while name.hasPrefix(".") { name.removeFirst() }
        return String(name.prefix(100)).trimmingCharacters(in: .whitespaces)
    }

    /// 这次导出每一页写哪几个文件（都直接在输出目录里，同一个名字开头），相册另有一份 PDF。
    /// 写文件和查重名用同一份清单。
    struct ExportPlan: Sendable {
        var pages: [[String]]
        var pdf: String?
    }

    nonisolated static func exportPlan(base: String, project: CollageProject, options: ExportOptions) -> ExportPlan {
        let ext = options.format.ext
        let count = project.pages.count
        var pages: [[String]] = []
        for i in 0..<count {
            let two = String(format: "%02d", i + 1)
            if project.mode == .album {
                pages.append(["\(base)_跨页_\(two).\(ext)"])
                continue
            }
            let name = count > 1 ? "\(base)_\(two)" : base
            var files = ["\(name).\(ext)"]
            switch project.canvas.seams {
            case .grid9:
                files += (1...9).map { "\(name)_九宫格_\($0).\(ext)" }
            case .carousel:
                files += (1...max(1, project.canvas.slides)).map { "\(name)_轮播_\($0).\(ext)" }
            default:
                break
            }
            pages.append(files)
        }
        let pdf: String? = project.mode == .album && options.pdf ? "\(base).pdf" : nil
        return ExportPlan(pages: pages, pdf: pdf)
    }

    /// `files`：这一页的文件名（exportPlan 给的：第一个是整张，后面是九宫格 / 轮播切片）。
    nonisolated private static func writePage(_ image: CGImage, files: [String], project: CollageProject,
                                              options base: ExportOptions, dir: URL, wantPDF: Bool) throws -> Data? {
        let canvas = project.canvas
        guard let mainName = files.first else { return nil }
        // 加了网的照片：JPEG 质量低于 0.9 网点边上会起振铃（一圈脏点），压到 0.9 以上。
        var options = base
        if project.style.halftone != nil { options.quality = max(0.9, options.quality) }
        if project.mode == .album {
            let url = dir.appendingPathComponent(mainName)
            if options.format == .jpeg {
                guard let data = CollageExport.encode(image, format: .jpeg, quality: options.quality, dpi: canvas.dpi) else {
                    throw CollageExport.ExportError.encode(url.lastPathComponent)
                }
                do { try data.write(to: url, options: .atomic) } catch {
                    throw CollageExport.ExportError.encode(url.lastPathComponent)
                }
                return wantPDF ? data : nil
            }
            try CollageExport.write(image, to: url, format: options.format, quality: options.quality, dpi: canvas.dpi)
            return wantPDF ? CollageExport.encode(image, format: .jpeg, quality: 0.93, dpi: canvas.dpi) : nil
        }
        let trimmed = CollageExport.trimmed(image, bleed: canvas.bleed) ?? image
        try CollageExport.write(image, to: dir.appendingPathComponent(mainName), format: options.format,
                                quality: options.quality, dpi: canvas.dpi)
        let tileNames = Array(files.dropFirst())
        var tiles: [CGImage] = []
        switch canvas.seams {
        case .grid9:
            tiles = CollageExport.split(trimmed, rows: 3, cols: 3)
        case .carousel:
            tiles = CollageExport.split(trimmed, rows: 1, cols: max(1, canvas.slides))
        default:
            break
        }
        for (tile, name) in zip(tiles, tileNames) {
            try CollageExport.write(tile, to: dir.appendingPathComponent(name), format: options.format,
                                    quality: options.quality, dpi: canvas.dpi)
        }
        return nil
    }

    // MARK: - 提示

    func setNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        // 几条合成一条的（交接）长：每 10 个字多留一秒，5～10 秒。
        let seconds = min(10, max(5, Double(text.count) / 10))
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - 持久化：项目（每场次）

    /// 强引用 self：窗口关得快（store 跟着释放）时，这一秒内的改动也要写完再走。
    private func scheduleProjectSave() {
        projectSaveTask?.cancel()
        projectSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.saveProject()
        }
    }

    /// 立刻落盘（命令行脚本退出前调：延迟保存还没到点进程就退了）。
    func flushSaves() {
        flushProjectSave()
        flushStateSave()
    }

    private func flushProjectSave() {
        guard projectSaveTask != nil else { return }
        projectSaveTask?.cancel()
        projectSaveTask = nil
        saveProject()
    }

    private func saveProject() {
        projectSaveTask = nil
        guard let url = projectURL else { return }
        do {
            let data = try JSONEncoder().encode(project)
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = "拼图项目保存失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 持久化：模板 + 默认样式（全局）

    private struct PersistState: Codable {
        var templates: [CollageTemplate] = []
        var style = CollageStyle()
        var canvas = CollageCanvas()
        var export = ExportOptions()
        var layoutStyle: LayoutStyle = .grid

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            templates = (try? c.decodeIfPresent([CollageTemplate].self, forKey: .templates)) ?? nil ?? []
            style = (try? c.decodeIfPresent(CollageStyle.self, forKey: .style)) ?? nil ?? CollageStyle()
            canvas = (try? c.decodeIfPresent(CollageCanvas.self, forKey: .canvas)) ?? nil ?? CollageCanvas()
            export = (try? c.decodeIfPresent(ExportOptions.self, forKey: .export)) ?? nil ?? ExportOptions()
            layoutStyle = (try? c.decodeIfPresent(LayoutStyle.self, forKey: .layoutStyle)) ?? nil ?? .grid
        }
    }

    private var defaultStyle = CollageStyle()
    private var defaultCanvas = CollageCanvas()
    /// 全局设置有没有改过：没改过退出时不写（以前从没打开拼图 tab 也会把出厂值写回去）。
    private var stateDirty = false
    private var statePath: URL { stateDir.appendingPathComponent("state.json") }

    private func loadState() {
        guard let data = try? Data(contentsOf: statePath) else { return }
        guard let state = try? JSONDecoder().decode(PersistState.self, from: data) else {
            // 整个文件坏了：挪到一边再用默认，别让下次保存把用户模板盖掉。
            let backup = stateDir.appendingPathComponent("state.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: statePath, to: backup)
            lastError = "拼图设置文件损坏，已备份为 state.json.bak"
            return
        }
        // 旧版存的模板可能和后来新加的内置模板同名（列表、缩略图按名字认，会串）：加后缀。
        var seen = Set<String>()
        userTemplates = state.templates.compactMap { t -> CollageTemplate? in
            var renamed = t
            renamed.name = userTemplateName(t.name)
            return seen.insert(renamed.name).inserted ? renamed : nil
        }
        defaultStyle = state.style
        defaultCanvas = state.canvas
        exportOptions = state.export
        layoutStyle = state.layoutStyle
        stateSaveTask?.cancel()
        stateDirty = false
    }

    private func scheduleStateSave() {
        stateDirty = true
        stateSaveTask?.cancel()
        stateSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.saveState()
        }
    }

    /// 模板增删是用户主动的，`force` 立即写；退出时只在改过才写。
    private func flushStateSave(force: Bool = false) {
        stateSaveTask?.cancel()
        guard force || stateDirty else { return }
        saveState()
    }

    private func saveState() {
        stateDirty = false
        var state = PersistState()
        state.templates = userTemplates
        state.style = defaultStyle
        state.canvas = defaultCanvas
        state.export = exportOptions
        state.layoutStyle = layoutStyle
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: statePath, options: .atomic)
        } catch {
            lastError = "拼图设置保存失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - 实时桥（DESIGN §9.3、§9.5.1、§10.6「STEP 1 不做了」）：AI 经桥调的几样，界面和命令行都不走这里

extension CollageStore {
    /// 编辑指纹（§9.3 第二轮改）：工程的 JSON（键排序）取 SHA-1 前 12 位，但托盘照片只留按顺序的 id —— 判决、
    /// 亮度、黑白这些后台自己会刷新的字段不算（改判后刷新托盘、路人信息算完都不让 if_digest 失效）。
    /// collage_get_state 的 digest、写工具的 digest_before / digest_after、externalEdit 的 changed 都用它；
    /// 命令行的 digest op（整个工程，CollageWatermarkCLI.digest）不变。
    var editDigest: String { Self.editDigest(project) }

    nonisolated static func editDigest(_ project: CollageProject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(project),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "?" }
        object["photos"] = project.photos.map(\.id)
        guard let reduced = MCPJSON.data(object) else { return "?" }
        return Insecure.SHA1.hash(data: reduced).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// 桥的一个请求 = 恰好一步撤销（§9.5.1）：不并进用户刚才那一下（0.6 s 内的连续调整），用户下一下也不并进来。
    /// body 里同步发生的 pushUndo 只记开头那一步；什么都没变就把空步撤掉（undoPushes 照样 +1，不回退）。
    /// 返回编辑指纹变没变。
    @discardableResult
    func externalEdit(_ body: () -> Void) -> Bool {
        let before = editDigest
        lastPushCoalesced = false
        lastUndoPush = .distantPast
        asOneUndoStep(body)
        lastPushCoalesced = false
        lastUndoPush = .distantPast
        return editDigest != before
    }

    /// 成套的结局，连同落地那一刻的撤销计数、深度和提示：在 outcome 回调里当场取。回调恢复 continuation 以后，
    /// 桥那边要等主线程的下一拍才接着跑，这中间用户按的键（改标题、⌘Z）会先落下来；那时再读，就会把用户那一步
    /// 记成 AI 的，之后 app_undo 撤掉的是用户的那一步。
    struct KitLanding {
        let outcome: KitOutcome
        let undoPushes: Int
        let undoDepth: Int
        let notice: String?
    }

    /// 一键成套 / 换封面的桥版本：异步的不包 asOneUndoStep（它们落地时自己记一步，§9.5.1），发起前、落地后各复位一次
    /// 合并状态，等 outcome 回来。
    func externalKit(_ kit: CollageKitID, coverStep: Int = 0) async -> KitLanding {
        lastPushCoalesced = false
        lastUndoPush = .distantPast
        let landing = await withCheckedContinuation { (cont: CheckedContinuation<KitLanding, Never>) in
            applyKit(kit, coverStep: coverStep, outcome: { [unowned self] o in
                let now = KitLanding(outcome: o, undoPushes: undoPushes, undoDepth: undoDepth, notice: notice)
                cont.resume(returning: now)
            })
        }
        lastPushCoalesced = false
        lastUndoPush = .distantPast
        return landing
    }

    /// 路人信息算完没有（命令行同名的是 CollageOpsScript.run 里的局部函数，CollageCLI.swift 那份不动）：主线程上
    /// 每 20 ms 看一次 hintsPending，算完回 true，到时间回 false。成套、换封面发起之前等它：不等的话挑封面用的是
    /// 「算到第几张」的路人信息，结果跟着机器快慢变。
    func hintsSettled(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while hintsPending {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// 预览重渲完没有（结果里要带「用户此刻屏幕上的拼图」，§9.4.3 第 12 步）：等后台渲染任务跑完、没有新的脏标记。
    func previewSettled(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while renderTask != nil || renderDirty {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// 按名字找模板：先全名、再内置分类名（套这个分类的第一个）、再名字里含这几个字的。
    /// 和 --collage-ops 的 applytpl 同一个规则，照抄 CollageCLI.swift 里 `case "applytpl"` 那三行（那边不动）。
    func template(named name: String) -> CollageTemplate? {
        allTemplates.first(where: { $0.name == name })
            ?? allTemplates.first(where: { $0.builtin && $0.category == name })
            ?? allTemplates.first(where: { $0.name.contains(name) })
    }

    /// 改某一格第 index 个字块的第一行（照 CollageCLI.swift 的 overlaytext op）。格子或字块不在 = false，什么都不动。
    /// 调用方自己包 externalEdit（和标题、刊头一起算一步）。
    @discardableResult
    func setOverlayFirstLine(_ text: String, at path: [Int], index: Int) -> Bool {
        guard let cell = root?.node(at: path)?.cell, cell.overlays.indices.contains(index) else { return false }
        var t = cell.overlays[index].text
        if !t.lines.isEmpty { t.lines[0].text = text }
        updateText(t, target: .overlay(path, cell.photoID, page?.id, index))
        return true
    }

    /// 换样式 / 色调 / 强度（照 CollageCLI.swift 的 style、look、strength 三个 op）：预设整套换（不合并），
    /// 色调和强度在它上面再改。调用方自己包 externalEdit。
    func setStyleParts(preset: String?, look: CollageLook?, strength: Double?) {
        if let preset { setStyle(CollageStyles.preset(preset), coalesce: false) }
        if look != nil || strength != nil {
            var st = project.style
            if let look { st.look = look }
            if let strength { st.lookStrength = strength }
            setStyle(st)
        }
    }
}

/// 文字编辑器写回哪里：文字格、照片上的字、自由图层里的字。
enum CollageTextTarget: Hashable {
    /// 路径 + 所在页（相册切了跨页，迟到的提交不认）。
    case cell([Int], UUID?)
    /// 路径 + 那一格当时的照片 + 所在页（换一批后路径上换了照片就不认）+ 第几个字块。
    case overlay([Int], String?, UUID?, Int)
    case item(UUID)
}
