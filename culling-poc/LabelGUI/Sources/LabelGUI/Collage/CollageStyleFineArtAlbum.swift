import Foundation

/// 相册编排主题（CollageProject.albumTheme；CollageAlbum.plan / layout / build 按它分派）：
/// - classic：原来的编排（扉页竖排标题 + 印章、疏密 4-3-5-2-4-3、横图铺满跨页），默认，出图逐像素不变；
/// - fineArt：婚礼 fine-art（DESIGN.md §3 K6、R3 §3–§4 的 R1–R12），见下面 CollageStyleFineArt.plan。
enum CollageAlbumTheme: String, Codable, CaseIterable, Hashable {
    case classic, fineArt

    var label: String {
        switch self {
        case .classic: return "默认"
        case .fineArt: return "婚礼 fine-art"
        }
    }
}

/// fine-art 编排给每个跨页的说明（CollageAlbum.Spread.fineArt）：哪种跨页、第几章、左页那行字、这一跨页的色调。
struct CollageFineArtSpread: Hashable {
    enum Kind: String {
        /// 扉页：左页标题 + 日期，右页一张宽景
        case title
        /// 章节开篇：左页一行小字（章节序号 · 时间），右页一张宽景
        case chapter
        /// 单张：右页一张，左页留白（每章收尾的高潮、落单的照片）
        case single
        /// 横图单页：一张横图放在右页版心里，不跨中缝
        case landscape
        /// 呼吸页：没有人脸 / 很小的脸，小一号放在右页
        case breath
        /// 对页双图：左右各一张，同高（竖配竖、横配横）
        case pair
        /// 一主两辅：一页主图，另一页两张配图（每张不到主图一半大）
        case mainPlusTwo
        /// 细节三联：右页一排三张小图（细节），左页留白
        case triptych
    }

    var kind: Kind
    /// 第几章（0 起）。
    var chapter: Int
    /// 左页那行字（扉页 = nil，用标题 + 日期行）。
    var caption: String?
    /// 这一跨页的色调：整章黑白、全是黑白照片的跨页 = 黑白；nil = 跟工程（雅致）。
    var look: CollageLookSetting?
    /// 一主两辅：photos 里第几张是主图、主图放左页还是右页。
    var mainIndex = 0
    var mainOnLeft = true
    /// 扉页标题用西文衬线（标题里没有汉字）。
    var latinTitle = false
    /// 为了不连着 3 个单图跨页，两张落单的并成的对页双图（可能横竖混排：左右按矮的那张同高）。
    var merged = false

    /// 这种跨页放几张照片（单图类 1）。
    var isSingle: Bool { kind == .title || kind == .chapter || kind == .single || kind == .landscape || kind == .breath }
}

extension CollageStyleFineArt {

    // MARK: - 编排规则的常数（R3 §3–§4；没有外部来源的是工程提案，交付报告里写了）

    /// 每跨页最多几张（R3 §3：fine-art 每跨页最多 3 张、平均 1.5–2）。
    static let maxPerSpread = 3
    /// 估算跨页数用的平均张数（R3 §3：跨页数 = ceil(张数 / 1.8)）。
    static let targetPerSpread = 1.8
    /// 连着几个多图跨页之后必须来一个单图跨页（R4：繁忙的跨页之后接一个单图）。
    static let maxBusyRun = 3
    /// 每章前几个跨页「宽而慢」：最多 2 张（R3）。
    static let sparseSpreads = 2
    /// 呼吸图的候选：没有人脸，或主脸面积 < 0.3%（photot 的全身照是 0.4%–1.5%，都不算）。
    static let breathFaceArea = 0.003
    /// 中缝两侧影调差的上限（R8：L* 差 25 以内；meanLuma 是 sRGB 编码值的平均，和 L*/100 差不多）。
    static let maxLumaGap = 0.25
    /// 一章里黑白照片占多少就整章转黑白（「整章黑白」开着时；R7：黑白按整章用，不零星撒）。
    static let monoChapterShare = 1.0 / 3.0
    /// 往后看几张找能配对的（竖配竖、同色调、不同姿势）：再远就打乱时间顺序了。
    static let lookahead = 5

    /// 章节开篇那行字比扉页日期行大多少。
    static let chapterCaptionScale = 1.15

    /// 黑白页的色调：整章黑白、全是黑白照片的跨页（本来就是黑白的照片不再叠雅致的暖高光）。
    static let monoLook = CollageLookSetting(look: .mono, strength: 0.8)

    /// 同一瞬间、同姿势的判断（nil = 不知道：特征算不出来）。selftest 直接给 similar，不跑 Vision。
    struct Similarity {
        var kept: [CollagePhotoRef]
        var dropped: [CollagePhotoRef]
        var similar: [String: Set<String>]
    }

