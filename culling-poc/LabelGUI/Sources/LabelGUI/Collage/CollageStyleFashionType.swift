import Foundation
import CoreGraphics

/// 时尚刊的「干净的字」（CollageOverlay.scrim = false）：不垫雾面（S3 样张里那块灰雾面一层层叠出来发脏），
/// 靠这几样让字认得出（CollageOverlays.place 里调，预览、导出、缩略图同一套）：
/// - 深浅不按整块字底下的平均亮度定：每个字形单独看底下（深字看偏暗的那头、浅字看偏亮的那头），取最不利的那个字形
///   还看得最清楚的深浅。一行横跨深浅交界（期号的「I」落在头发上、「2026」落在白袖子上）以前就整截没了。
/// - 候选位置也按字形看（字形框相对字块量一次，候选位置平移过去），挑每个字都清楚的地方。
/// - 还不够清楚（大字 < 3:1、小字 < 4.5:1）：沿字边落一圈很淡的光晕（浅字深晕、深字白晕），按差多少给。
/// - fade > 0 的字块（底部定死的一行主卖点）：一道平滑的底部压暗，只压到字看得清为止，字一律浅色。
/// - 要被读的字不小于 2.2%W：自动挑大小不往下缩；一行太长先自己缩（最多到 70%），再不行断成两行。
/// - 「 · 」隔开的几段里占位符没有值的那段不印（截图、去掉 EXIF 的照片不会印出「· F/ · S · ISO」）。
extension CollageOverlays {

    /// 要被读的字最小字号（短边比例）：R6 按小红书标签字号 24/1080 推的 2.2%W，1440 宽上 32 px。
    static let readableSize = 0.022
    /// 一行太长：先自己缩到原字号的这么多为止，还放不下就断成两行。
    static let shrinkBeforeWrap = 0.7
    /// 光晕、底部压暗之前，字和底下的对比度要到多少（WCAG 那种）：大字（≥ 0.04，约 3%H）3:1，小字 4.5:1。
    static func contrastTarget(_ size: Double) -> Double { size >= 0.04 ? 3 : 4.5 }
    /// 浅字、深字按多亮多暗算对比（和 contrast(_:light:) 同一对数：浅字不是纯白、深字不是纯黑）。
    static let lightInk = 0.9
    static let darkInk = 0.02
    /// 封面字栏的竖向范围（照片区高的比例）：R1 实测栏从 23–27%H 开始、到 67–82%H 结束。
    static let columnSpan = 0.2...0.82
    /// 栏顶想落的那一截（照片区高的比例，R1：23–27%H）：栏顶离它每远 10%H 加 columnTopPull（光罚出了 20–82% 的
    /// 范围不够：右栏衬线在 7232、7227 上从 47–52%H 开始，正落在没认出来的路人背上）。
    static let columnTop = 0.23...0.27
    static let columnTopPull = 1.6
    /// 字形底下压在人身上（主体 + 别的人）多少以内还算「不压人身上」：有这样的候选位置就只在它们里挑（同 hitsOccupied
    /// 那样当硬约束）。按字形量、不按字块外框量：左栏左对齐，外框右边那截空着、正好压着半透明的头纱（7221、7226 外框盖住
    /// 三成，字形只有 5%），按外框卡会把栏赶到最下面的亮栏杆上；袖子、头发、扇子上的那几处字形压着六成到九成。
    /// K1 final 2 起按「压得最多的那一行」量（Cover.worst）：一栏五行，最下面一行小字整个压在指尖上，按整栏平均只有一成多。
    static let bodyMax = 0.2
    /// 一行字形压在人身上超过这么多就算「碰到人」：候选代价照 occupiedCost 的样子加（碰到就 +3，再按压住多少 ×30），
    /// 左栏 / 右栏挑中的位置碰到人时也去另一边找一遍。
    static let peopleTouch = 0.05
    /// 多大的字按整体底色定深浅（主题字 Portrait、大引号）：横跨大半个照片宽的一个词，底下几处深色的缝不该决定它。
    static let displaySize = 0.1

    // MARK: - 文案整理

    private static let slotRegex = try! NSRegularExpression(pattern: "\\{([a-z_0-9]+)(\\|[^{}]*)?\\}")

    /// 摆位之前把字整理好：占位符缺值的段去掉；比 width（成品像素）宽的行先自己缩、再断成两行。竖排、转过的、
    /// 铺满宽度的行不动。
    static func cleanTypeText(_ text: CollageText, width: Double, short: Double, vars: [String: String]) -> CollageText {
        var out = text
        out.lines = text.lines.map { dropEmptySlots($0, vars: vars) }
        guard !text.vertical, !text.isRotated, width > 8, short > 0 else { return out }
        var lines: [CollageTextLine] = []
        for line in out.lines {
            lines += fitLine(line, width: width, short: short, vars: vars)
        }
        out.lines = lines
        return out
    }

