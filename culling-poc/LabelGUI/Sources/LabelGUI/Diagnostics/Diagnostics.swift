import Foundation

// MARK: - 诊断（全项目审查 D03）
//
// 逐张失败的原因翻成中文（导出 JPG、移到废纸篓、写 XMP、水印页）：在 CardImporter.describe 之前先认它不认的几种
// —— 盘不支持废纸篓、只读盘、EPERM（文件被锁定或者系统隐私权限）—— 其余照旧交给它。

enum Diagnostics {
    // MARK: 失败原因

    /// 给人看的 I/O 失败原因。`trash`：移到废纸篓那一路（「不支持」说成「这块盘不支持废纸篓」并给办法）。
    nonisolated static func describeIO(_ error: Error, trash: Bool = false) -> String {
        let ns = error as NSError
        let posix = CardImporter.posixCode(error)
        let cocoa = ns.domain == NSCocoaErrorDomain ? ns.code : nil
        if cocoa == NSFeatureUnsupportedError || (trash && posix == ENOTSUP) {
            return trash ? "这块盘不支持废纸篓（网络盘、部分外接盘）：在访达里手动删，或者先拷到本机再移"
                : "这块盘 / 共享不支持这个操作"
        }
        if posix == EROFS || cocoa == NSFileWriteVolumeReadOnlyError {
            return "盘是只读的（存储卡的写保护开关、只读的网络共享）"
        }
        if posix == EPERM {
            return "没有权限（文件被锁定，或者系统隐私权限不让访问：系统设置 › 隐私与安全性 › 文件与文件夹）"
        }
        if posix == EDQUOT { return "盘满了（超出配额）" }
        return CardImporter.describe(error)
    }

    /// 收尾消息后面那一截：「；原因：没有权限」，几种不同的就「；原因：没有权限（3 张）、盘满了（1 张）」。没有 = ""。
    nonisolated static func reasonSummary(_ reasons: [String], unit: String = "张") -> String {
        var counts: [(reason: String, count: Int)] = []
        for reason in reasons {
            if let i = counts.firstIndex(where: { $0.reason == reason }) {
                counts[i].count += 1
            } else {
                counts.append((reason, 1))
            }
        }
        guard let first = counts.first else { return "" }
        if counts.count == 1 { return "；原因：" + first.reason }
        let shown = counts.prefix(3).map { "\($0.reason)（\($0.count) \(unit)）" }.joined(separator: "、")
        let more = counts.count > 3 ? "…" : ""
        return "；原因：" + shown + more
    }
}
