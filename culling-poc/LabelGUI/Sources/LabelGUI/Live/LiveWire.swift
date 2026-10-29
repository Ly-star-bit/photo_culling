import Foundation
import MachO

// MARK: - 实时桥的线上格式（DESIGN §9.2，app 和 --mcp 共用；原型 R6 的 Wire.swift）
//
// Unix domain socket，一行一条 JSON（UTF-8，不带 prettyPrinted，行内没有裸换行）。每次工具调用：
// connect → hello → 一个请求 → 断开（R6 实测 p50 0.12 ms，不留常驻连接）。
// 这里只有纯的编解码、按行读、sockaddr 和几个 fd 小工具；锁在 LiveLock（app）和 LiveClient.probeLockFile（--mcp），
// 服务端在 LiveServer，客户端在 MCP/LiveClient。

enum LiveWire {
    /// 协议版本：只在线上格式不兼容时加 1；新方法靠 hello 的 capabilities（§9.2.5、§10.4）。
    static let proto = 1
    static let protoMin = 1
    static let protoMax = 1
    /// app 一侧收请求，一行最多 1 MiB（R6 §3.3）。
    static let maxRequestLine = 1 << 20
    /// --mcp 一侧读回复，一行最多 8 MiB（§10.6 STEP 2）：预览按 §4.4 的预算一次合计 ≤600 KB，base64 以后约 800 KB，
    /// 8 MiB 是十倍的余量；再大就是 app 那边出了 bug，不能让它把 --mcp 的内存吃光。
    static let maxReplyLine = 8 << 20

    /// 编成一行（带结尾换行）。经 MCPJSON（§10.4：先 sanitize，NaN / inf 变 null；编不了不抛异常），
    /// 编不了的回复换成同一个 id 的 internal 错误 —— 在 app 里抛 ObjC 异常就是用户的 app 闪退。
    static func encode(_ object: [String: Any]) -> Data {
        var data = MCPJSON.data(object) ?? fallback(id: object["id"])
        data.append(0x0A)
        return data
    }

    private static func fallback(id: Any?) -> Data {
        let error: [String: Any] = ["code": "internal", "message": "回复里有编不成 JSON 的值"]
        var frame: [String: Any] = ["error": error]
        frame["id"] = id ?? NSNull()
        return MCPJSON.data(frame) ?? Data(#"{"error":{"code":"internal","message":"回复编不成 JSON"},"id":null}"#.utf8)
    }

    /// 解一行；不是 JSON 对象回 nil。
    static func decode(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line, options: [])) as? [String: Any]
    }

    /// 单调时钟，毫秒（deadline、超时都用它，不受改系统时间影响）。
    static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    static func errnoText(_ e: Int32 = errno) -> String { "\(e) \(String(cString: strerror(e)))" }

    /// JSON 里的整数（Bool 不算；JSONSerialization 把 true 也解成 NSNumber）。
    static func int(_ raw: Any?) -> Int? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 1e15 else { return nil }
        return Int(d)
    }
}

// MARK: - sockaddr_un

enum LiveSockAddr {
    /// sun_path 是 104 字节（含结尾的 0），路径最多 103 字节（MacOSX15.4.sdk sys/un.h:79）。
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// 路径超长回 nil，不截断（截断了就会连到 / 绑到别的路径上）。
    static func with<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes, !bytes.contains(0) else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}

// MARK: - fd 小工具

enum LiveFD {
    /// CLOEXEC（§9.2.4）：锁、监听 socket、每个连接都设。app 今天只用 Foundation Process（它自己不让子进程继承 fd），
    /// 以后谁换成不关 fd 的起子进程办法（Live/、MCP/ 里禁用，§9.2.4），没设的 fd 就会被子进程攥着：app 退了，MCP 还以为它开着（R6 §4.4）。
    @discardableResult
    static func setCloexec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    static func isCloexec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }

    /// SO_NOSIGPIPE；返回 setsockopt 的返回值（accept 之后对端已经走了时是 -1 / EINVAL，R6 §4.3）。
    @discardableResult
    static func setNoSigpipe(_ fd: Int32) -> Int32 {
        var one: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 读 SO_NOSIGPIPE（看监听 socket 上设的有没有继承到 accept 出来的连接上）；读不了回 -1。
    static func noSigpipe(_ fd: Int32) -> Int32 {
        var value: Int32 = -1
        var len = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &len) == 0 ? value : -1
    }

    /// 阻塞地把整段写完。`noSignal`：send(…, MSG_NOSIGNAL)，SIGPIPE 的第 3 层（只有 sigpipe 矩阵的测试宿主会关掉它）。
    /// 返回 false = 对端断了（EPIPE / ECONNRESET）或别的错误。
    static func sendAll(_ fd: Int32, _ data: Data, noSignal: Bool = true) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            let flags: Int32 = noSignal ? MSG_NOSIGNAL : 0
            while left > 0 {
                let n = send(fd, p, left, flags)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pfd, 1, 100)
                        continue
                    }
                    return false
                }
                p += n
                left -= n
            }
            return true
        }
    }
}

