import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 拼图 tab：左托盘 · 中画布 · 右检视器，底部备选版式（相册模式多一条跨页条）。
struct CollageView: View {
    @ObservedObject var store: CollageStore
    /// 不整份订阅批量页（分析进度、判决计数一变，整个拼图页都跟着重算）：换场次由 CollageSessionWatch 盯，
    /// 托盘「带照片」菜单的计数由 CollageTrayHeader 自己订阅。
    let batchStore: BatchStore
    /// 检视器「水印」页读水印页的签名、设置和预设；只在那一页里观察它（水印页预览一动，拼图页不跟着重算）。
    let watermarkStore: WatermarkStore
    @State private var inspectorTab: CollageInspector.Tab
    @State private var autoCount = 6
    @State private var dedupeAlbum = true

    init(store: CollageStore, batchStore: BatchStore, watermarkStore: WatermarkStore,
         initialTab: CollageInspector.Tab = .layout) {
        self.store = store
        self.batchStore = batchStore
        self.watermarkStore = watermarkStore
        _inspectorTab = State(initialValue: initialTab)
    }

    var body: some View {
        let _ = CollagePerf.body("拼图页")
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                CollageTray(store: store, batchStore: batchStore)
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 320)
                CollageCanvasView(store: store) { inspectorTab = .text }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                CollageInspector(store: store, watermarkStore: watermarkStore, tab: $inspectorTab)
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
            }
            Divider()
            bottomStrips
            Divider()
            statusBar
        }
        .onAppear {
            attachSession()
            // 主体蒙版的模型第一次加载要 0.1–1 秒：一进拼图 tab 先在后台空跑一次。
            CollageMasks.warmUp()
        }
        .background(CollageSessionWatch(batchStore: batchStore) { attachSession() })
    }

    private func attachSession() {
        let dir = batchStore.photoDir
        store.attach(sessionDir: dir == nil ? nil : batchStore.sessionDir, photoDir: dir, batch: batchStore)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { store.project.mode }, set: { store.setMode($0) })) {
                Text("单张拼图").tag(CollageMode.single)
                Text("相册").tag(CollageMode.album)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("单张：一张拼图（朋友圈/小红书/九宫格/轮播）；相册：多个跨页，印刷用")

            if store.isAlbum {
                albumControls
            } else {
                singleControls
            }

            Divider().frame(height: 18)
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
                .help("撤销 (⌘Z)")
            Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
                .help("重做 (⇧⌘Z)")
            Toggle(isOn: Binding(get: { store.showGuides }, set: { store.showGuides = $0; store.setNeedsRender() })) {
                Image(systemName: "rectangle.dashed")
            }
            .toggleStyle(.button)
            .help("参考线：安全区、中缝、九宫格/轮播切线（不会导出）")

            Spacer()
            if store.isExporting {
                Button("取消") { store.cancelExport() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Button {
                store.export()
            } label: {
                Label(store.isAlbum ? "导出相册" : "导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: .command)
            .disabled(store.exportBlockedReason != nil)
            .help(store.exportBlockedReason ?? "按导出设置写到输出目录 (⌘E)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
            Button { store.previousAlternative() } label: { Image(systemName: "chevron.left") }
                .disabled(store.alternatives.isEmpty)
                .help("上一版 (←)")
            // 印样按拍摄先后排，没有备选版式（regenerate 只会提示一句）：→ 和「换一批」灰掉，备选条说去哪改。
            Button { store.nextAlternative() } label: { Image(systemName: "chevron.right") }
                .disabled(store.root == nil || store.isContactSheet)
                .help("下一版 (→)")
            Button("换一批") { store.regenerate() }
                .disabled(store.root == nil || store.isSolving || store.isContactSheet)
                .help(store.isContactSheet ? "印样按拍摄先后排，没有别的版：改规格、每条帧数在「版式 › 印样」里"
                      : "同样的照片重新求解一批备选；锁定的格子不动")
            if store.isSolving { ProgressView().controlSize(.small) }
        }
    }

    private var albumControls: some View {
        // 编排主题：默认 / 婚礼 fine-art（一键成套「整本婚礼相册」设成 fine-art；之后的「自动编排」按它编）。
        let fineArt = store.project.albumTheme == .fineArt
        return HStack(spacing: 8) {
            Picker("编排", selection: Binding(get: { store.project.albumTheme }, set: { store.setAlbumTheme($0) })) {
                ForEach(CollageAlbumTheme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .help("「自动编排」按哪套规则编：默认 = 分数最高的做扉页、横图铺满跨页；婚礼 fine-art = 扉页取宽景、"
                  + "每章疏 → 密 → 精选收尾、竖图成对、每跨页最多 3 张、不跨中缝（换了点「自动编排」生效）。"
                  + "纸、卡纸、≥ 25mm 的边距是样式：在「样式」里选「婚礼 fine-art」，一键成套「整本婚礼相册」两样一起设")
            Button("自动编排") { store.autoArrangeAlbum(dedupe: dedupeAlbum) }
                .disabled(store.project.photos.isEmpty)
                .help(fineArt ? "托盘里的照片按婚礼 fine-art 编成跨页：废片不要、同一场只留精选，扉页取宽景，每章疏 → 密 → 精选收尾"
                      : "托盘里的照片按时间和章节编成跨页：分数最高的做扉页，好片单独成页")
            Toggle("相似只留一张", isOn: $dedupeAlbum)
                .toggleStyle(.checkbox)
                .help(fineArt ? "只管画面相似的（关掉也不会全上：fine-art 一直是同一场只留精选、连拍只留一张）；拿掉的仍在托盘里，可以拖回任何跨页"
                      : "连拍、同地同姿势的只留分数高的（拿掉的仍在托盘里，可以拖回任何跨页）")
            if fineArt {
                Toggle("整章黑白", isOn: Binding(get: { store.project.albumChapterMono },
                                              set: { store.setAlbumTheme(.fineArt, chapterMono: $0) }))
                    .toggleStyle(.checkbox)
                    .help("一章里黑白照片占三分之一以上，整章的跨页都转黑白（R7：黑白按整章用，不零星撒）；下次「自动编排」生效")
            }
            // 婚礼 fine-art 的跨页按编排出版式（完整显示、卡纸留白），没有「换一批」（编排换回「默认」才有）：
            // 不摆一个永远灰着的按钮 —— 窗口最窄（960）时它占的地方正好让「整章黑白」放得下。
            if !fineArt {
                Button("换一批") { store.regenerate() }
                    .disabled(store.root == nil || store.isSolving)
                    .help("当前跨页重新求解；锁定的格子不动")
            }
            if store.isSolving { ProgressView().controlSize(.small) }
        }
        // 整组按自己要的宽度排（不折行、不截字）：顶栏的 HStack 按份给宽度，不先让右边的空当（Spacer）让出来 ——
        // 以前 960 宽、fine-art 时「相似只留一张」挤成两行；只给勾选框 fixedSize 又轮到「自动编排」截成「自动…」。
        .fixedSize()
    }

    // MARK: - 底部：跨页条 + 备选版式

    private var bottomStrips: some View {
        VStack(spacing: 0) {
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
                HStack(spacing: 4) {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                    Button {
                        store.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
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
    @State private var dropTargeted = false

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
        VStack(spacing: 0) {
            CollageTrayHeader(store: store, batchStore: batchStore)
            if !store.project.photos.isEmpty {
                filterBar(usage: usage)
                if !tray.selection.isEmpty { selectionBar }
            }
            Divider()
            if store.project.photos.isEmpty {
                emptyTray
            } else if visible.isEmpty {
                emptyFilter
            } else {
                // 网格只拿自己要的值：拖缝、拖滑杆、预览重渲这些不改托盘的，整个网格（每格的悬停提示、右键菜单、
                // 拖拽源）都跳过不重算。
                let placeTarget = store.selection.flatMap { store.root?.node(at: $0)?.isLeaf == true ? $0 : nil }
                CollageTrayGrid(store: store, tray: tray, photos: visible, usage: usage,
                                dropped: store.albumDroppedIDs, selection: tray.selection,
                                fineArt: store.isAlbum && store.project.albumTheme == .fineArt,
                                placeTarget: placeTarget, pagePhotoIDs: store.page?.photoIDs)
                    .equatable()
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(3)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let url = await CollageCanvasDropDelegate.loadURL(p) { urls.append(url) }
                }
                store.addFiles(urls)
            }
            return true
        }
        // 换了筛选：看不见的不留在选中里（不然 ⌫ 会删掉看不见的照片）。
        .onChange(of: tray.filter) { _, _ in
            tray.prune(to: Set(tray.visible(store.project.photos, usage: store.photoUsage).map(\.id)))
        }
    }

    /// 全部 / 未用 / 已用：先筛出没用上的再 ⌘A ⌫，就是批量清掉没用的。
    private func filterBar(usage: [String: Int]) -> some View {
        let used = store.project.photos.filter { usage[$0.id] != nil }.count
        let unused = store.project.photos.count - used
        return Picker("", selection: $tray.filter) {
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

    private var selectionBar: some View {
        let n = tray.selection.count
        return HStack(spacing: 6) {
            Text("已选 \(n) 张").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("移除", role: .destructive) { removeSelected() }
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
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func removeSelected() {
        store.removeFromTray(store.project.photos.map(\.id).filter(tray.selection.contains))
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
            .help("从批量页带精选进来，或添加外部照片（也可以直接把文件拖到这里）；也在这里移除没用上的")
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

/// 托盘的照片网格。Equatable：只有显示的照片、上了几次、相似角标、选中、右键菜单要用的两样变了才重算。
/// 点选：单击只选这一张、⌘ 点加减、⇧ 点从上一次点的那张连到这张；点空白处取消；⌘A 全选显示的；⌫ 移除选中的；Esc 取消。
private struct CollageTrayGrid: View, Equatable {
    /// 只用来调方法（不订阅；选中由外面的 CollageTray 订阅了传进来）。
    let store: CollageStore
    let tray: CollageTrayState
    /// 按筛选显示的照片（带进来的顺序）。
    let photos: [CollagePhotoRef]
    let usage: [String: Int]
    let dropped: Set<String>
    let selection: Set<String>
    let fineArt: Bool
    /// 右键「放进选中的格子」：画布上选中的是一格时它的路径。
    let placeTarget: [Int]?
    /// 右键「加进当前版（重排）」：当前页的照片（没有页 = nil）。
    let pagePhotoIDs: [String]?
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 6)]

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.tray === b.tray && a.photos == b.photos && a.usage == b.usage
            && a.dropped == b.dropped && a.selection == b.selection && a.fineArt == b.fineArt
            && a.placeTarget == b.placeTarget && a.pagePhotoIDs == b.pagePhotoIDs
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(photos) { photo in
                    CollageTrayItem(photo: photo, uses: usage[photo.id] ?? 0, dropped: dropped.contains(photo.id),
                                    selected: selection.contains(photo.id), fineArt: fineArt)
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

    /// 选中的（按显示顺序）。
    private var selectedIDs: [String] { photos.map(\.id).filter(selection.contains) }

    private func removeSelected() {
        let ids = selectedIDs
        if !ids.isEmpty { store.removeFromTray(ids) }
    }

    @ViewBuilder
    private func menu(for photo: CollagePhotoRef) -> some View {
        // 右键点在多选里的一张：对整批；点在没选的那张上：只对它（和以前一样）。
        if selection.count > 1, selection.contains(photo.id) {
            let ids = selectedIDs
            Button(ids.count > CollageTray.relayoutLimit ? "用这 \(ids.count) 张重新排一版（最多 \(CollageTray.relayoutLimit) 张）"
                                                          : "用这 \(ids.count) 张重新排一版") {
                store.relayout(photoIDs: ids)
            }
            .disabled(ids.count > CollageTray.relayoutLimit)
            if let page = pagePhotoIDs {
                let extra = ids.filter { !page.contains($0) }
                if !extra.isEmpty {
                    Button("加进当前版（重排，\(extra.count) 张）") { store.relayout(photoIDs: page + extra) }
                        .disabled(page.count + extra.count > CollageTray.relayoutLimit)
                }
            }
            Divider()
            Button("从托盘移除这 \(ids.count) 张", role: .destructive) { store.removeFromTray(ids) }
        } else {
            if let path = placeTarget {
                Button("放进选中的格子") { store.place(photoID: photo.id, at: path, edge: nil) }
            }
            Button("只用这张重新排一版") { store.relayout(photoIDs: [photo.id]) }
            if let ids = pagePhotoIDs, !ids.contains(photo.id) {
                Button("加进当前版（重排）") { store.relayout(photoIDs: ids + [photo.id]) }
            }
            Divider()
            Button("从托盘移除", role: .destructive) { store.removeFromTray(photo.id) }
        }
    }
}

struct CollageTrayItem: View {
    let photo: CollagePhotoRef
    /// 上了几次（所有页的格子和图层加起来）：1 次打勾，多次标次数。
    let uses: Int
    let dropped: Bool
    var selected = false
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
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .help(photo.id + (photo.isPick ? " · 精选" : "") + (uses > 1 ? " · 用了 \(uses) 次" : uses == 1 ? " · 已用" : "")
              + (dropped ? (fineArt ? " · fine-art 编排没上（同一场只留精选 / 相似）" : " · 相册去重拿掉的") : ""))
    }
}

// MARK: - 备选版式条

struct CollageAlternativeStrip: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        let _ = CollagePerf.body("备选条")
        HStack(spacing: 8) {
            Text("备选").font(.caption).foregroundStyle(.secondary)
                .frame(width: 32)
            if store.alternativeThumbs.isEmpty {
                // 婚礼 fine-art 编排的相册没有「换一批」（按钮灰着）：别叫人去点它。
                Text(store.root == nil ? "自动排版后这里是几十个备选版式，← → 切换"
                     : store.isAlbum && store.project.albumTheme == .fineArt
                     ? "婚礼 fine-art 的跨页按编排出版式，没有备选：想重排点「自动编排」"
                     : store.isContactSheet
                     ? "印样按拍摄先后排，没有备选：改规格、每条帧数在「版式 › 印样」里"
                     : "点「换一批」或 → 出一批备选版式")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                CollageAlternativeThumbs(store: store, thumbs: store.alternativeThumbs, selected: store.alternativeIndex)
                    .equatable()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 78)
    }
}

/// 备选缩略图那一排（几十张）：只有缩略图换了、选中的换了才重算。
private struct CollageAlternativeThumbs: View, Equatable {
    /// 只用来调方法（不订阅）。
    let store: CollageStore
    let thumbs: [NSImage]
    let selected: Int
    /// 每张缩略图是不是同一张（== 只比这个：NSImage 不是 Sendable，nonisolated 的 == 里不碰它）。
    private let thumbIDs: [ObjectIdentifier]

    init(store: CollageStore, thumbs: [NSImage], selected: Int) {
        self.store = store
        self.thumbs = thumbs
        self.selected = selected
        thumbIDs = thumbs.map(ObjectIdentifier.init)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.selected == b.selected && a.thumbIDs == b.thumbIDs
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
                    .help("第 \(item.offset + 1) 版")
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - 相册跨页条

struct CollagePageStrip: View {
    @ObservedObject var store: CollageStore
    /// 跨页缩略图在 store.thumbs 里（渲好一批只刷新这一条，不是整个拼图页）。
    @ObservedObject var thumbs: CollageThumbs

    /// 相册叫「跨页」，单张拼图的多页叫「页」。
    private var unit: String { store.isAlbum ? "跨页" : "页" }

    var body: some View {
        let _ = CollagePerf.body("页条")
        HStack(spacing: 8) {
            Text(unit).font(.caption).foregroundStyle(.secondary)
                .frame(width: 32)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(store.project.pages.enumerated()), id: \.element.id) { item in
                        pageCard(index: item.offset, page: item.element)
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
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 86)
    }

    private func pageCard(index: Int, page: CollagePage) -> some View {
        let selected = index == store.pageIndex
        return Button {
            store.pageIndex = index
        } label: {
            VStack(spacing: 2) {
                Group {
                    if let thumb = thumbs.pages[page.id] {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.2))
                    }
                }
                .frame(height: 52)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5))
                Text("\(index + 1)").font(.caption2).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("往前挪") { store.movePage(index, by: -1) }.disabled(index == 0)
            Button("往后挪") { store.movePage(index, by: 1) }.disabled(index == store.project.pages.count - 1)
            Divider()
            Button("删除这个\(unit)", role: .destructive) { store.deletePage(index) }
        }
        .help("\(unit) \(index + 1) · \(page.photoIDs.count) 张（右键挪动/删除）")
    }
}
