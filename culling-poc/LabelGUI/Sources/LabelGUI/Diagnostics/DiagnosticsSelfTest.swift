import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 诊断这一组的无头自检（审查 D03）：LABELGUI_DATA_DIR=<临时> LabelGUI --diag-selftest [<photo_dir>]
///   D 失败原因：盘不支持废纸篓、没权限、只读盘、盘满、EPERM；原因汇总；废纸篓移走一半；不限体积那条路逐字节和以前一样、
///     写不进去报「没有权限」；writeJPEG 原片不在 / 解不开；水印页拿到真原因
/// 只写 LABELGUI_DATA_DIR 下面（照片文件夹参数只读：拿第一张 JPG 再核对一次逐字节）。
enum DiagnosticsSelfTest {
    @MainActor
    static func run() -> Never {
        CollageCLI.requireIsolatedDataDir("--diag-selftest", "会在数据目录里建临时文件夹")
        let fm = FileManager.default
        let work = appDataDir.appendingPathComponent("diag-selftest", isDirectory: true)
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let check = Check()

        reasonChecks(work, check)

        check.unlockAll()
        try? fm.removeItem(at: work)
        let failures = check.failures
        print(failures.isEmpty ? "诊断自检全部通过" : "诊断自检 \(failures.count) 项失败：\(failures.joined(separator: "；"))")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// 断言 + 记下改过权限的目录（收尾全部改回 755 再删）。
    final class Check {
        private(set) var failures: [String] = []
        private var locked: [URL] = []

        func callAsFunction(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
            let shown = ok ? "" : "：" + detail()
            print((ok ? "  ok   " : "  FAIL ") + label + shown)
            if !ok { failures.append(label) }
        }

        func lock(_ url: URL, _ mode: Int16) {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            locked.append(url)
        }

        func unlockAll() {
            for url in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            locked = []
        }
    }

    // MARK: D 失败原因

    @MainActor
    private static func reasonChecks(_ work: URL, _ check: Check) {
        print("D. 逐张失败说原因")
        let cocoa = { (code: Int) in NSError(domain: NSCocoaErrorDomain, code: code) }
        let posix = { (code: Int32) in NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let cases: [(String, Error, Bool, String)] = [
            ("NSFeatureUnsupportedError（移到废纸篓）", cocoa(NSFeatureUnsupportedError), true, "不支持废纸篓"),
            ("ENOTSUP（移到废纸篓）", posix(ENOTSUP), true, "不支持废纸篓"),
            ("NSFileWriteNoPermissionError", cocoa(NSFileWriteNoPermissionError), false, "没有权限"),
            ("EACCES", posix(EACCES), false, "没有权限"),
            ("EROFS", posix(EROFS), false, "只读"),
            ("NSFileWriteVolumeReadOnlyError", cocoa(NSFileWriteVolumeReadOnlyError), false, "只读"),
            ("NSFileWriteOutOfSpaceError", cocoa(NSFileWriteOutOfSpaceError), false, "盘满了"),
            ("ENOSPC", posix(ENOSPC), false, "盘满了"),
            ("EPERM", posix(EPERM), false, "隐私与安全性"),
        ]
        for (label, error, trash, want) in cases {
            let text = Diagnostics.describeIO(error, trash: trash)
            check(text.contains(want), "\(label) → 「\(want)」", text)
        }
        check(Diagnostics.reasonSummary([]) == "", "没有原因 = 空")
        check(Diagnostics.reasonSummary(["没有权限", "没有权限"]) == "；原因：没有权限", "一种原因不数张数")
        let mixed = Diagnostics.reasonSummary(["没有权限", "盘满了", "没有权限"], unit: "个")
        check(mixed == "；原因：没有权限（2 个）、盘满了（1 个）", "几种原因分开数", mixed)

        let partial = BatchStore.TrashPartial(id: "DSCF0001", moved: ["DSCF0001.RAF"], left: ["DSCF0001.JPG"])
        let note = BatchStore.trashFailureNote(trashed: 3, failed: ["DSCF0001", "DSCF0002"],
                                               reasons: ["DSCF0001": Diagnostics.describeIO(cocoa(NSFileWriteNoPermissionError)),
                                                         "DSCF0002": "文件不见了（外置盘没挂上，或者已经被别处移走）"],
                                               partial: [partial])
        check(note.hasPrefix("移到废纸篓: 3 成功, 2 失败 (DSCF0001, DSCF0002)；原因：没有权限（1 张）、文件不见了"),
              "废纸篓：张数、前几张、原因", note)
        check(note.contains("其中 1 张只移走了一部分（DSCF0001：DSCF0001.RAF 已在废纸篓，DSCF0001.JPG 还在原处）"),
              "废纸篓移走一半的单独说", note)

        // 不限体积那条路改成先在内存里编码再原子写：字节要和以前直接写文件一模一样。
        let dir = work.appendingPathComponent("encode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let image = gradient(640, 427) else {
            check(false, "造一张渐变图")
            return
        }
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "diag"]]
        let newPath = dir.appendingPathComponent("new.jpg")
        let outcome = DeliveryEncoder.write(to: newPath, quality: 0.87, maxBytes: nil) { out, q in
            var p = props
            p[kCGImageDestinationLossyCompressionQuality] = q
            CGImageDestinationAddImage(out, image, p as CFDictionary)
        }
        let oldPath = dir.appendingPathComponent("old.jpg")
        let oldOK = legacyWrite(image, props: props, quality: 0.87, to: oldPath)
        let same = oldOK && (try? Data(contentsOf: newPath)) == (try? Data(contentsOf: oldPath))
        check(isOK(outcome) && same, "不限体积：和以前直接写文件逐字节一样（合成图）")
        if let photo = firstJPEG(), let src = CGImageSourceCreateWithURL(photo as CFURL, nil),
           let real = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let realProps = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
            let a = dir.appendingPathComponent("real-new.jpg")
            let b = dir.appendingPathComponent("real-old.jpg")
            let realOutcome = DeliveryEncoder.write(to: a, quality: 0.9, maxBytes: nil) { out, q in
                var p = realProps
                p[kCGImageDestinationLossyCompressionQuality] = q
                CGImageDestinationAddImage(out, real, p as CFDictionary)
            }
            let realSame = legacyWrite(real, props: realProps, quality: 0.9, to: b)
                && (try? Data(contentsOf: a)) == (try? Data(contentsOf: b))
            check(isOK(realOutcome) && realSame, "不限体积：和以前逐字节一样（\(photo.lastPathComponent)，带原片 EXIF）")
        }

