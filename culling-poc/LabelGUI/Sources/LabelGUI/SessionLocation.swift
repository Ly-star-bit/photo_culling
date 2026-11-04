import Foundation
import Darwin

// MARK: - 挪了的文件夹认得回来（全项目审查 S04 第一步）
//
// 场次目录名是照片文件夹路径的哈希（BatchStore.sessionKey）。文件夹在同一个卷里改了名、挪了位置，或者卷名从「T7」
// 变成「T7 1」以后，从「选择文件夹…」或拖进来打开新路径就是一个新的空场次 —— 判决、拼图都还在 sessions/<旧key>/ 里，
// 却接不上。BatchStore.switchSession 认回旧场次、改写照片路径要用的纯函数放这里。跨卷拷贝的指纹匹配（第二步）不在这里。

enum SessionLocation {
    /// 一个文件 / 文件夹是谁：设备号 + inode（stat 跟着符号链接走）。/private 前缀、大小写、NFC / NFD 写法不同都认得出是同一个。
    static func identity(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }

    /// 解一个书签：不弹框、不去挂载没挂上的卷（主线程上调）。
    static func resolveQuietly(_ bookmark: Data) -> URL? {
        var stale = false
        let quiet: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        return (try? URL(resolvingBookmarkData: bookmark, options: quiet.union(.withSecurityScope),
                         relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: quiet, relativeTo: nil, bookmarkDataIsStale: &stale))
    }

    /// 书签里记着的卷 UUID：只读书签本身，不碰文件系统（没挂上的网络盘也不会等）。
    static func bookmarkVolumeUUID(_ bookmark: Data) -> String? {
        URL.resourceValues(forKeys: [.volumeUUIDStringKey], fromBookmarkData: bookmark)?.volumeUUIDString
    }