    // MARK: - 编排

    /// fine-art 编排（CollageAlbum.plan(theme: .fineArt) 走这里）：
    /// 1. 废片不要；同一瞬间（近似重复组）只留一张；同一 take（场）只留精选（没有精选的场留它最好的那张）；
    ///    「相似只留一张」开着时再按画面去重（CollageSelect.distinctMoments）。
    /// 2. 扉页 = 景别最宽的那几张里分数最高的（R2），左页标题 + 日期行。
    /// 3. 按时间、按章节（R1）：两章以上从第二章起每章先来一个章节开篇（左页「II · 16:24」，右页本章最宽的一张；
    ///    第一章由扉页开篇 —— 不然一翻开就连着两个「左页一行字 + 右页一张」）；
    ///    每章疏 → 密 → 本章最高分的精选收成单张（R3）；连着 3 个多图跨页就插一个单图（R4）。
    /// 4. 竖图优先成对（R11）；同一跨页不放同姿势、同一场的两张（R10，same ≥ 1 就顺延）、不混黑白和彩色（R7）、
    ///    左右页亮度差不超过 maxLumaGap（R8）。
    /// 5. 全书 3–4 张呼吸图（R5，按跨页数缩放），小一号放右页。
    /// 6. 整章黑白（chapterMono）：一章里黑白占三分之一以上，整章的跨页都设成黑白页（CollagePage.look）。
    static func plan(_ photos: [CollagePhotoRef], dedupe: Bool, chapterMono: Bool, title bookTitle: String = "",
                     similarity: Similarity? = nil) -> CollageAlbum.Plan {
        var pool = photos.filter { $0.verdict != .reject }
        if pool.isEmpty { pool = photos }
        let moments = oneMoment(pool)
        var dropped = moments.dropped
        var kept = moments.kept
        var similar: [String: Set<String>] = [:]
        if let given = similarity {
            kept = kept.filter { p in given.kept.contains { $0.id == p.id } }
            dropped += given.dropped.filter { d in moments.kept.contains { $0.id == d.id } }
            similar = given.similar
        } else {
            let r = CollageSelect.distinctMoments(kept)
            similar = r.similar
            if dedupe {
                kept = r.kept
                dropped += r.dropped
            }
        }
        guard !kept.isEmpty else { return CollageAlbum.Plan(spreads: [], dropped: dropped, theme: .fineArt) }

        let ordered = CollageSelect.chronological(kept)
        var chapters: [[CollagePhotoRef]] = []
        for p in ordered {
            if let last = chapters.last?.last, last.chapter == p.chapter {
                chapters[chapters.count - 1].append(p)
            } else {
                chapters.append([p])
            }
        }

        // 扉页：全书景别最宽的那一档里分数最高的。
        let title = widest(ordered)
        var spreads: [CollageAlbum.Spread] = []
        spreads.append(spread(.title, [title], chapter: chapterIndex(of: title, in: chapters)))
        spreads[0].fineArt?.latinTitle = isLatinTitle(bookTitle)
        var used: Set<String> = [title.id]
        // 扉页后面紧跟的那个跨页不放和扉页同姿势的（一翻开就连着看到两遍差不多的画面）。
        var avoidNext = similarSet(title, similar)

        // 呼吸图：按跨页数定几张（全书 3–4 张），各章轮着挑分数高的。
        let estimate = Int((Double(ordered.count) / targetPerSpread).rounded(.up))
        let quota = breathQuota(spreads: estimate)
        var breathIDs: Set<String> = []
        if quota > 0 {
            var perChapter = chapters.map { c in
                c.filter { isBreath($0) && $0.id != title.id }.sorted { $0.score > $1.score }
            }
            var round = 0
            while breathIDs.count < quota, perChapter.contains(where: { !$0.isEmpty }), round < 64 {
                for i in perChapter.indices where !perChapter[i].isEmpty && breathIDs.count < quota {
                    // 一章最多两张呼吸图，再多就不叫「喘口气」了。
                    let already = chapters[i].filter { breathIDs.contains($0.id) }.count
                    if already >= 2 { perChapter[i] = []; continue }
                    breathIDs.insert(perChapter[i].removeFirst().id)
                }
                round += 1
            }
        }

        var busyRun = 0
        let multiChapter = chapters.count >= 2
        for (ci, chapter) in chapters.enumerated() {
            var rest = chapter.filter { !used.contains($0.id) }
            guard !rest.isEmpty else { continue }
            let monoShare = Double(chapter.filter { $0.isMonochrome == true }.count) / Double(chapter.count)
            let wholeMono = chapterMono && monoShare >= monoChapterShare
            var chapterSpreads: [CollageAlbum.Spread] = []

            // 本章高潮：分数最高的精选（没有精选 = 分数最高的那张）。照片少的章（多章时不到 4 张）不单独收尾：
            // 开篇、收尾都是单张，三张的章就成了三个单图跨页，整本稀得不像书。
            var climax: CollagePhotoRef?
            if multiChapter ? rest.count >= 4 : rest.count >= 2 {
                // 呼吸图不当高潮（它们是留给「喘口气」的，除非这一章只剩它们）。
                let plain = rest.filter { !breathIDs.contains($0.id) }
                let picks = (plain.isEmpty ? rest : plain).filter(\.isPick)
                let pool = picks.isEmpty ? (plain.isEmpty ? rest : plain) : picks
                climax = pool.max { a, b in a.score == b.score ? a.id > b.id : a.score < b.score }
                if let c = climax { rest.removeAll { $0.id == c.id } }
            }
            // 章节开篇：本章景别最宽的一张（两章以上、从第二章起才有；第一章、只有一章时扉页就是开篇）。
            if multiChapter, ci > 0, !rest.isEmpty {
                let candidates = rest.filter { !breathIDs.contains($0.id) }
                let pool = candidates.isEmpty ? rest : candidates
                let fresh = pool.filter { !avoidNext.contains($0.id) }
                let opener = widest(fresh.isEmpty ? pool : fresh)
                avoidNext = []
                rest.removeAll { $0.id == opener.id }
                chapterSpreads.append(spread(.chapter, [opener], chapter: ci,
                                             caption: chapterCaption(ci, opener)))
                busyRun = 0
            }
            var queue = rest.filter { !breathIDs.contains($0.id) }
            var pendingBreaths = rest.filter { breathIDs.contains($0.id) }

            var bodySpreads: [CollageAlbum.Spread] = []
            while !queue.isEmpty {
                if busyRun >= maxBusyRun {
                    // 连着 3 个多图跨页：插一个单图（先用呼吸图，没有就拿下一张单独放）。
                    if !pendingBreaths.isEmpty {
                        bodySpreads.append(spread(.breath, [pendingBreaths.removeFirst()], chapter: ci))
                    } else {
                        let p = queue.removeFirst()
                        bodySpreads.append(spread(p.isPortrait ? .single : .landscape, [p], chapter: ci))
                    }
                    busyRun = 0
                    continue
                }
                let beat = bodySpreads.count
                // 扉页之后的第一个跨页：同姿势的往后挪一个位置（只挪这一次，时间顺序差一点点）。
                if !avoidNext.isEmpty, let k = queue.firstIndex(where: { !avoidNext.contains($0.id) }), k > 0 {
                    queue.insert(queue.remove(at: k), at: 0)
                }
                let next = fill(&queue, sparse: beat < sparseSpreads, beat: beat, similar: similar, mono: wholeMono,
                                avoid: avoidNext)
                avoidNext = []
                bodySpreads.append(next.with(chapter: ci))
                busyRun = next.photos.count >= 2 ? busyRun + 1 : 0
            }
            // 最后落单的一张（配不上的）：前一个是对页双图、三张合得来，就并成一主两辅（不让两个单张挨着收尾）。
            if bodySpreads.count >= 2, let last = bodySpreads.last, let lastInfo = last.fineArt,
               lastInfo.kind == .single || lastInfo.kind == .landscape,
               let prev = bodySpreads[bodySpreads.count - 2].fineArt, prev.kind == .pair {
                let pair = bodySpreads[bodySpreads.count - 2].photos
                let lone = last.photos[0]
                let trio = CollageSelect.chronological(pair + [lone])
                if compatible(lone, with: pair, similar: similar, mono: wholeMono),
                   let merged = mainPlusTwoSpread(trio) {
                    bodySpreads.removeLast(2)
                    bodySpreads.append(merged.with(chapter: ci))
                }
            }
            // 剩下的呼吸图插进这一章中间：两边最好都是多图跨页（单图挨着单图就成了一串空页），越靠中间越好。
            for b in pendingBreaths {
                let n = bodySpreads.count
                var best = n
                var bestCost = Double.infinity
                for k in 0...n {
                    let prevSingle = k == 0 || bodySpreads[k - 1].photos.count < 2
                    let nextSingle = k == n || bodySpreads[k].photos.count < 2
                    let centre: Double = abs(Double(k) - Double(n) / 2) / Double(max(1, n))
                    let cost: Double = (prevSingle ? 2 : 0) + (nextSingle ? 2 : 0) + centre
                    if cost < bestCost {
                        bestCost = cost
                        best = k
                    }
                }
                bodySpreads.insert(spread(.breath, [b], chapter: ci), at: best)
            }
            chapterSpreads += bodySpreads
            busyRun = 0
            if let c = climax {
                chapterSpreads.append(spread(c.isPortrait ? .single : .landscape, [c], chapter: ci))
                busyRun = 0
            }
            // 不连着 3 个单图跨页：开篇、收尾、呼吸页不动，正文里落单的并起来。
            let hasOpener = multiChapter && chapterSpreads.first?.fineArt?.kind == .chapter
            var fixed: Set<String> = []
            if hasOpener, let o = chapterSpreads.first?.photos.first { fixed.insert(o.id) }
            if let c = climax { fixed.insert(c.id) }
            // 连着的单图跨页跨章也算：前面（扉页、上一章的收尾……）挨着的单图跨页，和下一章的章节开篇。
            var lead = 0
            for s in spreads.reversed() {
                guard s.photos.count == 1 else { break }
                lead += 1
            }
            let nextOpens = multiChapter && chapters.dropFirst(ci + 1).contains { c in c.contains { !used.contains($0.id) } }
            capSingles(&chapterSpreads, fixed: fixed, bodyStart: hasOpener ? 1 : 0, similar: similar, mono: wholeMono,
                       lead: lead, tail: nextOpens ? 1 : 0)
            // 色调：整章黑白 → 整章黑白页；不然全是黑白照片的跨页设黑白页（不叠雅致的暖高光），彩色照片的跟工程。
            for i in chapterSpreads.indices {
                let allMono = chapterSpreads[i].photos.allSatisfy { $0.isMonochrome == true }
                if wholeMono || allMono { chapterSpreads[i].fineArt?.look = monoLook }
            }
            for s in chapterSpreads { used.formUnion(s.photos.map(\.id)) }
            spreads += chapterSpreads
        }
        // 扉页的色调同样看照片本身。
        if title.isMonochrome == true { spreads[0].fineArt?.look = monoLook }
        return CollageAlbum.Plan(spreads: spreads, dropped: dropped, theme: .fineArt)
    }

