import Foundation

/// 同一个 .xmp 对应几张照片（2026-11 审查 S09）：listPhotos 把同目录、同名、同一类的第二个文件单独成片（HEIC+JPG、
/// RAF 旁边转出来的 DNG、JPG+同名 TIF），它们的 sidecar 都是「去扩展名 + .xmp」那一个文件 —— 写 XMP 时后写的盖掉先写的
/// 星级色标、两张都记成已同步；移废片时其中一张把共用的 .xmp（可能是另一张的 LR 调色）一起带进废纸篓。
/// 写 XMP（BatchStore.exportXMP）和移废片（trashRejects）都按这里认「谁在用这个 .xmp」。
enum SidecarSharing {
    typealias Photo = (id: String, rawPath: String)

    /// 一张照片的 .xmp：LR / C1 / Bridge 都按「原图去扩展名 + .xmp」找。
    static func xmpURL(rawPath: String) -> URL {
        URL(fileURLWithPath: rawPath).deletingPathExtension().appendingPathExtension("xmp")
    }

    /// 认「是不是同一个 .xmp 文件」的键：小写的路径。APFS 默认不分大小写，DSCF0001.xmp 和 dscf0001.xmp 是同一个文件；
    /// 分大小写的盘上会把两个不同的文件也当成共用 —— 只是多跳过一组、不会写错。
    static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    /// .xmp 的键 → 用它的照片 id（按传进来的顺序）。
    static func users(_ photos: [Photo]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for photo in photos { out[key(xmpURL(rawPath: photo.rawPath)), default: []].append(photo.id) }
        return out
    }

    /// 共用一个 .xmp 的那几组（每组至少 2 张，组内按传进来的顺序，组按第一张的 id 排）。
    static func sharedGroups(_ photos: [Photo]) -> [[String]] {
        users(photos).values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }

    /// Lightroom Classic 会读旁边 .xmp 的格式：专有 RAW。DNG、JPG、TIFF、HEIC 它读写的是文件里内嵌的元数据，旁边的
    /// .xmp 不看（Capture One 都读 sidecar）。ImageLoader.rawExtensions 里有 dng，不能直接拿它当「LR 读 sidecar」。
    static let lightroomReadsSidecar: Set<String> = ImageLoader.rawExtensions.subtracting(["dng"])

    /// LR 不读旁边 .xmp 的格式名（大写扩展名，JPEG 记成 JPG）；LR 读的返回 nil。
    static func lightroomBlindFormat(rawPath: String) -> String? {
        let ext = URL(fileURLWithPath: rawPath).pathExtension.lowercased()
        guard !lightroomReadsSidecar.contains(ext) else { return nil }
        return ext == "jpeg" ? "JPG" : ext.uppercased()
    }

    /// 移废片时谁带走旁边的 .xmp。共用这个 .xmp 的照片（按整场 `all` 算，不只看要移的）全都在这次要移的 `moving` 里，
    /// 才由其中排在最后的那一张带走，而且要等前面几张都真的移成了（`after`）；还有照片留下（同名的另一张不是废片、
    /// 是客户选中、在拼图里用着……）就谁都不带，.xmp 留在原地（`kept`：这些留着的 .xmp，在不在盘上由调用方看）。
    static func trashSidecars(moving: [Photo], all: [Photo]) -> (carry: [String: (xmp: URL, after: [String])], kept: [URL]) {
        let users = users(all)
        let movingIDs = Set(moving.map(\.id))
        var lastMover: [String: String] = [:]
        for photo in moving { lastMover[key(xmpURL(rawPath: photo.rawPath))] = photo.id }
        var carry: [String: (xmp: URL, after: [String])] = [:]
        var kept: [String: URL] = [:]
        for photo in moving {
            let url = xmpURL(rawPath: photo.rawPath)
            let k = key(url)
            let sharers = users[k] ?? [photo.id]
            guard sharers.allSatisfy(movingIDs.contains) else {
                kept[k] = url
                continue
            }
            guard lastMover[k] == photo.id else { continue }
            carry[photo.id] = (url, sharers.filter { $0 != photo.id })
        }
        return (carry, kept.keys.sorted().compactMap { kept[$0] })
    }
}
