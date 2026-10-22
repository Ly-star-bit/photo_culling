import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - 交付导出设置（导出 JPG / 精华 Top N / 水印页三个出口共用一份）

/// 三个 JPG 出口共用的导出设置：尺寸、缩小后锐化、色彩、去 GPS、文件名模板、体积上限、质量。
/// 以前三个面板各写各的：只有原尺寸/2048/4096、不锐化、JPG 导出带着 Adobe RGB 和 GPS 原样出去，
/// 精华的文件名和名次无关。水印页的 `WatermarkEngine.ExportOptions` 就是它；state.json 里旧的
/// maxLongSide / filenameSuffix 读进来换算成 size / nameTemplate，老设置导出来的文件名和尺寸不变。
///
/// 默认值是水印页以前的默认（原尺寸、质量 95、后缀 _wm、不去 GPS）；批量页两个出口用
/// `jpegExport` / `highlights` 起自己的默认。
struct DeliveryOptions: Codable, Equatable, Sendable {
    /// 尺寸规格，见 `DeliverySize`："original" / "long:2048" / "short:1200" / "box:1080x1440"。
    var size = DeliverySize.original.spec
    var quality: Double = 0.95
    var sharpen: DeliverySharpen = .standard
    /// nil = 跟着尺寸走（原尺寸保留原色彩空间，其余转 sRGB）。点过才存下来；换尺寸时清回 nil。
    /// 水印页不看它：水印是在 sRGB 画布上合成的，输出永远是 sRGB。
    var color: DeliveryColor?
    var stripGPS = false
    var nameTemplate = DeliveryNaming.originalToken + "_wm"
    var limitSize = false
    var maxMB: Double = 2

    init() {}

    /// 旧版水印设置里的字段：只读不写。
    private enum LegacyKeys: String, CodingKey { case maxLongSide, filenameSuffix }

    /// 逐字段宽松解码（预设要扛得住以后加字段）；缺 size / nameTemplate 时从旧字段换算。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let d = Self()
        let longSide: Int = legacy.lenient(.maxLongSide, 0)
        size = c.lenient(.size, longSide > 0 ? DeliverySize.long(longSide).spec : d.size)
        quality = c.lenient(.quality, d.quality)
        sharpen = c.lenient(.sharpen, d.sharpen)
        color = (try? c.decodeIfPresent(DeliveryColor.self, forKey: .color)) ?? nil
        stripGPS = c.lenient(.stripGPS, d.stripGPS)
        let suffix: String = legacy.lenient(.filenameSuffix, "_wm")
        nameTemplate = c.lenient(.nameTemplate, DeliveryNaming.originalToken + suffix)
        limitSize = c.lenient(.limitSize, d.limitSize)
        maxMB = c.lenient(.maxMB, d.maxMB)
    }

    var sizeValue: DeliverySize { DeliverySize(spec: size) }

    /// 实际用的色彩：没点过就按尺寸 —— 原尺寸（多半是给印厂、给精修）保留，其余（网络 / 微信）转 sRGB。
    var effectiveColor: DeliveryColor { color ?? (sizeValue == .original ? .keep : .srgb) }

    /// 体积上限（字节）；没开 = nil。按访达的算法 1 MB = 1000 × 1000。
    var maxBytes: Int? {
        guard limitSize, maxMB > 0 else { return nil }
        return Int(maxMB * 1_000_000)
    }

    /// 导出 JPG 的默认：以前存的长边（0/2048/4096）和质量（60–100）换算过来，文件名就是原名。
    static func jpegExport(legacyMaxPixel: Int, legacyQuality: Double) -> DeliveryOptions {
        var o = DeliveryOptions()
        o.size = DeliverySize.legacy(maxPixel: legacyMaxPixel).spec
        o.quality = min(1, max(0.6, legacyQuality / 100))
        o.nameTemplate = DeliveryNaming.originalToken
        return o
    }

    /// 精华 Top N 的默认：当天公开发的那一把 —— 去 GPS、按名次起名（按文件名排序上传就是名次顺序）。
    static func highlights(legacyMaxPixel: Int) -> DeliveryOptions {
        var o = DeliveryOptions()
        o.size = DeliverySize.legacy(maxPixel: legacyMaxPixel).spec
        o.quality = 0.9
        o.stripGPS = true
        o.nameTemplate = "{名次:2}_" + DeliveryNaming.originalToken
        return o
    }

    /// @AppStorage 里存的 JSON → 设置。存的字段盖在 `defaults` 上（缺的字段用这个出口自己的默认，
    /// 不是水印页的）；空串 / 坏了 = 直接用 defaults。
    static func load(_ raw: String, defaults: DeliveryOptions) -> DeliveryOptions {
        guard !raw.isEmpty, let stored = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any]
        else { return defaults }
        let merged = base.merging(stored) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let options = try? JSONDecoder().decode(DeliveryOptions.self, from: data) else { return defaults }
        return options
    }

    /// 存进 @AppStorage 的 JSON。
    var stored: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// 缩小后的输出锐化（Lightroom「输出锐化 · 屏幕」那几档）。只在输出比原图小时做；原尺寸从来不锐化。