    static func volumeUUID(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// 旧根下面的路径换到新根下：/旧/a/b.jpg → /新/a/b.jpg。按整段比（/旧2/… 不算 /旧 下面的）；不在旧根下面的 nil。
    static func rebased(_ path: String, from oldRoot: String, to newRoot: String) -> String? {
        let old = oldRoot.count > 1 && oldRoot.hasSuffix("/") ? String(oldRoot.dropLast()) : oldRoot
        let new = newRoot.count > 1 && newRoot.hasSuffix("/") ? String(newRoot.dropLast()) : newRoot
        guard path.hasPrefix(old + "/") else { return nil }
        return new + path.dropFirst(old.count)
    }

    /// 路径里最深的、还在的那一级解析过符号链接，再接上后面已经不在的几段：/Users/x/Pictures/NAS/0321（0321 改了名、
    /// NAS → /Volumes/T7/Photos）→ /Volumes/T7/Photos/0321。resolvingSymlinksInPath 对不存在的路径原样返回 ——
    /// 符号链接底下的拍摄文件夹改了名以后，photo_dir（给的写法）和枚举器给的照片路径（真实路径）就对不上了。
    /// 整条都在的照常解析；一级都不在的 nil。
    static func resolvedThroughExistingParent(_ path: String) -> String? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while !fm.fileExists(atPath: url.path) {
            guard url.pathComponents.count > 1 else { return nil }
            tail.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        var out = url.resolvingSymlinksInPath()
        for part in tail { out.appendPathComponent(part) }
        return out.path
    }

    /// 相对拍摄根目录算路径用：原样的写法、/private 折叠（PathRelativizer 自己做），再加上解析过符号链接的写法
    /// （根已经不在了也解析得到它还在的上一级）。
    static func relativizer(forRoot root: String) -> ImageLoader.PathRelativizer {
        var roots = [root]
        if let resolved = resolvedThroughExistingParent(root), resolved != root { roots.append(resolved) }
        return ImageLoader.PathRelativizer(roots: roots)
    }

    /// manifest.json 改写了什么。
    struct ManifestRebase: Equatable {
        /// 原来记的拍摄文件夹（photo_dir）。
        let from: String
        /// 改了几行（raw_path / decode_path 任一改了算一行）。
        let rows: Int
        /// 有路径、却一条都换不过去的行（不在原来记的拍摄文件夹下面，换了写法也认不出来）。
        var unmatched = 0
        /// 一行都没换过去：manifest 原样没动（photo_dir 也没改，下次打开再试）。不能说「已改到现在的位置」。
        var untouched: Bool { rows == 0 && unmatched > 0 }
    }

    /// 这一场的 manifest 记的拍摄文件夹（photo_dir）不是 `folder`（挪了、改了名，书签跟到了新位置）：raw_path、
    /// decode_path、photo_dir 按相对位置改到 `folder` 下。不改的话移废片、写 XMP、导出都还按旧路径走 —— 旧位置要是
    /// 又有了同名文件，就会去动它。preview_path 指的是场次目录（key 不变，目录也不变），不动。
    /// 照片路径按各级比、不按字符串前缀（PathRelativizer：/var 和 /private/var、拍摄文件夹在符号链接底下时 photo_dir
    /// 和照片路径写法不一样）。一行都换不过去的（rows == 0、unmatched > 0）整份不写，photo_dir 也不改 —— 不然下次打开
    /// photo_dir 已经是新位置，再也不会去改那些照片路径。
    /// 同一个文件夹换了写法（/tmp 和 /private/tmp、符号链接）、`folder` 不存在、没有 photo_dir 的不改，返回 nil。
    /// 写的方式和分析引擎一样（JSONSerialization、prettyPrinted + sortedKeys、atomic）。`failed` = 要改但写不进去。
    static func rebaseManifest(in sessionDir: URL, to folder: URL) -> (rebase: ManifestRebase?, failed: Bool) {
        let url = sessionDir.appendingPathComponent("manifest.json")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
              let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let old = json["photo_dir"] as? String,
              var photos = json["photos"] as? [[String: Any]] else { return (nil, false) }
        let new = folder.path
        guard old != new else { return (nil, false) }
        if let a = identity(old), let b = identity(new), a == b { return (nil, false) }
        let relativizer = relativizer(forRoot: old)
        func moved(_ path: String) -> String? {
            let rel = relativizer.relative(path)
                ?? resolvedThroughExistingParent(path).flatMap { relativizer.relative($0) }
            if let rel, !rel.isEmpty { return (new as NSString).appendingPathComponent(rel) }
            return rebased(path, from: old, to: new)
        }
        var rows = 0
        var unmatched = 0
        func rebaseRows(_ list: inout [[String: Any]]) {
            for i in list.indices {
                var changed = false
                var hasPath = false
                for key in ["raw_path", "decode_path"] {
                    guard let path = list[i][key] as? String else { continue }
                    hasPath = true
                    guard let target = moved(path) else { continue }
                    list[i][key] = target
                    changed = true
                }
                if changed {
                    rows += 1
                } else if hasPath {
                    unmatched += 1
                }
            }
        }
        rebaseRows(&photos)
        // 这一次没分析成、只记了 id 的那一份（PhotoIDMemory.swift 的 idOnlyKey：取消时没轮到的、解码失败的）也换：
        // 下次分析 PreviousIDs 按 photo_dir 和现在的根目录算相对路径，旧位置的绝对路径对不上，沿用下来的 id 又会变。
        var idOnly = json[ImageLoader.PreviousIDs.idOnlyKey] as? [[String: Any]]
        if idOnly != nil { rebaseRows(&idOnly!) }
        if rows == 0 && unmatched > 0 {
            SessionFiles.log.error("manifest.json 的照片路径一条都对不上原来的 photo_dir（\(old, privacy: .public)），没改")
            return (ManifestRebase(from: old, rows: 0, unmatched: unmatched), false)
        }
        json["photo_dir"] = new
        json["photos"] = photos
        if let idOnly { json[ImageLoader.PreviousIDs.idOnlyKey] = idOnly }
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return (nil, true)
        }
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            SessionFiles.log.error("manifest.json 改不了路径：\(error.localizedDescription, privacy: .public)")
            return (nil, true)
        }
        return (ManifestRebase(from: old, rows: rows, unmatched: unmatched), false)
    }

    /// 「重新定位文件夹…」之前的检查：这一场的照片（按 photo_dir 下的相对位置；没有 photo_dir 的按文件名）在 `folder`
    /// 里至少找得到一张。找到一张就停，最多看 `limit` 张。nil = manifest 读不出来（说不清）。
    static func anyPhotoPresent(sessionDir: URL, under folder: URL, limit: Int = 300) -> Bool? {
        guard let data = try? Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = json["photos"] as? [[String: Any]] else { return nil }
        let old = json["photo_dir"] as? String
        let fm = FileManager.default
        for photo in photos.prefix(limit) {
            guard let raw = photo["raw_path"] as? String else { continue }
            let candidate = old.flatMap { rebased(raw, from: $0, to: folder.path) }
                ?? folder.appendingPathComponent((raw as NSString).lastPathComponent).path
            if fm.fileExists(atPath: candidate) { return true }
        }
        return false
    }
}

