// 带人脸的合成图（native_analysis_smoke.py 的「分析可重复」那一段用）：灰底上画一个 Apple Color Emoji 的人物 emoji，存成 JPEG。
// Vision 认得出其中大部分人物 emoji 的脸（600pt、1500×1000 上：🧑 👨 👴 👩🏻 👩🏼 …，😀 这种黄脸认不出），而且正好卡在
// 人脸质量请求「有时用 landmarks 的框、有时用自己检测的」那条线上 —— 分析版本 3 以前，同一张图两次分析的 face_quality
// 经常不一样（VQ-04）。仓库里不放照片（个人照片、也不放 emoji 的渲染图），所以跑测试时现场画。
//
//   synth_face <out.jpg> <emoji> [字号 pt，默认 600] [eyes|mouth|none] [转多少度]
//
// 第 4 个参数（第 6 段「锐度只看眼眉带」用）：画完在图上跑一遍 landmarks，按 app 的口径（FaceAnalyzer.featureRects：两眼 + 两眉 /
// 外唇）找到那一块，四周再放出半块，只把这块高斯糊掉 —— 模拟前焦（眼睛糊、嘴清楚）和反过来。没认出脸退出码 3。none = 不糊。
// 第 5 个参数（第 7 段「歪头的 EAR」用）：emoji 绕画面中心逆时针转这么多度再画（歪头）。
//
// 编译：swiftc Scripts/synth_face.swift -o <某处>/synth_face（smoke 脚本自己编进它的临时目录）。
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: synth_face <out.jpg> <emoji> [字号 pt] [eyes|mouth|none] [转多少度]")
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
// 转的时候绕画面中心：先把原点挪到中心、转，再按字形外框居中画。
let degrees = args.count > 5 ? Double(args[5]) ?? 0 : 0
ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
ctx.rotate(by: CGFloat(degrees * .pi / 180))
ctx.textPosition = CGPoint(x: -bounds.width / 2 - bounds.minX, y: -bounds.height / 2 - bounds.minY)
CTLineDraw(line, ctx)

guard var image = ctx.makeImage() else { exit(1) }

if args.count > 4, args[4] == "eyes" || args[4] == "mouth" {
    let request = VNDetectFaceLandmarksRequest()
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    func area(_ f: VNFaceObservation) -> CGFloat { f.boundingBox.width * f.boundingBox.height }
    guard let face = request.results?.max(by: { area($0) < area($1) }), let lm = face.landmarks else {
        print("没认出脸")
        exit(3)
    }
    let regions: [VNFaceLandmarkRegion2D?]
    if args[4] == "eyes" {
        regions = [lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow]
    } else {
        regions = [lm.outerLips]
    }
    // pointsInImage 和 Core Image 一样是左下原点。
    let imageSize = CGSize(width: width, height: height)
    var points: [CGPoint] = []
    for region in regions {
        if let region { points += region.pointsInImage(imageSize: imageSize) }
    }
    guard points.count >= 4 else { exit(3) }
    let xs = points.map(\.x), ys = points.map(\.y)
    let tight = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    let blurRect = tight.insetBy(dx: -tight.width * 0.5, dy: -tight.height * 0.5)
    let source = CIImage(cgImage: image)
    let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: blurRect)
    guard let out = CIContext().createCGImage(blurred.composited(over: source), from: source.extent) else { exit(1) }
    image = out
}

guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL,
                                                 UTType.jpeg.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
