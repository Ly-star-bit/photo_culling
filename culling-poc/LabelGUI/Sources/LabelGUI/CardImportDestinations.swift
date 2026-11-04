import Foundation

// MARK: - 存储卡导入：导到哪（默认「图片 › yyyyMMdd」，可以改到外接盘）
//
// 内置盘 512GB / 1TB 的笔记本，一场婚礼 RAW+JPG 一两百 GB，几场就满 —— 导入根目录要能放到外接盘上。
// 规矩：
// · 根目录记在 appDataDir/card_import_settings.json：书签（文件夹改名 / 挪动了也跟得上）+ 路径 + 那块盘的
//   卷 UUID 和名字。
// · 照旧在根目录里按导入那天建 yyyyMMdd（不按 EXIF 拍摄日期分：婚宴过 0 点会切成两场）。
// · 也可以「这次导进一个已有的文件夹」（追加到已有场次，不记住）。
// · 外接盘没插上、文件夹没了：明说，绝不悄悄落回系统盘 —— /Volumes/T7 没挂上时那里可能是系统盘上一个
//   同名的空文件夹，卷 UUID 对不上就不算。
extension CardImporter {
    /// 记住的一个文件夹。
    struct SavedFolder: Codable, Equatable {
        var path: String
        var bookmark: Data?
        /// 那块盘的卷 UUID、名字（盘没插上时说得出是哪块；认得出 /Volumes 下同名的不是那块盘）。
        var volumeUUID: String?
        var volumeName: String?
    }

    /// appDataDir/card_import_settings.json（只有界面和测试的 --save-settings 写它）。
    struct DestinationSettings: Codable, Equatable {
        /// 导入根目录：在它里面按导入那天建 yyyyMMdd。nil = 「图片」。
        var root: SavedFolder?
        /// 第二份备份的根目录（在它里面建和导入位置同名的文件夹）；backupEnabled 关着就不备份（位置留着，再打开不用重选）。
        var backup: SavedFolder?
        var backupEnabled: Bool?

        var backupOn: Bool { backupEnabled == true && backup != nil }

        static let fileName = "card_import_settings.json"

        static func load(from dir: URL) -> DestinationSettings {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
                  let settings = try? JSONDecoder().decode(DestinationSettings.self, from: data) else {
                return DestinationSettings()
            }
            return settings
        }

