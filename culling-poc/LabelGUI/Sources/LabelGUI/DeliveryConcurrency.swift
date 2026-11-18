import Foundation
import ImageIO

/// 交付导出（导出 JPG / 精华 Top N / 水印批量）同时跑几张（优化分析 PP-01）。
///
/// 以前两处都写死 `min(4, max(2, 核数 / 4))`：16 核也只开 4 路，理由是「整幅解码一张就很大」—— 是为内存设的上限，
/// 但不分路子、也不看物理内存。按路子分（105 张 4000 万像素 JPG，M4 Max 16 核 / 128 GB，release，和 v1.32.0 比）：
/// - 原尺寸 JPEG 重编码（`streaming`）：编码器边拉像素边软件解原片，不整张解，纯吃 CPU。开到核数 − 2（留两个核给界面和
///   别的后台活）：14 路墙上 9.4–9.8 → 3.5–4.1 s，CPU 秒 +8%（能效核），peak 0.17 → 0.33–0.37 GB。
/// - 整幅解、CoreGraphics 合成（`fullDecode`：水印原尺寸、不锐化的缩图长边超过原图一半、原尺寸转 sRGB）：也纯吃 CPU，
///   但每路几百 MB，路数按物理内存定：所有路加起来不超过物理内存的 1/4，每路按 `bytesPerPixel` 估，封顶核数 − 2。
///   水印原尺寸 + EXIF 字 14 路：墙上 13.6 → 3.8 s，peak 1.9 → 5.8–6.2 GB（6 / 8 / 10 路 7.1 / 5.3 / 4.7 s）。
///   128 GB 的机器 14 路（16 核），16 GB 约 5 路，8 GB 2 路。
/// - 整幅解再交给 Core Image 缩放锐化（`coreImage`：长边 4096 + 锐化，SharpRenderer.deliveryDownscale 整幅那档）：
///   进程里那一个共用的 CIContext 排着渲（采样里线程等在 CI 的几条串行队列上），6 路以后不再快、只涨内存：
///   4 / 6 / 8 / 14 路墙上 7.9 / 5.9–6.0 / 5.5–5.9 / 5.1–5.9 s，peak 3.1 / 3.6 / 3.9–4.4 / 4.6–4.8 GB。按内存算、最多 6 路。
///   （复核开两个进程量到的 1.8 倍是两个 CIContext；要再快得给每路一个 CIContext，没做。）
/// - 解到原图一半以内的（`hardwareBound`：2048、朋友圈、小红书、IG）：卡在芯片里那一个硬件 JPEG 解码器上，路数翻 2–3 倍
///   每进程 CPU 秒一点没涨、墙上反而拉长，只快 15–20%、内存翻几倍 —— 照旧。
/// - RAW（`raw`）：ImageIO 去马赛克，没有 RAW 样片量过每路要多少内存 —— 照旧。
/// 导到外接机械盘 / U 盘时瓶颈换成写盘（原尺寸 34 张/s ≈ 275 MB/s），路数多了也不会更快，但也不会更慢。
enum DeliveryConcurrency {
    enum Path: Equatable, Sendable {
        case streaming
        case fullDecode(pixels: Int)
        case coreImage(pixels: Int)
        case hardwareBound
        case raw

        var label: String {
            switch self {
            case .streaming: return "原尺寸边解边编"
            case .fullDecode(let pixels): return "整幅解 \(pixels / 1_000_000) MP"
            case .coreImage(let pixels): return "整幅解 \(pixels / 1_000_000) MP + Core Image 锐化"
            case .hardwareBound: return "解到一半以内（硬件解码器）"
            case .raw: return "RAW"
            }
        }
    }

    /// 整幅解一路的峰值内存估算，字节 / 原图像素。v1.32.0 的 4 路实测 peak footprint：长边 4096 + 锐化 2.56 GB（16 B/像素）、
    /// 水印原尺寸 + EXIF 字 1.94 GB（12 B/像素）；转正解码换成 vImage（PP-02）以后每路多一帧（+4 B/像素），按大的算 20。
    /// 放开以后实测比这个省（水印 14 路 ≈ 11 B/像素），留着余量给相框 / 画布扩展和别的机身。
    static let bytesPerPixel = 20
    /// 所有路加起来最多占物理内存的几分之一。
    static let memoryShare = 0.25
    /// Core Image 那档最多几路（共用的 CIContext 排着渲，再多只涨内存）。
    static let coreImageCap = 6

    /// 以前的写死值（硬件解码器那档、RAW 照旧用它；别的档不比它少）。
    static func legacy(cores: Int) -> Int { min(4, max(2, cores / 4)) }

