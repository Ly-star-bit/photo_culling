import Foundation
import CoreGraphics

/// 「婚礼相册」风格：fine-art 预设 + 跨页模板。规格见 reports/杂志风格调研_2026-10-23/DESIGN.md §3 K6。
///
/// 注册钩子：templates 按 CollageTemplates.builtin 里的位置进模板库（category 写「婚礼相册」）；presets 拼在
/// CollageStyles.all 末尾。模板名全库唯一，模板名、分类名都不能包含别的分类名（--template-sheet --only、
/// 门禁按「包含」匹配）。积木用 CollageTemplates.photo / row / col / text，样式用 CollageStyles.make { s in … } ——
/// 这里的 static let 里别读 CollageStyles.all / preset(…) 和 CollageTemplates.builtin / find(…)：它们正拼着这两个
/// 数组，回头读自己会在初始化时卡死。只改这个文件（和同前缀的新文件），地基要改的在交付报告里单独列出。
/// 不预置任何真实刊名、胶片 / 滤镜品牌名（DESIGN.md §0.4）。
///
/// 编排主题（整本自动排：章节开篇、疏密、呼吸页、竖图成对……）在 CollageStyleFineArtAlbum.swift；
/// 这里是纸、字、每一页怎么排（模板和编排共用同一套页面积木），以及一键成套「整本婚礼相册」。
enum CollageStyleFineArt {

    // MARK: - 纸、卡纸、边距

    /// 模板库里的分类名（也是模板名的前缀）。
    static let category = "婚礼相册"

    /// 象牙纸（R3 §1：预览纸色 #F6F1E7）。
    static let ivory = CollageColor(hex: 0xF6F1E7)

    /// 卡纸：自然白（R3 §1 的另一种预览纸色 #F8F6F0），比象牙纸浅一档、偏冷一点 —— 看得出是一块卡纸。
    /// 以前卡纸和页面同色（象牙卡纸窗口册摊开的样子），可预设拿到普通网格上，卡纸宽按每格短边算、大格小格不一样宽，
    /// 只看得见照片边就参差不齐；卡纸看得出来，对齐的就是格子边（完整显示的格子卡纸贴着照片裁，见 CollageRender.drawPhoto）。
    static let matWhite = CollageColor(hex: 0xF8F6F0)

    /// 模板自带的画布：30×30cm 方册跨页（相册里套模板不换画布、不换样式，见 CollageStore.applyTemplate）。
    static let albumCanvas = CollageCanvas.albums[0]

    /// 底边比另外三边多留多少（页高的比例）：装裱的 bottom weighting（底边宽 1/4"–1/2"，R3 §2），
    /// 30cm 页上 9mm、20cm 页上 6mm；照片的视觉中心因此比几何中心高一点（光学居中）。
    static let bottomWeight = 0.03

    /// fine-art 页边距：max(12% 页边, 25mm)（R3 §2，25mm 对齐 Red Tree 的 fine-art 下限）。
    static let marginShare = 0.12
    static let marginFloorMM = 25.0

    /// 同一页上两张照片之间的缝（页内）。两张照片之间实际看到的空白 = 这条缝 + 两边各自的卡纸（每边约格子短边的 7%）：
    /// 4mm 的缝在 30cm 页上配图之间约 16–20mm，两道细线之间约 7–11mm（Queensberry 窗口之间至少 10mm，R3 §2）。
    static let gutterMM = 4.0

    /// 婚礼 fine-art：象牙纸、自然白卡纸 + 细线、宽边距、雅致色调、统一色调 0.3、照片上压一层纸纹；
    /// 细衬线横排字，不加印章；照片完整显示、不出血、不跨中缝（fine-art 纸不建议满版跨页，R3 §0.1）。
    /// 边距按 30×30cm 方册算（12% = 36mm）；选预设、换册子尺寸、一键成套都按实际册子重算（adapted / style(for:)）。
    static let style: CollageStyle = CollageStyles.make { s in
        s.background = ivory
        s.grain = 0.16
        s.border = .mat
        s.borderColor = matWhite
        s.matWidth = 0.07
        s.margin = marginShare
        s.insets = CollageInsets(top: marginShare, bottom: marginShare + bottomWeight,
                                 inner: marginShare, outer: marginShare)
        s.gutter = gutterMM / 300   // 30cm 方册：短边 300mm
        s.shadow = 0
        s.sharpen = 0.3
        // 小格子不自动收成半身：fine-art 照片一律完整显示。
        s.tightSmallCells = false
        s.look = .fineArt
        s.lookStrength = 0.75
        s.harmonize = 0.3
        s.paperOverPhotos = 0.3
    }

    /// 古典版心（Van de Graaf，R3 §2）：方页上 内 = 上 = 1/9、外 = 下 = 2/9，版心 2/3 × 2/3。
    static let canonStyle: CollageStyle = CollageStyles.make { s in
        s = style
        s.insets = CollageInsets(top: 1.0 / 9, bottom: 2.0 / 9, inner: 1.0 / 9, outer: 2.0 / 9)
        s.margin = 1.0 / 9
    }

    static let presets: [CollageStyles.Preset] = [
        CollageStyles.Preset(key: "weddingFineArt", name: "婚礼 fine-art", style: style),
        CollageStyles.Preset(key: "weddingCanon", name: "婚礼 · 古典版心", style: canonStyle),
    ]

