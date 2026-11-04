import Foundation

/// 挪了的文件夹认得回来（2026-11 全项目审查 S04 第一步）、存储卡当一场打开时不写卡（S07）：
///     LABELGUI_DATA_DIR=<临时目录> LabelGUI --session-move-selftest
/// 在数据目录里造几场假的拍摄（FileSafetySelfTest.writeShoot：小 JPEG + 手写的 manifest / layer1，不跑分析），真的改名、
/// 拷贝、删掉文件夹，逐条断言、打 PASS / FAIL：
///   - 同卷改名以后从「选择文件夹…」/ 拖进来打开新路径：沿用旧场次的 key（不开空场次），判决、客户选中都在；manifest 和
///     网格里的照片路径改到新位置；写 XMP 写在新位置；拼图托盘、方案、撤销栈里的照片路径跟上，存盘的 collage.json 也是。
///   - 拷贝出来的副本（原来的还在）不认，照常是新的一场。
///   - 从菜单点 / 重开 app：书签跟到新位置，照片路径改过去。
///   - 「重新定位文件夹…」：跨卷拷过去、原来的删了（书签解析不到）—— 指给它新位置以后 key 不变、路径改过去；
///     选错文件夹（一张这一场的照片都没有）不换书签。
///   - 实时桥（followBookmark: false）不跟书签、不认回、不改路径。
///   - 存储卡：判断表（DCIM 在卷根 + 可移除 / 可推出才算；外置 SSD、系统盘、网络卷不算；读不出来按「可能是」），
///     真读一个系统盘上的 DCIM 文件夹不算卡；编的卷属性（CardImporter.volumeFactsOverride，不挂真的卡 —— hdiutil 挂的映像
///     会弹「可移除的宗卷」授权框）打开卡上的 DCIM/100CANON：移废片、写 XMP、高 ISO 复制、导出到卡上、复制原片到卡上、水印导出到卡上（含「导出到 水印导出/」）、拼图默认目录和「选择…」选到卡上都挡住，
///     卡上一个文件都没多、没少；导出到卡外照常；外置 SSD 上的工作文件夹照常。
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
        cardTable(root.appendingPathComponent("card-table"))
        cardSession(root.appendingPathComponent("card"), model: model)
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

// MARK: - 存储卡当一场打开（S07）

