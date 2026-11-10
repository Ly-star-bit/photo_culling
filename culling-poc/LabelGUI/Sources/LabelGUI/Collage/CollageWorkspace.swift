import SwiftUI
import AppKit

// MARK: - 拼图页的工作区：两边的栏（收起 / 宽度）、画布缩放、几样视图偏好
//
// 以前是 HSplitView：1440 宽的窗口里两栏各撑到最大（340 + 380），相册跨页只画 660×330pt；没有收起，画布也不能放大。
// 现在两栏的宽度自己管（默认 250 / 330，拖分隔条改，记在偏好里），各有一个收起（左 ⌃⌘S、右 ⌥⌘S，同批量页的筛选面板），
// 画布能放大（捏合、⌘ 滚轮、⌘= ⌘- ⌘0 ⌘1，放大以后滚动 = 平移）。
// 偏好写 UserDefaults；无头（离屏快照、命令行）不读也不写，截出来的图只看命令行参数。

@MainActor
final class CollageWorkspace: ObservableObject {
    nonisolated static let trayRange: ClosedRange<CGFloat> = 230...420
    nonisolated static let inspectorRange: ClosedRange<CGFloat> = 300...460
    nonisolated static let trayDefault: CGFloat = 250
    nonisolated static let inspectorDefault: CGFloat = 330
    /// 画布区最窄（同以前 HSplitView 里给画布的 minWidth）。
    nonisolated static let canvasMin: CGFloat = 420
    /// 分隔条多宽（中间一条 1pt 的线，两边是好抓的空当）。
    nonisolated static let handleWidth: CGFloat = 7
    nonisolated static let thumbRange: ClosedRange<Double> = 56...132
    nonisolated static let thumbDefault: Double = 64

    @Published var trayHidden: Bool { didSet { save(trayHidden, "collage.trayHidden") } }
    @Published var inspectorHidden: Bool { didSet { save(inspectorHidden, "collage.inspectorHidden") } }
    @Published var trayWidth: CGFloat { didSet { save(Double(trayWidth), "collage.trayWidth") } }
    @Published var inspectorWidth: CGFloat { didSet { save(Double(inspectorWidth), "collage.inspectorWidth") } }
    /// 「样式 › 风格」摊开全部预设（收着 = 两排）。
    @Published var presetsExpanded: Bool { didSet { save(presetsExpanded, "collage.presetsExpanded") } }
    /// 托盘缩略图最小多宽（pt）。
    @Published var trayThumb: Double { didSet { save(trayThumb, "collage.trayThumb") } }
    /// 托盘按章节分组。
    @Published var trayGrouped: Bool { didSet { save(trayGrouped, "collage.trayGrouped") } }

    /// 画布的缩放和平移：只有画布订阅。
    let zoom = CollageCanvasZoom()
    /// 备选条上鼠标停着的那一个（画布底下浮一张大的）：只有那张大图订阅。
    let altHover = CollageAltHover()

