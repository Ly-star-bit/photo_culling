import Foundation

/// --album-selftest 里相册编排的另外几条（合成数据，不跑 Vision）：
/// - F19 客户选中无条件保留：废片、同一场只留精选、连拍只留一张、给定的相似去重都不拿掉客户选中的；
///   CollagePhotoRef.clientPick 存盘 / 旧工程 / 坏值。
/// - F06 目标跨页数：默认编排正好塞进 N 个跨页、放不下多出来、太少就少，一张不丢、每跨页张数在区间里、
///   全书疏密差不多、章节顺序不乱；fine-art 往目标并（不丢片、每跨页最多 3 张）；存盘、命令行参数。
enum CollageAlbumPlanSelfTest {

    static func run(book: CollageStyleFineArtSelfTest.Book, check: (Bool, String, String) -> Void) {
        checkClientPicks(book: book, check: check)
        checkDistinctKeeping(check: check)
        checkBudgetClassic(book: book, check: check)
        checkBudgetFineArt(book: book, check: check)
        checkBudgetModel(check: check)
    }

    // MARK: - F06 目标跨页数

    static func counts(_ plan: CollageAlbum.Plan) -> String {
        plan.spreads.map { String($0.photos.count) }.joined(separator: " ")
    }

    static func checkBudgetClassic(book: CollageStyleFineArtSelfTest.Book, check: (Bool, String, String) -> Void) {
        print("== 目标跨页数（默认编排）")
        let photos = book.photos
        let ids = Set(photos.map(\.id))
        let natural = CollageAlbum.plan(photos, dedupe: true)
        let explicitNil = CollageAlbum.plan(photos, dedupe: true, budget: nil)
        check(CollageStyleFineArtSelfTest.signature(natural) == CollageStyleFineArtSelfTest.signature(explicitNil)
              && natural.budget == nil,
              "不指定跨页数 = 原来的编排", "\(natural.spreads.count) 个跨页")
        // 每一种：一张不丢、没有重复、章节顺序不乱（跨页按章排，不会回到前一章）、扉页一张。
        func sound(_ plan: CollageAlbum.Plan, _ name: String) {
            let placed = plan.spreads.flatMap(\.photos).map(\.id)
            let chapters = plan.spreads.dropFirst().map { $0.photos.first?.chapter ?? 0 }
            let ordered = zip(chapters, chapters.dropFirst()).allSatisfy { $0 <= $1 }
            let oneChapter = plan.spreads.dropFirst().allSatisfy { s in Set(s.photos.map { $0.chapter ?? 0 }).count == 1 }
            let complete: Bool = Set(placed) == ids && placed.count == ids.count && plan.dropped.isEmpty
            let openerOne: Bool = (plan.spreads.first?.photos.count ?? 0) == 1
            check(complete && ordered && oneChapter && openerOne,
                  name + "：一张不丢、没有重复、一个跨页只放一章、章节顺序不乱", counts(plan))
        }
        for (target, lo, hi) in [(20, 1, 6), (25, 1, 6), (12, 1, 8), (24, 2, 4)] {
            let b = CollageAlbumBudget(spreads: target, minPerSpread: lo, maxPerSpread: hi)
            let plan = CollageAlbum.plan(photos, dedupe: true, budget: b)
            check(plan.spreads.count == target && plan.budget == b, "\(photos.count) 张塞进 \(b.label)：正好 \(target) 个",
                  "\(plan.spreads.count) 个")
            let body = plan.spreads.dropFirst().map(\.photos.count)
            let inRange = body.allSatisfy { $0 >= lo && $0 <= hi }
            check(inRange, "\(target) 个跨页：扉页以外每跨页 \(lo)–\(hi) 张", counts(plan))
            sound(plan, "\(target) 个跨页")
            // 疏密差不多（SmartAlbums 被抱怨的是前面一两张、后面五六张）：多图跨页前一半和后一半的平均张数差不超过
            // 1.5 张，最挤的不超过最松的 2.5 倍（4-3-5-2 的节奏起伏留着）。
            let grids = plan.spreads.dropFirst().filter { $0.kind == .grid }.map(\.photos.count)
            let half = grids.count / 2
            let front = Double(grids.prefix(half).reduce(0, +)) / Double(max(1, half))
            let back = Double(grids.dropFirst(half).reduce(0, +)) / Double(max(1, grids.count - half))
            let most = Double(grids.max() ?? 0)
            let least = Double(max(1, grids.min() ?? 1))
            check(most <= 2.5 * least && abs(front - back) <= 1.5, "\(target) 个跨页：全书疏密差不多",
                  String(format: "多图跨页 %.0f–%.0f 张 · 前一半 %.1f 后一半 %.1f", least, most, front, back))
        }
        // 放不下：每跨页最多 6 张、只给 6 个跨页 → 多出来，一张不丢。
        let tight = CollageAlbumBudget(spreads: 6, minPerSpread: 1, maxPerSpread: 6)
        let over = CollageAlbum.plan(photos, dedupe: true, budget: tight)
        let overBody = over.spreads.dropFirst().map(\.photos.count)
        check(over.spreads.count > 6 && overBody.allSatisfy { $0 <= 6 }, "放不下：多出几个跨页，每跨页还是最多 6 张",
              "\(over.spreads.count) 个 · " + counts(over))
        sound(over, "放不下")
        let overNote = CollageAlbumBudget.outcome(spreads: over.spreads.count, budget: tight, photos: photos.count, fineArt: false) ?? ""
        check(overNote.contains("多 \(over.spreads.count - 6) 个") && overNote.contains("不替你删片"),
              "放不下的提示：多几个、没删片", overNote)
        // 太少：100 个跨页 → 每张一个跨页也只有那么多。
        let loose = CollageAlbumBudget(spreads: 100)
        let under = CollageAlbum.plan(photos, dedupe: true, budget: loose)
        check(under.spreads.count < 100 && under.spreads.count >= photos.count - 8, "照片不够：少几个跨页，不加空页",
              "\(under.spreads.count) 个")
        sound(under, "照片不够")
        // 同一输入两次一样。
        let a = CollageAlbum.plan(photos, dedupe: true, budget: CollageAlbumBudget(spreads: 20))
        let b = CollageAlbum.plan(photos, dedupe: true, budget: CollageAlbumBudget(spreads: 20))
        check(CollageStyleFineArtSelfTest.signature(a) == CollageStyleFineArtSelfTest.signature(b), "同一输入两次编排一样", "")
        // 拆开的几块：分大小加起来正好、在区间里；按章分加起来正好。
        var sizesOK = true
        for n in [1, 2, 5, 9, 17, 40] {
            for g in 1...max(1, n) where (n + 5) / 6 <= g && g <= n {
                let s = CollageAlbum.bucketSizes(n, into: g, lo: 1, hi: 6, beat: n)
                if s.reduce(0, +) != n || s.count != g || s.contains(where: { $0 < 1 || $0 > 6 }) { sizesOK = false }
            }
        }
        check(sizesOK, "跨页大小：加起来正好、每个 1–6 张", "")
        let alloc = CollageAlbum.allocate([10, 3, 0, 25], total: 9, lo: 1, hi: 6)
        check(alloc.reduce(0, +) == 9 && alloc[2] == 0 && alloc[1] >= 1 && alloc[3] >= 5,
              "按章分跨页：加起来正好、空章不给、每章放得下", alloc.map(String.init).joined(separator: " "))
    }

