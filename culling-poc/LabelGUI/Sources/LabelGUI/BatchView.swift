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
    /// JPG 交付导出设置 (Capture One 式质量档)。
    @AppStorage("batch.jpegQuality") private var jpegQuality: Double = 90
    @AppStorage("batch.jpegIncludeUsable") private var jpegIncludeUsable = true
    @AppStorage("batch.jpegOverwrite") private var jpegOverwrite = false
    @State private var showJPEGSheet = false
    /// 高ISO RAW 导出 (降噪流程)。
    @State private var showISOSheet = false
    /// 精华 Top N（Aftershoot 的 Sneak Peek）：当天发朋友圈用的那二十张。
    @State private var showHighlightsSheet = false
    @AppStorage("batch.highlightsCount") private var highlightsCount = 20
    @AppStorage("batch.highlightsMaxPixel") private var highlightsMaxPixel = 2048
    @AppStorage("batch.isoThreshold") private var isoThreshold = 3200
    @AppStorage("batch.isoKeepersOnly") private var isoKeepersOnly = true
    /// JPG 导出长边 (0 = 原尺寸)。
    @AppStorage("batch.jpegMaxPixel") private var jpegMaxPixel = 0
    /// ⌘ 选中恰好 2 张时的任意对比。
    @State private var showComparePair = false
    /// 网格实际宽度 — ↑/↓ 换行导航需要估算列数。
    @State private var gridWidth: CGFloat = 800

    enum GridMode: String, CaseIterable {
        case byVerdict = "按判决"
        case byGroup = "按分组"
    }
    /// 按分组 = Aftershoot-style stacks: one cover per burst group, expand by
    /// opening the inspector (its 同组 strip does the within-group picking).
    @AppStorage("batch.gridMode") private var gridMode: GridMode = .byVerdict
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
    @State private var showStatsPopover = false
    /// Fullscreen review: one big photo + filmstrip, digit-verdicts auto-advance.
    @State private var reviewMode = false
    /// The grid order FROZEN when the inspector / review mode opened. Paging
    /// used to follow the live `visibleItems`: re-judging a photo moved it to
    /// another section (or out of the filtered list), so → jumped into the
    /// reject section or the arrows died. Trash intersects this with the live
    /// ids; a session switch clears it.
    @State private var pagingOrder: [String] = []

    var body: some View {
        Group {
            if reviewMode {
                ReviewView(store: store, orderIDs: pagingOrder,
                           focusedID: $focusedID, reviewMode: $reviewMode)
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
                        Divider()
                        controlPanel
                            .frame(width: 300)
                    }
                    Divider()
                    statusBar
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { inspectedID != nil },
            set: { if !$0 { inspectedID = nil } }
        )) {
            if let id = inspectedID {
                PhotoInspector(store: store, inspectedID: $inspectedID,
                               gridOrder: pagingOrder, initialID: id)
            }
        }
        // 换了一场拍摄就把选择/焦点全部丢掉。留着的话批量改判栏还显示"已选 3 张"，
        // 点下去会把判决写进新场次里根本不存在的 id（同名文件则改判错照片）。
        .onChange(of: store.photoDir) {
            selectedIDs = []
            focusedID = nil
            inspectedID = nil
            pagingOrder = []
        }
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
        .sheet(isPresented: $showComparePair) {
            ComparePairSheet(
                store: store,
                ids: store.items.filter { selectedIDs.contains($0.id) }.map(\.id),
                isPresented: $showComparePair
            )
        }
        .confirmationDialog(
            "把 \(store.recommendationSummary.takes) 场按推荐定案？",
            isPresented: $showAcceptAllConfirm
        ) {
            Button("定案 · \(store.recommendationSummary.rejects) 张设为废片") {
                withAnimation { store.acceptAllRecommendations() }
                selectedIDs.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("每个有精选的待处理场：精选留下，其余可用设为废片。你手动改判过的照片不动。整个操作 ⌘Z 一次撤销。")
        }
        .confirmationDialog(
            "把 \(store.verdictCounts.reject) 张废片移到废纸篓？",
            isPresented: $showTrashConfirm
        ) {
            Button("移到废纸篓", role: .destructive) { store.trashRejects() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原图 (RAW+JPG 成对一起) 和 XMP 会移到系统废纸篓，可随时恢复，不是永久删除。")
        }
        .confirmationDialog(
            "清除全部 \(store.recentSessions.count) 条历史记录？",
            isPresented: $showClearRecentsConfirm
        ) {
            Button("清除", role: .destructive) { store.clearRecentSessions() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将释放约 \(BatchStore.sizeText(store.totalSessionBytes)) 磁盘空间。" +
                 "只删除这些拍摄的缓存分析结果 (预览图/判决/人工改判)，照片本身不动。重新打开这些文件夹需要再分析一次。")
        }
    }

    // MARK: - Top bar (workflow-ordered: source → analyze → view → review → export)

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("选择文件夹...") { pickFolder() }
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
            .frame(maxWidth: 260)
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
                Button("开始分析") { store.runAnalysis() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.photoDir == nil)
                    .help("原生引擎分析全部照片 (锐度/闭眼/曝光/连拍分组)")
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
                ForEach(Verdict.allCases, id: \.self) { v in
                    Text(v.rawValue).tag(Verdict?.some(v))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Picker("排序", selection: $store.sortOrder) {
                ForEach(BatchStore.SortOrder.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("网格内的顺序：按拍摄时间 (双机位混排也按时间) 或按文件名")

            Spacer()

            Button("撤销") { store.undoLastOverride() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndoOverride)
                .help("撤销上一次改判 (⌘Z)")
            Button("全选") { selectedIDs = Set(visibleItems.map(\.id)) }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(store.items.isEmpty)
                .help("选中当前筛选下的全部照片 (⌘A)，配合批量栏一次改判")
            Button("审片模式") { enterReview() }
                .keyboardShortcut("f", modifiers: [])
                .disabled(store.items.isEmpty)
                .help("全屏逐张审片 · F 进入 · 1精选 2可用 3废片 0恢复")
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
                Menu("导出选片确认表 (HTML)") {
                    Button("仅精选 (\(store.verdictCounts.pick))...") {
                        exportContactSheet(includeUsable: false)
                    }
                    .disabled(store.verdictCounts.pick == 0)
                    Button("精选 + 可用 (\(store.verdictCounts.pick + store.verdictCounts.usable))...") {
                        exportContactSheet(includeUsable: true)
                    }
                    .disabled(store.verdictCounts.pick + store.verdictCounts.usable == 0)
                }
                .disabled(store.isRunning)
                Divider()
                Button("废片移到废纸篓 (\(store.verdictCounts.reject))", role: .destructive) {
                    showTrashConfirm = true
                }
                .disabled(store.verdictCounts.reject == 0 || store.isRunning)
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
                if store.pendingTakeCount > 0 {
                    Text("待处理 \(store.pendingTakeCount) 场 · D 跳下一场")
                        .font(.caption).foregroundStyle(.orange)
                        .help("还留着 2 张以上没淘汰的场。按 D 跳到下一个")
                }
                if !store.overrides.isEmpty {
                    Text("人工改判 \(store.overrides.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.unparsedCount > 0 {
                // Photos the engine couldn't read are invisible in the grid;
                // without this the folder silently has more photos than shown.
                Label("\(store.unparsedCount) 张未能解析", systemImage: "questionmark.square.dashed")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help("文件夹里有 \(store.unparsedCount) 张照片无法解码 (文件损坏、格式不支持或分析时还在拷贝)，不在网格中。修复后重新分析即可")
            }
            ForEach(store.chapterWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help(warning)
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
                .help("缩略图大小")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - JPG export sheet

    private var jpegExportSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出 JPG").font(.headline)
            Toggle("包含可用 (关闭则仅导出精选)", isOn: $jpegIncludeUsable)
            Picker("尺寸", selection: $jpegMaxPixel) {
                Text("长边 2048 (选片/微信)").tag(2048)
                Text("长边 4096 (屏幕交付)").tag(4096)
                Text("原尺寸").tag(0)
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("质量")
                Slider(value: $jpegQuality, in: 60...100, step: 5)
                Text("\(Int(jpegQuality))").monospacedDigit().frame(width: 30)
            }
            Toggle("覆盖已存在的同名文件", isOn: $jpegOverwrite)
                .help("关闭时已有的文件跳过不动 (防止误点第二次或覆盖客户已精修的文件)")
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
        .frame(width: 420)
    }

    // MARK: - 精华 Top N sheet

    private var highlightsSheet: some View {
        let top = store.topPicks(highlightsCount)
        return VStack(alignment: .leading, spacing: 14) {
            Text("精华 Top N").font(.headline)
            Text("全场评分最高的 N 张（表情 > 人脸质量 > 锐度），精选优先、不够从可用里补。当天发客户/朋友圈的那一把。")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("张数：\(highlightsCount)", value: $highlightsCount, in: 5...100, step: 5)
            Picker("尺寸", selection: $highlightsMaxPixel) {
                Text("长边 2048 (微信)").tag(2048)
                Text("长边 4096").tag(4096)
                Text("原尺寸").tag(0)
            }
            .pickerStyle(.radioGroup)
            Text(top.fromUsable > 0
                 ? "精选只有 \(top.ids.count - top.fromUsable) 张，从可用里按评分补了 \(top.fromUsable) 张"
                 : "共 \(top.ids.count) 张，全部来自精选")
                .font(.caption).foregroundStyle(top.fromUsable > 0 ? .orange : .secondary)
            Text("导出到 拍摄文件夹/\(ImageLoader.jpegExportSubfolder)/精华/ · 已存在的同名文件跳过")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("取消") { showHighlightsSheet = false }
                Button("导出 \(top.ids.count) 张") {
                    showHighlightsSheet = false
                    guard let base = store.defaultJPEGExportFolder else { return }
                    store.exportJPEGs(to: base.appendingPathComponent("精华"), includeUsable: true,
                                      quality: jpegQuality, maxPixel: highlightsMaxPixel == 0 ? nil : highlightsMaxPixel,
                                      overwrite: false, ids: Set(top.ids))
                }
                .buttonStyle(.borderedProminent)
                .disabled(top.ids.isEmpty || store.defaultJPEGExportFolder == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
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
            // 每场一行、行内按拍摄顺序 —— 键盘 ←/→ 和检视器翻页走的就是这个顺序。
            return groupedItems.flatMap(\.members)
        }
        let ordered = [Verdict.pick, .usable, .reject].flatMap { sectionItems($0) }
        guard let filter = store.verdictFilter else { return ordered }
        return ordered.filter { $0.verdict == filter }
    }

    /// 每场一行的数据。分组本身在 store 的 Derived 里算好（takeRows），这里只做
    /// 筛选：以前这是个计算属性，每次按键都对全部照片 Dictionary(grouping:) + 排序。
    private var groupedItems: [(group: Int, members: [BatchItem])] {
        let items = store.items
        return store.takeRows.compactMap { row in
            // 下标是上次 rebuildDerived 时的；items 换掉但还没重算的那一帧，靠这个
            // 守卫别把照片画进错的场（和 item(withID:) 里那道守卫同一套约定）。
            var members = row.indices.compactMap { idx -> BatchItem? in
                guard idx < items.count, items[idx].take == row.take else { return nil }
                return items[idx]
            }
            if pendingTakesOnly, members.filter({ $0.verdict != .reject }).count < 2 { return nil }
            if let filter = store.verdictFilter { members = members.filter { $0.verdict == filter } }
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
                    chapterTimeline(proxy)
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
            .onKeyPress(.return) { openFocused(); return .handled }
            .onKeyPress(characters: .init(charactersIn: "1230")) { press in
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.setOverrideBatch(targets, verdict)
                }
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
        pagingOrder = visibleItems.map(\.id)
        reviewMode = true
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
            Text("点击=选中 · 空格=大图 · F=审片 · ←/→=移动 · 1精选 2可用 3废片 0恢复 · ⌘点击=多选 · ⇧点击=连选 · 按分组=每场一行，点场标题选整场")
                .font(.caption2).foregroundStyle(.tertiary)
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

    private var groupToolbar: some View {
        let stats = store.takeStats
        let rec = store.recommendationSummary
        return HStack(spacing: 10) {
            if store.pendingTakeCount > 0 {
                Label("待处理 \(store.pendingTakeCount) 场", systemImage: "rectangle.stack.badge.person.crop")
                    .font(.caption).foregroundStyle(.orange)
                Text("D 下一场").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Label("没有待处理的场", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            }
            Divider().frame(height: 14)
            Toggle("只看待处理", isOn: $pendingTakesOnly)
                .toggleStyle(.button).controlSize(.small)
                .help("只显示还留着 2 张以上没淘汰的场 —— 定完一场它就自动消失。这场共 \(stats.takes) 个多张场、\(stats.photos) 张")
            Toggle("场内按评分", isOn: $takeSortByScore)
                .toggleStyle(.button).controlSize(.small)
                .help("每场里评分高的排前面 (表情 > 人脸质量 > 锐度)；关掉则按拍摄顺序。缩略图上的 #1 #2 #3 是同一把尺子")
            Spacer()
            Button("全部只留精选" + (rec.takes > 0 ? " (\(rec.takes) 场 · \(rec.rejects) 张废片)" : "")) {
                showAcceptAllConfirm = true
            }
            .controlSize(.small)
            .disabled(rec.takes == 0)
            .help("一键接受算法的推荐：每个有精选的待处理场，精选留下、其余可用设为废片。你手动标过可用的不动。⌘Z 一次全部撤销")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            Text("已选 \(selectedIDs.count) 张 → 批量改判:")
            ForEach(Verdict.allCases, id: \.self) { v in
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
            // 2–4 张：从一场 10 张里挑最好的，通常是 3–4 张决赛圈的事，只能比 2 张不够用。
            if (2...4).contains(selectedIDs.count) {
                Divider().frame(height: 16)
                Button("并排对比这 \(selectedIDs.count) 张") { showComparePair = true }
                    .buttonStyle(.bordered)
                    .help("并排对比选中的 \(selectedIDs.count) 张 (不限同场)，为每张分别改判")
            }
            Spacer()
            Button("取消选择") { selectedIDs.removeAll() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Chapter timeline (跨章节导航 + 覆盖保护可视化)

    /// One segment per shooting chapter, width ∝ photo count, colored by verdict
    /// makeup — a chapter culled to nothing shows as a solid red block instead
    /// of a status-bar sentence. Click to jump the grid there.
    private func chapterTimeline(_ proxy: ScrollViewProxy) -> some View {
        let segments = store.chapterSegments
        let total = max(1, segments.reduce(0) { $0 + $1.count })
        return GeometryReader { geo in
            HStack(alignment: .top, spacing: 2) {
                ForEach(segments) { seg in
                    let width = max(46, (geo.size.width - CGFloat(segments.count - 1) * 2)
                                        * CGFloat(seg.count) / CGFloat(total))
                    VStack(spacing: 2) {
                        HStack(spacing: 0) {
                            if seg.pick > 0 {
                                Rectangle().fill(.green)
                                    .frame(width: width * CGFloat(seg.pick) / CGFloat(seg.count))
                            }
                            if seg.usable > 0 {
                                Rectangle().fill(.blue)
                                    .frame(width: width * CGFloat(seg.usable) / CGFloat(seg.count))
                            }
                            if seg.reject > 0 { Rectangle().fill(.red) }
                        }
                        .frame(width: width, height: 7)
                        .clipShape(Capsule())
                        Text(seg.timeRange.isEmpty ? "章节\(seg.chapter + 1) · \(seg.count)"
                                                   : "\(seg.timeRange) · \(seg.count)")
                            .font(.caption2).monospacedDigit().lineLimit(1)
                            .foregroundStyle(seg.allRejected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    .frame(width: width)
                    .contentShape(Rectangle())
                    .help("章节\(seg.chapter + 1) \(seg.timeRange) · 共\(seg.count) · 精选\(seg.pick) 可用\(seg.usable) 废片\(seg.reject)"
                          + (seg.allRejected ? " ⚠️ 全部被淘汰" : seg.underMin ? " ⚠️ 低于最少保留" : ""))
                    .onTapGesture {
                        if let target = visibleItems.first(where: { $0.chapter == seg.chapter }) {
                            focusedID = target.id
                            withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 10)
        .padding(.top, 6)
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
        let rows = groupedItems
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
            row.members.filter { $0.verdict != .reject }.count > 1
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

    // MARK: 按分组 (每场一行)

    /// 每场一行，本场全部照片横向铺开（放不下自动换行）。不弹窗：以前是堆栈封面
    /// + 7px 小点，看不出任何能帮你做决定的东西，每场都得双击进 1240×880 的弹窗
    /// 再 Esc 出来，一场婚礼 200 个场就是 200 次进出。现在所有照片都在网格里，
    /// 点击 / ⌘点击 / 数字键直接作用在照片上，批量栏的「保留选中·其余废片」就是定案。
    private var groupGrid: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(groupedItems, id: \.group) { entry in
                takeRow(entry.group, members: entry.members)
            }
        }
    }

    private static let takeTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    @ViewBuilder
    private func takeRow(_ take: Int, members: [BatchItem]) -> some View {
        let alive = members.filter { $0.verdict != .reject }
        let picks = members.filter { $0.verdict == .pick }
        let pending = alive.count > 1
        let allSelected = members.allSatisfy { selectedIDs.contains($0.id) }
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
                        Text("\(members.count) 张").font(.caption).foregroundStyle(.secondary)
                        if let range = Self.timeRange(members) {
                            Text(range).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(allSelected ? "取消选中这一场" : "选中这一场的全部 \(members.count) 张")

                if members.count > 1 {
                    Text(pending ? "待处理 · 还剩 \(alive.count) 张" : (picks.isEmpty ? "已定" : "已定 · 精选 \(picks.count)"))
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(pending ? Color.orange.opacity(0.25) : Color.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(pending ? .orange : .green)
                }
                if pending {
                    Button("选可用 \(alive.count)") {
                        alive.forEach { selectedIDs.insert($0.id) }
                    }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(Color.accentColor)
                    .help("选中本场还没淘汰的 \(alive.count) 张，再 ⌘点击去掉要留的，批量栏一键定案")
                }
                Spacer()
                // 一键接受算法的精选：精选留下，本场其余全废。快速过场用的。
                if pending, !picks.isEmpty, alive.count > picks.count {
                    Button("只留精选 · 其余 \(alive.count - picks.count) 张废片") {
                        withAnimation { store.keepOnly(picks.map(\.id), among: members.map(\.id)) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("接受本场当前的精选，其余 \(alive.count - picks.count) 张设为废片。⌘Z 一次撤销")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(members) { member in
                    // groupSize 1：行头已经写了张数，缩略图上再贴 ×N 就重复了。
                    thumbnailCell(member, color: member.verdict.color, groupSize: 1)
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

    private static func timeRange(_ members: [BatchItem]) -> String? {
        let times = members.compactMap(\.captureTime)
        guard let first = times.min(), let last = times.max() else { return nil }
        let a = takeTimeFormatter.string(from: first)
        return first == last ? a : "\(a)–\(takeTimeFormatter.string(from: last))"
    }

    /// 两条角标各一个 tooltip，代替以前每个小图标各挂一个（一格 8 个 .help）。
    static func statusHelp(rank: Int?, manual: Bool, pick: Bool, groupSize: Int) -> String {
        var parts: [String] = []
        if let rank { parts.append("本场评分第 \(rank)") }
        if manual { parts.append("人工改判") }
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
                        thumbnailCell(item, color: color, groupSize: takeSizes[item.take] ?? 1)
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
                    let manual = store.overrides[item.id] != nil
                    if rank != nil || manual || item.verdict == .pick || groupSize > 1 {
                        HStack(spacing: 4) {
                            if let rank {
                                Text("#\(rank)").font(.caption2).bold().monospacedDigit()
                                    .foregroundStyle(rank == 1 ? Color.white : Color.white.opacity(0.6))
                            }
                            if manual { Image(systemName: "hand.raised.fill").font(.caption2) }
                            if item.verdict == .pick {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Verdict.pick.color)
                            }
                            if groupSize > 1 { Text("×\(groupSize)").font(.caption2).bold() }
                        }
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                        .help(Self.statusHelp(rank: rank, manual: manual, pick: item.verdict == .pick, groupSize: groupSize))
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
        // gesture + simultaneousGesture instead of two onTapGestures: the latter
        // makes SwiftUI hold every single click ~300ms to rule out a double —
        // that was the visible lag on selection. Simultaneous recognition fires
        // the single click instantly; during a double-click the first click just
        // sets focus (harmless) and the second opens the inspector.
        .gesture(TapGesture(count: 2).onEnded { openInspector(item.id) })
        .simultaneousGesture(TapGesture().onEnded {
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

    private func pickFolder() {
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

    private func exportContactSheet(includeUsable: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "选片确认_\(store.photoDir?.lastPathComponent ?? "").html"
        if let htmlType = UTType(filenameExtension: "html") {
            panel.allowedContentTypes = [htmlType]
        }
        if panel.runModal() == .OK, let url = panel.url {
            store.exportContactSheet(to: url, includeUsable: includeUsable)
        }
    }

    private var jpegExportCount: Int {
        let counts = store.verdictCounts
        return counts.pick + (jpegIncludeUsable ? counts.usable : 0)
    }

    /// nil = ask for a folder; otherwise export straight into it.
    private func exportJPEGs(to target: URL?) {
        var folder = target
        if folder == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "导出到此文件夹"
            panel.directoryURL = store.photoDir
            guard panel.runModal() == .OK, let url = panel.url else { return }
            folder = url
        }
        guard let folder else { return }
        store.exportJPEGs(to: folder, includeUsable: jpegIncludeUsable,
                          quality: jpegQuality / 100.0,
                          maxPixel: jpegMaxPixel > 0 ? jpegMaxPixel : nil,
                          overwrite: jpegOverwrite)
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

/// Capture One / Lightroom 那套"屏幕输出锐化"管线：Lanczos 精确缩到取景区的
/// **设备像素**尺寸，再过一次轻量 unsharp mask。
///
/// 缩小本身必然让图变软，这是数学上的事；C1 的 Output Sharpening、LR 的
/// "屏幕输出锐化"、PS 的 Bicubic Sharper 全是"缩完补一刀"。以前我们把 4096 的
/// 解码交给合成器随手缩，既没有 Lanczos 也没有这一刀，看着就是不如 C1 精神。
enum SharpRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// 半径按设备像素算：0.8px / 0.4 是 LR "屏幕·标准" 那档的量，只提边缘不出光晕。
    static let unsharpRadius = 0.8
    static let unsharpIntensity = 0.4

    /// 目标长边按 256 取整：窗口拖一像素不该重渲染，检视器和审片的取景区大小
    /// 接近时也能共用同一张。
    static func bucket(_ devicePixels: CGFloat) -> Int {
        max(256, Int((devicePixels / 256).rounded(.up)) * 256)
    }

    /// 只缩不放：源图比目标小时按原尺寸只做锐化，绝不把图放大来凑。
    static func render(_ source: NSImage, longEdge: Int) -> NSImage? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, CGFloat(longEdge) / max(w, h))
        let extent = CGRect(x: 0, y: 0, width: (w * scale).rounded(), height: (h * scale).rounded())
        var image = CIImage(cgImage: cg)
        if scale < 1 {
            guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
            // clampedToExtent：Lanczos 采样会越过边界，不钳住的话四周一圈发暗。
            lanczos.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            lanczos.setValue(scale, forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard let scaled = lanczos.outputImage else { return nil }
            image = scaled.cropped(to: extent)
        }
        guard let usm = CIFilter(name: "CIUnsharpMask") else { return nil }
        usm.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        usm.setValue(unsharpRadius, forKey: kCIInputRadiusKey)
        usm.setValue(unsharpIntensity, forKey: kCIInputIntensityKey)
        guard let sharpened = usm.outputImage?.cropped(to: extent),
              let out = context.createCGImage(sharpened, from: extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }
}

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

    final class Coordinator: NSObject {
        weak var scroll: NSScrollView?
        var overlayLayer: CALayer?
        var maskLayer: CALayer?

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

        context.coordinator.scroll = scroll
        // Bounds are zero until layout — apply the entry magnification after
        // the first pass.
        DispatchQueue.main.async { self.applyEntry(scroll) }
        syncOverlay(context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let imageView = scroll.documentView as? NSImageView, imageView.image !== image {
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            DispatchQueue.main.async { self.applyEntry(scroll) }
        }
        syncOverlay(context.coordinator)
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
        // Centered on the image middle; the user pans/zooms from there.
        if let doc = scroll.documentView {
            scroll.setMagnification(
                target,
                centeredAt: NSPoint(x: doc.frame.midX, y: doc.frame.midY))
        } else {
            scroll.magnification = target
        }
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
        return await decode(path: decodePath)
    }
}

/// One face close-up with an eye-state ring: green = eyes open, red = closed,
/// gray = undeterminable. The whole point is that the photographer never has to
/// zoom manually just to check eyes.
struct FaceCropView: View {
    let previewPath: String
    let decodePath: String
    let face: FaceInfo

    @State private var crop: NSImage?

    private var ringColor: Color {
        switch face.eyeClosed {
        case .some(true): return .red
        case .some(false): return .green
        case .none: return .gray
        }
    }

    var body: some View {
        Group {
            if let crop {
                Image(nsImage: crop).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.gray.opacity(0.2))
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ringColor, lineWidth: 3))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: face.eyeClosed == true ? "eye.slash.fill" : "eye.fill")
                .font(.caption2)
                .padding(2)
                .background(.black.opacity(0.6), in: Circle())
                .foregroundStyle(ringColor)
                .padding(2)
        }
        .task(id: decodePath + face.bbox.description) {
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
                guard let cropped = cg.cropping(to: rect) else { return nil }
                return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
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
    @State private var compareOn = false
    /// 场内定案的勾选集：⌘点击「同场」缩略条勾/取消，再按「保留勾选」把同场其余
    /// 全部设为废片。换场就清空 —— 留着会把上一场的勾选算进这一场的定案里。
    @State private var keepSet: Set<String> = []
    /// 对焦高亮开关 + 当前这张的遮罩（带 key，翻页不串图）。
    @State private var focusPeak = false
    @State private var focusMask: (key: String, image: CGImage)?

    init(store: BatchStore, inspectedID: Binding<String?>, gridOrder: [String], initialID: String) {
        self.store = store
        self._inspectedID = inspectedID
        self.gridOrder = gridOrder
        self._currentID = State(initialValue: initialID)
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

    /// The comparison partner: the take's pick if that's not the current photo,
    /// else the next member — "challenger vs incumbent" is the decision
    /// photographers actually make inside a take.
    private func compareTarget(_ item: BatchItem) -> BatchItem? {
        let members = groupMembers(item).filter { $0.id != item.id }
        guard !members.isEmpty else { return nil }
        return members.first { $0.verdict == .pick } ?? members.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                header(item)
                Group {
                    if compareOn, let other = compareTarget(item) {
                        comparePane(item, other)
                    } else {
                        imagePane(item)
                    }
                }
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
        .onChange(of: item?.take) { keepSet = [] }
        .onChange(of: focusPeak) { refreshFocusMask() }
        .onChange(of: zoomed) { refreshFocusMask() }
        .onChange(of: currentID) { refreshFocusMask() }
        // 废纸篓清掉的 id 还留在勾选里的话，定案会写到不存在的照片上。
        .onChange(of: store.items.count) {
            keepSet.formIntersection(Set(store.items.map(\.id)))
        }
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
            if compareTarget(item) != nil {
                Toggle("并排对比", isOn: $compareOn).toggleStyle(.button)
                    .keyboardShortcut("c", modifiers: [])
            }
            Toggle("分析框", isOn: $showOverlay).toggleStyle(.button)
            Toggle("对焦高亮", isOn: $focusPeak).toggleStyle(.button)
                .keyboardShortcut("p", modifiers: [])
                .disabled(!zoomed)
                .help("100% 视图上红色标出合焦区域（本图梯度 95 分位以上），看焦点落在眼睛还是耳朵 (P)")
            Button(zoomed ? "适应窗口" : (loadingFullRes ? "解码原图..." : "放大 100%")) {
                toggleZoom(item)
            }
            .disabled(loadingFullRes || compareOn)
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

    private func comparePane(_ item: BatchItem, _ other: BatchItem) -> some View {
        HStack(spacing: 2) {
            comparisonSide(item, label: "当前")
            comparisonSide(other, label: other.verdict == .pick ? "组内精选" : "组内另一张")
        }
        .background(Color.black)
    }

    private func comparisonSide(_ item: BatchItem, label: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(label) · \(item.id)").font(.caption).foregroundStyle(.white)
                Text(item.verdict.rawValue).font(.caption2)
                    .padding(.horizontal, 5)
                    .background(verdictColor(item.verdict).opacity(0.4), in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.top, 6)
            SharpImageView(previewPath: item.previewPath, decodePath: item.decodePath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Text("锐度 \(Int(item.sharpness))")
                if let q = item.faceQuality { Text(String(format: "质量 %.2f", q)) }
                if let e = item.expressionScore { Text("表情 \(e)") }
            }
            .font(.caption2).foregroundStyle(.white.opacity(0.8))
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
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

    /// 同一场的全部照片；点击切换，当前那张高亮。
    private func groupStrip(_ item: BatchItem, members: [BatchItem]) -> some View {
        VStack(spacing: 2) {
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
            groupKeepBar(members)
        }
    }

    /// 一张同组照片。点击切过去看，⌘点击把它勾进/踢出"要保留的"。
    private func groupStripCell(_ member: BatchItem) -> some View {
        let kept = keepSet.contains(member.id)
        return VStack(spacing: 1) {
            // 整图 fit：这一条正是挑选发生的地方，竖拍被裁掉一半就没法挑。
            ThumbnailView(path: member.previewPath, fit: true)
                .frame(width: 72, height: 72)
                .background(Color(white: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(member.id == currentID ? Color.accentColor : verdictColor(member.verdict),
                                lineWidth: member.id == currentID ? 3 : 1.5)
                )
                .overlay(alignment: .topLeading) {
                    if kept {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .background(Circle().fill(.white))
                            .padding(2)
                    }
                }
                .opacity(keepSet.isEmpty || kept ? 1 : 0.45)
            Text(member.verdict.rawValue).font(.caption2)
                .foregroundStyle(verdictColor(member.verdict))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                toggleKeep(member.id)
            } else {
                currentID = member.id
            }
        }
        .help("点击=看这张 · ⌘点击=勾选保留")
    }

    private func toggleKeep(_ id: String) {
        if keepSet.contains(id) { keepSet.remove(id) } else { keepSet.insert(id) }
    }

    /// 场内定案条。以前这里只能一张一张点开按 1/2/3 —— 一场 8 张要按 8 次，
    /// 还得自己记住哪几张已经判过了。
    @ViewBuilder
    private func groupKeepBar(_ members: [BatchItem]) -> some View {
        let ids = members.map(\.id)
        let keep = keepSet.intersection(ids)
        let drop = ids.count - keep.count
        HStack(spacing: 8) {
            Button(keepSet.contains(currentID) ? "取消保留这张 (K)" : "保留这张 (K)") {
                toggleKeep(currentID)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("k", modifiers: [])
            if keep.isEmpty {
                Text("⌘点击缩略图勾选要留的，其余一键设为废片")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Button("保留勾选 \(keep.count) 张 · 其余 \(drop) 张废片 (⏎)") {
                    store.keepOnly(keep, among: ids)
                    keepSet = []
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(drop == 0)
                .help("勾选的定为精选，同场其余 \(drop) 张设为废片。整场算一次改判，⌘Z 一次撤销")
                Button("清空勾选") { keepSet = [] }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 2)
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

// MARK: - Arbitrary two-photo compare (跨组对比)

/// Side-by-side compare of any two ⌘-selected photos — the in-group compare
/// answers "which frame of this burst", this answers "which of these two
/// moments/angles gets delivered".
struct ComparePairSheet: View {
    @ObservedObject var store: BatchStore
    let ids: [String]
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("并排对比").font(.headline)
                Spacer()
                Text("为每张分别改判后关闭")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button("关闭") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            HStack(spacing: 2) {
                ForEach(ids, id: \.self) { id in
                    if let item = store.item(withID: id) {
                        side(item)
                    }
                }
            }
            .background(Color.black)
        }
        .frame(minWidth: 1100, minHeight: 720)
    }

    private func verdictColor(_ v: Verdict) -> Color { v.color }

    private func side(_ item: BatchItem) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(item.id).font(.caption).foregroundStyle(.white)
                Text(item.verdict.rawValue).font(.caption2)
                    .padding(.horizontal, 5)
                    .background(verdictColor(item.verdict).opacity(0.4), in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.top, 6)
            SharpImageView(previewPath: item.previewPath, decodePath: item.decodePath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Text("锐度 \(Int(item.sharpness))")
                if let q = item.faceQuality { Text(String(format: "质量 %.2f", q)) }
                if let e = item.expressionScore { Text("表情 \(e)") }
                if let exif = item.exif { Text(exif.summary) }
            }
            .font(.caption2).foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 6) {
                let override = store.overrides[item.id]
                Button("精选") { store.setOverride(item.id, .pick) }
                    .buttonStyle(.bordered)
                    .tint(override == .pick ? .green : nil)
                Button("可用") { store.setOverride(item.id, .usable) }
                    .buttonStyle(.bordered)
                    .tint(override == .usable ? .blue : nil)
                Button("废片") { store.setOverride(item.id, .reject) }
                    .buttonStyle(.bordered)
                    .tint(override == .reject ? .red : nil)
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
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
    @Binding var focusedID: String?
    @Binding var reviewMode: Bool
    /// In-flow focus check: Z / double-click / pinch opens the full-res ZoomPane
    /// right here — no detour through the inspector and back.
    @State private var zoomed = false
    @State private var zoomImage: NSImage?
    @State private var loadingZoom = false
    @State private var focusPeak = false
    @State private var focusMask: (key: String, image: CGImage)?

    private var currentIndex: Int {
        guard let id = focusedID, let idx = orderIDs.firstIndex(of: id) else { return 0 }
        return idx
    }

    private var current: BatchItem? {
        guard !orderIDs.isEmpty else { return nil }
        return store.item(withID: orderIDs[min(currentIndex, orderIDs.count - 1)])
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = current {
                HStack {
                    Text("\(currentIndex + 1) / \(orderIDs.count)").monospacedDigit()
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
                    Spacer()
                    Text("1精选 2可用 3废片(自动下一张) · 0恢复 · Z放大 · ⌘Z撤销 · ←/→ · Esc退出")
                        .font(.caption2).foregroundStyle(.tertiary)
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
                        .onTapGesture(count: 2) { toggleZoom(item) }
                        .gesture(
                            MagnifyGesture().onEnded { value in
                                if value.magnification > 1.1 { toggleZoom(item) }
                            }
                        )
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // Lazy: a plain HStack instantiated every photo in the
                        // shoot the moment review mode opened — 3000 cells each
                        // firing a decode at once, and each holding its NSImage
                        // in @State where the cache byte limits can't reclaim it.
                        LazyHStack(spacing: 4) {
                            ForEach(orderIDs, id: \.self) { memberID in
                                if let member = store.item(withID: memberID) {
                                ThumbnailView(path: member.previewPath, maxPixel: 256, fit: true)
                                    .frame(width: 72, height: 72)
                                    .background(Color(white: 0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(member.id == item.id ? Color.accentColor : color(member.verdict),
                                                    lineWidth: member.id == item.id ? 3 : 1.5)
                                    )
                                    .id(member.id)
                                    .onTapGesture { focusedID = member.id }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 88)
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
            if focusedID == nil {
                if let last = store.lastReviewedID, orderIDs.contains(last) {
                    focusedID = last
                } else {
                    focusedID = orderIDs.first
                }
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
        .onKeyPress(characters: .init(charactersIn: "zZ")) { press in
            // Bare Z only: ⌘Z is the undo shortcut on the button above and
            // must not also toggle the zoom.
            guard press.modifiers.isSubset(of: [.shift, .capsLock]) else { return .ignored }
            if let item = current { toggleZoom(item) }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "1230")) { press in
            guard let item = current else { return .ignored }
            switch press.characters {
            case "1": store.setOverride(item.id, .pick)
            case "2": store.setOverride(item.id, .usable)
            case "3": store.setOverride(item.id, .reject)
            default: store.setOverride(item.id, nil)
            }
            if press.characters != "0" { step(1) }  // tag-and-advance
            return .handled
        }
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
        let next = currentIndex + delta
        if orderIDs.indices.contains(next) {
            focusedID = orderIDs[next]
        }
    }

    /// Warm the 1600px decode of the neighbors while the current photo is on
    /// screen — advancing with → hits the cache instead of a visible decode.
    private func prefetchNeighbors() {
        let idx = currentIndex
        for offset in [1, -1, 2] {
            let n = idx + offset
            guard orderIDs.indices.contains(n), let neighbor = store.item(withID: orderIDs[n]) else { continue }
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