// MARK: - 按行读（带超时、带上限）

final class LiveLineReader {
    enum Result { case line(Data), eof, timeout, tooLong, error(Int32) }

    let fd: Int32
    let maxLine: Int
    private var buffer = Data()
    private var scanned = 0

    init(fd: Int32, maxLine: Int) {
        self.fd = fd
        self.maxLine = maxLine
    }

    /// timeoutMs < 0 = 一直等。`stop`：每 50 ms 看一眼，返回 true 就当超时（取消用）。
    func next(timeoutMs: Int, stop: (() -> Bool)? = nil) -> Result {
        let deadline = timeoutMs < 0 ? Double.infinity : LiveWire.nowMs() + Double(timeoutMs)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer[buffer.startIndex.advanced(by: scanned)...].firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[buffer.index(after: nl)...])
                scanned = 0
                return .line(line)
            }
            scanned = buffer.count
            if buffer.count > maxLine { return .tooLong }
            if let stop, stop() { return .timeout }
            let remain = deadline - LiveWire.nowMs()
            if remain <= 0 { return .timeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let cap = stop == nil ? 1_000_000.0 : 50.0
            let wait = remain.isInfinite ? (stop == nil ? -1 : 50) : Int32(max(1, min(remain, cap)))
            let pr = poll(&pfd, 1, wait)
            if pr < 0 {
                if errno == EINTR { continue }
                return .error(errno)
            }
            if pr == 0 { continue }  // 超时在循环顶上判断
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .error(errno)
            }
            if n == 0 { return .eof }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

// MARK: - 我是谁（hello 里交换）

/// 真实 app 里 version / build 来自 Info.plist；裸开发版二进制没有，填 "dev"。uuid 是主可执行文件的 LC_UUID：
/// 同一次构建两边相同，换一次构建就变（§9.2.2，exact_build_match 就比它）。
enum LiveBuildInfo {
    static let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    static let exe: String = Bundle.main.executablePath ?? CommandLine.arguments[0]

    static let uuid: String = {
        guard let header = _dyld_get_image_header(0) else { return "unknown" }
        return header.withMemoryRebound(to: mach_header_64.self, capacity: 1) { h64 -> String in
            var cmd = UnsafeRawPointer(h64).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<h64.pointee.ncmds {
                let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
                if lc.cmd == UInt32(LC_UUID) {
                    let u = cmd.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                    return UUID(uuid: u).uuidString
                }
                cmd = cmd.advanced(by: Int(lc.cmdsize))
            }
            return "unknown"
        }
    }()
}

/// 跨线程递一个不是 Sendable 的值（[String: Any] 之类）；用的地方保证同一时刻只有一边在碰它。
struct LiveBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - 客户端连接（--mcp 的 LiveClient 用；app 启动时也用它问一句「锁的主人是不是一个活着的 app」）

enum LiveConnect {
    enum Outcome: Equatable {
        case connected(Int32)
        /// connect 的 errno（ENOENT、ECONNREFUSED、EACCES……）；路径超长是 ENAMETOOLONG。
        case failed(Int32)
        case timeout
    }

    /// 非阻塞 connect + poll，总预算 timeoutMs。socket 一出来就 CLOEXEC + SO_NOSIGPIPE（§9.2.2 客户端那条）。
    /// 连上以后回到阻塞模式，读写超时都由 poll 控制。macOS 上积压满了是立即 ECONNREFUSED，不是 EAGAIN（§9.1 第二轮实测），
    /// 要不要重连由调用方按锁的状态决定（LiveClient），这里只连一次。
    static func connect(_ path: String, timeoutMs: Int) -> Outcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return .failed(errno) }
        LiveFD.setCloexec(fd)
        LiveFD.setNoSigpipe(fd)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        guard let rc = LiveSockAddr.with(path, { Darwin.connect(fd, $0, $1) }) else {
            close(fd)
            return .failed(ENAMETOOLONG)
        }
        var err: Int32 = rc == 0 ? 0 : errno
        if err == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, Int32(max(1, timeoutMs))) <= 0 {
                close(fd)
                return .timeout
            }
            var soerr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len)
            err = soerr
        }
        guard err == 0 else {
            close(fd)
            return .failed(err)
        }
        _ = fcntl(fd, F_SETFL, flags)
        return .connected(fd)
    }

    /// 对端 uid（getpeereid）；拿不到回 nil。
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// 发一行、等一行。发不出去也照样读一次：app 回 too_many_connections 是连上就写、写完就关，
    /// 这边的 hello 撞上已经关掉的连接会 EPIPE，但那一行错误还在接收缓冲区里。
    static func exchange(_ fd: Int32, _ frame: [String: Any], timeoutMs: Int, maxLine: Int) -> LiveLineReader.Result {
        let sent = LiveFD.sendAll(fd, LiveWire.encode(frame))
        let e = errno
        let reply = LiveLineReader(fd: fd, maxLine: maxLine).next(timeoutMs: sent ? timeoutMs : min(timeoutMs, 50))
        if case .line = reply { return reply }
        return sent ? reply : .error(e)
    }
}
