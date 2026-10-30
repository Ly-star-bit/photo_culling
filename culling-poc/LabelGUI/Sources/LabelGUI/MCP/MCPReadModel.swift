import Foundation
import CryptoKit

/// 四个读工具的结果（DESIGN §10.4 的 MCPReadModel，§3.2 的字段）：`@MainActor` 的纯读函数 `(批量页的 store, 参数) -> DTO`。
/// **绝不给 store 的任何属性赋值**：`rejectBurstDuplicates` 这类属性的 didSet 会写设置、当场重算用户眼前的判决（§3.2）。
/// 只读已经算好的东西（items、derived、overrides、阈值），所以几千张时也是 O(n)、主线程上几毫秒。
/// v1 只有 app 在桥上调它（LiveHandlers 的 cull.read）；下一版的无头 worker 原样复用，所以放在 MCP/。
/// 结果就是 MCP 工具 text 里的那个 JSON，`--mcp` 只补 warnings（§10.4）；JSON 编码在连接队列上做。
@MainActor
enum MCPReadModel {
    enum Kind: String, CaseIterable {
        case overview, photos, get, groups

        /// 对应的 MCP 工具（参数校验按工具名查 MCPArgs.specs）。
        nonisolated var tool: String {
            switch self {
            case .overview: return "cull_session_overview"
            case .photos: return "cull_list_photos"
            case .get: return "cull_get_photos"
            case .groups: return "cull_list_groups"
            }
        }
    }

    struct Failure: Error {
        let code: String
        let message: String
        let hint: String
    }

    /// cull.read 的入口：参数已经过 MCPArgs.check（LiveHandlers 和 `--mcp` 共用同一份），场次已经核对过是 app 当前那一场。
    /// `textMax`：`--mcp` 的 text 上限（LABELGUI_MCP_TEXT_MAX，经桥传过来）；列表超了在这里截，next_cursor 才接得上。
    static func read(_ kind: Kind, store s: BatchStore, session: String, args: [String: Any],
                     textMax: Int) -> Result<[String: Any], Failure> {
        switch kind {
        case .overview: return .success(overview(s, session: session))
        case .photos: return photos(s, session: session, args: args, textMax: textMax)
        case .get: return getPhotos(s, args: args, textMax: textMax)
        case .groups: return groups(s, session: session, args: args, textMax: textMax)
        }
    }

    // MARK: - 取值的写法（§3.0）

    nonisolated static func verdictName(_ v: Verdict) -> String {
        switch v {
        case .pick: return "pick"
        case .usable: return "usable"
        case .reject: return "reject"
        }
    }

    /// 拍摄时间：照片的本地时间，不带时区；和 loadResults 解析时同一套（en_US_POSIX、当前时区），夏令时那一小时才对得上。
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func time(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return timeFormatter.string(from: date)
    }

    /// 保留 3 位小数。非有限数原样留着，编码时 MCPJSON.sanitize 换成 null（§3.0）。
    nonisolated static func r3(_ x: Double) -> Double {
        (x * 1000).rounded() / 1000
    }

    /// 章节号：和界面上的「章节 N」一样从 1 数；没有拍摄时间的那一堆是 0（时间轴上单独一段、排最后）。
    static func chapterNo(_ item: BatchItem) -> Int {
        item.captureTime == nil ? 0 : item.chapter + 1
    }

    // MARK: - 内存状态指纹（§10.4：cursor 里的 state）

    /// 当前全部照片按顺序的 (id, 判决, 是否人工改判, 场, 近似重复组) 的 SHA-1 前 12 位。每次现算，2,000 张也是毫秒级。
    static func stateFingerprint(_ s: BatchStore) -> String {
        var text = ""
        text.reserveCapacity(s.items.count * 32)
        for item in s.items {
            let manual = s.isManual(item.id) ? "m" : "a"
            text += "\(item.id)\t\(verdictName(item.verdict))\t\(manual)\t\(item.take)\t\(item.burstGroup)\n"
        }
        return MCPCursor.sha1(text, length: 12)
    }

    // MARK: - cull_session_overview

