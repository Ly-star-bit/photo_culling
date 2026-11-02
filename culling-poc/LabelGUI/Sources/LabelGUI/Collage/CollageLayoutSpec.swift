import Foundation

/// AI 设计版式用的描述语法（MCP collage_set_layout 的 layout、collage_get_state 的 layout；命令行 layoutfile: / dumplayout）。
/// 写成多叉的（「一行三格，2:1:1」），app 换成切分树（二叉、每层一个比例：第一块 vs 其余）；读回来时把同方向接着切的
/// 并回一个多叉节点。语法全文在 collage_list_templates 的 layout_grammar 里（`grammarText`）。
///
/// 节点（JSON 对象，四种只能是一种）：
///   切分 {"split": "row" | "column", "items": [节点 × 2…6], "sizes": [正数 …]（可省 = 等分）}
///        row = 左右并排（竖缝），column = 上下堆叠（横缝）；sizes 是各块的份数（去掉所有的缝以后按份分：applyGutters）。
///   照片 {"photo": 照片 id, "framing": "auto|full|half|close|cover", "shape": "rect|rounded|arch|circle",
///        "fit": "fill|contain|contain_blur", "crop": {"x": 0…1, "y": 0…1, "zoom": 1…4}, "hero": true, "look": 色调,
///        "look_strength": 0…1, "cutout": true | {"stroke", "shadow", "to_edge"}, "overlays": [压字 …]}
///   文字 {"text": {"lines": [行 …], "align": "left|center|right", "valign": "top|middle|bottom", "vertical": bool}}
///   留白 {"empty": true}
/// 行：字符串，或 {"text": …, "font": 字体, "weight": 字重, "size": 相对画布短边, "color": "#RRGGBB" 或色名,
///     "tracking": 字距, "italic": bool}；text 里可以写 {title} {date} 这类占位符。
/// 压字：{"lines": [行 …], "anchor": 位置或 auto, "x", "y"（anchor = custom 时字块中心）, "tone": "auto|light|dark", "scrim": bool}
///
/// 语法里没有的设置（花字、细线、印章、人物挡字……）不写在描述里，靠 snap 留下来（见那里）。
/// describe 写出来的东西一定能被 parse 收下（超出取值范围的按范围写，一个节点放不下的留在最后一块里）：真实的版
/// 读出来再发回去不会被校验挡住。
enum CollageLayoutSpec {
    struct Problem: Error, Equatable {
        /// 出错的位置，如 layout.items[1].items[0].photo
        var path: String
        var message: String
        var text: String { "\(path)：\(message)" }
    }

    /// 一页最多几格：只管 AI 新设计的。这一页本来就更多（整批带进拼图不限张数）的，app 按现有格数放宽，原样发回来不挡。
    static let maxLeaves = 36
    /// --mcp 只查结构（不知道这一页现在几格）时用的上限。
    static let wireCells = 4096
    static let itemsRange = 2...6
    static let maxLines = 8
    static let maxLineChars = 400
    static let maxOverlays = 4
    static let sizeRange = 0.005...1.0
    static let trackingRange = -0.5...2.0

    struct Parsed {
        var root: CollageNode
        /// 用到的照片，按出现顺序、不重复。
        var photoIDs: [String]
        /// 出现了不止一次的照片（app 允许，但多半是写错了）：结果里提醒一声。
        var duplicates: [String]
    }

    // MARK: - 取值表（collage_list_templates 的 layout_grammar 也用它们）

    static let axes: [String: CollageAxis] = ["row": .row, "column": .column]
    static let framings: [String: CollageFraming] = ["auto": .auto, "full": .full, "half": .half, "close": .close, "cover": .cover]
    static let shapes: [String: CollageShape] = ["rect": .rect, "rounded": .rounded, "arch": .arch, "circle": .circle]
    static let fits = ["fill", "contain", "contain_blur"]
    static let aligns: [String: CollageAlign] = ["left": .leading, "center": .center, "right": .trailing]
    static let valigns: [String: CollageAlign] = ["top": .leading, "middle": .center, "bottom": .trailing]
    static let anchors: [String: CollageAnchor] = [
        "auto": .auto, "top_left": .topLeading, "top": .top, "top_right": .topTrailing,
        "left": .leading, "center": .center, "right": .trailing,
        "bottom_left": .bottomLeading, "bottom": .bottom, "bottom_right": .bottomTrailing, "custom": .custom,
        "left_column": .leftColumn, "right_column": .rightColumn, "bottom_band": .bottomBand,
    ]
    static let tones: [String: CollageTone] = ["auto": .auto, "light": .light, "dark": .dark]
    static let namedColors: [String: CollageColor] = [
        "ink": .ink, "paper": .paper, "white": .white, "charcoal": .charcoal, "warm_grey": .warmGrey,
        "rule": .rule, "seal": .seal, "rice": .rice, "black": CollageColor(hex: 0x000000),
    ]
    static var fontNames: [String] { CollageFont.allCases.map(\.rawValue) }
    static var weightNames: [String] { CollageWeight.allCases.map(\.rawValue) }

