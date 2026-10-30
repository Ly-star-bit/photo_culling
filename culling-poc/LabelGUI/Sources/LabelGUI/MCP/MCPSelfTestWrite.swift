import Foundation

/// --mcp-selftest 的 STEP 3b 部分（MCPSelfTest.run 调），全是纯函数，不连 socket、不碰文件、不建任何 store：
/// 16. 9 个写工具的参数校验（MCPArgs）：一张手写的对 / 错表，含 schema 写不出来的那几条（至少给一个字段、cell_text 要带
///     if_digest、op_id 8–64 个字、look_strength 0–1、文字可以是空字符串）。
/// 17. app_undo 的判定（LiveAILog.check）：AI 写了能撤；用户之后又改过 → undo_not_ours；用户自己撤过 → already_undone_by_user；
///     换过场次 → session_switched；没改出东西的写不挡后面的撤销；AI 连撤两步只在中间没插用户的改动时成立。
/// 18. 忙信号挡哪些写（LiveInteraction.blocks，§9.6b 的表照字面写一遍）。
/// 19. 标题栏指示（LiveIndicator，§9.6a 的表）：显示什么、谁盖过谁、认不认得客户端的名字、关掉以后忘掉来过谁；
///     桥停了的两条（锁丢了、开桥失败，§9.2.4）排在哪、菜单关了照样不显示、开好了以后「已连接」接着显示。
/// 20. 桥停了（§9.2.4）：每种桥的状态在已经连上的连接上回什么（LiveServer.bridgeDownReply：bridge_off 只给菜单开关，
///     别的是 app_unreachable 带真正的原因）、标题栏是哪一句（indicatorProblem）、`--mcp` 从锁文件那一行看到这些原因时
///     给模型的 hint 里有没有标题栏上的同一句话（LiveClient.explain）；--mcp 自己算出来的原因（no_temp_dir）不提标题栏；
///     锁空着时的 not_running / old_app 在 §10.2 那句后面补标题栏那一句（锁刚被放掉、app 还没拿回来分不出来）。
extension MCPSelfTest {
    static func writeChecks(_ check: Check) {
        writeArgChecks(check)
        undoChecks(check)
        busyChecks(check)
        indicatorChecks(check)
        bridgeDownChecks(check)
    }