    static func overview(_ s: BatchStore, session: String) -> [String: Any] {
        var out: [String: Any] = ["session": session]
        out["folder"] = s.photoDir?.path ?? NSNull()
        out["name"] = s.photoDir?.lastPathComponent ?? NSNull()
        out["photo_count"] = s.items.count
        let counts = s.verdictCounts
        out["verdict_counts"] = ["pick": counts.pick, "usable": counts.usable, "reject": counts.reject]
        out["reason_counts"] = s.reasonCounts
        out["manual_override_count"] = s.manualOverrideCount
        out["client_pick_count"] = s.clientPickCount

        var thresholds: [String: Any] = ["sharpness": r3(s.sharpnessThreshold)]
        thresholds["clip_pct"] = r3(s.exposureThreshold * 100)
        thresholds["face_quality"] = r3(s.faceQualityThreshold)
        thresholds["preset"] = s.currentPreset?.rawValue ?? "自定义"
        thresholds["scene_gap_sec"] = r3(s.takeGapSec)
        out["thresholds"] = thresholds
        out["threshold_suggestions"] = s.thresholdSuggestions.map { sug -> [String: Any] in
            var row: [String: Any] = ["kind": sug.kind.rawValue, "released": sug.released, "rescued": sug.rescued]
            row["current"] = r3(sug.current)
            row["suggested"] = r3(sug.suggested)
            row["current_text"] = sug.currentText
            row["suggested_text"] = sug.suggestedText
            return row
        }

        out["chapters"] = chapterRows(s)
        out["chapter_warnings"] = s.chapterWarnings
        let takes = s.takeStats
        out["scenes"] = ["multi_photo_scenes": takes.takes, "photos": takes.photos, "pending": s.pendingTakeCount]
        let dups = s.burstGroupStats
        out["near_duplicates"] = ["groups": dups.groups, "photos": dups.photos]
        out["bodies"] = s.bodies.map { b -> [String: Any] in
            var row: [String: Any] = ["body": b.key, "name": b.name, "count": b.count, "offset_sec": b.offset]
            let serial: String = s.items.first(where: { $0.body == b.key })?.bodySerial ?? ""
            row["serial"] = serial.isEmpty ? NSNull() : serial
            row["first"] = time(b.first)
            row["last"] = time(b.last)
            return row
        }
        var settings: [String: Any] = ["dedupe": s.rejectBurstDuplicates, "min_keepers_per_chapter": s.minKeepersPerChapter]
        settings["sort_order"] = s.sortOrder.rawValue
        settings["source"] = "app"
        out["settings"] = settings
        var analysis: [String: Any] = ["running": s.isRunning]
        if s.isRunning { analysis["progress_text"] = s.progressText }
        out["analysis"] = analysis

        var warnings: [[String: Any]] = []
        if s.isRunning {
            warnings.append(warning("analysis_running", "app 正在分析，结果还在变。", hint: "等 app_status 的 live.analysis.running 变成 false 再读一次"))
        }
        if s.unparsedCount > 0 {
            warnings.append(warning("unparsed_photos", "有 \(s.unparsedCount) 张照片在清单里、但没有分析结果（不在任何计数里）。",
                                    hint: "请用户在 app 里点「重新分析」"))
        }
        out["warnings"] = warnings
        return out
    }

    /// 每章一行（§3.2 的 chapters）。只有一章时界面上没有时间轴（chapterSegments 是空的），这里照样给一行。
    static func chapterRows(_ s: BatchStore) -> [[String: Any]] {
        var byChapter: [Int: [BatchItem]] = [:]
        for item in s.items { byChapter[chapterNo(item), default: []].append(item) }
        var takeChapter: [Int: Int] = [:]
        for item in s.items { takeChapter[item.take] = chapterNo(item) }
        var pendingByChapter: [Int: Int] = [:]
        for take in s.pendingTakes {
            if let c = takeChapter[take] { pendingByChapter[c, default: 0] += 1 }
        }
        // 有时间的按章节号（= 时间顺序），没有时间的 0 放最后
        let order = byChapter.keys.sorted { a, b in
            if (a == 0) != (b == 0) { return b == 0 }
            return a < b
        }
        return order.map { chapter -> [String: Any] in
            let members = byChapter[chapter] ?? []
            var pick = 0
            var usable = 0
            var reject = 0
            for m in members {
                switch m.verdict {
                case .pick: pick += 1
                case .usable: usable += 1
                case .reject: reject += 1
                }
            }
            let times = members.compactMap(\.captureTime)
            let keepers = pick + usable
            var row: [String: Any] = ["chapter": chapter, "count": members.count, "pick": pick, "usable": usable, "reject": reject]
            row["start"] = time(times.min())
            row["end"] = time(times.max())
            row["undated"] = chapter == 0
            row["all_rejected"] = keepers == 0
            row["under_min"] = chapter != 0 && keepers > 0 && keepers < s.minKeepersPerChapter
            row["pending_scenes"] = pendingByChapter[chapter] ?? 0
            return row
        }
    }

    nonisolated static func warning(_ code: String, _ message: String, hint: String) -> [String: Any] {
        ["code": code, "message": message, "hint": hint]
    }

    // MARK: - cull_list_photos

