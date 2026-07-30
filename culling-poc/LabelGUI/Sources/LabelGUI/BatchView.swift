import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BatchView: View {
    @ObservedObject var store: BatchStore
    @State private var inspectedID: String?
    /// ⌘-click multi-selection for batch verdict changes.
    @State private var selectedIDs: Set<String> = []
    /// Keyboard focus in the grid: ←/→ move it, space opens the inspector,
    /// 1/2/3/0 apply verdicts without opening anything.
    @State private var focusedID: String?
    @State private var thumbSize: Double = 140
    @State private var showTrashConfirm = false
    /// JPG 交付导出设置 (Capture One 式质量档)。
    @State private var jpegQuality: Double = 90
    @State private var jpegIncludeUsable = true
    @State private var showJPEGSheet = false
    /// 高ISO RAW 导出 (降噪流程)。
    @State private var showISOSheet = false
    @State private var isoThreshold = 3200
    @State private var isoKeepersOnly = true

    enum GridMode: String, CaseIterable {
        case byVerdict = "按判决"
        case byGroup = "按分组"
    }
    /// 按分组 = Aftershoot-style stacks: one cover per burst group, expand by
    /// opening the inspector (its 同组 strip does the within-group picking).
    @State private var gridMode: GridMode = .byVerdict
    @State private var showStatsPopover = false
    /// Fullscreen review: one big photo + filmstrip, digit-verdicts auto-advance.
    @State private var reviewMode = false

    var body: some View {
        Group {
            if reviewMode {
                ReviewView(store: store, visibleItems: visibleItems,
                           focusedID: $focusedID, reviewMode: $reviewMode)
            } else {
                VStack(spacing: 0) {
                    topBar
                    Divider()
                    if !selectedIDs.isEmpty {
                        bulkActionBar
                        Divider()
                    }
                    HSplitView {
                        gridArea
                            .frame(minWidth: 500)
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
                PhotoInspector(store: store, inspectedID: $inspectedID, initialID: id)
            }
        }
        .sheet(isPresented: $showJPEGSheet) { jpegExportSheet }
        .sheet(isPresented: $showISOSheet) { isoExportSheet }
        .confirmationDialog(
            "把 \(store.verdictCounts.reject) 张废片移到废纸篓？",
            isPresented: $showTrashConfirm
        ) {
            Button("移到废纸篓", role: .destructive) { store.trashRejects() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原图 (RAW+JPG 成对一起) 和 XMP 会移到系统废纸篓，可随时恢复，不是永久删除。")
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
                        Button("\(session.name) · \(session.photoCount) 张") {
                            store.switchSession(to: URL(fileURLWithPath: session.path))
                        }
                    }
                }
            } label: {
                Label(store.photoDir?.lastPathComponent ?? "选择文件夹",
                      systemImage: "folder")
                    .lineLimit(1)
            }
            .fixedSize()
            .help(store.photoDir?.path ?? "选择一场拍摄的照片文件夹")

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
            if gridMode == .byVerdict {
                Picker("筛选", selection: $store.verdictFilter) {
                    Text("全部").tag(Verdict?.none)
                    ForEach(Verdict.allCases, id: \.self) { v in
                        Text(v.rawValue).tag(Verdict?.some(v))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            Spacer()

            Button("审片模式") { reviewMode = true }
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
                Button("导出高 ISO RAW (降噪)...") { showISOSheet = true }
                    .disabled(store.items.isEmpty || store.isRunning)
                Button("导出选片确认表 (HTML)...") { exportContactSheet() }
                    .disabled(store.verdictCounts.pick == 0 || store.isRunning)
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
                Text("共 \(total) · 精选 \(counts.pick) · 可用 \(counts.usable) · 废片 \(counts.reject) (\(rejectPct)%)")
                    .font(.caption).monospacedDigit()
                if !store.overrides.isEmpty {
                    Text("人工改判 \(store.overrides.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(store.chapterWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help(warning)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .lineLimit(1).help(error)
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
            HStack {
                Text("质量")
                Slider(value: $jpegQuality, in: 60...100, step: 5)
                Text("\(Int(jpegQuality))").monospacedDigit().frame(width: 30)
            }
            Text("共 \(jpegExportCount) 张 · 全尺寸重编码，保留 EXIF")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { showJPEGSheet = false }
                Button("选择文件夹并导出...") {
                    showJPEGSheet = false
                    exportJPEGs()
                }
                .buttonStyle(.borderedProminent)
                .disabled(jpegExportCount == 0)
            }
        }
        .padding(20)
        .frame(width: 360)
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
            return groupedItems.map { Self.groupCover($0.members) }
        }
        let ordered = [Verdict.pick, .usable, .reject].flatMap { v in
            store.items.filter { $0.verdict == v }
        }
        guard let filter = store.verdictFilter else { return ordered }
        return ordered.filter { $0.verdict == filter }
    }

    /// Burst groups in capture order (group ids are assigned chronologically).
    private var groupedItems: [(group: Int, members: [BatchItem])] {
        let dict = Dictionary(grouping: store.items, by: \.burstGroup)
        return dict.keys.sorted().map { ($0, dict[$0]!) }
    }

    /// A stack's cover: the group's pick, else its first member.
    static func groupCover(_ members: [BatchItem]) -> BatchItem {
        members.first { $0.verdict == .pick } ?? members[0]
    }

    // MARK: - Left: results grid (dark canvas — photos judge better on neutral gray)

    private var gridArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.items.isEmpty {
                        emptyState
                    } else if gridMode == .byGroup {
                        groupGrid
                    } else {
                        if store.verdictFilter == nil || store.verdictFilter == .pick {
                            verdictSection(.pick, color: .green)
                        }
                        if store.verdictFilter == nil || store.verdictFilter == .usable {
                            verdictSection(.usable, color: .blue)
                        }
                        if store.verdictFilter == nil || store.verdictFilter == .reject {
                            verdictSection(.reject, color: .red)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(white: 0.13))
            .environment(\.colorScheme, .dark)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { moveFocus(-1, proxy: proxy); return .handled }
            .onKeyPress(.rightArrow) { moveFocus(1, proxy: proxy); return .handled }
            .onKeyPress(.space) { openFocused(); return .handled }
            .onKeyPress(.return) { openFocused(); return .handled }
            .onKeyPress(characters: .init(charactersIn: "1230")) { press in
                guard let id = focusedID else { return .ignored }
                switch press.characters {
                case "1": store.setOverride(id, .pick)
                case "2": store.setOverride(id, .usable)
                case "3": store.setOverride(id, .reject)
                default: store.setOverride(id, nil)
                }
                return .handled
            }
        }
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
            Text("点击=选中 · 空格=大图 · F=审片 · ←/→=移动 · 1精选 2可用 3废片 0恢复 · ⌘点击=多选")
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
        }
        .padding()
        .frame(minWidth: 320)
    }

    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            Text("已选 \(selectedIDs.count) 张 → 批量改判:")
            ForEach(Verdict.allCases, id: \.self) { v in
                Button(v.rawValue) {
                    store.setOverrideBatch(selectedIDs, v)
                    selectedIDs.removeAll()
                }
                .buttonStyle(.bordered)
            }
            Button("恢复自动") {
                store.setOverrideBatch(selectedIDs, nil)
                selectedIDs.removeAll()
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("取消选择") { selectedIDs.removeAll() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
        proxy.scrollTo(next)
    }

    private func openFocused() {
        if let id = focusedID { inspectedID = id }
    }

    // MARK: 按分组 (stack view)

    private var groupGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 10)], spacing: 12) {
            ForEach(groupedItems, id: \.group) { entry in
                groupStackCell(entry.members)
                    .id(Self.groupCover(entry.members).id)
            }
        }
    }

    @ViewBuilder
    private func groupStackCell(_ members: [BatchItem]) -> some View {
        let cover = Self.groupCover(members)
        let isSelected = members.contains { selectedIDs.contains($0.id) }
        let isFocused = focusedID == cover.id
        VStack(spacing: 3) {
            ZStack {
                // Stacked-paper visual behind the cover for multi-shot groups.
                if members.count > 1 {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.gray.opacity(0.35))
                        .frame(height: thumbSize * 0.72)
                        .offset(x: 6, y: -6)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.gray.opacity(0.2))
                        .frame(height: thumbSize * 0.72)
                        .offset(x: 3, y: -3)
                }
                ThumbnailView(path: cover.previewPath)
                    .frame(height: thumbSize * 0.72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // The per-member verdict dots below already tell the group's
                    // fate; the border only marks selection/focus.
                    .overlay {
                        if isSelected || isFocused {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.accentColor, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if members.count > 1 {
                            Text("×\(members.count)").font(.caption2).bold()
                                .padding(3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(3)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .background(Circle().fill(.white))
                                .padding(3)
                        }
                    }
            }
            // One dot per member, colored by its verdict — the group's fate at a glance.
            HStack(spacing: 3) {
                ForEach(members.prefix(10)) { member in
                    Circle()
                        .fill(verdictColorStatic(member.verdict))
                        .frame(width: 7, height: 7)
                }
                if members.count > 10 { Text("…").font(.caption2) }
            }
            Text(cover.id).font(.caption2).lineLimit(1)
        }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { inspectedID = cover.id })
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.command) || !selectedIDs.isEmpty {
                // ⌘-click on a stack toggles the WHOLE group — batch verdicts
                // then apply to every member.
                let ids = members.map(\.id)
                if isSelected {
                    ids.forEach { selectedIDs.remove($0) }
                } else {
                    ids.forEach { selectedIDs.insert($0) }
                }
            } else {
                focusedID = cover.id
            }
        })
    }

    private func verdictColorStatic(_ v: Verdict) -> Color {
        switch v {
        case .pick: return .green
        case .usable: return .blue
        case .reject: return .red
        }
    }

    /// Reject reasons as compact icon badges — the text version wrapped and
    /// cluttered the grid. Full text lives in the tooltip and the inspector.
    static func reasonIcon(_ reason: String) -> String {
        if reason.contains("闭眼") { return "eye.slash" }
        if reason.contains("虚焦") { return "minus.magnifyingglass" }
        if reason.contains("曝光") { return "sun.max.fill" }
        if reason.contains("人脸质量") { return "person.crop.circle.badge.exclamationmark" }
        if reason.contains("VLM") { return "sparkles" }
        return "exclamationmark.triangle"
    }

    @ViewBuilder
    private func verdictSection(_ verdict: Verdict, color: Color) -> some View {
        let matching = store.items.filter { $0.verdict == verdict }
        let groupSizes = store.groupSizes
        if !matching.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(verdict.rawValue).font(.headline)
                    Text("\(matching.count)").font(.headline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)], spacing: 8) {
                    ForEach(matching) { item in
                        thumbnailCell(item, color: color, groupSize: groupSizes[item.burstGroup] ?? 1)
                            .id(item.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnailCell(_ item: BatchItem, color: Color, groupSize: Int) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        let isFocused = focusedID == item.id
        VStack(spacing: 3) {
            ThumbnailView(path: item.previewPath)
                .frame(height: thumbSize * 0.72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Border means ONE thing: selection/keyboard focus. Verdict
                // lives in the caption dot — the grid stops being a christmas
                // tree and the photos' own colors get judged on neutral ground.
                .overlay {
                    if isSelected || isFocused {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        if store.overrides[item.id] != nil {
                            Image(systemName: "hand.raised.fill").font(.caption2)
                        }
                        if groupSize > 1 {
                            Text("×\(groupSize)").font(.caption2).bold()
                        }
                    }
                    .padding(3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(3)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 3) {
                        ForEach(item.rejectReasons, id: \.self) { reason in
                            Image(systemName: Self.reasonIcon(reason)).font(.caption2).foregroundStyle(.red)
                        }
                        // VLM cleared this photo of charges — green seal.
                        if !item.vlmRescued.isEmpty {
                            Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green)
                                .help("VLM 平反: \(item.vlmRescued.joined(separator: "、"))")
                        }
                        // Info-only badges (yellow): not rejections, just heads-ups.
                        if item.slowShutter {
                            Image(systemName: "tortoise.fill").font(.caption2).foregroundStyle(.yellow)
                                .help("快门低于安全快门 (1/焦距)，易糊")
                        }
                        if item.tilted {
                            Image(systemName: "level").font(.caption2).foregroundStyle(.yellow)
                                .help(String(format: "水平线倾斜 %.1f°", item.horizonDeg ?? 0))
                        }
                    }
                    .padding(3)
                    .background((item.rejectReasons.isEmpty && !item.slowShutter && !item.tilted) ? .clear : .black.opacity(0.6), in: Capsule())
                    .padding(3)
                    .help(item.rejectReasons.joined(separator: ", "))
                }
                .overlay(alignment: .topLeading) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(.white))
                            .padding(3)
                    }
                }
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
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
        .gesture(TapGesture(count: 2).onEnded { inspectedID = item.id })
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.command) || !selectedIDs.isEmpty {
                if isSelected {
                    selectedIDs.remove(item.id)
                } else {
                    selectedIDs.insert(item.id)
                }
            } else {
                focusedID = item.id
            }
        })
    }

    // MARK: - Right: controls

    // MARK: - Right panel: thresholds + VLM only. Everything else lives in the
    // top bar / export menu; explanations live in .help tooltips, not captions.

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

                        thresholdSlider(
                            label: "锐度下限",
                            value: "\(Int(store.sharpnessThreshold))",
                            slider: Slider(value: $store.sharpnessThreshold, in: 0...150, step: 5),
                            help: "五官区域梯度锐度，低于此值判为虚焦 → 废片。清晰照片约 65-95"
                        )
                        thresholdSlider(
                            label: "曝光裁切上限",
                            value: String(format: "%.1f%%", store.exposureThreshold * 100),
                            slider: Slider(value: $store.exposureThreshold, in: 0.005...0.5),
                            help: "死白/死黑像素占比超过此值 → 废片"
                        )
                        thresholdSlider(
                            label: "人脸质量下限",
                            value: store.faceQualityThreshold > 0
                                ? String(format: "%.2f", store.faceQualityThreshold) : "关闭",
                            slider: Slider(value: $store.faceQualityThreshold, in: 0...1),
                            help: "特写脸的质量下限;小脸按景别自动放宽，连拍组内改为相对比较。拉到 0 关闭"
                        )
                        Text("拖动实时生效")
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
                        Button("复审废片 (\(autoRejectCount))") { store.runAppealOnRejects() }
                            .buttonStyle(.borderedProminent)
                            .disabled(autoRejectCount == 0 || store.isRunning)
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

    /// One threshold row: name + live value on top, slider below, docs in tooltip.
    private func thresholdSlider(label: String, value: String, slider: Slider<EmptyView, EmptyView>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
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
            // Re-picking an analyzed folder keeps its instant cached results.
            if store.items.isEmpty { store.runAnalysis() }
        }
    }

    private func exportContactSheet() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "选片确认_\(store.photoDir?.lastPathComponent ?? "").html"
        if let htmlType = UTType(filenameExtension: "html") {
            panel.allowedContentTypes = [htmlType]
        }
        if panel.runModal() == .OK, let url = panel.url {
            store.exportContactSheet(to: url, includeUsable: false)
        }
    }

    private var jpegExportCount: Int {
        let counts = store.verdictCounts
        return counts.pick + (jpegIncludeUsable ? counts.usable : 0)
    }

    /// Auto-rejects only — manual rejects are the photographer's word, no appeal.
    private var autoRejectCount: Int {
        store.items.filter { $0.verdict == .reject && store.overrides[$0.id] == nil }.count
    }

    private func exportJPEGs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出到此文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            store.exportJPEGs(to: url, includeUsable: jpegIncludeUsable, quality: jpegQuality / 100.0)
        }
    }
}

