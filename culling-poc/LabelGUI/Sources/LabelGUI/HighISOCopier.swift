import Foundation

/// 高 ISO RAW 复制到「拍摄文件夹/高ISO降噪/」（2026-11 审查 S10）。以前按文件名平铺、只比大小：两个子文件夹里同名的
/// RAW，大小不一样就先删掉前一张的副本再拷、一样大就当「已存在」跳过 —— 稳定少一张，计数还算两张。
/// 现在走「复制原片到…」同一套：目标里一模一样的（大小 + SHA-256，OriginalsCopier.sameContent）才跳过，同名不同内容的
/// 另存 -2、-3…；每个文件先落到 .part、校验、RENAME_EXCL 改名，绝不覆盖、绝不删目标里的任何文件。
/// 「高ISO降噪/」就在拍摄文件夹里，几乎总和原片在同一块盘上：APFS 上先克隆（clonefile，和以前 FileManager.copyItem
/// 一样不多占空间、一瞬间完成，克隆共用数据块，只核对大小）；克隆不了（跨卷、exFAT / HFS+ / SMB）才流式复制，
/// 大小和 SHA 校验（CardImporter.copyOne）。只复制 RAW 本身：RAW+JPG 的 JPG 不要，旁边的 .xmp 也不带
/// （和以前一样，降噪软件只吃 RAW）。
enum HighISOCopier {
    enum Outcome: Sendable {
        /// 复制成了：落地的文件名，是不是另存成了 -2 这类名字。
        case copied(name: String, renamed: Bool)
        /// 目标里已经有一模一样的（上次复制的）。
        case existed
        /// 目标盘满了（原片的文件名）：后面的不用再一个个试，exportHighISORaws 停下、点名没复制的。
        case diskFull(String)
        case failed(String)
        case cancelled
    }

