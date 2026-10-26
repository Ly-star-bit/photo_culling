import Foundation

/// 「底片印样」风格：底片条（社交）+ 印样（135 / 6×6）。规格见 reports/杂志风格调研_2026-10-23/DESIGN.md §3 K2。
///
/// 注册钩子：templates 按 CollageTemplates.builtin 里的位置进模板库（category 写「底片印样」）；presets 拼在
/// CollageStyles.all 末尾。模板名全库唯一，模板名、分类名都不能包含别的分类名（--template-sheet --only、
/// 门禁按「包含」匹配）。积木用 CollageTemplates.photo / row / col / text，样式用 CollageStyles.make { s in … } ——
/// 这里的 static let 里别读 CollageStyles.all / preset(…) 和 CollageTemplates.builtin / find(…)：它们正拼着这两个
/// 数组，回头读自己会在初始化时卡死。只改这个文件（和同前缀的新文件），地基要改的在交付报告里单独列出。
/// 不预置任何真实刊名、胶片 / 滤镜品牌名（DESIGN.md §0.4）：片边只印 SAFETY FILM、ISO、帧号、▶。
///
/// 画法全在 CollageContact（整页按片条画），这里只定规格：
/// - 底片条（社交，3:4 / 1:1）：放在纸上的一条条实物（带投影），一页只圈一个（社交图上帧帧都圈一眼假，R2 §10）；
///   照片比格子多时每场挑一张最好的（choice = best），竖着放的条挑竖片（人在条上是立着的，别的场有立着的就不上躺着的）。
/// - 印样（A4 300dpi）：白相纸上一块黑场、7 条 × 5 帧 / 4 条 × 3 帧，托盘按拍摄先后从头印（choice = roll），
///   每场最好的精选红圈，废片打叉，白边红笔手写卷号、日期、文件号。
enum CollageStyleFilm {

    // MARK: - 纸和画布

    /// 印样的白相纸、底片条的纸（和检视器里那几张同一组颜色，CollageContact.papers）。
    private static let whitePaper = CollageContact.papers[0].color
    private static let beigePaper = CollageContact.papers[1].color
    private static let darkPaper = CollageContact.papers[2].color

    private static let social34 = CollageCanvas.social[0]
    private static let social11 = CollageCanvas.social[1]
    private static let a4 = CollageCanvas.social.first { $0.isPrint } ?? CollageCanvas.social[0]

    /// 纸的样式：只有底色和一点纸纹（印样每帧保留各自的曝光，不套色调、不统一色调，R2 §3）。
    private static func paperStyle(_ paper: CollageColor, grain: Double) -> CollageStyle {
        CollageStyles.make { s in
            s.background = paper
            s.backgroundMode = .solid
            s.grain = grain
            s.margin = 0.05
            s.tightSmallCells = false
        }
    }

    /// 底片条：社交图上放在纸上的一条条，带投影；一页只圈一个（这一页最好的精选），照片多时每场挑一张（立着的优先）。
    private static func strip(_ format: CollageFilmFormat, perStrip: Int, strips: Int, tilt: Double,
                              pen: CollageColor, paper: CollageColor, fill: Bool, margin: Double) -> CollageContactSheet {
        var sheet = CollageContactSheet(format: format, layout: .strip, perStrip: perStrip, strips: strips)
        sheet.tilt = tilt
        sheet.markColor = pen
        sheet.paper = paper
        sheet.fillFrames = fill
        sheet.maxCircles = 1
        sheet.choice = .best
        sheet.margin = margin
        return sheet
    }

    /// 印样：白相纸、红笔；每场最好的精选圈（一页最多 circles 个：135 整卷 6 个 = R2 §7；12 帧的 6×6 三个 ——
    /// 圈是帧的 1.4 倍，方画幅一页圈到一半就是满版的红圈，R2 §6「一张印样通常只标 1–3 个」），废片打叉，
    /// 托盘按拍摄先后从头印。
    private static func proof(_ format: CollageFilmFormat, perStrip: Int, strips: Int, fill: Bool,
                              circles: Int) -> CollageContactSheet {
        var sheet = CollageContactSheet(format: format, layout: .sheet, perStrip: perStrip, strips: strips)
        sheet.markColor = CollagePencilMark.red
        sheet.maxCircles = circles
        sheet.paper = whitePaper
        sheet.fillFrames = fill
        sheet.choice = .roll
        sheet.margin = 0.05
        return sheet
    }

