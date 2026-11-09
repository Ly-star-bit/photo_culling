import Foundation
import SwiftUI

/// 相册的目标跨页数（F06，照 SmartAlbums 的 Number of spreads + 每跨页张数区间）：「自动编排」把托盘里的照片
/// 塞进这么多个跨页，**不替用户删片** —— 每跨页最多几张放不下，就多出几个跨页（跨页条上标橙、提示怎么办）；
/// 照片太少凑不够，就少几个。1 个跨页 = 摊开的左右两页（印厂说的「P」是单页：20 个跨页 = 40P）。
/// 存在工程里（CollageProject.albumBudget，nil = 自动：照片多少编多少，原来的疏密节奏）。
struct CollageAlbumBudget: Codable, Hashable {
    /// 目标跨页数（含扉页）。
    var spreads: Int
    /// 每跨页最少几张（扉页固定一张，不算在里面）。
    var minPerSpread = 1
    /// 每跨页最多几张。只对默认编排：婚礼 fine-art 每跨页固定 1–3 张（R3），最少、最多都不看。
    var maxPerSpread = 6

    static let spreadsRange = 1...200
    static let perSpreadRange = 1...12
    /// 第一次打开「指定跨页数」时的默认值（常见婚礼册 17–27 个跨页）。
    static let defaultSpreads = 20

    init(spreads: Int, minPerSpread: Int = 1, maxPerSpread: Int = 6) {
        self.spreads = spreads
        self.minPerSpread = minPerSpread
        self.maxPerSpread = maxPerSpread
        self = normalized
    }

    /// 夹到能用的范围、最少不超过最多。
    var normalized: CollageAlbumBudget {
        var out = self
        let s = Self.spreadsRange
        let p = Self.perSpreadRange
        out.spreads = min(s.upperBound, max(s.lowerBound, spreads))
        out.maxPerSpread = min(p.upperBound, max(p.lowerBound, maxPerSpread))
        out.minPerSpread = min(out.maxPerSpread, max(p.lowerBound, minPerSpread))
        return out
    }

    /// 界面、命令行那一句：「20 个跨页（40P）· 每跨页 1–6 张」。
    var label: String {
        "\(spreads) 个跨页（\(spreads * 2)P）· 每跨页 \(minPerSpread)–\(maxPerSpread) 张"
    }

    /// 编完了和目标比：正好 / 多了 / 少了（没设目标 = nil）。photos：参与编排的照片数。
    static func outcome(spreads count: Int, budget: CollageAlbumBudget?, photos: Int, fineArt: Bool) -> String? {
        guard let b = budget?.normalized else { return nil }
        if count == b.spreads { return "正好 \(b.spreads) 个跨页" }
        if count > b.spreads {
            // fine-art 不看目标里的每跨页张数（固定 1–3 张）：照实际的上限说，不说用户填的那个。
            // 并页还要守版式规则（CollageStyleFineArt.compress）：并了会破坏的不并，所以会多。
            let cap = fineArt ? "婚礼相册编排每跨页最多 \(CollageStyleFineArt.maxPerSpread) 张、并页不破坏版式（不连着 4 个多图跨页、"
                + "同姿势 / 黑白彩色不进同一跨页、左右页亮度差不大），"
                : "每跨页最多 \(b.maxPerSpread) 张"
            let fix = fineArt ? "编排换「默认」、或从托盘拿掉一些" : "调高每跨页张数、或从托盘拿掉一些"
            return "比目标 \(b.spreads) 个多 \(count - b.spreads) 个：\(cap)放不下这 \(photos) 张（目标跨页数不替你删片）—— \(fix)"
        }
        let why = b.minPerSpread > 1 && !fineArt ? "\(photos) 张照片、每跨页至少 \(b.minPerSpread) 张" : "只有 \(photos) 张照片"
        return "比目标 \(b.spreads) 个少 \(b.spreads - count) 个：\(why)"
    }
}

