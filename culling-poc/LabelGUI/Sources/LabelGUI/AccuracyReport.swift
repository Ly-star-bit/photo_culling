import Foundation

// MARK: - 「标注校准」页的人工标注 × app 自己的判决（优化分析 2026-11-10 的 U5、第五节）
//
// 标注页按 b / c / x 标虚焦、闭眼、曝光问题，打 1–5 分，存进这一场的 labels.csv。以前只有不随 app 发的 evaluate.py 读它；
// 这里把它和批量页的自动判决对上：每一类「抓到 / 漏掉 / 误杀」各几张、是哪几张。不用专门攒坏片，标任何一场都行。
//
// 口径（和 evaluate.py 不一样的地方写在这里）：
//   - 拿来比的是 app 的**自动**结论：`BatchItem.rejectReasons`（人工改判盖不掉它 —— 手动救回来的照片理由还在），
//     所以「误杀」不会因为你已经在批量页把它救回来就消失。精选只算自动提名的（人工改成精选的不算 app 的）。
//   - 哪些算「看过」：这一行打过分，或者 b / c / x 任何一项动过。看过而没按的那一项算「没问题」。
//     evaluate.py 是三项都要填 0 / 1 才算（空着跳过）；在 app 里没人会为了说「不虚」把开关拨开再拨回去，那样误杀永远是 0。
//   - 三类各认哪些理由：虚焦 = 「虚焦」；闭眼 = 「闭眼」；曝光 = 「曝光裁切」「欠曝」「过曝」。
//     「人脸质量低」「连拍重复」「VLM建议淘汰」「文件损坏」不归任何一类，只进「打了高分却被判废」那张清单。
//   - 样本少于 `minReviewed` 张、或者某个比例的分母少于 `minDenominator` 张：只报张数，不给百分比。

/// 一张照片 app 这边的结论（从 BatchItem 抄出来的那几样，纯值）。
struct AppJudgement: Equatable, Sendable {
    let id: String
    /// 界面上现在的判决（含人工改判）。
    let verdict: Verdict
    /// 自动理由（BatchItem.rejectReasons）：不是空的 = app 自己会判废。
    let reasons: [String]
    /// 人工改判过（BatchStore.isManual）。
    let manual: Bool

    var autoRejected: Bool { !reasons.isEmpty }
    var autoPicked: Bool { verdict == .pick && !manual }

    @MainActor
    static func all(from store: BatchStore) -> [AppJudgement] {
        store.items.map {
            AppJudgement(id: $0.id, verdict: $0.verdict, reasons: $0.rejectReasons, manual: store.isManual($0.id))
        }
    }
}

