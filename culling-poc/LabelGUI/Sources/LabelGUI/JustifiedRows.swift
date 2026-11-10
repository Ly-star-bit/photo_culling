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

// MARK: - 分行结果缓存

/// 分行结果按「分区、照片 id 序列、行宽、目标行高、比例的版本」记住（优化分析 2026-11-10 R3）。以前每按一下方向键，批量页
/// body、↑↓ 的行表、滚动定位各把整场重新分行一遍（7980 张时一下 2–3 遍），而焦点挪一格分行结果根本没变。
/// 只记排版（哪几张一行、各多宽）：照片本身（判决、角标）每次从现在的 items 里按下标取。
@MainActor
final class GridLayoutCache {
    struct Key: Hashable {
        var width: CGFloat
        var target: CGFloat
        /// BatchView.aspectEpoch：后台读完了大场次的比例。
        var epoch: Int
        /// PhotoAspect.generation：预览重写过、读失败的重试过。
        var generation: Int
    }

    final class Section {
        let ids: [String]
        let rows: [JustifiedRows.Row]
        /// 「分区-第几行」：滚动定位的目标。
        let rowIDs: [String]
        /// ↑ ↓ 用的格子中点，用到才算。
        private(set) lazy var cells: [[JustifiedRows.Cell]] = rows.map { JustifiedRows.cells(ids: ids, row: $0) }

        init(prefix: String, ids: [String], rows: [JustifiedRows.Row]) {
            self.ids = ids
            self.rows = rows
            rowIDs = rows.indices.map { "\(prefix)-\($0)" }
        }
    }

    private var key: Key?
    private var sections: [String: Section] = [:]
    /// 真分了几次行（自检数这个）。
    private(set) var packs = 0

    /// 这个分区的分行。键（行宽、行高、比例版本）和 id 序列都没变就是上次那份；`aspects` 只在要重新分行时才调。
    func section(prefix: String, ids: [String], key: Key, aspects: () -> [CGFloat]) -> Section {
        if self.key != key || sections.count > 4096 {
            sections.removeAll(keepingCapacity: true)
            self.key = key
        }
        if let hit = sections[prefix], hit.ids == ids { return hit }
        packs += 1
        let rows = JustifiedRows.pack(aspects: aspects(), width: key.width, target: key.target)
        let made = Section(prefix: prefix, ids: ids, rows: rows)
        sections[prefix] = made
        return made
    }
}

// MARK: - 照片的宽高比