// MARK: - 存储卡当一场打开（全项目审查 S07）
//
// 关了插卡弹框、直接打开 /Volumes/<卡>/DCIM 当一场时，分析和审片不碰卡（都写在数据目录），但移废片（进的是卡自己的
// .Trashes，格式化就没了）、写 XMP（正式导卡时 .xmp 当成相机的配套文件不导）、高 ISO 复制、导出 JPG / 精华 / 拼图的
// 默认目录都会写卡。BatchStore 按这里的判断挡住它们，横幅叫人先导入。
//
// 不调 cardVolume：它读卷根（第一次访问可移除宗卷会弹系统授权框；没授权还返回 nil，闸就悄悄失效），而 switchSession
// 在主线程上。这里只对照片文件夹本身取卷属性（用户已经通过面板 / 书签打开过它），而且一定要有 DCIM 这个条件 ——
// 只看「可推出」会把放在外置 SSD 上的正常工作盘也挡掉。

/// 照片文件夹所在的卷的几样属性（对文件夹本身取，不读卷根）。nil 的那几样 = 读不出来。
struct CardVolumeFacts: Equatable {
    var removable: Bool?
    var ejectable: Bool?
    var rootFileSystem: Bool?
    var local: Bool?
    /// 卷的挂载点（/Volumes/EOS_DIGITAL）。
    var volumePath: String?
    var name: String?
}

/// 这一场是不是开在存储卡上。
struct CardSessionCheck: Equatable {
    enum Kind: Equatable {
        case no
        case card
        /// 路径里有 DCIM、卷属性却读不全：按「可能是卡」挡（宁可多说一句，也别往卡上写）。
        case maybe
    }
    var kind: Kind
    /// 卡的名字（EOS_DIGITAL）；说不清时 nil。
    var name: String?
    /// 卡的挂载点：判断导出目标在不在卡上用；说不清时 nil（那时按和照片文件夹是不是同一个设备判断）。
    var root: String?

    static let no = CardSessionCheck(kind: .no)
    var blocksWrites: Bool { kind != .no }

    /// 给人看的叫法：「存储卡「EOS_DIGITAL」」/「存储卡」。
    var label: String {
        guard kind == .card, let name else { return "存储卡" }
        return "存储卡「\(name)」"
    }

    /// 说这一场：「这是存储卡「EOS_DIGITAL」上的文件夹」/「这个文件夹像是在存储卡上（…）」。
    var subject: String {
        switch kind {
        case .no: return ""
        case .card: return "这是\(label)上的文件夹"
        case .maybe: return "这个文件夹像是在存储卡上（路径里有 DCIM，读不出所在的盘是不是可移除的）"
        }
    }

