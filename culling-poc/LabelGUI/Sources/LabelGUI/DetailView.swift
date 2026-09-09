import SwiftUI

struct DetailView: View {
    @ObservedObject var store: LabelStore
    let photo: Photo
    @AppStorage("labelAutoAdvanceAfterScore") private var autoAdvance = true

    private enum Focus: Hashable { case pane, groupId, composition }
    @FocusState private var focus: Focus?

    private var typing: Bool { focus == .groupId || focus == .composition }

    var body: some View {
        HStack(spacing: 0) {
            imagePane
            Divider()
            formPane
                .frame(width: 320)
        }
        // Click-to-focus (.edit) so clicking the photo arms the shortcuts;
        // the system ring is replaced by our own border so it's obvious
        // which state the pane is in.
        .focusable(interactions: [.activate, .edit])
        .focused($focus, equals: .pane)
        .focusEffectDisabled()
        .overlay {
            if focus == .pane {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { focus = .pane }
        .onKeyPress(.leftArrow) { shortcut { store.previous() } }
        .onKeyPress(.rightArrow) { shortcut { store.next() } }
        .onKeyPress(characters: .init(charactersIn: "12345")) { press in
            shortcut {
                guard let n = Int(String(press.characters)) else { return }
                store.update(photo.id) { $0.humanScore = n }
                if autoAdvance { store.advanceAfterScore() }
            }
        }
        .onKeyPress(characters: .init(charactersIn: "bB")) { _ in
            shortcut { store.update(photo.id) { $0.blur = !($0.blur ?? false) } }
        }
        .onKeyPress(characters: .init(charactersIn: "cC")) { _ in
            shortcut { store.update(photo.id) { $0.closedEyes = !($0.closedEyes ?? false) } }
        }
        .onKeyPress(characters: .init(charactersIn: "xX")) { _ in
            shortcut { store.update(photo.id) { $0.exposureIssue = !($0.exposureIssue ?? false) } }
        }
    }

    /// Single-key shortcuts belong to the pane, never to a text field the user
    /// is typing in — there the key press must fall through to the field.
    private func shortcut(_ action: () -> Void) -> KeyPress.Result {
        guard !typing else { return .ignored }
        action()
        return .handled
    }

    private var imagePane: some View {
        VStack {
            if FileManager.default.fileExists(atPath: photo.previewPath) {
                ThumbnailView(path: photo.previewPath, maxPixel: 1600, fit: true)
                    .padding()
            } else {
                Text("无法加载预览图: \(photo.previewPath)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
        .contentShape(Rectangle())
        .onTapGesture { focus = .pane }
    }

    // MARK: - Bindings into the current row

    private func field<T>(_ keyPath: WritableKeyPath<LabelRow, T>) -> Binding<T> {
        Binding(
            get: { store.binding(for: photo.id)[keyPath: keyPath] },
            set: { value in store.update(photo.id) { $0[keyPath: keyPath] = value } }
        )
    }

    /// Tri-state flags shown as a plain toggle: nil reads as `fallback`, and
    /// setting stores the actual value (false is a real label, not "unset").
    private func field<T>(_ keyPath: WritableKeyPath<LabelRow, T?>, default fallback: T) -> Binding<T> {
        Binding(
            get: { store.binding(for: photo.id)[keyPath: keyPath] ?? fallback },
            set: { value in store.update(photo.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private var scoreBinding: Binding<Int> {
        Binding(
            get: { store.binding(for: photo.id).humanScore ?? 0 },
            set: { v in store.update(photo.id) { $0.humanScore = v == 0 ? nil : v } }
        )
    }

    private var formPane: some View {
        let l1 = store.layer1(for: photo.id)
        let l2 = store.layer2(for: photo.id)

        return Form {
            Section {
                LabeledContent("锐度", value: l1?.sharpness.map { String(format: "%.1f", $0) } ?? "-")
                LabeledContent("闭眼(算法)", value: {
                    guard let l1 else { return "无分析数据" }
                    if l1.faceFound != true { return "未检测到脸" }
                    if let closed = l1.eyeClosed { return closed ? "是" : "否" }
                    // Face box found, but eye landmarks failed (profile angle,
                    // bangs/ornament occlusion, tiny face) — a different failure
                    // from "no face", and worth showing as such.
                    return "有脸，眼部不可判"
                }())
                LabeledContent("人脸质量分", value: l1?.faceQuality.map { String(format: "%.3f", $0) } ?? "-")
                LabeledContent("高光裁切", value: l1?.highlightClipPct.map { String(format: "%.2f%%", $0 * 100) } ?? "-")
                LabeledContent("暗部裁切", value: l1?.shadowClipPct.map { String(format: "%.2f%%", $0 * 100) } ?? "-")
                LabeledContent("连拍分组(算法)", value: l1?.burstGroup.map(String.init) ?? "-")
                if let l2 {
                    LabeledContent("VLM表情分", value: l2.expressionScore.map(String.init) ?? "-")
                    LabeledContent("VLM构图问题", value: (l2.compositionIssues?.joined(separator: ", ")).flatMap { $0.isEmpty ? nil : $0 } ?? "无")
                    LabeledContent("VLM淘汰建议", value: l2.rejectRecommended.map { $0 ? "是" : "否" } ?? "-")
                }
            } header: {
                Text("参考信号 (只读)")
            } footer: {
                // "-" above means one of two very different things; say which.
                if let warning = store.loadWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                } else if l1 == nil {
                    Text("这张照片没有算法分析结果（分析失败或未分析）").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("人工标注") {
                Toggle("虚焦 (b)", isOn: field(\.blur, default: false))
                Toggle("闭眼 (c)", isOn: field(\.closedEyes, default: false))
                Toggle("曝光问题 (x)", isOn: field(\.exposureIssue, default: false))
                TextField("组号", text: field(\.groupId))
                    .focused($focus, equals: .groupId)
                TextField("构图问题描述", text: field(\.compositionIssue))
                    .focused($focus, equals: .composition)
                Picker("评分 (1-5)", selection: scoreBinding) {
                    Text("未评分").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("打分后自动下一张", isOn: $autoAdvance)
            }

            Section {
                HStack {
                    Button("上一张") { store.previous() }
                    Button("下一张") { store.next() }
                    Button("下一张未标注") { store.nextUnlabeled() }
                }
                Text(typing ? "正在输入文字，快捷键已暂停；点击图片恢复"
                            : (focus == .pane ? "键盘快捷键已激活" : "点击图片启用键盘快捷键"))
                    .font(.caption)
                    .foregroundStyle(focus == .pane ? Color.accentColor : .secondary)
                Text("快捷键: ←/→ 换图, 1-5 评分, b 虚焦, c 闭眼, x 曝光问题, ⌘] 下一张未标注")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
