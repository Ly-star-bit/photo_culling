import Foundation

/// --collage-ops 里相册跨页操作的 op（相册 A + B · S；CollageCLI 的 switch 里一行转发到 apply）。跨页号、页号都从 0 起
/// （同 page:N、delpage:N），路径同别的 op（"01" = 根的第一个孩子的第二个孩子，r = 根）：
///   movecells:00;01>5      当前跨页这几格的照片挪到第 5 个跨页（S1，两页都重排，一步撤销）
///   addto:5=DSCF7209;DSCF7211  托盘里这几张放进第 5 个跨页（S1，遵守 F5）
///   movepages:3;4>0        第 3、4 个跨页挪到第 0 个前面（S2，同 SwiftUI onMove）
///   delpages:2;3           删掉第 2、3 个跨页（S2）
///   mirror[:N]             第 N 个跨页左右镜像（S3；不给 = 当前跨页）
///   side:left+1 | side:right-1   只换左页 / 右页的版式，往后 / 往前轮一种（S4）
///   lockpage[:N;M] / unlockpage[:N;M]   锁住 / 解锁跨页（S5；不给 = 当前跨页）。设计稿写的是 lock:N / unlock:N，可 lock:<路径>
///                          早就是「切换这一格的锁」（lock:00），改不得，换了名字
///   cands:DSCF7212[@5]     打印换这张照片的候选（S6，最多几个，默认 12）
///   replace:00=DSCF7213    这一格换成那张（S6；那张在别的跨页上 = 两格对调）
///   arrangeplan            打印「自动编排」前要问的那句话（F6；不用问 = 「不用问」）
///   spreaddump             每个跨页：锁没锁、左页 | 右页的照片和拍摄时间、先后对不对（F4）
///   dedupebench:300        相册去重的耗时（F7）：用托盘照片轮着凑 N 张（特征缓存键各不相同），先算画面特征、再去重
/// 编排结果的断言另有几条（expect:unique / order / locked=N / noemptyslots / on=ID@N / here=ID / notice~字，见 editExpect）。
@MainActor
enum CollageAlbumEditCLI {

    static let names: Set<String> = ["movecells", "addto", "movepages", "delpages", "mirror", "side", "lockpage",
                                     "unlockpage", "cands", "replace", "arrangeplan", "spreaddump", "dedupebench"]

