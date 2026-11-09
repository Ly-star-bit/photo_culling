import Foundation
import Combine
import CoreGraphics
import ImageIO

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
///    撤销按项、按手势合并：两根滑杆连着拖（0.6 秒以内）是两步；同一根拖、松手（endCoalescing）、再拖是两步；
///    强度、颗粒来回换，每换一根新开一步。
/// 7. ←→ 只在这一页签里按先后走、到头绕回，只预览不套用；⏎（apply(focus)）才套用；打开时页签跟着现在的色调。
/// 8. 原图：所有级别不调色、颗粒晕光统一色温都是 0，版式不变。
/// 9. 撤销清掉选中以后「这一格」退回上一级；关掉暗房清掉悬停。
/// 10. 从相纸滤镜换进光谱色调：悬停、套用都带上这一款的起始颗粒晕光。
/// 11. 暗房开着时画布预览记着脏、先不渲（画布不在视图树里），关暗房马上补渲；实时桥要预览（previewSettled）时现渲一张，
///     渲着的时候暗房里接着拖出来的不跟着渲（照旧攒着）。
/// 12. 「这款的数据没读到」：只问缓存，没读过的在后台读、读完再提示（不在主线程上解析表）。
/// 13. 1:1 细节只渲够得着的那一块，和渲整页再裁逐字节相同：合成照片，投影 + 圆角 + 模糊填（1 倍、0.75 倍）、抠图格、
///     卡纸 + 细线 + 纸纹、报纸网点、每张照片 + 整页水印、模板库的散落相纸和封面刊头，都套光谱色调 + 颗粒 + 晕光。
/// 14. 换跨页：到头不动、不进撤销，选中 / 悬停 / 放大镜位置清掉，暗房渲的每一类都换成新一页的。
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

        // ---------------------------------------------------------------- 6b. 撤销按项、按手势合并
        print("== 撤销按项、按手势合并")
        store.endCoalescing()
        let twoBefore = store.project.style
        p0 = store.undoPushes
        album.setStyleValue(\.filmGrain, 0.5)
        album.setStyleValue(\.filmGrain, 0.52)
        album.setStyleValue(\.filmHalation, 0.4)
        album.setStyleValue(\.filmHalation, 0.42)
        check(store.undoPushes == p0 + 2, "拖完颗粒马上拖晕光（0.6 秒以内）：两步撤销，不并成一步", "\(store.undoPushes - p0) 步")
        store.undo()
        check(store.project.style.filmHalation == twoBefore.filmHalation && store.project.style.filmGrain == 0.52,
              "撤一下：只有晕光回去，颗粒还是拖到的值",
              String(format: "颗粒 %.2f 晕光 %.2f", store.project.style.filmGrain, store.project.style.filmHalation))
        store.undo()
        check(store.project.style == twoBefore, "再撤一下：颗粒也回去")
        p0 = store.undoPushes
        album.setStyleValue(\.filmGrain, 0.3)
        album.setStyleValue(\.filmGrain, 0.33)
        store.endCoalescing()  // 松手（DarkroomSlider 的 DragGesture.onEnded）
        album.setStyleValue(\.filmGrain, 0.36)
        album.setStyleValue(\.filmGrain, 0.4)
        check(store.undoPushes == p0 + 2, "同一根滑杆拖一下、松手、再拖（0.6 秒以内）：两步撤销", "\(store.undoPushes - p0) 步")
        store.undo()
        check(store.project.style.filmGrain == 0.33, "撤一下回到松手时的值",
              String(format: "%.2f", store.project.style.filmGrain))
        store.endCoalescing()
        album.scope = .project
        p0 = store.undoPushes
        album.setStrength(0.55)
        album.setStyleValue(\.filmGrain, 0.45)
        album.setStrength(0.6)
        check(store.undoPushes == p0 + 3, "强度、颗粒、强度来回拖：每换一根滑杆新开一步", "\(store.undoPushes - p0) 步")
        store.endCoalescing()

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
        styled.style.filmExposure = 1
        styled.style.filmWarmth = -0.5
        styled.pages[0].root.update(at: [1]) { $0.cell?.look = CollageLookSetting(look: .mono, strength: 1) }
        let orig = CollageDarkroom.original(styled, pageIndex: 0)
        let cellLooks = orig.pages[0].root.leafPaths().compactMap { orig.pages[0].root.node(at: $0)?.cell?.look }
        check(orig.style.look == .none && orig.style.filmGrain == 0 && orig.style.filmHalation == 0 && orig.style.harmonize == 0
              && orig.style.filmExposure == 0 && orig.style.filmWarmth == 0 && orig.pages[0].look == nil && cellLooks.isEmpty,
              "原图：哪一级都不调色，颗粒、晕光、统一色温、冲印区都是 0")
        check(orig.pages[0].root.leafPaths() == styled.pages[0].root.leafPaths() && orig.canvas == styled.canvas
              && orig.style.margin == styled.style.margin, "原图：版式、画布、边距照旧")

        // ---------------------------------------------------------------- 8b. 冲印区、↺
        print("== 冲印区、↺")
        let pr = CollageDarkroom(store: store, rendering: false)
        pr.setStyleValue(\.filmExposure, 5, range: -1...2)
        pr.setStyleValue(\.filmWarmth, -3, range: -1...1)
        pr.setFormat(.f67)
        check(store.project.style.filmExposure == 2 && store.project.style.filmWarmth == -1 && store.project.style.filmFormat == .f67,
              "胶片曝光收在 +2、冷暖收在 −1、画幅换成 6×7（都改整组）")
        let pReset = store.undoPushes
        pr.resetTexture()
        let d = CollageFilmEffects.defaults(pr.current.look)
        check(store.project.style.filmExposure == 0 && store.project.style.filmWarmth == 0 && store.project.style.filmFormat == .f135
              && store.project.style.filmGrain == (d?.grain ?? 0) && store.project.style.filmHalation == (d?.halation ?? 0)
              && store.undoPushes == pReset + 1, "↺：颗粒晕光回到这一款的起始值、冲印区回到不动，一步撤销")

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

        // ---------------------------------------------------------------- 11. 暗房开着时画布预览攒着
        print("== 画布预览")
        let behind = CollageStore(dataDir: appDataDir)
        behind.loadForTesting(project(album: true))
        behind.openDarkroom()
        behind.darkroom?.stop()  // 只验 store：暗房自己不渲
        var grainier = behind.project.style
        grainier.filmGrain = 0.4
        behind.setStyle(grainier, coalesce: false)
        check(behind.previewDeferred && behind.previewIdle,
              "暗房开着：改了样式，画布预览记着脏、先不渲（画布不在视图树里）")
        behind.closeDarkroom()
        check(!behind.previewDeferred && !behind.previewIdle, "关暗房：攒着的画布预览马上补渲")
        func spin(_ seconds: Double, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        spin(10) { behind.previewIdle }
        // 实时桥（collage_get_state 带预览、写完回包带预览）先 previewSettled：暗房开着也现渲一张，不给暗房之前那张。
        behind.openDarkroom()
        behind.darkroom?.stop()
        let stalePreview = behind.preview
        grainier.filmGrain = 0.7
        behind.setStyle(grainier, coalesce: false)
        var settled: Bool?
        Task { @MainActor in settled = await behind.previewSettled(timeout: 5) }
        spin(10) { settled != nil }
        check(settled == true && !behind.previewDeferred && behind.preview != nil && behind.preview !== stalePreview,
              "暗房开着、实时桥要预览：previewSettled 现渲一张新的", "\(settled.map { "\($0)" } ?? "没等到")")
        // AI 写的时候用户正在暗房里拖滑杆：previewSettled 带起来的渲染循环只渲实时桥要的那一张，渲着的时候暗房里又拖出来
        // 的脏照旧攒着（以前循环只看脏不看暗房，拖一下渲一张，一直渲到松手）。等循环取走工程、那张正在后台渲
        // （previewRendering），马上在主线程上连着标脏三下 —— 那张渲完要回主线程，这三下一定落在「渲着的时候」。
        var canvasRenders = 0
        let counter = behind.previewState.$image.dropFirst().sink { _ in canvasRenders += 1 }
        grainier.filmGrain = 0.3
        behind.setStyle(grainier, coalesce: false)
        var requested: Bool?
        Task { @MainActor in requested = await behind.previewSettled(timeout: 5) }
        let started = Date().addingTimeInterval(5)
        while !behind.previewRendering && canvasRenders == 0 && Date() < started {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        let caughtRunning = behind.previewRendering && canvasRenders == 0
        for k in 1...3 {
            grainier.filmGrain = 0.3 + Double(k) * 0.01
            behind.setStyle(grainier, coalesce: true)
        }
        spin(10) { requested != nil }
        spin(0.5) { false }  // 以前的循环这时还在接着渲
        check(caughtRunning && requested == true && canvasRenders == 1 && behind.previewDeferred && behind.previewIdle,
              "暗房开着、实时桥要预览时用户接着拖：只渲实时桥要的那一张，接着拖出来的照旧攒着",
              "赶上渲着 \(caughtRunning) · 画布渲了 \(canvasRenders) 张 · 攒着 \(behind.previewDeferred)")
        behind.closeDarkroom()
        spin(10) { behind.previewIdle }
        counter.cancel()
        check(canvasRenders == 2 && !behind.previewDeferred, "关暗房：攒着的那几下补渲成一张", "画布一共 \(canvasRenders) 张")

        // ---------------------------------------------------------------- 12. 数据没读到的提示
        print("== 数据没读到的提示")
        // 放表的目录指到一个空目录（漏打包）：右栏的提示不在主线程上现读 —— 一打开先空着，后台读完再给。
        let empty = appDataDir.appendingPathComponent("darkroom-selftest-no-luts")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        CollageFilmLUTs.directoryOverride = empty
        CollageFilmLUTs.resetForTesting()
        CollageFilmEffects.resetForTesting()
        let cold = CollageStore(dataDir: appDataDir)
        cold.loadForTesting(project(album: false))
        let blind = CollageDarkroom(store: cold, rendering: false)
        check(blind.dataMissing.isEmpty, "一打开：提示不在主线程上现读（先空着，后台去读）")
        spin(5) { !blind.probingData }
        check(blind.dataMissing == [.filmWarmSkin], "后台读完：「暖肤」的数据没读到，提示出来", "\(blind.dataMissing.map(\.rawValue))")
        CollageFilmLUTs.directoryOverride = nil
        CollageFilmLUTs.resetForTesting()
        CollageFilmEffects.resetForTesting()
        let found = CollageDarkroom(store: cold, rendering: false)
        spin(30) { !found.probingData }
        func said(_ v: Bool?) -> String { v.map { $0 ? "读到" : "读不到" } ?? "没读过" }
        let states = "色调表 \(said(CollageFilmLUTs.cachedState(.filmWarmSkin))) · 颗粒数据 "
            + said(CollageFilmEffects.cachedState(.filmWarmSkin))
        check(found.dataMissing.isEmpty && CollageFilmLUTs.cachedState(.filmWarmSkin) == true
              && CollageFilmEffects.cachedState(.filmWarmSkin) == true, "表在：后台读到了，不提示", states)
        let cached = CollageDarkroom(store: cold, rendering: false)
        check(!cached.probingData && cached.dataMissing.isEmpty, "读过的只问缓存，当场就对（不再派后台读）")

        // ---------------------------------------------------------------- 13. 1:1 细节只渲那一块
        print("== 1:1 细节只渲够得着的那一块：和渲整页再裁逐字节比")
        let photos = syntheticPhotos(check)
        if let photos { loupeIdentity(photos, check) }

        // ---------------------------------------------------------------- 14. 换跨页
        print("== 换跨页")
        pageTurn(photos, check, spin: spin)

        finish(failures)
    }

    /// 14. 暗房里换跨页（顶栏的 ‹ ›、⌘← ⌘→）：到头不动、不进撤销；换过去选中清掉（「这一格」退回这一页）、悬停和放大镜
    /// 位置清掉，样张、试条的照片换成新一页的主图；暗房开着渲的那几类（大预览、原图、1:1 细节、底片条、样张）都换成新一页的。
    @MainActor
    private static func pageTurn(_ photos: [CollagePhotoRef]?, _ check: (Bool, String, String) -> Void,
                                 spin: (Double, () -> Bool) -> Void) {
        var two = project(album: true)
        two.photos[0].score = 2
        two.photos[1].score = 1
        two.pages[1] = CollagePage(root: .leaf(.photo("b")))
        let nav = CollageStore(dataDir: appDataDir)
        nav.loadForTesting(two)
        let dn = CollageDarkroom(store: nav, rendering: false)
        check(dn.pageCount == 2 && !dn.canGoBack && dn.canGoForward, "两个跨页、在第 1 个：上一跨页灰掉、下一跨页能点", "")
        nav.selection = [0]
        dn.scope = .cell
        dn.loupeAnchor = CGPoint(x: 5, y: 5)
        dn.hover = .mono
        let subject = dn.subjectPhotoID
        let pushes = nav.undoPushes
        dn.goToPage(1)
        check(nav.pageIndex == 1 && nav.selection == nil && dn.effectiveScope == .page && dn.loupeAnchor == nil
              && dn.hover == nil && nav.undoPushes == pushes,
              "下一跨页：换到第 2 个，选中清掉、「这一格」退回这一页，悬停和放大镜位置清掉，不进撤销", "\(dn.effectiveScope)")
        check(subject == "a" && dn.subjectPhotoID == "b", "样张、试条的照片换成新一页的主图",
              "\(subject ?? "无") → \(dn.subjectPhotoID ?? "无")")
        dn.goToPage(1)
        check(nav.pageIndex == 1 && dn.canGoBack && !dn.canGoForward, "在最后一个跨页：下一跨页不动、灰掉", "")
        dn.goToPage(-1)
        check(nav.pageIndex == 0, "上一跨页回到第 1 个", "")

        // 真渲：合成照片的两个跨页，暗房开着换过去，每一类都换成新一页的。
        guard let photos else { return }
        var album = CollageProject()
        album.mode = .album
        album.photos = photos
        album.canvas = CollageCanvas(name: "自检 3:2", width: 1500, height: 1000)
        album.style.look = .filmWarmSkin
        album.style.filmGrain = 0.6
        album.pages = [CollagePage(root: .split(.row, 0.5, .leaf(.photo("p1")), .leaf(.photo("p2")))),
                       CollagePage(root: .leaf(.photo("p3")))]
        let live = CollageStore(dataDir: appDataDir)
        live.loadForTesting(album)
        live.openDarkroom()
        guard let dr = live.darkroom else {
            check(false, "真渲：暗房打开", "")
            return
        }
        func settled() -> Bool { !dr.busy && dr.processed != nil && dr.loupe != nil && !dr.reel.isEmpty && !dr.frames.isEmpty }
        spin(0.6) { false }
        spin(60) { settled() }
        let before = (dr.processed, dr.original, dr.loupe, dr.frames[.filmWarmSkin], dr.reel.map(\.photoID))
        dr.goToPage(1)
        spin(0.6) { false }
        spin(60) { settled() }
        check(before.4 == ["p1", "p2"] && dr.reel.map(\.photoID) == ["p3"] && dr.processed !== before.0
              && dr.original !== before.1 && dr.loupe !== before.2 && dr.frames[.filmWarmSkin] !== before.3
              && dr.subjectPhotoID == "p3",
              "真渲：换到第 2 个跨页，大预览、原图、1:1 细节、样张、底片条都换成新一页的",
              "底片条 \(before.4) → \(dr.reel.map(\.photoID))")
        // 真 1:1：视图报来屏幕是 2 倍，1:1 细节渲两倍边长的导出像素，图还是 loupeSide pt 见方。
        let small = dr.loupe
        dr.loupeDensity = 2
        spin(0.6) { false }
        spin(60) { settled() && dr.loupe !== small }
        let px = dr.loupe?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width ?? 0
        check(small?.size.width == CGFloat(CollageDarkroom.loupeSide) && px == CollageDarkroom.loupeSide * 2
              && dr.loupe?.size.width == CGFloat(CollageDarkroom.loupeSide),
              "Retina：1:1 细节渲 \(CollageDarkroom.loupeSide * 2)² 个导出像素、显示 \(CollageDarkroom.loupeSide) pt（一个导出像素 = 一个屏幕像素）",
              "\(px) 像素 · \(Int(dr.loupe?.size.width ?? 0)) pt")
        live.closeDarkroom()
    }

    /// 13. 1:1 细节（Options.region：离那一块远的格子不出图）和渲整页再裁逐字节相同。region 的安全边距是按效果估的
    /// （CollageRender 的 regionPad：投影、出血），以后哪个效果画出了这个范围，1:1 细节会悄悄缺一块 —— 以前只在
    /// --perf darkroom 里打印 PASS / FAIL，不影响退出码。合成照片（渐变天、硬边柱子、高光点：颗粒、晕光、锐化、
    /// Lanczos 都有东西可算）写进隔离的数据目录；每种模板都套光谱色调 + 颗粒 + 晕光，量每格中心、每格左上角（缝、投影
    /// 落的地方）、九宫点、画布四角、散落版每张相纸的中心。
    @MainActor
    private static func loupeIdentity(_ synthetic: [CollagePhotoRef], _ check: (Bool, String, String) -> Void) {
        guard CollageFilmEffects.extras(.filmWarmSkin) != nil else {
            check(false, "准备：光谱色调的颗粒、晕光数据读得到（third_party/film-luts）", "")
            return
        }
        var photos = synthetic
        // 抠图格那张：一张脸 + 一直到底边的身子（合成蒙版，不跑 Vision）。
        let face: [Double] = [0.42, 0.2, 0.58, 0.36]
        photos[3].faces = [face]
        let mw = 256, mh = 256
        var mask = [UInt8](repeating: 0, count: mw * mh)
        for y in 0..<mh {
            for x in 0..<mw {
                let u = (Double(x) + 0.5) / Double(mw), v = (Double(y) + 0.5) / Double(mh)
                let du = (u - 0.5) / 0.1, dv = (v - 0.28) / 0.1
                if du * du + dv * dv <= 1 || (u >= 0.3 && u <= 0.7 && v >= 0.36) { mask[y * mw + x] = 255 }
            }
        }
        CollageMasks.inject(CollageMasks.synthetic(mask, width: mw, height: mh, faces: [face]), for: photos[3])

        let canvas = CollageCanvas(name: "自检 3:2", width: 1500, height: 1000)
        func project(_ style: CollageStyle, root: CollageNode, canvas: CollageCanvas = canvas) -> CollageProject {
            var p = CollageProject()
            p.photos = photos
            p.canvas = canvas
            p.style = style
            p.style.look = .filmWarmSkin
            p.style.lookStrength = 0.8
            p.style.filmGrain = 0.6
            p.style.filmHalation = 0.5
            p.pages = [CollagePage(root: root)]
            return p
        }
        func cell(_ id: String) -> CollageNode { .leaf(.photo(id)) }

        var cases: [(name: String, project: CollageProject, scale: Double)] = []
        // 投影（最重的那一档）+ 圆角 + 完整显示带本图模糊填：投影是 region 外扩的主要原因。
        var shadow = CollageStyles.preset("grid")
        shadow.shadow = 1
        shadow.corner = 0.02
        shadow.margin = 0.05
        shadow.gutter = 0.03
        var blurred = CollageCell.photo("p2")
        blurred.contain = true
        blurred.containBlur = true
        let grid = CollageNode.split(.row, 0.55, cell("p1"), .split(.column, 0.5, .leaf(blurred), cell("p3")))
        cases.append(("投影 + 圆角 + 模糊填", project(shadow, root: grid), 1))
        cases.append(("投影 + 圆角 + 模糊填（0.75 倍导出）", project(shadow, root: grid), 0.75))
        // 大边距里只够得着投影、够不着照片的那一块（下面另加贴着四边外面的几处）：region 的外扩就是为它留的。
        var wide = shadow
        wide.margin = 0.32
        let roomy = CollageCanvas(name: "自检 大边距", width: 2400, height: 1600)
        cases.append(("大边距 + 投影（那一块只落在投影上）", project(wide, root: cell("p1"), canvas: roomy), 1))
        // 抠图格：白边 + 投影，主体切图要整张 tile。
        var cutout = CollageCell.photo("p4")
        cutout.cutout = CollageCutout(stroke: 0.01, shadow: 0.6)
        var plain = CollageStyles.preset("grid")
        plain.margin = 0
        plain.gutter = 0.01
        cases.append(("抠图格（白边、投影）", project(plain, root: .split(.row, 0.5, .leaf(cutout), cell("p1"))), 1))
        // 婚礼 fine-art：卡纸 + 细线（画在照片外面）+ 纸纹压照片。
        cases.append(("卡纸 + 细线 + 纸纹",
                      project(CollageStyleFineArt.style, root: .split(.row, 0.5, cell("p1"), cell("p3"))), 1))
        // 报纸风网点：加网替代锐化。
        var screened = CollageStyles.preset("grid")
        screened.halftone = CollageHalftone()
        cases.append(("报纸网点", project(screened, root: .split(.row, 0.5, cell("p1"), cell("p2"))), 1))
        // 每张照片 + 整页的水印（字 + 签名），压在投影那一版上。
        var marked = project(shadow, root: grid)
        var wm = CollageStyleFilmSelfTest.pageWatermark(.bottomRight, signature: CollageStyleFilmSelfTest.makeSignature())
        var text = CollageMarkText()
        text.customText = "© 自检"
        text.position = .bottomLeft
        var layer = CollageMarkLayer()
        layer.position = .bottomLeft
        layer.text = text
        wm.photos = layer
        marked.watermark = wm
        cases.append(("每张照片 + 整页水印", marked, 1))
        // 模板库里的两种：散落相纸（相纸带投影、图层）、封面刊头（压字）。
        let map = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        for name in ["手账 · 胶片散落", "封面 · 刊头大图"] {
            guard let template = CollageTemplates.find(name) else {
                check(false, "准备：模板「\(name)」找得到", "")
                continue
            }
            let c = template.canvas ?? canvas
            let style = template.style ?? CollageStyles.preset("grid")
            let page = CollageTemplates.apply(template, photos: photos,
                                              context: CollageLayout.Context(canvas: c, style: style, photos: map))
            var p = project(style, root: page.root, canvas: c)
            p.pages = [page]
            p.title = "自检"
            // 印刷画布（几千像素）缩到长边约 1500 再比：核对的是 region，不是尺寸。
            cases.append(("模板「\(name)」", p, min(1, 1500 / Double(max(c.width, c.height)))))
        }

        // 模板真的走到了要核对的那条路（出图记录）：抠图格用主体蒙版抠了、网点出了点、两层水印都画了。
        func report(_ name: String) -> CollageRender.RenderReport? {
            guard let c = cases.first(where: { $0.name.hasPrefix(name) }) else { return nil }
            var opts = CollageDarkroom.loupeOptions(scale: c.scale)
            let r = CollageRender.RenderReport()
            opts.report = r
            _ = CollageRender.render(page: c.project.pages[0], project: c.project, hints: [:], options: opts)
            return r
        }
        check(report("抠图格")?.masks.contains { $0.cutout } == true, "准备：抠图格真的按主体蒙版抠了", "")
        check(report("报纸网点")?.halftone.contains { $0.screened } == true, "准备：报纸网点真的出了点", "")
        let layers = Set(report("每张照片")?.marks.filter { $0.kind != nil }.map(\.layer) ?? [])
        check(layers == ["photo", "page"], "准备：每张照片、整页两层水印都画了", layers.sorted().joined(separator: "、"))

        // 原图解码缓存（1:1 细节停手一次渲一次）：同一处再渲一次一张原图都不重解；那一块只落在投影上：照片不解码。
        if let roomyCase = cases.first(where: { $0.name.hasPrefix("大边距") }),
           let f = CollageLayout.pageGeometry(roomyCase.project.pages[0].root, canvas: roomy, style: wide).frames.first {
            let p = roomyCase.project
            let cache = CollageImages.Recent(capacity: 2)
            let middle = CGPoint(x: Double(f.rect.x0 + f.rect.x1) / 2, y: Double(f.rect.y0 + f.rect.y1) / 2)
            func loupe(_ at: CGPoint) {
                _ = CollageDarkroom.loupeImage(p, pageIndex: 0, fallback: p.pages[0], hints: [:], scale: 1, center: at,
                                               originals: cache)
            }
            loupe(middle)
            let first = (cache.hits, cache.misses)
            loupe(middle)
            check(first == (0, 1) && cache.hits == 1 && cache.misses == 1, "原图缓存：同一处再渲一次，原图不重解",
                  "第一次 现解 \(first.1) · 第二次之后 命中 \(cache.hits) 现解 \(cache.misses)")
            let below = CGPoint(x: middle.x, y: Double(f.rect.y1) + Double(CollageDarkroom.loupeSide) + 6)
            let fresh = CollageImages.Recent(capacity: 2)
            _ = CollageDarkroom.loupeImage(p, pageIndex: 0, fallback: p.pages[0], hints: [:], scale: 1, center: below,
                                           side: CollageDarkroom.loupeSide * 2, originals: fresh)
            check(fresh.hits + fresh.misses == 0, "那一块只落在照片的投影上：照片不解码、不出图", "解了 \(fresh.misses) 张")
        }

        // 两种边长：普通屏 loupeSide、Retina 两倍（真 1:1：一个导出像素 = 一个屏幕像素）。
        for c in cases {
            for side in [CollageDarkroom.loupeSide, CollageDarkroom.loupeSide * 2] {
                let p = c.project
                let w = Double(p.canvas.width), h = Double(p.canvas.height)
                var centers: [CGPoint] = []
                for fy in [1.0 / 6, 0.5, 5.0 / 6] {
                    for fx in [1.0 / 6, 0.5, 5.0 / 6] { centers.append(CGPoint(x: w * fx, y: h * fy)) }
                }
                centers += [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)]
                // 贴着格子四边外面、刚好碰不到照片的那一块（中心离边 side / 2 + 6 个渲染像素）：只有投影落得进去。
                let off = (Double(side) / 2 + 6) / c.scale
                for f in CollageLayout.pageGeometry(p.pages[0].root, canvas: p.canvas, style: p.style).frames {
                    let r = f.rect
                    let mx = Double(r.x0 + r.x1) / 2, my = Double(r.y0 + r.y1) / 2
                    centers.append(CGPoint(x: mx, y: my))
                    centers.append(CGPoint(x: Double(r.x0), y: Double(r.y0)))
                    centers += [CGPoint(x: mx, y: Double(r.y1) + off), CGPoint(x: Double(r.x1) + off, y: my),
                                CGPoint(x: mx, y: Double(r.y0) - off), CGPoint(x: Double(r.x0) - off, y: my)]
                }
                for item in p.pages[0].items where item.kind == .photo {
                    centers.append(CGPoint(x: item.cx * w, y: item.cy * h))
                }
                let results = CollageDarkroom.loupeIdentity(p, pageIndex: 0, fallback: p.pages[0], hints: [:],
                                                            scale: c.scale, centers: centers, side: side)
                let bad = zip(centers, results).filter { !$0.1 }.map { "(\(Int($0.0.x)),\(Int($0.0.y)))" }
                check(bad.isEmpty,
                      "\(c.name)（\(side)²）：\(results.count - bad.count) / \(results.count) 处和渲整页再裁逐字节相同",
                      bad.isEmpty ? "" : "不同：" + bad.joined(separator: " "))
            }
        }
    }

    /// 四张合成照片（p1–p4：横、竖、横、方）写进隔离的数据目录，主图分数 p1 最高。写不出来 = nil。
    private static func syntheticPhotos(_ check: (Bool, String, String) -> Void) -> [CollagePhotoRef]? {
        let dir = appDataDir.appendingPathComponent("darkroom-selftest-photos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var photos: [CollagePhotoRef] = []
        for (i, size) in [(1500, 1000), (1000, 1500), (1500, 1000), (1200, 1200)].enumerated() {
            let url = dir.appendingPathComponent("p\(i + 1).jpg")
            guard writePhoto(url, width: size.0, height: size.1, variant: i) else {
                check(false, "准备：合成照片写得出来", url.lastPathComponent)
                return nil
            }
            var p = CollagePhotoRef(id: "p\(i + 1)", path: url.path, width: size.0, height: size.1)
            p.score = Double(4 - i)
            photos.append(p)
        }
        return photos
    }

    /// 合成照片：竖向渐变的天、暖色地面、一个过曝的太阳（晕光）、几根深色柱子（硬边：锐化、Lanczos）、一块红、一个
    /// 肤色椭圆。variant 换颜色和位置。写成 JPEG。
    private static func writePhoto(_ url: URL, width: Int, height: Int, variant: Int) -> Bool {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CollageRender.srgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        let w = CGFloat(width), h = CGFloat(height)
        let k = CGFloat(variant) * 0.07
        let sky = CGGradient(colorsSpace: CollageRender.srgb,
                             colors: [CGColor(srgbRed: 0.85, green: 0.9, blue: 0.95, alpha: 1),
                                      CGColor(srgbRed: 0.12 + k, green: 0.3, blue: 0.72 - k, alpha: 1)] as CFArray,
                             locations: [0, 1])
        let ground = CGGradient(colorsSpace: CollageRender.srgb,
                                colors: [CGColor(srgbRed: 0.25, green: 0.18 + k, blue: 0.1, alpha: 1),
                                         CGColor(srgbRed: 0.62, green: 0.5, blue: 0.32 + k, alpha: 1)] as CFArray,
                                locations: [0, 1])
        // CG 的原点在左下：天在上面 60%。
        if let sky { ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.4), end: CGPoint(x: 0, y: h), options: []) }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h * 0.4))
        if let ground { ctx.drawLinearGradient(ground, start: .zero, end: CGPoint(x: 0, y: h * 0.4), options: []) }
        ctx.restoreGState()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0.97, alpha: 1))
        let r = min(w, h) * 0.06
        ctx.fillEllipse(in: CGRect(x: w * (0.68 - k) - r, y: h * 0.78 - r, width: 2 * r, height: 2 * r))
        ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.06, blue: 0.06, alpha: 1))
        for i in 0..<5 {
            ctx.fill(CGRect(x: w * (0.08 + 0.18 * CGFloat(i) + k / 3), y: h * 0.1, width: w * 0.02, height: h * 0.5))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.78, green: 0.12, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: w * 0.15, y: h * (0.45 + k), width: w * 0.12, height: h * 0.1))
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.76, blue: 0.64, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 0.42, y: h * 0.3, width: w * 0.16, height: h * 0.3))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest)
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
