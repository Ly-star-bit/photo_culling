import Foundation
import AppKit
import SwiftUI

/// --album-selftest 里相册界面（相册 A + B 第 2 波 · U）的几条，合成数据、不要照片、不开界面：
/// - 编辑封面时哪些入口不能用（CollageAlbumRules.allows 的整张表）；
/// - ⌘← ⌘→ 换跨页到头、封面排在第一个跨页前面；按键判断（输入框里打字不接、只认单按 ⌘、G 不带修饰键）；Q / A、W / S；
/// - 整本概览的多选（单击 / ⌘ / ⇧）、按页 id 认选中（挪、删以后下标对得上）；拖动的插入位置（网格、一排）、插在封面前面算第一个；
/// - 「移到第…个跨页」的分组、填号；角标文字；
/// - store 上：封面卡不算在跨页数里、⌘← 从第一个跨页到封面再 ⌘→ 回来、点封面底下那个跨页也退出封面编辑、多选镜像一步撤销、
///   概览选中挪 / 删、跨页条上按位置认卡片（画布拖格子用）。
/// 拖放、手势、悬停、右键菜单本身离屏收不到合成鼠标事件，验不了（清单在交付报告里）。
enum CollageAlbumUISelfTest {
    typealias Check = CollageAlbumEditSelfTest.Check

    @MainActor
    static func run(check report: (Bool, String, String) -> Void) {
        withoutActuallyEscaping(report) { body in
            let check = Check(body: body)
            print("== 相册界面（第 2 波 U：概览、跨页条、换跨页、封面卡）")
            checkCoverRules(check: check)
            checkStep(check: check)
            checkKeys(check: check)
            checkSelection(check: check)
            checkInsertion(check: check)
            checkMoveMenu(check: check)
            checkStore(check: check)
        }
    }

    // MARK: - 编辑封面时哪些不能用

    static func checkCoverRules(check: Check) {
        typealias A = CollageAlbumRules.Action
        let blocked: Set<A> = [.scatter, .contactSheet, .freeItems, .darkroom, .pageLook, .moveToSpread, .replacePhoto,
                               .sideLayout, .mirror, .lockSpread, .saveTemplate]
        let got = Set(A.allCases.filter { !CollageAlbumRules.allows($0, editingCover: true) })
        check(got == blocked, "编辑封面：散落版、印样、图层、暗房、页色调、挪跨页、换一张、左右页换版式、镜像、锁、存模板都不能用",
              got.map(\.label).sorted().joined(separator: "、"))
        let open: [A] = [.selectCell, .placePhoto, .editText, .textCell, .refit, .cellLook, .crop, .regenerate]
        check(open.allSatisfy { CollageAlbumRules.allows($0, editingCover: true) },
              "编辑封面：选格子、放照片、改字、加文字格、贴合、单格色调、裁切、换一批照常")
        check(A.allCases.allSatisfy { CollageAlbumRules.allows($0, editingCover: false) }, "不在编辑封面：全都能用")
        check(Set(A.allCases.map(\.label)).count == A.allCases.count, "每一样都有名字、不重名")
    }

    // MARK: - ⌘← ⌘→

    static func checkStep(check: Check) {
        typealias T = CollageAlbumRules.Target
        func step(_ d: Int, _ cur: Int, cover: Bool = false, has: Bool = false, _ n: Int = 5) -> T? {
            CollageAlbumRules.step(d, current: cur, editingCover: cover, hasCover: has, count: n)
        }
        check(step(1, 0) == .page(1) && step(-1, 3) == .page(2), "⌘→ 下一个、⌘← 上一个")
        check(step(-1, 0) == nil && step(1, 4) == nil, "到头了不动：第一个按 ⌘←（没有封面）、最后一个按 ⌘→")
        check(step(-1, 0, has: true) == .cover, "有封面：第一个跨页按 ⌘← 到封面（封面排在第一个前面，同跨页条）")
        check(step(1, 3, cover: true, has: true) == .page(0) && step(-1, 3, cover: true, has: true) == nil,
              "编辑封面：⌘→ 到第一个跨页（不管封面底下是第几个），⌘← 不动")
        let empty: [T?] = [step(1, 0, 0), step(-1, 0, has: true, 0), step(1, 0, cover: true, has: true, 0)]
        check(empty.allSatisfy { $0 == nil }, "一个跨页都没有：⌘← ⌘→ 都不动（编辑封面时 ⌘→ 也不动）")
        check(step(0, 2) == nil, "delta 0 不动")
        // 只有一个跨页（最常见的头一回）：⌘→ 不动，有封面 ⌘← 进封面，封面 ⌘→ 回到它。
        let one: [T?] = [step(1, 0, 1), step(-1, 0, has: true, 1), step(1, 0, cover: true, has: true, 1)]
        check(one == [nil, .cover, .page(0)], "只有一个跨页：⌘→ 不动、⌘← 进封面、封面 ⌘→ 回来", "\(one)")
    }