    /// 按这本册子的尺寸重算边距和缝（四边边距的单位是画布短边，册子的页宽、页高不一定等于短边）：
    /// - 上、内、外 = max(12% 页边, 25mm)，下再多 bottomWeight；
    /// - 古典版心按页宽页高的 1/9、2/9（30×20 横版：内 = 页宽 / 9 = 33mm，不是短边 / 9）；
    /// - 页内的缝 gutterMM。
    /// 不是相册跨页（单张画布）：fine-art 原样返回；古典版心换成左右对称的（flatCanon）。
    static func style(for canvas: CollageCanvas, canon: Bool = false) -> CollageStyle {
        guard canvas.seams == .fold else { return canon ? flatCanon(for: canvas) : style }
        var s = canon ? canonStyle : style
        let short = canvas.shortSide
        let pageW = Double(canvas.width) / 2
        let pageH = Double(canvas.height)
        let floor = canvas.pixels(mm: marginFloorMM)
        if canon {
            s.insets = CollageInsets(top: pageH / 9 / short, bottom: pageH * 2 / 9 / short,
                                     inner: pageW / 9 / short, outer: pageW * 2 / 9 / short)
        } else {
            let side: Double = max(marginShare * pageW, floor) / short
            let top: Double = max(marginShare * pageH, floor) / short
            let bottom: Double = top + bottomWeight * pageH / short
            s.insets = CollageInsets(top: top, bottom: bottom, inner: side, outer: side)
        }
        s.margin = s.insets?.top ?? s.margin
        s.gutter = canvas.pixels(mm: gutterMM) / short
        return s
    }

    /// 古典版心放到单张画布上：单页没有订口 / 翻口，左右对称各 1/6 页宽（1/9 和 2/9 的中间），上 1/9、下 2/9 页高 ——
    /// 版心还是 2/3 × 2/3。照搬右页的 内 1/9、外 2/9，一张 3:4 的图版心就偏到一边去了。
    static func flatCanon(for canvas: CollageCanvas) -> CollageStyle {
        var s = canonStyle
        let short = max(1, canvas.shortSide)
        let w = Double(canvas.width)
        let h = Double(canvas.height)
        s.insets = CollageInsets(top: h / 9 / short, bottom: h * 2 / 9 / short, inner: w / 6 / short, outer: w / 6 / short)
        s.margin = s.insets?.top ?? s.margin
        return s
    }

    /// 样式页选了 fine-art 预设、ops style:、换册子尺寸、切到相册模式（CollageStore.setStyle / setCanvas / setMode，
    /// 命令行 --album）：认得出是 fine-art 自己算的边距（卡纸边，四边边距和缝 = 预设的、或者 old / canvas 上
    /// style(for:) 给的），就按 canvas 重算边距和缝（古典版心还是古典版心），别的设置（纸色、色调、纸纹……）照留；
    /// 不是 fine-art 的样式、用户自己改过边距的 = nil（原样）。
    static func adapted(_ style: CollageStyle, from old: CollageCanvas? = nil,
                        to canvas: CollageCanvas) -> CollageStyle? {
        guard style.border == .mat, let insets = style.insets else { return nil }
        var sources = [albumCanvas, canvas]
        if let old { sources.append(old) }
        for source in sources {
            for canon in [false, true] {
                let auto = self.style(for: source, canon: canon)
                guard let a = auto.insets, same(insets, a), abs(style.gutter - auto.gutter) < 1e-4 else { continue }
                let target = self.style(for: canvas, canon: canon)
                var out = style
                out.insets = target.insets
                out.margin = target.margin
                out.gutter = target.gutter
                return out
            }
        }
        return nil
    }

    /// 两套四边边距一样（差不到万分之一短边：4mm 的缝换成像素再除回来有一点舍入）。
    private static func same(_ a: CollageInsets, _ b: CollageInsets) -> Bool {
        let d: Double = max(abs(a.top - b.top), abs(a.bottom - b.bottom), abs(a.inner - b.inner), abs(a.outer - b.outer))
        return d < 1e-4
    }

    /// 换了册子尺寸（fine-art 样式）：已经排好的页上比 2.8mm 还小的字放到 2.8mm（字号的单位是画布短边，
    /// 30×30 排的日期行换到 20×20 上只剩 2.3mm）。
    static func readable(_ pages: [CollagePage], on canvas: CollageCanvas) -> [CollagePage] {
        let floor = smallSize(for: canvas)
        return pages.map { page in
            var out = page
            for path in page.root.leafPaths() {
                guard let cell = page.root.node(at: path)?.cell, cell.kind == .text,
                      let text = cell.text, text.lines.contains(where: { $0.size < floor }) else { continue }
                out.root.update(at: path) { node in
                    node.cell?.text?.lines = text.lines.map { line in
                        var l = line
                        l.size = max(l.size, floor)
                        return l
                    }
                }
            }
            return out
        }
    }

    // MARK: - 文字（细衬线、横排、不加印章）

    /// 小字的下限：2.8mm（约 8pt，R3 §7：再小 20cm 的册子上就读不清了）。size 的单位是画布短边。
    static let minTextMM = 2.8

    /// 日期行：MARCH 5, 2026（美式日期日子不补零：{day} 是两位的 05，{day_num} 才是 5）。照片没有拍摄时间时
    /// 整行不印（[[…]]：扉页、单图右页不剩一个孤零零的「,」）。
    static let dateLine = "[[{month_en} {day_num}, {year}]]"

