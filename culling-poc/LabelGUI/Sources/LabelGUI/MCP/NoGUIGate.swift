import Foundation

/// 不开界面的闸（DESIGN §5 第 2 层、§10.5）。main.swift 里有两道，用的是同一个判断：
/// - `early()`：在建数据目录之前（还什么都没写）。只拦本来就会走到开界面那一句（main.swift 最后一行）的启动：
///   argv[1] 像是拼错的无头参数 → 不开；argv 里没有无头参数时，LABELGUI_NO_GUI=1 → 不开、
///   「父进程不是 launchd、stdin 也不是终端」（像是被 MCP 客户端起的）→ 不开（LABELGUI_ALLOW_GUI=1 绕过）。
/// - `last()`：开界面之前的最后一道，不管 argv 里有什么：LABELGUI_NO_GUI=1 → 不开；
///   父进程不是 launchd 而且 stdin 不是终端 → 不开（LABELGUI_ALLOW_GUI=1 绕过）。
/// 访达、程序坞、`open`、登录项起的 app 父进程都是 launchd（pid 1），终端里直接跑 stdin 是终端，都不受影响。
/// 判断是纯函数 `decide`：反向用例（拼错的参数、没有参数、管道起的……）用 --mcp-selftest 拿假的输入测，
/// 不用真的起一个进程去试会不会开界面。
enum NoGUIGate {
    enum Stage: String {
        case early, last
    }

    enum Decision: Equatable {
        case proceed
        case refuse(String)
    }

    /// 横线的各种写法：输入法会把 -- 换成长短破折号，全角输入法会打出全角的减号。
    static let dashes: Set<Character> = ["-", "‐", "‑", "‒", "–", "—", "―", "−", "－", "﹣"]

    /// argv[1] 像是拼错了的无头参数时给出正确写法，否则 nil。只看 argv[1]：后面的位置参数里有用户给的标题、刊头，
    /// 标题恰好叫 mcp 时不能被拦。
    /// 去掉前后空白和开头的各种横线以后，是某个无头参数的名字（-collage-ui、—live-host、app-ui、" --mcp"……）
    /// 或者以 mcp 开头（mcp、-mcp、mcp-server、--mcp-server……）就算拼错；本来就写对的不算。
    static func misspelledFlag(_ arg: String) -> String? {
        if AppRuntime.headlessFlags.contains(arg) { return nil }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(trimmed.drop(while: { dashes.contains($0) })).lowercased()
        guard !name.isEmpty else { return nil }
        if AppRuntime.headlessFlags.contains("--" + name) { return "--" + name }
        if name.hasPrefix("mcp") { return "--mcp" }
        return nil
    }

    static func decide(stage: Stage, argv: [String], env: [String: String], ppid: pid_t, stdinIsTTY: Bool) -> Decision {
        let args = Array(argv.dropFirst())
        if let first = args.first, let fix = misspelledFlag(first) {
            return .refuse("参数「\(first)」像是 \(fix) 写错了（要两个半角减号，前后不带空格）：不开界面。")
        }
        let noGUI = env["LABELGUI_NO_GUI"] == "1"
        let launchedByClient = ppid != 1 && !stdinIsTTY && env["LABELGUI_ALLOW_GUI"] != "1"
        if stage == .early && args.contains(where: { AppRuntime.headlessFlags.contains($0) }) {
            return .proceed  // 无头参数自己分派、自己退出，走不到界面
        }
        if noGUI {
            return .refuse("设了 LABELGUI_NO_GUI=1，命令行里却没有能无头跑的参数：不开界面（给 AI 用是 --mcp，其他无头参数见 README「从源码构建」）。")
        }
        if launchedByClient {
            return .refuse("像是被 MCP 客户端启动的（父进程不是 launchd，stdin 也不是终端）：要加 --mcp，不开界面。真要开界面，设 LABELGUI_ALLOW_GUI=1。")
        }
        return .proceed
    }

    static func early() { enforce(.early) }
    static func last() { enforce(.last) }

    private static func enforce(_ stage: Stage) {
        let decision = decide(stage: stage, argv: CommandLine.arguments, env: ProcessInfo.processInfo.environment,
                              ppid: getppid(), stdinIsTTY: isatty(STDIN_FILENO) != 0)
        guard case .refuse(let why) = decision else { return }
        // stderr 的读端可能已经关了：忽略 SIGPIPE，写不出去也照样以 2 退出，不被信号杀掉。
        signal(SIGPIPE, SIG_IGN)
        MCPLog.stderr(why + "\n")
        exit(2)
    }
}
