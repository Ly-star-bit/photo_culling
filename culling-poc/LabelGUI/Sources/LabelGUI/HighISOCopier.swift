import Foundation

/// 高 ISO RAW 复制到「拍摄文件夹/高ISO降噪/」（2026-11 审查 S10）。以前按文件名平铺、只比大小：两个子文件夹里同名的
/// RAW，大小不一样就先删掉前一张的副本再拷、一样大就当「已存在」跳过 —— 稳定少一张，计数还算两张。
/// 现在走「复制原片到…」同一套：目标里一模一样的（大小 + SHA-256，OriginalsCopier.sameContent）才跳过，同名不同内容的
/// 另存 -2、-3…；每个文件先写 .part、大小和 SHA 校验、RENAME_EXCL 改名（CardImporter.copyOne），绝不覆盖、绝不删
/// 目标里的任何文件。只复制 RAW 本身：RAW+JPG 的 JPG 不要，旁边的 .xmp 也不带（和以前一样，降噪软件只吃 RAW）。
enum HighISOCopier {
    enum Outcome: Sendable {
        /// 复制成了：落地的文件名，是不是另存成了 -2 这类名字。
        case copied(name: String, renamed: Bool)
        /// 目标里已经有一模一样的（上次复制的）。
        case existed
        case failed(String)
        case cancelled
    }

    /// 复制一个 RAW。`partialLeftover`：原名的那个文件是这张原片的开头一截 —— 多半是旧版复制中断留下的半截
    /// （旧版直接用正式文件名写、不写 .part），新的副本另存了 -2，半截的留在原地没删。
    static func copy(_ source: URL, to dest: URL,
                     cancel: AnalysisEngine.CancelFlag) -> (outcome: Outcome, partialLeftover: Bool) {
        let fm = FileManager.default
        let name = source.lastPathComponent
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var partialLeftover = false
        for n in 1...999 {
            if cancel.isSet { return (.cancelled, partialLeftover) }
            let base = n == 1 ? stem : "\(stem)-\(n)"
            let target = dest.appendingPathComponent(ext.isEmpty ? base : base + "." + ext)
            if fm.fileExists(atPath: target.path) {
                if OriginalsCopier.sameContent(source, target) { return (.existed, partialLeftover) }
                if n == 1 && isTruncatedCopy(target, of: source) { partialLeftover = true }
                continue
            }
            do {
                let attrs = try fm.attributesOfItem(atPath: source.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let copy = CardImporter.Copy(source: source, target: target, size: size,
                                             modified: attrs[.modificationDate] as? Date,
                                             created: attrs[.creationDate] as? Date,
                                             originalName: name, shot: name)
                _ = try CardImporter.copyOne(copy, into: dest, cancel: cancel, onBytes: { _ in })
                return (.copied(name: target.lastPathComponent, renamed: n > 1), partialLeftover)
            } catch CardImporter.ImportError.targetExists(_) {
                continue   // 查过之后才冒出来的同名文件（别的程序刚写进来）：不碰它，换下一个名字
            } catch CardImporter.ImportError.cancelled {
                return (.cancelled, partialLeftover)
            } catch let error as CardImporter.ImportError {
                return (.failed(name + "：" + error.shortReason), partialLeftover)
            } catch {
                return (.failed(name + "：" + CardImporter.describe(error)), partialLeftover)
            }
        }
        return (.failed(name + "：-2 到 -999 都被占了"), partialLeftover)
    }

    /// `file` 比 `source` 短、而且正好是它的开头一截（中断的复制留下的样子）。只在同名冲突时才查，读的是那一截的长度。
    static func isTruncatedCopy(_ file: URL, of source: URL) -> Bool {
        let fm = FileManager.default
        guard let fileSize = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              let sourceSize = (try? fm.attributesOfItem(atPath: source.path))?[.size] as? NSNumber,
              fileSize.int64Value < sourceSize.int64Value,
              let a = try? FileHandle(forReadingFrom: file),
              let b = try? FileHandle(forReadingFrom: source) else { return false }
        defer {
            try? a.close()
            try? b.close()
        }
        while true {
            let chunkA = (try? a.read(upToCount: 1 << 20)) ?? nil
            guard let chunkA, !chunkA.isEmpty else { return true }
            guard let chunkB = (try? b.read(upToCount: chunkA.count)) ?? nil, chunkB == chunkA else { return false }
        }
    }
}