enum DeliverySharpen: String, Codable, CaseIterable, Sendable {
    case off, standard, high

    var label: String {
        switch self {
        case .off: return "不锐化"
        case .standard: return "屏幕·标准"
        case .high: return "屏幕·高"
        }
    }

    /// (半径 px, 强度)；nil = 不锐化。标准 = 检视器同一刀（SharpRenderer 的 0.8px / 0.4），高 = 同半径加到 0.7。
    /// DSCF7207 长边 2048 的梯度 RMS：不锐化 16.2 · 标准 21.7 · 高 24.5（高放大 4 倍看边缘没有明显光晕）。
    var unsharp: (radius: Double, intensity: Double)? {
        switch self {
        case .off: return nil
        case .standard: return (SharpRenderer.unsharpRadius, SharpRenderer.unsharpIntensity)
        case .high: return (SharpRenderer.unsharpRadius, 0.7)
        }
    }
}

enum DeliveryColor: String, Codable, CaseIterable, Sendable {
    case srgb, keep

    var label: String {
        switch self {
        case .srgb: return "sRGB（网络 / 微信）"
        case .keep: return "保留原色彩空间（印刷）"
        }
    }
}

// MARK: - 尺寸

/// 输出尺寸。框（box）是「放进这个框」：不裁、不放大，横图竖图都按同一个框（平台的宽都是 1080）。
enum DeliverySize: Equatable, Sendable {
    case original
    case long(Int)
    case short(Int)
    case box(Int, Int)

    struct Preset: Identifiable {
        let id: String
        let label: String
        let size: DeliverySize
    }

    /// 平台规格表：要加一个平台就在这里加一行（界面的菜单、命令行 --size 的名字都从这里来）。
    static let presets: [Preset] = [
        Preset(id: "original", label: "原尺寸", size: .original),
        Preset(id: "4096", label: "长边 4096（屏幕交付）", size: .long(4096)),
        Preset(id: "2048", label: "长边 2048（微博 / 选片）", size: .long(2048)),
        Preset(id: "moments", label: "朋友圈 长边 1080", size: .long(1080)),
        Preset(id: "xhs", label: "小红书 3:4（1080×1440 以内）", size: .box(1080, 1440)),
        Preset(id: "ig", label: "Instagram 4:5（1080×1350 以内）", size: .box(1080, 1350)),
    ]

    init(spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        let value = parts.count == 2 ? parts[1] : ""
        switch parts.first ?? "" {
        case "long" where (Int(value) ?? 0) > 0: self = .long(Int(value)!)
        case "short" where (Int(value) ?? 0) > 0: self = .short(Int(value)!)
        case "box":
            let wh = value.split(separator: "x").compactMap { Int($0) }
            self = wh.count == 2 && wh[0] > 0 && wh[1] > 0 ? .box(wh[0], wh[1]) : .original
        default:
            // 命令行也认预设名（--size xhs）。
            self = Self.presets.first { $0.id == spec }?.size ?? .original
        }
    }

    var spec: String {
        switch self {
        case .original: return "original"
        case .long(let n): return "long:\(n)"
        case .short(let n): return "short:\(n)"
        case .box(let w, let h): return "box:\(w)x\(h)"
        }
    }

    /// 以前存的「长边」：0 = 原尺寸，2048 / 4096 正好是两个预设。
    static func legacy(maxPixel: Int) -> DeliverySize { maxPixel > 0 ? .long(maxPixel) : .original }

