import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 画布在视图里的摆放：成品像素 ↔ 视图坐标。
struct CollageCanvasLayout {
    /// 画布在视图里占的矩形（等比适应、四周留白）。
    let rect: CGRect
    /// 视图点 / 成品像素。
    let scale: CGFloat

    init(rect: CGRect, scale: CGFloat) {
        self.rect = rect
        self.scale = scale
    }

    /// 编辑封面时画布区的两层摆放：image = 整张封面（封底 | 书脊 | 封面，带包边、出血）铺在视图里；edit = 封面那一页
    /// （格子、选中框、落点、命中都按它：几何是封面那一页自己的坐标，左上原点）。平常两个一样，都是这个跨页。
    @MainActor
    static func display(store: CollageStore, in size: CGSize) -> (image: CollageCanvasLayout, edit: CollageCanvasLayout) {
        if store.editingCover, let cover = store.coverLayout {
            let whole = CollageCanvas(name: "封面", width: max(1, cover.width), height: max(1, cover.height))
            let image = CollageCanvasLayout(canvas: whole, in: size)
            return (image, CollageCanvasLayout(rect: image.toView(cover.front), scale: image.scale))
        }
        let layout = CollageCanvasLayout(canvas: store.project.canvas, in: size)
        return (layout, layout)
    }

    init(canvas: CollageCanvas, in size: CGSize, padding: CGFloat = 28) {
        let availW = max(10, size.width - padding * 2)
        let availH = max(10, size.height - padding * 2)
        let cw = CGFloat(max(1, canvas.width))
        let ch = CGFloat(max(1, canvas.height))
        let s = min(availW / cw, availH / ch)
        let w = cw * s
        let h = ch * s
        rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        scale = s
    }

    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / scale, y: (p.y - rect.minY) / scale)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale,
               width: r.width * scale, height: r.height * scale)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale)
    }
}

/// 选中图层的两个把手（视图坐标）：上方的旋转、右下角的缩放。
struct CollageItemHandles {
    let center: CGPoint
    let topCenter: CGPoint
    let rotate: CGPoint
    let resize: CGPoint
    let corners: [CGPoint]

    init(item: CollageItem, canvas: CollageCanvas, layout: CollageCanvasLayout) {
        let pts = CollageItems.corners(item, canvas: canvas).map { layout.toView($0) }
        corners = pts
        center = layout.toView(CollageItems.center(item, canvas: canvas))
        let top = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        topCenter = top
        let dx = top.x - center.x
        let dy = top.y - center.y
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        rotate = CGPoint(x: top.x + dx / len * 24, y: top.y + dy / len * 24)
        resize = pts[2]
    }
}

/// 拖进画布时落在哪：哪个格子、中间（替换/互换）还是哪条边（劈开插入）。
struct CollageDropTarget: Equatable {
    var path: [Int]
    var edge: CollageLayout.Edge?
}

enum CollageHit {
    case gutter(CollageLayout.Gutter)
    case cell(CollageLayout.Frame)
    case item(CollageItem)
    case rotateHandle(CollageItem)
    case resizeHandle(CollageItem)
    /// 选中格子上压的第几个字块（拖它换位置）。
    case overlay(CollageLayout.Frame, Int, CGRect)
    case none

    /// 图层在格子、缝之上：先看选中图层的把手，再从最上面一层往下找，再看压字，最后才是缝和格子。
    @MainActor
    static func at(_ p: CGPoint, store: CollageStore, geometry: CollageLayout.Geometry,
                   layout: CollageCanvasLayout) -> CollageHit {
        let canvas = store.project.canvas
        if let selected = store.selectedItemValue {
            let h = CollageItemHandles(item: selected, canvas: canvas, layout: layout)
            if hypot(p.x - h.rotate.x, p.y - h.rotate.y) < 10 { return .rotateHandle(selected) }
            if hypot(p.x - h.resize.x, p.y - h.resize.y) < 10 { return .resizeHandle(selected) }
        }
        let c = layout.toCanvas(p)
        let slop = 3 / max(0.01, layout.scale)
        for item in store.items.reversed() where CollageItems.hits(item, point: c, canvas: canvas, slop: slop) {
            return .item(item)
        }
        if let path = store.selection, let frame = geometry.frames.first(where: { $0.path == path }),
           !frame.cell.overlays.isEmpty {
            let placed = store.overlayPlacements(for: frame)
            let hits = placed.indices.reversed().filter { i in
                placed[i]?.rect.insetBy(dx: -slop * 2, dy: -slop * 2).contains(c) == true
            }
            // 叠在一起时先认正在编辑的那一个（拖它不会被压在上面的那块抢走），再从最上面一层往下找。
            if let i = hits.first(where: { $0 == store.overlayIndex }) ?? hits.first, let p = placed[i] {
                return .overlay(frame, i, p.rect)
            }
        }
        return at(p, geometry: geometry, layout: layout)
    }

    /// 点到哪：缝优先（缝很窄，按视图点外扩几个点），再是格子。
    static func at(_ p: CGPoint, geometry: CollageLayout.Geometry, layout: CollageCanvasLayout) -> CollageHit {
        let c = layout.toCanvas(p)
        let slop = 6 / max(0.01, layout.scale)
        for g in geometry.gutters {
            let r = g.rect.cgRect
            let hitRect = g.axis == .row ? r.insetBy(dx: -slop, dy: 0) : r.insetBy(dx: 0, dy: -slop)
            if hitRect.contains(c) { return .gutter(g) }
        }
        for f in geometry.frames where f.rect.cgRect.contains(c) {
            return .cell(f)
        }
        return .none
    }