    // MARK: - 按键

    static func checkKeys(check: Check) {
        typealias K = CollageAlbumRules.KeyAction
        func key(_ code: UInt16, _ chars: String?, _ mods: NSEvent.ModifierFlags, typing: Bool = false) -> K? {
            CollageAlbumRules.keyAction(keyCode: code, characters: chars, modifiers: mods, typing: typing)
        }
        // 方向键的事件本身带 .function、.numericPad。
        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        check(key(123, nil, arrow.union(.command)) == .step(-1) && key(124, nil, arrow.union(.command)) == .step(1),
              "⌘← ⌘→ 换跨页")
        check(key(123, nil, arrow.union(.command), typing: true) == nil && key(5, "g", [], typing: true) == nil,
              "输入框里打字时不接（⌘← 是挪到行首、g 是打字）")
        check(key(123, nil, arrow) == nil, "不带 ⌘ 的 ← 不接（画布上切备选、托盘里挪）")
        let extra: [NSEvent.ModifierFlags] = [[.command, .shift], [.command, .option], [.command, .control]]
        check(extra.allSatisfy { key(124, nil, arrow.union($0)) == nil }, "⇧⌘ ⌥⌘ ⌃⌘ 方向键不接（留给选字、系统）")
        check(key(5, "g", []) == .overview && key(5, "G", [.capsLock]) == .overview, "G 开关整本概览（大小写锁定也认）")
        let gMods: [NSEvent.ModifierFlags] = [[.command], [.shift], [.option]]
        check(gMods.allSatisfy { key(5, "g", $0) == nil }, "⌘G ⇧G ⌥G 不接")
        check(key(0, "a", []) == nil && key(46, "m", []) == nil, "别的字不接")
        // Q / A、W / S（画布上）。
        func side(_ c: String, _ m: EventModifiers) -> String {
            guard let k = CollageAlbumRules.sideKey(c, modifiers: m) else { return "-" }
            return k.side.label + (k.step > 0 ? "+" : "−")
        }
        let keys = [side("q", []), side("a", []), side("W", [.shift]), side("s", [])]
        check(keys == ["左页−", "左页+", "右页−", "右页+"], "Q / A = 左页上一种 / 下一种，W / S = 右页（大写也认）",
              keys.joined(separator: " "))
        let refused = [side("s", [.command]), side("a", [.control]), side("x", [])]
        check(refused == ["-", "-", "-"], "⌘S、⌃A、别的字母不接")
    }

    // MARK: - 概览多选

    static func checkSelection(check: Check) {
        let order = ["a", "b", "c", "d", "e"]
        var r = CollageAlbumRules.click("b", command: false, shift: false, selection: [], anchor: nil, order: order)
        check(r.selection == ["b"] && r.anchor == "b", "单击只选这一个")
        r = CollageAlbumRules.click("d", command: true, shift: false, selection: r.selection, anchor: r.anchor, order: order)
        check(r.selection == ["b", "d"] && r.anchor == "d", "⌘ 点加一个")
        r = CollageAlbumRules.click("b", command: true, shift: false, selection: r.selection, anchor: r.anchor, order: order)
        check(r.selection == ["d"] && r.anchor == "b", "⌘ 点选中的那个 = 去掉（起点换成它，同托盘）")
        r = CollageAlbumRules.click("e", command: false, shift: true, selection: r.selection, anchor: r.anchor, order: order)
        check(r.selection == ["b", "c", "d", "e"] && r.anchor == "b", "⇧ 点从上次点的那个连到这个（起点不变）")
        r = CollageAlbumRules.click("a", command: false, shift: true, selection: r.selection, anchor: r.anchor, order: order)
        check(r.selection == ["a", "b"], "再 ⇧ 点另一头：换成起点到这一个（不是接着加）")
        r = CollageAlbumRules.click("e", command: true, shift: true, selection: ["a"], anchor: "c", order: order)
        check(r.selection == ["a", "c", "d", "e"], "⌘⇧ 点把这一段加进去")
        r = CollageAlbumRules.click("c", command: false, shift: true, selection: [], anchor: nil, order: order)
        check(r.selection == ["c"], "没有起点的 ⇧ 点 = 单击")

        let pages = (0..<5).map { _ in CollagePage(root: .leaf(.photo(nil))) }
        let ids = pages.map(\.id)
        check(CollageAlbumRules.indices(of: [ids[1], ids[3], UUID()], in: pages) == IndexSet([1, 3]),
              "选中按页 id 换成下标（不在了的不管）")
        let moved = CollageAlbum.moved(pages, from: IndexSet([3]), to: 0)
        check(CollageAlbumRules.indices(of: [ids[1], ids[3]], in: moved) == IndexSet([0, 2]),
              "挪了以后同一批选中换成新下标")
        let two: Set<UUID> = [ids[1], ids[3]]
        let outside = Array(CollageAlbumRules.targets(for: ids[2], selection: two, pages: pages))
        let inside = Array(CollageAlbumRules.targets(for: ids[3], selection: two, pages: pages))
        let alone = Array(CollageAlbumRules.targets(for: ids[3], selection: [ids[3]], pages: pages))
        check(outside == [2] && inside == [1, 3] && alone == [3], "右键 / 拖：点在多选里 = 整批，点在没选的上 = 只它")
    }

