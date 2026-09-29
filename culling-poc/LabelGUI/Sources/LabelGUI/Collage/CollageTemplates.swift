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
            s.look = .film
            s.lookStrength = 0.6
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
        Preset(key: "airy", name: "日系清透", style: make { s in
            s.background = CollageColor(hex: 0xF8F7F4)
            s.margin = 0.07
            s.gutter = 0.022
            s.look = .airy
            s.lookStrength = 0.7
            s.harmonize = 0.5
        }),
        Preset(key: "cinema", name: "电影", style: make { s in
            s.background = CollageColor(hex: 0x0E0E0F)
            s.margin = 0.03
            s.gutter = 0.012
            s.look = .cinema
            s.lookStrength = 0.75
            s.harmonize = 0.5
        }),
        Preset(key: "journal", name: "手账", style: make { s in
            s.background = CollageColor(hex: 0xEDE6D8)
            s.grain = 0.35
            s.look = .film
            s.lookStrength = 0.45
            s.harmonize = 0.4
        }),
        Preset(key: "cover", name: "封面", style: make { s in
            s.background = .white
            s.margin = 0
            s.gutter = 0
            s.harmonize = 0.3
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

    /// 带压字的照片格。
    static func photo(_ role: CollageRole = .support, shape: CollageShape? = nil, overlay: CollageOverlay?) -> CollageNode {
        var cell = CollageCell.photo(nil, role: role)
        cell.shape = shape
        cell.overlay = overlay
        return .leaf(cell)
    }
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

    /// 杂志角落的大号期数：{no} + 标题 + 日期，左对齐贴底。
    static func bigNumber() -> CollageText {
        var t = CollageText(lines: [
            CollageTextLine("{no}", font: .bodoni, weight: .regular, size: 0.15, color: .ink),
            CollageTextLine("{title}", font: .songti, weight: .light, size: 0.024, tracking: 0.5, color: .ink),
            CollageTextLine("{month_en} · {year}", font: .didot, weight: .regular, size: 0.011, tracking: 0.45,
                            color: .warmGrey),
        ], vertical: false, alignH: .leading, alignV: .trailing)
        t.lineSpacing = 0.3
        return t
    }

    /// 引语：大引号 + 标题 + 英文月份。
    static func quote() -> CollageText {
        var t = CollageText(lines: [
            CollageTextLine("“", font: .didot, weight: .regular, size: 0.09, color: .rule),
            CollageTextLine("{title}", font: .songti, weight: .light, size: 0.034, tracking: 0.15, color: .ink),
            CollageTextLine("{month_en} {day}, {year}", font: .didot, weight: .regular, size: 0.012,
                            tracking: 0.35, color: .warmGrey, italic: true),
        ], vertical: false, alignH: .leading, alignV: .center)
        t.lineSpacing = 0.25
        return t
    }

    /// 照片下的小图注：标题小字加宽字距 + 日期。
    static func smallCaption() -> CollageText {
        var t = CollageText(lines: [
            CollageTextLine("{title}", font: .songti, weight: .regular, size: 0.022, tracking: 0.5, color: .ink),
            CollageTextLine("{date}", font: .didot, weight: .regular, size: 0.011, tracking: 0.45, color: .warmGrey),
        ], vertical: false, alignH: .center, alignV: .center)
        t.lineSpacing = 0.8
        return t
    }

    /// 目录页页眉。
    static func contentsHeader() -> CollageText {
        var t = CollageText(lines: [
            CollageTextLine("{title}", font: .songti, weight: .bold, size: 0.05, tracking: 0.12, color: .ink),
            CollageTextLine("CONTENTS · NO.{no} · {year}", font: .didot, weight: .regular, size: 0.012,
                            tracking: 0.5, color: .warmGrey),
        ], vertical: false, alignH: .leading, alignV: .center)
        t.lineSpacing = 0.45
        t.rule = true
        return t
    }

    /// 竖排诗句 + 全日期 + 印章（中式留白）。
    static func verticalPoem() -> CollageText {
        var t = CollageText(lines: [
            CollageTextLine("{title}", font: .songti, weight: .regular, size: 0.052, tracking: 0.2, color: .ink),
            CollageTextLine("{date_cn_full}", font: .kaiti, weight: .regular, size: 0.017, color: .warmGrey, indent: 7),
        ], vertical: true, alignH: .center, alignV: .center)
        t.lineSpacing = 0.9
        t.seal = CollageSeal(text: "拾光", color: .seal, size: 0.03)
        return t
    }

    /// 编号小字压在照片角上（目录页）。
    static func numberOverlay(_ n: Int) -> CollageOverlay {
        let t = CollageText(lines: [
            CollageTextLine(String(format: "%02d", n), font: .didot, weight: .regular, size: 0.034, color: .white,
                            italic: true),
        ], vertical: false, alignH: .leading, alignV: .leading)
        var o = CollageOverlay(text: t)
        o.anchor = .bottomLeading
        o.inset = 0.07
        o.shadow = 0.6
        return o
    }

    /// 电影字幕（默认一句，可改）。
    static func subtitleOverlay(_ line: String) -> CollageOverlay {
        var o = CollageOverlays.preset("subtitle") ?? CollageOverlay(text: CollageText())
        if !o.text.lines.isEmpty { o.text.lines[0].text = line }
        return o
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

    static let builtin: [CollageTemplate] = cover + magazine + chinese + grid9 + journal + cinema + basics

    private static let xhs = CollageCanvas.social[0]
    private static let square9 = CollageCanvas.social[2]
    private static let banner = CollageCanvas(name: "横幅 16:9", width: 2560, height: 1440)

    // MARK: 小红书封面

    private static let cover: [CollageTemplate] = [
        CollageTemplate(
            name: "封面 · 刊头大图",
            root: photo(.hero, overlay: CollageOverlays.preset("masthead")),
            style: CollageStyles.preset("cover"), canvas: xhs,
            fitAspects: false, builtin: true, category: "小红书封面"),
        CollageTemplate(
            name: "封面 · 期数大图",
            root: col(0.7, photo(.hero, overlay: CollageOverlays.preset("number")), row(0.333, photo(), row(0.5, photo(), photo()))),
            style: {
                var s = CollageStyles.preset("white")
                s.margin = 0.03
                s.gutter = 0.008
                return s
            }(), canvas: xhs,
            fitAspects: false, builtin: true, category: "小红书封面"),
        CollageTemplate(
            name: "封面 · 对角双图",
            root: col(0.56, row(0.6, photo(.hero), text(bigNumber())), row(0.4, text(quote()), photo())),
            style: CollageStyles.preset("editorial"), canvas: xhs,
            fitAspects: false, builtin: true, category: "小红书封面"),
        CollageTemplate(
            name: "封面 · 四宫中缝标题",
            root: col(0.44, row(0.5, photo(.hero), photo()), col(0.22, text(centeredTitle()), row(0.5, photo(), photo()))),
            style: CollageStyles.preset("white"), canvas: xhs,
            fitAspects: false, builtin: true, category: "小红书封面"),
        CollageTemplate(
            name: "封面 · 手写一句",
            root: photo(.hero, overlay: CollageOverlays.preset("handwrite")),
            style: {
                var s = CollageStyles.preset("white")
                s.margin = 0.045
                s.look = .airy
                s.lookStrength = 0.6
                return s
            }(), canvas: xhs,
            fitAspects: false, builtin: true, category: "小红书封面"),
    ]

    // MARK: 日系杂志

    private static let magazine: [CollageTemplate] = [
        CollageTemplate(
            name: "杂志 · 竖排标题",
            root: col(0.807,
                      row(0.748, photo(.hero), col(0.62, text(verticalTitle()), text(englishCaption()))),
                      row(0.333, photo(), row(0.5, photo(), photo()))),
            style: CollageStyles.preset("editorial"),
            canvas: xhs,
            fitAspects: false, builtin: true, category: "日系杂志"),
        CollageTemplate(
            name: "日系 · 留白单图",
            root: col(0.87, photo(.hero), text(smallCaption())),
            style: {
                var s = CollageStyles.preset("airy")
                s.margin = 0.11
                return s
            }(), canvas: xhs,
            fitAspects: true, builtin: true, category: "日系杂志"),
        CollageTemplate(
            name: "日系 · 错落双图",
            root: col(0.6, row(0.68, photo(.hero), empty()), row(0.36, text(smallCaption()), photo())),
            style: {
                var s = CollageStyles.preset("airy")
                s.margin = 0.075
                s.gutter = 0.03
                return s
            }(), canvas: xhs,
            fitAspects: false, builtin: true, category: "日系杂志"),
        CollageTemplate(
            name: "日系 · 三图一文",
            root: row(0.52, col(0.64, photo(.hero), text(englishCaption(word: "Diary"))), col(0.5, photo(), photo())),
            style: CollageStyles.preset("airy"), canvas: xhs,
            fitAspects: false, builtin: true, category: "日系杂志"),
        CollageTemplate(
            name: "杂志 · 目录页",
            root: col(0.15, text(contentsHeader()),
                      col(0.5, row(0.5, photo(.hero, overlay: numberOverlay(1)), photo(overlay: numberOverlay(2))),
                          row(0.5, photo(overlay: numberOverlay(3)), photo(overlay: numberOverlay(4))))),
            style: CollageStyles.preset("editorial"), canvas: xhs,
            fitAspects: false, builtin: true, category: "日系杂志"),
        CollageTemplate(
            name: "杂志 · 大图引语",
            root: col(0.66, photo(.hero), row(0.52, text(quote()), photo())),
            style: CollageStyles.preset("editorial"), canvas: xhs,
            fitAspects: false, builtin: true, category: "日系杂志"),
        CollageTemplate(
            name: "标题 + 主图 + 双联",
            root: col(0.12, text(centeredTitle()), col(0.64, photo(.hero), row(0.5, photo(), photo()))),
            style: CollageStyles.preset("editorial"),
            canvas: CollageCanvas.social[3],
            fitAspects: true, builtin: true, category: "日系杂志"),
    ]

    // MARK: 中式

    private static let chinese: [CollageTemplate] = [
        CollageTemplate(
            name: "中式 · 月洞门",
            root: col(0.64,
                      row(0.72, photo(.hero, shape: .circle), text(verticalTitle(size: 0.075, seal: "拾光"))),
                      row(0.5, photo(shape: .arch), photo(shape: .arch))),
            style: CollageStyles.preset("chinese"),
            canvas: xhs,
            fitAspects: false, builtin: true, category: "中式"),
        CollageTemplate(
            name: "中式 · 拱窗三联",
            root: col(0.8,
                      row(0.333, photo(shape: .arch), row(0.5, photo(.hero, shape: .arch), photo(shape: .arch))),
                      text(centeredTitle())),
            style: CollageStyles.preset("chinese"),
            canvas: banner,
            fitAspects: false, builtin: true, category: "中式"),
        CollageTemplate(
            name: "中式 · 双月洞门",
            root: row(0.7, col(0.5, photo(.hero, shape: .circle), photo(shape: .circle)),
                      text(verticalTitle(size: 0.068, seal: "光"))),
            style: CollageStyles.preset("chinese"), canvas: xhs,
            fitAspects: false, builtin: true, category: "中式"),
        CollageTemplate(
            name: "中式 · 印章留白",
            root: row(0.72, photo(.hero), text(verticalPoem())),
            style: {
                var s = CollageStyles.preset("chinese")
                s.margin = 0.09
                s.gutter = 0.03
                return s
            }(), canvas: xhs,
            fitAspects: false, builtin: true, category: "中式"),
        CollageTemplate(
            name: "中式 · 竖幅长卷",
            root: col(0.62, row(0.68, photo(.hero, shape: .arch), text(verticalTitle(size: 0.058, seal: "拾光"))),
                      row(0.5, photo(), photo())),
            style: CollageStyles.preset("chinese"), canvas: CollageCanvas.social[4],
            fitAspects: false, builtin: true, category: "中式"),
        CollageTemplate(
            name: "中式 · 四拱窗",
            root: col(0.8, row(0.25, photo(shape: .arch), row(0.333, photo(.hero, shape: .arch),
                                                                row(0.5, photo(shape: .arch), photo(shape: .arch)))),
                      text(centeredTitle())),
            style: CollageStyles.preset("chinese"), canvas: banner,
            fitAspects: false, builtin: true, category: "中式"),
    ]

    // MARK: 九宫格（朋友圈：零边距零缝，切成 9 张后拼回去是一张图）

    private static let gridStyle: CollageStyle = {
        var s = CollageStyles.preset("white")
        s.margin = 0
        s.gutter = 0
        return s
    }()

    private static let grid9: [CollageTemplate] = [
        CollageTemplate(
            name: "九宫格 · 中心标题",
            root: col(0.3334, row(0.3334, photo(.hero), row(0.5, photo(), photo())),
                      col(0.5, row(0.3334, photo(), row(0.5, text(centeredTitle()), photo())),
                          row(0.3334, photo(), row(0.5, photo(), photo())))),
            style: gridStyle, canvas: square9,
            fitAspects: false, builtin: true, category: "九宫格"),
        CollageTemplate(
            name: "九宫格 · 大图四格",
            root: col(0.6667, row(0.6667, photo(.hero), col(0.5, photo(), photo())),
                      row(0.3334, photo(), row(0.5, photo(), photo()))),
            style: gridStyle, canvas: square9,
            fitAspects: false, builtin: true, category: "九宫格"),
        CollageTemplate(
            name: "九宫格 · 横贯中排",
            root: col(0.3334, row(0.3334, photo(), row(0.5, photo(), photo())),
                      col(0.5, photo(.hero), row(0.3334, photo(), row(0.5, photo(), photo())))),
            style: gridStyle, canvas: square9,
            fitAspects: false, builtin: true, category: "九宫格"),
        CollageTemplate(
            name: "九宫格 · 纯九宫",
            root: col(0.3334, row(0.3334, photo(.hero), row(0.5, photo(), photo())),
                      col(0.5, row(0.3334, photo(), row(0.5, photo(), photo())),
                          row(0.3334, photo(), row(0.5, photo(), photo())))),
            style: gridStyle, canvas: square9,
            fitAspects: false, builtin: true, category: "九宫格"),
    ]

    // MARK: 手账散落

    private static func scatterSpec(_ frame: CollageItemFrame, count: Int, tilt: Double, tape: Double,
                                    tapes: [CollageSticker], caption: String, spread: Double) -> CollageScatterSpec {
        var spec = CollageScatterSpec()
        spec.frame = frame
        spec.count = count
        spec.tilt = tilt
        spec.tape = tape
        spec.tapes = tapes
        spec.caption = caption
        spec.spread = spread
        return spec
    }

    private static func handTitle(color: CollageColor, cy: Double) -> CollageItem {
        var item = CollageItem(kind: .text)
        item.text = CollageText(lines: [
            CollageTextLine("{title}", font: .hanzipen, weight: .regular, size: 0.05, color: color),
            CollageTextLine("{date}", font: .hanzipen, weight: .regular, size: 0.02, color: color),
        ], vertical: false, alignH: .center, alignV: .center)
        item.cx = 0.5
        item.cy = cy
        item.width = 0.62
        item.height = 0.13
        item.rotation = -2
        return item
    }

    private static let journal: [CollageTemplate] = [
        CollageTemplate(
            name: "手账 · 拍立得",
            root: empty(), style: CollageStyles.preset("journal"), canvas: xhs,
            fitAspects: false, builtin: true, category: "手账散落",
            scatter: scatterSpec(.polaroid, count: 5, tilt: 6, tape: 0.6, tapes: [.washi, .stripe, .kraft],
                                 caption: "{date}", spread: 1.12)),
        CollageTemplate(
            name: "手账 · 白边照片墙",
            root: empty(), style: {
                var s = CollageStyles.preset("journal")
                s.background = CollageColor(hex: 0xDCD5C8)
                return s
            }(), canvas: xhs,
            fitAspects: false, builtin: true, category: "手账散落",
            scatter: scatterSpec(.white, count: 6, tilt: 4, tape: 0.85, tapes: [.kraft, .washi],
                                 caption: "", spread: 1.08)),
        CollageTemplate(
            name: "手账 · 黑卡相角",
            root: empty(), style: {
                var s = CollageStyles.preset("journal")
                s.background = CollageColor(hex: 0x2A2724)
                s.grain = 0.2
                return s
            }(), canvas: xhs,
            fitAspects: false, builtin: true, category: "手账散落",
            items: [handTitle(color: CollageColor(hex: 0xF1ECE2), cy: 0.915)],
            scatter: {
                var spec = scatterSpec(.mounts, count: 4, tilt: 2.5, tape: 0, tapes: [.washi], caption: "", spread: 1.0)
                spec.reserveBottom = 0.13
                return spec
            }()),
        CollageTemplate(
            name: "手账 · 胶片散落",
            root: empty(), style: {
                var s = CollageStyles.preset("journal")
                s.look = .film
                s.lookStrength = 0.65
                return s
            }(), canvas: xhs,
            fitAspects: false, builtin: true, category: "手账散落",
            scatter: scatterSpec(.film, count: 4, tilt: 5, tape: 0.5, tapes: [.kraft, .stripe],
                                 caption: "", spread: 1.1)),
    ]

    // MARK: 电影感

    private static let cinema: [CollageTemplate] = [
        CollageTemplate(
            name: "电影 · 双帧字幕",
            root: col(0.17, empty(), col(0.8, col(0.5, photo(.hero, overlay: subtitleOverlay("那天的风，吹得很温柔")),
                                                   photo(overlay: subtitleOverlay("我们都在慢慢长大"))), empty())),
            style: CollageStyles.preset("cinema"), canvas: xhs,
            fitAspects: false, builtin: true, category: "电影感"),
        CollageTemplate(
            name: "电影 · 宽银幕",
            root: col(0.1, empty(), col(0.89, photo(.hero, overlay: subtitleOverlay("{title}")), empty())),
            style: CollageStyles.preset("cinema"), canvas: banner,
            fitAspects: false, builtin: true, category: "电影感"),
    ]

    // MARK: 基础

    private static let basics: [CollageTemplate] = [
        CollageTemplate(
            name: "双联",
            root: row(0.5, photo(.hero), photo()),
            fitAspects: true, builtin: true, category: "基础"),
        CollageTemplate(
            name: "三联",
            root: row(0.333, photo(), row(0.5, photo(.hero), photo())),
            fitAspects: true, builtin: true, category: "基础"),
        CollageTemplate(
            name: "主图 + 四宫",
            root: row(0.6, photo(.hero), col(0.5, row(0.5, photo(), photo()), row(0.5, photo(), photo()))),
            fitAspects: true, builtin: true, category: "基础"),
        CollageTemplate(
            name: "主图 + 六宫",
            root: row(0.55, photo(.hero), col(0.333, row(0.5, photo(), photo()),
                                              col(0.5, row(0.5, photo(), photo()), row(0.5, photo(), photo())))),
            fitAspects: true, builtin: true, category: "基础"),
        CollageTemplate(
            name: "居中标题 + 三联",
            root: col(0.2, text(centeredTitle()), row(0.333, photo(), row(0.5, photo(.hero), photo()))),
            style: CollageStyles.preset("grid"),
            canvas: banner,
            fitAspects: true, builtin: true, category: "基础"),
        CollageTemplate(
            name: "画廊 · 四联",
            root: row(0.25, photo(), row(0.333, photo(.hero), row(0.5, photo(), photo()))),
            style: CollageStyles.preset("gallery"), canvas: banner,
            fitAspects: true, builtin: true, category: "基础"),
    ]

    // MARK: - 套用

    /// 名字精确匹配优先，再按包含（「三联」不能匹配到「拱窗三联」）。
    static func find(_ name: String, in list: [CollageTemplate] = builtin) -> CollageTemplate? {
        list.first { $0.name == name } ?? list.first { $0.name.contains(name) }
    }

    /// 套模板得到一整页：网格版 = 切分树（+ 模板带的贴纸）；散落版 = 按参数现撒；
    /// 自己存的散落版 = 原样摆放，照片按顺序换成这组。
    /// 主图角色的格子先拿分数最高的，其余按给定顺序填；照片不够的格子留空（占位）。
    static func apply(_ template: CollageTemplate, photos: [CollagePhotoRef],
                      context: CollageLayout.Context, seed: UInt64 = 7) -> CollagePage {
        if let spec = template.scatter {
            let use = Array(photos.prefix(max(1, spec.count)))
            let results = CollageScatter.generate(photos: use, spec: spec, context: context, seed: seed, keep: 4)
            let items = (results.first?.items ?? []) + template.items
            return CollagePage(root: .leaf(CollageCell()), items: items, freeform: true, scatter: spec)
        }
        var remaining = photos
        func takeBest() -> String? {
            guard let best = remaining.max(by: { $0.score < $1.score }) else { return nil }
            remaining.removeAll { $0.id == best.id }
            return best.id
        }
        func takeNext() -> String? {
            guard !remaining.isEmpty else { return nil }
            return remaining.removeFirst().id
        }
        var items = template.items
        if template.freeform {
            let photoIndices = items.indices.filter { items[$0].kind == .photo }
            // 主图 = 最大的那张相纸。
            let heroIndex = photoIndices.max { items[$0].width * items[$0].height < items[$1].width * items[$1].height }
            if let h = heroIndex { items[h].photoID = takeBest() }
            for i in photoIndices where i != heroIndex { items[i].photoID = takeNext() }
            return CollagePage(root: .leaf(CollageCell()), items: items, freeform: true, scatter: template.pageScatter)
        }
        var root = template.root
        let paths = root.leafPaths().filter { root.node(at: $0)?.cell?.kind == .photo }
        var assignment: [[Int]: String] = [:]
        for path in paths where root.node(at: path)?.cell?.role == .hero {
            if let id = takeBest() { assignment[path] = id }
        }
        for path in paths where assignment[path] == nil {
            if let id = takeNext() { assignment[path] = id }
        }
        for path in paths {
            root.update(at: path) { node in node.cell?.photoID = assignment[path] }
        }
        for i in items.indices where items[i].kind == .photo {
            items[i].photoID = takeNext()
        }
        if template.fitAspects {
            root = CollageLayout.refit(root, context: context)
        }
        return CollagePage(root: root, items: items, freeform: false)
    }

    /// 把当前页存成模板：去掉照片，只留结构、角色、文字、压字、贴纸（散落版连位置一起）。
    static func template(from page: CollagePage, name: String, style: CollageStyle?, canvas: CollageCanvas?,
                         fitAspects: Bool) -> CollageTemplate {
        var stripped = page.root
        for path in page.root.leafPaths() {
            stripped.update(at: path) { node in
                guard node.cell?.kind == .photo else { return }
                node.cell?.photoID = nil
                node.cell?.crop = nil
                node.cell?.locked = false
            }
        }
        let items = page.items.map { item -> CollageItem in
            var out = item
            out.id = UUID()
            out.photoID = nil
            return out
        }
        var t = CollageTemplate(name: name, root: stripped, style: style, canvas: canvas,
                                fitAspects: page.freeform ? false : fitAspects, category: "我的",
                                items: items, freeform: page.freeform)
        t.pageScatter = page.freeform ? page.scatter : nil
        return t
    }
}