    /// 落点：格子外圈 22% 算边（劈开插入），中间算替换。
    static func dropTarget(_ p: CGPoint, geometry: CollageLayout.Geometry, layout: CollageCanvasLayout,
                           excluding source: [Int]?) -> CollageDropTarget? {
        let c = layout.toCanvas(p)
        guard let f = geometry.frames.first(where: { $0.rect.cgRect.contains(c) }), f.path != source else { return nil }
        let r = f.rect.cgRect
        let u = Double((c.x - r.minX) / max(1, r.width))
        let v = Double((c.y - r.minY) / max(1, r.height))
        let edges: [(CollageLayout.Edge, Double)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        let nearest = edges.min { $0.1 < $1.1 }!
        if nearest.1 < 0.22 { return CollageDropTarget(path: f.path, edge: nearest.0) }
        return CollageDropTarget(path: f.path, edge: nil)
    }
}

struct CollageCanvasView: View {
    @ObservedObject var store: CollageStore
    /// 双击文字格、手写字、照片上的字：检视器切到「格式」、滚到那个编辑器（textEditor / overlays）。
    var onEditText: (CollageSpot) -> Void = { _ in }
    /// 用户在画布上选中了一样东西（格子、字块、图层）：检视器切到「格式」（NU3）。点空白处不调。
    /// 只接手势：撤销恢复的选中、实时桥、命令行设的选中不切页签（正在样式页拖滑杆时按 ⌘Z 不该被拽走）。
    var onSelect: () -> Void = {}
    /// 空画布中间的「自动排版」/「自动编排」（顶栏那个按钮的同一条路）。
    var onAutoLayout: () -> Void = {}
    /// 画布的缩放和平移（store.workspace.zoom）。
    @ObservedObject private var zoom: CollageCanvasZoom

    init(store: CollageStore, onEditText: @escaping (CollageSpot) -> Void = { _ in }, onSelect: @escaping () -> Void = {},
         onAutoLayout: @escaping () -> Void = {}) {
        self.store = store
        self.onEditText = onEditText
        self.onSelect = onSelect
        self.onAutoLayout = onAutoLayout
        self.zoom = store.workspace.zoom
    }

    private enum DragMode {
        case gutter(CollageLayout.Gutter)
        case move([Int])
        case pan([Int], CollageCropOverride, CollageLayout.Frame)
        case item(CollageItem)
        case rotate(CollageItem, CGPoint)
        case resize(CollageItem, CGPoint, CGFloat)
        case overlay([Int], Int, CGRect, CGPoint)
    }

    @State private var dragMode: DragMode?
    @State private var dropTarget: CollageDropTarget?
    @State private var hoverGutter: CollageLayout.Gutter?
    @State private var magnifyBase: CollageCropOverride?
    /// 捏合放大画布（不在调裁切时）：起手时的缩放。
    @State private var zoomBase: CGFloat?
    /// 拖着一格照片时指针在哪（视图坐标）：跟手画一张半透明的小图。
    @State private var dragPoint: CGPoint?
    /// 右键「移到第…个跨页（填号）…」的小框、点的是哪一格。
    @State private var askNumber = false
    @State private var menuPath: [Int]?
    @FocusState private var focused: Bool

