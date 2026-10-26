import Foundation
import CoreGraphics

/// 一键成套「出一期」（CollageKitID.fashionIssue，DESIGN §3 K1）：封面 + 3 张内页，3:4 单张多页（小红书轮播），
/// 四页共用刊头、期号、色调。封面挑「主图候选」：不按分数猜，按真套上封面之后的样子排（CollageCover 的决定：
/// 刊头在不在人后、挡了多少、眼睛离刊头多远、取景窗切没切脸、有没有路人、封面字压不压脸）；主图经 heroID 传进套版。
/// 内页从 distinctMoments 的保留集里挑（排除封面那张），三页景别交替：远（巨字开篇）→ 近（引语单图）→ 远（满版大片）。
/// 「换封面」= coverStep：在前 K 个候选里往后轮（当前工程已经是一期时，只换封面那张照片、其余页留着）。
///
/// 后台线程跑（CollageStore.applyKit），只读 Context、不碰界面状态；要用的路人信息、蒙版都同步拿（结果和时机无关）。
extension CollageStyleFashion {

    /// 「换封面」在前几个候选里轮。
    static let coverChoices = 5

    /// 一个主图候选：罚分（越低越好）和为什么（自测、命令行打印）。
    struct HeroPick {
        var photo: CollagePhotoRef
        var penalty: Double
        var notes: [String]
        /// 刊头那块的决定（人后 / 退回人前……）和量出来的遮挡、眼位。
        var block: CollageCover.Block?
        var window: CollageCrop.Window?
    }

    static func issue(_ context: CollageKits.Context) -> CollageProject? {
        // 托盘全是废片：照样出（是用户自己放进来的）；托盘空着、批量页这一场有照片：从这一场里拿（不要废片，
        // 全是废片就全拿）。这样只有真没照片时才返回 nil（CollageStore 已经先拦了「托盘是空的」）。
        var tray = context.tray.filter { $0.verdict != .reject }
        var borrowed: [CollagePhotoRef] = []
        if tray.isEmpty { tray = context.tray }
        if tray.isEmpty {
            let refs = context.batchItems().compactMap { CollageBridge.ref(from: $0, facts: context.facts) }
            let usable = refs.filter { $0.verdict != .reject }
            tray = usable.isEmpty ? refs : usable
            borrowed = tray
        }
        guard !tray.isEmpty else { return nil }
        var hints = context.hints
        for p in tray where hints[p.id] == nil { hints[p.id] = CollageVision.hints(for: p) }
        let base = issueBase(context.project)
        let ranked = heroCandidates(tray, hints: hints, base: base)
        let choices = Array(ranked.prefix(coverChoices))
        // 换封面：当前工程已经是一期（第一页是人后刊头的封面格）→ 从它现在那张往后轮，其余页留着（用户改过的字都在）。
        if context.coverStep > 0, let current = coverPhotoID(context.project), !choices.isEmpty {
            let at = choices.firstIndex { $0.photo.id == current } ?? -1
            let next = choices[((at + context.coverStep) % choices.count + choices.count) % choices.count].photo
            return swapCover(context.project, to: next, from: current, tray: tray, hints: hints)
        }
        // 没有能压刊头的候选（全是合影、认不出主体……）：照样出，封面用分数最高的（刊头会退回人前，原因在检视器里）。
        let fallback = tray.max { $0.score == $1.score ? $0.id > $1.id : $0.score < $1.score }
        // 余数照上面换封面那样折成非负（命令行 --cover-step -1 / nextcover:-1：Swift 的 % 带符号，-1 % 5 = -1 会越界）。
        let n = choices.count
        let rank = n == 0 ? 0 : ((context.coverStep % n) + n) % n
        guard let hero = choices.isEmpty ? fallback : choices[rank].photo else { return nil }

        var project = base
        for p in borrowed where !project.photos.contains(where: { $0.id == p.id }) { project.photos.append(p) }
        let map = Dictionary(tray.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func page(_ template: CollageTemplate, _ photo: CollagePhotoRef) -> CollagePage {
            let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map, hints: hints,
                                            heroID: photo.id)
            return CollageTemplates.apply(template, photos: [photo], context: ctx, seed: context.seed)
        }
        var pages = [page(coverSans, hero)]
        for (template, photo) in interiors(tray, hero: hero, hints: hints, base: base) {
            pages.append(page(template, photo))
        }
        project.pages = pages
        return project
    }

