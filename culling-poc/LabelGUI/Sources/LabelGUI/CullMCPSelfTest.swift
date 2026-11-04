import Foundation

/// 选片 MCP 的几样（概览报 XMP 过期、AI 改判记出处、一次定一场、导入客户选择）在真的 BatchStore 上跑一遍：
/// LABELGUI_DATA_DIR=<临时目录> LabelGUI --cull-mcp-selftest <Fixtures/photot-session>
/// 把 fixture 的 manifest / layer1 灌进临时数据目录里 /tmp/labelgui-fixture-photot 那一场（照片文件夹不存在，和
/// verdict_regression.sh 同一个约定：只读 session JSON），之后只写这个临时数据目录。不开界面、不连 socket。
/// 全部通过 exit 0，有失败的逐条打 FAIL、exit 1。
@MainActor
enum CullMCPSelfTest {
    static let photoDir = URL(fileURLWithPath: "/tmp/labelgui-fixture-photot")

    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        CollageCLI.requireIsolatedDataDir("--cull-mcp-selftest")
        AppUISnapshot.requireNotRealDataDir("--cull-mcp-selftest")
        guard args.count > flagIndex + 1 else {
            print("用法: LABELGUI_DATA_DIR=<临时目录> LabelGUI --cull-mcp-selftest <Fixtures/photot-session>")
            exit(2)
        }
        let fixture = URL(fileURLWithPath: args[flagIndex + 1])
        let key = BatchStore.sessionKey(for: photoDir)
        let sessionDir = appDataDir.appendingPathComponent("sessions/\(key)")
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: sessionDir.path))?.isEmpty ?? true else {
            print("\(sessionDir.path) 已经有东西：换一个空的临时数据目录再跑")
            exit(2)
        }
        try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        for name in ["manifest.json", "layer1_results.json"] {
            do {
                try fm.copyItem(at: fixture.appendingPathComponent(name), to: sessionDir.appendingPathComponent(name))
            } catch {
                print("拷不了 fixture 的 \(name)：\(error.localizedDescription)")
                exit(2)
            }
        }
        var failures: [String] = []
        var total = 0
        func check(_ ok: Bool, _ message: @autoclosure () -> String) {
            total += 1
            if !ok { failures.append(message()) }
        }
        xmpChecks(check, sessionDir: sessionDir)
        clientPickChecks(check, sessionDir: sessionDir)
        provenanceChecks(check, sessionDir: sessionDir)
        sceneChecks(check)
        for f in failures { print("FAIL " + f) }
        if failures.isEmpty {
            print("选片 MCP 自检：\(total) 条检查全部通过")
            exit(0)
        }
        print("选片 MCP 自检：\(failures.count)/\(total) 条失败")
        exit(1)
    }

    typealias Check = (Bool, @autoclosure () -> String) -> Void

    static func open() -> BatchStore {
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: photoDir)
        return store
    }

    static func overviewXMP(_ store: BatchStore) -> (stale: Int?, written: Bool?, warned: Bool) {
        let ov = MCPReadModel.overview(store, session: store.sessionDir.lastPathComponent)
        let xmp = ov["xmp"] as? [String: Any] ?? [:]
        let warned = (ov["warnings"] as? [[String: Any]] ?? []).contains { $0["code"] as? String == "xmp_stale" }
        return (xmp["stale_count"] as? Int, xmp["written"] as? Bool, warned)
    }

    // MARK: - 1. 概览的 xmp（XMP 过期）

    /// 没写过 XMP → written false、stale 0、没有 warning；放一份 xmp_state.json（2 张记成写过、判决和现在的一样，
    /// 3 张记成写过、判决不一样，1 张是别的软件的）再打开 → written true、stale = 没写过的 + 对不上的，带 warning xmp_stale。
    static func xmpChecks(_ check: Check, sessionDir: URL) {
        let store = open()
        let n = store.items.count
        check(n == 21, "fixture 应该是 21 张，实际 \(n)")
        let fresh = overviewXMP(store)
        check(fresh.stale == 0 && fresh.written == false && !fresh.warned,
              "没写过 XMP：xmp {stale_count 0, written false}、没有 xmp_stale：\(fresh)")
        let items = store.items.sorted { $0.id < $1.id }
        guard items.count >= 6 else { return }
        var marks: [String: [String: Any]] = [:]
        for item in items.prefix(2) {
            let m = BatchStore.xmpMark(item)
            marks[item.id] = ["v": m.v, "s": m.s]
        }
        for item in items[2..<5] {
            marks[item.id] = ["v": Verdict.reject.rawValue, "s": -1]
        }
        let state: [String: Any] = ["marks": marks, "foreign": [items[5].id], "foreignRechecked": true]
        let path = sessionDir.appendingPathComponent("xmp_state.json")
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? data.write(to: path, options: .atomic)
        let reopened = open()
        let seeded = overviewXMP(reopened)
        // 21 张：2 张对得上，1 张是别人的，剩下 18 张（3 张对不上 + 15 张没写过）都算过期
        check(seeded.stale == n - 3 && seeded.written == true && seeded.warned && reopened.xmpStaleCount == n - 3,
              "写过 XMP 以后：xmp.stale_count = \(n - 3)、written true、带 xmp_stale：\(seeded)")
        try? FileManager.default.removeItem(at: path)
        let cleared = overviewXMP(open())
        check(cleared.stale == 0 && cleared.written == false && !cleared.warned, "删掉 xmp_state.json 以后回到没写过：\(cleared)")
    }

    // MARK: - 2. 导入客户选择（cull_import_client_picks 用的那几样）

    /// 客户的原话 → resolveClientReply（导入框同一个函数）→ 结果主体（LiveHandlers.clientPicksBody，桥上 dry_run 回的就是它）；
    /// importClientPicks 加选、一步判决撤销；同一批再导一次不压撤销；⌘Z 回到导入之前，client_picks.json 跟着删掉。
    static func clientPickChecks(_ check: Check, sessionDir: URL) {
        let store = open()
        let file = sessionDir.appendingPathComponent("client_picks.json")
        let r = store.resolveClientReply("要这几张：DSCF7208、7209 还有 9999，谢谢")
        let body = LiveHandlers.clientPicksBody(r, existing: store.clientPicks)
        let summary = body["summary"] as? [String] ?? []
        let recognized = r.ids == ["DSCF7208", "DSCF7209"] && r.unknown == ["9999"] && body["new_ids"] as? [String] == r.ids
        let counted = body["already_picked"] as? Int == 0 && body["existing_count"] as? Int == 0
        let noSheet = body["sheet"] is NSNull && body["numbers_without_sheet"] as? Bool == true
        check(recognized && counted && noSheet && summary.first == "认出 2 张 · 没认出 1 个：9999",
              "认客户的原话：文件名 + 文件号认出 2 张，9999 列在没认出，预览第一行和导入框一样：\(body)")
        let pushes = store.overrideUndoPushes
        let depth = store.overrideUndoDepth
        store.importClientPicks(r.ids)
        check(store.clientPickCount == 2 && store.overrideUndoPushes == pushes + 1 && store.overrideUndoDepth == depth + 1
              && FileManager.default.fileExists(atPath: file.path),
              "标上：客户选中 2 张、压一步判决撤销、写了 client_picks.json（\(store.clientPickCount)、\(store.overrideUndoPushes - pushes)）")
        let again = LiveHandlers.clientPicksBody(store.resolveClientReply("DSCF7208 DSCF7230"), existing: store.clientPicks)
        check(again["new_ids"] as? [String] == ["DSCF7230"] && again["already_picked"] as? Int == 1 && again["existing_count"] as? Int == 2,
              "再来一段：已经是客户选中的不算新增：\(again)")
        store.importClientPicks(r.ids)
        check(store.overrideUndoPushes == pushes + 1, "同一批再标一次：不压撤销（\(store.overrideUndoPushes - pushes)）")
        let reopened = open()
        check(reopened.clientPicks == Set(r.ids), "重开以后客户选中还在：\(reopened.clientPicks.sorted())")
        let touched = store.undoLastOverride()
        check(store.clientPickCount == 0 && Set(touched) == Set(r.ids) && !FileManager.default.fileExists(atPath: file.path),
              "⌘Z：客户选中回到 0、动到的是那 2 张、client_picks.json 删掉：\(touched)")
    }

    // MARK: - 3. AI 改判的出处（ai_overrides.json）

    static func diskMarks(_ sessionDir: URL) -> [String: [String: Any]]? {
        let url = sessionDir.appendingPathComponent("ai_overrides.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
    }

    /// AI 改判照样是人工改判（isManual、「人工改判 N」），另记出处；用户亲手改过就拿掉；⌘Z 连出处一起回去（撤掉用户盖过 AI 的
    /// 那一步，出处回来；撤掉 AI 那一步，出处没了）；AI 改两次 previous 留最早的；重开还在；overrides.json 被别的改过、对不上就丢；
    /// 定案 / 接受推荐 / 「只留这张」都算亲手改；阈值建议和「滑杆漏掉」不拿 AI 的当样本；MCP 行的 changed_by。
    static func provenanceChecks(_ check: Check, sessionDir: URL) {
        let store = open()
        let ids = store.items.map(\.id).sorted()
        guard ids.count >= 8 else { return }
        let a = ids[0], b = ids[1], c = ids[2], d = ids[3]
        let groupSizes = store.groupSizes
        store.applyAIOverrides([(id: a, verdict: .reject)], opID: "op-ai-0001", tool: "cull_set_verdicts")
        let disk = diskMarks(sessionDir)?[a] ?? [:]
        let row = MCPReadModel.row(store.item(withID: a)!, store, groupSizes: groupSizes)
        let manual = store.isManual(a) && store.manualOverrideCount == 1 && store.aiOverrideCount == 1
        let source = disk["op_id"] as? String == "op-ai-0001" && disk["tool"] as? String == "cull_set_verdicts"
        let verdictKeys = disk["ai_verdict"] as? String == Verdict.reject.rawValue && disk.keys.contains("previous")
        let previousNull = disk["previous"] is NSNull
        let atParsed = (disk["at"] as? String).flatMap(ISO8601DateFormatter().date(from:)) != nil
        let rowOK = row["manual"] as? Bool == true && row["changed_by"] as? String == "ai"
        let rowText = String(describing: row["changed_by"])
        check(manual && source && verdictKeys && previousNull && atParsed && rowOK,
              "AI 改判：照样是人工改判（manual:true）、「其中 AI 1」，ai_overrides.json 记 {op_id, tool, at, previous:null, ai_verdict}，行上 changed_by ai：\(disk) \(rowText)")
        check(store.manualOverrideLabel == "人工改判 1（其中 AI 1）", "状态栏：\(store.manualOverrideLabel)")
        let detail = MCPReadModel.detail(store.item(withID: a)!, store, groupSizes: groupSizes)
        let ai = detail["ai_override"] as? [String: Any] ?? [:]
        check(ai["op_id"] as? String == "op-ai-0001" && ai["previous"] as? String == "auto" && ai["tool"] as? String == "cull_set_verdicts",
              "cull_get_photos 的 ai_override：op_id、tool、previous auto：\(ai)")
        store.setOverride(a, .reject)
        let userRow = MCPReadModel.row(store.item(withID: a)!, store, groupSizes: groupSizes)
        check(store.aiOverrideCount == 0 && store.isManual(a) && diskMarks(sessionDir) == nil && userRow["changed_by"] as? String == "user"
              && store.manualOverrideLabel == "人工改判 1",
              "用户亲手按了一下（同一个判决）：不再算 AI 的，ai_overrides.json 删掉，changed_by user，状态栏「人工改判 1」")
        store.undoLastOverride()
        check(store.aiOverride(a)?.opID == "op-ai-0001" && store.aiOverrideCount == 1 && diskMarks(sessionDir)?[a] != nil,
              "⌘Z 撤掉用户那一下：AI 的出处回来（内存和 ai_overrides.json）")
        store.undoLastOverride()
        check(store.overrides[a] == nil && store.aiOverrides[a] == nil && store.aiOverrideCount == 0 && diskMarks(sessionDir) == nil,
              "再 ⌘Z 撤掉 AI 那一步：判决回到自动，出处一起没了")
        // AI 改两次：previous 留 AI 第一次动它之前的（用户先判的精选）
        store.setOverride(b, .pick)
        store.applyAIOverrides([(id: b, verdict: .usable)], opID: "op-ai-0002", tool: "cull_set_verdicts")
        store.applyAIOverrides([(id: b, verdict: .reject)], opID: "op-ai-0003", tool: "cull_set_verdicts")
        let mb = store.aiOverride(b)
        check(mb?.opID == "op-ai-0003" && mb?.aiVerdict == Verdict.reject.rawValue && mb?.previous == Verdict.pick.rawValue,
              "AI 改了两次：出处是最后一次的 op_id、ai_verdict，previous 是 AI 动手之前用户判的精选：\(String(describing: mb))")
        store.applyAIOverrides([(id: c, verdict: .pick)], opID: "op-ai-0004", tool: "cull_set_verdicts")
        store.applyAIOverrides([(id: c, verdict: nil)], opID: "op-ai-0005", tool: "cull_set_verdicts")
        check(store.overrides[c] == nil && store.aiOverrides[c] == nil, "AI 恢复自动判决：没有判决可记，出处拿掉")
        store.applyAIOverrides([(id: d, verdict: .pick)], opID: "op-ai-0006", tool: "cull_set_verdicts")
        let reopened = open()
        check(reopened.aiOverride(b)?.opID == "op-ai-0003" && reopened.aiOverride(d)?.opID == "op-ai-0006" && reopened.aiOverrideCount == 2
              && reopened.manualOverrideCount == 2,
              "重开这一场：两张 AI 改判的出处都读回来了（人工改判 2，其中 AI 2）")
        // 老版本 app 打开过、把 d 改成了别的（它不认 ai_overrides.json）：读回来时对不上就丢
        let overridesURL = sessionDir.appendingPathComponent("overrides.json")
        let tampered: [String: String] = [b: Verdict.reject.rawValue, d: Verdict.usable.rawValue]
        if let data = try? JSONEncoder().encode(tampered) { try? data.write(to: overridesURL, options: .atomic) }
        let old = open()
        check(old.aiOverride(b) != nil && old.aiOverride(d) == nil && old.isManual(d) && old.aiOverrideCount == 1,
              "overrides.json 被老版本改过：d 的判决和记下的 AI 判决对不上 → 丢掉出处（照样是人工改判），b 对得上 → 留着")
        // 定案（keepOnly）、分组行「接受推荐」（applyOverrides accepted）、连拍挑选的 ⏎（applyOverrides）都算亲手改
        old.keepOnly([b], among: [b])
        check(old.aiOverride(b) == nil, "连拍定案（keepOnly）：亲手定过的不再算 AI 的")
        old.applyAIOverrides([(id: d, verdict: .reject)], opID: "op-ai-0007", tool: "cull_set_verdicts")
        old.applyOverrides([d: .reject], accepted: true)
        check(old.aiOverrides[d] == nil, "分组行「接受推荐」（applyOverrides）：不再算 AI 的")
        old.setOverrideBatch(old.overrides.keys.sorted(), nil)
        check(old.overrides.isEmpty && old.aiOverrideCount == 0, "全部恢复自动：没有改判、没有出处")
        // 复盘统计：锐度线拉到 200（全场都是虚焦废片）→ AI 放行 3 张不出阈值建议；同样 3 张换成用户亲手放行 → 出建议
        old.sharpnessThreshold = 200
        let blurred = old.items.filter { $0.rejectReasons.contains("虚焦") }.map(\.id).sorted()
        check(blurred.count >= 3, "锐度线 200：虚焦的废片至少 3 张（\(blurred.count)）")
        let three = Array(blurred.prefix(3))
        old.applyAIOverrides(three.map { (id: $0, verdict: Verdict.pick) }, opID: "op-ai-0008", tool: "cull_set_verdicts")
        check(old.thresholdSuggestions.isEmpty && old.aiOverrideCount == 3,
              "AI 放行 3 张虚焦：不出阈值建议（不是摄影师在纠正滑杆）：\(old.thresholdSuggestions.map(\.kind.rawValue))")
        old.setOverrideBatch(three, .pick)
        check(old.thresholdSuggestions.contains { $0.kind == .sharpness && $0.released == 3 } && old.aiOverrideCount == 0,
              "同样 3 张用户亲手放行：出「锐度下限」建议：\(old.thresholdSuggestions.map(\.kind.rawValue))")
        old.setOverrideBatch(three, nil)
        old.sharpnessThreshold = 45
        let clean = old.items.filter { $0.rejectReasons.isEmpty }.map(\.id).sorted()
        old.applyAIOverrides(clean.prefix(2).map { (id: $0, verdict: Verdict.reject) }, opID: "op-ai-0009", tool: "cull_set_verdicts")
        let aiOnly = old.manualRejectsWithoutReason
        old.setOverride(clean[2], .reject)
        check(aiOnly == 0 && old.manualRejectsWithoutReason == 1,
              "「滑杆漏掉」：AI 废掉的 2 张不算（\(aiOnly)），用户亲手废的 1 张算（\(old.manualRejectsWithoutReason)）")
        old.setOverrideBatch(old.overrides.keys.sorted(), nil)
    }

    // MARK: - 4. 一次定一场（cull_set_verdicts 的 changes）

    /// 最大的那一场：推荐的那张 pick、其余 reject，外加别处一张恢复自动 —— 一次 applyAIOverrides、一步撤销，⌘Z 一下全回去。
    static func sceneChecks(_ check: Check) {
        let store = open()
        guard let take = store.takeRows.max(by: { $0.indices.count < $1.indices.count })?.take else {
            check(false, "fixture 里找不到多张的场")
            return
        }
        let members = store.members(ofTake: take).map(\.id)
        guard let keep = members.first(where: { store.takeRank[$0] == 1 }), members.count >= 3,
              let outside = store.items.map(\.id).sorted().first(where: { !members.contains($0) }) else {
            check(false, "场 \(take) 没有推荐的那张、或者不到 3 张")
            return
        }
        store.setOverride(outside, .pick)
        let pushes = store.overrideUndoPushes
        let depth = store.overrideUndoDepth
        var changes: [(id: String, verdict: Verdict?)] = members.map { (id: $0, verdict: $0 == keep ? .pick : .reject) }
        changes.append((id: outside, verdict: nil))
        store.applyAIOverrides(changes, opID: "op-scene-01", tool: "cull_set_verdicts")
        let rejected = members.filter { store.item(withID: $0)?.verdict == .reject }.count
        let alive = store.members(ofTake: take).filter { $0.verdict != .reject }
        let oneStep = store.overrideUndoPushes == pushes + 1 && store.overrideUndoDepth == depth + 1
        let decided = store.item(withID: keep)?.verdict == .pick && rejected == members.count - 1 && !store.isPendingTake(alive: alive)
        check(oneStep && decided && store.overrides[outside] == nil && store.aiOverrideCount == members.count,
              "一次定一场（场 \(take)，\(members.count) 张）：1 张 pick、\(members.count - 1) 张 reject、另一张恢复自动，只压一步撤销，这一场不再待处理")
        let touched = store.undoLastOverride()
        check(Set(touched) == Set(members + [outside]) && store.overrides == [outside: .pick] && store.aiOverrideCount == 0
              && store.overrideUndoDepth == depth,
              "⌘Z 一下：这一场全部回到改判之前，另一张回到用户判的精选，出处都没了")
        store.undoLastOverride()
    }
}
