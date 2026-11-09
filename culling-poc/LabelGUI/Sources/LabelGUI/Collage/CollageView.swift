import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 拼图 tab：左栏（照片 / 模板 / 素材）· 中画布 · 右检视器（格式 / 样式 / 文档），底部方案栏、跨页条、备选版式。
/// 两边的页签在 store.nav（CollageNav.swift）：选中画布上的东西右栏切到「格式」，指路的字、「带我去」都走它。
struct CollageView: View {
    @ObservedObject var store: CollageStore
    /// 不整份订阅批量页（分析进度、判决计数一变，整个拼图页都跟着重算）：换场次由 CollageSessionWatch 盯，
    /// 托盘「带照片」菜单的计数由 CollageTrayHeader 自己订阅。
    let batchStore: BatchStore
    /// 检视器「文档 › 水印」读水印页的签名、设置和预设；只在那一块里观察它（水印页预览一动，拼图页不跟着重算）。
    let watermarkStore: WatermarkStore
    @State private var autoCount = 6
    @State private var dedupeAlbum = true
    /// 「自动编排」会替换已经排好的跨页时先问的那句话（F6，store.arrangeConfirmation）；nil = 没在问。
    @State private var arrangeAsk: String?
    /// 快捷键一览（状态栏键盘按钮、? 键）。
    @State private var showShortcuts = false

    init(store: CollageStore, batchStore: BatchStore, watermarkStore: WatermarkStore) {
        self.store = store
        self.batchStore = batchStore
        self.watermarkStore = watermarkStore
    }

