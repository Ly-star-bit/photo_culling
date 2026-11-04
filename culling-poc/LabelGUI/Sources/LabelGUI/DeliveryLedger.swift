import Foundation
import Darwin

// MARK: - 交付对照：导出的文件名 → 照片 id / 原片（这一场的 exports.json）
//
// 导出 JPG、精华 Top N、水印页每导一次，记下「写出去的文件名 → 哪一张照片、原片在哪」，存在这一场的会话目录
// （exports.json，只留最近 30 次）。不写进导出文件夹：那个文件夹是整个发给客户的。
// 用处：客户按交付文件名回复（精华的 01_DSCF7207、水印页的 DSCF7207_wm、自定义模板的 20261021_017），
// 「导入客户选择」靠它认回原片（ClientReply 的 Lookup）；以后精修图对回原片也从这里起步。
// 只认本工具导出时记下的名字：在 Lightroom 里另外改名导出的、这一版以前导出的，照样对不上（列在「没认出」里，不猜）。

struct DeliveryRecord: Codable, Equatable {
    /// 哪个出口。存成字符串（`kind`），以后加出口旧版也读得了。
    enum Kind: String {
        case jpeg, highlights, watermark
    }

    struct File: Codable, Equatable {
        /// 写出去的文件名（带 .jpg；同名另存的 -2、-3 照实记）。
        var file: String
        /// 照片 id。
        var id: String
        /// 原片路径（RAW+JPG 一对记 RAW）。
        var original: String
    }

    var id: String
    var at: Date
    /// jpeg = 导出 JPG，highlights = 精华 Top N，watermark = 水印页。
    var kind: String
    /// 导出到的文件夹。
    var folder: String
    /// 按导出顺序（精华按名次）。只有真写出去的；失败的不记。
    var files: [File]

    init(kind: Kind, folder: URL, files: [File], at: Date = Date()) {
        id = UUID().uuidString
        self.at = at
        self.kind = kind.rawValue
        self.folder = folder.path
        self.files = files
    }
}

enum DeliveryLedger {
    static let fileName = "exports.json"
    /// 和确认表记录一样，只留最近 30 次。
    static let limit = 30

    /// 坏掉的单条跳过，别的照用。
    private struct Lenient: Decodable {
        let record: DeliveryRecord?
        init(from decoder: Decoder) throws { record = try? DeliveryRecord(from: decoder) }
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 修改时间 + 大小：导入客户选择边打字边认，每敲一个字都要读一遍，没变就用上次解出来的。
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    @MainActor private static var cache: (path: String, stamp: Stamp, records: [DeliveryRecord])?

    private static func stamp(_ url: URL) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(modified: attrs[.modificationDate] as? Date, size: (attrs[.size] as? NSNumber)?.intValue)
    }

    /// 解出来的记录；nil = 整份不是记录的数组（坏了）。
    private static func decode(_ data: Data) -> [DeliveryRecord]? {
        (try? decoder().decode([Lenient].self, from: data)).map { $0.compactMap(\.record) }
    }

    /// 这一场的对照，最早的在前。没有 / 读不出 = 空。
    @MainActor static func load(_ url: URL) -> [DeliveryRecord] {
        guard let now = stamp(url) else { return [] }
        if let cache, cache.path == url.path, cache.stamp == now { return cache.records }
        let records = (try? Data(contentsOf: url)).flatMap(decode) ?? []
        cache = (url.path, now, records)
        return records
    }

    /// 盘上的一条：解得开的记录，或者解不开的那一条原样（新版本改了字段、手改坏了一条）—— 写回去时原样留着，
    /// 不在下一次记一笔时悄悄丢掉（照 sessions.json 的 SessionsIndexFile.unknown）。
    private enum Entry {
        case record(DeliveryRecord)
        case raw(Data)
    }

