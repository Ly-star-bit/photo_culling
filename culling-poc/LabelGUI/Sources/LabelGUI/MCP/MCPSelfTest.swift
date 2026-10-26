import Foundation

/// `LabelGUI --mcp-selftest [--json]`：MCP 这一层几个纯函数的自检，不起服务器、不读写任何文件。
/// 1. 不开界面的闸（NoGUIGate.decide）：拼错的参数、单横线、长短破折号、前面多空格、serve、没有参数……
///    × 父进程是不是 launchd × stdin 是不是终端 × LABELGUI_NO_GUI × LABELGUI_ALLOW_GUI × 两道闸。
///    反向用例只拿假的 argv / ppid / tty 喂给纯函数，绝不真的起一个可能开界面的进程。
///    期望值不是拿同一段代码算的：每一行手写「argv[1] 算不算拼错」「有没有无头参数」，再按 §10.5 的规则推。
///    --json 时每一行判断打一行 JSON（mcp_smoke.py 用自己的一份规则再核一遍）。
/// 2. MCPJSON：NaN / inf → null、不转义斜杠、键排序、编不了不抛异常、超长截断。
/// 3. MCPServerMain.mode：只认整个参数相等的 --mcp / --mcp-tools / --mcp-call。
/// 4. 工具定义：18 个 / 3 个、顺序、schema 规则（§3.0）、enum 和代码里的名单一致、没有漏填的占位。
enum MCPSelfTest {
    private struct Variant {
        let label: String
        let args: [String]
        /// argv[1] 算拼错（不管别的条件都不开界面）。
        let typo: Bool
        /// argv 里有写对的无头参数（第一道闸放行）。
        let headless: Bool
    }

    private static let variants: [Variant] = [
        Variant(label: "no-args", args: [], typo: false, headless: false),
        Variant(label: "--mcp", args: ["--mcp"], typo: false, headless: true),
        Variant(label: "--mcp-call", args: ["--mcp-call", "app_status", "{}"], typo: false, headless: true),
        Variant(label: "--collage-ui", args: ["--collage-ui", "/p", "/o.png"], typo: false, headless: true),
        Variant(label: "-mcp", args: ["-mcp"], typo: true, headless: false),
        Variant(label: "mcp", args: ["mcp"], typo: true, headless: false),
        Variant(label: "em-dash-mcp", args: ["—mcp"], typo: true, headless: false),
        Variant(label: "en-dash-mcp", args: ["–mcp"], typo: true, headless: false),
        Variant(label: "double-em-dash-mcp", args: ["——mcp"], typo: true, headless: false),
        Variant(label: "fullwidth-mcp", args: ["－－mcp"], typo: true, headless: false),
        Variant(label: "space-mcp", args: [" --mcp"], typo: true, headless: false),
        Variant(label: "mcp-trailing-space", args: ["--mcp "], typo: true, headless: false),
        Variant(label: "MCP-upper", args: ["--MCP"], typo: true, headless: false),
        Variant(label: "mcp-server", args: ["mcp-server"], typo: true, headless: false),
        Variant(label: "--mcp-server", args: ["--mcp-server"], typo: true, headless: false),
        Variant(label: "-collage-ui", args: ["-collage-ui", "/p", "/o.png"], typo: true, headless: false),
        Variant(label: "em-dash-app-ui", args: ["—app-ui", "/p", "/o.png"], typo: true, headless: false),
        Variant(label: "app-ui", args: ["app-ui"], typo: true, headless: false),
        Variant(label: "serve", args: ["serve"], typo: false, headless: false),
        Variant(label: "--bogus", args: ["--bogus"], typo: false, headless: false),
        Variant(label: "-NSDocumentRevisionsDebugMode", args: ["-NSDocumentRevisionsDebugMode", "YES"], typo: false, headless: false),
        Variant(label: "-psn", args: ["-psn_0_12345"], typo: false, headless: false),
        Variant(label: "photo-dir", args: ["/Users/x/Pictures/20261021"], typo: false, headless: false),
        Variant(label: "title-mcp", args: ["--collage", "/p", "--title", "mcp"], typo: false, headless: true),
    ]

    static func run() -> Never {
        var total = 0
        var failures: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            total += 1
            if !ok { failures.append(what()) }
        }
        let dump = CommandLine.arguments.contains("--json")