    /// 参数不对 = false（ops 打「参数不对，跳过」）。wait = 等后台排版落下来（ops 的 idle）。
    static func apply(_ name: String, _ arg: String, store: CollageStore, wait: () -> Void) -> Bool {
        func path(_ s: String) -> [Int] { s == "r" ? [] : s.compactMap { $0.wholeNumberValue } }
        func pair(_ s: String, _ sep: Character) -> (String, String)? {
            let kv = s.split(separator: sep, maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }
        func indices(_ s: String) -> IndexSet? {
            if s.isEmpty { return IndexSet(integer: store.pageIndex) }
            let n = s.split(separator: ";").map { Int($0) }
            guard !n.isEmpty, n.allSatisfy({ $0 != nil }) else { return nil }
            return IndexSet(n.compactMap { $0 })
        }
        switch name {
        case "movecells":
            guard let (cells, rest) = pair(arg, ">"), let target = Int(rest) else { return false }
            store.moveCells(cells.split(separator: ";").map { path(String($0)) }, toPage: target)
            wait()
            print("  " + (store.notice ?? ""))
        case "addto":
            guard let (page, list) = pair(arg, "="), let target = Int(page) else { return false }
            store.addPhotos(list.split(separator: ";").map(String.init), toPage: target)
            wait()
            print("  " + (store.notice ?? ""))
        case "movepages":
            guard let (list, rest) = pair(arg, ">"), let from = indices(list), let to = Int(rest) else { return false }
            store.movePages(from, to: to)
        case "delpages":
            guard !arg.isEmpty, let gone = indices(arg) else { return false }
            store.deletePages(gone)
        case "mirror":
            guard arg.isEmpty || Int(arg) != nil else { return false }
            store.mirrorPage(Int(arg) ?? store.pageIndex)
        case "side":
            let side: CollageSpreadSide
            if arg.hasPrefix("left") { side = .left } else if arg.hasPrefix("right") { side = .right } else { return false }
            let rest = arg.dropFirst(side == .left ? 4 : 5)
            guard let step = rest.isEmpty ? 1 : Int(rest) else { return false }
            store.cycleSideLayout(side, step: step)
            wait()
            print("  " + (store.notice ?? ""))
        case "lockpage", "unlockpage":
            guard let set = indices(arg) else { return false }
            store.setPagesLocked(set, name == "lockpage")
        case "cands":
            let parts = arg.split(separator: "@", maxSplits: 1).map(String.init)
            guard let id = parts.first, !id.isEmpty else { return false }
            let limit = parts.count > 1 ? Int(parts[1]) : 12
            guard let limit else { return false }
            let list = store.replacementCandidates(forPhoto: id, limit: limit)
            print("  换 \(id) 的候选 \(list.count) 张" + (list.isEmpty ? "（没有同连拍、同场、相似的）" : "："))
            for c in list {
                let used = c.page.map { "第\($0 + 1)个跨页" } ?? "没用"
                let tags = (c.reject ? " [废片]" : "") + (c.clientPick ? " [客户选中]" : "")
                print(String(format: "    %@ %@ 分数 %.2f %@%@", c.photoID, c.reason.label, c.score, used, tags))
            }
        case "replace":
            guard let (p, id) = pair(arg, "=") else { return false }
            store.replacePhoto(at: path(p), with: id)
            if let n = store.notice { print("  " + n) }
        case "arrangeplan":
            print("  自动编排前：" + (store.arrangeConfirmation ?? "不用问"))
        case "spreaddump":
            print(spreadDump(store))
        case "dedupebench":
            guard let n = Int(arg), n > 0 else { return false }
            dedupeBench(store, count: n)
        default:
            return false
        }
        return true
    }

    // MARK: - 打印

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func stamp(_ p: CollagePhotoRef) -> String {
        guard let t = p.captureTime else { return "无时间" }
        let sub = p.captureSubsec.map { String(format: "%.2f", $0).dropFirst() } ?? ""
        return clock.string(from: t) + sub
    }

    /// 一个跨页左页、右页的照片（各按阅读顺序）；找不到中缝那一刀 = nil（整版一张、散落版、印样）。
    static func sides(_ page: CollagePage) -> (left: [String], right: [String])? {
        guard !page.freeform, page.contactSheet == nil, let fold = CollageLayout.foldPath(page.root),
              let node = page.root.node(at: fold), !node.isLeaf else { return nil }
        return (node.children[0].photoIDs, node.children[1].photoIDs)
    }

    /// 这一页照片的阅读顺序（左页再右页）是不是按拍摄先后（F4）。
    static func inShotOrder(_ page: CollagePage, photos: [String: CollagePhotoRef]) -> Bool {
        guard let s = sides(page) else { return true }
        let list = (s.left + s.right).compactMap { photos[$0] }
        return zip(list, list.dropFirst()).allSatisfy { !CollageAlbum.shotEarlier($1, $0) }
    }

    static func spreadDump(_ store: CollageStore) -> String {
        let map = store.photoMap
        var lines: [String] = []
        for (i, page) in store.project.pages.enumerated() {
            func names(_ ids: [String]) -> String {
                ids.map { id in map[id].map { "\(id.suffix(4))(\(stamp($0)))" } ?? String(id.suffix(4)) }.joined(separator: " ")
            }
            let lock = page.locked ? " [锁]" : ""
            let here = i == store.pageIndex ? " *" : ""
            if let s = sides(page) {
                let order = inShotOrder(page, photos: map) ? "先后对" : "先后乱"
                lines.append("  跨页 \(i)\(here)\(lock) 左: \(names(s.left)) | 右: \(names(s.right)) · \(order)")
            } else {
                lines.append("  跨页 \(i)\(here)\(lock) 整版: \(names(page.photoIDs))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// F7：相册去重 N 张要多久。托盘照片按顺序轮着凑 N 张（缓存键各不相同，画面特征一张张现算；解的是同一批文件，解码有缓存，
    /// 所以「每张」比真的 N 张略少）：打印 N 张算特征、去重各多久。同一个 N 再跑一次 = 特征都在缓存里（平时编排时的样子）。
    private static func dedupeBench(_ store: CollageStore, count n: Int) {
        let tray = store.project.photos
        guard !tray.isEmpty else {
            print("  托盘是空的")
            return
        }
        var refs: [CollagePhotoRef] = []
        for k in 0..<n {
            var p = tray[k % tray.count]
            p.id = "bench\(k)-" + p.id
            // 画面特征按「路径 + 尺寸」缓存：宽度差 k 个像素就是另一张（解的还是同一个文件，解码有缓存）。
            p.width += k + 1
            // 分数错开一点：去重按分数从高到低过。
            p.score -= Double(k) * 1e-6
            refs.append(p)
        }
        let t0 = Date()
        let printed = refs.filter { CollageVision.featurePrint($0) != nil }.count
        let tPrint = Date().timeIntervalSince(t0)
        let t1 = Date()
        let r = CollageSelect.distinctMoments(refs)
        let tDedupe = Date().timeIntervalSince(t1)
        let pairs = min(n, CollageSelect.dedupeLimit) * (min(n, CollageSelect.dedupeLimit) - 1) / 2
        print(String(format: "  去重 %d 张：画面特征 %.2fs（%d 张算得出，每张 %.1f ms，平时在路人信息的后台任务里算）· "
                     + "去重 %.3fs（%d 对距离）· 留 %d 拿掉 %d",
                     n, tPrint, printed, tPrint * 1000 / Double(max(1, n)), tDedupe, pairs, r.kept.count, r.dropped.count))
    }
}

extension CollageCLI {
    /// 跨页操作的断言（budgetExpect 认不出的落到这里）：
    /// - unique：没有一张照片在两个跨页上（格子、图层、印样帧都算）；
    /// - order：每个能找到中缝的跨页，照片的阅读顺序（左页再右页）按拍摄先后（F4）；
    /// - locked=N：锁住了 N 个跨页；noemptyslots：导出前不会问空照片格（F2）；nofoldcross：没有照片横跨中缝（F1）；
    /// - on=ID@N：这张在第 N 个跨页上（从 0 起）；here=ID：这张在当前跨页上；
    /// - notice~字：状态栏提示里有这几个字。
    @MainActor
    static func editExpect(_ store: CollageStore, _ what: String) -> Expectation {
        let pages = store.project.pages
        switch what {
        case "unique":
            var seen: [String: Int] = [:]
            var twice: [String] = []
            for (i, p) in pages.enumerated() {
                for id in Set(p.photoIDs) {
                    if let first = seen[id] { twice.append("\(id)@\(first),\(i)") } else { seen[id] = i }
                }
            }
            return twice.isEmpty ? .pass("\(seen.count) 张各在一个跨页上") : .fail("在两个跨页上：" + twice.joined(separator: " "))
        case "order":
            let map = store.photoMap
            let bad = pages.indices.filter { !CollageAlbumEditCLI.inShotOrder(pages[$0], photos: map) }
            return bad.isEmpty ? .pass("\(pages.count) 个跨页都是左早右晚")
                : .fail("先后乱的跨页：" + bad.map(String.init).joined(separator: " "))
        case "nofoldcross":
            let pages = store.crossFoldPages()
            return pages.isEmpty ? .pass("没有照片压中缝") : .fail("压中缝的跨页：" + pages.map(String.init).joined(separator: " "))
        case "noemptyslots":
            let slots = CollageStore.emptyPhotoSlots(project: store.project)
            return slots.isEmpty ? .pass("没有空照片格")
                : .fail(slots.map { "跨页\($0.page):\($0.path.map(String.init).joined())" }.joined(separator: " "))
        default:
            break
        }
        if what.hasPrefix("locked="), let n = Int(what.dropFirst("locked=".count)) {
            let locked = pages.indices.filter { pages[$0].locked }
            let shown = locked.map(String.init).joined(separator: " ")
            return locked.count == n ? .pass("锁住 \(shown)") : .fail("锁住了 \(locked.count) 个（\(shown)），不是 \(n)")
        }
        if what.hasPrefix("on=") {
            let parts = what.dropFirst(3).split(separator: "@").map(String.init)
            guard parts.count == 2, let n = Int(parts[1]) else { return .unknown }
            let id = parts[0]
            let at = pages.indices.filter { pages[$0].photoIDs.contains(id) }
            return at == [n] ? .pass("\(id) 在第 \(n) 个跨页") : .fail("\(id) 在 \(at)，不是 [\(n)]")
        }
        if what.hasPrefix("here=") {
            let id = String(what.dropFirst(5))
            let here = store.page?.photoIDs.contains(id) == true
            return here ? .pass("当前跨页 \(store.pageIndex) 上有 \(id)") : .fail("当前跨页 \(store.pageIndex) 上没有 \(id)")
        }
        if what.hasPrefix("notice~") {
            let want = String(what.dropFirst("notice~".count))
            let notice = store.notice ?? ""
            return notice.contains(want) ? .pass(notice) : .fail("提示是「\(notice)」")
        }
        return .unknown
    }
}
