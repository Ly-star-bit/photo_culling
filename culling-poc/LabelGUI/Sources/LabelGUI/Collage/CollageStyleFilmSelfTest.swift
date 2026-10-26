import Foundation
import CoreGraphics
import ImageIO

/// LABELGUI_DATA_DIR=<临时> LabelGUI --film-selftest <photo_dir> [--out 目录]（先 --analyze 过；见 CollageStyleFilm）
///
/// 1. 真照片（这个文件夹的选片结果）：按卷出印样 → 每个章节一卷；卷内按拍摄先后；每一场（take）的帧连着排；
///    圈和批量页的判决对得上：有精选的场圈一张（手动的优先，再看场内名次 #1），没有精选的场不圈，废片打叉。
///    圈叉按真渲染一遍的出图记录核对（不是拿 CollageContact.marks 自己对自己）。
/// 2. 合成数据（不是真拍的：拿这个文件夹的照片复制、改 id、拍摄时间、章节、机身、判决）：三个章节、两台机身、
///    92 帧 —— 一个章节一卷、两台机身各一卷、超过 35 帧分 ROLL n/2、切口落在场与场之间、不丢帧不重帧、
///    手动精选压过自动的、废片打叉（关掉就没有）、没有批量页时用托盘。给了 --out 就把每页按 0.3 倍出图。
/// 3. 底片条挑帧（choice = best）：每场一张、在片条上立着的优先（别的场有立着的就不上躺着的）、其次精选，
///    竖着放的条挑竖片、横着放的挑横片。
/// 4. 笔色：深一点的纸上红笔看不清时圈和注记一起换白；白笔写在白相纸上只换注记；先套社交底片条再按卷出印样、
///    底片条换成印样：笔换回红笔（圈和注记一支笔）。
/// 5. 旧数据：没有 paper / choice 的印样 JSON 读成默认值，坏值退回默认。
/// 6. 模板：名字前缀、分类、全库唯一、不含旧分类名和别的新分类名、不含真实刊名 / 胶片品牌。
/// 7. 整页水印放在五个模板的九个位置上（只有字 / 每帧都圈 / 签名 + 字）：不压手写注记、不压圈叉（居中的也是：
///    注记就写在片条下面正中）；不居中的也不压片条、黑场；签名和字不互相压；上下两排的一样都不少。
/// 8. 印样：格子给定的短卷片条从上往下排、黑场只围有帧的几条再加一条空的（下面是白相纸）；6×6 的圈贴着自己那一帧；
///    片边 ISO 跟 EXIF。
/// 全过退出 0，否则 1。
enum CollageStyleFilmSelfTest {

    @MainActor
    static func run(flagIndex: Int) -> Never {
        AppRuntime.headless = true
        let args = CommandLine.arguments
        CollageCLI.requireIsolatedDataDir("--film-selftest")
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }
        let outDir: URL? = args.firstIndex(of: "--out").flatMap { i in
            args.count > i + 1 ? URL(fileURLWithPath: args[i + 1]) : nil
        }
        if let outDir { try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }

        guard args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") else {
            print("用法：LabelGUI --film-selftest <分析过的照片文件夹> [--out 目录]")
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        batch.switchSession(to: dir)
        let facts = CollageBridge.Facts(batch: batch)
        let items = batch.items
        let tray = items.filter { $0.verdict != .reject }.compactMap { CollageBridge.ref(from: $0, facts: facts) }