        // 1. 不开界面的闸
        var gateRows = 0
        for v in variants {
            for ppid: pid_t in [1, 4242] {
                for tty in [true, false] {
                    for noGUI in [false, true] {
                        for allowGUI in [false, true] {
                            for stage in [NoGUIGate.Stage.early, .last] {
                                var env: [String: String] = [:]
                                if noGUI { env["LABELGUI_NO_GUI"] = "1" }
                                if allowGUI { env["LABELGUI_ALLOW_GUI"] = "1" }
                                let actual = NoGUIGate.decide(stage: stage, argv: ["LabelGUI"] + v.args, env: env,
                                                              ppid: ppid, stdinIsTTY: tty)
                                let expectProceed = expected(v, stage: stage, ppid: ppid, tty: tty, noGUI: noGUI, allowGUI: allowGUI)
                                let proceeded = actual == .proceed
                                check(proceeded == expectProceed,
                                      "闸 \(stage.rawValue) \(v.label) ppid=\(ppid) tty=\(tty) NO_GUI=\(noGUI) ALLOW_GUI=\(allowGUI)：期望 \(expectProceed ? "放行" : "拦下")，实际 \(proceeded ? "放行" : "拦下")")
                                gateRows += 1
                                if dump {
                                    var row: [String: Any] = ["label": v.label, "argv": v.args, "ppid": Int(ppid), "tty": tty]
                                    row["no_gui"] = noGUI
                                    row["allow_gui"] = allowGUI
                                    row["stage"] = stage.rawValue
                                    row["decision"] = proceeded ? "proceed" : "refuse"
                                    if case .refuse(let why) = actual { row["message"] = why }
                                    print(MCPJSON.string(row))
                                }
                            }
                        }
                    }
                }
            }
        }

