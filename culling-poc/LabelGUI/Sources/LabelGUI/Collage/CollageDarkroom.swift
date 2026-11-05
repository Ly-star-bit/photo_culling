import Foundation
import AppKit
import Combine

/// 拼图的「暗房」：整页的看片 / 印放工作台（色调面板「进暗房…」打开，Esc /「完成」退出；视图见
/// CollageDarkroomView.swift）。左边看片台按片种排每个色调的样张，中间大预览（拖竖线对比原图、按住空格看原图），
/// 右边印放（强度试条、统一色温）、质感（颗粒、晕光）、1:1 放大镜，底下是这一页的底片条。
///
/// 规则（selftest --darkroom-selftest 一条条核对）：
/// - 悬停 / ←→ 只是预览：只渲大预览，不碰 store.project、不进撤销。
/// - 点一下 / ⏎ = 一步撤销，落在「套用到」选的那一级（整组 = 工程样式，这一页 = 页级色调，这一格 = 格级色调），
///   走 store 现成的 setStyle / setPageLook / setCellLook。
/// - 强度滑杆、试条：同一级上改强度，滑杆连拖合成一步。这一页 / 这一格还没有自己的色调时拖强度 = 用现在看到的
///   色调 + 新强度给这一级设上。
/// - 颗粒、晕光、统一色温永远是整组的（工程样式），和「套用到」无关。
/// - 「这一页」只在相册里有（单张拼图只有一页，整组就是这一页）；「这一格」要选中一格照片（点底下的底片条）。
///   撤销会清掉选中，这时「这一格」退回上一级。
///
/// 原图（对比用）= 色调原色、页 / 格不设色调、颗粒晕光 0、统一色温 0 —— 别的（边距、边框、字、水印）都照旧：比的是
/// 「进暗房前 / 后」，不是「照片 / 拼图」。
@MainActor
final class CollageDarkroom: ObservableObject {

    enum Scope: String, CaseIterable, Identifiable {
        case project, page, cell
        var id: String { rawValue }
        var label: String {
            switch self {
            case .project: return "整组"
            case .page: return "这一页"
            case .cell: return "这一格"
            }
        }
    }

    /// 看片台上的一组：负片画成 135 底片条，反转片装片框，电影负片是方齿孔 + 声带，滤镜是普通方块（不是胶片，
    /// 没有颗粒、晕光，也就不穿底片的外衣）。
    enum Kind { case negative, slide, cine, filter }