    /// 扉页：标题（宋体细：中文是衬线，里面的西文字形也是衬线）+ 日期行（全大写小字，字距 0.12em，R3 §7 取
    /// 0.10–0.15 的中间）。字号 0.04（R3 §7：名字 0.035–0.045）。标题是西文（没有汉字）时不加字距：大小写混排的
    /// 名字加字距是排版忌讳（R3：名字行 0），中文标题字距 0.12 才舒展。
    static func titleText(latin: Bool = false, small: Double = 0.0115) -> CollageText {
        var t = CollageText(lines: [
            CollageTextLine("{title}", font: .songti, weight: .light, size: 0.04, tracking: latin ? 0.02 : 0.12,
                            color: .ink),
            CollageTextLine(dateLine, font: .baskerville, weight: .regular, size: small,
                            tracking: 0.12, color: .warmGrey),
        ], vertical: false, alignH: .center, alignV: .center)
        t.lineSpacing = 1.0
        return t
    }

    /// 扉页左页：标题、日期行分成上下两个文字格。字块放不下时 drawShort 是按格子整块缩的 —— 一个字块的话长标题会把
    /// 日期行一起缩到 2.8mm 以下；分开之后只缩标题自己（之后改了标题也一样）。位置和一个字块时一样：整块（标题 + 1em +
    /// 日期行）在版心里竖直居中；两格都底对齐，标题格的底 = 标题的底，日期格的高 = 1em − 缝 + 日期行高（日期格的顶在标题底
    /// 下面一道缝）。缝比 1em 还宽、或者某一刀太窄（< minBand）就退回一个字块。short = 画布短边（像素）。
    static func titlePage(latin: Bool, small: Double, box: PageBox, short: Double) -> CollageNode {
        let whole = titleText(latin: latin, small: small)
        guard whole.lines.count == 2, short > 0 else { return CollageTemplates.text(whole) }
        let title = CollageText(lines: [whole.lines[0]], vertical: false, alignH: .center, alignV: .trailing)
        let date = CollageText(lines: [whole.lines[1]], vertical: false, alignH: .center, alignV: .trailing)
        // 量高度用的字（行高只看字体，和是哪几个字关系不大）：最长的英文月份。
        let vars = ["title": "拾光", "month_en": "SEPTEMBER", "day_num": "30", "year": "2026"]
        let titleH = Double(CollageTypeset.measure(title, short: short, vars: vars).height)
        let dateH = Double(CollageTypeset.measure(date, short: short, vars: vars).height)
        let spacing: Double = whole.lineSpacing * whole.lines[0].size * short
        let g = box.g
        let blockH: Double = titleH + spacing + dateH
        let titleBottom: Double = (box.h - blockH) / 2 + titleH
        let dateCellH: Double = spacing - g + dateH
        let rest: Double = box.h - g - titleBottom
        let r1: Double = titleBottom / max(1, box.h - g)
        let r2: Double = dateCellH / max(1, rest - g)
        let ok = dateCellH > dateH && rest - g > dateCellH && min(r1, r2) >= minBand && max(r1, r2) <= 1 - minBand
        guard ok else { return CollageTemplates.text(whole) }
        let lower: CollageNode = .split(.column, r2, CollageTemplates.text(date), CollageTemplates.empty())
        return .split(.column, r1, CollageTemplates.text(title), lower)
    }

    /// 标题里有没有汉字（没有 = 西文标题，扉页标题不加字距）。空标题 = 「拾光」，算中文。
    static func isLatinTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return !t.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    /// 一行小字（单图右页的左页、章节开篇的「II · 16:24」）：全大写、字距 0.12em、暖灰。
    static func captionText(_ text: String, size: Double = 0.0115) -> CollageText {
        var line = CollageTextLine(text, font: .baskerville, weight: .regular, size: size, tracking: 0.12,
                                   color: .warmGrey)
        line.textCase = .upper
        return CollageText(lines: [line], vertical: false, alignH: .center, alignV: .center)
    }

    /// 这本册子上小字至少多大（size 单位）：0.0115 × 短边，再不小于 2.8mm。
    static func smallSize(for canvas: CollageCanvas) -> Double {
        let floor: Double = canvas.pixels(mm: minTextMM) / max(1, canvas.shortSide)
        return max(0.0115, floor)
    }

    // MARK: - 一页的版心（模板和编排共用）

    /// 一页版心的大小（成品像素）和页内的缝宽：跨页的两页之一（中缝两侧的内边距已经扣掉）。
    struct PageBox: Hashable {
        var w: Double
        var h: Double
        var g: Double
    }

    static func pageBox(canvas: CollageCanvas, style: CollageStyle) -> PageBox {
        let content = CollageLayout.contentRect(canvas: canvas, style: style)
        let g = Double(CollageLayout.gutterPixels(canvas: canvas, style: style))
        let fold = CollageLayout.foldGap(canvas: canvas, style: style).map(Double.init) ?? g
        let w = (Double(content.width) - fold) / 2
        return PageBox(w: max(1, w), h: max(1, Double(content.height)), g: g)
    }

    /// 模板里的比例按 30×30cm 方册 + 本预设的版心算（套用时按实际册子和照片重排，见 fitTemplate）。
    static let templateBox: PageBox = pageBox(canvas: albumCanvas, style: style)

    /// 垫留白的那一条至少占这一刀的多少（CollageLayout.minRatio 是 0.04：再窄比例会被收住，算出来的位置就不准了）。
    static let minBand = 0.045

