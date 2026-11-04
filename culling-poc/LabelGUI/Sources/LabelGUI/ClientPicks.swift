import Foundation
import AppKit
import Darwin
import CryptoKit

// MARK: - 客户选片闭环：导入客户选择 → 客户选中 → 复制文件名清单 / 复制原片到精修文件夹
//
// 客户的回复五花八门：确认表「复制我的选择」的整段（带表号）、微信里打的「12、35、78」「7221 7230」、
// Pixieset 之类导出的 CSV / Lightroom 清单。这里尽量都认，认不出的原样列出来给你看，不猜。
// 认的顺序：完整文件名（扩展名不论、不分大小写）→ 文件名去掉扩展名 / 照片 id → 文件号（≥3 位数字，
// 全场只有一张是这个号才算，比如 7221 → DSCF7221）→ 编号（确认表上的 #n：带表号就按那张表，
// 没带就按最近导出的那张，预览里说是哪张）。12-15 这种范围只当编号认。

enum ClientReply {
    struct Resolution {
        /// 认出的照片 id（按出现顺序，去重）。
        var ids: [String] = []
        /// 没认出的原文（去重，按出现顺序；重名 / 编号和文件号对不上的带说明）。
        var unknown: [String] = []
        /// 文字里带的表号（「选片工具确认表 <表号>」那一行）。
        var header: String?
        /// 编号按这张表认（带表号 = 那张；没带 = 最近导出的那张；这一场没有 = nil）。
        var sheet: ProofSheet?
        /// 真的有编号是按表认出来的。
        var usedSheet = false
        /// 有编号，可是没有表可对（这一场没导出过确认表，或者表号不是这一场的）。
        var numbersWithoutSheet = false
        /// 当成表格（CSV）认的时候用了哪几列（表头上的名字）；不是表格 = nil。
        var tableColumns: [String]?
        /// 表格里别的列带数字、又认不出的格子有几个（都列在没认出里）。
        var tableDropped = 0
        /// 客户给照片写的备注（修图要求）：照片 id → 原话。确认表复制出来的「DSCF7207 备注：去路人」、微信里回的
        /// 「7207 去路人」「DSCF7207：瘦脸」都算（一行开头那张照片带上后面的话，见 noteSplit）；同一张写了几次取最后一次。
        var notes: [String: String] = [:]
    }