    /// 「 · 」隔开的一段里有占位符没有值（没写默认值）：这一段整段去掉；整行都去掉了 = 空行（不画）。
    static func dropEmptySlots(_ line: CollageTextLine, vars: [String: String]) -> CollageTextLine {
        guard line.text.contains("{") else { return line }
        let parts = line.text.components(separatedBy: " · ")
        let kept = parts.filter { part in
            let ns = part as NSString
            for m in slotRegex.matches(in: part, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1))
                let hasDefault = m.range(at: 2).location != NSNotFound
                if !hasDefault, (vars[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
            }
            return true
        }
        guard kept.count != parts.count else { return line }
        var l = line
        l.text = kept.joined(separator: " · ")
        return l
    }

    /// 一行放不进 width：先整行按比例缩（不低于原字号 70%、不低于要读的字号）；还放不下就在最顺的地方断成两行，
    /// 两行一起缩到放得下（同样不低于要读的字号；再放不下交给整块的 fit）。
    private static func fitLine(_ line: CollageTextLine, width: Double, short: Double,
                                vars: [String: String]) -> [CollageTextLine] {
        guard !line.fitWidth, line.size > 0 else { return [line] }
        let s = CollageTypeset.lineString(line, vars: vars)
        guard !s.isEmpty else { return [line] }
        let w = lineWidth(line, short: short, vars: vars)
        guard w > width else { return [line] }
        let floor: Double = line.size >= readableSize ? readableSize : line.size
        let k: Double = width / w * 0.995
        if k >= shrinkBeforeWrap || s.count < 4 {
            var l = line
            l.size = max(floor, line.size * k)
            return [l]
        }
        guard let cut = breakIndex(s) else {
            var l = line
            l.size = max(floor, line.size * k)
            return [l]
        }
        // 断开的两行是照片里的真字（展开过的）：再展开一次也不变（只有带「{…}」的标题会被当成占位符）。
        var first = line
        first.text = String(s.prefix(cut)).trimmingCharacters(in: .whitespaces)
        first.textCase = .none
        var second = line
        second.text = String(s.dropFirst(cut)).trimmingCharacters(in: .whitespaces)
        second.textCase = .none
        let wide: Double = max(lineWidth(first, short: short, vars: vars), lineWidth(second, short: short, vars: vars))
        if wide > width {
            let k2: Double = width / wide * 0.995
            first.size = max(floor, line.size * k2)
            second.size = first.size
        }
        return [first, second]
    }

    private static func lineWidth(_ line: CollageTextLine, short: Double, vars: [String: String]) -> Double {
        var t = CollageText(lines: [line], vertical: false, alignH: .leading, alignV: .leading)
        t.lineSpacing = 0
        return Double(CollageTypeset.measure(t, short: short, vars: vars).width)
    }

    /// 在哪儿断成两行：两半尽量一样长；汉字之间都能断，逗号、顿号后面最好、「的」后面其次；西文只在空格断；
    /// 标点不放到第二行开头。断不开（一个长单词）= nil。
    static func breakIndex(_ s: String) -> Int? {
        let chars = Array(s)
        let n = chars.count
        guard n >= 2 else { return nil }
        let leadBan: Set<Character> = ["，", "、", "。", "；", "：", "！", "？", "）", "」", "』", ",", ".", ";", ":", "!", "?", ")", "·"]
        // 标点后面最顺（「三月，/ 春日庭院……」），「的」「之」后面其次；没有分词，别的地方只按两半一样长挑。
        let punct: Set<Character> = ["，", "、", "；", "：", "·", ","]
        let good: Set<Character> = ["，", "、", "；", "：", "·", " ", "的", "之", "与", "和", ","]
        func cjk(_ c: Character) -> Bool { c.unicodeScalars.contains { $0.properties.isIdeographic } }
        var best: (at: Int, cost: Double)?
        for i in 1..<n {
            let a = chars[i - 1]
            let b = chars[i]
            guard !leadBan.contains(b) else { continue }
            let latinWord = !cjk(a) && !cjk(b) && a != " " && b != " " && !good.contains(a)
            guard !latinWord else { continue }
            let half = Double(n) / 2
            var cost: Double = abs(Double(i) - half) / max(1, half)
            if punct.contains(a) { cost -= 0.6 } else if good.contains(a) { cost -= 0.3 }
            if best == nil || cost < best!.cost - 1e-9 { best = (i, cost) }
        }
        return best?.at
    }

    // MARK: - 按字形看清不清楚

