import Foundation
import CoreGraphics
import CoreText

/// LABELGUI_DATA_DIR=<临时> LabelGUI --mask-selftest <photo_dir>（先 --analyze 过）
///
/// 1. 真照片：每张算一次主体蒙版（第一次含加载模型），打印耗时、覆盖率、每张脸的头顶（应在脸框上沿上面一点）、
///    实例；同一张算两次逐字节比（确定性）；存盘再读回逐字节比。给了文件夹却一张都拿不到（没分析过）算失败。
/// 2. 合成数据（不是真照片，也没在真合影上验过）：
///    - 遮挡规则逐条：首字母 5%、末字母 15%、总量 25%（可调）/ 33%（硬上限）、过半的字母 6 个以内 1 个 / 7 个以上 2 个、
///      主行以外的小字行每行 15%；
///    - 开关看着没反应的（自动位置、不是封面取景）说清原因；横图封面眼睛离刊头远记 eyeFar；
///    - 字形 × 蒙版的量法（一个字母整个被盖 = 1）；
///    - 退让每一步都走得到：照原样、横向挪、拉远、缩刊头、退回人前（挡太多 / 合影 3 张脸 / 认不出主体）；
///    - 退回人前压着头的（不是封面取景）挪到不压脸的地方；装饰大字只限总量；零边距印刷的取景留出出血外延；
///    - 决定和渲染缩放无关（同一个决定）。
///    真照片另验：抠图格的字深浅看页面底色（白页深字、黑页浅字），不看画不出来的照片背景。
/// 3. 字形轮廓（量遮挡用）和 drawFitted 真画出来的墨重合（横排居中铺满宽度、字距、压窄、两行、竖排、转 90°）。
/// 全过退出 0，否则 1。
enum CollageMaskSelfTest {

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        CollageCLI.requireIsolatedDataDir("--mask-selftest")
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }

        // ---------------------------------------------------------------- 1. 真照片
        if args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") {
            let dir = URL(fileURLWithPath: args[flagIndex + 1])
            let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
            batch.switchSession(to: dir)
            let maskDir = batch.sessionDir.appendingPathComponent("collage_masks")
            CollageMasks.setDirectory(maskDir)
            let facts = CollageBridge.Facts(batch: batch)
            let photos = batch.items.compactMap { CollageBridge.ref(from: $0, facts: facts) }
            print("== 真照片 \(photos.count) 张（\(dir.lastPathComponent)）· 蒙版目录 \(maskDir.path)")
            // 没分析过的文件夹（新的数据目录）一张都拿不到：别让真照片那一半悄悄跳过还报「全部通过」。
            check(!photos.isEmpty, "照片文件夹分析过（拿得到照片）",
                  photos.isEmpty ? "0 张：先 LABELGUI_DATA_DIR=同一个目录 LabelGUI --analyze \(dir.path)" : "")
            var times: [Double] = []
            for (i, p) in photos.enumerated() {
                CollageMasks.purgeMemory()
                let t0 = Date()
                guard let a = CollageMasks.compute(p, writeToDisk: false) else {
                    print("    \(p.id) 认不出主体")
                    continue
                }
                let ms = Date().timeIntervalSince(t0) * 1000
                if i > 0 { times.append(ms) }
                let b = CollageMasks.compute(p, writeToDisk: false)
                let same = b.map { $0.pixels == a.pixels } ?? false
                // 存盘、清内存、读回来：逐字节一样。
                let stored = CollageMasks.mask(for: p)
                CollageMasks.purgeMemory()
                let back = CollageMasks.cachedMask(for: p)
                let roundTrip = back.map { $0.pixels == (stored?.pixels ?? []) && $0.fromDisk } ?? false
                let faceTop = p.faces.first?[1] ?? -1
                let head = a.primaryHeadTop ?? -1
                let soft = a.pixels.filter { $0 > 12 && $0 < 243 }.count
                print(String(format: "    %@ %dx%d %.0f ms 覆盖 %.3f 软边 %.2f%% 头顶 %.3f 脸框上沿 %.3f 实例 %d 选 %@%@%@",
                             p.id, a.width, a.height, ms, a.coverage, Double(soft) / Double(max(1, a.pixels.count)) * 100,
                             head, faceTop, a.instances, a.selected.map(String.init).joined(separator: "+"),
                             same ? "" : " ·两次不一样", roundTrip ? "" : " ·读回不一样"))
                check(same, "\(p.id) 两次算的蒙版逐字节相同")
                check(roundTrip, "\(p.id) 存盘读回逐字节相同")
                if faceTop >= 0 {
                    // 头顶在脸框上沿之上（脸框外扩过 15%，头发、头饰还在上面），但不会高出 1.5 张脸。
                    let fh = (p.faces.first?[3] ?? 0) - faceTop
                    check(head >= 0 && head <= faceTop + 0.05 * fh && head >= faceTop - 1.5 * fh,
                          "\(p.id) 头顶落在脸框上沿附近（方向没翻）", String(format: "头顶 %.3f 脸框 %.3f", head, faceTop))
                }
            }
            if !times.isEmpty {
                let sorted = times.sorted()
                print(String(format: "  热的蒙版耗时 中位 %.0f ms · 最慢 %.0f ms（第一张含加载模型，不算）",
                             sorted[sorted.count / 2], sorted.last ?? 0))
            }
            // 抠图格的字深浅：照片只画主体，字底下透出的是页面底色 —— 同一张照片、同一块「自动」深浅的刊头，
            // 白页面上是深字、黑页面上是浅字（以前按画不出来的照片背景判，白页上出白字）。
            let pick = photos.first { $0.id == "DSCF7229" } ?? photos.first
            if let p = pick, let m = CollageMasks.mask(for: p) {
                var c = CollageCanvas.social[0]
                c.safe = 0
                let rect = CGRect(x: 0, y: 0, width: c.width, height: c.height)
                var line = CollageTextLine("MAISON", font: .didot, weight: .bold, size: 0.12, color: .ink)
                line.fitWidth = true
                var o = CollageOverlay(text: CollageText(lines: [line], vertical: false, alignH: .center, alignV: .leading))
                o.anchor = .top
                o.maxWidth = 0.96
                o.inset = 0.02
                o.tone = .auto
                let win = CollageCrop.window(for: p, cellAspect: Double(c.width) / Double(c.height), framing: .full,
                                             override: nil, hints: nil)
                let plain = CollageOverlays.place(o, area: rect, drawn: rect, canvas: c, photo: p, window: win, hints: nil,
                                                  vars: [:], background: .white)
                print("    \(p.id) 不抠图时按照片判：\(plain.map { $0.light ? "浅字" : "深字" } ?? "—")")
                for (bg, light, name) in [(CollageColor.white, false, "白"), (CollageColor(hex: 0x1E1E1E), true, "深灰")] {
                    let placed = CollageOverlays.place(o, area: rect, drawn: rect, canvas: c, photo: p, window: win,
                                                       hints: nil, vars: [:], background: bg, matte: m)
                    check(placed?.light == light, "\(p.id) 抠图格、\(name)页面 → \(light ? "浅字" : "深字")",
                          placed.map { String(format: "%@ · 雾面 %.2f", $0.light ? "浅字" : "深字", $0.halo) } ?? "摆不下")
                }
            }
        } else {
            print("== 真照片：没给照片文件夹，跳过（只验合成数据）")
        }

        // ---------------------------------------------------------------- 2a. 规则逐条（合成的遮挡量）
        print("== 遮挡规则（合成数据）")
        func occ(_ c: [Double]) -> CollageCover.Occlusion {
            CollageCover.summarize(hits: c, ink: c.map { _ in 1 }, main: Array(c.indices))
        }
        let rules: [(String, [Double], Double, Bool)] = [
            ("全不挡 → 行", [0, 0, 0, 0, 0, 0], 0.25, true),
            ("中间挡一点 → 行", [0, 0.1, 0.5, 0.3, 0, 0], 0.25, true),
            ("首字母 6% → 不行", [0.06, 0, 0, 0, 0, 0], 0.25, false),
            ("首字母 5% → 行", [0.05, 0, 0, 0, 0, 0], 0.25, true),
            ("末字母 16% → 不行", [0, 0, 0, 0, 0, 0.16], 0.25, false),
            ("末字母 15% → 行", [0, 0, 0, 0, 0, 0.15], 0.25, true),
            ("总量 26%（上限 25%）→ 不行", [0, 0.26, 0.5, 0.5, 0.3, 0], 0.25, false),
            ("总量 26%（上限调到 30%）→ 行", [0, 0.26, 0.5, 0.5, 0.3, 0], 0.30, true),
            ("总量 34%（上限调到 33%）→ 不行", [0, 0.5, 0.5, 0.5, 0.5, 0.04], 0.33, false),
            ("6 个字母 2 个过半 → 不行", [0, 0.51, 0.51, 0, 0, 0], 0.33, false),
            ("6 个字母 1 个过半 → 行", [0, 0.51, 0.3, 0, 0, 0], 0.25, true),
            ("7 个字母 2 个过半 → 行", [0, 0, 0.51, 0.51, 0.1, 0, 0], 0.25, true),
            ("7 个字母 3 个过半 → 不行", [0, 0.51, 0.51, 0.51, 0, 0, 0], 0.33, false),
        ]
        for (name, c, limit, pass) in rules {
            let o = occ(c)
            let why = CollageCover.failure(o, limit: limit)
            check((why == nil) == pass, name, String(format: "总 %.3f 首 %.2f 末 %.2f 过半 %d", o.total, o.first, o.last,
                                                      o.heavy) + (why.map { " · " + $0 } ?? ""))
        }
        // 装饰大字（只限总量）：首末字母、过半的字母不管，总量和 33% 照旧。
        let decorative: [(String, [Double], Double, Bool)] = [
            ("装饰大字：首字母 45%、总量 17.5% → 行", [0.45, 0.2, 0.05, 0], 0.25, true),
            ("装饰大字：6 个字母 2 个过半、总量 20% → 行", [0, 0.6, 0.6, 0, 0, 0], 0.25, true),
            ("装饰大字：总量 26%（上限 25%）→ 不行", [0.5, 0.54, 0, 0], 0.25, false),
            ("装饰大字：总量 34%（上限调到 33%）→ 不行", [0.7, 0.66, 0, 0], 0.33, false),
        ]
        for (name, c, limit, pass) in decorative {
            let o = occ(c)
            let why = CollageCover.failure(o, limit: limit, rule: .total)
            check((why == nil) == pass, name, String(format: "总 %.3f 首 %.2f 末 %.2f 过半 %d", o.total, o.first, o.last,
                                                      o.heavy) + (why.map { " · " + $0 } ?? ""))
        }
        // 原因里的数字：取整以后和上限一样时多给一位小数（「末字母被挡 15.4%（上限 15%）」，不是「15%」对「15%」）。
        let close = CollageCover.failure(occ([0, 0, 0, 0, 0, 0.154]), limit: 0.25) ?? ""
        check(close.contains("15.4%"), "原因里贴着上限的量多给一位小数", close)
        // 刊头带着的小字行（期号日期）：主行以外每行单独限 15%；装饰大字只管小字行（Fixes round 3）。
        let lineRules: [(String, [Double], [Bool], CollageOcclusionRule, Bool)] = [
            ("刊头 10%、日期小字行 72% → 不行", [0.1, 0.72], [false, true], .masthead, false),
            ("刊头 10%、日期小字行 12% → 行", [0.1, 0.12], [false, true], .masthead, true),
            ("刊名规矩：第 2 行和刊头一样大、被挡 40% → 不行", [0.1, 0.4], [false, false], .masthead, false),
            ("装饰大字：小字行 40% → 不行", [0.1, 0.4], [false, true], .total, false),
            ("装饰大字：第 2 行一样大、被挡 40%（只算总量）→ 行", [0.1, 0.4], [false, false], .total, true),
        ]
        for (name, lines, small, rule, pass) in lineRules {
            var o = occ([0, 0.1, 0.2, 0.2, 0.1, 0])
            o.perLine = lines
            o.mainLine = 0
            o.smallLines = small
            let why = CollageCover.failure(o, limit: 0.25, rule: rule)
            let named = why.map { $0.contains("第 2 行") } ?? true
            check((why == nil) == pass && named, name, why ?? "")
        }

        // ---------------------------------------------------------------- 2b. 合成场景走一遍 CollageCover
        print("== 退让（合成照片 + 合成蒙版，不是真照片）")
        var canvas = CollageCanvas.social[0]
        canvas.safe = 0
        var project = CollageProject()
        project.canvas = canvas
        project.style.margin = 0
        project.style.gutter = 0
        project.style.shadow = 0
        project.style.border = .none
        let frameRect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        func masthead(_ word: String = "ATELIER") -> CollageOverlay {
            var line = CollageTextLine(word, font: .didot, weight: .bold, size: 0.2, color: .white)
            line.fitWidth = true
            var o = CollageOverlay(text: CollageText(lines: [line], vertical: false, alignH: .center, alignV: .leading))
            o.anchor = .top
            o.inset = 0.02
            o.maxWidth = 0.96
            o.shadow = 0
            o.tone = .light
            o.layer = .behindSubject
            return o
        }
        // 合成照片：竖 2:3、默认 4000×6000（不放大），蒙版 682×1024。
        func photo(_ name: String, faces: [[Double]], size: [Int] = [4000, 6000]) -> CollagePhotoRef {
            var p = CollagePhotoRef(id: "synthetic-\(name)", path: "/nonexistent/synthetic-\(name).jpg", width: size[0],
                                    height: size[1])
            p.faces = faces
            return p
        }
        let mw = 682
        let mh = 1024
        /// 画一张合成蒙版：椭圆（头、帽子）、矩形（身体、举起的手、墙）。
        func paint(_ shapes: [(kind: String, rect: [Double])]) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: mw * mh)
            for y in 0..<mh {
                for x in 0..<mw {
                    let u = (Double(x) + 0.5) / Double(mw)
                    let v = (Double(y) + 0.5) / Double(mh)
                    for s in shapes {
                        let r = s.rect
                        var inside = false
                        if s.kind == "ellipse" {
                            let cx = (r[0] + r[2]) / 2
                            let cy = (r[1] + r[3]) / 2
                            let rx = (r[2] - r[0]) / 2
                            let ry = (r[3] - r[1]) / 2
                            let dx = (u - cx) / rx
                            let dy = (v - cy) / ry
                            inside = dx * dx + dy * dy <= 1
                        } else {
                            inside = u >= r[0] && u <= r[2] && v >= r[1] && v <= r[3]
                        }
                        if inside {
                            px[y * mw + x] = 255
                            break
                        }
                    }
                }
            }
            return px
        }
        struct Scene {
            var name: String
            var faces: [[Double]]
            var shapes: [(kind: String, rect: [Double])]?
            var framing: CollageFraming
            var expect: CollageCover.Step
            var expectLayer: CollageTextLayer
            var reasonHas: String?
            /// 照片像素（宽、高）。
            var size: [Int] = [4000, 6000]
        }
        let face = [0.42, 0.30, 0.58, 0.40]
        let head: (kind: String, rect: [Double]) = ("ellipse", [0.43, 0.26, 0.57, 0.41])
        let body: (kind: String, rect: [Double]) = ("rect", [0.36, 0.40, 0.64, 1.0])
        let scenes: [Scene] = [
            Scene(name: "单人正常", faces: [face], shapes: [head, body], framing: .cover, expect: .behind,
                  expectLayer: .behindSubject),
            Scene(name: "右边举着一根杆子（压末字母）→ 横向挪", faces: [face],
                  shapes: [head, body, ("rect", [0.79, 0.0, 0.83, 0.45])], framing: .cover, expect: .shifted,
                  expectLayer: .behindSubject, reasonHas: "挪"),
            Scene(name: "大帽子（中间几个字母全没了）→ 拉远", faces: [face],
                  shapes: [("ellipse", [0.30, 0.22, 0.70, 0.36]), head, body], framing: .cover, expect: .pulledBack,
                  expectLayer: .behindSubject, reasonHas: "拉远"),
            Scene(name: "全身取景、头太高（人顶在刊头里）→ 刊头缩到头顶上方", faces: [[0.42, 0.14, 0.58, 0.24]],
                  shapes: [("rect", [0.2, 0.08, 0.8, 0.25]), ("rect", [0.36, 0.24, 0.64, 1.0])], framing: .full,
                  expect: .shrunk, expectLayer: .behindSubject, reasonHas: "缩小"),
            Scene(name: "主体从照片顶上就开始、占满整宽 → 退回人前", faces: [face],
                  shapes: [("rect", [0.0, 0.0, 1.0, 1.0])], framing: .cover, expect: .front, expectLayer: .front,
                  reasonHas: "人物前面"),
            Scene(name: "合影 3 张脸 → 退回人前", faces: [face, [0.15, 0.32, 0.29, 0.41], [0.71, 0.31, 0.85, 0.40]],
                  shapes: [head, body], framing: .cover, expect: .front, expectLayer: .front, reasonHas: "合影"),
            Scene(name: "认不出主体 → 退回人前", faces: [face], shapes: nil, framing: .cover, expect: .front,
                  expectLayer: .front, reasonHas: "认不出主体"),
            // 682×1024 的小图放进 1440×1920：最大窗口都放大 2 倍多，拉近不了，头低、到不了刊头 —— 规则都满足（0%），
            // 但得说清为什么没挡（Fixes round 2）。
            Scene(name: "照片像素不够、头低 → 照原样在人后、说明头顶到不了刊头", faces: [[0.42, 0.52, 0.58, 0.62]],
                  shapes: [("ellipse", [0.43, 0.47, 0.57, 0.63]), ("rect", [0.36, 0.62, 0.64, 1.0])], framing: .cover,
                  expect: .behind, expectLayer: .behindSubject, reasonHas: "像素不够", size: [682, 1024]),
        ]
        for scene in scenes {
            let p = photo(scene.name, faces: scene.faces, size: scene.size)
            if let shapes = scene.shapes {
                CollageMasks.inject(CollageMasks.synthetic(paint(shapes), width: mw, height: mh, faces: scene.faces), for: p)
            } else {
                CollageMasks.inject(nil, for: p)
            }
            var cell = CollageCell.photo(p.id)
            cell.framing = scene.framing
            cell.overlay = masthead()
            var proj = project
            proj.photos = [p]
            CollageCover.purge()
            guard let r = CollageCover.resolve(cell: cell, frameRect: frameRect, project: proj, photo: p,
                                               framing: scene.framing, hints: nil, vars: [:], background: .white),
                  let block = r.blocks.first ?? nil else {
                check(false, scene.name, "没有决定")
                continue
            }
            let o = block.occlusion
            let detail = String(format: "→ %@/%@ 总 %.1f%% 首 %.1f%% 末 %.1f%% 过半 %d/%d 取景 %.3f,%.3f %.3fx%.3f",
                                block.layer.rawValue, block.step.rawValue, (o?.total ?? 0) * 100, (o?.first ?? 0) * 100,
                                (o?.last ?? 0) * 100, o?.heavy ?? 0, o?.letters ?? 0, r.window.x, r.window.y,
                                r.window.w, r.window.h) + (block.reason.map { " · " + $0 } ?? "")
            let reasonOK = scene.reasonHas.map { block.reason?.contains($0) ?? false } ?? (block.reason == nil)
            check(block.step == scene.expect && block.layer == scene.expectLayer && reasonOK, scene.name, detail)
            if block.layer == .behindSubject, let o, block.step != .front {
                check(CollageCover.failure(o, limit: block.limit) == nil, scene.name + "：最后的遮挡满足规则")
                check(block.eyesClear == true, scene.name + "：眼睛在蒙版里（字压不到）")
            }
            if block.layer == .front, r.faces < CollageCover.groupFaces, scene.framing == .cover {
                check(block.eyesClear == true, scene.name + "：退回人前后字不压眼睛")
            }
            if scene.expect == .behind, scene.framing == .cover, scene.size == [4000, 6000] {
                check(!block.eyeFar, scene.name + "：眼睛离刊头不远（基线下 ≤ 8%）",
                      block.eyeBelow.map { String(format: "基线下 %.1f%%", $0 * 100) } ?? "没算")
            }
            // 同一个格子按 0.5 预览、1 倍导出各渲染一次：决定不跟缩放走（决定是 1 倍几何 + 1024 蒙版）。
            var page = CollagePage(root: .leaf(cell))
            page.items = []
            var renders: [String] = []
            for scale in [0.5, 1.0] {
                var opts = CollageRender.Options(scale: scale)
                opts.includeBleed = scale == 1
                opts.export = scale == 1
                let report = CollageRender.RenderReport()
                opts.report = report
                _ = CollageRender.render(page: page, project: proj, hints: [:], options: opts)
                // 合成照片没有文件，照片画不出来（crops 没有）：比字块的层、决定、遮挡量、字块位置。
                let t = report.texts.first
                let r = t?.rect ?? .zero
                renders.append("\(t?.layer ?? "-")|\(t?.occlusion?.decision ?? "-")|"
                               + String(format: "%.4f|%.1f,%.1f,%.1f,%.1f", t?.occlusion?.total ?? -1, Double(r.minX),
                                        Double(r.minY), Double(r.width), Double(r.height)))
            }
            check(renders.count == 2 && renders[0] == renders[1], scene.name + "：0.5 预览和导出的决定一样", renders.joined(separator: " / "))
        }

        // ---------------------------------------------------------------- 2b'. 退回人前躲开头、装饰大字、出血外延
        print("== 退回人前躲开头 / 装饰大字只限总量 / 出血外延（合成照片 + 合成蒙版）")
        func bigWord(_ word: String, anchor: CollageAnchor, rule: CollageOcclusionRule) -> CollageOverlay {
            var line = CollageTextLine(word, font: .helveticaNeue, weight: .bold, size: 0.3, color: .ink)
            line.fitWidth = true
            var o = CollageOverlay(text: CollageText(lines: [line], vertical: false, alignH: .center, alignV: .leading))
            o.anchor = anchor
            o.inset = 0.02
            o.maxWidth = 0.6
            o.shadow = 0
            o.tone = .dark
            o.layer = .behindSubject
            o.occlusionRule = rule
            return o
        }
        struct Extra {
            var name: String
            var faces: [[Double]]
            var shapes: [(kind: String, rect: [Double])]
            var framing: CollageFraming
            var overlay: CollageOverlay
            var expectLayer: CollageTextLayer
            var expectMoved: Bool
            var reasonHas: String?
        }
        let midFace = [0.45, 0.42, 0.55, 0.50]
        let midHead: (kind: String, rect: [Double]) = ("ellipse", [0.44, 0.38, 0.56, 0.51])
        let midBody: (kind: String, rect: [Double]) = ("rect", [0.40, 0.50, 0.60, 1.0])
        let lowFace = [0.46, 0.60, 0.54, 0.66]
        let lowHead: (kind: String, rect: [Double]) = ("ellipse", [0.455, 0.57, 0.545, 0.665])
        let lowBody: (kind: String, rect: [Double]) = ("rect", [0.43, 0.66, 0.57, 1.0])
        let extras: [Extra] = [
            Extra(name: "近景、头顶着照片上沿（不是封面取景）→ 退回人前、刊头挪开头", faces: [[0.40, 0.10, 0.60, 0.24]],
                  shapes: [("ellipse", [0.37, 0.02, 0.63, 0.25]), ("rect", [0.28, 0.24, 0.72, 1.0])], framing: .close,
                  overlay: masthead(), expectLayer: .front, expectMoved: true, reasonHas: "挪到不压脸"),
            Extra(name: "巨型数字在人后、人站正中（刊名规矩）→ 退回人前、挪开头", faces: [midFace],
                  shapes: [midHead, midBody], framing: .full, overlay: bigWord("12", anchor: .center, rule: .masthead),
                  expectLayer: .front, expectMoved: true, reasonHas: "挪到不压脸"),
            Extra(name: "巨型数字在人后、人站正中（装饰大字只限总量）→ 照原样在人后", faces: [midFace],
                  shapes: [midHead, midBody], framing: .full, overlay: bigWord("12", anchor: .center, rule: .total),
                  expectLayer: .behindSubject, expectMoved: false, reasonHas: nil),
            // 开关看着没反应的两种（Fixes round 3）：得说清为什么挡不到、怎么改。
            // 人小、站在照片下半截（全身取景，头顶在格子一半往下）。
            Extra(name: "自动位置的刊头在人后、人在下半截 → 照原样在人后、说清自动位置挡不到", faces: [lowFace],
                  shapes: [lowHead, lowBody], framing: .full,
                  overlay: { var o = masthead(); o.anchor = .auto; return o }(),
                  expectLayer: .behindSubject, expectMoved: false, reasonHas: "自动位置的字会躲开人"),
            Extra(name: "全身取景、刊头定在上方、人在下半截 → 照原样在人后、说清不是封面取景", faces: [lowFace],
                  shapes: [lowHead, lowBody], framing: .full, overlay: masthead(),
                  expectLayer: .behindSubject, expectMoved: false, reasonHas: "不是封面取景，头顶到不了刊头"),
        ]
        for scene in extras {
            let p = photo(scene.name, faces: scene.faces)
            CollageMasks.inject(CollageMasks.synthetic(paint(scene.shapes), width: mw, height: mh, faces: scene.faces),
                                for: p)
            var cell = CollageCell.photo(p.id)
            cell.framing = scene.framing
            cell.overlay = scene.overlay
            var proj = project
            proj.photos = [p]
            CollageCover.purge()
            guard let r = CollageCover.resolve(cell: cell, frameRect: frameRect, project: proj, photo: p,
                                               framing: scene.framing, hints: nil, vars: [:], background: .white),
                  let block = r.blocks.first ?? nil else {
                check(false, scene.name, "没有决定")
                continue
            }
            let o = block.occlusion
            let detail = String(format: "→ %@/%@%@ 总 %.1f%% 首 %.1f%% 末 %.1f%% 过半 %d/%d", block.layer.rawValue,
                                block.step.rawValue, block.moved ? "·挪开头" : "", (o?.total ?? 0) * 100,
                                (o?.first ?? 0) * 100, (o?.last ?? 0) * 100, o?.heavy ?? 0, o?.letters ?? 0)
                + (block.reason.map { " · " + $0 } ?? "")
            let reasonOK = scene.reasonHas.map { block.reason?.contains($0) ?? false } ?? (block.reason == nil)
            check(block.layer == scene.expectLayer && block.moved == scene.expectMoved && reasonOK, scene.name, detail)
            // 不是封面取景的格子没挪过取景、没拉远过：原因里别这么说（Fixes round 2）。
            if scene.framing != .cover, block.step == .front {
                let claims = block.reason?.contains("挪取景、拉远") ?? false
                check(!claims, scene.name + "：原因只说试过的（不说挪取景、拉远）", block.reason ?? "")
            }
            // 渲染器摆出来的位置（CollageRender.overlayPlacements 问的是同一个决定）：字形碰不到头。
            let placed = CollageRender.overlayPlacements(cell: cell, frameRect: frameRect, project: proj, photo: p,
                                                         framing: scene.framing, hints: nil, vars: [:], background: .white)
            if scene.expectLayer == .front, let f = scene.faces.first, let q = placed.first ?? nil {
                let top = min(f[1], r.headTop ?? f[1])
                let head = CollageCrop.project([f[0], top, f[2], f[3]], window: r.window, into: frameRect)
                let glyphs = CollageTypeset.glyphOutlines(q.text, in: q.rect, short: q.short, vars: [:])
                let hit = head.map { h in glyphs.contains { $0.bounds.intersects(h) } } ?? false
                check(!hit && block.eyesClear == true, scene.name + "：人前的字不压头、不压眼睛",
                      String(format: "字块 %.0f,%.0f %.0fx%.0f", Double(q.rect.minX), Double(q.rect.minY),
                             Double(q.rect.width), Double(q.rect.height)))
            }
        }
        // 刊头带一行期号日期小字、封面取景把头压在小字上：小字行单独限 15%，退让，原因说「第 2 行」（Fixes round 3）。
        do {
            let p = photo("dateline", faces: [face])
            CollageMasks.inject(CollageMasks.synthetic(paint([head, body]), width: mw, height: mh, faces: [face]), for: p)
            var o = masthead()
            o.text.lines.append(CollageTextLine("MARCH · 2026 · NO.01", font: .didot, weight: .regular, size: 0.016,
                                                tracking: 0.45, color: .white))
            o.text.lineSpacing = 0.5
            var cell = CollageCell.photo(p.id)
            cell.framing = .cover
            cell.overlay = o
            var proj = project
            proj.photos = [p]
            CollageCover.purge()
            let r = CollageCover.resolve(cell: cell, frameRect: frameRect, project: proj, photo: p, framing: .cover,
                                         hints: nil, vars: [:], background: .white)
            if let r, let block = r.blocks.first ?? nil, let oc = block.occlusion {
                let lines = oc.perLine.map { String(format: "%.0f", $0 * 100) }.joined(separator: " ")
                let detail = "→ \(block.layer.rawValue)/\(block.step.rawValue) 每行 [\(lines)]" + (block.reason.map { " · " + $0 } ?? "")
                check(block.reason?.contains("第 2 行") ?? false, "刊头带日期小字、头压在小字上 → 退让、原因说第 2 行", detail)
                if block.layer == .behindSubject {
                    check(CollageCover.failure(oc, limit: block.limit) == nil && (oc.perLine.last ?? 1) <= CollageCover.lineMax,
                          "刊头带日期小字：退让以后小字行 ≤ 15%", detail)
                } else {
                    check(block.eyesClear == true, "刊头带日期小字：退回人前后字不压眼睛", detail)
                }
            } else {
                check(false, "刊头带日期小字、头压在小字上 → 退让、原因说第 2 行", "没有决定")
            }
        }
        // 横图放进 3:4 封面、人在照片下半截：窗口被照片下沿卡住，眼睛离刊头远 —— 记 eyeFar、原因说一句（Fixes round 3）。
        do {
            let f = [0.45, 0.50, 0.55, 0.66]
            let p = photo("eye-far", faces: [f], size: [6000, 4000])
            CollageMasks.inject(CollageMasks.synthetic(paint([("ellipse", [0.44, 0.45, 0.56, 0.67]),
                                                              ("rect", [0.38, 0.66, 0.62, 1.0])]),
                                                       width: mw, height: mh, faces: [f]), for: p)
            var cell = CollageCell.photo(p.id)
            cell.framing = .cover
            cell.overlay = masthead()
            var proj = project
            proj.photos = [p]
            CollageCover.purge()
            let r = CollageCover.resolve(cell: cell, frameRect: frameRect, project: proj, photo: p, framing: .cover,
                                         hints: nil, vars: [:], background: .white)
            let block = r?.blocks.first ?? nil
            let w = r?.window
            let detail = String(format: "取景 %.3f,%.3f %.3fx%.3f · 眼睛在基线下 %.1f%%", w?.x ?? 0, w?.y ?? 0, w?.w ?? 0,
                                w?.h ?? 0, (block?.eyeBelow ?? 0) * 100) + (block?.reason.map { " · " + $0 } ?? "")
            check(block?.eyeFar == true && (block?.reason?.contains("照片下沿") ?? false),
                  "横图封面、窗口卡在照片下沿 → 记下眼睛离刊头远、说原因", detail)
        }
        // 合影的封面取景（Fixes final）：旁边那个人也留在窗口里（同 CollageCrop.window 的安全区），切脸照实记；
        // 装不下所有人时只管主脸（头仍在刊头下面），记切脸。3 张脸退回人前的那个取景同样。
        do {
            struct Group {
                var name: String
                var faces: [[Double]]
                var shapes: [(kind: String, rect: [Double])]
                /// 所有人都装得下（否则只要求主脸在、记切脸）。
                var fits: Bool
                /// 照片像素（宽、高）。
                var size: [Int] = [4000, 6000]
                /// 只按主脸居中（改之前的取法）同样宽的窗口会切到旁边那个人：这个场景真考到了「装得下就收紧」。
                var centredCuts = false
            }
            let groups: [Group] = [
                Group(name: "两个人、主脸偏左、旁边那个在右边 → 两张脸都在窗口里、不记切脸",
                      faces: [[0.20, 0.30, 0.36, 0.40], [0.84, 0.46, 0.94, 0.54]],
                      shapes: [("ellipse", [0.21, 0.26, 0.35, 0.41]), ("rect", [0.15, 0.40, 0.41, 1.0]),
                               ("ellipse", [0.845, 0.43, 0.935, 0.55]), ("rect", [0.82, 0.54, 0.96, 1.0])],
                      fits: true, centredCuts: true),
                // 横图放进 3:4：窗口最宽只有照片宽的一半，两个人隔得比这还远，怎么拉远都装不下。
                Group(name: "横图、两个人隔得比最宽的窗口还远 → 主脸在窗口里、记切脸",
                      faces: [[0.30, 0.30, 0.38, 0.42], [0.86, 0.32, 0.94, 0.44]],
                      shapes: [("ellipse", [0.305, 0.26, 0.375, 0.43]), ("rect", [0.27, 0.42, 0.41, 1.0]),
                               ("ellipse", [0.865, 0.28, 0.935, 0.45]), ("rect", [0.83, 0.44, 0.97, 1.0])],
                      fits: false, size: [6000, 4000]),
                Group(name: "合影 3 张脸（退回人前的取景）→ 三张脸都在窗口里、不记切脸",
                      faces: [face, [0.15, 0.32, 0.29, 0.41], [0.71, 0.31, 0.85, 0.40]],
                      shapes: [head, body], fits: true),
            ]
            for g in groups {
                let p = photo("group-\(g.name)", faces: g.faces, size: g.size)
                CollageMasks.inject(CollageMasks.synthetic(paint(g.shapes), width: mw, height: mh, faces: g.faces), for: p)
                var cell = CollageCell.photo(p.id)
                cell.framing = .cover
                cell.overlay = masthead()
                var proj = project
                proj.photos = [p]
                CollageCover.purge()
                guard let r = CollageCover.resolve(cell: cell, frameRect: frameRect, project: proj, photo: p,
                                                   framing: .cover, hints: nil, vars: [:], background: .white) else {
                    check(false, g.name, "没有决定")
                    continue
                }
                let w = r.window
                let slack = w.rect.insetBy(dx: -1e-6, dy: -1e-6)
                let boxes = g.faces.map { CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]) }
                let allIn = boxes.allSatisfy { slack.contains($0) }
                let primaryIn = boxes.first.map { slack.contains($0) } ?? false
                // 同样宽、只按主脸居中的窗口（照片里夹紧）。
                let fc: Double = (g.faces[0][0] + g.faces[0][2]) / 2
                let cx: Double = min(max(0, fc - w.w / 2), max(0, 1 - w.w))
                let centred = CGRect(x: cx, y: w.y, width: w.w, height: w.h).insetBy(dx: -1e-6, dy: -1e-6)
                let centredAllIn = boxes.allSatisfy { centred.contains($0) }
                let block = r.blocks.first ?? nil
                let detail = String(format: "取景 %.3f,%.3f %.3fx%.3f（只按主脸居中 %.3f）", w.x, w.y, w.w, w.h, cx)
                    + (w.cutsFace ? " 切脸" : "") + (block.map { " → \($0.layer.rawValue)/\($0.step.rawValue)" } ?? "")
                    + (block?.reason.map { " · " + $0 } ?? "")
                if g.fits {
                    check(allIn && !w.cutsFace && (!g.centredCuts || !centredAllIn), g.name, detail)
                } else {
                    check(primaryIn && !allIn && w.cutsFace, g.name, detail)
                }
            }
        }
        // 零边距印刷（A4 带 3mm 出血）：封面取景、照常取景都把导出的出血外延留在照片里（导出不用整块平移）。
        do {
            var a4 = CollageCanvas.social[7]
            a4.safe = 0
            var proj = project
            proj.canvas = a4
            let frame = CGRect(x: 0, y: 0, width: a4.width, height: a4.height)
            let cases: [(String, [Double], CollageFraming)] = [
                ("封面取景、脸在正中", face, .cover),
                ("封面取景、脸贴着照片左边", [0.02, 0.30, 0.18, 0.40], .cover),
                ("全身取景、刊头在人后", face, .full),
            ]
            for (name, f, framing) in cases {
                let p = photo("bleed-\(name)", faces: [f])
                let h0: Double = f[1] - 0.04
                let shapes: [(kind: String, rect: [Double])] = [("ellipse", [f[0] - 0.01, h0, f[2] + 0.01, f[3] + 0.01]),
                                                                ("rect", [f[0] - 0.06, f[3], f[2] + 0.06, 1.0])]
                CollageMasks.inject(CollageMasks.synthetic(paint(shapes), width: mw, height: mh, faces: [f]), for: p)
                var cell = CollageCell.photo(p.id)
                cell.framing = framing
                cell.overlay = masthead()
                proj.photos = [p]
                CollageCover.purge()
                let rv = CollageRender.bleedReserve(cell: cell, frameRect: frame, project: proj)
                guard let r = CollageCover.resolve(cell: cell, frameRect: frame, project: proj, photo: p, framing: framing,
                                                   hints: nil, vars: [:], background: .white) else {
                    check(false, "A4 零边距：" + name, "没有决定")
                    continue
                }
                let w = r.window
                let right: Double = w.x + w.w * (1 + rv.right)
                let bottom: Double = w.y + w.h * (1 + rv.bottom)
                let fits = w.x >= rv.left * w.w - 1e-9 && w.y >= rv.top * w.h - 1e-9 && right <= 1 + 1e-9
                    && bottom <= 1 + 1e-9
                check(!rv.isEmpty && fits, "A4 零边距：" + name + "：取景连同出血外延都在照片里",
                      String(format: "取景 %.4f,%.4f %.4fx%.4f · 外延 左 %.4f 上 %.4f 右 %.4f 下 %.4f", w.x, w.y, w.w, w.h,
                             rv.left, rv.top, rv.right, rv.bottom))
            }
        }

        // ---------------------------------------------------------------- 2c. 字形 × 蒙版的量法
        print("== 字形 × 蒙版（合成）")
        do {
            let p = photo("measure", faces: [face])
            let o = masthead("HOLM")
            guard let placed = CollageOverlays.place(o, area: frameRect, drawn: frameRect, canvas: canvas, photo: p,
                                                     window: CollageCrop.Window.whole, hints: nil, vars: [:],
                                                     background: .white) else {
                check(false, "刊头摆不下")
                exit(1)
            }
            let L = CollageCover.letters(placed, vars: [:], drawn: frameRect, clip: nil)
            check(L.main.count == 4, "HOLM 拆成 4 个字母", "\(L.main.count) 个")
            // 蒙版正好盖住第 2 个字母的外框（照片窗口 = 整张、照片铺满格子：照片坐标 = 成品坐标 / 宽高）。
            let glyphs = CollageTypeset.glyphOutlines(placed.text, in: placed.rect, short: placed.short, vars: [:])
            if glyphs.count == 4 {
                let b = glyphs[1].bounds
                var px = [UInt8](repeating: 0, count: mw * mh)
                let x0 = Int(Double(b.minX) / Double(canvas.width) * Double(mw)) - 2
                let x1 = Int(Double(b.maxX) / Double(canvas.width) * Double(mw)) + 2
                let y0 = Int(Double(b.minY) / Double(canvas.height) * Double(mh)) - 2
                let y1 = Int(Double(b.maxY) / Double(canvas.height) * Double(mh)) + 2
                for y in max(0, y0)..<min(mh, y1) { for x in max(0, x0)..<min(mw, x1) { px[y * mw + x] = 255 } }
                if let m = CollageMasks.synthetic(px, width: mw, height: mh, faces: []) {
                    // 照片 2:3 塞进 3:4 的格子要裁：这里直接按「照片 = 格子」量（窗口整张、drawn = 格子）。
                    let r = CollageCover.occlusion(L, window: .whole, drawn: frameRect, mask: m)
                    let others = r.perLetter.enumerated().filter { $0.offset != 1 }.map(\.element).max() ?? 1
                    check(r.perLetter.count == 4 && r.perLetter[1] > 0.97 && others < 0.03,
                          "整个盖住第 2 个字母 → 它 100%、别的 0",
                          r.perLetter.map { String(format: "%.3f", $0) }.joined(separator: " "))
                }
            }
        }

        // ---------------------------------------------------------------- 3. 字形轮廓和真画出来的墨对得上
        print("== 字形轮廓 ↔ drawFitted 的墨")
        func outlineMatch(_ name: String, _ text: CollageText) {
            let short = Double(canvas.shortSide)
            let box = CGSize(width: 1300, height: 1300)
            let source = CollageTypeset.fittingWidth(text, in: box, short: short, vars: [:])
            let fitted = CollageTypeset.fit(source, in: box, short: short, vars: [:])
            let rect = CGRect(x: 60, y: 60, width: ceil(fitted.size.width) + 1, height: ceil(fitted.size.height) + 1)
            let w = Int(rect.maxX) + 60
            let h = Int(rect.maxY) + 60
            // 真画：和渲染器一样的翻转画布。
            guard let ctx = CollageRender.makeContext(width: w, height: h) else { return }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            var white = source
            white.lines = white.lines.map { var l = $0; l.color = .white; return l }
            CollageTypeset.drawFitted(white, in: rect, ctx: ctx, short: fitted.short, vars: [:], canvasHeight: h)
            guard let drawn = ctx.makeImage(), let data = drawn.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return }
            // 轮廓：同一组参数，填进一张灰度图。
            var mask = [UInt8](repeating: 0, count: w * h)
            let glyphs = CollageTypeset.glyphOutlines(source, in: rect, short: fitted.short, vars: [:])
            mask.withUnsafeMutableBytes { buf in
                guard let g = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                        space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                g.translateBy(x: 0, y: CGFloat(h))
                g.scaleBy(x: 1, y: -1)
                g.setFillColor(CGColor(gray: 1, alpha: 1))
                for gl in glyphs { g.addPath(gl.path) }
                g.fillPath()
            }
            // 比位置不比抗锯齿：各自外扩 1 像素再看对方落进来多少（错一个字、整行偏移都会掉下去；
            // 细笔画边上的半像素灰不算）。
            let stride = drawn.bytesPerRow
            var ink = [Bool](repeating: false, count: w * h)
            var shape = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    ink[y * w + x] = base[y * stride + x * 4] > 127
                    shape[y * w + x] = mask[y * w + x] > 127
                }
            }
            func near(_ a: [Bool], _ x: Int, _ y: Int) -> Bool {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx
                        let yy = y + dy
                        if xx >= 0, yy >= 0, xx < w, yy < h, a[yy * w + xx] { return true }
                    }
                }
                return false
            }
            var inkN = 0
            var inkHit = 0
            var shapeN = 0
            var shapeHit = 0
            for y in 0..<h {
                for x in 0..<w {
                    if ink[y * w + x] {
                        inkN += 1
                        if near(shape, x, y) { inkHit += 1 }
                    }
                    if shape[y * w + x] {
                        shapeN += 1
                        if near(ink, x, y) { shapeHit += 1 }
                    }
                }
            }
            let recall = inkN > 0 ? Double(inkHit) / Double(inkN) : 0
            let precision = shapeN > 0 ? Double(shapeHit) / Double(shapeN) : 0
            let iou = min(recall, precision)
            // --dump 目录：两张图都写出来（左 = 真画的墨，右 = 轮廓）读图核对。
            if let i = args.firstIndex(of: "--dump"), args.count > i + 1 {
                let dir = URL(fileURLWithPath: args[i + 1])
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let safe = name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_")
                try? CollageExport.write(drawn, to: dir.appendingPathComponent("outline_\(safe)_ink.png"), format: .png,
                                         quality: 1, dpi: 72)
                if let m = CollageMasks.grayImage(mask, width: w, height: h) {
                    try? CollageExport.write(m, to: dir.appendingPathComponent("outline_\(safe)_path.png"), format: .png,
                                             quality: 1, dpi: 72)
                }
            }
            check(iou > 0.98, "轮廓重合：" + name, String(format: "墨落在轮廓 1px 内 %.3f · 轮廓落在墨 1px 内 %.3f · %d 个字形",
                                                         recall, precision, glyphs.count))
        }
        func line(_ s: String, _ font: CollageFont, _ size: Double, tracking: Double = 0, fit: Bool = false,
                  widthScale: Double = 1) -> CollageTextLine {
            var l = CollageTextLine(s, font: font, weight: .bold, size: size, tracking: tracking, color: .white)
            l.fitWidth = fit
            l.widthScale = widthScale
            return l
        }
        outlineMatch("横排居中铺满宽度 Didot", CollageText(lines: [line("ATELIER", .didot, 0.2, fit: true)],
                                                         alignH: .center))
        outlineMatch("加字距 + 压窄 0.88", CollageText(lines: [line("NORD", .bodoni, 0.18, tracking: 0.4, fit: true,
                                                                  widthScale: 0.88)], alignH: .center))
        var two = CollageText(lines: [line("ATELIER", .didot, 0.16), line("SPRING ISSUE · NO.12", .avenir, 0.02)],
                              alignH: .trailing)
        two.lineSpacing = 0.2
        outlineMatch("两行右对齐", two)
        outlineMatch("竖排", CollageText(lines: [line("拾光周报", .songti, 0.08), line("第十二期", .songti, 0.03)],
                                         vertical: true, alignH: .trailing))
        var rotated = CollageText(lines: [line("spring afternoon", .helveticaNeue, 0.06)])
        rotated.rotation = -90
        outlineMatch("横排转 −90°", rotated)

        print(failures.isEmpty ? "== 全部通过" : "== 失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }
}
