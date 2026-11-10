import Foundation
import CoreGraphics

/// --album-selftest 里相册审查（2026-11）修补的几条，合成数据、不要照片、不跑 Vision、不开界面：
/// 1. 整本级的入口（自动编排、换装订、套规格、整本婚礼相册）先退出封面编辑；只改规则不退出；
/// 2. 编辑封面时挪 / 删跨页：pageIndex 跟着封面底下那个跨页；删的正好是那一页时接着编辑封面、封面的选中不清；
///    封面上「加进现在的版式」不管 F5（同 placeOnCover）；
/// 3. 导出前检查点一条：先退出封面编辑、收起整本概览再跳；封面那几条进封面编辑 / 去「文档 › 封面」；悬停说明；
///    编辑封面时导出范围「当前跨页」写明第几个；
/// 5. 锁住的扉页：自动编排、整本婚礼相册都只出一个扉页，照片一张不丢不重；mergeLocked 知道新编的没有扉页；
/// 6. 封面的空照片格、放大（拦 / 提醒），整本导出先问、只导几个跨页不问；清空托盘连封面一起去掉；
/// 7. 封面每张纸厚跟着装订的默认值走，手改过的不动；
/// 11. 规则框每一项各自合并撤销；
/// 12. 撤销 / 重做以后画面跟回原来那个跨页。
enum CollageAlbumReviewSelfTest {
    typealias Check = CollageAlbumEditSelfTest.Check
    typealias Edit = CollageAlbumEditSelfTest

    @MainActor
    static func run(check report: (Bool, String, String) -> Void) {
        withoutActuallyEscaping(report) { body in
            let check = Check(body: body)
            print("== 相册审查修补（封面编辑的入口、锁住的扉页、封面检查、撤销跟页）")
            checkCoverExits(check: check)
            checkCoverPages(check: check)
            checkReveal(check: check)
            checkLockedOpener(check: check)
            checkMergeWithoutOpener(check: check)
            checkCoverPreflight(check: check)
            checkSheet(check: check)
            checkRulesUndo(check: check)
            checkUndoFollows(check: check)
        }
    }

    // MARK: - 合成的一本

    /// 五个跨页：第 0 个是扉页（左页竖排标题 + 右页 R0），后面每个两张；托盘 12 张（R9–R11 没上版）。
    static func book() -> CollageProject {
        let photos = (0..<12).map { Edit.photo("R\($0)", Double($0) * 5, portrait: $0 % 3 != 0, score: 3 - Double($0) * 0.1) }
        var title = CollageTemplates.verticalTitle(size: 0.075, seal: "拾光")
        title.alignH = .center
        title.alignV = .center
        let opener = CollagePage(root: CollageTemplates.row(0.5, CollageTemplates.text(title), .leaf(.photo("R0", role: .hero))))
        func spread(_ a: Int, _ b: Int) -> CollagePage {
            CollagePage(root: .split(.row, 0.5, .leaf(.photo("R\(a)")), .leaf(.photo("R\(b)"))))
        }
        var p = CollageProject()
        p.mode = .album
        p.canvas = Edit.album30
        p.title = "拾光"
        p.photos = photos
        p.pages = [opener, spread(1, 2), spread(3, 4), spread(5, 6), spread(7, 8)]
        return p
    }

    /// 载入合成的那本、做好封面（主图 = 扉页那张 R0）。
    @MainActor
    static func coverStore(_ project: CollageProject = book()) -> CollageStore {
        let store = CollageStore(dataDir: appDataDir)
        store.loadForTesting(project)
        store.makeCover()
        return store
    }

    /// 封面那一块里第一个照片格的路径。
    @MainActor
    static func coverPhotoPath(_ store: CollageStore) -> [Int]? {
        guard let front = store.project.bookCover?.front else { return nil }
        return front.leafPaths().first { front.node(at: $0)?.cell?.kind == .photo }
    }

