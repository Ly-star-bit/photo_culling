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
///    PNG 跨页写出来了、只是 PDF 那份 JPEG 编不出来（testExportFailPDFEncodePages）：照样不出 PDF，提示说「图写出来了、
///    但没能放进 PDF」、不说「没写出来」，和 files 对得上；和渲染失败的同时有时两句各说各的页号。
/// 4. 空照片格（emptyPhotoSlots / emptySlotWarning，导出按钮和 MCP 共用）：只数网格页上没照片（或照片不在托盘）的照片格，
///    留白格、文字格、散落版、印样不算；提醒那句话写对页号；导出按钮有空格时先不导、等确认（exportConfirm），点了「仍然导出」
///    才导，没有空格直接导、不问。
/// 5. 写 PDF 时退出 / 崩溃留下的隐藏临时文件：sweepStalePDFTemps 只删输出目录第一层、名字是 writePDF 那种
///    （.<名字>.pdf.<8 位大写十六进制>.tmp，和 writePDF 真起的名字对得上）、普通文件、10 分钟没动过的；新的、预览缓存那种
///    .jpg 的、小写 / 7 位的、看得见的、目录、符号链接（目标也不碰）、子目录里的都不动；startExport 开工时清一遍。
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
        print("== PDF 临时文件残留清理")
        staleTempSweep(store, root.appendingPathComponent("sweep"), check: check)
        print("== 相册导出全流程")
        albumExport(store, root.appendingPathComponent("album"), check: check)
        print("== 相册有跨页没写出来")
        albumFailure(store, root.appendingPathComponent("fail"), check: check)
        print("== 空照片格")
        emptySlots(check: check)
        emptySlotConfirm(store, root.appendingPathComponent("confirm"), check: check)

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

    // MARK: - 5. PDF 临时文件残留清理

    @MainActor
    private static func staleTempSweep(_ store: CollageStore, _ dir: URL, check: Checks) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let hourAgo = Date().addingTimeInterval(-3600)
        func touch(_ name: String, at date: Date?, in folder: URL? = nil) {
            let url = (folder ?? dir).appendingPathComponent(name)
            try? Data("半截 PDF".utf8).write(to: url)
            if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        }
        func exists(_ name: String, in folder: URL? = nil) -> Bool {
            // 符号链接自己在不在（fileExists 会跟着链接走）
            (try? fm.attributesOfItem(atPath: (folder ?? dir).appendingPathComponent(name).path)) != nil
        }

        // writePDF 真起的临时文件名得是清理认的那一种（两边的规则走样了这里先红）
        var realTemp = ""
        if let page = jpeg(width: 624, height: 324, gray: 0.5) {
            try? CollageExport.writePDF(pages: [.data(page)], canvas: smallSpread, to: dir.appendingPathComponent("真.pdf"),
                                        title: "自检", cropMarks: false, overwrite: false) { realTemp = $0.lastPathComponent }
        }
        check(CollageExport.isPDFTempName(realTemp) && !exists(realTemp), "writePDF 的临时文件名清理认得、写完已经没了",
              realTemp)
        let names: [(String, Bool)] = [
            (".相册.pdf.1A2B3C4D.tmp", true), (".20261104-101500-2.pdf.0F9E8D7C.tmp", true),
            (".相册.pdf.1a2b3c4d.tmp", false), (".相册.pdf.1A2B3C4.tmp", false), (".相册.pdf.1A2B3C4D5.tmp", false),
            (".相册_跨页_01.jpg.ABCDEF01.tmp", false), (".pdf.1A2B3C4D.tmp", false), ("相册.pdf.1A2B3C4D.tmp", false),
            (".相册.pdf.1A2B3C4D", false), (".相册.pdf.GHIJKLMN.tmp", false), (".x.jpg.tmp-123-abcd", false),
            (".相册.pdf.1A2B3C4D.tmp.tmp", false),
        ]
        let wrong = names.filter { CollageExport.isPDFTempName($0.0) != $0.1 }.map(\.0)
        check(wrong.isEmpty, "临时文件名规则：只认 .<名字>.pdf.<8 位大写十六进制>.tmp", wrong.joined(separator: " "))

        let stale = ".相册.pdf.1A2B3C4D.tmp"
        let fresh = ".相册.pdf.5E6F7A8B.tmp"
        let nineMinutes = ".相册.pdf.99990000.tmp"
        touch(stale, at: hourAgo)
        touch(fresh, at: nil)
        touch(nineMinutes, at: Date().addingTimeInterval(-540))
        // 小写那个不能和 stale 只差大小写：APFS 默认不分大小写，会是同一个文件
        let keptStale = [".相册_跨页_01.jpg.ABCDEF01.tmp", ".相册.pdf.abcdef12.tmp", ".相册.pdf.1A2B3C4.tmp",
                         "相册.pdf.1A2B3C4D.tmp", "别人的.tmp", ".x.jpg.tmp-123-abcd", ".DS_Store", "相册.pdf"]
        for name in keptStale { touch(name, at: hourAgo) }
        // 名字对得上的目录、符号链接（自己和目标都是一小时前）、子目录里的：都不动
        let folderNamed = ".目录.pdf.0A0B0C0D.tmp"
        try? fm.createDirectory(at: dir.appendingPathComponent(folderNamed), withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: hourAgo], ofItemAtPath: dir.appendingPathComponent(folderNamed).path)
        let target = "链接目标.pdf"
        touch(target, at: hourAgo)
        let link = ".链接.pdf.11112222.tmp"
        try? fm.createSymbolicLink(atPath: dir.appendingPathComponent(link).path, withDestinationPath: target)
        var times = [timeval(tv_sec: Int(hourAgo.timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: Int(hourAgo.timeIntervalSince1970), tv_usec: 0)]
        _ = lutimes(dir.appendingPathComponent(link).path, &times)
        let linkDate = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(link).path))?[.modificationDate] as? Date
        let sub = dir.appendingPathComponent("子目录")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        touch(stale, at: hourAgo, in: sub)
        check(linkDate.map { $0 < Date().addingTimeInterval(-1800) } == true, "符号链接自己的修改时间也是一小时前（夹具）",
              "\(linkDate.map { "\($0)" } ?? "nil")")

        let removed = CollageExport.sweepStalePDFTemps(in: dir)
        check(removed == [stale] && !exists(stale), "只删了那份一小时前的 PDF 临时文件", removed.joined(separator: " "))
        check(exists(fresh) && exists(nineMinutes), "刚写的、9 分钟前的（可能正在写）留着")
        let gone = keptStale.filter { !exists($0) }
        check(gone.isEmpty, "预览缓存、小写、7 位、看得见的、别的隐藏文件、正式 PDF 都不动", gone.joined(separator: " "))
        check(exists(folderNamed) && exists(link) && exists(target) && exists(stale, in: sub),
              "名字对得上的目录、符号链接和它的目标、子目录里的都不动")
        check(CollageExport.sweepStalePDFTemps(in: dir.appendingPathComponent("没有这个目录")).isEmpty, "目录不存在：什么也不做")

        // startExport 开工时清一遍（导出按钮、MCP 同一条路）
        let out = dir.appendingPathComponent("导出")
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        touch(stale, at: hourAgo, in: out)
        touch(fresh, at: nil, in: out)
        var options = CollageStore.ExportOptions()
        options.outputPath = out.path
        options.pdf = true
        store.exportOptions = options
        let outcome = runExport(store, project: albumProject(pages: 2), options: options, name: "清理")
        check(outcome?.failure == nil && outcome?.files.last == "清理.pdf" && pageCount(out.appendingPathComponent("清理.pdf")) == 2,
              "导出照常（2 个跨页 + PDF）", "\(outcome?.files ?? []) \(outcome?.failure ?? "")")
        check(!exists(stale, in: out) && exists(fresh, in: out) && leftovers(out) == [fresh],
              "导出开工时清掉了过期的临时文件，新的留着", leftovers(out).joined(separator: " "))
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

        // e) PNG：第 2 个跨页的图写出来了，只是 PDF 用的那份 JPEG 编不出来 —— 照样不出 PDF，但不说「没写出来」
        let e = dir.appendingPathComponent("e")
        options.outputPath = e.path
        options.format = .png
        store.exportOptions = options
        store.testExportFailPDFEncodePages = [1]
        let o5 = runExport(store, project: albumProject(pages: 3), options: options, name: "编码")
        store.testExportFailPDFEncodePages = []
        let failure5 = o5?.failure ?? ""
        check(o5?.files == ["编码_跨页_01.png", "编码_跨页_02.png", "编码_跨页_03.png"]
              && fm.fileExists(atPath: e.appendingPathComponent("编码_跨页_02.png").path)
              && !fm.fileExists(atPath: e.appendingPathComponent("编码.pdf").path) && leftovers(e).isEmpty,
              "PNG 跨页写出来了、PDF 那份编不出来：三张都列出、不出 PDF", "\(o5?.files ?? [])")
        check(failure5.contains("转不成 PDF 页") && failure5.contains("没生成 PDF")
              && failure5.contains("第 2 个跨页的图写出来了、但没能放进 PDF") && !failure5.contains("没写出来"),
              "提示说图写出来了、没能放进 PDF，不说「没写出来」", failure5)
        check((store.lastError ?? "").hasPrefix("导出失败") && !store.progressText.hasPrefix("导出完成"),
              "界面照样是导出失败", store.lastError ?? "")

        // f) 第 1 个跨页渲染失败 + 第 3 个跨页只是 PDF 那份编不出来：两句各说各的页号
        let f = dir.appendingPathComponent("f")
        options.outputPath = f.path
        store.exportOptions = options
        store.testExportFailPages = [0]
        store.testExportFailPDFEncodePages = [2]
        let o6 = runExport(store, project: albumProject(pages: 3), options: options, name: "两种")
        store.testExportFailPages = []
        store.testExportFailPDFEncodePages = []
        let failure6 = o6?.failure ?? ""
        check(o6?.files == ["两种_跨页_02.png", "两种_跨页_03.png"]
              && !fm.fileExists(atPath: f.appendingPathComponent("两种.pdf").path),
              "渲染失败的不列、只缺 PDF 那份的照列，不出 PDF", "\(o6?.files ?? [])")
        check(failure6.contains("第 1 个跨页没写出来，第 3 个跨页的图写出来了、但没能放进 PDF")
              && !failure6.contains("第 3 个跨页没写出来"), "两种失败各说各的页号", failure6)

        // pdfSkippedNote 本身：跨页多时只列前 8 个（以前多打了一个「个」：「等 10 个 个跨页」）
        let many = CollageStore.pdfSkippedNote(Array(0..<10))
        check(many.contains("第 1、2、3、4、5、6、7、8 等 10 个跨页没写出来") && !many.contains("个 个"),
              "跨页多时只列前 8 个", many)
        let mixed = CollageStore.pdfSkippedNote([0, 1, 2], written: [1])
        check(mixed.hasPrefix("没生成 PDF：第 1、3 个跨页没写出来，第 2 个跨页的图写出来了、但没能放进 PDF"),
              "没写出来的、只缺 PDF 的分开列", mixed)
        options.format = .jpeg

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

    // MARK: - 4. 空照片格

    private static func emptySlots(check: Checks) {
        let tray = CollagePhotoRef(id: "p1", path: "/nonexistent/selftest/p1.jpg", width: 3000, height: 2000)
        func single(_ root: CollageNode) -> CollageProject {
            var p = CollageProject()
            p.canvas = CollageCanvas(name: "自检单张", width: 300, height: 400)
            p.photos = [tray]
            p.pages = [CollagePage(root: root)]
            return p
        }
        func count(_ p: CollageProject) -> Int { CollageStore.emptyPhotoSlots(project: p).count }

        let blank = single(CollageLayout.blankRoot(for: CollageCanvas(name: "自检单张", width: 300, height: 400)))
        check(count(blank) == 1, "空白页的照片格：1 个", "\(count(blank))")
        let warning = CollageStore.emptySlotWarning(CollageStore.emptyPhotoSlots(project: blank), project: blank) ?? ""
        check(warning.hasPrefix("有 1 个空照片格"), "单页：「有 1 个空照片格」", warning)

        let filled = single(.split(.row, 0.5, .leaf(photoCell("p1")), .leaf(CollageCell(kind: .empty))))
        check(count(filled) == 0, "放了托盘里的照片 + 留白格：0 个", "\(count(filled))")
        check(CollageStore.emptySlotWarning([], project: filled) == nil, "没有空格：不提醒")
        var text = CollageCell(kind: .text)
        text.text = CollageText()
        let gone = single(.split(.column, 0.5, .leaf(photoCell("不在托盘")), .leaf(text)))
        check(count(gone) == 1, "照片不在托盘里的照片格算空，文字格不算", "\(count(gone))")

        var freeform = single(.leaf(CollageCell(kind: .photo)))
        freeform.pages[0].freeform = true
        check(count(freeform) == 0, "散落版不看切分树", "\(count(freeform))")
        var sheet = single(.leaf(CollageCell(kind: .photo)))
        sheet.pages[0].contactSheet = CollageContactSheet()
        check(count(sheet) == 0, "印样整页按片条画，不看切分树", "\(count(sheet))")

        // 相册 8 个跨页，第 3、7 个各留了一页空（胶装单张跨页那种：左页空着）
        var album = albumProject(pages: 8)
        album.photos = [tray]
        let half = CollageNode.split(.row, 0.5, .leaf(CollageCell(kind: .photo)), .leaf(photoCell("p1")))
        album.pages[2].root = half
        album.pages[6].root = half
        album.pages[0].root = .split(.row, 0.5, .leaf(photoCell("p1")), .leaf(photoCell("p1")))
        let slots = CollageStore.emptyPhotoSlots(project: album)
        let albumWarning = CollageStore.emptySlotWarning(slots, project: album) ?? ""
        check(slots.map(\.page) == [2, 6] && slots.allSatisfy { $0.path == [0] }, "相册：第 3、7 个跨页的左页",
              "\(slots.map { "\($0.page):\($0.path)" })")
        check(albumWarning.hasPrefix("第 3、7 个跨页上有 2 个空照片格"), "相册：提醒写对跨页号", albumWarning)
        var many = albumProject(pages: 10)
        many.pages = many.pages.map { _ in CollagePage(root: .leaf(CollageCell(kind: .photo))) }
        let manyWarning = CollageStore.emptySlotWarning(CollageStore.emptyPhotoSlots(project: many), project: many) ?? ""
        check(manyWarning.hasPrefix("第 1、2、3、4、5、6、7、8 等 10 个跨页上有 10 个空照片格"), "跨页多时只列前 8 个", manyWarning)
    }

    @MainActor
    private static func emptySlotConfirm(_ store: CollageStore, _ dir: URL, check: Checks) {
        let fm = FileManager.default
        func files(_ d: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }
        // 托盘是空的、加一页空白页：一个空照片格
        let a = dir.appendingPathComponent("a")
        var options = CollageStore.ExportOptions()
        options.outputPath = a.path
        store.exportOptions = options
        store.exportName = "空格"
        store.addPage()
        let slots = CollageStore.emptyPhotoSlots(project: store.project)
        check(slots.count == 1 && store.exportBlockedReason == nil, "加一页空白页：1 个空照片格、可以导出",
              "\(slots.count) \(store.exportBlockedReason ?? "")")
        store.export()
        check(store.exportConfirm?.hasPrefix("有 1 个空照片格") == true && !store.isExporting && files(a).isEmpty,
              "有空格：先不导，等确认", "\(store.exportConfirm ?? "nil") 导出中=\(store.isExporting) \(files(a))")
        store.export(confirmed: true)
        spin(60) { !store.isExporting }
        check(store.exportConfirm == nil && files(a) == ["空格.jpg"], "点了「仍然导出」：导出来", "\(files(a))")

        // 换成一个文字格：没有空格，直接导、不问（不用留白格换：版式语法里没照片的照片格就写成留白，
        // applyDesignedLayout 的 snap 会把原来那个空照片格原样留下）
        let b = dir.appendingPathComponent("b")
        options.outputPath = b.path
        store.exportOptions = options
        var text = CollageCell(kind: .text)
        text.text = CollageText()
        store.applyDesignedLayout(.leaf(text))
        let none = CollageStore.emptyPhotoSlots(project: store.project).isEmpty
        store.export()
        let asked = store.exportConfirm
        let started = store.isExporting
        spin(60) { !store.isExporting }
        check(none && asked == nil && started && files(b) == ["空格.jpg"], "没有空格：不问，直接导出",
              "空格没了=\(none) \(asked ?? "nil") 开始了=\(started) \(files(b))")
    }
}
