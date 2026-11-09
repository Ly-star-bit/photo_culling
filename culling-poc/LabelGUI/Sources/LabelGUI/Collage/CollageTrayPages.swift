import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 左栏：照片 | 模板 | 素材（照 Canva 的左侧面板）
//
// 照片 = 原来的托盘（CollageTray，一点没动：网格的 Equatable、--perf trayclick 量的都是它）。
// 模板 = 一键成套、模板库、我的模板（存 / 导入 / 导出）：以前在检视器「版式」页最底下。
// 素材 = 文字格、手写字、贴纸、改成印样：以前分在「版式」「文字」两页。
// 模板页只在选中时建：模板缩略图不在看照片的时候渲。

struct CollageLeftPane: View {
    let store: CollageStore
    @ObservedObject var nav: CollageNav
    let batchStore: BatchStore
    @State private var dropTargeted = false

    init(store: CollageStore, batchStore: BatchStore) {
        self.store = store
        self.nav = store.nav
        self.batchStore = batchStore
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $nav.trayTab) {
                ForEach(CollageTrayTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .help("照片：托盘；模板：一键成套和模板库；素材：文字格、手写字、贴纸、印样")
            switch nav.trayTab {
            case .photos: CollageTray(store: store, batchStore: batchStore)
            case .templates: CollageTemplatesPage(store: store)
            case .assets: CollageAssetsPage(store: store)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(3)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        // 文件拖到左栏哪一页都收进托盘（收完切到「照片」看得见）。
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let url = await CollageCanvasDropDelegate.loadURL(p) { urls.append(url) }
                }
                store.addFiles(urls)
                if !urls.isEmpty { store.nav.trayTab = .photos }
            }
            return true
        }
    }
}

// MARK: - 模板

struct CollageTemplatesPage: View {
    @ObservedObject var store: CollageStore
    @State private var templateToDelete: String?
    /// 「整本婚礼相册」落下来会替换现有跨页时先问的那句话（F6，store.arrangeConfirmation）。
    @State private var weddingAsk: String?

    var body: some View {
        let _ = CollagePerf.body("模板页")
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.project.photos.isEmpty { emptyNotice }
                    kitsBox
                    CollageTemplateGallery(store: store) { templateToDelete = $0 }
                        .collageSpot(.templates, store.nav)
                    CollageMyTemplatesBox(store: store)
                        .collageSpot(.saveTemplate, store.nav)
                }
                .padding(10)
            }
            .collageScrollTarget(.tray, nav: store.nav, proxy: proxy)
        }
        .confirmationDialog("删除模板？", isPresented: Binding(
            get: { templateToDelete != nil },
            set: { if !$0 { templateToDelete = nil } }
        ), presenting: templateToDelete) { name in
            Button("删除「\(name)」", role: .destructive) { store.deleteTemplate(name) }
            Button("取消", role: .cancel) {}
        }
        .alert("按婚礼相册重排整本？", isPresented: Binding(
            get: { weddingAsk != nil },
            set: { if !$0 { weddingAsk = nil } }
        )) {
            Button("重排") { store.applyKit(.weddingAlbum) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(weddingAsk ?? "")
        }
    }

    /// 托盘空时模板全灰：把原因直接写出来（以前只在悬停提示里，NU7）。
    private var emptyNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("托盘里还没有照片，模板先灰着", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
            CollageJumpText(store: store, lead: "模板要往格子里放照片：先在", spot: .photos, tail: "里点「带照片」，",
                            title: "照片")
            Text(store.batch == nil ? "或者把照片文件拖到左栏。"
                 : "或者直接点下面的一键成套（从批量页的选片结果拿照片）。")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 一键成套：放最上面，一套一个按钮（以前是「版式」页最底下一个小菜单）。
    private var kitsBox: some View {
        GroupBox("一键成套") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(CollageKitID.allCases) { kit in
                    Button {
                        // 已经排好的相册：整本婚礼相册会把没锁的跨页全换掉，先问一句（F6；MCP、命令行不问）。
                        if kit == .weddingAlbum, let ask = store.arrangeConfirmation {
                            weddingAsk = ask
                        } else {
                            store.applyKit(kit)
                        }
                    } label: {
                        Text(kit.name).frame(maxWidth: .infinity)
                    }
                    .help(kit.summary)
                }
                Button("换封面（出一期）") { store.applyKit(.fashionIssue, coverStep: 1) }
                    .font(.caption)
                    .disabled(CollageStyleFashion.coverPhotoID(store.project) == nil)
                    .help("在前 \(CollageStyleFashion.coverChoices) 个主图候选里换下一张当封面，内页留着")
                Text("一次出一整套：一期杂志、一卷印样、一本婚礼相册（替换当前拼图，可以撤销）")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(store.isSolving || (store.project.photos.isEmpty && store.batch == nil))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .collageSpot(.kits, store.nav)
    }
}

