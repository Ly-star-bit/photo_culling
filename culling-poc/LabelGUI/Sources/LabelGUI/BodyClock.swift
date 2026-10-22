import Foundation

/// 双机位：认机身（型号 + 序列号）。「场」、近似重复、按机身对时都按这个 key 分开。
enum CameraBody {
    /// 每张照片的机身 key（和传进来的顺序一一对应）。同一个型号在这一批里出现了两个以上
    /// **不同的**序列号，才把序列号拼进去（「X-T50 #5B008966」）；否则就是型号本身 ——
    /// 单机身、不同型号的双机位和以前一字不差；某几张读不到序列号（老场次文件不在了、
    /// 被别的软件抹掉）也不会凭空多出一台机身。同型号两台、又有几张没序列号的，那几张单独算一台。
    static func keys(models: [String?], serials: [String?]) -> [String] {
        var serialsByModel: [String: Set<String>] = [:]
        for (model, serial) in zip(models, serials) {
            if let serial, !serial.isEmpty { serialsByModel[model ?? "", default: []].insert(serial) }
        }
        return zip(models, serials).map { model, serial in
            let m = model ?? ""
            guard let serial, !serial.isEmpty, (serialsByModel[m]?.count ?? 0) >= 2 else { return m }
            return "\(m) #\(serial)"
        }
    }

    /// 界面上的名字：型号；同型号有几台时后面带序列号末 4 位（「X-T50 · 8966」），末 4 位撞了就带全号。
    /// `bodies` 是这一场的每台机身（key 是 `keys` 给的，序列号没有 = ""），返回 key → 名字。
    static func displayNames(_ bodies: [(key: String, model: String, serial: String)]) -> [String: String] {
        let byModel = Dictionary(grouping: bodies, by: \.model)
        var names: [String: String] = [:]
        for (model, same) in byModel {
            let base = model.isEmpty ? "未知机身" : model
            let tails = same.map { String($0.serial.suffix(4)) }
            let tailsUnique = Set(tails).count == tails.count
            for body in same {
                if same.count < 2 {
                    names[body.key] = base
                } else if body.serial.isEmpty {
                    names[body.key] = base + " · 无序列号"
                } else {
                    names[body.key] = base + " · " + (tailsUnique ? String(body.serial.suffix(4)) : body.serial)
                }
            }
        }
        return names
    }
}

/// 按机身对时的偏移：输入框和命令行都认「+180」「-3:00」「1:02:03」（± 秒，或 分:秒 / 时:分:秒）。
enum BodyClock {
    /// 最多拨 ±48 小时：时区没改、日期差一天都够。输入框、命令行、「对成同一时刻」、
    /// body_offsets.json 读进来的都按它卡（不卡的话一长串 9 换算时溢出，整个程序崩掉）。
    static let maxOffset = 48 * 3600

    /// 看不懂、超过 ±48 小时 = nil。正号可以不写；全角的 ＋ － ： 也认。分:秒、时:分:秒 后面几段要小于 60。
    static func parseOffset(_ text: String) -> Int? {
        parseOffset(text, limit: maxOffset)
    }

    /// 输入框旁边的红字、命令行的提示（nil = 没问题）。
    static func offsetProblem(_ text: String) -> String? {
        guard parseOffset(text) == nil else { return nil }
        // 每段最多 6 位数，999999:59:59 换成秒也远小于 Int.max。
        return parseOffset(text, limit: .max) == nil ? "写成 +180 或 -3:00" : "最多 ±\(maxOffset / 3600) 小时"
    }

    private static func parseOffset(_ text: String, limit: Int) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "＋", with: "+")
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "−", with: "-")
        if t.hasSuffix("秒") { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
        var sign = 1
        if t.hasPrefix("-") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy(isShortNumber) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let seconds = values.reduce(0) { $0 * 60 + $1 }
        return seconds <= limit ? sign * seconds : nil
    }

    /// 1–6 位 ASCII 数字（不带正负号）：三段乘起来也溢出不了。
    private static func isShortNumber(_ part: Substring) -> Bool {
        (1...6).contains(part.utf8.count) && part.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// 秒 → 「+3:00」「-0:45」「+1:02:05」；0 = 「0」。
    static func formatOffset(_ seconds: Int) -> String {
        guard seconds != 0 else { return "0" }
        let a = abs(seconds)
        let sign = seconds > 0 ? "+" : "-"
        let (h, m, s) = (a / 3600, a % 3600 / 60, a % 60)
        return h > 0 ? String(format: "%@%d:%02d:%02d", sign, h, m, s) : String(format: "%@%d:%02d", sign, m, s)
    }

    /// 命令行逐张打印用（--verdicts --per-photo、--body-offset）。
    static let timeFormatter = posixFormatter("yyyy-MM-dd HH:mm:ss")
    private static let clockFormatter = posixFormatter("HH:mm:ss")
    private static let dayClockFormatter = posixFormatter("MM-dd HH:mm")

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// 「16:24:02–16:28:39」（对时之后的第一张到最后一张）；跨天的带日期。
    static func range(_ body: BatchStore.BodyInfo) -> String {
        guard let first = body.first, let last = body.last else { return "没有拍摄时间" }
        if first == last { return clockFormatter.string(from: first) }
        let sameDay = Calendar.current.isDate(first, inSameDayAs: last)
        let f = sameDay ? clockFormatter : dayClockFormatter
        return f.string(from: first) + "–" + f.string(from: last)
    }
}

