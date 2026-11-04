import Foundation

// MARK: - 实时桥写工具回报「存上没有」（审查 S01b）
//
// 判决、客户选中写盘失败时 BatchStore 有常驻红条（persistError），拼图写失败有 collage.lastError，但以前 AI 拿到的回复
// 照常是成功、窗口看不见时还说「改动已生效并已存盘」。现在 cull_set_verdicts、app_undo、cull_import_client_picks
// 和拼图的写工具结果里都带 persisted（true / false），没存上时另加一条 save_failed 警告，「已存盘」只在真存上时说。

/// 最近一次写某个 collage.json 的结果：存盘队列上写完当场记下（CollageStore.saveProject 的写盘闭包里），
/// 主线程 flushSaves 之后读到的就是最新的 —— 不靠 lastError：后台那次写失败的 lastError 是 Task @MainActor 晚一拍设的，
/// 写成功也不清它。按文件记：换了场次，上一场的失败不算到这一场头上。
final class CollageWriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var failure: String?

    func record(_ url: URL, failure: String?) {
        lock.lock()
        self.url = url
        self.failure = failure
        lock.unlock()
    }

    /// 这个文件最近一次写失败的原因；写上了、或者还没写过 = nil。
    func failure(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return self.url == url ? failure : nil
    }

    func reset() {
        lock.lock()
        url = nil
        failure = nil
        lock.unlock()
    }
}

extension LiveHandlers {
    /// 一个写工具回复里的 persisted 和 save_failed 警告。
    struct PersistReport {
        let persisted: Bool
        let warnings: [[String: Any]]
    }

    /// 判决这边：这一步动过的几份（判决 overrides.json、客户选中 client_picks.json）现在还有没存上的 → persisted false。
    /// 写失败（盘满）的原话用批量页红条那一句（persistError：哪份、为什么、怎么办）；原件读坏了这一场先不写的另说。
    static func batchPersistReport(_ batch: BatchStore, _ files: [BatchStore.PersistFile]) -> PersistReport {
        let unsaved = batch.unsavedFiles(files)
        guard !unsaved.failed.isEmpty || !unsaved.refused.isEmpty else { return PersistReport(persisted: true, warnings: []) }
        var warnings: [[String: Any]] = []
        if !unsaved.failed.isEmpty {
            let what = unsaved.failed.map(\.label).joined(separator: "、")
            let banner = batch.persistError ?? "\(what)没存上"
            warnings.append(MCPReadModel.warning(
                "save_failed", "改动在 app 里已经生效，但没存上盘，现在只在内存里：选片工具说「\(banner)」",
                hint: "照原话告诉用户：先腾出磁盘空间，再点批量页顶上红条的「重试」；存上之前 app 不让切场次，也先别退出"))
        }
        if !unsaved.refused.isEmpty {
            let what = unsaved.refused.map(\.label).joined(separator: "、")
            warnings.append(MCPReadModel.warning(
                "save_failed", "改动在 app 里已经生效，但这一场的\(what)文件原件读不出来，为免覆盖 app 这一场先不存它（现在只在内存里）",
                hint: "照原话告诉用户：看批量页顶上的提醒，修好或移走那个文件后重新打开这一场"))
        }
        return PersistReport(persisted: false, warnings: warnings)
    }

    /// 拼图这边：CollageStore.projectSaveProblem（flushSaves 之后读）。
    static func collagePersistReport(_ problem: String?) -> PersistReport {
        guard let problem else { return PersistReport(persisted: true, warnings: []) }
        let warning = MCPReadModel.warning(
            "save_failed", "改动在 app 里已经生效，但拼图工程没存上盘，现在只在内存里：选片工具说「\(problem)」",
            hint: "照原话告诉用户：先腾出磁盘空间（或者看拼图页底下的提示）；之后拼图上随便改一下 app 会整份再存一次")
        return PersistReport(persisted: false, warnings: [warning])
    }

    /// 窗口看不见时那条 window_not_visible 的话：存上了才说「已存盘」。
    nonisolated static func windowNotVisibleText(_ why: String, persisted: Bool) -> String {
        let done: String = persisted ? "改动已生效并已存盘" : "改动已在 app 里生效、但没存上盘（见 save_failed）"
        return done + "，但用户现在看不到选片工具的窗口（\(why)）：请告诉用户切过去看；MCP 不会替用户把窗口拉出来。"
    }
}
