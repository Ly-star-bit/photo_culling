import SwiftUI
import AppKit

// MARK: - 看单张 / 审片的放大：翻页保持放大（UX-01 / 11-04 审查 F16）

/// 看单张（PhotoInspector）、审片（ReviewView）共用的放大状态。以前两边各一份，翻一张就 `zoomed = false`：逐张查焦点
/// 每张都要再按 Z、再等一次整幅解码（40 MP 约 1 秒）。现在：
/// - 放大开着时翻页不退出。翻到的那张先显示适应窗口的图 +「解码原图…」，原图解出来按同一个倍数、离主脸同样的偏移进放大
///   （ZoomLink 记着最近一次的倍率和偏移，和连拍挑选几格联动同一个东西；照片里有主脸就以主脸为准，没有就以图中心）。
/// - 开着时预解「接着要翻到的那一张」的原图（按上一次翻的方向），解好的自己拿着（`ahead`）：FullResCache 是 NSCache，
///   放进第三张时扔掉哪张不一定（实测扔过刚预解好的那张），靠它就成了碰运气。手里最多两张：这一张 + 下一张。
/// - 翻得快不排一串整幅解码：翻到以后等一拍（`settle`）还停在这张才解；预解等这一张解完才开始。同一张只解一份
///   （FullResCache.image：预解还没完就翻到了，等那一份）。
/// - 原图没回来时按 1 / 2 / 3 判的就是这一张：解好的图带着路径，只给那一张用，翻走了就不拿出来。
/// 是 11-04 F16 说的「锁定放大」，但不另加一个锁定键：开着放大翻页就是保持，想看全图按 Z / Esc 退出（分析员的取舍，见
/// 优化分析 2026-11-18 UX-01）。
@MainActor
final class ViewerZoom: ObservableObject {
    /// 放大开着（Z / 双击 / 捏合 进来，还没退出）。原图还没解出来时也算开着：先显示适应窗口的图。
    @Published private(set) var on = false
    /// 解好的原图，带路径：只给这一张用。
    @Published private(set) var full: (path: String, image: NSImage)?
    /// 解不出来的那张（坏文件）：不当成「还在解」。
    @Published private(set) var failed: String?
    /// 怎么进的放大：Z / 双击直接 100%，捏合 = 适应 × 捏合的倍数。翻页沿用（倍率另外由 link 带过去）。
    private(set) var entry: ZoomPane.Entry = .hundred
    /// 几张之间沿用倍率和离主脸的偏移。退出放大时清掉，下次进来从头开始。
    let link = ZoomLink()
    /// 现在要的那张、接着要预解的那张（路径）。
    private(set) var wanted: String?
    private(set) var next: String?
    /// 预解好的下一张（翻到它时直接用）。换了方向、不再是接下来要的就放掉。
    private var ahead: (path: String, image: NSImage)?
    /// 预解好的是哪张（--viewer-zoom-selftest 看）。
    var aheadPath: String? { ahead?.path }
    /// 预解在路上（无头 --press 等它）。
    private(set) var prefetching: String?

    /// 翻到以后等多久还停在这张才去解原图（按住 → 一路翻过去的那些不解）。
    static let settle: Duration = .milliseconds(120)

    /// 这张解好的原图；没好、或者手里的是别的照片的 = nil。
    func image(for path: String) -> NSImage? {
        guard let full, full.path == path else { return nil }
        return full.image
    }

    /// 开着、这张的原图还没好（显示适应窗口的图 +「解码原图…」）。
    func loading(_ path: String) -> Bool {
        on && full?.path != path && failed != path
    }

    /// Z / 按钮：开 ↔ 关。`next` = 接着可能翻到的那张（预解它）。
    func toggle(path: String, next: String?, entry: ZoomPane.Entry = .hundred) {
        if on {
            off()
        } else {
            enter(path: path, next: next, entry: entry)
        }
    }

    /// 双击 / 捏合：只开不关（开着、原图还在解时再双击一下不该把放大关掉）。
    func enter(path: String, next: String?, entry: ZoomPane.Entry) {
        guard !on else { return }
        self.entry = entry
        on = true
        show(path, next: next)
    }

    func off() {
        on = false
        link.reset()
        wanted = nil
        full = nil
        ahead = nil
        failed = nil
    }

    /// 翻到这一张（开着才解）：解它的原图，解好再预解 `next`。关着时什么都不做（预取适应窗口那一档的事归 FitCache）。
    func show(_ path: String?, next: String?) {
        self.next = next
        guard on, let path else { return }
        wanted = path
        if full?.path != path { full = nil }  // 上一张的整幅马上放掉，不在内存里多压一张
        if let ahead, ahead.path == path {
            full = ahead
            self.ahead = nil
        } else if full == nil, let hit = FullResCache.cache.object(forKey: path as NSString) {
            full = (path, hit)
        }
        if ahead?.path != next { ahead = nil }  // 预解的不是接下来要翻到的了（换了方向）
        if full != nil {
            prefetchNext()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.settle)
            guard on, wanted == path else { return }
            let image = await FullResCache.image(path: path).value
            guard on, wanted == path else { return }
            if let image {
                full = (path, image)
            } else {
                failed = path
            }
            prefetchNext()
        }
    }

    /// 预解接着要翻到的那张（解进 FullResCache，翻到时直接命中）。
    private func prefetchNext() {
        guard on, let target = next, target != wanted, ahead?.path != target else { return }
        if let hit = FullResCache.cache.object(forKey: target as NSString) {
            ahead = (target, hit)
            return
        }
        prefetching = target
        Task { @MainActor in
            try? await Task.sleep(for: Self.settle)
            if on, next == target {
                let image = await FullResCache.image(path: target, priority: .utility).value
                if on, next == target, let image { ahead = (target, image) }
            }
            if prefetching == target { prefetching = nil }
        }
    }

    /// 无头 --press 等它：开着时这张解完（或解不出）、预解也完了才算停下来。
    var settled: Bool {
        guard on, let wanted else { return true }
        return (full?.path == wanted || failed == wanted) && prefetching == nil
    }

    /// 进放大时落在哪：主脸中心（归一化、左上原点，和 ZoomPane.anchor 一样）；没脸 = nil（图中心）。
    static func faceAnchor(_ faceBbox: [Double]?) -> CGPoint? {
        guard let b = faceBbox, b.count == 4 else { return nil }
        return CGPoint(x: (b[0] + b[2]) / 2, y: (b[1] + b[3]) / 2)
    }

    /// 无头打印用：「原图 5152×7728」「下一张原图 已解好」。
    func summary(for path: String?) -> String {
        let shown: String
        if let path, let image = image(for: path) {
            shown = "\(Int(image.size.width))×\(Int(image.size.height))"
        } else if let path, failed == path {
            shown = "解不出"
        } else {
            shown = "无"
        }
        let state = on ? (path.map { loading($0) } == true ? "开（解码中）" : "开") : "关"
        var text = "放大 \(state) · 原图 \(shown)"
        if on, let next {
            let name = URL(fileURLWithPath: next).deletingPathExtension().lastPathComponent
            text += " · 下一张 \(name) 原图\(ahead?.path == next ? "已解好" : "没解")"
        }
        return text
    }
}

/// 放大开着、原图还在解时盖在适应窗口那张图上的小牌子。
struct ViewerDecodingBadge: View {
    var body: some View {
        Label("解码原图…", systemImage: "hourglass")
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.black.opacity(0.7), in: Capsule())
            .foregroundStyle(Color.white)
            .padding(12)
            .allowsHitTesting(false)
    }
}
