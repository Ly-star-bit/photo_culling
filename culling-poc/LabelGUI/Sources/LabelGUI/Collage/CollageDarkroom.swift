import Foundation
import AppKit
import Combine

/// 拼图的「暗房」：整页的看片 / 印放工作台（色调面板「进暗房…」打开，Esc /「完成」退出；视图见
/// CollageDarkroomView.swift）。左边样张（页签分胶片 / 滤镜，胶片按片种分节），中间大预览（拖竖线对比原图、按住
/// 空格看原图），右边强度试条、统一色温、颗粒、晕光、1:1 细节，底下是这一页的小样。
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

    /// 样张的一组：负片、反转片、电影负片（光谱胶片，有颗粒晕光）和滤镜（程序调色，没有）。
    enum Kind { case negative, slide, cine, filter }

    struct Group: Identifiable {
        let title: String
        let kind: Kind
        let looks: [CollageLook]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "负片", kind: .negative,
              looks: [.filmSoftSkin, .filmWarmSkin, .filmRich, .filmSunny, .filmAmber, .filmFresh, .filmPastel,
                      .filmEveryday, .filmPushed]),
        Group(title: "反转片", kind: .slide, looks: [.slideVivid, .slideClean, .slideCool, .slideVintage]),
        Group(title: "电影负片", kind: .cine, looks: [.cineDay, .cineTungsten]),
        Group(title: "滤镜", kind: .filter, looks: CollageLook.allCases.filter { !$0.isSpectral }),
    ]

    /// 全部色调的先后。
    static let order: [CollageLook] = groups.flatMap(\.looks)

    /// 样张的两个页签：胶片（光谱色调）/ 滤镜（程序调色）。先少给选择（R8 §3.2），←→ 只在这一页签里走。
    enum Tab: String, CaseIterable, Identifiable {
        case film, filter
        var id: String { rawValue }
        var label: String { self == .film ? "胶片" : "滤镜" }
        /// 样张一行几张（↑↓ 跳一行）。
        var columns: Int { self == .film ? 2 : 3 }
    }

    static func tab(of look: CollageLook) -> Tab { look.isSpectral ? .film : .filter }

    static func looks(in tab: Tab) -> [CollageLook] {
        groups.filter { ($0.kind == .filter) == (tab == .filter) }.flatMap(\.looks)
    }

    /// 一句用途：只讲味道，不写片种、型号、ISO。用了哪支胶片的数据另写在「参考：…」那一行
    /// （CollageLook.referenceStock，用户 2026-11-05 定的：片名只进说明、配免责声明，不当色调名）。
    static func blurb(_ look: CollageLook) -> String {
        switch look {
        case .filmSoftSkin: return "低反差、奶油白，皮肤透粉"
        case .filmWarmSkin: return "金色皮肤、冷影，干净的暖"
        case .filmRich: return "浓而不艳，饱和色往深里走"
        case .filmSunny: return "最暖的一款，日光金黄"
        case .filmFresh: return "偏青绿的日系，清透"
        case .filmPastel: return "过曝的粉彩，黑位抬起"
        case .slideVivid: return "风景用的高饱和"
        case .slideClean: return "最中性、最干净"
        case .slideVintage: return "红暖蓝深，反差足"
        case .cineDay: return "暗部青、肤色暖的电影感"
        case .filmAmber: return "更暖、更复古的金黄"
        case .filmPushed: return "推两档：反差、饱和更足，颗粒更粗"
        case .filmEveryday: return "日常卷的绿调，暗部偏青"
        case .slideCool: return "浓烈清透，偏冷"
        case .cineTungsten: return "整体偏蓝的冷调电影感"
        case .none: return "不调色"
        case .film: return "暖、柔，黑位抬一点（原来叫「胶片」）"
        case .airy: return "提亮、偏青、反差低"
        case .faded: return "褪色，偏黄带棕"
        case .cinema: return "青橙对比，反差大（原来叫「电影」）"
        case .cool: return "冷灰、低饱和"
        case .mono: return "中性黑白"
        case .sepia: return "暖棕单色"
        case .newsprint: return "墨不纯黑、纸不纯白（原来叫「报纸」）"
        case .contrastMono: return "黑到底、白到顶"
        case .muted: return "哑光，反差和饱和都压低"
        case .fineArt: return "抬黑、柔和，高光微暖"
        }
    }

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
    /// 样张看哪个页签（打开时跟着现在的色调）。
    @Published var tab: Tab = .film
    /// 对比竖线、按住看原图：拖竖线一秒几十下，单独放一个对象，只有大预览和顶栏（「原图」按钮）订阅。以前放在暗房
    /// 自己身上，拖一下竖线样张栏、右栏、冲印、试条、底片条全跟着重算。
    final class Compare: ObservableObject {
        /// 对比竖线的位置：左边这一截看原图（0 = 全是成片）。
        @Published var split = 0.5
        /// 按住空格：整张看原图。
        @Published var showOriginal = false
    }
    let compare = Compare()
    var split: Double {
        get { compare.split }
        set { compare.split = newValue }
    }
    var showOriginal: Bool {
        get { compare.showOriginal }
        set { compare.showOriginal = newValue }
    }
    /// 1:1 放大镜看哪儿（画布像素坐标，左上原点）；nil = 主图那一格的中心。
    @Published var loupeAnchor: CGPoint? { didSet { scheduleLoupe() } }
    /// 1:1 细节所在那块屏幕一个 pt 几个像素（视图按 displayScale 填）：按它渲，Retina 上渲 loupeSide × 2 个导出像素、
    /// 显示在 loupeSide pt 里 —— 一个导出像素 = 一个屏幕像素。以前不管屏幕渲 232 个导出像素、显示成 232 pt，
    /// 2 倍屏上一个像素占 2×2，看到的是 200%，按它调的颗粒偏小。
    var loupeDensity: Double = 1 {
        didSet { if abs(loupeDensity - oldValue) > 0.01 { scheduleLoupe() } }
    }
    /// 1:1 细节渲多少个导出像素（边长）。
    var loupePixels: Int { Int((Double(Self.loupeSide) * max(1, loupeDensity)).rounded()) }

    @Published private(set) var frames: [CollageLook: NSImage] = [:]
    /// 大预览、原图、1:1 细节：拖着滑杆时一秒换十几次，单独放一个对象，只有大预览和 1:1 细节订阅它。
    /// 以前放在暗房自己身上，每出一张大预览、busy 每闪一下，顶栏、右栏（一排滑杆）、冲印、试条、底片条全跟着重算。
    final class Output: ObservableObject {
        @Published fileprivate(set) var processed: NSImage?
        @Published fileprivate(set) var original: NSImage?
        @Published fileprivate(set) var loupe: NSImage?
        /// 放大镜正在重渲（界面上把旧的压暗一点）。
        @Published fileprivate(set) var loupeStale = false
        /// 大预览顶上那条「在渲」的细线：busy 连着超过 busyLineDelay 才亮，busy 一停就灭。
        @Published fileprivate(set) var busyLine = false
    }
    let output = Output()
    var processed: NSImage? { output.processed }
    var original: NSImage? { output.original }
    var loupe: NSImage? { output.loupe }
    var loupeStale: Bool { output.loupeStale }
    /// 有渲染在跑、或者 1:1 细节等着停手（快照、perf 场景轮询它）。不发通知：界面上只看 busyLine。
    private(set) var busy = false
    /// busy 连着这么久，细线才亮（秒）。拖滑杆时大预览一帧一张、一张十几毫秒，busy 一秒开关二十几回；那条线每开关
    /// 一次都是 0.2 秒的淡入淡出，几乎一直在动画，主线程每一帧都把整个暗房的显示列表过一遍（离屏量：开关一次
    /// 30 ms，没有动画 2.7 ms）。短的渲染本来也一闪就过，看不出来；要等的（1:1 细节、换色调）照旧亮。
    static let busyLineDelay = 0.25
    private var busyLineWork: DispatchWorkItem?
    /// 强度试条：0 / 25 / 50 / 75 / 100%。
    @Published private(set) var testStrip: [NSImage] = []
    static let stripSteps: [Double] = [0, 0.25, 0.5, 0.75, 1]
    struct ReelFrame: Identifiable, Hashable {
        let path: [Int]
        let photoID: String
        let image: NSImage?
        var id: [Int] { path }
    }
    /// 底下的底片条：这一页每一格照片，套着它自己现在的色调。
    @Published private(set) var reel: [ReelFrame] = []
    /// 表、颗粒数据读不到的光谱色调（右栏「这款的数据没读到」）。只记问过的：现在套着的那一款（probeData）。
    @Published private(set) var dataMissing: Set<CollageLook> = []
    /// 正在后台读的（同一款不重复派）。
    private var probing: Set<CollageLook> = []

    /// 大预览可用的像素（视图按自己的尺寸 × 屏幕倍率填）。
    var previewPixels = CGSize(width: 1600, height: 1100) {
        didSet {
            if abs(previewPixels.width - oldValue.width) > 8 || abs(previewPixels.height - oldValue.height) > 8 {
                schedulePreview()
            }
        }
    }

    private var watch: AnyCancellable?
    /// 焦点、页签、悬停、放大镜位置是按哪一页设的（syncToPage）：页换了（顶栏 ‹ ›、MCP 加 / 删跨页、撤销、ops 改 pageIndex）
    /// 就按新这一页重设。
    private var shownPageID: UUID?
    /// storeWillChange 已经排了一次 syncToPage、还没跑（同一轮里 store 连着变只排一次）。
    private var pageSyncPending = false
    /// store 变了、大预览还没跟上的那一次（storeWillChange）。
    private var previewPending = false
    /// 停手以后把每一类都看一遍（storeWillChange）。
    private var settleWork: DispatchWorkItem?
    /// store 连着变的时候大预览最多隔这么久换一次要渲的那一份（秒）。
    static let previewInterval = 0.04
    /// store 停下来这么久，再把样张、底片条、原图、1:1 细节都看一遍（秒；和以前的去抖一样）。
    static let settleDelay = 0.12

    init(store: CollageStore, rendering: Bool = true) {
        self.store = store
        self.rendering = rendering
        watch = store.objectWillChange.sink { [weak self] _ in self?.storeWillChange() }
        shownPageID = store.page?.id
        focus = current.look
        tab = Self.tab(of: current.look)
        refresh()
    }

    /// 画布上的页换了（按页 id 认，不按下标：删了当前页、撤销回去下标不变、页已经不是那一页）：悬停、放大镜位置清掉，
    /// 样张的焦点和页签跟着新这一页现在用的色调（同打开暗房时）。不然焦点框还停在上一页套的那款，按 ⏎ 会把它套到这一页，
    /// ← → 也从它往后数（R3#2：以前只有顶栏 ‹ › 换页时重设，MCP 加 / 删跨页、撤销、ops 改 pageIndex 都不管）。
    /// 返回 true = 页换了、重设过（⏎ 先问它：刚换了页就不套用那个过期的焦点）。
    @discardableResult
    func syncToPage() -> Bool {
        let id = store.page?.id
        guard id != shownPageID else { return false }
        shownPageID = id
        hover = nil
        loupeAnchor = nil
        focus = current.look
        tab = Self.tab(of: current.look)
        return true
    }

    /// store 一变（objectWillChange 在改之前发，到点再读的是改完的）：
    /// - 大预览最多每 previewInterval 换一次要渲的那一份，最后那一下一定换到。以前整个暗房是去抖 120 ms：拖滑杆时
    ///   新值一直来、去抖一直不到点，大预览要等松手（或者停一下）才动 —— 拖着的时候看不到颗粒、曝光在变，倒是藏在
    ///   后面的画布预览在一张张渲（CollageStore.setNeedsRender）。大预览照旧只渲最新的那一次。
    /// - 别的几类（样张、试条、底片条、原图、1:1 细节）照旧停手 settleDelay 再看：拖强度时 27 张样张不用每一档渲一遍。
    private func storeWillChange() {
        // objectWillChange 在改之前发：到下一轮再看页换了没有。不放在去抖 settleDelay 的 refresh 里 —— ⏎ 可能抢在前面。
        if !pageSyncPending {
            pageSyncPending = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pageSyncPending = false
                    if self.watch != nil { self.syncToPage() }
                }
            }
        }
        if !previewPending {
            previewPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewInterval) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.previewPending else { return }
                    self.previewPending = false
                    self.schedulePreview()
                }
            }
        }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.watch != nil else { return }
                self.refresh()
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    func stop() {
        watch = nil
        previewPending = false
        settleWork?.cancel()
        settleWork = nil
        busyLineWork?.cancel()
        busyLineWork = nil
        loupeTimer?.invalidate()
        loupeTimer = nil
        laneKey.removeAll()
        laneJob.removeAll()
        originals.removeAll()
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
    /// 连拖合成一步只和同一级的强度合并（撤销的 key：整组是样式里的强度，这一页 / 这一格带上是哪一页、哪一格）。
    func setStrength(_ value: Double, coalesce: Bool = true) {
        let v = min(1, max(0, value))
        switch effectiveScope {
        case .project:
            var st = store.project.style
            st.lookStrength = v
            store.setStyle(st, coalesce: coalesce, key: \CollageStyle.lookStrength)
        case .page:
            var s = store.page?.look ?? CollageLookSetting(look: current.look, strength: v)
            s.strength = v
            store.setPageLook(s, coalesce: coalesce, key: "页的强度 \(store.page?.id.uuidString ?? "")")
        case .cell:
            var s = store.selectedCell?.look ?? CollageLookSetting(look: current.look, strength: v)
            s.strength = v
            store.setCellLook(s, coalesce: coalesce, key: "格的强度 \(store.page?.id.uuidString ?? "") \(store.selection ?? [])")
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

    /// 颗粒、晕光、统一色温、冲印区：整组的。range = 这一项的取值范围（胶片曝光 −1…+2、冷暖 −1…+1）。
    /// 连拖合成一步只和同一项合并（撤销的 key 就是这一项的 keyPath）：拖完颗粒马上拖晕光是两步。
    func setStyleValue(_ keyPath: WritableKeyPath<CollageStyle, Double>, _ value: Double,
                       range: ClosedRange<Double> = 0...1) {
        var st = store.project.style
        st[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, value))
        store.setStyle(st, coalesce: true, key: keyPath)
    }

    /// 画幅（整组的）：一次一步。
    func setFormat(_ format: CollageFilmFormat) {
        var st = store.project.style
        st.filmFormat = format
        store.setStyle(st, coalesce: false)
    }

    /// ↺：颗粒、晕光回到这一款的起始值，冲印区（曝光、冷暖、画幅）回到不动。一步撤销。
    func resetTexture() {
        var st = store.project.style
        let d = CollageFilmEffects.defaults(current.look)
        st.filmGrain = d?.grain ?? 0
        st.filmHalation = d?.halation ?? 0
        st.filmExposure = 0
        st.filmWarmth = 0
        st.filmFormat = .f135
        store.setStyle(st, coalesce: false, filmDefaults: false)
    }

    /// ←→（↑↓ 跳一行）：在这一页签的样张里挪焦点，大预览跟着看（不套用）。到头绕回；焦点不在这一页签里
    /// （刚换了页签）从第一张起。
    func moveFocus(_ delta: Int) {
        let list = Self.looks(in: tab)
        let i = list.firstIndex(of: hover ?? focus) ?? (delta > 0 ? -1 : 0)
        let next = list[((i + delta) % list.count + list.count) % list.count]
        focus = next
        hover = next
    }

    // MARK: - 换页

    var pageCount: Int { store.project.pages.count }
    var canGoBack: Bool { store.pageIndex > 0 }
    var canGoForward: Bool { store.pageIndex + 1 < pageCount }

    /// 换跨页（顶栏的 ‹ ›、⌘← ⌘→）：到头不动。悬停清掉、放大镜回到新一页主图那一格的中心（点过的位置是上一页的）；
    /// store 换页时清掉选中，「这一格」退回这一页；样张的焦点跟着新这一页的色调（syncToPage，别处换页也走它）。
    /// 各类渲染跟着 store 变（键里都有页码或这一页的照片），不用另外刷新。
    func goToPage(_ delta: Int) {
        let target = store.pageIndex + delta
        guard delta != 0, store.project.pages.indices.contains(target) else { return }
        store.pageIndex = target
        syncToPage()
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
        out.style.filmExposure = 0
        out.style.filmWarmth = 0
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

    /// 一类渲染的键：渲的那份工程（方案栏清掉 —— 存、删方案不改这一版的样子，和编辑指纹一样不算）+ 别的参数。
    /// 工程整份逐项比（==）：以前每次都把整份工程编成 JSON 算编辑指纹，315 张 / 30 页的相册一次 8 ms（debug），
    /// 大预览拖着跟手以后每 40 ms 就要算一次，停手再算原图、1:1 细节两份。没改过的数组和上一份共用内存，一比就过。
    struct LaneKey: Equatable {
        var project: CollageProject?
        var extra: String

        init(_ project: CollageProject, _ extra: String) {
            var p = project
            p.variants = []
            self.project = p
            self.extra = extra
        }

        /// 样张、试条、底片条：不看整份工程，键就是它们自己用到的那几样。
        init(_ extra: String) {
            project = nil
            self.extra = extra
        }
    }

    private var laneKey: [String: LaneKey] = [:]
    private var laneJob: [String: @MainActor () async -> Void] = [:]
    /// 1:1 细节的原图解码：最近用的两张（一般就是那一格，压着缝时是两格）。停手一次渲一次，以前每次都从原图整张重解
    /// （纯 RAW 场次一次一整幅 RAW）。关暗房就清掉（导出尺寸的解码一张几十上百 MB）。
    let originals = CollageImages.Recent(capacity: 2)
    private var laneRunning: Set<String> = []
    private var loupeTimer: Timer?

    private func submit(_ lane: String, key: LaneKey, _ job: @escaping @MainActor () async -> Void) {
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
            let start = Date()
            await job()
            CollagePerf.lane(lane, ms: Date().timeIntervalSince(start) * 1000)
            guard let self else { return }
            self.laneRunning.remove(lane)
            self.pump(lane)
        }
    }

    private func updateBusy() {
        let now = !laneRunning.isEmpty || !laneJob.isEmpty || loupeTimer != nil
        guard busy != now else { return }
        busy = now
        busyLineWork?.cancel()
        busyLineWork = nil
        if now {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.busy else { return }
                    self.output.busyLine = true
                }
            }
            busyLineWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyLineDelay, execute: work)
        } else if output.busyLine {
            output.busyLine = false
        }
    }

    private func current(_ lane: String, _ key: LaneKey) -> Bool { laneKey[lane] == key }

    /// 样张、试条、底片条的键里的冲印区：量化到色调表用的那一档（0.1 档 / 5%，CollageFilmEffects.Printing），
    /// 拖胶片曝光、冷暖时落在同一档里的几下不重渲。
    nonisolated static func printingKey(_ style: CollageStyle) -> String {
        let p = CollageFilmEffects.Printing(exposure: style.filmExposure, warmth: style.filmWarmth)
        return "\(p.exposure),\(p.warmth)"
    }

    /// store 变了（套用、撤销、换页、选中、托盘……）：每一类按自己的 key 看要不要重渲。
    func refresh() {
        syncToPage()
        probeData(current.look)
        guard rendering else { return }
        if store.selection == nil && scope == .cell { objectWillChange.send() }
        schedulePreview()
        scheduleOriginal()
        scheduleFrames()
        scheduleStrip()
        scheduleReel()
        scheduleLoupe()
    }

    /// 这一款的表、颗粒数据读到没有（右栏的提示）：只问缓存、不在主线程上读文件（CollageFilmLUTs / CollageFilmEffects
    /// .cachedState）；还没读过的派到后台读一次，读完再更新 dataMissing。以前右栏 body 里直接 table(look) /
    /// extras(look)：冷开暗房、刚点了一款样张还没渲完的胶片时，主线程上要解析一张 .cube 加四张表（十几万行文本，
    /// 几十毫秒）。平常画布、大预览早就在后台用这一款渲过，问的时候已经在缓存里，提示当场就对。
    private func probeData(_ look: CollageLook) {
        guard look.isSpectral else { return }
        let table = CollageFilmLUTs.cachedState(look), extras = CollageFilmEffects.cachedState(look)
        if table == false || extras == false {
            setMissing(look, true)
            return
        }
        if table == true && extras == true {
            setMissing(look, false)
            return
        }
        guard probing.insert(look).inserted else { return }
        Task { @MainActor [weak self] in
            let missing = await Task.detached(priority: .utility) {
                CollageFilmLUTs.table(look) == nil || CollageFilmEffects.extras(look) == nil
            }.value
            guard let self else { return }
            self.probing.remove(look)
            self.setMissing(look, missing)
        }
    }

    private func setMissing(_ look: CollageLook, _ missing: Bool) {
        guard dataMissing.contains(look) != missing else { return }
        if missing { dataMissing.insert(look) } else { dataMissing.remove(look) }
    }

    /// 自检用：后台读完了没有（probeData 派出去的都回来了）。
    var probingData: Bool { !probing.isEmpty }

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
        let key = LaneKey(project, "\(store.pageIndex)|\(scale)|\(hints.count)")
        let pageIndex = store.pageIndex
        submit("preview", key: key) { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.renderPage(project, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale)
            }.value
            guard let self, self.current("preview", key) else { return }
            self.output.processed = image
        }
    }

    private func scheduleOriginal() {
        guard let page = store.page else { return }
        let project = Self.original(store.project, pageIndex: store.pageIndex)
        let scale = previewScale
        let hints = store.hints
        let pageIndex = store.pageIndex
        // 原图哪一级都不调色：整组的强度不影响它（色调是原色时 Ops 是原样），拖强度不重渲原图。只改算键的那一份。
        var keyed = project
        keyed.style.lookStrength = 0
        let key = LaneKey(keyed, "\(pageIndex)|\(scale)|\(hints.count)")
        submit("original", key: key) { [weak self] in
            let image = await Task.detached(priority: .utility) {
                Self.renderPage(project, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale)
            }.value
            guard let self, self.current("original", key) else { return }
            self.output.original = image
        }
    }

    private func scheduleFrames() {
        guard let id = subjectPhotoID else { return }
        let base = store.project
        let hints = store.hints
        let strength = current.strength
        let looks = Self.order
        let key = LaneKey("\(id)|\(Int((strength * 20).rounded()))|\(base.style.halftone.map { "\($0)" } ?? "")|\(hints[id] != nil)"
                          + "|\(Self.printingKey(base.style))")
        submit("frames", key: key) { [weak self] in
            let images = await Task.detached(priority: .utility) { () -> [CollageLook: NSImage] in
                // 27 张互不相干：并发渲（每张和一张张挨着渲逐字节一样）。工程是值类型、几个线程只读不改：装进 LiveBox
                // 递给 concurrentPerform（它的闭包是 @Sendable，CollageProject 没标 Sendable，直接捕获有一条警告）。
                let shared = LiveBox(base)
                var out: [CollageLook: NSImage] = [:]
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: looks.count) { i in
                    let image = Self.sample(id, base: shared.value, hints: hints, look: looks[i], strength: strength,
                                            width: 330, height: 220)
                    lock.lock()
                    out[looks[i]] = image
                    lock.unlock()
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
        let steps = Self.stripSteps
        let key = LaneKey("\(id)|\(look.rawValue)|\(hints[id] != nil)|\(Self.printingKey(base.style))")
        submit("strip", key: key) { [weak self] in
            let images = await Task.detached(priority: .utility) { () -> [NSImage] in
                // 同样并发渲，按强度的先后放回去（渲不出来的那格照旧去掉）。工程同样装进 LiveBox 递过去。
                let shared = LiveBox(base)
                var out = [NSImage?](repeating: nil, count: steps.count)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: steps.count) { i in
                    let image = Self.sample(id, base: shared.value, hints: hints, look: look, strength: steps[i],
                                            width: 150, height: 100)
                    lock.lock()
                    out[i] = image
                    lock.unlock()
                }
                return out.compactMap { $0 }
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
        let page = project.pages.indices.contains(pageIndex) ? project.pages[pageIndex] : nil
        let settings = cells.map { f in
            f.cell.look ?? page?.look ?? CollageLookSetting(look: project.style.look, strength: project.style.lookStrength)
        }
        // 底片条每格是一张单独的样张（sample：一份新样式，只带色调、强度、加网、冲印区）：键只要每格的照片、它实际的
        // 色调和强度、加网（纸色跟底色）、冲印区（量化以后的，和色调表缓存同一档）、路人信息。颗粒、晕光、统一色温、
        // 边距、字都不进样张 —— 以前键是整个工程的指纹，暗房里拖一下颗粒，底片条整条跟着重渲一遍，渲出来和原来一模一样。
        let cellsKey = zip(cells, settings).map { f, s in
            "\(f.path.map(String.init).joined())=\(f.cell.photoID ?? "")@\(s.look.rawValue):\(s.strength):"
                + "\(hints[f.cell.photoID ?? ""] != nil)"
        }.joined(separator: ",")
        let halftone = project.style.halftone.map { "\($0)|\(project.style.background)" } ?? ""
        let key = LaneKey("\(pageIndex)|\(cellsKey)|\(halftone)|\(hints.count)|\(Self.printingKey(project.style))")
        submit("reel", key: key) { [weak self] in
            let reel = await Task.detached(priority: .utility) { () -> [ReelFrame] in
                zip(cells, settings).map { f, setting in
                    let id = f.cell.photoID ?? ""
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
        let originals = originals
        let side = loupePixels
        let density = max(1, loupeDensity)
        let key = LaneKey(project, "\(pageIndex)|\(scale)|\(Int(center.x)),\(Int(center.y))|\(hints.count)|\(side)")
        if laneKey["loupe"] != key { output.loupeStale = output.loupe != nil }
        submit("loupe", key: key) { [weak self] in
            let image = await Task.detached(priority: .utility) {
                Self.renderLoupe(project, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale, center: center,
                                 side: side, density: density, originals: originals)
            }.value
            guard let self, self.current("loupe", key) else { return }
            self.output.loupe = image
            self.output.loupeStale = false
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
    /// 冲印区（胶片曝光、冷暖）跟着工程带上：它烘在色调表里（CollageLooks.cube，一张 0.8 ms），大预览、1:1 细节都有，
    /// 样张、试条、底片条不带就和点下去的对不上（调过曝光、冷暖再挑一款，样张上看到的不是套上去的样子）。
    /// 只对光谱色调起作用（滤镜、反转片的曝光照旧不动，同 CollageFilmEffects.Developer）。颗粒、晕光照旧不进样张：
    /// 样张缩得很小，颗粒平均掉了，每张还多一遍 Core Image。统一色温不进：它是这一页几张照片往主图靠的增益，
    /// 一张照片的样张没有「别的照片」（CollageLooks.ops 要两张以上），样张默认用的就是主图，大预览里主图也不动。
    nonisolated static func sample(_ photoID: String, base: CollageProject, hints: [String: CollageCrop.Hints],
                                   look: CollageLook, strength: Double, width: Int, height: Int) -> NSImage? {
        var p = base
        p.canvas = CollageCanvas(name: "darkroom", width: width, height: height)
        var style = CollageStyle()
        style.margin = 0
        style.look = look
        style.lookStrength = strength
        style.filmExposure = base.style.filmExposure
        style.filmWarmth = base.style.filmWarmth
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

    /// 放大镜：导出尺寸（原图解码、导出倍数）渲整页，裁中心附近 side × side 像素（side = loupeSide × 屏幕倍率：一个导出
    /// 像素 = 一个屏幕像素；图的 size 按 density 换成 pt，还是 loupeSide pt 见方）。
    /// 只要那一小块：离它远的照片格、只够得着投影的照片格不出图（CollageRender.Options.region，裁出来的像素和渲整页
    /// 逐字节一样，--darkroom-selftest 核对）；原图解码先查 originals（最近两张）。以前整页每格都从原图解、在导出尺寸
    /// 上调色加颗粒，一次半秒多（1 倍；2、3 倍导出是 4、9 倍的像素），暗房里每改一下停手就来一次，渲的时候 1:1 细节
    /// 一直压暗、还和大预览抢 CPU。够得着的格子照旧整格调色加颗粒（只出一截不逐字节一样，见 CollageRender.cellImage）。
    nonisolated static let loupeSide = 232
    nonisolated static func renderLoupe(_ project: CollageProject, pageIndex: Int, fallback: CollagePage,
                                        hints: [String: CollageCrop.Hints], scale: Double, center: CGPoint,
                                        side: Int = loupeSide, density: Double = 1,
                                        originals: CollageImages.Recent? = nil, wholePage: Bool = false) -> NSImage? {
        guard let own = loupeImage(project, pageIndex: pageIndex, fallback: fallback, hints: hints, scale: scale,
                                   center: center, side: side, originals: originals, wholePage: wholePage)
        else { return nil }
        return NSImage(cgImage: own, size: NSSize(width: Double(own.width) / density, height: Double(own.height) / density))
    }

    nonisolated static func loupeImage(_ project: CollageProject, pageIndex: Int, fallback: CollagePage,
                                       hints: [String: CollageCrop.Hints], scale: Double, center: CGPoint,
                                       side: Int = loupeSide, originals: CollageImages.Recent? = nil,
                                       wholePage: Bool = false) -> CGImage? {
        let page = project.pages.indices.contains(pageIndex) ? project.pages[pageIndex] : fallback
        guard let rect = loupeRect(canvas: project.canvas, scale: scale, center: center, side: side) else { return nil }
        var opts = loupeOptions(scale: scale)
        opts.originals = originals
        if !wholePage { opts.region = rect }
        guard let cg = CollageRender.render(page: page, project: project, hints: hints, options: opts) else { return nil }
        return ownCrop(cg, rect, canvas: project.canvas, scale: scale)
    }

    /// 1:1 细节的渲染选项：导出尺寸、原图解码、带水印、不带出血（和导出看到的一样）。核对用的整页也用它，只差 region。
    nonisolated static func loupeOptions(scale: Double) -> CollageRender.Options {
        var opts = CollageRender.Options(scale: scale)
        opts.includeBleed = false
        opts.export = true
        opts.watermark = true
        return opts
    }

    /// 1:1 细节那一块在这次渲染里的位置（像素，左上原点）：side × side，中心尽量落在 center（画布像素），贴边时往里收；
    /// 画布比 side 还小就取画布的短边。渲出来的尺寸和 render 里一样算（不带出血）。
    nonisolated static func loupeRect(canvas: CollageCanvas, scale: Double, center: CGPoint, side: Int) -> CGRect? {
        let w = Int((Double(canvas.width) * scale).rounded())
        let h = Int((Double(canvas.height) * scale).rounded())
        let s = min(side, w, h)
        guard s > 0 else { return nil }
        let cx = Int((center.x * scale).rounded()), cy = Int((center.y * scale).rounded())
        let x = min(max(0, cx - s / 2), w - s)
        let y = min(max(0, cy - s / 2), h - s)
        return CGRect(x: x, y: y, width: s, height: s)
    }

    /// 从整页里裁出那一块，画进自己的位图。裁出来的 CGImage 和整页共用一块内存（dataProvider 是整页的）：直接交出去，
    /// 1:1 细节开着就一直钉着一整张导出尺寸的页面位图（印刷跨页约 100 MB）。画进自己的 side × side 位图（和渲染同一种
    /// 格式：sRGB、8 位、不带 alpha，1:1 不缩放，逐字节就是裁出来的那块），整页随这次渲染一起放掉。
    nonisolated static func ownCrop(_ cg: CGImage, _ rect: CGRect, canvas: CollageCanvas, scale: Double) -> CGImage? {
        let w = Int((Double(canvas.width) * scale).rounded())
        let h = Int((Double(canvas.height) * scale).rounded())
        guard cg.width == w, cg.height == h, let crop = cg.cropping(to: rect) else { return nil }
        let side = Int(rect.width)
        guard let ctx = CollageRender.makeContext(width: side, height: Int(rect.height)) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: Int(rect.height)))
        return ctx.makeImage()
    }

    /// 1:1 细节只渲够得着的那一块（Options.region，原图走 originals 缓存）和渲整页再裁（原图现解）逐字节比：每个中心
    /// 一个结果（整页只渲一次）。
    /// region 的安全边距是按效果估的（CollageRender 里的 regionPad），以后哪个效果画出了这个范围，1:1 细节就会悄悄缺
    /// 一块 —— --darkroom-selftest 用几种模板核对、不同就失败；--perf darkroom 在真照片上打印。
    nonisolated static func loupeIdentity(_ project: CollageProject, pageIndex: Int, fallback: CollagePage,
                                          hints: [String: CollageCrop.Hints], scale: Double, centers: [CGPoint],
                                          side: Int = loupeSide) -> [Bool] {
        let page = project.pages.indices.contains(pageIndex) ? project.pages[pageIndex] : fallback
        let whole = CollageRender.render(page: page, project: project, hints: hints, options: loupeOptions(scale: scale))
        let originals = CollageImages.Recent(capacity: 2)
        return centers.map { center in
            guard let whole, let rect = loupeRect(canvas: project.canvas, scale: scale, center: center, side: side),
                  let expected = ownCrop(whole, rect, canvas: project.canvas, scale: scale).flatMap(pixels),
                  let culled = loupeImage(project, pageIndex: pageIndex, fallback: fallback, hints: hints, scale: scale,
                                          center: center, side: side, originals: originals).flatMap(pixels)
            else { return false }
            return expected == culled
        }
    }

    /// 一张图的 RGBA 字节（画进一张新的位图再读：和格式、行宽无关）。
    nonisolated static func pixels(_ cg: CGImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: cg.width * 4, space: CollageRender.srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        return ok ? out : nil
    }
}