extension CollageAlbumBudget {
    /// 坏值按能用的范围收；缺了的按默认（旧工程没有这个键 = 整个是 nil，见 CollageProject 的解码）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spreads = try c.decode(Int.self, forKey: .spreads)
        // CollageModel 里的 soft 是文件内的：这里照它的意思写（坏值、缺了 = 默认）。
        let lo: Int?? = try? c.decodeIfPresent(Int.self, forKey: .minPerSpread)
        let hi: Int?? = try? c.decodeIfPresent(Int.self, forKey: .maxPerSpread)
        minPerSpread = (lo ?? nil) ?? 1
        maxPerSpread = (hi ?? nil) ?? 6
        self = normalized
    }
}

// MARK: - 默认编排：按目标跨页数塞

extension CollageAlbum {

    /// 默认编排按目标跨页数（CollageAlbum.plan 给了 budget 走这里；没给照旧是 4-3-5-2-4-3 的节奏）：
    /// 1. 扉页照旧是分数最高的那张；
    /// 2. 好片单独成页（分数前一成多，竖图配下一张竖图对页）只在宽裕时留：放不下、或者别的跨页因此挤到上限的
    ///    四分之三以上，就一张张退回多图跨页；每跨页最少要 2 张以上时不单独成页；
    /// 3. 剩下的多图跨页按各章张数分（每章至少放得下、至多不低于最少张数，多的给最挤的那章 —— 全书疏密差不多，
    ///    不会前面一两张、后面五六张）；章内按 4-3-5-2-4-3 的节奏（减了一半起伏）分大小，同姿势三张不进一个跨页；
    /// 4. 放不下就多出几个跨页，照片太少就少几个：一张都不拿掉（「相似只留一张」照旧是那个开关管）。
    static func planBudget(_ kept: [CollagePhotoRef], dropped: [CollagePhotoRef], similar: [String: Set<String>],
                           budget raw: CollageAlbumBudget) -> Plan {
        let budget = raw.normalized
        guard let opener = kept.max(by: { $0.score < $1.score }) else {
            return Plan(spreads: [], dropped: dropped, theme: .classic, budget: budget)
        }
        let rest = CollageSelect.chronological(kept.filter { $0.id != opener.id })
        var chapters: [[CollagePhotoRef]] = []
        for p in rest {
            if let last = chapters.last?.last, last.chapter == p.chapter {
                chapters[chapters.count - 1].append(p)
            } else {
                chapters.append([p])
            }
        }
        let lo = budget.minPerSpread
        let hi = budget.maxPerSpread
        let body = budget.spreads - 1

        // 好片单独成页：从默认的张数往下退，直到多图跨页（每跨页最多 hi 张）放得下。
        let heroCap = lo <= 1 && rest.count >= 8 ? Int((Double(rest.count) * 0.12).rounded()) : 0
        let ranked = rest.sorted { $0.score > $1.score }
        var segments: [BudgetSegment] = []
        // 好片占掉的跨页让哪一章的多图跨页挤到每跨页上限的四分之三以上（6 张上限 = 平均 4.5 张以上）也不留：
        // 一个跨页一张、旁边全是六张，不如大家都五张。
        var counts: [Int] = []
        for h in stride(from: heroCap, through: 0, by: -1) {
            let heroes = Set(ranked.prefix(h).map(\.id))
            segments = chapters.map { segment($0, heroes: heroes) }
            let heroSpreads = segments.reduce(0) { $0 + $1.heroes.count }
            let grid = segments.map(\.grid.count)
            counts = allocate(grid, total: body - heroSpreads, lo: lo, hi: hi)
            let fits = heroSpreads + counts.reduce(0, +) <= body
            let densities: [Double] = grid.indices.map { i in
                counts[i] > 0 ? Double(grid[i]) / Double(counts[i]) : 0
            }
            let densest: Double = densities.max() ?? 0
            if h == 0 || (fits && densest <= Double(hi) * 0.75) { break }
        }

        var spreads = [Spread(kind: .opener, photos: [opener])]
        var beat = 0
        for (ci, seg) in segments.enumerated() {
            let sizes = bucketSizes(seg.grid.count, into: counts[ci], lo: lo, hi: hi, beat: beat)
            beat += sizes.count
            let buckets = fillBuckets(seg.grid, sizes: sizes, similar: similar)
            // 好片插回它在时间上的位置：离它最近的那条跨页分界（分界 k = 第 k 个多图跨页之前放了几张）。
            var running = [0]
            for s in sizes { running.append((running.last ?? 0) + s) }
            let bounds = running
            var h = 0
            for k in 0...buckets.count {
                while h < seg.heroes.count, nearestBoundary(bounds, seg.heroes[h].after) == k {
                    spreads.append(seg.heroes[h].spread)
                    h += 1
                }
                if k < buckets.count {
                    let bucket = buckets[k]
                    spreads.append(Spread(kind: bucket.count == 1 ? .solo : .grid, photos: bucket))
                }
            }
            // 理论上上面放完了；保险：没放上的好片接在本章最后（照片不能丢）。
            while h < seg.heroes.count {
                spreads.append(seg.heroes[h].spread)
                h += 1
            }
        }
        return Plan(spreads: spreads, dropped: dropped, theme: .classic, budget: budget)
    }

