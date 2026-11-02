import Foundation

/// AI 设计版式用的描述语法（MCP collage_set_layout 的 layout、collage_get_state 的 layout；命令行 layoutfile: / dumplayout）。
/// 写成多叉的（「一行三格，2:1:1」），app 换成切分树（二叉、每层一个比例：第一块 vs 其余）；读回来时把同方向接着切的
/// 并回一个多叉节点。语法全文在 collage_list_templates 的 layout_grammar 里（`grammar`），README 里也有。
///
/// 节点（JSON 对象，四种只能是一种）：
///   切分 {"split": "row" | "column", "items": [节点 × 2…6], "sizes": [正数 …]（可省 = 等分）}
///        row = 左右并排（竖缝），column = 上下堆叠（横缝）；sizes 是各块的份数（去掉缝以后按份分）。
///   照片 {"photo": 照片 id, "framing": "auto|full|half|close", "shape": "rect|rounded|arch|circle",
///        "fit": "fill|contain|contain_blur", "crop": {"x": 0…1, "y": 0…1, "zoom": 1…4}, "hero": true, "overlays": [压字 …]}
///   文字 {"text": {"lines": [行 …], "align": "left|center|right", "valign": "top|middle|bottom", "vertical": bool}}
///   留白 {"empty": true}
/// 行：字符串，或 {"text": …, "font": 字体, "weight": 字重, "size": 0.01…0.3（相对画布短边）, "color": "#RRGGBB" 或色名,
///     "tracking": -0.2…1, "italic": bool}；text 里可以写 {title} {date} 这类占位符。
/// 压字：{"lines": [行 …], "anchor": 九宫格位置或 auto, "tone": "auto|light|dark", "scrim": bool}
///
/// 原样发回来不改东西（snap）：和原来同一个位置、形状一样的切分，比例差在 0.0005 以内用原来的；描述和原来一模一样的
/// 格子用原来的格子 —— 语法里没有的设置（抠图、人物挡字、单格色调……）不会因为 AI 读出来再发回去就丢了。
/// describe 写出来的东西一定能被 parse 收下（超出取值范围的按范围写，一个节点放不下的留在最后一块里）：真实的版
/// 读出来再发回去不会被校验挡住。
enum CollageLayoutSpec {
    struct Problem: Error, Equatable {
        /// 出错的位置，如 layout.items[1].items[0].photo
        var path: String
        var message: String
        var text: String { "\(path)：\(message)" }
    }

    static let maxLeaves = 36
    /// 只防递归太深：能发回去的一定要收（用户一刀刀切出来的版读出来可能套得很深）。
    static let maxDepth = 24
    static let itemsRange = 2...6
    static let maxLines = 8
    static let maxLineChars = 400
    static let maxOverlays = 4
    static let sizeRange = 0.01...0.3
    static let trackingRange = -0.2...1.0

    struct Parsed {
        var root: CollageNode
        /// 用到的照片，按出现顺序、不重复。
        var photoIDs: [String]
        /// 出现了不止一次的照片（app 允许，但多半是写错了）：结果里提醒一声。
        var duplicates: [String]
    }

    // MARK: - 取值表（collage_list_templates 的 layout_grammar 也用它们）

    static let axes: [String: CollageAxis] = ["row": .row, "column": .column]
    static let framings: [String: CollageFraming] = ["auto": .auto, "full": .full, "half": .half, "close": .close]
    static let shapes: [String: CollageShape] = ["rect": .rect, "rounded": .rounded, "arch": .arch, "circle": .circle]
    static let fits = ["fill", "contain", "contain_blur"]
    static let aligns: [String: CollageAlign] = ["left": .leading, "center": .center, "right": .trailing]
    static let valigns: [String: CollageAlign] = ["top": .leading, "middle": .center, "bottom": .trailing]
    static let anchors: [String: CollageAnchor] = [
        "auto": .auto, "top_left": .topLeading, "top": .top, "top_right": .topTrailing,
        "left": .leading, "center": .center, "right": .trailing,
        "bottom_left": .bottomLeading, "bottom": .bottom, "bottom_right": .bottomTrailing,
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
        out["limits"] = ["cells": maxLeaves, "items_per_split": itemsRange.upperBound, "lines": maxLines,
                         "line_chars": maxLineChars, "overlays": maxOverlays]
        return out
    }

