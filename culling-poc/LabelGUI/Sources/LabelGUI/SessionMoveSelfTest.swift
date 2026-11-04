import Foundation

/// 挪了的文件夹认得回来（2026-11 全项目审查 S04 第一步）：LABELGUI_DATA_DIR=<临时目录> LabelGUI --session-move-selftest
/// 在数据目录里造几场假的拍摄（FileSafetySelfTest.writeShoot：小 JPEG + 手写的 manifest / layer1，不跑分析），真的改名、
/// 拷贝、删掉文件夹，逐条断言、打 PASS / FAIL：
///   - 同卷改名以后从「选择文件夹…」/ 拖进来打开新路径：沿用旧场次的 key（不开空场次），判决、客户选中都在；manifest 和
///     网格里的照片路径改到新位置；写 XMP 写在新位置；拼图托盘、方案、撤销栈里的照片路径跟上，存盘的 collage.json 也是。
///   - 拷贝出来的副本（原来的还在）不认，照常是新的一场。
///   - 从菜单点 / 重开 app：书签跟到新位置，照片路径改过去。
///   - 「重新定位文件夹…」：跨卷拷过去、原来的删了（书签解析不到）—— 指给它新位置以后 key 不变、路径改过去；
///     选错文件夹（一张这一场的照片都没有）不换书签。
///   - 实时桥（followBookmark: false）不跟书签、不认回、不改路径。
/// 只写数据目录；退出前删掉造出来的照片文件夹。
@MainActor
enum SessionMoveSelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            passes += 1
            print("PASS " + what)
        } else {
            failures += 1
            let extra = detail()
            print("FAIL " + what + (extra.isEmpty ? "" : "（" + extra + "）"))
        }
    }

    static func run() -> Never {
        CollageCLI.requireIsolatedDataDir("--session-move-selftest", "会在数据目录里造假的拍摄、改名、拷贝文件夹")
        var root = appDataDir.appendingPathComponent("session-move-selftest-" + String(UUID().uuidString.prefix(8)))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 数据目录在 /private/tmp、/private/var 下时（LABELGUI_DATA_DIR=/private/tmp/…）：standardizedFileURL 在文件夹还在时
        // 去掉 /private、不在了就不去，BatchStore.sessionKey 跟着变 —— 改名前后按原路径算的 key 对不上。真实的拍摄文件夹不在
        // 这底下；这里换成不带 /private 的写法（同一个文件夹），算出来的 key 不随文件夹在不在变。
        if root.path.hasPrefix("/private/") {
            let alias = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)), isDirectory: true)
            if SessionLocation.identity(alias.path) == SessionLocation.identity(root.path) { root = alias }
        }
        pureRebase(root.appendingPathComponent("pure"))
        let model = AppModel.make(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir),
                                  bridge: .none)
        renamedThenPicked(root.appendingPathComponent("pick"), model: model)
        copyIsNotAdopted(root.appendingPathComponent("copy"), batch: model.batch)
        reopenFromMenu(root.appendingPathComponent("menu"), batch: model.batch)
        relocate(root.appendingPathComponent("relocate"), batch: model.batch)
        liveBridgeDoesNotFollow(root.appendingPathComponent("live"), batch: model.batch)
        try? FileManager.default.removeItem(at: root)
        print("session-move-selftest: \(passes) 通过 \(failures) 失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 小工具

    typealias Fake = FileSafetySelfTest.Fake

    private static func shoot(_ dir: URL) -> [Fake] {
        [Fake(id: "DSCF0001", raw: "DSCF0001.JPG", jpeg: true),
         Fake(id: "DSCF0002", raw: "DSCF0002.JPG", jpeg: true),
         Fake(id: "IMG_0003", raw: "第二机位/IMG_0003.JPG", jpeg: true)]
    }

    private static func manifestPhotoDir(_ key: String) -> String? {
        let url = appDataDir.appendingPathComponent("sessions/\(key)/manifest.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["photo_dir"] as? String
    }

    private static func key(_ dir: URL) -> String { BatchStore.sessionKey(for: dir) }

    /// 在 `dir` 下面（书签解析出来的是真实路径 /private/tmp/…，照写法和真实路径两种都认）。
    private static func under(_ path: String, _ dir: URL) -> Bool {
        if path.hasPrefix(dir.path + "/") { return true }
        // resolvingSymlinksInPath 会把 /private 又去掉，用 realpath。
        guard let real = realpath(dir.path, nil) else { return false }
        defer { free(real) }
        return path.hasPrefix(String(cString: real) + "/")
    }

    /// 这一场 manifest 的 photo_dir 就是 `dir`（按设备号 + inode 比）。
    private static func manifestAt(_ key: String, _ dir: URL) -> Bool {
        sameDir(manifestPhotoDir(key).map { URL(fileURLWithPath: $0) }, dir)
    }

    private static func pathsUnder(_ batch: BatchStore, _ dir: URL) -> Bool {
        !batch.items.isEmpty && batch.items.allSatisfy {
            under($0.rawPath, dir) && under($0.decodePath, dir) && FileManager.default.fileExists(atPath: $0.rawPath)
        }
    }

    private static func entry(_ batch: BatchStore, _ key: String) -> BatchStore.SessionEntry? {
        batch.recentSessions.first { $0.key == key }
    }

    private static func sameDir(_ a: URL?, _ b: URL) -> Bool {
        guard let a, let x = SessionLocation.identity(a.path) else { return false }
        return x == SessionLocation.identity(b.path)
    }

    /// 批量页来的照片（有 previewPath）：托盘、方案里各张的路径。
    private static func collagePaths(_ p: CollageProject) -> [String] {
        let tray = p.photos.filter { $0.previewPath != nil }.map(\.path)
        let saved = p.variants.flatMap { $0.project.photos.filter { $0.previewPath != nil }.map(\.path) }
        return tray + saved
    }

    // MARK: - 纯函数

    private static func pureRebase(_ dir: URL) {
        print("== 路径换根（纯函数）")
        check(SessionLocation.rebased("/a/b/c.jpg", from: "/a/b", to: "/x") == "/x/c.jpg", "旧根下面的换到新根下")
        check(SessionLocation.rebased("/a/b/sub/c.jpg", from: "/a/b/", to: "/x/") == "/x/sub/c.jpg", "结尾带 / 的根也认")
        check(SessionLocation.rebased("/a/bc/c.jpg", from: "/a/b", to: "/x") == nil, "按整段比：/a/bc 不在 /a/b 下面")
        check(SessionLocation.rebased("/a/b", from: "/a/b", to: "/x") == nil, "根本身不是照片，不换")
        // 同一个文件夹换了写法（/private/var 和 /var）：不改 manifest。
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = dir.appendingPathComponent("session")
        try? fm.createDirectory(at: session, withIntermediateDirectories: true)
        let real = dir.resolvingSymlinksInPath().path
        let alias = real.hasPrefix("/private/") ? String(real.dropFirst("/private".count)) : "/private" + real
        if SessionLocation.identity(alias) == SessionLocation.identity(real) {
            let json: [String: Any] = ["photo_dir": alias, "photos": [["id": "x", "raw_path": alias + "/x.jpg"]]]
            try? JSONSerialization.data(withJSONObject: json).write(to: session.appendingPathComponent("manifest.json"))
            let before = manifestText(session)
            let result = SessionLocation.rebaseManifest(in: session, to: URL(fileURLWithPath: real))
            check(result.rebase == nil && !result.failed && manifestText(session) == before,
                  "同一个文件夹换了写法（\(alias.hasPrefix("/private") ? "/private 前缀" : "去掉 /private")）：manifest 不动")
        }
        // 真挪了：photo_dir、raw_path、decode_path 改过去，preview_path、别的字段不动，不在旧根下的不动。
        let old = dir.appendingPathComponent("旧").path
        let new = dir.appendingPathComponent("新")
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        let photos: [[String: Any]] = [
            ["id": "a", "raw_path": old + "/a.RAF", "decode_path": old + "/a.JPG", "preview_path": "previews/a.jpg", "camera": "X-T5"],
            ["id": "b", "raw_path": "/别处/b.JPG", "decode_path": "/别处/b.JPG", "preview_path": "previews/b.jpg"],
        ]
        let json: [String: Any] = ["photo_dir": old, "photos": photos]
        try? JSONSerialization.data(withJSONObject: json).write(to: session.appendingPathComponent("manifest.json"))
        let moved = SessionLocation.rebaseManifest(in: session, to: new)
        let after = (try? Data(contentsOf: session.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let rows = after?["photos"] as? [[String: Any]] ?? []
        let a = rows.first { $0["id"] as? String == "a" } ?? [:]
        let b = rows.first { $0["id"] as? String == "b" } ?? [:]
        check(moved.rebase == SessionLocation.ManifestRebase(from: old, rows: 1) && after?["photo_dir"] as? String == new.path,
              "挪了：photo_dir 改成新位置，改了 1 行", "\(String(describing: moved.rebase))")
        check(a["raw_path"] as? String == new.path + "/a.RAF" && a["decode_path"] as? String == new.path + "/a.JPG"
              && a["preview_path"] as? String == "previews/a.jpg" && a["camera"] as? String == "X-T5",
              "raw_path / decode_path 换根，preview_path 和别的字段不动", "\(a)")
        check(b["raw_path"] as? String == "/别处/b.JPG", "不在旧根下面的路径不动")
        let missing = SessionLocation.rebaseManifest(in: session, to: dir.appendingPathComponent("不存在"))
        check(missing.rebase == nil && !missing.failed, "新位置不存在：不改")
    }

    private static func manifestText(_ session: URL) -> String {
        (try? String(contentsOf: session.appendingPathComponent("manifest.json"), encoding: .utf8)) ?? ""
    }

    // MARK: - 改名以后从「选择文件夹…」打开

    private static func renamedThenPicked(_ root: URL, model: AppModel) {
        print("== 同卷改名以后从「选择文件夹…」/ 拖进来打开新路径")
        let fm = FileManager.default
        let batch = model.batch
        let collage = model.collage
        let a = root.appendingPathComponent("婚礼 0321")
        let b = root.appendingPathComponent("婚礼 0321 已交付")
        FileSafetySelfTest.writeShoot(a, shoot(a))
        check(batch.switchSession(to: a) && batch.items.count == 3, "打开原来的文件夹：3 张", "\(batch.items.count)")
        FileSafetySelfTest.waitUntil(0.3) { false }
        model.ensureCollageAttached()
        batch.setOverride("DSCF0002", .reject)
        batch.importClientPicks(["DSCF0001"])
        collage.importFromBatch(ids: ["DSCF0001", "DSCF0002"], batch: batch, layout: true)
        let laidOut = FileSafetySelfTest.waitUntil {
            !collage.isSolving && collage.project.usedPhotoIDs == ["DSCF0001", "DSCF0002"]
        }
        check(laidOut, "拼图排了一版", "\(collage.project.usedPhotoIDs.sorted())")
        var saved = false
        if case .saved = collage.saveVariant() { saved = true }
        check(saved, "存成方案")
        collage.importFromBatch(ids: ["IMG_0003"], batch: batch, layout: false)
        check(FileSafetySelfTest.waitUntil { collage.project.photos.count == 3 } && collage.canUndo,
              "IMG_0003 进了托盘（撤销栈里有东西）")
        let keyA = key(a)
        check(batch.sessionDir.lastPathComponent == keyA, "场次 key 是按原来的路径算的")

        do {
            try fm.moveItem(at: a, to: b)
        } catch {
            check(false, "改名", error.localizedDescription)
            return
        }
        check(batch.switchSession(to: b), "打开改了名的文件夹")
        check(batch.sessionDir.lastPathComponent == keyA, "沿用原来那一场的 key（不开新的空场次）",
              batch.sessionDir.lastPathComponent)
        check(!fm.fileExists(atPath: appDataDir.appendingPathComponent("sessions/\(key(b))").path),
              "没按新路径建场次目录")
        check(batch.items.count == 3 && batch.overrides["DSCF0002"] == .reject && batch.clientPicks.contains("DSCF0001"),
              "3 张、人工改判、客户选中都在", "\(batch.items.count) \(batch.overrides) \(batch.clientPicks)")
        check(sameDir(batch.photoDir, b) && pathsUnder(batch, b), "网格里的照片路径都在新位置",
              batch.items.map(\.rawPath).joined(separator: ", "))
        check(manifestPhotoDir(keyA) == b.path, "manifest 的 photo_dir 改成新位置", manifestPhotoDir(keyA) ?? "nil")
        check(batch.progressText.contains("认出了"), "状态栏说认出了哪一场", batch.progressText)
        let row = entry(batch, keyA)
        check(row?.path == a.path && row?.name == b.lastPathComponent && entry(batch, key(b)) == nil,
              "最近场次：还是原来那一条（path 钉着原路径，名字换成新的），没多出一条", "\(String(describing: row))")

        // 拼图：AppModel 的订阅下一拍才挂；托盘、方案、撤销栈里的路径都跟上。
        model.ensureCollageAttached()
        let followed = FileSafetySelfTest.waitUntil(10) {
            let paths = collagePaths(collage.project)
            return paths.count >= 5 && paths.allSatisfy { under($0, b) }
        }
        check(followed, "拼图托盘和方案里的照片路径跟到新位置", collagePaths(collage.project).joined(separator: ", "))
        collage.undo()
        let undone = collagePaths(collage.project)
        check(!undone.isEmpty && undone.allSatisfy { under($0, b) }, "撤销一步回去的那一版也是新位置",
              undone.joined(separator: ", "))
        collage.redo()
        // 落盘（换到别的场次会先把这一场的存下来），读回来看 collage.json。
        collage.attach(sessionDir: nil, photoDir: nil, batch: nil)
        let file = appDataDir.appendingPathComponent("sessions/\(keyA)/collage.json")
        if case .ok(let disk) = SessionFiles.read(CollageProject.self, at: file, moveAside: false) {
            let paths = collagePaths(disk)
            check(paths.count >= 5 && paths.allSatisfy { under($0, b) }, "存盘的 collage.json 里也是新位置",
                  paths.joined(separator: ", "))
        } else {
            check(false, "读回 collage.json")
        }
        model.ensureCollageAttached()

        // 写 XMP：写在新位置的照片旁边。
        batch.exportXMP(.all)
        FileSafetySelfTest.wait(batch)
        let sidecars = ["DSCF0001", "DSCF0002", "第二机位/IMG_0003"].map { b.appendingPathComponent($0 + ".xmp").path }
        check(sidecars.allSatisfy(fm.fileExists(atPath:)) && !fm.fileExists(atPath: a.path),
              "写 XMP：3 个 .xmp 都写在新位置，原来的位置没被建回来", batch.lastError ?? "")
    }

    // MARK: - 拷贝出来的副本

    private static func copyIsNotAdopted(_ root: URL, batch: BatchStore) {
        print("== 拷贝出来的副本（原来的还在）不认")
        let fm = FileManager.default
        let c = root.appendingPathComponent("原件")
        let d = root.appendingPathComponent("副本")
        FileSafetySelfTest.writeShoot(c, shoot(c))
        check(batch.switchSession(to: c) && batch.items.count == 3, "打开原件")
        try? fm.copyItem(at: c, to: d)
        check(batch.switchSession(to: d), "打开副本")
        check(batch.sessionDir.lastPathComponent == key(d) && batch.items.isEmpty,
              "副本是新的一场（空的，等分析）", "\(batch.sessionDir.lastPathComponent) \(batch.items.count)")
        check(manifestPhotoDir(key(c)) == c.path, "原件那一场的 manifest 没动")
        let resolved = entry(batch, key(c))?.bookmark.flatMap(SessionLocation.resolveQuietly)
        check(sameDir(resolved, c), "原件那一条的书签还指着原件")
    }

    // MARK: - 从菜单点 / 重开 app

    private static func reopenFromMenu(_ root: URL, batch: BatchStore) {
        print("== 从菜单点 / 重开 app：书签跟到新位置，照片路径改过去")
        let fm = FileManager.default
        let e = root.appendingPathComponent("菜单原名")
        let f = root.appendingPathComponent("菜单新名")
        FileSafetySelfTest.writeShoot(e, shoot(e))
        check(batch.switchSession(to: e) && batch.items.count == 3, "打开原来的文件夹")
        try? fm.moveItem(at: e, to: f)
        guard let row = entry(batch, key(e)) else {
            check(false, "最近场次里有这一场")
            return
        }
        check(batch.switchSession(to: URL(fileURLWithPath: row.path)), "从菜单点原来那一条（传的是原路径）")
        check(batch.sessionDir.lastPathComponent == key(e) && sameDir(batch.photoDir, f) && pathsUnder(batch, f),
              "key 不变，照片路径改到新位置", batch.items.map(\.rawPath).joined(separator: ", "))
        check(manifestAt(key(e), f) && batch.progressText.contains("挪过"), "manifest 改了、状态栏说了一声",
              batch.progressText)
        // 重开 app（这一场是最近一条）：启动时重开它，路径已经是新的。
        let relaunched = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        check(relaunched.sessionDir.lastPathComponent == key(e) && pathsUnder(relaunched, f),
              "重开 app：还是这一场，照片路径在新位置")
    }

    // MARK: - 重新定位文件夹

    private static func relocate(_ root: URL, batch: BatchStore) {
        print("== 「重新定位文件夹…」：拷到别处、原来的删了")
        let fm = FileManager.default
        let g = root.appendingPathComponent("移动硬盘上的")
        let h = root.appendingPathComponent("NAS 上的")
        let empty = root.appendingPathComponent("选错的空文件夹")
        FileSafetySelfTest.writeShoot(g, shoot(g))
        check(batch.switchSession(to: g) && batch.items.count == 3, "打开原来的文件夹")
        batch.setOverride("DSCF0001", .pick)
        try? fm.copyItem(at: g, to: h)
        try? fm.removeItem(at: g)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        guard let row = entry(batch, key(g)) else {
            check(false, "最近场次里有这一场")
            return
        }
        check(row.bookmark.flatMap(SessionLocation.resolveQuietly) == nil, "原来的删了：书签解析不到（跨卷拷贝就是这样）")
        check(batch.switchSession(to: URL(fileURLWithPath: row.path)) && (batch.lastError ?? "").contains("重新定位"),
              "从菜单点：说文件夹不在了、提「重新定位文件夹…」", batch.lastError ?? "")
        check(batch.switchSession(to: h) && batch.sessionDir.lastPathComponent == key(h) && batch.items.isEmpty,
              "直接选拷过去的文件夹：书签对不上，是新的一场（跨卷指纹匹配是第二步）")
        check(!batch.relocateSession(row, to: empty) && (batch.lastError ?? "").contains("找不到"),
              "指给一个没有这一场照片的文件夹：不换", batch.lastError ?? "")
        check(entry(batch, key(g))?.bookmark == row.bookmark, "选错了：书签没换")
        check(batch.relocateSession(row, to: h), "指给拷过去的文件夹", batch.lastError ?? "")
        check(batch.sessionDir.lastPathComponent == key(g) && batch.items.count == 3 && batch.overrides["DSCF0001"] == .pick,
              "key 不变，3 张、人工改判都在")
        check(sameDir(batch.photoDir, h) && pathsUnder(batch, h) && manifestAt(key(g), h),
              "照片路径、manifest 改到新位置", batch.items.map(\.rawPath).joined(separator: ", "))
        check(batch.progressText.contains("重新定位") && !batch.progressText.contains("两条都在"),
              "状态栏说重新定位了（新位置自己那一场没分析过，不说两条）", batch.progressText)
        let resolved = entry(batch, key(g))?.bookmark.flatMap(SessionLocation.resolveQuietly)
        check(sameDir(resolved, h), "书签换成新位置")
        // 重新定位以后再直接选它：新位置自己那一场没分析过（没有 manifest），认回原来那一场。
        check(batch.switchSession(to: h) && batch.sessionDir.lastPathComponent == key(g),
              "重新定位以后直接选新位置：认回原来那一场")
    }

    // MARK: - 实时桥

    private static func liveBridgeDoesNotFollow(_ root: URL, batch: BatchStore) {
        print("== 实时桥（followBookmark: false）不跟书签、不认回、不改路径")
        let fm = FileManager.default
        let i = root.appendingPathComponent("实时桥原名")
        let j = root.appendingPathComponent("实时桥新名")
        FileSafetySelfTest.writeShoot(i, shoot(i))
        check(batch.switchSession(to: i) && batch.items.count == 3, "打开原来的文件夹")
        try? fm.moveItem(at: i, to: j)
        check(batch.switchSession(to: i, followBookmark: false), "实时桥按登记的路径打开")
        check(batch.photoDir?.path == i.path && (batch.lastError ?? "").contains("已不存在"),
              "停在登记的路径上，说文件夹不在了", batch.lastError ?? "")
        check(manifestPhotoDir(key(i)) == i.path, "manifest 没改")
    }
}
