import AppKit
import CoreGraphics
import ImageIO

// MARK: - 选片确认表的水印（导出菜单「带水印（用水印页的签名）」，默认关）

/// 确认表小样上的水印：水印页的签名和文字，裁成一个低调的左下角标 —— 右上角压着客户点的 ♥，斜纹平铺 / 居中会挡脸，
/// 客户就挑不了片了。相框、画布比例会改画布尺寸，强制关（和带进拼图一样只收签名和文字）。
/// 主线程从水印页拍快照（WatermarkStore.proofWatermark()），交给后台每张 800px 小样在内存里画一遍：
/// 预览文件（previewPath）一个字节不动，编号、表号、proof_sheets.json 也都不受影响。
/// @unchecked：CGImage 不是 Sendable，可拍完快照以后谁都不改它。
struct ProofWatermark: @unchecked Sendable {
    let config: WatermarkEngine.Config
    let signature: CGImage?

    /// 不透明度最高到这（水印页设得再实，确认表上也是淡淡的一个角标）。
    static let opacityCap = 0.5
    /// 签名最宽占短边的比例（水印页默认 0.15）。
    static let sizeRatioCap = 0.2
    /// 读不到原片尺寸时按这个长边算像素边距（常见相机 6000×4000）。
    static let assumedLongEdge = 6000

    /// 水印页的设置 → 确认表的角标：签名、文字都挪到左下，不平铺，淡一点；frame、canvasRatio 关掉。
    /// 签名关着、或者签名图读不出来就只画文字；两样都没有 = nil（没东西可画）。
    static func make(config: WatermarkEngine.Config, signature: CGImage?) -> ProofWatermark? {
        var c = config
        c.frame.enabled = false
        c.canvasRatio.enabled = false
        c.tile.enabled = false
        c.position = .bottomLeft
        c.landscapeOverrideEnabled = false
        c.opacity = min(c.opacity, opacityCap)
        c.sizeRatio = min(c.sizeRatio, sizeRatioCap)
        c.exifText.position = .bottomLeft
        c.exifText.opacity = min(c.exifText.opacity, opacityCap)
        let sig = c.signatureEnabled ? signature : nil
        c.signatureEnabled = sig != nil
        guard c.signatureEnabled || c.exifText.enabled else { return nil }
        return ProofWatermark(config: c, signature: sig)
    }

    /// 在一张小样上画（不改 `image`，返回新的一张；画不上 = nil）。`original` = 原片路径：水印页的像素边距是按原片给的，
    /// 按「小样长边 / 原片长边」缩；文字模板（{model} 这些）的 EXIF 也从原片读（1024 预览不一定带 EXIF）。都只读文件头。
    /// 真画上了东西才算画上：只开了 EXIF 文字模板、原片读不到（外接盘没插）或者没有 EXIF 时模板填出来是空的，一个字都不画；
    /// 签名比画面还大被跳过的也一样 —— 都返回 nil（这张不放进确认表），以前照样把干净的小样交回去、状态栏还写「带水印」。
    func apply(to image: CGImage, original: String) -> CGImage? {
        let source = original.isEmpty ? nil : CGImageSourceCreateWithURL(URL(fileURLWithPath: original) as CFURL, nil)
        let full = source.flatMap { WatermarkEngine.uprightSize(of: $0) }
        let baseLong = max(image.width, image.height)
        let fullLong = full.map { max($0.width, $0.height) } ?? Self.assumedLongEdge
        let scale = CGFloat(baseLong) / CGFloat(max(fullLong, baseLong))
        let needsTags = config.exifText.enabled && config.exifText.customText.isEmpty
        let tags = WatermarkEngine.ExifTags(source: needsTags ? source : nil)
        let text = drawsText(tags)
        if signature == nil && !text { return nil }
        guard let composed = WatermarkEngine.compose(base: image, signature: signature, config: config, tags: tags,
                                                     scale: scale) else { return nil }
        guard text || !composed.signatureSkipped else { return nil }
        return composed.image
    }

    /// 文字会不会画出来：自定义文字不是空的，或者模板按这张的 EXIF 填出来不是空的（和 WatermarkEngine.layoutExifText 同一个判断）。
    func drawsText(_ tags: WatermarkEngine.ExifTags) -> Bool {
        guard config.exifText.enabled else { return false }
        let custom = config.exifText.customText
        let text = custom.isEmpty ? tags.fillStripMissing(template: config.exifText.template) : custom
        return !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 只靠 EXIF 文字模板（没签名、没写自定义文字）：画什么要看每张原片里的相机参数，原片读不到、没有 EXIF 的画不上。
    var needsOriginalEXIF: Bool { signature == nil && config.exifText.enabled && config.exifText.customText.isEmpty }

    /// 有几张画不上水印时状态栏上说的原因。
    var skipReason: String {
        needsOriginalEXIF
            ? "水印只开了 EXIF 参数文字，要读原片里的相机参数：原片读不到（外接盘没插？）或没有 EXIF 的画不上 —— " +
              "插上原片所在的盘，或在水印页写一句自定义文字 / 选签名"
            : "预览读不出来或水印画不上"
    }
}

// MARK: - 导出选片确认表：保存面板下面的「套餐含 N 张」

/// 保存面板下面那一行：「套餐含 [  ] 张 · 选超了只提示、不拦」。默认填这一场上次导出那张表的张数（每单的套餐不一样，
/// 不跨场次记）；空着 = 不限。
@MainActor
final class ProofSheetSaveAccessory {
    let view: NSView
    private let field: NSTextField

    init(quota: Int?) {
        let label = NSTextField(labelWithString: "套餐含")
        field = NSTextField(string: quota.map(String.init) ?? "")
        field.placeholderString = "不限"
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let unit = NSTextField(labelWithString: "张 · 客户选超了只提示、不拦（超出的算加片），空着 = 不限")
        unit.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, field, unit])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        view = row
    }

    /// 填的张数；没填、不是正整数 = nil（不限）。
    var quota: Int? { Self.parse(field.stringValue) }

    nonisolated static func parse(_ text: String) -> Int? {
        let digits = ClientReply.halfwidth(text).trimmingCharacters(in: .whitespaces)
        guard let n = Int(digits), n > 0 else { return nil }
        return min(n, 9999)
    }
}
