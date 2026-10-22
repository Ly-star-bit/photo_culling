import SwiftUI

/// 状态栏「N 台机身」点开的对时面板：每台机身一行（名字、张数、对时后的第一张到最后一张、偏移）。
/// 偏移手填（± 秒，或 分:秒），⏎ 或「完成」生效；也可以回网格选两台机身同一瞬间的两张，
/// 批量栏「把这两张对成同一时刻」。只改这里的排序、分场、章节，不改原片。
struct BodyClockSheet: View {
    @ObservedObject var store: BatchStore
    @Binding var isPresented: Bool
    /// 机身 key → 输入框里的字（打开时按现在的偏移填好）。
    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按机身对时").font(.headline)
            Text("两台机器的钟差几分钟，排序、分场、章节就会交错。给慢的那台补上差的时间：+180 或 +3:00 = 往后拨 3 分钟，-0:30 = 往前拨 30 秒。只改这里的顺序，不改原片。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(store.bodies) { info in
                row(info)
            }
            Text("用两张照片对齐：在网格里 ⌘ 点选两台机身同一瞬间各拍的一张（同一次闪光、同一个动作），批量栏点「把这两张对成同一时刻」，以照片多的那台（第一行）为准。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("撤销上次对时") {
                    store.undoLastOverride()
                    resetDrafts()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndoBodyOffsets)
                .help("撤回上一次改的偏移 (⌘Z)")
                Spacer()
                Button("取消") { isPresented = false }
                Button("完成") {
                    if apply() { isPresented = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hasInvalid)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear(perform: resetDrafts)
    }

    private func row(_ info: BatchStore.BodyInfo) -> some View {
        let text = Binding(get: { drafts[info.key] ?? "" }, set: { drafts[info.key] = $0 })
        let problem = BodyClock.offsetProblem(text.wrappedValue)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.body.bold())
                Text("\(info.count) 张 · \(BodyClock.range(info))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            TextField("0", text: text)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .onSubmit { _ = apply() }
                .help("这台机身的时间加多少：± 秒，或 分:秒（-3:00），最多 ±\(BodyClock.maxOffset / 3600) 小时。0 = 不改")
        }
    }

    private var hasInvalid: Bool {
        store.bodies.contains { BodyClock.parseOffset(drafts[$0.key] ?? "") == nil }
    }

    /// 输入框里改过的一起生效（一条撤销记录）。有看不懂的就不动。
    private func apply() -> Bool {
        var changes: [String: Int] = [:]
        for info in store.bodies {
            guard let seconds = BodyClock.parseOffset(drafts[info.key] ?? "") else { return false }
            if seconds != info.offset { changes[info.key] = seconds }
        }
        store.setBodyOffsets(changes)
        resetDrafts()
        return true
    }

    private func resetDrafts() {
        var fresh: [String: String] = [:]
        for info in store.bodies { fresh[info.key] = BodyClock.formatOffset(info.offset) }
        drafts = fresh
    }
}
