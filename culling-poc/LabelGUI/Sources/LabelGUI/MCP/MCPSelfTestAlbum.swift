import Foundation

/// --mcp-selftest 的相册整本部分（相册 A + B 第 2 波 · M；MCPSelfTest.run 调），全是纯函数，不连 socket、不建 store：
/// 25. 6 个新工具和并进旧工具的参数（collage_get_state 的 candidates_for、collage_export 的 pages / proof）：一张手写的
///     过 / 不过表，含 schema 写不出来的那几条（每个 action 认哪几个参数、spine_mm 和 spine_auto 二选一……）。
/// 26. 工具定义：排在 25–30、只有 collage_preflight 只读、都不是 destructive、描述里写了编辑封面时怎么办；路由（读 / 写、截止时间）。
/// 27. 桥上用的纯函数：跨页号的范围（不给 = 当前跨页）、move 的 to → onMove 的 destination（逐个对 CollageAlbum.moved）、
///     导出前检查的一条怎么写（snake_case、跨页号从 1 起、路径）、拦和提醒分开、导出按钮会不会问、印厂规格的页数摘要、候选的理由。
extension MCPSelfTest {
    static func albumChecks(_ check: Check) {
        albumArgChecks(check)
        albumDefChecks(check)
        albumHelperChecks(check)
    }