    /// 分隔符：换行、空格（含全角空格）、Tab、中英文逗号 / 顿号 / 分号 / 冒号 / 句号 / 问号 / 叹号 / 括号。
    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",，、;；:：。!！?？()（）【】[]《》<>|"))
    /// 两头去掉的：# 号、各种引号、项目符号、句末的英文句点和省略号（「DSCF7207.」）。
    private static let trimmed = CharacterSet(charactersIn: "#＃\"'“”‘’「」『』*·•.…")

    /// 查表：小写的完整文件名 → id；小写的照片 id / 文件名去扩展名 → id；文件号（末尾那串数字去掉前导 0）→ id。
    private struct Lookup {
        var byFile: [String: Set<String>] = [:]
        var byName: [String: Set<String>] = [:]
        var byNumber: [String: Set<String>] = [:]
        /// 导出过的交付文件名（exports.json，见 DeliveryLedger.swift）：小写的完整文件名 / 去掉 .jpg 的名字 → id。
        /// 只收还在这一场的照片。好几次导出同一个名字指向不同的照片（{序号:3} 导了两回）= 重名，不替你挑。
        var deliveredFile: [String: Set<String>] = [:]
        var deliveredName: [String: Set<String>] = [:]
        var live: Set<String> = []

        init(_ items: [BatchItem], deliveries: [DeliveryRecord] = []) {
            for item in items {
                live.insert(item.id)
                byName[item.id.lowercased(), default: []].insert(item.id)
                for path in Set([item.rawPath, item.decodePath]) {
                    let url = URL(fileURLWithPath: path)
                    byFile[url.lastPathComponent.lowercased(), default: []].insert(item.id)
                    byName[url.deletingPathExtension().lastPathComponent.lowercased(), default: []].insert(item.id)
                    if let n = ClientReply.fileNumber(url.deletingPathExtension().lastPathComponent) {
                        byNumber[n, default: []].insert(item.id)
                    }
                }
                if let n = ClientReply.fileNumber(item.id) { byNumber[n, default: []].insert(item.id) }
            }
            for entry in deliveries.flatMap(\.files) where live.contains(entry.id) {
                let url = URL(fileURLWithPath: entry.file.lowercased())
                deliveredFile[url.lastPathComponent, default: []].insert(entry.id)
                deliveredName[url.deletingPathExtension().lastPathComponent, default: []].insert(entry.id)
            }
        }

        /// 按文件名认：原片的文件名，加上导出过的交付文件名。两边都对上、又不是同一张 = 重名（返回两张），不替你挑；
        /// 默认的导出 JPG 交付名就是原名，两边是同一张。
        func byFilename(_ token: String) -> Set<String>? {
            let original = originalFilename(token)
            guard let delivered = deliveredFilename(token) else { return original }
            return original.map { $0.union(delivered) } ?? delivered
        }

        /// 交付文件名：完整文件名 → 名字 → 去掉扩展名再按名字（扩展名的规矩和原片一样）。纯数字的名字（{序号:3}
        /// 导出的 001）不带扩展名时不在这里认，走文件号 / 编号那条（resolve 里当第三种认法一起比）。
        func deliveredFilename(_ token: String) -> Set<String>? {
            let lower = token.lowercased()
            if let hit = deliveredFile[lower] { return hit }
            if !ClientReply.isDigits(Substring(lower)), let hit = deliveredName[lower] { return hit }
            let url = URL(fileURLWithPath: lower)
            let ext = url.pathExtension
            guard !ext.isEmpty, ext.count <= 4, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  ext.contains(where: \.isLetter) else { return nil }
            return deliveredName[url.deletingPathExtension().lastPathComponent]
        }

        /// 按原片文件名认：完整文件名 → 名字 → 去掉扩展名再按名字。nil = 不是这一场的文件名；
        /// 返回不止一张 = 重名（不同子文件夹里同名的照片），不替你挑。
        /// 扩展名不论：这一场只有 JPG，客户回 DSCF7207.CR3 / .CR2 / .3FR 也按名字认（不超过 4 个字母或数字，
        /// 至少带一个字母 —— 「DSCF7207.1」这种不算扩展名）。
        func originalFilename(_ token: String) -> Set<String>? {
            let lower = token.lowercased()
            if let hit = byFile[lower] { return hit }
            if let hit = byName[lower] { return hit }
            let url = URL(fileURLWithPath: lower)
            let ext = url.pathExtension
            if !ext.isEmpty, ext.count <= 4, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
               ext.contains(where: \.isLetter) {
                return byName[url.deletingPathExtension().lastPathComponent]
            }
            return nil
        }

        /// 像这一场的照片：文件名（重名也算），或者全场只有一张是这个号的 ≥3 位文件号。表格认列用。
        func nameLike(_ token: String) -> Bool {
            if byFilename(token) != nil { return true }
            guard token.count >= 3, ClientReply.isDigits(Substring(token)) else { return false }
            return byNumber[ClientReply.fileNumber(token) ?? ""]?.count == 1
        }
    }

    /// 文件号：名字末尾那串数字去掉前导 0（DSCF0723 → 723，IMG_1 → 1）。没有就 nil。
    static func fileNumber(_ name: String) -> String? {
        let digits = String(name.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        guard !digits.isEmpty else { return nil }
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
    }

    private static func isDigits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }

    /// 「12-15」这种两头都是数字的范围。
    private static func isRange(_ s: Substring) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && isDigits(parts[0]) && isDigits(parts[1])
    }

    private static func hasDigit(_ s: String) -> Bool { s.contains { $0.isASCII && $0.isNumber } }

    /// 全角的数字、字母、标点（１２，ＤＳＣＦ：）转半角。不用系统的 fullwidthToHalfwidth：它会把顿号、
    /// 句号变成半角片假名标点（､ ｡），分隔符就认不出来了。
    static func halfwidth(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if (0xFF01...0xFF5E).contains(s.value), let ascii = Unicode.Scalar(s.value - 0xFEE0) {
                scalars.append(ascii)
            } else {
                scalars.append(s)
            }
        }
        return String(scalars)
    }

    /// 一个词清理成能查的样子：去 # 和引号，路径只留文件名，「第12张」「12号」「第2至4张」只留数字。
    static func clean(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: trimmed.union(.whitespaces))
        if let slash = t.lastIndex(of: "/") { t = String(t[t.index(after: slash)...]) }
        var core = Substring(t)
        if core.hasPrefix("第") { core = core.dropFirst() }
        if let last = core.last, "号號张張".contains(last) { core = core.dropLast() }
        if isDigits(core) || isRange(core) { t = String(core) }
        return t.isEmpty ? nil : t
    }

    /// 普通文字（微信回复、LR 清单）切成词。「12 - 15」「12～15」「12至15」先并成「12-15」，别被空格切散；
    /// 「7207和7208」「DSCF7207跟DSCF7208」「。还有7214」：后面跟着字母数字、前面是字母数字或分隔符时，
    /// 「和 / 跟 / 与 / 及 / 还有 / 以及」当分隔（「平和001.JPG」这种文件名里的字不动）。
    static func tokens(_ text: String) -> [String] {
        let ranged = text.replacingOccurrences(of: #"(\d+)\s*[-~～–—至到]\s*(\d+)"#, with: "$1-$2",
                                               options: .regularExpression)
        let joined = ranged.replacingOccurrences(of: #"(?:^|(?<=[0-9A-Za-z\s,、;。:!?]))(?:还有|以及|和|跟|与|及)(?=\s*[0-9A-Za-z])"#,
                                                 with: " ", options: .regularExpression)
        return joined.components(separatedBy: separators).compactMap(clean)
    }

    /// 要认的一个词，和跟着它的备注（只有一行开头那张照片会带）。
    private struct Word {
        var token: String
        var note: String?
    }

    /// 普通文字按行切：整行就是这一场的一个文件名（带空格的文件名「IMG 0001.JPG」，确认表复制出来的
    /// 就是一行一个）就整行当一个词；开头是一张照片、后面是备注的（noteSplit）开头那张带上备注；否则这一行再按分隔符切。
    /// `original` = 没转半角的同一段字（halfwidth 一个字符换一个字符，行和位置都对得上）：备注取它，
    /// 客户打的全角逗号、括号原样留着。`isHead` = 这个词认得出唯一一张照片（文件名、全场唯一的文件号）。
    private static func lineTokens(_ text: String, original: String, lookup: Lookup,
                                   isHead: (String) -> Bool) -> [Word] {
        let lines = text.components(separatedBy: .newlines)
        let originals = original.components(separatedBy: .newlines)
        var words: [Word] = []
        for (index, line) in lines.enumerated() {
            if let whole = clean(line), whole.contains(" "), lookup.byFilename(whole) != nil {
                words.append(Word(token: whole))
                continue
            }
            let raw = originals.count == lines.count ? originals[index] : line
            if let split = noteSplit(line, original: raw, lookup: lookup, isHead: isHead) {
                words.append(Word(token: split.head, note: split.note))
                continue
            }
            words += tokens(line).map { Word(token: $0) }
        }
        return words
    }

    /// 备注前面去掉的：空白、逗号、冒号、顿号这些（括号、引号留着，是备注自己的）。
    private static let noteLead = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",，、;；:：|-—~～"))

    /// 一行开头是这一场的一张照片（文件名，或全场唯一的 ≥3 位文件号），后面跟着的是不是备注：是就返回开头那个词和备注原话。
    /// - 后面以「备注」打头（确认表复制出来的「DSCF7207 备注：去路人」）：整段原样算备注，里面再有文件名、数字都不认。
    /// - 别的写法（「7207 去路人」「DSCF7207：瘦脸」「DSCF7207 修 3 处」）：后面还认得出照片的就不是备注，整行照旧按
    ///   分隔符切 —— 有文件名、全场唯一的文件号、范围，或者全是数字、两个以上数字（「DSCF7207 12 35」「7207、35、78 都要」）。
    ///   只夹着一个小数字的（「修 3 处」）算备注：以前那个 3 会被当成表上第 3 张认进来。
    private static func noteSplit(_ line: String, original: String, lookup: Lookup,
                                  isHead: (String) -> Bool) -> (head: String, note: String)? {
        let scalars = Array(line.unicodeScalars)
        let source = Array(original.unicodeScalars)
        let raw = source.count == scalars.count ? source : scalars
        // 开头那个词可能带空格（「IMG 0001.JPG 黑白」）：在头几个分隔符处切，长的先试。中文紧贴着文件名打的
        // （「7207去路人」「DSCF7207瘦脸」）在字母数字和汉字交界处也切一刀。
        var cuts: [Int] = []
        for (i, s) in scalars.enumerated() where i > 0 && !separators.contains(scalars[i - 1]) {
            let boundary = separators.contains(s) || (!s.isASCII && scalars[i - 1].isASCII)
            guard boundary else { continue }
            cuts.append(i)
            if cuts.count >= 4 { break }
        }
        for cut in cuts.reversed() {
            let headText = String(String.UnicodeScalarView(scalars[..<cut]))
            guard let head = clean(headText), isHead(head) else { continue }
            let restText = String(String.UnicodeScalarView(scalars[cut...]))
            let rest = restText.trimmingCharacters(in: noteLead)
            guard !rest.isEmpty else { return nil }
            let rawRest = String(String.UnicodeScalarView(raw[cut...]))
            let spoken = rawRest.trimmingCharacters(in: .whitespaces)
            var note = String(spoken.drop { $0.unicodeScalars.allSatisfy(noteLead.contains) })
            if rest.hasPrefix("备注") {
                note = String(note.dropFirst(2).drop { $0.unicodeScalars.allSatisfy(noteLead.contains) })
            } else {
                // 「第 12 张」「35 号」明说是第几张的：照旧当要的照片（「DSCF7207 第12张 谢谢」）。
                if restText.range(of: #"第\s*[0-9]+|[0-9]+\s*[张張号號]"#, options: .regularExpression) != nil { return nil }
                let words = tokens(restText)
                if words.contains(where: { lookup.nameLike($0) || isRange(Substring($0)) }) { return nil }
                let numbers = words.filter { isDigits(Substring($0)) }.count
                if numbers >= 2 || (!words.isEmpty && numbers == words.count) { return nil }
            }
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedNote.isEmpty ? nil : (head, trimmedNote)
        }
        return nil
    }

    /// splitHeader 在没转半角的原文上切同一刀（halfwidth 一个字符换一个字符，位置对得上）：备注要客户的原话。
    /// 对不上（不该发生）就用转过半角的 `rest`。
    private static func originalRest(_ text: String, half: String, rest: String) -> String {
        let pattern = ProofSheetPage.header + #"\s*([0-9]{8}-[0-9]{6})"#
        guard let range = half.range(of: pattern, options: .regularExpression) else {
            return text.unicodeScalars.count == half.unicodeScalars.count ? text : rest
        }
        let hs = half.unicodeScalars
        let os = text.unicodeScalars
        guard os.count == hs.count else { return rest }
        let lower = hs.distance(from: hs.startIndex, to: range.lowerBound)
        let length = hs.distance(from: range.lowerBound, to: range.upperBound)
        let a = os.index(os.startIndex, offsetBy: lower)
        let b = os.index(a, offsetBy: length)
        var out = String.UnicodeScalarView()
        out.append(contentsOf: os[..<a])
        out.append("\n")
        out.append(contentsOf: os[b...])
        return String(out)
    }

    /// 表号那一行：「选片工具确认表 20261021-153012」。返回表号和去掉这一行之后的文字。
    static func splitHeader(_ text: String) -> (header: String?, rest: String) {
        let pattern = ProofSheetPage.header + #"\s*([0-9]{8}-[0-9]{6})"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return (nil, text) }
        let line = String(text[range])
        let header = line.range(of: #"[0-9]{8}-[0-9]{6}"#, options: .regularExpression).map { String(line[$0]) }
        return (header, text.replacingCharacters(in: range, with: "\n"))
    }

    /// 当成表格认出来的：用了哪几列、按读的顺序要认的词，以及别的列里带数字、认不出的格子。
    private struct Table {
        var columns: [String] = []
        var tokens: [String] = []
        var dropped: [String] = []
    }

    /// 像导出的 CSV（Pixieset 收藏夹之类）就只取像文件名的那几列，备注、合集名那些列不拿来认（备注里的数字
    /// 不会被当成编号）。要同时满足：至少两行两列、大多数行列数一样；第一行像表头 —— 不带数字、也没有
    /// 这一场的文件名（微信回「12，35」换行「DSCF7207，DSCF7208」，第一行是客户要的编号，不是表头）；
    /// 至少有一列一半以上的格子是文件名或全场唯一的文件号。不像表格就返回 nil，按普通文字切。
    /// 别的列里的格子：本身就是文件名 / 文件号的照认；带数字又认不出的列进「没认出」，一个都不悄悄扔。
    private static func table(_ text: String, lookup: Lookup) -> Table? {
        let rows = CSV.parseRows(text).map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        guard rows.count >= 2, let head = rows.first, head.count >= 2,
              !head.contains(where: { hasDigit($0) || lookup.byFilename($0) != nil }) else { return nil }
        let body = rows.dropFirst()
        guard body.filter({ $0.count == head.count }).count * 5 >= body.count * 4 else { return nil }
        var keep = Set<Int>()
        for column in 0..<head.count {
            let cells = body.compactMap { $0.count > column ? clean($0[column]) : nil }
            let hits = cells.filter(lookup.nameLike).count
            if hits > 0, hits * 2 >= cells.count { keep.insert(column) }
        }
        guard !keep.isEmpty else { return nil }
        var t = Table()
        t.columns = head.indices.filter(keep.contains).map { head[$0].isEmpty ? "第 \($0 + 1) 列" : head[$0] }
        for row in body {
            for (column, cell) in row.enumerated() {
                guard let token = clean(cell) else { continue }
                if keep.contains(column) || lookup.nameLike(token) {
                    t.tokens.append(token)
                } else if hasDigit(token) {
                    t.dropped.append(token)
                }
            }
        }
        return t
    }

    /// `deliveries`：这一场导出过的交付对照（exports.json），客户按导出的文件名回也认得回原片。
    static func resolve(_ text: String, items: [BatchItem], sheets: [ProofSheet],
                        deliveries: [DeliveryRecord] = []) -> Resolution {
        let lookup = Lookup(items, deliveries: deliveries)
        var r = Resolution()
        let half = halfwidth(text)
        let (header, rest) = splitHeader(half)
        r.header = header
        if let header {
            r.sheet = sheets.last { $0.id == header }
        } else {
            r.sheet = sheets.last
        }
        var seen = Set<String>()
        var unknownSeen = Set<String>()
        /// 这个词带着的备注：认出照片时记到那张上。
        var pendingNote: String?
        func hit(_ id: String) {
            if seen.insert(id).inserted { r.ids.append(id) }
            if let note = pendingNote { r.notes[id] = note }
            pendingNote = nil
        }
        func miss(_ token: String) { if unknownSeen.insert(token).inserted { r.unknown.append(token) } }
        /// 表上第 n 张（还在这一场的）。
        func sheetPhoto(_ n: Int) -> String? {
            guard let sheet = r.sheet, n >= 1, n <= sheet.ids.count else { return nil }
            let id = sheet.ids[n - 1]
            return lookup.live.contains(id) ? id : nil
        }
        /// 一行开头能带备注的：认得出唯一一张的文件名，或全场唯一的 ≥3 位文件号（编号也对得上另一张的不算，下面会报
        /// 「文件号还是编号？」）。表上的编号不算：「12、35、78 都要」开头的 12 不能把后面当成备注。
        func uniqueHead(_ token: String) -> Bool {
            if let ids = lookup.byFilename(token) { return ids.count == 1 }
            guard token.count >= 3, isDigits(Substring(token)), let number = fileNumber(token),
                  let ids = lookup.byNumber[number], ids.count == 1, let file = ids.first else { return false }
            if let index = Int(token).flatMap(sheetPhoto), index != file { return false }
            return true
        }

        let parsed = table(rest, lookup: lookup)
        r.tableColumns = parsed?.columns
        r.tableDropped = Set(parsed?.dropped ?? []).count
        let words = parsed.map { $0.tokens.map { Word(token: $0) } }
            ?? lineTokens(rest, original: originalRest(text, half: half, rest: rest), lookup: lookup, isHead: uniqueHead)
        for word in words {
            let token = word.token
            pendingNote = word.note
            if let ids = lookup.byFilename(token) {
                if ids.count == 1, let id = ids.first { hit(id) } else { miss(token + "（重名）") }
                continue
            }
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, isDigits(parts[0]), isDigits(parts[1]),
               let a = Int(parts[0]), let b = Int(parts[1]) {
                // 范围只当编号认：12-15 = 表上第 12 到 15 张。
                guard r.sheet != nil else { r.numbersWithoutSheet = true; miss(token); continue }
                let photos = a <= b && b - a < 1000 ? (a...b).map(sheetPhoto) : [nil]
                if photos.contains(where: { $0 == nil }) { miss(token); continue }
                photos.compactMap { $0 }.forEach(hit)
                r.usedSheet = true
                continue
            }
            guard isDigits(Substring(token)) else {
                // 不带数字、也不像文件名的多半是聊天里的字（「要这几张」「谢谢」），不算没认出。
                let ext = URL(fileURLWithPath: token).pathExtension.lowercased()
                if token.contains(where: \.isNumber) || ImageLoader.imageExtensions.contains(ext) { miss(token) }
                continue
            }
            // 文件号：≥3 位、全场只有一张；编号：表上的第 n 张。两个都有又不是同一张 = 说不准，不替你挑。
            let byNumber = token.count >= 3 ? lookup.byNumber[fileNumber(token) ?? ""] : nil
            let byFile = byNumber?.count == 1 ? byNumber?.first : nil
            let byIndex = Int(token).flatMap(sheetPhoto)
            // 纯数字的交付文件名（{序号:3} 导出的 001.jpg）：客户回「001」也可能说的是它，算第三种认法 ——
            // 和文件号、编号指的不是同一张，一样说不准。
            if let delivered = lookup.deliveredName[token] {
                let others = Set([byFile, byIndex].compactMap { $0 })
                if delivered.count == 1, let id = delivered.first, others.isSubset(of: [id]) {
                    hit(id)
                } else {
                    miss(token + (delivered.count > 1 ? "（重名）" : "（交付文件名还是编号？）"))
                }
                continue
            }
            switch (byFile, byIndex) {
            case let (file?, index?) where file != index:
                miss(token + "（文件号还是编号？）")
            case let (file?, _):
                hit(file)
            case let (nil, index?):
                hit(index)
                r.usedSheet = true
            default:
                if r.sheet == nil { r.numbersWithoutSheet = true }
                miss(token + ((byNumber?.count ?? 0) > 1 ? "（好几张都是这个号）" : ""))
            }
        }
        // 表格别的列里带数字、认不出的格子：不拿来认（多半是备注、序号），可也不悄悄扔，列在后面。
        parsed?.dropped.forEach(miss)
        return r
    }

    /// 导入框里的预览（几行字）。`existing` = 现在的客户选中（导入是加上去，不清掉原来的）。
    static func summary(_ r: Resolution, existing: Set<String>) -> [String] {
        var lines: [String] = []
        var head = "认出 \(r.ids.count) 张"
        if !r.unknown.isEmpty {
            let shown = r.unknown.prefix(12).joined(separator: "、") + (r.unknown.count > 12 ? "…" : "")
            head += " · 没认出 \(r.unknown.count) 个：" + shown
        }
        lines.append(head)
        if let columns = r.tableColumns {
            var table = "当成表格认：第一行是表头，只用了「" + columns.joined(separator: "」「") + "」列"
            if r.tableDropped > 0 { table += "；别的列里带数字的 \(r.tableDropped) 格没拿来认，列在没认出里" }
            lines.append(table)
        }
        if r.usedSheet, let sheet = r.sheet {
            lines.append("编号按 \(sheet.title)对" + (r.header == nil ? "（没带表号，按最近导出的那张）" : ""))
        } else if let header = r.header, r.sheet == nil {
            lines.append("表号 \(header) 不是这一场导出的确认表，编号认不了（文件名照样认）")
        } else if r.numbersWithoutSheet {
            lines.append("这一场还没导出过确认表，编号认不了（文件名、文件号照样认）")
        }
        if let note = notesLine(r) { lines.append(note) }
        if let quota = quotaLine(r) { lines.append(quota) }
        if !r.ids.isEmpty {
            let fresh = r.ids.filter { !existing.contains($0) }.count
            var add = "加到客户选中里：新增 \(fresh) 张"
            if fresh < r.ids.count { add += "，\(r.ids.count - fresh) 张本来就是" }
            if !existing.isEmpty { add += "（原来的 \(existing.count) 张留着；要重来先「清除客户选中」）" }
            lines.append(add)
        }
        return lines
    }

    /// 「带备注 2 张：DSCF7207「去路人」、DSCF7210「黑白」」（按认出的顺序，最多列 3 张，每条太长截掉）。
    static func notesLine(_ r: Resolution) -> String? {
        let noted = r.ids.filter { r.notes[$0] != nil }
        guard !noted.isEmpty else { return nil }
        let shown = noted.prefix(3).map { id -> String in
            let note = r.notes[id] ?? ""
            let short = note.count > 24 ? String(note.prefix(24)) + "…" : note
            return id + "「" + short + "」"
        }
        let more: String = noted.count > 3 ? "…" : ""
        let list = shown.joined(separator: "、")
        return "带备注 \(noted.count) 张：\(list)\(more)（存进客户备注，复制原片时写成「精修要求.csv」）"
    }

    /// 那张表设了套餐张数：这次认出几张、超没超（只提示）。
    static func quotaLine(_ r: Resolution) -> String? {
        guard let quota = r.sheet?.quota, quota > 0, !r.ids.isEmpty else { return nil }
        let which = r.header == nil ? "（按最近导出的那张表）" : ""
        let over = r.ids.count - quota
        let tail = over > 0 ? "，超出 \(over) 张（加片）" : ""
        return "套餐含 \(quota) 张\(which)：这次认出 \(r.ids.count) 张" + tail
    }
}

// MARK: - 复制文件名清单（给 LR / C1 / Photo Mechanic 筛出这些照片）

enum FilenameList {
    enum Format: String, CaseIterable, Identifiable {
        case lightroom = "lr"
        case captureOne = "c1"
        case lines = "lines"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lightroom: return "Lightroom（逗号分隔）"
            case .captureOne: return "Capture One（空格分隔）"
            case .lines: return "一行一个（Photo Mechanic / 通用）"
            }
        }

        /// 复制完状态栏上那句：在那边怎么用。
        var howTo: String {
            switch self {
            case .lightroom: return "Lightroom：图库筛选器「文本 › 文件名 › 包含」里粘贴"
            case .captureOne: return "Capture One：选择 › 按文件名列表选择，分隔符选空格"
            case .lines: return "一行一个：存成 .txt 给 Photo Mechanic「Edit › Load Selection」，或别的工具"
            }
        }
    }

    private static func stem(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// LR / C1 用文件名去掉扩展名（RAW+JPG 一对只列一次）；一行一个列完整文件名，RAW+JPG 两个都列。
    static func make(_ chosen: [BatchItem], format: Format) -> (text: String, count: Int) {
        guard format != .lines else {
            var names: [String] = []
            for item in chosen {
                names.append(URL(fileURLWithPath: item.rawPath).lastPathComponent)
                if item.decodePath != item.rawPath { names.append(URL(fileURLWithPath: item.decodePath).lastPathComponent) }
            }
            return (names.map { $0 + "\n" }.joined(), names.count)
        }
        var seen = Set<String>()
        let names = chosen.map { stem($0.rawPath) }.filter { seen.insert($0.lowercased()).inserted }
        return (names.joined(separator: format == .lightroom ? ", " : " "), names.count)
    }

    /// 提醒：LR 的「包含」是按字串包含筛的，IMG_1 也会筛出 IMG_101（Pixieset 也这么提醒）；C1 用空格分隔，
    /// 带空格的文件名会被拆开。返回要说的一句话（没有就 nil）。
    static func caveat(_ chosen: [BatchItem], all: [BatchItem], format: Format) -> String? {
        let listed = Dictionary(chosen.map { (stem($0.rawPath).lowercased(), stem($0.rawPath)) },
                                uniquingKeysWith: { first, _ in first })
        let names = Set(listed.keys)
        switch format {
        case .lightroom:
            // 名字一样长就不可能互相包含（相机编号一般都是定长）：只拿比最短的名字还长的来比，大场次不至于两两比。
            guard let shortest = names.map(\.count).min() else { return nil }
            let longer = Set(all.map { stem($0.rawPath).lowercased() }).subtracting(names).filter { $0.count > shortest }
            let hit = longer.isEmpty ? [] : names.sorted().filter { n in longer.contains { $0.count > n.count && $0.contains(n) } }
            guard let first = hit.first else { return nil }
            return "注意：\(listed[first] ?? first) 等 \(hit.count) 个名字是别的文件名的一部分，LR「包含」会多筛出来，筛完核对一下"
        case .captureOne:
            let spaced = names.filter { $0.contains(" ") }.count
            return spaced > 0 ? "注意：\(spaced) 个文件名带空格，Capture One 按空格分隔会拆开它们" : nil
        case .lines:
            return nil
        }
    }
}

