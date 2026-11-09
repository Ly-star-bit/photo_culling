import Foundation
import CoreGraphics

/// --album-selftest 里相册封面（CollageBookCover）的几条，合成数据、不要照片：
/// 1. 尺寸换算：单页宽高、书脊、包边、出血（mm ↔ 像素）、整张和三块的位置，缩放后的取整和 CollageRender 一样；
/// 2. 书脊估算：P 数 × 每张纸厚 ÷ 2 + 2 × 板厚，填了用填的，不到 6mm 不印字（提示）；
/// 3. 书脊竖排：中文一个个立着从上往下，拉丁字母、数字整段转 90°，都在书脊里、从上往下、居中；
/// 4. 旧工程读回：没有 bookCover 键 = nil、存出来也不写这个键；坏值夹回范围，封面坏了只丢封面；
/// 5. 做封面：主图用扉页那张、标题日期照扉页，没有扉页挑分数最高有人脸的；
/// 6. 编辑封面（store.editingCover）：选格子、换照片、改字、对调、删格、加字都只改封面，pages 逐字节不变；撤销、换跨页、
///    去掉封面、切回单张都退出编辑；拿出托盘、「移除没用上的」、方案快照、废纸篓保护都算上封面的照片；
/// 7. 渲染：整张的像素尺寸、包边出血是镜像、封面 PDF 的 TrimBox / BleedBox。
enum CollageBookCoverSelfTest {

    @MainActor
    static func run(check: (Bool, String, String) -> Void) {
        checkLayout(check: check)
        checkSpineEstimate(check: check)
        checkSpineText(check: check)
        checkPersistence(check: check)
        checkMake(check: check)
        checkStore(check: check)
        checkRender(check: check)
    }

    // MARK: - 合成数据

    static func ref(_ id: String, score: Double, faces: [[Double]] = [], portrait: Bool = false,
                    verdict: CollageVerdict? = .pick) -> CollagePhotoRef {
        var p = CollagePhotoRef(id: id, path: "/nonexistent/\(id).jpg", width: portrait ? 4000 : 6000,
                                height: portrait ? 6000 : 4000)
        p.score = score
        p.faces = faces
        p.verdict = verdict
        p.captureTime = Date(timeIntervalSince1970: 1_773_000_000)
        return p
    }

    /// 一本两个跨页的相册：第一个是扉页（左页竖排标题 + 印章，右页 A），第二个三张。
    static func album() -> CollageProject {
        var p = CollageProject()
        p.mode = .album
        p.canvas = CollageCanvas.albums[0]
        p.title = "拾光"
        p.photos = [ref("A", score: 0.7, faces: [[0.4, 0.2, 0.5, 0.35]]),
                    ref("B", score: 0.9, faces: [[0.45, 0.25, 0.55, 0.4]], portrait: true),
                    ref("C", score: 0.6), ref("D", score: 0.5), ref("E", score: 0.95, verdict: .reject)]
        var title = CollageTemplates.verticalTitle(size: 0.075, seal: "拾光")
        title.alignH = .center
        title.alignV = .center
        p.pages = [CollagePage(root: CollageTemplates.row(0.5, CollageTemplates.text(title), .leaf(.photo("A", role: .hero)))),
                   CollagePage(root: .split(.row, 0.5, .leaf(.photo("B")),
                                            .split(.column, 0.5, .leaf(.photo("C")), .leaf(.photo("D")))))]
        return p
    }

    // MARK: - 1. 尺寸

    static func checkLayout(check: (Bool, String, String) -> Void) {
        print("== 封面尺寸")
        let canvas = CollageCanvas.albums[0]  // 30×30cm 跨页，300dpi，出血 3mm，安全区 5mm
        var cover = CollageBookCover(front: .leaf(.photo(nil)))
        cover.spineMM = 12.5
        cover.wrapMM = 15
        let l = cover.layout(canvas: canvas, spreads: 20)
        let px: (Double) -> Int = { Int(($0 / 25.4 * canvas.dpi).rounded()) }
        check(l.pageW == canvas.width / 2 && l.pageH == canvas.height, "单页宽高 = 跨页画布宽的一半 × 高",
              "\(l.pageW)×\(l.pageH)")
        check(l.spine == px(12.5) && l.wrap == px(15) && l.bleed == canvas.bleed, "书脊 12.5mm、包边 15mm、出血照画布",
              "书脊 \(l.spine)px 包边 \(l.wrap)px 出血 \(l.bleed)px")
        let widthMM = Double(l.width) / canvas.dpi * 25.4
        let heightMM = Double(l.height) / canvas.dpi * 25.4
        check(abs(widthMM - (300 * 2 + 12.5 + 2 * 18)) < 0.5 && abs(heightMM - (300 + 2 * 18)) < 0.5,
              "整张 = 两页 + 书脊 + 两边包边出血", String(format: "%.1f×%.1f mm", widthMM, heightMM))
        let ordered = l.back.maxX == l.spineRect.minX && l.spineRect.maxX == l.front.minX
            && l.back.minX == l.trim.minX && l.front.maxX == l.trim.maxX
            && l.trim.minX == CGFloat(l.extent) && l.trim.maxX == CGFloat(l.width - l.extent)
            && l.trim.minY == CGFloat(l.extent) && l.trim.maxY == CGFloat(l.height - l.extent)
        check(ordered, "封底 | 书脊 | 封面 挨着排、四周各留包边 + 出血",
              "封底 \(Int(l.back.minX))… 书脊 \(Int(l.spineRect.minX))… 封面 \(Int(l.front.minX))…\(Int(l.front.maxX))")
        // 缩放后的单页宽高和 CollageRender 渲封面那一页时的取整一样（拼起来不差一个像素）。
        let front = CollageBookCover.frontCanvas(canvas)
        let s = 0.137
        let ls = cover.layout(canvas: canvas, spreads: 20, scale: s)
        check(ls.pageW == Int((Double(front.width) * s).rounded()) && ls.pageH == Int((Double(front.height) * s).rounded()),
              "缩放后单页宽高和渲染器同一种取整", "\(ls.pageW)×\(ls.pageH)")
        check(front.seams == .none && front.bleed == 0 && front.safe == canvas.safe && front.dpi == canvas.dpi
              && front.width == canvas.width / 2,
              "封面那一页的画布：单页、没有中缝、没有出血、安全区照画布", "\(front.width)×\(front.height)")
    }