    /// 离 after 最近的那条分界（一样近取后面的）。
    static func nearestBoundary(_ bounds: [Int], _ after: Int) -> Int {
        var best = 0
        for k in bounds.indices where abs(bounds[k] - after) <= abs(bounds[best] - after) { best = k }
        return best
    }

    /// 一章：多图跨页的照片（按时间）+ 好片跨页（after = 它前面有几张多图跨页的照片）。
    struct BudgetSegment {
        var grid: [CollagePhotoRef] = []
        var heroes: [(after: Int, spread: Spread)] = []
    }

    /// 和默认编排同一条：好片是竖图、下一张也是竖图（不是好片）就配成对页，否则单独一页。
    static func segment(_ chapter: [CollagePhotoRef], heroes: Set<String>) -> BudgetSegment {
        var out = BudgetSegment()
        var i = 0
        while i < chapter.count {
            let p = chapter[i]
            guard heroes.contains(p.id) else {
                out.grid.append(p)
                i += 1
                continue
            }
            if p.isPortrait, i + 1 < chapter.count, chapter[i + 1].isPortrait, !heroes.contains(chapter[i + 1].id) {
                out.heroes.append((out.grid.count, Spread(kind: .pair, photos: [p, chapter[i + 1]])))
                i += 2
            } else {
                out.heroes.append((out.grid.count, Spread(kind: .solo, photos: [p])))
                i += 1
            }
        }
        return out
    }

    /// n 张每跨页最多 hi 张至少要几个跨页（0 张 = 0 个）。
    static func minSpreads(_ n: Int, _ hi: Int) -> Int {
        n <= 0 ? 0 : (n + hi - 1) / hi
    }

    /// 多图跨页按章分：每章先给放得下的最少个数，多出来的一个个给「每跨页张数最多」的那章（同样挤给前面的章），
    /// 每章不超过「每跨页至少 lo 张」允许的个数。total 不够每章最少的 = 照最少的给（结果比目标多）。
    static func allocate(_ sizes: [Int], total: Int, lo: Int, hi: Int) -> [Int] {
        var counts = sizes.map { minSpreads($0, hi) }
        let caps = sizes.indices.map { i in sizes[i] <= 0 ? 0 : max(counts[i], sizes[i] / lo) }
        var extra = total - counts.reduce(0, +)
        while extra > 0 {
            var best: Int?
            for i in sizes.indices where counts[i] < caps[i] {
                guard let b = best else { best = i; continue }
                // sizes[i] / counts[i] > sizes[b] / counts[b]，交叉相乘免得除。
                let lhs = sizes[i] * counts[b]
                let rhs = sizes[b] * counts[i]
                if lhs > rhs { best = i }
            }
            guard let i = best else { break }
            counts[i] += 1
            extra -= 1
        }
        return counts
    }

