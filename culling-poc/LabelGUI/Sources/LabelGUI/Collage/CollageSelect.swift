import Foundation
import CoreGraphics
import ImageIO
import Vision

/// 批量页 → 拼图：照片引用（文档自带的元数据）。
enum CollageBridge {

    /// 挑主图、挑片用的分数：判决最重（精选 > 可用），其次表情、人脸质量，锐度只做尾数。
    static func score(_ item: BatchItem) -> Double {
        var s = 0.0
        switch item.verdict {
        case .pick: s += 2
        case .usable: s += 1
        case .reject: s += 0
        }
        s += 0.6 * (item.expressionScore.map { Double($0) / 5 } ?? 0.6)
        s += 0.8 * (item.faceQuality ?? 0.5)
        s += 0.2 * min(item.sharpness, 150) / 150
        return s
    }

    /// 只有 BatchStore 才有、BatchItem 上没有的：场内名次、哪些是手动判的。在主线程从 BatchStore 取好
    /// （它是 @MainActor），后台建 ref、刷新时带着。
    struct Facts {
        var takeRank: [String: Int] = [:]
        var manual: Set<String> = []

        init() {}

        @MainActor
        init(batch: BatchStore) {
            takeRank = batch.takeRank
            manual = Set(batch.items.lazy.map(\.id).filter { batch.isManual($0) })
        }
    }

    static func ref(from item: BatchItem, facts: Facts = Facts()) -> CollagePhotoRef? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.decodePath) as CFURL, nil),
              let size = WatermarkEngine.uprightSize(of: source) else { return nil }
        var ref = CollagePhotoRef(id: item.id, path: item.decodePath, previewPath: item.previewPath,
                                  width: size.width, height: size.height)
        refresh(&ref, from: item, facts: facts)
        return ref
    }

    /// 托盘里的照片按批量页的现状刷新（重新判过、调过场的间隔、重新分析之后）：分析和判决带来的字段都换成
    /// 新的；文件路径、尺寸不动（同一个 id 就是同一张文件，不为刷新重新开文件）。建 ref 也走这里。
    static func refresh(_ ref: inout CollagePhotoRef, from item: BatchItem, facts: Facts) {
        var faces = item.faces.map(\.bbox).filter { $0.count == 4 }
        if faces.isEmpty, let primary = item.faceBbox, primary.count == 4 { faces = [primary] }
        ref.faces = faces
        ref.score = score(item)
        ref.isPick = item.verdict == .pick
        ref.take = item.take
        ref.chapter = item.chapter
        ref.captureTime = item.captureTime
        ref.faceAreaPct = item.faceAreaPct
        ref.burstGroup = item.burstGroup
        ref.takeRank = facts.takeRank[item.id]
        ref.frameNo = frameNumber(item.rawPath)
        ref.captureSubsec = item.captureSubsec
        ref.verdict = verdict(item.verdict)
        ref.isManual = facts.manual.contains(item.id)
        ref.eyesOpen = item.dynamicEyeClosed.map { !$0 }
        ref.exif = item.exif
        ref.body = item.body.isEmpty ? nil : item.body
    }

    static func verdict(_ v: Verdict) -> CollageVerdict {
        switch v {
        case .pick: return .pick
        case .usable: return .usable
        case .reject: return .reject
        }
    }

    /// 帧号 = 原文件名（不带扩展名）末尾那串数字：DSCF7207.RAF → "7207"、IMG_0001 → "0001"。用文件名不用 id：
    /// 两个文件夹有同名照片时 id 带着文件夹前缀。末尾不是数字 = nil。
    static func frameNumber(_ path: String) -> String? {
        // 只去最后一个扩展名：2026.03.21_DSCF7207.jpg 按第一个点切会剩下 2026。
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let digits = stem.reversed().prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : String(digits.reversed())
    }

    /// 外部文件在托盘里的 id（导入完按 id 排版的地方要用同一个写法）。
    static func fileID(_ url: URL) -> String { "file:" + url.path }

    /// 外部拖进来的文件：现场解一张 1536 跑人脸（和分析引擎同一个 FaceAnalyzer）。
    static func ref(fromFile url: URL) -> CollagePhotoRef? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let size = WatermarkEngine.uprightSize(of: source) else { return nil }
        let id = fileID(url)
        var ref = CollagePhotoRef(id: id, path: url.path, previewPath: nil, width: size.width, height: size.height)
        ref.frameNo = frameNumber(url.path)
        if let image = CollageImages.decode(path: url.path, maxPixel: 1536),
           let face = FaceAnalyzer.analyze(in: image).face {
            ref.faces = face.subjectFaces.map(\.bbox)
            ref.faceAreaPct = face.faceAreaPct
            ref.score = 1 + 0.8 * (face.captureQuality ?? 0.5)
        } else {
            ref.score = 1
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            ref.captureTime = ImageLoader.exifDateFormatter.date(from: s)
        }
        return ref
    }
}

