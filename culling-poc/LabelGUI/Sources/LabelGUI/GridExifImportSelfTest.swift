import Foundation

/// `--ux-selftest` 里的几组纯函数用例：EXIF 拍摄参数（快门 0 / 极小正数不崩）、网格多选（数字键、剪选中）、
/// 水印页导入的 RAW+JPG 配对。
/// 每条打 PASS / FAIL 一行，返回失败条数（main.swift 加到总数上）。
enum GridExifImportSelfTest {
    final class Tally {
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if !ok { failed += 1 }
            let head: String = ok ? "PASS " : "FAIL "
            let tail: String = ok ? "" : "（" + detail() + "）"
            print(head + name + tail)
        }
    }

    static func run() -> Int {
        let tally = Tally()
        exifCases(tally)
        gridSelectionCases(tally)
        watermarkCases(tally)
        return tally.failed
    }

    // MARK: - EXIF（S18）

    private static func exifCases(_ t: Tally) {
        func summary(_ shutter: Double?, aperture: Double? = 2.8, focal: Int? = 85) -> String {
            ExifMeta(shutterSec: shutter, aperture: aperture, iso: 800, focal35: focal, lens: nil).summary
        }
        let rest = "f/2.8 · ISO 800 · 85mm"
        // (说明, 快门秒数, 期望的 summary)
        let rows: [(String, Double?, String)] = [
            ("快门 0（EXIF 写 0/1）→ 跳过快门，不崩", 0, rest),
            ("快门是最小的非规格化小数 5e-324 → 1/s 溢出成 inf，跳过", 5e-324, rest),
            ("快门 1e-300 → 1/s 有限但远超 Int.max，跳过", 1e-300, rest),
            ("快门 1e-19 → 1/s ≈ 1e19 > Int.max，跳过", 1e-19, rest),
            ("快门 NaN → 跳过", Double.nan, rest),
            ("快门 +inf → 跳过（以前印成 infs）", Double.infinity, rest),
            ("快门负数 → 跳过（以前印成 1/-250）", -0.004, rest),
            ("快门 1/250 照常", 0.004, "1/250 · " + rest),
            ("快门 1/2 照常", 0.5, "1/2 · " + rest),
            ("快门 2s 照常", 2, "2s · " + rest),
            ("没有快门照常", nil, rest),
        ]
        for (name, shutter, want) in rows {
            let got = summary(shutter)
            t.check(got == want, "EXIF " + name, "得到 \(got)，期望 \(want)")
        }
        let zeroes = summary(0.004, aperture: 0, focal: 0)
        t.check(zeroes == "1/250 · ISO 800", "EXIF 光圈 0、焦距 0（老 manifest）→ 不印 f/0.0、0mm", "得到 \(zeroes)")

        // ImageLoader 读 EXIF 的清洗：只收有限正数；焦距回退不 trap。
        let positives: [(Double?, Double?)] = [
            (0, nil), (-1, nil), (.nan, nil), (.infinity, nil), (5e-324, 5e-324), (0.004, 0.004), (nil, nil),
        ]
        for (input, want) in positives {
            let got = ImageLoader.positiveFinite(input)
            let label: String = input.map { "\($0)" } ?? "nil"
            t.check(got == want, "EXIF 读入只收有限正数 positiveFinite(\(label))", "得到 \(String(describing: got))")
        }
        let focals: [(Double?, Int?)] = [
            (0, nil), (0.4, nil), (-35, nil), (.nan, nil), (.infinity, nil), (1e300, nil), (35.9, 35), (85, 85), (nil, nil),
        ]
        for (input, want) in focals {
            let got = ImageLoader.focalMillimeters(input)
            let label: String = input.map { "\($0)" } ?? "nil"
            t.check(got == want, "EXIF 焦距回退 focalMillimeters(\(label))（以前 Int(1e300) / Int(nan) 会崩）",
                    "得到 \(String(describing: got))")
        }
        let intOK: Bool = ImageLoader.positiveInt(0) == nil && ImageLoader.positiveInt(50) == 50
        t.check(intOK, "EXIF 35mm 等效焦距 0 = 未知，当没有（回退到实际焦距）")
    }

    // MARK: - 网格多选（S21）

    private static func gridSelectionCases(_ t: Tally) {
        typealias Targets = GridSelectionRules.DigitTargets
        // (说明, 选中, 网格里看得见的（顺序）, 焦点, 期望)
        let rows: [(String, Set<String>, [String], String?, Targets)] = [
            ("没有选中：改焦点那张，改完 keepPlace", [], ["a", "b", "c"], "b",
             Targets(ids: ["b"], fromSelection: false, clearSelection: false)),
            ("⌘点了三张：按网格顺序改这三张，改完清掉选中", ["c", "a", "d"], ["a", "b", "c", "d"], "b",
             Targets(ids: ["a", "c", "d"], fromSelection: true, clearSelection: true)),
            ("选中里有两张被筛掉了：只改还看得见的那张", ["a", "x", "y"], ["a", "b"], "b",
             Targets(ids: ["a"], fromSelection: true, clearSelection: true)),
            ("选中的全被筛掉（看不见）：改焦点那张，旧选中也清掉", ["x", "y"], ["a", "b"], "b",
             Targets(ids: ["b"], fromSelection: false, clearSelection: true)),
            ("选中的全看不见、也没有焦点：什么都不改，旧选中清掉", ["x"], ["a"], nil,
             Targets(ids: [], fromSelection: false, clearSelection: true)),
            ("没有选中也没有焦点：什么都不改", [], ["a"], nil,
             Targets(ids: [], fromSelection: false, clearSelection: false)),
        ]
        for (name, selected, visible, focused, want) in rows {
            let got = GridSelectionRules.digitTargets(selected: selected, visible: visible, focused: focused)
            t.check(got == want, "多选 数字键 " + name, "得到 \(got)")
        }
        // 情形 1（审查报告）：⌘点 3 张按 1、清掉选中，再方向键走到 u1 按 3 —— 改的只是 u1。
        let first = GridSelectionRules.digitTargets(selected: ["p1", "p2", "p3"], visible: ["p1", "p2", "p3", "u1"], focused: "u1")
        let afterClear: Set<String> = first.clearSelection ? [] : ["p1", "p2", "p3"]
        let second = GridSelectionRules.digitTargets(selected: afterClear, visible: ["p1", "p2", "p3", "u1"], focused: "u1")
        t.check(second.ids == ["u1"], "多选 按完数字键清掉选中：接着方向键 + 数字改的是焦点那张，不是早先那几张",
                "得到 \(second.ids)")

        let pruneRows: [(String, Set<String>, [String], Set<String>)] = [
            ("⌘A 后切到「废片」筛选：精选、可用的选中剪掉", ["p1", "u1", "r1", "r2"], ["r1", "r2"], ["r1", "r2"]),
            ("换章（[ ] / 时间轴）：上一章的选中剪掉", ["c1a", "c1b"], ["c2a", "c2b"], []),
            ("收起单张区 / 叠起定完的场：藏起来的剪掉", ["s1", "t1"], ["t1", "t2"], ["t1"]),
            ("展开（看得见的只多不少）：选中不变", ["t1"], ["t1", "t2", "s1"], ["t1"]),
            ("没有选中：还是空", [], ["a"], []),
        ]
        for (name, selected, visible, want) in pruneRows {
            let got = GridSelectionRules.pruned(selected, visible: visible)
            t.check(got == want, "多选 剪选中 " + name, "得到 \(got.sorted())")
        }

        let many = GridSelectionRules.changedNotice(count: 3, verdict: .reject) ?? "nil"
        t.check(many == "已改 3 张 → 废片 · ⌘Z 撤销", "多选 改了多张提示「已改 N 张」", "得到 \(many)")
        let restore = GridSelectionRules.changedNotice(count: 2, verdict: nil) ?? "nil"
        t.check(restore == "已改 2 张 → 恢复自动 · ⌘Z 撤销", "多选 按 0 恢复自动也提示", "得到 \(restore)")
        t.check(GridSelectionRules.changedNotice(count: 1, verdict: .pick) == nil, "多选 只改一张不提示")
    }

    // MARK: - 水印页导入的 RAW+JPG 配对（S26a）

    private static func watermarkCases(_ t: Tally) {
        func u(_ name: String) -> URL { URL(fileURLWithPath: "/shoot/" + name) }
        func names(_ urls: [URL]) -> String {
            urls.map { $0.path.hasPrefix("/shoot/") ? String($0.path.dropFirst(7)) : $0.path }.joined(separator: ",")
        }
        // (说明, 列表里已有的, 这次导入的, 期望列表, added, replaced, skippedRaw, rawOnly)
        typealias Row = (String, [String], [String], [String], Int, Int, Int, Int)
        let rows: [Row] = [
            ("RAW+JPG 文件夹：每对只留 JPG，纯 RAW 照收",
             [], ["A.JPG", "A.RAF", "B.JPG", "B.RAF", "C.RAF"], ["A.JPG", "B.JPG", "C.RAF"], 3, 0, 2, 1),
            ("RAW 排在 JPG 前面（.ARW < .JPG）：结果一样",
             [], ["A.ARW", "A.JPG"], ["A.JPG"], 1, 0, 1, 0),
            ("扩展名大小写不同照样配对", [], ["a.raf", "a.jpg"], ["a.jpg"], 1, 0, 1, 0),
            ("先拖 JPG、后拖 RAW：跳过 RAW", ["A.JPG"], ["A.RAF"], ["A.JPG"], 0, 0, 1, 0),
            ("先拖 RAW、后拖 JPG：原地换成 JPG（位置不变）",
             ["X.JPG", "A.RAF", "Y.JPG"], ["A.JPG"], ["X.JPG", "A.JPG", "Y.JPG"], 0, 1, 0, 0),
            ("先有 RAW，再拖整个文件夹（JPG + 同一张 RAW）：换成 JPG，那张 RAW 不再记一次跳过",
             ["A.RAF"], ["A.JPG", "A.RAF"], ["A.JPG"], 0, 1, 0, 0),
            ("同类同名不配对：HEIC + JPG 两张都留", [], ["A.HEIC", "A.JPG"], ["A.HEIC", "A.JPG"], 2, 0, 0, 0),
            ("同类同名不配对：RAF + DNG 两张都留", [], ["A.DNG", "A.RAF"], ["A.DNG", "A.RAF"], 2, 0, 0, 2),
            ("RAF + DNG + JPG：都是同一张，只留 JPG", [], ["A.DNG", "A.JPG", "A.RAF"], ["A.JPG"], 1, 0, 2, 0),
            ("列表里 RAF + DNG，再来 JPG：两张 RAW 都换掉", ["A.RAF", "A.DNG"], ["A.JPG"], ["A.JPG"], 0, 2, 0, 0),
            ("不同文件夹的同名不是一对", [], ["d1/A.JPG", "d2/A.RAF"], ["d1/A.JPG", "d2/A.RAF"], 2, 0, 0, 1),
            ("已经在列表里的不重复收", ["A.JPG"], ["A.JPG"], ["A.JPG"], 0, 0, 0, 0),
        ]
        for (name, existing, incoming, want, added, replaced, skipped, rawOnly) in rows {
            let m = WatermarkImportPairing.merge(existing: existing.map(u), incoming: incoming.map(u))
            let gotList = names(m.photos)
            let wantList = want.joined(separator: ",")
            let counts = [m.added, m.replaced.count, m.skippedRaw, m.rawOnly]
            let ok: Bool = gotList == wantList && counts == [added, replaced, skipped, rawOnly]
            t.check(ok, "水印导入 " + name,
                    "得到 [\(gotList)] 新加/换掉/跳过/纯RAW = \(counts)，期望 [\(wantList)] \([added, replaced, skipped, rawOnly])")
        }

        // 提示：跳过的张数要写进去，免得以为少导了。
        let folder = WatermarkImportPairing.merge(existing: [], incoming: ["A.JPG", "A.RAF", "B.JPG", "B.RAF", "C.RAF"].map(u))
        let folderNotice = WatermarkImportPairing.notice(for: folder, requested: true) ?? "nil"
        let folderWant = "已导入 3 张 · 跳过 2 张同名 RAW（RAW+JPG 只留 JPG，和选片页一样） · 1 张只有 RAW，按系统默认冲洗导出"
        t.check(folderNotice == folderWant, "水印导入提示：写出导入、跳过、纯 RAW 张数", "得到 \(folderNotice)")
        let skipOnly = WatermarkImportPairing.merge(existing: [u("A.JPG")], incoming: [u("A.RAF")])
        let skipNotice = WatermarkImportPairing.notice(for: skipOnly, requested: true) ?? "nil"
        t.check(skipNotice == "没有新照片：跳过 1 张同名 RAW（RAW+JPG 只留 JPG，和选片页一样）",
                "水印导入提示：一张没进来、全是跳过的 RAW 时说清楚", "得到 \(skipNotice)")
        let swap = WatermarkImportPairing.merge(existing: [u("A.RAF")], incoming: [u("A.JPG")])
        let swapNotice = WatermarkImportPairing.notice(for: swap, requested: true) ?? "nil"
        let swapOK: Bool = swapNotice == "1 张 RAW 换成了同名 JPG" && swap.replaced.first?.old == u("A.RAF")
            && swap.replaced.first?.new == u("A.JPG")
        t.check(swapOK, "水印导入提示：只换不加时不说「没有可导入的照片」", "得到 \(swapNotice)")
        let dup = WatermarkImportPairing.merge(existing: [u("A.JPG")], incoming: [u("A.JPG")])
        let dupNotice = WatermarkImportPairing.notice(for: dup, requested: true) ?? "nil"
        t.check(dupNotice == "没有可导入的照片 (格式不支持，或已经在列表里)", "水印导入提示：全在列表里照旧", "得到 \(dupNotice)")
        let nothing = WatermarkImportPairing.notice(for: WatermarkImportPairing.merge(existing: [], incoming: []), requested: false)
        t.check(nothing == nil, "水印导入提示：什么都没给就不提示")
    }
}
