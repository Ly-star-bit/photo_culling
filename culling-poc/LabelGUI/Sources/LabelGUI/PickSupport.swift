import SwiftUI
import AppKit
import ImageIO

// MARK: - 连拍挑选的共用件（原来在场内对比模式里）：预览宽高比、按人脸裁原图放大、几格联动放大、最高项

/// 预览图的宽高比（只读文件头，按路径缓存）。BatchItem 里没有尺寸，排台面要用。
@MainActor
enum PreviewAspect {
    private static var cache: [String: CGFloat] = [:]

    static func ratio(_ path: String) -> CGFloat {
        if let hit = cache[path] { return hit }
        var ratio: CGFloat = 1.5
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 {
            // 预览是分析时转正之后写的，一般没有方向标记；万一有，5–8 是转了 90°。
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            ratio = orientation >= 5 ? CGFloat(h) / CGFloat(w) : CGFloat(w) / CGFloat(h)
        }
        cache[path] = ratio
        return ratio
    }

    static func median(_ paths: [String]) -> CGFloat {
        let ratios = paths.map { ratio($0) }.sorted()
        guard !ratios.isEmpty else { return 1.5 }
        return ratios[ratios.count / 2]
    }
}

// MARK: - 放大：按人脸裁原图

/// 对比放大的原图区域。整幅常驻太贵（40MP 解出来 160MB，四格就是 640MB），连拍比的是
/// 人脸，所以按人脸区域裁一块全分辨率的，裁完就把整幅放掉。
enum CompareZoom {
    final class Crop {
        let image: NSImage
        /// 进入时居中的点：主脸中心，裁块内归一化、左上原点。
        let anchor: CGPoint
        /// 文件 + 裁块，对焦高亮遮罩按它缓存。
        let key: String
        /// 裁块在原图里的位置（像素、左上原点）和原图尺寸 —— 换一个人居中时拿它把那张脸的
        /// 归一化框换算到裁块里。
        let rect: CGRect
        let fullSize: CGSize

        init(image: NSImage, anchor: CGPoint, key: String, rect: CGRect, fullSize: CGSize) {
            self.image = image
            self.anchor = anchor
            self.key = key
            self.rect = rect
            self.fullSize = fullSize
        }

        /// 某张脸（归一化框、左上原点）的中心在裁块里的位置；框不对就退回主脸。裁块是全部人脸的
        /// 并集外扩，所以任何一张主体脸都在里面。
        func anchor(for bbox: [Double]) -> CGPoint {
            guard bbox.count == 4, rect.width > 0, rect.height > 0 else { return anchor }
            let cx: Double = (bbox[0] + bbox[2]) / 2 * Double(fullSize.width)
            let cy: Double = (bbox[1] + bbox[3]) / 2 * Double(fullSize.height)
            let x: Double = (cx - Double(rect.minX)) / Double(rect.width)
            let y: Double = (cy - Double(rect.minY)) / Double(rect.height)
            return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }
    }

    static let cache: NSCache<NSString, Crop> = {
        let c = NSCache<NSString, Crop>()
        c.countLimit = 12
        c.totalCostLimit = ThumbCache.budget(fraction: 0.04, cap: 600_000_000)
        return c
    }()

    /// 同时最多解两张：每张解码时的峰值是整幅，别让六格一起把内存顶上去。
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    /// 裁哪一块（原图像素、左上原点）：所有主体脸的并集，四周各扩一个脸宽（600–1200px）
    /// —— 够拖着看眼睛、发际线和手，又不至于把整幅搬进来；合影自然会宽到接近整幅。
    /// 没有脸就取中间 60%。
    static func region(faces: [[Double]], width: Int, height: Int) -> CGRect {
        // 全用 Double 算：CI 上 Xcode 16 的类型检查器碰到 Double/CGFloat 混算的长式子会超时。
        let fullW = Double(width), fullH = Double(height)
        let full = CGRect(x: 0, y: 0, width: fullW, height: fullH)
        let boxes: [CGRect] = faces.filter { $0.count == 4 }.map { b in
            let x: Double = b[0] * fullW
            let y: Double = b[1] * fullH
            let w: Double = (b[2] - b[0]) * fullW
            let h: Double = (b[3] - b[1]) * fullH
            return CGRect(x: x, y: y, width: w, height: h)
        }
        guard let first = boxes.first else {
            let dx: Double = fullW * 0.2
            let dy: Double = fullH * 0.2
            return full.insetBy(dx: dx, dy: dy).integral
        }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        let side: CGFloat = boxes.map { max($0.width, $0.height) }.max() ?? 0
        let margin: CGFloat = min(max(side, 600), 1200)
        return union.insetBy(dx: -margin, dy: -margin).intersection(full).integral
    }

    private static func cacheKey(_ item: BatchItem) -> String {
        "\(ThumbCache.generation)|\(item.decodePath)"
    }