    /// 一格照片：哪张、什么角色、照片的比例（没有照片 = 竖图 2:3）。
    struct Slot {
        var id: String?
        var role: CollageRole = .support
        var aspect: Double = 2.0 / 3.0
    }

    /// 照片格：完整显示（fine-art 不裁，照片四周是卡纸）。
    static func plate(_ role: CollageRole = .support, id: String? = nil) -> CollageNode {
        var cell = CollageCell.photo(id, role: role)
        cell.contain = true
        return .leaf(cell)
    }

    /// 小图的窗口：crop = 裁切格（照片按人脸裁成窗口的比例）；不然完整显示。
    static func window(_ slot: Slot, crop: Bool) -> CollageNode {
        var cell = CollageCell.photo(slot.id, role: slot.role)
        cell.contain = !crop
        return .leaf(cell)
    }

    /// 横图单页的模板格：固定 3:2 的横框（不完整显示：竖图套进来按人脸裁成横的，缩略图上也是一张横图）。
    static func landscapeFrame(_ role: CollageRole = .hero, id: String? = nil) -> CollageNode {
        .leaf(CollageCell.photo(id, role: role))
    }

    private static func clampRatio(_ r: Double) -> Double { min(1 - minBand, max(minBand, r)) }

    /// 卡纸里的窗口是 window 这个比例时，整格（窗口 + 卡纸）是什么比例。卡纸宽 = 格子短边 × mat，底边再多
    /// matBottomWeight 倍（CollageCrop.borderInner）。格子按这个比例分，照片正好填满窗口：同一排的窗口一样大 →
    /// 卡纸一样宽 → 照片的上下边（一摞：左右边）对得齐。
    static func cellAspect(window a: Double, mat: Double) -> Double {
        guard mat > 0 else { return a }
        let vertical: Double = 1 + CollageCrop.matBottomWeight
        // 竖格（宽 ≤ 高）：卡纸 = mat × 宽。
        let tallDenominator: Double = (1 - 2 * mat) / max(0.05, a) + mat * vertical
        let tall: Double = 1 / tallDenominator
        if tall <= 1 { return tall }
        // 横格（宽 ≥ 高）：卡纸 = mat × 高。
        let wide: Double = a * (1 - mat * vertical) + 2 * mat
        return wide
    }

    /// 一组小图（配图、三联）用什么比例的窗口：比例都差不多（3% 以内）= 照片自己的比例（照片正好填满窗口、不裁）；
    /// 横竖混排 = 1:1 方窗（窗口一样大才对得齐，按人脸裁）。squareLandscapes：三联里的横图也用方窗
    /// （一排三张横图又扁又小）。uniform = 照片自己的比例。
    static func windowAspect(_ aspects: [Double], squareLandscapes: Bool) -> (aspect: Double, uniform: Bool) {
        guard let lo = aspects.min(), let hi = aspects.max(), lo > 0 else { return (1, false) }
        let mean: Double = aspects.reduce(0, +) / Double(aspects.count)
        let uniform = hi / lo <= 1.03
        if uniform, !(squareLandscapes && mean > 1) { return (mean, true) }
        return (1, false)
    }

    /// 把 node 放进版心里 w × h 那么大的一块：水平居中，竖直居中再往上提 lift（版心高的比例）。四周用留白格垫；
    /// 哪一边垫的那条太窄（< minBand）就不垫那一边 —— 照片格是完整显示，格子大一点也不会裁。
    static func pad(_ node: CollageNode, w: Double, h: Double, in box: PageBox, lift: Double = 0) -> CollageNode {
        let g = box.g
        var out = node
        let rowAvail: Double = box.w - g
        let side: Double = (box.w - w) / 2 - g
        if rowAvail > 1, side / rowAvail >= minBand {
            let rest: Double = box.w - g - side
            let rL = clampRatio(side / rowAvail)
            let rI = clampRatio(w / max(1, rest - g))
            out = .split(.row, rL, .leaf(CollageCell()), .split(.row, rI, out, .leaf(CollageCell())))
        }
        let colAvail: Double = box.h - g
        let free: Double = (box.h - h) / 2 - g
        let liftPx: Double = lift * box.h
        let top: Double = free - liftPx
        let bottom: Double = free + liftPx
        guard colAvail > 1 else { return out }
        let topOK = top / colAvail >= minBand
        let bottomOK = bottom / colAvail >= minBand
        switch (topOK, bottomOK) {
        case (true, true):
            let rest: Double = box.h - g - top
            let rT = clampRatio(top / colAvail)
            let rI = clampRatio(h / max(1, rest - g))
            return .split(.column, rT, .leaf(CollageCell()), .split(.column, rI, out, .leaf(CollageCell())))
        case (false, true):
            let first: Double = box.h - g - bottom
            return .split(.column, clampRatio(first / colAvail), out, .leaf(CollageCell()))
        case (true, false):
            return .split(.column, clampRatio(top / colAvail), .leaf(CollageCell()), out)
        case (false, false):
            return out
        }
    }

    /// pad 能不能把 w × h 原样放进版心：每一边垫的那条要么够宽（≥ minBand），要么正好铺满（不用垫）。
    /// 不然垫的那条会被省掉、格子被拉大，窗口就不是算好的比例了（三联的方窗会变成 1.08:1）。
    static func padsExactly(w: Double, h: Double, in box: PageBox) -> Bool {
        func fits(_ inner: Double, _ outer: Double) -> Bool {
            if abs(outer - inner) < 2 { return true }
            let band: Double = (outer - inner) / 2 - box.g
            return band / max(1, outer - box.g) >= minBand
        }
        return fits(w, box.w) && fits(h, box.h)
    }

