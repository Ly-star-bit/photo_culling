import Foundation

/// --mcp-selftest 的 STEP 2 部分（MCPSelfTest.run 调），全是纯函数，不连任何 socket、不碰锁文件：
/// 9. 探测的判定表（LiveClient.afterConnectFailure / afterHello）：本机起不出来的状态（old_app、headless_writer、
///    peer_rejected、not_ready、data_dir_mismatch、锁读不了……）靠这张表测；期望值逐行手写，照 §9.1 的树。
///    数据目录 stat 被拒（EACCES / EPERM）算「在、读不了」、探测报 unreachable，它和锁文件 open 被拒、connect 被拒都按宿主沙箱说，
///    data_dir_unreadable 那一句只说真的看不到的；
///    §6.3：设了 LABELGUI_DATA_DIR、not_running、app 却开着时 app_status 加的那一句（app 开没开用假的输入，不查进程表）。
/// 10. 状态 → 错误码（§10.2）、15 个要 app 的工具 → 桥方法（§10.4）、session 核对（§10.2「session 怎么比」）、
///    截止时间（没给 deadline_seconds 时也不超过 LABELGUI_MCP_DEADLINE_SEC，和 tools/list 的 default 一样）。
/// 11. 线上格式：锁文件那一行的解析、socket 路径上限、SHA-256 前 16 位、编码时 NaN 变 null；--live-host 认不认得出
///     真实的 SockDir（只 realpath 已经存在的上一级：用户临时目录）。
extension MCPSelfTest {
    static func liveChecks(_ check: Check) {
        decisionChecks(check)
        routingChecks(check)
        wireChecks(check)
    }