    /// 一块字摆在某个位置时，每个字形底下的亮度和它要多少对比：候选位置挑、最后定深浅、光晕、底部压暗都用它。
    final class CleanType {
        let grid: Grid?
        let mapper: Mapper
        let look: CollageLook
        let strength: Double
        let matted: Bool
        let vars: [String: String]
        /// 这一格的主体蒙版（人物挡字、封面取景那一格 CollageCover 已经算好的；没有 = nil）：封面字躲开人身上的衣服。
        let subject: CollageMasks.Mask?
        /// 人脸框（照片坐标）：封面字离脸还要留一圈（脸框四边各外扩 15%），贴着脸边也不好看。
        let faces: [[Double]]
        /// 别的人（照片坐标框）：CollageCrop.Hints 的路人框（人体框全身 / 上半身、小脸往下估的肩膀）+ 主体蒙版那一次找到的人
        /// （CollageMasks.Mask.people：人体框、分块的人体姿态、对得上的前景实例）。按点落没落在任何一个框里量，同一个人
        /// 两边都报了也只算一次。
        let others: [[Double]]
        /// 封面字栏想落在的竖向范围（成品坐标；R1：栏从 23–27%H 开始、到 67–82%H 结束）。nil = 不管（不是左栏 / 右栏）。
        let span: ClosedRange<Double>?
        /// 栏顶想落的那一截（成品坐标，columnTop 换算的）和照片区的高：nil = 不管。
        let top: ClosedRange<Double>?
        let areaHeight: Double
        private var boxCache: [BoxKey: [(rect: CGRect, line: Int)]] = [:]

        /// 这一次摆位里的字形框缓存键（每个候选位置都查一次：要便宜，不拼字串）。
        private struct BoxKey: Hashable {
            var align: CollageAlign
            var short: Double
            var width: Double
            var height: Double
            var sizes: [Double]
        }

        /// 跨摆位、跨出图的字形框缓存键：同一份字（含对齐、字号）、同一个字号基准、同一个框、同一组占位符值。
        /// CoreText 排一遍字是摆位里最贵的一步（K1 final 2 起一栏要试三档大小 × 两边），预览每画一帧都要摆一遍。
        private struct GlyphKey: Hashable {
            var text: CollageText
            var short: Double
            var width: Double
            var height: Double
            var vars: [String: String]
        }

        private static let glyphLock = NSLock()
        private static var glyphCache: [GlyphKey: [(rect: CGRect, line: Int)]] = [:]

        init(grid: Grid?, mapper: Mapper, look: CollageLook, strength: Double, matted: Bool, vars: [String: String],
             subject: CollageMasks.Mask? = nil, faces: [[Double]] = [], bystanders: [[Double]] = [],
             column area: CGRect? = nil) {
            self.grid = grid
            self.mapper = mapper
            self.look = look
            self.strength = strength
            self.matted = matted
            self.vars = vars
            self.subject = subject
            self.faces = faces.filter(CollageCrop.isValidBox)
            self.others = (bystanders + (subject?.people ?? [])).filter(CollageCrop.isValidBox)
            self.span = area.map(CollageOverlays.columnRange)
            if let a = area {
                let h = Double(a.height)
                let lo: Double = Double(a.minY) + CollageOverlays.columnTop.lowerBound * h
                let hi: Double = Double(a.minY) + CollageOverlays.columnTop.upperBound * h
                self.top = lo...hi
                self.areaHeight = max(1, h)
            } else {
                self.top = nil
                self.areaHeight = 1
            }
        }

        /// 栏出了想落的竖向范围多少（成品像素换成范围高的比例）：每出 10% 加 2.5；栏顶离 23–27%H 每远 10%H 再加
        /// columnTopPull（栏贴着刊头下面开始，R1 的样子；越往下越容易落在路人、衣摆上）。
        func outOfSpan(_ r: CGRect) -> Double {
            guard let span else { return 0 }
            let h: Double = max(1, span.upperBound - span.lowerBound)
            let above: Double = max(0, span.lowerBound - Double(r.minY))
            let below: Double = max(0, Double(r.maxY) - span.upperBound)
            var c: Double = 25 * (above + below) / h
            if let top {
                let off: Double = max(0, top.lowerBound - Double(r.minY), Double(r.minY) - top.upperBound)
                c += 10 * CollageOverlays.columnTopPull * off / areaHeight
            }
            return c
        }

        /// 字块压没压到脸外面那一圈（脸框四边各外扩 15%；真压到脸 CollageOverlays.cost 另算，重得多）。
        func nearFace(_ r: CGRect) -> Bool {
            guard !faces.isEmpty, let box = mapper.toPhoto(r) else { return false }
            return faces.contains { f in
                let mx: Double = 0.15 * (f[2] - f[0])
                let my: Double = 0.15 * (f[3] - f[1])
                let ring = CGRect(x: f[0] - mx, y: f[1] - my, width: f[2] - f[0] + 2 * mx, height: f[3] - f[1] + 2 * my)
                return ring.intersects(box)
            }
        }

