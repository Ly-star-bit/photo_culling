import Foundation
import CoreGraphics
import CoreText

/// 印样 / 底片条（CollagePage.contactSheet）：整页按片条画，切分树不画（同散落版）。规格照 R2：
/// - 135：片宽 34.975 mm；画面 36×24、帧距 38（= 8 个孔距 4.75）、帧间 2 mm 片基；单侧片边带 5.49 mm（片宽 15.7%）。
///   齿孔沿片长 1.981 × 横跨片宽 2.794（竖矩形）、圆角 0.51，外沿离片边 2.01（偏外侧，不在片边带正中）；
///   孔按整条片子连续排（不是每帧一圈），帧号 n / ▶nA、SAFETY FILM + ISO 印在片边到孔外沿那 2.01 mm 里。
/// - 120（6×4.5 / 6×6 / 6×7）：片宽 61.2，单侧片边 2.6，没有齿孔；片边号和帧不对齐。
/// - 颜色（接触印相）：片基、帧间缝印成黑，齿孔只比片基亮一点点（不是白的），片边字浅灰；印样整块黑场压在白相纸上。
/// - 竖拍转 90° 躺在条里（可选「竖片立起来」）；比例不符加黑边（没曝光的片基），不裁。
/// - 条与条之间一道缝，每条微转、错位（种子固定，不排成完美网格）；帧号每卷随机偏 0.25–0.45 个帧距，不居中。
/// - 记号：每场最好那张精选红圈、废片打叉（CollagePencil），全部帧画完之后单独一遍，圈能压到片边、邻帧。
/// 版式全在成品 1 倍坐标里定（mm × 每毫米像素），预览、导出、.marks.json 是同一组数；渲染只按缩放画。
/// 不印任何胶片品牌、片种代码，不画 DX 码（DESIGN.md §0.4）。
enum CollageContact {

    // MARK: - 胶片尺寸（mm，R2 §1、§4）

    struct Film {
        /// 片宽（横跨片条）。
        var width: Double
        /// 画面：沿片长 × 横跨片宽。
        var along: Double
        var across: Double
        /// 帧间片基。
        var gap: Double
        var perforated: Bool
        /// 印片边字的那条带：135 = 片边到齿孔外沿；120 = 画面到片边。
        var lane: Double
        /// 片边字的大写高度（135 ≤ 1.3 mm，放得进 2.01 mm 那条带）。
        var capHeight: Double

        /// 帧距（135 = 38 = 8 个孔距）。
        var pitch: Double { along + gap }
        /// 单侧片边带（画面到片边；135 = 5.49 = 片宽 15.7%）。
        var edge: Double { (width - across) / 2 }
        /// 画面的宽高比（沿片长 / 横跨片宽）：135、6×7 横，6×4.5 竖，6×6 方。
        var aspect: Double { along / across }
    }

    static func film(_ format: CollageFilmFormat) -> Film {
        switch format {
        case .f135:
            return Film(width: 34.975, along: 36, across: 24, gap: 2, perforated: true, lane: 2.01, capHeight: 1.1)
        // 120：片宽 61.2（ISO 732 实测），画面 56 横跨片宽；帧间距看相机，取帧宽的 5–7%。
        case .f645:
            return Film(width: 61.2, along: 41.5, across: 56, gap: 3, perforated: false, lane: 2.6, capHeight: 1.3)
        case .f66:
            return Film(width: 61.2, along: 56, across: 56, gap: 3.5, perforated: false, lane: 2.6, capHeight: 1.3)
        case .f67:
            return Film(width: 61.2, along: 70, across: 56, gap: 4, perforated: false, lane: 2.6, capHeight: 1.3)
        }
    }

    /// 135 齿孔（SMPTE ST 139 的 KS 孔）：沿片长、横跨片宽、圆角、外沿离片边、孔距。
    static let perfAlong = 1.981
    static let perfAcross = 2.794
    static let perfCorner = 0.51
    static let perfFromEdge = 2.01
    static let perfPitch = 4.75
    /// 帧左沿到第一个孔中心：8 个孔居中排在 38 mm 帧距里（帧中心 18 = 1.375 + 3.5 × 4.75）。
    static let perfStart = 1.375
    /// 120 的片边号间距（R2 §4：常见的 120 黑白片一卷印 1–19，约 42 mm 一个；和帧不对齐）。
    static let rollNumberPitch = 42.0

    // MARK: - 颜色（接触印相）

    /// 片基、帧间缝、片边带（R2 §3：#0E0E0E–#151413）。
    static let base = CollageColor(hex: 0x141312)
    /// 印样黑场：相纸上没被片子挡住、直接曝光的地方，比片基还黑一点（片条的边隐约看得见）。
    static let fieldColor = CollageColor(hex: 0x0A0A0A)
    /// 齿孔：只比片基亮一点（3% 满量程，DESIGN 3–8% 取下限），印样上「隐约可见」，绝不是白的（白孔是看底片、幻灯片的样子）。
    static let hole = base.mixed(with: .white, 0.03)
    /// 片边字：黑白片浅灰，彩色片偏暖白。
    static let edgeMono = CollageColor(hex: 0xCFCFCF)
    static let edgeColour = CollageColor(hex: 0xE3D8C4)
    /// 底片条的投影。
    static let shadowColor = CollageColor(r: 0, g: 0, b: 0)

    /// 这一页实际用的几种黑和片边字的颜色。加了网点（报纸风）的页是一种墨印出来的：照片最黑的地方就是墨色
    /// （CIFalseColor 0 → 墨），片基、黑场还用 #141312、#0A0A0A 的话照片就成了浮在一块更黑的底上的灰片子 ——
    /// 这时片基、黑场（黑边是露出来的片基，跟着走）都是墨的实地，齿孔往纸色偏 3%，片边字是露出来的纸色。
    /// 只调影调不出点（点距不到 3 像素）时照片也是墨、纸两色，一样按墨色画。
    struct Inks {
        var base: CollageColor
        var field: CollageColor
        var hole: CollageColor
        var edge: CollageColor
    }

    static func inks(screen: CollageScreening.Spec?, mono: Bool) -> Inks {
        guard let screen else {
            return Inks(base: base, field: fieldColor, hole: hole, edge: mono ? edgeMono : edgeColour)
        }
        let ink = screen.halftone.ink
        return Inks(base: ink, field: ink, hole: ink.mixed(with: screen.paper, 0.03), edge: screen.paper)
    }

    // MARK: - 版式

    /// 一帧在条里的位置（条内局部坐标：1 倍成品像素、左上原点，x 沿片长）。
    struct Slot {
        /// 卷内第几帧（0 起）。
        var index: Int
        /// 帧号（135 = 片边上挨着这一帧印的那个号；120 片边号不对帧，记卷内序号）。
        var label: String
        var photoID: String
        /// 画面那块（36×24、56×56…）。
        var rect: CGRect
    }

    struct Strip {
        var index: Int
        /// 条内局部（1 倍像素）→ 成品 1 倍坐标。
        var transform: CGAffineTransform
        var length: CGFloat
        var height: CGFloat
        /// 条起点在整卷上的位置（mm）：孔、片边字按整卷连续排，剪开的条接得上。
        var rollStart: Double
        var slots: [Slot]
        /// 这一条转了多少度（微转 + 整体倾斜；左上原点里正角 = 顺时针）。
        var angle: Double
    }

    struct Note {
        var text: String
        var font: CollageFont
        /// 字号、字块左沿和竖向中心（成品 1 倍）、转角（度）。
        var size: Double
        var origin: CGPoint
        var angle: Double
        /// 字块左右不出这两条线（页面留白以内）：字太长时先缩字号（放不下再截断），再往左挪（noteShape）。
        var minX: Double
        var maxX: Double
        /// 片条（黑场）左右到哪：字比这一块还宽（竖着的一条底片条）时字块居中在它下面，不从它的左沿起头
        /// 往右拖出去一大截。
        var blockMinX: Double
        var blockMaxX: Double
    }

    struct Layout {
        var film: Film
        /// 每毫米多少成品像素（印刷画布最多 1:1：接触印相不放大）。
        var unit: Double
        var perStrip: Int
        var stripCount: Int
        var strips: [Strip]
        /// 印样的黑场：局部矩形（1 倍像素）+ 局部 → 成品。底片条没有。
        var field: (rect: CGRect, transform: CGAffineTransform)?
        var note: Note?
        /// 帧号相对帧左沿偏多少个帧距（每卷随机 0.25–0.45）、齿孔相位（mm）、片边字相位（帧距的比例）。
        var numberOffset: Double
        var perfPhase: Double
        var edgePhase: Double
        /// 120 片边号从几开始。
        var rollNumberStart: Int
        /// 一页放不下的帧（超过 sheet.frameLimit 的：条数、每条帧数给定 = 那么多格，自动 = 一卷的长度）。
        var overflow: [String]
        /// 整页所有东西（片条、黑场）在成品上的外接框；一帧都没有（帧全从托盘拿掉了）= nil。
        var bounds: CGRect?
        /// 再加上圈最多能压出去的那一圈（markOvershoot）：排版保证它不出画布，手写注记躲着它。没有帧 = nil。
        var inkBounds: CGRect?
    }

