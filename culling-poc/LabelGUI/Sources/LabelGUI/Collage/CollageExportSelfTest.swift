import Foundation
import CoreGraphics
import ImageIO

/// LabelGUI --collage-export-selftest（合成数据，不读照片；只往 LABELGUI_DATA_DIR 里自己建的目录写，跑完删掉）
///
/// 1. 相册 PDF 先写临时文件、读回来校验、再改名：正常写出页数对、结尾有 %%EOF、没有残留的临时文件；从盘上的页文件
///    逐页读和从内存读写出来的一样；写完被截断（afterClose 模拟盘满）、某一页 JPEG 读不了、目录不存在、正式名上已经
///    有文件（不覆盖）都抛错，盘上不留 PDF 也不留临时文件，已有的那个文件原样不动；verifyPDF 认得出空文件、截断、页数不对。
/// 2. 相册导出全流程（CollageStore.startExport，导出按钮和 MCP 同一条路）：JPEG（PDF 从盘上的跨页文件读）、PNG（PDF 用
///    另编的 JPEG）都写出每个跨页 + 一份页数对的 PDF，PDF 列在 files 最后，目录里没有临时文件。
/// 3. 相册有跨页没写出来（testExportFailPages 当成渲染失败）：不出 PDF（盘上没有、files 里没有、没有临时文件），failure 写明
///    缺第几个跨页，写出来的跨页照实列出；同一次导出还有软警告（照片读不了）时「导出失败」不被它盖掉，警告接在后面。
/// 全过退出 0，否则 1。
enum CollageExportSelfTest {

