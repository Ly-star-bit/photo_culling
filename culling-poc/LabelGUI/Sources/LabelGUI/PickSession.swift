import SwiftUI
import AppKit

// MARK: - 连拍挑选（场内对比模式第二版）的交互逻辑
//
// 2026-10-14 用户：重复图片选片「不好用」—— 分组视图被单张淹没、「留这张其余废」太绕、
// 对比模式规则太多（每屏张数 / 候场条 / 3 淘汰补位 / K 勾和 1 精选两套 / 定案按钮的字会变）、
// 看不清比不出来。选了「并排全览」，并补了一句「如果很多，可以左右滚动对比」。现在：
// - 一组 = 一场连拍，全部照片同时上台（多了就单行大图左右滚，见 PickLayout）；
// - 点一张 = 只留它，⌘点 = 多留 / 取消，1–9 = 只留第几张；
// - 屏幕上永远是一份**草稿**，什么都不立刻写；⏎ 按草稿写判决（整组一条撤销记录）并跳到下一个
//   待处理组；↑/↓ 换组不丢草稿；
// - 顶上「第 3/57 组」，⌘Z 撤销会跳回那一组。
// 逻辑全在这里、不碰 SwiftUI：界面不能开着验，无头 `--compare --keys` 驱动的就是这个对象。

/// 怎么进的连拍挑选。
enum PickRequest: Hashable {
    /// 从一场进。preset 非空 = 草稿一开始就是「这几张留、本场其余废」（网格里 ⌘ 选了同一场的
    /// 几张再按 C —— 和批量栏「保留选中·其余废片」同一个意思）；focus = 键盘高亮先落在哪张；
    /// chapter = 时间轴「只看这一章」开着时，这一轮只过这一章的待处理场。
    case take(Int, preset: [String] = [], focus: String? = nil, chapter: Int? = nil)
    /// 跨场 ⌘ 多选的几张：当成临时的一组来挑，没有上一组 / 下一组。
    case selection([String])

    /// ⌘ 多选进来的：全在同一场就按整场挑（选中的预先勾成留），跨场就只挑这几张。
    @MainActor
    static func forSelection(_ ids: [String], store: BatchStore) -> PickRequest? {
        guard ids.count >= 2 else { return nil }
        let takes = Set(ids.compactMap { store.item(withID: $0)?.take })
        if takes.count == 1, let take = takes.first {
            return .take(take, preset: ids)
        }
        return .selection(ids)
    }
}

@MainActor
final class PickSession: ObservableObject {
    /// 跨场多选那一组的组号（场号都是正数）。
    static let selectionKey = Int.min

    /// ⏎ 会怎么定（底栏那句话、无头脚本打印的都是它）。
    struct Outcome: Equatable {
        let picks: [String]
        let usables: [String]
        let rejects: Int
        /// 和现在的判决比，⏎ 会改掉几张的判决。
        let changes: Int
        var keepCount: Int { picks.count + usables.count }
    }

