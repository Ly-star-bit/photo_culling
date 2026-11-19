import Foundation

/// 解 manifest 里的拍摄时间（分析引擎写的 `yyyy-MM-dd'T'HH:mm:ss`，本地时区，不带时区后缀）。打开场次时每张照片解一次，
/// 在主线程上：以前逐张 DateFormatter.date(from:)，7980 张一次打开 280 ms 主线程里占 123 ms（优化分析 2026-11-18 PP-05）。
///
/// 怎么保证和 DateFormatter 一模一样（复核员提醒：夏令时切换那一小时有不存在的时刻、重复的时刻，ICU 怎么取不好照抄）：
/// 不自己算时区。按字节拆出六段数字，同一个「年月日时」只请 DateFormatter 解两次 —— 这一小时的 :00:00 和 :59:59；
/// 两个差正好 3599 秒（这一小时里没有时区跳变，DateFormatter 在这一小时里是线性的）就记下 :00:00 那个，这一小时里的
/// 每一张 = 它 + 分 × 60 + 秒。差得不是 3599（切换就在这一小时里：澳洲豪勋爵岛半小时的切换、1883 年以前的地方时……）、
/// 或者解不出来的，这一小时里的每一张照旧整串交给 DateFormatter。格式不对（长度、分隔符、不是数字、月日时分秒超出范围）
/// 的也整串交给它 —— 结果和以前逐张 DateFormatter 的一样，只是一场几千张只真解几十次。
/// --session-input-selftest 在十几个时区（含南半球、半小时 / 45 分钟时差、跳过一整天的萨摩亚、零点切换的圣保罗）
/// 逐小时、切换日逐分钟和 DateFormatter 对过。
///
/// 不是线程安全的（带缓存）：一次 loadResults 建一个，用完就扔。
struct CaptureTimeParser {
    let formatter: DateFormatter
    /// 「年月日时」→ 这一小时 :00:00 的时刻；存 nil = 这一小时不线性（或解不出来），逐张交给 formatter。
    private var hours: [Int: Date?] = [:]

    /// 和 BatchStore.loadResults 以前那个一样：en_US_POSIX、`yyyy-MM-dd'T'HH:mm:ss`、时区默认当前。
    init(timeZone: TimeZone = .current) {
        formatter = Self.makeFormatter(timeZone: timeZone)
    }

    static func makeFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f
    }

    /// 解过的小时里有几个不线性、逐张交给 formatter 的（自检核对退路真的走到了）。
    var irregularHours: Int { hours.values.filter { $0 == nil }.count }

    mutating func date(from text: String) -> Date? {
        guard let parts = Self.fields(text) else { return formatter.date(from: text) }
        let key = ((parts.year * 100 + parts.month) * 100 + parts.day) * 100 + parts.hour
        let base: Date?
        if let cached = hours[key] {
            base = cached
        } else {
            let head = String(text.prefix(13))   // yyyy-MM-ddTHH，前面已经核过是 ASCII
            let start = formatter.date(from: head + ":00:00")
            let end = formatter.date(from: head + ":59:59")
            let linear = start != nil && end != nil && end!.timeIntervalSince(start!) == 3599
            base = linear ? start : nil
            hours[key] = .some(base)
        }
        guard let base else { return formatter.date(from: text) }
        return base.addingTimeInterval(TimeInterval(parts.minute * 60 + parts.second))
    }

    /// 正好 19 个字节、`dddd-dd-ddTdd:dd:dd`，月 1–12、日 1–31、时 0–23、分秒 0–59：拆出六段；别的一律 nil（整串交给 formatter）。
    /// 日子在这个月里存不存在（2 月 30 日）不在这里管：同一个「年月日时」的 :00:00 也解不出来，这一小时整个走 formatter。
    static func fields(_ text: String) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)? {
        var text = text
        return text.withUTF8 { buf -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)? in
            guard buf.count == 19, buf[4] == 0x2D, buf[7] == 0x2D, buf[10] == 0x54, buf[13] == 0x3A, buf[16] == 0x3A else {
                return nil
            }
            func number(_ from: Int, _ count: Int) -> Int? {
                var v = 0
                for i in from..<(from + count) {
                    let d = Int(buf[i]) - 48
                    guard d >= 0, d <= 9 else { return nil }
                    v = v * 10 + d
                }
                return v
            }
            guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return nil }
            guard (1...12).contains(month), (1...31).contains(day), hour <= 23, minute <= 59, second <= 59 else { return nil }
            return (year, month, day, hour, minute, second)
        }
    }
}
