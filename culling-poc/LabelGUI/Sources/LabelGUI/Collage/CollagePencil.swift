import Foundation
import CoreGraphics

/// 油性笔记号（印样上圈片、打叉、点一下、画裁切线）。手绘感照 R2 §7（参考 rough.js 的默认值，换成相对尺寸）：
/// - 圈：一笔画、不闭合的螺旋：起笔在正上方 ±0.5 rad，逆时针（右手画圈的习惯）转一圈再多走 15–40°，
///   收笔半径比起笔大 3–8%；至少 9 个控制点（越大越多），每点半径随机 ±5%、位置抖 ±1.2% 的半轴，整体歪 ±6°；
/// - 线宽 = 被圈那一帧高度的 4–6%（圈的外框高 ≈ 帧高 × 1.42，所以取外框高的 3.5%）；起笔从 60% 渐粗到 100%，
///   收笔收到 40%；
/// - 蜡质断续：笔迹上 10–25% 的细碎空隙（不等距的小点、短擦痕，偏向笔迹两边，中线附近几乎是实的；疏密跟着
///   一阵重一阵轻的笔压走，见 skips(along:)），整体不透明度 0.9；
/// - 种子：同一个记号每次画出来一样（印样用 hash(照片 id + 页号)，贴纸用图层种子），无头出图能逐像素比。
///
/// 只画在调用方给的坐标系里（左上原点）：贴纸在图层局部坐标里画，印样在所有帧画完之后单独一遍画（圈要压到片边、邻帧）。
enum CollagePencil {

    /// 记号的种子：照片 id + 页号（R2 §7）。印样那一遍用它；贴纸用 CollageItems 自己的种子。
    static func seed(_ text: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in text.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return h
    }

    /// 默认线宽：按记号外框的大小（圈的外框比帧大 1.42 倍，叉、裁切线的外框就是那一帧）。
    static func defaultLineWidth(_ mark: CollagePencilMark, in rect: CGRect) -> CGFloat {
        let h = min(rect.height, rect.width * 1.2)
        switch mark {
        case .circle: return h * 0.035
        case .cross: return h * 0.05
        case .dot: return h * 0.08
        case .cropLine: return h * 0.032
        }
    }

