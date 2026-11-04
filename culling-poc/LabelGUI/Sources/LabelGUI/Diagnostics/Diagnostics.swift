import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 诊断（全项目审查 D03）
//
// 四件事放在这一个文件里：
//   1. 逐张失败的原因翻成中文（导出 JPG、移到废纸篓、写 XMP、水印页）：在 CardImporter.describe 之前先认它不认的几种
//      —— 盘不支持废纸篓、只读盘、EPERM（文件被锁定或者系统隐私权限）—— 其余照旧交给它。
//   2. 照片文件夹被系统隐私权限（TCC）拒绝时的话：点名「系统设置 › 隐私与安全性 › 文件与文件夹 › 选片工具」里哪个开关。
//   3. 诊断包：「帮助 › 导出诊断信息…」和无头 --diag-export 打同一个 zip —— 版本、系统、最近的提示和日志、数据目录里
//      有哪些文件（只列名字和大小，照片、预览图连名字都不列）、场次概况（几个、几张，不带路径和 bookmark）。场次 JSON、
//      sessions.json、客户备注一律不放；所有文字里的家目录换成 ~，场次文件夹的路径和「文件夹名」换成 <场次 N>。
//   4. 「帮助」菜单（快捷键一览、使用说明、导出 / 复制诊断信息、日志文件夹）。

enum Diagnostics {
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    static let manualURL = URL(string: "https://github.com/Ly-star-bit/photo_culling#readme")!

    // MARK: 失败原因

    /// 给人看的 I/O 失败原因。`trash`：移到废纸篓那一路（「不支持」说成「这块盘不支持废纸篓」并给办法）。
    nonisolated static func describeIO(_ error: Error, trash: Bool = false) -> String {
        let ns = error as NSError
        let posix = CardImporter.posixCode(error)
        let cocoa = ns.domain == NSCocoaErrorDomain ? ns.code : nil
        if cocoa == NSFeatureUnsupportedError || (trash && posix == ENOTSUP) {
            return trash ? "这块盘不支持废纸篓（网络盘、部分外接盘）：在访达里手动删，或者先拷到本机再移"
                : "这块盘 / 共享不支持这个操作"
        }
        if posix == EROFS || cocoa == NSFileWriteVolumeReadOnlyError {
            return "盘是只读的（存储卡的写保护开关、只读的网络共享）"
        }
        if posix == EPERM {
            return "没有权限（文件被锁定，或者系统隐私权限不让访问：系统设置 › 隐私与安全性 › 文件与文件夹）"
        }
        if posix == EDQUOT { return "盘满了（超出配额）" }
        return CardImporter.describe(error)
    }

    /// 收尾消息后面那一截：「；原因：没有权限」，几种不同的就「；原因：没有权限（3 张）、盘满了（1 张）」。没有 = ""。
    nonisolated static func reasonSummary(_ reasons: [String], unit: String = "张") -> String {
        var counts: [(reason: String, count: Int)] = []
        for reason in reasons {
            if let i = counts.firstIndex(where: { $0.reason == reason }) {
                counts[i].count += 1
            } else {
                counts.append((reason, 1))
            }
        }
        guard let first = counts.first else { return "" }
        if counts.count == 1 { return "；原因：" + first.reason }
        let shown = counts.prefix(3).map { "\($0.reason)（\($0.count) \(unit)）" }.joined(separator: "、")
        let more = counts.count > 3 ? "…" : ""
        return "；原因：" + shown + more
    }

