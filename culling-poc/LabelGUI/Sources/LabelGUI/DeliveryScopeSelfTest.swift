import Foundation

/// 交付出口的小规则，跑在 --delivery-selftest 里（CI 的「自检」步骤；端到端在 Scripts/delivery_regression.py）：
/// - 失败名单（FailureNames，优化分析 EC-08）：不超过 3 个全列；多了列前 3 个、写「等 M 张」，单位跟着那一句；
///   压不到体积上限那句（DeliveryEncoder.overLimitNote）同一个写法。水印批量的失败名单在 delivery_regression.py 6b 段。
/// - 交付对照里的失败全名单（DeliveryRecord.failed）：没有失败不写这个键，老记录（没有这个键）照样读得进来。
/// - 导出 JPG 的范围（JPEGScopeChoice，优化分析 UX-03）：列哪几档、默认哪档、选中的被清掉了退回哪档。
///   按 id 真导出（--ids、--scope client）在 delivery_regression.py 第 7 段。
@MainActor
enum DeliveryScopeSelfTest {
    typealias Check = (Bool, String, String) -> Void

    static func run(check: Check) {
        failureNames(check: check)
        recordFailures(check: check)
        jpegScopes(check: check)
    }

    // MARK: - 导出 JPG 的范围

    private static func jpegScopes(check: Check) {
        func list(_ c: [JPEGScopeChoice]) -> String { c.map(\.title).joined(separator: " | ") }
        let plain = JPEGScopeChoice.choices(picks: 5, usable: 7, selected: 0, client: 0, filter: nil)
        check(plain.map(\.scope) == [.picks, .picksUsable] && plain.map(\.count) == [5, 12],
              "范围：没选中、没客户选中、没开筛选 → 只有精选 / 精选 + 可用（和以前那个开关一样）", list(plain))
        let chapter = JPEGScopeChoice.Filter(label: "本章·精选 4 张", count: 4, onlyClient: false)
        let full = JPEGScopeChoice.choices(picks: 5, usable: 7, selected: 3, client: 30, filter: chapter)
        check(full.map(\.scope) == [.picks, .picksUsable, .selected, .client, .filtered]
              && full.map(\.count) == [5, 12, 3, 30, 4]
              && list(full) == "精选 (5 张) | 精选 + 可用 (12 张) | 选中的 3 张 | 客户选中 30 张 | 当前筛选：本章·精选 4 张",
              "范围：选了 3 张、客户选了 30 张、开着只看这一章 → 五档都列、张数对", list(full))
        let onlyClient = JPEGScopeChoice.choices(picks: 5, usable: 7, selected: 0, client: 30,
                                                 filter: JPEGScopeChoice.Filter(label: "客户选中 30 张", count: 30, onlyClient: true))
        check(onlyClient.map(\.scope) == [.picks, .picksUsable, .client],
              "范围：只开了「只看客户选中」→ 当前筛选和客户选中那档一样，不重复列", list(onlyClient))

        check(JPEGScopeChoice.defaultScope(selected: 3, includeUsable: false) == .selected,
              "范围：选了照片再打开面板，默认「选中的」", "")
        check(JPEGScopeChoice.defaultScope(selected: 0, includeUsable: true) == .picksUsable
              && JPEGScopeChoice.defaultScope(selected: 0, includeUsable: false) == .picks,
              "范围：没选照片 → 上次的精选 / 精选 + 可用（不默认当前筛选：开着废片筛选时会悄悄导出废片）", "")
        check(JPEGScopeChoice.resolve(.selected, in: plain, includeUsable: false) == .picks
              && JPEGScopeChoice.resolve(.client, in: full, includeUsable: true) == .client,
              "范围：选的那档没了（选中被清掉）退回精选 / 精选 + 可用；还在就照用", "")
    }

    // MARK: - 失败名单的写法

    private static func failureNames(check: Check) {
        let four = ["M_0000", "M_0002", "M_0003", "M_0004"]
        let cases: [(String, String, String)] = [
            (FailureNames.list([], unit: "张"), "", "空的：什么都不写"),
            (FailureNames.list(["a"], unit: "张"), "a", "一个：只写它"),
            (FailureNames.list(["a", "b", "c"], unit: "张"), "a, b, c", "正好 3 个：全列、不写「等」"),
            (FailureNames.list(four, unit: "张"), "M_0000, M_0002, M_0003 等 4 张",
             "4 个：列前 3 个、写「等 4 张」（以前只列 3 个、读起来像只失败 3 张）"),
            (FailureNames.list(four, unit: "个"), "M_0000, M_0002, M_0003 等 4 个", "XMP / 高 ISO 按「个」数"),
            (FailureNames.list(["a + b", "c + d", "e + f", "g + h"], unit: "组", separator: "、"), "a + b、c + d、e + f 等 4 组",
             "同名冲突那句：一组一组、顿号分开"),
            (DeliveryEncoder.overLimitNote(four, maxMB: 5), "4 张压到最低质量 40 还是超过 5 MB（已按最低质量写出）：M_0000, M_0002, M_0003 等 4 张",
             "压不到体积上限那句（导出 JPG / 水印共用）：同一个写法（以前写「…」）"),
        ]
        for (got, want, name) in cases {
            check(got == want, "失败名单：" + name, "「\(got)」，要「\(want)」")
        }
    }

    // MARK: - 交付对照里的失败全名单

    private static func recordFailures(check: Check) {
        let folder = URL(fileURLWithPath: "/tmp/labelgui-selftest-交付")
        let file = DeliveryRecord.File(file: "a.jpg", id: "a", original: "/tmp/a.JPG")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let clean = DeliveryRecord(kind: .jpeg, folder: folder, files: [file])
        let cleanJSON = (try? encoder.encode(clean)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(clean.failed == nil && !cleanJSON.contains("\"failed\""), "没有失败：不写 failed 这个键（和老版本写的一样）", cleanJSON)

        let failures = [DeliveryRecord.Failure(id: "b", reason: "没有权限"), DeliveryRecord.Failure(id: "c", reason: "")]
        let partial = DeliveryRecord(kind: .highlights, folder: folder, files: [file], failed: failures)
        let back = (try? encoder.encode(partial)).flatMap { try? decoder.decode(DeliveryRecord.self, from: $0) }
        // 时间按 ISO 8601 存到秒，整条比会差那点小数：比 id、文件和失败名单。
        check(back?.id == partial.id && back?.files == partial.files && back?.failed == failures,
              "有失败：全名单按顺序存进去、原样读回来",
              "\(back?.failed?.map(\.id) ?? [])")

        // 这一版以前写的（没有 failed 键）照样读得进来。
        let old = #"{"at":"2026-11-01T08:00:00Z","files":[{"file":"a.jpg","id":"a","original":"/tmp/a.JPG"}],"folder":"/tmp/x","id":"x","kind":"jpeg"}"#
        let decoded = try? decoder.decode(DeliveryRecord.self, from: Data(old.utf8))
        check(decoded?.files.count == 1 && decoded?.failed == nil, "老记录（没有 failed）照样读进来", "\(String(describing: decoded))")
    }
}
