// 拼图门禁的比图小工具（collage_gate.sh 用；CI 不跑）：两张图解码成同一种 8 位 sRGB RGBA 位图，逐像素比字节。
//
//   imgdiff <A> <B> [--heat 差异图.png]   一模一样 → 打印 "same WxH"，退出 0
//                                          有差异   → "diff WxH px=N (p%) max=M bbox=x,y,w,h"，退出 1
//                                          尺寸不同 → "size WxH vs WxH"，退出 1；读不了 → 退出 2
//   imgdiff --make-sig <out.png>          画一张固定的签名 PNG（门禁里水印用，同一台机器上每次逐字节相同）
//
// 编译一次就够：swiftc -O Scripts/imgdiff.swift -o <某处>/imgdiff（门禁脚本发现没编译或源码更新了会自己编）。
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// 解码成 RGBA8（预乘、sRGB）。两张图都走同一条路，同一个文件解出来必然逐字节相同。
func pixels(_ path: String) -> (w: Int, h: Int, data: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = image.width
    let h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ok = data.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (w, h, data) : nil
}

func writePNG(_ image: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

/// 差异图：A 压暗成灰，差异像素标红（看哪儿变了，不用肉眼找）。
func heat(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int, to path: String) {
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for i in stride(from: 0, to: a.count, by: 4) {
        let same = a[i] == b[i] && a[i + 1] == b[i + 1] && a[i + 2] == b[i + 2] && a[i + 3] == b[i + 3]
        if same {
            let luma = (Int(a[i]) * 3 + Int(a[i + 1]) * 6 + Int(a[i + 2])) / 10
            let g = UInt8(luma / 3)
            out[i] = g
            out[i + 1] = g
            out[i + 2] = g
        } else {
            out[i] = 255
            out[i + 1] = 30
            out[i + 2] = 30
        }
        out[i + 3] = 255
    }
    out.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return }
        _ = writePNG(image, to: path)
    }
}

/// 固定的签名：透明底上一行深色字（水印「着色」会把它染成白的）。
func makeSignature(_ path: String) -> Bool {
    let w = 1200
    let h = 360
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 190, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Gate Sig", attributes: attrs))
    ctx.textPosition = CGPoint(x: 40, y: 110)
    CTLineDraw(line, ctx)
    // 一道下划的笔画，签名图常见的样子（也让平铺、着色有非字形的像素可比）。
    ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 60, y: 70))
    ctx.addCurve(to: CGPoint(x: 1120, y: 90), control1: CGPoint(x: 400, y: 10), control2: CGPoint(x: 800, y: 150))
    ctx.strokePath()
    guard let image = ctx.makeImage() else { return false }
    return writePNG(image, to: path)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--make-sig", args.count == 2 {
    exit(makeSignature(args[1]) ? 0 : 2)
}
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: imgdiff <A> <B> [--heat out.png] | imgdiff --make-sig out.png\n".data(using: .utf8)!)
    exit(2)
}
let heatPath = args.firstIndex(of: "--heat").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
guard let a = pixels(args[0]) else { print("unreadable \(args[0])"); exit(2) }
guard let b = pixels(args[1]) else { print("unreadable \(args[1])"); exit(2) }
guard a.w == b.w, a.h == b.h else {
    print("size \(a.w)x\(a.h) vs \(b.w)x\(b.h)")
    exit(1)
}
if a.data == b.data {
    print("same \(a.w)x\(a.h)")
    exit(0)
}
var count = 0
var maxDiff = 0
var x0 = a.w
var y0 = a.h
var x1 = -1
var y1 = -1
for y in 0..<a.h {
    for x in 0..<a.w {
        let i = (y * a.w + x) * 4
        var d = 0
        for k in 0..<4 { d = max(d, abs(Int(a.data[i + k]) - Int(b.data[i + k]))) }
        guard d > 0 else { continue }
        count += 1
        maxDiff = max(maxDiff, d)
        x0 = min(x0, x)
        y0 = min(y0, y)
        x1 = max(x1, x)
        y1 = max(y1, y)
    }
}
let percent: Double = 100 * Double(count) / Double(a.w * a.h)
print(String(format: "diff %dx%d px=%d (%.4f%%) max=%d bbox=%d,%d,%d,%d", a.w, a.h, count, percent, maxDiff,
             x0, y0, x1 - x0 + 1, y1 - y0 + 1))
if let heatPath { heat(a.data, b.data, w: a.w, h: a.h, to: heatPath) }
exit(1)