    static func workers(_ path: Path, cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                        memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let old = legacy(cores: cores)
        let ceiling = max(old, cores - 2)
        func byMemory(_ pixels: Int) -> Int {
            let perWorker = Double(max(pixels, 1)) * Double(bytesPerPixel)
            return max(2, Int(Double(memory) * memoryShare / perWorker))
        }
        switch path {
        case .hardwareBound, .raw:
            return old
        case .streaming:
            return ceiling
        case .fullDecode(let pixels):
            return min(ceiling, byMemory(pixels))
        case .coreImage(let pixels):
            return min(ceiling, max(old, coreImageCap), byMemory(pixels))
        }
    }

    /// 一张图走哪一档。`width` / `height` 转正后的原图尺寸；`longEdge` 要缩到的长边（nil = 原尺寸不缩）；
    /// `streamsOriginal`：原尺寸时是不是边拉边编（导出 JPG 保留色彩是；转 sRGB 可能要整张画一遍、水印要整张合成，不是）。
    /// 解码尺寸和 BatchStore.writeJPEG / WatermarkEngine.export / SharpRenderer.deliveryDownscale 一样算：
    /// 缩小 + 锐化先解到目标的 1.5 倍（超过一半就整幅、走 Core Image），不锐化直接解到目标；解出来超过原图一半 = ImageIO
    /// 要整幅解。
    static func path(width: Int, height: Int, raw: Bool, longEdge: Int?, sharpen: DeliverySharpen,
                     streamsOriginal: Bool) -> Path {
        if raw { return .raw }
        let fullLong = max(width, height)
        let pixels = width * height
        guard let longEdge else { return streamsOriginal ? .streaming : .fullDecode(pixels: pixels) }
        if longEdge < fullLong && sharpen != .off {
            // SharpRenderer.deliveryDownscale：先解到目标的 1.5 倍，超过一半就整幅，再交给 Core Image。
            let wanted = longEdge * 3 / 2
            return wanted > fullLong / 2 ? .coreImage(pixels: pixels) : .hardwareBound
        }
        return min(longEdge, fullLong) > fullLong / 2 ? .fullDecode(pixels: pixels) : .hardwareBound
    }

    /// 文件头：转正后的宽高、是不是 RAW。读不出 = nil。
    static func header(_ url: URL) -> (width: Int, height: Int, raw: Bool)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let size = WatermarkEngine.uprightSize(of: source) else { return nil }
        return (size.width, size.height, ImageLoader.rawExtensions.contains(url.pathExtension.lowercased()))
    }

    struct Plan: Sendable {
        let workers: Int
        let path: Path?

        var label: String { "\(workers) 路" + (path.map { "（\($0.label)）" } ?? "") }
    }

    /// 一批里均匀抽最多 `sample` 张读文件头，按最吃资源的那张定（路数取最小）。一张都读不出 = 以前的写死值。
    static func plan(sources: [URL], sample: Int = 16,
                     cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                     memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                     path: (_ width: Int, _ height: Int, _ raw: Bool) -> Path) -> Plan {
        var best: Plan?
        let step = max(1, sources.count / max(1, sample))
        for index in stride(from: 0, to: sources.count, by: step).prefix(sample) {
            guard let head = header(sources[index]) else { continue }
            let p = path(head.width, head.height, head.raw)
            let n = workers(p, cores: cores, memory: memory)
            if best.map({ n < $0.workers }) ?? true { best = Plan(workers: n, path: p) }
        }
        return best ?? Plan(workers: legacy(cores: cores), path: nil)
    }

    /// 导出 JPG / 精华 Top N（BatchStore.writeJPEG）：原尺寸保留色彩 = 边拉边编；转 sRGB 可能要整张画一遍，按整幅算。
    static func jpegExport(sources: [URL], options: DeliveryOptions) -> Plan {
        let size = options.sizeValue
        let streams = options.effectiveColor == .keep
        return plan(sources: sources) { width, height, raw in
            path(width: width, height: height, raw: raw,
                 longEdge: size.longEdgeCap(width: Double(width), height: Double(height)),
                 sharpen: options.sharpen, streamsOriginal: streams)
        }
    }

    /// 水印批量（WatermarkEngine.export）：底图按成品尺寸倒推（相框 / 画布会撑大），永远整张合成。
    static func watermark(sources: [URL], config: WatermarkEngine.Config, options: DeliveryOptions) -> Plan {
        let size = options.sizeValue
        return plan(sources: sources) { width, height, raw in
            path(width: width, height: height, raw: raw,
                 longEdge: WatermarkEngine.baseMaxPixel(width: width, height: height, config: config, size: size),
                 sharpen: options.sharpen, streamsOriginal: false)
        }
    }
}