    let store: BatchStore
    /// 和网格的「场内按评分」一致：组内按评分排还是按拍摄顺序排（数字键按显示顺序）。
    let sortByScore: Bool
    /// 这一轮要过的组，进来时冻结、按时间顺序：进来的那一场 + 当时全部待处理的多张场。
    /// 冻结是为了「第 3/57 组」的分母不跟着变；定完的组留在原位，↑ 还能回去看。
    let groups: [Int]
    /// 跨场多选的那几张（这时 groups == [selectionKey]）。
    let selectionIDs: [String]?
    @Published private(set) var position: Int
    /// 键盘高亮（当前组里的下标）：空格 / ⇧空格 / Z 的对象，←/→ 移动。
    @Published private(set) var highlight = 0
    /// 草稿：组 → (id → 判决)。没有草稿的组按 `recommended` 显示。⏎ 才写进 store。
    @Published private(set) var drafts: [Int: [String: Verdict]] = [:]
    /// 最后一个待处理组也定完了（或跨场那一组确认了）。
    @Published private(set) var allDone = false
    /// 数字键「选完直接下一组」（Lightroom 的 Auto Advance）：1–9 = 只留第几张 + 确认 + 下一组，
    /// 一组一个键。只管数字键 —— 点击 / ⌘点 / 空格是在比的时候用的，不能一碰就定案。
    var autoAdvance = false
    /// ⌘Z 的一步。按时间顺序记在一条日志里（审查发现：以前每组各记各的，在 B 组点过、回 A 组确认，
    /// ⌘Z 先撤的却是 B 组的点击）。
    enum UndoStep {
        /// 改草稿：改之前的样子。
        case draft(key: Int, previous: [String: Verdict]?)
        /// 确认写进了 store（store 里对应一条撤销记录）；draft = 确认那一刻的草稿，撤销后原样摆回来。
        case commit(key: Int, draft: [String: Verdict]?)
    }
    /// 这一轮里的操作日志，⌘Z 从最新的往回撤；撤空了再撤进来之前的判决（store 的撤销栈）。
    @Published private(set) var undoLog: [UndoStep] = []

    init(store: BatchStore, request: PickRequest, sortByScore: Bool) {
        self.store = store
        self.sortByScore = sortByScore
        switch request {
        case .take(let take, let preset, let focus, let chapter):
            var set = Set(store.pendingTakes)
            if let chapter {
                set = set.filter { t in
                    store.members(ofTake: t).first.map(BatchStore.timelineChapter(of:)) == chapter
                }
            }
            set.insert(take)
            let groups = set.filter { (store.takeSizes[$0] ?? 0) >= 2 }.sorted()
            self.groups = groups
            selectionIDs = nil
            position = groups.firstIndex(of: take) ?? 0
            let members = Set(self.frames(of: take).map(\.id))
            let keep = Set(preset).intersection(members)
            if !keep.isEmpty {
                drafts[take] = Dictionary(members.map { ($0, keep.contains($0) ? Verdict.pick : .reject) },
                                          uniquingKeysWith: { first, _ in first })
            }
            highlight = initialHighlight(focus: focus)
        case .selection(let ids):
            groups = [Self.selectionKey]
            selectionIDs = ids
            position = 0
            highlight = initialHighlight(focus: nil)
        }
    }

    // MARK: 数据

    var currentKey: Int { groups.indices.contains(position) ? groups[position] : Self.selectionKey }

    /// 当前是一场（不是跨场多选）就返回场号。
    var currentTake: Int? {
        let key = currentKey
        return key == Self.selectionKey ? nil : key
    }

    var isSelection: Bool { selectionIDs != nil }

    /// 当前组的照片，按显示顺序。
    var frames: [BatchItem] { frames(of: currentKey) }

    var highlightedID: String? {
        let frames = self.frames
        return frames.indices.contains(highlight) ? frames[highlight].id : nil
    }

    /// 一组的照片。场：和网格那一行同一个顺序（拍摄时间；开了「场内按评分」就按评分）。跨场：网格顺序。
    func frames(of key: Int) -> [BatchItem] {
        if key == Self.selectionKey {
            let wanted = Set(selectionIDs ?? [])
            return store.items.filter { wanted.contains($0.id) }
        }
        var members = store.members(ofTake: key)
        if sortByScore {
            members.sort { a, b in
                let ka = BatchStore.scoreKey(a), kb = BatchStore.scoreKey(b)
                return ka == kb ? a.id < b.id : ka > kb
            }
        }
        return members
    }

    /// 这一组还待处理吗（跨场那组不算）。
    func isPending(_ key: Int) -> Bool {
        key != Self.selectionKey && store.isPendingTake(alive: frames(of: key).filter { $0.verdict != .reject })
    }

    /// 这一轮里已经不再待处理的组数（顶栏进度）。
    var decidedCount: Int {
        let pending = Set(store.pendingTakes)
        return groups.filter { $0 != Self.selectionKey && !pending.contains($0) }.count
    }

