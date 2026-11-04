import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 诊断（全项目审查 D03）
//
//   1. 逐张失败的原因翻成中文（导出 JPG、移到废纸篓、写 XMP、水印页）：在 CardImporter.describe 之前先认它不认的几种
//      —— 盘不支持废纸篓、只读盘、EPERM（文件被锁定或者系统隐私权限）—— 其余照旧交给它。
//   2. 照片文件夹被系统隐私权限（TCC）拒绝时的话：点名「系统设置 › 隐私与安全性 › 文件与文件夹 › 选片工具」里哪个开关。
//   3. 「帮助」菜单（快捷键一览、使用说明）。

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
    }
}
