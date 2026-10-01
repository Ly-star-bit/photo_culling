import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 画布在视图里的摆放：成品像素 ↔ 视图坐标。
struct CollageCanvasLayout {
    /// 画布在视图里占的矩形（等比适应、四周留白）。
    let rect: CGRect
    /// 视图点 / 成品像素。
    let scale: CGFloat

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
    /// 选中格子上压的字（拖它换位置）。
    case overlay(CollageLayout.Frame, CGRect)
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
        for item in store.items.reversed() where CollageItems.contains(item, point: c, canvas: canvas, slop: slop) {
            return .item(item)
        }
        if let path = store.selection, let frame = geometry.frames.first(where: { $0.path == path }),
           frame.cell.overlay != nil, let placement = store.overlayPlacement(for: frame),
           placement.rect.insetBy(dx: -slop * 2, dy: -slop * 2).contains(c) {
            return .overlay(frame, placement.rect)
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
    /// 双击文字格：让检视器切到「文字」。
    var onEditText: () -> Void = {}

    private enum DragMode {
        case gutter(CollageLayout.Gutter)
        case move([Int])
        case pan([Int], CollageCropOverride, CollageLayout.Frame)
        case item(CollageItem)
        case rotate(CollageItem, CGPoint)
        case resize(CollageItem, CGPoint, CGFloat)
        case overlay([Int], CGRect, CGPoint)
    }

    @State private var dragMode: DragMode?
    @State private var dropTarget: CollageDropTarget?
    @State private var hoverGutter: CollageLayout.Gutter?
    @State private var magnifyBase: CollageCropOverride?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let layout = CollageCanvasLayout(canvas: store.project.canvas, in: geo.size)
            let geometry = store.geometry
            ZStack(alignment: .topLeading) {
                Color(white: 0.14)
                canvasImage(layout)
                CollageCanvasOverlay(store: store, layout: layout, geometry: geometry,
                                     dropTarget: dropTarget, hoverGutter: hoverGutter)
                    .allowsHitTesting(false)
                if store.root == nil {
                    emptyHint
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(singleTapGesture(layout: layout, geometry: geometry))
            .simultaneousGesture(doubleTapGesture(layout: layout, geometry: geometry))
            .simultaneousGesture(dragGesture(layout: layout, geometry: geometry))
            .simultaneousGesture(magnifyGesture(geometry: geometry))
            .onContinuousHover { phase in
                hover(phase, layout: layout, geometry: geometry)
            }
            .onDrop(of: [.text, .fileURL], delegate: CollageCanvasDropDelegate(
                store: store, layout: layout, geometry: geometry, isFreeform: store.isFreeform,
                canvas: store.project.canvas, target: $dropTarget))
            .onAppear { reportViewport(layout) }
            .onChange(of: geo.size) { _, _ in reportViewport(layout) }
            .onChange(of: store.project.canvas) { _, _ in reportViewport(layout) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { keyArrow(-1) }
        .onKeyPress(.rightArrow) { keyArrow(1) }
        .onKeyPress(.upArrow) { keyNudge(dx: 0, dy: -1) }
        .onKeyPress(.downArrow) { keyNudge(dx: 0, dy: 1) }
        .onKeyPress(.escape) { keyEscape() }
        .onKeyPress(.delete) { keyDelete() }
        .onKeyPress(.deleteForward) { keyDelete() }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-")) { press in
            keyZoom(press.characters)
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "[]")) { press in
            keyRotate(press.characters)
        }
    }

    // MARK: - 画面

    @ViewBuilder
    private func canvasImage(_ layout: CollageCanvasLayout) -> some View {
        if let image = store.preview {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: layout.rect.width, height: layout.rect.height)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                .offset(x: layout.rect.minX, y: layout.rect.minY)
        } else {
            Rectangle()
                .fill(Color(white: 0.22))
                .frame(width: layout.rect.width, height: layout.rect.height)
                .offset(x: layout.rect.minX, y: layout.rect.minY)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.offgrid")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("把托盘里的照片拖进来，或点「自动排版」")
                .foregroundStyle(.secondary)
            Text("批量页多选后点「拼图」也能直接带过来")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func reportViewport(_ layout: CollageCanvasLayout) {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        store.setViewport(pixels: CGSize(width: layout.rect.width * backing, height: layout.rect.height * backing))
    }

    // MARK: - 点击

    /// 单击立刻选中：以前「双击优先、单击排在后面」，每一下单击都要等双击超时（0.3–0.5 秒）才选上。
    /// 双击的第二下（clickCount = 2）在这里就按双击处理，另外还挂了一个同时识别的双击手势兜底 ——
    /// 两边都可能走到 doubleTap，它是幂等的（进裁切、切到文字页，做两次和一次一样）。
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
        case .overlay(let f, _):
            store.selection = f.path
        case .gutter(let g):
            if NSEvent.modifierFlags.contains(.option) { store.flipGutter(g.path) }
        case .cell(let f):
            if store.cropEditing, store.selection != f.path { store.exitCropEdit() }
            store.selection = f.path
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
            if item.kind == .text { onEditText() }
            return
        }
        if case .overlay(let f, _) = hit {
            store.selection = f.path
            onEditText()
            return
        }
        guard case .cell(let f) = hit else { return }
        switch f.cell.kind {
        case .photo:
            if f.cell.photoID != nil { store.enterCropEdit(f.path) }
        case .text:
            store.selection = f.path
            onEditText()
        case .empty:
            store.selection = f.path
        }
    }

