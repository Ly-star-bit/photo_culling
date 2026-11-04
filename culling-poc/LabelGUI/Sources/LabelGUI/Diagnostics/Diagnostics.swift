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
//      sessions.json、客户备注一律不放；所有文字里的路径都打码（家目录 ~、盘名 <盘 N>、场次文件夹 <场次 N>、别的文件夹
//      <文件夹 N>，不只认 sessions.json 里登记的，见 Redactor），「」“”"" 里的文件夹名、盘名同样换掉。
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
        + "不含照片、预览图、客户回复原文和场次记录；所有路径里的用户名、盘名、文件夹名都换成了代号（照片文件名留着）。发给开发者就行。"

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
        let folders = model?.batch.diagnosticFolders ?? DiagnosticsBundle.LiveFolders()
        let dataDir = appDataDir
        let crashDir = crashReportsDir
        Task.detached {
            do {
                // 保存面板里点了「替换」也不删原来那个：换个名字「…-2.zip」，访达里选中真正写出来的那个。
                let report = try DiagnosticsBundle.write(dataDir: dataDir, to: url, context: context, history: history,
                                                         crashDir: crashDir, existing: .numbered, folders: folders)
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
                                                 history: ErrorHistory.shared.plainText(recent),
                                                 folders: model?.batch.diagnosticFolders ?? DiagnosticsBundle.LiveFolders())
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
            // key 用钉住的那个（sessions/<key> 的名字）：认回 / 书签跟到新位置以后，按 photoDir 现算的对不上 sessions.txt。
            let key = batch.sessionDir.lastPathComponent
            var parts = ["当前场次：\(dir.path)（key \(key)）", "\(batch.items.count) 张"]
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

extension BatchStore {
    /// 诊断包打码要认的、sessions.json 以外的文件夹：当前打开的（书签解析以后的路径、还没登记的新文件夹）和钉住的 key，
    /// 内存里的最近场次。
    var diagnosticFolders: DiagnosticsBundle.LiveFolders {
        let recent = recentSessions.map { DiagnosticsBundle.LiveFolders.Entry(key: $0.key, path: $0.path, name: $0.name) }
        let key: String? = photoDir == nil ? nil : sessionDir.lastPathComponent
        return DiagnosticsBundle.LiveFolders(current: photoDir?.path, currentKey: key, recent: recent)
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

    /// 界面那一路额外知道、sessions.json 里却可能没有的文件夹（打码的种子）：当前打开的这一场 —— 书签解析以后的路径
    /// （认回 / 改名 / 挪过以后和 sessions.json 里钉着的旧路径不一样），还没分析成的新文件夹根本不在 sessions.json 里 ——
    /// 和内存里的最近场次。无头 --diag-export 没有界面，全空。
    struct LiveFolders: Sendable {
        struct Entry: Sendable {
            let key: String
            let path: String
            let name: String
        }
        /// 当前打开的照片文件夹（photoDir）；没打开 = nil。
        var current: String?
        /// 当前这一场钉住的 key（sessionDir 的名字，不按 photoDir 重算）。
        var currentKey: String?
        var recent: [Entry] = []
    }

    /// 数据目录里每一场 manifest.json 的 photo_dir（key → 路径）：掉出最近 15 场、被「移除历史记录」删掉的旧场次，
    /// 认回 / 重新定位以后改到新位置的，日志里还留着它们的路径。只读每个文件开头一段（分析引擎按键名排序写，photo_dir 在最前面），
    /// 没找到再整份解析（只解析 8 MB 以内的）。
    static func manifestFolders(_ dataDir: URL) -> [(key: String, path: String)] {
        let sessions = dataDir.appendingPathComponent("sessions", isDirectory: true)
        let keys = ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).sorted()
        var out: [(key: String, path: String)] = []
        for key in keys {
            let url = sessions.appendingPathComponent(key).appendingPathComponent("manifest.json")
            if let path = manifestPhotoDir(url), !path.isEmpty { out.append((key, path)) }
        }
        return out
    }

    private static func manifestPhotoDir(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let text = String(decoding: head, as: UTF8.self)
        let pattern = #""photo_dir"\s*:\s*("(?:[^"\\]|\\.)*")"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let literal = try? JSONSerialization.jsonObject(with: Data(text[range].utf8), options: [.fragmentsAllowed]),
           let path = literal as? String {
            return path
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0, size <= 8 << 20, let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["photo_dir"] as? String
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
                      existing: ExistingTarget = .refuse, folders: LiveFolders = LiveFolders(),
                      now: Date = Date()) throws -> Report {
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
        let redact = Redactor(home: NSHomeDirectory(), sessions: sessions, live: folders,
                              manifests: manifestFolders(dataDir))
        // 先把要进包的文字都收齐、一起打码（一份里认出来的文件夹名，别的几份里「」里的同一个名字也换掉），再写。
        var parts: [(name: String, text: String)] = []
        parts.append(("README.txt", readme))
        let info = systemLines(dataDir: dataDir, now: now) + [""] + (context.isEmpty ? [] : ["界面状态："] + context)
        parts.append(("info.txt", info.joined(separator: "\n") + "\n"))
        parts.append(("recent-messages.txt", history + "\n"))
        parts.append(("sessions.txt", sessionsSummary(sessions, redact: redact)))
        parts.append(("data-dir.txt", tree(dataDir, redact: redact)))

        AppLog.flush()
        let logsDir = dataDir.appendingPathComponent(AppLog.logsFolderName, isDirectory: true)
        for url in AppLog.logFiles(in: logsDir) {
            guard let data = try? Data(contentsOf: url) else { continue }
            parts.append(("logs/" + url.lastPathComponent, String(decoding: data, as: UTF8.self)))
        }
        if let crashDir {
            for url in recentCrashReports(in: crashDir, now: now) {
                guard let data = try? Data(contentsOf: url) else { continue }
                // .ips 是 JSON，路径写成 \/Users\/…（JSON 里 \/ 和 / 一样）：先还原成 /，打码才认得出来。
                let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
                parts.append(("crash-reports/" + url.lastPathComponent, text))
            }
        }
        let redacted = redact.applyAll(parts.map(\.text))
        for (index, part) in parts.enumerated() {
            let url = stage.appendingPathComponent(part.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try redacted[index].write(to: url, atomically: true, encoding: .utf8)
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
    static func summaryText(dataDir: URL, context: [String], history: String,
                            folders: LiveFolders = LiveFolders()) -> String {
        let redact = Redactor(home: NSHomeDirectory(), sessions: readSessions(dataDir), live: folders,
                              manifests: manifestFolders(dataDir))
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
        所有路径都打了码：家目录换成 ~，外置盘的名字换成 <盘 N>，场次文件夹（最近场次、当前打开的、数据目录里还留着
        结果的旧场次）换成 <场次 N>（当前打开、还没登记的那个是 <当前场次>），别的文件夹名换成 <文件夹 N>；
        「」里的文件夹名、盘名同样换掉。系统文件夹（桌面、文稿、资源库……）和照片文件名照原样留着。

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
    /// 名字也打码（`redact.dataDirName`）：app 自己起的英文名照原样，别的（中文、带空格的）换成 <文件夹 N> / <文件 N>。
    static func tree(_ dataDir: URL, redact: Redactor) -> String {
        var lines = ["数据目录（\(redact.dataDirName(dataDir.lastPathComponent, isDirectory: true))）："]
        walk(dataDir, relative: "", depth: 0, redact: redact, into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func walk(_ dir: URL, relative: String, depth: Int, redact: Redactor, into lines: inout [String]) {
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
            let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
            let shown = redact.dataDirName(name, isDirectory: isFolder)
            let rel = relative.isEmpty ? shown : relative + "/" + shown
            if values?.isSymbolicLink == true {
                lines.append("  \(rel)  （符号链接）")
            } else if values?.isDirectory == true {
                if summarizedFolders.contains(name) || depth >= 4 {
                    let (count, bytes) = folderTotals(child)
                    lines.append("  \(rel)/  （\(count) 个文件，\(byteText(Int64(bytes)))，里面不列）")
                } else {
                    lines.append("  \(rel)/")
                    walk(child, relative: rel, depth: depth + 1, redact: redact, into: &lines)
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

/// 打包前把文字里的隐私换掉（审查：以前只认 sessions.json 里登记的场次 —— 还没分析成的新文件夹、认回 / 挪过 / 书签
/// 解析到的新路径、掉出最近 15 场的旧场次、日志里随便哪条路径，客户名原样进包）。三步：
///   1. 认得的文件夹（sessions.json、当前打开的、内存里的最近场次、数据目录里各场 manifest 的 photo_dir）整条路径换成
///      <场次 N>（当前打开、还没登记的是 <当前场次>）；家目录换成 ~。长的先换，只在一段路径的结尾处换。
///   2. 文字里出现的任意绝对路径（/… 或 ~/…）逐段打码：/Volumes/<盘名> → <盘 N>，/Users/<别人> → <用户>；系统文件夹
///      （桌面、文稿、资源库、/System、/usr、临时目录前面那几段随机名……）、场次 key、DCIM 下的 100CANON、纯日期数字照原样；
///      最后一段是英文数字名字的文件（DSCF0001.RAF、app.1.log）照原样，中文名的文件换成 <文件 N>.扩展名；其余每段换成
///      <文件夹 N>（同一个名字在整个包里是同一个代号）。
///   3. 「」里的名字：上面认得的、路径里打过码的同一个名字换成同一个代号；「文件夹「X」」「场次「X」」「存储卡「X」」
///      「「X」里找不到」这种一看就是文件夹 / 盘名的，没见过也换掉。弯引号 “X”（系统 NSError 的 localizedDescription：
///      The file “X” couldn’t be opened…，这个 app 拿到的是英文）、直引号 "X"（日志里打印的 NSError、英文）同样认，
///      英文的 the folder / the directory “X”、不像文件名的 the file “X”（列不存在的文件夹时系统也说 file）也算文件夹。
/// 不做裸词替换：文件夹叫「照片」「婚礼」也不会把正文里的这几个字换掉。
final class Redactor {
    /// 第 1 步：整条路径 → 代号（长的在前）。
    private var pathPairs: [(String, String)] = []
    /// 认得的文件夹名、场次名 → 代号。
    private var names: [String: String] = [:]
    /// 第 2、3 步现认出来的：别的文件夹名 → <文件夹 N>、盘名 → <盘 N>、中文文件名 → <文件 N>。
    private var folders: [String: String] = [:]
    private var volumes: [String: String] = [:]
    private var files: [String: String] = [:]
    private var labels: [String] = []
    private var sessionCount = 0

    init(home: String, sessions: [DiagnosticsBundle.SessionDigest],
         live: DiagnosticsBundle.LiveFolders = DiagnosticsBundle.LiveFolders(),
         manifests: [(key: String, path: String)] = []) {
        var byKey: [String: String] = [:]
        for session in sessions {
            let label = newSessionLabel()
            labels.append(label)
            if byKey[session.key] == nil { byKey[session.key] = label }
            seed(path: session.path, name: session.name, label: label)
        }
        for entry in live.recent where byKey[entry.key] == nil {
            let label = newSessionLabel()
            byKey[entry.key] = label
            seed(path: entry.path, name: entry.name, label: label)
        }
        if let current = live.current, !current.isEmpty {
            // 钉住的 key 对得上一场：用那一场的代号（书签解析到的新路径和 sessions.json 里的旧路径是同一场）。
            let known = live.currentKey.flatMap { byKey[$0] }
            let label = known ?? "<当前场次>"
            if known == nil, let key = live.currentKey { byKey[key] = label }
            seed(path: current, name: "", label: label)
        }
        for manifest in manifests {
            let label = byKey[manifest.key] ?? newSessionLabel()
            byKey[manifest.key] = label
            seed(path: manifest.path, name: "", label: label)
        }
        if home.count > 1 { pathPairs.append((home, "~")) }
        // 同一条路径两个代号：先登记的算（sessions.json 在最前面）。
        for (form, label) in pathPairs where knownForms[form] == nil { knownForms[form] = label }
        // 长的先换：/Volumes/T7/张三婚礼/仪式 先于 /Volumes/T7/张三婚礼，家目录在它们后面。一个正则一次扫完（几 MB 的日志、
        // 几十场也只扫一遍），只在一段路径的结尾处换：认得 /a/张三 不会把 /a/张三婚礼 换成「<场次 1>婚礼」。
        let forms = knownForms.keys.sorted { $0.count > $1.count }
        if !forms.isEmpty {
            let alternatives = forms.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            let boundary = #"(?=[/.…\s」”）)\]}"'：:，、;；|·⏎（(<>→]|$)"#
            knownRegex = try? NSRegularExpression(pattern: "(?:" + alternatives + ")" + boundary)
        }
    }

    /// 第 1 步用的：认得的整条路径（各种写法）→ 代号，和把它们一次找出来的正则。
    private var knownForms: [String: String] = [:]
    private var knownRegex: NSRegularExpression?

    private func newSessionLabel() -> String {
        sessionCount += 1
        return "<场次 \(sessionCount)>"
    }

    private func seed(path: String, name: String, label: String) {
        if !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            var forms: Set<String> = [path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
            // /var、/tmp 和 /private/var、/private/tmp 是同一个地方，日志里两种写法都有。
            for form in Array(forms) {
                if form.hasPrefix("/private/") {
                    forms.insert(String(form.dropFirst("/private".count)))
                } else if form.hasPrefix("/var/") || form.hasPrefix("/tmp/") {
                    forms.insert("/private" + form)
                }
            }
            for form in forms where form.count > 1 { pathPairs.append((form, label)) }
            let folder = url.lastPathComponent
            if !folder.isEmpty, folder != "/", names[folder] == nil { names[folder] = label }
        }
        if !name.isEmpty, names[name] == nil { names[name] = label }
    }

    func label(forSession index: Int) -> String {
        index < labels.count ? labels[index] : "<场次 \(index + 1)>"
    }

    func apply(_ text: String) -> String {
        applyAll([text])[0]
    }

    /// 一起打码：先换路径（同时记下打过码的文件夹名、盘名），再换所有文字里「」里的同一个名字。
    /// 整段都用 NSString（UTF-16）做：NSRegularExpression 直接扫原生 Swift 字符串，几 MB 的日志要几十秒。
    func applyAll(_ texts: [String]) -> [String] {
        let pathsDone = texts.map { maskPaths(replaceKnown(NSMutableString(string: $0))) }
        for text in pathsDone { learnQuoted(text) }
        return pathsDone.map { maskQuoted($0) as String }
    }

    /// `regex` 在 `ns` 里的每一处换成 `transform` 给的字（nil = 原样）。
    private static func replacing(_ regex: NSRegularExpression, in ns: NSString,
                                  _ transform: (NSTextCheckingResult) -> String?) -> NSString {
        let matches = regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return ns }
        let out = NSMutableString(capacity: ns.length)
        var last = 0
        for match in matches {
            let range = match.range
            out.append(ns.substring(with: NSRange(location: last, length: range.location - last)))
            out.append(transform(match) ?? ns.substring(with: range))
            last = range.location + range.length
        }
        out.append(ns.substring(from: last))
        return out
    }

    /// 数据目录结构（data-dir.txt）里的一个名字：app 自己起的英文名照原样，别的换成代号。
    func dataDirName(_ name: String, isDirectory: Bool) -> String {
        if Self.keepsName(name) || Self.isPlainName(name) { return name }
        if let label = names[name] { return label }
        if !isDirectory, let masked = maskFileName(name) { return masked }
        return isDirectory ? folderLabel(name) : fileLabel(name)
    }

    // MARK: 第 1 步

    private func replaceKnown(_ ns: NSString) -> NSString {
        guard let regex = knownRegex else { return ns }
        let forms = knownForms
        return Self.replacing(regex, in: ns) { forms[ns.substring(with: $0.range)] }
    }

    // MARK: 第 2 步：任意路径逐段打码

    /// 路径从这些字后面开始（行首、空白、左括号引号、冒号等号……、代号的 >），到中文标点、引号、换行、日志里折行的 ⏎ 为止。
    /// 括号不算终点（文件夹名里常有「婚礼（张三）」）：多出来的右括号在 splitTail 里切掉。
    private static let pathRegex: NSRegularExpression = {
        let starts = #"\s(（「“\[{"'=:：,，、;；|>→/"#
        let stops = #"\n\r\t」”\]}"'：:，、;；|·⏎<>→"#
        // (?<!:/)：网址 https://… 的第二个 / 不算路径开头。
        let pattern = "(?<![^" + starts + "])(?<!:/)(?:~(?=/)|/(?=[^/\\s<]))[^" + stops + "]*"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private func maskPaths(_ ns: NSString) -> NSString {
        Self.replacing(Self.pathRegex, in: ns) { match in
            let (path, tail) = Self.splitTail(ns.substring(with: match.range))
            // 切下来的后半截里可能还有路径（「/a/DSCF0001.RAF 和 /b/x」）：接着扫。
            let rest = tail.isEmpty ? "" : maskPaths(NSMutableString(string: tail)) as String
            return maskPath(path) + rest
        }
    }

    /// 匹配到的一段从左往右看：没配对的右括号（「（/Volumes/T7/x）」的那个 ））、前面一段正好是文件名的空格
    /// （「DSCF0001.RAF 等 3 张」「封面 周九.jpg 失败」）到那里为止；末尾的空白和句号也不算路径。
    private static func splitTail(_ raw: String) -> (String, String) {
        var cut = raw.endIndex
        var depth = 0
        var partStart = raw.startIndex
        for index in raw.indices {
            let c = raw[index]
            if c == "/" {
                partStart = raw.index(after: index)
            } else if c == "(" || c == "（" {
                depth += 1
            } else if c == ")" || c == "）" {
                if depth == 0 {
                    cut = index
                    break
                }
                depth -= 1
            } else if c == " " {
                let part = String(raw[partStart..<index])
                let ext = (part as NSString).pathExtension.lowercased()
                if !ext.isEmpty, fileExtensions.contains(ext) {
                    cut = index
                    break
                }
            }
        }
        var path = String(raw[..<cut])
        while let c = path.last, c.isWhitespace || c == "." || c == "," || c == "…" || c == "。" {
            path.removeLast()
        }
        guard !path.isEmpty else { return (raw, "") }
        return (path, String(raw.dropFirst(path.count)))
    }

    private func maskPath(_ path: String) -> String {
        var parts = path.components(separatedBy: "/")
        guard parts.count > 1 else { return path }
        let start = userZoneStart(&parts)
        if start < parts.count {
            let lastIndex = parts.count - 1
            for i in start..<parts.count {
                parts[i] = maskComponent(parts[i], isLast: i == lastIndex)
            }
        }
        return parts.joined(separator: "/")
    }

    /// 从第几段起按「用户自己的文件夹」打码；前面的系统段照原样（盘名、别的用户名在这里换掉）。
    private func userZoneStart(_ parts: inout [String]) -> Int {
        if parts[0] == "~" { return 1 }
        guard parts[0].isEmpty else { return 0 }
        func at(_ i: Int) -> String { i < parts.count ? parts[i] : "" }
        switch parts[1] {
        case "Volumes":
            if !at(2).isEmpty { parts[2] = volumeLabel(parts[2]) }
            return 3
        case "Users":
            let user = at(2)
            if !user.isEmpty, user != "Shared", !Self.isLabel(user) { parts[2] = "<用户>" }
            return 3
        case "private", "var":
            // 临时目录：/var/folders/<2 段随机>/<T|C|0>/ 照原样，再往下按用户的文件夹打码。
            let v = parts[1] == "private" ? 2 : 1
            if at(v) == "var", at(v + 1) == "folders" { return v + 5 }
            if parts[1] == "private", at(2) == "tmp" { return 3 }
            return parts.count
        case "tmp", "Network", "net":
            return 2
        case "System", "usr", "bin", "sbin", "Library", "Applications", "opt", "dev", "etc", "cores":
            return parts.count
        default:
            return 1
        }
    }

    private func maskComponent(_ part: String, isLast: Bool) -> String {
        if part.isEmpty || part == "." || part == ".." || part == "~" || Self.isLabel(part) { return part }
        if let label = names[part] { return label }
        if Self.keepsName(part) { return part }
        if isLast, let masked = maskFileName(part) { return masked }
        return folderLabel(part)
    }

    /// 像文件名（认得的扩展名）：名字是英文数字的照原样，别的换成 <文件 N>.扩展名；不像文件名 = nil（当文件夹打码）。
    private func maskFileName(_ part: String) -> String? {
        let ext = (part as NSString).pathExtension
        guard !ext.isEmpty, Self.fileExtensions.contains(ext.lowercased()) else { return nil }
        let stem = (part as NSString).deletingPathExtension
        if Self.isPlainName(stem) { return part }
        if let label = names[stem] { return label + "." + ext }
        return fileLabel(stem) + "." + ext
    }

    private func folderLabel(_ name: String) -> String {
        if let hit = folders[name] { return hit }
        let made = "<文件夹 \(folders.count + 1)>"
        folders[name] = made
        return made
    }

    private func volumeLabel(_ name: String) -> String {
        if Self.isLabel(name) || name == "Macintosh HD" || name == "Macintosh HD - Data" { return name }
        if let hit = volumes[name] { return hit }
        let made = "<盘 \(volumes.count + 1)>"
        volumes[name] = made
        return made
    }

    private func fileLabel(_ name: String) -> String {
        if let hit = files[name] { return hit }
        let made = "<文件 \(files.count + 1)>"
        files[name] = made
        return made
    }

    private static func isLabel(_ part: String) -> Bool {
        part.hasPrefix("<") && part.hasSuffix(">")
    }

    /// 英文、数字、_ . + - 组成的名字（DSCF0001、IMG_1234、app.1、manifest.json）。
    private static func isPlainName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let extra: Set<Character> = ["_", ".", "+", "-"]
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || extra.contains($0)) }
    }

    /// 不打码的段：系统和 app 自己的文件夹名、场次 key、UUID、DCIM 下的 100CANON、纯日期数字。
    private static func keepsName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if keptNames.contains(lower) || lower.hasPrefix("xuanpian-") || name.hasPrefix("选片工具") { return true }
        let hex = Set("0123456789abcdef")
        if lower.count == 16, lower.allSatisfy({ hex.contains($0) }) { return true }
        let groups = lower.split(separator: "-", omittingEmptySubsequences: false).map(\.count)
        if groups == [8, 4, 4, 4, 12], lower.allSatisfy({ hex.contains($0) || $0 == "-" }) { return true }
        if isDCFFolder(name) { return true }
        let dateChars = Set("0123456789-_. ")
        if let first = name.first, first.isASCII, first.isNumber, name.allSatisfy({ dateChars.contains($0) }) { return true }
        return false
    }

    /// DCIM 下的文件夹：三位数字 + 五个英文数字（100CANON、101MSDCF、100_FUJI）。
    private static func isDCFFolder(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count == 8, chars.allSatisfy(\.isASCII) else { return false }
        let digits = chars[0..<3].allSatisfy(\.isNumber)
        let rest = chars[3...].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return digits && rest
    }

    private static let keptNames: Set<String> = [
        "desktop", "documents", "downloads", "pictures", "movies", "music", "public", "sites", "library",
        "application support", "caches", "logs", "diagnosticreports", "containers", "group containers",
        "mobile documents", "com~apple~clouddocs", "cloudstorage", "preferences", "applications", "shared",
        ".trash", ".trashes", "dcim", "volumes", "users", "servers", "contents", "macos", "resources", "frameworks",
        "t", "c", "0", "tmp", "private", "var", "folders", "sessions", "previews", "thumbs", "thumbnails", "cache",
        "runtime", ".venv", "fonts", "labelgui", "选片工具.app",
    ]

    /// 路径最后一段带这些扩展名的当文件（名字是英文数字的照原样留着），别的当文件夹。
    private static let fileExtensions: Set<String> = DiagnosticsBundle.imageExtensions.union([
        "xmp", "json", "log", "txt", "zip", "pdf", "ips", "crash", "sock", "lock", "plist", "db", "sqlite", "csv",
        "md", "py", "app", "ttf", "otf", "dylib", "mov", "mp4", "m4v", "partial", "tmp", "html", "xml", "sh",
    ])

    // MARK: 第 3 步：「」里的名字

    /// 三种引号：「X」（app 自己的话）、“X”（系统 NSError 的 localizedDescription）、"X"（日志里打印的 NSError、英文）。
    /// 各扫各的：日志里 "The file “X” couldn’t…" 整句在直引号里，里面的 “X” 也要认出来。直引号允许空的（JSON 里的 ""
    /// 不打乱后面的配对）。
    private static let quoteForms: [(open: String, close: String, regex: NSRegularExpression)] = [
        ("「", "」", try! NSRegularExpression(pattern: "「([^「」\\n]{1,120})」")),
        ("“", "”", try! NSRegularExpression(pattern: "“([^“”\\n]{1,120})”")),
        ("\"", "\"", try! NSRegularExpression(pattern: "\"([^\"\\n]{0,120})\"")),
    ]

    /// 「」前面是这些字：里面是文件夹 / 场次的名字。
    private static let folderBefore = ["文件夹", "场次", "认出了", "移除", "目录"]
    /// 「」后面是这些字：里面是文件夹的名字（「X」里找不到…、「X」的照片现在在哪、「X」不是一个文件夹…）。
    private static let folderAfter = ["里找不到", "里面", "的照片", "不是一个文件夹", "已有分析结果", "已经不在", "重新定位", "那一场",
                                      "的位置"]

    private func forEachQuoted(_ ns: NSString, _ body: (_ name: String, _ before: String, _ after: String) -> Void) {
        for form in Self.quoteForms {
            for match in form.regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                let beforeStart = max(0, match.range.location - 12)
                let before = ns.substring(with: NSRange(location: beforeStart, length: match.range.location - beforeStart))
                let afterStart = match.range.location + match.range.length
                let after = ns.substring(with: NSRange(location: afterStart, length: min(10, ns.length - afterStart)))
                body(name, before, after)
            }
        }
    }

    private func learnQuoted(_ ns: NSString) {
        forEachQuoted(ns) { name, before, after in
            guard !name.isEmpty, !Self.isLabel(name), knownLabel(name) == nil else { return }
            let english = Self.englishWord(before: before)
            let folderish = Self.folderBefore.contains(where: { before.hasSuffix($0) })
                || Self.folderAfter.contains(where: { after.hasPrefix($0) })
                || english == "folder" || english == "directory"
                || (english == "file" && !Self.looksLikeFile(name) && !Self.keepsName(name))
            if before.hasSuffix("卡") || after.hasPrefix("上，") {
                _ = volumeLabel(name)
            } else if folderish {
                _ = folderLabel(name)
            }
        }
    }

    /// 引号前面紧挨着的那个英文词（「the folder “X”」→ folder），小写；不是「词 + 空格」结尾的 = nil。
    private static func englishWord(before: String) -> String? {
        guard before.hasSuffix(" ") else { return nil }
        let word = before.dropLast().reversed().prefix { $0.isASCII && $0.isLetter }
        return word.isEmpty ? nil : String(word.reversed()).lowercased()
    }

    /// 带认得的扩展名（a.csv、DSCF0001.RAF）：the file “X” 里这种是文件，不当文件夹换。
    private static func looksLikeFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && fileExtensions.contains(ext.lowercased())
    }

    private func knownLabel(_ name: String) -> String? {
        names[name] ?? volumes[name] ?? folders[name]
    }

    private func maskQuoted(_ ns: NSString) -> NSString {
        var out = ns
        for form in Self.quoteForms {
            let current = out
            out = Self.replacing(form.regex, in: current) { match in
                knownLabel(current.substring(with: match.range(at: 1))).map { form.open + $0 + form.close }
            }
        }
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
