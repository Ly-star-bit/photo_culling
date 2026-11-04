import Foundation

/// 跟进小修的自检（2026-11 全项目审查第二波，车道 F）：LABELGUI_DATA_DIR=<临时目录> LabelGUI --followup-selftest
/// 不要照片、不跑分析、不开界面：照 FileSafetySelfTest 在数据目录里造几场假的拍摄（小文件 + 手写的 manifest / layer1），逐条断言、
/// 打 PASS / FAIL：
///   - S01b 判决、客户选中、拼图写盘失败时，实时桥写工具的结果 persisted:false + save_failed，「已存盘」只在真存上时说
///     （场次目录 chmod 只读模拟盘满；后台那次拼图保存失败也算得上，不等 lastError 那一拍）。
/// 只写数据目录；改过的权限全部改回来，退出前删掉造出来的照片文件夹。
@MainActor
enum FollowupSelfTest {
    static let flag = "--followup-selftest"
    private static var failures = 0
    private static var total = 0
    /// chmod 过的目录 / 文件：退出前（包括中途出错）一律改回来，不然临时目录删不掉。
    private static var locked: [URL] = []

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok {
            print("PASS " + what)
        } else {
            failures += 1
            let extra = detail()
            print("FAIL " + what + (extra.isEmpty ? "" : "（" + extra + "）"))
        }
    }

    static func run() -> Never {
        CollageCLI.requireIsolatedDataDir(flag, "会在数据目录里造假的拍摄、改场次文件、复制文件")
        let root = appDataDir.appendingPathComponent("followup-selftest-" + String(UUID().uuidString.prefix(8)))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        persistReport(root.appendingPathComponent("persist"))
        unlockAll()
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "跟进小修自检：全部通过（\(total) 条）" : "跟进小修自检：\(failures) / \(total) 条失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 小工具

    static func setMode(_ url: URL, _ mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// 只读（模拟盘满：写 .atomic 的临时文件、改名都失败）。
    static func lock(_ url: URL) {
        setMode(url, 0o555)
        locked.append(url)
    }

    static func unlock(_ url: URL) {
        setMode(url, 0o755)
        locked.removeAll { $0 == url }
    }

    static func unlockAll() {
        for url in locked { setMode(url, 0o755) }
        locked = []
    }

    static func codes(_ warnings: [[String: Any]]) -> [String] {
        warnings.compactMap { $0["code"] as? String }
    }

    static func messages(_ warnings: [[String: Any]]) -> String {
        warnings.compactMap { $0["message"] as? String }.joined(separator: " | ")
    }

    static func diskOverrides(_ store: BatchStore) -> [String: String] {
        let url = store.sessionDir.appendingPathComponent("overrides.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    // MARK: - S01b 写盘失败要让实时桥的写工具知道

    static func persistReport(_ dir: URL) {
        print("— S01b 判决 / 客户选中 / 拼图没存上：写工具回 persisted:false + save_failed，「已存盘」只在真存上时说")
        typealias Fake = FileSafetySelfTest.Fake
        let store = FileSafetySelfTest.makeShoot(dir, [Fake(id: "A", raw: "A.JPG"), Fake(id: "B", raw: "B.JPG"),
                                                       Fake(id: "C", raw: "C.JPG")])
        let session = store.sessionDir
        check(store.items.count == 3, "造的一场有 3 张", "\(store.items.count)")

        // 正常：AI 改判当场写进 overrides.json，persisted true、没有警告；客户选中先有一张（client_picks.json 在盘上）
        store.applyAIOverrides([(id: "A", verdict: .reject)], opID: "op-ok", tool: "cull_set_verdicts")
        let fine = LiveHandlers.batchPersistReport(store, [.overrides])
        check(fine.persisted && fine.warnings.isEmpty && diskOverrides(store)["A"] == Verdict.reject.rawValue,
              "盘是好的：AI 改判 → persisted true、没有 save_failed，overrides.json 里有这一张", messages(fine.warnings))
        store.importClientPicks(["A"])
        check(LiveHandlers.batchPersistReport(store, [.clientPicks]).persisted, "盘是好的：导入客户选中 → persisted true")

        // 盘满（场次目录只读）：改判在内存里生效了，但写不上
        lock(session)
        store.applyAIOverrides([(id: "B", verdict: .pick)], opID: "op-full", tool: "cull_set_verdicts")
        let full = LiveHandlers.batchPersistReport(store, [.overrides])
        let banner = store.persistError ?? ""
        let fullText = messages(full.warnings)
        let fullOK: Bool = !full.persisted && codes(full.warnings) == ["save_failed"] && !banner.isEmpty
            && fullText.contains(banner) && store.overrides["B"] == .pick && diskOverrides(store)["B"] == nil
        check(fullOK, "写不上：AI 改判 → persisted false、一条 save_failed，原话带批量页红条那一句、内存里改了盘上没有",
              "persisted \(full.persisted) · \(fullText) · 红条 \(banner)")
        let hint = (full.warnings.first?["hint"] as? String) ?? ""
        check(hint.contains("重试"), "save_failed 的 hint 叫用户点红条的「重试」", hint)

        // 客户选中（cull_import_client_picks dry_run:false）同样报；只看这一步动的那一份
        store.importClientPicks(["C"])
        let picks = LiveHandlers.batchPersistReport(store, [.clientPicks])
        check(!picks.persisted && codes(picks.warnings) == ["save_failed"] && store.clientPicks.contains("C"),
              "写不上：导入客户选中 → persisted false + save_failed", messages(picks.warnings))
        // app_undo 撤掉 AI 那一步（这里撤的是客户选中）：撤销本身也没存上
        store.undoLastOverride()
        let undone = LiveHandlers.batchPersistReport(store, [.clientPicks])
        check(!undone.persisted && store.clientPicks == ["A"], "写不上：撤销客户选中 → 内存里撤了、persisted false",
              "persisted \(undone.persisted) · \(store.clientPicks.sorted())")

        // 窗口看不见那条话：没存上就不说「已存盘」
        let saidNo = LiveHandlers.windowNotVisibleText("窗口最小化了", persisted: false)
        let saidYes = LiveHandlers.windowNotVisibleText("窗口最小化了", persisted: true)
        check(!saidNo.contains("已存盘") && saidNo.contains("save_failed") && saidYes.contains("已存盘"),
              "window_not_visible：没存上时不说「已存盘」、指向 save_failed；存上了照旧", saidNo)

        // 腾出空间以后：下一次写把之前没存上的一起补上，persisted 回到 true、红条消失
        unlock(session)
        store.applyAIOverrides([(id: "C", verdict: .usable)], opID: "op-back", tool: "cull_set_verdicts")
        let back = LiveHandlers.batchPersistReport(store, [.overrides, .clientPicks])
        let disk = diskOverrides(store)
        check(back.persisted && back.warnings.isEmpty && store.persistError == nil
              && disk["B"] == Verdict.pick.rawValue && disk["C"] == Verdict.usable.rawValue,
              "腾出空间后再改一张：persisted true、红条没了，之前没存上的 B 也补写进 overrides.json", "\(disk)")

        // 原件读不出来（S02：这一场先不写它）：也算没存上，说法不一样
        let refusedDir = dir.deletingLastPathComponent().appendingPathComponent("persist-refused")
        _ = FileSafetySelfTest.makeShoot(refusedDir, [Fake(id: "R", raw: "R.JPG")])
        let refusedSession = appDataDir.appendingPathComponent("sessions/" + BatchStore.sessionKey(for: refusedDir))
        let overridesURL = refusedSession.appendingPathComponent("overrides.json")
        try? Data("{\"R\":\"精选\"}".utf8).write(to: overridesURL)
        setMode(overridesURL, 0o000)
        locked.append(overridesURL)
        let refusedStore = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        refusedStore.switchSession(to: refusedDir)
        refusedStore.applyAIOverrides([(id: "R", verdict: .reject)], opID: "op-refused", tool: "cull_set_verdicts")
        let refused = LiveHandlers.batchPersistReport(refusedStore, [.overrides])
        check(!refused.persisted && codes(refused.warnings) == ["save_failed"] && messages(refused.warnings).contains("读不出来"),
              "overrides.json 原件读不出来、这一场先不写：persisted false，save_failed 说是原件读不出来", messages(refused.warnings))
        unlock(overridesURL)

        collagePersist(session, photoDir: dir)
    }

    /// 拼图：flushSaves 之后读 projectSaveProblem —— 当场写失败、后台那次写失败（lastError 晚一拍）都要算上。
    static func collagePersist(_ session: URL, photoDir: URL) {
        let collage = CollageStore(dataDir: appDataDir)
        collage.attach(sessionDir: session, photoDir: photoDir, batch: nil)
        func touch() {
            var style = collage.project.style
            style.gutter += 0.002
            collage.setStyle(style, coalesce: false)
        }
        touch()
        let okProblem = collage.flushSaves()
        let ok = LiveHandlers.collagePersistReport(okProblem)
        check(okProblem == nil && ok.persisted && ok.warnings.isEmpty, "拼图盘是好的：flushSaves 回 nil、persisted true",
              okProblem ?? "")

        lock(session)
        touch()
        let now = collage.flushSaves()
        let nowReport = LiveHandlers.collagePersistReport(now)
        check(now?.hasPrefix("拼图项目保存失败") == true && !nowReport.persisted && codes(nowReport.warnings) == ["save_failed"],
              "拼图写不上（flushSaves 当场写）：回失败原因、persisted false + save_failed", now ?? "nil")

        // 后台那一次：改完等防抖的 1 s 过去、存盘队列上写失败；之后 flushSaves 没有排着的，也要报出来
        collage.lastError = nil
        touch()
        FileSafetySelfTest.waitUntil(1.8) { false }
        let late = collage.flushSaves()
        check(late?.hasPrefix("拼图项目保存失败") == true, "拼图后台保存失败：flushSaves（没有排着的）照样回失败原因", late ?? "nil")

        unlock(session)
        touch()
        let back = collage.flushSaves()
        check(back == nil && LiveHandlers.collagePersistReport(back).persisted,
              "拼图腾出空间后再改一下：flushSaves 回 nil、persisted true（lastError 不清也不影响）", back ?? "")
    }
}