    // MARK: 文件夹权限（隐私与安全性）

    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        let code = CardImporter.posixCode(error)
        return code == EPERM || code == EACCES
    }

    /// 这条话里点名了系统设置的隐私页（状态栏点开时给「打开系统设置」按钮）。
    nonisolated static func mentionsPrivacySettings(_ text: String) -> Bool {
        text.contains("隐私与安全性")
    }

    /// 「文件与文件夹 › 选片工具」下面管这个位置的那个开关；认不出来 = nil。
    nonisolated static func privacyToggle(for dir: URL, home: String = NSHomeDirectory()) -> String? {
        let path = dir.standardizedFileURL.path
        func under(_ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }
        if under(home + "/Desktop") { return "桌面文件夹" }
        if under(home + "/Documents") { return "文稿文件夹" }
        if under(home + "/Downloads") { return "下载文件夹" }
        if under(home + "/Library/Mobile Documents") { return "iCloud 云盘" }
        if under("/Network") || under("/net") { return "网络宗卷" }
        if under("/Volumes") {
            let local = (try? dir.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
            return local == false ? "网络宗卷" : "可移除的宗卷"
        }
        return nil
    }

    /// 照片文件夹列不出内容时说什么。权限类（EPERM：系统隐私权限；EACCES：文件夹自己的权限）点名系统设置里的开关，
    /// 不再落到「没有支持的图片文件」；别的原因照实说。
    nonisolated static func folderUnreadableMessage(_ dir: URL, error: Error) -> String {
        let name = dir.lastPathComponent
        guard isPermissionDenied(error) else {
            return "读不了这个文件夹「\(name)」：\(describeIO(error))"
        }
        let toggle = privacyToggle(for: dir).map { " › 打开「\($0)」" } ?? "，打开它对应的开关"
        var text = "没有权限读这个文件夹「\(name)」：到 系统设置 › 隐私与安全性 › 文件与文件夹 › 选片工具\(toggle)"
            + "（以前系统问的时候点了「不允许」，或者后来在那里关掉了），然后重新分析"
        if CardImporter.posixCode(error) == EACCES {
            text += "；那里已经开着的话，是文件夹自己的权限不让读：访达里选中它 › 显示简介 › 共享与权限"
        }
        return text
    }

    // MARK: 界面上的入口

    /// 开界面那一条路（main.swift 里 LabelGUIApp.main() 之前）：日志落盘，第一行记版本、系统、机型、剩余空间，退出时记一行。
    static func startGUILog(dataDir: URL) {
        guard AppLog.installFileLog(dataDir: dataDir, role: "GUI") != nil else { return }
        let lines = DiagnosticsBundle.systemLines(dataDir: dataDir, now: Date())
        AppLog.notice("app", "启动：" + lines.joined(separator: " | "))
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: nil) { _ in
            AppLog.notice("app", "退出")
            AppLog.flush()
        }
    }

    /// 「帮助 › 导出诊断信息…」要的界面状态（当前场次几张、AI 实时开没开）。LabelGUIApp 建好 AppModel 就接上。
    @MainActor static weak var model: AppModel?

    /// 系统放崩溃报告的目录（~/Library/Logs/DiagnosticReports）：只在界面那一路读；无头 --diag-export 用 --crash-dir 指测试目录。
    static var crashReportsDir: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    static let bundleBlurb = "打包版本、系统、最近的日志和提示、数据目录里有哪些文件（只列名字和大小）。"
        + "不含照片、预览图、客户回复原文和场次记录；路径里的用户名、场次文件夹名换成了代号。发给开发者就行。"

    nonisolated static func defaultZipName(_ date: Date) -> String {
        "选片工具诊断-\(DiagnosticsBundle.fileStamp(date)).zip"
    }

    /// 「帮助 › 导出诊断信息…」、状态栏提示里的同名按钮：选存到哪，后台打包，打好在访达里选中它。
    @MainActor
    static func exportInteractively() {
        guard !AppRuntime.headless else { return }
        let panel = NSSavePanel()
        panel.title = "导出诊断信息"
        panel.message = bundleBlurb
        panel.prompt = "导出"
        panel.nameFieldStringValue = defaultZipName(Date())
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let context = model?.diagnosticLines() ?? []
        let history = ErrorHistory.shared.plainText()
        let dataDir = appDataDir
        let crashDir = crashReportsDir
        Task.detached {
            do {
                // 保存面板里点了「替换」也不删原来那个：换个名字「…-2.zip」，访达里选中真正写出来的那个。
                let report = try DiagnosticsBundle.write(dataDir: dataDir, to: url, context: context, history: history,
                                                         crashDir: crashDir, existing: .numbered)
                let written = report.zip
                AppLog.notice("diagnostics", "导出诊断信息 → \(written.path)（\(report.entries.count) 个文件）")
                await MainActor.run { AppRuntime.revealInFinder([written]) }
            } catch {
                let why = describeIO(error)
                await MainActor.run { model?.batch.lastError = "导出诊断信息没成功：\(why)" }
            }
        }
    }

    /// 「帮助 › 复制诊断摘要」：版本、系统、界面状态和最近 5 条提示（同样换掉路径），粘进微信就能发。
    @MainActor
    static func copySummary() {
        let recent = Array(ErrorHistory.shared.entries.prefix(5))
        let text = DiagnosticsBundle.summaryText(dataDir: appDataDir, context: model?.diagnosticLines() ?? [],
                                                 history: ErrorHistory.shared.plainText(recent))
        ErrorHistory.copy(text)
    }
}