    static func checkBudgetFineArt(book: CollageStyleFineArtSelfTest.Book, check: (Bool, String, String) -> Void) {
        print("== 目标跨页数（婚礼 fine-art）")
        let natural = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: book.similarity)
        let n = natural.spreads.count
        let naturalIDs = Set(natural.spreads.flatMap(\.photos).map(\.id))
        let roomy = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: book.similarity,
                                             budget: CollageAlbumBudget(spreads: n + 5))
        check(CollageStyleFineArtSelfTest.signature(roomy) == CollageStyleFineArtSelfTest.signature(natural),
              "目标比编出来的多：和不指定一样（不加页）", "\(n) 个")
        // 目标没卡到（不比编出来的跨页数少）：和不指定一字不差。呼吸图张数以前按 min(照片数 / 1.8 估的跨页数, 目标) 定，
        // 检视器勾「指定跨页数」默认就是现在的跨页数，估的比编出来的多时，目标 = 编出来的也会少一张呼吸图、整本跟着变。
        // 一章 27 张（5 张没脸）：估 15 个跨页（呼吸图 3 张），编出来不到 15 个，正好踩在 3 → 2 张那条线上。
        let oneChapter = oneChapterBook()
        for (name, photos, sim) in [("四章合成婚礼", book.photos, book.similarity), ("一章 27 张", oneChapter.photos, oneChapter.similarity)] {
            let free = CollageStyleFineArt.plan(photos, dedupe: true, chapterMono: true, similarity: sim)
            let real = free.spreads.count
            let placedCount = free.spreads.reduce(0) { $0 + $1.photos.count }
            let estimate = Int((Double(placedCount) / CollageStyleFineArt.targetPerSpread).rounded(.up))
            let freeSig = CollageStyleFineArtSelfTest.signature(free)
            var differ: [Int] = []
            for target in real...max(real, estimate) {
                let p = CollageStyleFineArt.plan(photos, dedupe: true, chapterMono: true, similarity: sim,
                                                 budget: CollageAlbumBudget(spreads: target))
                if CollageStyleFineArtSelfTest.signature(p) != freeSig { differ.append(target) }
            }
            check(differ.isEmpty, "\(name)：目标 \(real)–\(max(real, estimate))（不比编出来的 \(real) 个少）和不指定一字不差",
                  differ.isEmpty ? "估 \(estimate) 个" : "目标 " + differ.map(String.init).joined(separator: " ") + " 变了")
            // 卡到了（目标比编出来的少）：按目标少放呼吸图重编；重编出来比目标还少就不用它（并到正好），一张不丢。
            let freeIDs = Set(free.spreads.flatMap(\.photos).map(\.id))
            var bad: [String] = []
            for target in stride(from: real - 1, through: max(2, real - 8), by: -1) {
                let p = CollageStyleFineArt.plan(photos, dedupe: true, chapterMono: true, similarity: sim,
                                                 budget: CollageAlbumBudget(spreads: target))
                let ids = p.spreads.flatMap(\.photos).map(\.id)
                let whole: Bool = Set(ids) == freeIDs && ids.count == freeIDs.count
                if !whole || p.spreads.count < target || p.spreads.count > real { bad.append("\(target)→\(p.spreads.count)") }
            }
            check(bad.isEmpty, "\(name)：目标比编出来的少时不少于目标、不多于不指定、一张不丢", bad.joined(separator: " "))
        }
        for target in [n - 4, 20, 8] {
            let plan = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: book.similarity,
                                                budget: CollageAlbumBudget(spreads: target))
            let placed = plan.spreads.flatMap(\.photos).map(\.id)
            check(Set(placed) == naturalIDs && placed.count == naturalIDs.count,
                  "目标 \(target)：照片和不指定时一样多（不删片、没重复）", "\(placed.count) 张")
            let fewer: Bool = plan.spreads.count < n && plan.spreads.count >= min(target, n)
            let capped: Bool = plan.spreads.allSatisfy { $0.photos.count <= CollageStyleFineArt.maxPerSpread }
            check(fewer && capped, "目标 \(target)：比不指定的 \(n) 个少，每跨页最多 3 张", "\(plan.spreads.count) 个 · " + counts(plan))
            let kinds: [CollageFineArtSpread.Kind] = plan.spreads.compactMap(\.fineArt?.kind)
            let openers: Int = kinds.filter { $0 == .chapter }.count
            let naturalOpeners: Int = natural.spreads.filter { $0.fineArt?.kind == .chapter }.count
            check(kinds.first == .title && openers == naturalOpeners, "目标 \(target)：扉页、章节开篇都在", "")
            let pages = CollageStyleFineArt.build(plan, context: CollageStyleFineArtSelfTest.context(CollageCanvas.albums[0], book: book.photos))
            let onPages = pages.flatMap { $0.root.photoIDs }
            check(pages.count == plan.spreads.count && Set(onPages) == naturalIDs, "目标 \(target)：每个跨页都出了版式、照片都在格子里", "")
            let broken = compressedViolations(plan.spreads, similar: book.similarity.similar)
            check(broken.isEmpty, "目标 \(target)：压过的册子照样守 R1 / R4 / R7 / R8 / R10（不连着 4 个多图跨页、同姿势 / 黑白彩色不同页……）",
                  broken.isEmpty ? counts(plan) : broken.joined(separator: "；"))
        }
        // 一章 27 张的也压一压（并页只能在一章里挪，最容易连成一长串多图跨页）。
        let single = oneChapterBook()
        let singleFree = CollageStyleFineArt.plan(single.photos, dedupe: true, chapterMono: true, similarity: single.similarity)
        var singleBroken: [String] = []
        for target in [singleFree.spreads.count - 2, 8, 4] {
            let p = CollageStyleFineArt.plan(single.photos, dedupe: true, chapterMono: true, similarity: single.similarity,
                                             budget: CollageAlbumBudget(spreads: target))
            singleBroken += compressedViolations(p.spreads, similar: single.similarity.similar).map { "目标 \(target) " + $0 }
        }
        check(singleBroken.isEmpty, "一章 27 张压到 \(singleFree.spreads.count - 2) / 8 / 4 个：照样守 R1 / R4 / R7 / R8 / R10",
              singleBroken.joined(separator: "；"))
        // 查规则的这一段自己也得认得出违规（不然上面几条白过）：四个对页双图连着、同姿势同页、黑白彩色同页、亮度差太大。
        let ref = { (id: String) in book.photos.first { $0.id == id } }
        func pairOf(_ a: String, _ b: String) -> CollageAlbum.Spread {
            var s = CollageAlbum.Spread(kind: .pair, photos: [a, b].compactMap(ref))
            s.fineArt = CollageFineArtSpread(kind: .pair, chapter: 2)
            return s
        }
        let fourBusy = [pairOf("C02", "C12"), pairOf("C13", "C14"), pairOf("C15", "C16"), pairOf("C03", "C05")]
        let probes: [(String, [CollageAlbum.Spread])] = [
            ("R4", fourBusy), ("R10", [pairOf("C09", "C10")]), ("R7", [pairOf("A11", "C02")]), ("R8", [pairOf("D05", "D06")]),
        ]
        let caught = probes.map { rule, list in
            compressedViolations(list, similar: book.similarity.similar).contains { $0.contains(rule) }
        }
        check(!caught.contains(false), "查压过的册子的规则认得出 R4 / R10 / R7 / R8 违规（自己不是白过）",
              zip(probes, caught).map { "\($0.0.0) \($0.1 ? "认得" : "没认出")" }.joined(separator: " "))
        // 直接喂 compress：并了会同姿势（C09 / C10）、黑白彩色混（E03 黑白）的那一对不并；对照：合得来的照样并。
        func spreadOf(_ kind: CollageFineArtSpread.Kind, _ ids: [String], chapter: Int) -> CollageAlbum.Spread {
            var s = CollageAlbum.Spread(kind: kind == .title ? .opener : (ids.count == 1 ? .solo : .pair), photos: ids.compactMap(ref))
            s.fineArt = CollageFineArtSpread(kind: kind, chapter: chapter)
            // 和 plan 一样：全是黑白照片的跨页是黑白页。
            if s.photos.allSatisfy({ $0.isMonochrome == true }) { s.fineArt?.look = CollageStyleFineArt.monoLook }
            return s
        }
        let opener = spreadOf(.title, ["A13"], chapter: 0)
        let refused: [(String, [CollageAlbum.Spread])] = [
            ("同姿势 对页+单", [opener, spreadOf(.pair, ["C02", "C09"], chapter: 1), spreadOf(.single, ["C10"], chapter: 1)]),
            ("同姿势 单+单", [opener, spreadOf(.single, ["C09"], chapter: 1), spreadOf(.single, ["C10"], chapter: 1)]),
            ("黑白彩色 对页+单", [opener, spreadOf(.pair, ["E02", "E06"], chapter: 3), spreadOf(.single, ["E03"], chapter: 3)]),
            ("黑白彩色 单+单", [opener, spreadOf(.single, ["E02"], chapter: 3), spreadOf(.single, ["E03"], chapter: 3)]),
        ]
        var refusedBad: [String] = []
        for (name, list) in refused {
            var out = list
            CollageStyleFineArt.compress(&out, toward: 2, similar: book.similarity.similar)
            if out.count != list.count || !compressedViolations(out, similar: book.similarity.similar).isEmpty { refusedBad.append(name) }
        }
        var control = [opener, spreadOf(.pair, ["C02", "C12"], chapter: 1), spreadOf(.single, ["C13"], chapter: 1)]
        CollageStyleFineArt.compress(&control, toward: 2, similar: book.similarity.similar)
        check(refusedBad.isEmpty && control.count == 2 && control.last?.fineArt?.kind == .mainPlusTwo,
              "compress 不并同姿势、黑白彩色混的（对页+单、单+单都是），合得来的照样并成一主两辅",
              refusedBad.isEmpty ? "对照并成 \(control.count) 个" : "并了：" + refusedBad.joined(separator: " "))
        let tight = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: book.similarity,
                                             budget: CollageAlbumBudget(spreads: 8))
        check(tight.spreads.count > 8, "fine-art 压到 8 个放不下（每跨页最多 3 张）：多出来、不删片", "\(tight.spreads.count) 个")

        // fine-art 每跨页固定 1–3 张、不看目标里的每跨页张数（命令行 / ops 的 20@1-2、默认编排时设的再换成 fine-art
        // 都能把 1–2 带进来）：和 1–6 编出来一样，提示照实际的 3 张说，不说用户填的 2。
        let sig20 = CollageStyleFineArtSelfTest.signature(CollageStyleFineArt.plan(
            book.photos, dedupe: true, chapterMono: true, similarity: book.similarity, budget: CollageAlbumBudget(spreads: 20)))
        let perSpreadSigs: [String] = [(1, 2), (2, 4), (1, 1)].map { lo, hi in
            let b = CollageAlbumBudget(spreads: 20, minPerSpread: lo, maxPerSpread: hi)
            let p = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: book.similarity, budget: b)
            return CollageStyleFineArtSelfTest.signature(p)
        }
        check(perSpreadSigs.allSatisfy { $0 == sig20 }, "fine-art 不看每跨页张数：1–2、2–4、1–1 和 1–6 编出来一样（固定 1–3 张）",
              perSpreadSigs.map { $0 == sig20 ? "同" : "不同" }.joined(separator: " "))
        let capped2 = CollageAlbumBudget(spreads: 8, minPerSpread: 2, maxPerSpread: 2)
        let overText = CollageAlbumBudget.outcome(spreads: 12, budget: capped2, photos: 30, fineArt: true) ?? ""
        let underText = CollageAlbumBudget.outcome(spreads: 5, budget: capped2, photos: 9, fineArt: true) ?? ""
        check(overText.contains("最多 \(CollageStyleFineArt.maxPerSpread) 张") && !overText.contains("最多 2 张")
              && !underText.contains("至少"),
              "fine-art 的提示照实际规则说（最多 3 张，不提用户填的每跨页张数）", overText + " / " + underText)
    }

    /// 压过的册子还得守的那几条（CollageStyleFineArt.compress 并页不许破坏的）：R1 一个跨页只放一章、章节按顺序；
    /// R4 连着的多图跨页最多 maxBusyRun 个；R7 不混黑白和彩色（混的只能是黑白页）、全是黑白的是黑白页；R8 对页双图、
    /// 一主两辅左右页亮度差不超 maxLumaGap；R10 同姿势不进同一跨页；每跨页最多 3 张。不查 R3（每章收尾单张、不连着 3 个
    /// 单图）、R5（呼吸图张数）、R11（落单竖图的比例）：压页本来就是把这些并掉（checkPlan 全跑会误报）。
    static func compressedViolations(_ spreads: [CollageAlbum.Spread], similar: [String: Set<String>]) -> [String] {
        var out: [String] = []
        var run = 0
        for (i, s) in spreads.enumerated() {
            let at = "第 \(i + 1) 个跨页"
            run = s.photos.count >= 2 ? run + 1 : 0
            if run > CollageStyleFineArt.maxBusyRun { out.append(at + " R4 连着 \(run) 个多图跨页") }
            if s.photos.count > CollageStyleFineArt.maxPerSpread { out.append(at + " \(s.photos.count) 张") }
            if Set(s.photos.map { $0.chapter ?? -1 }).count > 1 { out.append(at + " R1 跨章") }
            let monoCount: Int = s.photos.filter { $0.isMonochrome == true }.count
            let monoPage: Bool = s.fineArt?.look?.look == .mono
            if monoCount > 0, !monoPage { out.append(at + " R7 " + (monoCount < s.photos.count ? "黑白彩色混" : "黑白照片不是黑白页")) }
            let samePose: Bool = s.photos.contains { a in
                s.photos.contains { b in a.id != b.id && (similar[a.id]?.contains(b.id) ?? false) }
            }
            if samePose { out.append(at + " R10 同姿势") }
            guard let info = s.fineArt else { continue }
            var gap: Double = 0
            if info.kind == .pair, s.photos.count == 2 {
                gap = CollageStyleFineArt.lumaGap([s.photos[0]], [s.photos[1]])
            } else if info.kind == .mainPlusTwo, !s.photos.isEmpty {
                let main = s.photos[min(info.mainIndex, s.photos.count - 1)]
                gap = CollageStyleFineArt.lumaGap([main], s.photos.filter { $0.id != main.id })
            }
            if gap > CollageStyleFineArt.maxLumaGap { out.append(at + String(format: " R8 亮度差 %.2f", gap)) }
        }
        let chapterSeq: [Int] = spreads.dropFirst().compactMap { $0.fineArt?.chapter }
        if chapterSeq != chapterSeq.sorted() { out.append("R1 章节顺序乱了") }
        return out
    }

    /// 一章 27 张的合成册子（5 张没有人脸 = 呼吸图候选，3 张横图，2 张精选；没有场、连拍、黑白）。
    static func oneChapterBook() -> CollageStyleFineArtSelfTest.Book {
        typealias B = CollageStyleFineArtSelfTest.Book
        var photos: [CollagePhotoRef] = []
        for i in 0..<27 {
            let faceless = [3, 8, 13, 18, 23].contains(i)
            let landscape = [5, 15, 25].contains(i)
            let score: Double = 1.3 + Double((i * 7) % 10) / 20
            photos.append(B.ref(String(format: "S%02d", i + 1), 1, Double(i) * 3, portrait: !landscape,
                                face: faceless ? 0 : 0.02, score: score, pick: i == 10 || i == 20,
                                luma: 0.45 + Double(i % 3) / 20))
        }
        let sim = CollageStyleFineArt.Similarity(kept: photos, dropped: [], similar: [:])
        return B(photos: photos, similarity: sim, monoChapters: [])
    }

    static func checkBudgetModel(check: (Bool, String, String) -> Void) {
        print("== 目标跨页数：存盘、参数")
        var project = CollageProject()
        project.albumBudget = CollageAlbumBudget(spreads: 22, minPerSpread: 2, maxPerSpread: 5)
        if let data = try? JSONEncoder().encode(project),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let back = try? JSONDecoder().decode(CollageProject.self, from: data)
            check(back?.albumBudget == project.albumBudget, "存了再读回来一样", back?.albumBudget?.label ?? "nil")
            dict.removeValue(forKey: "albumBudget")
            let old = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
            check(old != nil && old?.albumBudget == nil, "旧工程没有这个键 = 自动", "")
            dict["albumBudget"] = "坏值"
            let bad = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
            check(bad != nil && bad?.albumBudget == nil, "坏值 = 自动（工程照常读回）", "")
            dict["albumBudget"] = ["spreads": 999, "minPerSpread": 9, "maxPerSpread": "x"]
            let clamp = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
            check(clamp?.albumBudget == CollageAlbumBudget(spreads: 200, minPerSpread: 6, maxPerSpread: 6),
                  "超范围的收回来、最少不超过最多", clamp?.albumBudget?.label ?? "nil")
        } else {
            check(false, "工程编码", "")
        }
        let none = CollageProject()
        let encoded = (try? JSONEncoder().encode(none)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(!encoded.contains("albumBudget"), "没指定时 collage.json 里不多这个键", "")
        let parsed = ["20", "20@2-5", "0", "20@5-2", "x", "20@1-13"].map { CollageCLI.parseBudget($0)?.label ?? "-" }
        check(parsed == [CollageAlbumBudget(spreads: 20).label, CollageAlbumBudget(spreads: 20, minPerSpread: 2, maxPerSpread: 5).label,
                         "-", "-", "-", "-"],
              "命令行 spreads:20 / 20@2-5 认得，写错的不认", parsed.joined(separator: " | "))
        // 每一段都要整段是数（--target-spreads 20@1-6 再加 --per-spread 2-4 拼出来的 20@1-6@2-4 以前被认成 1–4）。
        let strict = ["20@1-6@2-4", "20@a1-2-6", "20@1-2-6", "20@", "20@1-", "20@-6", "@20", "20@1-6x"]
            .map { CollageCLI.parseBudget($0)?.label ?? "-" }
        check(strict.allSatisfy { $0 == "-" }, "命令行每跨页张数写错（两个 @、夹字母、空段、多一个 -）不认、不猜",
              strict.joined(separator: " | "))
        // 三种结果：沿用 / 改回自动 / 换成几个跨页；写错 = 「错」。
        func outcome(_ kit: CollageKitID, _ n: Int?, _ lo: Int?, _ hi: Int?) -> String {
            switch CollageBudgetChange.parse(kit: kit, spreads: n, min: lo, max: hi) {
            case .failure: return "错"
            case .success(.keep): return "沿用"
            case .success(.set(nil)): return "自动"
            case .success(.set(let b?)): return "\(b.spreads)@\(b.minPerSpread)-\(b.maxPerSpread)"
            }
        }
        let mcp: [Bool] = [
            outcome(.weddingAlbum, nil, nil, nil) == "沿用",
            outcome(.weddingAlbum, 0, nil, nil) == "自动",
            outcome(.weddingAlbum, 18, 2, 3) == "18@2-3",
            outcome(.weddingAlbum, 18, nil, nil) == "18@1-6",
            outcome(.fashionIssue, 18, nil, nil) == "错",
            outcome(.weddingAlbum, nil, 2, nil) == "错",
            outcome(.weddingAlbum, 18, 4, 3) == "错",
            outcome(.weddingAlbum, 0, 1, nil) == "错",
            // 只给最少、比默认的最多 6 大：最多跟着抬（不报没给的那个 6）；两个都给了照样查。
            outcome(.weddingAlbum, 18, 8, nil) == "18@8-8",
            outcome(.weddingAlbum, 18, 6, nil) == "18@6-6",
            outcome(.weddingAlbum, 18, 8, 7) == "错",
            // 整本婚礼相册是 fine-art：每跨页固定 1–3 张，最多给 1、2 回参数不对（以前照收、报 2，编出来照样有 3 张的）。
            outcome(.weddingAlbum, 18, nil, 2) == "错",
            outcome(.weddingAlbum, 18, 1, 1) == "错",
            outcome(.weddingAlbum, 18, nil, 3) == "18@1-3",
        ]
        check(mcp.allSatisfy { $0 }, "MCP 成套的 spreads：不给沿用、0 改回自动、只对整本婚礼相册、写错回参数不对",
              mcp.map { $0 ? "✓" : "✗" }.joined())
        // 成套结果里的 album：多了带 over_target，正好 / 没设目标不带。
        var five = CollageProject()
        five.albumTheme = .fineArt
        five.pages = (0..<5).map { _ in CollagePage(root: .leaf(CollageCell())) }
        five.albumBudget = CollageAlbumBudget(spreads: 2)
        let overReport = CollageBudgetChange.report(five)
        five.albumBudget = CollageAlbumBudget(spreads: 5)
        let exact = CollageBudgetChange.report(five)
        five.albumBudget = nil
        let unset = CollageBudgetChange.report(five)
        let overOK: Bool = overReport.body["over_target"] as? Int == 3 && overReport.warning?["code"] as? String == "over_target"
        let exactOK: Bool = exact.body["over_target"] as? Int == 0 && exact.warning == nil
        let noneOK: Bool = unset.body["target"] is NSNull && unset.warning == nil
        check(overOK && exactOK && noneOK, "成套结果的 album：多 3 个带 over_target，正好不带，没设目标 target 是 null", "")
    }

    // MARK: - F19 客户选中

    /// 相似去重豁免客户选中，走生产的 distinctMoments（合成照片没有 Vision 特征：注入画面距离）：
    /// K1、K2 几乎一样，K2、K4 几乎一样，K1–K4 有点像但不到连拍，K3 和谁都远（中位数 = 远的那个）。
    /// 不豁免：K2 和 K1 是连拍 → 拿掉；K4 只和 K1 有点像 → 留。豁免 K2：K2 留下、也算「已经留下的」→ K4 和它是连拍、拿掉。
    /// 默认编排（CollageAlbum.plan dedupe）、fine-art（不给相似关系 = 生产那条路）、plan(theme: .fineArt) 各走一遍。
    static func checkDistinctKeeping(check: (Bool, String, String) -> Void) {
        print("== 相似去重豁免客户选中（注入画面距离，走 distinctMoments）")
        typealias B = CollageStyleFineArtSelfTest.Book
        let base = [B.ref("K1", 1, 0, score: 2.0), B.ref("K2", 1, 1, score: 1.5), B.ref("K3", 1, 2, score: 1.8),
                    B.ref("K4", 1, 3, score: 1.4)]
        let near: [Set<String>: Double] = [["K1", "K2"]: 0.1, ["K2", "K4"]: 0.1, ["K1", "K4"]: 0.6]
        CollageSelect.distanceOverride = { a, b in near[[a.id, b.id]] ?? 1.0 }
        defer { CollageSelect.distanceOverride = nil }
        var picked = base
        for i in picked.indices where picked[i].id == "K2" { picked[i].clientPick = true }

        func ids(_ list: [CollagePhotoRef]) -> String { list.map(\.id).sorted().joined(separator: ",") }
        let plain = CollageSelect.distinctMoments(base)
        let kept = CollageSelect.distinctMoments(base, keeping: ["K2"])
        check(ids(plain.dropped) == "K2" && ids(kept.dropped) == "K4",
              "distinctMoments：不豁免拿掉 K2（和 K1 连拍）；豁免 K2 留下它、它也算留下的（和它连拍的 K4 拿掉）",
              "不豁免拿掉 \(ids(plain.dropped)) · 豁免拿掉 \(ids(kept.dropped))")
        let routes: [(String, ([CollagePhotoRef]) -> CollageAlbum.Plan)] = [
            ("默认编排", { CollageAlbum.plan($0, dedupe: true) }),
            ("默认编排 + 目标跨页数", { CollageAlbum.plan($0, dedupe: true, budget: CollageAlbumBudget(spreads: 3)) }),
            ("fine-art", { CollageStyleFineArt.plan($0, dedupe: true, chapterMono: true) }),
            ("plan(theme: .fineArt)", { CollageAlbum.plan($0, dedupe: true, theme: .fineArt) }),
        ]
        for (name, run) in routes {
            let without = run(base)
            let with = run(picked)
            let placed = Set(with.spreads.flatMap(\.photos).map(\.id))
            check(ids(without.dropped) == "K2" && placed.contains("K2") && ids(with.dropped) == "K4",
                  "\(name)：相似去重拿掉 K2；客户选中了 K2 就留着（和它连拍的 K4 拿掉）",
                  "没选拿掉 \(ids(without.dropped)) · 选了拿掉 \(ids(with.dropped))\(placed.contains("K2") ? "" : "，K2 没上")")
        }
    }

    static func checkClientPicks(book: CollageStyleFineArtSelfTest.Book, check: (Bool, String, String) -> Void) {
        print("== 客户选中无条件保留（fine-art）")
        // A05：场 1 有精选 A04 → 平时拿掉；A09：连拍组 5 的第二张 → 平时拿掉；E05：废片 → 平时不要；
        // C10：和 C09 同姿势，给定的相似去重拿掉它（模拟「相似只留一张」）。
        let chosen: Set<String> = ["A05", "A09", "E05", "C10"]
        var photos = book.photos
        for i in photos.indices where chosen.contains(photos[i].id) { photos[i].clientPick = true }
        // 相似关系用没标客户选中的那份算（和真的一样：去重的结果不带客户选中的标记，客户选中看要编的这批照片）。
        var sim = book.similarity
        sim.kept = book.photos.filter { $0.id != "C10" }
        sim.dropped = book.photos.filter { $0.id == "C10" }

        let before = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: sim)
        let placedBefore = Set(before.spreads.flatMap(\.photos).map(\.id))
        check(placedBefore.isDisjoint(with: chosen), "对照：没有客户选中时这四张都不上（场里有精选 / 连拍第二张 / 废片 / 相似）",
              chosen.intersection(placedBefore).sorted().joined(separator: " "))
        let rejectIDs = Set(book.photos.filter { $0.verdict == .reject }.map(\.id))
        let accountedBefore = placedBefore.union(before.dropped.map(\.id)).union(rejectIDs)
        check(before.dropped.contains { $0.id == "C10" } && accountedBefore == Set(book.photos.map(\.id)),
              "对照：相似拿掉的 C10 在「拿掉的」里（每张要么上了、要么拿掉、要么是废片）", "")

        let plan = CollageStyleFineArt.plan(photos, dedupe: true, chapterMono: true, similarity: sim)
        let placed = plan.spreads.flatMap(\.photos).map(\.id)
        let placedSet = Set(placed)
        let droppedIDs = Set(plan.dropped.map(\.id))
        check(chosen.isSubset(of: placedSet), "客户选中的四张都上了（废片、场里第二张、连拍第二张、相似的）",
              chosen.subtracting(placedSet).sorted().joined(separator: " "))
        check(droppedIDs.isDisjoint(with: chosen), "拿掉的里没有客户选中的",
              droppedIDs.intersection(chosen).sorted().joined(separator: " "))
        check(placed.count == placedSet.count, "客户选中的不会上两次", "\(placed.count) / \(placedSet.count)")
        // 连拍组 5 里客户选了 A09：组里别的（精选 A08、A10）拿掉 —— 同一瞬间客户已经挑了，不放两张几乎一样的。
        check(droppedIDs.contains("A08") && droppedIDs.contains("A10") && !placedSet.contains("A08"),
              "连拍组里客户选了一张：组里别的拿掉（同一瞬间只上客户挑的那张）",
              ["A08", "A10"].map { "\($0) \(droppedIDs.contains($0) ? "拿掉" : "上了")" }.joined(separator: " "))
        // 废片：只有客户选中的那张上，另一张废片 E11 照样不要。
        check(!placedSet.contains("E11"), "没被客户选中的废片照样不上", "")
        let n = CollageStyleFineArt.droppedCounts(photos, plan: plan)
        check(n.moments + n.similar == plan.dropped.count, "拿掉的分两种说，加起来对得上",
              "同一场 \(n.moments) + 相似 \(n.similar) = \(plan.dropped.count)")
        check(CollageAlbum.clientPickNote(photos, plan: plan) == "客户选中的 4 张都上了", "编排提示写明客户选中的都上了",
              CollageAlbum.clientPickNote(photos, plan: plan) ?? "nil")
        check(CollageAlbum.clientPickNote(book.photos, plan: before) == nil, "没有客户选中：提示不多说一句", "")
        // 一键成套「整本婚礼相册」走的那道筛：客户选中的废片留着，别的废片不要。
        let pool = Set(CollageStyleFineArt.candidates(photos).map(\.id))
        check(pool.contains("E05") && !pool.contains("E11"), "成套的候选：客户选中的废片在、别的废片不在", "")
        let again = CollageStyleFineArt.plan(photos, dedupe: true, chapterMono: true, similarity: sim)
        check(CollageStyleFineArtSelfTest.signature(plan) == CollageStyleFineArtSelfTest.signature(again),
              "有客户选中时同一输入两次编排一样", "")

        print("== 客户选中存盘")
        var ref = CollagePhotoRef(id: "X1", path: "/nonexistent/x1.jpg", width: 3, height: 2)
        ref.clientPick = true
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(ref),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let back = try? JSONDecoder().decode(CollagePhotoRef.self, from: data)
            check(back?.clientPick == true, "存了再读回来还是客户选中", "")
            dict.removeValue(forKey: "clientPick")
            let old = (try? JSONSerialization.data(withJSONObject: dict))
                .flatMap { try? JSONDecoder().decode(CollagePhotoRef.self, from: $0) }
            check(old?.clientPick == false && old?.id == "X1", "旧工程没有这个键 = 不是客户选中（照片照常读回）", "")
            dict["clientPick"] = "坏值"
            let bad = (try? JSONSerialization.data(withJSONObject: dict))
                .flatMap { try? JSONDecoder().decode(CollagePhotoRef.self, from: $0) }
            check(bad?.clientPick == false && bad?.id == "X1", "坏值 = 不是（照片照常读回）", "")
        } else {
            check(false, "照片引用编码", "")
        }
    }
}