    /// 一章 n 张分成 g 个跨页的大小：按 4-3-5-2-4-3 的节奏（起伏减半：权重 = 节奏 + 3.5）分，夹在 lo…hi 里，
    /// 加起来正好 n。lo、hi 本身放不下（章太小、分得太多）时按放得下的放宽。beat = 全书接着数的节拍。
    static func bucketSizes(_ n: Int, into g: Int, lo: Int, hi: Int, beat: Int) -> [Int] {
        guard g > 0, n > 0 else { return [] }
        let loEff = min(lo, n / g)
        let hiEff = max(hi, (n + g - 1) / g)
        let rhythm = [4, 3, 5, 2, 4, 3]
        let weights: [Double] = (0..<g).map { k in Double(rhythm[(beat + k) % rhythm.count]) + 3.5 }
        let sum = weights.reduce(0, +)
        let ideal: [Double] = weights.map { w in Double(n) * w / sum }
        var sizes: [Int] = ideal.map { x in min(hiEff, max(loEff, Int(x.rounded()))) }
        var diff = n - sizes.reduce(0, +)
        while diff > 0 {
            var best: Int?
            for k in sizes.indices where sizes[k] < hiEff {
                let gap = ideal[k] - Double(sizes[k])
                if let b = best, gap <= ideal[b] - Double(sizes[b]) { continue }
                best = k
            }
            guard let k = best else { break }
            sizes[k] += 1
            diff -= 1
        }
        while diff < 0 {
            var best: Int?
            for k in sizes.indices where sizes[k] > loEff {
                let gap = ideal[k] - Double(sizes[k])
                if let b = best, gap >= ideal[b] - Double(sizes[b]) { continue }
                best = k
            }
            guard let k = best else { break }
            sizes[k] -= 1
            diff += 1
        }
        return sizes
    }

    /// 按定好的大小一个个装：和这个跨页里已有两张都是同地同姿势的顺延到下一个（最后一个跨页不顺延，照片不能丢）。
    static func fillBuckets(_ photos: [CollagePhotoRef], sizes: [Int],
                            similar: [String: Set<String>]) -> [[CollagePhotoRef]] {
        var queue = photos
        var out: [[CollagePhotoRef]] = []
        for (k, size) in sizes.enumerated() {
            let last = k == sizes.count - 1
            var bucket: [CollagePhotoRef] = []
            var deferred: [CollagePhotoRef] = []
            while bucket.count < size, !queue.isEmpty {
                let p = queue.removeFirst()
                let neighbours = similar[p.id] ?? []
                if !last, bucket.filter({ neighbours.contains($0.id) }).count >= 2 {
                    deferred.append(p)
                    continue
                }
                bucket.append(p)
            }
            while bucket.count < size, !deferred.isEmpty { bucket.append(deferred.removeFirst()) }
            queue = deferred + queue
            if last {
                bucket += queue
                queue = []
            }
            out.append(bucket)
        }
        return out.filter { !$0.isEmpty }
    }
}

// MARK: - 婚礼 fine-art：往目标跨页数并

extension CollageStyleFineArt {

    /// 目标跨页数（F06）：fine-art 编出来比目标多，就把同一章里相邻的单图跨页并起来（单 + 单 → 对页双图，
    /// 对页双图 + 单 → 一主两辅），一张都不拿掉、每跨页还是最多 3 张；扉页、章节开篇不动。先并正文里落单的，
    /// 再并呼吸页、每章收尾的单张。并出来的跨页照样守 fine-art 的规则，会破坏的那一对就不并（宁可多几个跨页）：
    /// 连着的多图跨页不超过 maxBusyRun 个（R4）、同姿势不进同一跨页（R10）、黑白彩色不混（R7）、左右页亮度差不超
    /// maxLumaGap（R8）。并到目标或者再也并不动为止（多出来的跨页条上标橙，提示里说）。比目标少不加页。
    /// cap：并出来的跨页最多几张（fine-art 固定 3 张：plan 不传目标里的「每跨页最多」，那个只对默认编排）。
    /// （辅助函数都拿数组当参数、不捕获 inout：release 下 Swift 6.3 的 CopyPropagation 遇到捕获 inout 的局部函数会崩。）
    static func compress(_ spreads: inout [CollageAlbum.Spread], toward target: Int, cap: Int = maxPerSpread,
                         similar: [String: Set<String>]) {
        var list = spreads
        while list.count > target {
            guard let best = bestMerge(list, cap: cap, similar: similar) else { break }
            list.replaceSubrange(best.index...(best.index + 1), with: [best.spread])
        }
        spreads = list
    }

