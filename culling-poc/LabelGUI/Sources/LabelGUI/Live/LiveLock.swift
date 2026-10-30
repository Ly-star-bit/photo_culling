import Foundation

/// `<数据目录>/.live.lock`（DESIGN §9.2.1）：app 活着就一直持有 flock(LOCK_EX)，进程一死内核自动放掉。
/// 它是「app 在不在」的唯一判据；socket 文件不算（可能是崩溃留下的）。
/// 这个类只给 app 一侧用（GUI 和 --live-host，经 AppModel.make）：建锁文件、拿 LOCK_EX、写那一行说明、10 s 一次查 inode。
/// --mcp 绝不建它、绝不拿 LOCK_EX：只在 LiveClient.probeLockFile() 里 O_RDONLY 打开已有的、LOCK_SH 探一下就放（§9.2.1、§10.5）；
/// 两边共用的只有 `parseInfo`（纯函数）。
final class LiveLock {
    let path: String
    private(set) var fd: Int32
    private(set) var inode: UInt64

    private init(path: String, fd: Int32, inode: UInt64) {
        self.path = path
        self.fd = fd
        self.inode = inode
    }

    enum Acquire {
        case acquired(LiveLock)
        /// 别人持有 LOCK_EX（另一个 app 实例、正在启动的实例、v2 的无头写者）。
        case busy
        /// 打不开（没权限、路径被换成符号链接 → ELOOP……）：带原因。
        case failed(String)
    }

    /// open(L, O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW, 0600) + flock(LOCK_EX|LOCK_NB)。O_CLOEXEC 在 open 里一次设好，没有竞态窗口。
    static func tryAcquire(_ path: String) -> Acquire {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 { return .failed("open \(path)：\(LiveWire.errnoText())") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(fd)
            return e == EWOULDBLOCK ? .busy : .failed("flock：\(LiveWire.errnoText(e))")
        }
        var st = stat()
        fstat(fd, &st)
        return .acquired(LiveLock(path: path, fd: fd, inode: UInt64(st.st_ino)))
    }

    /// 锁文件里那一行（pwrite 再 ftruncate 到新长度，同一个 fd）：只给 --mcp 报错用（谁持有、桥开没开、版本），不是真相，
    /// 真相是 flock 本身。先截断再写的话，--mcp 正好在两步之间来读会读到空文件，把 bridge_off 报成 role 未知；
    /// 现在中间最多读到「新的一行 + 旧的尾巴」，parseInfo 只取第一行。
    func writeInfo(_ info: [String: Any]) {
        var data = MCPJSON.data(info) ?? Data("{}".utf8)
        data.append(0x0A)
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        _ = ftruncate(fd, off_t(data.count))
    }

    enum Check: Equatable {
        case ok
        /// 锁文件被删了 / 换了（用户清理过数据目录）：重新建好、重新拿到了，那一行也写回去了。
        case reacquired
        /// 重新建了，但锁被别的进程趁空当拿走（flock 回 EWOULDBLOCK）：桥要关掉（§9.2.4 第二轮补）。
        case lost(String)
        /// 重新 open 不了（数据目录被挪走 / 删掉 → ENOENT，锁路径被换成符号链接 → ELOOP，没权限……）：没有别的进程拿着锁，
        /// 旧 fd 上的 flock 也还在；不能说成「被别的程序拿走了」（§9.2.4 那一句只给上面那种）。带原因。
        case reopenFailed(String)
    }

    /// 10 s 自检里的锁那一半：fstat(fd).st_ino 和 lstat(L).st_ino 不同、或者 L 不在了 → 重新 open + flock，
    /// 成功就写回那一行、关掉旧 fd；别人拿着就是锁丢了；open 不了是另一回事（reopenFailed）。代价是一次 fstat 加一次 lstat。
    func selfCheck(info: [String: Any]) -> Check {
        var a = stat(), b = stat()
        let held = fstat(fd, &a) == 0
        let onDisk = lstat(path, &b) == 0
        if held && onDisk && a.st_ino == b.st_ino && a.st_dev == b.st_dev { return .ok }
        switch LiveLock.tryAcquire(path) {
        case .acquired(let fresh):
            close(fd)
            fd = fresh.fd
            inode = fresh.inode
            fresh.fd = -1
            writeInfo(info)
            return .reacquired
        case .busy:
            return .lost("锁文件被换过，新的锁被别的进程拿走了")
        case .failed(let why):
            return .reopenFailed(why)
        }
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// 锁文件内容的第一行（最多 4 KB）解成对象；解析不了回 nil（--mcp 当作 role 未知）。两边共用的纯函数。
    static func parseInfo(_ data: Data) -> [String: Any]? {
        let head = data.prefix(4096)
        let line = head.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first.map { Data($0) } ?? Data()
        return LiveWire.decode(line)
    }
}
