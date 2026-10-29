import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 给 AI 看的图（DESIGN §10.3 app 一侧第 2 步、§4.4 的预算）：解码、裁切、缩放、编码 JPEG，全在 app 里做，
/// `--mcp` 只收字节（它连一行图片解码都没有，§10.5 的 grep 守着）。这里全部 nonisolated、不碰任何 store：
/// LiveHandlers 在主线程上把 BatchItem 复制出来，再在 Task.detached 里调这里；人脸裁原图走 CompareZoom 自己的队列。
enum LiveImages {
    /// 单张字节上限（§4.4，MCPConfig.perImageKB）：超了先把质量从 0.8 降到 0.6，再把尺寸乘 0.85 重缩，直到放得下。
    static let perImageLimit = MCPConfig.perImageKB * 1024
    static let quality = 0.8
    static let lowQuality = 0.6
    static let shrink = 0.85
    /// 长边下限：太小的图 API 会回 400，准确率也掉（§4.4）。
    static let minEdge = 256
    /// 默认长边：一张 1024，2–4 张每张 768（§10.3）。
    static func defaultEdge(count: Int) -> Int { count <= 1 ? 1024 : 768 }

    // MARK: - 原图打开记录（§10.7 第 33 条：受保护位置不读原图，测试宿主在 test.state 里看它）

    /// 每次要从原图解码之前记一笔（只记路径，最多留最近 64 条）；GUI 里也记，代价是一次加锁。
    /// 记在「打开之前」：哪怕打开失败也算碰过，受保护位置的断言要的就是「一次都没去碰」。
    final class OpenLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        private var total = 0

        func record(_ path: String) {
            lock.lock()
            total += 1
            paths.append(path)
            if paths.count > 64 { paths.removeFirst(paths.count - 64) }
            lock.unlock()
        }

        var snapshot: (count: Int, recent: [String]) {
            lock.lock()
            defer { lock.unlock() }
            return (total, paths)
        }
    }

    static let originalOpens = OpenLog()

    // MARK: - 解码

    /// ImageIO 直接解到目标尺寸（不整幅解码）、按 EXIF 转正。分析预览本来就是转正以后写的，带上 WithTransform 也没坏处。
    static func thumbnail(_ path: String, maxEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path, isDirectory: false) as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxEdge),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 在 1024 的预览上按人脸裁（受保护位置、原图读不到时，§10.3）：裁块用 CompareZoom.region，尺寸按预览算。
    static func faceCropOnPreview(_ item: BatchItem) -> CGImage? {
        guard let preview = thumbnail(item.previewPath, maxEdge: ImageLoader.previewMaxPixel) else { return nil }
        let rect = CompareZoom.region(faces: faceBoxes(item), width: preview.width, height: preview.height)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return preview.cropping(to: rect)
    }

    /// 和 CompareZoom.crop 一样取脸：全部主体脸，没有就退回主脸的框。
    static func faceBoxes(_ item: BatchItem) -> [[Double]] {
        item.faces.isEmpty ? (item.faceBbox.map { [$0] } ?? []) : item.faces.map(\.bbox)
    }

    // MARK: - 缩放、编码

    /// 画进 sRGB 的位图，长边缩到 `maxEdge`（不放大；比 256 还小的放大到 256）。原图可能是 P3：在这里转成 sRGB（§4.4）。
    static func scaled(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let w = Double(image.width)
        let h = Double(image.height)
        let long = max(w, h)
        guard long >= 1 else { return nil }
        var target = min(Double(maxEdge), long)
        if target < Double(minEdge) { target = Double(minEdge) }
        let scale: Double = target / long
        let outW = max(1, Int((w * scale).rounded()))
        let outH = max(1, Int((h * scale).rounded()))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    struct Encoded {
        let data: Data
        let width: Int
        let height: Int
    }

    /// §4.4：sRGB、质量 0.8；超过单张上限先降到 0.6，再把尺寸乘 0.85 重缩，直到放得下（长边到 256 还放不下就给这一版）。
    static func encode(_ image: CGImage, maxEdge: Int, limit: Int = perImageLimit) -> Encoded? {
        guard var current = scaled(image, maxEdge: maxEdge) else { return nil }
        var q = quality
        while true {
            guard let data = jpeg(current, quality: q) else { return nil }
            if data.count <= limit { return Encoded(data: data, width: current.width, height: current.height) }
            if q > lowQuality {
                q = lowQuality
                continue
            }
            let long = max(current.width, current.height)
            let next = Int((Double(long) * shrink).rounded(.down))
            if next < minEdge || next >= long { return Encoded(data: data, width: current.width, height: current.height) }
            guard let smaller = scaled(current, maxEdge: next) else { return nil }
            current = smaller
        }
    }
}
