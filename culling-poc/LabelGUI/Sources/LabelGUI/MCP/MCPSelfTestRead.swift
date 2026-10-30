import Foundation

/// --mcp-selftest 的 STEP 3a 部分（MCPSelfTest.run 调），全是纯函数，不连 socket、不碰文件：
/// 12. 要 app 的 15 个工具的参数校验（MCPArgs）和 tools/list 里的 schema 对得上；读工具一张手写的对 / 错表
///     （写工具的那张在 MCPSelfTestWrite.swift）。
/// 13. cursor（§10.4）：编码、解码、换了条件 / 场次 / 工具都不认；base64url 里没有 + / =。
/// 14. 输出目录（§10.3）：服务器起的文件名都认得出、用户的文件名都不认；id 里的 / 和开头的 . 进不了文件名。
/// 15. 图片字节的核对（FF D8、长度；全都不对回 internal）；text 截断时 next_cursor 跟着改、一条就超也给一条；
///     3 位小数溢出成 inf 时编码成 null。
extension MCPSelfTest {
    static func readChecks(_ check: Check) {
        argChecks(check)
        cursorChecks(check)
        outputChecks(check)
        bytesChecks(check)
    }

    private static func argChecks(_ check: Check) {
        let defs = MCPToolDefs.tools(live: true)
        for (tool, spec) in MCPArgs.specs {
            let def = defs.first { $0["name"] as? String == tool } ?? [:]
            let schema = def["inputSchema"] as? [String: Any] ?? [:]
            let props = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
            check(props == Set(spec.props.keys), "\(tool)：MCPArgs 认的参数 \(spec.props.keys.sorted()) 和 schema \(props.sorted()) 不一样")
            let required = Set(schema["required"] as? [String] ?? []).subtracting(["session"])
            check(required == Set(spec.required), "\(tool)：必填 \(spec.required) 和 schema \(required.sorted()) 不一样")
        }
        check(Set(MCPArgs.specs.keys) == Set(MCPLiveTools.routes.keys), "MCPArgs 管的正好是要 app 的 15 个工具")
        check(MCPLiveTools.wired == Set(MCPLiveTools.routes.values.map(\.method)) && MCPLiveTools.wired.count == 12,
              "接上的桥方法是 §10.4 的 12 个：\(MCPLiveTools.wired.sorted())")
        check(Set(MCPLiveTools.readKinds.keys) == Set(MCPLiveTools.routes.filter { $0.value.method == "cull.read" }.keys),
              "cull.read 的四个工具都有 kind")
        let k = "0123456789abcdef"
        // (工具, 参数, 应该过)
        let rows: [(String, [String: Any], Bool)] = [
            ("cull_session_overview", ["session": k], true),
            ("cull_session_overview", ["session": k, "dedupe": true], false),
            ("cull_session_overview", ["session": ""], false),
            ("cull_list_photos", ["session": k, "verdict": ["pick", "reject", "pick"], "limit": 100, "sort": "sharpness"], true),
            ("cull_list_photos", ["session": k, "verdict": ["good"]], false),
            ("cull_list_photos", ["session": k, "limit": 0], false),
            ("cull_list_photos", ["session": k, "limit": 101], false),
            ("cull_list_photos", ["session": k, "limit": true], false),
            ("cull_list_photos", ["session": k, "limit": 2.5], false),
            ("cull_list_photos", ["session": k, "chapter": -1], false),
            ("cull_list_photos", ["session": k, "manual_only": 1], false),
            ("cull_list_photos", ["session": k, "reason": String(repeating: "闭", count: 41)], false),
            ("cull_list_photos", ["session": k, "cursor": NSNull()], true),
            ("cull_get_photos", ["session": k, "ids": ["a"]], true),
            ("cull_get_photos", ["session": k], false),
            ("cull_get_photos", ["session": k, "ids": []], false),
            ("cull_get_photos", ["session": k, "ids": Array(repeating: "a", count: 25)], true),
            ("cull_get_photos", ["session": k, "ids": (0..<21).map { "p\($0)" }], false),
            ("cull_get_photos", ["session": k, "ids": [1]], false),
            ("cull_list_groups", ["session": k, "kind": "scene", "min_size": 1], true),
            ("cull_list_groups", ["session": k, "kind": "take"], false),
            ("cull_list_groups", ["session": k], false),
            ("cull_preview_photos", ["session": k, "ids": ["a", "b", "c", "d"], "crop": "face", "max_edge": 1568, "inline": false,
                                     "deadline_seconds": 30], true),
            ("cull_preview_photos", ["session": k, "ids": ["a", "b", "c", "d", "e"]], false),
            ("cull_preview_photos", ["session": k, "ids": ["a"], "max_edge": 255], false),
            ("cull_preview_photos", ["session": k, "ids": ["a"], "max_edge": 1569], false),
            ("cull_preview_photos", ["session": k, "ids": ["a"], "crop": "eyes"], false),
            ("cull_preview_photos", ["session": k, "ids": ["a"], "deadline_seconds": 4], false),
            ("cull_preview_photos", ["session": k, "ids": ["a"], "deadline_seconds": 601], false),
            ("collage_get_state", [:], true),
            ("collage_get_state", ["max_edge": 1024, "include_preview": false], true),
            ("collage_get_state", ["max_edge": 1025], false),
            ("collage_get_state", ["inline": "yes"], false),
        ]
        for (tool, args, ok) in rows {
            let problem = MCPArgs.check(tool, args, deadlineCap: 600)
            check((problem == nil) == ok, "\(tool) \(MCPJSON.string(args).prefix(120))：期望\(ok ? "过" : "不过")，实际 \(problem?.message ?? "过")")
        }
        // deadline_seconds 的上限跟着 LABELGUI_MCP_DEADLINE_SEC（`--mcp` 一侧传进来）
        check(MCPArgs.check("cull_preview_photos", ["ids": ["a"], "deadline_seconds": 60], deadlineCap: 50) != nil,
              "deadline_seconds 超过 LABELGUI_MCP_DEADLINE_SEC 要拦")
        check(MCPArgs.uniqueStrings(["b", "a", "b", 3, "a"]) == ["b", "a"], "ids 去重保持顺序、不是字符串的丢掉")
    }

