import Foundation

/// Native ports of layer1.py's numeric metrics. Same algorithms, same semantics:
/// - Laplacian variance for sharpness (higher = sharper)
/// - Exposure clipping: fraction of pixels where EVERY channel is blown/crushed
///   (a saturated red flower is not "blown"; washed-out white is). Also over the
///   subject region only (faces → head + upper body), plus luminance percentiles
///   for the 欠曝 / 过曝 call
/// - DCT perceptual hash for burst/duplicate grouping (same construction as
///   Python's imagehash.phash: 32x32 grayscale → 2D DCT-II → top-left 8x8 vs median)
enum Metrics {
    // MARK: - Grayscale

    /// OpenCV RGB2GRAY coefficients, matching what the Python layer measured with.
    /// Reads stride-4 RGBA directly; unsafe pointers keep the hot loop free of
    /// per-access bounds checks.
    static func grayscale(rgba: [UInt8], width: Int, height: Int) -> [Float] {
        let n = width * height
        var gray = [Float](repeating: 0, count: n)
        rgba.withUnsafeBufferPointer { src in
            gray.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    let r = Float(src[i * 4])
                    let g = Float(src[i * 4 + 1])
                    let b = Float(src[i * 4 + 2])
                    dst[i] = 0.299 * r + 0.587 * g + 0.114 * b
                }
            }
        }
        return gray
    }

    // MARK: - Sharpness

    /// RMS Sobel gradient magnitude (Tenengrad family) over the region, after a
    /// 3×3 Gaussian smoothing pass. Two deliberate departures from the Laplacian
    /// variance the Python layer used (cv2.Laplacian(gray).var()):
    /// - Sobel's first-derivative response degrades gracefully under sensor
    ///   noise, where the Laplacian's second derivative amplifies it — high-ISO
    ///   grain read as "sharpness" was the whole complaint.
    /// - The Gaussian pre-blur kills single-pixel ISO speckle outright; on a
    ///   feature-sized ROI its cost is invisible.
    /// sqrt of the mean keeps values in a slider-friendly range instead of raw
    /// squared-gradient millions. NOT comparable to Laplacian-variance numbers
    /// (253-647 on the same photos); this scale is what analysisVersion pins.
    static func tenengrad(gray: [Float], width: Int, height: Int,
                          x0: Int = 0, y0: Int = 0, x1: Int? = nil, y1: Int? = nil) -> Double {
        let xEnd = min(width, x1 ?? width)
        let yEnd = min(height, y1 ?? height)
        // Copy the region plus a 2px apron so blur + Sobel taps near the region
        // edge read real pixels, not padding.
        let rx0 = max(0, x0 - 2), ry0 = max(0, y0 - 2)
        let rx1 = min(width, xEnd + 2), ry1 = min(height, yEnd + 2)
        let rw = rx1 - rx0, rh = ry1 - ry0
        guard rw >= 5, rh >= 5 else { return 0 }

        var buf = [Float](repeating: 0, count: rw * rh)
        gray.withUnsafeBufferPointer { src in
            buf.withUnsafeMutableBufferPointer { dst in
                for y in 0..<rh {
                    let srcRow = (ry0 + y) * width + rx0
                    let dstRow = y * rw
                    for x in 0..<rw { dst[dstRow + x] = src[srcRow + x] }
                }
            }
        }

        // Separable 3×3 Gaussian [1 2 1]/4, horizontal then vertical. The
        // passes write into fresh zeroed buffers and copy only the one-pixel
        // border they don't compute (`var smooth = buf` used to copy the whole
        // region twice, a full-frame copy each for the whole-image fallback).
        var smooth = [Float](repeating: 0, count: rw * rh)
        buf.withUnsafeBufferPointer { src in
            smooth.withUnsafeMutableBufferPointer { dst in
                for y in 0..<rh {
                    let row = y * rw
                    dst[row] = src[row]
                    dst[row + rw - 1] = src[row + rw - 1]
                    for x in 1..<(rw - 1) {
                        dst[row + x] = (src[row + x - 1] + 2 * src[row + x] + src[row + x + 1]) * 0.25
                    }
                }
            }
        }
        var final = [Float](repeating: 0, count: rw * rh)
        smooth.withUnsafeBufferPointer { src in
            final.withUnsafeMutableBufferPointer { dst in
                for x in 0..<rw {
                    dst[x] = src[x]
                    dst[(rh - 1) * rw + x] = src[(rh - 1) * rw + x]
                }
                for y in 1..<(rh - 1) {
                    let row = y * rw
                    for x in 0..<rw {
                        dst[row + x] = (src[row - rw + x] + 2 * src[row + x] + src[row + rw + x]) * 0.25
                    }
                }
            }
        }

        // Sobel over the requested region (interior of the apron'd buffer).
        let sx0 = max(1, x0 - rx0), sy0 = max(1, y0 - ry0)
        let sx1 = min(rw - 1, xEnd - rx0), sy1 = min(rh - 1, yEnd - ry0)
        guard sx1 > sx0, sy1 > sy0 else { return 0 }
        var sum = 0.0
        var count = 0.0
        final.withUnsafeBufferPointer { g in
            for y in sy0..<sy1 {
                let row = y * rw
                for x in sx0..<sx1 {
                    let i = row + x
                    // Named taps: the 6-term chains inlined into Double(...)
                    // made older Swift compilers (CI's Xcode 16) time out
                    // type-checking this expression.
                    let tl = g[i - rw - 1], tc = g[i - rw], tr = g[i - rw + 1]
                    let ml = g[i - 1], mr = g[i + 1]
                    let bl = g[i + rw - 1], bc = g[i + rw], br = g[i + rw + 1]
                    let gxF: Float = tr + 2 * mr + br - tl - 2 * ml - bl
                    let gyF: Float = bl + 2 * bc + br - tl - 2 * tc - tr
                    let gx = Double(gxF), gy = Double(gyF)
                    sum += gx * gx + gy * gy
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        return (sum / count).squareRoot()
    }

    /// 对焦高亮用的每像素梯度幅值（Gaussian 3×3 预模糊 + Sobel，和 tenengrad 同一套
    /// 口径，只是不求均值）。边界一圈为 0。阈值由调用方按分位数定 —— 绝对阈值
    /// 换一张曝光就失效。
    static func gradientMagnitude(gray: [Float], width: Int, height: Int) -> [Float] {
        let w = width, h = height
        guard w >= 3, h >= 3 else { return [Float](repeating: 0, count: w * h) }
        var smooth = [Float](repeating: 0, count: w * h)
        gray.withUnsafeBufferPointer { src in
            smooth.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    dst[row] = src[row]; dst[row + w - 1] = src[row + w - 1]
                    for x in 1..<(w - 1) {
                        dst[row + x] = (src[row + x - 1] + 2 * src[row + x] + src[row + x + 1]) * 0.25
                    }
                }
            }
        }
        var blurred = [Float](repeating: 0, count: w * h)
        smooth.withUnsafeBufferPointer { src in
            blurred.withUnsafeMutableBufferPointer { dst in
                for x in 0..<w { dst[x] = src[x]; dst[(h - 1) * w + x] = src[(h - 1) * w + x] }
                for y in 1..<(h - 1) {
                    let row = y * w
                    for x in 0..<w {
                        dst[row + x] = (src[row - w + x] + 2 * src[row + x] + src[row + w + x]) * 0.25
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        blurred.withUnsafeBufferPointer { g in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 1..<(h - 1) {
                    let row = y * w
                    for x in 1..<(w - 1) {
                        let i = row + x
                        let tl = g[i - w - 1], tc = g[i - w], tr = g[i - w + 1]
                        let ml = g[i - 1], mr = g[i + 1]
                        let bl = g[i + w - 1], bc = g[i + w], br = g[i + w + 1]
                        let gx: Float = tr + 2 * mr + br - tl - 2 * ml - bl
                        let gy: Float = bl + 2 * bc + br - tl - 2 * tc - tr
                        dst[i] = (gx * gx + gy * gy).squareRoot()
                    }
                }
            }
        }
        return out
    }

    /// 对焦高亮真正该用的量：3×3 Laplacian 的绝对值（二阶导），**不预模糊**。
    /// 梯度幅值量的是反差 —— 深色木头对天空的边缘再糊也很大；二阶导量的是过渡有
    /// 多陡 —— 糊掉的边缘二阶导就小。相机的峰值对焦本质上就是个高通滤波。
    static func laplacianMagnitude(gray: [Float], width: Int, height: Int) -> [Float] {
        let w = width, h = height
        var out = [Float](repeating: 0, count: w * h)
        guard w >= 3, h >= 3 else { return out }
        gray.withUnsafeBufferPointer { g in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 1..<(h - 1) {
                    let row = y * w
                    for x in 1..<(w - 1) {
                        let i = row + x
                        let v: Float = 4 * g[i] - g[i - 1] - g[i + 1] - g[i - w] - g[i + w]
                        dst[i] = abs(v)
                    }
                }
            }
        }
        return out
    }

    // MARK: - Exposure clipping

    static let highlightClipValue: UInt8 = 250
    static let shadowClipValue: UInt8 = 5

    static func exposureClipping(rgba: [UInt8], width: Int, height: Int) -> (highlightPct: Double, shadowPct: Double) {
        var blown = 0
        var crushed = 0
        let n = width * height
        rgba.withUnsafeBufferPointer { src in
            for i in 0..<n {
                let r = src[i * 4], g = src[i * 4 + 1], b = src[i * 4 + 2]
                let lo = min(r, min(g, b))
                let hi = max(r, max(g, b))
                if lo >= highlightClipValue { blown += 1 }
                if hi <= shadowClipValue { crushed += 1 }
            }
        }
        return (Double(blown) / Double(n), Double(crushed) / Double(n))
    }

    // MARK: - Subject region (主体区域的裁切和亮度)

    /// 一行里的一段像素 [x0, x1)。几个矩形（多张脸）先拆成按行不重叠的段，重叠处不重复计数。
    struct Span { let y: Int; let x0: Int; let x1: Int }

    /// 归一化（左上原点）矩形的并集 → 按行的像素段。空列表 = 没有像素。
    static func spans(of rects: [[Double]], width: Int, height: Int) -> [Span] {
        let boxes = rects.compactMap { r -> (x0: Int, y0: Int, x1: Int, y1: Int)? in
            let x0 = max(0, Int(r[0] * Double(width))), x1 = min(width, Int(r[2] * Double(width)))
            let y0 = max(0, Int(r[1] * Double(height))), y1 = min(height, Int(r[3] * Double(height)))
            return x1 > x0 && y1 > y0 ? (x0, y0, x1, y1) : nil
        }
        guard let top = boxes.map(\.y0).min(), let bottom = boxes.map(\.y1).max() else { return [] }
        var out: [Span] = []
        for y in top..<bottom {
            let row = boxes.filter { $0.y0 <= y && y < $0.y1 }.map { ($0.x0, $0.x1) }.sorted { $0.0 < $1.0 }
            var current: (Int, Int)?
            for seg in row {
                if let c = current, seg.0 <= c.1 {
                    current = (c.0, max(c.1, seg.1))
                } else {
                    if let c = current { out.append(Span(y: y, x0: c.0, x1: c.1)) }
                    current = seg
                }
            }
            if let c = current { out.append(Span(y: y, x0: c.0, x1: c.1)) }
        }
        return out
    }

    /// 和 exposureClipping 同一个口径（三通道同时裁切），只数这些像素段 —— 背景里的死黑屋檐不算。
    static func exposureClipping(rgba: [UInt8], width: Int, spans: [Span]) -> (highlightPct: Double, shadowPct: Double)? {
        var blown = 0, crushed = 0, n = 0
        rgba.withUnsafeBufferPointer { src in
            for s in spans {
                for x in s.x0..<s.x1 {
                    let i = (s.y * width + x) * 4
                    let r = src[i], g = src[i + 1], b = src[i + 2]
                    if min(r, min(g, b)) >= highlightClipValue { blown += 1 }
                    if max(r, max(g, b)) <= shadowClipValue { crushed += 1 }
                }
                n += s.x1 - s.x0
            }
        }
        guard n > 0 else { return nil }
        return (Double(blown) / Double(n), Double(crushed) / Double(n))
    }

    // MARK: - 主体裁切只数人（优化分析 2026-11-18 VQ-01）

    /// 人像分割蒙版（FaceAnalyzer.personMask：Vision 的 .balanced，3:4 的图出 384×512），左上原点，0–255，越大越像人。
    struct PersonMask: Sendable {
        let width: Int
        let height: Int
        let values: [UInt8]
    }

    /// 矩形里高光、暗部裁切都不到这么多，就不跑分割、照旧用矩形的数（AnalysisEngine）：滑杆最低 0.5%，这些照片判决和以前一样，
    /// 也省下分割的开销（一张 ~7000 万条指令，进程里第一次还要 ~6 亿条载模型）。
    static let personClipGate = 0.005
    /// 一块死白（8 连通）外面一圈没裁切的像素，分割说「是人」的平均（0–1）低于它 = 这块死白是从背景连进来的，整块不算人。
    static let backgroundBlobVote = 0.25
    /// 脸芯里（人脸框四边各收 faceCoreInset）分割认作人的像素，有这么多死白 = 脸本身打爆了。
    static let blownFaceShare = 0.02
    static let faceCoreInset = 0.15
    /// 矩形里分割认作人的像素不到矩形的这么多 = 分割基本没认出人（戏服、面具、雕像上的脸……），不信它，照旧用矩形。
    /// 合成集（184 张）最少 47%，photot 21 张最少 63%。
    static let minPersonShare = 0.2

    /// 主体区域的曝光裁切，只数人（VQ-01）。`bodies` = 现在的主体矩形（头 + 上半身并集）的像素段，`faces` = 不带 padding 的脸框
    /// （FaceAnalyzer.exposureRegions）。矩形里分割认作人的像素不到 minPersonShare = nil（调用方照旧用矩形的数）。
    ///
    /// 为什么不直接用「矩形 ∩ 分割」（分析员的修法 B）：分割对纯色背景很准（白底 / 黑底 / 高调 / 低调都修好），但对死白区域靠不住，
    /// 两头都错 —— 逆光时打爆的栏杆和白汉服袖子连成一片，分割把整片并进了人（7231 背景 +3EV：矩形 28.0% → B 31.5%）；
    /// 整体过曝时打爆的白袖子贴着亮墙，分割又把袖子划出去了（7225 +1.5EV：36.0% → 8.0%）。死白没有纹理，分割只能猜。
    /// 所以没裁切的像素信分割，死白按「块」判：
    ///   - 暗部裁切照旧按分割数（黑底、低调、剪影上分割都准：黑底 0 中位 17.2% → 1.7%，剪影照抓）。
    ///   - 高光裁切：每个和「矩形 ∩ 人」相交的死白连通块（8 连通，整张图上找），看它外面一圈没裁切的像素分割投票 ——
    ///     < backgroundBlobVote（四周大多是背景）就整块不算（连进来的背景）；否则只数块里「矩形 ∩ 人」的那部分。
    ///     合成集（脸没爆的那些）里被扔掉的是 7231 背景 +2 / +3EV 连进来的那片（0.12 / 0.20）和 +1EV 时袖子和背景连成的一片
    ///     （0.12，真值里 22% 是人）；人身上的死白 0.35 以上，只有一个例外 0.23（下面说的 7225 +1EV）。
    ///   - 脸本身打爆了（脸芯里人的像素 ≥ blownFaceShare 是死白）：整张过曝，死白到处连成一片，上面的块判法会把人身上的也扔掉
    ///     （不这样的话 +1.5EV 有 2 张、+2EV 有 1 张掉到 15% 以下）。这时取 max(矩形, 矩形 ∩ 人)，不比以前松。合成集里只有整体 / 人 +1.5EV 及以上
    ///     会到这条（最少 1.2%），白底、逆光、高调的脸芯都是 0（脸框角上的背景不在分割里，不算）。
    /// 分母 = 矩形 ∩ 人里没裁切的 + 算进来的死白 + 暗部裁切（扔掉的块也从分母里拿掉）。
    /// 代价（只在 +1EV 这一档，分析员归「看用途」）：脸还没爆、白衣服已经爆了而且和亮墙连成一片的，会被当背景扔掉 ——
    /// 合成集整体 +1EV 宽松 / 标准 / 严格 2/6/8 → 1/5/7（7225 31.8% → 0.3%、7231 30.9% → 9.9%）；+1.5EV 起脸开始爆，照旧抓。
    /// 前后对照表在这次提交的说明里。
    static func personClipping(rgba: [UInt8], width: Int, height: Int, bodies: [Span], faces: [[Double]],
                               mask: PersonMask) -> (highlightPct: Double, shadowPct: Double)? {
        let mw = mask.width, mh = mask.height
        guard width > 0, height > 0, mw > 0, mh > 0, mask.values.count == mw * mh,
              rgba.count >= width * height * 4, !bodies.isEmpty else { return nil }
        // 蒙版按像素中心取最近邻对到分析图上：列号 maskX[x]，行起点 maskRow[y]。
        var maskX = [Int](repeating: 0, count: width)
        for x in 0..<width {
            maskX[x] = min(mw - 1, Int((Double(x) + 0.5) * Double(mw) / Double(width)))
        }
        var maskRow = [Int](repeating: 0, count: height)
        for y in 0..<height {
            maskRow[y] = min(mh - 1, Int((Double(y) + 0.5) * Double(mh) / Double(height))) * mw
        }
        let personValue: UInt8 = 128  // 分割 ≥ 0.5 算人
        let hiBit: UInt8 = 1, loBit: UInt8 = 2, rectBit: UInt8 = 4, seenBit: UInt8 = 8, ringBit: UInt8 = 16
        var state = [UInt8](repeating: 0, count: width * height)
        var rectN = 0, rectHi = 0, rectLo = 0, personN = 0, personHi = 0, personLo = 0
        var coreN = 0, coreHi = 0
        var counted = 0
        var cores: [[Double]] = []
        for f in faces where f.count == 4 {
            let fw = f[2] - f[0], fh = f[3] - f[1]
            cores.append([f[0] + faceCoreInset * fw, f[1] + faceCoreInset * fh,
                          f[2] - faceCoreInset * fw, f[3] - faceCoreInset * fh])
        }
        let coreSpans = spans(of: cores, width: width, height: height)

        rgba.withUnsafeBufferPointer { src in
            mask.values.withUnsafeBufferPointer { seg in
                state.withUnsafeMutableBufferPointer { st in
                    for i in 0..<(width * height) {
                        let r = src[i * 4], g = src[i * 4 + 1], b = src[i * 4 + 2]
                        if min(r, min(g, b)) >= highlightClipValue {
                            st[i] = hiBit
                        } else if max(r, max(g, b)) <= shadowClipValue {
                            st[i] = loBit
                        }
                    }
                    for s in bodies {
                        for x in s.x0..<s.x1 {
                            let i = s.y * width + x
                            let v = st[i]
                            st[i] = v | rectBit
                            rectN += 1
                            if v & hiBit != 0 { rectHi += 1 }
                            if v & loBit != 0 { rectLo += 1 }
                            guard seg[maskRow[s.y] + maskX[x]] >= personValue else { continue }
                            personN += 1
                            if v & hiBit != 0 { personHi += 1 }
                            if v & loBit != 0 { personLo += 1 }
                        }
                    }
                    for s in coreSpans {
                        for x in s.x0..<s.x1 where seg[maskRow[s.y] + maskX[x]] >= personValue {
                            coreN += 1
                            if st[s.y * width + x] & hiBit != 0 { coreHi += 1 }
                        }
                    }
                    guard personN > 0, Double(personN) >= minPersonShare * Double(rectN),
                          coreN == 0 || Double(coreHi) < blownFaceShare * Double(coreN) else { return }

                    // 高光裁切的连通块：从「矩形 ∩ 人」里的死白像素出发，整张图上 8 连通地找完一整块，
                    // 顺手数块里「矩形 ∩ 人」的像素、外面一圈（没裁切的 8 邻域，每个像素只数一次）的分割投票。
                    var stack: [Int32] = []
                    var ring: [Int32] = []
                    for s in bodies {
                        for x in s.x0..<s.x1 {
                            let start = s.y * width + x
                            guard st[start] & (hiBit | seenBit) == hiBit,
                                  seg[maskRow[s.y] + maskX[x]] >= personValue else { continue }
                            var inPerson = 0, voteSum = 0, voteN = 0
                            st[start] |= seenBit
                            stack.append(Int32(start))
                            while let top = stack.popLast() {
                                let p = Int(top)
                                let py = p / width, px = p - py * width
                                if st[p] & rectBit != 0, seg[maskRow[py] + maskX[px]] >= personValue { inPerson += 1 }
                                for ny in max(0, py - 1)...min(height - 1, py + 1) {
                                    for nx in max(0, px - 1)...min(width - 1, px + 1) {
                                        let q = ny * width + nx
                                        let v = st[q]
                                        if v & hiBit != 0 {
                                            if v & seenBit == 0 {
                                                st[q] = v | seenBit
                                                stack.append(Int32(q))
                                            }
                                        } else if v & ringBit == 0 {
                                            st[q] = v | ringBit
                                            ring.append(Int32(q))
                                            voteSum += Int(seg[maskRow[ny] + maskX[nx]])
                                            voteN += 1
                                        }
                                    }
                                }
                            }
                            for q in ring { st[Int(q)] &= ~ringBit }
                            ring.removeAll(keepingCapacity: true)
                            if voteN > 0, Double(voteSum) >= backgroundBlobVote * 255 * Double(voteN) {
                                counted += inPerson
                            }
                        }
                    }
                }
            }
        }
        guard personN > 0, rectN > 0, Double(personN) >= minPersonShare * Double(rectN) else { return nil }
        if coreN > 0, Double(coreHi) >= blownFaceShare * Double(coreN) {
            let rect = (Double(rectHi) / Double(rectN), Double(rectLo) / Double(rectN))
            let person = (Double(personHi) / Double(personN), Double(personLo) / Double(personN))
            return (max(rect.0, person.0), max(rect.1, person.1))
        }
        let total = personN - personHi + counted  // 人里没裁切的 + 暗部裁切 + 算进来的死白
        guard total > 0 else { return nil }
        return (Double(counted) / Double(total), Double(personLo) / Double(total))
    }

    /// 亮度（grayscale 的 0–255 口径）直方图，256 格。spans 为 nil = 整张。
    static func lumaHistogram(gray: [Float], width: Int, height: Int, spans: [Span]? = nil) -> [Int] {
        var hist = [Int](repeating: 0, count: 256)
        let rows = spans ?? (0..<height).map { Span(y: $0, x0: 0, x1: width) }
        gray.withUnsafeBufferPointer { g in
            hist.withUnsafeMutableBufferPointer { h in
                for s in rows {
                    let row = s.y * width
                    for x in s.x0..<s.x1 {
                        let v = Int(g[row + x])
                        h[v < 0 ? 0 : (v > 255 ? 255 : v)] += 1
                    }
                }
            }
        }
        return hist
    }

    /// 直方图的分位点（0…1），落在哪一格就返回那一格的亮度。空直方图返回 nil。
    static func percentile(_ hist: [Int], _ q: Double) -> Double? {
        let total = hist.reduce(0, +)
        guard total > 0 else { return nil }
        let target = Int((Double(total) * q).rounded(.up))
        var seen = 0
        for (level, count) in hist.enumerated() {
            seen += count
            if seen >= max(1, target) { return Double(level) }
        }
        return 255
    }

    // MARK: - Perceptual hash

    static let phashInputSize = 32
    static let phashOutputSize = 8

    /// Precomputed DCT-II basis for a 32-point transform.
    private static let dctBasis: [Float] = {
        let n = phashInputSize
        var basis = [Float](repeating: 0, count: n * n)
        for k in 0..<n {
            for i in 0..<n {
                basis[k * n + i] = cos(Float.pi * (Float(i) + 0.5) * Float(k) / Float(n))
            }
        }
        return basis
    }()

    /// pHash from an RGB buffer of ANY size: box-average downsample to 32x32
    /// grayscale, 2D DCT, top-left 8x8 coefficients thresholded on their median.
    /// Averaging (vs nearest-neighbor) matters for grouping stability: a single
    /// sampled pixel jitters with noise/micro-motion between burst frames, which
    /// flipped borderline hamming distances around the threshold.
    static func phash(rgba: [UInt8], width: Int, height: Int) -> UInt64 {
        let n = phashInputSize
        var small = [Float](repeating: 0, count: n * n)
        rgba.withUnsafeBufferPointer { src in
            small.withUnsafeMutableBufferPointer { dst in
                for y in 0..<n {
                    let sy0 = y * height / n
                    let sy1 = max(sy0 + 1, (y + 1) * height / n)
                    for x in 0..<n {
                        let sx0 = x * width / n
                        let sx1 = max(sx0 + 1, (x + 1) * width / n)
                        var acc: Float = 0
                        for sy in sy0..<sy1 {
                            let row = sy * width
                            for sx in sx0..<sx1 {
                                let i = (row + sx) * 4
                                acc += 0.299 * Float(src[i]) + 0.587 * Float(src[i + 1]) + 0.114 * Float(src[i + 2])
                            }
                        }
                        dst[y * n + x] = acc / Float((sy1 - sy0) * (sx1 - sx0))
                    }
                }
            }
        }

        // rows: T = basis · small^T applied per-row; then per-column
        var temp = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for k in 0..<n {
                var acc: Float = 0
                for i in 0..<n { acc += small[y * n + i] * dctBasis[k * n + i] }
                temp[y * n + k] = acc
            }
        }
        var dct = [Float](repeating: 0, count: n * n)
        for x in 0..<n {
            for k in 0..<n {
                var acc: Float = 0
                for i in 0..<n { acc += temp[i * n + x] * dctBasis[k * n + i] }
                dct[k * n + x] = acc
            }
        }

        let m = phashOutputSize
        var lowFreq = [Float]()
        lowFreq.reserveCapacity(m * m)
        for y in 0..<m {
            for x in 0..<m {
                lowFreq.append(dct[y * n + x])
            }
        }
        let sorted = lowFreq.sorted()
        let median = (sorted[m * m / 2 - 1] + sorted[m * m / 2]) / 2

        var hash: UInt64 = 0
        for (bit, value) in lowFreq.enumerated() where value > median {
            hash |= (1 << UInt64(63 - bit))
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func phashHex(_ hash: UInt64) -> String {
        String(format: "%016llx", hash)
    }
}
