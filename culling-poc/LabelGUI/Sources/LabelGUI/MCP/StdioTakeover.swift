import Foundation

/// --mcp / --mcp-call / --mcp-tools 的 stdio 接管：main.swift 的第一条可执行语句（DESIGN §2.2，R3 §4 实测过）。
/// 协议改走两个私有 fd（CLOEXEC）；fd 1 改指 stderr，之后 print、NSLog、FileHandle.standardOutput、C 的 stdio
/// 写的东西全落到 stderr，不会混进 JSON-RPC；fd 0 换成 /dev/null，谁也读不走客户端发来的消息。
enum StdioTakeover {
    struct FDs {
        let input: Int32
        let output: Int32
    }

    static func takeOver() -> FDs {
        fflush(stdout)
        let output = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3)
        let input = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
        guard output >= 0, input >= 0 else {
            // stdin / stdout 起来就是关着的：没有协议通道，没法当 MCP 服务器。
            fail("stdin/stdout 不可用", errno)
        }
        // fd 2 起来就是关着的（`2>&-`）：先拿 /dev/null 占住 2（0、1 都开着，open 拿到的就是 2）。不占的话下面换 fd 0
        // 用的 /dev/null 会落在 2 上、换完又关掉，dup2(2, 1) 跟着失败，fd 1 还是协议管道，print 直接写进 JSON-RPC。
        if fcntl(STDERR_FILENO, F_GETFD) == -1 {
            let devNull = open("/dev/null", O_WRONLY)
            if devNull > STDERR_FILENO {
                dup2(devNull, STDERR_FILENO)
                close(devNull)
            }
        }
        let devNull = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard devNull >= 0 else { fail("打不开 /dev/null", errno) }
        // dup2 出来的 fd 0 不带 CLOEXEC，和平常一样
        guard dup2(devNull, STDIN_FILENO) == STDIN_FILENO else { fail("fd 0 换不成 /dev/null", errno) }
        close(devNull)
        // 换不过去 fd 1 就还是协议管道：之后任何 print 都会混进 JSON-RPC，宁可不当服务器。这时候还什么都没打印过。
        guard dup2(STDERR_FILENO, STDOUT_FILENO) == STDOUT_FILENO else { fail("fd 1 改指不到 stderr", errno) }
        signal(SIGPIPE, SIG_IGN)  // 客户端走了：write 回 EPIPE，由写的那一侧退出，不被信号直接杀掉
        setvbuf(stdout, nil, _IOLBF, 0)
        return FDs(input: input, output: output)
    }

    private static func fail(_ why: String, _ code: Int32) -> Never {
        MCPLog.stderr("xuanpian mcp: \(why)（errno \(code)），退出\n")
        exit(2)
    }

    /// 继承来的 fd 可能带着 O_NONBLOCK（那是客户端那一端共享的文件状态，我们不去改它）：read / write 回 EAGAIN 时
    /// 在这里等到能读 / 能写，不能当成 EOF 或者客户端走了。对方真关了，poll 回 POLLHUP，下一次 read / write 自己会报。
    static func waitReady(_ fd: Int32, events: Int32) {
        var p = pollfd(fd: fd, events: Int16(events), revents: 0)
        _ = poll(&p, 1, -1)
    }
}

/// MCP 这一侧写日志的唯一出口（mcp_smoke 的 grep 不许 MCP/ 里再出现 FileHandle 的 standardError 写法）：
/// SIGPIPE 忽略以后，客户端关了 stderr 的读端（它不要日志），FileHandle 的 write(_:) 会抛 ObjC 异常、整个进程 abort ——
/// 还没回 initialize 就死了。这里写不出去就算了，日志丢了不影响协议。
enum MCPLog {
    static func stderr(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(STDERR_FILENO, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                off += n
            }
        }
    }
}