    static func photos(_ s: BatchStore, session: String, args: [String: Any], textMax: Int) -> Result<[String: Any], Failure> {
        let verdicts: Set<String> = Set((args["verdict"] as? [String]) ?? [])
        let reason = args["reason"] as? String
        let chapter = args["chapter"].flatMap(MCPArgs.integer)
        let scene = args["scene"].flatMap(MCPArgs.integer)
        let dup = args["near_duplicate"].flatMap(MCPArgs.integer)
        let body = args["body"] as? String
        let manualOnly = args["manual_only"] as? Bool ?? false
        let sort = args["sort"] as? String ?? "time"
        let limit = args["limit"].flatMap(MCPArgs.integer) ?? 50

        // 筛选条件的哈希：cursor 只能用在同一组条件上（limit 不算，换页大小照样接得上）
        var filter: [String: Any] = ["sort": sort, "manual_only": manualOnly]
        filter["verdict"] = verdicts.sorted()
        filter["reason"] = reason ?? NSNull()
        filter["chapter"] = chapter ?? NSNull()
        filter["scene"] = scene ?? NSNull()
        filter["near_duplicate"] = dup ?? NSNull()
        filter["body"] = body ?? NSNull()
        let filterHash = MCPCursor.sha1(MCPJSON.string(filter), length: 12)
        let state = stateFingerprint(s)
        var offset = 0
        var changed = false
        if let raw = args["cursor"] as? String {
            switch MCPCursor.decode(raw, kind: "photos", session: session, filter: filterHash) {
            case .failure(let f): return .failure(f)
            case .success(let c):
                offset = c.offset
                changed = c.state != state
            }
        }

        var matched: [BatchItem] = s.items.filter { item in
            if !verdicts.isEmpty && !verdicts.contains(verdictName(item.verdict)) { return false }
            if let reason, !item.rejectReasons.contains(reason) { return false }
            if let chapter, chapterNo(item) != chapter { return false }
            if let scene, item.take != scene { return false }
            if let dup, item.burstGroup != dup { return false }
            if let body, !bodyMatches(item, body, s) { return false }
            if manualOnly && !s.isManual(item.id) { return false }
            return true
        }
        switch sort {
        case "id":
            matched.sort { $0.id < $1.id }
        case "sharpness":
            // 锐度从高到低（同分按文件夹里的顺序）
            matched.sort { a, b in a.sharpness == b.sharpness ? a.order < b.order : a.sharpness > b.sharpness }
        default:
            BatchStore.sort(&matched, by: .captureTime)
        }
        let total = matched.count
        let start = min(offset, total)
        let page = Array(matched[start..<min(total, start + limit)])
        let groupSizes = s.groupSizes
        let rows: [[String: Any]] = page.map { row($0, s, groupSizes: groupSizes) }
        var out: [String: Any] = ["total": total, "returned": rows.count, "rows": rows, "offset": start]
        func cursor(_ next: Int) -> Any {
            next < total ? MCPCursor.encode(.init(offset: next, kind: "photos", session: session, filter: filterHash, state: state)) : NSNull()
        }
        out["next_cursor"] = cursor(start + rows.count)
        if changed { out["session_changed"] = true }
        let fitted = MCPJSON.fittingObject(out, list: "rows", limit: textMax) { o, kept in
            o["truncated"] = true
            o["returned"] = kept
            o["next_cursor"] = cursor(start + kept)
        }
        return .success(fitted)
    }

    /// 机身筛选：机身 key（同型号两台时带序列号）、型号、序列号、界面上显示的名字，哪个对上都算。
    static func bodyMatches(_ item: BatchItem, _ body: String, _ s: BatchStore) -> Bool {
        if item.body == body || item.camera == body || (item.bodySerial ?? "") == body { return true }
        return s.bodies.contains { $0.key == item.body && $0.name == body }
    }

    /// 一张照片一行（§3.2）：值为空的字段省略。clip_pct 是百分数（和 thresholds.clip_pct 同一个单位）。
    static func row(_ item: BatchItem, _ s: BatchStore, groupSizes: [Int: Int]) -> [String: Any] {
        var r: [String: Any] = ["id": item.id, "verdict": verdictName(item.verdict), "reasons": item.rejectReasons]
        if let t = item.captureTime { r["capture_time"] = timeFormatter.string(from: t) }
        r["chapter"] = chapterNo(item)
        r["scene"] = item.take
        if let rank = s.takeRank[item.id] { r["scene_rank"] = rank }
        if (groupSizes[item.burstGroup] ?? 0) > 1 { r["near_duplicate"] = item.burstGroup }
        r["sharpness"] = r3(item.sharpness)
        r["clip_pct"] = r3(item.worstClipPct * 100)
        if let q = item.faceQuality { r["face_quality"] = r3(q) }
        r["faces"] = item.faceCount
        r["eyes_closed"] = item.faces.filter { $0.eyeClosed == true }.count
        r["manual"] = s.isManual(item.id)
        if s.clientPicks.contains(item.id) { r["client_pick"] = true }
        return r
    }

    // MARK: - cull_get_photos

    static func getPhotos(_ s: BatchStore, args: [String: Any], textMax: Int) -> Result<[String: Any], Failure> {
        let ids = MCPArgs.uniqueStrings(args["ids"])
        var photos: [[String: Any]] = []
        var missing: [String] = []
        let groupSizes = s.groupSizes
        for id in ids {
            guard let item = s.item(withID: id) else {
                missing.append(id)
                continue
            }
            photos.append(detail(item, s, groupSizes: groupSizes))
        }
        if photos.isEmpty {
            return .failure(Failure(code: "photo_not_found", message: "这些 id 在 app 当前这一场里都没有：\(missing.joined(separator: ", "))。",
                                    hint: "id 是文件名去掉扩展名（比如 DSCF7208）；先 cull_list_photos 看有哪些"))
        }
        let out: [String: Any] = ["photos": photos, "missing_ids": missing]
        let fitted = MCPJSON.fittingObject(out, list: "photos", limit: textMax) { o, kept in
            o["truncated"] = true
            o["truncated_ids"] = photos.dropFirst(kept).compactMap { $0["id"] as? String }
        }
        return .success(fitted)
    }

