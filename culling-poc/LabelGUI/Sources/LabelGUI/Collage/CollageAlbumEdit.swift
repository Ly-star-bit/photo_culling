import Foundation

/// 相册跨页操作的纯函数（相册 A + B 第 1 波 · S）：跨页里谁先谁后（F4）、「拼图 (N)」切成几个新跨页（F3）、
/// 挪跨页（S2）、镜像（S3）、锁住的跨页和重排的合在一起（S5）、换照片的候选（S6）。
/// CollageStore 的相册段包一层撤销；--album-selftest（CollageAlbumEditSelfTest）直接测这里，不要照片。
extension CollageAlbum {

    // MARK: - F4 拍摄先后

    /// a 是不是比 b 先拍（F4：跨页里左页放早的、右页放晚的，页内照阅读顺序）：有拍摄时间的按 captureTime + captureSubsec
    /// （captureTime 只到整秒，同一秒的连拍看小数秒），同一刻按文件名（数字按数值比：DSCF998 在 DSCF1000 前面）；
    /// 没有时间的排在有时间的后面，按文件名。文件名一样（两个文件夹的同名照片）再按 id，先后总是定的。
    /// 编排分章、分跨页仍用 CollageSelect.chronological（不看小数秒）：改它会动编排结果和门禁的断言。
    static func shotEarlier(_ a: CollagePhotoRef, _ b: CollagePhotoRef) -> Bool {
        switch (a.captureTime, b.captureTime) {
        case let (x?, y?):
            let ta = x.timeIntervalSinceReferenceDate + (a.captureSubsec ?? 0)
            let tb = y.timeIntervalSinceReferenceDate + (b.captureSubsec ?? 0)
            if ta != tb { return ta < tb }
            return fileEarlier(a, b)
        case (nil, nil): return fileEarlier(a, b)
        case (nil, _): return false
        case (_, nil): return true
        }
    }

    private static func fileEarlier(_ a: CollagePhotoRef, _ b: CollagePhotoRef) -> Bool {
        let na = (a.path as NSString).lastPathComponent
        let nb = (b.path as NSString).lastPathComponent
        switch na.compare(nb, options: [.numeric]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id < b.id
        }
    }

    /// 按拍摄先后排好的照片。
    static func shotOrder(_ photos: [CollagePhotoRef]) -> [CollagePhotoRef] {
        photos.sorted(by: shotEarlier)
    }

    /// 求解器的格子按拍摄先后：photos = 照片格的下标（先拍的在前；不在 photos 里的照片排最后、保持原来的先后），
    /// others = 文字格、留白格（没有时间，求解器随机插在照片之间）。
    static func timeOrderedCells(_ cells: [CollageCell], photos map: [String: CollagePhotoRef])
        -> (photos: [Int], others: [Int]) {
        var known: [(Int, CollagePhotoRef)] = []
        var unknown: [Int] = []
        var others: [Int] = []
        for (i, cell) in cells.enumerated() {
            if cell.kind == .photo {
                if let id = cell.photoID, let p = map[id] { known.append((i, p)) } else { unknown.append(i) }
            } else {
                others.append(i)
            }
        }
        let sorted = known.sorted { x, y in
            if shotEarlier(x.1, y.1) { return true }
            if shotEarlier(y.1, x.1) { return false }
            return x.0 < y.0
        }
        return (sorted.map(\.0) + unknown, others)
    }
}

// MARK: - F3「拼图 (N)」切成几个新跨页

extension CollageAlbum {

    /// 默认编排每跨页最多几张（同 plan 的 maxPerSpread 默认值）。
    static let defaultMaxPerSpread = 5

    /// 「拼图 (N)」带进相册时每个新跨页最多几张（F3）：照默认编排 —— 设了目标跨页数用它的每跨页最多，没设 5 张；
    /// 婚礼相册 3 张（CollageStyleFineArt.maxPerSpread；只管张数，不套 fine-art 的版式规则）。
    static func handoffCap(theme: CollageAlbumTheme, budget: CollageAlbumBudget?) -> Int {
        if theme == .fineArt { return CollageStyleFineArt.maxPerSpread }
        return budget?.normalized.maxPerSpread ?? defaultMaxPerSpread
    }

