import SwiftUI
import AppKit

// MARK: - 章节时间轴（网格上方：跨章节导航 + 漏交保护 + 现在看到哪）
//
// 以前是 HStack 里每段 `max(46, 按张数分)`：章节一多（或者一章 2000 张、旁边几十章各几张），
// 46pt 的保底加起来就比网格宽，整条伸出去压在右边的筛选面板上；每段还硬写「时间段 · 张数」，
// 窄段全是「下午5:2…」。现在：
// - 宽度按张数**开方**分（大章不至于把小章挤成线），每段保底 3pt，总宽永远正好等于可用宽度；
// - 标签按优先级摆（换天 > 第一段 > 大章），和已摆的撞了就不画，细节都在悬停卡片里；
// - 多天的拍摄在换天处留缝、画分隔线、写日期；
// - 网格里现在看得见的章节在条下面画白线（滚动时跟着走）。

/// 网格里现在看得见哪些章节。缩略图出现 / 消失时记一笔，攒到下一拍再发布。只有时间轴
/// 观察它：批量页拿 @State 存着（不是 @StateObject），滚动不会因此重绘整个网格。
final class GridViewport: ObservableObject {
    @Published private(set) var chapters: Set<Int> = []
    /// id → (章节, 现在有几个格子挂着它)。要计数：改判时照片带动画换分区，新格子的 onAppear 会先于
    /// 旧格子的 onDisappear 到，只记 id 的话旧格子一注销就把还看得见的这张也抹掉了（审查发现）。
    private var visible: [String: (chapter: Int, cells: Int)] = [:]
    private var scheduled = false

    func appeared(_ id: String, chapter: Int) {
        visible[id] = (chapter, (visible[id]?.cells ?? 0) + 1)
        schedule()
    }

    func disappeared(_ id: String) {
        guard let entry = visible[id] else { return }
        if entry.cells <= 1 {
            visible.removeValue(forKey: id)
        } else {
            visible[id] = (entry.chapter, entry.cells - 1)
        }
        schedule()
    }

    /// 格子还挂着、章节却变了（重新分析后章节重排）：改记新章节。
    func update(_ id: String, chapter: Int) {
        guard let entry = visible[id], entry.chapter != chapter else { return }
        visible[id] = (chapter, entry.cells)
        schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let now = Set(self.visible.values.map(\.chapter))
            if now != self.chapters { self.chapters = now }
        }
    }
}

/// 时间轴的几何。纯计算：界面照着画，无头 `--timeline-selftest` 拿随机数据验它永远不出界、不重叠。
struct ChapterTimelineLayout: Equatable {
    struct Segment: Equatable {
        let index: Int
        let x: CGFloat
        let width: CGFloat
    }

    struct Label: Equatable {
        let index: Int
        let text: String
        let x: CGFloat
        let width: CGFloat
        let isDay: Bool
    }

    var segments: [Segment] = []
    var labels: [Label] = []
    /// 换天处分隔线的 x（无时间那段之前也有一条）。
    var dayMarks: [CGFloat] = []

    /// 每段保底宽度。段数多到连这个都放不下时按可用宽度均分（几百章的旅行文件夹）。
    static let minSegment: CGFloat = 3
    /// 两个标签之间至少空这么多。
    static let labelSpacing: CGFloat = 10

