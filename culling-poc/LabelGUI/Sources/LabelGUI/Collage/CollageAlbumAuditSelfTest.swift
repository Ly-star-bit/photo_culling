import Foundation
import CoreGraphics
import ImageIO

/// --album-audit-selftest：优化分析（2026-11-10）相册那张表 A1–A13 的修补，一条一段。合成数据、不要照片文件夹、不跑 Vision、
/// 不开界面；要真图的几段自己在数据目录里写几张纯色小 JPEG。那份报告点过名的自检盲区都在这里：
/// 原图读不了、胶装跨中缝、挪照片后的手调、书脊过期、导出范围粘住、AI 等的时候用户翻了页（指纹）、内页印刷 PDF 的
/// TrimBox / BleedBox。
/// 1. A1 / A2 原图读不了：检查报「拦」（带页号、格子，一张报一次）；导出不出印刷 PDF、不写「导出完成」；缺图和低清都报；
/// 2. A3 胶装照片跨中缝：拦、带页号和格子、点了跳过去；平铺不报；
/// 3. A4 书脊：记下填的时候多少 P，P 数变了拦；旧工程缺键读得回来、不报；估的整本导出问一次；
/// 4. A5 挪照片后的重排把其余照片的手调带回去，格子比例差太多的才清裁切；
/// 5. A6 胶装时字压进中缝带是拦；导出完那句后面带提醒条数；
/// 6. A7 部分导出成了范围复位、按钮上写清导哪几个；
/// 7. A8 指纹并进当前页号和封面状态，翻页不算改了拼图；collage_pages 的 delete 要 pages；
/// 8. A9 没套规格时页数只是提醒；A10 序号位数；A12 封面那页渲染失败要报错；A13 跨页小图的键；
/// 9. 内页印刷 PDF 的 MediaBox / BleedBox / TrimBox；
/// 10. R15（拼图画布那张表）：备选条「换一批」、去掉一个备选以后悬停的大图清掉。
enum CollageAlbumAuditSelfTest {
    typealias Check = CollageAlbumEditSelfTest.Check
    typealias Edit = CollageAlbumEditSelfTest
    typealias Review = CollageAlbumReviewSelfTest
    typealias Export = CollageExportSelfTest

    @MainActor
    static func run() -> Never {
        AppRuntime.headless = true
        CollageCLI.requireIsolatedDataDir("--album-audit-selftest")
        var failures: [String] = []
        let check = Check { ok, name, detail in
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }
        let root = appDataDir.appendingPathComponent("album-audit-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        print("== A1 / A2 原图读不了")
        checkSourcePreflight(check: check)
        checkSourceExport(root.appendingPathComponent("source"), check: check)
        print("== A3 胶装照片跨中缝")
        checkFoldCross(check: check)
        print("== A4 书脊按多少 P 填的")
        checkSpine(root.appendingPathComponent("spine"), check: check)
        print("== A5 挪照片后其余照片的手调")
        checkCarry(check: check)
        print("== A6 胶装时字压进中缝带、导出完带提醒条数")
        checkGluedText(root.appendingPathComponent("text"), check: check)
        print("== A7 导出范围")
        checkRange(root.appendingPathComponent("range"), check: check)
        print("== A8 指纹里的当前页")
        checkDigest(check: check)
        print("== A9 / A10 / A12 / A13")
        checkPageCount(check: check)
        checkSerial(check: check)
        checkCoverFailure(root.appendingPathComponent("cover"), check: check)
        checkThumbKeys(check: check)
        print("== 内页印刷 PDF 的框")
        checkPDFBoxes(root.appendingPathComponent("boxes"), check: check)
        print("== R15 备选条悬停的大图")
        checkAltHover(check: check)

        try? FileManager.default.removeItem(at: root)
        print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - 小工具

    /// 在 dir 里写 n 张纯色小 JPEG（真读得了的原图），返回照片（P0…；奇数竖、偶数横）。
    static func realPhotos(_ n: Int, in dir: URL) -> [CollagePhotoRef] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (0..<n).compactMap { i in
            let w = i % 2 == 0 ? 360 : 240
            let h = i % 2 == 0 ? 240 : 360
            guard let data = Export.jpeg(width: w, height: h, gray: 0.3 + Double(i) * 0.05) else { return nil }
            let url = dir.appendingPathComponent("P\(i).jpg")
            guard (try? data.write(to: url)) != nil else { return nil }
            var p = CollagePhotoRef(id: "P\(i)", path: url.path, width: w, height: h)
            p.captureTime = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)
            return p
        }
    }

    /// 小跨页画布上的一本：每个跨页左右各一张真照片。
    static func realBook(_ photos: [CollagePhotoRef], spreads: Int) -> CollageProject {
        var p = CollageProject()
        p.mode = .album
        p.canvas = Export.smallSpread
        p.title = "自检相册"
        p.photos = photos
        p.pages = (0..<spreads).map { i in
            CollagePage(root: .split(.row, 0.5, .leaf(.photo(photos[(2 * i) % photos.count].id)),
                                     .leaf(.photo(photos[(2 * i + 1) % photos.count].id))))
        }
        return p
    }

    @MainActor
    static func exportStore(_ project: CollageProject, out: URL, pdf: Bool = true) -> CollageStore {
        let store = CollageStore(dataDir: appDataDir)
        store.loadForTesting(project)
        var options = CollageStore.ExportOptions()
        options.outputPath = out.path
        options.pdf = pdf
        store.exportOptions = options
        return store
    }

