import Foundation

/// --persist-selftest 的审查跟进几组（P 车道修复）：橙条上限、拒存以后的改动、客户备注、AI 改判出处、sessions.json
/// 认不出是哪一场的条目、拼图工程没读进来时移废片。
extension PersistSelfTestHarness {
    // MARK: - 橙条最多几条

    func dataNoticeCap() {
        print("— 橙条提醒多了：最多 \(BatchStore.dataNoticeCap) 条，挤掉的第一行说几条，不悄悄丢")
        freshIndex()
        let store = newStore()
        store.dataNotice = nil
        let total = BatchStore.dataNoticeCap + 2
        for i in 1...total { store.addDataNotice("第 \(i) 条") }
        let lines = (store.dataNotice ?? "").components(separatedBy: "\n")
        let shown = Array(lines.dropFirst())
        let wantShown = ((total - BatchStore.dataNoticeCap + 1)...total).map { "第 \($0) 条" }
        check(lines.first?.contains("另有 2 条") == true && shown == wantShown,
              "\(total) 条：显示最近 \(BatchStore.dataNoticeCap) 条，第一行说另有 2 条：\(lines)")
        store.addDataNotice("再一条")
        let again = (store.dataNotice ?? "").components(separatedBy: "\n")
        check(again.count == BatchStore.dataNoticeCap + 1 && again.first?.contains("另有 3 条") == true && again.last == "再一条",
              "再加一条：数跟着涨、只有一行在说挤掉了几条：\(again)")
        store.dataNotice = nil
        store.addDataNotice("点掉以后的第一条")
        check(store.dataNotice == "点掉以后的第一条", "点掉以后重新数：\(store.dataNotice ?? "nil")")
    }
}
