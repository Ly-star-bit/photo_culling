import Foundation
import CoreGraphics

/// --album-selftest 里相册跨页操作的几条（相册 A + B · S；合成数据，不要照片、不跑 Vision）：
/// F1 / F2 单张跨页、F3 切页、F4 跨页里的先后、F5 同一张不上两个跨页、F6 编排前那句话、F7 去重上限、
/// S1 照片挪跨页、S2 挪 / 删跨页、S3 镜像两次还原、S4 只换一边的版式、S5 锁住的跨页编排时原样留着、S6 换照片候选的排序；
/// 挪照片 / 加照片 / 「拼图 (N)」当场落下、后台精排（审查 R1#2 / R1#4 / R1#10，checkSyncLanding）。
/// 有照片的（真出图）在门禁 collage_gate.sh 的 ops_album_edit。
enum CollageAlbumEditSelfTest {

    /// 断言：check(通过没有, 名字[, 细节])。
    struct Check {
        let body: (Bool, String, String) -> Void

        func callAsFunction(_ ok: Bool, _ name: String, _ detail: String = "") { body(ok, name, detail) }
    }

    typealias Book = CollageStyleFineArtSelfTest.Book

    @MainActor
    static func run(check report: (Bool, String, String) -> Void) {
        withoutActuallyEscaping(report) { body in
            let check = Check(body: body)
            checkShotOrder(check: check)
            checkSingleSpread(check: check)
            checkSpreadOrder(check: check)
            checkChunks(check: check)
            checkMovedIndices(check: check)
            checkMirror(check: check)
            checkMergeLocked(check: check)
            checkCandidates(check: check)
            checkDedupeLimit(check: check)
            checkSides(check: check)
            checkLockedModel(check: check)
            checkStore(check: check)
            checkSyncLanding(check: check)
        }
    }

    /// 合成照片：第几分钟拍的（再加小数秒）、竖不竖、场、连拍组、分数。
    static func photo(_ id: String, _ minute: Double, subsec: Double? = nil, portrait: Bool = true, take: Int? = nil,
                      burst: Int? = nil, score: Double = 1.5, verdict: CollageVerdict = .usable,
                      client: Bool = false, timeless: Bool = false) -> CollagePhotoRef {
        var p = Book.ref(id, 1, minute, portrait: portrait, face: 0, score: score, take: take, burst: burst,
                         verdict: verdict)
        p.captureSubsec = subsec
        p.clientPick = client
        if timeless { p.captureTime = nil }
        return p
    }

    static let album30 = CollageCanvas.albums[0]

    static func context(_ canvas: CollageCanvas, _ photos: [CollagePhotoRef]) -> CollageLayout.Context {
        var map: [String: CollagePhotoRef] = [:]
        for p in photos { map[p.id] = p }
        return CollageLayout.Context(canvas: canvas, style: CollageStyle(), photos: map, hints: [:], heroID: nil)
    }

    // MARK: - F4

    static func checkShotOrder(check: Check) {
        print("== 跨页里的先后（F4）")
        let a = photo("DSCF998", 1, subsec: 0.9)
        let b = photo("DSCF1000", 1, subsec: 0.2)
        let c = photo("DSCF0999", 1)
        let d = photo("X2", 0, timeless: true)
        let e = photo("X10", 0, timeless: true)
        let order = CollageAlbum.shotOrder([e, d, a, b, c]).map(\.id)
        // 同一秒：c（没有小数秒 = .0）、b（.2）、a（.9）；没有时间的排后面，文件名按数值比（X2 在 X10 前面）。
        check(order == ["DSCF0999", "DSCF1000", "DSCF998", "X2", "X10"], "按拍摄时间 + 小数秒，没时间的在后、按文件名（数值）",
              order.joined(separator: " "))
        let same = [photo("DSCF7210", 3), photo("DSCF998", 3), photo("DSCF7209", 3)]
        let byName = CollageAlbum.shotOrder(same).map(\.id)
        check(byName == ["DSCF998", "DSCF7209", "DSCF7210"], "同一刻按文件名（数字按数值）", byName.joined(separator: " "))
    }

    /// 求解器每个结果：左页、右页的阅读顺序连起来按拍摄先后（文字格不算）。
    static func ordered(_ root: CollageNode, _ map: [String: CollagePhotoRef]) -> Bool {
        guard let fold = CollageLayout.foldPath(root), let node = root.node(at: fold), !node.isLeaf else { return false }
        let list = (node.children[0].photoIDs + node.children[1].photoIDs).compactMap { map[$0] }
        return zip(list, list.dropFirst()).allSatisfy { !CollageAlbum.shotEarlier($1, $0) }
    }

    static func checkSpreadOrder(check: Check) {
        print("== 求解器排的跨页：左早右晚（F4）")
        // 拍摄先后和托盘顺序故意打乱：求解器拿到的是乱序（按分数、带进来的顺序）。
        let pool = [photo("P5", 50, portrait: false), photo("P1", 10), photo("P4", 40), photo("P2", 20, portrait: false),
                    photo("P7", 70), photo("P3", 30), photo("P6", 60, portrait: false), photo("P8", 80)]
        for canvas in [album30, glued(album30)] {
            for n in 2...8 {
                let photos = Array(pool.prefix(n))
                let ctx = context(canvas, photos)
                var all: [CollageLayout.Scored] = []
                for seed in [UInt64(3), 17] {
                    all += CollageLayout.solve(CollageLayout.Request(photos: photos, context: ctx, tries: 3000, keep: 18,
                                                                     seed: seed))
                }
                let bad = all.filter { !ordered($0.root, ctx.photos) }
                check(!all.isEmpty && bad.isEmpty,
                      "\(canvas.binding.label) \(n) 张：每一版都是左页早、右页晚，页内照阅读顺序",
                      "\(all.count) 版，乱的 \(bad.count)")
            }
        }
        // 有锁住的格子（换一批只排没锁的，solveKeepingLocks）：没锁的照片照样按先后分进各个自由区（左页的在右页的前面）。
        let five = Array(pool.prefix(5))   // P5 P1 P4 P2 P3
        var pinned = CollageCell.photo("P5")
        pinned.locked = true
        let lockRoot = CollageNode.split(.row, 0.5, .split(.column, 0.5, .leaf(pinned), .leaf(.photo("P4"))),
                                         .split(.column, 0.5, .leaf(.photo("P1")),
                                                .split(.row, 0.5, .leaf(.photo("P3")), .leaf(.photo("P2")))))
        let lockCtx = context(album30, five)
        let relocked = CollageLayout.solveKeepingLocks(current: lockRoot, context: lockCtx, tries: 2000, keep: 12, seed: 4)
        let lockOrdered = relocked.allSatisfy { r in
            let list = r.root.photoIDs.filter { $0 != "P5" }.compactMap { lockCtx.photos[$0] }
            return zip(list, list.dropFirst()).allSatisfy { !CollageAlbum.shotEarlier($1, $0) }
                && r.root.node(at: [0, 0])?.cell?.photoID == "P5"
        }
        check(!relocked.isEmpty && lockOrdered, "有锁住的格子：锁住的不动，其余照片照阅读顺序按先后", "\(relocked.count) 版")
        // 带一个文字格：文字格随机插，照片之间的先后不变。
        var title = CollageText(lines: [CollageTextLine("{title}")])
        title.alignH = .center
        let photos = Array(pool.prefix(4))
        let ctx = context(album30, photos)
        let withText = CollageLayout.solve(CollageLayout.Request(photos: photos, textCells: [.text(title)], context: ctx,
                                                                 tries: 3000, keep: 18, seed: 5))
        let textSides = Set(withText.compactMap { r -> Int? in
            guard let fold = CollageLayout.foldPath(r.root), let node = r.root.node(at: fold), !node.isLeaf else { return nil }
            return node.children[0].hasTextLeaf ? 0 : 1
        })
        check(!withText.isEmpty && withText.allSatisfy { ordered($0.root, ctx.photos) },
              "带文字格：照片照样按先后（文字格随机插在照片之间）", "\(withText.count) 版，文字在 \(textSides.sorted()) 页")
    }

