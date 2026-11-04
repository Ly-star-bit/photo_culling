import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 交付环节的数据安全承诺，进程内逐条断言：LABELGUI_DATA_DIR=<临时> LabelGUI --delivery-selftest。
/// 照 --ux-selftest 写期望表，结果确定，不要照片、不跑 Vision、不开界面：
/// - XMP 归属（XMPSidecar.isOwn）：只有我们自己（和以前的 culling-poc）写的 sidecar 才整份重写，
///   LR / C1 写的、哪怕描述里提到「选片工具」，都只能合并；
/// - 合并（XMPSidecar.merged）：别人的 sidecar 只改星级 / 色标，调色、关键字原样；色标是上次我们写的才拿掉；
///   读不全的写法（rdf:resource、非 rdf:li 上的 xml:lang、坏文件）宁可这张不写（nil）；
/// - 同名另存（DeliveryNaming.plan，水印批量和导出 JPG 共用）：目标里已有的另存 -2，批内大小写不同也算重名；
/// - 截断 JPEG（ImageLoader.jpegTruncated）：最后 64KB 的快路径、按段扫描、动态照片的尾巴、EXIF 缩略图里的 FF D9、后缀；
/// - 同一个文件（WatermarkEngine.isSameFile）：. 和 ..、经过符号链接的目录、硬链接、大小写不同；
/// - 去 GPS 两条路（BatchStore.writeJPEG、WatermarkEngine.export），GPS 写在 EXIF 里、只写在 XMP 包里都试；
///   不去 GPS 的对照组 GPS 要还在（证明这里查得出来），拍摄时间、机型这些不跟着去掉。
/// 临时文件写在数据目录下的 delivery-selftest/，跑完删掉。端到端（真命令行）见 Scripts/delivery_regression.py。
enum DeliverySelfTest {
    private final class Tally {
        var failures = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if !ok { failures += 1 }
            let head: String = ok ? "PASS " : "FAIL "
            let tail: String = detail.isEmpty ? "" : " · " + detail
            print(head + name + tail)
        }
    }

    @MainActor
    static func run() -> Never {
        CollageCLI.requireIsolatedDataDir("--delivery-selftest")
        let work = appDataDir.appendingPathComponent("delivery-selftest")
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            print("FAIL 建不了临时目录 \(work.path)：\(error.localizedDescription)")
            exit(1)
        }
        let t = Tally()
        print("== XMP 归属和合并")
        xmpCases(t)
        print("== 同名另存（DeliveryNaming.plan）")
        namingCases(work.appendingPathComponent("naming"), t)
        print("== 截断 JPEG（ImageLoader.jpegTruncated）")
        truncationCases(work.appendingPathComponent("trunc"), t)
        print("== 同一个文件（WatermarkEngine.isSameFile）")
        sameFileCases(work.appendingPathComponent("same"), t)
        print("== 拼图、水印导出不写进拍摄文件夹（ExportFolderGuard，见 ExportFolderSelfTest.swift）")
        ExportFolderSelfTest.run(work.appendingPathComponent("folder")) { t.check($0, $1, $2) }
        print("== 去 GPS（BatchStore.writeJPEG、WatermarkEngine.export）")
        gpsCases(work.appendingPathComponent("gps"), t)
        try? fm.removeItem(at: work)
        print(t.failures == 0 ? "== 全部通过" : "== \(t.failures) 条没过")
        exit(t.failures == 0 ? 0 : 1)
    }

    // MARK: - XMP

    /// LR Classic 开着「自动写 XMP」时的那种 sidecar：调色（crs）、关键字（dc:subject、lr:hierarchicalSubject 的 rdf:Bag）。
    static func lightroomSidecar(label: String?, rating: Int = 2, description: String? = nil) -> Data {
        let labelAttr = label.map { "\n   xmp:Label=\"\($0)\"" } ?? ""
        let desc = description.map {
            "\n   <dc:description>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">\($0)</rdf:li>\n    </rdf:Alt>\n   </dc:description>"
        } ?? ""
        let text = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 79.dabacbb, 2021/04/14-00:39:44        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmp:Rating="\(rating)"\(labelAttr)
           crs:Version="15.4"
           crs:Exposure2012="+0.35"
           crs:Contrast2012="-12"
           crs:WhiteBalance="Custom">
           <dc:subject>
            <rdf:Bag>
             <rdf:li>婚礼</rdf:li>
             <rdf:li>仪式</rdf:li>
            </rdf:Bag>
           </dc:subject>
           <lr:hierarchicalSubject>
            <rdf:Bag>
             <rdf:li>婚礼|仪式</rdf:li>
            </rdf:Bag>
           </lr:hierarchicalSubject>\(desc)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        return Data(text.utf8)
    }

    /// ImageIO 眼里的全部字段（递归）：路径 → 值（字符串值原样，结构 / 数组记成类型）。合并前后拿它逐个比。
    static func xmpFields(_ data: Data) -> [String: String]? {
        guard let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        var out: [String: String] = [:]
        let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, options) { path, tag in
            let value: String
            if let s = CGImageMetadataTagCopyValue(tag) as? String {
                value = s
            } else {
                value = "<type \(CGImageMetadataTagGetType(tag).rawValue)>"
            }
            out[path as String] = value
            return true
        }
        return out
    }

    static func xmpValue(_ data: Data, _ path: String) -> String? {
        guard let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String?
    }

    @MainActor
    private static func xmpCases(_ t: Tally) {
        // 归属
        let ours = Data(BatchStore.xmpContent(rating: 4, label: "Green", reason: "").utf8)
        t.check(XMPSidecar.isOwn(ours), "isOwn：我们自己的模板（BatchStore.xmpContent）认得出来 → 整份重写")
        let legacy = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="culling-poc">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3"/>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
        t.check(XMPSidecar.isOwn(legacy), "isOwn：以前的 Python 流水线（x:xmptk=\"culling-poc\"）写的也算自己的")
        let lr = lightroomSidecar(label: "Blue")
        t.check(!XMPSidecar.isOwn(lr), "isOwn：Lightroom 写的（Adobe XMP Core）不是自己的 → 只合并，不整份重写")
        let mentions = lightroomSidecar(label: nil, description: "选片工具 挑过的 x:xmptk 选片工具")
        t.check(!XMPSidecar.isOwn(mentions), "isOwn：别人的 sidecar 描述里提到「选片工具」也不算自己的")
        t.check(!XMPSidecar.isOwn(Data()), "isOwn：空文件不算自己的")

        // 合并：改星级 + 换色标，其余字段一个不少
        let before = xmpFields(lr) ?? [:]
        t.check(before["crs:Exposure2012"] == "+0.35" && before.count > 6,
                "前提：合成的 LR sidecar ImageIO 读得出来", "\(before.count) 个字段")
        if let out = XMPSidecar.merged(lr, rating: 5, label: "Green", lastLabel: nil) {
            var after = xmpFields(out) ?? [:]
            let rating: String? = xmpValue(out, "xmp:Rating")
            let label: String? = xmpValue(out, "xmp:Label")
            t.check(rating == "5" && label == "Green", "merged：星级 2→5、色标 Blue→Green",
                    "\(rating ?? "nil") / \(label ?? "nil")")
            var rest = before
            for key in ["xmp:Rating", "xmp:Label"] {
                rest.removeValue(forKey: key)
                after.removeValue(forKey: key)
            }
            let lost = rest.keys.filter { after[$0] != rest[$0] }.sorted()
            t.check(lost.isEmpty && after.count == rest.count, "merged：星级色标以外的字段逐个不变（调色、关键字）",
                    lost.isEmpty ? "\(rest.count) 个" : "变了 \(lost)")
            let text = String(decoding: out, as: UTF8.self)
            let kept = ["+0.35", "-12", "Custom", "婚礼|仪式", "仪式"].filter { text.contains($0) }
            t.check(kept.count == 5, "merged：调色数值和层级关键字原文还在", "\(kept)")
            t.check(!XMPSidecar.isOwn(out), "merged：合并完还是别人的（不会被下次当成自己的整份重写）")
        } else {
            t.check(false, "merged：普通的 LR sidecar 合并得了（不该返回 nil）")
        }
        let wasGreen = lightroomSidecar(label: "Green")
        // 拆成一个个命名的 let：CI 的 Xcode 16 类型检查比本机慢，长的 && 链会超时。
        let dropped: Data? = XMPSidecar.merged(wasGreen, rating: 3, label: nil, lastLabel: "Green")
        let droppedLabel: String? = dropped.flatMap { xmpValue($0, "xmp:Label") }
        let droppedRating: String? = dropped.flatMap { xmpValue($0, "xmp:Rating") }
        t.check(dropped != nil && droppedLabel == nil && droppedRating == "3",
                "merged：这次是可用（不带色标）、文件里还是上次我们写的 Green → 拿掉",
                "色标 \(droppedLabel ?? "无")、星级 \(droppedRating ?? "nil")")
        let userBlue: Data? = XMPSidecar.merged(lr, rating: 3, label: nil, lastLabel: "Green")
        let userLabel: String? = userBlue.flatMap { xmpValue($0, "xmp:Label") }
        t.check(userLabel == "Blue", "merged：文件里的色标是你后来在 LR 里改的 Blue → 留着", userLabel ?? "nil")
        let noLabel: Data? = XMPSidecar.merged(lightroomSidecar(label: nil), rating: -1, label: "Red", lastLabel: nil)
        let addedLabel: String? = noLabel.flatMap { xmpValue($0, "xmp:Label") }
        let addedRating: String? = noLabel.flatMap { xmpValue($0, "xmp:Rating") }
        t.check(addedLabel == "Red" && addedRating == "-1", "merged：原来没有色标的，废片加上 Red、星级 -1",
                "\(addedLabel ?? "nil") / \(addedRating ?? "nil")")

        // 读不全的写法：宁可不写
        let resource = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/" xmp:Rating="2">
           <xmpRights:WebStatement rdf:resource="https://example.com/license"/>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
        t.check(XMPSidecar.merged(resource, rating: 5, label: "Green", lastLabel: nil) == nil,
                "merged：带 rdf:resource 的（重写会变类型）→ nil，这张不写")
        let lang = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmp:Rating="2">
           <photoshop:Headline xml:lang="zh-CN">婚礼</photoshop:Headline>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
        t.check(XMPSidecar.merged(lang, rating: 5, label: "Green", lastLabel: nil) == nil,
                "merged：xml:lang 写在 rdf:li 以外的元素上 → nil")
        t.check(XMPSidecar.merged(Data("not xml <<<".utf8), rating: 5, label: "Green", lastLabel: nil) == nil,
                "merged：不是 XMP 的坏文件 → nil")
    }

    // MARK: - 同名另存

    private static func caseInsensitive(_ dir: URL) -> Bool {
        let probe = dir.appendingPathComponent("case-probe.tmp")
        FileManager.default.createFile(atPath: probe.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: probe) }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("CASE-PROBE.TMP").path)
    }

    private static func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    private static func namingCases(_ dir: URL, _ t: Tally) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ci = caseInsensitive(dir)
        for name in ["a.jpg", "B.jpg"] { fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data([1])) }

        let p1 = DeliveryNaming.plan(["a", "b", "c"], in: dir, overwrite: false)
        let want1 = ci ? ["a-2.jpg", "b-2.jpg", "c.jpg"] : ["a-2.jpg", "b.jpg", "c.jpg"]
        let renamed1 = ci ? 2 : 1
        t.check(names(p1.dests) == want1 && p1.renamed == renamed1,
                "目标里已有的另存 -2、旧文件不动（\(ci ? "大小写不敏感的卷：已有 B.jpg 也挡 b" : "大小写敏感的卷")）",
                "\(names(p1.dests)) 改名 \(p1.renamed)")
        let p2 = DeliveryNaming.plan(["x", "X", "x"], in: dir, overwrite: false)
        t.check(names(p2.dests) == ["x.jpg", "X-2.jpg", "x-3.jpg"] && p2.renamed == 0,
                "批内重名按小写比：x / X / x → x、X-2、x-3（不算「目标里已有」）", "\(names(p2.dests)) 改名 \(p2.renamed)")
        let p3 = DeliveryNaming.plan(["a", "a"], in: dir, overwrite: true)
        t.check(names(p3.dests) == ["a.jpg", "a-2.jpg"], "开了覆盖：目标里的 a.jpg 覆盖，批内第二个 a 照样 -2",
                "\(names(p3.dests))")
        fm.createFile(atPath: dir.appendingPathComponent("a-2.jpg").path, contents: Data([2]))
        let p4 = DeliveryNaming.plan(["a"], in: dir, overwrite: false)
        t.check(names(p4.dests) == ["a-3.jpg"] && p4.renamed == 1, "a.jpg、a-2.jpg 都在 → a-3", "\(names(p4.dests))")
        let p5 = DeliveryNaming.plan(["a", "c"], in: dir.appendingPathComponent("nonexistent"), overwrite: false)
        t.check(names(p5.dests) == ["a.jpg", "c.jpg"] && p5.renamed == 0, "目标文件夹还不存在：原名", "\(names(p5.dests))")
    }

    // MARK: - 截断 JPEG

    /// 一张真的 JPEG（噪声，几百 KB：熵编码数据比 64KB 长得多，里面的 FF 都带 00 填充）。
    static func noiseJPEG(width: Int, height: Int, seed: UInt64, properties: [CFString: Any] = [:]) -> Data? {
        var rng = SeededRandom(seed: seed)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var i = 0
        while i < pixels.count {
            let r = rng.next()
            pixels[i] = UInt8(truncatingIfNeeded: r)
            pixels[i + 1] = UInt8(truncatingIfNeeded: r >> 8)
            pixels[i + 2] = UInt8(truncatingIfNeeded: r >> 16)
            i += 4
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let image: CGImage = pixels.withUnsafeMutableBytes({ raw -> CGImage? in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space, bitmapInfo: info)
            return ctx?.makeImage()
        }) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 手写的最小 JPEG 结构：SOI、APP0、SOS 头、一段不含 FF 的「熵编码数据」，要不要 EOI 自己选。
    static func tinyJPEG(eoi: Bool) -> Data {
        var d = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        d.append(contentsOf: Array("JFIF".utf8) + [0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        d.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
        d.append(Data(repeating: 0x55, count: 1000))
        if eoi { d.append(contentsOf: [0xFF, 0xD9]) }
        return d
    }

    /// 尾巴：动态照片接在 EOI 后面的视频那种 —— 这里是不含 FF 的字节，长过 64KB。
    static func motionTail(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 0xFE) })
    }

    private static func truncationCases(_ dir: URL, _ t: Tally) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func probe(_ name: String, _ data: Data) -> Bool {
            let url = dir.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: data)
            return ImageLoader.jpegTruncated(url)
        }
        func tailHasEOI(_ data: Data) -> Bool {
            data.suffix(65536).range(of: Data([0xFF, 0xD9])) != nil
        }
        t.check(!probe("tiny-ok.jpg", tinyJPEG(eoi: true)), "小文件、最后有 EOI → 完整")
        t.check(probe("tiny-cut.jpg", tinyJPEG(eoi: false)), "小文件（整个都在最后 64KB 里）、没有 EOI → 截断")
        guard let big = noiseJPEG(width: 800, height: 800, seed: 11) else {
            t.check(false, "前提：编得出一张噪声 JPEG")
            return
        }
        let cut = big.prefix(big.count * 6 / 10)
        t.check(big.count > 200_000 && cut.count > 65536 && !tailHasEOI(cut),
                "前提：噪声 JPEG \(big.count) B，截到 \(cut.count) B 后最后 64KB 里没有 FF D9")
        t.check(!probe("big-ok.jpg", big), "完整的 JPEG → 完整（快路径：最后 64KB 里有 EOI）")
        t.check(probe("big-cut.jpg", Data(cut)), "截掉后 40% 的 JPEG → 截断（按段扫描走到文件尾没有 EOI）")
        let motion = big + motionTail(70_000)
        t.check(!tailHasEOI(motion), "前提：动态照片样本最后 64KB 里没有 FF D9")
        t.check(!probe("motion.jpg", motion), "动态照片（EOI 后面接了 70KB 视频）→ 完整（按段走到主图的 EOI）")
        // 主图截断、但 APP1 里嵌着一张完整的缩略图（自带 FF D8 … FF D9）：段长度跳过去，不能把缩略图的 EOI 当成主图的。
        let thumb = tinyJPEG(eoi: true)
        var payload = Data("Exif\0\0".utf8)
        payload.append(thumb)
        var withThumb = Data([0xFF, 0xD8, 0xFF, 0xE1])
        let length = payload.count + 2
        withThumb.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF)])
        withThumb.append(payload)
        withThumb.append(cut.dropFirst(2))
        t.check(!tailHasEOI(withThumb) && withThumb.range(of: Data([0xFF, 0xD9])) != nil,
                "前提：缩略图的 FF D9 在文件里、但不在最后 64KB")
        t.check(probe("thumb-cut.jpg", withThumb), "EXIF 里嵌着完整缩略图、主图截断 → 截断（跳过 APP1，不认缩略图的 EOI）")
        t.check(probe("upper-cut.JPG", Data(cut)), "后缀大写 .JPG 一样查")
        t.check(probe("cut.jpeg", Data(cut)), ".jpeg 一样查")
        t.check(!probe("cut.bmp", Data(cut)), "不是 jpg / jpeg 后缀的不查（解码已经成功了，别冤枉）")
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 0, count: 70_000))
        t.check(!probe("png-named.jpg", png), "叫 .jpg 其实不是 JPEG（看不懂的结构）→ 不算截断")
        t.check(!probe("four.jpg", Data([0xFF, 0xD8, 0xFF, 0xDA])), "不到 5 字节的 → 不算截断")
    }

    // MARK: - 同一个文件

    private static func sameFileCases(_ dir: URL, _ t: Tally) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.jpg")
        let b = dir.appendingPathComponent("b.jpg")
        fm.createFile(atPath: a.path, contents: Data("A".utf8))
        fm.createFile(atPath: b.path, contents: Data("B".utf8))
        let link = dir.appendingPathComponent("link.jpg")
        try? fm.createSymbolicLink(at: link, withDestinationURL: a)
        let hard = dir.appendingPathComponent("hard.jpg")
        try? fm.linkItem(at: a, to: hard)
        let linkDir = dir.deletingLastPathComponent().appendingPathComponent("same-link")
        try? fm.createSymbolicLink(at: linkDir, withDestinationURL: dir)

        t.check(WatermarkEngine.isSameFile(a, a), "同一个路径")
        let dotted = URL(fileURLWithPath: dir.path + "/./sub/../a.jpg")
        t.check(WatermarkEngine.isSameFile(dotted, a), "路径里带 . 和 ..", dotted.path)
        // 最后一段本身是指向原片的符号链接：isSameFile 比 stat 的设备号 + inode，stat 跟着链接走（以前 resourceValues
        // 不跟，这一种骗得过）。端到端 delivery_regression.py 另外验原片字节不变。
        t.check(WatermarkEngine.isSameFile(link, a), "指向原片的符号链接（最后一段是链接）")
        t.check(WatermarkEngine.isSameFile(linkDir.appendingPathComponent("a.jpg"), a), "经过符号链接的目录")
        t.check(WatermarkEngine.isSameFile(hard, a), "硬链接（同一个 inode，写它就是写原片）")
        if caseInsensitive(dir) {
            t.check(WatermarkEngine.isSameFile(dir.appendingPathComponent("A.JPG"), a), "大小写不同（大小写不敏感的卷）")
        } else {
            print("skip 大小写不同：这个卷分大小写，A.JPG 本来就是另一个文件")
        }
        t.check(!WatermarkEngine.isSameFile(a, b), "两个不同的文件")
        t.check(!WatermarkEngine.isSameFile(a, dir.appendingPathComponent("missing.jpg")), "输出文件还不存在")
    }

    // MARK: - 去 GPS

    /// GPS 还在不在：属性字典的 {GPS}、元数据树里 GPS 开头的标签（含 XMP 的 exif:GPS*）、文件字节里的 GPSLatitude。
    static func gpsTraces(_ url: URL) -> [String] {
        var found: [String] = []
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ["读不出来"] }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           props[kCGImagePropertyGPSDictionary] != nil {
            found.append("{GPS}")
        }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            var tags: [String] = []
            let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
            CGImageMetadataEnumerateTagsUsingBlock(meta, nil, options) { path, _ in
                let p = path as String
                if p.split(separator: ":").last?.hasPrefix("GPS") == true { tags.append(p) }
                return true
            }
            if !tags.isEmpty { found.append("元数据 \(tags.sorted().prefix(2).joined(separator: ","))") }
        }
        if let data = try? Data(contentsOf: url), data.range(of: Data("GPSLatitude".utf8)) != nil {
            found.append("字节里有 GPSLatitude")
        }
        return found
    }

    static func model(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else { return nil }
        return tiff[kCGImagePropertyTIFFModel] as? String
    }

    /// 只在 XMP 包里写了 GPS（exif:GPSLatitude，EXIF 里没有 GPS IFD）：把一个 APP1 XMP 段塞在 SOI 后面。
    static func withXMPOnlyGPS(_ jpeg: Data) -> Data {
        let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
        exif:GPSLatitude="31,13.83N" exif:GPSLongitude="121,28.42E"/></rdf:RDF></x:xmpmeta>
        """
        var payload = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        payload.append(Data(packet.utf8))
        var out = Data([0xFF, 0xD8, 0xFF, 0xE1])
        let length = payload.count + 2
        out.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF)])
        out.append(payload)
        out.append(jpeg.dropFirst(2))
        return out
    }

    private static func gpsCases(_ dir: URL, _ t: Tally) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 31.2304, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 121.4737, kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "SYNTH", kCGImagePropertyTIFFModel: "SYN-1"]
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:03:21 10:00:00"]
        let withGPS: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyTIFFDictionary: tiff,
                                        kCGImagePropertyExifDictionary: exif]
        guard let exifGPS = noiseJPEG(width: 320, height: 240, seed: 21, properties: withGPS),
              let plain = noiseJPEG(width: 320, height: 240, seed: 22,
                                    properties: [kCGImagePropertyTIFFDictionary: tiff]) else {
            t.check(false, "前提：编得出带 GPS 的 JPEG")
            return
        }
        let srcEXIF = dir.appendingPathComponent("gps-exif.jpg")
        let srcXMP = dir.appendingPathComponent("gps-xmp-only.jpg")
        fm.createFile(atPath: srcEXIF.path, contents: exifGPS)
        fm.createFile(atPath: srcXMP.path, contents: withXMPOnlyGPS(plain))
        let tracesEXIF = gpsTraces(srcEXIF)
        let tracesXMP = gpsTraces(srcXMP)
        t.check(tracesEXIF.contains("{GPS}"), "前提：EXIF 里写了 GPS 的原片查得出来", "\(tracesEXIF)")
        t.check(!tracesXMP.isEmpty, "前提：只在 XMP 包里写了 GPS 的原片查得出来", "\(tracesXMP)")

        var strip = DeliveryOptions()
        strip.stripGPS = true
        var keep = DeliveryOptions()
        keep.stripGPS = false
        // 精华 Top N 出厂默认就是去 GPS（DeliveryOptions.highlights）：默认值改了也要在这里露馅。
        t.check(DeliveryOptions.highlights(legacyMaxPixel: 2048).stripGPS, "精华 Top N 的出厂默认是去 GPS")
        t.check(!DeliveryOptions().stripGPS, "水印页的出厂默认不去 GPS（和以前一样）")

        func viaBatch(_ src: URL, _ name: String, _ options: DeliveryOptions) -> URL? {
            let out = dir.appendingPathComponent(name)
            if case .ok = BatchStore.writeJPEG(from: src, to: out, options: options) { return out }
            return nil
        }
        func viaWatermark(_ src: URL, _ name: String, _ options: DeliveryOptions) -> URL? {
            let out = dir.appendingPathComponent(name)
            do {
                try WatermarkEngine.export(source: src, to: out, signature: nil, config: WatermarkEngine.Config(),
                                           options: options)
                return out
            } catch {
                return nil
            }
        }
        typealias Exporter = (URL, String, DeliveryOptions) -> URL?
        let paths: [(String, Exporter)] = [("导出 JPG / 精华（BatchStore.writeJPEG）", viaBatch),
                                           ("水印页（WatermarkEngine.export）", viaWatermark)]
        for (k, entry) in paths.enumerated() {
            let (label, export) = entry
            if let out = export(srcEXIF, "\(k)-exif-strip.jpg", strip) {
                let left = gpsTraces(out)
                t.check(left.isEmpty, label + "：去 GPS → EXIF 里的 GPS 没了", left.isEmpty ? "" : "还剩 \(left)")
                t.check(model(out) == "SYN-1", label + "：去 GPS 不连带去掉机型", model(out) ?? "nil")
            } else {
                t.check(false, label + "：去 GPS 导出失败")
            }
            if let out = export(srcEXIF, "\(k)-exif-keep.jpg", keep) {
                t.check(gpsTraces(out).contains("{GPS}"), label + "：对照组不去 GPS → GPS 还在（证明上面查得出来）",
                        "\(gpsTraces(out))")
            } else {
                t.check(false, label + "：不去 GPS 的导出失败")
            }
            if let out = export(srcXMP, "\(k)-xmp-strip.jpg", strip) {
                let left = gpsTraces(out)
                t.check(left.isEmpty, label + "：GPS 只在原片的 XMP 包里 → 去 GPS 以后也没了",
                        left.isEmpty ? "" : "还剩 \(left)")
            } else {
                t.check(false, label + "：XMP 里带 GPS 的原片导出失败")
            }
        }
    }
}
