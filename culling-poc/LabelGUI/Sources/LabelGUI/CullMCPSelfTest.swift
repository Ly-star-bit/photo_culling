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
        deliveredNoteChecks(check)
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

    /// 概览 xmp 里的 last_written（没有这个键 = nil）。
    static func lastWritten(_ store: BatchStore) -> Any? {
        let ov = MCPReadModel.overview(store, session: store.sessionDir.lastPathComponent)
        return (ov["xmp"] as? [String: Any])?["last_written"]
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
        // hint 里的按钮名要和批量页状态栏上的字一样（BatchView.xmpStaleLabel「XMP 待更新 N 张 · 点这里重新写入」），
        // 以前写的「XMP 过期」app 里找不到
        let warnings = MCPReadModel.overview(reopened, session: reopened.sessionDir.lastPathComponent)["warnings"] as? [[String: Any]] ?? []
        let hint = warnings.first { $0["code"] as? String == "xmp_stale" }?["hint"] as? String ?? ""
        check(hint.contains("「XMP 待更新 \(n - 3) 张 · 点这里重新写入」") && !hint.contains("XMP 过期"),
              "xmp_stale 的 hint 用状态栏上真的按钮名：\(hint)")
        // last_written 记在 xmp_state.json 里（writtenAt），不拿文件 mtime 顶：老版本写的那份没有 → 不报
        check(lastWritten(reopened) == nil, "老版本写的 xmp_state.json（没有 writtenAt）：xmp 里没有 last_written")
        // 这一版写的带 writtenAt（JSONEncoder 默认的 Date：从 2001-01-01 起的秒数）→ 概览报带时区的 ISO 8601
        let at = Date(timeIntervalSinceReferenceDate: 815_000_000)
        var stamped = state
        stamped["writtenAt"] = at.timeIntervalSinceReferenceDate
        if let data = try? JSONSerialization.data(withJSONObject: stamped) { try? data.write(to: path, options: .atomic) }
        let withTime = lastWritten(open()) as? String
        let wantTime = MCPReadModel.instantFormatter.string(from: at)
        check(withTime == wantTime, "xmp_state.json 记了 writtenAt：last_written = \(wantTime)（实际 \(withTime ?? "nil")）")
        try? FileManager.default.removeItem(at: path)
        let cleared = overviewXMP(open())
        check(cleared.stale == 0 && cleared.written == false && !cleared.warned, "删掉 xmp_state.json 以后回到没写过：\(cleared)")
        xmpUnknownChecks(check, path: path)
        xmpWrittenAtChecks(check)
    }

    /// xmp_state.json 在、却解不开（NR4：BatchStore 挪开原件、xmpStateUnknown 记原因）：概览照实说不知道 —— written、
    /// stale_count、shared_sidecar_count 都是 null，unknown 写原因，带 xmp_state_unknown（hint 指「导出 › 全部重写 XMP」），
    /// 不带 xmp_stale。以前照旧报 written false、stale 0，看着像这一场没写过 XMP。读得进来的、没写过的没有 unknown 这个键。
    static func xmpUnknownChecks(_ check: Check, path: URL) {
        try? Data("{\"marks\": {\"DSCF72".utf8).write(to: path, options: .atomic)
        // 新建 store 会先自动打开「最近场次」的第一场（就是这一场）：那一下就把坏的挪开了，open() 里再切一次就成了没写过。
        // 先清掉场次索引，坏的那份留给 open() 里那一次读。
        try? FileManager.default.removeItem(at: appDataDir.appendingPathComponent("sessions.json"))
        let store = open()
        let ov = MCPReadModel.overview(store, session: store.sessionDir.lastPathComponent)
        let xmp = ov["xmp"] as? [String: Any] ?? [:]
        let codes = (ov["warnings"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        let nulls: Bool = xmp["written"] is NSNull && xmp["stale_count"] is NSNull && xmp["shared_sidecar_count"] is NSNull
        let reason = xmp["unknown"] as? String ?? ""
        check(store.xmpStateUnknown != nil && nulls && reason.contains("xmp_state.json") && xmp["last_written"] == nil,
              "xmp_state.json 解不开：xmp 里 written / stale_count / shared_sidecar_count 是 null、unknown 写原因：\(xmp)")
        let hint = (ov["warnings"] as? [[String: Any]] ?? []).first { $0["code"] as? String == "xmp_state_unknown" }?["hint"] as? String
        check(codes.contains("xmp_state_unknown") && !codes.contains("xmp_stale") && (hint ?? "").contains("全部重写 XMP"),
              "带 xmp_state_unknown（hint 指「导出 › 全部重写 XMP」）、不带 xmp_stale：\(codes) \(hint ?? "nil")")
        // 挪开的原件留着别的检查用不上：删掉，下面的用例回到没写过
        let dir = path.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix("xmp_state.corrupt") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        let fresh = MCPReadModel.overview(open(), session: store.sessionDir.lastPathComponent)["xmp"] as? [String: Any] ?? [:]
        check(fresh["unknown"] == nil && fresh["written"] as? Bool == false,
              "原件挪开以后再打开：回到没写过（written false，没有 unknown 这个键）：\(fresh)")
    }

    /// 真写一次 XMP（数据目录里造的假拍摄，照 FileSafetySelfTest.makeShoot；照片旁边写 .xmp）：写之前没有 last_written，
    /// 写完是刚才的时间，重开这一场读得回来同一个。
    static func xmpWrittenAtChecks(_ check: Check) {
        let dir = appDataDir.appendingPathComponent("cull-mcp-xmp-shoot")
        let fakes = ["x1", "x2"].map { FileSafetySelfTest.Fake(id: $0, raw: $0 + ".ARW") }
        let store = FileSafetySelfTest.makeShoot(dir, fakes)
        check(store.items.count == 2 && lastWritten(store) == nil, "假拍摄还没写过 XMP：没有 last_written（\(store.items.count) 张）")
        let before = Date()
        store.exportXMP(.all)
        FileSafetySelfTest.wait(store)
        let text = lastWritten(store) as? String
        let parsed = text.flatMap { MCPReadModel.instantFormatter.date(from: $0) }
        let sinceStart = parsed.map { $0.timeIntervalSince(before) } ?? -99
        let untilNow = parsed.map { $0.timeIntervalSinceNow } ?? 99
        check(sinceStart > -2 && untilNow < 2 && store.xmpStaleCount == 0,
              "写完 XMP：last_written 是刚才那次（\(text ?? "nil")，\(store.progressText)）")
        let reopened = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        reopened.switchSession(to: dir)
        check(text != nil && lastWritten(reopened) as? String == text, "重开这一场：last_written 读回来是同一个时间")
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
        clientNoteChecks(check, store: store, sessionDir: sessionDir)
        clientNotePersistChecks(check, store: store, sessionDir: sessionDir)
    }

    /// 带修图要求的回复（审查：桥上以前只传 ids，备注丢了、summary 却说存了）：LiveHandlers.applyClientImport（handler 的
    /// dry_run:false 就走它）和导入框同一条 importClientPicks(ids, notes:) —— 备注进 client_notes.json（精修要求.csv 的行）、
    /// 和客户选中同一步撤销；照片已经是客户选中、只补了备注也算改了；什么都没变不压撤销。结果主体带 notes / new_notes。
    static func clientNoteChecks(_ check: Check, store: BatchStore, sessionDir: URL) {
        let fm = FileManager.default
        let notesFile = sessionDir.appendingPathComponent("client_notes.json")
        let noted = store.resolveClientReply("DSCF7208 去路人\nDSCF7209：瘦脸")
        let wanted: [String: String] = ["DSCF7208": "去路人", "DSCF7209": "瘦脸"]
        let body = LiveHandlers.clientPicksBody(noted, existing: store.clientPicks, existingNotes: store.clientNotes)
        let bodyNotes = body["notes"] as? [String: String]
        let bodyNew = body["new_notes"] as? [String]
        check(noted.ids == ["DSCF7208", "DSCF7209"] && noted.notes == wanted && bodyNotes == wanted
              && bodyNew == ["DSCF7208", "DSCF7209"],
              "认出带备注的两行：notes 是客户原话、new_notes 是这两张：\(body)")
        // 拼图托盘里已经有 DSCF7208（没刷之前 clientPick false）：标完要跟着刷成 true —— 相册编排按它保留客户选中，
        // 用户停在拼图页没切 tab 时没人替它刷（审查：以前 handler 不刷）
        let collage = trayWithPhoto("DSCF7208", store: store, sessionDir: sessionDir)
        let trayBefore = collage.project.photos.first { $0.id == "DSCF7208" }?.clientPick
        let pushes = store.overrideUndoPushes
        let first = LiveHandlers.applyClientImport(noted, batch: store, collage: collage)
        let trayAfter = collage.project.photos.first { $0.id == "DSCF7208" }?.clientPick
        check(trayBefore == false && trayAfter == true,
              "导入以后拼图托盘里 DSCF7208 的 clientPick 跟着刷成 true（之前 \(String(describing: trayBefore))，之后 \(String(describing: trayAfter))）")
        let rows = store.retouchNotes(noted.ids)  // 带备注的几张（精修要求.csv 的行等复制完按实际文件名排）
        check(first.fresh == noted.ids && first.renoted == noted.ids && store.clientNotes == wanted
              && store.clientPicks == Set(noted.ids) && store.overrideUndoPushes == pushes + 1
              && fm.fileExists(atPath: notesFile.path) && rows.count == 2,
              "标上带备注的：客户选中 2 张、备注存进 client_notes.json（精修要求.csv 有 \(rows.count) 行）、一步撤销" +
              "（\(store.clientNotes)、\(store.overrideUndoPushes - pushes) 步）")
        let reopened = open()
        check(reopened.clientNotes == wanted, "重开以后客户备注还在：\(reopened.clientNotes)")
        // 照片已经是客户选中，客户又补了一句：只改备注也要存（导入框走 setClientReply），没写的那张留着原来的
        let more = store.resolveClientReply("DSCF7208 去路人，黑白")
        let moreBody = LiveHandlers.clientPicksBody(more, existing: store.clientPicks, existingNotes: store.clientNotes)
        let second = LiveHandlers.applyClientImport(more, batch: store, collage: collage)
        let merged = store.clientNotes["DSCF7208"] == "去路人，黑白" && store.clientNotes["DSCF7209"] == "瘦脸"
        check(second.fresh.isEmpty && second.renoted == ["DSCF7208"] && second.changed && merged
              && moreBody["new_ids"] as? [String] == [] && moreBody["new_notes"] as? [String] == ["DSCF7208"]
              && store.overrideUndoPushes == pushes + 2
              && LiveHandlers.clientImportNotice(second).hasPrefix("AI：更新了 1 张的客户备注"),
              "都已经是客户选中、只补了备注：照样算改了、再压一步撤销，DSCF7209 的备注留着（\(store.clientNotes)）")
        let third = LiveHandlers.applyClientImport(more, batch: store, collage: collage)
        check(!third.changed && store.overrideUndoPushes == pushes + 2, "同一句再导一次：什么都不变、不压撤销")
        let notice = LiveHandlers.clientImportNotice(first)
        check(notice.hasPrefix("AI：标了 2 张客户选中 · 备注 2 张"), "状态栏那一句带备注张数：\(notice)")
        _ = store.undoLastOverride()
        check(store.clientNotes["DSCF7208"] == "去路人" && store.clientPickCount == 2, "⌘Z 一下：备注回到补之前（\(store.clientNotes)）")
        _ = store.undoLastOverride()
        check(store.clientPickCount == 0 && store.clientNotes.isEmpty && !fm.fileExists(atPath: notesFile.path),
              "再 ⌘Z：客户选中和备注一起回到导入之前，client_notes.json 删掉（\(store.clientNotes)）")
    }

    /// cull_import_client_picks、app_undo 的 persisted 把客户备注也算上（最终审查）：client_picks.json 写上了、client_notes.json
    /// 没写上（这里拿一个同名的非空文件夹挡住，和盘满一样写不进去）也是 persisted false + save_failed —— 以前只看
    /// client_picks.json，照样说「已存盘」。挡住以后的那次导入、撤销都核对；挪开以后重试补写上，回到 true。
    static func clientNotePersistChecks(_ check: Check, store: BatchStore, sessionDir: URL) {
        let fm = FileManager.default
        let notesFile = sessionDir.appendingPathComponent("client_notes.json")
        let files = LiveHandlers.clientReplyFiles
        let undoFiles = LiveHandlers.undoPersistFiles(tool: "cull_import_client_picks")
        check(files.contains(.clientNotes) && undoFiles.contains(.clientNotes) && undoFiles.contains(.clientPicks)
              && LiveHandlers.undoPersistFiles(tool: "cull_set_verdicts") == [.overrides],
              "导入客户选择、撤销它的 persisted 看客户选中 + 客户备注两份，撤改判看 overrides.json：\(files) / \(undoFiles)")
        store.importClientPicks(["DSCF7208"], notes: ["DSCF7208": "去路人"])
        check(LiveHandlers.batchPersistReport(store, files).persisted && fm.fileExists(atPath: notesFile.path),
              "（对照）盘是好的：带备注导入，两份都写上、persisted true")
        // 备注那一份写不进去：client_notes.json 换成一个非空的文件夹（原子写换不掉它）
        try? fm.removeItem(at: notesFile)
        try? fm.createDirectory(at: notesFile, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: notesFile.appendingPathComponent("挡着"))
        store.importClientPicks(["DSCF7209"], notes: ["DSCF7209": "瘦脸"])
        let both = LiveHandlers.batchPersistReport(store, files)
        let picksOnly = LiveHandlers.batchPersistReport(store, [.clientPicks])
        let codes = both.warnings.compactMap { $0["code"] as? String }
        let banner = store.persistError ?? ""
        check(!both.persisted && codes == ["save_failed"] && picksOnly.persisted && banner.contains("客户备注")
              && store.clientNotes["DSCF7209"] == "瘦脸",
              "客户选中写上了、客户备注没写上：persisted false + save_failed（只看 client_picks.json 会是 true），红条说客户备注：\(banner)")
        _ = store.undoLastOverride()
        let undone = LiveHandlers.batchPersistReport(store, undoFiles)
        check(!undone.persisted && store.clientNotes == ["DSCF7208": "去路人"] && !store.clientPicks.contains("DSCF7209"),
              "备注还写不上时撤销这次导入：内存里撤了，persisted false（\(store.clientNotes)）")
        // 挪开以后点「重试」：补写上，回到 true；再撤掉第一次导入，盘上回到什么都没有
        try? fm.removeItem(at: notesFile)
        try? fm.removeItem(at: notesFile.appendingPathExtension("bak"))
        let retried = store.retryPersist()
        check(retried && LiveHandlers.batchPersistReport(store, files).persisted && store.persistError == nil,
              "挪开挡着的文件夹、重试：两份都写上，persisted true、红条没了")
        _ = store.undoLastOverride()
        check(store.clientPickCount == 0 && store.clientNotes.isEmpty && !fm.fileExists(atPath: notesFile.path),
              "再撤掉第一次导入：客户选中、备注都回到 0，client_notes.json 删掉")
    }

    /// 纯数字交付名开头的那一行（审查：W 的 uniqueHead 不看 D 的交付名）：「{序号:3}」导出的 003.jpg、017.jpg 发给客户，
    /// 客户回「003 去路人」「017瘦脸」—— 交付名认得出那张，后面的话也要当备注（以前「去路人」被当闲聊丢掉、「017瘦脸」整个
    /// 没认出）；和「003.jpg 去路人」结果一样。确认表上第 3 张是另一张时说不准：不认、不切备注，照旧报「交付文件名还是编号？」。
    static func deliveredNoteChecks(_ check: Check) {
        let items = open().items
        let others = items.filter { $0.id != "DSCF7208" && $0.id != "DSCF7209" }
        guard let a = items.first(where: { $0.id == "DSCF7208" }), let b = items.first(where: { $0.id == "DSCF7209" }),
              others.count >= 3 else {
            check(false, "fixture 里找不到 DSCF7208 / DSCF7209")
            return
        }
        let files = [DeliveryRecord.File(file: "003.jpg", id: a.id, original: a.rawPath),
                     DeliveryRecord.File(file: "017.jpg", id: b.id, original: b.rawPath)]
        let record = DeliveryRecord(kind: .jpeg, folder: URL(fileURLWithPath: "/tmp/labelgui-fixture-交付"), files: files)
        let r = ClientReply.resolve("003 去路人\n017瘦脸", items: items, sheets: [], deliveries: [record])
        let wanted: [String: String] = [a.id: "去路人", b.id: "瘦脸"]
        check(r.ids == [a.id, b.id] && r.notes == wanted && r.unknown.isEmpty,
              "纯数字交付名开头：003 / 017 认出那两张，后面的话是备注：ids \(r.ids)、notes \(r.notes)、没认出 \(r.unknown)")
        let dotted = ClientReply.resolve("003.jpg 去路人", items: items, sheets: [], deliveries: [record])
        check(dotted.ids == [a.id] && dotted.notes == [a.id: "去路人"], "带 .jpg 写也一样：\(dotted.notes)")
        let sheet = ProofSheet(id: "20261104-120000", date: Date(), scope: "仅精选", ids: others.prefix(3).map(\.id))
        let clash = ClientReply.resolve("003 去路人", items: items, sheets: [sheet], deliveries: [record])
        check(clash.ids.isEmpty && clash.notes.isEmpty && clash.unknown == ["003（交付文件名还是编号？）"],
              "确认表上第 3 张是另一张：说不准，不认也不切备注：ids \(clash.ids)、没认出 \(clash.unknown)")
    }

    /// 一个托盘里只有这一张（clientPick 先记成 false）的拼图工程：写进这一场的 collage.json，再挂到批量页这一场
    /// （= 用户开着拼图页；挂上时按批量页刷一遍，这时还不是客户选中）。
    static func trayWithPhoto(_ id: String, store: BatchStore, sessionDir: URL) -> CollageStore {
        var project = CollageProject()
        var ref = CollagePhotoRef(id: id, path: photoDir.appendingPathComponent(id + ".JPG").path, width: 3, height: 2)
        ref.clientPick = false
        project.photos = [ref]
        if let data = try? JSONEncoder().encode(project) {
            try? data.write(to: sessionDir.appendingPathComponent("collage.json"), options: .atomic)
        }
        let collage = CollageStore(dataDir: appDataDir)
        collage.attach(sessionDir: sessionDir, photoDir: photoDir, batch: store)
        return collage
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
        acceptAttributionChecks(check)
    }

    /// 两个「接受推荐」对 AI 出处的归属不一样，是产品规则（见 BatchStore.acceptAllRecommendations 旁的注释）：AI 把一场里
    /// 一张可用放行成精选以后，顶栏「全部接受推荐」不写本来就钉成精选的那张 → 照旧算 AI 的，同一场别的可用照样变废片；
    /// 分组行「接受推荐」把这一场每一张都写一遍 → 用户在这一场上确认过，算用户的。
    static func acceptAttributionChecks(_ check: Check) {
        let store = open()
        func autoUsable(_ take: Int) -> [String] {
            store.members(ofTake: take).filter { $0.verdict == .usable && store.overrides[$0.id] == nil }.map(\.id)
        }
        guard let take = store.takeRows.map(\.take).first(where: { autoUsable($0).count >= 2 }) else {
            check(false, "fixture 里找不到有 2 张以上自动可用的场")
            return
        }
        let usable = autoUsable(take)
        let target = usable[0]
        let loser = usable[1]
        store.applyAIOverrides([(id: target, verdict: .pick)], opID: "op-ai-accept", tool: "cull_set_verdicts")
        store.acceptAllRecommendations()
        let keptAI = store.aiOverride(target)?.opID == "op-ai-accept" && store.overrides[target] == .pick
        check(keptAI && store.overrides[loser] == .reject,
              "顶栏「全部接受推荐」：同一场的可用 \(loser) 变废片，AI 放行成精选的 \(target) 没被写、照旧算 AI 的")
        store.undoLastOverride()
        store.applyOverrides(store.recommendedDecision(for: store.members(ofTake: take)), accepted: true)
        check(store.aiOverride(target) == nil && store.overrides[target] == .pick && store.overrides[loser] == .reject,
              "分组行「接受推荐」：整场写一遍，用户在这一场上确认过，\(target) 不再算 AI 的")
        store.undoLastOverride()
        store.undoLastOverride()
        check(store.overrides.isEmpty && store.aiOverrideCount == 0, "撤回去：没有改判、没有出处")
    }
}
