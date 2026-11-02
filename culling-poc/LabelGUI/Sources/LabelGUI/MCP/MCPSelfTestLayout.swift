import Foundation

/// --mcp-selftest 的设计版式部分（MCPSelfTest.run 调），全是纯函数，不连 socket、不碰文件、不建任何 store：
/// 21. 语法 → 切分树：多叉换成二叉、份数换成比例、各种写法；一张手写的错误表（错在哪一个路径）。
/// 22. 读出来再发回去不改东西：每个内置模板、歪得厉害的切分（六块、细条）、语法里没有的设置，
///     describe → JSON → parse → applyGutters → snap 以后和原来的树一模一样；外面再包一层，没动的格子也一模一样。
/// 23. 份数按去掉所有的缝算：等分就是等分，一排两块和一排四块的缝对得齐；读回来的份数和写的一样。
/// 24. 改了一处：比例、没动的格子留着，改过的格子里没改的字块、行、同一张照片的单格色调留着。
extension MCPSelfTest {
    static func layoutChecks(_ check: Check) {
        layoutParseChecks(check)
        layoutRoundTripChecks(check)
        layoutGutterChecks(check)
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
        check(cell?.framing == .close, "照片格的取景")
        check(cell?.shape == .arch, "照片格的形状")
        check(cell?.contain == true, "照片格完整显示")
        check(cell?.containBlur == true, "照片格模糊铺底")
        check(cell?.crop == CollageCropOverride(cx: 0.2, cy: 0.7, zoom: 2), "照片格的裁切")
        check(cell?.role == .hero, "照片格的主图")
        let ov = cell?.overlays.first
        check(ov?.anchor == .bottomLeading, "压字的位置")
        check(ov?.tone == .light, "压字的色调")
        check(ov?.scrim == false, "压字的雾面")
        check(ov?.text.lines.count == 2, "压字的行数")
        let line = ov?.text.lines.last
        check(line?.font == .didot, "行的字体")
        check(line?.weight == .bold, "行的字重")
        check(line?.size == 0.02, "行的字号")
        check(line?.italic == true, "行的斜体")
        check(line.map { CollageLayoutSpec.hex($0.color) } == "#FF8000", "行的颜色")
        check(line?.tracking == 0.1, "行的字距")
        let text = parsed(json(#"{"text":{"lines":["竖排"],"align":"right","valign":"bottom","vertical":true}}"#))?.root.cell?.text
        check(text?.alignH == .trailing, "文字格的左右对齐")
        check(text?.alignV == .trailing, "文字格的上下对齐")
        check(text?.vertical == true, "文字格竖排")
        let more = parsed(json(#"""
        {"photo":"a","framing":"cover","look":"mono","look_strength":0.5,"cutout":{"stroke":0.1,"shadow":0.2,"to_edge":true},
         "overlays":[{"lines":["x"],"anchor":"custom","x":0.3,"y":0.7},{"lines":["y"],"anchor":"left_column"}]}
        """#))?.root.cell
        check(more?.framing == .cover, "封面取景")
        check(more?.look == CollageLookSetting(look: .mono, strength: 0.5), "单格色调")
        check(more?.cutout == CollageCutout(stroke: 0.1, shadow: 0.2, toEdge: true), "抠图")
        check(more?.overlays.first?.anchor == .custom, "压字指定位置")
        check(more?.overlays.first?.x == 0.3, "压字的 x")
        check(more?.overlays.first?.y == 0.7, "压字的 y")
        check(more?.overlays.last?.anchor == .leftColumn, "压字贴左栏")
        check(parsed(json(#"{"photo":"a","cutout":true}"#))?.root.cell?.cutout == CollageCutout(), "cutout:true = 默认抠图")
        check(parsed(json(#"{"photo":"a","cutout":false}"#))?.root.cell?.cutout == nil, "cutout:false = 不抠")
        let twice = parsed(json(#"{"split":"row","items":[{"photo":"a"},{"photo":"a"}]}"#))
        check(twice?.photoIDs == ["a"] && twice?.duplicates == ["a"], "同一张放两格：收下、报重复")

        let deep = (0..<(CollageLayoutSpec.maxLeaves + 1)).reduce(#"{"empty":true}"#) { inner, _ in #"{"split":"row","items":[\#(inner),{"split":"column","items":[{"split":"row","items":[{"empty":true},{"empty":true}]},{"empty":true}]}]}"# }
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
            (#"{"text":{"lines":[{"text":"x","size":1.5}]}}"#, "layout.text.lines[0].size", "字号超范围"),
            (#"{"photo":"a","look":"bw"}"#, "layout.look", "色调写错"),
            (#"{"photo":"a","look_strength":0.5}"#, "layout.look_strength", "强度不带色调"),
            (#"{"photo":"a","look":"mono","look_strength":2}"#, "layout.look_strength", "强度超范围"),
            (#"{"photo":"a","cutout":"yes"}"#, "layout.cutout", "抠图写错"),
            (#"{"photo":"a","cutout":{"stroke":3}}"#, "layout.cutout.stroke", "描边超范围"),
            (#"{"photo":"a","overlays":[{"lines":["x"],"x":0.5}]}"#, "layout.overlays[0].x", "不是 custom 写 x"),
            (#"{"photo":"a","overlays":[{"lines":["x"],"anchor":"custom","y":2}]}"#, "layout.overlays[0].y", "y 超范围"),
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
        if case .success = CollageLayoutSpec.parse(json(deep), isKnownPhoto: { _ in true }) { check(false, "套得太深、格子太多应该被拒绝") }
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

    /// 读出来再发回去：能过校验（格子多于上限的按现有格数放宽），snap 以后和原来一模一样。
    private static func roundTrip(_ root: CollageNode, _ what: String, _ check: Check,
                                  canvas: CollageCanvas = CollageCLI.canvas("3:4"), style: CollageStyle = CollageStyle()) {
        let described = CollageLayoutSpec.describe(root, canvas: canvas, style: style)
        guard let onWire = wire(described) else {
            check(false, "\(what)：describe 写不成 JSON")
            return
        }
        let cells = max(CollageLayoutSpec.maxLeaves, root.leaves.count)
        switch CollageLayoutSpec.parse(onWire, maxCells: cells, isKnownPhoto: { _ in true }) {
        case .failure(let p):
            check(false, "\(what)：读出来发回去被拒绝：\(p.text)")
        case .success(let parsed):
            let exact = CollageLayoutSpec.applyGutters(parsed.root, canvas: canvas, style: style, current: root)
            let snapped = CollageLayoutSpec.snap(exact, onto: root)
            check(snapped == root, "\(what)：发回去以后树变了")
            // 再读一遍和第一遍一样（发多少遍都不漂）
            let again = MCPJSON.data(CollageLayoutSpec.describe(snapped, canvas: canvas, style: style))
            check(again == MCPJSON.data(described), "\(what)：第二遍读出来不一样")
        }
    }

    /// 外面再包一层（底下加一条）：所有格子的位置都变了，描述没变的还是原来的格子。
    private static func wrapped(_ root: CollageNode, _ what: String, _ check: Check, canvas: CollageCanvas, style: CollageStyle) {
        let inner = CollageLayoutSpec.describe(root, canvas: canvas, style: style)
        let outer: [String: Any] = ["split": "column", "sizes": [9, 1], "items": [inner, ["empty": true]]]
        guard let onWire = wire(outer), let p = parsed(onWire) else {
            check(false, "\(what)：包一层以后解析不了")
            return
        }
        let snapped = CollageLayoutSpec.snap(CollageLayoutSpec.applyGutters(p.root, canvas: canvas, style: style), onto: root)
        check(Array(snapped.leaves.dropLast()) == root.leaves, "\(what)：外面包一层，没动的格子丢了设置")
    }

    private static func layoutRoundTripChecks(_ check: Check) {
        // 每个内置模板，三种画布（竖、方、相册跨页）
        let photos = (0..<40).map { ref("p\($0)", portrait: $0 % 3 != 0) }
        let map = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let canvases = [CollageCLI.canvas("3:4"), CollageCLI.canvas("1:1"), CollageCLI.canvas("album30")]
        var pages = 0
        for template in CollageTemplates.builtin {
            for canvas in canvases {
                let use = template.canvas ?? canvas
                let style = template.style ?? CollageStyle()
                let context = CollageLayout.Context(canvas: use, style: style, photos: map, hints: [:], heroID: nil)
                let page = CollageTemplates.apply(template, photos: photos, context: context)
                guard !page.freeform, page.contactSheet == nil else { continue }
                pages += 1
                roundTrip(page.root, "模板「\(template.name)」", check, canvas: use, style: style)
                if page.root.leaves.count < CollageLayoutSpec.maxLeaves {
                    wrapped(page.root, "模板「\(template.name)」", check, canvas: use, style: style)
                }
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
        for i in 1..<24 { tall = .split(i % 2 == 0 ? .row : .column, 0.5, tall, p("t\(i)")) }
        roundTrip(tall, "交替方向一层层往里套", check)
        var many = p("m0")
        for i in 1..<40 { many = .split(i % 2 == 0 ? .row : .column, 0.5, p("m\(i)"), many) }
        roundTrip(many, "比上限多的 40 格（整批带进拼图不限张数）", check)
        var wide = p("w0")
        for i in 1..<40 { wide = .split(.row, 1.0 / Double(41 - i), p("w\(i)"), wide) }
        roundTrip(wide, "同方向 40 块", check)
        var smallGap = CollageStyle()
        smallGap.gutter = 0.03
        smallGap.margin = 0
        roundTrip(chain, "缝很宽", check, canvas: CollageCLI.canvas("1:1"), style: smallGap)
        roundTrip(.split(.row, 0.3, p("a"), .split(.row, 0.4, p("b"), p("c"))), "缝很宽（三块）", check, canvas: CollageCLI.canvas("9:16"), style: smallGap)
        var hugeGap = CollageStyle()
        hugeGap.gutter = 0.4
        roundTrip(chain, "缝比格子还宽（放不下）", check, style: hugeGap)

        // 语法里没有的设置：描述一样就留着
        var rich = CollageCell.photo("a")
        rich.framing = .cover
        rich.look = CollageLookSetting(look: .mono, strength: 0.6, fromTemplate: true)
        rich.cutout = CollageCutout(stroke: 0.123456, shadow: 0, toEdge: true)
        rich.role = .support
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
        var tiny = CollageCell(kind: .text)
        var tinyLine = CollageTextLine("字距极小")
        tinyLine.tracking = 0.00001
        tiny.text = CollageText(lines: [tinyLine])
        roundTrip(.leaf(tiny), "字距小到四舍五入是 0", check)
        roundTrip(.split(.row, 0.5, p("a"), p("a")), "同一张放两格", check)
    }

    private static func layoutGutterChecks(_ check: Check) {
        let canvas = CollageCLI.canvas("3:4")
        var style = CollageStyle()
        style.gutter = 0.03
        func geometry(_ text: String) -> (CollageNode, [CollageLayout.Frame]) {
            guard let p = parsed(json(text)) else { return (CollageNode(), []) }
            let root = CollageLayoutSpec.applyGutters(p.root, canvas: canvas, style: style)
            return (root, CollageLayout.pageGeometry(root, canvas: canvas, style: style).frames)
        }
        let six = #"{"split":"row","items":[{"empty":true},{"empty":true},{"empty":true},{"empty":true},{"empty":true},{"empty":true}]}"#
        let (sixRoot, sixFrames) = geometry(six)
        let widths = sixFrames.map { Int($0.rect.cgRect.width) }
        check((widths.max() ?? 0) - (widths.min() ?? 99) <= 1, "六块等分：宽度一样（差不超过 1 px，缝 \(style.gutter)）：\(widths)")
        let sizes = (CollageLayoutSpec.describe(sixRoot, canvas: canvas, style: style)["sizes"] as? [NSNumber])?.map(\.doubleValue) ?? []
        check(sizes.count == 6, "六块读回来还是六块：\(sizes)")
        check(sizes.allSatisfy { abs($0 - 1.0 / 6.0) < 0.00001 }, "六块读回来的份数都是 1/6：\(sizes)")
        // 一排两块、一排四块：中间的缝对得齐
        let grid = #"""
        {"split":"column","items":[{"split":"row","items":[{"empty":true},{"empty":true}]},
         {"split":"row","items":[{"empty":true},{"empty":true},{"empty":true},{"empty":true}]}]}
        """#
        let (_, gridFrames) = geometry(grid)
        check(gridFrames.count == 6, "两排一共 6 格")
        if gridFrames.count == 6 {
            let top = gridFrames[0].rect.cgRect.maxX
            let bottom = gridFrames[3].rect.cgRect.maxX
            check(abs(top - bottom) <= 1, "一排两块和一排四块的缝对得齐：\(top) vs \(bottom)")
        }
        // 份数不等也按真实长度：3 : 1 正好三倍
        let (_, ratioFrames) = geometry(#"{"split":"row","sizes":[3,1,1],"items":[{"empty":true},{"empty":true},{"empty":true}]}"#)
        if ratioFrames.count == 3 {
            let a = Double(ratioFrames[0].rect.cgRect.width)
            let b = Double(ratioFrames[1].rect.cgRect.width)
            let c = Double(ratioFrames[2].rect.cgRect.width)
            check(abs(a - 3 * b) <= 3, "3:1:1：第一块是第二块的三倍：\(a) vs \(b)")
            check(abs(b - c) <= 1, "3:1:1：后两块一样宽：\(b) vs \(c)")
        } else {
            check(false, "3:1:1 应该三格")
        }
    }

    private static func layoutEditChecks(_ check: Check) {
        func p(_ id: String) -> CollageNode { .leaf(.photo(id)) }
        let canvas = CollageCLI.canvas("3:4")
        let style = CollageStyle()
        var a = CollageCell.photo("a")
        a.look = CollageLookSetting(look: .mono, strength: 0.6)
        a.locked = true
        var title = CollageTextLine("旧标题")
        title.fitWidth = true
        var head = CollageOverlay(text: CollageText(lines: [title]))
        head.anchor = .custom
        head.layer = .behindSubject
        var b = CollageCell.photo("b")
        b.overlays = [head]
        let old = CollageNode.split(.row, 0.6, .leaf(a), .leaf(b))
        func send(_ layout: [String: Any]) -> CollageNode? {
            guard let onWire = wire(layout), let got = parsed(onWire) else { return nil }
            return CollageLayoutSpec.snap(CollageLayoutSpec.applyGutters(got.root, canvas: canvas, style: style, current: old), onto: old)
        }
        let described = CollageLayoutSpec.describe(old, canvas: canvas, style: style)

        // 改比例：比例听新的，两个格子一个没动
        var resized = described
        resized["sizes"] = [1, 1]
        let moved = send(resized)
        check(moved?.ratio == 0.5, "比例改了就听新的")
        check(moved?.children[0].cell == a, "改比例：第一格没动")
        check(moved?.children[1].cell == b, "改比例：第二格没动（拖过的压字位置、人物挡字、铺满宽度都在）")

        // 改一格的取景：这一格的字块原样，色调、锁定都在
        var items = described["items"] as? [[String: Any]] ?? []
        items[1]["framing"] = "close"
        var reframed = described
        reframed["items"] = items
        let framed = send(reframed)
        check(framed?.children[1].cell?.framing == .close, "改取景：听新的")
        check(framed?.children[1].cell?.overlays == b.overlays, "改取景：这一格的字块一点没变")
        check(framed?.children[0].cell == a, "改取景：别的格子没动")

        // 改字块的字：语法里没有的设置（铺满宽度、人后、位置）留着
        var edit = described
        var cells2 = described["items"] as? [[String: Any]] ?? []
        var overlays = cells2[1]["overlays"] as? [[String: Any]] ?? []
        var lines = overlays[0]["lines"] as? [[String: Any]] ?? []
        lines[0]["text"] = "新标题"
        overlays[0]["lines"] = lines
        cells2[1]["overlays"] = overlays
        edit["items"] = cells2
        let retitled = send(edit)?.children[1].cell?.overlays.first
        check(retitled?.text.lines.first?.text == "新标题", "改字：听新的")
        check(retitled?.text.lines.first?.fitWidth == true, "改字：这一行的铺满宽度留着")
        check(retitled?.layer == .behindSubject, "改字：字块的人后留着")

        // 两张换了位置：格子整个跟着照片走（描述一样）
        let swapped = send(["split": "row", "items": [cellOnly(b, canvas, style), cellOnly(a, canvas, style)]])
        check(swapped?.children[0].cell == b, "换位置：b 整格带过去")
        check(swapped?.children[1].cell == a, "换位置：a 整格带过去")

        // 从头写的版：用户设的色调跟着照片走，模板带的不跟；"none" 能清掉；抠图不写就没有
        var fromTemplate = CollageCell.photo("t")
        fromTemplate.look = CollageLookSetting(look: .mono, strength: 0.5, fromTemplate: true)
        fromTemplate.cutout = CollageCutout(toEdge: true)
        var mine = CollageCell.photo("m")
        mine.look = CollageLookSetting(look: .sepia, strength: 0.4)
        let was = CollageNode.split(.row, 0.5, .leaf(fromTemplate), .leaf(mine))
        func design(_ text: String) -> CollageNode? {
            parsed(json(text)).map { CollageLayoutSpec.snap($0.root, onto: was) }
        }
        let fresh = design(#"{"split":"column","items":[{"photo":"t","framing":"close"},{"photo":"m","framing":"close"}]}"#)
        check(fresh?.children[0].cell?.look == nil, "模板带的色调不跟着照片走")
        check(fresh?.children[0].cell?.cutout == nil, "没写抠图就没有")
        check(fresh?.children[1].cell?.look == mine.look, "用户设的色调跟着照片走")
        let cleared = design(#"{"split":"column","items":[{"photo":"t","framing":"close"},{"photo":"m","look":"none"}]}"#)
        check(cleared?.children[1].cell?.look?.look == CollageLook.none, "look:none 能清掉")

        // 文字格改一行：细线、印章、别的行的花字留着；对齐听新的
        var rule = CollageText(lines: [CollageTextLine("第一行"), CollageTextLine("第二行")])
        rule.rule = true
        rule.lineSpacing = 0.9
        rule.lines[1].fitWidth = true
        let textRoot = CollageNode.split(.column, 0.5, .leaf(.text(rule)), p("x"))
        var textDoc = CollageLayoutSpec.describe(textRoot, canvas: canvas, style: style)
        var textItems = textDoc["items"] as? [[String: Any]] ?? []
        var block = textItems[0]["text"] as? [String: Any] ?? [:]
        var blockLines = block["lines"] as? [[String: Any]] ?? []
        blockLines[0]["text"] = "改过的"
        block["lines"] = blockLines
        block["align"] = "center"
        textItems[0]["text"] = block
        textDoc["items"] = textItems
        let textAfter = wire(textDoc).flatMap { parsed($0) }.map { CollageLayoutSpec.snap($0.root, onto: textRoot) }?.children[0].cell?.text
        check(textAfter?.lines.first?.text == "改过的", "文字格改一行：听新的")
        check(textAfter?.alignH == .center, "文字格改对齐：听新的")
        check(textAfter?.rule == true, "文字格改一行：细线留着")
        check(textAfter?.lineSpacing == 0.9, "文字格改一行：行距留着")
        check(textAfter?.lines.last?.fitWidth == true, "文字格改一行：别的行留着")

        // 显式写回默认：真的回到默认（封面取景 → 自动、拖过的位置 → 自动）
        var cover = CollageCell.photo("c")
        cover.framing = .cover
        var dragged = CollageOverlay(text: CollageText(lines: [CollageTextLine("字")]))
        dragged.anchor = .custom
        cover.overlays = [dragged]
        let coverRoot = CollageNode.leaf(cover)
        let reset = parsed(json(#"{"photo":"c","framing":"auto"}"#)).map { CollageLayoutSpec.snap($0.root, onto: coverRoot) }
        check(reset?.cell?.framing == .auto, "写 framing:auto：封面取景回到自动")
        check(reset?.cell?.overlays.isEmpty == true, "没写压字：没有")

        // 方向改了：不套旧比例
        let turned = parsed(json(#"{"split":"column","sizes":[3,2],"items":[{"photo":"a"},{"photo":"b"}]}"#))?.root
        check(turned.map { CollageLayoutSpec.snap($0, onto: old) }?.axis == .column, "方向改了听新的")
        check(CollageLayoutSpec.snap(p("a"), onto: nil) == p("a"), "没有旧版：原样")
    }

    private static func cellOnly(_ cell: CollageCell, _ canvas: CollageCanvas, _ style: CollageStyle) -> [String: Any] {
        CollageLayoutSpec.describe(.leaf(cell), canvas: canvas, style: style)
    }
}