struct AccuracyReport: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case blur = "虚焦"
        case eyes = "闭眼"
        case exposure = "曝光"

        /// app 的哪些理由算这一类。
        var appReasons: Set<String> {
            switch self {
            case .blur: return ["虚焦"]
            case .eyes: return ["闭眼"]
            case .exposure: return ["曝光裁切", "欠曝", "过曝"]
            }
        }

        /// --json 里的键。
        var key: String {
            switch self {
            case .blur: return "blur"
            case .eyes: return "closed_eyes"
            case .exposure: return "exposure"
            }
        }

        func humanFlag(_ row: LabelRow) -> Bool? {
            switch self {
            case .blur: return row.blur
            case .eyes: return row.closedEyes
            case .exposure: return row.exposureIssue
            }
        }
    }

    struct Category: Equatable, Sendable {
        let kind: Kind
        /// 你标了有这个问题的张数（= caught + missed）。
        var flagged: Int { caught.count + missed.count }
        /// 你标了、app 也给了这个理由。
        var caught: [String] = []
        /// 你标了、app 没给这个理由。
        var missed: [String] = []
        /// 你看过、没标，app 却给了这个理由。
        var falseKills: [String] = []
        /// app 给了这个理由的张数（只数你看过的）。
        var appFlagged: Int { caught.count + falseKills.count }
    }

    struct ScoreMismatch: Equatable, Sendable {
        let id: String
        let score: Int
        /// 判废的理由（「打了低分却进精选」那张清单是空的）。
        let reasons: [String]
    }

    /// 少于这么多张看过的：整份报告不给百分比。
    static let minReviewed = 20
    /// 一个比例的分母少于这么多张：这一个比例不给百分比。
    static let minDenominator = 5

    /// 看过、app 也有结果的张数 —— 下面所有数字的范围。
    var reviewed = 0
    /// 看过，但 app 没有这张的分析结果（分析失败、照片后来移走了）：不参与比较。
    var unanalyzed = 0
    /// app 这一场一共多少张有结果。
    var analyzed = 0
    var categories: [Category] = Kind.allCases.map { Category(kind: $0) }
    /// 你打 4 分以上，app 自己却判废。
    var lovedButRejected: [ScoreMismatch] = []
    /// 你打 2 分以下，app 却自动提名成精选。
    var dislikedButPicked: [ScoreMismatch] = []

    var tooFew: Bool { reviewed < Self.minReviewed }

    /// 这一行算不算「看过」。
    static func isReviewed(_ row: LabelRow) -> Bool {
        row.humanScore != nil || row.blur != nil || row.closedEyes != nil || row.exposureIssue != nil
    }

    /// 纯函数：标注（labels.csv 的行，按 id）× app 的结论。清单的先后跟着 `judgements`（批量页的顺序）。
    static func make(labels: [String: LabelRow], judgements: [AppJudgement]) -> AccuracyReport {
        var report = AccuracyReport()
        report.analyzed = judgements.count
        var seen = Set<String>()
        for judgement in judgements {
            // 同一个 id 出现两次（不该有）只算第一次，不让一张照片数两遍。
            guard seen.insert(judgement.id).inserted else { continue }
            guard let row = labels[judgement.id], isReviewed(row) else { continue }
            report.reviewed += 1
            let appReasons = Set(judgement.reasons)
            for i in report.categories.indices {
                let kind = report.categories[i].kind
                let human = kind.humanFlag(row) ?? false
                let app = !appReasons.isDisjoint(with: kind.appReasons)
                switch (human, app) {
                case (true, true): report.categories[i].caught.append(judgement.id)
                case (true, false): report.categories[i].missed.append(judgement.id)
                case (false, true): report.categories[i].falseKills.append(judgement.id)
                case (false, false): break
                }
            }
            if let score = row.humanScore {
                if score >= 4, judgement.autoRejected {
                    report.lovedButRejected.append(ScoreMismatch(id: judgement.id, score: score, reasons: judgement.reasons))
                }
                if score <= 2, judgement.autoPicked {
                    report.dislikedButPicked.append(ScoreMismatch(id: judgement.id, score: score, reasons: []))
                }
            }
        }
        report.unanalyzed = labels.filter { isReviewed($0.value) && !seen.contains($0.key) }.count
        return report
    }

    // MARK: - 白话

    /// 「6 张里 4 张（67%）」；样本太少、分母太小时只有张数。分母是 0 = nil（没有可说的）。
    func share(_ part: Int, of whole: Int) -> Int? {
        guard !tooFew, whole >= Self.minDenominator else { return nil }
        return Int((Double(part) / Double(whole) * 100).rounded())
    }

    /// 这份报告的范围，一句话。
    var scopeLine: String {
        var line = "你看过 \(reviewed) 张（这一场 app 分析了 \(analyzed) 张）"
        if unanalyzed > 0 { line += "；另有 \(unanalyzed) 张标了但 app 没有分析结果，不算" }
        return line
    }

    /// 样本太少时的那一句（够了 = nil）。
    var tooFewLine: String? {
        guard tooFew else { return nil }
        if reviewed == 0 { return "还没有标注：打分或按 b / c / x 标几张，这里就会出结果" }
        return "样本太少：才看过 \(reviewed) 张，下面只列张数；看过 \(Self.minReviewed) 张以上才给比例"
    }

    static let reviewedRule = "打过分或按过 b / c / x 的算看过；看过而没按的那一项算「没问题」"

    func countsLine(_ c: Category) -> String {
        "你标了 \(c.flagged) 张 · app 抓到 \(c.caught.count) · 漏掉 \(c.missed.count) · 误杀 \(c.falseKills.count)"
    }

    /// 两个比例的白话（精确率 / 召回率，界面上不出现这两个词）。没有可说的 = nil。
    func ratioLine(_ c: Category) -> String? {
        var parts: [String] = []
        if c.appFlagged > 0 {
            var text = "app 判成\(c.kind.rawValue)的 \(c.appFlagged) 张里，你也这么看的 \(c.caught.count) 张"
            if let pct = share(c.caught.count, of: c.appFlagged) { text += "（\(pct)%）" }
            parts.append(text)
        }
        if c.flagged > 0 {
            var text = "你标的 \(c.flagged) 张里，app 抓到 \(c.caught.count) 张"
            if let pct = share(c.caught.count, of: c.flagged) { text += "（\(pct)%）" }
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    /// `--accuracy` 打印的那一份（界面上是同一份数据、同样的句子）。
    func textLines(title: String) -> [String] {
        var lines = ["和自动判决对比 · \(title)", scopeLine, "（\(Self.reviewedRule)）"]
        if let few = tooFewLine { lines.append(few) }
        guard reviewed > 0 else { return lines }
        for c in categories {
            lines.append("\(c.kind.rawValue)：\(countsLine(c))")
            if let ratio = ratioLine(c) { lines.append("  \(ratio)") }
            if !c.falseKills.isEmpty { lines.append("  误杀（你没标、app 判了）：\(c.falseKills.joined(separator: " "))") }
            if !c.missed.isEmpty { lines.append("  漏掉（你标了、app 没判）：\(c.missed.joined(separator: " "))") }
        }
        lines.append("你打 4 分以上、app 却判废：\(lovedButRejected.count) 张")
        for m in lovedButRejected {
            lines.append("  \(m.id)（\(m.score) 分 · \(m.reasons.map(BatchStore.reasonLabel).joined(separator: "、"))）")
        }
        lines.append("你打 2 分以下、app 却选成精选：\(dislikedButPicked.count) 张")
        for m in dislikedButPicked { lines.append("  \(m.id)（\(m.score) 分）") }
        return lines
    }

    /// `--accuracy --json`。比例是整数百分比，只在够数时给（不够 = null），和白话那份同一条线。
    func json(folder: String) -> [String: Any] {
        func ratio(_ part: Int, _ whole: Int) -> Any {
            guard !tooFew, whole >= Self.minDenominator else { return NSNull() }
            return Int((Double(part) / Double(whole) * 100).rounded())
        }
        var cats: [String: Any] = [:]
        for c in categories {
            cats[c.kind.key] = [
                "labeled": c.flagged,
                "caught": c.caught.count,
                "missed": c.missed.count,
                "false_kills": c.falseKills.count,
                "app_flagged": c.appFlagged,
                "pct_of_app_flags_you_agree": ratio(c.caught.count, c.appFlagged),
                "pct_of_your_flags_caught": ratio(c.caught.count, c.flagged),
                "missed_ids": c.missed,
                "false_kill_ids": c.falseKills,
                "caught_ids": c.caught,
            ] as [String: Any]
        }
        return [
            "folder": folder,
            "reviewed": reviewed,
            "analyzed": analyzed,
            "labeled_without_analysis": unanalyzed,
            "too_few": tooFew,
            "min_reviewed_for_percent": Self.minReviewed,
            "min_denominator_for_percent": Self.minDenominator,
            "categories": cats,
            "scored_4_plus_but_rejected": lovedButRejected.map {
                ["id": $0.id, "score": $0.score, "reasons": $0.reasons] as [String: Any]
            },
            "scored_2_or_less_but_picked": dislikedButPicked.map { ["id": $0.id, "score": $0.score] as [String: Any] },
        ]
    }
}

// MARK: - LabelGUI --accuracy <照片文件夹> [--json]

/// 读这一场的 labels.csv 和分析结果，打印「和自动判决对比」。**只读**：不建数据目录、不写 sessions.json、不碰这一场的任何文件。
///
/// 判决只有 BatchStore 会算（阈值、连拍基线、复审平反都在它里面），而建 BatchStore、切场次会写 sessions.json、建场次目录。
/// 所以这里把这一场目录里的那几个小文件（manifest、layer JSON、阈值、改判；不含 previews/）抄到系统临时目录里一份影子数据目录，
/// BatchStore 开在影子上，算完删掉。真实数据目录从头到尾只被读。main.swift 里它在 ensureAppDataDir() 之前分派。
enum AccuracyCLI {
    static let usage = "用法: LabelGUI --accuracy <照片文件夹> [--json]"

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        guard args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") else {
            print(usage)
            exit(2)
        }
        let folder = URL(fileURLWithPath: args[flagIndex + 1])
        let key = BatchStore.sessionKey(for: folder)
        let realSession = appDataDir.appendingPathComponent("sessions/\(key)")
        let fm = FileManager.default
        guard fm.fileExists(atPath: realSession.appendingPathComponent("manifest.json").path) else {
            print("这个文件夹还没分析过（\(realSession.path) 里没有 manifest.json）：先在 app 里打开它跑一次分析")
            exit(1)
        }
        // 标注：读真实目录里的那一份。
        let labelsPath = realSession.appendingPathComponent("labels.csv")
        var labels: [String: LabelRow] = [:]
        if fm.fileExists(atPath: labelsPath.path) {
            guard let text = try? String(contentsOf: labelsPath, encoding: .utf8) else {
                print("读不了 \(labelsPath.path)")
                exit(1)
            }
            let parsed = LabelStore.parseLabels(text)
            if let problem = parsed.problem {
                print(problem)
                exit(1)
            }
            labels = parsed.rows
        }

        let shadow = fm.temporaryDirectory.appendingPathComponent("labelgui-accuracy-\(UUID().uuidString)")
        let judgements = shadowJudgements(folder: folder, realSession: realSession, key: key, shadow: shadow)
        try? fm.removeItem(at: shadow)

        let report = AccuracyReport.make(labels: labels, judgements: judgements)
        if args.contains("--json") {
            let object = report.json(folder: folder.path)
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            print(report.textLines(title: folder.lastPathComponent).joined(separator: "\n"))
        }
        exit(0)
    }

    /// 影子数据目录里开 BatchStore，拿这一场的判决。
    @MainActor
    private static func shadowJudgements(folder: URL, realSession: URL, key: String, shadow: URL) -> [AppJudgement] {
        let fm = FileManager.default
        let shadowSession = shadow.appendingPathComponent("sessions/\(key)")
        do {
            try fm.createDirectory(at: shadowSession, withIntermediateDirectories: true)
            // 数据目录根上的小文件（settings.json：老场次的阈值回落到它）。sessions.json 不抄：抄了 BatchStore 一建就去开
            // 「最近」的第一场。
            for url in plainFiles(in: appDataDir) where url.lastPathComponent != "sessions.json" {
                try fm.copyItem(at: url, to: shadow.appendingPathComponent(url.lastPathComponent))
            }
            // 这一场目录顶层的文件（不含 previews/ 这些子目录；.bak 不要）。
            for url in plainFiles(in: realSession) where url.pathExtension != "bak" {
                try fm.copyItem(at: url, to: shadowSession.appendingPathComponent(url.lastPathComponent))
            }
        } catch {
            print("建不了临时目录 \(shadow.path)：\(error.localizedDescription)")
            try? fm.removeItem(at: shadow)
            exit(1)
        }
        let store = BatchStore(dataDir: shadow, pythonRoot: shadow)
        // followBookmark: false —— 只按这个路径的 key 找，不解析书签、不认挪走的文件夹（那要读 sessions.json）。
        store.switchSession(to: folder, followBookmark: false)
        return AppJudgement.all(from: store)
    }

    /// 目录顶层的普通文件（不进子目录、不要隐藏文件、不跟符号链接）。
    private static func plainFiles(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: Set(keys)))?.isRegularFile == true }
    }
}

