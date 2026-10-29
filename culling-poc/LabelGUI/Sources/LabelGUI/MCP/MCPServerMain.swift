import Foundation

/// MCP 的三个入口（DESIGN §10，v1 只做实时）：
/// - `LabelGUI --mcp`：stdio MCP 服务器，给 Claude Code / Antigravity 起；
/// - `LabelGUI --mcp-tools`：打印 instructions 和 tools/list（一行 JSON）就退；
/// - `LabelGUI --mcp-call <工具> ['<参数 JSON>']`：调一次工具，打印结果（一行 JSON）就退；出错退出码 1，用法不对 2。
/// 三个都在 main.swift 里先接管 stdio、过 `NoGUIGate.early()`，在建数据目录、同步 Python 运行时、注册字体之前分派到这里，
/// 永不返回。这个进程不建应用对象、不连窗口服务、不起子进程、不建 BatchStore / CollageStore，对数据目录只读（§10.0）。
enum MCPServerMain {
    enum Mode: Equatable {
        case server
        case tools
        /// argv 里 --mcp-call 的下标。
        case call(Int)
    }

    /// argv 里最先出现的那一个 MCP 参数（只认整个参数相等，写错的由 NoGUIGate 拦）；都没有 = nil。
    static func mode(_ argv: [String]) -> Mode? {
        for (i, arg) in argv.enumerated().dropFirst() {
            switch arg {
            case "--mcp": return .server
            case "--mcp-tools": return .tools
            case "--mcp-call": return .call(i)
            default: continue
            }
        }
        return nil
    }

    static func run(_ mode: Mode, fds: StdioTakeover.FDs) -> Never {
        // 有意走一次 print：接管以后它落在 stderr（mcp_smoke 断言 stdout 上只有 JSON，而 stderr 里有这一行）。
        print("xuanpian mcp：stdout 已接管，协议走私有 fd；print 之类的输出都在 stderr")
        let live = MCPConfig.liveEnabled
        let tools = registry(live: live)
        switch mode {
        case .server:
            let server = MCPStdioServer(name: "xuanpian", title: "选片工具", version: MCPConfig.version,
                                        instructions: MCPToolDefs.instructions(live: live), tools: tools,
                                        input: fds.input, output: fds.output)
            // 回完 initialize 以后在后台清一次预览缓存（§10.3）：只在带标记的输出目录里、只删服务器起名的文件，不建任何东西
            server.afterInitialize = { _ = MCPOutput.cleanup() }
            server.run()
        case .tools:
            var out: [String: Any] = ["tools": tools.map(\.definition)]
            out["instructions"] = MCPToolDefs.instructions(live: live)
            emit(out, to: fds.output)
            exit(0)
        case .call(let i):
            let args = CommandLine.arguments
            guard args.count > i + 1 else { usage("--mcp-call 后面要跟工具名") }
            let name = args[i + 1]
            guard let tool = tools.first(where: { $0.name == name }) else {
                usage("没有工具「\(name)」（这一次能用的：\(tools.map(\.name).joined(separator: "、"))）")
            }
            let raw = args.count > i + 2 ? args[i + 2] : "{}"
            guard let arguments = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                usage("参数要是一个 JSON 对象，比如 '{}'：\(raw)")
            }
            let result = tool.handler(MCPStdioServer.Call(arguments: arguments))
            var out: [String: Any] = ["content": result.content]
            if result.isError { out["isError"] = true }
            emit(out, to: fds.output)
            exit(result.isError ? 1 : 0)
        }
    }

    /// 这一次 tools/list 里的工具和处理函数（顺序 = §10.1）。要 app 的 15 个按 §10.2 路由（MCPLiveTools）：每次调用探一次，
    /// app 没开一律 app_not_running，服务器绝不启动 app。
    static func registry(live: Bool) -> [MCPStdioServer.Tool] {
        MCPToolDefs.tools(live: live).compactMap { def in
            guard let name = def["name"] as? String else { return nil }
            let handler: (MCPStdioServer.Call) -> MCPStdioServer.ToolResult
            switch name {
            case "app_status": handler = MCPStatus.appStatus
            case "cull_list_sessions": handler = MCPInProcessTools.listSessions
            case "collage_list_templates": handler = MCPInProcessTools.listTemplates
            default:
                guard let routed = MCPLiveTools.handler(name) else { return nil }
                handler = routed
            }
            return MCPStdioServer.Tool(name: name, definition: def, handler: handler)
        }
    }

    /// --mcp-tools / --mcp-call 的输出：一行 JSON 写到私有 stdout。
    private static func emit(_ object: [String: Any], to fd: Int32) {
        var data = MCPJSON.data(object) ?? Data("{}".utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { StdioTakeover.waitReady(fd, events: POLLOUT); continue }
                    return
                }
                off += n
            }
        }
    }

    private static func usage(_ message: String) -> Never {
        MCPLog.stderr("--mcp-call：\(message)\n用法：LabelGUI --mcp-call <工具> ['<参数 JSON>']\n")
        exit(2)
    }
}

/// 环境变量和上限（DESIGN §10.2、§3.0）。都在第一次用到时读一次。
enum MCPConfig {
    /// LABELGUI_MCP_LIVE=0：不连 app（从不探测），tools/list 只有 app 没开也能用的 3 个（§10.1）。
    static let liveEnabled = ProcessInfo.processInfo.environment["LABELGUI_MCP_LIVE"] != "0"

    /// 单次调用的截止时间上限：LABELGUI_MCP_DEADLINE_SEC，默认 50，最多 600（§10.2）。
    static let deadlineCap: Int = {
        guard let raw = ProcessInfo.processInfo.environment["LABELGUI_MCP_DEADLINE_SEC"].flatMap({ Int($0) }) else { return 50 }
        return min(max(raw, 5), 600)
    }()

    /// 一次调用里内联图片的合计上限（KB）：LABELGUI_MCP_INLINE_KB，默认 600（§4.4、§10.3）。
    static let inlineKB: Int = {
        guard let raw = ProcessInfo.processInfo.environment["LABELGUI_MCP_INLINE_KB"].flatMap({ Int($0) }), raw > 0 else { return 600 }
        return min(raw, 20_000)
    }()

    /// 预览长边上限（§3.2）。
    static let maxEdge = 1568

    /// 单张预览的字节上限（KB，§4.4）：app 出图时照它压（LiveImages），inline:false 时一次最多 4 张都给。
    static let perImageKB = 350

    /// 版本和构建号：app 里的二进制取 Info.plist；开发用的裸二进制没有 Info.plist，报 dev。
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev" }
}