    /// 有几个跨页上印着书名（扉页的「{title}」）。
    static func titlePages(_ pages: [CollagePage]) -> Int {
        pages.filter { page in
            page.root.leaves.contains { $0.kind == .text && $0.text?.lines.contains { $0.text == "{title}" } == true }
        }.count
    }

    // MARK: - 1. 整本级的入口先退出封面编辑

    @MainActor
    static func checkCoverExits(check: Check) {
        let store = coverStore()
        store.setEditingCover(true)
        check(store.editingCover, "前提：做好封面、进得了封面编辑")
        store.autoArrangeAlbum(dedupe: false)
        let arrangeExited = !store.editingCover
        Edit.spin(60) { !store.isSolving && store.busyText == nil }
        check(arrangeExited && !store.editingCover && store.project.bookCover != nil && store.page?.id == store.project.pages.first?.id,
              "自动编排：一点就退出封面编辑（封面还在），落下来画布上是第 1 个跨页")

        store.setEditingCover(true)
        store.setBinding(.glued)
        check(!store.editingCover && store.project.canvas.binding == .glued, "换装订（文档 › 画布）：先退出封面编辑")
        store.setEditingCover(true)
        store.setBinding(.glued)
        check(store.editingCover, "装订没变：什么都不做，也不退出封面编辑")

        if let spec = CollagePrintSpec.builtin.first(where: { $0.binding == .layflat }) {
            store.applyPrintSpec(spec)
            check(!store.editingCover && store.project.canvas.binding == .layflat, "套规格（菜单、MCP collage_print_spec）：先退出封面编辑")
        }

        store.setEditingCover(true)
        var rules = store.project.canvas.effectivePrintRules
        rules.colorSpace = .adobeRGB
        store.setPrintRules(rules)
        check(store.editingCover, "只改页数、色彩这些规则（不重排跨页）：不退出封面编辑")

        var landed = false
        store.applyKit(.weddingAlbum) { landed = true }
        let kitExited = !store.editingCover
        Edit.spin(60) { landed }
        check(kitExited && landed && !store.editingCover && store.project.albumTheme == .fineArt && store.project.bookCover != nil,
              "左栏「整本婚礼相册」：一点就退出封面编辑（落下来 pageIndex 还是 0，以前一直停在封面上看不到结果）")
    }

    // MARK: - 2. 编辑封面时挪 / 删跨页

    @MainActor
    static func checkCoverPages(check: Check) {
        let store = coverStore()
        let original = store.project.pages.map(\.id)
        let path = coverPhotoPath(store)
        store.pageIndex = 4
        store.setEditingCover(true)
        store.selection = path
        store.deletePages(IndexSet(integer: 0))
        check(store.editingCover && store.pageIndex == 3 && store.project.pages[store.pageIndex].id == original[4]
              && store.selection == path,
              "编辑封面时删第 1 个跨页：底下还是原来那个跨页（下标跟着减一），接着编辑封面、封面的选中留着",
              "pageIndex \(store.pageIndex)")
        store.setEditingCover(false)
        check(store.page?.id == original[4], "回到跨页：还是原来那个（以前停在越界的下标上，「回到跨页」没反应、画布空白）")

        let moving = coverStore()
        let ids = moving.project.pages.map(\.id)
        moving.pageIndex = 1
        moving.setEditingCover(true)
        moving.movePages(IndexSet(integer: 1), to: 5)
        check(moving.editingCover && moving.pageIndex == 4 && moving.project.pages[4].id == ids[1],
              "编辑封面时把封面底下那个跨页挪到最后：底下那页跟着它走", "pageIndex \(moving.pageIndex)")
        moving.selection = coverPhotoPath(moving)
        moving.deletePages(IndexSet(integer: moving.pageIndex))
        check(moving.editingCover && moving.selection == coverPhotoPath(moving) && moving.pageIndex == 3,
              "编辑封面时删的正好是封面底下那一页：不退出封面编辑、封面的选中不清，底下换成删掉那一段后面（没有就最后）那一页",
              "pageIndex \(moving.pageIndex)")

        // 封面上「加进现在的版式」：R3 在第 3 个跨页上，封面照样能用（同 placeOnCover），不说 F5 那句、不拒。
        let relay = coverStore()
        relay.setEditingCover(true)
        let onCover = relay.project.bookCover?.front.photoIDs ?? []
        relay.relayout(photoIDs: onCover + ["R3"])
        Edit.spin(30) { !relay.isSolving }
        let after = relay.project.bookCover?.front.photoIDs ?? []
        check(after.contains("R3") && relay.project.pages[2].photoIDs.contains("R3") && !(relay.notice ?? "").contains("跨页上了"),
              "编辑封面时「加进现在的版式」：跨页上已经有的照片照样排进封面（不管 F5，和拖进封面一致）",
              after.joined(separator: "+"))
    }

