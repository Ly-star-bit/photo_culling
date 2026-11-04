import AppKit
import Foundation

/// 场次持久化自检（全项目审查 S01 / S02 / S06）：
///     LABELGUI_DATA_DIR=<空的临时目录> LabelGUI --persist-selftest <Fixtures/photot-session>
/// 在数据目录里照 fixture（manifest.json + layer1_results.json）造几场，再塞假的预览图、拼图蒙版；逐条造坏文件、
/// 设只读目录，核对原件保住了、提示有了、切场次拦住了。会改写数据目录：只在临时目录里跑。每条打一行 PASS / FAIL，
/// 有 FAIL 退出码 1。不碰 UserDefaults（minKeepersPerChapter 这类设置写的是全局的，数据目录隔离不了）。
enum PersistSelfTest {
    static let flag = "--persist-selftest"  // 和 ClientPicksCLI.flags 里的字面量一致

    @MainActor
    static func run(flagIndex: Int) -> Never {
        CollageCLI.requireIsolatedDataDir(flag)
        AppUISnapshot.requireNotRealDataDir(flag)
        let args = CommandLine.arguments
        guard args.count > flagIndex + 1 else {
            print("用法: \(flag) <fixture 目录（manifest.json + layer1_results.json，比如 Fixtures/photot-session）>")
            exit(2)
        }
        let fixture = URL(fileURLWithPath: args[flagIndex + 1])
        let manifest = fixture.appendingPathComponent("manifest.json").path
        guard FileManager.default.fileExists(atPath: manifest) else {
            print("fixture 目录里没有 manifest.json：\(fixture.path)")
            exit(2)
        }
        let t = PersistSelfTestHarness(dataDir: appDataDir, fixture: fixture)
        t.removeSessionKeepsVerdicts()
        t.corruptFilesKept()
        t.unreadableFileRefused()
        t.corruptCollageKept()
        t.sessionsIndexTolerant()
        t.writeFailureVisible()
        t.dedupePerSession()
        print("persist-selftest: \(t.passed) 通过 \(t.failed) 失败")
        exit(t.failed == 0 ? 0 : 1)
    }
}

@MainActor
final class PersistSelfTestHarness {
    let dataDir: URL
    let fixture: URL
    private(set) var passed = 0
    private(set) var failed = 0
    let fm = FileManager.default

    init(dataDir: URL, fixture: URL) {
        self.dataDir = dataDir
        self.fixture = fixture
    }