    // MARK: 草稿

    /// 一组现在的草稿（没动过就是推荐）。草稿里的照片和这一组现在的照片对不上（开着这个界面时
    /// 分析跑完、场号重排了）就作废 —— 不然 ⏎ 会把新进来的照片当成「没勾」一起废掉。
    func draft(for key: Int) -> [String: Verdict] {
        guard let d = drafts[key] else { return recommended(key) }
        guard Set(d.keys) == Set(frames(of: key).map(\.id)) else { return recommended(key) }
        return d
    }

    /// 推荐草稿。还待处理的场：现在的精选留（自动提名的或你按 1 的）、你手动标过可用的留作可用，
    /// 其余废 —— 和分组行的「接受推荐」同一个结果。定过的场、跨场多选：就是现在的判决
    /// （打开来看看、什么都不动，⏎ 就什么都不改）。
    func recommended(_ key: Int) -> [String: Verdict] {
        let frames = self.frames(of: key)
        if isPending(key) { return store.recommendedDecision(for: frames) }
        return Dictionary(frames.map { ($0.id, $0.verdict) }, uniquingKeysWith: { first, _ in first })
    }

    var outcome: Outcome { outcome(for: currentKey) }

    func outcome(for key: Int) -> Outcome {
        let frames = self.frames(of: key)
        let draft = self.draft(for: key)
        var picks: [String] = [], usables: [String] = []
        var rejects = 0, changes = 0
        for f in frames {
            let v = draft[f.id] ?? .reject
            switch v {
            case .pick: picks.append(f.id)
            case .usable: usables.append(f.id)
            case .reject: rejects += 1
            }
            if v != f.verdict { changes += 1 }
        }
        return Outcome(picks: picks, usables: usables, rejects: rejects, changes: changes)
    }

    /// 草稿被手动改过（和推荐不一样）—— 底栏才显示「恢复推荐」。
    var draftEdited: Bool { isEdited(currentKey) }

    func isEdited(_ key: Int) -> Bool {
        guard drafts[key] != nil else { return false }
        return draft(for: key) != recommended(key)
    }

    /// 改过但还没确认的组（按顺序）。Esc 离开前要问一声 —— 草稿模式下点了不按 ⏎ 是不会写的。
    var unconfirmedGroups: [Int] { groups.filter { isEdited($0) } }

    // MARK: 操作

    /// 改草稿前记一笔，⌘Z 撤回用。
    private func recordDraft() {
        log(.draft(key: currentKey, previous: drafts[currentKey]))
    }

    private func log(_ step: UndoStep) {
        undoLog.append(step)
        // store 的撤销栈只留 100 条；这里留宽一点，草稿步也占位置。
        if undoLog.count > 300 { undoLog.removeFirst(undoLog.count - 300) }
    }

    /// 只留这一张（点击 / 数字键 / 空格）：它精选，**和它同一场的**其余废。一组本来就是一场，
    /// 所以就是「只留这张」；跨场多选里别的场的照片不动 —— 它们不是这张的重复，不能因为点了这张
    /// 就被废掉（审查发现的回归：旧对比模式跨场时只改你逐张按过的）。
    func choose(_ id: String) {
        let frames = self.frames
        guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
        let take = frames[idx].take
        var d = draft(for: currentKey)
        for f in frames {
            if f.id == id {
                d[f.id] = .pick
            } else if f.take == take {
                d[f.id] = .reject
            }
        }
        recordDraft()
        drafts[currentKey] = d
        highlight = idx
    }

    /// 数字键：只留第 n 张（1 起，按显示顺序）。
    func choose(number n: Int) {
        let frames = self.frames
        guard n >= 1, n <= frames.count else { return }
        choose(frames[n - 1].id)
    }

    /// 数字键真正走的入口：开了「选完直接下一组」就顺手确认。超出本组张数的数字什么都不做。
    func press(number n: Int) {
        guard n >= 1, n <= frames.count else { return }
        choose(number: n)
        if autoAdvance { confirm() }
    }

