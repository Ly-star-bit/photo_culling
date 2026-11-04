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

    // MARK: - AI 改判出处（ai_overrides.json）跟着判决走

    /// 一条 AI 改判出处（和 BatchStore.AIOverride 写出来的一样）。
    func aiMarkJSON(_ id: String, verdict: Verdict) -> Data {
        let mark = "{\"\(id)\":{\"ai_verdict\":\"\(verdict.rawValue)\",\"at\":\"2026-11-01T10:00:00Z\"," +
            "\"op_id\":\"op-old\",\"previous\":null,\"tool\":\"cull_set_verdicts\"}}"
        return Data(mark.utf8)
    }

    func aiOverridesFollowVerdicts() {
        print("— AI 改判出处 ai_overrides.json：和判决一起挪开、一起不写、一起进红条，自己坏了也挪开")
        freshIndex()
        let other = makeSession("ai-other")
        let store = newStore()

        // 判决解不开：出处用同一个时间一起挪开，提示里说
        let bad = makeSession("ai-corrupt-verdicts")
        let aiData = aiMarkJSON("DSCF7207", verdict: .reject)
        try? Data("{\"DSCF7207\": \"废".utf8).write(to: bad.dir.appendingPathComponent("overrides.json"))
        try? aiData.write(to: bad.dir.appendingPathComponent("ai_overrides.json"))
        store.switchSession(to: bad.folder)
        guard let id = store.items.first?.id else {
            check(false, "fixture 读进来了")
            return
        }
        let aiAside = corruptCopies(of: "ai_overrides.json", in: bad.dir)
        let pair = corruptCopies(of: "overrides.json", in: bad.dir).first?.lastPathComponent.dropFirst("overrides".count)
        let aiPair = aiAside.first?.lastPathComponent.dropFirst("ai_overrides".count)
        let movedTogether: Bool = aiAside.count == 1 && aiAside.first.flatMap(read) == aiData && pair != nil && pair == aiPair
        check(movedTogether && !exists(bad.dir.appendingPathComponent("ai_overrides.json")),
              "overrides.json 解不开：ai_overrides.json 用同一个时间一起挪开、一字不差")
        check(store.dataNotice?.contains("ai_overrides.json") == true, "提示里说出处也挪开了：\(store.dataNotice ?? "nil")")
        store.applyAIOverrides([(id: id, verdict: .pick)], opID: "op-new", tool: "cull_set_verdicts")
        check(aiAside.first.flatMap(read) == aiData, "AI 再改判：挪开的出处原件没被碰到")

        // 判决读不出来（权限）：这一场不写判决，出处也不写不删（以前改一张再 ⌘Z 就删掉它）
        if chmodBlocks {
            let locked = makeSession("ai-locked-verdicts")
            let url = locked.dir.appendingPathComponent("overrides.json")
            let aiURL = locked.dir.appendingPathComponent("ai_overrides.json")
            try? Data("{\"DSCF7207\":\"废片\"}".utf8).write(to: url)
            try? aiData.write(to: aiURL)
            setMode(url, 0o000)
            store.switchSession(to: locked.folder)
            store.setOverride(id, .usable)
            store.undoLastOverride()
            check(read(aiURL) == aiData, "判决读不出来时改一张再 ⌘Z：ai_overrides.json 还在、一字不差")
            store.applyAIOverrides([(id: id, verdict: .pick)], opID: "op-locked", tool: "cull_set_verdicts")
            check(read(aiURL) == aiData && !exists(aiURL.appendingPathExtension("bak")), "AI 改判也不盖它（也没备份它：根本没写）")
            setMode(url, 0o644)
            store.switchSession(to: other.folder)
            store.switchSession(to: locked.folder)
            check(store.aiOverrides["DSCF7207"]?.opID == "op-old", "权限恢复后重新打开：AI 改过哪张、出处都读回来")

            // 出处自己读不出来：整份判决这一场不写（判决和出处一起写）
            let aiLocked = makeSession("ai-locked-marks")
            let verdictsURL = aiLocked.dir.appendingPathComponent("overrides.json")
            let verdicts = Data("{\"DSCF7207\":\"废片\"}".utf8)
            let marksURL = aiLocked.dir.appendingPathComponent("ai_overrides.json")
            try? verdicts.write(to: verdictsURL)
            try? aiData.write(to: marksURL)
            setMode(marksURL, 0o000)
            store.switchSession(to: aiLocked.folder)
            store.setOverride(id, .pick)
            setMode(marksURL, 0o644)
            let refused: Bool = read(verdictsURL) == verdicts && read(marksURL) == aiData
            check(refused && store.persistError?.contains("判决") == true && store.dataNotice?.contains("ai_overrides.json") == true,
                  "ai_overrides.json 读不出来：判决也先不写（两份一起写），红条、橙条都说")
            store.switchSession(to: other.folder)
        } else {
            print("SKIP root 跑时 chmod 000 挡不住读，读不出来那两段测不了")
        }

        // 出处自己解不开：挪开、提示，判决照常；下一次 AI 改判写一份新的
        let badMarks = makeSession("ai-corrupt-marks")
        let marksGarbage = Data("{\"DSCF7207\": {\"op_id\": ".utf8)
        try? Data("{\"DSCF7207\":\"废片\"}".utf8).write(to: badMarks.dir.appendingPathComponent("overrides.json"))
        try? marksGarbage.write(to: badMarks.dir.appendingPathComponent("ai_overrides.json"))
        store.switchSession(to: badMarks.folder)
        let marksAside = corruptCopies(of: "ai_overrides.json", in: badMarks.dir)
        check(marksAside.count == 1 && marksAside.first.flatMap(read) == marksGarbage && store.overrides["DSCF7207"] == .reject,
              "ai_overrides.json 解不开：原件挪开、一字不差，判决照常读进来")
        store.applyAIOverrides([(id: id, verdict: .usable)], opID: "op-fresh", tool: "cull_set_verdicts")
        let fresh = CullMCPSelfTest.diskMarks(badMarks.dir)
        check(fresh?[id]?["op_id"] as? String == "op-fresh" && marksAside.first.flatMap(read) == marksGarbage,
              "下一次 AI 改判：写一份新的出处，挪开的原件不碰")

        // 写不上（只读目录）：AI 改判的出处跟判决一起进红条，重试补写
        let full = makeSession("ai-full")
        store.switchSession(to: full.folder)
        setWritable(full.dir, false)
        defer { setWritable(full.dir, true) }
        store.applyAIOverrides([(id: id, verdict: .reject)], opID: "op-full", tool: "cull_set_verdicts")
        check(chmodBlocks ? store.persistError?.contains("判决") == true && CullMCPSelfTest.diskMarks(full.dir) == nil : true,
              "写不上：红条说判决没存上，出处也没写半截")
        setWritable(full.dir, true)
        let retried = store.retryPersist()
        check(retried && CullMCPSelfTest.diskMarks(full.dir)?[id]?["op_id"] as? String == "op-full" && store.persistError == nil,
              "点「重试」：判决和出处一起写上")
    }

    // MARK: - sessions.json 里认不出是哪一场的条目

    func sessionsIndexDropsKeyless() {
        print("— S02c 跟进 sessions.json 里认不出是哪一场的（null、{}、没有 key 也没有 path）：丢掉；认得出的照旧原样留着、提示点名文件夹")
        freshIndex()
        let a = makeSession("s02c-keyless-a"), b = makeSession("s02c-keyless-b"), c = makeSession("s02c-keyless-c")
        let indexURL = dataDir.appendingPathComponent("sessions.json")
        let good: [String: Any] = ["key": a.key, "path": a.folder.path, "name": a.folder.lastPathComponent,
                                   "lastAnalyzed": "2026-11-01T10:00:00Z", "photoCount": 21]
        let noName: [String: Any] = ["key": b.key, "path": b.folder.path, "lastAnalyzed": "2026-11-01T09:00:00Z", "photoCount": 21]
        let pathOnly: [String: Any] = ["path": c.folder.path]
        let list: [Any] = [good, NSNull(), [String: Any](), ["name": "没有 key 也没有 path"], noName, pathOnly]
        try? JSONSerialization.data(withJSONObject: list).write(to: indexURL)

        // MCP 先读（app 还没写过）：认不出的那三条不报，只报认得出的两条、点名文件夹，提示不再是「打开任意场次」
        let before = MCPPaths.readSessionsIndex()
        let problem = before.problem ?? ""
        let hint = before.hint ?? ""
        let problemOK: Bool = problem.contains("2 条读不懂") && problem.contains(b.folder.path) && problem.contains(c.folder.path)
        check(before.entries.map(\.key) == [a.key] && problemOK, "MCP：列好的那一条，说 2 条读不懂（不算认不出的 3 条）、点名文件夹：\(problem)")
        check(hint.contains("选择文件夹") && hint.contains(b.folder.path) && !hint.contains("任意场次"),
              "MCP 的提示：重新打开那个文件夹（不是「打开任意场次」）：\(hint)")

        let store = newStore()  // init 打开 a：登记、写回索引
        let disk = diskIndex()
        let raw = read(indexURL).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
        check(raw?.count == 3 && disk?.unknown.map(\.key) == [b.key, c.key] && disk?.dropped == 0,
              "写回去：认不出的 3 条没了，认得出的 2 条原样留着（\(raw?.count ?? -1) 条）")
        let notice = store.dataNotice ?? ""
        check(notice.contains("2 条读不懂") && notice.contains(b.folder.path) && notice.contains(c.folder.path),
              "橙条说 2 条读不懂、点名是哪两个文件夹：\(notice)")

        // 照提示重新打开那两个文件夹：新的一条取代读不懂的，MCP 的警告没了
        store.switchSession(to: b.folder)
        store.switchSession(to: c.folder)
        let after = MCPPaths.readSessionsIndex()
        check(after.problem == nil && diskIndex()?.unknown.isEmpty == true && after.entries.count == 3,
              "重新打开那两个文件夹以后：索引里没有读不懂的了，MCP 不再报（\(after.problem ?? "nil")）")
    }

    // MARK: - 拼图工程没读进来时「废片移到废纸篓」

    func collageUnknownBlocksTrash() {
        print("— 拼图工程没读进来（解不开 / 读不出来）：「废片移到废纸篓」默认一张都不移，「连这些一起移」照样能移")
        freshIndex()
        typealias Fake = FileSafetySelfTest.Fake
        let ids = ["a", "b", "c"]
        let dir = dataDir.appendingPathComponent("photos/collage-unknown", isDirectory: true)
        let otherDir = dataDir.appendingPathComponent("photos/collage-unknown-other", isDirectory: true)
        FileSafetySelfTest.writeShoot(dir, ids.map { Fake(id: $0, raw: $0 + ".JPG", jpeg: true) })
        FileSafetySelfTest.writeShoot(otherDir, [Fake(id: "x", raw: "x.JPG", jpeg: true)])
        let session = dataDir.appendingPathComponent("sessions/" + BatchStore.sessionKey(for: dir))
        let collageURL = session.appendingPathComponent("collage.json")
        let garbage = Data("{\"pages\": [{\"id\": ".utf8)
        try? garbage.write(to: collageURL)
        // 和 app 同一套接线（AppModel.make），不开实时桥。
        let model = AppModel.make(dataDir: dataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: dataDir), bridge: .none)
        let batch = model.batch
        batch.switchSession(to: dir)
        model.ensureCollageAttached()
        for id in ids { batch.setOverride(id, .reject) }
        batch.refreshCollageInUse()
        let unknown = batch.collageInUseUnknown ?? ""
        let blocked: Bool = batch.trashableRejects.isEmpty && batch.trashableRejectCount == 0 && batch.collageProtectedRejectCount == 3
        check(unknown.contains("解不开") && blocked,
              "collage.json 解不开（内存里是空工程）：默认要移的 0 张，3 张废片都先不移：\(unknown)")
        check(batch.trashableRejectsIncludingCollage.count == 3, "确认框里「连这些一起移」照样是这 3 张")
        // 万一闸失效：原片先删掉，trashRejects 一张都移不动，不会真的往废纸篓里放东西。
        for id in ids { try? fm.removeItem(at: dir.appendingPathComponent(id + ".JPG")) }
        batch.trashRejects()
        let refusedNow: Bool = !batch.isRunning && (batch.lastError ?? "").contains("拼图工程没读进来")
        FileSafetySelfTest.wait(batch)
        check(refusedNow && batch.items.count == 3, "点「移到废纸篓」：一张都不移，状态栏说拼图工程没读进来：\(batch.lastError ?? "nil")")

        // 重新打开（这回读得进来：离开时存了一份新的空工程）：照常按拼图里用到的算。拼图跟着批量页挂到别的场次（app 里是
        // photoDirWatch 下一拍做的，这里同步做一次），切回来才重新读。
        batch.switchSession(to: otherDir)
        model.ensureCollageAttached()
        batch.switchSession(to: dir)
        batch.refreshCollageInUse()
        check(batch.collageInUseUnknown == nil && batch.trashableRejectCount == 3,
              "重新打开、工程读得进来：照常（3 张都能移）" +
              "：\(batch.collageInUseUnknown ?? "nil") / \(batch.trashableRejectCount) / \(batch.items.count) / \(batch.verdictCounts.reject)")

        // 防抖推过来的那一路也带上原因（菜单上的张数）：再写坏、切走切回，不手动刷新
        try? garbage.write(to: collageURL)
        batch.switchSession(to: otherDir)
        model.ensureCollageAttached()
        batch.switchSession(to: dir)
        let pushed = FileSafetySelfTest.waitUntil(10) { batch.collageInUseUnknown != nil }
        check(pushed && batch.trashableRejectCount == 0, "不手动刷新：拼图那边推过来的也说工程没读进来，菜单上要移的是 0 张")

        // 读不出来（权限）：原件还在原处，同样不移
        if chmodBlocks {
            let lockedDir = dataDir.appendingPathComponent("photos/collage-locked", isDirectory: true)
            FileSafetySelfTest.writeShoot(lockedDir, ids.map { Fake(id: $0, raw: $0 + ".JPG", jpeg: true) })
            let lockedURL = dataDir.appendingPathComponent("sessions/" + BatchStore.sessionKey(for: lockedDir))
                .appendingPathComponent("collage.json")
            try? Data("{\"pages\":[]}".utf8).write(to: lockedURL)
            setMode(lockedURL, 0o000)
            defer { setMode(lockedURL, 0o644) }
            batch.switchSession(to: lockedDir)
            for id in ids { batch.setOverride(id, .reject) }
            batch.refreshCollageInUse()
            check((batch.collageInUseUnknown ?? "").contains("读不出来") && batch.trashableRejects.isEmpty,
                  "collage.json 读不出来：同样默认一张都不移：\(batch.collageInUseUnknown ?? "nil")")
            // 拼图原件读不出来、又改过：切场次和判决那边一样先问（拼图页每次存都再报一遍，可以前切场次不问）
            var asked: [String] = []
            batch.confirmDiscardRefused = { _, message in
                asked.append(message)
                return false
            }
            check(batch.switchSession(to: otherDir) && asked.isEmpty, "拼图没改过：切走不问")
            model.ensureCollageAttached()
            batch.switchSession(to: lockedDir)
            model.ensureCollageAttached()
            touchCollage(model.collage)
            let stayed: Bool = !batch.switchSession(to: otherDir) && batch.sessionDir.lastPathComponent == BatchStore.sessionKey(for: lockedDir)
            check(stayed && model.collage.hasRefusedEdits && asked.first?.contains("拼图") == true,
                  "拼图原件读不出来又改过：切场次先问（说是拼图），选留下就不切：\(asked.first ?? "没问")")
            batch.confirmDiscardRefused = { _, _ in true }
        } else {
            print("SKIP root 跑时 chmod 000 挡不住读，读不出来那一段测不了")
        }
        batch.switchSession(to: otherDir)
    }
}
