import AppKit
import SwiftUI

extension BatchView {
    /// 批量页顶上的常驻提醒：
    /// - 红：判决、客户选中、机身对时没存上（盘满了，审查 S01）。带「重试」，同一个文件写成功才消失，不能点掉。
    ///   原件读不出来、这次打开以后又改过、改动只在内存里的（S02 拒存）也在这一条里：不能点掉，重试没用（不给按钮），
    ///   重新打开这一场才消失。
    /// - 橙：场次里的文件读坏了、已经挪开保住原件（审查 S02）。点掉才没。
    /// 用 safeAreaInset 挂在整页外面：网格、审片、连拍挑选里都看得见 —— 改判最多的就是后两处。
    var persistBanner: some View {
        VStack(spacing: 0) {
            if let error = store.persistError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    Text(error).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    if store.persistRetryable {
                        Button("重试") { store.retryPersist() }
                            .controlSize(.small)
                            .help("腾出磁盘空间以后再写一次")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.red.opacity(0.18))
            }
            if let notice = store.dataNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppPalette.warning)
                    Text(notice).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    Button { store.dataNotice = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("知道了（关掉这条提醒）")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(AppPalette.warning.opacity(0.14))
            }
        }
    }
}

/// 离开有「只在内存里的改动」的场次之前问一句（原件读不出来、这一场不写盘，审查 S02 跟进）：切场次、移除当前这一场、
/// 清除历史记录、重新定位都走 BatchStore.persistBeforeLeaving → confirmDiscardRefused。默认「留在这一场」（回车），
/// 「仍要…」标成破坏性。无头一律不弹、直接放行（同 QuitAlert：没有人可问）；实时桥要先拿 confirm_required 问过用户。
@MainActor
enum PersistLeaveAlert {
    static func ask(action: String, message: String) -> Bool {
        guard !AppRuntime.headless else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "这一场有改动没存盘，\(action)就没了"
        alert.informativeText = message
        alert.addButton(withTitle: "留在这一场")
        let leave = alert.addButton(withTitle: "仍要\(action)")
        leave.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
