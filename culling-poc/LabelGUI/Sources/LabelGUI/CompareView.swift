import SwiftUI
import AppKit
import ImageIO

// MARK: - 场内对比模式
//
// 连拍选片的主战场。以前是两个弹窗（检视器里的「并排对比」、⌘多选的 ComparePairSheet）：
// 每场进出一次，右边的对手由不得你挑，对比时不能放大、看不到人脸，也没有「下一场」——
// 9-15 否掉「堆栈 + 弹窗」的理由它原样继承了。现在它占审片模式那个位置，全窗口：
// 一场的候选平铺上台，3 淘汰（下台，候场补位），K 勾要留的，⏎ 定案并跳下一个待处理场，
// Z 所有格一起放大到各自的人脸。

/// 怎么进的对比模式。
enum CompareRequest: Hashable {
    /// 一场。preferred = 先摆上台的（网格焦点那张 / 同一场里 ⌘多选的几张）；
    /// markPreferred = 顺手把它们勾成"要留的"（⌘多选进来时）。
    case take(Int, preferred: [String], markPreferred: Bool = false)
    /// 跨场的 ⌘多选：不同时刻/机位之间挑，只逐张改判，没有"本场其余废片"。
    case selection([String])

    /// ⌘多选进来的：全在同一场就按整场对比，先摆选中的、并勾成要留的 —— 和批量栏
    /// 「保留选中·其余废片」同一个意思；不勾的话一按 ⏎ 留下的是算法的精选，你选的
    /// 那几张反倒进了废片。跨场才是自由对比。
    @MainActor
    static func forSelection(_ ids: [String], store: BatchStore) -> CompareRequest? {
        guard ids.count >= 2 else { return nil }
        let takes = Set(ids.compactMap { store.item(withID: $0)?.take })
        if takes.count == 1, let take = takes.first {
            return .take(take, preferred: ids, markPreferred: true)
        }
        return .selection(ids)
    }
}

// MARK: - 交互逻辑

/// 对比模式的全部交互逻辑。不碰 SwiftUI：视图只负责画，无头 `--compare` 用按键脚本驱动
/// 同一个对象 —— 这个界面不能开 GUI 验证，逻辑必须能在命令行里跑通。
@MainActor
final class CompareSession: ObservableObject {
    enum Mode: Hashable {
        case take(Int)
        case selection([String])
    }

    /// 一次 3 键淘汰：谁、在哪一格、谁补的位。⌘Z 靠它把那张放回原来的格子。
    struct Elimination: Equatable {
        let id: String
        let slot: Int
        let replacement: String?
    }

    /// ⏎ 会怎么定。
    struct Settlement: Equatable {
        /// 留谁是怎么来的 —— 按钮和格子上都要写明，别让人以为是自己挑的。
        enum Source: Equatable {
            /// K 勾的。
            case marks
            /// 一张没勾：本场现在的精选，全是算法提名的。
            case recommended
            /// 一张没勾：本场现在的精选，里面有你按 1 定的。
            case picks
            /// 一张没勾、也没有精选，但只剩最后一张没淘汰 —— 一路 3 淘汰下来的赢家。
            /// （自动提名要 2 张以上存活才给精选，淘汰到只剩一张它就只是「可用」。）
            case survivor
        }
        /// 留下的（候场顺序）。
        let keep: [String]
        let source: Source
        /// 会从精选/可用变成废片的张数。
        let rejectCount: Int
        /// false = 定了也不改变任何判决（已经定过了）。
        let changes: Bool
    }

    static let capacities = [2, 3, 4, 6]
    static let defaultCapacity = 4

    let store: BatchStore
    /// 和网格的「场内按评分」一致：候场条按评分排还是按拍摄顺序排。
    let sortByScore: Bool
    @Published private(set) var mode: Mode
    /// 台上的照片，按槽位顺序。
    @Published private(set) var stage: [String] = []
    /// 当前格（stage 下标）：1/2/3/0/K 作用在它上面。
    @Published private(set) var active = 0
    /// 每场 K 勾的"要留下的"。一张没勾时 ⏎ 留本场现有的精选。
    @Published private(set) var marks: [Int: Set<String>] = [:]
    /// 最后一个待处理场也定完了。
    @Published private(set) var allDone = false
    @Published private(set) var capacity: Int
    /// 离开一场时台上的样子 —— ⌘Z 跳回来时原样摆回去。
    private var stageMemory: [Int: (stage: [String], active: Int)] = [:]
    /// 3 键淘汰记录，按场（跨场对比是一条单独的）。换场、改每屏张数都不清 ——
    /// 清了的话，去下一场再 ⌘Z，照片是不废了，却回不到台上。
    private var eliminations: [Mode: [Elimination]] = [:]

    init(store: BatchStore, request: CompareRequest, capacity: Int, sortByScore: Bool) {
        self.store = store
        self.sortByScore = sortByScore
        self.capacity = Self.capacities.contains(capacity) ? capacity : Self.defaultCapacity
        switch request {
        case .take(let take, let preferred, let markPreferred):
            mode = .take(take)
            load(take: take, preferred: preferred)
            if markPreferred {
                let ids = Set(members(of: take).map(\.id)).intersection(preferred)
                if !ids.isEmpty { marks[take] = ids }
            }
        case .selection(let ids):
            mode = .selection(ids)
            stage = Self.initialStage(pool: pool, preferred: ids, capacity: self.capacity)
        }
    }

    // MARK: 数据

