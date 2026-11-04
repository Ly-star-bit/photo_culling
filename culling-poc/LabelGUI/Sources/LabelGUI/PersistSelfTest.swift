import Foundation

/// 场次持久化自检（全项目审查 S01 / S02 / S06）：
///     LABELGUI_DATA_DIR=<空的临时目录> LabelGUI --persist-selftest <Fixtures/photot-session>
/// 在数据目录里照 fixture（manifest.json + layer1_results.json）造几场，再塞假的预览图、拼图蒙版；逐条造坏文件、
/// 设只读目录，核对原件保住了、提示有了、切场次拦住了。会改写数据目录：只在临时目录里跑。每条打一行 PASS / FAIL，
/// 有 FAIL 退出码 1。不碰 UserDefaults（minKeepersPerChapter 这类设置写的是全局的，数据目录隔离不了）。
enum PersistSelfTest {
    static let flag = "--persist-selftest"

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
              && store.photoDir?.path == a.folder.path,
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
}