    var body: some View {
        let _ = CollagePerf.body("画布")
        GeometryReader { geo in
            // 编辑封面：图是整张封面，格子按封面那一页（CollageCanvasLayout.display）。
            // 放大 / 平移（zoom）：两层摆放一起放大，下面的命中、落点、选中框都按放大后的 layout，不用另外换算。
            let fit = CollageCanvasLayout.display(store: store, in: geo.size)
            let pan = CollageCanvasZoom.clamp(zoom.offset, scale: zoom.scale, fitRect: fit.image.rect, viewSize: geo.size)
            let display = (image: fit.image.zoomed(zoom.scale, offset: pan, in: geo.size),
                           edit: fit.edit.zoomed(zoom.scale, offset: pan, in: geo.size))
            let layout = display.edit
            let geometry = store.geometry
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                AppPalette.canvas
                canvasImage(display.image)
                CollageCanvasOverlay(store: store, layout: layout, geometry: geometry,
                                     dropTarget: dropTarget, hoverGutter: hoverGutter)
                    .allowsHitTesting(false)
                if store.root == nil {
                    emptyHint
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if store.editingCover {
                    coverHint.frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                }
                if case .move(let source) = dragMode, let p = dragPoint {
                    dragGhost(source, at: p, layout: layout, geometry: geometry)
                }
            }
            // 放大以后画布比视图大：ZStack 会跟着最大的那张图长大，先定回视图这么大再裁，别画到两边的栏、底下的条上去。
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            // 右键：选中的那一样的常用操作（垫在底下、点击穿过去；右键由它自己的监听接，CollageContextMenuAnchor）。
            .background(CollageContextMenuAnchor { p in contextMenu(at: p, layout: layout, geometry: geometry) })
            // 滚轮：按着 ⌘ / ⌥ = 在指针处缩放；放大以后 = 平移；没放大的普通滚动不拦。
            .background(CollageScrollAnchor { delta, p, zooming in scroll(delta, at: p, zooming: zooming) })
            .contentShape(Rectangle())
            .gesture(singleTapGesture(layout: layout, geometry: geometry))
            .simultaneousGesture(doubleTapGesture(layout: layout, geometry: geometry))
            .simultaneousGesture(dragGesture(layout: layout, geometry: geometry, origin: origin))
            .simultaneousGesture(magnifyGesture(geometry: geometry))
            .onAppear { recordZoom(fit.image, in: geo.size) }
            .onChange(of: fit.image.rect) { _, _ in recordZoom(fit.image, in: geo.size) }
            .onChange(of: geo.size) { _, _ in recordZoom(fit.image, in: geo.size) }
            .onChange(of: zoom.scale) { _, _ in reportViewport(display.image) }
            // 换了画布（另一个尺寸、印厂规格、单张 ↔ 相册）、进出封面编辑：回到适应（放大着的那一块在新画布上不是同一个地方）。
            .onChange(of: store.project.canvas) { _, _ in zoom.fit() }
            .onChange(of: store.editingCover) { _, _ in zoom.fit() }
            .onContinuousHover { phase in
                hover(phase, layout: layout, geometry: geometry)
            }
            .onDrop(of: [.text, .fileURL], delegate: CollageCanvasDropDelegate(
                store: store, layout: layout, geometry: geometry, isFreeform: store.isFreeform,
                canvas: store.editCanvas, target: $dropTarget))
            .onAppear { reportViewport(display.image) }
            .onChange(of: geo.size) { _, _ in reportViewport(display.image) }
            .onChange(of: store.project.canvas) { _, _ in reportViewport(display.image) }
            // 进出封面编辑、书脊宽变了：整张封面的比例不一样，视口跟着报（封面预览按它算缩放）。
            .onChange(of: store.editingCover) { _, _ in reportViewport(display.image) }
            .onChange(of: store.coverLayout) { _, _ in reportViewport(display.image) }
            // 缩放小条盖在手势层外面（优化分析 R12）：以前它是手势层里的一个孩子，连点「+」两下同时被画布的双击手势
            // （simultaneousGesture）认成双击，进了它底下那一格的裁切。挂成这一层之后的 overlay，点它不经过画布的手势。
            .overlay(alignment: .bottomTrailing) {
                if store.root != nil {
                    CollageZoomBar(zoom: zoom).padding(10)
                }
            }
        }
        // 「填跨页号」小框挂在焦点修饰之前（同别处的弹框：挂在 .focusable() 后面有时弹不出来）。
        .collageMoveNumberAlert(store: store, isPresented: $askNumber, path: menuPath)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // ⌘← ⌘→ 是换跨页（拼图页的按键监听，CollageAlbumUI.swift）：带 ⌘ 的不当成切备选。
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in
            press.modifiers.contains(.command) ? .ignored : keyArrow(-1)
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in
            press.modifiers.contains(.command) ? .ignored : keyArrow(1)
        }
        .onKeyPress(.upArrow) { keyNudge(dx: 0, dy: -1) }
        .onKeyPress(.downArrow) { keyNudge(dx: 0, dy: 1) }
        .onKeyPress(.escape) { keyEscape() }
        .onKeyPress(.delete) { keyDelete() }
        .onKeyPress(.deleteForward) { keyDelete() }
        // ⌘= ⌘- 是画布缩放（顶栏那组快捷键）：带 ⌘ 的不当成裁切缩放。
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-")) { press in
            press.modifiers.contains(.command) ? .ignored : keyZoom(press.characters)
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "[]")) { press in
            keyRotate(press.characters)
        }
        // Q / A：左页上一种 / 下一种切法；W / S：右页（相册网格跨页，编辑封面时不接）。
        .onKeyPress(characters: CharacterSet(charactersIn: "qawsQAWS")) { press in
            keySide(press)
        }
        // 实时桥（§9.6b 的 dragging）：正在拖 / 捏合时 AI 的拼图写等用户松手。只往 store 上记，界面不变。
        // DragMode 带关联值、不是 Equatable，只能看「有没有」
        .onChange(of: gestureActive) { _, active in store.liveCanvasDragging = active }
        .onDisappear { store.liveCanvasDragging = false }
    }

    /// 画布上正在拖动或捏合（实时桥用）。
    private var gestureActive: Bool { dragMode != nil || magnifyBase != nil }

    // MARK: - 画布缩放

    /// 适应时的几何记给 zoom（顶栏快捷键、右下角小条、滚轮都按它算）；视图大小变了平移跟着夹。
    private func recordZoom(_ fitImage: CollageCanvasLayout, in size: CGSize) {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        zoom.record(viewSize: size, fitRect: fitImage.rect, fitPixelRatio: fitImage.scale * backing)
        zoom.reclamp()
    }

    private func scroll(_ delta: CGSize, at p: CGPoint, zooming: Bool) -> Bool {
        guard store.root != nil else { return false }
        if zooming {
            // 往上滚 = 放大。一下滚得再多也只算 ±40 点（鼠标滚轮带惯性时别一下放到头）。
            let d = max(-40, min(40, delta.height))
            zoom.zoom(to: zoom.scale * exp(d * 0.01), anchor: p)
            return true
        }
        guard !zoom.isFit else { return false }
        zoom.pan(by: delta)
        return true
    }

    // MARK: - 画面

    private func canvasImage(_ layout: CollageCanvasLayout) -> some View {
        CollageCanvasImage(preview: store.previewState, rect: layout.rect)
    }

    /// 编辑封面时画布底下一行：书脊、封底去哪改，怎么回到跨页。
    private var coverHint: some View {
        Text("封面：点格子选中、拖照片换、双击改字 · 书脊、封底在右栏「文档 › 封面」· 点跨页条上的跨页回去")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .allowsHitTesting(false)
    }

    /// 右键点在 p：先选中点到的那一样（看得见点的是哪个），再给它的菜单（CollageCanvasMenus.swift）。
    private func contextMenu(at p: CGPoint, layout: CollageCanvasLayout, geometry: CollageLayout.Geometry) -> NSMenu? {
        guard store.root != nil else { return nil }
        focused = true
        return Self.contextMenu(at: p, store: store, layout: layout, geometry: geometry, onSelect: onSelect,
                                onEditText: onEditText) { path in
            menuPath = path
            askNumber = true
        }
    }

    /// 同上，不碰视图状态（命令行 --menu-at 也走它）。
    static func contextMenu(at p: CGPoint, store: CollageStore, layout: CollageCanvasLayout,
                            geometry: CollageLayout.Geometry, onSelect: () -> Void,
                            onEditText: @escaping (CollageSpot) -> Void, ask: @escaping ([Int]) -> Void) -> NSMenu? {
        switch CollageHit.at(p, store: store, geometry: geometry, layout: layout) {
        case .item(let item), .rotateHandle(let item), .resizeHandle(let item):
            store.selectItem(item.id)
            onSelect()
            return CollageCanvasMenu.item(store: store, item: item, editText: onEditText)
        case .overlay(let f, let i, _):
            store.selection = f.path
            store.overlayIndex = i
            onSelect()
            return CollageCanvasMenu.cell(store: store, frame: f, editText: onEditText) { ask(f.path) }
        case .cell(let f):
            if store.cropEditing, store.selection != f.path { store.exitCropEdit() }
            store.selection = f.path
            onSelect()
            return CollageCanvasMenu.cell(store: store, frame: f, editText: onEditText) { ask(f.path) }
        case .gutter(let g):
            return CollageCanvasMenu.gutter(store: store, gutter: g)
        case .none:
            return CollageCanvasMenu.page(store: store)
        }
    }

    /// 空画布：托盘也空着 = 几个能点的入口（带精选、添加文件）；托盘有照片 = 一个「自动排版」。
    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.offgrid")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            if store.project.photos.isEmpty {
                Text("先带几张照片进来").foregroundStyle(.secondary)
                if let batch = store.batch {
                    CollageEmptyActions(store: store, batch: batch)
                } else {
                    CollageAddFilesButton(store: store).controlSize(.large)
                }
                Text("也可以把照片文件直接拖进来 · 批量页多选后点「拼图」也能带过来")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 相册的按钮叫「自动编排」（NU7：以前提示一律说「自动排版」，相册里找不到这个按钮）。
                Text("托盘里有 \(store.project.photos.count) 张照片").foregroundStyle(.secondary)
                Button(action: onAutoLayout) {
                    Label(store.isAlbum ? "自动编排" : "自动排版", systemImage: "wand.and.stars").frame(minWidth: 140)
                }
                .buttonStyle(.accentProminent)
                .controlSize(.large)
                .disabled(store.isSolving)
                Text("或者把托盘里的照片拖进来 · 左栏「模板」里套一个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 拖着一格时跟手的小图（半透明）：以前只有落点高亮，被拖的那张原地不动，看不出「正拖着它」。
    @ViewBuilder
    private func dragGhost(_ source: [Int], at p: CGPoint, layout: CollageCanvasLayout,
                           geometry: CollageLayout.Geometry) -> some View {
        if let frame = geometry.frames.first(where: { $0.path == source }) {
            let r = layout.toView(frame.rect.cgRect)
            let k = min(1, 150 / max(1, max(r.width, r.height)))
            let w = max(24, r.width * k)
            let h = max(24, r.height * k)
            Group {
                if let id = frame.cell.photoID, let photo = store.photoMap[id] {
                    ThumbnailView(path: photo.quickPath, maxPixel: 256)
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(white: 0.92)
                        Image(systemName: frame.cell.kind == .text ? "textformat" : "square.dashed")
                            .foregroundStyle(.gray)
                    }
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            .opacity(0.82)
            .offset(x: p.x - w / 2, y: p.y - h / 2)
            .allowsHitTesting(false)
        }
    }

    /// 预览渲多大：适应时 = 画布在屏幕上占的像素；放大了按缩放档（√2 一档）往上渲，最多 1600 万像素
    /// （30×30 的相册实际像素是 2500 万，一帧渲不动；再往里放就是这张放大了看）。
    private func reportViewport(_ layout: CollageCanvasLayout) {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let z = max(1, zoom.scale)
        let k = CollageCanvasZoom.renderBucket(z) / z
        var w = layout.rect.width * backing * k
        var h = layout.rect.height * backing * k
        let limit: CGFloat = 16_000_000
        if w * h > limit {
            let shrink = (limit / (w * h)).squareRoot()
            w *= shrink
            h *= shrink
        }
        store.setViewport(pixels: CGSize(width: w, height: h))
    }

    // MARK: - 点击

    /// 单击立刻选中：以前「双击优先、单击排在后面」，每一下单击都要等双击超时（0.3–0.5 秒）才选上。
    /// 双击的第二下（clickCount = 2）在这里就按双击处理，另外还挂了一个同时识别的双击手势兜底 ——
    /// 两边都可能走到 doubleTap，它是幂等的（进裁切、切到「格式」的文字编辑器，做两次和一次一样）。
    private func singleTapGesture(layout: CollageCanvasLayout, geometry: CollageLayout.Geometry) -> some Gesture {
        SpatialTapGesture(count: 1).onEnded { value in
            if Self.currentClickCount() >= 2 {
                doubleTap(value.location, layout: layout, geometry: geometry)
            } else {
                singleTap(value.location, layout: layout, geometry: geometry)
            }
        }
    }

    private func doubleTapGesture(layout: CollageCanvasLayout, geometry: CollageLayout.Geometry) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in doubleTap(value.location, layout: layout, geometry: geometry) }
    }

    /// 正在处理的这下鼠标是第几击（双击的第二下 = 2）。只读鼠标按键事件 —— 别的事件读 clickCount 会抛异常。
    private static func currentClickCount() -> Int {
        guard let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .leftMouseUp else { return 1 }
        return e.clickCount
    }

    private func singleTap(_ p: CGPoint, layout: CollageCanvasLayout, geometry: CollageLayout.Geometry) {
        focused = true
        switch CollageHit.at(p, store: store, geometry: geometry, layout: layout) {
        case .item(let item), .rotateHandle(let item), .resizeHandle(let item):
            store.selectItem(item.id)
            onSelect()
        case .overlay(let f, let i, _):
            store.selection = f.path
            store.overlayIndex = i
            onSelect()
        case .gutter(let g):
            if NSEvent.modifierFlags.contains(.option) { store.flipGutter(g.path) }
        case .cell(let f):
            if store.cropEditing, store.selection != f.path { store.exitCropEdit() }
            store.selection = f.path
            onSelect()
        case .none:
            store.exitCropEdit()
            store.selection = nil
            store.selectItem(nil)
        }
    }

    private func doubleTap(_ p: CGPoint, layout: CollageCanvasLayout, geometry: CollageLayout.Geometry) {
        focused = true
        let hit = CollageHit.at(p, store: store, geometry: geometry, layout: layout)
        if case .item(let item) = hit {
            store.selectItem(item.id)
            onSelect()
            if item.kind == .text { onEditText(.textEditor) }
            return
        }
        if case .overlay(let f, let i, _) = hit {
            store.selection = f.path
            store.overlayIndex = i
            onEditText(.overlays)
            return
        }
        guard case .cell(let f) = hit else { return }
        switch f.cell.kind {
        case .photo:
            if f.cell.photoID != nil { store.enterCropEdit(f.path) }
        case .text:
            store.selection = f.path
            onEditText(.textEditor)
        case .empty:
            store.selection = f.path
        }
        onSelect()
    }

    // MARK: - 拖动：拖缝 / 挪格子 / 裁切平移

    /// origin：画布在窗口里的左上角（.global）—— 拖一格照片出了画布、指到跨页条的卡片上时按它换算（跨页条记着自己在窗口里的位置）。
    private func dragGesture(layout: CollageCanvasLayout, geometry: CollageLayout.Geometry,
                             origin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                if dragMode == nil { dragMode = beginDrag(at: value.startLocation, layout: layout, geometry: geometry) }
                updateDrag(value, layout: layout, geometry: geometry, origin: origin)
            }
            .onEnded { _ in endDrag() }
    }

    private func beginDrag(at p: CGPoint, layout: CollageCanvasLayout,
                           geometry: CollageLayout.Geometry) -> DragMode? {
        focused = true
        // 裁切模式：在选中格里起手一律算平移（缝的命中区外扩了几个点，贴着格子边拖会误拖缝）。
        if store.cropEditing, let path = store.selection,
           let f = geometry.frames.first(where: { $0.path == path }),
           f.rect.cgRect.contains(layout.toCanvas(p)), let base = store.cropBaseline(for: f) {
            return .pan(f.path, base, f)
        }
        let hit = CollageHit.at(p, store: store, geometry: geometry, layout: layout)
        switch hit {
        case .item(let item):
            store.selectItem(item.id)
            onSelect()
            store.beginContinuousEdit()
            return .item(item)
        case .rotateHandle(let item):
            store.beginContinuousEdit()
            return .rotate(item, CollageItemHandles(item: item, canvas: store.project.canvas, layout: layout).center)
        case .resizeHandle(let item):
            store.beginContinuousEdit()
            let center = CollageItemHandles(item: item, canvas: store.project.canvas, layout: layout).center
            return .resize(item, center, max(4, hypot(p.x - center.x, p.y - center.y)))
        case .overlay(let f, let i, let rect):
            store.selection = f.path
            store.overlayIndex = i
            onSelect()
            store.beginContinuousEdit()
            return .overlay(f.path, i, store.overlayArea(for: f), CGPoint(x: rect.midX, y: rect.midY))
        case .gutter(let g):
            store.beginContinuousEdit()
            return .gutter(g)
        case .cell(let f):
            guard f.cell.kind != .empty || f.cell.photoID != nil else { return nil }
            if store.cropEditing { store.exitCropEdit() }
            store.selection = f.path
            onSelect()
            return .move(f.path)
        case .none:
            return nil
        }
    }

    private func updateDrag(_ value: DragGesture.Value, layout: CollageCanvasLayout, geometry: CollageLayout.Geometry,
                            origin: CGPoint) {
        guard let mode = dragMode else { return }
        switch mode {
        case .gutter(let g):
            let c = layout.toCanvas(value.location)
            let position = g.axis == .row ? Double(c.x) : Double(c.y)
            // 这条缝自己的宽度（相册设了四边边距时中缝比别的缝宽：两页的内边距）。
            let gutterWidth = g.axis == .row ? g.rect.width : g.rect.height
            let minPixels = store.editCanvas.shortSide * 0.06
            let ratio = CollageLayout.ratio(forDrag: position, gutter: g, gutterWidth: gutterWidth, minPixels: minPixels)
            store.setRatio(ratio, at: g.path)
        case .move(let source):
            dragPoint = value.location
            // 拖出画布、指到跨页条的卡片上：松手 = 挪到那个跨页（S1 moveCells）；卡片描边，画布上不画落点。
            let global = CGPoint(x: value.location.x + origin.x, y: value.location.y + origin.y)
            let hover = spreadTarget(source, at: global)
            if store.albumUI.stripHover != hover { store.albumUI.stripHover = hover }
            dropTarget = hover == nil
                ? CollageHit.dropTarget(value.location, geometry: geometry, layout: layout, excluding: source) : nil
        case .pan(let path, let base, let frame):
            pan(path: path, base: base, frame: frame, translation: value.translation, layout: layout)
        case .item(let base):
            let canvas = store.project.canvas
            let dx = Double(value.translation.width / layout.scale) / Double(canvas.width)
            let dy = Double(value.translation.height / layout.scale) / Double(canvas.height)
            store.setItemGeometry(base.id) { item in
                item.cx = min(1.3, max(-0.3, base.cx + dx))
                item.cy = min(1.3, max(-0.3, base.cy + dy))
            }
        case .rotate(let base, let center):
            let a0 = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x)
            let a1 = atan2(value.location.y - center.y, value.location.x - center.x)
            var deg = base.rotation + Double(a1 - a0) * 180 / .pi
            // 靠近 0° 吸一下：摆正比摆斜难。
            if abs(deg) < 1.5 { deg = 0 }
            store.setItemGeometry(base.id) { $0.rotation = deg.rounded() }
        case .resize(let base, let center, let startDist):
            let d = hypot(value.location.x - center.x, value.location.y - center.y)
            let k = Double(max(0.15, min(6, d / startDist)))
            store.setItemGeometry(base.id) { item in
                item.width = max(0.015, base.width * k)
                item.height = max(0.008, base.height * k)
            }
        case .overlay(let path, let index, let area, let startCenter):
            let cx = startCenter.x + value.translation.width / layout.scale
            let cy = startCenter.y + value.translation.height / layout.scale
            let x = Double((cx - area.minX) / max(1, area.width))
            let y = Double((cy - area.minY) / max(1, area.height))
            store.setOverlayPosition(x: x, y: y, at: path, index: index)
        }
    }

    /// 拖动方向 = 画面跟手：往右拖，照片往右走，取景窗口往左挪。
    private func pan(path: [Int], base: CollageCropOverride, frame: CollageLayout.Frame, translation: CGSize,
                     layout: CollageCanvasLayout) {
        guard let id = frame.cell.photoID, let photo = store.photoMap[id] else { return }
        let area = store.photoArea(for: frame)
        let maxW = CollageCrop.maxWindow(photoAspect: photo.aspect, cellAspect: CollageCrop.aspect(of: area))
        let zoom = max(1, base.zoom)
        let winW = maxW.w / zoom
        let winH = maxW.h / zoom
        let cellW = Double(area.width) * Double(layout.scale)
        let cellH = Double(area.height) * Double(layout.scale)
        let dx = Double(translation.width) / max(1, cellW) * winW
        let dy = Double(translation.height) / max(1, cellH) * winH
        let cx = min(1 - winW / 2, max(winW / 2, base.cx - dx))
        let cy = min(1 - winH / 2, max(winH / 2, base.cy - dy))
        store.setCrop(CollageCropOverride(cx: cx, cy: cy, zoom: zoom), at: path)
    }

    /// 这一格拖到窗口里的 point（.global）时指着跨页条上的第几个跨页（只对相册里的照片格、不在编辑封面）。
    private func spreadTarget(_ source: [Int], at point: CGPoint) -> Int? {
        guard store.isAlbum, CollageAlbumRules.allows(.moveToSpread, editingCover: store.editingCover),
              store.root?.node(at: source)?.cell?.photoID != nil,
              let page = store.albumUI.stripTarget(at: point), store.project.pages.indices.contains(page) else { return nil }
        return page
    }

    private func endDrag() {
        defer {
            dragMode = nil
            dragPoint = nil
            dropTarget = nil
            if store.albumUI.stripHover != nil { store.albumUI.stripHover = nil }
        }
        guard let mode = dragMode else { return }
        switch mode {
        case .gutter, .item, .rotate, .resize, .overlay:
            store.endContinuousEdit()
        case .move(let source):
            // 松手时指着跨页条上别的跨页：挪过去（两边在后台重排，那张卡片上转圈）。
            if let page = store.albumUI.stripHover {
                guard page != store.pageIndex, store.project.pages.indices.contains(page) else { return }
                let id = store.project.pages[page].id
                store.moveCells([source], toPage: page)
                store.albumUI.pendingPage = store.isSolving ? id : nil
                return
            }
            guard let target = dropTarget else { return }
            if let edge = target.edge {
                store.move(from: source, to: target.path, edge: edge)
            } else {
                store.swap(source, target.path)
            }
        case .pan:
            break
        }
    }

    // MARK: - 捏合缩放（裁切模式）

    private func magnifyGesture(geometry: CollageLayout.Geometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard store.cropEditing, let path = store.selection,
                      let frame = geometry.frames.first(where: { $0.path == path }) else {
                    // 不在调裁切：捏合 = 放大画布，手指中间那一点不动。
                    guard store.root != nil else { return }
                    if zoomBase == nil { zoomBase = zoom.scale }
                    zoom.zoom(to: (zoomBase ?? 1) * value.magnification, anchor: value.startLocation)
                    return
                }
                if magnifyBase == nil { magnifyBase = store.cropBaseline(for: frame) }
                guard let base = magnifyBase else { return }
                let zoom = min(8, max(1, base.zoom * Double(value.magnification)))
                store.setCrop(CollageCropOverride(cx: base.cx, cy: base.cy, zoom: zoom), at: path)
            }
            .onEnded { _ in
                magnifyBase = nil
                zoomBase = nil
            }
    }

    // MARK: - 悬停：缝上换光标

    private func hover(_ phase: HoverPhase, layout: CollageCanvasLayout, geometry: CollageLayout.Geometry) {
        switch phase {
        case .active(let p):
            if case .gutter(let g) = CollageHit.at(p, store: store, geometry: geometry, layout: layout) {
                if hoverGutter != g {
                    hoverGutter = g
                    (g.axis == .row ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                }
            } else if hoverGutter != nil {
                hoverGutter = nil
                NSCursor.arrow.set()
            }
        case .ended:
            if hoverGutter != nil {
                hoverGutter = nil
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: - 键盘

    private func keyArrow(_ delta: Int) -> KeyPress.Result {
        if store.cropEditing || store.selectedItem != nil { return keyNudge(dx: Double(delta), dy: 0) }
        if delta > 0 { store.nextAlternative() } else { store.previousAlternative() }
        return .handled
    }

    private func keyNudge(dx: Double, dy: Double) -> KeyPress.Result {
        if let id = store.selectedItem {
            // 选中图层：方向键挪 0.4%（和拖动同方向）。
            store.updateItem(id, coalesce: true) { item in
                item.cx += dx * 0.004
                item.cy += dy * 0.004
            }
            return .handled
        }
        guard store.cropEditing, let path = store.selection,
              let frame = store.geometry.frames.first(where: { $0.path == path }),
              let base = store.cropBaseline(for: frame) else { return .ignored }
        // 和拖动同一个方向：按 → 照片往右走（取景窗口往左挪）。
        let step = 0.02 / max(1, base.zoom)
        store.setCrop(CollageCropOverride(cx: base.cx - dx * step, cy: base.cy - dy * step, zoom: base.zoom), at: path)
        return .handled
    }

    /// Q / A、W / S：这个跨页的左页 / 右页换一种切法（CollageAlbumRules.sideKey）。
    private func keySide(_ press: KeyPress) -> KeyPress.Result {
        guard let key = CollageAlbumRules.sideKey(press.characters, modifiers: press.modifiers), store.isAlbum,
              CollageAlbumRules.allows(.sideLayout, editingCover: store.editingCover),
              let page = store.page, !page.freeform, page.contactSheet == nil,
              store.project.canvas.seams == .fold else { return .ignored }
        store.cycleSideLayout(key.side, step: key.step)
        return .handled
    }

    private func keyZoom(_ chars: String) -> KeyPress.Result {
        guard store.cropEditing, let path = store.selection,
              let frame = store.geometry.frames.first(where: { $0.path == path }),
              let base = store.cropBaseline(for: frame) else { return .ignored }
        let factor = chars == "-" ? 1 / 1.12 : 1.12
        let zoom = min(8, max(1, base.zoom * factor))
        store.setCrop(CollageCropOverride(cx: base.cx, cy: base.cy, zoom: zoom), at: path)
        return .handled
    }

    private func keyRotate(_ chars: String) -> KeyPress.Result {
        guard let id = store.selectedItem else { return .ignored }
        let step: Double = chars == "[" ? -2 : 2
        store.updateItem(id, coalesce: true) { $0.rotation += step }
        return .handled
    }

    private func keyEscape() -> KeyPress.Result {
        if store.selectedItem != nil {
            store.selectItem(nil)
            return .handled
        }
        if store.cropEditing {
            store.exitCropEdit()
            return .handled
        }
        if store.selection != nil {
            store.selection = nil
            return .handled
        }
        return .ignored
    }

    private func keyDelete() -> KeyPress.Result {
        if let id = store.selectedItem {
            store.deleteItem(id)
            return .handled
        }
        guard let path = store.selection, !store.cropEditing else { return .ignored }
        store.removeCell(path)
        return .handled
    }
}

/// 预览大图：只有它订阅 store.previewState —— 预览重渲一次只重画这一张图，画布的手势、叠加层不跟着重算。
private struct CollageCanvasImage: View {
    @ObservedObject var preview: CollagePreviewState
    let rect: CGRect

    /// 预览图的比例和画布区对得上（差 1.5% 以内）：刚进 / 出封面编辑时上一张（跨页 / 整张封面）还没换掉，比例不对就先画灰块，
    /// 不把上一张拉变形铺上去（跨页 2:1，整张封面多了书脊、包边，30×30 的册子差 3%）。
    private func fits(_ image: NSImage) -> Bool {
        guard rect.height > 0, image.size.height > 0 else { return false }
        let want = rect.width / rect.height
        let got = image.size.width / image.size.height
        return abs(got / want - 1) < 0.015
    }

    var body: some View {
        if let image = preview.image, fits(image) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                .offset(x: rect.minX, y: rect.minY)
        } else {
            Rectangle()
                .fill(Color(white: 0.22))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}

/// 叠加层：选中框、缝的拖动提示、落点、切脸/路人/锁定角标、裁切模式的人脸框和三分线。
/// 不接收点击（点击全在画布上统一命中测试）。
struct CollageCanvasOverlay: View {
    @ObservedObject var store: CollageStore
    let layout: CollageCanvasLayout
    let geometry: CollageLayout.Geometry
    let dropTarget: CollageDropTarget?
    let hoverGutter: CollageLayout.Gutter?

    var body: some View {
        let _ = CollagePerf.body("叠加层")
        let badges = store.canvasBadges()
        ZStack(alignment: .topLeading) {
            ForEach(geometry.frames, id: \.path) { frame in
                if let badge = badges[frame.path] {
                    badgeRow(badge, frame: frame)
                }
            }
            if let g = hoverGutter {
                gutterHighlight(g)
            }
            if let path = store.selection, let frame = geometry.frames.first(where: { $0.path == path }) {
                selectionOutline(frame)
                if store.cropEditing { cropGuides(frame) }
            }
            if let target = dropTarget, let frame = geometry.frames.first(where: { $0.path == target.path }) {
                dropHighlight(frame, edge: target.edge)
            }
            if let path = store.selection, !store.cropEditing,
               let frame = geometry.frames.first(where: { $0.path == path }), !frame.cell.overlays.isEmpty {
                // 每个字块一个虚框：正在编辑的那个实一点，别的淡一点（点一下切过去）。
                let placed = store.overlayPlacements(for: frame)
                ForEach(Array(placed.enumerated()), id: \.offset) { item in
                    if let p = item.element {
                        overlayBox(layout.toView(p.rect))
                            .opacity(item.offset == store.overlayIndex ? 1 : 0.45)
                    }
                }
            }
            if let item = store.selectedItemValue {
                itemSelection(CollageItemHandles(item: item, canvas: store.project.canvas, layout: layout))
            }
        }
    }

    /// 压字的范围：黑白双线虚框（深浅照片上都看得见）。
    private func overlayBox(_ r: CGRect) -> some View {
        let box = r.insetBy(dx: -4, dy: -4)
        return ZStack {
            Rectangle().stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, dash: [5, 4]))
            Rectangle().stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .frame(width: box.width, height: box.height)
        .offset(x: box.minX, y: box.minY)
    }

    /// 选中图层：旋转后的外框 + 旋转把手（上）+ 缩放把手（右下）。
    private func itemSelection(_ h: CollageItemHandles) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addLines(h.corners)
                path.closeSubpath()
                path.move(to: h.topCenter)
                path.addLine(to: h.rotate)
            }
            .stroke(AppPalette.accent, lineWidth: 2)
            handle(at: h.rotate)
            handle(at: h.resize)
        }
    }

    private func handle(at p: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(AppPalette.accent, lineWidth: 2))
            .frame(width: 12, height: 12)
            .offset(x: p.x - 6, y: p.y - 6)
    }

    private func viewRect(_ frame: CollageLayout.Frame) -> CGRect {
        layout.toView(frame.rect.cgRect)
    }

    private func selectionOutline(_ frame: CollageLayout.Frame) -> some View {
        let r = viewRect(frame)
        return Rectangle()
            .strokeBorder(AppPalette.accent, lineWidth: 2.5)
            .frame(width: r.width + 4, height: r.height + 4)
            .offset(x: r.minX - 2, y: r.minY - 2)
    }

    private func gutterHighlight(_ g: CollageLayout.Gutter) -> some View {
        let r = layout.toView(g.rect.cgRect)
        let isRow = g.axis == .row
        let w = isRow ? max(3, r.width) : r.width
        let h = isRow ? r.height : max(3, r.height)
        return Rectangle()
            .fill(AppPalette.accent.opacity(0.55))
            .frame(width: w, height: h)
            .offset(x: r.midX - w / 2, y: r.midY - h / 2)
    }

    @ViewBuilder
    private func dropHighlight(_ frame: CollageLayout.Frame, edge: CollageLayout.Edge?) -> some View {
        let r = viewRect(frame)
        if let edge {
            let bar = edgeBar(r, edge: edge)
            RoundedRectangle(cornerRadius: 2)
                .fill(AppPalette.accent)
                .frame(width: bar.width, height: bar.height)
                .offset(x: bar.minX, y: bar.minY)
        } else {
            Rectangle()
                .fill(AppPalette.accent.opacity(0.22))
                .overlay(Rectangle().strokeBorder(AppPalette.accent, lineWidth: 3))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
        }
    }

    private func edgeBar(_ r: CGRect, edge: CollageLayout.Edge) -> CGRect {
        let t: CGFloat = 6
        switch edge {
        case .left: return CGRect(x: r.minX, y: r.minY, width: t, height: r.height)
        case .right: return CGRect(x: r.maxX - t, y: r.minY, width: t, height: r.height)
        case .top: return CGRect(x: r.minX, y: r.minY, width: r.width, height: t)
        case .bottom: return CGRect(x: r.minX, y: r.maxY - t, width: r.width, height: t)
        }
    }

    /// 一格的角标（算哪些角标在 store.canvasBadges()：按工程、选中、路人信息和蒙版版本缓存）。
    private func badgeRow(_ b: CollageCanvasBadge, frame: CollageLayout.Frame) -> some View {
        let r = viewRect(frame)
        return HStack(spacing: 4) {
            if b.locked { badge("lock.fill", nil, .white) }
            if b.cutsFace { badge("exclamationmark.triangle.fill", "切脸", .red) }
            if b.bystander { badge("person.2.fill", "路人", .orange) }
            if let up = b.upscale { badge("plus.magnifyingglass", "放大\(Int((up * 100).rounded()))%", .orange) }
        }
        .offset(x: r.minX + 6, y: r.minY + 6)
    }

    private func badge(_ symbol: String, _ text: String?, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text) }
        }
        .font(.caption2.bold())
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.6), in: Capsule())
    }

    /// 裁切模式：三分线 + 人脸框，照着摆构图。
    @ViewBuilder
    private func cropGuides(_ frame: CollageLayout.Frame) -> some View {
        let r = viewRect(frame)
        ZStack(alignment: .topLeading) {
            Path { path in
                for k in 1...2 {
                    let x = r.minX + r.width * CGFloat(k) / 3
                    let y = r.minY + r.height * CGFloat(k) / 3
                    path.move(to: CGPoint(x: x, y: r.minY))
                    path.addLine(to: CGPoint(x: x, y: r.maxY))
                    path.move(to: CGPoint(x: r.minX, y: y))
                    path.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1)
            ForEach(Array(faceRects(frame, in: r).enumerated()), id: \.offset) { item in
                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 1.5)
                    .frame(width: item.element.width, height: item.element.height)
                    .offset(x: item.element.minX, y: item.element.minY)
            }
            Text("拖动平移 · 捏合或 +/- 缩放 · 方向键微调 · Esc 完成")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .offset(x: r.minX + 6, y: r.maxY - 26)
        }
    }

    private func faceRects(_ frame: CollageLayout.Frame, in r: CGRect) -> [CGRect] {
        guard let id = frame.cell.photoID, let photo = store.photoMap[id],
              let window = store.window(for: frame, waitForMask: false) else { return [] }
        let area = layout.toView(store.photoArea(for: frame))
        let drawn = CollageCrop.drawnRect(window: window, photo: photo, cell: frame.cell, in: area)
        return CollageCrop.faceBoxes(photo: photo, window: window, in: drawn)
    }
}

