import Foundation

/// 拼图、水印导出不写进拍摄文件夹（ExportFolderGuard，审查 S11）的进程内断言，挂在 --delivery-selftest 里
/// （「== 拼图、水印导出不写进拍摄文件夹」那一组）。全在 `dir`（数据目录下的临时目录）里建合成的拍摄文件夹，不读真照片：
/// - 判断本身：拍摄文件夹本身、里面的「交付」（还没建的也算）、指过去的软链接、经过软链接进去、/private 别名、大小写不同
///   → 拦；「水印导出」「拼图导出」「导出JPG/精华」、点开头的隐藏文件夹、拍摄文件夹的上一级、外面、拍摄文件夹不存在 → 不拦；
///   「水印导出」确实在分析跳过的名单里；水印页要查的文件夹 = 批量页那一场 + 照片所在的文件夹、去重（照片在「导出JPG」
///   「水印导出」里推到外面那一场；在别的候选的「.cache」里去掉，没有候选装着的点开头文件夹不往上推）；
///   最近场次只提醒（里面的提醒，外面的、分析跳过的子文件夹不提醒）；
/// - 水印页 exportAll：输出目录 = 照片所在的文件夹、里面还没建的「交付/客户A」、批量页那一场里面 → 一张不写、目录不建、
///   给「导出到 水印导出/」（不传批量页那一场的对照组照常导）；点了就导进 <拍摄文件夹>/水印导出/、原片不动；面板选到里面
///   不换、选外面的照换；最近场次里照常导、只提醒；照片来自「导出JPG」「水印导出」（分析跳过）→ 拍摄文件夹按外面那一场算：
///   旁边的「导出JPG/带水印」照常导、那一场的「交付」照样拦且点名那一场，一键改用导进 <那一场>/水印导出/ 只点一次；
/// - 拼图 startExport（导出按钮、MCP、命令行 export: 同一条路）：拍摄文件夹本身、里面的「交付」→ 拒绝、不建目录、
///   lastError 说清楚，MCP 入口（LiveHandlers.exportFolderRefused）回 invalid_state；默认的「拼图导出/」照常写出；
///   面板选到里面不换、选外面的照换、之前那句拦下的提示收掉。
/// 长的 && 链都拆成命名的 let（CI 的 Xcode 16 类型检查比本机严）。
@MainActor
enum ExportFolderSelfTest {
    typealias Check = (Bool, String, String) -> Void