    /// 这一场的全部成员，和网格那一行同一个顺序（拍摄时间；开了「场内按评分」就按评分）。
    /// 走 store 预先分好的 takeRows（二分找到这一场）：视图每次按键都要问好几遍，
    /// 每次对全部照片 filter + sort 就是上一轮刚从网格里清掉的那个坑。
    func members(of take: Int) -> [BatchItem] {
        let items = store.items
        let rows = store.takeRows
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].take < take { lo = mid + 1 } else { hi = mid }
        }
        var members: [BatchItem]
        if lo < rows.count, rows[lo].take == take,
           rows[lo].indices.allSatisfy({ $0 < items.count && items[$0].take == take }) {
            members = rows[lo].indices.map { items[$0] }
        } else {
            // 下标和 items 对不上（换了 items 还没重算的那一帧）就老老实实扫一遍。
            members = items.filter { $0.take == take }.sorted { a, b in
                let ta = a.captureTime ?? .distantPast, tb = b.captureTime ?? .distantPast
                return ta != tb ? ta < tb : a.id < b.id
            }
        }
        if sortByScore {
            members.sort { a, b in
                let ka = BatchStore.scoreKey(a), kb = BatchStore.scoreKey(b)
                return ka == kb ? a.id < b.id : ka > kb
            }
        }
        return members
    }

    /// 候场条 + 补位的来源：一场的全部成员，或 ⌘多选的那几张。
    var pool: [BatchItem] {
        switch mode {
        case .take(let take):
            return members(of: take)
        case .selection(let ids):
            let wanted = Set(ids)
            return store.items.filter { wanted.contains($0.id) }
        }
    }

    var currentTake: Int? {
        if case .take(let take) = mode { return take }
        return nil
    }

    var activeID: String? { stage.indices.contains(active) ? stage[active] : nil }

    /// 上台的先后：精选优先，其次评分（和自动提名、缩略图 #1#2#3 同一把尺子）。
    static func ranked(_ items: [BatchItem]) -> [BatchItem] {
        items.sorted { a, b in
            if (a.verdict == .pick) != (b.verdict == .pick) { return a.verdict == .pick }
            let ka = BatchStore.scoreKey(a), kb = BatchStore.scoreKey(b)
            return ka == kb ? a.id < b.id : ka > kb
        }
    }

    /// 开场摆谁：先摆 preferred（排名高的优先），不够再从没淘汰的里按排名补。一场只剩
    /// 不到 2 张没淘汰（已经定过了）就从全部成员里补 —— 回头复查"精选 vs 被废的"，
    /// 台上只摆一张就没得比。摆好后按候场顺序排，时间线从左往右读。
    static func initialStage(pool: [BatchItem], preferred: [String], capacity: Int) -> [String] {
        let wanted = Set(preferred)
        var chosen = ranked(pool.filter { wanted.contains($0.id) }).prefix(capacity).map(\.id)
        let alive = pool.filter { $0.verdict != .reject }
        for item in ranked(alive.count >= 2 ? alive : pool)
        where chosen.count < capacity && !chosen.contains(item.id) {
            chosen.append(item.id)
        }
        let order = Dictionary(pool.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return chosen.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
    }

    /// 待处理的场（和网格同一个定义，store 在每次重判时算好），按场号 = 时间顺序。
    func pendingTakes() -> [Int] { store.pendingTakes }

    /// 当前场之后的第一个待处理场，到底了绕回开头；除了当前这场没有别的就是 nil。
    var nextPendingTake: Int? {
        let current = currentTake ?? -1
        let pending = pendingTakes().filter { $0 != current }
        return pending.first { $0 > current } ?? pending.first
    }

    /// 下一个待处理场开场会摆上台的那几张 —— 视图趁现在把它们的大图解好。
    /// 跨场对比到不了下一场，不预取。
    func upcomingStage() -> [BatchItem] {
        guard currentTake != nil, let next = nextPendingTake else { return [] }
        let members = self.members(of: next)
        let byID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self.initialStage(pool: members, preferred: [], capacity: capacity).compactMap { byID[$0] }
    }

    // MARK: 换场

    private func load(take: Int, preferred: [String]) {
        let members = self.members(of: take)
        allDone = false
        if preferred.isEmpty, let memory = stageMemory[take] {
            let ids = Set(members.map(\.id))
            let kept = Array(memory.stage.filter { ids.contains($0) }.prefix(capacity))
            if !kept.isEmpty {
                stage = kept
                active = min(memory.active, kept.count - 1)
                return
            }
        }
        stage = Self.initialStage(pool: members, preferred: preferred, capacity: capacity)
        let focus = preferred.first { stage.contains($0) }
            ?? members.first { $0.verdict == .pick && stage.contains($0.id) }?.id
        active = focus.flatMap { stage.firstIndex(of: $0) } ?? 0
    }

    private func go(to take: Int) {
        if let current = currentTake { stageMemory[current] = (stage, active) }
        mode = .take(take)
        load(take: take, preferred: [])
    }

    // MARK: 操作

    func move(_ delta: Int) {
        guard !stage.isEmpty else { return }
        active = max(0, min(stage.count - 1, active + delta))
    }

    func activate(_ id: String) {
        if let idx = stage.firstIndex(of: id) { active = idx }
    }

    /// 候场条上点一张：已在台上就切过去；台上有空位就加一格；满了就换下当前格。
    func bringIn(_ id: String) {
        if let idx = stage.firstIndex(of: id) {
            active = idx
            return
        }
        guard pool.contains(where: { $0.id == id }) else { return }
        if stage.count < capacity {
            stage.append(id)
            active = stage.count - 1
        } else if stage.indices.contains(active) {
            stage[active] = id
        }
    }

    /// 1/2/3/0 作用在当前格。3 = 淘汰：这张下台，候场里排名最高的没淘汰的补进同一格；
    /// 候场空了台面就少一格，剩下的跟着变大。只剩一张时留在台上（红标），不清空台面。
    func setVerdict(_ verdict: Verdict?) {
        // 台上的 id 解析不到（这张被移走了）就别写 override，否则写进一个不存在的 id。
        guard let id = activeID, store.item(withID: id) != nil else { return }
        store.setOverride(id, verdict)
        // 改成可用/废片 = 不留了，勾掉，否则 ⏎ 又把它写回精选。
        if let take = currentTake, verdict == .reject || verdict == .usable {
            unmark(id, in: take)
        }
        if verdict == .reject { eliminateActive() }
    }

    private func eliminateActive() {
        guard let id = activeID else { return }
        let onStage = Set(stage)
        let bench = Self.ranked(pool.filter { !onStage.contains($0.id) && $0.verdict != .reject })
        if let next = bench.first {
            eliminations[mode, default: []].append(Elimination(id: id, slot: active, replacement: next.id))
            stage[active] = next.id
        } else if stage.count > 1 {
            eliminations[mode, default: []].append(Elimination(id: id, slot: active, replacement: nil))
            stage.remove(at: active)
            active = min(active, stage.count - 1)
        }
    }

    /// 台上有 id 解析不到了（分析结果重载、照片被移走）：拿掉，当前格夹回范围内。
    /// 不拿掉的话网格按剩下的画，当前格的下标却还指着原来的槽位 —— 高亮的和按键
    /// 作用的不是同一张。
    func pruneMissing() {
        let live = stage.filter { store.item(withID: $0) != nil }
        guard live.count != stage.count else { return }
        let keepActive = activeID.flatMap { live.contains($0) ? $0 : nil }
        stage = live
        active = keepActive.flatMap { live.firstIndex(of: $0) } ?? max(0, min(active, live.count - 1))
    }

    func isMarked(_ id: String) -> Bool {
        guard let take = currentTake else { return false }
        return marks[take]?.contains(id) ?? false
    }

    /// K：勾 / 取消当前格"要留下"。勾了任何一张，⏎ 就只留勾的。
    func toggleMark() {
        guard let take = currentTake, let id = activeID else { return }
        var set = marks[take] ?? []
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        marks[take] = set.isEmpty ? nil : set
    }

    private func unmark(_ id: String, in take: Int) {
        guard var set = marks[take], set.contains(id) else { return }
        set.remove(id)
        marks[take] = set.isEmpty ? nil : set
    }

    var settlement: Settlement? {
        guard let take = currentTake else { return nil }
        let members = self.members(of: take)
        let marked = (marks[take] ?? []).intersection(members.map(\.id))
        let picks = members.filter { $0.verdict == .pick }
        let alive = members.filter { $0.verdict != .reject }
        let keepSet: Set<String>
        let source: Settlement.Source
        if !marked.isEmpty {
            keepSet = marked
            source = .marks
        } else if !picks.isEmpty {
            keepSet = Set(picks.map(\.id))
            source = picks.contains { store.overrides[$0.id] == .pick } ? .picks : .recommended
        } else if alive.count == 1 {
            keepSet = [alive[0].id]
            source = .survivor
        } else {
            keepSet = []
            source = .marks
        }
        let keep = members.map(\.id).filter { keepSet.contains($0) }
        let rejectCount = members.filter { !keepSet.contains($0.id) && $0.verdict != .reject }.count
        let changes = rejectCount > 0 || members.contains { keepSet.contains($0.id) && $0.verdict != .pick }
        return Settlement(keep: keep, source: source, rejectCount: rejectCount, changes: changes)
    }

    /// 定案按钮上的字：留谁一定写出来 —— 自动提名会在你看不见的地方换人（废掉精选，
    /// 算法立刻在剩下的里再提一张），不写明就是在盲点。
    static func settleLabel(_ settlement: Settlement?) -> String {
        guard let s = settlement else { return "跨场对比：逐张 1/2/3 改判" }
        if s.keep.isEmpty { return "本场没有精选 · 按 K 勾选要留下的" }
        if !s.changes { return "本场已定案" }
        let names = s.keep.count <= 3
            ? s.keep.joined(separator: "、")
            : s.keep.prefix(3).joined(separator: "、") + " 等 \(s.keep.count) 张"
        let why: String
        switch s.source {
        case .marks: why = ""
        case .recommended: why = "（推荐）"
        case .picks: why = "（精选）"
        case .survivor: why = "（最后一张）"
        }
        return "定案：留 \(names)\(why) · 本场其余 \(s.rejectCount) 张废片"
    }

    /// ⏎：留下勾选的（没勾就是本场现有的精选），本场其余全部废片 —— 整场一条撤销记录，
    /// 然后跳到下一个待处理场。最后一场定完就停在这儿亮"都定完了"。
    @discardableResult
    func settle() -> Bool {
        guard let take = currentTake, let s = settlement, !s.keep.isEmpty, s.changes else { return false }
        store.keepOnly(s.keep, among: members(of: take).map(\.id))
        if let next = nextPendingTake {
            go(to: next)
        } else {
            allDone = true
        }
        return true
    }

    /// D：这一场先不定，去下一个待处理场。
    func skipTake() {
        guard currentTake != nil, let next = nextPendingTake else { return }
        go(to: next)
    }

    /// ⌘Z。撤的是刚才那次 3 → 那张回到原来的格子（补位的退回候场）；撤的是别的场的
    /// 改动（比如上一场的 ⏎ 定案）→ 跳回那一场，台面按离开时的样子摆回去。
    func undo() {
        let restored = store.undoLastOverride()
        guard !restored.isEmpty else { return }
        allDone = false
        // 先回到出事的那一场……
        if let current = currentTake {
            let takes = Set(restored.compactMap { store.item(withID: $0)?.take })
            if takes.count == 1, let take = takes.first, take != current {
                go(to: take)
            }
        }
        // ……撤的是那一场最近一次 3 淘汰，就把那张放回原来的格子。
        if var list = eliminations[mode], let last = list.last, restored == [last.id] {
            list.removeLast()
            eliminations[mode] = list
            restore(last)
        }
    }

    private func restore(_ e: Elimination) {
        if let idx = stage.firstIndex(of: e.id) {
            active = idx
        } else if let replacement = e.replacement, let idx = stage.firstIndex(of: replacement) {
            stage[idx] = e.id
            active = idx
        } else if stage.count < capacity {
            let slot = min(e.slot, stage.count)
            stage.insert(e.id, at: slot)
            active = slot
        } else if stage.indices.contains(active) {
            stage[active] = e.id
        }
    }

    /// 每屏张数。变少时保住当前格；变多时从候场按排名补。
    func setCapacity(_ n: Int) {
        guard Self.capacities.contains(n), n != capacity else { return }
        capacity = n
        if stage.count > n {
            let keepActive = activeID
            var trimmed = Array(stage.prefix(n))
            if let id = keepActive, !trimmed.contains(id) { trimmed[n - 1] = id }
            stage = trimmed
            active = keepActive.flatMap { trimmed.firstIndex(of: $0) } ?? 0
        } else {
            let onStage = Set(stage)
            for item in Self.ranked(pool.filter { !onStage.contains($0.id) && $0.verdict != .reject })
            where stage.count < n {
                stage.append(item.id)
            }
        }
        // 淘汰记录不清：restore 找不到原格/补位的就插空位或换当前格，照样能放回台上。
    }

    // MARK: 无头脚本

    /// `--compare --keys` 的按键（界面走的是同样这几个方法）。
    @discardableResult
    func handle(_ key: String) -> Bool {
        switch key {
        case "left", "←": move(-1)
        case "right", "→": move(1)
        case "1": setVerdict(.pick)
        case "2": setVerdict(.usable)
        case "3": setVerdict(.reject)
        case "0": setVerdict(nil)
        case "k": toggleMark()
        case "enter", "⏎": settle()
        case "d": skipTake()
        case "undo": undo()
        default:
            if key.hasPrefix("bring:") {
                bringIn(String(key.dropFirst(6)))
            } else if key.hasPrefix("cap:"), let n = Int(key.dropFirst(4)) {
                setCapacity(n)
            } else {
                return false
            }
        }
        return true
    }

    func describe() -> String {
        var lines: [String] = []
        switch mode {
        case .take(let take):
            let members = self.members(of: take)
            let alive = members.filter { $0.verdict != .reject }.count
            lines.append("场 \(take) · \(members.count) 张 · 没淘汰 \(alive) · 待处理 \(pendingTakes().count) 场")
        case .selection(let ids):
            let takes = Set(ids.compactMap { store.item(withID: $0)?.take })
            lines.append("跨场对比 \(ids.count) 张 · \(takes.count) 场")
        }
        func tag(_ id: String) -> String {
            guard let item = store.item(withID: id) else { return "\(id)=?" }
            var s = "\(id)=\(item.verdict.rawValue)"
            if let rank = store.takeRank[id] { s += "#\(rank)" }
            if isMarked(id) { s += "✓" }
            return s
        }
        lines.append("台上: " + stage.enumerated()
            .map { ($0.offset == active ? ">" : "") + tag($0.element) }
            .joined(separator: " "))
        let bench = pool.filter { !stage.contains($0.id) }.map { tag($0.id) }
        lines.append("候场: " + (bench.isEmpty ? "—" : bench.joined(separator: " ")))
        let s = settlement
        let usable = s.map { !$0.keep.isEmpty && $0.changes } ?? false
        lines.append("⏎: " + Self.settleLabel(s) + (usable ? "" : " [不可用]"))
        if allDone { lines.append("所有场都定完了") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 台面排布

/// 台面摆几行几列：让每张照片（按宽高比塞进格子）面积最大。竖拍四张多半一行排开，
/// 横拍四张往往 2×2 —— 不能写死。
enum CompareLayout {
    /// 每格里照片以外的固定高度：标题 + 人脸条 + 数值 + EXIF/改判按钮 + 内边距。
    static let tileChrome: CGFloat = 142
    static let spacing: CGFloat = 8

    static func grid(count n: Int, in size: CGSize, aspect: CGFloat,
                     chrome: CGFloat = CompareLayout.tileChrome,
                     spacing: CGFloat = CompareLayout.spacing) -> (rows: Int, cols: Int) {
        guard n > 1 else { return (1, 1) }
        var best = (rows: 1, cols: n)
        var bestArea: CGFloat = -1
        for rows in 1...n {
            let cols = (n + rows - 1) / rows
            if (rows - 1) * cols >= n { continue }  // 最后一行会是空的
            let cellW = (size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let cellH = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows) - chrome
            guard cellW > 0, cellH > 0 else { continue }
            let w = min(cellW, cellH * aspect)
            let area = w * w / aspect
            if area > bestArea + 1 {
                bestArea = area
                best = (rows, cols)
            }
        }
        return best
    }
}

/// 预览图的宽高比（只读文件头，按路径缓存）。BatchItem 里没有尺寸，排台面要用。
@MainActor
enum PreviewAspect {
    private static var cache: [String: CGFloat] = [:]

    static func ratio(_ path: String) -> CGFloat {
        if let hit = cache[path] { return hit }
        var ratio: CGFloat = 1.5
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 {
            // 预览是分析时转正之后写的，一般没有方向标记；万一有，5–8 是转了 90°。
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            ratio = orientation >= 5 ? CGFloat(h) / CGFloat(w) : CGFloat(w) / CGFloat(h)
        }
        cache[path] = ratio
        return ratio
    }

    static func median(_ paths: [String]) -> CGFloat {
        let ratios = paths.map { ratio($0) }.sorted()
        guard !ratios.isEmpty else { return 1.5 }
        return ratios[ratios.count / 2]
    }
}

// MARK: - 放大：按人脸裁原图

/// 对比放大的原图区域。整幅常驻太贵（40MP 解出来 160MB，四格就是 640MB），连拍比的是
/// 人脸，所以按人脸区域裁一块全分辨率的，裁完就把整幅放掉。
enum CompareZoom {
    final class Crop {
        let image: NSImage
        /// 进入时居中的点：主脸中心，裁块内归一化、左上原点。
        let anchor: CGPoint
        /// 文件 + 裁块，对焦高亮遮罩按它缓存。
        let key: String

        init(image: NSImage, anchor: CGPoint, key: String) {
            self.image = image
            self.anchor = anchor
            self.key = key
        }
    }

    static let cache: NSCache<NSString, Crop> = {
        let c = NSCache<NSString, Crop>()
        c.countLimit = 12
        c.totalCostLimit = ThumbCache.budget(fraction: 0.04, cap: 600_000_000)
        return c
    }()

    /// 同时最多解两张：每张解码时的峰值是整幅，别让六格一起把内存顶上去。
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    /// 裁哪一块（原图像素、左上原点）：所有主体脸的并集，四周各扩一个脸宽（600–1200px）
    /// —— 够拖着看眼睛、发际线和手，又不至于把整幅搬进来；合影自然会宽到接近整幅。
    /// 没有脸就取中间 60%。
    static func region(faces: [[Double]], width: Int, height: Int) -> CGRect {
        // 全用 Double 算：CI 上 Xcode 16 的类型检查器碰到 Double/CGFloat 混算的长式子会超时。
        let fullW = Double(width), fullH = Double(height)
        let full = CGRect(x: 0, y: 0, width: fullW, height: fullH)
        let boxes: [CGRect] = faces.filter { $0.count == 4 }.map { b in
            let x: Double = b[0] * fullW
            let y: Double = b[1] * fullH
            let w: Double = (b[2] - b[0]) * fullW
            let h: Double = (b[3] - b[1]) * fullH
            return CGRect(x: x, y: y, width: w, height: h)
        }
        guard let first = boxes.first else {
            let dx: Double = fullW * 0.2
            let dy: Double = fullH * 0.2
            return full.insetBy(dx: dx, dy: dy).integral
        }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        let side: CGFloat = boxes.map { max($0.width, $0.height) }.max() ?? 0
        let margin: CGFloat = min(max(side, 600), 1200)
        return union.insetBy(dx: -margin, dy: -margin).intersection(full).integral
    }

    private static func cacheKey(_ item: BatchItem) -> String {
        "\(ThumbCache.generation)|\(item.decodePath)"
    }

    /// 界面用：后台解码，最多两张并行。cancel 置位后还没开始的就不解了 —— 连按 Z、
    /// 或者解到一半 Esc 退出对比，排队的整幅解码（每张 160MB）不该接着跑。
    static func load(_ item: BatchItem, cancel: AnalysisEngine.CancelFlag) async -> Crop? {
        if let hit = cache.object(forKey: cacheKey(item) as NSString) { return hit }
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: cancel.isSet ? nil : crop(item))
            }
        }
    }

    /// 同步版（无头 `--compare-crop` 直接调）。
    static func crop(_ item: BatchItem) -> Crop? {
        let key = cacheKey(item)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let full: CGImage
        if let cached = FullResCache.cache.object(forKey: item.decodePath as NSString)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) {
            full = cached  // 检视器/审片刚放大过这张，直接从它裁
        } else {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.decodePath) as CFURL, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 20000,  // 原尺寸
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            full = decoded
        }
        let faces = item.faces.isEmpty ? (item.faceBbox.map { [$0] } ?? []) : item.faces.map(\.bbox)
        let rect = region(faces: faces, width: full.width, height: full.height)
        guard rect.width >= 1, rect.height >= 1,
              let cropped = full.cropping(to: rect),
              let owned = copyPixels(cropped) else { return nil }
        var anchor = CGPoint(x: 0.5, y: 0.5)
        if let b = item.faceBbox ?? faces.first, b.count == 4 {
            let centerX: Double = (b[0] + b[2]) / 2 * Double(full.width)
            let centerY: Double = (b[1] + b[3]) / 2 * Double(full.height)
            let x: Double = (centerX - Double(rect.minX)) / Double(rect.width)
            let y: Double = (centerY - Double(rect.minY)) / Double(rect.height)
            anchor = CGPoint(x: x, y: y)
        }
        let result = Crop(
            image: NSImage(cgImage: owned, size: NSSize(width: owned.width, height: owned.height)),
            anchor: anchor,
            key: key + "|\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))")
        cache.setObject(result, forKey: key as NSString, cost: owned.width * owned.height * 4)
        return result
    }

    /// cropping(to:) 和原图共用同一块像素 —— 不另画一份，整幅解码会跟着裁块一直活着。
    /// 用原图的色彩空间画（P3 的不压成 sRGB），不是 RGB 的才退回 sRGB。
    private static func copyPixels(_ image: CGImage) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? srgb
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: srgb, bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