    /// 按拍摄先后切成几个跨页：跨页数 = ⌈张数 / cap⌉，每个跨页张数尽量匀（12 张、最多 5 张 → 4 4 4，不是 5 5 2）。
    static func handoffChunks(_ photos: [CollagePhotoRef], cap: Int) -> [[CollagePhotoRef]] {
        let ordered = shotOrder(photos)
        guard !ordered.isEmpty else { return [] }
        let c = max(1, cap)
        let k = (ordered.count + c - 1) / c
        var out: [[CollagePhotoRef]] = []
        var start = 0
        for i in 0..<k {
            let size = ordered.count / k + (i < ordered.count % k ? 1 : 0)
            out.append(Array(ordered[start..<(start + size)]))
            start += size
        }
        return out
    }
}

// MARK: - S2 挪跨页

extension CollageAlbum {

    /// 几项一起挪到 destination（同 SwiftUI onMove：destination 是挪之前的下标，挪到它前面；≥ 个数 = 挪到最后）。
    /// 挪的几项保持原来的先后；不在范围里的下标不管。
    static func moved<T>(_ items: [T], from indices: IndexSet, to destination: Int) -> [T] {
        let picked = indices.filter { items.indices.contains($0) }
        guard !picked.isEmpty else { return items }
        let set = Set(picked)
        let moving = picked.map { items[$0] }
        var rest = items.enumerated().filter { !set.contains($0.offset) }.map(\.element)
        let at = destination - picked.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(0, at), rest.count))
        return rest
    }
}

// MARK: - S3 镜像

extension CollageAlbum {

    /// 一棵切分树左右镜像：横排切分（.row）的两个孩子对调、ratio → 1 − ratio，一路递归下去；竖排切分只往下递归。
    /// 格子里的东西原样（照片不翻像素、取景不变、字的左右对齐不变：文字格跟着格子走）。
    /// 做两次回到原样：结构、格子逐个相同；ratio 是浮点，1 − (1 − r) 和 r 可能差最后一位（r < 0.5 时 1 − r 不一定
    /// 能精确表示），差不到 1e-15，像素一样。
    static func mirrored(_ node: CollageNode) -> CollageNode {
        guard !node.isLeaf else { return node }
        var out = node
        if node.axis == .row {
            out.children = [mirrored(node.children[1]), mirrored(node.children[0])]
            out.ratio = 1 - node.ratio
        } else {
            out.children = node.children.map(mirrored)
        }
        return out
    }

    /// 一个跨页左右镜像（S3）：切分树（散落版记着的网格也翻）、自由图层 x → 1 − x、角度取反；贴在相纸上的胶带在相纸
    /// 局部坐标里也左右翻（局部坐标以相纸中心为原点：x 取反、相对角度取反）。照片上的字块按照片定位（照片没翻），不动。
    static func mirrored(_ page: CollagePage) -> CollagePage {
        var out = page
        out.root = mirrored(page.root)
        out.gridRoot = page.gridRoot.map(mirrored)
        out.items = page.items.map(mirrored)
        return out
    }

    static func mirrored(_ item: CollageItem) -> CollageItem {
        var out = item
        out.cx = 1 - item.cx
        out.rotation = negated(item.rotation)
        if var a = item.attach {
            a.x = negated(a.x)
            a.angle = negated(a.angle)
            out.attach = a
        }
        return out
    }

    /// 取反，0 还是 0（不写出 -0 来）。
    private static func negated(_ x: Double) -> Double { x == 0 ? 0 : -x }
}

// MARK: - S5 锁住的跨页

extension CollageAlbum {

    /// 工程里锁住的跨页（原来的下标、页）和它们上面的照片（不参与编排）。单张拼图没有锁住这回事。
    static func lockedSpreads(_ project: CollageProject) -> (pages: [(index: Int, page: CollagePage)], photoIDs: Set<String>) {
        guard project.mode == .album else { return ([], []) }
        let pages = project.pages.enumerated().filter { $0.element.locked }.map { (index: $0.offset, page: $0.element) }
        return (pages, Set(pages.flatMap { $0.page.photoIDs }))
    }

    /// 目标跨页数减掉锁住的个数（锁住的算在整本里）；没设 = nil。至少 1 个。
    static func budget(_ budget: CollageAlbumBudget?, excludingLocked locked: Int) -> CollageAlbumBudget? {
        guard var b = budget, locked > 0 else { return budget }
        b.spreads = max(CollageAlbumBudget.spreadsRange.lowerBound, b.spreads - locked)
        return b.normalized
    }