    /// 这一轮最该并的那一对（i、i+1）和并成的跨页；并不动 = nil。
    /// 先比档（正文落单的 0、呼吸页 / 章末收尾 1），再比单 + 单优先，再比哪章更松，最后比位置。
    /// 并了会让连着的多图跨页超过 maxBusyRun 个的不并（R4：打断一串多图跨页的那张单图正是 plan 特意插的）。
    private static func bestMerge(_ list: [CollageAlbum.Spread], cap: Int,
                                  similar: [String: Set<String>]) -> (index: Int, spread: CollageAlbum.Spread)? {
        var best: (key: [Double], index: Int, spread: CollageAlbum.Spread)?
        for i in 0..<max(0, list.count - 1) {
            let base = max(singleTier(list, i), singleTier(list, i + 1))
            guard let c = mergedSpread(list[i], list[i + 1], cap: cap, similar: similar),
                  busyRun(list, merging: i) <= maxBusyRun else { continue }
            let size: Double = c.photos.count == 2 ? 0 : 1
            let loose: Double = chapterSparsity(list, c.fineArt?.chapter ?? 0)
            let key: [Double] = [Double(base), size, -loose, Double(i)]
            if let b = best, !key.lexicographicallyPrecedes(b.key) { continue }
            best = (key, i, c)
        }
        return best.map { ($0.index, $0.spread) }
    }

    /// i、i+1 并成一个多图跨页以后，它所在那一串连着的多图跨页有几个（前后挨着的多图跨页都算，跨章也算）。
    private static func busyRun(_ list: [CollageAlbum.Spread], merging i: Int) -> Int {
        var run = 1
        var k = i - 1
        while k >= 0, list[k].photos.count >= 2 {
            run += 1
            k -= 1
        }
        k = i + 2
        while k < list.count, list[k].photos.count >= 2 {
            run += 1
            k += 1
        }
        return run
    }

    /// 单图跨页的档：正文里落单的 0，呼吸页、每章最后一个（收尾）1；多图跨页 0。
    private static func singleTier(_ list: [CollageAlbum.Spread], _ i: Int) -> Int {
        let s = list[i]
        guard s.photos.count == 1 else { return 0 }
        if s.fineArt?.kind == .breath { return 1 }
        let end = i + 1 >= list.count || list[i + 1].fineArt?.chapter != s.fineArt?.chapter
        return end ? 1 : 0
    }

    /// 同一章里跨页多、照片少的先并（全书疏密差不多）：跨页数 / 照片数。
    private static func chapterSparsity(_ list: [CollageAlbum.Spread], _ chapter: Int) -> Double {
        let members = list.filter { $0.fineArt?.chapter == chapter }
        let photos = members.reduce(0) { $0 + $1.photos.count }
        return Double(members.count) / Double(max(1, photos))
    }

    /// 相邻两个跨页并成一个：同一章、都不是扉页 / 章节开篇、加起来 2–3 张（不超过 cap）。2 张 = 对页双图，
    /// 3 张 = 一主两辅（主图那页和配图那页亮度差超了就不并）。同姿势、黑白彩色混、亮度差太多的不并（同一场的可以，
    /// 和 capSingles 并落单的一样）。以前并不动时还有一档连这些都不看，并出过同姿势、黑白彩色混在一起的跨页。
    private static func mergedSpread(_ a: CollageAlbum.Spread, _ b: CollageAlbum.Spread, cap: Int,
                                     similar: [String: Set<String>]) -> CollageAlbum.Spread? {
        guard let infoA = a.fineArt, let infoB = b.fineArt, infoA.chapter == infoB.chapter else { return nil }
        let structural: Set<CollageFineArtSpread.Kind> = [.title, .chapter]
        guard !structural.contains(infoA.kind), !structural.contains(infoB.kind) else { return nil }
        let all = a.photos + b.photos
        guard all.count <= min(cap, maxPerSpread), all.count >= 2 else { return nil }
        let mono = infoA.look != nil && infoB.look != nil
        let look = infoA.look == infoB.look ? infoA.look : nil
        var out: CollageAlbum.Spread
        if all.count == 2 {
            let x = all[0]
            let y = all[1]
            guard compatible(y, with: [x], similar: similar, mono: mono, relaxTake: true),
                  lumaGap([x], [y]) <= maxLumaGap else { return nil }
            out = CollageAlbum.Spread(kind: .pair, photos: CollageSelect.chronological(all))
            out.fineArt = CollageFineArtSpread(kind: .pair, chapter: infoA.chapter)
            out.fineArt?.merged = true
        } else {
            let pair = a.photos.count == 2 ? a.photos : b.photos
            let lone = a.photos.count == 2 ? b.photos[0] : a.photos[0]
            guard compatible(lone, with: pair, similar: similar, mono: mono, relaxTake: true) else { return nil }
            guard let trio = mainPlusTwoSpread(CollageSelect.chronological(all)) else { return nil }
            out = trio.with(chapter: infoA.chapter)
        }
        out.fineArt?.look = look
        return out
    }
}

