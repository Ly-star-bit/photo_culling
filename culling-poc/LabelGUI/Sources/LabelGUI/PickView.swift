import SwiftUI
import AppKit

// MARK: - 连拍挑选（全窗口，占审片模式的位置）
//
// 逻辑在 PickSession，排布在 PickLayout，这里只管画和收按键 / 鼠标。

struct PickView: View {
    @ObservedObject var store: BatchStore
    @StateObject private var session: PickSession
    /// 回网格，带上焦点应落在哪张。
    let onExit: (String?) -> Void

    /// 数字键选完直接下一组（见 PickSession.autoAdvance）。默认关。
    @AppStorage("pick.autoAdvance") private var autoAdvance = false
    @State private var zoomed = false
    /// 放大时以哪个人的脸居中（FaceAlignment 里的下标）；nil = 各格自己的主脸。合影 / 情侣连拍里
    /// 一个人一个人地比（Narrative 的「锁定一个人」）：[ ] 或顶栏 ‹ › 切换。
    @State private var zoomPerson: Int?
    @State private var focusPeak = false
    /// 放大时每格的人脸裁块（CompareZoom.cache 另有一份给回头用）。
    @State private var crops: [String: CompareZoom.Crop] = [:]
    @State private var loadingCrops: Set<String> = []
    @State private var masks: [String: CGImage] = [:]
    @State private var link = ZoomLink()
    /// 每次放大一个号 + 一面取消旗：收起放大 / 换组 / 退出时置旗，排队没开始的原图解码直接跳过；
    /// 回来的结果对不上号就丢。
    @State private var zoomGeneration = 0
    @State private var zoomCancel = AnalysisEngine.CancelFlag()
    /// 现在被建出来的格子（单行滚动是 Lazy 的）。放大只给它们解原图 —— 一组 40 张的连拍
    /// 不会一按 Z 就排队解 40 张整幅原图。
    @State private var appeared: Set<String> = []
    /// 最近一次单击（哪一组、什么时候）：双击放大时撤回第一下单击的「只留这张」——
    /// 双击是想看清楚，不是想选它。
    @State private var lastClick: (key: Int, at: Date)?
    /// Esc 离开时还有改过没确认的组：先问一声（草稿模式下点了不按 ⏎ 是不会写的）。
    @State private var confirmExit = false
    @State private var showShortcuts = false
    @FocusState private var keyFocus: Bool

    init(store: BatchStore, request: PickRequest, sortByScore: Bool, onExit: @escaping (String?) -> Void) {
        self.store = store
        self.onExit = onExit
        returnsToReview = request.returnsToReview
        _session = StateObject(wrappedValue: PickSession(store: store, request: request, sortByScore: sortByScore))
    }

    /// 离屏快照用（--compare-ui）：按键脚本先在 session 上跑完再画；zoom = 一出来就放大到脸
    /// （离屏窗口收不到按键）。
    init(store: BatchStore, session: PickSession, zoom: Bool = false, person: Int? = nil,
         onExit: @escaping (String?) -> Void) {
        self.store = store
        self.onExit = onExit
        _session = StateObject(wrappedValue: session)
        zoomOnAppear = zoom
        _zoomPerson = State(initialValue: person)
    }

    private var zoomOnAppear = false
    /// 审片里按 C 进来的：按钮写「返回审片」，⏎ 定完这一场直接回去。
    private var returnsToReview = false
    private var backLabel: String { returnsToReview ? "返回审片" : "返回网格" }