// MARK: - Cached async thumbnail

/// Grid cells used to decode the full preview JPEG synchronously in `body` on
/// every appearance — scrolling a few hundred photos stuttered. Decode a small
/// thumbnail off the main thread once and cache it.
enum ThumbCache {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2000
        return c
    }()

    static func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(path)" as NSString
    }

    static func load(path: String, maxPixel: Int = 512) -> NSImage? {
        let cacheKey = key(path, maxPixel)
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: cacheKey)
        return image
    }
}

struct ThumbnailView: View {
    let path: String
    var maxPixel: Int = 512
    var fit: Bool = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
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

// MARK: - Full-res decode cache (inspector zoom)

/// TRUE full-resolution decodes for the inspector's zoom mode. The grid previews
/// are only 1024px and a capped decode hides exactly the eyelash-level focus
/// detail a photographer zooms in to check — so no size cap here (a 40MP frame
/// is ~160MB decoded; the cache keeps only a couple).
enum FullResCache {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2
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
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

// MARK: - Face crop strip

/// Mid-size decodes for face crops: big enough (2560px) that a subject face crop
/// shows real eye detail, cheap enough to produce per photo on the fly.
enum FaceStripCache {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 8
        return c
    }()

    static func decode(path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2560,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// One face close-up with an eye-state ring: green = eyes open, red = closed,
/// gray = undeterminable. The whole point is that the photographer never has to
/// zoom manually just to check eyes.
struct FaceCropView: View {
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
            let bbox = face.bbox
            let result = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard bbox.count == 4,
                      let decoded = FaceStripCache.decode(path: path),
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
    @State var currentID: String
    @State private var zoomed = false
    @State private var fullResImage: NSImage?
    @State private var loadingFullRes = false
    /// Trackpad-pinch zoom factor applied to the full-res decode (1.0 = one image
    /// pixel per physical pixel).
    @State private var zoomScale: CGFloat = 1.0
    @State private var pinchBase: CGFloat?
    @State private var showOverlay = true
    @State private var compareOn = false

    init(store: BatchStore, inspectedID: Binding<String?>, initialID: String) {
        self.store = store
        self._inspectedID = inspectedID
        self._currentID = State(initialValue: initialID)
    }

    private var item: BatchItem? {
        store.items.first { $0.id == currentID }
    }

    /// Navigation order = what the grid shows under the current filter.
    private var visibleIDs: [String] {
        let filtered = store.verdictFilter.map { f in store.items.filter { $0.verdict == f } } ?? store.items
        return filtered.map(\.id)
    }

    private func groupMembers(_ item: BatchItem) -> [BatchItem] {
        store.items.filter { $0.burstGroup == item.burstGroup }
    }

    /// The comparison partner: the group's pick if that's not the current photo,
    /// else the next group member — "challenger vs incumbent" is the decision
    /// photographers actually make inside a burst.
    private func compareTarget(_ item: BatchItem) -> BatchItem? {
        let members = groupMembers(item).filter { $0.id != item.id }
        guard !members.isEmpty else { return nil }
        return members.first { $0.verdict == .pick } ?? members.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                header(item)
                if compareOn, let other = compareTarget(item) {
                    comparePane(item, other)
                } else {
                    imagePane(item)
                }
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
        .frame(minWidth: 960, minHeight: 760)
    }

    // MARK: header

    private func header(_ item: BatchItem) -> some View {
        HStack {
            Text(item.id).font(.headline)
            Text("组 \(item.burstGroup)").foregroundStyle(.secondary)
            Text(item.verdict.rawValue)
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

    private func verdictColor(_ v: Verdict) -> Color {
        switch v {
        case .pick: return .green
        case .usable: return .blue
        case .reject: return .red
        }
    }

    // MARK: image panes

    @ViewBuilder
    private func imagePane(_ item: BatchItem) -> some View {
        Group {
            if zoomed, let full = fullResImage {
                // SwiftUI sizes are in POINTS; on Retina 1pt = 2 physical px.
                // Divide by the backing scale so zoomScale 1.0 means one image
                // pixel per one physical pixel.
                let backing = NSScreen.main?.backingScaleFactor ?? 2.0
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: full)
                        .resizable()
                        .overlay { analysisOverlay(item) }
                        .frame(width: full.size.width * zoomScale / backing,
                               height: full.size.height * zoomScale / backing)
                }
                .background(Color.black)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let base = pinchBase ?? zoomScale
                            pinchBase = base
                            zoomScale = min(2.5, max(0.15, base * value.magnification))
                        }
                        .onEnded { _ in pinchBase = nil }
                )
            } else {
                // Async cached decode — a synchronous NSImage(contentsOfFile:)
                // here blocked the main thread on every open/photo switch.
                ThumbnailView(path: item.previewPath, maxPixel: 1600, fit: true)
                    .overlay { analysisOverlay(item) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .gesture(
                        MagnifyGesture()
                            .onEnded { value in
                                if value.magnification > 1.15 { toggleZoom(item) }
                            }
                    )
            }
        }
        .onTapGesture(count: 2) { toggleZoom(item) }
        .onChange(of: currentID) {
            zoomed = false
            fullResImage = nil
            zoomScale = 1.0
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
            ThumbnailView(path: item.previewPath, maxPixel: 1600, fit: true)
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
                    FaceCropView(decodePath: item.decodePath, face: face)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    /// All shots of the same burst group; click to switch, current highlighted.
    private func groupStrip(_ item: BatchItem, members: [BatchItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("同组").font(.caption2).foregroundStyle(.secondary)
                ForEach(members) { member in
                    VStack(spacing: 1) {
                        ThumbnailView(path: member.previewPath)
                            .frame(width: 76, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(member.id == currentID ? Color.accentColor : verdictColor(member.verdict),
                                            lineWidth: member.id == currentID ? 3 : 1.5)
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
                    Text("组内表情").font(.caption2).foregroundStyle(.secondary)
                    ForEach(withFaces) { member in
                        VStack(spacing: 1) {
                            FaceCropView(decodePath: member.decodePath, face: member.faces[0])
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
        }
    }

    private func toggleZoom(_ item: BatchItem) {
        if zoomed {
            zoomed = false
            return
        }
        if let cached = FullResCache.cache.object(forKey: item.decodePath as NSString) {
            fullResImage = cached
            zoomScale = 1.0
            zoomed = true
            return
        }
        loadingFullRes = true
        let path = item.decodePath
        Task.detached(priority: .userInitiated) {
            let image = FullResCache.load(path: path)
            await MainActor.run {
                loadingFullRes = false
                if let image {
                    fullResImage = image
                    zoomScale = 1.0
                    zoomed = true
                }
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
    let visibleItems: [BatchItem]
    @Binding var focusedID: String?
    @Binding var reviewMode: Bool

    private var currentIndex: Int {
        guard let id = focusedID, let idx = visibleItems.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    private var current: BatchItem? {
        visibleItems.isEmpty ? nil : visibleItems[min(currentIndex, visibleItems.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = current {
                HStack {
                    Text("\(currentIndex + 1) / \(visibleItems.count)").monospacedDigit()
                    Text(item.id).font(.headline)
                    Text(item.verdict.rawValue).font(.caption).bold()
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
                    Text("1精选 2可用 3废片(自动下一张) · 0恢复 · ←/→ · Esc退出")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button("退出") { reviewMode = false }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(8)

                ThumbnailView(path: item.previewPath, maxPixel: 1600, fit: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(visibleItems) { member in
                                ThumbnailView(path: member.previewPath, maxPixel: 256)
                                    .frame(width: 92, height: 64)
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
                        .padding(6)
                    }
                    .frame(height: 80)
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
        .onAppear { if focusedID == nil { focusedID = visibleItems.first?.id } }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
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

    private func step(_ delta: Int) {
        let next = currentIndex + delta
        if visibleItems.indices.contains(next) {
            focusedID = visibleItems[next].id
        }
    }

    private func color(_ v: Verdict) -> Color {
        switch v {
        case .pick: return .green
        case .usable: return .blue
        case .reject: return .red
        }
    }
}
