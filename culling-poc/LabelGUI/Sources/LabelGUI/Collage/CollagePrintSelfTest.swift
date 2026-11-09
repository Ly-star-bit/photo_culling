import Foundation
import CoreGraphics
import ImageIO
import PDFKit

/// --collage-export-selftest 里相册 B · P 道那几段（合成数据，不读照片）：
/// 1. 导出范围解析（「1-3, 7」、反着写、中文标点、越界、写错）和显示；
/// 2. 页数规则（合规、少了、多了、步长不对）、规则的容错解码、旧画布读回来没有规则、nil 不写进 JSON；
///    内置规格：短名、名字不重复，前四个尺寸和以前的四个相册画布像素一样；默认规则下中缝带和以前一样（求解不变）；
///    「存成规格」量回来再套上去像素不变；
/// 3. 导出前检查各种类：空照片格、页数、用了两次、放大（拦 / 提醒）、脸压中缝（胶装拦 / 平铺提醒）、贴边没铺出血、
///    首尾单页、字出安全区；导出确认框（只有空格时和以前一字不差、有别的列前几条、部分导出只看那几页）；
///    reveal 换页、选中那一格；
/// 4. 色彩：sRGB（没规格 / 显式 sRGB）导出的 JPEG 和照旧编码的逐字节一样；Adobe RGB 导出的跨页 JPEG / PNG 读回来
///    配置文件是 Adobe RGB (1998)、JPEG 是基线，PDF 里那页图的 ICC 是 Adobe RGB；
/// 5. 部分导出：只写选中的跨页（序号是原跨页号）、不出 PDF、重名只看要写的那几个；
/// 6. 看版 PDF：页数、每页尺寸、页脚「跨页 N / M · 标题」和照片文件名（阅读顺序，PDFKit 读出来）、同名加 -2、不留临时文件。
enum CollagePrintSelfTest {
    typealias Checks = CollageExportSelfTest.Checks

    @MainActor
    static func run(_ store: CollageStore, root: URL, check: Checks) {
        print("== 导出范围")
        ranges(check: check)
        print("== 页数规则 / 印厂规格")
        rules(check: check)
        print("== 导出前检查")
        preflight(check: check)
        preflightStore(store, check: check)
        print("== 色彩（sRGB 不变 / Adobe RGB）")
        color(store, root.appendingPathComponent("color"), check: check)
        print("== 只导某几个跨页")
        partial(store, root.appendingPathComponent("partial"), check: check)
        print("== 看版 PDF")
        proof(store, root.appendingPathComponent("proof"), check: check)
    }

    // MARK: - 1. 范围

    private static func ranges(check: Checks) {
        func parse(_ s: String, _ n: Int) -> [Int]? { try? CollageExportRange.parse(s, count: n).get() }
        check(parse("1-3, 7", 10) == [0, 1, 2, 6], "「1-3, 7」→ 第 1、2、3、7 个", "\(parse("1-3, 7", 10) ?? [])")
        check(parse("3-1；5，5、 8~9", 10) == [0, 1, 2, 4, 7, 8], "反着写、中文标点、重复、~ 都认",
              "\(parse("3-1；5，5、 8~9", 10) ?? [])")
        check(parse("1–3", 3) == [0, 1, 2], "长横（–）也认")
        for bad in ["", "0", "11", "a", "1-3-5", "2-", "-2", "1.5"] {
            check(parse(bad, 10) == nil, "写错的不认：「\(bad)」")
        }
        if case .failure(let e) = CollageExportRange.parse("12", count: 10) {
            check(e.message.contains("一共 10 个跨页"), "越界说一共几个", e.message)
        }
        check(CollageExportRange.label([0, 1, 2, 6]) == "1–3、7" && CollageExportRange.label([4]) == "5",
              "显示：连着的并成一段", CollageExportRange.label([0, 1, 2, 6]))
        check((try? CollageExportRange.all.resolve(pageCount: 5, current: 2).get()) == .some(nil), "全部 = nil")
        check((try? CollageExportRange.current.resolve(pageCount: 5, current: 2).get()) == .some([2]), "当前跨页")
        check((try? CollageExportRange.current.resolve(pageCount: 0, current: 0).get()) == nil, "没有跨页时当前跨页算错")
    }

    // MARK: - 2. 页数规则 / 规格