    /// collage_list_templates 的 layout_grammar（--mcp 进程里就能给，不连 app）。
    static var grammar: [String: Any] {
        var out: [String: Any] = ["grammar": grammarText]
        out["fonts"] = CollageFont.allCases.map { f -> [String: Any] in ["key": f.rawValue, "name": f.label] }
        out["weights"] = weightNames
        out["framings"] = framings.keys.sorted()
        out["shapes"] = shapes.keys.sorted()
        out["fits"] = fits
        out["anchors"] = anchors.keys.sorted()
        out["tones"] = tones.keys.sorted()
        out["named_colors"] = namedColors.keys.sorted()
        out["looks"] = CollageLook.allCases.map(\.rawValue)
        out["limits"] = ["cells": maxLeaves, "items_per_split": itemsRange.upperBound, "lines": maxLines,
                         "line_chars": maxLineChars, "overlays": maxOverlays]
        return out
    }

    private static let grammarText = """
    collage_set_layout 的 layout 是一棵树（写成 JSON 文本发过去），节点四种（只能是一种）：
    切分 {"split":"row"|"column","items":[节点…],"sizes":[份数…]}：row 左右并排，column 上下堆叠；items 2–6 块，sizes 是各块的份数（去掉所有的缝以后按份分，等分的两排缝对得齐），不写 = 等分。
    照片 {"photo":照片 id,"framing":"auto|full|half|close|cover","shape":"rect|rounded|arch|circle","fit":"fill|contain|contain_blur","crop":{"x":0–1,"y":0–1,"zoom":1–4},"hero":true,"look":色调,"look_strength":0–1,"cutout":true,"overlays":[压字…]}：只有 photo 必填。fit：fill 铺满格子（默认，按人脸裁）、contain 完整显示四周留底色、contain_blur 完整显示四周铺自己的模糊。crop 手动指定照片上的中心点（左上角 0,0）和放大倍数，给了就不再按人脸取景。hero 标主图。look 是这一格单独的色调（取值见 looks，"none" = 这一格不要色调；不写 = 跟页面，用户单独给这张照片设的色调跟着照片走）。cutout 只画抠出来的人，背景透出页面（或 {"stroke":描边,"shadow":投影,"to_edge":是否要人一直到底边}）。
    文字 {"text":{"lines":[行…],"align":"left|center|right","valign":"top|middle|bottom","vertical":true}}：一整格的字。
    留白 {"empty":true}。
    行：字符串，或 {"text":字,"font":字体,"weight":字重,"size":字号,"color":"#RRGGBB"或色名,"tracking":-0.5–2,"italic":true}。size 相对画布短边（0.005–1，正文 0.02 左右，大标题 0.08 以上；不写 0.04）。字里可以写占位符 {title} {date} {date_cn} {year} {month} {model} {lens}。
    压字：{"lines":[行…],"anchor":位置,"x":0–1,"y":0–1,"tone":"auto|light|dark","scrim":false}：压在照片上的字。anchor 不写 = auto（自动找不挡脸的地方）；custom = 字块中心放在照片的 x、y；tone auto = 按底下亮度选深浅字，scrim 默认 true（底下太花时垫一层雾面）。
    设计之前先调 collage_get_state：canvas 是画布尺寸，tray_photos 是托盘里每张照片的 id 和像素尺寸（横竖比例），layout 是这一页现在的版式，可以改一改再发回去。格子比例和照片比例差得越远裁得越多：竖图放竖格，横图放横格，一格要放完整就 fit=contain。
    读到的 layout 里没写的设置（花字、细线、印章、人物挡字这些）app 帮你留着：没改的格子原样，改了一处的格子里没改的字块、行也留着。整格换掉或者发一版全新的，就没有了。
    例子（上面一条标题，下面左边一张竖图占 3 份，右边上下两张横图占 2 份）：
    {"split":"column","sizes":[1,6],"items":[{"text":{"lines":[{"text":"春日","font":"songti","size":0.06}],"align":"center","valign":"middle"}},{"split":"row","sizes":[3,2],"items":[{"photo":"DSCF0001","hero":true},{"split":"column","items":[{"photo":"DSCF0002"},{"photo":"DSCF0003"}]}]}]}
    """

    // MARK: - 解析

