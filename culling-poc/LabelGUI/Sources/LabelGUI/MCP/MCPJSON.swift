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

    /// 非有限数 → null，可选值的 nil → null，字典和数组逐层处理；其余原样（不合法的留给 isValidJSONObject 拦）。
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            // Bool 也是 NSNumber（CFBoolean），原样；只有浮点数要查是不是有限。
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n }
            if CFNumberIsFloatType(n as CFNumber) && !n.doubleValue.isFinite { return NSNull() }
            return n
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

    /// text 超过上限时从 `key` 那个列表的尾部截掉（§3.0）：二分找最多能留几条。
    /// `mark` 给截过的对象补 truncated / next_cursor 之类（参数是留下的条数），它补的字段也算进长度。
    static func fitting(_ object: Object, list key: String, limit: Int = textMax,
                        mark: (inout Object, Int) -> Void = { object, _ in object["truncated"] = true }) -> String {
        let whole = string(object)
        guard whole.count > limit, let list = object[key] as? [Any], !list.isEmpty else { return whole }
        func render(_ kept: Int) -> String {
            var cut = object
            cut[key] = Array(list.prefix(kept))
            mark(&cut, kept)
            return string(cut)
        }
        // lo 条一定放得下（0 条放不下也只能给 0 条），hi 条放不下。
        var lo = 0
        var hi = list.count
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if render(mid).count <= limit { lo = mid } else { hi = mid }
        }
        return render(lo)
    }
}