    static func glued(_ canvas: CollageCanvas) -> CollageCanvas {
        var c = canvas
        c.binding = .glued
        return c
    }

    // MARK: - F1 / F2

    static func checkSingleSpread(check: Check) {
        print("== 跨页只放一张（F1 / F2）")
        let tall = photo("T1", 1)
        let wide = photo("W1", 1, portrait: false)
        var pano = CollagePhotoRef(id: "PANO", path: "/nonexistent/selftest/PANO.jpg", width: 9000, height: 4000)
        pano.captureTime = Book.day
        func one(_ p: CollagePhotoRef, _ canvas: CollageCanvas) -> CollageNode? {
            CollageLayout.solve(CollageLayout.Request(photos: [p], context: context(canvas, [p]), tries: 100, keep: 4,
                                                      seed: 1)).first?.root
        }
        func rightPage(_ root: CollageNode?) -> Bool {
            guard let r = root, !r.isLeaf, r.axis == .row, abs(r.ratio - 0.5) < 1e-9 else { return false }
            return r.children[0].cell?.kind == .empty && r.children[1].cell?.photoID != nil
        }
        let portrait = one(tall, album30)
        check(rightPage(portrait) && portrait?.children[1].cell?.contain == true,
              "平铺对裱放一张竖图：右页完整显示，左页留白格（不再整格裁成 2:1）", portrait?.signature ?? "nil")
        // 3:2 横图（1.5 ≥ 1.4）、没有脸：铺满整个跨页；全景同样。
        let landscape = one(wide, album30)
        check(landscape?.isLeaf == true && landscape?.cell?.framing == .full, "平铺对裱放一张够宽的横图、中缝没脸：铺满跨页",
              landscape?.signature ?? "nil")
        check(one(pano, album30)?.isLeaf == true, "全景同样铺满")
        // 中缝上有脸的横图：不铺满，放右页。
        var faced = wide
        faced.faces = [[0.45, 0.3, 0.55, 0.45]]
        faced.faceAreaPct = 0.015
        check(rightPage(one(faced, album30)), "横图中缝上有脸：放右页、左页留白")
        // 4:3 横图（1.33 < 1.4）：不够宽，放右页。
        var four = CollagePhotoRef(id: "F43", path: "/nonexistent/selftest/F43.jpg", width: 4000, height: 3000)
        four.captureTime = Book.day
        check(rightPage(one(four, album30)), "4:3 横图不够宽（< 1.4）：放右页")
        let gluedRoot = one(wide, glued(album30))
        check(rightPage(gluedRoot), "胶装放一张：右页，左页是留白格（F2：以前是空照片格）", gluedRoot?.signature ?? "nil")
        // 导出前的空格确认不报留白格。
        var project = CollageProject()
        project.mode = .album
        project.canvas = glued(album30)
        project.photos = [wide]
        project.pages = [CollagePage(root: gluedRoot ?? .leaf(CollageCell()))]
        check(CollageStore.emptyPhotoSlots(project: project).isEmpty, "胶装单张跨页：导出前不再问空照片格")
    }

    // MARK: - F3

    static func checkChunks(check: Check) {
        print("== 「拼图 (N)」切成几个新跨页（F3）")
        let twelve = (0..<12).map { photo("C\($0)", Double((7 * $0) % 12)) }
        let chunks = CollageAlbum.handoffChunks(twelve, cap: 5)
        let sizes = chunks.map(\.count)
        let flat = chunks.flatMap { $0 }
        let chrono = zip(flat, flat.dropFirst()).allSatisfy { !CollageAlbum.shotEarlier($1, $0) }
        check(sizes == [4, 4, 4] && chrono && Set(flat.map(\.id)) == Set(twelve.map(\.id)),
              "12 张、每跨页最多 5 张：切成 4 4 4，按拍摄先后、一张不丢", sizes.map(String.init).joined(separator: " "))
        check(CollageAlbum.handoffChunks(Array(twelve.prefix(3)), cap: 5).map(\.count) == [3], "3 张：一个跨页")
        check(CollageAlbum.handoffChunks(twelve, cap: 3).map(\.count) == [3, 3, 3, 3], "婚礼相册（3 张）：4 个跨页")
        check(CollageAlbum.handoffChunks(Array(twelve.prefix(7)), cap: 5).map(\.count) == [4, 3], "7 张：4 3（不是 5 2）")
        let budget = CollageAlbumBudget(spreads: 20, minPerSpread: 1, maxPerSpread: 4)
        check(CollageAlbum.handoffCap(theme: .classic, budget: nil) == 5
              && CollageAlbum.handoffCap(theme: .classic, budget: budget) == 4
              && CollageAlbum.handoffCap(theme: .fineArt, budget: budget) == CollageStyleFineArt.maxPerSpread,
              "每跨页最多：没设目标 5、设了用它的最多、婚礼相册 3")
    }

    // MARK: - S2

