import Foundation

/// 手写的 MCP stdio 服务端（只用 Foundation；原型是 R3 的 MCPStdio.swift，为什么不用 SDK 见 DESIGN §1.1）：
/// 一行一条 JSON-RPC 2.0，UTF-8，不带 .prettyPrinted，所以帧里不会有裸换行。
/// - 读：一个线程阻塞 read(2)，按行切；tools/call 先登记 inflight 再派发，取消不会比请求先到（SDK #285 那种竞态）。
/// - 写：一条串行队列，对私有输出 fd 阻塞地写整行（不设 O_NONBLOCK），帧不会交错（R3 压测：SDK 在并发大响应下 0 帧完整，
///   这一版 0 损坏）。读线程只往队列里放、不等写完：客户端暂时不读 stdout 时，排队的帧不到 256 个就照样收得到取消；
///   排满了读线程停下等空位（内存不无限长），这时候每 50 ms 看一眼 stdin 关了没有，关了就退出（§10.2 的 EOF 退出不落空）。
/// - 在途：一个 tools/call 从登记到它那一帧写出去（或因取消丢掉）都算在途，最多 8 个，第 9 个回 busy（§10.2）。
/// - v1 只说 legacy（initialize 握手，§1.2）。modern（2026-07-28：每个请求 _meta 带版本、server/discover）的分支
///   留到 v2，用 modernEnabled 关着；不能用「把 modern 版本列表置空」来关，那样回的是 -32022，dual-era 客户端就不回落了。
final class MCPStdioServer: @unchecked Sendable {
    typealias JSON = [String: Any]

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    struct ToolResult {
        var content: [JSON]
        var isError = false

        /// 一个 text 块，内容是 `object` 的紧凑 JSON（§3.0）。
        static func json(_ object: JSON) -> ToolResult {
            ToolResult(content: [["type": "text", "text": MCPJSON.string(object)]])
        }

        /// 业务错误（§4.5）：isError + `{"error":{"code","message","hint","data"}}`。
        static func error(_ code: String, _ message: String, hint: String? = nil, data: JSON? = nil) -> ToolResult {
            var e: JSON = ["code": code, "message": message]
            if let hint { e["hint"] = hint }
            if let data { e["data"] = data }
            return ToolResult(content: [["type": "text", "text": MCPJSON.string(["error": e])]], isError: true)
        }
    }

    /// 握手时客户端报的名字、版本，和协商出来的协议版本（app_status.client、server.protocol 用）。
    struct ClientInfo {
        var name: String
        var version: String
        var requested: String
        var answered: String
    }

    /// 一次 tools/call：参数、取消旗子、握手信息（--mcp-call 没有握手，client 是 nil）。
    final class Call: @unchecked Sendable {
        let arguments: JSON
        let cancel: CancelFlag
        let client: ClientInfo?
        init(arguments: JSON, cancel: CancelFlag = CancelFlag(), client: ClientInfo? = nil) {
            self.arguments = arguments
            self.cancel = cancel
            self.client = client
        }
    }

    struct Tool {
        let name: String
        /// tools/list 里的那一条（MCPToolDefs 生成）。
        let definition: JSON
        let handler: (Call) -> ToolResult
    }

    static let legacyVersions = ["2025-11-25", "2025-06-18"]
    static let modernVersions = ["2026-07-28"]
    static let modernEnabled = false
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaClientCaps = "io.modelcontextprotocol/clientCapabilities"
    /// 同时在途的 tools/call 上限（§10.2）。
    static let maxInflight = 8
    /// 一行请求的上限：客户端发来的都是小 JSON，没有换行的超长输入不能把内存吃光。
    static let maxLineBytes = 4 << 20

    let name: String
    let title: String
    let version: String
    let instructions: String
    private let tools: [Tool]
    private let toolIndex: [String: Int]
    private let input: Int32
    private let output: Int32
    // 每个块各自一个自动释放池：常驻进程里 JSONSerialization 之类的临时对象不攒着（mcp_smoke 第 7 组看 RSS）。
    private let writeQueue = DispatchQueue(label: "xuanpian.mcp.write", autoreleaseFrequency: .workItem)
    private let workQueue = DispatchQueue(label: "xuanpian.mcp.work", attributes: .concurrent, autoreleaseFrequency: .workItem)
    private let signalQueue = DispatchQueue(label: "xuanpian.mcp.signal")
    /// 排队待写的帧最多这么多个：客户端一直不读 stdout 时，读线程到这里停下，内存不会无限长。
    private let writeSlots = DispatchSemaphore(value: 256)
    private let lock = NSLock()
    private var inflight: [String: CancelFlag] = [:]
    private var clientInfo: ClientInfo?
    private var signalSources: [DispatchSourceSignal] = []
    private static let exitLock = NSLock()
    private static var exiting = false

