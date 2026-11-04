import Foundation

extension BatchStore {
    /// `raw` 和 `other` 是同一帧被拆成的两张（RAW、JPG 分卡存 / 分文件夹放，listPhotos 只在同目录同主名时配对）：
    /// `raw` 是 RAW、`other` 不是，拍摄时刻（含小数秒、机身对时）和机身都一样。近似重复去重时护着 RAW（审查 M01 后半）：
    /// 它输给自己那张 JPG 被判「连拍重复」的话，「移到废纸篓」会把这一帧唯一的 RAW 挪走。
    /// 跨目录配对要改 id、要迁移（M01 的 L 部分），这里只是去重的一道防线。
    static func isSplitTwin(raw: BatchItem, of other: BatchItem) -> Bool {
        guard let time = raw.captureTime, time == other.captureTime, raw.captureSubsec == other.captureSubsec,
              raw.body == other.body else { return false }
        let rawExt = (raw.rawPath as NSString).pathExtension.lowercased()
        let otherExt = (other.rawPath as NSString).pathExtension.lowercased()
        return ImageLoader.rawExtensions.contains(rawExt) && !ImageLoader.rawExtensions.contains(otherExt)
    }
}