    /// 在 rect 里画一个记号。lineWidth = nil 按大小定。
    static func draw(_ mark: CollagePencilMark, in rect: CGRect, color: CollageColor, seed: UInt64, ctx: CGContext,
                     lineWidth: CGFloat? = nil) {
        guard rect.width > 1, rect.height > 1 else { return }
        let lw = max(0.5, lineWidth ?? defaultLineWidth(mark, in: rect))
        let (strokes, blob) = shape(mark, in: rect, seed: seed)
        // 笔身、两个圆头各填一次：合成一条路径的话，圆头和笔身的绕向正好相反（笔身多边形的绕向和笔往哪走无关），
        // 非零规则下重叠那半个圆互相抵消，起笔、收笔里面各漏一个洞。
        let bodies: [CGPath] = strokes.flatMap { taperedPaths($0, width: lw) }
        let blobPath = blob.map { closedSpline($0) }
        var bounds = CGRect.null
        for path in bodies { bounds = bounds.union(path.boundingBoxOfPath) }
        if let blobPath { bounds = bounds.union(blobPath.boundingBoxOfPath) }
        guard !bounds.isNull else { return }
        ctx.saveGState()
        // 一个透明层：笔画之间、笔身和圆头之间的重叠不叠深（层里都是不透明的同一个颜色，0.9 整层最后才乘），
        // 蜡质空隙从整层里挖。层只开笔迹那一块（外扩 2 个线宽，空隙的毛边也在里面）：不给范围 CG 按整个裁切区
        // 开一层（A4 导出一层 36 MB），合回去时整张画布都要过一遍。
        ctx.setAlpha(0.9)
        ctx.beginTransparencyLayer(in: bounds.insetBy(dx: -lw * 2, dy: -lw * 2), auxiliaryInfo: nil)
        ctx.setFillColor(color.cgColor)
        for path in bodies {
            ctx.addPath(path)
            ctx.fillPath()
        }
        if let blobPath {
            ctx.addPath(blobPath)
            ctx.fillPath()
        }
        // 蜡质断续：顺着笔走向的细碎空隙（油性笔在纸面纹理上挂不住蜡的地方），从整层里挖掉。
        var gaps = SeededRandom(seed: seed ^ 0x9e3779b9)
        // 挖的颜色只要 alpha：一个不透明的黑，每粒挖多深用整体不透明度（setAlpha）给，深浅只有 4 档（skips(along:)）。
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineCap(.round)
        for points in strokes { skips(along: points, width: lw, rng: &gaps, ctx: ctx) }
        if blob != nil, !bounds.isNull { skips(across: bounds, angle: -0.5, width: lw, rng: &gaps, ctx: ctx) }
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 笔迹占的地方（rect 同一坐标系）：每一笔每 4 个点一小段，取外接框再外扩半个线宽（圆头、渐粗渐细都在里面）；
    /// 点是实心一团，取整团的外接框。整页水印在留白带里挑哪一头时躲的是它：圈、叉里面是空的，签名可以落在圈里，
    /// 能不压笔迹就不压（整页层画在图层之后，压上去就是签名盖着红笔）。
    static func inkBoxes(_ mark: CollagePencilMark, in rect: CGRect, seed: UInt64,
                         lineWidth: CGFloat? = nil) -> [CGRect] {
        guard rect.width > 1, rect.height > 1 else { return [] }
        let lw = max(0.5, lineWidth ?? defaultLineWidth(mark, in: rect))
        let (strokes, blob) = shape(mark, in: rect, seed: seed)
        var out: [CGRect] = []
        for points in strokes where points.count >= 2 {
            for start in stride(from: 0, to: points.count - 1, by: 4) {
                let piece = points[start...min(points.count - 1, start + 4)]
                let xs = piece.map(\.x)
                let ys = piece.map(\.y)
                let x0: CGFloat = (xs.min() ?? 0) - lw / 2
                let y0: CGFloat = (ys.min() ?? 0) - lw / 2
                let w: CGFloat = (xs.max() ?? 0) - (xs.min() ?? 0) + lw
                let h: CGFloat = (ys.max() ?? 0) - (ys.min() ?? 0) + lw
                out.append(CGRect(x: x0, y: y0, width: w, height: h))
            }
        }
        if let blob { out.append(closedSpline(blob).boundingBoxOfPath) }
        return out
    }

    // MARK: - 形状

    /// 一个记号的中心线（几笔）和点的那一团：draw、inkBoxes 共用，同一个种子出同一组点。
    private static func shape(_ mark: CollagePencilMark, in rect: CGRect,
                              seed: UInt64) -> (strokes: [[CGPoint]], blob: [CGPoint]?) {
        var rng = SeededRandom(seed: seed)
        switch mark {
        case .circle: return ([circleStroke(rect, rng: &rng)], nil)
        case .cross: return (crossStrokes(rect, rng: &rng), nil)
        case .dot: return ([], dotBlob(rect, rng: &rng))
        case .cropLine: return (cropStrokes(rect, rng: &rng), nil)
        }
    }

    private static func unit(_ rng: inout SeededRandom) -> CGFloat { CGFloat(CollageItems.unit(&rng)) }

    /// −1…1
    private static func signed(_ rng: inout SeededRandom) -> CGFloat { unit(&rng) * 2 - 1 }

    /// 圈：一笔、不闭合的螺旋。外框 rect 就是椭圆的外接框（收笔那一圈略大一点，会冲出框一点点）。
    static func circleStroke(_ rect: CGRect, rng: inout SeededRandom) -> [CGPoint] {
        let cx: CGFloat = rect.midX + signed(&rng) * rect.width * 0.015
        let cy: CGFloat = rect.midY + signed(&rng) * rect.height * 0.015
        let rx: CGFloat = rect.width / 2 * 0.95
        let ry: CGFloat = rect.height / 2 * 0.95
        let tilt: CGFloat = signed(&rng) * 6 * .pi / 180
        let start: CGFloat = -.pi / 2 + signed(&rng) * 0.5
        let overshoot: CGFloat = (15 + unit(&rng) * 25) * .pi / 180
        let growth: CGFloat = 0.03 + unit(&rng) * 0.05
        let sweep: CGFloat = 2 * .pi + overshoot
        let size: CGFloat = max(rx, ry)
        let count = min(16, max(9, 9 + Int(size / 160)))
        let steps = count + Int((overshoot / (2 * .pi)) * CGFloat(count)) + 1
        let jitter: CGFloat = ry * 0.012
        var control: [CGPoint] = []
        for k in 0...steps {
            let t: CGFloat = CGFloat(k) / CGFloat(steps)
            // 逆时针（左上原点里角度往小走）。
            let a: CGFloat = start - sweep * t
            let grow: CGFloat = 1 + growth * t
            let wobble: CGFloat = 1 + signed(&rng) * 0.05 * (k == 0 ? 0.3 : 1)
            let r: CGFloat = grow * wobble
            let lx: CGFloat = cos(a) * rx * r + signed(&rng) * jitter
            let ly: CGFloat = sin(a) * ry * r + signed(&rng) * jitter
            let x: CGFloat = cx + lx * cos(tilt) - ly * sin(tilt)
            let y: CGFloat = cy + lx * sin(tilt) + ly * cos(tilt)
            control.append(CGPoint(x: x, y: y))
        }
        return spline(control, samples: 10)
    }

    /// 叉：两笔，左上→右下、右上→左下，每笔略弯、端点不齐。
    static func crossStrokes(_ rect: CGRect, rng: inout SeededRandom) -> [[CGPoint]] {
        let inset: CGFloat = 0.08
        func corner(_ fx: CGFloat, _ fy: CGFloat, _ rng: inout SeededRandom) -> CGPoint {
            let x: CGFloat = rect.minX + rect.width * (fx + signed(&rng) * 0.035)
            let y: CGFloat = rect.minY + rect.height * (fy + signed(&rng) * 0.035)
            return CGPoint(x: x, y: y)
        }
        let a0 = corner(inset, inset, &rng)
        let a1 = corner(1 - inset, 1 - inset, &rng)
        let b0 = corner(1 - inset, inset, &rng)
        let b1 = corner(inset, 1 - inset, &rng)
        return [bowedLine(a0, a1, rng: &rng), bowedLine(b0, b1, rng: &rng)]
    }

    /// 裁切线：四条边各一笔，冲过角 5–9%，每条略斜、略弯（先上后右、下、左）。
    static func cropStrokes(_ rect: CGRect, rng: inout SeededRandom) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        for i in 0..<4 {
            let p0 = corners[i]
            let p1 = corners[(i + 1) % 4]
            let dx: CGFloat = p1.x - p0.x
            let dy: CGFloat = p1.y - p0.y
            let o0: CGFloat = 0.05 + unit(&rng) * 0.04
            let o1: CGFloat = 0.05 + unit(&rng) * 0.04
            let nx: CGFloat = -dy
            let ny: CGFloat = dx
            let skew: CGFloat = signed(&rng) * 0.012
            let s = CGPoint(x: p0.x - dx * o0 + nx * skew, y: p0.y - dy * o0 + ny * skew)
            let e = CGPoint(x: p1.x + dx * o1 - nx * skew, y: p1.y + dy * o1 - ny * skew)
            out.append(bowedLine(s, e, rng: &rng))
        }
        return out
    }

