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
        check(r.ids == ["DSCF7208", "DSCF7209"] && r.unknown == ["9999"] && body["new_ids"] as? [String] == r.ids
              && body["already_picked"] as? Int == 0 && body["existing_count"] as? Int == 0 && body["sheet"] is NSNull
              && body["numbers_without_sheet"] as? Bool == true && summary.first == "认出 2 张 · 没认出 1 个：9999",
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
}