    /// 重排出来的跨页（fresh：第 0 个是扉页）和锁住的跨页合成一本（S5）：
    /// - 锁住的按它最早一张照片的拍摄时间插进去：插在第一个比它晚开始的跨页前面；扉页永远在最前（按分数 / 景别挑的，
    ///   不按时间）；比谁都晚的接在最后；
    /// - 原来就是第一个的锁住页（锁住了扉页）还在最前面；
    /// - 上面没有照片（只有字、留白）的锁住页放回原来的下标；
    /// - 几个锁住页之间保持原来的先后。
    static func mergeLocked(_ fresh: [CollagePage], locked: [(index: Int, page: CollagePage)],
                            photos: [String: CollagePhotoRef]) -> [CollagePage] {
        guard !locked.isEmpty else { return fresh }
        func start(_ page: CollagePage) -> CollagePhotoRef? {
            page.photoIDs.compactMap { photos[$0] }.min(by: shotEarlier)
        }
        var out = fresh
        var opener: Int? = fresh.isEmpty ? nil : 0
        var floor = 0
        for (index, page) in locked.sorted(by: { $0.index < $1.index }) {
            var at: Int
            if index == 0 {
                at = 0
            } else if let t = start(page) {
                let from = min(out.count, max(floor, (opener ?? -1) + 1))
                at = out.count
                for j in from..<out.count {
                    if let s = start(out[j]), shotEarlier(t, s) {
                        at = j
                        break
                    }
                }
            } else {
                at = min(index, out.count)
            }
            at = min(max(at, floor), out.count)
            out.insert(page, at: at)
            if let o = opener, at <= o { opener = o + 1 }
            floor = at + 1
        }
        return out
    }
}

// MARK: - S6 换照片的候选

/// 换照片的一个候选（S6，CollageStore.replacementCandidates；界面在「格式 › 换一张」）。
struct CollageReplacement: Hashable {
    enum Reason: Int, Comparable, CaseIterable {
        /// 同一个近似重复组（burstGroup：引擎按同机身 2 秒内 + phash 汉明 ≤ 10 分的，几乎同一张）
        case burst
        /// 同一场（take：批量页按快门间隔切的一串，人在动、表情在变；堆栈网格、检视器同组条用的就是它）
        case take
        /// 画面相似（Vision 特征距离 < 两两距离中位数的 76%，同相册去重的「同地同姿势」）
        case similar

        static func < (a: Reason, b: Reason) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .burst: return "同连拍"
            case .take: return "同场"
            case .similar: return "相似"
            }
        }
    }

    var photoID: String
    var reason: Reason
    var score: Double
    /// 用在第几个跨页（0 起）；nil = 还没上版。
    var page: Int?
    var reject: Bool
    var clientPick: Bool
}

extension CollageAlbum {

    /// 托盘里能换 target 的照片（S6）：同连拍组 > 同一场 > 画面相似（每张取最强的那条理由；chapter 是隔 15 分钟以上
    /// 切的章，太粗，不当理由）。排序：废片最后；其余没用过的在前，同一类理由放一起（同连拍 > 同场 > 相似），同一类按分数。
    /// pageOf：每张照片用在第几个跨页（没用 = 不在里面）；similar：这张和 target 画面相似不相似。
    static func replacementCandidates(for target: CollagePhotoRef, tray: [CollagePhotoRef], pageOf: [String: Int],
                                      limit: Int, similar: (CollagePhotoRef) -> Bool) -> [CollageReplacement] {
        var seen: Set<String> = [target.id]
        var out: [CollageReplacement] = []
        for p in tray where seen.insert(p.id).inserted {
            let reason: CollageReplacement.Reason
            if let a = target.burstGroup, let b = p.burstGroup, a == b {
                reason = .burst
            } else if let a = target.take, let b = p.take, a == b {
                reason = .take
            } else if similar(p) {
                reason = .similar
            } else {
                continue
            }
            out.append(CollageReplacement(photoID: p.id, reason: reason, score: p.score, page: pageOf[p.id],
                                          reject: p.verdict == .reject, clientPick: p.clientPick))
        }
        out.sort { a, b in
            if a.reject != b.reject { return !a.reject }
            if (a.page == nil) != (b.page == nil) { return a.page == nil }
            if a.reason != b.reason { return a.reason < b.reason }
            if a.score != b.score { return a.score > b.score }
            return a.photoID < b.photoID
        }
        return Array(out.prefix(max(0, limit)))
    }
}

// MARK: - S4 左页、右页分开换版式

/// 跨页的哪一边。
enum CollageSpreadSide: Int, CaseIterable {
    case left = 0, right = 1

