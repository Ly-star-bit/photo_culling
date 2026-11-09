import Foundation
import JavaScriptCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 选片确认表自检（LabelGUI --proof-selftest，不读写数据目录、不开界面）
//
// 1. 页面脚本：用 JavaScriptCore 跑 ProofSheetPage 生成的那段 ES5（给 document / localStorage / clipboard 做个假的，
//    元素按 HTML 里真有的 id 建 —— 脚本找一个不存在的 id 就会在这里炸），点选、超套餐、写备注、复制、重开页面读回来。
// 2. 复制出来的那段文字原样喂给 ClientReply.resolve：认出的照片和备注要和页面上点的一样（来回一趟）。
// 3. ClientReply 的备注写法：「DSCF7207 修 3 处」不再把第 3 张认进来、「7207 7208」还是两张、全角标点原样留着……
enum ProofSheetSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            print("PASS " + name)
        } else {
            failures += 1
            let extra = detail()
            print("FAIL " + name + (extra.isEmpty ? "" : " → " + extra))
        }
    }

    static func run() -> Never {
        pageScript()
        replyNotes()
        extraChecks()
        print(failures == 0 ? "确认表自检全部通过" : "确认表自检 \(failures) 条没过")
        exit(failures == 0 ? 0 : 1)
    }

    /// 后面加的检查（同一个 --proof-selftest 里跑）。
    private static func extraChecks() {
        watermarkChecks()
        multiPhotoLines()
        markerChecks()
        leadingSignChecks()
        greetingChecks()
        blankWatermarkChecks()
        retouchLandedChecks()
        numberedNoteChecks()
        dashAndRangeChecks()
    }

    // MARK: 编号开头的修图要求（优化分析 NR2：「12 去路人」「12 备注：去路人」以前备注丢了）

    private static func numberedNoteChecks() {
        let all = items()
        let header = "\(ProofSheetPage.header) \(bigSheet.id)\n"
        func expect(_ text: String, ids: [String], notes: [String: String], numbered: [String: String] = [:],
                    _ name: String) {
            let r = ClientReply.resolve(text, items: all, sheets: [bigSheet])
            let ok = r.ids == ids && r.notes == notes && r.numberedNotes == numbered
            check(ok, name, "认出 \(r.ids.joined(separator: " ")) · 备注 \(r.notes) · 按编号 \(r.numberedNotes) · 没认出 \(r.unknown)")
        }
        // 显式写了「备注」：一定收成备注，不算「按编号认的」。
        expect("12 备注：去路人", ids: ["DSCF7212"], notes: ["DSCF7212": "去路人"], "「12 备注：去路人」：收成备注")
        expect(header + "12 备注：修 3 处\n", ids: ["DSCF7212"], notes: ["DSCF7212": "修 3 处"],
               "带表号、「备注：」后面带数字也整段收（显式写的）")
        expect("12备注：-1档", ids: ["DSCF7212"], notes: ["DSCF7212": "-1档"], "紧贴着写的「12备注：-1档」：负号留着")
        // 只凭编号：后面不带数字 = 备注，记下是按编号认的。
        expect("12 去路人", ids: ["DSCF7212"], notes: ["DSCF7212": "去路人"], numbered: ["DSCF7212": "12"],
               "「12 去路人」：收成备注，记成按编号认的")
        expect("12去路人", ids: ["DSCF7212"], notes: ["DSCF7212": "去路人"], numbered: ["DSCF7212": "12"],
               "紧贴着写的「12去路人」也一样")
        expect("12 去路人，7208 瘦脸", ids: ["DSCF7212", "DSCF7208"], notes: ["DSCF7212": "去路人", "DSCF7208": "瘦脸"],
               numbered: ["DSCF7212": "12"], "编号开头、后面又跟一张文件号：各带各的，只有编号那条算按编号认的")
        expect("12 去路人\nDSCF7212 瘦脸", ids: ["DSCF7212"], notes: ["DSCF7212": "瘦脸"],
               "同一张后面用文件名又写了一次：按最后那次，不再算按编号认的")
        // 反例：两个以上编号、后面带数字的，照旧都是要的照片、不当备注。
        expect("12、35 都要", ids: ["DSCF7212", "DSCF7235"], notes: [:], "反例「12、35 都要」：两张都要、没有备注")
        expect("12、35、38 都要", ids: ["DSCF7212", "DSCF7235", "DSCF7238"], notes: [:], "反例「12、35、38 都要」：三张都要")
        expect("12 35、38 都要", ids: ["DSCF7212", "DSCF7235", "DSCF7238"], notes: [:], "反例「12 35、38 都要」：三张都要")
        expect("12 还有 35 瘦脸", ids: ["DSCF7212", "DSCF7235"], notes: [:], "反例「12 还有 35 瘦脸」：后面带数字，两张都要、不当备注")
        expect("12 修 3 处", ids: ["DSCF7212", "DSCF7203"], notes: [:],
               "反例「12 修 3 处」：后面带数字拿不准，照旧都当要的照片（预览里看得见第 3 张）")
        expect("7207 去路人，3 处要修", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人，3 处要修"],
               "文件号开头那行里的「3 处」：编号不拿来切段，整句还是 7207 的备注")
        // 编号也对得上文件号（表上 120 张以上）：照旧说不准、不带备注。
        let many = (1...130).map { item(String(format: "IMG_%04d", $0 + 1000)) } + [item("DSCF0120")]
        let manySheet = ProofSheet(id: "20261104-080000", date: Date(), scope: "精选 + 可用", ids: many.map(\.id))
        let ambiguous = ClientReply.resolve("120 备注：去路人", items: many, sheets: [manySheet])
        check(ambiguous.notes.isEmpty && ambiguous.unknown.contains { $0.hasPrefix("120") },
              "「120 备注：…」文件号、编号对不上：照旧说不准、不带备注", "\(ambiguous.ids) \(ambiguous.unknown)")
        // 没导出过确认表：「12 去路人」认不出 12，照旧列在没认出、不带备注。
        let noSheet = ClientReply.resolve("12 去路人", items: all, sheets: [])
        check(noSheet.ids.isEmpty && noSheet.notes.isEmpty && noSheet.numbersWithoutSheet,
              "没有确认表：「12 去路人」认不了编号、不带备注", "\(noSheet.ids) \(noSheet.notes) \(noSheet.unknown)")

        // 导入预览：按编号认的备注单列一行（橙色那行的开头），「备注：」的不进这一行。
        let mixed = ClientReply.resolve("12 去路人\nDSCF7207 备注：瘦脸", items: all, sheets: [bigSheet])
        let lines = ClientReply.summary(mixed, existing: [])
        let numberedLine = lines.first { $0.hasPrefix(ClientReply.numberedNotePrefix) } ?? ""
        check(lines.contains { $0.hasPrefix("带备注 2 张：") } && numberedLine.contains("1 张")
              && numberedLine.contains("12 → DSCF7212「去路人」") && !numberedLine.contains("DSCF7207"),
              "导入预览：带备注 2 张，另有一行说其中 1 张按编号认（12 → DSCF7212），「备注：」那张不在这行", lines.joined(separator: " / "))
        let explicit = ClientReply.summary(ClientReply.resolve("12 备注：去路人", items: all, sheets: [bigSheet]), existing: [])
        check(!explicit.contains { $0.hasPrefix(ClientReply.numberedNotePrefix) }, "只有「备注：」的：没有按编号那一行",
              explicit.joined(separator: " / "))
    }

    // MARK: 「7207-去路人」「7207~7215」、破折号（优化分析 NR2）

    private static func dashAndRangeChecks() {
        let all = items()
        func expect(_ text: String, pool: [BatchItem]? = nil, sheets: [ProofSheet]? = nil, ids: [String],
                    notes: [String: String], _ name: String) {
            let r = ClientReply.resolve(text, items: pool ?? all, sheets: sheets ?? [bigSheet])
            let ok = r.ids == ids && r.notes == notes
            check(ok, name, "认出 \(r.ids.joined(separator: " ")) · 备注 \(r.notes) · 没认出 \(r.unknown)")
        }
        expect("7207-去路人", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人"], "「7207-去路人」：- 前面切开，备注不带 -")
        expect("DSCF7207-去路人", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人"], "「DSCF7207-去路人」")
        expect("DSCF7207～瘦脸", ids: ["DSCF7207"], notes: ["DSCF7207": "瘦脸"], "全角波浪号「DSCF7207～瘦脸」")
        expect("7207——去路人", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人"], "「7207——去路人」：破折号不进备注")
        expect("DSCF7207 ——去路人", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人"],
               "「DSCF7207 ——去路人」：破折号后面不是数字，不进备注")
        expect("DSCF7207 -1档", ids: ["DSCF7207"], notes: ["DSCF7207": "-1档"], "反例「DSCF7207 -1档」：负号后面是数字，留着")
        expect("7207-去路人，7208-瘦脸", ids: ["DSCF7207", "DSCF7208"], notes: ["DSCF7207": "去路人", "DSCF7208": "瘦脸"],
               "一行两张都用 - 连着备注：各带各的")
        expect("7207 去路人，7208-瘦脸", ids: ["DSCF7207", "DSCF7208"], notes: ["DSCF7207": "去路人", "DSCF7208": "瘦脸"],
               "后面那张用 - 连着：不被吞进前面那张的备注")
        // 反例：另存名 DSCF7207-2（- 后面是数字）不切。
        let saved = all + [item("DSCF7207-2")]
        expect("DSCF7207-2", pool: saved, ids: ["DSCF7207-2"], notes: [:], "反例「DSCF7207-2」（另存名）：整个认，不切成 7207 和 2")
        expect("DSCF7207-2 去路人", pool: saved, ids: ["DSCF7207-2"], notes: ["DSCF7207-2": "去路人"], "「DSCF7207-2 去路人」：备注记在另存的那张上")
        let notHere = ClientReply.resolve("DSCF7207-2", items: all, sheets: [bigSheet])
        check(notHere.ids.isEmpty && notHere.unknown == ["DSCF7207-2"], "这一场没有 DSCF7207-2：整个列在没认出，不悄悄认成 7207",
              "\(notHere.ids) \(notHere.unknown)")
        // 反例：精修师改的名「DSCF7207-修.jpg」（这一场没有这个文件）：- 后面是带扩展名的文件名，不切成 7207 + 备注「修.jpg」，
        // 照旧整个列在没认出（delivery_ledger_regression 的 F 段同一条）。
        let retouched = ClientReply.resolve("DSCF7207-修.jpg\nDSCF7208-修图", items: all, sheets: [bigSheet])
        check(retouched.ids == ["DSCF7208"] && retouched.notes == ["DSCF7208": "修图"] && retouched.unknown == ["DSCF7207-修.jpg"],
              "反例「DSCF7207-修.jpg」：带扩展名的改名不切、进没认出；「DSCF7208-修图」照旧切成备注",
              "认出 \(retouched.ids) · 备注 \(retouched.notes) · 没认出 \(retouched.unknown)")
        // 反例：文件名本身是「数字-汉字」（001-婚礼.JPG），001 又是另一张的文件号：整行是文件名，不切。
        let wedding = [item("DSCF0001"), item("001-婚礼")]
        expect("001-婚礼.JPG", pool: wedding, sheets: [], ids: ["001-婚礼"], notes: [:], "反例「001-婚礼.JPG」：整行是文件名，不切")
        expect("001-婚礼.JPG 黑白", pool: wedding, sheets: [], ids: ["001-婚礼"], notes: ["001-婚礼": "黑白"],
               "「001-婚礼.JPG 黑白」：整个文件名带备注")

        // 范围：表上编号够不着，两头都是全场唯一的文件号 → 按文件号区间认。
        let span = (7207...7215).map { String(format: "DSCF%d", $0) }
        expect("7207~7215", ids: span, notes: [:], "「7207~7215」：表上只有 40 张够不着，按文件号区间认 9 张")
        expect("7207-7215", ids: span, notes: [:], "「7207-7215」一样")
        expect("7207～7215", ids: span, notes: [:], "全角「7207～7215」一样")
        expect("7207-7215", sheets: [], ids: span, notes: [:], "没导出过确认表：一样按文件号区间认")
        let gappy = all.filter { $0.id != "DSCF7210" }
        expect("7207-7215", pool: gappy, ids: span.filter { $0 != "DSCF7210" }, notes: [:], "区间里缺一张（删掉了）：其余照认")
        // 反例：12-15 表上够得着，照旧按编号；两头有一头不是唯一的文件号、表上够得着一部分的，拿不准 → 没认出。
        expect("12-15", ids: ["DSCF7212", "DSCF7213", "DSCF7214", "DSCF7215"], notes: [:], "反例「12-15」：表上够得着，照旧按编号")
        let twins = all + [item("IMG_7215")]
        let twin = ClientReply.resolve("7207-7215", items: twins, sheets: [bigSheet])
        check(twin.ids.isEmpty && twin.unknown == ["7207-7215"], "反例：7215 有两张（两台机身）：拿不准，整条进没认出",
              "\(twin.ids) \(twin.unknown)")
        let manyItems = (1...130).map { item(String(format: "IMG_%04d", $0 + 1000)) } + [item("DSCF0125"), item("DSCF0135")]
        let manySheet = ProofSheet(id: "20261104-080000", date: Date(), scope: "精选 + 可用", ids: manyItems.map(\.id))
        let partial = ClientReply.resolve("125-135", items: manyItems, sheets: [manySheet])
        check(partial.ids.isEmpty && partial.unknown == ["125-135"], "反例：表上够得着一部分（130 张）：拿不准，整条进没认出",
              "\(partial.ids) \(partial.unknown)")
    }

    // MARK: 精修要求.csv 按实际落地的文件名写（审查：另存 -2 的指到目标里别的照片、取消了也照样列着）

    private static func retouchLandedChecks() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("proof-retouch-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let shoot = dir.appendingPathComponent("shoot")
        let dest = dir.appendingPathComponent("精修")
        try? fm.createDirectory(at: shoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let mine = shoot.appendingPathComponent("DSCF7207.RAF")
        let other = shoot.appendingPathComponent("DSCF7208.RAF")
        try? Data("这一单的 7207".utf8).write(to: mine)
        try? Data("这一单的 7208".utf8).write(to: other)
        // 精修文件夹是几单共用的：里面已经有上一单的 DSCF7207.RAF（机身计数器重复）。
        try? Data("上一单的 7207".utf8).write(to: dest.appendingPathComponent("DSCF7207.RAF"))
        func shot(_ id: String, _ url: URL) -> OriginalsCopier.Shot {
            OriginalsCopier.Shot(id: id, rawPath: url.path, decodePath: url.path)
        }
        let first = OriginalsCopier.copy(shot("DSCF7207", mine), to: dest, cancel: AnalysisEngine.CancelFlag())
        check(first.landedName == "DSCF7207-2.RAF" && first.renamed && first.copied == 1,
              "目标里有同名不同内容的：另存 -2，landedName 是「DSCF7207-2.RAF」", "\(first)")
        let again = OriginalsCopier.copy(shot("DSCF7207", mine), to: dest, cancel: AnalysisEngine.CancelFlag())
        check(again.landedName == "DSCF7207-2.RAF" && again.copied == 0 && again.skipped == 1,
              "再复制一次（目标里 -2 那张一模一样）：跳过，landedName 还是 -2 的名字", "\(again)")
        let stop = AnalysisEngine.CancelFlag()
        stop.set()
        let cancelled = OriginalsCopier.copy(shot("DSCF7208", other), to: dest, cancel: stop)
        check(cancelled.cancelled && cancelled.landedName == nil && !fm.fileExists(atPath: dest.appendingPathComponent("DSCF7208.RAF").path),
              "复制时取消：没落地，landedName = nil", "\(cancelled)")
        let gone = OriginalsCopier.copy(shot("DSCF7209", shoot.appendingPathComponent("DSCF7209.RAF")), to: dest,
                                        cancel: AnalysisEngine.CancelFlag())
        check(gone.landedName == nil && !gone.failed.isEmpty, "原片读不出来：landedName = nil", "\(gone)")

        let noted = [OriginalsCopier.NotedShot(id: "DSCF7207", note: "去路人"),
                     OriginalsCopier.NotedShot(id: "DSCF7208", note: "瘦脸"),
                     OriginalsCopier.NotedShot(id: "DSCF7210", note: "黑白")]
        let plan = OriginalsCopier.retouchRows(noted, landed: ["DSCF7207": "DSCF7207-2.RAF", "DSCF7210": "DSCF7210.RAF"])
        let wantRows = [OriginalsCopier.RetouchRow(file: "DSCF7207-2.RAF", note: "去路人"),
                        OriginalsCopier.RetouchRow(file: "DSCF7210.RAF", note: "黑白")]
        check(plan.rows == wantRows && plan.missing == 1,
              "精修要求.csv 只写落了地的、用实际文件名（-2），取消 / 没复制成的不写", "\(plan)")
        let note = OriginalsCopier.retouchNote("写了 精修要求.csv（2 张的客户备注）", missing: plan.missing) ?? ""
        check(note == "写了 精修要求.csv（2 张的客户备注）；带备注的 1 张没复制成，没写进精修要求.csv",
              "状态栏说几张带备注的没写进去", note)
        check(OriginalsCopier.retouchNote(nil, missing: 3) == "带备注的 3 张没复制成，没写进精修要求.csv"
              && OriginalsCopier.retouchNote(nil, missing: 0) == nil, "一张都没复制成：只说没写进去；没有备注：不说")
    }

    // MARK: 水印画不上东西就不放（审查：只开 EXIF 模板文字、原片读不到时报「带水印」却是干净的图）

    private static func blankWatermarkChecks() {
        var template = WatermarkEngine.Config()
        template.signatureEnabled = false
        template.exifText.enabled = true
        template.exifText.customText = ""
        guard let mark = ProofWatermark.make(config: template, signature: nil),
              let base = solid(800, 533, gray: 100.0 / 255) else {
            check(false, "只有 EXIF 模板文字也做得出角标")
            return
        }
        check(mark.needsOriginalEXIF && mark.skipReason.contains("原片"), "只有 EXIF 模板文字：标出来要读原片", mark.skipReason)
        check(mark.apply(to: base, original: "") == nil, "模板文字、没给原片：画不上 = nil（不交回干净的小样）")
        check(mark.apply(to: base, original: "/nonexistent/proof-selftest/DSCF7207.RAF") == nil,
              "模板文字、原片读不到（外接盘没插）：nil")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proof-blank-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bare = dir.appendingPathComponent("bare.jpg")
        let tagged = dir.appendingPathComponent("tagged.jpg")
        let preview = dir.appendingPathComponent("preview.jpg")
        guard let big = solid(1200, 800, gray: 0.4), writeJPEG(big, to: bare), writeJPEG(big, to: preview),
              let dest = CGImageDestinationCreateWithURL(tagged as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            check(false, "造得出原片")
            return
        }
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T50"]
        CGImageDestinationAddImage(dest, big, [kCGImagePropertyTIFFDictionary: tiff] as CFDictionary)
        check(CGImageDestinationFinalize(dest), "写得出带机身型号的原片")
        check(mark.apply(to: base, original: bare.path) == nil, "模板文字、原片在但没有 EXIF：nil")
        if let drawn = mark.apply(to: base, original: tagged.path) {
            check(changed(pixels(base), pixels(drawn), width: 800, height: 533) != nil, "原片有机身型号：照样画上「FUJIFILM X-T50」")
        } else {
            check(false, "原片有机身型号：照样画上")
        }
        check(BatchStore.contactSheetJPEG(path: preview.path, watermark: mark, original: "") == nil,
              "确认表里那一张：画不上就不放（contactSheetJPEG = nil）")
        var literal = template
        literal.exifText.template = "小何摄影"
        check(ProofWatermark.make(config: literal, signature: nil)?.apply(to: base, original: "") != nil,
              "模板里只有字、没有占位符：不用原片也画得上")
        // 签名比画面还高（被跳过）、又没开文字：一样什么都没画。
        var sigOnly = WatermarkEngine.Config()
        sigOnly.exifText.enabled = false
        if let tall = whiteSignature(10, 2000), let skipped = ProofWatermark.make(config: sigOnly, signature: tall) {
            check(!skipped.needsOriginalEXIF && skipped.apply(to: base, original: "") == nil, "签名太高被跳过、没开文字：nil")
        } else {
            check(false, "造得出很高的签名")
        }
    }

    // MARK: 寒暄行带全角逗号不当成 CSV（审查：按行写的备注全丢）

    private static func greetingChecks() {
        let all = items()
        func resolve(_ text: String) -> ClientReply.Resolution { ClientReply.resolve(text, items: all, sheets: [bigSheet]) }
        func detail(_ r: ClientReply.Resolution) -> String {
            "认出 \(r.ids) · 备注 \(r.notes) · 表格列 \(r.tableColumns ?? []) · 没认出 \(r.unknown)"
        }
        let hello = resolve("你好，选好了\nDSCF7207，去路人\nDSCF7210，黑白")
        check(hello.ids == ["DSCF7207", "DSCF7210"] && hello.notes == ["DSCF7207": "去路人", "DSCF7210": "黑白"]
              && hello.tableColumns == nil, "「你好，选好了」开头、一行一张带要求：按行认、备注都在（不当成表格）", detail(hello))
        let three = resolve("你好，选好了，谢谢\nDSCF7207，去路人，瘦脸\nDSCF7210，黑白，亮一点")
        check(three.ids == ["DSCF7207", "DSCF7210"] && three.notes == ["DSCF7207": "去路人，瘦脸", "DSCF7210": "黑白，亮一点"]
              && three.tableColumns == nil, "寒暄两个逗号、每行三段：照样按行认、备注原样", detail(three))
        let csv = resolve("文件名,备注\nＤＳＣＦ７２０７,瘦脸\nDSCF7208,黑白\n")
        check(csv.ids == ["DSCF7207", "DSCF7208"] && csv.notes.isEmpty && csv.tableColumns == ["文件名"],
              "真的 CSV（半角逗号）照旧当表格认，全角的文件名格子也认", detail(csv))
    }

    // MARK: 备注开头客户自己写的 - ~ 留着（审查：「-1档」读回成「1档」）

    private static func leadingSignChecks() {
        let all = items()
        let header = "\(ProofSheetPage.header) \(bigSheet.id)\n"
        func expect(_ text: String, note: String, _ name: String) {
            let r = ClientReply.resolve(text, items: all, sheets: [bigSheet])
            check(r.ids == ["DSCF7207"] && r.notes == ["DSCF7207": note], name,
                  "认出 \(r.ids) · 备注 \(r.notes) · 没认出 \(r.unknown)")
        }
        expect(header + "DSCF7207 \(ProofSheetPage.noteMarker)-1档曝光\n", note: "-1档曝光", "「备注：-1档曝光」的负号留着")
        expect("DSCF7207备注：-1档", note: "-1档", "紧贴着写的「备注：」也只去掉记号自己")
        expect("DSCF7207 备注 ~0.5EV", note: "~0.5EV", "「备注」后面没冒号：~ 留着")
        expect("7207 -0.5EV", note: "-0.5EV", "微信写法「7207 -0.5EV」：负号留着")
        expect("DSCF7207：-1档", note: "-1档", "「文件名：-1档」：冒号去掉、负号留着")
        expect("DSCF7207 - 去路人", note: "去路人", "「DSCF7207 - 去路人」：两边带空格的 - 还是分隔")
        expect("DSCF7207 —— 黑白", note: "黑白", "「——」后面跟空格也是分隔")

        // 来回一趟：页面上写「-1档曝光」，复制出来再导入还是「-1档曝光」。
        let html = page(quota: nil)
        guard let ctx = context(html: html) else { return }
        ctx.evaluateScript("__cells[0].onclick(); __click('nb1'); __byId['note-text'].value = '-1档曝光'; __byId['note-save'].onclick(); __byId['copy'].onclick();")
        let copied = eval(ctx, "__byId['out'].value")
        let r = ClientReply.resolve(copied, items: items(), sheets: [sheet(quota: nil)])
        check(r.ids == [names[0]] && r.notes == [names[0]: "-1档曝光"], "页面写「-1档曝光」复制再导入：还是「-1档曝光」",
              copied.debugDescription + " → \(r.notes)")
    }

    // MARK: 「备注：」记号：开头那张认不出也不拿备注去认照片（审查）

    private static func markerChecks() {
        let header = "\(ProofSheetPage.header) \(bigSheet.id)\n"
        // 同名的两张（不同子文件夹）：开头那个词重名。
        func at(_ id: String, _ file: String) -> BatchItem {
            let path = "/nonexistent/proof-selftest/" + file
            return BatchItem(
                id: id, previewPath: "", rawPath: path, decodePath: path, sharpness: 0, worstClipPct: 0,
                eyeClosed: nil, faceQuality: nil, faceCount: 0, faceBbox: nil, faceAreaPct: nil, faces: [],
                burstGroup: 0, expressionScore: nil, vlmReject: false, vlmCompositionIssues: [], vlmReason: nil,
                appealClosedEyes: nil, appealSubjectSharp: nil, appealIntentionalExposure: nil, appealReason: nil,
                exif: nil, horizonDeg: nil)
        }
        let all = items() + [at("仪式_DSCF7301", "仪式/DSCF7301.JPG"), at("晚宴_DSCF7301", "晚宴/DSCF7301.JPG")]
        func resolve(_ text: String) -> ClientReply.Resolution {
            ClientReply.resolve(text, items: all, sheets: [bigSheet])
        }
        func detail(_ r: ClientReply.Resolution) -> String {
            "认出 \(r.ids.joined(separator: " ")) · 备注 \(r.notes) · 没认出 \(r.unknown)"
        }
        let gone = resolve(header + "DSCF9999 \(ProofSheetPage.noteMarker)修 3 处\nDSCF7210\n")
        check(gone.ids == ["DSCF7210"] && gone.notes.isEmpty && gone.unknown == ["DSCF9999"],
              "开头那张不在这一场（移进了废纸篓）：只报它没认出，备注「修 3 处」不把表上第 3 张认进来", detail(gone))
        let named = resolve(header + "DSCF9999 \(ProofSheetPage.noteMarker)和 DSCF7208 一样的调色\n")
        check(named.ids.isEmpty && named.unknown == ["DSCF9999"],
              "开头那张不在这一场：备注里的 DSCF7208 也不认", detail(named))
        let twin = resolve(header + "DSCF7301 \(ProofSheetPage.noteMarker)修 3 处\n")
        check(twin.ids.isEmpty && twin.notes.isEmpty && twin.unknown == ["DSCF7301（重名）"],
              "开头那个词重名：只报（重名），备注里的 3 不认", detail(twin))
        let kept = resolve(header + "晚宴_DSCF7301 \(ProofSheetPage.noteMarker)修 3 处，和 7208 一样\n")
        check(kept.ids == ["晚宴_DSCF7301"] && kept.notes == ["晚宴_DSCF7301": "修 3 处，和 7208 一样"],
              "页面复制的是照片 id：重名的照片用 id 照样认、备注原样", detail(kept))
        let chat = resolve("选好了 \(ProofSheetPage.noteMarker)7207去路人")
        check(chat.ids == ["DSCF7207"] && chat.notes == ["DSCF7207": "去路人"],
              "记号前面不是照片（「选好了 备注：…」）：照旧按普通文字认", detail(chat))
    }

    // MARK: 一行好几张照片（审查：第二张被吞进第一张的备注）

    private static func multiPhotoLines() {
        let all = items()
        func expect(_ text: String, ids: [String], notes: [String: String], _ name: String) {
            let r = ClientReply.resolve(text, items: all, sheets: [bigSheet])
            let ok = r.ids == ids && r.notes == notes
            check(ok, name, "认出 \(r.ids.joined(separator: " ")) · 备注 \(r.notes) · 没认出 \(r.unknown)")
        }
        expect("7207去路人，7208瘦脸，7215调亮", ids: ["DSCF7207", "DSCF7208", "DSCF7215"],
               notes: ["DSCF7207": "去路人", "DSCF7208": "瘦脸", "DSCF7215": "调亮"],
               "「7207去路人，7208瘦脸，7215调亮」：三张都认、各带各的备注（以前 7208、7215 被吞进 7207 的备注）")
        expect("7207 去路人，7208 瘦脸", ids: ["DSCF7207", "DSCF7208"], notes: ["DSCF7207": "去路人", "DSCF7208": "瘦脸"],
               "「7207 去路人，7208 瘦脸」：两张各带各的备注")
        expect("7207 去路人，7208瘦脸", ids: ["DSCF7207", "DSCF7208"], notes: ["DSCF7207": "去路人", "DSCF7208": "瘦脸"],
               "第二张紧贴着汉字也切得开")
        expect("7207 去路人，背景虚一点，7208 瘦脸", ids: ["DSCF7207", "DSCF7208"],
               notes: ["DSCF7207": "去路人，背景虚一点", "DSCF7208": "瘦脸"], "备注里的逗号不切（后面不是照片），原样留着")
        expect("DSCF7207瘦脸 DSCF7208", ids: ["DSCF7207", "DSCF7208"], notes: ["DSCF7207": "瘦脸"],
               "没有句读：紧贴着汉字的「DSCF7207瘦脸」拆成照片 + 备注，后面那张照认")
        expect("7207、7208 瘦脸", ids: ["DSCF7207", "DSCF7208"], notes: [:],
               "开头那张没带备注（「7207、7208 …」）：不切段、不带备注（和「DSCF7207, DSCF7208 都要」一样）")
        let glued = ClientReply.resolve("7207 去路人还有7208瘦脸", items: all, sheets: [bigSheet])
        let visible = glued.ids.contains("DSCF7208") || glued.unknown.contains { $0.contains("7208") }
        check(visible && glued.notes["DSCF7207"]?.contains("7208") != true,
              "「…还有7208瘦脸」：7208 不悄悄进 7207 的备注（认出来或者列在没认出里）",
              "认出 \(glued.ids) · 备注 \(glued.notes) · 没认出 \(glued.unknown)")
    }

    // MARK: 确认表水印（只画在内存里的 800px 小样上）

    /// 一张纯灰的图（sRGB、不透明）。
    static func solid(_ w: Int, _ h: Int, gray: CGFloat) -> CGImage? {
        guard let ctx = rgbaContext(w, h) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 签名图：整块不透明的白（外接框就是签名的大小，好量位置）。
    static func whiteSignature(_ w: Int, _ h: Int) -> CGImage? { solid(w, h, gray: 1) }

    static func rgbaContext(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 像素（RGBA，第 0 行是最上面一行）。
    static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        guard let ctx = rgbaContext(w, h) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let count = w * h * 4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    /// 两张一样大的图哪里不一样（左上原点的外接框、不一样的地方最亮的那个值）；一样 = nil。
    static func changed(_ a: [UInt8], _ b: [UInt8], width w: Int, height h: Int,
                        threshold: Int = 10) -> (box: CGRect, brightest: Int)? {
        guard a.count == b.count, a.count == w * h * 4 else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1, brightest = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let d = abs(Int(a[i]) - Int(b[i]))
                guard d > threshold else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                brightest = max(brightest, Int(b[i]))
            }
        }
        guard maxX >= 0 else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (box, brightest)
    }

    /// 改版之前的 contactSheetJPEG（原样抄一份）：不带水印的输出要和它逐字节一样。
    static func legacyContactJPEG(path: String) -> Data? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func watermarkChecks() {
        // 1. 水印页怎么设都裁成左下一个淡角标。
        var wild = WatermarkEngine.Config()
        wild.position = .topRight
        wild.landscapeOverrideEnabled = true
        wild.landscapeOverride = .center
        wild.tile.enabled = true
        wild.frame.enabled = true
        wild.canvasRatio.enabled = true
        wild.opacity = 1
        wild.sizeRatio = 0.5
        wild.exifText.enabled = true
        wild.exifText.position = .topRight
        wild.exifText.opacity = 1
        guard let sig = whiteSignature(300, 100), let base = solid(800, 533, gray: 100.0 / 255) else {
            check(false, "造得出测试图")
            return
        }
        let made = ProofWatermark.make(config: wild, signature: sig)
        let c = made?.config
        check(c?.frame.enabled == false && c?.canvasRatio.enabled == false, "相框、画布比例强制关")
        check(c?.tile.enabled == false, "不平铺（斜纹会挡脸）")
        check(c?.position == .bottomLeft && c?.landscapeOverrideEnabled == false, "签名挪到左下（右上留给 ♥）")
        check(c?.exifText.position == .bottomLeft, "文字也挪到左下")
        check(c?.opacity == ProofWatermark.opacityCap && c?.exifText.opacity == ProofWatermark.opacityCap, "不透明度压到 0.5")
        check(c?.sizeRatio == ProofWatermark.sizeRatioCap, "签名最宽占短边 20%")
        var noSig = WatermarkEngine.Config()
        noSig.exifText.enabled = false
        check(ProofWatermark.make(config: noSig, signature: nil) == nil, "没签名图也没文字：没东西可画（nil）")
        var off = WatermarkEngine.Config()
        off.signatureEnabled = false
        check(ProofWatermark.make(config: off, signature: sig) == nil, "签名关着也没文字：nil")
        var textOnly = WatermarkEngine.Config()
        textOnly.exifText.enabled = true
        textOnly.exifText.customText = "样片 · 小何摄影"
        let textMark = ProofWatermark.make(config: textOnly, signature: nil)
        check(textMark != nil && textMark?.config.signatureEnabled == false && textMark?.signature == nil,
              "只有文字：签名关掉、照样画文字")

        // 2. 画在 800px 小样上：尺寸不变、只动左下那一块、淡。
        let before = pixels(base)
        guard let made, let marked = made.apply(to: base, original: "") else {
            check(false, "签名画得上")
            return
        }
        check(marked.width == 800 && marked.height == 533, "画完还是 800×533（相框、画布比例没生效）",
              "\(marked.width)×\(marked.height)")
        let after = pixels(marked)
        if let diff = changed(before, after, width: 800, height: 533) {
            // 读不到原片：按长边 6000 算，边距 30 × 800/6000 = 4px；签名宽 = 短边 533 × 20% = 107。
            let box = diff.box
            let left = Int(box.minX), bottom = Int(box.maxY), width = Int(box.width)
            let marginOK = abs(left - 4) <= 1 && abs(bottom - 529) <= 1
            check(marginOK, "签名在左下、边距按原片换算（读不到原片按长边 6000：4px）", "\(box)")
            check(abs(width - 107) <= 2, "签名宽 = 短边 × 20%", "\(box)")
            check(box.maxX < 400 && box.minY > 266, "只动左下那一块（右上的 ♥、中间的脸都没碰）", "\(box)")
            check(diff.brightest <= 185 && diff.brightest >= 170, "不透明度 0.5：白签名压在灰上是半亮", "\(diff.brightest)")
        } else {
            check(false, "小样上真画了水印")
        }

        // 3. 原片读得到：边距按原片长边换算（3000 长边 → 30 × 800/3000 = 8px）。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proof-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let originalURL = dir.appendingPathComponent("DSCF7207.JPG")
        if let big = solid(3000, 2000, gray: 0.4), writeJPEG(big, to: originalURL),
           let scaled = made.apply(to: base, original: originalURL.path),
           let diff = changed(before, pixels(scaled), width: 800, height: 533) {
            let left = Int(diff.box.minX), bottom = Int(diff.box.maxY)
            let marginOK = abs(left - 8) <= 1 && abs(bottom - 525) <= 1
            check(marginOK, "边距按原片长边换算（3000 → 8px）", "\(diff.box)")
        } else {
            check(false, "原片读得到时画得上")
        }

        // 4. 竖图、只有文字：一样在左下，右上 ♥ 那块不碰。
        if let tall = solid(533, 800, gray: 100.0 / 255), let textMark,
           let drawn = textMark.apply(to: tall, original: ""),
           let diff = changed(pixels(tall), pixels(drawn), width: 533, height: 800) {
            let heartZone = CGRect(x: 533 - 52, y: 0, width: 52, height: 52)
            check(!diff.box.intersects(heartZone), "竖图：文字不压右上的 ♥", "\(diff.box)")
            let lowerLeft = diff.box.minY > 400 && diff.box.minX < 40
            check(lowerLeft, "竖图：文字在左下", "\(diff.box)")
        } else {
            check(false, "只有文字时画得上")
        }

        // 5. 确认表里那一张：不带水印和改版前逐字节一样；带水印的变了、尺寸一样；预览文件一个字节没动。
        let previewURL = dir.appendingPathComponent("preview.jpg")
        guard let preview = solid(1024, 683, gray: 0.45), writeJPEG(preview, to: previewURL),
              let previewBytes = try? Data(contentsOf: previewURL) else {
            check(false, "造得出预览")
            return
        }
        let plain = BatchStore.contactSheetJPEG(path: previewURL.path)
        check(plain != nil && plain == legacyContactJPEG(path: previewURL.path), "不带水印：和改版前逐字节一样")
        let withMark = BatchStore.contactSheetJPEG(path: previewURL.path, watermark: made, original: originalURL.path)
        check(withMark != nil && withMark != plain, "带水印：图变了")
        func size(_ data: Data?) -> String {
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let s = WatermarkEngine.uprightSize(of: src) else { return "?" }
            return "\(s.width)×\(s.height)"
        }
        check(size(withMark) == size(plain) && size(plain).hasPrefix("800×"), "带水印：尺寸和不带的一样（800 长边）",
              size(withMark) + " / " + size(plain))
        check((try? Data(contentsOf: previewURL)) == previewBytes, "预览文件一个字节没动")
    }

    // MARK: 页面脚本（JavaScriptCore）

    static let sheetID = "20261104-101500"
    static let names = ["DSCF7207", "DSCF7208", "DSCF7209", "DSCF7210", "DSCF7211"]

    /// 一页确认表（图是 1 字节的假数据：脚本不看图）。
    static func page(quota: Int?) -> String {
        var cells = ""
        for (i, name) in names.enumerated() {
            cells += ProofSheetPage.cell(number: i + 1, id: name, pick: i == 0, jpeg: Data([0]))
        }
        return ProofSheetPage.html(title: "自检", sheetID: sheetID, count: names.count, date: "2026-11-04",
                                   cells: cells, quota: quota)
    }

    /// 假的 DOM：HTML 里有的 id 一个一个建出来，.cell 按 data-name / data-n 建。
    static func prelude(html: String, storage: String) -> String {
        let ids = matches(#"id="([^"]+)""#, in: html)
        let cells = matchPairs(#"class="cell" data-name="([^"]*)" data-n="([0-9]+)""#, in: html)
        var js = #"""
        var __byId = {}, __cells = [], __exec = false, __clip = null;
        function __El(id) { this.id = id; this.attrs = {}; this.style = {}; this.className = ""; this.textContent = ""; this.value = ""; this.onclick = null; }
        __El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
        __El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
        __El.prototype.focus = function () {};
        __El.prototype.select = function () {};
        __El.prototype.setSelectionRange = function () {};
        var __store = STORE;
        var document = {
          body: new __El("body"),
          getElementById: function (id) { return __byId[id] || null; },
          querySelectorAll: function (sel) { return sel === ".cell" ? __cells : []; },
          createElement: function () { return new __El(""); },
          execCommand: function () { return __exec; }
        };
        document.body.appendChild = function () {};
        document.body.removeChild = function () {};
        var localStorage = {
          getItem: function (k) { return Object.prototype.hasOwnProperty.call(__store, k) ? __store[k] : null; },
          setItem: function (k, v) { __store[k] = String(v); }
        };
        var window = { localStorage: localStorage, isSecureContext: true, event: null };
        var navigator = {};
        function setTimeout(f, ms) { return 1; }
        function clearTimeout(t) {}
        function __click(id) { var e = { stopped: false, stopPropagation: function () { this.stopped = true; } }; __byId[id].onclick(e); return e.stopped; }
        """#.replacingOccurrences(of: "STORE", with: storage)
        for id in ids { js += "\n__byId[\(jsString(id))] = new __El(\(jsString(id)));" }
        for (name, n) in cells {
            js += "\n(function () { var c = new __El(''); c.attrs['data-name'] = \(jsString(name)); c.attrs['data-n'] = \(jsString(n)); __cells.push(c); })();"
        }
        return js
    }

    static func script(in html: String) -> String {
        guard let start = html.range(of: "<script>"), let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex)
        else { return "" }
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// 一个跑着确认表脚本的 JS 环境；`storage` = localStorage 里原来有的（JSON 对象原文）。
    static func context(html: String, storage: String = "{}") -> JSContext? {
        guard let ctx = JSContext() else {
            check(false, "建得出 JavaScriptCore 环境")
            return nil
        }
        // 任何时候抛错（脚本本身、或者找不到元素）都算一条没过。
        ctx.exceptionHandler = { _, value in check(false, "页面脚本不抛错", value?.toString() ?? "?") }
        ctx.evaluateScript(prelude(html: html, storage: storage))
        let code = script(in: html)
        check(!code.isEmpty, "页面里找得到脚本")
        ctx.evaluateScript(code)
        return ctx
    }

    static func eval(_ ctx: JSContext, _ code: String) -> String {
        ctx.evaluateScript(code)?.toString() ?? "<nil>"
    }

    private static func pageScript() {
        let html = page(quota: 3)
        guard let ctx = context(html: html) else { return }
        check(eval(ctx, "document.body.className") == "js", "脚本跑起来（body 加上 js）")
        check(eval(ctx, "__byId['count'].textContent") == "已选 0 / 3 张", "套餐 3 张：底栏「已选 0 / 3 张」",
              eval(ctx, "__byId['count'].textContent"))
        // 选第 1、2、4、5 张（第 3 张 DSCF7209 不选：下面「修 3 处」那个 3 不能把它认进来）。
        ctx.evaluateScript("__cells[0].onclick(); __cells[1].onclick(); __cells[3].onclick();")
        check(eval(ctx, "__byId['count'].textContent") == "已选 3 / 3 张", "选满 3 张")
        ctx.evaluateScript("__cells[4].onclick();")
        check(eval(ctx, "__byId['count'].textContent") == "已选 4 / 3，超出 1 张", "选超了只提示「超出 1 张」",
              eval(ctx, "__byId['count'].textContent"))
        check(eval(ctx, "__byId['count'].className") == "over", "超出时底栏变色")
        check(eval(ctx, "__cells[4].className") == "cell on", "超出套餐也照样选上（不拦）")
        check(eval(ctx, "__byId['toast'].textContent").contains("超出套餐的 3 张"), "超出那一下有提示",
              eval(ctx, "__byId['toast'].textContent"))

        // 第 2 张写备注：点「写备注」不能把这张取消选中。
        check(eval(ctx, "__click('nb2')") == "true", "点「写备注」不往格子上冒（stopPropagation）")
        check(eval(ctx, "__cells[1].className") == "cell on", "写备注不改选中")
        check(eval(ctx, "__byId['note'].style.display") == "block", "备注框打开")
        check(eval(ctx, "__byId['note-name'].textContent") == names[1], "备注框写着是哪张")
        ctx.evaluateScript("__byId['note-text'].value = '  去掉后面的路人\\n脸瘦一点，修 3 处 '; __byId['note-save'].onclick();")
        let note = "去掉后面的路人 脸瘦一点，修 3 处"
        check(eval(ctx, "__byId['note'].style.display") == "none", "保存后备注框关上")
        check(eval(ctx, "__byId['nt2'].textContent") == ProofSheetPage.noteMarker + note, "格子下面显示备注（换行并成空格）",
              eval(ctx, "__byId['nt2'].textContent"))
        check(eval(ctx, "__byId['nb2'].textContent") == "改备注", "按钮变成「改备注」")
        let saved = eval(ctx, "__store['xuanpian-sheet-\(sheetID)-notes']")
        check(saved.contains("去掉后面的路人"), "备注存进 localStorage（单独一个键）", saved)

        // 写了又清空 = 删掉。
        ctx.evaluateScript("__click('nb4'); __byId['note-text'].value = '黑白'; __byId['note-save'].onclick();")
        ctx.evaluateScript("__click('nb4'); __byId['note-text'].value = '   '; __byId['note-save'].onclick();")
        check(eval(ctx, "__byId['nt4'].textContent") == "", "备注清空就删掉")
        // 取消不存。
        ctx.evaluateScript("__click('nb5'); __byId['note-text'].value = '不要了'; __byId['note-cancel'].onclick();")
        check(eval(ctx, "__byId['nt5'].textContent") == "", "取消不存备注")

        // 复制：剪贴板接口没有、execCommand 也不行 → 摆在框里让人长按复制。
        ctx.evaluateScript("__byId['copy'].onclick();")
        let copied = eval(ctx, "__byId['out'].value")
        let notedLine = "\(names[1]) \(ProofSheetPage.noteMarker)\(note)"
        let expected = "\(ProofSheetPage.header) \(sheetID)\n\(names[0])\n\(notedLine)\n\(names[3])\n\(names[4])\n"
        check(copied == expected, "复制的文字：一张一行，带备注的「文件名 备注：…」", copied.debugDescription)
        // 有剪贴板接口：提示里说超了几张、几张带备注。
        ctx.evaluateScript("navigator.clipboard = { writeText: function (t) { __clip = t; return { then: function (ok) { ok(); } }; } }; __byId['copy'].onclick();")
        check(eval(ctx, "__clip") == expected, "剪贴板里是同一段")
        check(eval(ctx, "__byId['toast'].textContent").hasPrefix("已复制 4 张的选择（超出套餐 1 张，1 张带备注）"),
              "复制后的提示说超出、带备注", eval(ctx, "__byId['toast'].textContent"))

        // 来回一趟：复制出来的这段原样导入。
        let r = ClientReply.resolve(copied, items: items(), sheets: [sheet(quota: 3)])
        check(r.ids == [names[0], names[1], names[3], names[4]], "导入认出的就是页面上点的四张（「修 3 处」不认第 3 张）",
              r.ids.joined(separator: " "))
        check(r.notes == [names[1]: note], "导入读回备注", r.notes.description)
        check(r.header == sheetID, "认出表号")
        let lines = ClientReply.summary(r, existing: [])
        check(lines.contains { $0.hasPrefix("带备注 1 张：\(names[1])「") }, "导入预览说几张带备注", lines.joined(separator: " / "))
        check(lines.contains("套餐含 3 张：这次认出 4 张，超出 1 张（加片）"), "导入预览说超出套餐", lines.joined(separator: " / "))

        // 重开页面：选择、备注都从 localStorage 读回来。
        let store = eval(ctx, "JSON.stringify(__store)")
        if let again = context(html: html, storage: store) {
            check(eval(again, "__byId['count'].textContent") == "已选 4 / 3，超出 1 张", "重开页面：选择读回来")
            check(eval(again, "__byId['nt2'].textContent") == ProofSheetPage.noteMarker + note, "重开页面：备注读回来")
            check(eval(again, "__byId['nb2'].textContent") == "改备注", "重开页面：按钮是「改备注」")
        }

        // 不设张数：和以前一样「已选 N 张」，复制的文字没有备注时和以前逐字一样。
        let plain = page(quota: nil)
        check(plain.contains("<span id=\"count\">已选 0 张</span>"), "不设张数：底栏初始「已选 0 张」")
        check(!plain.contains("套餐含"), "不设张数：页面上不提套餐")
        // 老页面存下的选择（只有选择那个键）照样读。
        let old = "{\"xuanpian-sheet-\(sheetID)\": \"[\\\"\(names[2])\\\"]\"}"
        if let ctx2 = context(html: plain, storage: old) {
            check(eval(ctx2, "__byId['count'].textContent") == "已选 1 张", "不设张数：读回老的选择、底栏「已选 1 张」",
                  eval(ctx2, "__byId['count'].textContent"))
            ctx2.evaluateScript("__cells[0].onclick(); __byId['copy'].onclick();")
            let text = eval(ctx2, "__byId['out'].value")
            let want = "\(ProofSheetPage.header) \(sheetID)\n\(names[0])\n\(names[2])\n"
            check(text == want, "没写备注：复制的文字和以前一样（表号一行、一行一个文件名）", text.debugDescription)
            check(eval(ctx2, "__byId['count'].className") == "", "不设张数不变色")
        }
        // localStorage 一碰就抛（无痕、微信预览）也照样能点、能写备注、能复制。
        if let ctx3 = context(html: plain, storage: "{}") {
            ctx3.evaluateScript("localStorage.getItem = localStorage.setItem = function () { throw new Error('denied'); };")
            ctx3.evaluateScript("__cells[1].onclick(); __click('nb2'); __byId['note-text'].value = '黑白'; __byId['note-save'].onclick(); __byId['copy'].onclick();")
            check(eval(ctx3, "__byId['count'].textContent") == "已选 1 张", "存不了也照样能点")
            check(eval(ctx3, "__byId['out'].value").contains(names[1] + " " + ProofSheetPage.noteMarker + "黑白"),
                  "存不了也照样能写备注、复制")
        }
    }

    // MARK: ClientReply 的备注写法

    /// 40 张（DSCF7201…DSCF7240，确认表上 #n = DSCF72nn）+ 一张带空格的「IMG 0001.JPG」。
    static func items() -> [BatchItem] {
        var out = (1...40).map { n in item(String(format: "DSCF72%02d", n)) }
        out.append(item("IMG 0001"))
        // 页面脚本那段用的 DSCF7207…7211 也在这 40 张里。
        return out
    }

    static func item(_ id: String) -> BatchItem {
        let path = "/nonexistent/proof-selftest/\(id).JPG"
        return BatchItem(
            id: id, previewPath: "", rawPath: path, decodePath: path, sharpness: 0, worstClipPct: 0,
            eyeClosed: nil, faceQuality: nil, faceCount: 0, faceBbox: nil, faceAreaPct: nil, faces: [],
            burstGroup: 0, expressionScore: nil, vlmReject: false, vlmCompositionIssues: [], vlmReason: nil,
            appealClosedEyes: nil, appealSubjectSharp: nil, appealIntentionalExposure: nil, appealReason: nil,
            exif: nil, horizonDeg: nil)
    }

    /// 页面脚本那张表（DSCF7207…7211，#3 = DSCF7209）。
    static func sheet(quota: Int?) -> ProofSheet {
        ProofSheet(id: sheetID, date: Date(timeIntervalSince1970: 1_793_000_000), scope: "仅精选", ids: names,
                   lists: ProofSheet.lists(quota: quota))
    }

    /// 40 张那张表（#n = DSCF72nn）。
    static let bigSheet = ProofSheet(id: "20261104-090000", date: Date(timeIntervalSince1970: 1_792_990_000),
                                     scope: "精选 + 可用", ids: (1...40).map { String(format: "DSCF72%02d", $0) })

    private static func replyNotes() {
        let all = items()
        func resolve(_ text: String) -> ClientReply.Resolution {
            ClientReply.resolve(text, items: all, sheets: [bigSheet])
        }
        func expect(_ text: String, ids: [String], notes: [String: String], _ name: String) {
            let r = resolve(text)
            let ok = r.ids == ids && r.notes == notes
            check(ok, name, "认出 \(r.ids.joined(separator: " ")) · 备注 \(r.notes) · 没认出 \(r.unknown)")
        }
        expect("DSCF7207 修 3 处", ids: ["DSCF7207"], notes: ["DSCF7207": "修 3 处"],
               "「DSCF7207 修 3 处」：3 处是备注，不把表上第 3 张认进来")
        expect("7207 7208", ids: ["DSCF7207", "DSCF7208"], notes: [:], "「7207 7208」还是两张、没有备注")
        expect("12、35", ids: ["DSCF7212", "DSCF7235"], notes: [:], "「12、35」按编号认两张")
        expect("DSCF7207 12 35", ids: ["DSCF7207", "DSCF7212", "DSCF7235"], notes: [:], "文件名后面全是数字：都是要的照片")
        expect("7207、12、35 都要", ids: ["DSCF7207", "DSCF7212", "DSCF7235"], notes: [:], "后面两个以上数字：不是备注")
        expect("7207 去路人，瘦脸（背景虚一点）！", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人，瘦脸（背景虚一点）！"],
               "文件号后面的话是备注，全角标点原样留着")
        expect("７２０７ 黑白", ids: ["DSCF7207"], notes: ["DSCF7207": "黑白"], "全角数字的文件号也认、备注照留")
        expect("DSCF7207：脸瘦一点", ids: ["DSCF7207"], notes: ["DSCF7207": "脸瘦一点"], "「文件名：备注」")
        expect("7207去路人", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人"], "中文紧贴着文件号（以前整个算没认出）")
        expect("DSCF7207, DSCF7208 都要", ids: ["DSCF7207", "DSCF7208"], notes: [:], "后面还有文件名：不是备注，两张都要")
        expect("IMG 0001.JPG 黑白", ids: ["IMG 0001"], notes: ["IMG 0001": "黑白"], "带空格的文件名后面跟备注")
        // 规则改过（优化分析 NR2，用户同意）：一行只有一个表上编号、后面的话一个数字都不带 = 这张的备注（以前丢掉）；
        // 两个以上编号（「12、35 都要」）照旧都要、不当备注 —— 那几条在 numberedNoteChecks 里。
        expect("12 去路人", ids: ["DSCF7212"], notes: ["DSCF7212": "去路人"], "开头是表上编号、后面不带数字：收成备注")
        expect("DSCF7207 第12张 谢谢", ids: ["DSCF7207", "DSCF7212"], notes: [:], "后面明说「第 12 张」：照旧是要的照片")
        expect("DSCF7207 修 2 处，这张也要", ids: ["DSCF7207"], notes: ["DSCF7207": "修 2 处，这张也要"],
               "「这张」不是第几张：整句是备注")
        expect("DSCF7207\nDSCF7208 黑白\n7210 7211", ids: ["DSCF7207", "DSCF7208", "DSCF7210", "DSCF7211"],
               notes: ["DSCF7208": "黑白"], "一行一行各认各的")
        expect("DSCF7207 去路人\nDSCF7207 还要瘦脸", ids: ["DSCF7207"], notes: ["DSCF7207": "还要瘦脸"], "同一张写两次取后一次")
        let header = "\(ProofSheetPage.header) \(bigSheet.id)\n"
        let marked = "\(header)DSCF7207 \(ProofSheetPage.noteMarker)和 DSCF7208 一样的调色，修 3 处\nDSCF7210\n"
        expect(marked,
               ids: ["DSCF7207", "DSCF7210"], notes: ["DSCF7207": "和 DSCF7208 一样的调色，修 3 处"],
               "确认表的「备注：」后面整段原样算备注，里面的文件名、数字不认")
        expect(header + "DSCF7207\nDSCF7208\n", ids: ["DSCF7207", "DSCF7208"], notes: [:], "老格式（没有备注）照旧")
        expect("文件名,备注\nDSCF7207,瘦脸\nDSCF7208,\n", ids: ["DSCF7207", "DSCF7208"], notes: [:], "CSV 照旧按表格认（备注列不收）")
        let unknown = resolve("DSCF9999 去路人")
        check(unknown.ids.isEmpty && unknown.notes.isEmpty && unknown.unknown == ["DSCF9999"],
              "不是这一场的文件名：照旧列在没认出、不带备注", "\(unknown.unknown)")
        let chatter = resolve("要这几张：7207、7208，谢谢")
        check(chatter.ids == ["DSCF7207", "DSCF7208"] && chatter.notes.isEmpty, "聊天的字照旧跳过",
              "\(chatter.ids) \(chatter.notes)")
        // 没导出过确认表：文件号后面的话照样算备注。
        let noSheet = ClientReply.resolve("7207 去路人", items: all, sheets: [])
        check(noSheet.ids == ["DSCF7207"] && noSheet.notes == ["DSCF7207": "去路人"], "没有确认表也认备注")
        // 编号也对得上另一张的 ≥3 位数（表上有 120 张以上才会碰到）：不当开头，照旧报「文件号还是编号？」。
        let many = (1...130).map { item(String(format: "IMG_%04d", $0 + 1000)) } + [item("DSCF0120")]
        let manySheet = ProofSheet(id: "20261104-080000", date: Date(), scope: "精选 + 可用", ids: many.map(\.id))
        let ambiguous = ClientReply.resolve("120 去路人", items: many, sheets: [manySheet])
        check(ambiguous.notes.isEmpty && ambiguous.unknown.contains { $0.hasPrefix("120") },
              "文件号、编号对不上的照旧说不准、不带备注", "\(ambiguous.ids) \(ambiguous.unknown)")

        // 套餐张数跟着表存、老表照样读。
        let decoded = try? JSONDecoder().decode([ProofSheet].self, from: Data(
            #"[{"id":"20261021-153012","date":782000000,"scope":"仅精选","ids":["a","b"]}]"#.utf8))
        check(decoded?.first?.quota == nil && decoded?.first?.ids == ["a", "b"], "老的 proof_sheets.json 照样读（没有张数）")
        let round = (try? JSONEncoder().encode(sheet(quota: 30)))
            .flatMap { try? JSONDecoder().decode(ProofSheet.self, from: $0) }
        check(round?.quota == 30, "套餐张数存了读回来一样")
        let plainJSON = (try? JSONEncoder().encode(sheet(quota: nil))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!plainJSON.contains("lists"), "不设张数不写 lists（老版本读新文件也不受影响）", plainJSON)
        check(ProofSheetSaveAccessory.parse(" ３０ ") == 30 && ProofSheetSaveAccessory.parse("0") == nil
              && ProofSheetSaveAccessory.parse("") == nil, "张数输入框：全角数字认、0 和空着 = 不限")

        // 精修要求.csv：表头、BOM、逗号引号转义。
        let csv = String(decoding: OriginalsCopier.retouchCSV([
            OriginalsCopier.RetouchRow(file: "DSCF7207.RAF", note: "去路人，瘦脸"),
            OriginalsCopier.RetouchRow(file: "DSCF7208.RAF", note: "和\"7207\"一样, 黑白"),
        ]), as: UTF8.self)
        let wantCSV = "\u{FEFF}文件名,备注\r\nDSCF7207.RAF,去路人，瘦脸\r\nDSCF7208.RAF,\"和\"\"7207\"\"一样, 黑白\"\r\n"
        check(csv == wantCSV, "精修要求.csv 的内容（BOM、表头、转义）", csv.debugDescription)
        retouchFormulaChecks()
    }

    /// 精修要求.csv 防公式（审查：客户备注「=HYPERLINK(…)」「+1 档」「-1 档」「@张三」，修图师在 Excel 里双击打开会被当成公式算、
    /// 显示成 #NAME? 或者一个能点的链接）：以 = + - @ 或 Tab 开头的格子前面加一个 '（OWASP CSV injection 的通行做法），
    /// 文件名那一列同样（改过名的「-DSCF7299.JPG」）；中间带这些字的、表头不动；带逗号引号的先加 ' 再整格加引号。
    /// 读回来（当客户回复导入）认出的照片、没认出的字和不加 ' 时一样。
    private static func retouchFormulaChecks() {
        let rows = [
            OriginalsCopier.RetouchRow(file: "DSCF7201.JPG", note: "=HYPERLINK(\"http://x\",\"点我\")"),
            OriginalsCopier.RetouchRow(file: "DSCF7202.JPG", note: "+1 档曝光"),
            OriginalsCopier.RetouchRow(file: "DSCF7203.JPG", note: "-1 档，压暗"),
            OriginalsCopier.RetouchRow(file: "DSCF7204.JPG", note: "@张三 看一下"),
            OriginalsCopier.RetouchRow(file: "DSCF7205.JPG", note: "\t=1+1"),
            OriginalsCopier.RetouchRow(file: "-DSCF7299.JPG", note: "去路人 = 背景干净, -1 档"),
        ]
        let csv = String(decoding: OriginalsCopier.retouchCSV(rows), as: UTF8.self)
        let want = "\u{FEFF}文件名,备注\r\n"
            + "DSCF7201.JPG,\"'=HYPERLINK(\"\"http://x\"\",\"\"点我\"\")\"\r\n"
            + "DSCF7202.JPG,'+1 档曝光\r\n"
            + "DSCF7203.JPG,'-1 档，压暗\r\n"
            + "DSCF7204.JPG,'@张三 看一下\r\n"
            + "DSCF7205.JPG,'\t=1+1\r\n"
            + "'-DSCF7299.JPG,\"去路人 = 背景干净, -1 档\"\r\n"
        check(csv == want, "精修要求.csv 防公式：= + - @ Tab 开头的备注、文件名前面加 '，中间带的不动，加 ' 以后再转义", csv.debugDescription)
        let parsed = CSV.parseRows(csv).dropFirst()
        let cellsOK = parsed.count == rows.count && zip(parsed, rows).allSatisfy { cells, row in
            let note = row.note.hasPrefix("去路人") ? row.note : "'" + row.note
            return cells.count == 2 && cells[1] == note
        }
        check(cellsOK, "防公式的 CSV 按 CSV 读回来：每格就是原话前面多一个 '（逗号、引号没读坏）", "\(Array(parsed))")
        // 读回：当成客户回复导入，和不加 ' 的老写法认出的一样。
        var plain = "\u{FEFF}" + CSV.writeRow(["文件名", "备注"]) + "\r\n"
        for row in rows { plain += CSV.writeRow([row.file, row.note]) + "\r\n" }
        let pool = items() + [item("-DSCF7299")]
        let guarded = ClientReply.resolve(csv, items: pool, sheets: [])
        let old = ClientReply.resolve(plain, items: pool, sheets: [])
        let wantIDs = ["DSCF7201", "DSCF7202", "DSCF7203", "DSCF7204", "DSCF7205", "-DSCF7299"]
        check(guarded.ids == wantIDs && guarded.ids == old.ids && guarded.unknown == old.unknown,
              "防公式的精修要求.csv 当客户回复导入：认出的照片、没认出的字和以前一样",
              "\(guarded.ids) \(guarded.unknown) vs \(old.ids) \(old.unknown)")
    }

    // MARK: 小工具

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func matchPairs(_ pattern: String, in text: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