    /// 按导出按钮那一路（export）走一次，等它导完。
    @MainActor
    static func press(_ store: CollageStore, confirmed: Bool = false) {
        store.export(confirmed: confirmed)
        Export.spin(120) { !store.isExporting }
        // 结尾那几句（进度文字、范围复位）在导出 Task 的最后、done 回调里：再转几下让它落地。
        Export.spin(0.3) { false }
    }

    static func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: - 1. 原图读不了

    @MainActor
    static func checkSourcePreflight(check: Check) {
        let book = Review.book()
        let clean = CollagePreflight.run(project: book, hints: [:], texts: false, readable: { _ in true })
        check(!clean.contains { $0.kind == .source }, "原图都读得了：不报")
        let issues = CollagePreflight.run(project: book, hints: [:], texts: false, readable: { $0.id != "R3" && $0.id != "R9" })
        let source = issues.filter { $0.kind == .source }
        // R3 在第 3 个跨页的左格；R9 在托盘里、没上版：不报。
        check(source.count == 1 && source.first?.photoID == "R3" && source.first?.severity == .block
              && source.first?.page == 2 && source.first?.path == [0],
              "一张原图读不了：拦，带第几个跨页、哪一格；没上版的不报",
              source.map { "\($0.photoID ?? "-")@\($0.page ?? -1)/\($0.path ?? [])" }.joined(separator: " "))
        check(source.first?.message.contains("原图读不了") == true && source.first?.message.contains("第 3 个跨页") == true
              && source.first?.message.contains("R3") == true, "那句话说清是哪张、在哪、印出来会糊", source.first?.message ?? "")
        // 合成照片的路径都不在盘上：按盘查（默认）用到的 9 张全报，每张一次；原因是文件夹不在。
        let disk = CollagePreflight.run(project: book, hints: [:], texts: false).filter { $0.kind == .source }
        check(disk.count == 9 && Set(disk.compactMap(\.photoID)).count == 9
              && disk.allSatisfy { $0.message.contains("文件夹不在") },
              "默认按盘查：文件不在的每张报一次，说文件夹不在（盘没接上）", "\(disk.count) 条")
        let ask = CollageStore.exportConfirmation(issues, project: book, pages: nil)
        check(ask?.message.contains("原图读不了") == true, "导出按钮先问，列出原图读不了那一条", ask?.message ?? "不问")
        check(CollageStore.exportConfirmation(issues, project: book, pages: [0, 1]) == nil
              && CollageStore.exportConfirmation(issues, project: book, pages: [2]) != nil,
              "只导几个跨页：只看那几个跨页上的")
        // 封面上的照片读不了也报（封面那块带格子路径）。
        var covered = book
        covered.bookCover = CollageBookCover.make(project: book)
        let onCover = CollagePreflight.run(project: covered, hints: [:], texts: false, readable: { $0.id != "R0" })
        check(onCover.contains { $0.kind == .cover && $0.severity == .block && $0.photoID == "R0" && $0.message.contains("原图读不了") }
              && onCover.contains { $0.kind == .source && $0.photoID == "R0" },
              "封面用的那张读不了：封面一条（拦）、跨页一条")
        // A2：缺图和低清两种都报。
        let both = CollageStore.exportWarning(missing: ["a", "b"], lowRes: ["c"], signatureLost: false) ?? ""
        check(both.contains("2 张照片读不了") && both.contains("1 张原图读不了，用了 1024 预览"), "缺图和低清都有：两种都报", both)
        let only = CollageStore.exportWarning(missing: [], lowRes: ["c"], signatureLost: false) ?? ""
        check(only.hasPrefix("1 张原图读不了") && !only.contains("格子空着"), "只有低清：只报低清")
    }

