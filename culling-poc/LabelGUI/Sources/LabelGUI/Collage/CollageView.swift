import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 拼图 tab：左托盘 · 中画布 · 右检视器，底部备选版式（相册模式多一条跨页条）。
struct CollageView: View {
    @ObservedObject var store: CollageStore
    @ObservedObject var batchStore: BatchStore
    @State private var inspectorTab: CollageInspector.Tab
    @State private var autoCount = 6
    @State private var dedupeAlbum = true

    init(store: CollageStore, batchStore: BatchStore, initialTab: CollageInspector.Tab = .layout) {
        self.store = store
        self.batchStore = batchStore
        _inspectorTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                CollageTray(store: store, batchStore: batchStore)
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 320)
                CollageCanvasView(store: store) { inspectorTab = .text }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                CollageInspector(store: store, tab: $inspectorTab)
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
            }
            Divider()
            bottomStrips
            Divider()
            statusBar
        }
        .onAppear { attachSession() }
        .onChange(of: batchStore.photoDir) { _, _ in attachSession() }
    }

    private func attachSession() {
        let dir = batchStore.photoDir
        store.attach(sessionDir: dir == nil ? nil : batchStore.sessionDir, photoDir: dir)
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
            Button { store.nextAlternative() } label: { Image(systemName: "chevron.right") }
                .disabled(store.root == nil)
                .help("下一版 (→)")
            Button("换一批") { store.regenerate() }
                .disabled(store.root == nil || store.isSolving)
                .help("同样的照片重新求解一批备选；锁定的格子不动")
            if store.isSolving { ProgressView().controlSize(.small) }
        }
    }

    private var albumControls: some View {
        HStack(spacing: 8) {
            Button("自动编排") { store.autoArrangeAlbum(dedupe: dedupeAlbum) }
                .disabled(store.project.photos.isEmpty)
                .help("托盘里的照片按时间和章节编成跨页：分数最高的做扉页，好片单独成页")
            Toggle("相似只留一张", isOn: $dedupeAlbum)
                .toggleStyle(.checkbox)
                .help("连拍、同地同姿势的只留分数高的（拿掉的仍在托盘里，可以拖回任何跨页）")
            Button("换一批") { store.regenerate() }
                .disabled(store.root == nil || store.isSolving)
                .help("当前跨页重新求解；锁定的格子不动")
            if store.isSolving { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - 底部：跨页条 + 备选版式

    private var bottomStrips: some View {
        VStack(spacing: 0) {
            if store.isAlbum {
                CollagePageStrip(store: store)
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
                Text(notice).font(.caption).foregroundStyle(.secondary)
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

struct CollageTray: View {
    @ObservedObject var store: CollageStore
    @ObservedObject var batchStore: BatchStore
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.project.photos.isEmpty {
                emptyTray
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(store.project.photos) { photo in
                            CollageTrayItem(photo: photo, used: store.usedPhotoIDs.contains(photo.id),
                                            dropped: store.albumDropped.contains { $0.id == photo.id })
                                .onDrag { NSItemProvider(object: photo.id as NSString) }
                                .contextMenu { menu(for: photo) }
                        }
                    }
                    .padding(8)
                }
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
    }

    private var header: some View {
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
                Button("清空托盘和版式", role: .destructive) { store.clearTray() }
                    .disabled(store.project.photos.isEmpty)
            } label: {
                Label("带照片", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("从批量页带精选进来，或添加外部照片（也可以直接把文件拖到这里）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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

    @ViewBuilder
    private func menu(for photo: CollagePhotoRef) -> some View {
        if let path = store.selection, store.root?.node(at: path)?.isLeaf == true {
            Button("放进选中的格子") { store.place(photoID: photo.id, at: path, edge: nil) }
        }
        Button("只用这张重新排一版") { store.relayout(photoIDs: [photo.id]) }
        if let page = store.page, !page.photoIDs.contains(photo.id) {
            Button("加进当前版（重排）") { store.relayout(photoIDs: page.photoIDs + [photo.id]) }
        }
        Divider()
        Button("从托盘移除", role: .destructive) { store.removeFromTray(photo.id) }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { store.addFiles(panel.urls) }
    }
}

struct CollageTrayItem: View {
    let photo: CollagePhotoRef
    let used: Bool
    let dropped: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ThumbnailView(path: photo.quickPath, maxPixel: 256)
                .aspectRatio(1, contentMode: .fill)
                .frame(minWidth: 60, minHeight: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(used ? 0.45 : 1)
            if used {
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
                Text("相似")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
        .help(photo.id + (photo.isPick ? " · 精选" : "") + (used ? " · 已用" : "") + (dropped ? " · 相册去重拿掉的" : ""))
    }
}

// MARK: - 备选版式条

struct CollageAlternativeStrip: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        HStack(spacing: 8) {
            Text("备选").font(.caption).foregroundStyle(.secondary)
                .frame(width: 32)
            if store.alternativeThumbs.isEmpty {
                Text(store.root == nil ? "自动排版后这里是几十个备选版式，← → 切换" : "点「换一批」或 → 出一批备选版式")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(store.alternativeThumbs.enumerated()), id: \.offset) { item in
                            Button {
                                store.applyAlternative(item.offset)
                            } label: {
                                Image(nsImage: item.element)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 64)
                                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(
                                        item.offset == store.alternativeIndex ? Color.accentColor : Color.clear,
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
        .padding(.horizontal, 10)
        .frame(height: 78)
    }
}

// MARK: - 相册跨页条

struct CollagePageStrip: View {
    @ObservedObject var store: CollageStore

    var body: some View {
        HStack(spacing: 8) {
            Text("跨页").font(.caption).foregroundStyle(.secondary)
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
                    .help("在当前跨页后面加一个空跨页")
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
                    if let thumb = store.pageThumbs[page.id] {
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
            Button("删除这个跨页", role: .destructive) { store.deletePage(index) }
        }
        .help("跨页 \(index + 1) · \(page.photoIDs.count) 张（右键挪动/删除）")
    }
}