extension SessionMoveSelfTest {
    private static func cardTable(_ dir: URL) {
        print("== 存储卡判断表（纯函数）+ 真读一个系统盘上的 DCIM")
        let card = CardVolumeFacts(removable: true, ejectable: true, rootFileSystem: false, local: true,
                                   volumePath: "/Volumes/EOS_DIGITAL", name: "EOS_DIGITAL")
        let ssd = CardVolumeFacts(removable: false, ejectable: true, rootFileSystem: false, local: true,
                                  volumePath: "/Volumes/T7", name: "T7")
        let system = CardVolumeFacts(removable: false, ejectable: false, rootFileSystem: true, local: true,
                                     volumePath: "/", name: "Macintosh HD")
        let nas = CardVolumeFacts(removable: false, ejectable: true, rootFileSystem: false, local: false,
                                  volumePath: "/Volumes/photo", name: "photo")
        let fixedDisk = CardVolumeFacts(removable: false, ejectable: false, rootFileSystem: false, local: true,
                                        volumePath: "/Volumes/Data2", name: "Data2")
        func kind(_ path: String, child: Bool = false, _ facts: CardVolumeFacts?) -> CardSessionCheck.Kind {
            CardImporter.classifyCardSession(path: path, hasDCIMChild: child, facts: facts).kind
        }
        let full = CardImporter.classifyCardSession(path: "/Volumes/EOS_DIGITAL/DCIM/100CANON", hasDCIMChild: false, facts: card)
        check(full == CardSessionCheck(kind: .card, name: "EOS_DIGITAL", root: "/Volumes/EOS_DIGITAL"),
              "卡上的 DCIM/100CANON → 是卡，带卡名和挂载点", "\(full)")
        check(kind("/Volumes/EOS_DIGITAL/DCIM", card) == .card, "卡上的 DCIM 本身 → 是卡")
        check(kind("/Volumes/EOS_DIGITAL/dcim/100CANON", card) == .card, "小写 dcim 也认")
        check(kind("/Volumes/EOS_DIGITAL", child: true, card) == .card, "打开的是卡的根（下面有 DCIM）→ 是卡")
        check(kind("/Volumes/EOS_DIGITAL", child: false, card) == .no, "可移除盘的根、下面没有 DCIM → 不是")
        check(kind("/Volumes/T7/项目/0321", ssd) == .no, "外置 SSD 上的工作文件夹（路径里没有 DCIM）→ 不是")
        check(kind("/Volumes/T7/备份/DCIM/100CANON", ssd) == .no, "外置 SSD 上备份的 DCIM（不在卷根下）→ 不是")
        check(kind("/Volumes/T7/备份", child: true, ssd) == .no, "外置 SSD 上的文件夹、下面有 DCIM（不是卷根）→ 不是")
        check(kind("/Volumes/T7/DCIM/100CANON", ssd) == .card, "可推出的盘、卷根下就是 DCIM（读卡器里的卡就是这样）→ 当卡挡")
        check(kind("/Users/x/Pictures/卡备份/DCIM/100CANON", system) == .no, "系统盘上拷出来的 DCIM → 不是")
        check(kind("/Volumes/photo/DCIM/100CANON", nas) == .no, "网络卷上的 DCIM → 不是")
        check(kind("/Volumes/Data2/DCIM/100CANON", fixedDisk) == .no, "不可移除、不可推出的内置第二块盘 → 不是")
        check(kind("/Volumes/EOS_DIGITAL/DCIM/100CANON", nil) == .maybe, "卷属性整个读不出来 → 可能是卡（照样挡）")
        var noRemovable = card
        noRemovable.removable = nil
        noRemovable.ejectable = nil
        check(kind("/Volumes/EOS_DIGITAL/DCIM", noRemovable) == .maybe, "可不可移除读不出来 → 可能是")
        var noRoot = card
        noRoot.rootFileSystem = nil
        check(kind("/Volumes/EOS_DIGITAL/DCIM", noRoot) == .maybe, "是不是系统盘读不出来 → 可能是")
        var noMount = card
        noMount.volumePath = nil
        check(kind("/Volumes/EOS_DIGITAL/DCIM", noMount) == .maybe, "挂载点读不出来 → 可能是")
        check(kind("/Users/x/Pictures/0321", nil) == .no, "路径里没有 DCIM：不看卷属性，直接不是")
        let maybe = CardImporter.classifyCardSession(path: "/Volumes/EOS_DIGITAL/DCIM", hasDCIMChild: false, facts: nil)
        check(maybe.blocksWrites && maybe.subject.contains("像是在存储卡上"), "「可能是」也挡写，话里说「像是」", maybe.subject)
        check(full.subject == "这是存储卡「EOS_DIGITAL」上的文件夹", "是卡：话里带卡名", full.subject)

        let check1 = CardSessionCheck(kind: .card, name: "EOS_DIGITAL", root: "/Volumes/EOS_DIGITAL")
        check(check1.contains(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL/导出JPG"), photoDir: nil), "导出目标在卡上 → 在")
        check(check1.contains(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL"), photoDir: nil), "卡的根本身 → 在")
        check(!check1.contains(URL(fileURLWithPath: "/Users/x/Pictures/导出"), photoDir: nil), "电脑上的文件夹 → 不在")
        check(!check1.contains(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL_2/导出"), photoDir: nil), "名字带同样前缀的另一张卡 → 不在")
        check(!CardSessionCheck.no.contains(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL/x"), photoDir: nil), "不是卡的场次什么都不挡")

        // 真读：数据目录在系统盘上，DCIM/100CANON 也不算卡（不编卷属性）。
        let real = dir.appendingPathComponent("DCIM/100CANON")
        try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let facts = CardImporter.volumeFacts(of: real)
        check(facts?.rootFileSystem == true, "真读卷属性：数据目录在系统盘上", "\(String(describing: facts))")
        check(CardImporter.cardSession(for: real) == .no, "真读：系统盘上的 DCIM/100CANON 不算卡")
        check(CardImporter.cardSession(for: dir) == .no, "真读：下面有 DCIM 的系统盘文件夹不算卡")
    }

    private static func cardSession(_ root: URL, model: AppModel) {
        print("== 存储卡当一场打开：移废片、写 XMP、高 ISO、导出到卡上、复制原片、水印导出、拼图默认目录和「选择…」都不写卡（编的卷属性）")
        let fm = FileManager.default
        let batch = model.batch
        let collage = model.collage
        let card = root.appendingPathComponent("EOS_DIGITAL")
        let dcim = card.appendingPathComponent("DCIM/100CANON")
        let ssd = root.appendingPathComponent("T7")
        let off = root.appendingPathComponent("电脑上")
        try? fm.createDirectory(at: off, withIntermediateDirectories: true)
        FileSafetySelfTest.writeShoot(dcim, [
            Fake(id: "IMG_0001", raw: "IMG_0001.JPG", iso: 6400, jpeg: true),
            Fake(id: "IMG_0002", raw: "IMG_0002.CR3", iso: 6400),
            Fake(id: "IMG_0003", raw: "IMG_0003.JPG", jpeg: true),
        ])
        let cardPath = card.path
        let ssdPath = ssd.path
        CardImporter.volumeFactsOverride = { url in
            let path = url.standardizedFileURL.path
            if path.hasPrefix(cardPath + "/") || path == cardPath {
                return CardVolumeFacts(removable: true, ejectable: true, rootFileSystem: false, local: true,
                                       volumePath: cardPath, name: "EOS_DIGITAL")
            }
            if path.hasPrefix(ssdPath + "/") || path == ssdPath {
                return CardVolumeFacts(removable: false, ejectable: true, rootFileSystem: false, local: true,
                                       volumePath: ssdPath, name: "T7")
            }
            return nil
        }
        defer { CardImporter.volumeFactsOverride = nil }
        func cardListing() -> [String] {
            (fm.subpaths(atPath: card.path) ?? []).sorted()
        }

        check(batch.switchSession(to: dcim) && batch.items.count == 3, "打开卡上的 DCIM/100CANON：3 张")
        check(batch.cardSession == CardSessionCheck(kind: .card, name: "EOS_DIGITAL", root: cardPath) && batch.isCardSession,
              "认出是存储卡「EOS_DIGITAL」", "\(batch.cardSession)")
        check(batch.defaultJPEGExportFolder == nil, "没有默认的「导出JPG/」（导出到 / 精华按钮灰掉）")
        batch.setOverride("IMG_0001", .pick)
        batch.setOverride("IMG_0003", .reject)
        // 万一闸失效：要移的那张原片先删掉，trashRejects 一张都移不动，不会真的往废纸篓里放东西。
        try? fm.removeItem(at: dcim.appendingPathComponent("IMG_0003.JPG"))
        let before = cardListing()

        batch.trashRejects()
        FileSafetySelfTest.wait(batch)
        check((batch.lastError ?? "").contains("存储卡") && (batch.lastError ?? "").contains(".Trashes") && batch.items.count == 3,
              "移废片：不移，说卡自己的 .Trashes 格式化就没了", batch.lastError ?? "")
        batch.exportXMP(.all)
        FileSafetySelfTest.wait(batch)
        check((batch.lastError ?? "").contains("不带 .xmp") && !cardListing().contains { $0.hasSuffix(".xmp") },
              "写 XMP：不写，说正式导入不带 .xmp", batch.lastError ?? "")
        batch.exportHighISORaws(minISO: 3200, keepersOnly: false)
        FileSafetySelfTest.wait(batch)
        check((batch.lastError ?? "").contains("高 ISO")
              && !fm.fileExists(atPath: dcim.appendingPathComponent(ImageLoader.denoiseSubfolder).path),
              "高 ISO 复制：不复制、没建「高ISO降噪/」", batch.lastError ?? "")
        let options = DeliveryOptions.jpegExport(legacyMaxPixel: 1024, legacyQuality: 0.85)
        let onCard = card.appendingPathComponent("导出")
        batch.exportJPEGs(to: onCard, includeUsable: true, options: options)
        FileSafetySelfTest.wait(batch)
        check((batch.lastError ?? "").contains("导出目标") && !fm.fileExists(atPath: onCard.path),
              "导出 JPG 选了卡上的文件夹：不导、没建", batch.lastError ?? "")
        batch.exportHighlights(count: 5, into: card.appendingPathComponent("精华"), options: options)
        FileSafetySelfTest.wait(batch)
        check((batch.lastError ?? "").contains("导出目标") && !fm.fileExists(atPath: card.appendingPathComponent("精华").path),
              "精华导到卡上：不导", batch.lastError ?? "")
        // 复制原片到…：面板以前从拍摄文件夹旁边（卡的 DCIM）开，卡上的目标照收（原片副本、精修要求.csv 都写在卡上）。
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        let startFresh = batch.copyPanelStartFolder
        check(batch.lastCopyDestination == nil && startFresh != nil && startFresh == pictures
              && !(startFresh?.path ?? "").hasPrefix(cardPath),
              "复制原片的面板：卡上的一场不从卡的 DCIM 开，从「图片」开", startFresh?.path ?? "nil")
        for target in [card.appendingPathComponent("DCIM"), card.appendingPathComponent("DCIM/精修"),
                       dcim.appendingPathComponent("精修")] {
            batch.copyOriginals(["IMG_0001"], to: target)
            FileSafetySelfTest.wait(batch)
            let name = String(target.path.dropFirst(cardPath.count))
            check((batch.lastError ?? "").contains("存储卡") && batch.lastCopyDestination == nil
                  && !fm.fileExists(atPath: target.appendingPathComponent("IMG_0001.JPG").path),
                  "复制原片到卡上的「\(name)」：不复制、不记成下次的目标", batch.lastError ?? "nil")
        }
        check(!(batch.lastError ?? "").contains("_精修"), "　…… 不叫人在旁边新建「_精修」（旁边也在卡上）", batch.lastError ?? "")
        // 老版本记下的卡上目标：面板不从那儿开。
        let record = batch.sessionDir.appendingPathComponent("copy_originals.json")
        try? JSONEncoder().encode(["dest": card.appendingPathComponent("DCIM/精修").path]).write(to: record)
        check(batch.lastCopyDestination != nil && batch.copyPanelStartFolder == pictures,
              "上次记的复制目标在卡上：面板不从那儿开", batch.copyPanelStartFolder?.path ?? "nil")
        // 水印页（AppModel.make 接上的卡闸）：输出目录在卡上不导；在卡上的拍摄文件夹里面也不给「导出到 水印导出/」（它也在卡上）。
        let wm = model.watermark
        wm.config.frame.enabled = true
        wm.addPhotos([dcim.appendingPathComponent("IMG_0001.JPG")])
        for target in [card.appendingPathComponent("水印"), dcim.appendingPathComponent("成品")] {
            wm.outputDir = target
            wm.exportAll(shootDir: batch.photoDir, sessions: [])
            let name = String(target.path.dropFirst(cardPath.count))
            check(!wm.isExporting && (wm.lastError ?? "").contains("存储卡") && wm.folderRefusal == nil
                  && !fm.fileExists(atPath: target.path),
                  "水印导出到卡上的「\(name)」：不导、不建，不给「导出到 水印导出/」", wm.lastError ?? "nil")
        }
        let wmOff = off.appendingPathComponent("水印")
        wm.outputDir = wmOff
        for target in [card.appendingPathComponent("水印"), dcim.appendingPathComponent("成品")] {
            wm.chooseOutputDir(target, shootDir: batch.photoDir, sessions: [])
            let name = String(target.path.dropFirst(cardPath.count))
            check(wm.outputDir == wmOff && (wm.lastError ?? "").contains("存储卡") && wm.folderRefusal == nil,
                  "水印页输出目录选到卡上的「\(name)」：不换，不给「改用 水印导出/」", wm.lastError ?? "nil")
        }
        check(cardListing() == before, "卡上一个文件都没多、没少", "\(cardListing())")
        wm.chooseOutputDir(wmOff, shootDir: batch.photoDir, sessions: [])
        check(wm.outputDir == wmOff && wm.lastError == nil, "　…… 再选卡外的目录：换上，卡上那句收掉", wm.lastError ?? "")
        wm.exportAll(shootDir: batch.photoDir, sessions: [])
        let wmStarted = wm.isExporting
        FileSafetySelfTest.waitUntil(60) { !wm.isExporting }
        let wmWritten = (try? fm.contentsOfDirectory(atPath: wmOff.path)) ?? []
        check(wmStarted && wmWritten.contains { $0.lowercased().hasSuffix(".jpg") },
              "水印导出到卡外照常导", "\(wmWritten) \(wm.lastError ?? "")")
        let offCopy = off.appendingPathComponent("精修")
        batch.copyOriginals(["IMG_0001"], to: offCopy)
        FileSafetySelfTest.wait(batch)
        check(fm.fileExists(atPath: offCopy.appendingPathComponent("IMG_0001.JPG").path)
              && sameDir(batch.copyPanelStartFolder, offCopy),
              "复制原片到卡外照常复制，下次面板从那儿开", "\(batch.lastError ?? "") \(batch.copyPanelStartFolder?.path ?? "nil")")

        let offExport = off.appendingPathComponent("导出JPG")
        batch.exportJPEGs(to: offExport, includeUsable: true, options: options)
        FileSafetySelfTest.wait(batch)
        let written = (try? fm.contentsOfDirectory(atPath: offExport.path)) ?? []
        check(written.contains { $0.lowercased().hasSuffix(".jpg") }, "导出到卡外的文件夹照常导", "\(written) \(batch.lastError ?? "")")

        // 拼图：默认目录（卡上的「拼图导出/」）不给；选到卡上的不导；选到卡外的照常。
        FileSafetySelfTest.waitUntil(0.3) { false }
        model.ensureCollageAttached()
        collage.importFromBatch(ids: ["IMG_0001"], batch: batch, layout: true)
        check(FileSafetySelfTest.waitUntil { !collage.isSolving && !collage.project.pages.isEmpty }, "拼图排了一版")
        let savedOptions = collage.exportOptions
        collage.exportOptions.outputPath = nil
        check(collage.defaultOutputFolder == nil && collage.outputFolder == nil
              && (collage.exportBlockedReason ?? "").contains("存储卡"),
              "拼图默认目录在卡上：不给，导出按钮说先选卡外的目录", collage.exportBlockedReason ?? "nil")
        let collageOnCard = card.appendingPathComponent("拼图")
        collage.exportOptions.outputPath = collageOnCard.path
        let refused = collage.startExport(project: collage.project, options: collage.exportOptions, name: "卡上", reveal: false)
        check((refused ?? "").contains("导出目标") && !fm.fileExists(atPath: collageOnCard.path)
              && (collage.exportBlockedReason ?? "").contains("导出目标"),
              "拼图输出目录选到卡上：不导（AI 的 collage_export 走同一个 startExport）", refused ?? "nil")
        collage.exportOptions.outputPath = off.appendingPathComponent("拼图").path
        check(collage.exportBlockedReason == nil, "拼图输出目录选到卡外：可以导", collage.exportBlockedReason ?? "")
        // 「选择…」面板选完：选到卡上（拍摄文件夹外面 / 里面）不换、说卡上不写，不叫人点「用默认」（卡上的一场没有默认目录）
        let chosenBefore = collage.exportOptions.outputPath
        for target in [card.appendingPathComponent("拼图2"), dcim.appendingPathComponent("成品")] {
            let took = collage.chooseOutputFolder(target)
            let name = String(target.path.dropFirst(cardPath.count))
            let said = collage.lastError ?? ""
            check(!took && collage.exportOptions.outputPath == chosenBefore && said.contains("存储卡") && !said.contains("用默认"),
                  "拼图「选择…」选到卡上的「\(name)」：不换，说卡上不写、不叫人点「用默认」", said)
        }
        let offCollage = off.appendingPathComponent("拼图2")
        let tookOff = collage.chooseOutputFolder(offCollage)
        check(tookOff && collage.exportOptions.outputPath == offCollage.path && collage.lastError == nil,
              "　…… 再选卡外的：换上，卡上那句收掉", collage.lastError ?? "")
        collage.exportOptions = savedOptions
        check(cardListing() == before, "拼图这一路也没往卡上写", "\(cardListing())")

        // 外置 SSD 上的工作文件夹（可推出、没有 DCIM）、SSD 上备份的 DCIM（不在卷根）：照常是普通场次。
        let work = ssd.appendingPathComponent("项目/0321")
        FileSafetySelfTest.writeShoot(work, [Fake(id: "A", raw: "A.JPG", jpeg: true)])
        check(batch.switchSession(to: work) && !batch.isCardSession && batch.defaultJPEGExportFolder != nil,
              "外置 SSD 上的工作文件夹：不当卡，默认导出目录照常", "\(batch.cardSession)")
        let backup = ssd.appendingPathComponent("备份/DCIM/100CANON")
        FileSafetySelfTest.writeShoot(backup, [Fake(id: "B", raw: "B.JPG", jpeg: true)])
        check(batch.switchSession(to: backup) && !batch.isCardSession, "外置 SSD 上备份的 DCIM：不当卡")
        check(batch.switchSession(to: dcim) && batch.isCardSession, "切回卡上那一场：又认出是卡")
        check(batch.switchSession(to: work) && !batch.isCardSession, "切到别的场次：卡的标记跟着清掉")

        // 水印页的「导出到 水印导出/」是在别的场次拦下的（照片所在的卡上文件夹），之后批量页换到卡上那一场再点：不换、不导。
        wm.outputDir = dcim.appendingPathComponent("成品")
        wm.exportAll(shootDir: batch.photoDir, sessions: [])
        let offered = wm.folderRefusal?.safeFolder
        check(!wm.isExporting && offered.map { under($0.path, card) } == true,
              "前提：不是卡上那一场时，卡上照片文件夹里的输出目录照旧给「导出到 水印导出/」", offered?.path ?? "nil")
        check(batch.switchSession(to: dcim) && batch.isCardSession, "　…… 批量页换到卡上那一场")
        wm.useSafeOutputDir(shootDir: batch.photoDir, sessions: [])
        check(!wm.isExporting && wm.outputDir == dcim.appendingPathComponent("成品")
              && (wm.lastError ?? "").contains("存储卡") && wm.folderRefusal == nil && cardListing() == before,
              "　…… 再点「导出到 水印导出/」：不换到卡上、不导，卡上一个文件没多", "\(wm.lastError ?? "nil") \(cardListing())")
        wm.clearPhotos()
    }
}