    init() {
        let d = UserDefaults.standard
        let live = !AppRuntime.headless
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard live, d.object(forKey: key) != nil else { return fallback }
            return min(range.upperBound, max(range.lowerBound, d.double(forKey: key)))
        }
        trayHidden = live && d.bool(forKey: "collage.trayHidden")
        inspectorHidden = live && d.bool(forKey: "collage.inspectorHidden")
        trayWidth = CGFloat(number("collage.trayWidth", Double(Self.trayDefault),
                                   Double(Self.trayRange.lowerBound)...Double(Self.trayRange.upperBound)))
        inspectorWidth = CGFloat(number("collage.inspectorWidth", Double(Self.inspectorDefault),
                                        Double(Self.inspectorRange.lowerBound)...Double(Self.inspectorRange.upperBound)))
        presetsExpanded = live && d.bool(forKey: "collage.presetsExpanded")
        trayThumb = number("collage.trayThumb", Self.thumbDefault, Self.thumbRange)
        trayGrouped = live && d.bool(forKey: "collage.trayGrouped")
    }

    private func save(_ value: Any, _ key: String) {
        if !AppRuntime.headless { UserDefaults.standard.set(value, forKey: key) }
    }

    /// 「去那儿」要去的那一栏收着：先摊开（不然切了页签、滚过去、描边都看不见）。
    func reveal(_ area: CollageSpot.Area) {
        switch area {
        case .tray: if trayHidden { trayHidden = false }
        case .inspector: if inspectorHidden { inspectorHidden = false }
        case .bar: break
        }
    }

    /// 两栏这一次实际多宽：窗口窄、放不下「两栏 + 画布最窄」时两栏按各自还能让的份往回收（收到各自的下限为止）。
    /// nil = 那一栏收着。
    nonisolated static func widths(total: CGFloat, tray: CGFloat?, inspector: CGFloat?) -> (tray: CGFloat, inspector: CGFloat) {
        let t = tray.map { min(trayRange.upperBound, max(trayRange.lowerBound, $0)) } ?? 0
        let i = inspector.map { min(inspectorRange.upperBound, max(inspectorRange.lowerBound, $0)) } ?? 0
        let handles = (tray == nil ? 0 : handleWidth) + (inspector == nil ? 0 : handleWidth)
        let room = total - canvasMin - handles
        let excess = t + i - room
        guard excess > 0 else { return (t, i) }
        let slackT = tray == nil ? 0 : t - trayRange.lowerBound
        let slackI = inspector == nil ? 0 : i - inspectorRange.lowerBound
        let slack = slackT + slackI
        guard slack > 0 else { return (t, i) }
        let give = min(1, excess / slack)
        return ((t - slackT * give).rounded(), (i - slackI * give).rounded())
    }
}

// MARK: - 画布缩放

/// 画布的缩放（1 = 适应窗口）和平移（视图点）。画布每次排版把「适应时多大」记进来（不发布），顶栏快捷键、右下角的
/// 小条、滚轮都按它算、按它夹。
@MainActor
final class CollageCanvasZoom: ObservableObject {
    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var offset: CGSize = .zero

    /// 画布区多大、适应时画布占的矩形（视图点）。
    private(set) var viewSize: CGSize = .zero
    private(set) var fitRect: CGRect = .zero
    /// 适应时一个成品像素占几个屏幕像素（< 1 = 缩小着看）。发布：右下角小条上的百分比跟着它（换画布、拖窗口）。
    @Published private(set) var fitPixelRatio: CGFloat = 1

    nonisolated static let step: CGFloat = 1.25
    /// 平移时画布边最多离开视图边多远（和适应时四周的留白一样）。
    nonisolated static let slack: CGFloat = 28

    var isFit: Bool { scale <= 1.0001 }

    /// 最大放多大：至少 4 倍；成品比屏幕细得多的（30×30 的相册）放得到实际像素。
    var maxScale: CGFloat { min(24, max(4, 1 / max(0.01, fitPixelRatio))) }

    /// 实际像素的百分比（100% = 一个成品像素一个屏幕像素）。
    var percent: Int { Int((scale * fitPixelRatio * 100).rounded()) }

    /// 画布每次排版调：记下适应时的几何；视图变小了平移跟着夹回来。
    func record(viewSize: CGSize, fitRect: CGRect, fitPixelRatio: CGFloat) {
        self.viewSize = viewSize
        self.fitRect = fitRect
        if abs(self.fitPixelRatio - fitPixelRatio) > 0.0005 { self.fitPixelRatio = fitPixelRatio }
    }

    /// 夹过的平移：放大后的画布不会整个拖出视图。
    nonisolated static func clamp(_ offset: CGSize, scale: CGFloat, fitRect: CGRect, viewSize: CGSize) -> CGSize {
        let maxX = max(0, (fitRect.width * scale - viewSize.width) / 2 + slack)
        let maxY = max(0, (fitRect.height * scale - viewSize.height) / 2 + slack)
        return CGSize(width: min(maxX, max(-maxX, offset.width)), height: min(maxY, max(-maxY, offset.height)))
    }

