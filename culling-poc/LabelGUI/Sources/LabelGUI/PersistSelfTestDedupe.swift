import Foundation

/// --persist-selftest 的一组（审查 S20a）：「近似重复只留最佳」按场次存。
/// 全局开关只钉在 argument domain 里（AppRuntime.pinBatchSettings，内存里，不写设置域），跑完换回无头的默认值。
extension PersistSelfTestHarness {
    /// 这一场 thresholds.json 里去重那个键：nil = 文件没有、解不开或者没有这个键。
    func storedDedupe(_ dir: URL) -> Bool? {
        guard let data = read(dir.appendingPathComponent("thresholds.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["rejectBurstDuplicates"] as? Bool
    }

    func storedThresholds(_ dir: URL) -> BatchStore.ThresholdState? {
        read(dir.appendingPathComponent("thresholds.json")).flatMap { try? JSONDecoder().decode(BatchStore.ThresholdState.self, from: $0) }
    }

    func dedupePerSession() {
        print("— S20a 「近似重复只留最佳」按场次存：一场拨开关不改别的场次，老场次按升级前的全局值记下来，命令行钉的不落盘")
        freshIndex()
        let lastUsed = dataDir.appendingPathComponent("thresholds.json")
        try? fm.removeItem(at: lastUsed)
        // 升级前用户把全局开关开着
        AppRuntime.pinBatchSettings(rejectBurstDuplicates: true)
        AppRuntime.pinnedRejectBurstDuplicates = nil
        defer {
            AppRuntime.pinBatchSettings()
            AppRuntime.pinnedRejectBurstDuplicates = nil
        }
        let legacy = Data("{\"sharpness\":45,\"faceQuality\":0,\"exposure\":0.15}".utf8)
        let storedOff = Data("{\"sharpness\":45,\"faceQuality\":0,\"exposure\":0.15,\"rejectBurstDuplicates\":false}".utf8)
        let a = makeSession("s20-a"), b = makeSession("s20-b"), c = makeSession("s20-c")
        try? legacy.write(to: a.dir.appendingPathComponent("thresholds.json"))
        try? legacy.write(to: b.dir.appendingPathComponent("thresholds.json"))
        try? storedOff.write(to: c.dir.appendingPathComponent("thresholds.json"))

        // 界面那条路（老场次回落的值写回去）
        let store = newStore()
        store.writesBackLegacyDedupe = true
        store.switchSession(to: a.folder)
        let dupOn = store.reasonCounts["连拍重复"] ?? 0
        check(store.rejectBurstDuplicates && dupOn > 0,
              "老场次（thresholds.json 没有这个键）回落到升级前的全局开关：开，连拍重复 \(dupOn) 张")
        // 期望值拆成有类型的 let：CI 上的 Xcode 16 对一长串 && 里的字面量类型检查很慢。
        let migrated = storedThresholds(a.dir)
        let wantLegacy = BatchStore.legacyThresholds
        let sameSliders: Bool = migrated?.sharpness == wantLegacy.sharpness && migrated?.exposure == wantLegacy.exposure
        let sameFace: Bool = migrated?.faceQuality == wantLegacy.faceQuality
        let noGap: Bool = migrated != nil && migrated?.takeGap == nil
        let migratedOn: Bool = storedDedupe(a.dir) == true
        check(migratedOn && sameSliders && sameFace && noGap, "回落的值写回这一场（其余阈值一个不动、不补 takeGap）")
        check(!exists(lastUsed), "打开老场次不算「用过」：数据目录里「上次用的」没写")
        let overview = MCPReadModel.overview(store, session: a.key)
        let settings = overview["settings"] as? [String: Any] ?? [:]
        let reportedOn: Bool = (settings["dedupe"] as? Bool) == true
        let dedupeScope: String = settings["dedupe_scope"] as? String ?? ""
        let keepersScope: String = settings["min_keepers_scope"] as? String ?? ""
        check(reportedOn && dedupeScope == "session" && keepersScope == "all_sessions",
              "MCP 概览的 settings：dedupe 是这一场的、dedupe_scope=session、min_keepers_scope=all_sessions：\(settings)")

        store.rejectBurstDuplicates = false
        spin(5) { self.storedDedupe(a.dir) == false && self.storedDedupe(self.dataDir) == false }
        check(storedDedupe(a.dir) == false && (store.reasonCounts["连拍重复"] ?? 0) == 0,
              "在 a 里关掉：a 的 thresholds.json 记下关，连拍重复 0")
        check(storedDedupe(dataDir) == false, "数据目录里「上次用的」也记下关（新场次照它打底）")
        check(BatchStore.globalRejectBurstDuplicates, "全局开关没跟着变（界面不再写 UserDefaults）")

        store.switchSession(to: b.folder)
        let dupB = store.reasonCounts["连拍重复"] ?? 0
        check(store.rejectBurstDuplicates && dupB == dupOn && storedDedupe(b.dir) == true,
              "还没打开过的老场次 b 照旧按升级前的全局值（开）判、写回开，不跟 a 刚拨的走")
        store.switchSession(to: c.folder)
        check(!store.rejectBurstDuplicates && read(c.dir.appendingPathComponent("thresholds.json")) == storedOff,
              "c 存着关：按自己的，不回落、不改写")
        store.switchSession(to: a.folder)
        check(!store.rejectBurstDuplicates && (store.reasonCounts["连拍重复"] ?? 0) == 0, "回到 a：还是关")

        // 全新场次（没分析过）照「上次用的」（关），不照全局（开）
        let newFolder = dataDir.appendingPathComponent("photos/s20-new", isDirectory: true)
        try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
        store.switchSession(to: newFolder)
        check(!store.rejectBurstDuplicates && storedDedupe(store.sessionDir) == false,
              "全新场次照「上次用的」打底：关，写进这一场")
        // 分析过、但从没有 thresholds.json 的老场次：阈值照「上次用的」（以前就这样），去重不跟它，按全局
        let d = makeSession("s20-d")
        store.switchSession(to: d.folder)
        check(store.rejectBurstDuplicates && storedDedupe(d.dir) == true,
              "分析过却没有 thresholds.json 的老场次：去重不跟「上次用的」（关），按升级前的全局值（开）")

        // 无头：读到的全局值是钉在内存里的，不写回
        freshIndex()
        let e = makeSession("s20-e")
        try? legacy.write(to: e.dir.appendingPathComponent("thresholds.json"))
        let headless = newStore()
        headless.switchSession(to: e.folder)
        check(!headless.writesBackLegacyDedupe && headless.rejectBurstDuplicates
              && read(e.dir.appendingPathComponent("thresholds.json")) == legacy,
              "无头打开老场次：按钉住的全局值判、不写回（无头读到的不是界面里那个全局值）")

        // 命令行钉的（--verdicts --dedupe）：盖过存的、不落盘
        AppRuntime.pinnedRejectBurstDuplicates = true
        headless.switchSession(to: c.folder)
        check(headless.rejectBurstDuplicates && (headless.reasonCounts["连拍重复"] ?? 0) == dupOn,
              "钉成开：盖过 c 存的关，连拍重复 \(headless.reasonCounts["连拍重复"] ?? 0) 张")
        headless.takeGapSec = 5
        spin(5) { self.storedThresholds(c.dir)?.takeGap == 5 }
        let pinnedSave = storedThresholds(c.dir)
        check(pinnedSave?.takeGap == 5 && pinnedSave?.rejectBurstDuplicates == false,
              "钉着的时候改间隔：阈值写进去了，去重还是 c 原来存的关")
        headless.rejectBurstDuplicates = true
        spin(1) { false }
        check(storedDedupe(c.dir) == false, "钉着的时候拨开关也只在内存里")
        AppRuntime.pinnedRejectBurstDuplicates = nil
        headless.switchSession(to: c.folder)
        check(!headless.rejectBurstDuplicates, "不钉了再打开 c：关")
    }
}