    /// 这张图要缩到的长边；nil = 不缩（原尺寸，或者源图本来就放得进去 —— 绝不放大）。
    /// long:N 照旧总是 N：以前「长边 N」就是不管大小都走缩略图那条路，结果一个字节都不能变。
    func longEdgeCap(width: Double, height: Double) -> Int? {
        let long = max(width, height), short = min(width, height)
        let scale: Double
        switch self {
        case .original: return nil
        case .long(let n): return n
        case .short(let n):
            guard long > 0, Double(n) < short else { return nil }
            return Self.longEdge(forShort: n, long: long, short: short)
        case .box(let w, let h): scale = min(Double(w) / width, Double(h) / height)
        }
        guard long > 0, scale < 1 else { return nil }
        // 向下取整保证放得进框；加一点点是给浮点误差的（10304 × 1440/10304 算出来是 1439.99999…）。
        return max(1, Int((long * scale + 1e-6).rounded(.down)))
    }

    /// 短边正好是 n 的长边。缩图（ImageIO 和 deliveryDownscale 都一样）是给长边、短边按比例四舍五入；
    /// 以前长边向下取整，5001×3999 要短边 1200 出来是 1500×1199。取最接近的长边，再左右挪一步核对。
    private static func longEdge(forShort n: Int, long: Double, short: Double) -> Int {
        func shortSide(_ edge: Int) -> Int { Int((short * Double(edge) / long).rounded()) }
        let guess = max(1, Int((Double(n) * long / short).rounded()))
        return [guess, guess - 1, guess + 1].first { $0 >= 1 && shortSide($0) == n } ?? guess
    }

    /// 已经出来的图还超出多少：nil = 放得下；否则按这个比例再缩一次（四舍五入多出来的一两个像素）。
    func shrinkRatio(width: Int, height: Int) -> Double? {
        let long = max(width, height), short = min(width, height)
        switch self {
        case .original: return nil
        case .long(let n): return long > n ? Double(n) / Double(long) : nil
        case .short(let n): return short > n ? Double(n) / Double(short) : nil
        case .box(let w, let h):
            let ratio = min(Double(w) / Double(width), Double(h) / Double(height))
            return ratio < 1 ? ratio : nil
        }
    }
}

// MARK: - 文件名模板

/// 三个出口共用的文件名模板：{原名} {序号:3} {日期} {名次:2} {相机} {星级}，「:3」= 补零到 3 位。
/// 文字部分里的 / : 和控制字符去掉（原名本来就是合法文件名，原样用 —— 默认模板出来的名字和以前逐字一样）。
enum DeliveryNaming {
    static let originalToken = "{原名}"
    static let tokensHint = "可用 {原名} {序号:3} {日期} {相机} {星级}"
    static let rankTokenHint = "可用 {名次:2} {原名} {序号:3} {日期} {相机} {星级}"

    struct Fields {
        var original: String
        var index: Int
        var date: Date? = nil
        /// 精华 Top N 的名次；别的出口没有（{名次} 留空）。
        var rank: Int? = nil
        var camera: String? = nil
        var stars: Int? = nil
    }

