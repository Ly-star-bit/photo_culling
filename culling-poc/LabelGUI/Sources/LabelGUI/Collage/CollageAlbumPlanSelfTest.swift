import Foundation

/// --album-selftest 里相册编排的另外几条（合成数据，不跑 Vision）：
/// - F19 客户选中无条件保留：废片、同一场只留精选、连拍只留一张、给定的相似去重都不拿掉客户选中的；
///   CollagePhotoRef.clientPick 存盘 / 旧工程 / 坏值。
/// - F06 目标跨页数：默认编排正好塞进 N 个跨页、放不下多出来、太少就少，一张不丢、每跨页张数在区间里、
///   全书疏密差不多、章节顺序不乱；fine-art 往目标并（不丢片、每跨页最多 3 张）；存盘、命令行参数。
enum CollageAlbumPlanSelfTest {

    static func run(book: CollageStyleFineArtSelfTest.Book, check: (Bool, String, String) -> Void) {
        checkClientPicks(book: book, check: check)
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
        }
        let tight = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: book.similarity,
                                             budget: CollageAlbumBudget(spreads: 8))
        check(tight.spreads.count > 8, "fine-art 压到 8 个放不下（每跨页最多 3 张）：多出来、不删片", "\(tight.spreads.count) 个")
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

    static func checkClientPicks(book: CollageStyleFineArtSelfTest.Book, check: (Bool, String, String) -> Void) {
        print("== 客户选中无条件保留（fine-art）")
        // A05：场 1 有精选 A04 → 平时拿掉；A09：连拍组 5 的第二张 → 平时拿掉；E05：废片 → 平时不要；
        // C10：和 C09 同姿势，给定的相似去重拿掉它（模拟「相似只留一张」）。
        let chosen: Set<String> = ["A05", "A09", "E05", "C10"]
        var photos = book.photos
        for i in photos.indices where chosen.contains(photos[i].id) { photos[i].clientPick = true }
        var sim = book.similarity
        sim.kept = photos.filter { $0.id != "C10" }
        sim.dropped = photos.filter { $0.id == "C10" }

        let before = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: sim)
        let placedBefore = Set(before.spreads.flatMap(\.photos).map(\.id))
        check(placedBefore.isDisjoint(with: chosen), "对照：没有客户选中时这四张都不上（场里有精选 / 连拍第二张 / 废片 / 相似）",
              chosen.intersection(placedBefore).sorted().joined(separator: " "))

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