    /// 同一瞬间只留一张：近似重复组（burstGroup）里留精选 / 分数最高的；同一 take（场）有精选就只留精选
    /// （照片人选了好几张就都留，编排时不放在同一跨页），没有精选留场内名次第一 / 分数最高的那张。
    static func oneMoment(_ photos: [CollagePhotoRef]) -> (kept: [CollagePhotoRef], dropped: [CollagePhotoRef]) {
        func better(_ a: CollagePhotoRef, _ b: CollagePhotoRef) -> Bool {
            if a.isPick != b.isPick { return a.isPick }
            let ra = a.takeRank ?? 99
            let rb = b.takeRank ?? 99
            if ra != rb { return ra < rb }
            if a.score != b.score { return a.score > b.score }
            return a.id < b.id
        }
        var dropped: [CollagePhotoRef] = []
        // 近似重复组：每组一张。
        var bestInBurst: [Int: CollagePhotoRef] = [:]
        for p in photos {
            guard let g = p.burstGroup else { continue }
            if let cur = bestInBurst[g], !better(p, cur) { continue }
            bestInBurst[g] = p
        }
        var stage: [CollagePhotoRef] = []
        for p in photos {
            if let g = p.burstGroup, bestInBurst[g]?.id != p.id {
                dropped.append(p)
            } else {
                stage.append(p)
            }
        }
        // 场：有精选只留精选，没有留最好的一张。
        var takes: [Int: [CollagePhotoRef]] = [:]
        for p in stage { if let t = p.take { takes[t, default: []].append(p) } }
        var keep: Set<String> = []
        for (_, members) in takes {
            let picks = members.filter(\.isPick)
            if picks.isEmpty {
                if let best = members.min(by: better) { keep.insert(best.id) }
            } else {
                keep.formUnion(picks.map(\.id))
            }
        }
        var kept: [CollagePhotoRef] = []
        for p in stage {
            if p.take == nil || keep.contains(p.id) { kept.append(p) } else { dropped.append(p) }
        }
        return (kept, dropped)
    }