    /// 模板里有没有用到某个字段（读 EXIF / 星级要开文件，用不到就不读）。
    static func uses(_ template: String, _ token: String) -> Bool { template.contains("{" + token) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    static func render(_ template: String, _ fields: Fields) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += sanitized(String(rest[..<open]))
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let token = rest[rest.index(after: open)..<close]
            out += value(of: token, fields) ?? sanitized(String(rest[open...close]))
            rest = rest[rest.index(after: close)...]
        }
        out += sanitized(String(rest))
        // 「.」开头会变成隐藏文件（原名本来就是的不动）；全空了就退回原名；文件名上限 255 字节
        // （中文 3 字节一个），留出 -2 和 .jpg。
        while out.hasPrefix("."), !fields.original.hasPrefix(".") { out.removeFirst() }
        if out.trimmingCharacters(in: .whitespaces).isEmpty { return fields.original }
        while out.utf8.count > 240, out != fields.original { out.removeLast() }
        return out
    }

    /// 一个 {…} 的值；不认识的名字返回 nil（原样当文字留着）。
    private static func value(of token: Substring, _ f: Fields) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard let name = parts.first else { return nil }
        let width = parts.count == 2 ? Int(parts[1]) : nil
        func padded(_ n: Int) -> String {
            let s = String(n)
            return String(repeating: "0", count: max(0, (width ?? 0) - s.count)) + s
        }
        switch name {
        case "原名": return f.original
        case "序号": return padded(f.index)
        case "名次": return f.rank.map(padded) ?? ""
        case "日期": return f.date.map { dayFormatter.string(from: $0) } ?? ""
        case "相机": return sanitized(f.camera ?? "")
        case "星级": return f.stars.map { String(max(0, $0)) } ?? ""
        default: return nil
        }
    }

    /// 文件名里不能有的：/ 会跑到别的目录，: 在访达里变成 /，控制字符（换行）。
    static func sanitized(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0) })
    }

    /// 文件名 → 目标路径。批内重名（APFS 默认不分大小写，按小写比）一律另存 -2、-3；目标里已经有的，
    /// `overwrite` 关着也另存 -2（旧文件不动），开着才覆盖。`renamed` = 因为目标里已有而改名的张数。
    static func plan(_ names: [String], in folder: URL, overwrite: Bool) -> (dests: [URL], renamed: Int) {
        let fm = FileManager.default
        var used = Set<String>()
        var dests: [URL] = []
        var renamed = 0
        for name in names {
            let first = folder.appendingPathComponent("\(name).jpg")
            var dest = first
            var n = 2
            while used.contains(dest.standardizedFileURL.path.lowercased())
                    || (!overwrite && fm.fileExists(atPath: dest.path)) {
                dest = folder.appendingPathComponent("\(name)-\(n).jpg")
                n += 1
            }
            if dest != first, fm.fileExists(atPath: first.path) { renamed += 1 }
            used.insert(dest.standardizedFileURL.path.lowercased())
            dests.append(dest)
        }
        return (dests, renamed)
    }

    /// 文件的星级（xmp:Rating）；水印页的照片不在选片场次里，只能看文件。旁边有同名 .xmp 的先看它（本工具
    /// 「写 XMP」、LR / C1 都写在这里，相机嵌在 JPEG 里的多半是 0），没有再看文件里嵌的。
    static func fileRating(_ url: URL) -> Int? {
        func rating(_ meta: CGImageMetadata) -> Int? {
            (CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?).flatMap { Int($0) }
        }
        let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
        if let data = try? Data(contentsOf: sidecar), let tree = WatermarkEngine.metadataTree(fromXMP: data),
           let stars = rating(tree) { return stars }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return nil }
        return rating(meta)
    }
}

// MARK: - 编码（体积上限）

enum DeliveryEncoder {
    /// 压到这个质量还超就不再压了（再低就花了），照这个质量写出去并报出来。
    static let floorQuality = 0.4

    enum Outcome: Sendable { case ok, overLimit, failed }

    /// 收尾时点名压不到上限的那几张（文件照最低质量写出去了）。
    static func overLimitNote(_ names: [String], maxMB: Double) -> String {
        let list = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
        return "\(names.count) 张压到最低质量 \(Int(floorQuality * 100)) 还是超过 \(String(format: "%g", maxMB)) MB"
            + "（已按最低质量写出）：\(list)"
    }

    /// `add` 往 destination 里加图（带属性字典或元数据树，两条出口加法不同），参数是这次的质量。
    /// 没有上限 = 和以前一样直接写文件；有上限 = 先在内存里编码，超了就在 [最低, 设定] 之间二分质量
    /// （最多 7 次编码），取放得下的最高质量。
    static func write(to dest: URL, quality: Double, maxBytes: Int?,
                      add: (CGImageDestination, Double) -> Void) -> Outcome {
        guard let maxBytes else {
            guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return .failed }
            add(out, quality)
            return CGImageDestinationFinalize(out) ? .ok : .failed
        }
        func encode(_ q: Double) -> Data? {
            let data = NSMutableData()
            guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            add(out, q)
            return CGImageDestinationFinalize(out) ? data as Data : nil
        }
        guard var best = encode(quality) else { return .failed }
        var fits = best.count <= maxBytes
        if !fits, quality > floorQuality, let floor = encode(floorQuality) {
            best = floor
            fits = floor.count <= maxBytes
            if fits {
                var lo = floorQuality, hi = quality
                for _ in 0..<5 {
                    let mid = (lo + hi) / 2
                    guard let data = encode(mid) else { break }
                    if data.count <= maxBytes { best = data; lo = mid } else { hi = mid }
                }
            }
        }
        do { try best.write(to: dest, options: .atomic) } catch { return .failed }
        return fits ? .ok : .overLimit
    }
}

