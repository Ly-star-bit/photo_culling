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
        return isFramed(cell: cell, style: style) ? borderInner(outer, style.border) : outer
    }

    /// 形状外框（月洞门 = 正方形），相纸/胶片的框画在这里面。
    static func outerArea(cell: CollageCell, rect: CGRect, style: CollageStyle) -> CGRect {
        guard (cell.shape ?? style.shape) == .circle else { return rect }
        let d = min(rect.width, rect.height)
        return CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
    }

    static func isFramed(cell: CollageCell, style: CollageStyle) -> Bool {
        let shape = cell.shape ?? style.shape
        return (style.border == .polaroid || style.border == .film) && (shape == .rect || shape == .rounded)
    }

    /// 相纸：上左右窄、下宽；胶片：长边两侧留齿孔带。
    static func borderInner(_ outer: CGRect, _ border: CollageBorder) -> CGRect {
        let m = min(outer.width, outer.height)
        switch border {
        case .polaroid:
            let side = m * 0.05
            let bottom = m * 0.19
            return CGRect(x: outer.minX + side, y: outer.minY + side,
                          width: outer.width - side * 2, height: outer.height - side - bottom)
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
