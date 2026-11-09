import Foundation
import CoreGraphics
import ImageIO
import PDFKit

// MARK: - 印厂规格 / 导出前检查 / 部分导出 / 看版的 ops（--collage-ops；相册 B · P 道）
//
// CollageCLI 的 switch 里只有一行转发到这里（三道各加自己的一行，不在同一处堆代码）。
//   spec:<短名或名字>（套内置 / 存过的规格，例 spec:sq30-glued、spec:方册 25×25 平铺）· spec:list · spec:（打印现在的）
//   spec:save=<名字> · spec:del=<名字>（「存成规格…」/ 删掉存的）
//   spec:color=adobe|srgb · spec:pages=20-60/2 · spec:ends=on|off · spec:fold=6.5|auto · spec:quality=0.95|auto
//   spec:size=30x30（单页 cm）—— 改现在这本的规则 / 尺寸（同「文档 › 画布」）
//   preflight（打印导出前检查，同「导出 ▾」的清单）· preflight:fast（只算导出按钮看的那些，不渲字）
//   preflight:reveal=N（点清单第 N 条：换页、选中，打印落在哪）
//   exportrange:all|current|1-3;7（「导出 ▾」的范围；ops 用逗号分步，跨页号之间用分号）
//   proofpdf（出看版 PDF 到 --out，不弹访达）· exportto:<目录>（按导出设置和范围导出到这个目录，不弹访达、不问确认：
//   要问的那句打出来）
@MainActor
enum CollagePrintCLI {
    static let names: Set<String> = ["spec", "preflight", "exportrange", "proofpdf", "exportto"]

    /// 返回 false = 参数不对（ops 打「参数不对，跳过」）。
    static func apply(_ name: String, _ arg: String, store: CollageStore, outDir: URL) -> Bool {
        switch name {
        case "spec": return spec(arg, store: store)
        case "preflight": return preflight(arg, store: store)
        case "exportrange": return exportRange(arg, store: store)
        case "proofpdf": return proof(store: store, outDir: outDir)
        case "exportto": return exportTo(arg, store: store)
        default: return false
        }
    }

    private static func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// 路人信息、蒙版还在后台算时先等（取景看它：放大倍数、脸压不压中缝跟着变）。
    private static func settle(_ store: CollageStore) {
        spin(120) { !store.hintsPending }
    }

    static func describe(_ canvas: CollageCanvas) -> String {
        let size = canvas.pageSizeCM
        let r = canvas.effectivePrintRules
        let fold = String(format: "%.1fmm", canvas.foldBand / max(1, canvas.dpi) * 25.4)
        let quality = r.jpegQuality.map { String(format: "%.2f", $0) } ?? "跟导出设置"
        return "画布 \(canvas.name) · 单页 " + String(format: "%.2f×%.2fcm", size.width, size.height)
            + " · \(canvas.width)x\(canvas.height)px · \(canvas.binding.label) · 中缝带每侧 \(fold)"
            + " · 页数 \(r.summary)\(r.singleEnds ? " · 首尾单页" : "") · \(r.colorSpace.label) · JPEG \(quality)"
            + (canvas.printRules == nil ? "（没套规格：保守默认）" : "")
    }

