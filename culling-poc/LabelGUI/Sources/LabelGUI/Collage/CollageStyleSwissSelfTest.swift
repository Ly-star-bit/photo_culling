import Foundation
import CoreGraphics
import CoreText

/// LabelGUI --swiss-selftest（不读照片、不写任何文件、不用数据目录）
///
/// 1. 栅格公式（R4 §B3）：几种画布上按公式从头再算一遍，和 CollageStyleSwiss.Grid 逐项比（m = 5%W、b = 1.1s、
///    g = b、cw、r = round、mh 吸附到整数行、剩下的不到一行、s 在 0.026–0.047 S 里）。
/// 2. 每个「瑞士网格」模板按成品尺寸排一遍：边距 5%W、缝 = b、每个格子的左右沿落在栏线上、上下沿落在基线格上
///    （出血到成品边的除外）、格高是整数行；小字的基线（按 CollageTypeset 真排出来的字形）一行隔 b（每行下面
///    有细线的隔 2b），所有小字块的基线落在同一套基线格上；默认字不缩（放得下）；字号 ≤ 3 种、大字是小字的 7–18 倍；
///    默认小写、左齐；一页只有一种强调色、红字面积 ≤ 20%（按成品渲染数红像素）；巨型数字的字顶落在基线格上、
///    在人后、只限总量、封面取景 + 抠图。
/// 3. 名字：前缀「瑞士网格 · 」、全库唯一、不含别的分类名（--template-sheet --only 按包含匹配）；默认字里没有真实
///    刊名 / 胶片牌子、不用 {make} / {brand}；预设「瑞士」在 CollageStyles.all 里。
/// 4. 第 1 轮核对修的（合成数据，不读照片）：没有 EXIF / 拍摄时间时不留标点残渣、巨型日期换成期号；文字格换了
///    浅色底（「瑞士」预设、相册的象牙纸）白字翻深、墨字在黑纸上翻浅；长标题在单字号里折行不缩字、六格细线只缩
///    刊头那一行、两栏细线和基线还对齐；巨型数字的抠图贴不到成品底边（人在格子里断了、相册留了下边距）就不抠。
/// 5. 最后一轮核对修的：模板自带的格级黑白换模板时不跟着照片走（换一批照样跟）、两个新字段的旧 JSON / 来回、
///    满版巨字的巨字按刊名的规矩判（挡掉字母的退回人前）、小字沿左边找干净的地方、竖排巨字的尾留一个下边距。
/// 全过退出 0，否则 1。
enum CollageSwissSelfTest {

    @MainActor
    static func run() -> Never {
        // 无头：这里一个界面都不碰，兜底也不许弹访达（AppRuntime.revealInFinder）。
        AppRuntime.headless = true
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }

        // ---------------------------------------------------------------- 1. 公式
        print("== 栅格公式（R4 §B3）")
        let canvases: [(String, CollageCanvas, ClosedRange<Double>)] = [
            ("3:4", CollageCanvas.social[0], 0.026...0.047),
            ("1:1", CollageCanvas.social[1], 0.026...0.047),
            ("4:5", CollageCanvas.social[3], 0.03...0.035),
            ("9:16", CollageCanvas.social[4], 0.03...0.035),
            ("A4", CollageCanvas.social[7], 0.03...0.04),
        ]
        for (label, canvas, sizes) in canvases {
            let g = CollageStyleSwiss.Grid.solve(canvas: canvas, sizes: sizes)
            let W = Double(canvas.width)
            let H = Double(canvas.height)
            let S = min(W, H)
            let c = abs(W - H) < 1 ? 4 : 6
            let m = 0.05 * W
            let b = g.baseline
            let cw = (W - 2 * m - Double(c - 1) * b) / Double(c)
            let avail = H - 2 * m - g.band
            let r = Int((avail / (cw + b)).rounded())
            let mh = (((avail - Double(r - 1) * b) / Double(r)) / b).rounded(.down) * b
            let used = Double(r) * mh + Double(r - 1) * b
            let sRel = g.size / S
            check(g.columns == c, "\(label) 栏数", "\(g.columns)（竖版 6 栏、方的 4 栏）")
            check(abs(g.margin - m) < 1e-6, "\(label) 边距 = 0.05W", f1(g.margin))
            check(abs(b - 1.1 * g.size) < 1e-6 && abs(g.gap - b) < 1e-9, "\(label) b = 1.1s、g = b",
                  "s \(f1(g.size)) b \(f1(b))")
            check(b == b.rounded(), "\(label) b 是整数像素", f1(b))
            check(abs(g.column - cw) < 1e-6, "\(label) 栏宽", f1(g.column))
            check(g.rows == r, "\(label) r = round((H−2m−t)/(cw+g))", "\(g.rows)")
            check(abs(g.module - mh) < 1e-6 && g.lines >= 2, "\(label) 格高吸附整数行", "\(g.lines) 行 = \(f1(g.module))")
            check(abs(g.leftover - (avail - used)) < 1e-6 && g.leftover >= -1e-6 && g.leftover < b,
                  "\(label) 吸附后剩下的不到一行", f1(g.leftover))
            check(sRel >= 0.026 - 1e-9 && sRel <= 0.047 + 1e-9, "\(label) 小字在实测区间 0.026–0.047 S",
                  String(format: "%.4f S", sRel))
            // 栏宽 × c + 缝 = 版心宽；行 × 格 + 缝 + 剩下的 = 版心高。
            let rowsH = g.rowsHeight(g.rows)
            check(abs(g.span(c) - (W - 2 * m)) < 1e-6 && abs(rowsH + g.leftover - avail) < 1e-6,
                  "\(label) 栏、格加起来正好是版心", "\(f1(g.span(c))) × \(f1(rowsH))")
        }
        // 顶部空带也照公式（t = 0.15H、0.25H）。
        for t in [0.15, 0.25] {
            let canvas = CollageCanvas.social[0]
            let g = CollageStyleSwiss.Grid.solve(canvas: canvas, band: t * Double(canvas.height), sizes: 0.03...0.037)
            let top = g.rowTop(0)
            check(abs(top - (g.margin + t * Double(canvas.height))) < 1e-6 && g.leftover < g.baseline,
                  "3:4 顶部空带 t = \(t)H", "第一格上沿 \(f1(top)) · \(g.rows) 格 × \(g.lines) 行 · 剩 \(f1(g.leftover))")
        }

