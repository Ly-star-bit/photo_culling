import Foundation

/// 交付对照（DeliveryLedger.swift）的进程内自检，跑在 --delivery-selftest 里（CI 的「自检」步骤；端到端的命令行出口在
/// Scripts/delivery_ledger_regression.py，那个脚本不在 CI 里）：
/// - 水印页比对（DeliveryLedger.matchByFile）：同名的别处照片不认，链接、大小写不同照认，只 stat 名字对得上的场次照片。
/// - 界面那条路的接线：用和 app 同一个 AppModel.make 建 store，水印页真导出一次，对照要记进批量页这一场的 exports.json
///   （AppModel.make 里 `watermark.recordDeliveries(into: batch)` 那一行丢了，这里就红；无头 --watermark-batch 自己接，测不到它）；
///   exports.json 解不开：挪成 exports.corrupt-<时间>.json、批量页提醒；读不出来：不写、不挪，水印页自己的状态栏报出来。
/// - 导入客户选择（ClientReply.resolve）：原片本来就叫 001.JPG、交付名 001.jpg 是另一张；交付名 1-2.jpg 和确认表的
///   范围「1-2」指的不是同一批 —— 都列进没认出、不猜。
/// 临时文件都在 `dir` 下（场次 JSON 在数据目录的 sessions/ 里），调用方跑完删掉。
@MainActor
enum DeliveryLedgerSelfTest {
    typealias Check = (Bool, String, String) -> Void

