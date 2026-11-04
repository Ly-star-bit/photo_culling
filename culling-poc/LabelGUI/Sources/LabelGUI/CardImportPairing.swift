import Foundation
import ImageIO

// MARK: - 存储卡导入：RAW、JPG 分卡存时认出「同一帧」
//
// 机身设成 RAW、JPG 分卡存（佳能「分别记录」、索尼「分类(JPEG/RAW)」、尼康「卡槽 1 RAW / 卡槽 2 JPEG」）时，
// 第二张卡上的 DSC0001.JPG 导进来，目标里同主名只有第一张卡的 DSC0001.ARW。它们是不是同一帧，文件名说明
// 不了（两台同号机身、编号转了一圈都会撞名），只能看文件头：拍摄时间（到 SubSec）、型号、机身序列号全对得上、
// 两边序列号都有，才算同一帧。任何一样读不到就不算 —— 宁可改名多一张，也不能把两台机身的 RAW、JPG 拼成一张。
extension CardImporter {
    /// 一帧的身份（都从文件头读，不解码）。
    struct FrameIdentity: Equatable {
        let dateTimeOriginal: String
        let subsec: String
        let model: String
        let serial: String
    }

    /// 读不到任何一样（没 EXIF、没 SubSec、没型号、没写序列号）= nil。只读文件。
    static func frameIdentity(of url: URL) -> FrameIdentity? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        func text(_ value: Any?) -> String? {
            let raw = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let time = text(exif?[kCGImagePropertyExifDateTimeOriginal]),
              let subsec = text(exif?[kCGImagePropertyExifSubsecTimeOriginal]),
              let model = text(tiff?[kCGImagePropertyTIFFModel]),
              let serial = ImageLoader.bodySerial(in: props), !serial.isEmpty else { return nil }
        return FrameIdentity(dateTimeOriginal: time, subsec: subsec, model: model, serial: serial)
    }

    /// 配对用的「类」：true = RAW、false = JPG 这一类（HEIF、TIFF……），nil = 分析不认的格式（不参与配对）。
    /// 和 ImageLoader.listPhotos 的规则一样：一个 RAW 配一个非 RAW。
    static func pairKind(_ ext: String) -> Bool? {
        let e = ext.lowercased()
        guard ImageLoader.imageExtensions.contains(e) else { return nil }
        return ImageLoader.rawExtensions.contains(e)
    }
}
