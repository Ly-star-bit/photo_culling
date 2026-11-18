import Foundation
import Accelerate
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 按 EXIF 方向转正的解码（优化分析 PP-02）：结果和 `CGImageSourceCreateThumbnailAtIndex(… WithTransform: true)`
/// 逐字节一样，竖拍整幅少一半多的 CPU。
///
/// 为什么：带 WithTransform 时 ImageIO 解完再用 CoreGraphics 的通用仿射采样（`rgba32_sample_rgba32`）一个像素一个像素地转，
/// 4000 万像素的竖拍整幅这一步 ~200 ms；不带变换解、再用 vImage 整块转 90° / 镜像，16 张竖拍整幅平均 358 → 158 ms CPU、
/// 44.9 → 16.4 G 指令（单线程逐张）。横拍（方向 1）两条路本来就是同一条，不碰。
///
/// 只在「逐字节一样」有把握的地方走新路，其余一律原样走 ImageIO：
/// - 只有不用重采样的尺寸：整幅（maxPixel ≥ 长边），或者正好 1/2、1/4、1/8（JPEG 按 DCT 直接解出来、两边都整除）。
///   这时两条路都是「同一张解码图 + 无损的转 / 翻」。要重采样的尺寸 ImageIO 带变换那条路换了一种采样：长边 2048 / 4096 /
///   5000（相册格子常落在这）竖拍都有差（最大差 66–86 级，带变换的那张略软），离 DCT 档差一两个像素的（597 / 600、
///   510 / 512）也有差，按宽高猜不出来 —— 所以不用「比例整除」那种宽一点的条件。逐张核对：photot 竖拍（方向 6 / 8）、
///   改写方向标签造出的 1–8 八种方向、6000×4000 / 8192×5464 / 11648×8736 / 6001×4001 等十几种尺寸，45 000 多个组合里
///   满足这个条件的没有一个不一样（自检见 DeliveryDecodeSelfTest.swift）。
/// - 只有 8 位 RGB 的 JPEG：灰度 JPEG、HEIF / TIFF / PNG、RAW 都退回老路（没量过，不赌）。
/// - 解出来的图再核一遍：每像素 32 位、8 位一个分量、RGB 色彩空间、宽高和要的一样；不对就扔掉、老路重解。
/// 新图沿用解码图的色彩空间、bitmapInfo、渲染意图（ICC 标签原样，Adobe RGB / P3 不会被悄悄转掉）。
///
/// 内存：新路要解码图和转好的图同时在，转好的那份是自己 calloc 的（算进 peak footprint，ImageIO 自己出的图大半不算），
/// 一路多一帧：4000 万像素 4 路的 peak footprint 长边 4096 + 锐化 2.5 → 3.1 GB、水印原尺寸 1.9 → 2.4–2.7 GB。
/// 交付导出的路数按这个算。输出缓冲不能用 NSMutableData：在导出的并发任务里大块内存一直不还（同一组 4 路涨到 7 GB）。
///
/// 现在接的是交付这一条线：WatermarkEngine.decodeUpright（水印批量、水印预览、导出 JPG / 水印的缩小 + 锐化
/// SharpRenderer.deliveryDownscale 的整幅那档）和 BatchStore.writeJPEG 不锐化缩图那条。检视器 1:1（FullResCache）、
/// 连拍挑选放大（CompareZoom.crop）、合影小脸（FaceAnalyzer）、拼图解码（CollageImages.decode）、MCP 的图（LiveImages）
/// 都是把 `CGImageSourceCreateThumbnailAtIndex(… WithTransform: true)` 换成 `UprightDecode.thumbnail` 一行的事，结果逐字节一样。
enum UprightDecode {
    /// 解到长边不超过 `maxPixel`、按 EXIF 方向转正。和 ImageIO 的
    /// `[FromImageAlways: true, ThumbnailMaxPixelSize: maxPixel, WithTransform: true]` 缩略图逐字节一样。
    static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        rotated(source, maxPixel: maxPixel) ?? transformed(source, maxPixel: maxPixel)
    }

    /// 老路：ImageIO 带变换的缩略图。
    static func transformed(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// 解码图的宽高（转正之前）：整幅 = 原样，1/2、1/4、1/8 = 两边各右移 k 位。nil = 这个尺寸要重采样，不走新路。
    /// `width` / `height` 是文件里存的（编码）宽高。
    static func exactDecodeSize(width: Int, height: Int, maxPixel: Int) -> (width: Int, height: Int)? {
        let long = max(width, height), short = min(width, height)
        guard width > 0, height > 0 else { return nil }
        if maxPixel >= long { return (width, height) }
        for k in 1...3 where long % (1 << k) == 0 && short % (1 << k) == 0 && maxPixel == long >> k {
            return (width >> k, height >> k)
        }
        return nil
    }

    /// 新路：不带变换解 + vImage 转 / 翻。走不了（方向 1、不是 8 位 RGB JPEG、尺寸要重采样、解出来的格式不对）= nil。
    static func rotated(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        guard (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
              (2...8).contains(orientation),
              (props[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8,
              (props[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelRGB as String),
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              let want = exactDecodeSize(width: width, height: height, maxPixel: maxPixel),
              let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: false,
              ] as CFDictionary)
        else { return nil }
        return rotate(raw, orientation: orientation, expect: want)
    }

    /// 把不带变换解出来的图按 EXIF 方向转正（无损：只挪像素）。格式不是 8 位 4 通道 RGB、宽高不是 `expect` = nil。
    static func rotate(_ raw: CGImage, orientation: Int, expect: (width: Int, height: Int)) -> CGImage? {
        let alpha = raw.alphaInfo
        guard raw.width == expect.width, raw.height == expect.height,
              raw.bitsPerComponent == 8, raw.bitsPerPixel == 32,
              alpha == .noneSkipFirst || alpha == .noneSkipLast,
              let space = raw.colorSpace, space.model == .rgb,
              let data = raw.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= raw.bytesPerRow * raw.height
        else { return nil }
        let w = raw.width, h = raw.height
        let swapsAxes = orientation >= 5
        let outW = swapsAxes ? h : w, outH = swapsAxes ? w : h
        // 行宽对齐到 32 字节（和 ImageIO 自己出的图一样）。
        let rowBytes = (outW * 4 + 31) / 32 * 32
        let byteCount = rowBytes * outH
        guard let out = calloc(1, byteCount) else { return nil }
        // 交给 CGDataProvider 管：CGImage 放掉时 free。不用 NSMutableData —— 那样在导出的并发任务里大块内存一直不还（实测
        // 4 路长边 4096 peak footprint 2.5 → 7 GB）。
        guard let provider = CGDataProvider(dataInfo: nil, data: out, size: byteCount, releaseData: { _, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
        }) else { free(out); return nil }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes), height: vImagePixelCount(h),
                                width: vImagePixelCount(w), rowBytes: raw.bytesPerRow)
        var dst = vImage_Buffer(data: out, height: vImagePixelCount(outH),
                                width: vImagePixelCount(outW), rowBytes: rowBytes)
        var fill: [UInt8] = [0, 0, 0, 0]
        let flags = vImage_Flags(kvImageNoFlags)
        // EXIF 方向（文件里存的样子 → 转正要做什么）：2 左右翻 · 3 转 180° · 4 上下翻 · 5 = 逆时针 90° 再上下翻 ·
        // 6 顺时针 90° · 7 = 顺时针 90° 再上下翻 · 8 逆时针 90°。vImageRotate90 的参数是逆时针转几个 90°。
        let error: vImage_Error
        switch orientation {
        case 2: error = vImageHorizontalReflect_ARGB8888(&src, &dst, flags)
        case 3: error = vImageRotate90_ARGB8888(&src, &dst, 2, &fill, flags)
        case 4: error = vImageVerticalReflect_ARGB8888(&src, &dst, flags)
        case 5, 7:
            let turned = vImageRotate90_ARGB8888(&src, &dst, orientation == 5 ? 1 : 3, &fill, flags)
            error = turned == kvImageNoError ? vImageVerticalReflect_ARGB8888(&dst, &dst, flags) : turned
        case 6: error = vImageRotate90_ARGB8888(&src, &dst, 3, &fill, flags)
        case 8: error = vImageRotate90_ARGB8888(&src, &dst, 1, &fill, flags)
        default: return nil
        }
        guard error == kvImageNoError else { return nil }
        return CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: space, bitmapInfo: raw.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: raw.shouldInterpolate, intent: raw.renderingIntent)
    }
}