    /// ⌘点 / ⇧空格：这一张在留和废之间切（多留几张）。
    func toggle(_ id: String) {
        let frames = self.frames
        guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
        var d = draft(for: currentKey)
        d[id] = (d[id] ?? .reject) == .reject ? .pick : .reject
        recordDraft()
        drafts[currentKey] = d
        highlight = idx
    }

    func chooseHighlighted() {
        if let id = highlightedID { choose(id) }
    }

    func toggleHighlighted() {
        if let id = highlightedID { toggle(id) }
    }

    func move(_ delta: Int) {
        let count = frames.count
        guard count > 0 else { return }
        highlight = max(0, min(count - 1, highlight + delta))
    }

    func highlight(_ id: String) {
        if let idx = frames.firstIndex(where: { $0.id == id }) { highlight = idx }
    }

    /// 0 / 「恢复推荐」：扔掉这一组的草稿。
    func resetDraft() {
        guard drafts[currentKey] != nil else { return }
        recordDraft()
        drafts[currentKey] = nil
        highlight = initialHighlight(focus: nil)
    }

    /// ⏎：按草稿写判决（整组一条撤销记录），然后去下一个还待处理的组；都定完了就停在这里亮横幅。
    /// - 只写和现在的人工判决不一样的（不往撤销栈里塞空操作）；
    /// - 一张判决都不变、这组也不待处理（回头看看定过的组、跨场多选没动）就什么都不写 —— 不然
    ///   自动判的照片会被顺手写成人工判决，以后拧滑杆它们就不跟着动了。还待处理的组哪怕判决不变也要写：
    ///   写成人工的这一组才算定了，不然 ⏎ 完它还在待处理里，D 和下一组会一直绕回来。
    @discardableResult
    func confirm() -> Bool {
        guard !frames.isEmpty else { return false }
        commit(currentKey)
        advance()
        return true
    }

    /// 把一组的草稿写进 store（不换组）。写了东西就在日志里记一步「确认」。
    private func commit(_ key: Int) {
        let frames = self.frames(of: key)
        guard !frames.isEmpty else { return }
        let draft = self.draft(for: key)
        let unchanged = frames.allSatisfy { (draft[$0.id] ?? .reject) == $0.verdict }
        if !(unchanged && !isPending(key)) {
            var writes: [String: Verdict] = [:]
            for f in frames {
                let v = draft[f.id] ?? .reject
                if store.overrides[f.id] != v { writes[f.id] = v }
            }
            if !writes.isEmpty {
                store.applyOverrides(writes)
                log(.commit(key: key, draft: drafts[key]))
            }
        }
        drafts[key] = nil
    }

    /// Esc 离开前「确认这几组」：改过没确认的组挨个写进去（每组一条撤销记录），不换组。
    func confirmUnconfirmed() {
        for key in unconfirmedGroups { commit(key) }
    }

    /// 当前之后第一个还待处理的组（到底绕回开头）在 groups 里的下标；⏎ 去的就是它。
    var upcomingIndex: Int? {
        guard !isSelection else { return nil }
        let pending = Set(store.pendingTakes)
        let order = Array(groups.indices.dropFirst(position + 1)) + Array(groups.indices.prefix(position))
        return order.first { pending.contains(groups[$0]) }
    }

    /// ⏎ 之后：去下一个还待处理的组；都没有了就停在这里亮「定完了」。
    private func advance() {
        if let next = upcomingIndex {
            go(to: next)
        } else {
            allDone = true
            highlight = initialHighlight(focus: nil)
        }
    }

    /// 双击放大时撤回第一下单击：双击是「看清楚」，不是「选它」。只撤日志里最新的一步，而且得是
    /// 当前这一组的改草稿。
    @discardableResult
    func revertLastDraftChange() -> Bool {
        guard case .draft(let key, let previous)? = undoLog.last, key == currentKey else { return false }
        undoLog.removeLast()
        drafts[key] = previous
        return true
    }