    private static let grammarText = """
    collage_set_layout 的 layout 是一棵树（写成 JSON 文本发过去），节点四种（只能是一种）：
    切分 {"split":"row"|"column","items":[节点…],"sizes":[份数…]}：row 左右并排，column 上下堆叠；items 2–6 块，sizes 是各块的份数（去掉缝以后按份分），不写 = 等分。
    照片 {"photo":照片 id,"framing":"auto|full|half|close","shape":"rect|rounded|arch|circle","fit":"fill|contain|contain_blur","crop":{"x":0–1,"y":0–1,"zoom":1–4},"hero":true,"overlays":[压字…]}：只有 photo 必填。fit：fill 铺满格子（默认，按人脸裁）、contain 完整显示四周留底色、contain_blur 完整显示四周铺自己的模糊。crop 手动指定照片上的中心点（左上角 0,0）和放大倍数，给了就不再按人脸取景。hero 标主图。
    文字 {"text":{"lines":[行…],"align":"left|center|right","valign":"top|middle|bottom","vertical":true}}：一整格的字。
    留白 {"empty":true}。
    行：字符串，或 {"text":字,"font":字体,"weight":字重,"size":字号,"color":"#RRGGBB"或色名,"tracking":-0.2–1,"italic":true}。size 相对画布短边（0.01–0.3，正文 0.02 左右，大标题 0.08 以上）。字里可以写占位符 {title} {date} {date_cn} {year} {month} {model} {lens}。
    压字：{"lines":[行…],"anchor":位置,"tone":"auto|light|dark","scrim":false}：压在照片上的字。anchor 不写 = auto（自动找不挡脸的地方），tone auto = 按底下亮度选深浅字，scrim 默认 true（底下太花时垫一层雾面）。
    设计之前先调 collage_get_state：canvas 是画布尺寸，tray_photos 是托盘里每张照片的 id 和像素尺寸（横竖比例），layout 是这一页现在的版式，可以改一改再发回去。格子比例和照片比例差得越远裁得越多：竖图放竖格，横图放横格，一格要放完整就 fit=contain。
    例子（上面一条标题，下面左边一张竖图占 3 份，右边上下两张横图占 2 份）：
    {"split":"column","sizes":[1,6],"items":[{"text":{"lines":[{"text":"春日","font":"songti","size":0.06}],"align":"center","valign":"middle"}},{"split":"row","sizes":[3,2],"items":[{"photo":"DSCF0001","hero":true},{"split":"column","items":[{"photo":"DSCF0002"},{"photo":"DSCF0003"}]}]}]}
    """

    // MARK: - 解析

    /// 解析并校验；isKnownPhoto：照片 id 认不认得（托盘里的、这一页已经在用的、这一场批量页里的）。
    /// value 是 JSON 文本（工具的 schema 这么写：树是递归的，schema 写不出又不是所有客户端都认得的 $ref）或解析好的对象。
    static func parse(_ value: Any?, isKnownPhoto: (String) -> Bool) -> Result<Parsed, Problem> {
        if let text = value as? String {
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                return .failure(Problem(path: "layout", message: "不是合法的 JSON"))
            }
            return parse(json, isKnownPhoto: isKnownPhoto)
        }
        var ids: [String] = []
        var leaves = 0
        do {
            guard let value else { throw Problem(path: "layout", message: "缺 layout") }
            let root = try node(value, path: "layout", depth: 0, ids: &ids, leaves: &leaves, known: isKnownPhoto)
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

    private static func node(_ value: Any, path: String, depth: Int, ids: inout [String], leaves: inout Int,
                             known: (String) -> Bool) throws -> CollageNode {
        guard let o = value as? [String: Any] else { throw Problem(path: path, message: "要是一个对象") }
        let kinds = ["split", "photo", "text", "empty"].filter { o[$0] != nil }
        guard kinds.count == 1 else {
            throw Problem(path: path, message: "split / photo / text / empty 只能有一个（现在是 \(kinds.isEmpty ? "一个都没有" : kinds.joined(separator: "、"))）")
        }
        switch kinds[0] {
        case "split":
            try only(o, ["split", "items", "sizes"], path: path)
            guard depth < maxDepth else { throw Problem(path: path, message: "切分最多套 \(maxDepth) 层") }
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
                                         known: known))
            }
            return chain(axis, children, sizes)
        case "photo":
            try only(o, ["photo", "framing", "shape", "fit", "crop", "hero", "overlays"], path: path)
            leaves += 1
            guard leaves <= maxLeaves else { throw Problem(path: path, message: "一页最多 \(maxLeaves) 格") }
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
            guard leaves <= maxLeaves else { throw Problem(path: path, message: "一页最多 \(maxLeaves) 格") }
            return .leaf(.text(try textBlock(o["text"] as Any, path: path + ".text")))
        default:
            try only(o, ["empty"], path: path)
            guard bool(o["empty"]) == true else { throw Problem(path: path + ".empty", message: "要写 true") }
            leaves += 1
            guard leaves <= maxLeaves else { throw Problem(path: path, message: "一页最多 \(maxLeaves) 格") }
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
        try only(o, ["lines", "anchor", "tone", "scrim"], path: path)
        var text = CollageText()
        text.lines = try lines(o["lines"], path: path + ".lines")
        var overlay = CollageOverlay(text: text)
        if let v = o["anchor"] { overlay.anchor = try pick(v, anchors, path: path + ".anchor") }
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
            guard let d = number(v), trackingRange.contains(d) else { throw Problem(path: path + ".tracking", message: "要在 -0.2–1") }
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