    static func run(_ dir: URL, check: Check) {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let shoot = dir.appendingPathComponent("ShootA婚礼")
        let outside = dir.appendingPathComponent("外面")
        for name in ["交付", "水印导出", "拼图导出", "导出JPG/精华", ".cache"] {
            try? fm.createDirectory(at: shoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("指向拍摄文件夹")
        try? fm.createSymbolicLink(at: link, withDestinationURL: shoot)
        judgement(dir, shoot: shoot, outside: outside, link: link, check: check)
        watermark(dir, shoot: shoot, outside: outside, check: check)
        watermarkFromSkipped(dir, check: check)
        collage(dir, shoot: shoot, outside: outside, check: check)
        try? fm.removeItem(at: dir)
    }

    /// 这一层的文件名（不往下走）：拦下时拍摄文件夹一个文件都不能多。
    private static func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private static func entry(_ name: String, _ url: URL) -> BatchStore.SessionEntry {
        BatchStore.SessionEntry(key: name, path: url.path, name: name, lastAnalyzed: "", photoCount: 0)
    }

    private static func samePath(_ a: URL?, _ b: URL) -> Bool {
        a?.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// 数据目录在 /var、/tmp 下时它的 /private 别名（或者反过来）；不在就 nil。
    private static func privateAlias(_ path: String) -> String? {
        if path.hasPrefix("/private/") { return String(path.dropFirst("/private".count)) }
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { return "/private" + path }
        return nil
    }

    // MARK: - 判断本身

    private static func judgement(_ dir: URL, shoot: URL, outside: URL, link: URL, check: Check) {
        func hit(_ folder: URL, _ shoots: [URL]? = nil) -> Bool {
            ExportFolderGuard.blockingShoot(folder, among: shoots ?? [shoot]) != nil
        }
        func sub(_ path: String) -> URL { shoot.appendingPathComponent(path) }
        check(hit(shoot), "拍摄文件夹本身 → 拦", "")
        check(hit(sub("交付")), "里面的「交付」→ 拦", "")
        check(hit(sub("交付/客户A")), "里面还没建的「交付/客户A」→ 拦", "")
        check(hit(link), "指向拍摄文件夹的软链接 → 拦", "")
        check(hit(link.appendingPathComponent("交付")), "经过软链接进去的「交付」→ 拦", "")
        if let alias = privateAlias(shoot.path), FileManager.default.fileExists(atPath: alias) {
            check(hit(URL(fileURLWithPath: alias).appendingPathComponent("交付")), "/private 别名 → 拦", alias)
        } else {
            print("skip /private 别名：数据目录不在 /var、/tmp 下")
        }
        let upper = dir.appendingPathComponent(shoot.lastPathComponent.uppercased())
        if FileManager.default.fileExists(atPath: upper.path) {
            check(hit(upper.appendingPathComponent("交付")), "大小写不同（大小写不敏感的卷）→ 拦", upper.lastPathComponent)
        } else {
            print("skip 大小写不同：这个卷分大小写")
        }
        let skipped: Bool = !hit(sub("水印导出")) && !hit(sub("拼图导出")) && !hit(sub("导出JPG/精华"))
        check(skipped, "「水印导出」「拼图导出」「导出JPG/精华」（分析跳过）→ 不拦", "")
        check(!hit(sub(".cache")), "点开头的隐藏文件夹 → 不拦", "")
        check(!hit(dir), "拍摄文件夹的上一级 → 不拦", "")
        check(!hit(outside), "外面的 → 不拦", "")
        check(!hit(sub("交付"), [dir.appendingPathComponent("不存在的拍摄文件夹")]), "拍摄文件夹不存在（stat 不到）→ 不拦", "")
        check(ImageLoader.excludedSubfolders.contains(ExportFolderGuard.watermarkSubfolder),
              "「\(ExportFolderGuard.watermarkSubfolder)」在分析跳过的子文件夹名单里", "")

        let other = dir.appendingPathComponent("别处")
        let dotted = URL(fileURLWithPath: shoot.path + "/./d.jpg")
        let photos: [URL] = [sub("a.jpg"), sub("b.jpg"), other.appendingPathComponent("c.jpg"), dotted]
        let shoots: [String] = ExportFolderGuard.watermarkShoots(batch: outside, photos: photos).map(\.standardizedFileURL.path)
        let want: [String] = [outside, shoot, other].map(\.standardizedFileURL.path)
        let names = shoots.map { ($0 as NSString).lastPathComponent }
        check(shoots == want, "水印页要查的：批量页那一场 + 照片所在的文件夹，去重", "\(names)")
        // 照片在 app 自己的输出文件夹里（分析跳过）：推到最上面那一段的上一级，不把「导出JPG」当成一场
        let exported: [URL] = [sub("导出JPG/精华/x.jpg"), sub("水印导出/y.jpg"), sub("导出JPG/水印导出/z.jpg"), sub("导出JPG/w.jpg")]
        let roots: [String] = ExportFolderGuard.watermarkShoots(batch: nil, photos: exported).map(\.standardizedFileURL.path)
        let rootNames = roots.map { ($0 as NSString).lastPathComponent }
        check(roots == [shoot.standardizedFileURL.path], "照片在「导出JPG/精华」「水印导出」「导出JPG/水印导出」里 → 拍摄文件夹是外面那一场",
              "\(rootNames)")
        let fromExport = ExportFolderGuard.watermarkShoots(batch: nil, photos: [sub("导出JPG/w.jpg")])
        let besideExport: Bool = !hit(sub("导出JPG/带水印"), fromExport) && !hit(sub("导出JPG"), fromExport)
        check(besideExport, "　…… 输出到「导出JPG」本身、里面的「导出JPG/带水印」→ 不拦", "")
        let deliverHit = ExportFolderGuard.blockingShoot(sub("交付"), among: fromExport)
        check(samePath(deliverHit, shoot), "　…… 输出到那一场的「交付」→ 照样拦，点名的是那一场", deliverHit?.lastPathComponent ?? "nil")
        // 照片在点开头的文件夹里：落在别的候选分析跳过的子树里就去掉；不往上推（上一级不一定是一场）
        func paths(_ urls: [URL]) -> [String] { urls.map(\.standardizedFileURL.path) }
        let inHidden = ExportFolderGuard.watermarkShoots(batch: shoot, photos: [sub(".cache/q.jpg")])
        check(paths(inHidden) == paths([shoot]), "照片在那一场的「.cache」里 → 只查那一场（.cache 不算一场）",
              "\(inHidden.map(\.lastPathComponent))")
        let hiddenBeside: Bool = !hit(sub(".cache/带水印"), inHidden) && hit(sub("交付"), inHidden)
        check(hiddenBeside, "　…… 输出「.cache/带水印」→ 不拦，「交付」照样拦", "")
        let byPhoto = ExportFolderGuard.watermarkShoots(batch: nil, photos: [sub("a.jpg"), sub(".cache/r.jpg")])
        check(paths(byPhoto) == paths([shoot]), "　…… 批量页没开、同一批里有那一场根目录的照片 → 也去掉「.cache」",
              "\(byPhoto.map(\.lastPathComponent))")
        let loose = dir.appendingPathComponent(".藏/S2")
        let notWidened = ExportFolderGuard.watermarkShoots(batch: outside, photos: [loose.appendingPathComponent("r.jpg")])
        check(paths(notWidened) == paths([outside, loose]), "照片在「.藏/S2」、没有别的候选装着它 → 照样当一场查，不推成上一级",
              "\(notWidened.map(\.lastPathComponent))")

        let sessions = [entry("别处那一场", other), entry("婚礼A", shoot)]
        let note: String = ExportFolderGuard.sessionReminder(sub("交付"), sessions: sessions, what: "拼图") ?? ""
        check(note.hasPrefix("提醒") && note.contains("「婚礼A」"), "最近场次的拍摄文件夹里 → 提醒是哪一场", note)
        let viaLink = ExportFolderGuard.sessionReminder(link.appendingPathComponent("交付"), sessions: sessions, what: "拼图")
        check(viaLink != nil, "经过软链接进去的也提醒", "")
        let outsideNote = ExportFolderGuard.sessionReminder(outside, sessions: sessions, what: "拼图")
        let skippedNote = ExportFolderGuard.sessionReminder(sub("水印导出"), sessions: sessions, what: "拼图")
        check(outsideNote == nil, "外面的 → 不提醒", outsideNote ?? "")
        check(skippedNote == nil, "分析跳过的子文件夹 → 不提醒", skippedNote ?? "")
    }

    // MARK: - 水印页

    private static func watermark(_ dir: URL, shoot: URL, outside: URL, check: Check) {
        let fm = FileManager.default
        let p1 = shoot.appendingPathComponent("p1.jpg")
        let p2 = shoot.appendingPathComponent("p2.jpg")
        fm.createFile(atPath: p1.path, contents: CollageExportSelfTest.jpeg(width: 96, height: 64, gray: 0.3))
        fm.createFile(atPath: p2.path, contents: CollageExportSelfTest.jpeg(width: 96, height: 64, gray: 0.7))
        let originals: [Data?] = [p1, p2].map { try? Data(contentsOf: $0) }
        let store = WatermarkStore(dataDir: dir.appendingPathComponent("wm-data"))
        store.config.frame.enabled = true
        store.addPhotos([p1, p2])
        check(store.photos.count == 2 && store.hasWatermarkContent, "前提：两张照片、开了相框", "\(store.photos.count)")
        let before = listing(shoot)
        let safe = shoot.appendingPathComponent(ExportFolderGuard.watermarkSubfolder)
        /// 拦下了：没在导、lastError 是拦下的那句、状态栏的按钮对得上它、export = 是不是点导出时拦的。
        func refused(_ export: Bool) -> Bool {
            let said: Bool = store.lastError?.hasPrefix("不能导出到拍摄文件夹") == true
            let button: Bool = store.folderRefusal?.message == store.lastError && store.folderRefusal?.export == export
            return !store.isExporting && said && button
        }
        func finish() { CollageExportSelfTest.spin(60) { !store.isExporting } }

        store.outputDir = shoot
        store.exportAll(shootDir: nil, sessions: [])
        let suggested = store.folderRefusal?.safeFolder
        check(refused(true) && samePath(suggested, safe), "水印：输出目录 = 照片所在的文件夹 → 不导，给「导出到 水印导出/」",
              "\(store.lastError ?? "") → \(suggested?.path ?? "")")
        finish()   // 万一开始导了（守卫失灵），等它写完再看目录
        check(listing(shoot) == before, "　…… 拍摄文件夹一个文件都没多", "\(listing(shoot))")

        let deep = shoot.appendingPathComponent("交付/客户A")
        store.outputDir = deep
        store.exportAll(shootDir: nil, sessions: [])
        check(refused(true) && !fm.fileExists(atPath: deep.path), "水印：里面还没建的「交付/客户A」→ 不导、目录不建",
              store.lastError ?? "")

        let session = dir.appendingPathComponent("批量页那一场")
        try? fm.createDirectory(at: session, withIntermediateDirectories: true)
        let into = session.appendingPathComponent("交付")
        store.outputDir = into
        store.exportAll(shootDir: session, sessions: [])
        let sessionSafe: Bool = samePath(store.folderRefusal?.safeFolder, session.appendingPathComponent("水印导出"))
        check(refused(true) && sessionSafe, "水印：照片不在批量页那一场、输出在那一场里面 → 也拦（shootDir = batchStore.photoDir）",
              store.lastError ?? "")
        check(!fm.fileExists(atPath: into.path), "　…… 那一场里的「交付」没建出来", "")
        store.exportAll(shootDir: nil, sessions: [])
        let started: Bool = store.isExporting && store.folderRefusal == nil
        finish()
        check(started && listing(into).count == 2, "　对照：不传批量页那一场就照常导出", "\(listing(into))")

        // 面板：选到里面不换（原来的目录不动），给「改用 水印导出/」；选外面的照换、提示收掉
        store.outputDir = outside
        store.chooseOutputDir(shoot, shootDir: nil, sessions: [])
        check(store.outputDir == outside && refused(false), "水印面板选到照片所在的文件夹 → 不换，给「改用 水印导出/」",
              store.outputDir?.lastPathComponent ?? "nil")
        let picked = outside.appendingPathComponent("客户A")
        store.chooseOutputDir(picked, shootDir: nil, sessions: [])
        let cleared: Bool = store.folderRefusal == nil && store.lastError == nil
        check(store.outputDir == picked && cleared, "水印面板选外面的 → 照换、提示收掉", store.lastError ?? "")

        // 一键「导出到 水印导出/」：换目录、接着导，原片不动
        store.outputDir = shoot
        store.exportAll(shootDir: nil, sessions: [])
        store.useSafeOutputDir(shootDir: nil, sessions: [])
        let resumed: Bool = store.isExporting && samePath(store.outputDir, safe)
        finish()
        let written = listing(safe)
        let allWatermarked: Bool = written.count == 2 && written.allSatisfy { $0.hasSuffix("_wm.jpg") }
        check(resumed && allWatermarked && store.lastError == nil, "「导出到 水印导出/」→ 换到 <拍摄文件夹>/水印导出/ 接着导",
              "\(written) \(store.lastError ?? "")")
        let untouched: Bool = [p1, p2].map { try? Data(contentsOf: $0) } == originals
        check(untouched && listing(shoot) == before, "　…… 原片逐字节不变、拍摄文件夹这一层没多文件", "")

        // 最近场次里：照常导，只提醒
        let recent = dir.appendingPathComponent("上周那一场")
        let recentOut = recent.appendingPathComponent("交付")
        try? fm.createDirectory(at: recent, withIntermediateDirectories: true)
        store.outputDir = recentOut
        store.exportAll(shootDir: nil, sessions: [entry("上周婚礼", recent)])
        let notice = store.notice ?? ""
        let reminded: Bool = store.isExporting && notice.contains("「上周婚礼」")
        finish()
        check(reminded && listing(recentOut).count == 2, "水印：最近场次的拍摄文件夹里 → 照常导，只提醒", notice)
    }

    // MARK: - 水印页：照片在分析跳过的文件夹里

    /// 照片来自「导出JPG」「水印导出」（分析跳过）：拍摄文件夹按外面那一场算。旁边的「导出JPG/带水印」、「导出JPG」本身照常导；
    /// 那一场的「交付」照样拦、点名那一场（不是「导出JPG」），建议 <那一场>/水印导出/；照片同时来自那一场和它的「水印导出」时
    /// 只拦一次，点「导出到 水印导出/」就真的导进 <那一场>/水印导出/（不是 水印导出/水印导出）。自己一个 ShootB，不动上面的。
    private static func watermarkFromSkipped(_ dir: URL, check: Check) {
        let fm = FileManager.default
        let shoot = dir.appendingPathComponent("ShootB")
        let exported = shoot.appendingPathComponent(ImageLoader.jpegExportSubfolder)
        let marks = shoot.appendingPathComponent(ExportFolderGuard.watermarkSubfolder)
        for folder in [exported, marks] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let e1 = exported.appendingPathComponent("e1.jpg")
        let e2 = exported.appendingPathComponent("e2.jpg")
        let q1 = shoot.appendingPathComponent("q1.jpg")
        let q0 = marks.appendingPathComponent("q0_wm.jpg")
        for (index, url) in [e1, e2, q1, q0].enumerated() {
            let gray = 0.2 + 0.15 * Double(index)
            fm.createFile(atPath: url.path, contents: CollageExportSelfTest.jpeg(width: 96, height: 64, gray: gray))
        }
        let before = listing(shoot)
        let store = WatermarkStore(dataDir: dir.appendingPathComponent("wm-data-skipped"))
        store.config.frame.enabled = true
        store.addPhotos([e1, e2])
        check(store.photos.count == 2 && store.hasWatermarkContent, "前提：「导出JPG」里两张、开了相框", "\(store.photos.count)")
        func finish(_ s: WatermarkStore) { CollageExportSelfTest.spin(60) { !s.isExporting } }
        func marked(_ folder: URL, _ names: [String]) -> Bool {
            let have = Set(listing(folder))
            return names.allSatisfy { have.contains($0) }
        }

        let beside = exported.appendingPathComponent("带水印")
        store.outputDir = beside
        store.exportAll(shootDir: shoot, sessions: [])
        let started1: Bool = store.isExporting && store.folderRefusal == nil
        finish(store)
        let wrote1: Bool = listing(beside) == ["e1_wm.jpg", "e2_wm.jpg"]
        check(started1 && wrote1, "水印：照片在「导出JPG」、批量页开着那一场、输出「导出JPG/带水印」→ 照常导",
              "\(store.lastError ?? "") \(listing(beside))")

        store.outputDir = exported
        store.exportAll(shootDir: nil, sessions: [])
        let started2: Bool = store.isExporting && store.folderRefusal == nil
        finish(store)
        let wrote2: Bool = marked(exported, ["e1_wm.jpg", "e2_wm.jpg"])
        check(started2 && wrote2, "水印：批量页没开、输出就是「导出JPG」本身（{原名}_wm）→ 照常导",
              "\(store.lastError ?? "") \(listing(exported))")

        let deliver = shoot.appendingPathComponent("交付")
        store.outputDir = deliver
        store.exportAll(shootDir: nil, sessions: [])
        let message = store.lastError ?? ""
        let named: Bool = message.hasPrefix("不能导出到拍摄文件夹「ShootB」") && !message.contains("「导出JPG」")
        let safeIsShoot: Bool = samePath(store.folderRefusal?.safeFolder, marks)
        check(!store.isExporting && named && safeIsShoot, "水印：照片在「导出JPG」、输出那一场的「交付」→ 拦，点名「ShootB」、建议 ShootB/水印导出",
              "\(message) → \(store.folderRefusal?.safeFolder.path ?? "")")
        finish(store)
        check(!fm.fileExists(atPath: deliver.path), "　……「交付」没建出来", "")

        // 照片同时来自那一场和它的「水印导出」：只拦一次，一键改用就导进 ShootB/水印导出/
        let mixed = WatermarkStore(dataDir: dir.appendingPathComponent("wm-data-mixed"))
        mixed.config.frame.enabled = true
        mixed.addPhotos([q1, q0])
        mixed.outputDir = deliver
        mixed.exportAll(shootDir: nil, sessions: [])
        let once: Bool = !mixed.isExporting && samePath(mixed.folderRefusal?.safeFolder, marks)
        check(once && mixed.lastError?.hasPrefix("不能导出到拍摄文件夹「ShootB」") == true,
              "水印：照片来自那一场和它的「水印导出」、输出「交付」→ 拦一次，建议 ShootB/水印导出", mixed.lastError ?? "")
        mixed.useSafeOutputDir(shootDir: nil, sessions: [])
        let resumed: Bool = mixed.isExporting && samePath(mixed.outputDir, marks) && mixed.folderRefusal == nil
        finish(mixed)
        let landed: Bool = marked(marks, ["q1_wm.jpg", "q0_wm_wm.jpg"])
        let nested: Bool = fm.fileExists(atPath: marks.appendingPathComponent(ExportFolderGuard.watermarkSubfolder).path)
        check(resumed && landed && !nested && mixed.lastError == nil, "　……「导出到 水印导出/」点一次就导进 ShootB/水印导出/（没有 水印导出/水印导出）",
              "\(listing(marks)) \(mixed.lastError ?? "")")
        check(listing(shoot) == before, "　…… ShootB 这一层一个文件都没多", "\(listing(shoot))")
    }

    // MARK: - 拼图

    private static func collage(_ dir: URL, shoot: URL, outside: URL, check: Check) {
        let fm = FileManager.default
        let store = CollageStore(dataDir: dir.appendingPathComponent("collage-data"))
        let sessionDir = dir.appendingPathComponent("collage-session")
        try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        store.attach(sessionDir: sessionDir, photoDir: shoot)
        let project = CollageExportSelfTest.albumProject(pages: 1)
        var options = CollageStore.ExportOptions()
        options.pdf = false
        let before = listing(shoot)
        func export(to folder: URL?, name: String) -> CollageStore.ExportOutcome? {
            options.outputPath = folder?.path
            store.exportOptions = options
            return CollageExportSelfTest.runExport(store, project: project, options: options, name: name)
        }

        let o1 = export(to: shoot, name: "拦")
        let why1 = o1?.failure ?? ""
        let said1: Bool = why1.hasPrefix("不能导出到拍摄文件夹「\(shoot.lastPathComponent)」里面") && why1.contains("用默认")
        let nothing1: Bool = o1?.files.isEmpty == true && listing(shoot) == before
        check(said1 && nothing1 && store.lastError == why1, "拼图：输出目录 = 拍摄文件夹 → 拒绝，lastError 说点「用默认」，一个文件不写",
              why1)
        var mcpCode = ""
        var mcpExecuted: Bool?
        if case .failure(let code, _, let data)? = LiveHandlers.exportFolderRefused(store) {
            mcpCode = code
            mcpExecuted = data?["executed"] as? Bool
        }
        check(mcpCode == "invalid_state" && mcpExecuted == false, "　MCP collage_export 入口回 invalid_state（executed:false）", mcpCode)

        let deep = shoot.appendingPathComponent("交付/拼图")
        let o2 = export(to: deep, name: "拦")
        let said2: Bool = o2?.failure?.hasPrefix("不能导出到拍摄文件夹") == true
        check(said2 && !fm.fileExists(atPath: deep.path), "拼图：里面还没建的「交付/拼图」→ 拒绝、目录不建", o2?.failure ?? "")

        let o3 = export(to: nil, name: "默认")
        let defaultFolder = shoot.appendingPathComponent(ImageLoader.collageExportSubfolder)
        let files3: [String] = o3?.files ?? []
        let wrote3: Bool = o3?.failure == nil && !files3.isEmpty && listing(defaultFolder) == files3.sorted()
        var mcpAllows = true
        if case .some = LiveHandlers.exportFolderRefused(store) { mcpAllows = false }
        check(wrote3 && samePath(o3?.folder, defaultFolder) && mcpAllows, "拼图：默认的「拼图导出/」照常写出（MCP 入口也放行）",
              "\(files3) \(o3?.failure ?? "")")

        options.outputPath = nil
        store.exportOptions = options
        let refusedPick: Bool = !store.chooseOutputFolder(shoot.appendingPathComponent("交付"))
        let pickSaid: Bool = store.lastError?.hasPrefix("不能导出到拍摄文件夹") == true
        check(refusedPick && store.exportOptions.outputPath == nil && pickSaid, "拼图面板选到拍摄文件夹里的「交付」→ 不换（还是默认）",
              store.lastError ?? "")
        let pickedOutside: Bool = store.chooseOutputFolder(outside)
        check(pickedOutside && store.exportOptions.outputPath == outside.path && store.lastError == nil,
              "拼图面板选外面的 → 照换、拦下的那句收掉", store.lastError ?? "")
    }
}