/// 按需算的视觉信息：路人、无脸主体、画面特征。只进内存缓存，从不写回分析结果。
enum CollageVision {
    private static let lock = NSLock()
    private static var hintCache: [String: CollageCrop.Hints] = [:]
    private static var printCache: [String: VNFeaturePrintObservation] = [:]

    /// 缓存按文件（路径 + 尺寸）记，不按照片 id：批量页的 id 就是文件名，两个场次都有
    /// DSC_0001 时，按 id 记会把上一场的路人框、相似度套到这一场的同名照片上。
    static func cacheKey(_ photo: CollagePhotoRef) -> String {
        "\(photo.path)|\(photo.width)x\(photo.height)"
    }

    static func hints(for photo: CollagePhotoRef) -> CollageCrop.Hints {
        let key = cacheKey(photo)
        lock.lock()
        let hit = hintCache[key]
        lock.unlock()
        if let hit { return hit }
        let computed = computeHints(photo)
        lock.lock()
        hintCache[key] = computed
        lock.unlock()
        return computed
    }

    private static func computeHints(_ photo: CollagePhotoRef) -> CollageCrop.Hints {
        guard let image = CollageImages.preview(photo, need: 1024) else { return CollageCrop.Hints() }
        // 全身模式只报画面主体；背景里半截身子、虚掉的路人要靠上半身模式才抓得到
        // （photot 7232 右边的白衣人、7208 桥上的人都只有上半身模式能检出）。
        let fullBody = VNDetectHumanRectanglesRequest()
        fullBody.upperBodyOnly = false
        let upperBody = VNDetectHumanRectanglesRequest()
        upperBody.upperBodyOnly = true
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([fullBody, upperBody, faces])
        let humanObservations = (fullBody.results ?? []) + (upperBody.results ?? [])

        let subjects = photo.faces.filter { $0.count == 4 }
        func center(_ b: [Double]) -> (Double, Double) { ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2) }
        func contains(_ b: [Double], _ p: (Double, Double)) -> Bool {
            p.0 >= b[0] && p.0 <= b[2] && p.1 >= b[1] && p.1 <= b[3]
        }
        var bystanders: [[Double]] = []
        for obs in humanObservations {
            let b = topLeft(obs.boundingBox)
            // 框里有主体的脸 = 主体本人。
            if subjects.contains(where: { contains(b, center($0)) }) { continue }
            // 全身、上半身两次检测会报同一个人：中心落在已有框里就算重复。
            if bystanders.contains(where: { contains($0, center(b)) }) { continue }
            bystanders.append(b)
        }
        for obs in faces.results ?? [] {
            let b = topLeft(obs.boundingBox)
            let c = center(b)
            if subjects.contains(where: { contains($0, c) }) { continue }
            if bystanders.contains(where: { contains($0, c) }) { continue }
            // 只有一张小脸：往下估一截肩膀。
            let w = b[2] - b[0]
            let h = b[3] - b[1]
            bystanders.append([max(0, b[0] - 0.4 * w), max(0, b[1] - 0.3 * h),
                               min(1, b[2] + 0.4 * w), min(1, b[3] + 1.6 * h)])
        }
        var subject: [Double]?
        if subjects.isEmpty, let s = FaceAnalyzer.subjectRect(in: image) {
            subject = [s.x0, s.y0, s.x1, s.y1]
        }
        var hints = CollageCrop.Hints(bystanders: bystanders, subject: subject)
        if let t = tone(of: image) {
            hints.meanLuma = t.luma
            hints.isMonochrome = t.mono
        }
        return hints
    }

    /// 亮度、黑白判定，外加判定用的三个量（命令行 toneprobe 打印，调阈值时看得见离线多远）。
    struct Tone {
        var luma: Double
        var mono: Bool
        /// 去掉整体偏色之后色度的 95 分位。
        var spread: Double
        /// 有颜色的像素单位色相向量平均起来多长（1 = 全朝一个方向）。
        var hueAlign: Double
        /// 色度按亮度二次拟合之后剩下的 95 分位（调色黑白的颜色只跟着亮度走，接近 0）。
        var lumaResidual: Double
    }

    /// 调色黑白的「颜色只跟着亮度走」：二次拟合的残差 95 分位上限。实测棕褐调 0.040–0.049，
    /// 钨丝灯 2800K–3500K 的彩色照片 0.19–0.27、暖色调色 0.16–0.22、photot 21 张 0.20–0.33。
    static let monoLumaResidual = 0.08

    /// 平均亮度、是不是黑白：缩到 32×32 看。黑白有两种：
    /// - 中性或整体偏一个色（冷调、暖调的黑白）：去掉整体偏色之后 95% 的像素色度都 < 0.05；
    /// - 调色黑白（棕褐、蓝调，暗处淡、亮处浓）：有颜色的像素色相几乎都朝一个方向（单位色相向量的平均长度
    ///   ≥ 0.95），**而且**颜色只跟着亮度走（色度对亮度二次拟合的残差 95 分位 < monoLumaResidual）。
    /// 彩色照片里总有方向相反的颜色（肤色和天空、衣服和树）：photot 21 张色相一致度 0.03–0.60，棕褐调的黑白 0.98。
    /// 但整体偏暖的彩色照片（钨丝灯、暖白平衡）色相也全朝橙色那边（0.98），只看方向会被判成黑白：
    /// 它们同一亮度上还有红灯笼、蓝裙子，残差下不来 —— 第二条要两个都满足。
    static func tone(of image: CGImage) -> Tone? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CollageRender.srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        let n = side * side
        var luma = 0.0
        var l = [Double](repeating: 0, count: n)
        var a = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let bl = Double(pixels[i * 4 + 2]) / 255
            l[i] = 0.2126 * r + 0.7152 * g + 0.0722 * bl
            luma += l[i]
            a[i] = r - g
            b[i] = (r + g) / 2 - bl
        }
        let meanA = a.reduce(0, +) / Double(n)
        let meanB = b.reduce(0, +) / Double(n)
        let deviation = (0..<n).map { i -> Double in
            let da = a[i] - meanA
            let db = b[i] - meanB
            return (da * da + db * db).squareRoot()
        }.sorted()
        let p95 = deviation[min(n - 1, Int(Double(n) * 0.95))]
        // 色相一致：色度 > 0.03 的像素各取单位色相向量，平均起来有多长（1 = 全朝一个方向）。
        var sumX = 0.0
        var sumY = 0.0
        var chromatic = 0.0
        for i in 0..<n {
            let c = (a[i] * a[i] + b[i] * b[i]).squareRoot()
            guard c > 0.03 else { continue }
            sumX += a[i] / c
            sumY += b[i] / c
            chromatic += 1
        }
        let resultant: Double = chromatic > 0 ? (sumX * sumX + sumY * sumY).squareRoot() / chromatic : 1
        // 颜色是不是只跟着亮度走：a、b 各按亮度二次拟合，看剩下的。
        let fa = quadraticFit(l, a)
        let fb = quadraticFit(l, b)
        let residual = (0..<n).map { i -> Double in
            let x = l[i]
            let pa: Double = fa.0 + fa.1 * x + fa.2 * x * x
            let pb: Double = fb.0 + fb.1 * x + fb.2 * x * x
            let da = a[i] - pa
            let db = b[i] - pb
            return (da * da + db * db).squareRoot()
        }.sorted()
        let r95 = residual[min(n - 1, Int(Double(n) * 0.95))]
        let toned = resultant >= 0.95 && r95 < monoLumaResidual
        return Tone(luma: luma / Double(n), mono: p95 < 0.05 || toned, spread: p95, hueAlign: resultant,
                    lumaResidual: r95)
    }

    /// 最小二乘 y ≈ c0 + c1·x + c2·x²（3×3 正规方程，列主元消去）。x 几乎全一样（纯色图）解不出时退回平均值。
    static func quadraticFit(_ x: [Double], _ y: [Double]) -> (Double, Double, Double) {
        var m = [[Double]](repeating: [0, 0, 0, 0], count: 3)
        for i in x.indices {
            let x1 = x[i]
            let x2 = x1 * x1
            let f = [1, x1, x2]
            for r in 0..<3 {
                for c in 0..<3 { m[r][c] += f[r] * f[c] }
                m[r][3] += f[r] * y[i]
            }
        }
        let mean = x.isEmpty ? 0 : y.reduce(0, +) / Double(x.count)
        for col in 0..<3 {
            var pivot = col
            for r in col..<3 where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-9 else { return (mean, 0, 0) }
            m.swapAt(col, pivot)
            for r in 0..<3 where r != col {
                let k = m[r][col] / m[col][col]
                for c in col..<4 { m[r][c] -= k * m[col][c] }
            }
        }
        return (m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2])
    }

    /// Vision 是左下原点。
    private static func topLeft(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(1 - r.maxY), Double(r.maxX), Double(1 - r.minY)]
    }

    static func featurePrint(_ photo: CollagePhotoRef) -> VNFeaturePrintObservation? {
        let key = cacheKey(photo)
        lock.lock()
        if let hit = printCache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let image = CollageImages.preview(photo, need: 512) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first else { return nil }
        lock.lock()
        printCache[key] = obs
        lock.unlock()
        return obs
    }

    static func distance(_ a: CollagePhotoRef, _ b: CollagePhotoRef) -> Double? {
        guard let fa = featurePrint(a), let fb = featurePrint(b) else { return nil }
        var d: Float = 0
        guard (try? fa.computeDistance(&d, to: fb)) != nil else { return nil }
        return Double(d)
    }
}