// MARK: - 帮助菜单

/// 「快捷键一览」窗口（和状态栏键盘按钮、? 键弹的是同一张 ShortcutsPanel）。
enum ShortcutsWindow {
    static let id = "shortcuts"
}

/// 替换系统默认的「帮助」菜单（没有帮助手册，默认那一项点了只会说「帮助不可用」）。
struct HelpMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("快捷键一览") { openWindow(id: ShortcutsWindow.id) }
        Button("使用说明（网页）") {
            guard !AppRuntime.headless else { return }
            openURL(Diagnostics.manualURL)
        }
        Divider()
        Button("导出诊断信息…") { Diagnostics.exportInteractively() }
        Button("复制诊断摘要") { Diagnostics.copySummary() }
        Button("在访达里显示日志文件夹") {
            if let dir = AppLog.logsDir { AppRuntime.revealInFinder([dir]) }
        }
    }
}

extension AppModel {
    /// 诊断包、诊断摘要里的界面状态。路径在打包时统一换成代号。
    func diagnosticLines() -> [String] {
        let tabName: String
        switch tab {
        case .batch: tabName = "批量处理"
        case .watermark: tabName = "水印"
        case .collage: tabName = "拼图"
        case .labeling: tabName = "标注校准"
        }
        var lines = ["当前页面：\(tabName)"]
        if let dir = batch.photoDir {
            var parts = ["当前场次：\(dir.path)（key \(BatchStore.sessionKey(for: dir))）", "\(batch.items.count) 张"]
            if batch.unparsedCount > 0 { parts.append("未能解析 \(batch.unparsedCount) 张") }
            if batch.xmpStaleCount > 0 { parts.append("XMP 过期 \(batch.xmpStaleCount) 张") }
            if batch.isRunning { parts.append("正在处理") }
            lines.append(parts.joined(separator: " · "))
        } else {
            lines.append("当前场次：没有打开")
        }
        lines.append("水印页：\(watermark.photos.count) 张")
        let album = collage.isAlbum ? "（相册）" : ""
        lines.append("拼图：\(collage.project.pages.count) 页" + album)
        let live = indicator.text.isEmpty ? "" : "（\(indicator.text)）"
        lines.append("AI 实时操作：" + (indicator.bridgeEnabled ? "开" : "关") + live)
        return lines
    }
}

// MARK: - 诊断包

enum DiagnosticsBundle {
    struct Report {
        let zip: URL
        /// zip 里的文件（相对路径，带最外层那个文件夹名）。
        let entries: [String]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 一场在 sessions.json 里的样子（只拿打包要用的几项）。
    struct SessionDigest {
        let key: String
        let path: String
        let name: String
        let photoCount: Int
        let lastAnalyzed: String
    }

    /// 照片、预览图：结构里连名字都不列，每个文件夹只说几张、多大。
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp",
        "raf", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq",
    ]
    /// 这些文件夹只说几个文件、多大，不往里列（Python 运行时、虚拟环境、预览图）。
    static let summarizedFolders: Set<String> = ["runtime", ".venv", "previews", "thumbs", "thumbnails", "cache"]

    nonisolated static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// 目标位置已经有东西时怎么办：一律不删、不覆盖（审查：以前先 removeItem 再挪，传进来的是目录就整个递归删掉）。
    enum ExistingTarget {
        /// 报错（无头 --diag-export：先在入口拒绝，这里再挡一次）。
        case refuse
        /// 换一个名字「…-2.zip」「…-3.zip」（保存面板那一路：用户点了「替换」也不删原来那个）。
        case numbered
    }

