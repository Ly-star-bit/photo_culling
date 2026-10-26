import Foundation
import CoreGraphics

/// 人物挡字（字块在人后）和封面取景：一格照片的「决定」—— 取景窗口、每块人后的字实际在人前还是人后、刊头缩没缩、
/// 每个字母被挡掉多少、为什么退让。渲染器、画布上的虚框和拖字、水印避让、检视器读数、.marks.json 都问这一个
/// （CollageRender.overlayPlacements / cellWindow 里调），所以预览、导出、界面看到的是同一个决定。
///
/// 全按成品尺寸（1 倍）的几何和 1024 的蒙版算，和这次渲染缩放多少无关：renderclean@0.5 和 renderexport 的决定一样。
///
/// 规则（R1 §2，推出来的默认值，不是行业标准）：
/// - 字形栅格化（字块宽 ~512 像素）乘蒙版，得到每个字母被挡掉的墨迹比例 c_i；
/// - 首字母 ≤ 5%、末字母 ≤ 15%、总墨迹 ≤ 25%（每块字的 maxOcclusion 可调），超过 33% 一律不行；
///   被挡过半的字母：6 个字母以内最多 1 个，7 个以上最多 2 个；主行以外的每一行（期号日期小字）单独 ≤ 15%；
/// - 3 张脸以上（合影）不做遮挡；
/// - 不满足时依次退让：横向挪取景 → 拉远（头顶往下）→ 刊头缩到「头顶上方的净空 − 1.5% 格高」→ 退回字在人前
///   （封面取景把头放到刊头下面，字不压脸），并留一句原因给检视器。
enum CollageCover {

    static let firstMax = 0.05
    static let lastMax = 0.15
    static let hardMax = 0.33
    /// 被挡过半算「这个字母没了」。
    static let heavyLevel = 0.5
    /// 几张脸算合影。
    static let groupFaces = 3
    /// 刊头缩到头顶上方时，离头顶留多少（格高的比例）；字高缩得比原来 35% 还小就不缩了（字太小不像刊头）。
    static let headroomGap = 0.015
    static let shrinkFloor = 0.35
    /// 刊头带着的小字行（期号日期、副标题）每行单独限：墨少，总量里几乎看不出来，可挡掉一截就读不成了
    /// （「MARCH · 2026 · NO.01」被头挡成「NO.01」）。刊名规矩下主行以外的每一行都管；装饰大字只管小字行
    /// （字号不到主行一半的），和主行差不多大的行只算进总量。
    static let lineMax = 0.15
    static let smallLine = 0.5
    /// 封面取景要的眼位：字高 45–70% 处，或基线下 0–8% 格高。比基线低这么多（格高的比例）算「眼睛离刊头远」。
    static let eyeFarBelow = 0.08
    /// 退让（横向挪、拉远）那一步算不算成：规则满足之外，头还得碰得到刊头 —— 头顶进了字高（离主行基线至少 15% 字高），
    /// 并且主行（刊名）的墨挡掉了 ≥ 2%；脸中心留在格宽 30–70%。以前规则满足就停：
    /// 挪到头躲进字缝、拉远到头掉到刊头下面（总 0–1.5%），或者把人推到离格边 22% 的地方，也算「成了」。
    static let engageMin = 0.02
    static let engageDepth = 0.15
    static let centreBand: ClosedRange<Double> = 0.3...0.7

    /// 一块字被挡的情况（全是墨迹比例 0…1）。
    struct Occlusion: Hashable {
        /// 整块字（所有行）被挡掉多少墨。
        var total: Double
        /// 主行（字号最大的那一行，刊头）每个字母。
        var perLetter: [Double]
        var first: Double
        var last: Double
        /// 被挡过半的字母有几个。
        var heavy: Int
        /// 每一行（空行不算）被挡掉多少墨：刊头带着的期号日期小字墨少，总量里看不出来，每行单独限（lineMax）。
        var perLine: [Double] = []
        /// 主行是第几行（perLine 的下标）；每一行是不是小字（字号不到主行一半）。
        var mainLine = 0
        var smallLines: [Bool] = []

        var letters: Int { perLetter.count }
    }

    enum Step: String {
        /// 照原样在人后。
        case behind
        /// 横向挪了取景。
        case shifted
        /// 拉远了（头顶往下）。
        case pulledBack
        /// 刊头缩到头顶上方。
        case shrunk
        /// 退回人前。
        case front
    }

    /// 一块要求在人后的字最后怎么定的。
    struct Block {
        var layer: CollageTextLayer
        var step: Step
        /// 检视器那一句（照原样在人后 = nil）。
        var reason: String?
        /// 量出来的遮挡（退回人前的，记的是第一次试的那个：读数说得出为什么退）。没有蒙版 = nil。
        var occlusion: Occlusion?
        var limit: Double
        var depth: Double
        /// 主脸的眼睛有没有被字盖住（人后时看蒙版盖不盖得住眼睛；人前时看眼睛落不落在字形上）。没有脸 = nil。
        var eyesClear: Bool?
        /// 这块是不是定封面取景的那块（刊头）。
        var band: Bool
        /// 按哪套规矩判的（刊名 / 装饰大字只管总量）。
        var rule: CollageOcclusionRule = .masthead
        /// 退回人前时压着头，挪到了自动位置（躲开头）。
        var moved = false
        /// 刊头那块（封面取景、在人后）：主脸眼睛在主行基线下多远（格高的比例，负 = 在基线上面）；
        /// eyeFar = 超过 8%（照片下沿卡住、脸太大……），挑封面主图时可以按它筛。
        var eyeBelow: Double?
        var eyeFar = false
        /// 眼睛远是被什么卡住的："bottom" = 照片下沿（拉近就被照片底边卡住）、"top" = 头顶上面天不够、
        /// "face" = 脸在照片里太大。不远 = nil。挑封面主图按它筛（下沿卡住的竖图放进 3:4 最常见）。
        var eyeClamp: String?
    }