    /// 一条一条解；nil = 整份不是数组（截断、零长度、手改坏了括号）。
    private static func entries(_ data: Data) -> [Entry]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any] else {
            return nil
        }
        let d = decoder()
        return array.compactMap { element -> Entry? in
            // sortedKeys：同一条每次序列化出来一字不差。
            guard let raw = try? JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed, .sortedKeys])
            else { return nil }
            if let record = try? d.decode(DeliveryRecord.self, from: raw) { return .record(record) }
            return .raw(raw)
        }
    }

    /// 记一笔的结果。
    enum AppendResult: Equatable {
        /// 写进去了。`movedCorrupt` = 原来那份整份解不开，原件挪到了哪（exports.corrupt-<时间>.json）。
        case written(movedCorrupt: URL?)
        /// 原件在、却读不出来（权限、I/O），或者解不开又挪不开：没写，原件原样留着（拿空的去盖就全没了）。关联值是原因。
        case refused(String)
        /// 写不进去（盘满了……）。关联值是原因。
        case writeFailed(String)
    }

    /// 记一次（只留最近 30 次）。和场次里别的小文件一样（SessionPersistence.swift，审查 S02）分清四种：没有 = 从空的开始；
    /// 解不开 = 先挪成 exports.corrupt-<时间>.json（同名已有加 -2，不盖掉上一次挪开的）再写；读不出来、挪不开 = 不写；
    /// 解得开的照用，其中解不开的单条原样写回去。
    @MainActor @discardableResult
    static func append(_ record: DeliveryRecord, to url: URL) -> AppendResult {
        var kept: [Entry] = []
        var moved: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                SessionFiles.log.error("读不出 \(url.path, privacy: .public)：\(error.localizedDescription, privacy: .public)")
                return .refused("读不出来（\(CardImporter.describe(error))）")
            }
            if let old = entries(data) {
                kept = old
            } else if let target = SessionFiles.moveAside(url) {
                moved = target
            } else {
                return .refused("解不开、也挪不开")
            }
        }
        let all = Array((kept + [.record(record)]).suffix(limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let records = all.compactMap { entry -> DeliveryRecord? in
            if case .record(let r) = entry { return r }
            return nil
        }
        let data: Data
        do {
            if records.count == all.count {
                data = try encoder.encode(records)
            } else {
                var out = Data("[".utf8)
                for (i, entry) in all.enumerated() {
                    if i > 0 { out.append(contentsOf: Array(",".utf8)) }
                    switch entry {
                    case .record(let r): out.append(try encoder.encode(r))
                    case .raw(let raw): out.append(raw)
                    }
                }
                out.append(contentsOf: Array("]".utf8))
                data = out
            }
            try data.write(to: url, options: .atomic)
        } catch {
            SessionFiles.log.error("写 \(url.path, privacy: .public) 失败：\(CardImporter.describe(error), privacy: .public)")
            return .writeFailed(CardImporter.describe(error))
        }
        if let now = stamp(url) { cache = (url.path, now, records) }
        return .written(movedCorrupt: moved)
    }

    /// 文件本身（设备号 + inode）：大小写、软链接、/tmp 和 /private/tmp 都骗不过。文件不在 = nil。
    static func fileID(_ path: String) -> String? {
        var st = stat()
        return stat(path, &st) == 0 ? "\(st.st_dev):\(st.st_ino)" : nil
    }
}

// MARK: - BatchStore：读写这一场的交付对照

extension BatchStore {
    var deliveryLedgerPath: URL { sessionDir.appendingPathComponent(DeliveryLedger.fileName) }

    /// 这一场导出过的交付对照，最早的在前。
    var deliveryRecords: [DeliveryRecord] { DeliveryLedger.load(deliveryLedgerPath) }

    /// 导出 JPG / 精华写完以后记一笔。`ledger` 是开工时这一场的 exports.json（导出途中不让切场次，开工时拿住更稳）。
    /// 一张都没写出去不记。原来那份解不开、挪开了的提醒一句（dataNotice）；读不出来、写不进去的报 lastError。
    func recordDelivery(_ kind: DeliveryRecord.Kind, folder: URL, files: [DeliveryRecord.File], into ledger: URL) {
        guard !files.isEmpty else { return }
        let name = photoDir.map { "「\($0.lastPathComponent)」" } ?? ""
        let problem: String
        switch DeliveryLedger.append(DeliveryRecord(kind: kind, folder: folder, files: files), to: ledger) {
        case .written(let moved):
            if let moved {
                addDataNotice("\(name)的交付对照 \(DeliveryLedger.fileName) 解不开（被手改过或写坏了），原件已挪成 " +
                              "\(moved.lastPathComponent)：以前导出的交付文件名，客户按它回复时认不出（这一次的照常记下了）")
            }
            return
        case .refused(let why):
            problem = "交付对照（\(DeliveryLedger.fileName)）\(why)，这次没记、也没改写它"
        case .writeFailed(let why):
            problem = "交付对照（\(DeliveryLedger.fileName)）没写进去（\(why)）"
        }
        lastError = (lastError.map { $0 + "；" } ?? "") + problem + "：客户按这次导出的文件名回复时认不出"
    }

    /// 水印页导出写完：原图按文件本身（设备号 + inode）对回这一场的照片，对上的记一笔。水印页的照片不一定是这一场的
    /// （拖进来的外部照片、切了场次）：对不上的不记，不按文件名猜 —— 别的日子同名的 DSCF7207 不能认成这一场的。
    func recordWatermarkDelivery(folder: URL, files: [(file: URL, source: URL)]) {
        guard photoDir != nil, !items.isEmpty, !files.isEmpty else { return }
        var byFile: [String: BatchItem] = [:]
        for item in items {
            for path in Set([item.rawPath, item.decodePath]) {
                if let key = DeliveryLedger.fileID(path), byFile[key] == nil { byFile[key] = item }
            }
        }
        let entries = files.compactMap { pair -> DeliveryRecord.File? in
            guard let key = DeliveryLedger.fileID(pair.source.path), let item = byFile[key] else { return nil }
            return DeliveryRecord.File(file: pair.file.lastPathComponent, id: item.id, original: item.rawPath)
        }
        recordDelivery(.watermark, folder: folder, files: entries, into: deliveryLedgerPath)
    }
}

extension WatermarkStore {
    /// 水印页导出写完交给批量页，记进当前场次的交付对照（AppModel 和无头 --watermark-batch 接上）。
    func recordDeliveries(into batch: BatchStore) {
        onDelivered = { [weak batch] folder, files in
            batch?.recordWatermarkDelivery(folder: folder, files: files)
        }
    }
}