        /// 字块外框压没压到脸（脸框四边各外扩 10%）：干净的字当硬约束（同 hitsOccupied，place 里算进 open）。
        /// 字形压人代价加上之后，底栏两头、栏的上下都可能比「人身上」便宜的只剩脸边那一格（巨字开篇 7229 的开篇小字
        /// 换到右头、外框左边那截压进了脸框）：光靠 nearFace 的 +5 拦不住。
        func hitsFace(_ r: CGRect) -> Bool {
            guard !faces.isEmpty, let box = mapper.toPhoto(r) else { return false }
            return faces.contains { f in
                let mx: Double = 0.1 * (f[2] - f[0])
                let my: Double = 0.1 * (f[3] - f[1])
                let g = CGRect(x: f[0] - mx, y: f[1] - my, width: f[2] - f[0] + 2 * mx, height: f[3] - f[1] + 2 * my)
                return g.intersects(box)
            }
        }

        /// 照片坐标上一点压在人身上多少：主体按蒙版值（0…1，软边），别的人按框（在任何一个框里 = 1）。
        func person(u: Double, v: Double) -> (subject: Double, other: Double) {
            let s: Double = subject?.value(u: u, v: v) ?? 0
            let o: Double = others.contains { u >= $0[0] && u <= $0[2] && v >= $0[1] && v <= $0[3] } ? 1 : 0
            return (s, o)
        }

        /// 字块外框盖住人多少（0…1，框里 8×8 个点）：主体、别的人一个点两样都压只算一次（取大的）。
        func onPeople(_ r: CGRect) -> Double {
            guard subject != nil || !others.isEmpty, let box = mapper.toPhoto(r) else { return 0 }
            let n = 8
            var sum = 0.0
            for j in 0..<n {
                for i in 0..<n {
                    let u: Double = Double(box.minX) + (Double(i) + 0.5) / Double(n) * Double(box.width)
                    let v: Double = Double(box.minY) + (Double(j) + 0.5) / Double(n) * Double(box.height)
                    let p = person(u: u, v: v)
                    sum += max(p.subject, p.other)
                }
            }
            return sum / Double(n * n)
        }

        /// 字形压在人身上多少（0…1）：subject = 主体、others = 别的人、all = 两样合起来（一个点两样都压只算一次），
        /// 都按字形框面积加权；worst = 压得最多的那一行的 all。
        struct Cover {
            var subject = 0.0
            var others = 0.0
            var all = 0.0
            var worst = 0.0
        }

        /// 字形底下压在人身上多少（每个字形框里 3×3 个点、按字形框面积加权）：栏的外框里常有一半是空的
        /// （右对齐短行左边那截），按外框量，一栏有两行整个压在白袖子上也只算三四成。worst 按行量：一栏五行，
        /// 最下面一行小字整个压在指尖上（7227 的 VOL. 01），按整栏平均只有一成多。
        func inkOnPeople(_ boxes: [(rect: CGRect, line: Int)], at origin: CGPoint) -> Cover {
            guard subject != nil || !others.isEmpty else { return Cover() }
            var sum = (subject: 0.0, others: 0.0, all: 0.0)
            var weight = 0.0
            var lines: [Int: (all: Double, weight: Double)] = [:]
            for b in boxes {
                guard let box = mapper.toPhoto(b.rect.offsetBy(dx: origin.x, dy: origin.y)) else { continue }
                let area: Double = Double(b.rect.width * b.rect.height)
                guard area > 0 else { continue }
                var vs = 0.0
                var vo = 0.0
                var va = 0.0
                for j in 0..<3 {
                    for i in 0..<3 {
                        let u: Double = Double(box.minX) + (Double(i) + 0.5) / 3 * Double(box.width)
                        let w: Double = Double(box.minY) + (Double(j) + 0.5) / 3 * Double(box.height)
                        let p = person(u: u, v: w)
                        vs += p.subject
                        vo += p.other
                        va += max(p.subject, p.other)
                    }
                }
                sum.subject += area * vs / 9
                sum.others += area * vo / 9
                sum.all += area * va / 9
                weight += area
                let l = lines[b.line] ?? (0, 0)
                lines[b.line] = (l.all + area * va / 9, l.weight + area)
            }
            guard weight > 0 else { return Cover() }
            let worst: Double = lines.values.map { $0.weight > 0 ? $0.all / $0.weight : 0 }.max() ?? 0
            return Cover(subject: sum.subject / weight, others: sum.others / weight, all: sum.all / weight, worst: worst)
        }

        /// 字形压人的代价，照 occupiedCost 的样子：有一行碰到人（worst > peopleTouch）就 +3，再按压住多少（all）×30。
        static func peopleCost(_ c: Cover) -> Double {
            guard c.worst > CollageOverlays.peopleTouch else { return 0 }
            return 3 + 30 * c.all
        }