    private static func spec(_ arg: String, store: CollageStore) -> Bool {
        if arg.isEmpty {
            print("  " + describe(store.project.canvas))
            return true
        }
        if arg == "list" {
            for s in store.printSpecs {
                let mark = s.matches(store.project.canvas) ? " ✓" : ""
                print("  \(s.key ?? "（我的）") · \(s.name) · \(s.detail)\(mark)")
            }
            return true
        }
        let kv = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if kv.count == 2 {
            let key = kv[0]
            let value = kv[1]
            var rules = store.project.canvas.effectivePrintRules
            switch key {
            case "save":
                guard let saved = store.savePrintSpec(named: value) else { return false }
                print("  存成规格「\(saved)」· 我的规格 \(store.userPrintSpecs.count) 条")
            case "del":
                guard store.userPrintSpecs.contains(where: { $0.name == value }) else { return false }
                store.deletePrintSpec(named: value)
                print("  删掉规格「\(value)」· 我的规格 \(store.userPrintSpecs.count) 条")
            case "color":
                switch value {
                case "adobe", "adobeRGB": rules.colorSpace = .adobeRGB
                case "srgb", "sRGB": rules.colorSpace = .sRGB
                default: return false
                }
                store.setPrintRules(rules)
            case "pages":
                // 20-60/2：最少-最多/每次加几 P。
                let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                let range = parts.first.map { $0.split(separator: "-", omittingEmptySubsequences: false) } ?? []
                guard parts.count == 2, range.count == 2, let lo = Int(range[0]), let hi = Int(range[1]),
                      let step = Int(parts[1]), CollagePrintRules.pageLimit.contains(lo),
                      CollagePrintRules.pageLimit.contains(hi), lo <= hi,
                      CollagePrintRules.stepRange.contains(step) else { return false }
                rules.minPages = lo
                rules.maxPages = hi
                rules.pageStep = step
                store.setPrintRules(rules)
            case "ends":
                guard value == "on" || value == "off" else { return false }
                rules.singleEnds = value == "on"
                store.setPrintRules(rules)
            case "fold":
                let canvas = store.project.canvas
                let mm: Double?
                if value == "auto" {
                    mm = nil
                } else if let v = Double(value), CollagePrintRules.foldRangeMM.contains(v) {
                    mm = v
                } else {
                    return false
                }
                if canvas.binding == .glued { rules.gluedFoldMM = mm } else { rules.layflatFoldMM = mm }
                store.setPrintRules(rules)
            case "quality":
                if value == "auto" {
                    rules.jpegQuality = nil
                } else if let q = Double(value), CollagePrintRules.qualityRange.contains(q) {
                    rules.jpegQuality = q
                } else {
                    return false
                }
                store.setPrintRules(rules)
            case "size":
                let wh = value.lowercased().split(separator: "x").compactMap { Double($0) }
                let range = CollagePrintSpec.pageCMRange
                guard wh.count == 2, store.isAlbum, range.contains(wh[0]), range.contains(wh[1]) else { return false }
                store.setPageSizeCM(width: wh[0], height: wh[1])
            default:
                return false
            }
            if key != "save", key != "del" { print("  " + describe(store.project.canvas)) }
            return true
        }
        guard let spec = CollagePrintSpec.find(arg, in: store.userPrintSpecs) else {
            print("  没有规格「\(arg)」：" + store.printSpecs.map { $0.key ?? $0.name }.joined(separator: " / "))
            return false
        }
        guard store.isAlbum else {
            print("  印厂规格只对相册：先 mode:album")
            return false
        }
        store.applyPrintSpec(spec)
        print("  套用规格「\(spec.name)」· " + describe(store.project.canvas)
              + (store.notice.map { " · 提示: \($0)" } ?? ""))
        return true
    }

    static func line(_ issue: CollagePreflightIssue) -> String {
        let at = issue.page.map { "第\($0 + 1)页" } ?? "整本"
        let cell = issue.path.map { $0.isEmpty ? "r" : $0.map(String.init).joined() }
            ?? (issue.item.map { _ in "图层" } ?? "—")
        return "[\(issue.severity.label)] \(issue.kind.label) · \(at) · \(cell) · \(issue.message)"
    }

    private static func preflight(_ arg: String, store: CollageStore) -> Bool {
        settle(store)
        if arg.hasPrefix("reveal=") {
            let issues = store.preflight()
            guard let n = Int(arg.dropFirst("reveal=".count)), issues.indices.contains(n) else { return false }
            store.reveal(issues[n])
            let sel = store.selection.map { $0.isEmpty ? "r" : $0.map(String.init).joined() } ?? "无"
            print("  点第 \(n) 条：\(line(issues[n])) → 跨页 \(store.pageIndex + 1) · 选中格子 \(sel)"
                  + " · 选中图层 \(store.selectedItem == nil ? "无" : "有") · 右栏 \(store.nav.inspectorTab.rawValue)")
            return true
        }
        guard arg.isEmpty || arg == "fast" else { return false }
        let t0 = Date()
        let issues = store.preflight(texts: arg.isEmpty)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("  导出前检查（\(arg.isEmpty ? "全部" : "只看导出按钮那些") · \(ms) ms）：\(CollagePreflight.summary(issues))")
        for (i, issue) in issues.enumerated() { print("    \(i). " + line(issue)) }
        let pages = (try? store.exportPageSelection.get()) ?? nil
        if let ask = CollageStore.exportConfirmation(issues, project: store.project, pages: pages) {
            print("  导出按钮会问：\(ask.title)")
            for row in ask.message.split(separator: "\n") { print("    " + row) }
        } else {
            print("  导出按钮不问")
        }
        return true
    }