    // MARK: - 2. 书脊估算

    static func checkSpineEstimate(check: (Bool, String, String) -> Void) {
        print("== 书脊估算")
        var c = CollageBookCover(front: .leaf(.photo(nil)))
        c.sheetMM = 0.15
        c.boardMM = 2
        check(abs(c.estimatedSpineMM(spreads: 20) - (40 * 0.15 / 2 + 4)) < 1e-9 && c.spineWidthMM(spreads: 20) == c.estimatedSpineMM(spreads: 20),
              "20 个跨页 = 40P：40 × 0.15 ÷ 2 + 2 × 2 = 7mm，没填就用估的", String(format: "%.2f mm", c.estimatedSpineMM(spreads: 20)))
        c.spineMM = 12.5
        check(c.spineWidthMM(spreads: 20) == 12.5, "填了印厂给的数就用填的", "12.5 mm")
        check(CollageBookCover.defaultSheetMM(.glued) < CollageBookCover.defaultSheetMM(.layflat),
              "每张纸厚的默认值：平铺对裱比胶装厚", "\(CollageBookCover.defaultSheetMM(.glued)) / \(CollageBookCover.defaultSheetMM(.layflat))")
        c.spineMM = nil
        let notes = c.notes(spreads: 20)
        check(notes.contains { $0.contains("估的") && $0.contains("40P") && $0.contains("照印厂给的数改") },
              "没填书脊：提示里写明是估的、怎么估的", notes.first ?? "")
        c.spineMM = 5
        let narrow = c.notes(spreads: 20)
        check(!CollageBookCover.spineFitsText(5.9) && CollageBookCover.spineFitsText(6)
              && narrow.contains { $0.contains("放不下字") } && !narrow.contains { $0.contains("估的") },
              "书脊不到 6mm：不印字并提示", narrow.joined(separator: "；"))
        c.spineTitle = ""
        c.spineDate = " "
        check(c.notes(spreads: 20).isEmpty, "书脊没字：太窄也不提示", "")
    }

    // MARK: - 3. 书脊竖排