    var body: some View {
        let frames = session.frames
        let draft = session.draft(for: session.currentKey)
        let faces = FaceAlignment(frames: frames)
        VStack(spacing: 0) {
            header(frames, people: faces.people)
            Divider()
            GeometryReader { geo in
                stage(frames, draft: draft, faces: faces, size: geo.size)
            }
            .overlay(alignment: .top) {
                if session.allDone { doneBanner }
            }
            Divider()
            footer
        }
        .background(Color(white: 0.13))
        .focusable()
        .focused($keyFocus)
        .focusEffectDisabled()
        .confirmationDialog("有 \(session.unconfirmedGroups.count) 组点过但还没确认", isPresented: $confirmExit) {
            Button("确认这 \(session.unconfirmedGroups.count) 组再返回") {
                session.confirmUnconfirmed()
                onExit(session.highlightedID)
            }
            Button("不保存，直接返回", role: .destructive) { onExit(session.highlightedID) }
            Button("继续挑", role: .cancel) {}
        } message: {
            Text("连拍挑选里点的只是草稿，按 ⏎ 才写进判决。确认 = 按你点的写进去（每组一次撤销）；不保存 = 这些组保持原来的判决。")
        }
        .onAppear {
            keyFocus = true
            session.autoAdvance = autoAdvance
            prefetchUpcoming()
            if zoomOnAppear && !zoomed { toggleZoom() }
        }
        .onDisappear { zoomCancel.set() }
        .onChange(of: store.items.count) { session.pruneMissing() }
        .onChange(of: session.position) {
            resetZoom()
            prefetchUpcoming()
        }
        // 审片里绕过来挑一场：⏎ 定完就回审片接着往下，不用再按 Esc。
        .onChange(of: session.allDone) { _, done in
            if done && returnsToReview { onExit(session.highlightedID) }
        }
        .onChange(of: focusPeak) {
            if focusPeak { refreshMasks() } else { masks = [:] }
        }
        .onChange(of: autoAdvance) { session.autoAdvance = autoAdvance }
        .onKeyPress(.leftArrow) { session.move(-1); return .handled }
        .onKeyPress(.rightArrow) { session.move(1); return .handled }
        .onKeyPress(.upArrow) { session.previous(); return .handled }
        .onKeyPress(.downArrow) { session.next(); return .handled }
        .onKeyPress(.space, phases: .down) { press in
            withAnimation(.easeOut(duration: 0.12)) {
                if press.modifiers.contains(.shift) { session.toggleHighlighted() } else { session.chooseHighlighted() }
            }
            return .handled
        }
        // 1–9：只留第几张；0：恢复推荐。⌘1 之类放过去。只认按下、不认按住的重复 —— 开着「选完直接
        // 下一组」时按住 1 稍久一点，重复事件会一组接一组地确认下去（审查发现）。
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]),
                  let n = Int(press.characters) else { return .ignored }
            withAnimation(.easeOut(duration: 0.12)) {
                if n == 0 { session.resetDraft() } else { session.press(number: n) }
            }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "zZ")) { press in
            // 只认裸 Z：⌘Z 是撤销按钮的快捷键。
            guard press.modifiers.isSubset(of: [.shift, .capsLock]) else { return .ignored }
            toggleZoom()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "pP")) { press in
            guard press.modifiers.isSubset(of: [.shift, .capsLock]), zoomed else { return .ignored }
            focusPeak.toggle()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "?")) { _ in
            showShortcuts.toggle()
            return .handled
        }
        // [ ]：放大时换一个人居中（只有一个人就不响应）。
        .onKeyPress(characters: .init(charactersIn: "[]")) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]), zoomed, faces.people > 1 else {
                return .ignored
            }
            cyclePerson(press.characters == "]" ? 1 : -1, people: faces.people)
            return .handled
        }
    }

    // MARK: 顶栏

    private func header(_ frames: [BatchItem], people: Int) -> some View {
        HStack(spacing: 10) {
            Button { exitOrUnzoom() } label: {
                Label(zoomed ? "适应" : backLabel,
                      systemImage: zoomed ? "arrow.down.right.and.arrow.up.left" : "chevron.left")
            }
            .keyboardShortcut(.escape, modifiers: [])
            .help(zoomed ? "退出放大 (Esc)" : (returnsToReview ? "回到审片 (Esc)，接着刚才那张往下" : "回到网格 (Esc)，焦点落在高亮的那张"))
            Text("连拍挑选").font(.headline)
            if !session.isSelection && !session.groups.isEmpty {
                Text("第 \(session.position + 1)/\(session.groups.count) 组").font(.headline).monospacedDigit()
                ProgressView(value: Double(session.decidedCount), total: Double(max(1, session.groups.count)))
                    .frame(width: 80)
                    .help("这一轮 \(session.groups.count) 组里已经定了 \(session.decidedCount) 组")
                Text("已定 \(session.decidedCount)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            let unconfirmed = session.unconfirmedGroups.count
            if unconfirmed > 0 {
                Text("\(unconfirmed) 组未确认").font(.caption).foregroundStyle(.orange)
                    .help("这几组点过但没按 ⏎，判决还没写进去。离开时会问你要不要一起确认")
            }
            Divider().frame(height: 16)
            groupTitle(frames)
            Spacer(minLength: 8)
            if !session.isSelection {
                Button { session.previous() } label: { Label("上一组", systemImage: "chevron.up") }
                    .disabled(!session.hasPrevious)
                    .help("上一组 (↑)。没确认的草稿会留着，回来还是你点过的样子")
                Button { session.next() } label: { Label("下一组", systemImage: "chevron.down") }
                    .disabled(!session.hasNext)
                    .help("下一组 (↓)，这一组先不定")
            }
            Divider().frame(height: 16)
            Button(zoomed ? "适应 (Z)" : "放大到脸 (Z)") { toggleZoom() }
                .help("所有格一起放大到 100%，各自以主脸为中心；拖动、捏合任何一格，其余跟着走。双击照片也行")
            if zoomed && people > 1 {
                HStack(spacing: 2) {
                    Button { cyclePerson(-1, people: people) } label: { Image(systemName: "chevron.left") }
                    Text(zoomPerson.map { "人物 \($0 + 1)/\(people)" } ?? "主脸")
                        .font(.caption).monospacedDigit().frame(minWidth: 62)
                    Button { cyclePerson(1, people: people) } label: { Image(systemName: "chevron.right") }
                }
                .help("每格都以同一个人的脸居中，一个人一个人地比 ([ ])。从左到右数，这张里没检测到他就停在主脸")
            }
            Toggle("对焦 (P)", isOn: $focusPeak)
                .toggleStyle(.button)
                .disabled(!zoomed)
                .help("放大后红色标出合焦区域，看焦点落在眼睛还是耳朵")
            Button("撤销") { withAnimation(.easeOut(duration: 0.12)) { session.undo() } }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!session.canUndo)
                .help("撤销 (⌘Z)：先撤这一组你刚点的；没有了再撤上一次确认的判决（撤的是别的组就跳回那一组）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func groupTitle(_ frames: [BatchItem]) -> some View {
        if let take = session.currentTake {
            let pending = session.isPending(take)
            HStack(spacing: 6) {
                Text("场 \(take)").font(.subheadline.bold())
                Text("\(frames.count) 张").font(.caption).foregroundStyle(.secondary)
                if let range = BatchView.timeRange(frames) {
                    Text(range).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                Text(pending ? "待处理" : "已定")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((pending ? Color.orange : Color.green).opacity(0.22), in: Capsule())
                    .foregroundStyle(pending ? .orange : .green)
            }
            .lineLimit(1)
        } else {
            Text("跨 \(Set(frames.map(\.take)).count) 场 · \(frames.count) 张")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: 台面

    @ViewBuilder
    private func stage(_ frames: [BatchItem], draft: [String: Verdict], faces: FaceAlignment,
                       size: CGSize) -> some View {
        if frames.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
                Text(session.groups.isEmpty ? "没有要挑的连拍" : "这一组已经没有照片了").foregroundStyle(.secondary)
            }
            .frame(width: size.width, height: size.height)
        } else {
            let inner = CGSize(width: max(1, size.width - PickLayout.margin * 2),
                               height: max(1, size.height - PickLayout.margin * 2))
            let layout = PickLayout.compute(count: frames.count, in: inner,
                                            aspect: PreviewAspect.median(frames.map(\.previewPath)),
                                            hasFaces: frames.contains { !$0.faces.isEmpty })
            let best = CompareBest(frames)
            let entries = Array(frames.enumerated())
            switch layout.arrangement {
            case .grid(let rows, let cols):
                VStack(spacing: PickLayout.spacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(alignment: .top, spacing: PickLayout.spacing) {
                            ForEach(Array(entries[(row * cols)..<min(entries.count, (row + 1) * cols)]),
                                    id: \.element.id) { entry in
                                tile(entry.element, index: entry.offset, state: draft[entry.element.id] ?? .reject,
                                     best: best, faces: faces, layout: layout)
                            }
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
            case .strip:
                // 张数多：单行大图，左右滚动对比（触控板横扫 / ←→ 移动高亮时自动滚到它）。
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .center, spacing: PickLayout.spacing) {
                            ForEach(entries, id: \.element.id) { entry in
                                tile(entry.element, index: entry.offset, state: draft[entry.element.id] ?? .reject,
                                     best: best, faces: faces, layout: layout)
                                    .id(entry.element.id)
                            }
                        }
                        .padding(.horizontal, PickLayout.margin)
                        .frame(minHeight: size.height)
                    }
                    .onAppear {
                        if let id = session.highlightedID { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: session.highlight) {
                        guard let id = session.highlightedID else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                    }
                }
                // 换组就是新的一条：滚动位置从这一组的高亮那张开始，不接着上一组的。
                .id(session.currentKey)
            }
        }
    }

    private func tile(_ item: BatchItem, index: Int, state: Verdict, best: CompareBest,
                      faces: FaceAlignment, layout: PickLayout.Result) -> some View {
        PickTile(item: item, number: index + 1, state: state,
                 rank: store.takeRank[item.id], manual: store.overrides[item.id] != nil,
                 highlighted: index == session.highlight, layout: layout, best: best,
                 faceSlots: faces.slots[item.id] ?? [], eyes: faces.summary(item.id),
                 zoomFace: zoomPerson.flatMap { p in
                     let slots = faces.slots[item.id] ?? []
                     return slots.indices.contains(p) ? slots[p]?.face.bbox : nil
                 },
                 zoomKey: zoomPerson.map { "#p\($0)" } ?? "",
                 zoomed: zoomed, crop: crops[item.id], loadingCrop: loadingCrops.contains(item.id),
                 mask: focusPeak ? masks[item.id] : nil, link: link,
                 onClick: { command in click(item, command: command) },
                 onDoubleClick: { doubleClick(item) },
                 onHighlight: {
                     session.highlight(item.id)
                     keyFocus = true
                 },
                 onSet: { verdict in
                     withAnimation(.easeOut(duration: 0.12)) { session.set(item.id, verdict) }
                     keyFocus = true
                 })
            .onAppear {
                appeared.insert(item.id)
                if zoomed { loadCrop(item.id) }
            }
            .onDisappear {
                appeared.remove(item.id)
                // 单行滚动的大组：滚出去的格子把裁块放掉（CompareZoom.cache 还留着最近的几张）。
                crops.removeValue(forKey: item.id)
                masks.removeValue(forKey: item.id)
            }
    }

    private func click(_ item: BatchItem, command: Bool) {
        lastClick = (session.currentKey, Date())
        withAnimation(.easeOut(duration: 0.12)) {
            if command { session.toggle(item.id) } else { session.choose(item.id) }
        }
        keyFocus = true
    }

    private func doubleClick(_ item: BatchItem) {
        if let last = lastClick, last.key == session.currentKey,
           Date().timeIntervalSince(last.at) < NSEvent.doubleClickInterval + 0.2 {
            session.revertLastDraftChange()
        }
        lastClick = nil
        session.highlight(item.id)
        if !zoomed { toggleZoom() }
    }

    // MARK: 底栏

    private var footer: some View {
        let outcome = session.outcome
        let wholeGroupOut = outcome.keepCount == 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: wholeGroupOut ? "trash.fill" : "checkmark.circle.fill")
                    .foregroundStyle(wholeGroupOut ? Color.red : Verdict.pick.color)
                Text(PickSession.outcomeText(outcome))
                    .font(.callout)
                    .foregroundStyle(wholeGroupOut ? Color.red : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                if outcome.changes == 0 {
                    Text("（和现在一样）").font(.caption).foregroundStyle(.tertiary)
                }
                if session.draftEdited {
                    Button("恢复推荐 (0)") { withAnimation(.easeOut(duration: 0.12)) { session.resetDraft() } }
                        .controlSize(.small)
                        .help("扔掉这一组你点过的，回到算法推荐（精选留、其余废）")
                }
                Button("这组全留") { withAnimation(.easeOut(duration: 0.12)) { session.keepAll() } }
                    .controlSize(.small)
                    .help("整组都想留时用：现在的精选（你点过的；没点过就是推荐的那张）还是精选，其余都设可用。⏎ 才写进去")
                Spacer(minLength: 8)
                Toggle("数字键选完直接下一组", isOn: $autoAdvance)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("开：按 1–9 = 只留第几张并立刻确认、跳下一组，一组一个键（Lightroom 的自动前进）。" +
                          "点击、⌘点、空格不受影响；按错了 ⌘Z 撤回并跳回那一组")
                Button(session.isSelection ? "确认 (⏎)" : "确认并下一组 (⏎)") {
                    // 按住 ⏎ 的重复事件不算：不然一路确认下去。
                    if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
                    withAnimation(.easeOut(duration: 0.15)) { _ = session.confirm() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(session.frames.isEmpty)
                .help("按左边那句话写判决（留的设为精选/可用，其余设为废片，整组一次撤销），然后跳到下一个待处理的组")
            }
            HStack(spacing: 6) {
                Text(session.isSelection
                     ? "点 = 留这张（同一场的其余废，别的场不动）· 右上角 = 只改这一张 · 1–9 第几张 · ←/→ 移动 · Z 放大到脸 · ⌘Z 撤销 · Esc 返回"
                     : "点 = 只留这张 · 鼠标停上去右上角 精选/可用/废 = 只改这一张 · 1–9 只留第几张 · ⇧空格 多留 · ↑/↓ 换组 · Z 放大到脸 · ⌘Z 撤销 · Esc 返回")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                Button { showShortcuts.toggle() } label: { Image(systemName: "keyboard").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("快捷键一览 (?)")
                    .popover(isPresented: $showShortcuts, arrowEdge: .top) { ShortcutsPanel() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var doneBanner: some View {
        HStack(spacing: 10) {
            Label(session.isSelection ? "这一组定好了" : "待处理的组都定完了 · ↑ 可以回去看",
                  systemImage: "checkmark.circle.fill")
                .font(.callout.bold())
                .foregroundStyle(.green)
            // 鼠标用户也得有条路回去（以前只写了「Esc 返回网格」）；回网格后按 F 逐张审片。
            // 直接回网格：放大着确认完最后一组时，这里点一下不该只是退出放大。
            Button(backLabel) {
                if zoomed { resetZoom() }
                exitOrUnzoom()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.green.opacity(0.2), in: Capsule())
        .padding(.top, 10)
    }

    // MARK: 动作

    private func exitOrUnzoom() {
        if zoomed {
            resetZoom()
            return
        }
        if !session.unconfirmedGroups.isEmpty {
            confirmExit = true
            return
        }
        onExit(session.highlightedID)
    }

    private func toggleZoom() {
        if zoomed {
            resetZoom()
            return
        }
        zoomed = true
        zoomGeneration += 1
        zoomCancel = AnalysisEngine.CancelFlag()
        let live = Set(session.frames.map(\.id))
        for id in appeared where live.contains(id) { loadCrop(id) }
    }

    /// 换一个人居中：新的联动对象（旧的那几格各自拆掉、注销），新格子按新的脸重新入伙 ——
    /// 不然新格子会照着上一个人的偏移对齐。倍率回到 100%。
    private func cyclePerson(_ delta: Int, people: Int) {
        guard people > 1 else { return }
        let current = zoomPerson ?? (delta > 0 ? -1 : people)
        zoomPerson = (current + delta + people) % people
        link = ZoomLink()
    }

    private func resetZoom() {
        zoomCancel.set()
        zoomGeneration += 1
        zoomed = false
        zoomPerson = nil
        focusPeak = false
        crops = [:]
        masks = [:]
        loadingCrops = []
        link.reset()
    }

    /// 一格去解原图裁人脸（放大时出现在台上的才解）。
    private func loadCrop(_ id: String) {
        guard zoomed, crops[id] == nil, !loadingCrops.contains(id), let item = store.item(withID: id) else { return }
        let generation = zoomGeneration
        let cancel = zoomCancel
        loadingCrops.insert(id)
        Task { @MainActor in
            let crop = await CompareZoom.load(item, cancel: cancel)
            // 不是本轮放大发出去的（中间收起/换组过）：结果和转圈都不归它管。
            guard generation == zoomGeneration else { return }
            loadingCrops.remove(id)
            guard zoomed, appeared.contains(id), let crop else { return }
            crops[id] = crop
            if focusPeak { refreshMasks() }
        }
    }

    private func refreshMasks() {
        guard zoomed, focusPeak else { return }
        for (id, crop) in crops where masks[id] == nil {
            let image = crop.image
            let key = crop.key
            Task.detached(priority: .userInitiated) {
                let mask = FocusMask.compute(from: image, key: key)
                await MainActor.run {
                    guard let mask, zoomed, focusPeak, crops[id]?.key == key else { return }
                    masks[id] = mask
                }
            }
        }
    }

    /// ⏎ 之后要去的那一组先解好。小组（≤4 张，格子大、要清晰版）解 4096；大组格子小，预览就够。
    private func prefetchUpcoming() {
        guard let index = session.upcomingIndex else { return }
        let frames = session.frames(of: session.groups[index])
        if frames.count <= 4 {
            for item in frames {
                let path = item.decodePath
                let px = SharpImageView.fitMaxPixel
                guard FitCache.cache.object(forKey: ThumbCache.key(path, px)) == nil else { continue }
                Task.detached(priority: .utility) { _ = FitCache.load(path: path, maxPixel: px) }
            }
        } else {
            for item in frames.prefix(10) {
                let path = item.previewPath
                let px = ImageLoader.previewMaxPixel
                guard ThumbCache.cache.object(forKey: ThumbCache.key(path, px)) == nil else { continue }
                Task.detached(priority: .utility) { _ = ThumbCache.load(path: path, maxPixel: px) }
            }
        }
    }
}

// MARK: - 一格

private struct PickTile: View {
    let item: BatchItem
    /// 1 起；1–9 就是它的数字键。
    let number: Int
    /// 草稿里的去留。
    let state: Verdict
    let rank: Int?
    let manual: Bool
    let highlighted: Bool
    let layout: PickLayout.Result
    let best: CompareBest
    /// 按人对齐的脸（下标 = 人，nil = 这张里没检测到这个人）。
    let faceSlots: [FaceAlignment.Slot?]
    let eyes: (closed: Int, squint: Int, known: Int)
    /// 放大时要居中的那张脸（换人看时）；nil = 主脸。zoomKey 跟着变，好让放大窗按新锚点重建。
    let zoomFace: [Double]?
    let zoomKey: String
    let zoomed: Bool
    let crop: CompareZoom.Crop?
    let loadingCrop: Bool
    let mask: CGImage?
    let link: ZoomLink
    let onClick: (_ command: Bool) -> Void
    let onDoubleClick: () -> Void
    /// 放大时在照片上单击 / 双击：只把这一格设为高亮，不改去留 —— 放大时点一下多半是为了拖、捏、
    /// 按 [ ] 或 P，不是在选（审查发现：以前会顺手把它改成唯一留下的）。
    let onHighlight: () -> Void
    /// 右上角「精选 / 可用 / 废」：只改这一张。
    let onSet: (Verdict) -> Void

    @State private var hovering = false

    /// 格子够大（物理像素超过预览）才走 4096 + 锐化的清晰版；格子小的大组用 1024 预览就够，
    /// 不然一组十几张就是十几张 4096 解码。
    private var sharp: Bool {
        max(layout.image.width, layout.image.height) * (NSScreen.main?.backingScaleFactor ?? 2)
            > CGFloat(ImageLoader.previewMaxPixel) * 1.1
    }

    var body: some View {
        let kept = state != .reject
        let showHover = hovering || item.id == SnapshotPreview.hoverID
        // 废掉的照片变灰，但鼠标停上去 / 键盘高亮时恢复原色 —— 它们还是候选，要能比。
        let vivid = kept || highlighted || showHover
        VStack(alignment: .leading, spacing: PickLayout.innerSpacing) {
            photo(vivid: vivid)
                .frame(width: layout.image.width, height: layout.image.height)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(kept ? state.color : Color.clear, lineWidth: 3))
                .overlay(alignment: .topLeading) { numberBadge }
                .overlay(alignment: .topTrailing) {
                    // 悬停时这里换成可点的三个按钮（挂在下面手势的外层）。
                    if !showHover { stateBadge }
                }
                .overlay(alignment: .bottomLeading) { reasonsBadge }
            if layout.faceSize > 0 { faces }
            metrics
        }
        .padding(PickLayout.tilePadding)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(highlighted ? 0.10 : 0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(highlighted ? Color.white.opacity(0.85) : Color.white.opacity(0.06), lineWidth: highlighted ? 2 : 1)
        )
        .contentShape(Rectangle())
        // 同网格：双击手势 + 同时识别的单击，单击不必等 300ms 排除双击；双击的第二下也会来一次
        // 单击，按 clickCount 跳过（拼图画布同一个写法，用户在界面里验过）。
        .gesture(TapGesture(count: 2).onEnded { onDoubleClick() })
        .simultaneousGesture(TapGesture().onEnded {
            guard !ClickGuard.isRepeatClick else { return }
            onClick(NSEvent.modifierFlags.contains(.command))
        })
        // 悬停时右上角三个按钮（Lightroom 网格格子上可点的旗标那种）。必须挂在点击手势**之后**：
        // 挂在里面的话它们是手势的子孙，点按钮会同时触发上面的「只留这张」。
        .overlay(alignment: .topTrailing) {
            if showHover {
                stateControls
                    .padding(.top, PickLayout.tilePadding + 5)
                    .padding(.trailing, PickLayout.tilePadding + 5)
            }
        }
        // 悬停也挂在按钮外层：挂在里面的话鼠标移到按钮上就算「离开」，按钮一闪一闪。
        .onHover { hovering = $0 }
        .help("\(item.id) · 点照片 = 只留这张 · 右上角 = 只改这一张 · ⌘点 = 多留/取消 · 双击 = 放大到脸")
    }

    /// 精选 / 可用 / 废：现在是哪个就亮哪个。
    private var stateControls: some View {
        HStack(spacing: 2) {
            ForEach([Verdict.pick, .usable, .reject], id: \.self) { verdict in
                let on = state == verdict
                // 只认单击：双击的第二下不算（和网格悬停条一样）。
                Button { if !ClickGuard.isRepeatClick { onSet(verdict) } } label: {
                    Label(Self.controlTitle(verdict), systemImage: verdict.symbol)
                        .font(.caption.bold())
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(on ? verdict.color.opacity(0.9) : Color.clear, in: Capsule())
                        .foregroundStyle(on ? Color.white : verdict.color)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Self.controlHelp(verdict))
            }
        }
        .padding(3)
        .background(.black.opacity(0.75), in: Capsule())
        .fixedSize()
    }

    private static func controlTitle(_ verdict: Verdict) -> String {
        switch verdict {
        case .pick: return "精选"
        case .usable: return "可用"
        case .reject: return "废"
        }
    }

    private static func controlHelp(_ verdict: Verdict) -> String {
        switch verdict {
        case .pick: return "这张留作精选（同一场别的照片不动）"
        case .usable: return "这张留作可用（同一场别的照片不动）"
        case .reject: return "这张废掉（同一场别的照片不动）"
        }
    }

    @ViewBuilder
    private func photo(vivid: Bool) -> some View {
        if zoomed, let crop {
            // 放大后在照片上单击 / 双击只设高亮（双击时 ZoomPane 自己切 适应 ↔ 100%）；要改去留用
            // 数字键、空格，或点下面的人脸 / 数值行。
            ZoomPane(image: crop.image, entry: .hundred, faceBbox: nil, boxColor: .systemYellow,
                     focusMask: mask, anchor: zoomFace.map { crop.anchor(for: $0) } ?? crop.anchor, link: link,
                     onClick: onHighlight,
                     onDoubleClick: onHighlight)
                .id(crop.key + zoomKey + "#\(ObjectIdentifier(link).hashValue)")
        } else {
            Group {
                if sharp {
                    SharpImageView(previewPath: item.previewPath, decodePath: item.decodePath)
                } else {
                    ThumbnailView(path: item.previewPath, maxPixel: ImageLoader.previewMaxPixel, fit: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .saturation(vivid ? 1 : 0.3)
            .opacity(vivid ? 1 : 0.6)
            .overlay {
                if zoomed && loadingCrop {
                    ProgressView().controlSize(.small)
                        .padding(8)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var numberBadge: some View {
        HStack(spacing: 5) {
            Text("\(number)")
                .font(.system(size: number < 10 ? 13 : 11, weight: .bold)).monospacedDigit()
                .foregroundStyle(.white)
            if let rank {
                Text("#\(rank)").font(.caption2.bold()).monospacedDigit()
                    .foregroundStyle(rank == 1 ? Color.white : Color.white.opacity(0.6))
                    .help("算法评分本组第 \(rank)（表情 > 人脸质量 > 锐度）")
            }
            if manual {
                Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                    .help("人工改判过")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(6)
    }

    private var stateBadge: some View {
        let look = Self.stateLook(state)
        return Text(look.text)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(look.fill, in: Capsule())
            .foregroundStyle(look.ink)
            .padding(6)
    }

    /// 单独一个函数：CI 的 Xcode 16 对结果构建器里的 switch 比本地编译器挑剔。
    private static func stateLook(_ state: Verdict) -> (text: String, fill: Color, ink: Color) {
        switch state {
        case .pick: return ("★ 留", Verdict.pick.color.opacity(0.9), .white)
        case .usable: return ("留·可用", Verdict.usable.color.opacity(0.9), .white)
        case .reject: return ("废", Color.black.opacity(0.6), Verdict.reject.color)
        }
    }

    /// 左下：算法给的毛病（闭眼 / 虚焦…）。留不留是你定，但毛病要看得见。
    @ViewBuilder
    private var reasonsBadge: some View {
        if !item.rejectReasons.isEmpty {
            Text(item.rejectReasons.joined(separator: " · "))
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.red)
                .lineLimit(1)
                .padding(6)
        }
    }

    /// 这张里每个人的脸，按人对齐：几张之间同一个人落在同一个位置，这张里没检测到这个人就留一个
    /// 虚框（转头、被挡住一眼看得出）。圈：绿睁眼、黄眯眼（比这个人本组最好的那张明显小）、红闭眼。
    private var faces: some View {
        let size = layout.faceSize
        let fit = max(1, Int((layout.image.width + 4) / (size + 4)))
        let shown = faceSlots.count > fit ? Array(faceSlots.prefix(max(1, fit - 1))) : faceSlots
        return HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, slot in
                if let slot {
                    FaceCropView(previewPath: item.previewPath, decodePath: item.decodePath, face: slot.face,
                                 size: size, eye: slot.eye, bestEyes: slot.bestEyes)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: size, height: size)
                        .overlay(Text("没检测到").font(.caption2).foregroundStyle(.tertiary))
                        .help("这一张里没检测到这个人的脸（转头、被挡住或出画）")
                }
            }
            if faceSlots.count > shown.count {
                Text("+\(faceSlots.count - shown.count)").font(.caption).foregroundStyle(.secondary)
            }
            if faceSlots.isEmpty {
                Text("没有检测到人脸").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: layout.image.width, height: size, alignment: .leading)
    }

    private var metrics: some View {
        let sharpness = CompareBest.sharpnessText(item.sharpness)
        return HStack(spacing: 8) {
            metric("锐度", "\(sharpness)", top: best.sharpness == sharpness)
            if let q = item.faceQuality {
                let text = CompareBest.qualityText(q)
                metric("质量", text, top: best.quality == text)
            }
            if let e = item.expressionScore {
                metric("表情", "\(e)", top: best.expression == e)
            }
            eyeSummary
            Spacer(minLength: 4)
            Text(item.id).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(-1)
        }
        .font(.caption)
        .lineLimit(1)
        .frame(width: layout.image.width, height: PickLayout.metricsHeight, alignment: .leading)
    }

    /// 本组最高的那一项标绿 + ▲。
    private func metric(_ label: String, _ value: String, top: Bool) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().bold(top)
                .foregroundStyle(top ? Verdict.pick.color : Color.primary)
            if top {
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7))
                    .foregroundStyle(Verdict.pick.color)
            }
        }
        .fixedSize()
    }

    /// 闭眼优先报，其次眯眼，都没有才是「睁眼 n/n」。分母是这一组里的人数（按人对齐后的）。
    @ViewBuilder
    private var eyeSummary: some View {
        if eyes.known > 0 {
            let total = max(eyes.known, faceSlots.count)
            Group {
                if eyes.closed > 0 {
                    Label("闭眼 \(eyes.closed)/\(total)", systemImage: "eye.slash").foregroundStyle(Color.red)
                } else if eyes.squint > 0 {
                    Label("眯眼 \(eyes.squint)/\(total)", systemImage: "eye").foregroundStyle(Color.yellow)
                } else {
                    Label("睁眼 \(eyes.known)/\(total)", systemImage: "eye").foregroundStyle(Color.green)
                }
            }
            .fixedSize()
        }
    }
}