    /// 一张照片的全部分析（§3.2 cull_get_photos）。路径只给原图（§3.0：结果里的路径只指向输出目录或原图）。
    static func detail(_ item: BatchItem, _ s: BatchStore, groupSizes: [Int: Int]) -> [String: Any] {
        var d = row(item, s, groupSizes: groupSizes)
        d["original_path"] = item.rawPath
        if item.decodePath != item.rawPath { d["decode_path"] = item.decodePath }
        d["camera"] = item.camera ?? NSNull()
        d["body"] = item.body.isEmpty ? NSNull() : item.body
        let serial: String = item.bodySerial ?? ""
        d["serial"] = serial.isEmpty ? NSNull() : serial
        d["clock_offset_sec"] = item.clockOffset
        let original: Date? = item.captureTime?.addingTimeInterval(Double(-item.clockOffset))
        d["capture_time_original"] = time(original)
        if let sub = item.captureSubsec { d["capture_subsec"] = r3(sub) }
        if let e = item.exif {
            var exif: [String: Any] = [:]
            if let v = e.shutterSec { exif["shutter_sec"] = v }
            if let v = e.aperture { exif["aperture"] = r3(v) }
            if let v = e.iso { exif["iso"] = v }
            if let v = e.focal35 { exif["focal_35"] = v }
            if let v = e.lens { exif["lens"] = v }
            if !e.summary.isEmpty { exif["summary"] = e.summary }
            d["exif"] = exif
        }
        d["slow_shutter"] = item.slowShutter
        if let h = item.horizonDeg { d["horizon_deg"] = r3(h) }
        d["tilted"] = item.tilted
        if let a = item.faceAreaPct { d["face_area_pct"] = r3(a) }
        d["faces_detail"] = item.faces.map { f -> [String: Any] in
            var face: [String: Any] = ["bbox": f.bbox.map { r3($0) }]
            face["eye_closed"] = f.eyeClosed ?? NSNull()
            face["ear"] = f.ear.map { r3($0) } ?? NSNull()
            face["area_pct"] = f.areaPct.map { r3($0) } ?? NSNull()
            return face
        }
        if let v = item.faceLuma { d["face_luma"] = r3(v) }
        if let v = item.frameLuma { d["frame_luma"] = r3(v) }
        if let v = item.frameLumaP99 { d["frame_luma_p99"] = r3(v) }
        d["file_corrupt"] = item.fileCorrupt
        d["near_duplicate_size"] = groupSizes[item.burstGroup] ?? 1
        if let e = item.expressionScore { d["expression_score"] = e }
        if item.vlmReject || !item.vlmCompositionIssues.isEmpty || item.vlmReason != nil {
            var vlm: [String: Any] = ["reject": item.vlmReject, "composition_issues": item.vlmCompositionIssues]
            vlm["reason"] = item.vlmReason ?? NSNull()
            d["vlm"] = vlm
        }
        if item.appealClosedEyes != nil || item.appealSubjectSharp != nil || item.appealIntentionalExposure != nil {
            var appeal: [String: Any] = ["closed_eyes": item.appealClosedEyes ?? NSNull()]
            appeal["subject_sharp"] = item.appealSubjectSharp ?? NSNull()
            appeal["intentional_exposure"] = item.appealIntentionalExposure ?? NSNull()
            appeal["reason"] = item.appealReason ?? NSNull()
            d["appeal"] = appeal
        }
        if !item.vlmRescued.isEmpty { d["vlm_rescued"] = item.vlmRescued }
        d["override"] = s.overrides[item.id].map { verdictName($0) } ?? NSNull()
        d["accepted_recommendation"] = s.overrides[item.id] != nil && !s.isManual(item.id)
        d["client_pick"] = s.clientPicks.contains(item.id)
        return d
    }

    // MARK: - cull_list_groups

    static func groups(_ s: BatchStore, session: String, args: [String: Any], textMax: Int) -> Result<[String: Any], Failure> {
        let kind = args["kind"] as? String ?? "scene"
        let minSize = args["min_size"].flatMap(MCPArgs.integer) ?? 2
        let limit = args["limit"].flatMap(MCPArgs.integer) ?? 30
        let filter: [String: Any] = ["kind": kind, "min_size": minSize]
        let filterHash = MCPCursor.sha1(MCPJSON.string(filter), length: 12)
        let state = stateFingerprint(s)
        var offset = 0
        var changed = false
        if let raw = args["cursor"] as? String {
            switch MCPCursor.decode(raw, kind: "groups", session: session, filter: filterHash) {
            case .failure(let f): return .failure(f)
            case .success(let c):
                offset = c.offset
                changed = c.state != state
            }
        }
        let all: [[String: Any]]
        switch kind {
        case "chapter": all = chapterGroups(s, minSize: minSize)
        case "near_duplicate": all = dupGroups(s, minSize: minSize)
        default: all = sceneGroups(s, minSize: minSize)
        }
        let total = all.count
        let start = min(offset, total)
        let page = Array(all[start..<min(total, start + limit)])
        var out: [String: Any] = ["kind": kind, "total": total, "returned": page.count, "groups": page, "offset": start]
        func cursor(_ next: Int) -> Any {
            next < total ? MCPCursor.encode(.init(offset: next, kind: "groups", session: session, filter: filterHash, state: state)) : NSNull()
        }
        out["next_cursor"] = cursor(start + page.count)
        if changed { out["session_changed"] = true }
        let fitted = MCPJSON.fittingObject(out, list: "groups", limit: textMax) { o, kept in
            o["truncated"] = true
            o["returned"] = kept
            o["next_cursor"] = cursor(start + kept)
        }
        return .success(fitted)
    }

