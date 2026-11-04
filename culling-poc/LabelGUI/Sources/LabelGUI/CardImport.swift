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
        /// 必须已经在的那一级（外接盘上的导入根目录 / 「导进已有的文件夹」）：导的时候不在了就停，
        /// 不顺着建一串目录（盘没挂上时会建到系统盘上去）。nil = 「图片」那条老路。
        let mustExist: URL?
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
        /// 以前导到的文件夹在一块现在没插上的盘上（/Volumes/<名字>）：那不是「文件夹没了」，是盘没插。
        let previousVolumeOffline: String?
        /// 目标里已经有、内容一模一样的（张）。
        let skippedInDest: Int
        /// 和目标里别的照片重名、整组改了名的（张）。
        let renamedShots: Int
        /// 改了名的里面，RAW+JPG 一起改的（张）—— 只有这些才是「改了名还是一对」。
        let renamedWithPair: Int
        /// 改了名的头一个新主名（确认框举例：IMG_0001_2）。
        let renamedExample: String?
        /// 改了名的里面，目标里同主名的是另一类（RAW↔JPG）、但文件头读不全（拍摄时间 / SubSec / 型号 /
        /// 机身序列号）、认不准是不是同一帧的（张）—— 这些没配成一对，会多出一张。
        let unconfirmedHalves: Int
        /// 目标里同主名只有另一类、文件头确认是同一帧（RAW、JPG 分卡存的另一张卡）：补在旁边、不改名（张）。
        let pairedShots: Int
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
        /// 第二份备份（没开 = nil）。
        var backup: Backup?

        var totalBytes: Int64 { copies.reduce(0) { $0 + $1.size } }
        var shotCount: Int { Set(copies.map(\.shot)).count }
        var rawCount: Int { copies.filter { CardImporter.rawLikeExtensions.contains($0.target.pathExtension.lowercased()) }.count }
        var enoughSpace: Bool { primaryEnoughSpace && backupEnoughSpace }
        /// 有事可做：有新照片要导，或者（勾了重导时）只是要补备份。
        var hasWork: Bool { !copies.isEmpty || (backup?.fileCount ?? 0) > 0 }
        /// 导入位置那块盘够不够（备份在同一块盘上就连备份一起算）。
        var primaryEnoughSpace: Bool {
            guard let free = freeBytes else { return true }
            var alsoBackup: Int64 = 0
            if let backup, backup.sameVolume { alsoBackup = backup.totalBytes }
            let need = totalBytes + alsoBackup
            return free >= need + CardImporter.spaceMargin
        }
        var backupEnoughSpace: Bool {
            guard let backup, !backup.sameVolume, let free = backup.freeBytes else { return true }
            return free >= backup.totalBytes + CardImporter.spaceMargin
        }

        /// 第二份备份（Photo Mechanic 的 Secondary、Lightroom 的「Make a Second Copy To」）：主目标那份校验过
        /// 以后，从主目标那份再走一遍 copyOne 写到备份盘 —— 同样 .part + SHA-256 校验、绝不覆盖。两边用同一个
        /// 名字（选名字时两边都得空着）。账本照旧只记主目标。
        struct Backup {
            let destination: URL
            /// 备份根目录（必须已经在：盘拔了就停备份，不顺着建目录）。
            let mustExist: URL?
            /// 主目标复制完、要再备份一份的文件（按主目标里的路径）。
            let afterPrimary: Set<String>
            /// 主目标里已经有、备份里还没有的：从主目标那份补过去（「补备份」：勾「以前导入过的也再导一遍」再插卡）。
            let fromPrimary: [Copy]
            /// 备份里已经有、内容一样的文件数。
            let alreadyBackedUp: Int
            /// 主目标里已经有、备份里同名的却是别的文件：名字改不了，这几张没法备份（张）。
            let conflicts: Int
            let existingInBackup: Int
            /// 要往备份写的字节、文件数。
            let totalBytes: Int64
            let fileCount: Int
            var freeBytes: Int64?
            /// 和导入位置在同一块盘上（空间一起算；盘坏了两份一起没 —— 确认框提醒一句）。var：离屏快照假装两块盘。
            var sameVolume: Bool
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
        /// 导进来的里面和目标里别的照片重名、改了名的（张）和一个例子（新主名）—— 导完照实说一句：
        /// 双读卡器同时插两张卡时，确认框里的改名数是前一张卡导到一半时算的，不准。
        var renamedShots = 0
        var renamedExample: String?
        /// 第二份备份（没开 = nil）：写到哪、该写几个、写成了几个、哪些没写成。
        var backupDestination: URL?
        var backupPlannedFiles = 0
        var backupCopiedFiles = 0
        var backupFailed: [Failure] = []
        /// 备份整个停了的原因（备份盘拔了、满了、空间不够、和导入位置重叠）—— 主目标照常导完。
        var backupAborted: String?
        /// 主目标里已经有、备份里同名的却是别的文件，没法备份（张）。
        var backupConflicts = 0
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
    /// `backup`：第二份备份写到哪（Target 的 destination / mustExist；没开备份 = nil）。
    static func plan(source: URL, destination: URL, mustExist: URL? = nil, backup: Target? = nil,
                     ledger: Ledger, includeImported: Bool,
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
        // 备份那边现有的文件（同样分桶）：选名字时两边都得空着（或者已经是这张）。
        var backupIndex: [String: [URL]]?
        var existingInBackup = 0
        if let backup {
            var index: [String: [URL]] = [:]
            if let contents = try? fm.contentsOfDirectory(at: backup.destination, includingPropertiesForKeys: [.fileSizeKey]) {
                for url in contents where !url.lastPathComponent.hasPrefix(".") {
                    index[firstDotKey(url.lastPathComponent), default: []].append(url)
                    existingInBackup += 1
                }
            }
            backupIndex = index
        }
        /// 目标里属于这个名字的文件：IMG_0001.CR3 / IMG_0001.jpg / IMG_0001.xmp / IMG_0001.CR3.xmp。
        func occupants(of stem: String, in index: [String: [URL]]) -> [URL] {
            let lower = stem.lowercased() + "."
            return (index[firstDotKey(stem)] ?? []).filter { $0.lastPathComponent.lowercased().hasPrefix(lower) }
        }

        // 同一文件夹里同名的算一张（RAW+JPG）—— 和 listPhotos 配对规则一样，区分大小写。
        let groups = Dictionary(grouping: files) { $0.url.deletingPathExtension().path }
        var planned: Set<String> = []          // 这次已经分出去的名字（小写）
        var copies: [Copy] = []
        var alreadyThere: [(key: String, path: String)] = []
        var skippedImported = 0, skippedInDest = 0, renamedShots = 0
        var renamedWithPair = 0, unconfirmedHalves = 0, pairedShots = 0
        var renamedExample: String?
        var backupAfter: Set<String> = []
        var backupFromPrimary: [Copy] = []
        var backupAlready = 0, backupConflicts = 0
        var backupBytes: Int64 = 0
        var backupFiles = 0
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
        var identities: [URL: FrameIdentity?] = [:]
        var frameChecks = 0
        func identity(_ url: URL) -> FrameIdentity? {
            if let cached = identities[url] { return cached }
            let id = frameIdentity(of: url)
            identities[url] = id
            return id
        }
        /// 卡上这张的每个文件、目标里的另一半，文件头是不是同一帧：nil = 有一样读不到。
        func sameFrame(_ members: [CardFile], _ halves: [URL]) -> Bool? {
            frameChecks += 1
            if frameChecks % 50 == 1 { progress?("核对目标里同名的 RAW / JPG 是不是同一帧（第 \(frameChecks) 张）…") }
            var ids: [FrameIdentity] = []
            for url in members.map(\.url) + halves {
                guard let id = identity(url) else { return nil }
                ids.append(id)
            }
            return ids.allSatisfy { $0 == ids[0] }
        }
        /// 占着某个名字的文件分一分：这张本身（内容整份一样）、同一帧的另一半候选、.xmp、不相干的。
        func examine(_ stem: String, _ taken: [URL], _ members: [CardFile], kind: Bool?)
            -> (identical: Set<String>, halves: [URL], foreign: Bool, sidecar: Bool) {
            var identical: Set<String> = []     // 已经在的成员（原文件名）
            var halves: [URL] = []              // 同主名（大小写也一样）的另一类：可能是同一帧的另一半
            var foreign = false, sidecar = false
            for url in taken {
                let name = url.lastPathComponent.lowercased()
                if let m = members.first(where: { (stem + "." + $0.ext).lowercased() == name }), sameContent(m, url) {
                    identical.insert(m.name)
                } else if url.pathExtension.lowercased() == "xmp" {
                    sidecar = true
                } else if let kind, url.deletingPathExtension().lastPathComponent == stem,
                          pairKind(url.pathExtension) == !kind {
                    halves.append(url)
                } else {
                    foreign = true
                }
            }
            return (identical, halves, foreign, sidecar)
        }
        /// 备份里这个名字能不能用：空着、已经是这张、或者是文件头确认了的另一半。能用时返回备份里已经有的成员。
        func backupFits(_ stem: String, _ members: [CardFile], kind: Bool?) -> Set<String>? {
            guard let backupIndex else { return [] }
            let taken = occupants(of: stem, in: backupIndex)
            if taken.isEmpty { return [] }
            let e = examine(stem, taken, members, kind: kind)
            if e.foreign { return nil }
            let missing = members.filter { !e.identical.contains($0.name) }
            if missing.isEmpty { return e.identical }
            var paired = false
            if !e.halves.isEmpty {
                guard sameFrame(members, e.halves) == true else { return nil }
                paired = true
            }
            if e.sidecar && !paired { return nil }
            return e.identical
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
            // 这张全是 RAW（true）或全是 JPG 这一类（false）时，目标里同主名的另一类可能是它的另一半。
            let kinds = Set(members.map { pairKind($0.ext) })
            var memberKind: Bool?
            if kinds.count == 1, let only = kinds.first { memberKind = only }
            var n = 1
            // backupDone：备份里已经有的成员；nil = 备份里这个名字被别的文件占着（主目标里已经有了、改不了名）。
            var chosen: (stem: String, missing: [CardFile], paired: Bool, backupDone: Set<String>?)?
            var baseUnconfirmed = false
            while chosen == nil, n < 10_000 {
                if cancel?.isSet == true { throw ImportError.cancelled }
                let stem = n == 1 ? baseStem : "\(baseStem)_\(n)"
                n += 1
                if planned.contains(stem.lowercased()) { continue }
                let taken = occupants(of: stem, in: destIndex)
                var missing = members
                var paired = false
                if !taken.isEmpty {
                    let e = examine(stem, taken, members, kind: memberKind)
                    if e.foreign { continue }
                    missing = members.filter { !e.identical.contains($0.name) }
                    if !missing.isEmpty {
                        // RAW、JPG 分卡存：目标里同主名只有另一类。文件头说是同一帧才补在旁边、不改名；读不全（nil）
                        // 或者对不上，都当成别的照片，换下一个名字（两台同号机身的 RAW、JPG 不能拼成一张）。
                        if !e.halves.isEmpty {
                            let same = sameFrame(members, e.halves)
                            if same == nil, stem == baseStem { baseUnconfirmed = true }
                            guard same == true else { continue }
                            paired = true
                        }
                        // 补缺的文件不往一个已经有 .xmp 的名字上挂：那份 xmp 不一定是这张的。文件头确认了的另一半
                        // 旁边的 .xmp 就是这一帧的（Lightroom 给 RAW 写的那份），放行。
                        if e.sidecar && !paired { continue }
                    }
                }
                // 备份：两边用同一个名字。要新复制的，名字在备份里也得能用，不然换一个两边都空着的；
                // 主目标里已经都有了的，名字改不了 —— 备份里被占着就记成「没法备份」。
                let fit = backupFits(stem, members, kind: memberKind)
                if fit == nil && !missing.isEmpty { continue }
                chosen = (stem, missing, paired, fit)
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
            // 备份：这张的每个文件在备份里都该有一份（同一个名字）。新复制的等主目标校验过再备份；主目标里
            // 早就有的从主目标那份补。
            if let backup, backupIndex != nil {
                if let done = chosen.backupDone {
                    backupAlready += done.count
                    for m in members where !done.contains(m.name) {
                        let name = chosen.stem + "." + m.ext
                        let primaryTarget = destination.appendingPathComponent(name)
                        backupBytes += m.size
                        backupFiles += 1
                        if chosen.missing.contains(where: { $0.url == m.url }) {
                            backupAfter.insert(primaryTarget.path)
                        } else {
                            backupFromPrimary.append(Copy(source: primaryTarget,
                                                          target: backup.destination.appendingPathComponent(name),
                                                          size: m.size, modified: m.modified, created: m.created,
                                                          originalName: m.name, shot: groupKey))
                        }
                    }
                } else {
                    backupConflicts += 1
                }
            }
            if chosen.missing.isEmpty {
                skippedInDest += 1
                continue
            }
            if chosen.stem != baseStem {
                renamedShots += 1
                if renamedExample == nil { renamedExample = chosen.stem }
                if kinds.contains(true) && kinds.contains(false) { renamedWithPair += 1 }
                if baseUnconfirmed { unconfirmedHalves += 1 }
            }
            if chosen.paired { pairedShots += 1 }
            for m in chosen.missing {
                copies.append(Copy(source: m.url, target: destination.appendingPathComponent(chosen.stem + "." + m.ext),
                                   size: m.size, modified: m.modified, created: m.created,
                                   originalName: m.name, shot: groupKey))
            }
        }

        let folders = previousFolders.sorted { $0.value > $1.value }.map(\.key)
        // 以前导到的那个文件夹不在：盘没插上（/Volumes/<名字> 没挂）和文件夹真没了，说法不一样。
        let previousMissing = folders.first.map { !isDirectory(URL(fileURLWithPath: $0)) } ?? false
        let previousOffline = previousMissing ? folders.first.flatMap(offlineVolumeName(for:)) : nil
        return Plan(source: source, sourceName: source.lastPathComponent, destination: destination,
                    mustExist: mustExist,
                    copies: copies, alreadyThere: alreadyThere,
                    cardShots: groups.count, cardFiles: files.count,
                    skippedImported: skippedImported,
                    previousFolders: folders,
                    previousFolderGone: previousMissing && previousOffline == nil,
                    previousVolumeOffline: previousOffline,
                    skippedInDest: skippedInDest, renamedShots: renamedShots,
                    renamedWithPair: renamedWithPair, renamedExample: renamedExample,
                    unconfirmedHalves: unconfirmedHalves, pairedShots: pairedShots, videoCount: videos,
                    otherCount: others.count, otherExamples: Array(others.prefix(3)),
                    scanProblems: problems,
                    includeImported: includeImported, existingInDest: existingInDest,
                    freeBytes: freeBytes(near: destination),
                    backup: backup.map { b in
                        Plan.Backup(destination: b.destination, mustExist: b.mustExist,
                                    afterPrimary: backupAfter, fromPrimary: backupFromPrimary,
                                    alreadyBackedUp: backupAlready, conflicts: backupConflicts,
                                    existingInBackup: existingInBackup,
                                    totalBytes: backupBytes, fileCount: backupFiles,
                                    freeBytes: freeBytes(near: b.destination),
                                    sameVolume: sameVolume(destination, b.destination))
                    })
    }

    /// 两个位置在不在同一块盘上（还不存在的往上找存在的那一级）。
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(existingAncestor(of: a).path, &sa) == 0, stat(existingAncestor(of: b).path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev
    }

    // MARK: 执行

    /// 照计划复制。`progress(已完成文件数, 已复制字节)` 从后台线程来，最多每 `progressInterval` 秒一次。
    /// 按「张」走：一张照片的几个文件（RAW+JPG）先一起看目标名字还空不空，空着才开始复制。
    /// 有第二份备份时，主目标的每个文件校验过就从主目标那份再写一份到备份盘；备份出问题只停备份、照实报。
    /// `backupFault`：测试用（第 N 次备份当成这个错误），平常不传。
    static func execute(_ plan: Plan, ledgerURL: URL, cancel: AnalysisEngine.CancelFlag,
                        progressInterval: TimeInterval = 0.1,
                        backupFault: ((Int) -> ImportError?)? = nil,
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

        // 外接盘上的导入位置 / 选的已有文件夹，确认之后被拔掉、删掉了：不导（往上找存在的那一级会落到系统盘）。
        if let must = plan.mustExist, !isDirectory(must) {
            outcome.aborted = "导入位置 \(displayPath(must)) 不见了（盘拔掉了？），没导"
            return finish()
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
            if plan.mustExist == nil {
                try fm.createDirectory(at: plan.destination, withIntermediateDirectories: true)
            } else if !isDirectory(plan.destination) {
                // 只在已经在的那一级下面建一层（yyyyMMdd），不连上级一起建。
                try fm.createDirectory(at: plan.destination, withIntermediateDirectories: false)
            }
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

        // 第二份备份：主目标那份校验过以后，从主目标再走一遍 copyOne（同样 .part + SHA-256、绝不覆盖）。
        // 备份盘出问题（拔了、满了、写不进去）只停备份、照实报，主目标照常导完 —— 下面那些停法只盯卡和主目标。
        var backupStop: String?
        var backupWriteFailures = 0
        var backupAttempts = 0
        if let backup = plan.backup {
            outcome.backupDestination = backup.destination
            outcome.backupPlannedFiles = backup.fileCount
            outcome.backupConflicts = backup.conflicts
            backupStop = prepareBackup(backup, for: plan)
        }
        /// 备份一个文件。false = 用户取消了。
        func backupOne(_ copy: Copy) -> Bool {
            guard let backup = plan.backup, backupStop == nil else { return true }
            if !isDirectory(backup.destination) {
                backupStop = "备份盘找不到了，被拔掉了？"
                return true
            }
            backupAttempts += 1
            do {
                if let fault = backupFault?(backupAttempts) { throw fault }
                _ = try copyOne(copy, into: backup.destination, cancel: cancel) { delta in
                    bytesDone += delta
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= progressInterval {
                        lastReport = now
                        progress(filesDone, bytesDone)
                    }
                }
                outcome.backupCopiedFiles += 1
                backupWriteFailures = 0
            } catch ImportError.cancelled {
                return false
            } catch let error as ImportError {
                // 原因里的「目标」说的是备份盘（「备份盘满了」「备份里已经有 X，没覆盖」）。
                let reason = error.shortReason.replacingOccurrences(of: "目标", with: "备份")
                outcome.backupFailed.append(Failure(name: copy.originalName, reason: reason))
                switch error {
                case .diskFull:
                    backupStop = "备份盘满了"
                case .unsafePath:
                    backupStop = error.shortReason
                case .writeFailed, .readFailed, .verifyFailed, .sizeMismatch:
                    backupWriteFailures += 1
                    if backupWriteFailures >= 3 {
                        backupStop = "备份连续 \(backupWriteFailures) 个文件没写成（\(error.shortReason)），停了备份"
                    }
                case .targetExists, .unreadable, .cancelled:
                    break
                }
            } catch {
                outcome.backupFailed.append(Failure(name: copy.originalName, reason: describe(error)))
            }
            return true
        }

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
            // 用 lstat 看（entryExists）：悬空的符号链接 fileExists 看不见，到改名那一步才撞上，就拆开了。
            if let clash = members.first(where: { entryExists($0.target) }) {
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
                    if let backup = plan.backup, backup.afterPrimary.contains(copy.target.path) {
                        let second = Copy(source: copy.target,
                                          target: backup.destination.appendingPathComponent(copy.target.lastPathComponent),
                                          size: copy.size, modified: copy.modified, created: copy.created,
                                          originalName: copy.originalName, shot: copy.shot)
                        if !backupOne(second) {
                            outcome.cancelled = true
                            break shotLoop
                        }
                    }
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
        // 主目标里早就有、备份里还没有的：从主目标那份补到备份（不读卡）。
        if !outcome.cancelled, let backup = plan.backup {
            for copy in backup.fromPrimary {
                if backupStop != nil { break }
                if cancel.isSet || !backupOne(copy) {
                    outcome.cancelled = true
                    break
                }
            }
            let bfd = open(backup.destination.path, O_RDONLY)
            if bfd >= 0 { _ = fcntl(bfd, F_FULLFSYNC); close(bfd) }
        }
        outcome.backupAborted = backupStop
        // 一次 F_FULLFSYNC 把盘的写缓存刷下去 —— 用户看到「导入完成」可能马上就去格式化存储卡。
        let fd = open(plan.destination.path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        try? ledger.save(to: ledgerURL)
        outcome.copiedShots = copiedShots.count
        var renamed: [String: String] = [:]     // 张 → 新主名
        for copy in plan.copies where copiedShots.contains(copy.shot) {
            let newStem = copy.target.deletingPathExtension().lastPathComponent
            if newStem != (copy.originalName as NSString).deletingPathExtension { renamed[copy.shot] = newStem }
        }
        outcome.renamedShots = renamed.count
        outcome.renamedExample = renamed.values.sorted().first
        progress(filesDone, bytesDone)
        return finish()
    }

    /// 备份能不能开始：备份根目录在、不和卡 / 导入位置重叠、空间够，然后建备份文件夹。不行就返回原因（只停备份）。
    private static func prepareBackup(_ backup: Plan.Backup, for plan: Plan) -> String? {
        if let must = backup.mustExist, !isDirectory(must) {
            return "备份位置 \(displayPath(must)) 不见了，盘没插上？这次没备份"
        }
        let probe = existingAncestor(of: backup.destination)
        if isWithin(probe, plan.source) || isWithin(plan.source, backup.destination) {
            return "备份位置和存储卡重叠了，没备份"
        }
        if isWithin(probe, plan.destination) || isWithin(plan.destination, backup.destination) {
            return "备份位置和导入位置是同一个地方，没备份"
        }
        if let free = freeBytes(near: backup.destination) {
            // 和导入位置在同一块盘上：主目标那份也要从这块盘里出。
            let alsoPrimary: Int64 = backup.sameVolume ? plan.totalBytes : 0
            let need = backup.totalBytes + alsoPrimary
            if free < need + spaceMargin {
                return "备份盘空间不够：要 \(BatchStore.sizeText(need))，只剩 \(BatchStore.sizeText(free))，没备份"
            }
        }
        do {
            if backup.mustExist == nil {
                try FileManager.default.createDirectory(at: backup.destination, withIntermediateDirectories: true)
            } else if !isDirectory(backup.destination) {
                try FileManager.default.createDirectory(at: backup.destination, withIntermediateDirectories: false)
            }
        } catch {
            return "建不了备份文件夹 \(displayPath(backup.destination))：\(describe(error))，没备份"
        }
        return nil
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
        // 不是每种卷都支持它：SMB / NFS 共享、部分 exFAT 盘（macOS 14 的 exfat 内核扩展实测过；15 以后换成
        // FSKit，没实测）回 ENOTSUP。只在 ENOTSUP 时退回：lstat 看正式名字在不在，不在再普通 rename ——
        // 这两步之间不是原子的，所以在这些非 APFS 卷上「绝不覆盖」降成了尽力而为（整张开始前、copyOne 开头
        // 都已经查过同名，剩下的是几微秒的窗口）。用 lstat 不用 fileExists：fileExists 跟着符号链接走，
        // 悬空的符号链接会被当成「不存在」然后被 rename 盖掉。EINVAL 不算「不支持」：macOS 上那是 flags
        // 不合法或路径本身有问题，照常报错。
        var renameCode: Int32 = 0
        if pretendNoExclusiveRename {
            renameCode = ENOTSUP
        } else if renamex_np(part.path, final.path, UInt32(RENAME_EXCL)) != 0 {
            renameCode = errno
        }
        if renameCode == ENOTSUP {
            var existing = stat()
            if lstat(final.path, &existing) == 0 { throw ImportError.targetExists(final.lastPathComponent) }
            let probe = errno
            // 连「在不在」都说不清（没权限、I/O 错）：不冒险改名。
            if probe != ENOENT { throw ImportError.writeFailed(name, describe(errnoError(probe))) }
            if rename(part.path, final.path) != 0 {
                let code = errno
                if code == ENOSPC { throw ImportError.diskFull(name) }
                throw ImportError.writeFailed(name, describe(errnoError(code)))
            }
        } else if renameCode != 0 {
            if renameCode == EEXIST { throw ImportError.targetExists(final.lastPathComponent) }
            throw ImportError.writeFailed(name, String(cString: strerror(renameCode)))
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

    /// 这个名字上有没有东西（lstat：符号链接本身也算，悬空的也算）。
    static func entryExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
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

    /// 系统调用的 errno 包成错误，交给 describe 出中文原因。
    static func errnoError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    /// 测试用：LABELGUI_TEST_NO_RENAME_EXCL=1 假装目标卷不支持 RENAME_EXCL（走 copyOne 的 ENOTSUP 退路）。
    /// 只在设了 LABELGUI_DATA_DIR（隔离的测试数据目录）时生效，正常使用碰不到。
    static let pretendNoExclusiveRename: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["LABELGUI_TEST_NO_RENAME_EXCL"] == "1" && !(env["LABELGUI_DATA_DIR"] ?? "").isEmpty
    }()

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
        case ENOTSUP?: return "这块盘 / 共享不支持这个操作"
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
    /// 「重要用途可用」只有 APFS 算得准：exFAT / FAT / SMB 这些外接盘上常是 nil（会当成够）或 0（会永远不够），
    /// 那时退回普通的「可用」，再不行问 statfs。
    static func freeBytes(near url: URL) -> Int64? {
        let probe = existingAncestor(of: url)
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let plain = v?.volumeAvailableCapacity { return Int64(plain) }
        var fs = statfs()
        if statfs(probe.path, &fs) == 0 {
            let blocks = Int64(fs.f_bavail)
            let blockSize = Int64(fs.f_bsize)
            return blocks * blockSize
        }
        return v?.volumeAvailableCapacityForImportantUsage
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

    /// 该备份、没备份成的文件数（主目标那份没导进来的，备份里当然也没有）。
    var backupMissingFiles: Int { max(backupPlannedFiles - backupCopiedFiles, backupFailed.count) }
    /// 开了备份、备份没做全：「先别格式化」要两份都校验过才不说。
    var backupIncomplete: Bool {
        backupDestination != nil && (backupMissingFiles > 0 || backupAborted != nil || backupConflicts > 0)
    }

    /// 「备份没写全：3 个文件没备份到 T7 › 备份 › 20261104（备份盘满了）」
    var backupProblemText: String? {
        guard let dest = backupDestination, backupIncomplete else { return nil }
        let place = CardImporter.displayPath(dest)
        var lines: [String] = []
        if backupMissingFiles > 0 || backupAborted != nil {
            let why = backupAborted ?? backupFailed.first?.reason ?? "没写成"
            lines.append("备份没写全：\(backupMissingFiles) 个文件没备份到 \(place)（\(why)）")
        }
        if backupConflicts > 0 {
            lines.append("\(backupConflicts) 张备份里同名的是别的文件，没法备份（在 \(place)）")
        }
        return lines.joined(separator: "；")
    }

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
        if let renamedText { text += " · " + renamedText }
        if let dest = backupDestination, !cancelled {
            if backupIncomplete {
                text += " · 备份没做完" + (backupAborted.map { "（\($0)）" } ?? "（\(backupMissingFiles) 个文件没备份）")
            } else {
                text += " · 另备份 \(backupCopiedFiles) 个文件到 \(CardImporter.displayPath(dest))"
            }
        }
        return text
    }

    /// 「3 张和目标里别的照片重名，改名导入了（如 IMG_0001_2）」
    var renamedText: String? {
        guard renamedShots > 0 else { return nil }
        let example = renamedExample.map { "（如 \($0)）" } ?? ""
        return "\(renamedShots) 张和目标里别的照片重名，改名导入了\(example)"
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
        // 备份没做全：电脑上只有一份，同样先别格式化。补备份：再插卡勾「以前导入过的也再导一遍」——
        // 主目标里内容一样的不会重复复制，只从主目标那份补到备份。
        let backupHint = !cancelled ? backupProblemText : nil
        if let backupHint { parts.append(backupHint) }
        // 改了名不是「先别格式化」的理由（照片都好好导进来了），只照实说一句。
        let info = [renamedText].compactMap { $0 }
        if parts.isEmpty {
            guard !info.isEmpty else { return nil }
            return "存储卡「\(card)」：" + info.joined(separator: "；")
        }
        var tail = " —— 先别格式化存储卡，再插一次会只补没导的"
        if backupHint != nil {
            tail += "（补备份要勾「以前导入过的也再导一遍」，已经导进来的不会重复复制）"
        }
        return "存储卡「\(card)」：" + (parts + info).joined(separator: "；") + tail
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
                                              mustExist: plan.mustExist,
                                              backup: plan.backup.map {
                                                  CardImporter.Target(destination: $0.destination, mustExist: $0.mustExist,
                                                                      appending: false, issue: nil)
                                              },
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
            // 有备份时字节连备份一起算（进度条走到头 = 两份都写完）。
            let total = max(fresh.totalBytes + (fresh.backup?.totalBytes ?? 0), 1)
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
        // 确认框里正开着选文件夹的面板（换导入位置）：也算在忙，横幅留着（BatchView 的 modalPanelOpen 管不到那个面板）。
        guard finishedImport != nil, queuedCardImports == 0, !isRunning, !userBusy,
              !CardImportCenter.pickingFolder else { return }
        openFinishedImport()
    }

    /// 横幅上的「打开并分析」/「打开」。
    func openFinishedImport() {
        guard let done = finishedImport, !isRunning else { return }
        finishedImport = nil
        // 导到外接盘上、还没打开盘就拔了：别打开一个空场次，说一声（照片在那块盘上，插回去用「选择文件夹…」打开）。
        if !CardImporter.directoryExists(done.folder) {
            addImportNotice("\(done.shots) 张导到了 \(CardImporter.displayPath(done.folder))，那里现在打不开（盘拔掉了？）—— " +
                            "插回去以后用文件夹菜单「选择文件夹…」打开")
            return
        }
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
///   [--plant-symlink-after-plan 文件名] [--plant-symlink-mid 文件名] [--rename-after-plan 路径]
///   （--dest 也可以换成 --dest-root <根目录> / --into-existing <已有文件夹> / --use-saved-settings，
///    配 --save-settings 把 --dest-root 记进数据目录 —— 走界面那套「导到哪」，见 CardImportDestinations.swift）
///   [--backup <备份根目录>] [--backup-full-at N] [--unplug-backup-after N]（第二份备份；后两个是测试备份盘满、被拔）
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
        // 导到哪：--dest 直接给目标文件夹（老用法）；或者走界面那套 —— --dest-root 导入根目录（按今天建 yyyyMMdd）、
        // --into-existing 导进已有的文件夹、--use-saved-settings 用数据目录里记住的根目录（--save-settings 先记下）。
        // 哪个都没给（或记住的是「图片」）就拒绝：测试不往真的「图片」里写。
        var settings = args.contains("--use-saved-settings") ? CardImporter.DestinationSettings.load(from: appDataDir)
            : CardImporter.DestinationSettings()
        if let root = option("--dest-root") {
            settings.root = CardImporter.savedFolder(for: URL(fileURLWithPath: root))
        }
        // --backup <根目录>：同时写第二份备份（在它里面建和导入位置同名的文件夹）。
        if let backupRoot = option("--backup") {
            settings.backup = CardImporter.savedFolder(for: URL(fileURLWithPath: backupRoot))
            settings.backupEnabled = true
        }
        if args.contains("--save-settings") { settings.save(to: appDataDir) }
        let target: CardImporter.Target
        if let destPath = option("--dest") {
            target = CardImporter.Target(destination: URL(fileURLWithPath: destPath).standardizedFileURL,
                                         mustExist: nil, appending: false, issue: nil)
        } else if let existing = option("--into-existing") {
            target = CardImporter.target(settings: settings, choice: .existing(URL(fileURLWithPath: existing)))
        } else if settings.root != nil {
            target = CardImporter.target(settings: settings, choice: .saved)
        } else {
            print("--ingest 必须给 --dest <目标文件夹>（或 --dest-root / --into-existing；测试不往真的「图片」里写）")
            exit(2)
        }
        if let issue = target.issue {
            print("导入位置有问题：\(issue)")
            exit(3)
        }
        let backupTarget = CardImporter.backupTarget(settings: settings, primary: target)
        if let issue = backupTarget?.issue {
            print("备份位置有问题：\(issue)")
            exit(3)
        }
        let card = URL(fileURLWithPath: args[flagIndex + 1]).standardizedFileURL
        let dest = target.destination
        if let cap = option("--ledger-cap").flatMap(Int.init) { CardImporter.Ledger.cap = cap }
        let ledgerURL = appDataDir.appendingPathComponent(CardImporter.ledgerFileName)
        let plan: CardImporter.Plan
        do {
            plan = try CardImporter.plan(source: card, destination: dest, mustExist: target.mustExist,
                                         backup: backupTarget,
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
        // 悬空的符号链接（fileExists 看不见它）：--plant-symlink-after-plan 计划做完就放（验证整张跳过）；
        // --plant-symlink-mid 第一个文件复制完才放（整张检查已经过了，只剩改名那道闸 —— 配
        // LABELGUI_TEST_NO_RENAME_EXCL=1 验证 RENAME_EXCL 的退路用 lstat 查、不会把它盖掉）。
        func plantSymlink(_ name: String) {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: dest.appendingPathComponent(name).path,
                                                        withDestinationPath: "nowhere-planted-by-test")
        }
        if let planted = option("--plant-symlink-after-plan") { plantSymlink(planted) }
        var midSymlink = option("--plant-symlink-mid")
        // --rename-after-plan 路径：计划做完、复制之前把它挪走（模拟确认之后外接盘被拔掉）—— 验证不导、
        // 也不在原来的路径上重新建出文件夹（那会落到系统盘上）。
        if let path = option("--rename-after-plan") {
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".moved")
        }
        // 备份盘的两种意外（测试用）：--backup-full-at N 第 N 次备份当成「盘满了」；--unplug-backup-after N
        // 主目标导完 N 个文件后把备份根目录挪走（像被拔掉）。主目标都要照常导完。
        let backupFullAt = option("--backup-full-at").flatMap(Int.init)
        var unplugBackupAfter = option("--unplug-backup-after").flatMap(Int.init)
        let backupRootPath = option("--backup")

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
        let fault: ((Int) -> CardImporter.ImportError?)? = backupFullAt.map { at in
            { attempt in attempt == at ? CardImporter.ImportError.diskFull("备份测试") : nil }
        }
        let outcome = CardImporter.execute(plan, ledgerURL: ledgerURL, cancel: flag, progressInterval: 0,
                                           backupFault: fault) { files, bytes in
            if let n = cancelAfter, files >= n { flag.set() }
            if let b = cancelAtBytes, bytes >= b { flag.set() }
            if files >= 1, let name = midSymlink {
                midSymlink = nil
                plantSymlink(name)
            }
            if let n = unplugBackupAfter, files >= n, let root = backupRootPath {
                unplugBackupAfter = nil
                try? FileManager.default.moveItem(atPath: root, toPath: root + ".unplugged")
            }
        }
        print(outcome.summary + "（\(outcome.copiedFiles) 个文件）")
        print(String(format: "elapsed=%.3f", outcome.elapsed))
        for f in outcome.failed { print("  失败 \(f.name)：\(f.reason)") }
        if outcome.backupDestination != nil {
            print("备份：写成 \(outcome.backupCopiedFiles)/\(outcome.backupPlannedFiles) 个文件" +
                  (outcome.backupAborted.map { " · 停了：\($0)" } ?? ""))
            for f in outcome.backupFailed { print("  备份失败 \(f.name)：\(f.reason)") }
        }
        if let notice = outcome.notice(card: plan.sourceName) { print("导入提醒：\(notice)") }
        let clean = outcome.failed.isEmpty && outcome.aborted == nil && outcome.scanProblems.isEmpty
            && !outcome.backupIncomplete
        exit(clean ? 0 : 1)
    }

    static func describe(_ plan: CardImporter.Plan) -> String {
        var lines = ["卡「\(plan.sourceName)」：照片 \(plan.cardShots) 张 / \(plan.cardFiles) 个文件 · 视频 \(plan.videoCount)"]
        lines.append(plan.copies.isEmpty ? "要导入：没有" : "要导入：\(plan.summaryLine)")
        lines.append("跳过：以前导入过 \(plan.skippedImported) 张 · 目标里已有 \(plan.skippedInDest) 张 · 改名 \(plan.renamedShots) 张" +
                     (plan.previousFolders.isEmpty ? "" : " · 以前导到 \(plan.previousFolders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))") +
                     (plan.previousFolderGone ? "（那个文件夹已经不在了）" : "") +
                     (plan.previousVolumeOffline.map { "（那块盘「\($0)」没插上）" } ?? ""))
        if plan.pairedShots > 0 || plan.unconfirmedHalves > 0 {
            lines.append("RAW/JPG 配对：补成一对 \(plan.pairedShots) 张 · 认不准没配 \(plan.unconfirmedHalves) 张")
        }
        if plan.renamedShots > 0 {
            lines.append("改名：\(plan.renamedShots) 张（如 \(plan.renamedExample ?? "-")）· 其中 RAW+JPG 一起改 \(plan.renamedWithPair) 张")
        }
        if let other = plan.otherFilesText { lines.append("其他文件：\(other)") }
        if let problems = plan.scanProblemText { lines.append("读不出来：\(problems)") }
        lines.append("目标：\(CardImporter.displayPath(plan.destination))（原有 \(plan.existingInDest) 个文件）· 空间\(plan.enoughSpace ? "够" : "不够")")
        if let must = plan.mustExist { lines.append("必须已经在：\(must.path)") }
        if let backup = plan.backup {
            let space = plan.backupEnoughSpace ? "够" : "不够"
            let same = backup.sameVolume ? " · 和导入位置同一块盘" : ""
            let place = "备份：\(CardImporter.displayPath(backup.destination))（原有 \(backup.existingInBackup) 个文件）"
            let work = " · 要备份 \(backup.fileCount) 个文件（补备份 \(backup.fromPrimary.count) 个）"
            let rest = " · 备份里已有 \(backup.alreadyBackedUp) 个 · 没法备份 \(backup.conflicts) 张 · 空间\(space)\(same)"
            lines.append(place + work + rest)
        }
        return lines.joined(separator: "\n")
    }
}
