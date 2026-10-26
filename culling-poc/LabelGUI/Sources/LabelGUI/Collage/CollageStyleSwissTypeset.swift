import Foundation
import CoreGraphics

/// 瑞士网格带进来的三样通用排字功能（都是默认关的：旧模板、旧工程一步都不多走，逐像素不变）。放在这里而不是
/// CollageTypeset / CollageRender 里，那两个文件只留一行钩子（fill、prepared、画文字格），合并时好对：
///
/// - [[…]] 可省的一段（fill → fillOptional）：没有 EXIF、没有拍摄时间的照片不留「f/ · s · iso」这种残渣；
/// - 一行放不下宽度时折行 / 只缩这一行（prepared → overflowed；CollageTextLine.overflow、glyphScale）；
/// - 文字格的字色跟着页面底色翻深浅（画文字格 → paperToned；CollageText.paperTone）。
extension CollageTypeset {

    // MARK: - [[…]] 可省的一段

    /// [[…]] = 可省的一段：里面有一个占位符是空的（没有默认），整段连同字面的字一起不印 —— 没有 EXIF 的照片
    /// （截图、微信转过的图）上 "f/{fnumber}"、"{shutter} s"、"iso {iso}" 不留 "f/  s  iso" 这种残渣；
    /// [[甲||乙]] = 甲那段不全就印乙（巨型日期没有拍摄时间时换成期号）。开头悬空的分隔符（前面那段没了留下的
    /// " · "、", "）去掉。只有带 [[ 的字串走这里（fill 分派）。
    static func fillOptional(_ template: String, vars: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            out += rest[..<open.lowerBound]
            let inner = String(rest[open.upperBound..<close.lowerBound])
            let (main, alternative) = splitAlternative(inner)
            if hasEmptyPlaceholder(main, vars: vars) {
                if let alternative, !hasEmptyPlaceholder(alternative, vars: vars) { out += alternative }
            } else {
                out += main
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        let filled = substitute(out, vars: vars)
        let dangling = CharacterSet(charactersIn: "·,;/|").union(.whitespaces)
        return String(filled.unicodeScalars.drop { dangling.contains($0) })
    }

    /// [[甲||乙]] 拆成甲、乙（占位符的 {key|默认} 里的 | 不算：只认花括号外面的「||」）。
    private static func splitAlternative(_ inner: String) -> (String, String?) {
        var depth = 0
        var previous: Character?
        for i in inner.indices {
            let ch = inner[i]
            if ch == "{" { depth += 1 } else if ch == "}" { depth = max(0, depth - 1) }
            if ch == "|", previous == "|", depth == 0 {
                let cut = inner.index(before: i)
                return (String(inner[..<cut]), String(inner[inner.index(after: i)...]))
            }
            previous = ch
        }
        return (inner, nil)
    }

    /// 这一段里有没有展开是空的占位符（{key|默认} 有默认的不算空）。
    private static func hasEmptyPlaceholder(_ segment: String, vars: [String: String]) -> Bool {
        let ns = segment as NSString
        return placeholderRegex.matches(in: segment, range: NSRange(location: 0, length: ns.length)).contains { match in
            let value = vars[ns.substring(with: match.range(at: 1))] ?? ""
            return value.isEmpty && match.range(at: 2).location == NSNotFound
        }
    }

    // MARK: - 一行放不下宽度

    /// 放不下宽度的行按它的 overflow 处理（CollageTextLine.overflow，文字格、文字图层走 prepared 的都管）：
    /// wrap 在词缝折行（没有空格的中文按字折），折出来的每一段是一行字面的字（已经展开、改过大小写）、字号不变 ——
    /// 瑞士风「只有一种字号」的长标题换行，不是整块缩小；一个词就比框宽（拼音连写的长标题）的那一段只缩它自己。
    /// 折完整块高过了框：那一行改成只缩它自己。shrink 只把这一行的字形缩到正好放下（glyphScale：行框、基线、
    /// 细线还按原字号排，别的行字号、基线都不动；字还是原来那句模板，照常展开）。折出来的字面会再展开一次占位符，
    /// 展开之后带 { 或 [[ 的（用户标题里自己打的）不折、只缩，免得被当成占位符吃掉。
    /// 只管横排、没铺满宽度的行；一行都没有设的字块原样返回（旧版式逐像素不变）。剩下还放不下的交给 drawShort 整体缩。
    static func overflowed(_ text: CollageText, in box: CGSize, short: Double, vars: [String: String]) -> CollageText {
        guard !text.vertical, text.lines.contains(where: { $0.overflow != .block && !$0.fitWidth }) else { return text }
        let frame = text.isRotated ? CGSize(width: box.height, height: box.width) : box
        let room = Double(frame.width) * 0.998
        guard room > 1, short > 0 else { return text }
        func extent(_ s: String, _ spec: CollageTextLine) -> Double {
            lineExtent(s, spec, size: spec.size * short, vertical: false)
        }
        // 只缩这一行的字形：按比例缩一次、再量一次修掉字形取整的误差。
        func shrunk(_ spec: CollageTextLine, _ s: String) -> CollageTextLine {
            var l = spec
            for _ in 0..<2 {
                let e = extent(s, l)
                guard e > room else { break }
                l.glyphScale = max(0.1, l.glyphScale * room / e)
            }
            return l
        }
        // 折出来的一段：字面的字（已经展开、改过大小写），再放不下（一个长词）只缩它自己。
        func literal(_ spec: CollageTextLine, _ piece: String) -> CollageTextLine {
            var l = spec
            l.text = piece
            l.textCase = .none
            l.overflow = .block
            return shrunk(l, piece)
        }
        var wrapped = text
        var single = text
        var anyWrap = false
        wrapped.lines = []
        single.lines = []
        for spec in text.lines {
            let s = lineString(spec, vars: vars)
            guard spec.overflow != .block, !spec.fitWidth, !s.isEmpty, extent(s, spec) > room else {
                wrapped.lines.append(spec)
                single.lines.append(spec)
                continue
            }
            single.lines.append(shrunk(spec, s))
            guard spec.overflow == .wrap, !s.contains("{"), !s.contains("[[") else {
                wrapped.lines.append(shrunk(spec, s))
                continue
            }
            anyWrap = true
            // 有空格按词折；整行没有空格、带汉字的按字折；一个长词（拼音连写）折不开，只缩它自己。
            let words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let cjk = words.count == 1 && s.unicodeScalars.contains { $0.properties.isIdeographic }
            let tokens = cjk ? s.map(String.init) : words
            let gap = cjk ? "" : " "
            var current = ""
            for token in tokens {
                let candidate = current.isEmpty ? token : current + gap + token
                if current.isEmpty || extent(candidate, spec) <= room {
                    current = candidate
                } else {
                    wrapped.lines.append(literal(spec, current))
                    current = token
                }
            }
            if !current.isEmpty { wrapped.lines.append(literal(spec, current)) }
        }
        guard anyWrap else { return single }
        // 摆正之后的高（转了 ±90° 的 measure 宽高互换，换回来）。
        let measured = measure(wrapped, short: short, vars: vars)
        let height = Double(wrapped.isRotated ? measured.width : measured.height)
        return height <= Double(frame.height) ? wrapped : single
    }
}

extension CollageRender {

