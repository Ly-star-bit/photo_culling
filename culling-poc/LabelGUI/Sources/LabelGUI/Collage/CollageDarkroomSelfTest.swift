import Foundation

/// LABELGUI_DATA_DIR=<临时> LabelGUI --darkroom-selftest
///
/// 暗房（CollageDarkroom）的规则，只验状态、不渲染（渲染看 --collage-ui --darkroom 的快照），不要照片：
/// 1. 样张：四组（负片 9、反转片 4、电影负片 2、滤镜 12）合起来正好是全部色调、每个一次；光谱色调只在三组胶片里，
///    滤镜里一个都没有；「胶片」页签 = 15 款光谱色调，「滤镜」页签 = 12 款；每款一句用途，不带片种、型号、ISO。
/// 2. 打开：整组、看到的就是工程的色调；单张拼图没有「这一页」，没选格子「这一格」退回整组。
/// 3. 悬停只是预览：工程、撤销步数都不动，预览用的工程里这一级换成了悬停的色调。
/// 4. 套用：整组 / 这一页 / 这一格各改各的那一级，一次一步撤销，undo 一下回去。
/// 5. 强度：这一页还没有自己的色调时拖强度 = 用现在看到的色调 + 新强度给这一页设上；连拖合成一步；
///    已经有的（包括模板带的）只改强度，fromTemplate 留着。
/// 6. 颗粒、晕光、统一色温永远改整组，选「这一格」也一样。
/// 7. ←→ 只在这一页签里按先后走、到头绕回，只预览不套用；⏎（apply(focus)）才套用；打开时页签跟着现在的色调。
/// 8. 原图：所有级别不调色、颗粒晕光统一色温都是 0，版式不变。
/// 9. 撤销清掉选中以后「这一格」退回上一级；关掉暗房清掉悬停。
/// 全过退出 0，否则 1。
enum CollageDarkroomSelfTest {

    @MainActor
    static func run() -> Never {
        CollageCLI.requireIsolatedDataDir("--darkroom-selftest")
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }

        // ---------------------------------------------------------------- 1. 样张
        print("== 样张")
        let order = CollageDarkroom.order
        check(order.count == CollageLook.allCases.count && Set(order) == Set(CollageLook.allCases),
              "四组合起来正好是全部色调、每个一次", "\(order.count) / \(CollageLook.allCases.count)")
        let counts = CollageDarkroom.groups.map { "\($0.title)\($0.looks.count)" }.joined(separator: " ")
        check(counts == "负片9 反转片4 电影负片2 滤镜12", "分组和张数", counts)
        for group in CollageDarkroom.groups {
            let film = group.kind != .filter
            check(group.looks.allSatisfy { $0.isSpectral == film },
                  film ? "「\(group.title)」里都是光谱胶片" : "「滤镜」里没有光谱胶片（滤镜没有颗粒、晕光，不穿底片外衣）")
        }
        let filmTab = CollageDarkroom.looks(in: .film), filterTab = CollageDarkroom.looks(in: .filter)
        check(filmTab.count == 15 && filmTab.allSatisfy(\.isSpectral) && filterTab.count == 12 && !filterTab.contains(where: \.isSpectral),
              "「胶片」页签 15 款光谱色调、「滤镜」页签 12 款", "\(filmTab.count) / \(filterTab.count)")
        let brands = ["KODAK", "FUJI", "ILFORD", "PORTRA", "EKTAR", "VELVIA", "PROVIA", "VISION", "GOLD", "ULTRAMAX",
                      "ISO", "柯达", "富士", "金200"]
        for look in order {
            let text = CollageDarkroom.blurb(look)
            // 只认阿拉伯数字（含全角）：Character.isNumber 把「一款」「抬一点」的「一」也算成数字。
            let digits = text.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
            check(!text.isEmpty && !digits && !brands.contains(where: { text.uppercased().contains($0) }),
                  "「\(look.label)」的用途「\(text)」不带片种、型号、数字")
        }