    private static func exportRange(_ arg: String, store: CollageStore) -> Bool {
        switch arg {
        case "all", "": store.exportRange = .all
        case "current": store.exportRange = .current
        default: store.exportRange = .custom(arg)
        }
        switch store.exportPageSelection {
        case .success(let only):
            print("  导出范围 → " + (only.map { "第 \(CollageExportRange.label($0)) 个跨页（\($0.count) 个，不出 PDF）" } ?? "全部"))
        case .failure(let bad):
            print("  导出范围写错了：\(bad.message) · 导出按钮：\(store.exportBlockedReason ?? "可以导")")
        }
        return true
    }

    private static func proof(store: CollageStore, outDir: URL) -> Bool {
        settle(store)
        var result: Result<String, CollageExportRange.Bad>?
        let refused = store.startProofPDF(project: store.project, name: store.exportName, folder: outDir,
                                          reveal: false) { result = $0 }
        if let refused {
            print("  看版没出：\(refused)")
            return true
        }
        spin(600) { result != nil }
        spin(5) { !store.isExporting }
        switch result {
        case .success(let file)?:
            let url = outDir.appendingPathComponent(file)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("  看版 \(file) · \(size / 1024) KB · " + store.progressText)
            if let doc = PDFDocument(url: url) {
                print("  PDF \(doc.pageCount) 页")
                for i in 0..<min(doc.pageCount, 3) {
                    guard let page = doc.page(at: i) else { continue }
                    let box = page.bounds(for: .mediaBox)
                    let text = (page.string ?? "").replacingOccurrences(of: "\n", with: " / ")
                    print(String(format: "    第 %d 页 %.0f×%.0f pt · 页脚：", i + 1, box.width, box.height) + text)
                }
            }
        case .failure(let bad)?:
            print("  看版没出：\(bad.message)")
        case nil:
            print("  看版超时")
        }
        return true
    }

    private static func exportTo(_ arg: String, store: CollageStore) -> Bool {
        guard !arg.isEmpty else { return false }
        settle(store)
        let dir = URL(fileURLWithPath: arg)
        guard case .success(let only) = store.exportPageSelection else {
            print("  导出范围写错了：\(store.exportBlockedReason ?? "")")
            return true
        }
        if let ask = CollageStore.exportConfirmation(store.preflight(texts: false), project: store.project, pages: only) {
            print("  导出按钮会先问：\(ask.title)（这里照「仍然导出」走）")
        }
        // startExport 写进 store 的输出目录（导出按钮那个）：同 export: 先换成这个目录。
        store.exportOptions.outputPath = dir.path
        let options = store.exportOptions
        var outcome: CollageStore.ExportOutcome?
        let refused = store.startExport(project: store.project, options: options, name: store.exportName, reveal: false,
                                        pages: only) { outcome = $0 }
        if refused == nil { spin(600) { outcome != nil } }
        spin(5) { !store.isExporting }
        guard let outcome else {
            print("  导出超时")
            return true
        }
        print("  导出 → " + (outcome.files.isEmpty ? "（没写出文件）" : outcome.files.joined(separator: " "))
              + (outcome.failure.map { " · 失败: \($0)" } ?? "") + (outcome.warning.map { " · 提示: \($0)" } ?? ""))
        print("  " + store.progressText)
        // 第一张图的色彩、JPEG 是不是基线（核对规格的 sRGB / Adobe RGB 有没有生效）。
        if let first = outcome.files.first(where: { !$0.hasSuffix(".pdf") }) {
            let url = dir.appendingPathComponent(first)
            if let data = try? Data(contentsOf: url), let src = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let profile = props[kCGImagePropertyProfileName] as? String ?? "（没有）"
                let baseline = CollageExport.jpegIsBaseline(data).map { $0 ? "基线" : "渐进" } ?? "—"
                let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                print("  \(first)：\(w)x\(h) · 色彩 \(profile) · \(baseline) · \(data.count / 1024) KB")
            }
        }
        return true
    }
}