// MARK: - 无头入口

/// LABELGUI_DATA_DIR=<临时> LabelGUI --body-offset <photo_dir> [--body '<key>' --seconds N | --align id,id] [--undo]
/// 打印每台机身（key、名字、张数、对时后的时间范围、偏移）；给了 --body/--seconds 或 --align 就改一次再打印，
/// --undo 紧接着撤销一次，最后重开这一场再打印一遍（偏移要从 body_offsets.json 读回来）。
enum BodyClockCLI {
    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        guard !(ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? "").isEmpty else {
            print("--body-offset 会改这一场的 body_offsets.json：先设 LABELGUI_DATA_DIR=<临时目录>")
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[flagIndex + 1])
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        printBodies(store, title: "现在")
        if let key = option("--body") {
            let text = option("--seconds") ?? ""
            guard let seconds = BodyClock.parseOffset(text) else {
                print("--seconds " + (BodyClock.offsetProblem(text) ?? ""))
                exit(1)
            }
            guard store.bodies.contains(where: { $0.key == key }) else {
                print("没有这台机身: \(key)")
                exit(1)
            }
            store.setBodyOffsets([key: seconds])
            printBodies(store, title: "设 \(key) \(BodyClock.formatOffset(seconds)) 后")
        } else if let pair = option("--align") {
            let ids = pair.split(separator: ",").map(String.init)
            guard ids.count == 2, let a = store.alignment(ids[0], ids[1]) else {
                print("--align 要两台不同机身、都有拍摄时间的两张，对齐后偏移不超过 ±\(BodyClock.maxOffset / 3600) 小时")
                exit(1)
            }
            print("对成同一时刻: 以 \(a.reference.name) 为准，\(a.moved.name) → \(BodyClock.formatOffset(a.offset))")
            store.setBodyOffsets([a.moved.key: a.offset])
            printBodies(store, title: "对齐后")
        }
        if args.contains("--undo") {
            store.undoLastOverride()
            printBodies(store, title: "撤销一次后")
        }
        let reopened = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        reopened.switchSession(to: dir)
        printBodies(reopened, title: "重开后")
        exit(0)
    }

    @MainActor
    static func printBodies(_ store: BatchStore, title: String) {
        print("\(title): \(store.bodies.count) 台机身")
        for b in store.bodies {
            let offset = BodyClock.formatOffset(b.offset)
            print("  \(b.key) 「\(b.name)」 \(b.count) 张 · \(BodyClock.range(b)) · 偏移 \(offset)")
        }
    }

    /// --verdicts --per-photo 在两台以上机身时每行后面多打的：机身、对时后的拍摄时间、章节。
    @MainActor
    static func perPhotoSuffix(_ item: BatchItem, store: BatchStore) -> String {
        let name = store.bodies.first { $0.key == item.body }?.name ?? "未知机身"
        let time = item.captureTime.map(BodyClock.timeFormatter.string(from:)) ?? "无时间"
        return " · \(name) · \(time) · 章节\(item.chapter + 1)"
    }

    /// 同上，逐张之后再打：每台机身一行，章节数，按拍摄时间（对时后）排的顺序。
    @MainActor
    static func printTimeline(_ store: BatchStore) {
        printBodies(store, title: "机身")
        let dated = store.items.filter { $0.captureTime != nil }
        print("章节 \(Set(dated.map(\.chapter)).count) 个")
        var order = store.items
        BatchStore.sort(&order, by: .captureTime)
        print("按拍摄时间: " + order.map(\.id).joined(separator: " "))
    }
}