    /// 缩放到 z；anchor（视图坐标）那一点底下的画面不动（捏合、滚轮在指针处放大），nil = 视图正中。
    func zoom(to z: CGFloat, anchor: CGPoint? = nil) {
        let target = min(maxScale, max(1, z))
        guard abs(target - scale) > 0.0005 else { return }
        var next = offset
        if target <= 1.0001 {
            next = .zero
        } else if let p = anchor, viewSize.width > 0 {
            let c = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            // p = c + v·scale + offset，放大以后同一个 v 还落在 p。
            let vx = (p.x - c.x - offset.width) / scale
            let vy = (p.y - c.y - offset.height) / scale
            next = CGSize(width: p.x - c.x - vx * target, height: p.y - c.y - vy * target)
        } else {
            next = CGSize(width: offset.width * target / scale, height: offset.height * target / scale)
        }
        scale = target <= 1.0001 ? 1 : target
        offset = Self.clamp(next, scale: scale, fitRect: fitRect, viewSize: viewSize)
    }

    func zoomIn() { zoom(to: scale * Self.step) }
    func zoomOut() { zoom(to: scale / Self.step) }
    func fit() { zoom(to: 1) }
    /// 实际像素（已经是了就回到适应）。
    func actualPixels() {
        let actual = min(maxScale, max(1, 1 / max(0.01, fitPixelRatio)))
        zoom(to: abs(scale - actual) < 0.01 ? 1 : actual)
    }

    func pan(by delta: CGSize) {
        guard !isFit else { return }
        let next = Self.clamp(CGSize(width: offset.width + delta.width, height: offset.height + delta.height),
                              scale: scale, fitRect: fitRect, viewSize: viewSize)
        if next != offset { offset = next }
    }

    /// 视图大小、画布比例变了：平移按新的几何夹一次。
    func reclamp() {
        let next = isFit ? .zero : Self.clamp(offset, scale: scale, fitRect: fitRect, viewSize: viewSize)
        if next != offset { offset = next }
        if scale > maxScale { scale = maxScale }
    }

    /// 预览渲多大用的缩放档（1、√2、2、2.83、4 …）：捏合时缩放连续变，预览只在跨档时重渲。
    nonisolated static func renderBucket(_ scale: CGFloat) -> CGFloat {
        guard scale > 1.0001 else { return 1 }
        return pow(2, (log2(scale) * 2).rounded(.up) / 2)
    }
}

extension CollageCanvasLayout {
    /// 适应的摆放放大 z 倍（绕视图正中）再平移。
    func zoomed(_ z: CGFloat, offset: CGSize, in size: CGSize) -> CollageCanvasLayout {
        guard z > 1.0001 || offset != .zero else { return self }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = CGRect(x: c.x + (rect.minX - c.x) * z + offset.width, y: c.y + (rect.minY - c.y) * z + offset.height,
                       width: rect.width * z, height: rect.height * z)
        return CollageCanvasLayout(rect: r, scale: scale * z)
    }
}

/// 画布右下角的缩放小条：− 百分比 + 适应。只订阅缩放。
struct CollageZoomBar: View {
    @ObservedObject var zoom: CollageCanvasZoom

