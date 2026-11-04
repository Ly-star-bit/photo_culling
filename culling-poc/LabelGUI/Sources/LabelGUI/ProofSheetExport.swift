import AppKit

// MARK: - 导出选片确认表：保存面板下面的「套餐含 N 张」

/// 保存面板下面那一行：「套餐含 [  ] 张 · 选超了只提示、不拦」。默认填这一场上次导出那张表的张数（每单的套餐不一样，
/// 不跨场次记）；空着 = 不限。
@MainActor
final class ProofSheetSaveAccessory {
    let view: NSView
    private let field: NSTextField

    init(quota: Int?) {
        let label = NSTextField(labelWithString: "套餐含")
        field = NSTextField(string: quota.map(String.init) ?? "")
        field.placeholderString = "不限"
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let unit = NSTextField(labelWithString: "张 · 客户选超了只提示、不拦（超出的算加片），空着 = 不限")
        unit.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, field, unit])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        view = row
    }

    /// 填的张数；没填、不是正整数 = nil（不限）。
    var quota: Int? { Self.parse(field.stringValue) }

    nonisolated static func parse(_ text: String) -> Int? {
        let digits = ClientReply.halfwidth(text).trimmingCharacters(in: .whitespaces)
        guard let n = Int(digits), n > 0 else { return nil }
        return min(n, 9999)
    }
}
