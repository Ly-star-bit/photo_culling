import Foundation
import CoreGraphics

/// 时尚刊自检：LABELGUI_DATA_DIR=<临时目录> LabelGUI --fashion-selftest <照片文件夹>（先 --analyze 过同一个数据目录）
///
/// 1. 真照片（photot 是一个模特、一天的汉服照，只验得到单人）：
///    - 强调色：每张主体的几类颜色、挑出来的颜色和底下的对比 ≥ 3:1、两次一样；
///    - 挑主图：排序、原因，筛掉的不进候选，两次一样；
///    - 出一期：4 页、3:4 单张多页、封面 = 第 1 候选（经 heroID）、内页不重复不含封面、四页刊头期号一样；
///    - 换封面：往后轮一张、轮满一圈回到第 1 张、内页对调不重复；没有一期时 coverStep 直接挑第 N 张（−1 = 最后一个，不越界）；
///      对调到内页的旧封面在那一页放不好（取景里有路人、切脸）时换一张没上这一期、放得好的；
///    - 7 个模板 × 每张照片 + 一期的 4 页：字块两两不重叠、人前的字不压脸、封面字不进底部 10.4%、没有真实刊名 / 胶片品牌；
///    - 模板名、分类名：前缀「时尚刊 · 」、全库唯一、不含别的分类名（--template-sheet --only 按包含匹配）；
///    - 人物挡字退让（S3 留给 K1 的 a）：stock 刊头 + 人后，挪取景、拉远的「成了」都还压着刊名（主行 ≥ 2%）、脸在 30–70%；
///    - 验收第 1 轮（fix1）：12 个字的标题下每条要读的封面字 ≥ 32 px（2.2%W）；「刊头在后 · 无衬线」两栏同一种深浅；
///      期号日期在右下（有条码时叠在条码上面）；刊头字墨的顶在 1–4%H；引语单图的脸在照片格宽 35–65%；
///      挑主图眼睛远的排在合规的后面；巨字开篇单页不算一期封面；托盘全是废片也出得来；长标题的刊头取前两个字。
///    - 别的人当障碍：7232 的红马甲、7227 的男人字栏躲开；远处的小人（7213、7214 刊头底下桥头那一群）认得出、挑主图标路人；
///      7224 屋脊上的脊兽不当人，7222、7223 不乱标路人。
/// 2. 合成数据（合成照片 + 合成蒙版，不是真照片；合影、多人这类 photot 没有的规则在这里验）：
///    - 挑主图的规矩：3 张脸、闭眼、认不出主体不进候选；横图、取景里有路人排在后面；
///    - 退让（a）：大帽子挡满中间、拉远到头掉出刊头才满足规则 → 不算拉远成了；
///    - 退回人前要拉近（b）：合影 3 张脸、头在照片偏下 → 头顶落在最下面一行基线下约 2%；
///    - 拉远的措辞（c）、眼睛远是照片下沿卡住（d，marks 记 eyeClamp）；
///    - 软边去污染（e）：深色背景前的浅色主体软边叠到白字上，不再是一圈暗边；
///    - 字块之间硬让位：左栏、右栏、底栏、人后刊头 4 块在 21 张上两两不重叠（S3_06 那张 SPECIAL EDITION 压期号）；
///    - 没有 EXIF 的照片（截图）：封面、满版大片的字里不出现「F/」「ISO」这种缺了值的半截；
///    - 也没有拍摄时间：7 个模板都不剩日期的半截（引语单图的「—  ,」、巨字开篇的「摄于」、folio 结尾的「·」）；
///    - 短刊头（AYA）字墨的顶在 1–4%H、字高 ≥ 15%H。
enum CollageStyleFashionSelfTest {
    /// 真实刊名、常见刊名词、胶片 / 滤镜品牌（DESIGN §0.4）：短词按整词比，长的按包含比（FUJIFILM 也算）。
    /// PORTRA 按整词比：固定词 PORTRAIT 里就有这几个字母。
    static let bannedWords = ["W", "GQ", "TIME", "MUSE", "ELLE", "PORTRA"]
    static let bannedParts = ["VOGUE", "BAZAAR", "KINFOLK", "CEREAL", "KODAK", "FUJI", "ILFORD", "HARPER",
                              "VANITY", "GLAMOUR", "INSTYLE", "ALLURE", "COSMOPOLITAN", "TATLER", "ISSN"]
    /// 别的分类名（模板名、分类名都不能含）。
    static let otherCategories = ["小红书封面", "日系杂志", "中式", "九宫格", "手账散落", "电影感", "基础",
                                  "底片印样", "留白杂志", "报纸风", "瑞士网格", "婚礼相册"]

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        CollageCLI.requireIsolatedDataDir("--fashion-selftest")
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }

        // ---------------------------------------------------------------- 0. 模板名、分类名
        print("== 模板名、分类名")
        let mine = CollageStyleFashion.templates
        check(mine.count == 7, "7 个模板（封面 4 + 内页 3）", "\(mine.count)")
        for t in mine {
            let others = otherCategories.filter { t.name.contains($0) || t.category.contains($0) }
            let dup = CollageTemplates.builtin.filter { $0.name == t.name }.count
            check(t.name.hasPrefix("时尚刊 · ") && t.category == "时尚刊" && others.isEmpty && dup == 1
                  && banned(t.name) == nil, "模板「\(t.name)」",
                  others.isEmpty ? (dup == 1 ? "" : "重名 \(dup)") : "含别的分类名 \(others)")
        }
        check(CollageStyles.all.filter { $0.key == "fashion" }.count == 1, "风格预设「时尚刊」(fashion) 注册了一个")

        // ---------------------------------------------------------------- 1. 真照片
        if args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") {
            let dir = URL(fileURLWithPath: args[flagIndex + 1])
            let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
            batch.switchSession(to: dir)
            CollageMasks.setDirectory(batch.sessionDir.appendingPathComponent("collage_masks"))
            let facts = CollageBridge.Facts(batch: batch)
            let photos = batch.items.filter { $0.verdict != .reject }.compactMap { CollageBridge.ref(from: $0, facts: facts) }
            check(!photos.isEmpty, "照片文件夹分析过（拿得到照片）",
                  photos.isEmpty ? "0 张：先 LABELGUI_DATA_DIR=同一个目录 LabelGUI --analyze \(dir.path)" : "\(photos.count) 张")
            var hints: [String: CollageCrop.Hints] = [:]
            for p in photos { hints[p.id] = CollageVision.hints(for: p) }
            realPhotos(photos, hints: hints, items: batch.items, facts: facts, record: check)
        } else {
            print("== 没给照片文件夹，跳过真照片（只验合成数据）")
        }

        // ---------------------------------------------------------------- 2. 合成数据
        synthetic(record: check)

        print(failures.isEmpty ? "== 全部通过" : "== 失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - 真照片

    @MainActor
    private static func realPhotos(_ photos: [CollagePhotoRef], hints: [String: CollageCrop.Hints], items: [BatchItem],
                                   facts: CollageBridge.Facts, record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        print("== 强调色（主体里衣服、嘴唇的几类颜色；深底 0.2 / 浅底 0.85 上挑出来的）")
        // 摆位里只用已经有的蒙版（封面格的人物挡字先算好）：这里先把蒙版算出来，和真出图时一样。
        for p in photos { _ = CollageMasks.mask(for: p) }
        var accentOK = true
        var accentDetail = ""
        for p in photos {
            let sw = CollageStyleFashion.palette(for: p)
            let list = sw.map { String(format: "L%.0f a%.0f b%.0f C%.0f %.0f%%", $0.l, $0.a, $0.b, $0.chroma, $0.share * 100) }
            var picked: [String] = []
            for under in [0.2, 0.85] {
                // 深底上是浅字（强调色要比底亮）、浅底上是深字（要比底暗）。
                let light = under < 0.5
                guard let c = CollageStyleFashion.accent(for: p, under: under, light: light) else {
                    picked.append("—")
                    continue
                }
                let bg = CollageLooks.linear(under)
                let k = CollageStyleFashion.contrast(c, bg)
                let y = CollageStyleFashion.linearLuminance(c)
                let lab = labChroma(c)
                picked.append(hex(c) + String(format: "(%.1f:1 C%.0f)", k, lab))
                if k < CollageStyleFashion.accentContrast - 0.01 || (light ? y <= bg : y >= bg)
                    || lab < CollageStyleFashion.accentMinChroma - 0.5 {
                    accentOK = false
                    accentDetail += " \(p.id)@\(under) \(String(format: "%.2f C%.0f", k, lab))"
                }
                if CollageStyleFashion.accent(for: p, under: under, light: light) != c { accentOK = false }
            }
            print("    \(p.id) [\(list.joined(separator: " | "))] → 深底 \(picked[0]) 浅底 \(picked[1])")
        }
        check(accentOK, "强调色：对比 ≥ 3:1、在字该在的那一边、彩度 ≥ 15、两次挑的一样", accentDetail)

        print("== 挑主图（套上封面看决定；罚分从低到高）")
        var base = CollageProject()
        base.photos = photos
        let issueBase = CollageStyleFashion.issueBase(base)
        let ranked = CollageStyleFashion.heroCandidates(photos, hints: hints, base: issueBase)
        for (k, h) in ranked.enumerated() {
            let occ = h.block?.occlusion.map { String(format: "挡 %.1f%%", $0.total * 100) } ?? "没量"
            print(String(format: "    %2d %@ 罚分 %.2f · %@ · %@", k + 1, h.photo.id, h.penalty,
                         h.block.map { $0.layer.rawValue + "/" + $0.step.rawValue } ?? "—", occ)
                  + (h.notes.isEmpty ? "" : " · " + h.notes.joined(separator: "、")))
        }
        let again = CollageStyleFashion.heroCandidates(photos, hints: hints, base: issueBase)
        check(!ranked.isEmpty && ranked.map(\.photo.id) == again.map(\.photo.id), "候选排序是定的（两次一样）",
              "\(ranked.count) 张")
        let bad = ranked.filter { h in
            let n = h.photo.faces.filter(CollageCrop.isValidBox).count
            return !(1...2).contains(n) || h.photo.eyesOpen == false || CollageMasks.mask(for: h.photo) == nil
        }
        check(bad.isEmpty, "候选都是 1–2 张脸、睁眼、有蒙版", bad.map(\.photo.id).joined(separator: " "))
        if let top = ranked.first {
            check(top.block?.layer == .behindSubject && !(top.window?.cutsFace ?? true), "第 1 候选的刊头在人后、取景不切脸",
                  top.photo.id)
        }

        print("== 出一期（4 页、共用刊头期号、封面经 heroID）")
        let context = CollageKits.Context(project: base, tray: photos, batchItems: { items }, facts: facts, hints: hints,
                                          seed: 7)
        guard let issue = CollageStyleFashion.issue(context) else {
            check(false, "出一期出得来", "nil")
            return
        }
        let ids = issue.pages.map { $0.photoIDs }
        print("    页：" + ids.map { $0.joined(separator: "+") }.joined(separator: " | "))
        check(issue.pages.count == 4 && issue.mode == .single && issue.canvas.width == 1440 && issue.canvas.height == 1920,
              "4 页、单张多页、3:4 1440×1920", "\(issue.pages.count) 页 \(issue.canvas.width)×\(issue.canvas.height)")
        let cover = CollageStyleFashion.coverPhotoID(issue)
        check(cover == ranked.first?.photo.id, "封面 = 第 1 候选", cover ?? "—")
        let flat = ids.flatMap { $0 }
        check(Set(flat).count == flat.count && !ids.dropFirst().flatMap { $0 }.contains(cover ?? ""), "四页照片不重复、内页不含封面")
        let kept = Set(CollageSelect.distinctMoments(photos).kept.map(\.id))
        let fromKept = ids.dropFirst().flatMap { $0 }.filter { kept.contains($0) }.count
        check(fromKept == 3, "内页都从 distinctMoments 的保留集里挑", "\(fromKept)/3")
        let again2 = CollageStyleFashion.issue(context)?.pages.map { $0.photoIDs }
        check(again2 == ids, "出一期是定的（同一组照片出同一套）")
        // 每一页存成「我的模板」（默认照页上的 fixedAspects）再套回去：版式的切分树形状不变（以前成套出的页
        // fixedAspects 没记，引语单图存完再套按照片比例重排成了 R3）。
        var tripBad: [String] = []
        let tripMap = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 切分树的形状：方向、比例（两位小数）、叶子是照片还是文字。
        func shape(_ n: CollageNode) -> String {
            guard n.children.count == 2 else { return n.cell?.kind == .text ? "T" : "P" }
            let axis = n.axis == .row ? "R" : "C"
            return axis + String(format: "%.2f", n.ratio) + "(" + shape(n.children[0]) + "," + shape(n.children[1]) + ")"
        }
        for (i, page) in issue.pages.enumerated() where !page.freeform && page.contactSheet == nil {
            let saved = CollageTemplates.template(from: page, name: "自检\(i)", style: issue.style, canvas: issue.canvas,
                                                  aspect: issue.canvas.aspect, fitAspects: !page.fixedAspects)
            let ctx = CollageLayout.Context(canvas: issue.canvas, style: issue.style, photos: tripMap, hints: hints)
            let back = CollageTemplates.apply(saved, photos: page.photoIDs.compactMap { tripMap[$0] }, context: ctx)
            if !page.fixedAspects || shape(back.root) != shape(page.root) {
                tripBad.append("第 \(i + 1) 页 \(shape(page.root)) → \(shape(back.root))")
            }
        }
        check(tripBad.isEmpty, "每一页存成「我的模板」再套回去，版式不变（成套的页也记着固定比例）", tripBad.joined(separator: "；"))
        var issueTexts: [[String]] = []
        for (i, page) in issue.pages.enumerated() {
            let r = report(page: page, project: issue, hints: hints)
            issueTexts.append(r.texts.flatMap(\.lines))
            let problems = layoutProblems(r, project: issue, cover: i == 0)
            check(problems.isEmpty, "第 \(i + 1) 页字块不重叠、不压脸、不进遮挡带", problems.joined(separator: "；"))
            let names = r.texts.flatMap(\.lines).compactMap(banned)
            check(names.isEmpty, "第 \(i + 1) 页没有真实刊名、胶片品牌", names.joined(separator: " "))
        }
        let masthead = CollageTypeset.mastheadText(issue.masthead, title: issue.title.isEmpty ? "拾光" : issue.title)
        let shared = issueTexts.enumerated().allSatisfy { i, lines in
            lines.contains { $0.contains(masthead) } && (i == 0 ? lines.contains { $0.contains("ISSUE 01") }
                : lines.contains { $0.hasPrefix(String(format: "%02d · ", i + 1)) })
        }
        check(shared && issue.issue == "01", "四页共用刊头「\(masthead)」、期号 01（内页 folio 是页码）")
        print("    文字：")
        for (i, lines) in issueTexts.enumerated() { print("      第 \(i + 1) 页：" + lines.joined(separator: " ⏎ ")) }

        print("== 换封面")
        let k = min(CollageStyleFashion.coverChoices, ranked.count)
        var rotated = issue
        var seen: [String] = []
        for _ in 0..<k {
            var c = context
            c.project = rotated
            c.coverStep = 1
            guard let next = CollageStyleFashion.issue(c) else { break }
            rotated = next
            seen.append(CollageStyleFashion.coverPhotoID(rotated) ?? "—")
            let all = rotated.pages.flatMap(\.photoIDs)
            if Set(all).count != all.count { seen.append("（重复）") }
        }
        let expect = (1...k).map { ranked[$0 % k].photo.id }
        check(seen == expect, "往后轮一张、轮满 \(k) 张回到第 1 张、照片不重复", seen.joined(separator: " → "))
        // 只换封面那张：内页留着（新封面要是在内页上，就和旧封面对调），版式、字都不动。
        let same = zip(rotated.pages, issue.pages).allSatisfy { a, b in a.root.signature == b.root.signature }
        check(rotated.pages.count == issue.pages.count && same, "换封面不动内页的版式（只换 / 对调照片）")
        var fresh = context
        fresh.coverStep = 2
        let third = fresh.project.pages.isEmpty ? CollageStyleFashion.issue(fresh).flatMap(CollageStyleFashion.coverPhotoID) : nil
        check(k < 3 || third == ranked[2].photo.id, "没有一期时 coverStep 2 = 第 3 候选", third ?? "—")
        // 对调到内页的旧封面放不好（那一页的取景里有路人、切脸……fitPenalty ≥ swapFitLimit）：换一张托盘里没上这一期、
        // 放得好的，不把旧封面硬塞进去。造一个这样的局面：封面先换成一张不在候选里、放到第 2 页会带路人的照片，
        // 再「换封面」轮到第 2 页那张（它得在前 k 个候选里）。
        let choiceIDs = ranked.prefix(k).map(\.photo.id)
        let photoMap = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if issue.pages.count > 1, let opener = issue.pages[1].photoIDs.first, let at = choiceIDs.firstIndex(of: opener) {
            let usedIDs = Set(issue.pages.flatMap(\.photoIDs))
            func onOpener(_ p: CollagePhotoRef) -> Double {
                var trial = issue
                var root = trial.pages[1].root
                for path in root.leafPaths() where root.node(at: path)?.cell?.photoID == opener {
                    root.update(at: path) { node in
                        node.cell?.photoID = p.id
                        node.cell?.crop = nil
                    }
                }
                trial.pages[1].root = root
                return CollageStyleFashion.fitPenalty(page: trial.pages[1], photo: p, project: trial, hints: hints, map: photoMap)
            }
            let misfit = photos.sorted { $0.id < $1.id }.first { p in
                !usedIDs.contains(p.id) && !choiceIDs.contains(p.id) && onOpener(p) >= CollageStyleFashion.swapFitLimit
            }
            if let misfit {
                var probe = issue
                var root = probe.pages[0].root
                root.update(at: []) { node in
                    node.cell?.photoID = misfit.id
                    node.cell?.crop = nil
                }
                probe.pages[0].root = root
                var c = context
                c.project = probe
                c.coverStep = at + 1
                let swapped = CollageStyleFashion.issue(c)
                let landed = swapped?.pages[1].photoIDs.first
                let all = swapped?.pages.flatMap(\.photoIDs) ?? []
                let fit = landed.flatMap { id in photoMap[id] }.map { p in
                    CollageStyleFashion.fitPenalty(page: swapped!.pages[1], photo: p, project: swapped!, hints: hints, map: photoMap)
                } ?? 99
                check(CollageStyleFashion.coverPhotoID(swapped ?? probe) == opener && landed != misfit.id
                      && Set(all).count == all.count && fit < CollageStyleFashion.swapFitLimit,
                      "换封面：放不好的旧封面（\(misfit.id) 在第 2 页罚 \(String(format: "%.1f", onOpener(misfit)))）不硬塞进内页，换一张放得好的",
                      "第 2 页 \(landed ?? "—") 罚 \(String(format: "%.1f", fit))")
            } else {
                print("    （托盘里没有放到第 2 页会带路人的照片，跳过「旧封面放不好」那条）")
            }
        }
        // 负的 coverStep（命令行 --cover-step -1 / nextcover:-1 夹到范围里之前）：余数折成非负，不越界崩掉。
        var negative = context
        negative.coverStep = -1
        let wrapped = negative.project.pages.isEmpty ? CollageStyleFashion.issue(negative).flatMap(CollageStyleFashion.coverPhotoID) : nil
        check(k < 1 || wrapped == ranked[k - 1].photo.id, "没有一期时 coverStep −1 = 最后一个候选（不越界）", wrapped ?? "—")
        var one = context
        one.tray = [photos[0]]
        one.project.photos = [photos[0]]
        let tiny = CollageStyleFashion.issue(one)
        check((tiny?.pages.count ?? 0) >= 1, "托盘只有 1 张也出得来（只有封面）", "\(tiny?.pages.count ?? 0) 页")

        print("== 7 个模板 × \(photos.count) 张：字块、人脸、遮挡带、文案")
        for t in CollageStyleFashion.templates {
            var bad: [String] = []
            var names: Set<String> = []
            for p in photos {
                var project = issueBase
                project.photos = photos
                let map = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map, hints: hints,
                                                heroID: p.id)
                let page = CollageTemplates.apply(t, photos: [p], context: ctx)
                project.pages = [page]
                let r = report(page: page, project: project, hints: hints)
                let isCover = t.root.cell?.framing == .cover
                bad += layoutProblems(r, project: project, cover: isCover).map { "\(p.id) \($0)" }
                for n in r.texts.flatMap(\.lines).compactMap(banned) { names.insert(n) }
            }
            check(bad.isEmpty, "「\(t.name)」字块不重叠、不压脸" + (t.root.cell?.framing == .cover ? "、不进遮挡带" : ""),
                  bad.prefix(4).joined(separator: "；"))
            check(names.isEmpty, "「\(t.name)」展开后的字没有真实刊名、胶片品牌", names.joined(separator: " "))
        }

        print("== 人物挡字退让（a）：挪取景、拉远「成了」都还压着刊名、脸在格宽 30–70%")
        for (label, overlay) in [("stock 刊头", stockMasthead()), ("时尚刊刊头", CollageStyleFashion.masthead())] {
            var bad: [String] = []
            var steps: [String: Int] = [:]
            for p in photos {
                guard let (block, w, frame) = resolve(overlay, photo: p, hints: hints[p.id]) else { continue }
                steps[block.step.rawValue, default: 0] += 1
                guard block.step == .shifted || block.step == .pulledBack, let o = block.occlusion else { continue }
                let main = o.perLine.indices.contains(o.mainLine) ? o.perLine[o.mainLine] : o.total
                let f = p.faces.first(where: CollageCrop.isValidBox) ?? [0, 0, 1, 1]
                let centre: Double = ((f[0] + f[2]) / 2 - w.x) / w.w
                let frac: Double = (Double(frame.minX) + centre * Double(frame.width)) / Double(frame.width)
                if main < CollageCover.engageMin || !CollageCover.centreBand.contains(frac) {
                    bad.append(String(format: "%@ %@ 主行 %.1f%% 脸 %.0f%%", p.id, block.step.rawValue, main * 100, frac * 100))
                }
            }
            check(bad.isEmpty, label + "：" + steps.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " "),
                  bad.joined(separator: "；"))
        }

        fixRound1(photos, hints: hints, ranked: ranked, issueBase: issueBase, context: context, record: record)
        finalRound(photos, hints: hints, issueBase: issueBase, record: record)
        peopleRound(photos, hints: hints, ranked: ranked, issueBase: issueBase, record: record)
    }

    // MARK: - 验收第 1 轮（fix1）

    /// 套一个模板到一张照片：页、工程、出图记录、每块字的摆位（Placement 里有深浅）。
    private static func applied(_ t: CollageTemplate, _ p: CollagePhotoRef, photos: [CollagePhotoRef],
                                hints: [String: CollageCrop.Hints], base: CollageProject)
        -> (project: CollageProject, report: CollageRender.RenderReport, placed: [CollageOverlays.Placement?],
            vars: [String: String]) {
        var project = base
        project.photos = photos
        let map = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map, hints: hints,
                                        heroID: p.id)
        let page = CollageTemplates.apply(t, photos: [p], context: ctx)
        project.pages = [page]
        let r = report(page: page, project: project, hints: hints)
        var placed: [CollageOverlays.Placement?] = []
        var vars: [String: String] = [:]
        let geo = CollageLayout.pageGeometry(page.root, canvas: project.canvas, style: project.style)
        if let frame = geo.frames.first(where: { $0.cell.kind == .photo }), let photo = project.photo(frame.cell.photoID ?? "") {
            vars = CollageTypeset.cellVariables(
                CollageTypeset.variables(project: project, root: page.root, photos: map, pageID: page.id), photo: photo)
            placed = CollageRender.overlayPlacements(cell: frame.cell, frameRect: frame.rect.cgRect, project: project,
                                                     photo: photo, framing: frame.cell.framing, hints: hints[photo.id],
                                                     vars: vars, background: project.style.background)
        }
        return (project, r, placed, vars)
    }

    /// 要读的封面字块（封面字栏、一句话的主卖点）：干净的字、沿边找位置或带底部压暗的那几块（下标）。
    private static func readableBlocks(_ t: CollageTemplate) -> Set<Int> {
        guard let cell = t.root.cell else { return [] }
        return Set(cell.overlays.indices.filter { i in
            let o = cell.overlays[i]
            return !o.scrim && o.layer == .front && (o.anchor.isSide || o.fade > 0)
        })
    }

    private static func blockIndex(_ owner: String) -> Int {
        owner.split(separator: ".").count > 1 ? Int(owner.split(separator: ".").last!) ?? 0 : 0
    }

    @MainActor
    private static func fixRound1(_ photos: [CollagePhotoRef], hints: [String: CollageCrop.Hints],
                                  ranked: [CollageStyleFashion.HeroPick], issueBase: CollageProject,
                                  context: CollageKits.Context, record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        let covers = [CollageStyleFashion.coverSans, CollageStyleFashion.coverSerifRight, CollageStyleFashion.coverFrench,
                      CollageStyleFashion.coverOneLine]
        let floorPx: Double = CollageOverlays.readableSize * Double(CollageStyleFashion.canvas.width) - 0.05

        print("== 验收第 1 轮：要读的封面字 ≥ 2.2%W（默认标题、12 个字的标题），期号日期右下，两栏同深浅")
        for title in ["", "春日庭院里的一个下午时光"] {
            var base = issueBase
            base.title = title
            for t in covers {
                var small: [String] = []
                var wrapped = 0
                let readable = readableBlocks(t)
                for p in photos {
                    let r = applied(t, p, photos: photos, hints: hints, base: base).report
                    for x in r.texts where x.kind == "overlay" && readable.contains(blockIndex(x.owner)) {
                        if let m = x.sizes.min(), m < floorPx { small.append(String(format: "%@ %@ %.0fpx", p.id, x.owner, m)) }
                        if x.lines.count > t.root.cell!.overlays[blockIndex(x.owner)].text.lines.count { wrapped += 1 }
                    }
                }
                let label = title.isEmpty ? "默认标题" : "12 字标题"
                check(small.isEmpty, "「\(t.name)」\(label)：要读的字都 ≥ \(Int(floorPx.rounded())) px",
                      small.isEmpty ? (wrapped > 0 ? "断行 \(wrapped) 块" : "") : small.prefix(5).joined(separator: "；"))
            }
        }

        var mixed: [String] = []
        var issueBad: [String] = []
        let W = Double(CollageStyleFashion.canvas.width)
        let H = Double(CollageStyleFashion.canvas.height)
        for t in covers {
            let barcode = !t.items.isEmpty
            for p in photos {
                let a = applied(t, p, photos: photos, hints: hints, base: issueBase)
                if t.name == CollageStyleFashion.coverSans.name {
                    let tones = Set(a.placed.indices.filter { t.root.cell!.overlays[$0].matchTone }.compactMap { a.placed[$0]?.light })
                    if tones.count > 1 { mixed.append(p.id) }
                }
                guard let issue = a.report.texts.last(where: { $0.kind == "overlay" }) else { continue }
                let right: Bool = Double(issue.rect.maxX) >= W * (1 - 0.035) - 2
                let low: Bool = Double(issue.rect.minY) >= H * 0.8
                let above: Bool = !barcode || Double(issue.rect.maxY) <= H * (1 - CollageStyleFashion.barcodeTop) + 0.5
                if !(right && low && above) {
                    issueBad.append(String(format: "%@ %@ x%.0f–%.0f y%.0f–%.0f", t.name, p.id, issue.rect.minX, issue.rect.maxX,
                                           issue.rect.minY, issue.rect.maxY))
                }
            }
        }
        check(mixed.isEmpty, "「刊头在后 · 无衬线」两栏封面字同一种深浅（全白或全黑）× \(photos.count) 张", mixed.joined(separator: " "))
        check(issueBad.isEmpty, "期号日期在右下（有条码的叠在条码上面）：4 款封面 × \(photos.count) 张", issueBad.prefix(4).joined(separator: "；"))

        print("== 刊头字墨的顶、引语单图的取景")
        var tops: [Double] = []
        var heights: [Double] = []
        var offCentre: [String] = []
        for p in photos {
            let a = applied(CollageStyleFashion.coverSans, p, photos: photos, hints: hints, base: issueBase)
            if let m = a.placed.first ?? nil {
                let L = CollageCover.letters(m, vars: a.vars, drawn: CGRect(x: 0, y: 0, width: W, height: H), clip: nil)
                tops.append(L.capTop / H)
                heights.append((L.baseline - L.capTop) / H)
            }
            let q = applied(CollageStyleFashion.spreadQuote, p, photos: photos, hints: hints, base: issueBase)
            if let c = q.report.crops.first, let f = p.faces.first(where: CollageCrop.isValidBox), c.window.width > 0 {
                let centre: Double = ((f[0] + f[2]) / 2 - Double(c.window.minX)) / Double(c.window.width)
                if centre < 0.35 || centre > 0.65 { offCentre.append(String(format: "%@ %.0f%%", p.id, centre * 100)) }
            }
        }
        let topRange = (tops.min() ?? 0, tops.max() ?? 1)
        check(topRange.0 >= 0.01 && topRange.1 <= 0.04, "刊头字墨的顶在 1–4%H（\(photos.count) 张）",
              String(format: "%.1f–%.1f%%H，字高 %.1f–%.1f%%H", topRange.0 * 100, topRange.1 * 100,
                     (heights.min() ?? 0) * 100, (heights.max() ?? 0) * 100))
        check(offCentre.isEmpty, "引语单图：脸在照片格宽 35–65%（\(photos.count) 张）", offCentre.joined(separator: " "))

        print("== 挑主图、换封面开关、废片托盘、长标题刊头")
        let firstFar = ranked.first?.block?.eyeFar ?? false
        let anyNear = ranked.contains { !($0.block?.eyeFar ?? false) }
        check(!(firstFar && anyNear), "有眼位合规的候选时，第 1 候选不是眼睛离刊头远的",
              ranked.prefix(3).map { $0.photo.id + (($0.block?.eyeFar ?? false) ? "(远)" : "") }.joined(separator: " > "))
        var opener = issueBase
        opener.photos = photos
        let map = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ctx = CollageLayout.Context(canvas: opener.canvas, style: opener.style, photos: map, hints: hints)
        opener.pages = [CollageTemplates.apply(CollageStyleFashion.spreadOpener, photos: [photos[0]], context: ctx)]
        var cover = issueBase
        cover.photos = photos
        cover.pages = [CollageTemplates.apply(CollageStyleFashion.coverFrench, photos: [photos[0]], context: ctx)]
        check(CollageStyleFashion.coverPhotoID(opener) == nil && CollageStyleFashion.coverPhotoID(cover) != nil,
              "「换封面」只认带刊头的封面页（巨字开篇单页不算）")
        var rejects = context
        rejects.tray = photos.prefix(4).map { p in
            var r = p
            r.verdict = .reject
            return r
        }
        rejects.project.photos = rejects.tray
        check((CollageStyleFashion.issue(rejects)?.pages.count ?? 0) >= 1, "托盘全是废片也出得来（不再提示「还没做好」）")
        var long = CollageProject()
        long.title = "春日庭院里的一个下午"
        let lb = CollageStyleFashion.issueBase(long)
        check(lb.masthead == "CHUNRI", "没填刊头、标题转出来太长：刊头取前两个字（CHUNRI）", lb.masthead)
    }

    /// 封面 · 刊头大图的刊头（{title} 宋体 + 期号日期小字一块）定在上方、人后：同 --overlay masthead --anchor top --overlay-behind。
    private static func stockMasthead() -> CollageOverlay {
        var o = CollageOverlays.preset("masthead") ?? CollageOverlay(text: CollageText())
        o.anchor = .top
        o.layer = .behindSubject
        return o
    }

    /// 一格 3:4 零边距封面取景、只有这一块字：决定、取景、格子。
    private static func resolve(_ overlay: CollageOverlay, photo p: CollagePhotoRef, hints: CollageCrop.Hints?,
                                faces: [[Double]]? = nil) -> (CollageCover.Block, CollageCrop.Window, CGRect)? {
        var project = CollageProject()
        project.canvas = CollageStyleFashion.canvas
        project.style = CollageStyleFashion.style
        project.photos = [p]
        var cell = CollageCell.photo(p.id, role: .hero)
        cell.framing = .cover
        cell.overlays = [overlay]
        project.pages = [CollagePage(root: .leaf(cell))]
        let frame = CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height)
        let vars = CollageTypeset.cellVariables(CollageTypeset.variables(project: project, root: .leaf(cell),
                                                                         photos: [p.id: p]), photo: p)
        guard let r = CollageCover.resolve(cell: cell, frameRect: frame, project: project, photo: p, framing: .cover,
                                           hints: hints, vars: vars, background: .white),
              let block = r.blocks.first ?? nil else { return nil }
        return (block, r.window, frame)
    }

    /// 按 0.25 渲染一页、收出图记录（字块位置是 1 倍几何，和导出一样）。
    private static func report(page: CollagePage, project: CollageProject,
                               hints: [String: CollageCrop.Hints]) -> CollageRender.RenderReport {
        var opts = CollageRender.Options(scale: 0.25)
        opts.includeBleed = false
        let r = CollageRender.RenderReport()
        opts.report = r
        _ = CollageRender.render(page: page, project: project, hints: hints, options: opts)
        return r
    }

    /// 字块两两重叠、人前的字压脸（脸框外扩 10%）、封面字（≥ 25px 的压字）进底部 10.4% 带。
    private static func layoutProblems(_ r: CollageRender.RenderReport, project: CollageProject, cover: Bool) -> [String] {
        var out: [String] = []
        let texts = r.texts
        for i in texts.indices {
            for j in texts.indices where j > i {
                let hit = texts[i].rect.intersection(texts[j].rect)
                if !hit.isNull, hit.width > 0.5, hit.height > 0.5 { out.append("\(texts[i].owner)×\(texts[j].owner) 重叠") }
            }
        }
        for c in r.crops {
            guard let p = project.photo(c.photoID), c.window.width > 0, c.window.height > 0 else { continue }
            for f in p.faces where CollageCrop.isValidBox(f) {
                let fw = f[2] - f[0]
                let fh = f[3] - f[1]
                let sx: Double = Double(c.drawn.width) / Double(c.window.width)
                let sy: Double = Double(c.drawn.height) / Double(c.window.height)
                let x0: Double = Double(c.drawn.minX) + (f[0] - 0.1 * fw - Double(c.window.minX)) * sx
                let y0: Double = Double(c.drawn.minY) + (f[1] - 0.1 * fh - Double(c.window.minY)) * sy
                let face = CGRect(x: x0, y: y0, width: 1.2 * fw * sx, height: 1.2 * fh * sy)
                for t in texts where t.kind == "overlay" && t.layer == "front" && t.owner.split(separator: ".").first.map(String.init) == c.owner {
                    // 退回人前的人后大字按字形碰没碰脸（CollageCover 已经挪过）；人前的封面字按外框。
                    if t.occlusion != nil { continue }
                    let hit = t.rect.intersection(face)
                    if !hit.isNull, hit.width > 0.5, hit.height > 0.5 { out.append("\(t.owner) 压脸") }
                }
            }
        }
        if cover {
            let floor = Double(project.canvas.height) * (1 - CollageStyleFashion.bottomBand) + 1
            for t in texts where t.kind == "overlay" && (t.sizes.max() ?? 0) >= 25 && Double(t.rect.maxY) > floor {
                out.append("\(t.owner) 进了底部遮挡带")
            }
        }
        return out
    }

    /// 一行字里的真实刊名 / 品牌（没有 = nil）。
    static func banned(_ line: String) -> String? {
        let up = line.uppercased()
        let tokens = up.split { !$0.isLetter }.map(String.init)
        if let w = tokens.first(where: { bannedWords.contains($0) }) { return w }
        if let w = bannedParts.first(where: { up.contains($0) }) { return w }
        if let w = tokens.first(where: { CollageTypeset.looksLikeRealMasthead($0) && $0.count > 1 }) { return w }
        return CollageTypeset.looksLikeRealMasthead(line) ? line : nil
    }

    /// 颜色的 Lab 彩度（强调色不能是发灰的灰青）。
    static func labChroma(_ c: CollageColor) -> Double {
        let lr = CollageLooks.linear(c.r)
        let lg = CollageLooks.linear(c.g)
        let lb = CollageLooks.linear(c.b)
        let x: Double = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y: Double = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z: Double = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let a: Double = 500 * (f(x) - f(y))
        let b: Double = 200 * (f(y) - f(z))
        return (a * a + b * b).squareRoot()
    }

    static func hex(_ c: CollageColor) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    // MARK: - 合成数据

    @MainActor
    private static func synthetic(record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        print("== 合成数据（合成照片 + 合成蒙版，不是真照片）")
        let mw = 682
        let mh = 1024
        func paint(_ shapes: [(kind: String, rect: [Double])], w: Int = 682, h: Int = 1024) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let u = (Double(x) + 0.5) / Double(w)
                    let v = (Double(y) + 0.5) / Double(h)
                    for s in shapes {
                        let r = s.rect
                        var inside = false
                        if s.kind == "ellipse" {
                            let dx: Double = (u - (r[0] + r[2]) / 2) / ((r[2] - r[0]) / 2)
                            let dy: Double = (v - (r[1] + r[3]) / 2) / ((r[3] - r[1]) / 2)
                            inside = dx * dx + dy * dy <= 1
                        } else {
                            inside = u >= r[0] && u <= r[2] && v >= r[1] && v <= r[3]
                        }
                        if inside {
                            px[y * w + x] = 255
                            break
                        }
                    }
                }
            }
            return px
        }
        func photo(_ name: String, faces: [[Double]], size: [Int] = [4000, 6000],
                   shapes: [(kind: String, rect: [Double])]?) -> CollagePhotoRef {
            var p = CollagePhotoRef(id: "synthetic-k1-\(name)", path: "/nonexistent/synthetic-k1-\(name).jpg",
                                    width: size[0], height: size[1])
            p.faces = faces
            p.score = 0.5
            let w = size[0] >= size[1] ? 1024 : mw
            let h = size[0] >= size[1] ? Int((1024.0 * Double(size[1]) / Double(size[0])).rounded()) : mh
            if let shapes {
                CollageMasks.inject(CollageMasks.synthetic(paint(shapes, w: w, h: h), width: w, height: h, faces: faces),
                                    for: p)
            } else {
                CollageMasks.inject(nil, for: p)
            }
            return p
        }
        let face = [0.42, 0.30, 0.58, 0.40]
        let head: (kind: String, rect: [Double]) = ("ellipse", [0.43, 0.26, 0.57, 0.41])
        let body: (kind: String, rect: [Double]) = ("rect", [0.36, 0.40, 0.64, 1.0])
        func mast(_ word: String = "ATELIER") -> CollageOverlay {
            var o = CollageStyleFashion.masthead()
            o.text.lines[0].text = word
            o.tone = .light
            return o
        }
        CollageCover.purge()

        // 挑主图的规矩。
        let good = photo("good", faces: [face], shapes: [head, body])
        let group = photo("group", faces: [face, [0.15, 0.32, 0.29, 0.41], [0.71, 0.31, 0.85, 0.40]],
                          shapes: [head, body, ("ellipse", [0.15, 0.28, 0.29, 0.42]), ("ellipse", [0.71, 0.27, 0.85, 0.41])])
        var closed = photo("closed", faces: [face], shapes: [head, body])
        closed.eyesOpen = false
        let nomask = photo("nomask", faces: [face], shapes: nil)
        let wide = photo("landscape", faces: [[0.46, 0.30, 0.54, 0.45]], size: [6000, 4000],
                         shapes: [("ellipse", [0.465, 0.25, 0.535, 0.46]), ("rect", [0.42, 0.45, 0.58, 1.0])])
        let crowd = photo("bystander", faces: [face], shapes: [head, body])
        var hints: [String: CollageCrop.Hints] = [:]
        hints[crowd.id] = CollageCrop.Hints(bystanders: [[0.62, 0.30, 0.72, 0.60]])
        let tray = [good, group, closed, nomask, wide, crowd]
        var base = CollageProject()
        base.photos = tray
        let ranked = CollageStyleFashion.heroCandidates(tray, hints: hints, base: CollageStyleFashion.issueBase(base))
        let order = ranked.map { $0.photo.id.replacingOccurrences(of: "synthetic-k1-", with: "") }
        check(order.first == "good" && !order.contains("group") && !order.contains("closed") && !order.contains("nomask"),
              "挑主图：3 张脸、闭眼、认不出主体不进候选；正常单人竖图排第 1", order.joined(separator: " > "))
        let notes = ranked.map { $0.notes.joined(separator: "、") }.joined(separator: " | ")
        check(order.firstIndex(of: "landscape") ?? -1 > 0 && order.firstIndex(of: "bystander") ?? -1 > 0
              && notes.contains("横图") && notes.contains("路人"), "横图、取景里有路人排在后面，原因说得出", notes)

        // （a）大帽子挡满中间：拉远到头掉出刊头才满足规则，那样不算「拉远成了」。
        let hat = photo("widehat", faces: [face], shapes: [("ellipse", [0.12, 0.20, 0.88, 0.36]), head, body])
        if let (block, _, _) = resolve(mast(), photo: hat, hints: nil) {
            let o = block.occlusion
            let main = o.map { $0.perLine.indices.contains($0.mainLine) ? $0.perLine[$0.mainLine] : $0.total } ?? 0
            let engaged = block.step != .shifted && block.step != .pulledBack || main >= CollageCover.engageMin
            check(engaged, "（a）大帽子：挪取景 / 拉远成了的时候还压着刊名", "\(block.step.rawValue) 主行 "
                  + String(format: "%.1f%%", main * 100) + (block.reason.map { " · " + $0 } ?? ""))
        } else {
            check(false, "（a）大帽子有决定", "")
        }

        // （b）合影退回人前：头在照片偏下，以前窗口不拉近、头掉到刊头下面老远；现在头顶落在最下面一行基线下约 2%。
        let low = photo("grouplow", faces: [[0.42, 0.52, 0.58, 0.60], [0.16, 0.53, 0.30, 0.61], [0.70, 0.52, 0.84, 0.60]],
                        shapes: [("ellipse", [0.43, 0.48, 0.57, 0.61]), ("rect", [0.36, 0.60, 0.64, 1.0]),
                                 ("ellipse", [0.16, 0.49, 0.30, 0.62]), ("ellipse", [0.70, 0.48, 0.84, 0.61])])
        if let (block, w, frame) = resolve(mast(), photo: low, hints: nil), let mask = CollageMasks.mask(for: low),
           let ht = mask.primaryHeadTop {
            let headY: Double = (ht - w.y) / w.h * Double(frame.height)
            let placed = layoutBaseline(mast(), photo: low, window: w)
            let target: Double = placed + 0.02 * Double(frame.height)
            let off: Double = (headY - target) / Double(frame.height)
            check(block.layer == .front && abs(off) < 0.015, "（b）合影退回人前、拉近到头顶在最下面一行基线下 2%",
                  String(format: "头顶 %.0f 目标 %.0f（差 %.1f%%H）窗口 %.3f×%.3f", headY, target, off * 100, w.w, w.h))
        } else {
            check(false, "（b）合影场景有决定", "")
        }

        // （c）拉远的措辞按幅度：拉到整张照片写「不少」。
        let words = [CollageCover.pullWording(1.0, from: 0.6, full: 1.0), CollageCover.pullWording(0.8, from: 0.6, full: 1.0),
                     CollageCover.pullWording(0.65, from: 0.6, full: 1.0)]
        check(words[0].hasPrefix("不少") && words[1] == "一些" && words[2] == "一点", "（c）拉远措辞：整张 / 长 25% 以上 / 一点",
              words.joined(separator: " · "))

        // （d）横图放进 3:4、人在照片下半截：照片下沿卡住，眼睛离刊头远 —— eyeFar + eyeClamp = bottom，进 marks。
        let far = photo("eyefar", faces: [[0.45, 0.58, 0.55, 0.74]], size: [6000, 4000],
                        shapes: [("ellipse", [0.44, 0.53, 0.56, 0.75]), ("rect", [0.38, 0.74, 0.62, 1.0])])
        if let (block, _, _) = resolve(mast(), photo: far, hints: nil) {
            check(block.eyeFar && block.eyeClamp == "bottom", "（d）照片下沿卡住：eyeFar、eyeClamp = bottom",
                  block.eyeBelow.map { String(format: "基线下 %.1f%%", $0 * 100) } ?? "没算")
            var cell = CollageCell.photo(far.id, role: .hero)
            cell.framing = .cover
            cell.overlays = [mast()]
            var project = CollageProject()
            project.canvas = CollageStyleFashion.canvas
            project.style = CollageStyleFashion.style
            project.photos = [far]
            let page = CollagePage(root: .leaf(cell))
            project.pages = [page]
            let r = report(page: page, project: project, hints: [:])
            let json = r.texts.first?.occlusion.map { CollageWatermarkCLI.occlusionJSON($0) }
            check((json?["eyeClamp"] as? String) == "bottom", "（d）.marks.json 的 occlusion 记了 eyeClamp")
        }

        // （e）软边去污染：深色背景前的浅色主体，软边叠到白字上不再发暗。
        decontamination(record: check)

        // 字块之间硬让位：S3_06 那组（人后刊头 + 左栏 + 右栏 + 底栏 SPECIAL EDITION）。
        siblings(record: check)

        // 验收最后一轮：栏躲开人身上（换到另一边）、截短的刊头、短刊头字距上限。
        bodyAvoid(record: check)
        otherPerson(record: check)
        shortMastheads(record: check)

        // 没有 EXIF（截图、去掉 EXIF 的导出）：「 · 」隔开的那几段里缺值的整段不印，不出现「F/」「ISO」半截。
        let bare = photo("noexif", faces: [face], shapes: [head, body])
        var leftovers: [String] = []
        for t in [CollageStyleFashion.coverSans, CollageStyleFashion.spreadFull] {
            var project = CollageProject()
            project.canvas = CollageStyleFashion.canvas
            project.style = CollageStyleFashion.style
            project.photos = [bare]
            let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: [bare.id: bare], hints: [:])
            let page = CollageTemplates.apply(t, photos: [bare], context: ctx)
            project.pages = [page]
            for line in report(page: page, project: project, hints: [:]).texts.flatMap(\.lines) {
                let stub = line.contains("F/") || line.contains("ISO") || line.hasPrefix("·") || line.hasSuffix("·")
                    || line.contains("· ·") || line == "S" || line.hasSuffix("MM")
                if stub { leftovers.append(line) }
            }
        }
        check(leftovers.isEmpty, "没有 EXIF 的照片：封面、满版大片不印缺值的半截（F/、ISO）", leftovers.joined(separator: " | "))
        // 这张合成照片也没有拍摄时间（截图、微信转过的图、「添加文件」进来的）：7 个模板都不剩日期的半截 ——
        // 引语单图的落款不剩「—  ,」、巨字开篇不剩「摄于」、folio 不以「·」结尾、左栏不剩「人像」「的光」。
        var undated: [String] = []
        for t in CollageStyleFashion.templates {
            var project = CollageProject()
            project.canvas = CollageStyleFashion.canvas
            project.style = CollageStyleFashion.style
            project.photos = [bare]
            let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: [bare.id: bare], hints: [:])
            let page = CollageTemplates.apply(t, photos: [bare], context: ctx)
            project.pages = [page]
            for line in report(page: page, project: project, hints: [:]).texts.flatMap(\.lines) {
                let s = line.trimmingCharacters(in: .whitespaces)
                let lone: Set<String> = [",", "—", "·", "摄于", "人像", "的光", "的一组人像", "农历", "ISSUE"]
                let stub = lone.contains(s) || s.hasPrefix("—") || s.hasPrefix(",") || s.contains(" ,")
                    || s.hasPrefix("·") || s.hasSuffix("·")
                if stub { undated.append("\(t.name)「\(line)」") }
            }
        }
        check(bare.captureTime == nil && undated.isEmpty, "没有拍摄时间：7 个模板都不剩日期的半截（—  ,、摄于、· 结尾）",
              undated.joined(separator: " | "))

        // 短刊头（≤ 4 个字母）：字距撑满、字高 ≥ 15%H，字墨的顶照样在 1–4%H。
        var shortMast = CollageStyleFashion.masthead()
        shortMast.text.lines[0].text = "AYA"
        let frame = CGRect(x: 0, y: 0, width: CollageStyleFashion.canvas.width, height: CollageStyleFashion.canvas.height)
        var sp = CollageProject()
        sp.canvas = CollageStyleFashion.canvas
        sp.style = CollageStyleFashion.style
        var sc = CollageCell.photo(good.id, role: .hero)
        sc.overlays = [shortMast]
        let placedShort = CollageRender.rawPlacements(cell: sc, frameRect: frame, project: sp, photo: good, framing: .auto,
                                                      hints: nil, vars: [:], background: .white, window: nil,
                                                      maxHeights: [:])
        if let m = placedShort.first ?? nil {
            let L = CollageCover.letters(m, vars: [:], drawn: frame, clip: nil)
            let top: Double = L.capTop / Double(frame.height)
            let cap: Double = (L.baseline - L.capTop) / Double(frame.height)
            check(top >= 0.01 && top <= 0.04 && cap >= 0.15, "短刊头 AYA：字墨的顶在 1–4%H、字高 ≥ 15%H",
                  String(format: "顶 %.1f%%H 字高 %.1f%%H", top * 100, cap * 100))
        } else {
            check(false, "短刊头摆得出来", "")
        }
    }

    /// 合成场景里刊头最下面一行的基线（1 倍、成品坐标）。
    private static func layoutBaseline(_ overlay: CollageOverlay, photo p: CollagePhotoRef, window: CollageCrop.Window) -> Double {
        var project = CollageProject()
        project.canvas = CollageStyleFashion.canvas
        project.style = CollageStyleFashion.style
        var cell = CollageCell.photo(p.id, role: .hero)
        cell.framing = .cover
        cell.overlays = [overlay]
        let frame = CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height)
        let placed = CollageRender.rawPlacements(cell: cell, frameRect: frame, project: project, photo: p, framing: .cover,
                                                 hints: nil, vars: [:], background: .white, window: window, maxHeights: [:])
        guard let first = placed.first ?? nil else { return 0 }
        return CollageCover.letters(first, vars: [:], drawn: frame, clip: nil).lastBaseline
    }

    /// 合成 tile：深底（0.12）上一个浅色圆（0.75），边上 12 像素软边 —— 软边的像素就是「主体 + 背景」按 alpha 混的。
    /// 叠到白字上：理想 = a·主体 + (1 − a)·白；原 tile 是 a·(a·主体 + (1 − a)·深底) + (1 − a)·白（暗一圈）。
    private static func decontamination(record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        let n = 160
        var alphaPx = [UInt8](repeating: 0, count: n * n)
        var rgb = [UInt8](repeating: 0, count: n * n * 4)
        let fg = 0.75
        let bgc = 0.12
        for y in 0..<n {
            for x in 0..<n {
                let d: Double = (Double(x) - 80).hypot(Double(y) - 80)
                let a: Double = min(1, max(0, (50 - d) / 12 + 0.5))
                alphaPx[y * n + x] = UInt8((a * 255).rounded())
                let v: Double = a * fg + (1 - a) * bgc
                let o = (y * n + x) * 4
                rgb[o] = UInt8((v * 255).rounded())
                rgb[o + 1] = rgb[o]
                rgb[o + 2] = rgb[o]
                rgb[o + 3] = 255
            }
        }
        guard let alpha = gray(alphaPx, n), let tile = color(rgb, n),
              let mask = CollageMasks.synthetic(alphaPx, width: n, height: n, faces: []) else {
            check(false, "（e）合成 tile 建得出来", "")
            return
        }
        let shown = CollageRender.Shown(tile: tile, drawn: CGRect(x: 0, y: 0, width: n, height: n),
                                        window: CollageCrop.Window(x: 0, y: 0, w: 1, h: 1),
                                        clip: CGPath(rect: CGRect(x: 0, y: 0, width: n, height: n), transform: nil),
                                        guide: "synthetic-k1-decont")
        guard let clean = CollageRender.decontaminated(shown: shown, alpha: alpha, mask: mask, scale: 1),
              let cleanPx = pixels(clean) else {
            check(false, "（e）去污染出得来", "")
            return
        }
        var errOld = 0.0
        var errNew = 0.0
        var count = 0.0
        for i in 0..<(n * n) {
            let a = Double(alphaPx[i]) / 255
            guard a > 0.1, a < 0.9 else { continue }
            let ideal: Double = a * fg + (1 - a)
            let old: Double = a * Double(rgb[i * 4]) / 255 + (1 - a)
            let new: Double = a * Double(cleanPx[i * 4]) / 255 + (1 - a)
            errOld += abs(old - ideal)
            errNew += abs(new - ideal)
            count += 1
        }
        let o = errOld / max(1, count)
        let e = errNew / max(1, count)
        check(count > 100 && e < o * 0.35, "（e）软边去污染：叠到白字上离理想色近得多（暗边去掉了）",
              String(format: "软边 %.0f 像素，平均偏差 %.3f → %.3f", count, o, e))
    }

    private static func gray(_ px: [UInt8], _ n: Int) -> CGImage? {
        var copy = px
        return copy.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }

    private static func color(_ px: [UInt8], _ n: Int) -> CGImage? {
        var copy = px
        return copy.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                      space: CollageRender.srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        let n = image.width * image.height * 4
        var px = [UInt8](repeating: 0, count: n)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CollageRender.srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? px : nil
    }

    /// S3_06 那组字块在合成照片上：底栏 SPECIAL EDITION 以前压住左栏的期号。按 photot 的样子造几张：脸在中间偏上，
    /// 底下一大片「乱」的区域靠合成蒙版和人脸代价逼着底栏往上走。
    // MARK: - 验收最后一轮

    /// 真照片：封面字栏、开篇小字不压人身上（验收点名的几张）；统一深浅不再选「深字压在白袖子上」；法式左栏的主题字
    /// 在亮石头上用深字。
    @MainActor
    private static func finalRound(_ photos: [CollagePhotoRef], hints: [String: CollageCrop.Hints],
                                   issueBase: CollageProject, record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        print("== 验收最后一轮：字栏不压人身上、两遍深浅比总代价、大字按面积定深浅")
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 字形压在主体上超过 bodyMax 的封面字栏、开篇小字：只在照片上找不到不压人的位置时才允许（这里列出来看）。
        var onBody: [String] = []
        var named: [String] = []
        let watched: Set<String> = ["DSCF7223", "DSCF7230", "DSCF7222"]
        for t in [CollageStyleFashion.coverSans, CollageStyleFashion.coverSerifRight, CollageStyleFashion.coverFrench,
                  CollageStyleFashion.spreadOpener] {
            let overlays = t.root.cell?.overlays ?? []
            for p in photos {
                let a = applied(t, p, photos: photos, hints: hints, base: issueBase)
                for i in overlays.indices where !overlays[i].scrim && overlays[i].anchor.isSide {
                    guard let b = a.placed.indices.contains(i) ? a.placed[i] : nil else { continue }
                    guard b.onBody > CollageOverlays.bodyMax else { continue }
                    let tag = String(format: "%@ %@ 第%d块 %.0f%%", t.name.replacingOccurrences(of: "时尚刊 · ", with: ""),
                                     p.id, i + 1, b.onBody * 100)
                    onBody.append(tag)
                    if watched.contains(p.id) { named.append(tag) }
                }
            }
        }
        print("    字形压在人身上超过 \(Int(CollageOverlays.bodyMax * 100))% 的字栏（找不到不压人的位置）：\(onBody.count) 块"
              + (onBody.isEmpty ? "" : " · " + onBody.prefix(6).joined(separator: "；")))
        check(named.isEmpty, "验收点名的 7223（两款封面左栏）、7230（两栏）、7222（开篇小字）：字形不压人身上",
              named.joined(separator: "；"))
        if let p = byID["DSCF7230"] {
            let a = applied(CollageStyleFashion.coverSans, p, photos: photos, hints: hints, base: issueBase)
            let cols = a.placed.indices.filter { i in
                CollageStyleFashion.coverSans.root.cell?.overlays[i].matchTone ?? false
            }.compactMap { a.placed[$0] }
            let ok = cols.count == 2 && cols.allSatisfy { $0.onBody <= CollageOverlays.bodyMax }
            check(ok, "「刊头在后 · 无衬线」7230：两遍深浅比摆位总代价，两栏都不落在白袖子上",
                  cols.map { String(format: "%@ 压人 %.0f%%", $0.light ? "白" : "黑", $0.onBody * 100) }.joined(separator: "，"))
        }
        if let p = byID["DSCF7227"] {
            let a = applied(CollageStyleFashion.coverFrench, p, photos: photos, hints: hints, base: issueBase)
            let overlays = CollageStyleFashion.coverFrench.root.cell?.overlays ?? []
            let theme = overlays.indices.first { overlays[$0].anchor == .bottom }
            let light = theme.flatMap { a.placed.indices.contains($0) ? a.placed[$0]?.light : nil }
            check(light == false, "「法式左栏」7227：主题字压在亮石头栏杆上用深字（按面积定，不让几道深缝说了算）",
                  light.map { $0 ? "白字" : "深字" } ?? "没摆出来")
        }
    }

    /// 合成：人站满了左半边（蒙版盖住左边 0–58%）、干净的左栏 → 换到右栏；人站满整张 → 照旧在左栏（没有不压人的地方）。
    @MainActor
    private static func bodyAvoid(record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        var project = CollageProject()
        project.canvas = CollageStyleFashion.canvas
        project.style = CollageStyleFashion.style
        let frame = CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height)
        guard let column = CollageStyleFashion.coverFrench.root.cell?.overlays.first(where: { $0.anchor == .leftColumn })
        else {
            check(false, "法式左栏有左栏", "")
            return
        }
        let w = 682
        let h = 1024
        for (k, cover) in [(0, 0.58), (1, 1.0)] {
            var px = [UInt8](repeating: 0, count: w * h)
            for y in Int(Double(h) * 0.12)..<h {
                for x in 0..<Int(Double(w) * cover) { px[y * w + x] = 255 }
            }
            let f = [0.22, 0.16, 0.36, 0.26]
            var p = CollagePhotoRef(id: "synthetic-k1-bodyavoid\(k)", path: "/nonexistent/bodyavoid\(k).jpg",
                                    width: 4000, height: 6000)
            p.faces = [f]
            let mask = CollageMasks.synthetic(px, width: w, height: h, faces: [f])
            CollageMasks.inject(mask, for: p)
            var cell = CollageCell.photo(p.id, role: .hero)
            cell.overlays = [column]
            project.photos = [p]
            let placed = CollageRender.rawPlacements(cell: cell, frameRect: frame, project: project, photo: p, framing: .auto,
                                                     hints: nil, vars: ["title": "拾光", "month_cn": "三月"],
                                                     background: .white, window: nil, maxHeights: [:], mask: mask)
            guard let b = placed.first ?? nil else {
                check(false, "合成栏摆得出来（场景 \(k)）", "")
                continue
            }
            let detail = String(format: "%@ 压人 %.0f%%", b.anchor == .rightColumn ? "右栏" : "左栏", b.onBody * 100)
            if k == 0 {
                check(b.anchor == .rightColumn && b.onBody <= CollageOverlays.bodyMax && b.text.alignH == .trailing,
                      "合成：人站满左半边，左栏换到右边、右对齐、不压人", detail)
            } else {
                check(b.anchor == .leftColumn, "合成：人站满整张，没有不压人的地方：照旧在左栏（不乱跳）", detail)
            }
        }
    }

    // MARK: - 验收 final 2：别的人当障碍

    /// 字块外框（成品坐标）换成照片坐标（这一格的取景窗口）。
    private static func toPhoto(_ r: CGRect, _ c: CollageRender.CropRecord) -> CGRect? {
        CollageOverlays.Mapper(drawn: c.drawn, window: CollageCrop.Window(x: Double(c.window.minX), y: Double(c.window.minY),
                                                                           w: Double(c.window.width),
                                                                           h: Double(c.window.height))).toPhoto(r)
    }

    /// 真照片：photot 7232 右栏那儿的红马甲路人、7227 伸出来的指尖和右边的男人（验收 final 没过的两张）。
    /// 红马甲、男人的框是手量的（预览上看的，照片坐标）：只拿来验，程序里用的是 CollageMasks.otherPeople 找到的。
    @MainActor
    private static func peopleRound(_ photos: [CollagePhotoRef], hints: [String: CollageCrop.Hints],
                                    ranked: [CollageStyleFashion.HeroPick], issueBase: CollageProject,
                                    record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        print("== 验收 final 2：别的人当障碍（蒙版那一次找到的人 + 路人框）")
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let vest = CGRect(x: 0.72, y: 0.53, width: 0.13, height: 0.10)
        let man = CGRect(x: 0.80, y: 0.67, width: 0.07, height: 0.10)
        func fmt(_ b: [Double]) -> String { "[" + b.map { String(format: "%.2f", $0) }.joined(separator: " ") + "]" }
        let column = CollageStyleFashion.coverSerifRight.root.cell?.overlays.firstIndex { $0.anchor == .rightColumn }
        if let p = byID["DSCF7232"], let column {
            let mask = CollageMasks.mask(for: p)
            let people = mask?.people ?? []
            let found = people.contains { b in
                let i = vest.intersection(CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]))
                return !i.isNull && Double(i.width * i.height) >= 0.5 * Double(vest.width * vest.height)
            }
            check(found, "7232：蒙版那一次认出了右栏那儿背对镜头的红马甲路人（分块的人体姿态）", people.map(fmt).joined(separator: " "))
            let a = applied(CollageStyleFashion.coverSerifRight, p, photos: photos, hints: hints, base: issueBase)
            if let b = a.placed.indices.contains(column) ? a.placed[column] : nil, let crop = a.report.crops.first,
               let box = toPhoto(b.rect, crop) {
                let y0: Double = Double(b.rect.minY) / Double(issueBase.canvas.height) * 100
                let y1: Double = Double(b.rect.maxY) / Double(issueBase.canvas.height) * 100
                check(!box.intersects(vest) && b.onBody <= CollageOverlays.peopleTouch,
                      "「右栏衬线」7232（模板库缩略图那张）：字栏不压红马甲路人",
                      String(format: "%@ %.1f–%.1f%%H，压人最多的一行 %.0f%%", b.anchor == .rightColumn ? "右栏" : "左栏",
                             y0, y1, b.onBody * 100))
            } else {
                check(false, "「右栏衬线」7232 摆得出来", "")
            }
            // 磁盘缓存：别的人跟着蒙版一起存、一起读回来（maskVersion 2 起）。
            CollageMasks.purgeMemory()
            let again = CollageMasks.cachedMask(for: p)
            check(again?.fromDisk == true && again?.people == people,
                  "别的人跟着蒙版进磁盘缓存、读回来一样（maskVersion \(CollageMasks.maskVersion)）",
                  again.map { "\($0.people.count) 个" } ?? "读不回来")
        }
        if let p = byID["DSCF7227"], let column {
            let a = applied(CollageStyleFashion.coverSerifRight, p, photos: photos, hints: hints, base: issueBase)
            if let b = a.placed.indices.contains(column) ? a.placed[column] : nil, let crop = a.report.crops.first,
               let box = toPhoto(b.rect, crop) {
                check(!box.intersects(man) && b.onBody <= CollageOverlays.peopleTouch,
                      "「右栏衬线」7227：三月二十一日、VOL. 01 不压伸出来的指尖，也不压右边的男人（小一号 / 换到左栏）",
                      String(format: "%@ 字号 ×%.2f，压人最多的一行 %.0f%%", b.anchor == .rightColumn ? "右栏" : "左栏",
                             (b.text.lines.first?.size ?? 0) / 0.042, b.onBody * 100))
            } else {
                check(false, "「右栏衬线」7227 摆得出来", "")
            }
        }
        // 远处的小人（审查 ui/1）：7213、7214 刊头 NG 底下桥头那一群，人体框、前景实例、2×2 的姿态都没有，3×3 小块的
        // 姿态才认得出；挑主图要标「取景里有路人」（以前漏了，换封面第 3、4 次轮到它们）。那一群的范围是手量的（预览上看的，
        // 照片坐标）。反过来：7224 屋脊上的脊兽不算人；7222、7223 的取景里真没有人，不许标。
        let notesByID = Dictionary(ranked.map { ($0.photo.id, $0.notes) }, uniquingKeysWith: { a, _ in a })
        let rankOf = Dictionary(ranked.enumerated().map { ($1.photo.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        func centre(_ b: [Double]) -> CGPoint { CGPoint(x: (b[0] + b[2]) / 2, y: (b[1] + b[3]) / 2) }
        let crowds: [(String, CGRect)] = [("DSCF7213", CGRect(x: 0.72, y: 0.40, width: 0.28, height: 0.10)),
                                          ("DSCF7214", CGRect(x: 0.60, y: 0.42, width: 0.38, height: 0.10))]
        for (id, crowd) in crowds {
            guard let p = byID[id] else { continue }
            let people = CollageMasks.mask(for: p)?.people ?? []
            check(people.contains { crowd.contains(centre($0)) },
                  "\(id)：刊头 NG 底下桥头那一群远处的小人认得出来（3×3 小块的人体姿态）", people.map(fmt).joined(separator: " "))
            let notes = notesByID[id] ?? []
            check(notes.contains("取景里有路人"), "\(id)：挑主图标了「取景里有路人」",
                  "第 \(rankOf[id] ?? 0) 候选 · " + notes.joined(separator: "、"))
        }
        if let p = byID["DSCF7224"] {
            let beast = CGRect(x: 0.60, y: 0.0, width: 0.07, height: 0.12)
            let people = CollageMasks.mask(for: p)?.people ?? []
            check(!people.contains { beast.contains(centre($0)) },
                  "DSCF7224：屋脊上的脊兽不当人（小块上至少 \(CollageMasks.poseFineMinJoints) 个点）", people.map(fmt).joined(separator: " "))
        }
        for id in ["DSCF7222", "DSCF7223"] where byID[id] != nil {
            let notes = notesByID[id] ?? []
            check(!notes.contains("取景里有路人"), "\(id)：取景里没有人，不标路人（小块的姿态不乱报）",
                  "第 \(rankOf[id] ?? 0) 候选 · " + notes.joined(separator: "、"))
        }
        // 4 款封面 + 巨字开篇 × 全部照片：字栏压人最多的那一行（主体 + 别的人）超过 peopleTouch 的列出来；右栏衬线一块都不许有。
        var touching: [String] = []
        var serif: [String] = []
        for t in [CollageStyleFashion.coverSans, CollageStyleFashion.coverSerifRight, CollageStyleFashion.coverFrench,
                  CollageStyleFashion.spreadOpener] {
            let overlays = t.root.cell?.overlays ?? []
            for p in photos {
                let a = applied(t, p, photos: photos, hints: hints, base: issueBase)
                for i in overlays.indices where !overlays[i].scrim && overlays[i].anchor.isSide {
                    guard let b = a.placed.indices.contains(i) ? a.placed[i] : nil, b.onBody > CollageOverlays.peopleTouch
                    else { continue }
                    let tag = String(format: "%@ %@ 第%d块 %.0f%%", t.name.replacingOccurrences(of: "时尚刊 · ", with: ""),
                                     p.id, i + 1, b.onBody * 100)
                    touching.append(tag)
                    if t.name == CollageStyleFashion.coverSerifRight.name { serif.append(tag) }
                }
            }
        }
        print("    字栏有一行碰到人（> \(Int(CollageOverlays.peopleTouch * 100))%）：\(touching.count) 块"
              + (touching.isEmpty ? "" : " · " + touching.prefix(8).joined(separator: "；")))
        check(serif.isEmpty, "「右栏衬线」× 全部照片：字栏没有一行压在人身上（主体、别的人）", serif.joined(separator: "；"))
    }

    /// 合成：别的人站在右栏那儿（主体在中间，左边空着）。蒙版那一次找到的人、路人框两种来源都要躲；右边整条都站着人就换到
    /// 左栏；两边都站满了才压人（照旧在右栏）。顺带验姿态点估人框（只认出肩膀以上往下延躯干，认出胯只延一点）。
    @MainActor
    private static func otherPerson(record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        var project = CollageProject()
        project.canvas = CollageStyleFashion.canvas
        project.style = CollageStyleFashion.style
        let frame = CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height)
        guard let column = CollageStyleFashion.coverSerifRight.root.cell?.overlays.first(where: { $0.anchor == .rightColumn })
        else {
            check(false, "右栏衬线有右栏", "")
            return
        }
        let w = 682
        let h = 1024
        // 主体：照片横向 35–62%、12% 往下；脸在头上。
        var px = [UInt8](repeating: 0, count: w * h)
        for y in Int(Double(h) * 0.12)..<h {
            for x in Int(Double(w) * 0.35)..<Int(Double(w) * 0.62) { px[y * w + x] = 255 }
        }
        let f = [0.40, 0.15, 0.56, 0.26]
        func run(_ k: Int, people: [[Double]], bystanders: [[Double]])
            -> (placed: CollageOverlays.Placement?, geo: CollageRender.OverlayGeometry) {
            var p = CollagePhotoRef(id: "synthetic-k1-otherperson\(k)", path: "/nonexistent/otherperson\(k).jpg",
                                    width: 4000, height: 6000)
            p.faces = [f]
            let mask = CollageMasks.synthetic(px, width: w, height: h, faces: [f], people: people)
            CollageMasks.inject(mask, for: p)
            var cell = CollageCell.photo(p.id, role: .hero)
            cell.overlays = [column]
            project.photos = [p]
            let hints = CollageCrop.Hints(bystanders: bystanders)
            let placed = CollageRender.rawPlacements(cell: cell, frameRect: frame, project: project, photo: p,
                                                     framing: .auto, hints: hints,
                                                     vars: ["title": "拾光", "month_en_title": "March",
                                                            "month_cn": "三月", "day_cn": "二十一日", "issue": "01"],
                                                     background: .white, window: nil, maxHeights: [:], mask: mask)
            let geo = CollageRender.overlayGeometry(cell: cell, frameRect: frame, style: project.style, photo: p,
                                                    framing: .auto, hints: hints)
            return (placed.first ?? nil, geo)
        }
        func photoBox(_ r: CGRect, _ g: CollageRender.OverlayGeometry) -> CGRect? {
            CollageOverlays.Mapper(drawn: g.drawn, window: g.window).toPhoto(r)
        }
        func describe(_ b: CollageOverlays.Placement?) -> String {
            guard let b else { return "没摆出来" }
            let y0: Double = Double(b.rect.minY) / Double(project.canvas.height) * 100
            let y1: Double = Double(b.rect.maxY) / Double(project.canvas.height) * 100
            return String(format: "%@ %.0f–%.0f%%H 压人最多的一行 %.0f%%", b.anchor == .rightColumn ? "右栏" : "左栏",
                          y0, y1, b.onBody * 100)
        }
        // 没有别的人：右栏落在哪（之后把人放在这儿）。
        let free = run(0, people: [], bystanders: [])
        guard let base = free.placed, let spot = photoBox(base.rect, free.geo) else {
            check(false, "合成：没有别的人时右栏摆得出来", describe(free.placed))
            return
        }
        let person = [Double(spot.minX) - 0.02, Double(spot.minY) - 0.02, Double(spot.maxX) + 0.02, Double(spot.maxY) + 0.02]
        let personRect = CGRect(x: person[0], y: person[1], width: person[2] - person[0], height: person[3] - person[1])
        for (k, label, people, bystanders) in [(1, "蒙版那一次找到的人", [person], [[Double]]()),
                                               (2, "路人框（CollageCrop.Hints）", [[Double]](), [person])] {
            let r = run(k, people: people, bystanders: bystanders)
            let box = r.placed.flatMap { photoBox($0.rect, r.geo) }
            let ok = r.placed != nil && box.map { !$0.intersects(personRect) } == true
                && (r.placed?.onBody ?? 1) <= CollageOverlays.peopleTouch
            check(ok, "合成：别的人站在右栏原来的位置（\(label)）→ 字栏让开、一行都不压人", describe(r.placed))
        }
        // 右边整条都站着人 → 换到左栏（左对齐、不压人）。
        let wall = [0.64, 0.0, 1.0, 1.0]
        let flipped = run(3, people: [wall], bystanders: [])
        check(flipped.placed?.anchor == .leftColumn && flipped.placed?.text.alignH == .leading
              && (flipped.placed?.onBody ?? 1) <= CollageOverlays.peopleTouch,
              "合成：右边整条站满了人 → 换到左栏、左对齐、不压人", describe(flipped.placed))
        // 两边都站满 → 最后才压人：照旧在右栏（不乱跳）。
        let crowd = run(4, people: [wall, [0.0, 0.0, 0.36, 1.0]], bystanders: [])
        check(crowd.placed?.anchor == .rightColumn, "合成：两边都站满了人 → 实在没有地方才压人，照旧在右栏",
              describe(crowd.placed))
        // 姿态点估人框：只认出耳朵、肩膀（7232 的红马甲）往下延躯干；认出了胯的只延一点（桥上的人腿在桥栏后面）。
        typealias J = CollageMasks.Joint
        let upper: [J] = [J(name: .leftShoulder, x: 500, y: 579), J(name: .rightShoulder, x: 577, y: 576),
                          J(name: .neck, x: 538, y: 577), J(name: .rightEar, x: 543, y: 549)]
        let hips: [J] = upper + [J(name: .root, x: 540, y: 690)]
        let a = CollageMasks.poseBox(upper, width: 682, height: 1024) ?? [0, 0, 0, 0]
        let b = CollageMasks.poseBox(hips, width: 682, height: 1024) ?? [0, 0, 0, 0]
        let s = 77.0
        let wantA: Double = (579 + 1.2 * s) / 1024
        let wantB: Double = (690 + 0.3 * s) / 1024
        check(abs(a[3] - wantA) < 0.002 && abs(b[3] - wantB) < 0.002 && a[1] < 549.0 / 1024 && a[0] < 500.0 / 682,
              "姿态点估人框：只有肩膀以上往下延 1.2 个肩宽，认出胯的只延 0.3", fmtBox(a) + " / " + fmtBox(b))
    }

    private static func fmtBox(_ b: [Double]) -> String {
        "[" + b.map { String(format: "%.3f", $0) }.joined(separator: " ") + "]"
    }

    /// {masthead_short}：没填刊头、标题转出来超过 12 个字母时截短；填了的照用；短刊头字距不超过 0.45em。
    @MainActor
    private static func shortMastheads(record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        let cases: [(masthead: String, title: String, want: String)] = [
            ("", "春日庭院里的一个下午", "CHUNRI"),
            ("", "Spring Afternoon In The Garden", "SPRING"),
            ("", "拾光", "SHIGUANG"),
            ("Atelier Nord Studio", "春日庭院里的一个下午", "ATELIER NORD STUDIO"),
        ]
        let got = cases.map { CollageStyleFashion.shortMasthead($0.masthead, title: $0.title) }
        check(got == cases.map(\.want), "{masthead_short}：长中文标题取前两个字的拼音、长西文标题取第一个词、填了的照用",
              got.joined(separator: " / "))
        var project = CollageProject()
        project.title = "春日庭院里的一个下午"
        let root = CollageNode.leaf(CollageCell.photo(nil, role: .hero))
        let vars = CollageTypeset.variables(project: project, root: root, photos: [:])
        check(vars["masthead_short"] == "CHUNRI" && vars["masthead"] != "CHUNRI",
              "直接套模板也是截短的刊头（{masthead} 不变，别的风格照旧）", (vars["masthead_short"] ?? "—") + " / " + (vars["masthead"] ?? "—"))
        var line = CollageStyleFashion.masthead().text.lines[0]
        line.text = "AYA"
        let text = CollageText(lines: [line], vertical: false, alignH: .center, alignV: .leading)
        let short = CollageStyleFashion.canvas.shortSide
        let box = CGSize(width: Double(CollageStyleFashion.canvas.width) * 0.95, height: Double(CollageStyleFashion.canvas.height))
        let filled = CollageTypeset.fittingWidth(text, in: box, short: short, vars: [:])
        let track = filled.lines[0].tracking
        check(track <= CollageTypeset.spreadMax + 1e-9 && filled.lines[0].size <= line.size + 1e-9,
              "短刊头 AYA：字距 ≤ 0.45em、字号不超过上限（字高 20%H）", String(format: "字距 %.2fem", track))
    }

    @MainActor
    private static func siblings(record: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        var project = CollageProject()
        project.canvas = CollageStyleFashion.canvas
        project.style = CollageStyleFashion.style
        func block(_ anchor: CollageAnchor, _ lines: [CollageTextLine], align: CollageAlign) -> CollageOverlay {
            var o = CollageOverlay(text: CollageText(lines: lines, vertical: false, alignH: align, alignV: .leading))
            o.anchor = anchor
            o.shadow = 0.3
            o.tone = .light
            return o
        }
        let left = block(.leftColumn, [
            CollageTextLine("第{issue}期", font: .pingfang, weight: .bold, size: 0.028, tracking: 0.1, color: .white),
            CollageTextLine("春日庭院", font: .songti, weight: .bold, size: 0.05, tracking: 0.05, color: .white),
            CollageTextLine("{date_cn}", font: .pingfang, weight: .regular, size: 0.02, color: .white),
        ], align: .leading)
        let right = block(.rightColumn, [
            CollageTextLine("PORTRAIT", font: .avenir, weight: .bold, size: 0.026, tracking: 0.3, color: .white),
            CollageTextLine("92mm · f/4.5", font: .didot, weight: .regular, size: 0.03, color: .white),
        ], align: .trailing)
        let bottom = block(.bottomBand, [
            CollageTextLine("SPECIAL EDITION", font: .didot, weight: .regular, size: 0.07, tracking: 0.02, color: .white,
                            italic: true),
        ], align: .center)
        var bad: [String] = []
        var tried = 0
        for (k, f) in [[0.40, 0.18, 0.56, 0.28], [0.30, 0.25, 0.46, 0.35], [0.50, 0.22, 0.66, 0.32]].enumerated() {
            var p = CollagePhotoRef(id: "synthetic-k1-sib\(k)", path: "/nonexistent/sib\(k).jpg", width: 4000, height: 6000)
            p.faces = [f]
            CollageMasks.inject(nil, for: p)
            var cell = CollageCell.photo(p.id, role: .hero)
            cell.overlays = [CollageStyleFashion.masthead(), left, right, bottom]
            project.photos = [p]
            let frame = CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height)
            let placed = CollageRender.overlayPlacements(cell: cell, frameRect: frame, project: project, photo: p,
                                                         framing: .auto, hints: nil, vars: ["issue": "12", "date_cn": "二〇二六年三月"],
                                                         background: .white).compactMap { $0?.rect }
            tried += 1
            for i in placed.indices {
                for j in placed.indices where j > i {
                    let hit = placed[i].intersection(placed[j])
                    if !hit.isNull, hit.width > 0.5, hit.height > 0.5 { bad.append("场景\(k) 第\(i + 1)×\(j + 1)块") }
                }
            }
        }
        check(bad.isEmpty && tried == 3, "字块硬让位：刊头 + 左栏 + 右栏 + 底栏两两不重叠（3 个合成场景）", bad.joined(separator: "；"))
    }
}

private extension Double {
    func hypot(_ other: Double) -> Double { (self * self + other * other).squareRoot() }
}
