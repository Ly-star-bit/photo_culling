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

    /// `indices` 里哪几张是「同一帧拆开的那张 RAW」：组里另有一张，isSplitTwin(raw: 它, of: 那张) 成立。去重、提名用它。
    /// 以前是逐对比（每张都把整组扫一遍），一场几百上千张连着拍（相邻都 ≤8 秒，串成一场）时提名一次要比几十万到上千万对，
    /// --verdicts 一个场 100 / 300 / 1000 张是 0.37 / 1.12 / 6.93 G 条指令（优化分析 2026-11-18 edge 复核 N1）。现在不是 RAW 的
    /// 按（拍摄时刻、小数秒、机身）记一张表、RAW 去表里找，结果和逐对比一样：isSplitTwin 只看这三样和两边的扩展名。
    static func splitTwinRaws(_ indices: [Int], in items: [BatchItem]) -> Set<Int> {
        // 先只看拍摄时刻（到小数秒）：同一帧的两张时刻一定一样，时刻跟谁都不撞的照片不用再看扩展名、机身（拖一格阈值滑杆
        // 每一场都要问一遍，几千张时整场算扩展名、建表占提名的大半，优化分析 2026-11-18 PI-04）。
        struct Moment: Hashable {
            let time: Date
            let subsec: Double?
        }
        var moments: [Moment: Int] = [:]
        for idx in indices {
            guard let time = items[idx].captureTime else { continue }
            moments[Moment(time: time, subsec: items[idx].captureSubsec), default: 0] += 1
        }
        let shared = indices.filter { idx in
            guard let time = items[idx].captureTime else { return false }
            return (moments[Moment(time: time, subsec: items[idx].captureSubsec)] ?? 0) > 1
        }
        guard shared.count >= 2 else { return [] }
        return splitTwinRaws(among: shared, in: items)
    }

    /// splitTwinRaws 的后一半：只在拍摄时刻撞了的那几张里认。
    private static func splitTwinRaws(among indices: [Int], in items: [BatchItem]) -> Set<Int> {
        struct Frame: Hashable {
            let time: Date
            let subsec: Double?
            let body: String
        }
        // 按下标就地读字段，不把整张 BatchItem 拷出来（几千张时拷贝本身就显眼）。
        func frame(_ idx: Int) -> Frame? {
            guard let time = items[idx].captureTime else { return nil }
            return Frame(time: time, subsec: items[idx].captureSubsec, body: items[idx].body)
        }
        var raws: [Int] = []
        var others = Set<Frame>()
        for idx in indices {
            guard let key = frame(idx) else { continue }
            if ImageLoader.rawExtensions.contains((items[idx].rawPath as NSString).pathExtension.lowercased()) {
                raws.append(idx)
            } else {
                others.insert(key)
            }
        }
        guard !raws.isEmpty, !others.isEmpty else { return [] }
        return Set(raws.filter { idx in frame(idx).map { others.contains($0) } ?? false })
    }
}
