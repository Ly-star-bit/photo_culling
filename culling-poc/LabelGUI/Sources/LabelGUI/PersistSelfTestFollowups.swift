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

    // MARK: - 原件读不出来、这一场不写盘以后又改过

    /// root 跑时 chmod 000 挡不住读写，读不出来那几段测不了。
    var chmodBlocks: Bool { getuid() != 0 }

    func setMode(_ url: URL, _ mode: Int) {
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func refusedEditsSurface() {
        print("— S02a 跟进 原件读不出来、这一场不写盘以后又改过：常驻红条（点不掉、没有「重试」），切场次 / 移除 / 退出前问一句，不硬拦")
        guard chmodBlocks else {
            print("SKIP root 跑时 chmod 000 挡不住读，这一段测不了")
            return
        }
        freshIndex()
        let s = makeSession("s02a-dirty"), other = makeSession("s02a-dirty-other")
        let url = s.dir.appendingPathComponent("overrides.json")
        let original = Data("{\"DSCF7207\":\"废片\"}".utf8)
        try? original.write(to: url)
        setMode(url, 0o000)
        defer { setMode(url, 0o644) }
        let store = newStore()
        var asked: [(action: String, message: String)] = []
        var answer = false
        store.confirmDiscardRefused = { action, message in
            asked.append((action, message))
            return answer
        }
        store.switchSession(to: s.folder)
        guard let id = store.items.first?.id else {
            check(false, "fixture 读进来了")
            return
        }
        check(store.persistError == nil && store.dataNotice?.contains("读不出来") == true,
              "刚打开、还没改：只有橙色提醒，没有红条")
        store.setOverride(id, .pick)
        store.dataNotice = nil  // 用户点掉橙条
        let banner = store.persistError ?? ""
        let bannerOK: Bool = banner.contains("判决") && banner.contains("只在内存里") && banner.contains("原件读不出来")
        check(bannerOK && !store.persistRetryable, "改过以后（橙条点掉了）：红条说判决原件读不出来、改动只在内存里，没有「重试」：\(banner)")
        check(!store.retryPersist() && store.persistError == banner, "重试写不上：retryPersist 回 false（退出时照样问），红条不变")

        // 切场次：先问；选「留在这一场」就不切
        let switched = store.switchSession(to: other.folder)
        let firstAsk = asked.first
        let stayed: Bool = !switched && store.sessionDir.lastPathComponent == s.key && store.overrides[id] == .pick
        check(stayed && asked.count == 1 && firstAsk?.action == "切场次" && firstAsk?.message.contains("判决") == true,
              "切场次先问一句（说清是判决、切了就没）；选「留在这一场」：没切、改动还在")
        check(store.lastError?.contains("没有切场次") == true && store.persistError != nil,
              "状态栏说为什么没切，红条还在：\(store.lastError ?? "nil")")
        if let entry = store.recentSessions.first(where: { $0.key == s.key }) {
            store.removeSession(entry)
            let kept: Bool = store.photoDir != nil && store.sessionDir.lastPathComponent == s.key && store.overrides[id] == .pick
            check(kept && asked.count == 2 && asked.last?.action == "移除这一场", "移除当前这一场也先问；不同意就不移")
        } else {
            check(false, "这一场在「最近场次」里")
        }

        // 退出：QuitCoordinator 看到红条，问「不退出 / 仍然退出」（假的弹框，选不退出）
        var quitAsked: QuitGuard.Decision?
        let quit = QuitCoordinator(target: store, headless: false, ask: { decision in
            quitAsked = decision
            return false
        }, reply: { _ in })
        let reply = quit.shouldTerminate(reason: .user)
        let askedUnsaved: Bool = quitAsked == .askUnsaved(banner)
        check(reply == .terminateCancel && askedUnsaved, "按 ⌘Q：问「有改动没存上」，选不退出就不退")

        // 同意丢掉：切过去，红条跟着没了；原件一个字节没动，权限恢复后重新打开读回来
        answer = true
        let left: Bool = store.switchSession(to: other.folder)
        check(left && asked.count == 3 && store.sessionDir.lastPathComponent == other.key && store.persistError == nil,
              "选「仍要切场次」：切过去，红条没了")
        setMode(url, 0o644)
        check(read(url) == original, "读不出来的原件一个字节没动")
        store.switchSession(to: s.folder)
        check(store.overrides["DSCF7207"] == .reject && store.persistError == nil && asked.count == 3,
              "权限恢复后重新打开：原来的改判读回来，没有红条（这次没改过，切走不问）")
    }

    // MARK: - 客户备注（client_notes.json）走同一套护栏

    func savedNotes(_ s: Session) -> [String: String]? {
        read(s.dir.appendingPathComponent("client_notes.json")).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    func clientNotesGuarded() {
        print("— 客户备注：解不开挪开、读不出来不写、选中不写时备注也不写、写不上上红条 / 拦切场次 / 重试补写")
        freshIndex()
        let other = makeSession("notes-other")

        // 解不开：挪开保住原件、提示；下一次导入带备注的回复只写这次的，挪开的原件不碰
        let bad = makeSession("notes-corrupt")
        let garbage = Data("{\"DSCF7207\": \"提亮一点\", \"DSCF72".utf8)
        try? garbage.write(to: bad.dir.appendingPathComponent("client_notes.json"))
        let store = newStore()
        store.switchSession(to: bad.folder)
        guard let id = store.items.first?.id, let id2 = store.items.dropFirst().first?.id else {
            check(false, "fixture 读进来了")
            return
        }
        let aside = corruptCopies(of: "client_notes.json", in: bad.dir)
        check(aside.count == 1 && aside.first.flatMap(read) == garbage && store.clientNotes.isEmpty,
              "client_notes.json 解不开：原件挪成 \(aside.first?.lastPathComponent ?? "—")、一字不差，这一场先当没有备注")
        check(store.dataNotice?.contains("client_notes.json") == true, "橙条点名 client_notes.json：\(store.dataNotice ?? "nil")")
        store.importClientPicks([id2], notes: [id2: "去掉路人"])
        let wantNew: [String: String] = [id2: "去掉路人"]
        check(savedNotes(bad) == wantNew && aside.first.flatMap(read) == garbage && store.persistError == nil,
              "导入带备注的回复：只写这次的那条，挪开的原件没被碰到")

        // 读不出来（权限）：不挪、不写；导入以后红条点名客户备注；原件一字不差
        if chmodBlocks {
            let locked = makeSession("notes-locked")
            let url = locked.dir.appendingPathComponent("client_notes.json")
            let original = Data("{\"DSCF7207\":\"肤色暖一点\"}".utf8)
            try? original.write(to: url)
            setMode(url, 0o000)
            store.switchSession(to: locked.folder)
            check(store.dataNotice?.contains("客户备注") == true && corruptCopies(of: "client_notes.json", in: locked.dir).isEmpty,
                  "读不出来：提示、没挪")
            store.importClientPicks([id2], notes: [id2: "裁掉左边"])
            check(store.persistError?.contains("客户备注") == true && store.persistError?.contains("只在内存里") == true,
                  "导入带备注的回复：红条说客户备注只在内存里：\(store.persistError ?? "nil")")
            setMode(url, 0o644)
            check(read(url) == original, "读不出来的原件没被盖掉")
            store.switchSession(to: other.folder)
            store.switchSession(to: locked.folder)
            let wantOriginal: [String: String] = ["DSCF7207": "肤色暖一点"]
            check(store.clientNotes == wantOriginal && store.persistError == nil, "权限恢复后重新打开：原来的备注读回来")

            // 客户选中读不出来：同一次导入的备注也不写（盘上两份对得上）
            let picksLocked = makeSession("notes-picks-locked")
            let picksURL = picksLocked.dir.appendingPathComponent("client_picks.json")
            try? Data("[\"DSCF7207\"]".utf8).write(to: picksURL)
            setMode(picksURL, 0o000)
            store.switchSession(to: picksLocked.folder)
            store.importClientPicks([id2], notes: [id2: "调亮"])
            let banner = store.persistError ?? ""
            let notesURL = picksLocked.dir.appendingPathComponent("client_notes.json")
            check(!exists(notesURL) && banner.contains("客户选中") && banner.contains("客户备注"),
                  "客户选中读不出来：备注也不写，红条两样都点名：\(banner)")
            check(LiveHandlers.batchPersistReport(store, [.clientNotes]).persisted == false,
                  "实时桥问客户备注存上没有：没有（跟着客户选中一起不写）")
            setMode(picksURL, 0o644)
            store.switchSession(to: other.folder)
        } else {
            print("SKIP root 跑时 chmod 000 挡不住读，读不出来那两段测不了")
        }

        // 写不上（场次目录只读 = 盘满）：红条点名客户备注、切场次拦住，腾出空间点「重试」补写
        let full = makeSession("notes-full")
        store.switchSession(to: full.folder)
        store.importClientPicks([id])
        setWritable(full.dir, false)
        defer { setWritable(full.dir, true) }
        store.importClientPicks([id], notes: [id: "眼睛提亮"])
        let error = store.persistError ?? ""
        check(chmodBlocks ? error.contains("客户备注") && store.persistRetryable : true,
              "写不上：红条点名客户备注、给「重试」：\(error)")
        let blocked: Bool = !store.switchSession(to: other.folder) && store.sessionDir.lastPathComponent == full.key
        check(chmodBlocks ? blocked && store.clientNotes[id] == "眼睛提亮" : true, "没存上之前切场次被拦下，内存里的备注还在")
        setWritable(full.dir, true)
        let retried = store.retryPersist()
        let wantFull: [String: String] = [id: "眼睛提亮"]
        check(retried && store.persistError == nil && savedNotes(full) == wantFull, "腾出空间点「重试」：备注写上、红条消失")
    }
}