    // MARK: - 3. 导出前检查点一条

    @MainActor
    static func checkReveal(check: Check) {
        let store = coverStore()
        store.pageIndex = 2
        store.setEditingCover(true)
        store.albumUI.overviewShown = true
        let slot = CollagePreflightIssue(kind: .emptySlot, severity: .block, page: 2, path: [1], message: "自检")
        store.reveal(slot)
        check(!store.editingCover && !store.albumUI.overviewShown && store.pageIndex == 2 && store.selection == [1],
              "编辑封面、开着整本概览时点第 3 个跨页那一条（正好是封面底下那页）：退出封面编辑、收起概览，选中那一格",
              "editing \(store.editingCover) 概览 \(store.albumUI.overviewShown) 选中 \(store.selection ?? [])")

        let path = coverPhotoPath(store)
        let coverSlot = CollagePreflightIssue(kind: .cover, severity: .block, page: nil, path: path, message: "封面：自检")
        store.reveal(coverSlot)
        check(store.editingCover && store.selection == path, "点封面上的空照片格那一条：进封面编辑、选中那一格")
        store.setEditingCover(false)
        store.nav.inspectorTab = .format
        let spine = CollagePreflightIssue(kind: .cover, severity: .warn, page: nil, message: "封面：书脊是估的")
        store.reveal(spine)
        check(!store.editingCover && store.nav.inspectorTab == .document, "点书脊那一条：去「文档 › 封面」（右栏切到「文档」）")

        let pages = CollagePreflightIssue(kind: .pageCount, severity: .block, message: "页数")
        check(CollagePreflightBox.rowHelp(coverSlot).contains("封面编辑") && CollagePreflightBox.rowHelp(spine).contains("文档 › 封面")
              && CollagePreflightBox.rowHelp(pages).contains("文档 › 画布") && CollagePreflightBox.rowHelp(slot).contains("跳到那个跨页"),
              "清单的悬停说明：封面那几条指到封面（不再写「在「文档 › 画布」里改规格」），页数照旧")
        check(CollageExportRangeBox.currentLabel(editingCover: true, pageIndex: 2) == "当前跨页（第 3 个）"
              && CollageExportRangeBox.currentLabel(editingCover: false, pageIndex: 2) == "当前跨页",
              "编辑封面时导出范围写「当前跨页（第 N 个）」：导的是封面底下那个跨页、不是封面")
    }

    // MARK: - 5. 锁住的扉页

