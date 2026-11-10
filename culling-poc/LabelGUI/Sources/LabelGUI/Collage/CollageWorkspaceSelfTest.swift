import Foundation
import AppKit

/// --album-selftest 里拼图工作区的几条（合成数据、不开界面）：两栏的宽度怎么让、画布缩放（夹、指针处放大、预览档）、
/// 「风格」收着时显示哪几个、托盘按章节分组的顺序、贴纸小图渲得出来。
/// 拖分隔条、捏合、滚轮、右键、悬停本身离屏收不到合成事件，验不了；右键菜单的内容用 `--collage-ui … --menu-at` 打印出来核对。
enum CollageWorkspaceSelfTest {
    typealias Check = CollageAlbumEditSelfTest.Check

    @MainActor
    static func run(check report: (Bool, String, String) -> Void) {
        withoutActuallyEscaping(report) { body in
            let check = Check(body: body)
            print("== 拼图工作区（两栏、画布缩放、风格两排、托盘分组、贴纸小图）")
            checkWidths(check: check)
            checkZoom(check: check)
            checkPresets(check: check)
            checkGrouping(check: check)
            checkStickers(check: check)
        }
    }

    static func checkWidths(check: Check) {
        let wide = CollageWorkspace.widths(total: 1440, tray: 250, inspector: 330)
        check(wide.tray == 250 && wide.inspector == 330, "1440 宽：两栏就是设的 250 / 330（画布 846）", "\(wide)")
        let narrow = CollageWorkspace.widths(total: 964, tray: 250, inspector: 330)
        check(narrow.tray == 230 && narrow.inspector == 300, "964 宽：两栏收到下限 230 / 300，画布还有 420", "\(narrow)")
        let mid = CollageWorkspace.widths(total: 1000, tray: 250, inspector: 330)
        let canvas = 1000 - mid.tray - mid.inspector - CollageWorkspace.handleWidth * 2
        check(abs(canvas - CollageWorkspace.canvasMin) <= 1 && mid.tray < 250 && mid.inspector < 330,
              "1000 宽：两栏各让一点，画布正好 420", "\(mid) 画布 \(canvas)")
        let hidden = CollageWorkspace.widths(total: 1000, tray: nil, inspector: 330)
        check(hidden.tray == 0 && hidden.inspector == 330, "左栏收着：右栏不用让", "\(hidden)")
        let huge = CollageWorkspace.widths(total: 2000, tray: 900, inspector: 10)
        check(huge.tray == CollageWorkspace.trayRange.upperBound && huge.inspector == CollageWorkspace.inspectorRange.lowerBound,
              "存的宽度出界：夹回各自的范围", "\(huge)")
        let tiny = CollageWorkspace.widths(total: 700, tray: 250, inspector: 330)
        check(tiny.tray == 230 && tiny.inspector == 300, "比最窄还窄：两栏停在下限（不变负数）", "\(tiny)")
    }

    @MainActor
    static func checkZoom(check: Check) {
        let view = CGSize(width: 800, height: 600)
        let fit = CGRect(x: 100, y: 28, width: 600, height: 544)
        let zoom = CollageCanvasZoom()
        zoom.record(viewSize: view, fitRect: fit, fitPixelRatio: 0.2)
        check(zoom.isFit && zoom.percent == 20 && zoom.maxScale == 5, "适应：20%，最大放到实际像素 5 倍",
              "\(zoom.percent)% 最大 \(zoom.maxScale)")
        zoom.pan(by: CGSize(width: 50, height: 0))
        check(zoom.offset == .zero, "没放大时不能平移")
        // 指针处放大：指针底下那一点不动。
        let p = CGPoint(x: 250, y: 200)
        func canvasPoint(_ z: CollageCanvasZoom) -> CGPoint {
            let layout = CollageCanvasLayout(rect: fit, scale: 1).zoomed(z.scale, offset: z.offset, in: view)
            return layout.toCanvas(p)
        }
        let before = canvasPoint(zoom)
        zoom.zoom(to: 2, anchor: p)
        let after = canvasPoint(zoom)
        check(abs(before.x - after.x) < 0.01 && abs(before.y - after.y) < 0.01 && zoom.scale == 2,
              "在指针处放大 2 倍：指针底下还是同一点", "\(before) → \(after)")
        zoom.pan(by: CGSize(width: 9999, height: 9999))
        let maxX = (fit.width * 2 - view.width) / 2 + CollageCanvasZoom.slack
        let maxY = (fit.height * 2 - view.height) / 2 + CollageCanvasZoom.slack
        check(abs(zoom.offset.width - maxX) < 0.01 && abs(zoom.offset.height - maxY) < 0.01,
              "平移夹住：画布边最多离开视图边 28pt", "\(zoom.offset) 上限 \(maxX),\(maxY)")
        zoom.zoom(to: 99)
        check(zoom.scale == 5, "放大夹在最大", "\(zoom.scale)")
        zoom.actualPixels()
        check(zoom.isFit && zoom.offset == .zero, "已经是实际像素再按一次：回到适应、平移清零", "\(zoom.scale) \(zoom.offset)")
        zoom.actualPixels()
        check(zoom.percent == 100, "实际像素 = 100%", "\(zoom.percent)%")
        zoom.zoomOut()
        zoom.fit()
        check(zoom.isFit, "⌘0 回到适应")
        // 放大后的摆放来回换算
        let layout = CollageCanvasLayout(rect: fit, scale: 0.1).zoomed(3, offset: CGSize(width: -40, height: 25), in: view)
        let c = CGPoint(x: 1234, y: 987)
        let back = layout.toCanvas(layout.toView(c))
        check(abs(back.x - c.x) < 0.01 && abs(back.y - c.y) < 0.01 && abs(layout.scale - 0.3) < 1e-9,
              "放大后的摆放：成品坐标 ↔ 视图坐标来回一致", "\(back)")
        let buckets = [1.0, 1.2, 1.5, 2.0, 2.1, 3.9].map { Double(CollageCanvasZoom.renderBucket(CGFloat($0))) }
        let want = [1.0, 2.0.squareRoot(), 2.0, 2.0, 2.0 * 2.0.squareRoot(), 4.0]
        check(zip(buckets, want).allSatisfy { abs($0 - $1) < 1e-6 }, "预览档：不低于现在的缩放、√2 一档", "\(buckets)")
    }