        func save(to dir: URL) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(self) else { return }
            try? data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        }
    }

    /// 这次导到哪。
    enum DestinationChoice: Equatable {
        /// 按记住的根目录（没记 = 「图片」）建 yyyyMMdd。
        case saved
        /// 这次导进一个已有的文件夹（追加到已有场次，不建子文件夹、不记住）。
        case existing(URL)
        /// 记住的盘不在时用户点了「这次导到「图片」」。
        case pictures
    }

    struct Target: Equatable {
        let destination: URL
        /// 必须已经在的那一级（外接盘上的根目录 / 已有的文件夹）：导的时候不在了就停，绝不顺着建一串目录。
        /// nil = 「图片」那条老路（照旧连上级一起建）。
        let mustExist: URL?
        /// 导进已有文件夹（不建 yyyyMMdd）。
        let appending: Bool
        /// 说不通的原因（盘没插上、文件夹没了、写不进去）：有它就不导。
        let issue: String?
    }

    /// 用户选的文件夹记成什么（选的时候盘一定在）。
    static func savedFolder(for url: URL) -> SavedFolder {
        let folder = url.standardizedFileURL
        let bookmark = (try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        let values = try? folder.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeNameKey])
        return SavedFolder(path: folder.path, bookmark: bookmark, volumeUUID: values?.volumeUUIDString,
                           volumeName: values?.volumeLocalizedName ?? values?.volumeName)
    }

    enum FolderState: Equatable {
        case ok(URL)
        case volumeOffline(name: String)
        case gone
    }

    /// 记住的文件夹现在在不在。先跟书签（改名 / 挪动过也找得到；不自动连网络盘、不弹框），再看路径；
    /// 找到的文件夹不在原来那块盘上（卷 UUID 对不上）不算。
    static func resolve(_ saved: SavedFolder) -> FolderState {
        var candidates: [URL] = []
        if let bookmark = saved.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                candidates.append(url)
            }
        }
        candidates.append(URL(fileURLWithPath: saved.path))
        for url in candidates where directoryExists(url) {
            if let want = saved.volumeUUID,
               let actual = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString,
               actual != want { continue }
            return .ok(url.standardizedFileURL)
        }
        if let want = saved.volumeUUID {
            if !mountedVolumeUUIDs().contains(want) {
                return .volumeOffline(name: saved.volumeName ?? volumeNameInPath(saved.path) ?? "外接盘")
            }
            return .gone
        }
        if let name = offlineVolumeName(for: saved.path) { return .volumeOffline(name: name) }
        return .gone
    }

    /// 这次的目标。
    static func target(settings: DestinationSettings, choice: DestinationChoice, now: Date = Date()) -> Target {
        let day = dayFormatter.string(from: now)
        switch choice {
        case .existing(let folder):
            let url = folder.standardizedFileURL
            let issue = directoryExists(url) ? writableIssue(url) : "「\(displayPath(url))」不在了（盘拔掉了，或者删了、挪走了）"
            return Target(destination: url, mustExist: url, appending: true, issue: issue)
        case .pictures:
            return Target(destination: defaultDestination(now: now), mustExist: nil, appending: false, issue: nil)
        case .saved:
            guard let root = settings.root else {
                return Target(destination: defaultDestination(now: now), mustExist: nil, appending: false, issue: nil)
            }
            let shown = displayPath(URL(fileURLWithPath: root.path))
            switch resolve(root) {
            case .ok(let url):
                return Target(destination: url.appendingPathComponent(day, isDirectory: true), mustExist: url,
                              appending: false, issue: writableIssue(url))
            case .volumeOffline(let name):
                let url = URL(fileURLWithPath: root.path)
                return Target(destination: url.appendingPathComponent(day, isDirectory: true), mustExist: url,
                              appending: false, issue: "导入位置（\(shown)）在「\(name)」上，这块盘现在没插上 —— 插上它，或者换个位置")
            case .gone:
                let url = URL(fileURLWithPath: root.path)
                return Target(destination: url.appendingPathComponent(day, isDirectory: true), mustExist: url,
                              appending: false, issue: "导入位置（\(shown)）不在了（删了或挪走了）—— 换个位置")
            }
        }
    }

    /// 第二份备份写到哪：备份根目录里和导入位置同名的文件夹（20261104，或追加的那个已有文件夹的名字）。
    /// 没开备份 / 这次不备份 = nil。备份盘没插上、文件夹没了、写不进去、和导入位置是同一个地方：issue 说清楚，不导
    /// （开着备份的人以为有两份 —— 不能悄悄只导一份）。
    static func backupTarget(settings: DestinationSettings, primary: Target, skip: Bool = false) -> Target? {
        guard !skip, settings.backupOn, let saved = settings.backup else { return nil }
        let name = primary.destination.lastPathComponent
        let shown = displayPath(URL(fileURLWithPath: saved.path))
        switch resolve(saved) {
        case .ok(let root):
            let dest = root.appendingPathComponent(name, isDirectory: true)
            var issue = writableIssue(root).map { "备份位置" + $0 }
            let a = dest.resolvingSymlinksInPath().path
            let b = primary.destination.resolvingSymlinksInPath().path
            if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
                issue = "备份位置（\(shown)）和导入位置是同一个地方 —— 换一块盘上的文件夹"
            }
            return Target(destination: dest, mustExist: root, appending: false, issue: issue)
        case .volumeOffline(let volume):
            let root = URL(fileURLWithPath: saved.path)
            return Target(destination: root.appendingPathComponent(name, isDirectory: true), mustExist: root,
                          appending: false, issue: "备份位置（\(shown)）在「\(volume)」上，这块盘现在没插上 —— 插上它，或者这次不备份")
        case .gone:
            let root = URL(fileURLWithPath: saved.path)
            return Target(destination: root.appendingPathComponent(name, isDirectory: true), mustExist: root,
                          appending: false, issue: "备份位置（\(shown)）不在了（删了或挪走了）—— 换个备份位置，或者这次不备份")
        }
    }

    /// 写不进去（只读的盘、没权限）：开始前就说，别等复制时连着失败三个才停。
    private static func writableIssue(_ folder: URL) -> String? {
        FileManager.default.isWritableFile(atPath: folder.path) ? nil : "「\(displayPath(folder))」写不进去（只读的盘，或者没有权限）—— 换个位置"
    }

    /// 路径在 /Volumes/<名字>/… 下、而那块盘没挂上：返回名字（拿来分清「盘没插上」和「文件夹删了」）。
    static func offlineVolumeName(for path: String) -> String? {
        guard let name = volumeNameInPath(path) else { return nil }
        return directoryExists(URL(fileURLWithPath: "/Volumes").appendingPathComponent(name)) ? nil : name
    }

    private static func volumeNameInPath(_ path: String) -> String? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return parts[2]
    }

    private static func mountedVolumeUUIDs() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey],
                                                         options: []) ?? []
        return Set(urls.compactMap { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString })
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