    func go(to index: Int) {
        guard groups.indices.contains(index) else { return }
        position = index
        allDone = false
        highlight = initialHighlight(focus: nil)
    }

    /// ↓ / ↑：换组，不确认、草稿留着（回来还是你点过的样子）。
    func next() { go(to: position + 1) }
    func previous() { go(to: position - 1) }

    var hasNext: Bool { position + 1 < groups.count }
    var hasPrevious: Bool { position > 0 }

    /// ⌘Z 能不能按：这一轮里有操作可撤，或者 store 里还有进来之前的判决可撤。
    var canUndo: Bool { !undoLog.isEmpty || store.canUndoOverride }

    /// ⌘Z，按时间顺序：最新一步是改草稿 → 那一组的草稿回到改之前（不在那一组就跳过去）；是确认 →
    /// store 撤销那一次写入，跳回那一组，草稿摆回确认那一刻的样子（你当时点的哪张还是哪张）。
    /// 这一轮的日志撤空了，再撤进来之前的判决（比如网格里刚做的），撤的是某一组就跳过去。
    func undo() {
        allDone = false
        if let step = undoLog.popLast() {
            switch step {
            case .draft(let key, let previous):
                drafts[key] = previous
                show(key)
            case .commit(let key, let draft):
                store.undoLastOverride()
                drafts[key] = draft
                show(key)
            }
            return
        }
        let restored = store.undoLastOverride()
        guard !restored.isEmpty else { return }
        let takes = Set(restored.compactMap { store.item(withID: $0)?.take })
        if !isSelection, takes.count == 1, let take = takes.first {
            show(take)
        } else {
            highlight = min(highlight, max(0, frames.count - 1))
        }
    }

    /// 撤销后把那一组摆到眼前：不在那一组就跳过去；就在这一组只把高亮夹回范围。
    private func show(_ key: Int) {
        if key != currentKey, let idx = groups.firstIndex(of: key) {
            go(to: idx)
        } else {
            highlight = min(highlight, max(0, frames.count - 1))
        }
    }

    /// 照片被移走（废纸篓 / 重新分析）后把高亮夹回范围内。
    func pruneMissing() {
        highlight = min(highlight, max(0, frames.count - 1))
    }

    private func initialHighlight(focus: String?) -> Int {
        let frames = self.frames
        if let focus, let idx = frames.firstIndex(where: { $0.id == focus }) { return idx }
        let draft = self.draft(for: currentKey)
        return frames.firstIndex { draft[$0.id] == .pick }
            ?? frames.firstIndex { draft[$0.id] == .usable }
            ?? 0
    }

    // MARK: 文字（底栏 + 无头脚本）

    /// 底栏那句话：⏎ 之后会是什么样。
    static func outcomeText(_ o: Outcome) -> String {
        if o.keepCount == 0 { return "整组 \(o.rejects) 张全部废片" }
        func names(_ ids: [String]) -> String {
            ids.count <= 3 ? ids.joined(separator: "、") : ids.prefix(3).joined(separator: "、") + " 等 \(ids.count) 张"
        }
        var parts: [String] = []
        if !o.picks.isEmpty { parts.append("精选 \(names(o.picks))") }
        if !o.usables.isEmpty { parts.append("可用 \(names(o.usables))") }
        var text = "留 \(o.keepCount) 张：" + parts.joined(separator: "；")
        if o.rejects > 0 { text += " · 其余 \(o.rejects) 张废片" }
        return text
    }

    // MARK: 无头脚本

    /// `--compare --keys` 的按键（界面走的是同样这几个方法）。
    @discardableResult
    func handle(_ key: String) -> Bool {
        switch key {
        case "left", "←": move(-1)
        case "right", "→": move(1)
        case "up", "↑": previous()
        case "down", "↓": next()
        case "space": chooseHighlighted()
        case "shift-space", "⇧space": toggleHighlighted()
        case "enter", "⏎": confirm()
        case "undo": undo()
        case "0", "reset": resetDraft()
        default:
            if let n = Int(key), (1...9).contains(n) {
                press(number: n)
            } else if key.hasPrefix("click:") {
                choose(String(key.dropFirst(6)))
            } else if key.hasPrefix("cmd:") {
                toggle(String(key.dropFirst(4)))
            } else {
                return false
            }
        }
        return true
    }

