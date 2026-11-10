import SwiftUI

// MARK: - 界面：印厂规格（文档 › 画布）、导出前检查 / 范围 / 看版（导出 ▾）—— 相册 B · P 道
//
// 模型在 CollagePrintSpec.swift / CollagePreflight.swift / CollageProofPDF.swift；改动都走 store 的方法（进撤销栈）。

/// 「文档 › 画布」相册的那个菜单：内置规格（按装订分两节）、我的规格、「存成规格…」「删除我的规格」。
struct CollagePrintSpecMenu: View {
    @ObservedObject var store: CollageStore
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let canvas = store.project.canvas
        Menu {
            Section("平铺对裱 · 保守默认，照印厂给的改") {
                ForEach(CollagePrintSpec.builtin.filter { $0.binding == .layflat }) { item($0, canvas: canvas) }
            }
            Section("胶装锁线 · 保守默认，照印厂给的改") {
                ForEach(CollagePrintSpec.builtin.filter { $0.binding == .glued }) { item($0, canvas: canvas) }
            }
            if !store.userPrintSpecs.isEmpty {
                Section("我的规格") {
                    ForEach(store.userPrintSpecs) { item($0, canvas: canvas) }
                }
            }
            Divider()
            Button("存成规格…") {
                newName = canvas.name
                naming = true
            }
            if !store.userPrintSpecs.isEmpty {
                Menu("删除我的规格") {
                    ForEach(store.userPrintSpecs) { spec in
                        Button(spec.name) { store.deletePrintSpec(named: spec.name) }
                    }
                }
            }
        } label: {
            // 名字还是某条规格、内容已经改过（换了装订、改了页数 / 色彩）：标「改过」，别让人以为还是原样。
            let edited = store.printSpecs.contains { $0.name == canvas.name && !$0.matches(canvas) }
            Text(canvas.name + (edited ? "（改过）" : "")).lineLimit(1)
        }
        .help("印厂规格：单页尺寸、出血、安全区、装订、页数、色彩一起换（内置的都是保守默认，照印厂给的改）。"
              + "换了尺寸版式按比例缩放")
        .alert("存成规格", isPresented: $naming) {
            TextField("名字", text: $newName)
            Button("存") { store.savePrintSpec(named: newName) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("现在的尺寸、出血、安全区、装订、页数、色彩存成一条（存在全局设置里），以后在这个菜单里直接选。同名的覆盖。")
        }
    }

    @ViewBuilder
    private func item(_ spec: CollagePrintSpec, canvas: CollageCanvas) -> some View {
        Button {
            store.applyPrintSpec(spec)
        } label: {
            if spec.matches(canvas) {
                Label(spec.name, systemImage: "checkmark")
            } else {
                Text(spec.name)
            }
        }
        .help(spec.detail)
    }
}

/// 相册的自定义尺寸：填单页的 cm（跨页宽 = 2 × 单页宽）。社交画布那一栏照旧填像素（CollageCanvasBox）。
struct CollagePageSizeFields: View {
    @ObservedObject var store: CollageStore
    @State private var width = ""
    @State private var height = ""

    var body: some View {
        HStack(spacing: 4) {
            Text("单页")
            TextField("宽", text: $width).frame(width: 52)
            Text("×")
            TextField("高", text: $height).frame(width: 52)
            Text("cm").font(.caption).foregroundStyle(.secondary)
            Button("应用") { apply() }
                .disabled(parsed == nil)
        }
        .font(.caption)
        .help("单页的宽、高（cm）：跨页宽是它的两倍；dpi、出血、安全区、装订、页数规则不变")
        .onAppear { sync() }
        .onChange(of: store.project.canvas) { _, _ in sync() }
    }

    private var parsed: (Double, Double)? {
        let range = CollagePrintSpec.pageCMRange
        guard let w = Double(width.replacingOccurrences(of: ",", with: ".")),
              let h = Double(height.replacingOccurrences(of: ",", with: ".")),
              range.contains(w), range.contains(h) else { return nil }
        return (w, h)
    }

    private func sync() {
        let size = store.project.canvas.pageSizeCM
        width = Self.text(size.width)
        height = Self.text(size.height)
    }

