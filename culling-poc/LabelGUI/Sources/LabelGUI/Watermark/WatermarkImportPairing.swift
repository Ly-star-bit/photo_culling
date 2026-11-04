import Foundation

/// 水印页导入照片时的 RAW+JPG 配对。规则和 ImageLoader.listPhotos 一样：同一个目录里去掉扩展名同名
/// （`deletingPathExtension().path`）的 RAW 和非 RAW 是同一张，留非 RAW（机内 JPG / HEIF，颜色就是相机冲的）；
/// 同类同名（IMG_0001.HEIC + IMG_0001.JPG、RAF 旁边一张 DNG）不配对，各自保留。
/// 以前 addPhotos 只看扩展名，RAW+JPG 双存的文件夹拖进来每张两条，导出 X_wm.jpg 和 X_wm-2.jpg 两份，
/// 后一份是 ImageIO 默认冲洗的 RAW。列表里已有的也算：先 JPG 后 RAW 跳过 RAW；先 RAW 后 JPG 用 JPG 原地换掉 RAW。
enum WatermarkImportPairing {
    struct Merge {
        /// 合并以后的列表（原有顺序不变，新的接在后面；被换掉的 RAW 原地换成 JPG）。
        var photos: [URL]
        /// 新加进列表的张数（原地换掉的不算）。
        var added = 0
        /// 列表里原有的 RAW 被这一批里的同名非 RAW 换掉：(旧, 新)。
        var replaced: [(old: URL, new: URL)] = []
        /// 没收的 RAW：同名非 RAW 已经在列表里，或者这一批里也有。
        var skippedRaw = 0
        /// 这一批新进列表、没有同名非 RAW 的 RAW（导出按 ImageIO 默认冲洗）。
        var rawOnly = 0
    }

    static func key(_ url: URL) -> String { url.deletingPathExtension().path }

    static func isRaw(_ url: URL) -> Bool {
        ImageLoader.rawExtensions.contains(url.pathExtension.lowercased())
    }

    /// existing = 列表里已有的，incoming = 这一次要导入的（已经按扩展名筛过）。同一个文件已经在列表里照旧不重复收。
    static func merge(existing: [URL], incoming: [URL]) -> Merge {
        var slots: [URL?] = existing
        var listed = Set(existing.map(\.path))
        // 列表里已有非 RAW 的 key；还没配上非 RAW 的 RAW 在 slots 里的位置。
        var nonRawKeys = Set<String>()
        var rawSlots: [String: [Int]] = [:]
        for (index, url) in existing.enumerated() {
            if isRaw(url) {
                rawSlots[key(url), default: []].append(index)
            } else {
                nonRawKeys.insert(key(url))
            }
        }
        for k in nonRawKeys { rawSlots[k] = nil }

        var added = 0
        var skippedRaw = 0
        var replaced: [(old: URL, new: URL)] = []
        var addedRaw = Set<String>()  // 这一批收进来的 RAW（path）
        let existingCount = existing.count
        for url in incoming {
            guard !listed.contains(url.path) else { continue }
            let k = key(url)
            if isRaw(url) {
                if nonRawKeys.contains(k) {
                    // 记进 listed：同一张 RAW 在这一批里出现两次（文件夹 + 里面的文件一起拖）只算一次跳过。
                    listed.insert(url.path)
                    skippedRaw += 1
                    continue
                }
                rawSlots[k, default: []].append(slots.count)
                slots.append(url)
                listed.insert(url.path)
                addedRaw.insert(url.path)
                added += 1
                continue
            }
            nonRawKeys.insert(k)
            guard let rawIndices = rawSlots.removeValue(forKey: k), !rawIndices.isEmpty else {
                slots.append(url)
                listed.insert(url.path)
                added += 1
                continue
            }
            // 同名 RAW 在列表里：第一张原地换成这张（不算新加的一行），其余同名 RAW（RAF + DNG 都在）
            // 也是同一张，去掉。这一批里先到的 RAW 对用户来说就是没收：记进 skippedRaw，不记 replaced。
            listed.insert(url.path)
            for (n, index) in rawIndices.enumerated() {
                guard let old = slots[index] else { continue }
                // old 留在 listed 里：同一批里再来一次（拖了文件夹又拖里面的文件）就照「已在列表」不吭声，
                // 不会再记一次跳过。
                slots[index] = n == 0 ? url : nil
                guard index >= existingCount else {
                    replaced.append((old, url))
                    continue
                }
                addedRaw.remove(old.path)
                skippedRaw += 1
                // 第一张那一行留给了 JPG，还算新加的；其余的行没了。
                if n > 0 { added -= 1 }
            }
        }
        let photos = slots.compactMap { $0 }
        let rawOnly = photos.reduce(0) { $0 + (addedRaw.contains($1.path) ? 1 : 0) }
        return Merge(photos: photos, added: added, replaced: replaced, skippedRaw: skippedRaw, rawOnly: rawOnly)
    }

    /// 导入以后那一行提示。requested = 这次确实给了东西（全都进不来时要说清楚）。nil = 不提示。
    static func notice(for merge: Merge, requested: Bool) -> String? {
        var parts: [String] = []
        if merge.added > 0 { parts.append("已导入 \(merge.added) 张") }
        if !merge.replaced.isEmpty { parts.append("\(merge.replaced.count) 张 RAW 换成了同名 JPG") }
        if merge.skippedRaw > 0 {
            let lead: String = parts.isEmpty ? "没有新照片：" : ""
            parts.append(lead + "跳过 \(merge.skippedRaw) 张同名 RAW（RAW+JPG 只留 JPG，和选片页一样）")
        }
        if merge.rawOnly > 0 { parts.append("\(merge.rawOnly) 张只有 RAW，按系统默认冲洗导出") }
        if parts.isEmpty {
            // 一张都没进来时说清楚，别让按钮显示着数量、列表却纹丝不动。
            return requested ? "没有可导入的照片 (格式不支持，或已经在列表里)" : nil
        }
        return parts.joined(separator: " · ")
    }
}