        // 合成工程：单张拼图，两格照片（不读文件，只验状态）。
        let store = CollageStore(dataDir: appDataDir)
        store.loadForTesting(project(album: false))

        // ---------------------------------------------------------------- 2. 打开
        print("== 打开")
        store.openDarkroom()
        guard let dr = store.darkroom else {
            check(false, "openDarkroom 之后 store.darkroom 有值")
            finish(failures)
        }
        dr.stop()  // 自检不渲染：停掉对 store 的订阅（下面的 dr 状态都现算）
        let quiet = CollageDarkroom(store: store, rendering: false)
        check(quiet.effectiveScope == .project && quiet.current.look == .filmWarmSkin && quiet.current.strength == 0.7,
              "一打开：整组，看到的是工程的色调和强度", "\(quiet.effectiveScope) \(quiet.current.look) \(quiet.current.strength)")
        check(quiet.focus == .filmWarmSkin, "键盘焦点落在现在的色调上", "\(quiet.focus)")
        check(!quiet.pageAvailable, "单张拼图没有「这一页」")
        quiet.scope = .cell
        check(quiet.effectiveScope == .project, "没选格子：「这一格」退回整组", "\(quiet.effectiveScope)")
        quiet.scope = .project

        // ---------------------------------------------------------------- 3. 悬停
        print("== 悬停只是预览")
        let before = store.project
        let pushes = store.undoPushes
        quiet.hover = .slideVivid
        check(store.project == before && store.undoPushes == pushes, "悬停：工程、撤销步数都不动")
        check(quiet.previewProject.style.look == .slideVivid && quiet.previewProject.style.lookStrength == 0.7,
              "预览用的工程：整组换成悬停的色调、强度照旧")
        quiet.hover = nil
        check(quiet.previewProject == store.project, "不悬停：预览就是 store 里的工程")

        // ---------------------------------------------------------------- 4. 套用
        print("== 套用")
        var p0 = store.undoPushes
        quiet.apply(.cineDay)
        check(store.project.style.look == .cineDay && store.undoPushes == p0 + 1, "整组：改工程样式，一步撤销")
        store.undo()
        check(store.project.style.look == .filmWarmSkin, "undo 一下回去")

        store.selection = [0]
        quiet.scope = .cell
        check(quiet.effectiveScope == .cell && quiet.current.look == .filmWarmSkin && !quiet.ownsSetting,
              "选中一格：「这一格」，跟着整组")
        p0 = store.undoPushes
        quiet.apply(.slideClean)
        let cell0 = store.project.pages[0].root.node(at: [0])?.cell?.look
        let cell1 = store.project.pages[0].root.node(at: [1])?.cell?.look
        check(cell0?.look == .slideClean && cell0?.strength == 0.7 && cell1 == nil && store.project.style.look == .filmWarmSkin
              && store.undoPushes == p0 + 1, "这一格：只改这一格（强度沿用 70%），别的格、整组不动，一步撤销")
        quiet.followParent()
        check(store.project.pages[0].root.node(at: [0])?.cell?.look == nil, "「跟着上一级」：这一格不再单独设")

