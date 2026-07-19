import SwiftUI

struct DetailView: View {
    @ObservedObject var store: LabelStore
    let photo: Photo

    var body: some View {
        HStack(spacing: 0) {
            imagePane
            Divider()
            formPane
                .frame(width: 320)
        }
        .focusable()
        .onKeyPress(.leftArrow) { store.previous(); return .handled }
        .onKeyPress(.rightArrow) { store.next(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "12345")) { press in
            if let n = Int(String(press.characters)) {
                store.update(photo.id) { $0.humanScore = n }
            }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "bB")) { _ in
            store.update(photo.id) { $0.blur = !($0.blur ?? false) }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "cC")) { _ in
            store.update(photo.id) { $0.closedEyes = !($0.closedEyes ?? false) }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "xX")) { _ in
            store.update(photo.id) { $0.exposureIssue = !($0.exposureIssue ?? false) }
            return .handled
        }
    }

    private var imagePane: some View {
        VStack {
            if let nsImage = NSImage(contentsOfFile: photo.previewPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
            } else {
                Text("无法加载预览图: \(photo.previewPath)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }

    private var formPane: some View {
        let l1 = store.layer1(for: photo.id)
        let l2 = store.layer2(for: photo.id)
        let row = store.binding(for: photo.id)

        return Form {
            Section("参考信号 (只读)") {
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
            }

            Section("人工标注") {
                Toggle("虚焦 (b)", isOn: Binding(
                    get: { row.blur ?? false },
                    set: { v in store.update(photo.id) { $0.blur = v } }
                ))
                Toggle("闭眼 (c)", isOn: Binding(
                    get: { row.closedEyes ?? false },
                    set: { v in store.update(photo.id) { $0.closedEyes = v } }
                ))
                Toggle("曝光问题 (x)", isOn: Binding(
                    get: { row.exposureIssue ?? false },
                    set: { v in store.update(photo.id) { $0.exposureIssue = v } }
                ))
                TextField("组号", text: Binding(
                    get: { row.groupId },
                    set: { v in store.update(photo.id) { $0.groupId = v } }
                ))
                TextField("构图问题描述", text: Binding(
                    get: { row.compositionIssue },
                    set: { v in store.update(photo.id) { $0.compositionIssue = v } }
                ))
                Picker("评分 (1-5)", selection: Binding(
                    get: { row.humanScore ?? 0 },
                    set: { v in store.update(photo.id) { $0.humanScore = v == 0 ? nil : v } }
                )) {
                    Text("未评分").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
            }

            Section {
                HStack {
                    Button("上一张") { store.previous() }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("下一张") { store.next() }.keyboardShortcut(.rightArrow, modifiers: [])
                }
                Text("快捷键: ←/→ 换图, 1-5 评分, b 虚焦, c 闭眼, x 曝光问题")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