    @MainActor
    static func run() -> Never {
        // 无头：一个界面都不碰，导出完也不许弹访达（AppRuntime.revealInFinder）。
        AppRuntime.headless = true
        CollageCLI.requireIsolatedDataDir("--collage-export-selftest")
        let check = Checks()
        let root = appDataDir.appendingPathComponent("export-selftest-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        print("== 相册 PDF：临时文件 + 校验 + 改名")
        pdfWrite(root.appendingPathComponent("pdf"), check: check)
        let store = CollageStore(dataDir: appDataDir)
        print("== 相册导出全流程")
        albumExport(store, root.appendingPathComponent("album"), check: check)
        print("== 相册有跨页没写出来")
        albumFailure(store, root.appendingPathComponent("fail"), check: check)

        try? FileManager.default.removeItem(at: root)
        if check.failures.isEmpty {
            print("全部通过")
            exit(0)
        }
        print("失败 \(check.failures.count) 项：" + check.failures.joined(separator: "；"))
        exit(1)
    }

    final class Checks {
        var failures: [String] = []
        func callAsFunction(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }
    }

    // MARK: - 小工具

    /// 一张纯色的小 JPEG（不读照片）。
    static func jpeg(width: Int, height: Int, gray: Double) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return nil }
        return CollageExport.encode(image, format: .jpeg, quality: 0.9, dpi: 300)
    }

    /// 目录里的隐藏临时文件（.<名字>.<随机>.tmp）。
    static func leftovers(_ dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(".") && $0.hasSuffix(".tmp") }.sorted()
    }

    static func pageCount(_ url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? -1
    }

    /// 等主线程上的回调（导出在 Task 里跑，要转主线程的 RunLoop）。
    @MainActor
    static func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// 走一次 startExport，等 done 回来（超时 = nil）。
    @MainActor
    static func runExport(_ store: CollageStore, project: CollageProject, options: CollageStore.ExportOptions,
                          name: String) -> CollageStore.ExportOutcome? {
        var result: CollageStore.ExportOutcome?
        let refused = store.startExport(project: project, options: options, name: name, reveal: false) { result = $0 }
        if refused != nil { return result }
        spin(120) { result != nil }
        // done 在导出 Task 的 defer 里回调，那时 isExporting 刚放下：再转一下 RunLoop 让它落地
        spin(5) { !store.isExporting }
        return result
    }

    /// 相册工程：pages 个跨页，每个跨页左右两格留白（不读照片）。
    static func albumProject(pages: Int) -> CollageProject {
        var p = CollageProject()
        p.mode = .album
        p.canvas = smallSpread
        p.title = "自检相册"
        p.pages = (0..<pages).map { _ in
            CollagePage(root: .split(.row, 0.5, .leaf(CollageCell(kind: .empty)), .leaf(CollageCell(kind: .empty))))
        }
        return p
    }

    static func photoCell(_ id: String) -> CollageCell {
        var cell = CollageCell(kind: .photo)
        cell.photoID = id
        return cell
    }

    /// 小号的相册跨页画布（300 dpi、带出血、中缝）：渲染、编码都快。
    static let smallSpread: CollageCanvas = {
        var c = CollageCanvas(name: "自检跨页", width: 600, height: 300, dpi: 300, bleed: 12, safe: 0, seams: .fold)
        c.binding = .layflat
        return c
    }()

    // MARK: - 1. writePDF

    private static func pdfWrite(_ dir: URL, check: Checks) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let canvas = smallSpread
        let pages = [0.2, 0.5, 0.8].compactMap { jpeg(width: 624, height: 324, gray: $0) }
        check(pages.count == 3, "合成 3 页 JPEG", "\(pages.count)")

        // 正常：内存里的数据
        let good = dir.appendingPathComponent("好.pdf")
        var thrown: Error?
        do {
            try CollageExport.writePDF(pages: pages.map { .data($0) }, canvas: canvas, to: good, title: "自检",
                                       cropMarks: true, overwrite: false)
        } catch { thrown = error }
        check(thrown == nil && pageCount(good) == 3 && CollageExport.verifyPDF(at: good, pages: 3) == nil,
              "正常写出：3 页、校验通过", "\(thrown?.localizedDescription ?? "") 页数 \(pageCount(good))")
        check(leftovers(dir).isEmpty, "正常写出：没有残留的临时文件", leftovers(dir).joined(separator: " "))

        // 从盘上的页文件逐页读（相册 JPEG 格式走这条）
        var files: [URL] = []
        for (i, data) in pages.enumerated() {
            let url = dir.appendingPathComponent("页_\(i + 1).jpg")
            try? data.write(to: url, options: .atomic)
            files.append(url)
        }
        let fromFiles = dir.appendingPathComponent("从文件.pdf")
        thrown = nil
        do {
            try CollageExport.writePDF(pages: files.map { .file($0) }, canvas: canvas, to: fromFiles, title: "自检",
                                       cropMarks: true, overwrite: false)
        } catch { thrown = error }
        let sizeA = (try? fm.attributesOfItem(atPath: good.path)[.size] as? Int) ?? 0
        let sizeB = (try? fm.attributesOfItem(atPath: fromFiles.path)[.size] as? Int) ?? -1
        // JPEG 原样嵌入：两份 PDF 只差文件里的时间戳之类，大小应该几乎一样
        check(thrown == nil && pageCount(fromFiles) == 3 && abs(sizeA - sizeB) < 256,
              "从页文件逐页读：3 页，和内存那份一样大", "\(sizeA) vs \(sizeB) \(thrown?.localizedDescription ?? "")")

        // 写完被截断（模拟盘满：closePDF 不报错，只能读回来查）
        let cut = dir.appendingPathComponent("截断.pdf")
        thrown = nil
        do {
            try CollageExport.writePDF(pages: pages.map { .data($0) }, canvas: canvas, to: cut, title: "自检",
                                       cropMarks: true, overwrite: false) { tmp in
                if let h = FileHandle(forWritingAtPath: tmp.path) {
                    let size = (try? h.seekToEnd()) ?? 0
                    try? h.truncate(atOffset: size / 2)
                    try? h.close()
                }
            }
        } catch { thrown = error }
        check(thrown != nil && !fm.fileExists(atPath: cut.path) && leftovers(dir).isEmpty,
              "写完被截断：抛错、不留 PDF、不留临时文件", thrown?.localizedDescription ?? "没抛错")

        // 某一页 JPEG 读不了（页文件被挪走了 / 数据坏了）：不出一份少了画面的 PDF
        let broken = dir.appendingPathComponent("坏页.pdf")
        thrown = nil
        do {
            try CollageExport.writePDF(pages: [.data(pages[0]), .data(Data("不是 JPEG".utf8)), .data(pages[2])],
                                       canvas: canvas, to: broken, title: "自检", cropMarks: false, overwrite: false)
        } catch { thrown = error }
        let pageError = (thrown as? CollageExport.ExportError).map { if case .pdfPage(2) = $0 { return true } else { return false } } ?? false
        check(pageError && !fm.fileExists(atPath: broken.path) && leftovers(dir).isEmpty,
              "第 2 页数据坏了：报第 2 页、不留 PDF、不留临时文件", thrown?.localizedDescription ?? "没抛错")
        let gone = dir.appendingPathComponent("页文件没了.pdf")
        thrown = nil
        do {
            try CollageExport.writePDF(pages: [.file(files[0]), .file(dir.appendingPathComponent("没有这个.jpg"))],
                                       canvas: canvas, to: gone, title: "自检", cropMarks: false, overwrite: false)
        } catch { thrown = error }
        check(thrown != nil && !fm.fileExists(atPath: gone.path) && leftovers(dir).isEmpty,
              "页文件不见了：抛错、不留 PDF", thrown?.localizedDescription ?? "没抛错")

        // 目录不存在
        let nowhere = dir.appendingPathComponent("没有这个目录/相册.pdf")
        thrown = nil
        do {
            try CollageExport.writePDF(pages: pages.map { .data($0) }, canvas: canvas, to: nowhere, title: "自检",
                                       cropMarks: false, overwrite: false)
        } catch { thrown = error }
        check(thrown != nil && !fm.fileExists(atPath: nowhere.path), "目录不存在：抛错",
              thrown?.localizedDescription ?? "没抛错")

        // 正式名上已经有文件：不覆盖（导出按钮），原来的一个字节不变；overwrite（命令行 album.pdf）照旧覆盖
        let taken = dir.appendingPathComponent("已有.pdf")
        let old = Data("原来的文件".utf8)
        try? old.write(to: taken)
        thrown = nil
        do {
            try CollageExport.writePDF(pages: pages.map { .data($0) }, canvas: canvas, to: taken, title: "自检",
                                       cropMarks: false, overwrite: false)
        } catch { thrown = error }
        let exists = (thrown as? CollageExport.ExportError).map { if case .pdfExists = $0 { return true } else { return false } } ?? false
        check(exists && (try? Data(contentsOf: taken)) == old && leftovers(dir).isEmpty,
              "正式名已经有了（不覆盖）：报已存在、原文件不动、不留临时文件", thrown?.localizedDescription ?? "没抛错")
        thrown = nil
        do {
            try CollageExport.writePDF(jpegPages: pages, canvas: canvas, to: taken, title: "自检", cropMarks: false)
        } catch { thrown = error }
        check(thrown == nil && pageCount(taken) == 3 && leftovers(dir).isEmpty, "overwrite：换成新的 3 页 PDF",
              thrown?.localizedDescription ?? "")

        // verifyPDF 本身
        let empty = dir.appendingPathComponent("空.pdf")
        try? Data().write(to: empty)
        let half = dir.appendingPathComponent("半截.pdf")
        if let whole = try? Data(contentsOf: good) { try? whole.prefix(whole.count / 2).write(to: half) }
        check(CollageExport.verifyPDF(at: empty, pages: 3) != nil, "verifyPDF：空文件不过")
        check(CollageExport.verifyPDF(at: half, pages: 3) != nil, "verifyPDF：半截不过",
              CollageExport.verifyPDF(at: half, pages: 3) ?? "")
        check(CollageExport.verifyPDF(at: good, pages: 4) != nil, "verifyPDF：页数不对不过",
              CollageExport.verifyPDF(at: good, pages: 4) ?? "")
        check(CollageExport.verifyPDF(at: dir.appendingPathComponent("没有.pdf"), pages: 1) != nil, "verifyPDF：没有这个文件不过")
    }

    // MARK: - 2. 相册导出全流程

    @MainActor
    private static func albumExport(_ store: CollageStore, _ dir: URL, check: Checks) {
        let project = albumProject(pages: 3)
        for format in [CollageExport.Format.jpeg, .png] {
            let out = dir.appendingPathComponent(format.rawValue)
            var options = CollageStore.ExportOptions()
            options.outputPath = out.path
            options.format = format
            options.pdf = true
            store.exportOptions = options
            let outcome = runExport(store, project: project, options: options, name: "相册")
            let ext = format.ext
            let want = ["相册_跨页_01.\(ext)", "相册_跨页_02.\(ext)", "相册_跨页_03.\(ext)", "相册.pdf"]
            let pdf = out.appendingPathComponent("相册.pdf")
            check(outcome != nil && outcome?.failure == nil && outcome?.files == want,
                  "\(format.label)：3 个跨页 + PDF，PDF 在最后", "\(outcome?.files ?? []) \(outcome?.failure ?? "")")
            check(pageCount(pdf) == 3 && CollageExport.verifyPDF(at: pdf, pages: 3) == nil && leftovers(out).isEmpty,
                  "\(format.label)：PDF 3 页、校验通过、没有临时文件", "页数 \(pageCount(pdf)) \(leftovers(out))")
            check(store.lastError == nil && store.progressText.hasPrefix("导出完成"), "\(format.label)：界面显示导出完成",
                  "\(store.progressText) \(store.lastError ?? "")")
        }
    }

    // MARK: - 3. 相册有跨页没写出来

    @MainActor
    private static func albumFailure(_ store: CollageStore, _ dir: URL, check: Checks) {
        let fm = FileManager.default
        // a) 第 2 个跨页渲染失败（JPEG）
        let a = dir.appendingPathComponent("a")
        var options = CollageStore.ExportOptions()
        options.outputPath = a.path
        options.pdf = true
        store.exportOptions = options
        store.testExportFailPages = [1]
        let o1 = runExport(store, project: albumProject(pages: 3), options: options, name: "缺页")
        store.testExportFailPages = []
        let failure1 = o1?.failure ?? ""
        check(failure1.contains("第 2 个跨页没写出来") && failure1.contains("没生成 PDF"),
              "第 2 个跨页失败：failure 写明没生成 PDF、缺第 2 个跨页", failure1)
        check(o1?.files == ["缺页_跨页_01.jpg", "缺页_跨页_03.jpg"], "写出来的两个跨页照实列出，没有 PDF",
              "\(o1?.files ?? [])")
        check(!fm.fileExists(atPath: a.appendingPathComponent("缺页.pdf").path) && leftovers(a).isEmpty,
              "盘上没有 PDF、没有临时文件", "\(((try? fm.contentsOfDirectory(atPath: a.path)) ?? []).sorted())")
        check((store.lastError ?? "").hasPrefix("导出失败") && !store.progressText.hasPrefix("导出完成"),
              "界面：导出失败，不说导出完成", "\(store.lastError ?? "") / \(store.progressText)")

        // b) PNG + 第 1 个跨页上的照片读不了（软警告）+ 第 3 个跨页失败：「导出失败」不被软警告盖掉
        let b = dir.appendingPathComponent("b")
        options.outputPath = b.path
        options.format = .png
        store.exportOptions = options
        var project = albumProject(pages: 3)
        let ghost = CollagePhotoRef(id: "ghost", path: appDataDir.appendingPathComponent("没有这张.jpg").path,
                                    width: 3000, height: 2000)
        project.photos = [ghost]
        project.pages[0].root = .split(.row, 0.5, .leaf(photoCell("ghost")), .leaf(CollageCell(kind: .empty)))
        store.testExportFailPages = [2]
        let o2 = runExport(store, project: project, options: options, name: "缺页")
        store.testExportFailPages = []
        let failure2 = o2?.failure ?? ""
        let warning2 = o2?.warning ?? ""
        let shown = store.lastError ?? ""
        check(failure2.contains("第 3 个跨页没写出来") && o2?.files == ["缺页_跨页_01.png", "缺页_跨页_02.png"]
              && !fm.fileExists(atPath: b.appendingPathComponent("缺页.pdf").path) && leftovers(b).isEmpty,
              "PNG：第 3 个跨页失败，不出 PDF", "\(failure2) \(o2?.files ?? [])")
        check(!warning2.isEmpty && shown.hasPrefix("导出失败") && shown.contains(failure2) && shown.contains(warning2),
              "有软警告时「导出失败」不被盖掉，警告接在后面", shown)

        // c) 没有失败、只有软警告：照旧出 PDF，界面显示那条警告（不算失败）
        let c = dir.appendingPathComponent("c")
        options.outputPath = c.path
        options.format = .jpeg
        store.exportOptions = options
        let o3 = runExport(store, project: project, options: options, name: "软警告")
        check(o3?.failure == nil && o3?.files.last == "软警告.pdf" && pageCount(c.appendingPathComponent("软警告.pdf")) == 3,
              "只有软警告：PDF 照出（3 页）", "\(o3?.failure ?? "") \(o3?.files ?? [])")
        check(store.lastError == o3?.warning && store.lastError != nil && store.progressText.hasPrefix("导出完成"),
              "只有软警告：界面是那条警告 + 导出完成", "\(store.lastError ?? "") / \(store.progressText)")

        // d) 单张模式不受影响（没有 PDF）
        let d = dir.appendingPathComponent("d")
        options.outputPath = d.path
        store.exportOptions = options
        var single = CollageProject()
        single.canvas = CollageCanvas(name: "自检单张", width: 300, height: 400)
        single.pages = [CollagePage(root: .leaf(CollageCell(kind: .empty)))]
        let o4 = runExport(store, project: single, options: options, name: "单张")
        check(o4?.failure == nil && o4?.files == ["单张.jpg"], "单张模式照旧", "\(o4?.files ?? [])")
    }
}
