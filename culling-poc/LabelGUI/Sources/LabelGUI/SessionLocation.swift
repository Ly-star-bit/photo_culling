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

    /// manifest.json 改写了什么。
    struct ManifestRebase: Equatable {
        /// 原来记的拍摄文件夹（photo_dir）。
        let from: String
        /// 改了几行（raw_path / decode_path 任一改了算一行）。
        let rows: Int
    }

    /// 这一场的 manifest 记的拍摄文件夹（photo_dir）不是 `folder`（挪了、改了名，书签跟到了新位置）：raw_path、
    /// decode_path、photo_dir 按相对位置改到 `folder` 下。不改的话移废片、写 XMP、导出都还按旧路径走 —— 旧位置要是
    /// 又有了同名文件，就会去动它。preview_path 指的是场次目录（key 不变，目录也不变），不动。
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
        var rows = 0
        for i in photos.indices {
            var changed = false
            for key in ["raw_path", "decode_path"] {
                guard let path = photos[i][key] as? String, let moved = rebased(path, from: old, to: new) else { continue }
                photos[i][key] = moved
                changed = true
            }
            if changed { rows += 1 }
        }
        json["photo_dir"] = new
        json["photos"] = photos
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return (nil, true)
        }
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            SessionFiles.log.error("manifest.json 改不了路径：\(error.localizedDescription, privacy: .public)")
            return (nil, true)
        }
        return (ManifestRebase(from: old, rows: rows), false)
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
