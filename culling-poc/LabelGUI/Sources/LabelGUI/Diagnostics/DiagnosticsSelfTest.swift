import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 诊断这一组的无头自检（审查 D03）：LABELGUI_DATA_DIR=<临时> LabelGUI --diag-selftest [<photo_dir>] [--out <目录>]
///   A 状态栏提示的历史：20 条环形、新的在前、连着一样的只记次数、分级；三个 store 的 lastError 一设上就记、类型还是 String?
///   B 持久日志：一条一行、换行折掉、轮转（个数、大小）、提示历史跟着进日志、实时桥的 LiveServer.log 也进日志
///   C 诊断包：zip 里有说明 / 诊断信息 / 提示 / 日志 / 场次概况 / 目录结构 / 崩溃报告（只要最近的、选片工具的），
///     没有照片、预览图（连名字都没有）、bookmark、客户备注原文、场次文件夹名、家目录；目标已经有文件 / 文件夹时一个字节都不动；
///     打码不只认 sessions.json（纯函数：任意路径逐段打码、「」里的文件夹名、不误伤；界面那一路：真的 AppModel 里认回的场次、
///     没登记的当前文件夹、掉出最近场次的旧场次、日志里的新路径、崩溃报告里转义过的路径 —— zip 里哪个文件都没有客户名）
///   D 失败原因：盘不支持废纸篓、没权限、只读盘、盘满、EPERM；原因汇总；废纸篓移走一半（拼的那句话，和真正判断的
///     BatchStore.trashFiles：假的移动动作，RAW 移走、JPG 抛 EPERM / 都不在 / 第一个就抛错 / 再移一次）；不限体积那条路逐字节和以前一样、
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
        // 实时桥的日志（拿不到锁、桥开了、锁丢了……）：以前只走 stderr，从访达启动的 GUI 里进 /dev/null。
        LiveServer.log("自检：桥的日志也进 app.log")
        AppLog.flush()
        let live = (try? String(contentsOf: files[0], encoding: .utf8)) ?? ""
        check(live.contains("notice live: 自检：桥的日志也进 app.log\n"), "实时桥 LiveServer.log 也进日志（分类 live）",
              live.suffix(200).description)
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
        let want = ["README.txt", "info.txt", "recent-messages.txt", "sessions.txt", "data-dir.txt", "film-luts.txt",
                    "logs/app.log", "logs/app.1.log", "crash-reports/LabelGUI-2026-11-03-101010.ips"]
        let missing = want.filter { files[folder + "/" + $0] == nil }
        check(missing.isEmpty, "说明、诊断信息、提示、场次概况、目录结构、光谱胶片的表、日志、最近的崩溃报告都在", "缺 \(missing)")
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
        let luts = files[folder + "/film-luts.txt"] ?? ""
        check(luts.hasPrefix("光谱胶片的表")
              && (CollageFilmLUTs.directory == nil || (luts.contains("款光谱色调要的文件都在") && luts.contains("filmWarmSkin.json"))),
              "光谱胶片的表：在哪个目录、缺没缺、目录里的文件", String(luts.prefix(300)))
        let summary = files[folder + "/sessions.txt"] ?? ""
        check(summary.contains("<场次 1>  key \(key1) · 3 张") && summary.contains("<场次 2>  key \(key2) · 5 张"),
              "场次概况：代号、key、张数", summary)
        let info = files[folder + "/info.txt"] ?? ""
        check(info.contains("macOS：") && info.contains("机型：") && info.contains("当前场次：<场次 1>（key \(key1)）"),
              "诊断信息：系统、机型、界面状态（路径换成代号）", info)
        targetChecks(work, data: data, check)
        redactorChecks(check)
        quoteChecks(work, check)
        liveFolderChecks(work, check)
    }

    /// 打码（纯函数）：任意路径逐段打码、只在一段结尾处换、「」里的文件夹名、网址和系统路径不动。
    @MainActor
    private static func redactorChecks(_ check: Check) {
        print("C2. 打码：不只认 sessions.json 里登记的")
        let home = "/Users/someone"
        let key = BatchStore.sessionKey(for: URL(fileURLWithPath: "/Volumes/T7/张三婚礼"))
        let sessions = [DiagnosticsBundle.SessionDigest(key: key, path: "/Volumes/T7/张三婚礼", name: "张三婚礼_交付",
                                                        photoCount: 3, lastAnalyzed: "")]
        let redact = Redactor(home: home, sessions: sessions)
        let texts = [
            "照片文件夹「张三婚礼」不存在 ⏎ /Volumes/T7/张三婚礼/DSCF0001.RAF",
            "列照片时跳过读不了的 /Volumes/T7 1/交付/张三婚礼_交付/锁着的：没有权限",
            "数据目录：/Users/someone/Library/Application Support/选片工具 · 所在的盘还剩 1 GB",
            "分析失败: 没有权限读这个文件夹「王五订婚」：到 系统设置 › 隐私与安全性",
            "导出到 /Users/someone/Desktop/客户钱七/精选/DSCF0002.JPG 等 3 张",
            "「孙八挑错的」里找不到「张三婚礼_交付」的照片",
            "/Users/other/Pictures/20261104/DCIM/100CANON/IMG_0001.CR3",
            "socket：/var/folders/ab/xyz123/T/xuanpian-live/0123456789abcdef/s.sock",
            "可执行文件：/Applications/选片工具.app/Contents/MacOS/LabelGUI",
            "写入 ~/Desktop/封面 周九.jpg 失败",
            "核对存储卡「EOS_DIGITAL」…",
            "使用说明 https://github.com/x/y#readme",
            "/Volumes/T7/张三婚礼2/x.JPG 和 /Volumes/T7/张三婚礼",
            "「客户钱七」不存在",
            "场次 key 对得上「数据目录结构」里的 sessions/<key>；写入「封面.jpg」失败；1/2 倍、JPG/RAW、a / b",
            "跳过 /Volumes/T7/婚礼（张三）/DSCF0004.RAF 和（/Volumes/T7/客户吴十）",
        ]
        let out = redact.applyAll(texts)
        func at(_ i: Int) -> String { i < out.count ? out[i] : "" }
        let banned = ["张三", "王五", "钱七", "孙八", "周九", "吴十", "T7", "EOS_DIGITAL", "someone", "/Users/other"]
        let all = out.joined(separator: "\n")
        check(banned.allSatisfy { !all.contains($0) }, "客户名、盘名、用户名都换掉了", all)
        check(at(0) == "照片文件夹「<场次 1>」不存在 ⏎ <场次 1>/DSCF0001.RAF", "认得的场次：路径和「文件夹名」换成 <场次 1>，照片文件名留着",
              at(0))
        check(at(1).hasPrefix("列照片时跳过读不了的 /Volumes/<盘 1>/<文件夹 ") && at(1).contains("/<场次 1>/<文件夹 ")
              && at(1).hasSuffix("：没有权限"), "认回以后的新路径（盘名变了、上面多一层）：盘、文件夹逐段打码，场次名认得", at(1))
        check(at(2) == "数据目录：~/Library/Application Support/选片工具 · 所在的盘还剩 1 GB", "家目录换成 ~，系统文件夹照原样", at(2))
        check(at(3).hasPrefix("分析失败: 没有权限读这个文件夹「<文件夹 "), "没登记、只在「」里出现的文件夹名（隐私权限拦下）也换掉", at(3))
        check(at(4).hasPrefix("导出到 ~/Desktop/<文件夹 ") && at(4).hasSuffix("/DSCF0002.JPG 等 3 张"),
              "随便哪条路径：桌面留着、文件夹打码、照片文件名和后面的字留着", at(4))
        check(at(5).hasPrefix("「<文件夹 ") && at(5).hasSuffix("」里找不到「<场次 1>」的照片"), "「X」里找不到：两个名字都换掉", at(5))
        check(at(6) == "/Users/<用户>/Pictures/20261104/DCIM/100CANON/IMG_0001.CR3", "别的用户名换掉；日期、DCIM、100CANON 留着", at(6))
        check(at(7) == texts[7], "临时目录、socket 路径照原样", at(7))
        check(at(8) == texts[8], "app 自己的路径照原样", at(8))
        check(at(9).hasPrefix("写入 ~/Desktop/<文件 ") && at(9).hasSuffix(".jpg 失败"), "中文名的文件换成 <文件 N>.jpg", at(9))
        check(at(10).hasPrefix("核对存储卡「<盘 "), "存储卡「卷名」换成 <盘 N>", at(10))
        check(at(11) == texts[11], "网址不动", at(11))
        check(at(12).hasSuffix("/x.JPG 和 <场次 1>") && !at(12).contains("<场次 1>2"), "只在一段结尾处换：张三婚礼2 不会换成「<场次 1>2」",
              at(12))
        check(at(13).hasPrefix("「<文件夹 ") && at(13).hasSuffix("」不存在"), "路径里打过码的名字，别处「」里的也换（同一个代号）", at(13))
        check(at(14) == texts[14], "不是路径、不是文件夹名的不误伤（说明文字、文件名、分数、斜杠）", at(14))
        check(at(15).hasPrefix("跳过 /Volumes/<盘 ") && at(15).contains("/DSCF0004.RAF 和（/Volumes/<盘 ") && at(15).hasSuffix(">）"),
              "文件夹名里的括号算路径的一部分；包着路径的括号留在外面", at(15))
    }

    /// 打码（纯函数）：系统错误文案（Foundation 的 NSError，这个 app 拿到的是英文、名字用弯引号 “X”）、日志里打印出来的 NSError
    /// （"…" 里套着 “…”）、直引号里的文件夹名，和「」一样按前后文换代号（英文的 the folder / the file 也算）；弯引号包着的整条路径
    /// 也打码；按钮名、照片文件名不误伤。
    @MainActor
    private static func quoteChecks(_ work: URL, _ check: Check) {
        print("C2b. 打码：系统错误文案里 “…” 和 \"…\" 里的文件夹名")
        let key = BatchStore.sessionKey(for: URL(fileURLWithPath: "/Volumes/T7/张三婚礼"))
        let sessions = [DiagnosticsBundle.SessionDigest(key: key, path: "/Volumes/T7/张三婚礼", name: "张三婚礼_交付",
                                                        photoCount: 3, lastAnalyzed: "")]
        let redact = Redactor(home: "/Users/someone", sessions: sessions)
        // 真的系统错误（Foundation 自己的说法，列一个不存在的文件夹）：一个没登记的名字、一个认得的场次名。
        func systemError(_ name: String) -> String {
            let url = work.appendingPathComponent("quote-checks", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            do {
                _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                return ""
            } catch {
                return (error as NSError).localizedDescription
            }
        }
        let realUnknown = systemError("李四订婚")
        let realKnown = systemError("张三婚礼")
        check(realUnknown.contains("“李四订婚”") && realKnown.contains("“张三婚礼”"),
              "前提：系统的 NSError 文案用弯引号包着文件夹名", realUnknown + " / " + realKnown)
        let texts = [
            "分析失败: " + realUnknown,
            "列照片失败: " + realKnown,
            "You don’t have permission to save the file “a.csv” in the folder “王五订婚”.",
            "The folder “赵六写真” doesn’t exist.",
            "未能打开文件夹“周九婚纱”。",
            "导出失败：Error Domain=NSCocoaErrorDomain Code=260 \"The file “张三婚礼_交付” couldn’t be opened because there is no such file.\""
                + " UserInfo={NSFilePath=/Volumes/T7/张三婚礼}",
            "照片文件夹\"吴十订婚\"不存在",
            "{\"a\":\"\",\"name\":\"张三婚礼\"}",
            "The file “/Volumes/T7/张三婚礼” couldn’t be opened; “/Users/someone/Desktop/客户钱七” too",
            "先点“取消”再移除历史记录；先点“启动服务”",
            "The file “DSCF0001.RAF” couldn’t be opened; 写入「封面.jpg」失败",
            "又看了一遍：「李四订婚」、“王五订婚”、\"赵六写真\"",
        ]
        let out = redact.applyAll(texts)
        func at(_ i: Int) -> String { i < out.count ? out[i] : "" }
        func label(in text: String) -> String {
            ProofSheetSelfTest.matches("[“\"「](<文件夹 [0-9]+>)[”\"」]", in: text).first ?? "?"
        }
        let banned = ["张三", "李四", "王五", "赵六", "周九", "吴十", "钱七", "T7", "someone"]
        let all = out.joined(separator: "\n")
        check(banned.allSatisfy { !all.contains($0) }, "弯引号、直引号里的客户名都换掉了", all)
        check(at(0).hasPrefix("分析失败: ") && at(0).contains("“<文件夹 "),
              "真的系统错误里没登记的文件夹名（the file / the folder “X”）换成 <文件夹 N>", at(0))
        check(at(1).contains("“<场次 1>”"), "真的系统错误里认得的场次名，前面没有「文件夹」也换成 <场次 1>", at(1))
        check(at(2).hasPrefix("You don’t have permission to save the file “a.csv” in the folder “<文件夹 ") && at(2).hasSuffix(">”."),
              "the folder “X” 换掉，the file “a.csv” 这种文件名留着", at(2))
        check(at(3).hasPrefix("The folder “<文件夹 ") && at(3).hasSuffix(">” doesn’t exist."), "The folder “X” doesn’t exist", at(3))
        check(at(4).hasPrefix("未能打开文件夹“<文件夹 ") && at(4).hasSuffix(">”。"), "中文的 文件夹“X” 和「」一样换", at(4))
        check(at(5).contains("\"The file “<场次 1>” couldn’t be opened because there is no such file.\"")
              && at(5).hasSuffix("NSFilePath=<场次 1>}"), "日志里打印的 NSError：\"…\" 里套着的 “X” 也认得", at(5))
        check(at(6).hasPrefix("照片文件夹\"<文件夹 ") && at(6).hasSuffix(">\"不存在"), "直引号里的文件夹名按同样的前后文换", at(6))
        check(at(7) == "{\"a\":\"\",\"name\":\"<场次 1>\"}", "JSON 里的空串不打乱直引号的配对", at(7))
        check(at(8).hasPrefix("The file “<场次 1>” couldn’t be opened; “~/Desktop/<文件夹 ") && at(8).hasSuffix(">” too"),
              "弯引号包着的整条路径：认得的换成 <场次 1>，别的逐段打码", at(8))
        check(at(9) == texts[9], "弯引号里的按钮名不误伤", at(9))
        check(at(10) == texts[10], "引号里的照片文件名不误伤", at(10))
        let li = label(in: at(0))
        let wang = label(in: at(2))
        let zhao = label(in: at(3))
        check(at(11) == "又看了一遍：「\(li)」、“\(wang)”、\"\(zhao)\"",
              "一处认出的文件夹名，别处「」、“”、\"\" 里的也换成同一个代号", at(11) + " / " + li + wang + zhao)
    }

    /// 界面那一路（真的 AppModel、BatchStore）：认回的场次（photoDir 是改名以后的新路径、sessions.json 里钉着旧路径）、
    /// 还没登记的当前文件夹（隐私权限拦下那种）、掉出最近场次的旧场次、日志里随便哪条路径 —— zip 里哪个文件都没有客户名。
    @MainActor
    private static func liveFolderChecks(_ work: URL, _ check: Check) {
        print("C3. 诊断包（界面那一路）：认回的场次、没登记的当前文件夹、日志里的新路径都打码")
        let fm = FileManager.default
        var root = work.appendingPathComponent("gui", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // 和 --session-move-selftest 一样：/private/tmp 下面换成不带 /private 的写法，改名前后按路径算的 key 才稳。
        if root.path.hasPrefix("/private/") {
            let alias = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)), isDirectory: true)
            if SessionLocation.identity(alias.path) == SessionLocation.identity(root.path) { root = alias }
        }
        AppLog.uninstallFileLog()
        AppLog.installFileLog(dataDir: appDataDir, role: "自检")
        defer { AppLog.uninstallFileLog() }
        ErrorHistory.shared.clear()
        let model = AppModel.make(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir),
                                  bridge: .none)
        let batch = model.batch

        // 1. 认回：分析过的「张三婚礼」改名成「张三婚礼_已交付精修」，从新路径打开 → 沿用旧 key、photoDir 是新路径。
        let a = root.appendingPathComponent("张三婚礼", isDirectory: true)
        let b = root.appendingPathComponent("张三婚礼_已交付精修", isDirectory: true)
        let shoot = [FileSafetySelfTest.Fake(id: "DSCF0001", raw: "DSCF0001.JPG", jpeg: true),
                     FileSafetySelfTest.Fake(id: "DSCF0002", raw: "DSCF0002.JPG", jpeg: true)]
        FileSafetySelfTest.writeShoot(a, shoot)
        let oldKey = BatchStore.sessionKey(for: a)
        let opened = batch.switchSession(to: a) && batch.items.count == 2
        FileSafetySelfTest.waitUntil(0.3) { false }
        AppLog.notice("batch", "照片文件夹「张三婚礼」里 \(a.path)/DSCF0001.JPG（改名以前的一行）")
        let renamed = (try? fm.moveItem(at: a, to: b)) != nil
        let reopened = renamed && batch.switchSession(to: b)
        let samePlace = SessionLocation.identity(batch.photoDir?.path ?? "/nonexistent") == SessionLocation.identity(b.path)
        let adopted = reopened && samePlace && batch.sessionDir.lastPathComponent == oldKey
        check(opened && adopted, "前提：改了名的文件夹认回原来那一场（photoDir 是新路径，key 还是旧的）",
              "\(opened) \(reopened) \(batch.photoDir?.path ?? "nil") \(batch.sessionDir.lastPathComponent)")
        let lockedB = b.appendingPathComponent("锁着的第二机位", isDirectory: true)
        try? fm.createDirectory(at: lockedB, withIntermediateDirectories: true)
        check.lock(lockedB, 0o000)
        _ = ImageLoader.listPhotos(in: b)   // 日志：列照片时跳过读不了的 <新路径>/锁着的第二机位
        batch.lastError = "「孙八挑错的文件夹」里找不到「\(b.lastPathComponent)」的照片"
        let first = exportAndRead(model, to: work.appendingPathComponent("gui-1.zip"), crashDir: nil, check)
        let info1 = first.first { $0.key.hasSuffix("/info.txt") }?.value ?? ""
        let newKey = BatchStore.sessionKey(for: b)
        check(info1.contains("（key \(oldKey)）") && !info1.contains(newKey), "info.txt 的 key 是钉住的旧 key（对得上 sessions.txt）",
              info1)
        check(info1.contains("当前场次：<场次 1>（key"), "info.txt 里认回的场次（新路径）换成 <场次 1>", info1)

        // 2. 没登记的当前文件夹：分析被隐私权限拦下（一张都没有，不进 sessions.json）。
        let c = root.appendingPathComponent("王五订婚照", isDirectory: true)
        let lockedC = c.appendingPathComponent("客户挑的", isDirectory: true)
        try? fm.createDirectory(at: lockedC, withIntermediateDirectories: true)
        check.lock(lockedC, 0o000)
        let switched = batch.switchSession(to: c)
        let unregistered = !batch.recentSessions.contains { $0.key == BatchStore.sessionKey(for: c) }
        check(switched && unregistered, "前提：当前打开的「王五订婚照」不在最近场次里")
        let eperm = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        batch.lastError = "分析失败: " + Diagnostics.folderUnreadableMessage(c, error: eperm)
        _ = ImageLoader.listPhotos(in: c)   // 日志：列照片时跳过读不了的 <路径>/客户挑的
        // 3. 掉出最近场次的旧场次（只剩数据目录里的 manifest）和日志里只出现过一次的路径。
        let goneKey = BatchStore.sessionKey(for: URL(fileURLWithPath: "/Volumes/T7/赵六旧场次"))
        let gone = appDataDir.appendingPathComponent("sessions/\(goneKey)", isDirectory: true)
        try? fm.createDirectory(at: gone, withIntermediateDirectories: true)
        try? Data(#"{"photo_dir":"/Volumes/T7/赵六旧场次","photos":[]}"#.utf8).write(to: gone.appendingPathComponent("manifest.json"))
        AppLog.error("batch", "照片文件夹「赵六旧场次」不存在 (被删除、改名或硬盘未挂载) ⏎ /Volumes/T7/赵六旧场次/DSCF0009.RAF")
        AppLog.error("export", "导出到 /Volumes/客户钱七的盘/钱七写真/精选：写入「DSCF0003.jpg」失败")
        // 4. 崩溃报告：.ips 里的路径是 JSON 转义过的 \/Users\/…
        let crash = work.appendingPathComponent("gui-crash", isDirectory: true)
        try? fm.createDirectory(at: crash, withIntermediateDirectories: true)
        let escapedHome = NSHomeDirectory().replacingOccurrences(of: "/", with: "\\/")
        try? Data("{\"procPath\":\"\(escapedHome)\\/Desktop\\/孙八私房\\/x\"}".utf8)
            .write(to: crash.appendingPathComponent("LabelGUI-2026-11-04-101010.ips"))
        let second = exportAndRead(model, to: work.appendingPathComponent("gui-2.zip"), crashDir: crash, check)

        let banned = ["张三婚礼", "已交付精修", "锁着的第二机位", "孙八", "王五订婚照", "客户挑的", "赵六旧场次", "客户钱七的盘",
                      "钱七写真", "/Volumes/T7/", NSHomeDirectory() + "/", escapedHome]
        for (label, files) in [("第一个包", first), ("第二个包", second)] {
            var leaks: [String] = []
            for (name, text) in files {
                for word in banned where text.contains(word) { leaks.append("\(name)：\(word)") }
            }
            check(!files.isEmpty && leaks.isEmpty, "\(label)：zip 里哪个文件都没有客户名、盘名、家目录", "\(leaks)")
        }
        let info2 = second.first { $0.key.hasSuffix("/info.txt") }?.value ?? ""
        check(info2.contains("当前场次：<当前场次>（key "), "没登记的当前文件夹 → <当前场次>", info2)
        let log2 = second.first { $0.key.hasSuffix("/logs/app.log") }?.value ?? ""
        check(log2.contains("/DSCF0009.RAF") && log2.contains("/Volumes/<盘 ") && log2.contains("「DSCF0003.jpg」"),
              "日志里照片文件名、盘的位置（代号）还看得出来", String(log2.suffix(600)))
        let crash2 = second.first { $0.key.contains("/crash-reports/") }?.value ?? ""
        check(crash2.contains("~/Desktop/<文件夹 "), "崩溃报告里转义过的路径也打码", crash2)
        check.unlockAll()
        try? fm.removeItem(at: root)
    }

    /// 用界面那一路的参数（diagnosticLines、提示历史、diagnosticFolders）打一个包，解开读回每个文件。
    @MainActor
    private static func exportAndRead(_ model: AppModel, to zip: URL, crashDir: URL?, _ check: Check) -> [String: String] {
        let fm = FileManager.default
        do {
            _ = try DiagnosticsBundle.write(dataDir: appDataDir, to: zip, context: model.diagnosticLines(),
                                            history: ErrorHistory.shared.plainText(), crashDir: crashDir,
                                            folders: model.batch.diagnosticFolders)
        } catch {
            check(false, "打包 \(zip.lastPathComponent)", Diagnostics.describeIO(error))
            return [:]
        }
        let unpacked = zip.deletingPathExtension().appendingPathExtension("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try? ditto.run()
        ditto.waitUntilExit()
        var files: [String: String] = [:]
        let base = unpacked.standardizedFileURL.path + "/"
        if let e = fm.enumerator(at: unpacked, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files[String(url.standardizedFileURL.path.dropFirst(base.count))] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        try? fm.removeItem(at: unpacked)
        try? fm.removeItem(at: zip)
        return files
    }

    /// 打包的目标位置已经有东西：一个字节都不动（以前先 removeItem 再挪：给的是文件夹就整个递归删掉）。
    @MainActor
    private static func targetChecks(_ work: URL, data: URL, _ check: Check) {
        let fm = FileManager.default
        let root = work.appendingPathComponent("目标已有", isDirectory: true)
        let folder = root.appendingPathComponent("已有的文件夹.zip", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let keep = folder.appendingPathComponent("别删我.txt")
        try? Data("里面的东西".utf8).write(to: keep)
        let file = root.appendingPathComponent("已有的.zip")
        let original = Data("原来的 zip，不是这次打的".utf8)
        try? original.write(to: file)
        for (label, url) in [("已有的文件夹", folder), ("已有的文件", file)] {
            do {
                _ = try DiagnosticsBundle.write(dataDir: data, to: url, context: [], history: "", crashDir: nil)
                check(false, "打包到\(label)：应该报错不动它")
            } catch {
                check(error.localizedDescription.contains("不覆盖"), "打包到\(label)：报「不覆盖」", error.localizedDescription)
            }
        }
        let folderIntact = (try? Data(contentsOf: keep)) == Data("里面的东西".utf8)
        check(folderIntact && fm.fileExists(atPath: folder.path), "已有的文件夹和里面的文件都还在")
        check((try? Data(contentsOf: file)) == original, "已有的文件逐字节没变")
        // 保存面板那一路（点了「替换」）：换个名字写，原来的不动。
        do {
            let report = try DiagnosticsBundle.write(dataDir: data, to: file, context: [], history: "", crashDir: nil,
                                                     existing: .numbered)
            let wrote = report.zip.lastPathComponent
            check(wrote == "已有的-2.zip" && fm.fileExists(atPath: report.zip.path) && (try? Data(contentsOf: file)) == original,
                  "保存面板那一路：写成「已有的-2.zip」，原来的逐字节没变", wrote)
            let again = try DiagnosticsBundle.write(dataDir: data, to: folder, context: [], history: "", crashDir: nil,
                                                    existing: .numbered)
            let stillThere = (try? Data(contentsOf: keep)) == Data("里面的东西".utf8)
            check(again.zip.lastPathComponent == "已有的文件夹-2.zip" && stillThere, "目标是文件夹也换名字、文件夹不动",
                  again.zip.lastPathComponent)
        } catch {
            check(false, "保存面板那一路换名字写", error.localizedDescription)
        }
        try? fm.removeItem(at: root)
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
        trashOutcomeChecks(work, check)

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

    /// 移到废纸篓真正判断「移走 / 不见了 / 移走一半」的那段（BatchStore.trashFiles）：移动动作换成假的（挪进一个假废纸篓
    /// 文件夹、或者抛 EPERM），不碰真的废纸篓。
    private static func trashOutcomeChecks(_ work: URL, _ check: Check) {
        let fm = FileManager.default
        let dir = work.appendingPathComponent("trash-pair", isDirectory: true)
        let bin = work.appendingPathComponent("trash-pair-bin", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("DSCF0001.RAF")
        let jpg = dir.appendingPathComponent("DSCF0001.JPG")
        try? Data("raw".utf8).write(to: raw)
        try? Data("jpg".utf8).write(to: jpg)
        let eperm = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        func intoBin(_ url: URL) throws {
            try fm.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        }
        // RAW 移走了、JPG 被锁住抛 EPERM。
        let half = BatchStore.trashFiles("DSCF0001", [raw, jpg]) { url in
            if url == jpg { throw eperm }
            try intoBin(url)
        }
        let wantPartial = BatchStore.TrashPartial(id: "DSCF0001", moved: ["DSCF0001.RAF"], left: ["DSCF0001.JPG"])
        if case .failed(let why, let partial) = half {
            check(partial == wantPartial, "废纸篓移走一半：moved 只有 RAW、left 只有 JPG", "\(String(describing: partial))")
            check(why.contains("没有权限"), "废纸篓移走一半：原因是「没有权限」", why)
        } else {
            check(false, "废纸篓移走一半：算失败（不进 trashedIDs，照片留在网格里）", "\(half)")
        }
        check(!fm.fileExists(atPath: raw.path) && fm.fileExists(atPath: jpg.path), "前提：RAW 真的挪走了、JPG 还在原处")
        // 再移一次：已经不在的 RAW 跳过，只移剩下的 JPG → 算移走。
        let again = BatchStore.trashFiles("DSCF0001", [raw, jpg], move: intoBin)
        check(again == .trashed && !fm.fileExists(atPath: jpg.path), "再移一次：跳过已经不在的、只移剩下的，算移走", "\(again)")
        // 一个文件都没找到：不算成功，原因「文件不见了」。
        let missing = BatchStore.trashFiles("DSCF0002", [dir.appendingPathComponent("DSCF0002.RAF")]) { _ in
            check(false, "文件不在时不该去移")
        }
        if case .missing(let why) = missing {
            check(why.contains("文件不见了"), "一个文件都没找到：算失败，原因「文件不见了」", why)
        } else {
            check(false, "一个文件都没找到：算失败（不进 trashedIDs）", "\(missing)")
        }
        // 第一个就抛错：失败，没有「移走一半」。
        let lockedRaw = dir.appendingPathComponent("DSCF0003.RAF")
        try? Data("raw".utf8).write(to: lockedRaw)
        let first = BatchStore.trashFiles("DSCF0003", [lockedRaw]) { _ in throw eperm }
        if case .failed(let why, let partial) = first {
            check(partial == nil && why.contains("没有权限") && fm.fileExists(atPath: lockedRaw.path),
                  "第一个文件就抛错：失败、不算移走一半、文件还在", "\(String(describing: partial)) \(why)")
        } else {
            check(false, "第一个文件就抛错：算失败", "\(first)")
        }
        try? fm.removeItem(at: dir)
        try? fm.removeItem(at: bin)
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