// MARK: - 屏幕输出锐化（检视器 / 审片 / 交付导出）

/// Capture One / Lightroom 那套"屏幕输出锐化"管线：Lanczos 精确缩到取景区的
/// **设备像素**尺寸，再过一次轻量 unsharp mask。
///
/// 缩小本身必然让图变软，这是数学上的事；C1 的 Output Sharpening、LR 的
/// "屏幕输出锐化"、PS 的 Bicubic Sharper 全是"缩完补一刀"。以前我们把 4096 的
/// 解码交给合成器随手缩，既没有 Lanczos 也没有这一刀，看着就是不如 C1 精神。
/// 交付导出（JPG / 精华 / 水印页）缩小时走同一刀（`deliveryDownscale`）。
enum SharpRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// 半径按设备像素算：0.8px / 0.4 是 LR "屏幕·标准" 那档的量，只提边缘不出光晕。
    static let unsharpRadius = 0.8
    static let unsharpIntensity = 0.4

    /// 目标长边按 256 取整：窗口拖一像素不该重渲染，检视器和审片的取景区大小
    /// 接近时也能共用同一张。
    static func bucket(_ devicePixels: CGFloat) -> Int {
        max(256, Int((devicePixels / 256).rounded(.up)) * 256)
    }

    /// 只缩不放：源图比目标小时按原尺寸只做锐化，绝不把图放大来凑。
    static func render(_ source: NSImage, longEdge: Int) -> NSImage? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, CGFloat(longEdge) / max(w, h))
        let extent = CGRect(x: 0, y: 0, width: (w * scale).rounded(), height: (h * scale).rounded())
        var image = CIImage(cgImage: cg)
        if scale < 1 {
            guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
            // clampedToExtent：Lanczos 采样会越过边界，不钳住的话四周一圈发暗。
            lanczos.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            lanczos.setValue(scale, forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard let scaled = lanczos.outputImage else { return nil }
            image = scaled.cropped(to: extent)
        }
        guard let usm = CIFilter(name: "CIUnsharpMask") else { return nil }
        usm.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        usm.setValue(unsharpRadius, forKey: kCIInputRadiusKey)
        usm.setValue(unsharpIntensity, forKey: kCIInputIntensityKey)
        guard let sharpened = usm.outputImage?.cropped(to: extent),
              let out = context.createCGImage(sharpened, from: extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    /// 交付导出的缩小 + 锐化：ImageIO 先解到目标的 1.5 倍（转正；JPEG 走 DCT 缩放，61MP 也不用整张解），
    /// Lanczos 精确缩到长边 `longEdge`，再按档位补一刀 USM。`keepColor` = 按源图的色彩空间出图（保留
    /// Adobe RGB / P3），否则真转换到 sRGB（CIContext 渲染时做色彩匹配，不是只改标签）。
    /// 返回的 fullWidth/fullHeight 是转正后的全尺寸（水印页按它折算像素单位的参数）。
    /// `assumeSpace`：ImageIO 当成 sRGB 解、其实是别的色彩空间（相机直出的 Adobe RGB，见 `cameraAdobeRGB`）。
    static func deliveryDownscale(_ source: CGImageSource, longEdge: Int, sharpen: DeliverySharpen,
                                  keepColor: Bool, assumeSpace: CGColorSpace? = nil) -> WatermarkEngine.DecodedBase? {
        guard let full = WatermarkEngine.uprightSize(of: source) else { return nil }
        let fullLong = max(full.width, full.height)
        // 中间图解到目标的 1.5 倍就够 Lanczos 用。以前解到 2 倍：长边 2048 要 4096，比 7728 的一半还大，
        // ImageIO 只能整张解完再缩，4 个 worker 峰值近 2 GB、比不锐化慢一倍多；1.5 倍 = 3072，JPEG 先按 DCT
        // 解一半再缩，峰值和耗时都减半，锐度几乎一样（DSCF7207 标准档梯度 RMS 22.0 → 21.7）。
        // 1.5 倍也超过一半（长边 4096）时反正要整张解，就直接用整张，省掉 ImageIO 那一遍缩放。
        let wanted = longEdge * 3 / 2
        guard longEdge < fullLong,
              let raw = WatermarkEngine.decodeUpright(source, maxPixel: wanted > fullLong / 2 ? fullLong : wanted)?.image
        else { return nil }
        let decoded = retagged(raw, as: assumeSpace)
        // 目标尺寸按全尺寸算（和 ImageIO 直接缩到 longEdge 的结果一样大），不按中间那张的取整。
        let w = Double(decoded.width), h = Double(decoded.height)
        let scale = Double(longEdge) / Double(fullLong)
        let outW = max(1, Int((Double(full.width) * scale).rounded()))
        let outH = max(1, Int((Double(full.height) * scale).rounded()))
        let extent = CGRect(x: 0, y: 0, width: outW, height: outH)
        var image = CIImage(cgImage: decoded)
        if outW < decoded.width || outH < decoded.height {
            guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
            lanczos.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            lanczos.setValue(Double(outH) / h, forKey: kCIInputScaleKey)
            lanczos.setValue((Double(outW) / w) / (Double(outH) / h), forKey: kCIInputAspectRatioKey)
            guard let scaled = lanczos.outputImage else { return nil }
            image = scaled.cropped(to: extent)
        }
        if let amount = sharpen.unsharp, let usm = CIFilter(name: "CIUnsharpMask") {
            usm.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            usm.setValue(amount.radius, forKey: kCIInputRadiusKey)
            usm.setValue(amount.intensity, forKey: kCIInputIntensityKey)
            guard let sharpened = usm.outputImage else { return nil }
            image = sharpened.cropped(to: extent)
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = keepColor && decoded.colorSpace?.model == .rgb ? decoded.colorSpace ?? sRGB : sRGB
        guard let out = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: space) else { return nil }
        return WatermarkEngine.DecodedBase(image: out, fullWidth: full.width, fullHeight: full.height)
    }

    /// 相机设成 Adobe RGB 直出的 JPEG（DCF 选项文件）：不嵌 ICC，只在 EXIF 里写 ColorSpace = 0xFFFF（未校准），
    /// 外加互通 IFD 里的 R03。ImageIO 不认这一套，当成 sRGB 解 —— 「转 sRGB」什么也没转就标成 sRGB，出来发灰。
    /// 没嵌 ICC、又写着未校准的 JPEG，按 Adobe RGB 认（返回它）；其余 nil。
    static func cameraAdobeRGB(_ src: CGImageSource, url: URL, props: [CFString: Any]) -> CGColorSpace? {
        guard (CGImageSourceGetType(src) as String?) == UTType.jpeg.identifier,
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              (exif[kCGImagePropertyExifColorSpace] as? Int) == 0xFFFF,
              WatermarkEngine.jpegSegment(of: url, marker: 0xE2, header: Data("ICC_PROFILE\0".utf8)) == nil
        else { return nil }
        return CGColorSpace(name: CGColorSpace.adobeRGB1998)
    }

    /// ImageIO 当成 sRGB 解出来的图换回该有的色彩空间（只换标签，像素不动；后面转 sRGB 时才真转换）。
    static func retagged(_ image: CGImage, as space: CGColorSpace?) -> CGImage {
        guard let space, image.colorSpace?.name == CGColorSpace.sRGB else { return image }
        return image.copy(colorSpace: space) ?? image
    }

    /// 要不要转 sRGB：已经是 sRGB、灰度图（没有色域可言）、读不出色彩空间的都不动。
    static func needsSRGBConversion(_ space: CGColorSpace?) -> Bool {
        guard let space, space.model != .monochrome else { return false }
        return space.name != CGColorSpace.sRGB
    }

    /// 真转换到 sRGB：画进 sRGB 画布（ColorSync 做色彩匹配），和水印页合成走的是同一种转换。
    static func convertedToSRGB(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

private extension KeyedDecodingContainer {
    /// 字段缺失或类型不对 → 用默认值。
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
