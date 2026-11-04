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
        /// 那块盘挂在哪（/Volumes/photo）：拿不到卷 UUID 的盘（很多网络共享）靠它认 —— 共享断了以后 /Volumes/photo
        /// 可能留下一个系统盘上的空文件夹，路径还在，可已经不是那块盘了。
        var volumePath: String?
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
                           volumeName: values?.volumeLocalizedName ?? values?.volumeName,
                           volumePath: volumeMountPath(of: folder))
    }

    enum FolderState: Equatable {
        case ok(URL)
        case volumeOffline(name: String)
        case gone
    }

    /// 记住的文件夹现在在不在。先跟书签（改名 / 挪动过也找得到；不自动连网络盘、不弹框），再看路径；
    /// 找到的文件夹不在原来那块盘上（卷 UUID 对不上；没有卷 UUID 的，落到了系统盘上）不算，在废纸篓里也不算。
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
        // 拿不到卷 UUID 的盘（很多网络共享）只能靠挂载点认：记下的挂载点；以前的设置没记，路径在 /Volumes/<名字>/ 下就是
        // /Volumes/<名字>。
        let mount = saved.volumeUUID == nil ? expectedMountPath(saved) : nil
        // 在访达里「删掉」文件夹就是挪进废纸篓（同一块盘上的一次改名）：书签按文件身份跟过去，卷 UUID 也对得上 ——
        // 不挡的话照片会导进 ~/.Trash/… 或 /Volumes/T7/.Trashes/501/…，清倒废纸篓就没了（审查发现）。当成「不在了」。
        for url in candidates where directoryExists(url) && !isInTrash(url) {
            if let want = saved.volumeUUID,
               let actual = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString,
               actual != want { continue }
            // 没有卷 UUID、原来不在系统盘上的：找到的文件夹落在系统盘上就不算。共享断了，/Volumes/photo 可能留下一个
            // 系统盘上的空文件夹 —— 以前路径在就收下，照片就写进了系统盘（审查发现）。只挡这一种：共享重新挂成
            // /Volumes/photo-1、书签跟过去的照样收下（不在系统盘上）。
            if let mount, mount != "/", (volumeMountPath(of: url) ?? "/") == "/" { continue }
            return .ok(url.standardizedFileURL)
        }
        if let want = saved.volumeUUID {
            if !mountedVolumeUUIDs().contains(want) {
                return .volumeOffline(name: saved.volumeName ?? volumeNameInPath(saved.path) ?? "外接盘")
            }
            return .gone
        }
        if let mount, mount != "/", !mountedVolumePaths().contains(mount) {
            return .volumeOffline(name: saved.volumeName ?? URL(fileURLWithPath: mount).lastPathComponent)
        }
        if let name = offlineVolumeName(for: saved.path) { return .volumeOffline(name: name) }
        return .gone
    }

    /// 这次的目标。`dataDir`：看日期文件夹的名字是不是被挪走了的一场占着（dayFolder），测试给隔离的数据目录。
    static func target(settings: DestinationSettings, choice: DestinationChoice, now: Date = Date(),
                       dataDir: URL = appDataDir) -> Target {
        let day = dayFormatter.string(from: now)
        let sessions = dataDir.appendingPathComponent("sessions", isDirectory: true)
        switch choice {
        case .existing(let folder):
            let url = folder.standardizedFileURL
            let issue = directoryExists(url) ? writableIssue(url) : "「\(displayPath(url))」不在了（盘拔掉了，或者删了、挪走了）"
            return Target(destination: url, mustExist: url, appending: true, issue: issue)
        case .pictures:
            let pictures = defaultDestination(now: now).deletingLastPathComponent()
            return Target(destination: dayFolder(in: pictures, day: day, sessionsDir: sessions), mustExist: nil,
                          appending: false, issue: nil)
        case .saved:
            guard let root = settings.root else {
                let pictures = defaultDestination(now: now).deletingLastPathComponent()
                return Target(destination: dayFolder(in: pictures, day: day, sessionsDir: sessions), mustExist: nil,
                              appending: false, issue: nil)
            }
            let shown = displayPath(URL(fileURLWithPath: root.path))
            switch resolve(root) {
            case .ok(let url):
                return Target(destination: dayFolder(in: url, day: day, sessionsDir: sessions), mustExist: url,
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

    /// 导入那天的文件夹（`parent`/yyyyMMdd）；这个名字被一场挪走了的占着就换成 yyyyMMdd-2、-3……（审查）。
    /// 场次按照片文件夹路径的哈希认（BatchStore.sessionKey）：那一场在访达里改了名、挪走、重新定位到外接盘以后，key 还是
    /// 原路径的。原路径上再建一个同名文件夹导进去，导完自动打开时按原路径认成挪走的那一场（书签跟过去、红条叫人改名，新导的
    /// 照片没人分析）；书签解析不到时更会把新卡里同名的照片当成那一场的。换个名字，新卡就是干干净净的一场。
    /// 同一天接着导、那个文件夹还是那一场的（manifest 记的就是它）照旧导进去，追加到那一场。
    static func dayFolder(in parent: URL, day: String, sessionsDir: URL) -> URL {
        let first = parent.appendingPathComponent(day, isDirectory: true)
        guard nameTakenByMovedSession(first, sessionsDir: sessionsDir) else { return first }
        for n in 2...99 {
            let candidate = parent.appendingPathComponent("\(day)-\(n)", isDirectory: true)
            if !nameTakenByMovedSession(candidate, sessionsDir: sessionsDir) { return candidate }
        }
        return first
    }

    /// `folder` 这个路径的 key 下已经有一场（sessions/<key>/manifest.json 在），而 `folder` 不是它的照片文件夹：`folder` 不在
    /// （那一场改了名、挪走、删了），或者 manifest 记的照片文件夹是别处（按设备号 + inode 比；记的那个现在打不开也算别处）。
    /// 只读数据目录里的一个小 JSON、stat 两次。
    static func nameTakenByMovedSession(_ folder: URL, sessionsDir: URL) -> Bool {
        let manifest = sessionsDir.appendingPathComponent(BatchStore.sessionKey(for: folder), isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return false }
        guard let here = SessionLocation.identity(folder.path) else { return true }
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recorded = json["photo_dir"] as? String else { return false }
        return SessionLocation.identity(recorded) != here
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

    /// 这个位置所在的那块盘挂在哪（standardized 路径；系统盘上的是 /）。读不出来 = nil。
    static func volumeMountPath(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path
    }

    /// 记住的文件夹应该挂在哪：记下的挂载点；以前的设置没记，路径在 /Volumes/<名字>/ 下就当是 /Volumes/<名字>。
    private static func expectedMountPath(_ saved: SavedFolder) -> String? {
        saved.volumePath ?? volumeNameInPath(saved.path).map { "/Volumes/" + $0 }
    }

    /// 这个文件夹在哪块盘上：卷 UUID，拿不到（很多网络共享）就用挂载点。确认导入时记下（Plan.mustExistVolume），
    /// 真开始导时再比 —— 排着队的时候盘被拔了、共享断了，原路径上留下的同名空文件夹在系统盘上，路径还在，盘已经换了。
    static func volumeIdentity(of url: URL) -> String? {
        // 新建一个 URL 再读：resourceValues 缓存在 URL 对象上，确认时读过的那份会跟着计划一路带到开始导的时候（后台任务里
        // 没有 run loop 帮它清），读出来的就还是确认那一刻的盘。
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        let values = try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        if let uuid = values?.volumeUUIDString { return uuid }
        return values?.volume.map { "mount:" + $0.standardizedFileURL.path }
    }

    private static func mountedVolumePaths() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return Set(urls.map { $0.standardizedFileURL.path })
    }

    private static func mountedVolumeUUIDs() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey],
                                                         options: []) ?? []
        return Set(urls.compactMap { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString })
    }

    /// 在废纸篓里吗：路径里有 .Trash（家目录的废纸篓、iCloud 的）或 .Trashes（外接盘、网络盘的 .Trashes/<uid>）。
    /// 只看路径（不问 FileManager 的废纸篓位置：网络盘卡住时会跟着卡）。
    static func isInTrash(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return parts.contains(".Trash") || parts.contains(".Trashes")
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