    static func text(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    private func apply() {
        guard let (w, h) = parsed else { return }
        store.setPageSizeCM(width: w, height: h)
    }
}

/// 「文档 › 画布」相册：页数规则、首尾单页、中缝带、色彩、JPEG。没套规格的相册显示的是保守默认，一改就记进这本。
struct CollagePrintRulesBox: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        let canvas = store.project.canvas
        let rules = canvas.effectivePrintRules
        let count = store.project.pages.count
        let problem = canvas.pageProblem(spreads: count)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("页数")
                Stepper(value: rule(\.minPages), in: CollagePrintRules.pageLimit.lowerBound...rules.maxPages, step: 2) {
                    Text("\(rules.minPages)").monospacedDigit()
                }
                .fixedSize()
                Text("–")
                Stepper(value: rule(\.maxPages), in: rules.minPages...CollagePrintRules.pageLimit.upperBound, step: 2) {
                    Text("\(rules.maxPages)P").monospacedDigit()
                }
                .fixedSize()
                Text("每次加")
                // 跨页只能 2P 一加：每次加几 P 只给偶数（2、4、6…；MCP、旧工程里的奇数一点就变成偶数）。
                Stepper(value: evenStep, in: CollagePrintRules.evenStepRange, step: 2) {
                    Text("\(rules.pageStep)P").monospacedDigit()
                }
                .fixedSize()
            }
            .help("印厂说的「P」是单页：1 个跨页 = 2P，所以跨页只能 2P 一加。最少、最多几 P，每次能加几 P（照印厂给的改）")
            pageLine(rules: rules, count: count, problem: problem)
            Toggle("首尾单页（第一页、最后一页贴在封板上）", isOn: rule(\.singleEnds))
                .toggleStyle(.checkbox)
                .help("有的平铺册第一页、最后一页贴在封板上：第 1 个跨页的左页、最后一个跨页的右页印不出来，"
                      + "导出前检查会提醒那半边别放照片和字。页数照「跨页 × 2」算，首尾怎么数照印厂的核对")
            foldRow(canvas)
            Picker("色彩", selection: rule(\.colorSpace)) {
                ForEach(CollageColorSpace.allCases, id: \.self) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("导出的跨页图和印刷 PDF 用哪个色彩：排版、预览照旧在 sRGB 里，导出时转、嵌配置文件。印厂没要 Adobe RGB 就用 sRGB")
            HStack(spacing: 4) {
                Picker("JPEG 质量", selection: rule(\.jpegQuality)) {
                    Text("跟导出设置").tag(Double?.none)
                    ForEach([0.9, 0.95, 1.0], id: \.self) { q in Text("\(Int(q * 100))").tag(Double?(q)) }
                }
                .fixedSize()
                Text("· 基线（baseline）").foregroundStyle(.secondary)
            }
            .font(.caption)
            .help("印厂常要「JPEG 质量拉满、基线（不是渐进式）」：导出写的一直是基线 JPEG，这里只定质量")
            Text("这些是保守默认：照印厂给的改。改好了点上面的菜单「存成规格…」，下次直接选")
                .collageHint()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 「= 10–30 个跨页；现在 4 个跨页 = 8P，少了 12P」：不合规标橙。
    @ViewBuilder
    private func pageLine(rules: CollagePrintRules, count: Int, problem: String?) -> some View {
        let range = "= \(CollagePrintRules.spreads(rules.minPages))–\(rules.maxPages / 2) 个跨页"
        let now = count > 0 ? "；现在 \(count) 个跨页 = \(rules.pages(spreads: count))P" : ""
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(AppPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(range + now)
                .collageHint()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 中缝带每侧：自动（平铺短边 2%、胶装至少 12mm）或者填印厂给的 mm。只管现在这种装订的那一个数。
    @ViewBuilder
    private func foldRow(_ canvas: CollageCanvas) -> some View {
        let glued = canvas.binding == .glued
        let set: Double? = glued ? canvas.printRules?.gluedFoldMM : canvas.printRules?.layflatFoldMM
        let now = canvas.foldBand / max(1, canvas.dpi) * 25.4
        HStack(spacing: 4) {
            Text("中缝带每侧")
            Toggle("自动", isOn: Binding(get: { set == nil }, set: { auto in
                setFold(auto ? nil : (now * 2).rounded() / 2)
            }))
            .toggleStyle(.checkbox)
            if let mm = set {
                Stepper(value: Binding(get: { mm }, set: { setFold($0) }), in: CollagePrintRules.foldRangeMM, step: 0.5) {
                    Text(String(format: "%.1fmm", mm)).monospacedDigit()
                }
                .fixedSize()
            } else {
                Text(String(format: "%.1fmm", now)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.caption)
        .help("中缝两侧各让出多宽不放脸、字（\(glued ? "胶装" : "平铺")）。自动 = 平铺短边 2%、胶装至少 12mm；印厂给了数就填它")
    }

    private func setFold(_ mm: Double?) {
        var rules = store.project.canvas.effectivePrintRules
        let glued = store.project.canvas.binding == .glued
        if glued { rules.gluedFoldMM = mm } else { rules.layflatFoldMM = mm }
        // 撤销按项合并：中缝带是自己的一项（平铺、胶装各一个），不和页数、色彩并成一步。
        let item: WritableKeyPath<CollagePrintRules, Double?> = glued ? \.gluedFoldMM : \.layflatFoldMM
        store.setPrintRules(rules, coalesce: true, key: item)
    }

    /// 「每次加几 P」：只给偶数，奇数往上取到偶数（同一项撤销）。
    private var evenStep: Binding<Int> {
        Binding(get: { store.project.canvas.effectivePrintRules.pageStep },
                set: { value in rule(\.pageStep).wrappedValue = CollagePrintRules.evenStep(value) })
    }

    /// 规则框的一项：连着点同一个步进器合成一步撤销，换一项（页数 → 色彩）新开一步（key = 这一项的 keyPath）。
    private func rule<T>(_ keyPath: WritableKeyPath<CollagePrintRules, T>) -> Binding<T> {
        Binding(get: { store.project.canvas.effectivePrintRules[keyPath: keyPath] },
                set: { value in
                    var rules = store.project.canvas.effectivePrintRules
                    rules[keyPath: keyPath] = value
                    if rules.maxPages < rules.minPages { rules.maxPages = rules.minPages }
                    store.setPrintRules(rules, coalesce: true, key: keyPath)
                })
    }
}

// MARK: - 导出 ▾：范围、导出前检查、看版

/// 「导出 ▾」里相册的范围：全部 / 当前跨页 / 自定义「1-3, 7」。部分导出只写那几张跨页图、不出 PDF。
struct CollageExportRangeBox: View {
    @ObservedObject var store: CollageStore
    @State private var custom = ""

    enum Kind: Hashable { case all, current, custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("范围", selection: kind) {
                Text("全部").tag(Kind.all)
                Text(Self.currentLabel(editingCover: store.editingCover, pageIndex: store.pageIndex)).tag(Kind.current)
                Text("自定义").tag(Kind.custom)
            }
            .pickerStyle(.segmented)
            .help("只导某几个跨页：改了一页不用整本重渲。文件名里的序号还是原来的跨页号"
                  + (store.editingCover ? "。正在编辑封面：「当前跨页」是封面底下那个跨页，封面只在导「全部」时写" : ""))
            if case .custom = store.exportRange {
                TextField("跨页号，比如 1-3, 7", text: Binding(get: { custom }, set: { text in
                    custom = text
                    store.exportRange = .custom(text)
                }))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }
            status
        }
        .onAppear {
            if case .custom(let text) = store.exportRange { custom = text }
        }
    }

    /// 「当前跨页」那一段的字：编辑封面时画布上是封面，「当前」导的却是封面底下那个跨页（封面不写）—— 写明是第几个
    /// （R2#9）。分段控件没法单独灰掉一段。
    static func currentLabel(editingCover: Bool, pageIndex: Int) -> String {
        editingCover ? "当前跨页（第 \(pageIndex + 1) 个）" : "当前跨页"
    }

    private var kind: Binding<Kind> {
        Binding(get: {
            switch store.exportRange {
            case .all: return .all
            case .current: return .current
            case .custom: return .custom
            }
        }, set: { k in
            switch k {
            case .all: store.exportRange = .all
            case .current: store.exportRange = .current
            case .custom: store.exportRange = .custom(custom)
            }
        })
    }

    @ViewBuilder
    private var status: some View {
        switch store.exportPageSelection {
        case .success(nil):
            EmptyView()
        case .success(let only?):
            let pdf = store.exportOptions.pdf ? "、不出 PDF（缺页的 PDF 不能拿去印，要 PDF 选「全部」）" : ""
            let cover = store.project.bookCover != nil ? "、不写封面" : ""
            Text("只导第 \(CollageExportRange.label(only)) 个跨页（\(only.count) 个）：只写这几张跨页图\(pdf)\(cover)；文件名里的序号还是原来的跨页号")
                .collageHint()
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let bad):
            Label(bad.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(AppPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 「导出 ▾」里的「导出前检查」：一行一条（拦的在前），点一下跳到那个跨页、选中那一格。后台算（要低清渲每页拿字的位置）。
struct CollagePreflightBox: View {
    @ObservedObject var store: CollageStore
    @StateObject private var runner = CollagePreflightRunner()
    /// 最多列几条（弹出框按内容高度排，太长就盖住画布了）。
    static let shownLimit = 6

    var body: some View {
        GroupBox("导出前检查") {
            VStack(alignment: .leading, spacing: 5) {
                if let issues = runner.issues {
                    let head = CollagePreflight.summary(issues) + (runner.running ? " · 更新中…" : "")
                    Label(head, systemImage: issues.isEmpty ? "checkmark.circle" : "list.bullet")
                        .font(.caption)
                        .foregroundStyle(issues.isEmpty ? .secondary : .primary)
                    // 按序号认（同一格两块字压出安全区、首行又一样时 id 会重）。
                    ForEach(Array(issues.prefix(Self.shownLimit).enumerated()), id: \.offset) { row($0.element) }
                    if issues.count > Self.shownLimit {
                        Text("还有 \(issues.count - Self.shownLimit) 条（拦的在前；改好前面的再看）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if issues.contains(where: { $0.severity == .block }) {
                        Text("有「拦」的，点导出时会先问一句")
                            .collageHint()
                    }
                } else {
                    Text("检查中…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .task(id: CollagePreflightRunner.key(store)) { runner.refresh(store) }
    }

    private func row(_ issue: CollagePreflightIssue) -> some View {
        let block = issue.severity == .block
        return Button {
            store.reveal(issue)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: block ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(block ? Color.red : AppPalette.warning)
                Text(issue.message)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.rowHelp(issue))
    }

    /// 那一行的悬停说明：封面的几条指到封面（以前和页数一样写「在「文档 › 画布」里改规格」，对不上）。
    static func rowHelp(_ issue: CollagePreflightIssue) -> String {
        if issue.kind == .cover {
            return issue.path != nil ? "封面上的事：点一下进封面编辑、选中那一格"
                : "封面上的事：点一下去「文档 › 封面」（书脊宽、包边、封面的版式在那里改）"
        }
        return issue.page == nil ? "整本的事：在「文档 › 画布」里改规格，或者加减跨页" : "点一下跳到那个跨页、选中那一格"
    }
}

/// 「导出 ▾ › 印刷」里的「出看版 PDF」（相册）。
struct CollageProofButton: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        Button {
            store.nav.exportShown = false
            store.startProofPDF(project: store.project, name: store.exportName, reveal: true)
        } label: {
            Label("出看版 PDF", systemImage: "doc.richtext")
        }
        .disabled(blocked != nil)
        .help(blocked ?? "给客户看版：每个跨页一页（长边约 2000 px），页脚印「跨页 7 / 20 · 标题」和照片文件名；"
              + "不带出血、裁切线。写成「名_看版.pdf」，不覆盖")
    }

    private var blocked: String? {
        if store.isExporting { return "正在导出" }
        if store.project.pages.isEmpty { return "还没有跨页" }
        if store.outputFolder == nil { return "先选择输出目录" }
        return store.cardOutputRefusal
    }
}
