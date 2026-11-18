import Foundation

/// 交付出口的小规则，跑在 --delivery-selftest 里（CI 的「自检」步骤；端到端在 Scripts/delivery_regression.py）：
/// - 失败名单（FailureNames，优化分析 EC-08）：不超过 3 个全列；多了列前 3 个、写「等 M 张」，单位跟着那一句。
/// - 交付对照里的失败全名单（DeliveryRecord.failed）：没有失败不写这个键，老记录（没有这个键）照样读得进来。
@MainActor
enum DeliveryScopeSelfTest {
    typealias Check = (Bool, String, String) -> Void

    static func run(check: Check) {
        failureNames(check: check)
        recordFailures(check: check)
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