    private static func rules(check: Checks) {
        let std = CollagePrintRules.standard
        check(std.pageProblem(spreads: 10) == nil && std.pageProblem(spreads: 30) == nil && std.pageProblem(spreads: 17) == nil,
              "20–60P：10、17、30 个跨页都合规")
        let over = std.pageProblem(spreads: 34) ?? ""
        check(over.hasPrefix("印厂要 20–60P、每次加 2P；现在 34 个跨页 = 68P，多了 8P"), "多了：两种单位都写", over)
        let under = std.pageProblem(spreads: 4) ?? ""
        check(under.contains("现在 4 个跨页 = 8P，少了 12P") && under.contains("再加 6 个跨页"), "少了", under)
        var four = CollagePrintRules()
        four.pageStep = 4
        let step = four.pageProblem(spreads: 11) ?? ""
        check(step.contains("22P") && step.contains("每次加 4P") && step.contains("再加 2P") && step.contains("减 2P"),
              "步长不对：再加 / 减几 P", step)
        check(four.pageProblem(spreads: 12) == nil, "24P 合每次加 4P")
        check(std.pageProblem(spreads: 0) == nil, "没有跨页不报")

        // 容错解码：坏值按范围收、不认识的色彩 = sRGB；旧画布没有这个键 = nil；nil 不写进 JSON。
        let bad = #"{"minPages": 1, "maxPages": 9000, "pageStep": 0, "colorSpace": "cmyk", "layflatFoldMM": -3, "jpegQuality": 3}"#
        let decoded = try? JSONDecoder().decode(CollagePrintRules.self, from: Data(bad.utf8))
        check(decoded?.minPages == 2 && decoded?.maxPages == 2000 && decoded?.pageStep == 1 && decoded?.colorSpace == .sRGB
              && decoded?.layflatFoldMM == 0 && decoded?.jpegQuality == 1,
              "规则坏值按范围收", "\(String(describing: decoded))")
        let oldCanvas = #"{"name": "相册 30×30cm 跨页", "width": 7087, "height": 3543, "dpi": 300, "bleed": 35, "safe": 59, "seams": "fold", "slides": 1, "binding": "glued"}"#
        let old = try? JSONDecoder().decode(CollageCanvas.self, from: Data(oldCanvas.utf8))
        check(old != nil && old?.printRules == nil && old?.binding == .glued, "旧画布读回来：没有规则（nil）")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = (try? encoder.encode(CollageCanvas.albums[0])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!plain.contains("printRules"), "没有规则的画布存出来没有 printRules 这个键（旧工程字节不变）")
        var ruled = CollageCanvas.albums[0]
        ruled.printRules = CollagePrintRules()
        ruled.printRules?.colorSpace = .adobeRGB
        let round = (try? encoder.encode(ruled)).flatMap { try? JSONDecoder().decode(CollageCanvas.self, from: $0) }
        check(round?.printRules?.colorSpace == .adobeRGB, "带规则的画布存了读回来还在")

        // 默认规则下中缝带和以前一样（求解、避脸不变）；填了 mm 才照它。
        var same = true
        for base in CollageCanvas.albums {
            for binding in CollageBinding.allCases {
                var a = base
                a.binding = binding
                var b = a
                b.printRules = .standard
                if a.foldBand != b.foldBand || CollageLayout.seamLines(a) != CollageLayout.seamLines(b) { same = false }
            }
        }
        check(same, "默认规则：四个相册画布两种装订的中缝带和以前一样")
        var custom = CollageCanvas.albums[0]
        custom.printRules = CollagePrintRules()
        custom.printRules?.layflatFoldMM = 8
        check(abs(custom.foldBand - custom.pixels(mm: 8)) < 0.001, "填了平铺中缝带 8mm 就照它",
              String(format: "%.1f", custom.foldBand))
        custom.binding = .glued
        check(abs(custom.foldBand - max(custom.shortSide * 0.02, custom.pixels(mm: 12))) < 0.001,
              "胶装那个没填：照老算法（至少 12mm）")

        // 内置规格。
        let builtin = CollagePrintSpec.builtin
        check(Set(builtin.compactMap(\.key)).count == builtin.count && Set(builtin.map(\.name)).count == builtin.count,
              "内置规格短名、名字都不重复（\(builtin.count) 条）")
        let firstFour = builtin.filter { $0.binding == .layflat }.prefix(4).map(\.canvas)
        let geometry = zip(firstFour, CollageCanvas.albums).allSatisfy { a, b in
            a.width == b.width && a.height == b.height && a.dpi == b.dpi && a.bleed == b.bleed && a.safe == b.safe
                && a.seams == b.seams
        }
        check(geometry, "前四个尺寸和以前的四个相册画布像素一样")
        check(builtin.allSatisfy { $0.rules == .standard }, "内置规格的规则都是保守默认")
        check(CollagePrintSpec.find("sq25-glued", in: [])?.name == "方册 25×25 胶装"
              && CollagePrintSpec.find("方册 30×30 平铺", in: [])?.key == "sq30-flat", "按短名、名字都找得到")
        // 「存成规格」量回来再套上去：像素不变。
        var mine = CollageCanvas.albums[3]
        mine.binding = .glued
        mine.printRules = CollagePrintRules()
        mine.printRules?.colorSpace = .adobeRGB
        let saved = CollagePrintSpec(name: "我的", canvas: mine).canvas
        check(saved.width == mine.width && saved.height == mine.height && saved.bleed == mine.bleed
              && saved.safe == mine.safe && saved.binding == .glued && saved.printRules?.colorSpace == .adobeRGB,
              "存成规格再套回来：尺寸、出血、安全区、装订、规则都一样", "\(saved.width)x\(saved.height) vs \(mine.width)x\(mine.height)")
        let specJSON = try? JSONEncoder().encode([CollagePrintSpec(name: "我的", canvas: mine)])
        let specBack = specJSON.flatMap { try? JSONDecoder().decode([CollageLossy<CollagePrintSpec>].self, from: $0) }
        check(specBack?.first?.value?.canvas.width == mine.width, "存的规格读回来")
        let broken = #"[{"name": "坏的", "pageWidthCM": 999, "pageHeightCM": 30}, {"name": "好的", "pageWidthCM": 30, "pageHeightCM": 30}]"#
        let lossy = (try? JSONDecoder().decode([CollageLossy<CollagePrintSpec>].self, from: Data(broken.utf8)))?
            .compactMap(\.value)
        check(lossy?.map(\.name) == ["好的"], "坏了的规格只丢它自己", "\(lossy?.map(\.name) ?? [])")
    }