    private static func albumArgChecks(_ check: Check) {
        let k = "0123456789abcdef"
        let op = "op-12345678"
        // (工具, 参数, 应该过)
        let rows: [(String, [String: Any], Bool)] = [
            ("collage_pages", ["session": k, "action": "go", "page": 3], true),
            ("collage_pages", ["session": k, "action": "go"], false),
            ("collage_pages", ["session": k, "action": "go", "page": 0], false),
            ("collage_pages", ["session": k, "action": "go", "page": 2, "pages": "3"], false),
            ("collage_pages", ["session": k, "action": "add"], true),
            ("collage_pages", ["session": k, "action": "add", "page": 4, "reveal": true, "op_id": op], true),
            ("collage_pages", ["session": k, "action": "add", "to": 2], false),
            ("collage_pages", ["session": k, "action": "delete", "pages": "1-3, 7"], true),
            ("collage_pages", ["session": k, "action": "delete"], true),
            ("collage_pages", ["session": k, "action": "delete", "page": 2], false),
            ("collage_pages", ["session": k, "action": "delete", "pages": ""], false),
            ("collage_pages", ["session": k, "action": "move", "pages": "25", "to": 3], true),
            ("collage_pages", ["session": k, "action": "move", "pages": "25"], false),
            ("collage_pages", ["session": k, "action": "move", "to": 1000], false),
            ("collage_pages", ["session": k, "action": "lock", "pages": "2;4"], true),
            ("collage_pages", ["session": k, "action": "unlock", "if_digest": "abc", "inline": false], true),
            ("collage_pages", ["session": k, "action": "mirror", "pages": "5", "deadline_seconds": 30], true),
            ("collage_pages", ["session": k, "action": "mirror", "side": "left"], false),
            ("collage_pages", ["session": k, "action": "side_layout", "side": "left"], true),
            ("collage_pages", ["session": k, "action": "side_layout", "side": "right", "step": -1, "page": 2], true),
            ("collage_pages", ["session": k, "action": "side_layout"], false),
            ("collage_pages", ["session": k, "action": "side_layout", "side": "top"], false),
            ("collage_pages", ["session": k, "action": "side_layout", "side": "left", "step": 0], false),
            ("collage_pages", ["session": k, "action": "side_layout", "side": "left", "step": 21], false),
            ("collage_pages", ["session": k, "action": "side_layout", "side": "left", "pages": "2"], false),
            ("collage_pages", ["session": k, "action": "jump", "page": 1], false),
            ("collage_pages", ["session": k], false),
            ("collage_move_photos", ["session": k, "photos": ["a", "b"], "to": 5], true),
            ("collage_move_photos", ["session": k, "photos": ["a"], "to": 1, "deadline_seconds": 60, "if_digest": "x"], true),
            ("collage_move_photos", ["session": k, "photos": ["a"]], false),
            ("collage_move_photos", ["session": k, "to": 2], false),
            ("collage_move_photos", ["session": k, "photos": [], "to": 2], false),
            ("collage_move_photos", ["session": k, "photos": (0..<37).map { "p\($0)" }, "to": 2], false),
            ("collage_move_photos", ["session": k, "photos": ["a"], "to": 0], false),
            ("collage_move_photos", ["session": k, "photos": ["a"], "to": 2, "cells": ["00"]], false),
            ("collage_replace_photo", ["session": k, "path": "01", "with": "DSCF7213"], true),
            ("collage_replace_photo", ["session": k, "path": "", "with": "DSCF7213", "op_id": op], true),
            ("collage_replace_photo", ["session": k, "path": "0a", "with": "x"], false),
            ("collage_replace_photo", ["session": k, "path": "012345678", "with": "x"], false),
            ("collage_replace_photo", ["session": k, "path": 1, "with": "x"], false),
            ("collage_replace_photo", ["session": k, "path": "0"], false),
            ("collage_replace_photo", ["session": k, "path": "0", "with": ""], false),
            ("collage_preflight", ["session": k], true),
            ("collage_preflight", ["session": k, "texts": false, "pages": "1-3"], true),
            ("collage_preflight", ["session": k, "texts": "no"], false),
            ("collage_preflight", ["session": k, "inline": false], false),
            ("collage_preflight", ["session": k, "op_id": op], false),
            ("collage_print_spec", ["session": k], true),
            ("collage_print_spec", ["session": k, "spec": "sq30-glued"], true),
            ("collage_print_spec", ["session": k, "min_pages": 20, "max_pages": 80, "page_step": 4, "single_ends": true,
                                    "color": "adobe_rgb", "jpeg_quality": 0.95, "fold_mm": 6.5], true),
            ("collage_print_spec", ["session": k, "auto": ["jpeg_quality", "fold_mm"]], true),
            ("collage_print_spec", ["session": k, "auto": ["jpeg_quality"], "jpeg_quality": 0.9], false),
            ("collage_print_spec", ["session": k, "auto": ["dpi"]], false),
            ("collage_print_spec", ["session": k, "min_pages": 60, "max_pages": 20], false),
            ("collage_print_spec", ["session": k, "min_pages": 1], false),
            ("collage_print_spec", ["session": k, "page_step": 41], false),
            ("collage_print_spec", ["session": k, "color": "cmyk"], false),
            ("collage_print_spec", ["session": k, "jpeg_quality": 0.3], false),
            ("collage_print_spec", ["session": k, "fold_mm": 41], false),
            ("collage_print_spec", ["session": k, "save_as": "我的"], false),
            ("collage_cover", ["session": k], true),
            ("collage_cover", ["session": k, "action": "make"], true),
            ("collage_cover", ["session": k, "action": "make", "spine_mm": 12.5, "spine_title": "{title}", "back_photo": ""], true),
            ("collage_cover", ["session": k, "action": "remake", "wrap_mm": 18, "board_mm": 2.5, "sheet_mm": 0.15], true),
            ("collage_cover", ["session": k, "spine_auto": true, "spine_date": "", "back_text": "2026 · 春"], true),
            ("collage_cover", ["session": k, "action": "edit"], true),
            ("collage_cover", ["session": k, "action": "done", "reveal": true, "op_id": op], true),
            ("collage_cover", ["session": k, "action": "remove", "spine_mm": 10], false),
            ("collage_cover", ["session": k, "action": "edit", "back_text": "x"], false),
            ("collage_cover", ["session": k, "spine_mm": 10, "spine_auto": true], false),
            ("collage_cover", ["session": k, "spine_auto": false], false),
            ("collage_cover", ["session": k, "spine_mm": 151], false),
            ("collage_cover", ["session": k, "sheet_mm": 0.01], false),
            ("collage_cover", ["session": k, "spine_title": String(repeating: "字", count: 61)], false),
            ("collage_cover", ["session": k, "action": "open"], false),
            ("collage_get_state", ["candidates_for": "DSCF7212", "candidates_limit": 5], true),
            ("collage_get_state", ["candidates_for": "DSCF7212"], true),
            ("collage_get_state", ["candidates_limit": 5], false),
            ("collage_get_state", ["candidates_for": "", "candidates_limit": 5], false),
            ("collage_get_state", ["candidates_for": "a", "candidates_limit": 31], false),
            ("collage_export", ["session": k, "pages": "1-3, 7"], true),
            ("collage_export", ["session": k, "proof": true, "name": "看版", "variant": "1a2b3c4d"], true),
            ("collage_export", ["session": k, "proof": true, "pages": "1"], false),
            ("collage_export", ["session": k, "proof": true, "scale": 2], false),
            ("collage_export", ["session": k, "proof": true, "format": "png"], false),
            ("collage_export", ["session": k, "proof": false, "scale": 2, "pages": "2"], true),
            ("collage_export", ["session": k, "pages": ""], false),
            ("collage_export", ["session": k, "proof": "yes"], false),
        ]
        for (tool, args, ok) in rows {
            let problem = MCPArgs.check(tool, args, deadlineCap: 600)
            check((problem == nil) == ok, "\(tool) \(MCPJSON.string(args).prefix(120))：期望\(ok ? "过" : "不过")，实际 \(problem?.message ?? "过")")
        }
        // 报错要说人话、告诉下一步：go 少了 page、action 带错参数
        let go = MCPArgs.check("collage_pages", ["action": "go"])
        check(go?.message.contains("page") == true && go?.hint.contains("album.spreads") == true, "go 少了 page：说要翻到第几个、去哪儿看跨页号")
        let wrong = MCPArgs.check("collage_pages", ["action": "go", "page": 2, "pages": "3"])
        check(wrong?.message.contains("pages") == true && wrong?.hint.contains("move") == true, "go 带了 pages：点名多了哪个、说 pages 给谁用")
    }