// MARK: - 界面：检视器「文档 › 画布」里相册的目标跨页数

/// 检视器「文档 › 画布」（相册）里：目标跨页数开关 + 跨页数、每跨页张数。改了不马上重排（和「编排」主题一样），
/// 点「按这个编排」或工具条的「自动编排」生效。
struct CollageAlbumBudgetControls: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        let budget = store.project.albumBudget
        let fineArt = store.project.albumTheme == .fineArt
        VStack(alignment: .leading, spacing: 6) {
            Toggle("指定跨页数", isOn: Binding(get: { budget != nil }, set: { on in
                let start = max(1, store.project.pages.isEmpty ? CollageAlbumBudget.defaultSpreads : store.project.pages.count)
                store.setAlbumBudget(on ? CollageAlbumBudget(spreads: start) : nil)
            }))
            .toggleStyle(.checkbox)
            .help("「自动编排」把托盘里的照片塞进指定的跨页数：不替你删片，放不下就多出几个、在跨页条上标橙")
            if let b = budget {
                Stepper(value: Binding(get: { b.spreads }, set: { v in
                    var next = b
                    next.spreads = v
                    store.setAlbumBudget(next, coalesce: true)
                }), in: CollageAlbumBudget.spreadsRange) {
                    Text("\(b.spreads) 个跨页（\(b.spreads * 2)P）").monospacedDigit()
                }
                .help("1 个跨页 = 摊开的左右两页；印厂说的「P」是单页：\(b.spreads) 个跨页 = \(b.spreads * 2)P（含扉页）")
                // fine-art 每跨页固定 1–3 张、不看这两个数：不给调（存着的值留给换回默认编排）。
                if !fineArt {
                    HStack(spacing: 4) {
                        Text("每跨页")
                        Stepper(value: Binding(get: { b.minPerSpread }, set: { v in
                            var next = b
                            next.minPerSpread = v
                            next.maxPerSpread = max(next.maxPerSpread, v)
                            store.setAlbumBudget(next, coalesce: true)
                        }), in: CollageAlbumBudget.perSpreadRange) {
                            Text("\(b.minPerSpread)").monospacedDigit()
                        }
                        .fixedSize()
                        Text("–")
                        Stepper(value: Binding(get: { b.maxPerSpread }, set: { v in
                            var next = b
                            next.maxPerSpread = v
                            next.minPerSpread = min(next.minPerSpread, v)
                            store.setAlbumBudget(next, coalesce: true)
                        }), in: CollageAlbumBudget.perSpreadRange) {
                            Text("\(b.maxPerSpread) 张").monospacedDigit()
                        }
                        .fixedSize()
                    }
                    .help("每个跨页最少、最多放几张（扉页固定一张）")
                }
                let rule = fineArt ? "婚礼相册编排每跨页固定 1–3 张（每跨页张数只对默认编排）：把落单的单图、呼吸页、章末收尾并起来往目标凑，"
                    + "并了会破坏版式（连着 4 个多图跨页、同姿势 / 黑白彩色同页、左右亮度差太大）的不并，凑不够就多出几个（不删片）"
                    : "照片全部排进去、不替你删：每跨页最多 \(b.maxPerSpread) 张放不下时，多出来的跨页在跨页条上标橙"
                Text(rule + "。改完点工具条的「自动编排」生效")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("不指定 = 照片多少编多少（默认 4-3-5-2-4-3 的疏密）")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 跨页条左边的计数：没指定跨页数 = 「12」；指定了 = 「12/20」，多了标橙。
struct CollageAlbumSpreadCount: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        let count = store.project.pages.count
        // 印厂规格的页数规则（CollagePrintRules.pageProblem）：不合规也标橙，悬停说清楚多了 / 少了几 P。
        let pages = store.project.canvas.effectivePrintRules.pageProblem(spreads: count).map { "\n" + $0 }
        if let b = store.project.albumBudget {
            let over = count > b.spreads
            Text("\(count)/\(b.spreads)")
                .font(.caption2).monospacedDigit()
                .foregroundStyle(over || pages != nil ? Color.orange : Color.secondary)
                .help(helpText(count: count, target: b.spreads) + (pages ?? ""))
        } else {
            Text("\(count)")
                .font(.caption2).monospacedDigit()
                .foregroundStyle(pages != nil ? Color.orange : Color.secondary)
                .help("\(count) 个跨页（\(count * 2)P）。要指定跨页数：右栏「文档 › 画布」里勾「指定跨页数」" + (pages ?? ""))
        }
    }

    private func helpText(count: Int, target: Int) -> String {
        let change = "在右栏「文档 › 画布」里改目标"
        if count > target {
            return "比目标 \(target) 个跨页多 \(count - target) 个（页码标橙的那几个）：调高每跨页张数，或从托盘拿掉一些；" + change
        }
        if count < target { return "比目标 \(target) 个跨页少 \(target - count) 个（照片不够）；" + change }
        return "正好是目标的 \(target) 个跨页（\(target * 2)P）"
    }
}