    @MainActor
    static func checkSourceExport(_ dir: URL, check: Check) {
        let photos = realPhotos(6, in: dir.appendingPathComponent("src"))
        guard photos.count == 6 else {
            check(false, "写得出合成原图", "")
            return
        }
        let book = realBook(photos, spreads: 3)
        // a) 原图都在：照常出 PDF、写「导出完成」。
        let a = dir.appendingPathComponent("a")
        let store = exportStore(book, out: a)
        let ok = Export.runExport(store, project: book, options: store.exportOptions, name: "整本")
        check(ok?.failure == nil && ok?.warning == nil && ok?.files.last == "整本.pdf" && store.progressText.hasPrefix("导出完成"),
              "原图都读得了：3 个跨页 + PDF，写「导出完成」", "\(ok?.files ?? []) \(ok?.failure ?? "") \(store.progressText)")
        // b) 一张原图读不了（退回预览）：跨页图照写，不出 PDF，算失败，说清几张；不写「导出完成」。
        let b = dir.appendingPathComponent("b")
        store.exportOptions.outputPath = b.path
        store.testUnreadableOriginals = ["P2"]
        let pre = store.preflight(texts: false).filter { $0.kind == .source }
        check(pre.count == 1 && pre.first?.photoID == "P2" && pre.first?.page == 1, "检查按同一个判断报那一张")
        let low = Export.runExport(store, project: book, options: store.exportOptions, name: "低清")
        let failure = low?.failure ?? ""
        check(failure.contains("没生成 PDF") && failure.contains("1 张原图读不了") && low?.files == ["低清_跨页_01.jpg", "低清_跨页_02.jpg", "低清_跨页_03.jpg"],
              "一张用了预览图：跨页图照写、不出印刷 PDF，failure 说清为什么", "\(low?.files ?? []) \(failure)")
        check(!FileManager.default.fileExists(atPath: b.appendingPathComponent("低清.pdf").path) && Export.leftovers(b).isEmpty,
              "盘上没有 PDF、没有临时文件", files(b).joined(separator: " "))
        check((store.lastError ?? "").hasPrefix("导出失败") && (store.lastError ?? "").contains("用了 1024 预览")
              && !store.progressText.hasPrefix("导出完成") && low?.warning?.contains("P2") == true,
              "界面：导出失败 + 哪一张用了预览，不写「导出完成」", "\(store.lastError ?? "") / \(store.progressText)")
        // c) 没勾 PDF：不算失败，但进度文字不写「导出完成」。
        let c = dir.appendingPathComponent("c")
        store.exportOptions.outputPath = c.path
        store.exportOptions.pdf = false
        let soft = Export.runExport(store, project: book, options: store.exportOptions, name: "只出图")
        check(soft?.failure == nil && soft?.files.count == 3 && !store.progressText.hasPrefix("导出完成")
              && store.progressText.contains("1 张照片用的不是原图"),
              "没勾 PDF：图照写、不算失败，进度文字写明有照片不是原图", "\(soft?.failure ?? "") / \(store.progressText)")
        // d) 文件真的不在（缺图，格子空着）：同样不出 PDF。
        var gone = book
        gone.photos[4] = CollagePhotoRef(id: "P4", path: dir.appendingPathComponent("没有这张.jpg").path, width: 360, height: 240)
        let d = dir.appendingPathComponent("d")
        store.exportOptions.outputPath = d.path
        store.exportOptions.pdf = true
        store.loadForTesting(gone)
        // loadForTesting 默认当成都读得了：这一段要按盘查。
        store.testUnreadableOriginals = nil
        let missing = Export.runExport(store, project: gone, options: store.exportOptions, name: "缺图")
        check((missing?.failure ?? "").contains("没生成 PDF") && (missing?.failure ?? "").contains("格子空着")
              && missing?.files.contains("缺图.pdf") == false,
              "原图不在、预览也没有（格子空着）：不出 PDF", "\(missing?.files ?? []) \(missing?.failure ?? "")")
        let found = store.preflight(texts: false).filter { $0.kind == .source }
        check(found.count == 1 && found.first?.photoID == "P4" && found.first?.message.contains("挪走或改名") == true,
              "按盘查：只报不在的那一张，说文件挪走或改名了", found.first?.message ?? "")
    }

    // MARK: - 2. 胶装照片跨中缝

    @MainActor
    static func checkFoldCross(check: Check) {
        var book = Review.book()
        // 第 2 个跨页：一张横图铺满整个跨页（平铺对裱排的整版跨页）。
        book.pages[1] = CollagePage(root: .leaf(.photo("R3")))
        book.canvas.binding = .layflat
        let flat = CollagePreflight.run(project: book, hints: [:], texts: false, readable: { _ in true })
        check(!flat.contains { $0.kind == .foldCross }, "平铺对裱：横图跨中缝是正常做法，不报")
        book.canvas.binding = .glued
        let glued = CollagePreflight.run(project: book, hints: [:], texts: false, readable: { _ in true })
        let cross = glued.filter { $0.kind == .foldCross }
        check(cross.count == 1 && cross.first?.severity == .block && cross.first?.page == 1 && cross.first?.path == []
              && cross.first?.photoID == "R3" && cross.first?.message.contains("横跨中缝") == true,
              "胶装：拦，带第几个跨页、哪一格", cross.map(\.message).joined(separator: " "))
        check(CollageStore.crossFoldUses(project: book).map(\.page) == [1], "和换装订时的提示同一个判断（crossFoldUses）")
        let store = CollageStore(dataDir: appDataDir)
        store.loadForTesting(book)
        check(store.crossFoldPages() == [1], "crossFoldPages 还是那几页")
        if let issue = cross.first {
            store.reveal(issue)
            check(store.pageIndex == 1 && store.selection == [], "清单上点它：翻到那个跨页、选中那一格")
        }
        check(CollageStore.exportConfirmation(glued, project: book, pages: nil)?.message.contains("横跨中缝") == true,
              "导出按钮先问")
        // 完整显示的竖图放在跨页正中（没碰到中缝两侧以外）也算；左右各一页的不算。
        book.pages[1] = CollagePage(root: .split(.row, 0.5, .leaf(.photo("R3")), .leaf(.photo("R4"))))
        check(!CollagePreflight.run(project: book, hints: [:], texts: false, readable: { _ in true }).contains { $0.kind == .foldCross },
              "左右各一页：不报")
    }

    // MARK: - 3. 书脊