    static func run(_ dir: URL, check: Check) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        matchCases(dir.appendingPathComponent("match"), check: check)
        wiring(dir.appendingPathComponent("wiring"), check: check)
        replyCases(dir.appendingPathComponent("reply"), check: check)
    }

    // MARK: - 导入客户选择：数字样的名字有好几种认法时不猜

    private static func replyCases(_ dir: URL, check: Check) {
        // 原片本来就按序号起名（001.JPG…），{序号:3} 导出的 001.jpg 却是 017；{序号} 不补零再导一次另存的 1-2.jpg 是 023。
        let names = ["001", "002", "017", "023"]
        let store = FileSafetySelfTest.makeShoot(dir, names.map { FileSafetySelfTest.Fake(id: $0, raw: $0 + ".JPG") })
        check(store.items.count == names.count, "前提：造的这一场 4 张", "\(store.items.count)")
        func file(_ name: String, _ id: String) -> DeliveryRecord.File {
            DeliveryRecord.File(file: name, id: id, original: dir.appendingPathComponent(id + ".JPG").path)
        }
        let record = DeliveryRecord(kind: .jpeg, folder: dir.appendingPathComponent("out"),
                                    files: [file("001.jpg", "017"), file("002.jpg", "002"), file("1-2.jpg", "023"),
                                            file("5-2.jpg", "017")])
        func resolve(_ text: String, sheets: [ProofSheet]) -> (ids: [String], unknown: [String]) {
            let r = ClientReply.resolve(text, items: store.items, sheets: sheets, deliveries: [record])
            return (r.ids, r.unknown)
        }
        let plain = resolve("001\n001.jpg\n002\n017\n1-2\n", sheets: [])
        check(plain.unknown == ["001（交付文件名还是原片名？）", "001.jpg（交付文件名还是原片名？）"],
              "原片 001.JPG 和交付名 001.jpg（是 017）各指一张：「001」「001.jpg」都不猜", "\(plain.unknown)")
        check(plain.ids == ["002", "017", "023"],
              "交付名和原片名是同一张的（002）照认；没有确认表时「1-2」按交付名 1-2.jpg 认", "\(plain.ids)")
        let sheet = ProofSheet(id: "selftest-ledger", date: Date(), scope: "选中的照片", ids: ["001", "002", "017"])
        let ranged = resolve("1-2\n2-3\n1-2.jpg\n5-2\n", sheets: [sheet])
        check(ranged.unknown == ["1-2（交付文件名还是编号？）"],
              "有确认表：「1-2」交付名是 023、表上第 1 到 2 张是 001 002 → 不猜", "\(ranged.unknown)")
        check(ranged.ids == ["002", "017", "023"],
              "「2-3」照旧按表认，「1-2.jpg」带扩展名按交付名，倒着写的「5-2」不是范围、按交付名认", "\(ranged.ids)")
    }

    // MARK: - 水印页：原图按文件本身对回这一场

    private static func matchCases(_ dir: URL, check: Check) {
        let fm = FileManager.default
        let shoot = dir.appendingPathComponent("shoot")
        let other = dir.appendingPathComponent("other")
        let links = dir.appendingPathComponent("links")
        for folder in [shoot, other, links] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        func file(_ folder: URL, _ name: String, _ text: String) -> URL {
            let url = folder.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data(text.utf8))
            return url
        }
        let raw1 = file(shoot, "DSCF0001.RAF", "raw 1")
        let jpg1 = file(shoot, "DSCF0001.JPG", "jpg 1")
        let jpg2 = file(shoot, "DSCF0002.JPG", "jpg 2")
        let otherDay = file(other, "DSCF0002.JPG", "别的日子同名的另一张")
        let link = links.appendingPathComponent("DSCF0002.JPG")
        try? fm.createSymbolicLink(at: link, withDestinationURL: jpg2)
        let renamed = links.appendingPathComponent("renamed.jpg")
        try? fm.linkItem(at: jpg2, to: renamed)
        // 场次里另有 500 张名字不沾边的（路径不存在也无所谓）：一张都不该被 stat。
        let unrelated = (0..<500).map { i -> DeliveryLedger.SessionPhoto in
            let path = shoot.appendingPathComponent(String(format: "UNRELATED_%04d.JPG", i)).path
            return DeliveryLedger.SessionPhoto(id: "u\(i)", rawPath: path, decodePath: path)
        }
        let photos = [DeliveryLedger.SessionPhoto(id: "p1", rawPath: raw1.path, decodePath: jpg1.path),
                      DeliveryLedger.SessionPhoto(id: "p2", rawPath: jpg2.path, decodePath: jpg2.path)] + unrelated
        var statted: [String] = []
        func counting(_ path: String) -> String? {
            statted.append(path)
            return DeliveryLedger.fileID(path)
        }
        let sources: [(file: String, source: String)] = [
            ("DSCF0001_wm.jpg", jpg1.path), ("DSCF0002_wm.jpg", otherDay.path), ("DSCF0002_wm-2.jpg", link.path),
            ("renamed_wm.jpg", renamed.path),
        ]
        let got = DeliveryLedger.matchByFile(sources, photos: photos, statFile: counting)
        let pairs = got.map { "\($0.file)→\($0.id)" }
        check(pairs == ["DSCF0001_wm.jpg→p1", "DSCF0002_wm-2.jpg→p2"],
              "水印比对：RAW+JPG 那一对按 JPG 认回、指向原片的链接认回；别处同名的、改了名的硬链接不认", "\(pairs)")
        check(got.first?.original == raw1.path, "　…… original 记 RAW", got.first?.original ?? "-")
        let touchedUnrelated = statted.filter { $0.contains("UNRELATED_") }.count
        check(touchedUnrelated == 0 && Set(statted).count <= 6,
              "只 stat 写出去的原图和名字对得上的场次照片：500 张不沾边的一张没碰（场次在网络盘上时不卡）",
              "stat \(statted.count) 次，其中不沾边的 \(touchedUnrelated)")
        let upper = shoot.appendingPathComponent("dscf0001.jpg")
        if fm.fileExists(atPath: upper.path) {
            let cased = DeliveryLedger.matchByFile([("x_wm.jpg", upper.path)], photos: photos).map(\.id)
            check(cased == ["p1"], "大小写不同的路径（不分大小写的盘）照认", "\(cased)")
        }
        let none = DeliveryLedger.matchByFile([("y_wm.jpg", shoot.appendingPathComponent("gone.jpg").path)],
                                              photos: photos, statFile: counting)
        check(none.isEmpty, "原图不在了：不认", "\(none.map(\.id))")
    }

    // MARK: - AppModel.make 的接线：水印页导出 → 批量页这一场的交付对照

    private static func wiring(_ dir: URL, check: Check) {
        let fm = FileManager.default
        let shoot = dir.appendingPathComponent("shoot")
        FileSafetySelfTest.writeShoot(shoot, [FileSafetySelfTest.Fake(id: "w1", raw: "w1.JPG", jpeg: true),
                                              FileSafetySelfTest.Fake(id: "w2", raw: "w2.JPG", jpeg: true)])
        let other = dir.appendingPathComponent("other")
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        let stranger = other.appendingPathComponent("w1.JPG")
        fm.createFile(atPath: stranger.path, contents: FileSafetySelfTest.tinyJPEG())
        // 和 app 同一套接线（AppModel.make），不开实时桥。
        let model = AppModel.make(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir),
                                  bridge: .none)
        let batch = model.batch
        let watermark = model.watermark
        batch.switchSession(to: shoot)
        check(batch.items.count == 2, "前提：批量页打开了造的这一场", "\(batch.items.count) 张")
        watermark.config.frame.enabled = true
        watermark.addPhotos([shoot.appendingPathComponent("w1.JPG"), stranger])
        let out = dir.appendingPathComponent("out")
        /// 水印页「批量导出」一次，等它连交付对照一起收完尾。
        func export() -> Bool {
            watermark.outputDir = out
            watermark.exportAll(shootDir: batch.photoDir, sessions: [])
            let started = watermark.isExporting
            CollageExportSelfTest.spin(60) { !watermark.isExporting }
            return started && !watermark.isExporting
        }
        let ledger = batch.deliveryLedgerPath

        check(export(), "水印页批量导出 2 张（这一场的 w1、别处同名的 w1）", watermark.lastError ?? "")
        let record = batch.deliveryRecords.last
        let pairs = record?.files.map { "\($0.file)→\($0.id)" } ?? []
        check(record?.kind == "watermark" && pairs == ["w1_wm.jpg→w1"],
              "AppModel.make 接上了：水印页导出记进批量页这一场的 exports.json，别处同名的那张不记", "\(pairs)")
        let reported: Bool = record.map { watermark.lastDelivery == .recorded($0) } ?? false
        check(reported && watermark.lastError == nil, "　…… 水印页拿到「记下了」，没有报错", watermark.lastError ?? "")

        try? Data("not json".utf8).write(to: ledger)
        check(export(), "exports.json 写坏了再导一次", watermark.lastError ?? "")
        let sessionDir = ledger.deletingLastPathComponent()
        let moved = ((try? fm.contentsOfDirectory(atPath: sessionDir.path)) ?? []).filter { $0.hasPrefix("exports.corrupt-") }
        let movedText = moved.first.flatMap {
            try? String(contentsOf: sessionDir.appendingPathComponent($0), encoding: .utf8)
        }
        let noticed: Bool = batch.dataNotice?.contains(moved.first ?? "?") == true
        check(moved.count == 1 && movedText == "not json" && batch.deliveryRecords.count == 1 && noticed,
              "解不开：原件挪成 exports.corrupt-<时间>.json、这次照记、批量页提醒一句", "\(moved) · \(batch.dataNotice ?? "-")")

        guard geteuid() != 0 else {
            print("SKIP 读不出来的 exports.json（root 跑时 chmod 挡不住读）")
            return
        }
        let before = try? Data(contentsOf: ledger)
        let elsewhere = dir.appendingPathComponent("elsewhere.json")
        try? Data("[]".utf8).write(to: elsewhere)
        chmod(ledger.path, 0)
        let exported = export()
        _ = DeliveryLedger.load(elsewhere)   // 缓存换成别的文件，下一次读这一场的才真去读盘
        let whileLocked = batch.deliveryRecords.count
        chmod(ledger.path, 0o644)
        let afterFix = batch.deliveryRecords.count
        check(whileLocked == 0 && afterFix == 1, "读不出来时导入框当空的；改回权限马上读得到（读失败的空结果不进缓存）",
              "\(whileLocked) → \(afterFix)")
        let after = try? Data(contentsOf: ledger)
        var failed = false
        if case .failed? = watermark.lastDelivery { failed = true }
        let said: Bool = watermark.lastError?.contains("交付对照") == true && watermark.lastError?.contains("读不出来") == true
        check(exported && failed && said && before != nil && after == before,
              "读不出来（chmod 000）：不写、不挪，水印页自己的状态栏说没记进去", watermark.lastError ?? "-")
        withExtendedLifetime(model) {}
    }
}
