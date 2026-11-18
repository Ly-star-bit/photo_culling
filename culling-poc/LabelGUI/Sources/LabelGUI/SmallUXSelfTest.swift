import Foundation
import CoreGraphics

/// --ux-selftest 里批量页几件小事的纯函数部分（优化分析 2026-11-18 L4 第 4 步）：
///   1. 连拍挑选单行滚动时每张按自己的比例算框（ux 复核漏网 1）：对着 `--compare` 排布表里已知的数。
///   2. 时间轴跨年份才带年（EC-07）。
/// 返回没过的条数。
@MainActor
enum SmallUXSelfTest {
    static func run() -> Int {
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if !ok { failed += 1 }
            let tail: String = ok ? "" : "（\(detail())）"
            print((ok ? "PASS " : "FAIL ") + name + tail)
        }
        func text(_ s: CGSize) -> String { "\(Int(s.width))×\(Int(s.height))" }

        // 1. 连拍挑选的框
        let portrait: CGFloat = 2.0 / 3.0
        let landscape: CGFloat = 1.5
        // 10 张、1416×720：排布表里竖拍滚动 394×592、横拍滚动 590×393（Fixtures/synthetic-rejects/expected_compare.txt）。
        let big = CGSize(width: 1416, height: 720)
        let mixed = PickLayout.compute(count: 10, in: big, aspect: landscape, hasFaces: true)
        check(mixed.arrangement == .strip, "连拍挑选 10 张 1416×720 是单行滚动", "\(mixed.arrangement)")
        let tall: CGSize = mixed.frame(aspect: portrait)
        let wide: CGSize = mixed.frame(aspect: landscape)
        check(text(tall) == "394×592", "单行滚动：横框的一组里竖片按竖框算（394×592）", text(tall))
        check(text(wide) == "590×393" && wide == mixed.image, "单行滚动：横片照旧 590×393、就是中位比例那一张的框", text(wide))
        let byPortrait = PickLayout.compute(count: 10, in: big, aspect: portrait, hasFaces: true)
        check(byPortrait.frame(aspect: landscape) == wide && byPortrait.frame(aspect: portrait) == tall,
              "单行滚动：中位取到竖还是横，每张的框都一样（只看自己的比例）")
        let small = PickLayout.compute(count: 9, in: CGSize(width: 1256, height: 640), aspect: landscape, hasFaces: true)
        check(text(small.frame(aspect: portrait)) == "341×512" && text(small.frame(aspect: landscape)) == "521×347",
              "单行滚动 1256×640：竖 341×512、横 521×347", text(small.frame(aspect: portrait)) + " / " + text(small.frame(aspect: landscape)))
        // 铺满（行 × 列）：格子一样大，哪种比例都是 image（横竖混的铺满那一档以后再说）。
        let grid = PickLayout.compute(count: 4, in: big, aspect: landscape, hasFaces: true)
        let gridSame: Bool = grid.frame(aspect: portrait) == grid.image && grid.frame(aspect: landscape) == grid.image
        check(grid.arrangement != .strip && gridSame, "铺满的一组：每张都是同一个框", "\(grid.arrangement) \(text(grid.image))")
        // 极端比例照旧夹在 0.2…5、不小于 80×60。
        let pano: CGSize = mixed.frame(aspect: 12)
        check(pano.width <= mixed.stripMaxWidth + 0.5 && pano.height >= 60, "全景图不超宽度上限、不矮过 60", text(pano))

        failed += timelineYears()
        return failed
    }

    /// 2. 时间轴跨年份才带年（EC-07）：机身时间复位成 1970 / 2000 的几段和正常的一段混在一起，标签、右键菜单、
    ///    悬停卡片要分得出；同一年的多天拍摄照旧不写年。
    private static func timelineYears() -> Int {
        var failed = 0
        func expect(_ ok: Bool, _ name: String, _ detail: String) {
            if !ok { failed += 1 }
            let tail: String = ok || detail.isEmpty ? "" : "（\(detail)）"
            print((ok ? "PASS " : "FAIL ") + name + tail)
        }
        let calendar = Calendar.current
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h)) ?? Date(timeIntervalSince1970: 0)
        }
        func segments(_ starts: [Date]) -> [BatchStore.ChapterSegment] {
            starts.enumerated().map { i, start in
                BatchStore.ChapterSegment(chapter: i, count: 5, pick: 1, usable: 2, reject: 2,
                                          start: start, end: start.addingTimeInterval(60), timeRange: "",
                                          underMin: false, pendingTakes: 0, covers: [])
            }
        }
        let reset = segments([at(1970, 1, 1, 0), at(2000, 1, 1, 0), at(2000, 1, 1, 9), at(2026, 3, 21, 16)])
        let layout = ChapterTimelineLayout.compute(reset, width: 1440, measure: ChapterTimelineLayout.measureText)
        let days: [String] = layout.labels.filter(\.isDay).map(\.text)
        expect(ChapterTimelineLayout.spansYears(reset), "时间轴：1970 / 2000 / 2026 算跨年份", "")
        expect(days.count == 3 && days.allSatisfy { $0.contains("年") }, "时间轴：跨年份时换天的标签都带年",
               days.joined(separator: " | "))
        expect(days.contains { $0.hasPrefix("1970年1月1日") } && days.contains { $0.hasPrefix("2000年1月1日") },
               "时间轴：两段「1月1日」分得出是哪一年", days.joined(separator: " | "))
        let menu: String = ChapterTimeline.menuTitle(reset[1], year: true)
        expect(menu.contains("2000年1月1日"), "时间轴：右键菜单「只看这一章」带年", menu)

        let sameYear = segments([at(2026, 3, 20, 10), at(2026, 3, 21, 9), at(2026, 3, 22, 18)])
        let plain = ChapterTimelineLayout.compute(sameYear, width: 1440, measure: ChapterTimelineLayout.measureText)
        let plainDays: [String] = plain.labels.filter(\.isDay).map(\.text)
        expect(!ChapterTimelineLayout.spansYears(sameYear) && !plainDays.isEmpty && !plainDays.contains { $0.contains("年") },
               "时间轴：同一年的多天拍摄不写年", plainDays.joined(separator: " | "))
        expect(ChapterTimelineLayout.dayText(at(2026, 3, 21, 16)) == "3月21日"
               && ChapterTimelineLayout.dayText(at(2000, 1, 1, 0), year: true) == "2000年1月1日",
               "时间轴：dayText 默认不带年、year 带年", ChapterTimelineLayout.dayText(at(2000, 1, 1, 0), year: true))
        // 无时间那一段不算一个年份。
        var undated = segments([at(2026, 3, 21, 9)])
        undated.append(BatchStore.ChapterSegment(chapter: BatchStore.ChapterSegment.undatedID, count: 2, pick: 0, usable: 2,
                                                 reject: 0, start: nil, end: nil, timeRange: "", underMin: false,
                                                 pendingTakes: 0, covers: []))
        expect(!ChapterTimelineLayout.spansYears(undated), "时间轴：无时间的那段不算跨年份", "")
        return failed
    }
}
