import Foundation
import os

// MARK: - 持久日志（全项目审查 D03）
//
// 以前 GUI 进程没有任何落盘的日志：从访达 / 程序坞启动时 stdout、stderr 都接在 /dev/null 上，print 和 LiveServer.log
// 全丢，状态栏那一行红字下一次操作就被清掉，别人机器上出了问题没有现场。现在两份（状态栏提示、实时桥的 LiveServer.log、
// 列照片时跳过的文件夹都写进来）：
//   - os.Logger（subsystem local.culling.labelgui，和 SessionFiles.log 同一个），「控制台」里按 subsystem 能筛；
//   - 数据目录 logs/app.log 一份文本（一条一行，带时间、进程、级别、分类），超过 1 MB 轮转成 app.1.log … app.4.log，
//     最多留 5 份（≈ 5 MB）。「帮助 › 导出诊断信息…」把它们打进 zip。
// 文本只在开界面那一条路落盘（main.swift 里 LabelGUIApp.main() 之前 installFileLog）和自检里：--mcp 对数据目录只读
// （DESIGN §10.0、README「不写数据目录」），无头命令照旧打印到终端，不往数据目录多写一个 logs/。
// 这里一个字节都不往 stderr 写（MCP 模式下 stderr 读端关了会 SIGPIPE，见 StdioTakeover.swift）。

enum AppLog {
    static let subsystem = "local.culling.labelgui"

    enum Level: String, Sendable {
        case info, notice, warning, error
    }

    /// 这一个进程的文本日志（没装 = nil：只进 os.Logger）。
    private static let state = OSAllocatedUnfairLock<AppLogFile?>(initialState: nil)
    private static let loggers = OSAllocatedUnfairLock<[String: Logger]>(initialState: [:])

    static func info(_ category: String, _ message: String) { write(category, .info, message) }
    static func notice(_ category: String, _ message: String) { write(category, .notice, message) }
    static func warning(_ category: String, _ message: String) { write(category, .warning, message) }
    static func error(_ category: String, _ message: String) { write(category, .error, message) }

    /// 任何线程都能调；文本那份在后台串行队列里写，不卡调用方。
    static func write(_ category: String, _ level: Level, _ message: String) {
        let logger = loggers.withLock { cache -> Logger in
            if let hit = cache[category] { return hit }
            let made = Logger(subsystem: subsystem, category: category)
            cache[category] = made
            return made
        }
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let file = state.withLock { $0 }
        file?.append(Date(), category: category, level: level, message: message)
    }

    /// 开始往 `<dataDir>/logs/` 落盘，返回日志目录（建不了 = nil，照样只进 os.Logger）。同一个进程只装一次。
    /// `role` 写进每一行（GUI / 自检），`maxBytes`、`keep` 只有自检改（测轮转）。
    @discardableResult
    static func installFileLog(dataDir: URL, role: String, maxBytes: Int = 1 << 20, keep: Int = 5) -> URL? {
        let dir = dataDir.appendingPathComponent(logsFolderName, isDirectory: true)
        let installed = state.withLock { current -> AppLogFile? in
            if let current { return current }
            let made = AppLogFile(dir: dir, role: role, maxBytes: maxBytes, keep: keep)
            current = made
            return made
        }
        return installed?.dir
    }

    /// 自检用：卸下（下一次 install 换一个目录 / 参数）。会先把排着的写完。
    static func uninstallFileLog() {
        let old = state.withLock { current -> AppLogFile? in
            let old = current
            current = nil
            return old
        }
        old?.close()
    }

    /// 排着的都写进文件再返回（退出前、导出诊断包前、自检里读文件前）。
    static func flush() {
        state.withLock { $0 }?.sync()
    }

    /// 装上的那个日志目录（没装 = nil）。
    static var logsDir: URL? { state.withLock { $0 }?.dir }

    static let logsFolderName = "logs"
    static let fileName = "app.log"

    /// 日志目录里的文件，新的在前：app.log、app.1.log、app.2.log…（诊断包、自检用）。
    static func logFiles(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        func order(_ name: String) -> Int? {
            if name == fileName { return 0 }
            guard name.hasPrefix("app."), name.hasSuffix(".log") else { return nil }
            return Int(name.dropFirst(4).dropLast(4))
        }
        return names.compactMap { name in order(name).map { (name, $0) } }
            .sorted { $0.1 < $1.1 }
            .map { dir.appendingPathComponent($0.0) }
    }

    /// 一条日志里的换行折成「 ⏎ 」：一条一行，grep、轮转都按行。
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ⏎ ")
    }
}

/// 一个进程的文本日志：O_APPEND 一次 write 一整行（同一个数据目录万一有两个进程在写，行也不会互相截断），
/// 超过上限轮转。所有文件操作都在自己的串行队列里。
final class AppLogFile: @unchecked Sendable {
    let dir: URL
    private let role: String
    private let maxBytes: Int
    private let keep: Int
    private let queue = DispatchQueue(label: "local.culling.labelgui.applog", qos: .utility)
    private var fd: Int32 = -1
    private var size = 0
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZ"
        return f
    }()

    init?(dir: URL, role: String, maxBytes: Int, keep: Int) {
        self.dir = dir
        self.role = role
        self.maxBytes = max(4096, maxBytes)
        self.keep = max(2, keep)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard open() else { return nil }
        // 上一次装的参数可能留得更多（keep 改小了）：多出来的旧文件删掉。
        for url in AppLog.logFiles(in: dir).dropFirst(self.keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var current: URL { dir.appendingPathComponent(AppLog.fileName) }

    private func open() -> Bool {
        fd = Darwin.open(current.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        var st = stat()
        size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
        return true
    }

    func append(_ date: Date, category: String, level: AppLog.Level, message: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        queue.async { [self] in
            let stamp = formatter.string(from: date)
            let line = "\(stamp) \(role)[\(pid)] \(level.rawValue) \(category): \(AppLog.oneLine(message))\n"
            writeLine(line)
        }
    }

    func sync() { queue.sync {} }

    func close() {
        queue.sync {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }
    }

    private func writeLine(_ line: String) {
        let bytes = Array(line.utf8)
        if size > 0 && size + bytes.count > maxBytes { rotate() }
        guard fd >= 0 else { return }
        let written = bytes.withUnsafeBytes { raw -> Int in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                off += n
            }
            return off
        }
        size += written
    }

    /// app.log → app.1.log → … → app.(keep-1).log，最老的那份删掉，再开一个新的 app.log。
    private func rotate() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        func numbered(_ i: Int) -> URL { dir.appendingPathComponent(i == 0 ? AppLog.fileName : "app.\(i).log") }
        unlink(numbered(keep - 1).path)
        for i in stride(from: keep - 2, through: 0, by: -1) {
            rename(numbered(i).path, numbered(i + 1).path)
        }
        _ = open()
    }
}