    /// 数（整数也算，true / false 不算）。不能用 `is Bool` 判断：JSON 里的 0、1 是 NSNumber，`as? Bool` 也会成功。
    private static func number(_ v: Any?) -> Double? {
        v.flatMap(MCPArgs.number)
    }

    private static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    // MARK: - 写回语法

    /// 切分树 → 语法：第二块接着同方向切的并成一个多叉节点；sizes 写成和为 1 的小数。留六位有效数字（不是六位小数）：
    /// 读回来时后面几块的比例是「这一块 / 余下的」，余下的很小时按小数位留，误差会超过 snap 的容差。
    static func describe(_ n: CollageNode) -> [String: Any] {
        guard !n.isLeaf else { return describeCell(n.cell ?? CollageCell()) }
        var items = [n.children[0]]
        var sizes = [ratio(n)]
        var rest = 1 - ratio(n)
        var current = n.children[1]
        // 一个节点最多 itemsRange.upperBound 块：再多的留在最后一块里（它自己还是一个同方向的切分）
        while !current.isLeaf, current.axis == n.axis, items.count < itemsRange.upperBound - 1 {
            items.append(current.children[0])
            sizes.append(rest * ratio(current))
            rest *= 1 - ratio(current)
            current = current.children[1]
        }
        items.append(current)
        sizes.append(rest)
        return ["split": n.axis == .row ? "row" : "column", "items": items.map(describe), "sizes": sizes.map(significant)]
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
            if !cell.overlays.isEmpty {
                o["overlays"] = cell.overlays.prefix(maxOverlays).map { ov -> [String: Any] in
                    var d: [String: Any] = ["lines": ov.text.lines.prefix(maxLines).map(describeLine)]
                    // 拖过的位置（custom）、封面的左栏 / 右栏 / 底条语法里没有：不写（当 auto 读）；原样发回来时 snap
                    // 按描述对上旧格子，原来的位置留着
                    if let k = anchors.first(where: { $0.value == ov.anchor })?.key, k != "auto" { d["anchor"] = k }
                    if ov.tone != .auto, let k = tones.first(where: { $0.value == ov.tone })?.key { d["tone"] = k }
                    if !ov.scrim { d["scrim"] = false }
                    return d
                }
            }
            return o
        }
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
        if l.tracking != 0 { o["tracking"] = round4(clamp(l.tracking, trackingRange)) }
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

    // MARK: - 原样发回来不改东西

    /// 新树按位置对上旧树：形状一样的切分、比例差在 0.0005 以内用旧比例；描述和旧格子一样的格子用旧格子（带着语法里
    /// 没有的设置）。没对上的格子，同一张照片在旧树上的单独设置（色调、抠图、锁定）跟着照片走（同套模板）。
    static func snap(_ new: CollageNode, onto old: CollageNode?) -> CollageNode {
        guard let old else { return new }
        var kept: [String: CollageCell] = [:]
        for cell in old.leaves {
            if let id = cell.photoID, kept[id] == nil { kept[id] = cell }
        }
        return align(new, old, kept)
    }

    private static func align(_ new: CollageNode, _ old: CollageNode?, _ kept: [String: CollageCell]) -> CollageNode {
        if new.isLeaf {
            if let old, old.isLeaf, let oc = old.cell, let nc = new.cell, same(describeCell(oc), describeCell(nc)) { return old }
            guard var cell = new.cell, let id = cell.photoID, let was = kept[id] else { return new }
            cell.look = was.look
            cell.cutout = was.cutout
            cell.locked = was.locked
            var out = new
            out.cell = cell
            return out
        }
        var out = new
        var firstOld: CollageNode?
        var secondOld: CollageNode?
        if let old, !old.isLeaf, old.axis == new.axis {
            if abs(new.ratio - ratio(old)) < 0.0005 { out.ratio = old.ratio }
            firstOld = old.children[0]
            secondOld = old.children[1]
        }
        out.children = [align(new.children[0], firstOld, kept), align(new.children[1], secondOld, kept)]
        return out
    }

    private static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let x = try? JSONSerialization.data(withJSONObject: a, options: opts),
              let y = try? JSONSerialization.data(withJSONObject: b, options: opts) else { return false }
        return x == y
    }
}