    /// 测试用（--files-selftest；和 CardImporter.volumeFactsOverride 一样只有自检代码设，正常使用都是默认值）：
    /// noClone 不克隆、走跨卷那条流式复制；freeBytes 假装目标盘只剩这么多；diskFullNames 复制这些文件名的原片时假装盘满。
    struct TestHooks {
        var noClone = false
        var freeBytes: Int64?
        var diskFullNames: Set<String> = []
    }
    nonisolated(unsafe) static var testHooks = TestHooks()

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
            if testHooks.diskFullNames.contains(name) { return (.diskFull(name), partialLeftover) }
            switch clone(source, to: target, in: dest) {
            case .done:
                return (.copied(name: target.lastPathComponent, renamed: n > 1), partialLeftover)
            case .targetExists:
                continue   // 查过之后才冒出来的同名文件：不碰它，换下一个名字
            case .diskFull:
                return (.diskFull(name), partialLeftover)
            case .unavailable:
                break      // 跨卷、不是 APFS：下面流式复制
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
            } catch CardImporter.ImportError.diskFull(_) {
                return (.diskFull(name), partialLeftover)
            } catch let error as CardImporter.ImportError {
                return (.failed(name + "：" + error.shortReason), partialLeftover)
            } catch {
                return (.failed(name + "：" + CardImporter.describe(error)), partialLeftover)
            }
        }
        return (.failed(name + "：-2 到 -999 都被占了"), partialLeftover)
    }

    private enum CloneResult { case done, targetExists, diskFull, unavailable }

    /// 克隆到 `.名字.part`，再 RENAME_EXCL 改成正式名（和 copyOne 同一套临时名、同一道绝不覆盖的闸，写的只是目标文件夹的
    /// 直接子项）。克隆和原片共用数据块，算 SHA 证明不了什么，只核对大小；时间戳照原片设。克隆不了（EXDEV 跨卷、
    /// ENOTSUP 不是 APFS……）、改名出了 EEXIST 以外的错，都回 .unavailable，交给流式复制（它把错报清楚）。
    private static func clone(_ source: URL, to target: URL, in dest: URL) -> CloneResult {
        // 假装不支持 RENAME_EXCL 的测试卷（LABELGUI_TEST_NO_RENAME_EXCL）也不会是 APFS：一律走 copyOne 那条退路。
        if testHooks.noClone || CardImporter.pretendNoExclusiveRename { return .unavailable }
        let fm = FileManager.default
        let part = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".part")
        do {
            try CardImporter.requireInside(target, dest)
            try CardImporter.requireInside(part, dest)
        } catch {
            return .unavailable   // copyOne 照样会查，报「拒绝写到目标文件夹以外」
        }
        // 上次崩掉留下的半截 —— 是我们自己的临时文件。
        if CardImporter.entryExists(part) { try? fm.removeItem(at: part) }
        if clonefile(source.path, part.path, 0) != 0 {
            return errno == ENOSPC ? .diskFull : .unavailable
        }
        var finished = false
        defer { if !finished { try? fm.removeItem(at: part) } }
        guard let attrs = try? fm.attributesOfItem(atPath: source.path),
              let want = (attrs[.size] as? NSNumber)?.int64Value,
              let got = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber,
              got.int64Value == want else { return .unavailable }
        var dates: [FileAttributeKey: Any] = [:]
        if let m = attrs[.modificationDate] { dates[.modificationDate] = m }
        if let c = attrs[.creationDate] { dates[.creationDate] = c }
        if !dates.isEmpty { try? fm.setAttributes(dates, ofItemAtPath: part.path) }
        if renamex_np(part.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            return errno == EEXIST ? .targetExists : .unavailable
        }
        finished = true
        return .done
    }

    // MARK: 开工前的空间预检

    /// 要真复制（克隆不了）的有几个、共多少字节。和「高ISO降噪/」在同一块能克隆的盘上的不算（克隆不占空间）；
    /// 目标里同名（或 -2、-3…）已经有一样大的也不算（多半是上次复制的，循环里再按 SHA 核对）—— 盘紧的时候重跑不被误拦。
    static func bytesToCopy(_ sources: [URL], into dest: URL) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        let probe = fm.fileExists(atPath: dest.path) ? dest : dest.deletingLastPathComponent()
        let volume = try? probe.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        let canClone = !testHooks.noClone && !CardImporter.pretendNoExclusiveRename
            && (volume?.volumeSupportsFileCloning ?? false)
        var st = stat()
        let destDevice: dev_t? = stat(probe.path, &st) == 0 ? st.st_dev : nil
        var files = 0
        var bytes: Int64 = 0
        for source in sources {
            guard stat(source.path, &st) == 0 else { continue }   // 读不了的，循环里会报
            if canClone, let destDevice, st.st_dev == destDevice { continue }
            let size = Int64(st.st_size)
            if alreadyThere(source, size: size, in: dest) { continue }
            files += 1
            bytes += size
        }
        return (files, bytes)
    }

    /// 按 copy 挑名字的顺序（原名、-2、-3…，到第一个空着的为止）找一样大的。
    private static func alreadyThere(_ source: URL, size: Int64, in dest: URL) -> Bool {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var st = stat()
        for n in 1...999 {
            let base = n == 1 ? stem : "\(stem)-\(n)"
            let target = dest.appendingPathComponent(ext.isEmpty ? base : base + "." + ext)
            guard stat(target.path, &st) == 0 else { return false }
            if Int64(st.st_size) == size { return true }
        }
        return false
    }

    /// 空间不够就不开工（同存储卡导入：复制完系统盘至少还剩 CardImporter.spaceMargin）。不用真复制、读不出剩余空间的照常复制。
    static func spaceRefusal(_ need: (files: Int, bytes: Int64), near dest: URL) -> String? {
        guard need.bytes > 0, let free = testHooks.freeBytes ?? CardImporter.freeBytes(near: dest),
              free < need.bytes + CardImporter.spaceMargin else { return nil }
        let margin = BatchStore.sizeText(CardImporter.spaceMargin)
        return "高 ISO RAW 没复制：有 \(need.files) 个要实打实复制（不在同一块能克隆的 APFS 盘上），共 " +
            BatchStore.sizeText(need.bytes) + "，目标盘只剩 " + BatchStore.sizeText(free) +
            "（复制完至少要留 \(margin)）。腾出空间后再点一次"
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