    /// 一排（axis = .row，同高 size）或一摞（.column，同宽 size）照片格：每格按 aspects（整格的比例）分，格与格之间一条缝。
    static func group(_ cells: [CollageNode], aspects: [Double], axis: CollageAxis, size: Double, g: Double) -> CollageNode {
        guard let first = cells.first else { return .leaf(CollageCell()) }
        guard cells.count > 1 else { return first }
        let lengths = aspects.map { a -> Double in axis == .row ? a * size : size / max(0.05, a) }
        let restLength: Double = lengths.dropFirst().reduce(0, +) + Double(cells.count - 2) * g
        let r = clampRatio(lengths[0] / max(1, lengths[0] + restLength))
        let rest = group(Array(cells.dropFirst()), aspects: Array(aspects.dropFirst()), axis: axis, size: size, g: g)
        return .split(axis, r, first, rest)
    }

    /// 一排 / 一摞的外框（宽, 高）。
    static func groupSize(aspects: [Double], axis: CollageAxis, size: Double, g: Double) -> (w: Double, h: Double) {
        let gaps = Double(max(0, aspects.count - 1)) * g
        if axis == .row {
            let w: Double = aspects.reduce(0) { $0 + $1 * size } + gaps
            return (w, size)
        }
        let h: Double = aspects.reduce(0) { $0 + size / max(0.05, $1) } + gaps
        return (size, h)
    }

    /// 一张照片完整显示在 w × h 的格子里、扣掉卡纸之后实际画多大（面积，像素²）：和渲染同一个算法
    /// （CollageCrop.borderInner 的卡纸 + aspectFit），主图 ≥ 2 倍配图（R6）按它量。
    static func shownArea(aspect: Double, w: Double, h: Double, mat: Double) -> Double {
        let fit = shownRect(aspect: aspect, in: CGRect(x: 0, y: 0, width: w, height: h), mat: mat)
        return Double(fit.width * fit.height)
    }

    /// 裁切格（窗口）里照片画多大：照片填满卡纸里面那一块。
    static func windowArea(w: Double, h: Double, mat: Double) -> Double {
        let inner = CollageCrop.borderInner(CGRect(x: 0, y: 0, width: w, height: h), .mat, mat: mat)
        return Double(inner.width * inner.height)
    }

    /// 完整显示的照片在格子 outer 里画在哪（扣掉卡纸、居中）。
    static func shownRect(aspect: Double, in outer: CGRect, mat: Double) -> CGRect {
        let inner = mat > 0 ? CollageCrop.borderInner(outer, .mat, mat: mat) : outer
        return CollageCrop.aspectFit(aspect, in: inner)
    }

    /// 单张：整个版心（完整显示）。
    static func platePage(_ node: CollageNode) -> CollageNode { node }

    /// 呼吸页：小一号（版心的 72%），四周大留白。
    static let breathShare = 0.72

    static func breathPage(_ node: CollageNode, aspect: Double, in box: PageBox) -> CollageNode {
        let fit = CollageCrop.aspectFit(aspect, in: CGRect(x: 0, y: 0, width: box.w * breathShare,
                                                           height: box.h * breathShare))
        return pad(node, w: Double(fit.width), h: Double(fit.height), in: box)
    }

    /// 对页双图：左右各一张，同高（R3「同高、镜像」）。比例一样 = 两页都是整个版心（完整显示）；比例不一样（模板里
    /// 横竖混排、3:2 配 16:9）= 两张都按矮的那张的高：高的那张垫成正好那么高的格子（格子 = 照片 + 卡纸），按卡纸上下的差
    /// 往上提一点，两张照片的上下边对齐；垫的那条太窄就两张一起缩一点。对不齐（量出来差 > 2 像素）就退回两页整版。
    static func pairPages(_ slots: [Slot], in box: PageBox, mat: Double) -> (left: CollageNode, right: CollageNode) {
        let plates = slots.map { plate($0.role, id: $0.id) }
        guard slots.count == 2 else {
            return (plates.first ?? CollageTemplates.empty(), plates.count > 1 ? plates[1] : CollageTemplates.empty())
        }
        let full = CGRect(x: 0, y: 0, width: box.w, height: box.h)
        let shown = slots.map { shownRect(aspect: $0.aspect, in: full, mat: mat) }
        let tallest = Double(max(shown[0].height, shown[1].height))
        let shortest = Double(min(shown[0].height, shown[1].height))
        guard tallest - shortest > max(2, tallest * 0.005) else { return (plates[0], plates[1]) }
        let low = shown[0].height <= shown[1].height ? 0 : 1
        let centre = Double(shown[low].midY)
        for step in 0..<12 {
            let k: Double = pow(0.97, Double(step))
            let ph: Double = shortest * k
            var nodes: [CollageNode] = []
            for i in 0..<2 {
                if step == 0, i == low {
                    nodes.append(plates[i])
                    continue
                }
                guard let cell = exactCell(aspect: slots[i].aspect, photoHeight: ph, mat: mat), cell.w <= box.w else { break }
                // 照片的上边 = centre - ph / 2；格子比照片高出上面一道卡纸，pad 是让格子居中再往上提 lift。
                let cellTop: Double = centre - ph / 2 - cell.top
                let liftPx: Double = (box.h - cell.h) / 2 - cellTop
                nodes.append(pad(plates[i], w: cell.w, h: cell.h, in: box, lift: liftPx / box.h))
            }
            guard nodes.count == 2 else { continue }
            if aligned(nodes, aspects: slots.map(\.aspect), box: box, mat: mat) { return (nodes[0], nodes[1]) }
        }
        return (plates[0], plates[1])
    }

