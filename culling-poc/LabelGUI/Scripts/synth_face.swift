// 带人脸的合成图（native_analysis_smoke.py 的「分析可重复」那一段用）：灰底上画一个 Apple Color Emoji 的人物 emoji，存成 JPEG。
// Vision 认得出其中大部分人物 emoji 的脸（600pt、1500×1000 上：🧑 👨 👴 👩🏻 👩🏼 …，😀 这种黄脸认不出），而且正好卡在
// 人脸质量请求「有时用 landmarks 的框、有时用自己检测的」那条线上 —— 分析版本 3 以前，同一张图两次分析的 face_quality
// 经常不一样（VQ-04）。仓库里不放照片（个人照片、也不放 emoji 的渲染图），所以跑测试时现场画。
//
//   synth_face <out.jpg> <emoji> [字号 pt，默认 600]
//
// 编译：swiftc Scripts/synth_face.swift -o <某处>/synth_face（smoke 脚本自己编进它的临时目录）。
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: synth_face <out.jpg> <emoji> [字号 pt]")
    exit(2)
}
let size = args.count > 3 ? CGFloat(Double(args[3]) ?? 600) : 600
let width = 1500, height = 1000
guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setFillColor(CGColor(red: 0.55, green: 0.6, blue: 0.65, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

let font = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: args[2], attributes: attrs))
// 按字形的实际外框居中（emoji 的 ascent / descent 和画出来的图不一样大）。
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let x = (CGFloat(width) - bounds.width) / 2 - bounds.minX
let y = (CGFloat(height) - bounds.height) / 2 - bounds.minY
ctx.textPosition = CGPoint(x: x, y: y)
CTLineDraw(line, ctx)

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL,
                                                 UTType.jpeg.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
