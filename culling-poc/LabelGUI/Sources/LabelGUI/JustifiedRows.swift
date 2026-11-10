import Foundation
import CoreGraphics
import ImageIO

// MARK: - 网格按照片比例排满一行
//
// 以前每张照片放进一个固定的方格里整图 fit：竖片只占格子宽度的四成，两边是灰底，1440 宽的窗口一排 7 格、真正的照片面积不到
// 一半。现在一行里每张按自己的宽高比给宽度、同一行一样高，整行正好排满（Aftershoot / Narrative 的网格、Flickr 的
// justified 排法）：行高在缩略图滑杆定的目标附近浮动，最后一行不拉伸、靠左。
//
// 这里是纯算法（--ux-selftest 直接测）：怎么分行、↑ ↓ 落到哪一张。画在 BatchView。

enum JustifiedRows {
    struct Row: Equatable {
        /// 这一行是 aspects 里的哪一段。
        let range: Range<Int>
        let height: CGFloat
        /// 每张的宽度（和 range 一一对应）。
        let widths: [CGFloat]
    }

    static let spacing: CGFloat = 6
    /// 排版用的宽高比夹在这个范围里：全景、长条截图不会一张占掉三行的宽度或者窄成一根线（格子里照样整图显示）。
    static let aspectRange: ClosedRange<CGFloat> = 0.5...2.4
    /// 一行最高到目标的多少倍（一行只放得下一两张横片时别撑成巨幅）。
    static let maxStretch: CGFloat = 1.35

    static func clamped(_ aspect: CGFloat) -> CGFloat {
        guard aspect.isFinite, aspect > 0 else { return 1.5 }
        return min(aspectRange.upperBound, max(aspectRange.lowerBound, aspect))
    }

    /// 分行。`aspects` = 宽 / 高，`width` = 一行能用的宽度，`target` = 想要的行高。
    static func pack(aspects raw: [CGFloat], width: CGFloat, target: CGFloat, spacing: CGFloat = spacing) -> [Row] {
        guard !raw.isEmpty, width > 1, target > 1 else { return [] }
        let aspects = raw.map(clamped)
        var rows: [Row] = []
        var start = 0
        var sum: CGFloat = 0

        /// 这一段正好排满时的行高。
        func fitHeight(_ count: Int, _ aspectSum: CGFloat) -> CGFloat {
            (width - spacing * CGFloat(count - 1)) / aspectSum
        }
        func emit(_ range: Range<Int>, _ height: CGFloat) {
            rows.append(Row(range: range, height: height, widths: aspects[range].map { $0 * height }))
        }

        var i = 0
        while i < aspects.count {
            sum += aspects[i]
            let count = i - start + 1
            let natural = sum * target + spacing * CGFloat(count - 1)
            if natural >= width {
                // 带上这一张（行会矮一点）还是不带（行会高一点）：哪个离目标近用哪个；不带会高过头就带上。
                let with = fitHeight(count, sum)
                var take = count
                var height = with
                if count > 1 {
                    let without = fitHeight(count - 1, sum - aspects[i])
                    // 偏向矮的那一边（× 1.3）：行高忽高忽低里，突然高出一截的那一行最扎眼。
                    if without <= target * maxStretch, abs(log(without / target)) * 1.3 < abs(log(with / target)) {
                        take = count - 1
                        height = without
                    }
                }
                emit(start..<(start + take), min(height, target * maxStretch))
                start += take
                sum = take == count ? 0 : aspects[i]
                // 没带上的那一张自己就比一行宽（窗口很窄）：单独一行。
                if take != count, aspects[i] * target >= width {
                    emit(start..<(start + 1), min(fitHeight(1, aspects[i]), target * maxStretch))
                    start += 1
                    sum = 0
                }
            }
            i += 1
        }
        if start < aspects.count {
            // 最后一行不拉伸、靠左。
            emit(start..<aspects.count, target)
        }
        return rows
    }

    // MARK: ↑ ↓

    /// 一格在行里的位置（中点的 x）。
    struct Cell: Equatable {
        let id: String
        let mid: CGFloat
    }

    /// 一行的格子（带中点）。
    static func cells(ids: [String], row: Row, spacing: CGFloat = spacing) -> [Cell] {
        var x: CGFloat = 0
        var out: [Cell] = []
        for (k, width) in row.widths.enumerated() {
            out.append(Cell(id: ids[row.range.lowerBound + k], mid: x + width / 2))
            x += width + spacing
        }
        return out
    }

    /// ↑（-1）/ ↓（+1）：上一行 / 下一行里中点离现在这张最近的那一张。在第一行按 ↑、最后一行按 ↓ = nil（不动）。
    /// 现在这张不在任何一行里（没有焦点、被筛掉了）= 第一张。
    static func vertical(rows: [[Cell]], from current: String?, direction: Int) -> String? {
        guard let first = rows.first?.first else { return nil }
        guard let current else { return first.id }
        for (r, row) in rows.enumerated() {
            guard let here = row.first(where: { $0.id == current }) else { continue }
            let next = r + direction
            guard rows.indices.contains(next) else { return nil }
            return rows[next].min { abs($0.mid - here.mid) < abs($1.mid - here.mid) }?.id
        }
        return first.id
    }
}

// MARK: - 照片的宽高比

/// 预览图的宽 / 高：只读文件头（不解码，约 0.1 ms 一张），按路径记住；预览重写了（ThumbCache.invalidate）就忘掉重读。
/// 分行要用到一个分区里每一张的比例：几百张的场次第一次排版时当场读完；几千张的大场次先按 2:3 排、后台读完再排一次
/// （BatchView.aspects），不在主线程上卡半秒。
enum PhotoAspect {
    private final class Book: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: CGFloat] = [:]

        func get(_ path: String) -> CGFloat? {
            lock.lock(); defer { lock.unlock() }
            return known[path]
        }

        func set(_ path: String, _ value: CGFloat) {
            lock.lock(); defer { lock.unlock() }
            known[path] = value
        }

        func forget(_ paths: [String]) {
            lock.lock(); defer { lock.unlock() }
            for path in paths { known[path] = nil }
        }
    }
    private static let book = Book()

    /// 读不出来（文件没了）、还没读到时用的：竖拍 2:3。不记，下次再读。
    static let fallback: CGFloat = 2.0 / 3.0

    /// 读过的（不碰文件）。nil = 还没读过。
    static func known(path: String) -> CGFloat? { book.get(path) }

    /// 没读过就当场读文件头。
    static func of(path: String) -> CGFloat {
        if let hit = book.get(path) { return hit }
        guard let aspect = read(path: path) else { return fallback }
        book.set(path, aspect)
        return aspect
    }

    /// 这些预览重写过了：下次重读。
    static func forget(_ paths: [String]) { book.forget(paths) }

    /// 文件头里的像素尺寸，带 EXIF 方向（5–8 是转了 90° 的）。
    static func read(path: String) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGFloat(h / w) : CGFloat(w / h)
    }
}