// MARK: - MCP（collage_run_kit 的 spreads / min_per_spread / max_per_spread）

/// 一键成套顺带改不改目标跨页数：keep = 沿用工程里的；set(nil) = 改回自动；set(b) = 换成 b。
enum CollageBudgetChange {
    case keep
    case set(CollageAlbumBudget?)

    struct Bad: Error {
        let message: String
    }

    /// 参数 → 改法：三个都没给 = keep；只对整本婚礼相册；spreads = 0 是改回自动（不能再带每跨页张数）。
    static func parse(kit: CollageKitID, spreads: Int?, min lo: Int?, max hi: Int?) -> Result<CollageBudgetChange, Bad> {
        guard spreads != nil || lo != nil || hi != nil else { return .success(.keep) }
        guard kit == .weddingAlbum else {
            return .failure(Bad(message: "spreads、min_per_spread、max_per_spread 只对 kit=weddingAlbum（整本婚礼相册）有用"))
        }
        guard let n = spreads else { return .failure(Bad(message: "min_per_spread、max_per_spread 要和 spreads 一起给")) }
        if n == 0 {
            guard lo == nil, hi == nil else {
                return .failure(Bad(message: "spreads=0 是改回自动（不限跨页数），不能再给 min_per_spread / max_per_spread"))
            }
            return .success(.set(nil))
        }
        // 整本婚礼相册是婚礼 fine-art 编排：每跨页固定 1–3 张，给的最多比 3 小也做不到（以前照收、报的是用户给的数，
        // 编出来照样有 3 张的跨页）。
        if let h = hi, h < CollageStyleFineArt.maxPerSpread {
            return .failure(Bad(message: "整本婚礼相册按婚礼 fine-art 编排，每跨页固定 1–3 张：max_per_spread 不能小于 "
                                + "\(CollageStyleFineArt.maxPerSpread)（要每跨页最多 1–2 张，请用户在 app 里把相册的编排换成「默认」再点「自动编排」）"))
        }
        let a = lo ?? 1
        // 只给了最少（比如 8）：最多跟着抬到最少（和检视器的步进器一样），不拿没给的默认 6 去报「最少比最多大」。
        let b = hi ?? max(6, a)
        guard a <= b else { return .failure(Bad(message: "min_per_spread（\(a)）不能比 max_per_spread（\(b)）大")) }
        return .success(.set(CollageAlbumBudget(spreads: n, minPerSpread: a, maxPerSpread: b)))
    }

    /// collage_get_state 的 album_target、成套结果里的 album.target。
    static func targetInfo(_ b: CollageAlbumBudget) -> [String: Any] {
        ["spreads": b.spreads, "min_per_spread": b.minPerSpread, "max_per_spread": b.maxPerSpread]
    }