    @MainActor
    static func checkLockedOpener(check: Check) {
        let photos = book().photos
        check(CollageAlbum.plan(photos, dedupe: false, opener: false).spreads.allSatisfy { $0.kind != .opener }
              && CollageAlbum.plan(photos, dedupe: false, theme: .fineArt, opener: false).spreads.allSatisfy { $0.fineArt?.kind != .title }
              && CollageAlbum.plan(photos, dedupe: false, budget: CollageAlbumBudget(spreads: 4, minPerSpread: 1, maxPerSpread: 6),
                                   opener: false).spreads.allSatisfy { $0.kind != .opener },
              "plan(opener: false)：默认编排、按目标跨页数编、婚礼 fine-art 都不出扉页")
        for theme in [CollageAlbumTheme.classic, .fineArt] {
            var p = book()
            p.albumTheme = theme
            let store = CollageStore(dataDir: appDataDir)
            store.loadForTesting(p)
            store.setPagesLocked(IndexSet(integer: 0), true)
            let locked = store.project.pages[0]
            check(CollageAlbum.lockedOpener(store.project), "\(theme.label)：锁住的第一个跨页认得出是扉页")
            if theme == .classic {
                store.autoArrangeAlbum(dedupe: false)
                Edit.spin(60) { !store.isSolving && store.busyText == nil }
            } else {
                var landed = false
                store.applyKit(.weddingAlbum) { landed = true }
                Edit.spin(60) { landed }
            }
            let pages = store.project.pages
            let used = pages.flatMap(\.photoIDs)
            // fine-art 的「同一场只留精选」这本合成书用不上（没有场），十二张都该上版。
            let all = Set(p.photos.map(\.id))
            check(pages.first == locked && titlePages(pages) == 1 && Set(used) == all && used.count == all.count,
                  "\(theme.label)：锁住扉页再编排，只有一个扉页（锁住的那个、还在最前），照片一张不丢不重",
                  "扉页 \(titlePages(pages)) 个；\(used.count) 张 / 托盘 \(all.count) 张")
        }
        // 锁住的第一个跨页不是扉页（两张照片）：照常出扉页。
        var plain = book()
        plain.pages[0] = plain.pages[1]
        plain.pages[1] = CollagePage(root: .split(.row, 0.5, .leaf(.photo("R0")), .leaf(.photo("R9"))))
        plain.pages[0].locked = true
        check(!CollageAlbum.lockedOpener(plain), "锁住的第一个跨页是两张照片（不是扉页）：照常出扉页")
    }

    /// mergeLocked(freshOpener: false)：新编的第一个不是扉页，锁住的页按时间插在它前面也行（不再被当成扉页挡在后面）。
    static func checkMergeWithoutOpener(check: Check) {
        let photos = (0..<10).map { Edit.photo("M\($0)", Double($0) * 10) }
        var map: [String: CollagePhotoRef] = [:]
        for p in photos { map[p.id] = p }
        func page(_ ids: [Int]) -> CollagePage {
            var root = CollageNode.leaf(.photo("M\(ids[0])"))
            for i in ids.dropFirst() { root = .split(.row, 0.5, root, .leaf(.photo("M\(i)"))) }
            return CollagePage(root: root)
        }
        var opener = CollagePage(root: .split(.row, 0.5, .leaf(.text(CollageText(lines: [CollageTextLine("{title}")]))),
                                              .leaf(.photo("M9"))))
        opener.locked = true
        var early = page([0, 1])
        early.locked = true
        let fresh = [page([2, 3]), page([4, 5])]
        func ids(_ pages: [CollagePage]) -> String { pages.map { $0.photoIDs.joined(separator: "+") }.joined(separator: " | ") }
        let merged = CollageAlbum.mergeLocked(fresh, locked: [(index: 0, page: opener), (index: 1, page: early)], photos: map,
                                              freshOpener: false)
        check(ids(merged) == "M9 | M0+M1 | M2+M3 | M4+M5", "新编的没有扉页：锁住的扉页在最前，比新编第一个还早的锁住页插在它前面",
              ids(merged))
    }

    // MARK: - 6. 封面的空照片格、放大、清空托盘

