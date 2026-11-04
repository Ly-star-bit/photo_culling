import Foundation
import ImageIO

/// 文件安全自检（2026-11 全项目审查 S08 / S09 / S10 / S17）：LABELGUI_DATA_DIR=<临时目录> LabelGUI --files-selftest
/// 在数据目录里造几场假的拍摄（小文件 + 手写的 manifest / layer1，不用跑分析），逐条断言、打 PASS / FAIL：
///   - XMP：「XMP 待更新」只写改了的那几张，别的 sidecar 一个不换（LR 里改过的星级不被盖回去）；全部重写时内容没变的不重写。
///   - 同名不同格式共用一个 .xmp：整组不写、单独点名、不记成已同步；移废片时共用的 .xmp 全移走才带走。
///   - DNG / JPG 写完提醒 LR 不读旁边的 .xmp。
/// 只写数据目录；退出前删掉造出来的照片文件夹。
@MainActor
enum FileSafetySelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            print("PASS " + what)
        } else {
            failures += 1
            let extra = detail()
            print("FAIL " + what + (extra.isEmpty ? "" : "（" + extra + "）"))
        }
    }

    static func run() -> Never {
        guard !(ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? "").isEmpty else {
            print("--files-selftest 会在数据目录里造假的拍摄、写 .xmp、复制文件：先设 LABELGUI_DATA_DIR=<临时目录>")
            exit(2)
        }
        let root = appDataDir.appendingPathComponent("files-selftest-" + String(UUID().uuidString.prefix(8)))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        xmpIncremental(root.appendingPathComponent("xmp"))
        sharedSidecar(root.appendingPathComponent("shared"))
        lightroomFormats(root.appendingPathComponent("lr"))
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "文件安全自检：全部通过" : "文件安全自检：\(failures) 条失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 造一场假的拍摄

    /// 一张假照片：`raw` / `decode` 是相对拍摄文件夹的路径（decode 不给 = 单文件）。
    struct Fake {
        let id: String
        let raw: String
        var decode: String?
        var iso = 400
        /// 原图的内容（不给 = 按 id 编一段）。
        var content: Data?
    }

    /// 照片文件写进 `dir`，manifest / layer1 写进这一场的场次目录，返回打开了这一场的 store。
    /// 每张隔一分钟、各自一组：不成连拍，判决只看下面手动设的。
    static func makeShoot(_ dir: URL, _ photos: [Fake]) -> BatchStore {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        var layer1: [[String: Any]] = []
        for (i, photo) in photos.enumerated() {
            let raw = dir.appendingPathComponent(photo.raw)
            try? fm.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = photo.content ?? Data(("RAW " + photo.id + String(repeating: ".", count: 64 + i)).utf8)
            try? content.write(to: raw)
            var decodePath = raw.path
            if let decode = photo.decode {
                let url = dir.appendingPathComponent(decode)
                try? Data(("JPG " + photo.id).utf8).write(to: url)
                decodePath = url.path
            }
            let minute = String(format: "%02d", i % 60)
            manifest.append([
                "id": photo.id, "raw_path": raw.path, "decode_path": decodePath,
                "preview_path": "previews/\(photo.id).jpg", "capture_time": "2026-03-21T10:\(minute):00",
                "camera": "X-T50", "body_serial": "", "exif": ["iso": photo.iso],
            ])
            layer1.append([
                "id": photo.id, "sharpness": 90.0, "burst_group": i + 1, "face_found": false, "face_count": 0,
                "highlight_clip_pct": 0.0, "shadow_clip_pct": 0.0, "frame_luma": 128, "frame_luma_p99": 220,
            ])
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

    static func wait(_ store: BatchStore, timeout: Double = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func xmp(_ dir: URL, _ stem: String) -> URL { dir.appendingPathComponent(stem + ".xmp") }

    /// 文件的 inode：原子写是「写临时文件再改名」，重写过就换了一个。
    static func inode(_ url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// 这一场每张照片旁边 .xmp 的 inode（没有 sidecar 的不在里面）。
    static func sidecarInodes(_ items: [BatchItem]) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for item in items {
            let url = URL(fileURLWithPath: item.rawPath).deletingPathExtension().appendingPathExtension("xmp")
            if let n = inode(url) { out[url.path] = n }
        }
        return out
    }

    /// ImageIO 读出来的 xmp:Rating（自己的模板和合并过的写法不一样，按值比）。
    static func rating(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let meta = CGImageMetadataCreateFromXMPData(data as CFData),
              let tag = CGImageMetadataCopyTagWithPath(meta, nil, "xmp:Rating" as CFString) else { return nil }
        return CGImageMetadataTagCopyValue(tag) as? String
    }

    /// Lightroom 写的那种 sidecar：带调色参数，xmptk 是 Adobe 的。
    static func lightroomSidecar(rating: Int) -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           xmp:Rating="\(rating)"
           crs:Exposure2012="+0.35"
           crs:Temperature="5200">
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }

    // MARK: - S17 只写改了的

    private static func xmpIncremental(_ dir: URL) {
        print("== XMP：只写改了的 / 全部重写不白改文件")
        let store = makeShoot(dir, ["p1", "p2", "p3", "p4"].map { Fake(id: $0, raw: $0 + ".ARW") })
        store.setOverride("p1", .pick)
        store.setOverride("p2", .usable)
        store.setOverride("p3", .usable)
        store.setOverride("p4", .reject)
        // p3 旁边原来就有 Lightroom 的 sidecar（带调色）：第一次写只合并星级。
        try? lightroomSidecar(rating: 2).write(to: xmp(dir, "p3"))
        store.exportXMP(.all)
        wait(store)
        let all = ["p1", "p2", "p3", "p4"].map { xmp(dir, $0) }
        check(all.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "第一次写：4 张都有 .xmp", store.progressText)
        let p3Merged = (try? String(contentsOf: xmp(dir, "p3"), encoding: .utf8)) ?? ""
        check(p3Merged.contains("Exposure2012") && rating(xmp(dir, "p3")) == "3", "LR 的 sidecar 只合并了星级、调色还在")
        check(store.xmpStaleCount == 0, "写完 XMP 过期 0 张", "\(store.xmpStaleCount)")

        // 之后在 LR 里把 p3 改成 1 星（LR 重写了它的 sidecar）；这边只改了 p1。
        let lrEdited = lightroomSidecar(rating: 1)
        try? lrEdited.write(to: xmp(dir, "p3"))
        store.setOverride("p1", .usable)
        check(store.xmpStaleCount == 1, "改 1 张：XMP 过期 1 张", "\(store.xmpStaleCount)")
        let before = sidecarInodes(store.items)
        store.exportXMP(.changed)
        wait(store)
        let after = sidecarInodes(store.items)
        let touched = after.filter { before[$0.key] != $0.value }.map { URL(fileURLWithPath: $0.key).lastPathComponent }
        check(touched == ["p1.xmp"], "只写改了的：只换了 p1.xmp", touched.sorted().joined(separator: ","))
        check(rating(xmp(dir, "p1")) == "3", "p1.xmp 是新的星级（可用 3 星）", rating(xmp(dir, "p1")) ?? "-")
        check((try? Data(contentsOf: xmp(dir, "p3"))) == lrEdited, "LR 里改的 p3 一个字节没动（没被盖回 3 星）")
        check(store.progressText.contains("其余 3 张没动"), "完成提示按实际张数", store.progressText)
        check(store.xmpStaleCount == 0, "写完 XMP 过期 0 张", "\(store.xmpStaleCount)")

        // 菜单「全部重写 XMP」：自己的 sidecar 内容没变的不重写（修改时间不变），别人的照样合并（这是用户点名要的全量）。
        let before2 = sidecarInodes(store.items)
        store.exportXMP(.all)
        wait(store)
        let after2 = sidecarInodes(store.items)
        let own = ["p1", "p2", "p4"].map { xmp(dir, $0).path }
        check(own.allSatisfy { before2[$0] != nil && before2[$0] == after2[$0] }, "全部重写：自己的 3 个内容没变，没重写")
        check(rating(xmp(dir, "p3")) == "3", "全部重写：别人的 p3 按现在的判决合并回 3 星")
        check(store.progressText.contains("3 个本来就对"), "全部重写的提示说了几个没动", store.progressText)
        check(!store.progressText.contains("Lightroom Classic"), "全是专有 RAW：不提醒 LR 读不了", store.progressText)
    }

    // MARK: - S09-a 同名共用一个 .xmp

    private static func sharedSidecar(_ dir: URL) {
        print("== 同名不同格式的照片共用一个 .xmp")
        // s1.HEIC + s1.JPG 各自成片；C2.RAF 和 c2.dng 只差大小写（APFS 上 C2.xmp 和 c2.xmp 是同一个文件）。
        let store = makeShoot(dir, [
            Fake(id: "s1", raw: "s1.HEIC"), Fake(id: "s1_jpg", raw: "s1.JPG"), Fake(id: "t1", raw: "t1.ARW"),
            Fake(id: "C2", raw: "C2.RAF"), Fake(id: "c2_dng", raw: "c2.dng"),
        ])
        store.setOverride("s1", .reject)
        store.setOverride("s1_jpg", .pick)
        store.setOverride("t1", .usable)
        store.setOverride("C2", .pick)
        store.setOverride("c2_dng", .usable)
        store.exportXMP(.all)
        wait(store)
        let fm = FileManager.default
        check(fm.fileExists(atPath: xmp(dir, "t1").path), "不共用的 t1 照常写了")
        check(!fm.fileExists(atPath: xmp(dir, "s1").path), "s1.HEIC + s1.JPG 共用的 s1.xmp 没写")
        check(!fm.fileExists(atPath: xmp(dir, "c2").path) && !fm.fileExists(atPath: xmp(dir, "C2").path),
              "只差大小写的 C2.RAF + c2.dng 也算共用，没写")
        let warning = store.lastError ?? ""
        check(warning.contains("同名冲突 4 张") && warning.contains("s1.HEIC") && warning.contains("s1.JPG")
              && warning.contains("C2.RAF") && warning.contains("c2.dng"), "单独一条「同名冲突」、点了名", warning)
        check(store.xmpStaleCount == 4 && store.xmpSharedSidecarCount == 4,
              "跳过的不记成已同步：还算待更新 4 张、其中同名冲突 4 张", "\(store.xmpStaleCount)/\(store.xmpSharedSidecarCount)")
        store.exportXMP(.changed)
        wait(store)
        check(!fm.fileExists(atPath: xmp(dir, "s1").path) && (store.lastError ?? "").contains("同名冲突 4 张"),
              "再点「XMP 待更新」：照样不写、照样点名", store.lastError ?? "-")

        // 移废片：共用的 .xmp 只在用它的照片全都移走时才带走（由排在最后的那张、前面的移成了再带）。
        let all = store.items.map { ($0.id, $0.rawPath) }
        func photo(_ id: String) -> SidecarSharing.Photo { all.first { $0.0 == id }! }
        let alone = SidecarSharing.trashSidecars(moving: [photo("s1")], all: all)
        check(alone.carry.isEmpty && alone.kept.map(\.lastPathComponent) == ["s1.xmp"],
              "只移 s1.HEIC：s1.JPG 还在用，s1.xmp 留着")
        let both = SidecarSharing.trashSidecars(moving: [photo("s1"), photo("s1_jpg")], all: all)
        check(both.carry["s1"] == nil && both.carry["s1_jpg"]?.after == ["s1"] && both.kept.isEmpty,
              "两张都移：最后那张等前一张移成了再带走 s1.xmp")
        let single = SidecarSharing.trashSidecars(moving: [photo("t1")], all: all)
        check(single.carry["t1"]?.xmp.lastPathComponent == "t1.xmp" && single.carry["t1"]?.after == [],
              "不共用的照常带走自己的 .xmp")
    }

    // MARK: - S09-b LR 不读 DNG / JPG 旁边的 .xmp

    private static func lightroomFormats(_ dir: URL) {
        print("== DNG / JPG 场次的 LR 提醒")
        let store = makeShoot(dir, [
            Fake(id: "d1", raw: "d1.DNG"), Fake(id: "d2", raw: "d2.dng"), Fake(id: "j1", raw: "j1.JPG"),
            Fake(id: "r1", raw: "r1.ARW"),
        ])
        store.exportXMP(.all)
        wait(store)
        let text = store.progressText
        check(text.contains("注意 3 张是 DNG/JPG") && text.contains("Lightroom Classic 不读") && text.contains("复制文件名"),
              "点名 DNG/JPG、引导复制文件名去 LR 筛", text)
        check(FileManager.default.fileExists(atPath: xmp(dir, "d1").path), "DNG 旁边照样写了 .xmp（C1 能读）")
    }
}

/// --export-xmp … --then id=判决 --incremental 的那一步：点「XMP 待更新」（只写改了的），数动了几个 sidecar。
@MainActor
enum XMPIncrementalCheck {
    static func run(_ store: BatchStore) -> Int {
        let before = FileSafetySelfTest.sidecarInodes(store.items)
        store.exportXMP(.changed)
        FileSafetySelfTest.wait(store)
        print(store.progressText)
        if let error = store.lastError { print(error) }
        let after = FileSafetySelfTest.sidecarInodes(store.items)
        let touched = after.filter { before[$0.key] != $0.value }.count
        print("只写改了的：动了 \(touched) 个 sidecar（期望 1）· XMP 过期 \(store.xmpStaleCount) 张")
        return touched
    }
}