    static func checkSpineText(check: (Bool, String, String) -> Void) {
        print("== 书脊竖排")
        let runs = CollageBookCoverRender.spineRuns("林 & 苏 Wedding 2026")
        let want = [CollageBookCoverRender.SpineRun(text: "林", upright: true),
                    CollageBookCoverRender.SpineRun(text: " & ", upright: false),
                    CollageBookCoverRender.SpineRun(text: "苏", upright: true),
                    CollageBookCoverRender.SpineRun(text: " Wedding 2026", upright: false)]
        check(runs == want, "中文一个字一段立着，拉丁字母、数字、空格连成一段转着",
              runs.map { ($0.upright ? "立" : "转") + "「\($0.text)」" }.joined(separator: " "))
        let latin = CollageBookCoverRender.spineRuns("Spring Notes")
        check(latin.count == 1 && !latin[0].upright, "纯西文：整段转 90°", latin.first?.text ?? "")
        check(CollageBookCoverRender.spineRuns("　春日「宴」").allSatisfy(\.upright), "全角标点也立着排", "")

        let canvas = CollageCanvas.albums[0]
        var cover = CollageBookCover(front: .leaf(.photo(nil)))
        cover.spineMM = 12.5
        cover.spineTitle = "拾光 Spring"
        cover.spineDate = "{date}"
        let vars = ["title": "拾光", "date": "2026.03.14"]
        let l = cover.layout(canvas: canvas, spreads: 20)
        guard let s = CollageBookCoverRender.spineLayout(cover: cover, vars: vars, rect: l.spineRect, spineMM: 12.5,
                                                         canvas: canvas, scale: 1) else {
            check(false, "12.5mm 书脊排得下字", "nil")
            return
        }
        let texts = s.glyphs.map { ($0.upright ? "立" : "转") + $0.text }
        check(texts == ["立拾", "立光", "转 Spring", "转2026.03.14"], "标题、日期按段排：拾 光 立着，Spring、日期转着",
              texts.joined(separator: " "))
        let inside = s.glyphs.allSatisfy { l.spineRect.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }
        let ordered = zip(s.glyphs, s.glyphs.dropFirst()).allSatisfy { $0.frame.maxY <= $1.frame.minY + 0.5 }
        let centered = s.glyphs.allSatisfy { abs($0.frame.midX - l.spineRect.midX) < 1 }
        check(inside && ordered && centered, "都在书脊里、从上往下不重叠、横向居中在书脊中线上",
              String(format: "字号 %.0fpx · 书脊 %.0fpx 宽", Double(s.fontSize), Double(l.spineRect.width)))
        let top = s.glyphs.first.map { $0.frame.minY - l.spineRect.minY } ?? 0
        let bottom = s.glyphs.last.map { l.spineRect.maxY - $0.frame.maxY } ?? 0
        check(top > 0 && abs(top - bottom) < 2 && top >= CGFloat(canvas.safe),
              "标题从上头排、日期排到下头，上下留一样的边（不小于安全区）", String(format: "上 %.0f 下 %.0f", top, bottom))
        // 转着的段：基线朝下（+y）、字头朝右（+x）—— 段的起点在最上面，字框横跨书脊中线。
        if let rotated = s.glyphs.first(where: { !$0.upright }) {
            check(rotated.origin.y == rotated.frame.minY && rotated.frame.minX < l.spineRect.midX && rotated.frame.maxX > l.spineRect.midX,
                  "转着的段从最上面那一头起排（从上往下读）", "")
        }
        // 字号：书脊宽的一半以内；很长的标题一起缩，不出书脊。
        var long = cover
        long.spineTitle = String(repeating: "很长的相册标题", count: 12)
        if let ls = CollageBookCoverRender.spineLayout(cover: long, vars: vars, rect: l.spineRect, spineMM: 12.5,
                                                       canvas: canvas, scale: 1) {
            let fits = ls.glyphs.allSatisfy { l.spineRect.contains($0.frame.insetBy(dx: 0.5, dy: 0.5)) }
            check(ls.fontSize < s.fontSize && fits, "标题太长：一起缩小，不出书脊", String(format: "字号 %.0fpx", Double(ls.fontSize)))
        } else {
            check(false, "标题太长：一起缩小，不出书脊", "nil")
        }
        check(s.fontSize <= l.spineRect.width * 0.5 + 0.01, "字号不超过书脊宽的一半", "")
        let narrow = CollageBookCoverRender.spineLayout(cover: cover, vars: vars, rect: l.spineRect, spineMM: 5.5,
                                                        canvas: canvas, scale: 1)
        check(narrow == nil, "书脊 5.5mm（不到 6mm）：不排字", "")
        // 真画出来看朝向（CoreText 的竖排字形放进一行横排会被整个转躺下，量排版框抓不到，要量墨）：
        // 「一」立着是一横（宽 > 高）；「-」转 90° 是一竖（高 > 宽）；
        // 转着的「op」比「oo」往左多出一截（p 的降部朝左 = 字头朝右，顺时针转），墨都落在这一段的排版框里（从上往下排，
        // 不是从起点往上）。
        let one = spineInk("一", cover: cover, canvas: canvas)
        let dash = spineInk("-", cover: cover, canvas: canvas)
        check((one.map { $0.box.width > $0.box.height * 2 } ?? false) && (dash.map { $0.box.height > $0.box.width * 2 } ?? false),
              "画出来的朝向：中文立着（「一」是一横），西文转 90°（「-」是一竖）",
              "一 \(one.map { "\(Int($0.box.width))×\(Int($0.box.height))" } ?? "无") · - \(dash.map { "\(Int($0.box.width))×\(Int($0.box.height))" } ?? "无")")
        if let op = spineInk("op", cover: cover, canvas: canvas), let oo = spineInk("oo", cover: cover, canvas: canvas) {
            // 降部伸出去的那一截比字头那边多出来的（衬线、字面高低）大得多。
            let descenderLeft = oo.box.minX - op.box.minX > 3 * max(1, op.box.maxX - oo.box.maxX)
            let inFrame = oo.frame.insetBy(dx: -1, dy: -1).contains(oo.box)
            check(descenderLeft && inFrame, "西文顺时针转 90°：降部朝左（字头朝右）、从上往下排",
                  "op \(Int(op.box.minX))…\(Int(op.box.maxX)) / oo \(Int(oo.box.minX))…\(Int(oo.box.maxX)) · 墨 \(Int(oo.box.minY))…\(Int(oo.box.maxY)) 在框 \(Int(oo.frame.minY))…\(Int(oo.frame.maxY)) 里")
        } else {
            check(false, "西文顺时针转 90°：画得出来", "")
        }
    }

    /// 只排一段书脊字（没有日期），画在白底上，量墨的外框（左上原点像素）和第一段的排版框。
    static func spineInk(_ title: String, cover: CollageBookCover, canvas: CollageCanvas) -> (box: CGRect, frame: CGRect)? {
        var c = cover
        c.spineTitle = title
        c.spineDate = ""
        let w = 160, h = 1200
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let layout = CollageBookCoverRender.spineLayout(cover: c, vars: [:], rect: rect, spineMM: 13.5, canvas: canvas, scale: 1),
              let first = layout.glyphs.first, let ctx = CollageRender.makeContext(width: w, height: h) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        CollageBookCoverRender.drawSpine(layout, ctx: ctx, color: .ink)
        guard let img = ctx.makeImage(), let px = pixels(img) else { return nil }
        var box = CGRect.null
        for x in 0..<w {
            for y in 0..<h where luma(px(x, y)) < 0.5 { box = box.union(CGRect(x: x, y: y, width: 1, height: 1)) }
        }
        let frame = layout.glyphs.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        return box.isNull ? nil : (box, frame)
    }

    // MARK: - 4. 存盘