    private static func bridgeDownChecks(_ check: Check) {
        typealias B = LiveServer.Bridge
        let lost = LiveBridgeNotice.lockLost
        check(lost == "数据目录的锁被别的程序拿走了：AI 实时操作已停，重开 app 恢复", "锁丢了那一句是 §9.2.4 的原话：\(lost)")
        let unsafe = "AI 实时操作的连接开不起来（放连接的临时目录权限不对）：已暂停，每 10 秒自动再试"
        let tooLong = "AI 实时操作的连接开不起来（连接文件的路径太长）：已停，重开 app 再试"
        // 锁文件重新 open 不了（数据目录被挪走……）：不是「被别的程序拿走了」，自检接着试
        let reopen = "AI 实时操作的连接开不起来（数据目录的锁文件不见了或打不开）：已暂停，每 10 秒自动再试"
        // (桥, 期望的错误码 / nil = 照常执行, hint 里要有的字, 标题栏)
        let rows: [(B, String?, String, LiveBridgeProblem?)] = [
            (.on, nil, "", nil),
            (.off("disabled_in_settings"), "bridge_off", "菜单", nil),
            (.unavailable("lock_lost"), "app_unreachable", lost, .lockLost),
            (.unavailable("sock_dir_unsafe"), "app_unreachable", unsafe, .failed(unsafe)),
            (.unavailable("bind_failed"), "app_unreachable", "连接建不起来", .failed("AI 实时操作的连接开不起来（连接建不起来）：已暂停，每 10 秒自动再试")),
            (.unavailable("socket_path_occupied"), "app_unreachable", "被别的文件占着", .failed("AI 实时操作的连接开不起来（连接文件的位置被别的文件占着）：已暂停，每 10 秒自动再试")),
            (.unavailable("socket_path_too_long"), "app_unreachable", tooLong, .failed(tooLong)),
            (.unavailable("lock_failed"), "app_unreachable", "锁文件打不开", .failed("AI 实时操作的连接开不起来（数据目录的锁文件打不开）：已停，重开 app 再试")),
            (.unavailable("lock_reopen_failed"), "app_unreachable", reopen, .failed(reopen)),
            (.unavailable("another_instance"), "app_unreachable", "过几秒再调", nil),
            (.unavailable("waiting_for_lock"), "app_unreachable", "过几秒再调", nil),
            (.unavailable("starting"), "app_unreachable", "过几秒再调", nil),
        ]
        for (bridge, want, hintPart, problem) in rows {
            let reply = LiveServer.bridgeDownReply(bridge)
            var code: String?
            var message = ""
            var data: [String: Any] = [:]
            if case .failure(let c, let m, let d)? = reply {
                code = c
                message = m
                data = d ?? [:]
            }
            let hint = data["hint"] as? String ?? ""
            let menu = message.contains("菜单") || hint.contains("菜单")
            let reasonOK = bridge == .on || code == "bridge_off" || data["reason"] as? String == bridge.reason
            check(code == want && (want == nil || (hint.contains(hintPart) && data["executed"] as? Bool == false)) && reasonOK
                  && menu == (code == "bridge_off"),
                  "桥 \(bridge) → \(code ?? "照常执行")（应该 \(want ?? "照常执行")），hint「\(hint)」；只有菜单关了才说菜单")
            check(LiveServer.indicatorProblem(bridge) == problem, "桥 \(bridge) → 标题栏 \(String(describing: LiveServer.indicatorProblem(bridge)))")
        }
        // --mcp：锁文件那一行（或者锁被不认识的程序占着）→ unreachable；hint 里是标题栏上的同一句话
        let probes: [(String, String)] = [
            ("lock_lost", lost), ("lock_role_unknown", lost), ("sock_dir_unsafe", unsafe), ("socket_path_too_long", tooLong),
            ("lock_reopen_failed", reopen),
        ]
        for (reason, sentence) in probes {
            let p = LiveClient.Probe(state: .unreachable, reason: reason)
            let (message, hint) = LiveClient.explain(p)
            check(hint.contains("「\(sentence)」") && !message.contains("10 秒内会自愈") && !hint.contains("10 秒内会自愈")
                  && LiveClient.errorCode(p.state) == "app_unreachable",
                  "--mcp 看到 unreachable（\(reason)）：hint 带标题栏那一句「\(sentence)」：\(hint)")
        }
        let plain = LiveClient.explain(LiveClient.Probe(state: .unreachable, reason: "connect:2"))
        check(plain.hint == "10 秒内会自愈；不行就请用户重开选片工具", "socket 一时不在（connect:2）：还是原来那句自愈的说明")
        // --mcp 自己拿不到临时目录（no_temp_dir）、数据目录解析不了：app 没写过锁文件那一行，不能说成 app 标题栏上的事
        for reason in ["no_temp_dir", "data_dir", "lock_failed"] {
            let (message, hint) = LiveClient.explain(LiveClient.Probe(state: .unreachable, reason: reason))
            check(!LiveBridgeNotice.onLockLine.contains(reason) && !hint.contains("标题栏") && !message.contains("开不起来"),
                  "--mcp 看到 unreachable（\(reason)）：不是 app 写在锁文件里的原因，不提标题栏：\(message) / \(hint)")
        }
        let lockLine: Set<String> = ["bind_failed", "sock_dir_unsafe", "socket_path_occupied", "lock_reopen_failed",
                                     "lock_lost", "socket_path_too_long"]
        check(LiveBridgeNotice.onLockLine == lockLine, "app 会写进锁文件那一行的原因：\(LiveBridgeNotice.onLockLine.sorted())")
        // 锁被别的程序放掉、app 还没拿回来（1 s 内）：锁是空的，--mcp 判成 not_running / old_app。§10.2 那句原样在前面，
        // 后面补一句标题栏上的那一句
        let notRunning = LiveClient.explain(LiveClient.Probe(state: .notRunning))
        let oldApp = LiveClient.explain(LiveClient.Probe(state: .oldApp))
        let spec102 = "请用户自己打开选片工具，并在 app 里打开要处理的场次，再调一次；MCP 不会启动它。"
        let notRunningOK: Bool = notRunning.message == "选片工具没开。" && notRunning.hint.hasPrefix(spec102)
        let notRunningAside: Bool = notRunning.hint.contains("「\(lost)」") && LiveClient.errorCode(.notRunning) == "app_not_running"
        check(notRunningOK && notRunningAside, "not_running：§10.2 的 hint 原样在前，后面带标题栏那一句：\(notRunning.hint)")
        let oldAppOK: Bool = oldApp.hint.hasPrefix("请用户更新 app，或者先退出它") && oldApp.hint.contains("「\(lost)」")
        check(oldAppOK, "old_app：hint 带标题栏那一句：\(oldApp.hint)")
    }