    /// 照片高 photoHeight、正好填满卡纸窗口的格子：宽、高、上面那道卡纸多宽。
    private static func exactCell(aspect a: Double, photoHeight ph: Double,
                                  mat: Double) -> (w: Double, h: Double, top: Double)? {
        let c = cellAspect(window: a, mat: mat)
        let vertical: Double = 1 + CollageCrop.matBottomWeight
        if c <= 1 {
            // 竖格：卡纸 = mat × 宽。
            let denominator: Double = 1 - mat * c * vertical
            guard denominator > 0.1 else { return nil }
            let h: Double = ph / denominator
            let w: Double = c * h
            return (w, h, mat * w)
        }
        let denominator: Double = 1 - mat * vertical
        guard denominator > 0.1 else { return nil }
        let h: Double = ph / denominator
        return (c * h, h, mat * h)
    }

    /// 两页上的照片（完整显示）上下边差不到 2 像素：按真排出来的格子量（垫的那条可能被省掉）。
    private static func aligned(_ pages: [CollageNode], aspects: [Double], box: PageBox, mat: Double) -> Bool {
        let bounds = CollageLayout.IntRect(x0: 0, y0: 0, x1: Int(box.w.rounded()), y1: Int(box.h.rounded()))
        var rects: [CGRect] = []
        for (node, aspect) in zip(pages, aspects) {
            let geo = CollageLayout.geometry(node, in: bounds, gutter: Int(box.g.rounded()))
            guard let f = geo.frames.first(where: { $0.cell.kind == .photo }) else { return false }
            let outer = CGRect(x: f.rect.x0, y: f.rect.y0, width: f.rect.width, height: f.rect.height)
            rects.append(shownRect(aspect: aspect, in: outer, mat: mat))
        }
        guard rects.count == 2 else { return false }
        let dTop = abs(Double(rects[0].minY - rects[1].minY))
        let dBottom = abs(Double(rects[0].maxY - rects[1].maxY))
        return max(dTop, dBottom) <= 2
    }

    /// 配图那一页（一主两辅、R6）：两张排成一排或一摞（挑每张都更大的那种），每张最多主图面积的 share 倍，
    /// 整组在版心里居中。mainArea = 对页主图实际画出来的面积。两张是一样大的窗口（windowAspect）：
    /// fixed（模板）= 裁切格，之后拖进来横的竖的都还对得齐；编排（不 fixed）同方向就完整显示，横竖混排才是方窗。
    static func supportsPage(_ slots: [Slot], mainArea: Double, in box: PageBox, mat: Double, fixed: Bool,
                             share: Double = 0.49) -> CollageNode {
        guard slots.count >= 2 else {
            return slots.first.map { plate($0.role, id: $0.id) } ?? .leaf(CollageCell())
        }
        let g = box.g
        let win = windowAspect(slots.map(\.aspect), squareLandscapes: false)
        let crop = fixed || !win.uniform
        let cells = slots.map { window($0, crop: crop) }
        let cellA = cellAspect(window: win.aspect, mat: mat)
        let aspects = Array(repeating: cellA, count: slots.count)
        // 量的是垫好留白之后真排出来的格子（垫的那条太窄会被省掉、格子变大，照片可能换一个方向顶到边）。
        let bounds = CollageLayout.IntRect(x0: 0, y0: 0, x1: Int(box.w.rounded()), y1: Int(box.h.rounded()))
        func page(_ axis: CollageAxis, _ size: Double) -> CollageNode {
            let node = group(cells, aspects: aspects, axis: axis, size: size, g: g)
            let outer = groupSize(aspects: aspects, axis: axis, size: size, g: g)
            return pad(node, w: outer.w, h: outer.h, in: box)
        }
        func exact(_ axis: CollageAxis, _ size: Double) -> Bool {
            let outer = groupSize(aspects: aspects, axis: axis, size: size, g: g)
            return padsExactly(w: outer.w, h: outer.h, in: box)
        }
        func areas(_ node: CollageNode) -> [Double] {
            let geo = CollageLayout.geometry(node, in: bounds, gutter: Int(g.rounded()))
            let frames = geo.frames.filter { $0.cell.kind == .photo }
            return frames.map { f in
                let w = Double(f.rect.width)
                let h = Double(f.rect.height)
                return crop ? windowArea(w: w, h: h, mat: mat) : shownArea(aspect: win.aspect, w: w, h: h, mat: mat)
            }
        }
        func fitted(_ axis: CollageAxis) -> (node: CollageNode, minArea: Double) {
            // 先放到版心能放下的最大，再按 2% 一档往小收，直到每张都不超过主图的 share 倍、垫的留白放得下。
            let sumA: Double = aspects.reduce(0, +)
            let sumInv: Double = aspects.reduce(0) { $0 + 1 / max(0.05, $1) }
            let gaps = Double(aspects.count - 1) * g
            var size: Double = axis == .row ? min(box.h, (box.w - gaps) / sumA) : min(box.w, (box.h - gaps) / sumInv)
            var node = page(axis, size)
            var tries = 0
            while (areas(node).max() ?? 0) > share * mainArea || !exact(axis, size), tries < 80 {
                size *= 0.98
                node = page(axis, size)
                tries += 1
            }
            return (node, areas(node).min() ?? 0)
        }
        let row = fitted(.row)
        let column = fitted(.column)
        return column.minArea > row.minArea * 1.02 ? column.node : row.node
    }