    static func checkPersistence(check: (Bool, String, String) -> Void) {
        print("== 封面存盘、旧工程读回")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var old = album()
        old.bookCover = nil
        guard let data = try? encoder.encode(old), let json = String(data: data, encoding: .utf8) else {
            check(false, "工程编得出来", "")
            return
        }
        check(!json.contains("bookCover"), "没有封面：存盘不写 bookCover 这个键（旧工程存出来不变）", "")
        let back = try? JSONDecoder().decode(CollageProject.self, from: data)
        check(back?.bookCover == nil && back?.pages.count == 2, "旧工程（没有这个键）读回来 = 不做封面", "")

        var with = old
        var cover = CollageBookCover.make(project: old)!
        cover.spineMM = 12.5
        cover.wrapMM = 18
        cover.back = CollageBookCoverBack(photoID: "B", text: "{date}")
        cover.spineTitle = "林 & 苏"
        with.bookCover = cover
        let round = (try? encoder.encode(with)).flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
        check(round?.bookCover == cover && round == with, "有封面：存了再读回来一样", "")

        // 坏值：夹回范围；封面那块坏了只丢封面。
        if let d = try? encoder.encode(with), var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           var c = obj["bookCover"] as? [String: Any] {
            c["wrapMM"] = -5
            c["spineMM"] = 1e9
            c["sheetMM"] = "厚"
            c["boardMM"] = 99
            c["back"] = 3
            obj["bookCover"] = c
            let bad = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
            let b = bad?.bookCover
            check(b?.wrapMM == 0 && b?.spineMM == CollageBookCover.spineRange.upperBound
                  && b?.sheetMM == CollageBookCover.defaultSheetMM(.layflat) && b?.boardMM == CollageBookCover.boardRange.upperBound
                  && b?.back == CollageBookCoverBack() && b?.front == cover.front,
                  "坏值夹回范围（包边 −5 → 0、书脊 1e9 → 150、纸厚不是数 → 默认、板厚 99 → 10、封底坏了 = 留白）",
                  b.map { "包边 \($0.wrapMM) 书脊 \($0.spineMM ?? -1) 纸 \($0.sheetMM) 板 \($0.boardMM)" } ?? "nil")
            c["front"] = "坏了"
            obj["bookCover"] = c
            let broken = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
            check(broken != nil && broken?.bookCover == nil && broken?.pages.count == 2,
                  "封面那块坏了：只丢封面，工程照常读回", "")
        } else {
            check(false, "坏值：编得出来", "")
        }
        // 方案快照、废纸篓保护：只上了封面的那张也算。
        var onlyCover = with
        onlyCover.bookCover?.back.photoID = "E"
        check(onlyCover.variantSnapshot.photos.contains { $0.id == "E" } && onlyCover.photoIDsInUseIncludingVariants.contains("E")
              && !onlyCover.usedPhotoIDs.contains("E"),
              "只上了封面的照片：方案快照留着、废纸篓保护算它（usedPhotoIDs 照旧只看跨页）", "")
        check(with.sameDesign(as: with) && !old.sameDesign(as: with), "方案比对：有没有封面不是同一版", "")
    }

    // MARK: - 5. 做封面

    static func checkMake(check: (Bool, String, String) -> Void) {
        print("== 做封面")
        let p = album()
        guard let cover = CollageBookCover.make(project: p) else {
            check(false, "有扉页：做得出封面", "nil")
            return
        }
        let opener = p.pages[0].root.leaves.first { $0.kind == .text }?.text
        let text = cover.front.leaves.first { $0.kind == .text }?.text
        check(cover.front.photoIDs == ["A"], "主图用扉页那张（不是分数最高的 B）", cover.front.photoIDs.joined())
        check(text?.lines == opener?.lines && text?.seal == opener?.seal, "标题、日期照扉页（字体、字号、印章一样）",
              text?.lines.map(\.text).joined(separator: " / ") ?? "")
        check(!cover.front.isLeaf && cover.front.axis == .row && cover.front.children[0].cell?.photoID == "A",
              "竖排标题：照片在左（靠书脊）、字在右", "")
        check(cover.sheetMM == CollageBookCover.defaultSheetMM(.layflat) && cover.spineMM == nil && cover.wrapMM == 15
              && cover.boardMM == 2, "默认：书脊按估算、包边 15mm、板厚 2mm、纸厚按装订", "")
        var glued = p
        glued.canvas.binding = .glued
        check(CollageBookCover.make(project: glued)?.sheetMM == CollageBookCover.defaultSheetMM(.glued), "胶装：纸厚按胶装的默认值", "")

        // 婚礼扉页：标题、日期两格 → 并成一块横排。
        var fine = p
        let titleCell = CollageText(lines: [CollageTextLine("{title}", size: 0.04)], vertical: false)
        let dateCell = CollageText(lines: [CollageTextLine("{date}", size: 0.0115)], vertical: false)
        fine.pages[0] = CollagePage(root: .split(.row, 0.5,
                                                 .split(.column, 0.5, CollageTemplates.text(titleCell), CollageTemplates.text(dateCell)),
                                                 .leaf(.photo("C"))))
        let fineCover = CollageBookCover.make(project: fine)
        let merged = fineCover?.front.leaves.first { $0.kind == .text }?.text
        check(fineCover?.front.photoIDs == ["C"] && merged?.lines.map(\.text) == ["{title}", "{date}"]
              && fineCover?.front.axis == .column,
              "扉页拆成标题、日期两格：并成一块，横排照片在上、字在下", merged?.lines.map(\.text).joined(separator: " ") ?? "")

        // 没有扉页：分数最高、有人脸的（废片不要）。
        var noOpener = p
        noOpener.pages.removeFirst()
        check(CollageBookCover.make(project: noOpener)?.front.photoIDs == ["B"],
              "没有扉页：挑分数最高、有人脸的（E 分数更高但是废片，C 没有人脸）", "")
        var faceless = noOpener
        for i in faceless.photos.indices { faceless.photos[i].faces = [] }
        check(CollageBookCover.make(project: faceless)?.front.photoIDs == ["B"], "都没有人脸：分数最高的（废片不要）", "")
        var empty = CollageProject()
        empty.mode = .album
        check(CollageBookCover.make(project: empty) == nil, "托盘是空的：做不出封面", "")

        // 脸贴着书脊：横图、脸在最左边，封面那一页一整格。零边距 → 脸离书脊那条折线不到 12mm，提醒；默认边距（13.5mm）
        // 不提醒；脸在中间不提醒。
        var edge = p
        edge.photos.append(ref("F", score: 0.5, faces: [[0.0, 0.3, 0.08, 0.45]]))
        edge.photos.append(ref("G", score: 0.5, faces: [[0.46, 0.3, 0.54, 0.45]]))
        let left = CollageBookCover(front: .leaf(.photo("F")))
        let middle = CollageBookCover(front: .leaf(.photo("G")))
        let defaultMargin = left.faceWarnings(project: edge, hints: [:])
        var bleed = edge
        bleed.style.margin = 0
        let tight = left.faceWarnings(project: bleed, hints: [:])
        check(tight.count == 1 && tight[0].contains("书脊") && defaultMargin.isEmpty && middle.faceWarnings(project: bleed, hints: [:]).isEmpty,
              "脸贴着书脊（零边距、脸在最左边）：提醒；默认边距、脸在中间：不提醒", tight.first ?? "无")
        // 导出前检查：书脊是估的、太窄、脸贴书脊各一条提醒（不拦、不指到跨页）；没有封面一条都没有。
        var pre = bleed
        var narrowCover = left
        narrowCover.spineMM = nil
        narrowCover.sheetMM = 0.02
        narrowCover.boardMM = 0.5
        pre.bookCover = narrowCover
        let issues = CollagePreflight.run(project: pre, hints: [:], texts: false).filter { $0.kind == .cover }
        let noCover = CollagePreflight.run(project: bleed, hints: [:], texts: false).filter { $0.kind == .cover }
        check(issues.count == 3 && issues.allSatisfy { $0.severity == .warn && $0.page == nil }
              && issues.contains { $0.message.contains("估的") } && issues.contains { $0.message.contains("放不下字") }
              && issues.contains { $0.photoID == "F" && $0.message.contains("书脊") } && noCover.isEmpty,
              "导出前检查：封面三条提醒（书脊估的、太窄没印字、脸贴书脊）", issues.map(\.message).joined(separator: "；"))
    }