    /// 打一个 zip 到 `zip`。那里已经有文件或文件夹时一个字节都不动：`existing` = .refuse 报错，.numbered 换个名字，
    /// 返回的 Report.zip 是真正写到的地方。`crashDir`：系统的崩溃报告目录，只拿最近 30 天里最新 3 份选片工具的。
    static func write(dataDir: URL, to zip: URL, context: [String], history: String, crashDir: URL?,
                      existing: ExistingTarget = .refuse, now: Date = Date()) throws -> Report {
        let fm = FileManager.default
        if existing == .refuse, let what = existingItem(at: zip) {
            throw Failure(message: "\(zip.path) 已经\(what)，不覆盖：换一个还没有的 .zip 文件名")
        }
        let root = fm.temporaryDirectory.appendingPathComponent("xuanpian-diag-\(UUID().uuidString)", isDirectory: true)
        let folderName = "xuanpian-diagnostics-\(fileStamp(now))"
        let stage = root.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sessions = readSessions(dataDir)
        let redact = Redactor(home: NSHomeDirectory(), sessions: sessions)
        func put(_ name: String, _ text: String) throws {
            let url = stage.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try redact.apply(text).write(to: url, atomically: true, encoding: .utf8)
        }

        try put("README.txt", readme)
        let info = systemLines(dataDir: dataDir, now: now) + [""] + (context.isEmpty ? [] : ["界面状态："] + context)
        try put("info.txt", info.joined(separator: "\n") + "\n")
        try put("recent-messages.txt", history + "\n")
        try put("sessions.txt", sessionsSummary(sessions, redact: redact))
        try put("data-dir.txt", tree(dataDir))

        AppLog.flush()
        let logsDir = dataDir.appendingPathComponent(AppLog.logsFolderName, isDirectory: true)
        for url in AppLog.logFiles(in: logsDir) {
            guard let data = try? Data(contentsOf: url) else { continue }
            try put("logs/" + url.lastPathComponent, String(decoding: data, as: UTF8.self))
        }
        if let crashDir {
            for url in recentCrashReports(in: crashDir, now: now) {
                guard let data = try? Data(contentsOf: url) else { continue }
                try put("crash-reports/" + url.lastPathComponent, String(decoding: data, as: UTF8.self))
            }
        }

        let entries = listFiles(stage).map { folderName + "/" + $0 }
        let tmpZip = root.appendingPathComponent("out.zip")
        // 不带扩展属性、资源分叉（不然多出 __MACOSX/._*）；zip 里的名字全用 ASCII：ditto 不给 zip 标 UTF-8，
        // 别的解压工具（Windows、Python）会把中文名解成乱码。
        try runDitto(["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", stage.path, tmpZip.path])
        try fm.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 不先删：moveItem 遇到目标已经有东西（文件、文件夹、链接）就报错不动它；.numbered 换下一个名字再试。
        var target = zip
        var attempt = 1
        while true {
            if existingItem(at: target) == nil {
                do {
                    try fm.moveItem(at: tmpZip, to: target)
                    return Report(zip: target, entries: entries)
                } catch {
                    // 查完到挪之间被别人占了：照下面一样处理；别的错照实报。
                    guard existingItem(at: target) != nil else { throw error }
                }
            }
            guard existing == .numbered, attempt < 100 else {
                throw Failure(message: "\(target.path) 已经\(existingItem(at: target) ?? "有了")，不覆盖：换一个还没有的 .zip 文件名")
            }
            attempt += 1
            target = numberedSibling(zip, attempt)
        }
    }