// MARK: - 复制原片到精修文件夹（一键分片）

enum OriginalsCopier {
    /// 一张照片：原图（RAW 或 JPG）、RAW+JPG 的另一半。旁边的 .xmp 在复制时现找（后台线程）。
    struct Shot: Sendable {
        let id: String
        let rawPath: String
        let decodePath: String
    }

    struct ShotResult: Sendable {
        var copied = 0
        var skipped = 0
        var renamed = false
        /// 目标里已经有同名的 .xmp、内容不一样（多半是上次复制之后又写过一次 XMP）：不覆盖，留着旧的。
        var keptSidecar = false
        var failed: [String] = []
        var cancelled = false
        /// 这一张因为目标那边写不进去而失败的原因（盘满、没权限、不支持、写完校验对不上）。原片读不出来、
        /// 目标里刚冒出同名的别的文件不算：那不说明后面的也会失败（FailureStreak 只数这一种）。
        var targetFailure: String?
    }

    /// 目标文件夹在拍摄文件夹里面、而且下次分析会扫到它（listPhotos 递归，只跳过导出JPG / 高ISO降噪这类
    /// 排除的子文件夹和点开头的隐藏文件夹）。原片复制进去，下次分析就成了重复的新照片 —— 这种目标不让选。
    /// 按目录本身（设备号 + inode）往上找拍摄文件夹，/tmp 和 /private/tmp、大小写都骗不过它。
    static func insideAnalysis(_ dest: URL, shoot: URL) -> Bool {
        var root = stat()
        guard stat(shoot.path, &root) == 0 else { return false }
        // 先把已经存在的那段软链接解开：目标本身是指向拍摄文件夹里的软链接，也算在里面。
        var url = dest.resolvingSymlinksInPath().standardizedFileURL
        var below: [String] = []
        while true {
            var here = stat()
            if stat(url.path, &here) == 0, here.st_dev == root.st_dev, here.st_ino == root.st_ino {
                return !below.contains { ImageLoader.excludedSubfolders.contains($0) || $0.hasPrefix(".") }
            }
            guard url.path != "/" else { return false }
            below.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
    }

    /// 两个文件内容一样吗：大小一样、整份 SHA-256 一样。
    static func sameContent(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let sa = (try? fm.attributesOfItem(atPath: a.path))?[.size] as? NSNumber,
              let sb = (try? fm.attributesOfItem(atPath: b.path))?[.size] as? NSNumber,
              sa == sb,
              let ha = try? CardImporter.sha256(of: a), let hb = try? CardImporter.sha256(of: b) else { return false }
        return ha == hb
    }

    private static func renamed(_ url: URL, suffix: String, in dest: URL) -> URL {
        let base = dest.appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix)
        return url.pathExtension.isEmpty ? base : base.appendingPathExtension(url.pathExtension)
    }