    // MARK: - 3. 导出前检查

    static func photo(_ id: String, w: Int = 3000, h: Int = 2000, faces: [[Double]] = []) -> CollagePhotoRef {
        var p = CollagePhotoRef(id: id, path: "/nonexistent/selftest/\(id).jpg", width: w, height: h)
        p.faces = faces
        return p
    }

    private static func cell(_ id: String?) -> CollageCell {
        var c = CollageCell(kind: .photo)
        c.photoID = id
        return c
    }

    /// 相册（自检跨页画布），每个跨页左右两格。
    private static func album(_ pages: [(String?, String?)], photos: [CollagePhotoRef],
                              canvas: CollageCanvas = CollageExportSelfTest.smallSpread) -> CollageProject {
        var p = CollageProject()
        p.mode = .album
        p.canvas = canvas
        p.title = "自检相册"
        p.photos = photos
        p.pages = pages.map { CollagePage(root: .split(.row, 0.5, .leaf(cell($0.0)), .leaf(cell($0.1)))) }
        return p
    }

    private static func kinds(_ issues: [CollagePreflightIssue]) -> String {
        issues.map { "\($0.kind.rawValue)/\($0.severity.rawValue)@\($0.page.map(String.init) ?? "-")" }.joined(separator: " ")
    }

    @MainActor
    private static func preflight(check: Checks) {
        let tray = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"].map { photo($0) }
        // 10 个跨页（20P）：前 6 个跨页 12 张不同的，后 4 个是空格 —— 空格 8 个，别的不拦。
        let pairs: [(String?, String?)] = (0..<10).map { i in (i < 6 ? tray[i * 2].id : nil, i < 6 ? tray[i * 2 + 1].id : nil) }
        let clean = album(pairs, photos: tray)
        let issues = CollagePreflight.run(project: clean, hints: [:], texts: false)
        let empties = issues.filter { $0.kind == .emptySlot }
        check(empties.count == 8 && empties.allSatisfy { $0.severity == .block && ($0.page ?? 0) >= 6 },
              "空照片格：8 个，都拦、在第 7–10 个跨页", kinds(issues))
        check(!issues.contains { $0.kind == .pageCount || $0.kind == .duplicate }, "20P、没重复：不报页数、不报重复", kinds(issues))

        // 3 个跨页（6P）、a 用了两次：页数拦（整本，page = nil）、第 2 次用的那一格拦。
        let dup = album([("a", "b"), ("c", "a"), ("d", "e")], photos: tray)
        let d = CollagePreflight.run(project: dup, hints: [:], texts: false)
        let pageIssue = d.first { $0.kind == .pageCount }
        check(pageIssue?.severity == .block && pageIssue?.page == nil
              && pageIssue?.message.contains("现在 3 个跨页 = 6P，少了 14P") == true,
              "页数不合规：拦，整本的事", pageIssue?.message ?? "没报")
        let dupIssue = d.filter { $0.kind == .duplicate }
        check(dupIssue.count == 1 && dupIssue.first?.page == 1 && dupIssue.first?.path == [1]
              && dupIssue.first?.message.contains("a 用了 2 次（第 1、2 个跨页）") == true,
              "同一张用了两次：拦，指到第 2 次那一格", dupIssue.first?.message ?? "没报")
        check(d.first?.kind == .pageCount, "整本的事排最前", kinds(d))

        // 放大：先量一格画出来多大，再按它定照片像素，算出 180%（拦）和 130%（提醒）。
        let probe = album([("big", nil)], photos: [photo("big", w: 6000, h: 6000)])
        let drawn = CollagePreflight.placements(project: probe, hints: [:]).first?.drawn ?? .zero
        let side = Double(max(drawn.width, drawn.height))
        let blur = photo("blur", w: Int((side / 1.8).rounded()), h: Int((side / 1.8).rounded()))
        let soft = photo("soft", w: Int((side / 1.3).rounded()), h: Int((side / 1.3).rounded()))
        let upProject = album([("blur", "x"), ("soft", "y")], photos: [blur, soft, photo("x"), photo("y")])
        let up = CollagePreflight.run(project: upProject, hints: [:], texts: false).filter { $0.kind == .upscale }
        let factors = Dictionary(CollagePreflight.placements(project: upProject, hints: [:]).map {
            ($0.photo.id, CollageCrop.upscale(photo: $0.photo, window: $0.window, drawn: $0.drawn))
        }, uniquingKeysWith: { a, _ in a })
        let upBlock = up.first { $0.photoID == "blur" }
        let upWarn = up.first { $0.photoID == "soft" }
        check(upBlock?.severity == .block && (1.7...1.9).contains(factors["blur"] ?? 0),
              "放大约 180%：拦", (upBlock?.message ?? "没报") + " \(factors["blur"] ?? 0)")
        check(upWarn?.severity == .warn && (1.25...1.35).contains(factors["soft"] ?? 0),
              "放大约 130%：提醒", (upWarn?.message ?? "没报") + " \(factors["soft"] ?? 0)")
        check(up.count == 2, "x、y 没放大：不报", kinds(up))
        check(CollageStore.upscaleIssues(project: upProject, hints: [:]).map(\.photoID) == ["blur", "soft"],
              "upscaleIssues（画布角标、upscale op）和清单同一套：倍数大的在前")

        // 脸压中缝：一整格铺满跨页，脸在正中间。胶装拦、平铺提醒。
        var spread = CollageExportSelfTest.smallSpread
        let face = photo("face", w: 4000, h: 2000, faces: [[0.46, 0.3, 0.54, 0.5]])
        var full = album([], photos: [face], canvas: spread)
        full.pages = [CollagePage(root: .leaf(cell("face")))]
        let flat = CollagePreflight.run(project: full, hints: [:], texts: false).first { $0.kind == .foldFace }
        check(flat?.severity == .warn && flat?.path == [], "平铺：脸压中缝 = 提醒", flat?.message ?? "没报")
        spread.binding = .glued
        full.canvas = spread
        let glued = CollagePreflight.run(project: full, hints: [:], texts: false).first { $0.kind == .foldFace }
        check(glued?.severity == .block && glued?.message.contains("胶装会被书脊吃掉") == true,
              "胶装：脸压中缝 = 拦", glued?.message ?? "没报")
        let side2 = album([("face", "x")], photos: [face, photo("x")])
        check(!CollagePreflight.run(project: side2, hints: [:], texts: false).contains { $0.kind == .foldFace },
              "脸在左页里面（没进中缝带）：不报")

        // 贴边没铺出血：零边距、出血 0 → 报；零边距、有出血、普通矩形格 → 渲染器会铺，不报；圆形格贴边 → 报。
        var edge = album([("a", "b")], photos: tray)
        edge.style.margin = 0
        edge.canvas.bleed = 0
        let noBleed = CollagePreflight.run(project: edge, hints: [:], texts: false).filter { $0.kind == .bleed }
        check(noBleed.count == 2 && noBleed.allSatisfy { $0.severity == .warn && $0.message.contains("出血是 0") },
              "出血是 0、零边距：两格都报", kinds(noBleed))
        edge.canvas.bleed = 12
        check(!CollagePreflight.run(project: edge, hints: [:], texts: false).contains { $0.kind == .bleed },
              "有出血、零边距、矩形格：渲染器铺进出血，不报")
        _ = edge.pages[0].root.update(at: [0]) { $0.cell?.shape = .circle }
        let round = CollagePreflight.run(project: edge, hints: [:], texts: false).filter { $0.kind == .bleed }
        check(round.count == 1 && round.first?.path == [0], "圆形格贴边：不往出血里铺，报那一格", kinds(round))
        var margined = album([("a", "b")], photos: tray)
        margined.canvas.bleed = 0
        check(!CollagePreflight.run(project: margined, hints: [:], texts: false).contains { $0.kind == .bleed },
              "有边距（照片不贴边）：出血是 0 也不报")

        // 首尾单页：第 1 个跨页左页、最后一个跨页右页有照片 → 提醒。
        var ends = album([("a", "b"), ("c", "d"), ("e", "f")], photos: tray)
        ends.canvas.printRules = CollagePrintRules()
        ends.canvas.printRules?.singleEnds = true
        let hidden = CollagePreflight.run(project: ends, hints: [:], texts: false).filter { $0.kind == .singleEnd }
        check(hidden.map(\.photoID) == ["a", "f"] && hidden.allSatisfy { $0.severity == .warn },
              "首尾单页：第 1 个跨页的 a（左页）、最后一个的 f（右页）", kinds(hidden))

        // 字出安全区（要渲字：texts = true）：文字图层贴着左边。
        var texted = album([("a", "b"), ("c", "d")], photos: tray)
        texted.canvas.safe = 30
        var item = CollageItem(kind: .text)
        item.cx = 0.02
        item.cy = 0.5
        item.width = 0.4
        item.height = 0.2
        item.text = CollageText(lines: [CollageTextLine("出界的字")])
        texted.pages[1].items = [item]
        let textIssues = CollagePreflight.run(project: texted, hints: [:], texts: true).filter { $0.kind == .textSafe }
        check(textIssues.count == 1 && textIssues.first?.page == 1 && textIssues.first?.item == item.id
              && textIssues.first?.message.contains("出界的字") == true,
              "字出安全区：提醒，指到那个文字图层", textIssues.first?.message ?? "没报 \(kinds(textIssues))")
        check(!CollagePreflight.run(project: texted, hints: [:], texts: false).contains { $0.kind == .textSafe },
              "texts = false 不渲字、不报字")

        // 导出确认：只有空格时标题、那句话和以前一样；有别的列出来；部分导出只看那几页，页数不拦。
        let onlyEmpty = album((0..<10).map { i in (i == 2 ? nil : "p\(i)a", "p\(i)b") },
                              photos: (0..<10).flatMap { [photo("p\($0)a"), photo("p\($0)b")] })
        let ask1 = CollageStore.exportConfirmation(CollagePreflight.run(project: onlyEmpty, hints: [:], texts: false),
                                                    project: onlyEmpty, pages: nil)
        check(ask1?.title == "有空照片格，仍要导出吗？"
              && ask1?.message == "第 3 个跨页上有 1 个空照片格：导出来是一块底色（预览里的虚线框不会印出来）。从托盘拖照片进去，或者选中那一格「删除格子」。",
              "只有空格：确认框和以前一字不差", ask1.map { "\($0.title) / \($0.message)" } ?? "没问")
        let ask2 = CollageStore.exportConfirmation(d, project: dup, pages: nil)
        check(ask2?.title.contains("2 条没过") == true && ask2?.message.contains("少了 14P") == true
              && ask2?.message.contains("a 用了 2 次") == true, "页数 + 重复：都列出来", ask2?.message ?? "没问")
        check(CollageStore.exportConfirmation(d, project: dup, pages: [0, 2]) == nil,
              "只导第 1、3 个跨页：重复在第 2 个、页数是整本的事 —— 不问")
        check(CollageStore.exportConfirmation(d, project: dup, pages: [1])?.message.contains("a 用了 2 次") == true,
              "只导第 2 个跨页：那一格的重复照样问")
        check(CollageStore.exportConfirmation([], project: dup, pages: nil) == nil, "没有拦的：不问")
    }