    // MARK: - 插入位置

    static func checkInsertion(check: Check) {
        typealias M = CollageAlbumRules.GridMetrics
        // 4 列，格子 100×60，缝 10，左上角 (16, 16)：第 k 列 x = 16 + 110k，中线 66 + 110k；第 r 行 y = 16 + 70r。
        let m = M(columns: 4, cell: CGSize(width: 100, height: 60), spacing: 10, origin: CGPoint(x: 16, y: 16))
        func ins(_ x: CGFloat, _ y: CGFloat, _ slots: Int = 10) -> (slot: Int, row: Int, gap: Int) {
            CollageAlbumRules.insertion(at: CGPoint(x: x, y: y), slots: slots, metrics: m)
        }
        let row0: [Int] = [ins(20, 30).slot, ins(70, 30).slot, ins(170, 30).slot, ins(180, 30).slot]
        check(row0 == [0, 1, 1, 2], "同一行：第 0 格中线左边插在最前，过了第 k 格中线插在它后面", "\(row0)")
        let end0 = ins(470, 30), start1 = ins(10, 100)
        let both: [Int] = [end0.slot, end0.row, end0.gap, start1.slot, start1.row, start1.gap]
        check(both == [4, 0, 4, 4, 1, 0],
              "第 0 行最后面和第 1 行最前面都是插在第 4 格前（行不一样：竖线画在指针那一行）",
              "\(end0) \(start1)")
        check(ins(470, 170).slot == 10 && ins(470, 170).gap == 2, "最后一行只有 2 格：指针在右边空处 = 插在最后")
        check(ins(70, 900).row == 2 && ins(70, -50).row == 0, "指针在网格上面 / 下面：夹到第一行 / 最后一行")
        func hit(_ x: CGFloat, _ y: CGFloat) -> Int {
            CollageAlbumRules.hitSlot(at: CGPoint(x: x, y: y), slots: 10, metrics: m) ?? -1
        }
        let hits: [Int] = [hit(66 + 220, 40), hit(121, 40), hit(66 + 330, 40 + 140)]
        check(hits == [2, -1, -1], "点在哪一格：格子上算、缝里不算、最后一格后面的空位不算", "\(hits)")
        let wide = CollageAlbumRules.columns(width: 470, cardWidth: 100, spacing: 10, padding: 16)
        let narrow = CollageAlbumRules.columns(width: 80, cardWidth: 100, spacing: 10, padding: 16)
        check(wide == 4 && narrow == 1, "几列：放得下几个放几个，再窄也有 1 列")
        // 跨页条：一行；前面 1 格是封面。
        let dests: [Int] = [0, 3, 9].map { CollageAlbumRules.pageDestination(slot: $0, leadingSlots: 1, pageCount: 5) }
        check(dests == [0, 2, 5], "插在封面前面 = 插在第一个跨页前（封面不能动）；插在最后 = 跨页数", "\(dests)")
        func changes(_ picked: [Int], _ to: Int) -> Bool {
            CollageAlbumRules.moveChangesOrder(IndexSet(picked), to: to, count: 5)
        }
        let moves: [Bool] = [changes([2], 2), changes([2], 3), changes([1, 2], 3), changes([2], 0), changes([1, 3], 2)]
        check(moves == [false, false, false, true, true],
              "放回原处（自己前后两个缝）不算挪：不画线、不记撤销；隔开的两个并到一起算挪", "\(moves)")
        let line = CollageAlbumOverview.lineRect(slot: 4, slots: 10, metrics: m)
        // 上一行最后一格（第 3 列）右边 = 16 + 3 × 110 + 100，再往右半个缝。
        let wantX: CGFloat = 451
        let wantY: CGFloat = 16
        check(abs(line.midX - wantX) < 0.01 && abs(line.minY - wantY) < 0.01,
              "插在一行开头的格子前面：竖线画在上一行最后一格的右边", "\(line)")
    }

