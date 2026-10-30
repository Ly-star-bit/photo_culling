import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

struct BatchView: View {
    @ObservedObject var store: BatchStore
    @State private var inspectedID: String?
    /// ⌘-click multi-selection for batch verdict changes.
    @State private var selectedIDs: Set<String> = []
    /// Keyboard focus in the grid: ←/→ move it, space opens the inspector,
    /// 1/2/3/0 apply verdicts without opening anything.
    @State private var focusedID: String?
    // View preferences persist across launches (they reset to defaults every
    // start before, so the thumbnail size and export settings were re-done
    // every session).
    @AppStorage("batch.thumbSize") private var thumbSize: Double = 140
    @State private var showTrashConfirm = false
    @State private var showClearRecentsConfirm = false
    /// JPG 交付导出设置。质量（60–100）是旧版存的：新的导出设置还没存过时拿它起默认。
    @AppStorage("batch.jpegQuality") private var jpegQuality: Double = 90
    @AppStorage("batch.jpegIncludeUsable") private var jpegIncludeUsable = true
    @AppStorage("batch.jpegOverwrite") private var jpegOverwrite = false
    @State private var showJPEGSheet = false
    /// 高ISO RAW 导出 (降噪流程)。
    @State private var showISOSheet = false
    /// 精华 Top N（Aftershoot 的 Sneak Peek）：当天发朋友圈用的那二十张。
    @State private var showHighlightsSheet = false
    /// 「导入客户选择…」对话框。
    @State private var showClientImport = false
    @AppStorage("batch.highlightsCount") private var highlightsCount = 20
    /// 旧版存的精华长边 / JPG 导出长边 (0 = 原尺寸)：新的导出设置还没存过时拿它们起默认，老用户的选择不丢。
    @AppStorage("batch.highlightsMaxPixel") private var highlightsMaxPixel = 2048
    @AppStorage("batch.isoThreshold") private var isoThreshold = 3200
    @AppStorage("batch.isoKeepersOnly") private var isoKeepersOnly = true
    @AppStorage("batch.jpegMaxPixel") private var jpegMaxPixel = 0
    /// 导出 JPG / 精华 Top N 各自的交付设置（DeliveryOptions 的 JSON；空 = 还没改过，用默认）。
    @AppStorage("batch.jpegDelivery") private var jpegDeliveryRaw = ""
    @AppStorage("batch.highlightsDelivery") private var highlightsDeliveryRaw = ""
    /// 连拍挑选（全窗口，占审片模式的位置）。nil = 在网格。
    @State private var pickRequest: PickRequest?
    /// 网格实际宽度 — ↑/↓ 换行导航需要估算列数。
    @State private var gridWidth: CGFloat = 800
    /// 网格里现在看得见哪些章节（时间轴画「你在这」）。故意用 @State 存引用而不是
    /// @StateObject：批量页不订阅它，滚动时只有时间轴重画。
    @State private var viewport: GridViewport

    /// viewport 只给离屏测试用（--batch-ui --scroll-test 从外面读它，验证滚出去的格子会不会注销）。
    init(store: BatchStore, viewport: GridViewport? = nil) {
        self.store = store
        _viewport = State(initialValue: viewport ?? GridViewport())
    }

    enum GridMode: String, CaseIterable {
        case byVerdict = "按判决"
        case byGroup = "按分组"
    }
    /// 按分组 = 每个多张场一行（Aftershoot 的重复组视图）；一组一组细挑按 C 进连拍挑选。
    @AppStorage("batch.gridMode") private var gridMode: GridMode = .byVerdict
    /// 分组模式下单张照片（没有连拍、不用挑）收在最后的折叠区里，默认收起 ——
    /// 以前每张单张也占一整行，真正要挑的连拍被冲散，得一直往下滚着找。
    @AppStorage("batch.showSingles") private var showSingles = false
    /// 右侧「筛选严格度」面板。调完阈值基本不再碰，小屏上收起来给网格让地方（⌥⌘S）。
    @AppStorage("batch.showControls") private var showControls = true
    /// 已定的场默认叠起来（Aftershoot 的叠放）：只显示留下的，被废的收成一个按钮。这里记的是
    /// 手动展开了的场。换场次清空。
    @State private var expandedTakes: Set<Int> = []
    /// 只看待处理的场 —— 3000 张的婚礼里绝大多数场只有 1 张，真正要取舍的堆栈
    /// 本来全被它们淹掉。「待处理」= 还留着 2 张以上没淘汰的场；已经定成
    /// 1 张精选、其余废片的，活儿干完了就自动从视野里消失。
    @AppStorage("batch.pendingTakesOnly") private var pendingTakesOnly = false
    /// 场内按评分排（Aftershoot 的重复组里 AI 选中的排第一）。默认按拍摄顺序，
    /// 因为连拍的时间线本身就是信息（哪张是最后按的）。
    @AppStorage("batch.takeSortByScore") private var takeSortByScore = false
    /// D 键上一次落在哪一场 —— 焦点丢了（比如废纸篓清掉了那张）时的回退。
    @State private var lastVisitedTake: Int?
    @State private var showAcceptAllConfirm = false
    /// 这次「接受推荐」的范围：nil = 全部章节，否则只这一章（确认框的字跟着它）。
    @State private var acceptScope: Int?
    @State private var acceptPreview: (takes: Int, rejects: Int) = (0, 0)
    @State private var showStatsPopover = false
    /// 状态栏「N 台机身」点开的对时面板。
    @State private var showBodyClock = false
    /// 快捷键一览（状态栏右下角的键盘图标，或网格里按 ?）。
    @State private var showShortcuts = false
    /// 从访达拖文件夹进来时的高亮。
    @State private var folderDropTargeted = false
    /// 「选择文件夹…」的面板 / 提示框开着（runModal 期间）：存储卡导完别在这时候切场次。
    @State private var modalPanelOpen = false
    /// 审片里按 C 去挑连拍的：挑完回到审片（同一个顺序、停在挑完那张），不是回网格。
    @State private var reviewAfterPick = false
    /// Fullscreen review: one big photo + filmstrip, digit-verdicts auto-advance.
    @State private var reviewMode = false
    /// The grid order FROZEN when the inspector / review mode opened. Paging
    /// used to follow the live `visibleItems`: re-judging a photo moved it to
    /// another section (or out of the filtered list), so → jumped into the
    /// reject section or the arrows died. Trash intersects this with the live
    /// ids; a session switch clears it.
    @State private var pagingOrder: [String] = []
    /// 这一轮审片里「跳过废片」能不能起作用：进来的那一刻定死。算成活的话，先筛选废片再审、救回一张，
    /// 「有留下的了」立刻成立，整轮只剩那一张（审查发现）；反过来废掉最后一张留下的又会突然不跳。
    @State private var reviewSkippable = true

    var body: some View {
        Group {
            if reviewMode {
                ReviewView(store: store, orderIDs: pagingOrder, rejectsSkippable: reviewSkippable,
                           focusedID: $focusedID, reviewMode: $reviewMode) { id in
                    // 审到一组连拍：C 直接去挑这一场，挑完回到审片接着往下。
                    // 只挑这一场（.only）：⏎ 定完自动回来，不会顺着去挑别的组。
                    guard let item = store.item(withID: id), (store.takeSizes[item.take] ?? 0) >= 2 else { return }
                    reviewAfterPick = true
                    reviewMode = false
                    pickRequest = .only(item.take, focus: id)
                }
            } else if let request = pickRequest {
                PickView(store: store, request: request, sortByScore: takeSortByScore) { focusID in
                    pickRequest = nil
                    // 从审片过来的：回审片（顺序还是进审片时冻结的那份），停在按 C 的那张 —— focusedID
                    // 一直没动；那张被废了而跳过废片开着，ReviewView.onAppear 会落到它后面第一张留下的。
                    // 以前这里把焦点换成挑选里高亮的那张（可能在别的场），中间的照片就悄悄跳过了。
                    if reviewAfterPick {
                        reviewAfterPick = false
                        reviewMode = true
                        return
                    }
                    if let focusID {
                        focusedID = focusID
                        lastVisitedTake = store.item(withID: focusID)?.take
                    }
                }
                .id(request)
            } else {
                VStack(spacing: 0) {
                    topBar
                    Divider()
                    // 分组模式的工具自己一行。顶栏 27 个控件在 1280pt 必然溢出 ——
                    // 长文件夹名把「撤销/审片」挤出窗口的工单已经出过一次。
                    if gridMode == .byGroup && !store.items.isEmpty {
                        groupToolbar
                        Divider()
                    }
                    if !selectedIDs.isEmpty {
                        bulkActionBar
                        Divider()
                    }
                    // Plain HStack: the old HSplitView had a fixed-width right
                    // pane, so its divider never moved anyway.
                    HStack(spacing: 0) {
                        gridArea
                            .frame(minWidth: 500, maxWidth: .infinity)
                        if showControls {
                            Divider()
                            controlPanel
                                .frame(width: 300)
                                .transition(.move(edge: .trailing))
                        }
                    }
                    importBanner
                    Divider()
                    statusBar
                }
                // 从访达把文件夹拖进来就打开（Aftershoot / Narrative 都这样）；拖的是照片就打开它所在的文件夹。
                .overlay {
                    if folderDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                Label("松开打开这个文件夹", systemImage: "folder.badge.plus")
                                    .font(.title3.bold())
                                    .padding(.horizontal, 18).padding(.vertical, 10)
                                    .background(.black.opacity(0.7), in: Capsule())
                            )
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $folderDropTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { openDroppedFolder(url) }
                    }
                    return true
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { inspectedID != nil },
            set: { if !$0 { inspectedID = nil } }
        )) {
            if let id = inspectedID {
                PhotoInspector(store: store, inspectedID: $inspectedID,
                               gridOrder: pagingOrder, initialID: id) { currentID in
                    inspectedID = nil
                    if let item = store.item(withID: currentID) {
                        pickTake(item.take, focus: currentID)
                    }
                }
            }
        }
        // 换了一场拍摄就把选择/焦点全部丢掉。留着的话批量改判栏还显示"已选 3 张"，
        // 点下去会把判决写进新场次里根本不存在的 id（同名文件则改判错照片）。
        // 存储卡导完：闲着（网格就在眼前）就直接打开、开始分析；正在挑片 / 审片 / 看大图 / 开着导出框，
        // 就只留一条横幅 —— 自动切场次会把没确认的挑选草稿、审片位置一起扔掉（审查发现）。
        .onChange(of: store.importCompletions) { openFinishedImportIfIdle() }
        .onAppear { openFinishedImportIfIdle() }
        .onChange(of: store.photoDir) {
            reviewMode = false
            reviewAfterPick = false
            selectedIDs = []
            focusedID = nil
            inspectedID = nil
            pagingOrder = []
            pickRequest = nil
            expandedTakes = []
        }
        // 实时桥（§9.6b）：这几样开着时 AI 的改判 / 切场次 / 定位照片要等或者不做。只往 store 上记，界面不变
        .onChange(of: liveFlags, initial: true) { store.liveUI = liveFlags }
        // 重新分析会原地覆盖预览图 —— 不清缓存的话数值更新了、图还是旧的。
        // 只有分析真的重写了预览才清；切场次/VLM/废纸篓也发同一通知，
        // 以前跟着一起清空，切回来整个网格重新解码一遍。
        .onReceive(NotificationCenter.default.publisher(for: .analysisDidFinish)) { note in
            if note.userInfo?["previewsChanged"] as? Bool == true {
                ThumbCache.invalidate()
            }
        }
        // 废片进废纸篓后这些 id 就没了，留着同样会写到不存在的照片上。
        .onChange(of: store.items.count) {
            let live = Set(store.items.map(\.id))
            selectedIDs.formIntersection(live)
            pagingOrder.removeAll { !live.contains($0) }
            if let focused = focusedID, !live.contains(focused) { focusedID = nil }
            if let inspected = inspectedID, !live.contains(inspected) { inspectedID = nil }
        }
        .sheet(isPresented: $showJPEGSheet) { jpegExportSheet }
        .sheet(isPresented: $showISOSheet) { isoExportSheet }
        .sheet(isPresented: $showHighlightsSheet) { highlightsSheet }
        .sheet(isPresented: $showClientImport) { ClientImportSheet(store: store, isPresented: $showClientImport) }
        .sheet(isPresented: $showBodyClock) { BodyClockSheet(store: store, isPresented: $showBodyClock) }
        .confirmationDialog(acceptTitle, isPresented: $showAcceptAllConfirm) {
            Button("定案 · \(acceptPreview.rejects) 张设为废片") {
                let scope = acceptScope
                withAnimation { store.acceptAllRecommendations(inChapter: scope) }
                selectedIDs.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(acceptMessage)
        }
        .confirmationDialog(
            "把 \(store.trashableRejectCount) 张废片移到废纸篓？",
            isPresented: $showTrashConfirm
        ) {
            Button("移到废纸篓", role: .destructive) { store.trashRejects() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(trashMessage)
        }
        .confirmationDialog(
            "清除全部 \(store.recentSessions.count) 条历史记录？",
            isPresented: $showClearRecentsConfirm
        ) {
            Button("清除", role: .destructive) { store.clearRecentSessions() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将释放约 \(BatchStore.sizeText(store.totalSessionBytes)) 磁盘空间。" +
                 "只删除这些拍摄的缓存分析结果 (预览图/判决/人工改判)，照片本身不动。重新打开这些文件夹需要再分析一次。" +
                 "更早掉出菜单的拍摄只清预览图，判决照旧留着。")
        }
    }

    // MARK: - 存储卡导入：导完待打开的横幅、导入出的问题

    /// 用户正在干别的（挑片、审片、看大图、开着导出框 / 确认框 / 选文件夹）：导完别自动切场次 ——
    /// 确认框底下换了场次，「移到废纸篓」「接受推荐」就落到新文件夹上了（审查发现）。
    private var busyWithPhotos: Bool {
        reviewMode || pickRequest != nil || inspectedID != nil || modalPanelOpen
            || showJPEGSheet || showISOSheet || showHighlightsSheet || showClientImport
            || showTrashConfirm || showAcceptAllConfirm || showClearRecentsConfirm
    }

    private func openFinishedImportIfIdle() {
        store.openFinishedImportIfReady(userBusy: busyWithPhotos)
    }

    /// busyWithPhotos 拆成三样给实时桥（§9.6b 第二轮改）：sheet 和确认框（另加对时面板）、连拍挑选、审片 / 检视器。
    private var liveFlags: BatchStore.LiveUIFlags {
        let exports = showJPEGSheet || showISOSheet || showHighlightsSheet || showClientImport || showBodyClock
        let confirms = showTrashConfirm || showAcceptAllConfirm || showClearRecentsConfirm
        let sheet: Bool = modalPanelOpen || exports || confirms
        return BatchStore.LiveUIFlags(sheet: sheet, pick: pickRequest != nil, viewing: reviewMode || inspectedID != nil)
    }

    /// AI 的「在 app 里定位照片」（cull_show_photos，§9.3）：选中这些（或者只移焦点）、滚过去。只改视图状态：不改判决、
    /// 不改筛选、不开检视器；被当前筛选藏起来的不选，报回去（hidden_by_filter）。场次换了的请求不认。
    private func applyViewRequest(_ proxy: ScrollViewProxy) {
        guard let request = store.viewRequest else { return }
        store.viewRequest = nil
        guard store.photoDir != nil, request.session == store.sessionDir.lastPathComponent else { return }
        let ids = request.ids.filter { store.item(withID: $0) != nil }
        let visible = Set(visibleItems.map(\.id))
        let shown = ids.filter { visible.contains($0) }
        // 要的一张都看不见（被筛选藏起来、折在连拍里）：用户原来的选中不动，只报回去
        if request.select && !shown.isEmpty { selectedIDs = Set(shown) }
        if let first = shown.first {
            focusedID = first
            lastVisitedTake = store.item(withID: first)?.take
            DispatchQueue.main.async { proxy.scrollTo(first, anchor: .center) }
        }
        store.viewApplied = BatchStore.ViewApplied(token: request.token, selected: request.select ? shown : [],
                                                   focus: shown.first, hidden: ids.filter { !visible.contains($0) })
    }

    @ViewBuilder
    private var importBanner: some View {
        if let done = store.finishedImport {
            HStack(spacing: 10) {
                Image(systemName: "sdcard.fill").foregroundStyle(.green)
                Text(finishedImportText(done)).font(.callout)
                Spacer()
                Button(done.analyze ? "打开并分析" : "打开") { store.openFinishedImport() }
                    .controlSize(.small)
                    .disabled(store.isRunning)
                Button { store.finishedImport = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("不打开（以后从「选择文件夹…」打开这个文件夹也行）")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.green.opacity(0.12))
        }
        if let notice = store.importNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(notice).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer()
                Button { store.importNotice = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("知道了（关掉这条提醒）")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.14))
        }
    }

    private func finishedImportText(_ done: CardImporter.FinishedImport) -> String {
        "存储卡导入完成：\(done.shots) 张在 " + CardImporter.displayPath(done.folder)
    }