    @MainActor
    static func checkSpine(_ dir: URL, check: Check) {
        let store = Review.coverStore()
        store.testUnreadableOriginals = []
        check(store.project.bookCover?.spineMM == nil && store.project.bookCover?.spinePages == nil, "刚做的封面：书脊是估的，不记 P 数")
        let estimated = store.preflight(texts: false).filter { $0.kind == .spine }
        check(estimated.count == 1 && estimated.first?.severity == .warn && estimated.first?.message.contains("是估的") == true,
              "书脊是估的：一条提醒（kind = spine）", estimated.map(\.message).joined(separator: " "))
        store.setCoverSpine(12.5)
        check(store.project.bookCover?.spinePages == 10, "填书脊宽：记下这一刻是 10P", "\(store.project.bookCover?.spinePages ?? -1)")
        check(!store.preflight(texts: false).contains { $0.kind == .spine }, "页数没变：不报")
        store.pageIndex = store.project.pages.count - 1
        store.addPage()
        let stale = store.preflight(texts: false).filter { $0.kind == .spine }
        check(stale.count == 1 && stale.first?.severity == .block && stale.first?.message.contains("是按 10P 填的，现在 12P") == true,
              "加了一个跨页：拦，「书脊是按 10P 填的，现在 12P」", stale.map(\.message).joined(separator: " "))
        check(CollageStore.exportConfirmation(stale, project: store.project, pages: nil) != nil
              && CollageStore.exportConfirmation(stale, project: store.project, pages: [0]) == nil,
              "整本导出先问；只导几个跨页（不写封面）不问")
        if let issue = stale.first {
            store.nav.inspectorTab = .format
            store.reveal(issue)
            check(!store.editingCover, "点它去「文档 › 封面」，不进封面编辑")
        }
        // 旧工程读回：编码以后把 spinePages 键拿掉 = 这一版之前存的。
        if let data = try? JSONEncoder().encode(store.project),
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var cover = object["bookCover"] as? [String: Any] {
            check(cover["spinePages"] as? Int == 10, "存盘带着 spinePages")
            let back = try? JSONDecoder().decode(CollageProject.self, from: data)
            check(back?.bookCover?.spinePages == 10 && back?.bookCover?.spineMM == 12.5, "读回来还在")
            cover.removeValue(forKey: "spinePages")
            object["bookCover"] = cover
            let old = (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
            check(old?.bookCover?.spineMM == 12.5 && old?.bookCover?.spinePages == nil && old?.pages.count == 6,
                  "旧工程（没有这个键）：读得回来，P 数 = 不知道")
            if let old {
                check(!CollagePreflight.run(project: old, hints: [:], texts: false, readable: { _ in true }).contains { $0.kind == .spine },
                      "不知道是按多少 P 填的：不报")
            }
        } else {
            check(false, "工程编得出 JSON", "")
        }
        store.setCoverSpine(12.5)
        check(store.project.bookCover?.spinePages == 12 && !store.preflight(texts: false).contains { $0.kind == .spine },
              "同一个数再填一次：按现在的 12P 记，不再报")
        store.setCoverSpine(nil)
        check(store.project.bookCover?.spinePages == nil, "改回估算：不留 P 数")

        // 「书脊是估的」整本导出时问一次。
        let photos = realPhotos(6, in: dir.appendingPathComponent("src"))
        guard photos.count == 6 else { return }
        var book = realBook(photos, spreads: 3)
        book.bookCover = CollageBookCover(front: .leaf(.photo("P0")))
        let out = dir.appendingPathComponent("out")
        let asking = exportStore(book, out: out)
        asking.export()
        check(asking.exportConfirm?.contains("是估的") == true && !asking.isExporting, "书脊是估的：整本导出先问一次",
              asking.exportConfirm ?? "没问")
        asking.exportConfirm = nil
        asking.exportRange = .current
        asking.export()
        let partialAsked = asking.exportConfirm != nil
        Export.spin(120) { !asking.isExporting }
        Export.spin(0.3) { false }
        check(!partialAsked, "只导当前跨页（不写封面）：不问")
        asking.exportRange = .all
        press(asking, confirmed: true)
        check(files(out).contains { $0.hasSuffix("_封面.jpg") }, "点了仍然导出：封面写出来了", files(out).joined(separator: " "))
        asking.export()
        let again = asking.exportConfirm
        Export.spin(120) { !asking.isExporting }
        Export.spin(0.3) { false }
        check(again == nil, "问过一次、页数没变：不再问", again ?? "")
        asking.pageIndex = 2
        asking.addPage()
        asking.export()
        check(asking.exportConfirm?.contains("是估的") == true, "加了跨页（估出来的数变了）：再问一次")
        asking.exportConfirm = nil
    }

    // MARK: - 4. 挪照片后的手调

    @MainActor
    static func checkCarry(check: Check) {
        let canvas = Edit.album30
        let style = CollageStyle()
        var a = CollageCell.photo("A")
        a.crop = CollageCropOverride(cx: 0.4, cy: 0.45, zoom: 1.6)
        a.framing = .close
        a.shape = .arch
        var b = CollageCell.photo("B")
        b.contain = true
        b.containBlur = true
        var c = CollageCell.photo("C")
        c.cutout = CollageCutout(stroke: 0.01, shadow: 0.3)
        let old = CollageNode.split(.row, 0.5, .leaf(a), .split(.column, 0.5, .leaf(b), .leaf(c)))
        // 同一个结构、格子是新建的（求解器按照片重新建格子）。
        let fresh = CollageNode.split(.row, 0.5, .leaf(.photo("A")), .split(.column, 0.5, .leaf(.photo("B")), .leaf(.photo("C"))))
        let same = CollageLayout.carryAdjustments(from: old, into: fresh, canvas: canvas, style: style)
        func cell(_ root: CollageNode, _ id: String) -> CollageCell? { root.leaves.first { $0.photoID == id } }
        check(cell(same, "A")?.crop == a.crop && cell(same, "A")?.framing == .close && cell(same, "A")?.shape == .arch,
              "格子比例没变：裁切、景别、形状都带回去")
        check(cell(same, "B")?.contain == true && cell(same, "B")?.containBlur == true, "完整显示（模糊铺底）带回去")
        check(cell(same, "C")?.cutout == c.cutout, "抠图带回去")
        check(same == old, "带回去以后和原来逐节点相等")
        // 换了结构：A 从竖格（半个跨页）变成横条，比例差得多 → 裁切回到自动，景别、形状留着；B、C 同理。
        let wide = CollageNode.split(.column, 0.3, .leaf(.photo("A")), .split(.row, 0.5, .leaf(.photo("B")), .leaf(.photo("C"))))
        let moved = CollageLayout.carryAdjustments(from: old, into: wide, canvas: canvas, style: style)
        check(cell(moved, "A")?.crop == nil && cell(moved, "A")?.framing == .close && cell(moved, "A")?.shape == .arch,
              "格子比例差太多：裁切回到自动，景别、形状留着")
        check(cell(moved, "B")?.contain == false, "完整显示：格子比例差太多不带（那多半是求解器给单张页的）")
        // 新格子上求解器自己定了的不盖。
        var solved = CollageCell.photo("A")
        solved.framing = .full
        let keep = CollageLayout.carryAdjustments(from: old, into: .leaf(solved), canvas: canvas, style: style)
        check(keep.cell?.framing == .full, "新格子上已经定了景别（求解器、锁定格）：不盖")
        check(CollageLayout.carryAdjustments(from: fresh, into: wide, canvas: canvas, style: style) == wide, "没有手调：原样")

        // store：把一张挪到别的跨页，两页其余照片的景别、形状还在（精排落下以后）。
        let store = CollageStore(dataDir: appDataDir)
        let photos = (0..<10).map { Edit.photo("E\($0)", Double($0) * 5, portrait: $0 % 3 != 0, score: 3 - Double($0) * 0.1) }
        func leaf(_ id: String, _ edit: (inout CollageCell) -> Void = { _ in }) -> CollageNode {
            var cell = CollageCell.photo(id)
            edit(&cell)
            return .leaf(cell)
        }
        var p = CollageProject()
        p.mode = .album
        p.canvas = canvas
        p.photos = photos
        p.pages = [
            CollagePage(root: .split(.row, 0.5, leaf("E0") { $0.framing = .half },
                                     .split(.column, 0.5, leaf("E1"), leaf("E2") { $0.shape = .rounded }))),
            CollagePage(root: .split(.row, 0.5, leaf("E3") { $0.framing = .close }, leaf("E4"))),
        ]
        store.loadForTesting(p)
        let depth = store.undoDepth
        store.moveCells([[1, 0]], toPage: 1)
        Edit.spin(30) { !store.isRefining }
        func now(_ page: Int, _ id: String) -> CollageCell? { store.project.pages[page].root.leaves.first { $0.photoID == id } }
        check(store.project.pages[1].photoIDs.contains("E1") && !store.project.pages[0].photoIDs.contains("E1"), "E1 挪到了第 2 个跨页")
        check(now(0, "E0")?.framing == .half && now(0, "E2")?.shape == .rounded, "原跨页其余两张：景别、形状还在",
              "\(now(0, "E0")?.framing.rawValue ?? "-") \(now(0, "E2")?.shape?.rawValue ?? "-")")
        check(now(1, "E3")?.framing == .close, "目标跨页原有的那张：景别还在", now(1, "E3")?.framing.rawValue ?? "-")
        check(store.undoDepth == depth + 1 && (store.notice ?? "").contains("裁切、景别留着"), "还是一步撤销；提示说其余照片的手调留着",
              store.notice ?? "")
        store.addPhotos(["E7"], toPage: 1)
        Edit.spin(30) { !store.isRefining }
        check(now(1, "E3")?.framing == .close && store.project.pages[1].photoIDs.contains("E7"), "往那个跨页再加一张：原有照片的景别还在")
    }

    // MARK: - 5. 胶装时字压进中缝带

    @MainActor
    static func checkGluedText(_ dir: URL, check: Check) {
        let photos = realPhotos(4, in: dir.appendingPathComponent("src"))
        guard photos.count == 4 else { return }
        var book = realBook(photos, spreads: 2)
        // 第 2 个跨页：一整格居中的标题，正压在中缝上。
        book.pages[1] = CollagePage(root: .leaf(.text(CollageTemplates.centeredTitle())))
        book.canvas.binding = .layflat
        let flat = CollagePreflight.run(project: book, hints: [:], texts: true).filter { $0.kind == .textSafe && $0.page == 1 }
        check(flat.count == 1 && flat.first?.severity == .warn && flat.first?.message.contains("摊开时在折缝上") == true,
              "平铺：字压进中缝带只是提醒", flat.map(\.message).joined(separator: " "))
        book.canvas.binding = .glued
        let glued = CollagePreflight.run(project: book, hints: [:], texts: true).filter { $0.kind == .textSafe && $0.page == 1 }
        check(glued.count == 1 && glued.first?.severity == .block && glued.first?.message.contains("书脊会吃掉") == true,
              "胶装：拦，文案是「书脊会吃掉」", glued.map(\.message).joined(separator: " "))
        check(!CollagePreflight.run(project: book, hints: [:], texts: false).contains { $0.kind == .textSafe },
              "不排字的那一版查不出来（所以胶装时导出按钮要排一遍字）")
        let out = dir.appendingPathComponent("out")
        let store = exportStore(book, out: out, pdf: false)
        store.export()
        check(store.exportConfirm?.contains("书脊会吃掉") == true && !store.isExporting, "胶装：导出按钮先问字压中缝那一条",
              store.exportConfirm ?? "没问")
        store.exportConfirm = nil
        // 平铺：不问，导完那句后面带提醒条数。
        store.setBinding(.layflat)
        let reminders = store.preflight(texts: true).filter { $0.severity == .warn }.count
        press(store)
        check(reminders > 0 && store.exportConfirm == nil && store.progressText.hasPrefix("导出完成")
              && store.progressText.hasSuffix("导出前检查还有 \(reminders) 条提醒（导出 ▾ 里看）"),
              "平铺：不问；导出完成那句后面接提醒条数", "\(reminders) 条 / \(store.progressText)")
    }

    // MARK: - 6. 导出范围

    @MainActor
    static func checkRange(_ dir: URL, check: Check) {
        let photos = realPhotos(6, in: dir.appendingPathComponent("src"))
        guard photos.count == 6 else { return }
        let book = realBook(photos, spreads: 3)
        let out = dir.appendingPathComponent("out")
        let store = exportStore(book, out: out)
        check(store.exportButtonTitle() == "导出相册" && store.exportButtonTitle(compact: true) == "导出", "范围是全部：按钮叫「导出相册」")
        store.pageIndex = 1
        store.exportRange = .current
        check(store.exportButtonTitle() == "导出第 2 个跨页" && store.exportButtonTitle(compact: true) == "导出 2"
              && store.exportButtonHelp.contains("只导第 2 个跨页"),
              "范围是当前跨页：按钮写清导的是第 2 个", store.exportButtonTitle())
        store.exportRange = .custom("1, 3")
        check(store.exportButtonTitle() == "导出第 1、3 个跨页", "自定义：按钮写清哪几个", store.exportButtonTitle())
        store.exportRange = .custom("1-3")
        check(store.exportButtonTitle() == "导出相册", "自定义选的正好是全部 = 全部")
        store.exportRange = .custom("9")
        check(store.exportButtonTitle() == "导出相册" && store.exportBlockedReason != nil, "范围写错：按钮灰着，字不乱写")
        store.exportRange = .current
        press(store)
        check(files(out).count == 1 && files(out).first?.contains("_跨页_02.jpg") == true, "部分导出：只写了第 2 个跨页，没有 PDF",
              files(out).joined(separator: " "))
        check(store.exportRange == .all && store.exportButtonTitle() == "导出相册", "部分导出成了：范围复位成「全部」",
              "\(store.exportRange)")
        press(store)
        check(files(out).filter { $0.hasSuffix(".pdf") }.count == 1 && files(out).count == 5, "再按一次导的是整本（3 个跨页 + PDF）",
              files(out).joined(separator: " "))
        // 失败的不复位（多半要原样再来一次）。
        store.exportRange = .custom("1")
        store.testExportFailPages = [0]
        press(store)
        store.testExportFailPages = []
        check(store.exportRange == .custom("1"), "部分导出失败：范围留着")
        // 单张拼图不看范围。
        var single = book
        single.mode = .single
        store.loadForTesting(single)
        check(store.exportButtonTitle() == "导出", "单张拼图：按钮叫「导出」")
    }

    // MARK: - 7. 指纹里的当前页

    @MainActor
    static func checkDigest(check: Check) {
        let store = Review.coverStore()
        let d0 = store.editDigest
        let c0 = store.contentDigest
        check(d0.count == 12 && d0 != c0, "编辑指纹还是 12 位，和只看内容的那一半不一样")
        var flipped = true
        let changed = store.externalEdit {
            store.pageIndex = 2
            flipped = store.pageIndex == 2
        }
        check(flipped && !changed && store.contentDigest == c0, "翻页：不算改了拼图（externalEdit 的 changed、内容指纹都不变）")
        check(store.editDigest != d0, "翻页：AI 手里的指纹变了（带着旧 if_digest 的写会回 stale_digest）")
        store.pageIndex = 0
        check(store.editDigest == d0, "翻回来：指纹回到原来")
        store.setEditingCover(true)
        check(store.editDigest != d0 && store.contentDigest == c0, "进封面编辑：指纹变了，内容没变")
        store.setEditingCover(false)
        check(store.editDigest == d0, "退出封面编辑：指纹回到原来")
        check(CollageStore.viewDigest(content: c0, pageIndex: 0, editingCover: false) == d0, "viewDigest 是同一个函数（盘上的指纹也按它并）")
        // collage_pages 的 delete 必须点名删哪几个；collage_replace_photo 认 page。
        check(MCPArgs.check("collage_pages", ["session": "k", "action": "delete"]) != nil
              && MCPArgs.check("collage_pages", ["session": "k", "action": "delete", "pages": "2"]) == nil,
              "collage_pages action=delete 不给 pages：invalid_argument")
        check(MCPArgs.check("collage_pages", ["session": "k", "action": "lock"]) == nil, "lock 不给 pages 照旧 = 当前跨页")
        check(MCPArgs.check("collage_replace_photo", ["session": "k", "path": "0", "with": "R1", "page": 3]) == nil
              && MCPArgs.check("collage_replace_photo", ["session": "k", "path": "0", "with": "R1", "page": 0]) != nil,
              "collage_replace_photo 认 page（从 1 起）")
    }

    // MARK: - 8. 零碎

    static func checkPageCount(check: Check) {
        var book = Review.book()
        book.canvas.printRules = nil
        let loose = CollagePreflight.run(project: book, hints: [:], texts: false, readable: { _ in true }).filter { $0.kind == .pageCount }
        check(loose.count == 1 && loose.first?.severity == .warn && loose.first?.message.contains("还没套印厂规格") == true
              && loose.first?.message.hasPrefix("印厂要") == false,
              "没套规格：5 个跨页只是提醒，不说「印厂要」", loose.map(\.message).joined(separator: " "))
        check(CollageStore.exportConfirmation(loose, project: book, pages: nil) == nil, "导出按钮不问")
        book.canvas.printRules = .standard
        let strict = CollagePreflight.run(project: book, hints: [:], texts: false, readable: { _ in true }).filter { $0.kind == .pageCount }
        check(strict.count == 1 && strict.first?.severity == .block && strict.first?.message.hasPrefix("印厂要") == true,
              "套了规格：拦，「印厂要 …」", strict.map(\.message).joined(separator: " "))
        check(book.canvas.pageProblem(spreads: 12) == nil, "合规的页数不报")
    }

    static func checkSerial(check: Check) {
        func names(_ n: Int) -> [String] {
            let plan = CollageStore.exportPlan(base: "册", project: Export.albumProject(pages: n), options: CollageStore.ExportOptions())
            return plan.pages.flatMap { $0 }
        }
        let small = names(99)
        check(small.first == "册_跨页_01.jpg" && small.last == "册_跨页_99.jpg", "99 个跨页：序号两位（和以前一样）")
        let big = names(120)
        check(big.first == "册_跨页_001.jpg" && big[10] == "册_跨页_011.jpg" && big.last == "册_跨页_120.jpg" && big == big.sorted(),
              "120 个跨页：序号三位，按名字排就是页序", "\(big.first ?? "") … \(big.last ?? "")")
        var single = Export.albumProject(pages: 100)
        single.mode = .single
        single.canvas = CollageCanvas(name: "自检单张", width: 300, height: 400, dpi: 72, bleed: 0, safe: 0, seams: .none)
        let pages = CollageStore.exportPlan(base: "图", project: single, options: CollageStore.ExportOptions()).pages
        check(pages.first?.first == "图_001.jpg", "单张拼图 100 页同理", pages.first?.first ?? "")
    }

    @MainActor
    static func checkCoverFailure(_ dir: URL, check: Check) {
        let photos = realPhotos(4, in: dir.appendingPathComponent("src"))
        guard photos.count == 4 else { return }
        var book = realBook(photos, spreads: 2)
        var cover = CollageBookCover(front: .leaf(.photo("P0")))
        cover.spineMM = 10
        book.bookCover = cover
        let out = dir.appendingPathComponent("out")
        let store = exportStore(book, out: out)
        let ok = Export.runExport(store, project: book, options: store.exportOptions, name: "好")
        check(ok?.failure == nil && ok?.files.suffix(2) == ["好_封面.jpg", "好_封面.pdf"], "封面照常：图 + PDF", "\(ok?.files ?? []) \(ok?.failure ?? "")")
        store.testExportFailCover = true
        let bad = Export.runExport(store, project: book, options: store.exportOptions, name: "坏")
        store.testExportFailCover = false
        check((bad?.failure ?? "").contains("封面") && (bad?.failure ?? "").contains("渲染失败")
              && bad?.files.contains { $0.contains("封面") } == false && !files(out).contains { $0.hasPrefix("坏_封面") },
              "封面那一页渲染失败：报错，不写只有底色和书脊字的封面", "\(bad?.files ?? []) \(bad?.failure ?? "")")
        check((store.lastError ?? "").hasPrefix("导出失败") && !store.progressText.hasPrefix("导出完成"), "界面：导出失败")
        // 预览、缩略图（不是导出）照旧画剩下的。
        var opts = CollageRender.Options(scale: 0.5)
        opts.includeBleed = false
        check(CollageBookCoverRender.render(cover: cover, project: book, hints: [:], options: opts, failFront: true) != nil,
              "预览（不是导出）：封面那一页渲不出来照旧画书脊、封底")
        // 封面上的照片用了预览图：封面图照写，封面 PDF 不出。
        store.testUnreadableOriginals = ["P0"]
        var coverOnly = book
        coverOnly.pages = [CollagePage(root: .split(.row, 0.5, .leaf(.photo("P2")), .leaf(.photo("P3"))))]
        let low = Export.runExport(store, project: coverOnly, options: store.exportOptions, name: "糊")
        store.testUnreadableOriginals = nil
        check(low?.files.contains("糊_封面.jpg") == true && low?.files.contains("糊_封面.pdf") == false
              && low?.files.contains("糊.pdf") == true && (low?.failure ?? "").hasPrefix("封面：没生成 PDF"),
              "封面的照片用了预览图：封面图照写、封面 PDF 不出（内页 PDF 照出）", "\(low?.files ?? []) \(low?.failure ?? "")")
    }

    static func checkThumbKeys(check: Check) {
        let plain = CollagePage(root: .split(.row, 0.5, .leaf(.photo("A")), .leaf(.photo("B"))))
        var titled = plain
        titled.root = .split(.row, 0.5, .leaf(.text(CollageTemplates.centeredTitle())), .leaf(.photo("B")))
        check(!CollageStore.usesPageNumber(plain) && CollageStore.usesPageNumber(titled), "纯照片的网格页不跟页码走，有文字格的跟")
        func key(_ page: CollagePage, _ i: Int, _ n: Int) -> Int {
            CollageStore.pageThumbKey(page, index: i, count: n, shared: 7, numbered: CollageStore.usesPageNumber(page))
        }
        check(key(plain, 3, 20) == key(plain, 9, 21), "纯照片页：挪了位置、加了跨页，小图的键不变（不重渲）")
        check(key(titled, 3, 20) != key(titled, 4, 20) && key(titled, 3, 20) != key(titled, 3, 21), "有字的页：页码、页数变了键就变")
        var edited = plain
        edited.root = .split(.row, 0.6, .leaf(.photo("A")), .leaf(.photo("B")))
        check(key(plain, 3, 20) != key(edited, 3, 20), "这一页自己改了：键变")
        check(CollageStore.pageThumbKey(plain, index: 3, count: 20, shared: 7, numbered: true)
              != CollageStore.pageThumbKey(plain, index: 4, count: 20, shared: 7, numbered: true),
              "整本开着水印（记号按页码定种子）：每一页都跟页码走")
        var scattered = plain
        scattered.freeform = true
        check(CollageStore.usesPageNumber(scattered), "散落版（胶带撕口按页码定种子）：跟页码走")
    }

    // MARK: - R15 备选条悬停的大图（拼图画布那张表里的一条：store 层能验的放这里）

    @MainActor
    static func checkAltHover(check: Check) {
        let store = CollageStore(dataDir: appDataDir)
        var project = Review.book()
        project.mode = .single
        project.canvas = CollageCanvas(name: "自检单张", width: 1200, height: 900, dpi: 72, bleed: 0, safe: 0, seams: .none)
        project.pages = [CollagePage(root: .leaf(CollageCell(kind: .empty)))]
        store.loadForTesting(project)
        let hover = store.workspace.altHover
        func ready() -> Bool { !store.isSolving && store.alternatives.count > 1 && store.alternativeThumbs.count == store.alternatives.count }
        store.autoLayout(count: 5)
        Edit.spin(60) { ready() }
        guard ready() else {
            check(false, "排得出一批备选", "\(store.alternatives.count) 个")
            return
        }
        store.hoverAlternative(1)
        Edit.spin(10) { hover.index == 1 }
        check(hover.index == 1 && hover.image != nil, "前提：悬停第 2 个备选，大图出来了")
        let before = store.alternatives.count
        store.removeAlternative(0)
        check(store.alternatives.count == before - 1 && hover.index == nil && hover.image == nil,
              "从备选里去掉前面一个（后面的往前挪）：悬停的大图清掉")
        store.hoverAlternative(0)
        Edit.spin(10) { hover.index == 0 }
        check(hover.index == 0, "再悬停：按现在的这一排重渲")
        store.autoLayout(count: 5)
        Edit.spin(60) { ready() && hover.index == nil }
        check(hover.index == nil && hover.image == nil, "「换一批」回来：上一批的大图清掉（不再拿旧图对着新一批的第 N 个）")
        // 清掉以后迟到的那次渲染不再冒出来。
        store.hoverAlternative(1)
        store.removeAlternative(0)
        Edit.spin(1.0) { false }
        check(hover.index == nil && hover.image == nil, "清掉以后还在路上的那次渲染作废")
    }

    // MARK: - 9. 内页印刷 PDF 的框

    @MainActor
    static func checkPDFBoxes(_ dir: URL, check: Check) {
        let photos = realPhotos(4, in: dir.appendingPathComponent("src"))
        guard photos.count == 4 else { return }
        let book = realBook(photos, spreads: 2)
        let canvas = book.canvas
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        // 600×300 px、300 dpi、出血 12 px：成品 144×72 pt，出血 2.88 pt。
        let pt = 72.0 / canvas.dpi
        let trimW = Double(canvas.width) * pt
        let trimH = Double(canvas.height) * pt
        let bleed = Double(canvas.bleed) * pt
        for marks in [true, false] {
            let out = dir.appendingPathComponent(marks ? "marks" : "plain")
            let store = exportStore(book, out: out)
            store.exportOptions.cropMarks = marks
            let done = Export.runExport(store, project: book, options: store.exportOptions, name: "框")
            let doc = CGPDFDocument(out.appendingPathComponent("框.pdf") as CFURL)
            let slug = marks ? 10.0 / 25.4 * 72 : 0
            let media = CGRect(x: 0, y: 0, width: trimW + 2 * bleed + 2 * slug, height: trimH + 2 * bleed + 2 * slug)
            let bleedBox = CGRect(x: slug, y: slug, width: trimW + 2 * bleed, height: trimH + 2 * bleed)
            let trimBox = CGRect(x: slug + bleed, y: slug + bleed, width: trimW, height: trimH)
            var good = done?.failure == nil && doc?.numberOfPages == 2
            var detail = "\(done?.failure ?? "")"
            for n in 1...2 {
                guard let page = doc?.page(at: n) else {
                    good = false
                    continue
                }
                let m = page.getBoxRect(.mediaBox)
                let b = page.getBoxRect(.bleedBox)
                let t = page.getBoxRect(.trimBox)
                if !(close(m, media) && close(b, bleedBox) && close(t, trimBox)) {
                    good = false
                    detail += " 第 \(n) 页 media \(m) bleed \(b) trim \(t)"
                }
            }
            check(good, marks ? "带裁切线：MediaBox 多出 10mm 一圈，BleedBox = 成品 + 出血，TrimBox = 成品（144×72 pt）"
                              : "不带裁切线：MediaBox = BleedBox，TrimBox 往里收一圈出血", detail)
            // 跨页图的像素 = 成品 + 两边出血（和 BleedBox 对得上）。
            let jpg = out.appendingPathComponent("框_跨页_01.jpg")
            let size = CGImageSourceCreateWithURL(jpg as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            check(size?.width == canvas.width + 2 * canvas.bleed && size?.height == canvas.height + 2 * canvas.bleed,
                  "跨页图 \(canvas.width + 2 * canvas.bleed)×\(canvas.height + 2 * canvas.bleed) px（成品 + 出血）",
                  "\(size?.width ?? 0)×\(size?.height ?? 0)")
        }
    }
}