    /// 复制一张：RAW、JPG 用同一个名字落地 —— 先试原名；目标里有同名但内容不一样的，整张换 -2、-3…
    /// （一模一样的跳过、算「已经有了」）。旁边的 .xmp 跟着照片的名字走，目标里已有不一样的就不覆盖。
    /// 每个文件走存储卡导入同一套：先写 .part、大小和 SHA-256 校验通过、RENAME_EXCL 改名（绝不覆盖）。
    /// 原片只读不写。
    static func copy(_ shot: Shot, to dest: URL, cancel: AnalysisEngine.CancelFlag) -> ShotResult {
        let fm = FileManager.default
        var result = ShotResult()
        var images = [URL(fileURLWithPath: shot.rawPath)]
        if shot.decodePath != shot.rawPath { images.append(URL(fileURLWithPath: shot.decodePath)) }
        // 每个后缀下：照片文件在目标里要么没有、要么一模一样（记下哪些一样，后面不再算一遍 SHA）。
        var identical = Set<URL>()
        var chosen: String?
        for n in 1...999 where chosen == nil {
            let suffix = n == 1 ? "" : "-\(n)"
            var same = Set<URL>()
            let fits = images.allSatisfy { src in
                let target = renamed(src, suffix: suffix, in: dest)
                guard fm.fileExists(atPath: target.path) else { return true }
                guard sameContent(src, target) else { return false }
                same.insert(src)
                return true
            }
            if fits { chosen = suffix; identical = same }
        }
        guard let suffix = chosen else {
            result.failed.append("\(shot.id)：-2 到 -999 都被占了")
            return result
        }
        result.renamed = !suffix.isEmpty
        var plan = images.map { ($0, renamed($0, suffix: suffix, in: dest)) }
        let xmp = images[0].deletingPathExtension().appendingPathExtension("xmp")
        if fm.fileExists(atPath: xmp.path) { plan.append((xmp, renamed(xmp, suffix: suffix, in: dest))) }
        for (src, target) in plan {
            if identical.contains(src) {
                result.skipped += 1
                continue
            }
            if fm.fileExists(atPath: target.path) {
                if src == xmp, sameContent(src, target) {
                    result.skipped += 1
                } else if src == xmp {
                    result.keptSidecar = true
                } else {
                    result.failed.append("\(target.lastPathComponent)：目标里刚冒出同名的别的文件，没覆盖")
                }
                continue
            }
            do {
                let attrs = try fm.attributesOfItem(atPath: src.path)
                let copy = CardImporter.Copy(source: src, target: target,
                                             size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                                             modified: attrs[.modificationDate] as? Date,
                                             created: attrs[.creationDate] as? Date,
                                             originalName: src.lastPathComponent, shot: shot.id)
                _ = try CardImporter.copyOne(copy, into: dest, cancel: cancel, onBytes: { _ in })
                result.copied += 1
            } catch CardImporter.ImportError.cancelled {
                result.cancelled = true
                return result
            } catch let error as CardImporter.ImportError {
                let why = reason(error)
                result.failed.append(src.lastPathComponent + "：" + why)
                if targetSide(error) { result.targetFailure = why }
            } catch {
                result.failed.append(src.lastPathComponent + "：" + CardImporter.describe(error))
            }
        }
        return result
    }