        // ---------------------------------------------------------------- 5. 强度（相册：这一页）
        print("== 强度")
        store.loadForTesting(project(album: true))
        let album = CollageDarkroom(store: store, rendering: false)
        check(album.pageAvailable, "相册有「这一页」")
        album.scope = .page
        check(album.effectiveScope == .page && !album.ownsSetting, "这一页还没有自己的色调：跟着整组")
        p0 = store.undoPushes
        album.setStrength(0.4)
        album.setStrength(0.45)
        album.setStrength(0.5)
        let pageLook = store.project.pages[0].look
        check(pageLook?.look == .filmWarmSkin && pageLook?.strength == 0.5 && store.project.style.lookStrength == 0.7,
              "拖强度：用现在看到的色调 + 新强度给这一页设上，整组的强度不动", "\(String(describing: pageLook))")
        check(store.undoPushes == p0 + 1, "连拖三下合成一步撤销", "\(store.undoPushes - p0) 步")
        album.apply(.filmPastel)
        check(store.project.pages[0].look?.look == .filmPastel && store.project.pages[0].look?.strength == 0.5
              && store.project.pages[1].look == nil, "这一页：只改这一页（强度沿用 50%），别的跨页不动")
        check(album.overriddenBelow == nil, "选「这一页」时不提示被下级盖住")
        store.setPageLook(CollageLookSetting(look: .mono, strength: 0.9, fromTemplate: true))
        album.setStrength(0.6, coalesce: false)
        check(store.project.pages[0].look == CollageLookSetting(look: .mono, strength: 0.6, fromTemplate: true),
              "模板带的页级色调拖强度：只改强度，fromTemplate 留着", "\(String(describing: store.project.pages[0].look))")
        album.apply(.filmPastel)
        album.scope = .project
        check(album.overriddenBelow != nil, "选「整组」而这一页单独设了色调：提示整组改了这一页看不出来")

        // ---------------------------------------------------------------- 6. 颗粒、晕光、统一色温
        print("== 颗粒、晕光、统一色温对整组")
        store.selection = [0]
        album.scope = .cell
        album.setStyleValue(\.filmGrain, 0.6)
        album.setStyleValue(\.filmHalation, 0.3)
        album.setStyleValue(\.harmonize, 0.2)
        check(store.project.style.filmGrain == 0.6 && store.project.style.filmHalation == 0.3 && store.project.style.harmonize == 0.2,
              "选着「这一格」改颗粒、晕光、统一色温：改的是工程样式")
        check(store.project.pages[0].root.node(at: [0])?.cell?.look == nil, "这一格的色调没被顺手设上")

        // ---------------------------------------------------------------- 7. 键盘
        print("== 键盘")
        let kb = CollageDarkroom(store: store, rendering: false)
        check(kb.tab == .film, "打开时页签跟着现在的色调（光谱色调 → 胶片）", "\(kb.tab)")
        kb.focus = filmTab[0]
        kb.moveFocus(-1)
        check(kb.focus == filmTab.last && kb.hover == filmTab.last, "← 在第一个：绕到这一页签的最后一个，大预览跟着看")
        kb.moveFocus(1)
        check(kb.focus == filmTab[0], "→ 再绕回第一个")
        let pk = store.project
        kb.moveFocus(3)
        check(store.project == pk, "←→ 只预览，不套用")
        kb.scope = .project
        kb.apply(kb.focus)
        check(store.project.style.look == filmTab[3] && kb.hover == nil, "⏎ 套用焦点那一格，悬停清掉")
        kb.tab = .filter
        kb.moveFocus(1)
        check(kb.focus == filterTab[0], "换到「滤镜」页签：→ 从滤镜的第一个起，不跑回胶片", "\(kb.focus)")
        kb.moveFocus(-1)
        check(kb.focus == filterTab.last, "「滤镜」页签里 ← 绕到滤镜的最后一个", "\(kb.focus)")
        kb.hover = nil
        kb.tab = .film

        // ---------------------------------------------------------------- 8. 原图
        print("== 原图")
        var styled = store.project
        styled.style.filmGrain = 0.8
        styled.style.filmHalation = 0.5
        styled.style.harmonize = 0.4
        styled.pages[0].root.update(at: [1]) { $0.cell?.look = CollageLookSetting(look: .mono, strength: 1) }
        let orig = CollageDarkroom.original(styled, pageIndex: 0)
        let cellLooks = orig.pages[0].root.leafPaths().compactMap { orig.pages[0].root.node(at: $0)?.cell?.look }
        check(orig.style.look == .none && orig.style.filmGrain == 0 && orig.style.filmHalation == 0 && orig.style.harmonize == 0
              && orig.pages[0].look == nil && cellLooks.isEmpty, "原图：哪一级都不调色，颗粒、晕光、统一色温都是 0")
        check(orig.pages[0].root.leafPaths() == styled.pages[0].root.leafPaths() && orig.canvas == styled.canvas
              && orig.style.margin == styled.style.margin, "原图：版式、画布、边距照旧")