    func describe() -> String {
        var lines: [String] = []
        let key = currentKey
        let frames = self.frames
        if isSelection {
            let takes = Set(frames.map(\.take)).count
            lines.append("连拍挑选 · 跨 \(takes) 场 \(frames.count) 张")
        } else {
            let unconfirmed = unconfirmedGroups.count
            lines.append("连拍挑选 · 第 \(position + 1)/\(groups.count) 组 · 已定 \(decidedCount) · 场 \(key) · \(frames.count) 张"
                         + (isPending(key) ? "（待处理）" : "（已定）") + (unconfirmed > 0 ? " · 未确认 \(unconfirmed) 组" : ""))
        }
        let draft = self.draft(for: key)
        let faces = FaceAlignment(frames: frames)
        for (i, f) in frames.enumerated() {
            let v = draft[f.id] ?? .reject
            let mark = v == .reject ? "废" : (v == .pick ? "留★" : "留·可用")
            let rank = store.takeRank[f.id].map { " #\($0)" } ?? ""
            let override = store.overrides[f.id] != nil ? " ✋" : ""
            lines.append("\(i == highlight ? ">" : " ")\(i + 1) \(f.id) 现在\(f.verdict.rawValue)\(override) → \(mark)\(rank)"
                         + faces.describe(f.id))
        }
        let o = outcome
        lines.append("⏎: " + Self.outcomeText(o) + (o.changes > 0 ? " · 改 \(o.changes) 张" : " · 不改判决")
                     + (draftEdited ? " · 草稿已改" : ""))
        if allDone { lines.append(isSelection ? "这一组定好了" : "待处理的组都定完了") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 台面排布

/// 一组怎么摆：一屏放得下、图又不小，就按行列铺满（每张图面积最大）；张数多到会挤成小图，
/// 就改成单行大图左右滚动（用户：「如果很多，可以左右滚动对比」）。
enum PickLayout {
    enum Arrangement: Equatable {
        case grid(rows: Int, cols: Int)
        case strip
    }

    struct Result: Equatable {
        let arrangement: Arrangement
        /// 照片框（按这一组的中位宽高比算；别的比例在框里等比放）。
        let image: CGSize
        /// 人脸条每张脸的边长，0 = 这一组没有脸、不留人脸条。
        let faceSize: CGFloat
    }

    static let spacing: CGFloat = 10
    static let margin: CGFloat = 12
    static let tilePadding: CGFloat = 8
    static let innerSpacing: CGFloat = 6
    static let metricsHeight: CGFloat = 16
    /// 一屏铺满时图的短边低于这个就不硬塞了，改单行滚动。4 张以内总是一屏铺满。
    static let minShortSide: CGFloat = 220
    /// 单行滚动时一屏至少露出这么多张（太宽的横片不至于一屏只看见一张多）。
    static let stripVisible: CGFloat = 2.3

    /// 照片以外的高度：内边距 + 人脸条 + 数值行。
    static func chrome(face: CGFloat) -> CGFloat {
        tilePadding * 2 + metricsHeight + innerSpacing + (face > 0 ? face + innerSpacing : 0)
    }

    static func faceSize(count n: Int, strip: Bool, hasFaces: Bool) -> CGFloat {
        guard hasFaces else { return 0 }
        if strip { return 84 }
        switch n {
        case ...2: return 96
        case 3...4: return 84
        case 5...6: return 72
        default: return 60
        }
    }

    static func compute(count n: Int, in size: CGSize, aspect: CGFloat, hasFaces: Bool) -> Result {
        let n = max(1, n)
        let aspect = max(0.2, min(5, aspect))
        let face = faceSize(count: n, strip: false, hasFaces: hasFaces)
        let chrome = chrome(face: face)
        var best: (rows: Int, cols: Int, w: CGFloat, h: CGFloat)?
        for rows in 1...n {
            let cols = (n + rows - 1) / rows
            if (rows - 1) * cols >= n { continue }  // 最后一行会是空的
            let cellW = (size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols) - tilePadding * 2
            let cellH = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows) - chrome
            guard cellW > 0, cellH > 0 else { continue }
            let w = min(cellW, cellH * aspect)
            let h = w / aspect
            if best == nil || w * h > best!.w * best!.h + 1 { best = (rows, cols, w, h) }
        }
        if let b = best, n <= 4 || min(b.w, b.h) >= minShortSide {
            return Result(arrangement: .grid(rows: b.rows, cols: b.cols),
                          image: CGSize(width: floor(b.w), height: floor(b.h)), faceSize: face)
        }
        let stripFace = faceSize(count: n, strip: true, hasFaces: hasFaces)
        var h = size.height - Self.chrome(face: stripFace)
        var w = h * aspect
        let maxW = (size.width - spacing * 2) / stripVisible - tilePadding * 2
        if w > maxW {
            w = maxW
            h = w / aspect
        }
        return Result(arrangement: .strip,
                      image: CGSize(width: floor(max(80, w)), height: floor(max(60, h))), faceSize: stripFace)
    }
}

// MARK: - 人脸按人对齐（Narrative Close-ups 那种：每个人一列，几张之间比同一个人）

/// 一组照片里「同一个人」的脸。连拍里人基本不动：以脸最多的那张为锚，每张的脸从左到右；
/// 张数和锚一样就按位置一一对应，不一样（有人转头没检测到）就各自找最近的锚。
/// 只用来显示，不碰判决（判决层的闭眼规则在 BatchStore.applyThresholds）。
@MainActor
struct FaceAlignment {
    enum Eye: Equatable {
        case open
        /// 半闭 / 眯眼 / 低头：判决层没算闭眼，但这张眼睛明显比这个人在本组睁得最开的那张小 ——
        /// Narrative 的黄色「可能不理想」。只是提示，不进判决。
        case squint
        case closed
        case unknown
    }

    struct Slot {
        let face: FaceInfo
        let eye: Eye
        /// 这个人在本组里眼睛最好的那张（只在本组有人眯眼 / 闭眼时才标，全都睁得好好的不标）。
        let bestEyes: Bool
    }

    /// 眯眼：EAR 低于这个人本组最好的这个比例。纯相对、不设绝对线 —— 判决层的「≥0.22 一律睁眼」
    /// 是防误杀的，可提示要的正是 0.25 对 0.40 这种「没闭但明显没睁满」。实测 photot 一场 10 张：
    /// 正常睁眼在最好那张的 0.80–1.00，眼睛明显小的那张 0.60（DSCF7224），0.75 正好分开。
    static let squintFactor = 0.75

    /// 人数（以脸最多的那张为准）。
    let people: Int
    /// 照片 id → 每个人的脸（下标 = 人；nil = 这张里没检测到这个人）。
    let slots: [String: [Slot?]]

    init(frames: [BatchItem]) {
        func center(_ f: FaceInfo) -> CGPoint {
            guard f.bbox.count == 4 else { return .zero }
            return CGPoint(x: (f.bbox[0] + f.bbox[2]) / 2, y: (f.bbox[1] + f.bbox[3]) / 2)
        }
        let sorted: [(id: String, faces: [FaceInfo])] = frames.map { item in
            (item.id, item.faces.filter { $0.bbox.count == 4 }.sorted { center($0).x < center($1).x })
        }
        let anchorFaces = sorted.max { $0.faces.count < $1.faces.count }?.faces ?? []
        let anchors = anchorFaces.map(center)
        people = anchors.count

        // 先对齐。
        var assigned: [String: [FaceInfo?]] = [:]
        for (id, faces) in sorted {
            var row = [FaceInfo?](repeating: nil, count: people)
            if faces.count == people {
                for i in 0..<people { row[i] = faces[i] }
            } else {
                var pairs: [(face: Int, anchor: Int, d: CGFloat)] = []
                for (fi, f) in faces.enumerated() {
                    let c = center(f)
                    for (ai, a) in anchors.enumerated() {
                        pairs.append((fi, ai, hypot(c.x - a.x, c.y - a.y)))
                    }
                }
                var usedFace = Set<Int>(), usedAnchor = Set<Int>()
                for p in pairs.sorted(by: { $0.d < $1.d }) where !usedFace.contains(p.face) && !usedAnchor.contains(p.anchor) {
                    row[p.anchor] = faces[p.face]
                    usedFace.insert(p.face)
                    usedAnchor.insert(p.anchor)
                }
            }
            assigned[id] = row
        }

        // 每个人本组睁得最开的 EAR（太小的脸 EAR 不可信，和判决层同一条线）。
        func usableEar(_ f: FaceInfo) -> Double? {
            guard let ear = f.ear else { return nil }
            if let area = f.areaPct, area < BatchStore.minEarFaceAreaPct { return nil }
            return ear
        }
        var bestEar = [Double?](repeating: nil, count: people)
        var bestID = [String?](repeating: nil, count: people)
        for (id, _) in sorted {
            for p in 0..<people {
                guard let f = assigned[id]?[p], let ear = usableEar(f) else { continue }
                if bestEar[p] == nil || ear > bestEar[p]! {
                    bestEar[p] = ear
                    bestID[p] = id
                }
            }
        }
        func eye(_ f: FaceInfo, person p: Int) -> Eye {
            if f.eyeClosed == true { return .closed }
            if let ear = usableEar(f), let best = bestEar[p], best > 0, ear < best * Self.squintFactor {
                return .squint
            }
            return f.eyeClosed == false ? .open : .unknown
        }
        // 谁需要标「眼睛最好」：这个人在本组里有眯眼或闭眼的那几张时才标，不然全是噪音。
        var troubled = [Bool](repeating: false, count: people)
        for (id, _) in sorted {
            for p in 0..<people {
                guard let f = assigned[id]?[p] else { continue }
                let e = eye(f, person: p)
                if e == .squint || e == .closed { troubled[p] = true }
            }
        }
        var slots: [String: [Slot?]] = [:]
        for (id, _) in sorted {
            slots[id] = (0..<people).map { p in
                guard let f = assigned[id]?[p] else { return nil }
                let e = eye(f, person: p)
                return Slot(face: f, eye: e, bestEyes: troubled[p] && bestID[p] == id && e == .open)
            }
        }
        self.slots = slots
    }

    /// 这张的睁眼小结（底下数值行 + 无头脚本）：闭眼几个、眯眼几个、看得出的一共几个。
    func summary(_ id: String) -> (closed: Int, squint: Int, known: Int) {
        var closed = 0, squint = 0, known = 0
        for slot in slots[id] ?? [] {
            guard let slot else { continue }
            switch slot.eye {
            case .closed: closed += 1; known += 1
            case .squint: squint += 1; known += 1
            case .open: known += 1
            case .unknown: break
            }
        }
        return (closed, squint, known)
    }

    /// 无头脚本里的一格：每个人一个字（开 / 眯 / 闭 / ? / — 没检测到），最好的那个带 ★。
    func describe(_ id: String) -> String {
        guard people > 0 else { return "" }
        let marks = (slots[id] ?? []).map { slot -> String in
            guard let slot else { return "—" }
            let base: String
            switch slot.eye {
            case .open: base = "开"
            case .squint: base = "眯"
            case .closed: base = "闭"
            case .unknown: base = "?"
            }
            return slot.bestEyes ? base + "★" : base
        }
        return " 眼[" + marks.joined(separator: " ") + "]"
    }
}