    /// 一期共用的东西：3:4 画布、时尚刊样式（用户自己设过色调就留着）、单张多页；刊头、标题、水印跟着当前工程。
    /// 期号空着时定成 01（不然 {issue} 退回页码，封面、内页各印各的期号）。
    static func issueBase(_ current: CollageProject) -> CollageProject {
        var project = current
        project.mode = .single
        project.canvas = canvas
        var s = style
        if current.style.look != .none {
            s.look = current.style.look
            s.lookStrength = current.style.lookStrength
        }
        project.style = s
        if project.issue.trimmingCharacters(in: .whitespaces).isEmpty { project.issue = "01" }
        // 没填刊头、标题又长：刊头定成截短的那个（shortMasthead，检视器里看得到、改得了）；填了刊头、标题不长的照旧。
        // 模板里的刊头、folio 本来就印 {masthead_short}，直接套模板也是这个字。
        if project.masthead.trimmingCharacters(in: .whitespaces).isEmpty {
            let title = project.title.trimmingCharacters(in: .whitespaces)
            let named = title.isEmpty ? "拾光" : title
            let short = shortMasthead("", title: named)
            if !short.isEmpty, short != CollageTypeset.mastheadText("", title: named) { project.masthead = short }
        }
        project.pages = []
        return project
    }

    /// 刊头最多几个字母还像刊头（R1：长刊名 10–13%H；12 个字母的 Bodoni 铺满一行约 8%H）。
    static let mastheadMaxLetters = 12

    /// {masthead_short}（时尚刊的刊头、folio 印它；CollageTypeset.variables 里算）：填了刊头照用（转大写，不截）；
    /// 没填按标题生成（同 {masthead}），生成出来超过 mastheadMaxLetters 个字母（不算空格）就截短 —— 中文标题取前两个字的
    /// 拼音（「春日庭院里的一个下午」转出 27 个字母，铺满一行只剩 5%H 高 → CHUNRI），西文标题取第一个词（还长就照旧）。
    static func shortMasthead(_ masthead: String, title: String) -> String {
        let full = CollageTypeset.mastheadText(masthead, title: title)
        guard masthead.trimmingCharacters(in: .whitespaces).isEmpty else { return full }
        guard full.filter({ !$0.isWhitespace }).count > mastheadMaxLetters else { return full }
        let t = title.trimmingCharacters(in: .whitespaces)
        let latin = t.range(of: "[A-Za-z]", options: .regularExpression) != nil
        let short: String
        if latin {
            short = full.split(separator: " ").first.map(String.init) ?? full
        } else {
            short = CollageTypeset.mastheadText("", title: String(t.prefix(2)))
        }
        guard !short.isEmpty, short.count <= mastheadMaxLetters else { return full }
        return short
    }

    /// 当前工程是不是一期、封面是哪张：第一页是一格照片、带人后的刊头（出一期的封面、或者套了时尚刊封面模板）。
    static func coverPhotoID(_ project: CollageProject) -> String? {
        guard let first = project.pages.first, first.contactSheet == nil, !first.freeform,
              let cell = first.root.cell, cell.kind == .photo,
              cell.overlays.contains(where: isMasthead) else { return nil }
        return cell.photoID
    }

    /// 封面的刊头：人后、定在上方、一行铺满宽度的大字（巨字开篇的人后巨字定在中间，不算：只有它的单页不是封面）。
    static func isMasthead(_ o: CollageOverlay) -> Bool {
        o.layer == .behindSubject && o.anchor.cell?.row == 0 && o.text.lines.contains { $0.fitWidth }
    }

