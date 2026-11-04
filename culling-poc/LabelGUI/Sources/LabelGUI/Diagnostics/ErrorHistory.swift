import AppKit
import SwiftUI

// MARK: - 状态栏提示的历史（全项目审查 D03）
//
// 三个 tab 的状态栏以前都是 `Text(error).lineLimit(1).help(error)`：选不中、复制不了，下一次操作把 lastError 置空就
// 再也找不回来。现在 BatchStore / CollageStore / WatermarkStore 的 lastError 一被设上（didSet）就记一条进这里
// （最近 20 条，新的在前，三个 tab 一起）。状态栏那一行点一下弹出全文：可选中、带「复制」，
// 下面是最近的历史。lastError 本身还是 String?（实时桥 app_says 读它），这里只是旁边多记一份。
// 里面混着不是错误的提醒（压不到体积上限、XMP 原样保留、预览被清理……），所以每条按字面分「错误 / 提醒」两级。

@MainActor
final class ErrorHistory: ObservableObject {
    static let shared = ErrorHistory()
    static let capacity = 20

    enum Source: String, CaseIterable, Sendable {
        case batch = "批量"
        case collage = "拼图"
        case watermark = "水印"
    }

    enum Level: String, Sendable {
        case error = "错误"
        case notice = "提醒"
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var date: Date
        let source: Source
        let level: Level
        let text: String
        /// 同一个 tab 连着出了几次一模一样的（不重复占位置，只记次数）。
        var repeats = 1
    }

    /// 新的在前，最多 `capacity` 条。
    @Published private(set) var entries: [Entry] = []

    /// store 的 lastError didSet 调：nil、空的不记；和最新一条一模一样（同一个 tab）的只加次数、更新时间。
    func record(_ text: String?, source: Source) {
        guard let text, !text.isEmpty else { return }
        let level = Self.level(of: text)
        if let first = entries.first, first.source == source, first.text == text {
            entries[0].repeats += 1
            entries[0].date = Date()
        } else {
            entries.insert(Entry(date: Date(), source: source, level: level, text: text), at: 0)
            if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        }
    }

    /// 自检用。
    func clear() { entries = [] }

    /// 按字面分级：说了失败、不能、读不了、没有权限……的算错误，其余（注意、压不到上限、原样保留）算提醒。
    nonisolated static func level(of text: String) -> Level {
        errorWords.contains { text.contains($0) } ? .error : .notice
    }

    nonisolated static let errorWords = [
        "失败", "出错", "错误", "无法", "不能", "读不了", "读不出", "写不进", "没写进去", "没存上", "没有权限",
        "不存在", "解不开", "盘满", "断开", "不支持", "拒绝", "被拦", "超时",
    ]

    /// 「全部复制」的纯文字：一条一段，带时间、tab、级别。
    func plainText(_ list: [Entry]? = nil) -> String {
        let shown = list ?? entries
        guard !shown.isEmpty else { return "（这次打开以后还没有提示）" }
        return shown.map(Self.line).joined(separator: "\n\n")
    }

    static func line(_ entry: Entry) -> String {
        let times = entry.repeats > 1 ? "（连着 \(entry.repeats) 次）" : ""
        return "[\(DiagFormat.stamp.string(from: entry.date))] \(entry.source.rawValue) · \(entry.level.rawValue)\(times)\n\(entry.text)"
    }

    /// 文字进剪贴板（只在点了按钮时；无头没人点）。
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// 提示历史里的时间（不跟着系统地区变：DateFormatter 一律 en_US_POSIX）。
enum DiagFormat {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 状态栏那一行

/// 三个 tab 状态栏共用：收起时和以前一样是一行红字（截断，悬停看全文）+ 关闭按钮；点那一行弹出全文和最近的历史。
struct ErrorNotice: View {
    let text: String
    let source: ErrorHistory.Source
    /// 关闭按钮的颜色（批量页是 secondary，拼图 / 水印页是 tertiary，和以前一样）。
    var closeStyle: HierarchicalShapeStyle = .secondary
    var closeHelp: String = "关闭这条提示"
    let dismiss: () -> Void
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 4) {
            Button { showDetail.toggle() } label: {
                Text(text).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(text + "\n\n（点一下看全文、复制，还有最近的提示）")
            .popover(isPresented: $showDetail, arrowEdge: .top) {
                ErrorHistoryPanel(current: text, source: source)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(closeStyle)
            .help(closeHelp)
        }
    }
}

/// 点开状态栏提示的那一块：这一条的全文（可选中、复制）、权限类的给「打开系统设置」，下面最近 20 条（三个 tab 一起）。
struct ErrorHistoryPanel: View {
    let current: String?
    let source: ErrorHistory.Source
    @ObservedObject var history: ErrorHistory = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current {
                HStack {
                    Text("这条提示").font(.headline)
                    Spacer()
                    Button("复制") { ErrorHistory.copy(current) }
                        .help("把这条提示的全文放进剪贴板")
                }
                ScrollView {
                    Text(current)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 150)
                if Diagnostics.mentionsPrivacySettings(current) { PrivacySettingsButton() }
                Divider()
            }
            HStack {
                Text("最近的提示（\(history.entries.count) 条，三个页面一起，新的在上）")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("全部复制") { ErrorHistory.copy(history.plainText()) }
                    .disabled(history.entries.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if history.entries.isEmpty {
                        Text("还没有").font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(history.entries) { entry in
                        ErrorHistoryRow(entry: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 210)
        }
        .padding(14)
        .frame(width: 480)
    }
}

/// 「打开「隐私与安全性」设置」：系统设置 › 隐私与安全性 › 文件与文件夹（照片文件夹、存储卡读不了时）。
struct PrivacySettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("打开「隐私与安全性」设置") {
            guard !AppRuntime.headless else { return }
            openURL(Diagnostics.privacySettingsURL)
        }
        .help("系统设置 › 隐私与安全性 › 文件与文件夹：给「选片工具」打开对应的开关")
    }
}

private struct ErrorHistoryRow: View {
    let entry: ErrorHistory.Entry

    var body: some View {
        let times = entry.repeats > 1 ? " ×\(entry.repeats)" : ""
        let head = DiagFormat.time.string(from: entry.date) + " · " + entry.source.rawValue + times
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: entry.level == .error ? "exclamationmark.circle.fill" : "info.circle")
                .font(.caption)
                .foregroundStyle(entry.level == .error ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(head).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button { ErrorHistory.copy(ErrorHistory.line(entry)) } label: {
                Image(systemName: "doc.on.doc").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("复制这一条")
        }
    }
}