    private static func decisionChecks(_ check: Check) {
        typealias C = LiveClient
        let app = C.LockHolder(role: "app", bridge: "on")
        let appOff = C.LockHolder(role: "app", bridge: "off", reason: "disabled_in_settings")
        let appUnavailable = C.LockHolder(role: "app", bridge: "unavailable", reason: "socket_path_too_long")
        let headless = C.LockHolder(role: "headless", bridge: nil)
        let unknown = C.LockHolder(role: nil, bridge: nil)
        // (connect errno, 锁, 有旧版 app, 300 ms 还没用完) → 期望
        let rows: [(Int32, C.LockProbe, Bool, Bool, C.Next, String)] = [
            (ENOENT, .missing, false, true, .state(.notRunning, reason: nil), "没有 socket、没有锁文件"),
            (ENOENT, .missing, true, true, .state(.oldApp, reason: nil), "没有锁文件、有旧版 app"),
            (ECONNREFUSED, .free, false, true, .state(.notRunning, reason: nil), "残留 socket、锁是空的（R6 T5b）"),
            (ECONNREFUSED, .free, true, true, .state(.oldApp, reason: nil), "锁是空的、有旧版 app"),
            (ECONNREFUSED, .held(app), false, true, .retryConnect, "锁是 app、connect 被拒、预算没用完：再连（积压满了）"),
            (ECONNREFUSED, .held(app), false, false, .state(.unreachable, reason: "connect:\(ECONNREFUSED)"), "预算用完：unreachable"),
            (ENOENT, .held(app), false, true, .state(.unreachable, reason: "connect:\(ENOENT)"), "socket 被删、锁是 app（R6 T15）：不重连"),
            (ECONNREFUSED, .held(appOff), false, true, .state(.bridgeOff, reason: "disabled_in_settings"), "锁写着 bridge=off"),
            (ENOENT, .held(appUnavailable), false, true, .state(.unreachable, reason: "socket_path_too_long"), "app 开不了桥"),
            (ECONNREFUSED, .held(appUnavailable), false, true, .state(.unreachable, reason: "socket_path_too_long"), "开不了桥时不重连"),
            (ENOENT, .held(headless), false, true, .state(.headlessWriter, reason: nil), "无头写者（R6 §3.4）"),
            (ENOENT, .held(unknown), false, true, .state(.unreachable, reason: "lock_role_unknown"), "锁那一行解析不了"),
            (ENOENT, .denied(EACCES), false, true, .state(.unreachable, reason: "lock_unreadable:\(EACCES)"), "锁打不开（沙箱）≠ 没开"),
            (ENOENT, .denied(ELOOP), true, true, .state(.unreachable, reason: "lock_unreadable:\(ELOOP)"), "锁是符号链接"),
            (EACCES, .free, false, true, .state(.notRunning, reason: nil), "connect EACCES、锁是空的"),
            (EPERM, .held(app), false, true, .state(.unreachable, reason: "connect:\(EPERM)"), "锁是 app、connect EPERM（宿主沙箱，§8 第 27 条）：不重连"),
            (ENAMETOOLONG, .missing, false, true, .state(.notRunning, reason: nil), "socket 路径太长、没有锁"),
        ]
        for (e, lock, old, budget, want, label) in rows {
            let got = C.afterConnectFailure(errno: e, lock: lock, oldAppRunning: old, budgetLeft: budget)
            check(got == want, "探测 · \(label)：\(got)，应该 \(want)")
        }
        let id = "16777234:42"
        func reply(proto: Int = 1, lo: Int = 1, hi: Int = 1, dir: String = id, ready: Bool = true) -> [String: Any] {
            var r: [String: Any] = ["proto": proto, "proto_min": lo, "proto_max": hi]
            r["data_dir_id"] = dir
            r["ready"] = ready
            return r
        }
        let hellos: [(C.HelloOutcome, Bool, C.Next, String)] = [
            (.reply(reply()), true, .state(.live, reason: nil), "正常"),
            (.reply(reply(lo: 99, hi: 99)), true, .state(.protoMismatch, reason: nil), "app 的协议区间不含 1"),
            (.reply(reply(proto: 2, lo: 1, hi: 2)), true, .state(.protoMismatch, reason: nil), "app 回的 proto 不是 1"),
            (.reply(reply(dir: "1:2")), true, .state(.dataDirMismatch, reason: nil), "dev:ino 不一样"),
            (.reply(reply(ready: false)), true, .state(.notReady, reason: nil), "ready:false"),
            (.error("proto_mismatch"), true, .state(.protoMismatch, reason: nil), "app 拒绝了协议"),
            (.error("data_dir_mismatch"), true, .state(.dataDirMismatch, reason: nil), "app 说数据目录不对"),
            (.error("hello_required"), true, .state(.unreachable, reason: "hello_error:hello_required"), "别的 hello 错误"),
            (.timeout, true, .state(.unresponsive, reason: "hello_timeout"), "hello 1 s 没回（R6 T9）"),
            (.garbage, true, .state(.unresponsive, reason: "hello_garbage"), "回了不是 JSON 的东西"),
            (.eof, true, .state(.peerRejected, reason: "closed_before_hello_reply"), "一个字节没回就关（R6 T14）"),
            (.tooManyConnections, true, .retryConnect, "16 个连接满了、hello 预算没用完：再连"),
            (.tooManyConnections, false, .state(.unresponsive, reason: "too_many_connections"), "一直满：unresponsive"),
        ]
        for (outcome, budget, want, label) in hellos {
            let got = C.afterHello(outcome, dataDirID: id, budgetLeft: budget)
            check(got == want, "hello · \(label)：\(got)，应该 \(want)")
        }
        dataDirChecks(check)
    }