    /// 细节三联：一排三张小图（同高、一样大的窗口），占版心宽的 tripletShare，竖直居中。三张竖图 = 竖窗（照片自己的
    /// 比例）；有横图 = 1:1 方窗（细节图裁方是三联最常见的做法，一排三张横图太扁）。fixed（模板）一律裁切格。
    static let tripletShare = 0.94

    static func tripletPage(_ slots: [Slot], in box: PageBox, mat: Double, fixed: Bool) -> CollageNode {
        let g = box.g
        let win = windowAspect(slots.map(\.aspect), squareLandscapes: true)
        let crop = fixed || !win.uniform
        let cells = slots.map { window($0, crop: crop) }
        let cellA = cellAspect(window: win.aspect, mat: mat)
        let aspects = Array(repeating: cellA, count: slots.count)
        let sumA: Double = max(0.1, aspects.reduce(0, +))
        let gaps = Double(max(0, cells.count - 1)) * g
        func fits(_ size: Double) -> Bool { padsExactly(w: size * sumA + gaps, h: size, in: box) }
        var size: Double = min(box.h * 0.5, (box.w * tripletShare - gaps) / sumA)
        if !fits(size) {
            // 两边留的那条比 minBand 窄（pad 会省掉、格子被拉宽）：铺满版心宽；还不行就往小收到垫得下。
            let full: Double = min(box.h * 0.5, (box.w - gaps) / sumA)
            if fits(full) {
                size = full
            } else {
                var tries = 0
                while !fits(size), tries < 40 {
                    size *= 0.98
                    tries += 1
                }
            }
        }
        let node = group(cells, aspects: aspects, axis: .row, size: size, g: g)
        let outer = groupSize(aspects: aspects, axis: .row, size: size, g: g)
        return pad(node, w: outer.w, h: outer.h, in: box)
    }

    /// 横图单页的模板版：版心宽、卡纸里的窗口是 3:2 的横框，竖直居中。格子按 cellAspect 分（同配图、三联）：
    /// 整格 3:2 的话卡纸占掉上下，窗口成了 1.6:1，3:2 的横图上下各被裁掉 3%（fine-art 不裁）。
    static func landscapePage(_ node: CollageNode, aspect: Double = 1.5, mat: Double, in box: PageBox) -> CollageNode {
        let cellA: Double = cellAspect(window: max(0.2, aspect), mat: mat)
        let h: Double = min(box.h, box.w / max(0.2, cellA))
        return pad(node, w: box.w, h: h, in: box)
    }

    /// 主图那一页实际画多大（单张占满版心、完整显示）。
    static func plateArea(aspect: Double, in box: PageBox, mat: Double) -> Double {
        shownArea(aspect: aspect, w: box.w, h: box.h, mat: mat)
    }

    // MARK: - 跨页模板（根节点都是 row(0.5, 左页, 右页)：中缝那一刀，照片不跨缝）

    enum TemplateKind {
        /// 左页一行小字（日期），右页一张
        case single
        /// 左右各一张，同高
        case pair
        /// 左页主图，右页两张配图
        case mainPlusTwo
        /// 右页一排三张小图，左页留白
        case triptych
        /// 右页一张横图（3:2 横框），左页留白
        case landscape
    }

    static let templateKinds: [String: TemplateKind] = [
        "婚礼相册 · 单图右页": .single,
        "婚礼相册 · 对页双图": .pair,
        "婚礼相册 · 一主两辅": .mainPlusTwo,
        "婚礼相册 · 细节三联": .triptych,
        "婚礼相册 · 横图单页": .landscape,
    ]

    /// 一个跨页模板的切分树：照片格的先后（leaves 里照片的顺序）每种固定 ——
    /// 单图 / 横图 [主图]，对页 [左(主图), 右]，一主两辅 [主图, 配图, 配图]，三联 [左, 中(主图), 右]。
    static func templateRoot(_ kind: TemplateKind, slots given: [Slot], box: PageBox, mat: Double,
                             small: Double) -> CollageNode {
        func slot(_ i: Int, _ role: CollageRole) -> Slot {
            var s = i < given.count ? given[i] : Slot()
            s.role = role
            return s
        }
        func row(_ left: CollageNode, _ right: CollageNode) -> CollageNode { CollageTemplates.row(0.5, left, right) }
        switch kind {
        case .single:
            let hero = slot(0, .hero)
            return row(CollageTemplates.text(captionText(dateLine, size: small)), plate(.hero, id: hero.id))
        case .pair:
            let pages = pairPages([slot(0, .hero), slot(1, .support)], in: box, mat: mat)
            return row(pages.left, pages.right)
        case .mainPlusTwo:
            let main = slot(0, .hero)
            let mainArea = plateArea(aspect: main.aspect, in: box, mat: mat)
            let supports = supportsPage([slot(1, .support), slot(2, .support)], mainArea: mainArea, in: box,
                                        mat: mat, fixed: true)
            return row(plate(.hero, id: main.id), supports)
        case .triptych:
            let cells = [slot(0, .support), slot(1, .hero), slot(2, .support)]
            return row(CollageTemplates.empty(), tripletPage(cells, in: box, mat: mat, fixed: true))
        case .landscape:
            let hero = slot(0, .hero)
            return row(CollageTemplates.empty(), landscapePage(landscapeFrame(id: hero.id), mat: mat, in: box))
        }
    }