        /// 一个字形：底下偏暗那头（25%）、偏亮那头（75%）的亮度（sRGB 0…1，调过色调），中心的 y（成品坐标），要的对比。
        struct Spot {
            var lo: Double
            var hi: Double
            var y: Double
            var target: Double
            var line: Int
        }

        /// 字形框（相对字块左上角）：同一份字、同一个字号、同一个对齐只量一次（这一次摆位里按便宜的键查，
        /// 查不到再查跨摆位的缓存，最后才排字）。line = 非空行的序号。
        func boxes(_ text: CollageText, size: CGSize, short: Double) -> [(rect: CGRect, line: Int)] {
            let key = BoxKey(align: text.alignH, short: short, width: Double(size.width), height: Double(size.height),
                             sizes: text.lines.map(\.size))
            if let hit = boxCache[key] { return hit }
            let global = GlyphKey(text: text, short: short, width: Double(size.width), height: Double(size.height), vars: vars)
            Self.glyphLock.lock()
            let cached = Self.glyphCache[global]
            Self.glyphLock.unlock()
            if let cached {
                boxCache[key] = cached
                return cached
            }
            let frame = CGRect(origin: .zero, size: size)
            let out = CollageTypeset.glyphOutlines(text, in: frame, short: short, vars: vars).map { ($0.bounds, $0.line) }
            boxCache[key] = out
            Self.glyphLock.lock()
            // 只是缓存：攒多了整个清掉重来（一张封面几十份，换照片、改字才会涨）。
            if Self.glyphCache.count > 512 { Self.glyphCache.removeAll() }
            Self.glyphCache[global] = out
            Self.glyphLock.unlock()
            return out
        }

        /// 字块摆在 origin 时每个字形底下的情况。sizes = 每个非空行的实际字号（短边比例）。没有照片网格 = 空。
        func spots(_ boxes: [(rect: CGRect, line: Int)], at origin: CGPoint, sizes: [Double]) -> [Spot] {
            guard let grid else { return [] }
            var out: [Spot] = []
            out.reserveCapacity(boxes.count)
            for b in boxes {
                let r = b.rect.offsetBy(dx: origin.x, dy: origin.y)
                guard let box = mapper.toPhoto(r) else { continue }
                var values = cells(grid, in: box)
                guard !values.isEmpty else { continue }
                if !matted { values = values.map { CollageOverlays.graded($0, look: look, strength: strength) } }
                values.sort()
                let lo = values[min(values.count - 1, values.count / 4)]
                let hi = values[min(values.count - 1, (values.count * 3) / 4)]
                let size = sizes.indices.contains(b.line) ? sizes[b.line] : (sizes.last ?? 0.03)
                out.append(Spot(lo: lo, hi: hi, y: Double(r.midY), target: CollageOverlays.contrastTarget(size),
                                line: b.line))
            }
            return out
        }

        /// 字形底下的网格格子里（大的字形占的格子多，自然按面积算），浅字、深字各有多大一片对比够 3:1（调过色调）。
        /// 大字定深浅用。
        func legibleShare(_ text: CollageText, rect: CGRect, short: Double) -> (light: Double, dark: Double)? {
            guard let grid else { return nil }
            var all: [Double] = []
            for b in boxes(text, size: rect.size, short: short) {
                guard let box = mapper.toPhoto(b.rect.offsetBy(dx: rect.minX, dy: rect.minY)) else { continue }
                all += cells(grid, in: box)
            }
            guard !all.isEmpty else { return nil }
            var okLight = 0
            var okDark = 0
            for v in all {
                let g: Double = matted ? v : CollageOverlays.graded(v, look: look, strength: strength)
                let lb: Double = CollageLooks.linear(min(1, max(0, g)))
                if Self.ratio(lb, CollageOverlays.lightInk) >= 3 { okLight += 1 }
                if Self.ratio(lb, CollageOverlays.darkInk) >= 3 { okDark += 1 }
            }
            let n = Double(all.count)
            return (Double(okLight) / n, Double(okDark) / n)
        }

        /// 网格里落在 box（照片坐标）里的那些格的亮度。
        private func cells(_ grid: Grid, in box: CGRect) -> [Double] {
            let n = Grid.side
            let win = grid.window
            guard win.width > 0, win.height > 0 else { return [] }
            let u0 = Double((box.minX - win.minX) / win.width)
            let u1 = Double((box.maxX - win.minX) / win.width)
            let v0 = Double((box.minY - win.minY) / win.height)
            let v1 = Double((box.maxY - win.minY) / win.height)
            let i0 = max(0, min(n - 1, Int(u0 * Double(n))))
            let i1 = max(i0, min(n - 1, Int((u1 * Double(n)).rounded(.up)) - 1))
            let j0 = max(0, min(n - 1, Int(v0 * Double(n))))
            let j1 = max(j0, min(n - 1, Int((v1 * Double(n)).rounded(.up)) - 1))
            var out: [Double] = []
            out.reserveCapacity((i1 - i0 + 1) * (j1 - j0 + 1))
            for j in j0...j1 {
                for i in i0...i1 { out.append(grid.lum[j * n + i]) }
            }
            return out
        }