    /// 数据目录 stat 被拒（宿主的沙箱）≠ 不存在；设了 LABELGUI_DATA_DIR、not_running、app 却开着 → §6.3 那一句。
    private static func dataDirChecks(_ check: Check) {
        // (stat 的 errno, 是目录, access 过不过) → (在, 能读)
        let states: [(Int32, Bool, Bool, Bool, Bool, String)] = [
            (0, true, true, true, true, "正常"),
            (0, true, false, true, false, "在、access 不过（chmod、沙箱只挡读内容）"),
            (ENOENT, false, false, false, false, "不存在"),
            (ENOTDIR, false, false, false, false, "上一级是个文件"),
            (0, false, false, false, false, "是个文件"),
            (EPERM, false, false, true, false, "stat 被沙箱拒（EPERM）：在、读不了，不是不存在"),
            (EACCES, false, false, true, false, "上一级没有 x 权限（EACCES）：在、读不了"),
        ]
        for (e, isDir, acc, exists, readable, label) in states {
            let got = MCPPaths.dataDirState(statErrno: e, isDirectory: isDir, accessOK: acc)
            check(got.exists == exists && got.readable == readable, "数据目录 · \(label)：\(got)")
        }
        // probe 在数据目录被拒时报 unreachable（reason data_dir_unreadable:<errno>）；锁文件 open 被拒（lock_unreadable）同样是
        // 沙箱，而且锁没看到：说明里不能说「锁被它占着」。锁被 app 占着而 connect 被拒（EPERM / EACCES，§8 第 27 条）也是沙箱，
        // 锁看到了。是沙箱的都不能说「10 秒内会自愈」，hint 是放行。(reason, 是不是沙箱, 锁没看到, 说明里要有的字)
        let denials: [(LiveState, String, Bool, Bool, String)] = [
            (.unreachable, LiveClient.dataDirUnreadable + ":\(EPERM)", true, true, "读不了数据目录（"),
            (.unreachable, LiveClient.dataDirUnreadable + ":\(EACCES)", true, true, "读不了数据目录（"),
            (.unreachable, "lock_unreadable:\(EPERM)", true, true, "读不了数据目录里的锁文件"),
            (.unreachable, "lock_unreadable:\(EACCES)", true, true, "读不了数据目录里的锁文件"),
            (.unreachable, "connect:\(EPERM)", true, false, "连不上本用户临时目录里它的 socket（connect:\(EPERM)，"),
            (.unreachable, "connect:\(EACCES)", true, false, "连不上本用户临时目录里它的 socket（connect:\(EACCES)，"),
            (.unreachable, "lock_unreadable:\(ELOOP)", false, false, ""),
            (.unreachable, "connect:\(ENOENT)", false, false, ""),
            (.unreachable, "connect:\(ECONNREFUSED)", false, false, ""),
            (.notRunning, "data_dir_missing", false, false, ""),
        ]
        for (state, reason, sandbox, unseen, part) in denials {
            let p = LiveClient.Probe(state: state, reason: reason)
            let (m, h) = LiveClient.explain(p)
            let ok = sandbox ? (m.contains(part) && m.contains("沙箱") && m.contains("锁被它占着") != unseen && !h.contains("自愈")
                                && h == MCPStatus.sandboxHint && LiveClient.errorCode(state) == "app_unreachable")
                             : h != MCPStatus.sandboxHint
            check(LiveClient.isSandboxDenied(p) == sandbox && LiveClient.lockUnseen(p) == unseen && ok,
                  "沙箱 · \(state.rawValue) \(reason)：\(sandbox ? "是" : "不是")沙箱，锁\(unseen ? "没" : "")看到：\(m) / \(h)")
        }
        // data_dir_unreadable 那一句只说真的发生了的（锁没看到 → 看不出开没开；sessions.json 读被拒 → 列不出场次）：
        // 目录只有 x 没有 r 时两样都看得到，不能和同一份 warnings 里的「选片工具没开」打架。(锁没看到, 读被拒, 期望的说明)
        let base = "读不了数据目录（多半是宿主的沙箱不让读）"
        let unreadable: [(Bool, Bool, String)] = [
            (true, true, base + "：看不出选片工具开没开，也列不出场次。"),
            (true, false, base + "：看不出选片工具开没开。"),
            (false, true, base + "：列不出场次。"),
            (false, false, base + "。"),
        ]
        for (unseen, denied, want) in unreadable {
            let w = MCPStatus.dataDirUnreadableWarning(lockUnseen: unseen, sessionsDenied: denied)
            check(w["code"] as? String == "data_dir_unreadable" && w["message"] as? String == want && w["hint"] as? String == MCPStatus.sandboxHint,
                  "data_dir_unreadable · 锁\(unseen ? "没" : "")看到、sessions.json \(denied ? "读被拒" : "读得到")：\(w["message"] ?? "")")
        }
        // §6.3：(LABELGUI_DATA_DIR, 状态, app 开着) → 有没有那一句；app 开着没开只在前两条成立时才去看
        let rows: [(String?, LiveState, Bool, Bool, String)] = [
            ("/tmp/lg", .notRunning, true, true, "设了、not_running、app 开着"),
            ("/tmp/lg", .notRunning, false, false, "app 没开"),
            (nil, .notRunning, true, false, "没设（默认数据目录：那是 old_app 的事）"),
            ("", .notRunning, true, false, "设成空的 = 没设"),
            ("/tmp/lg", .live, true, false, "live"),
            ("/tmp/lg", .unreachable, true, false, "unreachable"),
            ("/tmp/lg", .disabled, true, false, "LABELGUI_MCP_LIVE=0"),
        ]
        for (env, state, running, want, label) in rows {
            var asked = false
            let w = MCPStatus.dataDirOverrideWarning(envDataDir: env, state: state, appRunning: { asked = true; return running }())
            let text = w?["message"] as? String ?? ""
            let spec = "选片工具开着，但 MCP 用的数据目录是 LABELGUI_DATA_DIR=\(env ?? "")，不是 app 的那个：去掉这个环境变量才能实时操作"
            let lazy = asked == (env?.isEmpty == false && state == .notRunning)
            check((w != nil) == want && lazy && (!want || (w?["code"] as? String == "data_dir_override" && text.hasPrefix(spec))),
                  "§6.3 · \(label)：\(w == nil ? "没有" : text)；查没查进程表：\(asked)")
        }
        for (raw, want) in [("0", false), ("1", true)] {
            check(MCPStatus.appRunningForOverrideCheck(["LABELGUI_MCP_TEST_GUI_RUNNING": raw]) == want,
                  "LABELGUI_MCP_TEST_GUI_RUNNING=\(raw) 钉住「app 开着」= \(want)")
        }
    }