// MARK: - LabelGUI --accuracy-selftest

/// 造几张带标注的假数据，断言各项计数、样本太少时不出百分比、labels.csv 解析。纯函数，不读写任何文件。
enum AccuracySelfTest {
    static func run() -> Never {
        var failed = 0
        var total = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            total += 1
            if ok {
                print("PASS " + name)
            } else {
                failed += 1
                print("FAIL " + name + " " + detail())
            }
        }
        func row(blur: Bool? = nil, eyes: Bool? = nil, exposure: Bool? = nil, score: Int? = nil) -> LabelRow {
            var r = LabelRow()
            r.blur = blur
            r.closedEyes = eyes
            r.exposureIssue = exposure
            r.humanScore = score
            return r
        }
        func app(_ id: String, _ verdict: Verdict, _ reasons: [String] = [], manual: Bool = false) -> AppJudgement {
            AppJudgement(id: id, verdict: verdict, reasons: reasons, manual: manual)
        }

        // 八张：每一格（抓到 / 漏掉 / 误杀 / 都没事）至少一张，再加人工改判、没看过、没分析的。
        let labels: [String: LabelRow] = [
            "a": row(blur: true, score: 1),                 // 虚焦：你标了，app 也判了 → 抓到
            "b": row(blur: true, score: 2),                 // 虚焦：你标了，app 没判 → 漏掉；2 分却进了自动精选
            "c": row(score: 5),                             // 没标，app 判虚焦 + 欠曝 → 两类误杀；5 分却被判废
            "d": row(eyes: true, score: 2),                 // 闭眼抓到；2 分、精选是人工改的 → 不算 app 的
            "e": row(blur: false, eyes: false, exposure: true, score: 3),  // 曝光：你标了，app 给的是「过曝」→ 抓到
            "f": row(exposure: true),                       // 只按了 x 没打分也算看过；app 没判 → 漏掉
            "g": row(score: 4),                             // 4 分，app 只给了「人脸质量低」→ 不归三类，进「高分被判废」
            "h": LabelRow(),                                // 只填过组号之类 = 没看过，不算
            "z": row(blur: true, score: 1),                 // 标了，但 app 没有这张
        ]
        let judgements = [
            app("a", .reject, ["虚焦"]),
            app("b", .pick),
            app("c", .usable, ["虚焦", "欠曝"], manual: true),   // 手动救回来了：理由还在，照样算误杀
            app("d", .pick, ["闭眼"], manual: true),
            app("e", .reject, ["过曝"]),
            app("f", .usable),
            app("g", .reject, ["人脸质量低"]),
            app("h", .reject, ["虚焦"]),
            app("u", .usable),                              // 没标注的照片
        ]
        let r = AccuracyReport.make(labels: labels, judgements: judgements)
        let blur = r.categories[0], eyes = r.categories[1], exposure = r.categories[2]
        check(r.reviewed == 7 && r.analyzed == 9 && r.unanalyzed == 1, "范围：看过 7、分析过 9、标了没分析 1",
              "\(r.reviewed) \(r.analyzed) \(r.unanalyzed)")
        check(blur.kind == .blur && blur.flagged == 2 && blur.caught == ["a"] && blur.missed == ["b"] && blur.falseKills == ["c"],
              "虚焦：标了 2、抓到 a、漏掉 b、误杀 c（手动救回来的照样算，没看过的 h 不算）", "\(blur)")
        check(eyes.flagged == 1 && eyes.caught == ["d"] && eyes.missed.isEmpty && eyes.falseKills.isEmpty,
              "闭眼：标了 1、抓到 d", "\(eyes)")
        check(exposure.flagged == 2 && exposure.caught == ["e"] && exposure.missed == ["f"] && exposure.falseKills == ["c"],
              "曝光：「过曝」「欠曝」「曝光裁切」都算；抓到 e、漏掉 f、误杀 c", "\(exposure)")
        check(r.lovedButRejected.map(\.id) == ["c", "g"] && r.lovedButRejected[1].reasons == ["人脸质量低"],
              "打 4 分以上却被判废：c、g（带理由）", "\(r.lovedButRejected)")
        check(r.dislikedButPicked.map(\.id) == ["b"], "打 2 分以下却进了精选：只有 b（d 的精选是人工改的）",
              "\(r.dislikedButPicked)")