    /// 存储卡导入的错误说法是冲着读卡来的（「读卡不稳？」），这里换成说盘。
    private static func reason(_ error: CardImporter.ImportError) -> String {
        switch error {
        case .sizeMismatch, .verifyFailed: return "复制后校验对不上（盘不稳？），没留下半截"
        case .writeFailed(_, let why): return "写不进目标文件夹：" + localized(why)
        default: return error.shortReason
        }
    }

    /// 是目标那边的问题（后面的多半也写不进去）：写不进、盘满、写完校验对不上、路径不对。
    private static func targetSide(_ error: CardImporter.ImportError) -> Bool {
        switch error {
        case .writeFailed, .diskFull, .sizeMismatch, .verifyFailed, .unsafePath: return true
        case .readFailed, .targetExists, .cancelled, .unreadable: return false
        }
    }

    /// copyOne 在 RENAME_EXCL 回了别的 errno 时给的是英文 strerror（「Operation not supported」）：认得出的换成中文
    /// （和 CardImporter.describe 同一套说法，审查 S15）。
    static func localized(_ why: String) -> String {
        for code in [ENOTSUP, EOPNOTSUPP, EACCES, EPERM, EIO, ENOENT, ENOSPC, ENXIO, ENODEV, EROFS]
        where why == String(cString: strerror(code)) {
            switch code {
            case EOPNOTSUPP: return CardImporter.describe(CardImporter.errnoError(ENOTSUP))
            case EROFS: return "这块盘是只读的"
            default: return CardImporter.describe(CardImporter.errnoError(code))
            }
        }
        return why
    }

