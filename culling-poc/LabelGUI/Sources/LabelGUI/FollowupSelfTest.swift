import Foundation

/// 跟进小修的自检（2026-11 全项目审查第二波，车道 F）：LABELGUI_DATA_DIR=<临时目录> LabelGUI --followup-selftest
/// 不要照片、不跑分析、不开界面：照 FileSafetySelfTest 在数据目录里造几场假的拍摄（小文件 + 手写的 manifest / layer1），逐条断言、
/// 打 PASS / FAIL：
///   - S01b 判决、客户选中、拼图写盘失败时，实时桥写工具的结果 persisted:false + save_failed，「已存盘」只在真存上时说
///     （场次目录 chmod 只读模拟盘满；后台那次拼图保存失败也算得上，不等 lastError 那一拍）。
///   - F19 水印页「导入选片结果」菜单：精选 / 精选 + 可用 / 客户选中（客户选中的废片也带，RAW+JPG 用 JPG）。
///   - 水印 EXIF 文字的快门：0、负数、非有限、非规格化的极小正数（1/t = inf）不崩、不填；≥1s 照旧 %g。
///   - S15「复制原片到…」连续 3 张写不进目标就停、说清楚原因和怎么办（不支持 → NAS / exFAT），英文 strerror 换成中文。
///   - M01 近似重复去重：拍摄时刻完全一样、一张 RAW 一张 JPG（分卡存、分文件夹放的同一帧）时，RAW 不判「连拍重复」；
///     场里只剩这一对时按一帧算、不提精选，接受全部推荐也不把 RAW 钉成废片。
///   - MCP cull_get_photos 的 exif：老 manifest 里存的 shutter_sec / aperture / focal_35 = 0 不报（和 summary 一样）。
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
        watermarkImport(root.appendingPathComponent("wm"))
        watermarkShutter()
        originalsStop(root.appendingPathComponent("copy"))
        splitTwinDedupe(root.appendingPathComponent("twin"))
        readModelExif(root.appendingPathComponent("exif"))
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

    /// root 跑时 chmod 只读挡不住写：靠只读模拟盘满的那几段跳过（CI 的 runner 不是 root）。
    static var chmodWorks: Bool { geteuid() != 0 }

    static func persistReport(_ dir: URL) {
        print("— S01b 判决 / 客户选中 / 拼图没存上：写工具回 persisted:false + save_failed，「已存盘」只在真存上时说")
        guard chmodWorks else {
            print("SKIP root 跑时 chmod 只读挡不住写，这一段测不了")
            return
        }
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

    // MARK: - F19 水印页按客户选中导入

    static func watermarkImport(_ dir: URL) {
        print("— F19 水印页「导入选片结果」：精选 / 精选 + 可用 / 客户选中")
        typealias Fake = FileSafetySelfTest.Fake
        let store = FileSafetySelfTest.makeShoot(dir, [
            Fake(id: "P1", raw: "P1.JPG", jpeg: true), Fake(id: "U1", raw: "U1.JPG", jpeg: true),
            Fake(id: "R1", raw: "R1.JPG", jpeg: true), Fake(id: "RW", raw: "RW.ARW", decode: "RW.JPG"),
        ])
        store.setOverride("P1", .pick)
        store.setOverride("U1", .usable)
        store.setOverride("R1", .reject)
        store.setOverride("RW", .pick)
        store.importClientPicks(["R1", "RW"])
        func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }
        func inOrder(_ ids: Set<String>) -> [String] {
            store.items.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.decodePath).lastPathComponent }
        }
        let picks = names(WatermarkStore.batchPhotos(store, .picks))
        let keepers = names(WatermarkStore.batchPhotos(store, .picksAndUsable))
        let client = names(WatermarkStore.batchPhotos(store, .clientPicks))
        check(picks == inOrder(["P1", "RW"]), "精选：只带精选，RAW+JPG 带 JPG", "\(picks)")
        check(keepers == inOrder(["P1", "U1", "RW"]), "精选 + 可用：和以前那个按钮一样", "\(keepers)")
        check(client == inOrder(["R1", "RW"]) && client.contains("R1.JPG") && client.contains("RW.JPG"),
              "客户选中：不看判决（客户点名的废片 R1 也带），RAW+JPG 带 JPG", "\(client)")

        let wm = WatermarkStore(dataDir: appDataDir)
        wm.importClientPicks(store)
        check(names(wm.photos) == client, "水印页 importClientPicks：列表里就是客户选中的那几张", "\(names(wm.photos))")
        wm.importFromBatch(store, includeUsable: false)
        let after = Set(names(wm.photos))
        check(after == Set(client + picks) && wm.photos.count == after.count,
              "再导入精选：加上 P1，和已经在列表里的 RW 不重复", "\(names(wm.photos))")
        wm.clearPhotos()
    }

    // MARK: - 水印 EXIF 文字的快门（第一波 G 车道留下的：ExifTags 只判了 t > 0）

    static func watermarkShutter() {
        print("— 水印 EXIF 文字 {shutter}：极小正数不再 Int(+inf) 崩")
        // (说明, 曝光时间秒数, 期望 {shutter} 的值；nil = 不填，模板里的 {shutter} 原样留着)
        let rows: [(String, Double, String?)] = [
            ("最小的非规格化小数 5e-324（1/t 溢出成 inf）", 5e-324, nil),
            ("1e-300（1/t 有限但远超 Int.max）", 1e-300, nil),
            ("1e-19（1/t ≈ 1e19 > Int.max）", 1e-19, nil),
            ("0（EXIF 写 0/1）", 0, nil),
            ("负数", -0.004, nil),
            ("NaN", Double.nan, nil),
            ("+inf（以前印成 inf）", Double.infinity, nil),
            ("1/250 照常", 0.004, "1/250"),
            ("1/8000 照常", 1.0 / 8000, "1/8000"),
            ("0.5s → 1/2", 0.5, "1/2"),
            ("1.5s 保持 1.5（%g）", 1.5, "1.5"),
            ("2s → 2", 2, "2"),
            ("30s → 30", 30, "30"),
        ]
        for (name, t, want) in rows {
            let got = WatermarkEngine.ExifTags.shutterValue(t)
            check(got == want, "水印快门 " + name, "得到 \(got ?? "nil")，期望 \(want ?? "nil")")
        }
        // 模板照旧：没填的 {shutter} 原样留着（exif_text 语义），填了的带上模板里的「s」
        var tags = WatermarkEngine.ExifTags(source: nil)
        tags.values["shutter"] = WatermarkEngine.ExifTags.shutterValue(1.0 / 250)
        let filled = tags.fill(template: "{shutter}s · ISO {iso}")
        check(filled == "1/250s · ISO {iso}", "模板 {shutter}s 填出 1/250s，找不到的 {iso} 原样留着", filled)
    }

    // MARK: - S15 复制原片：连续失败就停、中文提示

    static func originalsStop(_ dir: URL) {
        print("— S15 复制原片到…：连续 3 张写不进目标就停，原因和下一步说清楚")
        typealias Streak = OriginalsCopier.FailureStreak
        func shot(copied: Int = 0, skipped: Int = 0, target: String? = nil, failed: Bool = false) -> OriginalsCopier.ShotResult {
            var r = OriginalsCopier.ShotResult()
            r.copied = copied
            r.skipped = skipped
            r.targetFailure = target
            if failed || target != nil { r.failed = ["x：" + (target ?? "原片读不出来")] }
            return r
        }
        func run(_ results: [OriginalsCopier.ShotResult]) -> (stopAt: Int?, why: String?) {
            var streak = Streak()
            for (i, r) in results.enumerated() {
                streak.record(r)
                if streak.shouldStop { return (i + 1, streak.lastReason) }
            }
            return (nil, nil)
        }
        let full = "目标盘满了"
        // (说明, 每张的结果, 期望第几张停 / nil = 不停)
        let rows: [(String, [OriginalsCopier.ShotResult], Int?)] = [
            ("连续 3 张写不进目标 → 第 3 张停", [shot(target: full), shot(target: full), shot(target: full), shot(copied: 1)], 3),
            ("中间复制成了一张 → 重新数", [shot(target: full), shot(target: full), shot(copied: 2), shot(target: full),
                                     shot(target: full)], nil),
            ("目标里一模一样跳过的不打断、也不算", [shot(target: full), shot(skipped: 2), shot(target: full), shot(skipped: 1),
                                        shot(target: full)], 5),
            ("只是原片读不出来（原片挪走了）不算目标的问题", [shot(failed: true), shot(failed: true), shot(failed: true),
                                             shot(failed: true)], nil),
            ("RAW 复制成了、JPG 没写进去：这张不算失败", [shot(copied: 1, target: full), shot(target: full), shot(target: full)], nil),
        ]
        for (name, results, want) in rows {
            let got = run(results)
            check(got.stopAt == want, "复制原片 连续失败 " + name, "第 \(got.stopAt.map(String.init) ?? "—") 张停")
        }

        // 原因 → 下一步；英文 strerror 换成中文
        let notSupported = CardImporter.describe(CardImporter.errnoError(ENOTSUP))
        let nasHint = OriginalsCopier.stopHint("写不进目标文件夹：" + notSupported)
        check(nasHint.contains("NAS") && nasHint.contains("exFAT"), "不支持（ENOTSUP）→ 提示多半是 NAS 共享 / exFAT 盘、换本机文件夹", nasHint)
        check(OriginalsCopier.stopHint(full).contains("腾出空间"), "盘满 → 腾出空间或换一块盘")
        check(OriginalsCopier.stopHint("写不进目标文件夹：没有权限").contains("换一个文件夹"), "没有权限 → 换一个文件夹")
        let english = String(cString: strerror(ENOTSUP))
        let zh = OriginalsCopier.localized(english)
        check(zh == notSupported, "英文 strerror「\(english)」换成中文", zh)
        check(OriginalsCopier.localized(String(cString: strerror(EACCES))) == "没有权限" && OriginalsCopier.localized("别的原因") == "别的原因",
              "没有权限也换成中文，认不出的原样留着")

        // 端到端：目标文件夹只读（每张都在建 .part 时失败）→ 6 张里试了 3 张就停，状态栏说清楚；改回来再复制全部成功
        guard chmodWorks else {
            print("SKIP root 跑时 chmod 只读挡不住写，复制原片端到端这一段测不了")
            return
        }
        typealias Fake = FileSafetySelfTest.Fake
        let fakes = (1...6).map { Fake(id: "C\($0)", raw: "C\($0).JPG") }
        let store = FileSafetySelfTest.makeShoot(dir.appendingPathComponent("shoot"), fakes)
        let dest = dir.appendingPathComponent("dest")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        lock(dest)
        let ids = store.items.map(\.id)
        store.copyOriginals(ids, to: dest)
        FileSafetySelfTest.wait(store)
        let error = store.lastError ?? ""
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
        let stoppedOK: Bool = error.contains("连续 3 张都没复制成") && error.contains("后面 3 张没再试")
            && store.progressText.hasPrefix("复制原片停下了: 3 张 · 复制了 0 个文件") && listing.isEmpty
        check(stoppedOK, "目标只读：试了 3 张就停，状态栏说「连续 3 张都没复制成…后面 3 张没再试」，目标里什么都没留下",
              "\(error) · \(store.progressText) · \(listing)")
        unlock(dest)
        store.copyOriginals(ids, to: dest)
        FileSafetySelfTest.wait(store)
        let copied = (try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.filter { !$0.hasPrefix(".") } ?? []
        check(store.lastError == nil && copied.count == 6 && store.progressText.hasPrefix("复制原片完成: 6 张"),
              "改回能写以后再复制：6 张全部复制、没有报错", "\(store.lastError ?? "nil") · \(store.progressText) · \(copied.count)")
    }

    // MARK: - M01 去重不把分开放的同一帧 RAW 判成「连拍重复」

    /// 一张假照片：文件（相对拍摄文件夹）、拍摄时间、小数秒、近似重复组、锐度（定谁赢）、机型。
    struct DupFake {
        let id: String
        let file: String
        let time: String
        var subsec: Double?
        let group: Int
        let sharpness: Double
        var camera = "X-T50"
        /// manifest 里的 exif（不给 = 只有 ISO 400）。
        var exif: [String: Any]?
    }

    /// 照 FileSafetySelfTest.writeShoot 手写 manifest / layer1（拍摄时间、小数秒、组号自己给），打开这一场。
    static func makeDupShoot(_ dir: URL, _ photos: [DupFake]) -> BatchStore {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        var layer1: [[String: Any]] = []
        for photo in photos {
            let url = dir.appendingPathComponent(photo.file)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(("PHOTO " + photo.id).utf8).write(to: url)
            manifest.append([
                "id": photo.id, "raw_path": url.path, "decode_path": url.path, "preview_path": "previews/\(photo.id).jpg",
                "capture_time": photo.time, "camera": photo.camera, "body_serial": "", "exif": photo.exif ?? ["iso": 400],
            ])
            var row: [String: Any] = [
                "id": photo.id, "sharpness": photo.sharpness, "burst_group": photo.group, "face_found": false, "face_count": 0,
                "highlight_clip_pct": 0.0, "shadow_clip_pct": 0.0, "frame_luma": 128, "frame_luma_p99": 220,
            ]
            if let sub = photo.subsec { row["capture_subsec"] = sub }
            layer1.append(row)
        }
        let session = appDataDir.appendingPathComponent("sessions/" + BatchStore.sessionKey(for: dir))
        try? fm.createDirectory(at: session, withIntermediateDirectories: true)
        let m: [String: Any] = ["photo_dir": dir.path, "photos": manifest]
        let l: [String: Any] = ["analysis_version": 2, "engine": "native", "results": layer1]
        for (name, json) in [("manifest.json", m), ("layer1_results.json", l)] {
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: session.appendingPathComponent(name))
            }
        }
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        return store
    }

    static func splitTwinDedupe(_ dir: URL) {
        print("— M01 近似重复去重：同一帧拆成一张 RAW 一张 JPG 时，RAW 不判「连拍重复」")
        // 每组隔一分钟（各成一场）。JPG 比 RAW 锐 = JPG 赢下这一组
        let photos: [DupFake] = [
            // 1 分卡存：RAW/、JPG/ 两个文件夹，同一帧（时刻到小数秒、机身都一样）
            DupFake(id: "T1", file: "RAW/DSCF0001.RAF", time: "2026-03-21T10:00:00", subsec: 0.25, group: 1, sharpness: 90),
            DupFake(id: "T1_2", file: "JPG/DSCF0001.JPG", time: "2026-03-21T10:00:00", subsec: 0.25, group: 1, sharpness: 95),
            // 2 对照：两张 JPG 同一时刻（不是 RAW+JPG）→ 照常去重
            DupFake(id: "J1", file: "J1.JPG", time: "2026-03-21T10:01:00", subsec: 0.5, group: 2, sharpness: 90),
            DupFake(id: "J2", file: "J2.JPG", time: "2026-03-21T10:01:00", subsec: 0.5, group: 2, sharpness: 95),
            // 3 对照：RAW + JPG 但小数秒不同（连拍里前后两帧）→ RAW 照常去重
            DupFake(id: "S1", file: "S1.RAF", time: "2026-03-21T10:02:00", subsec: 0.1, group: 3, sharpness: 90),
            DupFake(id: "S2", file: "S2.JPG", time: "2026-03-21T10:02:00", subsec: 0.3, group: 3, sharpness: 95),
            // 4 对照：同一时刻但不是同一台机身（双机位）→ RAW 照常去重
            DupFake(id: "B1", file: "B1.RAF", time: "2026-03-21T10:03:00", subsec: 0.5, group: 4, sharpness: 90, camera: "X-T50"),
            DupFake(id: "B2", file: "B2.JPG", time: "2026-03-21T10:03:00", subsec: 0.5, group: 4, sharpness: 95, camera: "X-H2"),
            // 5 RAW 更锐、赢下这一组：JPG 那张照常判连拍重复（只护 RAW）
            DupFake(id: "W1", file: "RAW/DSCF0005.RAF", time: "2026-03-21T10:04:00", subsec: nil, group: 5, sharpness: 99),
            DupFake(id: "W1_2", file: "JPG/DSCF0005.JPG", time: "2026-03-21T10:04:00", subsec: nil, group: 5, sharpness: 90),
            // 6 一组三张：同一帧的 RAW + JPG、再加一张更好的 → JPG 判连拍重复，RAW 照样护着
            DupFake(id: "G1", file: "RAW/DSCF0007.RAF", time: "2026-03-21T10:05:00", subsec: 0.2, group: 6, sharpness: 80),
            DupFake(id: "G1_2", file: "JPG/DSCF0007.JPG", time: "2026-03-21T10:05:00", subsec: 0.2, group: 6, sharpness: 85),
            DupFake(id: "G2", file: "JPG/DSCF0008.JPG", time: "2026-03-21T10:05:01", subsec: 0.1, group: 6, sharpness: 99),
        ]
        let store = makeDupShoot(dir, photos)
        check(store.items.count == photos.count, "造的一场有 \(photos.count) 张", "\(store.items.count)")
        store.rejectBurstDuplicates = true
        func dup(_ id: String) -> Bool { store.item(withID: id)?.rejectReasons.contains("连拍重复") == true }
        func verdict(_ id: String) -> Verdict? { store.item(withID: id)?.verdict }
        // (说明, id, 期望是不是「连拍重复」)
        let rows: [(String, String, Bool)] = [
            ("分卡存的同一帧：RAW 输给自己那张 JPG 也不判连拍重复", "T1", false),
            ("分卡存的同一帧：赢的 JPG 照旧", "T1_2", false),
            ("对照 两张 JPG 同一时刻：输的那张照常去重", "J1", true),
            ("对照 RAW + JPG 小数秒不同（前后两帧）：RAW 照常去重", "S1", true),
            ("对照 同一时刻、不同机身（双机位）：RAW 照常去重", "B1", true),
            ("RAW 赢下这一组：那张 JPG 照常去重（只护 RAW）", "W1_2", true),
            ("RAW 赢下这一组：RAW 本身不动", "W1", false),
            ("一组三张、更好的是另一帧：同一帧的 JPG 判连拍重复", "G1_2", true),
            ("一组三张、更好的是另一帧：同一帧的 RAW 照样护着", "G1", false),
        ]
        for (name, id, want) in rows {
            check(dup(id) == want, "去重 " + name, "\(id)：理由 \(store.item(withID: id)?.rejectReasons ?? []) · \(verdict(id).map(\.rawValue) ?? "—")")
        }
        check(verdict("T1") != .reject && verdict("G1") != .reject, "护着的 RAW 不是废片（移到废纸篓不会动它）",
              "T1 \(verdict("T1").map(\.rawValue) ?? "—") · G1 \(verdict("G1").map(\.rawValue) ?? "—")")
        // 精选按帧数对手：单帧的场里只剩同一帧的 RAW + JPG，两张都不提成精选（以前 JPG 会被提成一张没有对手的精选）
        check(verdict("T1") == .usable && verdict("T1_2") == .usable,
              "单帧的场只剩分卡存的同一帧：RAW、JPG 都是可用，没有提出一张没对手的精选",
              "T1 \(verdict("T1").map(\.rawValue) ?? "—") · T1_2 \(verdict("T1_2").map(\.rawValue) ?? "—")")
        check(verdict("G2") == .pick, "对照 同一帧的 RAW 旁边还有另一帧：照常在场里提精选（赢的是另一帧）",
              "G2 \(verdict("G2").map(\.rawValue) ?? "—")")
        // 接受全部推荐：没有精选的那一场不动，护着的 RAW 不会被钉成废片
        store.acceptAllRecommendations()
        check(verdict("T1") != .reject && verdict("T1_2") != .reject, "接受全部推荐以后：单帧场的 RAW、JPG 都不是废片",
              "T1 \(verdict("T1").map(\.rawValue) ?? "—") · T1_2 \(verdict("T1_2").map(\.rawValue) ?? "—")")
        store.undoLastOverride()
        store.rejectBurstDuplicates = false
        check(verdict("T1") == .usable && verdict("T1_2") == .usable,
              "关掉去重也一样：单帧场里的同一帧 RAW + JPG 都是可用，不提精选",
              "T1 \(verdict("T1").map(\.rawValue) ?? "—") · T1_2 \(verdict("T1_2").map(\.rawValue) ?? "—")")
        check(!dup("J1") && !dup("S1"), "关掉去重：连拍重复整组回来")
    }

    // MARK: - MCP 读模型的 exif：老 manifest 里的 0 不报

    static func readModelExif(_ dir: URL) {
        print("— MCP cull_get_photos 的 exif：老 manifest 里存的快门 / 光圈 / 等效焦距 0 不报")
        let zero: [String: Any] = ["shutter_sec": 0, "aperture": 0, "focal_35": 0, "iso": 400]
        let real: [String: Any] = ["shutter_sec": 0.004, "aperture": 2.8, "focal_35": 85, "iso": 800]
        let store = makeDupShoot(dir, [
            DupFake(id: "Z0", file: "Z0.JPG", time: "2026-03-21T11:00:00", group: 1, sharpness: 90, exif: zero),
            DupFake(id: "Z1", file: "Z1.JPG", time: "2026-03-21T11:05:00", group: 2, sharpness: 90, exif: real),
        ])
        func exif(_ id: String) -> [String: Any] {
            guard let item = store.item(withID: id) else { return [:] }
            return MCPReadModel.detail(item, store, groupSizes: [:])["exif"] as? [String: Any] ?? [:]
        }
        let z = exif("Z0")
        let zeroOK: Bool = z["shutter_sec"] == nil && z["aperture"] == nil && z["focal_35"] == nil
            && z["iso"] as? Int == 400 && z["summary"] as? String == "ISO 400"
        check(zeroOK, "老 manifest 里 shutter_sec / aperture / focal_35 是 0：不报这几项，iso、summary 照旧", "\(z)")
        let r = exif("Z1")
        let realOK: Bool = r["shutter_sec"] as? Double == 0.004 && r["aperture"] as? Double == 2.8 && r["focal_35"] as? Int == 85
        check(realOK, "正常的快门 1/250、f/2.8、85mm 照报", "\(r)")
        let encodable = JSONSerialization.isValidJSONObject(z) && JSONSerialization.isValidJSONObject(r)
        check(encodable, "两张的 exif 都能编成 JSON")
    }
}