    /// 点：不太圆的一小团（闭合样条，填满）。
    static func dotBlob(_ rect: CGRect, rng: inout SeededRandom) -> [CGPoint] {
        let r: CGFloat = min(rect.width, rect.height) / 2 * 0.9
        let cx: CGFloat = rect.midX
        let cy: CGFloat = rect.midY
        let start: CGFloat = unit(&rng) * 2 * .pi
        var points: [CGPoint] = []
        for k in 0..<8 {
            let a: CGFloat = start + CGFloat(k) / 8 * 2 * .pi
            let rr: CGFloat = r * (1 + signed(&rng) * 0.08)
            points.append(CGPoint(x: cx + cos(a) * rr, y: cy + sin(a) * rr * 0.92))
        }
        return points
    }

    /// 一笔直线：中间往一侧鼓 ±3% 长度，沿途 5 个控制点各抖一点。
    private static func bowedLine(_ a: CGPoint, _ b: CGPoint, rng: inout SeededRandom) -> [CGPoint] {
        let dx: CGFloat = b.x - a.x
        let dy: CGFloat = b.y - a.y
        let len: CGFloat = max(1, hypot(dx, dy))
        let nx: CGFloat = -dy / len
        let ny: CGFloat = dx / len
        let bow: CGFloat = signed(&rng) * 0.03 * len
        var control: [CGPoint] = []
        for k in 0..<5 {
            let t: CGFloat = CGFloat(k) / 4
            let arc: CGFloat = 4 * t * (1 - t) * bow
            let wobble: CGFloat = (k == 0 || k == 4) ? 0 : signed(&rng) * 0.006 * len
            let x: CGFloat = a.x + dx * t + nx * (arc + wobble)
            let y: CGFloat = a.y + dy * t + ny * (arc + wobble)
            control.append(CGPoint(x: x, y: y))
        }
        return spline(control, samples: 12)
    }