        // ---------------------------------------------------------------- 2. 模板
        print("== 模板")
        let builtin = CollageTemplates.builtin
        let swiss = builtin.filter { $0.category == CollageStyleSwiss.category }
        check(swiss.count == 5, "「瑞士网格」5 款（DESIGN 的四种 + 竖排巨字的满版那一版）", "\(swiss.count) 款")
        let grids: [String: CollageStyleSwiss.Grid] = [
            CollageStyleSwiss.giantNumber.name: CollageStyleSwiss.numberGrid,
            CollageStyleSwiss.singleSize.name: CollageStyleSwiss.typeGrid,
            CollageStyleSwiss.rotatedWord.name: CollageStyleSwiss.wordGrid,
            CollageStyleSwiss.fullBleedWord.name: CollageStyleSwiss.wordGrid,
            CollageStyleSwiss.sixModules.name: CollageStyleSwiss.sixGrid,
        ]
        let vars = CollageStyleSwiss.sampleVars
        for t in swiss {
            print("-- \(t.name)")
            guard let g = grids[t.name], let canvas = t.canvas, let style = t.style else {
                check(false, "\(t.name) 有栅格、画布、样式")
                continue
            }
            let W = Double(canvas.width)
            let H = Double(canvas.height)
            let S = min(W, H)
            let tol = 1.01
            check(!t.fitAspects, "\(t.name) 固定比例（不按照片重算）")
            check(t.name.hasPrefix("瑞士网格 · "), "\(t.name) 名字前缀")
            check(abs(Double(CollageLayout.gutterPixels(canvas: canvas, style: style)) - g.gap) <= tol,
                  "\(t.name) 缝 = b", "\(CollageLayout.gutterPixels(canvas: canvas, style: style)) px")
            let content = CollageLayout.contentRect(canvas: canvas, style: style)
            // 满版那一版照片四边出血，边距是照片上的字离成品边的距离（下面按摆位核对）。
            let fullBleed = t.name == CollageStyleSwiss.fullBleedWord.name
            if fullBleed {
                check(content.x0 == 0 && content.y0 == 0 && content.x1 == canvas.width && content.y1 == canvas.height,
                      "\(t.name) 照片四边出血", "\(content.x0),\(content.y0)…\(content.x1),\(content.y1)")
            } else {
                check(abs(Double(content.x0) - g.margin) <= tol, "\(t.name) 左边距 = 5%W", "\(content.x0) px")
            }
            let geo = CollageLayout.pageGeometry(t.root, canvas: canvas, style: style)
            // 栏线、基线格（成品像素）。出血到成品边的格子（照片铺到底边、右边）那一边不算。
            let xs: [Double] = (0..<g.columns).flatMap { [g.columnLeft($0), g.columnLeft($0) + g.column] }
            let top = Double(content.y0)
            func onColumn(_ x: Int) -> Bool { xs.contains { abs($0 - Double(x)) <= tol } || x == 0 || x == canvas.width }
            func onLine(_ y: Int) -> Bool {
                let k = (Double(y) - top) / g.baseline
                return abs(k - k.rounded()) * g.baseline <= tol || y == canvas.height
            }
            for f in geo.frames {
                let r = f.rect
                let name = "\(t.name) [\(f.path.map(String.init).joined())]"
                check(onColumn(r.x0) && onColumn(r.x1), "\(name) 左右沿在栏线上", "\(r.x0)…\(r.x1)")
                // 巨型数字那一版：字格和照片格之间那道缝是「让数字字顶落在格线上」反推的（字格下沿、照片格上沿
                // 不在格线上），单独核对字顶（下面）。
                let capCut = t.name == CollageStyleSwiss.giantNumber.name
                let y0OK = onLine(r.y0) || (capCut && f.cell.kind == .photo)
                let y1OK = onLine(r.y1) || (capCut && f.cell.kind == .text)
                check(y0OK && y1OK, "\(name) 上下沿在基线格上（格高整数行）", "\(r.y0)…\(r.y1)")
            }
            for gut in geo.gutters {
                let w = gut.axis == .row ? gut.rect.width : gut.rect.height
                check(abs(Double(w) - g.gap) <= tol, "\(t.name) 缝[\(gut.path.map(String.init).joined())] = b", "\(w)")
            }

            // 字：小字块的基线、字号、大小写、对齐、颜色。
            var sizes: [Double] = []
            var accents: Set<String> = []
            var phases: [Double] = []
            // 大小写、对齐、强调色（字号另算：要按排出来的算）。巨型数字是数位，不管大小写。
            func collect(_ text: CollageText) {
                for l in text.lines {
                    if l.color != CollageStyleSwiss.ink && l.color != .white {
                        accents.insert(String(format: "%.3f,%.3f,%.3f", l.color.r, l.color.g, l.color.b))
                    }
                    if !l.text.contains("{month}.{day}") {
                        check(l.textCase == .lower, "\(t.name) 「\(l.text)」默认小写")
                    }
                }
                check(text.alignH == .leading, "\(t.name) 左齐", text.lines.first?.text ?? "")
            }
            for f in geo.frames {
                for o in f.cell.overlays { collect(o.text) }
                guard f.cell.kind == .text, let text = f.cell.text else { continue }
                collect(text)
                let rect = f.rect.cgRect
                let laid = CollageTypeset.prepared(text, in: rect, short: S, vars: vars)
                let fitted = laid.text
                for l in fitted.lines { sizes.append(l.size * laid.short) }
                if text.isRotated {
                    let big: Double = (fitted.lines.first?.size ?? 0) * laid.short
                    check(big >= 7 * g.size - 0.5, "\(t.name) 转 90° 的巨字 ≥ 7 倍小字", "\(f1(big)) px")
                    continue
                }
                check(abs(laid.short - S) < 1e-6, "\(t.name) 字格放得下（默认字不缩）",
                      String(format: "缩到 %.3f", laid.short / S))
                let glyphs = CollageTypeset.glyphOutlines(fitted, in: rect, short: laid.short, vars: vars)
                var baselines: [Int: Double] = [:]
                for gl in glyphs where baselines[gl.line] == nil { baselines[gl.line] = gl.baseline }
                let ordered = baselines.keys.sorted().compactMap { baselines[$0] }
                let pitch: Double = text.rule && text.ruleStyle == .underEachLine ? 2 * g.baseline : g.baseline
                let steps = zip(ordered.dropFirst(), ordered).map { $0 - $1 }
                check(steps.allSatisfy { abs($0 - pitch) <= 0.5 },
                      "\(t.name) 小字基线一行隔 \(pitch == g.baseline ? "b" : "2b")",
                      steps.isEmpty ? "一行" : steps.map(f1).joined(separator: " / "))
                if let first = ordered.first {
                    let k = (first - top) / g.baseline
                    phases.append((k - k.rounded(.down)) * g.baseline)
                }
            }
            // 照片上的字（巨型数字 / 刊头）按摆位排出来的字号算。
            for f in geo.frames where !f.cell.overlays.isEmpty {
                let project = projectFor(t, canvas: canvas, style: style)
                let placed = CollageRender.overlayPlacements(cell: f.cell, frameRect: f.rect.cgRect, project: project,
                                                             photo: nil, framing: f.cell.framing, hints: nil, vars: vars,
                                                             background: style.background)
                for (i, p) in placed.enumerated() {
                    guard let p else { continue }
                    for l in p.text.lines { sizes.append(l.size * p.short) }
                    let o = f.cell.overlays[i]
                    check(o.shadow == 0, "\(t.name) 照片上的字不垫雾面、不加投影")
                    if fullBleed {
                        // 小字左沿、巨字右沿离成品边 m；巨字在人后、按刊名的规矩，顶和小字那一截下面隔一行。
                        let big = p.text.isRotated
                        let edge: Double = big ? W - Double(p.rect.maxX) : Double(p.rect.minX)
                        check(abs(edge - g.margin) <= 1.5, "\(t.name) \(big ? "巨字右沿" : "小字左沿")离成品边 m",
                              "\(f1(edge)) px")
                        if big {
                            check(o.layer == .behindSubject && o.occlusionRule == .masthead && o.maxOcclusion <= 0.15,
                                  "\(t.name) 巨字在人后、按刊名的规矩（首末字母、过半的字母都管，总量 ≤ 15%）")
                            check(f.cell.look?.look == .contrastMono, "\(t.name) 照片格自己带高反差黑白（换样式、进相册不变）")
                            let gapAbove: Double = Double(p.rect.minY) - (g.margin + 5 * g.baseline)
                            check(abs(gapAbove - g.baseline) <= 4, "\(t.name) 巨字的顶在小字那一截下面隔一行",
                                  "顶 y \(f1(Double(p.rect.minY)))")
                        }
                    }
                    if t.name == CollageStyleSwiss.giantNumber.name {
                        let size: Double = (p.text.lines.first?.size ?? 0) * p.short
                        let gap = CollageStyleSwiss.capGap(font: .helveticaNeue, weight: .bold, size: size)
                        let cap: Double = Double(p.rect.minY) + gap
                        let k = (cap - top) / g.baseline
                        check(abs(k - k.rounded()) * g.baseline <= 1.5, "巨型数字的字顶落在基线格上",
                              "字顶 y \(f1(cap)) = 第 \(f1(k)) 行")
                        check(abs(Double(p.rect.width) - g.span(g.columns)) <= 4, "巨型数字铺满六栏",
                              "\(f1(Double(p.rect.width))) / \(f1(g.span(g.columns)))")
                        check(o.layer == .behindSubject && o.occlusionRule == .total && f.cell.framing == .cover
                              && f.cell.cutout?.toEdge == true, "巨型数字：人后、只限总量、封面取景、抠图格（贴底边）")
                        check(f.cell.look?.look == .contrastMono, "巨型数字：照片格自己带高反差黑白（换样式、进相册不变）")
                    }
                }
            }
            // 同一套基线格：所有小字块第一条基线离格线的偏移一样（字体上沿一样，差 1–2 px 是粗细字重）。
            if let lo = phases.min(), let hi = phases.max() {
                check(hi - lo <= 1.5, "\(t.name) 小字块落在同一套基线格上", phases.map(f1).joined(separator: " / "))
            }
            // 字号种类：相差 1% 以内算一种。
            var kinds: [Double] = []
            for v in sizes.sorted() where !kinds.contains(where: { abs($0 - v) / max(1, v) < 0.01 }) { kinds.append(v) }
            check(kinds.count <= 3, "\(t.name) 字号 ≤ 3 种", kinds.map(f1).joined(separator: " / "))
            if let small = kinds.first, let big = kinds.last, big > 4 * small {
                let ratio = big / small
                check(ratio >= 7 && ratio <= 18, "\(t.name) 大字是小字的 7–18 倍", String(format: "%.1f 倍", ratio))
            }
            check(kinds.contains { abs($0 - g.size) <= 0.5 }, "\(t.name) 小字 = 栅格的 s", f1(g.size))
            check(accents.count <= 1, "\(t.name) 一种强调色", accents.sorted().joined(separator: " "))
            check(accents.allSatisfy { a in
                [CollageStyleSwiss.red, CollageStyleSwiss.orange].contains { String(format: "%.3f,%.3f,%.3f", $0.r, $0.g, $0.b) == a }
            }, "\(t.name) 强调色是印刷红 / 橙红")
            check(style.look == .contrastMono, "\(t.name) 照片高反差黑白")
            // 红字面积：占位符先换成样例变量（没有照片就没有日期，巨型数字会只剩一个点），按成品 1/4 渲染
            // （空照片格画占位，不是红的），数偏红的像素。
            let share = redShare(filled(t), canvas: canvas, style: style)
            check(share <= 0.2, "\(t.name) 红色面积 ≤ 20%", String(format: "%.1f%%", share * 100))
        }