    var body: some View {
        HStack(spacing: 2) {
            Button { zoom.zoomOut() } label: { Image(systemName: "minus").frame(width: 18, height: 18) }
                .disabled(zoom.isFit)
                .help("缩小 (⌘-)")
            Button { zoom.actualPixels() } label: {
                Text("\(zoom.percent)%").monospacedDigit().frame(minWidth: 40)
            }
            .help("实际像素 100%（⌘1，再按一次回到适应）。现在 \(zoom.percent)%")
            Button { zoom.zoomIn() } label: { Image(systemName: "plus").frame(width: 18, height: 18) }
                .disabled(zoom.scale >= zoom.maxScale - 0.001)
                .help("放大 (⌘=)；捏合、⌘ 滚轮在指针处放大，放大以后滚动 = 平移")
            if !zoom.isFit {
                Button("适应") { zoom.fit() }
                    .help("整页适应窗口 (⌘0)")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

/// 滚轮：垫在画布底下的看不见的 NSView + 只看本窗口的滚轮监听（同右键菜单那个）。指针在画布区里时问 handle，
/// 它说接了就吞掉这一下，没接照常往下传（没放大时的普通滚动不拦）。
struct CollageScrollAnchor: NSViewRepresentable {
    /// (滚了多少（视图点）, 指针在哪（视图坐标，左上原点）, 按着 ⌘ / ⌥) → 接没接。
    let handle: (CGSize, CGPoint, Bool) -> Bool

    final class AnchorView: NSView {
        var handle: ((CGSize, CGPoint, Bool) -> Bool)?
        private var token: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                // 鼠标滚轮一格 = 一行：换成和触控板差不多的点数。
                let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                let delta = CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k)
                let zooming = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
                return self.handle?(delta, p, zooming) == true ? nil : event
            }
        }

        private func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.handle = handle
    }
}

// MARK: - 两栏 + 画布

/// 左栏 | 画布 | 右栏。只订阅工作区（收起、宽度）：拖分隔条只重排这一层。
struct CollageSplit<Left: View, Center: View, Right: View>: View {
    @ObservedObject var workspace: CollageWorkspace
    let left: Left
    let center: Center
    let right: Right

    var body: some View {
        GeometryReader { geo in
            let w = CollageWorkspace.widths(total: geo.size.width,
                                            tray: workspace.trayHidden ? nil : workspace.trayWidth,
                                            inspector: workspace.inspectorHidden ? nil : workspace.inspectorWidth)
            HStack(spacing: 0) {
                if !workspace.trayHidden {
                    left.frame(width: w.tray).background(AppPalette.panel)
                    CollageSplitHandle(width: w.tray, direction: 1, range: CollageWorkspace.trayRange,
                                       set: { workspace.trayWidth = $0 },
                                       reset: { workspace.trayWidth = CollageWorkspace.trayDefault })
                }
                center
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if workspace.trayHidden {
                            CollagePaneToggle(edge: .leading, shown: false) { workspace.trayHidden = false }
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if workspace.inspectorHidden {
                            CollagePaneToggle(edge: .trailing, shown: false) { workspace.inspectorHidden = false }
                                .padding(8)
                        }
                    }
                if !workspace.inspectorHidden {
                    CollageSplitHandle(width: w.inspector, direction: -1, range: CollageWorkspace.inspectorRange,
                                       set: { workspace.inspectorWidth = $0 },
                                       reset: { workspace.inspectorWidth = CollageWorkspace.inspectorDefault })
                    right.frame(width: w.inspector).background(AppPalette.panel)
                }
            }
        }
    }
}

/// 分隔条：拖动改那一栏的宽度（direction 1 = 往右拖变宽，-1 = 往左拖变宽），双击回默认。
private struct CollageSplitHandle: View {
    let width: CGFloat
    let direction: CGFloat
    let range: ClosedRange<CGFloat>
    let set: (CGFloat) -> Void
    let reset: () -> Void
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(start != nil || hovering ? AppPalette.accent.opacity(0.7) : Color(nsColor: .separatorColor))
                .frame(width: start != nil || hovering ? 2 : 1)
        }
        .frame(width: CollageWorkspace.handleWidth)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = start ?? width
                    if start == nil { start = base }
                    set(min(range.upperBound, max(range.lowerBound, (base + value.translation.width * direction).rounded())))
                }
                .onEnded { _ in start = nil }
        )
        .onTapGesture(count: 2) { reset() }
        // 指针还停在上面时这一条没了（按快捷键收起了那一栏）：把推进去的光标弹出来，不然一直是左右箭头。
        .onDisappear {
            if hovering { NSCursor.pop() }
        }
        .help("拖动改宽度，双击回默认")
    }
}

/// 收起 / 摊开一栏的小按钮：栏里的页签那一行各有一个（收起），收起以后画布角上有一个（摊开）。
struct CollagePaneToggle: View {
    let edge: HorizontalEdge
    /// 那一栏现在摊着（按钮 = 收起）。
    let shown: Bool
    let action: () -> Void

