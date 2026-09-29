import Foundation
import SwiftUI
import AppKit

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
        didSet { if selection != nil, selectedItem != nil { selectedItem = nil } }
    }
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
    /// 色调样张（这一页的主图套每个色调）。
    @Published private(set) var lookThumbs: [CollageLook: NSImage] = [:]
    private var lookThumbKey = ""
    private var hintTask: Task<Void, Never>?
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
    }

    @Published var exportOptions = ExportOptions() { didSet { scheduleStateSave() } }
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

    init(dataDir: URL) {
        stateDir = dataDir.appendingPathComponent("collage")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        loadState()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushProjectSave()
                self?.flushStateSave()
            }
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

    /// 成品像素坐标里的几何（画布叠加层、拖缝、落点都用它）。散落版没有格子。
    var geometry: CollageLayout.Geometry {
        guard let root, !isFreeform else { return CollageLayout.Geometry() }
        let content = CollageLayout.contentRect(canvas: project.canvas, style: project.style)
        let gutter = CollageLayout.gutterPixels(canvas: project.canvas, style: project.style)
        return CollageLayout.geometry(root, in: content, gutter: gutter)
    }

    var selectedCell: CollageCell? {
        guard let selection else { return nil }
        return root?.node(at: selection)?.cell
    }

    var isFreeform: Bool { page?.freeform ?? false }
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

    /// 当前页每格的取景（界面画人脸框、切脸警告用）—— 和渲染器同一个取景区域。
    func window(for frame: CollageLayout.Frame) -> CollageCrop.Window? {
        guard frame.cell.kind == .photo, let id = frame.cell.photoID, let photo = photoMap[id] else { return nil }
        let geo = geometry
        let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: geo.frames,
                                                     photos: photoMap, tight: project.style.tightSmallCells)
        return CollageCrop.window(for: photo, cell: frame.cell, cellAspect: CollageCrop.aspect(of: photoArea(for: frame)),
                                  framing: framing, hints: hints[id])
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

    /// 选中格子上压的字在成品上的位置（和渲染器同一套算法：画布上的虚线框、拖字用）。
    func overlayPlacement(for frame: CollageLayout.Frame) -> CollageOverlays.Placement? {
        guard let overlay = frame.cell.overlay, let page else { return nil }
        let map = photoMap
        let ids = page.photoIDs
        let photo = frame.cell.photoID.flatMap { map[$0] }
        let framing = CollageLayout.effectiveFraming(path: frame.path, cell: frame.cell, in: geometry.frames,
                                                     photos: map, tight: project.style.tightSmallCells)
        let vars = CollageTypeset.variables(project: project, root: page.root, photos: map, pagePhotoIDs: ids,
                                            pageID: page.id)
        let bg = CollageRender.backgroundColor(project: project, pagePhotoIDs: ids, photos: map)
        return CollageRender.overlayPlacement(overlay, cell: frame.cell, frameRect: frame.rect.cgRect,
                                              project: project, photo: photo, framing: framing,
                                              hints: frame.cell.photoID.flatMap { hints[$0] }, vars: vars,
                                              background: bg)
    }

    // MARK: - 场次

    /// 批量页换了场次：存当前的，读新场次的拼图项目。没打开文件夹时用一个默认项目文件，
    /// 那时做的拼图也不会丢。
    func attach(sessionDir: URL?, photoDir: URL?) {
        let newURL = sessionDir?.appendingPathComponent("collage.json")
            ?? stateDir.appendingPathComponent("scratch.json")
        guard newURL != projectURL else { return }
        finishCropEditForNavigation()
        flushProjectSave()
        projectURL = newURL
        self.photoDir = photoDir
        sessionToken = UUID()
        solveGeneration += 1
        isSolving = false
        busyText = nil
        hintTask?.cancel()
        hints = [:]
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoFlags()
        selection = nil
        selectedItem = nil
        clearAlternatives()
        albumDropped = []
        lookThumbKey = ""
        lookThumbs = [:]
        templateThumbKeys = [:]
        templateThumbTask?.cancel()
        templateThumbsBusy = false
        templateThumbs = [:]
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
        computeHints(for: project.photos)
        setNeedsRender()
        schedulePageThumbs()
    }

    // MARK: - 托盘：导入

    /// 从批量页带照片进来（网格多选的「拼这几张」、精选、精华 Top N）。已在托盘里的不重复加。
    /// `layout` = 带进来之后直接排一版。
    func importFromBatch(ids: [String], batch: BatchStore, layout: Bool) {
        let items = ids.compactMap { batch.item(withID: $0) }
        addRefs(from: items, layout: layout ? .solve(ids) : .none)
    }

    func importVerdicts(batch: BatchStore, includeUsable: Bool) {
        let items = batch.items.filter { $0.verdict == .pick || (includeUsable && $0.verdict == .usable) }
        addRefs(from: items, layout: .none)
    }

    func importTop(_ n: Int, batch: BatchStore) {
        let ids = batch.topPicks(n).ids
        addRefs(from: ids.compactMap { batch.item(withID: $0) }, layout: .none)
    }

    private enum AfterImport {
        case none
        case solve([String])
    }

    private func addRefs(from items: [BatchItem], layout: AfterImport) {
        guard !items.isEmpty else {
            setNotice("没有可带进来的照片")
            return
        }
        busyText = "读取 \(items.count) 张照片…"
        let token = sessionToken
        // 带进来之后要排版的：读照片期间套了模板、撤销，读完就只进托盘、不再排（不能盖掉刚做的）。
        var ticket: SolveTicket?
        if case .solve = layout { ticket = beginSolve() }
        Task { [weak self] in
            let refs = await Task.detached(priority: .userInitiated) {
                items.compactMap(CollageBridge.ref(from:))
            }.value
            guard let self, self.sessionToken == token else { return }
            self.busyText = nil
            self.mergeIntoTray(refs)
            if case .solve(let ids) = layout, let ticket, ticket.generation == self.solveGeneration {
                self.isSolving = false
                self.solve(photoIDs: ids.filter { id in refs.contains { $0.id == id } })
            }
        }
    }

    func addFiles(_ urls: [URL]) {
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
        busyText = "分析 \(files.count) 张照片的人脸…"
        let token = sessionToken
        Task { [weak self] in
            let refs = await Task.detached(priority: .userInitiated) {
                files.compactMap(CollageBridge.ref(fromFile:))
            }.value
            guard let self, self.sessionToken == token else { return }
            self.busyText = nil
            self.mergeIntoTray(refs)
        }
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
        for i in project.pages.indices {
            var root = project.pages[i].root
            for path in root.leafPaths() where root.node(at: path)?.cell?.photoID == id {
                root.update(at: path) { $0.cell?.photoID = nil; $0.cell?.crop = nil }
            }
            project.pages[i].root = root
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
        pageIndex = 0
        clearAlternatives()
        albumDropped = []
        commitEdit()
    }

    private func computeHints(for photos: [CollagePhotoRef]) {
        let todo = photos.filter { hints[$0.id] == nil }
        guard !todo.isEmpty else { return }
        let previous = hintTask
        let token = sessionToken
        hintTask = Task { [weak self] in
            await previous?.value
            for p in todo {
                if Task.isCancelled { return }
                let h = await Task.detached(priority: .utility) { CollageVision.hints(for: p) }.value
                guard let self, self.sessionToken == token else { return }
                self.hints[p.id] = h
            }
            self?.hintsVersion += 1
            self?.setNeedsRender()
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
    func layoutFresh(photoIDs: [String]) {
        if effectiveLayoutStyle == .scatter, !isAlbum {
            scatter(photoIDs: photoIDs, spec: page?.scatter ?? CollageScatterSpec())
        } else {
            solve(photoIDs: photoIDs)
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
                p.gridRoot = page.root
                p.root = .leaf(CollageCell())
            } else if let grid = restoredGrid(from: page) {
                p.items = decorationsForGrid(from: page, consumed: consumedSourceItems(page))
                p.root = grid
                p.gridRoot = nil
            } else {
                // 记着的网格对不上了（照片全删了）：文字格回不去，那些字留成手写字。
                p.items = decorationsForGrid(from: page, consumed: [])
                p.root = .leaf(CollageCell(kind: .photo))
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
        let content = CollageLayout.contentRect(canvas: canvas, style: project.style)
        let gutter = CollageLayout.gutterPixels(canvas: canvas, style: project.style)
        let frames = CollageLayout.geometry(root, in: content, gutter: gutter).frames
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
    func solve(photoIDs: [String]) {
        let map = photoMap
        let photos = Self.unique(photoIDs).compactMap { map[$0] }
        guard !photos.isEmpty else { return }
        solveSeed &+= 1
        let texts = page.map { textCellsForGrid(from: $0) } ?? []
        runSolve(photos: photos, texts: texts, seed: solveSeed, replacePage: true)
    }

    /// 换一批：同一组照片、新的随机种子；有锁定的格子就只重排没锁的区域。
    func regenerate() {
        guard let root, let page else { return }
        if page.freeform {
            scatter(photoIDs: page.photoIDs, spec: page.scatter ?? CollageScatterSpec())
            return
        }
        solveSeed &+= 1
        let hasLocks = root.leaves.contains { $0.locked }
        if hasLocks {
            let ctx = context
            let seed = solveSeed
            let ticket = beginSolve()
            Task { [weak self] in
                let results = await Task.detached(priority: .userInitiated) {
                    CollageLayout.solveKeepingLocks(current: root, context: ctx, tries: 6000, keep: 16, seed: seed)
                }.value
                self?.finishSolve(ticket, results)
            }
        } else {
            let map = photoMap
            let photos = Self.unique(root.photoIDs).compactMap { map[$0] }
            let texts = root.leaves.filter { $0.kind == .text }
            runSolve(photos: photos, texts: texts, seed: solveSeed, replacePage: true)
        }
    }

    private func runSolve(photos: [CollagePhotoRef], texts: [CollageCell], seed: UInt64, replacePage: Bool) {
        let ctx = context
        let ticket = beginSolve()
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                CollageLayout.solve(CollageLayout.Request(photos: photos, textCells: texts, context: ctx,
                                                          tries: 16000, keep: 18, seed: seed))
            }.value
            self?.finishSolve(ticket, results)
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
        return SolveTicket(generation: solveGeneration, session: sessionToken, pageID: page?.id, recordUndo: recordUndo)
    }

    private func finishSolve(_ ticket: SolveTicket, _ results: [CollageLayout.Scored],
                             scatter: CollageScatterSpec? = nil) {
        guard ticket.generation == solveGeneration else { return }   // 更新的一次还在算
        isSolving = false
        guard ticket.session == sessionToken, ticket.pageID == page?.id else { return }
        adopt(results, scatter: scatter, recordUndo: ticket.recordUndo)
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
        let scale = min(1, 150 / Double(max(project.canvas.width, project.canvas.height)))
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

    // MARK: - 模板

    var allTemplates: [CollageTemplate] { CollageTemplates.builtin + userTemplates }

    /// 套模板：照片 = 当前页上的（不够就从托盘按分数补）。模板带的画布/样式一起换上。
    func applyTemplate(_ template: CollageTemplate) {
        var ids = Self.unique(page?.photoIDs ?? [])
        if ids.count < template.photoSlots {
            // 相册：别的跨页已经用了的不拿（同一张不能出现在两个跨页上）。
            let used = Set(ids).union(isAlbum ? usedPhotoIDs : [])
            let extra = project.photos.filter { !used.contains($0.id) }.sorted { $0.score > $1.score }
            ids += extra.prefix(template.photoSlots - ids.count).map(\.id)
        }
        let map = photoMap
        let photos = ids.compactMap { map[$0] }
        cancelPendingSolve()
        pushUndo()
        if let canvas = template.canvas, !isAlbum { project.canvas = canvas }
        // 相册的样式是整本共用的：套模板只换这一页的版式，不把其他跨页的底色、色调一起改了。
        if let style = template.style, !isAlbum { project.style = style }
        solveSeed &+= 1
        var newPage = CollageTemplates.apply(template, photos: photos, context: context, seed: solveSeed)
        newPage.id = page?.id ?? newPage.id
        setPage(newPage)
        if !isAlbum {
            layoutStyle = newPage.freeform ? .scatter : .grid
            scheduleStateSave()
        }
        clearAlternatives()
        selection = nil
        selectedItem = nil
        commitEdit()
        setNotice("已套用「\(template.name)」" + (isAlbum && template.style != nil ? "（相册里只换版式，样式整本统一）" : ""))
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
        setRoot(CollageLayout.remove(at: source, from: inserted))
        selection = nil
        commitEdit()
    }

    /// 托盘里的照片拖到格子上：中间 = 替换，边上 = 劈开插入。已经在版里的照片 = 挪过去。
    func place(photoID: String, at target: [Int], edge: CollageLayout.Edge?) {
        // 画布收的是纯文本拖放：别的 app 拖进来一段字不能当成照片 id。
        guard photoMap[photoID] != nil else { return }
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
            mutateRoot { _ in CollageNode.leaf(CollageCell(kind: .photo)) }
        } else {
            mutateRoot { CollageLayout.remove(at: path, from: $0) }
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
    }

    func setRatio(_ ratio: Double, at path: [Int]) {
        guard let root else { return }
        setRoot(CollageLayout.setRatio(ratio, at: path, in: root))
        scheduleProjectSave()
        setNeedsRender()
    }

    func endContinuousEdit() {
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
        }
    }

    func setShape(_ shape: CollageShape?) { updateSelectedCell { $0.shape = shape } }
    func setContain(_ on: Bool) { updateSelectedCell { $0.contain = on; if on { $0.crop = nil } } }
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
        case .overlay(let path, let photoID, let pageID):
            // 换一批之后压字跟着照片走了：路径上已经是另一张照片，迟到的提交不能写到它的字上。
            guard page?.id == pageID, let cell = root?.node(at: path)?.cell, cell.overlay != nil,
                  cell.photoID == photoID else { return }
            updateOverlay(at: path, coalesce: true) { $0.text = text }
        case .item(let id):
            guard page?.items.contains(where: { $0.id == id && $0.kind == .text }) == true else { return }
            updateItem(id, coalesce: true) { $0.text = text }
        }
    }

    // MARK: - 照片上的字

    func setOverlay(_ overlay: CollageOverlay?, at path: [Int]) {
        guard root?.node(at: path)?.cell?.kind == .photo else { return }
        mutateRoot { r in
            var out = r
            out.update(at: path) { $0.cell?.overlay = overlay }
            return out
        }
    }

    func updateOverlay(at path: [Int], coalesce: Bool = false, _ body: (inout CollageOverlay) -> Void) {
        guard let current = root?.node(at: path)?.cell?.overlay else { return }
        var overlay = current
        body(&overlay)
        // 点的是已经选中的那一项：不记空撤销、不清重做栈。
        guard overlay != current else { return }
        let updated = overlay
        mutateRoot(coalesce: coalesce) { r in
            var out = r
            out.update(at: path) { $0.cell?.overlay = updated }
            return out
        }
    }

    /// 拖字：开始记一次撤销（beginContinuousEdit），拖动中只改位置。
    func setOverlayPosition(x: Double, y: Double, at path: [Int]) {
        guard let root, var overlay = root.node(at: path)?.cell?.overlay else { return }
        // 第一次拖：把按位置定下的对齐（右上角 = 右对齐）存进字里，拖起来不会突然换对齐。
        if overlay.anchor != .custom, !overlay.text.vertical,
           let frame = geometry.frames.first(where: { $0.path == path }),
           let placed = overlayPlacement(for: frame) {
            overlay.text.alignH = placed.text.alignH
        }
        overlay.anchor = .custom
        overlay.x = min(1, max(0, x))
        overlay.y = min(1, max(0, y))
        var out = root
        out.update(at: path) { $0.cell?.overlay = overlay }
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
                : CollagePage(root: .leaf(CollageCell(kind: .photo)))]
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
        if kind == .label { item.label = "{date}" }
        let canvas = project.canvas
        if kind.isTape || kind == .clip, let anchor = selectedItemValue, anchor.kind == .photo {
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
        let band: Double = canvas.shortSide * 0.02
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
        mutateRoot { root in
            if target.isEmpty {
                let axis: CollageAxis = (edge == .left || edge == .right) ? .row : .column
                let newFirst = edge == .left || edge == .top
                let leaf = CollageNode.leaf(.text(text))
                let ratio = axis == .row ? (newFirst ? 0.22 : 0.78) : (newFirst ? 0.14 : 0.86)
                return newFirst ? .split(axis, ratio, leaf, root) : .split(axis, ratio, root, leaf)
            }
            return CollageLayout.insert(.text(text), at: target, edge: edge, into: root)
        }
    }

    /// `coalesce`：滑杆、取色器连续拖动合成一步；点色块、选预设、切开关每次一步。
    func setStyle(_ style: CollageStyle, coalesce: Bool = true) {
        guard style != project.style else { return }
        pushUndo(coalesce: coalesce)
        project.style = style
        // 下次新建拼图沿用：只在你改过之后才记（以前退出时把出厂值写回 state.json）。
        defaultStyle = style
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

    // MARK: - 相册

    func setMode(_ mode: CollageMode) {
        guard mode != project.mode else { return }
        cancelPendingSolve()
        pushUndo()
        let oldCanvas = project.canvas
        project.mode = mode
        if mode == .album {
            if project.canvas.seams != .fold { project.canvas = CollageCanvas.albums[0] }
        } else if project.canvas.seams == .fold {
            project.canvas = CollageCanvas.social[0]
            if project.pages.count > 1 {
                project.pages = [project.pages[min(pageIndex, project.pages.count - 1)]]
            }
            pageIndex = 0
        }
        refitFreeformPages(from: oldCanvas)
        clearAlternatives()
        selection = nil
        commitEdit()
        // 散落页换到相册跨页（有中缝）或从跨页换回单张：按新画布重新撒一版，和切模式算同一步撤销
        // （等比缩放只是先顶着：单张的摆法缩进跨页正好横在中缝上）。
        if oldCanvas != project.canvas, let page, page.freeform, !page.photoIDs.isEmpty {
            scatter(photoIDs: page.photoIDs, spec: page.scatter ?? CollageScatterSpec(), recordUndo: false)
        }
    }

    /// 托盘里的全部照片自动编排成相册（去重可关）。
    func autoArrangeAlbum(dedupe: Bool) {
        let photos = project.photos
        guard !photos.isEmpty else {
            setNotice("托盘是空的：先带精选进来")
            return
        }
        let ctx = context
        busyText = "编排相册…"
        // 编排也在作废机制里：编排期间切回单张、撤销、套模板，结果回来不能盖掉。
        let ticket = beginSolve()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([CollagePage], [CollagePhotoRef]) in
                let plan = CollageAlbum.plan(photos, dedupe: dedupe)
                return (CollageAlbum.build(plan, context: ctx, seed: 11), plan.dropped)
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
            self.setNotice("编排好 \(result.0.count) 个跨页" + (result.1.isEmpty ? "" : "，相似的拿掉 \(result.1.count) 张（可在托盘里拖回）"))
        }
    }

    func addPage() {
        pushUndo()
        let blank = CollagePage(root: CollageNode.leaf(CollageCell(kind: .photo)))
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
            project.pages[pageIndex].root = root.isLeaf ? CollageNode.leaf(CollageCell(kind: .photo))
                                                        : CollageLayout.remove(at: selection, from: root)
            self.selection = nil
            commitEdit()
            setNotice("已移到第 \(target + 1) 个跨页（放在照片少的那半页，拖到想要的位置）")
            return
        }
        let targetRoot = project.pages[target].root
        let content = CollageLayout.contentRect(canvas: project.canvas, style: project.style)
        let gutter = CollageLayout.gutterPixels(canvas: project.canvas, style: project.style)
        let frames = CollageLayout.geometry(targetRoot, in: content, gutter: gutter).frames
        let newTarget: CollageNode
        if targetRoot.isLeaf, targetRoot.cell?.kind != .text, targetRoot.cell?.photoID == nil {
            newTarget = .leaf(moved)
        } else {
            let photoFrames = frames.filter { $0.cell.kind != .text }
            guard let anchor = (photoFrames.isEmpty ? frames : photoFrames).max(by: { $0.rect.area < $1.rect.area }) else { return }
            let edge: CollageLayout.Edge = anchor.rect.aspect >= 1 ? .right : .bottom
            newTarget = CollageLayout.insert(moved, at: anchor.path, edge: edge, into: targetRoot)
        }
        pushUndo()
        project.pages[target].root = newTarget
        project.pages[pageIndex].root = root.isLeaf ? CollageNode.leaf(CollageCell(kind: .photo))
                                                    : CollageLayout.remove(at: selection, from: root)
        self.selection = nil
        commitEdit()
        setNotice("已移到第 \(target + 1) 个跨页（插在最大那张旁边，想重排点「换一批」）")
    }

    // MARK: - 色调样张

    /// 这一页分数最高的照片（没有就托盘里最高的）套每个色调，方形小图。
    func renderLookThumbs() {
        let map = photoMap
        let pool = (page?.photoIDs ?? []).compactMap { map[$0] }
        guard let hero = (pool.isEmpty ? project.photos : pool).max(by: { $0.score < $1.score }) else { return }
        let key = sessionToken.uuidString + hero.id
        guard key != lookThumbKey else { return }
        lookThumbKey = key
        var base = project
        base.canvas = CollageCanvas(name: "look", width: 240, height: 240)
        base.style = CollageStyle()
        base.style.margin = 0
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
        // 按照片集合认（换一批、置顶只改顺序，不用整批重渲）。
        let photoKey = photos.map(\.id).sorted().joined(separator: ",") + "|\(hintsVersion)|\(album)"
        let styleKey = "|s\(project.style.hashValue)"
        let canvasKey = "|c\(project.canvas.hashValue)"
        var todo: [(CollageTemplate, String)] = []
        for t in templates {
            var key = photoKey + "|\(t.hashValue)"
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
                let thumb = await Task.detached(priority: .utility) { () -> NSImage? in
                    Self.templateThumb(template, base: base, photos: photos, hints: hints, album: album)
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
                                                  hints: [String: CollageCrop.Hints], album: Bool) -> NSImage? {
        var project = base
        if !album {
            if let s = template.style { project.style = s }
            if let c = template.canvas { project.canvas = c }
        }
        var map: [String: CollagePhotoRef] = [:]
        for p in project.photos { map[p.id] = p }
        let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map, hints: hints, heroID: nil)
        let page = CollageTemplates.apply(template, photos: Array(photos.prefix(max(1, template.photoSlots))),
                                          context: ctx, seed: 7)
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
        let now = Date()
        if coalesce, lastPushCoalesced, now.timeIntervalSince(lastUndoPush) < 0.6 {
            lastUndoPush = now
            return
        }
        lastPushCoalesced = coalesce
        lastUndoPush = now
        undoStack.append(project)
        if undoStack.count > 120 { undoStack.removeFirst(undoStack.count - 120) }
        redoStack.removeAll()
        updateUndoFlags()
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
        if let s = selection, isFreeform || root?.node(at: s)?.isLeaf != true {
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
        guard isAlbum else {
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
        let stamp = Self.stampFormatter.string(from: Date())
        let base = (project.title.isEmpty ? (isAlbum ? "相册" : "拼图") : project.title)
            .filter { $0 != "/" && $0 != ":" }
        let dir = folder.appendingPathComponent("\(base)_\(stamp)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            lastError = "无法创建输出目录: \(error.localizedDescription)"
            return
        }
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
            for (i, page) in snapshot.pages.enumerated() {
                if self?.exportCancelled ?? true { break }
                let result = await Task.detached(priority: .userInitiated) { () -> PageResult in
                    var opts = CollageRender.Options(scale: 1)
                    opts.export = true
                    opts.includeBleed = true
                    let report = CollageRender.RenderReport()
                    opts.report = report
                    guard let image = CollageRender.render(page: page, project: snapshot, hints: hints, options: opts) else {
                        return PageResult(pdfData: nil, error: "第 \(i + 1) 页渲染失败", lowRes: [], missing: [])
                    }
                    do {
                        let data = try Self.writePage(image, index: i, count: snapshot.pages.count, project: snapshot,
                                                      options: options, dir: dir, wantPDF: wantPDF)
                        return PageResult(pdfData: data, error: nil, lowRes: report.lowRes, missing: report.missing)
                    } catch {
                        return PageResult(pdfData: nil, error: error.localizedDescription, lowRes: [], missing: [])
                    }
                }.value
                if let data = result.pdfData { pdfPages.append(data) }
                if let f = result.error, failure == nil { failure = f }
                lowRes += result.lowRes
                missing += result.missing
                guard let self else { return }
                self.progressFraction = Double(i + 1) / Double(snapshot.pages.count)
                self.progressText = "导出 \(i + 1)/\(snapshot.pages.count)…"
            }
            if wantPDF, !pdfPages.isEmpty, !(self?.exportCancelled ?? true) {
                self?.progressText = "生成 PDF…"
                let pdfURL = dir.appendingPathComponent("\(base).pdf")
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
                self.progressText = "导出完成 → \(dir.lastPathComponent)"
                AppRuntime.revealInFinder([dir])
            }
            // 成品里有退化的格子：说清楚是哪几张（导出本身不算失败）。
            if !missing.isEmpty {
                self.lastError = "\(Set(missing).count) 张照片读不了，格子空着：" + Set(missing).sorted().prefix(4).joined(separator: " ")
            } else if !lowRes.isEmpty {
                self.lastError = "\(Set(lowRes).count) 张原图读不了，用了 1024 预览（印刷会糊）：" + Set(lowRes).sorted().prefix(4).joined(separator: " ")
            }
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        exportCancelled = true
        progressText = "正在取消…"
    }

    /// 固定格式必须钉 en_US_POSIX：系统偏好 12 小时制时，"HH" 会被换成「上午9」，
    /// 文件夹名就成了「春日宴_20260928-上午90228」。
    private static let stampFormatter: DateFormatter = {
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
    }

    /// 一页落盘：单张按画布切缝写九宫格/轮播；相册每个跨页一张（带出血）。
    /// `wantPDF` 时返回这一页进 PDF 用的 JPEG 数据（JPEG 格式就是写盘的同一份）。
    nonisolated private static func writePage(_ image: CGImage, index: Int, count: Int, project: CollageProject,
                                              options: ExportOptions, dir: URL, wantPDF: Bool) throws -> Data? {
        let canvas = project.canvas
        let ext = options.format.ext
        if project.mode == .album {
            let url = dir.appendingPathComponent(String(format: "跨页_%02d.%@", index + 1, ext))
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
        let name = count > 1 ? String(format: "拼图_%02d", index + 1) : "拼图"
        let trimmed = CollageExport.trimmed(image, bleed: canvas.bleed) ?? image
        try CollageExport.write(image, to: dir.appendingPathComponent("\(name).\(ext)"), format: options.format,
                                quality: options.quality, dpi: canvas.dpi)
        switch canvas.seams {
        case .grid9:
            for (i, tile) in CollageExport.split(trimmed, rows: 3, cols: 3).enumerated() {
                try CollageExport.write(tile, to: dir.appendingPathComponent("\(name)_九宫格_\(i + 1).\(ext)"),
                                        format: options.format, quality: options.quality, dpi: canvas.dpi)
            }
        case .carousel:
            for (i, tile) in CollageExport.split(trimmed, rows: 1, cols: max(1, canvas.slides)).enumerated() {
                try CollageExport.write(tile, to: dir.appendingPathComponent("\(name)_轮播_\(i + 1).\(ext)"),
                                        format: options.format, quality: options.quality, dpi: canvas.dpi)
            }
        default:
            break
        }
        return nil
    }

    // MARK: - 提示

    func setNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
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

/// 文字编辑器写回哪里：文字格、照片上的字、自由图层里的字。
enum CollageTextTarget: Hashable {
    /// 路径 + 所在页（相册切了跨页，迟到的提交不认）。
    case cell([Int], UUID?)
    /// 路径 + 那一格当时的照片 + 所在页（换一批后路径上换了照片就不认）。
    case overlay([Int], String?, UUID?)
    case item(UUID)
}
