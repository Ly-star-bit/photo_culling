import Foundation

/// 样式预设：一键换整套「纸、缝、边、框」。
enum CollageStyles {
    struct Preset: Identifiable, Hashable {
        let key: String
        let name: String
        let style: CollageStyle
        var id: String { key }
    }

    static let all: [Preset] = [
        Preset(key: "grid", name: "极简纸白", style: make { _ in }),
        Preset(key: "white", name: "纯白", style: make { s in
            s.background = .white
        }),
        Preset(key: "dark", name: "墨黑", style: make { s in
            s.background = .charcoal
            s.gutter = 0.009
        }),
        Preset(key: "editorial", name: "杂志", style: make { s in
            s.margin = 0.064
            s.gutter = 0.016
        }),
        Preset(key: "chinese", name: "中式", style: make { s in
            s.background = .rice
            s.grain = 0.35
            s.margin = 0.07
            s.gutter = 0.02
        }),
        Preset(key: "film", name: "胶片", style: make { s in
            s.background = CollageColor(hex: 0x2A2826)
            s.border = .film
            s.margin = 0.05
            s.gutter = 0.016
            s.tightSmallCells = false
        }),
        Preset(key: "polaroid", name: "相纸", style: make { s in
            s.background = CollageColor(hex: 0xE9E4DA)
            s.grain = 0.25
            s.border = .polaroid
            s.shadow = 0.55
            s.margin = 0.07
            s.gutter = 0.034
        }),
        Preset(key: "gallery", name: "画廊", style: make { s in
            s.background = CollageColor(hex: 0xF7F6F3)
            s.border = .hairline
            s.borderColor = CollageColor(hex: 0x1D1D1F)
            s.shadow = 0.35
            s.margin = 0.08
            s.gutter = 0.03
        }),
        Preset(key: "tinted", name: "主图取色", style: make { s in
            s.backgroundMode = .fromPhoto
            s.grain = 0.15
        }),
    ]

    private static func make(_ body: (inout CollageStyle) -> Void) -> CollageStyle {
        var s = CollageStyle()
        body(&s)
        return s
    }

    static func preset(_ key: String) -> CollageStyle {
        all.first { $0.key == key }?.style ?? CollageStyle()
    }
}

/// 精选模板：每一个都是真能拿去发的版。求解器负责数量，模板负责品味。
enum CollageTemplates {

    // MARK: - 小积木

    static func photo(_ role: CollageRole = .support, shape: CollageShape? = nil, contain: Bool = false) -> CollageNode {
        var cell = CollageCell.photo(nil, role: role)
        cell.shape = shape
        cell.contain = contain
        return .leaf(cell)
    }

    static func text(_ t: CollageText) -> CollageNode { .leaf(.text(t)) }
    static func empty() -> CollageNode { .leaf(CollageCell()) }
    static func row(_ r: Double, _ a: CollageNode, _ b: CollageNode) -> CollageNode { .split(.row, r, a, b) }
    static func col(_ r: Double, _ a: CollageNode, _ b: CollageNode) -> CollageNode { .split(.column, r, a, b) }

    // MARK: - 文字块

    /// 竖排宋体大标题 + 竖排中文日期 + 细线 + 印章（杂志/中式右栏）。
    static func verticalTitle(size: Double = 0.083, seal: String = "光", date: Bool = true) -> CollageText {
        var lines = [CollageTextLine("{title}", font: .songti, weight: .light, size: size, color: .ink)]
        if date {
            lines.append(CollageTextLine("{date_cn}", font: .songti, weight: .regular, size: size * 0.24,
                                         color: .warmGrey, indent: 6.2))
        }
        var t = CollageText(lines: lines, vertical: true, alignH: .trailing, alignV: .leading)
        t.lineSpacing = 0.55
        t.rule = true
        t.seal = CollageSeal(text: seal, color: .seal, size: 0.035)
        return t
    }

    /// 右下英文小字：斜体 Didot + 加字距的大写两行。
    static func englishCaption(word: String = "Portraits") -> CollageText {
        var t = CollageText(lines: [
            CollageTextLine(word, font: .didot, weight: .regular, size: 0.043, color: .ink, italic: true),
            CollageTextLine("{month_en} · {year}", font: .didot, weight: .regular, size: 0.014, tracking: 0.3,
                            color: .warmGrey),
            CollageTextLine("{year_roman}", font: .didot, weight: .regular, size: 0.014, tracking: 0.3,
                            color: .warmGrey),
        ], vertical: false, alignH: .trailing, alignV: .trailing)
        t.lineSpacing = 0.5
        return t
    }