    /// 景别最宽的那一档里分数最高的（没有脸 = 最宽）；横图稍微优先（宽景放右页最舒展）。
    static func widest(_ photos: [CollagePhotoRef]) -> CollagePhotoRef {
        func width(_ p: CollagePhotoRef) -> Double { p.faces.isEmpty ? 0 : (p.faceAreaPct ?? 0.05) }
        let sorted = photos.sorted { width($0) < width($1) }
        // 最宽的 40%（至少 1 张）里挑。
        let n = max(1, Int((Double(sorted.count) * 0.4).rounded(.up)))
        let head = sorted.prefix(n)
        func value(_ p: CollagePhotoRef) -> Double { p.score + (p.isPortrait ? 0 : 0.15) }
        return head.max { a, b in value(a) == value(b) ? a.id > b.id : value(a) < value(b) } ?? photos[0]
    }

    static func isBreath(_ p: CollagePhotoRef) -> Bool {
        p.faces.isEmpty || (p.faceAreaPct ?? 1) < breathFaceArea
    }

    /// 呼吸图几张（DESIGN：全书 3–4 张）：15 个跨页起 3 张（AU 的婚礼册是 17–27 个跨页），28 个起 4 张；
    /// 更薄的册子按比例少放（6–13 个跨页 1 张、14 个 2 张：一本十来个跨页的册子放三张空镜就太空了），5 个跨页以下不放。
    static func breathQuota(spreads: Int) -> Int {
        guard spreads >= 6 else { return 0 }
        if spreads >= 28 { return 4 }
        if spreads >= 15 { return 3 }
        return max(1, (spreads + 2) / 8)
    }