/// 对比放大时几格一起动：拖、捏、双击任何一格，其余按"离各自人脸中心的偏移"跟过去。
/// 连拍帧之间人会漂，按同一个像素坐标对齐会对到脸旁边去。
final class ZoomLink {
    private final class Member {
        weak var scroll: NSScrollView?
        let anchor: NSPoint

        init(scroll: NSScrollView, anchor: NSPoint) {
            self.scroll = scroll
            self.anchor = anchor
        }
    }

    private var members: [ObjectIdentifier: Member] = [:]
    /// 正在把一格的变化套到别的格上 —— 那些格自己的边界变化通知不能再传出去。
    private var syncing = false
    /// 最近一次联动的倍率和偏移：新补上台的一格照着它摆。
    private var shared: (magnification: CGFloat, delta: NSPoint)?

    /// 入伙：ZoomPane 先按自己的人脸摆好再调这个，有联动状态就照着对齐。
    func register(_ scroll: NSScrollView, anchor: NSPoint) {
        let member = Member(scroll: scroll, anchor: anchor)
        members[ObjectIdentifier(scroll)] = member
        guard let shared else { return }
        syncing = true
        defer { syncing = false }
        apply(shared, to: member)
    }

    func unregister(_ scroll: NSScrollView) {
        members.removeValue(forKey: ObjectIdentifier(scroll))
    }

