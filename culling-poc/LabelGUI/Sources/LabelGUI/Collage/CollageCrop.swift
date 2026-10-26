import Foundation
import CoreGraphics

/// 智能裁切：给一张照片和一个格子的宽高比，算出照片上要取的那一块（归一化窗口）。
///
/// - 人脸框来自分析结果，已经外扩 15%（FaceAnalyzer.bboxPadding），这里只在上面再给
///   头发/头饰留一截，左右下只留一点 —— 不能在外扩上再大幅外扩，否则小格永远判"切脸"。
/// - 全身（默认）：窗口尽量大；照片要左右裁时保留原构图（从居中开始，只挪到刚好不切脸）；
///   要上下裁时眼线放上三分线（全身照裁天不裁脚）。
/// - 半身/特写：按主脸大小换算窗口高度，脸居中、眼线上三分。
/// - 路人：窗口压到路人时在允许范围里挪一挪，挪不开就标出来。
enum CollageCrop {

    struct Hints: Hashable {
        /// 非主体的人（归一化框，左上原点）。
        var bystanders: [[Double]] = []
        /// 无脸照片的主体框（Vision 前景分割）。
        var subject: [Double]?
        /// 1024 预览的平均亮度 0…1、是不是黑白（顺手算的，抄进托盘的 CollagePhotoRef：编排、成套用）。
        var meanLuma: Double?
        var isMonochrome: Bool?
        /// 主体蒙版算完抄过来的（CollageMasks）：每张脸的头顶（脸横向范围里蒙版最上面那一行，归一化 y；
        /// 没找到 = −1）、蒙版占画面多少。只给挑主图这类便宜的用处看；渲染、封面取景直接问 CollageMasks
        /// （同步拿，不等后台），预览和导出才是同一个头顶。
        var headTop: [Double]?
        var maskCoverage: Double?

        init(bystanders: [[Double]] = [], subject: [Double]? = nil) {
            self.bystanders = bystanders
            self.subject = subject
        }
    }