    struct Group: Identifiable {
        let title: String
        let kind: Kind
        let looks: [CollageLook]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "负片", kind: .negative,
              looks: [.filmSoftSkin, .filmWarmSkin, .filmRich, .filmSunny, .filmFresh, .filmPastel]),
        Group(title: "反转片", kind: .slide, looks: [.slideVivid, .slideClean, .slideVintage]),
        Group(title: "电影负片", kind: .cine, looks: [.cineDay]),
        Group(title: "滤镜", kind: .filter, looks: CollageLook.allCases.filter { !$0.isSpectral }),
    ]

    /// 看片台上的先后（←→ 按这个走）。
    static let order: [CollageLook] = groups.flatMap(\.looks)

    /// 片边的帧号：光谱胶片按看片台的先后 1…10；滤镜不是底片，没有帧号。
    static func frameNumber(_ look: CollageLook) -> Int? {
        guard look.isSpectral else { return nil }
        return order.filter(\.isSpectral).firstIndex(of: look).map { $0 + 1 }
    }

    /// 片边字：▶帧号 + 色调名，只此而已。商标红线（reports/胶片模拟调研_2026-11-05/R7）：不印 ISO、型号、
    /// 品牌 —— 160 / 400 这类数字会把烘焙脚本里「哪款对哪支胶片」从界面上漏出去。
    static func edgeText(_ look: CollageLook) -> String {
        guard let n = frameNumber(look) else { return look.label }
        return "▶\(n) \(look.label)"
    }

    /// 片边上的通用字（和印样模板一样，CollageStyleFilm.swift）。
    static let rebateText = "SAFETY FILM"

    static func kind(of look: CollageLook) -> Kind {
        groups.first { $0.looks.contains(look) }?.kind ?? .filter
    }

    static func kindLabel(_ look: CollageLook) -> String {
        switch kind(of: look) {
        case .negative: return "负片"
        case .slide: return "反转片"
        case .cine: return "电影负片"
        case .filter: return "滤镜"
        }
    }

    // MARK: - 状态

    unowned let store: CollageStore
    /// false = 只有状态、不渲染（自检用）。
    let rendering: Bool

    /// 「套用到」：用户选的那一级。实际生效的看 effectiveScope（选中没了就退回上一级）。
    @Published var scope: Scope = .project { didSet { if scope != oldValue { refresh() } } }
    /// 悬停 / ←→ 正在看的色调（只预览，不套用）。
    @Published var hover: CollageLook? { didSet { if hover != oldValue { hoverChanged() } } }
    /// 键盘焦点（←→ 走、⏎ 套用）。
    @Published var focus: CollageLook = .none
    /// 对比竖线的位置：左边这一截看原图（0 = 全是成片）。
    @Published var split = 0.5
    /// 按住空格：整张看原图。
    @Published var showOriginal = false
    /// 1:1 放大镜看哪儿（画布像素坐标，左上原点）；nil = 主图那一格的中心。
    @Published var loupeAnchor: CGPoint? { didSet { scheduleLoupe() } }

    @Published private(set) var frames: [CollageLook: NSImage] = [:]
    @Published private(set) var processed: NSImage?
    @Published private(set) var original: NSImage?
    /// 强度试条：0 / 25 / 50 / 75 / 100%。
    @Published private(set) var testStrip: [NSImage] = []
    static let stripSteps: [Double] = [0, 0.25, 0.5, 0.75, 1]
    @Published private(set) var loupe: NSImage?
    /// 放大镜正在重渲（界面上把旧的压暗一点）。
    @Published private(set) var loupeStale = false
    struct ReelFrame: Identifiable, Hashable {
        let path: [Int]
        let photoID: String
        let image: NSImage?
        var id: [Int] { path }
    }
    /// 底下的底片条：这一页每一格照片，套着它自己现在的色调。
    @Published private(set) var reel: [ReelFrame] = []
    /// 有渲染在跑（快照等它）。
    @Published private(set) var busy = false

    /// 大预览可用的像素（视图按自己的尺寸 × 屏幕倍率填）。
    var previewPixels = CGSize(width: 1600, height: 1100) {
        didSet {
            if abs(previewPixels.width - oldValue.width) > 8 || abs(previewPixels.height - oldValue.height) > 8 {
                schedulePreview()
            }
        }
    }

    private var watch: AnyCancellable?

    init(store: CollageStore, rendering: Bool = true) {
        self.store = store
        self.rendering = rendering
        watch = store.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        focus = current.look
        refresh()
    }

    func stop() {
        watch = nil
        loupeTimer?.invalidate()
        loupeTimer = nil
        laneKey.removeAll()
        laneJob.removeAll()
    }

    // MARK: - 哪一级

    var pageAvailable: Bool { store.isAlbum && store.page != nil }
    var cellAvailable: Bool { store.selectedCell?.kind == .photo && store.selectedCell?.photoID != nil }

    var effectiveScope: Scope {
        switch scope {
        case .cell where cellAvailable: return .cell
        case .cell, .page: return pageAvailable ? .page : .project
        case .project: return .project
        }
    }

    func setting(_ s: Scope) -> CollageLookSetting {
        let style = store.project.style
        let projectSetting = CollageLookSetting(look: style.look, strength: style.lookStrength)
        let pageSetting = store.page?.look ?? projectSetting
        switch s {
        case .project: return projectSetting
        case .page: return pageSetting
        case .cell: return store.selectedCell?.look ?? pageSetting
        }
    }

    /// 「套用到」那一级现在看到的色调和强度（没自己设 = 跟着上一级的那份）。
    var current: CollageLookSetting { setting(effectiveScope) }

    /// 这一级自己设了色调（不是跟着上一级）。整组永远是自己的。
    var ownsSetting: Bool {
        switch effectiveScope {
        case .project: return true
        case .page: return store.page?.look != nil
        case .cell: return store.selectedCell?.look != nil
        }
    }

    /// 选「整组」时这一页 / 这一格自己设了别的色调：整组改了，这里看不出来（界面上提醒一句）。
    var overriddenBelow: String? {
        guard effectiveScope == .project else { return nil }
        if store.page?.look != nil { return "这一页单独设了色调「\(store.page!.look!.look.label)」：整组改了，这一页看不出来" }
        if store.selectedCell?.look != nil { return "选中的这一格单独设了色调：整组改了，这一格看不出来" }
        return nil
    }

    // MARK: - 操作（都是 store 现成的方法，一次一步撤销）

    func apply(_ look: CollageLook) {
        let strength = current.strength
        switch effectiveScope {
        case .project:
            var st = store.project.style
            st.look = look
            store.setStyle(st, coalesce: false)
        case .page:
            store.setPageLook(CollageLookSetting(look: look, strength: strength))
        case .cell:
            store.setCellLook(CollageLookSetting(look: look, strength: strength))
        }
        focus = look
        hover = nil
    }

    /// 强度：同一级上改；这一页 / 这一格还没有自己的色调时，用现在看到的色调 + 新强度给它设上。
    /// 已经有的就只改强度（模板带的 fromTemplate 留着：换模板时它照旧不跟着照片走）。
    func setStrength(_ value: Double, coalesce: Bool = true) {
        let v = min(1, max(0, value))
        switch effectiveScope {
        case .project:
            var st = store.project.style
            st.lookStrength = v
            store.setStyle(st, coalesce: coalesce)
        case .page:
            var s = store.page?.look ?? CollageLookSetting(look: current.look, strength: v)
            s.strength = v
            store.setPageLook(s, coalesce: coalesce)
        case .cell:
            var s = store.selectedCell?.look ?? CollageLookSetting(look: current.look, strength: v)
            s.strength = v
            store.setCellLook(s, coalesce: coalesce)
        }
    }

    /// 这一页 / 这一格不再单独设色调，跟着上一级。
    func followParent() {
        switch effectiveScope {
        case .project: return
        case .page: store.setPageLook(nil)
        case .cell: store.setCellLook(nil)
        }
    }

    /// 颗粒、晕光、统一色温：整组的。
    func setStyleValue(_ keyPath: WritableKeyPath<CollageStyle, Double>, _ value: Double) {
        var st = store.project.style
        st[keyPath: keyPath] = min(1, max(0, value))
        store.setStyle(st, coalesce: true)
    }

    /// ←→：在看片台上挪焦点，大预览跟着看（不套用）。到头绕回。
    func moveFocus(_ delta: Int) {
        let list = Self.order
        let i = list.firstIndex(of: hover ?? focus) ?? 0
        let next = list[((i + delta) % list.count + list.count) % list.count]
        focus = next
        hover = next
    }

    /// 底片条上点一格：选中它，「套用到」换成这一格，放大镜挪过去。
    func selectCell(_ path: [Int]) {
        store.selection = path
        scope = .cell
        loupeAnchor = nil
        refresh()
    }

    // MARK: - 预览要的工程（纯函数，自检直接测）

    /// 把 setting 套到 scope 那一级上（不进撤销，只给渲染用）。
    nonisolated static func project(_ p: CollageProject, pageIndex: Int, selection: [Int]?, scope: Scope,
                                    setting: CollageLookSetting) -> CollageProject {
        var out = p
        switch scope {
        case .project:
            out.style.look = setting.look
            out.style.lookStrength = setting.strength
        case .page:
            guard out.pages.indices.contains(pageIndex) else { return out }
            out.pages[pageIndex].look = setting
        case .cell:
            guard out.pages.indices.contains(pageIndex), let selection else { return out }
            out.pages[pageIndex].root.update(at: selection) { node in node.cell?.look = setting }
        }
        // 套用时会带上的颗粒 / 晕光起始值，预览里也带上（看到的就是点下去的）。
        CollageFilmEffects.adoptDefaults(before: p, into: &out, look: setting.look)
        return out
    }

    /// 原图：整组 / 这一页 / 每一格都不调色，颗粒晕光、统一色温都关掉；版式、字、水印照旧。
    nonisolated static func original(_ p: CollageProject, pageIndex: Int) -> CollageProject {
        var out = p
        out.style.look = .none
        out.style.harmonize = 0
        out.style.filmGrain = 0
        out.style.filmHalation = 0
        guard out.pages.indices.contains(pageIndex) else { return out }
        out.pages[pageIndex].look = nil
        for path in out.pages[pageIndex].root.leafPaths() {
            out.pages[pageIndex].root.update(at: path) { node in node.cell?.look = nil }
        }
        return out
    }

    /// 大预览要渲的工程：悬停时把悬停的色调套到这一级上，否则就是 store 里的。
    var previewProject: CollageProject {
        guard let hover else { return store.project }
        return Self.project(store.project, pageIndex: store.pageIndex, selection: store.selection,
                            scope: effectiveScope, setting: CollageLookSetting(look: hover, strength: current.strength))
    }

    /// 样张、试条用哪张照片：这一格就是这一格的，否则这一页的主图。
    var subjectPhotoID: String? {
        if effectiveScope == .cell, let id = store.selectedCell?.photoID { return id }
        let ids = store.page?.root.photoIDs ?? []
        return CollageRender.heroPhoto(ids.isEmpty ? store.project.photos.map(\.id) : ids, photos: store.photoMap)?.id
    }

    /// 放大镜的中心（画布像素）：点过预览就用点的地方，否则选中那一格 / 主图那一格的中心。
    var loupeCenter: CGPoint {
        if let loupeAnchor { return loupeAnchor }
        let frames = store.geometry.frames
        let target = (effectiveScope == .cell ? store.selection : nil)
            ?? frames.first { $0.cell.photoID == subjectPhotoID }?.path
        if let f = frames.first(where: { $0.path == target }) {
            return CGPoint(x: Double(f.rect.x0 + f.rect.x1) / 2, y: Double(f.rect.y0 + f.rect.y1) / 2)
        }
        return CGPoint(x: Double(store.project.canvas.width) / 2, y: Double(store.project.canvas.height) / 2)
    }

    // MARK: - 渲染（每一类只渲最新的那一次：跑着的时候来了新的，跑完接着渲最新的）

    private var laneKey: [String: String] = [:]
    private var laneJob: [String: @MainActor () async -> Void] = [:]
    private var laneRunning: Set<String> = []
    private var loupeTimer: Timer?

    private func submit(_ lane: String, key: String, _ job: @escaping @MainActor () async -> Void) {
        guard rendering, laneKey[lane] != key else { return }
        laneKey[lane] = key
        laneJob[lane] = job
        pump(lane)
    }

    private func pump(_ lane: String) {
        guard !laneRunning.contains(lane), let job = laneJob.removeValue(forKey: lane) else {
            updateBusy()
            return
        }
        laneRunning.insert(lane)
        updateBusy()
        Task { @MainActor [weak self] in
            await job()
            guard let self else { return }
            self.laneRunning.remove(lane)
            self.pump(lane)
        }
    }

    private func updateBusy() {
        let now = !laneRunning.isEmpty || !laneJob.isEmpty || loupeTimer != nil
        if busy != now { busy = now }
    }

    private func current(_ lane: String, _ key: String) -> Bool { laneKey[lane] == key }

    /// store 变了（套用、撤销、换页、选中、托盘……）：每一类按自己的 key 看要不要重渲。
    func refresh() {
        guard rendering else { return }
        if store.selection == nil && scope == .cell { objectWillChange.send() }
        schedulePreview()
        scheduleOriginal()
        scheduleFrames()
        scheduleStrip()
        scheduleReel()
        scheduleLoupe()
    }

    private func hoverChanged() {
        // 悬停只换大预览和试条（一帧以内）；样张、底片条不动，放大镜等停下来再渲。
        schedulePreview()
        scheduleStrip()
        scheduleLoupe()
    }

    private var previewScale: Double {
        let c = store.project.canvas
        let sx = Double(previewPixels.width) / Double(max(1, c.width))
        let sy = Double(previewPixels.height) / Double(max(1, c.height))
        return max(0.05, min(1, min(sx, sy)))
    }

    private func schedulePreview() {
        guard let page = store.page else { return }
        let project = previewProject
        let scale = previewScale
        let hints = store.hints
        let key = CollageStore.editDigest(project) + "|\(store.pageIndex)|\(scale)|\(hints.count)"
        let pageIndex = store.pageIndex
        submit("preview", key: key) { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.renderPage(project, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale)
            }.value
            guard let self, self.current("preview", key) else { return }
            self.processed = image
        }
    }

    private func scheduleOriginal() {
        guard let page = store.page else { return }
        let project = Self.original(store.project, pageIndex: store.pageIndex)
        let scale = previewScale
        let hints = store.hints
        let pageIndex = store.pageIndex
        let key = CollageStore.editDigest(project) + "|\(pageIndex)|\(scale)|\(hints.count)"
        submit("original", key: key) { [weak self] in
            let image = await Task.detached(priority: .utility) {
                Self.renderPage(project, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale)
            }.value
            guard let self, self.current("original", key) else { return }
            self.original = image
        }
    }

    private func scheduleFrames() {
        guard let id = subjectPhotoID else { return }
        let base = store.project
        let hints = store.hints
        let strength = current.strength
        let key = "\(id)|\(Int((strength * 20).rounded()))|\(base.style.halftone.map { "\($0)" } ?? "")|\(hints[id] != nil)"
        submit("frames", key: key) { [weak self] in
            let images = await Task.detached(priority: .utility) { () -> [CollageLook: NSImage] in
                var out: [CollageLook: NSImage] = [:]
                for look in Self.order {
                    out[look] = Self.sample(id, base: base, hints: hints, look: look, strength: strength,
                                            width: 330, height: 220)
                }
                return out
            }.value
            guard let self, self.current("frames", key) else { return }
            self.frames = images
        }
    }

    private func scheduleStrip() {
        guard let id = subjectPhotoID else { return }
        let base = store.project
        let hints = store.hints
        let look = hover ?? current.look
        let key = "\(id)|\(look.rawValue)|\(hints[id] != nil)"
        submit("strip", key: key) { [weak self] in
            let images = await Task.detached(priority: .utility) { () -> [NSImage] in
                Self.stripSteps.compactMap { s in
                    Self.sample(id, base: base, hints: hints, look: look, strength: s, width: 150, height: 100)
                }
            }.value
            guard let self, self.current("strip", key) else { return }
            self.testStrip = images
        }
    }

    private func scheduleReel() {
        let project = store.project
        let pageIndex = store.pageIndex
        let hints = store.hints
        let cells = store.geometry.frames.filter { $0.cell.kind == .photo && $0.cell.photoID != nil }
        let key = CollageStore.editDigest(project) + "|\(pageIndex)|\(hints.count)"
        submit("reel", key: key) { [weak self] in
            let reel = await Task.detached(priority: .utility) { () -> [ReelFrame] in
                let page = project.pages.indices.contains(pageIndex) ? project.pages[pageIndex] : nil
                return cells.map { f in
                    let id = f.cell.photoID ?? ""
                    let setting = f.cell.look ?? page?.look
                        ?? CollageLookSetting(look: project.style.look, strength: project.style.lookStrength)
                    let image = Self.sample(id, base: project, hints: hints, look: setting.look,
                                            strength: setting.strength, width: 180, height: 120)
                    return ReelFrame(path: f.path, photoID: id, image: image)
                }
            }.value
            guard let self, self.current("reel", key) else { return }
            self.reel = reel
        }
    }

    /// 放大镜是导出尺寸的整页渲染（印刷画布有八百多万像素）：停手 0.35 秒以后再渲，渲的时候旧图压暗。
    private func scheduleLoupe() {
        guard rendering else { return }
        loupeTimer?.invalidate()
        loupeTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loupeTimer = nil
                self.startLoupe()
            }
        }
        updateBusy()
    }

    private func startLoupe() {
        guard let page = store.page else { updateBusy(); return }
        let project = previewProject
        let hints = store.hints
        let pageIndex = store.pageIndex
        let scale = Double(CollageStore.exportScale(canvas: project.canvas, options: store.exportOptions))
        let center = loupeCenter
        let key = CollageStore.editDigest(project) + "|\(pageIndex)|\(scale)|\(Int(center.x)),\(Int(center.y))|\(hints.count)"
        if laneKey["loupe"] != key { loupeStale = loupe != nil }
        submit("loupe", key: key) { [weak self] in
            let image = await Task.detached(priority: .utility) {
                Self.renderLoupe(project, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale, center: center)
            }.value
            guard let self, self.current("loupe", key) else { return }
            self.loupe = image
            self.loupeStale = false
        }
        updateBusy()
    }

    // MARK: - 渲染函数（后台跑）

    nonisolated static func renderPage(_ project: CollageProject, pageIndex: Int, fallback: CollagePage,
                                       hints: [String: CollageCrop.Hints], scale: Double) -> NSImage? {
        let page = project.pages.indices.contains(pageIndex) ? project.pages[pageIndex] : fallback
        var opts = CollageRender.Options(scale: scale)
        opts.includeBleed = false
        opts.watermark = true
        guard let cg = CollageRender.render(page: page, project: project, hints: hints, options: opts) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 一张照片的样张（3:2，满版，不要边距、底色、水印），套 look / strength。和色调面板的样张同一条路，只是横的。
    nonisolated static func sample(_ photoID: String, base: CollageProject, hints: [String: CollageCrop.Hints],
                                   look: CollageLook, strength: Double, width: Int, height: Int) -> NSImage? {
        var p = base
        p.canvas = CollageCanvas(name: "darkroom", width: width, height: height)
        var style = CollageStyle()
        style.margin = 0
        style.look = look
        style.lookStrength = strength
        if var h = base.style.halftone {
            h.paper = CollageScreening.paper(h, background: base.style.background)
            h.pitch = 0.001
            style.halftone = h
        }
        p.style = style
        let page = CollagePage(root: .leaf(.photo(photoID)))
        p.pages = [page]
        var opts = CollageRender.Options(scale: 1)
        opts.includeBleed = false
        guard let cg = CollageRender.render(page: page, project: p, hints: hints, options: opts) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 放大镜：导出尺寸（原图解码、导出倍数）渲整页，裁中心附近 side × side 像素（1 个导出像素 = 1 pt）。
    static let loupeSide = 232
    nonisolated static func renderLoupe(_ project: CollageProject, pageIndex: Int, fallback: CollagePage,
                                        hints: [String: CollageCrop.Hints], scale: Double, center: CGPoint) -> NSImage? {
        let page = project.pages.indices.contains(pageIndex) ? project.pages[pageIndex] : fallback
        var opts = CollageRender.Options(scale: scale)
        opts.includeBleed = false
        opts.export = true
        opts.watermark = true
        guard let cg = CollageRender.render(page: page, project: project, hints: hints, options: opts) else { return nil }
        let side = min(loupeSide, cg.width, cg.height)
        let cx = Int((center.x * scale).rounded()), cy = Int((center.y * scale).rounded())
        let x = min(max(0, cx - side / 2), cg.width - side)
        let y = min(max(0, cy - side / 2), cg.height - side)
        guard let crop = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: side, height: side))
    }
}
