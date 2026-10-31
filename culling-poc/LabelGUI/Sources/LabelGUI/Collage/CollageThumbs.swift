import AppKit
import SwiftUI

// 拼图页的图片状态（预览大图、各种缩略图）各自成一个小对象，只有显示它们的那一小块界面订阅。
// 以前它们都是 CollageStore 的 @Published：预览重渲一次、几十个模板缩略图每渲好一张，整个拼图页
// （托盘、画布叠加层、检视器、几十个模板格子）都跟着重算一遍。store 上留着同名的只读属性
// （preview、templateThumbs……），命令行、实时桥照旧按名字读。

/// 画布的预览大图。
@MainActor
final class CollagePreviewState: ObservableObject {
    @Published var image: NSImage?
    /// 预览图对应的画布缩放（预览像素 / 成品像素）。
    @Published var scale: Double = 0.5
}

/// 各种缩略图：跨页条、模板库、风格预设、色调样张。
@MainActor
final class CollageThumbs: ObservableObject {
    /// 相册跨页条（按页 id）。
    @Published var pages: [UUID: NSImage] = [:]
    /// 模板库（按模板名）。
    @Published var templates: [String: NSImage] = [:]
    /// 风格预设样张（按预设 key）。
    @Published var styles: [String: NSImage] = [:]
    /// 色调样张。
    @Published var looks: [CollageLook: NSImage] = [:]
}

/// 画布叠加层每一格的角标（锁、切脸、路人、印刷放大倍数）。store 按工程、选中、路人信息和蒙版的版本缓存：
/// 悬停到缝上、拖照片经过画布时叠加层重算，不再每一格重新取景。
struct CollageCanvasBadge: Equatable {
    var locked = false
    var cutsFace = false
    var bystander = false
    /// 印刷画布上放大超过上限的倍数（没超就是 nil）。
    var upscale: Double?

    var isEmpty: Bool { !locked && !cutsFace && !bystander && upscale == nil }
}