    var label: String { self == .left ? "左页" : "右页" }
}

extension CollageLayout {

    enum SideAlternatives {
        /// 找不到中缝那一刀（不是相册跨页、或者整个跨页一格）
        case notSpread
        /// 这一边不到两张照片
        case single
        /// 这一边有锁住的格子
        case locked
        /// 几种切法（整棵树）：第 0 个是现在的样子，其余按分数，结构各不相同
        case options([CollageNode])
    }

    /// S4：只重切跨页一侧（中缝那一刀的左孩子或右孩子；上下有横条的也认，见 foldPath）：这一边的照片、文字格不变
    /// （留白格是切法的一部分，重切时不要），照片按拍摄先后读下来（F4），按这一边的像素框随机切分、按比例闭式解，
    /// 拼回整个跨页打分；同一结构只留分数最好的，最多 keep 种（含现在这种）。
    static func sideAlternatives(_ root: CollageNode, side: CollageSpreadSide, context: Context, tries: Int = 3000,
                                 keep: Int = 6, seed: UInt64) -> SideAlternatives {
        guard context.canvas.seams == .fold, let fold = foldPath(root) else { return .notSpread }
        let sidePath = fold + [side.rawValue]
        guard let sub = root.node(at: sidePath) else { return .notSpread }
        let leaves = sub.leaves
        if leaves.contains(where: \.locked) { return .locked }
        let cells = leaves.filter { $0.kind != .empty }
        guard cells.filter({ $0.kind == .photo }).count >= 2 else { return .single }
        let frames = pageGeometry(root, canvas: context.canvas, style: context.style).frames
            .filter { $0.path.starts(with: sidePath) }
        guard var box = frames.first?.rect else { return .notSpread }
        for f in frames.dropFirst() {
            box = IntRect(x0: min(box.x0, f.rect.x0), y0: min(box.y0, f.rect.y0),
                          x1: max(box.x1, f.rect.x1), y1: max(box.y1, f.rect.y1))
        }
        let width = Double(box.width)
        let height = Double(box.height)
        let g = Double(gutterPixels(canvas: context.canvas, style: context.style))
        let aspects = cells.map { preferredAspect($0, photos: context.photos) }
        let order = CollageAlbum.timeOrderedCells(cells, photos: context.photos)
        var rng = SeededRandom(seed: seed)
        // 伸缩范围比整页求解宽一些（0.45–2.2，一页只有两三张时常规范围里常常只有一两种切法），裁得多的按 |log m| 往后排
        // （和求解器同一个裁切项）。
        func search(_ lo: Double, _ hi: Double, tries: Int) -> [String: (score: Double, root: CollageNode)] {
            var best: [String: (score: Double, root: CollageNode)] = [:]
            for _ in 0..<max(1, tries) {
                var slice = order.photos
                for t in order.others { slice.insert(t, at: Int.random(in: 0...slice.count, using: &rng)) }
                let shape = randomShape(slice, using: &rng)
                let k = coeff(shape, aspects, g)
                guard let m = fitM(k, width: width, height: height), m > lo, m < hi else { continue }
                let newSub = node(shape, aspects, g, m: m, width: width, height: height, cells: cells)
                var assembled = root
                assembled.update(at: sidePath) { $0 = newSub }
                let s = score(assembled, m: nil, context: context).score + 4.0 * abs(log(m))
                let sig = structureKey(newSub)
                if let e = best[sig], e.score <= s { continue }
                best[sig] = (s, assembled)
            }
            return best
        }
        var best = search(0.45, 2.2, tries: tries)
        if best.isEmpty { best = search(0.2, 5, tries: max(1000, tries / 2)) }
        let current = structureKey(sub)
        let ranked = best.filter { $0.key != current }
            .sorted { a, b in a.value.score != b.value.score ? a.value.score < b.value.score : a.key < b.key }
            .prefix(max(0, keep - 1))
            .map(\.value.root)
        return .options([root] + ranked)
    }

    /// 切法的结构：横切 / 竖切、先后、格子种类，不看比例（同一种切法按照片比例解出来的比例都一样，现在这一版手拖过缝也算同一种）。
    static func structureKey(_ n: CollageNode) -> String {
        if n.isLeaf {
            switch n.cell?.kind {
            case .text: return "T"
            case .empty, nil: return "E"
            case .photo: return "P"
            }
        }
        return (n.axis == .row ? "R(" : "C(") + structureKey(n.children[0]) + "," + structureKey(n.children[1]) + ")"
    }
}