    // MARK: - 模板

    static let templates: [CollageTemplate] = [
        // 深色底上竖着的一条 135、三帧：竖片转回来正好立着（帧从下往上 1、2、3），白色油性笔圈一张，
        // 下面白笔手写卷号日期。3:4 上一条三帧放竖的比横的大一倍（横条的帧只有 349 px 宽）。
        CollageTemplate(
            name: "底片条 · 三帧",
            root: .leaf(CollageCell()),
            style: paperStyle(darkPaper, grain: 0.16), canvas: social34,
            fitAspects: false, builtin: true, category: "底片印样",
            contactSheet: strip(.f135, perStrip: 3, strips: 1, tilt: -90, pen: CollagePencilMark.white,
                                paper: darkPaper, fill: false, margin: 0.045)),
        // 米色纸上斜放的一条 135、四帧（朝右上斜 74°，比竖放长出一帧），红笔圈一张，片条带投影。
        CollageTemplate(
            name: "底片条 · 斜放",
            root: .leaf(CollageCell()),
            style: paperStyle(beigePaper, grain: 0.3), canvas: social34,
            fitAspects: false, builtin: true, category: "底片印样",
            contactSheet: strip(.f135, perStrip: 4, strips: 1, tilt: -74, pen: CollagePencilMark.red,
                                paper: beigePaper, fill: false, margin: 0.05)),
        // 1:1 上三条 6×6（120，没有齿孔）、每条三帧：方画幅按人脸取景裁满（3:2 的照片放进方框加黑边就像一排 135
        // 竖片，S4b 样张 02b），一页圈一张。
        CollageTemplate(
            name: "底片条 · 方片",
            root: .leaf(CollageCell()),
            style: paperStyle(whitePaper, grain: 0.12), canvas: social11,
            fitAspects: false, builtin: true, category: "底片印样",
            contactSheet: strip(.f66, perStrip: 3, strips: 3, tilt: 0, pen: CollagePencilMark.red,
                                paper: whitePaper, fill: true, margin: 0.03)),
        // A4 300dpi：7 条 × 5 帧 = 35 帧（Print File 35-7B 那种 8×10 印样的排法，R2 §5），竖片转 90° 躺在条里，
        // 比例不符加黑边不裁（印样是选片用的，不能替摄影师裁）。
        CollageTemplate(
            name: "印样 · 135 整卷",
            root: .leaf(CollageCell()),
            style: paperStyle(whitePaper, grain: 0), canvas: a4,
            fitAspects: false, builtin: true, category: "底片印样",
            contactSheet: proof(.f135, perStrip: 5, strips: 7, fill: false, circles: 6)),
        // A4 300dpi：4 条 × 3 帧 = 12 帧（一卷 120 的 6×6，R2 §4）。方画幅裁满（按人脸取景）：挑 6×6 就是要方片的样子，
        // 不想裁的在检视器关掉「裁满画幅」。
        CollageTemplate(
            name: "印样 · 6×6",
            root: .leaf(CollageCell()),
            style: paperStyle(whitePaper, grain: 0), canvas: a4,
            fitAspects: false, builtin: true, category: "底片印样",
            contactSheet: proof(.f66, perStrip: 3, strips: 4, fill: true, circles: 3)),
    ]

    static let presets: [CollageStyles.Preset] = []

    // MARK: - 一键成套：按卷出印样

    /// 一卷（一页）：第几卷、这一卷分成几页里的第几页、帧（按拍摄先后）、规格。
    struct Roll {
        var number: Int
        var part: Int
        var parts: Int
        var format: CollageFilmFormat
        var frames: [CollagePhotoRef]
    }

    /// 一页印样的格子：135 = 7 条 × 5 帧（35，R2 §5）；6×4.5 = 4 × 4（16 = 一卷）；6×6 = 4 条 × 3 帧（12 = 一卷）；
    /// 6×7 = 4 条 × 3 帧（一卷 10 张：3、3、3、1，R2 §4 的「3 条 × 3 张剩 1 张」）。
    static func grid(_ format: CollageFilmFormat) -> (perStrip: Int, strips: Int) {
        switch format {
        case .f135: return (5, 7)
        case .f645: return (4, 4)
        case .f66, .f67: return (3, 4)
        }
    }

