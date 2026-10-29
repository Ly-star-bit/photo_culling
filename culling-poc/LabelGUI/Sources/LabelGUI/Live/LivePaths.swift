import Foundation
import CryptoKit

/// 实时桥的路径（DESIGN §9.2.1，app 和 --mcp 共用这一份代码：两边算出的 socket 路径要逐字节相同）。
///
///     D       = realpath(3)(数据目录)        不用 Foundation 的 resolvingSymlinksInPath：它把 /private/tmp 写回 /tmp
///     D_id    = "<st_dev>:<st_ino>"          hello 里真正比的是它，路径字符串只给报错信息用
///     L       = D/.live.lock                 app 活着就一直持有 flock(LOCK_EX)，进程一死内核放掉：「app 在不在」的唯一判据
///     SockDir = confstr(_CS_DARWIN_USER_TEMP_DIR) + "xuanpian-live"     本用户 0700；不看 $TMPDIR，不用 /tmp
///     S       = SockDir/<SHA-256(D) 的前 16 个十六进制字符>.sock         本机 84 字节，sun_path 上限 103
///
/// realpath(3) 把 /tmp 软链接、大小写、NFC / NFD 三种拼法都归成磁盘上的那一份（§9.2.1 第二轮实测），所以只要两边都经这里，
/// 哈希就一样；测试脚本不自己算 S（Python 的 os.path.realpath 不改大小写、不做归一化），用宿主 ready 行里的那个。
/// 这里只算，不建任何东西：SockDir 由 app 在开桥时建（LiveServer），--mcp 绝不建（§5 第 7 层）。
struct LivePaths {
    let dataDir: String
    let dataDirID: String
    let lockPath: String
    let sockDir: String
    let socketPath: String

    /// S 超过 sun_path 的 103 字节：app 不开桥，--mcp 不 connect、直接探锁（warning socket_path_too_long）。
    /// 真实的 SockDir 固定 49 + 14 字节，只有测试用的 LABELGUI_LIVE_SOCK_ROOT 能把它撑长。
    var socketTooLong: Bool { socketPath.utf8.count > LiveSockAddr.maxPathBytes }

    enum Problem: Error, Equatable {
        /// 数据目录 realpath / stat 不了（不存在、没权限）：带 errno。
        case dataDir(Int32)
        /// confstr(_CS_DARWIN_USER_TEMP_DIR) 拿不到（不该发生）。
        case noTempDir
    }

    static let socketDirName = "xuanpian-live"
    static let lockName = ".live.lock"

    /// `sockRoot`：nil = 真实的 SockDir；测试宿主和设了 LABELGUI_DATA_DIR 的 --mcp 才会给（`clientSockRoot`）。
    static func resolve(dataDir raw: String, sockRoot: String?) -> Result<LivePaths, Problem> {
        guard let d = realpath(raw) else { return .failure(.dataDir(errno)) }
        var st = stat()
        guard stat(d, &st) == 0 else { return .failure(.dataDir(errno)) }
        let dir: String
        if let sockRoot, !sockRoot.isEmpty {
            dir = sockRoot.count > 1 && sockRoot.hasSuffix("/") ? String(sockRoot.dropLast()) : sockRoot
        } else {
            guard let real = realSockDir else { return .failure(.noTempDir) }
            dir = real
        }
        return .success(LivePaths(dataDir: d, dataDirID: "\(st.st_dev):\(st.st_ino)",
                                  lockPath: d + "/" + lockName, sockDir: dir,
                                  socketPath: dir + "/" + hash16(d) + ".sock"))
    }

    /// realpath(3)：失败回 nil（errno 留着给调用方看）。
    static func realpath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// confstr(_CS_DARWIN_USER_TEMP_DIR)：/var/folders/<2>/<28>/T/，按用户 UUID 算，和用户名、$TMPDIR 都无关。
    static func darwinUserTempDir() -> String? {
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard n > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: n)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, n) > 0 else { return nil }
        return String(cString: buf)
    }

    /// 真实的 SockDir（不带结尾的 /）。
    static var realSockDir: String? {
        guard let t = darwinUserTempDir() else { return nil }
        return (t.hasSuffix("/") ? t : t + "/") + socketDirName
    }

    static func hash16(_ dataDir: String) -> String {
        SHA256.hash(data: Data(dataDir.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// --mcp 用哪个 socket 根目录：只有设了 LABELGUI_DATA_DIR 才认 LABELGUI_LIVE_SOCK_ROOT（测试一定两个都设；
    /// 用户的 MCP 配置里两个都不设，就是真实的 SockDir）。GUI 不认它（§9.2.1）。
    static func clientSockRoot(_ env: [String: String]) -> String? {
        guard !(env["LABELGUI_DATA_DIR"] ?? "").isEmpty, let root = env["LABELGUI_LIVE_SOCK_ROOT"], !root.isEmpty else { return nil }
        return root
    }

    /// `root` 是不是真实的 SockDir（或者它里面）：测试宿主拿这个拒绝在用户的 socket 目录里 bind。
    /// 两边都按「最长的存在的那一段 realpath + 剩下的原样接上」算（真实的 SockDir 可能还不存在），
    /// 再 NFC、不分大小写比（APFS 默认不分）。
    static func isRealSockDir(_ root: String) -> Bool {
        guard let real = realSockDir else { return false }
        let r = loosely(root)
        let target = loosely(real)
        return r == target || r.hasPrefix(target + "/")
    }

    private static func loosely(_ path: String) -> String {
        var head = path
        var tail: [String] = []
        while head.count > 1 && head.hasSuffix("/") { head.removeLast() }
        var resolved = realpath(head)
        while resolved == nil, head.count > 1 {
            let ns = head as NSString
            tail.insert(ns.lastPathComponent, at: 0)
            head = ns.deletingLastPathComponent
            resolved = realpath(head)
        }
        let joined = ([resolved ?? head] + tail).joined(separator: "/")
        return joined.replacingOccurrences(of: "//", with: "/").precomposedStringWithCanonicalMapping.lowercased()
    }
}
