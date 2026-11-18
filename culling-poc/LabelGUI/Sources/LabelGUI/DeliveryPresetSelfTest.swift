import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 交付的预设，跑在 --delivery-selftest 里（CI 的「自检」步骤）：
/// - 水印页预设带导出设置（优化分析 gap 复核补 2）：存、套用、删、打勾认哪个、落盘再读；老 state.json（预设不带导出设置）
///   套用时不动导出设置；新写的 state.json 里 presets 还是老样子（[名字: 水印参数]，老版本、拼图照样读）。
/// - 水印页「批量导出」还差什么（UX-10）：几样全列、按顺序，签名图勾着没选 PNG 时说清是差签名图。
@MainActor
enum DeliveryPresetSelfTest {
    typealias Check = (Bool, String, String) -> Void

    static func run(_ work: URL, check: Check) {
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        watermarkPresets(work.appendingPathComponent("wm"), check: check)
        watermarkMissing(work.appendingPathComponent("missing"), check: check)
    }

    // MARK: - 水印页预设带导出设置

    private static func watermarkPresets(_ dir: URL, check: Check) {
        let xhs = DeliverySize.box(1080, 1440).spec
        let store = WatermarkStore(dataDir: dir)
        store.config.exifText.enabled = true
        store.options.size = xhs
        store.options.stripGPS = true
        store.savePreset(named: "社交")
        store.options.size = DeliverySize.original.spec
        store.options.stripGPS = false
        store.savePreset(named: "交付")
        check(store.activePresetName == "交付",
              "水印预设：两个预设只差导出尺寸 → 打勾认的是导出设置也一样的那个（以前只比水印参数，勾打在名字排前面的）",
              "认成 \(store.activePresetName ?? "-")")
        store.applyPreset(named: "社交")
        check(store.options.size == xhs && store.options.stripGPS && store.activePresetName == "社交",
              "水印预设：套用「社交」→ 导出尺寸换成小红书、去 GPS 跟着换，勾打在「社交」上",
              "尺寸 \(store.options.size) · 去 GPS \(store.options.stripGPS) · 勾 \(store.activePresetName ?? "-")")
        check(store.presetSummary("社交") == "小红书 3:4" && store.presetSummary("交付") == "原尺寸",
              "水印预设：每行小字写它带的导出尺寸", store.presetSummary("社交") + " / " + store.presetSummary("交付"))

        // 落盘再读（预设是马上写的，不走防抖）。
        let again = WatermarkStore(dataDir: dir)
        check(again.presetOptions["社交"]?.size == xhs && again.presetOptions["交付"]?.size == DeliverySize.original.spec
              && again.presets.count == 2,
              "水印预设：导出设置落盘，重开还在", "\(again.presetOptions.mapValues(\.size))")

        // 新写的 state.json：presets 还是 [名字: 水印参数]（老版本、拼图检视器、--collage 照样读），导出设置在另一个键。
        let statePath = dir.appendingPathComponent("watermark/state.json")
        let raw = (try? Data(contentsOf: statePath))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let presetsOnly = (raw["presets"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode([String: WatermarkEngine.Config].self, from: $0) }
        check(presetsOnly?.count == 2 && raw["presetOptions"] != nil,
              "水印预设：state.json 里 presets 的样子没变（老版本照样读得出两个预设），导出设置单独一个键",
              "presets \(presetsOnly?.count ?? -1) 个 · presetOptions \(raw["presetOptions"] != nil)")

        // 删预设连导出设置一起删。
        again.deletePreset(named: "社交")
        let third = WatermarkStore(dataDir: dir)
        check(third.presets["社交"] == nil && third.presetOptions["社交"] == nil && third.presetOptions["交付"] != nil,
              "水印预设：删了「社交」，它的导出设置也没了，「交付」的还在", "\(third.presetOptions.keys.sorted())")

        // 老版本存的 state.json：预设只有水印参数 → 套用时不动现在的导出设置。
        let oldDir = dir.appendingPathComponent("old")
        try? FileManager.default.createDirectory(at: oldDir.appendingPathComponent("watermark"), withIntermediateDirectories: true)
        var oldConfig = WatermarkEngine.Config()
        oldConfig.frame.enabled = true
        let enc = JSONEncoder()
        let oldState: [String: Any] = [
            "config": (try? JSONSerialization.jsonObject(with: enc.encode(WatermarkEngine.Config()))) ?? [:],
            "options": (try? JSONSerialization.jsonObject(with: enc.encode(DeliveryOptions()))) ?? [:],
            "presets": ["老预设": (try? JSONSerialization.jsonObject(with: enc.encode(oldConfig))) ?? [:]],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: oldState) {
            try? data.write(to: oldDir.appendingPathComponent("watermark/state.json"))
        }
        let old = WatermarkStore(dataDir: oldDir)
        old.options.size = DeliverySize.long(2048).spec
        old.applyPreset(named: "老预设")
        check(old.config.frame.enabled && old.options.size == DeliverySize.long(2048).spec
              && old.presetSummary("老预设") == "不含导出设置" && old.activePresetName == "老预设",
              "水印预设：老 state.json 的预设没带导出设置 → 套用只换水印参数、导出尺寸不动，小字写「不含导出设置」",
              "相框 \(old.config.frame.enabled) · 尺寸 \(old.options.size) · \(old.presetSummary("老预设"))")
        check(old.lastError == nil, "水印预设：老 state.json 读进来不报坏、不挪备份", old.lastError ?? "")
    }

    // MARK: - 水印页「批量导出」还差什么

    private static func watermarkMissing(_ dir: URL, check: Check) {
        let store = WatermarkStore(dataDir: dir)
        let fresh = store.exportMissing
        check(fresh == ["导入照片", "选输出目录", "选一张签名 PNG（或开 EXIF 文字 / 相框）"] && store.needsSignatureFile,
              "还差什么：刚来水印页 → 三样全列（导入照片 · 选输出目录 · 签名 PNG），签名按钮描提醒色",
              fresh.joined(separator: " · "))
        store.config.signatureEnabled = false
        check(store.exportMissing.last == "水印内容（签名图、EXIF 文字、相框至少开一样）" && !store.needsSignatureFile,
              "还差什么：签名图水印关了、别的也没开 → 写「水印内容」，签名按钮不描", store.exportMissing.joined(separator: " · "))
        store.config.exifText.enabled = true
        check(store.exportMissing == ["导入照片", "选输出目录"], "还差什么：开了 EXIF 文字 → 水印内容那样没了",
              store.exportMissing.joined(separator: " · "))
        let photo = dir.appendingPathComponent("a.jpg")
        if let image = tinyImage() { _ = ProofSheetSelfTest.writeJPEG(image, to: photo) }
        store.addPhotos([photo])
        store.outputDir = dir.appendingPathComponent("out")
        check(store.exportMissing.isEmpty && store.canExport, "还差什么：照片、输出目录、水印内容都有 → 不差了，按钮亮",
              store.exportMissing.joined(separator: " · "))
    }

    private static func tinyImage() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return ctx.makeImage()
    }
}