    private static func cursorChecks(_ check: Check) {
        let p = MCPCursor.Payload(offset: 35, kind: "photos", session: "0123456789abcdef", filter: "abcdefabcdef", state: "0f0f0f0f0f0f")
        let c = MCPCursor.encode(p)
        check(MCPCursor.parse(c) == p, "cursor 编了再解回来一样")
        check(!c.contains("+") && !c.contains("/") && !c.contains("=") && c.utf8.count <= 512, "cursor 是 base64url、不带 =、≤ 512：\(c)")
        check(MCPCursor.parse("garbage!") == nil && MCPCursor.parse("") == nil && MCPCursor.parse(String(c.dropLast(3))) == nil,
              "坏的 cursor 解不出来")
        func code(_ r: Result<MCPCursor.Payload, MCPReadModel.Failure>) -> String {
            switch r {
            case .success: return "ok"
            case .failure(let f): return f.code + ":" + f.message.prefix(8)
            }
        }
        check(code(MCPCursor.decode(c, kind: "photos", session: p.session, filter: p.filter)) == "ok", "同一个工具、同一场、同样的条件：认")
        for (kind, session, filter, why) in [("groups", p.session, p.filter, "换了工具"), ("photos", "fedcba9876543210", p.filter, "换了场次"),
                                             ("photos", p.session, "000000000000", "换了筛选条件")] {
            check(code(MCPCursor.decode(c, kind: kind, session: session, filter: filter)).hasPrefix("invalid_argument"), "cursor \(why)：invalid_argument")
        }
        let neg = MCPCursor.encode(MCPCursor.Payload(offset: -1, kind: "photos", session: p.session, filter: p.filter, state: p.state))
        check(MCPCursor.parse(neg) == nil, "offset 是负数的 cursor 不认")
        check(MCPCursor.sha1("", length: 12) == "da39a3ee5e6b", "SHA-1 前 12 位（空串）")
    }

    private static func outputChecks(_ check: Check) {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        for (id, edge, face) in [("DSCF7208", 1024, false), ("IMG_0001.HEIC", 768, true), ("../../etc/passwd", 256, false),
                                 (".hidden", 1568, true), ("照片 一", 512, false), (String(repeating: "x", count: 300), 768, false), ("", 768, false)] {
            let name = MCPOutput.previewName(sha: sha, id: id, edge: edge, face: face)
            check(MCPOutput.isServerName(name) && !name.contains("/") && !name.hasPrefix("."), "预览文件名 \(name) 认得出、没有 / 也不是 . 开头")
        }
        check(MCPOutput.previewName(sha: sha, id: "DSCF7208", edge: 1024, face: true) == "0123456789abcdef-DSCF7208-1024-face.jpg",
              "文件名格式：<sha1 前 16>-<id>-<长边>-<face|full>.jpg")
        check(MCPOutput.safeID("../x") == "_x" && MCPOutput.safeID("a/b") == "a_b" && MCPOutput.safeID("...") == "photo",
              "id 里的 / 换成 _，开头的 . 去掉")
        check(MCPOutput.isServerName(MCPOutput.collageName(sha: sha)), "拼图预览的文件名认得出")
        for user in ["my-notes.jpg", "IMG_0001.jpg", "0123456789abcdef.jpg", "0123456789ABCDEF-x-768-full.jpg",
                     "0123456789abcdef-x-768-full.jpeg", "0123456789abcdef-x-768-full.jpg.bak", ".xuanpian-mcp",
                     "0123456789abcdef-collage.png", "0123456789abcdef-a/b-768-full.jpg"] {
            check(!MCPOutput.isServerName(user), "\(user) 不是服务器起的名字（清理不删）")
        }
        check(MCPOutput.isKey("0123456789abcdef") && !MCPOutput.isKey("0123456789ABCDEF") && !MCPOutput.isKey("not-a-key")
              && !MCPOutput.isKey("0123456789abcdef0"), "previews/<key>/ 只认 16 位小写十六进制")
        check(MCPOutput.inside("/a/b/c", "/a/b") && MCPOutput.inside("/a/b", "/a/b") && !MCPOutput.inside("/a/bc", "/a/b")
              && MCPOutput.inside("/a/b/c", "/a/b/"), "「在里面」按路径段比（/a/bc 不在 /a/b 里）")
    }