    /// 界面用：后台解码，最多两张并行。cancel 置位后还没开始的就不解了 —— 连按 Z、
    /// 或者解到一半 Esc 退出对比，排队的整幅解码（每张 160MB）不该接着跑。
    static func load(_ item: BatchItem, cancel: AnalysisEngine.CancelFlag) async -> Crop? {
        if let hit = cache.object(forKey: cacheKey(item) as NSString) { return hit }
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: cancel.isSet ? nil : crop(item))
            }
        }
    }

    /// 同步版（无头 `--compare-crop` 直接调）。
    static func crop(_ item: BatchItem) -> Crop? {
        let key = cacheKey(item)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let full: CGImage
        if let cached = FullResCache.cache.object(forKey: item.decodePath as NSString)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) {
            full = cached  // 检视器/审片刚放大过这张，直接从它裁
        } else {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.decodePath) as CFURL, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 20000,  // 原尺寸
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            full = decoded
        }
        let faces = item.faces.isEmpty ? (item.faceBbox.map { [$0] } ?? []) : item.faces.map(\.bbox)
        let rect = region(faces: faces, width: full.width, height: full.height)
        guard rect.width >= 1, rect.height >= 1,
              let cropped = full.cropping(to: rect),
              let owned = copyPixels(cropped) else { return nil }
        var anchor = CGPoint(x: 0.5, y: 0.5)
        if let b = item.faceBbox ?? faces.first, b.count == 4 {
            let centerX: Double = (b[0] + b[2]) / 2 * Double(full.width)
            let centerY: Double = (b[1] + b[3]) / 2 * Double(full.height)
            let x: Double = (centerX - Double(rect.minX)) / Double(rect.width)
            let y: Double = (centerY - Double(rect.minY)) / Double(rect.height)
            anchor = CGPoint(x: x, y: y)
        }
        let result = Crop(
            image: NSImage(cgImage: owned, size: NSSize(width: owned.width, height: owned.height)),
            anchor: anchor,
            key: key + "|\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
            rect: rect, fullSize: CGSize(width: full.width, height: full.height))
        cache.setObject(result, forKey: key as NSString, cost: owned.width * owned.height * 4)
        return result
    }

    /// cropping(to:) 和原图共用同一块像素 —— 不另画一份，整幅解码会跟着裁块一直活着。
    /// 用原图的色彩空间画（P3 的不压成 sRGB），不是 RGB 的才退回 sRGB。
    private static func copyPixels(_ image: CGImage) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? srgb
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: srgb, bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

/// 对比放大时几格一起动：拖、捏、双击任何一格，其余按"离各自人脸中心的偏移"跟过去。
/// 连拍帧之间人会漂，按同一个像素坐标对齐会对到脸旁边去。
final class ZoomLink {
    private final class Member {
        weak var scroll: NSScrollView?
        let anchor: NSPoint

        init(scroll: NSScrollView, anchor: NSPoint) {
            self.scroll = scroll
            self.anchor = anchor
        }
    }

    private var members: [ObjectIdentifier: Member] = [:]
    /// 正在把一格的变化套到别的格上 —— 那些格自己的边界变化通知不能再传出去。
    private var syncing = false
    /// 最近一次联动的倍率和偏移：新补上台的一格照着它摆。
    private var shared: (magnification: CGFloat, delta: NSPoint)?

    /// 入伙：ZoomPane 先按自己的人脸摆好再调这个，有联动状态就照着对齐。
    func register(_ scroll: NSScrollView, anchor: NSPoint) {
        let member = Member(scroll: scroll, anchor: anchor)
        members[ObjectIdentifier(scroll)] = member
        guard let shared else { return }
        syncing = true
        defer { syncing = false }
        apply(shared, to: member)
    }

    func unregister(_ scroll: NSScrollView) {
        members.removeValue(forKey: ObjectIdentifier(scroll))
    }

    func reset() {
        members.removeAll()
        shared = nil
    }

    /// 某一格的可视区变了（拖动、捏合、双击都会走到这）。
    func changed(_ scroll: NSScrollView) {
        guard !syncing, let source = members[ObjectIdentifier(scroll)] else { return }
        let bounds = scroll.contentView.bounds
        let state = (magnification: scroll.magnification,
                     delta: NSPoint(x: bounds.midX - source.anchor.x, y: bounds.midY - source.anchor.y))
        shared = state
        syncing = true
        defer { syncing = false }
        for (key, member) in members where key != ObjectIdentifier(scroll) {
            apply(state, to: member)
        }
    }

    private func apply(_ state: (magnification: CGFloat, delta: NSPoint), to member: Member) {
        guard let scroll = member.scroll else { return }
        if abs(scroll.magnification - state.magnification) > 0.0001 {
            scroll.magnification = state.magnification
        }
        ZoomPane.center(scroll, on: NSPoint(x: member.anchor.x + state.delta.x,
                                            y: member.anchor.y + state.delta.y))
    }
}

/// 台上几张之间每项的最高值；只有一张、或者大家一样，就不标。按**显示出来的数**比：
/// 123.4 和 123.2 都显示「锐度 123」，只标一张会被读成真有差别。并列最高的都标。
struct CompareBest {
    let sharpness: Int?
    let quality: String?
    let expression: Int?

    init(_ items: [BatchItem]) {
        func top<T: Comparable & Hashable>(_ values: [T]) -> T? {
            values.count >= 2 && Set(values).count > 1 ? values.max() : nil
        }
        sharpness = top(items.map { Self.sharpnessText($0.sharpness) })
        // "0.71" 这类两位小数的字符串按字典序比较和按数值比较一致（都是 0.xx / 1.00）。
        quality = top(items.compactMap { $0.faceQuality.map(Self.qualityText) })
        expression = top(items.compactMap(\.expressionScore))
    }

    static func sharpnessText(_ value: Double) -> Int { Int(value) }
    static func qualityText(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// 这一下是不是双击的第二下（或更多）。按钮被点完照片会挪位（跳去废片区、整场叠起来），手快连点时
/// 第二下就落在别的照片上了 —— 第二下一律不算。
/// 只有鼠标按键事件才有 clickCount：全键盘操控按空格、VoiceOver / 语音控制按下按钮时 currentEvent 是
/// 键盘或别的事件，读 clickCount 会抛 NSInternalInconsistencyException（拼图画布同一个写法）。
enum ClickGuard {
    @MainActor static var isRepeatClick: Bool {
        guard let e = NSApp.currentEvent else { return false }
        switch e.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return e.clickCount >= 2
        default:
            return false
        }
    }
}