    private static func indicatorChecks(_ check: Check) {
        MainActor.assumeIsolated {
            let i = LiveIndicator()
            check(i.text == "" && i.stateName == "none" && i.bridgeEnabled, "没有 AI：副标题是空的，菜单那一项打着勾")
            i.finished(notice: "AI：不该出现")
            check(i.text == "", "没开始过的写收尾：什么都不变")
            i.sawHello(client: "claude-code 2.1.303")
            check(i.text == "Claude Code 已连接" && i.stateName == "connected", "claude-code 的 hello → 「Claude Code 已连接」：\(i.text)")
            for (client, want) in [("Claude-Code 2", "Claude Code"), ("claude-ai 0.1", "Claude"), ("cursor-vscode 1", "AI"),
                                   ("", "AI")] as [(String, String)] {
                i.sawHello(client: client)
                check(i.text == want + " 已连接", "mcp_client「\(client)」→「\(want) 已连接」：\(i.text)")
            }
            i.sawHello(client: nil)
            check(i.text == "AI 已连接", "--mcp-call 没有 initialize → 「AI 已连接」：\(i.text)")
            i.sawHello(client: "claude-code 2.1.303")
            i.began("套模板")
            check(i.text == "AI 正在操作：套模板…" && i.stateName == "working", "写在执行 → 「AI 正在操作：套模板…」：\(i.text)")
            i.sawHello(client: "claude-code 2.1.303")
            check(i.stateName == "working", "在途写的时候又来一个 hello：还是「正在操作」")
            let done = "AI：套了模板「封面 · 刊头大图」· 在拼图页 ⌘Z 撤销"
            i.finished(notice: done)
            check(i.text == done && i.stateName == "just_did", "做成了 → 和那一页的提示同一句话：\(i.text)")
            i.sawHello(client: "claude-code 2.1.303")
            check(i.text == done, "刚做完的那句不被之后的 hello 盖掉")
            i.began("改判")
            i.finished(notice: nil)
            check(i.text == "Claude Code 已连接", "没做成（user_busy、出错、没改出东西）→ 直接回「已连接」：\(i.text)")
            i.setAnotherInstance(true)
            check(i.text == "另一个选片工具正在用这个数据目录：AI 只连那一个", "没拿到锁、另一个实例占着：\(i.text)")
            i.setAnotherInstance(false)
            i.setBridgeEnabled(false)
            check(i.text == "" && !i.bridgeEnabled, "菜单里关了：不显示，那一项没打勾")
            i.setAnotherInstance(true)
            i.began("套模板")
            check(i.text == "", "关着的时候什么都不显示（另一个实例、在途的写也一样）")
            i.finished(notice: done)
            i.setAnotherInstance(false)
            i.setBridgeEnabled(true)
            check(i.text == "" && i.bridgeEnabled, "再打开：不拿关之前的 hello、关着时做完的那句说事（\(i.text)）")
            // 桥停了（§9.2.4）：锁丢了 / 开桥失败排在另一个实例下面、在途的写上面；菜单关了照样不显示
            i.sawHello(client: "claude-code 2.1.303")
            i.setBridgeProblem(.lockLost)
            check(i.text == LiveBridgeNotice.lockLost && i.stateName == "lock_lost", "锁被别的程序拿走了：§9.2.4 那一句：\(i.text)")
            i.began("套模板")
            check(i.stateName == "lock_lost", "锁丢了盖过「正在操作」（关桥之前已经开始的写照样落地，但桥已经停了）")
            i.finished(notice: done)
            check(i.stateName == "lock_lost", "锁丢了盖过「刚做完」")
            i.setAnotherInstance(true)
            check(i.stateName == "another_instance", "另一个实例那一句排在锁丢了上面")
            i.setAnotherInstance(false)
            i.setBridgeEnabled(false)
            check(i.text == "", "菜单关了：锁丢了也不显示（那一项没打勾就是状态）")
            i.setBridgeEnabled(true)
            check(i.stateName == "lock_lost", "再打开菜单：锁丢了那一句又回来（重开 app 才恢复）")
            let failed = "AI 实时操作的连接开不起来（连接建不起来）：已暂停，每 10 秒自动再试"
            i.setBridgeProblem(.failed(failed))
            check(i.text == failed && i.stateName == "bridge_failed", "开桥 / 重新 bind 失败：带原因的那一句：\(i.text)")
            i.sawHello(client: "claude-code 2.1.303")
            i.setBridgeProblem(nil)
            check(i.text == "Claude Code 已连接", "桥开好了：那一句清掉，「已连接」接着显示（来过谁不忘）：\(i.text)")
            i.configure(connectedMs: 0, justDidMs: 0)
            i.sawHello(client: "claude-code 2.1.303")
            check(i.text == "", "超过「已连接」的时长（这里设成 0）→ 淡掉：\(i.text)")
            i.began("改判")
            i.finished(notice: done)
            check(i.text == "", "超过「刚做完」的时长 → 不再显示那句：\(i.text)")
        }
    }