    /// CollageTemplates.apply 套这五个模板时走这里（照片已经按角色分好）：按这本册子的版心、这几张照片的横竖重排一遍，
    /// 小字按册子尺寸放大（≥ 2.8mm）。配图、三联是一样大的裁切窗口：之后拖进别的横竖的照片也还是对齐的。
    /// 不是这几个模板 = nil（照旧）。
    static func fitTemplate(_ template: CollageTemplate, root: CollageNode, photos: [CollagePhotoRef],
                            context: CollageLayout.Context) -> CollageNode? {
        guard template.builtin, template.category == category, let kind = templateKinds[template.name] else { return nil }
        var map = context.photos
        for p in photos { map[p.id] = p }
        let slots = root.leaves.filter { $0.kind == .photo }.map { cell -> Slot in
            Slot(id: cell.photoID, role: cell.role, aspect: cell.photoID.flatMap { map[$0]?.aspect } ?? 2.0 / 3.0)
        }
        let box = pageBox(canvas: context.canvas, style: context.style)
        let mat = context.style.border == .mat ? context.style.matWidth : 0
        return templateRoot(kind, slots: slots, box: box, mat: mat, small: smallSize(for: context.canvas))
    }

    private static func authored(_ kind: TemplateKind) -> CollageNode {
        templateRoot(kind, slots: [], box: templateBox, mat: style.matWidth, small: 0.0115)
    }

    static let templates: [CollageTemplate] = [
        // 左页一行小字（日期），右页一张：扉页、章节开头、整本里最常见的一种。
        CollageTemplate(
            name: "婚礼相册 · 单图右页", root: authored(.single),
            style: style, canvas: albumCanvas, fitAspects: false, builtin: true, category: category),
        // 左右各一张，同高、镜像（竖图配竖图；横竖混着套也按矮的那张对齐上下边）。
        CollageTemplate(
            name: "婚礼相册 · 对页双图", root: authored(.pair),
            style: style, canvas: albumCanvas, fitAspects: false, builtin: true, category: category),
        // 左页主图，右页两张配图（每张不到主图一半大，R6；两张同方向用照片的比例，横竖混排用方窗）。
        CollageTemplate(
            name: "婚礼相册 · 一主两辅", root: authored(.mainPlusTwo),
            style: style, canvas: albumCanvas, fitAspects: false, builtin: true, category: category),
        // 右页一排三张小图（细节，三张竖图用竖窗、有横图用方窗），左页留白：每跨页最多 3 张（DESIGN）。
        CollageTemplate(
            name: "婚礼相册 · 细节三联", root: authored(.triptych),
            style: style, canvas: albumCanvas, fitAspects: false, builtin: true, category: category),
        // 一张横图放在右页的版心里，不跨中缝（fine-art 纸上的「整版大图」）。
        CollageTemplate(
            name: "婚礼相册 · 横图单页", root: authored(.landscape),
            style: style, canvas: albumCanvas, fitAspects: false, builtin: true, category: category),
    ]

    // MARK: - 一键成套：整本婚礼相册

    /// 一键成套 kit：整本婚礼相册（CollageKitID.weddingAlbum）：切到相册模式（已经是相册就沿用它的册子尺寸、装订），
    /// fine-art 样式按册子尺寸重算边距，托盘照片（废片不要）按 fine-art 主题编排（CollageStyleFineArtAlbum.swift）。
    /// 托盘、标题、副标题、刊头、水印跟着工程走。照片不够（托盘空）= nil。
    static func weddingAlbum(_ context: CollageKits.Context) -> CollageProject? {
        var project = context.project
        var photos = context.tray.filter { $0.verdict != .reject }
        if photos.isEmpty { photos = context.tray }
        guard !photos.isEmpty else { return nil }
        // 亮度、黑白从路人信息补（托盘里的 ref 一般已经抄过；刚带进来、还没算到的从 hints 拿）。
        for i in photos.indices {
            guard let h = context.hints[photos[i].id] else { continue }
            if photos[i].meanLuma == nil { photos[i].meanLuma = h.meanLuma }
            if photos[i].isMonochrome == nil { photos[i].isMonochrome = h.isMonochrome }
        }
        project.mode = .album
        if project.canvas.seams != .fold { project.canvas = albumCanvas }
        project.style = style(for: project.canvas)
        project.albumTheme = .fineArt
        // 整章黑白照工程原来的（新工程默认开；之前关掉了就还是关着）。
        var map: [String: CollagePhotoRef] = [:]
        for p in project.photos { map[p.id] = p }
        for p in photos { map[p.id] = p }
        let layout = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map,
                                           hints: context.hints, heroID: nil)
        let plan = CollageAlbum.plan(photos, dedupe: true, theme: .fineArt, chapterMono: project.albumChapterMono,
                                     title: project.title)
        let pages = CollageAlbum.build(plan, context: layout, seed: context.seed)
        guard !pages.isEmpty else { return nil }
        project.pages = pages
        return project
    }
}