    /// 文字格的字和页面底色对比不到 3:1 的那几行按底色翻深浅（CollageText.paperTone）：墨黑纸上的白字落到浅纸上
    /// 翻成近黑、浅纸上的黑字落到深色纸上翻成近白（细线跟着第一行）。强调色（有颜色的字）不翻成黑白：够 4:1 的
    /// 不动（印刷红在浅纸上 4.4:1），不够的（黑纸上用的橙红落到浅纸上只有 3.2:1）色相、饱和度不变，只调深浅到 4.5:1。
    static func paperToned(_ text: CollageText, background: CollageColor) -> CollageText {
        let light = background.luminance < 0.5
        func accent(_ color: CollageColor) -> CollageColor {
            let hsl = color.hsl
            // 深纸上往亮里调、浅纸上往暗里调：二分找离原色最近、刚够 4.5:1 的那个亮度。
            var near: Double = hsl.l
            var far: Double = light ? 1 : 0
            for _ in 0..<16 {
                let mid: Double = (near + far) / 2
                let trial = CollageColor(hsl: CollageColor.HSL(h: hsl.h, s: hsl.s, l: mid))
                if CollageContact.contrast(trial, background) >= 4.5 { far = mid } else { near = mid }
            }
            return CollageColor(hsl: CollageColor.HSL(h: hsl.h, s: hsl.s, l: far))
        }
        func fixed(_ color: CollageColor) -> CollageColor {
            let before = CollageContact.contrast(color, background)
            if color.hsl.s > 0.3 { return before < 4 ? accent(color) : color }
            guard before < 3 else { return color }
            let after = CollageOverlays.toned(color, light: light)
            return CollageContact.contrast(after, background) > before ? after : color
        }
        var out = text
        out.lines = text.lines.map { line in
            var l = line
            l.color = fixed(line.color)
            return l
        }
        if var body = out.body {
            body.color = fixed(body.color)
            out.body = body
        }
        return out
    }
}
