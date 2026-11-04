import Foundation

/// 网格多选的规则（纯函数，`--ux-selftest` 直接测）。
/// 以前有选中时 1/2/3/0 改的是整个 selectedIDs、改完不清：⌘点几张按 1，再用方向键走到别的照片按 3，
/// 废掉的是早先那几张（已经跳到精选区、常常滚出屏幕），焦点那张没动；切了筛选、换了章，
/// 看不见的选中也一直留着。现在：数字键只改选中里还看得见的，改完清掉选中（和底部批量栏一样）；
/// 筛选 / 分组 / 展开状态一变，看不见的选中就剪掉。
enum GridSelectionRules {
    struct DigitTargets: Equatable {
        /// 这次要改判的照片，按网格顺序。
        let ids: [String]
        /// true = 改的是选中的那几张；false = 改的是焦点那张。改完焦点都走 refocus。
        let fromSelection: Bool
        /// 改完要不要清掉选中：原来有选中就清 —— 包括选中的全被筛掉、退回去改焦点那张的情形。
        let clearSelection: Bool
    }

    /// 数字键改判的对象：选中里还看得见的优先（按网格顺序）；没有选中、或者选中的一张都看不见，就改焦点那张。
    static func digitTargets(selected: Set<String>, visible: [String], focused: String?) -> DigitTargets {
        if !selected.isEmpty {
            let shown = visible.filter { selected.contains($0) }
            if !shown.isEmpty {
                return DigitTargets(ids: shown, fromSelection: true, clearSelection: true)
            }
        }
        let single: [String] = focused.map { [$0] } ?? []
        return DigitTargets(ids: single, fromSelection: false, clearSelection: !selected.isEmpty)
    }

    /// 改完判决以后焦点怎么办（数字键、批量栏）。
    enum Refocus: Equatable {
        /// 焦点那张还在原来的邻居之间（或者没有焦点）。
        case stay
        /// 焦点那张挪走了 / 看不见了：落到改判前紧跟着它、这次没改、现在还看得见的那张（BatchView.placeAfterChange）。
        case move(String)
        /// 看不见了、也没有能落的（全被筛掉）：清掉焦点，下一次数字键什么都不改，不改看不见的那张。
        case clear
    }

    /// `changed` = 这一下改了判决的全部照片（改焦点那张时就是它自己）。焦点那张在不在 changed 里都算：
    /// 一次改了好几张时它可能在选中里（⇧点、⌘A、点场标题选整场），也可能没选、却跟着整场叠掉（只看待处理）。
    /// 以前多选改完焦点不动，留在被筛掉的照片上，下一次数字键退回去改焦点那张 —— 改的是看不见的它。
    static func refocus(focused: String?, changed: [String], before: [String], after: [String]) -> Refocus {
        guard let focused else { return .stay }
        if let next = BatchView.placeAfterChange(of: focused, before: before, after: after, changed: Set(changed)) {
            return .move(next)
        }
        return after.contains(focused) ? .stay : .clear
    }

    /// 筛选 / 分组方式 / 单张区 / 场的展开收起变了以后，选中只留还看得见的。
    static func pruned(_ selected: Set<String>, visible: [String]) -> Set<String> {
        guard !selected.isEmpty else { return selected }
        return selected.intersection(visible)
    }

    /// 数字键一次改了多张时的提示；一张不提示（网格上看得见它变了）。
    static func changedNotice(count: Int, verdict: Verdict?) -> String? {
        guard count >= 2 else { return nil }
        let what: String = verdict?.rawValue ?? "恢复自动"
        return "已改 \(count) 张 → \(what) · ⌘Z 撤销"
    }
}

/// 决定网格里看得见哪些照片的那几样状态。任何一样变了就剪选中（BatchView 里一个 onChange 看它）。
struct GridSelectionScope: Equatable {
    let verdictFilter: Verdict?
    let clientPickFilter: Bool
    let reasonFilter: String?
    let borderlineFilter: Bool
    let chapterFilter: Int?
    let gridMode: BatchView.GridMode
    let pendingTakesOnly: Bool
    let showSingles: Bool
    let expandedTakes: Set<Int>
}