    private static func writeArgChecks(_ check: Check) {
        let k = "0123456789abcdef"
        let op = "op-12345678"
        let cell: [String: Any] = ["path": "01", "index": 0, "text": "第一行，带逗号"]
        // (工具, 参数, 应该过)
        let rows: [(String, [String: Any], Bool)] = [
            ("app_open_session", ["session": k], true),
            ("app_open_session", ["session": k, "confirm": true, "reveal": false, "op_id": op], true),
            ("app_open_session", ["session": k, "op_id": "short"], false),
            ("app_open_session", ["session": k, "op_id": String(repeating: "x", count: 65)], false),
            ("app_open_session", ["session": k, "confirm": "yes"], false),
            ("cull_set_verdicts", ["session": k, "ids": ["a", "b", "a"], "verdict": "auto"], true),
            ("cull_set_verdicts", ["session": k, "ids": ["a"]], false),
            ("cull_set_verdicts", ["session": k, "ids": ["a"], "verdict": "keep"], false),
            ("cull_set_verdicts", ["session": k, "ids": [], "verdict": "pick"], false),
            ("cull_set_verdicts", ["session": k, "ids": (0..<501).map { "p\($0)" }, "verdict": "pick"], false),
            ("cull_set_verdicts", ["session": k, "ids": ["a"], "verdict": "pick", "inline": true], false),
            ("cull_show_photos", ["session": k, "ids": ["a"], "mode": "focus", "reveal": false], true),
            ("cull_show_photos", ["session": k, "ids": ["a"], "op_id": op], false),
            ("cull_show_photos", ["session": k, "ids": (0..<201).map { "p\($0)" }], false),
            ("collage_apply_template", ["session": k, "template": "时尚刊", "if_digest": "", "inline": false], true),
            ("collage_apply_template", ["session": k], false),
            ("collage_apply_template", ["session": k, "template": ""], false),
            ("collage_apply_template", ["session": k, "template": String(repeating: "字", count: 81)], false),
            ("collage_run_kit", ["session": k, "kit": "fashionIssue", "deadline_seconds": 50], true),
            ("collage_run_kit", ["session": k, "kit": "magazine"], false),
            ("collage_next_cover", ["session": k], true),
            ("collage_next_cover", ["session": k, "steps": 21], false),
            ("collage_set_text", ["session": k, "title": ""], true),
            ("collage_set_text", ["session": k, "masthead": String(repeating: "M", count: 41)], false),
            ("collage_set_text", ["session": k], false),
            ("collage_set_text", ["session": k, "cell_text": cell], false),
            ("collage_set_text", ["session": k, "cell_text": cell, "if_digest": "abc"], true),
            ("collage_set_text", ["session": k, "cell_text": ["path": "0a", "index": 0, "text": "x"], "if_digest": "abc"], false),
            ("collage_set_text", ["session": k, "cell_text": ["path": "", "index": -1, "text": "x"], "if_digest": "abc"], false),
            ("collage_set_text", ["session": k, "cell_text": ["path": "0", "index": 0, "text": String(repeating: "字", count: 120)],
                                  "if_digest": "abc"], true),
            ("collage_set_text", ["session": k, "cell_text": ["path": "0", "index": 0, "text": String(repeating: "字", count: 121)],
                                  "if_digest": "abc"], false),
            ("collage_set_text", ["session": k, "cell_text": ["path": "", "index": 0, "text": "x", "extra": 1], "if_digest": "a"], false),
            ("collage_set_style", ["session": k, "look_strength": 0.5], true),
            ("collage_set_style", ["session": k, "look_strength": 1], true),
            ("collage_set_style", ["session": k, "look_strength": 1.5], false),
            ("collage_set_style", ["session": k, "look_strength": true], false),
            ("collage_set_style", ["session": k, "style": "no-such-style"], false),
            ("collage_set_style", ["session": k], false),
            ("app_undo", ["target": "collage"], true),
            ("app_undo", ["target": "verdicts", "session": k, "op_id": op], true),
            ("app_undo", [:], false),
            ("app_undo", ["target": "both"], false),
        ]
        for (tool, args, ok) in rows {
            let problem = MCPArgs.check(tool, args, deadlineCap: 600)
            check((problem == nil) == ok, "\(tool) \(MCPJSON.string(args).prefix(120))：期望\(ok ? "过" : "不过")，实际 \(problem?.message ?? "过")")
        }
        let first = MCPToolDefs.styleKeys.first ?? ""
        check(MCPArgs.check("collage_set_style", ["style": first, "look": MCPToolDefs.lookKeys.first ?? ""]) == nil,
              "style / look 的 enum 取自 CollageStyles.all、CollageLook")
    }