/// 我的模板：把当前版存成模板（起名字、自适应开关）、导入、导出。「格式 › 这一页」的「存成模板…」跳到这里。
struct CollageMyTemplatesBox: View {
    @ObservedObject var store: CollageStore
    @State private var templateName = ""
    /// nil = 跟着这一页（套固定比例的模板来的默认关）。
    @State private var templateFits: Bool?

    var body: some View {
        GroupBox("我的模板") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("把这一页的版式存成模板…", text: $templateName)
                        .onSubmit { saveTemplate() }
                    Button("存") { saveTemplate() }
                        .disabled(templateName.trimmingCharacters(in: .whitespaces).isEmpty || store.root == nil)
                }
                Toggle("套用时按照片比例自适应", isOn: Binding(get: { fitsOnSave }, set: { templateFits = $0 }))
                    .font(.caption)
                    .help("关掉 = 固定比例，照片按格子裁（严格网格、月洞门这种）；散落版总是原样摆放")
                HStack {
                    Button("导入模板…") { importTemplates() }
                    Button("导出我的模板…") { exportTemplates() }
                        .disabled(store.userTemplates.isEmpty)
                }
                .font(.caption)
                Text("存过的在上面「我的模板」一组里；右键可以删。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var fitsOnSave: Bool { templateFits ?? !(store.page?.fixedAspects ?? false) }

    private func saveTemplate() {
        store.saveTemplate(named: templateName, fitAspects: fitsOnSave)
        templateName = ""
        templateFits = nil
    }

    private func importTemplates() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { store.importTemplates(from: url) }
    }

    private func exportTemplates() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "拼图模板.json"
        if panel.runModal() == .OK, let url = panel.url { store.exportTemplates(to: url) }
    }
}

// MARK: - 素材

struct CollageAssetsPage: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        let _ = CollagePerf.body("素材页")
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    textCellBox
                        .collageSpot(.textCells, store.nav)
                    CollageDecorBox(store: store)
                        .collageSpot(.stickers, store.nav)
                    contactBox
                        .collageSpot(.contactSheet, store.nav)
                }
                .padding(10)
            }
            .collageScrollTarget(.tray, nav: store.nav, proxy: proxy)
        }
    }

    /// 加文字格：四个方向一套按钮（以前「版式」页是 上 / 下 / 左·竖排 / 右·竖排，「文字」页是 上方横排 / 右侧竖排 / 手写字，
    /// 同一件事两套叫法，NU4）。选中格子时加在那一格旁边，否则加在整版的这一边。
    private var textCellBox: some View {
        GroupBox("文字格") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    textCellButton("上方横排", edge: .top, vertical: false)
                    textCellButton("下方横排", edge: .bottom, vertical: false)
                    textCellButton("左侧竖排", edge: .left, vertical: true)
                    textCellButton("右侧竖排", edge: .right, vertical: true)
                }
                .disabled(store.root == nil || store.isFreeform)
                Text(store.isFreeform ? "散落版没有格子：用下面的「加手写字」。"
                     : "选中一个格子时加在那一格旁边，否则加在整版的这一边。点画布上的文字格，右栏「格式」里改字。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func textCellButton(_ title: String, edge: CollageLayout.Edge, vertical: Bool) -> some View {
        Button { store.addTextCell(edge: edge, vertical: vertical) } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .font(.caption)
        .help(store.isFreeform ? "散落版没有格子：用「加手写字」" : "")
    }

    private var contactBox: some View {
        GroupBox("印样") {
            VStack(alignment: .leading, spacing: 8) {
                Button("改成印样") { store.makeContactSheet() }
                    .disabled(store.project.photos.isEmpty)
                    .help("托盘的照片按拍摄先后排成一卷：连续的片条、齿孔、帧号，精选红圈、废片打叉（可以撤销）"
                          + (store.isAlbum ? "。相册跨页里印样放在右页，不跨中缝；别的跨页用了的照片不拿" : ""))
                CollageJumpText(store: store, lead: "这一页换成一卷印样（托盘的照片按拍摄先后排）。规格、记号、改回网格在右栏",
                                spot: .contact, tail: "里。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}
