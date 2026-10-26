import Foundation
import CoreGraphics

/// LABELGUI_DATA_DIR=<临时> LabelGUI --album-selftest [<photo_dir> --out <目录>]
///
/// fine-art 相册编排（CollageStyleFineArt.plan / layout）的自测。photot 只有一个模特、一天、一章，覆盖不到婚礼的
/// 章节、黑白混排、细节图，所以这里用**合成的照片引用**（不是真照片，也没在真婚礼上验过）：
/// 1. 一本四章的「婚礼」：准备（黑白过三分之一、细节图、连拍重复）、仪式（同一场两张精选、横图、同姿势）、
///    外景（没有人脸的场地图、亮度两极）、晚宴（零星两张黑白、两张废片）。打印每个跨页的结构，逐条断言 R1–R12；
/// 2. 同一本按三种册子（30×30、20×20、30×20 横版）出版式：不跨中缝、边距 ≥ 25mm、主图 ≥ 2 倍配图、小字 ≥ 2.8mm、
///    整章黑白落到页级色调；
/// 3. 关掉整章黑白、关掉去重、只有一张 / 两张 / 三张、全是废片、没有时间、默认主题照旧；同一输入两次结果一样。
/// 给了照片文件夹：再把那批真照片套上合成的章节 / 黑白标记（明说是假的）按 fine-art 编一本，出跨页图到 --out，
/// 用来看章节开篇、整章黑白、一主两辅、横图单页的样子 —— 不是婚礼，也不能当成婚礼验过。
/// 全过退出 0，否则 1。
enum CollageStyleFineArtSelfTest {

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        CollageCLI.requireIsolatedDataDir("--album-selftest")
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }

        // ---------------------------------------------------------------- 1. 合成的一本
        let book = Book.wedding()
        print("== 合成婚礼 \(book.photos.count) 张（4 章；合成数据，不是真照片）")
        let plan = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: book.similarity)
        printPlan(plan)
        checkPlan(plan, book: book, chapterMono: true, check: check)

        // 同一输入两次一样（编排里没有随机）。
        let again = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, similarity: book.similarity)
        check(signature(plan) == signature(again), "同一输入两次编排一样")

        // ---------------------------------------------------------------- 2. 版式
        for canvas in [CollageCanvas.albums[0], CollageCanvas.albums[2], CollageCanvas.albums[3]] {
            checkLayout(plan, book: book, canvas: canvas, check: check)
        }
        var glued = CollageCanvas.albums[1]
        glued.binding = .glued
        checkLayout(plan, book: book, canvas: glued, check: check)

        // ---------------------------------------------------------------- 3. 开关、边界
        print("== 关掉整章黑白")
        let noMono = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: false, similarity: book.similarity)
        checkPlan(noMono, book: book, chapterMono: false, check: check)
        let monoPages = noMono.spreads.filter { $0.fineArt?.look != nil }
        check(monoPages.allSatisfy { $0.photos.allSatisfy { $0.isMonochrome == true } },
              "整章黑白关着：只有全是黑白照片的跨页设黑白页（彩色照片不被转成黑白）",
              "\(monoPages.count) 个黑白页")

        print("== 不给相似关系（Vision 特征算不出来 = 合成数据走真实那条路）")
        let real = CollageAlbum.plan(book.photos, dedupe: true, theme: .fineArt, chapterMono: true)
        check(real.theme == .fineArt && !real.spreads.isEmpty && real.spreads.allSatisfy { $0.fineArt != nil },
              "CollageAlbum.plan(theme: .fineArt) 分派到 fine-art", "\(real.spreads.count) 个跨页")
        let placedReal = real.spreads.flatMap(\.photos).map(\.id)
        check(Set(placedReal).count == placedReal.count, "真实那条路：没有一张放两次")

        print("== 扉页标题")
        for (t, latin) in [("Spring Notes", true), ("林 & 苏", false), ("", false), ("拾光 2026", false)] {
            let p = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, title: t,
                                             similarity: book.similarity)
            let page = CollageStyleFineArt.build(p, context: context(CollageCanvas.albums[0], book: book.photos)).first
            let tracking = page?.root.leaves.first { $0.kind == .text }?.text?.lines.first?.tracking ?? -1
            check(p.spreads.first?.fineArt?.latinTitle == latin && (latin ? tracking < 0.05 : tracking >= 0.1),
                  "扉页标题「\(t)」：\(latin ? "西文不加字距" : "中文字距 0.12")", String(format: "字距 %.2f", tracking))
        }

        print("== 工程存盘：编排主题、整章黑白")
        var saved = CollageProject()
        saved.albumTheme = .fineArt
        saved.albumChapterMono = false
        if let data = try? JSONEncoder().encode(saved),
           let back = try? JSONDecoder().decode(CollageProject.self, from: data),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            check(back.albumTheme == .fineArt && !back.albumChapterMono, "存了再读回来一样")
            dict.removeValue(forKey: "albumTheme")
            dict.removeValue(forKey: "albumChapterMono")
            let old = (try? JSONSerialization.data(withJSONObject: dict))
                .flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
            check(old?.albumTheme == .classic && old?.albumChapterMono == true, "旧工程没有这两个键 = 默认主题、整章黑白开")
            dict["albumTheme"] = "lustre"
            dict["albumChapterMono"] = "坏值"
            let bad = (try? JSONSerialization.data(withJSONObject: dict))
                .flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
            check(bad?.albumTheme == .classic && bad?.albumChapterMono == true, "认不得的主题、坏值 = 默认（工程照常读回）")
        } else {
            check(false, "工程编码", "")
        }

        print("== 默认主题照旧")
        let classicA = CollageAlbum.plan(book.photos, dedupe: true)
        let classicB = CollageAlbum.plan(book.photos, dedupe: true, theme: .classic, chapterMono: false)
        check(signature(classicA) == signature(classicB) && classicA.spreads.allSatisfy { $0.fineArt == nil }
              && classicA.theme == .classic,
              "theme: .classic 和不给主题一样（不带 fine-art 说明）")

        checkMargins(check: check)
        checkLongTitles(book: book, check: check)
        let quotas = [5, 6, 13, 14, 15, 27, 28, 40].map { CollageStyleFineArt.breathQuota(spreads: $0) }
        check(quotas == [0, 1, 1, 2, 3, 3, 4, 4], "呼吸图定额：15 个跨页起 3 张、28 个起 4 张，薄册子 1–2 张、5 个以下不放",
              quotas.map(String.init).joined(separator: " "))
        checkTemplates(book: book, check: check)
        checkDateLine(check: check)
        checkPacing(check: check)

        print("== 很少的照片")
        for n in [1, 2, 3, 5] {
            let few = Array(book.photos.filter { $0.verdict != .reject }.prefix(n))
            let p = CollageStyleFineArt.plan(few, dedupe: true, chapterMono: true, similarity: nil)
            let placed = p.spreads.flatMap(\.photos).map(\.id)
            let kept = Set(placed).union(p.dropped.map(\.id))
            check(!p.spreads.isEmpty && p.spreads[0].fineArt?.kind == .title && Set(placed).count == placed.count
                  && kept == Set(few.map(\.id)),
                  "\(n) 张：有扉页、每张要么上了要么在拿掉的里面、没有重复",
                  p.spreads.map { $0.fineArt?.kind.rawValue ?? "?" }.joined(separator: " "))
            let pages = CollageAlbum.build(p, context: context(CollageCanvas.albums[0], book: few))
            check(pages.count == p.spreads.count, "\(n) 张：每个跨页都出了版式")
        }
        let rejects = book.photos.filter { $0.verdict == .reject }
        let onlyRejects = CollageStyleFineArt.plan(rejects, dedupe: true, chapterMono: true, similarity: nil)
        check(!onlyRejects.spreads.isEmpty, "全是废片：不崩，照样编（没别的可用）", "\(onlyRejects.spreads.count) 个跨页")
        var timeless = book.photos
        for i in timeless.indices { timeless[i].captureTime = nil }
        let noTime = CollageStyleFineArt.plan(timeless, dedupe: true, chapterMono: true, similarity: book.similarity)
        check(!noTime.spreads.isEmpty
              && noTime.spreads.compactMap(\.fineArt).filter { $0.kind == .chapter }.allSatisfy {
                  !($0.caption ?? "").contains(":")
              }, "没有拍摄时间：章节开篇只印章序（不印时刻）")

        // ---------------------------------------------------------------- 4. 真照片套合成标记（可选）
        if args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") {
            renderOnPhotos(dir: URL(fileURLWithPath: args[flagIndex + 1]), args: args, check: check)
        }

        print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - 合成数据

    /// 一本合成的婚礼：照片引用 + 同姿势关系（selftest 直接给，不跑 Vision）。
    struct Book {
        var photos: [CollagePhotoRef]
        var similarity: CollageStyleFineArt.Similarity
        /// 应该整章黑白的章（黑白 ≥ 三分之一）。
        var monoChapters: Set<Int>

        static let day: Date = {
            var c = DateComponents()
            c.year = 2026
            c.month = 5
            c.day = 16
            c.hour = 14
            c.minute = 0
            return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 0)
        }()

        /// id、章、第几分钟、竖不竖、脸面积（0 = 没有脸）、分数、精选、场、连拍组、黑白、亮度、判决。
        static func ref(_ id: String, _ chapter: Int, _ minute: Double, portrait: Bool = true, face: Double = 0.02,
                        score: Double = 1.5, pick: Bool = false, take: Int? = nil, burst: Int? = nil,
                        mono: Bool = false, luma: Double = 0.5, verdict: CollageVerdict? = nil) -> CollagePhotoRef {
            var r = CollagePhotoRef(id: id, path: "/nonexistent/selftest/\(id).jpg",
                                    width: portrait ? 4000 : 6000, height: portrait ? 6000 : 4000)
            if face > 0 {
                let side = face.squareRoot()
                r.faces = [[0.45 - side / 2, 0.25, 0.45 + side / 2, 0.25 + side]]
                r.faceAreaPct = face
            } else {
                r.faceAreaPct = nil
            }
            r.score = score + (pick ? 1 : 0)
            r.isPick = pick
            r.take = take
            r.burstGroup = burst
            r.chapter = chapter
            r.captureTime = day.addingTimeInterval(minute * 60)
            r.isMonochrome = mono
            r.meanLuma = luma
            r.verdict = verdict ?? (pick ? .pick : .usable)
            return r
        }

        static func wedding() -> Book {
            var p: [CollagePhotoRef] = []
            // 第 1 章 准备（14:00 起）：13 张里 5 张黑白（≥ 1/3 → 整章黑白）；3 张细节（没有脸）；连拍 3 张重复。
            p += [
                ref("A01", 1, 0, portrait: false, face: 0, score: 1.6, luma: 0.62),             // 细节：戒指
                ref("A02", 1, 2, face: 0, score: 1.5, luma: 0.58),                              // 细节：鞋
                ref("A03", 1, 4, face: 0, score: 1.4, mono: true, luma: 0.55),                  // 细节：花，黑白
                ref("A04", 1, 6, face: 0.03, score: 1.7, pick: true, take: 1, luma: 0.5),
                ref("A05", 1, 6.2, face: 0.03, score: 1.6, take: 1, luma: 0.5),                 // 场 1 有精选 → 拿掉
                ref("A06", 1, 9, face: 0.025, score: 1.5, take: 2, mono: true, luma: 0.45),
                ref("A07", 1, 9.3, face: 0.026, score: 1.2, take: 2, mono: true, luma: 0.45),   // 场 2 没精选 → 留 A06
                ref("A08", 1, 12, face: 0.04, score: 1.8, pick: true, burst: 5, luma: 0.52),
                ref("A09", 1, 12.05, face: 0.04, score: 1.7, burst: 5, luma: 0.52),            // 连拍重复 → 拿掉
                ref("A10", 1, 12.1, face: 0.04, score: 1.6, burst: 5, luma: 0.52),             // 连拍重复 → 拿掉
                ref("A11", 1, 16, portrait: false, face: 0.012, score: 1.5, mono: true, luma: 0.4),
                ref("A12", 1, 20, face: 0.02, score: 1.6, mono: true, luma: 0.42),
                ref("A13", 1, 25, face: 0.018, score: 1.55, pick: true, luma: 0.5),
                ref("A14", 1, 30, face: 0.02, score: 1.45, luma: 0.48),
                ref("A15", 1, 34, face: 0.015, score: 1.4, mono: true, luma: 0.44),
            ]
            // 第 2 章 仪式（15:30 起）：同一场两张精选（不能放同一跨页）；横图成对；C09 / C10 同姿势。
            p += [
                ref("C01", 2, 90, portrait: false, face: 0.004, score: 1.6, luma: 0.55),        // 宽景（开篇候选）
                ref("C02", 2, 92, face: 0.02, score: 1.5, luma: 0.5),
                ref("C03", 2, 95, face: 0.03, score: 1.7, pick: true, take: 10, luma: 0.5),
                ref("C04", 2, 95.4, face: 0.03, score: 1.65, pick: true, take: 10, luma: 0.5),  // 同一场第二张精选
                ref("C05", 2, 100, portrait: false, face: 0.01, score: 1.5, luma: 0.5),
                ref("C06", 2, 102, portrait: false, face: 0.012, score: 1.45, luma: 0.52),
                ref("C07", 2, 104, portrait: false, face: 0.011, score: 1.4, luma: 0.5),
                ref("C08", 2, 106, portrait: false, face: 0.009, score: 1.6, luma: 0.48),
                ref("C09", 2, 110, face: 0.03, score: 1.5, luma: 0.5),
                ref("C10", 2, 111, face: 0.03, score: 1.45, luma: 0.5),                         // 和 C09 同姿势
                ref("C11", 2, 115, face: 0.025, score: 2.1, pick: true, luma: 0.5),             // 本章最高分精选
                ref("C12", 2, 118, face: 0.02, score: 1.4, luma: 0.46),
                ref("C13", 2, 121, face: 0.02, score: 1.35, luma: 0.47),
                ref("C14", 2, 124, face: 0.03, score: 1.5, luma: 0.5),
                ref("C15", 2, 128, face: 0.02, score: 1.3, luma: 0.5),
                ref("C16", 2, 131, face: 0.018, score: 1.35, luma: 0.5),
            ]
            // 第 3 章 外景（17:00 起）：两张没有人脸的场地图（呼吸）；亮度两极 D05（0.88）/ D06（0.22）不能对页。
            p += [
                ref("D01", 3, 180, portrait: false, face: 0, score: 1.7, luma: 0.6),            // 场地（呼吸）
                ref("D02", 3, 183, face: 0.02, score: 1.6, luma: 0.5),
                ref("D03", 3, 186, face: 0.022, score: 1.5, luma: 0.52),
                ref("D04", 3, 189, portrait: false, face: 0.002, score: 1.55, luma: 0.55),      // 远景小脸（呼吸）
                ref("D05", 3, 192, face: 0.02, score: 1.5, luma: 0.88),
                ref("D06", 3, 193, face: 0.02, score: 1.5, luma: 0.22),
                ref("D07", 3, 196, face: 0.03, score: 2.2, pick: true, luma: 0.5),              // 本章最高分精选
                ref("D08", 3, 199, portrait: false, face: 0.01, score: 1.5, luma: 0.5),
                ref("D09", 3, 202, face: 0.02, score: 1.45, luma: 0.5),
                ref("D10", 3, 205, face: 0.02, score: 1.4, luma: 0.52),
                ref("D11", 3, 208, face: 0.03, score: 1.6, pick: true, luma: 0.5),
                ref("D12", 3, 211, face: 0, score: 1.5, luma: 0.58),                            // 细节（没有脸）
                ref("D13", 3, 214, face: 0.02, score: 1.35, luma: 0.5),
                ref("D14", 3, 217, face: 0.025, score: 1.4, luma: 0.5),
            ]
            // 第 4 章 晚宴（19:00 起）：16 张里两张黑白（< 1/3 → 不转整章，黑白单独成页不和彩色混）；两张废片；
        // 最后四张细节（没有脸：一张当呼吸图，剩三张凑细节三联）。
            p += [
                ref("E01", 4, 300, portrait: false, face: 0.006, score: 1.6, luma: 0.35),
                ref("E02", 4, 303, face: 0.03, score: 1.5, luma: 0.33),
                ref("E03", 4, 306, face: 0.03, score: 1.45, mono: true, luma: 0.3),
                ref("E04", 4, 309, face: 0.03, score: 1.4, mono: true, luma: 0.32),
                ref("E05", 4, 312, face: 0.025, score: 0.4, luma: 0.3, verdict: .reject),         // 废片
                ref("E06", 4, 315, face: 0.02, score: 1.5, luma: 0.34),
                ref("E07", 4, 318, face: 0.02, score: 1.45, luma: 0.36),
                ref("E08", 4, 321, portrait: false, face: 0.01, score: 1.5, luma: 0.33),
                ref("E09", 4, 324, portrait: false, face: 0.012, score: 1.45, luma: 0.35),
                ref("E10", 4, 327, face: 0.03, score: 2.0, pick: true, luma: 0.34),             // 本章最高分精选
                ref("E11", 4, 330, face: 0.02, score: 0.3, luma: 0.3, verdict: .reject),          // 废片
                ref("E12", 4, 333, face: 0.02, score: 1.4, luma: 0.35),
                ref("E13", 4, 336, face: 0.02, score: 1.35, luma: 0.33),
                ref("E14", 4, 339, portrait: false, face: 0.008, score: 1.45, luma: 0.34),
                ref("E15", 4, 342, face: 0, score: 1.5, luma: 0.4),                             // 细节：桌花
                ref("E16", 4, 343, face: 0, score: 1.45, luma: 0.38),                           // 细节：蛋糕
                ref("E17", 4, 344, face: 0, score: 1.4, luma: 0.36),                            // 细节：喜帖
                ref("E18", 4, 345, face: 0, score: 1.55, luma: 0.4),                            // 细节：戒枕
            ]
            let similar: [String: Set<String>] = ["C09": ["C10"], "C10": ["C09"], "D09": ["D10"], "D10": ["D09"]]
            let sim = CollageStyleFineArt.Similarity(kept: p, dropped: [], similar: similar)
            return Book(photos: p, similarity: sim, monoChapters: [0])
        }
    }

    // MARK: - 打印

    static func describe(_ p: CollagePhotoRef) -> String {
        var s = p.id + (p.isPortrait ? "竖" : "横")
        if p.isPick { s += "★" }
        if p.isMonochrome == true { s += "黑白" }
        if CollageStyleFineArt.isBreath(p) { s += "·景" }
        return s
    }

    static func printPlan(_ plan: CollageAlbum.Plan) {
        for (i, s) in plan.spreads.enumerated() {
            guard let info = s.fineArt else { continue }
            var line = String(format: "  %2d ", i + 1) + "[\(info.kind.rawValue)] 第\(info.chapter + 1)章 · "
                + s.photos.map(describe).joined(separator: " ")
            if info.kind == .mainPlusTwo {
                line += " · 主图 \(s.photos[min(info.mainIndex, s.photos.count - 1)].id)（\(info.mainOnLeft ? "左" : "右")页）"
            }
            if let c = info.caption { line += " · 「\(c)」" }
            if let look = info.look { line += " · 色调 \(look.look.rawValue)" }
            print(line)
        }
        let count = plan.spreads.reduce(0) { $0 + $1.photos.count }
        print(String(format: "  共 %d 个跨页 %d 张，平均 %.2f 张；拿掉 %d 张：", plan.spreads.count, count,
                     Double(count) / Double(max(1, plan.spreads.count)), plan.dropped.count)
              + plan.dropped.map(\.id).joined(separator: " "))
    }

    static func signature(_ plan: CollageAlbum.Plan) -> String {
        plan.spreads.map { s in
            (s.fineArt.map { $0.kind.rawValue + "\($0.chapter)" + ($0.caption ?? "") + ($0.look?.look.rawValue ?? "") }
             ?? s.kind.rawValue) + ":" + s.photos.map(\.id).joined(separator: ",")
        }.joined(separator: "|") + "/" + plan.dropped.map(\.id).joined(separator: ",")
    }

    // MARK: - 编排断言

    static func checkPlan(_ plan: CollageAlbum.Plan, book: Book, chapterMono: Bool,
                          check: (Bool, String, String) -> Void) {
        let spreads = plan.spreads
        let infos = spreads.compactMap(\.fineArt)
        let all = spreads.flatMap(\.photos)
        let ids = all.map(\.id)
        let input = book.photos
        let rejects = Set(input.filter { $0.verdict == .reject }.map(\.id))
        check(infos.count == spreads.count, "每个跨页都带 fine-art 说明", "")

        // 一张不丢、一张不重：放上的 + 拿掉的 + 废片 = 输入。
        check(Set(ids).count == ids.count, "没有一张放两次", "")
        let accounted = Set(ids).union(plan.dropped.map(\.id)).union(rejects)
        check(accounted == Set(input.map(\.id)) && Set(ids).isDisjoint(with: rejects),
              "废片不上；其余每张要么上了、要么在「拿掉的」里", "放上 \(ids.count) · 拿掉 \(plan.dropped.count) · 废片 \(rejects.count)")

        // 每跨页最多 3 张，每页最多 2 张（细节三联那一页 3 张小图是例外，对页留白）。
        let over = spreads.filter { s in
            guard let info = s.fineArt else { return true }
            if s.photos.count > CollageStyleFineArt.maxPerSpread { return true }
            return info.kind != .triptych && info.kind != .mainPlusTwo && s.photos.count > 2
        }
        check(over.isEmpty, "每跨页最多 3 张、每页最多 2 张（三联除外）", "\(over.count) 个超了")
        let average = Double(ids.count) / Double(max(1, spreads.count))
        check(average >= 1.5 && average <= 2.0, "平均每跨页 1.5–2 张（R3）", String(format: "%.2f", average))

        // 扉页：第一个，景别宽（脸面积不大于全书中位数）。
        let faceOf: (CollagePhotoRef) -> Double = { $0.faces.isEmpty ? 0 : ($0.faceAreaPct ?? 0.05) }
        let sortedFaces = all.map(faceOf).sorted()
        let median = sortedFaces.isEmpty ? 0 : sortedFaces[sortedFaces.count / 2]
        if let first = spreads.first, let info = first.fineArt {
            check(info.kind == .title && first.photos.count == 1 && faceOf(first.photos[0]) <= median,
                  "R2 扉页在最前、一张景别宽的", describe(first.photos[0]))
        }

        // R1：章节按时间顺序、一个跨页不跨章；章节开篇在每章最前，「罗马数字 · 时刻」。
        let body = Array(spreads.dropFirst())
        let chapterSeq = body.compactMap { $0.fineArt?.chapter }
        check(chapterSeq == chapterSeq.sorted(), "R1 章节按顺序（不跨章挪照片）", "")
        let mixed = spreads.filter { s in Set(s.photos.map { $0.chapter ?? -1 }).count > 1 }
        check(mixed.isEmpty, "R1 一个跨页里的照片都来自同一章", "")
        let chapters = Array(Set(chapterSeq)).sorted()
        var openerOK = true
        var climaxOK = true
        var sparseOK = true
        for c in chapters {
            let mine = body.filter { $0.fineArt?.chapter == c }
            guard let head = mine.first?.fineArt else { continue }
            let numeral = CollageStyleFineArt.roman(c + 1)
            // 第一章由扉页开篇（不再来一个「I · 14:16」：一翻开就连着两个「左页一行字 + 右页一张」）。
            if chapters.count >= 2, c == chapters.first {
                if head.kind == .chapter { openerOK = false }
            } else if chapters.count >= 2, !(head.kind == .chapter && (head.caption ?? "").hasPrefix(numeral)) {
                openerOK = false
            }
            // R3：本章最高分的精选收尾（单张）；开篇之后的前两个跨页最多 2 张。
            let chapterPhotos = mine.flatMap(\.photos)
            let picks = chapterPhotos.filter(\.isPick).filter { !CollageStyleFineArt.isBreath($0) }
            // 照片少的章（开篇之外不到 4 张）不单独收尾。
            if chapterPhotos.count >= 5, let top = picks.max(by: { $0.score < $1.score }), let last = mine.last,
               let lastInfo = last.fineArt {
                if !(lastInfo.isSingle && last.photos.map(\.id) == [top.id]) { climaxOK = false }
            }
            let afterOpener = mine.drop { $0.fineArt?.kind == .chapter }
            for s in afterOpener.prefix(CollageStyleFineArt.sparseSpreads) where s.photos.count > 2 { sparseOK = false }
        }
        check(openerOK, "R1/R3 第二章起每章先来章节开篇（「II · 15:30」这样一行），第一章由扉页开篇", "")
        check(climaxOK, "R3 每章收尾是本章最高分的精选、单张", "")
        check(sparseOK, "R3 每章开头疏：开篇之后前两个跨页最多 2 张", "")
        // 疏 → 密：照片够多的章（开篇和收尾之外 ≥ 8 张），开头两个跨页之后要有 3 张的跨页（呼吸页不算内容页）。
        var denser = true
        var denseDetail: [String] = []
        for c in chapters {
            let mine = body.filter { $0.fineArt?.chapter == c && $0.fineArt?.kind != .chapter && $0.fineArt?.kind != .breath }
            let photos = mine.dropLast().reduce(0) { $0 + $1.photos.count }
            guard photos >= 8 else { continue }
            let later = mine.dropFirst(CollageStyleFineArt.sparseSpreads).map(\.photos.count)
            denseDetail.append("第\(c + 1)章 " + mine.map { "\($0.photos.count)" }.joined())
            if (later.max() ?? 0) < 3 { denser = false }
        }
        check(denser, "R3 疏 → 密：照片多的章开头两个跨页之后有 3 张的跨页", denseDetail.joined(separator: " · "))

        // R4：连着的多图跨页不超过 3 个。
        var run = 0
        var longest = 0
        for s in spreads {
            run = s.photos.count >= 2 ? run + 1 : 0
            longest = max(longest, run)
        }
        check(longest <= CollageStyleFineArt.maxBusyRun, "R4 连着的多图跨页最多 3 个", "最长 \(longest)")

        // R5：呼吸图（没脸 / 小脸，单张小一号）按跨页数定额：15 个跨页起全书 3–4 张（DESIGN），更薄的册子 1–2 张。
        let breaths = spreads.filter { $0.fineArt?.kind == .breath }
        let breathRange = spreads.count >= 15 ? 3...4 : 0...2
        check(breathRange.contains(breaths.count) && breaths.allSatisfy {
            $0.photos.count == 1 && CollageStyleFineArt.isBreath($0.photos[0])
        }, "R5 呼吸图 \(breathRange.lowerBound)–\(breathRange.upperBound) 张（这本 \(spreads.count) 个跨页）、都是没脸 / 小脸的单张",
              breaths.map { $0.photos[0].id }.joined(separator: " "))

        // R6 在版式里量（checkLayout）。
        // R7：一个跨页不混黑白和彩色；整章黑白的章每个跨页都是黑白页；全黑白的跨页设黑白页。
        var r7 = true
        var monoChapterOK = true
        for s in spreads {
            guard let info = s.fineArt else { continue }
            let monoCount = s.photos.filter { $0.isMonochrome == true }.count
            let isMonoPage = info.look?.look == .mono
            if monoCount > 0, monoCount < s.photos.count, !isMonoPage { r7 = false }
            if monoCount == s.photos.count, !isMonoPage { r7 = false }
            // 扉页是整本的开头、不属于哪一章：只看照片本身。
            let shouldMono = chapterMono && info.kind != .title && book.monoChapters.contains(info.chapter)
            if shouldMono, !isMonoPage { monoChapterOK = false }
            if !shouldMono, isMonoPage, monoCount < s.photos.count { monoChapterOK = false }
        }
        check(r7, "R7 一个跨页不混黑白和彩色（混的只能是整章黑白）", "")
        check(monoChapterOK, chapterMono ? "R7 整章黑白：第 1 章（黑白过三分之一）整章黑白页，别的章不转"
              : "R7 整章黑白关着：没有一章被转成黑白", "")

        // R8：两页亮度差 ≤ 0.25。
        var r8 = true
        for s in spreads {
            guard let info = s.fineArt else { continue }
            switch info.kind {
            case .pair where s.photos.count == 2:
                if CollageStyleFineArt.lumaGap([s.photos[0]], [s.photos[1]]) > CollageStyleFineArt.maxLumaGap { r8 = false }
            case .mainPlusTwo:
                let main = s.photos[min(info.mainIndex, s.photos.count - 1)]
                let others = s.photos.filter { $0.id != main.id }
                if CollageStyleFineArt.lumaGap([main], others) > CollageStyleFineArt.maxLumaGap { r8 = false }
            default:
                break
            }
        }
        check(r8, "R8 左右页亮度差不超过 0.25", "")
        let d05 = spreads.first { $0.photos.contains { $0.id == "D05" } }
        check(d05.map { !$0.photos.contains { $0.id == "D06" } } ?? true, "R8 最亮（D05）和最暗（D06）不对页", "")

        // R10：同一瞬间只留一张（连拍组），同一场只留精选；同一跨页不放同姿势 / 同一场的两张。
        let placed = Set(ids)
        check(!placed.contains("A09") && !placed.contains("A10") && placed.contains("A08"),
              "R10 连拍重复只留精选（A08，拿掉 A09 A10）", "")
        check(!placed.contains("A05") && placed.contains("A04"), "R10 同一场有精选只留精选（A04，拿掉 A05）", "")
        check(placed.contains("A06") && !placed.contains("A07"), "R10 同一场没精选留最好的一张（A06，拿掉 A07）", "")
        check(placed.contains("C03") && placed.contains("C04")
              && spreads.first { $0.photos.contains { $0.id == "C03" } }?.photos.contains { $0.id == "C04" } == false,
              "R10 同一场两张精选都留、但不在同一跨页", "")
        let samePose = spreads.filter { s in
            s.photos.contains { a in s.photos.contains { b in a.id != b.id && (book.similarity.similar[a.id]?.contains(b.id) ?? false) } }
        }
        check(samePose.isEmpty, "R10 同姿势（same ≥ 1）不进同一跨页", "")

        // R11：对页双图同方向；竖图大多成对。
        let pairs = spreads.filter { $0.fineArt?.kind == .pair }
        let mergedPairs = pairs.filter { $0.fineArt?.merged == true }
        check(pairs.allSatisfy {
            $0.photos.count == 2 && ($0.photos[0].isPortrait == $0.photos[1].isPortrait || $0.fineArt?.merged == true)
        }, "R11 对页双图竖配竖、横配横（同高；横竖混排的只有为了不连着 3 个单图并起来的）",
              "\(pairs.count) 个，其中并起来的 \(mergedPairs.count) 个")
        let bodyPortraits = spreads.filter {
            guard let k = $0.fineArt?.kind else { return false }
            return k != .title && k != .chapter && k != .breath
        }.flatMap(\.photos).filter(\.isPortrait)
        let lonely = spreads.filter { $0.fineArt?.kind == .single }.flatMap(\.photos)
        let climaxIDs = Set(chapters.compactMap { c in body.filter { $0.fineArt?.chapter == c }.last?.photos.first?.id })
        let lonelyPortraits = lonely.filter { $0.isPortrait && !climaxIDs.contains($0.id) }
        check(Double(lonelyPortraits.count) <= Double(bodyPortraits.count) * 0.25,
              "R11 竖图优先成对：除了每章收尾，落单的竖图不到四分之一",
              "\(lonelyPortraits.count) / \(bodyPortraits.count)：" + lonelyPortraits.map(\.id).joined(separator: " "))

        // 不连着 3 个单图跨页（开篇、呼吸、收尾挨在一起的除外：它们不能并）。
        var singleRun = 0
        var longestSingles = 0
        var stuck = false
        var runKinds: [CollageFineArtSpread.Kind] = []
        for s in spreads {
            if s.photos.count == 1 {
                singleRun += 1
                runKinds.append(s.fineArt?.kind ?? .single)
            } else {
                singleRun = 0
                runKinds = []
            }
            longestSingles = max(longestSingles, singleRun)
            // 一串里能并的（正文的单张）不止一个才算没并干净。
            if singleRun > CollageStyleFineArt.maxSingleRun,
               runKinds.filter({ $0 == .single || $0 == .landscape }).count > 2 { stuck = true }
        }
        check(longestSingles <= CollageStyleFineArt.maxSingleRun || !stuck,
              "R3 不连着 3 个单图跨页（剩下的只能是开篇 / 呼吸 / 收尾挨着）", "最长 \(longestSingles)")
        // 扉页后面那个跨页不放和扉页同姿势的。
        if let title = spreads.first?.photos.first, spreads.count > 1 {
            let near = CollageStyleFineArt.similarSet(title, book.similarity.similar)
            check(!spreads[1].photos.contains { near.contains($0.id) }, "扉页之后的跨页不放和扉页同姿势的", "")
        }

        // 一主两辅：主图是三张里分数最高的。
        let mains = spreads.filter { $0.fineArt?.kind == .mainPlusTwo }
        check(mains.allSatisfy { s in
            let info = s.fineArt!
            let main = s.photos[min(info.mainIndex, s.photos.count - 1)]
            return s.photos.count == 3 && s.photos.allSatisfy { $0.score <= main.score }
        }, "一主两辅：主图是三张里分数最高的", "\(mains.count) 个")
        let triptychs = spreads.filter { $0.fineArt?.kind == .triptych }
        check(triptychs.allSatisfy { $0.photos.count == 3 && $0.photos.allSatisfy(CollageStyleFineArt.isBreath) },
              "细节三联只放细节（没脸 / 小脸）", "\(triptychs.count) 个")
        let kinds = Set(infos.map(\.kind))
        check(kinds.isSuperset(of: [.title, .chapter, .single, .landscape, .breath, .pair, .mainPlusTwo, .triptych]),
              "这本里八种跨页都用到了（扉页、章节开篇、单张、横图单页、呼吸页、对页双图、一主两辅、细节三联）",
              kinds.map(\.rawValue).sorted().joined(separator: " "))
    }

    // MARK: - 版式断言

    static func context(_ canvas: CollageCanvas, book: [CollagePhotoRef]) -> CollageLayout.Context {
        var map: [String: CollagePhotoRef] = [:]
        for p in book { map[p.id] = p }
        return CollageLayout.Context(canvas: canvas, style: CollageStyleFineArt.style(for: canvas), photos: map,
                                     hints: [:], heroID: nil)
    }

    static func checkLayout(_ plan: CollageAlbum.Plan, book: Book, canvas: CollageCanvas,
                            check: (Bool, String, String) -> Void) {
        let ctx = context(canvas, book: book.photos)
        let style = ctx.style
        let pages = CollageAlbum.build(plan, context: ctx)
        print("== 版式 \(canvas.name)\(canvas.binding == .glued ? "（胶装）" : "") · 边距 上\(fmt(style.insets?.top)) 下\(fmt(style.insets?.bottom)) 内\(fmt(style.insets?.inner)) 外\(fmt(style.insets?.outer)) · 缝 \(fmt(style.gutter))")
        let floor = canvas.pixels(mm: CollageStyleFineArt.marginFloorMM) - 1
        let halfW = Double(canvas.width) / 2
        let mat = style.matWidth
        var rootOK = true
        var photosOK = true
        var foldOK = true
        var marginOK = true
        var r6OK = true
        var containOK = true
        var lookOK = true
        var r6Detail: [String] = []
        for (i, page) in pages.enumerated() {
            let spread = plan.spreads[i]
            if !CollageLayout.isFoldSplit(page.root) { rootOK = false }
            if page.look != spread.fineArt?.look { lookOK = false }
            let geo = CollageLayout.pageGeometry(page.root, canvas: canvas, style: style)
            let frames = geo.frames.filter { $0.cell.kind == .photo }
            let onPage = frames.compactMap(\.cell.photoID)
            if onPage.sorted() != spread.photos.map(\.id).sorted() { photosOK = false }
            let kind = spread.fineArt?.kind
            for f in frames {
                // 完整显示；配图、三联横竖混排时是一样大的方窗（裁切格），别的跨页一律完整显示。
                if !f.cell.contain {
                    let inner = CollageCrop.borderInner(CGRect(x: 0, y: 0, width: f.rect.width, height: f.rect.height),
                                                        .mat, mat: mat)
                    let square = abs(Double(inner.width / max(1, inner.height)) - 1) < 0.03
                    if !(kind == .mainPlusTwo || kind == .triptych) || !square { containOK = false }
                }
                let r = f.rect
                // 不跨中缝：整格在左页或右页。
                if Double(r.x0) < halfW, Double(r.x1) > halfW { foldOK = false }
                // 离成品四边、离中缝至少 25mm。
                let left = Double(r.x0)
                let right = Double(canvas.width - r.x1)
                let top = Double(r.y0)
                let bottom = Double(canvas.height - r.y1)
                let toFold = Double(r.x1) <= halfW ? halfW - Double(r.x1) : Double(r.x0) - halfW
                if min(left, right, top, bottom, toFold) < floor { marginOK = false }
            }
            if spread.fineArt?.kind == .mainPlusTwo, let info = spread.fineArt {
                let main = spread.photos[min(info.mainIndex, spread.photos.count - 1)]
                func area(_ f: CollageLayout.Frame) -> Double {
                    let p = ctx.photos[f.cell.photoID ?? ""]
                    let w = Double(f.rect.width)
                    let h = Double(f.rect.height)
                    if !f.cell.contain { return CollageStyleFineArt.windowArea(w: w, h: h, mat: mat) }
                    return CollageStyleFineArt.shownArea(aspect: p?.aspect ?? 1, w: w, h: h, mat: mat)
                }
                let mainArea = frames.first { $0.cell.photoID == main.id }.map(area) ?? 0
                let others = frames.filter { $0.cell.photoID != main.id }.map(area)
                let ratio = mainArea / max(1, others.max() ?? 1)
                r6Detail.append(String(format: "%@ %.2f", main.id, ratio))
                if ratio < 1.99 { r6OK = false }
            }
        }
        check(rootOK, "每个跨页的根是中缝那一刀（row 0.5）", "")
        check(photosOK, "版式里的照片就是编排给的那几张", "")
        check(containOK, "照片格都完整显示（fine-art 不裁；配图、三联横竖混排才是一样大的方窗）", "")
        check(foldOK, "没有照片跨中缝", "")
        check(marginOK, "照片离成品边、离中缝都 ≥ 25mm", "")
        check(r6OK, "R6 一主两辅：主图实际面积 ≥ 2 倍配图", r6Detail.joined(separator: " · "))
        check(lookOK, "页级色调 = 编排给的（整章黑白落到 CollagePage.look）", "")
        // 小字：章节开篇、扉页日期行 ≥ 2.8mm —— 按画出来的字号量（放不下时 drawShort 整格缩），不是 line.size。
        var smallest = Double.infinity
        for page in pages {
            let geo = CollageLayout.pageGeometry(page.root, canvas: canvas, style: style)
            for f in geo.frames where f.cell.kind == .text {
                guard let text = f.cell.text else { continue }
                smallest = min(smallest, drawnMM(text, rect: f.rect.cgRect, canvas: canvas, title: "").min() ?? 0)
            }
        }
        check(smallest >= CollageStyleFineArt.minTextMM - 0.01, "小字 ≥ 2.8mm（画出来的）", String(format: "%.2fmm", smallest))
    }

    /// 占位符的样子（量字用）：最长的英文月份。
    static func sampleVars(title: String) -> [String: String] {
        ["title": title.isEmpty ? "拾光" : title, "month_en": "SEPTEMBER", "day_num": "30", "year": "2026"]
    }

    /// 一个文字格里每行画出来多大（mm）：和渲染同一个 drawShort（字块放不下这一格就整块按比例缩）。
    static func drawnMM(_ text: CollageText, rect: CGRect, canvas: CollageCanvas, title: String) -> [Double] {
        let short = CollageTypeset.drawShort(text, in: rect, short: canvas.shortSide, vars: sampleVars(title: title))
        return text.lines.map { $0.size * short / canvas.dpi * 25.4 }
    }

    /// 扉页标题很长（校验者那几个）：标题、日期行是两个文字格，只缩标题，日期行画出来 ≥ 2.8mm；两格不压在一起；
    /// 短标题时整块的位置和原来一个字块一样（差不过 3 像素）。
    static func checkLongTitles(book: Book, check: (Bool, String, String) -> Void) {
        print("== 扉页长标题：只缩标题，日期行 ≥ 2.8mm（按画出来的字号量）")
        var glued = CollageCanvas.albums[1]
        glued.binding = .glued
        let titles = ["林晓与苏明远的婚礼 · 二〇二六年三月二十一日 · 苏州", "A Very Long Wedding Album Title For Two People",
                      "林晓 & 苏明远 · 苏州平江路婚礼纪念", "拾光", "Spring Notes"]
        for canvas in [CollageCanvas.albums[0], glued, CollageCanvas.albums[2]] {
            var dateMin = Double.infinity
            var splitOK = true
            var overlapOK = true
            var titleSizes: [String] = []
            var sameAsBlock = true
            for t in titles {
                let plan = CollageStyleFineArt.plan(book.photos, dedupe: true, chapterMono: true, title: t,
                                                    similarity: book.similarity)
                let ctx = context(canvas, book: book.photos)
                guard let page = CollageAlbum.build(plan, context: ctx).first else { splitOK = false; continue }
                let geo = CollageLayout.pageGeometry(page.root, canvas: canvas, style: ctx.style)
                let texts = geo.frames.filter { $0.cell.kind == .text }
                guard texts.count == 2, let titleCell = texts.first(where: { $0.cell.text?.lines.first?.text == "{title}" }),
                      let dateCell = texts.first(where: { $0.cell.text?.lines.first?.text == CollageStyleFineArt.dateLine }),
                      let titleText = titleCell.cell.text, let dateText = dateCell.cell.text else {
                    splitOK = false
                    continue
                }
                let vars = sampleVars(title: t)
                dateMin = min(dateMin, drawnMM(dateText, rect: dateCell.rect.cgRect, canvas: canvas, title: t).min() ?? 0)
                titleSizes.append(String(format: "%.1f", drawnMM(titleText, rect: titleCell.rect.cgRect, canvas: canvas, title: t)[0]))
                let ts = CollageTypeset.drawShort(titleText, in: titleCell.rect.cgRect, short: canvas.shortSide, vars: vars)
                let ds = CollageTypeset.drawShort(dateText, in: dateCell.rect.cgRect, short: canvas.shortSide, vars: vars)
                let tr = CollageTypeset.blockRect(titleText, in: titleCell.rect.cgRect, short: ts, vars: vars)
                let dr = CollageTypeset.blockRect(dateText, in: dateCell.rect.cgRect, short: ds, vars: vars)
                if tr.maxY > dr.minY || tr.minX < titleCell.rect.cgRect.minX - 1 || tr.maxX > titleCell.rect.cgRect.maxX + 1 {
                    overlapOK = false
                }
                // 短标题（放得下、不缩）：和一个字块时的位置一样。
                if t == "拾光" || t == "Spring Notes" {
                    let whole = CollageStyleFineArt.titleText(latin: CollageStyleFineArt.isLatinTitle(t),
                                                              small: CollageStyleFineArt.smallSize(for: canvas))
                    let left = CGRect(x: titleCell.rect.cgRect.minX, y: titleCell.rect.cgRect.minY,
                                      width: titleCell.rect.cgRect.width,
                                      height: CollageStyleFineArt.pageBox(canvas: canvas, style: ctx.style).h)
                    let ws = CollageTypeset.drawShort(whole, in: left, short: canvas.shortSide, vars: vars)
                    let wr = CollageTypeset.blockRect(whole, in: left, short: ws, vars: vars)
                    if abs(wr.minY - tr.minY) > 3 || abs(wr.maxY - dr.maxY) > 3 { sameAsBlock = false }
                }
            }
            check(splitOK, "\(canvas.name)\(canvas.binding == .glued ? "（胶装）" : "")：扉页标题、日期行是两个文字格", "")
            check(dateMin >= CollageStyleFineArt.minTextMM - 0.01, "\(canvas.name)：长标题只缩标题，日期行画出来 ≥ 2.8mm",
                  String(format: "日期行最小 %.2fmm · 标题 ", dateMin) + titleSizes.joined(separator: " / ") + "mm")
            check(overlapOK, "\(canvas.name)：标题在格子里放得下、不压日期行", "")
            check(sameAsBlock, "\(canvas.name)：短标题的位置和原来一个字块一样（±3 像素）", "")
        }
    }

    private static func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }

    // MARK: - 边距按册子重算（样式页选预设、换册子尺寸）

    static func checkMargins(check: (Bool, String, String) -> Void) {
        print("== 预设的边距按册子重算（CollageStyleFineArt.adapted：setStyle / setCanvas / setMode / --album）")
        let a30 = CollageCanvas.albums[0]
        let a20 = CollageCanvas.albums[2]
        let a3020 = CollageCanvas.albums[3]
        func mm(_ v: Double?, _ c: CollageCanvas) -> Double { (v ?? 0) * c.shortSide / c.dpi * 25.4 }
        for canvas in [a30, a20, a3020, CollageCanvas.albums[1]] {
            let fine = CollageStyleFineArt.adapted(CollageStyleFineArt.style, to: canvas)
            let ins = fine?.insets
            let pageW: Double = Double(canvas.width) / 2 / canvas.dpi * 25.4
            let pageH: Double = Double(canvas.height) / canvas.dpi * 25.4
            let want = max(pageW * 0.12, 25.0)
            let side = mm(ins?.inner, canvas)
            let top = mm(ins?.top, canvas)
            check(fine != nil && abs(side - want) < 0.2 && abs(mm(ins?.outer, canvas) - want) < 0.2
                  && abs(top - max(pageH * 0.12, 25)) < 0.2,
                  "预设「婚礼 fine-art」套到\(canvas.name)：上 / 内 / 外 = max(12% 页边, 25mm)",
                  String(format: "上 %.1fmm 内 %.1fmm 外 %.1fmm 下 %.1fmm", top, side, mm(ins?.outer, canvas),
                         mm(ins?.bottom, canvas)))
            let canon = CollageStyleFineArt.adapted(CollageStyleFineArt.canonStyle, to: canvas)?.insets
            check(abs(mm(canon?.inner, canvas) - pageW / 9) < 0.2 && abs(mm(canon?.outer, canvas) - pageW * 2 / 9) < 0.2
                  && abs(mm(canon?.top, canvas) - pageH / 9) < 0.2 && abs(mm(canon?.bottom, canvas) - pageH * 2 / 9) < 0.2,
                  "古典版心套到\(canvas.name)：内 = 页宽 / 9、外 = 页宽 × 2/9、上 = 页高 / 9、下 = 页高 × 2/9",
                  String(format: "内 %.1fmm 外 %.1fmm 上 %.1fmm 下 %.1fmm", mm(canon?.inner, canvas),
                         mm(canon?.outer, canvas), mm(canon?.top, canvas), mm(canon?.bottom, canvas)))
        }
        // 古典版心放到单张画布（小红书 3:4、1:1）：左右对称各 1/6 页宽，上 1/9、下 2/9 页高（版心 2/3 × 2/3）。
        for canvas in CollageCanvas.social.prefix(2) {
            let flat = CollageStyleFineArt.adapted(CollageStyleFineArt.canonStyle, to: canvas)?.insets
            let w = Double(canvas.width)
            let h = Double(canvas.height)
            let short = canvas.shortSide
            let ok = flat.map { i in
                abs(i.inner - i.outer) < 1e-9 && abs(i.inner * short - w / 6) < 1 && abs(i.top * short - h / 9) < 1
                    && abs(i.bottom * short - h * 2 / 9) < 1
            } ?? false
            check(ok, "古典版心套到单张画布 \(canvas.name)：左右对称（各 1/6 页宽），上 1/9、下 2/9 页高", "")
            let back = flat.flatMap { _ in CollageStyleFineArt.adapted(CollageStyleFineArt.style(for: canvas, canon: true),
                                                                       from: canvas, to: a30) }
            check(back?.insets == CollageStyleFineArt.style(for: a30, canon: true).insets,
                  "单张画布上的古典版心切到相册：回到跨页的 内 1/9、外 2/9", "")
        }
        // 换册子尺寸：30×30 算好的 → 20×20、20×20 → 30×20；纸纹改过也认，边距改过就不认。
        var tweaked = CollageStyleFineArt.style(for: a30)
        tweaked.grain = 0.4
        let moved = CollageStyleFineArt.adapted(tweaked, from: a30, to: a20)
        check(moved?.insets == CollageStyleFineArt.style(for: a20).insets && moved?.grain == 0.4,
              "换册子尺寸：30×30 的 fine-art 边距换到 20×20 重算，改过的纸纹留着", "")
        let again = CollageStyleFineArt.adapted(CollageStyleFineArt.style(for: a20), from: a20, to: a3020)
        check(again?.insets == CollageStyleFineArt.style(for: a3020).insets, "20×20 → 30×20 横版也重算", "")
        let canonMoved = CollageStyleFineArt.adapted(CollageStyleFineArt.style(for: a30, canon: true), from: a30, to: a3020)
        check(canonMoved?.insets == CollageStyleFineArt.style(for: a3020, canon: true).insets, "古典版心换尺寸还是古典版心", "")
        let remembered = CollageStyleFineArt.adapted(CollageStyleFineArt.style(for: a3020), from: a3020,
                                                     to: CollageCanvas.social[0])
        check(remembered?.insets == CollageStyleFineArt.style.insets,
              "记成下次新建的默认样式（setStyle）：30×20 重算过的边距换回预设本来的（不带到下一张单张拼图）", "")
        var hand = CollageStyleFineArt.style(for: a30)
        hand.insets?.top = 0.2
        check(CollageStyleFineArt.adapted(hand, from: a30, to: a20) == nil, "自己改过边距的不动", "")
        check(CollageStyles.all.filter { !$0.key.hasPrefix("wedding") }.allSatisfy {
            CollageStyleFineArt.adapted($0.style, from: a30, to: a20) == nil
        }, "别的样式预设一个都不动（门禁里的旧出图不变）", "")
        // 排好的页换到小册子：小字放到 2.8mm。
        let page = CollagePage(root: CollageTemplates.row(0.5, CollageTemplates.text(CollageStyleFineArt.titleText()),
                                                          CollageStyleFineArt.plate(.hero)))
        let raised = CollageStyleFineArt.readable([page], on: a20)
        let smallest = raised[0].root.leaves.compactMap(\.text).flatMap(\.lines).map(\.size).min() ?? 0
        let smallMM = smallest * a20.shortSide / a20.dpi * 25.4
        check(smallMM >= CollageStyleFineArt.minTextMM - 0.01, "30×30 排的页换到 20×20：小字放到 2.8mm",
              String(format: "%.2fmm", smallMM))
    }

    // MARK: - 跨页模板

    /// 五个模板 × 三种册子 × 竖 / 横 / 混排：套用时按真照片重排（CollageTemplates.apply → fitTemplate）。
    static func checkTemplates(book: Book, check: (Bool, String, String) -> Void) {
        print("== 跨页模板：按册子和照片的横竖重排（竖 / 横 / 横竖混排 × 30×30 / 20×20 / 30×20）")
        func photo(_ id: String, _ portrait: Bool, _ score: Double) -> CollagePhotoRef {
            Book.ref(id, 1, score, portrait: portrait, score: score)
        }
        let sets: [(String, [CollagePhotoRef])] = [
            ("竖竖竖", [photo("T1", true, 2.0), photo("T2", true, 1.5), photo("T3", true, 1.4)]),
            ("横横横", [photo("T1", false, 2.0), photo("T2", false, 1.5), photo("T3", false, 1.4)]),
            ("竖横横", [photo("T1", true, 2.0), photo("T2", false, 1.5), photo("T3", false, 1.4)]),
            ("横竖横", [photo("T1", false, 2.0), photo("T2", true, 1.5), photo("T3", false, 1.4)]),
        ]
        let templates = CollageTemplates.builtin.filter { $0.category == CollageStyleFineArt.category }
        check(templates.count == 5, "模板库里有 5 个婚礼相册模板", "\(templates.count)")
        var marginOK = true
        var textOK = true
        var windowsOK = true
        var r6OK = true
        var pairOK = true
        var tripletOK = true
        var smallestMM = Double.infinity
        var r6Worst = Double.infinity
        var notes: [String] = []
        var r6Table: [String] = []
        for canvas in [CollageCanvas.albums[0], CollageCanvas.albums[2], CollageCanvas.albums[3]] {
            let style = CollageStyleFineArt.style(for: canvas)
            let mat = style.matWidth
            let floor = canvas.pixels(mm: CollageStyleFineArt.marginFloorMM) - 1
            let halfW = Double(canvas.width) / 2
            for (setName, photos) in sets {
                let ctx = context(canvas, book: photos)
                for t in templates {
                    let page = CollageTemplates.apply(t, photos: photos, context: ctx)
                    let geo = CollageLayout.pageGeometry(page.root, canvas: canvas, style: style)
                    let frames = geo.frames.filter { $0.cell.kind == .photo }
                    for f in frames {
                        let r = f.rect
                        let toFold = Double(r.x1) <= halfW ? halfW - Double(r.x1) : Double(r.x0) - halfW
                        let edges = [Double(r.x0), Double(canvas.width - r.x1), Double(r.y0), Double(canvas.height - r.y1), toFold]
                        if (edges.min() ?? 0) < floor || (Double(r.x0) < halfW && Double(r.x1) > halfW) { marginOK = false }
                    }
                    for line in page.root.leaves.compactMap(\.text).flatMap(\.lines) {
                        let v = line.size * canvas.shortSide / canvas.dpi * 25.4
                        smallestMM = min(smallestMM, v)
                        if v < CollageStyleFineArt.minTextMM - 0.01 { textOK = false }
                    }
                    func shown(_ f: CollageLayout.Frame) -> CGRect {
                        let outer = CGRect(x: f.rect.x0, y: f.rect.y0, width: f.rect.width, height: f.rect.height)
                        if !f.cell.contain { return CollageCrop.borderInner(outer, .mat, mat: mat) }
                        let a = ctx.photos[f.cell.photoID ?? ""]?.aspect ?? 1
                        return CollageStyleFineArt.shownRect(aspect: a, in: outer, mat: mat)
                    }
                    let name = t.name.replacingOccurrences(of: "婚礼相册 · ", with: "")
                    switch CollageStyleFineArt.templateKinds[t.name] {
                    case .mainPlusTwo?:
                        // 配图：两张一样大的裁切窗口（之后拖进横的竖的都还对齐），主图 ≥ 2 倍。
                        guard let main = frames.first(where: { $0.cell.role == .hero }) else { r6OK = false; continue }
                        let supports = frames.filter { $0.cell.role != .hero }
                        // 一样大（整数切缝差一两个像素不算）。
                        let ws = supports.map(\.rect.width)
                        let hs = supports.map(\.rect.height)
                        let spread = max((ws.max() ?? 0) - (ws.min() ?? 0), (hs.max() ?? 0) - (hs.min() ?? 0))
                        if supports.count != 2 || spread > 2 || supports.contains(where: { $0.cell.contain }) {
                            windowsOK = false
                            notes.append("\(name) \(setName) \(canvas.name) 配图 \(ws)×\(hs)")
                        }
                        let mainArea = Double(shown(main).width * shown(main).height)
                        let biggest = supports.map { Double(shown($0).width * shown($0).height) }.max() ?? 1
                        let ratio = mainArea / max(1, biggest)
                        r6Worst = min(r6Worst, ratio)
                        if ratio < 1.99 { r6OK = false }
                        let short = canvas.name.replacingOccurrences(of: "相册 ", with: "").replacingOccurrences(of: "跨页", with: "")
                        r6Table.append("\(short)\(setName) \(String(format: "%.2f", 1 / ratio))")
                        // 配图不能小成邮票：每张至少主图的 0.25（30×20 横版上两张横配图并排只能这么大）。
                        if ratio > 1 / 0.25 { r6OK = false; notes.append("\(name) \(setName) \(short) 配图太小") }
                    case .triptych?:
                        let cells = frames.sorted { $0.rect.x0 < $1.rect.x0 }
                        let rects = cells.map(shown)
                        // 横图、混排是方窗：窗口（卡纸里面那一块）真是 1:1，没被垫留白省掉拉宽。
                        if setName != "竖竖竖", rects.contains(where: { abs(Double($0.width / max(1, $0.height)) - 1) > 0.02 }) {
                            tripletOK = false
                            notes.append("三联 \(setName) \(canvas.name) 窗口 \(rects.map { "\(Int($0.width))x\(Int($0.height))" })")
                        }
                        let tops = Set(rects.map { Int($0.minY.rounded()) })
                        let bottoms = Set(rects.map { Int($0.maxY.rounded()) })
                        if cells.count != 3 || cells.contains(where: { $0.cell.contain })
                            || (tops.max() ?? 0) - (tops.min() ?? 0) > 1 || (bottoms.max() ?? 0) - (bottoms.min() ?? 0) > 1 {
                            tripletOK = false
                        }
                    case .pair?:
                        let rects = frames.map(shown)
                        if rects.count == 2 {
                            let dTop = abs(Double(rects[0].minY - rects[1].minY))
                            let dBottom = abs(Double(rects[0].maxY - rects[1].maxY))
                            if max(dTop, dBottom) > 2 { pairOK = false; notes.append("\(name) \(setName) 差 \(Int(max(dTop, dBottom)))px") }
                        } else { pairOK = false }
                    default:
                        break
                    }
                }
            }
        }
        check(marginOK, "模板套到三种册子：照片离成品边、离中缝 ≥ 25mm，不跨中缝", "")
        check(textOK, "模板套到三种册子：小字 ≥ 2.8mm（20×20 上日期行放大）", String(format: "最小 %.2fmm", smallestMM))
        check(windowsOK, "一主两辅：两张配图是一样大的裁切窗口（竖 / 横 / 混排都对齐，之后拖照片进来也对齐）",
              notes.joined(separator: " · "))
        check(r6OK, "一主两辅：主图 ≥ 2 倍配图、配图不小于主图的 0.25", String(format: "最小倍数 %.2f", r6Worst)
              + " · 配图 / 主图：" + r6Table.joined(separator: " "))
        check(tripletOK, "细节三联：三张一样大的裁切窗口，上下边对齐（横图、混排是真正的方窗）", "")
        check(pairOK, "对页双图：两张照片上下边对齐（横竖混排按矮的那张同高）", "")
    }

    static func checkDateLine(check: (Bool, String, String) -> Void) {
        print("== 日期行：日子不补零（{day_num}）")
        var c = DateComponents()
        c.year = 2026
        c.month = 3
        c.day = 5
        c.hour = 12
        guard let date = Calendar(identifier: .gregorian).date(from: c) else { check(false, "日期", ""); return }
        let vars = CollageTypeset.dateVariables(date)
        let lines = CollageTypeset.expandedLines(CollageStyleFineArt.titleText(), vars: vars.merging(["title": "拾光"]) { a, _ in a })
        let dateText = lines.last?.text ?? ""
        check(vars["day_num"] == "5" && vars["day"] == "05" && dateText == "MARCH 5, 2026",
              "3 月 5 日：日期行印「MARCH 5, 2026」（{day} 还是两位的 05）", dateText)
        let caption = CollageTypeset.expandedLines(CollageStyleFineArt.captionText(CollageStyleFineArt.dateLine), vars: vars)
        check(caption.first?.text.contains(" 5, ") == true, "单图右页那行日期也不补零", caption.first?.text ?? "")
        // 照片没有拍摄时间（截图、微信转过的图、添加文件进来的）：扉页、单图右页的日期行整行不印，不剩一个「,」。
        let bare = CollageTypeset.variables(project: CollageProject(), root: .leaf(CollageCell()), photos: [:])
        let noDate = CollageTypeset.expandedLines(CollageStyleFineArt.captionText(CollageStyleFineArt.dateLine), vars: bare)
        let noDateTitle = CollageTypeset.expandedLines(CollageStyleFineArt.titleText(), vars: bare).map(\.text)
        check(bare["day_num"] == nil && noDate.isEmpty && noDateTitle == ["拾光"],
              "没有拍摄时间：单图右页的日期行不印、扉页只剩标题（不剩「,」）",
              (noDate.map(\.text) + noDateTitle).joined(separator: " ⏎ "))
    }

    // MARK: - 节奏（合成）

    static func checkPacing(check: (Bool, String, String) -> Void) {
        print("== 节奏：扉页之后不放同姿势的；同一场好几张精选（排不成对）也不连着 3 个单图跨页")
        // 一章：扉页是 W1（最宽），W2 和它同姿势、时间上紧跟着。
        var a: [CollagePhotoRef] = [Book.ref("W1", 1, 0, face: 0.002, score: 2.5, pick: true)]
        for i in 2...7 { a.append(Book.ref("W\(i)", 1, Double(i), face: 0.03, score: 1.5 + Double(i) * 0.01)) }
        let sim = CollageStyleFineArt.Similarity(kept: a, dropped: [], similar: ["W1": ["W2"], "W2": ["W1"]])
        let p1 = CollageStyleFineArt.plan(a, dedupe: true, chapterMono: true, similarity: sim)
        let second = p1.spreads.count > 1 ? p1.spreads[1].photos.map(\.id) : []
        check(p1.spreads.first?.photos.first?.id == "W1" && !second.contains("W2") && !second.isEmpty,
              "扉页 W1 之后的跨页不放同姿势的 W2", p1.spreads.map { $0.photos.map(\.id).joined(separator: "+") }.joined(separator: " → "))
        // 一章：扉页之后 8 张竖图全是同一场的精选（不是同姿势）：按「同一场不进同一跨页」只能一张一张放。
        var b: [CollagePhotoRef] = [Book.ref("S0", 1, 0, portrait: false, face: 0.002, score: 2.6, pick: true)]
        for i in 1...8 { b.append(Book.ref("S\(i)", 1, Double(i), face: 0.03, score: 1.4 + Double(i) * 0.01, pick: true, take: 9)) }
        let p2 = CollageStyleFineArt.plan(b, dedupe: true, chapterMono: true,
                                          similarity: CollageStyleFineArt.Similarity(kept: b, dropped: [], similar: [:]))
        var run = 0
        var longest = 0
        for s in p2.spreads {
            run = s.photos.count == 1 ? run + 1 : 0
            longest = max(longest, run)
        }
        let merged = p2.spreads.filter { $0.fineArt?.merged == true }.count
        let placed = p2.spreads.flatMap(\.photos).map(\.id)
        check(longest <= CollageStyleFineArt.maxSingleRun && merged > 0 && Set(placed).count == b.count,
              "同一场 8 张精选：落单的并成对页（同一场在这里放开），不连着 3 个单图",
              "最长 \(longest) · 并了 \(merged) 个 · " + p2.spreads.map { $0.photos.map(\.id).joined(separator: "+") }.joined(separator: " → "))
    }

    // MARK: - 真照片套合成标记

    /// 一批真照片套上合成的章节 / 黑白 / 细节标记（打印出来，明说是假的），按 fine-art 编一本出图。
    @MainActor
    static func renderOnPhotos(dir: URL, args: [String], check: (Bool, String, String) -> Void) {
        let outIndex = args.firstIndex(of: "--out")
        let out = URL(fileURLWithPath: outIndex.map { args[min(args.count - 1, $0 + 1)] } ?? "album_selftest")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        batch.switchSession(to: dir)
        let facts = CollageBridge.Facts(batch: batch)
        var photos = CollageSelect.chronological(batch.items.compactMap { CollageBridge.ref(from: $0, facts: facts) })
        print("== 真照片 \(photos.count) 张（\(dir.lastPathComponent)）套合成标记 —— 不是婚礼，章节、黑白、细节都是假的")
        check(!photos.isEmpty, "照片文件夹分析过（拿得到照片）", "")
        guard !photos.isEmpty else { return }
        var hints: [String: CollageCrop.Hints] = [:]
        for i in photos.indices {
            let h = CollageVision.hints(for: photos[i])
            hints[photos[i].id] = h
            photos[i].meanLuma = h.meanLuma
            // 假标记：按时间切三章；场、连拍组清掉（不然同一场只留精选，这批 21 张只剩 8 张）；
            // 第 1 章标成黑白（整章黑白）；最后两张横图之外的两张当「细节」（去掉人脸 = 呼吸 / 三联候选）。
            let third = max(1, photos.count / 3)
            photos[i].chapter = min(2, i / third)
            photos[i].take = nil
            photos[i].burstGroup = nil
            photos[i].isMonochrome = photos[i].chapter == 0
        }
        let landscapes = photos.indices.filter { !photos[$0].isPortrait }
        for i in landscapes.prefix(2) {
            photos[i].faces = []
            photos[i].faceAreaPct = nil
        }
        for p in photos {
            print("    \(p.id) 假第\((p.chapter ?? 0) + 1)章\(p.isMonochrome == true ? " 假黑白" : "")\(p.faces.isEmpty ? " 假细节" : "")")
        }
        var project = CollageProject()
        project.mode = .album
        project.photos = photos
        project.canvas = CollageCanvas.albums[0]
        project.style = CollageStyleFineArt.style(for: project.canvas)
        project.albumTheme = .fineArt
        project.title = "拾光"
        var map: [String: CollagePhotoRef] = [:]
        for p in photos { map[p.id] = p }
        let ctx = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: map, hints: hints,
                                        heroID: nil)
        // 不按画面去重：这 21 张是同一个人同一天，按画面去重只剩 9 张、三章各 3 张，看不出疏密。
        let plan = CollageAlbum.plan(photos, dedupe: false, theme: .fineArt, chapterMono: true)
        printPlan(plan)
        project.pages = CollageAlbum.build(plan, context: ctx)
        for (i, page) in project.pages.enumerated() {
            var opts = CollageRender.Options(scale: 0.4)
            opts.includeBleed = false
            guard let image = CollageRender.render(page: page, project: project, hints: hints, options: opts) else {
                check(false, "第 \(i + 1) 个跨页出图", "")
                continue
            }
            let kind = plan.spreads[i].fineArt?.kind.rawValue ?? "?"
            let url = out.appendingPathComponent(String(format: "synthetic_%02d_%@.jpg", i + 1, kind))
            try? CollageExport.write(image, to: url, format: .jpeg, quality: 0.9, dpi: 72)
        }
        // 第一个章节开篇、第一个黑白跨页再出一张导出尺寸的（看小字、黑白页的细节）。章节、黑白标记是合成的：
        // 文件名照样带 synthetic_（DESIGN §0.7：样张不能让人以为是真婚礼上验过的）。
        let wanted = [plan.spreads.firstIndex { $0.fineArt?.kind == .chapter },
                      plan.spreads.firstIndex { $0.fineArt?.look != nil && $0.fineArt?.kind == .pair }]
        for i in Set(wanted.compactMap { $0 }).sorted() {
            var opts = CollageRender.Options(scale: 1)
            opts.export = true
            opts.includeBleed = false
            guard let image = CollageRender.render(page: project.pages[i], project: project, hints: hints, options: opts) else {
                continue
            }
            let kind = plan.spreads[i].fineArt?.kind.rawValue ?? "?"
            let url = out.appendingPathComponent(String(format: "synthetic_export_%02d_%@.jpg", i + 1, kind))
            try? CollageExport.write(image, to: url, format: .jpeg, quality: 0.9, dpi: 300)
        }
        check(project.pages.count == plan.spreads.count, "真照片套合成标记：每个跨页都出了图",
              "\(project.pages.count) 张 → \(out.path)")
    }
}