    private static func routingChecks(_ check: Check) {
        let codes: [(LiveState, String)] = [
            (.notRunning, "app_not_running"), (.bridgeOff, "bridge_off"), (.unreachable, "app_unreachable"),
            (.unresponsive, "app_unresponsive"), (.protoMismatch, "app_version_mismatch"), (.oldApp, "old_app"),
            (.notReady, "not_ready"), (.dataDirMismatch, "data_dir_mismatch"), (.peerRejected, "peer_rejected"),
            (.headlessWriter, "busy"),
        ]
        for (state, code) in codes {
            check(LiveClient.errorCode(state) == code, "\(state.rawValue) 应该回 \(code)，实际 \(LiveClient.errorCode(state))")
        }
        let methods: [String: String] = [
            "cull_session_overview": "cull.read", "cull_list_photos": "cull.read", "cull_get_photos": "cull.read",
            "cull_list_groups": "cull.read", "cull_preview_photos": "cull.preview", "collage_get_state": "collage.state",
            "app_open_session": "session.open", "cull_set_verdicts": "cull.set_verdicts", "cull_show_photos": "cull.show",
            "collage_apply_template": "collage.apply_template", "collage_run_kit": "collage.run_kit",
            "collage_next_cover": "collage.next_cover", "collage_set_text": "collage.set_text",
            "collage_set_style": "collage.set_style", "app_undo": "undo",
        ]
        let appTools = MCPToolDefs.tools(live: true).compactMap { $0["name"] as? String }.dropFirst(3)
        check(Set(appTools) == Set(methods.keys) && Set(MCPLiveTools.routes.keys) == Set(methods.keys),
              "要 app 的 15 个工具和路由表对得上：\(appTools.sorted())")
        for (tool, method) in methods {
            check(MCPLiveTools.routes[tool]?.method == method, "\(tool) 应该转给 \(method)")
        }
        let deadlines: [String: Int] = ["cull_preview_photos": 30_000, "collage_run_kit": 50_000, "collage_next_cover": 50_000]
        for (tool, route) in MCPLiveTools.routes {
            check(route.deadlineMs == (deadlines[tool] ?? 10_000), "\(tool) 的默认截止时间 \(route.deadlineMs) ms（§10.2）")
        }
        // 这次调用真正用的截止时间：没给 deadline_seconds 时，有这个参数的三个工具也不超过 LABELGUI_MCP_DEADLINE_SEC
        // （和 tools/list 的 default 一样）；其余工具照用 10 s；给了就用给的。期望值手写：(工具, 参数, 上限, 期望 ms)
        let effective: [(String, [String: Any], Int, Int)] = [
            ("cull_preview_photos", [:], 50, 30_000), ("cull_preview_photos", [:], 20, 20_000), ("cull_preview_photos", [:], 5, 5_000),
            ("collage_run_kit", [:], 50, 50_000), ("collage_run_kit", [:], 20, 20_000), ("collage_run_kit", [:], 600, 50_000),
            ("collage_next_cover", [:], 30, 30_000), ("collage_next_cover", [:], 5, 5_000),
            ("collage_run_kit", ["deadline_seconds": 40], 50, 40_000), ("cull_preview_photos", ["deadline_seconds": 7], 600, 7_000),
            ("cull_list_photos", [:], 5, 10_000), ("collage_set_text", [:], 5, 10_000), ("collage_get_state", [:], 600, 10_000),
        ]
        for (tool, args, cap, want) in effective {
            guard let route = MCPLiveTools.routes[tool] else { check(false, "没有 \(tool) 的路由"); continue }
            let got = MCPLiveTools.effectiveDeadlineMs(tool, route, args, cap: cap)
            check(got == want, "截止时间 · \(tool) \(args) 上限 \(cap) s：\(got) ms，应该 \(want)")
        }
        // 这个进程自己的上限下：tools/list 写的 default × 1000 = 没给参数时真正用的
        for def in MCPToolDefs.tools(live: true) {
            let name = def["name"] as? String ?? ""
            let props = (def["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            guard let dl = props["deadline_seconds"] as? [String: Any], let route = MCPLiveTools.routes[name] else { continue }
            let advertised = (dl["default"] as? Int ?? -1) * 1_000
            let used = MCPLiveTools.effectiveDeadlineMs(name, route, [:], cap: MCPConfig.deadlineCap)
            check(advertised == used, "\(name)：tools/list 的 default \(advertised) ms = 没给参数时用的 \(used) ms")
        }
        // session 核对：key / 路径 / 没打开任何场次 / 必填没给 / 可选没给
        let open: [String: Any] = ["session": "0123456789abcdef", "folder": "/nonexistent-xp-mcp-selftest/20261021"]
        func code(_ r: Result<String?, MCPLiveTools.SessionError>) -> String {
            switch r {
            case .success(let k): return "ok:" + (k ?? "nil")
            case .failure(let e):
                let text = e.result.content.first?["text"] as? String ?? ""
                return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["code"] as? String } ?? "?"
            }
        }
        let sessions: [(MCPLiveTools.SessionRule, Any?, [String: Any]?, String, String)] = [
            (.required, "0123456789abcdef", open, "ok:0123456789abcdef", "key 对上"),
            (.required, "0123456789ABCDEF", open, "ok:0123456789abcdef", "大写 key 也认"),
            (.required, "/nonexistent-xp-mcp-selftest/20261021", open, "ok:0123456789abcdef", "路径对上"),
            (.required, "/nonexistent-xp-mcp-selftest/20261021/", open, "ok:0123456789abcdef", "结尾斜杠"),
            (.required, "/nonexistent-xp-mcp-selftest/other", open, "session_not_open", "别的场次"),
            (.required, "fedcba9876543210", open, "session_not_open", "别的 key"),
            (.required, "0123456789abcdef", nil, "session_not_open", "app 没打开任何场次"),
            (.required, nil, open, "invalid_argument", "必填没给"),
            (.required, 12, open, "invalid_argument", "不是字符串"),
            (.required, "relative/dir", open, "invalid_argument", "相对路径"),
            (.optional, nil, open, "ok:nil", "可选没给 = app 当前那一场"),
            (.optional, nil, nil, "ok:nil", "可选没给、没打开任何场次（app 回 session:null）"),
            (.optional, NSNull(), open, "ok:nil", "null 当作没给"),
            (.optional, "fedcba9876543210", open, "session_not_open", "可选给了就核对"),
            (.target, "fedcba9876543210", open, "ok:nil", "app_open_session 不核对"),
        ]
        for (rule, raw, o, want, label) in sessions {
            let got = code(MCPLiveTools.checkSession(rule, raw, open: o))
            check(got == want, "session · \(label)：\(got)，应该 \(want)")
        }
    }

    private static func wireChecks(_ check: Check) {
        check(LiveSockAddr.maxPathBytes == 103, "sun_path 上限应该是 103 字节，实际 \(LiveSockAddr.maxPathBytes)")
        let fits = "/" + String(repeating: "a", count: 102)
        check(LiveSockAddr.with(fits) { _, _ in true } == true, "103 字节的 socket 路径放得下")
        check(LiveSockAddr.with(fits + "b") { _, _ in true } == nil, "104 字节的 socket 路径放不下（不截断）")
        // 期望值是 python3 hashlib.sha256 算的，不是这段代码自己算的
        check(LivePaths.hash16("/private/tmp/xp-live-selftest/数据") == "808d858e3381fde9", "SHA-256 前 16 位和 hashlib 一致")
        let info = LiveLock.parseInfo(Data(#"{"role":"app","pid":12,"bridge":"off"}"#.utf8) + Data("\n垃圾".utf8))
        check(LiveClient.LockHolder(info) == LiveClient.LockHolder(role: "app", bridge: "off", reason: nil, pid: 12),
              "锁文件第一行解得出来，后面的垃圾不管")
        check(LiveLock.parseInfo(Data("not json".utf8)) == nil && LiveLock.parseInfo(Data()) == nil, "解析不了 = nil（role 未知）")
        let big = Data(repeating: 0x20, count: 5_000) + Data(#"{"role":"app"}"#.utf8)
        check(LiveLock.parseInfo(big) == nil, "只看前 4 KB")
        let frame = String(decoding: LiveWire.encode(["id": 1, "result": ["x": Double.nan, "path": "/a/b"]]), as: UTF8.self)
        check(frame == "{\"id\":1,\"result\":{\"path\":\"/a/b\",\"x\":null}}\n", "桥的回复 NaN 变 null、不转义斜杠、一行：\(frame)")
        // --live-host 拒绝真实的 SockDir（各种写法）；只 realpath 已经存在的上一级，不建、不进去
        if let real = LivePaths.realSockDir, let temp = LivePaths.darwinUserTempDir() {
            let spellings = [real, real + "/", real + "/sub", "/private" + real, real.uppercased()]
            for p in spellings { check(LivePaths.isRealSockDir(p), "\(p) 应该认成真实的 SockDir") }
            let others = ["/tmp/xp-live-selftest-not-real", (temp.hasSuffix("/") ? temp : temp + "/") + "xuanpian-live-test-1", temp]
            for p in others { check(!LivePaths.isRealSockDir(p), "\(p) 不是真实的 SockDir") }
        } else {
            check(false, "拿不到 DARWIN_USER_TEMP_DIR")
        }
        let odd = String(decoding: LiveWire.encode(["id": 2, "result": ["bad": Date()]]), as: UTF8.self)
        check(odd.contains("\"internal\"") && odd.contains("\"id\":2") && odd.hasSuffix("\n"), "编不了的回复换成同一个 id 的 internal：\(odd)")
    }
}