    struct Window: Hashable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var cutsFace = false
        var hitsBystander = false

        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
        static let whole = Window(x: 0, y: 0, w: 1, h: 1)
    }

    /// 照片实际能画的区域（成品坐标）：月洞门 = 格子正中的正方形；相纸/胶片 = 框内（只对
    /// 矩形、圆角生效）。评分、界面警告、渲染必须用同一个 —— 以前评分按整格算，月洞门和
    /// 相纸格「切脸」判断的窗口根本不是画出来的那个。
    static func photoArea(cell: CollageCell, rect: CGRect, style: CollageStyle) -> CGRect {
        let shape = cell.shape ?? style.shape
        var outer = rect
        if shape == .circle {
            let d = min(rect.width, rect.height)
            outer = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        }
        return isFramed(cell: cell, style: style) ? borderInner(outer, style.border, mat: style.matWidth) : outer
    }

    /// 形状外框（月洞门 = 正方形），相纸/胶片的框画在这里面。
    static func outerArea(cell: CollageCell, rect: CGRect, style: CollageStyle) -> CGRect {
        guard (cell.shape ?? style.shape) == .circle else { return rect }
        let d = min(rect.width, rect.height)
        return CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
    }

    static func isFramed(cell: CollageCell, style: CollageStyle) -> Bool {
        let shape = cell.shape ?? style.shape
        let framedBorder = style.border == .polaroid || style.border == .film || style.border == .mat
        return framedBorder && (shape == .rect || shape == .rounded)
    }

    /// 卡纸底边比另外三边宽多少（装裱惯例 bottom weighting：底边宽 1/4"–1/2"，不加的话画看起来往下掉）。
    static let matBottomWeight = 1.2

    /// 相纸：上左右窄、下宽；胶片：长边两侧留齿孔带；卡纸：四边 mat × 短边，底边再宽两成。
    static func borderInner(_ outer: CGRect, _ border: CollageBorder, mat: Double = 0.07) -> CGRect {
        let m = min(outer.width, outer.height)
        switch border {
        case .polaroid:
            let side = m * 0.05
            let bottom = m * 0.19
            return CGRect(x: outer.minX + side, y: outer.minY + side,
                          width: outer.width - side * 2, height: outer.height - side - bottom)
        case .mat:
            let side = m * CGFloat(mat)
            let bottom = m * CGFloat(mat * matBottomWeight)
            return CGRect(x: outer.minX + side, y: outer.minY + side,
                          width: max(2, outer.width - side * 2), height: max(2, outer.height - side - bottom))
        case .film:
            if outer.width >= outer.height {
                let band = outer.height * 0.1
                let side = outer.width * 0.012
                return CGRect(x: outer.minX + side, y: outer.minY + band,
                              width: outer.width - side * 2, height: outer.height - band * 2)
            }
            let band = outer.width * 0.1
            let side = outer.height * 0.012
            return CGRect(x: outer.minX + band, y: outer.minY + side,
                          width: outer.width - band * 2, height: outer.height - side * 2)
        default:
            return outer
        }
    }

    static func aspect(of r: CGRect) -> Double { Double(max(1, r.width)) / Double(max(1, r.height)) }

    static func isValidBox(_ b: [Double]) -> Bool {
        b.count == 4 && b.allSatisfy { $0.isFinite } && b[2] > b[0] && b[3] > b[1]
    }

    /// cellAspect 在照片里能放下的最大窗口（归一化尺寸）。
    static func maxWindow(photoAspect: Double, cellAspect: Double) -> (w: Double, h: Double) {
        guard photoAspect > 0, cellAspect > 0 else { return (1, 1) }
        if cellAspect < photoAspect { return (cellAspect / photoAspect, 1) }
        return (1, photoAspect / cellAspect)
    }

    /// 人脸安全区（归一化）。主脸尺寸决定留白：上 0.3 张脸（头饰）、其余 0.06。
    static func safeRegion(_ faces: [[Double]]) -> CGRect? {
        let valid = faces.filter(isValidBox)
        guard let primary = valid.first else { return nil }
        var x0 = 1.0
        var y0 = 1.0
        var x1 = 0.0
        var y1 = 0.0
        for f in valid {
            x0 = min(x0, f[0])
            y0 = min(y0, f[1])
            x1 = max(x1, f[2])
            y1 = max(y1, f[3])
        }
        let fw = primary[2] - primary[0]
        let fh = primary[3] - primary[1]
        let top = max(0, y0 - 0.3 * fh)
        let bottom = min(1, y1 + 0.06 * fh)
        let left = max(0, x0 - 0.06 * fw)
        let right = min(1, x1 + 0.06 * fw)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func window(for photo: CollagePhotoRef, cell: CollageCell, cellAspect: Double,
                       framing: CollageFraming, hints: Hints?) -> Window {
        if cell.contain { return .whole }
        return window(for: photo, cellAspect: cellAspect, framing: framing, override: cell.crop, hints: hints)
    }

    static func window(for photo: CollagePhotoRef, cellAspect: Double, framing: CollageFraming,
                       override: CollageCropOverride?, hints: Hints?) -> Window {
        let ap = photo.aspect
        let maxW = maxWindow(photoAspect: ap, cellAspect: cellAspect)
        let safe = safeRegion(photo.faces)

        if let o = override {
            let zoom = max(1, o.zoom)
            let w = maxW.w / zoom
            let h = maxW.h / zoom
            let x = clamp(o.cx - w / 2, 0, 1 - w)
            let y = clamp(o.cy - h / 2, 0, 1 - h)
            var win = Window(x: x, y: y, w: w, h: h)
            win.cutsFace = safe.map { !contains(win.rect, $0) } ?? false
            win.hitsBystander = overlap(win.rect, hints?.bystanders ?? []) > 0.0005
            return win
        }

        // 窗口大小
        var w = maxW.w
        var h = maxW.h
        // 第一个框无效（0 高度等）时不能拿它算窗口：会得到 NaN / 0×0 的窗口。
        let primary = photo.faces.first(where: isValidBox)
        if let f = primary, framing == .half || framing == .close {
            let fh = f[3] - f[1]
            let targetH = fh * (framing == .half ? 4.6 : 2.3)
            let scaleDown = min(1, targetH / maxW.h)
            w = maxW.w * scaleDown
            h = maxW.h * scaleDown
            // 合影：窗口至少装得下所有人的安全区。
            if let s = safe, s.width > w || s.height > h {
                let grow = min(maxW.w / w, maxW.h / h, max(s.width / w, s.height / h))
                w *= grow
                h *= grow
            }
        } else if primary == nil, framing == .half || framing == .close {
            let z = framing == .half ? 0.72 : 0.5
            w = maxW.w * z
            h = maxW.h * z
        }

        // 期望位置
        var prefX = 0.5 - w / 2
        var prefY = 0.5 - h / 2
        if let f = primary {
            let fh = f[3] - f[1]
            let eyeY = f[1] + 0.42 * fh
            prefY = eyeY - h / 3
            if framing != .full && framing != .auto {
                prefX = (f[0] + f[2]) / 2 - w / 2
            }
        } else if let s = hints?.subject, s.count == 4 {
            prefX = (s[0] + s[2]) / 2 - w / 2
            prefY = (s[1] + s[3]) / 2 - h / 2
        }

        // 允许范围：窗口在照片里，且安全区在窗口里（装不下就居中对着安全区）。
        var loX = 0.0
        var hiX = max(0, 1 - w)
        var loY = 0.0
        var hiY = max(0, 1 - h)
        var cut = false
        if let s = safe {
            let needLoX = Double(s.maxX) - w
            let needHiX = Double(s.minX)
            if needLoX <= needHiX + 1e-9 {
                loX = max(loX, needLoX)
                hiX = min(hiX, needHiX)
            } else {
                cut = true
                let c = Double(s.midX) - w / 2
                loX = clamp(c, 0, max(0, 1 - w))
                hiX = loX
            }
            let needLoY = Double(s.maxY) - h
            let needHiY = Double(s.minY)
            if needLoY <= needHiY + 1e-9 {
                loY = max(loY, needLoY)
                hiY = min(hiY, needHiY)
            } else {
                cut = true
                let c = Double(s.midY) - h / 2
                loY = clamp(c, 0, max(0, 1 - h))
                hiY = loY
            }
            if loX > hiX { hiX = loX }
            if loY > hiY { hiY = loY }
        }
        var x = clamp(prefX, loX, hiX)
        var y = clamp(prefY, loY, hiY)

        // 路人：在允许范围内挪到压得最少的位置（挪动本身也算一点代价）。主体的构图优先 —— 眼线只在
        // 窗口高度的两成到四成半之间挪（再往上挪就是把人压到画面底下、身子切在胸口），而且要真躲开
        // 一大半才挪；躲不开就按原来的构图，角标标出路人，让人自己裁。
        let bystanders = hints?.bystanders ?? []
        var hits = false
        let before = overlap(CGRect(x: x, y: y, width: w, height: h), bystanders)
        if !bystanders.isEmpty, before > 0.0005 {
            var bandLo = loY
            var bandHi = hiY
            if let f = primary {
                let eye = f[1] + 0.42 * (f[3] - f[1])
                bandLo = max(loY, eye - 0.45 * h)
                bandHi = min(hiY, eye - 0.2 * h)
                if bandLo > bandHi {
                    bandLo = y
                    bandHi = y
                }
            }
            var best = (x: x, y: y, cost: Double.infinity, area: before)
            let steps = 12
            for i in 0...steps {
                for j in 0...steps {
                    let cx = hiX > loX ? loX + (hiX - loX) * Double(i) / Double(steps) : loX
                    let cy = bandHi > bandLo ? bandLo + (bandHi - bandLo) * Double(j) / Double(steps) : bandLo
                    let area = overlap(CGRect(x: cx, y: cy, width: w, height: h), bystanders)
                    let cost = area * 40 + abs(cx - x) + abs(cy - y)
                    if cost < best.cost { best = (cx, cy, cost, area) }
                    if bandHi <= bandLo { break }
                }
                if hiX <= loX { break }
            }
            if best.area <= before * 0.5 {
                x = best.x
                y = best.y
            }
            hits = overlap(CGRect(x: x, y: y, width: w, height: h), bystanders) > 0.0005
        }

        var win = Window(x: x, y: y, w: w, h: h)
        win.cutsFace = cut || (safe.map { !contains(win.rect, $0) } ?? false)
        win.hitsBystander = hits
        return win
    }

    // MARK: - 封面取景（CollageFraming.cover）

    /// 封面取景的目标，全是这一格的成品坐标（1 倍）：刊头最大那一行的字顶、基线，头顶压进字高的比例 t。
    /// behind = 人在字前（头顶压进刊头）；false = 字在人前（头顶落到基线下面，字不压脸）。
    struct CoverTarget {
        var area: CGRect
        var capTop: Double
        var baseline: Double
        var depth: Double
        var behind = true
        /// 头顶（归一化照片 y）：有蒙版用实测，没有用脸框上沿 − 0.3 脸高。
        var headTop: Double
        /// 放大上限（成品像素 / 原图像素）：超了就不再拉近，改提高 t。
        var upscaleLimit = 1.2
        /// 最多拉近几倍（相对最大窗口；nil = 不限）：CollageOverlay.maxZoom。
        var maxZoom: Double?
        /// 横向挪：0 = 脸居中对着格子中线（刊头居中，头压在中间的字母上）；正 = 窗口往右挪（照片坐标）。
        var shiftX = 0.0
        /// 导出往出血外延的那几条边（零边距印刷、贴着成品边）：窗口连同外延都要在照片里。
        var reserve = Reserve()
    }

    /// 导出时窗口往外延多少（相对窗口自己的宽 / 高：外延像素 ÷ 这一格的宽 / 高）。全 0 = 不外延。
    struct Reserve: Hashable {
        var left = 0.0
        var top = 0.0
        var right = 0.0
        var bottom = 0.0

        var isEmpty: Bool { left + top + right + bottom <= 0 }
    }

    /// 定好的取景连同出血外延要在照片里（导出时外延正好装得下，不用整块平移、也不用重新取景 —— 那样头就不在
    /// 预览里定的位置上了）：放不下就以中心缩一点（拉近），再整块挪回照片里。没有外延 = 原样。
    static func reserved(_ win: Window, _ r: Reserve) -> Window {
        guard !r.isEmpty, win.w > 0, win.h > 0 else { return win }
        let spanX: Double = 1 + r.left + r.right
        let spanY: Double = 1 + r.top + r.bottom
        let k: Double = min(1, 1 / (win.w * spanX), 1 / (win.h * spanY))
        var out = win
        if k < 1 {
            out.w = win.w * k
            out.h = win.h * k
            out.x = win.x + (win.w - out.w) / 2
            out.y = win.y + (win.h - out.h) / 2
        }
        let hiX: Double = 1 - out.w - r.right * out.w
        let hiY: Double = 1 - out.h - r.bottom * out.h
        out.x = clamp(out.x, r.left * out.w, hiX)
        out.y = clamp(out.y, r.top * out.h, hiY)
        return out
    }

    /// 解封面窗口（C2 §5 方案 a）：头顶落在字顶下 t 个字高；眼睛要么在字高 45–70% 处（脸嵌在字母之间），
    /// 要么在基线下 0–8% 格高，两种里挑要放大更少的；放大受 upscaleLimit 管，管不住就把 t 提高（头再往下）。
    /// 字在人前时头顶落在基线下 2% 格高、窗口尽量大。窗口出了照片上沿就再拉近一点（头顶上面没那么多天）。
    static func coverWindow(photo: CollagePhotoRef, cellAspect: Double, target c: CoverTarget, hints: Hints?) -> Window {
        let maxW = maxWindow(photoAspect: photo.aspect, cellAspect: cellAspect)
        guard let f = photo.faces.first(where: isValidBox), c.area.height > 1 else {
            return window(for: photo, cellAspect: cellAspect, framing: .full, override: nil, hints: hints)
        }
        let areaH = Double(c.area.height)
        let fh = f[3] - f[1]
        let eye: Double = f[1] + 0.42 * fh
        let ht = min(c.headTop, f[1])
        let de = max(1e-4, eye - ht)
        let capH = max(1, c.baseline - c.capTop)
        // 最大的窗口：连同导出的出血外延都在照片里（没有外延 = maxW.h）。
        let r = c.reserve
        let spanX: Double = 1 + r.left + r.right
        let spanY: Double = 1 + r.top + r.bottom
        let fullH: Double = min(maxW.h, 1 / spanY, maxW.h / (maxW.w * spanX))
        // 不放大超过上限、不拉近超过 maxZoom 的最小窗口高（归一化照片高）。
        let hPixels: Double = areaH / (c.upscaleLimit * Double(max(1, photo.height)))
        let hZoom: Double = c.maxZoom.map { fullH / max(1, $0) } ?? 0
        let hMin = min(fullH, max(hPixels, hZoom))
        var t = c.depth
        var h = fullH
        var headY: Double
        if c.behind {
            // 两种眼位：字高 45–70%，或基线下 0–8% 格高。D = 眼到头顶的成品距离 = de × 格高 / h。
            let spans: [(Double, Double)] = [((0.45 - t) * capH, (0.70 - t) * capH),
                                            ((1 - t) * capH, (1 - t) * capH + 0.08 * areaH)]
            var best: Double?
            for (lo, hi) in spans where lo > 0 {
                let hLo = de * areaH / hi
                let hHi = de * areaH / lo
                let top = min(fullH, hHi)
                guard top >= max(hMin, hLo) - 1e-9 else { continue }
                best = max(best ?? 0, top)
            }
            if let best {
                h = best
            } else if de * areaH / fullH > (1 - t) * capH + 0.08 * areaH {
                // 脸大：最大窗口眼睛都在基线下面老远，不拉近。
                h = fullH
            } else {
                // 要放大超过上限才够得着：停在上限，把 t 提高到眼睛落到字高 45% 处（头再往下）。
                h = hMin
                let reach = de * areaH / h
                t = max(t, min(1.2, 0.45 - reach / capH))
            }
            headY = c.capTop + t * capH
        } else {
            headY = c.baseline + 0.02 * areaH
        }
        // 头顶落在格子里的比例。窗口上沿不能出照片：头顶上面天不够就拉近（不超过放大上限）。人在字后时下沿也不能出：
        // 竖图放进稍宽的封面，最大窗口上下只有一点余量，不拉近头就顶不到刊头里（会被照片下沿卡住、掉到刊头下面）。
        // 出血外延也算在照片里（上沿留 r.top·h、下沿留 r.bottom·h；没有外延时就是原来那两条）。
        let tau = max(0, (headY - Double(c.area.minY)) / areaH)
        let topNeed: Double = tau + r.top
        let bottomNeed: Double = 1 - tau + r.bottom
        if topNeed > 1e-6, ht - tau * h < r.top * h { h = max(hMin, min(h, ht / topNeed)) }
        if c.behind, bottomNeed > 1e-6, ht - tau * h + h * (1 + r.bottom) > 1 {
            h = max(hMin, min(h, (1 - ht) / bottomNeed))
        }
        // 要留在窗口里的（同 CollageCrop.window 的安全区：合影里旁边那个人也不能切掉）：主脸的头 ∪ 其余每张脸的安全区。
        let head = CGRect(x: f[0], y: max(0, ht), width: f[2] - f[0], height: max(0, f[3] - max(0, ht)))
        let keep = coverKeep(photo.faces, head: head)
        // 字在人前（退回人前那一版、封面取景刊头在人前）：下沿出了照片也拉近 —— 不拉近 y 就被照片底边夹住，
        // 头掉到刊头下面老远（竖 2:3 放进 3:4、头在照片偏下）。拉近到头顶落在最下面那行基线下 2%，
        // 不超过放大上限，也不切要留的人：最低的下巴还在窗口里、所有人的宽度装得下。
        if !c.behind, bottomNeed > 1e-6, ht - tau * h + h * (1 + r.bottom) > 1 {
            let byChin: Double = (Double(keep.maxY) - ht) / max(1e-6, 1 - tau)
            let byWidth: Double = Double(keep.width) * maxW.h / maxW.w
            let floorH: Double = max(hMin, byChin, byWidth)
            h = min(fullH, max(floorH, min(h, (1 - ht) / bottomNeed)))
        }
        let w = h * maxW.w / maxW.h
        var loY: Double = r.top * h
        var hiY: Double = max(loY, 1 - h - r.bottom * h)
        // 竖向听头顶的目标（头顶压进刊头），只在装得下所有人时收紧到不切人；装不下（或和照片边、出血外延冲突）
        // 就照原样（切没切人下面按窗口实际装没装下判）。keep 的上沿不低于主脸头顶，收紧不会把头顶切掉。
        let needLoY: Double = Double(keep.maxY) - h
        let needHiY = Double(keep.minY)
        let fitLoY = max(loY, needLoY)
        let fitHiY = min(hiY, needHiY)
        if fitLoY <= fitHiY + 1e-9 {
            loY = fitLoY
            hiY = max(fitLoY, fitHiY)
        }
        let y = clamp(ht - tau * h, loY, hiY)
        let fc = (f[0] + f[2]) / 2
        // 横向：脸居中，再按 shiftX 挪；所有人（主脸加头顶、其余的脸加留白）不能出窗口；左右的出血外延也要在照片里。
        // 装不下所有人：退回只管主脸（刊头压的是主脸的头），切脸照实记。
        var loX: Double = r.left * w
        var hiX: Double = max(loX, 1 - w - r.right * w)
        let needLoX: Double = Double(keep.maxX) - w
        let needHiX = Double(keep.minX)
        let fitLoX = max(loX, needLoX)
        let fitHiX = min(hiX, needHiX)
        if fitLoX <= fitHiX + 1e-9 {
            loX = fitLoX
            hiX = max(fitLoX, fitHiX)
        } else {
            let faceLo = f[2] - w
            let faceHi = f[0]
            if faceLo <= faceHi {
                loX = max(loX, faceLo)
                hiX = min(hiX, faceHi)
            }
            if loX > hiX { hiX = loX }
        }
        let x = clamp(fc - w / 2 + c.shiftX, loX, hiX)
        var win = Window(x: x, y: y, w: w, h: h)
        win.cutsFace = !contains(win.rect, keep)
        win.hitsBystander = overlap(win.rect, hints?.bystanders ?? []) > 0.0005
        return win
    }

    /// 封面取景要留在窗口里的：主脸只要头（头顶用实测、不另加留白 —— 单人照和以前一样，刊头压的就是这个头），
    /// 其余每张脸照 safeRegion 留白（按主脸大小：上 0.3 张脸、其余 0.06）。只有一张脸 = head。
    static func coverKeep(_ faces: [[Double]], head: CGRect) -> CGRect {
        let valid = faces.filter(isValidBox)
        guard let primary = valid.first, valid.count > 1 else { return head }
        let fw = primary[2] - primary[0]
        let fh = primary[3] - primary[1]
        var keep = head
        for g in valid.dropFirst() {
            let left = max(0, g[0] - 0.06 * fw)
            let top = max(0, g[1] - 0.3 * fh)
            let right = min(1, g[2] + 0.06 * fw)
            let bottom = min(1, g[3] + 0.06 * fh)
            keep = keep.union(CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        return keep
    }

    /// 照片实际画在格子里的哪一块：完整显示 = 按比例居中；否则铺满格子。
    static func drawnRect(window: Window, photo: CollagePhotoRef, cell: CollageCell, in rect: CGRect) -> CGRect {
        guard cell.contain else { return rect }
        return aspectFit(photo.aspect, in: rect)
    }

    /// 这张照片在成品上放大了多少：画出来的像素 / 取景窗口里原图的像素，横竖取大的那个（SmartAlbums 的
    /// 分辨率警告也是这么算）。> 1 = 放大；印刷超过 1.2 开始发软。drawn 用成品像素（scale 1）。
    static func upscale(photo: CollagePhotoRef, window: Window, drawn: CGRect) -> Double {
        let srcW = window.w * Double(photo.width)
        let srcH = window.h * Double(photo.height)
        guard srcW > 0, srcH > 0, drawn.width > 0, drawn.height > 0 else { return 1 }
        return max(Double(drawn.width) / srcW, Double(drawn.height) / srcH)
    }

    static func aspectFit(_ aspect: Double, in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0, aspect > 0 else { return rect }
        let cellAspect = Double(rect.width / rect.height)
        if aspect > cellAspect {
            let h = Double(rect.width) / aspect
            return CGRect(x: Double(rect.minX), y: Double(rect.midY) - h / 2, width: Double(rect.width), height: h)
        }
        let w = Double(rect.height) * aspect
        return CGRect(x: Double(rect.midX) - w / 2, y: Double(rect.minY), width: w, height: Double(rect.height))
    }

    /// 归一化照片坐标里的框 → 画布坐标（落在 drawn 这块里），完全在窗口外的丢掉。
    static func project(_ box: [Double], window: Window, into drawn: CGRect) -> CGRect? {
        guard box.count == 4, window.w > 0, window.h > 0 else { return nil }
        let sx = Double(drawn.width) / window.w
        let sy = Double(drawn.height) / window.h
        let x0 = Double(drawn.minX) + (box[0] - window.x) * sx
        let y0 = Double(drawn.minY) + (box[1] - window.y) * sy
        let x1 = Double(drawn.minX) + (box[2] - window.x) * sx
        let y1 = Double(drawn.minY) + (box[3] - window.y) * sy
        let r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(drawn)
        return r.isNull || r.isEmpty ? nil : r
    }

    static func faceBoxes(photo: CollagePhotoRef, window: Window, in drawn: CGRect) -> [CGRect] {
        photo.faces.filter(isValidBox).compactMap { project($0, window: window, into: drawn) }
    }

    // MARK: - 小工具

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi >= lo else { return lo }
        return min(hi, max(lo, v))
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        let eps = 1e-6
        return Double(inner.minX) >= Double(outer.minX) - eps && Double(inner.minY) >= Double(outer.minY) - eps
            && Double(inner.maxX) <= Double(outer.maxX) + eps && Double(inner.maxY) <= Double(outer.maxY) + eps
    }

    /// 窗口和一组框的重叠面积（归一化照片面积）。
    static func overlap(_ window: CGRect, _ boxes: [[Double]]) -> Double {
        var total = 0.0
        for b in boxes where b.count == 4 {
            let r = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
            let i = window.intersection(r)
            if !i.isNull { total += Double(i.width * i.height) }
        }
        return total
    }
}