    private static func bytesChecks(_ check: Check) {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let b64 = jpeg.base64EncodedString()
        check(MCPLiveTools.jpeg(b64, bytes: jpeg.count) == jpeg, "完整的 JPEG 字节：收")
        check(MCPLiveTools.jpeg(b64, bytes: jpeg.count + 1) == nil, "长度和 bytes 对不上：丢")
        check(MCPLiveTools.jpeg(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(), bytes: 4) == nil, "不是 FF D8 开头（PNG）：丢")
        check(MCPLiveTools.jpeg("@@@", bytes: 3) == nil && MCPLiveTools.jpeg(nil, bytes: 0) == nil, "不是 base64：丢")
        check(MCPLiveTools.jpeg(b64, bytes: true) == nil, "bytes 不是整数：丢")
        // text 截断（§3.0）：app 那一侧按 text 上限截列表，next_cursor 跟着截到的条数走
        let rows: [[String: Any]] = (0..<50).map { ["id": "DSCF\(7000 + $0)", "note": String(repeating: "x", count: 80)] }
        let fitted = MCPJSON.fittingObject(["rows": rows, "next_cursor": NSNull()], list: "rows", limit: 2_000) { o, kept in
            o["truncated"] = true
            o["next_cursor"] = "after-\(kept)"
        }
        let kept = (fitted["rows"] as? [Any])?.count ?? -1
        check(kept > 0 && kept < 50 && fitted["next_cursor"] as? String == "after-\(kept)" && MCPJSON.string(fitted).count <= 2_000,
              "text 超了：截到 \(kept) 条，next_cursor 跟着改，编出来 ≤ 2000 字")
        let small: [String: Any] = ["rows": [["id": "a"]]]
        check(MCPJSON.fittingObject(small, list: "rows", limit: 2_000) { o, _ in o["truncated"] = true }["truncated"] == nil,
              "放得下就原样交回")
        // 一条就超了上限：也给这一条，next_cursor 往前走（给 0 条的话模型照着翻永远翻不完）
        let huge: [[String: Any]] = (0..<3).map { ["id": "G\($0)", "faces_detail": String(repeating: "f", count: 900)] }
        let one = MCPJSON.fittingObject(["rows": huge, "next_cursor": NSNull()], list: "rows", limit: 500) { o, kept in
            o["truncated"] = true
            o["next_cursor"] = "after-\(kept)"
        }
        check((one["rows"] as? [Any])?.count == 1 && one["next_cursor"] as? String == "after-1",
              "一条就超了上限：还是给 1 条，next_cursor 是 after-1（\(one["next_cursor"] ?? "nil")）")
        let single = MCPJSON.fittingObject(["photos": Array(huge.prefix(1))], list: "photos", limit: 500) { o, _ in o["truncated"] = true }
        check((single["photos"] as? [Any])?.count == 1 && single["truncated"] == nil, "只有一条又超了：原样交回，不标截断")
        // app 给的图片全都核对不过：internal，不存文件（这条路径不碰输出目录）
        let bad = MCPLiveTools.previewResult(["images": [["id": "A", "jpeg_b64": Data([0x89, 0x50]).base64EncodedString(), "bytes": 2],
                                                         ["id": "B", "jpeg_b64": b64, "bytes": jpeg.count + 5]]],
                                             session: "0123456789abcdef", face: false, inline: true)
        let badText = bad.content.first?["text"] as? String ?? ""
        check(bad.isError && badText.contains(#""code":"internal""#) && bad.content.count == 1,
              "图片字节全都不对：internal，没有 image 块（\(badText.prefix(80))）")
        check(MCPJSON.string(["x": MCPReadModel.r3(1.7976931348623157e308), "y": MCPReadModel.r3(0.4996)]) == #"{"x":null,"y":0.5}"#,
              "3 位小数：溢出成 inf 的编成 null，其余四舍五入")
    }
}