    /// 一页最多几帧：格子数和一卷的长度里小的那个（135 一页 35，6×7 一页一卷 10 张）。
    static func pageCapacity(_ format: CollageFilmFormat) -> Int {
        let g = grid(format)
        return min(g.perStrip * g.strips, format.rollLength)
    }

    /// 按卷分（纯函数，自检直接喂合成数据）：
    /// - 一个章节一卷；同一章节里有两台以上机身时每台一卷（真的胶片一台相机一卷：两台机器的帧按时间交错排进
    ///   一卷，同一场的帧就不挨着了）；卷按开拍时间排，卷号 1、2、3…；
    /// - 卷内按（拍摄时间, 小数秒, 帧号）排（CollageContact.rollOrder）；规格按这一卷多数照片的比例
    ///   （3:2 → 135，4:3 → 6×4.5，1:1 → 6×6，5:4 → 6×7）；
    /// - 一页放不下（135 超过 35 帧）分成 n/N 页，不抽帧；切口尽量落在场与场之间：最后两条里有场的分界就在那儿切
    ///   （同一场在一页上才好比），没有就照满页切（一场 20 帧以上的连拍本来就要跨页）。
    static func rolls(_ photos: [CollagePhotoRef]) -> [Roll] {
        struct Group {
            var chapter: Int
            var body: String
            var frames: [CollagePhotoRef]
        }
        var groups: [Group] = []
        var index: [String: Int] = [:]
        // 一个章节里有几台机身：只有一台的时候不按机身分（外部文件没有机身 = 一台）。
        var bodiesByChapter: [Int: Set<String>] = [:]
        for p in photos { bodiesByChapter[p.chapter ?? 0, default: []].insert(p.body ?? "") }
        for p in photos {
            let chapter = p.chapter ?? 0
            let body = (bodiesByChapter[chapter]?.count ?? 0) > 1 ? (p.body ?? "") : ""
            let key = "\(chapter)|\(body)"
            if let i = index[key] {
                groups[i].frames.append(p)
            } else {
                index[key] = groups.count
                groups.append(Group(chapter: chapter, body: body, frames: [p]))
            }
        }
        for i in groups.indices { groups[i].frames = CollageContact.rollOrder(groups[i].frames) }
        groups.sort { a, b in
            let ta = a.frames.compactMap(\.captureTime).min()
            let tb = b.frames.compactMap(\.captureTime).min()
            switch (ta, tb) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if a.chapter != b.chapter { return a.chapter < b.chapter }
            return a.body < b.body
        }
        var out: [Roll] = []
        for (n, group) in groups.enumerated() {
            let format = CollageContact.suggestedFormat(group.frames)
            let chunks = split(group.frames, capacity: pageCapacity(format), perStrip: grid(format).perStrip)
            for (k, chunk) in chunks.enumerated() {
                out.append(Roll(number: n + 1, part: k + 1, parts: chunks.count, format: format, frames: chunk))
            }
        }
        return out
    }