    /// 连续几张都写不进目标就停（审查 S15）：目标在不支持的共享 / 盘上、盘满、被拔时，以前每张都完整写完、回读一遍才失败，
    /// 几百张 RAW 白跑一整批。只数目标那边的失败（targetFailure）；复制成了一个文件就重新数，跳过的（目标里一模一样）、
    /// 只是原片读不出来的不算、也不打断。
    struct FailureStreak {
        static let limit = 3
        private(set) var count = 0
        /// 最后那一张的原因（停下时报给用户）。
        private(set) var lastReason: String?
        var shouldStop: Bool { count >= Self.limit }

        mutating func record(_ r: ShotResult) {
            if r.copied > 0 {
                count = 0
                lastReason = nil
                return
            }
            guard let why = r.targetFailure else { return }
            count += 1
            lastReason = why
        }
    }

    /// 停下来时状态栏那一句：几张、为什么、后面几张没试、怎么办。
    static func stopNote(_ streak: FailureStreak, remaining: Int) -> String {
        let why = streak.lastReason ?? "写不进目标文件夹"
        return "连续 \(FailureStreak.limit) 张都没复制成（\(why)），停下了，后面 \(remaining) 张没再试：" + stopHint(why)
    }

    /// 按原因给的下一步：不支持 → 多半是 NAS 共享 / exFAT 盘；盘满；没权限 / 只读；别的先看盘还在不在。
    static func stopHint(_ why: String) -> String {
        if why.contains(CardImporter.describe(CardImporter.errnoError(ENOTSUP))) {
            return "目标所在的盘或共享不支持这样写（NAS / SMB 共享、部分 exFAT 移动硬盘常见），换一个本机磁盘上的文件夹再复制"
        }
        if why.contains("盘满") { return "目标盘满了，腾出空间或换一块盘再复制一次（已经复制好的会跳过）" }
        if why.contains("没有权限") || why.contains("只读") { return "这个文件夹写不进去，换一个文件夹再复制" }
        return "看看目标盘还插着、能写，再复制一次（已经复制好的会跳过）"
    }
}

