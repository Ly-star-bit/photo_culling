import Foundation
import ImageIO

/// 原图旁 .xmp 的归属判断和「只改星级 / 色标」的合并。写 XMP（BatchStore.exportXMP）用。
enum XMPSidecar {
    /// 我们自己写的 sidecar 的指纹 —— Lightroom 写的是 x:xmptk="Adobe XMP Core ..."。
    /// 靠它区分“上次是我们写的，可以整份重写”和“别人的数据，只能合并”。
    static let marker = #"x:xmptk="选片工具""#
    /// 本工具以前的版本写的（2026-09 之前的 Python 流水线 rate.py，标记是 culling-poc）：
    /// 也是我们的模板、只有星级色标，可以整份重写。以前不认它，这些 sidecar 被当成别人的，
    /// 永远不更新、也不进「XMP 待更新」。
    static let legacyMarkers = [#"x:xmptk="culling-poc""#]

    static func isOwn(_ data: Data) -> Bool {
        ([marker] + legacyMarkers).contains { data.range(of: Data($0.utf8)) != nil }
    }

    /// 别人的 sidecar（LR 开着自动写 XMP、C1、Photo Mechanic 导入模板）：只改 xmp:Rating / xmp:Label，
    /// 调色、关键字、GPS 原样留着。这次没有色标（可用）时：文件里的色标还是 `lastLabel`（上次我们写的：
    /// 精选绿、废片红、客户选中紫）才拿掉；是别的色（你之后在 LR 里改的）就留着。
    /// 解析 → 改两个字段 → 重新序列化，再验一遍：除这两个字段外 ImageIO 看到的每个字段都没变，
    /// 而且原文件里写着的每个值在新文件里都还在（ImageIO 读不全的写法会在这里露馅）；
    /// 重写后会变类型的 RDF 写法（rdf:resource 等）直接不合并。XML 注释会丢，不算数据。
    /// 任何一处对不上就返回 nil —— 宁可这张不写，也不能把别人的调色写丢。
    static func merged(_ data: Data, rating: Int, label: String?, lastLabel: String?) -> Data? {
        guard let parsed = CGImageMetadataCreateFromXMPData(data as CFData),
              let meta = CGImageMetadataCreateMutableCopy(parsed),
              CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "\(rating)" as CFString)
        else { return nil }
        var before = fields(parsed)
        let existingLabel = before["xmp:Label"]?.value
        let dropLabel = label == nil && lastLabel != nil && existingLabel == lastLabel
        if let label {
            guard CGImageMetadataSetValueWithPath(meta, nil, "xmp:Label" as CFString, label as CFString) else { return nil }
        } else if dropLabel {
            CGImageMetadataRemoveTagWithPath(meta, nil, "xmp:Label" as CFString)
        }
        guard let out = CGImageMetadataCreateXMPData(meta, nil) as Data?,
              let reparsed = CGImageMetadataCreateFromXMPData(out as CFData) else { return nil }
        var after = fields(reparsed)
        let wantLabel = label ?? (dropLabel ? nil : existingLabel)
        guard after["xmp:Rating"]?.value == "\(rating)", after["xmp:Label"]?.value == wantLabel else { return nil }
        for key in ["xmp:Rating", "xmp:Label"] {
            before.removeValue(forKey: key)
            after.removeValue(forKey: key)
        }
        guard before == after else { return nil }
        let keptValues: [String] = after.values.flatMap { [$0.value] + $0.qualifiers }
        let kept = Set(keptValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard let written = sourceValues(data), written.allSatisfy(kept.contains) else { return nil }
        return out
    }

    private struct Field: Equatable {
        let type: Int32
        let value: String
        let qualifiers: [String]
    }

    /// ImageIO 眼里的全部字段（递归到结构 / 数组里面）：路径 → 类型、值、限定符。
    private static func fields(_ meta: CGImageMetadata) -> [String: Field] {
        var out: [String: Field] = [:]
        let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, options) { path, tag in
            let tags = (CGImageMetadataTagCopyQualifiers(tag) as? [CGImageMetadataTag]) ?? []
            let qualifiers: [String] = tags.compactMap { CGImageMetadataTagCopyValue($0) as? String }
            let value = CGImageMetadataTagCopyValue(tag) as? String ?? ""
            out[path as String] = Field(type: CGImageMetadataTagGetType(tag).rawValue, value: value,
                                        qualifiers: qualifiers.sorted())
            return true
        }
        return out
    }

    /// 原文件里写着的每个值（属性值、元素文字），去掉 rdf / xmlns / x 这些骨架和要改的星级色标。
    /// 拿来查「重写之后还在不在」—— 比的是 fields() 里的值部分。
    private static func sourceValues(_ data: Data) -> Set<String>? {
        let collector = ValueCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), !collector.unsupported else { return nil }
        return collector.values
    }

    private final class ValueCollector: NSObject, XMLParserDelegate {
        var values = Set<String>()
        /// 用了 ImageIO 重写会变样的 RDF 写法（rdf:resource 的网址值会被写成普通文字、带语言的单值……）：
        /// 值还在，类型丢了，比对查不出来 —— 见到就整张不合并。
        var unsupported = false
        private var text = ""
        private static let plainRDF: Set<String> = ["rdf:about", "rdf:parseType"]
        private static let skeleton: Set<String> = ["xmlns", "x", "rdf", "xml"]

        private static func counts(_ qName: String) -> Bool {
            let parts = qName.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return qName != "xmlns" }
            if skeleton.contains(parts[0]) { return false }
            // 老 Adobe 软件把 xmp 命名空间写成 xap: 前缀。
            let basic = parts[0] == "xmp" || parts[0] == "xap"
            return !(basic && (parts[1] == "Rating" || parts[1] == "Label"))
        }

        private func add(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values.insert(value) }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            for (name, value) in attributeDict {
                if name.hasPrefix("rdf:") && !Self.plainRDF.contains(name) { unsupported = true }
                if name == "xml:lang" && elementName != "rdf:li" { unsupported = true }
                if Self.counts(name) { add(value) }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            // rdf:li 的文字算它外层那个属性的；外层若是星级 / 色标，值本来就会变，别算进来。
            if elementName == "rdf:li" || Self.counts(elementName) { add(text) }
            text = ""
        }
    }
}