        /// 这种深浅下最不清楚的那个字形差多少（target − 对比度；≤ 0 = 每个字都够清楚）。没有字形 = nil。
        /// darken(y) = 那一高度上底部压暗了多少（0…1，浅字才有）。
        static func deficit(_ spots: [Spot], light: Bool, darken: (Double) -> Double = { _ in 0 }) -> Double? {
            guard !spots.isEmpty else { return nil }
            var worst = -Double.infinity
            for s in spots {
                let bg: Double = light ? s.hi : s.lo
                let lb: Double = CollageLooks.linear(min(1, max(0, bg))) * (1 - (light ? darken(s.y) : 0))
                let c: Double = ratio(lb, light ? CollageOverlays.lightInk : CollageOverlays.darkInk)
                worst = max(worst, s.target - c)
            }
            return worst
        }

        /// 这种深浅「大体上」行不行：差的字形平均差多少 + 最差那个的三成。挑深浅、挑位置按它 —— 一行里只有一两个字形
        /// 落在头发上，别为了它们把整行换成另一种深浅（那样其余的字全不清楚）；那一两个靠光晕救。
        static func score(_ spots: [Spot], light: Bool, darken: (Double) -> Double = { _ in 0 }) -> Double? {
            guard !spots.isEmpty else { return nil }
            var sum = 0.0
            var worst = 0.0
            for s in spots {
                let bg: Double = light ? s.hi : s.lo
                let lb: Double = CollageLooks.linear(min(1, max(0, bg))) * (1 - (light ? darken(s.y) : 0))
                let c: Double = ratio(lb, light ? CollageOverlays.lightInk : CollageOverlays.darkInk)
                let d: Double = max(0, s.target - c)
                sum += d
                worst = max(worst, d)
            }
            return sum / Double(spots.count) + 0.3 * worst
        }