// MARK: - BatchStore：确认表记录、导入客户选择、筛选范围、复制文件名 / 原片

extension BatchStore {
    private var proofSheetsPath: URL { sessionDir.appendingPathComponent("proof_sheets.json") }

    /// 这一场导出过的确认表，最早的在前。只读不挪（导入框每敲一个字读一次）：解不开的到下一次记一笔时再挪开。
    var proofSheets: [ProofSheet] {
        if case .ok(let sheets) = SessionFiles.read([ProofSheet].self, at: proofSheetsPath, moveAside: false) { return sheets }
        return []
    }

    /// 导出成功后记一笔（只留最近 30 张）。以前记录文件解不开就当空的，记这一笔时把以前的整份盖掉（审查 S02）：
    /// 现在先挪成 proof_sheets.corrupt-<时间>.json；读不出来、挪不开的不写，免得盖掉。
    func recordProofSheet(_ sheet: ProofSheet) {
        let lost = "这张表的编号没记下：客户只回编号时认不出（回文件名照样认）"
        var existing: [ProofSheet] = []
        switch SessionFiles.read([ProofSheet].self, at: proofSheetsPath) {
        case .missing:
            break
        case .ok(let sheets):
            existing = sheets
        case .corrupt(let moved?):
            let name = photoDir.map { "「\($0.lastPathComponent)」" } ?? ""
            addDataNotice("\(name)的确认表记录 proof_sheets.json 解不开，原件已挪成 \(moved.lastPathComponent)：" +
                          "以前导出的确认表，客户只回编号时认不出（回文件名照样认）")
        case .corrupt(nil), .unreadable:
            lastError = "确认表导出了，但记录文件 proof_sheets.json 读不出来、也挪不开，" + lost
            return
        }
        let sheets = Array((existing.filter { $0.id != sheet.id } + [sheet]).suffix(30))
        guard let data = try? JSONEncoder().encode(sheets), SessionFiles.writeLogged(data, to: proofSheetsPath) else {
            lastError = "确认表导出了，但写 proof_sheets.json 失败，" + lost
            return
        }
    }

    /// 粘贴进来的客户回复认成哪些照片（导入框边打字边算）。
    func resolveClientReply(_ text: String) -> ClientReply.Resolution {
        ClientReply.resolve(text, items: items, sheets: proofSheets, deliveries: deliveryRecords)
    }

    /// 「标记为客户选中」：加到原来的客户选中上（客户常常分几次回，加选是常事）。一步 ⌘Z 撤回。
    /// `notes` = 这次回复里的备注（照片 id → 原话）：同一张原来有备注的换成这次的，没写的留着原来的；
    /// 和客户选中一起进同一步撤销。
    func importClientPicks(_ ids: [String], notes: [String: String] = [:]) {
        let before = clientPicks.count
        let picks = clientPicks.union(ids)
        let merged = clientNotes.merging(notes.filter { !$0.value.isEmpty }) { _, new in new }
        if merged == clientNotes {
            setClientPicks(picks)
        } else {
            setClientReply(picks: picks, notes: merged)
        }
        let added = clientPicks.count - before
        let noted = notes.isEmpty ? "" : " · 备注 \(notes.count) 张"
        progressText = "客户选中：新增 \(added) 张，共 \(clientPicks.count) 张\(noted) · ⌘Z 撤销"
    }

    func clearClientPicks() {
        let n = clientPicks.count
        let notes = clientNotes.count
        // 「只看客户选中」开着的话一起关掉，不然网格一下子空了。
        clientPickFilter = false
        // 备注跟着一起清（重导一遍客户回复的时候不留上一轮的修图要求）；同一步 ⌘Z 一起回来。
        if notes == 0 {
            setClientPicks([])
        } else {
            setClientReply(picks: [], notes: [:])
        }
        let noted = notes == 0 ? "" : "、备注 \(notes) 条"
        progressText = "已清除客户选中 \(n) 张\(noted) · ⌘Z 撤销"
    }

