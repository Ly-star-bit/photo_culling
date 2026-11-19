import Foundation

/// `--threshold-selftest [--seed N]`：拖阈值滑杆的快路径（BatchStore.applyThresholdChange，优化分析 2026-11-18 PI-04）和整场
/// 重算逐字段相同。
///
/// 造一场 480 张的假拍摄（照片本身按 seed 随机：对焦、曝光裁切、人脸质量、EAR 都撒在三条线附近；有老结果只有锐度的、近似重复组
/// 一张到四张、复审平反、本地模型建议淘汰、欠曝 / 过曝、坏文件、两台机身、四章），随机拖 200 下三根滑杆 —— 大多是一格一格地拖
/// （对焦一格 5，和滑杆的 step 一样），夹着预设、人脸质量拨到「关闭」再拨开、整根拖到别处；中间隔一阵改几张判决（改判那条局部
/// 重算），第 101 下打开 / 关上去重（整场重算）。每 10 下把这时的 items / derived 和整场重算（applyThresholds）逐字段比一次
/// （BatchStore.fastPathDiff：items 整张比，derived 每一样都比），全等才过。
///
/// 拖的时候关掉局部重算的自动对账（BatchStore.verifyOverrideFastPath）：开着的话每一下快路径的结果都马上被整场重算盖掉，
/// 一下接一下的快路径攒下来的差就测不到了。另外核对快路径真的走到了（不是一路退回整场重算）、真的翻过照片、人脸质量从「关闭」
/// 拨开 / 拨回「关闭」也走过快路径。
@MainActor
enum ThresholdFastPathSelfTest {
    static let flag = "--threshold-selftest"
    private static var failures = 0
    private static var total = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok {
            print("PASS " + what)
        } else {
            failures += 1
            let extra = detail()
            print("FAIL " + what + (extra.isEmpty ? "" : "（" + extra + "）"))
        }
    }

    static func runFromCommandLine(_ args: [String] = CommandLine.arguments) -> Never {
        var seed: UInt64 = 1
        if let i = args.firstIndex(of: "--seed") {
            let raw = args.count > i + 1 ? args[i + 1] : ""
            // 写错了直接退出：悄悄退回默认 seed，以为在复现的其实是另一组。
            guard let value = UInt64(raw) else {
                print("\(flag)：--seed 要一个非负整数，拿到的是「\(raw)」")
                exit(2)
            }
            seed = value
        }
        run(seed: seed)
    }

    static func run(seed: UInt64) -> Never {
        CollageCLI.requireIsolatedDataDir(flag, "会在数据目录里造假的拍摄、写场次文件")
        let root = appDataDir.appendingPathComponent("threshold-selftest-" + String(UUID().uuidString.prefix(8)))
        var rng = SeededRandom(seed: seed)
        let store = makeShoot(root.appendingPathComponent("shoot"), rng: &rng)
        let verifyBefore = BatchStore.verifyOverrideFastPath
        BatchStore.verifyOverrideFastPath = false
        drag(store, rng: &rng, seed: seed)
        BatchStore.verifyOverrideFastPath = verifyBefore
        try? FileManager.default.removeItem(at: root)
        let tail = failures == 0 ? "全部通过（\(total) 条）" : "\(failures) / \(total) 条失败"
        print("阈值滑杆快路径自检（seed=\(seed)）：" + tail)
        if failures > 0 { print("复现：LabelGUI \(flag) --seed \(seed)") }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 拖

    private static func drag(_ store: BatchStore, rng: inout SeededRandom, seed: UInt64) {
        // 从「标准」开始（人脸质量线开着），去重先关着。
        store.rejectBurstDuplicates = false
        store.applyPreset(.standard)
        sanity(store)

        let ids = store.items.map(\.id)
        let shareBefore = BatchStore.thresholdFastPathMaxShare
        var fastRuns = 0, fallbacks = 0, rejudged = 0, idle = 0, zeroCrossFast = 0, overrideRuns = 0, dedupeSeen = 0
        for step in 1...200 {
            // 每 50 下换一种：照常（翻得多就退回整场重算）/ 不许退（大跳、人脸质量过零也走快路径）；前 100 下去重关，后 100 下开。
            BatchStore.thresholdFastPathMaxShare = (step - 1) / 50 % 2 == 1 ? 1 : shareBefore
            if step == 101 { store.rejectBurstDuplicates = true }  // 整场重算；之后的快路径要连着去重一起对
            if step % 23 == 0, !ids.isEmpty {
                // 改几张判决（含恢复自动）：改判那条局部重算接着阈值快路径的结果往下算。
                let n = Int.random(in: 1...3, using: &rng)
                let picked = (0..<n).map { _ in ids[Int.random(in: 0..<ids.count, using: &rng)] }
                let verdicts: [Verdict?] = [.pick, .usable, .reject, nil]
                let before = store.overrideFastPathRuns
                store.setOverrideBatch(picked, verdicts[Int.random(in: 0..<verdicts.count, using: &rng)])
                overrideRuns += store.overrideFastPathRuns - before
            }
            let qualityWasOn = store.faceQualityThreshold > 0
            let before = store.thresholdFastPathRuns
            move(store, rng: &rng)
            if store.thresholdFastPathRuns > before {
                fastRuns += 1
                rejudged += store.thresholdFastPathRejudged
                if store.thresholdFastPathRejudged == 0 { idle += 1 }
                if qualityWasOn != (store.faceQualityThreshold > 0) { zeroCrossFast += 1 }
            } else {
                fallbacks += 1
            }
            if step % 10 == 0 {
                if store.items.contains(where: { $0.rejectReasons.contains("连拍重复") }) { dedupeSeen += 1 }
                compare(store, "第 \(step) 下")
            }
        }
        BatchStore.thresholdFastPathMaxShare = shareBefore
        print("拖了 200 下：快路径 \(fastRuns) 下（共重判 \(rejudged) 张，\(idle) 下一张没翻）、退回整场重算 \(fallbacks) 下；"
              + "人脸质量过零走快路径 \(zeroCrossFast) 下；中间改判走局部重算 \(overrideRuns) 次；比的时候有「连拍重复」的 \(dedupeSeen) 次")
        check(dedupeSeen >= 3, "开着去重比的那几次里有照片判成「连拍重复」（去重这条路测得到）", "\(dedupeSeen)")
        // 不是一路退回整场重算、不是一张都没翻：上面 20 次「相同」才算数。
        check(fastRuns >= 120, "200 下里快路径至少走了 120 下", "\(fastRuns)")
        check(rejudged >= 200, "快路径累计重判了至少 200 张（真的有照片翻过线）", "\(rejudged)")
        check(idle >= 1, "有一张都没翻的一下（items 不动、只换看线的派生量）也比过", "\(idle)")
        check(zeroCrossFast >= 1, "人脸质量从「关闭」拨开 / 拨回「关闭」有走快路径的", "\(zeroCrossFast)")
        check(fallbacks >= 1, "翻得太多退回整场重算的也有（预设、整根拖走）", "\(fallbacks)")
        check(overrideRuns >= 1, "中间的改判走了改判的局部重算", "\(overrideRuns)")
    }

    /// 拖一下：大多一格一格地拖，偶尔预设、人脸质量过零、整根拖到别处。
    private static func move(_ store: BatchStore, rng: inout SeededRandom) {
        let roll = Int.random(in: 0..<100, using: &rng)
        let sign: Double = Bool.random(using: &rng) ? 1 : -1
        switch roll {
        case 0..<40:
            let next = store.focusThreshold + 5 * sign
            store.focusThreshold = BatchStore.clampFocus(next)
        case 40..<65:
            let next = store.exposureThreshold + sign * Double.random(in: 0.002...0.03, using: &rng)
            store.exposureThreshold = min(BatchStore.exposureRange.upperBound, max(BatchStore.exposureRange.lowerBound, next))
        case 65..<82:
            let next = store.faceQualityThreshold + sign * Double.random(in: 0.01...0.08, using: &rng)
            store.faceQualityThreshold = min(1, max(0, next))
        case 82..<88:
            // 拨到「关闭」/ 从「关闭」拨开：组内相对的那一半人脸质量判断整个跟着开关
            store.faceQualityThreshold = store.faceQualityThreshold > 0 ? 0 : Double.random(in: 0.02...0.4, using: &rng)
        case 88..<94:
            let presets = BatchStore.CullPreset.allCases
            store.applyPreset(presets[Int.random(in: 0..<presets.count, using: &rng)])
        default:
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: store.focusThreshold = Double(Int.random(in: 0...30, using: &rng) * 5)
            case 1: store.exposureThreshold = Double.random(in: BatchStore.exposureRange, using: &rng)
            default: store.faceQualityThreshold = Double.random(in: 0...1, using: &rng)
            }
        }
    }

    /// 这时的 items / derived 和整场重算逐字段比。
    private static func compare(_ store: BatchStore, _ label: String) {
        let fastItems = store.items, fastDerived = store.derived
        let lines = String(format: "对焦 %.0f · 曝光 %.3f · 人脸质量 %.3f", store.focusThreshold, store.exposureThreshold,
                           store.faceQualityThreshold)
        store.applyThresholds()
        let diff = BatchStore.fastPathDiff(fastItems, fastDerived, store.items, store.derived)
        check(diff == nil, label + "（" + lines + (store.rejectBurstDuplicates ? " · 去重开" : " · 去重关")
              + "）：快路径和整场重算的 items / derived 逐字段相同", diff ?? "")
    }

    /// 这一场造得够不够格：几条路都测得到（不然「全等」可能只是没东西可比）。
    private static func sanity(_ store: BatchStore) {
        let items = store.items
        check(items.count == shootSize, "\(shootSize) 张都进了网格", "\(items.count)")
        check(store.chapterSegments.count >= 4, "至少四章（章节条按章局部重算测得到）", "\(store.chapterSegments.count)")
        let reasons = Set(items.flatMap(\.rejectReasons))
        for reason in ["虚焦", "曝光裁切", "人脸质量低", "闭眼", "欠曝", "VLM建议淘汰", "文件损坏"] {
            check(reasons.contains(reason), "起手就有照片带「\(reason)」")
        }
        check(items.contains { !$0.vlmRescued.isEmpty }, "起手就有复审平反的（平反跟着线变）")
        check(items.contains { $0.focus == nil }, "有老结果（没有对焦、按锐度折算）")
        check(items.contains { $0.verdict == .pick }, "起手就有提名的精选")
        let groups = Dictionary(grouping: items.filter { $0.faceQuality != nil }, by: \.burstGroup)
        check(groups.values.contains { $0.count >= 2 }, "有两张以上带人脸质量的近似重复组（组内相对那一半测得到）")
        check(groups.values.contains { $0.count == 1 }, "有落单带人脸质量的（按景别补偿的绝对线测得到）")
    }

    // MARK: - 造一场

    private static let shootSize = 480

    /// 照 FollowupSelfTest.makeDupShoot 手写 manifest / layer1 / layer2 / 复审结果，打开这一场。
    private static func makeShoot(_ dir: URL, rng: inout SeededRandom) -> BatchStore {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let start = parser.date(from: "2026-03-21T09:00:00") ?? Date(timeIntervalSince1970: 0)

        var manifest: [[String: Any]] = []
        var layer1: [[String: Any]] = []
        var layer2: [[String: Any]] = []
        var appeals: [[String: Any]] = []
        var group = 0
        var n = 0
        // 四章（隔一小时），每章一串场（隔 20–40 秒），每场 1–8 张（隔 0.5–2 秒），场里连着的 1–4 张一个近似重复组。
        for chapter in 0..<4 {
            var t = start.addingTimeInterval(Double(chapter) * 3600)
            while n < shootSize * (chapter + 1) / 4 {
                let camera = Bool.random(using: &rng) ? "X-T50" : "X-H2"
                var left = min(Int.random(in: 1...8, using: &rng), shootSize * (chapter + 1) / 4 - n)
                while left > 0 {
                    group += 1
                    let size = min(left, Int.random(in: 1...4, using: &rng))
                    let scope: String? = Bool.random(using: &rng) ? "eyes" : nil
                    for _ in 0..<size {
                        let id = String(format: "P%04d", n)
                        let url = dir.appendingPathComponent(id + ".JPG")
                        try? Data(("PHOTO " + id).utf8).write(to: url)
                        var photo: [String: Any] = ["id": id, "raw_path": url.path, "decode_path": url.path]
                        photo["preview_path"] = "previews/\(id).jpg"
                        photo["capture_time"] = parser.string(from: t)
                        photo["camera"] = camera
                        photo["body_serial"] = ""
                        photo["exif"] = ["iso": 400]
                        manifest.append(photo)
                        layer1.append(layer1Row(id, group: group, scope: scope, rng: &rng))
                        if Int.random(in: 0..<100, using: &rng) < 50 { layer2.append(layer2Row(id, rng: &rng)) }
                        if Int.random(in: 0..<100, using: &rng) < 20 { appeals.append(appealRow(id, rng: &rng)) }
                        n += 1
                        t = t.addingTimeInterval(Double.random(in: 0.5...2, using: &rng))
                    }
                    left -= size
                }
                t = t.addingTimeInterval(Double.random(in: 20...40, using: &rng))
            }
        }

        let session = appDataDir.appendingPathComponent("sessions/" + BatchStore.sessionKey(for: dir))
        try? fm.createDirectory(at: session, withIntermediateDirectories: true)
        let files: [(String, [String: Any])] = [
            ("manifest.json", ["photo_dir": dir.path, "photos": manifest]),
            ("layer1_results.json", ["analysis_version": 4, "engine": "native", "results": layer1]),
            ("layer2_results.json", ["results": layer2]),
            ("appeal_results.json", ["results": appeals]),
        ]
        for (name, json) in files {
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: session.appendingPathComponent(name))
            }
        }
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        return store
    }

    /// 一张的 layer1：数撒在三条线附近（对焦 30–130、曝光裁切多半在 0–0.35、人脸质量 0.05–0.95），四分之一是只有锐度的老结果。
    private static func layer1Row(_ id: String, group: Int, scope: String?, rng: inout SeededRandom) -> [String: Any] {
        var row: [String: Any] = ["id": id, "burst_group": group]
        row["sharpness"] = Double.random(in: 20...200, using: &rng)
        if Int.random(in: 0..<100, using: &rng) < 75 { row["focus_ratio"] = Double.random(in: 0.03...0.13, using: &rng) }
        let clipRoll = Int.random(in: 0..<100, using: &rng)
        let clip = clipRoll < 60 ? Double.random(in: 0...0.1, using: &rng)
            : clipRoll < 90 ? Double.random(in: 0.1...0.35, using: &rng) : Double.random(in: 0.35...0.6, using: &rng)
        if Bool.random(using: &rng) {
            row["subject_highlight_clip_pct"] = clip
            row["subject_shadow_clip_pct"] = Double.random(in: 0...0.05, using: &rng)
        } else {
            row["highlight_clip_pct"] = clip
            row["shadow_clip_pct"] = Double.random(in: 0...0.05, using: &rng)
        }
        row["frame_luma"] = 128.0
        row["frame_luma_p99"] = 220.0
        if let scope { row["sharpness_scope"] = scope }
        row["capture_subsec"] = Double(Int.random(in: 0..<100, using: &rng)) / 100
        if Int.random(in: 0..<100, using: &rng) < 2 { row["file_corrupt"] = true }
        guard Int.random(in: 0..<100, using: &rng) < 80 else {
            row["face_found"] = false
            row["face_count"] = 0
            if Int.random(in: 0..<100, using: &rng) < 6 {  // 整张黑、没有一处亮：欠曝
                row["frame_luma"] = 30.0
                row["frame_luma_p99"] = 90.0
            }
            return row
        }
        let area = Double.random(in: 0.002...0.2, using: &rng)
        var faces: [[String: Any]] = []
        for k in 0..<Int.random(in: 1...2, using: &rng) {
            var face: [String: Any] = ["bbox": [0.4, 0.3, 0.6, 0.5], "eye_closed": false]
            face["ear"] = Double.random(in: 0.05...0.40, using: &rng)
            // 第二张脸有时很小（EAR 免检，或者只在原图上判得了）
            face["area_pct"] = k == 0 ? area : Double.random(in: 0.0003...0.02, using: &rng)
            face["ear_full_res"] = Int.random(in: 0..<100, using: &rng) < 15
            faces.append(face)
        }
        row["face_found"] = true
        row["face_count"] = faces.count
        row["faces"] = faces
        row["face_bbox"] = [0.4, 0.3, 0.6, 0.5]
        row["face_area_pct"] = area
        row["face_quality"] = Double.random(in: 0.05...0.95, using: &rng)
        let lumaRoll = Int.random(in: 0..<100, using: &rng)
        row["face_luma"] = lumaRoll < 5 ? 245.0 : lumaRoll < 10 ? 50.0 : 150.0
        if lumaRoll >= 5 && lumaRoll < 10 { row["frame_luma_p99"] = 90.0 }
        return row
    }

    private static func layer2Row(_ id: String, rng: inout SeededRandom) -> [String: Any] {
        var row: [String: Any] = ["id": id, "composition_issues": [String](), "reason": "自检"]
        row["expression_score"] = Int.random(in: 1...5, using: &rng)
        row["reject_recommended"] = Int.random(in: 0..<100, using: &rng) < 8
        return row
    }

    /// 复审：三样罪名各自随机 true / false / 没问（没问的不写）。
    private static func appealRow(_ id: String, rng: inout SeededRandom) -> [String: Any] {
        var row: [String: Any] = ["id": id, "reason": "自检"]
        for key in ["subject_sharp", "intentional_exposure", "closed_eyes"] {
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: row[key] = true
            case 1: row[key] = false
            default: break
            }
        }
        return row
    }
}