    struct Resolution {
        /// 这一格的取景（铺出血之前、成品尺寸那一份）。
        var window: CollageCrop.Window
        /// 和 cell.overlays 一一对应：要求在人后的有，别的 nil。
        var blocks: [Block?]
        /// 刊头缩字（字块下标 → 最高多少成品像素）。
        var maxHeights: [Int: Double] = [:]
        /// 退回人前、挪开头的字块（下标 → 要躲开的头，成品坐标）：摆位时改成自动位置，头当成已占用。
        var moved: [Int: [CGRect]] = [:]
        var mask: CollageMasks.Mask?
        /// 主脸头顶（归一化照片 y）和它是怎么来的："mask" / "estimate"。
        var headTop: Double?
        var headTopSource: String
        var faces: Int
        /// 抠图格要贴着成品底边（CollageCutout.toEdge）却贴不上：这一张不抠、整张照片照放（人后的字照样按蒙版）。
        /// cutoutReason = 检视器 / coverdump 那一句；edgeCoverage = 量的数（取景底边那一条、往上身子那一截蒙版盖住多宽）。
        var cutoutDropped = false
        var cutoutReason: String?
        var edgeCoverage: (edge: Double, body: Double)?

        /// 有字块最后在人后：要画主体切图。
        var hasBehind: Bool { blocks.contains { $0?.layer == .behindSubject } }
    }

    // MARK: - 入口（带缓存）

    private struct Key: Hashable {
        var cell: CollageCell
        var frame: [Double]
        var canvas: CollageCanvas
        var style: CollageStyle
        var photo: CollagePhotoRef
        var framing: CollageFraming
        var hints: CollageCrop.Hints?
        var vars: [String: String]
        var background: CollageColor
    }

    private static let lock = NSLock()
    private static var cache: [Key: Resolution] = [:]

    /// 这一格走不走这一套：封面取景、有人后的字、抠图格（只看格子自己设的，「自动」景别不会变成封面）。
    static func applies(to cell: CollageCell) -> Bool {
        cell.kind == .photo && (cell.framing == .cover || cell.cutout != nil
            || cell.overlays.contains { $0.layer == .behindSubject })
    }