    /// 只换封面那张：新的那张要是在内页上，就和旧封面对调（同一张不出现两次），裁切复位（封面取景自己定）。
    /// 对调过去的旧封面再按那一页真的格子量一遍（refill）：放不好就换一张托盘里没上这一期的。
    private static func swapCover(_ current: CollageProject, to next: CollagePhotoRef, from old: String,
                                  tray: [CollagePhotoRef], hints: [String: CollageCrop.Hints]) -> CollageProject {
        var project = current
        guard next.id != old else { return project }
        var receiver: Int?
        for i in project.pages.indices {
            var root = project.pages[i].root
            for path in root.leafPaths() {
                guard let cell = root.node(at: path)?.cell, cell.kind == .photo else { continue }
                if i == 0, path.isEmpty, cell.photoID == old {
                    root.update(at: path) { node in
                        node.cell?.photoID = next.id
                        node.cell?.crop = nil
                    }
                } else if i > 0, cell.photoID == next.id {
                    root.update(at: path) { node in
                        node.cell?.photoID = old
                        node.cell?.crop = nil
                    }
                    receiver = i
                }
            }
            project.pages[i].root = root
        }
        if !project.photos.contains(where: { $0.id == next.id }) { project.photos.append(next) }
        if let i = receiver { refill(&project, page: i, old: old, displaced: next, tray: tray, hints: hints) }
        return project
    }

    /// 对调过去的旧封面在那一页罚分到这么多（取景里有路人 1.5、切脸 3、人后的大字退回人前 3）就算放不好。
    static let swapFitLimit = 1.5