    /// 排一页：帧 → 条（每条几帧、几条）→ 微转错位 → 整体倾斜 → 按页面留白缩放居中 → 手写注记的位置。
    /// rollNo = 页码（{no}）：种子、默认卷号用它。
    static func layout(_ sheet: CollageContactSheet, canvas: CollageCanvas, rollNo: String) -> Layout {
        let film = film(sheet.format)
        let all = sheet.frames
        // 一页最多一卷（自动排时）或给定的格数：再多的放不下，不往一卷里硬塞。
        let limit = sheet.frameLimit
        let grid = gridSize(sheet, count: min(all.count, limit), canvas: canvas, film: film, rollNo: rollNo)
        let capacity = min(grid.perStrip * grid.strips, limit)
        let frames = Array(all.prefix(capacity))
        let overflow = Array(all.dropFirst(capacity))
        var rng = SeededRandom(seed: rollSeed(sheet, rollNo: rollNo))
        let numberOffset: Double = 0.25 + 0.2 * unit(&rng)
        let perfPhase: Double = (unit(&rng) * 2 - 1) * 0.8
        let edgePhase: Double = 0.15 + 0.5 * unit(&rng)
        let rollNumberStart = 1 + Int(unit(&rng) * 3)
        let noteAngle: Double = (unit(&rng) * 2 - 1) * 1.2
        var jitter = jitterRandom(sheet, rollNo: rollNo)
        let arranged = arrange(sheet, film: film, perStrip: grid.perStrip, strips: grid.strips, count: frames.count,
                               rng: &jitter)
        let room = area(sheet, canvas: canvas)
        let fit = fitTransform(arranged, sheet: sheet, area: room, print: canvas.isPrint ? canvas.pixels(mm: 1) : nil)
        let u = fit.unit
        let toUnit = CGAffineTransform(scaleX: CGFloat(1 / u), y: CGFloat(1 / u))
        let pitchPx = CGFloat(film.pitch * u)
        let along = CGFloat(film.along * u)
        let across = CGFloat(film.across * u)
        let x0 = CGFloat(film.gap / 2 * u)
        let y0 = CGFloat(film.edge * u)
        var strips: [Strip] = []
        for i in 0..<grid.strips {
            let first = i * grid.perStrip
            guard first < frames.count else { break }
            let ids = frames[first..<min(frames.count, first + grid.perStrip)]
            var slots: [Slot] = []
            for (k, id) in ids.enumerated() {
                let index = first + k
                let x = x0 + CGFloat(k) * pitchPx
                slots.append(Slot(index: index, label: "\(index + 1)", photoID: id,
                                  rect: CGRect(x: x, y: y0, width: along, height: across)))
            }
            let local = arranged.stripTransforms[i]
            let transform = toUnit.concatenating(local).concatenating(fit.transform)
            let angleDeg: Double = arranged.angles[i] * 180 / .pi + sheet.tilt
            let length = CGFloat(Double(slots.count) * film.pitch * u)
            strips.append(Strip(index: i, transform: transform, length: length, height: CGFloat(film.width * u),
                                rollStart: Double(first) * film.pitch, slots: slots, angle: angleDeg))
        }
        var field: (rect: CGRect, transform: CGAffineTransform)?
        if let f = arranged.field {
            let rect = f.rect.applying(CGAffineTransform(scaleX: CGFloat(u), y: CGFloat(u)))
            field = (rect, toUnit.concatenating(f.transform).concatenating(fit.transform))
        }
        // 一帧都没有：什么都不画，外接框是空的（CGRect.null 的 minX 是无穷大，写不进 .marks.json）。
        let bounds: CGRect? = arranged.outline.isEmpty ? nil : bbox(arranged.outline.map { $0.applying(fit.transform) })
        let inkBounds: CGRect? = arranged.inkOutline.isEmpty ? nil
            : bbox(arranged.inkOutline.map { $0.applying(fit.transform) })
        let note = bounds.flatMap {
            notePlacement(sheet, canvas: canvas, area: room, bounds: $0, ink: inkBounds ?? $0, angle: noteAngle)
        }
        return Layout(film: film, unit: u, perStrip: grid.perStrip, stripCount: grid.strips, strips: strips, field: field,
                      note: note, numberOffset: numberOffset, perfPhase: perfPhase, edgePhase: edgePhase,
                      rollNumberStart: rollNumberStart, overflow: overflow, bounds: bounds, inkBounds: inkBounds)
    }

    /// 每卷的种子：第一帧 + 页码 + 规格（同一卷每次排出来一样；无头出图、.marks.json 能逐字比）。
    static func rollSeed(_ sheet: CollageContactSheet, rollNo: String) -> UInt64 {
        CollagePencil.seed("contact|\(sheet.frames.first ?? "")|\(rollNo)|\(sheet.format.rawValue)")
    }

    /// 条的微转、错位、黑场的歪：单独一串随机数（挑每条几帧时试排的和真排的是同一组）。
    private static func jitterRandom(_ sheet: CollageContactSheet, rollNo: String) -> SeededRandom {
        SeededRandom(seed: rollSeed(sheet, rollNo: rollNo) ^ 0x51ED)
    }

    private static func unit(_ rng: inout SeededRandom) -> Double { CollageItems.unit(&rng) }

    /// 每条几帧、几条。给定的照用；条数给了、每条没给 = 平分；都没给 = 在 1…n 帧一条里挑画面最大的
    /// （差不到 2% 取每条多的：一条长的比好几条短的像真的）。没有帧时按规格给个默认（135 一条 5 帧……）。
    private static func gridSize(_ sheet: CollageContactSheet, count n: Int, canvas: CollageCanvas, film: Film,
                                 rollNo: String) -> (perStrip: Int, strips: Int) {
        if sheet.perStrip > 0 {
            let strips = sheet.strips > 0 ? sheet.strips : max(1, (n + sheet.perStrip - 1) / sheet.perStrip)
            return (sheet.perStrip, strips)
        }
        guard n > 0 else {
            let fallback: Int
            switch sheet.format {
            case .f135: fallback = 5
            case .f645: fallback = 4
            case .f66, .f67: fallback = 3
            }
            return (fallback, max(1, sheet.strips))
        }
        if sheet.strips > 0 { return (max(1, (n + sheet.strips - 1) / sheet.strips), sheet.strips) }
        var candidates: [(perStrip: Int, strips: Int, unit: Double)] = []
        let room = area(sheet, canvas: canvas)
        let print: Double? = canvas.isPrint ? canvas.pixels(mm: 1) : nil
        for f in 1...min(n, 12) {
            let s = (n + f - 1) / f
            var jitter = jitterRandom(sheet, rollNo: rollNo)
            let arranged = arrange(sheet, film: film, perStrip: f, strips: s, count: n, rng: &jitter)
            candidates.append((f, s, fitTransform(arranged, sheet: sheet, area: room, print: print).unit))
        }
        let top = candidates.map(\.unit).max() ?? 1
        let pick = candidates.last { $0.unit >= top * 0.98 } ?? candidates[0]
        return (pick.perStrip, pick.strips)
    }

    /// 条在「组」里怎么摆（mm）：每条按整条长度绕自己的中心微转、横向错位；条与条之间留一道缝，转角不同的两条
    /// 往一头收拢时把缝加宽（两条不叠）。印样外面一圈黑场（自己也歪一点点）：条数、每条帧数都给定（模板、成套）时
    /// 按整个格子曝光 —— 压片玻璃下面整块都见光，空着的条也是黑的，片条从上往下排、短卷下面露出黑场（R2 §5）；
    /// 自动排（格子跟着帧数走）只围着有帧的那几条。
    /// reserved = 给定条数、每条帧数全排满时的所有角（定缩放：短卷的帧和整卷一样大）；
    /// outline = 真画出来的（定位置）：有帧的那几条、每条按它真有几帧的长度（最后一条没排满就短一截，
    /// 和 layout 里画的 Strip.length 一样）。印样的黑场照旧按整条长度围（没排满的那几格露出黑场，经典印样就是这样），
    /// 所以印样的位置跟着黑场走（格子给定 = 整个格子，短卷不再缩成页中间的两条）；底片条没有黑场，位置、外接框
    /// 就是真画出来的那几条。
    /// inkReserved / inkOutline：同上，每条再往外扩出圈能压出去的那一圈（markOvershoot，沿片长按各自的长度），外加黑场。
    private struct Arranged {
        var stripTransforms: [CGAffineTransform]
        var angles: [Double]
        var field: (rect: CGRect, transform: CGAffineTransform)?
        var outline: [CGPoint]
        var reserved: [CGPoint]
        var inkOutline: [CGPoint]
        var inkReserved: [CGPoint]
    }

    /// 圈最多压出片条多少（mm）：沿片长 = 头尾两帧的圈压出条头条尾多少，横跨片宽 = 压出片边多少。
    /// 圈的外框 = 帧 × circleScale（135 1.4、方画幅 1.28）；螺旋收笔大 3–8%、半径抖 ±5%、中心抖、整体歪 ±6°
    /// （CollagePencil.circleStroke），合起来按外框的 1.13 倍算，再加半个线宽。这一页不会有圈（自动圈关了、
    /// 也没有手动圈）= 0。叉、点、裁切线都在帧里面，不用算。
    static func markOvershoot(_ sheet: CollageContactSheet, film: Film) -> (along: Double, across: Double) {
        let circles = sheet.marks || sheet.markOverrides.values.contains(CollagePencilMark.circle.rawValue)
        guard circles else { return (0, 0) }
        let k: Double = circleScale(film) * 1.13 / 2
        let halfPen: Double = pencilWidthMM(film) / 2
        let halfAlong: Double = film.along * k + halfPen
        let halfAcross: Double = film.across * k + halfPen
        let along: Double = max(0, halfAlong - (film.gap / 2 + film.along / 2))
        let across: Double = max(0, halfAcross - film.width / 2)
        return (along, across)
    }