    // MARK: - 移到第…个跨页

    static func checkMoveMenu(check: Check) {
        check(CollageAlbumRules.moveGroups(count: 12) == [.init(title: "", pages: Array(0..<12))],
              "12 个以内直接列")
        let g = CollageAlbumRules.moveGroups(count: 23)
        check(g.map(\.title) == ["第 1–10 个", "第 11–20 个", "第 21–23 个"] && g.flatMap(\.pages) == Array(0..<23),
              "多了每 10 个一组、一个不漏", g.map(\.title).joined(separator: " "))
        check(CollageAlbumRules.moveGroups(count: 0).isEmpty, "没有跨页：没有菜单")
        func parse(_ s: String, current: Int = 2) -> Result<Int, CollageAlbumRules.MoveError> {
            CollageAlbumRules.parseSpreadNumber(s, count: 30, current: current)
        }
        let good: [Int] = ["7", " 第 7 个 ", "７"].map { s -> Int in
            if case .success(let i) = parse(s) { return i } else { return -1 }
        }
        check(good == [6, 6, 6], "填号：7、「第 7 个」、全角７都是第 7 个", "\(good)")
        let bad = ["", "0", "31", "abc", "3"].map { s -> Bool in if case .failure = parse(s) { return true } else { return false } }
        check(bad.allSatisfy { $0 }, "空、0、超过跨页数、认不出、就是这一个：说一句不挪")
        func badge(_ page: Int?, _ current: Int, _ album: Bool, _ count: Int) -> String {
            CollageAlbumRules.usedBadge(page: page, current: current, album: album, pageCount: count) ?? "无"
        }
        let badges = [badge(4, 1, true, 9), badge(1, 1, true, 9), badge(nil, 1, true, 9), badge(0, 3, false, 1),
                      badge(0, 2, false, 4)]
        check(badges == ["第 5 跨页", "这一页", "无", "已用", "第 1 页"],
              "「换一张」角标：第 N 跨页 / 这一页 / 没上版不标；单张拼图一页 = 已用、几页 = 第 N 页",
              badges.joined(separator: " "))
        check(CollageAlbumRules.photoCountLabel(0) == "空" && CollageAlbumRules.photoCountLabel(3) == "3 张", "卡片下面的张数")
    }

    // MARK: - store 上