/// 预览图的宽 / 高：只读文件头（不解码，约 0.1 ms 一张），按路径记住；预览重写了（ThumbCache.invalidate）就忘掉重读。
/// 分行要用到一个分区里每一张的比例：几百张的场次第一次排版时当场读完；几千张的大场次先按 2:3 排、后台读完再排一次
/// （BatchView.aspects），不在主线程上卡半秒。
///
/// 读不出来的（预览被清掉的旧场次、文件坏了）也记一笔「试过」：以前不记，每次排版都把它当「没读过」——不到 600 张时每次
/// 重算都在主线程上把读不出的文件再读一遍；超过 600 张时后台读一遍全失败 → 加一次重排 → 还是「没读过」→ 再读，网格在后台
/// 空转到「重新分析」跑完为止（优化分析 2026-11-10 R1 / R2）。「试过」和读到的一起忘（forget）；任务跑完以后 BatchView 再给
/// 读失败的一次机会（retryFailed）。
///
/// 读文件头用的是 WatermarkEngine.uprightSize（FitCache.header 也是它）：编码宽高 + EXIF 方向 5–8 时交换，一份实现。
/// 表不和 FitCache 并：那边按原图路径记、还带是不是 JPEG，这边按预览路径记、要一把锁批量取、要记「试过」。
enum PhotoAspect {
    private final class Book: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: CGFloat] = [:]
        /// 读过、没读出来的。
        private var failed: Set<String> = []
        /// forget / retryFailed 一次加一：同一条路径的比例可能变了，按它缓存的分行结果作废。
        private var generation = 0

        func get(_ path: String) -> CGFloat? {
            lock.lock(); defer { lock.unlock() }
            return known[path]
        }

        func tried(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return known[path] != nil || failed.contains(path)
        }

        /// 一把锁查一批：读到的比例（没读到 = nil）、其中一次都没试过的下标。
        func lookup(_ paths: [String]) -> (aspects: [CGFloat?], untried: [Int]) {
            lock.lock(); defer { lock.unlock() }
            var aspects: [CGFloat?] = []
            aspects.reserveCapacity(paths.count)
            var untried: [Int] = []
            for (index, path) in paths.enumerated() {
                let hit = known[path]
                aspects.append(hit)
                if hit == nil, !failed.contains(path) { untried.append(index) }
            }
            return (aspects, untried)
        }

        /// 一把锁记一批（nil = 读过、没读出来）。返回这一批里新学到了几张的比例。
        @discardableResult
        func record(_ results: [(path: String, aspect: CGFloat?)]) -> Int {
            lock.lock(); defer { lock.unlock() }
            var learned = 0
            for (path, aspect) in results {
                if let aspect {
                    if known[path] == nil { learned += 1 }
                    known[path] = aspect
                    failed.remove(path)
                } else if known[path] == nil {
                    failed.insert(path)
                }
            }
            return learned
        }

        func forget(_ paths: [String]) {
            lock.lock(); defer { lock.unlock() }
            for path in paths {
                known[path] = nil
                failed.remove(path)
            }
            generation += 1
        }

        func retryFailed() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !failed.isEmpty else { return false }
            failed.removeAll()
            generation += 1
            return true
        }

        func currentGeneration() -> Int {
            lock.lock(); defer { lock.unlock() }
            return generation
        }
    }
    private static let book = Book()

    /// 读不出来（文件没了）、还没读到时用的：竖拍 2:3。
    static let fallback: CGFloat = 2.0 / 3.0

    /// 读到的（不碰文件）。nil = 还没读过，或者读过、没读出来。
    static func known(path: String) -> CGFloat? { book.get(path) }

    /// 读过了（读到了，或者试过、没读出来）：不会再碰文件，直到 forget / retryFailed。
    static func tried(path: String) -> Bool { book.tried(path) }

    /// 同一条路径的比例可能变过几回（forget、retryFailed 各加一）：分行缓存的键。
    static var generation: Int { book.currentGeneration() }

    /// 没读过就当场读文件头；读不出来 = fallback，记一笔「试过」（下次不再读）。
    static func of(path: String) -> CGFloat {
        let (aspects, untried) = book.lookup([path])
        if let hit = aspects[0] { return hit }
        guard !untried.isEmpty else { return fallback }
        let aspect = read(path: path)
        book.record([(path, aspect)])
        return aspect ?? fallback
    }

    /// 一批路径各读过没有（一把锁，不碰文件）：读到的比例（没有 = nil）、一次都没试过的下标。
    static func lookup(paths: [String]) -> (aspects: [CGFloat?], untried: [Int]) { book.lookup(paths) }

    /// 把这一批里没试过的读掉（当场读文件头），返回新学到了几张的比例 —— 0 = 再排一次也是原样，不用重排。
    @discardableResult
    static func warm(paths: [String]) -> Int {
        let untried = book.lookup(paths).untried
        guard !untried.isEmpty else { return 0 }
        return book.record(untried.map { (paths[$0], read(path: paths[$0])) })
    }

    /// 这一批的比例（读不出来的 = fallback）：没试过的当场读掉。
    static func resolve(paths: [String]) -> [CGFloat] {
        let first = book.lookup(paths)
        guard !first.untried.isEmpty else { return first.aspects.map { $0 ?? fallback } }
        var aspects = first.aspects
        var results: [(path: String, aspect: CGFloat?)] = []
        results.reserveCapacity(first.untried.count)
        for index in first.untried {
            let aspect = read(path: paths[index])
            aspects[index] = aspect
            results.append((paths[index], aspect))
        }
        book.record(results)
        return aspects.map { $0 ?? fallback }
    }

    /// 这些预览重写过了：下次重读（「试过、没读出来」的记号一起清）。
    static func forget(_ paths: [String]) { book.forget(paths) }

    /// 读失败的再给一次机会（分析 / 导入跑完以后：预览可能补回来了）。返回有没有可重试的。
    @discardableResult
    static func retryFailed() -> Bool { book.retryFailed() }

    /// 文件头里的像素尺寸，带 EXIF 方向（5–8 是转了 90° 的）。
    static func read(path: String) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let size = WatermarkEngine.uprightSize(of: source), size.width > 0, size.height > 0 else { return nil }
        return CGFloat(size.width) / CGFloat(size.height)
    }
}