    /// 解析并校验；isKnownPhoto：照片 id 认不认得（托盘里的、这一页已经在用的、这一场批量页里的）。
    /// value 是 JSON 文本（工具的 schema 这么写：树是递归的，schema 写不出又不是所有客户端都认得的 $ref）或解析好的对象。
    /// maxCells：这一页最多几格（默认 maxLeaves）；切分套几层不另外卡（一刀刀切出来的版读出来可能套得很深），最多和格数一样。
    static func parse(_ value: Any?, maxCells: Int = maxLeaves, isKnownPhoto: (String) -> Bool) -> Result<Parsed, Problem> {
        if let text = value as? String {
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                return .failure(Problem(path: "layout", message: "不是合法的 JSON"))
            }
            return parse(json, maxCells: maxCells, isKnownPhoto: isKnownPhoto)
        }
        var ids: [String] = []
        var leaves = 0
        do {
            guard let value else { throw Problem(path: "layout", message: "缺 layout") }
            let root = try node(value, path: "layout", depth: 0, ids: &ids, leaves: &leaves, maxCells: maxCells, known: isKnownPhoto)
            var seen = Set<String>()
            var twice: [String] = []
            for id in ids where !seen.insert(id).inserted && !twice.contains(id) { twice.append(id) }
            var unique = Set<String>()
            return .success(Parsed(root: root, photoIDs: ids.filter { unique.insert($0).inserted }, duplicates: twice))
        } catch let p as Problem {
            return .failure(p)
        } catch {
            return .failure(Problem(path: "layout", message: "\(error)"))
        }
    }

    private static func node(_ value: Any, path: String, depth: Int, ids: inout [String], leaves: inout Int, maxCells: Int,
                             known: (String) -> Bool) throws -> CollageNode {
        guard let o = value as? [String: Any] else { throw Problem(path: path, message: "要是一个对象") }
        let kinds = ["split", "photo", "text", "empty"].filter { o[$0] != nil }
        guard kinds.count == 1 else {
            throw Problem(path: path, message: "split / photo / text / empty 只能有一个（现在是 \(kinds.isEmpty ? "一个都没有" : kinds.joined(separator: "、"))）")
        }
        switch kinds[0] {
        case "split":
            try only(o, ["split", "items", "sizes"], path: path)
            guard depth < maxCells else { throw Problem(path: path, message: "切分最多套 \(maxCells) 层") }
            guard let name = o["split"] as? String, let axis = axes[name] else {
                throw Problem(path: path + ".split", message: "只能是 row（左右并排）或 column（上下堆叠）")
            }
            guard let items = o["items"] as? [Any], itemsRange.contains(items.count) else {
                throw Problem(path: path + ".items", message: "要 \(itemsRange.lowerBound)–\(itemsRange.upperBound) 块")
            }
            var sizes = Array(repeating: 1.0, count: items.count)
            if let raw = o["sizes"] {
                guard let list = raw as? [Any], list.count == items.count else {
                    throw Problem(path: path + ".sizes", message: "要和 items 一样多（\(items.count) 个）")
                }
                sizes = try list.enumerated().map { i, v in
                    guard let d = number(v), d.isFinite, d > 0 else {
                        throw Problem(path: path + ".sizes[\(i)]", message: "要是正数")
                    }
                    return d
                }
            }
            var children: [CollageNode] = []
            for (i, item) in items.enumerated() {
                children.append(try node(item, path: "\(path).items[\(i)]", depth: depth + 1, ids: &ids, leaves: &leaves,
                                         maxCells: maxCells, known: known))
            }
            return chain(axis, children, sizes)
        case "photo":
            try only(o, ["photo", "framing", "shape", "fit", "crop", "hero", "look", "look_strength", "cutout", "overlays"], path: path)
            leaves += 1
            guard leaves <= maxCells else { throw Problem(path: path, message: "一页最多 \(maxCells) 格") }
            guard let id = o["photo"] as? String, !id.isEmpty else { throw Problem(path: path + ".photo", message: "要照片 id") }
            guard known(id) else {
                throw Problem(path: path + ".photo", message: "没有这张照片「\(id)」（要是托盘里或这一场里的）")
            }
            ids.append(id)
            if let v = o["hero"], bool(v) == nil { throw Problem(path: path + ".hero", message: "要是 true / false") }
            var cell = CollageCell.photo(id, role: bool(o["hero"]) == true ? .hero : .auto)
            if let v = o["framing"] { cell.framing = try pick(v, framings, path: path + ".framing") }
            if let v = o["shape"] { cell.shape = try pick(v, shapes, path: path + ".shape") }
            if let v = o["fit"] {
                guard let s = v as? String, fits.contains(s) else {
                    throw Problem(path: path + ".fit", message: "只能是 " + fits.joined(separator: " / "))
                }
                cell.contain = s != "fill"
                cell.containBlur = s == "contain_blur"
            }
            if let v = o["crop"] {
                let p = path + ".crop"
                guard let c = v as? [String: Any] else { throw Problem(path: p, message: "要是 {x, y, zoom}") }
                try only(c, ["x", "y", "zoom"], path: p)
                guard let x = number(c["x"]), let y = number(c["y"]), (0...1).contains(x), (0...1).contains(y) else {
                    throw Problem(path: p, message: "x、y 要在 0–1（照片上的中心点，左上角是 0,0）")
                }
                let zoom = c["zoom"] == nil ? 1 : number(c["zoom"])
                guard let z = zoom, (1...4).contains(z) else { throw Problem(path: p + ".zoom", message: "要在 1–4") }
                cell.crop = CollageCropOverride(cx: x, cy: y, zoom: z)
            }
            if let v = o["look"] {
                guard let name = v as? String, let look = CollageLook(rawValue: name) else {
                    throw Problem(path: path + ".look", message: "没有这个色调（取值见 layout_grammar.looks）")
                }
                var setting = CollageLookSetting(look: look)
                if let k = o["look_strength"] {
                    guard let d = number(k), (0...1).contains(d) else {
                        throw Problem(path: path + ".look_strength", message: "要在 0–1")
                    }
                    setting.strength = d
                }
                cell.look = setting
            } else if o["look_strength"] != nil {
                throw Problem(path: path + ".look_strength", message: "要和 look 一起写")
            }
            if let v = o["cutout"] { cell.cutout = try cutout(v, path: path + ".cutout") }
            if let v = o["overlays"] {
                guard let list = v as? [Any], list.count <= maxOverlays else {
                    throw Problem(path: path + ".overlays", message: "最多 \(maxOverlays) 块字")
                }
                cell.overlays = try list.enumerated().map { i, item in try overlay(item, path: "\(path).overlays[\(i)]") }
            }
            return .leaf(cell)
        case "text":
            try only(o, ["text"], path: path)
            leaves += 1
            guard leaves <= maxCells else { throw Problem(path: path, message: "一页最多 \(maxCells) 格") }
            return .leaf(.text(try textBlock(o["text"] as Any, path: path + ".text")))
        default:
            try only(o, ["empty"], path: path)
            guard bool(o["empty"]) == true else { throw Problem(path: path + ".empty", message: "要写 true") }
            leaves += 1
            guard leaves <= maxCells else { throw Problem(path: path, message: "一页最多 \(maxCells) 格") }
            return .leaf(CollageCell(kind: .empty))
        }
    }

    /// n 块 → 二叉：第一块对其余（比例 = 第一块的份数 / 总份数，夹在排版引擎的上下限里），其余再这样切。
    static func chain(_ axis: CollageAxis, _ nodes: [CollageNode], _ sizes: [Double]) -> CollageNode {
        guard nodes.count > 1 else { return nodes[0] }
        let total = sizes.reduce(0, +)
        let ratio = min(1 - CollageLayout.minRatio, max(CollageLayout.minRatio, sizes[0] / total))
        return .split(axis, ratio, nodes[0], chain(axis, Array(nodes.dropFirst()), Array(sizes.dropFirst())))
    }

    private static func cutout(_ value: Any, path: String) throws -> CollageCutout? {
        if let b = bool(value) { return b ? CollageCutout() : nil }
        guard let o = value as? [String: Any] else { throw Problem(path: path, message: "要是 true / false 或 {stroke, shadow, to_edge}") }
        try only(o, ["stroke", "shadow", "to_edge"], path: path)
        var out = CollageCutout()
        if let d = try unit(o, "stroke", path: path) { out.stroke = d }
        if let d = try unit(o, "shadow", path: path) { out.shadow = d }
        if let v = o["to_edge"] {
            guard let b = bool(v) else { throw Problem(path: path + ".to_edge", message: "要是 true / false") }
            out.toEdge = b
        }
        return out
    }

    private static func textBlock(_ value: Any, path: String) throws -> CollageText {
        guard let o = value as? [String: Any] else { throw Problem(path: path, message: "要是 {lines, align, valign, vertical}") }
        try only(o, ["lines", "align", "valign", "vertical"], path: path)
        var text = CollageText()
        text.lines = try lines(o["lines"], path: path + ".lines")
        if let v = o["align"] { text.alignH = try pick(v, aligns, path: path + ".align") }
        if let v = o["valign"] { text.alignV = try pick(v, valigns, path: path + ".valign") }
        if let v = o["vertical"] {
            guard let b = bool(v) else { throw Problem(path: path + ".vertical", message: "要是 true / false") }
            text.vertical = b
        }
        return text
    }

    private static func overlay(_ value: Any, path: String) throws -> CollageOverlay {
        guard let o = value as? [String: Any] else { throw Problem(path: path, message: "要是 {lines, anchor, tone, scrim}") }
        try only(o, ["lines", "anchor", "x", "y", "tone", "scrim"], path: path)
        var text = CollageText()
        text.lines = try lines(o["lines"], path: path + ".lines")
        var overlay = CollageOverlay(text: text)
        if let v = o["anchor"] { overlay.anchor = try pick(v, anchors, path: path + ".anchor") }
        if overlay.anchor != .custom, let key = ["x", "y"].first(where: { o[$0] != nil }) {
            throw Problem(path: "\(path).\(key)", message: "只有 anchor 是 custom 时才能写")
        }
        if let d = try unit(o, "x", path: path) { overlay.x = d }
        if let d = try unit(o, "y", path: path) { overlay.y = d }
        if let v = o["tone"] { overlay.tone = try pick(v, tones, path: path + ".tone") }
        if let v = o["scrim"] {
            guard let b = bool(v) else { throw Problem(path: path + ".scrim", message: "要是 true / false") }
            overlay.scrim = b
        }
        return overlay
    }

    private static func lines(_ value: Any?, path: String) throws -> [CollageTextLine] {
        guard let list = value as? [Any], list.count <= maxLines else {
            throw Problem(path: path, message: "要是数组，最多 \(maxLines) 行")
        }
        return try list.enumerated().map { i, item in try line(item, path: "\(path)[\(i)]") }
    }

    private static func line(_ value: Any, path: String) throws -> CollageTextLine {
        if let s = value as? String {
            guard s.count <= maxLineChars else { throw Problem(path: path, message: "一行最多 \(maxLineChars) 个字") }
            return CollageTextLine(s)
        }
        guard let o = value as? [String: Any] else { throw Problem(path: path, message: "要是字符串或 {text, font, size, …}") }
        try only(o, ["text", "font", "weight", "size", "color", "tracking", "italic"], path: path)
        guard let s = o["text"] as? String else { throw Problem(path: path + ".text", message: "要字") }
        guard s.count <= maxLineChars else { throw Problem(path: path + ".text", message: "一行最多 \(maxLineChars) 个字") }
        var line = CollageTextLine(s)
        if let v = o["font"] {
            guard let name = v as? String, let f = CollageFont(rawValue: name) else {
                throw Problem(path: path + ".font", message: "没有这个字体（取值见 collage_list_templates 的 layout_grammar.fonts）")
            }
            line.font = f
        }
        if let v = o["weight"] {
            guard let name = v as? String, let w = CollageWeight(rawValue: name) else {
                throw Problem(path: path + ".weight", message: "只能是 " + weightNames.joined(separator: " / "))
            }
            line.weight = w
        }
        if let v = o["size"] {
            guard let d = number(v), sizeRange.contains(d) else {
                throw Problem(path: path + ".size", message: "要在 \(sizeRange.lowerBound)–\(sizeRange.upperBound)（相对画布短边）")
            }
            line.size = d
        }
        if let v = o["color"] { line.color = try color(v, path: path + ".color") }
        if let v = o["tracking"] {
            guard let d = number(v), trackingRange.contains(d) else { throw Problem(path: path + ".tracking", message: "要在 \(trackingRange.lowerBound)–\(trackingRange.upperBound)") }
            line.tracking = d
        }
        if let v = o["italic"] {
            guard let b = bool(v) else { throw Problem(path: path + ".italic", message: "要是 true / false") }
            line.italic = b
        }
        return line
    }

    static func color(_ value: Any, path: String) throws -> CollageColor {
        guard let s = value as? String else { throw Problem(path: path, message: "要是 \"#RRGGBB\" 或色名") }
        if let named = namedColors[s] { return named }
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
            throw Problem(path: path, message: "要是 \"#RRGGBB\" 或色名（" + namedColors.keys.sorted().joined(separator: " / ") + "）")
        }
        return CollageColor(hex: v)
    }

    private static func pick<T>(_ value: Any, _ table: [String: T], path: String) throws -> T {
        guard let s = value as? String, let v = table[s] else {
            throw Problem(path: path, message: "只能是 " + table.keys.sorted().joined(separator: " / "))
        }
        return v
    }

    private static func only(_ o: [String: Any], _ allowed: Set<String>, path: String) throws {
        if let extra = o.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Problem(path: path + "." + extra, message: "不认识这个键（这里能写：" + allowed.sorted().joined(separator: "、") + "）")
        }
    }

    private static func unit(_ o: [String: Any], _ key: String, path: String) throws -> Double? {
        guard let v = o[key] else { return nil }
        guard let d = number(v), (0...1).contains(d) else { throw Problem(path: "\(path).\(key)", message: "要在 0–1") }
        return d
    }

    /// 数（整数也算，true / false 不算）。不能用 `is Bool` 判断：JSON 里的 0、1 是 NSNumber，`as? Bool` 也会成功。
    private static func number(_ v: Any?) -> Double? {
        v.flatMap(MCPArgs.number)
    }

    private static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    // MARK: - 写回语法

    /// 切分树 → 语法：第二块接着同方向切的并成一个多叉节点；sizes 是每块实际占的份（去掉所有的缝以后，和为 1），写六位有效数字：
    /// 读回来时后面几块的比例是「这一块 / 余下的」，余下的很小时按小数位留，误差会超过 snap 的容差。
    static func describe(_ root: CollageNode, canvas: CollageCanvas, style: CollageStyle) -> [String: Any] {
        let (width, height, g) = bounds(canvas: canvas, style: style)
        return describeNode(root, width: width, height: height, g: g)
    }

    private static func bounds(canvas: CollageCanvas, style: CollageStyle) -> (Double, Double, Double) {
        let content = CollageLayout.contentRect(canvas: canvas, style: style)
        return (Double(content.width), Double(content.height), Double(CollageLayout.gutterPixels(canvas: canvas, style: style)))
    }

    /// 同方向连着切的一串（第二块接着切）里的一块：实际多长（同 CollageLayout.place，不取整）；tail、left：从这一块开始的
    /// 那个节点和它占的长度。
    private struct Link {
        let node: CollageNode
        let length: Double
        let tail: CollageNode
        let left: Double
    }

    private static func links(_ n: CollageNode, length: Double, g: Double) -> [Link] {
        var out: [Link] = []
        var left = length
        var current = n
        while !current.isLeaf, current.axis == n.axis {
            let avail = max(0, left - g)
            let first = avail * ratio(current)
            out.append(Link(node: current.children[0], length: first, tail: current, left: left))
            left = avail - first
            current = current.children[1]
        }
        out.append(Link(node: current, length: left, tail: current, left: left))
        return out
    }

    private static func describeNode(_ n: CollageNode, width: Double, height: Double, g: Double) -> [String: Any] {
        guard !n.isLeaf else { return describeCell(n.cell ?? CollageCell()) }
        let isRow = n.axis == .row
        var chain = links(n, length: isRow ? width : height, g: g)
        var gap = g
        if chain.contains(where: { $0.length <= 0 }) {
            // 小得放不下缝（版比画布还碎）：按比例本身写，不按真实长度
            gap = 0
            chain = links(n, length: 1, g: 0)
        }
        let total = chain.reduce(0) { $0 + $1.length }
        // 一个节点最多 itemsRange.upperBound 块：再多的留在最后一块里（它自己还是一个同方向的切分）
        let cap = itemsRange.upperBound
        let shown = chain.count > cap ? Array(chain.prefix(cap - 1)) : chain
        var items: [[String: Any]] = shown.map { link in
            describeNode(link.node, width: isRow ? link.length : width, height: isRow ? height : link.length, g: gap)
        }
        var sizes = shown.map { $0.length / total }
        if chain.count > cap {
            let rest = chain[cap - 1]
            items.append(describeNode(rest.tail, width: isRow ? rest.left : width, height: isRow ? height : rest.left, g: gap))
            sizes.append(chain[(cap - 1)...].reduce(0) { $0 + $1.length } / total)
        }
        return ["split": isRow ? "row" : "column", "items": items, "sizes": sizes.map(significant)]
    }

    /// parse 出来的比例是份数（chain 没管缝）：按这张画布真实的缝换成切分树的比例，让每块正好占「去掉所有的缝以后」的那几份
    /// —— 二叉的每一刀只扣自己那条缝，直接用份数的话越往后的块越窄，一排两块和一排四块的缝也对不齐。describe 的反过程。
    /// current：这一页现在的版。份数和读 current 读出来的一样的那一刀用它原来的比例（读出来的份数留了六位有效数字，也不是
    /// 每个版都换算得回来：有的版碎得放不下缝），原样发回来一定一模一样。
    static func applyGutters(_ root: CollageNode, canvas: CollageCanvas, style: CollageStyle, current: CollageNode? = nil) -> CollageNode {
        let (width, height, g) = bounds(canvas: canvas, style: style)
        let exact = gutterFitted(root, width: width, height: height, g: g)
        guard let current, case .success(let readBack) = parse(describe(current, canvas: canvas, style: style), maxCells: wireCells,
                                                               isKnownPhoto: { _ in true }) else { return exact }
        return keptRatios(exact, shares: root, readBack: readBack.root, current: current)
    }

    private static func keptRatios(_ exact: CollageNode, shares: CollageNode, readBack: CollageNode, current: CollageNode) -> CollageNode {
        guard !exact.isLeaf, !shares.isLeaf, !readBack.isLeaf, !current.isLeaf, shares.axis == readBack.axis, readBack.axis == current.axis else {
            return exact
        }
        var out = exact
        if abs(shares.ratio - readBack.ratio) < 0.0005 { out.ratio = current.ratio }
        out.children = [0, 1].map { i in
            keptRatios(exact.children[i], shares: shares.children[i], readBack: readBack.children[i], current: current.children[i])
        }
        return out
    }

    private static func gutterFitted(_ n: CollageNode, width: Double, height: Double, g: Double) -> CollageNode {
        guard !n.isLeaf else { return n }
        let isRow = n.axis == .row
        var nodes: [CollageNode] = []
        var shares: [Double] = []
        var rest = 1.0
        var current = n
        while !current.isLeaf, current.axis == n.axis {
            nodes.append(current.children[0])
            shares.append(rest * ratio(current))
            rest *= 1 - ratio(current)
            current = current.children[1]
        }
        nodes.append(current)
        shares.append(rest)
        let length = isRow ? width : height
        let usable = length - g * Double(nodes.count - 1)
        // 放不下缝：比例不动
        let gap = usable > 0 ? g : 0
        let lengths = shares.map { $0 * (usable > 0 ? usable : length) }
        func fitted(_ i: Int) -> CollageNode {
            gutterFitted(nodes[i], width: isRow ? lengths[i] : width, height: isRow ? height : lengths[i], g: g)
        }
        var out = fitted(nodes.count - 1)
        var left = lengths[nodes.count - 1]
        for i in (0..<(nodes.count - 1)).reversed() {
            let avail = lengths[i] + left
            out = .split(n.axis, clamp(lengths[i] / max(avail, 1e-9), CollageLayout.minRatio...(1 - CollageLayout.minRatio)), fitted(i), out)
            left = avail + gap
        }
        return out
    }

    static func describeCell(_ cell: CollageCell) -> [String: Any] {
        switch cell.kind {
        case .empty:
            return ["empty": true]
        case .text:
            return ["text": describeText(cell.text ?? CollageText())]
        case .photo:
            // 没放照片的格子（托盘拿掉了照片）在语法里就是留白
            guard let id = cell.photoID, !id.isEmpty else { return ["empty": true] }
            var o: [String: Any] = ["photo": id]
            if cell.framing != .auto, let k = framings.first(where: { $0.value == cell.framing })?.key { o["framing"] = k }
            if let shape = cell.shape, let k = shapes.first(where: { $0.value == shape })?.key { o["shape"] = k }
            if cell.contain { o["fit"] = cell.containBlur ? "contain_blur" : "contain" }
            if let c = cell.crop {
                o["crop"] = ["x": round4(clamp(c.cx, 0...1)), "y": round4(clamp(c.cy, 0...1)), "zoom": round4(clamp(c.zoom, 1...4))]
            }
            if cell.role == .hero { o["hero"] = true }
            if let look = cell.look {
                o["look"] = look.look.rawValue
                o["look_strength"] = round4(clamp(look.strength, 0...1))
            }
            if let cut = cell.cutout {
                if cut == CollageCutout() {
                    o["cutout"] = true
                } else {
                    o["cutout"] = ["stroke": round4(clamp(cut.stroke, 0...1)), "shadow": round4(clamp(cut.shadow, 0...1)),
                                   "to_edge": cut.toEdge] as [String: Any]
                }
            }
            if !cell.overlays.isEmpty {
                o["overlays"] = cell.overlays.prefix(maxOverlays).map(describeOverlay)
            }
            return o
        }
    }

    private static func describeOverlay(_ ov: CollageOverlay) -> [String: Any] {
        var d: [String: Any] = ["lines": ov.text.lines.prefix(maxLines).map(describeLine)]
        if ov.anchor != .auto, let k = anchors.first(where: { $0.value == ov.anchor })?.key { d["anchor"] = k }
        if ov.anchor == .custom {
            d["x"] = round4(clamp(ov.x, 0...1))
            d["y"] = round4(clamp(ov.y, 0...1))
        }
        if ov.tone != .auto, let k = tones.first(where: { $0.value == ov.tone })?.key { d["tone"] = k }
        if !ov.scrim { d["scrim"] = false }
        return d
    }

    private static func describeText(_ t: CollageText) -> [String: Any] {
        var o: [String: Any] = ["lines": t.lines.prefix(maxLines).map(describeLine)]
        if t.alignH != .leading, let k = aligns.first(where: { $0.value == t.alignH })?.key { o["align"] = k }
        if t.alignV != .leading, let k = valigns.first(where: { $0.value == t.alignV })?.key { o["valign"] = k }
        if t.vertical { o["vertical"] = true }
        return o
    }

    private static func describeLine(_ l: CollageTextLine) -> [String: Any] {
        var o: [String: Any] = ["text": String(l.text.prefix(maxLineChars)), "font": l.font.rawValue]
        o["size"] = round4(clamp(l.size, sizeRange))
        o["color"] = hex(l.color)
        if l.weight != .regular { o["weight"] = l.weight.rawValue }
        // 四舍五入以后是 0 的不写（写了就是 0，读回来和不写一样）
        if abs(l.tracking) >= 0.00005 { o["tracking"] = round4(clamp(l.tracking, trackingRange)) }
        if l.italic { o["italic"] = true }
        return o
    }

    static func hex(_ c: CollageColor) -> String {
        func b(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }

    /// 写进 JSON 的数：用十进制的 NSDecimalNumber（Double 经 JSONSerialization 会写成 0.69230800000000003）。
    static func round4(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.4f", v)) }
    private static func significant(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.6g", v)) }
    private static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double { min(range.upperBound, max(range.lowerBound, v)) }
    /// 渲染实际用的比例（存着的超出上下限时按上下限画）。
    private static func ratio(_ n: CollageNode) -> Double { clamp(n.ratio, CollageLayout.minRatio...(1 - CollageLayout.minRatio)) }

    // MARK: - 语法里没有的设置留下来

    /// 新树对上旧树，语法里没有的设置（花字、细线、印章、人物挡字……）留下来；什么都没改的版发回来和原来一模一样：
    /// - 形状一样的切分，比例差在 0.0005 以内用旧比例；
    /// - 描述和旧格子一样的格子用旧格子：先看同一个位置，再看别的位置（切分多叉换成二叉，加一块、外面再包一层，后面的
    ///   格子位置全变了，它们还是没改过的）；
    /// - 改过的格子：同一张照片的单格色调（模板带的不算，同套模板）、锁定跟着照片走，没改的字块、行留着；文字格同理。
    static func snap(_ new: CollageNode, onto old: CollageNode?) -> CollageNode {
        guard let old else { return new }
        var out = alignRatios(new, old)
        var slots = old.leafPaths().compactMap { path -> OldCell? in
            old.node(at: path)?.cell.map { OldCell(path: path, cell: $0, key: key($0)) }
        }
        let paths = new.leafPaths()
        var settled: [[Int]: CollageCell] = [:]
        // 同一个位置、一样的
        for path in paths {
            guard let cell = new.node(at: path)?.cell, let i = slots.firstIndex(where: { $0.path == path }), slots[i].key == key(cell) else { continue }
            settled[path] = slots[i].cell
            slots[i].used = true
        }
        // 别的位置、一样的
        for path in paths where settled[path] == nil {
            guard let cell = new.node(at: path)?.cell, let i = slots.firstIndex(where: { !$0.used && $0.key == key(cell) }) else { continue }
            settled[path] = slots[i].cell
            slots[i].used = true
        }
        // 改过的
        for path in paths where settled[path] == nil {
            guard let cell = new.node(at: path)?.cell else { continue }
            settled[path] = edited(cell, at: path, slots: &slots)
        }
        for (path, cell) in settled {
            out.update(at: path) { $0.cell = cell }
        }
        return out
    }

    private struct OldCell {
        let path: [Int]
        let cell: CollageCell
        let key: String
        var used = false
    }

    private static func key(_ cell: CollageCell) -> String {
        MCPJSON.data(describeCell(cell)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func alignRatios(_ new: CollageNode, _ old: CollageNode?) -> CollageNode {
        guard !new.isLeaf else { return new }
        var out = new
        var firstOld: CollageNode?
        var secondOld: CollageNode?
        if let old, !old.isLeaf, old.axis == new.axis {
            if abs(new.ratio - ratio(old)) < 0.0005 { out.ratio = old.ratio }
            firstOld = old.children[0]
            secondOld = old.children[1]
        }
        out.children = [alignRatios(new.children[0], firstOld), alignRatios(new.children[1], secondOld)]
        return out
    }

    /// 没找到一样的旧格子：照片格找同一张照片（同一个位置的优先），文字格找同一个位置的（行数一样或者有一行字没变）、
    /// 再找别处有一行字没变的。
    private static func edited(_ cell: CollageCell, at path: [Int], slots: inout [OldCell]) -> CollageCell {
        switch cell.kind {
        case .empty:
            return cell
        case .photo:
            guard let id = cell.photoID else { return cell }
            let same: (OldCell) -> Bool = { !$0.used && $0.cell.photoID == id }
            guard let i = slots.firstIndex(where: { same($0) && $0.path == path }) ?? slots.firstIndex(where: same) else { return cell }
            slots[i].used = true
            return merged(photo: cell, was: slots[i].cell)
        case .text:
            guard let text = cell.text else { return cell }
            let words = Set(text.lines.map(\.text))
            func shares(_ t: CollageText) -> Bool { t.lines.contains { words.contains($0.text) } }
            let here = slots.firstIndex { slot in
                guard !slot.used, slot.path == path, slot.cell.kind == .text, let t = slot.cell.text else { return false }
                return t.lines.count == text.lines.count || shares(t)
            }
            let elsewhere = slots.firstIndex { slot in
                guard !slot.used, slot.cell.kind == .text, let t = slot.cell.text else { return false }
                return shares(t)
            }
            guard let i = here ?? elsewhere, let was = slots[i].cell.text else { return cell }
            slots[i].used = true
            var out = slots[i].cell
            var block = mergedLines(text, was: was)
            block.alignH = text.alignH
            block.alignV = text.alignV
            block.vertical = text.vertical
            out.text = block
            return out
        }
    }

    private static func merged(photo cell: CollageCell, was: CollageCell) -> CollageCell {
        var out = cell
        if let look = out.look {
            if let old = was.look, old.look == look.look, round4(old.strength) == round4(look.strength) { out.look = old }
        } else if was.look?.fromTemplate == false {
            out.look = was.look
        }
        if let cut = out.cutout, let old = was.cutout, key(cutoutOnly(cut)) == key(cutoutOnly(old)) { out.cutout = old }
        out.locked = was.locked
        if out.role == .auto, was.role == .support { out.role = .support }
        out.coverAuto = was.coverAuto && out.framing == was.framing
        out.overlays = mergedOverlays(cell.overlays, was: was.overlays)
        return out
    }

    private static func cutoutOnly(_ cut: CollageCutout) -> CollageCell {
        var cell = CollageCell.photo("-")
        cell.cutout = cut
        return cell
    }

    /// 和旧字块描述一样的用旧的；其余的按顺序对上同一个下标的旧字块，没写的设置留着。
    private static func mergedOverlays(_ new: [CollageOverlay], was: [CollageOverlay]) -> [CollageOverlay] {
        func overlayKey(_ ov: CollageOverlay) -> Data? { MCPJSON.data(describeOverlay(ov)) }
        var used = Set<Int>()
        var out: [CollageOverlay?] = Array(repeating: nil, count: new.count)
        for (i, ov) in new.enumerated() {
            guard let j = was.indices.first(where: { !used.contains($0) && overlayKey(was[$0]) == overlayKey(ov) }) else { continue }
            out[i] = was[j]
            used.insert(j)
        }
        return new.enumerated().map { i, ov in
            if let kept = out[i] { return kept }
            guard was.indices.contains(i), !used.contains(i) else { return ov }
            var merged = was[i]
            merged.text = mergedLines(ov.text, was: was[i].text)
            merged.anchor = ov.anchor
            merged.x = ov.x
            merged.y = ov.y
            merged.tone = ov.tone
            merged.scrim = ov.scrim
            return merged
        }
    }

    /// 文字块：旧的那些设置留着，行按下标对上旧行：描述一样的用旧行，改过的只换语法里有的那几项。
    private static func mergedLines(_ new: CollageText, was: CollageText) -> CollageText {
        var out = was
        out.lines = new.lines.enumerated().map { i, line in
            guard was.lines.indices.contains(i) else { return line }
            let old = was.lines[i]
            if MCPJSON.data(describeLine(old)) == MCPJSON.data(describeLine(line)) { return old }
            var merged = old
            merged.text = line.text
            merged.font = line.font
            merged.weight = line.weight
            merged.size = line.size
            merged.tracking = line.tracking
            merged.italic = line.italic
            if hex(line.color) != hex(old.color) { merged.color = line.color }
            return merged
        }
        return out
    }
}
