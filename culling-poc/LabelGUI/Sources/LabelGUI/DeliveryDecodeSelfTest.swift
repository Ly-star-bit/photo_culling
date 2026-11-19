import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 交付的解码，跑在 --delivery-selftest 里（CI 的「自检」步骤）：
/// - 转正解码（UprightDecode，优化分析 PP-02）：样片只有方向 1 / 6 / 8，这里造图 —— 带纹理的合成图编成 JPEG，
///   再只改方向标签（CGImageDestinationCopyImageSource，压缩数据一个字节不动）造出 1–8 八种方向；每种在整幅、正好
///   1/2、1/4、1/8 这几档和 ImageIO 带变换的结果逐字节比，还要核对真的走了新路。要重采样的尺寸、灰度 JPEG、PNG
///   要退回老路（结果当然也一样）。一张小图（816×544，所有档位）+ 一张相机大小的（4032×3024，整幅和一半：
///   大图 ImageIO 可能换硬件解码器）。
/// - 转正解码的调用点（PP-02 后一半）：检视器 1:1、适应视图大图、连拍挑选放大、拼图解码、MCP 的图各从自己的入口解
///   方向 6 / 8 的样张文件，和 ImageIO 带变换逐字节比、核对走了新路（UprightDecode.taken）。合影小脸那处（整幅）在
///   refineSmallFaces 里面、单独调不到：端到端靠 --analyze 的 layer1 逐字节比（交接里写了怎么造小脸样张）。
/// - 交付并发路数（DeliveryConcurrency，PP-01）：各个尺寸 / 锐化 / 色彩落到哪一档（含 Core Image 那档），16 核 128 GB、10 核 16 GB、
///   8 核 8 GB 各开几路；缩到一半以内和 RAW 跟以前一样。真导出的路数在 --export-jpeg / --watermark-batch 打的「并发:」。
enum DeliveryDecodeSelfTest {
    typealias Check = (Bool, String, String) -> Void

    /// `dir`：调用点那段写样张文件的地方（跑完删掉）。
    static func run(_ dir: URL, check: Check) {
        upright(check: check)
        callSites(dir, check: check)
        concurrency(check: check)
    }

    // MARK: - 转正解码的调用点