    // MARK: - 笔画

    /// Catmull-Rom 样条：过每个控制点，两头重复端点。
    static func spline(_ p: [CGPoint], samples: Int) -> [CGPoint] {
        guard p.count >= 2 else { return p }
        var out: [CGPoint] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)]
            let p1 = p[i]
            let p2 = p[i + 1]
            let p3 = p[min(p.count - 1, i + 2)]
            for s in 0..<samples {
                let t: CGFloat = CGFloat(s) / CGFloat(samples)
                out.append(catmull(p0, p1, p2, p3, t))
            }
        }
        out.append(p[p.count - 1])
        return out
    }

    private static func catmull(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2: CGFloat = t * t
        let t3: CGFloat = t2 * t
        let a: CGFloat = -t3 + 2 * t2 - t
        let b: CGFloat = 3 * t3 - 5 * t2 + 2
        let c: CGFloat = -3 * t3 + 4 * t2 + t
        let d: CGFloat = t3 - t2
        let x: CGFloat = (a * p0.x + b * p1.x + c * p2.x + d * p3.x) / 2
        let y: CGFloat = (a * p0.y + b * p1.y + c * p2.y + d * p3.y) / 2
        return CGPoint(x: x, y: y)
    }

    /// 闭合的 Catmull-Rom（点的那一团）。
    private static func closedSpline(_ p: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        let n = p.count
        guard n >= 3 else { return path }
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n]
            let p1 = p[i]
            let p2 = p[(i + 1) % n]
            let p3 = p[(i + 2) % n]
            for s in 0..<8 {
                let pt = catmull(p0, p1, p2, p3, CGFloat(s) / 8)
                if i == 0, s == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        path.closeSubpath()
        return path
    }

    /// 笔画宽度沿途：起笔 60% → 100%（前 15%），收笔 100% → 40%（后 20%）。
    static func widthProfile(_ t: CGFloat) -> CGFloat {
        if t < 0.15 {
            let u: CGFloat = t / 0.15
            let s: CGFloat = u * u * (3 - 2 * u)
            return 0.6 + 0.4 * s
        }
        if t > 0.8 {
            let u: CGFloat = (t - 0.8) / 0.2
            return 1 - 0.6 * u
        }
        return 1
    }

    /// 一条中心线按宽度轮廓外扩成填充多边形（CG 的描边是等宽的，渐粗渐细只能自己画），两头圆头。
    /// 返回笔身、起笔圆头、收笔圆头三条路径，要分开填（见 draw：合成一条的话非零规则下圆头和笔身互相抵消）。
    static func taperedPaths(_ points: [CGPoint], width: CGFloat) -> [CGPath] {
        let path = CGMutablePath()
        let n = points.count
        guard n >= 2 else { return [] }
        // 沿途累计长度 → t（按长度算宽度，控制点疏密不影响粗细）。
        var acc: [CGFloat] = [0]
        for i in 1..<n { acc.append(acc[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = max(1e-3, acc[n - 1])
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        var halves: [CGFloat] = []
        for i in 0..<n {
            let a = points[max(0, i - 1)]
            let b = points[min(n - 1, i + 1)]
            let dx: CGFloat = b.x - a.x
            let dy: CGFloat = b.y - a.y
            let len: CGFloat = max(1e-4, hypot(dx, dy))
            let half: CGFloat = width * widthProfile(acc[i] / total) / 2
            let nx: CGFloat = -dy / len * half
            let ny: CGFloat = dx / len * half
            left.append(CGPoint(x: points[i].x + nx, y: points[i].y + ny))
            right.append(CGPoint(x: points[i].x - nx, y: points[i].y - ny))
            halves.append(half)
        }
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        // 圆头：两端各一个圆（同一透明层里各填一次，重叠不叠深）。
        let h0 = halves[0]
        let h1 = halves[n - 1]
        let head = CGPath(ellipseIn: CGRect(x: points[0].x - h0, y: points[0].y - h0, width: h0 * 2, height: h0 * 2),
                          transform: nil)
        let tail = CGPath(ellipseIn: CGRect(x: points[n - 1].x - h1, y: points[n - 1].y - h1, width: h1 * 2,
                                            height: h1 * 2), transform: nil)
        return [path, head, tail]
    }

    /// 一笔上的蜡质空隙（R2 §7：按相纸颗粒做断续，留 10–25% 的高频空隙）。油性笔在纸面纹理的凸起上挂不住蜡：
    /// 空的是一粒粒小点、短擦痕，多在笔迹两边（压力小），中线附近笔压最重、几乎是实的 —— 以前那种顺着笔走向、
    /// 等距排的长细条，100% 下连成笔迹中间一条虚线，像矢量描边（R2 §10 第 7 条）。
    /// 空隙的疏密不是一路一样的：手上的力一阵重一阵轻，蜡厚的一段几乎是实的，发干的一段空得多、啃得深，偶尔还
    /// 擦出一道顺笔走向的短白痕（干湿见 Dryness）。只按随机间隔撒、疏密处处一样的话，放大看就是一串排得很匀的
    /// 小缺口，还是像一条虚线。所以：
    /// - 沿弧长按随机间隔（指数分布）落一粒，平均间隔 = 0.25 个线宽 ÷（0.35 + 1.6 × 干湿）：实的段落 0.7 个线宽一粒，
    ///   最干的地方 0.13 个线宽一粒；
    /// - 边上啃掉的一口（中心在离中线 80%–125% 个半宽，一半在笔迹外：毛边）占七成到四成（越干越少），其余是笔迹
    ///   里面的细小麻点（离中线 20%–60/80% 个半宽，越干越往里）；中线上不落；
    /// - 毛边长 0.15–0.6 个线宽、粗 0.08–0.24；麻点长 0.06–0.24、粗 0.05–0.13；都再乘 0.7–1.3（越干越大）；
    ///   方向顺着笔走向再随机歪 ±35°；
    /// - 发干的地方（干湿 > 0.7）偶尔一道擦痕：长 0.8–2.4 个线宽、粗 0.05–0.1，离中线 35%–70% 个半宽，顺着笔走向；
    /// - 每粒挖掉 55–100%（4 档；越干越深），收笔渐细的那截（宽度不到 75%）空隙更少、更短。挖掉的面积约 10–20%。
    private static func skips(along points: [CGPoint], width lw: CGFloat, rng: inout SeededRandom, ctx: CGContext) {
        let n = points.count
        guard n >= 2 else { return }
        var acc: [CGFloat] = [0]
        for i in 1..<n { acc.append(acc[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = acc[n - 1]
        guard total > lw else { return }
        let dryness = Dryness(length: total, lineWidth: lw, rng: &rng)
        let step: CGFloat = lw * 0.25
        var d: CGFloat = step * unit(&rng)
        var i = 1
        while d < total {
            while i < n - 1, acc[i] < d { i += 1 }
            let a = points[i - 1]
            let b = points[i]
            let seg: CGFloat = max(1e-4, acc[i] - acc[i - 1])
            let f: CGFloat = (d - acc[i - 1]) / seg
            let dx: CGFloat = (b.x - a.x) / seg
            let dy: CGFloat = (b.y - a.y) / seg
            let profile: CGFloat = widthProfile(d / total)
            let dry: CGFloat = dryness.at(d)
            let edgeShare: CGFloat = 0.7 - 0.3 * dry
            let edge: Bool = unit(&rng) < edgeShare
            let side: CGFloat = unit(&rng) < 0.5 ? -1 : 1
            let innerReach: CGFloat = 0.2 + (0.4 + 0.2 * dry) * unit(&rng)
            let reach: CGFloat = edge ? 0.8 + 0.45 * unit(&rng) : innerReach
            let turn: CGFloat = signed(&rng) * 0.6
            let grow: CGFloat = 0.7 + 0.6 * dry
            let lenScale: CGFloat = (edge ? 0.15 + unit(&rng) * 0.45 : 0.06 + unit(&rng) * 0.18) * grow
            let thickScale: CGFloat = (edge ? 0.08 + unit(&rng) * 0.16 : 0.05 + unit(&rng) * 0.08) * grow
            // 挖多深只取 4 档（0.55 / 0.7 / 0.85 / 1）：每粒一个随机透明度的话，一个圈就用掉几百种不同的透明度，
            // CG 在同一进程里另一条线程上「整块同一个透明度」的填充（软边、投影、带 alpha 的字）会被带坏几个像素、
            // 每次坏的不一样（S4b 第 2 轮实测：另一条线程 5 种以内没事，9 种以上必坏）。编辑之后后台预览和导出
            // 同时在画，同一页导出几次就对不上。越干挖得越深（档位往上挪，还是这 4 档）。
            let depthLevel: CGFloat = min(3, (unit(&rng) * 4 + dry).rounded(.down))
            let depth: CGFloat = 0.55 + 0.15 * depthLevel
            let keep: Bool = profile >= 0.75 || unit(&rng) < profile
            let streak: Bool = dry > 0.7 && unit(&rng) < (dry - 0.7) * 0.6
            if keep {
                let half: CGFloat = lw * profile / 2
                let px: CGFloat = a.x + (b.x - a.x) * f
                let py: CGFloat = a.y + (b.y - a.y) * f
                let off: CGFloat = side * half * reach
                let len: CGFloat = lw * lenScale * (0.5 + 0.5 * profile)
                let thick: CGFloat = lw * thickScale * (0.6 + 0.4 * profile)
                let cx: CGFloat = px - dy * off
                let cy: CGFloat = py + dx * off
                let ux: CGFloat = dx * cos(turn) - dy * sin(turn)
                let uy: CGFloat = dx * sin(turn) + dy * cos(turn)
                ctx.setAlpha(depth)
                ctx.setLineWidth(thick)
                ctx.move(to: CGPoint(x: cx - ux * len / 2, y: cy - uy * len / 2))
                ctx.addLine(to: CGPoint(x: cx + ux * len / 2, y: cy + uy * len / 2))
                ctx.strokePath()
                if streak, profile >= 0.75 {
                    // 擦痕：顺着笔走向（不歪），在中线和边之间，一道细长的白。
                    let sOff: CGFloat = -side * half * (0.35 + 0.35 * unit(&rng))
                    let sLen: CGFloat = lw * (0.8 + 1.6 * unit(&rng))
                    let sThick: CGFloat = lw * (0.05 + 0.05 * unit(&rng))
                    let sx: CGFloat = px - dy * sOff
                    let sy: CGFloat = py + dx * sOff
                    ctx.setLineWidth(sThick)
                    ctx.move(to: CGPoint(x: sx - dx * sLen / 2, y: sy - dy * sLen / 2))
                    ctx.addLine(to: CGPoint(x: sx + dx * sLen / 2, y: sy + dy * sLen / 2))
                    ctx.strokePath()
                }
            }
            let gap: CGFloat = -log(max(1e-4, unit(&rng)))
            let density: CGFloat = 0.35 + 1.6 * dry
            d += step / density * min(3, gap)
        }
    }

    /// 沿笔走向的「干湿」0…1：0 = 笔压足、蜡厚（几乎是实的），1 = 笔压轻、蜡挂不住（空隙密、啃得深）。
    /// 两层值噪声叠起来（粗的一层节距 4–7 个线宽，细的 1.5–2.5 个；节点上随机取值、平滑插值），再拉开对比：
    /// 一笔上有成段实的，也有一阵一阵发干的地方，不会处处一样。随机数从空隙那一串里先取（形状不受影响）。
    private struct Dryness {
        var coarse: [CGFloat]
        var fine: [CGFloat]
        var coarseStep: CGFloat
        var fineStep: CGFloat

        init(length: CGFloat, lineWidth lw: CGFloat, rng: inout SeededRandom) {
            coarseStep = lw * (4 + 3 * CollagePencil.unit(&rng))
            fineStep = lw * (1.5 + CollagePencil.unit(&rng))
            let nc = Int((length / coarseStep).rounded(.up)) + 2
            let nf = Int((length / fineStep).rounded(.up)) + 2
            var c: [CGFloat] = []
            for _ in 0..<min(nc, 4096) { c.append(CollagePencil.unit(&rng)) }
            var f: [CGFloat] = []
            for _ in 0..<min(nf, 4096) { f.append(CollagePencil.unit(&rng)) }
            coarse = c
            fine = f
        }

        func at(_ d: CGFloat) -> CGFloat {
            let raw: CGFloat = 0.68 * Self.sample(coarse, d / coarseStep) + 0.32 * Self.sample(fine, d / fineStep)
            // 拉开：0.3 以下算实，0.8 以上算最干。
            let t: CGFloat = min(1, max(0, (raw - 0.3) / 0.5))
            return t * t * (3 - 2 * t)
        }

        private static func sample(_ knots: [CGFloat], _ x: CGFloat) -> CGFloat {
            guard let last = knots.indices.last else { return 0.5 }
            let i = min(last, max(0, Int(x.rounded(.down))))
            let j = min(last, i + 1)
            let t: CGFloat = min(1, max(0, x - CGFloat(i)))
            let s: CGFloat = t * t * (3 - 2 * t)
            return knots[i] + (knots[j] - knots[i]) * s
        }
    }

    /// 点（一团）上的空隙：同样的细条，都朝一个方向（像一下一下涂出来的）。
    private static func skips(across rect: CGRect, angle: CGFloat, width lw: CGFloat, rng: inout SeededRandom,
                              ctx: CGContext) {
        let dx: CGFloat = cos(angle)
        let dy: CGFloat = sin(angle)
        let area: CGFloat = rect.width * rect.height
        ctx.setAlpha(1)
        let count = min(400, Int(area / (lw * lw) * 1.2))
        for _ in 0..<count {
            let cx: CGFloat = rect.minX + unit(&rng) * rect.width
            let cy: CGFloat = rect.minY + unit(&rng) * rect.height
            let len: CGFloat = lw * (0.4 + unit(&rng) * 1.2)
            ctx.setLineWidth(lw * (0.08 + unit(&rng) * 0.14))
            ctx.move(to: CGPoint(x: cx - dx * len / 2, y: cy - dy * len / 2))
            ctx.addLine(to: CGPoint(x: cx + dx * len / 2, y: cy + dy * len / 2))
            ctx.strokePath()
        }
    }
}