        // ---------------------------------------------------------------- 9. 撤销清选中、关掉
        print("== 撤销、关掉")
        store.selection = [0]
        kb.scope = .cell
        kb.apply(.filmRich)
        store.undo()
        check(store.selection == nil && kb.effectiveScope == .page, "撤销清掉选中：「这一格」退回这一页（相册）", "\(kb.effectiveScope)")
        kb.hover = .mono
        store.closeDarkroom()
        check(store.darkroom == nil, "关掉暗房：store.darkroom 是 nil")
        store.openDarkroom()
        check(store.darkroom?.hover == nil, "再打开：没有残留的悬停")
        store.closeDarkroom()

        // ---------------------------------------------------------------- 10. 换进光谱色调带上起始颗粒
        print("== 起始颗粒")
        let fresh = CollageStore(dataDir: appDataDir)
        var filtered = project(album: false)
        filtered.style.look = .film
        fresh.loadForTesting(filtered)
        fresh.openDarkroom()
        if let fd = fresh.darkroom, let d = CollageFilmEffects.defaults(.filmSunny), let cd = CollageFilmEffects.defaults(.cineDay) {
            fd.hover = .filmSunny
            let preview = fd.previewProject.style
            check(preview.filmGrain == d.grain && preview.filmHalation == d.halation && fresh.project.style.filmGrain == 0,
                  "悬停在光谱色调上：预览带上这一款的起始颗粒 / 晕光，工程不动",
                  String(format: "预览 %.2f / %.2f", preview.filmGrain, preview.filmHalation))
            let p1 = fresh.undoPushes
            fd.apply(.filmSunny)
            check(fresh.project.style == preview && fresh.undoPushes == p1 + 1, "套用：和预览一样（色调 + 起始颗粒晕光），一步撤销")
            fresh.undo()
            check(fresh.project.style.look == .film && fresh.project.style.filmGrain == 0 && fresh.project.style.filmHalation == 0,
                  "undo 一下：色调和颗粒晕光一起回去")
            fd.selectCell([0])
            let p2 = fresh.undoPushes
            fd.apply(.cineDay)
            check(fresh.project.pages[0].root.node(at: [0])?.cell?.look?.look == .cineDay
                  && fresh.project.style.filmGrain == cd.grain && fresh.undoPushes == p2 + 1,
                  "只给这一格换光谱色调：起始颗粒记在整组上，同一步撤销")
            fresh.undo()
            check(fresh.project.style.filmGrain == 0 && fresh.project.pages[0].root.node(at: [0])?.cell?.look == nil,
                  "undo 一下：这一格的色调和整组的颗粒一起回去")
        } else {
            check(false, "起始颗粒的准备（暗房打开、读得到起始值）")
        }
        fresh.closeDarkroom()

        finish(failures)
    }

    private static func finish(_ failures: [String]) -> Never {
        print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    /// 两格照片的拼图（相册 = 两个跨页），工程色调「暖肤」70%。照片文件不存在：只验状态。
    private static func project(album: Bool) -> CollageProject {
        var p = CollageProject()
        p.mode = album ? .album : .single
        p.photos = ["a", "b"].map { CollagePhotoRef(id: $0, path: "/nonexistent/\($0).jpg", width: 3000, height: 2000) }
        func cell(_ id: String) -> CollageCell {
            var c = CollageCell(kind: .photo)
            c.photoID = id
            return c
        }
        let page = CollagePage(root: .split(.row, 0.5, .leaf(cell("a")), .leaf(cell("b"))))
        p.pages = album ? [page, page] : [page]
        p.style.look = .filmWarmSkin
        p.style.lookStrength = 0.7
        return p
    }
}