    func reset() {
        members.removeAll()
        shared = nil
    }

    /// 某一格的可视区变了（拖动、捏合、双击都会走到这）。
    func changed(_ scroll: NSScrollView) {
        guard !syncing, let source = members[ObjectIdentifier(scroll)] else { return }
        let bounds = scroll.contentView.bounds
        let state = (magnification: scroll.magnification,
                     delta: NSPoint(x: bounds.midX - source.anchor.x, y: bounds.midY - source.anchor.y))
        shared = state
        syncing = true
        defer { syncing = false }
        for (key, member) in members where key != ObjectIdentifier(scroll) {
            apply(state, to: member)
        }
    }

    private func apply(_ state: (magnification: CGFloat, delta: NSPoint), to member: Member) {
        guard let scroll = member.scroll else { return }
        if abs(scroll.magnification - state.magnification) > 0.0001 {
            scroll.magnification = state.magnification
        }
        ZoomPane.center(scroll, on: NSPoint(x: member.anchor.x + state.delta.x,
                                            y: member.anchor.y + state.delta.y))
    }
}

// MARK: - 视图

/// 台上几张之间每项的最高值；只有一张、或者大家一样，就不标。按**显示出来的数**比：
/// 123.4 和 123.2 都显示「锐度 123」，只标一张会被读成真有差别。并列最高的都标。
struct CompareBest {
    let sharpness: Int?
    let quality: String?
    let expression: Int?

