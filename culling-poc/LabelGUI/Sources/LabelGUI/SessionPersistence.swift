import Foundation
import os

// MARK: - 场次目录里的小文件：读坏了不静默当空（全项目审查 S02）
//
// 判决（overrides.json / accepted.json）、客户选中、机身对时、阈值、确认表记录、拼图工程都是 KB 级的 JSON，每次整份
// 重写。以前读的时候「文件不存在」和「在、但解不开」走同一条路 —— 当空的，下一次保存就把原件整份盖掉（按一次 1/2/3
// 一场几百条人工改判就没了）。现在先分清这两种：解不开的照存储卡导入账本（CardImporter.Ledger.load）挪成
// `<名字>.corrupt-<时间>.json` 保住原件、提示，然后从空的开始；读不出来（权限、I/O）或者挪不动的，这一场不写它。

enum SessionFiles {
    static let log = Logger(subsystem: "local.culling.labelgui", category: "persist")

    /// 读一份 JSON 的结果。
    enum Read<T> {
        /// 没有这个文件（新场次的常态，不是错）。
        case missing
        case ok(T)
        /// 在、但解不开（手改坏了、截断、零长度）。关联值 = 原件挪到了哪；nil = 挪不动（或者调用方说了不挪）。
        case corrupt(URL?)
        /// 在、但读不出来（权限、I/O；关联值是给人看的原因）：没挪，原件还在原处，不能拿空的去盖它。
        case unreadable(String)
    }

    /// `moveAside: false`：只看不动（导入框每敲一个字都要读一次确认表记录，那条路不挪文件）。`stamp` 见 moveAside。
    static func read<T: Decodable>(_ type: T.Type, at url: URL, moveAside: Bool = true, stamp: String? = nil) -> Read<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.error("读不出 \(url.path, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            return .unreadable(CardImporter.describe(error))
        }
        if let value = try? JSONDecoder().decode(T.self, from: data) { return .ok(value) }
        guard moveAside else { return .corrupt(nil) }
        return .corrupt(self.moveAside(url, stamp: stamp))
    }

    /// 挪成同一个目录下的 `<名字>.corrupt-<yyyyMMdd-HHmmss>.<扩展名>`，同名已有就加 -2、-3（不盖掉上一次挪开的）。
    /// `stamp` 给定时用它：overrides.json 和 accepted.json 一起挪，时间一样好配对。返回挪到了哪；挪不动 = nil。
    @discardableResult
    static func moveAside(_ url: URL, stamp: String? = nil) -> URL? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(stamp ?? timestamp())"
        func named(_ name: String) -> URL { dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)") }
        var target = named(base)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = named("\(base)-\(n)")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
            log.notice("解不开，挪成 \(target.path, privacy: .public)")
            return target
        } catch {
            log.error("解不开、也挪不动 \(url.path, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// 打开这一场以后第一次改写某个文件之前复制一份 `<名字>.bak`（照 LabelStore 的 backedUpSinceLoad）：这一次
    /// 打开以后被改坏、改空了，打开时的那一版还在。只留一份（下次打开再换）。复制失败只记日志，不挡保存：
    /// 盘满了接下来的写本来也会失败、会报出来。
    @discardableResult
    static func backup(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        let bak = url.appendingPathExtension("bak")
        do {
            if fm.fileExists(atPath: bak.path) { try fm.removeItem(at: bak) }
            try fm.copyItem(at: url, to: bak)
            return true
        } catch {
            log.error("备份 \(url.lastPathComponent, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 写失败只记日志的那几样（阈值、场次索引、确认表记录：丢了能自己补回来，不值得一条红条）。
    @discardableResult
    static func writeLogged(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("写 \(url.path, privacy: .public) 失败：\(CardImporter.describe(error), privacy: .public)")
            return false
        }
    }

    /// 删一个文件；本来就没有不算错（别的错照样抛：删不掉的话重开以后旧数据会回来）。
    static func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        }
    }
}
