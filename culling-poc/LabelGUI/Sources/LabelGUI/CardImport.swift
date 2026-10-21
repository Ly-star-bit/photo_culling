import Foundation
import AppKit
import CryptoKit
import Darwin

// MARK: - 存储卡导入：插卡 → 问一声 → 复制到「图片/yyyyMMdd」→ 打开、开始分析
//
// 数据安全的几条铁律，每条都有代码兜底，不只是注释：
// 1. 存储卡只读。这里对源文件只有「读」；所有写 / 改名 / 删除先过 `requireInside(_:_:)`，
//    路径不在目标文件夹里直接抛错 —— 存储卡上的文件一个字节都不会动，导完也不删卡。
// 2. 目标里绝不覆盖。目标文件夹里同名（不分大小写）已经是别的照片 → 整组（同一文件夹里同名的
//    RAW+JPG）一起换名（_2、_3…），RAW+JPG 还配得上；复制时也按整张看：计划之后目标里冒出同名文件，
//    整张跳过（不拆开）；最后一步用 renamex_np(RENAME_EXCL)，目标已存在就失败，算第二道闸。
// 3. 先写隐藏的 `.名字.part`，大小对上、重新读一遍的 SHA-256 和读卡时算的对上，再改成正式名字；
//    取消 / 出错删掉 .part（前面带点，分析扫描也看不到它）。
// 4. 开始前查空间，不够就不开始，不会导一半把盘写满。
// 5. 「目标里已经有了」要整份逐字节一样才算（大小、头尾指纹只是先筛）—— 中间坏了一块的旧副本
//    不能顶替卡上的原片。
// 6. 卡上有读不出来的地方、有没导的文件，都要说出来，不能装作卡上就这么多。
//
// 「以前导入过」记在 appDataDir/import_ledger.json：原文件名|大小|指纹（头尾各 64KB 的 SHA-256）。
// 只有复制并校验通过、或整份比对一致的才记。不用修改时间 —— FAT 卡的时间只精确到 2 秒，
// 有的读卡器 / 系统组合还会改写它。
enum CardImporter {
    /// 导入哪些：分析认的全部（ImageLoader，都是本机 ImageIO 解得开的），再加解不开、但确实是相机
    /// 照片的格式（GoPro GPR、Mamiya MEF、柯达 KDC、适马 X3F、Insta360 INSP）—— 导进来不丢，只是分析看不到。
    static let photoExtensions: Set<String> = ImageLoader.imageExtensions.union(["gpr", "mef", "kdc", "x3f", "insp"])
    /// 确认框里数 RAW 用。
    static let rawLikeExtensions: Set<String> = ImageLoader.rawExtensions.union(["gpr", "mef", "kdc", "x3f"])
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "mts", "m2ts", "avi", "mxf", "crm", "braw", "insv", "r3d", "mpg", "mpeg", "m4v", "3gp",
    ]
    /// 相机自己写在 DCIM 里的配套小文件（视频缩略图、低码率代理、目录、元数据）：不导，也不当成
    /// 「没导的其他文件」去提醒。录音备注（WAV）不在这里 —— 那是拍摄者录的，要提一句。
    static let sidecarExtensions: Set<String> = [
        "thm", "lrv", "lrf", "ctg", "xml", "xmp", "dat", "ind", "bdm", "cpi", "mpl", "bin", "ini", "db", "tmp", "lst",
    ]
    static let ledgerFileName = "import_ledger.json"
    /// 空间余量：导完系统盘至少还剩 1 GB。
    static let spaceMargin: Int64 = 1 << 30

    // MARK: 类型

    struct Volume: Identifiable, Hashable {
        let root: URL
        let name: String
        /// 卷的 UUID（FAT / exFAT 卡由卷序列号来）：记「不导入」用，卷名大家都叫 EOS_DIGITAL / Untitled。
        let uuid: String?
        var id: String { root.path }
    }

    struct Copy: Hashable {
        let source: URL
        let target: URL
        let size: Int64
        let modified: Date?
        let created: Date?
        /// 卡上的原文件名 —— 账本按它记（换了名的也认得出是同一张）。
        let originalName: String
        /// 同一张照片（RAW+JPG）的几个文件共用一个：数「张」、复制时整张一起看。
        let shot: String
    }

    struct Plan: Identifiable {
        let id = UUID()
        let source: URL
        let sourceName: String
        let destination: URL
        let copies: [Copy]
        /// 目标里已经有、整份逐字节一样的 —— 记进账本，不再复制。
        let alreadyThere: [(key: String, path: String)]
        /// 卡上的照片：张数（RAW+JPG 算一张）、文件数。
        let cardShots: Int
        let cardFiles: Int
        /// 以前导入过、这次不导的（张）。
        let skippedImported: Int
        /// 以前导入到了哪些文件夹（给提示用），和最常见的那个还在不在。
        let previousFolders: [String]
        let previousFolderGone: Bool
        /// 目标里已经有、内容一模一样的（张）。
        let skippedInDest: Int
        /// 和目标里别的照片重名、整组改了名的（张）。
        let renamedShots: Int
        let videoCount: Int
        /// 不是照片、不是视频、也不是相机配套小文件的（录音备注、不认识的格式）：个数和几个例子。
        let otherCount: Int
        let otherExamples: [String]
        /// 卡上读不出来的地方（相对卡根目录的路径）。非空 = 卡上的照片可能比这里数的多。
        let scanProblems: [String]
        let includeImported: Bool
        /// 目标文件夹里原来就有的文件数（同一天导第二张卡时提示「会放在一起」）。
        let existingInDest: Int
        var freeBytes: Int64?

        var totalBytes: Int64 { copies.reduce(0) { $0 + $1.size } }
        var shotCount: Int { Set(copies.map(\.shot)).count }
        var rawCount: Int { copies.filter { CardImporter.rawLikeExtensions.contains($0.target.pathExtension.lowercased()) }.count }
        var enoughSpace: Bool {
            guard let free = freeBytes else { return true }
            return free >= totalBytes + CardImporter.spaceMargin
        }
    }

    /// 导完、等着打开的那批（BatchStore.finishedImport）。
    struct FinishedImport: Equatable {
        let folder: URL
        let analyze: Bool
        let shots: Int
    }

    struct Failure {
        let name: String
        let reason: String
    }

    struct Outcome {
        /// 计划要复制的文件数：中途停下时「没导进来」按它算（failed 只数试过的）。
        var plannedFiles = 0
        var copiedFiles = 0
        var copiedShots = 0
        var copiedBytes: Int64 = 0
        var failed: [Failure] = []
        var cancelled = false
        /// 整个停下来的原因（卡拔了、盘满了、空间不够、目标建不出来）。
        var aborted: String?
        /// 计划时卡上读不出来的地方（照搬 Plan.scanProblems，导完一起提醒）。
        var scanProblems: [String] = []
        var elapsed: TimeInterval = 0
    }

    enum ImportError: LocalizedError {
        case unsafePath(String)
        case targetExists(String)
        case sizeMismatch(String)
        case verifyFailed(String)
        case cancelled
        /// 计划阶段：卡（或目标文件夹）整个读不了。
        case unreadable(String)
        /// 读卡出错（文件名, 原因）—— 只有这类、校验 / 大小不对的才算「存储卡可能坏了」。
        case readFailed(String, String)
        /// 写目标出错（文件名, 原因）。
        case writeFailed(String, String)
        case diskFull(String)

        var errorDescription: String? {
            switch self {
            case .unsafePath(let p): return "拒绝写到目标文件夹以外：\(p)"
            case .targetExists(let n): return "目标里已经有 \(n)（计划之后才出现的），没覆盖它"
            case .sizeMismatch(let n): return "\(n) 复制后大小不对（读卡不稳？）"
            case .verifyFailed(let n): return "\(n) 复制后校验对不上（读卡不稳？）"
            case .cancelled: return "已取消"
            case .unreadable(let p): return "读不了 \(p)"
            case .readFailed(let n, let why): return "\(n) 读不出来（\(why)）"
            case .writeFailed(let n, let why): return "\(n) 写不进目标文件夹（\(why)）"
            case .diskFull(let n): return "目标盘满了，\(n) 没写完"
            }
        }

        /// 不带文件名的短原因（失败列表、导入提醒里文件名已经写在前面了）。
        var shortReason: String {
            switch self {
            case .unsafePath: return "拒绝写到目标文件夹以外"
            case .targetExists(let n): return "目标里已经有 \(n)，没覆盖"
            case .sizeMismatch: return "复制后大小对不上，读卡不稳？"
            case .verifyFailed: return "复制后校验对不上，读卡不稳？"
            case .cancelled: return "已取消"
            case .unreadable: return "读不了"
            case .readFailed(_, let why): return "读不出来：\(why)"
            case .writeFailed(_, let why): return "写不进目标文件夹：\(why)"
            case .diskFull: return "目标盘满了"
            }
        }
    }

    // MARK: 账本

    struct Ledger {
        struct Entry: Codable {
            var dest: String
            var at: Date
        }
        private(set) var entries: [String: Entry] = [:]
        /// 「原文件名|大小」索引：新卡（一张都没导过）不用读卡算指纹。
        private var prefixes: Set<String> = []
        /// 最多记这么多（约 15 张满卡），超了一次扔掉最早的到 90%（不是每记一条就排一次序 ——
        /// 到上限以后一次导入 4000 个文件会排 4000 次 6 万条）。var：无头测试 `--ledger-cap` 调小。
        static var cap = 60_000

        static func key(name: String, size: Int64, fingerprint: String) -> String {
            "\(name)|\(size)|\(fingerprint)"
        }

        /// 读账本。`backupCorrupt`：文件在、但解不开（被别的程序改坏了）→ 先改名另存一份再从空账本开始，
        /// 别让接下来的保存把全部导入记录盖掉。只有要写账本的（execute）才传 true，计划是只读的。
        static func load(from url: URL, backupCorrupt: Bool = false) -> Ledger {
            var ledger = Ledger()
            guard let data = try? Data(contentsOf: url) else { return ledger }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(File.self, from: data) {
                ledger.entries = file.entries
                ledger.prefixes = Set(file.entries.keys.map(Self.prefix(of:)))
            } else if backupCorrupt {
                let stamp = Int(Date().timeIntervalSince1970)
                let aside = url.deletingLastPathComponent().appendingPathComponent("import_ledger.corrupt-\(stamp).json")
                try? FileManager.default.moveItem(at: url, to: aside)
            }
            return ledger
        }

        func save(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(File(version: 1, entries: entries)).write(to: url, options: .atomic)
        }

        func mightContain(name: String, size: Int64) -> Bool { prefixes.contains("\(name)|\(size)") }
        func entry(for key: String) -> Entry? { entries[key] }

        mutating func record(_ key: String, dest: String, at date: Date = Date()) {
            entries[key] = Entry(dest: dest, at: date)
            prefixes.insert(Self.prefix(of: key))
            if entries.count > Self.cap {
                let keep = max(1, Self.cap * 9 / 10)
                let drop = entries.sorted { $0.value.at < $1.value.at }.prefix(entries.count - keep)
                for (k, _) in drop { entries[k] = nil }
                prefixes = Set(entries.keys.map(Self.prefix(of:)))
            }
        }

        private static func prefix(of key: String) -> String {
            // 文件名里可以有「|」吗？相机不会；就算有，最后一段是指纹，按最后一个「|」切。
            guard let cut = key.range(of: "|", options: .backwards) else { return key }
            return String(key[..<cut.lowerBound])
        }

        private struct File: Codable {
            var version: Int
            var entries: [String: Entry]
        }
    }

    // MARK: 找卡

    /// 这个宗卷是相机存储卡吗：可移除或可推出、本地、根目录有 DCIM 文件夹。
    /// 插上任何盘（Time Machine 备份盘、网络共享、DMG）都会收到挂载通知，别去扫 4TB 的备份盘。
    /// 第一次访问可移除宗卷会弹系统授权框 —— 别在主线程上调。
    static func cardVolume(at root: URL) -> Volume? {
        let keys: Set<URLResourceKey> = [
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
            .volumeIsRootFileSystemKey, .volumeLocalizedNameKey, .volumeNameKey, .volumeUUIDStringKey,
        ]
        guard let v = try? root.resourceValues(forKeys: keys) else { return nil }
        if v.volumeIsRootFileSystem == true || v.volumeIsLocal == false { return nil }
        guard v.volumeIsRemovable == true || v.volumeIsEjectable == true else { return nil }
        guard isDirectory(root.appendingPathComponent("DCIM")) else { return nil }
        return Volume(root: root, name: v.volumeLocalizedName ?? v.volumeName ?? root.lastPathComponent,
                      uuid: v.volumeUUIDString)
    }

    /// 有插着的可移除盘，但系统不让读（「隐私与安全性 › 文件与文件夹 › 可移除的宗卷」没开）——
    /// 这时 cardVolume 看不到 DCIM，会被当成「没插卡」。手动「从存储卡导入…」找不到卡时用它说清楚。
    /// 会读每个可移除盘的根目录（可能弹系统授权框）：只给界面里手动点的那条路用，无头参数走不到。
    static func removableAccessDenied() -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                         options: [.skipHiddenVolumes]) ?? []
        for root in urls {
            guard let v = try? root.resourceValues(forKeys: keys), v.volumeIsRootFileSystem != true,
                  v.volumeIsRemovable == true || v.volumeIsEjectable == true else { continue }
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            } catch {
                if let code = posixCode(error), code == EPERM || code == EACCES { return true }
            }
        }
        return false
    }

    /// 现在插着的相机存储卡。
    static func mountedCards() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(cardVolume(at:))
    }

    /// 默认目标：「图片」文件夹里以今天日期命名的文件夹（20261014）。
    static func defaultDestination(now: Date = Date()) -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent(dayFormatter.string(from: now), isDirectory: true)
    }

    /// 钉 en_US_POSIX + 公历：系统设成佛历时「yyyy」会变成 2569。
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// 界面上怎么称呼目标：「图片 › 20261014」；不在「图片」里就写路径（家目录缩成 ~）。
    static func displayPath(_ url: URL) -> String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if let pictures, path.hasPrefix(pictures + "/") {
            return "图片 › " + path.dropFirst(pictures.count + 1).split(separator: "/").joined(separator: " › ")
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: 计划（只读：读卡、读目标文件夹，什么都不写）

    private struct CardFile {
        let url: URL
        let name: String
        let ext: String
        let size: Int64
        let modified: Date?
        let created: Date?
    }

    /// `progress`：要整份比对目标里的同名文件时说一声（重导进同一个文件夹时可能要读很久）。
    static func plan(source: URL, destination: URL, ledger: Ledger, includeImported: Bool,
                     cancel: AnalysisEngine.CancelFlag? = nil,
                     progress: ((String) -> Void)? = nil) throws -> Plan {
        let fm = FileManager.default
        let dcim = source.appendingPathComponent("DCIM")
        let scanRoot = isDirectory(dcim) ? dcim : source
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey]
        // 不用 .skipsHiddenFiles：它也会跳过带「隐藏」标记的文件 —— FAT 卡上的隐藏属性（比如尼康的
        // 「隐藏图像」）就是这个标记，那些是真照片（审查发现）。只跳过名字以点开头的（._ 文件、.Trashes）。
        var problems: [String] = []
        var firstError: Error?
        func relative(_ url: URL) -> String {
            let root = source.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
        }
        guard let enumerator = fm.enumerator(at: scanRoot, includingPropertiesForKeys: keys,
                                             options: [.skipsPackageDescendants],
                                             errorHandler: { url, error in
                                                 if firstError == nil { firstError = error }
                                                 let rel = relative(url)
                                                 if !problems.contains(rel) { problems.append(rel) }
                                                 return true
                                             }) else {
            throw ImportError.unreadable(scanRoot.path)
        }
        var files: [CardFile] = []
        var videos = 0
        var others: [String] = []
        for case let url as URL in enumerator {
            if cancel?.isSet == true { throw ImportError.cancelled }
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            if name.hasPrefix(".") {
                if v?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            // 读不出属性（卡不稳）：记成读不出来的地方，别不吭声地少一张。
            guard let v else {
                let rel = relative(url)
                if !problems.contains(rel) { problems.append(rel) }
                continue
            }
            guard v.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if photoExtensions.contains(ext) {
                files.append(CardFile(url: url, name: name, ext: url.pathExtension, size: Int64(v.fileSize ?? 0),
                                      modified: v.contentModificationDate, created: v.creationDate))
            } else if videoExtensions.contains(ext) {
                videos += 1
            } else if !sidecarExtensions.contains(ext) {
                others.append(name)
            }
        }
        // 一个文件都没读到、又出了错：多半整张卡读不了（没给权限），整个报错。读到了一部分就照常出计划，
        // 读不出来的地方记在 scanProblems 里，确认框和导完都要提醒。
        if files.isEmpty, let firstError { throw firstError }

        // 目标文件夹现有的文件，按「第一个点之前」分桶，查某个名字有没有被占用。
        var destIndex: [String: [URL]] = [:]
        var existingInDest = 0
        if let contents = try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in contents where !url.lastPathComponent.hasPrefix(".") {
                destIndex[firstDotKey(url.lastPathComponent), default: []].append(url)
                existingInDest += 1
            }
        }
        /// 目标里属于这个名字的文件：IMG_0001.CR3 / IMG_0001.jpg / IMG_0001.xmp / IMG_0001.CR3.xmp。
        func occupants(of stem: String) -> [URL] {
            let lower = stem.lowercased() + "."
            return (destIndex[firstDotKey(stem)] ?? []).filter { $0.lastPathComponent.lowercased().hasPrefix(lower) }
        }

        // 同一文件夹里同名的算一张（RAW+JPG）—— 和 listPhotos 配对规则一样，区分大小写。
        let groups = Dictionary(grouping: files) { $0.url.deletingPathExtension().path }
        var planned: Set<String> = []          // 这次已经分出去的名字（小写）
        var copies: [Copy] = []
        var alreadyThere: [(key: String, path: String)] = []
        var skippedImported = 0, skippedInDest = 0, renamedShots = 0
        var previousFolders: [String: Int] = [:]
        var fingerprints: [URL: String] = [:]
        var digests: [URL: SHA256.Digest] = [:]
        var compared = 0
        func fingerprintOf(_ f: CardFile) throws -> String {
            if let cached = fingerprints[f.url] { return cached }
            let fp = try fingerprint(f.url, size: f.size)
            fingerprints[f.url] = fp
            return fp
        }
        /// 卡上这个文件和目标里那个是不是同一份：大小、头尾指纹先筛（便宜），都一样再整份 SHA-256 比。
        func sameContent(_ m: CardFile, _ url: URL) -> Bool {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) == m.size,
                  let mine = try? fingerprintOf(m), let theirs = try? fingerprint(url, size: m.size), mine == theirs
            else { return false }
            compared += 1
            progress?("逐字节核对目标里已有的同名文件（第 \(compared) 个）…")
            let full: SHA256.Digest
            if let cached = digests[m.url] {
                full = cached
            } else {
                guard let d = try? sha256(of: m.url, cancel: cancel) else { return false }
                digests[m.url] = d
                full = d
            }
            guard let other = try? sha256(of: url, cancel: cancel) else { return false }
            return full == other
        }

        for groupKey in groups.keys.sorted() {
            if cancel?.isSet == true { throw ImportError.cancelled }
            let members = groups[groupKey]!.sorted { $0.name < $1.name }

            // 1. 账本：这张的每个文件都导过 → 默认跳过。读不出指纹的当没导过（后面复制会报错）。
            var ledgerKeys: [String?] = []
            for m in members {
                if ledger.mightContain(name: m.name, size: m.size), let fp = try? fingerprintOf(m) {
                    let key = Ledger.key(name: m.name, size: m.size, fingerprint: fp)
                    ledgerKeys.append(ledger.entry(for: key) == nil ? nil : key)
                } else {
                    ledgerKeys.append(nil)
                }
            }
            if !includeImported, ledgerKeys.allSatisfy({ $0 != nil }) {
                skippedImported += 1
                for key in ledgerKeys.compactMap({ $0 }) {
                    if let dest = ledger.entry(for: key)?.dest {
                        previousFolders[URL(fileURLWithPath: dest).deletingLastPathComponent().path, default: 0] += 1
                    }
                }
                continue
            }

            // 2. 目标文件夹：找一个能用的名字。原名先试；被别的照片占了就 _2、_3……
            //    · 占着这个名字的全是「这张本身、内容整份一样」→ 已经在了，缺哪个补哪个；
            //    · 有不相干的文件（别的照片、只剩 .xmp 的、坏掉的旧副本）→ 这个名字不能用，换下一个。
            let baseStem = members[0].url.deletingPathExtension().lastPathComponent
            var n = 1
            var chosen: (stem: String, missing: [CardFile])?
            while chosen == nil, n < 10_000 {
                if cancel?.isSet == true { throw ImportError.cancelled }
                let stem = n == 1 ? baseStem : "\(baseStem)_\(n)"
                n += 1
                if planned.contains(stem.lowercased()) { continue }
                let taken = occupants(of: stem)
                if taken.isEmpty {
                    chosen = (stem, members)
                    break
                }
                var identical: Set<String> = []     // 已经在的成员（原文件名）
                var foreign = false, sidecar = false
                for url in taken {
                    let name = url.lastPathComponent.lowercased()
                    if let m = members.first(where: { (stem + "." + $0.ext).lowercased() == name }), sameContent(m, url) {
                        identical.insert(m.name)
                    } else if url.pathExtension.lowercased() == "xmp" {
                        sidecar = true
                    } else {
                        foreign = true
                    }
                }
                if foreign { continue }
                let missing = members.filter { !identical.contains($0.name) }
                if missing.isEmpty {
                    chosen = (stem, [])
                    break
                }
                // 补缺的文件不往一个已经有 .xmp 的名字上挂：那份 xmp 不一定是这张的。
                if sidecar { continue }
                chosen = (stem, missing)
            }
            if cancel?.isSet == true { throw ImportError.cancelled }
            guard let chosen else { continue }
            planned.insert(chosen.stem.lowercased())

            let present = members.filter { m in !chosen.missing.contains(where: { $0.url == m.url }) }
            for m in present {
                let target = destination.appendingPathComponent(chosen.stem + "." + m.ext)
                if let fp = try? fingerprintOf(m) {
                    alreadyThere.append((Ledger.key(name: m.name, size: m.size, fingerprint: fp), target.path))
                }
            }
            if chosen.missing.isEmpty {
                skippedInDest += 1
                continue
            }
            if chosen.stem != baseStem { renamedShots += 1 }
            for m in chosen.missing {
                copies.append(Copy(source: m.url, target: destination.appendingPathComponent(chosen.stem + "." + m.ext),
                                   size: m.size, modified: m.modified, created: m.created,
                                   originalName: m.name, shot: groupKey))
            }
        }

        let folders = previousFolders.sorted { $0.value > $1.value }.map(\.key)
        return Plan(source: source, sourceName: source.lastPathComponent, destination: destination,
                    copies: copies, alreadyThere: alreadyThere,
                    cardShots: groups.count, cardFiles: files.count,
                    skippedImported: skippedImported,
                    previousFolders: folders,
                    previousFolderGone: folders.first.map { !isDirectory(URL(fileURLWithPath: $0)) } ?? false,
                    skippedInDest: skippedInDest, renamedShots: renamedShots, videoCount: videos,
                    otherCount: others.count, otherExamples: Array(others.prefix(3)),
                    scanProblems: problems,
                    includeImported: includeImported, existingInDest: existingInDest,
                    freeBytes: freeBytes(near: destination))
    }

    // MARK: 执行

    /// 照计划复制。`progress(已完成文件数, 已复制字节)` 从后台线程来，最多每 `progressInterval` 秒一次。
    /// 按「张」走：一张照片的几个文件（RAW+JPG）先一起看目标名字还空不空，空着才开始复制。
    static func execute(_ plan: Plan, ledgerURL: URL, cancel: AnalysisEngine.CancelFlag,
                        progressInterval: TimeInterval = 0.1,
                        progress: @escaping (Int, Int64) -> Void) -> Outcome {
        let fm = FileManager.default
        let start = Date()
        var outcome = Outcome()
        outcome.scanProblems = plan.scanProblems
        outcome.plannedFiles = plan.copies.count
        func finish() -> Outcome {
            var done = outcome
            done.elapsed = Date().timeIntervalSince(start)
            return done
        }

        if let free = freeBytes(near: plan.destination), free < plan.totalBytes + spaceMargin {
            outcome.aborted = "空间不够：要 \(BatchStore.sizeText(plan.totalBytes))，只剩 \(BatchStore.sizeText(free))"
            return finish()
        }
        // 目标落在卡里面（或者把卡当成了目标）：一个都不写，连文件夹都不建。目标还不存在就拿存在的那一级比。
        if isWithin(existingAncestor(of: plan.destination), plan.source) || isWithin(plan.source, plan.destination) {
            outcome.aborted = "目标文件夹和存储卡重叠了，不导入"
            return finish()
        }
        do {
            try fm.createDirectory(at: plan.destination, withIntermediateDirectories: true)
        } catch {
            outcome.aborted = "建不了目标文件夹 \(displayPath(plan.destination))：\(describe(error))"
            return finish()
        }

        var ledger = Ledger.load(from: ledgerURL, backupCorrupt: true)
        for (key, path) in plan.alreadyThere { ledger.record(key, dest: path) }

        // 一张照片的几个文件（plan 里挨着放）。
        var shots: [[Copy]] = []
        for copy in plan.copies {
            if let last = shots.last?.first, last.shot == copy.shot {
                shots[shots.count - 1].append(copy)
            } else {
                shots.append([copy])
            }
        }

        var bytesDone: Int64 = 0
        var filesDone = 0
        var lastReport = Date.distantPast
        var copiedShots: Set<String> = []
        var readFailures = 0, writeFailures = 0
        var lastLedgerSave = Date()
        progress(0, 0)
        shotLoop: for members in shots {
            if cancel.isSet { outcome.cancelled = true; break }
            // 卡被拔了：后面每个都会失败，别刷出几百条错误。
            if !fm.fileExists(atPath: plan.source.path) {
                outcome.aborted = "存储卡「\(plan.sourceName)」不见了（被拔掉了？）"
                break
            }
            // 计划之后目标里冒出了同名文件（同一个文件夹刚导过另一张卡、别的程序写进来）：整张不导，
            // 也不覆盖 —— 只跳冲突的那一个会把 RAW 和 JPG 拆到两张不同的照片下（审查发现）。
            if let clash = members.first(where: { fm.fileExists(atPath: $0.target.path) }) {
                let why = "目标里突然有了同名的 \(clash.target.lastPathComponent)，整张没导、没覆盖"
                for m in members { outcome.failed.append(Failure(name: m.originalName, reason: why)) }
                filesDone += members.count
                progress(filesDone, bytesDone)
                continue
            }
            for copy in members {
                if cancel.isSet { outcome.cancelled = true; break shotLoop }
                do {
                    let key = try copyOne(copy, into: plan.destination, cancel: cancel) { delta in
                        bytesDone += delta
                        let now = Date()
                        if now.timeIntervalSince(lastReport) >= progressInterval {
                            lastReport = now
                            progress(filesDone, bytesDone)
                        }
                    }
                    if let key { ledger.record(key, dest: copy.target.path) }
                    outcome.copiedFiles += 1
                    outcome.copiedBytes += copy.size
                    copiedShots.insert(copy.shot)
                    readFailures = 0
                    writeFailures = 0
                } catch ImportError.cancelled {
                    outcome.cancelled = true
                    break shotLoop
                } catch let error as ImportError {
                    outcome.failed.append(Failure(name: copy.originalName, reason: error.shortReason))
                    switch error {
                    case .diskFull:
                        outcome.aborted = "目标盘满了（\(displayPath(plan.destination))）"
                        break shotLoop
                    case .writeFailed:
                        writeFailures += 1
                        if writeFailures >= 3 {
                            outcome.aborted = "连续 \(writeFailures) 个文件\(error.shortReason)，停下了"
                            break shotLoop
                        }
                    case .readFailed, .verifyFailed, .sizeMismatch:
                        readFailures += 1
                        if readFailures >= 8 {
                            outcome.aborted = "连续 \(readFailures) 个文件读不出来，停下了（存储卡坏了或被拔掉？）"
                            break shotLoop
                        }
                    case .unsafePath:
                        outcome.aborted = error.shortReason
                        break shotLoop
                    case .targetExists, .unreadable, .cancelled:
                        break      // 同名冲突不算读卡出错
                    }
                } catch {
                    outcome.failed.append(Failure(name: copy.originalName, reason: describe(error)))
                    readFailures += 1
                }
                filesDone += 1
                // 最多 20 秒存一次账本：中途崩了，下次也知道哪些已经导过。按文件数存的话，账本几万条
                // （几 MB）时一次导入要反复写几百 MB。丢几条也无妨：导进同一个文件夹时整份比对照样认得出。
                if Date().timeIntervalSince(lastLedgerSave) >= 20 {
                    try? ledger.save(to: ledgerURL)
                    lastLedgerSave = Date()
                }
                progress(filesDone, bytesDone)
            }
        }
        // 一次 F_FULLFSYNC 把盘的写缓存刷下去 —— 用户看到「导入完成」可能马上就去格式化存储卡。
        let fd = open(plan.destination.path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        try? ledger.save(to: ledgerURL)
        outcome.copiedShots = copiedShots.count
        progress(filesDone, bytesDone)
        return finish()
    }

    /// 复制一个文件：.part → 校验 → 不覆盖地改名。返回账本 key（复制成功但读不回指纹就是 nil：
    /// 文件好好的，只是不记账，下次导进同一个文件夹时整份比对会认出来）。
    /// 错误分清楚：读卡出错 / 写目标出错 / 盘满 / 同名 —— 用户看到的原因不能全是「存储卡坏了」。
    /// 「复制原片到…」（OriginalsCopier）也走这一个：同一套校验、同一道绝不覆盖的闸。
    static func copyOne(_ copy: Copy, into destination: URL, cancel: AnalysisEngine.CancelFlag,
                                onBytes: (Int64) -> Void) throws -> String? {
        let fm = FileManager.default
        let name = copy.originalName
        let final = copy.target
        let part = final.deletingLastPathComponent().appendingPathComponent("." + final.lastPathComponent + ".part")
        try requireInside(final, destination)
        try requireInside(part, destination)
        // 计划之后才冒出来的同名文件（别的程序刚写进来）：不覆盖，报错跳过。
        if fm.fileExists(atPath: final.path) { throw ImportError.targetExists(final.lastPathComponent) }

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: copy.source)
        } catch {
            throw ImportError.readFailed(name, describe(error))
        }
        defer { try? input.close() }

        // 上次崩掉留下的半截 —— 是我们自己的临时文件，在目标文件夹里。
        if fm.fileExists(atPath: part.path) {
            do { try fm.removeItem(at: part) } catch { throw ImportError.writeFailed(name, describe(error)) }
        }
        guard fm.createFile(atPath: part.path, contents: nil) else {
            throw ImportError.writeFailed(name, "建不了临时文件")
        }
        var finished = false
        defer { if !finished { try? fm.removeItem(at: part) } }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: part)
        } catch {
            throw ImportError.writeFailed(name, describe(error))
        }
        func writeError(_ error: Error) -> ImportError {
            posixCode(error) == ENOSPC ? .diskFull(name) : .writeFailed(name, describe(error))
        }

        var hasher = SHA256()
        var written: Int64 = 0
        do {
            while true {
                if cancel.isSet { throw ImportError.cancelled }
                let chunk: Data
                do {
                    chunk = try autoreleasepool { try input.read(upToCount: 8 << 20) } ?? Data()
                } catch {
                    throw ImportError.readFailed(name, describe(error))
                }
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                do { try output.write(contentsOf: chunk) } catch { throw writeError(error) }
                written += Int64(chunk.count)
                onBytes(Int64(chunk.count))
            }
            do {
                try output.synchronize()
                try output.close()
            } catch {
                throw writeError(error)
            }
        } catch {
            try? output.close()
            throw error
        }
        let onDisk = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard written == copy.size, onDisk == copy.size else { throw ImportError.sizeMismatch(name) }
        let reread: SHA256.Digest
        do { reread = try sha256(of: part) } catch { throw ImportError.writeFailed(name, describe(error)) }
        guard reread == hasher.finalize() else { throw ImportError.verifyFailed(name) }

        // 时间戳跟原片一样：访达按日期排、分析的增量复用（大小 + 修改时间）都靠它。改的是目标里的 .part。
        var attrs: [FileAttributeKey: Any] = [:]
        if let m = copy.modified { attrs[.modificationDate] = m }
        if let c = copy.created { attrs[.creationDate] = c }
        if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: part.path) }

        // RENAME_EXCL：目标已存在就失败 —— 原子的「绝不覆盖」。
        if renamex_np(part.path, final.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST { throw ImportError.targetExists(final.lastPathComponent) }
            throw ImportError.writeFailed(name, String(cString: strerror(code)))
        }
        finished = true
        guard let fp = try? fingerprint(final, size: copy.size) else { return nil }
        return Ledger.key(name: name, size: copy.size, fingerprint: fp)
    }

    // MARK: 小工具

    /// 所有写操作的闸：只许是目标文件夹的直接子项（存储卡上的东西永远不碰）。
    /// 比的是目录本身（设备号 + inode），不比路径字符串 —— /tmp 和 /private/tmp、大小写、软链接都骗不过它。
    static func requireInside(_ url: URL, _ folder: URL) throws {
        let name = url.lastPathComponent
        var parent = stat(), root = stat()
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              stat(url.deletingLastPathComponent().path, &parent) == 0, stat(folder.path, &root) == 0,
              parent.st_dev == root.st_dev, parent.st_ino == root.st_ino else {
            throw ImportError.unsafePath(url.path)
        }
    }

    /// a 在 b 里面（或就是 b）吗。两个都得存在。
    private static func isWithin(_ a: URL, _ b: URL) -> Bool {
        let pa = a.resolvingSymlinksInPath().path, pb = b.resolvingSymlinksInPath().path
        return pa == pb || pa.hasPrefix(pb.hasSuffix("/") ? pb : pb + "/")
    }

    /// 头尾各 64KB 的 SHA-256（不到 128KB 就整个文件），取前 16 字节。只当身份用（账本 key、先筛），
    /// 不当「两个文件一样」的证据。
    static func fingerprint(_ url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 64 * 1024
        if size <= Int64(chunk * 2) {
            hasher.update(data: try handle.readToEnd() ?? Data())
        } else {
            hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
            try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of url: URL, cancel: AnalysisEngine.CancelFlag? = nil) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancel?.isSet == true { throw ImportError.cancelled }
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    /// 错误里的 POSIX 错误码（Foundation 包了一层的也挖出来）。
    static func posixCode(_ error: Error) -> Int32? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            return Int32(under.code)
        }
        guard ns.domain == NSCocoaErrorDomain else { return nil }
        switch ns.code {
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return EACCES
        case NSFileWriteOutOfSpaceError: return ENOSPC
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return ENOENT
        default: return nil
        }
    }

    /// 给人看的原因：不用 Foundation 那句「你没有权限存储文件」之类读着不对路的话。
    static func describe(_ error: Error) -> String {
        switch posixCode(error) {
        case EACCES?, EPERM?: return "没有权限"
        case EIO?: return "I/O 错误"
        case ENOENT?: return "文件不见了"
        case ENOSPC?: return "盘满了"
        case ENXIO?, ENODEV?: return "设备断开了"
        default: return (error as NSError).localizedDescription
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func firstDotKey(_ name: String) -> String {
        String(name.lowercased().split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// 目标所在的盘还剩多少（目标还不存在就往上找存在的那一级）。
    static func freeBytes(near url: URL) -> Int64? {
        let probe = existingAncestor(of: url)
        guard let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return v.volumeAvailableCapacityForImportantUsage
    }

    /// 自己或往上第一个存在的那一级。
    private static func existingAncestor(of url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return probe
    }
}

extension CardImporter.Plan {
    /// 「312 张 · 624 个文件（RAW 312 · 其他 312）· 18.4 GB」
    var summaryLine: String {
        let files = copies.count
        let raw = rawCount
        let breakdown = raw == 0 || raw == files ? "" : "（RAW \(raw) · 其他 \(files - raw)）"
        let fileText = files == shotCount ? "" : " · \(files) 个文件\(breakdown)"
        return "\(shotCount) 张\(fileText) · \(BatchStore.sizeText(totalBytes))"
    }

    /// 「卡上有 2 处读不出来：DCIM/101CANON、DCIM/102CANON」
    var scanProblemText: String? {
        guard !scanProblems.isEmpty else { return nil }
        let shown = scanProblems.prefix(3).joined(separator: "、") + (scanProblems.count > 3 ? " 等" : "")
        return "卡上有 \(scanProblems.count) 处读不出来：\(shown)"
    }

    /// 「3 个其他文件没导入（如 IMG_0008.WAV）」
    var otherFilesText: String? {
        guard otherCount > 0 else { return nil }
        return "\(otherCount) 个其他文件没导入（如 \(otherExamples.joined(separator: "、"))）"
    }
}

extension CardImporter.Outcome {
    /// 没导进来的文件数：计划的减去导进来的（中途停下时后面没试的也算）。
    var missingFiles: Int { max(plannedFiles - copiedFiles, failed.count) }

    var summary: String {
        var text: String
        if cancelled {
            text = "已取消导入：导进来 \(copiedShots) 张，存储卡上的照片没动，下次插卡会接着导剩下的"
        } else if let aborted {
            text = "导入中断：\(aborted)（已导进来 \(copiedShots) 张）"
        } else {
            text = "导入完成：\(copiedShots) 张 · \(BatchStore.sizeText(copiedBytes)) · 用时 \(Self.durationText(elapsed))"
        }
        if !cancelled && missingFiles > 0 { text += " · \(missingFiles) 个文件没导进来" }
        if !scanProblems.isEmpty { text += " · 卡上有 \(scanProblems.count) 处读不出来" }
        return text
    }

    /// 要用户记住的那句（BatchStore.importNotice）：有文件没导进来、卡上有读不出来的地方、中途停了。
    /// 用户自己点的取消不算（他知道）。
    func notice(card: String) -> String? {
        var parts: [String] = []
        if !cancelled && missingFiles > 0 {
            let names = failed.prefix(4).map(\.name).joined(separator: "、") + (failed.count > 4 ? " 等" : "")
            let why = failed.first.map { "：\(names)（\($0.reason)）" } ?? ""
            parts.append("\(missingFiles) 个文件没导进来\(why)")
        }
        if !scanProblems.isEmpty {
            let shown = scanProblems.prefix(2).joined(separator: "、") + (scanProblems.count > 2 ? " 等" : "")
            parts.append("卡上有 \(scanProblems.count) 处读不出来（\(shown)），那里的照片没导")
        }
        if let aborted { parts.append(aborted) }
        guard !parts.isEmpty else { return nil }
        return "存储卡「\(card)」：" + parts.joined(separator: "；") + " —— 先别格式化存储卡，再插一次会只补没导的"
    }

    static func durationText(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(max(s, 0)) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 小时 \(s % 3600 / 60) 分"
    }
}

// MARK: - BatchStore：导入和分析共用进度条 / 取消按钮

extension BatchStore {
    /// 导入一张卡。确认框里的计划只当「导哪张卡、导到哪、要不要重导」：开始时按卡和目标文件夹现在的
    /// 样子重新做一遍计划 —— 确认框可能开了很久，同一个文件夹也可能刚导过另一张卡（审查发现：拿旧计划
    /// 逐个文件处理冲突，会把两台相机同号的 RAW 和 JPG 拼成一张）。
    /// 导完不直接切场次：记在 `finishedImport`，BatchView 闲着就打开（正在挑片 / 审片就留横幅）。
    func importFromCard(_ plan: CardImporter.Plan, analyzeAfter: Bool) {
        guard !isRunning else {
            lastError = "正在处理中，先点“取消”再导入"
            return
        }
        isRunning = true
        importing = true
        importingSource = plan.source
        lastError = nil
        progressFraction = nil
        progressText = "核对存储卡「\(plan.sourceName)」…"
        let flag = freshCancelFlag()
        let ledgerURL = dataDir.appendingPathComponent(CardImporter.ledgerFileName)
        let started = Date()
        let card = plan.sourceName
        // 进度回调是 Task 排进主线程的，可能比收尾那一下晚到 —— 收尾之后的一律不算。
        let live = ImportLiveBox()

        Task.detached { [weak self] in
            let fresh: CardImporter.Plan
            do {
                fresh = try CardImporter.plan(source: plan.source, destination: plan.destination,
                                              ledger: CardImporter.Ledger.load(from: ledgerURL),
                                              includeImported: plan.includeImported, cancel: flag)
            } catch {
                await MainActor.run { [weak self] in
                    live.on = false
                    guard let self else { return }
                    self.isRunning = false
                    self.importing = false
                    self.importingSource = nil
                    if flag.isSet {
                        self.progressText = "已取消导入，存储卡上的照片没动"
                    } else {
                        self.progressText = ""
                        self.addImportNotice("存储卡「\(card)」读不了（\(CardImporter.describe(error))），没导 —— 先别格式化存储卡")
                    }
                    // 这张没导成，前面排队导完的那批还等着打开、分析（审查发现：以前会就此没人管）。
                    self.importCompletions += 1
                }
                return
            }
            let total = max(fresh.totalBytes, 1)
            let fileCount = fresh.copies.count
            let outcome = CardImporter.execute(fresh, ledgerURL: ledgerURL, cancel: flag) { files, bytes in
                Task { @MainActor [weak self] in
                    guard let self, live.on else { return }
                    let elapsed = Date().timeIntervalSince(started)
                    var text = "导入中 \(files)/\(fileCount) 个文件 · \(BatchStore.sizeText(bytes))/\(BatchStore.sizeText(total))"
                    if elapsed > 5, bytes > 0 {
                        let remaining = elapsed / Double(bytes) * Double(total - bytes)
                        text += " · 还要约 \(CardImporter.Outcome.durationText(max(1, remaining)))"
                    }
                    self.progressText = text
                    self.progressFraction = Double(bytes) / Double(total)
                }
            }
            await MainActor.run { [weak self] in
                live.on = false
                guard let self else { return }
                self.isRunning = false
                self.importing = false
                self.importingSource = nil
                self.progressFraction = nil
                self.progressText = outcome.summary
                if let notice = outcome.notice(card: card) { self.addImportNotice(notice) }
                if !outcome.cancelled, outcome.aborted == nil,
                   outcome.copiedFiles > 0 || !fresh.alreadyThere.isEmpty {
                    self.recordFinishedImport(CardImporter.FinishedImport(folder: fresh.destination, analyze: analyzeAfter,
                                                                          shots: outcome.copiedShots))
                }
                self.importCompletions += 1
            }
        }
    }

    /// 记下导完的一批。同一个文件夹（连着导了几张卡）就合起来：张数相加，有一张要分析就分析。
    /// 不同文件夹（比如跨了午夜）：横幅换成新的这批，旧的那批写进提醒，不能没人管。
    private func recordFinishedImport(_ new: CardImporter.FinishedImport) {
        guard let earlier = finishedImport else {
            finishedImport = new
            return
        }
        if earlier.folder.standardizedFileURL.path == new.folder.standardizedFileURL.path {
            finishedImport = CardImporter.FinishedImport(folder: new.folder, analyze: earlier.analyze || new.analyze,
                                                         shots: earlier.shots + new.shots)
        } else {
            finishedImport = new
            addImportNotice("\(earlier.shots) 张导到了 \(CardImporter.displayPath(earlier.folder))，还没打开、没分析 —— " +
                            "用文件夹菜单「选择文件夹…」打开它")
        }
    }

    /// 一张卡导完（或没导成）的那一刻：排队的都导完了、没在跑别的、用户也没在挑片审片 → 打开导完的那批，
    /// 要分析就分析。还有卡排着队就先不开（开了也不能分析，分析的请求会丢 —— 审查发现）。用户在忙就
    /// 什么都不做，横幅留着等他点。
    func openFinishedImportIfReady(userBusy: Bool) {
        guard finishedImport != nil, queuedCardImports == 0, !isRunning, !userBusy else { return }
        openFinishedImport()
    }

    /// 横幅上的「打开并分析」/「打开」。
    func openFinishedImport() {
        guard let done = finishedImport, !isRunning else { return }
        finishedImport = nil
        switchSession(to: done.folder)
        if done.analyze { runAnalysis() }
    }

    /// 导入的提醒攒着（几张卡各有问题时都留着），最多 3 条，用户点掉才没。
    func addImportNotice(_ text: String) {
        var lines = importNotice.map { $0.components(separatedBy: "\n") } ?? []
        lines.append(text)
        importNotice = lines.suffix(3).joined(separator: "\n")
    }
}

/// 只在主线程上读写。
private final class ImportLiveBox: @unchecked Sendable {
    var on = true
}

// MARK: - 无头测试

/// LABELGUI_DATA_DIR=<临时> LabelGUI --ingest <card_dir> --dest <dir> [--reimport] [--plan-only] [--cancel-after N]
///   [--cancel-at-bytes B] [--via-store [--no-analyze]] [--ledger-cap N] [--plant-after-plan 文件名]
/// 账本在 LABELGUI_DATA_DIR 里；必须给 --dest —— 测试不往真的「图片」文件夹里写。
/// --cancel-after N：复制完 N 个文件就取消；--cancel-at-bytes B：复制到第 B 字节（文件中间）就取消
/// —— 验证 .part 清干净、账本只记了导完的。--plant-after-plan：计划做完、复制之前往目标里放一个同名文件
/// （模拟同一个文件夹刚导过另一张卡），验证整张跳过、不拆 RAW+JPG。这条路直接调 execute（不重做计划），
/// 测的就是 execute 自己的防线；--via-store 走界面那条（会重做计划）。
enum CardImportCLI {
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        if (ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? "").isEmpty {
            print("--ingest 会写导入账本：先设 LABELGUI_DATA_DIR=<临时目录> 再跑（不能碰真实数据）")
            exit(2)
        }
        guard let destPath = option("--dest") else {
            print("--ingest 必须给 --dest <目标文件夹>（测试不往真的「图片」里写）")
            exit(2)
        }
        let card = URL(fileURLWithPath: args[flagIndex + 1]).standardizedFileURL
        let dest = URL(fileURLWithPath: destPath).standardizedFileURL
        if let cap = option("--ledger-cap").flatMap(Int.init) { CardImporter.Ledger.cap = cap }
        let ledgerURL = appDataDir.appendingPathComponent(CardImporter.ledgerFileName)
        let plan: CardImporter.Plan
        do {
            plan = try CardImporter.plan(source: card, destination: dest,
                                         ledger: CardImporter.Ledger.load(from: ledgerURL),
                                         includeImported: args.contains("--reimport"))
        } catch {
            print("读卡失败: \(CardImporter.describe(error))")
            exit(1)
        }
        print(describe(plan))
        for copy in plan.copies {
            print("  \(copy.source.pathComponents.suffix(3).joined(separator: "/")) → \(copy.target.lastPathComponent)")
        }
        if args.contains("--plan-only") { exit(0) }

        if let planted = option("--plant-after-plan") {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try? Data("planted by test".utf8).write(to: dest.appendingPathComponent(planted))
        }

        // --via-store：走界面同一条路 —— BatchStore.importFromCard（重做计划 → 复制）→ 像 BatchView 闲着时那样
        // 打开目标文件夹 → 自动开始分析，等全部跑完再打印。
        if args.contains("--via-store") {
            MainActor.assumeIsolated {
                let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
                let before = store.photoDir?.path ?? "-"
                store.importFromCard(plan, analyzeAfter: !args.contains("--no-analyze"))
                let deadline = Date().addingTimeInterval(900)
                // 像 BatchView 那样：每导完一张的那一刻看要不要打开。
                let watch = store.$importCompletions.dropFirst().sink { _ in
                    DispatchQueue.main.async { store.openFinishedImportIfReady(userBusy: false) }
                }
                while Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    if !store.importing && !store.isRunning && store.finishedImport == nil { break }
                }
                withExtendedLifetime(watch) {}
                print("导入前打开的：\(before)")
                print("现在打开的：\(store.photoDir?.path ?? "-") · \(store.items.count) 张 · \(store.progressText)")
                if let notice = store.importNotice { print("导入提醒：\(notice)") }
                if let error = store.lastError { print("lastError：\(error)") }
            }
            exit(0)
        }

        let flag = AnalysisEngine.CancelFlag()
        let cancelAfter = option("--cancel-after").flatMap(Int.init)
        let cancelAtBytes = option("--cancel-at-bytes").flatMap(Int64.init)
        let outcome = CardImporter.execute(plan, ledgerURL: ledgerURL, cancel: flag, progressInterval: 0) { files, bytes in
            if let n = cancelAfter, files >= n { flag.set() }
            if let b = cancelAtBytes, bytes >= b { flag.set() }
        }
        print(outcome.summary + "（\(outcome.copiedFiles) 个文件）")
        print(String(format: "elapsed=%.3f", outcome.elapsed))
        for f in outcome.failed { print("  失败 \(f.name)：\(f.reason)") }
        if let notice = outcome.notice(card: plan.sourceName) { print("导入提醒：\(notice)") }
        let clean = outcome.failed.isEmpty && outcome.aborted == nil && outcome.scanProblems.isEmpty
        exit(clean ? 0 : 1)
    }

    static func describe(_ plan: CardImporter.Plan) -> String {
        var lines = ["卡「\(plan.sourceName)」：照片 \(plan.cardShots) 张 / \(plan.cardFiles) 个文件 · 视频 \(plan.videoCount)"]
        lines.append(plan.copies.isEmpty ? "要导入：没有" : "要导入：\(plan.summaryLine)")
        lines.append("跳过：以前导入过 \(plan.skippedImported) 张 · 目标里已有 \(plan.skippedInDest) 张 · 改名 \(plan.renamedShots) 张" +
                     (plan.previousFolders.isEmpty ? "" : " · 以前导到 \(plan.previousFolders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))") +
                     (plan.previousFolderGone ? "（那个文件夹已经不在了）" : ""))
        if let other = plan.otherFilesText { lines.append("其他文件：\(other)") }
        if let problems = plan.scanProblemText { lines.append("读不出来：\(problems)") }
        lines.append("目标：\(CardImporter.displayPath(plan.destination))（原有 \(plan.existingInDest) 个文件）· 空间\(plan.enoughSpace ? "够" : "不够")")
        return lines.joined(separator: "\n")
    }
}