enum CollageSelect {

    /// 景别档：0 全景（脸很小）、1 中景、2 近景。
    static func scaleBucket(_ p: CollagePhotoRef) -> Int {
        guard let a = p.faceAreaPct, !p.faces.isEmpty else { return 0 }
        if a < 0.012 { return 0 }
        if a < 0.05 { return 1 }
        return 2
    }

    /// 挑 n 张：分数高的先上；和已选的越像扣得越多（Vision 特征距离，按候选两两距离的
    /// 中位数归一）；同一场轻扣；景别、横竖跟已选不同的加一点。
    ///
    /// 不再「一场只出一张」：photot 灯笼楼那一场 10 张、姿势各不相同，这条硬规则把它们
    /// 全挡在外面，反倒让另一场里和桥上那张几乎一样的 7207 补了进来。画面像不像由特征
    /// 距离说了算（同场连拍 0.18–0.29、同地同姿势 0.33–0.41、换地方 0.55+）；只有特征
    /// 算不出来时才退回按场硬去重。
    static func pick(_ n: Int, from photos: [CollagePhotoRef], useSimilarity: Bool = true) -> [CollagePhotoRef] {
        let pool = photos.sorted { $0.score > $1.score }
        guard pool.count > n, n > 0 else { return pool }

        var scale = 1.0
        var dist: [String: Double] = [:]
        func key(_ a: CollagePhotoRef, _ b: CollagePhotoRef) -> String { a.id < b.id ? a.id + "|" + b.id : b.id + "|" + a.id }
        if useSimilarity {
            var all: [Double] = []
            let head = Array(pool.prefix(60))
            for i in 0..<head.count {
                for j in (i + 1)..<head.count {
                    if let d = CollageVision.distance(head[i], head[j]) {
                        dist[key(head[i], head[j])] = d
                        all.append(d)
                    }
                }
            }
            if !all.isEmpty {
                all.sort()
                scale = max(1e-6, all[all.count / 2])
            }
        }

        let haveDistances = !dist.isEmpty
        var chosen = [pool[0]]
        while chosen.count < n {
            let usedTakes = Set(chosen.compactMap(\.take))
            let chosenIDs = Set(chosen.map(\.id))
            var candidates = pool.filter { p in
                guard !chosenIDs.contains(p.id) else { return false }
                guard !haveDistances, let t = p.take else { return true }
                return !usedTakes.contains(t)
            }
            if candidates.isEmpty { candidates = pool.filter { !chosenIDs.contains($0.id) } }
            let scales = Set(chosen.map(scaleBucket))
            let portraits = chosen.filter(\.isPortrait).count
            var best: CollagePhotoRef?
            var bestValue = -Double.infinity
            for p in candidates {
                var v = p.score
                if haveDistances {
                    let ds = chosen.compactMap { dist[key(p, $0)] }
                    if let nearest = ds.min() {
                        let norm = nearest / scale
                        v += 0.8 * min(norm, 1.4)
                        // 低于中位数的 80% 开始扣，到 40% 扣满：同场连拍 ≈ 扣满，同姿势 ≈ 扣一半。
                        let closeness = min(1, max(0, (0.8 - norm) / 0.4))
                        v -= 1.4 * closeness
                        // 同地同姿势（和相册去重同一条线：中位数的 76% 以下）再扣一截：两张几乎一样的精选
                        // 并排，不如换一张不一样的可用（photot 7208 / 7212 以前就这样挨在一起）。
                        if norm < 0.76 { v -= 1.0 }
                    }
                    if let t = p.take, usedTakes.contains(t) { v -= 0.35 }
                }
                if !scales.contains(scaleBucket(p)) { v += 0.15 }
                let tooManyPortraits = portraits * 3 > chosen.count * 2
                if tooManyPortraits && !p.isPortrait { v += 0.1 }
                if v > bestValue {
                    bestValue = v
                    best = p
                }
            }
            guard let next = best else { break }
            chosen.append(next)
        }
        return chosen
    }