    /// `url`（导出目标，还不存在就看它存在的那一级）在不在这张卡上。
    /// `photoDir`：不知道卡的挂载点时，和照片文件夹在同一个设备上就算在卡上。
    func contains(_ url: URL, photoDir: URL?) -> Bool {
        guard blocksWrites else { return false }
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        if let root {
            func inside(_ path: String, _ top: String) -> Bool {
                path == top || path.hasPrefix(top.hasSuffix("/") ? top : top + "/")
            }
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            if inside(url.standardizedFileURL.path, rootURL.path) { return true }
            // 经过符号链接指到卡上的：按它存在的那一级的真实路径再看一次。
            return inside(probe.resolvingSymlinksInPath().path, rootURL.resolvingSymlinksInPath().path)
        }
        guard let photoDir else { return true }
        var a = stat(), b = stat()
        guard stat(probe.path, &a) == 0, stat(photoDir.path, &b) == 0 else { return true }
        return a.st_dev == b.st_dev
    }
}

extension CardImporter {
    /// 测试用：给照片文件夹编卷属性（--session-move-selftest 不挂真的卡：hdiutil 挂的映像会弹「可移除的宗卷」授权框）。
    /// 返回 nil = 照常去读。
    nonisolated(unsafe) static var volumeFactsOverride: ((URL) -> CardVolumeFacts?)?

    /// 对文件夹本身取卷属性。整个取不出来 = nil。
    static func volumeFacts(of url: URL) -> CardVolumeFacts? {
        let keys: Set<URLResourceKey> = [
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey,
            .volumeURLKey, .volumeLocalizedNameKey, .volumeNameKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return CardVolumeFacts(removable: v.volumeIsRemovable, ejectable: v.volumeIsEjectable,
                               rootFileSystem: v.volumeIsRootFileSystem, local: v.volumeIsLocal,
                               volumePath: v.volume?.path, name: v.volumeLocalizedName ?? v.volumeName)
    }

    static func isDCIM(_ component: String) -> Bool { component.caseInsensitiveCompare("DCIM") == .orderedSame }

    /// 判断表（纯函数，--session-move-selftest 逐条验）。`hasDCIMChild` = 这个文件夹下面直接有 DCIM（打开的是卡的根）。
    /// 路径里没有 DCIM、下面也没有的，不看卷属性直接「不是」。有的话：系统盘 / 网络卷不是；可移除或可推出、而且 DCIM
    /// 就在卷的根下面（相机就是这样写卡的）才是 —— 外置 SSD 上某个备份文件夹里的 DCIM 不算；读不出来的按「可能是」。
    static func classifyCardSession(path: String, hasDCIMChild: Bool, facts: CardVolumeFacts?) -> CardSessionCheck {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.contains(where: isDCIM) || hasDCIMChild else { return .no }
        let maybe = CardSessionCheck(kind: .maybe, name: facts?.name, root: facts?.volumePath)
        guard let facts, let rootFS = facts.rootFileSystem else { return maybe }
        if rootFS || facts.local == false { return .no }
        if facts.removable == nil && facts.ejectable == nil { return maybe }
        guard facts.removable == true || facts.ejectable == true else { return .no }
        guard let volumePath = facts.volumePath else { return maybe }
        let volume = URL(fileURLWithPath: volumePath).standardizedFileURL.pathComponents
        guard components.starts(with: volume) else { return maybe }
        let inside = components.dropFirst(volume.count)
        let atRoot: Bool = inside.first.map(isDCIM) ?? hasDCIMChild
        guard atRoot else { return .no }
        let name = facts.name ?? (volumePath as NSString).lastPathComponent
        return CardSessionCheck(kind: .card, name: name, root: volumePath)
    }

    /// switchSession 用（主线程）：绝大多数场次（路径里没有 DCIM、下面也没有 DCIM 文件夹）只多一次 stat，不读卷属性。
    static func cardSession(for folder: URL) -> CardSessionCheck {
        var isDir: ObjCBool = false
        let child = FileManager.default.fileExists(atPath: folder.appendingPathComponent("DCIM").path, isDirectory: &isDir)
            && isDir.boolValue
        let path = folder.standardizedFileURL.path
        guard child || URL(fileURLWithPath: path).pathComponents.contains(where: isDCIM) else { return .no }
        let facts = volumeFactsOverride?(folder) ?? volumeFacts(of: folder)
        return classifyCardSession(path: path, hasDCIMChild: child, facts: facts)
    }
}
