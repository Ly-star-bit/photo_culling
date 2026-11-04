import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 诊断这一组的无头自检（审查 D03）：LABELGUI_DATA_DIR=<临时> LabelGUI --diag-selftest [<photo_dir>] [--out <目录>]
///   A 状态栏提示的历史：20 条环形、新的在前、连着一样的只记次数、分级；三个 store 的 lastError 一设上就记、类型还是 String?
///   B 持久日志：一条一行、换行折掉、轮转（个数、大小）、提示历史跟着进日志
///   C 诊断包：zip 里有说明 / 诊断信息 / 提示 / 日志 / 场次概况 / 目录结构 / 崩溃报告（只要最近的、选片工具的），
///     没有照片、预览图（连名字都没有）、bookmark、客户备注原文、场次文件夹名、家目录
///   D 失败原因：盘不支持废纸篓、没权限、只读盘、盘满、EPERM；原因汇总；废纸篓移走一半；不限体积那条路逐字节和以前一样、
///     写不进去报「没有权限」；writeJPEG 原片不在 / 解不开；水印页拿到真原因
///   E 文件夹权限：chmod 000 的照片文件夹分析时报「没有权限读这个文件夹 … 系统设置 › 隐私与安全性 › 文件与文件夹」，
///     不报「没有支持的图片文件」；空文件夹照旧；读不了的子文件夹跳过；开关按位置点名
/// 只写 LABELGUI_DATA_DIR 下面（照片文件夹参数只读：拿第一张 JPG 再核对一次逐字节）。--out 给定时把展开的提示面板拍成 PNG。
enum DiagnosticsSelfTest {
    @MainActor
    static func run() -> Never {
        CollageCLI.requireIsolatedDataDir("--diag-selftest", "会在数据目录里建 logs/、假的场次和临时文件夹")
        let fm = FileManager.default
        let work = appDataDir.appendingPathComponent("diag-selftest", isDirectory: true)
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let check = Check()

        historyChecks(work, check)
        logChecks(work, check)
        bundleChecks(work, check)
        reasonChecks(work, check)
        permissionChecks(work, check)
        if let i = CommandLine.arguments.firstIndex(of: "--out"), CommandLine.arguments.count > i + 1 {
            renderPanel(to: URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true), check)
        }

        check.unlockAll()
        AppLog.uninstallFileLog()
        try? fm.removeItem(at: work)
        let failures = check.failures
        print(failures.isEmpty ? "诊断自检全部通过" : "诊断自检 \(failures.count) 项失败：\(failures.joined(separator: "；"))")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// 断言 + 记下改过权限的目录（收尾全部改回 755 再删）。
    final class Check {
        private(set) var failures: [String] = []
        private var locked: [URL] = []

        func callAsFunction(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
            let shown = ok ? "" : "：" + detail()
            print((ok ? "  ok   " : "  FAIL ") + label + shown)
            if !ok { failures.append(label) }
        }

        func lock(_ url: URL, _ mode: Int16) {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            locked.append(url)
        }

        func unlockAll() {
            for url in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            locked = []
        }
    }

    // MARK: A 提示历史