        // 2. MCPJSON
        let messy: [String: Any] = ["z": Double.nan, "b": [1.5, Double.infinity, -Double.infinity] as [Any],
                                    "path": "/Users/x/a.jpg", "flag": true, "n": 3, "none": Optional<Int>.none as Any]
        let text = MCPJSON.string(messy)
        check(!text.contains("\\/"), "MCPJSON 转义了斜杠：\(text)")
        let back = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        check(back["z"] is NSNull, "NaN 没变成 null：\(text)")
        check((back["b"] as? [Any])?.dropFirst().allSatisfy({ $0 is NSNull }) == true, "±inf 没变成 null：\(text)")
        check(back["none"] is NSNull, "nil 没变成 null：\(text)")
        check(back["path"] as? String == "/Users/x/a.jpg", "路径变了：\(text)")
        check(MCPJSON.string(["b": 1, "a": 2]) == #"{"a":2,"b":1}"#, "键没排序")
        check(MCPJSON.data(["when": Date()]) == nil, "编不了的值应该回 nil")
        let rows = (0..<200).map { i in String(repeating: "x", count: 40) + "\(i)" }
        let cut = MCPJSON.fitting(["rows": rows, "total": rows.count], list: "rows", limit: 2_000)
        let cutBack = (try? JSONSerialization.jsonObject(with: Data(cut.utf8))) as? [String: Any] ?? [:]
        let kept = (cutBack["rows"] as? [Any])?.count ?? -1
        check(cut.count <= 2_000 && cutBack["truncated"] as? Bool == true && kept > 0,
              "截断不对：\(cut.count) 字、留 \(kept) 条")
        let oneMore = MCPJSON.string(["rows": Array(rows.prefix(kept + 1)), "total": rows.count, "truncated": true])
        check(oneMore.count > 2_000, "截断留少了：多留一条也放得下")

        // 3. 入口参数
        check(MCPServerMain.mode(["L", "--mcp"]) == .server, "--mcp")
        check(MCPServerMain.mode(["L", "--mcp-tools"]) == .tools, "--mcp-tools")
        check(MCPServerMain.mode(["L", "--mcp-call", "app_status", "{}"]) == .call(1), "--mcp-call")
        for wrong in [["L"], ["L", "-mcp"], ["L", "mcp"], ["L", "—mcp"], ["L", " --mcp"], ["L", "--mcp-selftest"], ["L", "--collage-ui", "a", "b"]] {
            check(MCPServerMain.mode(wrong) == nil, "不该当成 MCP 入口：\(wrong)")
        }

        // 4. 工具定义
        let liveNames = MCPToolDefs.tools(live: true).compactMap { $0["name"] as? String }
        let expectNames = ["app_status", "cull_list_sessions", "collage_list_templates", "cull_session_overview",
                           "cull_list_photos", "cull_get_photos", "cull_list_groups", "cull_preview_photos",
                           "collage_get_state", "app_open_session", "cull_set_verdicts", "cull_show_photos",
                           "collage_apply_template", "collage_run_kit", "collage_next_cover", "collage_set_text",
                           "collage_set_style", "app_undo"]
        check(liveNames == expectNames, "18 个工具的名字或顺序不对：\(liveNames)")
        let disabledNames = MCPToolDefs.tools(live: false).compactMap { $0["name"] as? String }
        check(disabledNames == MCPToolDefs.alwaysAvailable, "LABELGUI_MCP_LIVE=0 时应该只有 3 个：\(disabledNames)")
        for live in [true, false] {
            for def in MCPToolDefs.tools(live: live) {
                let name = def["name"] as? String ?? "?"
                check(def["description_disabled"] == nil, "\(name) 漏出了 description_disabled")
                check((def["description"] as? String ?? "").count <= 2_000, "\(name) 描述超过 2000 字")
                let schema = def["inputSchema"] as? [String: Any] ?? [:]
                check(schema["type"] as? String == "object" && schema["additionalProperties"] as? Bool == false,
                      "\(name) 的 schema 根部要是 object + additionalProperties:false")
                check(schema["anyOf"] == nil && schema["oneOf"] == nil && schema["allOf"] == nil, "\(name) 根部不能有 anyOf/oneOf/allOf")
                for (prop, spec) in schema["properties"] as? [String: Any] ?? [:] {
                    let s = spec as? [String: Any] ?? [:]
                    check(s["type"] is String, "\(name).\(prop) 没写 type")
                    if s["type"] as? String == "array" {
                        check((s["items"] as? [String: Any])?["type"] is String, "\(name).\(prop) 的 items 没写 type")
                    }
                }
                let flat = MCPJSON.string(def)
                check(!flat.contains("\"$") && !flat.contains("{{"), "\(name) 有没填的占位：\(flat.prefix(200))")
            }
        }
        func enumOf(_ tool: String, _ prop: String) -> [String] {
            let def = MCPToolDefs.tools(live: true).first { $0["name"] as? String == tool } ?? [:]
            let props = (def["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            return (props[prop] as? [String: Any])?["enum"] as? [String] ?? []
        }
        check(enumOf("collage_set_style", "style") == CollageStyles.all.map(\.key), "style enum 和 CollageStyles.all 不一致")
        check(enumOf("collage_set_style", "look") == CollageLook.allCases.map(\.rawValue), "look enum 和 CollageLook 不一致")
        check(enumOf("collage_run_kit", "kit") == CollageKitID.allCases.map(\.rawValue), "kit enum 和 CollageKitID 不一致")
        for live in [true, false] {
            let instructions = MCPToolDefs.instructions(live: live)
            let first = instructions.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            check(instructions.count <= 4_096 && first.count <= 512, "instructions 超长（全文 \(instructions.count)，第一段 \(first.count)）")
        }

        for f in failures { print("FAIL " + f) }
        if failures.isEmpty {
            print("MCP 自检：\(total) 条检查全部通过（不开界面的闸 \(gateRows) 种组合）")
            exit(0)
        }
        print("MCP 自检：\(failures.count)/\(total) 条失败")
        exit(1)
    }

    /// §10.5 的规则，照字面写：拼错 → 两道闸都拦；第一道闸见到写对的无头参数就放行；
    /// 之后 LABELGUI_NO_GUI=1 → 拦；父进程不是 launchd、stdin 不是终端、没设 LABELGUI_ALLOW_GUI=1 → 拦。
    private static func expected(_ v: Variant, stage: NoGUIGate.Stage, ppid: pid_t, tty: Bool, noGUI: Bool, allowGUI: Bool) -> Bool {
        if v.typo { return false }
        if stage == .early && v.headless { return true }
        if noGUI { return false }
        if ppid != 1 && !tty && !allowGUI { return false }
        return true
    }
}