    /// 一组最多列这么多个成员（一章可能有上千张）；多的标 members_truncated，用 cull_list_photos 按条件翻。
    static let memberCap = 100

    /// 场（take）：和 `--verdicts` 里「场 N (k 张)」那几行是同一个东西 —— 成员按拍摄时间，名次是场内排名（#1 推荐保留），
    /// pending = 还要人取舍（isPendingTake）。
    static func sceneGroups(_ s: BatchStore, minSize: Int) -> [[String: Any]] {
        let pending = Set(s.pendingTakes)
        var takes: [Int] = []
        var seen = Set<Int>()
        for row in s.takeRows where !seen.contains(row.take) {
            seen.insert(row.take)
            takes.append(row.take)
        }
        takes.sort()
        var out: [[String: Any]] = []
        for take in takes {
            let members = s.members(ofTake: take)
            guard members.count >= minSize else { continue }
            var g = groupRow(key: take, members, s) { s.takeRank[$0.id] }
            g["pending"] = pending.contains(take)
            out.append(g)
        }
        return out
    }

    /// 近似重复（burstGroup）：名次和场内名次同一个分数（BatchStore.scoreKey），只排没被淘汰的。
    static func dupGroups(_ s: BatchStore, minSize: Int) -> [[String: Any]] {
        var byGroup: [Int: [BatchItem]] = [:]
        for item in s.items { byGroup[item.burstGroup, default: []].append(item) }
        var out: [[String: Any]] = []
        for key in byGroup.keys.sorted() {
            var members = byGroup[key] ?? []
            guard members.count >= minSize else { continue }
            BatchStore.sort(&members, by: .captureTime)
            let alive = members.filter { $0.verdict != .reject }
            let ranked = alive.sorted { BatchStore.scoreKey($0) > BatchStore.scoreKey($1) }
            var rank: [String: Int] = [:]
            if ranked.count > 1 {
                for (i, item) in ranked.enumerated() { rank[item.id] = i + 1 }
            }
            out.append(groupRow(key: key, members, s) { rank[$0.id] })
        }
        return out
    }

    /// 章节：成员按拍摄时间。名次不排（章节里不是互相取舍的关系）。
    static func chapterGroups(_ s: BatchStore, minSize: Int) -> [[String: Any]] {
        var byChapter: [Int: [BatchItem]] = [:]
        for item in s.items { byChapter[chapterNo(item), default: []].append(item) }
        let order = byChapter.keys.sorted { a, b in
            if (a == 0) != (b == 0) { return b == 0 }
            return a < b
        }
        var out: [[String: Any]] = []
        for key in order {
            var members = byChapter[key] ?? []
            guard members.count >= minSize else { continue }
            BatchStore.sort(&members, by: .captureTime)
            var g = groupRow(key: key, members, s) { _ in nil }
            g["undated"] = key == 0
            out.append(g)
        }
        return out
    }

    static func groupRow(key: Int, _ members: [BatchItem], _ s: BatchStore, rank: (BatchItem) -> Int?) -> [String: Any] {
        let times = members.compactMap(\.captureTime)
        var g: [String: Any] = ["key": key, "count": members.count]
        if let first = members.first { g["chapter"] = chapterNo(first) }
        g["start"] = time(times.min())
        g["end"] = time(times.max())
        var recommended: Any = NSNull()
        let shown = members.prefix(memberCap)
        g["members"] = shown.map { m -> [String: Any] in
            var row: [String: Any] = ["id": m.id, "verdict": verdictName(m.verdict), "manual": s.isManual(m.id)]
            if let r = rank(m) {
                row["rank"] = r
                if r == 1 { recommended = m.id }
            }
            return row
        }
        // 推荐的那张可能排在截掉的后面
        if recommended is NSNull, let best = members.first(where: { rank($0) == 1 }) { recommended = best.id }
        g["recommended"] = recommended
        if members.count > memberCap { g["members_truncated"] = true }
        return g
    }
}

/// cull_list_photos / cull_list_groups 的 cursor（§10.4）：base64url 编码的 {offset, 筛选条件哈希, session, state}。
/// session 对不上 → invalid_argument；state（内存状态指纹）变了 → 从同一个 offset 接着给，带 session_changed:true。
enum MCPCursor {
    struct Payload: Equatable {
        let offset: Int
        let kind: String
        let session: String
        let filter: String
        let state: String
    }

    static func sha1(_ text: String, length: Int) -> String {
        String(sha1Data(Data(text.utf8)).prefix(length))
    }