    /// 成套落地以后：几个跨页、目标几个、多了几个；多了带一条 over_target 警告（不删片，所以会多）。
    static func report(_ project: CollageProject) -> (body: [String: Any], warning: [String: Any]?) {
        let count = project.pages.count
        var body: [String: Any] = ["spreads": count]
        guard let b = project.albumBudget else {
            body["target"] = NSNull()
            return (body, nil)
        }
        body["target"] = targetInfo(b)
        let over = max(0, count - b.spreads)
        body["over_target"] = over
        guard over > 0 else { return (body, nil) }
        let placed = project.usedPhotoIDs.count
        let message = CollageAlbumBudget.outcome(spreads: count, budget: b, photos: placed,
                                                 fineArt: project.albumTheme == .fineArt) ?? ""
        // fine-art 压页会把落单的单图、呼吸页、章末收尾并掉，但不破坏版式规则，并不动就多（CollageStyleFineArt.compress）。
        let rules = project.albumTheme == .fineArt
            ? "婚礼 fine-art 往目标并时会把落单的单图、呼吸页、章末收尾并掉，但并了会破坏版式（连着 4 个多图跨页、同姿势 / 黑白彩色同页、左右亮度差太大）的不并。"
            : ""
        let hint = rules + "请用户决定：在 app 里把相册的编排换成「默认」再点「自动编排」（默认编排每跨页最多 \(b.maxPerSpread) 张，会塞进目标），"
            + "或者从托盘拿掉一些照片再成套。AI 不替用户删片"
        return (body, MCPReadModel.warning("over_target", message, hint: hint))
    }
}

// MARK: - 命令行

extension CollageCLI {
    /// 「20」「20@1-6」→ 目标跨页数（每跨页最少-最多）；写错 = nil。每一段都要整段是数：多一个 @（20@1-6@2-4）、
    /// 多一个 -、空段、夹了字母的都不认（以前 compactMap 把认不出的那段悄悄扔掉，20@1-6@2-4 成了 1–4）。
    static func parseBudget(_ text: String) -> CollageAlbumBudget? {
        let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let n = Int(first), CollageAlbumBudget.spreadsRange.contains(n) else { return nil }
        guard parts.count == 2 else { return CollageAlbumBudget(spreads: n) }
        guard !parts[1].contains("@") else { return nil }
        let range = parts[1].split(separator: "-", omittingEmptySubsequences: false)
        guard range.count == 2, let lo = Int(range[0]), let hi = Int(range[1]),
              lo >= 1, lo <= hi, CollageAlbumBudget.perSpreadRange.contains(hi) else { return nil }
        return CollageAlbumBudget(spreads: n, minPerSpread: lo, maxPerSpread: hi)
    }

    /// ops 的 expect:spreads=N（正好 N 个跨页）/ spreads<=N / perspread=1-6（扉页以外每个跨页的张数在这个范围里）。
    @MainActor
    static func budgetExpect(_ store: CollageStore, _ what: String) -> Expectation {
        let pages = store.project.pages
        let counts = pages.map { $0.photoIDs.count }
        let shown = counts.map(String.init).joined(separator: " ")
        if what.hasPrefix("spreads<="), let n = Int(what.dropFirst("spreads<=".count)) {
            return pages.count <= n ? .pass("\(pages.count) 个跨页") : .fail("\(pages.count) 个跨页，比 \(n) 多")
        }
        if what.hasPrefix("spreads="), let n = Int(what.dropFirst("spreads=".count)) {
            return pages.count == n ? .pass("\(pages.count) 个跨页") : .fail("\(pages.count) 个跨页，不是 \(n)：\(shown)")
        }
        if what.hasPrefix("perspread="), let b = parseBudget("1@" + what.dropFirst("perspread=".count)) {
            let bad = counts.enumerated().dropFirst().filter { $0.element < b.minPerSpread || $0.element > b.maxPerSpread }
            if bad.isEmpty { return .pass("每跨页 \(shown)") }
            let detail = bad.map { "第\($0.offset + 1)个 \($0.element) 张" }.joined(separator: " ")
            return .fail("不在 \(b.minPerSpread)–\(b.maxPerSpread) 张里：\(detail)")
        }
        return editExpect(store, what)
    }
}