/// 托盘里的照片（文字 = 照片 id）、Finder 里的文件拖进画布。
struct CollageCanvasDropDelegate: DropDelegate {
    let store: CollageStore
    let layout: CollageCanvasLayout
    let geometry: CollageLayout.Geometry
    /// 建 delegate 时（主线程）取好：拖放回调在旧 SDK 上不保证在主 actor，不能同步读 store。
    let isFreeform: Bool
    let canvas: CollageCanvas
    @Binding var target: CollageDropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text, .fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [.text]), !isFreeform {
            target = CollageHit.dropTarget(info.location, geometry: geometry, layout: layout, excluding: nil)
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = target
        target = nil
        let c = layout.toCanvas(info.location)
        let point = CGPoint(x: c.x / CGFloat(max(1, canvas.width)), y: c.y / CGFloat(max(1, canvas.height)))
        if let provider = info.itemProviders(for: [.text]).first {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let id = object as? String else { return }
                Task { @MainActor in
                    // 印样：接在这一卷最后（先判它：渲染也是印样优先）。散落版：落点放一张相纸。
                    if store.isContactSheet {
                        store.addContactFrame(id)
                    } else if store.isFreeform {
                        store.addPhotoItem(id, at: point)
                    } else if let where_ {
                        store.place(photoID: id, at: where_.path, edge: where_.edge)
                    } else if store.root == nil {
                        // 空画布拖进第一张：按开关上的网格 / 散落排。
                        store.layoutFresh(photoIDs: [id])
                    }
                }
            }
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await Self.loadURL(p) { urls.append(url) }
            }
            store.addFiles(urls)
        }
        return true
    }

    static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