    /// 这一格要不要走这一套：封面取景、有人后的字、抠图格。都不是 = nil（旧版式一步都不多走，逐像素不变）。
    static func resolve(cell: CollageCell, frameRect: CGRect, project: CollageProject, photo: CollagePhotoRef?,
                        framing: CollageFraming, hints: CollageCrop.Hints?, vars: [String: String],
                        background: CollageColor) -> Resolution? {
        guard let photo, cell.kind == .photo else { return nil }
        let behind = cell.overlays.contains { $0.layer == .behindSubject }
        guard framing == .cover || behind || cell.cutout != nil else { return nil }
        // Hints 里抄过来的头顶不进键：决定用的是蒙版自己的头顶，后台抄完不该让缓存失效。
        var bare = hints
        bare?.headTop = nil
        bare?.maskCoverage = nil
        let frame = [Double(frameRect.minX), Double(frameRect.minY), Double(frameRect.width), Double(frameRect.height)]
        let key = Key(cell: cell, frame: frame, canvas: project.canvas, style: project.style, photo: photo,
                      framing: framing, hints: bare, vars: vars, background: background)
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }
        var out = solve(cell: cell, frameRect: frameRect, project: project, photo: photo, framing: framing,
                        hints: hints, vars: vars, background: background)
        // 抠图格贴不到成品底边就不抠（CollageCutout.toEdge，CollageStyleSwissCutout.swift；别的格子一步都不多走）。
        edgeRule(&out, cell: cell, frameRect: frameRect, canvas: project.canvas)
        markPeople(&out)
        lock.lock()
        if cache.count > 128 { cache.removeAll() }
        cache[key] = out
        lock.unlock()
        return out
    }

    /// 蒙版另外认出来的人（Mask.people：主体以外的人，K1 起）也算路人：取景里有就标「路人」（画布角标、检视器提示、
    /// 出一期挑主图的罚分 —— DESIGN 的「取景窗里没有路人」以前只看 Vision 人框，近处被切半个的游客漏掉了）。
    /// 只改标记、不挪取景：渲染一个像素都不变。
    static func markPeople(_ res: inout Resolution) {
        guard !res.window.hitsBystander, let people = res.mask?.people, !people.isEmpty else { return }
        res.window.hitsBystander = CollageCrop.overlap(res.window.rect, people) > 0.0005
    }

    /// 测试用：清掉决定缓存。
    static func purge() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - 解

    private static func solve(cell: CollageCell, frameRect: CGRect, project: CollageProject, photo: CollagePhotoRef,
                              framing: CollageFraming, hints: CollageCrop.Hints?, vars: [String: String],
                              background: CollageColor) -> Resolution {
        let style = project.style
        let overlays = cell.overlays
        let mask = CollageMasks.mask(for: photo)
        let faces = photo.faces.filter(CollageCrop.isValidBox)
        let primary = faces.first
        let estimate: Double? = primary.map { max(0, $0[1] - 0.3 * ($0[3] - $0[1])) }
        let measured = mask?.primaryHeadTop
        let headTop = measured ?? estimate
        let area = CollageCrop.photoArea(cell: cell, rect: frameRect, style: style)
        let aspect = CollageCrop.aspect(of: area)
        // 零边距印刷、这一格贴着成品边：导出时取景往出血外延。先把外延的那几毫米留出来（预览也留：同一个决定），
        // 导出时正好装得下，不用整块平移 —— 平移了头就不在刊头里定好的位置上，量出来的遮挡也不是印出来的那个。
        let reserve = CollageRender.bleedReserve(cell: cell, frameRect: frameRect, project: project)
        let plain = CollageCrop.reserved(
            CollageCrop.window(for: photo, cell: cell, cellAspect: aspect, framing: framing, hints: hints), reserve)
        var res = Resolution(window: plain, blocks: Array(repeating: nil, count: overlays.count), mask: mask,
                             headTop: headTop, headTopSource: measured != nil ? "mask" : "estimate", faces: faces.count)
        guard !overlays.isEmpty else { return res }

        let geo = CollageRender.overlayGeometry(cell: cell, frameRect: frameRect, style: style, photo: photo,
                                                framing: framing, hints: hints, window: plain)
        let drawn = geo.drawn
        let shape = cell.shape ?? style.shape
        let framed = CollageCrop.isFramed(cell: cell, style: style)
        // 照片只在形状里：圆、拱窗外面的字底下没有人（矩形 = 只看 drawn）。抠图格的主体不裁到形状里
        // （形状外面本来就是页面底色，drawSubject 只裁到格子的矩形），同样只看 drawn。
        let corner = CGFloat(style.corner * project.canvas.shortSide)
        let clip: CGPath? = (shape == .rect || framed || cell.cutout != nil) ? nil
            : CollageRender.shapePath(shape, rect: drawn, corner: corner)
        func placements(_ w: CollageCrop.Window, _ heights: [Int: Double],
                        _ moves: [Int: [CGRect]] = [:]) -> [CollageOverlays.Placement?] {
            CollageRender.rawPlacements(cell: cell, frameRect: frameRect, project: project, photo: photo,
                                        framing: framing, hints: hints, vars: vars, background: background,
                                        window: w, maxHeights: heights, mask: mask, moved: moves)
        }
        let fixed: (CollageOverlay) -> Bool = { $0.anchor != .auto && !$0.anchor.isSide }
        let behindIdx = overlays.indices.filter { overlays[$0].layer == .behindSubject }
        // 定封面取景的那块（刊头）：人后、定死位置的第一块；封面取景但字都在人前时，取定死位置的第一块（头放到它下面）。
        let band = behindIdx.first { fixed(overlays[$0]) }
            ?? (framing == .cover ? overlays.indices.first { fixed(overlays[$0]) } : nil)
        let first = placements(plain, [:])
        let bandPlacement = band.flatMap { first[$0] }
        let bandLetters = bandPlacement.map { letters($0, vars: vars, drawn: drawn, clip: clip) }
        // 刊头在格子上半截才谈得上「头顶压进刊头」。
        let bandOnTop = bandPlacement.map { $0.rect.midY < area.midY } ?? false
        let canSolve = framing == .cover && !cell.contain && cell.crop == nil && primary != nil && headTop != nil
            && bandOnTop && bandLetters != nil
        func target(_ t: Double, behind: Bool, shift: Double = 0) -> CollageCrop.CoverTarget {
            // 字在人前：头顶放到整块字最下面那一行的基线下面（刊头带着期号日期小字时也不压；单行就是主行基线）。
            let base: Double = (behind ? bandLetters?.baseline : bandLetters?.lastBaseline) ?? Double(area.minY)
            return CollageCrop.CoverTarget(area: area, capTop: bandLetters?.capTop ?? Double(area.minY),
                                           baseline: base, depth: t, behind: behind,
                                           headTop: headTop ?? 0, upscaleLimit: CollageStore.upscaleLimit,
                                           maxZoom: band.flatMap { overlays[$0].maxZoom }, shiftX: shift,
                                           reserve: reserve)
        }
        func coverWindow(_ t: Double, behind: Bool, shift: Double = 0) -> CollageCrop.Window {
            CollageCrop.coverWindow(photo: photo, cellAspect: aspect, target: target(t, behind: behind, shift: shift),
                                    hints: hints)
        }
        // 退回人前时的取景：封面把头放到刊头下面（字不压脸），别的照旧（压着头的字块下面再挪开）。
        let frontWindow = canSolve ? coverWindow(0, behind: false) : plain
        // 退让那一步成没成（engageMin 那几条）：规则满足、头还压得进刊头、人没被推到格子边上。
        func meets(_ w: CollageCrop.Window, _ oc: Occlusion, _ L: Letters) -> Bool {
            guard let f = primary, let ht = headTop, w.w > 0, w.h > 0 else { return true }
            let sx: Double = Double(drawn.width) / w.w
            let sy: Double = Double(drawn.height) / w.h
            let headY: Double = Double(drawn.minY) + (ht - w.y) * sy
            let capH: Double = max(1, L.baseline - L.capTop)
            guard headY <= L.baseline - engageDepth * capH else { return false }
            let centreX: Double = Double(drawn.minX) + ((f[0] + f[2]) / 2 - w.x) * sx
            let frac: Double = (centreX - Double(area.minX)) / max(1, Double(area.width))
            guard centreBand.contains(frac) else { return false }
            // 看主行（刊名）挡掉的墨：头只擦到下面的期号日期小字、或者躲进字缝里一点墨都没碰，不算压进了刊头
            // （「头框横向压着字母」这种量法对中文刊头不灵：汉字的外框又宽又空，头在两个字之间也算压着）。
            let mainOcc: Double = oc.perLine.indices.contains(oc.mainLine) ? oc.perLine[oc.mainLine] : oc.total
            return mainOcc >= engageMin
        }
        // 拉远了多少（原因的措辞）：拉到最大的窗口（整张照片都用上了）写「不少」，窗口高长了 25% 以上「一些」，否则「一点」。
        let maxW = CollageCrop.maxWindow(photoAspect: photo.aspect, cellAspect: aspect)
        let spanX: Double = 1 + reserve.left + reserve.right
        let spanY: Double = 1 + reserve.top + reserve.bottom
        let fullH: Double = min(maxW.h, 1 / spanY, maxW.h / (maxW.w * spanX))
        func pulled(_ w: CollageCrop.Window, from w0: CollageCrop.Window) -> String {
            pullWording(w.h, from: w0.h, full: fullH)
        }
        var window = plain
        var heights: [Int: Double] = [:]
        // 刊头在人后、规则都满足，但头顶根本没到刊头（下面的眼位就不用再说一遍）。
        var headMissed = false

        if let b = band, overlays[b].layer == .behindSubject, let L = bandLetters {
            let o = overlays[b]
            let rule = o.occlusionRule
            let limit = min(hardMax, o.maxOcclusion)
            var block = Block(layer: .behindSubject, step: .behind, reason: nil, occlusion: nil, limit: limit,
                              depth: o.depth, eyesClear: nil, band: true, rule: rule)
            if faces.count >= groupFaces {
                block.layer = .front
                block.step = .front
                block.reason = "多人合影（\(faces.count) 张脸），刊头放到人物前面了"
                window = frontWindow
            } else if let mask {
                let w0 = canSolve ? coverWindow(o.depth, behind: true) : plain
                let o0 = occlusion(L, window: w0, drawn: drawn, mask: mask)
                block.occlusion = o0
                window = w0
                if let why = failure(o0, limit: limit, rule: rule) {
                    var found = false
                    if canSolve {
                        // 1. 横向挪：每次挪窗口宽的 1/16，近的先试，两边轮流。
                        for k in 1...8 where !found {
                            for sign in [1.0, -1.0] {
                                let shift: Double = sign * Double(k) * w0.w / 16
                                let w = coverWindow(o.depth, behind: true, shift: shift)
                                guard abs(w.x - w0.x) > 1e-6 else { continue }
                                let oc = occlusion(L, window: w, drawn: drawn, mask: mask)
                                if failure(oc, limit: limit, rule: rule) == nil, meets(w, oc, L) {
                                    window = w
                                    block.occlusion = oc
                                    block.step = .shifted
                                    let much = k <= 2 ? "一点" : (k <= 5 ? "一些" : "不少")
                                    block.reason = "挡得太多（\(why)），取景往旁边挪了\(much)"
                                    found = true
                                    break
                                }
                            }
                        }
                        // 2. 拉远：头顶一档档往下（t 加大，越过基线也行）。
                        if !found {
                            var steps: [Double] = [0.15, 0.3, 0.45, 0.6, 0.8, 1.0, 1.25]
                            // 刊头带着小字行（期号日期）：最后再试一档，头顶放到整块字下面（小字一点不挡；单行刊头不多试）。
                            if L.lastBaseline > L.baseline + 1 {
                                let capH: Double = max(1, L.baseline - L.capTop)
                                let below: Double = L.lastBaseline + headroomGap * Double(area.height) - L.capTop
                                let clear: Double = below / capH - o.depth
                                if clear > 1.25 { steps.append(clear) }
                            }
                            for dt in steps {
                                let w = coverWindow(o.depth + dt, behind: true)
                                let oc = occlusion(L, window: w, drawn: drawn, mask: mask)
                                if failure(oc, limit: limit, rule: rule) == nil, meets(w, oc, L) {
                                    window = w
                                    block.occlusion = oc
                                    block.step = .pulledBack
                                    block.reason = "挡得太多（\(why)），取景拉远了\(pulled(w, from: w0))（头顶往下）"
                                    found = true
                                    break
                                }
                            }
                        }
                    }
                    // 3. 刊头缩到头顶上方的净空 − 1.5% 格高（照常取景：封面 = 不拉近的那一版）。按墨算：字块顶不动，
                    //    整块按比例缩到主行基线落在头顶上方（字块上下还有字身留白，不能拿字块高去比）。
                    if !found, let ht = headTop, plain.h > 0 {
                        let headY: Double = Double(drawn.minY) + (ht - plain.y) / plain.h * Double(drawn.height)
                        let top = Double(L.rect.minY)
                        let reach = max(1, L.baseline - top)
                        let k: Double = (headY - headroomGap * Double(area.height) - top) / reach
                        let full = Double(L.rect.height)
                        var trial: [Int: Double] = [:]
                        if k < 1 { trial[b] = full * k }
                        // 不用缩（k ≥ 1）= 照常取景头本来就在刊头下面：那样头离刊头老远（近景整张照片铺满、全身取景），
                        // 不算这一步成了 —— 接着退回人前，封面取景把头放到刊头下面 2%（会拉近）。
                        if k >= shrinkFloor, !trial.isEmpty, let p1 = placements(plain, trial)[b] {
                            let L1 = letters(p1, vars: vars, drawn: drawn, clip: clip)
                            let oc = occlusion(L1, window: plain, drawn: drawn, mask: mask)
                            if failure(oc, limit: limit, rule: rule) == nil {
                                window = plain
                                heights = trial
                                block.occlusion = oc
                                block.step = .shrunk
                                block.reason = "挡得太多（\(why)），头顶上方地方不够，刊头缩小了"
                                found = true
                            }
                        }
                    }
                    // 4. 退回人前（封面取景把头放到刊头下面；别的景别下面挪开头）。原因只说真试过的那几步：
                    //    不是封面取景（或手动裁过、完整显示）的格子没挪过取景、没拉远过。
                    if !found {
                        window = frontWindow
                        block.occlusion = o0
                        block.layer = .front
                        block.step = .front
                        let tried = canSolve ? "挪取景、拉远、缩字都不行"
                            : "缩字也不行（\(fixedWhy(cell: cell, framing: framing))，不挪取景）"
                        block.reason = "挡得太多（\(why)），\(tried)，刊头放到人物前面了"
                    }
                    block.reason = block.reason.map { $0 + lineHint(why) }
                } else if let ht = headTop, w0.h > 0 {
                    // 规则都满足，但可能是因为头根本没碰到刊头：照片像素不够，再拉近就超过放大上限（coverWindow 停在
                    // 上限、t 推到头），或者这一格根本不是封面取景（半身、手动裁过……），头顶落在刊头基线下面 ——
                    // 读数「刊名被挡 0%」得说清为什么、怎么才压得进去。
                    let headY: Double = Double(drawn.minY) + (ht - w0.y) / w0.h * Double(drawn.height)
                    // 头顶在基线下面；或者只擦到字的下半截、一点墨都没挡（半身取景常见：头顶刚好停在字脚）。
                    let capH: Double = max(1, L.baseline - L.capTop)
                    let grazed = o0.total < 0.005 && headY > L.capTop + 0.5 * capH
                    if headY >= L.baseline || grazed {
                        let what = rule == .masthead ? "刊名" : "大字"
                        headMissed = true
                        if canSolve {
                            let up = CollageCrop.upscale(photo: photo, window: w0, drawn: drawn)
                            let limitText = String(format: "%.1f", CollageStore.upscaleLimit)
                            block.reason = up >= CollageStore.upscaleLimit - 0.005
                                ? "照片像素不够，拉近会放大超过 \(limitText) 倍，头顶到不了刊头（\(what)没被挡）"
                                : "取景到照片边了，头顶到不了刊头（\(what)没被挡）"
                        } else {
                            block.reason = "\(fixedWhy(cell: cell, framing: framing))，头顶到不了刊头（\(what)没被挡）"
                                + coverHint(cell: cell, framing: framing)
                        }
                    }
                } else if primary == nil, o0.total < 0.005 {
                    // 有蒙版、没认出脸（背影、侧脸、扇子挡着脸）：没有头顶可对，取景不为刊头挪，也一点没挡 ——
                    // 「刊名被挡 0%」同样得说为什么（以前什么都不说，「人后」开关像是没用）。
                    let what = rule == .masthead ? "刊名" : "大字"
                    headMissed = true
                    block.reason = "照片里没有认出人脸，取景不会为刊头挪动，头压不进刊头（\(what)没被挡）"
                }
            } else {
                block.layer = .front
                block.step = .front
                block.reason = "这张照片认不出主体（抠不出人），刊头放到人物前面了"
                window = frontWindow
            }
            res.blocks[b] = block
        } else if framing == .cover, canSolve {
            // 封面取景、刊头在人前：头放到刊头下面。
            window = frontWindow
        } else if framing == .cover, !bandOnTop, behindIdx.isEmpty, !cell.contain, cell.crop == nil, let f = primary {
            // 封面景别、上方没有刊头（时尚刊引语单图拿它当「脸在格子正中、不拉近」）：窄高的格子里脸贴着照片边、
            // 居中不了时拉近一点，让脸中心进格宽 35–65%（CollageStyleFashionType）。
            window = CollageCrop.faceCentred(plain, photo: photo, face: f, reserve: reserve, drawn: drawn,
                                             bystanders: hints?.bystanders ?? [])
        }

        // 退回人前、定死位置（不是手动拖的）的字块还压着头（非封面景别、封面也没能把头放到字下面）：改成自动位置、
        // 把头当成已占用，在九个位置 × 三档大小里挑不压头的。挪了还压着就留在原处，原因里说一句。
        let heads = headBoxes(faces: faces, headTop: headTop, window: window, drawn: drawn)
        var moved: [Int: [CGRect]] = [:]
        func avoidHeads(_ i: Int, _ current: [CollageOverlays.Placement?]) -> [CollageOverlays.Placement?]? {
            guard !heads.isEmpty, var block = res.blocks[i], block.layer == .front, fixed(overlays[i]),
                  overlays[i].anchor != .custom, let p = current[i], touches(p, heads, vars: vars) else { return nil }
            var trial = moved
            trial[i] = heads
            let again = placements(window, heights, trial)
            let said = block.reason ?? ""
            guard let q = again[i], !touches(q, heads, vars: vars) else {
                block.reason = said + "（压着头，照片里找不到不压脸的地方）"
                res.blocks[i] = block
                return nil
            }
            moved = trial
            block.moved = true
            block.reason = said + "（压着头，挪到不压脸的地方了）"
            res.blocks[i] = block
            return again
        }
        var final = placements(window, heights)
        if let b = band, let again = avoidHeads(b, final) { final = again }

        // 其余人后的字（自动位置、沿边的、第二块定死位置的）：在定下来的取景上量，挡太多就放到人前。
        // again = 有字块挪开了头、自动位置的跟着换了地方：只把还在人后的再量一遍（已经退回人前的不动）。
        func measureRest(again: Bool) {
            for i in behindIdx where i != band {
                if again, res.blocks[i]?.layer != .behindSubject { continue }
                let o = overlays[i]
                let limit = min(hardMax, o.maxOcclusion)
                var block = Block(layer: .behindSubject, step: .behind, reason: nil, occlusion: nil, limit: limit,
                                  depth: o.depth, eyesClear: nil, band: false, rule: o.occlusionRule)
                if faces.count >= groupFaces {
                    block.layer = .front
                    block.step = .front
                    block.reason = "多人合影（\(faces.count) 张脸），这块字放到人物前面了"
                } else if let mask, let p = final[i] {
                    let L = letters(p, vars: vars, drawn: drawn, clip: clip)
                    let oc = occlusion(L, window: window, drawn: drawn, mask: mask)
                    block.occlusion = oc
                    if let why = failure(oc, limit: limit, rule: o.occlusionRule) {
                        block.layer = .front
                        block.step = .front
                        block.reason = "这块字挡得太多（\(why)），放到人物前面了" + lineHint(why)
                    } else if !fixed(o), oc.total < 0.005 {
                        // 自动位置、沿边的字摆位时躲着脸：在人后也碰不到人，开关看着没反应 —— 说清怎么才挡得到。
                        let how = o.anchor.isSide ? "沿边的字会躲开人" : "自动位置的字会躲开人"
                        let fix = framing == .cover ? "把位置定在「上」" : "把位置定在「上」，景别用「封面」"
                        block.reason = "\(how)，挡不到；\(fix)，头才会压进字里"
                    }
                } else if mask == nil {
                    block.layer = .front
                    block.step = .front
                    block.reason = "这张照片认不出主体（抠不出人），这块字放到人物前面了"
                }
                res.blocks[i] = block
            }
        }
        measureRest(again: false)
        // 其余退回人前、定死位置的也躲开头。挪过以后自动位置的字块可能跟着换了地方：还在人后的再量一遍。
        var shifted = false
        for i in behindIdx where i != band {
            if let again = avoidHeads(i, final) {
                final = again
                shifted = true
            }
        }
        if shifted { measureRest(again: true) }
        // 眼睛：人后看蒙版盖不盖得住眼睛，人前看眼睛落不落在字形上。
        if let f = primary, window.w > 0, window.h > 0 {
            let eyeV: Double = f[1] + 0.42 * (f[3] - f[1])
            let eyeU: Double = (f[0] + f[2]) / 2
            let ex: Double = Double(drawn.minX) + (eyeU - window.x) / window.w * Double(drawn.width)
            let ey: Double = Double(drawn.minY) + (eyeV - window.y) / window.h * Double(drawn.height)
            let eye = CGPoint(x: ex, y: ey)
            for i in res.blocks.indices {
                guard var block = res.blocks[i] else { continue }
                if block.layer == .behindSubject {
                    block.eyesClear = (mask?.value(u: eyeU, v: eyeV) ?? 0) >= 0.5
                } else if let p = final[i] {
                    let glyphs = CollageTypeset.glyphOutlines(p.text, in: p.rect, short: p.short, vars: vars)
                    block.eyesClear = !glyphs.contains { $0.bounds.contains(eye) }
                }
                res.blocks[i] = block
            }
            // 刊头在人后、封面取景：眼睛离刊头基线多远。超过 8% 格高（照片下沿卡住了拉近、脸太大、头顶上面天不够）
            // 封面就不像了：记下来（marks、挑主图用），原因里说一句（拉远、头顶到不了刊头的已经说过了，不再说）。
            if let b = band, var block = res.blocks[b], block.layer == .behindSubject, canSolve, heights.isEmpty,
               let L = bandLetters {
                let below: Double = (ey - L.baseline) / max(1, Double(area.height))
                block.eyeBelow = below
                if below > eyeFarBelow + 0.005 {
                    block.eyeFar = true
                    let bottomEdge: Double = window.y + window.h * (1 + reserve.bottom)
                    let clamp = bottomEdge >= 1 - 1e-3 ? "bottom" : (window.y <= reserve.top * window.h + 1e-3 ? "top" : "face")
                    block.eyeClamp = clamp
                    if !headMissed, block.step == .behind || block.step == .shifted {
                        let cause = clamp == "bottom" ? "照片下沿不够（拉近就被照片底边卡住）"
                            : (clamp == "top" ? "头顶上面的天不够（只能拉近）" : "脸在照片里太大")
                        let text = "\(cause)，眼睛离刊头远了些（在刊头基线下 \(percent(below))，理想是 0–8%）"
                        block.reason = block.reason.map { $0 + "；" + text } ?? text
                    }
                }
                res.blocks[b] = block
            }
        }
        res.window = window
        res.maxHeights = heights
        res.moved = moved
        return res
    }

    /// 拉远了多少（原因的措辞，按窗口高）：拉到最大的窗口写「不少（整张照片都用上了）」，长了 25% 以上「一些」，否则「一点」。
    static func pullWording(_ h: Double, from h0: Double, full: Double) -> String {
        if h >= full * 0.995 { return "不少（整张照片都用上了）" }
        return h >= 1.25 * h0 ? "一些" : "一点"
    }

    /// 每张脸的「头」（脸框两边各放宽 0.15 脸宽算上两鬓的头发、头顶到下巴）投到这一格上（成品坐标）。主脸的头顶用
    /// 定下来的那个（蒙版实测 / 估计），别的脸按脸框上沿 − 0.3 脸高估。整个在取景外的不要。
    private static func headBoxes(faces: [[Double]], headTop: Double?, window: CollageCrop.Window,
                                  drawn: CGRect) -> [CGRect] {
        faces.enumerated().compactMap { k, f in
            let fh = f[3] - f[1]
            let side: Double = 0.15 * (f[2] - f[0])
            let guess: Double = max(0, f[1] - 0.3 * fh)
            let top: Double = min(f[1], k == 0 ? (headTop ?? guess) : guess)
            return CollageCrop.project([f[0] - side, top, f[2] + side, f[3]], window: window, into: drawn)
        }
    }

    /// 退让时为什么不挪取景（canSolve 为假的那几种，给原因用）。
    private static func fixedWhy(cell: CollageCell, framing: CollageFraming) -> String {
        if framing != .cover { return "这一格不是封面取景" }
        if cell.crop != nil { return "这一格手动裁过" }
        if cell.contain { return "这一格是完整显示" }
        return "这一格定不了封面取景"
    }

    /// 是小字行挡多了才退让的：提一句怎么让头压进刊名（小字另起一块，人前的字块不受这条限）。
    private static func lineHint(_ why: String) -> String {
        why.hasPrefix("第 ") ? "；把小字另起一块（放人前），刊名才压得进头" : ""
    }

    /// 头顶到不了刊头时怎么改（接在原因后面；没得改 = 空）。
    private static func coverHint(cell: CollageCell, framing: CollageFraming) -> String {
        if framing != .cover { return "；景别换成「封面」，头顶才会压进刊头" }
        if cell.crop != nil { return "；复位裁切，封面取景才挪得动" }
        if cell.contain { return "；关掉完整显示，封面取景才挪得动" }
        return ""
    }

    /// 字（每个字形的外框）碰没碰到头。
    private static func touches(_ p: CollageOverlays.Placement, _ heads: [CGRect], vars: [String: String]) -> Bool {
        let glyphs = CollageTypeset.glyphOutlines(p.text, in: p.rect, short: p.short, vars: vars)
        return glyphs.contains { g in heads.contains { $0.intersects(g.bounds) } }
    }

    /// 不满足哪一条（给原因用的一句）；都满足 = nil。rule = 装饰大字时只看总量（首末字母、过半的字母不管）。
    /// 主行以外的行（期号日期这种小字）每行单独限 lineMax：刊名规矩下每一行都管，装饰大字只管小字行。
    static func failure(_ o: Occlusion, limit: Double, rule: CollageOcclusionRule = .masthead) -> String? {
        let what = rule == .masthead ? "刊名" : "大字"
        if o.total > hardMax { return "\(what)被挡 \(percent(o.total, over: hardMax))，超过 33%" }
        if o.total > limit { return "\(what)被挡 \(percent(o.total, over: limit))，超过上限 \(percent(limit))" }
        if rule == .masthead {
            if o.first > firstMax { return "首字母被挡 \(percent(o.first, over: firstMax))（上限 5%）" }
            if o.last > lastMax { return "末字母被挡 \(percent(o.last, over: lastMax))（上限 15%）" }
            // 3、4 个字母的短刊名（AYA、NORD）一个字母都不许挡过半：字距撑开之后头正好落在中间那个字母上，
            // 挡掉一个就成了「A A」（R1：ELLE 那种短刊名实测只挡第二个 L 的两成）。
            if o.letters <= 4, o.letters >= 3, o.heavy > 0 { return "短刊名有字母被挡过半" }
            let allowed = o.letters <= 6 ? 1 : 2
            if o.heavy > allowed { return "\(o.heavy) 个字母被挡过半" }
        }
        for (i, v) in o.perLine.enumerated() where i != o.mainLine && v > lineMax {
            let small = o.smallLines.indices.contains(i) && o.smallLines[i]
            guard rule == .masthead || small else { continue }
            return "第 \(i + 1) 行被挡 \(percent(v, over: lineMax))（小字每行上限 \(percent(lineMax))）"
        }
        return nil
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// 超了上限的量：取整以后和上限一样（15.4% 对 15%）就多给一位小数（还一样再多一位），免得读成「15%，超过 15%」。
    static func percent(_ v: Double, over limit: Double) -> String {
        if Int((v * 100).rounded()) != Int((limit * 100).rounded()) { return percent(v) }
        let one = String(format: "%.1f", v * 100)
        if one != String(format: "%.1f", limit * 100) { return one + "%" }
        return String(format: "%.2f%%", v * 100)
    }

    // MARK: - 字形 × 蒙版

    /// 一块字栅格化之后的墨：每个字形一组采样点（成品坐标的像素中心 + 墨的深浅），外加主行（字号最大的那一行）
    /// 是哪几个字形、主行的字顶和基线（封面取景的刊头带）。
    struct Letters {
        struct Sample {
            var x: Float
            var y: Float
            var ink: Float
            /// 落在照片画出来的地方（形状里）：外面的字底下没有人。
            var inside: Bool
        }
        var samples: [[Sample]]
        var ink: [Double]
        /// 每个字形在第几行。
        var lineOf: [Int]
        var main: [Int]
        var capTop: Double
        var baseline: Double
        var rect: CGRect
        /// 主行是第几行；每一行的字号（短边比例，和 expandedLines 一一对应）。
        var mainLine = 0
        var lineSizes: [Double] = []
        /// 最下面那一行的基线（单行 = baseline）：字在人前时头放到它下面。
        var lastBaseline = 0.0
    }

    /// 栅格化：字块长边 ~512 像素（比 1 倍小就按 1 倍），每个字形单独画一张小图，记下有墨的像素。
    static func letters(_ p: CollageOverlays.Placement, vars: [String: String], drawn: CGRect, clip: CGPath?) -> Letters {
        let glyphs = CollageTypeset.glyphOutlines(p.text, in: p.rect, short: p.short, vars: vars)
        let lines = CollageTypeset.expandedLines(p.text, vars: vars)
        var mainLine = 0
        var biggest = -1.0
        for (i, l) in lines.enumerated() where l.line.size > biggest {
            biggest = l.line.size
            mainLine = i
        }
        let longSide = Double(max(p.rect.width, p.rect.height))
        let r: Double = min(1, 512 / max(1, longSide))
        var samples: [[Letters.Sample]] = []
        var ink: [Double] = []
        var main: [Int] = []
        for (k, g) in glyphs.enumerated() {
            let pts = rasterize(g.path, bounds: g.bounds, scale: r, drawn: drawn, clip: clip)
            samples.append(pts)
            ink.append(pts.reduce(0) { $0 + Double($1.ink) })
            if g.line == mainLine { main.append(k) }
        }
        let lineOf = glyphs.map(\.line)
        let mainGlyphs = main.map { glyphs[$0] }
        let upright = !p.text.vertical && !p.text.isRotated
        let capTop: Double = upright ? Double(mainGlyphs.map(\.bounds.minY).min() ?? p.rect.minY) : Double(p.rect.minY)
        let baseline: Double = upright ? (mainGlyphs.first?.baseline ?? Double(p.rect.maxY)) : Double(p.rect.maxY)
        let lastBaseline: Double = upright ? (glyphs.map(\.baseline).max() ?? baseline) : baseline
        return Letters(samples: samples, ink: ink, lineOf: lineOf, main: main, capTop: capTop, baseline: baseline,
                       rect: p.rect, mainLine: mainLine, lineSizes: lines.map { $0.line.size },
                       lastBaseline: max(baseline, lastBaseline))
    }

    private static func rasterize(_ path: CGPath, bounds b: CGRect, scale r: Double, drawn: CGRect,
                                  clip: CGPath?) -> [Letters.Sample] {
        let w = Int((Double(b.width) * r).rounded(.up)) + 2
        let h = Int((Double(b.height) * r).rounded(.up)) + 2
        guard w > 2, h > 2, w * h < 4_000_000 else { return [] }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // 翻成 y 朝下：位图第 j 行 = 成品 y 方向第 j 个像素。
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: CGFloat(r), y: CGFloat(r))
            ctx.translateBy(x: -b.minX + CGFloat(1 / r), y: -b.minY + CGFloat(1 / r))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            return true
        }
        guard ok else { return [] }
        var out: [Letters.Sample] = []
        let x0 = Double(b.minX) - 1 / r
        let y0 = Double(b.minY) - 1 / r
        for j in 0..<h {
            for i in 0..<w {
                let v = pixels[j * w + i]
                guard v > 0 else { continue }
                let x: Double = x0 + (Double(i) + 0.5) / r
                let y: Double = y0 + (Double(j) + 0.5) / r
                let pt = CGPoint(x: x, y: y)
                let inside = drawn.contains(pt) && (clip?.contains(pt) ?? true)
                out.append(Letters.Sample(x: Float(x), y: Float(y), ink: Float(Double(v) / 255), inside: inside))
            }
        }
        return out
    }

    /// 这块字在这个取景下被挡掉多少：每个采样点按取景映射回照片，乘那里的蒙版值。
    static func occlusion(_ L: Letters, window: CollageCrop.Window, drawn: CGRect, mask: CollageMasks.Mask) -> Occlusion {
        let dw = max(1e-6, Double(drawn.width))
        let dh = max(1e-6, Double(drawn.height))
        let sx: Double = window.w / dw
        let sy: Double = window.h / dh
        let ox = Double(drawn.minX)
        let oy = Double(drawn.minY)
        var hits = [Double](repeating: 0, count: L.samples.count)
        for (k, letter) in L.samples.enumerated() {
            var hit = 0.0
            for s in letter where s.inside {
                let u: Double = window.x + (Double(s.x) - ox) * sx
                let v: Double = window.y + (Double(s.y) - oy) * sy
                hit += Double(s.ink) * mask.value(u: u, v: v)
            }
            hits[k] = hit
        }
        var out = summarize(hits: hits, ink: L.ink, main: L.main)
        let lines = (L.lineOf.max() ?? -1) + 1
        out.perLine = (0..<lines).map { line in
            let idx = L.lineOf.indices.filter { L.lineOf[$0] == line }
            let total = idx.reduce(0) { $0 + L.ink[$1] }
            return total > 0 ? min(1, idx.reduce(0) { $0 + hits[$1] } / total) : 0
        }
        out.mainLine = L.mainLine
        let mainSize: Double = L.lineSizes.indices.contains(L.mainLine) ? L.lineSizes[L.mainLine] : 0
        out.smallLines = (0..<lines).map { line in
            L.lineSizes.indices.contains(line) && L.lineSizes[line] <= smallLine * mainSize
        }
        return out
    }

    /// 每个字形被挡的墨 → 整块、主行每个字母、首末字母、过半的个数（自测直接拿合成数据调它）。
    static func summarize(hits: [Double], ink: [Double], main: [Int]) -> Occlusion {
        let totalInk = ink.reduce(0, +)
        let totalHit = hits.reduce(0, +)
        let total: Double = totalInk > 0 ? totalHit / totalInk : 0
        let per: [Double] = main.map { i in ink[i] > 0 ? min(1, hits[i] / ink[i]) : 0 }
        let heavy = per.filter { $0 > heavyLevel }.count
        return Occlusion(total: min(1, total), perLetter: per, first: per.first ?? 0, last: per.last ?? 0, heavy: heavy)
    }
}