    init(name: String, title: String, version: String, instructions: String, tools: [Tool], input: Int32, output: Int32) {
        self.name = name
        self.title = title
        self.version = version
        self.instructions = instructions
        self.tools = tools
        var index: [String: Int] = [:]
        for (i, tool) in tools.enumerated() { index[tool.name] = i }
        self.toolIndex = index
        self.input = input
        self.output = output
    }

    /// 接上 SIGINT / SIGTERM，起读线程，主线程交给 dispatchMain()。永不返回：stdin EOF 或收到信号时 0.5 s 内 exit(0)。
    func run() -> Never {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)  // 交给 DispatchSource 接，不让默认处置直接杀进程
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler { [self] in terminate(drain: true) }
            source.resume()
            signalSources.append(source)
        }
        let reader = Thread { [self] in
            readLoop()
            terminate(drain: true)  // EOF：客户端关了 stdin，尽快退出（正在跑的请求一并放弃）
        }
        reader.stackSize = 1 << 20
        reader.start()
        dispatchMain()
    }

    /// 退出（§2.5、§10.2）：最多花 0.3 s 等在途的调用回完、把已经排队的帧写完，然后 exit(0)；另有一个 0.4 s 的
    /// _exit 兜底 —— 写被堵在满了的管道上、或者 exit 自己卡在冲 stdio 缓冲时，照样在 0.5 s 内退出。
    /// v1 没有子进程要杀、没有快照要删。
    private func terminate(drain: Bool) -> Never {
        Self.exitLock.lock()
        let first = !Self.exiting
        Self.exiting = true
        Self.exitLock.unlock()
        // 读线程（EOF）和信号可能同时到：只让第一个走退出流程，后到的停在这里等进程结束。
        guard first else { while true { Thread.sleep(forTimeInterval: 1) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { _exit(0) }
        if drain {
            // 在途的调用多半几毫秒就回完（S1 的工具都是）：管道一次灌进几条请求就关 stdin（排错时常这么试）也收得到结果。
            // 等在途和冲写队列共用这 0.3 s；写被堵住时在途永远清不空，等满 0.3 s 照样退。
            let deadline = DispatchTime.now() + 0.3
            while DispatchTime.now() < deadline {
                lock.lock()
                let idle = inflight.isEmpty
                lock.unlock()
                if idle { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let drained = DispatchSemaphore(value: 0)
            writeQueue.async { drained.signal() }
            _ = drained.wait(timeout: deadline)
        }
        exit(0)
    }

    /// stdin 那一头关了没有（只看不读：客户端关了写端，还没读完的数据留在管道里也一样回 POLLHUP，macOS 上实测过）。
    private func inputClosed() -> Bool {
        var p = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return false }
        return (Int32(p.revents) & (POLLHUP | POLLERR | POLLNVAL)) != 0
    }

    // MARK: - 收

    private func readLoop() {
        var pending = Data()
        var discarding = false  // 当前这一行超长：丢到下一个换行为止
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN { StdioTakeover.waitReady(input, events: POLLIN); continue }  // 继承来的 O_NONBLOCK
            if n <= 0 { return }  // EOF（客户端关了 stdin）或读错：都按关机处理
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                if discarding { discarding = false; continue }
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) {
                    autoreleasepool { handle(Data(line)) }  // 读线程一直不退，不包一层的话临时对象会一直攒到进程结束
                }
            }
            if pending.count > Self.maxLineBytes {
                if !discarding { sendError(id: NSNull(), code: -32700, "Parse error（一行超过 \(Self.maxLineBytes >> 20) MiB）") }
                discarding = true
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    /// 请求的 id：字符串或数字（Bool 不算）；其余（null、对象、缺失）回 nil。
    private func requestID(_ raw: Any?) -> Any? {
        switch raw {
        case let s as String: return s
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n
        default: return nil
        }
    }

    private func handle(_ line: Data) {
        guard let any = try? JSONSerialization.jsonObject(with: line) else {
            return sendError(id: NSNull(), code: -32700, "Parse error")
        }
        guard let msg = any as? JSON else {
            // 2025-06-18 起去掉了 JSON-RPC batch；数组和其他非对象一律算坏请求。
            return sendError(id: NSNull(), code: -32600, "Invalid Request（不支持 batch）")
        }
        let id = requestID(msg["id"])
        guard msg["jsonrpc"] as? String == "2.0" else {
            return sendError(id: id ?? NSNull(), code: -32600, "Invalid Request（缺 \"jsonrpc\":\"2.0\"）")
        }
        guard let method = msg["method"] as? String else {
            // 没有 method：要么是客户端对我们请求的回应（v1 从不发请求，丢掉），要么是坏请求。
            if msg["result"] != nil || msg["error"] != nil { return }
            return sendError(id: id ?? NSNull(), code: -32600, "Invalid Request（缺 method）")
        }
        let rawParams = msg["params"]
        let params = rawParams as? JSON ?? [:]
        // 未知的通知一律丢掉、什么都不回：JSON-RPC 不允许回应通知（Claude Code 会发 notifications/roots/list_changed）。
        guard msg.keys.contains("id") else { return notification(method, params) }
        guard let id else {
            return sendError(id: NSNull(), code: -32600, "Invalid Request（id 必须是字符串或数字，不能是 null）")
        }
        // params 给了就必须是对象（§1.2），哪个方法都一样；null 当作没给（有的客户端会发 "params": null）。
        if let rawParams, !(rawParams is JSON), !(rawParams is NSNull) {
            return sendError(id: id, code: -32602, "Invalid params（params 必须是对象）")
        }
        request(id: id, method: method, params: params)
    }

    private func notification(_ method: String, _ params: JSON) {
        switch method {
        case "notifications/cancelled":
            // 读线程按顺序处理：请求一定先于它的取消登记进 inflight。还没写出去的那一帧到写的时候会被丢掉。
            if let rid = requestID(params["requestId"]) {
                lock.lock(); inflight[key(rid)]?.set(); lock.unlock()
            }
        default:
            break  // notifications/initialized、progress、roots/list_changed……都不用回
        }
    }

    private func request(id: Any, method: String, params: JSON) {
        let meta = params["_meta"] as? JSON ?? [:]
        // modern 请求的 _meta 里带 protocolVersion，每个请求自己验（v1 关着，见类注释）。
        let modern = Self.modernEnabled && meta[Self.metaVersion] != nil
        if modern {
            let v = meta[Self.metaVersion] as? String ?? ""
            guard Self.modernVersions.contains(v) else {
                return sendError(id: id, code: -32022, "Unsupported protocol version",
                                 data: ["supported": Self.modernVersions + Self.legacyVersions, "requested": v])
            }
            guard meta[Self.metaClientCaps] is JSON else {
                return sendError(id: id, code: -32602, "Missing \(Self.metaClientCaps) in _meta")
            }
        }
        // modern 的结果要多带 resultType 和 serverInfo；legacy 原样。
        let decorate: (JSON) -> JSON = { [self] result in
            guard modern else { return result }
            var r = result
            r["resultType"] = "complete"
            var m = r["_meta"] as? JSON ?? [:]
            m["io.modelcontextprotocol/serverInfo"] = ["name": name, "version": version]
            r["_meta"] = m
            return r
        }
        let reply: (JSON) -> Void = { [self] result in send(["jsonrpc": "2.0", "id": id, "result": decorate(result)]) }
        switch method {
        case "initialize":
            initialize(id: id, params: params)
        case "server/discover" where modern:
            reply(["supportedVersions": Self.modernVersions + Self.legacyVersions,
                   "capabilities": ["tools": [:] as JSON], "instructions": instructions])
        case "ping":
            reply([:])
        case "tools/list":
            // 不分页，顺序固定（§10.1）。
            reply(["tools": tools.map(\.definition)])
        case "tools/call":
            call(id: id, params: params, decorate: decorate)
        default:
            // server/discover 和所有不认识的请求立刻回 -32601：不能靠不回让客户端超时回落，那样会拖慢 Claude Code 启动。
            sendError(id: id, code: -32601, "Method not found: \(method)")
        }
    }

    private func initialize(id: Any, params: JSON) {
        let asked = params["protocolVersion"] as? String ?? ""
        // 请求的是 v1 认的两个就原样回，其他（包括允许 batch 的 2025-03-26）一律回最新的那个。
        let answered = Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0]
        let client = params["clientInfo"] as? JSON ?? [:]
        let info = ClientInfo(name: client["name"] as? String ?? "", version: client["version"] as? String ?? "",
                              requested: asked, answered: answered)
        // 一个进程只握一次手：再来一个 initialize 不能把已经协商好的版本和 app_status.client 改掉。
        lock.lock()
        let again = clientInfo != nil
        if !again { clientInfo = info }
        lock.unlock()
        if again {
            return sendError(id: id, code: -32600, "Invalid Request（已经握过手了，initialize 只能发一次）")
        }
        // Antigravity 用哪个协议版本没人验证过（§8），这行日志就是证据。
        MCPLog.stderr("initialize client=\(info.name) \(info.version) requested=\(asked) answered=\(answered)\n")
        var serverInfo: JSON = ["name": name, "version": version]
        serverInfo["title"] = title
        var result: JSON = ["protocolVersion": answered, "serverInfo": serverInfo, "instructions": instructions]
        result["capabilities"] = ["tools": ["listChanged": false] as JSON] as JSON
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func call(id: Any, params: JSON, decorate: @escaping (JSON) -> JSON) {
        guard let toolName = params["name"] as? String, let i = toolIndex[toolName] else {
            return sendError(id: id, code: -32602, "Unknown tool: \(params["name"] ?? "")")
        }
        let rawArgs = params["arguments"]
        guard rawArgs == nil || rawArgs is NSNull || rawArgs is JSON else {
            return sendError(id: id, code: -32602, "arguments 必须是对象")
        }
        let k = key(id)
        let flag = CancelFlag()
        lock.lock()
        if inflight[k] != nil {
            lock.unlock()
            return sendError(id: id, code: -32600, "Invalid Request（id 和一个还没回的请求重复）")
        }
        if inflight.count >= Self.maxInflight {
            lock.unlock()
            let busy = ToolResult.error("busy", "同时在跑的调用已经有 \(Self.maxInflight) 个了，这一个没有执行。",
                                        hint: "等前面的结果回来再调")
            return send(["jsonrpc": "2.0", "id": id, "result": decorate(["content": busy.content, "isError": true])])
        }
        inflight[k] = flag
        let client = clientInfo
        lock.unlock()
        // progressToken 照收不发（v1 不发 progress，§10.1）。
        let call = Call(arguments: rawArgs as? JSON ?? [:], cancel: flag, client: client)
        let tool = tools[i]
        workQueue.async { [self] in
            let result = tool.handler(call)
            var r: JSON = ["content": result.content]
            if result.isError { r["isError"] = true }
            // 帧写出去（或者因为取消丢掉）以后才算不在途。
            send(["jsonrpc": "2.0", "id": id, "result": decorate(r)], cancel: flag) { [self] in
                lock.lock(); inflight[k] = nil; lock.unlock()
            }
        }
    }

    private func key(_ id: Any) -> String { id is String ? "s:\(id)" : "n:\(id)" }

    // MARK: - 发

    func sendError(id: Any, code: Int, _ message: String, data: Any? = nil) {
        var e: JSON = ["code": code, "message": message]
        if let data { e["data"] = data }
        send(["jsonrpc": "2.0", "id": id, "error": e])
    }

    /// 编码在调用方的线程上做，写在串行队列上做。`cancel` 到写的时候已经置位就不写（规范：取消以后不再为这个 id
    /// 发任何消息）；`done` 不管写没写都调。
    func send(_ message: JSON, cancel: CancelFlag? = nil, done: (() -> Void)? = nil) {
        var frame: Data
        if let data = MCPJSON.data(message) {
            frame = data
        } else {
            // 结果编不成 JSON（MCPJSON 已经把 NaN 换掉了，到这里是代码 bug）：回 -32603，不让这个 id 没有下文。
            MCPLog.stderr("xuanpian mcp: 结果编不成 JSON，回 -32603\n")
            let fallback: JSON = ["jsonrpc": "2.0", "id": message["id"] ?? NSNull(),
                                  "error": ["code": -32603, "message": "Internal error（结果编不成 JSON）"] as JSON]
            frame = MCPJSON.data(fallback) ?? Data()
        }
        frame.append(0x0A)
        // 排队的帧满了（客户端一直不读 stdout）：等空位。读线程停在这里时读不到 EOF，所以每 50 ms 自己看一眼 stdin，
        // 客户端已经关了就直接退（写被堵着，冲队列也冲不出去）。
        while writeSlots.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if inputClosed() { terminate(drain: false) }
        }
        writeQueue.async { [self] in
            defer {
                writeSlots.signal()
                done?()
            }
            if cancel?.isSet == true { return }
            writeAll(frame)
        }
    }

    private func writeAll(_ frame: Data) {
        frame.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(output, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { StdioTakeover.waitReady(output, events: POLLOUT); continue }  // 继承来的 O_NONBLOCK
                    terminate(drain: false)  // EPIPE 之类：客户端已经不在了
                }
                off += n
            }
        }
    }
}
