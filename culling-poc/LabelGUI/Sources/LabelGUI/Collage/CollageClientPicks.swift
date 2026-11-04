import Foundation

/// 客户选中 → 拼图（F19）：托盘「带照片 › 客户选中 (N)」、批量页「进托盘 (N)」把客户点名要的照片带进来；
/// 相册编排（默认 / 婚礼 fine-art）无条件保留客户选中的 —— 废片、同一场只留精选、近似重复只留一张、
/// 「相似只留一张」都不拿掉它（CollagePhotoRef.clientPick，attach / 切回拼图时按批量页刷新）。
extension CollageAlbum {

    /// 这一批里客户选中的 id（编排传给 CollageSelect.distinctMoments 的 keeping）。
    static func clientPickIDs(_ photos: [CollagePhotoRef]) -> Set<String> {
        Set(photos.lazy.filter(\.clientPick).map(\.id))
    }

    /// 编排完的提示里那半句：托盘里客户选中的上了几张（规则是全上）。托盘里没有客户选中的 = nil。
    static func clientPickNote(_ photos: [CollagePhotoRef], plan: Plan) -> String? {
        let picks = clientPickIDs(photos)
        guard !picks.isEmpty else { return nil }
        let placed = Set(plan.spreads.flatMap(\.photos).map(\.id))
        let on = picks.filter(placed.contains).count
        return on == picks.count ? "客户选中的 \(picks.count) 张都上了" : "客户选中的上了 \(on)/\(picks.count) 张"
    }
}

extension CollageCLI {
    enum Expectation {
        case pass(String)
        case fail(String)
        /// 不认识的断言（写错了）
        case unknown
    }

    /// ops「expect:…」：编排结果的断言（门禁里一行「断言失败」就算失败）。
    /// - clientplaced：托盘里客户选中的每一张都上了某个跨页，「拿掉」里没有一张客户选中的。
    /// - trayisclient：托盘不空、全是客户选中的（清空托盘再「带照片 › 客户选中」之后）。
    /// - alltray：托盘里每一张都上了某个跨页（不删片）。spreads=N / spreads<=N / perspread=1-6：见 budgetExpect。
    @MainActor
    static func albumExpect(_ store: CollageStore, _ what: String) -> Expectation {
        switch what {
        case "clientplaced":
            let picks = store.project.photos.filter(\.clientPick).map(\.id)
            guard !picks.isEmpty else { return .fail("托盘里没有客户选中的照片（先 clientpicks: / importclient）") }
            let used = store.project.usedPhotoIDs
            let off = picks.filter { !used.contains($0) }
            let dropped = store.albumDropped.filter(\.clientPick).map(\.id)
            if off.isEmpty && dropped.isEmpty { return .pass("\(picks.count) 张都上了") }
            return .fail("没上 [" + off.joined(separator: " ") + "] · 拿掉里有 [" + dropped.joined(separator: " ") + "]")
        case "trayisclient":
            // 「带照片 › 客户选中」之后（先清空托盘）：托盘里全是客户选中的。
            let tray = store.project.photos
            let others = tray.filter { !$0.clientPick }.map(\.id)
            if !tray.isEmpty && others.isEmpty { return .pass("托盘 \(tray.count) 张全是客户选中的") }
            return .fail("托盘 \(tray.count) 张，不是客户选中的 [" + others.joined(separator: " ") + "]")
        case "alltray":
            // 不删片：托盘里的每一张都上了某个跨页（arrange:all = 关掉「相似只留一张」之后）。
            let used = store.project.usedPhotoIDs
            let off = store.project.photos.map(\.id).filter { !used.contains($0) }
            if off.isEmpty { return .pass("托盘 \(store.project.photos.count) 张都上了") }
            return .fail("没上 [" + off.joined(separator: " ") + "]")
        default:
            return budgetExpect(store, what)
        }
    }

    /// ops「albumdump」：相册编排的结果（每个跨页几张、客户选中的上了第几个跨页、拿掉了几张），按它断言、不看图。
    @MainActor
    static func albumDump(_ store: CollageStore) -> String {
        let pages = store.project.pages
        let tray = store.project.photos
        let used = store.project.usedPhotoIDs
        var firstPage: [String: Int] = [:]
        for (i, page) in pages.enumerated() {
            for id in page.photoIDs where firstPage[id] == nil { firstPage[id] = i + 1 }
        }
        let counts = pages.map { String($0.photoIDs.count) }.joined(separator: " ")
        let placed = tray.filter { used.contains($0.id) }.count
        let dropped = store.albumDropped.map(\.id)
        let droppedText = dropped.isEmpty ? "" : "（" + dropped.joined(separator: " ") + "）"
        var lines = ["  相册 \(pages.count) 个跨页 · 每跨页 \(counts) · 托盘 \(tray.count) 张 · 上了 \(placed) 张 · 拿掉 \(dropped.count) 张"
                     + droppedText]
        let picks = tray.filter(\.clientPick)
        if !picks.isEmpty {
            let on = picks.filter { used.contains($0.id) }
            let off = picks.filter { !used.contains($0.id) }
            let onText = on.map { "\($0.id)@\(firstPage[$0.id] ?? 0)" }.joined(separator: " ")
            let offText = off.isEmpty ? "" : " · 没上 " + off.map(\.id).joined(separator: " ")
            lines.append("  客户选中 \(picks.count) 张：上了 \(on.count) 张（\(onText)）\(offText)")
            lines.append("  拿掉的里客户选中 \(store.albumDropped.filter(\.clientPick).count) 张")
        }
        return lines.joined(separator: "\n")
    }
}