    private static func undoChecks(_ check: Check) {
        func code(_ c: LiveAILog.UndoCheck) -> String {
            switch c {
            case .ok: return "ok"
            case .notOurs: return "undo_not_ours"
            case .nothing(let why): return why
            case .userUndid: return "already_undone_by_user"
            }
        }
        // 1. AI 写了一步（push 5 → 6，深度 3）：能撤；撤完再撤 → already_undone
        var log = LiveAILog()
        check(code(log.check(.collage, pushes: 5, depth: 2)) == "no_ai_step", "AI 还没写过 → no_ai_step")
        log.recordWrite(.collage, op: "a", tool: "t", before: 5, after: 6, depth: 3)
        check(code(log.check(.collage, pushes: 6, depth: 3)) == "ok", "AI 刚写的一步能撤")
        check(code(log.check(.verdicts, pushes: 6, depth: 3)) == "no_ai_step", "判决和拼图分开记")
        check(code(log.check(.collage, pushes: 7, depth: 4)) == "undo_not_ours", "用户之后又改过 → undo_not_ours")
        check(code(log.check(.collage, pushes: 6, depth: 2)) == "already_undone_by_user", "用户自己撤过 → already_undone_by_user")
        log.markUndone(.collage, 0)
        check(code(log.check(.collage, pushes: 6, depth: 2)) == "already_undone", "AI 撤过以后再撤 → already_undone")
        // 2. 没改出东西的写（空步撤掉了，计数 +1）：不挡后面的撤销；用户先改过的话不算进 AI 那一步
        log = LiveAILog()
        log.recordWrite(.collage, op: "a", tool: "t", before: 0, after: 1, depth: 1)
        log.recordNoop(.collage, before: 1, after: 2)
        check(code(log.check(.collage, pushes: 2, depth: 1)) == "ok", "AI 写了一步、又一次没改出东西：照样能撤上一步")
        log.recordNoop(.collage, before: 3, after: 4)
        check(code(log.check(.collage, pushes: 4, depth: 2)) == "undo_not_ours", "用户改过以后 AI 没改出东西：不算 AI 的，undo_not_ours")
        // 3. 连撤两步：中间没插用户的改动才行
        log = LiveAILog()
        log.recordWrite(.verdicts, op: "a", tool: "t", before: 0, after: 1, depth: 1)
        log.recordWrite(.verdicts, op: "b", tool: "t", before: 1, after: 2, depth: 2)
        guard case .ok(let top) = log.check(.verdicts, pushes: 2, depth: 2) else {
            check(false, "两步都是 AI 的：最上面那步能撤")
            return
        }
        check(log.entry(.verdicts, top)?.opID == "b", "先撤最近的那一步")
        log.markUndone(.verdicts, top)
        check(code(log.check(.verdicts, pushes: 2, depth: 1)) == "ok", "AI 撤了 b 以后接着撤 a")
        log = LiveAILog()
        log.recordWrite(.verdicts, op: "a", tool: "t", before: 0, after: 1, depth: 1)
        log.recordWrite(.verdicts, op: "b", tool: "t", before: 2, after: 3, depth: 3)
        log.markUndone(.verdicts, 1)
        check(code(log.check(.verdicts, pushes: 3, depth: 2)) == "undo_not_ours", "a 和 b 之间插着用户的一步：撤完 b 不能再撤 a")
        // 4. 场次换过
        log = LiveAILog()
        log.recordWrite(.collage, op: "a", tool: "t", before: 0, after: 1, depth: 1)
        log.sessionEpoch += 1
        check(code(log.check(.collage, pushes: 1, depth: 1)) == "session_switched", "换过场次 → session_switched")
        check(!log.canUndo(.collage, pushes: 1, depth: 1), "top_is_ai 和 app_undo 同一个判断")
    }

