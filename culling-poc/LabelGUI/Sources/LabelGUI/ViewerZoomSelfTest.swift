import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - LabelGUI --viewer-zoom-selftest
//
// 看单张 / 审片的放大（ViewerZoom，UX-01 / 11-04 F16）：自己在临时目录里造几张 JPEG，不开界面，只验状态。
//   1. Z 进放大：这张的原图解出来；接着要翻到的那张也预解好了。
//   2. 翻到预解好的那张：当场就有原图（不等解码）；再预解下一张。
//   3. 翻到没解过的一张：上一张的原图马上放掉、这张算「解码中」；解完放大照旧开着。
//   4. 一口气翻过三张（不停）：被翻过去的两张不解（等一拍还停在那张才解），只解最后停下的那张。
//   5. 换方向：预解的那张不再是接下来要的就放掉。
//   6. 解不出的文件不卡在「解码中」；退出放大清干净。
//   7. 同一张同时要两次（预解还没完就翻到了）：只解一份，两边拿到的是同一张图。
//   8. 落在脸上：主脸中心；没脸 = nil（图中心）。
//   9. 人脸特写多大（GP-02）：审片竖片放进右边黑边、260pt；张数多按高度压；横片黑边够宽也放进去；放不下照旧角上 76pt；
//      看单张右栏一张脸占满栏宽。
enum ViewerZoomSelfTest {
    @MainActor
    static func run() -> Never {
        var failed = 0
        var total = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { failed += 1 }
            print((ok ? "PASS " : "FAIL ") + "放大：" + name + (ok ? "" : "（\(detail())）"))
        }
        func spin(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func wait(_ zoom: ViewerZoom) {
            let deadline = Date().addingTimeInterval(10)
            spin(0.05)
            while !zoom.settled, Date() < deadline { spin(0.02) }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LabelGUI-viewer-zoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            print("FAIL 放大：建不了临时目录 \(dir.path)")
            exit(1)
        }
        // 每张一个尺寸，认得出解出来的是哪张。
        var paths: [String] = []
        for k in 0..<8 {
            let url = dir.appendingPathComponent(String(format: "P%02d.jpg", k))
            guard writeJPEG(url, width: 400 + k * 10, height: 600) else {
                print("FAIL 放大：写不出样张 \(url.path)")
                exit(1)
            }
            paths.append(url.path)
        }
        func width(_ image: NSImage?) -> Int { Int(image?.size.width ?? 0) }
        FullResCache.cache.removeAllObjects()

        // 1. 进放大
        let zoom = ViewerZoom()
        zoom.toggle(path: paths[0], next: paths[1])
        check(zoom.on && zoom.loading(paths[0]), "Z 以后马上算开着、这张在解", "on=\(zoom.on)")
        wait(zoom)
        check(width(zoom.image(for: paths[0])) == 400, "这张的原图解出来了", "宽 \(width(zoom.image(for: paths[0])))")
        check(zoom.summary(for: paths[0]).contains("P01 原图已解好"), "下一张预解好了", zoom.summary(for: paths[0]))

        // 2. 翻到预解好的那张：当场就有
        zoom.show(paths[1], next: paths[2])
        check(width(zoom.image(for: paths[1])) == 410 && !zoom.loading(paths[1]), "翻到预解好的那张，当场就有原图",
              zoom.summary(for: paths[1]))
        check(zoom.image(for: paths[0]) == nil, "上一张的原图不再给出来")
        wait(zoom)
        check(zoom.summary(for: paths[1]).contains("P02 原图已解好"), "接着预解再下一张", zoom.summary(for: paths[1]))

        // 3. 翻到没解过的一张（跳着翻）
        FullResCache.cache.removeAllObjects()
        zoom.show(paths[4], next: paths[5])
        check(zoom.on && zoom.loading(paths[4]) && zoom.image(for: paths[1]) == nil,
              "翻到没解过的：放大还开着、这张算解码中、上一张放掉了", zoom.summary(for: paths[4]))
        wait(zoom)
        check(zoom.on && width(zoom.image(for: paths[4])) == 440, "解完照样在放大里", zoom.summary(for: paths[4]))

        // 4. 一口气翻过三张，只解最后停下的那张
        FullResCache.cache.removeAllObjects()
        zoom.show(paths[5], next: paths[6])
        zoom.show(paths[6], next: paths[7])
        zoom.show(paths[7], next: nil)
        wait(zoom)
        let skipped = FullResCache.cache.object(forKey: paths[5] as NSString) == nil
            && FullResCache.cache.object(forKey: paths[6] as NSString) == nil
        check(skipped && width(zoom.image(for: paths[7])) == 470, "连着翻过去的两张不解，只解停下的那张",
              "P05 \(FullResCache.cache.object(forKey: paths[5] as NSString) != nil ? "解了" : "没解")，"
              + "P06 \(FullResCache.cache.object(forKey: paths[6] as NSString) != nil ? "解了" : "没解")，"
              + zoom.summary(for: paths[7]))

        // 5. 换方向：预解的那张放掉
        zoom.show(paths[2], next: paths[3])
        wait(zoom)
        check(zoom.summary(for: paths[2]).contains("P03 原图已解好"), "往前翻：预解 P03", zoom.summary(for: paths[2]))
        zoom.show(paths[1], next: paths[0])
        check(zoom.aheadPath == nil, "掉头往回翻：预解好的 P03 当场放掉（不再是接下来要的）", "还拿着 \(zoom.aheadPath ?? "")")
        wait(zoom)
        check(zoom.aheadPath == paths[0], "往回翻预解的是 P00", zoom.summary(for: paths[1]))

        // 6. 解不出 / 退出
        let missing = dir.appendingPathComponent("不存在.jpg").path
        zoom.show(missing, next: nil)
        wait(zoom)
        check(zoom.on && !zoom.loading(missing) && zoom.summary(for: missing).contains("解不出"),
              "解不出的文件不卡在解码中", zoom.summary(for: missing))
        zoom.off()
        check(!zoom.on && zoom.full == nil && zoom.settled && !zoom.loading(paths[2]), "退出放大清干净")
        zoom.show(paths[0], next: paths[1])
        check(!zoom.on && zoom.full == nil, "关着时翻页什么都不解")

        // 7. 同一张同时要两次：只解一份
        FullResCache.cache.removeAllObjects()
        var first: NSImage?
        var second: NSImage?
        Task { @MainActor in first = await FullResCache.image(path: paths[6], priority: .utility).value }
        Task { @MainActor in second = await FullResCache.image(path: paths[6]).value }
        let deadline = Date().addingTimeInterval(10)
        while (first == nil || second == nil), Date() < deadline { spin(0.02) }
        check(first != nil && first === second, "同一张同时要两次，拿到的是同一份解码", "first=\(first != nil) second=\(second != nil)")

        // 8. 落在脸上
        let anchor = ViewerZoom.faceAnchor([0.2, 0.1, 0.4, 0.3])
        check(anchor.map { abs($0.x - 0.3) < 1e-9 && abs($0.y - 0.2) < 1e-9 } == true, "进放大落在主脸中心", "\(String(describing: anchor))")
        check(ViewerZoom.faceAnchor(nil) == nil && ViewerZoom.faceAnchor([0.1, 0.2]) == nil, "没脸（或框不对）就是图中心（nil）")

        // 9. 人脸特写多大（GP-02）
        let tall = ReviewView.closeupLayout(pane: CGSize(width: 1440, height: 730), aspect: 2.0 / 3, faces: 1)
        check(tall.inSideBar && tall.size == 260, "审片 1440 宽的竖片：一张脸放进右边黑边、260pt", "\(tall)")
        let four = ReviewView.closeupLayout(pane: CGSize(width: 1440, height: 730), aspect: 2.0 / 3, faces: 6)
        let fourHeight: CGFloat = four.size * 4 + 3 * 6 + 12 + 10 + 16
        check(four.inSideBar && four.size >= 140 && fourHeight <= 730, "竖片六张脸（画四张）：按高度压、放得下",
              "\(four)，四张占高 \(fourHeight)")
        let wide = ReviewView.closeupLayout(pane: CGSize(width: 1440, height: 730), aspect: 1.5, faces: 1)
        check(wide.inSideBar && wide.size >= 110 && wide.size + 12 <= wide.side, "横片 1440 宽：黑边约 170pt，特写放进黑边、不盖照片",
              "\(wide)")
        let narrow = ReviewView.closeupLayout(pane: CGSize(width: 900, height: 450), aspect: 1.5, faces: 2)
        check(!narrow.inSideBar && narrow.size == 76, "窄窗口的横片：照旧盖在右上角、76pt", "\(narrow)")
        let square = ReviewView.closeupLayout(pane: CGSize(width: 800, height: 800), aspect: 1, faces: 1)
        check(!square.inSideBar && square.size == 76, "照片占满宽度（没有黑边）：照旧 76pt", "\(square)")
        let sizes = [1, 2, 4, 5, 9].map { PhotoInspector.faceTileSize(count: $0, width: 292) }
        check(sizes == [292, 142, 142, 92, 92], "看单张右栏：一张脸占满栏宽、2–4 张一排两张、再多一排三张", "\(sizes)")

        FullResCache.cache.removeAllObjects()
        print(failed == 0 ? "放大：\(total) 条都过" : "放大：\(failed)/\(total) 条没过")
        exit(failed == 0 ? 0 : 1)
    }

    private static func writeJPEG(_ url: URL, width: Int, height: Int) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