    func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if ok { passed += 1 } else { failed += 1 }
    }

    struct Session {
        let folder: URL
        let dir: URL
        var key: String { dir.lastPathComponent }
    }

    /// 一场：照片文件夹 <数据目录>/photos/<name>（建出来、空的：--verdicts 一样只读场次 JSON），场次目录照 fixture
    /// 灌好，预览图、拼图蒙版各放一个 4 KB 的假文件。
    func makeSession(_ name: String) -> Session {
        let folder = dataDir.appendingPathComponent("photos/\(name)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = dataDir.appendingPathComponent("sessions/\(BatchStore.sessionKey(for: folder))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in ["manifest.json", "layer1_results.json"] {
            let target = dir.appendingPathComponent(file)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: fixture.appendingPathComponent(file), to: target)
        }
        let session = Session(folder: folder, dir: dir)
        fillCache(session)
        return session
    }

    /// 假的预览图、拼图蒙版（各 4 KB）。打开另一场时不在「最近场次」里的会被清掉（pruneOrphanedSessions），
    /// 所以要核对缓存的用例在打开完以后再灌一次。
    func fillCache(_ session: Session) {
        for sub in BatchStore.sessionCacheDirs {
            let d = session.dir.appendingPathComponent(sub, isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            // 不用全零：APFS 把全零的写成稀疏文件，占用算出来是 0，体积那条就测不出东西。
            try? Data(repeating: 0x5A, count: 4096).write(to: d.appendingPathComponent("fake.bin"))
        }
    }

    /// 新开一个 store 之前把「最近场次」清掉：init 会自动打开第一场，各条用例互不串。
    func freshIndex() {
        try? fm.removeItem(at: dataDir.appendingPathComponent("sessions.json"))
    }

    func newStore() -> BatchStore {
        BatchStore(dataDir: dataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: dataDir))
    }

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - S06 移除历史记录只清预览

    func removeSessionKeepsVerdicts() {
        print("— S06 移除历史记录：只清预览图和拼图蒙版，判决、客户选中、拼图留着")
        freshIndex()
        let a = makeSession("s06-a"), b = makeSession("s06-b")
        let store = newStore()
        store.switchSession(to: b.folder)
        store.switchSession(to: a.folder)
        guard let id = store.items.first?.id else {
            check(false, "fixture 读进来了（\(fixture.path)）")
            return
        }
        store.setOverride(id, .reject)
        store.setClientPicks([id])
        let collage = a.dir.appendingPathComponent("collage.json")
        try? Data("{\"pages\":[]}".utf8).write(to: collage)

        // 打开 a 的时候 b 还不在「最近场次」里，b 的预览被清过：两场都重新灌一次，再量一遍
        fillCache(a)
        fillCache(b)
        store.refreshSessionAvailability(force: true)
        spin(10) { (store.sessionSizes[a.key] ?? 0) > 0 && (store.sessionSizes[b.key] ?? 0) > 0 }
        let cacheBytes = BatchStore.sessionCacheDirs.reduce(Int64(0)) {
            $0 + BatchStore.directorySize(a.dir.appendingPathComponent($1))
        }
        let whole = BatchStore.directorySize(a.dir)
        check(store.sessionSizes[a.key] == cacheBytes && cacheBytes > 0 && cacheBytes < whole,
              "菜单报的体积只算预览图 + 蒙版（\(store.sessionSizes[a.key] ?? -1) = \(cacheBytes)，整个目录 \(whole)）")

        guard let entryA = store.recentSessions.first(where: { $0.key == a.key }),
              let entryB = store.recentSessions.first(where: { $0.key == b.key }) else {
            check(false, "两场都在「最近场次」里")
            return
        }
        // 先移除不是当前打开的那一场
        store.removeSession(entryB)
        check(!exists(b.dir.appendingPathComponent("previews")) && exists(b.dir.appendingPathComponent("manifest.json"))
              && store.photoDir != nil && store.sessionDir.lastPathComponent == a.key,
              "移除另一场：它的预览清掉、分析结果留着，当前这一场不动")
        // 再移除当前这一场
        store.removeSession(entryA)
        let cacheGone = BatchStore.sessionCacheDirs.allSatisfy { !exists(a.dir.appendingPathComponent($0)) }
        check(cacheGone, "移除当前这一场：previews/、collage_masks/ 删掉")
        let kept = ["overrides.json", "client_picks.json", "collage.json", "manifest.json", "layer1_results.json"]
        let missing = kept.filter { !exists(a.dir.appendingPathComponent($0)) }
        check(missing.isEmpty, "判决、客户选中、拼图工程、分析结果都留着" + (missing.isEmpty ? "" : "（没了：\(missing)）"))
        check(store.photoDir == nil && !store.recentSessions.contains { $0.key == a.key },
              "从「最近场次」里拿掉、界面回到没开场次")
        check(store.progressText.contains("判决") && store.progressText.contains("拼图"),
              "提示写清删了什么、留了什么：\(store.progressText)")

        store.switchSession(to: a.folder)
        check(store.overrides[id] == .reject && store.clientPicks.contains(id),
              "重新打开这个文件夹：改判、客户选中原样回来")
        check(store.lastError?.contains("移除") == true, "提示预览清掉了、怎么补（也涵盖「移除过」）：\(store.lastError ?? "nil")")
    }

    // MARK: - S02a 判决、客户选中、对时、确认表、阈值读坏了

    func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// 场次目录里 `<stem>.corrupt-*` 的那几份（挪开的原件）。
    func corruptCopies(of name: String, in dir: URL) -> [URL] {
        let stem = (name as NSString).deletingPathExtension + ".corrupt-"
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(stem) }.sorted().map { dir.appendingPathComponent($0) }
    }

    func corruptFilesKept() {
        print("— S02a 判决、客户选中、对时、确认表、阈值读坏了：挪开保住原件、提示，下一次保存不盖掉")
        freshIndex()
        let s = makeSession("s02a"), other = makeSession("s02a-other")
        let garbage: [(String, Data)] = [
            ("overrides.json", Data("{\"DSCF7207\": \"精选\", \"DSCF72".utf8)),  // 截断
            ("accepted.json", Data("[\"DSCF7207\"]".utf8)),                       // 好的：跟着 overrides.json 一起挪
            ("client_picks.json", Data()),                                         // 零长度
            ("body_offsets.json", Data("[1, 2, 3]".utf8)),                         // 类型不对
            ("thresholds.json", Data("{\"sharpness\": \"高\"}".utf8)),
            ("proof_sheets.json", Data("not json".utf8)),
        ]
        for (name, data) in garbage { try? data.write(to: s.dir.appendingPathComponent(name)) }
        let store = newStore()
        store.switchSession(to: s.folder)
        guard let id = store.items.first?.id else {
            check(false, "fixture 读进来了")
            return
        }
        for (name, data) in garbage where name != "proof_sheets.json" {
            let aside = corruptCopies(of: name, in: s.dir)
            check(aside.count == 1 && read(aside[0]) == data,
                  "\(name) 原件挪成 \(aside.first?.lastPathComponent ?? "—")，内容一字不差")
        }
        let pair = corruptCopies(of: "overrides.json", in: s.dir).first?.lastPathComponent.dropFirst("overrides".count)
        let acceptedPair = corruptCopies(of: "accepted.json", in: s.dir).first?.lastPathComponent.dropFirst("accepted".count)
        check(pair != nil && pair == acceptedPair, "overrides.json 和 accepted.json 挪开用同一个时间（好配对）")
        check(store.overrides.isEmpty && store.clientPicks.isEmpty && store.bodyOffsets.isEmpty, "这几样从空的开始")
        let notice = store.dataNotice ?? ""
        let named = ["overrides.json", "client_picks.json", "body_offsets.json", "thresholds.json"].allSatisfy(notice.contains)
        check(named && notice.contains("XMP"), "提示里点名了这几个文件、说了先别写 XMP")
        let rewritten = read(s.dir.appendingPathComponent("thresholds.json"))
            .flatMap { try? JSONDecoder().decode(BatchStore.ThresholdState.self, from: $0) }
        check(rewritten?.faceQuality == BatchStore.legacyThresholds.faceQuality && store.faceQualityThreshold == 0,
              "thresholds.json 按原来的回落顺序重定了一份（有分析结果、没有「上次用的」→ 升级前的默认）")

        store.setOverride(id, .reject)
        store.setClientPicks([id])
        let saved = read(s.dir.appendingPathComponent("overrides.json"))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        let wantSaved: [String: String] = [id: Verdict.reject.rawValue]
        check(saved == wantSaved, "改判以后 overrides.json 只写了这一条")
        check(read(corruptCopies(of: "overrides.json", in: s.dir)[0]) == garbage[0].1, "挪开的原件没被这次保存碰到")

        store.recordProofSheet(ProofSheet(id: "selftest-1", date: Date(), scope: "仅精选", ids: [id]))
        let sheetAside = corruptCopies(of: "proof_sheets.json", in: s.dir)
        let sheetIDs: [String] = store.proofSheets.map(\.id)
        let sheetKept: Bool = sheetAside.count == 1 && read(sheetAside[0]) == garbage[5].1
        check(sheetKept && sheetIDs == ["selftest-1"],
              "确认表记录：解不开的挪开，新记录只有这一张")

        // .bak：重新打开以后第一次改写前留一份打开时的样子，一次打开只备份一次
        let atOpen = read(s.dir.appendingPathComponent("overrides.json"))
        store.switchSession(to: other.folder)
        store.switchSession(to: s.folder)
        store.setOverride(id, .pick)
        let bak = s.dir.appendingPathComponent("overrides.json.bak")
        check(atOpen != nil && read(bak) == atOpen, "重新打开后第一次改判前留了 overrides.json.bak（打开时那一版）")
        store.setOverride(id, .usable)
        check(read(bak) == atOpen, ".bak 一次打开只备份一次（第二次改判不覆盖它）")
        check(store.overrides[id] == .usable && store.dataNotice != nil, "改判照常；提醒留着等用户点掉")
    }

    func unreadableFileRefused() {
        print("— S02a 读不出来的（权限）：不挪、不覆盖，这一场先不存")
        freshIndex()
        let s = makeSession("s02a-locked")
        let url = s.dir.appendingPathComponent("overrides.json")
        let original = Data("{\"DSCF7207\":\"废片\"}".utf8)
        try? original.write(to: url)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let store = newStore()
        store.switchSession(to: s.folder)
        guard let id = store.items.first?.id else {
            check(false, "fixture 读进来了")
            return
        }
        check(store.dataNotice?.contains("读不出来") == true && corruptCopies(of: "overrides.json", in: s.dir).isEmpty,
              "提示读不出来、没挪：\(store.dataNotice ?? "nil")")
        store.setOverride(id, .pick)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        check(read(url) == original, "改判没把读不出来的原件盖掉")
        store.switchSession(to: makeSession("s02a-locked-other").folder)
        store.switchSession(to: s.folder)
        check(store.overrides["DSCF7207"] == .reject, "权限恢复后重新打开：原来的改判读回来了")
    }

    // MARK: - S02b 拼图工程读坏了

    /// 拼图上随便改一下（= 用户的第一次编辑）再立刻落盘。
    func touchCollage(_ store: CollageStore) {
        var style = store.project.style
        style.gutter += 0.002
        store.setStyle(style, coalesce: false)
        store.flushSaves()
    }

    func corruptCollageKept() {
        print("— S02b 拼图工程解不开：挪开保住原件、提示，第一次编辑不盖掉；每次打开后第一次保存前留 .bak")
        let s = makeSession("s02b")
        let url = s.dir.appendingPathComponent("collage.json")
        let bak = url.appendingPathExtension("bak")
        let garbage = Data("{\"pages\": [{\"id\": ".utf8)
        try? garbage.write(to: url)
        let store = CollageStore(dataDir: dataDir)
        store.attach(sessionDir: s.dir, photoDir: s.folder, batch: nil)
        let aside = corruptCopies(of: "collage.json", in: s.dir)
        check(aside.count == 1 && read(aside[0]) == garbage && !exists(url),
              "collage.json 原件挪成 \(aside.first?.lastPathComponent ?? "—")，内容一字不差")
        check(store.lastError?.contains("解不开") == true, "拼图页提示：\(store.lastError ?? "nil")")
        touchCollage(store)
        let saved = read(url).flatMap { try? JSONDecoder().decode(CollageProject.self, from: $0) }
        check(saved != nil && aside.first.flatMap(read) == garbage, "第一次编辑写出新的 collage.json，挪开的原件没被碰到")
        check(!exists(bak), "打开时没有原件就不留 .bak")

        // 下次打开（另一个 store = 重启 app）：第一次保存前把打开时的那一版复制成 collage.json.bak，只复制一次
        let atOpen = read(url)
        let again = CollageStore(dataDir: dataDir)
        again.attach(sessionDir: s.dir, photoDir: s.folder, batch: nil)
        check(again.lastError == nil, "好的工程照常打开、不提示")
        touchCollage(again)
        check(atOpen != nil && read(bak) == atOpen, "打开后第一次保存前留了 collage.json.bak（打开时那一版）")
        touchCollage(again)
        check(read(bak) == atOpen, ".bak 一次打开只备份一次")

        // 没开文件夹时用的 scratch.json 走同一段
        let scratch = dataDir.appendingPathComponent("collage/scratch.json")
        try? Data().write(to: scratch)
        let third = CollageStore(dataDir: dataDir)
        third.attach(sessionDir: nil, photoDir: nil, batch: nil)
        let scratchAside = corruptCopies(of: "scratch.json", in: scratch.deletingLastPathComponent())
        check(scratchAside.count == 1 && third.lastError?.contains("scratch.json") == true,
              "没开文件夹时的 scratch.json（零长度）同样挪开、提示")
    }

    // MARK: - S02c sessions.json 读坏了

    func diskIndex() -> SessionsIndexFile? {
        read(dataDir.appendingPathComponent("sessions.json")).flatMap(SessionsIndexFile.decode)
    }

    func sessionsIndexTolerant() {
        print("— S02c sessions.json：一条坏了只少那一条、原样留着、不清它的预览；整份坏了挪开、这次启动不清预览")
        freshIndex()
        let a = makeSession("s02c-a"), b = makeSession("s02c-b"), c = makeSession("s02c-c")
        let indexURL = dataDir.appendingPathComponent("sessions.json")
        func entry(_ s: Session, named: Bool) -> [String: Any] {
            var e: [String: Any] = ["key": s.key, "path": s.folder.path, "lastAnalyzed": "2026-11-01T10:00:00Z", "photoCount": 21]
            if named { e["name"] = s.folder.lastPathComponent }
            return e
        }
        let list = [entry(a, named: true), entry(b, named: false), entry(c, named: true)]
        try? JSONSerialization.data(withJSONObject: list).write(to: indexURL)

        let store = newStore()  // init 打开第一场 a：登记、清掉不在菜单里的场次的预览
        check(store.recentSessions.map(\.key) == [a.key, c.key], "解得开的两条进菜单，缺 name 的那条不进")
        check(store.dataNotice?.contains("1 条读不懂") == true, "提示有一条读不懂：\(store.dataNotice ?? "nil")")
        check(exists(b.dir.appendingPathComponent("previews")), "读不懂的那一条，它的场次预览没被清")
        let kept = diskIndex()
        check(kept?.unknown.count == 1 && kept?.unknown.first?.key == b.key && kept?.entries.count == 2,
              "写回去的 sessions.json 里那一条原样留着")

        // GUI 开着时命令行 --analyze 登记了一场：GUI 下一次写索引时合进来，不盖掉、不清它的预览
        let d = makeSession("s02c-d")
        BatchStore.registerSession(dataDir: dataDir, folder: d.folder, photoCount: 21)
        check(diskIndex()?.unknown.first?.key == b.key, "命令行登记也留着读不懂的那一条")
        store.switchSession(to: c.folder)
        check(store.recentSessions.contains { $0.key == d.key } && exists(d.dir.appendingPathComponent("previews")),
              "命令行登记的那一场合进菜单、预览没被清")
        // 从文件夹重新打开读不懂的那一场：新的一条取代它
        store.switchSession(to: b.folder)
        let after = diskIndex()
        check(after?.unknown.isEmpty == true && after?.entries.contains { $0.key == b.key } == true,
              "重新打开那个文件夹：新的一条取代读不懂的那条")
        // 移除不会被合并回来（合并只在登记时做，不在写索引时做）
        if let entryD = store.recentSessions.first(where: { $0.key == d.key }) {
            store.removeSession(entryD)
            store.switchSession(to: a.folder)
            check(!store.recentSessions.contains { $0.key == d.key } && diskIndex()?.entries.contains { $0.key == d.key } == false,
                  "移除的那一场不会从盘上合并回来")
        }

        // 整份坏了
        let garbage = Data("[{\"key\": \"".utf8)
        try? garbage.write(to: indexURL)
        fillCache(c)
        let second = newStore()
        let aside = corruptCopies(of: "sessions.json", in: dataDir)
        check(second.recentSessions.isEmpty && aside.count == 1 && aside.first.flatMap(read) == garbage,
              "整份解不开：原件挪成 \(aside.first?.lastPathComponent ?? "—")，菜单是空的")
        check(second.dataNotice?.contains("sessions.json") == true, "提示索引坏了、判决都还在")
        second.switchSession(to: a.folder)
        check(exists(c.dir.appendingPathComponent("previews")), "这次启动不清别的场次的预览")
        check(second.recentSessions.map(\.key) == [a.key], "新的索引从这一场开始")
    }

    // MARK: - S01a 写盘失败：常驻红条、重试、切场次前拦住

    /// 场次目录设成只读（写不进新文件、改不了名）= 盘满时 .atomic 写失败的样子（错误码不同：这里是「没有权限」）。
    func setWritable(_ dir: URL, _ on: Bool) {
        try? fm.setAttributes([.posixPermissions: on ? 0o755 : 0o555], ofItemAtPath: dir.path)
    }

    func savedVerdicts(_ s: Session) -> [String: String]? {
        read(s.dir.appendingPathComponent("overrides.json")).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    func writeFailureVisible() {
        print("— S01a 判决、客户选中、对时写不上：常驻红条、重试、下一次改判 / 切场次前 / 退出时再写，切场次先拦住")
        freshIndex()
        let s = makeSession("s01a"), other = makeSession("s01a-other")
        let store = newStore()
        store.switchSession(to: s.folder)
        let ids = store.items.map(\.id)
        guard ids.count >= 2 else {
            check(false, "fixture 读进来了")
            return
        }
        let id = ids[0], id2 = ids[1]
        defer { setWritable(s.dir, true) }
        store.setOverride(id, .pick)
        check(store.persistError == nil, "写得上的时候没有红条")

        setWritable(s.dir, false)
        store.setOverride(id2, .reject)
        let error = store.persistError ?? ""
        check(error.contains("判决") && error.contains("没有权限") && error.contains("重试"),
              "改判写不上：红条说哪样没存上、为什么、怎么办：\(error)")
        check(store.lastError == nil, "不借 lastError（切场次、分析会清它）")
        let switched = store.switchSession(to: other.folder)
        check(!switched && store.sessionDir.lastPathComponent == s.key && store.overrides[id2] == .reject,
              "切场次被拦下：还在这一场，内存里的改判还在")
        check(store.lastError?.contains("重试") == true, "状态栏说清为什么没切：\(store.lastError ?? "nil")")
        check(!store.retryPersist() && store.persistError != nil, "盘还没腾出来：重试照样失败，红条留着")
        store.setClientPicks([id2])
        check(store.persistError?.contains("客户选中") == true, "客户选中也写不上：同一条红条一起说")

        setWritable(s.dir, true)
        store.setOverride(id, .usable)
        let picks = read(s.dir.appendingPathComponent("client_picks.json")).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        // 期望值拆成有类型的 let：CI 上的 Xcode 16 对一长串 && 里的字面量类型检查很慢。
        let wantVerdicts: [String: String] = [id: Verdict.usable.rawValue, id2: Verdict.reject.rawValue]
        let wantPicks: [String] = [id2]
        let flushed: Bool = store.persistError == nil && savedVerdicts(s) == wantVerdicts && picks == wantPicks
        check(flushed, "腾出空间后的下一次改判：之前没存上的判决、客户选中一起写回去，红条消失")

        if let body = store.bodies.first?.key {
            setWritable(s.dir, false)
            store.setBodyOffsets([body: 90])
            check(store.persistError?.contains("机身对时") == true, "机身对时写不上也上红条")
            setWritable(s.dir, true)
            let url = s.dir.appendingPathComponent("body_offsets.json")
            func offsets() -> [String: Int]? { read(url).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } }
            let before = offsets()
            let retried = store.retryPersist()
            let want: [String: Int] = [body: 90]
            let ok: Bool = before == nil && retried && store.persistError == nil && offsets() == want
            check(ok, "点「重试」写回去、红条消失")
        } else {
            check(false, "fixture 里有机身（对时那一条要用）")
        }

        setWritable(s.dir, false)
        store.setOverride(id, .reject)
        setWritable(s.dir, true)
        check(store.switchSession(to: other.folder) && store.persistError == nil, "切场次前先自动重试：写上了就照常切")
        store.switchSession(to: s.folder)
        check(store.overrides[id] == .reject, "切回来判决是最后改的那一次")

        setWritable(s.dir, false)
        store.setOverride(id, .pick)
        if let entry = store.recentSessions.first(where: { $0.key == s.key }) {
            store.removeSession(entry)
            // 比 sessionDir 不比 photoDir：第二次打开走 bookmark，解析出来的是 /private/var/… 那条路径
            check(store.photoDir != nil && store.sessionDir.lastPathComponent == s.key && store.overrides[id] == .pick
                  && store.recentSessions.contains { $0.key == s.key },
                  "移除当前这一场也先拦住（会清掉界面）")
        }
        setWritable(s.dir, true)
        store.retryPersist()

        setWritable(s.dir, false)
        store.setOverride(id, .usable)
        setWritable(s.dir, true)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        spin(5) { store.persistError == nil }
        check(store.persistError == nil && savedVerdicts(s)?[id] == Verdict.usable.rawValue, "退出（willTerminate）时再写一次")
    }
}