    @MainActor
    private static func preflightStore(_ store: CollageStore, check: Checks) {
        // 换成相册、加三个空白跨页：每个跨页都有空照片格；点第 3 个跨页那条 → 换到第 3 个、选中那一格、右栏切到「格式」。
        store.setMode(.album)
        while store.project.pages.count < 3 { store.addPage() }
        store.pageIndex = 0
        store.nav.inspectorTab = .document
        let issues = store.preflight(texts: false)
        guard let target = issues.first(where: { $0.kind == .emptySlot && $0.page == 2 }) else {
            check(false, "store：第 3 个跨页的空格在清单里", kinds(issues))
            return
        }
        store.reveal(target)
        check(store.pageIndex == 2 && store.selection == target.path && store.nav.inspectorTab == .format,
              "reveal：换到第 3 个跨页、选中那一格、右栏切到格式",
              "跨页 \(store.pageIndex + 1) 选中 \(String(describing: store.selection)) 页签 \(store.nav.inspectorTab.rawValue)")
        if let pages = issues.first(where: { $0.kind == .pageCount }) {
            let before = store.pageIndex
            store.reveal(pages)
            check(store.pageIndex == before, "整本的事（页数）点了不跳")
        }
        // 套内置规格：画布换成它（同一步撤销里换装订），规则跟着来；setPrintRules 改色彩。
        guard let glued = CollagePrintSpec.find("sq25-glued", in: []) else { return }
        let depth = store.undoDepth
        store.applyPrintSpec(glued)
        check(store.project.canvas.name == "方册 25×25 胶装" && store.project.canvas.binding == .glued
              && store.project.canvas.printRules == .standard && store.undoDepth == depth + 1,
              "套规格：尺寸、装订、规则一起换，一步撤销", "\(store.project.canvas.name) 撤销 \(depth)→\(store.undoDepth)")
        var rules = store.project.canvas.effectivePrintRules
        rules.colorSpace = .adobeRGB
        store.setPrintRules(rules)
        check(store.project.canvas.exportColorSpace == .adobeRGB && glued.matches(store.project.canvas) == false,
              "改色彩：画布记上，菜单上不再打勾（和内置的不一样了）")
        store.setPageSizeCM(width: 20, height: 30)
        check(store.project.canvas.width == CollageCanvas.px(cm: 40, dpi: 300)
              && store.project.canvas.height == CollageCanvas.px(cm: 30, dpi: 300)
              && store.project.canvas.printRules?.colorSpace == .adobeRGB && store.project.canvas.binding == .glued,
              "自定义单页 20×30cm：跨页 40×30cm，规则、装订不变", "\(store.project.canvas.width)x\(store.project.canvas.height)")
        store.undo()
        store.undo()
        store.undo()
    }