    /// count = 真有几帧（条数 = 帧数按每条帧数分，最后一条可以不满）。
    private static func arrange(_ sheet: CollageContactSheet, film: Film, perStrip: Int, strips: Int, count: Int,
                                rng: inout SeededRandom) -> Arranged {
        let w = film.width
        let full = Double(perStrip) * film.pitch
        let used = perStrip > 0 ? (count + perStrip - 1) / perStrip : 0
        // 印样的条挨得紧（默认片宽 2%：条与条之间一道细缝）；底片条之间留出投影的位置（默认 18%）。
        let gap = w * sheet.effectiveStripGap
        let over = markOvershoot(sheet, film: film)
        // 一条长 length（mm）的片条连圈能压到的那一圈（条内局部坐标）。
        func inkRect(_ length: Double) -> CGRect {
            CGRect(x: -over.along, y: -over.across, width: length + over.along * 2, height: w + over.across * 2)
        }
        var angles: [Double] = []
        var shifts: [Double] = []
        for _ in 0..<strips {
            let sign: Double = unit(&rng) < 0.5 ? -1 : 1
            let magnitude: Double = 0.3 + 0.5 * unit(&rng)
            let shiftSign: Double = unit(&rng) < 0.5 ? -1 : 1
            let shift: Double = 1 + unit(&rng)
            angles.append(sheet.jitter ? sign * magnitude * .pi / 180 : 0)
            shifts.append(sheet.jitter && strips > 1 ? shiftSign * shift : 0)
        }
        var transforms: [CGAffineTransform] = []
        var outline: [CGPoint] = []
        var reserved: [CGPoint] = []
        var inkOutline: [CGPoint] = []
        var inkReserved: [CGPoint] = []
        // 有帧的那几条按整条长度的角：印样的黑场围着它。nextEmpty = 有帧的后面那一条空条（格子给定时黑场多围它一条）。
        var usedFull: [CGPoint] = []
        var nextEmpty: [CGPoint] = []
        var y = w / 2
        for i in 0..<strips {
            if i > 0 {
                let converge: Double = full / 2 * abs(sin(angles[i - 1]) - sin(angles[i]))
                y += w + gap + converge
            }
            let toCenter = CGAffineTransform(translationX: CGFloat(-full / 2), y: CGFloat(-w / 2))
            let turn = CGAffineTransform(rotationAngle: CGFloat(angles[i]))
            let place = CGAffineTransform(translationX: CGFloat(full / 2 + shifts[i]), y: CGFloat(y))
            let t = toCenter.concatenating(turn).concatenating(place)
            transforms.append(t)
            let four = corners(CGRect(x: 0, y: 0, width: full, height: w)).map { $0.applying(t) }
            reserved += four
            inkReserved += corners(inkRect(full)).map { $0.applying(t) }
            if i < used {
                // 这一条真有几帧（最后一条可以不满）：条从左头起排，短的那截在右头空着。
                let frames = min(perStrip, count - i * perStrip)
                let length: Double = Double(frames) * film.pitch
                usedFull += four
                outline += corners(CGRect(x: 0, y: 0, width: length, height: w)).map { $0.applying(t) }
                inkOutline += corners(inkRect(length)).map { $0.applying(t) }
            } else if i == used {
                nextEmpty = four
            }
        }
        var field: (rect: CGRect, transform: CGAffineTransform)?
        if sheet.layout == .sheet, used > 0 {
            let angle: Double = sheet.jitter ? (unit(&rng) * 2 - 1) * 0.35 * .pi / 180 : 0
            let pad = CGFloat(w * 0.12)
            func around(_ points: [CGPoint]) -> (rect: CGRect, transform: CGAffineTransform) {
                let rect = bbox(points).insetBy(dx: -pad, dy: -pad)
                let t = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                    .concatenating(CGAffineTransform(rotationAngle: CGFloat(angle)))
                    .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
                return (rect, t)
            }
            let own = around(usedFull)
            let whole = around(reserved)
            // 条数、每条帧数给定（模板、成套）：黑场围着有帧的那几条再加一条空的（压片玻璃下多见光一条），再往下是
            // 白相纸；片条的位置照旧按整个格子定（贴顶，fitTransform）。以前整个格子都曝光：6 张的托盘套「印样 · 135
            // 整卷」A4 八成五是黑的，模板库的缩略图是一块黑板（审查）。整卷（条都有帧）= 整个格子，和以前一样。
            let exposed = sheet.capacity != nil ? around(usedFull + nextEmpty) : own
            field = exposed
            let exposedCorners = corners(exposed.rect).map { $0.applying(exposed.transform) }
            let wholeCorners = corners(whole.rect).map { $0.applying(whole.transform) }
            outline += exposedCorners
            reserved += wholeCorners
            inkOutline += exposedCorners
            inkReserved += wholeCorners
        }
        return Arranged(stripTransforms: transforms, angles: angles, field: field, outline: outline, reserved: reserved,
                        inkOutline: inkOutline, inkReserved: inkReserved)
    }

    /// 这一页能放东西的地方（成品 1 倍）。
    /// - page：单张 = 整张画布；相册跨页 = 右页（印样是单张的一页，不跨中缝），靠中缝那边至少让出中缝带；
    /// - safe：片条、黑场放在页面留白以内，有手写注记时下面再让出一行字（注记也写在留白以内：社交图的边上
    ///   常被界面挡住）；
    /// - ink：圈可以压进留白，但离画布边至少半个留白（最少短边 1%），也不压进注记那一行。
    private struct Area {
        var page: CGRect
        var safe: CGRect
        var ink: CGRect
        var pad: Double
    }

    private static func area(_ sheet: CollageContactSheet, canvas: CollageCanvas) -> Area {
        let w = Double(canvas.width)
        let h = Double(canvas.height)
        let short = canvas.shortSide
        let pad: Double = sheet.margin * short
        let fold = canvas.seams == .fold
        let page = fold ? CGRect(x: w / 2, y: 0, width: w / 2, height: h) : CGRect(x: 0, y: 0, width: w, height: h)
        let inner: Double = fold ? max(pad, canvas.foldBand) : pad
        let inset: Double = max(pad * 0.5, short * 0.01)
        let innerInset: Double = fold ? max(inset, canvas.foldBand) : inset
        let noteRoom: Double = sheet.note.isEmpty ? 0 : noteSize(canvas) * 1.9
        let safeW: Double = max(1, Double(page.width) - inner - pad)
        let safeH: Double = max(1, h - pad * 2 - noteRoom)
        let safe = CGRect(x: Double(page.minX) + inner, y: pad, width: safeW, height: safeH)
        let inkBottom: Double = noteRoom > 0 ? h - pad - noteRoom : h - inset
        let inkW: Double = max(1, Double(page.width) - innerInset - inset)
        let inkH: Double = max(1, inkBottom - inset)
        let ink = CGRect(x: Double(page.minX) + innerInset, y: inset, width: inkW, height: inkH)
        return Area(page: page, safe: safe, ink: ink, pad: pad)
    }