    @MainActor
    static func checkCoverPreflight(check: Check) {
        let store = coverStore()
        guard let path = coverPhotoPath(store), let hero = store.project.bookCover?.front.node(at: path)?.cell?.photoID else {
            check(false, "封面上有照片格", "")
            return
        }
        let clean = CollageBookCover.preflightIssues(project: store.project, hints: [:], readable: { _ in true })
        check(!clean.contains { $0.severity == .block }, "照片够大、格子都有照片：封面没有「拦」的",
              clean.map(\.message).joined(separator: "；"))

        // 放大：同一张照片按比例缩小像素（取景不变），放大倍数跟着反比变。
        var frontProject = store.project
        frontProject.canvas = CollageBookCover.frontCanvas(store.project.canvas)
        frontProject.pages = []
        var photos: [String: CollagePhotoRef] = [:]
        for p in store.project.photos { photos[p.id] = p }
        guard let cover = store.project.bookCover,
              let placed = CollagePreflight.placements(page: cover.editPage, index: 0, project: frontProject, photos: photos,
                                                       hints: [:]).first(where: { $0.photo.id == hero }) else {
            check(false, "封面那一格算得出取景", "")
            return
        }
        let k0 = CollageCrop.upscale(photo: placed.photo, window: placed.window, drawn: placed.drawn)
        func shrunk(to k: Double) -> CollageProject {
            var p = store.project
            if let i = p.photos.firstIndex(where: { $0.id == hero }) {
                let f = k0 / k
                p.photos[i].width = max(1, Int((Double(p.photos[i].width) * f).rounded()))
                p.photos[i].height = max(1, Int((Double(p.photos[i].height) * f).rounded()))
            }
            return p
        }
        let soft = CollageBookCover.preflightIssues(project: shrunk(to: 1.35), hints: [:]).filter { $0.photoID == hero && $0.message.contains("放大") }
        let blurry = CollageBookCover.preflightIssues(project: shrunk(to: 2), hints: [:]).filter { $0.photoID == hero && $0.message.contains("放大") }
        check(soft.count == 1 && soft[0].severity == .warn && blurry.count == 1 && blurry[0].severity == .block
              && blurry[0].path == path && blurry[0].page == nil,
              "封面放大：135% 提醒、200% 拦（同跨页的 120% / 150%），带封面那一块的格子路径",
              (soft + blurry).map(\.message).joined(separator: "；"))

        // 空照片格：拦；整本导出先问，只导几个跨页不问（不写封面）。
        store.updateBookCover { $0?.front.update(at: path) { $0.cell?.photoID = nil } }
        let issues = store.preflight(texts: false)
        let empty = issues.filter { $0.kind == .cover && $0.severity == .block && $0.path == path }
        check(empty.count == 1 && empty[0].page == nil, "封面上的空照片格：拦（page = nil、带封面那一块的路径）",
              issues.map(\.message).joined(separator: "；"))
        let ask = CollageStore.exportConfirmation(issues, project: store.project, pages: nil)
        let partial = CollageStore.exportConfirmation(issues.filter { $0.kind == .cover }, project: store.project, pages: [1])
        check(ask?.message.contains("封面：有一个空照片格") == true && partial == nil,
              "导整本时先问（列出封面那一条）；只导几个跨页不问封面的（部分导出不写封面）", ask?.message ?? "nil")
        // 照片不在托盘里（被拿出去了）也算空格。
        store.updateBookCover { $0?.front.update(at: path) { $0.cell?.photoID = "不在托盘里" } }
        check(CollageBookCover.preflightIssues(project: store.project, hints: [:]).contains { $0.severity == .block && $0.path == path },
              "封面格子里的照片不在托盘里：同样算空照片格")

        // 清空托盘：照片、跨页、封面一起去掉（一步撤销），编辑封面也跟着退出。
        store.setEditingCover(true)
        let depth = store.undoDepth
        store.clearTray()
        check(store.project.bookCover == nil && !store.editingCover && store.project.pages.isEmpty && store.undoDepth == depth + 1,
              "清空托盘和版式：封面一起去掉、退出封面编辑，一步撤销")
        store.undo()
        check(store.project.bookCover != nil && store.project.pages.count == 5, "⌘Z：封面、跨页都回来")
    }

