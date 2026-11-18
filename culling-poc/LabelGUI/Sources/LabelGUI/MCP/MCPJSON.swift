import Foundation

/// MCP 这一侧所有 JSON 的唯一出口（DESIGN §1.2、§4.5）：外层的 JSON-RPC 帧、text 块里的结果 JSON 都经这里编码。
/// - 先 sanitize：NaN / ±inf 换成 null。JSONSerialization 碰到非有限数会抛 ObjC 异常，整个进程直接退出（R4 §3.8）；
///   之后 app 端的桥回复也用这同一个函数（§10.4），在 app 里那就是用户的 app 闪退。
/// - `.withoutEscapingSlashes`：默认会把 /Users/x/a.jpg 写成 \/Users\/x\/a.jpg，模型照抄路径去读会失败。
/// - `.sortedKeys`：同一个对象每次编出来逐字节相同。
enum MCPJSON {
    typealias Object = [String: Any]

    /// text 块的长度上限（字符），LABELGUI_MCP_TEXT_MAX 可调（§3.0）。
    static let textMax: Int = {
        let raw = ProcessInfo.processInfo.environment["LABELGUI_MCP_TEXT_MAX"].flatMap { Int($0) }
        guard let raw, raw >= 1_000 else { return 20_000 }
        return min(raw, 1_000_000)
    }()

    /// 非有限数 → null，可选值的 nil → null，有限的小数换成最短写法（shortest），字典和数组逐层处理；其余原样
    /// （不合法的留给 isValidJSONObject 拦）。
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            // Bool 也是 NSNumber（CFBoolean），原样；只有浮点数要查是不是有限。
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n }
            // 已经是十进制数（JSON 解析出来的长数、shortest 换过的）：原样写；NaN 照样换 null（不然 JSONSerialization 抛异常）
            if let d = n as? NSDecimalNumber { return d.decimalValue.isNaN ? NSNull() : d }
            guard CFNumberIsFloatType(n as CFNumber) else { return n }
            let x = n.doubleValue
            guard x.isFinite else { return NSNull() }
            return shortest(x) ?? n
        case let d as [String: Any]:
            return d.mapValues { sanitize($0) }
        case let a as [Any]:
            return a.map { sanitize($0) }
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let wrapped = mirror.children.first?.value else { return NSNull() }
                return sanitize(wrapped)
            }
            return value
        }
    }

    /// 小数的最短写法（优化分析 MC-04）：JSONSerialization 把 Double 按 17 位有效数字写（r3 过的 0.637 写成
    /// 0.63700000000000001），列表、版式类的结果白多一到两成 token；NSDecimalNumber 它按十进制原样写。Swift 的 "\(x)" 就是
    /// 能读回同一个 Double 的最短写法，按它的数字建 NSDecimalNumber（尾数 + 小数位数）：写出去的就是这串字，读回来是同一个 Double。
    /// - 只换「-123.456」这种不到 16 个字的：r3 过的值都是；本来就 15–17 位有效数字的换了也省不了几个字，原样走（还省时间：
    ///   换一个数多花约 0.7 µs，长的不换几乎不多花）。带指数的（"1e-05"）也不换。
    /// - 不用 NSDecimalNumber(string:)：Decimal 的指数只到 ±127，"3.14e+300" 建出来是 NaN，JSONSerialization 碰到 NaN 抛
    ///   ObjC 异常、进程直接退（文件头那条，app 端就是闪退）。这里尾数不到 10^15、小数位数不到 15，建不出 NaN。
    /// - 也不拿 Decimal 的 doubleValue 回头去比：它自己会差一个 ulp（1.993 就比不上），写出去的字是对的。
    /// 这个函数也管 CollageStore.editDigest、CollageLayoutSpec 的几处比较：同一个 Double 永远写成同一串字，比较结果不变；
    /// 指纹的值和以前不同（只在同一个进程里比，不存盘）。
    static func shortest(_ x: Double) -> NSNumber? {
        // 整数值（0、1、70.0）JSONSerialization 本来就写成 "70"，不用换
        if x.rounded(.towardZero) == x && abs(x) < 1e15 { return nil }
        let text = "\(x)"
        guard text.utf8.count < 16 else { return nil }
        var mantissa: UInt64 = 0
        var places: Int16 = 0
        var dot = false
        var negative = false
        for c in text.utf8 {
            switch c {
            case UInt8(ascii: "-"): negative = true
            case UInt8(ascii: "."): dot = true
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                mantissa = mantissa * 10 + UInt64(c - UInt8(ascii: "0"))
                if dot { places += 1 }
            default: return nil  // 指数（e）之类
            }
        }
        return NSDecimalNumber(mantissa: mantissa, exponent: -places, isNegative: negative)
    }

    /// 编成一行（不带换行）。编不了（不是对象 / 数组、里面有不认识的类型）回 nil，不抛异常。
    static func data(_ object: Any) -> Data? {
        let clean = sanitize(object)
        guard JSONSerialization.isValidJSONObject(clean) else { return nil }
        return try? JSONSerialization.data(withJSONObject: clean, options: [.withoutEscapingSlashes, .sortedKeys])
    }

    /// 同上，给 text 块用；编不了时退回一个说明错误的对象（总归是合法 JSON）。
    static func string(_ object: Any) -> String {
        if let data = data(object), let s = String(data: data, encoding: .utf8) { return s }
        return #"{"error":{"code":"internal","message":"结果里有编不成 JSON 的值","hint":"换个参数再调；还不行就是服务器的 bug"}}"#
    }

    /// text 超过上限时从 `key` 那个列表的尾部截掉（§3.0）：二分找最多能留几条（至少留 1 条）。
    /// `mark` 给截过的对象补 truncated / next_cursor 之类（参数是留下的条数），它补的字段也算进长度。
    static func fitting(_ object: Object, list key: String, limit: Int = textMax,
                        mark: (inout Object, Int) -> Void = { object, _ in object["truncated"] = true }) -> String {
        let whole = string(object)
        guard whole.count > limit else { return whole }
        return string(fittingObject(object, list: key, limit: limit, mark: mark))
    }

    /// 同上，交回截好的对象（app 端的桥回复要的是对象，编码在连接队列上做）。放得下就原样交回。
    static func fittingObject(_ object: Object, list key: String, limit: Int,
                              mark: (inout Object, Int) -> Void) -> Object {
        guard string(object).count > limit, let list = object[key] as? [Any], list.count > 1 else { return object }
        func cut(_ kept: Int) -> Object {
            var o = object
            o[key] = Array(list.prefix(kept))
            mark(&o, kept)
            return o
        }
        // 至少给 1 条（这一条自己就超了也给）：给 0 条的话 next_cursor 原地不动，模型照着翻永远翻不完。
        // lo 条放得下（或者 lo 是 1），hi 条放不下。
        var lo = 1
        var hi = list.count
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if string(cut(mid)).count <= limit { lo = mid } else { hi = mid }
        }
        return cut(lo)
    }
}