    // MARK: - 拖动：拖缝 / 挪格子 / 裁切平移

    private func dragGesture(layout: CollageCanvasLayout, geometry: CollageLayout.Geometry) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                if dragMode == nil { dragMode = beginDrag(at: value.startLocation, layout: layout, geometry: geometry) }
                updateDrag(value, layout: layout, geometry: geometry)
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
            store.beginContinuousEdit()
            return .item(item)
        case .rotateHandle(let item):
            store.beginContinuousEdit()
            return .rotate(item, CollageItemHandles(item: item, canvas: store.project.canvas, layout: layout).center)
        case .resizeHandle(let item):
            store.beginContinuousEdit()
            let center = CollageItemHandles(item: item, canvas: store.project.canvas, layout: layout).center
            return .resize(item, center, max(4, hypot(p.x - center.x, p.y - center.y)))
        case .overlay(let f, let rect):
            store.selection = f.path
            store.beginContinuousEdit()
            return .overlay(f.path, store.overlayArea(for: f), CGPoint(x: rect.midX, y: rect.midY))
        case .gutter(let g):
            store.beginContinuousEdit()
            return .gutter(g)
        case .cell(let f):
            guard f.cell.kind != .empty || f.cell.photoID != nil else { return nil }
            if store.cropEditing { store.exitCropEdit() }
            store.selection = f.path
            return .move(f.path)
        case .none:
            return nil
        }
    }

    private func updateDrag(_ value: DragGesture.Value, layout: CollageCanvasLayout, geometry: CollageLayout.Geometry) {
        guard let mode = dragMode else { return }
        switch mode {
        case .gutter(let g):
            let c = layout.toCanvas(value.location)
            let position = g.axis == .row ? Double(c.x) : Double(c.y)
            let gutterWidth = CollageLayout.gutterPixels(canvas: store.project.canvas, style: store.project.style)
            let minPixels = store.project.canvas.shortSide * 0.06
            let ratio = CollageLayout.ratio(forDrag: position, gutter: g, gutterWidth: gutterWidth, minPixels: minPixels)
            store.setRatio(ratio, at: g.path)
        case .move(let source):
            dropTarget = CollageHit.dropTarget(value.location, geometry: geometry, layout: layout, excluding: source)
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
        case .overlay(let path, let area, let startCenter):
            let cx = startCenter.x + value.translation.width / layout.scale
            let cy = startCenter.y + value.translation.height / layout.scale
            let x = Double((cx - area.minX) / max(1, area.width))
            let y = Double((cy - area.minY) / max(1, area.height))
            store.setOverlayPosition(x: x, y: y, at: path)
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

    private func endDrag() {
        defer {
            dragMode = nil
            dropTarget = nil
        }
        guard let mode = dragMode else { return }
        switch mode {
        case .gutter, .item, .rotate, .resize, .overlay:
            store.endContinuousEdit()
        case .move(let source):
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
                      let frame = geometry.frames.first(where: { $0.path == path }) else { return }
                if magnifyBase == nil { magnifyBase = store.cropBaseline(for: frame) }
                guard let base = magnifyBase else { return }
                let zoom = min(8, max(1, base.zoom * Double(value.magnification)))
                store.setCrop(CollageCropOverride(cx: base.cx, cy: base.cy, zoom: zoom), at: path)
            }
            .onEnded { _ in magnifyBase = nil }
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

/// 叠加层：选中框、缝的拖动提示、落点、切脸/路人/锁定角标、裁切模式的人脸框和三分线。
/// 不接收点击（点击全在画布上统一命中测试）。
struct CollageCanvasOverlay: View {
    @ObservedObject var store: CollageStore
    let layout: CollageCanvasLayout
    let geometry: CollageLayout.Geometry
    let dropTarget: CollageDropTarget?
    let hoverGutter: CollageLayout.Gutter?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(geometry.frames, id: \.path) { frame in
                badges(for: frame)
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
               let frame = geometry.frames.first(where: { $0.path == path }), frame.cell.overlay != nil,
               let placement = store.overlayPlacement(for: frame) {
                overlayBox(layout.toView(placement.rect))
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
            .stroke(Color.accentColor, lineWidth: 2)
            handle(at: h.rotate)
            handle(at: h.resize)
        }
    }

    private func handle(at p: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 12, height: 12)
            .offset(x: p.x - 6, y: p.y - 6)
    }

    private func viewRect(_ frame: CollageLayout.Frame) -> CGRect {
        layout.toView(frame.rect.cgRect)
    }

    private func selectionOutline(_ frame: CollageLayout.Frame) -> some View {
        let r = viewRect(frame)
        return Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .frame(width: r.width + 4, height: r.height + 4)
            .offset(x: r.minX - 2, y: r.minY - 2)
    }

    private func gutterHighlight(_ g: CollageLayout.Gutter) -> some View {
        let r = layout.toView(g.rect.cgRect)
        let isRow = g.axis == .row
        let w = isRow ? max(3, r.width) : r.width
        let h = isRow ? r.height : max(3, r.height)
        return Rectangle()
            .fill(Color.accentColor.opacity(0.55))
            .frame(width: w, height: h)
            .offset(x: r.midX - w / 2, y: r.midY - h / 2)
    }

    @ViewBuilder
    private func dropHighlight(_ frame: CollageLayout.Frame, edge: CollageLayout.Edge?) -> some View {
        let r = viewRect(frame)
        if let edge {
            let bar = edgeBar(r, edge: edge)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: bar.width, height: bar.height)
                .offset(x: bar.minX, y: bar.minY)
        } else {
            Rectangle()
                .fill(Color.accentColor.opacity(0.22))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 3))
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

    @ViewBuilder
    private func badges(for frame: CollageLayout.Frame) -> some View {
        let r = viewRect(frame)
        let window = store.window(for: frame)
        let cut = window?.cutsFace ?? false
        // 路人只在选中的那一格标（景区照片几乎格格有路人，以前满屏橙色角标）；切脸一直标。
        let bystander = (window?.hitsBystander ?? false) && store.selection == frame.path
        // 印刷画布：放大超过 120% 的格子一直标（印出来会软）。
        let up = store.project.canvas.isPrint ? store.upscale(for: frame) : nil
        let soft = (up ?? 0) > CollageStore.upscaleLimit
        if cut || bystander || soft || frame.cell.locked {
            HStack(spacing: 4) {
                if frame.cell.locked { badge("lock.fill", nil, .white) }
                if cut { badge("exclamationmark.triangle.fill", "切脸", .red) }
                if bystander { badge("person.2.fill", "路人", .orange) }
                if soft, let up { badge("plus.magnifyingglass", "放大\(Int((up * 100).rounded()))%", .orange) }
            }
            .offset(x: r.minX + 6, y: r.minY + 6)
        }
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
              let window = store.window(for: frame) else { return [] }
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
                    // 散落版：落点放一张相纸。
                    if store.isFreeform {
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
