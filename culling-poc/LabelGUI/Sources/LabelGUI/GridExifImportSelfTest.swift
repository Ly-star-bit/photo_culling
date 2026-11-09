import Foundation
import Combine
import AppKit

/// `--ux-selftest` 里的几组纯函数用例：EXIF 拍摄参数（快门 0 / 极小正数不崩）、网格多选（数字键、剪选中）、
/// 水印页导入的 RAW+JPG 配对、拼图托盘每格的选中标记、审片 / 检视器大图的解码尺寸。
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

    @MainActor
    static func run() -> Int {
        let tally = Tally()
        exifCases(tally)
        gridSelectionCases(tally)
        watermarkCases(tally)
        trayMarkCases(tally)
        fitDecodeCases(tally)
        cacheInvalidationCases(tally)
        return tally.failed
    }

    // MARK: - 分析收尾只清重写了预览的照片

    /// 分析收尾的缓存清理（BatchStore.stalePreviewPaths + ThumbCache.invalidate(paths:)）：只有分析前就在网格里、
    /// 这次又写了预览的照片作废，别的照片的键、缓存里的图一个不动。
    @MainActor
    private static func cacheInvalidationCases(_ t: Tally) {
        let tag = "/selftest-" + String(UUID().uuidString.prefix(8))
        let (aPrev, aRaw, bPrev, bRaw) = (tag + "/previews/A.jpg", tag + "/A.JPG", tag + "/previews/B.jpg", tag + "/B.JPG")
        let before = ["A": [aPrev, aRaw], "B": [bPrev, bRaw]]
        let none = BatchStore.stalePreviewPaths(before: before, written: [])
        t.check(none.isEmpty, "分析收尾 全部复用 → 一张不清", "得到 \(none)")
        let fresh = BatchStore.stalePreviewPaths(before: before, written: ["N1", "N2"])
        t.check(fresh.isEmpty, "分析收尾 只新拷进来的照片写了预览 → 一张不清（新照片本来就是新键）", "得到 \(fresh)")
        let one = BatchStore.stalePreviewPaths(before: before, written: ["A", "N1"])
        t.check(one == [aPrev, aRaw], "分析收尾 改过的 A 重写了预览 → 只清 A 的预览和原图路径", "得到 \(one)")

        let image = NSImage(size: NSSize(width: 4, height: 4))
        let keys = [aPrev: ThumbCache.key(aPrev, 512), bPrev: ThumbCache.key(bPrev, 512)]
        let fitB = FitCache.renderedKey(path: bRaw, edge: 2560)
        let fitA = FitCache.renderedKey(path: aRaw, edge: 2560)
        for key in keys.values { ThumbCache.cache.setObject(image, forKey: key) }
        FitCache.cache.setObject(image, forKey: fitB)
        FullResCache.cache.setObject(image, forKey: aRaw as NSString)
        FullResCache.cache.setObject(image, forKey: bRaw as NSString)
        ThumbCache.invalidate(paths: one)
        let aThumbMoved: Bool = ThumbCache.key(aPrev, 512) != keys[aPrev]
        let aSharpMoved: Bool = FitCache.renderedKey(path: aRaw, edge: 2560) != fitA
        t.check(aThumbMoved && aSharpMoved, "分析收尾 A 的缩略图键、锐化成品键都换了（看得见的格子会重解 A）")
        let bThumbKey: Bool = ThumbCache.key(bPrev, 512) == keys[bPrev]
        let bSharpKey: Bool = FitCache.renderedKey(path: bRaw, edge: 2560) == fitB
        let bThumbHeld: Bool = ThumbCache.cache.object(forKey: ThumbCache.key(bPrev, 512)) != nil
        let bSharpHeld: Bool = FitCache.cache.object(forKey: fitB) != nil
        t.check(bThumbKey && bSharpKey && bThumbHeld && bSharpHeld, "分析收尾 B 的键没变、缓存里的图还在（不重解、不灰一下）")
        let aFullGone: Bool = FullResCache.cache.object(forKey: aRaw as NSString) == nil
        let bFullHeld: Bool = FullResCache.cache.object(forKey: bRaw as NSString) != nil
        t.check(aFullGone && bFullHeld, "分析收尾 100% 原图缓存只拿掉 A 的")
        for key in keys.values { ThumbCache.cache.removeObject(forKey: key) }
        FitCache.cache.removeObject(forKey: fitB)
        FullResCache.cache.removeObject(forKey: bRaw as NSString)
    }

    // MARK: - 大图解码尺寸

    /// 审片 / 检视器 / 连拍挑选的大图解多大（FitCache.decodeSize）：几种机身长边 × 几档取景区。期望值手算：
    /// 原图长边的一半 ≥ 0.9 × min(4096, 档位) 就要一半（一半超过 4096 的要 4096），不够就 4096。
    private static func fitDecodeCases(_ t: Tally) {
        let displays = [1536, 2560, 3072, 3328, 3584, 3840, 4096, 5120]
        // (机身, 原图长边, 每档期望)
        let rows: [(String, Int, [Int])] = [
            ("24 MP 6000", 6000, [3000, 3000, 3000, 3000, 4096, 4096, 4096, 4096]),
            ("24 MP 6048", 6048, [3024, 3024, 3024, 3024, 4096, 4096, 4096, 4096]),
            ("33 MP 7008", 7008, [3504, 3504, 3504, 3504, 3504, 3504, 4096, 4096]),
            ("40 MP 7728", 7728, [3864, 3864, 3864, 3864, 3864, 3864, 3864, 3864]),
            ("45 MP 8192", 8192, [4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096]),
            ("61 MP 9504", 9504, [4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096]),
        ]
        for (name, original, want) in rows {
            let got = displays.map { FitCache.decodeSize(original: original, display: $0) }
            t.check(got == want, "大图解码尺寸 " + name + " × 档位 \(displays)", "得到 \(got)，期望 \(want)")
        }
        let small = [1536, 2560].map { FitCache.decodeSize(original: 3000, display: $0) }
        t.check(small == [1500, 4096], "大图解码尺寸 长边 3000 的小 JPEG：1536 档要一半，2560 档要 4096（ImageIO 给原尺寸）",
                "得到 \(small)")
        let unknown = FitCache.decodeSize(original: 0, display: 2560)
        t.check(unknown == 4096, "大图解码尺寸 读不到原图尺寸 → 4096（老路）", "得到 \(unknown)")
        let jpeg = FitCache.Header(width: 7728, height: 5152, jpeg: true)
        let raw = FitCache.Header(width: 7728, height: 5152, jpeg: false)
        let byHeader = [FitCache.decodeSize(header: jpeg, display: 2560), FitCache.decodeSize(header: raw, display: 2560),
                        FitCache.decodeSize(header: nil, display: 2560)]
        t.check(byHeader == [3864, 4096, 4096], "大图解码尺寸 JPEG 要一半；RAW / HEIC、读不出头的照旧 4096",
                "得到 \(byHeader)")
    }

    // MARK: - 拼图托盘的选中标记

    /// 托盘网格每格只订阅自己那张的标记（CollageTrayState.mark）：单击换一张只该有两格收到通知，
    /// ⌘ / ⇧ / ⌘A / 筛掉 / 取消之后每个标记都和 selection 对得上（对不上 = 选中框画错）。
    @MainActor
    private static func trayMarkCases(_ t: Tally) {
        let tray = CollageTrayState()
        let order = ["a", "b", "c", "d", "e"]
        let marks = order.map(tray.mark)
        var fired: [String: Int] = [:]
        let subs = zip(order, marks).map { id, m in m.objectWillChange.sink { _ in fired[id, default: 0] += 1 } }
        defer { subs.forEach { $0.cancel() } }
        func agrees() -> Bool { zip(order, marks).allSatisfy { id, m in m.selected == tray.selection.contains(id) } }
        func step(_ name: String, _ action: () -> Void, notified: Set<String>? = nil) {
            fired = [:]
            action()
            let shown = order.filter { tray.mark($0).selected }.joined(separator: ",")
            t.check(agrees(), "托盘标记 " + name + "：每格的选中框和选中一致", "选中 \(tray.selection.sorted())，标记 \(shown)")
            if let notified {
                t.check(Set(fired.keys) == notified && fired.values.allSatisfy { $0 == 1 },
                        "托盘标记 " + name + (notified.isEmpty ? "：一格都不通知"
                                               : "：只通知 " + notified.sorted().joined(separator: "、")),
                        "通知了 \(fired.sorted { $0.key < $1.key })")
            }
        }
        step("单击 a", { tray.click("a", command: false, shift: false, order: order) }, notified: ["a"])
        step("单击换到 c", { tray.click("c", command: false, shift: false, order: order) }, notified: ["a", "c"])
        step("再单击 c（没变）", { tray.click("c", command: false, shift: false, order: order) }, notified: [])
        step("⌘ 点 e", { tray.click("e", command: true, shift: false, order: order) }, notified: ["e"])
        step("⌘ 点 c 去掉", { tray.click("c", command: true, shift: false, order: order) }, notified: ["c"])
        step("⇧ 点 b（从 c 连到 b）", { tray.click("b", command: false, shift: true, order: order) })
        step("⌘A", { tray.selectAll(order) })
        step("筛掉 d、e", { tray.prune(to: ["a", "b", "c"]) }, notified: ["d", "e"])
        let late = tray.mark("b")
        t.check(late === marks[1], "托盘标记 同一张拿到的是同一个标记（格子滚出去再回来不换对象）")
        let fresh = tray.mark("x")
        t.check(!fresh.selected, "托盘标记 第一次拿的标记按现在的选中定（x 没选）")
        tray.selection.insert("x")
        t.check(fresh.selected, "托盘标记 不经过 click 原地往选中里插一张：标记跟上")
        step("Esc 取消", { tray.clear() })
        step("换场次 reset", { tray.click("d", command: false, shift: false, order: order); tray.reset() })
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

        refocusCases(t)

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

    /// 多选改判以后焦点落在哪（GridSelectionRules.refocus，数字键和批量栏共用）。
    private static func refocusCases(_ t: Tally) {
        typealias R = GridSelectionRules.Refocus
        // (说明, 焦点, 这一下改了的, 改判前看得见的（顺序）, 改判后看得见的, 期望)
        let rows: [(String, String?, [String], [String], [String], R)] = [
            ("「可用」筛选下 ⇧选 A–D 按 1：四张都藏了 → 落到没改的 E（以前焦点留在藏起的 A 上）",
             "A", ["A", "B", "C", "D"], ["A", "B", "C", "D", "E", "F"], ["E", "F"], .move("E")),
            ("按判决分区时选中的一串跳去精选区 → 落到原来后面没改的 E，不跟着落到那一串的第二张 B",
             "A", ["A", "B", "C", "D"], ["p1", "A", "B", "C", "D", "E", "r1"], ["A", "B", "C", "D", "p1", "E", "r1"], .move("E")),
            ("按判决分区、选中的一串改完还在原来两张没改的照片之间 → 不动",
             "A", ["A", "B", "C", "D"], ["p1", "A", "B", "C", "D", "E"], ["p1", "A", "B", "C", "D", "E"], .stay),
            ("焦点没选、还看得见 → 不动", "F", ["A", "B", "C", "D"], ["A", "B", "C", "D", "E", "F"], ["E", "F"], .stay),
            ("焦点没选、却跟着整场定完叠掉（只看待处理）→ 落到下一场第一张",
             "t3", ["t1", "t2"], ["t1", "t2", "t3", "u1", "u2"], ["u1", "u2"], .move("u1")),
            ("「保留选中」：焦点那张废了被筛掉、留下的 B 一起改了 → 落到没改的 X",
             "A", ["A", "B"], ["A", "B", "X"], ["B", "X"], .move("X")),
            ("一起改了的那几张之外没有看得见的 → 退回去落在一起改了、还看得见的那张",
             "A", ["A", "B"], ["A", "B"], ["B"], .move("B")),
            ("⌘A 以后全被筛掉、一张都没得落 → 清掉焦点（下一次数字键什么都不改）",
             "A", ["A", "B"], ["A", "B"], [], .clear),
            ("改焦点那张：唯一一张被筛掉 → 清掉焦点（以前留在看不见的它上面）", "p1", ["p1"], ["p1"], [], .clear),
            ("改焦点那张：位置没变 → 不动", "a2", ["a2"], ["a1", "a2", "a3"], ["a1", "a2", "a3"], .stay),
            ("没有焦点 → 不动", nil, ["A"], ["A", "B"], ["B"], .stay),
        ]
        for (name, focused, changed, before, after, want) in rows {
            let got = GridSelectionRules.refocus(focused: focused, changed: changed, before: before, after: after)
            t.check(got == want, "多选 改完焦点 " + name, "得到 \(got)")
        }

        // 审查报告的情形连起来走一遍：按 1 改 A–D，再按 3 —— 改的是看得见的 E，不是藏起来的 A。
        let visible = ["A", "B", "C", "D", "E", "F"]
        let first = GridSelectionRules.digitTargets(selected: ["A", "B", "C", "D"], visible: visible, focused: "A")
        let after = ["E", "F"]
        var focus: String? = "A"
        switch GridSelectionRules.refocus(focused: focus, changed: first.ids, before: visible, after: after) {
        case .stay: break
        case .clear: focus = nil
        case .move(let next): focus = next
        }
        let afterClear: Set<String> = first.clearSelection ? [] : ["A", "B", "C", "D"]
        let second = GridSelectionRules.digitTargets(selected: afterClear, visible: after, focused: focus)
        t.check(second.ids == ["E"], "多选 ⇧选 A–D 按 1 藏掉以后再按 3：改的是看得见的 E，不是藏起来的 A",
                "得到 \(second.ids)")
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
            // 选片页把 A.DNG + A.JPG 配成一张（解码 JPG）、多出来的 A.RAF 单算一张，「导入选片结果」带过来的就是这两条。
            ("「导入选片结果」带过来 RAF + DNG + JPG 的那两张（A.JPG、A.RAF）：也只留 JPG",
             [], ["A.JPG", "A.RAF"], ["A.JPG"], 1, 0, 1, 0),
            ("列表里 RAF + DNG，再来 JPG：两张 RAW 都换掉", ["A.RAF", "A.DNG"], ["A.JPG"], ["A.JPG"], 0, 2, 0, 0),
            ("不同文件夹的同名不是一对", [], ["d1/A.JPG", "d2/A.RAF"], ["d1/A.JPG", "d2/A.RAF"], 2, 0, 0, 1),
            ("已经在列表里的不重复收", ["A.JPG"], ["A.JPG"], ["A.JPG"], 0, 0, 0, 0),
            ("同一张 RAW 在这一批里出现两次（文件夹 + 里面的文件）：只算一次跳过",
             [], ["A.JPG", "A.RAF", "A.RAF"], ["A.JPG"], 1, 0, 1, 0),
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
        let folderWant = "已导入 3 张 · 跳过 2 张同名 RAW（RAW+JPG 只留 JPG） · 1 张只有 RAW，按系统默认冲洗导出"
        t.check(folderNotice == folderWant, "水印导入提示：写出导入、跳过、纯 RAW 张数", "得到 \(folderNotice)")
        let skipOnly = WatermarkImportPairing.merge(existing: [u("A.JPG")], incoming: [u("A.RAF")])
        let skipNotice = WatermarkImportPairing.notice(for: skipOnly, requested: true) ?? "nil"
        t.check(skipNotice == "没有新照片：跳过 1 张同名 RAW（RAW+JPG 只留 JPG）",
                "水印导入提示：一张没进来、全是跳过的 RAW 时说清楚", "得到 \(skipNotice)")
        // 「导入选片结果」这种情形里选片页其实是两张：提示不能说「和选片页一样」。
        let fromBatch = WatermarkImportPairing.merge(existing: [], incoming: [u("A.JPG"), u("A.RAF")])
        let fromBatchNotice = WatermarkImportPairing.notice(for: fromBatch, requested: true) ?? "nil"
        t.check(fromBatchNotice == "已导入 1 张 · 跳过 1 张同名 RAW（RAW+JPG 只留 JPG）",
                "水印导入提示：导入选片结果跳过同名 RAW 时不说「和选片页一样」", "得到 \(fromBatchNotice)")
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

        collageFileCases(t, u: u, names: names)
    }

    /// 拼图托盘收外部文件（CollageStore.addFiles、水印页交接里认不出的）的 RAW+JPG 配对：CollageHandoff.pairedExternalFiles。
    private static func collageFileCases(_ t: Tally, u: (String) -> URL, names: ([URL]) -> String) {
        // (说明, 托盘里已有的, 这次拖进来的, 期望收的, 没收的 RAW 张数)
        let rows: [(String, [String], [String], [String], Int)] = [
            ("RAW+JPG 双存的文件夹拖进托盘：每一帧只收 JPG，纯 RAW 照收",
             [], ["A.JPG", "A.RAF", "B.JPG", "B.RAF", "C.RAF"], ["A.JPG", "B.JPG", "C.RAF"], 2),
            ("RAW 排在 JPG 前面（.ARW < .JPG）：照样只收 JPG", [], ["A.ARW", "A.JPG"], ["A.JPG"], 1),
            ("扩展名大小写不同照样配对", [], ["a.raf", "a.JPG"], ["a.JPG"], 1),
            ("托盘里已经有这一张的 JPG，再拖它的 RAW：不收", ["A.JPG"], ["A.RAF"], [], 1),
            ("托盘里只有 RAW，再拖同名 JPG：照收 JPG（不原地换，托盘里那张可能已经上了版）", ["A.RAF"], ["A.JPG"], ["A.JPG"], 0),
            ("同类同名不配对：RAF + DNG 都收", [], ["A.DNG", "A.RAF"], ["A.DNG", "A.RAF"], 0),
            ("同类同名不配对：HEIC + JPG 都收", [], ["A.HEIC", "A.JPG"], ["A.HEIC", "A.JPG"], 0),
            ("不同文件夹的同名不是一对", [], ["d1/A.JPG", "d2/A.RAF"], ["d1/A.JPG", "d2/A.RAF"], 0),
            ("同一张 RAW 给了两次（文件夹 + 里面的文件）：只算一张没收", [], ["A.JPG", "A.RAF", "A.RAF"], ["A.JPG"], 1),
        ]
        for (name, tray, incoming, want, skipped) in rows {
            let got = CollageHandoff.pairedExternalFiles(incoming.map(u), trayPaths: tray.map { u($0).path })
            let gotList = names(got.kept)
            let wantList = want.joined(separator: ",")
            let ok: Bool = gotList == wantList && got.skippedRaw == skipped
            t.check(ok, "拼图外部文件 " + name,
                    "得到 [\(gotList)] 没收 \(got.skippedRaw)，期望 [\(wantList)] 没收 \(skipped)")
        }
    }
}