    static func checkMovedIndices(check: Check) {
        print("== 挪跨页（S2）")
        let items = ["a", "b", "c", "d", "e"]
        func m(_ i: [Int], _ to: Int) -> String { CollageAlbum.moved(items, from: IndexSet(i), to: to).joined() }
        // 同 SwiftUI onMove：destination 是挪之前的下标、挪到它前面。
        check(m([3, 4], 0) == "deabc", "3、4 挪到最前", m([3, 4], 0))
        check(m([0], 5) == "bcdea", "第 0 个挪到最后", m([0], 5))
        check(m([1, 3], 3) == "acbde", "1、3 挪到 3 前面（保持先后）", m([1, 3], 3))
        check(m([2], 2) == "abcde" && m([2], 3) == "abcde", "挪到自己前后 = 不动")
        check(m([1], 3) == "acbde" && m([3], 1) == "adbce", "往后一格 / 往前两格", m([1], 3) + " " + m([3], 1))
        check(m([9], 0) == "abcde", "越界的下标不管")
    }

    // MARK: - S3

    /// 两棵树逐节点相等（ratio 容差 1e-12：1 − (1 − r) 和 r 可能差最后一位）。
    static func same(_ a: CollageNode, _ b: CollageNode) -> Bool {
        guard a.isLeaf == b.isLeaf, a.cell == b.cell else { return false }
        if a.isLeaf { return true }
        return a.axis == b.axis && abs(a.ratio - b.ratio) < 1e-12 && same(a.children[0], b.children[0])
            && same(a.children[1], b.children[1])
    }

    static func checkMirror(check: Check) {
        print("== 镜像（S3）")
        var title = CollageCell.text(CollageText(lines: [CollageTextLine("标题")], alignH: .leading))
        title.text?.alignH = .leading
        var p1 = CollageCell.photo("M1")
        p1.crop = CollageCropOverride(cx: 0.3, cy: 0.4, zoom: 1.5)
        let right = CollageNode.split(.column, 0.37, .leaf(.photo("M2")),
                                      .split(.row, 0.1, .leaf(.photo("M3")), .leaf(.photo("M4"))))
        let root = CollageNode.split(.row, 0.5, .split(.column, 0.3, .leaf(title), .leaf(p1)), right)
        var page = CollagePage(root: root)
        var tape = CollageItem(kind: .sticker)
        tape.cx = 0.13
        tape.rotation = 7.3
        var photoItem = CollageItem(kind: .photo)
        photoItem.photoID = "M9"
        photoItem.cx = 0.7
        photoItem.rotation = -4
        tape.attach = CollageAttachment(to: photoItem.id, x: 0.31, y: -0.4, angle: 11.3)
        page.items = [photoItem, tape]
        let once = CollageAlbum.mirrored(page)
        let twice = CollageAlbum.mirrored(once)
        // 一次：左右页对调；左页那一列 = 原来右页那一列翻过来（横排切分的两个孩子对调、ratio 取补）。
        let swapped = once.root.children[0].node(at: [1])?.children.map { $0.cell?.photoID ?? "" } == ["M4", "M3"]
            && abs((once.root.children[0].node(at: [1])?.ratio ?? 0) - 0.9) < 1e-12
            && once.root.children[1].children[0].cell?.kind == .text
        check(swapped, "镜像一次：左右页对调，横排切分里的两格也对调、比例取补；文字格跟着走", once.root.signature)
        let textAlign = once.root.children[1].children[0].cell?.text?.alignH
        let crop = once.root.children[1].children[1].cell?.crop
        check(textAlign == .leading && crop == p1.crop, "字的左右对齐、裁切取景不变")
        check(same(twice.root, page.root), "镜像两次：切分树逐节点回到原样（ratio 差不到 1e-12）")
        let itemsBack = zip(twice.items, page.items).allSatisfy { a, b in
            abs(a.cx - b.cx) < 1e-12 && a.rotation == b.rotation && a.attach == b.attach && a.cy == b.cy
        }
        check(itemsBack && once.items[0].cx == 1 - 0.7 && once.items[0].rotation == 4
              && once.items[1].attach?.x == -0.31 && once.items[1].attach?.angle == -11.3,
              "图层 x → 1 − x、角度取反，贴着的胶带在相纸上也翻；两次还原")
        // 像素：两次镜像的几何和原来一模一样；一次镜像左页的格子 = 原来右页的格子翻过来（±1 像素）。
        let style = CollageStyle()
        let g0 = CollageLayout.pageGeometry(page.root, canvas: album30, style: style).frames
        let g2 = CollageLayout.pageGeometry(twice.root, canvas: album30, style: style).frames
        check(g0.map(\.rect) == g2.map(\.rect), "镜像两次：每一格的像素框一样")
        let g1 = CollageLayout.pageGeometry(once.root, canvas: album30, style: style).frames
        let w = album30.width
        let mirroredOK = g0.allSatisfy { f in
            guard let id = f.cell.photoID ?? f.cell.text?.lines.first?.text,
                  let m = g1.first(where: { ($0.cell.photoID ?? $0.cell.text?.lines.first?.text) == id }) else { return false }
            return abs(m.rect.x0 - (w - f.rect.x1)) <= 1 && abs(m.rect.x1 - (w - f.rect.x0)) <= 1 && m.rect.y0 == f.rect.y0
                && m.rect.y1 == f.rect.y1
        }
        check(mirroredOK, "镜像一次：每一格的位置左右翻过来（±1 像素）")
        // 散落页记着的网格也翻。
        var free = page
        free.freeform = true
        free.gridRoot = root
        check(CollageAlbum.mirrored(free).gridRoot.map { same(CollageAlbum.mirrored($0), root) } == true,
              "散落页记着的网格一起翻")
    }

    // MARK: - S5