    // MARK: - Top bar (workflow-ordered: source → analyze → view → review → export)

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("选择文件夹...") { pickFolder() }
                // 插卡时会自己问；这条给「卡早就插着、当时点了不导入」的时候用。
                Button("从存储卡导入...") {
                    NotificationCenter.default.post(name: .cardImportRequested, object: nil)
                }
                if !store.recentSessions.isEmpty {
                    Divider()
                    ForEach(store.recentSessions) { session in
                        let missing = store.missingSessionKeys.contains(session.key)
                        Button("\(session.name) · \(session.photoCount) 张\(missing ? " (文件夹已不存在)" : "")") {
                            store.switchSession(to: URL(fileURLWithPath: session.path))
                        }
                    }
                    Divider()
                    // NSMenu items can't carry their own context menu, so removal
                    // lives in a submenu rather than a right-click on each row.
                    // 缓存体积在这里显示：预览图约 190KB/张，15 场大拍摄能到几个 GB，
                    // 而菜单本来完全看不出占了多少盘。
                    Menu("移除历史记录 (共 \(BatchStore.sizeText(store.totalSessionBytes)))") {
                        ForEach(store.recentSessions) { session in
                            let bytes = store.sessionSizes[session.key] ?? 0
                            Button("\(session.name) · \(session.photoCount) 张 · \(BatchStore.sizeText(bytes))") {
                                store.removeSession(session)
                            }
                        }
                        Divider()
                        Button("全部清除...", role: .destructive) { showClearRecentsConfirm = true }
                    }
                }
            } label: {
                Label(store.photoDir?.lastPathComponent ?? "选择文件夹",
                      systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Capped: `.fixedSize()` let a long Chinese folder name push 撤销/
            // 审片/导出 off the right edge of a 1280pt window.
            // 保底 110：窄窗口里别的控件把它挤得只剩「f…」，连是哪场拍摄都看不出。
            .frame(minWidth: 110, maxWidth: 260)
            .fixedSize(horizontal: false, vertical: true)
            // 处理中换文件夹会污染网格并让"重新分析"卡死，store 里也有守卫兜底。
            .disabled(store.isRunning)
            .help(store.isRunning ? "正在处理中，先取消再切换文件夹"
                                  : (store.photoDir?.path ?? "选择一场拍摄的照片文件夹"))
            // Folders get deleted in Finder while the app sits open — recheck on
            // the way back in so the menu isn't showing yesterday's truth.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                store.refreshSessionAvailability()
            }

            if store.isRunning {
                Button("取消") { store.cancel() }
            } else {
                if store.items.isEmpty {
                    Button("开始分析") { store.runAnalysis() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.photoDir == nil)
                        .help("原生引擎分析全部照片 (锐度/闭眼/曝光/连拍分组)")
                } else {
                    // 分析过了就不再是主按钮：以前分析完它还是醒目的蓝色，像是「下一步」，容易误点重跑。
                    Button("重新分析") { store.runAnalysis() }
                        .disabled(store.photoDir == nil)
                        .help("只分析新增或改动过的照片，没动过的直接沿用（拷进了新照片时用）")
                }
            }

            Divider().frame(height: 16)

            Picker("视图", selection: $gridMode) {
                ForEach(GridMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            // 两种模式都有判决筛选。分组模式下「只看精选」= 每场只剩那一张，
            // 交付前过一遍最终选片正好用它。
            Picker("筛选", selection: $store.verdictFilter) {
                Text("全部").tag(Verdict?.none)
                // 精选 / 可用 / 废片：和数字键 1 / 2 / 3、网格分区同一个顺序（以前是反的）。
                ForEach(Verdict.allCases.reversed(), id: \.self) { v in
                    Text(v.rawValue).tag(Verdict?.some(v))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            // 「只看客户选中」：和判决筛选叠加。没导入过客户选择就不占顶栏的地方。
            if store.clientPickCount > 0 || store.clientPickFilter {
                Toggle(isOn: $store.clientPickFilter) {
                    Label {
                        Text("客户选中 \(store.clientPickCount)")
                    } icon: {
                        Image(systemName: "heart.fill").foregroundStyle(store.clientPickFilter ? Color.purple : Color.secondary)
                    }
                }
                .toggleStyle(.button)
                .fixedSize()
                .help("只看客户选中的照片（和左边的判决筛选叠加）。没选中照片时，复制文件名、复制原片就按这个范围")
            }
            Picker("排序", selection: $store.sortOrder) {
                ForEach(BatchStore.SortOrder.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("排序：网格内的顺序按拍摄时间 (双机位混排也按时间)、按文件名或按评分")

            Spacer()

            // 撤销 / 全选用图标：顶栏在 1100pt 宽时文件夹名被挤得只剩「f…」，这两个有快捷键、图标也认得出。
            Button { store.undoLastOverride() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndoOverride)
                .help("撤销上一步：改判、导入 / 清除客户选中、按机身对时 (⌘Z)")
            Button { selectedIDs = Set(visibleItems.map(\.id)) } label: { Image(systemName: "checkmark.square") }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(store.items.isEmpty)
                .help("全选当前筛选下的照片 (⌘A)，配合批量栏一次改判")
            Button("审片") { enterReview() }
                .keyboardShortcut("f", modifiers: [])
                .disabled(store.items.isEmpty)
                .help("全屏逐张审片 · F 进入 · 1精选 2可用 3废片 0恢复")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .help(showControls ? "收起右侧筛选面板，网格更宽 (⌥⌘S)" : "显示右侧筛选面板 (⌥⌘S)")
            Button("复盘") { showStatsPopover = true }
                .disabled(store.items.isEmpty)
                .popover(isPresented: $showStatsPopover) { statsPopover }
                .help("按焦段/ISO 的出片率统计")

            Menu {
                Button("写入 XMP (LR/C1 可读)") { store.exportXMP() }
                    .disabled(store.items.isEmpty || store.isRunning)
                Button("导出 JPG...") { showJPEGSheet = true }
                    .disabled(jpegExportCount == 0 || store.isRunning)
                Button("精华 Top N (JPG)...") { showHighlightsSheet = true }
                    .disabled(store.items.isEmpty || store.isRunning)
                Button("导出高 ISO RAW (降噪)...") { showISOSheet = true }
                    .disabled(store.items.isEmpty || store.isRunning)
                Divider()
                clientMenuItems
                Divider()
                Button("废片移到废纸篓 (\(store.trashableRejectCount))", role: .destructive) {
                    showTrashConfirm = true
                }
                .disabled(store.trashableRejectCount == 0 || store.isRunning)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Bottom status bar (the ONE home for stats + progress)

    private var statusBar: some View {
        let counts = store.verdictCounts
        let total = store.items.count
        let rejectPct = total > 0 ? Int(Double(counts.reject) / Double(total) * 100) : 0
        return HStack(spacing: 12) {
            if total > 0 {
                Text("共 \(total) · 精选 \(counts.pick) · 可用 \(counts.usable) · 废片 \(counts.reject) (\(rejectPct)%) · 出片 \(counts.pick + counts.usable) (\(100 - rejectPct)%)")
                    .font(.caption).monospacedDigit()
                if pendingInScope == 0 && burstTakesInScope > 0 {
                    // 下一步提示：连拍都定完了，接下来通常是逐张过一遍留下的。
                    Text((store.activeChapterFilter != nil ? "本章" : "") + "连拍都挑完了 · F 审片")
                        .font(.caption).foregroundStyle(.green)
                        .help("按 F 进审片模式逐张过一遍留下的，然后在右上角「导出」写 XMP 或导出 JPG")
                }
                if pendingInScope > 0 {
                    // 两种视图都有的入口：点一下就开始一组一组挑（按判决视图下没有分组工具条）。
                    Button { startPicking() } label: {
                        Text((store.activeChapterFilter != nil ? "本章" : "") + "待处理 \(pendingInScope) 场连拍 · C 开始挑选")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("还留着 2 张以上没淘汰的场。点这里（或按 C）一组一组挑；按 D 在网格里跳到下一个")
                }
                if store.manualOverrideCount > 0 {
                    Text("人工改判 \(store.manualOverrideCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.clientPickCount > 0 {
                    Label("客户选中 \(store.clientPickCount)", systemImage: "heart.fill")
                        .font(.caption).foregroundStyle(.purple)
                        .help("导入的客户选择（紫心）。顶栏「客户选中」只看这些；「导出」菜单里复制文件名、复制原片到精修文件夹")
                }
                if store.bodies.count >= 2 { bodyClockHint }
            }
            // 上次写 XMP 之后又改了判决：Lightroom / C1 那边还是旧的，提醒一下、点一下就重写。
            if store.xmpStaleCount > 0 {
                Button { store.exportXMP() } label: {
                    Label("XMP 待更新 \(store.xmpStaleCount) 张 · 点这里重新写入", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .disabled(store.isRunning)
                .help("有 \(store.xmpStaleCount) 张的判决、星级或客户选中和上次写进 XMP 的不一样（或者上次没写进去），Lightroom / Capture One 读到的还是旧的。点这里按现在的判决重写（别的软件写的 XMP 只改星级/色标，调色等原样保留）")
            }
            if store.unparsedCount > 0 {
                // Photos the engine couldn't read are invisible in the grid;
                // without this the folder silently has more photos than shown.
                Label("\(store.unparsedCount) 张未能解析", systemImage: "questionmark.square.dashed")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help("文件夹里有 \(store.unparsedCount) 张照片无法解码 (文件损坏、格式不支持或分析时还在拷贝)，不在网格中。修复后重新分析即可")
            }
            // 解得出来但文件不完整的：在网格里、已判废片，这条一直挂着 —— 别以为卡上的原片没问题就格式化了。
            if let corrupt = store.reasonCounts["文件损坏"] {
                Label("\(corrupt) 张文件损坏", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help("这 \(corrupt) 张文件不完整 (JPEG 结尾缺失、解出来缺的那截是灰的，多半是读卡出错或拷贝中断)，已判废片。卡先别格式化，从卡上重新拷一次再分析")
            }
            // 章节警告收成一条：长场次里几十章，一条一个会把状态栏挤爆。全文在提示里，时间轴上有三角标。
            if let first = store.chapterWarnings.first {
                let all = store.chapterWarnings
                // 整章全灭（漏交）比「留得少」严重：有就先说它，红色，别藏在提示里。
                let wiped = store.chapterSegments.filter { $0.allRejected && !$0.undated }.count
                let thin = all.count - wiped
                let summary = wiped > 0
                    ? "\(wiped) 个章节全部被淘汰" + (thin > 0 ? "，\(thin) 个留得太少" : "")
                    : "\(all.count) 个章节留得太少（时间轴上标了三角）"
                Label(all.count == 1 ? first : summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(wiped > 0 ? .red : .orange).lineLimit(1)
                    .help(all.joined(separator: "\n"))
            }
            if let error = store.lastError {
                HStack(spacing: 4) {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .lineLimit(1).help(error)
                    Button { store.lastError = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("关闭这条提示")
                }
            }
            Spacer()
            if !store.progressText.isEmpty {
                Text(store.progressText).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let fraction = store.progressFraction {
                ProgressView(value: fraction).frame(width: 140)
            }
            Slider(value: $thumbSize, in: 90...260)
                .frame(width: 100)
                .help("缩略图大小 (- / =)")
            Button { showShortcuts.toggle() } label: { Image(systemName: "keyboard") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("快捷键一览 (?)")
                .popover(isPresented: $showShortcuts, arrowEdge: .top) { ShortcutsPanel() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 双机位才有：「2 台机身」，点开按机身对时。对过的标出来（排序、章节已经按对过的时间排）。
    private var bodyClockHint: some View {
        let adjusted = store.bodies.contains { $0.offset != 0 }
        let title = "\(store.bodies.count) 台机身" + (adjusted ? " · 已对时" : "")
        return Button { showBodyClock = true } label: {
            Label(title, systemImage: "camera.on.rectangle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("这一场有 \(store.bodies.count) 台机身（同型号的按序列号分开），连拍的「场」各分各的。两台的钟不准时点这里对时")
    }

    // MARK: - JPG export sheet

    private var jpegOptions: Binding<DeliveryOptions> {
        Binding(get: {
            DeliveryOptions.load(jpegDeliveryRaw,
                                 defaults: .jpegExport(legacyMaxPixel: jpegMaxPixel, legacyQuality: jpegQuality))
        }, set: { jpegDeliveryRaw = $0.stored })
    }

    private var highlightsOptions: Binding<DeliveryOptions> {
        Binding(get: {
            DeliveryOptions.load(highlightsDeliveryRaw, defaults: .highlights(legacyMaxPixel: highlightsMaxPixel))
        }, set: { highlightsDeliveryRaw = $0.stored })
    }

    private var jpegExportSheet: some View {
        let options = jpegOptions
        let preview = store.jpegNamePreview(options.wrappedValue, includeUsable: jpegIncludeUsable)
        return VStack(alignment: .leading, spacing: 14) {
            Text("导出 JPG").font(.headline)
            Toggle("包含可用 (关闭则仅导出精选)", isOn: $jpegIncludeUsable)
            DeliveryOptionsSection(options: options, namePreview: preview)
            Toggle("覆盖已存在的同名文件", isOn: $jpegOverwrite)
                .help("关闭时目标里已有同名文件就另存为 -2、-3，旧文件不动 (防止覆盖客户已精修的文件)")
            Text("共 \(jpegExportCount) 张 · 重编码，保留 EXIF · 默认导出到 拍摄文件夹/\(ImageLoader.jpegExportSubfolder)/ (不参与分析)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { showJPEGSheet = false }
                Button("其他文件夹...") {
                    showJPEGSheet = false
                    exportJPEGs(to: nil)
                }
                .disabled(jpegExportCount == 0)
                Button("导出到 \(ImageLoader.jpegExportSubfolder)/") {
                    showJPEGSheet = false
                    exportJPEGs(to: store.defaultJPEGExportFolder)
                }
                .buttonStyle(.borderedProminent)
                .disabled(jpegExportCount == 0 || store.defaultJPEGExportFolder == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - 精华 Top N sheet

    private var highlightsSheet: some View {
        let top = store.topPicks(highlightsCount)
        let options = highlightsOptions
        let preview = store.jpegNamePreview(options.wrappedValue, includeUsable: true, ids: top.ids, ranked: true)
        return VStack(alignment: .leading, spacing: 14) {
            Text("精华 Top N").font(.headline)
            Text("全场评分最高的 N 张（表情 > 人脸质量 > 锐度），精选优先、不够从可用里补。当天发客户/朋友圈的那一把。")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("张数：\(highlightsCount)", value: $highlightsCount, in: 5...100, step: 5)
            DeliveryOptionsSection(options: options, namePreview: preview, tokensHint: DeliveryNaming.rankTokenHint)
            Text(top.fromUsable > 0
                 ? "精选只有 \(top.ids.count - top.fromUsable) 张，从可用里按评分补了 \(top.fromUsable) 张"
                 : "共 \(top.ids.count) 张，全部来自精选")
                .font(.caption).foregroundStyle(top.fromUsable > 0 ? .orange : .secondary)
            Text("每次导到 拍摄文件夹/\(ImageLoader.jpegExportSubfolder)/精华/ 下面一个新文件夹（Top\(top.ids.count)_日期_时间），不和上次导的混")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("取消") { showHighlightsSheet = false }
                Button("导出 \(top.ids.count) 张") {
                    showHighlightsSheet = false
                    guard let base = store.defaultJPEGExportFolder else { return }
                    store.exportHighlights(count: highlightsCount, into: base.appendingPathComponent("精华"),
                                           options: options.wrappedValue)
                }
                .buttonStyle(.borderedProminent)
                .disabled(top.ids.isEmpty || store.defaultJPEGExportFolder == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - 高ISO RAW export sheet

    /// (RAW count, matching-but-JPEG-only count) under the sheet's current
    /// settings — same store query the export itself runs, so the numbers match.
    private var isoExportMatches: (raws: Int, jpegOnly: Int) {
        let matches = store.highISOMatches(minISO: isoThreshold, keepersOnly: isoKeepersOnly)
        return (matches.raws.count, matches.jpegOnly)
    }

    private var isoExportSheet: some View {
        let matches = isoExportMatches
        return VStack(alignment: .leading, spacing: 14) {
            Text("导出高 ISO RAW (降噪)").font(.headline)
            Picker("ISO ≥", selection: $isoThreshold) {
                ForEach([800, 1600, 3200, 6400, 12800], id: \.self) { iso in
                    Text("\(iso)").tag(iso)
                }
            }
            .pickerStyle(.segmented)
            Toggle("排除废片", isOn: $isoKeepersOnly)
            Text("符合条件: \(matches.raws) 个 RAW"
                 + (matches.jpegOnly > 0 ? " (另有 \(matches.jpegOnly) 张只有 JPG，不会复制)" : ""))
                .font(.caption).foregroundStyle(.secondary)
            Text("复制 (不移动) 到 拍摄文件夹/\(ImageLoader.denoiseSubfolder)/，供 DxO PureRAW、LR AI 降噪等批量处理；该文件夹不参与分析")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("取消") { showISOSheet = false }
                Button("开始复制") {
                    showISOSheet = false
                    store.exportHighISORaws(minISO: isoThreshold, keepersOnly: isoKeepersOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(matches.raws == 0)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// Grid order under the current filter — shared by keyboard nav and inspector paging.
    private var visibleItems: [BatchItem] {
        if gridMode == .byGroup {
            // 每场一行、行内按拍摄顺序，单张区展开了就接在最后 —— 键盘 ←/→ 和检视器翻页走的
            // 就是这个顺序（收起的单张不在里面：看不见的照片不该被翻到）。
            return groupedItems.flatMap(\.members) + (showSingles ? singleItems : [])
        }
        let ordered = [Verdict.pick, .usable, .reject].flatMap { sectionItems($0) }
        guard let filter = store.verdictFilter else { return ordered }
        return ordered.filter { $0.verdict == filter }
    }

    /// 每场一行的数据（只有多张的场；单张见 singleItems）。分组本身在 store 的 Derived 里算好
    /// （takeRows），这里只做筛选：以前这是个计算属性，每次按键都对全部照片 Dictionary(grouping:) + 排序。
    private var groupedItems: [(group: Int, members: [BatchItem])] {
        let items = store.items
        let chapter = store.activeChapterFilter
        return store.takeRows.compactMap { row in
            guard row.indices.count >= 2 else { return nil }
            // 「只看这一章」：一场不会跨章，看第一张就够。
            if let chapter, let first = row.indices.first, first < items.count,
               BatchStore.timelineChapter(of: items[first]) != chapter { return nil }
            // 下标是上次 rebuildDerived 时的；items 换掉但还没重算的那一帧，靠这个
            // 守卫别把照片画进错的场（和 item(withID:) 里那道守卫同一套约定）。
            var members = row.indices.compactMap { idx -> BatchItem? in
                guard idx < items.count, items[idx].take == row.take else { return nil }
                return items[idx]
            }
            let alive = members.filter { $0.verdict != .reject }
            let pending = store.isPendingTake(alive: alive)
            if pendingTakesOnly, !pending { return nil }
            if let filter = store.verdictFilter {
                members = members.filter { $0.verdict == filter }
            } else if !pending, !alive.isEmpty, !expandedTakes.contains(row.take), !store.clientPickFilter {
                // 定完的场叠起来：只剩留下的那几张（整场全废的不叠，不然这一行什么都看不见）。
                // 「只看客户选中」时不叠：客户选中的废片也得看得见。
                members = alive
            }
            if store.clientPickFilter { members = members.filter { store.clientPicks.contains($0.id) } }
            guard !members.isEmpty else { return nil }
            if takeSortByScore {
                members.sort {
                    let ka = BatchStore.scoreKey($0), kb = BatchStore.scoreKey($1)
                    return ka == kb ? $0.id < $1.id : ka > kb
                }
            }
            return (row.take, members)
        }
    }

    /// 分组模式里的单张照片（这一场只有它一张），按拍摄顺序。「只看待处理」时不显示。
    private var singleItems: [BatchItem] {
        guard !pendingTakesOnly else { return [] }
        let items = store.items
        return store.takeRows.compactMap { row -> BatchItem? in
            guard row.indices.count == 1, let idx = row.indices.first, idx < items.count,
                  items[idx].take == row.take else { return nil }
            let item = items[idx]
            if let filter = store.verdictFilter, item.verdict != filter { return nil }
            if store.clientPickFilter, !store.clientPicks.contains(item.id) { return nil }
            if let chapter = store.activeChapterFilter, BatchStore.timelineChapter(of: item) != chapter { return nil }
            return item
        }
    }

    /// 选中的照片牵扯到的**多张**场的全部成员 —— 「保留选中·其余废片」的候选集。
    /// 支持一次跨多场：每场挑一张，一次性把 5 场的重复全部定案。
    /// 单张场要排除掉：选 4 张毫不相干的照片 + 1 张连拍，候选集里混进那 4 张单张，
    /// 一点定案就把它们一起写成精选了 —— 用户根本没要求改它们的判决。
    private var selectionGroupMembers: [String] {
        let sizes = store.takeSizes
        let takes = Set(store.items
            .filter { selectedIDs.contains($0.id) && (sizes[$0.take] ?? 1) > 1 }
            .map(\.take))
        guard !takes.isEmpty else { return [] }
        return store.items.filter { takes.contains($0.take) }.map(\.id)
    }

    // MARK: - Left: results grid (dark canvas — photos judge better on neutral gray)

    private var gridArea: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !store.chapterSegments.isEmpty {
                    ChapterTimeline(segments: store.chapterSegments, viewport: viewport,
                                    showPending: gridMode == .byGroup,
                                    minKeepers: store.minKeepersPerChapter,
                                    filtered: store.activeChapterFilter,
                                    onFilter: { chapter in setChapterFilter(chapter, proxy: proxy) }) { segment in
                        jumpToChapter(segment, proxy: proxy)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    // 悬停卡片画在时间轴下面、压在网格上：时间轴得排在网格之上。
                    .zIndex(1)
                    if let chapter = store.activeChapterFilter,
                       let segment = store.chapterSegments.first(where: { $0.chapter == chapter }) {
                        chapterFilterBar(segment, proxy: proxy)
                    }
                }
                ScrollView {
                // pinnedViews：滚到废片区中间也看得见"在哪个区、多少张、理由 chip"。
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    if store.items.isEmpty {
                        emptyState
                    } else if gridMode == .byGroup {
                        groupGrid
                    } else {
                        ForEach(Verdict.allCases.reversed(), id: \.self) { verdict in
                            if store.verdictFilter == nil || store.verdictFilter == verdict {
                                verdictSection(verdict, color: verdict.color)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(white: 0.13))
            .background(GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width, initial: true) {
                    gridWidth = geo.size.width
                }
            })
            // 从审片/连拍挑选回来，网格是重新建的，滚动位置归零 —— 滚回焦点那张。
            // 异步一拍：嵌套的 Lazy 网格要先铺出来 scrollTo 才找得到。
            // AI 在别的 tab 时要定位的照片（cull_show_photos 的 pending）也在这里补上。
            .onAppear {
                applyViewRequest(proxy)
                guard let id = focusedID else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: store.viewRequest) { applyViewRequest(proxy) }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { moveFocus(-1, proxy: proxy); return .handled }
            .onKeyPress(.rightArrow) { moveFocus(1, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { moveFocusVertically(-1, proxy: proxy); return .handled }
            .onKeyPress(.downArrow) { moveFocusVertically(1, proxy: proxy); return .handled }
            .onKeyPress(.space) { openFocused(); return .handled }
            .onKeyPress(characters: .init(charactersIn: "dD")) { press in
                guard press.modifiers.isSubset(of: [.shift, .capsLock]) else { return .ignored }
                jumpToNextPendingTake(proxy)
                return .handled
            }
            // C：进连拍挑选。⌘C（拷贝）之类放过去。
            .onKeyPress(characters: .init(charactersIn: "cC")) { press in
                guard press.modifiers.isSubset(of: [.shift, .capsLock]) else { return .ignored }
                return pickFromKeyboard() ? .handled : .ignored
            }
            .onKeyPress(.return) { openFocused(); return .handled }
            // ?：快捷键一览。
            .onKeyPress(characters: .init(charactersIn: "?")) { _ in
                showShortcuts.toggle()
                return .handled
            }
            // [ ]：上一章 / 下一章（时间轴上那一段的第一张）。
            .onKeyPress(characters: .init(charactersIn: "[]")) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                jumpChapter(press.characters == "]" ? 1 : -1, proxy: proxy)
                return .handled
            }
            // 只认按下：现在改判后焦点会挪到下一张，按住 3 的按键重复会一张接一张往下废。
            .onKeyPress(characters: .init(charactersIn: "1230"), phases: .down) { press in
                // A digit hits the whole ⌘/⇧ selection when there is one —
                // "select five, press 3" used to reject only the focused photo.
                let targets: [String] = !selectedIDs.isEmpty ? Array(selectedIDs)
                    : (focusedID.map { [$0] } ?? [])
                guard !targets.isEmpty else { return .ignored }
                let verdict: Verdict?
                switch press.characters {
                case "1": verdict = .pick
                case "2": verdict = .usable
                case "3": verdict = .reject
                default: verdict = nil
                }
                let before = visibleItems.map(\.id)
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.setOverrideBatch(targets, verdict)
                }
                if selectedIDs.isEmpty, let focused = focusedID {
                    keepPlace(of: focused, before: before, proxy: proxy)
                }
                return .handled
            }
            // - / =：缩略图小一号 / 大一号（Lightroom 网格的习惯）。
            .onKeyPress(characters: .init(charactersIn: "-=+")) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                let step: Double = press.characters == "-" ? -20 : 20
                withAnimation(.easeOut(duration: 0.15)) { thumbSize = min(260, max(90, thumbSize + step)) }
                if let id = focusedID { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                return .handled
            }
        }
    }

    /// Freeze the current grid order, then open — see `pagingOrder`.
    /// 分组模式下 visibleItems 是每场展开后的全部成员（以前只有封面：打开一场
    /// 10 张按 → 会跳到下一场，审片也只审封面、18 张静默跳过 13 张）。
    private func openInspector(_ id: String) {
        pagingOrder = visibleItems.map(\.id)
        inspectedID = id
    }

    private func enterReview() {
        pagingOrder = reviewOrder()
        reviewSkippable = pagingOrder.contains { store.item(withID: $0).map { $0.verdict != .reject } ?? false }
        reviewMode = true
    }

    /// 审片的顺序。按判决模式 = 网格上看到的（分区 + 筛选）。分组模式不能照抄网格：那里单张收着、
    /// 「只看待处理」还会把定完的场藏掉 —— 连拍挑完按 F，审的要么是空的、要么漏掉全部单张（审查发现）。
    /// 分组模式就按拍摄时间过整场（判决筛选、只看这一章照样生效）。
    private func reviewOrder() -> [String] {
        guard gridMode == .byGroup else { return visibleItems.map(\.id) }
        let items = store.items
        let chapter = store.activeChapterFilter
        let ids = store.takeRows.flatMap { row in
            row.indices.compactMap { idx -> String? in
                guard idx < items.count, items[idx].take == row.take else { return nil }
                let item = items[idx]
                if let filter = store.verdictFilter, item.verdict != filter { return nil }
                if store.clientPickFilter, !store.clientPicks.contains(item.id) { return nil }
                if let chapter, BatchStore.timelineChapter(of: item) != chapter { return nil }
                return item.id
            }
        }
        return ids.isEmpty ? visibleItems.map(\.id) : ids
    }

    /// 进连拍挑选，从这一场开始。focus = 键盘高亮先落在哪张。
    private func pickTake(_ take: Int, focus: String?) {
        guard (store.takeSizes[take] ?? 0) >= 2 else { return }
        pickRequest = .take(take, focus: focus, chapter: store.activeChapterFilter)
    }

    /// 当前范围里有几个多张的场（「只看这一章」开着就只数这一章）—— 本章根本没连拍时别说「挑完了」。
    private var burstTakesInScope: Int {
        guard let chapter = store.activeChapterFilter else { return store.takeStats.takes }
        let items = store.items
        return store.takeRows.reduce(0) { n, row in
            guard row.indices.count >= 2, let first = row.indices.first, first < items.count,
                  BatchStore.timelineChapter(of: items[first]) == chapter else { return n }
            return n + 1
        }
    }

    /// 当前范围里还待处理的场数：「只看这一章」开着就是这一章的（时间轴上那段记着），否则全部。
    private var pendingInScope: Int {
        guard let chapter = store.activeChapterFilter else { return store.pendingTakeCount }
        return store.chapterSegments.first { $0.chapter == chapter }?.pendingTakes ?? 0
    }

    /// 网格焦点正好在这一场里就返回它（进挑选时高亮先落在它上面）。
    private func focus(in members: [BatchItem]) -> String? {
        guard let id = focusedID, members.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// ⌘多选的几张：都在同一场就按整场挑（选中的预先留、其余废），跨场就只挑这几张。
    private func pickSelection() {
        let ids = store.items.filter { selectedIDs.contains($0.id) }.map(\.id)
        if let request = PickRequest.forSelection(ids, store: store) {
            pickRequest = request
        }
    }

    /// 「开始挑选」：焦点所在的场还待处理就从它开始，否则从它后面第一个待处理场开始（到底绕回）。
    private func startPicking() {
        var pending = store.pendingTakes
        let chapter = store.activeChapterFilter
        if let chapter {
            pending = pending.filter { store.members(ofTake: $0).first.map(BatchStore.timelineChapter(of:)) == chapter }
        }
        guard !pending.isEmpty else { return }
        let current = focusedID.flatMap { store.item(withID: $0)?.take } ?? lastVisitedTake ?? -1
        let take = pending.first { $0 >= current } ?? pending[0]
        pickRequest = .take(take, focus: focusedID, chapter: chapter)
    }

    /// C 键：选了 2 张以上挑选中的；焦点在多张场里就挑这一场；都不是就从待处理的开始挑。
    private func pickFromKeyboard() -> Bool {
        if selectedIDs.count >= 2 {
            pickSelection()
            return true
        }
        if let id = focusedID, let item = store.item(withID: id), (store.takeSizes[item.take] ?? 0) >= 2 {
            pickTake(item.take, focus: id)
            return true
        }
        guard pendingInScope > 0 else { return false }
        startPicking()
        return true
    }

    /// Finder-style selection. Plain click focuses one photo and drops any
    /// selection; ⌘ toggles; ⇧ selects the run between the focused photo and
    /// this one in grid order. (Before: once anything was ⌘-selected, EVERY
    /// plain click toggled, and there was no range select at all.)
    private func handleClick(ids: [String], anchorID: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = focusedID {
            let order = visibleItems.map(\.id)
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: anchorID) {
                selectedIDs.formUnion(order[min(a, b)...max(a, b)])
                return
            }
        }
        if flags.contains(.command) {
            if ids.allSatisfy({ selectedIDs.contains($0) }) {
                ids.forEach { selectedIDs.remove($0) }
            } else {
                ids.forEach { selectedIDs.insert($0) }
            }
            return
        }
        selectedIDs.removeAll()
        focusedID = anchorID
    }

    /// Columns currently on screen, from the measured grid width — ↑/↓ moves
    /// focus by one visual row. Approximate across section boundaries, exact
    /// within a section (same adaptive item size everywhere).
    private var gridColumns: Int {
        var contentWidth = gridWidth - 28  // LazyVStack padding 14 × 2
        if gridMode == .byGroup { contentWidth -= 20 }  // takeRow 自己的 padding 10 × 2
        return max(1, Int((contentWidth + 8) / (thumbSize + 8)))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            if store.isRunning {
                Text(store.progressText.isEmpty ? "分析中..." : store.progressText)
                    .foregroundStyle(.secondary)
            } else if let error = store.lastError {
                // The status-bar error is easy to miss; an empty grid is exactly
                // when the user is staring at the middle of the window.
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 480)
                    .multilineTextAlignment(.center)
                Button("重新分析") { store.runAnalysis() }
                    .disabled(store.photoDir == nil)
            } else if let dir = store.photoDir {
                Text("已选择 \(dir.lastPathComponent)，还没有分析结果")
                    .foregroundStyle(.secondary)
                Button("开始分析") { store.runAnalysis() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("还没有分析结果")
                    .foregroundStyle(.secondary)
                Button("选择照片文件夹...") { pickFolder() }
            }
            // 以前这里是一整行密密麻麻的快捷键；现在有快捷键表了，只留两条最有用的入口。
            Text("也可以把照片文件夹从访达直接拖进窗口 · 插上相机存储卡会问要不要导入 · 按 ? 看全部快捷键")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    /// Keeper-rate by focal length / ISO — which gear and settings actually
    /// produce keepers, a byproduct competitors don't surface.
    private var statsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("拍摄复盘 (出片率 = 非废片占比)").font(.headline)
            if store.focalStats.isEmpty && store.isoStats.isEmpty {
                Text("没有 EXIF 数据 (需要重新分析一次)").foregroundStyle(.secondary)
            }
            if !store.focalStats.isEmpty {
                Text("按焦段").font(.caption).foregroundStyle(.secondary)
                ForEach(store.focalStats) { b in
                    HStack {
                        Text(b.label).frame(width: 90, alignment: .leading)
                        ProgressView(value: Double(b.ratePct), total: 100).frame(width: 120)
                        Text("\(b.ratePct)% (\(b.keepers)/\(b.total))").font(.caption).monospacedDigit()
                    }
                }
            }
            if !store.isoStats.isEmpty {
                Text("按 ISO").font(.caption).foregroundStyle(.secondary)
                ForEach(store.isoStats) { b in
                    HStack {
                        Text(b.label).frame(width: 90, alignment: .leading)
                        ProgressView(value: Double(b.ratePct), total: 100).frame(width: 120)
                        Text("\(b.ratePct)% (\(b.keepers)/\(b.total))").font(.caption).monospacedDigit()
                    }
                }
            }
            // VLM calibration: pure counting, no learning — a high release rate
            // means the model's rejects aren't trustworthy on this kind of shoot.
            let vlmSuggested = store.items.filter(\.vlmReject)
            if !vlmSuggested.isEmpty {
                Divider()
                Text("VLM 判断校准").font(.caption).foregroundStyle(.secondary)
                let released = vlmSuggested.filter { $0.verdict != .reject }.count
                Text("VLM 建议淘汰 \(vlmSuggested.count) 张 · 你放行了其中 \(released) 张 (\(released * 100 / vlmSuggested.count)%)")
                    .font(.caption)
                    .foregroundStyle(released * 2 > vlmSuggested.count ? .orange : .primary)
            }
            // 从你的改判反推滑杆：你放行了哪些被这条线判死的，线就该退到哪。
            // 不是机器学习，是算术 —— 但它是"学习你的风格"里诚实能做的那部分。
            if !store.thresholdSuggestions.isEmpty || store.manualRejectsWithoutReason > 0 {
                Divider()
                Text("阈值建议（从你的改判反推）").font(.caption).foregroundStyle(.secondary)
                ForEach(store.thresholdSuggestions) { sug in
                    HStack(spacing: 6) {
                        Text("你放行了 \(sug.released) 张被「\(sug.kind.rawValue)」判死的 → 建议 \(sug.currentText) → \(sug.suggestedText)（能救回 \(sug.rescued)/\(sug.released)）")
                            .font(.caption)
                        Button("应用") { store.applySuggestion(sug) }
                            .controlSize(.small)
                    }
                }
                if store.thresholdSuggestions.contains(where: { $0.kind == .faceQuality }) {
                    Text("人脸质量那条是近似值：小脸按景别自动放宽，连拍组内走相对比较，同一个数对不同照片不是同一条线")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if store.manualRejectsWithoutReason > 0 {
                    Text("你手动废掉了 \(store.manualRejectsWithoutReason) 张滑杆一个理由都没给的 —— 滑杆漏掉的，没有信号说明该收紧哪条线")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            let rescued = store.items.filter { !$0.vlmRescued.isEmpty }.count
            if rescued > 0 {
                Text("复审平反 \(rescued) 张 (算法误杀被 VLM 纠正)")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .padding()
        .frame(minWidth: 320)
    }

    /// 「接受推荐」确认框的标题 / 说明，数是按下按钮那一刻算好的（`acceptPreview`）—— 以前每次重绘都
    /// 重新扫一遍全场。单独成属性：三元 + 插值拼在视图构建器里，Xcode 16 类型检查会超时（同 takeStatusText）。
    private var acceptTitle: String {
        let scope = acceptScope != nil ? "把本章 " : "把 "
        return scope + "\(acceptPreview.takes) 场按推荐定案？"
    }

    /// 「废片移到废纸篓」确认框的说明：客户选中的废片不动，要说出来。
    private var trashMessage: String {
        let kept = store.clientPickRejectCount
        let client = kept > 0 ? "客户选中的 \(kept) 张废片不动 (客户点名要的)。" : ""
        return client + "原图 (RAW+JPG 成对一起) 和 XMP 会移到系统废纸篓，可随时恢复，不是永久删除。"
    }

    private var acceptMessage: String {
        let scope = acceptScope != nil ? "只动这一章。" : ""
        return scope + "每个有精选的待处理场：精选留下，其余可用设为废片。你手动改判过的照片不动。整个操作 ⌘Z 一次撤销。"
    }

    private var groupToolbar: some View {
        let stats = store.takeStats
        let chapter = store.activeChapterFilter
        // 「只看这一章」开着就只算、只动这一章（长场次一章一章过）；否则全场。
        let rec = chapter.map { store.recommendationSummary(inChapter: $0) } ?? store.recommendationSummary
        let bursts = burstTakesInScope
        let decided = max(0, bursts - pendingInScope)
        return HStack(spacing: 10) {
            if pendingInScope > 0 {
                Button { startPicking() } label: {
                    Label("开始挑选 · " + (store.activeChapterFilter != nil ? "本章" : "") + "待处理 \(pendingInScope) 场",
                          systemImage: "rectangle.stack")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("一组一组过 (C)：整组并排上台，点一张 = 只留它，⏎ 确认并跳下一组")
                Text("D 跳到下一场").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Label("没有待处理的连拍", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            }
            Divider().frame(height: 14)
            Toggle("只看待处理", isOn: $pendingTakesOnly)
                .toggleStyle(.button).controlSize(.small)
                .help("只显示还留着 2 张以上没淘汰的场 —— 定完一场它就自动消失。这场共 \(stats.takes) 个多张场、\(stats.photos) 张")
            Toggle("场内按评分", isOn: $takeSortByScore)
                .toggleStyle(.button).controlSize(.small)
                .help("每场里评分高的排前面 (表情 > 人脸质量 > 锐度)；关掉则按拍摄顺序。缩略图上的 #1 #2 #3 是同一把尺子")
            if bursts > 0 {
                Divider().frame(height: 14)
                // 进度：这一轮（全场 / 本章）多张连拍定了几场。
                ProgressView(value: Double(decided), total: Double(bursts))
                    .frame(width: 70)
                Text("已定 \(decided)/\(bursts) 场").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help((chapter != nil ? "这一章" : "这场拍摄") + "里 \(bursts) 个多张连拍，定完 \(decided) 个")
            }
            Spacer()
            Button((chapter != nil ? "本章接受推荐" : "全部接受推荐")
                   + (rec.takes > 0 ? " (\(rec.takes) 场 · \(rec.rejects) 张废片)" : "")) {
                acceptScope = chapter
                acceptPreview = rec
                showAcceptAllConfirm = true
            }
            .controlSize(.small)
            .disabled(rec.takes == 0)
            .help((chapter != nil ? "只动这一章：" : "") +
                  "一键接受算法的推荐：每个有精选的待处理场，精选留下、其余可用设为废片。你手动标过可用的不动。⌘Z 一次全部撤销")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            Text("已选 \(selectedIDs.count) 张 → 批量改判:")
            ForEach(Verdict.allCases.reversed(), id: \.self) { v in
                Button(v.rawValue) {
                    withAnimation { store.setOverrideBatch(selectedIDs, v) }
                    selectedIDs.removeAll()
                }
                .buttonStyle(.bordered)
            }
            Button("恢复自动") {
                withAnimation { store.setOverrideBatch(selectedIDs, nil) }
                selectedIDs.removeAll()
            }
            .buttonStyle(.bordered)
            let groupCandidates = selectionGroupMembers
            // 选中的照片可能落在候选集之外 (单张组)，不能拿总数相减。
            let dropCount = groupCandidates.filter { !selectedIDs.contains($0) }.count
            if dropCount > 0 {
                Divider().frame(height: 16)
                Button("保留选中 · 其余 \(dropCount) 张设为废片") {
                    withAnimation {
                        store.keepOnly(selectedIDs, among: groupCandidates)
                    }
                    selectedIDs.removeAll()
                }
                .buttonStyle(.borderedProminent)
                // ⌘⏎ 而不是光秃秃的 ⏎：网格自己用 .onKeyPress(.return) 开大图，
                // 而按钮的 key equivalent 在 keyDown 之前就被吃掉 —— 只要选中了
                // 照片，想按回车看大图就会变成"整组定案"。
                .keyboardShortcut(.return, modifiers: .command)
                .help("把选中这几张定为精选，它们所在的场里其余 \(dropCount) 张全部设为废片 (⌘⏎)。" +
                      "整场算一次改判，⌘Z 一次撤销。可以跨多场：每场各挑一张，一次定案。")
            }
            // 不卡张数：一屏摆不下的，连拍挑选会改成单行左右滚动。
            if selectedIDs.count >= 2 {
                Divider().frame(height: 16)
                Button("挑选这 \(selectedIDs.count) 张 (C)") { pickSelection() }
                    .buttonStyle(.bordered)
                    .help("进连拍挑选。选中的都在同一场 = 整场挑（选中的先留、其余废，⏎ 确认）；" +
                          "跨场 = 把这几张并排比，点一张只留它")
            }
            alignButton
            Button("拼图 (\(selectedIDs.count))") {
                // 按网格里的顺序递过去（Set 没有顺序）。
                let order = store.items.map(\.id).filter { selectedIDs.contains($0) }
                store.collageRequest = order
            }
            .buttonStyle(.bordered)
            .help("把选中的照片带到「拼图」页，直接排一版（按人脸裁切、主图最大）")
            Spacer()
            Button("取消选择") { selectedIDs.removeAll() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 选了两台机身各一张：「把这两张对成同一时刻」，以照片多的那台为准调另一台的偏移（⌘Z 撤销）。
    @ViewBuilder private var alignButton: some View {
        let ids = Array(selectedIDs)
        if ids.count == 2, let align = store.alignment(ids[0], ids[1]) {
            let shift = BodyClock.formatOffset(align.offset)
            Divider().frame(height: 16)
            Button("把这两张对成同一时刻") {
                withAnimation { store.setBodyOffsets([align.moved.key: align.offset]) }
                selectedIDs.removeAll()
            }
            .buttonStyle(.bordered)
            .help("两台机身同一瞬间拍的这两张（同一次闪光、同一个动作）：以「\(align.reference.name)」为准，「\(align.moved.name)」整台的对时偏移设成 \(shift)，排序、分场、章节跟着重排。⌘Z 撤销，状态栏「N 台机身」里可以再改")
        }
    }

    // MARK: - Chapter timeline (跨章节导航 + 覆盖保护可视化，见 ChapterTimeline.swift)

    /// 「只看这一章」开 / 关。开的时候焦点和滚动落到那一章第一张；关的时候留在原来那张上。
    private func setChapterFilter(_ chapter: Int?, proxy: ScrollViewProxy) {
        let keep = focusedID
        store.chapterFilter = chapter
        selectedIDs.removeAll()
        DispatchQueue.main.async {
            let items = visibleItems
            let target = (chapter == nil ? keep.flatMap { id in items.first { $0.id == id } } : nil) ?? items.first
            if let target {
                focusedID = target.id
                proxy.scrollTo(target.id, anchor: .center)
            }
        }
    }

    /// 时间轴下面那一条：现在只看哪一章、怎么换、怎么回到全部。
    private func chapterFilterBar(_ segment: BatchStore.ChapterSegment, proxy: ScrollViewProxy) -> some View {
        let day = segment.start.map { ChapterTimelineLayout.dayText($0) + " " } ?? ""
        let title = segment.undated ? "无拍摄时间的照片" : "章节 \(segment.chapter + 1) · \(day)\(segment.timeRange)"
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
            Text("只看 \(title) · \(segment.count) 张").font(.caption.bold()).monospacedDigit()
            Text("[ ] 换到上一章 / 下一章 · 点时间轴别的段直接换").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("显示全部章节") { setChapterFilter(nil, proxy: proxy) }
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [.shift])
                .help("回到全部章节 (⇧Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.14))
    }

    /// 时间轴点了一段：焦点落到当前视图里这一章的第一张。返回 false = 这一章在当前视图
    /// 里一张都没有（判决筛选 / 只看待处理 / 单张收起了），时间轴的卡片会说明原因。
    private func jumpToChapter(_ segment: BatchStore.ChapterSegment, proxy: ScrollViewProxy) -> Bool {
        // 「只看这一章」开着：点别的章 = 换成只看那一章（不然它被筛掉了，跳不过去）。
        if let active = store.activeChapterFilter, active != segment.chapter {
            store.chapterFilter = segment.chapter
            focusedID = nil
            DispatchQueue.main.async {
                if let first = visibleItems.first {
                    focusedID = first.id
                    proxy.scrollTo(first.id, anchor: .center)
                }
            }
            return true
        }
        let inChapter: (BatchItem) -> Bool = { BatchStore.timelineChapter(of: $0) == segment.chapter }
        if let target = visibleItems.first(where: inChapter) {
            focusedID = target.id
            // 居中：贴顶会被吸顶的分区标题 / 场标题挡住。
            withAnimation { proxy.scrollTo(target.id, anchor: .center) }
            return true
        }
        // 分组模式下这一章只有单张、单张区又收着：展开再跳（等网格铺出来那一拍）。
        guard gridMode == .byGroup, !showSingles, let target = singleItems.first(where: inChapter) else { return false }
        showSingles = true
        focusedID = target.id
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target.id, anchor: .center) }
        }
        return true
    }

    /// 数字键改判后，这张在网格里挪了位置（按判决分区时跳到别的区、被筛选或叠放藏掉）：焦点落到原来
    /// 紧挨着它的下一张（没有就上一张）。不然 ←/→ 会从它的新位置（比如最底下的废片区）接着走，
    /// 刚才看到哪儿就丢了。还在原来两个邻居之间就不动。
    private func keepPlace(of id: String, before: [String], proxy: ScrollViewProxy) {
        guard let next = Self.placeAfterChange(of: id, before: before, after: visibleItems.map(\.id)) else { return }
        focusedID = next
        // 等网格按新判决重新铺一拍再滚：整场叠起来时立刻滚，目标位置还是旧的。
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(next, anchor: .center) } }
    }

    /// keepPlace 的判断（纯函数，`--ux-selftest` 直接测）：nil = 这张还在原来两个邻居之间，不用动；
    /// 否则返回改判前紧跟在它后面、现在还看得见的那张（后面没有就往前找）。
    static func placeAfterChange(of id: String, before: [String], after: [String]) -> String? {
        guard let old = before.firstIndex(of: id) else { return nil }
        let visible = Set(after)
        if let new = after.firstIndex(of: id) {
            // 「没挪」= 在两边都还在的照片里，它前后还是原来那两张。只看紧挨着的邻居不行：同一场里别的
            // 照片被叠掉 / 展开出来，紧挨着的邻居变了，可它其实没动（审查发现）。
            let earlier = Set(before)
            let prevBefore = before[..<old].last { visible.contains($0) }
            let nextBefore = before[(old + 1)...].first { visible.contains($0) }
            let prevAfter = after[..<new].last { earlier.contains($0) }
            let nextAfter = after[(new + 1)...].first { earlier.contains($0) }
            if prevBefore == prevAfter && nextBefore == nextAfter { return nil }
        }
        let candidates = Array(before[(old + 1)...]) + Array(before[..<old].reversed())
        return candidates.first { $0 != id && visible.contains($0) }
    }

    /// [ / ]：从焦点那张所在的章节往前 / 往后跳一章；那一章在当前视图里一张都没有就接着往下找。
    private func jumpChapter(_ delta: Int, proxy: ScrollViewProxy) {
        let segments = store.chapterSegments
        guard !segments.isEmpty else { return }
        // 「只看这一章」开着：[ ] 直接换成上一章 / 下一章（Narrative 的 ←/→ 换场景）。
        if let active = store.activeChapterFilter, let idx = segments.firstIndex(where: { $0.chapter == active }) {
            let next = idx + delta
            guard segments.indices.contains(next) else { return }
            _ = jumpToChapter(segments[next], proxy: proxy)
            return
        }
        let current = focusedID.flatMap { store.item(withID: $0) }.map(BatchStore.timelineChapter(of:))
        var index = current.flatMap { c in segments.firstIndex { $0.chapter == c } }
            ?? (delta > 0 ? -1 : segments.count)
        while true {
            index += delta
            guard segments.indices.contains(index) else { return }
            if jumpToChapter(segments[index], proxy: proxy) { return }
        }
    }

    private func moveFocus(_ delta: Int, proxy: ScrollViewProxy) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let ids = items.map(\.id)
        let next: String
        if let current = focusedID, let idx = ids.firstIndex(of: current) {
            next = ids[max(0, min(ids.count - 1, idx + delta))]
        } else {
            next = ids[0]
        }
        focusedID = next
        // 单步 ←/→ 用最小滚动（不跳行）；按列跨行的 ↑/↓ 居中，别停在吸顶标题底下。
        proxy.scrollTo(next, anchor: abs(delta) > 1 ? .center : nil)
    }

    /// ↑/↓。按判决模式按估算的列数跳一行；分组模式每场一行、行内自适应换行，
    /// 先在本场内按列跳，跳出本场就落到相邻场的第一张 / 最后一张 —— 不会像
    /// 全局按列数跳那样从一场中间莫名其妙落进下一场中间。
    private func moveFocusVertically(_ direction: Int, proxy: ScrollViewProxy) {
        guard gridMode == .byGroup else {
            moveFocus(direction * gridColumns, proxy: proxy)
            return
        }
        // 单张区展开时当作最后一「行」：从最后一场按 ↓ 能走进去。
        let singles = showSingles ? singleItems : []
        let rows = groupedItems + (singles.isEmpty ? [] : [(group: -1, members: singles)])
        guard !rows.isEmpty else { return }
        guard let current = focusedID,
              let rowIdx = rows.firstIndex(where: { $0.members.contains { $0.id == current } }),
              let col = rows[rowIdx].members.firstIndex(where: { $0.id == current }) else {
            focusedID = rows[0].members.first?.id
            if let id = focusedID { proxy.scrollTo(id, anchor: .center) }
            return
        }
        let row = rows[rowIdx].members
        let inRow = col + direction * gridColumns
        let next: String
        if row.indices.contains(inRow) {
            next = row[inRow].id
        } else {
            let adjacent = rowIdx + direction
            guard rows.indices.contains(adjacent) else { return }
            next = direction > 0 ? rows[adjacent].members[0].id : rows[adjacent].members.last!.id
        }
        focusedID = next
        // 吸顶的分区标题会盖住贴着顶边停下的目标；跨行跳转一律居中。
        proxy.scrollTo(next, anchor: .center)
    }

    private func openFocused() {
        if let id = focusedID { openInspector(id) }
    }

    /// D：跳到下一个还没定的场（Aftershoot 过重复组的节奏：定完一组，一键下一组）。
    /// 按**场号**找"比当前场晚的第一个待处理"，不按行下标：开着「只看待处理」时，
    /// 定完一场那行立刻消失，焦点那张不在任何行里，按下标找会跳回第一行。
    /// 场号按时间递增，所以"比当前场号大"就是"后面的"。到底了绕回开头。
    private func jumpToNextPendingTake(_ proxy: ScrollViewProxy) {
        if gridMode != .byGroup { gridMode = .byGroup }
        let rows = groupedItems
        let pending = rows.filter { row in
            store.isPendingTake(alive: row.members.filter { $0.verdict != .reject })
        }
        guard !pending.isEmpty else { return }
        let currentTake = focusedID.flatMap { store.item(withID: $0)?.take } ?? lastVisitedTake ?? -1
        let next = pending.first { $0.group > currentTake } ?? pending[0]
        let target = next.members.first { $0.verdict != .reject } ?? next.members[0]
        lastVisitedTake = next.group
        selectedIDs.removeAll()
        focusedID = target.id
        withAnimation { proxy.scrollTo(target.id, anchor: .top) }
    }

    // MARK: 按分组 (每个多张场一行，单张收在最后)

    /// 每个多张场一行，本场全部照片横向铺开（放不下自动换行）。单张照片（没有连拍、不用挑）
    /// 收进最后的折叠区 —— 以前它们也一张一行，一场婚礼里多半是单张，要挑的连拍被冲散。
    /// 鼠标停在照片上点「只留这张」就是定案；要一组一组细看按 C 进连拍挑选。
    private var groupGrid: some View {
        let singles = singleItems
        return LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(groupedItems, id: \.group) { entry in
                takeRow(entry.group, members: entry.members)
            }
            if !singles.isEmpty {
                singlesSection(singles)
            }
        }
    }

    private static let takeTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    @ViewBuilder
    private func takeRow(_ take: Int, members: [BatchItem]) -> some View {
        // members 可能被判决筛选过 / 叠起来过；定案要作用在整场上，所以另取全部成员。
        let all = store.members(ofTake: take)
        let alive = all.filter { $0.verdict != .reject }
        let picks = all.filter { $0.verdict == .pick }
        let pending = store.isPendingTake(alive: alive)
        // 这一行被叠起来藏掉的废片张数（判决筛选、只看客户选中藏掉的不算 —— 那是你自己要的）。
        let unfiltered = store.verdictFilter == nil && !store.clientPickFilter
        let folded = unfiltered ? all.count - members.count : 0
        let allSelected = members.allSatisfy { selectedIDs.contains($0.id) }
        let recommended = pending ? store.recommendedDecision(for: all) : [:]
        let recRejects = alive.filter { recommended[$0.id] == .reject }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // 点标题 = 选中整场（再点取消），批量栏随即出现。
                Button {
                    if allSelected {
                        members.forEach { selectedIDs.remove($0.id) }
                    } else {
                        members.forEach { selectedIDs.insert($0.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(allSelected ? Color.accentColor : .secondary)
                        Text("场 \(take)").font(.subheadline.bold())
                        Text("\(all.count) 张").font(.caption).foregroundStyle(.secondary)
                        if let range = Self.timeRange(all) {
                            Text(range).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(allSelected ? "取消选中这一场" : "选中这一场的全部 \(members.count) 张")

                let pillColor: Color = pending ? .orange : .green
                Text(Self.takeStatusText(pending: pending, alive: alive.count, picks: picks.count))
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(pillColor.opacity(pending ? 0.25 : 0.2), in: Capsule())
                    .foregroundStyle(pillColor)
                if folded > 0 {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { _ = expandedTakes.insert(take) }
                    } label: {
                        Label("显示被废的 \(folded) 张", systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                    .help("这一场定完了，被废的照片叠起来了。点开再看一遍")
                } else if !pending, unfiltered, expandedTakes.contains(take), alive.count < all.count {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { _ = expandedTakes.remove(take) }
                    } label: {
                        Label("收起废片", systemImage: "rectangle.compress.vertical")
                    }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                // 一键接受算法的推荐：精选留、你标过可用的留，其余废。快速过场用的。
                if pending {
                    Button(recRejects > 0 ? "接受推荐 · 废 \(recRejects) 张" : "接受推荐") {
                        withAnimation { store.applyOverrides(recommended, accepted: true) }
                        // 定完这一场会叠起来：焦点落到留下的那张上，别停在被叠掉的照片上（←/→ 会从头开始）。
                        if let keep = all.first(where: { recommended[$0.id] == .pick }) { focusedID = keep.id }
                    }
                    .controlSize(.small)
                    .help(Self.acceptHelp(picks: picks.map(\.id), rejects: recRejects))
                }
                Button(pending ? "挑选" : "复查") { pickTake(take, focus: focus(in: members)) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("整场并排上台细挑 (焦点在本场时按 C 也行)：点一张 = 只留它，⏎ 确认并跳下一组")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(members) { member in
                    // groupSize 1：行头已经写了张数，缩略图上再贴 ×N 就重复了。
                    let soleKeeper = member.verdict != .reject && alive.count == 1
                    CellHoverBar(id: member.id, verdict: member.verdict,
                                 keepOnly: soleKeeper ? nil : {
                                     withAnimation { keepOnly(member.id, inTake: all) }
                                     focusedID = member.id
                                 },
                                 compact: thumbSize < 150,
                                 onSet: { v in setFromHover(member.id, v) }) {
                        thumbnailCell(member, color: member.verdict.color, groupSize: 1)
                    }
                    .id(member.id)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(pending ? Color.white.opacity(0.04) : Color.clear)
        )
        // 待处理的场左边一条橙线 —— 比 4% 的白底醒目得多，又不和照片争颜色。
        .overlay(alignment: .leading) {
            if pending {
                RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.8)).frame(width: 3).padding(.vertical, 8)
            }
        }
    }

    /// 行头状态 pill 的字。单独一个函数：嵌套三元 + 插值在视图构建器里类型检查要 20ms，CI 的 Xcode 16 更慢。
    private static func takeStatusText(pending: Bool, alive: Int, picks: Int) -> String {
        if pending { return "待处理 · \(alive) 张没淘汰" }
        return picks == 0 ? "已定" : "已定 · 精选 \(picks)"
    }

    /// 行头「接受推荐」的说明。单独拼：放在视图构建器里一长串 + 连接，CI 的 Xcode 16 类型检查会超时。
    private static func acceptHelp(picks: [String], rejects: Int) -> String {
        let keep = "留下本场现在的精选（\(picks.joined(separator: "、"))）和你标过可用的，"
        let rest = rejects > 0 ? "其余 \(rejects) 张设为废片。" : "这一场就算定了。"
        return keep + rest + "整场一次改判，⌘Z 一次撤销"
    }

    /// 缩略图悬停条上的 ★ / ● / ✕：只改这一张。已经是这个**人工**判决就不重复写一条撤销记录；
    /// 自动判的点亮着的那个，等于把它钉成人工判决（以后拧滑杆不再跟着动），记一步撤销。
    /// 改的是焦点那张：和数字键一样焦点留在原位（`placeAfterChange`），不然按判决分区时它跳去废片区，
    /// ←/→ 从那儿接着走。不滚动 —— 鼠标就停在这儿。
    private func setFromHover(_ id: String, _ verdict: Verdict) {
        guard store.item(withID: id)?.verdict != verdict || store.overrides[id] != verdict else { return }
        let before = id == focusedID ? visibleItems.map(\.id) : nil
        withAnimation(.easeInOut(duration: 0.2)) { store.setOverrideBatch([id], verdict) }
        if let before, let next = Self.placeAfterChange(of: id, before: before, after: visibleItems.map(\.id)) {
            focusedID = next
        }
    }

    /// 「只留这张」：它精选，本场其余全部废片（整场一条撤销记录）。
    private func keepOnly(_ id: String, inTake members: [BatchItem]) {
        store.applyOverrides(Dictionary(members.map { ($0.id, $0.id == id ? Verdict.pick : .reject) },
                                        uniquingKeysWith: { first, _ in first }))
    }

    /// 单张照片的折叠区。
    private func singlesSection(_ singles: [BatchItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showSingles.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSingles ? "chevron.down" : "chevron.right")
                        .font(.caption.bold()).frame(width: 12)
                    Text("单张 \(singles.count)").font(.subheadline.bold())
                    Text("没有连拍、不用挑，收在这里免得把要挑的连拍冲散").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showSingles ? "收起单张" : "展开看这 \(singles.count) 张单张照片")
            if showSingles {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(singles) { item in
                        CellHoverBar(id: item.id, verdict: item.verdict, keepOnly: nil, onSet: { v in setFromHover(item.id, v) }) {
                            thumbnailCell(item, color: item.verdict.color, groupSize: 1)
                        }
                        .id(item.id)
                    }
                }
            }
        }
        .padding(10)
    }

    static func timeRange(_ members: [BatchItem]) -> String? {
        let times = members.compactMap(\.captureTime)
        guard let first = times.min(), let last = times.max() else { return nil }
        let a = takeTimeFormatter.string(from: first)
        return first == last ? a : "\(a)–\(takeTimeFormatter.string(from: last))"
    }

    /// 两条角标各一个 tooltip，代替以前每个小图标各挂一个（一格 8 个 .help）。
    static func statusHelp(rank: Int?, manual: Bool, client: Bool, pick: Bool, groupSize: Int) -> String {
        var parts: [String] = []
        if let rank { parts.append("本场评分第 \(rank)") }
        if manual { parts.append("人工改判") }
        if client { parts.append("客户选中") }
        if pick { parts.append("精选") }
        if groupSize > 1 { parts.append("同场 \(groupSize) 张") }
        return parts.joined(separator: " · ")
    }

    static func infoHelp(_ item: BatchItem, closed: Int) -> String {
        var parts: [String] = item.rejectReasons
        if !item.vlmRescued.isEmpty { parts.append("VLM 平反: " + item.vlmRescued.joined(separator: "、")) }
        if item.slowShutter { parts.append("快门低于安全快门 (1/焦距)，易糊") }
        if item.tilted { parts.append(String(format: "水平线倾斜 %.1f°", item.horizonDeg ?? 0)) }
        if closed > 0 { parts.append("\(item.faces.count) 张脸里 \(closed) 张闭眼") }
        else if closed == 0 { parts.append("\(item.faces.count) 张脸全部睁眼") }
        return parts.joined(separator: " · ")
    }

    /// Reject reasons as compact icon badges — the text version wrapped and
    /// cluttered the grid. Full text lives in the tooltip and the inspector.
    static func reasonIcon(_ reason: String) -> String {
        if reason.contains("连拍重复") { return "square.stack.3d.down.right" }
        if reason.contains("闭眼") { return "eye.slash" }
        if reason.contains("虚焦") { return "minus.magnifyingglass" }
        if reason.contains("欠曝") { return "sun.min.fill" }
        if reason.contains("过曝") { return "sun.max.circle.fill" }
        if reason.contains("曝光") { return "sun.max.fill" }
        if reason.contains("人脸质量") { return "person.crop.circle.badge.exclamationmark" }
        if reason.contains("VLM") { return "sparkles" }
        return "exclamationmark.triangle"
    }

    /// Items of one verdict section, narrowed by the borderline filter and (for
    /// rejects) the active reason filter. Shared with keyboard navigation.
    private func sectionItems(_ verdict: Verdict) -> [BatchItem] {
        // 分区下标在 Derived 里；这里只对本分区做筛选（以前每个分区各扫一遍全部）。
        let items = store.items
        var matching = (store.byVerdict[verdict] ?? []).compactMap { idx -> BatchItem? in
            guard idx < items.count, items[idx].verdict == verdict else { return nil }
            return items[idx]
        }
        if store.borderlineFilter {
            matching = matching.filter { store.isBorderline($0) }
        }
        if store.clientPickFilter {
            matching = matching.filter { store.clientPicks.contains($0.id) }
        }
        if let chapter = store.activeChapterFilter {
            matching = matching.filter { BatchStore.timelineChapter(of: $0) == chapter }
        }
        if verdict == .reject, let reason = store.reasonFilter {
            matching = matching.filter { $0.rejectReasons.contains(reason) }
        }
        return matching
    }

    @ViewBuilder
    private func verdictSection(_ verdict: Verdict, color: Color) -> some View {
        let matching = sectionItems(verdict)
        let takeSizes = store.takeSizes
        if !matching.isEmpty || (verdict == .reject && store.reasonFilter != nil) {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)], spacing: 8) {
                    ForEach(matching) { item in
                        CellHoverBar(id: item.id, verdict: item.verdict, keepOnly: nil, onSet: { v in setFromHover(item.id, v) }) {
                            thumbnailCell(item, color: color, groupSize: takeSizes[item.take] ?? 1)
                        }
                        .id(item.id)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: verdict.symbol).font(.caption.bold()).foregroundStyle(color)
                    Text(verdict.rawValue).font(.headline)
                    Text("\(matching.count)").font(.headline).foregroundStyle(.secondary)
                    if verdict == .reject {
                        reasonChips
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                // 吸顶时要盖住下面滚过的缩略图。
                .background(Color(white: 0.13))
            }
        }
    }

    /// Per-reason kill counts as clickable filter chips — "audit all 闭眼 kills
    /// in one pass" instead of scanning badges thumbnail by thumbnail.
    private var reasonChips: some View {
        let counts = store.reasonCounts
        return HStack(spacing: 4) {
            ForEach(BatchStore.reasonOrder.filter { counts[$0] != nil }, id: \.self) { reason in
                let active = store.reasonFilter == reason
                Button {
                    store.reasonFilter = active ? nil : reason
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: Self.reasonIcon(reason)).font(.caption2)
                        Text("\(reason) \(counts[reason]!)").font(.caption)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(active ? Color.red.opacity(0.35) : Color.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(active ? Color.red : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(active ? "点击取消筛选" : "只看因「\(reason)」被标记的照片")
            }
        }
    }

    @ViewBuilder
    private func thumbnailCell(_ item: BatchItem, color: Color, groupSize: Int) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        let isFocused = focusedID == item.id
        VStack(spacing: 3) {
            // 方格 + 整图 fit（Lightroom / Aftershoot 的做法）。以前是 .fill 塞进
            // 140×100 的横框：一张竖拍只剩中间一条，52% 的画面被裁掉，看不到脚也
            // 看不到构图 —— 而这类场次全是竖拍。
            ThumbnailView(path: item.previewPath, fit: true)
                .frame(maxWidth: .infinity, minHeight: thumbSize, maxHeight: thumbSize)
                .background(Color(white: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // 焦点和选中分开：以前都是 3px accent，⌘多选之后分不清焦点在哪，
                // 而数字键在没有选中时判的正是焦点那张。选中 = accent 粗框 + 左上 ✓，
                // 焦点 = 白色细框，两者可以同时出现。
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3)
                    }
                    if isFocused {
                        RoundedRectangle(cornerRadius: 5).inset(by: isSelected ? 3 : 0)
                            .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    }
                }
                // 右上一条：状态（排名 · 手判 · ★精选 · ×N）。精选统一用绿星（和判决
                // 小点、审片头部同一个符号同一个色），排名只用灰度 —— 以前四个角各挂
                // 一坨、精选绿圆和 #1 黄字打架，代码里自己写着"别弄成圣诞树"。
                .overlay(alignment: .topTrailing) {
                    let rank = store.takeRank[item.id]
                    let manual = store.isManual(item.id)
                    let client = store.clientPicks.contains(item.id)
                    let hasStatus: Bool = rank != nil || manual || client || item.verdict == .pick || groupSize > 1
                    if hasStatus {
                        HStack(spacing: 4) {
                            if let rank {
                                Text("#\(rank)").font(.caption2).bold().monospacedDigit()
                                    .foregroundStyle(rank == 1 ? Color.white : Color.white.opacity(0.6))
                            }
                            if manual { Image(systemName: "hand.raised.fill").font(.caption2) }
                            // 客户选中：紫心（和确认表上客户点的那颗、XMP 的紫色标同一个颜色）。
                            if client { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.purple) }
                            if item.verdict == .pick {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Verdict.pick.color)
                            }
                            if groupSize > 1 { Text("×\(groupSize)").font(.caption2).bold() }
                        }
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                        .help(Self.statusHelp(rank: rank, manual: manual, client: client,
                                              pick: item.verdict == .pick, groupSize: groupSize))
                    }
                }
                // 左下一条：信息（淘汰理由 · VLM 平反 · 慢门 · 水平 · 合影睁眼）。
                .overlay(alignment: .bottomLeading) {
                    let closed = item.faces.count >= 2 ? item.faces.filter { $0.eyeClosed == true }.count : -1
                    let hasInfo = !item.rejectReasons.isEmpty || !item.vlmRescued.isEmpty
                        || item.slowShutter || item.tilted || closed >= 0
                    if hasInfo {
                        HStack(spacing: 4) {
                            ForEach(item.rejectReasons, id: \.self) { reason in
                                Image(systemName: Self.reasonIcon(reason)).font(.caption2).foregroundStyle(.red)
                            }
                            if !item.vlmRescued.isEmpty {
                                Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green)
                            }
                            if item.slowShutter { Image(systemName: "tortoise.fill").font(.caption2).foregroundStyle(.yellow) }
                            if item.tilted { Image(systemName: "level").font(.caption2).foregroundStyle(.yellow) }
                            if closed >= 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: closed > 0 ? "eye.slash" : "eye").font(.caption2)
                                    Text("\(item.faces.count - closed)/\(item.faces.count)").font(.caption2).monospacedDigit()
                                }
                                .foregroundStyle(closed > 0 ? .red : .green)
                            }
                        }
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                        .help(Self.infoHelp(item, closed: closed))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(.white))
                            .padding(4)
                    }
                }
            HStack(spacing: 4) {
                Image(systemName: item.verdict.symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 8)
                Text(item.id).font(.caption2).lineLimit(1)
                    .foregroundStyle(.secondary)
                if let iso = item.exif?.iso {
                    // Orange from ISO 3200 up — the range worth batch-denoising.
                    Text("ISO \(iso)").font(.caption2).monospacedDigit().lineLimit(1)
                        .foregroundStyle(iso >= 3200 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                }
            }
        }
        .contentShape(Rectangle())
        // 时间轴的「你在这」：只记出现/消失，不在这里读任何会触发重绘的状态。
        .onAppear { viewport.appeared(item.id, chapter: BatchStore.timelineChapter(of: item)) }
        .onDisappear { viewport.disappeared(item.id) }
        .onChange(of: BatchStore.timelineChapter(of: item)) { _, chapter in viewport.update(item.id, chapter: chapter) }
        // gesture + simultaneousGesture instead of two onTapGestures: the latter
        // makes SwiftUI hold every single click ~300ms to rule out a double —
        // that was the visible lag on selection. Simultaneous recognition fires
        // the single click instantly; during a double-click the first click just
        // sets focus (harmless) and the second opens the inspector.
        // 双击的第二下不再算一次单击：⌘ 双击不会选上又取消；点完悬停按钮照片挪了位，手快补的
        // 第二下落在新补上来的照片上，也不会把焦点和多选带走。
        .gesture(TapGesture(count: 2).onEnded { openInspector(item.id) })
        .simultaneousGesture(TapGesture().onEnded {
            guard !ClickGuard.isRepeatClick else { return }
            handleClick(ids: [item.id], anchorID: item.id)
        })
    }

    // MARK: - Right: controls

    // MARK: - Right panel: thresholds + VLM only. Everything else lives in the
    // top bar / export menu; explanations live in .help tooltips, not captions.

    /// 「同一场最大间隔」滑杆 + 按快门节奏直方图。
    ///
    /// 这是整个分组的主刻度：之前分组靠 phash 汉明距离≤10 把"同一场"切碎成
    /// 一对一对（photot 实测最大组只有 2 张），堆栈界面因此根本没东西可堆。
    /// 现在按拍摄时间切场，间隔交给用户拧 —— 宴会抓拍和影棚摆拍的节奏差一个
    /// 数量级，没有哪个固定值是对的。
    @ViewBuilder
    private var takeGapRow: some View {
        let stats = store.takeStats
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("同一场最大间隔").font(.callout)
                Spacer()
                Text("\(stats.takes) 场多张").font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("\(Int(store.takeGapSec)) 秒").font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            MetricHistogram(
                bins: store.captureGapBins,
                range: BatchStore.captureGapHistRange,
                threshold: store.takeGapSec,
                killBelow: true,
                sqrtScale: true,
                markColor: .green
            )
            Slider(value: $store.takeGapSec, in: 1...60, step: 1)
            Text("绿色 = 会并进同一场的间隔。只改怎么分堆，不改任何判决。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .help("相邻两张间隔超过这个秒数就算换了一场。直方图是本场拍摄的按快门节奏分布," +
              "白线就是当前这条线。双机位按机身各切各的 —— 两台机器同一秒各拍一张是" +
              "两个角度,不是重复。")
    }

    /// 连拍去重开关。分组本来只用来"提名"最佳的那张，组内其余照片原封不动留在
    /// 可用里 —— 一组 8 张全清晰全睁眼时等于没去重。这是规则，不写 overrides：
    /// 关掉开关整组立刻全部回来。
    @ViewBuilder
    private var burstDedupeRow: some View {
        let stats = store.burstGroupStats
        VStack(alignment: .leading, spacing: 2) {
            Toggle("近似重复只留最佳 (\(store.reasonCounts["连拍重复"] ?? 0))",
                   isOn: $store.rejectBurstDuplicates)
                .font(.caption)
                .help("只作用在「几乎同一张」这一层 (2秒内 + phash 汉明距离≤10)，不是整场。" +
                      "场里人在动、表情在变，哪张好是审美判断，交给你在堆栈里勾选。" +
                      "这是可随时关掉的规则，不会覆盖你手动改判过的照片。" +
                      "本场共 \(stats.groups) 组近似重复、\(stats.photos) 张候选")
                .disabled(stats.groups == 0)
            Text(stats.groups > 0
                 ? "\(stats.groups) 组近似重复 · \(stats.photos) 张（和上面的「场」是两层）"
                 : "本场没有近似重复的照片")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("筛选严格度") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("预设", selection: Binding(
                            get: { store.currentPreset },
                            set: { if let p = $0 { store.applyPreset(p) } }
                        )) {
                            ForEach(BatchStore.CullPreset.allCases, id: \.self) { p in
                                Text(p.rawValue).tag(BatchStore.CullPreset?.some(p))
                            }
                            Text("自定义").tag(BatchStore.CullPreset?.none)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        let reasonCounts = store.reasonCounts
                        thresholdSlider(
                            label: "锐度下限",
                            value: "\(Int(store.sharpnessThreshold))",
                            killCount: reasonCounts["虚焦"] ?? 0,
                            slider: Slider(value: $store.sharpnessThreshold, in: 0...150, step: 5),
                            help: "五官区域梯度锐度，低于此值判为虚焦 → 废片。清晰照片约 65-95。直方图 = 本场分布，红色 = 会被此线淘汰",
                            histogram: MetricHistogram(
                                bins: store.sharpnessBins,
                                range: BatchStore.sharpnessHistRange,
                                threshold: store.sharpnessThreshold,
                                killBelow: true
                            )
                        )
                        thresholdSlider(
                            label: "曝光裁切上限",
                            value: String(format: "%.1f%%", store.exposureThreshold * 100),
                            killCount: reasonCounts["曝光裁切"] ?? 0,
                            slider: Slider(value: $store.exposureThreshold, in: 0.005...0.5),
                            help: "死白/死黑像素占比超过此值 → 废片。直方图为开方刻度 (大多数照片裁切接近 0)",
                            histogram: MetricHistogram(
                                bins: store.exposureBins,
                                range: BatchStore.exposureHistRange,
                                threshold: store.exposureThreshold,
                                killBelow: false,
                                sqrtScale: true
                            )
                        )
                        thresholdSlider(
                            label: "人脸质量下限",
                            value: store.faceQualityThreshold > 0
                                ? String(format: "%.2f", store.faceQualityThreshold) : "关闭",
                            killCount: reasonCounts["人脸质量低"] ?? 0,
                            slider: Slider(value: $store.faceQualityThreshold, in: 0...1),
                            help: "特写脸的质量下限;小脸按景别自动放宽，连拍组内改为组内相对比较 (不看此线)。直方图只画单张照片的分布。拉到 0 关闭",
                            histogram: MetricHistogram(
                                // Only photos the absolute line actually
                                // applies to; burst frames are judged
                                // group-relative and were misleading here.
                                bins: store.faceQualityBins,
                                range: BatchStore.faceQualityHistRange,
                                threshold: store.faceQualityThreshold,
                                killBelow: true
                            )
                        )
                        takeGapRow
                        burstDedupeRow
                        Toggle("只看临界照片 (\(store.borderlineCount))", isOn: $store.borderlineFilter)
                            .font(.caption)
                            .help("任一阈值 ±15% 区间内的照片 — 调完滑杆先过一眼刀口上的这些，误杀都藏在这里")
                        Stepper("每章节最少保留 \(store.minKeepersPerChapter == 0 ? "—" : "\(store.minKeepersPerChapter) 张")",
                                value: $store.minKeepersPerChapter, in: 0...50)
                            .font(.caption)
                            .help("某个章节（仪式/晚宴…）留下的张数低于这个数就在状态栏和时间轴上提醒。0 = 只在整章全灭时提醒")
                        Text("拖动实时生效 · 红字 = 该项当前淘汰数")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(6)
                }

                GroupBox("VLM 语义分析") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("模型") {
                            Text("MiniCPM-V 4.6").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("启动服务") { store.startVLMServer() }
                            .help("通过 Ollama 启动 MiniCPM-V 4.6")
                        Button("复审废片 (\(store.autoRejectCount))") { store.runAppealOnRejects() }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.autoRejectCount == 0 || store.isRunning)
                            .help("给自动淘汰的照片一个平反机会：按各自的淘汰原因定向复查 (虚焦→主体清晰吗;闭眼→是否眯眼笑;曝光→是否刻意剪影/逆光)。洗清罪名的照片自动回到可用并带“平反”徽章;人工改判过的不复审")
                        Button("精审幸存照片") { store.runVLMOnSurvivors() }
                            .disabled(store.items.isEmpty || store.isRunning)
                            .help("可选:给未淘汰照片打表情分(连拍组挑精选用)并检查构图(抢镜/切肢仅作提示徽章)")
                    }
                    .padding(6)
                }
            }
            .padding(12)
        }
    }

    /// One threshold row: name + live value + kill count on top, the shoot's
    /// metric distribution behind the slider, docs in tooltip.
    private func thresholdSlider(label: String, value: String, killCount: Int,
                                 slider: Slider<EmptyView, EmptyView>, help: String,
                                 histogram: MetricHistogram) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                if killCount > 0 {
                    Text("淘汰 \(killCount)").font(.caption).monospacedDigit()
                        .foregroundStyle(.red)
                }
                Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            histogram
            slider
        }
        .help(help)
    }

    /// 拖进来的东西：文件夹就打开它，照片文件就打开它所在的文件夹。新文件夹直接开始分析；
    /// 分析过的就打开缓存的结果（要重新分析点顶栏「重新分析」）。
    private func openDroppedFolder(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        guard !store.isRunning else {
            store.lastError = "正在处理中，先点“取消”再换文件夹"
            return
        }
        store.switchSession(to: folder)
        if store.items.isEmpty { store.runAnalysis() }
    }

    private func pickFolder() {
        modalPanelOpen = true
        defer { modalPanelOpen = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.switchSession(to: url)
            // A folder with no cached session shows an empty grid until analysis
            // runs — users read that as "选了没反应", so kick it off right away.
            if store.items.isEmpty {
                store.runAnalysis()
            } else {
                // Re-picking an analyzed folder used to silently show the same
                // cached grid — also read as "没反应". Ask instead: re-analysis
                // is incremental (unchanged photos are skipped), so it's cheap
                // when the folder gained new photos.
                let alert = NSAlert()
                alert.messageText = "「\(url.lastPathComponent)」已有分析结果"
                alert.informativeText = "已加载缓存的 \(store.items.count) 张。要重新分析吗？" +
                    "未改动的照片会自动跳过，只分析新增或修改过的部分。"
                alert.addButton(withTitle: "重新分析")
                alert.addButton(withTitle: "查看现有结果")
                if alert.runModal() == .alertFirstButtonReturn {
                    store.runAnalysis()
                }
            }
        }
    }

    /// `ids` 给定 = 只导这几张（「选中的照片」，大场次分批发）。
    private func exportContactSheet(includeUsable: Bool, ids: [String]? = nil) {
        modalPanelOpen = true      // 存储卡导完别在保存面板开着时切场次（导出的会变成新场次的）
        defer { modalPanelOpen = false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "选片确认_\(store.photoDir?.lastPathComponent ?? "").html"
        if let htmlType = UTType(filenameExtension: "html") {
            panel.allowedContentTypes = [htmlType]
        }
        if panel.runModal() == .OK, let url = panel.url {
            store.exportContactSheet(to: url, includeUsable: includeUsable, ids: ids)
        }
    }

    // MARK: - 客户选片闭环：确认表 → 导入客户选择 → 复制文件名清单 / 复制原片

    /// 「导出」菜单里的这一段。确认表的大小按每张约 120 KB 先估给你看。
    /// 菜单跟着整页重绘（方向键每按一下都算），这里只数张数；照片 id 等点了再取。
    @ViewBuilder
    private var clientMenuItems: some View {
        let counts = store.verdictCounts
        let keepers = counts.pick + counts.usable
        let selectedCount = selectedIDs.count
        Menu("导出选片确认表 (HTML)") {
            Button("仅精选 (\(counts.pick) 张 · \(ProofSheetPage.estimate(counts.pick)))...") {
                exportContactSheet(includeUsable: false)
            }
            .disabled(counts.pick == 0)
            Button("精选 + 可用 (\(keepers) 张 · \(ProofSheetPage.estimate(keepers)))...") {
                exportContactSheet(includeUsable: true)
            }
            .disabled(keepers == 0)
            Button("选中的照片 (\(selectedCount) 张 · \(ProofSheetPage.estimate(selectedCount)))...") {
                exportContactSheet(includeUsable: false, ids: selectedInGridOrder)
            }
            .disabled(selectedCount == 0)
        }
        .disabled(store.isRunning)
        Button("导入客户选择...") { showClientImport = true }
            .disabled(store.items.isEmpty || store.isRunning)
        if store.clientPickCount > 0 {
            Button("清除客户选中 (\(store.clientPickCount))") { store.clearClientPicks() }
        }
        let scopeCount = selectedCount > 0 ? selectedCount : store.filteredCount
        let scope = Self.scopeLabel(store: store, selected: selectedCount, count: scopeCount)
        Menu("复制文件名 (\(scope))") {
            ForEach(FilenameList.Format.allCases) { format in
                Button(format.title) { store.copyFilenameList(deliveryScopeIDs(), format: format) }
            }
        }
        .disabled(scopeCount == 0)
        Button("复制原片到... (\(scope))") { copyOriginals(deliveryScopeIDs()) }
            .disabled(scopeCount == 0 || store.isRunning || store.photoDir == nil)
    }

    /// 选中的照片，按网格顺序（Set 没有顺序）。
    private var selectedInGridOrder: [String] {
        store.items.map(\.id).filter(selectedIDs.contains)
    }

    /// 复制文件名 / 复制原片的范围：选中了照片就是选中的那些，否则是当前筛选（判决、客户选中、本章、临界）。
    /// 分组视图里收起来的单张、叠起来的废片照样算（筛选选得出来就算）。
    private func deliveryScopeIDs() -> [String] {
        selectedIDs.isEmpty ? store.filteredItems().map(\.id) : selectedInGridOrder
    }

    private static func scopeLabel(store: BatchStore, selected: Int, count: Int) -> String {
        guard selected == 0 else { return "选中的 \(selected) 张" }
        var parts: [String] = []
        if store.activeChapterFilter != nil { parts.append("本章") }
        if store.clientPickFilter { parts.append("客户选中") }
        if let verdict = store.verdictFilter { parts.append(verdict.rawValue) }
        if store.borderlineFilter { parts.append("临界") }
        let name = parts.isEmpty ? "全部" : parts.joined(separator: "·")
        return name + " \(count) 张"
    }

    /// 「复制原片到…」：选目标文件夹（记住上次的，没有就从拍摄文件夹旁边开始），然后后台复制。
    private func copyOriginals(_ ids: [String]) {
        modalPanelOpen = true      // 存储卡导完别在选文件夹时切场次
        defer { modalPanelOpen = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "复制到这里"
        panel.message = "把 \(ids.count) 张的原片（RAW+JPG 和旁边的 .xmp 一起）复制过去：只复制、不移动，同名不覆盖。" +
            "不能选拍摄文件夹里面（下次分析会当成新照片），可以在旁边新建一个精修文件夹"
        panel.directoryURL = store.lastCopyDestination ?? store.photoDir?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.copyOriginals(ids, to: url)
    }

    private var jpegExportCount: Int {
        let counts = store.verdictCounts
        return counts.pick + (jpegIncludeUsable ? counts.usable : 0)
    }

    /// nil = ask for a folder; otherwise export straight into it.
    private func exportJPEGs(to target: URL?) {
        modalPanelOpen = true      // 存储卡导完别在保存面板开着时切场次（导出的会变成新场次的）
        defer { modalPanelOpen = false }
        var folder = target
        if folder == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "导出到此文件夹"
            panel.message = "不能选拍摄文件夹里面（勾了覆盖会换掉原片，下次分析也会当成新照片）；" +
                "拍摄文件夹下的「\(ImageLoader.jpegExportSubfolder)」可以"
            panel.directoryURL = store.photoDir
            guard panel.runModal() == .OK, let url = panel.url else { return }
            folder = url
        }
        guard let folder else { return }
        store.exportJPEGs(to: folder, includeUsable: jpegIncludeUsable, options: jpegOptions.wrappedValue,
                          overwrite: jpegOverwrite)
    }
}

// MARK: - 快捷键一览

/// 快捷键按场景分组列出来（Aftershoot、Narrative 都有这么一张表）。以前只散在各处的提示行里。
struct ShortcutsPanel: View {
    private static let sections: [(String, [(String, String)])] = [
        ("网格", [
            ("点击", "选中这张（数字键改的就是它）"),
            ("双击 / 空格 / ⏎", "打开大图"),
            ("← → ↑ ↓", "移动"),
            ("[  ]", "上一章 / 下一章"),
            ("1  2  3  0", "精选 · 可用 · 废片 · 恢复自动（选了多张就作用于全部）"),
            ("⌘点  ⇧点  ⌘A", "多选 · 连选 · 全选"),
            ("⌘⏎", "保留选中，同场其余废片（选了连拍里的照片时）"),
            ("C  D  F", "连拍挑选 · 跳到下一个待处理的场（切到按分组）· 审片"),
            ("-  =", "缩略图小一号 / 大一号"),
            ("⌥⌘S", "收起 / 显示右侧筛选面板"),
            ("⌘Z  Esc", "撤销 · 取消选择"),
        ]),
        ("连拍挑选", [
            ("点照片", "只留这张（同一场其余废）"),
            ("右上角 精选/可用/废", "只改这一张"),
            ("⌘点  ⇧空格", "多留 / 取消"),
            ("1–9  空格", "只留第几张（开了「选完直接下一组」就顺便确认）· 只留高亮那张"),
            ("0", "恢复推荐"),
            ("← →  ↑ ↓", "移动高亮 · 上一组 / 下一组"),
            ("⏎", "确认并下一组"),
            ("Z  [ ]  P", "放大到脸 · 放大时换人 · 对焦高亮"),
            ("⌘Z  Esc", "撤销 · 先退出放大，再返回（网格；从审片来的回审片）"),
        ]),
        ("审片", [
            ("1  2  3", "精选 · 可用 · 废片（判完自动下一张）"),
            ("0", "恢复自动"),
            ("← →", "上一张 / 下一张"),
            ("Z  P", "放大 · 对焦高亮"),
            ("C", "这张是连拍：去挑这一场（⏎ 定完自动回到审片）"),
            ("⌘Z  Esc", "撤销 · 先退出放大，再退出审片"),
        ]),
        ("大图（双击打开）", [
            ("← →", "上一张 / 下一张"),
            ("1  2  3  0", "精选 · 可用 · 废片 · 恢复自动"),
            ("C  P", "挑选本场 · 对焦高亮（放大时）"),
            ("⌘Z  Esc", "撤销 · 关闭"),
        ]),
        ("时间轴", [
            ("点一段", "跳到这一章"),
            ("右键", "只看这一章（已经在看这一章：显示全部章节）"),
            ("⇧Esc", "显示全部章节"),
        ]),
        ("其他", [
            ("拖文件夹进窗口", "打开这场拍摄（拖照片 = 打开它所在的文件夹）"),
            ("插相机存储卡", "问要不要导入到「图片 › 今天日期」，导完直接分析"),
            ("?", "这张表"),
        ]),
    ]

    var body: some View {
        // 两列（网格 + 时间轴 + 其他 / 连拍挑选 + 审片 + 大图）：并排四列比 1280 的窗口还宽，
        // 从状态栏弹出来会出界。
        HStack(alignment: .top, spacing: 24) {
            column([Self.sections[0], Self.sections[4], Self.sections[5]])
            column([Self.sections[1], Self.sections[2], Self.sections[3]])
        }
        .padding(16)
    }

    private func column(_ sections: [(String, [(String, String)])]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections, id: \.0) { title, rows in
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    ForEach(rows, id: \.0) { key, action in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(key).font(.caption.monospaced().bold())
                                .frame(width: 128, alignment: .leading)
                            Text(action).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(width: 330, alignment: .leading)
    }
}

// MARK: - 缩略图悬停：快捷判决（Lightroom 网格格子上可点的旗标那种）

/// 鼠标停在缩略图上，图下沿露出一小条：★ 精选 / ● 可用 / ✕ 废片（现在是哪个亮哪个），多张连拍的行里
/// 再加「只留这张」。只用鼠标的人不用先 ⌘ 选再去顶上的批量栏，也不用记 1/2/3。
/// 包在格子**外面**：按钮是格子点击手势的兄弟而不是子孙，点按钮不会顺带触发「选中这张」；
/// 悬停挂在叠加层之后（把按钮也包进去），不然指针移到按钮上算「离开」，按钮一闪一闪。
private struct CellHoverBar<Content: View>: View {
    let id: String
    let verdict: Verdict
    /// 多张连拍、而且它还不是唯一留下的那张时才有。
    let keepOnly: (() -> Void)?
    /// 缩略图窄（< 150pt）：「只留这张」单独一行放在上面。一行放不下时整条比格子宽，✕ 伸到隔壁格子
    /// 底下，鼠标一过去悬停就没了，根本点不到（审查发现）。
    var compact = false
    let onSet: (Verdict) -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    /// 只认单击：点完 ✕ 这张会跳去废片区、「只留这张」会让整场叠起来，后面的照片立刻补到指针底下 ——
    /// 手快连点两下，第二下就落在别的照片上了（`ClickGuard`）。
    static var isSingleClick: Bool { !ClickGuard.isRepeatClick }

    var body: some View {
        content()
            .overlay(alignment: .bottom) {
                if hovering || id == SnapshotPreview.hoverID {
                    bar
                        .padding(3)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .fixedSize()
                        .padding(.bottom, 22)
                }
            }
            .onHover { hovering = $0 }
    }

    @ViewBuilder private var bar: some View {
        if compact, let keepOnly {
            VStack(spacing: 3) {
                keepButton(keepOnly)
                verdictButtons
            }
        } else {
            HStack(spacing: 3) {
                if let keepOnly { keepButton(keepOnly) }
                verdictButtons
            }
        }
    }

    private func keepButton(_ action: @escaping () -> Void) -> some View {
        Button { if Self.isSingleClick { action() } } label: {
            Text("只留这张").font(.caption2.bold())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Verdict.pick.color.opacity(0.92), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("这张留下（精选），本场其余设为废片。整场一次改判，⌘Z 撤销")
    }

    private var verdictButtons: some View {
        HStack(spacing: 3) {
            ForEach([Verdict.pick, .usable, .reject], id: \.self) { v in
                let on = v == verdict
                Button { if Self.isSingleClick { onSet(v) } } label: {
                    Image(systemName: v.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 18)
                        .background(on ? v.color.opacity(0.9) : Color.clear, in: Capsule())
                        .foregroundStyle(on ? Color.white : v.color)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(v.rawValue + "（只改这一张）")
            }
        }
    }
}

// MARK: - Cached async thumbnail

/// Grid cells used to decode the full preview JPEG synchronously in `body` on
/// every appearance — scrolling a few hundred photos stuttered. Decode a small
/// thumbnail off the main thread once and cache it.
enum ThumbCache {
    /// Shared by the grid's 512px thumbs AND the review/inspector 1600px fit
    /// decodes (~7MB each) — a count limit alone let the 1600px entries grow to
    /// multiple GB on a 500-photo shoot, so the limit is bytes, not entries.
    /// ~1/10 of physical RAM (8GB Air → 800MB, 16GB → 1.6GB, 32GB+ capped at
    /// 2GB): the fixed 800MB plus the other two caches was 1.6GB on an 8GB
    /// machine, which swapped.
    static let physicalMemory = Int(ProcessInfo.processInfo.physicalMemory)
    static func budget(fraction: Double, cap: Int) -> Int {
        min(cap, Int(Double(physicalMemory) * fraction))
    }

    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = budget(fraction: 0.10, cap: 2_000_000_000)
        return c
    }()

    /// Re-analysis overwrites previews/<id>.jpg in place, so a purely
    /// path-keyed cache kept serving the old picture (new numbers, stale
    /// thumbnail) until relaunch. Bumping this on every analysisDidFinish
    /// changes the cache key AND the `.task(id:)` of every ThumbnailView, so
    /// visible cells re-decode instead of sitting on their @State copy.
    nonisolated(unsafe) private(set) static var generation = 0

    @MainActor
    static func invalidate() {
        generation += 1
        cache.removeAllObjects()
        FullResCache.cache.removeAllObjects()
        FaceStripCache.cache.removeAllObjects()
    }

    static func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(generation)|\(maxPixel)|\(path)" as NSString
    }

    static func load(path: String, maxPixel: Int = 512) -> NSImage? {
        let cacheKey = key(path, maxPixel)
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let image = decode(path: path, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: cacheKey, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    /// 纯解码，不进缓存 —— 大图那条线用自己的 FitCache，别把网格缩略图挤出去。
    static func decode(path: String, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        // RAW-only 场次的适应视图：先试相机内嵌的 JPEG 预览（相机自己锐化过，
        // 解码只要几十毫秒），够大才用；不够大（很多 RAW 只嵌了 160px 缩略图）
        // 就走下面的完整 demosaic。Photo Mechanic / LR 的"嵌入式预览"就是这么干的。
        // 代价：适应视图（相机渲染）和 100%（Apple 的 RAW 渲染）色彩/反差会略有不同。
        let ext = (path as NSString).pathExtension.lowercased()
        if maxPixel >= 2000, ImageLoader.rawExtensions.contains(ext),
           let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixel,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary),
           max(embedded.width, embedded.height) >= min(2000, maxPixel / 2) {
            return NSImage(cgImage: embedded, size: NSSize(width: embedded.width, height: embedded.height))
        }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  // 以前只喂已经转正的预览图，没这个键也没事。SharpImageView 现在直接喂
                  // 相机原文件（带 EXIF 方向），不转的话竖拍先正着出预览、再横着换上
                  // 清晰版，分析框还画错轴。对预览图是无操作。
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct ThumbnailView: View {
    let path: String
    var maxPixel: Int = 512
    var fit: Bool = false
    @State private var image: NSImage?

    var body: some View {
        // Read the cache synchronously in body: a cell scrolled back into view
        // is a fresh struct with nil @State, and waiting for `.task` to copy
        // the cached image over showed a gray flash on every scroll-back.
        let shown = image ?? ThumbCache.cache.object(forKey: ThumbCache.key(path, maxPixel))
        return Group {
            if let shown {
                Image(nsImage: shown).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                Rectangle().fill(.gray.opacity(0.2))
            }
        }
        .task(id: ThumbCache.key(path, maxPixel)) {
            if let cached = ThumbCache.cache.object(forKey: ThumbCache.key(path, maxPixel)) {
                image = cached
                return
            }
            // Tiny debounce so fast scrolling cancels cells before their decode
            // even starts — otherwise a fling through 500 photos queues 500
            // wasted JPEG decodes behind the ones actually on screen.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            let p = path
            let px = maxPixel
            let loaded = await Task.detached(priority: .utility) { ThumbCache.load(path: p, maxPixel: px) }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

// MARK: - 大图专用缓存

/// 检视器 / 审片 / 对比的 4096 解码（~45MB/张）和锐化成品（~17MB/张）。以前和网格
/// 缩略图塞同一个 ThumbCache：检视器里翻 20 张就是 1.2GB，回到网格全灰重解。
/// 这里只留翻页前后够用的几张，网格那边不受影响。
enum FitCache {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 12
        c.totalCostLimit = ThumbCache.budget(fraction: 0.05, cap: 800_000_000)
        return c
    }()

    static func load(path: String, maxPixel: Int) -> NSImage? {
        let cacheKey = ThumbCache.key(path, maxPixel)
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let image = ThumbCache.decode(path: path, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: cacheKey, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

// MARK: - Progressive fit view (检视器 / 审片 / 对比的大图)

// SharpRenderer（Lanczos + 屏幕输出锐化）挪到了 DeliveryExport.swift：交付导出缩小时也走它。

/// 适应窗口的大图，三段渐进：1024 预览秒出 → 4096 解码 → 按取景区设备像素
/// Lanczos+锐化的成品换上。翻页时预取的是中间那张 4096，成品在 GPU 上几毫秒。
///
/// 以前三处大图全是 `ThumbnailView(previewPath, maxPixel: 1600)` —— 但预览文件
/// 本身只有 1024px（previewMaxPixel），Retina 27" 上的大图面板 ~2200 物理像素宽，
/// 等于把预览放大两倍多来看，怎么看都是糊的。"放大 100%" 那一档是清楚的，
/// 反而衬得适应视图更糊。
struct SharpImageView: View {
    let previewPath: String
    let decodePath: String
    /// 带着 key 存：检视器翻页时这个 view 结构位置不变，@State 会原地保留 ——
    /// 不带 key 的话按 → 之后画面还是上一张，新照片的头信息配着旧画面，
    /// 数字键判的是新 id、看的是旧图。和 toggleZoom 里 requestedID 那道守卫同一类。
    @State private var loaded: (key: NSString, image: NSImage)?
    /// 图实际显示出来的尺寸（点），量出来才知道要渲染多少设备像素。
    @State private var displayed: CGSize = .zero

    /// 中间那张解码的上限。JPEG 走 ImageIO 的 DCT 缩放解码，4096 和 2048 耗时
    /// 差不多；RAW 反正要完整 demosaic 再缩。6K 显示器上也够用。
    static let fitMaxPixel = 4096

    private var longEdge: Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return SharpRenderer.bucket(max(displayed.width, displayed.height) * scale)
    }

    var body: some View {
        let decodedKey = ThumbCache.key(decodePath, Self.fitMaxPixel)
        let previewKey = ThumbCache.key(previewPath, 1024)
        // 成品按 (文件, 目标长边) 缓存，和解码缓存住同一个 NSCache。
        let renderedKey = ThumbCache.key(decodePath + "#sharp", longEdge)
        let mine = loaded?.key == renderedKey || loaded?.key == decodedKey ? loaded?.image : nil
        let shown = mine
            ?? FitCache.cache.object(forKey: renderedKey)
            ?? FitCache.cache.object(forKey: decodedKey)
            ?? ThumbCache.cache.object(forKey: previewKey)
        return Group {
            if let shown {
                Image(nsImage: shown).interpolation(.high).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.gray.opacity(0.2))
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { displayed = geo.size }
        })
        .task(id: renderedKey) {
            if let done = FitCache.cache.object(forKey: renderedKey) {
                loaded = (renderedKey, done)
                return
            }
            // 1. 预览先上（多半已在缓存里，没有就解一张 1024 的，很快）。
            if loaded?.key != decodedKey, loaded?.key != renderedKey {
                let p = previewPath
                if let quick = await Task.detached(priority: .userInitiated) { ThumbCache.load(path: p, maxPixel: 1024) }.value {
                    guard !Task.isCancelled else { return }
                    loaded = (decodedKey, quick)
                }
            }
            // 2. 4096 解码。
            let d = decodePath
            let px = Self.fitMaxPixel
            guard let decoded = await Task.detached(priority: .userInitiated) { FitCache.load(path: d, maxPixel: px) }.value,
                  !Task.isCancelled else { return }
            loaded = (decodedKey, decoded)
            // 3. 还没量到尺寸就先停在这，量到后 renderedKey 变化会再进来。
            guard displayed != .zero else { return }
            // 窗口拖动时每个 256 档只渲染一次，中间的档位让它取消掉。
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let edge = longEdge
            let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                if let hit = FitCache.cache.object(forKey: renderedKey) { return hit }
                guard let out = SharpRenderer.render(decoded, longEdge: edge) else { return nil }
                FitCache.cache.setObject(out, forKey: renderedKey,
                                         cost: Int(out.size.width * out.size.height * 4))
                return out
            }.value
            guard !Task.isCancelled, let rendered else { return }
            loaded = (renderedKey, rendered)
        }
    }
}

// MARK: - Full-res decode cache (inspector zoom)

/// TRUE full-resolution decodes for the inspector's zoom mode. The grid previews
/// are only 1024px and a capped decode hides exactly the eyelash-level focus
/// detail a photographer zooms in to check — so no size cap here (a 40MP frame
/// is ~160MB decoded; the cache keeps only a couple).
enum FullResCache {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2
        // two ~40MP frames on a 16GB machine; a 61MP pair evicts down to one
        c.totalCostLimit = ThumbCache.budget(fraction: 0.04, cap: 600_000_000)
        return c
    }()

    static func load(path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 20000,  // effectively uncapped
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: path as NSString, cost: cg.width * cg.height * 4)
        return image
    }
}

// MARK: - 对焦高亮 (focus peaking)

/// 100% 视图上叠一层红色：Laplacian（二阶导）在本图 97 分位以上的像素。看合焦落在
/// 眼睛还是耳朵，C1 / Narrative 都有，Aftershoot 反而没有。
/// - 用二阶导不用梯度：第一版用梯度幅值，把糊掉但反差大的整个背景全标红了。
/// - 在 ≤4096 长边上算，不是 2048：缩到 2048 会把"稍软"和"锐利"都压成一像素过渡，
///   区分度就没了。不从 1024 预览算。
/// - 阈值用分位数不用绝对值：绝对值换一张曝光就失效。
/// - 按 decodePath 缓存；调用方也要按 key 存，翻页后上一张的遮罩盖在这一张上
///   比没有遮罩更糟。
enum FocusMask {
    static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 2  // 4096 长边的 RGBA 遮罩 ~45MB 一张
        return c
    }()
    static let maxEdge = 4096
    static let percentile = 0.97

    static func compute(from image: NSImage, key: String) -> CGImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, CGFloat(maxEdge) / CGFloat(max(cg.width, cg.height)))
        let w = max(3, Int(CGFloat(cg.width) * scale)), h = max(3, Int(CGFloat(cg.height) * scale))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let gray = Metrics.grayscale(rgba: rgba, width: w, height: h)
        let grad = Metrics.laplacianMagnitude(gray: gray, width: w, height: h)
        // 每 8 个像素采一个算分位数，够准且快。
        var sample: [Float] = []
        sample.reserveCapacity(w * h / 8 + 1)
        var i = 0
        while i < grad.count { sample.append(grad[i]); i += 8 }
        sample.sort()
        guard !sample.isEmpty else { return nil }
        let threshold = max(1, sample[min(sample.count - 1, Int(Double(sample.count) * percentile))])
        var mask = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) where grad[p] > threshold {
            // premultipliedLast：红 × alpha(0.8)
            mask[p * 4] = 204; mask[p * 4 + 3] = 204
        }
        let data = Data(mask)
        guard let provider = CGDataProvider(data: data as CFData),
              let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        cache.setObject(out, forKey: key as NSString)
        return out
    }
}

// MARK: - Native zoom pane (NSScrollView magnification)

/// AppKit-native 1:1 viewer. NSScrollView's own magnification handles the
/// trackpad pinch — smooth, continuous, anchored at the pointer, exactly the
/// 预览.app feel. Double-click toggles fit ↔ 100%. SwiftUI's ScrollView can't
/// do this: it exposes no content-offset control, so pinch zoom can't anchor.
struct ZoomPane: NSViewRepresentable {
    enum Entry {
        /// Open at fit × factor — pinch-to-enter carries its own gesture factor
        /// so the transition continues the motion instead of teleporting.
        case fit(factor: CGFloat)
        /// Open at 100% (one image pixel per physical pixel).
        case hundred
    }

    let image: NSImage
    let entry: Entry
    /// Primary-face box (normalized top-left) drawn as a layer on the image.
    let faceBbox: [Double]?
    let boxColor: NSColor
    /// 对焦高亮遮罩（和 image 同一张的，见 FocusMask），nil = 关。
    var focusMask: CGImage? = nil
    /// 进入时让这个点（归一化、左上原点）落在视图正中，而不是图片中心 —— 连拍挑选
    /// 每格按各自的人脸居中。
    var anchor: CGPoint? = nil
    /// 连拍挑选几格联动（拖动/捏合/双击跟着走），nil = 独立。
    var link: ZoomLink? = nil
    /// 单击回调（连拍挑选用来选这一格）：SwiftUI 的点击手势落不到 NSScrollView 上。
    var onClick: (() -> Void)? = nil
    /// 双击回调（在它自己切完 适应 ↔ 100% 之后调）：连拍挑选拿它撤回第一下单击改掉的草稿。
    var onDoubleClick: (() -> Void)? = nil

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        weak var scroll: NSScrollView?
        var overlayLayer: CALayer?
        var maskLayer: CALayer?
        var boundsObserver: NSObjectProtocol?
        weak var link: ZoomLink?
        var onClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        @MainActor @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            // 双击的第二下也会再来一次单击：只认真正的单击。
            guard !ClickGuard.isRepeatClick else { return }
            onClick?()
        }

        /// 单击和双击都要：单击切当前格，双击照旧在适应/100% 之间切。
        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
            true
        }

        @objc func doubleClicked(_ gesture: NSClickGestureRecognizer) {
            guard let scroll, let doc = scroll.documentView else { return }
            let backing = scroll.window?.backingScaleFactor ?? 2
            let hundred = 1.0 / backing
            let fit = ZoomPane.fitMagnification(scroll)
            // At (or near) 100% → back to fit; anywhere else → 100% at the
            // clicked point, so the detail you aimed at stays under the cursor.
            let target = abs(scroll.magnification - hundred) < 0.01 ? fit : hundred
            let point = gesture.location(in: doc)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                scroll.animator().setMagnification(target, centeredAt: point)
            }
            onDoubleClick?()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func fitMagnification(_ scroll: NSScrollView) -> CGFloat {
        guard let doc = scroll.documentView,
              doc.frame.width > 0, doc.frame.height > 0,
              scroll.bounds.width > 0, scroll.bounds.height > 0 else { return 1 }
        return min(scroll.bounds.width / doc.frame.width,
                   scroll.bounds.height / doc.frame.height)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .black

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.wantsLayer = true
        // 适应 ↔ 100% 之间的每一档都是在缩小一张几千万像素的图层。默认的线性
        // 缩小滤波只采样相邻 4 个像素，高频细节（发丝、睫毛、织物）会闪烁/锯齿，
        // 看着就是"不清晰"。三线性 = mipmap，每一档都是正经重采样过的 ——
        // Capture One 那种任何倍率下都干净的手感就是这个。
        imageView.layer?.minificationFilter = .trilinear
        imageView.layer?.magnificationFilter = .linear
        scroll.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)
        if onClick != nil {
            let click = NSClickGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
            click.numberOfClicksRequired = 1
            click.delegate = context.coordinator
            doubleClick.delegate = context.coordinator
            imageView.addGestureRecognizer(click)
        }

        context.coordinator.scroll = scroll
        context.coordinator.onClick = onClick
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.link = link
        if link != nil {
            scroll.contentView.postsBoundsChangedNotifications = true
            // queue: nil = 在发通知的线程上同步回调。给 .main 会被排成异步，联动时的重入
            // 保护就拦不住 A 带 B、B 又带回 A 的来回弹。
            context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil
            ) { [weak coordinator = context.coordinator] _ in
                guard let coordinator, let scroll = coordinator.scroll else { return }
                coordinator.link?.changed(scroll)
            }
        }
        // Bounds are zero until layout — apply the entry magnification after
        // the first pass.
        DispatchQueue.main.async { self.applyEntry(scroll) }
        syncOverlay(context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onClick = onClick
        context.coordinator.onDoubleClick = onDoubleClick
        if let imageView = scroll.documentView as? NSImageView, imageView.image !== image {
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            DispatchQueue.main.async { self.applyEntry(scroll) }
        }
        syncOverlay(context.coordinator)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.boundsObserver = nil
        }
        coordinator.link?.unregister(scroll)
    }

    private func applyEntry(_ scroll: NSScrollView) {
        guard scroll.bounds.width > 0 else { return }
        let backing = scroll.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let fit = Self.fitMagnification(scroll)
        scroll.minMagnification = min(fit, 1 / backing) * 0.5
        scroll.maxMagnification = 3.0 / backing  // 300% actual pixels
        let target: CGFloat
        switch entry {
        case .fit(let factor):
            target = min(scroll.maxMagnification, fit * max(1, factor))
        case .hundred:
            target = 1.0 / backing
        }
        guard let doc = scroll.documentView else {
            scroll.magnification = target
            return
        }
        if let anchor {
            // setMagnification(_:centeredAt:) 只是让那个点在屏幕上不动，并不居中 ——
            // 以前从图片中心进，恰好中心本来就在视图中间才看着像居中。指定点要自己滚过去。
            let point = Self.docPoint(anchor, in: doc)
            scroll.magnification = target
            Self.center(scroll, on: point)
            // 先按自己的人脸摆好再入伙：入伙时联动会把大家当前的倍率/偏移套过来。
            link?.register(scroll, anchor: point)
        } else {
            // Centered on the image middle; the user pans/zooms from there.
            scroll.setMagnification(
                target,
                centeredAt: NSPoint(x: doc.frame.midX, y: doc.frame.midY))
            link?.register(scroll, anchor: NSPoint(x: doc.frame.midX, y: doc.frame.midY))
        }
    }

    /// 归一化、左上原点 → 文档坐标（AppKit 左下原点，单位 = 图像像素）。
    static func docPoint(_ point: CGPoint, in doc: NSView) -> NSPoint {
        NSPoint(x: point.x * doc.frame.width, y: (1 - point.y) * doc.frame.height)
    }

    /// 把文档里的某一点滚到可视区正中（贴边时由 CenteringClipView 兜住）。
    static func center(_ scroll: NSScrollView, on point: NSPoint) {
        let clip = scroll.contentView
        let size = clip.bounds.size
        clip.scroll(to: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        scroll.reflectScrolledClipView(clip)
    }

    private func syncOverlay(_ coordinator: Coordinator) {
        coordinator.overlayLayer?.removeFromSuperlayer()
        coordinator.overlayLayer = nil
        // 遮罩铺满整个图层，跟着 magnification 一起缩放。
        coordinator.maskLayer?.removeFromSuperlayer()
        coordinator.maskLayer = nil
        if let mask = focusMask, let imageView = coordinator.scroll?.documentView {
            let layer = CALayer()
            layer.frame = CGRect(origin: .zero, size: image.size)
            layer.contents = mask
            layer.contentsGravity = .resize
            layer.minificationFilter = .trilinear
            layer.isGeometryFlipped = false
            imageView.layer?.addSublayer(layer)
            coordinator.maskLayer = layer
        }
        guard let bbox = faceBbox, bbox.count == 4,
              let imageView = coordinator.scroll?.documentView else { return }
        let w = image.size.width, h = image.size.height
        let layer = CALayer()
        // Normalized top-left bbox → AppKit's bottom-left origin.
        layer.frame = CGRect(x: bbox[0] * w, y: h - bbox[3] * h,
                             width: (bbox[2] - bbox[0]) * w,
                             height: (bbox[3] - bbox[1]) * h)
        layer.borderColor = boxColor.cgColor
        layer.borderWidth = 2
        imageView.layer?.addSublayer(layer)
        coordinator.overlayLayer = layer
    }
}

/// Keeps an undersized document centered in the scroll view (fit mode / small
/// images) instead of pinned to the bottom-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = doc.frame.minX - (rect.width - doc.frame.width) / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = doc.frame.minY - (rect.height - doc.frame.height) / 2
        }
        return rect
    }
}

// MARK: - Face crop strip

/// Mid-size decodes for face crops when the 1024px preview is too small for
/// the face: 2048px from the original, cached. Kept small — a 10-frame RAW
/// burst used to trigger 10 concurrent 2560px RAW decodes on inspector open.
enum FaceStripCache {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 8
        c.totalCostLimit = ThumbCache.budget(fraction: 0.015, cap: 150_000_000)
        return c
    }()

    /// Serialises original-file decodes: they are the expensive path (a RAW
    /// demosaic each), and the strip asks for up to ten at once. Async so the
    /// waiting happens on this queue, not on parked cooperative-pool threads.
    static let decodeQueue = DispatchQueue(label: "facestrip.decode", qos: .userInitiated)

    static func decode(path: String) async -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        return await withCheckedContinuation { continuation in
            decodeQueue.async {
                if let hit = cache.object(forKey: path as NSString) {
                    continuation.resume(returning: hit)
                    return
                }
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 2048,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                cache.setObject(image, forKey: path as NSString, cost: cg.width * cg.height * 4)
                continuation.resume(returning: image)
            }
        }
    }

    /// Face wide enough on the 1024px preview to read eyes from it — then the
    /// preview (already cached for the grid) is the source, no original decode.
    static let previewFaceMinWidth = 110.0

    static func source(previewPath: String, decodePath: String, bbox: [Double]) async -> NSImage? {
        guard bbox.count == 4 else { return nil }
        let widthOnPreview = (bbox[2] - bbox[0]) * Double(ImageLoader.previewMaxPixel)
        if widthOnPreview >= previewFaceMinWidth,
           let preview = ThumbCache.load(path: previewPath, maxPixel: ImageLoader.previewMaxPixel) {
            return preview
        }
        // 大图那边已经解过 4096 的（审片 / 挑选 / 检视器的大图、相邻预取都会解）：直接拿来裁，
        // 不再为一张脸单独排一张 2048 的原图解码 —— 那个队列是串行的、取消不了，翻得快会越排越长。
        if let fit = FitCache.cache.object(forKey: ThumbCache.key(decodePath, 4096)) {
            return fit
        }
        return await decode(path: decodePath)
    }
}

/// One face close-up with an eye-state ring: green = eyes open, red = closed,
/// gray = undeterminable. The whole point is that the photographer never has to
/// zoom manually just to check eyes.
struct FaceCropView: View {
    /// cropping(to:) 和整幅解码共用同一块像素 —— 不另画一份，一张 76pt 的小脸会把整张 2048/4096 的
    /// 解码一直留在内存里（缓存早就放掉了它也放不掉）。
    nonisolated static func ownPixels(_ image: CGImage) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? srgb
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    let previewPath: String
    let decodePath: String
    let face: FaceInfo
    /// 边长（点）。检视器 84，连拍挑选每格底下 60–96（按格子大小）。
    var size: CGFloat = 84
    /// 连拍挑选按人对齐后的睁眼档（多了黄色「眯眼」）；nil = 只看这张脸自己的睁闭眼。
    var eye: FaceAlignment.Eye? = nil
    /// 这个人在本组里眼睛最好的那张：右上角一颗绿星。
    var bestEyes = false

    @State private var crop: NSImage?

    private var ringColor: Color {
        if let eye {
            switch eye {
            case .open: return .green
            case .squint: return .yellow
            case .closed: return .red
            case .unknown: return .gray
            }
        }
        switch face.eyeClosed {
        case .some(true): return .red
        case .some(false): return .green
        case .none: return .gray
        }
    }

    private var eyeSymbol: String {
        if eye == .closed || (eye == nil && face.eyeClosed == true) { return "eye.slash.fill" }
        return "eye.fill"
    }

    var body: some View {
        Group {
            if let crop {
                Image(nsImage: crop).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.gray.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ringColor, lineWidth: 3))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: eyeSymbol)
                .font(.caption2)
                .padding(2)
                .background(.black.opacity(0.6), in: Circle())
                .foregroundStyle(ringColor)
                .padding(2)
        }
        .overlay(alignment: .topTrailing) {
            if bestEyes {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .padding(3)
                    .background(.black.opacity(0.6), in: Circle())
                    .foregroundStyle(Verdict.pick.color)
                    .padding(2)
                    .help("这个人在本组里眼睛睁得最好的一张")
            }
        }
        .task(id: decodePath + face.bbox.description) {
            // 换了照片 / 换了脸：先清掉，别让上一张的脸挂在新照片的睁闭眼圈底下。
            crop = nil
            // 翻得快时先等一拍：被翻过去的格子在这里就取消了，不会去排原图解码。
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let path = decodePath
            let preview = previewPath
            let bbox = face.bbox
            let result = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard bbox.count == 4,
                      let decoded = await FaceStripCache.source(previewPath: preview, decodePath: path, bbox: bbox),
                      let cg = decoded.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                let rect = CGRect(x: bbox[0] * w, y: bbox[1] * h,
                                  width: (bbox[2] - bbox[0]) * w, height: (bbox[3] - bbox[1]) * h)
                guard let cropped = cg.cropping(to: rect), let owned = Self.ownPixels(cropped) else { return nil }
                return NSImage(cgImage: owned, size: NSSize(width: owned.width, height: owned.height))
            }.value
            guard !Task.isCancelled else { return }
            crop = result
        }
    }
}

// MARK: - Photo inspector (zoom + manual override + group compare)

struct PhotoInspector: View {
    @ObservedObject var store: BatchStore
    @Binding var inspectedID: String?
    /// The grid's current visible order — paging must match what's on screen.
    let gridOrder: [String]
    @State var currentID: String
    @State private var zoomed = false
    @State private var fullResImage: NSImage?
    @State private var loadingFullRes = false
    /// How the zoom pane opens: at fit×pinch-factor (pinch entry, continuous
    /// with the gesture) or straight at 100% (double-click / toolbar button).
    @State private var zoomEntry: ZoomPane.Entry = .hundred
    /// Live scale of the fit view while an entry pinch is in progress — visual
    /// feedback so the gesture never feels dead before zoom mode takes over.
    @State private var fitPinch: CGFloat = 1.0
    @State private var showOverlay = true
    /// 对焦高亮开关 + 当前这张的遮罩（带 key，翻页不串图）。
    @State private var focusPeak = false
    @State private var focusMask: (key: String, image: CGImage)?
    /// 「挑选本场」：关掉检视器，进全窗口的连拍挑选（参数是当前这张的 id，高亮先落在它上面）。
    /// 场内的取舍全在连拍挑选里做，检视器只看一张。
    let onPickTake: (String) -> Void

    init(store: BatchStore, inspectedID: Binding<String?>, gridOrder: [String], initialID: String,
         onPickTake: @escaping (String) -> Void) {
        self.store = store
        self._inspectedID = inspectedID
        self.gridOrder = gridOrder
        self._currentID = State(initialValue: initialID)
        self.onPickTake = onPickTake
    }

    private var item: BatchItem? {
        store.item(withID: currentID)
    }

    /// Navigation order = what the grid shows under the current filter.
    /// Exactly what the grid shows, handed down from BatchView. Recomputing it
    /// here from store.items only honoured verdictFilter, so ←/→ paged through
    /// photos the grid was hiding (reason chips, 只看临界, 按分组封面) and in a
    /// different order than the pick/usable/reject sections.
    private var visibleIDs: [String] { gridOrder }

    private func groupMembers(_ item: BatchItem) -> [BatchItem] {
        store.items.filter { $0.take == item.take }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                header(item)
                imagePane(item)
                    // The photo wins the height fight against the strips below —
                    // on a 13" screen a group with faces squeezed it to a strip itself.
                    .layoutPriority(1)
                if !item.faces.isEmpty {
                    faceStrip(item)
                }
                let members = groupMembers(item)
                if members.count > 1 {
                    groupStrip(item, members: members)
                    groupFaceCompareStrip(item, members: members)
                }
                signalsRow(item)
                exifRow(item)
                vlmInfo(item)
                bottomBar(item)
            } else {
                Text("照片不存在").padding()
            }
        }
        .frame(minWidth: 960, idealWidth: 1240, minHeight: 700, idealHeight: 880)
        .onChange(of: focusPeak) { refreshFocusMask() }
        .onChange(of: zoomed) { refreshFocusMask() }
        .onChange(of: currentID) { refreshFocusMask() }
    }

    // MARK: header

    private func header(_ item: BatchItem) -> some View {
        HStack {
            Text(item.id).font(.headline)
            Text("场 \(item.take)").foregroundStyle(.secondary)
            if (store.groupSizes[item.burstGroup] ?? 1) > 1 {
                Label("近似重复", systemImage: "square.stack.3d.down.right")
                    .font(.caption).foregroundStyle(.orange)
                    .help("和同场的另一张几乎是同一张画面 (phash 汉明距离≤10)，" +
                          "自动「只留最佳」作用的就是这一层")
            }
            Label(item.verdict.rawValue, systemImage: item.verdict.symbol)
                .font(.caption).bold()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(verdictColor(item.verdict).opacity(0.2), in: Capsule())
                .foregroundStyle(verdictColor(item.verdict))
            Spacer()
            if (store.takeSizes[item.take] ?? 1) > 1 {
                Button("挑选本场 (C)") { onPickTake(item.id) }
                    .keyboardShortcut("c", modifiers: [])
                    .help("进连拍挑选：本场照片并排上台，点一张 = 只留它，⏎ 确认并跳下一组，Z 一起放大到脸")
            }
            Toggle("分析框", isOn: $showOverlay).toggleStyle(.button)
            Toggle("对焦高亮", isOn: $focusPeak).toggleStyle(.button)
                .keyboardShortcut("p", modifiers: [])
                .disabled(!zoomed)
                .help("100% 视图上红色标出合焦区域（本图梯度 95 分位以上），看焦点落在眼睛还是耳朵 (P)")
            Button(zoomed ? "适应窗口" : (loadingFullRes ? "解码原图..." : "放大 100%")) {
                toggleZoom(item)
            }
            .disabled(loadingFullRes)
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.rawPath)])
            }
            Button("关闭") { inspectedID = nil }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
    }

    private func verdictColor(_ v: Verdict) -> Color { v.color }

    // MARK: image panes

    @ViewBuilder
    private func imagePane(_ item: BatchItem) -> some View {
        Group {
            if zoomed, let full = fullResImage {
                // AppKit-native magnification: NSScrollView handles the pinch
                // itself — smooth, continuous, anchored at the pointer. The old
                // SwiftUI ScrollView + frame-resize approach re-laid the content
                // on every tick with no anchor control, which felt like the
                // zoom "jumping around".
                ZoomPane(image: full,
                         entry: zoomEntry,
                         faceBbox: showOverlay ? item.faceBbox : nil,
                         boxColor: item.dynamicEyeClosed == true ? .systemRed : .systemYellow,
                         focusMask: focusPeak && focusMask?.key == item.decodePath ? focusMask?.image : nil)
            } else {
                // Async cached decode — a synchronous NSImage(contentsOfFile:)
                // here blocked the main thread on every open/photo switch.
                SharpImageView(previewPath: item.previewPath, decodePath: item.decodePath)
                    .overlay { analysisOverlay(item) }
                    .scaleEffect(fitPinch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipped()
                    .gesture(
                        // The pinch's own factor carries into zoom mode
                        // (fit × factor), so entry is continuous with the
                        // gesture instead of teleporting to 100%.
                        MagnifyGesture()
                            .onChanged { value in
                                fitPinch = max(1.0, value.magnification)
                            }
                            .onEnded { value in
                                let factor = value.magnification
                                fitPinch = 1.0
                                if factor > 1.1 {
                                    toggleZoom(item, entry: .fit(factor: factor))
                                }
                            }
                    )
                    .onTapGesture(count: 2) { toggleZoom(item, entry: .hundred) }
            }
        }
        .onAppear { prefetchNeighbors() }
        .onChange(of: currentID) {
            zoomed = false
            fullResImage = nil
            fitPinch = 1.0
            prefetchNeighbors()
        }
    }

    /// Warm the fit-view decode of the previous/next photo so ←/→ paging is
    /// instant instead of showing the gray placeholder.
    private func prefetchNeighbors() {
        let ids = visibleIDs
        guard let idx = ids.firstIndex(of: currentID) else { return }
        for offset in [1, -1] {
            let n = idx + offset
            guard ids.indices.contains(n),
                  let neighbor = store.item(withID: ids[n]) else { continue }
            // 预取的是 SharpImageView 要换上去的那张清晰版，翻到时直接命中缓存。
            let path = neighbor.decodePath
            let px = SharpImageView.fitMaxPixel
            guard FitCache.cache.object(forKey: ThumbCache.key(path, px)) == nil else { continue }
            Task.detached(priority: .utility) {
                _ = FitCache.load(path: path, maxPixel: px)
            }
        }
    }

    /// Draws the primary-face box + its metrics directly on the photo, so 对焦
    /// judgement (which face was measured, how it scored, eye state) is visible
    /// in place instead of in a separate row.
    @ViewBuilder
    private func analysisOverlay(_ item: BatchItem) -> some View {
        if showOverlay, let b = item.faceBbox, b.count == 4 {
            GeometryReader { geo in
                let rect = CGRect(
                    x: b[0] * geo.size.width,
                    y: b[1] * geo.size.height,
                    width: (b[2] - b[0]) * geo.size.width,
                    height: (b[3] - b[1]) * geo.size.height
                )
                let eyeText = item.dynamicEyeClosed.map { $0 ? "闭眼!" : "睁眼" } ?? ""
                let qualityText = item.faceQuality.map { String(format: "质量 %.2f", $0) } ?? ""
                let info = ["锐度 \(Int(item.sharpness))", qualityText, eyeText]
                    .filter { !$0.isEmpty }.joined(separator: "  ")

                Rectangle()
                    .path(in: rect)
                    .stroke(item.dynamicEyeClosed == true ? Color.red : Color.yellow, lineWidth: 2)
                Text(info)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(item.dynamicEyeClosed == true ? .red : .yellow)
                    .offset(x: rect.minX, y: max(2, rect.minY - 20))
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: strips

    /// Face close-ups with eye-state rings — scan this instead of zooming.
    private func faceStrip(_ item: BatchItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("人脸").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(item.faces.enumerated()), id: \.offset) { _, face in
                    FaceCropView(previewPath: item.previewPath, decodePath: item.decodePath, face: face)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    /// 同一场的全部照片；点击切换，当前那张高亮。场内取舍（留哪张、其余废片）在
    /// 连拍挑选里做 —— 这里以前也有一套勾选定案条，同一个动作两套手势。
    private func groupStrip(_ item: BatchItem, members: [BatchItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("同场 \(members.count) 张").font(.caption2).foregroundStyle(.secondary)
                ForEach(members) { member in
                    groupStripCell(member)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    /// 一张同场照片，点击切过去看。
    private func groupStripCell(_ member: BatchItem) -> some View {
        VStack(spacing: 1) {
            // 整图 fit：竖拍被裁掉一半就看不出是哪一张。
            ThumbnailView(path: member.previewPath, fit: true)
                .frame(width: 72, height: 72)
                .background(Color(white: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(member.id == currentID ? Color.accentColor : verdictColor(member.verdict),
                                lineWidth: member.id == currentID ? 3 : 1.5)
                )
            Text(member.verdict.rawValue).font(.caption2)
                .foregroundStyle(verdictColor(member.verdict))
        }
        .contentShape(Rectangle())
        .onTapGesture { currentID = member.id }
        .help("点击=看这张 · 场内取舍按 C 进连拍挑选")
    }

    // MARK: info rows

    private func signalsRow(_ item: BatchItem) -> some View {
        HStack(spacing: 16) {
            signal("锐度", String(format: "%.0f", item.sharpness))
            signal("人脸质量", item.faceQuality.map { String(format: "%.2f", $0) } ?? "-")
            signal("曝光裁切", String(format: "%.1f%%", item.worstClipPct * 100))
            signal("闭眼", item.dynamicEyeClosed.map { $0 ? "是" : "否" } ?? "-")
            if let deg = item.horizonDeg, abs(deg) > 1 {
                signal("水平", String(format: "%+.1f°", deg))
            }
            if item.faceCount > 1 { signal("主体人数", "\(item.faceCount)") }
            if let expr = item.expressionScore { signal("VLM表情", "\(expr)") }
            if !item.vlmRescued.isEmpty { signal("VLM平反", item.vlmRescued.joined(separator: "、")) }
            if !item.rejectReasons.isEmpty {
                Text(item.rejectReasons.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.red)
            }
            Spacer()
            HistogramView(path: item.previewPath)
                .frame(width: 130, height: 44)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// The photographer's own language: shooting parameters + slow-shutter flag.
    @ViewBuilder
    private func exifRow(_ item: BatchItem) -> some View {
        if let exif = item.exif {
            HStack(spacing: 6) {
                Text(exif.summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let lens = exif.lens {
                    Text("· \(lens)").font(.caption).foregroundStyle(.tertiary)
                }
                if exif.slowShutter {
                    Label("低于安全快门", systemImage: "tortoise.fill")
                        .font(.caption).foregroundStyle(.yellow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 2)
        }
    }

    /// Primary-face crop of EVERY group member side by side — expression picking
    /// without flipping back and forth. Click a face to jump to that shot.
    @ViewBuilder
    private func groupFaceCompareStrip(_ item: BatchItem, members: [BatchItem]) -> some View {
        let withFaces = members.filter { !$0.faces.isEmpty }
        if withFaces.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("场内表情").font(.caption2).foregroundStyle(.secondary)
                    ForEach(withFaces) { member in
                        VStack(spacing: 1) {
                            FaceCropView(previewPath: member.previewPath, decodePath: member.decodePath,
                                         face: member.faces[0])
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(member.id == currentID ? Color.accentColor : .clear, lineWidth: 3)
                                )
                            Text(member.verdict.rawValue).font(.caption2)
                                .foregroundStyle(verdictColor(member.verdict))
                        }
                        .onTapGesture { currentID = member.id }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func vlmInfo(_ item: BatchItem) -> some View {
        if !item.vlmCompositionIssues.isEmpty || item.vlmReason != nil {
            VStack(alignment: .leading, spacing: 2) {
                if !item.vlmCompositionIssues.isEmpty {
                    Text("构图问题: \(item.vlmCompositionIssues.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let reason = item.vlmReason {
                    Text("VLM: \(reason)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    private func bottomBar(_ item: BatchItem) -> some View {
        HStack {
            Button("◀ 上一张") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Spacer()
            verdictButtons(item)
            Spacer()
            Button("下一张 ▶") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding()
    }

    private func signal(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }

    @ViewBuilder
    private func verdictButtons(_ item: BatchItem) -> some View {
        let override = store.overrides[item.id]
        HStack(spacing: 8) {
            Text("改判:").foregroundStyle(.secondary)
            Button("精选") { store.setOverride(item.id, .pick) }
                .buttonStyle(.bordered)
                .tint(override == .pick ? .green : nil)
                .keyboardShortcut("1", modifiers: [])
            Button("可用") { store.setOverride(item.id, .usable) }
                .buttonStyle(.bordered)
                .tint(override == .usable ? .blue : nil)
                .keyboardShortcut("2", modifiers: [])
            Button("废片") { store.setOverride(item.id, .reject) }
                .buttonStyle(.bordered)
                .tint(override == .reject ? .red : nil)
                .keyboardShortcut("3", modifiers: [])
            Button("恢复自动") { store.setOverride(item.id, nil) }
                .buttonStyle(.bordered)
                .disabled(override == nil)
                .keyboardShortcut("0", modifiers: [])
            Button("撤销") { store.undoLastOverride() }
                .buttonStyle(.bordered)
                .disabled(!store.canUndoOverride)
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销上一次改判 (⌘Z)")
        }
    }

    private func toggleZoom(_ item: BatchItem, entry: ZoomPane.Entry = .hundred) {
        if zoomed {
            zoomed = false
            return
        }
        zoomEntry = entry
        if let cached = FullResCache.cache.object(forKey: item.decodePath as NSString) {
            fullResImage = cached
            zoomed = true
            return
        }
        loadingFullRes = true
        let path = item.decodePath
        let requestedID = item.id
        Task.detached(priority: .userInitiated) {
            let image = FullResCache.load(path: path)
            await MainActor.run {
                loadingFullRes = false
                // 一张 40MP 原图要解码约 1 秒，期间用户可能已经 ←/→ 翻走了。
                // 不校验的话放大窗里是上一张、而头部信息和判决键作用在这一张。
                guard requestedID == currentID else { return }
                if let image {
                    fullResImage = image
                    zoomed = true
                }
            }
        }
    }

    /// 放大 + 开关都亮着才算；算完核对 key，翻页了就丢掉。
    private func refreshFocusMask() {
        guard focusPeak, zoomed, let item, let full = fullResImage else { return }
        let key = item.decodePath
        if focusMask?.key == key { return }
        Task.detached(priority: .userInitiated) {
            let mask = FocusMask.compute(from: full, key: key)
            await MainActor.run {
                guard let mask, currentID == item.id else { return }
                focusMask = (key, mask)
            }
        }
    }

    private func step(_ delta: Int) {
        let ids = visibleIDs
        guard let idx = ids.firstIndex(of: currentID) else { return }
        let next = idx + delta
        if ids.indices.contains(next) {
            currentID = ids[next]
        }
    }
}

// MARK: - Threshold metric histogram

/// Distribution of one analysis metric across the current shoot, with the
/// threshold line drawn on top — the slider stops being a blind drag: red bars
/// are the photos this line kills, before you commit to it.
struct MetricHistogram: View {
    /// 预先分好的箱（BatchStore.histogramBins），不再每次重绘对 3000 个值分箱。
    let bins: [Int]
    let range: ClosedRange<Double>
    let threshold: Double
    /// true = values BELOW the threshold are rejected (sharpness/quality);
    /// false = values above (exposure clipping).
    let killBelow: Bool
    /// Square-root x-axis for metrics bunched near zero (exposure clip) —
    /// linear would pile everything into the first bar.
    var sqrtScale: Bool = false
    /// 被线选中那一侧的颜色。阈值滑杆是"会被淘汰"所以用红；「同一场最大间隔」
    /// 选中的是"会并进同一场"，不是淘汰，用绿色，别让人误以为要删照片。
    var markColor: Color = .red

    private func position(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        let f = max(0, min(1, (v - range.lowerBound) / span))
        return sqrtScale ? f.squareRoot() : f
    }

    var body: some View {
        Canvas { context, size in
            let binCount = bins.count
            guard let maxBin = bins.max(), maxBin > 0 else { return }
            let barW = size.width / CGFloat(binCount)
            let tx = CGFloat(position(threshold)) * size.width
            for (i, count) in bins.enumerated() where count > 0 {
                let h = max(2, CGFloat(count) / CGFloat(maxBin) * size.height)
                let x = CGFloat(i) * barW
                let killed = killBelow ? (x + barW / 2) < tx : (x + barW / 2) >= tx
                context.fill(
                    Path(CGRect(x: x, y: size.height - h, width: max(1, barW - 1), height: h)),
                    with: .color(killed ? markColor.opacity(0.8) : .gray.opacity(0.55))
                )
            }
            var line = Path()
            line.move(to: CGPoint(x: tx, y: 0))
            line.addLine(to: CGPoint(x: tx, y: size.height))
            context.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1)
        }
        .frame(height: 26)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Histogram

/// Luminance histogram (64 bins) from the preview — photographers trust this
/// over any single exposure number.
struct HistogramView: View {
    let path: String
    @State private var bins: [Float]?

    var body: some View {
        Canvas { context, size in
            guard let bins, let maxValue = bins.max(), maxValue > 0 else { return }
            let barWidth = size.width / CGFloat(bins.count)
            for (i, value) in bins.enumerated() {
                let h = CGFloat(value / maxValue) * size.height
                let rect = CGRect(x: CGFloat(i) * barWidth, y: size.height - h,
                                  width: barWidth, height: h)
                context.fill(Path(rect), with: .color(.white.opacity(0.85)))
            }
        }
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        .task(id: path) {
            let p = path
            let computed = await Task.detached(priority: .utility) { () -> [Float]? in
                guard let image = ThumbCache.load(path: p, maxPixel: 512),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let (rgba, w, h) = ImageLoader.rgbaBuffer(cg) else { return nil }
                var hist = [Float](repeating: 0, count: 64)
                let n = w * h
                rgba.withUnsafeBufferPointer { src in
                    for i in 0..<n {
                        let luma = (299 * Int(src[i * 4]) + 587 * Int(src[i * 4 + 1]) + 114 * Int(src[i * 4 + 2])) / 1000
                        hist[min(63, luma >> 2)] += 1
                    }
                }
                return hist
            }.value
            guard !Task.isCancelled else { return }
            bins = computed
        }
    }
}

// MARK: - Fullscreen review mode

/// Photo Mechanic-style pro flow: one big photo, filmstrip below, right hand on
/// arrows, left hand on digits — a digit verdict AUTO-ADVANCES to the next shot.
struct ReviewView: View {
    @ObservedObject var store: BatchStore
    /// Paging order frozen when review mode opened (see BatchView.pagingOrder);
    /// verdicts are read live from the store so the header/filmstrip update.
    let orderIDs: [String]
    /// 进来时定死的：这一轮有没有留下的照片（全是废片 = 本来就是在审废片，「跳过废片」不起作用）。
    let rejectsSkippable: Bool
    @Binding var focusedID: String?
    @Binding var reviewMode: Bool
    /// C / 「挑选这一场」：审到连拍时直接去挑这一场（参数是当前这张的 id）。
    var onPickTake: (String) -> Void = { _ in }
    @State private var showShortcuts = false
    /// In-flow focus check: Z / double-click / pinch opens the full-res ZoomPane
    /// right here — no detour through the inspector and back.
    @State private var zoomed = false
    @State private var zoomImage: NSImage?
    @State private var loadingZoom = false
    @State private var focusPeak = false
    @State private var focusMask: (key: String, image: CGImage)?
    /// 最后一遍过「留下的」时不走进废片区（默认开）。本来就只看废片（筛选了废片再进来审）时不起作用。
    @AppStorage("review.skipRejects") private var skipRejects = true
    /// 按完 1/2/3/0 自动翻到下一张时，屏幕上方闪一下刚才那张判成了什么（Lightroom 的「已设为留用」那种）。
    @State private var toast: (text: String, symbol: String, color: Color, token: Int)?

    /// 实际翻的顺序：开着「跳过废片」就去掉废片 —— 但正在看的这张一定留着（刚按 0 恢复的废片不能
    /// 从脚底下消失），整组都是废片时不跳（不然一张都翻不了）。
    private var order: [String] {
        guard skipping else { return orderIDs }
        return orderIDs.filter { $0 == focusedID || store.item(withID: $0)?.verdict != .reject }
    }

    private var skipping: Bool { skipRejects && rejectsSkippable }

    /// 顺序里的位置。order 要扫一遍全部照片（一万张），一次刷新里算一次传进来，别每处各算一遍。
    private func index(in order: [String]) -> Int {
        guard let id = focusedID, let idx = order.firstIndex(of: id) else { return 0 }
        return idx
    }

    private var currentIndex: Int { index(in: order) }

    private func current(in order: [String]) -> BatchItem? {
        guard !order.isEmpty else { return nil }
        return store.item(withID: order[min(index(in: order), order.count - 1)])
    }

    private var current: BatchItem? { current(in: order) }

    var body: some View {
        let order = self.order
        let position = index(in: order)
        VStack(spacing: 0) {
            if let item = current(in: order) {
                HStack {
                    Text("\(position + 1) / \(order.count)").monospacedDigit()
                    Text(item.id).font(.headline)
                    Label(item.verdict.rawValue, systemImage: item.verdict.symbol).font(.caption).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color(item.verdict).opacity(0.25), in: Capsule())
                        .foregroundStyle(color(item.verdict))
                    if !item.rejectReasons.isEmpty {
                        Text(item.rejectReasons.joined(separator: ", ")).font(.caption).foregroundStyle(.red)
                    }
                    if let exif = item.exif {
                        Text(exif.summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    // 连拍里的第几张：审到连拍时知道前后还有几张同一瞬间的；点一下（或按 C）去挑这一场。
                    if let position = burstPosition(item) {
                        Button { onPickTake(item.id) } label: {
                            Label(position + " · 挑选 (C)", systemImage: "rectangle.stack")
                                .font(.caption).monospacedDigit()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("这张是连拍里的一张：去连拍挑选把这一场并排比一遍 (C)")
                    }
                    Spacer()
                    if skipping, position == order.count - 1 {
                        let skipped = orderIDs.count - order.count
                        if skipped > 0 {
                            Text("留下的看完了 · 另有 \(skipped) 张废片跳过了").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Toggle("跳过废片", isOn: $skipRejects)
                        .toggleStyle(.checkbox).font(.caption)
                        .help("最后一遍过留下的时不走进废片区。要审废片（找误杀）就关掉，或在网格里筛选「废片」再按 F")
                    Text("1精选 2可用 3废片(自动下一张) · 0恢复 · Z放大 · ⌘Z撤销 · ←/→ · Esc退出")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                        .layoutPriority(-1)
                    Button(zoomed ? "适应窗口" : (loadingZoom ? "解码原图..." : "放大 (Z)")) { toggleZoom(item) }
                        .disabled(loadingZoom)
                    Toggle("对焦高亮 (P)", isOn: $focusPeak).toggleStyle(.button)
                        .disabled(!zoomed)
                        .help("100% 视图上红色标出合焦区域")
                    Button("撤销") { store.undoLastOverride() }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(!store.canUndoOverride)
                    Button("退出") {
                        // Esc backs out one level at a time: zoom first, then review.
                        if zoomed { zoomed = false } else { reviewMode = false }
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(8)

                if zoomed, let full = zoomImage {
                    ZoomPane(image: full, entry: .hundred,
                             faceBbox: item.faceBbox,
                             boxColor: item.dynamicEyeClosed == true ? .systemRed : .systemYellow,
                             focusMask: focusPeak && focusMask?.key == item.decodePath ? focusMask?.image : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SharpImageView(previewPath: item.previewPath, decodePath: item.decodePath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        // 右上角：这张里每个人的脸，带睁闭眼圈 —— 不用放大就能看眼睛。
                        .overlay(alignment: .topTrailing) { faceColumn(item) }
                        .overlay(alignment: .top) { toastView }
                        .onTapGesture(count: 2) { toggleZoom(item) }
                        .gesture(
                            MagnifyGesture().onEnded { value in
                                if value.magnification > 1.1 { toggleZoom(item) }
                            }
                        )
                }

                verdictBar(item)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // Lazy: a plain HStack instantiated every photo in the
                        // shoot the moment review mode opened — 3000 cells each
                        // firing a decode at once, and each holding its NSImage
                        // in @State where the cache byte limits can't reclaim it.
                        LazyHStack(spacing: 6) {
                            ForEach(order, id: \.self) { memberID in
                                if let member = store.item(withID: memberID) {
                                // 边框永远是判决色，当前这张另加一圈白的 —— 以前当前张是 accent 蓝框，
                                // 和「可用」的蓝框分不清，也看不出当前这张是什么判决。
                                ThumbnailView(path: member.previewPath, maxPixel: 256, fit: true)
                                    .frame(width: 72, height: 72)
                                    .background(Color(white: 0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(color(member.verdict), lineWidth: 2))
                                    .overlay {
                                        if member.id == item.id {
                                            RoundedRectangle(cornerRadius: 6).inset(by: -3)
                                                .stroke(Color.white, lineWidth: 2.5)
                                        }
                                    }
                                    .padding(.vertical, 3)
                                    .id(member.id)
                                    .onTapGesture { focusedID = member.id }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 92)
                    .onAppear {
                        // 从网格中间进来 / 接着上次的位置：胶片条一开始就停在这张上。
                        if let id = focusedID { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: focusedID) {
                        if let id = focusedID { proxy.scrollTo(id) }
                    }
                }
            } else {
                Text("没有照片").frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("退出") { reviewMode = false }.keyboardShortcut(.escape, modifiers: []).padding()
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            // Resume where the last review session stopped — 3000 photos get
            // reviewed across evenings. An explicit grid focus wins.
            if focusedID == nil, let last = store.lastReviewedID, orderIDs.contains(last) {
                focusedID = last
            }
            // 从一张废片进来（网格焦点 / 上次停在一张废片上）：开着「跳过废片」就落到它后面第一张留下的
            // （到底绕回开头）。以前会落在顺序最末尾，一进来就亮「留下的看完了」，→ 也按不动。
            if skipping, let id = focusedID, store.item(withID: id)?.verdict == .reject,
               let idx = orderIDs.firstIndex(of: id) {
                let after = orderIDs[(idx + 1)...] + orderIDs[..<idx]
                focusedID = after.first { store.item(withID: $0)?.verdict != .reject } ?? id
            }
            if focusedID == nil || !orderIDs.contains(focusedID!) {
                focusedID = order.first
            }
            prefetchNeighbors()
        }
        .onChange(of: focusedID) {
            zoomed = false
            zoomImage = nil
            prefetchNeighbors()
        }
        .onDisappear {
            if let id = focusedID { store.saveReviewPosition(id) }
        }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onChange(of: focusPeak) { refreshFocusMask() }
        .onChange(of: zoomed) { refreshFocusMask() }
        .onKeyPress(characters: .init(charactersIn: "pP")) { press in
            guard press.modifiers.isSubset(of: [.shift, .capsLock]), zoomed else { return .ignored }
            focusPeak.toggle()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "?")) { _ in
            showShortcuts.toggle()
            return .handled
        }
        // C：这张在连拍里就去挑这一场。⌘C 放过去。
        .onKeyPress(characters: .init(charactersIn: "cC")) { press in
            guard press.modifiers.isSubset(of: [.shift, .capsLock]), let item = current,
                  burstPosition(item) != nil else { return .ignored }
            onPickTake(item.id)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "zZ")) { press in
            // Bare Z only: ⌘Z is the undo shortcut on the button above and
            // must not also toggle the zoom.
            guard press.modifiers.isSubset(of: [.shift, .capsLock]) else { return .ignored }
            if let item = current { toggleZoom(item) }
            return .handled
        }
        // 只认按下：按住 3 会按键重复，一张接一张往下废（审查发现）。
        .onKeyPress(characters: .init(charactersIn: "1230"), phases: .down) { press in
            guard let item = current else { return .ignored }
            switch press.characters {
            case "1": apply(.pick, to: item)
            case "2": apply(.usable, to: item)
            case "3": apply(.reject, to: item)
            default: apply(nil, to: item)
            }
            return .handled
        }
    }

    /// 判一张：按键和下面那排按钮走同一条路 —— 写判决、闪提示、判了（不是恢复）就自动下一张。
    private func apply(_ verdict: Verdict?, to item: BatchItem) {
        store.setOverride(item.id, verdict)
        if let now = store.item(withID: item.id) {
            showToast(verdict != nil ? "\(now.verdict.rawValue) · \(item.id)" : "恢复自动 → \(now.verdict.rawValue) · \(item.id)",
                      symbol: now.verdict.symbol, color: now.verdict.color)
        }
        if verdict != nil { step(1, from: item.id) }  // tag-and-advance
    }

    /// 大图下面那排判决按钮：只用鼠标也能审（以前审片模式只认按键）。
    private func verdictBar(_ item: BatchItem) -> some View {
        HStack(spacing: 8) {
            ForEach([(Verdict.pick, "1"), (.usable, "2"), (.reject, "3")], id: \.0) { verdict, key in
                let on = item.verdict == verdict
                // 只认单击：判完会自动翻到下一张，双击的第二下会判到下一张上。
                Button { if !ClickGuard.isRepeatClick { apply(verdict, to: item) } } label: {
                    Label("\(verdict.rawValue)  \(key)", systemImage: verdict.symbol)
                        .font(.callout.bold())
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(on ? verdict.color.opacity(0.85) : verdict.color.opacity(0.15), in: Capsule())
                        .foregroundStyle(on ? Color.white : verdict.color)
                }
                .buttonStyle(.plain)
                .help("\(verdict.rawValue) (\(key))，判完自动下一张")
            }
            Button { apply(nil, to: item) } label: {
                Text("恢复自动  0").font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.overrides[item.id] == nil)
            .help("去掉人工改判，回到按滑杆算的判决 (0)")
            Button { showShortcuts.toggle() } label: { Image(systemName: "keyboard") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("快捷键一览 (?)")
                .popover(isPresented: $showShortcuts, arrowEdge: .bottom) { ShortcutsPanel() }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private func refreshFocusMask() {
        guard focusPeak, zoomed, let item = current, let full = zoomImage else { return }
        let key = item.decodePath
        if focusMask?.key == key { return }
        Task.detached(priority: .userInitiated) {
            let mask = FocusMask.compute(from: full, key: key)
            await MainActor.run {
                guard let mask, focusedID == item.id else { return }
                focusMask = (key, mask)
            }
        }
    }

    private func toggleZoom(_ item: BatchItem) {
        if zoomed {
            zoomed = false
            return
        }
        if let cached = FullResCache.cache.object(forKey: item.decodePath as NSString) {
            zoomImage = cached
            zoomed = true
            return
        }
        // 已经在解上一张了就别再排一个：连按 Z 会对同一文件并发跑两次原图解码。
        guard !loadingZoom else { return }
        loadingZoom = true
        let path = item.decodePath
        let requestedID = item.id
        Task.detached(priority: .userInitiated) {
            let image = FullResCache.load(path: path)
            await MainActor.run {
                loadingZoom = false
                // 解码期间可能已经翻页了 —— 否则放大的是上一张，而数字键判在这一张。
                guard requestedID == focusedID else { return }
                if let image {
                    zoomImage = image
                    zoomed = true
                }
            }
        }
    }

    private func step(_ delta: Int) {
        let order = self.order
        let next = index(in: order) + delta
        if order.indices.contains(next) {
            focusedID = order[next]
        }
    }

    /// 按完判决往下翻：按「判之前」的位置找下一张 —— 开着「跳过废片」时刚判成废片的这张会从顺序里
    /// 退出去，再按它现在的下标找就会跳过一张。
    private func step(_ delta: Int, from id: String) {
        guard let idx = orderIDs.firstIndex(of: id) else { step(delta); return }
        var i = idx + delta
        let skip = skipping
        while orderIDs.indices.contains(i) {
            if !skip || store.item(withID: orderIDs[i])?.verdict != .reject {
                focusedID = orderIDs[i]
                return
            }
            i += delta
        }
    }

    /// 连拍里的第几张（单张不显示）。
    private func burstPosition(_ item: BatchItem) -> String? {
        let members = store.members(ofTake: item.take)
        guard members.count > 1, let idx = members.firstIndex(where: { $0.id == item.id }) else { return nil }
        return "场 \(item.take) · 第 \(idx + 1)/\(members.count) 张"
    }

    /// 右上角一列人脸（从左到右排），带睁闭眼圈；没脸不画。
    @ViewBuilder
    private func faceColumn(_ item: BatchItem) -> some View {
        let faces = item.faces.filter { $0.bbox.count == 4 }
            .sorted { ($0.bbox[0] + $0.bbox[2]) < ($1.bbox[0] + $1.bbox[2]) }
        if !faces.isEmpty {
            VStack(spacing: 6) {
                // 按「这张照片 + 第几张脸」认格子：只按下标的话翻页时复用同一个格子，新照片底下先挂着上一张的脸。
                ForEach(Array(faces.prefix(4).enumerated()), id: \.offset) { offset, face in
                    FaceCropView(previewPath: item.previewPath, decodePath: item.decodePath, face: face, size: 76)
                        .id("\(item.id)#\(offset)")
                }
                if faces.count > 4 {
                    Text("+\(faces.count - 4)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast.text, systemImage: toast.symbol)
                .font(.callout.bold())
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Color.black.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(toast.color.opacity(0.8), lineWidth: 1.5))
                .foregroundStyle(toast.color)
                .padding(.top, 14)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func showToast(_ text: String, symbol: String, color: Color) {
        let token = (toast?.token ?? 0) + 1
        withAnimation(.easeOut(duration: 0.12)) { toast = (text, symbol, color, token) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            guard toast?.token == token else { return }
            withAnimation(.easeIn(duration: 0.25)) { toast = nil }
        }
    }

    /// Warm the 1600px decode of the neighbors while the current photo is on
    /// screen — advancing with → hits the cache instead of a visible decode.
    private func prefetchNeighbors() {
        let order = self.order
        let idx = index(in: order)
        for offset in [1, -1, 2] {
            let n = idx + offset
            guard order.indices.contains(n), let neighbor = store.item(withID: order[n]) else { continue }
            // 预取的是 SharpImageView 要换上去的那张清晰版，翻到时直接命中缓存。
            let path = neighbor.decodePath
            let px = SharpImageView.fitMaxPixel
            guard FitCache.cache.object(forKey: ThumbCache.key(path, px)) == nil else { continue }
            Task.detached(priority: .utility) {
                _ = FitCache.load(path: path, maxPixel: px)
            }
        }
    }

    private func color(_ v: Verdict) -> Color { v.color }
}