    /// 这几张里带客户备注的，按给的顺序：精修要求.csv 的行（文件名 = 原片的名字）。
    func retouchRows(_ ids: [String]) -> [OriginalsCopier.RetouchRow] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id -> OriginalsCopier.RetouchRow? in
            guard let note = clientNotes[id], !note.isEmpty, let item = byID[id] else { return nil }
            return OriginalsCopier.RetouchRow(file: URL(fileURLWithPath: item.rawPath).lastPathComponent, note: note)
        }
    }

    /// 「当前筛选」下的照片：判决筛选、只看客户选中、只看这一章、只看临界、废片的理由筛选 —— 和按判决的网格
    /// 看得见的一样，只是不管分组视图里收起来的单张、叠起来的废片。复制文件名 / 复制原片没选中照片时用它。
    func filteredItems() -> [BatchItem] {
        let chapter = activeChapterFilter
        return items.filter { passesFilters($0, chapter: chapter) }
    }

    /// 只数张数（「导出」菜单上的范围说明每次重绘都要，别为它建数组）。
    var filteredCount: Int {
        let chapter = activeChapterFilter
        var n = 0
        for item in items where passesFilters(item, chapter: chapter) { n += 1 }
        return n
    }

    private func passesFilters(_ item: BatchItem, chapter: Int?) -> Bool {
        if let v = verdictFilter, item.verdict != v { return false }
        if clientPickFilter, !clientPicks.contains(item.id) { return false }
        if let chapter, Self.timelineChapter(of: item) != chapter { return false }
        if borderlineFilter, !isBorderline(item) { return false }
        if item.verdict == .reject, let reason = reasonFilter, !item.rejectReasons.contains(reason) { return false }
        return true
    }

    /// 复制文件名清单到剪贴板，状态栏说复制了几个、什么格式、在那边怎么用。
    func copyFilenameList(_ ids: [String], format: FilenameList.Format) {
        let wanted = Set(ids)
        let chosen = items.filter { wanted.contains($0.id) }
        guard !chosen.isEmpty else {
            lastError = "没有可复制的照片"
            return
        }
        let list = FilenameList.make(chosen, format: format)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list.text, forType: .string)
        progressText = "已复制 \(list.count) 个文件名（\(format.title)）· \(format.howTo)"
        lastError = FilenameList.caveat(chosen, all: items, format: format)
    }

    private var copyDestinationPath: URL { sessionDir.appendingPathComponent("copy_originals.json") }

    /// 上次「复制原片到…」选的文件夹（每场各记各的）。
    var lastCopyDestination: URL? {
        (try? Data(contentsOf: copyDestinationPath))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["dest"]
            .map { URL(fileURLWithPath: $0) }
    }

    /// 「复制原片到…」：把这些照片的原片（RAW+JPG 一起、旁边的 .xmp 一起）复制（不是移动）到 dest。
    /// 目标里一模一样的跳过，同名不同内容的整张另存 -2；每个文件复制完校验大小和 SHA-256；原片只读。
    /// 后台跑、顶栏有进度和「取消」；完了不弹访达。
    func copyOriginals(_ ids: [String], to dest: URL) {
        guard !isRunning else { return }
        guard let photoDir else { return }
        let wanted = Set(ids)
        let shots = items.filter { wanted.contains($0.id) }
            .map { OriginalsCopier.Shot(id: $0.id, rawPath: $0.rawPath, decodePath: $0.decodePath) }
        guard !shots.isEmpty else {
            lastError = "没有可复制的照片"
            return
        }
        if !FileManager.default.fileExists(atPath: photoDir.path) {
            lastError = "照片文件夹「\(photoDir.lastPathComponent)」不存在 (被删除、改名或硬盘未挂载)，没法复制原片"
            return
        }
        if OriginalsCopier.insideAnalysis(dest, shoot: photoDir) {
            lastError = "不能复制到拍摄文件夹里面：下次分析会把复制过去的原片当成新照片。" +
                "请选拍摄文件夹外面的文件夹（比如旁边新建一个「\(photoDir.lastPathComponent)_精修」）"
            return
        }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            lastError = "建不了目标文件夹: \(CardImporter.describe(error))"
            return
        }
        if let data = try? JSONEncoder().encode(["dest": dest.path]) {
            try? data.write(to: copyDestinationPath, options: .atomic)
        }
        // 客户写了修图要求的：先在目标里写一份「精修要求.csv」（不覆盖），完了状态栏上说一声。
        let retouch = OriginalsCopier.writeRetouchNotes(retouchRows(shots.map(\.id)), to: dest)
        isRunning = true
        lastError = nil
        let flag = freshCancelFlag()
        let total = shots.count
        progressText = "复制原片 0/\(total)..."

        Task.detached { [weak self] in
            var copied = 0, skipped = 0, renamed = 0, keptSidecars = 0, done = 0
            var failed: [String] = []
            var streak = OriginalsCopier.FailureStreak()
            for shot in shots {
                if flag.isSet { break }
                let r = OriginalsCopier.copy(shot, to: dest, cancel: flag)
                if r.cancelled { break }
                copied += r.copied
                skipped += r.skipped
                if r.renamed && r.copied > 0 { renamed += 1 }
                if r.keptSidecar { keptSidecars += 1 }
                failed += r.failed
                done += 1
                // 连续几张都写不进目标：后面的多半也一样，停下（审查 S15）
                streak.record(r)
                if streak.shouldStop && done < total { break }
                let doneNow = done
                await MainActor.run { [weak self] in
                    self?.progressText = "复制原片 \(doneNow)/\(total)..."
                    self?.progressFraction = Double(doneNow) / Double(total)
                }
            }
            let stopped = streak.shouldStop && done < total
            let stopNote = stopped ? OriginalsCopier.stopNote(streak, remaining: total - done) : nil
            let summary = OriginalsCopier.summary(shots: done, copied: copied, skipped: skipped, renamed: renamed,
                                                  keptSidecars: keptSidecars, folder: dest.lastPathComponent,
                                                  cancelled: flag.isSet, stopped: stopped)
            let failures = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progressFraction = nil
                self.isRunning = false
                self.progressText = summary + (retouch.map { " · " + $0 } ?? "")
                if let stopNote {
                    self.lastError = "复制原片: " + stopNote
                } else if !failures.isEmpty {
                    let names = failures.prefix(3).joined(separator: "；") + (failures.count > 3 ? "…" : "")
                    self.lastError = "复制原片: \(failures.count) 个文件没复制 (\(names))"
                }
            }
        }
    }
}

extension OriginalsCopier {
    static func summary(shots: Int, copied: Int, skipped: Int, renamed: Int, keptSidecars: Int,
                        folder: String, cancelled: Bool, stopped: Bool = false) -> String {
        let head: String = cancelled ? "已取消: " : (stopped ? "复制原片停下了: " : "复制原片完成: ")
        var parts = [head + "\(shots) 张 · 复制了 \(copied) 个文件 → \(folder)/"]
        if skipped > 0 { parts.append("\(skipped) 个目标里已经有了（一模一样）跳过") }
        if renamed > 0 { parts.append("\(renamed) 张和目标里的同名不同内容，另存为 -2") }
        if keptSidecars > 0 { parts.append("\(keptSidecars) 个 .xmp 目标里已有不一样的，没覆盖") }
        return parts.joined(separator: " · ")
    }

    /// 精修要求.csv 的一行：原片文件名、客户备注。
    struct RetouchRow: Equatable {
        let file: String
        let note: String
    }

    static let retouchFileName = "精修要求"

    /// 精修要求.csv 的内容：表头「文件名,备注」、一张一行；UTF-8 带 BOM（Excel 直接双击打开中文不乱码）。
    static func retouchCSV(_ rows: [RetouchRow]) -> Data {
        var text = "\u{FEFF}" + CSV.writeRow(["文件名", "备注"]) + "\r\n"
        for row in rows { text += CSV.writeRow([row.file, row.note]) + "\r\n" }
        return Data(text.utf8)
    }

    /// 「复制原片到…」时一起写的修图要求（这次复制的照片里带客户备注的）。目标里已有「精修要求.csv」：一模一样就不再写，
    /// 不一样另存「精修要求-2.csv」…，绝不覆盖（写的时候也是「不存在才写」）。返回状态栏上那一句；没有备注 = nil。
    static func writeRetouchNotes(_ rows: [RetouchRow], to dest: URL) -> String? {
        guard !rows.isEmpty else { return nil }
        let data = retouchCSV(rows)
        for n in 1...99 {
            let suffix: String = n == 1 ? "" : "-\(n)"
            let name = "\(retouchFileName)\(suffix).csv"
            let url = dest.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                if (try? Data(contentsOf: url)) == data { return "\(name) 已经有了（\(rows.count) 张的备注，一模一样）" }
                continue
            }
            do {
                try data.write(to: url, options: .withoutOverwriting)
                let kept = n == 1 ? "" : "（目标里已有不一样的\(retouchFileName).csv，没覆盖）"
                return "写了 \(name)（\(rows.count) 张的客户备注）" + kept
            } catch {
                return "\(name) 没写成（\(CardImporter.describe(error))），客户备注还在 app 里（鼠标停在网格的紫心上能看）"
            }
        }
        return "\(retouchFileName)-2 到 -99.csv 都被占了，客户备注没写出来"
    }
}