    /// 这个位置已经有什么（文件夹 / 文件 / 链接）；没有 = nil。不跟符号链接（断了的链接也算有）。
    nonisolated static func existingItem(at url: URL) -> String? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let kind = st.st_mode & S_IFMT
        if kind == S_IFDIR { return "是一个文件夹" }
        if kind == S_IFLNK { return "有一个符号链接" }
        return "有这个文件"
    }

    /// 「诊断.zip」→「诊断-2.zip」。
    nonisolated static func numberedSibling(_ url: URL, _ n: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// 诊断摘要（复制进剪贴板的那份）：系统、界面状态、给定的几条提示，同样换掉路径。
    static func summaryText(dataDir: URL, context: [String], history: String) -> String {
        let redact = Redactor(home: NSHomeDirectory(), sessions: readSessions(dataDir))
        let lines = systemLines(dataDir: dataDir, now: Date()) + [""] + context + ["", "最近的提示：", history]
        return redact.apply(lines.joined(separator: "\n"))
    }

    static let readme = """
        选片工具诊断包
        - info.txt：版本、系统、机型、数据目录所在的盘还剩多少、导出时界面的状态
        - recent-messages.txt：这次打开以后状态栏出过的提示（最近 20 条）
        - logs/：app 的日志（最近约 5 MB）
        - sessions.txt、data-dir.txt：有几场、每场几张，数据目录里有哪些文件（只列名字和大小）
        - crash-reports/：最近 30 天里选片工具的崩溃报告（有的话）
        不含：照片、预览图（连文件名都不列）、客户回复和备注原文、场次记录（判决、sessions.json）。
        路径里的用户名换成了 ~，场次文件夹的路径和名字换成了 <场次 N>。

        """

    // MARK: 各部分

    static func systemLines(dataDir: URL, now: Date) -> [String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev（不是打包的 app）"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let process = ProcessInfo.processInfo
        let memoryGB = Double(process.physicalMemory) / 1_073_741_824
        let model = sysctlString("hw.model") ?? "-"
        let chip = sysctlString("machdep.cpu.brand_string") ?? "-"
        let free = CardImporter.freeBytes(near: dataDir).map(byteText) ?? "-"
        let stamp = DiagFormat.stamp.string(from: now)
        return [
            "选片工具 \(version)（build \(build)）",
            "可执行文件：\(Bundle.main.executablePath ?? CommandLine.arguments.first ?? "-")",
            "macOS：\(process.operatingSystemVersionString)",
            "机型：\(model) · 芯片：\(chip) · \(process.activeProcessorCount) 核 · 内存 \(String(format: "%.0f", memoryGB)) GB",
            "地区：\(Locale.current.identifier) · 时区：\(TimeZone.current.identifier)",
            "数据目录：\(dataDir.path) · 所在的盘还剩 \(free)",
            "导出时间：\(stamp)",
        ]
    }

    static func readSessions(_ dataDir: URL) -> [SessionDigest] {
        let url = dataDir.appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: url),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return array.compactMap { element in
            guard let dict = element as? [String: Any] else { return nil }
            let path = dict["path"] as? String ?? ""
            let key = (dict["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (path.isEmpty ? "?" : BatchStore.sessionKey(for: URL(fileURLWithPath: path)))
            return SessionDigest(key: key, path: path, name: dict["name"] as? String ?? "",
                                 photoCount: dict["photoCount"] as? Int ?? 0,
                                 lastAnalyzed: dict["lastAnalyzed"] as? String ?? "")
        }
    }

    static func sessionsSummary(_ sessions: [SessionDigest], redact: Redactor) -> String {
        guard !sessions.isEmpty else { return "sessions.json 里没有场次（或者读不出来）\n" }
        var lines = ["最近场次 \(sessions.count) 个（文件夹路径和名字不放，用代号；场次 key 对得上「数据目录结构」里的 sessions/<key>）："]
        for (index, session) in sessions.enumerated() {
            let label = redact.label(forSession: index)
            lines.append("\(label)  key \(session.key) · \(session.photoCount) 张 · 上次分析 \(session.lastAnalyzed)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 数据目录里有哪些文件：名字 + 大小；照片 / 预览图不列名字（每个文件夹一行「N 张图片」），运行时、预览目录只说总数。
    static func tree(_ dataDir: URL) -> String {
        var lines = ["数据目录（\(dataDir.lastPathComponent)）："]
        walk(dataDir, relative: "", depth: 0, into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func walk(_ dir: URL, relative: String, depth: Int, into lines: inout [String]) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else {
            lines.append("  \(relative.isEmpty ? "." : relative)/  （读不出来）")
            return
        }
        var imageCount = 0
        var imageBytes = 0
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let name = child.lastPathComponent
            let rel = relative.isEmpty ? name : relative + "/" + name
            if values?.isSymbolicLink == true {
                lines.append("  \(rel)  （符号链接）")
            } else if values?.isDirectory == true {
                if summarizedFolders.contains(name) || depth >= 4 {
                    let (count, bytes) = folderTotals(child)
                    lines.append("  \(rel)/  （\(count) 个文件，\(byteText(Int64(bytes)))，里面不列）")
                } else {
                    lines.append("  \(rel)/")
                    walk(child, relative: rel, depth: depth + 1, into: &lines)
                }
            } else if imageExtensions.contains(child.pathExtension.lowercased()) {
                imageCount += 1
                imageBytes += values?.fileSize ?? 0
            } else {
                lines.append("  \(rel)  \(byteText(Int64(values?.fileSize ?? 0)))")
            }
        }
        if imageCount > 0 {
            let at = relative.isEmpty ? "." : relative
            lines.append("  \(at)/  （另有 \(imageCount) 张图片，\(byteText(Int64(imageBytes)))，不列名字）")
        }
    }

    private static func folderTotals(_ dir: URL) -> (Int, Int) {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [], errorHandler: { _, _ in true }) else { return (0, 0) }
        var count = 0
        var bytes = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            count += 1
            bytes += v.fileSize ?? 0
        }
        return (count, bytes)
    }

    /// 最近 30 天里最新 3 份选片工具（裸二进制叫 LabelGUI）的崩溃报告。
    static func recentCrashReports(in dir: URL, now: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let ours = all.filter { url in
            let name = url.lastPathComponent
            let mine = name.hasPrefix("LabelGUI") || name.hasPrefix("选片工具")
            return mine && ["ips", "crash"].contains(url.pathExtension.lowercased())
        }
        let dated: [(URL, Date)] = ours.compactMap { url in
            guard let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate, date >= cutoff
            else { return nil }
            return (url, date)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    private static func listFiles(_ dir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = dir.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            out.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent)
        }
        return out.sorted()
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(message: "打 zip 失败（ditto 退出码 \(process.terminationStatus)）：\(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 打包前把文字里的隐私换掉：场次文件夹的路径（最长的先换）、「文件夹名」、家目录（数据目录跟着成了 ~/Library/…）。
struct Redactor {
    private let replacements: [(String, String)]
    private let quotedNames: [(String, String)]
    private let labels: [String]

    init(home: String, sessions: [DiagnosticsBundle.SessionDigest]) {
        var pairs: [(String, String)] = []
        var quoted: [(String, String)] = []
        var labels: [String] = []
        for (index, session) in sessions.enumerated() {
            let label = "<场次 \(index + 1)>"
            labels.append(label)
            if !session.path.isEmpty {
                let url = URL(fileURLWithPath: session.path)
                let forms = Set([session.path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
                for form in forms where form.count > 1 { pairs.append((form, label)) }
                let folder = url.lastPathComponent
                if !folder.isEmpty { quoted.append(("「\(folder)」", "「\(label)」")) }
            }
            if !session.name.isEmpty { quoted.append(("「\(session.name)」", "「\(label)」")) }
        }
        if home.count > 1 { pairs.append((home, "~")) }
        // 长的先换：/Volumes/T7/张三婚礼/仪式 先于 /Volumes/T7/张三婚礼，家目录最后。
        replacements = pairs.sorted { $0.0.count > $1.0.count }
        quotedNames = quoted
        self.labels = labels
    }

    func label(forSession index: Int) -> String {
        index < labels.count ? labels[index] : "<场次 \(index + 1)>"
    }

    func apply(_ text: String) -> String {
        var out = text
        for (from, to) in replacements { out = out.replacingOccurrences(of: from, with: to) }
        for (from, to) in quotedNames { out = out.replacingOccurrences(of: from, with: to) }
        return out
    }
}

// MARK: - 无头入口

/// LABELGUI_DATA_DIR=<临时> LabelGUI --diag-export <out.zip> [--crash-dir <目录>]：和「帮助 › 导出诊断信息…」同一个 zip，
/// 打印 zip 里的文件。只读数据目录、只写 out.zip；要 LABELGUI_DATA_DIR（测试别把真实数据目录的日志打出来）。
/// out.zip 必须是一个还没有的、以 .zip 结尾的文件名：给的是已有的文件夹 / 文件就退出码 2，什么都不动
/// （以前会把那个文件夹整个递归删掉、原地换成 zip）。
enum DiagnosticsCLI {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        CollageCLI.requireIsolatedDataDir("--diag-export", "会把数据目录里的日志和场次概况打进 zip")
        let args = CommandLine.arguments
        let given = args[flagIndex + 1]
        let out = URL(fileURLWithPath: given)
        if let what = DiagnosticsBundle.existingItem(at: out) {
            print("--diag-export：\(given) 已经\(what)，不覆盖、不往里写：给一个还没有的 .zip 文件名")
            exit(2)
        }
        guard out.pathExtension.lowercased() == "zip", !given.hasSuffix("/") else {
            print("--diag-export：\(given) 不是 .zip 文件名：给一个还没有的、以 .zip 结尾的文件名")
            exit(2)
        }
        let crashDir = args.firstIndex(of: "--crash-dir").flatMap { i in
            args.count > i + 1 ? URL(fileURLWithPath: args[i + 1], isDirectory: true) : nil
        }
        do {
            let report = try DiagnosticsBundle.write(dataDir: appDataDir, to: out, context: ["（无头 --diag-export：没有界面状态）"],
                                                     history: ErrorHistory.shared.plainText(), crashDir: crashDir)
            print("诊断包 → \(report.zip.path)（\(report.entries.count) 个文件）")
            for entry in report.entries { print("  " + entry) }
            exit(0)
        } catch {
            print("诊断包没打成：\(Diagnostics.describeIO(error))")
            exit(1)
        }
    }
}