    /// 字节的 SHA-1（40 位十六进制）：预览文件按内容起名也用它（§10.3）。
    static func sha1Data(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ p: Payload) -> String {
        let obj: [String: Any] = ["o": p.offset, "k": p.kind, "s": p.session, "f": p.filter, "t": p.state]
        let b64 = Data(MCPJSON.string(obj).utf8).base64EncodedString()
        return b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func parse(_ raw: String) -> Payload? {
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let offset = obj["o"].flatMap(MCPArgs.integer), offset >= 0,
              let kind = obj["k"] as? String, let session = obj["s"] as? String,
              let filter = obj["f"] as? String, let state = obj["t"] as? String else { return nil }
        return Payload(offset: offset, kind: kind, session: session, filter: filter, state: state)
    }

    static func decode(_ raw: String, kind: String, session: String, filter: String) -> Result<Payload, MCPReadModel.Failure> {
        guard let p = parse(raw), p.kind == kind else {
            return .failure(.init(code: "invalid_argument", message: "cursor 不是这个工具上一页给的。",
                                  hint: "cursor 原样传回上一页结果里的 next_cursor；从头翻就不带 cursor"))
        }
        guard p.session == session else {
            return .failure(.init(code: "invalid_argument", message: "cursor 是另一场的（app 当前打开的已经不是那一场）。",
                                  hint: "不带 cursor 从头列这一场"))
        }
        guard p.filter == filter else {
            return .failure(.init(code: "invalid_argument", message: "cursor 和这次的筛选条件对不上（换了条件就要从头翻）。",
                                  hint: "筛选条件和上一页保持一样，或者不带 cursor 从头列"))
        }
        return .success(p)
    }
}

/// 要 app 的 15 个工具的参数校验（§3.0、§10.1 的 schema）：`--mcp`（MCPLiveTools）先查一遍、早点给错，app（LiveHandlers）
/// 再按同一份查（§9.2.3：参数用和 MCP 工具同一份校验代码）。schema 里没写的属性一律不收；uniqueItems 只当提示，这里去重
/// 不报错（§3.0）。session 只看类型，和 app 当前那一场的比对在 MCPLiveTools.checkSession / app 那一侧。
/// 写工具另有几条 schema 写不出来的规矩（至少给一个字段、cell_text 要带 if_digest），见 rules。
enum MCPArgs {
    struct Problem: Error {
        let message: String
        let hint: String
    }

    enum Spec {
        case string(maxLength: Int)
        case int(ClosedRange<Int>)
        case bool
        case oneOf([String])
        case strings(count: ClosedRange<Int>, maxLength: Int, oneOf: [String]?)
        /// deadline_seconds：5 到 LABELGUI_MCP_DEADLINE_SEC（app 这一侧不查上限，`--mcp` 已经按它截过）。
        case deadline
        /// 可以是空字符串的文字（标题、刊头……：空 = 清掉 / 按标题生成）。
        case text(maxLength: Int)
        /// 数（整数也算，true / false 不算）。
        case number(ClosedRange<Double>)
        /// op_id：8–64 个字。
        case opID
        /// collage_set_text 的 cell_text：{path: 0–8 位数字, index: ≥0 的整数, text: 字符串}，别的键不收。
        case cellText
    }

    struct ToolSpec {
        let props: [String: Spec]
        let required: [String]
    }

