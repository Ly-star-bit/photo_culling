import Foundation

/// Native ports of layer1.py's numeric metrics. Same algorithms, same semantics:
/// - Laplacian variance for sharpness (higher = sharper)
/// - Exposure clipping: fraction of pixels where EVERY channel is blown/crushed
///   (a saturated red flower is not "blown"; washed-out white is)
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