    /// 相册选片：
    /// - 连拍（特征距离 < 中位数 54%，同场连拍那种）只留分数高的一张；
    /// - 可用照片如果和已经留下的两张以上是同地同姿势（< 中位数 76%），不收 —— 同一个
    ///   姿势在书里出现三次就腻了。精选只受连拍规则约束。
    /// 按分数从高到低过，精选天然先留。返回同地同姿势的两两关系，编排时一个跨页里别堆
    /// 三张这样的。特征算不出来时原样返回。
    static func distinctMoments(_ photos: [CollagePhotoRef])
        -> (kept: [CollagePhotoRef], dropped: [CollagePhotoRef], similar: [String: Set<String>]) {
        let sorted = photos.sorted { $0.score > $1.score }
        let head = Array(sorted.prefix(120))
        var dist: [String: Double] = [:]
        var all: [Double] = []
        for i in 0..<head.count {
            for j in (i + 1)..<head.count {
                if let d = CollageVision.distance(head[i], head[j]) {
                    dist[head[i].id + "|" + head[j].id] = d
                    dist[head[j].id + "|" + head[i].id] = d
                    all.append(d)
                }
            }
        }
        guard !all.isEmpty else { return (photos, [], [:]) }
        all.sort()
        let median = all[all.count / 2]
        var similar: [String: Set<String>] = [:]
        for (key, d) in dist where d < 0.76 * median {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            similar[parts[0], default: []].insert(parts[1])
        }

        var kept: [CollagePhotoRef] = []
        var dropped: [CollagePhotoRef] = []
        for p in sorted {
            let distances = kept.compactMap { dist[p.id + "|" + $0.id] }
            let nearest = distances.min() ?? .infinity
            let samePose = distances.filter { $0 < 0.76 * median }.count
            if nearest < 0.54 * median || (!p.isPick && samePose >= 2) {
                dropped.append(p)
            } else {
                kept.append(p)
            }
        }
        return (kept, dropped, similar)
    }