    init(_ items: [BatchItem]) {
        func top<T: Comparable & Hashable>(_ values: [T]) -> T? {
            values.count >= 2 && Set(values).count > 1 ? values.max() : nil
        }
        sharpness = top(items.map { Self.sharpnessText($0.sharpness) })
        // "0.71" 这类两位小数的字符串按字典序比较和按数值比较一致（都是 0.xx / 1.00）。
        quality = top(items.compactMap { $0.faceQuality.map(Self.qualityText) })
        expression = top(items.compactMap(\.expressionScore))
    }

    static func sharpnessText(_ value: Double) -> Int { Int(value) }
    static func qualityText(_ value: Double) -> String { String(format: "%.2f", value) }
}

struct CompareView: View {
    @ObservedObject var store: BatchStore
    @StateObject private var session: CompareSession
    /// 回网格，带上焦点应落在哪张。
    let onExit: (String?) -> Void

    @AppStorage("compare.capacity") private var capacity = CompareSession.defaultCapacity
    @State private var zoomed = false
    /// 放大时是哪一场：换场就收起放大，不在新场上接着解原图。
    @State private var zoomedMode: CompareSession.Mode?
    @State private var focusPeak = false
    /// 台上各格的放大裁块，只留台上的（CompareZoom.cache 另有一份给回头用）。
    @State private var crops: [String: CompareZoom.Crop] = [:]
    @State private var loadingCrops: Set<String> = []
    @State private var masks: [String: CGImage] = [:]
    @State private var link = ZoomLink()
    /// 每次放大一个号 + 一面取消旗：收起放大 / 换场 / 退出时置旗，排队没开始的原图解码
    /// 直接跳过；回来的结果对不上号就丢，转圈也只由本轮的任务收。
    @State private var zoomGeneration = 0
    @State private var zoomCancel = AnalysisEngine.CancelFlag()
    @FocusState private var keyFocus: Bool

    init(store: BatchStore, request: CompareRequest, sortByScore: Bool, onExit: @escaping (String?) -> Void) {
        self.store = store
        self.onExit = onExit
        let saved = UserDefaults.standard.object(forKey: "compare.capacity") as? Int ?? CompareSession.defaultCapacity
        _session = StateObject(wrappedValue: CompareSession(store: store, request: request,
                                                            capacity: saved, sortByScore: sortByScore))
    }

