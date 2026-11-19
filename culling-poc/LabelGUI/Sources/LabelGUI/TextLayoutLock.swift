import Foundation
import CoreText

/// 排字（建 CTLine / CTFramesetter / 排 CTFrame / 截断）全进程一次只排一个。
///
/// PP-01 查出来的 CoreText 竞态：几个线程同时第一次拿某个字号排字时，CoreText 有时排出来窄 3%，而且这个字号在整个进程里
/// 一直窄（8 个线程同时量默认 EXIF 那一行，10 个进程里 8 个量窄；锁住建 CTLine 这一下 16 个进程全对）。水印批量先锁上了；
/// v1.33.0 相册整本导出改成同时渲 2–3 个跨页（PP-03）以后，拼图的标题 / 正文 / 联系表 / 书脊也会几路同时第一次排同一个
/// 导出字号（屏幕预览没排过这个字号），同样要锁（发版前审查查出来的）。只锁建排版对象这几下（微秒到毫秒），画字不锁。
/// 递归锁：锁里再套一层（建 frame 的参数里现建 framesetter）不死锁。
enum TextLayoutLock {
    private static let lock = NSRecursiveLock()

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func line(_ string: CFAttributedString) -> CTLine {
        run { CTLineCreateWithAttributedString(string) }
    }

    static func framesetter(_ string: CFAttributedString) -> CTFramesetter {
        run { CTFramesetterCreateWithAttributedString(string) }
    }

    static func frame(_ setter: CTFramesetter, _ range: CFRange, _ path: CGPath, _ attributes: CFDictionary?) -> CTFrame {
        run { CTFramesetterCreateFrame(setter, range, path, attributes) }
    }

    static func suggestSize(_ setter: CTFramesetter, _ range: CFRange, _ attributes: CFDictionary?, _ constraints: CGSize,
                            _ fitRange: UnsafeMutablePointer<CFRange>?) -> CGSize {
        run { CTFramesetterSuggestFrameSizeWithConstraints(setter, range, attributes, constraints, fitRange) }
    }

    static func truncated(_ line: CTLine, _ width: Double, _ type: CTLineTruncationType, _ token: CTLine?) -> CTLine? {
        run { CTLineCreateTruncatedLine(line, width, type, token) }
    }
}