        // ---------------------------------------------------------------- 3. 名字、文案、预设
        print("== 名字、文案、预设")
        let names = builtin.map(\.name)
        check(Set(names).count == names.count, "模板名全库唯一")
        let others = ["小红书封面", "日系杂志", "中式", "九宫格", "手账散落", "电影感", "基础",
                      "时尚刊", "底片印样", "留白杂志", "报纸风", "婚礼相册"]
        for t in swiss {
            let hit = others.filter { t.name.contains($0) || t.category.contains($0) }
            check(hit.isEmpty, "\(t.name) 不含别的分类名", hit.joined(separator: " "))
        }
        let notMine = builtin.filter { $0.category != CollageStyleSwiss.category }
            .filter { $0.name.contains(CollageStyleSwiss.category) || $0.category.contains(CollageStyleSwiss.category) }
        check(notMine.isEmpty, "别的模板不会被 --only 瑞士网格 带进来", notMine.map(\.name).joined(separator: " "))
        let banned = ["VOGUE", "ELLE", "BAZAAR", "MUSE", "W", "GQ", "TIME", "KINFOLK", "CEREAL", "KODAK", "FUJI",
                      "ILFORD", "PORTRA"]
        for t in swiss {
            var lines: [String] = []
            for cell in t.root.leaves {
                let own: [CollageTextLine] = cell.text?.lines ?? []
                let onPhoto: [CollageTextLine] = cell.overlays.flatMap { $0.text.lines }
                lines += (own + onPhoto).map { $0.text }
            }
            let words = Set(lines.joined(separator: " ").uppercased()
                .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            let hit = banned.filter { b in words.contains(b) || (b.count > 3 && words.contains { $0.contains(b) }) }
            check(hit.isEmpty, "\(t.name) 默认字没有真实刊名 / 胶片牌子", hit.joined(separator: " "))
            check(!lines.contains { $0.contains("{make}") || $0.contains("{brand}") },
                  "\(t.name) 不用 {make} / {brand}（会展开成相机厂牌）")
        }
        check(CollageStyles.all.contains { $0.key == "swiss" && $0.name == "瑞士" }, "预设「瑞士」在样式列表里")
        if let p = CollageStyles.all.first(where: { $0.key == "swiss" }) {
            check(p.style.look == .contrastMono && p.style.background == CollageStyleSwiss.paper
                  && abs(p.style.margin - 0.05) < 1e-9 && !p.style.tightSmallCells && p.style.insets == nil,
                  "预设「瑞士」：纸 #F2F1EC、高反差黑白、5% 边距、不收小格、不带四边边距",
                  String(format: "缝 %.4f", p.style.gutter))
        }

        roundOne(swiss, check: check)
        finalRound(check: check)

        print(failures.isEmpty ? "== 全部通过" : "== 失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    /// 4. 第 1 轮核对修的（合成数据）。
    @MainActor
    private static func roundOne(_ swiss: [CollageTemplate], check: (Bool, String, String) -> Void) {
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        print("== 没有 EXIF / 拍摄时间、换了底色、长标题、抠图贴底边")
        // 4.1 没有 EXIF、没有拍摄时间（截图、微信转过的图）：CollageTypeset.variables 只给得出刊头、期号、张数。
        // 每块字展开之后只能剩这几句，不留「f/ · s · iso」「, 」「.」这种残渣。
        let bare: [String: String] = ["title": "拾光", "masthead": "SHIGUANG", "no": "01", "issue": "01",
                                      "count": "1", "subtitle": ""]
        let allowed: Set<String> = ["shiguang", "photographs", "photographs: 1", "no. 01", "no.01"]
        for t in swiss {
            var texts: [CollageText] = []
            for cell in t.root.leaves {
                if let x = cell.text { texts.append(x) }
                texts += cell.overlays.map(\.text)
            }
            let shown = texts.flatMap { CollageTypeset.expandedLines($0, vars: bare).map(\.text) }
            let junk = shown.filter { !allowed.contains($0) }
            check(junk.isEmpty, "\(t.name) 没有 EXIF、拍摄时间时不留标点残渣",
                  junk.isEmpty ? shown.joined(separator: " / ") : junk.map { "「\($0)」" }.joined(separator: " "))
        }
        let number = CollageStyleSwiss.giantNumber.root.leaves.flatMap(\.overlays).first?.text
        let noDate = number.map { CollageTypeset.expandedLines($0, vars: bare).map(\.text) } ?? []
        let dated = number.map { CollageTypeset.expandedLines($0, vars: CollageStyleSwiss.sampleVars).map(\.text) } ?? []
        check(noDate == ["no.01"] && dated == ["03.21"], "巨型数字：有日期 03.21，没有拍摄时间换成期号",
              (dated + noDate).joined(separator: " / "))

        // 4.2 换了底色：文字格都跟着底色翻（paperTone）；白字到浅纸上、墨字到黑纸上翻过来；强调色不翻成黑白，
        // 不够 4:1 的（橙红落到浅纸上）色相不变、调深浅到 4.5:1。
        for t in swiss {
            let cells = t.root.leaves.compactMap(\.text)
            check(cells.allSatisfy(\.paperTone), "\(t.name) 文字格的字跟着页面底色翻深浅", "\(cells.count) 块")
        }
        let backgrounds: [(String, CollageColor)] = [("瑞士纸", CollageStyleSwiss.paper), ("白", .white),
                                                     ("象牙", CollageColor.paper), ("墨黑", CollageStyleSwiss.ink)]
        for t in swiss {
            for (label, bg) in backgrounds {
                var worst = 21.0
                var worstAccent = 21.0
                var accentsKept = true
                var moved: [String] = []
                for text in t.root.leaves.compactMap(\.text) {
                    let toned = CollageRender.paperToned(text, background: bg)
                    for (a, b) in zip(text.lines, toned.lines) {
                        let ratio = CollageContact.contrast(b.color, bg)
                        worst = min(worst, ratio)
                        guard a.color == CollageStyleSwiss.red || a.color == CollageStyleSwiss.orange else { continue }
                        worstAccent = min(worstAccent, ratio)
                        // 色相、饱和度不变（还是红 / 橙红，不是黑白）；原来就够 4:1 的一点不动。
                        let hueKept = abs(a.color.hsl.h - b.color.hsl.h) < 0.01 && abs(a.color.hsl.s - b.color.hsl.s) < 0.02
                        let before = CollageContact.contrast(a.color, bg)
                        if !hueKept || (before >= 4 && a.color != b.color) { accentsKept = false }
                        if a.color != b.color { moved.append(String(format: "%.1f→%.1f", before, ratio)) }
                    }
                }
                check(worst >= 3 && worstAccent >= 4 && accentsKept,
                      "\(t.name) 文字格在「\(label)」底上的字都 ≥ 3:1、强调色 ≥ 4:1 且不翻成黑白",
                      String(format: "最低 %.1f:1 · 强调色最低 %.1f:1", worst, worstAccent)
                        + (moved.isEmpty ? "" : " · 强调色调了深浅 " + moved.joined(separator: " ")))
            }
        }

        // 4.3 长标题（四十来个字母）+ 副标题。
        var long = CollageStyleSwiss.sampleVars
        long["masthead"] = "SPRING AFTERNOON IN THE OLD TOWN OF SUZHOU"
        long["subtitle"] = "with lin and wang"
        func cellText(_ t: CollageTemplate, _ k: Int) -> (CollageText, CGRect)? {
            guard let canvas = t.canvas, let style = t.style else { return nil }
            let geo = CollageLayout.pageGeometry(t.root, canvas: canvas, style: style)
            let cells = geo.frames.filter { $0.cell.kind == .text }
            guard cells.indices.contains(k), let text = cells[k].cell.text else { return nil }
            return (text, cells[k].rect.cgRect)
        }
        func baselines(_ text: CollageText, _ rect: CGRect, short: Double, vars: [String: String]) -> [Double] {
            let laid = CollageTypeset.prepared(text, in: rect, short: short, vars: vars)
            let glyphs = CollageTypeset.glyphOutlines(laid.text, in: rect, short: laid.short, vars: vars)
            var out: [Int: Double] = [:]
            for gl in glyphs where out[gl.line] == nil { out[gl.line] = gl.baseline }
            return out.keys.sorted().compactMap { out[$0] }
        }
        // 单字号：刊头、副标题折行，整块不缩，每一行都是栅格的 s，基线还是一行隔 b。
        let tg = CollageStyleSwiss.typeGrid
        if let (main, rect) = cellText(CollageStyleSwiss.singleSize, 0) {
            let laid = CollageTypeset.prepared(main, in: rect, short: tg.short, vars: long)
            let sizes = laid.text.lines.map { $0.size * laid.short }
            let shown = CollageTypeset.expandedLines(laid.text, vars: long).map(\.text)
            let steps = zip(baselines(main, rect, short: tg.short, vars: long).dropFirst(),
                            baselines(main, rect, short: tg.short, vars: long)).map { $0 - $1 }
            check(abs(laid.short - tg.short) < 1e-6 && sizes.allSatisfy { abs($0 - tg.size) <= 0.5 } && shown.count > 5,
                  "单字号：长标题折行，整块不缩、只有一种字号", shown.joined(separator: " / "))
            check(steps.allSatisfy { abs($0 - tg.baseline) <= 0.5 }, "单字号：折行之后基线还是一行隔 b",
                  steps.map(f1).joined(separator: " / "))
        }
        // 六格细线：刊头那栏 4 栏宽，四十来个字母照原字号放得下；六十多个只缩刊头那一行，日期、右栏照原字号，
        // 两栏第一条基线对齐。
        let sg = CollageStyleSwiss.sixGrid
        var longer = long
        longer["masthead"] = "SPRING AFTERNOON IN THE OLD TOWN OF SUZHOU WITH LIN AND WANG"
        if let (left, lr) = cellText(CollageStyleSwiss.sixModules, 0), let (right, rr) = cellText(CollageStyleSwiss.sixModules, 1) {
            for (label, vars) in [("四十来个字母", long), ("六十多个字母", longer)] {
                let a = CollageTypeset.prepared(left, in: lr, short: sg.short, vars: vars)
                let b = CollageTypeset.prepared(right, in: rr, short: sg.short, vars: vars)
                let dateSize: Double = (a.text.lines.first?.size ?? 0) * a.short
                let mastSize: Double = (a.text.lines.last.map { $0.size * $0.glyphScale } ?? 0) * a.short
                let la = baselines(left, lr, short: sg.short, vars: vars)
                let lb = baselines(right, rr, short: sg.short, vars: vars)
                // 两栏的基线（每行下面细线跟着基线走）一条一条对齐：刊头缩了字形，行框、基线、细线不动。
                let aligned = la.count == lb.count && zip(la, lb).allSatisfy { abs($0 - $1) <= 0.5 }
                check(abs(a.short - sg.short) < 1e-6 && abs(b.short - sg.short) < 1e-6 && abs(dateSize - sg.size) <= 0.5
                      && mastSize <= sg.size + 0.5 && aligned,
                      "六格细线（\(label)）：左右两栏照原字号、基线一条条对齐，只有刊头那行按需缩字形",
                      "日期 \(f1(dateSize)) 刊头 \(f1(mastSize)) px · 基线 \(la.map(f1).joined(separator: ",")) | \(lb.map(f1).joined(separator: ","))")
            }
        }

        // 4.4 抠图贴底边（合成蒙版）：人一直到照片底边 = 抠；人在格子里断了（栏杆挡住的一刀齐）= 不抠；
        // 格子底边不是成品底边（相册留了下边距）= 不抠。
        let t = CollageStyleSwiss.giantNumber
        guard let canvas = t.canvas, let style = t.style else { return }
        let geo = CollageLayout.pageGeometry(t.root, canvas: canvas, style: style)
        guard let frame = geo.frames.first(where: { $0.cell.kind == .photo }) else { return }
        let mw = 682
        let mh = 1024
        let face: [Double] = [0.42, 0.22, 0.58, 0.32]
        func paint(bodyBottom: Double) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: mw * mh)
            for y in 0..<mh {
                for x in 0..<mw {
                    let u = (Double(x) + 0.5) / Double(mw)
                    let v = (Double(y) + 0.5) / Double(mh)
                    let du = (u - 0.5) / 0.1
                    let dv = (v - 0.25) / 0.08
                    let head = du * du + dv * dv <= 1
                    let body = u >= 0.3 && u <= 0.7 && v >= 0.31 && v <= bodyBottom
                    if head || body { px[y * mw + x] = 255 }
                }
            }
            return px
        }
        func resolve(_ name: String, bodyBottom: Double, frameRect: CGRect) -> CollageCover.Resolution? {
            var p = CollagePhotoRef(id: "swiss-edge-\(name)", path: "/nonexistent/swiss-edge-\(name).jpg",
                                    width: 4000, height: 6000)
            p.faces = [face]
            CollageMasks.inject(CollageMasks.synthetic(paint(bodyBottom: bodyBottom), width: mw, height: mh,
                                                       faces: [face]), for: p)
            var cell = frame.cell
            cell.photoID = p.id
            var project = CollageProject()
            project.canvas = canvas
            project.style = style
            project.photos = [p]
            CollageCover.purge()
            return CollageCover.resolve(cell: cell, frameRect: frameRect, project: project, photo: p, framing: .cover,
                                        hints: nil, vars: CollageStyleSwiss.sampleVars, background: style.background)
        }
        let rect = frame.rect.cgRect
        let whole = resolve("whole", bodyBottom: 1, frameRect: rect)
        check(whole?.cutoutDropped == false && whole?.mask != nil, "抠图贴底边：人一直到照片底边 = 抠",
              whole?.edgeCoverage.map { String(format: "底边 %.0f%% 身子 %.0f%%", $0.edge * 100, $0.body * 100) } ?? "没有决定")
        if let w = whole?.window {
            let cut: Double = w.y + 0.8 * w.h
            let floating = resolve("cut", bodyBottom: cut, frameRect: rect)
            check(floating?.cutoutDropped == true && floating?.mask != nil && floating?.cutoutReason != nil,
                  "抠图贴底边：人在格子里断了（取景 80% 处一刀齐）= 不抠、整张照放", floating?.cutoutReason ?? "抠了")
        }
        let lifted = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 60)
        let album = resolve("album", bodyBottom: 1, frameRect: lifted)
        check(album?.cutoutDropped == true, "抠图贴底边：格子底边不是成品底边（相册的下边距）= 不抠", album?.cutoutReason ?? "抠了")
        CollageCover.purge()
        CollageMasks.purgeMemory()
    }

    /// 5. 最后一轮核对修的（合成数据）。
    @MainActor
    private static func finalRound(check: (Bool, String, String) -> Void) {
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        print("== 模板自带的黑白、存模板、满版巨字、竖排巨字的尾")
        // 5.1 模板自带的格级黑白（fromTemplate）换模板时不跟着照片走；用户自己设的照样带。
        var mono = CollageCell.photo("swiss-a")
        mono.look = CollageLookSetting(look: .contrastMono, strength: 1, fromTemplate: true)
        var user = CollageCell.photo("swiss-b")
        user.look = CollageLookSetting(look: .mono, strength: 0.8)
        let old = CollageNode.split(.row, 0.5, .leaf(mono), .leaf(user))
        let next = CollageNode.split(.column, 0.5, .leaf(.photo("swiss-a")), .leaf(.photo("swiss-b")))
        let carried = CollageLayout.carryCellLooks(from: old, into: next).leaves
        check(carried.first?.look == nil && carried.last?.look?.look == .mono,
              "换模板：模板自带的黑白不带进新版式，用户设的照样带",
              carried.map { $0.look?.look.rawValue ?? "跟样式" }.joined(separator: " / "))
        let shuffled = CollageLayout.carryOverlays(from: old, into: next).leaves
        check(shuffled.first?.look?.look == .contrastMono, "换一批（同一个模板）：模板自带的黑白跟着照片走", "")
        let baked = [CollageStyleSwiss.giantNumber, CollageStyleSwiss.fullBleedWord].flatMap { $0.root.leaves }
            .compactMap(\.look)
        check(baked.count == 2 && baked.allSatisfy(\.fromTemplate), "巨型数字、满版巨字的格级黑白记成模板自带的", "")
        // 5.2 新字段的存盘：旧 JSON（没有这两个键）读成默认，新的来回不丢。
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let oldLook = try? decoder.decode(CollageLookSetting.self, from: Data(#"{"look":"contrastMono","strength":1}"#.utf8))
        let lookTrip = (try? encoder.encode(mono.look)).flatMap { try? decoder.decode(CollageLookSetting.self, from: $0) }
        check(oldLook?.fromTemplate == false && lookTrip?.fromTemplate == true, "色调的 fromTemplate：旧 JSON = false，来回不丢", "")
        var page = CollagePage(root: .leaf(.photo("swiss-a")))
        page.fixedAspects = true
        let pageTrip = (try? encoder.encode(page)).flatMap { try? decoder.decode(CollagePage.self, from: $0) }
        let oldPage = try? decoder.decode(CollagePage.self, from: Data(#"{"root":{"cell":{"kind":"photo"}}}"#.utf8))
        check(pageTrip?.fixedAspects == true && oldPage?.fixedAspects == false,
              "页的 fixedAspects（存「我的模板」默认固定比例）：旧 JSON = false，来回不丢", "")
        // 5.3 满版巨字：巨字按刊名的规矩判（核对里挡字的两张：7226 总 19.2%、2 个字母过半；7229 首字母 100%）。
        let a = CollageCover.Occlusion(total: 0.192, perLetter: [0, 0.1, 0.9, 0.6, 0, 0, 0, 0], first: 0, last: 0, heavy: 2)
        let b = CollageCover.Occlusion(total: 0.179, perLetter: [1, 0.3, 0, 0, 0, 0, 0, 0], first: 1, last: 0, heavy: 1)
        let c = CollageCover.Occlusion(total: 0.023, perLetter: [0, 0, 0, 0, 0, 0, 0.15, 0.05], first: 0, last: 0.05, heavy: 0)
        let limit: Double = 0.15
        check(CollageCover.failure(a, limit: limit, rule: .masthead) != nil
              && CollageCover.failure(b, limit: limit, rule: .masthead) != nil
              && CollageCover.failure(c, limit: limit, rule: .masthead) == nil,
              "满版巨字：挡掉字母的退回人前，手指尖擦到一点的留在人后",
              [a, b, c].map { CollageCover.failure($0, limit: limit, rule: .masthead) ?? "在人后" }.joined(separator: " / "))
        let fb = CollageStyleSwiss.fullBleedWord
        if let cell = fb.root.leaves.first, cell.overlays.count == 2 {
            let small = cell.overlays[0]
            let neutral = small.text.lines.allSatisfy { $0.color == CollageStyleSwiss.ink }
            check(small.anchor == .leftColumn && small.tone == .auto && neutral && small.shadow == 0,
                  "满版巨字：小字贴左边距、沿左边找干净的地方，墨 / 白按底下明暗（强调色只给巨字），不垫雾面", "")
        }
        // 5.4 竖排巨字：巨字格的下沿 = 成品底边 − 栅格下边距 − 一道缝，下面一块空格（巨字的尾是留出来的）。
        let rw = CollageStyleSwiss.rotatedWord
        let wg = CollageStyleSwiss.wordGrid
        if let canvas = rw.canvas, let style = rw.style {
            let geo = CollageLayout.pageGeometry(rw.root, canvas: canvas, style: style)
            let word = geo.frames.first { $0.cell.text?.isRotated == true }
            let expected: Double = wg.height - (wg.margin + wg.leftover) - wg.gap
            let bottom = Double(word?.rect.y1 ?? 0)
            let emptyBelow = geo.frames.contains { $0.cell.kind == .empty && Double($0.rect.y0) > bottom }
            check(abs(bottom - expected) <= 1.01 && emptyBelow, "竖排巨字：巨字格的下沿离成品底边一个下边距加一道缝",
                  "下沿 \(f1(bottom)) / \(f1(expected))")
        }
    }

    /// 套这个模板的一页（照片格都空着）的工程：标题「拾光」（刊头 SHIGUANG），没有照片也就没有日期。
    private static func projectFor(_ t: CollageTemplate, canvas: CollageCanvas, style: CollageStyle) -> CollageProject {
        var project = CollageProject()
        project.canvas = canvas
        project.style = style
        project.title = "拾光"
        project.pages = [CollagePage(root: t.root, items: t.items, freeform: false)]
        return project
    }

    /// 每块字的占位符换成样例变量（量红字面积用：巨型数字是 03.21 而不是空的）。
    private static func filled(_ t: CollageTemplate) -> CollageTemplate {
        func fill(_ text: CollageText) -> CollageText {
            var out = text
            out.lines = text.lines.map { l in
                var line = l
                line.text = CollageTypeset.fill(l.text, vars: CollageStyleSwiss.sampleVars)
                return line
            }
            return out
        }
        var out = t
        for path in t.root.leafPaths() {
            out.root.update(at: path) { node in
                guard var cell = node.cell else { return }
                if let text = cell.text { cell.text = fill(text) }
                cell.overlays = cell.overlays.map { o in
                    var copy = o
                    copy.text = fill(o.text)
                    return copy
                }
                node.cell = cell
            }
        }
        return out
    }

    /// 偏红像素占整页的比例（成品 1/4 渲染，空照片格画占位）。
    private static func redShare(_ t: CollageTemplate, canvas: CollageCanvas, style: CollageStyle) -> Double {
        let project = projectFor(t, canvas: canvas, style: style)
        guard let page = project.pages.first else { return 1 }
        var opts = CollageRender.Options(scale: 0.25)
        opts.includeBleed = false
        opts.placeholders = true
        guard let image = CollageRender.render(page: page, project: project, hints: [:], options: opts) else { return 1 }
        let w = image.width
        let h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 1 }
        let px = data.assumingMemoryBound(to: UInt8.self)
        var red = 0
        for i in 0..<(w * h) {
            let r = Int(px[i * 4])
            let g = Int(px[i * 4 + 1])
            let b = Int(px[i * 4 + 2])
            if r > 150, r - g > 80, r - b > 80 { red += 1 }
        }
        return Double(red) / Double(max(1, w * h))
    }
}