    var body: some View {
        let left = edge == .leading
        Button(action: action) {
            Image(systemName: left ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 13))
                .frame(width: 22, height: 20)
                .foregroundStyle(shown ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.white.opacity(0.9)))
                .background(shown ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color.black.opacity(0.55)),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(left ? (shown ? "收起左栏，画布大一点 (⌃⌘S)" : "显示左栏：照片、模板、素材 (⌃⌘S)")
                   : (shown ? "收起右栏，画布大一点 (⌥⌘S)" : "显示右栏：格式、样式、文档 (⌥⌘S)"))
    }
}

// MARK: - 说明字

extension View {
    /// 面板里的说明字：11pt、二级灰（以前是 10pt 三级灰，深色底上几乎读不出来，而不少操作只靠这些字说明）。
    func collageHint() -> some View {
        font(.subheadline).foregroundStyle(.secondary)
    }
}

// MARK: - 备选条悬停的大图

/// 鼠标停在备选条的哪一张上、它的大图（后台渲好才有）。只有画布底下那张大图订阅。
@MainActor
final class CollageAltHover: ObservableObject {
    @Published var index: Int?
    @Published var image: NSImage?
    /// 第几次悬停（迟到的渲染对不上就扔）。
    var token = 0
    /// 鼠标现在停在哪一张上（不发布：只用来认「移开的是不是它」）。
    var hovered: Int?
}

/// 画布底下浮着的那张：备选条上鼠标停着的备选放大了看（不接点击）。
struct CollageAltHoverPreview: View {
    @ObservedObject var hover: CollageAltHover

    var body: some View {
        if let index = hover.index, let image = hover.image {
            VStack(spacing: 4) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 420, maxHeight: 280)
                Text("第 \(index + 1) 个备选 · 点一下用它").font(.caption).foregroundStyle(.white.opacity(0.9))
            }
            .padding(8)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 10)
            .padding(.bottom, 10)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

// MARK: - 贴纸的小图

/// 「素材 › 贴纸与手写」每个贴纸的样子：按加进来时的默认颜色、角度，在一小块纸上渲一次（后台），进程里记着。
@MainActor
final class CollageStickerThumbs: ObservableObject {
    static let shared = CollageStickerThumbs()
    @Published private(set) var images: [CollageSticker: NSImage] = [:]
    private var started = false

    /// 小图的那块纸（像素）；贴纸放大到占满它的大半。
    nonisolated static let paper = (width: 300, height: 180)

    /// 这个贴纸在小图里的那一个图层（自检也用它）。
    nonisolated static func item(_ kind: CollageSticker) -> CollageItem {
        var item = CollageItem(kind: .sticker)
        item.sticker = kind
        item.color = kind.defaultColor
        item.rotation = kind == .postmark ? -8 : (kind.isTape ? -6 : 0)
        if kind == .label { item.label = "拾光" }
        if kind == .barcode { item.label = "20260101" }
        // 宽、高相对画布短边（纸高）：放大到宽不过纸宽的 78%、高不过纸高的 74%。
        let size = kind.defaultSize
        let aspect = Double(paper.width) / Double(paper.height)
        let k = min(0.78 * aspect / size.w, 0.74 / size.h)
        item.width = size.w * k
        item.height = size.h * k
        item.cx = 0.5
        item.cy = 0.5
        return item
    }

    nonisolated static func render(_ kind: CollageSticker) -> CGImage? {
        var project = CollageProject()
        project.canvas = CollageCanvas(name: "贴纸", width: paper.width, height: paper.height)
        let page = CollagePage(root: .leaf(CollageCell(kind: .empty)), items: [item(kind)], freeform: true)
        project.pages = [page]
        var opts = CollageRender.Options(scale: 1)
        opts.includeBleed = false
        return CollageRender.render(page: page, project: project, hints: [:], options: opts)
    }

    func load() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            let rendered = await Task.detached(priority: .utility) { () -> [(CollageSticker, CGImage)] in
                CollageSticker.allCases.compactMap { kind in Self.render(kind).map { (kind, $0) } }
            }.value
            var out: [CollageSticker: NSImage] = [:]
            for (kind, cg) in rendered {
                out[kind] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            self?.images = out
        }
    }
}