        // 样本太少：照实说，全文没有百分号。
        let text = r.textLines(title: "假数据").joined(separator: "\n")
        check(r.tooFew && text.contains("样本太少") && !text.contains("%"), "看过 7 张：说「样本太少」、不给百分比", text)
        check(!text.lowercased().contains("precision") && !text.lowercased().contains("recall")
              && !text.contains("精确率") && !text.contains("召回"), "白话：没有 precision / recall 这类词")
        let json = r.json(folder: "/x")
        let jsonBlur = (json["categories"] as? [String: Any])?["blur"] as? [String: Any]
        check(json["too_few"] as? Bool == true && jsonBlur?["pct_of_your_flags_caught"] is NSNull
              && jsonBlur?["false_kills"] as? Int == 1 && (jsonBlur?["missed_ids"] as? [String]) == ["b"],
              "--json：样本太少时比例是 null，计数和清单照给")
        check(JSONSerialization.isValidJSONObject(json), "--json：编得出来")

        // 够数了：30 张，虚焦标了 10 张（抓到 8、漏 2），另有 2 张误杀 → 10 张里 8 张（80%）、app 判的 10 张里 8 张（80%）。
        var many: [String: LabelRow] = [:]
        var manyApp: [AppJudgement] = []
        for i in 0..<30 {
            let id = String(format: "p%02d", i)
            many[id] = row(blur: i < 10 ? true : nil, score: 3)
            let flagged = i < 8 || i == 20 || i == 21
            manyApp.append(app(id, flagged ? .reject : .usable, flagged ? ["虚焦"] : []))
        }
        let big = AccuracyReport.make(labels: many, judgements: manyApp)
        let bigBlur = big.categories[0]
        let ratio = big.ratioLine(bigBlur) ?? ""
        check(!big.tooFew && bigBlur.caught.count == 8 && bigBlur.missed == ["p08", "p09"] && bigBlur.falseKills == ["p20", "p21"]
              && ratio == "app 判成虚焦的 10 张里，你也这么看的 8 张（80%）；你标的 10 张里，app 抓到 8 张（80%）",
              "30 张：给比例（10 张里 8 张 80%）", ratio)
        // 分母太小的那一个比例不给：闭眼一张都没标、app 判了 0 张 → 没有比例那一行。
        check(big.ratioLine(big.categories[1]) == nil, "闭眼没人标、app 也没判：没有比例可说")
        var few = many
        few["p00"]?.closedEyes = true
        let small = AccuracyReport.make(labels: few, judgements: manyApp)
        check(small.ratioLine(small.categories[1]) == "你标的 1 张里，app 抓到 0 张", "分母只有 1 张：只报张数、不给百分比",
              small.ratioLine(small.categories[1]) ?? "nil")