        // ---------------------------------------------------------------- 1. 真照片
        print("== 真照片 \(items.count) 帧（\(dir.lastPathComponent)）")
        check(!items.isEmpty, "照片文件夹分析过（拿得到照片）",
              items.isEmpty ? "0 张：先 LABELGUI_DATA_DIR=同一个目录 LabelGUI --analyze \(dir.path)" : "")
        var base = CollageProject()
        base.photos = tray
        let context = CollageKits.Context(project: base, tray: tray, batchItems: { items }, facts: facts, hints: [:],
                                          seed: 7)
        if !items.isEmpty, let project = CollageStyleFilm.roll(context) {
            let chapters = Set(items.map(\.chapter))
            let multiBody = Dictionary(grouping: items, by: \.chapter).values.contains { Set($0.map(\.body)).count > 1 }
            if !multiBody {
                let pagesWanted = chapters.count
                check(project.pages.count >= pagesWanted, "一个章节至少一页",
                      "\(chapters.count) 个章节 → \(project.pages.count) 页")
            }
            let all = project.pages.compactMap(\.contactSheet).flatMap(\.frames)
            check(Set(all) == Set(items.map(\.id)) && all.count == items.count, "全部帧都上了（含废片）、没有重复",
                  "\(all.count) / \(items.count)")
            let photos = Dictionary(project.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (n, page) in project.pages.enumerated() {
                guard let sheet = page.contactSheet else { continue }
                let refs = sheet.frames.compactMap { photos[$0] }
                check(refs.map(\.id) == CollageContact.rollOrder(refs).map(\.id), "第 \(n + 1) 页按拍摄先后排")
                // 每一场的帧连着排（一页之内）。
                var seen: [Int: Int] = [:]
                var contiguous = true
                for (i, p) in refs.enumerated() {
                    guard let t = p.take else { continue }
                    if let last = seen[t], last != i - 1 { contiguous = false }
                    seen[t] = i
                }
                check(contiguous, "第 \(n + 1) 页每一场的帧连着排")
                // 真渲染一遍（导出同款的出图记录）：圈叉和判决对。
                let record = renderRecord(page, project: project, scale: 0.25)
                let marks = Dictionary((record?.frames ?? []).map { ($0.photoID, $0.mark) }, uniquingKeysWith: { a, _ in a })
                let byTake = Dictionary(grouping: items.filter { sheet.frames.contains($0.id) }, by: \.take)
                for take in byTake.keys.sorted() {
                    let members = byTake[take] ?? []
                    let picks = members.filter { $0.verdict == .pick }
                    let circled = members.filter { marks[$0.id] == "circle" }.map(\.id)
                    if picks.isEmpty {
                        check(circled.isEmpty, "场 \(take) 没有精选，不圈", circled.joined(separator: " "))
                    } else {
                        let manual = picks.filter { facts.manual.contains($0.id) }
                        let ranked = (manual.isEmpty ? picks : manual).sorted { a, b in
                            (facts.takeRank[a.id] ?? 99, a.id) < (facts.takeRank[b.id] ?? 99, b.id)
                        }
                        let expected = ranked.first?.id ?? ""
                        check(circled == [expected], "场 \(take) 圈的是这一场的精选 \(expected)",
                              "圈了 " + (circled.isEmpty ? "—" : circled.joined(separator: " ")))
                    }
                    for r in members where r.verdict == .reject {
                        check(marks[r.id] == "cross", "废片 \(r.id) 打叉")
                    }
                }
                let ids = sheet.frames.compactMap { id in items.first { $0.id == id } }
                let summary = ids.map { "\($0.id.suffix(4))=\(marks[$0.id].flatMap { $0 } ?? "·")" }.joined(separator: " ")
                print("    第 \(n + 1) 页 ROLL \(sheet.roll ?? 0) · \(sheet.frames.count) 帧 · \(summary)")
                if let outDir, let image = renderImage(page, project: project, scale: 0.3) {
                    try? CollageExport.write(image, to: outDir.appendingPathComponent("real_\(n + 1).png"), format: .png,
                                             quality: 1, dpi: 72)
                }
            }
        } else if !items.isEmpty {
            check(false, "按卷出印样返回了工程")
        }

        // ---------------------------------------------------------------- 2. 合成数据
        print("== 合成数据（复制这个文件夹的照片，改 id / 时间 / 章节 / 机身 / 判决；不是真拍的）")
        let synth = synthesize(tray)
        check(synth.count >= 80, "合成了 \(synth.count) 帧")
        if !synth.isEmpty {
            let rolls = CollageStyleFilm.rolls(synth)
            let numbers = rolls.map(\.number)
            print("    " + rolls.map { "ROLL \($0.number) \($0.part)/\($0.parts) \($0.format.label) \($0.frames.count) 帧" }
                .joined(separator: " · "))
            // 章节 10：63 帧一台机身 → 一卷两页；章节 11：两台机身 → 两卷；章节 12：8 帧 → 一卷。
            let ch10 = rolls.filter { $0.frames.first?.chapter == 10 }
            let ch11 = rolls.filter { $0.frames.first?.chapter == 11 }
            let ch12 = rolls.filter { $0.frames.first?.chapter == 12 }
            check(ch10.count == 2 && Set(ch10.map(\.number)).count == 1 && ch10.map(\.parts) == [2, 2]
                    && ch10.map(\.part) == [1, 2],
                  "63 帧的章节分成 ROLL n/2 两页（同一个卷号）", ch10.map { "\($0.part)/\($0.parts) \($0.frames.count) 帧" }
                    .joined(separator: " "))
            check(ch11.count == 2 && Set(ch11.map(\.number)).count == 2
                    && ch11.allSatisfy { Set($0.frames.map { $0.body ?? "" }).count == 1 },
                  "两台机身的章节每台一卷", ch11.map { "ROLL \($0.number) \($0.frames.count) 帧" }.joined(separator: " "))
            check(ch12.count == 1 && ch12.first?.parts == 1, "8 帧的章节一卷一页")
            check(numbers == numbers.sorted() && Set(numbers).count == 4, "卷号按开拍时间 1…4",
                  numbers.map(String.init).joined(separator: ","))
            check(rolls.allSatisfy { $0.frames.count <= 35 }, "每页最多 35 帧")
            let flat = rolls.flatMap(\.frames).map(\.id)
            check(flat.count == synth.count && Set(flat) == Set(synth.map(\.id)), "不丢帧、不重帧",
                  "\(flat.count) / \(synth.count)")
            // 切口落在场与场之间（最后两条里有分界的话）。
            if ch10.count == 2, let last = ch10[0].frames.last, let next = ch10[1].frames.first {
                check(CollageContact.takeKey(last) != CollageContact.takeKey(next), "分页的切口在两场之间",
                      "第一页 \(ch10[0].frames.count) 帧，切在 \(last.id) | \(next.id)")
            }
            // 每页的圈叉：真渲染一遍。
            var project = CollageProject()
            project.photos = synth
            project.canvas = CollageCanvas.social.first { $0.isPrint } ?? project.canvas
            let pages = rolls.map { CollageStyleFilm.page($0, inherit: nil) }
            project.pages = pages
            let byID = Dictionary(synth.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var circlesOK = true
            var crossesOK = true
            var notes: [String] = []
            for (i, page) in pages.enumerated() {
                guard let sheet = page.contactSheet, let record = renderRecord(page, project: project, scale: 0.2) else {
                    circlesOK = false
                    continue
                }
                notes.append(record.note ?? "")
                let marks = Dictionary(record.frames.map { ($0.photoID, $0.mark) }, uniquingKeysWith: { a, _ in a })
                let refs = sheet.frames.compactMap { byID[$0] }
                for (_, members) in Dictionary(grouping: refs, by: { CollageContact.takeKey($0) }) {
                    let picks = members.filter { $0.verdict == .pick }
                    let circled = members.filter { marks[$0.id] == "circle" }
                    if picks.isEmpty {
                        if !circled.isEmpty { circlesOK = false }
                    } else {
                        let manual = picks.filter(\.isManual)
                        let pool = manual.isEmpty ? picks : manual
                        let best = pool.min { a, b in (a.takeRank ?? 99, a.id) < (b.takeRank ?? 99, b.id) }
                        if circled.map(\.id) != [best?.id ?? ""] { circlesOK = false }
                    }
                }
                for r in refs where r.verdict == .reject && marks[r.id] != "cross" { crossesOK = false }
                if let outDir, let image = renderImage(page, project: project, scale: 0.3) {
                    try? CollageExport.write(image, to: outDir.appendingPathComponent("synth_\(i + 1).png"), format: .png,
                                             quality: 1, dpi: 72)
                }
            }
            check(circlesOK, "合成：每场有精选的圈一张（手动的优先），没有精选的不圈")
            check(crossesOK, "合成：废片打叉")
            check(notes.contains { $0.contains("1/2") } && notes.contains { $0.contains("2/2") }, "注记写着 1/2、2/2",
                  notes.filter { $0.contains("/") }.joined(separator: " | "))
            let manualPick = synth.first { $0.isManual && $0.verdict == .pick }
            if let manualPick, let pageWith = pages.first(where: { $0.contactSheet?.frames.contains(manualPick.id) == true }),
               let record = renderRecord(pageWith, project: project, scale: 0.2) {
                let mark = record.frames.first { $0.photoID == manualPick.id }?.mark
                check(mark == "circle", "合成：手动精选 \(manualPick.id) 压过同一场的自动精选", mark ?? "没圈")
            }
            // 关掉打叉。
            if let rejectPage = pages.first(where: { p in p.contactSheet?.frames.contains { byID[$0]?.verdict == .reject } == true }) {
                var off = rejectPage
                off.contactSheet?.crossRejects = false
                let record = renderRecord(off, project: project, scale: 0.2)
                check(record?.frames.contains { $0.mark == "cross" } == false, "合成：关掉「废片打叉」就没有叉")
            }
            // 没有批量页（外部文件）：托盘就是这一卷。
            var noBatch = CollageProject()
            noBatch.photos = synth
            let ctx = CollageKits.Context(project: noBatch, tray: synth, batchItems: { [] }, facts: CollageBridge.Facts(),
                                          hints: [:], seed: 1)
            let fromTray = CollageStyleFilm.roll(ctx)
            check(fromTray?.pages.count == rolls.count && fromTray?.mode == .single, "没有批量页时按托盘出卷",
                  "\(fromTray?.pages.count ?? 0) 页")
            // 当前工程里有印样设置：再出一次照着来（这里关掉打叉、换绿笔：绿笔在白相纸上看得清，照用）。
            func kit(after pages: [CollagePage]) -> [CollageContactSheet] {
                var p = noBatch
                p.pages = pages
                let out = CollageStyleFilm.roll(CollageKits.Context(project: p, tray: synth, batchItems: { [] },
                                                                    facts: CollageBridge.Facts(), hints: [:], seed: 1))
                return out?.pages.compactMap(\.contactSheet) ?? []
            }
            func sheetPage(_ sheet: CollageContactSheet) -> CollagePage {
                var page = CollagePage(root: .leaf(CollageCell()))
                page.contactSheet = sheet
                return page
            }
            var old = CollageContactSheet(format: .f135)
            old.crossRejects = false
            old.markColor = CollagePencilMark.green
            let sheets = kit(after: [sheetPage(old)])
            check(!sheets.isEmpty && sheets.allSatisfy { !$0.crossRejects && $0.markColor == CollagePencilMark.green },
                  "再出一次照着当前印样的设置（关掉打叉、绿笔）")
            // 白笔的印样：白相纸上白笔要换墨色写注记（两支笔）—— 换回红笔，开关照旧跟着。
            old.markColor = CollagePencilMark.white
            let whiteKit = kit(after: [sheetPage(old)])
            check(!whiteKit.isEmpty && whiteKit.allSatisfy { !$0.crossRejects && $0.markColor == CollagePencilMark.red },
                  "照着白笔的印样出：笔换回红笔、关掉的打叉照旧关着")
            // 先套「底片条 · 三帧」（暖黑纸、白笔）再按卷出印样：不照着底片条来，红笔、一支笔。
            if let strip = CollageStyleFilm.templates.first(where: { $0.contactSheet?.layout == .strip })?.contactSheet {
                var tried = strip
                tried.crossRejects = false
                let fromStrip = kit(after: [sheetPage(tried)])
                let white = CollageContact.defaultPaper(.sheet)
                check(!fromStrip.isEmpty && fromStrip.allSatisfy { s in
                    s.markColor == CollagePencilMark.red && s.crossRejects && s.paper == white
                        && CollageContact.onePen(s.markColor, paper: s.paper ?? white)
                }, "先套底片条再按卷出印样：红笔、圈和注记一支笔、不照着底片条的开关",
                      fromStrip.first.map { "笔 " + CollageScreening.hex($0.markColor) } ?? "没出")
                // 底片条 → 印样 → 底片条（检视器「排法」、ops）：白笔到了白相纸上换回红笔；红笔放回暖黑上照用红。
                var switched = strip
                CollageContact.switchLayout(&switched, to: .sheet)
                let toSheet = switched
                CollageContact.switchLayout(&switched, to: .strip)
                check(toSheet.paper == white && toSheet.markColor == CollagePencilMark.red
                        && switched.paper == CollageContact.defaultPaper(.strip) && switched.markColor == CollagePencilMark.red,
                      "底片条换成印样：白相纸、红笔；再换回底片条：暖黑、红笔照用")
            }
        }

        // ---------------------------------------------------------------- 3. 底片条挑帧
        print("== 底片条挑帧（choice = best）")
        if tray.count > 3 {
            var vertical = CollageContactSheet(format: .f135, layout: .strip, perStrip: 3, strips: 1)
            vertical.tilt = -90
            vertical.choice = .best
            let film = CollageContact.film(.f135)
            let picked = CollageContact.chooseBest(tray, count: 3, sheet: vertical)
            let pickCount = tray.filter { CollageContact.isPick($0) }.count
            check(picked.count == 3, "挑了 3 帧")
            check(Set(picked.map { CollageContact.takeKey($0) }).count == picked.count, "三帧来自三场")
            // 立着的优先、其次精选：有立着的帧的场够三个就三帧都立着；立着的精选所在的场先上。
            let uprightTakes = Set(tray.filter { CollageContact.standsUpright($0, film: film, sheet: vertical) }
                .map { CollageContact.takeKey($0) })
            let uprightPickTakes = Set(tray.filter { CollageContact.isPick($0) && CollageContact.standsUpright($0, film: film, sheet: vertical) }
                .map { CollageContact.takeKey($0) })
            let standing = picked.filter { CollageContact.standsUpright($0, film: film, sheet: vertical) }.count
            check(standing == min(3, uprightTakes.count), "竖着放的条：立着的优先",
                  picked.map { "\($0.id.suffix(4))\($0.isPortrait ? "竖" : "横")" }.joined(separator: " "))
            check(picked.filter { CollageContact.isPick($0) }.count >= min(3, uprightPickTakes.count), "其次精选",
                  "\(pickCount) 张精选，立着的精选在 \(uprightPickTakes.count) 场")
            // 横片为主的托盘（合成：这个文件夹的横片每张单独一场、都改成精选，+ 一张不是精选的竖片）：竖条里用上
            // 那张竖片，不让三个人都躺着（以前精选在前，三张横的精选会把它挤掉）。
            let landscapes = tray.filter { !$0.isPortrait }.enumerated().map { i, p -> CollagePhotoRef in
                var c = p
                c.take = 900 + i
                c.burstGroup = nil
                c.verdict = .pick
                c.isPick = true
                return c
            }
            if landscapes.count >= 3, let portrait = tray.first(where: { $0.isPortrait && !CollageContact.isPick($0) }) {
                let chosen = CollageContact.chooseBest(landscapes + [portrait], count: 3, sheet: vertical)
                check(chosen.contains { $0.id == portrait.id },
                      "横片精选为主的托盘（合成）：竖条里用上那张不是精选的竖片 \(portrait.id)",
                      chosen.map(\.id).joined(separator: " "))
            }
            let nonPicks = tray.filter { !CollageContact.isPick($0) }
            var flat = vertical
            flat.tilt = 0
            let takes = Dictionary(grouping: nonPicks, by: { CollageContact.takeKey($0) })
            // 同一场里横竖都有的（这个文件夹的场 7）：竖条挑竖片，横条挑横片。
            if let mixed = takes.values.first(where: { g in g.contains(where: \.isPortrait) && g.contains { !$0.isPortrait } }) {
                let v = CollageContact.chooseBest(mixed, count: 1, sheet: vertical).first
                let h = CollageContact.chooseBest(mixed, count: 1, sheet: flat).first
                check(v?.isPortrait == true && CollageContact.standsUpright(v!, film: film, sheet: vertical),
                      "竖着放的条挑竖片", v?.id ?? "—")
                check(h?.isPortrait == false && CollageContact.standsUpright(h!, film: film, sheet: flat),
                      "横着放的条挑横片", h?.id ?? "—")
            }
            let page = CollageContact.page(photos: tray, spec: vertical)
            check(page.contactSheet?.frames == CollageContact.rollOrder(picked).map(\.id), "建页：挑出来的按拍摄先后排")
            var roll = vertical
            roll.choice = .roll
            let first = CollageContact.page(photos: tray, spec: roll)
            check(first.contactSheet?.frames == CollageContact.rollOrder(tray).prefix(3).map(\.id),
                  "choice = roll 还是前 3 张（旧行为）")
        }

        // ---------------------------------------------------------------- 4. 笔色
        print("== 笔色")
        let red = CollagePencilMark.red
        let white = CollagePencilMark.white
        let grey = CollageColor(hex: 0x555555)
        let warm = CollageColor(hex: 0x2B2926)
        let sheetPaper = CollageContact.defaultPaper(.sheet)
        let g = CollageContact.pens(red, paper: grey)
        check(g.marks == white && g.note == white, "中灰纸上红笔看不清：圈和注记一起换白")
        let w = CollageContact.pens(red, paper: warm)
        check(w.marks == red && w.note == red, "暖黑底上红笔照用（圈、注记都是红）")
        let s = CollageContact.pens(white, paper: sheetPaper)
        check(s.marks == white && s.note == .ink, "白笔写在白相纸上：圈照用白（画在黑片基上），注记换墨色")
        let r = CollageContact.pens(red, paper: sheetPaper)
        check(r.marks == red && r.note == red, "白相纸上红笔照用")
        check(CollageContact.defaultPaper(.strip).luminance < 0.2 && CollageContact.suitsSheet(sheetPaper)
                && !CollageContact.suitsSheet(CollageContact.defaultPaper(.strip)),
              "印样默认白相纸、底片条默认暖黑")

        // ---------------------------------------------------------------- 5. 旧数据
        print("== 旧数据")
        let oldJSON = #"{"format":"66","layout":"strip","perStrip":3,"strips":1,"frames":["a","b"],"marks":true}"#
        let decoded = try? JSONDecoder().decode(CollageContactSheet.self, from: Data(oldJSON.utf8))
        check(decoded?.paper == nil && decoded?.choice == .roll && decoded?.format == .f66 && decoded?.frames == ["a", "b"],
              "没有 paper / choice 的旧印样读成默认（跟着底色、按拍摄先后）")
        let badJSON = #"{"format":"135","paper":"zz","choice":"nope"}"#
        let bad = try? JSONDecoder().decode(CollageContactSheet.self, from: Data(badJSON.utf8))
        check(bad != nil && bad?.paper == nil && bad?.choice == .roll, "坏的 paper / choice 退回默认")
        var round = CollageContactSheet(format: .f135, layout: .strip, perStrip: 3, strips: 1)
        round.paper = CollageColor(hex: 0x252321)
        round.choice = .best
        let encoded = try? JSONEncoder().encode(round)
        let back = encoded.flatMap { try? JSONDecoder().decode(CollageContactSheet.self, from: $0) }
        check(back == round, "paper / choice 存了读回一样")
        if let template = CollageStyleFilm.templates.first {
            let data = try? JSONEncoder().encode(template)
            let again = data.flatMap { try? JSONDecoder().decode(CollageTemplate.self, from: $0) }
            check(again?.contactSheet == template.contactSheet, "模板带的印样规格存了读回一样（含纸、挑帧）")
        }

        // ---------------------------------------------------------------- 6. 模板
        print("== 模板")
        let mine = CollageStyleFilm.templates
        check(mine.count == 5, "五个模板", mine.map(\.name).joined(separator: " / "))
        let wanted = ["底片条 · 三帧", "底片条 · 斜放", "底片条 · 方片", "印样 · 135 整卷", "印样 · 6×6"]
        check(mine.map(\.name) == wanted, "名字照 DESIGN §3 K2")
        check(mine.allSatisfy { $0.category == "底片印样" && $0.builtin && $0.contactSheet != nil }, "分类「底片印样」、都带印样规格")
        let names = CollageTemplates.builtin.map(\.name)
        check(Set(names).count == names.count, "模板名全库唯一")
        let others = ["小红书封面", "日系杂志", "中式", "九宫格", "手账散落", "电影感", "基础",
                      "时尚刊", "留白杂志", "报纸风", "瑞士网格", "婚礼相册"]
        let clash = mine.filter { t in others.contains { t.name.contains($0) || t.category.contains($0) } }
        check(clash.isEmpty, "名字、分类不含别的分类名", clash.map(\.name).joined(separator: " "))
        let banned = ["VOGUE", "ELLE", "BAZAAR", "MUSE", "GQ", "TIME", "KINFOLK", "CEREAL", "KODAK", "FUJI", "ILFORD",
                      "PORTRA", "AGFA", "TRI-X", "T-MAX", "HP5", "EKTAR", "VELVIA"]
        let texts = mine.flatMap { t -> [String] in
            [t.name, t.category, t.contactSheet?.note ?? "", t.contactSheet?.edgeText ?? "", t.contactSheet?.iso ?? ""]
        } + CollageStyleFilm.rolls(tray).map { CollageStyleFilm.page($0, inherit: nil).contactSheet?.note ?? "" }
        let hits = texts.filter { s in banned.contains { s.uppercased().contains($0) } || s.uppercased() == "W" }
        check(hits.isEmpty, "默认文字里没有真实刊名、胶片品牌", hits.joined(separator: " | "))

        // ---------------------------------------------------------------- 7. 整页水印
        print("== 整页水印躲手写注记、圈叉、片条：五个模板 × 九个位置（字 / 每帧都圈 / 签名 + 字）")
        if !tray.isEmpty {
            // 签名 + 字那一组要一张真读得出来的签名图：画一张写进隔离的资料目录（读不出来就是这一组没测，算失败）。
            let signature = makeSignature()
            check(signature.flatMap(CollageWatermarks.signatureImage) != nil, "自检用的签名图读得出来",
                  signature?.file ?? "写不出 PNG")
            var hits: [String] = []
            var onFilm: [String] = []
            var dropped: [String] = []
            var clashes: [String] = []
            var summary: [String] = []
            // 真判决的圈（photot：三帧圈的是最上面那帧）之外再来一遍「每帧都圈」：注记上面那截、两头都有笔迹时
            // 也不压（实在没地方就不画，不算失败）；再来一遍签名 + 字（同一个位置）：两样都在、谁也不压谁。
            let variants: [(label: String, circleAll: Bool, signed: Bool)] = [
                ("", false, false), ("（每帧都圈）", true, false), ("（签名 + 字）", false, true),
            ]
            for template in CollageStyleFilm.templates {
                for variant in variants {
                    guard var spec = template.contactSheet else { continue }
                    if variant.circleAll {
                        let ids = CollageContact.page(photos: tray, spec: spec).contactSheet?.frames ?? []
                        for id in ids { spec.markOverrides[id] = CollagePencilMark.circle.rawValue }
                    }
                    let (project, page) = templateProject(template, spec: spec, tray: tray)
                    let photos = Dictionary(project.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    // 和 CollageWatermarks.pagePlacement 同一份占位符（{no} 定记号的种子）。
                    let vars = CollageTypeset.variables(project: project, root: page.root, photos: photos,
                                                        pagePhotoIDs: page.photoIDs, pageID: page.id)
                    guard let sheet = page.contactSheet else { continue }
                    let avoid = CollageContact.obstacles(sheet, canvas: project.canvas, photos: photos, vars: vars)
                    let blockers = avoid.text + avoid.ink
                    let film = CollageContact.content(sheet, canvas: project.canvas, vars: vars).quads
                    let label = variant.label
                    for position in WatermarkEngine.GridPosition.allCases {
                        var wmProject = project
                        wmProject.watermark = pageWatermark(position, signature: variant.signed ? signature : nil)
                        let placed = CollageWatermarks.pagePlacement(project: wmProject, page: page)
                        let tag = "\(template.name)\(label) \(position.rawValue)"
                        if placed.contains(where: { p in blockers.contains { $0.intersects(p.rect) } }) { hits.append(tag) }
                        // 居中的本来就压在片子上（没有留白带可进），别的位置一律不压片条、黑场。
                        if position != .center,
                           placed.contains(where: { CollageWatermarks.Cover.touches($0.rect, .identity, film) }) {
                            onFilm.append(tag)
                        }
                        let boxes = placed.map(\.rect)
                        let overlapping = boxes.indices.contains { i in boxes.indices.contains { j in j > i && boxes[i].intersects(boxes[j]) } }
                        if overlapping { clashes.append(tag) }
                        // 上下两排（四个角、上下居中）：一样都不能少（每帧都圈的那组实在没地方可以不画）。
                        let kinds = Set(placed.map(\.kind))
                        let wanted: Set<String> = variant.signed ? ["signature", "text"] : ["text"]
                        if position.row != 0, !variant.circleAll, !wanted.isSubset(of: kinds) { dropped.append(tag) }
                        let centred = position == .bottomCenter || position == .topCenter
                        if centred, let r = placed.first?.rect {
                            let short = template.name.components(separatedBy: " · ").last ?? template.name
                            let rect = "[\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))]"
                            summary.append("\(short)\(label) \(position.rawValue) → \(rect)")
                        }
                    }
                    check(!blockers.isEmpty, "\(template.name)\(label)：有注记 / 圈叉可躲（\(avoid.text.count) 块字、\(avoid.ink.count) 段笔迹）")
                    // 片条、黑场的四边形是空的话「不压片条」那一条就白过了。
                    check(!film.isEmpty, "\(template.name)\(label)：有片条 / 黑场可躲（\(film.count) 块）")
                }
            }
            print("    " + summary.joined(separator: " · "))
            check(hits.isEmpty, "没有一个位置压注记、圈叉", hits.joined(separator: "；"))
            check(onFilm.isEmpty, "不居中的没有一个压片条、黑场（按转过的四边形算）", onFilm.joined(separator: "；"))
            check(clashes.isEmpty, "签名和字不互相压", clashes.joined(separator: "；"))
            check(dropped.isEmpty, "上下两排的位置一样都没被挤掉（签名 + 字两样都在）", dropped.joined(separator: "；"))
        }

        // ---------------------------------------------------------------- 8. 印样细节
        print("== 印样：短卷的黑场、6×6 的圈、片边 ISO")
        let ordered = CollageContact.rollOrder(tray)
        if let proof = CollageStyleFilm.templates.first(where: { $0.name == "印样 · 135 整卷" }),
           let spec = proof.contactSheet, ordered.count > 7 {
            // 同一个第一帧、同一个页码 = 同一个种子：7 帧和整卷的片条位置、黑场上沿应该一样（格子给定 = 按整个格子定位）；
            // 7 帧的黑场只围有帧的两条再加一条空的，比整卷的矮（以前整个格子曝光，A4 八成是黑的）。
            var short = spec
            short.frames = ordered.prefix(7).map(\.id)
            var whole = spec
            whole.frames = ordered.map(\.id)
            let canvas = templateProject(proof, spec: spec, tray: tray).0.canvas
            let a = CollageContact.layout(short, canvas: canvas, rollNo: "01")
            let b = CollageContact.layout(whole, canvas: canvas, rollNo: "01")
            func top(_ lay: CollageContact.Layout) -> CGFloat {
                guard let strip = lay.strips.first else { return -1 }
                let body = CGRect(x: 0, y: 0, width: strip.length, height: strip.height)
                return CollageContact.bbox(CollageContact.corners(body).map { $0.applying(strip.transform) }).minY
            }
            let ra = a.bounds ?? .zero
            let rb = b.bounds ?? .zero
            let dTopField: CGFloat = abs(ra.minY - rb.minY)
            let dTop: CGFloat = abs(top(a) - top(b))
            check(a.bounds != nil && dTopField < 1 && dTop < 0.5,
                  "7 帧的「印样 · 135 整卷」：片条从上往下排、黑场上沿和整卷的一样",
                  "7 帧 y \(Int(ra.minY))+\(Int(ra.height)) · 整卷 y \(Int(rb.minY))+\(Int(rb.height))")
            // 黑场下沿：盖住第 3 条（有帧的两条后面那条空的），不到第 4 条的一半（黑场比片条外沿多出 0.12 片宽，
            // 条与条之间只有 0.02 片宽的缝）。Layout.strips 只有有帧的条：空条的位置拿整卷那一份的（同一个种子、
            // 同一个格子，条的位置一样）。
            func stripBox(_ lay: CollageContact.Layout, _ i: Int) -> CGRect? {
                guard lay.strips.indices.contains(i) else { return nil }
                let strip = lay.strips[i]
                let body = CGRect(x: 0, y: 0, width: strip.length, height: strip.height)
                return CollageContact.bbox(CollageContact.corners(body).map { $0.applying(strip.transform) })
            }
            let usedStrips = (short.frames.count + max(1, a.perStrip) - 1) / max(1, a.perStrip)
            let coversEmpty = stripBox(b, usedStrips).map { ra.maxY >= $0.maxY } ?? false
            let stopsBefore = stripBox(b, usedStrips + 1).map { ra.maxY < $0.midY } ?? true
            let pageHeight = CGFloat(canvas.height)
            check(coversEmpty && stopsBefore && ra.height < rb.height,
                  "黑场只围有帧的 \(usedStrips) 条再加一条空的（下面是白相纸）",
                  String(format: "7 帧 %.0f%% · 整卷 %.0f%% 页高", Double(ra.height / pageHeight) * 100,
                         Double(rb.height / pageHeight) * 100))
            var auto = CollageContactSheet(format: .f135)
            auto.frames = short.frames
            let autoLay = CollageContact.layout(auto, canvas: canvas, rollNo: "01")
            check((autoLay.bounds?.height ?? 0) < (a.bounds?.height ?? 0), "自动排（格子跟着帧数）照旧只围有帧的那几条")
        }
        let square = CollageContact.film(.f66)
        check(CollageContact.circleScale(square) == 1.28 && CollageContact.circleScale(CollageContact.film(.f135)) == 1.4,
              "圈的外框：方画幅 1.28 倍、135 1.4 倍")
        if let sixes = CollageStyleFilm.templates.first(where: { $0.name == "印样 · 6×6" }), let spec = sixes.contactSheet {
            let (project, page) = templateProject(sixes, spec: spec, tray: tray)
            if let record = renderRecord(page, project: project, scale: 0.25) {
                let circled = record.frames.filter { $0.mark == "circle" }
                let ratios = circled.compactMap { f in f.markInk.map { Double($0.width / max(1, f.rect.width)) } }
                check(!ratios.isEmpty && ratios.allSatisfy { $0 < 1.42 }, "「印样 · 6×6」的圈贴着自己那一帧（笔迹宽 < 帧宽 1.42 倍）",
                      ratios.map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
        }
        let iso = CollageContact.rollISO(tray)
        print("    这个文件夹的 EXIF ISO：\(iso ?? "不一样 / 读不到")")
        if let first = CollageStyleFilm.templates.first?.contactSheet {
            let sheet = CollageContact.page(photos: tray, spec: first).contactSheet
            let byID = Dictionary(tray.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let onPage = (sheet?.frames ?? []).compactMap { byID[$0] }
            check(sheet?.iso == (CollageContact.rollISO(onPage) ?? "400"), "套模板：片边 ISO 跟这一页的 EXIF（都一样时）",
                  sheet?.iso ?? "—")
            var typed = first
            typed.iso = "800"
            check(CollageContact.page(photos: tray, spec: typed).contactSheet?.iso == "800", "自己填了 ISO 的照填的印")
        }
        if let roll = CollageStyleFilm.rolls(tray).first {
            let kitISO = CollageStyleFilm.page(roll, inherit: nil).contactSheet?.iso
            check(kitISO == (CollageContact.rollISO(roll.frames) ?? "400"), "按卷出印样：片边 ISO 跟这一卷的 EXIF", kitISO ?? "—")
        }
        var mixed = tray
        if mixed.count > 1 { mixed[1].path = "/nonexistent/none.jpg" }
        check(mixed.count < 2 || CollageContact.rollISO(mixed) == nil, "有一帧读不到 EXIF：不猜，照默认")

        print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - 合成数据

    /// 拿真照片复制出三个章节（不是真拍的）：
    /// - 章节 10：同一台机身，照片复制三遍（63 帧，每遍往后挪 10 分钟），第二遍的场 7 里把 DSCF7225 改成手动精选
    ///   （同一场还有自动精选 DSCF7221），第三遍的 DSCF7224 改成废片；
    /// - 章节 11：第二天，一遍（21 帧），单双号分给两台机身（场号按机身分开）；
    /// - 章节 12：第三天，前 8 帧，全改成「可用」（没有精选 = 不圈），其中一帧改成废片。
    /// 帧号重新编（8001 起）：{first}–{last} 看得出是哪一段。
    static func synthesize(_ tray: [CollagePhotoRef]) -> [CollagePhotoRef] {
        let source = CollageContact.rollOrder(tray)
        guard !source.isEmpty else { return [] }
        var out: [CollagePhotoRef] = []
        var serial = 8001
        func copy(_ p: CollagePhotoRef, tag: String, chapter: Int, shift: TimeInterval, take: Int?) -> CollagePhotoRef {
            var c = p
            c.id = "\(tag).\(p.id)"
            c.chapter = chapter
            c.captureTime = p.captureTime.map { $0.addingTimeInterval(shift) }
            c.take = take
            c.burstGroup = p.burstGroup.map { $0 + serial * 1000 }
            c.frameNo = "\(serial)"
            c.isManual = false
            serial += 1
            return c
        }
        for k in 0..<3 {
            for p in source {
                var c = copy(p, tag: "c10-\(k)", chapter: 10, shift: Double(k) * 600, take: p.take.map { $0 + 100 * k })
                c.body = "X-T50"
                if k == 1, p.id.hasSuffix("7225") {
                    c.verdict = .pick
                    c.isPick = true
                    c.isManual = true
                }
                if k == 2, p.id.hasSuffix("7224") {
                    c.verdict = .reject
                    c.isPick = false
                }
                out.append(c)
            }
        }
        for (i, p) in source.enumerated() {
            let body = i % 2
            var c = copy(p, tag: "c11", chapter: 11, shift: 86_400, take: p.take.map { $0 * 2 + body + 1000 })
            c.body = body == 0 ? "X-T50#A" : "X-T50#B"
            out.append(c)
        }
        for (i, p) in source.prefix(8).enumerated() {
            var c = copy(p, tag: "c12", chapter: 12, shift: 172_800, take: p.take.map { $0 + 2000 })
            c.body = "X-T50"
            c.verdict = i == 5 ? .reject : .usable
            c.isPick = false
            out.append(c)
        }
        return out
    }

    // MARK: - 模板工程

    /// 模板套在托盘上的一页（和 CollageTemplates.apply 同一条路：CollageContact.page）+ 带着模板画布、样式的工程。
    static func templateProject(_ template: CollageTemplate, spec: CollageContactSheet,
                                tray: [CollagePhotoRef]) -> (CollageProject, CollagePage) {
        var project = CollageProject()
        project.photos = tray
        if let canvas = template.canvas { project.canvas = canvas }
        if let style = template.style { project.style = style }
        let page = CollageContact.page(photos: tray, spec: spec)
        project.pages = [page]
        return (project, page)
    }

    /// 整页水印：字放在 position；给了签名就签名也开着、同一个位置（没给 = 只有字）。
    static func pageWatermark(_ position: WatermarkEngine.GridPosition,
                              signature: CollageSignature? = nil) -> CollageWatermark {
        var text = CollageMarkText()
        text.customText = "拾光 · 工作室"
        text.position = position
        var layer = CollageMarkLayer()
        layer.signatureOn = signature != nil
        layer.position = position
        layer.text = text
        var wm = CollageWatermark()
        wm.page = layer
        wm.signature = signature
        return wm
    }

    /// 自检用的签名图：600×180 透明底上一道深灰的「签名」（一个圆角条 + 一笔下划线），写进隔离的资料目录。
    /// 写不出来 = nil。
    static func makeSignature() -> CollageSignature? {
        let w = 600
        let h = 180
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 30, y: 70, width: 400, height: 80), cornerWidth: 30, cornerHeight: 30,
                           transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1))
        ctx.setLineWidth(10)
        ctx.move(to: CGPoint(x: 20, y: 40))
        ctx.addLine(to: CGPoint(x: 580, y: 30))
        ctx.strokePath()
        guard let image = ctx.makeImage() else { return nil }
        let url = appDataDir.appendingPathComponent("film-selftest-signature.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return CollageSignature(file: url.path, key: "film-selftest-signature", sourceName: "签名.png")
    }

    // MARK: - 出图

    /// 按导出的规矩渲一遍（缩放 scale），拿印样的出图记录。
    static func renderRecord(_ page: CollagePage, project base: CollageProject, scale: Double) -> CollageContact.Record? {
        var project = base
        project.pages = [page]
        var opts = CollageRender.Options(scale: scale)
        opts.export = true
        opts.includeBleed = false
        let report = CollageRender.RenderReport()
        opts.report = report
        _ = CollageRender.render(page: page, project: project, hints: [:], options: opts)
        return report.contactSheet
    }

    static func renderImage(_ page: CollagePage, project base: CollageProject, scale: Double) -> CGImage? {
        var project = base
        project.pages = [page]
        var opts = CollageRender.Options(scale: scale)
        opts.includeBleed = false
        return CollageRender.render(page: page, project: project, hints: [:], options: opts)
    }
}