    @MainActor
    static func compute(_ segs: [BatchStore.ChapterSegment], width: CGFloat,
                        measure: (String, Bool) -> CGFloat) -> ChapterTimelineLayout {
        var layout = ChapterTimelineLayout()
        let n = segs.count
        guard n > 0, width > 1 else { return layout }

        let calendar = Calendar.current
        let days: [Date?] = segs.map { $0.start.map { calendar.startOfDay(for: $0) } }
        let multiDay = Set(days.compactMap { $0 }).count > 1
        // 第 i 段之前换了一天（无时间那段的 day 是 nil，也算换）。写成循环：闭包版的类型推断在
        // 本地就要 70ms，CI 的 Xcode 16 对这类式子超时过。
        var breaks = [Bool](repeating: false, count: n)
        var breakCount = 0
        for i in 1..<max(1, n) where days[i] != days[i - 1] {
            breaks[i] = true
            breakCount += 1
        }

        // 缝：段与段 2pt、换天 9pt；放不下就一级级收窄，最后连缝都不留。
        var gap: CGFloat = 0, dayGap: CGFloat = 0
        func gapsTotal() -> CGFloat {
            CGFloat(n - 1 - breakCount) * gap + CGFloat(breakCount) * dayGap
        }
        for (g, d) in [(CGFloat(2), CGFloat(9)), (1, 5), (0, 3), (0, 0)] {
            gap = g
            dayGap = d
            if width - gapsTotal() >= CGFloat(n) * minSegment { break }
        }
        let avail = max(0, width - gapsTotal())
        let minW = min(minSegment, avail / CGFloat(n))

        // 注水式分配：按开方权重分，分到不足保底的钉成保底，剩下的再分，直到没人掉线。
        let weights = segs.map { Double(max(1, $0.count)).squareRoot() }
        var widths = [CGFloat](repeating: minW, count: n)
        var fixed = Set<Int>()
        while true {
            let free = (0..<n).filter { !fixed.contains($0) }
            guard !free.isEmpty else { break }
            let freeAvail = avail - CGFloat(fixed.count) * minW
            let freeWeight = free.reduce(0.0) { $0 + weights[$1] }
            var changed = false
            for i in free {
                let w = CGFloat(weights[i] / freeWeight) * freeAvail
                if w < minW {
                    fixed.insert(i)
                    widths[i] = minW
                    changed = true
                } else {
                    widths[i] = w
                }
            }
            if !changed { break }
        }

        var x: CGFloat = 0
        for i in 0..<n {
            if i > 0 {
                let g = breaks[i] ? dayGap : gap
                if breaks[i], g > 0 { layout.dayMarks.append(x + g / 2) }
                x += g
            }
            layout.segments.append(Segment(index: i, x: x, width: widths[i]))
            x += widths[i]
        }

        // 标签。每段的起点写开始时间（宽到装得下就写全「09:12–11:40 · 234 张」），换天的那段
        // 写日期；按优先级摆，撞了就不画 —— 悬停卡片里什么都有，挤成「下午5:2…」反而什么都看不清。
        struct Candidate {
            let index: Int
            let texts: [String]
            let isDay: Bool
            let priority: Double
        }
        var candidates: [Candidate] = []
        for (i, seg) in segs.enumerated() {
            if seg.undated {
                candidates.append(Candidate(index: i, texts: ["无时间"], isDay: false, priority: 1))
                continue
            }
            guard let start = seg.start else { continue }
            let time = BatchStore.chapterTimeFormatter.string(from: start)
            if multiDay && (i == 0 || breaks[i]) {
                candidates.append(Candidate(index: i, texts: ["\(dayText(start)) \(time)", dayText(start)],
                                            isDay: true, priority: 3e9 - Double(i)))
            } else {
                var texts: [String] = []
                if let end = seg.end {
                    texts.append("\(time)–\(BatchStore.chapterTimeFormatter.string(from: end)) · \(seg.count) 张")
                }
                texts.append(time)
                candidates.append(Candidate(index: i, texts: texts, isDay: false,
                                            priority: (i == 0 ? 2e9 : 0) + Double(seg.count)))
            }
        }
        var placed: [(lo: CGFloat, hi: CGFloat)] = []
        func free(_ lo: CGFloat, _ hi: CGFloat) -> Bool {
            placed.allSatisfy { hi + labelSpacing <= $0.lo || lo >= $0.hi + labelSpacing }
        }
        for c in candidates.sorted(by: { $0.priority > $1.priority }) {
            let seg = layout.segments[c.index]
            for (k, text) in c.texts.enumerated() {
                let w = measure(text, c.isDay)
                // 全写版只在自己那段里装得下时用（不往别的段上伸）。
                let isRich = !c.isDay && c.texts.count > 1 && k == 0
                if isRich && w + 4 > seg.width { continue }
                var lo = seg.x + 1
                if lo + w > width {
                    // 贴着右边出界：日期往左挪着也要写；普通时间不挪 —— 挪开了就对不上自己那段。
                    guard c.isDay else { continue }
                    lo = max(0, width - w)
                }
                let hi = lo + w
                guard hi <= width + 0.5, free(lo, hi) else { continue }
                placed.append((lo, hi))
                layout.labels.append(Label(index: c.index, text: text, x: lo, width: w, isDay: c.isDay))
                break
            }
        }
        layout.labels.sort { $0.x < $1.x }
        return layout
    }

