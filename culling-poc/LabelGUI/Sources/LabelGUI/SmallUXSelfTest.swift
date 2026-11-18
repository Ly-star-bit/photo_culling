import Foundation
import CoreGraphics

/// --ux-selftest 里批量页几件小事的纯函数部分（优化分析 2026-11-18 L4 第 4 步）：
///   1. 连拍挑选单行滚动时每张按自己的比例算框（ux 复核漏网 1）：对着 `--compare` 排布表里已知的数。
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

        return failed
    }
}
