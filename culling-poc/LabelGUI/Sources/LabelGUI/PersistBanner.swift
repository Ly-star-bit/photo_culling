import SwiftUI

extension BatchView {
    /// 批量页顶上的常驻提醒：
    /// - 红：判决、客户选中、机身对时没存上（盘满了，审查 S01）。带「重试」，同一个文件写成功才消失，不能点掉。
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
                    Button("重试") { store.retryPersist() }
                        .controlSize(.small)
                        .help("腾出磁盘空间以后再写一次")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.red.opacity(0.18))
            }
            if let notice = store.dataNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(notice).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    Button { store.dataNotice = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("知道了（关掉这条提醒）")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.14))
            }
        }
    }
}