    static func dayText(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    static func weekdayText(_ date: Date) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let w = Calendar.current.component(.weekday, from: date)
        return names[(w - 1 + 7) % 7]
    }

    /// 标签字号和界面画的一样（10pt、数字等宽，日期加粗），量出来的宽度才对得上。
    static func measureText(_ text: String, bold: Bool) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: bold ? .semibold : .regular)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + 2
    }
}

/// 时间轴本体。
struct ChapterTimeline: View {
    let segments: [BatchStore.ChapterSegment]
    @ObservedObject var viewport: GridViewport
    /// 分组模式下在每章上方点出「还有连拍没定」的橙点。
    let showPending: Bool
    let minKeepers: Int
    /// 「只看这一章」开着时是哪一章：别的段变暗、这一段描白边。
    let filtered: Int?
    /// 右键菜单「只看这一章 / 显示全部章节」。
    let onFilter: (Int?) -> Void
    /// 点了一段。返回 false = 当前视图里这一章一张都没有（被筛选掉 / 单张收起了）。
    let onJump: (BatchStore.ChapterSegment) -> Bool

    @State private var hovered: Int?
    /// 点过但跳不过去的那一段 —— 卡片上说明原因，别让人以为没点上。
    @State private var missed: Int?

    init(segments: [BatchStore.ChapterSegment], viewport: GridViewport, showPending: Bool, minKeepers: Int,
         filtered: Int? = nil, onFilter: @escaping (Int?) -> Void = { _ in },
         previewHover: Int? = nil, onJump: @escaping (BatchStore.ChapterSegment) -> Bool) {
        self.segments = segments
        self.viewport = viewport
        self.showPending = showPending
        self.minKeepers = minKeepers
        self.filtered = filtered
        self.onFilter = onFilter
        self.onJump = onJump
        // 只给离屏快照用（--timeline-ui --hover N）：离屏窗口收不到鼠标，悬停卡片只能这样看。
        _hovered = State(initialValue: previewHover)
    }

    static let markerHeight: CGFloat = 8
    static let barHeight: CGFloat = 8
    static let labelTop: CGFloat = markerHeight + barHeight + 5
    static let height: CGFloat = labelTop + 13
    static let cardWidth: CGFloat = 260