        // 写不进去的目录：两条路都报「没有权限」。
        let readOnly = dir.appendingPathComponent("只读", isDirectory: true)
        try? FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        check.lock(readOnly, 0o555)
        for (label, cap) in [("不限体积", nil), ("限体积", 50_000)] as [(String, Int?)] {
            let result = DeliveryEncoder.write(to: readOnly.appendingPathComponent("x.jpg"), quality: 0.8, maxBytes: cap) { out, q in
                CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            }
            check(failure(result)?.contains("没有权限") == true, "\(label)写进只读目录：失败带「没有权限」", "\(result)")
        }

        // writeJPEG：原片不在了 / 解不开 / 写不进去。
        let options = DeliveryOptions()
        let missing = BatchStore.writeJPEG(from: dir.appendingPathComponent("没有这张.JPG"), to: dir.appendingPathComponent("m.jpg"),
                                           options: options)
        check(failure(missing)?.contains("原片不在了") == true, "writeJPEG：原片不在了", "\(missing)")
        let garbage = dir.appendingPathComponent("坏的.JPG")
        try? Data("不是 JPEG".utf8).write(to: garbage)
        let broken = BatchStore.writeJPEG(from: garbage, to: dir.appendingPathComponent("g.jpg"), options: options)
        check(failure(broken)?.contains("解不开原片") == true, "writeJPEG：解不开原片", "\(broken)")
        let blocked = BatchStore.writeJPEG(from: oldPath, to: readOnly.appendingPathComponent("w.jpg"), options: options)
        check(failure(blocked)?.contains("没有权限") == true, "writeJPEG：导出目录写不进去 → 没有权限", "\(blocked)")
        do {
            try WatermarkEngine.export(source: oldPath, to: readOnly.appendingPathComponent("wm.jpg"), signature: nil,
                                       config: WatermarkEngine.Config(), options: options)
            check(false, "水印页写进只读目录应该失败")
        } catch {
            check(error.localizedDescription.contains("没有权限"), "水印页的「首个原因」拿到真原因", error.localizedDescription)
        }
    }

    // MARK: 小工具

    private static func isOK(_ outcome: DeliveryEncoder.Outcome) -> Bool {
        if case .ok = outcome { return true }
        return false
    }

    private static func failure(_ outcome: DeliveryEncoder.Outcome) -> String? {
        if case .failed(let why) = outcome { return why }
        return nil
    }

    /// 改之前不限体积那条路的写法（CGImageDestinationCreateWithURL + Finalize），拿来逐字节对照。
    private static func legacyWrite(_ image: CGImage, props: [CFString: Any], quality: Double, to url: URL) -> Bool {
        guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        var p = props
        p[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(out, image, p as CFDictionary)
        return CGImageDestinationFinalize(out)
    }

    private static func gradient(_ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let colors = [CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)]
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])
        else { return nil }
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return ctx.makeImage()
    }

    /// 命令行给了照片文件夹：拿第一张 JPG（只读）。
    private static func firstJPEG() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--diag-selftest"), args.count > i + 1, !args[i + 1].hasPrefix("--") else { return nil }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().first { ["jpg", "jpeg"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .map { dir.appendingPathComponent($0) }
    }
}