    private static func callSites(_ dir: URL, check: Check) {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: dir) }
        guard let base = texturedJPEG(width: 4032, height: 3024),
              (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            check(false, "转正解码：调用点造不出样张 / 建不了目录", dir.path)
            return
        }
        func cg(_ image: NSImage?) -> CGImage? { image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        for orientation in [6, 8] {
            let url = dir.appendingPathComponent("o\(orientation).jpg")
            guard let data = retagged(base, orientation: orientation), (try? data.write(to: url)) != nil,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                check(false, "转正解码：调用点写不出方向 \(orientation) 的样张", url.path)
                continue
            }
            let path = url.path
            FullResCache.cache.removeObject(forKey: path as NSString)
            // （名字、maxPixel、该不该走新路、解码）：maxPixel 是那一处实际传给 ImageIO 的。
            let sites: [(String, Int, Bool, () -> CGImage?)] = [
                ("检视器 / 审片 1:1（FullResCache.load，整幅）", 20000, true, { cg(FullResCache.load(path: path)) }),
                ("适应视图大图（ThumbCache.decode，正好一半）", 2016, true, { cg(ThumbCache.decode(path: path, maxPixel: 2016)) }),
                ("适应视图大图（ThumbCache.decode，要重采样的 1000 照旧 ImageIO）", 1000, false,
                 { cg(ThumbCache.decode(path: path, maxPixel: 1000)) }),
                ("拼图解码（CollageImages.decode，整幅）", 4032, true, { CollageImages.decode(path: path, maxPixel: 4032) }),
                ("拼图解码（CollageImages.decode，1/4）", 1008, true, { CollageImages.decode(path: path, maxPixel: 1008) }),
                ("MCP 的图（LiveImages.thumbnail，整幅）", 4032, true, { LiveImages.thumbnail(path, maxEdge: 4032) }),
            ]
            var wrong: [String] = []
            for (label, maxPixel, shouldTake, decode) in sites {
                let before = UprightDecode.taken.value
                let got = decode()
                let took = UprightDecode.taken.value > before
                guard let got, let want = UprightDecode.transformed(source, maxPixel: maxPixel) else {
                    wrong.append(label + " 解不出")
                    continue
                }
                if !sameImage(want, got) || got.width > got.height { wrong.append(label + " 和 ImageIO 不一样") }
                if took != shouldTake { wrong.append(label + (took ? " 不该走新路" : " 没走新路")) }
            }
            // 连拍挑选放大：解整幅、按脸裁、另画一份。拿 ImageIO 带变换的整幅按同一块裁，两边画进同一种位图再比。
            CompareZoom.cache.removeAllObjects()
            FullResCache.cache.removeObject(forKey: path as NSString)
            let bbox = [0.40, 0.30, 0.55, 0.42]
            let item = BatchItem(
                id: "o\(orientation)", previewPath: "", rawPath: path, decodePath: path, sharpness: 0, worstClipPct: 0,
                eyeClosed: nil, faceQuality: nil, faceCount: 1, faceBbox: bbox, faceAreaPct: nil, faces: [],
                burstGroup: 0, expressionScore: nil, vlmReject: false, vlmCompositionIssues: [], vlmReason: nil,
                appealClosedEyes: nil, appealSubjectSharp: nil, appealIntentionalExposure: nil, appealReason: nil,
                exif: nil, horizonDeg: nil)
            let before = UprightDecode.taken.value
            let crop = CompareZoom.crop(item)
            let took = UprightDecode.taken.value > before
            let label = "连拍挑选放大（CompareZoom.crop，整幅）"
            if let crop, let full = UprightDecode.transformed(source, maxPixel: 20000) {
                let rect = CompareZoom.region(faces: [bbox], width: full.width, height: full.height)
                let want = full.cropping(to: rect).flatMap(redraw)
                let got = cg(crop.image).flatMap(redraw)
                var same = false
                if let want, let got { same = sameImage(want, got) }
                if crop.fullSize != CGSize(width: full.width, height: full.height) || crop.rect != rect {
                    wrong.append(label + " 整幅 \(crop.fullSize) / 裁块 \(crop.rect) 不对")
                }
                if !same { wrong.append(label + " 和 ImageIO 不一样") }
                if !took { wrong.append(label + " 没走新路") }
            } else {
                wrong.append(label + " 解不出")
            }
            FullResCache.cache.removeObject(forKey: path as NSString)
            CompareZoom.cache.removeAllObjects()
            check(wrong.isEmpty,
                  "转正解码：调用点（方向 \(orientation)，4032×3024）检视器 1:1、适应视图、连拍挑选放大、拼图、MCP 都和 ImageIO 带变换逐字节一样，整除档走了新路",
                  wrong.joined(separator: "，"))
        }
    }

    /// 画进一张新的 sRGB RGBX 位图（连拍挑选放大的裁块是另画的一份，两边过同一道再比）。
    private static func redraw(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: - 并发路数

    private static func concurrency(check: Check) {
        typealias C = DeliveryConcurrency
        let gb: UInt64 = 1 << 30
        let fuji = 7728 * 5152  // 4000 万像素
        // 7728×5152 横拍 / 5152×7728 竖拍：尺寸、锐化、色彩 → 哪一档。
        func lane(_ w: Int, _ h: Int, _ size: DeliverySize, _ sharpen: DeliverySharpen = .standard,
                  streams: Bool = true, raw: Bool = false) -> C.Path {
            C.path(width: w, height: h, raw: raw, longEdge: size.longEdgeCap(width: Double(w), height: Double(h)),
                   sharpen: sharpen, streamsOriginal: streams)
        }
        let lanes: [(C.Path, C.Path, String)] = [
            (lane(7728, 5152, .original), .streaming, "原尺寸保留色彩 → 边解边编"),
            (lane(7728, 5152, .original, streams: false), .fullDecode(pixels: fuji), "原尺寸转 sRGB / 水印 → 整幅"),
            (lane(5152, 7728, .long(4096)), .coreImage(pixels: fuji), "长边 4096 + 锐化（先解到 6144 > 一半）→ 整幅 + Core Image"),
            (lane(5152, 7728, .long(4096), .off), .fullDecode(pixels: fuji), "长边 4096 不锐化（4096 > 3864）→ 整幅"),
            (lane(5152, 7728, .long(2048)), .hardwareBound, "长边 2048 + 锐化（3072）→ 硬件解码器"),
            (lane(5152, 7728, .long(2576)), .hardwareBound, "长边 2576 + 锐化（正好 3864 = 一半）→ 硬件解码器"),
            (lane(5152, 7728, .box(1080, 1440)), .hardwareBound, "小红书 → 硬件解码器"),
            (lane(5152, 7728, .long(9000)), .fullDecode(pixels: fuji), "长边比原图大（不缩，整幅解）→ 整幅"),
            (lane(7728, 5152, .original, raw: true), .raw, "RAW → 照旧"),
        ]
        let wrongLanes = lanes.filter { $0.0 != $0.1 }.map { "\($0.2)：\($0.0.label)" }
        check(wrongLanes.isEmpty, "并发：尺寸 / 锐化 / 色彩落到哪一档（\(lanes.count) 种）", wrongLanes.joined(separator: "；"))

        let counts: [(Int, Int, String)] = [
            (C.workers(.streaming, cores: 16, memory: 128 * gb), 14, "16 核 原尺寸：核数 − 2"),
            (C.workers(.fullDecode(pixels: fuji), cores: 16, memory: 128 * gb), 14, "16 核 128 GB 整幅 40 MP：核数 − 2"),
            (C.workers(.fullDecode(pixels: 102_000_000), cores: 16, memory: 128 * gb), 14, "16 核 128 GB 整幅 1 亿像素"),
            (C.workers(.fullDecode(pixels: fuji), cores: 10, memory: 16 * gb), 5, "10 核 16 GB 整幅 40 MP：按内存 5 路"),
            (C.workers(.fullDecode(pixels: fuji), cores: 8, memory: 8 * gb), 2, "8 核 8 GB 整幅 40 MP：2 路"),
            (C.workers(.streaming, cores: 8, memory: 8 * gb), 6, "8 核 原尺寸：6 路"),
            (C.workers(.coreImage(pixels: fuji), cores: 16, memory: 128 * gb), 6, "16 核 128 GB 整幅 + Core Image：最多 6 路"),
            (C.workers(.coreImage(pixels: fuji), cores: 10, memory: 16 * gb), 5, "10 核 16 GB 整幅 + Core Image：按内存 5 路"),
            (C.workers(.hardwareBound, cores: 16, memory: 128 * gb), 4, "16 核 缩到一半以内：照旧 4 路"),
            (C.workers(.raw, cores: 16, memory: 128 * gb), 4, "16 核 RAW：照旧 4 路"),
            (C.workers(.hardwareBound, cores: 8, memory: 8 * gb), 2, "8 核 缩到一半以内：照旧 2 路"),
            (C.workers(.streaming, cores: 4, memory: 8 * gb), 2, "4 核 原尺寸：不少于 2 路"),
        ]
        let wrongCounts = counts.filter { $0.0 != $0.1 }.map { "\($0.2) 开了 \($0.0)" }
        check(wrongCounts.isEmpty, "并发：路数按核数和内存（\(counts.count) 种机器 / 路子）", wrongCounts.joined(separator: "；"))
    }

    // MARK: - 转正解码

    private static func upright(check: Check) {
        let names = ["", "原样", "左右翻", "转 180°", "上下翻", "转置", "顺时针 90°", "反转置", "逆时针 90°"]
        let cases: [(w: Int, h: Int, tiers: [Int], offTiers: [Int])] = [
            (816, 544, [20000, 816, 408, 204, 102], [600, 407, 815, 750]),
            (4032, 3024, [20000, 2016], [3000]),
        ]
        for (w, h, tiers, offTiers) in cases {
            guard let base = texturedJPEG(width: w, height: h) else {
                check(false, "转正解码：造不出 \(w)×\(h) 的测试 JPEG", "")
                continue
            }
            var mismatched: [String] = []
            var notTaken: [String] = []
            var wrongTaken: [String] = []
            for orientation in 1...8 {
                guard let data = retagged(base, orientation: orientation),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    mismatched.append("方向 \(orientation) 造不出")
                    continue
                }
                for maxPixel in tiers + offTiers {
                    let label = "方向 \(orientation)（\(names[orientation])）@\(maxPixel)"
                    guard let old = UprightDecode.transformed(source, maxPixel: maxPixel),
                          let new = UprightDecode.thumbnail(source, maxPixel: maxPixel) else {
                        mismatched.append(label + " 解不出")
                        continue
                    }
                    if !sameImage(old, new) { mismatched.append(label) }
                    let took = UprightDecode.rotated(source, maxPixel: maxPixel) != nil
                    let shouldTake = orientation != 1 && tiers.contains(maxPixel)
                    if shouldTake && !took { notTaken.append(label) }
                    if !shouldTake && took { wrongTaken.append(label) }
                }
            }
            let size = "\(w)×\(h)"
            check(mismatched.isEmpty,
                  "转正解码 \(size)：八种方向 × 整幅 / 1/2 / 1/4 / 1/8 和要重采样的几档，都和 ImageIO 带变换逐字节一样",
                  mismatched.prefix(4).joined(separator: "，"))
            check(notTaken.isEmpty,
                  "转正解码 \(size)：方向 2–8 在整幅和 DCT 整除档真的走了 vImage（不然上面那条等于没测）",
                  notTaken.prefix(4).joined(separator: "，"))
            check(wrongTaken.isEmpty,
                  "转正解码 \(size)：方向 1、要重采样的尺寸（\(offTiers.map(String.init).joined(separator: " / "))）照旧走 ImageIO",
                  wrongTaken.prefix(4).joined(separator: "，"))
        }

        // 灰度 JPEG、PNG 带方向：不走新路，结果和 ImageIO 一样。
        for (label, type, gray) in [("灰度 JPEG", UTType.jpeg, true), ("PNG", UTType.png, false)] {
            guard let image = texturedImage(width: 408, height: 272, gray: gray),
                  let data = encode(image, type: type, orientation: 6),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let old = UprightDecode.transformed(source, maxPixel: 20000),
                  let new = UprightDecode.thumbnail(source, maxPixel: 20000) else {
                check(false, "转正解码：\(label) 造不出 / 解不出", "")
                continue
            }
            check(UprightDecode.rotated(source, maxPixel: 20000) == nil && sameImage(old, new),
                  "转正解码：\(label)（方向 6、整幅）退回 ImageIO，结果一样", "\(new.width)×\(new.height)")
        }

        let exact: [((Int, Int, Int), String?)] = [
            ((7728, 5152, 20000), "7728×5152"), ((7728, 5152, 7728), "7728×5152"), ((7728, 5152, 3864), "3864×2576"),
            ((7728, 5152, 1932), "1932×1288"), ((7728, 5152, 966), "966×644"), ((7728, 5152, 483), nil),
            ((7728, 5152, 3072), nil), ((7728, 5152, 5000), nil), ((7728, 5152, 7727), nil),
            ((6001, 4001, 3000), nil), ((6001, 4001, 6001), "6001×4001"), ((5152, 7728, 3864), "2576×3864"),
        ]
        let wrong = exact.filter { item, want in
            let got = UprightDecode.exactDecodeSize(width: item.0, height: item.1, maxPixel: item.2).map { "\($0.width)×\($0.height)" }
            return got != want
        }.map { "\($0.0.0)×\($0.0.1)@\($0.0.2)" }
        check(wrong.isEmpty, "转正解码：走新路的尺寸只有整幅和两边都整除的 1/2、1/4、1/8（3072 / 5000 / 差一个像素的都不算）",
              wrong.joined(separator: "，"))
    }

    /// 两张图宽高、像素格式一样，每行有效像素逐字节一样（行尾对齐的填充不比）。
    static func sameImage(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, a.bitsPerPixel == b.bitsPerPixel,
              a.bitsPerComponent == b.bitsPerComponent, a.bitmapInfo == b.bitmapInfo,
              a.colorSpace?.name == b.colorSpace?.name,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return false }
        let row = a.width * a.bitsPerPixel / 8
        for y in 0..<a.height where memcmp(pa + y * a.bytesPerRow, pb + y * b.bytesPerRow, row) != 0 { return false }
        return true
    }

    /// 带纹理的合成图：平滑的色块（转错方向、采样换了都看得出）+ 细斜线和逐像素的噪点（高频，重采样一变就不一样）。
    static func texturedImage(width: Int, height: Int, gray: Bool = false) -> CGImage? {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        // 小块随机色放大画满（平滑插值），定种子的 LCG，每次一样。
        let cw = 24, ch = 16
        var seed: UInt32 = 0x2545F491
        func next() -> UInt8 { seed = seed &* 1_664_525 &+ 1_013_904_223; return UInt8(truncatingIfNeeded: seed >> 24) }
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if let cells = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                 space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
           let cellBytes = cells.data?.bindMemory(to: UInt8.self, capacity: cw * ch * 4) {
            for i in 0..<(cw * ch * 4) { cellBytes[i] = next() }
            if let small = cells.makeImage() {
                ctx.interpolationQuality = .high
                ctx.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        // 左上角一块实心（方向转错一眼就不一样）、细斜线。
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - height / 5, width: width / 7, height: height / 5))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1)
        var x = -height
        while x < width {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x + height, y: height))
            x += 7
        }
        ctx.strokePath()
        guard let data = ctx.data else { return ctx.makeImage() }
        // 逐像素加一点噪点（±12）：JPEG 量化后还留着高频。
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        let step = gray ? 1 : 4
        for y in 0..<height {
            let row = bytes + y * ctx.bytesPerRow
            for i in stride(from: 0, to: width * step, by: 1) where gray || i % 4 != 3 {
                let n = Int(next() % 25) - 12
                row[i] = UInt8(clamping: Int(row[i]) + n)
            }
        }
        return ctx.makeImage()
    }

    static func encode(_ image: CGImage, type: UTType, orientation: Int) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation,
                                                 kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func texturedJPEG(width: Int, height: Int) -> Data? {
        texturedImage(width: width, height: height).flatMap { encode($0, type: .jpeg, orientation: 1) }
    }

    /// 只改方向标签（压缩数据原样拷）。
    private static func retagged(_ jpeg: Data, orientation: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, [kCGImageDestinationOrientation: orientation] as CFDictionary,
                                                &error) else { return nil }
        guard let check = CGImageSourceCreateWithData(out, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
              (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == orientation else { return nil }
        return out as Data
    }
}