    var body: some View {
        GeometryReader { geo in
            let layout = ChapterTimelineLayout.compute(segments, width: geo.size.width,
                                                       measure: ChapterTimelineLayout.measureText)
            canvas(layout)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let hit = Self.hit(point, layout)
                        if hit != hovered {
                            hovered = hit
                            missed = nil
                        }
                    case .ended:
                        hovered = nil
                        missed = nil
                    }
                }
                .onTapGesture { point in
                    guard let i = Self.hit(point, layout), segments.indices.contains(i) else { return }
                    hovered = i
                    missed = onJump(segments[i]) ? nil : i
                }
                // 右键：只看这一章 / 回到全部。菜单内容按右键时鼠标停在哪一段来定。
                .contextMenu {
                    if let i = hovered, segments.indices.contains(i) {
                        let seg = segments[i]
                        if filtered == seg.chapter {
                            Button("显示全部章节") { onFilter(nil) }
                        } else {
                            Button("只看这一章（\(Self.menuTitle(seg))）") { onFilter(seg.chapter) }
                        }
                    }
                    if filtered != nil, hovered.map({ segments.indices.contains($0) && segments[$0].chapter == filtered }) != true {
                        Button("显示全部章节") { onFilter(nil) }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let i = hovered, segments.indices.contains(i),
                       let seg = layout.segments.first(where: { $0.index == i }) {
                        let x = min(max(0, seg.x + seg.width / 2 - Self.cardWidth / 2),
                                    max(0, geo.size.width - Self.cardWidth))
                        TimelineCard(segment: segments[i], minKeepers: minKeepers, missed: missed == i)
                            .offset(x: x, y: Self.height + 4)
                            .allowsHitTesting(false)
                    }
                }
        }
        // 不挂 .help：悬停卡片就是说明，系统提示过一秒再叠上来反而挡住它。
        .frame(height: Self.height)
    }

    static func menuTitle(_ seg: BatchStore.ChapterSegment) -> String {
        guard let start = seg.start else { return "无拍摄时间 · \(seg.count) 张" }
        return "章节 \(seg.chapter + 1) · \(ChapterTimelineLayout.dayText(start)) \(seg.timeRange) · \(seg.count) 张"
    }

    private func canvas(_ layout: ChapterTimelineLayout) -> some View {
        let visible = viewport.chapters
        let hovered = self.hovered
        let segments = self.segments
        let showPending = self.showPending
        let filtered = self.filtered
        return Canvas { ctx, size in
            let barY = Self.markerHeight
            for s in layout.segments {
                let seg = segments[s.index]
                let rect = CGRect(x: s.x, y: barY, width: max(s.width, 0.5), height: Self.barHeight)
                let shape = Path(roundedRect: rect, cornerRadius: min(2, s.width / 2))
                // 「只看这一章」：别的段压暗（还能点 —— 点了就换成只看那一章）。
                let dimmed = filtered != nil && filtered != seg.chapter
                ctx.drawLayer { layer in
                    layer.clip(to: shape)
                    if dimmed { layer.opacity = 0.3 }
                    var x = rect.minX
                    let total = CGFloat(max(1, seg.count))
                    for (n, color) in [(seg.pick, Verdict.pick.color), (seg.usable, Verdict.usable.color),
                                       (seg.reject, Verdict.reject.color)] where n > 0 {
                        let w = rect.width * CGFloat(n) / total
                        layer.fill(Path(CGRect(x: x, y: rect.minY, width: w + 0.5, height: rect.height)),
                                   with: .color(color.opacity(seg.undated ? 0.45 : 0.85)))
                        x += w
                    }
                }
                if hovered == s.index {
                    ctx.fill(shape, with: .color(.white.opacity(0.3)))
                }
                if filtered == seg.chapter {
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3),
                               with: .color(.white), lineWidth: 1.5)
                }
                // 现在网格里看得见的章节：条下面一道白线（相邻的连成一片）。
                if visible.contains(seg.chapter) {
                    ctx.fill(Path(CGRect(x: s.x, y: barY + Self.barHeight + 1.5, width: s.width, height: 2)),
                             with: .color(.white.opacity(0.85)))
                }
                // 条上方的记号：漏交警告优先（全灭红、不够数橙），其次分组模式下的待处理连拍。
                let cx = s.x + s.width / 2
                if seg.allRejected || seg.underMin {
                    var tri = Path()
                    tri.move(to: CGPoint(x: cx, y: 0.5))
                    tri.addLine(to: CGPoint(x: cx + 3.5, y: 6.5))
                    tri.addLine(to: CGPoint(x: cx - 3.5, y: 6.5))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(seg.allRejected ? .red : .orange))
                } else if showPending && seg.pendingTakes > 0 {
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 2, y: 2, width: 4, height: 4)), with: .color(.orange))
                }
            }
            for x in layout.dayMarks {
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: barY + Self.barHeight + 4)),
                         with: .color(.white.opacity(0.35)))
            }
            for label in layout.labels {
                let seg = segments[label.index]
                let color: Color = seg.allRejected ? .red
                    : (label.isDay ? .white.opacity(0.9) : .white.opacity(seg.undated ? 0.4 : 0.6))
                let text = Text(label.text)
                    .font(.system(size: 10, weight: label.isDay ? .semibold : .regular).monospacedDigit())
                    .foregroundColor(color)
                ctx.draw(text, at: CGPoint(x: label.x, y: Self.labelTop), anchor: .topLeading)
            }
        }
    }

    /// 鼠标落在哪一段：标签行上按标签认，条上按 x 找（落在缝里取近的那段）。
    static func hit(_ point: CGPoint, _ layout: ChapterTimelineLayout) -> Int? {
        if point.y >= labelTop,
           let label = layout.labels.first(where: { point.x >= $0.x - 2 && point.x <= $0.x + $0.width + 2 }) {
            return label.index
        }
        var best: (index: Int, distance: CGFloat)?
        for s in layout.segments {
            let d: CGFloat = point.x < s.x ? s.x - point.x : (point.x > s.x + s.width ? point.x - s.x - s.width : 0)
            if d == 0 { return s.index }
            if best == nil || d < best!.distance { best = (s.index, d) }
        }
        return best.flatMap { $0.distance <= 6 ? $0.index : nil }
    }
}