    @MainActor
    private static func historyChecks(_ work: URL, _ check: Check) {
        print("A. 状态栏提示的历史")
        let history = ErrorHistory.shared
        history.clear()
        history.record(nil, source: .batch)
        history.record("", source: .batch)
        check(history.entries.isEmpty, "nil、空字符串不记")
        for i in 1...25 { history.record("第 \(i) 条：导出失败", source: .batch) }
        let first = history.entries.first?.text ?? ""
        let last = history.entries.last?.text ?? ""
        check(history.entries.count == ErrorHistory.capacity, "最多留 \(ErrorHistory.capacity) 条", "\(history.entries.count)")
        check(first.hasPrefix("第 25 条") && last.hasPrefix("第 6 条"), "新的在前、最老的挤掉", "\(first) … \(last)")
        history.record("第 25 条：导出失败", source: .batch)
        check(history.entries.count == ErrorHistory.capacity && history.entries.first?.repeats == 2,
              "连着一样的只记次数", "\(history.entries.first?.repeats ?? 0)")
        history.record("第 25 条：导出失败", source: .collage)
        check(history.entries.first?.source == .collage && history.entries.first?.repeats == 1,
              "一样的话、别的页面算新的一条")
        let samples: [(String, ErrorHistory.Level)] = [
            ("JPG 导出: 1 成功, 2 失败 (A, B)；原因：没有权限", .error),
            ("没有权限读这个文件夹「x」：到 系统设置 › 隐私与安全性 › 文件与文件夹", .error),
            ("2 张压到最低质量 40 还是超过 5 MB（已按最低质量写出）：a, b", .notice),
            ("注意：DSCF7207 等 2 个名字是别的文件名的一部分，LR「包含」会多筛出来，筛完核对一下", .notice),
            ("1 张没写星级 (a)：旁边已有其它软件的 XMP，格式读不全、合并怕写丢调色，原样保留了", .notice),
        ]
        for (text, want) in samples {
            check(ErrorHistory.level(of: text) == want, "分级「\(text.prefix(18))…」→ \(want.rawValue)")
        }

        // 三个 store：lastError 一设上就记，来源对；设 nil 不记；lastError 本身还是那个字符串。
        let storeData = work.appendingPathComponent("stores-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeData, withIntermediateDirectories: true)
        history.clear()
        let batch = BatchStore(dataDir: storeData, pythonRoot: appConfig.resolvedPythonRoot(dataDir: storeData))
        let collage = CollageStore(dataDir: storeData)
        let watermark = WatermarkStore(dataDir: storeData)
        history.clear()   // 建 store 时自己设过的不算
        batch.lastError = "批量页的一条：导出失败"
        collage.lastError = "拼图页的一条：导出失败"
        watermark.lastError = "水印页的一条：导出失败"
        batch.lastError = nil
        let sources = history.entries.map(\.source)
        check(sources == [.watermark, .collage, .batch], "三个 store 的 lastError 都记进来、来源对", "\(sources)")
        check(batch.lastError == nil && collage.lastError == "拼图页的一条：导出失败", "lastError 照旧是 String?、设 nil 不记")
        let plain = history.plainText()
        check(plain.contains("批量 · 错误") && plain.contains("批量页的一条"), "全部复制的文字带页面、级别、原文", plain)
    }

    // MARK: B 持久日志

    @MainActor
    private static func logChecks(_ work: URL, _ check: Check) {
        print("B. 持久日志")
        let fm = FileManager.default
        AppLog.uninstallFileLog()
        let logData = work.appendingPathComponent("log-data", isDirectory: true)
        let dir = AppLog.installFileLog(dataDir: logData, role: "自检", maxBytes: 4096, keep: 3)
        check(dir?.lastPathComponent == "logs" && fm.fileExists(atPath: dir?.path ?? "/nonexistent"), "装上：数据目录 logs/")
        guard let dir else { return }
        AppLog.error("test", "第一行\n第二行")
        AppLog.flush()
        let text = (try? String(contentsOf: dir.appendingPathComponent("app.log"), encoding: .utf8)) ?? ""
        let pid = ProcessInfo.processInfo.processIdentifier
        check(text.contains(" 自检[\(pid)] error test: 第一行 ⏎ 第二行\n"), "一条一行：时间、进程、级别、分类，换行折成 ⏎", text)
        let filler = String(repeating: "x", count: 90)
        for i in 0..<200 { AppLog.info("test", "\(i) \(filler)") }
        AppLog.flush()
        let files = AppLog.logFiles(in: dir)
        let names = files.map(\.lastPathComponent)
        check(names == ["app.log", "app.1.log", "app.2.log"], "超过上限轮转、最多留 3 份", "\(names)")
        let sizes = files.map { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? -1 }
        check(sizes.allSatisfy { $0 > 0 && $0 <= 4096 }, "每份不超过上限", "\(sizes)")
        let newest = (try? String(contentsOf: files[0], encoding: .utf8)) ?? ""
        check(newest.contains("199 \(filler)"), "最新的一行在 app.log")
        ErrorHistory.shared.record("提示也进日志：盘满了", source: .collage)
        AppLog.flush()
        let after = (try? String(contentsOf: files[0], encoding: .utf8)) ?? ""
        check(after.contains("error collage: 提示也进日志：盘满了"), "状态栏提示跟着进日志（分类 = 页面）", after.suffix(200).description)
        AppLog.uninstallFileLog()
        check(AppLog.logsDir == nil, "卸下以后只进 os.Logger")
    }

    // MARK: C 诊断包

    @MainActor
    private static func bundleChecks(_ work: URL, _ check: Check) {
        print("C. 诊断包")
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let data = work.appendingPathComponent("bundle-data", isDirectory: true)
        let clientFolder = "/Volumes/T7/客户张三婚礼"
        let desktopFolder = home + "/Desktop/王五订婚"
        let key1 = BatchStore.sessionKey(for: URL(fileURLWithPath: clientFolder))
        let key2 = BatchStore.sessionKey(for: URL(fileURLWithPath: desktopFolder))
        let bookmark = "Ym9va21hcmstc2VjcmV0LWJ5dGVz"
        let sessions = """
            [{"key":"\(key1)","path":"\(clientFolder)","name":"客户张三婚礼","lastAnalyzed":"2026-11-01","photoCount":3,"bookmark":"\(bookmark)"},
             {"key":"\(key2)","path":"\(desktopFolder)","name":"王五订婚","lastAnalyzed":"2026-11-02","photoCount":5}]
            """
        let session1 = data.appendingPathComponent("sessions/\(key1)", isDirectory: true)
        let previews = session1.appendingPathComponent("previews", isDirectory: true)
        try? fm.createDirectory(at: previews, withIntermediateDirectories: true)
        try? fm.createDirectory(at: data.appendingPathComponent("logs"), withIntermediateDirectories: true)
        func put(_ url: URL, _ text: String) { try? text.write(to: url, atomically: true, encoding: .utf8) }
        put(data.appendingPathComponent("sessions.json"), sessions)
        put(session1.appendingPathComponent("manifest.json"), "{\"photos\":[{\"id\":\"DSCF0001\",\"raw_path\":\"\(clientFolder)/DSCF0001.RAF\"}]}")
        put(session1.appendingPathComponent("client_notes.json"), "{\"DSCF0001\":\"客户原话：去路人，脸修瘦一点\"}")
        put(previews.appendingPathComponent("DSCF0001.jpg"), "不是真的预览图")
        put(session1.appendingPathComponent("collage-thumb-DSCF0002.png"), "不是真的图")
        put(data.appendingPathComponent("logs/app.log"),
            "2026-11-04 10:00:00.000 -0800 GUI[1] error batch: 照片文件夹「客户张三婚礼」不存在 ⏎ \(clientFolder)/DSCF0001.RAF\n"
                + "2026-11-04 10:00:01.000 -0800 GUI[1] notice app: 启动：数据目录：\(home)/Library/Application Support/选片工具\n")
        put(data.appendingPathComponent("logs/app.1.log"), "2026-11-03 09:00:00.000 -0800 GUI[1] notice app: 更早的一份\n")
        let crash = work.appendingPathComponent("crash", isDirectory: true)
        try? fm.createDirectory(at: crash, withIntermediateDirectories: true)
        put(crash.appendingPathComponent("LabelGUI-2026-11-03-101010.ips"), "{\"procPath\":\"\(home)/Applications/选片工具.app\"}")
        put(crash.appendingPathComponent("Safari-2026-11-03-101010.ips"), "别的程序的")
        let old = crash.appendingPathComponent("LabelGUI-2026-08-01-101010.ips")
        put(old, "太旧了")
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86_400)], ofItemAtPath: old.path)

        let history = "[2026-11-04 10:00:00] 批量 · 错误\n照片文件夹「王五订婚」不存在（\(desktopFolder)）"
        let zip = work.appendingPathComponent("出来的/诊断.zip")
        let report: DiagnosticsBundle.Report
        do {
            report = try DiagnosticsBundle.write(dataDir: data, to: zip, context: ["当前场次：\(clientFolder)（key \(key1)）· 3 张"],
                                                 history: history, crashDir: crash)
        } catch {
            check(false, "打包", Diagnostics.describeIO(error))
            return
        }
        check(fm.fileExists(atPath: zip.path), "zip 写到指定的地方（目录不存在先建）")
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try? ditto.run()
        ditto.waitUntilExit()
        let base = unpacked.standardizedFileURL.path + "/"
        var files: [String: String] = [:]
        if let e = fm.enumerator(at: unpacked, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let rel = String(url.standardizedFileURL.path.dropFirst(base.count))
                files[rel] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        let names = files.keys.sorted()
        check(names == report.entries, "报告列的文件就是 zip 里的", "\(names) vs \(report.entries)")
        let folder = names.first.map { String($0.split(separator: "/").first ?? "") } ?? ""
        check(folder.hasPrefix("xuanpian-diagnostics-"), "最外层一个「xuanpian-diagnostics-时间」文件夹", folder)
        let want = ["README.txt", "info.txt", "recent-messages.txt", "sessions.txt", "data-dir.txt", "logs/app.log", "logs/app.1.log",
                    "crash-reports/LabelGUI-2026-11-03-101010.ips"]
        let missing = want.filter { files[folder + "/" + $0] == nil }
        check(missing.isEmpty, "说明、诊断信息、提示、场次概况、目录结构、日志、最近的崩溃报告都在", "缺 \(missing)")
        check(names.count == want.count, "别的程序的、30 天以前的崩溃报告不要，场次 JSON、sessions.json 不放", "\(names)")
        let images = names.filter { DiagnosticsBundle.imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        check(images.isEmpty, "没有照片、预览图", "\(images)")
        let all = files.values.joined(separator: "\n")
        let banned = ["客户张三婚礼", "王五订婚", "客户原话", "去路人", bookmark, home + "/", "DSCF0001.jpg", "collage-thumb-DSCF0002"]
        let leaked = banned.filter { all.contains($0) }
        check(leaked.isEmpty, "没有客户原话、bookmark、场次文件夹名、家目录、预览图的名字", "漏了 \(leaked)")
        let log = files[folder + "/logs/app.log"] ?? ""
        check(log.contains("照片文件夹「<场次 1>」不存在 ⏎ <场次 1>/DSCF0001.RAF") && log.contains("~/Library/Application Support/选片工具"),
              "日志里的路径、「文件夹名」换成代号，家目录换成 ~", log)
        let hint = files[folder + "/recent-messages.txt"] ?? ""
        check(hint.contains("「<场次 2>」不存在（<场次 2>）"), "提示里的也换掉", hint)
        let tree = files[folder + "/data-dir.txt"] ?? ""
        check(tree.contains("sessions/\(key1)/manifest.json") && tree.contains("sessions/\(key1)/previews/  （1 个文件")
              && tree.contains("另有 1 张图片"), "目录结构：JSON 列名字和大小，预览目录只说个数，图片不列名字", tree)
        let summary = files[folder + "/sessions.txt"] ?? ""
        check(summary.contains("<场次 1>  key \(key1) · 3 张") && summary.contains("<场次 2>  key \(key2) · 5 张"),
              "场次概况：代号、key、张数", summary)
        let info = files[folder + "/info.txt"] ?? ""
        check(info.contains("macOS：") && info.contains("机型：") && info.contains("当前场次：<场次 1>（key \(key1)）"),
              "诊断信息：系统、机型、界面状态（路径换成代号）", info)
    }

    // MARK: D 失败原因

    @MainActor
    private static func reasonChecks(_ work: URL, _ check: Check) {
        print("D. 逐张失败说原因")
        let cocoa = { (code: Int) in NSError(domain: NSCocoaErrorDomain, code: code) }
        let posix = { (code: Int32) in NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let cases: [(String, Error, Bool, String)] = [
            ("NSFeatureUnsupportedError（移到废纸篓）", cocoa(NSFeatureUnsupportedError), true, "不支持废纸篓"),
            ("ENOTSUP（移到废纸篓）", posix(ENOTSUP), true, "不支持废纸篓"),
            ("NSFileWriteNoPermissionError", cocoa(NSFileWriteNoPermissionError), false, "没有权限"),
            ("EACCES", posix(EACCES), false, "没有权限"),
            ("EROFS", posix(EROFS), false, "只读"),
            ("NSFileWriteVolumeReadOnlyError", cocoa(NSFileWriteVolumeReadOnlyError), false, "只读"),
            ("NSFileWriteOutOfSpaceError", cocoa(NSFileWriteOutOfSpaceError), false, "盘满了"),
            ("ENOSPC", posix(ENOSPC), false, "盘满了"),
            ("EPERM", posix(EPERM), false, "隐私与安全性"),
        ]
        for (label, error, trash, want) in cases {
            let text = Diagnostics.describeIO(error, trash: trash)
            check(text.contains(want), "\(label) → 「\(want)」", text)
        }
        check(Diagnostics.reasonSummary([]) == "", "没有原因 = 空")
        check(Diagnostics.reasonSummary(["没有权限", "没有权限"]) == "；原因：没有权限", "一种原因不数张数")
        let mixed = Diagnostics.reasonSummary(["没有权限", "盘满了", "没有权限"], unit: "个")
        check(mixed == "；原因：没有权限（2 个）、盘满了（1 个）", "几种原因分开数", mixed)

        let partial = BatchStore.TrashPartial(id: "DSCF0001", moved: ["DSCF0001.RAF"], left: ["DSCF0001.JPG"])
        let note = BatchStore.trashFailureNote(trashed: 3, failed: ["DSCF0001", "DSCF0002"],
                                               reasons: ["DSCF0001": Diagnostics.describeIO(cocoa(NSFileWriteNoPermissionError)),
                                                         "DSCF0002": "文件不见了（外置盘没挂上，或者已经被别处移走）"],
                                               partial: [partial])
        check(note.hasPrefix("移到废纸篓: 3 成功, 2 失败 (DSCF0001, DSCF0002)；原因：没有权限（1 张）、文件不见了"),
              "废纸篓：张数、前几张、原因", note)
        check(note.contains("其中 1 张只移走了一部分（DSCF0001：DSCF0001.RAF 已在废纸篓，DSCF0001.JPG 还在原处）"),
              "废纸篓移走一半的单独说", note)

        // 不限体积那条路改成先在内存里编码再原子写：字节要和以前直接写文件一模一样。
        let dir = work.appendingPathComponent("encode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let image = gradient(640, 427) else {
            check(false, "造一张渐变图")
            return
        }
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "diag"]]
        let newPath = dir.appendingPathComponent("new.jpg")
        let outcome = DeliveryEncoder.write(to: newPath, quality: 0.87, maxBytes: nil) { out, q in
            var p = props
            p[kCGImageDestinationLossyCompressionQuality] = q
            CGImageDestinationAddImage(out, image, p as CFDictionary)
        }
        let oldPath = dir.appendingPathComponent("old.jpg")
        let oldOK = legacyWrite(image, props: props, quality: 0.87, to: oldPath)
        let same = oldOK && (try? Data(contentsOf: newPath)) == (try? Data(contentsOf: oldPath))
        check(isOK(outcome) && same, "不限体积：和以前直接写文件逐字节一样（合成图）")
        if let photo = firstJPEG(), let src = CGImageSourceCreateWithURL(photo as CFURL, nil),
           let real = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let realProps = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
            let a = dir.appendingPathComponent("real-new.jpg")
            let b = dir.appendingPathComponent("real-old.jpg")
            let realOutcome = DeliveryEncoder.write(to: a, quality: 0.9, maxBytes: nil) { out, q in
                var p = realProps
                p[kCGImageDestinationLossyCompressionQuality] = q
                CGImageDestinationAddImage(out, real, p as CFDictionary)
            }
            let realSame = legacyWrite(real, props: realProps, quality: 0.9, to: b)
                && (try? Data(contentsOf: a)) == (try? Data(contentsOf: b))
            check(isOK(realOutcome) && realSame, "不限体积：和以前逐字节一样（\(photo.lastPathComponent)，带原片 EXIF）")
        }

        // 写不进去的目录：两条路都报「没有权限」。
        let readOnly = dir.appendingPathComponent("只读", isDirectory: true)
        try? FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        check.lock(readOnly, 0o555)
        for (label, cap) in [("不限体积", nil), ("限体积", 50_000)] as [(String, Int?)] {
            let result = DeliveryEncoder.write(to: readOnly.appendingPathComponent("x.jpg"), quality: 0.8, maxBytes: cap) { out, q in
                CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            }
            check(failure(result)?.contains("没有权限") == true, "\(label)写进只读目录：失败带「没有权限」", "\(result)")
        }

        // writeJPEG：原片不在了 / 解不开 / 写不进去。
        let options = DeliveryOptions()
        let missing = BatchStore.writeJPEG(from: dir.appendingPathComponent("没有这张.JPG"), to: dir.appendingPathComponent("m.jpg"),
                                           options: options)
        check(failure(missing)?.contains("原片不在了") == true, "writeJPEG：原片不在了", "\(missing)")
        let garbage = dir.appendingPathComponent("坏的.JPG")
        try? Data("不是 JPEG".utf8).write(to: garbage)
        let broken = BatchStore.writeJPEG(from: garbage, to: dir.appendingPathComponent("g.jpg"), options: options)
        check(failure(broken)?.contains("解不开原片") == true, "writeJPEG：解不开原片", "\(broken)")
        let blocked = BatchStore.writeJPEG(from: oldPath, to: readOnly.appendingPathComponent("w.jpg"), options: options)
        check(failure(blocked)?.contains("没有权限") == true, "writeJPEG：导出目录写不进去 → 没有权限", "\(blocked)")
        do {
            try WatermarkEngine.export(source: oldPath, to: readOnly.appendingPathComponent("wm.jpg"), signature: nil,
                                       config: WatermarkEngine.Config(), options: options)
            check(false, "水印页写进只读目录应该失败")
        } catch {
            check(error.localizedDescription.contains("没有权限"), "水印页的「首个原因」拿到真原因", error.localizedDescription)
        }
    }

    // MARK: E 文件夹权限

    @MainActor
    private static func permissionChecks(_ work: URL, _ check: Check) {
        print("E. 照片文件夹读不了")
        let fm = FileManager.default
        let home = "/Users/someone"
        let toggles: [(String, String?)] = [
            (home + "/Desktop/婚礼", "桌面文件夹"), (home + "/Documents/a/b", "文稿文件夹"), (home + "/Downloads", "下载文件夹"),
            (home + "/Library/Mobile Documents/com~apple~CloudDocs/x", "iCloud 云盘"), ("/Network/Servers/nas/x", "网络宗卷"),
            ("/Volumes/没有这块盘-diag/DCIM", "可移除的宗卷"), (home + "/Pictures/20261104", nil), (home + "/Desktopx", nil),
        ]
        for (path, want) in toggles {
            let got = Diagnostics.privacyToggle(for: URL(fileURLWithPath: path), home: home)
            check(got == want, "\(path) → \(want ?? "认不出")", got ?? "nil")
        }
        let eperm = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        let tcc = Diagnostics.folderUnreadableMessage(URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/婚礼"), error: eperm)
        check(tcc.contains("没有权限读这个文件夹「婚礼」") && tcc.contains("系统设置 › 隐私与安全性 › 文件与文件夹 › 选片工具 › 打开「桌面文件夹」")
              && !tcc.contains("共享与权限"), "系统隐私权限（EPERM）：点名「桌面文件夹」开关", tcc)
        check(Diagnostics.mentionsPrivacySettings(tcc), "状态栏点开时给「打开系统设置」按钮")

        let photos = work.appendingPathComponent("照片-没权限", isDirectory: true)
        try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: photos.appendingPathComponent("DSCF0001.JPG"))
        check.lock(photos, 0o000)
        let problem = ImageLoader.folderReadProblem(photos) ?? ""
        check(problem.contains("没有权限读这个文件夹「照片-没权限」") && problem.contains("系统设置 › 隐私与安全性 › 文件与文件夹")
              && problem.contains("共享与权限"), "chmod 000：没有权限读这个文件夹 + 系统设置 + 文件夹自己的权限", problem)
        let sessionDir = work.appendingPathComponent("session", isDirectory: true)
        try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        do {
            _ = try AnalysisEngine.analyzeFolder(photos, dataDir: sessionDir) { _ in }
            check(false, "chmod 000 的文件夹分析应该失败")
        } catch {
            let text = error.localizedDescription
            check(text.contains("没有权限读这个文件夹") && !text.contains("没有支持的图片文件"),
                  "分析报权限，不再报「没有支持的图片文件」", text)
        }
        let empty = work.appendingPathComponent("照片-空的", isDirectory: true)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        do {
            _ = try AnalysisEngine.analyzeFolder(empty, dataDir: sessionDir) { _ in }
            check(false, "空文件夹分析应该失败")
        } catch {
            check(error.localizedDescription.contains("没有支持的图片文件"), "真的没有图片时照旧", error.localizedDescription)
        }
        // 顶层读得了、一个子文件夹读不了：跳过它，照样列出别的（不让整场失败）。
        let mixed = work.appendingPathComponent("照片-一个子文件夹没权限", isDirectory: true)
        let locked = mixed.appendingPathComponent("锁着的", isDirectory: true)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: mixed.appendingPathComponent("DSCF0002.JPG"))
        try? Data("x".utf8).write(to: locked.appendingPathComponent("DSCF0003.JPG"))
        check.lock(locked, 0o000)
        let listed = ImageLoader.listPhotos(in: mixed).map(\.stem)
        check(ImageLoader.folderReadProblem(mixed) == nil && listed == ["DSCF0002"], "子文件夹读不了：跳过、照样列出别的", "\(listed)")
    }

    // MARK: 面板快照（看样子，不进 CI）

    @MainActor
    private static func renderPanel(to dir: URL, _ check: Check) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = ErrorHistory.shared
        history.clear()
        history.record("2 张压到最低质量 40 还是超过 5 MB（已按最低质量写出）：DSCF7201, DSCF7202", source: .watermark)
        history.record("拼图导出失败：写入「封面.jpg」失败：盘满了", source: .collage)
        let current = "分析失败: 没有权限读这个文件夹「婚礼」：到 系统设置 › 隐私与安全性 › 文件与文件夹 › 选片工具 › 打开「桌面文件夹」"
            + "（以前系统问的时候点了「不允许」，或者后来在那里关掉了），然后重新分析"
        history.record(current, source: .batch)
        let panel = ErrorHistoryPanel(current: current, source: .batch)
        let bar = HStack(spacing: 12) {
            ErrorNotice(text: current, source: .batch) {}
            Spacer()
            Text("完成: 120 张").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6).frame(width: 700).background(.bar)
        for (name, view) in [("error-panel.png", AnyView(panel)), ("error-statusbar.png", AnyView(bar))] {
            let url = dir.appendingPathComponent(name)
            check(snapshot(view, to: url), "拍 → \(url.path)")
        }
    }

    /// 和 --batch-ui 一样：离屏的无边框窗口（不显示）里排版，cacheDisplay 拍下来（ScrollView 里的内容也拍得到）。
    @MainActor
    private static func snapshot(_ view: AnyView, to url: URL) -> Bool {
        let root = view.fixedSize().background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    // MARK: 小工具

    private static func isOK(_ outcome: DeliveryEncoder.Outcome) -> Bool {
        if case .ok = outcome { return true }
        return false
    }

    private static func failure(_ outcome: DeliveryEncoder.Outcome) -> String? {
        if case .failed(let why) = outcome { return why }
        return nil
    }

    /// 改之前不限体积那条路的写法（CGImageDestinationCreateWithURL + Finalize），拿来逐字节对照。
    private static func legacyWrite(_ image: CGImage, props: [CFString: Any], quality: Double, to url: URL) -> Bool {
        guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        var p = props
        p[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(out, image, p as CFDictionary)
        return CGImageDestinationFinalize(out)
    }

    private static func gradient(_ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let colors = [CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)]
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])
        else { return nil }
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return ctx.makeImage()
    }

    /// 命令行给了照片文件夹：拿第一张 JPG（只读）。
    private static func firstJPEG() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--diag-selftest"), args.count > i + 1, !args[i + 1].hasPrefix("--") else { return nil }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().first { ["jpg", "jpeg"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .map { dir.appendingPathComponent($0) }
    }
}