    static func checkMergeLocked(check: Check) {
        print("== 锁住的跨页合回去（S5）")
        let photos = (0..<12).map { photo("L\($0)", Double($0) * 10) }
        var map: [String: CollagePhotoRef] = [:]
        for p in photos { map[p.id] = p }
        func page(_ ids: [Int], tag: String = "") -> CollagePage {
            var root = CollageNode.leaf(.photo("L\(ids[0])"))
            for i in ids.dropFirst() { root = .split(.row, 0.5, root, .leaf(.photo("L\(i)"))) }
            if !tag.isEmpty { root = .split(.column, 0.2, .leaf(.text(CollageText(lines: [CollageTextLine(tag)]))), root) }
            return CollagePage(root: root)
        }
        // 重排出来的：扉页（L11，分数最高）、L0-1、L2-3、L6-7、L8-9（L4 L5 在锁住的那页上）。
        let fresh = [page([11]), page([0, 1]), page([2, 3]), page([6, 7]), page([8, 9])]
        func ids(_ pages: [CollagePage]) -> String { pages.map { $0.photoIDs.joined(separator: "+") }.joined(separator: " | ") }
        var lockedMid = page([4, 5])
        lockedMid.locked = true
        let merged = CollageAlbum.mergeLocked(fresh, locked: [(index: 3, page: lockedMid)], photos: map)
        check(ids(merged) == "L11 | L0+L1 | L2+L3 | L4+L5 | L6+L7 | L8+L9", "锁住的按最早一张的时间插回去（扉页不算）", ids(merged))
        let lockedFirst = CollageAlbum.mergeLocked(fresh, locked: [(index: 0, page: lockedMid)], photos: map)
        check(ids(lockedFirst).hasPrefix("L4+L5 | L11"), "原来是第一个的锁住页还在最前面", ids(lockedFirst))
        var late = page([10])
        late.locked = true
        var textOnly = CollagePage(root: .leaf(.text(CollageText(lines: [CollageTextLine("后记")]))))
        textOnly.locked = true
        let tail = CollageAlbum.mergeLocked(fresh, locked: [(index: 1, page: lockedMid), (index: 2, page: textOnly),
                                                            (index: 6, page: late)], photos: map)
        let tailIDs = tail.map { $0.photoIDs.isEmpty ? "字" : $0.photoIDs.joined(separator: "+") }.joined(separator: " | ")
        check(tailIDs == "L11 | L0+L1 | L2+L3 | L4+L5 | 字 | L6+L7 | L8+L9 | L10",
              "几个锁住页：保持原来的先后；没照片的放回原下标之后；比谁都晚的接在最后", tailIDs)
        check(CollageAlbum.mergeLocked([], locked: [(index: 2, page: lockedMid), (index: 5, page: late)], photos: map)
                .map(\.photoIDs) == [["L4", "L5"], ["L10"]], "没有别的照片可编：只剩锁住的，原来的先后")
        let b = CollageAlbumBudget(spreads: 20, minPerSpread: 1, maxPerSpread: 6)
        check(CollageAlbum.budget(b, excludingLocked: 3)?.spreads == 17 && CollageAlbum.budget(b, excludingLocked: 30)?.spreads == 1
              && CollageAlbum.budget(nil, excludingLocked: 3) == nil && CollageAlbum.budget(b, excludingLocked: 0) == b,
              "目标跨页数减掉锁住的（至少 1 个）")
    }

    // MARK: - S6

    static func checkCandidates(check: Check) {
        print("== 换照片的候选（S6）")
        let target = photo("T", 10, take: 3, burst: 30, score: 2)
        let tray = [
            target,
            photo("BURST_LOW", 10.01, take: 3, burst: 30, score: 1.2),
            photo("BURST_HIGH", 10.02, take: 3, burst: 30, score: 2.5),
            photo("TAKE", 11, take: 3, burst: 31, score: 3.0),
            photo("SIM", 40, take: 7, burst: 70, score: 2.8),
            photo("USED_BURST", 10.03, take: 3, burst: 30, score: 2.9),
            photo("REJECT_BURST", 10.04, take: 3, burst: 30, score: 0.5, verdict: .reject),
            photo("CLIENT_TAKE", 12, take: 3, burst: 32, score: 1.0, client: true),
            photo("OTHER", 90, take: 9, burst: 90, score: 3.5),
        ]
        let list = CollageAlbum.replacementCandidates(for: target, tray: tray, pageOf: ["USED_BURST": 4, "T": 2],
                                                      limit: 12) { $0.id == "SIM" }
        let order = list.map(\.photoID)
        check(order == ["BURST_HIGH", "BURST_LOW", "TAKE", "CLIENT_TAKE", "SIM", "USED_BURST", "REJECT_BURST"],
              "没用过的在前；同连拍 > 同场 > 相似，同类按分数；废片最后；不相关的不列", order.joined(separator: " "))
        check(list.first { $0.photoID == "USED_BURST" }?.page == 4 && list.first { $0.photoID == "CLIENT_TAKE" }?.clientPick == true
              && list.first { $0.photoID == "REJECT_BURST" }?.reject == true && list.first { $0.photoID == "SIM" }?.reason == .similar,
              "带上用在第几个跨页、客户选中、废片、理由")
        check(CollageAlbum.replacementCandidates(for: target, tray: tray, pageOf: [:], limit: 2) { _ in false }.count == 2,
              "最多 limit 个")
        // 外部文件（没有场、连拍组）：只认相似。
        var external = photo("EXT", 10)
        external.take = nil
        external.burstGroup = nil
        let ext = CollageAlbum.replacementCandidates(for: external, tray: tray + [external], pageOf: [:], limit: 12) { _ in false }
        check(ext.isEmpty, "没有场、连拍组的照片：不按 nil 相等凑候选")
    }

    // MARK: - F7

    /// 改之前的去重（只比分数前 120 张、按 "id|id" 存距离），对照用。
    static func legacyDistinctMoments(_ photos: [CollagePhotoRef], measure: (CollagePhotoRef, CollagePhotoRef) -> Double?)
        -> (kept: [CollagePhotoRef], dropped: [CollagePhotoRef], similar: [String: Set<String>]) {
        let sorted = photos.sorted { $0.score > $1.score }
        let head = Array(sorted.prefix(120))
        var dist: [String: Double] = [:]
        var all: [Double] = []
        for i in 0..<head.count {
            for j in (i + 1)..<head.count {
                if let d = measure(head[i], head[j]) {
                    dist[head[i].id + "|" + head[j].id] = d
                    dist[head[j].id + "|" + head[i].id] = d
                    all.append(d)
                }
            }
        }
        guard !all.isEmpty else { return (photos, [], [:]) }
        all.sort()
        let median = all[all.count / 2]
        var similar: [String: Set<String>] = [:]
        for (key, d) in dist where d < 0.76 * median {
            let parts = key.split(separator: "|").map(String.init)
            similar[parts[0], default: []].insert(parts[1])
        }
        var kept: [CollagePhotoRef] = []
        var dropped: [CollagePhotoRef] = []
        for p in sorted {
            let distances = kept.compactMap { dist[p.id + "|" + $0.id] }
            let nearest = distances.min() ?? .infinity
            let samePose = distances.filter { $0 < 0.76 * median }.count
            if nearest < 0.54 * median || (!p.isPick && samePose >= 2) { dropped.append(p) } else { kept.append(p) }
        }
        return (kept, dropped, similar)
    }