/// 悬停卡片：这一章的全部信息（时间轴上放不下的都在这）。
private struct TimelineCard: View {
    let segment: BatchStore.ChapterSegment
    let minKeepers: Int
    let missed: Bool

    private var title: String {
        guard let start = segment.start else { return "无拍摄时间" }
        return "章节 \(segment.chapter + 1) · \(ChapterTimelineLayout.dayText(start)) \(ChapterTimelineLayout.weekdayText(start))"
    }

    private var subtitle: String {
        guard let start = segment.start, let end = segment.end else { return "EXIF 里没有拍摄时间的照片，网格里排在最后" }
        let f = BatchStore.chapterTimeFormatter
        let minutes = Int(end.timeIntervalSince(start) / 60)
        let span = minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(max(1, minutes)) 分钟"
        return "\(f.string(from: start)) – \(f.string(from: end)) · \(span)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout.bold())
                Spacer(minLength: 6)
                Text("\(segment.count) 张").font(.callout).monospacedDigit()
            }
            Text(subtitle).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if !segment.covers.isEmpty {
                HStack(spacing: 4) {
                    ForEach(segment.covers, id: \.self) { path in
                        ThumbnailView(path: path)
                            .frame(width: Self.coverSize, height: Self.coverSize)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            composition
            HStack(spacing: 10) {
                legend("精选", segment.pick, Verdict.pick.color)
                legend("可用", segment.usable, Verdict.usable.color)
                legend("废片", segment.reject, Verdict.reject.color)
            }
            if segment.pendingTakes > 0 {
                Label("还有 \(segment.pendingTakes) 场连拍没定", systemImage: "rectangle.stack")
                    .font(.caption).foregroundStyle(.orange)
            }
            if segment.allRejected {
                Label("这一章全部被淘汰（漏交风险）", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else if segment.underMin {
                Label("只留了 \(segment.pick + segment.usable) 张（每章至少 \(minKeepers)）",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(missed ? "当前视图里没有这一章的照片（被筛选掉了，或单张已收起）"
                        : "点击跳到这一章 · 右键只看这一章 · 网格里 [ ] 上一章 / 下一章")
                .font(.caption2)
                .foregroundStyle(missed ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        }
        .padding(10)
        .frame(width: ChapterTimeline.cardWidth, alignment: .leading)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
    }

    /// 4 张代表照片正好铺满卡片内宽。
    static let coverSize: CGFloat = (ChapterTimeline.cardWidth - 20 - 3 * 4) / 4

    private var composition: some View {
        let total = CGFloat(max(1, segment.count))
        let width = ChapterTimeline.cardWidth - 20
        return HStack(spacing: 0) {
            Rectangle().fill(Verdict.pick.color).frame(width: width * CGFloat(segment.pick) / total)
            Rectangle().fill(Verdict.usable.color).frame(width: width * CGFloat(segment.usable) / total)
            Rectangle().fill(Verdict.reject.color).frame(width: width * CGFloat(segment.reject) / total)
        }
        .frame(width: width, height: 6, alignment: .leading)
        .clipShape(Capsule())
    }

    private func legend(_ name: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(name) \(n)").font(.caption).monospacedDigit()
        }
    }
}

// MARK: - 无头自检：随机章节数 / 张数 / 宽度，验证永远不出界、不重叠

enum ChapterTimelineSelfTest {
    /// LabelGUI --timeline-selftest：打印 PASS / 第一处 FAIL。
    @MainActor
    static func run() -> Never {
        var rng = SystemRandomNumberGenerator()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var failures: [String] = []
        for trial in 0..<3000 {
            let n = Int.random(in: 1...(trial % 10 == 0 ? 600 : 80), using: &rng)
            let width = CGFloat.random(in: 120...2400, using: &rng)
            let days = Int.random(in: 1...5, using: &rng)
            var t = base
            var segs: [BatchStore.ChapterSegment] = []
            for i in 0..<n {
                if Int.random(in: 0..<max(1, n / days), using: &rng) == 0 { t = t.addingTimeInterval(86_400) }
                let count = [1, 2, 5, 40, 300, 2500].randomElement(using: &rng)!
                let undated = i == n - 1 && n > 1 && Bool.random(using: &rng)
                let pick = Int.random(in: 0...count, using: &rng)
                let usable = Int.random(in: 0...(count - pick), using: &rng)
                segs.append(BatchStore.ChapterSegment(
                    chapter: undated ? BatchStore.ChapterSegment.undatedID : i, count: count,
                    pick: pick, usable: usable, reject: count - pick - usable,
                    start: undated ? nil : t, end: undated ? nil : t.addingTimeInterval(600),
                    timeRange: "", underMin: false, pendingTakes: 0, covers: []))
                t = t.addingTimeInterval(Double.random(in: 1_000...9_000, using: &rng))
            }
            let layout = ChapterTimelineLayout.compute(segs, width: width, measure: ChapterTimelineLayout.measureText)
            let eps: CGFloat = 0.01
            if layout.segments.count != n { failures.append("trial \(trial): \(layout.segments.count) 段 ≠ \(n)") }
            for (k, s) in layout.segments.enumerated() {
                if s.x < -eps || s.x + s.width > width + eps {
                    failures.append("trial \(trial): 第 \(k) 段出界 x=\(s.x) w=\(s.width) / \(width)")
                }
                if k > 0 {
                    let prev = layout.segments[k - 1]
                    if s.x < prev.x + prev.width - eps { failures.append("trial \(trial): 第 \(k) 段和前一段重叠") }
                }
                if s.width <= 0 { failures.append("trial \(trial): 第 \(k) 段宽度 \(s.width)") }
            }
            for (k, l) in layout.labels.enumerated() {
                if l.x < -eps || l.x + l.width > width + 0.5 + eps {
                    failures.append("trial \(trial): 标签「\(l.text)」出界 x=\(l.x) w=\(l.width) / \(width)")
                }
                if k > 0 {
                    let prev = layout.labels[k - 1]
                    if l.x < prev.x + prev.width + ChapterTimelineLayout.labelSpacing - eps {
                        failures.append("trial \(trial): 标签「\(prev.text)」和「\(l.text)」重叠")
                    }
                }
            }
            if failures.count > 5 { break }
        }
        if failures.isEmpty {
            print("时间轴自检 PASS：3000 组随机章节（1–600 段、宽 120–2400pt、1–5 天、带无时间段）全部不出界、不重叠")
            exit(0)
        }
        failures.prefix(10).forEach { print("FAIL " + $0) }
        exit(1)
    }
}