    /// 一卷切成几页：每页最多 capacity 帧；放不下时切口往前找场与场的分界（不早于倒数第二条的开头），找不到就切满。
    static func split(_ frames: [CollagePhotoRef], capacity: Int, perStrip: Int) -> [[CollagePhotoRef]] {
        guard capacity > 0, frames.count > capacity else { return frames.isEmpty ? [] : [frames] }
        var out: [[CollagePhotoRef]] = []
        var rest = frames[...]
        while rest.count > capacity {
            let start = rest.startIndex
            var cut = start + capacity
            let earliest = start + max(1, capacity - perStrip * 2)
            var k = cut
            while k > earliest {
                if CollageContact.takeKey(frames[k - 1]) != CollageContact.takeKey(frames[k]) {
                    cut = k
                    break
                }
                k -= 1
            }
            out.append(Array(rest[start..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { out.append(Array(rest)) }
        return out
    }

    /// 这一卷的一页印样。inherit = 当前工程里已有的印样（layout = 印样的那一页，见 roll）的设置（打不打叉、
    /// 圈不圈、片边字、ISO……）：在检视器里调过、再点一次「按卷出印样」时照着来（废片打叉就是这样关的）。
    /// 笔色只在白相纸上还是一支笔时照着来（fitPen：白笔、黄笔写在白相纸上注记得换墨色，换回红笔）。
    /// 片边的 ISO 还是默认的 400 时印这一卷 EXIF 的 ISO（都一样的话，CollageContact.rollISO）。
    static func page(_ roll: Roll, inherit: CollageContactSheet?) -> CollagePage {
        let g = grid(roll.format)
        var sheet = CollageContactSheet(format: roll.format, layout: .sheet, perStrip: g.perStrip, strips: g.strips)
        sheet.markColor = CollagePencilMark.red
        if let inherit {
            sheet.markColor = inherit.markColor
            sheet.marks = inherit.marks
            sheet.crossRejects = inherit.crossRejects
            sheet.edgeText = inherit.edgeText
            sheet.iso = inherit.iso
            sheet.edgePrint = inherit.edgePrint
            sheet.jitter = inherit.jitter
            sheet.uprightPortraits = inherit.uprightPortraits
        }
        sheet.layout = .sheet
        sheet.paper = whitePaper
        CollageContact.fitPen(&sheet)
        if sheet.iso == CollageContactSheet().iso, let iso = CollageContact.rollISO(roll.frames) { sheet.iso = iso }
        sheet.choice = .roll
        // 成套是选片结果的记录：每一场最好的那张都圈（不按 R2 的「一页最多 6 个」截）。
        sheet.maxCircles = 0
        sheet.roll = roll.number
        sheet.note = roll.parts > 1
            ? "ROLL {roll} · \(roll.part)/\(roll.parts) · {date} · {first}–{last}"
            : "ROLL {roll} · {date} · {first}–{last}"
        sheet.frames = roll.frames.map(\.id)
        var page = CollagePage(root: .leaf(CollageCell()))
        page.contactSheet = sheet
        return page
    }

    /// 一键成套 kit：按卷出印样（CollageKitID.contactRoll）。
    /// 读批量页这个场次的**全部**帧（含废片：印样就是整卷），托盘里有的用托盘那份（按批量页的现状刷新），
    /// 没有的现建 ref 加进新工程的托盘；没开批量页（外部文件）= 托盘就是这一卷。A4 300dpi、单张多页、一卷一页。
    /// 圈、叉都是渲染器按判决现画的（CollageContact.marks）：每场最好的精选（手动的优先）红圈，没有精选的场不圈，
    /// 单帧的场只有精选才圈，废片打叉。
    static func roll(_ context: CollageKits.Context) -> CollageProject? {
        var trayByID: [String: CollagePhotoRef] = [:]
        for p in context.tray where trayByID[p.id] == nil { trayByID[p.id] = p }
        let items = context.batchItems()
        var refs: [CollagePhotoRef] = []
        if items.isEmpty {
            refs = context.tray
        } else {
            for item in items {
                if var ref = trayByID[item.id] {
                    CollageBridge.refresh(&ref, from: item, facts: context.facts)
                    refs.append(ref)
                } else if let ref = CollageBridge.ref(from: item, facts: context.facts) {
                    refs.append(ref)
                }
            }
        }
        guard !refs.isEmpty else { return nil }
        // 只照着印样（白相纸上的黑场）来：社交底片条的设置是给深色纸、社交图定的（「底片条 · 三帧」的白笔套到
        // A4 白相纸上就是白圈、墨色注记 —— 先试了底片条再点一键成套就会这样）。
        let inherit = context.project.pages.lazy.compactMap(\.contactSheet).first { $0.layout == .sheet }
        var project = context.project
        project.mode = .single
        project.canvas = a4
        project.style = paperStyle(whitePaper, grain: 0)
        project.pages = rolls(refs).map { page($0, inherit: inherit) }
        // 托盘：原来的照片（按批量页刷新过的）在前，托盘里没有的（废片、没带进来的帧）接在后面。
        let fresh = Dictionary(refs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var photos = context.tray.map { fresh[$0.id] ?? $0 }
        let inTray = Set(photos.map(\.id))
        photos += refs.filter { !inTray.contains($0.id) }
        project.photos = photos
        return project
    }
}