    /// 组（mm）→ 成品 1 倍：整体倾斜，缩到放得下、在 safe 里居中。印刷画布最多 1:1（接触印相不放大，print = 每毫米像素）。
    /// 缩放按排满的算（短卷的帧和整卷一样大），位置按真画出来的居中（一帧都没有、条数帧数给定时按排满的）；
    /// 片条、黑场要进 safe，圈能压到的那一圈（排满的、真画出来的都算）要进 ink。
    private static func fitTransform(_ a: Arranged, sheet: CollageContactSheet, area: Area,
                                     print: Double?) -> (unit: Double, transform: CGAffineTransform) {
        // 格子给定的印样（有黑场）：按整个格子定位（片条贴顶，短卷的黑场只围有帧的几条，下面留白相纸）；
        // 自动排、底片条（没有黑场）按真画出来的居中。
        let gridSheet = sheet.capacity != nil && sheet.layout == .sheet
        let place = a.outline.isEmpty || gridSheet ? a.reserved : a.outline
        let box = bbox(place)
        guard !box.isNull, box.width > 0, box.height > 0 else { return (1, .identity) }
        let tilt = CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(sheet.tilt * .pi / 180)))
        let turned = bbox(place.map { $0.applying(tilt) })
        let full = bbox(a.reserved.map { $0.applying(tilt) })
        let inkPlace = a.inkOutline.isEmpty ? a.inkReserved : a.inkOutline
        let ink = bbox(inkPlace.map { $0.applying(tilt) })
        let inkFull = bbox(a.inkReserved.map { $0.applying(tilt) })
        let safe = area.safe
        let anchor = CGPoint(x: safe.midX, y: safe.midY)
        let ux: Double = Double(safe.width) / Double(full.width)
        let uy: Double = Double(safe.height) / Double(full.height)
        // 排满时圈能压到的那一圈：以 anchor 为中心对称地放进 ink。
        let inkHalfW: Double = Double(min(anchor.x - area.ink.minX, area.ink.maxX - anchor.x))
        let inkHalfH: Double = Double(min(anchor.y - area.ink.minY, area.ink.maxY - anchor.y))
        let kx: Double = inkFull.width > 0 ? inkHalfW * 2 / Double(inkFull.width) : ux
        let ky: Double = inkFull.height > 0 ? inkHalfH * 2 / Double(inkFull.height) : uy
        // 真画出来的那几条：按它离中心的实际距离逐边算（短卷、斜放时不对称）。
        let center = CGPoint(x: turned.midX, y: turned.midY)
        let own = sideLimit(ink, center: center, anchor: anchor, area: area.ink)
        var u = max(0.01, min(ux, uy, kx, ky, own))
        if let print { u = min(u, print) }
        let t = tilt
            .concatenating(CGAffineTransform(translationX: -turned.midX, y: -turned.midY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(u), y: CGFloat(u)))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
        return (u, t)
    }

    /// box（组坐标）里的 center 对到画布上的 anchor、按 u 缩放之后，box 要落在 area 里：u 最大能取多少（四条边各算一次）。
    private static func sideLimit(_ box: CGRect, center: CGPoint, anchor: CGPoint, area: CGRect) -> Double {
        var u = Double.greatestFiniteMagnitude
        let left: Double = Double(center.x - box.minX)
        let right: Double = Double(box.maxX - center.x)
        let up: Double = Double(center.y - box.minY)
        let down: Double = Double(box.maxY - center.y)
        if left > 0 { u = min(u, Double(anchor.x - area.minX) / left) }
        if right > 0 { u = min(u, Double(area.maxX - anchor.x) / right) }
        if up > 0 { u = min(u, Double(anchor.y - area.minY) / up) }
        if down > 0 { u = min(u, Double(area.maxY - anchor.y) / down) }
        return u
    }

    /// 手写注记的字号：短边 2.6%（A4 上约 5.5 mm，油性笔写的卷号、日期就这么大）。
    static func noteSize(_ canvas: CollageCanvas) -> Double { canvas.shortSide * 0.026 }

    /// 手写注记放在片条下面的白边里（下面放不下就放上面，都放不下就不写），靠左（比片条还宽时居中，见 noteShape）、歪一点点。
    /// 字块（中心 ± 0.6 字高）上沿离片条、圈（ink = 圈最多压到哪儿）至少 0.3 字高，下沿离纸边不少于页面留白
    /// （中心到留白线 0.8 字高）：不写进社交图边上那条会被界面挡住的留白，也不压在圈上。
    private static func notePlacement(_ sheet: CollageContactSheet, canvas: CollageCanvas, area: Area, bounds: CGRect,
                                      ink: CGRect, angle: Double) -> Note? {
        guard !sheet.note.isEmpty, !bounds.isNull, !bounds.isEmpty else { return nil }
        let size = noteSize(canvas)
        let h = Double(canvas.height)
        let pad = area.pad
        let block = ink.isNull ? bounds : bounds.union(ink)
        let left: Double = Double(bounds.minX) + size * 0.5
        let lowest: Double = h - pad - size * 0.8
        let belowMin: Double = Double(block.maxY) + size * 0.9
        let belowPref: Double = max(Double(bounds.maxY) + size * 1.35, belowMin)
        let highest: Double = pad + size * 0.8
        let aboveMax: Double = Double(block.minY) - size * 0.9
        let abovePref: Double = min(Double(bounds.minY) - size * 1.35, aboveMax)
        let y: Double
        if belowMin <= lowest {
            y = min(belowPref, lowest)
        } else if aboveMax >= highest {
            y = max(abovePref, highest)
        } else {
            return nil
        }
        return Note(text: sheet.note, font: .bradley, size: size, origin: CGPoint(x: left, y: y), angle: angle,
                    minX: Double(area.safe.minX), maxX: Double(area.safe.maxX),
                    blockMinX: Double(bounds.minX), blockMaxX: Double(bounds.maxX))
    }

    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    // MARK: - 照片怎么进帧

    /// 要不要转 90°：画面横（135、6×7）放竖片、画面竖（6×4.5）放横片时转；方片、「竖片立起来」不转。
    static func rotates(_ photo: CollagePhotoRef, film: Film, upright: Bool) -> Bool {
        guard !upright else { return false }
        let a = photo.aspect
        let frameWide = film.aspect > 1.02
        let frameTall = film.aspect < 0.98
        return (frameWide && a < 0.98) || (frameTall && a > 1.02)
    }

    // MARK: - 记号

    /// 每帧的记号。自动：每场（take）最好的那张精选画圈 —— 手动定的优先，再看场内名次、分数；
    /// 没有场的照片按连拍组算，也没有连拍组的一张算一场；同一场（连拍组）的其他精选不圈 —— 「帧帧都圈」
    /// （R2 §10 第 8 条）靠这一条挡：圈的是不同的场，不再按帧数限密度。一页最多 maxCircles 个（R2 §7：6 个），
    /// 超了按（手动的、分数）挑；废片打叉（可关）。手动定的（markOverrides）最后盖上去，不受上限：none = 不画。
    /// 手动定过记号的帧不进自动圈的名单（不占上限的名额：手动改成点、叉、不画的那一场，名额让给别的场）；
    /// 手动圈了某一帧的场也不再自动圈（同一场只圈一张）。
    static func marks(_ sheet: CollageContactSheet, frames: [String],
                      photos: [String: CollagePhotoRef]) -> [String: CollagePencilMark] {
        var out: [String: CollagePencilMark] = [:]
        if sheet.marks {
            var byTake: [String: [CollagePhotoRef]] = [:]
            var order: [String] = []
            for id in frames {
                guard let p = photos[id], isPick(p) else { continue }
                let key = takeKey(p)
                if byTake[key] == nil { order.append(key) }
                byTake[key, default: []].append(p)
            }
            let circledByHand = Set(frames.compactMap { id -> String? in
                guard sheet.markOverrides[id] == CollagePencilMark.circle.rawValue, let p = photos[id] else { return nil }
                return takeKey(p)
            })
            let bests: [CollagePhotoRef] = order.filter { !circledByHand.contains($0) }.compactMap { key in
                byTake[key]?.min { a, b in pickRank(a).lexicographicallyPrecedes(pickRank(b)) }
            }.filter { sheet.markOverrides[$0.id] == nil }
            let ranked = bests.sorted { a, b in
                if a.isManual != b.isManual { return a.isManual }
                if a.score != b.score { return a.score > b.score }
                return a.id < b.id
            }
            let circled = sheet.maxCircles > 0 ? Array(ranked.prefix(sheet.maxCircles)) : ranked
            for p in circled { out[p.id] = .circle }
        }
        if sheet.crossRejects {
            for id in frames where photos[id]?.verdict == .reject { out[id] = .cross }
        }
        for (id, raw) in sheet.markOverrides where frames.contains(id) {
            if let mark = CollagePencilMark(rawValue: raw) { out[id] = mark } else if raw == "none" { out[id] = nil }
        }
        return out
    }

    /// 一场：有场按场，没有按连拍组，也没有就一张一场。
    static func takeKey(_ p: CollagePhotoRef) -> String {
        p.take.map { "t\($0)" } ?? p.burstGroup.map { "b\($0)" } ?? "p\(p.id)"
    }

    /// 算不算精选：有批量页判决按判决，外部文件看 isPick。
    static func isPick(_ p: CollagePhotoRef) -> Bool {
        if let v = p.verdict { return v == .pick }
        return p.isPick
    }

    /// 场内挑哪张精选圈：手动的 → 场内名次 → 分数 → id（越小越好）。
    private static func pickRank(_ p: CollagePhotoRef) -> [Double] {
        let manual: Double = p.isManual ? 0 : 1
        let rank = Double(p.takeRank ?? 99)
        return [manual, rank, -p.score]
    }

    // MARK: - 建一页 / 排卷

    /// 一页印样：照片按拍摄先后排成一卷（最多 frameLimit 帧：容量给定 = 那么多格，自动 = 一卷的长度；
    /// 后面的留给下一卷，调用方按 photos.count − frames.count 提示没上的几张）。
    /// choice = best（社交底片条）且照片比格子多时，不取前 N 张：每场挑一张最好的凑够 N 张（chooseBest），
    /// 再按拍摄先后排 —— 三帧的底片条从一整天里拿开头三张没有意义。
    /// 片边的 ISO 还是默认的 400 时，这一页的帧 EXIF 都是同一个 ISO 就印它（rollISO）。
    static func page(photos: [CollagePhotoRef], spec: CollageContactSheet) -> CollagePage {
        var sheet = spec
        let ordered = rollOrder(photos)
        let limit = sheet.frameLimit
        let chosen = sheet.choice == .best && ordered.count > limit
            ? rollOrder(chooseBest(ordered, count: limit, sheet: sheet))
            : Array(ordered.prefix(limit))
        sheet.frames = chosen.map(\.id)
        if sheet.iso == CollageContactSheet().iso, let iso = rollISO(chosen) { sheet.iso = iso }
        var page = CollagePage(root: .leaf(CollageCell()))
        page.contactSheet = sheet
        return page
    }

    /// 挑 count 帧（choice = best）：先每场（同 marks 的场：场 → 连拍组 → 一张一场）挑一张，场与场之间按
    /// （在这条片子上是正的、精选、手动的、分数）排，取前 count 场；场不够 count 个再从各场剩下的里按同样的顺序补。
    /// 「是正的」= 转进片条、片条再整体倾斜之后人是立着的（竖着放的底片条挑竖片，横着放的挑横片）：排在精选
    /// 前面 —— 真的片条上横片在竖条里就是躺着的，可是发到社交图上，躺着的人一眼看去像放错了；别的场有立着的
    /// 就用它（同一场里也是：立着的可用片先于躺着的精选），全是躺着的才上躺着的。圈照旧只圈精选。
    static func chooseBest(_ photos: [CollagePhotoRef], count: Int, sheet: CollageContactSheet) -> [CollagePhotoRef] {
        guard count > 0, photos.count > count else { return photos }
        let film = film(sheet.format)
        func rank(_ p: CollagePhotoRef) -> [Double] {
            let pick: Double = isPick(p) ? 0 : 1
            let upright: Double = standsUpright(p, film: film, sheet: sheet) ? 0 : 1
            let manual: Double = p.isManual ? 0 : 1
            return [upright, pick, manual, -p.score]
        }
        func better(_ a: CollagePhotoRef, _ b: CollagePhotoRef) -> Bool {
            let ra = rank(a)
            let rb = rank(b)
            if ra != rb { return ra.lexicographicallyPrecedes(rb) }
            return a.id < b.id
        }
        var groups: [String: [CollagePhotoRef]] = [:]
        for p in photos { groups[takeKey(p), default: []].append(p) }
        let sortedGroups = groups.values.map { $0.sorted(by: better) }
        let heads = sortedGroups.compactMap(\.first).sorted(by: better)
        var chosen = Array(heads.prefix(count))
        if chosen.count < count {
            let rest = sortedGroups.flatMap { $0.dropFirst() }.sorted(by: better)
            chosen += rest.prefix(count - chosen.count)
        }
        return chosen
    }

    /// 这张照片在片条上是不是正的：转 90° 躺进画幅的头朝右（drawFrame），片条整体再转 tilt 度（左上原点里正 = 顺时针）；
    /// 人的「上」落在页面上方 ±45° 以内算正。
    static func standsUpright(_ photo: CollagePhotoRef, film: Film, sheet: CollageContactSheet) -> Bool {
        let theta: Double = sheet.tilt * .pi / 180
        // 没转：照片的上 = 片条的 −y；转了 90°（头朝右）：照片的上 = 片条的 +x。转过 tilt 之后看 y 分量（朝上为负）。
        let upY: Double = rotates(photo, film: film, upright: sheet.uprightPortraits) ? sin(theta) : -cos(theta)
        return upY < -0.7071
    }

    // MARK: - 纸

    /// 常用的几张纸（检视器「印样」框里挑）：白相纸（RC 光面相纸的白，带一点点暖）、米色纸、暖黑（社交底片条）。
    static let papers: [(name: String, color: CollageColor)] = [
        ("白相纸", CollageColor(hex: 0xF6F5F1)), ("米色纸", CollageColor(hex: 0xECE4D4)), ("暖黑", CollageColor(hex: 0x252321)),
    ]

    /// 换排法时换上的纸：印样印在白相纸上（黑场压在白纸上才是印样）；底片条放在暖黑上（社交图、片条带投影）。
    static func defaultPaper(_ layout: CollageContactLayout) -> CollageColor {
        layout == .sheet ? papers[0].color : papers[2].color
    }

    /// 这张纸印印样行不行：偏深（亮度不到 0.75）的黑场压上去分不出来（米色 0.9、纸白 0.95 都行）。
    static func suitsSheet(_ paper: CollageColor) -> Bool { paper.luminance >= 0.75 }

    /// 卷内顺序：拍摄时间 → 小数秒（同一秒的连拍）→ 帧号（文件名末尾的数字）→ id。没有拍摄时间的排最后。
    static func rollOrder(_ photos: [CollagePhotoRef]) -> [CollagePhotoRef] {
        photos.sorted { a, b in
            switch (a.captureTime, b.captureTime) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            let sa = a.captureSubsec ?? 0
            let sb = b.captureSubsec ?? 0
            if sa != sb { return sa < sb }
            let fa = a.frameNo.flatMap { Int($0) } ?? Int.max
            let fb = b.frameNo.flatMap { Int($0) } ?? Int.max
            if fa != fb { return fa < fb }
            return a.id < b.id
        }
    }

    /// 按照片比例挑规格（R2 §4）：3:2 → 135，4:3 → 6×4.5，1:1 → 6×6，5:4 → 6×7（看多数照片的长短边比）。
    static func suggestedFormat(_ photos: [CollagePhotoRef]) -> CollageFilmFormat {
        guard !photos.isEmpty else { return .f135 }
        var votes: [CollageFilmFormat: Int] = [:]
        for p in photos {
            let r = max(p.aspect, 1 / max(0.01, p.aspect))
            let format: CollageFilmFormat
            if r < 1.12 { format = .f66 } else if r < 1.29 { format = .f67 } else if r < 1.42 { format = .f645 } else { format = .f135 }
            votes[format, default: 0] += 1
        }
        return votes.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key ?? .f135
    }

    // MARK: - 画

    /// 这一页画了什么（.marks.json 的 contactSheet、ops 的 contactdump）。坐标都是成品 1 倍、不含出血。
    struct Record {
        var format: String
        var layout: String
        var roll: String
        var unit: Double
        var perStrip: Int
        var strips: Int
        var tilt: Double
        /// 这次渲染印了片边字没有（缩得太小的预览不印，字只会糊成一片）。
        var edgePrinted: Bool
        var numberOffset: Double
        var frames: [FrameRecord]
        var stripRecords: [StripRecord]
        var note: String?
        var noteRect: CGRect?
        var overflow: [String]
        /// 一帧都没有 = nil（.marks.json 里是 null）。
        var bounds: CGRect?
        /// 圈最多能压到哪儿（排版留出来的那一圈，Layout.inkBounds）。
        var inkBounds: CGRect?
        /// 每帧照片画出来的那块，这次渲染的坐标（含出血、乘过缩放）：纸纹压照片（paperOverPhotos）压在这些上，
        /// 和格子照片的 Shown.clip 一样。不写进 .marks.json。
        var paperClips: [CGPath] = []
    }

    struct FrameRecord {
        var index: Int
        var label: String
        var photoID: String
        var strip: Int
        /// 画面那块转到成品上的四个角（从左上顺时针）和外接框。
        var corners: [CGPoint]
        var rect: CGRect
        var rotated: Bool
        /// 照片实际画出来的那块（比例不符时比画面小，四周是黑边）的外接框；照片读不了 = nil。
        var drawn: CGRect?
        var letterboxed: Bool
        var mark: String?
        /// 记号的笔迹实际画到哪儿（CollagePencil.inkBoxes 转到成品上的外接框）；没有记号 = nil。
        var markInk: CGRect?
        var verdict: String?
        var take: Int?
    }

    struct StripRecord {
        var index: Int
        var frames: Int
        var angle: Double
        var corners: [CGPoint]
        var holes: Int
    }

    /// 环境：和 render(page:) 里画格子用的同一组东西。
    struct Context {
        var photos: [String: CollagePhotoRef]
        var hints: [String: CollageCrop.Hints]
        var colorOps: [String: CollageLooks.Ops]
        var vars: [String: String]
        var options: CollageRender.Options
        var style: CollageStyle
        var canvas: CollageCanvas
        var scale: Double
        var bleed: Int
        var sharpenRadius: Double
        var screen: CollageScreening.Spec?
        /// 页面底色（手写注记写在白边上：笔色和纸色太近时换一支看得见的笔）。
        var background: CollageColor
    }

    @discardableResult
    static func draw(_ sheet: CollageContactSheet, ctx: CGContext, env: Context) -> Record {
        let rollNo = env.vars["no"] ?? "01"
        let lay = layout(sheet, canvas: env.canvas, rollNo: rollNo)
        let drawnIDs = lay.strips.flatMap { $0.slots.map(\.photoID) }
        let marks = marks(sheet, frames: drawnIDs, photos: env.photos)
        let mono = env.style.look.isMonochrome
            || (!drawnIDs.isEmpty && drawnIDs.allSatisfy { env.photos[$0]?.isMonochrome == true })
        let inks = inks(screen: env.screen, mono: mono)
        let u = lay.unit
        let scale = env.scale
        let capPx: Double = lay.film.capHeight * u * scale
        let edgePrinted = sheet.edgePrint && capPx >= 2.5
        // 圈叉和注记用哪支笔（一支笔；只有浅色笔写在浅色纸上时注记换墨色，见 pens）。
        let pen = pens(sheet.markColor, paper: env.background)

        func enter(_ t: CGAffineTransform) {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(env.bleed), y: CGFloat(env.bleed))
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.concatenate(t)
        }

        // 这次渲染的像素：局部 → 成品 1 倍 → 乘缩放 → 挪出血（和 enter() 同一串，软边的遮罩按它逐像素算）。
        let toPixels = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
            .concatenating(CGAffineTransform(translationX: CGFloat(env.bleed), y: CGFloat(env.bleed)))

        // 1. 印样的黑场：边上软一点（压片玻璃的边、光的漫射，约 0.5 mm：σ 0.25 mm），自己也歪一点点。
        //    软边按像素算遮罩（drawSoftEdge），不用 setShadow：同一页每次导出的像素会不一样。
        if let area = lay.field {
            let sigma: Double = u * 0.25
            drawSoftEdge(ctx, rect: area.rect, device: area.transform.concatenating(toPixels), sigma: sigma, peak: 0.9,
                         color: inks.field)
            enter(area.transform)
            ctx.setFillColor(inks.field.cgColor)
            ctx.fill(area.rect)
            ctx.restoreGState()
        }

        var frameRecords: [FrameRecord] = []
        var stripRecords: [StripRecord] = []
        var paperClips: [CGPath] = []
        // 每帧的照片先并发解好（导出时从原图解，一张张解一页要好几秒），下面按帧的先后画。
        let plans = lay.strips.flatMap { strip in
            strip.slots.map { framePlan(slot: $0, sheet: sheet, layout: lay, env: env) }
        }
        let decoded = decodeFrames(plans, env: env)
        var slotIndex = 0
        for strip in lay.strips {
            let body = CGRect(x: 0, y: 0, width: strip.length, height: strip.height)
            // 2. 片基：底片条（放在页面上的一条实物）带投影；印样里是印出来的，没有投影。
            //    投影往页面的下方挪 0.4% 短边（光从上面来：不跟着条转，所以挪在条的变换之后），σ 0.7% 短边
            //    （以前 setShadow 的模糊 1.4% 短边），最深 50% 黑。
            if sheet.layout == .strip {
                let short: Double = env.canvas.shortSide
                let drop: Double = short * 0.004
                let sigma: Double = short * 0.007
                let down = CGAffineTransform(translationX: 0, y: CGFloat(drop))
                drawSoftEdge(ctx, rect: body, device: strip.transform.concatenating(down).concatenating(toPixels),
                             sigma: sigma, peak: 0.5, color: shadowColor)
            }
            enter(strip.transform)
            ctx.setFillColor(inks.base.cgColor)
            ctx.fill(body)
            ctx.saveGState()
            ctx.clip(to: body)
            // 3. 齿孔（只有 135）：整卷连续，条与条剪开的地方接得上。
            let holes = lay.film.perforated ? drawPerforations(ctx, strip: strip, layout: lay, color: inks.hole) : 0
            // 4. 每一帧（照片在上面先并发解好了）。
            for slot in strip.slots {
                let drawn = drawFrame(ctx, slot: slot, strip: strip, sheet: sheet, layout: lay, env: env,
                                      mark: marks[slot.photoID], plan: plans[slotIndex], decoded: decoded[slotIndex])
                slotIndex += 1
                frameRecords.append(drawn.record)
                if let clip = drawn.clip { paperClips.append(clip) }
            }
            // 5. 片边字。
            if edgePrinted { drawEdgePrint(ctx, strip: strip, sheet: sheet, layout: lay, color: inks.edge) }
            ctx.restoreGState()
            ctx.restoreGState()
            stripRecords.append(StripRecord(index: strip.index, frames: strip.slots.count, angle: strip.angle,
                                            corners: corners(body).map { $0.applying(strip.transform) }, holes: holes))
        }

        // 6. 记号：全部帧画完之后单独一遍（圈压到片边、邻帧，不被后画的帧盖住）。种子 = 照片 id + 页号。
        for strip in lay.strips {
            for slot in strip.slots {
                guard let mark = marks[slot.photoID] else { continue }
                enter(strip.transform)
                let lw = pencilWidth(lay)
                let box = markRect(mark, frame: slot.rect, film: lay.film)
                let seed = CollagePencil.seed("\(slot.photoID)|\(rollNo)")
                CollagePencil.draw(mark, in: box, color: pen.marks, seed: seed, ctx: ctx, lineWidth: lw)
                ctx.restoreGState()
                let ink = CollagePencil.inkBoxes(mark, in: box, seed: seed, lineWidth: lw)
                    .flatMap { corners($0).map { $0.applying(strip.transform) } }
                if let k = frameRecords.firstIndex(where: { $0.index == slot.index }) {
                    frameRecords[k].markInk = ink.isEmpty ? nil : bbox(ink)
                }
            }
        }

        // 7. 白边上的手写注记（同一支笔）。
        var noteText: String?
        var noteRect: CGRect?
        if let note = lay.note {
            let text = filledNote(note.text, vars: noteVariables(sheet, ids: drawnIDs, vars: env.vars,
                                                                 photos: env.photos, rollNo: rollNo))
            if !text.isEmpty {
                noteText = text
                noteRect = drawNote(ctx, note: note, text: text, color: pen.note, env: env)
            }
        }

        return Record(format: sheet.format.rawValue, layout: sheet.layout.rawValue,
                      roll: noteVariables(sheet, ids: drawnIDs, vars: env.vars, photos: env.photos,
                                          rollNo: rollNo)["roll"] ?? rollNo,
                      unit: u, perStrip: lay.perStrip, strips: lay.stripCount, tilt: sheet.tilt,
                      edgePrinted: edgePrinted, numberOffset: lay.numberOffset, frames: frameRecords,
                      stripRecords: stripRecords, note: noteText, noteRect: noteRect, overflow: lay.overflow,
                      bounds: lay.bounds, inkBounds: lay.inkBounds, paperClips: paperClips)
    }

    /// 一块矩形四周的软边 / 投影（高斯模糊过的边）：按这次渲染的像素自己算一张灰度遮罩，透过它填不透明的颜色。
    /// 不用 setShadow，也不用一层层带透明度的填充：CG 的「整块同一个透明度」的填充（颜色带 alpha、setAlpha、
    /// 投影合成都算）在同一个进程里另一条线程同时用很多种不同透明度画东西时会画坏几个像素、每次坏的不一样
    /// （S4b 第 2 轮实测：另一条线程用 9 种以上透明度，这边连 0.5 的填充都会错；遮罩 + 不透明填充不受影响）。
    /// 编辑之后后台的预览和导出就是同时在画，所以同一页导出几次逐像素对不上。遮罩按公式逐像素算，每次一样。
    /// - rect：局部坐标里的矩形；device：局部 → 这次渲染的像素（含缩放、出血；当前坐标就是左上原点的像素，
    ///   不能再有别的变换）。是相似变换（转、平移、等比缩放），σ 跟着它缩放。
    /// - 离矩形边 d（局部单位，往外为正、里面为负）处的覆盖率 = peak × Φ(−d/σ)；算到外面 3σ（再往外不到 0.2%）。
    ///   里面也算（投影往下挪了之后条下面露出来一截）；黑场里面马上会填实，算了也看不见。
    private static func drawSoftEdge(_ ctx: CGContext, rect: CGRect, device: CGAffineTransform, sigma: Double,
                                     peak: Double, color: CollageColor) {
        guard sigma > 0, rect.width > 0, rect.height > 0 else { return }
        let reach = CGFloat(sigma * 3)
        let outer = bbox(corners(rect.insetBy(dx: -reach, dy: -reach)).map { $0.applying(device) })
        let x0 = max(0, Int(outer.minX.rounded(.down)))
        let y0 = max(0, Int(outer.minY.rounded(.down)))
        let x1 = min(ctx.width, Int(outer.maxX.rounded(.up)))
        let y1 = min(ctx.height, Int(outer.maxY.rounded(.up)))
        let w = x1 - x0
        let h = y1 - y0
        guard w > 0, h > 0 else { return }
        let inv = device.inverted()
        let root2: Double = 2.0.squareRoot()
        let far: Double = sigma * 3
        let minX = Double(rect.minX)
        let maxX = Double(rect.maxX)
        let minY = Double(rect.minY)
        let maxY = Double(rect.maxY)
        // 像素中心 (x + ½, y + ½) 在局部坐标里 = 起点 + x·ex + y·ey（逆变换是仿射的，逐行逐列加就行）。
        let origin = CGPoint(x: Double(x0) + 0.5, y: Double(y0) + 0.5).applying(inv)
        let ex = CGPoint(x: inv.a, y: inv.b)
        let ey = CGPoint(x: inv.c, y: inv.d)
        var bytes = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let rowX: Double = Double(origin.x) + Double(ey.x) * Double(row)
            let rowY: Double = Double(origin.y) + Double(ey.y) * Double(row)
            for col in 0..<w {
                let px: Double = rowX + Double(ex.x) * Double(col)
                let py: Double = rowY + Double(ex.y) * Double(col)
                let dx: Double = max(minX - px, px - maxX)
                let dy: Double = max(minY - py, py - maxY)
                let d: Double = dx > 0 || dy > 0 ? hypot(max(dx, 0), max(dy, 0)) : max(dx, dy)
                let c: Double
                if d >= far {
                    c = 0
                } else if d <= -far {
                    c = peak
                } else {
                    c = peak * 0.5 * erfc(d / (sigma * root2))
                }
                bytes[row * w + col] = UInt8(max(0, min(255, (c * 255).rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let mask = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        // 当前坐标是左上原点：和 CollageRender.drawImageTopLeft 一样局部翻回去，遮罩第一行落在 y0。
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(x0), y: CGFloat(y0 + h))
        ctx.scaleBy(x: 1, y: -1)
        let area = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clip(to: area, mask: mask)
        ctx.setFillColor(color.cgColor)
        ctx.fill(area)
        ctx.restoreGState()
    }

    /// 注记展开：按「 · 」分段，占位符全展开成空的那一段连同分隔点不写（照片没有拍摄时间：「ROLL 01 · 7209–7232」，
    /// 不写成「ROLL 01 ·  · 7209–7232」）；只有一帧（第一帧 = 最后一帧）时「{first}–{last}」只写一个帧号（不写 7232–7232）。
    /// 旧工程存下来的注记也这么展开：默认那句不用改。
    static func filledNote(_ text: String, vars: [String: String]) -> String {
        var t = text
        if let first = vars["first"], first == vars["last"] {
            t = t.replacingOccurrences(of: "{first}–{last}", with: "{first}")
        }
        let parts = t.components(separatedBy: " · ")
        let kept = parts.filter { part in
            let ns = part as NSString
            let found = CollageTypeset.placeholderRegex.matches(in: part, range: NSRange(location: 0, length: ns.length))
            guard !found.isEmpty else { return true }
            // 有默认字的 {key|默认} 不算空。
            return !found.allSatisfy { match in
                let value = vars[ns.substring(with: match.range(at: 1))] ?? ""
                let fallback = match.range(at: 2).location != NSNotFound && match.range(at: 2).length > 0
                return value.isEmpty && !fallback
            }
        }
        return CollageTypeset.fill(kept.count == parts.count ? t : kept.joined(separator: " · "), vars: vars)
    }

    /// 注记的占位符：页面的那一份 + {roll}（卷号，没填 = 页码）{first} {last}（第一、最后一帧的帧号）{frames}（几帧）。
    static func noteVariables(_ sheet: CollageContactSheet, ids: [String], vars: [String: String],
                              photos: [String: CollagePhotoRef], rollNo: String) -> [String: String] {
        var v = vars
        v["roll"] = sheet.roll.map { String(format: "%02d", $0) } ?? rollNo
        let numbers = ids.compactMap { photos[$0]?.frameNo }
        v["first"] = numbers.first ?? "1"
        v["last"] = numbers.last ?? "\(ids.count)"
        v["frames"] = "\(ids.count)"
        return v
    }

    /// 圈叉（marks）和注记（note）的笔色：一支油性笔。这支笔在这张纸上几乎看不见（对比度不到 noteMinContrast）时
    /// 换一支看得见的：墨色、白里和纸对比度高的那支 ——
    /// - 换成白（纸偏深：中灰、深色的取色底上的红笔、绿笔）：圈叉、注记一起换。白笔在黑片基、照片上也清楚，
    ///   圈画到片条外面的纸上也看得见；以前只换注记，同一页上注记白、圈红，像两支笔；
    /// - 换成墨色（浅色笔写在浅色纸上：白笔、黄笔写在白相纸的白边上）：只换注记。圈叉画在黑片基、照片上，
    ///   浅色的笔在那儿是清楚的，换成墨色就看不见了 —— 注记和圈不同色只剩这一种情况。
    /// 红笔在暖黑底上（#C8302A 对 #2B2926 约 2.7:1）够得上，照用红。
    static func pens(_ pen: CollageColor, paper: CollageColor) -> (marks: CollageColor, note: CollageColor) {
        guard contrast(pen, paper) < noteMinContrast else { return (pen, pen) }
        let white = CollagePencilMark.white
        if contrast(white, paper) > contrast(.ink, paper) { return (white, white) }
        return (pen, .ink)
    }

    /// 这支笔在这张纸上是不是「一支笔」：圈叉、注记都照用它（pens 没换色）。
    static func onePen(_ pen: CollageColor, paper: CollageColor) -> Bool {
        let p = pens(pen, paper: paper)
        return p.marks == pen && p.note == pen
    }

    /// 换了纸（换排法、按卷出印样）之后笔还配不配：这一页自己的纸上不是一支笔（白笔、黄笔换到白相纸上，注记
    /// 得换墨色、圈还是白的）就换回红笔 —— 红笔在白相纸、米色纸、暖黑上都清楚（DESIGN「每场最好那张红笔圈」）。
    /// 没设纸（跟着工程底色）不动：那是用户自己挑的底，pens 在渲染时照样会换。
    static func fitPen(_ sheet: inout CollageContactSheet) {
        guard let paper = sheet.paper, !onePen(sheet.markColor, paper: paper) else { return }
        sheet.markColor = CollagePencilMark.red
    }

    /// 换排法：纸换成那种排法的纸（defaultPaper），笔跟着配新纸（fitPen）。检视器「排法」、ops 的 contact:…;sheet|strip、
    /// contactset:layout= 都走这里（同一步另给了纸 / 笔的，调用方自己按给的）。
    static func switchLayout(_ sheet: inout CollageContactSheet, to layout: CollageContactLayout) {
        guard sheet.layout != layout else { return }
        sheet.layout = layout
        sheet.paper = defaultPaper(layout)
        fitPen(&sheet)
    }

    /// 片边的 ISO：这几帧 EXIF 都是同一个 ISO 就印它（数码机身的感光度当片速，和照片对得上）；有一帧读不到、
    /// 有两个不同的值 = nil（照旧印默认的 400）。EXIF 按路径缓存（CollageTypeset.exifValues）。
    static func rollISO(_ photos: [CollagePhotoRef]) -> String? {
        var seen: String?
        for p in photos {
            guard let iso = CollageTypeset.exifValues(p.path)["iso"], !iso.isEmpty, Int(iso) != nil else { return nil }
            if let s = seen, s != iso { return nil }
            seen = iso
        }
        return seen
    }

    /// 笔色和纸色至少这么大的对比度才照用（白笔 / 白相纸约 1.1，黄笔 / 白相纸约 1.5–1.7，橙笔 / 白相纸约 2.7–3）。
    static let noteMinContrast = 2.0

    /// 两个颜色的对比度（WCAG：相对亮度 (L亮 + 0.05) / (L暗 + 0.05)，1…21）。
    static func contrast(_ a: CollageColor, _ b: CollageColor) -> Double {
        func relative(_ c: CollageColor) -> Double {
            let r: Double = CollageLooks.linear(c.r)
            let g: Double = CollageLooks.linear(c.g)
            let b: Double = CollageLooks.linear(c.b)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let la = relative(a)
        let lb = relative(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 油性笔线宽：帧高（横跨片宽那边）的 5%，最粗 1.6 mm（笔就这么粗，120 的大帧不跟着变粗）。
    private static func pencilWidth(_ lay: Layout) -> CGFloat {
        CGFloat(pencilWidthMM(lay.film) * lay.unit)
    }

    private static func pencilWidthMM(_ film: Film) -> Double {
        let byFrame: Double = film.across * 0.05
        return min(byFrame, 1.6)
    }

    /// 圈的外框是帧的多少倍：135、6×4.5、6×7 = 1.4（R2 §7：半轴 0.70，外接 36×24 的帧要 0.71，压到片边、邻帧）；
    /// 方画幅（6×6）= 1.28（半轴 0.64，R2 的下沿）：方帧四面一样长，1.4 倍的圈四面都压进邻帧、挨着的两个圈搭在
    /// 一起；0.64 的圈贴着自己这一帧，只露出四个角。
    static func circleScale(_ film: Film) -> Double {
        abs(film.aspect - 1) < 0.02 ? 1.28 : CollagePencilMark.circle.frameScale
    }

    /// 记号的外框：圈 = 帧 × circleScale（压到片边、邻帧），叉 = 那一帧，裁切线 = 帧里面，点 = 帧右上角一小团。
    private static func markRect(_ mark: CollagePencilMark, frame: CGRect, film: Film) -> CGRect {
        let k = CGFloat(mark == .circle ? circleScale(film) : mark.frameScale)
        let w = frame.width * k
        let h = frame.height * k
        if mark == .dot {
            let side = min(frame.width, frame.height) * k
            return CGRect(x: frame.maxX - side * 1.5, y: frame.minY + side * 0.5, width: side, height: side)
        }
        return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
    }

    /// 齿孔：每帧 8 个，竖矩形，偏外侧；位置按整卷算（rollStart），返回这一条画了几个（剪开的地方算半个也算）。
    private static func drawPerforations(_ ctx: CGContext, strip: Strip, layout lay: Layout, color: CollageColor) -> Int {
        let u = lay.unit
        let film = lay.film
        let w = CGFloat(perfAlong * u)
        let h = CGFloat(perfAcross * u)
        let r = CGFloat(perfCorner * u)
        let top = CGFloat(perfFromEdge * u)
        let bottom = CGFloat((film.width - perfFromEdge - perfAcross) * u)
        // 第一个孔中心在整卷上的位置（mm）；条起点在整卷上 rollStart 处。
        let first: Double = film.gap / 2 + perfStart + lay.perfPhase
        let startM = Int(((strip.rollStart - first - perfAlong) / perfPitch).rounded(.down))
        let length = Double(strip.length) / u
        var count = 0
        ctx.setFillColor(color.cgColor)
        var m = startM
        while true {
            let center: Double = first + Double(m) * perfPitch - strip.rollStart
            if center - perfAlong > length { break }
            m += 1
            guard center + perfAlong / 2 > 0 else { continue }
            let x = CGFloat(center * u) - w / 2
            for y in [top, bottom] {
                ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r,
                                   transform: nil))
            }
            count += 1
        }
        ctx.fillPath()
        return count
    }

    /// 一帧里那张照片怎么放：取景、画在帧里哪块、解多大（drawFrame 画；draw 先按它把每帧的照片并发解好）。
    private struct FramePlan {
        var photo: CollagePhotoRef
        var rotated: Bool
        var window: CollageCrop.Window
        var target: CGRect
        /// 照片自己的宽高（转 90° 时和画面那块互换）、解出来的像素。
        var pw: CGFloat
        var ph: CGFloat
        var tw: Int
        var th: Int
        var letterboxed: Bool
        var screen: CollageScreening.Spec?
    }

    /// 解好的一帧，连同解码时出的问题（原图读不了退回预览 / 连预览都没有）：画的时候按帧的先后并进这一页的 report。
    private struct DecodedFrame {
        var tile: CGImage?
        var lowRes: [String] = []
        var missing: [String] = []
    }

    private static func framePlan(slot: Slot, sheet: CollageContactSheet, layout lay: Layout, env: Context) -> FramePlan? {
        guard let photo = env.photos[slot.photoID] else { return nil }
        let frame = slot.rect
        let rotated = rotates(photo, film: lay.film, upright: sheet.uprightPortraits)
        let photoAspect: Double = rotated ? 1 / photo.aspect : photo.aspect
        var window = CollageCrop.Window.whole
        let target: CGRect
        var letterboxed = false
        if sheet.fillFrames {
            target = frame
            let cellAspect: Double = rotated ? 1 / lay.film.aspect : lay.film.aspect
            window = CollageCrop.window(for: photo, cellAspect: cellAspect, framing: .auto, override: nil,
                                        hints: env.hints[photo.id])
        } else {
            target = CollageCrop.aspectFit(photoAspect, in: frame)
            letterboxed = abs(Double(target.width - frame.width)) > 0.5 || abs(Double(target.height - frame.height)) > 0.5
        }
        let pw = rotated ? target.height : target.width
        let ph = rotated ? target.width : target.height
        let tw = max(1, Int((Double(pw) * env.scale).rounded()))
        let th = max(1, Int((Double(ph) * env.scale).rounded()))
        let screen = env.screen.map { frameScreen($0, frame: frame, scale: env.scale) }
        return FramePlan(photo: photo, rotated: rotated, window: window, target: target, pw: pw, ph: ph, tw: tw, th: th,
                         letterboxed: letterboxed, screen: screen)
    }

    private static func decodeFrame(_ plan: FramePlan, env: Context) -> DecodedFrame {
        let local = env.options.report != nil ? CollageRender.RenderReport() : nil
        let tile = CollageRender.cellImage(photo: plan.photo, window: plan.window, width: plan.tw, height: plan.th,
                                           sharpen: env.style.sharpen, radius: env.sharpenRadius,
                                           export: env.options.export, report: local,
                                           color: env.colorOps[plan.photo.id], screen: plan.screen)
        return DecodedFrame(tile: tile, lowRes: local?.lowRes ?? [], missing: local?.missing ?? [])
    }

    /// 每帧的照片并发解好（最多 frameDecodeWidth 个同时）。导出时每帧都从原图解（40MP 的 JPEG 一张约 0.1 秒）：
    /// 一页 21–35 帧一张接一张解要 2–4 秒（按卷出印样一场几十页）。只是先解好，画还是按帧的先后一帧帧画：
    /// 每帧的像素和一张张解的一样。
    private static func decodeFrames(_ plans: [FramePlan?], env: Context) -> [DecodedFrame?] {
        var out = [DecodedFrame?](repeating: nil, count: plans.count)
        let jobs = plans.indices.filter { plans[$0] != nil }
        guard !jobs.isEmpty else { return out }
        let lock = NSLock()
        let width = min(frameDecodeWidth, jobs.count)
        DispatchQueue.concurrentPerform(iterations: width) { worker in
            var k = worker
            while k < jobs.count {
                let i = jobs[k]
                if let plan = plans[i] {
                    let decoded = decodeFrame(plan, env: env)
                    lock.lock()
                    out[i] = decoded
                    lock.unlock()
                }
                k += width
            }
        }
        return out
    }

    /// 同时解几帧：原图解码按需要的长边缩着解（一帧几百像素），六个同时内存有数，再多也快不了多少。
    static let frameDecodeWidth = 6

    /// 一帧：底下就是片基（黑边 = 没曝光的片基）；照片按比例放进画面（不裁），竖片转 90°（头朝右：右手在上竖拍）。
    /// clip = 照片画出来的那块换到这次渲染的坐标（纸纹压照片用）；没画出来 = nil。plan / decoded：draw 先算好、
    /// 并发解好的（decodeFrames）。
    private static func drawFrame(_ ctx: CGContext, slot: Slot, strip: Strip, sheet: CollageContactSheet,
                                  layout lay: Layout, env: Context, mark: CollagePencilMark?,
                                  plan: FramePlan?, decoded: DecodedFrame?) -> (record: FrameRecord, clip: CGPath?) {
        let frame = slot.rect
        let photo = env.photos[slot.photoID]
        let rotated = plan?.rotated ?? false
        var drawnRect: CGRect?
        var clip: CGPath?
        let letterboxed = plan?.letterboxed ?? false
        if let plan {
            let target = plan.target
            let pw = plan.pw
            let ph = plan.ph
            let screen = plan.screen
            if let report = env.options.report, let decoded {
                report.lowRes += decoded.lowRes
                report.missing += decoded.missing
            }
            if let tile = decoded?.tile {
                ctx.saveGState()
                ctx.clip(to: frame)
                if rotated {
                    ctx.translateBy(x: target.midX, y: target.midY)
                    ctx.rotate(by: .pi / 2)
                    CollageRender.drawImageTopLeft(ctx, tile, CGRect(x: -pw / 2, y: -ph / 2, width: pw, height: ph))
                } else {
                    CollageRender.drawImageTopLeft(ctx, tile, target)
                }
                ctx.restoreGState()
                drawnRect = bbox(corners(target).map { $0.applying(strip.transform) })
                // 和 enter() 同一串变换：条内局部 → 成品 1 倍 → 乘缩放 → 挪出血。target 本来就在画面里面。
                var device = strip.transform
                    .concatenating(CGAffineTransform(scaleX: CGFloat(env.scale), y: CGFloat(env.scale)))
                    .concatenating(CGAffineTransform(translationX: CGFloat(env.bleed), y: CGFloat(env.bleed)))
                clip = CGPath(rect: target, transform: &device)
                if let report = env.options.report, let screen {
                    report.halftone.append(CollageRender.halftoneRecord(screen, owner: "f\(slot.index)", photoID: plan.photo.id))
                }
            }
        }
        let pageCorners = corners(frame).map { $0.applying(strip.transform) }
        let verdict = photo?.verdict?.rawValue ?? (photo?.isPick == true ? "pick" : nil)
        let record = FrameRecord(index: slot.index, label: slot.label, photoID: slot.photoID, strip: strip.index,
                                 corners: pageCorners, rect: bbox(pageCorners), rotated: rotated, drawn: drawnRect,
                                 letterboxed: letterboxed, mark: mark?.rawValue, markInk: nil, verdict: verdict,
                                 take: photo?.take)
        return (record, clip)
    }

    /// 一帧至少这么多个网点（沿短边）：点距按画布短边算（0.4%），A4 印样上一帧只有 27 个点，照片糊成几块；
    /// 一帧 60 个点约等于把这张印样按 70 线左右印在报纸上。收到 3 像素以下照常只调影调（CollageScreening.minPitch）。
    static let dotsAcrossFrame = 60.0

    /// 这一帧的加网：点距取页面的和「帧短边 / 60」里小的那个。
    private static func frameScreen(_ spec: CollageScreening.Spec, frame: CGRect, scale: Double) -> CollageScreening.Spec {
        var s = spec
        let short: Double = Double(min(frame.width, frame.height)) * scale
        s.pitchPx = min(spec.pitchPx, short / dotsAcrossFrame)
        return s
    }

    static func bbox(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// 片边字。135：下边（片边到孔外沿）印帧号 n、▶nA，帧号整体相对帧左沿偏 numberOffset 个帧距（每卷随机，
    /// 不居中）；上边每两帧印一次「SAFETY FILM  400」。120：上边印片边号（约 42 mm 一个，和帧不对齐），
    /// 下边印 SAFETY FILM + ISO。位置都按整卷算，剪开的条接得上；剪口压住的字照样只剩半截。
    private static func drawEdgePrint(_ ctx: CGContext, strip: Strip, sheet: CollageContactSheet, layout lay: Layout,
                                      color: CollageColor) {
        let u = lay.unit
        let film = lay.film
        let font = edgeFont(capHeight: film.capHeight * u)
        let cap: Double = film.capHeight * u
        let topBaseline = CGFloat((film.lane / 2) * u + cap / 2)
        let bottomBaseline = CGFloat((film.width - film.lane / 2) * u + cap / 2)
        let length = Double(strip.length) / u
        let label = [sheet.edgeText, sheet.iso].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "  ")
        // 片名那一边：每两帧一次。
        let nameLane = film.perforated ? topBaseline : bottomBaseline
        if !label.isEmpty {
            let every = film.pitch * 2
            var j = Int((strip.rollStart / every).rounded(.down)) - 1
            while true {
                let at: Double = lay.edgePhase * film.pitch + Double(j) * every - strip.rollStart
                if at > length { break }
                j += 1
                guard at > -every else { continue }
                drawText(label, font: font, color: color, x: CGFloat(at * u), baseline: nameLane, ctx: ctx)
            }
        }
        if film.perforated {
            // 帧号：n 和 ▶nA，半个帧距一个。
            for slot in strip.slots {
                let start = Double(slot.rect.minX) / u
                let at: Double = start + lay.numberOffset * film.pitch
                let n = slot.index + 1
                drawText("\(n)", font: font, color: color, x: CGFloat(at * u), baseline: bottomBaseline, ctx: ctx)
                let half: Double = at + film.pitch / 2
                let arrowW = CGFloat(cap * 0.78)
                let arrowX = CGFloat(half * u)
                drawArrow(ctx, x: arrowX, baseline: bottomBaseline, cap: CGFloat(cap), color: color)
                drawText("\(n)A", font: font, color: color, x: arrowX + arrowW + CGFloat(cap * 0.3),
                         baseline: bottomBaseline, ctx: ctx)
            }
        } else {
            // 120：片边号按整卷等距，和帧不对齐。
            var j = Int((strip.rollStart / rollNumberPitch).rounded(.down)) - 1
            while true {
                let at: Double = lay.edgePhase * rollNumberPitch + Double(j) * rollNumberPitch - strip.rollStart
                if at > length { break }
                defer { j += 1 }
                guard at > -rollNumberPitch, j >= 0 else { continue }
                drawText("\(lay.rollNumberStart + j)", font: font, color: color, x: CGFloat(at * u),
                         baseline: topBaseline, ctx: ctx)
            }
        }
    }

    /// 片边字体：窄体无衬线粗体，按大写高度定字号（不同字体的大写高度比例不一样）。
    private static func edgeFont(capHeight: Double) -> CTFont {
        let probe = CollageTypeset.font(.helveticaCondensed, .bold, italic: false, size: 100)
        let ratio: Double = max(0.5, Double(CTFontGetCapHeight(probe)) / 100)
        let size = CGFloat(capHeight / ratio)
        return CollageTypeset.font(.helveticaCondensed, .bold, italic: false, size: size)
    }

    /// 在当前坐标（左上原点）里画一行字：x = 字的左沿，baseline = 基线。CTLineDraw 要 y 朝上，局部翻回去。
    private static func drawText(_ s: String, font: CTFont, color: CollageColor, x: CGFloat, baseline: CGFloat,
                                 ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// ▶：实心小三角，高 = 大写高度的 0.8，底边落在基线上方一点（和字一样高的那一截居中）。
    private static func drawArrow(_ ctx: CGContext, x: CGFloat, baseline: CGFloat, cap: CGFloat, color: CollageColor) {
        let h = cap * 0.8
        let w = cap * 0.78
        let top = baseline - cap / 2 - h / 2
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.move(to: CGPoint(x: x, y: top))
        ctx.addLine(to: CGPoint(x: x + w, y: top + h / 2))
        ctx.addLine(to: CGPoint(x: x, y: top + h))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// 注记最小缩到几倍字号：再小就不像顺手写在白边上的卷号了（字太长时到这一档还放不下就截断）。
    static let noteMinScale = 0.6

    /// 注记排出来的样子（成品 1 倍）：这一行字、字块左沿、竖向中心、基线、绕左沿中点歪的变换、转过之后的外接框。
    /// 画（drawNote）和整页水印要躲的框（obstacles）都用它，水印躲的就是画出来的那一块。
    private struct NoteShape {
        var line: CTLine
        var x: CGFloat
        var mid: CGFloat
        var baseline: CGFloat
        var turn: CGAffineTransform
        var box: CGRect
    }

    /// Bradley 手写（有汉字就用手写楷），同一支油性笔的颜色。字比左右两条线（页面留白以内）之间还宽：
    /// 先缩字号放进去（最小 noteMinScale 倍），到最小还放不下就在右头截断补「…」；再往左挪，不出左边那条线。
    /// 只缩不换行：字只会变矮，area 给注记让出的那一行（1.9 字高）照样够，注记的竖向中心不动。
    private static func noteShape(_ note: Note, text: String, color: CollageColor) -> NoteShape {
        let cjk = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        let family: CollageFont = cjk ? .hanzipen : note.font
        func attributes(_ size: Double) -> [NSAttributedString.Key: Any] {
            [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CollageTypeset.font(family, .regular, italic: false, size: CGFloat(size)),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor(alpha: 0.92),
            ]
        }
        func makeLine(_ size: Double) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes(size)))
        }
        let room: Double = max(1, note.maxX - note.minX)
        var line = makeLine(note.size)
        let natural: Double = CTLineGetTypographicBounds(line, nil, nil, nil)
        if natural > room {
            // 字宽和字号成正比：按比例缩，留 0.5% 的余量（字形取整），不小于最小那一档。
            let fit: Double = note.size * room / natural * 0.995
            let size: Double = max(note.size * noteMinScale, fit)
            line = makeLine(size)
            let shrunk: Double = CTLineGetTypographicBounds(line, nil, nil, nil)
            if shrunk > room {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes(size)))
                if let cut = CTLineCreateTruncatedLine(line, room, .end, token) { line = cut }
            }
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        // 字比片条那一块还宽：居中在它下面；不然从片条左沿（再进半个字）起头。放到右边会出页面留白：往左挪（不出左边那条线）。
        let block = CGFloat(note.blockMaxX - note.blockMinX)
        let centered = CGFloat(note.blockMinX + note.blockMaxX) / 2 - width / 2
        let start = width > block ? centered : note.origin.x
        let rightmost = CGFloat(note.maxX) - width
        let x = max(CGFloat(note.minX), min(start, rightmost))
        let mid = note.origin.y
        let baseline = mid + (ascent - descent) / 2
        let turn = CGAffineTransform(translationX: -x, y: -mid)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(note.angle * .pi / 180)))
            .concatenating(CGAffineTransform(translationX: x, y: mid))
        let box = CGRect(x: x, y: baseline - ascent, width: width, height: ascent + descent)
        return NoteShape(line: line, x: x, mid: mid, baseline: baseline, turn: turn,
                         box: bbox(corners(box).map { $0.applying(turn) }))
    }

    /// 手写注记：绕左沿中点歪一点（排法见 noteShape）。返回成品上的外接框。
    private static func drawNote(_ ctx: CGContext, note: Note, text: String, color: CollageColor, env: Context) -> CGRect {
        let shape = noteShape(note, text: text, color: color)
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(env.bleed), y: CGFloat(env.bleed))
        ctx.scaleBy(x: CGFloat(env.scale), y: CGFloat(env.scale))
        ctx.concatenate(shape.turn)
        ctx.translateBy(x: shape.x, y: shape.baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(shape.line, ctx)
        ctx.restoreGState()
        return shape.box
    }

    // MARK: - 整页水印要躲的

    /// 印样页的「版心」（成品 1 倍）：
    /// - bounds：片条、黑场真画到哪儿的外接框（Layout.bounds，同 .marks.json 的 contactSheet.bounds）。整页水印的
    ///   留白带按它算（CollageWatermarks.Painter：带 = 安全区里片条外面那圈空纸），不按工程的外边距 —— 印样有自己的
    ///   留白，工程外边距比它大时按外边距算的带会压在片条、黑场上。一帧都没有 = nil（照外边距）。
    /// - quads：每一条片条、黑场转过之后的四个角：整页水印靠边的那样放不进留白带、照旧排时躲开它们（不压在片子上）。
    ///   按四边形算，不按外接框：斜放的片条外接框把条旁边空着的纸也圈进去了。
    static func content(_ sheet: CollageContactSheet, canvas: CollageCanvas,
                        vars: [String: String]) -> (bounds: CGRect?, quads: [[CGPoint]]) {
        let lay = layout(sheet, canvas: canvas, rollNo: vars["no"] ?? "01")
        var quads = lay.strips.map { strip in
            corners(CGRect(x: 0, y: 0, width: strip.length, height: strip.height)).map { $0.applying(strip.transform) }
        }
        if let field = lay.field { quads.append(corners(field.rect).map { $0.applying(field.transform) }) }
        return (lay.bounds, quads)
    }

    /// 印样页上整页水印要躲的（成品 1 倍）：手写注记（text，同文字格）、圈叉的笔迹（ink，同油性笔贴纸：一小段一个框，
    /// 转过的取外接框）。片条、黑场不在这里：留白带按它们外面那圈空纸算，照旧排时躲它们的四边形（content）。
    /// 和 draw 同一份版式、同一组记号、同一个种子、同一个注记排法，画之前就能算
    /// （CollageWatermarks.Painter.prepare 在画格子之前排整页层）。vars = 这一页的占位符（和渲染同一份，{no} 定种子）。
    static func obstacles(_ sheet: CollageContactSheet, canvas: CollageCanvas, photos: [String: CollagePhotoRef],
                          vars: [String: String]) -> (text: [CGRect], ink: [CGRect]) {
        let rollNo = vars["no"] ?? "01"
        let lay = layout(sheet, canvas: canvas, rollNo: rollNo)
        let drawnIDs = lay.strips.flatMap { $0.slots.map(\.photoID) }
        let marks = marks(sheet, frames: drawnIDs, photos: photos)
        var ink: [CGRect] = []
        let lw = pencilWidth(lay)
        for strip in lay.strips {
            for slot in strip.slots {
                guard let mark = marks[slot.photoID] else { continue }
                let box = markRect(mark, frame: slot.rect, film: lay.film)
                let seed = CollagePencil.seed("\(slot.photoID)|\(rollNo)")
                for piece in CollagePencil.inkBoxes(mark, in: box, seed: seed, lineWidth: lw) {
                    ink.append(bbox(corners(piece).map { $0.applying(strip.transform) }))
                }
            }
        }
        var text: [CGRect] = []
        if let note = lay.note {
            let filled = filledNote(note.text, vars: noteVariables(sheet, ids: drawnIDs, vars: vars,
                                                                   photos: photos, rollNo: rollNo))
            if !filled.isEmpty {
                // 笔色不改字形，量的时候随便给一个。
                text.append(noteShape(note, text: filled, color: sheet.markColor).box)
            }
        }
        return (text, ink)
    }
}