    // MARK: - 4. 色彩

    /// 导出页那样渲一页（startExport 同一组选项）。
    private static func render(_ project: CollageProject, page: Int) -> CGImage? {
        var opts = CollageRender.Options(scale: 1)
        opts.export = true
        opts.includeBleed = true
        opts.watermark = project.watermark?.exportEnabled ?? true
        opts.report = CollageRender.RenderReport()
        return CollageRender.render(page: project.pages[page], project: project, hints: [:], options: opts)
    }

    static func profileName(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyProfileName] as? String
    }

    /// PDF 第 1 页上那张图的色彩：ICCBased 的配置文件里认得出「Adobe RGB」/「sRGB」就报它，别的报 nil。
    static func pdfImageProfile(_ url: URL) -> String? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1), let dict = page.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return nil }
        var found: String?
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let sdict = CGPDFStreamGetDictionary(stream) else { return true }
            var space: CGPDFArrayRef?
            var name: UnsafePointer<CChar>?
            var icc: CGPDFStreamRef?
            guard CGPDFDictionaryGetArray(sdict, "ColorSpace", &space), let space,
                  CGPDFArrayGetName(space, 0, &name), let name, String(cString: name) == "ICCBased",
                  CGPDFArrayGetStream(space, 1, &icc), let icc else { return true }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(icc, &format) as Data? else { return true }
            for (label, needle) in [("Adobe RGB", "Adobe RGB"), ("sRGB", "sRGB")] {
                let ascii = Data(needle.utf8)
                let utf16 = needle.data(using: .utf16BigEndian) ?? Data()
                if data.range(of: ascii) != nil || data.range(of: utf16) != nil {
                    found = label
                    return false
                }
            }
            found = "其他"
            return false
        }, nil)
        return found
    }

    @MainActor
    private static func color(_ store: CollageStore, _ dir: URL, check: Checks) {
        var project = CollageExportSelfTest.albumProject(pages: 2)
        // 有色块的一页（灰色的转不转都差不多）：左格放一张读不了的照片会画底色，这里用底色 + 文字格就够区分。
        project.style.background = CollageColor(r: 0.9, g: 0.2, b: 0.1)
        var options = CollageStore.ExportOptions()
        options.pdf = true

        // sRGB：没规格、显式 sRGB 规格 —— 跨页 JPEG 和照旧编码（CollageExport.encode）的逐字节一样。
        guard let image = render(project, page: 0),
              let legacy = CollageExport.encode(image, format: .jpeg, quality: options.quality, dpi: project.canvas.dpi) else {
            check(false, "渲染自检跨页")
            return
        }
        for (label, rules) in [("没规格", CollagePrintRules?.none), ("显式 sRGB 规格", CollagePrintRules.standard)] {
            var p = project
            p.canvas.printRules = rules
            let out = dir.appendingPathComponent(label)
            options.outputPath = out.path
            // startExport 写进 store 的输出目录（导出按钮那个），这里和别的自检一样先设好。
            store.exportOptions = options
            let outcome = CollageExportSelfTest.runExport(store, project: p, options: options, name: "色")
            let written = try? Data(contentsOf: out.appendingPathComponent("色_跨页_01.jpg"))
            check(outcome?.failure == nil && written == legacy, "sRGB（\(label)）：跨页 JPEG 和照旧编码的逐字节一样",
                  "\(written?.count ?? -1) vs \(legacy.count) \(outcome?.failure ?? "")")
            check(written.flatMap(CollageExport.jpegIsBaseline) == true, "sRGB（\(label)）：JPEG 是基线（FFC0）")
            check(profileName(out.appendingPathComponent("色_跨页_01.jpg")) != "Adobe RGB (1998)",
                  "sRGB（\(label)）：没有嵌 Adobe RGB")
        }

        // Adobe RGB：JPEG（PDF 从盘上的跨页读）、PNG（PDF 用另编的 JPEG）。
        var adobe = project
        adobe.canvas.printRules = CollagePrintRules()
        adobe.canvas.printRules?.colorSpace = .adobeRGB
        for format in [CollageExport.Format.jpeg, .png] {
            let out = dir.appendingPathComponent("adobe-\(format.rawValue)")
            options.outputPath = out.path
            options.format = format
            store.exportOptions = options
            let outcome = CollageExportSelfTest.runExport(store, project: adobe, options: options, name: "色")
            let file = out.appendingPathComponent("色_跨页_01.\(format.ext)")
            check(outcome?.failure == nil && outcome?.files.last == "色.pdf", "Adobe RGB \(format.label)：跨页 + PDF 都写出来",
                  "\(outcome?.files ?? []) \(outcome?.failure ?? "")")
            check(profileName(file) == "Adobe RGB (1998)", "Adobe RGB \(format.label)：读回来配置文件是 Adobe RGB (1998)",
                  profileName(file) ?? "没有")
            if format == .jpeg {
                let data = try? Data(contentsOf: file)
                check(data.flatMap(CollageExport.jpegIsBaseline) == true, "Adobe RGB JPEG：基线（FFC0）")
                check(data != legacy, "Adobe RGB JPEG：和 sRGB 那份不一样（真转了）")
            }
            let pdf = out.appendingPathComponent("色.pdf")
            check(pdfImageProfile(pdf) == "Adobe RGB", "Adobe RGB \(format.label)：PDF 里那页图的 ICC 是 Adobe RGB",
                  pdfImageProfile(pdf) ?? "读不出")
        }
        // 对照：sRGB 的 PDF 里是 sRGB（PDF 那条路没被改坏）。
        options.format = .jpeg
        let srgbOut = dir.appendingPathComponent("srgb-pdf")
        options.outputPath = srgbOut.path
        store.exportOptions = options
        _ = CollageExportSelfTest.runExport(store, project: project, options: options, name: "色")
        let srgbProfile = pdfImageProfile(srgbOut.appendingPathComponent("色.pdf"))
        check(srgbProfile != "Adobe RGB", "sRGB 的 PDF 里不是 Adobe RGB", srgbProfile ?? "读不出")
        // 规格定了 JPEG 质量：照它编（和照旧编码按那个质量的逐字节一样）。
        var quality = project
        quality.canvas.printRules = CollagePrintRules()
        quality.canvas.printRules?.jpegQuality = 1.0
        let qOut = dir.appendingPathComponent("quality")
        options.outputPath = qOut.path
        store.exportOptions = options
        _ = CollageExportSelfTest.runExport(store, project: quality, options: options, name: "色")
        let q1 = CollageExport.encode(image, format: .jpeg, quality: 1.0, dpi: project.canvas.dpi)
        check((try? Data(contentsOf: qOut.appendingPathComponent("色_跨页_01.jpg"))) == q1,
              "规格的 JPEG 质量 1.0：照它编（不看导出设置的 0.93）")
        check(CollageExportSelfTest.leftovers(dir.appendingPathComponent("adobe-jpeg")).isEmpty, "没有临时文件")
    }

    // MARK: - 5. 部分导出

    @MainActor
    private static func partial(_ store: CollageStore, _ dir: URL, check: Checks) {
        let fm = FileManager.default
        let project = CollageExportSelfTest.albumProject(pages: 4)
        var options = CollageStore.ExportOptions()
        options.outputPath = dir.path
        options.pdf = true
        store.exportOptions = options
        func files() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }

        let plan = CollageStore.exportPlan(base: "名", project: project, options: options, only: [0, 2])
        check(plan.indices == [0, 2] && plan.pdf == nil && plan.allFiles == ["名_跨页_01.jpg", "名_跨页_03.jpg"],
              "计划：只有第 1、3 个跨页，序号是原跨页号，不出 PDF", "\(plan.allFiles)")

        var done: CollageStore.ExportOutcome?
        let refused = store.startExport(project: project, options: options, name: "部分", reveal: false, pages: [2, 0, 2, 9]) {
            done = $0
        }
        CollageExportSelfTest.spin(60) { done != nil }
        CollageExportSelfTest.spin(5) { !store.isExporting }
        check(refused == nil && done?.failure == nil && done?.files == ["部分_跨页_01.jpg", "部分_跨页_03.jpg"]
              && files() == ["部分_跨页_01.jpg", "部分_跨页_03.jpg"],
              "只导第 1、3 个跨页（乱序、重复、越界的丢掉）：两张图，没有 PDF", "\(done?.files ?? []) \(files())")
        check(store.progressText.contains("只导了第 1、3 个跨页") && store.progressText.contains("不出 PDF"),
              "完成那句说清只导了哪几个、没出 PDF", store.progressText)

        // 再导第 2 个跨页、同名：01 / 03 在盘上不算撞名（只查这次要写的），不加 -2。
        done = nil
        store.startExport(project: project, options: options, name: "部分", reveal: false, pages: [1]) { done = $0 }
        CollageExportSelfTest.spin(60) { done != nil }
        CollageExportSelfTest.spin(5) { !store.isExporting }
        check(done?.files == ["部分_跨页_02.jpg"], "再导第 2 个：只查这次要写的那个，不加 -2", "\(done?.files ?? [])")
        // 同样的第 1、3 个再导一次：撞名了，整组加 -2。
        done = nil
        store.startExport(project: project, options: options, name: "部分", reveal: false, pages: [0, 2]) { done = $0 }
        CollageExportSelfTest.spin(60) { done != nil }
        CollageExportSelfTest.spin(5) { !store.isExporting }
        check(done?.files == ["部分-2_跨页_01.jpg", "部分-2_跨页_03.jpg"], "同样的再导一次：加 -2，不覆盖",
              "\(done?.files ?? [])")
        // 选的正好是全部 = 全部：照常出 PDF。
        done = nil
        store.startExport(project: project, options: options, name: "整本", reveal: false, pages: [0, 1, 2, 3]) { done = $0 }
        CollageExportSelfTest.spin(60) { done != nil }
        CollageExportSelfTest.spin(5) { !store.isExporting }
        check(done?.files.last == "整本.pdf" && done?.files.count == 5, "选了全部 4 个 = 全部：照常出 PDF", "\(done?.files ?? [])")
        // 范围里一个都不在这本里：不开始。
        done = nil
        let none = store.startExport(project: project, options: options, name: "空", reveal: false, pages: [9]) { done = $0 }
        check(none != nil && done?.failure != nil, "范围里的跨页都不在：开始不了、说原因", none ?? "开始了")

        // store 的范围：自定义写错了，导出按钮灰掉、说原因。
        store.setMode(.album)
        while store.project.pages.count < 3 { store.addPage() }
        store.exportOptions = options
        store.exportRange = .custom("2-5")
        check(store.exportBlockedReason?.contains("一共 3 个跨页") == true, "范围越界：导出按钮灰、说一共几个",
              store.exportBlockedReason ?? "nil")
        store.exportRange = .custom("1-3")
        check((try? store.exportPageSelection.get()) == .some(nil), "1-3 正好是全部 3 个 = 全部")
        store.pageIndex = 1
        store.exportRange = .current
        check((try? store.exportPageSelection.get()) == .some([1]), "当前跨页 = 第 2 个")
        store.exportRange = .all
    }

    // MARK: - 6. 看版 PDF

    @MainActor
    private static func proof(_ store: CollageStore, _ dir: URL, check: Checks) {
        var project = CollageExportSelfTest.albumProject(pages: 3)
        project.photos = [photo("A0001"), photo("B0002"), photo("C0003")]
        // 第 2 个跨页：左页 B0002、右页上下两格（C0003 在上、A0001 在下）→ 阅读顺序 B0002 C0003 A0001。
        project.pages[1].root = .split(.row, 0.5, .leaf(cell("B0002")),
                                       .split(.column, 0.5, .leaf(cell("C0003")), .leaf(cell("A0001"))))
        check(CollageProofPDF.photoNames(page: project.pages[1], project: project)
              == ["B0002.jpg", "C0003.jpg", "A0001.jpg"], "照片文件名按阅读顺序：左页、右页先上后下",
              CollageProofPDF.photoNames(page: project.pages[1], project: project).joined(separator: " "))
        func runProof(_ name: String) -> Result<String, CollageExportRange.Bad>? {
            var result: Result<String, CollageExportRange.Bad>?
            let refused = store.startProofPDF(project: project, name: name, folder: dir, reveal: false) { result = $0 }
            if refused == nil { CollageExportSelfTest.spin(120) { result != nil } }
            CollageExportSelfTest.spin(5) { !store.isExporting }
            return result
        }
        let first = runProof("看")
        guard case .success(let file)? = first else {
            check(false, "看版 PDF 写出来", "\(String(describing: first))")
            return
        }
        let url = dir.appendingPathComponent(file)
        check(file == "看_看版.pdf" && CollageExportSelfTest.pageCount(url) == 3, "看版：名_看版.pdf、3 页", file)
        if let doc = PDFDocument(url: url), let p1 = doc.page(at: 0), let p2 = doc.page(at: 1) {
            let t1 = p1.string ?? ""
            let t2 = p2.string ?? ""
            check(t1.contains("跨页 1 / 3 · 自检相册"), "第 1 页页脚：跨页 1 / 3 · 标题", t1)
            let order = ["B0002.jpg", "C0003.jpg", "A0001.jpg"].compactMap { t2.range(of: $0)?.lowerBound }
            check(t2.contains("跨页 2 / 3 · 自检相册") && order.count == 3 && order == order.sorted(),
                  "第 2 页页脚：跨页号 + 照片文件名（阅读顺序）", t2)
            let box = p1.bounds(for: .mediaBox)
            let image = project.canvas
            let scale = min(1, CollageProofPDF.longSide / Double(max(image.width, image.height)))
            let wantW = (Double(image.width) * scale).rounded() * CollageProofPDF.pointsPerPixel
            check(abs(Double(box.width) - wantW) < 1 && box.height > box.width / 2,
                  "页面宽 = 画面（不带出血）× 0.5 pt、下面多一截页脚", "\(box)")
        } else {
            check(false, "PDFKit 读得出看版")
        }
        let second = runProof("看")
        check((try? second?.get()) == "看-2_看版.pdf", "同名再出一次：看-2_看版.pdf，不覆盖", "\(String(describing: second))")
        check(CollageExportSelfTest.leftovers(dir).isEmpty, "没有临时文件", CollageExportSelfTest.leftovers(dir).joined(separator: " "))
        // 单张拼图不出看版。
        var single = project
        single.mode = .single
        var refusedSingle: Result<String, CollageExportRange.Bad>?
        let why = store.startProofPDF(project: single, name: "单", folder: dir, reveal: false) { refusedSingle = $0 }
        check(why != nil && (try? refusedSingle?.get()) == nil, "单张拼图：不出看版", why ?? "出了")
    }
}
