import Foundation

/// 托盘的选中和筛选：只有托盘订阅（选几张不让整个拼图页重算），不进撤销、不存盘，换场次清空。
/// 照相册类软件的照片栏做（Lightroom 书籍模块、Apple 照片的书、Mixbook……，调研见
/// reports/拼图卡顿分析_2026-10-30/托盘多选调研.md）：单击 / ⌘ / ⇧ 选，⌫ 移除，顶上「全部 / 未用 / 已用」筛选。
@MainActor
final class CollageTrayState: ObservableObject {
    enum Filter: String, CaseIterable {
        case all, unused, used

        var label: String {
            switch self {
            case .all: return "全部"
            case .unused: return "未用"
            case .used: return "已用"
            }
        }
    }

    @Published var selection: Set<String> = []
    @Published var filter: Filter = .all {
        didSet { if filter != oldValue { anchor = nil } }
    }
    /// ⇧ 点连选的起点：上一次单击或 ⌘ 点的那张。
    private(set) var anchor: String?

    /// 按筛选留下要显示的（顺序不变 = 带进来的顺序）。usage：每张上了几次（没上的不在里面）。
    func visible(_ photos: [CollagePhotoRef], usage: [String: Int]) -> [CollagePhotoRef] {
        switch filter {
        case .all: return photos
        case .unused: return photos.filter { usage[$0.id] == nil }
        case .used: return photos.filter { usage[$0.id] != nil }
        }
    }

    /// 点了一张。单击：只选它；⌘：加上 / 去掉它；⇧：从起点连到它（按现在显示的顺序，⇧⌘ 是加上这一段）。
    /// 起点不在显示的里面（筛掉了、移除了）时 ⇧ 当单击。
    func click(_ id: String, command: Bool, shift: Bool, order: [String]) {
        if shift, let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            let range = Set(order[min(i, j)...max(i, j)])
            selection = command ? selection.union(range) : range
            return
        }
        if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        anchor = id
    }

    /// ⌘A：选中显示的全部。
    func selectAll(_ order: [String]) {
        selection = Set(order)
        anchor = order.first
    }

    func clear() {
        if !selection.isEmpty { selection = [] }
        anchor = nil
    }

    /// 换场次、清空托盘：选中清掉，筛选回到「全部」（留着「已用」，新带进来的托盘会显示「还没有照片上版」）。
    func reset() {
        clear()
        if filter != .all { filter = .all }
    }

    /// 只留还在 ids 里的（移除了、换了筛选看不见了的去掉）。
    func prune(to ids: Set<String>) {
        let kept = selection.intersection(ids)
        if kept != selection { selection = kept }
        if let a = anchor, !ids.contains(a) { anchor = nil }
    }
}