    static func checkPresets(check: Check) {
        check(CollageStylePanel.collapsedPresets(count: 21, active: 0, limit: 6) == [0, 1, 2, 3, 4, 5], "风格收着：前 6 个")
        check(CollageStylePanel.collapsedPresets(count: 21, active: 13, limit: 6) == [0, 1, 2, 3, 4, 13],
              "风格收着：正在用的排在后面，顶掉第 6 个")
        check(CollageStylePanel.collapsedPresets(count: 21, active: nil, limit: 6) == [0, 1, 2, 3, 4, 5], "风格收着：哪个都不是")
        check(CollageStylePanel.collapsedPresets(count: 4, active: 3, limit: 6) == [0, 1, 2, 3], "预设不到 6 个：全显示")
    }

    static func checkGrouping(check: Check) {
        func ref(_ id: String, _ chapter: Int?) -> CollagePhotoRef {
            var r = CollagePhotoRef(id: id, path: "/x/\(id).jpg", width: 3, height: 2)
            r.chapter = chapter
            return r
        }
        let mixed = [ref("a", 1), ref("b", nil), ref("c", 0), ref("d", 1), ref("e", 0)]
        let got = CollageTray.grouped(mixed)?.map(\.id)
        check(got == ["c", "e", "a", "d", "b"], "托盘按章节：章节小的在前、章内还是带进来的顺序、没有章节的排最后",
              "\(got ?? [])")
        check(CollageTray.grouped([ref("a", 2), ref("b", 2)]) == nil, "只有一章：不分组")
        check(CollageTray.grouped([ref("a", nil), ref("b", nil)]) == nil, "都没有章节（外部文件）：不分组")
    }

    static func checkStickers(check: Check) {
        for kind in CollageSticker.allCases {
            let item = CollageStickerThumbs.item(kind)
            let paper = CollageStickerThumbs.paper
            let aspect = Double(paper.width) / Double(paper.height)
            let fits = item.width <= 0.78 * aspect + 1e-9 && item.height <= 0.74 + 1e-9
            guard let cg = CollageStickerThumbs.render(kind) else {
                check(false, "贴纸小图「\(kind.label)」渲得出来")
                continue
            }
            // 不是一张白纸：中间那一带里有和纸色差得多的像素。
            let inked = inkFraction(cg)
            check(fits && cg.width == paper.width && cg.height == paper.height && inked > 0.004,
                  "贴纸小图「\(kind.label)」：\(paper.width)×\(paper.height)，贴纸在纸里、画出东西了",
                  String(format: "宽 %.2f 高 %.2f 着墨 %.1f%%", item.width, item.height, inked * 100))
        }
    }

    /// 和左上角那个像素（纸色）差得多的像素占多少。
    private static func inkFraction(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = (Int(data[0]), Int(data[1]), Int(data[2]))
        var n = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let d = abs(Int(data[i]) - base.0) + abs(Int(data[i + 1]) - base.1) + abs(Int(data[i + 2]) - base.2)
            if d > 45 { n += 1 }
        }
        return Double(n) / Double(w * h)
    }
}