    // 一个工具一个 let（Xcode 16 的类型检查器碰到一整个嵌套的大字面量会超时，§10.6 那条 6.1.2 门禁）
    static let session: Spec = .string(maxLength: 1024)
    static let cursor: Spec = .string(maxLength: 512)
    static let limit: Spec = .int(1...100)
    static let overviewSpec = ToolSpec(props: ["session": session], required: [])
    static let photosSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "cursor": cursor, "limit": limit, "manual_only": .bool]
        p["verdict"] = .strings(count: 0...3, maxLength: 16, oneOf: ["pick", "usable", "reject"])
        p["reason"] = .string(maxLength: 40)
        p["chapter"] = .int(0...1_000_000)
        p["scene"] = .int(0...1_000_000_000)
        p["near_duplicate"] = .int(0...1_000_000_000)
        p["body"] = .string(maxLength: 120)
        p["sort"] = .oneOf(["time", "id", "sharpness"])
        return ToolSpec(props: p, required: [])
    }()
    static let getSpec = ToolSpec(props: ["session": session, "ids": .strings(count: 1...20, maxLength: 128, oneOf: nil)],
                                  required: ["ids"])
    static let groupsSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "cursor": cursor, "limit": limit]
        p["kind"] = .oneOf(["chapter", "scene", "near_duplicate"])
        p["min_size"] = .int(1...100)
        return ToolSpec(props: p, required: ["kind"])
    }()
    static let previewSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "inline": .bool, "deadline_seconds": .deadline]
        p["ids"] = .strings(count: 1...4, maxLength: 128, oneOf: nil)
        p["crop"] = .oneOf(["full", "face"])
        p["max_edge"] = .int(256...1568)
        return ToolSpec(props: p, required: ["ids"])
    }()
    static let collageStateSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "include_preview": .bool, "inline": .bool]
        p["max_edge"] = .int(256...1024)
        return ToolSpec(props: p, required: [])
    }()

    // 写工具（§9.3）：reveal / op_id / if_digest / inline 是几个工具共用的
    static let digest: Spec = .text(maxLength: 64)
    static let openSpec = ToolSpec(props: ["session": session, "confirm": .bool, "reveal": .bool, "op_id": .opID], required: [])
    static let verdictsSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "reveal": .bool, "op_id": .opID]
        p["ids"] = .strings(count: 1...500, maxLength: 128, oneOf: nil)
        p["verdict"] = .oneOf(["pick", "usable", "reject", "auto"])
        return ToolSpec(props: p, required: ["ids", "verdict"])
    }()
    static let showSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "reveal": .bool, "mode": .oneOf(["select", "focus"])]
        p["ids"] = .strings(count: 1...200, maxLength: 128, oneOf: nil)
        return ToolSpec(props: p, required: ["ids"])
    }()
    static let templateSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "if_digest": digest, "reveal": .bool, "op_id": .opID, "inline": .bool]
        p["template"] = .string(maxLength: 80)
        return ToolSpec(props: p, required: ["template"])
    }()
    static let kitSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "if_digest": digest, "reveal": .bool, "op_id": .opID, "inline": .bool]
        p["kit"] = .oneOf(MCPToolDefs.kitIDs)
        p["deadline_seconds"] = .deadline
        return ToolSpec(props: p, required: ["kit"])
    }()
    static let coverSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "if_digest": digest, "reveal": .bool, "op_id": .opID, "inline": .bool]
        p["steps"] = .int(1...20)
        p["deadline_seconds"] = .deadline
        return ToolSpec(props: p, required: [])
    }()
    static let textSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "if_digest": digest, "reveal": .bool, "op_id": .opID, "inline": .bool]
        p["title"] = .text(maxLength: 60)
        p["subtitle"] = .text(maxLength: 120)
        p["masthead"] = .text(maxLength: 40)
        p["issue"] = .text(maxLength: 20)
        p["cell_text"] = .cellText
        return ToolSpec(props: p, required: [])
    }()
    static let styleSpec: ToolSpec = {
        var p: [String: Spec] = ["session": session, "if_digest": digest, "reveal": .bool, "op_id": .opID, "inline": .bool]
        p["style"] = .oneOf(MCPToolDefs.styleKeys)
        p["look"] = .oneOf(MCPToolDefs.lookKeys)
        p["look_strength"] = .number(0...1)
        return ToolSpec(props: p, required: [])
    }()
    static let undoSpec: ToolSpec = {
        let p: [String: Spec] = ["session": session, "op_id": .opID, "target": .oneOf(["verdicts", "collage"])]
        return ToolSpec(props: p, required: ["target"])
    }()

    /// 每个工具认的参数和必填的（session 不在必填里：它的规矩在路由表，§10.2）。
    static let specs: [String: ToolSpec] = {
        var s: [String: ToolSpec] = [
            "cull_session_overview": overviewSpec, "cull_list_photos": photosSpec, "cull_get_photos": getSpec,
            "cull_list_groups": groupsSpec, "cull_preview_photos": previewSpec, "collage_get_state": collageStateSpec,
        ]
        s["app_open_session"] = openSpec
        s["cull_set_verdicts"] = verdictsSpec
        s["cull_show_photos"] = showSpec
        s["collage_apply_template"] = templateSpec
        s["collage_run_kit"] = kitSpec
        s["collage_next_cover"] = coverSpec
        s["collage_set_text"] = textSpec
        s["collage_set_style"] = styleSpec
        s["app_undo"] = undoSpec
        return s
    }()

    /// schema 写不出来的几条（§9.3）：改字、换样式至少给一个字段；cell_text 必须同时带 if_digest（格子下标在用户改过版式
    /// 以后会指错地方）。
    static func rules(_ tool: String, _ args: [String: Any]) -> Problem? {
        func given(_ k: String) -> Bool { args[k] != nil && !(args[k] is NSNull) }
        switch tool {
        case "collage_set_text":
            guard ["title", "subtitle", "masthead", "issue", "cell_text"].contains(where: given) else {
                return Problem(message: "collage_set_text 至少要给一个字段：title、subtitle、masthead、issue、cell_text。", hint: "")
            }
            if given("cell_text") && !given("if_digest") {
                return Problem(message: "cell_text 必须同时带 if_digest。",
                               hint: "先 collage_get_state 拿 digest 和 cells[].path，再带着 if_digest 调（用户改过版式以后格子下标会指错地方）")
            }
        case "collage_set_style":
            guard ["style", "look", "look_strength"].contains(where: given) else {
                return Problem(message: "collage_set_style 至少要给一个字段：style、look、look_strength。", hint: "取值见 collage_list_templates")
            }
        default:
            break
        }
        return nil
    }

    /// JSON 里的整数（true / false、带小数的都不算）。
    static func integer(_ raw: Any) -> Int? {
        MCPInProcessTools.integer(raw)
    }

    /// 字符串数组去重（保持顺序）；不是数组 = 空。
    static func uniqueStrings(_ raw: Any?) -> [String] {
        var seen = Set<String>()
        return ((raw as? [Any]) ?? []).compactMap { $0 as? String }.filter { seen.insert($0).inserted }
    }

    /// nil = 没问题。`deadlineCap`：`--mcp` 的 LABELGUI_MCP_DEADLINE_SEC（app 一侧传 nil，不查上限）。
    static func check(_ tool: String, _ args: [String: Any], deadlineCap: Int? = nil) -> Problem? {
        guard let spec = specs[tool] else { return Problem(message: "没有这个工具：\(tool)", hint: "") }
        let names = spec.props.keys.sorted().joined(separator: "、")
        if let extra = args.keys.sorted().first(where: { spec.props[$0] == nil }) {
            return Problem(message: "\(tool) 不认参数 \(extra)。", hint: "能用的参数：\(names)")
        }
        for name in spec.required where args[name] == nil || args[name] is NSNull {
            return Problem(message: "\(tool) 缺必填参数 \(name)。", hint: "能用的参数：\(names)")
        }
        for name in args.keys.sorted() {
            guard let s = spec.props[name], let value = args[name], !(value is NSNull) else { continue }
            if let problem = checkValue(name, value, s, deadlineCap: deadlineCap) { return problem }
        }
        return rules(tool, args)
    }

    static func checkValue(_ name: String, _ value: Any, _ spec: Spec, deadlineCap: Int?) -> Problem? {
        switch spec {
        case .string(let maxLength):
            guard let s = value as? String, !s.isEmpty, s.count <= maxLength else {
                return Problem(message: "\(name) 要是 1–\(maxLength) 个字的字符串。", hint: "")
            }
        case .int(let range):
            guard let n = integer(value), range.contains(n) else {
                return Problem(message: "\(name) 要是 \(range.lowerBound)–\(range.upperBound) 的整数。", hint: "")
            }
        case .bool:
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                return Problem(message: "\(name) 要是 true 或 false。", hint: "")
            }
        case .oneOf(let allowed):
            guard let s = value as? String, allowed.contains(s) else {
                return Problem(message: "\(name) 只能是 \(allowed.joined(separator: " / "))。", hint: "")
            }
        case .strings(let count, let maxLength, let allowed):
            guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else {
                return Problem(message: "\(name) 要是字符串数组。", hint: "")
            }
            let unique = uniqueStrings(list)
            guard count.contains(unique.count) else {
                return Problem(message: "\(name) 要 \(count.lowerBound)–\(count.upperBound) 个（去重以后）。", hint: "")
            }
            for s in unique {
                guard !s.isEmpty, s.count <= maxLength else {
                    return Problem(message: "\(name) 里每一项要是 1–\(maxLength) 个字。", hint: "")
                }
                if let allowed, !allowed.contains(s) {
                    return Problem(message: "\(name) 里的值只能是 \(allowed.joined(separator: " / "))，不认 \(s)。", hint: "")
                }
            }
        case .deadline:
            let cap = deadlineCap ?? 600
            guard let n = integer(value), (5...max(5, cap)).contains(n) else {
                return Problem(message: "\(name) 要是 5–\(max(5, cap)) 的整数（秒）。", hint: "上限是 LABELGUI_MCP_DEADLINE_SEC")
            }
        case .text(let maxLength):
            guard let s = value as? String, s.count <= maxLength else {
                return Problem(message: "\(name) 要是最多 \(maxLength) 个字的字符串。", hint: "")
            }
        case .number(let range):
            guard let x = number(value), range.contains(x) else {
                return Problem(message: "\(name) 要是 \(range.lowerBound)–\(range.upperBound) 之间的数。", hint: "")
            }
        case .opID:
            guard let s = value as? String, (8...64).contains(s.count) else {
                return Problem(message: "\(name) 要是 8–64 个字的字符串。", hint: "原样传回上一次结果里的 op_id")
            }
        case .cellText:
            return checkCellText(name, value)
        }
        return nil
    }

    /// JSON 里的数（整数、小数都算；true / false、非有限数不算）。
    static func number(_ raw: Any) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let x = n.doubleValue
        return x.isFinite ? x : nil
    }

    static func checkCellText(_ name: String, _ value: Any) -> Problem? {
        let shape = Problem(message: "\(name) 要写成 {\"path\":\"00\",\"index\":0,\"text\":\"…\"}：path 是 0–8 位数字的格子路径，"
                            + "index 是这一格里第几个字块（从 0 开始），text 是新的第一行（最多 120 个字）。",
                            hint: "path 取 collage_get_state 的 cells[].path")
        // text 和 subtitle 同一个上限：只靠 1 MiB 的请求上限的话，一行上兆的字会写进用户的工程、每次重画都排一遍
        guard let obj = value as? [String: Any], Set(obj.keys) == ["path", "index", "text"],
              let path = obj["path"] as? String, path.utf8.count <= 8, path.utf8.allSatisfy({ (48...57).contains($0) }),
              let index = obj["index"].flatMap(integer), index >= 0,
              let text = obj["text"] as? String, text.count <= 120 else { return shape }
        return nil
    }
}