    /// 时间顺序（没时间的排最后，按 id）。
    static func chronological(_ photos: [CollagePhotoRef]) -> [CollagePhotoRef] {
        photos.sorted { a, b in
            switch (a.captureTime, b.captureTime) {
            case let (x?, y?): return x == y ? a.id < b.id : x < y
            case (nil, nil): return a.id < b.id
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }
}

/// 相册：编排（哪些照片进哪个跨页）+ 每个跨页的版式。CLI 和拼图 tab 共用。
enum CollageAlbum {

    enum SpreadKind: String, Codable {
        /// 扉页：左页竖排标题，右页主图
        case opener
        /// 求解器排多张
        case grid
        /// 一页一张（两张竖图对页）
        case pair
        /// 单张：横图铺满跨页，否则右页 + 左页日期
        case solo
    }

    struct Spread {
        var kind: SpreadKind
        var photos: [CollagePhotoRef]
        /// fine-art 主题的跨页说明（哪种跨页、第几章、左页的字、整章黑白）；默认主题 = nil。
        var fineArt: CollageFineArtSpread? = nil
    }

    struct Plan {
        var spreads: [Spread]
        /// 去重拿掉的（界面上可以一键加回）。
        var dropped: [CollagePhotoRef]
        /// 按哪个主题编的（build 按它出版式）。
        var theme: CollageAlbumTheme = .classic
    }

    /// 编排：去重 → 分数最高的做扉页 → 其余按时间、按章节分组，疏密交替（4-3-5-2-4-3）；
    /// 分数排前一成多的竖图和下一张组成一页一张的对页，横图单独铺满。
    /// theme = .fineArt：婚礼 fine-art 的编排（CollageStyleFineArt.plan，chapterMono = 整章黑白，title = 工程标题：
    /// 扉页标题是西文就不加字距）；默认主题照旧。
    static func plan(_ photos: [CollagePhotoRef], dedupe: Bool = true, maxPerSpread: Int = 5,
                     theme: CollageAlbumTheme = .classic, chapterMono: Bool = true, title: String = "") -> Plan {
        if theme == .fineArt {
            return CollageStyleFineArt.plan(photos, dedupe: dedupe, chapterMono: chapterMono, title: title)
        }
        var kept = photos
        var dropped: [CollagePhotoRef] = []
        var similar: [String: Set<String>] = [:]
        if dedupe {
            let r = CollageSelect.distinctMoments(photos)
            kept = r.kept
            dropped = r.dropped
            similar = r.similar
        }
        guard let opener = kept.max(by: { $0.score < $1.score }) else { return Plan(spreads: [], dropped: dropped) }
        var spreads = [Spread(kind: .opener, photos: [opener])]
        let rest = CollageSelect.chronological(kept.filter { $0.id != opener.id })
        let heroCount = rest.count >= 8 ? Int((Double(rest.count) * 0.12).rounded()) : 0
        let heroes = Set(rest.sorted { $0.score > $1.score }.prefix(heroCount).map(\.id))

        var chapters: [[CollagePhotoRef]] = []
        for p in rest {
            if let last = chapters.last?.last, last.chapter == p.chapter {
                chapters[chapters.count - 1].append(p)
            } else {
                chapters.append([p])
            }
        }
        let rhythm = [4, 3, 5, 2, 4, 3]
        var beat = 0
        for chapter in chapters {
            let chapterStart = spreads.count
            var queue = chapter
            var bucket: [CollagePhotoRef] = []
            // 和这个跨页里已有的两张都是同地同姿势：顺延到下一个跨页（仍在本章内）。
            var deferred: [CollagePhotoRef] = []
            func closeBucket() {
                guard !bucket.isEmpty else { return }
                // 只剩一张不能当多图版式解：单格会被拉满整个 2:1 跨页，竖图只剩一条、脸压中缝。
                spreads.append(Spread(kind: bucket.count == 1 ? .solo : .grid, photos: bucket))
                bucket = []
                beat += 1
                queue = deferred + queue
                deferred = []
            }
            while !queue.isEmpty || !deferred.isEmpty {
                if queue.isEmpty {
                    if bucket.isEmpty {
                        queue = deferred
                        deferred = []
                    } else {
                        closeBucket()
                    }
                    continue
                }
                let p = queue.removeFirst()
                if heroes.contains(p.id) {
                    closeBucket()
                    if p.isPortrait, let next = queue.first, next.isPortrait, !heroes.contains(next.id) {
                        queue.removeFirst()
                        spreads.append(Spread(kind: .pair, photos: [p, next]))
                    } else {
                        spreads.append(Spread(kind: .solo, photos: [p]))
                    }
                    continue
                }
                let neighbours = similar[p.id] ?? []
                let same = bucket.filter { neighbours.contains($0.id) }.count
                if same >= 2 {
                    deferred.append(p)
                    continue
                }
                bucket.append(p)
                if bucket.count >= min(maxPerSpread, rhythm[beat % rhythm.count]) { closeBucket() }
            }
            if !bucket.isEmpty {
                // 剩一张：并进本章最后一个多张跨页（还有空位、且不会和那页两张以上同姿势 ——
                // 否则等于把刚顺延出去的那张又塞回去），否则自成单张。
                let neighbours = bucket.count == 1 ? (similar[bucket[0].id] ?? []) : []
                if bucket.count == 1,
                   let j = spreads.indices.last(where: { $0 >= chapterStart && spreads[$0].kind == .grid && spreads[$0].photos.count < maxPerSpread }),
                   spreads[j].photos.filter({ neighbours.contains($0.id) }).count < 2 {
                    spreads[j].photos.append(contentsOf: bucket)
                } else {
                    spreads.append(Spread(kind: bucket.count == 1 ? .solo : .grid, photos: bucket))
                }
            }
        }
        return Plan(spreads: spreads, dropped: dropped)
    }

    /// 一个跨页的版式。grid 走求解器（和上一个跨页的结构不同），其余走固定版。
    static func layout(_ spread: Spread, previousSignature: String, context: CollageLayout.Context,
                       seed: UInt64) -> CollageNode {
        if let info = spread.fineArt { return CollageStyleFineArt.layout(spread, info: info, context: context) }
        switch spread.kind {
        case .opener:
            var cell = CollageCell.photo(spread.photos[0].id, role: .hero)
            cell.contain = true
            var title = CollageTemplates.verticalTitle(size: 0.075, seal: "拾光")
            title.alignH = .center
            title.alignV = .center
            return CollageTemplates.row(0.5, CollageTemplates.text(title), .leaf(cell))
        case .pair:
            var a = CollageCell.photo(spread.photos[0].id)
            a.contain = true
            var b = CollageCell.photo(spread.photos.count > 1 ? spread.photos[1].id : nil)
            b.contain = true
            return CollageTemplates.row(0.5, .leaf(a), .leaf(b))
        case .solo:
            let p = spread.photos[0]
            // 横图铺满整个跨页只在平铺对裱时做：胶装、锁线的书脊会吃掉中间一条。
            if p.aspect >= 1.4, context.canvas.allowsCrossFold {
                var cell = CollageCell.photo(p.id, role: .hero)
                cell.framing = .full
                let root = CollageNode.leaf(cell)
                let scored = CollageLayout.score(root, m: nil, context: context)
                if scored.seamFaces == 0, scored.cutFaces == 0 { return root }
            }
            var cell = CollageCell.photo(p.id, role: .hero)
            cell.contain = true
            var caption = CollageText(lines: [
                CollageTextLine("{date_cn_full}", font: .songti, weight: .light, size: 0.022, color: .warmGrey),
            ], vertical: true, alignH: .center, alignV: .center)
            caption.seal = CollageSeal(text: "光", color: .seal, size: 0.025)
            return CollageTemplates.row(0.5, CollageTemplates.text(caption), .leaf(cell))
        case .grid:
            let results = CollageLayout.solve(CollageLayout.Request(photos: spread.photos, context: context,
                                                                    tries: 12000, keep: 12, seed: seed))
            if let chosen = results.first(where: { $0.signature != previousSignature }) ?? results.first {
                return chosen.root
            }
            // 求解器兜底放宽后仍然无解（理论上不会）：绝不能返回空页把照片弄丢。
            if spread.photos.count == 2 { return layout(Spread(kind: .pair, photos: spread.photos),
                                                        previousSignature: previousSignature, context: context, seed: seed) }
            return fallbackRow(spread.photos, context: context)
        }
    }

    /// 一字排开再按原比例贴合：任何张数都有解。
    static func fallbackRow(_ photos: [CollagePhotoRef], context: CollageLayout.Context) -> CollageNode {
        guard var node = photos.last.map({ CollageNode.leaf(.photo($0.id)) }) else { return .leaf(CollageCell(kind: .photo)) }
        for p in photos.dropLast().reversed() {
            node = .split(.row, 0.5, .leaf(.photo(p.id)), node)
        }
        return CollageLayout.refit(node, context: context)
    }

    static func build(_ plan: Plan, context: CollageLayout.Context, seed: UInt64 = 1) -> [CollagePage] {
        if plan.theme == .fineArt { return CollageStyleFineArt.build(plan, context: context) }
        var pages: [CollagePage] = []
        var previous = ""
        for (i, spread) in plan.spreads.enumerated() {
            let root = layout(spread, previousSignature: previous, context: context, seed: seed &+ UInt64(i))
            previous = root.signature
            pages.append(CollagePage(root: root))
        }
        return pages
    }
}