    @MainActor
    static func checkStore(check: Check) {
        let store = CollageStore(dataDir: appDataDir)
        let photos = (0..<10).map { CollageAlbumEditSelfTest.photo("U\($0)", Double($0) * 5, portrait: $0 % 3 != 0,
                                                                     score: 3 - Double($0) * 0.1) }
        func spread(_ a: String, _ b: String) -> CollagePage {
            CollagePage(root: .split(.row, 0.5, .leaf(.photo(a)), .leaf(.photo(b))))
        }
        var project = CollageProject()
        project.mode = .album
        project.canvas = CollageAlbumEditSelfTest.album30
        project.photos = photos
        project.pages = [spread("U0", "U1"), spread("U2", "U3"), spread("U4", "U5"), spread("U6", "U7"), spread("U8", "U9")]
        store.loadForTesting(project)
        func order() -> String { store.project.pages.map { $0.photoIDs.joined(separator: "+") }.joined(separator: " ") }

        // 封面卡不算在跨页数里。
        check(store.makeCover() && store.project.bookCover != nil && store.project.pages.count == 5,
              "做了封面：跨页还是 5 个（封面不进 pages，跨页条的计数、页数检查都不算它）")

        // ⌘← 从第一个跨页到封面，⌘→ 回第一个；到头不动。
        store.pageIndex = 0
        check(CollageAlbumKeys.go(-1, store: store) && store.editingCover, "第一个跨页按 ⌘←：编辑封面")
        check(!CollageAlbumKeys.go(-1, store: store) && store.editingCover, "封面上再按 ⌘←：不动")
        check(CollageAlbumKeys.go(1, store: store) && !store.editingCover && store.pageIndex == 0, "封面按 ⌘→：回到第一个跨页")
        store.pageIndex = 4
        check(!CollageAlbumKeys.go(1, store: store) && store.pageIndex == 4, "最后一个跨页按 ⌘→：不动")
        // 封面底下是第 2 个跨页时点第 2 个跨页的卡片：pageIndex 不变（didSet 不会触发），照样要退出封面编辑。
        store.pageIndex = 2
        store.setEditingCover(true)
        CollageAlbumKeys.open(.page(2), store: store)
        check(!store.editingCover && store.pageIndex == 2, "编辑封面时点封面底下那个跨页的卡片：退出封面编辑")
        check(CollageAlbumKeys.perform(.overview, store: store) && store.albumUI.overviewShown
              && CollageAlbumKeys.perform(.overview, store: store) && !store.albumUI.overviewShown, "G：开、关整本概览")

        // 多选镜像：一步撤销，两次回原样。
        let before = store.project.pages
        let depth = store.undoDepth
        store.mirrorPages(IndexSet([1, 3]))
        let flipped = store.project.pages
        let changed: [Bool] = flipped.indices.map { flipped[$0] != before[$0] }
        check(store.undoDepth == depth + 1 && changed == [false, true, false, true, false],
              "多选镜像两个跨页：一步撤销，别的跨页不动", "\(changed)")
        store.mirrorPages(IndexSet([1, 3]))
        check(store.project.pages.map(\.photoIDs) == before.map(\.photoIDs)
              && zip(store.project.pages, before).allSatisfy { $0.root.signature == $1.root.signature },
              "再镜像一次：回到原样")
        store.undo()
        store.undo()
        check(store.project.pages == before, "撤销两次回到镜像之前")

        // 概览选中挪 / 删：按页 id 认，挪完删的还是那两个。
        let ui = store.albumUI
        ui.overviewSelection = [store.project.pages[3].id, store.project.pages[4].id]
        store.movePages(ui.selectedIndices(store.project.pages), to: 0)
        check(order() == "U6+U7 U8+U9 U0+U1 U2+U3 U4+U5" && ui.selectedIndices(store.project.pages) == IndexSet([0, 1]),
              "概览选中两个拖到最前：一起挪，选中跟着页走", order())
        store.deletePages(ui.selectedIndices(store.project.pages))
        check(order() == "U0+U1 U2+U3 U4+U5", "删除选中的两个：删的就是它们", order())
        store.undo()
        store.undo()
        check(order() == "U0+U1 U2+U3 U4+U5 U6+U7 U8+U9", "撤销两次回到原样")

        // 锁住、解锁这个跨页（「这个跨页」的勾、右键）。
        store.setPagesLocked(IndexSet([1, 2]), true)
        check(store.project.pages.map(\.locked) == [false, true, true, false, false], "锁住两个跨页")
        store.undo()

        // 跨页条上按位置认卡片（画布拖格子出来时）：封面卡、缝、条外面都不算。
        ui.stripMetrics = CollageAlbumRules.GridMetrics(columns: 6, cell: CGSize(width: 104, height: 68), spacing: 8)
        ui.stripLeadingSlots = 1
        ui.stripPageCount = 5
        ui.stripContent = CGRect(x: 100, y: 700, width: 6 * 112, height: 68)
        ui.stripViewport = CGRect(x: 90, y: 694, width: 400, height: 80)
        check(ui.stripTarget(at: CGPoint(x: 100 + 112 + 50, y: 730)) == 0
              && ui.stripTarget(at: CGPoint(x: 100 + 2 * 112 + 50, y: 730)) == 1,
              "跨页条：封面卡后面第一张是第 0 个跨页")
        check(ui.stripTarget(at: CGPoint(x: 150, y: 730)) == nil && ui.stripTarget(at: CGPoint(x: 100 + 108, y: 730)) == nil,
              "指着封面卡、卡片之间的缝：不算")
        check(ui.stripTarget(at: CGPoint(x: 100 + 4 * 112 + 50, y: 730)) == nil,
              "滚出看得见的那一截的卡片：不算（不然会认到检视器底下）")
        check(ui.stripTarget(at: CGPoint(x: 262, y: 600)) == nil, "条外面：不算")
    }
}