    /// 换封面对调到内页的旧封面：封面取景里躲开的路人，到了满宽的内页又进了画面（7232 换到巨字开篇，红马甲、白衬衫
    /// 都在 H 下面）—— 按这一页真的格子量一遍（fitPenalty），放不好（≥ swapFitLimit）就从托盘里没上这一期的照片里
    /// 挑一张量出来放得好（< swapFitLimit）、分数加罚分比旧封面低的换上（同 interiors 的挑法：分数、精选、竖图、有脸，
    /// 景别和原来这一页那张一样的优先）。没有更好的照旧对调；同一张照样不出现两次。
    private static func refill(_ project: inout CollageProject, page i: Int, old: String, displaced: CollagePhotoRef,
                               tray: [CollagePhotoRef], hints: [String: CollageCrop.Hints]) {
        var map = Dictionary(project.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in tray { map[p.id] = p }
        guard let oldRef = map[old], project.pages.indices.contains(i) else { return }
        let page = project.pages[i]
        let paths = page.root.leafPaths().filter { page.root.node(at: $0)?.cell?.photoID == old }
        guard !paths.isEmpty else { return }
        let bucket = CollageSelect.scaleBucket(displaced)
        let snapshot = project
        func placed(_ p: CollagePhotoRef) -> CollageProject {
            var trial = snapshot
            var root = page.root
            for path in paths {
                root.update(at: path) { node in
                    node.cell?.photoID = p.id
                    node.cell?.crop = nil
                }
            }
            trial.pages[i].root = root
            if !trial.photos.contains(where: { $0.id == p.id }) { trial.photos.append(p) }
            return trial
        }
        func cost(_ p: CollagePhotoRef) -> (fit: Double, total: Double) {
            let trial = placed(p)
            let fit = fitPenalty(page: trial.pages[i], photo: p, project: trial, hints: hints, map: map)
            var total: Double = fit - p.score
            if p.isPick { total -= 0.3 }
            if !p.isPortrait { total += 0.8 }
            if p.faces.filter(CollageCrop.isValidBox).isEmpty { total += 0.5 }
            if CollageSelect.scaleBucket(p) != bucket { total += 1.2 }
            return (fit, total)
        }
        let mine = cost(oldRef)
        guard mine.fit >= swapFitLimit else { return }
        let used = Set(project.pages.flatMap(\.photoIDs))
        var best: (p: CollagePhotoRef, total: Double)?
        for p in tray.sorted(by: { $0.id < $1.id }) where !used.contains(p.id) && p.verdict != .reject {
            let c = cost(p)
            guard c.fit < swapFitLimit, c.total < mine.total else { continue }
            if best == nil || c.total < best!.total - 1e-9 { best = (p, c.total) }
        }
        guard let chosen = best?.p else { return }
        project = placed(chosen)
    }

    // MARK: - 挑主图

    /// 取景里有路人：Vision 的人框（Hints.bystanders）或者蒙版另外认出来的人（Mask.people）压进了取景框。
    /// 封面格的取景 CollageCover 已经标过（markPeople）；内页不走封面取景的格子在这里补问一次蒙版。
    static func hitsPeople(_ w: CollageCrop.Window, _ p: CollagePhotoRef) -> Bool {
        if w.hitsBystander { return true }
        guard w.w > 0, let people = CollageMasks.mask(for: p)?.people, !people.isEmpty else { return false }
        return CollageCrop.overlap(w.rect, people) > 0.0005
    }

    /// 主图候选，罚分从低到高（同分按 id，顺序是定的）。先筛掉不能当封面的：没有脸或 3 张脸以上（合影不做人物挡字）、
    /// 闭眼、废片、认不出主体（没有蒙版）。剩下的每张真套一次封面（coverSans），按 CollageCover 的决定和摆位打分。
    static func heroCandidates(_ tray: [CollagePhotoRef], hints: [String: CollageCrop.Hints],
                               base: CollageProject) -> [HeroPick] {
        var picks: [HeroPick] = []
        let map = Dictionary(tray.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in tray {
            let faces = p.faces.filter(CollageCrop.isValidBox)
            guard (1...2).contains(faces.count), p.eyesOpen != false, p.verdict != .reject,
                  CollageMasks.mask(for: p) != nil else { continue }
            picks.append(evaluate(p, hints: hints, base: base, map: map))
        }
        // 眼睛离刊头远（照片下沿卡住、天不够、脸太大：DESIGN 要基线下 0–8%H）的排在所有合规的后面：
        // 有合规的就不会挑它当封面，全不合规时才按罚分轮到它。
        return picks.sorted { a, b in
            let fa = a.block?.eyeFar ?? false
            let fb = b.block?.eyeFar ?? false
            if fa != fb { return !fa }
            return a.penalty == b.penalty ? a.photo.id < b.photo.id : a.penalty < b.penalty
        }
    }

    /// 套上封面看一眼：罚分 + 原因。
    static func evaluate(_ p: CollagePhotoRef, hints: [String: CollageCrop.Hints], base: CollageProject,
                         map: [String: CollagePhotoRef]) -> HeroPick {
        var project = base
        let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map, hints: hints,
                                        heroID: p.id)
        let page = CollageTemplates.apply(coverSans, photos: [p], context: ctx)
        project.pages = [page]
        var notes: [String] = []
        var penalty = 0.0
        // 照片本身：分数高、精选优先；竖图配 3:4；景别中近（全身远景的脸太小，拉近要放大）；两个人扣一点。
        penalty -= p.score
        if p.isPick { penalty -= 0.4 }
        if !p.isPortrait {
            penalty += 2
            notes.append("横图放进 3:4")
        }
        if CollageSelect.scaleBucket(p) == 0 {
            penalty += 0.6
            notes.append("全身远景")
        }
        if p.faces.filter(CollageCrop.isValidBox).count == 2 {
            penalty += 1
            notes.append("两个人")
        }
        let geo = CollageLayout.pageGeometry(page.root, canvas: project.canvas, style: project.style)
        guard let frame = geo.frames.first(where: { $0.cell.kind == .photo }) else {
            return HeroPick(photo: p, penalty: penalty + 20, notes: notes + ["套不上"], block: nil, window: nil)
        }
        let rect = frame.rect.cgRect
        let vars = CollageTypeset.cellVariables(
            CollageTypeset.variables(project: project, root: page.root, photos: map, pageID: page.id), photo: p)
        let bg = project.style.background
        guard let decided = CollageCover.resolve(cell: frame.cell, frameRect: rect, project: project, photo: p,
                                                 framing: frame.cell.framing, hints: hints[p.id], vars: vars,
                                                 background: bg) else {
            return HeroPick(photo: p, penalty: penalty + 20, notes: notes + ["定不了封面取景"], block: nil, window: nil)
        }
        let w = decided.window
        let block = decided.blocks.first ?? nil
        if let block {
            if block.layer != .behindSubject {
                penalty += 10
                notes.append("刊头退回人前")
            } else {
                let total = block.occlusion?.total ?? 0
                if total < 0.04 {
                    penalty += 3
                    notes.append(String(format: "头没压进刊头（%.0f%%）", total * 100))
                } else {
                    penalty += 4 * abs(total - 0.14)
                }
                if block.step != .behind {
                    penalty += 0.5
                    notes.append("退让：\(block.step.rawValue)")
                }
            }
            // 眼睛离刊头基线的理想是 0–8% 格高；照片下沿卡住（竖 2:3 放进 3:4 常见）、天不够都算远。
            if let e = block.eyeBelow, e > CollageCover.eyeFarBelow {
                penalty += 20 * (e - CollageCover.eyeFarBelow)
                notes.append(String(format: "眼睛在刊头基线下 %.0f%%", e * 100) + (block.eyeClamp.map { "（\($0)）" } ?? ""))
            }
            if block.eyeClamp == "top" { penalty += 1 }
        }
        if w.cutsFace {
            penalty += 6
            notes.append("取景切脸")
        }
        if hitsPeople(w, p) {
            penalty += 2.5
            notes.append("取景里有路人")
        }
        let up = CollageCrop.upscale(photo: p, window: w, drawn: rect)
        if up > 1.0 {
            penalty += 3 * (up - 1)
            notes.append(String(format: "放大 %.2f 倍", up))
        }
        // 封面字（人前的字块）压脸：摆位本来就躲脸，躲不开说明脸太大或太偏。
        let placed = CollageRender.overlayPlacements(cell: frame.cell, frameRect: rect, project: project, photo: p,
                                                     framing: frame.cell.framing, hints: hints[p.id], vars: vars,
                                                     background: bg)
        let faceBoxes = CollageCrop.faceBoxes(photo: p, window: w, in: rect)
        for (i, placement) in placed.enumerated() where i > 0 {
            guard let r = placement?.rect else { continue }
            if faceBoxes.contains(where: { $0.intersects(r) }) {
                penalty += 5
                notes.append("封面字压脸")
                break
            }
        }
        return HeroPick(photo: p, penalty: penalty, notes: notes, block: block, window: w)
    }

    // MARK: - 内页

    /// 三张内页：巨字开篇（远景竖图，巨字压得进人后）→ 引语单图（中近景竖图，窄高的格子）→ 满版大片（远景，
    /// 和开篇不同一场优先）。从 distinctMoments 的保留集里挑（同一瞬间只留一张），排除封面；不够再从去掉的里补。
    static func interiors(_ tray: [CollagePhotoRef], hero: CollagePhotoRef, hints: [String: CollageCrop.Hints],
                          base: CollageProject) -> [(CollageTemplate, CollagePhotoRef)] {
        let moments = CollageSelect.distinctMoments(tray)
        var pool = moments.kept.filter { $0.id != hero.id }
        pool += moments.dropped.filter { $0.id != hero.id }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        let keptIDs = Set(moments.kept.map(\.id))
        var used: Set<String> = [hero.id]
        var takes: Set<Int> = []
        if let t = hero.take { takes.insert(t) }
        var out: [(CollageTemplate, CollagePhotoRef)] = []
        let map = Dictionary(tray.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        /// wide = 要远景（全身）；false = 要中近景。罚分：分数、精选、保留集、竖图、景别、同一场。
        func pick(_ template: CollageTemplate, wide: Bool, extra: (CollagePhotoRef) -> Double = { _ in 0 })
            -> CollagePhotoRef? {
            var best: (p: CollagePhotoRef, v: Double)?
            for p in pool where !used.contains(p.id) {
                var v = -p.score
                if p.isPick { v -= 0.3 }
                if !keptIDs.contains(p.id) { v += 1.5 }
                if !p.isPortrait { v += 0.8 }
                if p.faces.filter(CollageCrop.isValidBox).isEmpty { v += 0.5 }
                let bucket = CollageSelect.scaleBucket(p)
                if wide != (bucket == 0) { v += 1.2 }
                if let t = p.take, takes.contains(t) { v += 0.4 }
                // 和已经上了的同地同姿势（distinctMoments 的 similar）：四页像一张照片的连拍就不像一期了。
                if !(moments.similar[p.id] ?? []).isDisjoint(with: used) { v += 1 }
                v += extra(p)
                if best == nil || v < best!.v - 1e-9 || (abs(v - best!.v) < 1e-9 && p.id < best!.p.id) { best = (p, v) }
            }
            guard let chosen = best?.p else { return nil }
            used.insert(chosen.id)
            if let t = chosen.take { takes.insert(t) }
            out.append((template, chosen))
            return chosen
        }
        // 每一页都真套一次看取景（脸在格子中间、没切脸）；巨字开篇还要巨字真能压到人后面（装饰大字只限总量）。
        for (template, wide) in [(spreadOpener, true), (spreadQuote, false), (spreadFull, true)] {
            _ = pick(template, wide: wide) { p in
                fitPenalty(template, photo: p, hints: hints, base: base, map: map)
            }
        }
        return out
    }

    /// 这张照片套进这一页好不好看：取景切了脸 +3；主脸中心离格子中线超过格宽 15%（窄高的引语格里，避路人把人
    /// 推到格子边上）按超出多少扣；有人后的巨字、最后退回人前了 +3。
    private static func fitPenalty(_ template: CollageTemplate, photo p: CollagePhotoRef,
                                   hints: [String: CollageCrop.Hints], base: CollageProject,
                                   map: [String: CollagePhotoRef]) -> Double {
        var project = base
        let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map, hints: hints,
                                        heroID: p.id)
        let page = CollageTemplates.apply(template, photos: [p], context: ctx)
        project.pages = [page]
        return fitPenalty(page: page, photo: p, project: project, hints: hints, map: map)
    }

    /// 同上，量的是现成的一页（project 里的这一页，照片已经放进格子里了：换封面对调到内页时用；自检也调它）。
    static func fitPenalty(page: CollagePage, photo p: CollagePhotoRef, project: CollageProject,
                                   hints: [String: CollageCrop.Hints], map: [String: CollagePhotoRef]) -> Double {
        let geo = CollageLayout.pageGeometry(page.root, canvas: project.canvas, style: project.style)
        let photoFrames = geo.frames.filter { $0.cell.kind == .photo }
        guard let frame = photoFrames.first(where: { $0.cell.photoID == p.id }) ?? photoFrames.first else { return 3 }
        let rect = frame.rect.cgRect
        let vars = CollageTypeset.cellVariables(
            CollageTypeset.variables(project: project, root: page.root, photos: map, pageID: page.id), photo: p)
        let bg = project.style.background
        var v = 0.0
        let w = CollageRender.cellWindow(cell: frame.cell, frameRect: rect, project: project, photo: p,
                                         framing: frame.cell.framing, hints: hints[p.id], vars: vars, background: bg)
        if w.cutsFace { v += 3 }
        // 取景里有路人（桥上的人）：内页也排后面一点（封面那张罚 2.5，内页轻一点）。
        if hitsPeople(w, p) { v += 1.5 }
        if let f = p.faces.first(where: CollageCrop.isValidBox), w.w > 0 {
            let centre: Double = ((f[0] + f[2]) / 2 - w.x) / w.w
            v += 10 * max(0, abs(centre - 0.5) - 0.15)
        }
        if frame.cell.overlays.contains(where: { $0.layer == .behindSubject }) {
            let decided = CollageCover.resolve(cell: frame.cell, frameRect: rect, project: project, photo: p,
                                               framing: frame.cell.framing, hints: hints[p.id], vars: vars,
                                               background: bg)
            let block = decided?.blocks.first ?? nil
            if block?.layer != .behindSubject { v += 3 }
        }
        return v
    }
}
