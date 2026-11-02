import Foundation

/// --mcp-selftest 的设计版式部分（MCPSelfTest.run 调），全是纯函数，不连 socket、不碰文件、不建任何 store：
/// 21. 语法 → 切分树：多叉换成二叉、份数换成比例、各种写法；一张手写的错误表（错在哪一个路径）。
/// 22. 读出来再发回去不改东西：每个内置模板、歪得厉害的切分（六块、细条）、语法里没有的设置，
///     describe → JSON → parse → snap 以后和原来的树一模一样。
/// 23. 改了一处：比例、没动的格子留着，同一张照片的单格色调、抠图跟着照片走。
extension MCPSelfTest {
    static func layoutChecks(_ check: Check) {
        layoutParseChecks(check)
        layoutRoundTripChecks(check)
        layoutEditChecks(check)
    }

    private static func parsed(_ value: Any) -> CollageLayoutSpec.Parsed? {
        if case .success(let p) = CollageLayoutSpec.parse(value, isKnownPhoto: { _ in true }) { return p }
        return nil
    }

    /// 走一遍 JSON（数字、布尔要和线上的一样是 NSNumber）。
    private static func wire(_ value: Any) -> Any? {
        MCPJSON.data(value).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private static func json(_ text: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? NSNull()
    }

    private static func layoutParseChecks(_ check: Check) {
        // 三块 2:1:1 → 第一块对其余 0.5，其余再 0.5
        let three = parsed(json(#"{"split":"row","sizes":[2,1,1],"items":[{"photo":"a"},{"photo":"b"},{"photo":"c"}]}"#))
        check(three?.root.axis == .row && three?.root.ratio == 0.5, "三块 2:1:1：第一刀 0.5")
        check(three?.root.children[1].axis == .row && three?.root.children[1].ratio == 0.5, "三块 2:1:1：第二刀 0.5")
        check(three?.photoIDs == ["a", "b", "c"], "photoIDs 按出现顺序")
        check(parsed(json(#"{"split":"column","items":[{"empty":true},{"photo":"a"}]}"#))?.root.ratio == 0.5, "不写 sizes = 等分")
        check(parsed(json(#"{"photo":"a"}"#))?.root.isLeaf == true, "整页一张照片也行")
        // 极端份数夹在排版引擎的上下限里
        let thin = parsed(json(#"{"split":"column","sizes":[1,1000],"items":[{"empty":true},{"photo":"a"}]}"#))
        check(thin?.root.ratio == CollageLayout.minRatio, "份数差太大：夹到 minRatio")

        let cell = parsed(json(#"""
        {"photo":"a","framing":"close","shape":"arch","fit":"contain_blur","crop":{"x":0.2,"y":0.7,"zoom":2},"hero":true,
         "overlays":[{"lines":["标题",{"text":"副标题","font":"didot","weight":"bold","size":0.02,"color":"#FF8000","tracking":0.1,"italic":true}],
                      "anchor":"bottom_left","tone":"light","scrim":false}]}
        """#))?.root.cell
        check(cell?.framing == .close && cell?.shape == .arch && cell?.contain == true && cell?.containBlur == true, "照片格的取景、形状、完整显示")
        check(cell?.crop == CollageCropOverride(cx: 0.2, cy: 0.7, zoom: 2) && cell?.role == .hero, "照片格的裁切、主图")
        let ov = cell?.overlays.first
        check(ov?.anchor == .bottomLeading && ov?.tone == .light && ov?.scrim == false && ov?.text.lines.count == 2, "压字的位置、色调、雾面、行数")
        let line = ov?.text.lines.last
        check(line?.font == .didot && line?.weight == .bold && line?.size == 0.02 && line?.italic == true, "行的字体、字重、字号、斜体")
        check(line.map { CollageLayoutSpec.hex($0.color) } == "#FF8000" && line?.tracking == 0.1, "行的颜色、字距")
        let text = parsed(json(#"{"text":{"lines":["竖排"],"align":"right","valign":"bottom","vertical":true}}"#))?.root.cell
        check(text?.kind == .text && text?.text?.alignH == .trailing && text?.text?.alignV == .trailing && text?.text?.vertical == true, "文字格")
        let twice = parsed(json(#"{"split":"row","items":[{"photo":"a"},{"photo":"a"}]}"#))
        check(twice?.photoIDs == ["a"] && twice?.duplicates == ["a"], "同一张放两格：收下、报重复")

        let deep = (0..<(CollageLayoutSpec.maxDepth + 1)).reduce(#"{"photo":"z"}"#) { inner, _ in #"{"split":"row","items":[\#(inner),{"empty":true}]}"# }
        let leaves = (0...CollageLayoutSpec.maxLeaves).map { #"{"split":"row","items":[{"photo":"p\#($0)"},{"empty":true}]}"# }
            .reduce(#"{"empty":true}"#) { inner, next in next.replacingOccurrences(of: #"{"empty":true}"#, with: inner) }
        let rows: [(String, String, String)] = [
            ("[]", "layout", "不是对象"),
            (#"{}"#, "layout", "四种都没有"),
            (#"{"photo":"a","empty":true}"#, "layout", "两种都有"),
            (#"{"split":"diagonal","items":[{"empty":true},{"empty":true}]}"#, "layout.split", "方向写错"),
            (#"{"split":"row","items":[{"empty":true}]}"#, "layout.items", "只有一块"),
            (#"{"split":"row","items":[{"empty":true},{"empty":true},{"empty":true},{"empty":true},{"empty":true},{"empty":true},{"empty":true}]}"#, "layout.items", "七块"),
            (#"{"split":"row","sizes":[1],"items":[{"empty":true},{"empty":true}]}"#, "layout.sizes", "份数个数不对"),
            (#"{"split":"row","sizes":[1,0],"items":[{"empty":true},{"empty":true}]}"#, "layout.sizes[1]", "份数不是正数"),
            (#"{"split":"row","sizes":[1,true],"items":[{"empty":true},{"empty":true}]}"#, "layout.sizes[1]", "份数是布尔"),
            (#"{"split":"row","items":[{"empty":true},{"photo":""}]}"#, "layout.items[1].photo", "空的照片 id"),
            (#"{"photo":"a","framing":"wide"}"#, "layout.framing", "取景写错"),
            (#"{"photo":"a","shape":"star"}"#, "layout.shape", "形状写错"),
            (#"{"photo":"a","fit":"stretch"}"#, "layout.fit", "fit 写错"),
            (#"{"photo":"a","crop":{"x":2,"y":0}}"#, "layout.crop", "crop 超范围"),
            (#"{"photo":"a","crop":{"x":0,"y":0,"zoom":9}}"#, "layout.crop.zoom", "zoom 超范围"),
            (#"{"photo":"a","crop":{"x":0,"y":0,"w":1}}"#, "layout.crop.w", "crop 多了键"),
            (#"{"photo":"a","hero":1}"#, "layout.hero", "hero 不是布尔"),
            (##"{"photo":"a","color":"#000000"}"##, "layout.color", "照片格多了键"),
            (#"{"photo":"a","overlays":[{"lines":["x"],"anchor":"middle"}]}"#, "layout.overlays[0].anchor", "压字位置写错"),
            (#"{"photo":"a","overlays":[{"lines":["x"]},{"lines":["x"]},{"lines":["x"]},{"lines":["x"]},{"lines":["x"]}]}"#, "layout.overlays", "压字太多"),
            (#"{"text":{"lines":"标题"}}"#, "layout.text.lines", "lines 不是数组"),
            (#"{"text":{"lines":[1]}}"#, "layout.text.lines[0]", "行不是字符串或对象"),
            (#"{"text":{"lines":[{"text":"x","font":"comic"}]}}"#, "layout.text.lines[0].font", "字体写错"),
            (#"{"text":{"lines":[{"text":"x","weight":"thin"}]}}"#, "layout.text.lines[0].weight", "字重写错"),
            (#"{"text":{"lines":[{"text":"x","size":0.9}]}}"#, "layout.text.lines[0].size", "字号超范围"),
            (#"{"text":{"lines":[{"text":"x","color":"red"}]}}"#, "layout.text.lines[0].color", "颜色写错"),
            (##"{"text":{"lines":[{"text":"x","color":"#12345"}]}}"##, "layout.text.lines[0].color", "颜色位数不对"),
            (#"{"text":{"lines":[{"text":"x","tracking":3}]}}"#, "layout.text.lines[0].tracking", "字距超范围"),
            (#"{"text":{"lines":[{"text":"x","bold":true}]}}"#, "layout.text.lines[0].bold", "行多了键"),
            (#"{"empty":false}"#, "layout.empty", "empty 不是 true"),
        ]
        for (text, path, why) in rows {
            let result = CollageLayoutSpec.parse(json(text), isKnownPhoto: { _ in true })
            if case .failure(let p) = result {
                check(p.path == path, "\(why)：错误位置应该是 \(path)，实际 \(p.path)")
            } else {
                check(false, "\(why)：应该被拒绝：\(text)")
            }
        }
        let long = String(repeating: "字", count: CollageLayoutSpec.maxLineChars + 1)
        if case .success = CollageLayoutSpec.parse(["text": ["lines": [long]]], isKnownPhoto: { _ in true }) {
            check(false, "一行太长应该被拒绝")
        }
        if case .success = CollageLayoutSpec.parse(json(deep), isKnownPhoto: { _ in true }) { check(false, "套得太深应该被拒绝") }
        if case .success = CollageLayoutSpec.parse(json(leaves), isKnownPhoto: { _ in true }) { check(false, "格子太多应该被拒绝") }
        if case .success = CollageLayoutSpec.parse(nil, isKnownPhoto: { _ in true }) { check(false, "没有 layout 应该被拒绝") }
        if case .failure(let p) = CollageLayoutSpec.parse(json(#"{"photo":"b"}"#), isKnownPhoto: { $0 == "a" }) {
            check(p.path == "layout.photo", "不认识的照片：错误位置 layout.photo，实际 \(p.path)")
        } else {
            check(false, "不认识的照片应该被拒绝")
        }

        // 工具参数：结构在 --mcp 这边就挡住（照片认不认得只有 app 知道）
        let k = "0123456789abcdef"
        check(MCPArgs.check("collage_set_layout", ["session": k, "layout": json(#"{"photo":"不认识也过"}"#)]) == nil, "set_layout：结构对就过")
        check(MCPArgs.check("collage_set_layout", ["session": k]) != nil, "set_layout：layout 必填")
        let bad = MCPArgs.check("collage_set_layout", ["session": k, "layout": json(#"{"split":"row","items":[{"photo":"a"},{"photo":"b","shape":"star"}]}"#)])
        check(bad?.message.contains("layout.items[1].shape") == true, "set_layout：错误里有路径：\(bad?.message ?? "")")
        let grammar = CollageLayoutSpec.grammar
        check((grammar["fonts"] as? [[String: Any]])?.count == CollageFont.allCases.count, "layout_grammar：每个字体一行")
        check(grammar["weights"] as? [String] == CollageWeight.allCases.map(\.rawValue), "layout_grammar：字重")
        let text0 = grammar["grammar"] as? String ?? ""
        let example = text0.split(separator: "\n").last.map(String.init) ?? ""
        check(parsed(json(example))?.photoIDs.count == 3, "layout_grammar 里的例子要能解析：\(example)")
    }

    private static func ref(_ id: String, portrait: Bool) -> CollagePhotoRef {
        var r = CollagePhotoRef(id: id, path: "/nonexistent/selftest/\(id).jpg", width: portrait ? 4000 : 6000, height: portrait ? 6000 : 4000)
        r.faces = [[0.4, 0.2, 0.6, 0.4]]
        return r
    }

    /// 读出来再发回去：能过校验，snap 以后和原来一模一样。
    private static func roundTrip(_ root: CollageNode, _ what: String, _ check: Check) {
        let described = CollageLayoutSpec.describe(root)
        guard let onWire = wire(described) else {
            check(false, "\(what)：describe 写不成 JSON")
            return
        }
        switch CollageLayoutSpec.parse(onWire, isKnownPhoto: { _ in true }) {
        case .failure(let p):
            check(false, "\(what)：读出来发回去被拒绝：\(p.text)")
        case .success(let parsed):
            let snapped = CollageLayoutSpec.snap(parsed.root, onto: root)
            check(snapped == root, "\(what)：发回去以后树变了")
            // 再读一遍和第一遍一样（发多少遍都不漂）
            let again = MCPJSON.data(CollageLayoutSpec.describe(snapped))
            check(again == MCPJSON.data(described), "\(what)：第二遍读出来不一样")
        }
    }

    private static func layoutRoundTripChecks(_ check: Check) {
        // 每个内置模板，三种画布（竖、方、相册跨页）
        let photos = (0..<40).map { ref("p\($0)", portrait: $0 % 3 != 0) }
        let map = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let canvases = [CollageCLI.canvas("3:4"), CollageCLI.canvas("1:1"), CollageCLI.canvas("album30")]
        var pages = 0
        for template in CollageTemplates.builtin {
            for canvas in canvases {
                let context = CollageLayout.Context(canvas: template.canvas ?? canvas, style: template.style ?? CollageStyle(), photos: map, hints: [:], heroID: nil)
                let page = CollageTemplates.apply(template, photos: photos, context: context)
                guard !page.freeform, page.contactSheet == nil else { continue }
                pages += 1
                roundTrip(page.root, "模板「\(template.name)」", check)
            }
        }
        check(pages > 50, "内置模板的切分树页太少，测的范围不对：\(pages)")

        func p(_ id: String) -> CollageNode { .leaf(.photo(id)) }
        // 歪得厉害：同方向连切很多刀、细条、比例超出上下限、比 maxLeaves 少一点的大网格
        var chain = p("z")
        for i in 0..<9 { chain = .split(.row, 0.137 + Double(i) * 0.07, p("c\(i)"), chain) }
        roundTrip(chain, "同方向十块（一个节点放不下）", check)
        var skew = p("z")
        for i in 0..<6 { skew = .split(.column, 0.96, p("s\(i)"), skew) }
        roundTrip(skew, "六刀都留很细的一条", check)
        roundTrip(.split(.column, 0.04, .leaf(CollageCell(kind: .empty)), .split(.row, 0.0417, p("a"), p("b"))), "最细的标题带", check)
        roundTrip(.split(.row, 0.999, p("a"), p("b")), "比例超出上限", check)
        roundTrip(.split(.row, 1.0 / 3.0, p("a"), .split(.row, 0.5, p("b"), p("c"))), "三等分（除不尽）", check)
        var tall = p("t0")
        for i in 1..<CollageLayoutSpec.maxDepth { tall = .split(i % 2 == 0 ? .row : .column, 0.5, tall, p("t\(i)")) }
        roundTrip(tall, "交替方向套到最深", check)

        // 语法里没有的设置：描述一样就留着
        var rich = CollageCell.photo("a")
        rich.framing = .cover
        rich.look = CollageLookSetting(look: .mono, strength: 0.6)
        rich.locked = true
        rich.coverAuto = true
        var line = CollageTextLine("刊头", font: .didot, weight: .black, size: 0.5, tracking: 3, color: CollageColor(r: 0.123, g: 0.456, b: 0.789))
        line.fitWidth = true
        line.indent = 2
        var overlay = CollageOverlay(text: CollageText(lines: [line]))
        overlay.anchor = .custom
        overlay.x = 0.3
        overlay.layer = .behindSubject
        rich.overlays = Array(repeating: overlay, count: CollageLayoutSpec.maxOverlays + 1)
        roundTrip(.leaf(rich), "带着语法里没有的设置的照片格", check)
        var emptyPhoto = CollageCell.photo(nil)
        emptyPhoto.locked = true
        roundTrip(.split(.row, 0.5, .leaf(emptyPhoto), p("a")), "没放照片的照片格", check)
        var block = CollageText(lines: Array(repeating: CollageTextLine(String(repeating: "长", count: CollageLayoutSpec.maxLineChars + 5)), count: CollageLayoutSpec.maxLines + 2))
        block.rule = true
        block.lineSpacing = 0.8
        roundTrip(.leaf(.text(block)), "行太多、一行太长的文字格", check)
        roundTrip(.leaf(.text(CollageText())), "没有字的文字格", check)
        var crop = CollageCell.photo("a")
        crop.crop = CollageCropOverride(cx: 1.2, cy: -0.1, zoom: 6.5)
        roundTrip(.leaf(crop), "裁切超出范围（旧工程）", check)
        roundTrip(.split(.row, 0.5, p("a"), p("a")), "同一张放两格", check)
    }

    private static func layoutEditChecks(_ check: Check) {
        func p(_ id: String) -> CollageNode { .leaf(.photo(id)) }
        var a = CollageCell.photo("a")
        a.look = CollageLookSetting(look: .mono, strength: 0.6)
        a.locked = true
        var title = CollageTextLine("旧标题")
        title.fitWidth = true
        var head = CollageOverlay(text: CollageText(lines: [title]))
        head.anchor = .custom
        var b = CollageCell.photo("b")
        b.overlays = [head]
        let old = CollageNode.split(.row, 0.6, .leaf(a), .leaf(b))

        // 改第一块的比例：比例听新的，两个格子一个没动
        let moved = parsed(json(#"{"split":"row","sizes":[1,1],"items":[{"photo":"a"},{"photo":"b","overlays":[{"lines":[{"text":"旧标题","font":"songti","size":0.04,"color":"\#(CollageLayoutSpec.hex(title.color))"}]}]}]}"#))?.root
        let snapped = moved.map { CollageLayoutSpec.snap($0, onto: old) }
        check(snapped?.ratio == 0.5, "比例改了就听新的")
        check(snapped?.children[1].cell == b, "没动的格子留着语法里没有的设置（拖过的压字位置、铺满宽度）")
        check(snapped?.children[0].cell?.look == a.look && snapped?.children[0].cell?.locked == true, "没动的格子留着色调、锁定")

        // 两张换了位置：色调跟着照片走；a 上的字不再跟着（AI 没写）
        let swapped = parsed(json(#"{"split":"row","items":[{"photo":"b"},{"photo":"a","framing":"close"}]}"#))?.root
        let after = swapped.map { CollageLayoutSpec.snap($0, onto: old) }
        check(after?.children[1].cell?.look == a.look && after?.children[1].cell?.framing == .close, "换位置、改取景：单格色调跟着照片走")
        check(after?.children[0].cell?.overlay == nil, "AI 没写压字：新版式上没有")

        // 方向改了：不套旧比例
        let turned = parsed(json(#"{"split":"column","sizes":[3,2],"items":[{"photo":"a"},{"photo":"b"}]}"#))?.root
        check(turned.map { CollageLayoutSpec.snap($0, onto: old) }?.axis == .column, "方向改了听新的")
        check(CollageLayoutSpec.snap(p("a"), onto: nil) == p("a"), "没有旧版：原样")
    }
}