    // MARK: - 7. 每张纸厚跟着装订

    @MainActor
    static func checkSheet(check: Check) {
        let store = coverStore()
        let flat = CollageBookCover.defaultSheetMM(.layflat)
        let glued = CollageBookCover.defaultSheetMM(.glued)
        check(store.project.canvas.binding == .layflat && store.project.bookCover?.sheetMM == flat, "前提：平铺、纸厚是平铺的默认值")
        let depth = store.undoDepth
        store.setBinding(.glued)
        check(store.project.bookCover?.sheetMM == glued && store.undoDepth == depth + 1,
              "换成胶装：纸厚还是平铺的默认值 → 换成胶装的默认值（同一步撤销）")
        store.undo()
        check(store.project.bookCover?.sheetMM == flat && store.project.canvas.binding == .layflat, "⌘Z 一次：装订、纸厚一起回去")
        if let spec = CollagePrintSpec.builtin.first(where: { $0.binding == .glued }) {
            store.applyPrintSpec(spec)
            check(store.project.bookCover?.sheetMM == glued, "套胶装的规格：纸厚同样跟过去")
            store.undo()
        }
        store.setCoverSheet(0.3)
        store.setBinding(.glued)
        check(store.project.bookCover?.sheetMM == 0.3, "手改过纸厚（0.3mm）：换装订不动它")
    }

    // MARK: - 11. 规则框每一项各自合并撤销

    @MainActor
    static func checkRulesUndo(check: Check) {
        let store = coverStore()
        let pagesKey: WritableKeyPath<CollagePrintRules, Int> = \.minPages
        let colorKey: WritableKeyPath<CollagePrintRules, CollageColorSpace> = \.colorSpace
        let depth = store.undoDepth
        var rules = store.project.canvas.effectivePrintRules
        rules.minPages = 22
        store.setPrintRules(rules, coalesce: true, key: pagesKey)
        rules.colorSpace = .adobeRGB
        store.setPrintRules(rules, coalesce: true, key: colorKey)
        check(store.undoDepth == depth + 2, "0.6 秒内先改页数再切色彩：两步撤销（以前并成一步）", "\(store.undoDepth - depth) 步")
        rules.minPages = 24
        store.setPrintRules(rules, coalesce: true, key: pagesKey)
        rules.minPages = 26
        store.setPrintRules(rules, coalesce: true, key: pagesKey)
        check(store.undoDepth == depth + 3, "同一个步进器连着点：合成一步", "\(store.undoDepth - depth) 步")
        store.undo()
        check(store.project.canvas.effectivePrintRules.minPages == 22 && store.project.canvas.effectivePrintRules.colorSpace == .adobeRGB,
              "⌘Z 一次只撤掉连着点的页数，色彩还在")
    }

    // MARK: - 12. 撤销以后画面跟回原来那个跨页

    @MainActor
    static func checkUndoFollows(check: Check) {
        let store = CollageStore(dataDir: appDataDir)
        store.loadForTesting(book())
        let a = store.project.pages[0].id
        store.movePages(IndexSet(integer: 0), to: 5)
        check(store.pageIndex == 4 && store.page?.id == a, "前提：把第 1 个（当前）拖到最后，画面跟着到第 5 个")
        store.undo()
        check(store.pageIndex == 0 && store.page?.id == a, "⌘Z：跨页回到原位，画面跟着那个跨页回到第 1 个（以前停在第 5 个、显示别的跨页）",
              "pageIndex \(store.pageIndex)")
        store.redo()
        check(store.pageIndex == 4 && store.page?.id == a, "⌘⇧Z：再挪过去，画面还跟着它")
        store.addPage()
        let added = store.pageIndex
        store.undo()
        check(added == 5 && store.pageIndex == 4 && store.project.pages.count == 5,
              "撤掉「加一个跨页」：那一页没了，按下标夹回最后一个", "pageIndex \(store.pageIndex)")
    }
}