    var body: some View {
        let _ = CollagePerf.body("拼图页")
        Group {
            // 暗房开着：整页换成暗房工作台（和批量页的审片、连拍挑选一样整个换掉，画布不在视图树里，
            // 它的 ←→、Esc 就不会和暗房的抢）。
            if let darkroom = store.darkroom {
                CollageDarkroomView(model: darkroom, store: store)
            } else {
                editor
            }
        }
        .onAppear {
            attachSession()
            // 主体蒙版的模型第一次加载要 0.1–1 秒：一进拼图 tab 先在后台空跑一次。
            CollageMasks.warmUp()
        }
        .background(CollageSessionWatch(batchStore: batchStore) { attachSession() })
        // 导出前检查有「拦」的（空照片格、放大超过 150%、页数不合规……）时导出前问一次（store.export 设 exportConfirm、标题）
        .alert(store.exportConfirmTitle, isPresented: exportConfirmShown) {
            Button("仍然导出") { store.export(confirmed: true) }
            Button("取消", role: .cancel) { store.exportConfirm = nil }
        } message: {
            Text(store.exportConfirm ?? "")
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                // 模板格最小 86pt：两列要 230 左右（以前 190，模板挪进左栏以后一列太浪费）。
                // 230 + 画布 420 + 检视器 300 = 950，最窄的窗口（960）里照样放得下。
                CollageLeftPane(store: store, batchStore: batchStore)
                    .frame(minWidth: 230, idealWidth: 250, maxWidth: 340)
                // 选中画布上的照片、文字、贴纸：右栏切到「格式」（NU3）；双击文字 / 照片上的字：切过去并滚到编辑器。
                // 相册开着整本概览时这一块换成网格（CollageAlbumOverview）。
                CollageCanvasArea(store: store, isAlbum: store.isAlbum)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                CollageInspector(store: store, watermarkStore: watermarkStore)
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
            }
            Divider()
            bottomStrips
            Divider()
            statusBar
        }
        // 离屏快照截不到弹出框（单独一个窗口）：--collage-ui 把「导出 ▾」的内容画在顶栏下面。
        .overlay(alignment: .topTrailing) {
            if SnapshotPreview.inlineExport { CollageInlineExport(store: store) }
        }
        // ? 开关快捷键一览（焦点不在画布、托盘上也接；正在输入框里打字时不接，见 ShortcutsKey）。暗房开着时编辑器不在视图树里，
        // 暗房自己接 ?。
        .shortcutsHotkey(isPresented: $showShortcuts)
        // ⌘← ⌘→ 换跨页（封面在第一个跨页前面）、G 整本概览：同 ? 键，输入框里打字时不接（⌘← 是挪到行首）。
        .collageAlbumKeys(store: store)
    }

    private var exportConfirmShown: Binding<Bool> {
        Binding(get: { store.exportConfirm != nil }, set: { if !$0 { store.exportConfirm = nil } })
    }

    private func attachSession() {
        let dir = batchStore.photoDir
        store.attach(sessionDir: dir == nil ? nil : batchStore.sessionDir, photoDir: dir, batch: batchStore)
    }

    // MARK: - 顶栏

    /// 单张 / 相册 … 撤销 重做 参考线 方案 | 暗房 导出 ▾。窗口窄、放不下整排时（960 宽的相册，婚礼 fine-art 最挤）
    /// 换紧凑的一排：间距收一点、暗房只留图标、「导出相册」写成「导出」、「编排」两个字不写（ViewThatFits 按整排的
    /// 理想宽度挑，放得下就是完整的那排）。
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarRow(compact: false)
            topBarRow(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .background(topBarShortcuts)
    }

    /// 顶栏的快捷键只挂一份：两排（完整 / 紧凑）里的按钮都不挂，这里一组看不见的按钮挂（ViewThatFits 没挑中的那一排
    /// 不能也接一次 ⌘Z）。能不能按和看得见的那个按钮同一个条件（灰着的时候快捷键也不动）。
    private var topBarShortcuts: some View {
        ZStack {
            Button("撤销") { store.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
            Button("重做") { store.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
            Button("存成方案") { store.saveVariant() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store.project.pages.isEmpty || store.isSolving)
            Button("导出") { store.export() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.exportBlockedReason != nil)
            if store.isExporting {
                Button("取消导出") { store.cancelExport() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func topBarRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            Picker("", selection: Binding(get: { store.project.mode }, set: { store.setMode($0) })) {
                Text("单张拼图").tag(CollageMode.single)
                Text("相册").tag(CollageMode.album)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("单张：一张拼图（朋友圈/小红书/九宫格/轮播）；相册：多个跨页，印刷用")

            if store.isAlbum {
                albumControls(compact: compact)
            } else {
                singleControls
            }

            Divider().frame(height: 18)
            editButtons
            Spacer(minLength: 8)
            trailingButtons(compact: compact)
        }
    }

    /// 撤销、重做、参考线、存成方案：只放图标（顶栏在最窄的窗口里已经挤满了）。快捷键在 topBarShortcuts。
    @ViewBuilder
    private var editButtons: some View {
        Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            .disabled(!store.canUndo)
            .help("撤销 (⌘Z)")
        Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
            .disabled(!store.canRedo)
            .help("重做 (⇧⌘Z)")
        Toggle(isOn: Binding(get: { store.showGuides }, set: { store.showGuides = $0; store.setNeedsRender() })) {
            Image(systemName: "rectangle.dashed")
        }
        .toggleStyle(.button)
        .help("参考线：安全区、中缝、九宫格/轮播切线（不会导出）")
        Button { store.saveVariant() } label: { Image(systemName: "plus.square.on.square") }
            .disabled(store.project.pages.isEmpty || store.isSolving)
            .help("把现在的拼图存成方案（⇧⌘S）：底下的方案栏里点缩略图随时切回来，可以存好几个比着挑")
    }

    @ViewBuilder
    private func trailingButtons(compact: Bool) -> some View {
        if store.isExporting {
            Button("取消") { store.cancelExport() }
                .help("停止导出 (Esc)")
        }
        // 暗房进顶栏（NU2）：以前唯一的入口在样式页色调块最底下。整组进；只改这一页 / 这一格从「格式」里进。
        Button {
            store.openDarkroom()
        } label: {
            if compact {
                Image(systemName: "film")
            } else {
                Label("暗房", systemImage: "film")
            }
        }
        .buttonStyle(.bordered)
        .tint(CollageDarkroomButton.amber)
        // 编辑封面时不进暗房（暗房按「当前跨页」套色调，会改到封面底下那个跨页上）。
        .disabled(store.page == nil || !CollageAlbumRules.allows(.darkroom, editingCover: store.editingCover))
        .help(store.editingCover ? "编辑封面时不进暗房：先点跨页条上的一个跨页" : CollageDarkroomButton.projectHelp)
        .collageSpot(.darkroom, store.nav)
        CollageExportButtons(store: store, compact: compact)
            .collageSpot(.export, store.nav)
    }

    private var singleControls: some View {
        HStack(spacing: 8) {
            Stepper(value: $autoCount, in: 1...16) {
                Text("\(autoCount) 张").monospacedDigit()
            }
            .fixedSize()
            .help("自动排版用几张")
            Picker("", selection: Binding(get: { store.effectiveLayoutStyle }, set: { store.setLayoutStyle($0) })) {
                ForEach(CollageStore.LayoutStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 104)
            .help("网格：照片按原比例拼满；散落：像拍立得撒在桌上（斜放、叠放、胶带），脸不会被压住")
            Button("自动排版") { store.autoLayout(count: autoCount) }
                .disabled(store.project.photos.isEmpty || store.isSolving)
                .help("从托盘按分数和多样性挑 \(autoCount) 张，排出一批备选版式")
            // ←、→、「换一批」在备选条最左边（本来就是管备选的）。
            if store.isSolving { ProgressView().controlSize(.small) }
        }
    }

    private func albumControls(compact: Bool) -> some View {
        // 编排主题：默认 / 婚礼 fine-art（一键成套「整本婚礼相册」设成 fine-art；之后的「自动编排」按它编）。
        let fineArt = store.project.albumTheme == .fineArt
        return HStack(spacing: 8) {
            Picker("编排", selection: Binding(get: { store.project.albumTheme }, set: { store.setAlbumTheme($0) })) {
                ForEach(CollageAlbumTheme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .modifier(CollageHideLabels(on: compact))
            .fixedSize()
            .help("「自动编排」按哪套规则编：默认 = 分数最高的做扉页、横图铺满跨页；婚礼相册 = 扉页取宽景、"
                  + "每章疏 → 密 → 精选收尾、竖图成对、每跨页最多 3 张、不跨中缝（换了点「自动编排」生效）。"
                  + "纸、卡纸、≥ 25mm 的边距是样式：在「样式 › 风格」里选「婚礼 · 雅致」，左栏「模板」的一键成套「整本婚礼相册」两样一起设")
            Button("自动编排") {
                // 已经排好的相册：整本重排会替换没锁的跨页，先问一句（F6；命令行、MCP 直接调 store，不问）。
                if let ask = store.arrangeConfirmation {
                    arrangeAsk = ask
                } else {
                    store.autoArrangeAlbum(dedupe: dedupeAlbum)
                }
            }
                .disabled(store.project.photos.isEmpty)
                .alert("重新编排整本？", isPresented: Binding(get: { arrangeAsk != nil },
                                                        set: { if !$0 { arrangeAsk = nil } })) {
                    Button("重排") { store.autoArrangeAlbum(dedupe: dedupeAlbum) }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(arrangeAsk ?? "")
                }
                .help((fineArt ? "托盘里的照片按婚礼相册编成跨页：废片不要、同一场只留精选，扉页取宽景，每章疏 → 密 → 精选收尾"
                       : "托盘里的照片按时间和章节编成跨页：分数最高的做扉页，好片单独成页")
                      + "。客户选中的一张都不拿掉；右栏「文档 › 画布」里指定了跨页数就往那么多个跨页里塞（不删片）")
            Toggle("相似只留一张", isOn: $dedupeAlbum)
                .toggleStyle(.checkbox)
                .help(fineArt ? "只管画面相似的（关掉也不会全上：婚礼相册一直是同一场只留精选、连拍只留一张）；拿掉的仍在托盘里，可以拖回任何跨页"
                      : "连拍、同地同姿势的只留分数高的（拿掉的仍在托盘里，可以拖回任何跨页）")
            if fineArt {
                Toggle("整章黑白", isOn: Binding(get: { store.project.albumChapterMono },
                                              set: { store.setAlbumTheme(.fineArt, chapterMono: $0) }))
                    .toggleStyle(.checkbox)
                    .help("一章里黑白照片占三分之一以上，整章的跨页都转黑白（黑白一用就是一整章，不零星撒在几页里）；下次「自动编排」生效")
            }
            // 「换一批」在备选条最左边（婚礼 fine-art 的跨页按编排出版式，没有「换一批」，那里也不摆）。
            if store.isSolving { ProgressView().controlSize(.small) }
        }
        // 整组按自己要的宽度排（不折行、不截字）：顶栏的 HStack 按份给宽度，不先让右边的空当（Spacer）让出来 ——
        // 以前 960 宽、fine-art 时「相似只留一张」挤成两行；只给勾选框 fixedSize 又轮到「自动编排」截成「自动…」。
        .fixedSize()
    }

    // MARK: - 底部：跨页条 + 备选版式

    private var bottomStrips: some View {
        VStack(spacing: 0) {
            // 方案栏常驻（NU6）：以前存过才出现，没存过的人不知道有；空的时候是矮矮一条「+ 存成方案（⇧⌘S）」。
            CollageVariantStrip(store: store, thumbs: store.thumbs)
                .collageSpot(.variants, store.nav)
            Divider()
            // 相册的跨页条；单张拼图有好几页（一键成套的一期杂志、小红书轮播组图）时也显示（页条）。
            if store.isAlbum || store.project.pages.count > 1 {
                CollagePageStrip(store: store, thumbs: store.thumbs)
                Divider()
            }
            CollageAlternativeStrip(store: store)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let error = store.lastError {
                // 点一下弹出全文（可选中、复制）和最近的提示（ErrorNotice，审查 D03）。
                ErrorNotice(text: error, source: .collage, closeStyle: .tertiary) { store.lastError = nil }
            }
            if let busy = store.busyText {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let notice = store.notice {
                // 一行放不下就截掉尾巴（悬停看全文），不把状态栏撑高。
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).help(notice)
            }
            if !store.progressText.isEmpty {
                Text(store.progressText).font(.caption).foregroundStyle(.secondary)
            }
            if let fraction = store.progressFraction {
                ProgressView(value: fraction).frame(width: 140)
            }
            Text(canvasSummary).font(.caption).foregroundStyle(.tertiary)
            Button { showShortcuts.toggle() } label: { Image(systemName: "keyboard") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("快捷键一览 (?)")
                .popover(isPresented: $showShortcuts, arrowEdge: .top) { ShortcutsPanel(page: .collage) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var canvasSummary: String {
        let c = store.project.canvas
        let size = "\(c.width)×\(c.height)px"
        if c.isPrint {
            let w = Double(c.width) / c.dpi * 2.54
            let h = Double(c.height) / c.dpi * 2.54
            return "\(c.name) · " + String(format: "%.1f×%.1fcm @%.0fdpi", w, h, c.dpi)
        }
        return "\(c.name) · \(size)"
    }
}

// MARK: - 画布区：画布 / 整本概览

/// 中间那一块：平常是画布；相册开着整本概览（跨页条的「整本」、G）时换成网格。只订阅 albumUI（开关概览），
/// isAlbum 由 CollageView 传（它本来就订阅 store）：切回单张时概览自己关掉。
private struct CollageCanvasArea: View {
    let store: CollageStore
    @ObservedObject var ui: CollageAlbumUI
    let isAlbum: Bool

    init(store: CollageStore, isAlbum: Bool) {
        self.store = store
        self.ui = store.albumUI
        self.isAlbum = isAlbum
    }

    var body: some View {
        Group {
            if ui.overviewShown && isAlbum {
                CollageAlbumOverview(store: store)
            } else {
                CollageCanvasView(store: store,
                                  onEditText: { spot in store.go(spot) },
                                  onSelect: { store.nav.showFormat() })
            }
        }
        .onChange(of: isAlbum) { _, album in if !album, ui.overviewShown { ui.overviewShown = false } }
    }
}

// MARK: - 托盘

/// 只盯批量页换场次（photoDir），拼图页本身不整份订阅 BatchStore。
private struct CollageSessionWatch: View {
    @ObservedObject var batchStore: BatchStore
    let onChange: () -> Void

    var body: some View {
        Color.clear.onChange(of: batchStore.photoDir) { _, _ in onChange() }
    }
}

struct CollageTray: View {
    @ObservedObject var store: CollageStore
    /// 选中和筛选（store.tray）：只有托盘订阅。
    @ObservedObject var tray: CollageTrayState
    let batchStore: BatchStore

    /// 「用这几张重新排一版」最多几张（和顶栏自动排版的张数上限一样）。
    static let relayoutLimit = 16

    init(store: CollageStore, batchStore: BatchStore) {
        self.store = store
        self.tray = store.tray
        self.batchStore = batchStore
    }

    var body: some View {
        let _ = CollagePerf.body("托盘")
        let usage = store.photoUsage
        let visible = tray.visible(store.project.photos, usage: usage)
        let visibleIDs = visible.map(\.id)
        // 看得见的才算选中：筛「未用」时一张刚上了版（拖进画布、重排）就从网格里消失，撤销拿掉了刚带进来的 ——
        // 这些都不再算，「已选」的张数、「移除」按钮、⌫ 只管看得见的。
        let selected = tray.selection.intersection(visibleIDs)
        VStack(spacing: 0) {
            CollageTrayHeader(store: store, batchStore: batchStore)
            if !store.project.photos.isEmpty {
                filterBar(usage: usage)
                // 「已选 N 张」那一行一直占着位置（没选中时是操作提示）：以前第一次选中才冒出来，整列缩略图往下跳 26pt，
                // 正好跳在鼠标底下，点完像是点错了、卡了一下。
                selectionBar(selected, order: visibleIDs)
            }
            Divider()
            if store.project.photos.isEmpty {
                emptyTray
            } else if visible.isEmpty {
                emptyFilter
            } else {
                // 网格只拿自己要的值：拖缝、拖滑杆、预览重渲这些不改托盘的，整个网格（每格的悬停提示、右键菜单、
                // 拖拽源）都跳过不重算。单击换一张也一样：选中框每格自己订阅（tray.mark），网格只拿多选。
                let placeTarget = store.selection.flatMap { store.root?.node(at: $0)?.isLeaf == true ? $0 : nil }
                CollageTrayGrid(store: store, tray: tray, photos: visible, usage: usage,
                                dropped: store.albumDroppedIDs, multiSelection: selected.count > 1 ? selected : [],
                                fineArt: store.isAlbum && store.project.albumTheme == .fineArt,
                                placeTarget: placeTarget, pagePhotoIDs: store.page?.photoIDs)
                    .equatable()
            }
        }
        // 文件拖进来：整个左栏都收（CollageLeftPane），哪个页签都行。
        // 显示的变了（换了筛选、上了版、移除、撤销）：看不见的从选中里去掉。
        .onChange(of: visibleIDs) { _, ids in tray.prune(to: Set(ids)) }
    }

    /// 全部 / 未用 / 已用：先筛出没用上的再 ⌘A ⌫，就是批量清掉没用的。
    private func filterBar(usage: [String: Int]) -> some View {
        let used = store.project.photos.filter { usage[$0.id] != nil }.count
        return CollageTrayFilterBar(tray: tray, filter: tray.filter, used: used,
                                    unused: store.project.photos.count - used)
            .equatable()
    }

    private func selectionBar(_ selected: Set<String>, order: [String]) -> some View {
        let n = selected.count
        return HStack(spacing: 6) {
            if n == 0 {
                Text("单击选中 · ⌘ 加减 · ⇧ 连选 · 拖进画布").font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            } else {
                Text("已选 \(n) 张").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                // 多选以后最常见的意图：用这几张排一版（NU8：以前只在右键菜单里）。
                if n > 1 { relayoutButton(order.filter(selected.contains)) }
                Button("移除", role: .destructive) { store.removeFromTray(order.filter(selected.contains)) }
                    .controlSize(.small)
                    .help("从托盘移除选中的 \(n) 张（⌫）：版式里用到的格子留空，⌘Z 一次撤回")
                Button {
                    tray.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("取消选择（Esc）")
            }
        }
        // 选没选中都一样高：网格不跟着上下跳。
        .frame(height: 20)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// 「排一版」：和右键「用这 N 张重新排一版」同一个方法；排完取消托盘的选中（键盘焦点还在托盘上，紧接着按 ⌫ 不会把
    /// 刚排上的照片移出托盘，同 CollageTrayGrid.toCanvas）。超过 16 张灰着，悬停说为什么。
    private func relayoutButton(_ ids: [String]) -> some View {
        let tooMany = ids.count > Self.relayoutLimit
        return Button("排一版") {
            store.relayout(photoIDs: ids)
            tray.clear()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(tooMany || store.isSolving)
        .help(tooMany ? "一版最多 \(Self.relayoutLimit) 张：少选几张（现在 \(ids.count) 张）"
              : "用选中的 \(ids.count) 张重新排一版（右键里也有；⌘Z 撤回）")
    }

    private var emptyTray: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("点「带照片」拿精选进来\n或在批量页多选后点「拼图」\n也可以把文件拖到这里")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyFilter: some View {
        Text(tray.filter == .unused ? "托盘里的照片都上版了" : "还没有照片上版")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}

/// 托盘的「全部 / 未用 / 已用」。Equatable：点选换一张时托盘 body 会重算，这一条的分段控件不跟着更新
/// （每次更新都要把系统分段控件和它的辅助功能属性重设一遍，大托盘采样里占点一下的一成）。
private struct CollageTrayFilterBar: View, Equatable {
    /// 只用来改筛选（不订阅：外面的 CollageTray 订阅了，筛选、张数变了才传新的进来）。
    let tray: CollageTrayState
    let filter: CollageTrayState.Filter
    let used: Int
    let unused: Int

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.tray === b.tray && a.filter == b.filter && a.used == b.used && a.unused == b.unused
    }

    var body: some View {
        Picker("", selection: Binding(get: { tray.filter }, set: { tray.filter = $0 })) {
            ForEach(CollageTrayState.Filter.allCases, id: \.self) { f in
                Text(f == .all ? f.label : f == .unused ? "\(f.label) \(unused)" : "\(f.label) \(used)").tag(f)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .help("只看还没上版的 / 已经上版的照片。点选：单击、⌘ 点加减、⇧ 点连选、⌘A 全选；⌫ 移除选中的")
    }
}

/// 托盘标题和「带照片」菜单：菜单里的精选、可用张数跟着批量页，只有这一行订阅 BatchStore。
private struct CollageTrayHeader: View {
    @ObservedObject var store: CollageStore
    @ObservedObject var batchStore: BatchStore

    var body: some View {
        let unused = store.unusedTrayIDs
        let dropped = store.droppedTrayIDs
        let fineArt = store.isAlbum && store.project.albumTheme == .fineArt
        HStack(spacing: 6) {
            Text("托盘").font(.headline)
            Text("\(store.project.photos.count)").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Menu {
                Button("精选 (\(batchStore.verdictCounts.pick))") {
                    store.importVerdicts(batch: batchStore, includeUsable: false)
                }
                .disabled(batchStore.verdictCounts.pick == 0)
                Button("精选 + 可用 (\(batchStore.verdictCounts.pick + batchStore.verdictCounts.usable))") {
                    store.importVerdicts(batch: batchStore, includeUsable: true)
                }
                .disabled(batchStore.items.isEmpty)
                // 客户选中：批量页「导入客户选择」导进来的（不看判决，客户选中的废片也带）。没导入过就不占地方。
                if batchStore.clientPickCount > 0 {
                    Button("客户选中 (\(batchStore.clientPickCount))") { store.importClientPicks(batch: batchStore) }
                        .help("批量页导入的客户选择（紫心）。相册「自动编排」会把它们全部排上：客户选中的废片、同一场的第二张、连拍里的都不拿掉")
                }
                Button("精华 Top 20") { store.importTop(20, batch: batchStore) }
                    .disabled(batchStore.items.isEmpty)
                Divider()
                Button("添加文件…") { pickFiles() }
                Divider()
                // 拿出托盘，不碰版式（「清空托盘和版式」连版式一起清）。
                Button("移除没用上的（\(unused.count) 张）") { store.removeFromTray(unused) }
                    .disabled(unused.isEmpty)
                if !store.albumDropped.isEmpty {
                    Button(fineArt ? "移除编排拿掉的（\(dropped.count) 张）" : "移除相似拿掉的（\(dropped.count) 张）") {
                        store.removeFromTray(dropped)
                    }
                    .disabled(dropped.isEmpty)
                }
                Button("清空托盘和版式", role: .destructive) { store.clearTray() }
                    .disabled(store.project.photos.isEmpty)
            } label: {
                Label("带照片", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("从批量页带精选、客户选中进来，或添加外部照片（也可以直接把文件拖到这里）；也在这里移除没用上的")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { store.addFiles(panel.urls) }
    }
}

/// 托盘的照片网格。Equatable：只有显示的照片、上了几次、相似角标、多选、右键菜单要用的两样变了才重算。
/// 以前选中整份传进来，点一下换一张整个网格重算一遍：每格重建点按、拖拽、右键菜单（菜单当场就建）、悬停提示，
/// 大托盘还要把几百格重新排一遍 —— 每下 2700–3200 万条指令（--perf trayclick），现在 700–1000 万。
/// 点选：单击只选这一张、⌘ 点加减、⇧ 点从上一次点的那张连到这张；点空白处取消；⌘A 全选显示的；⌫ 移除选中的；Esc 取消。
private struct CollageTrayGrid: View, Equatable {
    /// 只用来调方法（不订阅；选中由外面的 CollageTray 订阅了传进来）。
    let store: CollageStore
    let tray: CollageTrayState
    /// 按筛选显示的照片（带进来的顺序）。
    let photos: [CollagePhotoRef]
    let usage: [String: Int]
    let dropped: Set<String>
    /// 多选（看得见的选了两张以上）时是选中的那几张，否则空：只有右键菜单要它（对整批的那几项）。
    /// 单击换一张不改它，网格就不重算；每格的选中框各自订阅 tray.mark。
    let multiSelection: Set<String>
    let fineArt: Bool
    /// 右键「放进选中的格子」：画布上选中的是一格时它的路径。
    let placeTarget: [Int]?
    /// 右键「加进当前版（重排）」：当前页的照片（没有页 = nil）。
    let pagePhotoIDs: [String]?
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 6)]

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.tray === b.tray && a.photos == b.photos && a.usage == b.usage
            && a.dropped == b.dropped && a.multiSelection == b.multiSelection && a.fineArt == b.fineArt
            && a.placeTarget == b.placeTarget && a.pagePhotoIDs == b.pagePhotoIDs
    }

    var body: some View {
        let _ = CollagePerf.body("托盘网格")
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(photos) { photo in
                    CollageTrayCell(mark: tray.mark(photo.id), photo: photo, uses: usage[photo.id] ?? 0,
                                    dropped: dropped.contains(photo.id), focused: focused, fineArt: fineArt)
                        .onTapGesture { click(photo.id) }
                        .onDrag { NSItemProvider(object: photo.id as NSString) }
                        .contextMenu { menu(for: photo) }
                }
            }
            .padding(8)
        }
        // 点在照片之间、下面的空白：取消选择（点在照片上由照片自己的手势先接）。
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            tray.clear()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { removeSelected() }
        .onExitCommand { tray.clear() }
        .onCommand(#selector(NSResponder.selectAll(_:))) { tray.selectAll(photos.map(\.id)) }
    }

    private func click(_ id: String) {
        focused = true
        let flags = NSEvent.modifierFlags
        tray.click(id, command: flags.contains(.command), shift: flags.contains(.shift), order: photos.map(\.id))
    }

    /// 右键里改画布的操作（放进格子、重排）：做完取消托盘的选中。键盘焦点还在托盘上，紧接着按 ⌫（多半是想清掉画布上
    /// 那一格）就什么也不移除，不会把刚放进去的照片移出托盘。
    private func toCanvas(_ action: () -> Void) {
        action()
        tray.clear()
    }

    /// 多选的那几张（按显示顺序）。
    private var selectedIDs: [String] { photos.map(\.id).filter(multiSelection.contains) }

    /// ⌫：现在选中的（单击换一张网格不重算，这里不能用存下来的值，现读 tray）。
    private func removeSelected() {
        let ids = photos.map(\.id).filter(tray.selection.contains)
        if !ids.isEmpty { store.removeFromTray(ids) }
    }

    @ViewBuilder
    private func menu(for photo: CollagePhotoRef) -> some View {
        // 右键点在多选里的一张：对整批；点在没选的那张上：只对它（和以前一样）。
        if multiSelection.contains(photo.id) {
            let ids = selectedIDs
            Button(ids.count > CollageTray.relayoutLimit ? "用这 \(ids.count) 张重新排一版（最多 \(CollageTray.relayoutLimit) 张）"
                                                          : "用这 \(ids.count) 张重新排一版") {
                toCanvas { store.relayout(photoIDs: ids) }
            }
            .disabled(ids.count > CollageTray.relayoutLimit)
            if let page = pagePhotoIDs {
                let extra = ids.filter { !page.contains($0) }
                if !extra.isEmpty {
                    Button("加进现在的版式（重排，\(extra.count) 张）") { toCanvas { store.relayout(photoIDs: page + extra) } }
                        .disabled(page.count + extra.count > CollageTray.relayoutLimit)
                }
            }
            Divider()
            Button("从托盘移除这 \(ids.count) 张", role: .destructive) { store.removeFromTray(ids) }
        } else {
            if let path = placeTarget {
                Button("放进选中的格子") { toCanvas { store.place(photoID: photo.id, at: path, edge: nil) } }
            }
            Button("只用这张重新排一版") { toCanvas { store.relayout(photoIDs: [photo.id]) } }
            if let ids = pagePhotoIDs, !ids.contains(photo.id) {
                Button("加进现在的版式（重排）") { toCanvas { store.relayout(photoIDs: ids + [photo.id]) } }
            }
            Divider()
            Button("从托盘移除", role: .destructive) { store.removeFromTray(photo.id) }
        }
    }
}

/// 托盘网格的一格：只订阅这一张的选中标记。active 只在选中时有用（选中框的颜色），没选中的格子传 false ——
/// 焦点在托盘和画布之间来回时，不让每一格都跟着重算。
private struct CollageTrayCell: View {
    @ObservedObject var mark: CollageTrayMark
    let photo: CollagePhotoRef
    let uses: Int
    let dropped: Bool
    let focused: Bool
    let fineArt: Bool

    var body: some View {
        CollageTrayItem(photo: photo, uses: uses, dropped: dropped, selected: mark.selected,
                        active: mark.selected && focused, fineArt: fineArt)
    }
}

struct CollageTrayItem: View {
    let photo: CollagePhotoRef
    /// 上了几次（所有页的格子和图层加起来）：1 次打勾，多次标次数。
    let uses: Int
    let dropped: Bool
    var selected = false
    /// 托盘有键盘焦点（⌫、Esc、⌘A 归它）：选中框画成强调色；没有焦点画成灰的（和访达一样）。
    var active = true
    /// 婚礼 fine-art 编排拿掉的不全是「相似」（同一场只留精选拿掉的更多）：角标写「拿掉」。
    var fineArt = false

    var body: some View {
        let _ = CollagePerf.body("托盘格")
        ZStack(alignment: .topTrailing) {
            ThumbnailView(path: photo.quickPath, maxPixel: 256)
                .aspectRatio(1, contentMode: .fill)
                .frame(minWidth: 60, minHeight: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(uses > 0 ? 0.45 : 1)
            if uses > 1 {
                Text("\(uses)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.accentColor, in: Capsule())
                    .padding(3)
            } else if uses == 1 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(3)
            } else if photo.isPick {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .padding(4)
                    .shadow(radius: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            // 客户选中：紫心（和批量页缩略图、确认表上客户点的那颗同一个符号同一个颜色）。
            if photo.clientPick {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .padding(4)
                    .shadow(radius: 1)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if dropped {
                Text(fineArt ? "拿掉" : "相似")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(active ? Color.accentColor : Color.gray, lineWidth: 3)
            }
        }
        .help(helpText)
    }

    /// 悬停提示（拆成一段段拼：一整串三元表达式加起来，CI 的编译器类型检查会超时）。
    private var helpText: String {
        var parts = [photo.id]
        if photo.isPick { parts.append("精选") }
        if photo.clientPick { parts.append("客户选中（编排不会拿掉）") }
        if uses > 1 { parts.append("用了 \(uses) 次") } else if uses == 1 { parts.append("已用") }
        if dropped { parts.append(fineArt ? "婚礼相册编排没上（同一场只留精选 / 相似）" : "相册去重拿掉的") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 备选版式条

struct CollageAlternativeStrip: View {
    @ObservedObject var store: CollageStore

    /// 婚礼 fine-art 的相册跨页按编排出版式：没有 ← → 和「换一批」（不摆永远灰着的按钮）。
    private var fineArtAlbum: Bool { store.isAlbum && store.project.albumTheme == .fineArt }

    var body: some View {
        let _ = CollagePerf.body("备选条")
        HStack(spacing: 8) {
            controls
            if store.alternativeThumbs.isEmpty {
                emptyHint
                Spacer()
            } else {
                CollageAlternativeThumbs(store: store, thumbs: store.alternativeThumbs, selected: store.alternativeIndex,
                                         clearCanvasLabel: clearCanvasLabel)
                    .equatable()
                Button {
                    store.clearAlternativeStrip()
                } label: {
                    Label("清空", systemImage: "xmark.circle")
                }
                .controlSize(.small)
                .help("清空这一排备选：画布上现在的版式留着。右键缩略图可以只去掉一个，或者连画布一起清")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 78)
    }

    /// 「备选」+ ← → +「换一批」：以前在顶栏，挪到管备选的这一条最左边。印样按拍摄先后排，没有备选版式
    /// （regenerate 只会提示一句）：→ 和「换一批」灰掉，旁边说去哪改。
    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("备选").font(.caption).foregroundStyle(.secondary)
            if !fineArtAlbum {
                HStack(spacing: 4) {
                    Button { store.previousAlternative() } label: { Image(systemName: "chevron.left") }
                        .disabled(store.alternatives.isEmpty)
                        .help("上一个备选 (←)")
                    Button { store.nextAlternative() } label: { Image(systemName: "chevron.right") }
                        .disabled(store.root == nil || store.isContactSheet)
                        .help("下一个备选 (→)")
                }
                .controlSize(.small)
                Button("换一批") { store.regenerate() }
                    .controlSize(.small)
                    .disabled(store.root == nil || store.isSolving || store.isContactSheet)
                    .help(store.isContactSheet ? "印样按拍摄先后排，没有备选：改规格、每条帧数在右栏「格式 › 印样」里"
                          : store.isAlbum ? "当前跨页重新求解；锁定的格子不动" : "同样的照片重新求解一批备选；锁定的格子不动")
            }
        }
        .frame(width: 72, alignment: .leading)
    }

    @ViewBuilder
    private var emptyHint: some View {
        if store.root == nil {
            Text(store.isAlbum ? "点「自动编排」把托盘编成跨页；每个跨页「换一批」出备选版式，← → 切换"
                 : "自动排版后这里是几十个备选版式，← → 切换")
                .font(.caption).foregroundStyle(.tertiary)
        } else if fineArtAlbum {
            // 婚礼 fine-art 编排的相册没有「换一批」：别叫人去点它。
            Text("婚礼相册的跨页按编排出版式，没有备选：想重排点「自动编排」")
                .font(.caption).foregroundStyle(.tertiary)
        } else if store.isContactSheet {
            CollageJumpText(store: store, lead: "印样按拍摄先后排，没有备选：改规格、每条帧数在右栏", spot: .contact, tail: "里")
        } else {
            Text("点左边的「换一批」或 → 出一批备选版式")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// 右键「连画布一起清」的说法：单张拼图只有一页 = 清空画布（照片还在托盘里）；几页的 / 相册 = 删掉这一页 / 跨页。
    /// 编辑封面时 = nil（不出这一项）：备选是封面的，删的却是封面底下那个看不见的跨页（审查发现）。
    private var clearCanvasLabel: String? {
        if store.isAlbum { return store.editingCover ? nil : "删除这个跨页" }
        return store.project.pages.count > 1 ? "删除这一页" : "清空画布（照片还在托盘里）"
    }
}

/// 备选缩略图那一排（几十张）：只有缩略图换了、选中的换了才重算。右键：用这一版 / 从备选里去掉 / 清空备选 /
/// 连画布一起清（以前右键没反应，备选只有退出 app 才清得掉）。
private struct CollageAlternativeThumbs: View, Equatable {
    /// 只用来调方法（不订阅）。
    let store: CollageStore
    let thumbs: [NSImage]
    let selected: Int
    let clearCanvasLabel: String?
    /// 每张缩略图是不是同一张（== 只比这个：NSImage 不是 Sendable，nonisolated 的 == 里不碰它）。
    private let thumbIDs: [ObjectIdentifier]

    init(store: CollageStore, thumbs: [NSImage], selected: Int, clearCanvasLabel: String?) {
        self.store = store
        self.thumbs = thumbs
        self.selected = selected
        self.clearCanvasLabel = clearCanvasLabel
        thumbIDs = thumbs.map(ObjectIdentifier.init)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.selected == b.selected && a.thumbIDs == b.thumbIDs
            && a.clearCanvasLabel == b.clearCanvasLabel
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { item in
                    Button {
                        store.applyAlternative(item.offset)
                    } label: {
                        Image(nsImage: item.element)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(
                                item.offset == selected ? Color.accentColor : Color.clear,
                                lineWidth: 2.5))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("用这个备选") { store.applyAlternative(item.offset) }
                        Button("从备选里去掉") { store.removeAlternative(item.offset) }
                        Divider()
                        Button("清空备选") { store.clearAlternativeStrip() }
                        if let clearCanvasLabel {
                            Button(clearCanvasLabel, role: .destructive) { store.deletePage(store.pageIndex) }
                        }
                    }
                    .help("第 \(item.offset + 1) 个备选（右键：从备选里去掉、清空备选）")
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - 相册跨页条

/// 方案栏：存下来的几版（CollageVariant）。点缩略图切过去（一步撤销），右键覆盖 / 改名 / 删除（这三样不进撤销：
/// 覆盖、删除先问一句），最后一格「+」存现在这一版。和现在一模一样的描蓝边；最近存的 / 切到的那个之后又改过，
/// 名字后面标「改过」（右键「用现在的样子覆盖它」）。一直显示：没存过时是一条「+ 存成方案（⇧⌘S）」。
struct CollageVariantStrip: View {
    @ObservedObject var store: CollageStore
    /// 方案缩略图在 store.thumbs 里。
    @ObservedObject var thumbs: CollageThumbs

    /// 右键菜单点了以后等确认的那一样（覆盖、删除先问；改名弹输入框）。
    private enum Pending: Equatable {
        case rename(String)
        case overwrite(String)
        case delete(String)
    }
    @State private var pending: Pending?
    @State private var draft = ""

    var body: some View {
        let _ = CollagePerf.body("方案条")
        if store.variants.isEmpty {
            emptyStrip
        } else {
            strip
        }
    }

    /// 还没存过方案：一个按钮 + 一句话（不占缩略图那么高，画布少让一点）。
    private var emptyStrip: some View {
        HStack(spacing: 8) {
            Text("方案").font(.caption).foregroundStyle(.secondary)
                .frame(width: 32)
            Button {
                store.saveVariant()
            } label: {
                Label("存成方案（⇧⌘S）", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(store.project.pages.isEmpty || store.isSolving)
            .help("把现在的拼图存成方案：画布、样式、文字、所有页、水印一起存，点缩略图随时切回来")
            Text("存好几个方案并排比着挑，点一下切过去（⌘Z 回到切之前）")
                .font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var strip: some View {
        let current = store.currentVariantIDs
        let modifiedID = store.activeVariantModified ? store.activeVariantID : nil
        return HStack(spacing: 8) {
            Text("方案").font(.caption).foregroundStyle(.secondary)
                .frame(width: 32)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.variants) { v in
                        card(v, current: current.contains(v.id), modified: v.id == modifiedID, anyCurrent: !current.isEmpty)
                    }
                    Button {
                        store.saveVariant()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 40, height: 52)
                            .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!current.isEmpty || store.project.pages.isEmpty || store.isSolving)
                    .help(!current.isEmpty ? "现在的拼图已经存过了" : "把现在的拼图存成方案（⇧⌘S）")
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 86)
        .alert("给方案改名", isPresented: flag(for: { if case .rename = $0 { return true } else { return false } })) {
            TextField("方案名", text: $draft)
            Button("好") {
                if case .rename(let id) = pending { store.renameVariant(id, to: draft) }
                pending = nil
            }
            Button("取消", role: .cancel) { pending = nil }
        }
        .alert(confirmTitle, isPresented: flag(for: { if case .rename = $0 { return false } else { return true } })) {
            Button(confirmButton, role: .destructive) {
                switch pending {
                case .overwrite(let id): store.updateVariant(id)
                case .delete(let id): store.deleteVariant(id)
                default: break
                }
                pending = nil
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: {
            Text("这一步不能撤销。")
        }
    }

    private func name(_ id: String) -> String {
        store.variants.first { $0.id == id }?.name ?? ""
    }

    private var confirmTitle: String {
        switch pending {
        case .overwrite(let id): return "用现在的拼图覆盖「\(name(id))」？"
        case .delete(let id): return "删除「\(name(id))」？"
        default: return ""
        }
    }

    private var confirmButton: String {
        if case .overwrite = pending { return "覆盖" }
        return "删除"
    }

    private func flag(for match: @escaping (Pending) -> Bool) -> Binding<Bool> {
        Binding(get: { pending.map(match) ?? false }, set: { if !$0 { pending = nil } })
    }

    private func card(_ v: CollageVariant, current: Bool, modified: Bool, anyCurrent: Bool) -> some View {
        Button {
            store.openVariant(v.id)
        } label: {
            VStack(spacing: 2) {
                Group {
                    if let image = thumbs.variants[v.id] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.2)).frame(width: 40)
                    }
                }
                .frame(height: 52)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(current ? Color.accentColor : Color.clear, lineWidth: 2.5))
                (Text(v.name) + Text(modified ? " · 改过" : "").foregroundColor(.orange))
                    .font(.caption2).foregroundStyle(current ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 96)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("切到这个方案") { store.openVariant(v.id) }.disabled(current)
            // 现在这一版已经存成某个方案了就不让覆盖（不然两个方案一模一样）
            Button("用现在的拼图覆盖它…") { pending = .overwrite(v.id) }
                .disabled(anyCurrent || store.project.pages.isEmpty || store.isSolving)
            Button("改名…") {
                draft = v.name
                pending = .rename(v.id)
            }
            Divider()
            Button("删除…", role: .destructive) { pending = .delete(v.id) }
        }
        .help("\(v.name) · \(v.project.pages.count) 页 · 点一下切到这个方案（⌘Z 回来）；右键覆盖、改名、删除")
    }
}

/// 跨页条（相册；单张拼图有好几页时是页条）。相册最前面一张「封面」卡（不算在跨页数里；没做封面时是「+ 封面」），
/// 左边「整本」开整本概览。卡片：点一下换到那一页（封面卡 = 编辑封面）；拖动排序（插入的位置画竖线）；托盘的照片拖到卡片上 =
/// 加进那一页、画布上的格子拖到卡片上 = 挪过去（画布自己的拖动手势，按 store.albumUI 记的位置认卡片）；锁住的画一把锁；
/// 右键挪、锁、镜像、删。
struct CollagePageStrip: View {
    @ObservedObject var store: CollageStore
    /// 跨页缩略图在 store.thumbs 里（渲好一批只刷新这一条，不是整个拼图页）。
    @ObservedObject var thumbs: CollageThumbs
    /// 画布拖格子经过哪张卡片、哪张卡片在排（store.albumUI）。
    @ObservedObject var ui: CollageAlbumUI
    /// 正在拖着排序的那一页、指针在条里的位置（内容坐标）。
    @State private var drag: StripDrag?

    private struct StripDrag: Equatable {
        var id: UUID
        var location: CGPoint
    }

    init(store: CollageStore, thumbs: CollageThumbs) {
        self.store = store
        self.thumbs = thumbs
        self.ui = store.albumUI
    }

    static let space = "pageStrip"
    static let thumbHeight: CGFloat = 52
    static let spacing: CGFloat = 8

    /// 相册叫「跨页」，单张拼图的多页叫「页」。
    private var unit: String { store.isAlbum ? "跨页" : "页" }

    /// 卡片宽：缩略图按画布比例（30×30 的跨页 2:1 = 104pt）；封面卡同宽（整张封面缩进去）。
    private var cardWidth: CGFloat {
        let c = store.project.canvas
        return min(150, max(40, (Self.thumbHeight * CGFloat(c.width) / CGFloat(max(1, c.height))).rounded()))
    }

    /// 前面几张不是跨页（相册的封面卡）。
    private var leadingSlots: Int { store.isAlbum ? 1 : 0 }

    private var metrics: CollageAlbumRules.GridMetrics {
        let slots = leadingSlots + store.project.pages.count
        return CollageAlbumRules.GridMetrics(columns: max(1, slots), cell: CGSize(width: cardWidth, height: Self.thumbHeight + 16),
                                             spacing: Self.spacing)
    }

    var body: some View {
        let _ = CollagePerf.body("页条")
        let m = metrics
        HStack(spacing: 8) {
            leftColumn
            ScrollView(.horizontal, showsIndicators: false) {
                cards(m)
                    .padding(.vertical, 6)
            }
            .background(viewportReader)
        }
        .padding(.horizontal, 10)
        .frame(height: 86)
        .onAppear { record(m) }
        .onChange(of: m) { _, now in record(now) }
        .onChange(of: store.project.pages.count) { _, _ in record(metrics) }
        // 排完了（托盘照片、画布格子落下来）：卡片上不再转圈。
        .onChange(of: store.isSolving) { _, solving in if !solving, ui.pendingPage != nil { ui.pendingPage = nil } }
    }

    /// 画布拖格子时按这几个数认卡片（不发布：只在拖的时候现查）。
    private func record(_ m: CollageAlbumRules.GridMetrics) {
        ui.stripMetrics = m
        ui.stripLeadingSlots = leadingSlots
        ui.stripPageCount = store.project.pages.count
    }

    /// 左边：「跨页」、几个（多了、页数不合规标橙）、「整本」。
    private var leftColumn: some View {
        VStack(spacing: 3) {
            Text(unit).font(.caption).foregroundStyle(.secondary)
            // 相册：几个跨页（指定了跨页数是「现在 / 目标」，多了标橙）。封面不算在里面。
            if store.isAlbum {
                CollageAlbumSpreadCount(store: store)
                overviewButton
            }
        }
        .frame(width: 44)
    }

    /// 「整本」：开着概览时实心（再点一下回编辑）。
    @ViewBuilder
    private var overviewButton: some View {
        let label = Text("整本").font(.caption2)
        if ui.overviewShown {
            Button { ui.toggleOverview(store) } label: { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("回到编辑这个跨页 (G、Esc)")
        } else {
            Button { ui.toggleOverview(store) } label: { label }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("整本概览：摊开全部跨页，拖动排序、多选锁住 / 镜像 / 删除 (G)")
        }
    }

    private func cards(_ m: CollageAlbumRules.GridMetrics) -> some View {
        HStack(spacing: Self.spacing) {
            if store.isAlbum { coverCard }
            ForEach(Array(store.project.pages.enumerated()), id: \.element.id) { item in
                pageCard(index: item.offset, page: item.element, metrics: m)
            }
            Button {
                store.addPage()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 40, height: 56)
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("在当前\(unit)后面加一个空\(unit)")
        }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) { insertionLine(m) }
        .background(contentReader)
    }

    /// 卡片们在窗口里的位置（画布拖格子出来时按它认卡片）。
    private var contentReader: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { ui.stripContent = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in ui.stripContent = f }
        }
    }

    /// 条看得见的那一截（滚出去的卡片不算）。
    private var viewportReader: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { ui.stripViewport = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in ui.stripViewport = f }
        }
    }

    // MARK: 封面卡（U8）

    private var coverCard: some View {
        let made = store.project.bookCover != nil
        let editing = store.editingCover
        return VStack(spacing: 2) {
            ZStack {
                if made {
                    CollageCoverThumb(store: store, longEdge: 300)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    Label("封面", systemImage: "plus").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: cardWidth, height: Self.thumbHeight)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(editing ? Color.accentColor : Color.clear, lineWidth: 2.5))
            Text("封面").font(.caption2).foregroundStyle(editing ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { openCover() }
        .contextMenu { coverMenu(made: made) }
        .help(made ? "封面（不算在跨页数里）：点一下编辑封面那一块；书脊、封底在「文档 › 封面」。点任何一个跨页回去"
              : "做封面：主图用扉页那张，标题、日期照扉页（⌘Z 撤回）；做好就编辑它")
    }

    private func openCover() {
        if store.project.bookCover == nil {
            guard store.makeCover() else { return }
        }
        ui.overviewShown = false
        CollageAlbumKeys.open(.cover, store: store)
    }

    @ViewBuilder
    private func coverMenu(made: Bool) -> some View {
        if made {
            Button("编辑封面") { openCover() }
            Button("按扉页重做") { store.makeCover(replace: true) }
            Divider()
            Button("去掉封面", role: .destructive) { store.removeCover() }
        } else {
            Button("做封面") { openCover() }
        }
    }

    // MARK: 跨页卡片

    private func pageCard(index: Int, page: CollagePage, metrics m: CollageAlbumRules.GridMetrics) -> some View {
        let selected = index == store.pageIndex && !store.editingCover
        // 超出目标跨页数的那几个跨页：页码标橙（印厂 / 套餐放不下的就是它们）。
        let over: Bool = store.isAlbum && (store.project.albumBudget.map { index >= $0.spreads } ?? false)
        let card = CollageStripCard(thumb: thumbs.pages[page.id], width: cardWidth, number: index + 1, locked: page.locked,
                                    selected: selected, over: over, hover: ui.stripHover == index,
                                    pending: ui.pendingPage == page.id && store.isSolving,
                                    onDropPhoto: { id in CollageAlbumDrops.photo(id, onPage: page.id, store: store) })
        return card
            .opacity(drag?.id == page.id ? 0.35 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                // 点一个跨页 = 去编辑它（开着整本概览也回到画布；退出封面编辑，见 CollageAlbumKeys.open）。
                if ui.overviewShown { ui.overviewShown = false }
                CollageAlbumKeys.open(.page(index), store: store)
            }
            .gesture(reorder(page.id, metrics: m))
            .contextMenu { pageMenu(index: index, page: page) }
            .help(cardHelp(index, page))
    }

    private func cardHelp(_ index: Int, _ page: CollagePage) -> String {
        let lock = page.locked ? " · 锁住" : ""
        return "\(unit) \(index + 1) · \(page.photoIDs.count) 张\(lock)（拖动排序；托盘照片、画布上的格子拖上来 = 放进这一\(unit)；"
            + "右键锁住、镜像、挪、删）"
    }

    @ViewBuilder
    private func pageMenu(index: Int, page: CollagePage) -> some View {
        Button("往前挪") { store.movePage(index, by: -1) }.disabled(index == 0)
        Button("往后挪") { store.movePage(index, by: 1) }.disabled(index == store.project.pages.count - 1)
        if store.isAlbum {
            Divider()
            Button(page.locked ? "解锁这个跨页" : "锁住这个跨页") {
                store.setPagesLocked(IndexSet(integer: index), !page.locked)
            }
            Button("镜像这个跨页") { store.mirrorPage(index) }
                .disabled(page.contactSheet != nil)
        }
        Divider()
        Button("删除这个\(unit)", role: .destructive) { store.deletePage(index) }
    }

    // MARK: 拖动排序（U2）

    private func reorder(_ id: UUID, metrics m: CollageAlbumRules.GridMetrics) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    drag = StripDrag(id: id, location: value.location)
                } else {
                    drag?.location = value.location
                }
            }
            .onEnded { value in
                defer { drag = nil }
                guard let dest = destination(id, at: value.location, metrics: m),
                      let from = store.project.pages.firstIndex(where: { $0.id == id }) else { return }
                store.movePages(IndexSet(integer: from), to: dest)
            }
    }

    /// 拖到这里松手插在第几个前面（movePages 的 destination）；顺序不变 = nil。
    private func destination(_ id: UUID, at p: CGPoint, metrics m: CollageAlbumRules.GridMetrics) -> Int? {
        let count = store.project.pages.count
        guard let from = store.project.pages.firstIndex(where: { $0.id == id }) else { return nil }
        let slot = CollageAlbumRules.insertion(at: p, slots: leadingSlots + count, metrics: m).slot
        let dest = CollageAlbumRules.pageDestination(slot: slot, leadingSlots: leadingSlots, pageCount: count)
        return CollageAlbumRules.moveChangesOrder(IndexSet(integer: from), to: dest, count: count) ? dest : nil
    }

    @ViewBuilder
    private func insertionLine(_ m: CollageAlbumRules.GridMetrics) -> some View {
        if let drag, let dest = destination(drag.id, at: drag.location, metrics: m) {
            let x = CGFloat(dest + leadingSlots) * m.pitchX - m.spacing / 2 - 1.5
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: Self.thumbHeight + 4)
                .offset(x: x, y: -2)
                .allowsHitTesting(false)
        }
    }
}

/// 跨页条上的一张卡片：缩略图、锁、页码（多了标橙）；当前页描边，托盘照片、画布格子拖上来描边，在排的时候转圈。
private struct CollageStripCard: View {
    let thumb: NSImage?
    let width: CGFloat
    let number: Int
    let locked: Bool
    let selected: Bool
    let over: Bool
    /// 画布上的格子拖着指到这张卡片。
    let hover: Bool
    let pending: Bool
    let onDropPhoto: (String) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.2))
                }
                if pending { ProgressView().controlSize(.small) }
            }
            .frame(width: width, height: CollagePageStrip.thumbHeight)
            .overlay(alignment: .topLeading) {
                if locked { CollageLockBadge() }
            }
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(hover || targeted || selected ? Color.accentColor : Color.clear,
                              lineWidth: hover || targeted ? 3.5 : 2.5))
            Text("\(number)").font(.caption2).foregroundStyle(tint)
        }
        .onDrop(of: [.text], isTargeted: $targeted) { providers in
            CollageAlbumDrops.loadText(providers, onDropPhoto)
        }
    }

    private var tint: AnyShapeStyle {
        if over { return AnyShapeStyle(Color.orange) }
        return selected ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
}

// MARK: - 顶栏「导出 ▾」

/// 紧凑的顶栏：Picker 不写标签（「编排」两个字）。
private struct CollageHideLabels: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.labelsHidden()
        } else {
            content
        }
    }
}

/// 「导出」一键按导出设置写出（⌘E，和以前一样）；旁边的 ▾ 弹出导出设置（文件、印刷、输出目录：以前是检视器的「导出」页，
/// 照 Canva 的「分享 › 下载」）。▾ 不跟着导出按钮灰：没有输出目录导不了的时候，正要从这里选一个。
struct CollageExportButtons: View {
    @ObservedObject var store: CollageStore
    @ObservedObject var nav: CollageNav
    /// 顶栏放不下整排时：相册也只写「导出」。
    let compact: Bool

    init(store: CollageStore, compact: Bool = false) {
        self.store = store
        self.nav = store.nav
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 1) {
            Button {
                store.export()
            } label: {
                Label(store.isAlbum && !compact ? "导出相册" : "导出", systemImage: "square.and.arrow.up")
            }
            // ⌘E 挂在顶栏那组看不见的快捷键上（CollageView.topBarShortcuts）：顶栏两排里各有一个这个按钮。
            .disabled(store.exportBlockedReason != nil)
            .help(store.exportBlockedReason ?? "按导出设置写到输出目录 (⌘E)；旁边的 ▾ 改文件名、文件格式、清晰度、输出目录")
            Button {
                nav.exportShown.toggle()
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("导出设置：文件名、文件格式、清晰度、带不带水印、印刷（出血、PDF）、输出目录")
            // 离屏快照里不弹真的弹出框（截不到，还要一个窗口）：CollageView 把内容画在顶栏下面。
            .popover(isPresented: SnapshotPreview.inlineExport ? .constant(false) : $nav.exportShown,
                     arrowEdge: .bottom) {
                CollageExportPopover(store: store)
            }
        }
        .buttonStyle(.borderedProminent)
    }
}

/// 离屏快照里「导出 ▾」摊开的样子（SnapshotPreview.inlineExport）：画在顶栏下面、右边对齐。只订阅 nav。
private struct CollageInlineExport: View {
    let store: CollageStore
    @ObservedObject var nav: CollageNav

    init(store: CollageStore) {
        self.store = store
        self.nav = store.nav
    }

    var body: some View {
        if nav.exportShown {
            CollageExportPopover(store: store)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.4)))
                .shadow(radius: 12)
                .padding(.top, 46)
                .padding(.trailing, 10)
        }
    }
}

/// 弹出框里的导出设置：就是以前「导出」页那一块（CollageExportPanel），按内容高度排。
struct CollageExportPopover: View {
    let store: CollageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出设置").font(.headline)
            CollageExportPanel(store: store)
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        // 滑杆松手 = 一次拖动结束（质量、出血、安全区）。
        .environment(\.collageUndo, store)
    }
}
