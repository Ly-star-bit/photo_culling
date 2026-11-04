import Foundation

/// 交付对照（DeliveryLedger.swift）的进程内自检，跑在 --delivery-selftest 里（CI 的「自检」步骤；端到端的命令行出口在
/// Scripts/delivery_ledger_regression.py，那个脚本不在 CI 里）：
/// - 水印页比对（DeliveryLedger.matchByFile）：同名的别处照片不认，链接、大小写不同照认，只 stat 名字对得上的场次照片。
/// 临时文件都在 `dir` 下，调用方跑完删掉。
@MainActor
enum DeliveryLedgerSelfTest {
    typealias Check = (Bool, String, String) -> Void

    static func run(_ dir: URL, check: Check) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        matchCases(dir.appendingPathComponent("match"), check: check)
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
}