    static func checkDedupeLimit(check: Check) {
        print("== 相册去重的上限（F7）")
        // 合成的画面距离：同一组（id 里的组号）很近，同姿势那几组中等，其余远；按 id 定，和调用先后无关。
        func group(_ p: CollagePhotoRef) -> Int { Int(p.id.split(separator: "-")[1]) ?? 0 }
        func measure(_ a: CollagePhotoRef, _ b: CollagePhotoRef) -> Double? {
            let ga = group(a), gb = group(b)
            if ga == gb { return 0.2 }
            if ga / 4 == gb / 4 { return 0.38 }
            let h = (a.id + b.id).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return 0.6 + Double(h % 100) / 400
        }
        func book(_ n: Int) -> [CollagePhotoRef] {
            (0..<n).map { i in photo("D\(i)-\(i / 3)", Double(i), score: 3 - Double(i) * 0.01, verdict: i % 5 == 0 ? .pick : .usable) }
        }
        CollageSelect.distanceOverride = measure
        defer { CollageSelect.distanceOverride = nil }
        for n in [40, 120] {
            let photos = book(n)
            let new = CollageSelect.distinctMoments(photos)
            let old = legacyDistinctMoments(photos, measure: measure)
            check(new.kept.map(\.id) == old.kept.map(\.id) && new.dropped.map(\.id) == old.dropped.map(\.id)
                  && new.similar == old.similar,
                  "\(n) 张（≤ 120）：去重结果和改之前一字不差", "留 \(new.kept.count) 拿掉 \(new.dropped.count)")
        }
        let big = book(300)
        let new = CollageSelect.distinctMoments(big)
        let old = legacyDistinctMoments(big, measure: measure)
        let lateDropped = new.dropped.filter { p in big.firstIndex(where: { $0.id == p.id }).map { $0 >= 120 } ?? false }
        let oldLate = old.dropped.filter { p in big.firstIndex(where: { $0.id == p.id }).map { $0 >= 120 } ?? false }
        check(!lateDropped.isEmpty && oldLate.isEmpty && new.similar[big[200].id] != nil,
              "300 张：分数第 120 名以后的照样去重、判同姿势（以前一张都不管）",
              "第 121 名以后拿掉 \(lateDropped.count) 张（以前 \(oldLate.count)）")
    }

    // MARK: - S4

    static func checkSides(check: Check) {
        print("== 左页、右页分开换版式（S4）")
        let photos = [photo("S1", 1), photo("S2", 2, portrait: false), photo("S3", 3), photo("S4", 4),
                      photo("S5", 5, portrait: false)]
        let ctx = context(album30, photos)
        let right = CollageNode.split(.column, 0.5, .split(.row, 0.5, .leaf(.photo("S3")), .leaf(.photo("S4"))),
                                      .leaf(.photo("S5")))
        let left = CollageNode.split(.row, 0.4, .leaf(.photo("S1")), .leaf(.photo("S2")))
        let root = CollageNode.split(.row, 0.5, left, right)
        guard case .options(let options) = CollageLayout.sideAlternatives(root, side: .right, context: ctx, seed: 9) else {
            check(false, "右页三张：算得出几种切法", "")
            return
        }
        let sigs = options.map { $0.children[1].signature }
        check(options.count >= 3 && Set(sigs).count == sigs.count && options[0] == root,
              "右页三张：几种结构各不相同的切法，第 0 种是原来的", "\(options.count) 种：" + sigs.joined(separator: " "))
        check(options.allSatisfy { $0.children[0] == left && Set($0.children[1].photoIDs) == ["S3", "S4", "S5"] && abs($0.ratio - 0.5) < 1e-12 },
              "只动右页：左页原样、照片不变、中缝那一刀不动")
        check(options.allSatisfy { ordered($0, ctx.photos) }, "右页照阅读顺序按拍摄先后")
        if case .single = CollageLayout.sideAlternatives(root, side: .left, context: context(album30, photos), seed: 9) {
            check(false, "左页两张：有切法", "")
        } else {
            check(true, "左页两张：有切法", "")
        }
        let soloRoot = CollageNode.split(.row, 0.5, .leaf(CollageCell(kind: .empty)), .leaf(.photo("S1")))
        if case .single = CollageLayout.sideAlternatives(soloRoot, side: .right, context: ctx, seed: 9) {
            check(true, "只有一张：说「这一页只有一张」", "")
        } else {
            check(false, "只有一张：说「这一页只有一张」", "")
        }
        // 上下有横条（标题带）的跨页：中缝那一刀在横条旁边那棵子树（foldPath）。
        let banded = CollageNode.split(.column, 0.15, .leaf(.text(CollageText(lines: [CollageTextLine("标题")]))), root)
        if case .options(let list) = CollageLayout.sideAlternatives(banded, side: .right, context: ctx, seed: 9) {
            check(list.count >= 3 && list.allSatisfy { $0.children[0] == banded.children[0] && $0.children[1].children[0] == left },
                  "上面有标题横条：照样找得到中缝，只动右页", "\(list.count) 种")
        } else {
            check(false, "上面有标题横条：照样找得到中缝", "")
        }
        var lockedRoot = root
        lockedRoot.update(at: [1, 1]) { $0.cell?.locked = true }
        if case .locked = CollageLayout.sideAlternatives(lockedRoot, side: .right, context: ctx, seed: 9) {
            check(true, "这一边有锁住的格子：不换", "")
        } else {
            check(false, "这一边有锁住的格子：不换", "")
        }
    }

    // MARK: - S5 存盘