    static func centeredTitle() -> CollageText {
        var t = CollageText(lines: [
            CollageTextLine("{title}", font: .songti, weight: .light, size: 0.05, tracking: 0.35, color: .ink),
            CollageTextLine("{date}", font: .didot, weight: .regular, size: 0.014, tracking: 0.4, color: .warmGrey),
        ], vertical: false, alignH: .center, alignV: .center)
        t.lineSpacing = 0.9
        return t
    }

    // MARK: - 内置模板

    static let builtin: [CollageTemplate] = [
        CollageTemplate(
            name: "杂志 · 竖排标题",
            root: col(0.807,
                      row(0.748, photo(.hero), col(0.62, text(verticalTitle()), text(englishCaption()))),
                      row(0.333, photo(), row(0.5, photo(), photo()))),
            style: CollageStyles.preset("editorial"),
            canvas: CollageCanvas.social[0],
            fitAspects: false, builtin: true),
        CollageTemplate(
            name: "中式 · 月洞门",
            root: col(0.64,
                      row(0.72, photo(.hero, shape: .circle), text(verticalTitle(size: 0.075, seal: "拾光"))),
                      row(0.5, photo(shape: .arch), photo(shape: .arch))),
            style: CollageStyles.preset("chinese"),
            canvas: CollageCanvas.social[0],
            fitAspects: false, builtin: true),
        CollageTemplate(
            name: "中式 · 拱窗三联",
            root: col(0.8,
                      row(0.333, photo(shape: .arch), row(0.5, photo(.hero, shape: .arch), photo(shape: .arch))),
                      text(centeredTitle())),
            style: CollageStyles.preset("chinese"),
            canvas: CollageCanvas(name: "横幅 16:9", width: 2560, height: 1440),
            fitAspects: false, builtin: true),
        CollageTemplate(
            name: "双联",
            root: row(0.5, photo(.hero), photo()),
            fitAspects: true, builtin: true),
        CollageTemplate(
            name: "三联",
            root: row(0.333, photo(), row(0.5, photo(.hero), photo())),
            fitAspects: true, builtin: true),
        CollageTemplate(
            name: "主图 + 四宫",
            root: row(0.6, photo(.hero), col(0.5, row(0.5, photo(), photo()), row(0.5, photo(), photo()))),
            fitAspects: true, builtin: true),
        CollageTemplate(
            name: "居中标题 + 三联",
            root: col(0.2, text(centeredTitle()), row(0.333, photo(), row(0.5, photo(.hero), photo()))),
            style: CollageStyles.preset("grid"),
            canvas: CollageCanvas(name: "横幅 16:9", width: 2560, height: 1440),
            fitAspects: true, builtin: true),
        CollageTemplate(
            name: "标题 + 主图 + 双联",
            root: col(0.12, text(centeredTitle()), col(0.64, photo(.hero), row(0.5, photo(), photo()))),
            style: CollageStyles.preset("editorial"),
            canvas: CollageCanvas.social[3],
            fitAspects: true, builtin: true),
    ]

    // MARK: - 套用

    /// 主图角色的格子先拿分数最高的，其余按给定顺序填；照片不够的格子留空（占位）。
    static func apply(_ template: CollageTemplate, photos: [CollagePhotoRef],
                      context: CollageLayout.Context) -> CollageNode {
        var root = template.root
        let paths = root.leafPaths().filter { root.node(at: $0)?.cell?.kind == .photo }
        var remaining = photos
        var assignment: [[Int]: String] = [:]
        let heroPaths = paths.filter { root.node(at: $0)?.cell?.role == .hero }
        for path in heroPaths {
            guard let best = remaining.max(by: { $0.score < $1.score }) else { break }
            assignment[path] = best.id
            remaining.removeAll { $0.id == best.id }
        }
        for path in paths where assignment[path] == nil {
            guard !remaining.isEmpty else { break }
            assignment[path] = remaining.removeFirst().id
        }
        for path in paths {
            root.update(at: path) { node in node.cell?.photoID = assignment[path] }
        }
        if template.fitAspects {
            root = CollageLayout.refit(root, context: context)
        }
        return root
    }

    /// 把当前版存成模板：去掉照片，只留结构、角色、文字。
    static func template(from root: CollageNode, name: String, style: CollageStyle?, canvas: CollageCanvas?,
                         fitAspects: Bool) -> CollageTemplate {
        var stripped = root
        for path in root.leafPaths() {
            stripped.update(at: path) { node in
                guard node.cell?.kind == .photo else { return }
                node.cell?.photoID = nil
                node.cell?.crop = nil
                node.cell?.locked = false
            }
        }
        return CollageTemplate(name: name, root: stripped, style: style, canvas: canvas, fitAspects: fitAspects)
    }
}