        // 没有标注、没有判决。
        let empty = AccuracyReport.make(labels: [:], judgements: manyApp)
        check(empty.reviewed == 0 && (empty.tooFewLine ?? "").contains("还没有标注")
              && empty.textLines(title: "x").count == 4, "一张都没标：只说「还没有标注」")
        check(AccuracyReport.make(labels: many, judgements: []).unanalyzed == 30, "app 没有结果：全算「标了没分析」")

        // labels.csv：和标注页写出来的一样（空 = 没标，0 = 标了没问题）；缺 id 列报出来；带逗号的自由文本。
        let csv = "id,blur,closed_eyes,group_id,composition_issue,exposure_issue,human_score\n"
            + "a,1,,3,,,1\nb,0,0,,\"歪了, 切头\",1,\nc,,,,,,\n"
        let parsed = LabelStore.parseLabels(csv)
        check(parsed.problem == nil && parsed.rows.count == 3 && parsed.rows["a"]?.blur == true
              && parsed.rows["a"]?.closedEyes == nil && parsed.rows["a"]?.humanScore == 1 && parsed.rows["a"]?.groupId == "3"
              && parsed.rows["b"]?.blur == false && parsed.rows["b"]?.exposureIssue == true
              && parsed.rows["b"]?.compositionIssue == "歪了, 切头" && parsed.rows["b"]?.humanScore == nil,
              "labels.csv 解析：三态、分数、带逗号的文字")
        check(parsed.rows["c"].map(AccuracyReport.isReviewed) == false && parsed.rows["b"].map(AccuracyReport.isReviewed) == true,
              "全空的一行不算看过；填了 0 的算")
        check(LabelStore.parseLabels("name,blur\nx,1\n").problem != nil, "缺 id 列：报出来，不当成没有标注")
        check(LabelStore.parseLabels("").problem == nil && LabelStore.parseLabels("").rows.isEmpty, "空文件：没有标注，不算错")

        print(failed == 0 ? "标注对比自检通过：\(total) 条" : "标注对比自检 \(failed)/\(total) 条没过")
        exit(failed == 0 ? 0 : 1)
    }
}
