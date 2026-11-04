import Foundation

/// --album-selftest 里相册编排的另外几条（合成数据，不跑 Vision）：
/// - F19 客户选中无条件保留：废片、同一场只留精选、连拍只留一张、给定的相似去重都不拿掉客户选中的；
///   CollagePhotoRef.clientPick 存盘 / 旧工程 / 坏值。
enum CollageAlbumPlanSelfTest {

    static func run(book: CollageStyleFineArtSelfTest.Book, check: (Bool, String, String) -> Void) {
        checkClientPicks(book: book, check: check)
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
