import Foundation

/// LABELGUI_DATA_DIR=<临时> LabelGUI --darkroom-selftest
///
/// 暗房（CollageDarkroom）的规则，只验状态、不渲染（渲染看 --collage-ui --darkroom 的快照），不要照片：
/// 1. 看片台：四组（负片 6、反转片 3、电影负片 1、滤镜 12）合起来正好是全部色调、每个一次；光谱色调只在三组胶片里，
///    滤镜里一个都没有；片边字只有 ▶帧号 + 名字（帧号 1…10，没有 ISO、型号、品牌）。
/// 2. 打开：整组、看到的就是工程的色调；单张拼图没有「这一页」，没选格子「这一格」退回整组。
/// 3. 悬停只是预览：工程、撤销步数都不动，预览用的工程里这一级换成了悬停的色调。
/// 4. 套用：整组 / 这一页 / 这一格各改各的那一级，一次一步撤销，undo 一下回去。
/// 5. 强度：这一页还没有自己的色调时拖强度 = 用现在看到的色调 + 新强度给这一页设上；连拖合成一步。
/// 6. 颗粒、晕光、统一色温永远改整组，选「这一格」也一样。
/// 7. ←→ 按看片台的先后走、到头绕回，只预览不套用；⏎（apply(focus)）才套用。
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

        // ---------------------------------------------------------------- 1. 看片台
        print("== 看片台")
        let order = CollageDarkroom.order
        check(order.count == CollageLook.allCases.count && Set(order) == Set(CollageLook.allCases),
              "四组合起来正好是全部色调、每个一次", "\(order.count) / \(CollageLook.allCases.count)")
        let counts = CollageDarkroom.groups.map { "\($0.title)\($0.looks.count)" }.joined(separator: " ")
        check(counts == "负片6 反转片3 电影负片1 滤镜12", "分组和张数", counts)
        for group in CollageDarkroom.groups {
            let film = group.kind != .filter
            check(group.looks.allSatisfy { $0.isSpectral == film },
                  film ? "「\(group.title)」里都是光谱胶片" : "「滤镜」里没有光谱胶片（滤镜没有颗粒、晕光，不穿底片外衣）")
        }
        let numbers = order.compactMap(CollageDarkroom.frameNumber)
        check(numbers == Array(1...10), "帧号 1…10 只给光谱胶片", "\(numbers)")
        let brands = ["KODAK", "FUJI", "ILFORD", "PORTRA", "EKTAR", "VELVIA", "PROVIA", "VISION", "ISO", "柯达", "富士"]
        for look in order {
            let text = CollageDarkroom.edgeText(look)
            let digits = text.filter(\.isNumber)
            let expected = CollageDarkroom.frameNumber(look).map(String.init) ?? ""
            check(digits == expected && !brands.contains(where: { text.uppercased().contains($0) }),
                  "片边字「\(text)」只有帧号和名字")
        }
        check(!CollageDarkroom.rebateText.contains(where: \.isNumber), "片边通用字没有数字", CollageDarkroom.rebateText)

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
        kb.focus = order[0]
        kb.moveFocus(-1)
        check(kb.focus == order.last && kb.hover == order.last, "← 在第一个：绕到最后一个，大预览跟着看")
        kb.moveFocus(1)
        check(kb.focus == order[0], "→ 再绕回第一个")
        let pk = store.project
        kb.moveFocus(3)
        check(store.project == pk, "←→ 只预览，不套用")
        kb.scope = .project
        kb.apply(kb.focus)
        check(store.project.style.look == order[3] && kb.hover == nil, "⏎ 套用焦点那一格，悬停清掉")

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