    /// 章节开篇左页那行字：罗马数字章序 · 这一章第一张的时刻（24 小时制，en_US_POSIX）。
    /// 点前面用发丝空格（U+200A）：Baskerville 的 I、V 右边和点左边的留白比点右边加数字左边宽，两边都用普通空格
    /// 300dpi 下量出来是 36 | 30 像素（字距每个字后面都加），点前换成发丝空格是 28 | 25–30。
    static func chapterCaption(_ index: Int, _ first: CollagePhotoRef) -> String {
        let numeral = roman(index + 1)
        guard let t = first.captureTime else { return numeral }
        return numeral + "\u{200A}· " + timeFormatter.string(from: t)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HH:mm"
        return f
    }()

    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = max(1, n)
        var out = ""
        for (v, s) in table {
            while rest >= v {
                out += s
                rest -= v
            }
        }
        return out
    }

    private static func chapterIndex(of p: CollagePhotoRef, in chapters: [[CollagePhotoRef]]) -> Int {
        chapters.firstIndex { c in c.contains { $0.id == p.id } } ?? 0
    }

    private static func spread(_ kind: CollageFineArtSpread.Kind, _ photos: [CollagePhotoRef], chapter: Int,
                               caption: String? = nil) -> CollageAlbum.Spread {
        let classic: CollageAlbum.SpreadKind
        switch kind {
        case .title: classic = .opener
        case .pair: classic = .pair
        case .mainPlusTwo, .triptych: classic = .grid
        default: classic = .solo
        }
        var s = CollageAlbum.Spread(kind: classic, photos: photos)
        s.fineArt = CollageFineArtSpread(kind: kind, chapter: chapter, caption: caption)
        return s
    }

    /// 和 p 同姿势的（相似关系两个方向都看）。
    static func similarSet(_ p: CollagePhotoRef, _ similar: [String: Set<String>]) -> Set<String> {
        var out = similar[p.id] ?? []
        for (k, v) in similar where v.contains(p.id) { out.insert(k) }
        return out
    }

    /// 拿掉的分两种说（命令行那一行、界面的提示）：同一场只留精选 / 近似重复只留一张（oneMoment，fine-art 一直开着），
    /// 和画面相似（「相似只留一张」那个开关）。
    static func droppedCounts(_ photos: [CollagePhotoRef], plan: CollageAlbum.Plan) -> (moments: Int, similar: Int) {
        var pool = photos.filter { $0.verdict != .reject }
        if pool.isEmpty { pool = photos }
        let moments = oneMoment(pool).dropped.count
        return (moments, max(0, plan.dropped.count - moments))
    }

    static func droppedNote(_ photos: [CollagePhotoRef], plan: CollageAlbum.Plan) -> String {
        let n = droppedCounts(photos, plan: plan)
        return "同一场只留精选拿掉 \(n.moments) · 相似拿掉 \(n.similar)"
    }

    // MARK: - 不连着 3 个单图跨页

    /// 连着的单图跨页最多几个（R3 疏 → 密：一串左页空着的单图读起来像没排完）。
    static let maxSingleRun = 2

    /// 正文里落单的单张（不是章节开篇、呼吸页、本章收尾）两两并成对页双图：先找同方向的，再找横竖混排的
    /// （左右按矮的那张同高）；并不成就并进旁边的对页双图成一主两辅（开篇之后两个疏的跨页不并）。并了之后多图跨页
    /// 不能连着超过 3 个（R4）。同一场不进同一跨页这条在这里放开（不同姿势、亮度差得不多就行）。
    /// 剩下的一串（全是开篇 / 呼吸 / 收尾，或者谁和谁都合不来）照旧。
    /// lead / tail：这一章前面、后面挨着的单图跨页有几个（前面 = 扉页、上一章的收尾；后面 = 下一章的章节开篇）：
    /// 连成一串的长度跨章算，只是并的只能是这一章里的。
    private static func capSingles(_ spreads: inout [CollageAlbum.Spread], fixed: Set<String>, bodyStart: Int,
                                   similar: [String: Set<String>], mono: Bool, lead: Int = 0, tail: Int = 0) {
        func movable(_ s: CollageAlbum.Spread) -> Bool {
            guard s.photos.count == 1, let k = s.fineArt?.kind, k == .single || k == .landscape else { return false }
            return !fixed.contains(s.photos[0].id)
        }
        func longestBusy(_ list: [CollageAlbum.Spread]) -> Int {
            var best = 0
            var run = 0
            for s in list {
                run = s.photos.count >= 2 ? run + 1 : 0
                best = max(best, run)
            }
            return best
        }
        func longRuns(_ list: [CollageAlbum.Spread]) -> [ClosedRange<Int>] {
            // 前面 lead 个、后面 tail 个单图跨页接在两头（下标 < 0 / ≥ count），一串里落在这一章的那段才拿去并。
            var out: [ClosedRange<Int>] = []
            var start: Int? = lead > 0 ? -lead : nil
            let end = list.count + tail
            for i in 0...end {
                let single = i < list.count ? list[i].photos.count == 1 : i < end
                if single, start == nil { start = i }
                if !single, let s = start {
                    let lo = max(0, s)
                    let hi = min(list.count, i) - 1
                    if i - s > maxSingleRun, lo <= hi { out.append(lo...hi) }
                    start = nil
                }
            }
            return out
        }
        func pairMerge(_ list: [CollageAlbum.Spread], _ i: Int, mixed: Bool) -> [CollageAlbum.Spread]? {
            guard i + 1 < list.count, movable(list[i]), movable(list[i + 1]) else { return nil }
            let a = list[i].photos[0]
            let b = list[i + 1].photos[0]
            guard (a.isPortrait != b.isPortrait) == mixed,
                  compatible(b, with: [a], similar: similar, mono: mono, relaxTake: true),
                  lumaGap([a], [b]) <= maxLumaGap else { return nil }
            var merged = spread(.pair, CollageSelect.chronological([a, b]), chapter: list[i].fineArt?.chapter ?? 0)
            merged.fineArt?.merged = true
            var out = list
            out.replaceSubrange(i...(i + 1), with: [merged])
            return out
        }
        func trioMerge(_ list: [CollageAlbum.Spread], _ j: Int, _ n: Int) -> [CollageAlbum.Spread]? {
            guard n >= 0, n < list.count, movable(list[j]), list[n].fineArt?.kind == .pair,
                  list[n].photos.count == 2, min(j, n) >= bodyStart + sparseSpreads else { return nil }
            let pair = list[n].photos
            let lone = list[j].photos[0]
            guard compatible(lone, with: pair, similar: similar, mono: mono, relaxTake: true),
                  let merged = mainPlusTwoSpread(CollageSelect.chronological(pair + [lone])) else { return nil }
            var out = list
            out.replaceSubrange(min(j, n)...max(j, n), with: [merged.with(chapter: list[j].fineArt?.chapter ?? 0)])
            return out
        }
        for _ in 0..<32 {
            var next: [CollageAlbum.Spread]?
            search: for run in longRuns(spreads) {
                for mixed in [false, true] {
                    for i in run where i < run.upperBound {
                        if let c = pairMerge(spreads, i, mixed: mixed), longestBusy(c) <= maxBusyRun {
                            next = c
                            break search
                        }
                    }
                }
                for j in run {
                    for n in [j - 1, j + 1] {
                        if let c = trioMerge(spreads, j, n), longestBusy(c) <= maxBusyRun {
                            next = c
                            break search
                        }
                    }
                }
            }
            guard let merged = next else { return }
            spreads = merged
        }
    }

    // MARK: - 一个跨页放哪几张

    /// 两张能不能放在同一跨页：同色调（整章黑白时不管）、不是同一场 / 同姿势、亮度差不超过上限。
    /// relaxTake：同一场也行（只要不是同姿势；并落单的单张时用）。
    static func compatible(_ p: CollagePhotoRef, with members: [CollagePhotoRef], similar: [String: Set<String>],
                           mono: Bool, relaxTake: Bool = false) -> Bool {
        for m in members {
            if !mono, (p.isMonochrome == true) != (m.isMonochrome == true) { return false }
            if !relaxTake, let a = p.take, let b = m.take, a == b { return false }
            if similar[p.id]?.contains(m.id) == true || similar[m.id]?.contains(p.id) == true { return false }
        }
        return true
    }

    /// 两页的亮度差（不知道亮度 = 0）。
    static func lumaGap(_ left: [CollagePhotoRef], _ right: [CollagePhotoRef]) -> Double {
        func mean(_ ps: [CollagePhotoRef]) -> Double? {
            let ls = ps.compactMap(\.meanLuma)
            return ls.isEmpty ? nil : ls.reduce(0, +) / Double(ls.count)
        }
        guard let a = mean(left), let b = mean(right) else { return 0 }
        return abs(a - b)
    }

    /// 从队首起排下一个跨页（队首那张一定在里面，配的照片只在往后 lookahead 张里找，不打乱太多时间顺序）：
    /// - 疏的阶段（每章前两个）：竖图找下一张竖图配对页双图，横图找横图；配不上就单张；
    /// - 密的阶段：细节（没脸 / 小脸）凑得出三张 → 细节三联；按节拍轮流一主两辅 / 对页双图，凑不齐退一档。
    /// avoid：这几张不当配的（扉页之后第一个跨页：和扉页同姿势的）。
    private static func fill(_ queue: inout [CollagePhotoRef], sparse: Bool, beat: Int,
                             similar: [String: Set<String>], mono: Bool,
                             avoid: Set<String> = []) -> CollageAlbum.Spread {
        let first = queue.removeFirst()
        let window = Array(queue.prefix(lookahead))
        func take(_ p: CollagePhotoRef) { queue.removeAll { $0.id == p.id } }
        func mate(_ members: [CollagePhotoRef], where ok: (CollagePhotoRef) -> Bool) -> CollagePhotoRef? {
            window.first { p in
                ok(p) && !avoid.contains(p.id) && !members.contains { $0.id == p.id }
                    && compatible(p, with: members, similar: similar, mono: mono)
            }
        }
        func pairSpread(_ a: CollagePhotoRef, _ b: CollagePhotoRef) -> CollageAlbum.Spread {
            spread(.pair, CollageSelect.chronological([a, b]), chapter: 0)
        }
        func single(_ p: CollagePhotoRef) -> CollageAlbum.Spread {
            spread(p.isPortrait ? .single : .landscape, [p], chapter: 0)
        }
        // 对页双图：同方向（同高）、两页亮度差得不多。
        func pairMate() -> CollagePhotoRef? {
            mate([first]) { p in p.isPortrait == first.isPortrait && lumaGap([first], [p]) <= maxLumaGap }
        }
        if sparse {
            if let b = pairMate() {
                take(b)
                return pairSpread(first, b)
            }
            return single(first)
        }
        // 细节三联：三张都是细节。
        if isBreath(first), let b = mate([first], where: isBreath) {
            if let c = mate([first, b], where: isBreath) {
                take(b)
                take(c)
                return spread(.triptych, CollageSelect.chronological([first, b, c]), chapter: 0)
            }
        }
        // 一主两辅：三张里分数最高的当主图；两页亮度差得不多。
        func mainPlusTwo() -> CollageAlbum.Spread? {
            guard let b = mate([first], where: { _ in true }),
                  let c = mate([first, b], where: { _ in true }),
                  let s = mainPlusTwoSpread(CollageSelect.chronological([first, b, c])) else { return nil }
            take(b)
            take(c)
            return s
        }
        // 节拍：密的阶段一主两辅、对页双图轮着来（密的第一个是一主两辅）；对页双图只配同方向的（竖图成对，R11）。
        // 本章快排完时按剩几张定，别剩下一张落单：剩 3 张先一主两辅，剩 4 张先两个对页双图。
        let remaining = queue.count + 1
        let preferMain = remaining == 3 || (remaining != 4 && beat % 2 == 0)
        if preferMain, let s = mainPlusTwo() { return s }
        if let b = pairMate() {
            take(b)
            return pairSpread(first, b)
        }
        if let s = mainPlusTwo() { return s }
        return single(first)
    }

    /// 三张（按时间排好）排成一主两辅：主图 = 分数最高的，主图那一页和配图那一页亮度差超了 = nil。
    /// 主图在时间上最早就放左页，否则放右页（读的顺序跟着时间走）。
    static func mainPlusTwoSpread(_ trio: [CollagePhotoRef]) -> CollageAlbum.Spread? {
        guard trio.count == 3,
              let main = trio.max(by: { x, y in x.score == y.score ? x.id > y.id : x.score < y.score }) else { return nil }
        let others = trio.filter { $0.id != main.id }
        guard lumaGap([main], others) <= maxLumaGap else { return nil }
        var s = spread(.mainPlusTwo, trio, chapter: 0)
        let index = trio.firstIndex { $0.id == main.id } ?? 0
        s.fineArt?.mainIndex = index
        s.fineArt?.mainOnLeft = index == 0
        return s
    }

    // MARK: - 版式

    /// fine-art 跨页的版式（CollageAlbum.layout 遇到 spread.fineArt 走这里）：根节点 row(0.5, 左页, 右页)，
    /// 照片格完整显示，大小、位置按这本册子的版心现算（模板用的是同一套页面积木）。
    static func layout(_ spread: CollageAlbum.Spread, info: CollageFineArtSpread,
                       context: CollageLayout.Context) -> CollageNode {
        let box = pageBox(canvas: context.canvas, style: context.style)
        let mat = context.style.border == .mat ? context.style.matWidth : 0
        let small = smallSize(for: context.canvas)
        let photos = spread.photos
        func cell(_ p: CollagePhotoRef, hero: Bool = false) -> CollageNode { plate(hero ? .hero : .support, id: p.id) }
        func slot(_ p: CollagePhotoRef, _ role: CollageRole) -> Slot { Slot(id: p.id, role: role, aspect: p.aspect) }
        func row(_ left: CollageNode, _ right: CollageNode) -> CollageNode { CollageTemplates.row(0.5, left, right) }
        guard let first = photos.first else { return row(CollageTemplates.empty(), CollageTemplates.empty()) }
        switch info.kind {
        case .title:
            // 标题、日期行分两格：长标题只缩标题，日期行不小于 2.8mm。
            let left = titlePage(latin: info.latinTitle, small: small, box: box, short: context.canvas.shortSide)
            return row(left, cell(first, hero: true))
        case .chapter:
            // 章节那一行比日期行大一号（还是小字：约 11pt）。
            let size: Double = small * chapterCaptionScale
            return row(CollageTemplates.text(captionText(info.caption ?? "", size: size)), cell(first, hero: true))
        case .single, .landscape:
            return row(CollageTemplates.empty(), cell(first, hero: true))
        case .breath:
            return row(CollageTemplates.empty(), breathPage(cell(first, hero: true), aspect: first.aspect, in: box))
        case .pair:
            guard photos.count > 1 else { return row(cell(first, hero: true), CollageTemplates.empty()) }
            // 同方向（同比例）两页整版；并起来的横竖混排按矮的那张同高。
            let pages = pairPages([slot(first, .hero), slot(photos[1], .support)], in: box, mat: mat)
            return row(pages.left, pages.right)
        case .mainPlusTwo:
            guard photos.count >= 3 else { return row(cell(first, hero: true), photos.count > 1 ? cell(photos[1]) : CollageTemplates.empty()) }
            let i = min(max(0, info.mainIndex), photos.count - 1)
            let main = photos[i]
            let others = photos.enumerated().filter { $0.offset != i }.map(\.element)
            let mainArea = plateArea(aspect: main.aspect, in: box, mat: mat)
            let supports = supportsPage(others.map { slot($0, .support) }, mainArea: mainArea, in: box, mat: mat,
                                        fixed: false)
            return info.mainOnLeft ? row(cell(main, hero: true), supports) : row(supports, cell(main, hero: true))
        case .triptych:
            let slots = photos.enumerated().map { slot($0.element, $0.offset == 1 ? .hero : .support) }
            return row(CollageTemplates.empty(), tripletPage(slots, in: box, mat: mat, fixed: false))
        }
    }

    /// 编排 → 页：每个跨页按 fine-art 版式，页级色调照编排给的（整章黑白）。
    static func build(_ plan: CollageAlbum.Plan, context: CollageLayout.Context) -> [CollagePage] {
        plan.spreads.map { spread in
            guard let info = spread.fineArt else {
                return CollagePage(root: CollageAlbum.layout(spread, previousSignature: "", context: context, seed: 1))
            }
            var page = CollagePage(root: layout(spread, info: info, context: context))
            page.look = info.look
            return page
        }
    }
}

extension CollageAlbum.Spread {
    /// 换上章节号（fill 先按 0 建）。
    func with(chapter: Int) -> CollageAlbum.Spread {
        var out = self
        out.fineArt?.chapter = chapter
        return out
    }
}