    private static func albumDefChecks(_ check: Check) {
        let defs = MCPToolDefs.tools(live: true)
        let names = defs.compactMap { $0["name"] as? String }
        let album = ["collage_pages", "collage_move_photos", "collage_replace_photo", "collage_preflight", "collage_print_spec",
                     "collage_cover"]
        check(Array(names.suffix(6)) == album, "相册整本的 6 个排在最后（25–30），不动旧编号：\(names.suffix(6))")
        func def(_ name: String) -> [String: Any] { defs.first { $0["name"] as? String == name } ?? [:] }
        func annotation(_ name: String, _ key: String) -> Bool? { (def(name)["annotations"] as? [String: Any])?[key] as? Bool }
        func description(_ name: String) -> String { def(name)["description"] as? String ?? "" }
        func props(_ name: String) -> Set<String> {
            Set(((def(name)["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]).keys)
        }
        for name in album {
            check(annotation(name, "readOnlyHint") == (name == "collage_preflight"), "\(name) 的 readOnlyHint：只有导出前检查是只读的")
            check(annotation(name, "destructiveHint") == false, "\(name) 不是 destructive（都能 ⌘Z）")
        }
        // 编辑封面时「当前页」类工具怎么办，写在说明里（DESIGN · M 的规矩）
        for name in ["collage_set_layout", "collage_auto_layout", "collage_apply_template", "collage_set_text"] {
            check(description(name).contains("编辑相册封面") && description(name).contains("invalid_state"),
                  "\(name) 的说明写了编辑封面时回 invalid_state")
        }
        check(description("collage_get_state").contains("editing_cover") && description("collage_get_state").contains("candidates_for"),
              "collage_get_state 的说明写了 editing_cover 和 candidates_for")
        check(description("collage_cover").contains("编辑封面时") && description("collage_replace_photo").contains("编辑封面时"),
              "collage_cover、collage_replace_photo 的说明写了编辑封面时作用在哪")
        check(props("collage_export").isSuperset(of: ["pages", "proof"]), "collage_export 有 pages、proof")
        check(props("collage_get_state").isSuperset(of: ["candidates_for", "candidates_limit"]), "collage_get_state 有 candidates_for")
        let instructions = MCPToolDefs.instructions(live: true)
        check(album.allSatisfy(instructions.contains), "instructions 提到了相册整本的 6 个工具")
        // 路由：导出前检查是读（不排进写的 FIFO）；翻页 / 改跨页、挪照片在后台排，50 s
        check(MCPLiveTools.routes["collage_preflight"]?.write == false && MCPLiveTools.routes["collage_pages"]?.write == true,
              "collage_preflight 走读，collage_pages 走写")
        for name in album where name != "collage_preflight" {
            check(MCPLiveTools.collageWrites.contains(MCPLiveTools.routes[name]?.method ?? ""), "\(name) 的结果带拼图预览")
        }
        // 关掉实时时只有前 3 个，描述里不提相册整本的工具
        let off = MCPToolDefs.tools(live: false)
        let offText = off.compactMap { $0["description"] as? String }.joined() + MCPToolDefs.instructions(live: false)
        check(!album.contains(where: offText.contains), "LABELGUI_MCP_LIVE=0 的描述里不提相册整本的工具")
    }

    private static func albumHelperChecks(_ check: Check) {
        // 跨页号的范围：不给 = 当前；写法同「导出 ▾」
        func sel(_ raw: Any?, _ count: Int, _ current: Int) -> String {
            switch LiveHandlers.pageSelection(raw, count: count, current: current) {
            case .success(let list): return list.map(String.init).joined(separator: ",")
            case .failure(let bad): return "错:" + bad.message
            }
        }
        check(sel(nil, 5, 2) == "2", "pages 不给 = 当前跨页：\(sel(nil, 5, 2))")
        check(sel("1-3, 5", 5, 0) == "0,1,2,4", "「1-3, 5」= 0,1,2,4：\(sel("1-3, 5", 5, 0))")
        check(sel("3-1", 5, 0) == "0,1,2", "反着写也认：\(sel("3-1", 5, 0))")
        check(sel("6", 5, 0).hasPrefix("错:") && sel("6", 5, 0).contains("一共 5"), "越界说一共几个：\(sel("6", 5, 0))")
        check(sel(nil, 0, 0).hasPrefix("错:"), "没有跨页时不给 pages 也是错")

        // move 的 to（挪完以后从第几个开始）→ onMove 的 destination：每种都拿 CollageAlbum.moved 回放核对
        let cases: [(Int, [Int], Int)] = [(10, [7], 2), (10, [2], 7), (10, [0], 9), (10, [9], 0), (10, [2, 3], 0), (10, [2, 5], 6),
                                          (10, [1, 8], 4), (3, [0, 1, 2], 0), (5, [4], 4), (5, [1, 3], 3)]
        for (count, picked, start) in cases {
            guard let d = LiveHandlers.moveDestination(count: count, picked: picked, start: start) else {
                check(false, "move \(picked) → 从第 \(start) 个开始：应该挪得了")
                continue
            }
            let out = CollageAlbum.moved(Array(0..<count), from: IndexSet(picked), to: d)
            check(Array(out[start..<(start + picked.count)]) == picked.sorted(),
                  "move \(picked) → 从第 \(start) 个开始（destination \(d)）：\(out)")
        }
        check(LiveHandlers.moveDestination(count: 10, picked: [2, 3], start: 9) == nil, "两个跨页挪到最后一个开始：越界 = nil")
        check(LiveHandlers.moveDestination(count: 5, picked: [7], start: 0) == nil, "挪不存在的跨页 = nil")
        check(LiveHandlers.moveDestination(count: 5, picked: [], start: 0) == nil, "什么都没挑 = nil")

        // 导出前检查的一条：snake_case、跨页号从 1 起、路径、图层
        check(LiveHandlers.snakeCase("emptySlot") == "empty_slot" && LiveHandlers.snakeCase("upscale") == "upscale"
              && LiveHandlers.snakeCase("fillerBody") == "filler_body", "种类写成 snake_case")
        let slot = CollagePreflightIssue(kind: .emptySlot, severity: .block, page: 2, path: [0, 1], message: "第 3 个跨页有一个空照片格")
        let row = LiveHandlers.issueRow(slot)
        check(row["kind"] as? String == "empty_slot" && row["page"] as? Int == 3 && row["path"] as? String == "01"
              && row["severity"] as? String == "block" && row["photo_id"] is NSNull && row["layer"] == nil,
              "空照片格那一条：\(MCPJSON.string(row))")
        let pages = CollagePreflightIssue(kind: .pageCount, severity: .block, message: "印厂要 20–60P")
        let pagesRow = LiveHandlers.issueRow(pages)
        check(pagesRow["page"] is NSNull && pagesRow["path"] is NSNull, "整本的事（页数）page、path 是 null")
        let layer = CollagePreflightIssue(kind: .upscale, severity: .warn, page: 0, item: UUID(), photoID: "DSCF7212", message: "放大")
        check(LiveHandlers.issueRow(layer)["layer"] as? Bool == true && LiveHandlers.issueRow(layer)["photo_id"] as? String == "DSCF7212",
              "相纸上的那一条标 layer、带照片 id")

        // 拦和提醒分开；只导几页时导出按钮会不会问只看那几页（同 CollageStore.exportConfirmation）
        var project = CollageProject()
        project.mode = .album
        project.canvas = CollagePrintSpec.builtin[0].canvas
        project.pages = (0..<3).map { _ in CollagePage(root: .leaf(CollageCell())) }
        let upscale = CollagePreflightIssue(kind: .upscale, severity: .block, page: 0, path: [], photoID: "a", message: "放大到 180%")
        let warn = CollagePreflightIssue(kind: .textSafe, severity: .warn, page: 1, path: [1], message: "字出安全区")
        let issues = [upscale, slot, pages, warn]
        let all = LiveHandlers.preflightBody(issues, project: project, pages: nil)
        check(all["block_count"] as? Int == 3 && all["warn_count"] as? Int == 1 && (all["blocks"] as? [Any])?.count == 3
              && (all["warnings"] as? [Any])?.count == 1 && all["export_would_ask"] is [String: Any] && all["pages"] is NSNull,
              "整本：3 条拦、1 条提醒，导出按钮会问：\(MCPJSON.string(all).prefix(200))")
        let only = LiveHandlers.preflightBody(issues, project: project, pages: [1])
        check(only["export_would_ask"] is NSNull && (only["pages"] as? [Int]) == [2],
              "只导第 2 个跨页（上面只有提醒）：导出按钮不问")
        let cut = LiveHandlers.preflightBody(Array(repeating: warn, count: 5), project: project, pages: nil, limit: 2)
        check((cut["warnings"] as? [Any])?.count == 2 && cut["truncated"] as? Bool == true && cut["warn_count"] as? Int == 5,
              "超过上限：列前几条、truncated、计数照实")

        // 印厂规格的页数摘要：3 个跨页 = 6P，按保守默认 20–60P 查 → 少了
        let summary = LiveHandlers.printSummary(project)
        check(summary["pages_p"] as? Int == 6 && (summary["page_problem"] as? String)?.contains("少了") == true
              && summary["preset"] as? Bool == true && summary["binding"] as? String == "layflat",
              "印厂规格的页数：\(MCPJSON.string(summary))")
        var social = CollageProject()
        social.pages = [CollagePage(root: .leaf(CollageCell()))]
        check(LiveHandlers.printSummary(social)["page_problem"] is NSNull, "单张拼图不查页数")
        check(LiveHandlers.colorName(.sRGB) == "srgb" && LiveHandlers.colorName(.adobeRGB) == "adobe_rgb", "色彩的名字同 color 参数")
        check(LiveHandlers.candidateReason(.burst) == "burst" && LiveHandlers.candidateReason(.take) == "take"
              && LiveHandlers.candidateReason(.similar) == "similar", "候选的理由：burst / take / similar")
        check(MCPArgs.coverFields.allSatisfy { LiveHandlers.coverFieldLabel($0) != $0 }, "封面每个字段都有中文名（提示里用）")
        check(LiveHandlers.pageKind(CollagePage(root: .leaf(CollageCell()))) == "grid", "普通页 = grid")
    }
}
