import SwiftUI

extension BatchView {
    /// 批量页顶上的常驻提醒（审查 S02）：场次里的文件读坏了、已经挪开保住原件（橙色，点掉才没）。
    /// 用 safeAreaInset 挂在整页外面：网格、审片、连拍挑选里都看得见 —— 改判最多的就是后两处。
    @ViewBuilder
    var persistBanner: some View {
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