    private static func busyChecks(_ check: Check) {
        typealias R = LiveInteraction.Reason
        // §9.6b 的表：原因 → 挡哪些写（拼图 / 判决 / 切场次 / 定位）
        let table: [(R, [Bool])] = [
            (.pointer, [true, true, true, true]), (.typing, [true, true, true, true]), (.composing, [true, true, true, true]),
            (.menu, [true, true, true, true]), (.modal, [true, true, true, true]),
            (.dragging, [true, false, false, false]), (.continuousEdit, [true, false, false, false]),
            (.cropEditing, [true, false, false, false]), (.exporting, [true, false, false, false]),
            (.batchSheet, [false, true, true, true]), (.pickSession, [false, true, true, true]),
            (.batchViewing, [false, false, true, true]),
        ]
        let scopes: [LiveInteraction.Scope] = [.collage, .verdicts, .session, .show]
        check(table.count == R.allCases.count, "忙信号的每个原因都在表里")
        for (reason, want) in table {
            let got = scopes.map { LiveInteraction.blocks(reason, $0) }
            check(got == want, "\(reason.rawValue) 挡的写：期望 \(want)，实际 \(got)")
        }
        let transient: Set<R> = [.pointer, .dragging, .typing, .composing, .menu, .continuousEdit]
        for r in R.allCases {
            check(r.transient == transient.contains(r), "\(r.rawValue) 是\(transient.contains(r) ? "一时" : "一直")的原因")
        }
    }
}