    // MARK: - 6. 编辑封面

    @MainActor
    static func checkStore(check: (Bool, String, String) -> Void) {
        print("== 编辑封面（store.editingCover）")
        let dir = appDataDir.appendingPathComponent("bookcover-selftest-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CollageStore(dataDir: dir)
        store.loadForTesting(album())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let pagesBefore = try? encoder.encode(store.project.pages)
        let depth0 = store.undoDepth
        store.setEditingCover(true)
        check(!store.editingCover, "没有封面：进不去封面编辑", "")
        check(store.makeCover() && store.project.bookCover != nil && store.undoDepth == depth0 + 1, "做封面：一步撤销", "")
        check(!store.makeCover(), "已经有封面：再点「做封面」不重做", store.notice ?? "")
        store.pageIndex = 1
        store.setEditingCover(true)
        guard store.editingCover, let cover = store.project.bookCover else {
            check(false, "有封面：进得去封面编辑", "")
            return
        }
        let frontCanvas = CollageBookCover.frontCanvas(store.project.canvas)
        check(store.pageIndex == 1 && store.page?.id == cover.id && store.root == cover.front,
              "编辑封面：不动 pageIndex，当前页 = 封面那块（id 是封面的）", "pageIndex \(store.pageIndex)")
        let maxX = store.geometry.frames.map(\.rect.x1).max() ?? 0
        check(store.editCanvas == frontCanvas && maxX <= frontCanvas.width && maxX > frontCanvas.width / 2,
              "几何按封面那一页算（单页宽，没有中缝）", "最右 \(maxX) / \(frontCanvas.width)")
        let photoPath = cover.front.leafPaths().first { cover.front.node(at: $0)?.cell?.kind == .photo } ?? []
        let textPath = cover.front.leafPaths().first { cover.front.node(at: $0)?.cell?.kind == .text } ?? []
        store.selection = photoPath
        check(store.selectedCell?.photoID == "A", "选中封面上的照片格", "")
        // 换照片：B 已经在第 2 个跨页上，封面照样能用；走画布同一个入口 place。
        store.place(photoID: "B", at: photoPath, edge: nil)
        check(store.project.bookCover?.front.node(at: photoPath)?.cell?.photoID == "B" && store.selection == photoPath,
              "换照片（place）：封面那一格换成 B（跨页上已经有 B 也能放），选中那一格", "")
        store.setFraming(.half)
        check(store.project.bookCover?.front.node(at: photoPath)?.cell?.framing == .half, "改景别落在封面上", "")
        // 改字：走文字编辑器同一个入口（目标带封面的 id）。
        var t = store.project.bookCover?.front.node(at: textPath)?.cell?.text ?? CollageText()
        t.lines[0].text = "林 & 苏"
        store.updateText(t, target: .cell(textPath, cover.id))
        store.endCoalescing()
        check(store.project.bookCover?.front.node(at: textPath)?.cell?.text?.lines.first?.text == "林 & 苏", "改字落在封面上", "")
        store.updateText(t, target: .cell(textPath, store.project.pages[1].id))
        store.swap(photoPath, textPath)
        check(store.project.bookCover?.front.node(at: textPath)?.cell?.photoID == "B", "对调两格", "")
        store.removeCell(photoPath)
        let afterRemove = store.project.bookCover?.front
        check(afterRemove?.isLeaf == true && afterRemove?.cell?.photoID == "B",
              "删一格：剩下的那一格顶上来（不按跨页补成左右两个空页）", afterRemove.map { $0.isLeaf ? "一格" : "两格" } ?? "")
        store.selection = nil
        store.addTextCell(edge: .bottom, vertical: false)
        let withText = store.project.bookCover?.front
        check(withText?.axis == .column && withText?.children.count == 2 && withText?.children[1].cell?.kind == .text,
              "加文字格：整块下面加一条（不按中缝只加在右页）", "")
        let pagesNow = try? encoder.encode(store.project.pages)
        check(pagesBefore != nil && pagesNow == pagesBefore, "编辑封面这一串：pages 逐字节没变", "")
        // 撤销回到刚做好的封面。
        while store.undoDepth > depth0 + 1 { store.undo() }
        check(store.project.bookCover?.front == cover.front && (try? encoder.encode(store.project.pages)) == pagesBefore,
              "撤销回到刚做好的封面", "")
        check(store.editingCover, "撤销（封面还在）：还在编辑封面", "")
        // 换跨页退出。
        store.pageIndex = 0
        check(!store.editingCover && store.page?.id == store.project.pages[0].id, "换到别的跨页：退出封面编辑", "")
        store.setEditingCover(true)
        store.removeCover()
        check(!store.editingCover && store.project.bookCover == nil, "去掉封面：退出封面编辑", "")
        store.undo()
        check(store.project.bookCover != nil && !store.editingCover, "撤销去掉：封面回来，不自动进编辑", "")
        store.setEditingCover(true)
        store.setMode(.single)
        check(!store.editingCover, "切回单张：退出封面编辑", "")
        store.undo()
        // 托盘：只上了封面的不算「没用上」；拿出托盘时封面那一格变空格。
        let unusedBefore = store.unusedTrayIDs.contains("E")
        store.setCoverBackPhoto("E")
        check(unusedBefore && !store.unusedTrayIDs.contains("E") && store.project.bookCover?.back.photoID == "E",
              "只上了封面（封底）的照片不算「没用上」", store.unusedTrayIDs.joined(separator: " "))
        store.removeFromTray(["A"])
        check(store.project.bookCover?.front.photoIDs.contains("A") == false
              && store.project.bookCover?.front.leaves.contains { $0.kind == .photo && $0.photoID == nil } == true,
              "拿出托盘：封面上那一格变空格", "")
        // 书脊、包边：数字框连着敲合成一步，ops 每步一步。
        let d = store.undoDepth
        store.setCoverSpine(12)
        store.setCoverSpine(12.5)
        check(store.project.bookCover?.spineMM == 12.5 && store.undoDepth == d + 1, "书脊宽连着改：一步撤销", "")
        store.endCoalescing()
        store.setCoverWrap(-3)
        store.endCoalescing()
        store.setCoverSpine(nil)
        check(store.project.bookCover?.wrapMM == 0 && store.project.bookCover?.spineMM == nil, "包边夹到 0；书脊清空 = 按估算", "")
        // 不在编辑封面时 placeOnCover 照样能用（MCP、ops），选中不动。
        store.setEditingCover(false)
        store.selection = [0]
        let path = store.project.bookCover?.front.leafPaths().first { store.project.bookCover?.front.node(at: $0)?.cell?.kind == .photo } ?? []
        store.placeOnCover(photoID: "C", at: path, edge: nil)
        check(store.project.bookCover?.front.node(at: path)?.cell?.photoID == "C" && store.selection == [0],
              "没在编辑封面：placeOnCover 照样换照片，不碰跨页的选中", "")
    }

    // MARK: - 7. 渲染

    static func checkRender(check: (Bool, String, String) -> Void) {
        print("== 封面渲染（合成：没有照片文件，格子空着）")
        var p = album()
        var cover = CollageBookCover.make(project: p)!
        cover.spineMM = 12.5
        cover.back.text = "MMXXVI"
        p.bookCover = cover
        let scale = 0.12
        var opts = CollageRender.Options(scale: scale)
        opts.includeBleed = true
        let l = cover.layout(canvas: p.canvas, spreads: p.pages.count, scale: scale)
        guard let image = CollageBookCoverRender.render(project: p, hints: [:], options: opts) else {
            check(false, "渲得出整张封面", "nil")
            return
        }
        check(image.width == l.width && image.height == l.height, "整张封面的像素 = 几何算的（带包边、出血）",
              "\(image.width)×\(image.height)")
        var trimOpts = opts
        trimOpts.includeBleed = false
        let trim = CollageBookCoverRender.render(project: p, hints: [:], options: trimOpts)
        check(trim?.width == Int(l.trim.width) && trim?.height == Int(l.trim.height), "不带包边：只要封底 | 书脊 | 封面",
              "\(trim?.width ?? 0)×\(trim?.height ?? 0)")
        var single = p
        single.mode = .single
        check(CollageBookCoverRender.render(project: single, hints: [:], options: opts) == nil, "不是相册：不出封面", "")
        checkMirror(check: check)
        checkEdgeSpans(check: check)
        if let px = pixels(image) {
            // 合成的这本：边距 4.5% 短边（13.5mm）比包边 + 出血（18mm）窄，四边贴边的都是底色 —— 包边一整圈铺底色，不把
            // 照片、字的一条边翻出去。
            let bg = px(1, 1)
            var clean = true
            for x in stride(from: 0, to: image.width, by: 3) where px(x, 0) != bg || px(x, image.height - 1) != bg { clean = false }
            for y in stride(from: 0, to: image.height, by: 3) where px(0, y) != bg || px(image.width - 1, y) != bg { clean = false }
            check(clean, "边上是底色：包边、出血整圈铺底色（不镜像出一条照片边）", "")
            // 书脊上有字（墨色比底色深的像素），书脊外面挨着的一条没有字压过去。
            let spine = l.spineRect
            var ink = 0
            for x in Int(spine.minX)..<Int(spine.maxX) {
                for y in stride(from: Int(spine.minY), to: Int(spine.maxY), by: 1) where luma(px(x, y)) < 0.5 { ink += 1 }
            }
            check(ink > 20, "书脊上印了字", "\(ink) 个深色像素")
        } else {
            check(false, "读得到像素", "")
        }
        // 窄书脊：没字。
        var narrow = p
        narrow.bookCover?.spineMM = 4
        let ln = narrow.bookCover!.layout(canvas: narrow.canvas, spreads: narrow.pages.count, scale: scale)
        if let img = CollageBookCoverRender.render(project: narrow, hints: [:], options: opts), let px = pixels(img) {
            var ink = 0
            for x in Int(ln.spineRect.minX)..<Int(ln.spineRect.maxX) {
                for y in Int(ln.spineRect.minY)..<Int(ln.spineRect.maxY) where luma(px(x, y)) < 0.5 { ink += 1 }
            }
            check(ink == 0, "书脊 4mm：书脊上没有字", "\(ink) 个深色像素")
        }
        // 封面 PDF：一页，TrimBox = 看得见的那块，BleedBox = 整张。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookcover-pdf-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("测试_封面.pdf")
        if let jpeg = CollageExport.encode(image, format: .jpeg, quality: 0.8, dpi: p.canvas.dpi * scale) {
            do {
                try CollageExport.writeCoverPDF(page: .data(jpeg), layout: l, dpi: p.canvas.dpi * scale, to: url, title: "拾光",
                                                cropMarks: true)
                let doc = CGPDFDocument(url as CFURL)
                let page = doc?.page(at: 1)
                let boxes = CollageExport.coverPDFBoxes(layout: l, dpi: p.canvas.dpi * scale, cropMarks: true)
                let trimBox = page?.getBoxRect(.trimBox) ?? .zero
                let bleedBox = page?.getBoxRect(.bleedBox) ?? .zero
                let close: (CGRect, CGRect) -> Bool = { a, b in
                    abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01
                        && abs(a.height - b.height) < 0.01
                }
                let trimMM = Double(trimBox.width) / 72 * 25.4
                check(doc?.numberOfPages == 1 && close(trimBox, boxes.trim) && close(bleedBox, boxes.bleed)
                      && abs(trimMM - (600 + 12.5)) < 1,
                      "封面 PDF：一页，TrimBox = 封底 | 书脊 | 封面，BleedBox = 整张（带包边出血）",
                      String(format: "Trim 宽 %.1f mm", trimMM))
                var again = false
                do {
                    try CollageExport.writeCoverPDF(page: .data(jpeg), layout: l, dpi: p.canvas.dpi * scale, to: url, title: "拾光",
                                                    cropMarks: true)
                } catch { again = true }
                let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".tmp") }
                check(again && leftovers.isEmpty, "同名已经有了：不覆盖、报错，不留临时文件", "")
            } catch {
                check(false, "封面 PDF 写得出来", error.localizedDescription)
            }
        }
        // 导出的文件名：相册、有封面才有；勾了 PDF 才有封面 PDF。
        var o = CollageStore.ExportOptions()
        o.format = .png
        o.pdf = false
        let all = CollageStore.ExportOptions()
        let full = CollageStore.exportPlan(base: "春", project: p, options: all)
        check(CollageStore.exportPlan(base: "春", project: p, options: o).cover == ["春_封面.png"]
              && full.cover == ["春_封面.jpg", "春_封面.pdf"] && full.allFiles.suffix(2) == ["春_封面.jpg", "春_封面.pdf"]
              && CollageStore.exportPlan(base: "春", project: p, options: all, only: [0]).cover.isEmpty
              && CollageStore.exportPlan(base: "春", project: album(), options: all).cover.isEmpty,
              "导出清单里的封面：名_封面.<格式>（+ 名_封面.pdf），排在跨页 PDF 后面；部分导出、没有封面不写", "")
        // 看版 PDF 的封面页：页脚「封面 · 标题」，照片按封面那一页的阅读顺序、再是封底那张。
        var proofProject = p
        proofProject.bookCover?.back.photoID = "B"
        let proof = CollageBookCoverRender.proofPage(project: proofProject, hints: [:])
        check(proof?.heading == "封面 · 拾光" && proof?.names == ["A.jpg", "B.jpg"]
              && (proof.map { max($0.pixelWidth, $0.pixelHeight) } ?? 0) <= Int(CollageProofPDF.longSide) + 1,
              "看版 PDF 的封面页：「封面 · 标题」、封面上的照片文件名、长边不超过 2000", proof.map { "\($0.pixelWidth)×\($0.pixelHeight) " + $0.names.joined(separator: " ") } ?? "nil")
        check(CollageBookCoverRender.proofPage(project: album(), hints: [:]) == nil, "没有封面：看版不加封面页", "")
    }

    /// 合成一块「看得见的」：底色上右上角一块渐变（贴着上边和右边）。镜像只出现在贴边的那一段，别处铺底色。
    static func checkMirror(check: (Bool, String, String) -> Void) {
        let w = 40, h = 30, e = 6
        let bg = CollageColor(hex: 0xF4F1EA)
        guard let ctx = CollageRender.makeContext(width: w, height: h) else { return }
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 右上角 20×12（左下原点里是 y 18…30）：每个像素颜色都不一样。
        for x in 20..<w {
            for y in 0..<12 {
                ctx.setFillColor(CGColor(srgbRed: Double(x) / 40, green: Double(y) / 12, blue: 0.3, alpha: 1))
                ctx.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))
            }
        }
        let spans = CollageBookCoverRender.EdgeSpans(top: [20..<w], right: [0..<12], topRight: true)
        guard let trim = ctx.makeImage(),
              let sheet = CollageBookCoverRender.mirrorEdges(trim, extent: e, background: bg, spans: spans),
              let full = CollageBookCoverRender.mirrorEdges(trim, extent: e, background: bg),
              let t = pixels(trim), let s = pixels(sheet), let f = pixels(full) else {
            check(false, "包边：合成图拼得出来", "")
            return
        }
        var center = true
        for x in 0..<w { for y in 0..<h where s(e + x, e + y) != t(x, y) { center = false } }
        var mirrorTop = true
        for x in 20..<w { for k in 0..<e where s(e + x, e - 1 - k) != t(x, k) { mirrorTop = false } }
        var mirrorRight = true
        for y in 0..<12 { for k in 0..<e where s(e + w + k, e + y) != t(w - 1 - k, y) { mirrorRight = false } }
        var solid = true
        let b = s(e, e + h - 1)
        for x in 0..<(e + 20) { for k in 0..<e where s(x, k) != b { solid = false } }
        for y in 0..<(h + 2 * e) { for k in 0..<e where s(k, y) != b { solid = false } }
        for x in 0..<(w + 2 * e) { for k in 0..<e where s(x, e + h + k) != b { solid = false } }
        var corner = true
        for k in 0..<e { for j in 0..<e where s(e + w + k, e - 1 - j) != t(w - 1 - k, j) { corner = false } }
        check(sheet.width == w + 2 * e && sheet.height == h + 2 * e && center && mirrorTop && mirrorRight && corner && solid,
              "包边、出血：照片贴边的那一段（和挨着的角）往外镜像（翻过板边接得上），别处铺底色", "")
        var whole = true
        for y in 0..<h { for k in 0..<e where f(e - 1 - k, e + y) != t(k, y) { whole = false } }
        check(whole, "不给哪几段：整圈镜像", "")
    }

    /// 哪几段镜像：照片格贴着成品边（零边距铺满）才镜像；默认边距一段都不镜像；模糊底整页镜像。
    static func checkEdgeSpans(check: (Bool, String, String) -> Void) {
        var p = album()
        let cover = CollageBookCover(front: .split(.row, 0.6, .leaf(.photo("A")), .leaf(.text(CollageTemplates.centeredTitle()))))
        let l = cover.layout(canvas: p.canvas, spreads: p.pages.count)
        let none = CollageBookCoverRender.frontEdgeSpans(cover: cover, project: p, layout: l, scale: 1)
        p.style.margin = 0
        let bleed = CollageBookCoverRender.frontEdgeSpans(cover: cover, project: p, layout: l, scale: 1)
        let x0 = l.pageW + l.spine
        let photoW = bleed.top.first.map { $0.count } ?? 0
        let gutter = CollageLayout.gutterPixels(canvas: CollageBookCover.frontCanvas(p.canvas), style: p.style)
        check(none == CollageBookCoverRender.EdgeSpans(), "默认边距：包边一整圈铺底色（纸纹也不影响）", "")
        check(bleed.top.count == 1 && bleed.top[0].lowerBound == x0 && bleed.bottom == bleed.top && bleed.right.isEmpty
              && !bleed.topRight && abs(photoW - Int(Double(l.pageW - gutter) * 0.6)) <= 2,
              "零边距：只有贴边的照片格那一段镜像（右边是文字格，不镜像）", "上边 \(bleed.top.map { "\($0)" })")
        p.style.backgroundMode = .blurPhoto
        let blur = CollageBookCoverRender.frontEdgeSpans(cover: cover, project: p, layout: l, scale: 1)
        check(blur.top == [x0..<(x0 + l.pageW)] && blur.right == [0..<l.pageH] && blur.topRight && blur.bottomRight
              && blur.left.isEmpty && !blur.topLeft,
              "模糊底：封面那一页上、下、右整段镜像，封底、书脊不镜像", "")
        // {no}：封面那块和第 2 个跨页的树一模一样，也印 01（封面不是哪个跨页）。
        var same = album()
        var noText = CollageTemplates.centeredTitle()
        noText.lines[0].text = "{no}"
        let tree = CollageNode.split(.column, 0.8, .leaf(.photo("A")), .leaf(.text(noText)))
        same.pages[1] = CollagePage(root: tree)
        same.bookCover = CollageBookCover(front: tree)
        var opts = CollageRender.Options(scale: 0.1)
        let report = CollageRender.RenderReport()
        opts.report = report
        _ = CollageBookCoverRender.render(project: same, hints: [:], options: opts)
        let printed = report.texts.flatMap(\.lines)
        let vars = CollageBookCoverRender.spineVariables(cover: same.bookCover!, project: same, photos: [:])
        check(printed.contains("01") && !printed.contains("02") && vars["no"] == "01",
              "封面的 {no} = 01（树和某个跨页一样也不印那个跨页的页码）", printed.joined(separator: " "))
    }

    // MARK: - 小工具

    /// 读像素（左上原点）：返回 (x, y) → RGBA 打包成一个整数。
    static func pixels(_ image: CGImage) -> ((Int, Int) -> UInt32)? {
        let w = image.width
        let h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CollageRender.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let copy = buf
        return { x, y in
            let i = (y * w + x) * 4
            return UInt32(copy[i]) << 24 | UInt32(copy[i + 1]) << 16 | UInt32(copy[i + 2]) << 8 | UInt32(copy[i + 3])
        }
    }

    static func luma(_ rgba: UInt32) -> Double {
        let r = Double((rgba >> 24) & 0xFF) / 255
        let g = Double((rgba >> 16) & 0xFF) / 255
        let b = Double((rgba >> 8) & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