        static func ratio(_ a: Double, _ b: Double) -> Double {
            (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// 候选位置的代价：字形大体上差得越多越贵（深浅定死的按定死的算，自动的按两种里好的那种）；压在人身上
        /// （主体和别的人：外框 ×4，字形照 occupiedCost 的样子 peopleCost）、贴着脸边、栏出了 R1 的竖向范围也贵。
        /// onBody = 压人最多的那一行字形有多少压在人身上（Cover.worst；place 拿它先筛「不压人身上」的候选）；
        /// people = 代价里压人的那几项（外框 ×4 + peopleCost）：place 拿「不算它时最便宜的位置碰不碰人」判断栏是不是被人挤开的。
        func cost(_ text: CollageText, size: CGSize, short: Double, at origin: CGPoint, tone: CollageTone,
                  sizes: [Double]) -> (cost: Double, onBody: Double, people: Double) {
            let glyphs = boxes(text, size: size, short: short)
            let s = spots(glyphs, at: origin, sizes: sizes)
            let dl = Self.score(s, light: true) ?? 0
            let dd = Self.score(s, light: false) ?? 0
            let d: Double
            switch tone {
            case .light: d = dl
            case .dark: d = dd
            case .auto: d = min(dl, dd)
            }
            let r = CGRect(origin: origin, size: size)
            let ink = inkOnPeople(glyphs, at: origin)
            let people: Double = 4 * onPeople(r) + Self.peopleCost(ink)
            let body: Double = people + (nearFace(r) ? 5 : 0) + outOfSpan(r)
            return (6 * min(1, d / 2) + body, ink.worst, people)
        }

        /// 最后定下来的：深浅、光晕多浓、底部压暗、每一行字形底下最不利的亮度（强调色按它挑）、
        /// 大体上还差多少（score：统一深浅比较两遍用）。
        struct Verdict {
            var light: Bool
            var glow: Double
            var fade: CollageOverlays.Fade?
            var deficit: Double
            /// 每个非空行：浅字看的最亮、深字看的最暗（sRGB 0…1）。
            var worstLum: [Int: Double]
        }

        func judge(_ text: CollageText, rect: CGRect, short: Double, tone: CollageTone, fade: Double,
                   area: CGRect, sizes: [Double]) -> Verdict? {
            let s = spots(boxes(text, size: rect.size, short: short), at: rect.origin, sizes: sizes)
            guard !s.isEmpty else { return nil }
            var light: Bool
            var shade: CollageOverlays.Fade?
            if fade > 0 {
                // 底部压暗：从字块上面一个字块高的地方开始，到字块底边压到最深，再往下一直到照片区底边都这么深。
                light = true
                let from: Double = Double(rect.minY) - 1.2 * Double(rect.height)
                let to: Double = Double(rect.maxY)
                var need = 0.0
                for p in s {
                    let lb: Double = CollageLooks.linear(min(1, max(0, p.hi)))
                    let allowed: Double = (CollageOverlays.lightInk + 0.05) / p.target - 0.05
                    guard lb > allowed else { continue }
                    let want: Double = 1 - allowed / lb
                    let at: Double = Fade.profile(p.y, from: from, to: to)
                    need = max(need, want / max(0.05, at))
                }
                let alpha: Double = min(fade, need)
                if alpha > 0.02 { shade = Fade(alpha: alpha, from: from, to: to, bottom: Double(area.maxY)) }
            } else {
                switch tone {
                case .light: light = true
                case .dark: light = false
                case .auto:
                    let dl = Self.score(s, light: true) ?? 0
                    let dd = Self.score(s, light: false) ?? 0
                    light = dl <= dd
                    // 大字（主题字 Portrait 横跨七成照片宽）：按字形底下有多大一片看得清定 —— 每一格底下浅字、深字各够不够
                    // 3:1，数够的格子（按面积），多出一成以上的那种赢。差不多（7227：亮石头栏杆和中间深色的裙子各一半）
                    // 用深字：深字配白晕是轻轻托一下，白字配深晕就成了描边字。score（几处深缝、亮缝说了算）不再管大字。
                    if (sizes.max() ?? 0) >= CollageOverlays.displaySize, let share = legibleShare(text, rect: rect, short: short) {
                        light = share.light - share.dark >= 0.1
                    }
                }
            }
            let darken: (Double) -> Double = { y in shade?.alpha(at: y) ?? 0 }
            // 光晕按最差的那个字形给（整行一起落：深晕在深底上、白晕在白底上本来就看不出，只在缺的地方显）。
            let d = Self.deficit(s, light: light, darken: darken) ?? 0
            let glow: Double = min(1, max(0, d / 2.5))
            let overall = Self.score(s, light: light, darken: darken) ?? 0
            var worst: [Int: Double] = [:]
            for p in s {
                let bg: Double = light ? p.hi : p.lo
                if let w = worst[p.line] {
                    worst[p.line] = light ? max(w, bg) : min(w, bg)
                } else {
                    worst[p.line] = bg
                }
            }
            return Verdict(light: light, glow: glow, fade: shade, deficit: overall, worstLum: worst)
        }
    }

    /// 光晕（干净的字看不清时）：沿每个字形描一圈和字号成比例的粗边（浅字深晕、深字白晕），再羽化，画在字下面。
    /// 用投影做不出来：小字的笔画只有两三个像素，模糊半径一大投影就淡没了。整块一起画（透明图层里叠，不会越叠越浓）；
    /// 深晕落在深底上、白晕落在白底上本来就看不出，只在缺对比的那几个字形周围显出来。short = 这次渲染的字号基准。
    static func drawGlow(_ p: Placement, in rect: CGRect, ctx: CGContext, short: Double, vars: [String: String]) {
        guard p.glow > 0.02 else { return }
        let glyphs = CollageTypeset.glyphOutlines(p.text, in: rect, short: short, vars: vars)
        guard !glyphs.isEmpty else { return }
        let sizes = CollageTypeset.expandedLines(p.text, vars: vars).map { $0.line.size * short }
        let tint: CGFloat = p.light ? 0 : 1
        let alpha: Double = (p.light ? 0.3 : 0.3) + 0.35 * p.glow
        let color = CGColor(srgbRed: tint, green: tint, blue: tint, alpha: min(0.85, alpha))
        let typical: Double = sizes.isEmpty ? 20 : sizes.sorted()[sizes.count / 2]
        // 描边、羽化都跟字号走，但大字有上限（主题字、巨字描一圈几十像素的边就成了贴纸字）：描边最多 0.4% 短边、
        // 羽化最多 1.2% 短边（short 是字号基准 ≈ 画布短边）。
        let maxStroke: Double = short * 0.004
        let blur: Double = min(typical * (0.18 + 0.12 * p.glow), short * 0.012)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: CGFloat(blur), color: color)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineJoin(.round)
        for line in Set(glyphs.map(\.line)).sorted() {
            let px: Double = sizes.indices.contains(line) ? sizes[line] : typical
            let path = CGMutablePath()
            for g in glyphs where g.line == line { path.addPath(g.path) }
            ctx.setLineWidth(CGFloat(min(maxStroke, px * (0.06 + 0.1 * p.glow))))
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 底部压暗：from 处透明，平滑地（smoothstep）到 to 处最深 alpha，再往下到 bottom 一直这么深。成品坐标。
    struct Fade: Hashable {
        var alpha: Double
        var from: Double
        var to: Double
        var bottom: Double

        static func profile(_ y: Double, from: Double, to: Double) -> Double {
            guard to > from else { return y >= to ? 1 : 0 }
            let t: Double = min(1, max(0, (y - from) / (to - from)))
            return t * t * (3 - 2 * t)
        }

        func alpha(at y: Double) -> Double { alpha * Fade.profile(y, from: from, to: to) }
    }

    /// 封面字栏的竖向范围换成成品坐标。
    static func columnRange(_ area: CGRect) -> ClosedRange<Double> {
        let top: Double = Double(area.minY) + columnSpan.lowerBound * Double(area.height)
        let bottom: Double = Double(area.minY) + columnSpan.upperBound * Double(area.height)
        return top...bottom
    }

    /// 非空行各自的实际字号（短边比例，按 fit 缩过的倍数）：和 glyphOutlines 的行号一一对应。
    static func lineSizes(_ text: CollageText, scale: Double, vars: [String: String]) -> [Double] {
        CollageTypeset.expandedLines(text, vars: vars).map { $0.line.size * scale }
    }

    /// 第 i 行（text.lines 的下标）是第几个非空行；空行 = nil。
    static func runIndex(_ text: CollageText, line i: Int, vars: [String: String]) -> Int? {
        guard text.lines.indices.contains(i),
              !CollageTypeset.lineString(text.lines[i], vars: vars).isEmpty else { return nil }
        return text.lines[..<i].filter { !CollageTypeset.lineString($0, vars: vars).isEmpty }.count
    }

    /// 按行缩一档（干净的字的自动大小，整块缩会把最小那行缩破要读的字号时）：每行 × s，不低于要读的字号
    /// （原来就比它小的行不动）；铺满宽度的行不动。
    static func shrunkLines(_ text: CollageText, by s: Double) -> CollageText {
        var t = text
        t.lines = text.lines.map { line in
            guard !line.fitWidth, line.size > 0 else { return line }
            var l = line
            let floor: Double = min(line.size, readableSize)
            l.size = max(floor, line.size * s)
            return l
        }
        return t
    }

    /// 干净的字的最小字号（要读的那些）：自动挑大小只在不把它缩到 readableSize 以下的几档里挑。
    static func smallestLine(_ text: CollageText, vars: [String: String]) -> Double {
        CollageTypeset.expandedLines(text, vars: vars).filter { !$0.line.fitWidth }.map(\.line.size).min() ?? 1
    }
}

extension CollageCrop {
    /// 引语单图（封面景别、上方没有刊头）：脸中心在窗口宽的 35–65% 就不动；不在（窄高的格子、脸贴着照片边，
    /// 窗口顶到照片边挪不过去）就以 1.1、1.2 … 1.6 倍一档档拉近，每档先把脸挪到正中再夹回照片里（连同出血外延），
    /// 第一档进了 35–65%、不切脸、不超过放大上限的就用它；都不行用最接近的那档（不超放大上限、不切脸）。
    static func faceCentred(_ win: Window, photo: CollagePhotoRef, face f: [Double], reserve r: Reserve,
                            drawn: CGRect, bystanders: [[Double]]) -> Window {
        guard win.w > 0, win.h > 0 else { return win }
        let fc: Double = (f[0] + f[2]) / 2
        let fy: Double = (f[1] + f[3]) / 2
        func at(_ w: Window) -> Double { (fc - w.x) / w.w }
        let band = 0.35...0.65
        guard !band.contains(at(win)) else { return win }
        let safe = safeRegion(photo.faces)
        let v: Double = (fy - win.y) / win.h
        var best = win
        var bestMiss: Double = abs(at(win) - 0.5)
        for step in 0...6 {
            let zoom: Double = 1 + 0.1 * Double(step)
            var w = win
            w.w = win.w / zoom
            w.h = win.h / zoom
            let loX: Double = r.left * w.w
            let hiX: Double = max(loX, 1 - w.w - r.right * w.w)
            let loY: Double = r.top * w.h
            let hiY: Double = max(loY, 1 - w.h - r.bottom * w.h)
            w.x = min(max(fc - w.w / 2, loX), hiX)
            w.y = min(max(fy - v * w.h, loY), hiY)
            if let s = safe, !inside(w.rect, s) { break }
            if upscale(photo: photo, window: w, drawn: drawn) > CollageStore.upscaleLimit + 1e-6 { break }
            let miss: Double = abs(at(w) - 0.5)
            if miss < bestMiss - 1e-9 {
                best = w
                bestMiss = miss
            }
            if band.contains(at(w)) { break }
        }
        best.cutsFace = win.cutsFace || (safe.map { !inside(best.rect, $0) } ?? false)
        best.hitsBystander = overlap(best.rect, bystanders) > 0.0005
        return best
    }

    private static func inside(_ outer: CGRect, _ inner: CGRect) -> Bool {
        let e: CGFloat = 1e-6
        return inner.minX >= outer.minX - e && inner.maxX <= outer.maxX + e
            && inner.minY >= outer.minY - e && inner.maxY <= outer.maxY + e
    }
}