    static func checkLockedModel(check: Check) {
        var page = CollagePage(root: .leaf(.photo("a")))
        page.locked = true
        guard let data = try? JSONEncoder().encode(page),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            check(false, "跨页的锁存盘", "")
            return
        }
        let back = try? JSONDecoder().decode(CollagePage.self, from: data)
        dict.removeValue(forKey: "locked")
        let old = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { try? JSONDecoder().decode(CollagePage.self, from: $0) }
        dict["locked"] = "坏值"
        let bad = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { try? JSONDecoder().decode(CollagePage.self, from: $0) }
        check(back?.locked == true && old?.locked == false && bad?.locked == false && old?.root == page.root,
              "跨页的锁：存了读回来一样；旧工程没有这个键、坏值 = 没锁（页照常读回）")
    }

    // MARK: - store（一步撤销、页跟着走、锁住编排、挪照片、换照片、F5、F6）

    @MainActor
    static func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    static func checkStore(check: Check) {
        print("== 跨页操作（store：一步撤销、锁住编排、挪照片）")
        let store = CollageStore(dataDir: appDataDir)
        let photos = (0..<10).map { photo("E\($0)", Double($0) * 5, portrait: $0 % 3 != 0, score: 3 - Double($0) * 0.1) }
        func spread(_ a: String, _ b: String) -> CollagePage {
            CollagePage(root: .split(.row, 0.5, .leaf(.photo(a)), .leaf(.photo(b))))
        }
        var project = CollageProject()
        project.mode = .album
        project.canvas = album30
        project.photos = photos
        project.pages = [spread("E0", "E1"), spread("E2", "E3"), spread("E4", "E5"), spread("E6", "E7"), spread("E8", "E9")]
        store.loadForTesting(project)
        func pageIDs() -> [String] { store.project.pages.map { $0.photoIDs.joined(separator: "+") } }

        // F6：有跨页、有照片 → 要问；锁住几个说几个。
        check(store.arrangeConfirmation == "重排会替换没锁的 5 个跨页；⌘Z 能撤回", "F6：编排前那句话",
              store.arrangeConfirmation ?? "nil")

        // S2：挪、删，pageIndex 跟着当前页走，一步撤销。
        store.pageIndex = 2
        let depth = store.undoDepth
        store.movePages(IndexSet([3, 4]), to: 0)
        check(pageIDs() == ["E6+E7", "E8+E9", "E0+E1", "E2+E3", "E4+E5"] && store.pageIndex == 4 && store.undoDepth == depth + 1,
              "S2 挪两个跨页到最前：当前页跟着走（第 2 个 → 第 4 个），一步撤销", pageIDs().joined(separator: " ") + " 当前 \(store.pageIndex)")
        store.undo()
        check(pageIDs() == ["E0+E1", "E2+E3", "E4+E5", "E6+E7", "E8+E9"], "撤销一次全回去")
        store.pageIndex = 2
        store.deletePages(IndexSet([1, 2]))
        check(pageIDs() == ["E0+E1", "E6+E7", "E8+E9"] && store.pageIndex == 1 && store.undoDepth == depth + 1,
              "S2 删两个（含当前页）：停在删掉那一段后面那一页，一步撤销", pageIDs().joined(separator: " ") + " 当前 \(store.pageIndex)")
        store.undo()
        store.pageIndex = 3
        store.movePage(3, by: -1)
        check(pageIDs()[2] == "E6+E7" && store.pageIndex == 2, "往前挪一格（movePage 调 movePages）：画面跟着那一页")
        store.undo()

        // S5：锁住第 2 个（E4+E5），自动编排：它原样留着、上面的照片不重排。
        store.setPagesLocked(IndexSet(integer: 2), true)
        let lockedPage = store.project.pages[2]
        check(store.arrangeConfirmation == "重排会替换没锁的 4 个跨页（锁住的 1 个不动）；⌘Z 能撤回", "F6：说锁住的几个",
              store.arrangeConfirmation ?? "nil")
        store.autoArrangeAlbum(dedupe: false)
        spin(60) { !store.isSolving && store.busyText == nil }
        let after = store.project.pages
        let kept = after.filter { $0.id == lockedPage.id }
        let elsewhere = after.filter { $0.id != lockedPage.id }.flatMap(\.photoIDs)
        let all = after.flatMap(\.photoIDs)
        check(kept.count == 1 && kept[0] == lockedPage && !elsewhere.contains("E4") && !elsewhere.contains("E5")
              && Set(all) == Set(photos.map(\.id)) && all.count == photos.count,
              "S5 锁住的跨页编排时原样留着，上面的照片不参与编排、别的照片一张不丢",
              after.map { ($0.locked ? "🔒" : "") + $0.photoIDs.joined(separator: "+") }.joined(separator: " | "))
        // 锁住页按它最早一张的时间（E4 = 第 20 分钟）插：前面的跨页（扉页除外）都比它早开始。
        let lockedAt = after.firstIndex { $0.id == lockedPage.id } ?? -1
        let map = store.photoMap
        func start(_ p: CollagePage) -> CollagePhotoRef? { p.photoIDs.compactMap { map[$0] }.min(by: CollageAlbum.shotEarlier) }
        let before = after.indices.filter { $0 > 0 && $0 < lockedAt }.allSatisfy { i in
            start(after[i]).map { CollageAlbum.shotEarlier($0, map["E4"]!) } ?? true
        }
        let behind = after.indices.filter { $0 > lockedAt }.allSatisfy { i in
            start(after[i]).map { !CollageAlbum.shotEarlier($0, map["E4"]!) } ?? true
        }
        check(lockedAt > 0 && before && behind, "锁住页按最早一张的拍摄时间插在中间", "第 \(lockedAt) 个")
        store.undo()

        // S1：第 0 个跨页的 E0 挪到第 3 个跨页，一步撤销；两页都还在、没有一张丢或重复。
        store.loadForTesting(project)
        store.pageIndex = 0
        let d0 = store.undoDepth
        store.moveCells([[0]], toPage: 3)
        spin(60) { !store.isSolving && !store.isRefining && store.busyText == nil }
        let moved = store.project.pages
        check(!moved[0].photoIDs.contains("E0") && moved[3].photoIDs.contains("E0") && Set(moved[3].photoIDs) == ["E0", "E6", "E7"]
              && moved[0].photoIDs == ["E1"] && store.undoDepth == d0 + 1,
              "S1 照片挪到第 3 个跨页：两页都重排，一步撤销", moved.map { $0.photoIDs.joined(separator: "+") }.joined(separator: " | "))
        // 原页剩一张：放右页、左页留白（F1 那一支）。
        let rest = moved[0].root
        check(!rest.isLeaf && rest.children[0].cell?.kind == .empty, "原页只剩一张：左页留白、照片放一页（不整格铺满）",
              rest.signature)
        store.undo()
        check(store.project.pages == project.pages, "撤销一次两页都回去")

        // S1 addPhotos + F5：托盘里已经在第 1 个跨页上的照片不放进第 4 个。
        var extra = project
        extra.photos.append(photo("EX", 100))
        store.loadForTesting(extra)
        store.addPhotos(["E2", "EX"], toPage: 4)
        spin(60) { !store.isSolving && !store.isRefining && store.busyText == nil }
        check(Set(store.project.pages[4].photoIDs) == ["E8", "E9", "EX"] && store.project.pages[1].photoIDs.contains("E2")
              && (store.notice ?? "").contains("第 2 个跨页上了"),
              "S1 托盘照片放进第 4 个跨页；E2 在第 1 个跨页上：不放、说一句（F5）", store.notice ?? "")

        // F5：拖托盘 / place 一张在别的跨页上的照片：不放。
        store.loadForTesting(extra)
        store.pageIndex = 4
        let before5 = store.project
        store.place(photoID: "E0", at: [0], edge: nil)
        check(store.project == before5 && (store.notice ?? "").hasPrefix("这张在第 1 个跨页上了"), "F5 place 别的跨页上的照片：不放",
              store.notice ?? "")
        store.relayout(photoIDs: (store.page?.photoIDs ?? []) + ["E0"])
        spin(10) { !store.isSolving }
        check(store.project == before5, "F5「加进现在的版式」：别的跨页上的那张不加，什么都不变")

        // F1：全空的跨页里放一张竖图 → 按这张求解（右页、左页留白），不整格铺满。
        store.addPage()
        let blank = store.pageIndex
        store.place(photoID: "EX", at: [], edge: nil)
        spin(30) { !store.isSolving }
        let placed = store.project.pages[blank].root
        check(!placed.isLeaf && placed.children[0].cell?.kind == .empty && placed.children[1].cell?.photoID == "EX",
              "F1 往全空的跨页放一张竖图：右页完整显示、左页留白", placed.signature)

        // S6 replacePhoto：换成别的跨页上的那张 = 两格对调。
        store.loadForTesting(project)
        store.pageIndex = 0
        store.replacePhoto(at: [0], with: "E6")
        check(store.project.pages[0].root.children[0].cell?.photoID == "E6"
              && store.project.pages[3].root.children[0].cell?.photoID == "E0" && store.undoDepth == 1,
              "S6 换成第 3 个跨页上的那张：两格对调，一步撤销", store.notice ?? "")

        // S3 镜像：一步撤销，两次还原。
        store.loadForTesting(project)
        store.mirrorPage(1)
        check(store.project.pages[1].photoIDs == ["E3", "E2"], "S3 镜像：左右对调")
        store.mirrorPage(1)
        check(store.project.pages[1].root.children.map { $0.cell?.photoID } == ["E2", "E3"] && store.undoDepth == 2,
              "S3 再镜像一次：回到原样（每次一步撤销）")
    }

    // MARK: - 当场落下、后台精排（审查 R1#2 / R1#4 / R1#10）

    /// 挪照片、加照片、「拼图 (N)」以前整个放在后台排，和「换一批」共用一个作废号：被用户接着的一下作废就悄悄没了。
    /// 现在当场落下、后台精排各有各的号（CollageStore.refinePages）。连着加两个跨页、加完马上编辑当前页、F3 之后马上往
    /// 新跨页拖一张，是审查里复现「操作悄悄丢掉」的几种做法。
    @MainActor
    static func checkSyncLanding(check: Check) {
        print("== 挪照片 / 加照片 / 「拼图 (N)」当场落下、后台精排（R1#2 / R1#4 / R1#10）")
        let store = CollageStore(dataDir: appDataDir)
        var photos = (0..<10).map { photo("E\($0)", Double($0) * 5, portrait: $0 % 3 != 0, score: 3 - Double($0) * 0.1) }
        photos += ["EX", "EY", "EZ"].enumerated().map { photo($0.element, 60 + Double($0.offset), portrait: $0.offset != 1) }
        photos += (0..<7).map { photo("F\($0)", 100 + Double($0) * 3, portrait: $0 % 2 == 0) }
        func spread(_ a: String, _ b: String) -> CollagePage {
            CollagePage(root: .split(.row, 0.5, .leaf(.photo(a)), .leaf(.photo(b))))
        }
        var project = CollageProject()
        project.mode = .album
        project.canvas = album30
        project.photos = photos
        project.pages = [spread("E0", "E1"), spread("E2", "E3"), spread("E4", "E5"), spread("E6", "E7"), spread("E8", "E9")]
        func idle() { spin(60) { !store.isSolving && !store.isRefining } }
        func on(_ id: String) -> [Int] { store.project.pages.indices.filter { store.project.pages[$0].photoIDs.contains(id) } }
        func sig(_ i: Int) -> String { store.project.pages.indices.contains(i) ? store.project.pages[i].root.signature : "-" }

        // 精排 = 以前的后台求解（同一个 Request、种子、次数）：新 store 第一次求解的种子是 8（solveSeed 从 7 起，加一）。
        store.loadForTesting(project)
        store.addPhotos(["EX"], toPage: 4)
        let synced = store.project.pages[4].root
        check(Set(synced.photoIDs) == ["E8", "E9", "EX"] && store.isRefining && store.undoDepth == 1 && !store.isSolving,
              "加照片当场落下（一步撤销），后台还在精排，不占「正在排」", synced.signature)
        let ctx = store.spreadContext
        let want = CollageLayout.solve(CollageLayout.Request(photos: ["E8", "E9", "EX"].compactMap { ctx.photos[$0] },
                                                             context: ctx, tries: 16000, keep: 1, seed: 8)).first?.root
        idle()
        check(want != nil && store.project.pages[4].root == want && want != synced && store.undoDepth == 1,
              "精排落下来 = 以前后台求解的那一版（同一个种子、16000 次），不另记撤销", sig(4))
        store.undo()
        check(store.project.pages == project.pages, "撤销一次回到加之前")

        // 两次连着加到不同跨页：都落下（以前第二次把第一次作废了）。
        store.loadForTesting(project)
        store.addPhotos(["EX"], toPage: 3)
        store.addPhotos(["EY"], toPage: 1)
        idle()
        check(on("EX") == [3] && on("EY") == [1] && store.undoDepth == 2, "连着加到两个跨页：两次都落下、各一步撤销",
              "EX \(on("EX")) EY \(on("EY"))")

        // 加到别的跨页以后马上编辑当前页（对调两格）：加的照片照样在，对调也在。
        store.loadForTesting(project)
        store.pageIndex = 0
        store.addPhotos(["EX"], toPage: 2)
        store.swap([0], [1])
        idle()
        check(on("EX") == [2] && store.project.pages[0].photoIDs == ["E1", "E0"],
              "加到别的跨页后马上在当前页对调两格：照片照样在第 2 个跨页上", "EX \(on("EX")) · " + sig(0))

        // 精排落下之前就被清掉（自检换工程 = 换场次）：落不到新工程上，也不让人一直等。
        store.loadForTesting(project)
        store.addPhotos(["EX"], toPage: 4)
        store.loadForTesting(project)
        check(!store.isRefining, "换工程以后不再等上一份的精排")
        spin(1) { false }
        check(store.project.pages == project.pages, "上一份的精排回来也不落到新工程上")

        // R1#4：精排落下之前镜像了那一页 → 镜像留着（那一页被用户动过，精排跳过）。
        store.loadForTesting(project)
        store.addPhotos(["EX"], toPage: 4)
        let landed4 = store.project.pages[4]
        store.mirrorPages(IndexSet(integer: 4))
        idle()
        check(store.project.pages[4].root == CollageAlbum.mirrored(landed4).root,
              "精排落下之前镜像了那一页：镜像留着，精排不盖", sig(4))

        // 挪照片 + 精排落下之前又做了一步（镜像第 1 个跨页）：精排落下；撤销一次只退镜像（精排的版留着），再撤销一次回到挪之前。
        store.loadForTesting(project)
        store.pageIndex = 0
        store.moveCells([[0]], toPage: 3)
        let src = store.project.pages[0].root
        let dst = store.project.pages[3].root
        check(on("E0") == [3] && src.children.first?.cell?.kind == .empty && store.isRefining,
              "挪照片当场落下：源页只剩一张 = 放右页、左页留白（单张那一支，不用等精排）", src.signature + " · " + dst.signature)
        store.mirrorPages(IndexSet(integer: 1))
        idle()
        let refined = store.project.pages[3].root
        check(store.project.pages[0].root == src && Set(refined.photoIDs) == ["E0", "E6", "E7"] && store.undoDepth == 2,
              "精排落下（目标页）、源页就是同步那一版", refined.signature)
        store.undo()
        check(store.project.pages[1] == project.pages[1] && store.project.pages[3].root == refined,
              "撤销一次只退镜像：精排的版留着（补进了镜像之前那一步的快照）", sig(3))
        store.undo()
        check(store.project.pages == project.pages, "再撤销一次回到挪之前（操作之前那一步的快照没被精排碰）")
        store.redo()
        check(store.project.pages[3].root == refined, "重做：回来的是精排的版", sig(3))

        // F3：「拼图 (7)」以后马上往第一个新跨页拖一张：两个新跨页都有照片，「放了 7 张」说的时候照片已经在上面。
        store.loadForTesting(project)
        store.pageIndex = 4
        let seven = (0..<7).map { "F\($0)" }
        store.layoutRequestedForTesting(seven)
        let fresh = Array(store.project.pages.dropFirst(5))
        check((store.notice ?? "").contains("放了 7 张") && fresh.count == 2 && fresh.allSatisfy { !$0.photoIDs.isEmpty }
              && Set(fresh.flatMap(\.photoIDs)) == Set(seven) && store.pageIndex == 5 && store.undoDepth == 1,
              "F3 提示出来的时候照片已经在新跨页上（一步撤销）",
              (store.notice ?? "") + " · " + fresh.map { $0.photoIDs.joined(separator: "+") }.joined(separator: " | "))
        store.addPhotos(["EZ"], toPage: 5)
        idle()
        let after = Array(store.project.pages.dropFirst(5))
        check(after.count == 2 && after.allSatisfy { $0.photoIDs.count >= 3 } && Set(after.flatMap(\.photoIDs)) == Set(seven + ["EZ"])
              && on("EZ") == [5] && store.undoDepth == 2,
              "F3 之后马上往第一个新跨页拖一张：另一个新跨页照样排好（以前一直空着）",
              after.map { $0.photoIDs.joined(separator: "+") }.joined(separator: " | "))
        store.undo()
        store.undo()
        check(store.project.pages == project.pages, "撤销两次：新跨页都没了")

        // R1#10 + side_layout 的结局：第一次后台算、落下来记一步；换一批在算的时候走缓存再轮一下，换一批作废、刚切的留着。
        var three = project
        three.pages[0] = CollagePage(root: .split(.row, 0.5, .leaf(.photo("E0")),
                                                  .split(.column, 0.5, .leaf(.photo("E1")), .leaf(.photo("E2")))))
        three.pages[1] = spread("E3", "E4")
        store.loadForTesting(three)
        var got: CollageStore.SideCycleOutcome?
        let gen = store.cycleSideLayout(.right, step: 1) { got = $0 }
        idle()
        var landedPushes = -1
        if case .landed(let pushes, _, _) = got { landedPushes = pushes }
        let cycled = store.project.pages[0].root
        check(gen != nil && landedPushes == store.undoPushes && store.undoDepth == 1 && cycled != three.pages[0].root,
              "右页换一种切法：后台算完落下来，结局回调带落地那一刻的撤销计数", cycled.signature)
        store.regenerate()
        check(store.isSolving, "点了「换一批」，正在算")
        got = nil
        let cached = store.cycleSideLayout(.right, step: 1) { got = $0 }
        let second = store.project.pages[0].root
        var cachedLanded = false
        if case .landed = got { cachedLanded = true }
        check(cached == nil && cachedLanded && !store.isSolving && second != cycled,
              "走缓存再轮一下：当场落下、还在算的「换一批」作废（R1#10）", second.signature)
        idle()
        check(store.project.pages[0].root == second, "「换一批」不会落下来盖掉刚切的", sig(0))

        // side_layout 等的是自己这一票：后台在算时用户点了「换一批」= 代号变了、结局是作废；截止时撤回自己这一票。
        store.loadForTesting(three)
        got = nil
        let mine = store.cycleSideLayout(.right, step: 1) { got = $0 }
        store.regenerate()
        check(mine != nil && store.currentSolveGeneration != mine, "算的时候用户点了「换一批」：求解代号变了（桥立刻回 superseded）")
        idle()
        spin(30) { got != nil }
        var superseded = false
        if case .superseded = got { superseded = true }
        check(superseded, "结局回调：作废")
        store.loadForTesting(three)
        got = nil
        let late = store.cycleSideLayout(.right, step: 1) { got = $0 }
        let before = store.project
        check(late.map { store.cancelSolve(generation: $0) } == true && !store.isSolving, "截止时撤回自己这一票")
        // 撤回以后不算「正在排」了，idle 当场就过：等后台那一次真算完、回调来了再看
        spin(30) { got != nil }
        superseded = false
        if case .superseded = got { superseded = true }
        check(superseded && store.project == before && store.undoDepth == 0, "撤回的那一票不会过后又落下来")
    }
}