    var body: some View {
        let pool = session.pool
        // 槽位号跟着 session.stage 走：解析不到的 id 跳过，但剩下的格子还是原来的槽位号，
        // 高亮和按键作用的永远是同一张。
        let slots: [(slot: Int, item: BatchItem)] = session.stage.enumerated().compactMap { entry in
            store.item(withID: entry.element).map { (slot: entry.offset, item: $0) }
        }
        let settlement = session.settlement
        let keepers = Set(settlement?.keep ?? [])
        VStack(spacing: 0) {
            header(pool: pool)
            Divider()
            GeometryReader { geo in
                stageGrid(slots, keepers: keepers, source: settlement?.source, size: geo.size)
            }
            .overlay(alignment: .top) {
                if session.allDone { doneBanner }
            }
            if pool.contains(where: { !session.stage.contains($0.id) }) {
                Divider()
                bench(pool, keepers: keepers)
            }
            Divider()
            footer(settlement)
        }
        .background(Color(white: 0.13))
        .focusable()
        .focused($keyFocus)
        .focusEffectDisabled()
        .onAppear {
            keyFocus = true
            prefetchUpcoming()
        }
        .onDisappear { zoomCancel.set() }
        .onChange(of: store.items.count) { session.pruneMissing() }
        .onChange(of: session.mode) {
            resetZoom()
            prefetchUpcoming()
        }
        .onChange(of: session.stage) {
            let live = Set(session.stage)
            crops = crops.filter { live.contains($0.key) }
            masks = masks.filter { live.contains($0.key) }
            if zoomed, zoomedMode == session.mode { loadCrops() }
        }
        .onChange(of: capacity) { session.setCapacity(capacity) }
        .onChange(of: focusPeak) {
            if focusPeak { refreshMasks() } else { masks = [:] }
        }
        .onKeyPress(.leftArrow) { session.move(-1); return .handled }
        .onKeyPress(.rightArrow) { session.move(1); return .handled }
        .onKeyPress(characters: .init(charactersIn: "1230")) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
            let verdict: Verdict?
            switch press.characters {
            case "1": verdict = .pick
            case "2": verdict = .usable
            case "3": verdict = .reject
            default: verdict = nil
            }
            withAnimation(.easeInOut(duration: 0.15)) { session.setVerdict(verdict) }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "kK")) { press in
            guard press.modifiers.isSubset(of: [.shift, .capsLock]) else { return .ignored }
            session.toggleMark()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "dD")) { press in
            guard press.modifiers.isSubset(of: [.shift, .capsLock]) else { return .ignored }
            session.skipTake()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "zZ")) { press in
            // 只认裸 Z：⌘Z 是撤销按钮的快捷键。
            guard press.modifiers.isSubset(of: [.shift, .capsLock]) else { return .ignored }
            toggleZoom()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "pP")) { press in
            guard press.modifiers.isSubset(of: [.shift, .capsLock]), zoomed else { return .ignored }
            focusPeak.toggle()
            return .handled
        }
    }

    // MARK: 顶栏

    private func header(pool: [BatchItem]) -> some View {
        HStack(spacing: 10) {
            Button { exitOrUnzoom() } label: {
                Label(zoomed ? "适应窗口" : "返回网格",
                      systemImage: zoomed ? "arrow.down.right.and.arrow.up.left" : "chevron.left")
            }
            .keyboardShortcut(.escape, modifiers: [])
            .help(zoomed ? "退出放大 (Esc)" : "回到网格 (Esc)，焦点落在当前格那张")
            title(pool: pool)
            Spacer(minLength: 8)
            Picker("每屏", selection: $capacity) {
                ForEach(CompareSession.capacities, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .help("台上同时摆几张，其余在下方候场条，淘汰一张补一张")
            Button(zoomed ? "适应 (Z)" : "放大到脸 (Z)") { toggleZoom() }
                .help("所有格一起放大到 100%，各自以主脸为中心；拖动、捏合、双击任何一格，其余跟着走")
            Toggle("对焦高亮 (P)", isOn: $focusPeak)
                .toggleStyle(.button)
                .disabled(!zoomed)
                .help("放大后红色标出合焦区域，看焦点落在眼睛还是耳朵")
            Button("撤销") { withAnimation(.easeInOut(duration: 0.15)) { session.undo() } }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndoOverride)
                .help("撤销上一次改判 (⌘Z)。撤的是别的场的定案就跳回那一场")
            if session.currentTake != nil {
                Button("下一场 (D)") { session.skipTake() }
                    .disabled(session.nextPendingTake == nil)
                    .help("这一场先不定，去下一个待处理场")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func title(pool: [BatchItem]) -> some View {
        switch session.mode {
        case .take(let take):
            let alive = pool.filter { $0.verdict != .reject }.count
            let picks = pool.filter { $0.verdict == .pick }.map(\.id)
            HStack(spacing: 8) {
                Text("场 \(take)").font(.headline)
                Text("\(pool.count) 张 · 没淘汰 \(alive)").font(.caption).foregroundStyle(.secondary)
                if let range = BatchView.timeRange(pool) {
                    Text(range).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                if picks.isEmpty {
                    Text("还没有精选").font(.caption).foregroundStyle(.orange)
                } else {
                    Label(picks.joined(separator: "、"), systemImage: "star.fill")
                        .font(.caption).lineLimit(1)
                        .foregroundStyle(Verdict.pick.color)
                        .help("本场现在的精选")
                }
                if store.pendingTakeCount > 0 {
                    Text("待处理 \(store.pendingTakeCount) 场").font(.caption2).foregroundStyle(.orange)
                }
            }
        case .selection(let ids):
            let takes = Set(pool.map(\.take)).count
            HStack(spacing: 8) {
                Text("对比 \(ids.count) 张").font(.headline)
                Text("跨 \(takes) 场 · 逐张改判").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 台面

    @ViewBuilder
    private func stageGrid(_ slots: [(slot: Int, item: BatchItem)], keepers: Set<String>,
                           source: CompareSession.Settlement.Source?, size: CGSize) -> some View {
        let items = slots.map(\.item)
        let inner = CGSize(width: max(1, size.width - 24), height: max(1, size.height - 16))
        let layout = CompareLayout.grid(count: items.count, in: inner,
                                        aspect: PreviewAspect.median(items.map(\.previewPath)))
        let spacing = CompareLayout.spacing
        let cellW = (inner.width - CGFloat(layout.cols - 1) * spacing) / CGFloat(layout.cols)
        let cellH = (inner.height - CGFloat(layout.rows - 1) * spacing) / CGFloat(layout.rows)
        let best = CompareBest(items)
        if items.isEmpty {
            Text("台上没有照片").foregroundStyle(.secondary)
                .frame(width: size.width, height: size.height)
        } else {
            VStack(spacing: spacing) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        // 摆放位置按解析到的顺序排，槽位号用 session.stage 里的真下标。
                        ForEach(Array(slots.enumerated()).filter { $0.offset / layout.cols == row },
                                id: \.element.item.id) { entry in
                            tile(entry.element.item, slot: entry.element.slot,
                                 keep: keepers.contains(entry.element.item.id) ? source : nil, best: best)
                                .frame(width: cellW, height: cellH)
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// keep = 这张在 ⏎ 定案时会留下（以及为什么），nil = 不留。
    private func tile(_ item: BatchItem, slot: Int, keep: CompareSession.Settlement.Source?,
                      best: CompareBest) -> some View {
        let isActive = slot == session.active
        return VStack(alignment: .leading, spacing: 4) {
            tileHeader(item, keep: keep)
            imageArea(item)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    // 绿框 = ⏎ 定案时会留下的。
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(keep != nil ? Verdict.pick.color : Color.clear, lineWidth: 2)
                )
            facesRow(item)
            metricsRow(item, best: best)
            actionRow(item, marked: session.isMarked(item.id))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isActive ? 0.08 : 0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor : Color.white.opacity(0.08), lineWidth: isActive ? 3 : 1)
        )
        .contentShape(Rectangle())
        // 同网格：双击手势 + 同时识别的单击，单击不必等 300ms 排除双击。
        .gesture(TapGesture(count: 2).onEnded {
            session.activate(item.id)
            if !zoomed { toggleZoom() }
        })
        .simultaneousGesture(TapGesture().onEnded {
            session.activate(item.id)
            keyFocus = true
        })
    }

    private func tileHeader(_ item: BatchItem, keep: CompareSession.Settlement.Source?) -> some View {
        HStack(spacing: 5) {
            if let rank = store.takeRank[item.id] {
                Text("#\(rank)").font(.caption2.bold()).monospacedDigit()
                    .foregroundStyle(rank == 1 ? Color.white : Color.white.opacity(0.6))
                    .help("本场评分第 \(rank)")
            }
            Text(item.id).font(.caption.bold()).lineLimit(1).truncationMode(.middle)
            Label(item.verdict.rawValue, systemImage: item.verdict.symbol)
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(item.verdict.color.opacity(0.25), in: Capsule())
                .foregroundStyle(item.verdict.color)
            if store.overrides[item.id] != nil {
                Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(.secondary)
                    .help("人工改判过")
            }
            Spacer(minLength: 0)
            if let keep {
                let badge = Self.keepBadge(keep)
                Label(badge.text, systemImage: keep == .marks ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.caption2.bold())
                    .foregroundStyle(Verdict.pick.color)
                    .help(badge.help)
            }
        }
        .frame(height: 18)
    }

    /// 格子上"会留下"的角标文字。单独一个函数：CI 的 Xcode 16 对结果构建器里的
    /// switch 表达式比本地编译器挑剔。
    private static func keepBadge(_ source: CompareSession.Settlement.Source) -> (text: String, help: String) {
        switch source {
        case .marks: return ("勾选·留", "你勾的：⏎ 定案时留下")
        case .recommended: return ("推荐·留", "算法提名的精选：一张都没勾时，⏎ 定案留下它")
        case .picks: return ("精选·留", "本场现在的精选：一张都没勾时，⏎ 定案留下它")
        case .survivor: return ("最后一张·留", "只剩这一张没淘汰：⏎ 定案把它定为精选")
        }
    }

    @ViewBuilder
    private func imageArea(_ item: BatchItem) -> some View {
        if zoomed, let crop = crops[item.id] {
            ZoomPane(image: crop.image, entry: .hundred, faceBbox: nil, boxColor: .systemYellow,
                     focusMask: focusPeak ? masks[item.id] : nil,
                     anchor: crop.anchor, link: link,
                     onClick: {
                         session.activate(item.id)
                         keyFocus = true
                     })
                .id(crop.key)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SharpImageView(previewPath: item.previewPath, decodePath: item.decodePath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .opacity(item.verdict == .reject ? 0.5 : 1)
                .overlay {
                    if zoomed && loadingCrops.contains(item.id) {
                        ProgressView().controlSize(.small)
                            .padding(8)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
        }
    }

    /// 每格自己的人脸，带睁闭眼圈 —— 不放大就能比眼睛。
    @ViewBuilder
    private func facesRow(_ item: BatchItem) -> some View {
        if !item.faces.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(item.faces.prefix(8).enumerated()), id: \.offset) { _, face in
                        FaceCropView(previewPath: item.previewPath, decodePath: item.decodePath,
                                     face: face, size: 56)
                    }
                    if item.faces.count > 8 {
                        Text("+\(item.faces.count - 8)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 58)
        }
    }

    private func metricsRow(_ item: BatchItem, best: CompareBest) -> some View {
        let sharp = CompareBest.sharpnessText(item.sharpness)
        return HStack(spacing: 8) {
            metric("锐度", "\(sharp)", top: best.sharpness == sharp)
            if let q = item.faceQuality {
                let text = CompareBest.qualityText(q)
                metric("质量", text, top: best.quality == text)
            }
            if let e = item.expressionScore {
                metric("表情", "\(e)", top: best.expression == e)
            }
            eyeSummary(item)
            if !item.rejectReasons.isEmpty {
                Text(item.rejectReasons.joined(separator: "·")).foregroundStyle(.red).lineLimit(1)
                    .help(item.rejectReasons.joined(separator: "、"))
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .frame(height: 16)
    }

    /// EXIF + 可点的改判按钮。键盘之外总得有条路：跨场对比没有 ⏎，只有触控板的时候
    /// 以前的并排对比弹窗是能点精选/可用/废片的。按钮先把这一格设成当前格再改判，
    /// 和按键走同一个方法（3 照样下台）。高亮看的是现在的判决，不是有没有手判过。
    private func actionRow(_ item: BatchItem, marked: Bool) -> some View {
        HStack(spacing: 4) {
            if let exif = item.exif {
                Text(exif.summary).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(exif.lens.map { exif.summary + " · " + $0 } ?? exif.summary)
            }
            Spacer(minLength: 4)
            verdictButton(item, .pick, key: "1")
            verdictButton(item, .usable, key: "2")
            verdictButton(item, .reject, key: "3")
            if session.currentTake != nil {
                Button {
                    session.activate(item.id)
                    session.toggleMark()
                    keyFocus = true
                } label: {
                    Image(systemName: marked ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(marked ? Verdict.pick.color : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(marked ? "取消勾选 (K)" : "勾成要留的 (K)：⏎ 定案时只留勾的")
            }
        }
        .frame(height: 18)
    }

    private func verdictButton(_ item: BatchItem, _ verdict: Verdict, key: String) -> some View {
        let current = item.verdict == verdict
        return Button {
            session.activate(item.id)
            withAnimation(.easeInOut(duration: 0.15)) { session.setVerdict(verdict) }
            keyFocus = true
        } label: {
            Image(systemName: verdict.symbol)
                .font(.caption2.bold())
                .frame(width: 20, height: 16)
                .foregroundStyle(current ? Color.white : verdict.color)
                .background(current ? verdict.color.opacity(0.8) : verdict.color.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("\(verdict.rawValue) (\(key))" + (verdict == .reject ? "：下台，候场补位" : ""))
    }

    /// 台上最高的那一项标绿 + ▲。
    private func metric(_ label: String, _ value: String, top: Bool) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().bold(top)
                .foregroundStyle(top ? Verdict.pick.color : Color.primary)
            if top {
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7))
                    .foregroundStyle(Verdict.pick.color)
            }
        }
    }

    @ViewBuilder
    private func eyeSummary(_ item: BatchItem) -> some View {
        let known = item.faces.filter { $0.eyeClosed != nil }
        if !known.isEmpty {
            let closed = known.filter { $0.eyeClosed == true }.count
            Label(closed > 0 ? "闭眼 \(closed)/\(item.faces.count)" : "睁眼 \(known.count)/\(item.faces.count)",
                  systemImage: closed > 0 ? "eye.slash" : "eye")
                .foregroundStyle(closed > 0 ? Color.red : Color.green)
        }
    }

    // MARK: 候场条 / 底栏

    private func bench(_ pool: [BatchItem], keepers: Set<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                Text(session.currentTake != nil ? "本场 \(pool.count) 张" : "已选 \(pool.count) 张")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(pool) { member in
                    benchCell(member, keep: keepers.contains(member.id))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 94)
        .background(Color.black.opacity(0.2))
    }

    private func benchCell(_ member: BatchItem, keep: Bool) -> some View {
        let onStage = session.stage.contains(member.id)
        let border: Color = onStage ? .accentColor : (keep ? Verdict.pick.color : member.verdict.color.opacity(0.7))
        return VStack(spacing: 2) {
            ThumbnailView(path: member.previewPath, maxPixel: 256, fit: true)
                .frame(width: 64, height: 64)
                .background(Color(white: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: onStage ? 2.5 : 1.5))
                .overlay(alignment: .topTrailing) {
                    if member.verdict == .pick {
                        Image(systemName: "star.fill").font(.system(size: 9))
                            .foregroundStyle(Verdict.pick.color)
                            .padding(2)
                            .background(.black.opacity(0.6), in: Circle())
                            .padding(2)
                    }
                }
                .opacity(member.verdict == .reject && !onStage ? 0.4 : 1)
            Text(onStage ? "台上" : member.verdict.rawValue)
                .font(.system(size: 9))
                .foregroundStyle(onStage ? Color.accentColor : member.verdict.color)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            session.bringIn(member.id)
            keyFocus = true
        }
        .help(onStage ? "\(member.id) 在台上 · 点击切到这一格" : "\(member.id) · 点击换上台（替换当前格）")
    }

    private func footer(_ settlement: CompareSession.Settlement?) -> some View {
        HStack(spacing: 12) {
            Text(session.currentTake != nil
                 ? "←/→ 换格 · 1精选 2可用 3废片(下台) 0恢复 · K 勾要留的 · ⏎ 定案并下一场 · D 跳过 · Z 放大到脸 · ⌘Z 撤销 · Esc 返回"
                 : "←/→ 换格 · 1精选 2可用 3废片(下台) 0恢复 · Z 放大到脸 · ⌘Z 撤销 · Esc 返回")
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let settlement {
                Button(CompareSession.settleLabel(settlement) + " (⏎)") {
                    withAnimation(.easeInOut(duration: 0.15)) { _ = session.settle() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(settlement.keep.isEmpty || !settlement.changes)
                .help("勾选的（没勾就是本场现在的精选）定为精选，本场其余设为废片，然后跳到下一个待处理场。整场一次改判，⌘Z 一次撤销并跳回来")
            } else {
                Text(CompareSession.settleLabel(nil)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var doneBanner: some View {
        Label("所有场都定完了 · Esc 返回网格", systemImage: "checkmark.circle.fill")
            .font(.callout.bold())
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.green.opacity(0.25), in: Capsule())
            .foregroundStyle(.green)
            .padding(.top, 10)
    }

    // MARK: 动作

    private func exitOrUnzoom() {
        if zoomed {
            resetZoom()
            return
        }
        onExit(session.activeID)
    }

    private func toggleZoom() {
        if zoomed {
            resetZoom()
            return
        }
        zoomed = true
        zoomedMode = session.mode
        zoomGeneration += 1
        zoomCancel = AnalysisEngine.CancelFlag()
        loadCrops()
    }

    private func resetZoom() {
        zoomCancel.set()
        zoomGeneration += 1
        zoomed = false
        zoomedMode = nil
        focusPeak = false
        crops = [:]
        masks = [:]
        loadingCrops = []
        link.reset()
    }

    /// 台上还没有裁块的格子去解原图（补位上台的那张也走这里）。
    private func loadCrops() {
        let generation = zoomGeneration
        let cancel = zoomCancel
        for id in session.stage where crops[id] == nil && !loadingCrops.contains(id) {
            guard let item = store.item(withID: id) else { continue }
            loadingCrops.insert(id)
            Task { @MainActor in
                let crop = await CompareZoom.load(item, cancel: cancel)
                // 不是本轮放大发出去的（中间收起/换场过）：结果和转圈都不归它管。
                guard generation == zoomGeneration else { return }
                loadingCrops.remove(id)
                guard zoomed, session.stage.contains(id), let crop else { return }
                crops[id] = crop
                if focusPeak { refreshMasks() }
            }
        }
    }

    private func refreshMasks() {
        guard zoomed, focusPeak else { return }
        for (id, crop) in crops where masks[id] == nil {
            let image = crop.image
            let key = crop.key
            Task.detached(priority: .userInitiated) {
                let mask = FocusMask.compute(from: image, key: key)
                await MainActor.run {
                    guard let mask, zoomed, focusPeak, crops[id]?.key == key else { return }
                    masks[id] = mask
                }
            }
        }
    }

    /// 下一个待处理场开场的那几张先解好，⏎ 之后直接命中缓存。有上限：FitCache 只有
    /// 12 格（每张台上照片占两格：4096 解码 + 锐化成品），预取多了会把台上正在看的挤掉。
    private func prefetchUpcoming() {
        let room = max(0, 6 - session.stage.count)
        for item in session.upcomingStage().prefix(room) {
            let path = item.decodePath
            let px = SharpImageView.fitMaxPixel
            guard FitCache.cache.object(forKey: ThumbCache.key(path, px)) == nil else { continue }
            Task.detached(priority: .utility) {
                _ = FitCache.load(path: path, maxPixel: px)
            }
        }
    }
}
