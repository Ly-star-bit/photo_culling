import Foundation
import CoreGraphics
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 主体蒙版（人物挡字、抠图、封面取景的头顶）：Vision 前景实例分割（系统「抠出主体」同一个模型）在 1024 预览上算，
/// 按人脸框挑实例（没有人脸取全部），generateScaledMaskForImage 出和预览一样大的软边蒙版，存 8 位灰度。
///
/// - 和人脸框、Hints 同一个坐标：转正后的照片、左上原点、归一化 —— 不用换算。
/// - 软边留着（头发丝那一圈是半透明的）：字透过发丝看得见，不是一刀切。
/// - 磁盘缓存 `<工程目录>/collage_masks/<sha1(路径|宽x高|修改时间|大小|maskVersion)>.png`（+ `.labels.png` 原始实例
///   标签图、`.json` 记选了哪几个实例、用的人脸框、覆盖率、头顶、主体以外的人）；内存里 NSCache。批量页清旧场次时一起清。
/// - 同一张预览上顺手找主体以外的人（`Mask.people`，K1 起）：封面字把他们当障碍躲开。
/// - 渲染要用就同步拿（内存 → 磁盘 → 现算，一张 70–100 ms —— 其中找别的人约 50 ms，第一次加载模型 ~0.2 s）：后台预热只是先填好，
///   出图不等它、也不靠它 —— 不然预览和导出、两次出图会因为算到第几张而不同。
enum CollageMasks {
    /// 改了请求、挑实例的规矩、头顶的算法就 +1：旧的磁盘缓存自动作废。
    /// 2（K1）：多存主体以外的人（people）；旧缓存没有这一项，读出来会当成「没有别人」，所以要作废。
    /// 3（审查）：找别的人多跑一遍 3×3 小块的人体姿态（poseFineTiles）；旧缓存里的 people 漏了远处的小人，作废重算。
    static let maskVersion = 3

    /// 抠图（格子、散落贴纸）的已知限制，检视器开关下面那一行。系统的主体分割把半透明的纱当成不透明的人
    /// （photot 里头纱那一片蒙版几乎全是 1），纱后面的柱子、房梁就跟着一起抠出来；连在人身上的路人、人靠着的石栏杆
    /// （7221 袖子边上一块）也没有单独的实例。
    /// 按颜色自动去掉试过（S3 Fixes round 2，五种做法）：去得掉纱的那几种，红、棕背景前的手和暖光下的米白袖子也会一起
    /// 被去掉；不伤手和袖子的那种又几乎去不掉纱 —— 没做，先在检视器里说清楚。
    static let cutoutCaveat = "半透明的头纱、披帛会连着后面的背景一起抠出来，贴着人的路人、人靠着或碰着的东西（栏杆、柱子、椅背）"
        + "也可能带进来（系统主体分割当它们是人）；白底上看得出时换一张照片，或关掉抠图"

    /// 一张照片的蒙版。像素一份常驻（量遮挡逐点取值），CGImage 给抠图用。
    final class Mask: @unchecked Sendable {
        /// 磁盘上的文件名（不带扩展名）。
        let key: String
        let image: CGImage
        let pixels: [UInt8]
        let width: Int
        let height: Int
        /// ≥ 0.5 的像素占整张多少。
        let coverage: Double
        /// 每张脸（photo.faces 里的有效框，同顺序）的头顶：脸横向范围里蒙版最上面那一行（归一化 y）；没找到 = −1。
        let headTop: [Double]
        /// 前景实例一共几个、挑了哪几个（1 起）。
        let instances: Int
        let selected: [Int]
        /// 主体以外的人（照片坐标、左上原点、归一化的框 [x0, y0, x1, y1]）：封面字当障碍躲开。见 otherPeople。
        let people: [[Double]]
        /// 这次拿到它花了多久（现算 = Vision + 写盘；从磁盘读 = 读的时间）。
        let millis: Double
        let fromDisk: Bool
        /// 蒙版内容的指纹（像素 + 尺寸 + 挑了哪几个实例）：切图 alpha、抠图格的亮度网格按它缓存。key 是磁盘文件名，
        /// 不管人脸框（脸换了重挑实例，文件名不变），合成的蒙版 key 全叫 "synthetic" —— 都不能拿来当缓存键。
        let signature: String

        init(key: String, image: CGImage, pixels: [UInt8], width: Int, height: Int, coverage: Double,
             headTop: [Double], instances: Int, selected: [Int], millis: Double, fromDisk: Bool,
             people: [[Double]] = []) {
            self.key = key
            self.image = image
            self.pixels = pixels
            self.width = width
            self.height = height
            self.coverage = coverage
            self.headTop = headTop
            self.instances = instances
            self.selected = selected
            self.people = people
            self.millis = millis
            self.fromDisk = fromDisk
            var sha = Insecure.SHA1()
            sha.update(data: Data("\(width)x\(height)|\(selected)|".utf8))
            pixels.withUnsafeBytes { sha.update(bufferPointer: $0) }
            signature = sha.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// 归一化照片坐标上的蒙版值 0…1（双线性；出了照片 = 0）。
        func value(u: Double, v: Double) -> Double {
            guard u >= 0, v >= 0, u <= 1, v <= 1, width > 1, height > 1 else { return 0 }
            let x = min(Double(width - 1), max(0, u * Double(width) - 0.5))
            let y = min(Double(height - 1), max(0, v * Double(height) - 0.5))
            let x0 = Int(x)
            let y0 = Int(y)
            let x1 = min(width - 1, x0 + 1)
            let y1 = min(height - 1, y0 + 1)
            let fx = x - Double(x0)
            let fy = y - Double(y0)
            let a = Double(pixels[y0 * width + x0])
            let b = Double(pixels[y0 * width + x1])
            let c = Double(pixels[y1 * width + x0])
            let d = Double(pixels[y1 * width + x1])
            let top = a + (b - a) * fx
            let bottom = c + (d - c) * fx
            return (top + (bottom - top) * fy) / 255
        }

        /// 主脸的头顶（没有蒙版里的头顶 = nil）。
        var primaryHeadTop: Double? {
            guard let h = headTop.first, h >= 0 else { return nil }
            return h
        }
    }

    // MARK: - 缓存

    private static let lock = NSLock()
    /// 只有一个 Vision 在算：后台预热和渲染线程同时要同一张时，后到的等前面算完直接拿。
    private static let computeLock = NSLock()
    private static var directory: URL?
    private static let memory: NSCache<NSString, Mask> = {
        let c = NSCache<NSString, Mask>()
        c.countLimit = 64
        c.totalCostLimit = 256_000_000
        return c
    }()
    /// 认不出主体的照片（不再反复跑 Vision）。
    private static var none: Set<String> = []

    /// 蒙版放哪（拼图工程旁边的 collage_masks/）；nil = 只放内存。CollageStore.attach、命令行开场设。
    static func setDirectory(_ url: URL?) {
        lock.lock()
        directory = url
        lock.unlock()
    }

    static var currentDirectory: URL? {
        lock.lock()
        defer { lock.unlock() }
        return directory
    }

    /// 内存键：文件 + 尺寸 + 人脸框（挑实例按人脸，脸换了就要重挑）。
    private static func memoryKey(_ photo: CollagePhotoRef) -> String {
        CollageVision.cacheKey(photo) + "|" + faceSignature(photo)
    }

    private static func faceSignature(_ photo: CollagePhotoRef) -> String {
        photo.faces.filter(CollageCrop.isValidBox)
            .map { $0.map { String(format: "%.4f", $0) }.joined(separator: ",") }.joined(separator: ";")
    }

    /// 磁盘键（C3 §4）：sha1(路径 | 转正宽x高 | 修改时间 | 大小 | maskVersion)。文件读不到 stamp 时只按路径和尺寸。
    static func diskKey(_ photo: CollagePhotoRef) -> String {
        let stamp = ImageLoader.FileStamp.of(URL(fileURLWithPath: photo.path))
        let raw = "\(photo.path)|\(photo.width)x\(photo.height)|\(stamp.map { String(format: "%.3f", $0.mtime) } ?? "-")|"
            + "\(stamp?.size ?? -1)|\(maskVersion)"
        return Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 已经有的（内存或磁盘），不现算。
    static func cachedMask(for photo: CollagePhotoRef) -> Mask? {
        let mk = memoryKey(photo)
        lock.lock()
        let hit = memory.object(forKey: mk as NSString)
        lock.unlock()
        if let hit { return hit }
        guard let disk = loadFromDisk(photo) else { return nil }
        lock.lock()
        memory.setObject(disk, forKey: mk as NSString, cost: disk.pixels.count * 2)
        lock.unlock()
        return disk
    }

    /// 问 mask(for:) 会不会现算：内存、磁盘里有，或者已经知道认不出主体 = 不会（画布的角标在主线程上问之前先看它）。
    static func isSettled(_ photo: CollagePhotoRef) -> Bool {
        let mk = memoryKey(photo)
        lock.lock()
        let known = memory.object(forKey: mk as NSString) != nil || none.contains(mk)
        lock.unlock()
        return known || cachedMask(for: photo) != nil
    }

    /// 渲染、封面取景、遮挡判定用的那一份：内存 → 磁盘 → 现算（同步）。nil = 这张照片认不出主体。
    static func mask(for photo: CollagePhotoRef) -> Mask? {
        let mk = memoryKey(photo)
        lock.lock()
        let hit = memory.object(forKey: mk as NSString)
        let known = none.contains(mk)
        lock.unlock()
        if let hit { return hit }
        if known { return nil }
        computeLock.lock()
        defer { computeLock.unlock() }
        // 等锁的时候别人可能已经算好了。
        lock.lock()
        let again = memory.object(forKey: mk as NSString)
        let knownNow = none.contains(mk)
        lock.unlock()
        if let again { return again }
        if knownNow { return nil }
        let found = loadFromDisk(photo) ?? compute(photo)
        lock.lock()
        if let found {
            memory.setObject(found, forKey: mk as NSString, cost: found.pixels.count * 2)
        } else {
            none.insert(mk)
        }
        lock.unlock()
        return found
    }

    /// 进拼图 tab 时先跑一次空请求：第一次加载模型要 0.1–1 秒，别让它落在第一次出图上。
    static func warmUp() {
        lock.lock()
        let first = !warmed
        warmed = true
        lock.unlock()
        guard first else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CollageRender.srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return }
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            guard let image = ctx.makeImage() else { return }
            let request = VNGenerateForegroundInstanceMaskRequest()
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    private static var warmed = false

    /// 自测用：把合成的蒙版（nil = 认不出主体）放进内存缓存，之后 mask(for:) 直接拿它（不跑 Vision、不读盘）。
    static func inject(_ mask: Mask?, for photo: CollagePhotoRef) {
        let mk = memoryKey(photo)
        lock.lock()
        if let mask {
            memory.setObject(mask, forKey: mk as NSString, cost: mask.pixels.count * 2)
            none.remove(mk)
        } else {
            memory.removeObject(forKey: mk as NSString)
            none.insert(mk)
        }
        lock.unlock()
    }

    /// 自测用：从一张合成的灰度图（0…255，左上原点）建蒙版，头顶、覆盖率照真的算；people = 主体以外的人（合成的框）。
    static func synthetic(_ pixels: [UInt8], width: Int, height: Int, faces: [[Double]],
                          people: [[Double]] = []) -> Mask? {
        guard let image = grayImage(pixels, width: width, height: height) else { return nil }
        let heads = faces.filter(CollageCrop.isValidBox).map { headTop(pixels, width: width, height: height, face: $0) }
        return Mask(key: "synthetic", image: image, pixels: pixels, width: width, height: height,
                    coverage: coverage(pixels), headTop: heads, instances: 1, selected: [1], millis: 0, fromDisk: false,
                    people: people.filter(CollageCrop.isValidBox))
    }

    /// 测试用：把内存里的全清掉（磁盘的不动）。
    static func purgeMemory() {
        lock.lock()
        memory.removeAllObjects()
        none.removeAll()
        lock.unlock()
    }

    // MARK: - 现算

    /// Vision 前景实例 → 按人脸挑实例 → 预览尺寸的软边蒙版（8 位）。
    static func compute(_ photo: CollagePhotoRef, writeToDisk: Bool = true) -> Mask? {
        let t0 = Date()
        guard let preview = CollageImages.preview(photo, need: ImageLoader.previewMaxPixel) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: preview, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first,
              !obs.allInstances.isEmpty else { return nil }
        let labels = labelMap(obs.instanceMask)
        let faces = photo.faces.filter(CollageCrop.isValidBox)
        let chosen = chooseInstances(labels: labels, faces: faces, all: Array(obs.allInstances))
        guard let buffer = try? obs.generateScaledMaskForImage(forInstances: IndexSet(chosen), from: handler),
              let soft = bytes(of: buffer) else { return nil }
        guard let image = grayImage(soft.pixels, width: soft.width, height: soft.height) else { return nil }
        let heads = faces.map { headTop(soft.pixels, width: soft.width, height: soft.height, face: $0) }
        let cover = coverage(soft.pixels)
        let people = otherPeople(preview: preview, handler: handler, labels: labels, chosen: chosen,
                                 all: Array(obs.allInstances), subject: soft, faces: faces)
        let key = diskKey(photo)
        let ms = Date().timeIntervalSince(t0) * 1000
        let mask = Mask(key: key, image: image, pixels: soft.pixels, width: soft.width, height: soft.height,
                        coverage: cover, headTop: heads, instances: obs.allInstances.count, selected: chosen,
                        millis: ms, fromDisk: false, people: people)
        if writeToDisk { save(mask, labels: labels, photo: photo) }
        return mask
    }

    /// 实例标签图（低分辨率，左上原点，0 = 背景）。
    private static func labelMap(_ buffer: CVPixelBuffer) -> (pixels: [UInt8], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return ([], 0, 0) }
        var out = [UInt8](repeating: 0, count: w * h)
        let src = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w { out[y * w + x] = src[y * stride + x] }
        }
        return (out, w, h)
    }

    /// 挑实例：落在人脸框里的标签（占脸框 15% 以上的都要；都不到就要占得最多的那个）；没有脸、脸框里一个
    /// 实例都没有 = 全部。photot 7228 下半身连着栏杆是另一个实例 —— 按脸挑就不会把栏杆当成人。
    static func chooseInstances(labels: (pixels: [UInt8], width: Int, height: Int), faces: [[Double]],
                                all: [Int]) -> [Int] {
        guard !faces.isEmpty, labels.width > 0, labels.height > 0 else { return all }
        var picked = Set<Int>()
        var bestLabel = 0
        var bestCount = 0
        for f in faces {
            let x0 = max(0, Int(f[0] * Double(labels.width)))
            let x1 = min(labels.width, Int((f[2] * Double(labels.width)).rounded(.up)))
            let y0 = max(0, Int(f[1] * Double(labels.height)))
            let y1 = min(labels.height, Int((f[3] * Double(labels.height)).rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            var counts: [Int: Int] = [:]
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let l = Int(labels.pixels[y * labels.width + x])
                    if l > 0 { counts[l, default: 0] += 1 }
                }
            }
            let area = (x1 - x0) * (y1 - y0)
            for (l, n) in counts {
                if Double(n) >= 0.15 * Double(area) { picked.insert(l) }
                if n > bestCount || (n == bestCount && l < bestLabel) {
                    bestCount = n
                    bestLabel = l
                }
            }
        }
        if picked.isEmpty, bestCount > 0 { picked.insert(bestLabel) }
        let valid = picked.filter { all.contains($0) }
        return valid.isEmpty ? all : valid.sorted()
    }

    // MARK: - 主体以外的人

    /// 姿态分块：预览上 2×2 块、每块 0.6 边长（相邻两块压着 0.2，块缝上的人总有一块是整的）。
    static let poseTiles: [CGRect] = [0.0, 0.4].flatMap { y in
        [0.0, 0.4].map { x in CGRect(x: x, y: y, width: 0.6, height: 0.6) }
    }
    /// 再细一层：3×3 块、每块 0.4 边长（相邻两块压着 0.1）。远处的小人（photot 7213、7214 刊头 NG 底下桥头那一群、
    /// 桥顶上的人：预览上 20–30 px 宽）在 0.6 的块里太小认不出，放大到 0.4 才认得出；2×2 那一遍照旧先跑、找到的框不变。
    static let poseFineTiles: [CGRect] = [0.0, 0.3, 0.6].flatMap { y in
        [0.0, 0.3, 0.6].map { x in CGRect(x: x, y: y, width: 0.4, height: 0.4) }
    }
    /// 姿态点置信度下限；一个人至少认出几个点才算（photot 7232 的红马甲只认得出两肩、脖子、一只耳朵）。
    static let poseConfidence: Float = 0.3
    static let poseMinJoints = 4
    /// 小块上要多认出几个点：块越小越容易把屋脊兽、石雕认成人（photot 7224 屋脊上的脊兽 5 个点；
    /// 小块认出来的真人都在 6 个点以上，7225 栏杆下面的背影正好 6 个）。
    static let poseFineMinJoints = 6

    /// 主体以外的人（照片坐标框），封面字当障碍躲开。同一张预览上找三样：
    /// 1. 人体框（VNDetectHumanRectanglesRequest，全身模式，和蒙版同一个 handler）；
    /// 2. 人体姿态（VNDetectHumanBodyPoseRequest）在 poseTiles 4 块上各跑一次：背对镜头、虚掉、被墙挡掉半截的路人整张跑
    ///    什么都认不出（photot 7232 右栏那儿的红马甲、7227 右边的男人：前景实例只有主体一个，人体框全身 / 上半身、人物分割、
    ///    整张的姿态都没有他们），放大一块才认得出肩膀和耳朵。4 块一共 25 ms 左右。之后再在 poseFineTiles 9 块上跑一遍
    ///    （至少 poseFineMinJoints 个点）：远处的小人 2×2 的块里也太小（7213、7214 刊头 NG 底下桥头那一群，人体框、
    ///    前景实例、2×2 的姿态都没有），9 块一共 45 ms 左右；
    /// 3. 前景实例里没挑中的那几个：只在和 1、2 找到的人对得上（实例框有三成以上落在那个人的框里）时才算人，记实例自己的框
    ///    （贴得更紧）—— 没挑中的实例常常不是人（photot 7228 没挑中的是连着栏杆的下半身）。
    /// 主体本人不算：框里有主体的脸、或者框（姿态按那几个点）一半以上落在主体蒙版上。同一个人几处都报了（中心落在已有的框里）
    /// 只记一次。只给封面字摆位用（CollageOverlays.CleanType），不进取景、不进挑片。
    static func otherPeople(preview: CGImage, handler: VNImageRequestHandler,
                            labels: (pixels: [UInt8], width: Int, height: Int), chosen: [Int], all: [Int],
                            subject: (pixels: [UInt8], width: Int, height: Int), faces: [[Double]]) -> [[Double]] {
        func onSubject(_ x: Double, _ y: Double) -> Bool {
            guard subject.width > 0, subject.height > 0, x >= 0, y >= 0, x < 1, y < 1 else { return false }
            let px = min(subject.width - 1, Int(x * Double(subject.width)))
            let py = min(subject.height - 1, Int(y * Double(subject.height)))
            return subject.pixels[py * subject.width + px] >= 128
        }
        func center(_ b: [Double]) -> (Double, Double) { ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2) }
        func contains(_ b: [Double], _ p: (Double, Double)) -> Bool {
            p.0 >= b[0] && p.0 <= b[2] && p.1 >= b[1] && p.1 <= b[3]
        }
        func isSubject(_ b: [Double]) -> Bool {
            if faces.contains(where: { contains(b, center($0)) }) { return true }
            var on = 0
            for j in 0..<8 {
                for i in 0..<8 {
                    let x: Double = b[0] + (Double(i) + 0.5) / 8 * (b[2] - b[0])
                    let y: Double = b[1] + (Double(j) + 0.5) / 8 * (b[3] - b[1])
                    if onSubject(x, y) { on += 1 }
                }
            }
            return on >= 32
        }
        var found: [[Double]] = []
        func add(_ b: [Double]) {
            let c = center(b)
            guard CollageCrop.isValidBox(b), !found.contains(where: { contains($0, c) }) else { return }
            found.append(b)
        }
        // 1. 人体框（全身模式）。
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        try? handler.perform([bodies])
        for o in bodies.results ?? [] {
            let r = o.boundingBox
            let b = [Double(r.minX), Double(1 - r.maxY), Double(r.maxX), Double(1 - r.minY)].map { min(1, max(0, $0)) }
            if !isSubject(b) { add(b) }
        }
        // 2. 人体姿态，分块跑：先 2×2（找到的框和以前一样），再 3×3 小块补远处的小人（中心落在已有框里的不重复记）。
        let w = Double(preview.width)
        let h = Double(preview.height)
        func poses(_ tiles: [CGRect], minJoints: Int) {
            for t in tiles {
                let cx: Double = (Double(t.minX) * w).rounded()
                let cy: Double = (Double(t.minY) * h).rounded()
                let cw: Double = (Double(t.width) * w).rounded()
                let ch: Double = (Double(t.height) * h).rounded()
                let crop = CGRect(x: cx, y: cy, width: cw, height: ch)
                guard crop.width > 16, crop.height > 16, let tile = preview.cropping(to: crop) else { continue }
                let pose = VNDetectHumanBodyPoseRequest()
                try? VNImageRequestHandler(cgImage: tile, options: [:]).perform([pose])
                for o in pose.results ?? [] {
                    guard let points = try? o.recognizedPoints(.all) else { continue }
                    var joints: [Joint] = []
                    for (name, p) in points where p.confidence >= poseConfidence {
                        // 块里归一化、左下原点 → 预览像素、左上原点。
                        let x: Double = Double(crop.minX) + Double(p.location.x) * Double(crop.width)
                        let y: Double = Double(crop.minY) + (1 - Double(p.location.y)) * Double(crop.height)
                        joints.append(Joint(name: name, x: x, y: y))
                    }
                    guard joints.count >= minJoints else { continue }
                    // 主体自己（块把主体切成半个人也认得出）：一半以上的点在蒙版上，或者有点落在主体的脸框里。
                    let onBody = joints.filter { onSubject($0.x / w, $0.y / h) }.count
                    if 2 * onBody >= joints.count { continue }
                    if joints.contains(where: { j in faces.contains { contains($0, (j.x / w, j.y / h)) } }) { continue }
                    if let b = poseBox(joints, width: w, height: h) { add(b) }
                }
            }
        }
        poses(poseTiles, minJoints: poseMinJoints)
        poses(poseFineTiles, minJoints: poseFineMinJoints)
        // 3. 没挑中的前景实例：和上面认出来的人对得上才算。
        for l in all where !chosen.contains(l) {
            guard let ib = labelBox(labels, label: l) else { continue }
            let area: Double = (ib[2] - ib[0]) * (ib[3] - ib[1])
            let matched = found.contains { b in
                let ix: Double = max(0, min(ib[2], b[2]) - max(ib[0], b[0]))
                let iy: Double = max(0, min(ib[3], b[3]) - max(ib[1], b[1]))
                return ix * iy >= 0.3 * area
            }
            // 不按中心去重：实例框比姿态估的框贴，两个都留着（量的时候按点落没落在任何一个框里算，叠着的不重复算）。
            if matched, CollageCrop.isValidBox(ib) { found.append(ib) }
        }
        return found
    }

    struct Joint {
        var name: VNHumanBodyPoseObservation.JointName
        var x: Double
        var y: Double
    }

    /// 姿态点（预览像素）→ 人的框（归一化）。s = 身体的尺度（两肩距离、点的宽、点的高的一半里最大的）；
    /// 头顶在最上面那个点上面 0.45s（认出了鼻子、眼、耳）或 s（只认出肩膀以下）；下面：只认出肩膀以上就往下延 1.2s
    /// （躯干在、只是没认出来：7232 的红马甲），认出了胯、膝、脚踝的只延 0.3s（下面没认出来的腿多半被挡住了：
    /// 桥上的人腿在桥栏后面，延长了会把封面字从桥上空着的石头上赶走）；左右各放 0.4s。估的框宁大勿小。
    static func poseBox(_ joints: [Joint], width: Double, height: Double) -> [Double]? {
        let xs = joints.map(\.x)
        let ys = joints.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), width > 0, height > 0
        else { return nil }
        var s: Double = max(x1 - x0, 0.5 * (y1 - y0), 0.012 * max(width, height))
        if let l = joints.first(where: { $0.name == .leftShoulder }),
           let r = joints.first(where: { $0.name == .rightShoulder }) {
            s = max(s, hypot(l.x - r.x, l.y - r.y))
        }
        let head: Set<VNHumanBodyPoseObservation.JointName> = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
        let hasHead = joints.contains { head.contains($0.name) }
        let lower: Set<VNHumanBodyPoseObservation.JointName> = [.root, .leftHip, .rightHip, .leftKnee, .rightKnee,
                                                                 .leftAnkle, .rightAnkle]
        let hasLower = joints.contains { lower.contains($0.name) }
        let top: Double = y0 - (hasHead ? 0.45 : 1.0) * s
        let bottom: Double = y1 + (hasLower ? 0.3 : 1.2) * s
        let left: Double = x0 - 0.4 * s
        let right: Double = x1 + 0.4 * s
        return [left / width, top / height, right / width, bottom / height].map { min(1, max(0, $0)) }
    }

    /// 标签图里某个实例的外框（归一化、左上原点）；没有这个标签 = nil。
    static func labelBox(_ labels: (pixels: [UInt8], width: Int, height: Int), label: Int) -> [Double]? {
        guard labels.width > 0, labels.height > 0 else { return nil }
        var x0 = labels.width
        var y0 = labels.height
        var x1 = -1
        var y1 = -1
        for y in 0..<labels.height {
            let row = y * labels.width
            for x in 0..<labels.width where Int(labels.pixels[row + x]) == label {
                x0 = min(x0, x)
                y0 = min(y0, y)
                x1 = max(x1, x)
                y1 = max(y1, y)
            }
        }
        guard x1 >= x0, y1 >= y0 else { return nil }
        return [Double(x0) / Double(labels.width), Double(y0) / Double(labels.height),
                Double(x1 + 1) / Double(labels.width), Double(y1 + 1) / Double(labels.height)]
    }

    /// generateScaledMaskForImage 给的是 Float32 单通道：转成 0…255。
    private static func bytes(of buffer: CVPixelBuffer) -> (pixels: [UInt8], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = (base + y * stride).assumingMemoryBound(to: Float32.self)
                for x in 0..<w {
                    let v = Double(row[x]) * 255
                    out[y * w + x] = UInt8(max(0, min(255, v.rounded())))
                }
            }
        case kCVPixelFormatType_OneComponent8:
            let src = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w { out[y * w + x] = src[y * stride + x] }
            }
        default:
            return nil
        }
        return (out, w, h)
    }

    /// 头顶：这张脸横向范围里，从上往下第一行「够实」的蒙版（≥ 0.5 的像素至少占这段宽的 3%、至少 2 个）。
    /// 只往脸框上面找 1.5 张脸高（高发髻、头饰算头；再往上连着的举手、伞不算），找到的是那一行的上沿。
    static func headTop(_ pixels: [UInt8], width: Int, height: Int, face f: [Double]) -> Double {
        guard width > 0, height > 0 else { return -1 }
        let x0 = max(0, Int(f[0] * Double(width)))
        let x1 = min(width, Int((f[2] * Double(width)).rounded(.up)))
        let fh = f[3] - f[1]
        let top = max(0, Int(((f[1] - 1.5 * fh) * Double(height)).rounded(.down)))
        let mid = min(height, Int((((f[1] + f[3]) / 2) * Double(height)).rounded(.up)))
        guard x1 > x0, mid > top else { return -1 }
        let need = max(2, Int(Double(x1 - x0) * 0.03))
        for y in top..<mid {
            var n = 0
            let row = y * width
            for x in x0..<x1 where pixels[row + x] >= 128 { n += 1 }
            if n >= need { return Double(y) / Double(height) }
        }
        return -1
    }

    private static func coverage(_ pixels: [UInt8]) -> Double {
        guard !pixels.isEmpty else { return 0 }
        var n = 0
        for v in pixels where v >= 128 { n += 1 }
        return Double(n) / Double(pixels.count)
    }

    static func grayImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - 磁盘

    private struct Record: Codable {
        var maskVersion: Int
        var path: String
        var width: Int
        var height: Int
        var maskSize: [Int]
        var instances: Int
        var selected: [Int]
        var faces: String
        var coverage: Double
        var headTop: [Double]
        var people: [[Double]]
    }

    private static func files(_ key: String) -> (mask: URL, labels: URL, json: URL)? {
        guard let dir = currentDirectory else { return nil }
        return (dir.appendingPathComponent(key + ".png"), dir.appendingPathComponent(key + ".labels.png"),
                dir.appendingPathComponent(key + ".json"))
    }

    private static func save(_ mask: Mask, labels: (pixels: [UInt8], width: Int, height: Int), photo: CollagePhotoRef) {
        guard let f = files(mask.key) else { return }
        try? FileManager.default.createDirectory(at: f.mask.deletingLastPathComponent(), withIntermediateDirectories: true)
        writePNG(mask.image, to: f.mask)
        if let l = grayImage(labels.pixels, width: labels.width, height: labels.height) { writePNG(l, to: f.labels) }
        let record = Record(maskVersion: maskVersion, path: photo.path, width: photo.width, height: photo.height,
                            maskSize: [mask.width, mask.height], instances: mask.instances, selected: mask.selected,
                            faces: faceSignature(photo), coverage: mask.coverage, headTop: mask.headTop,
                            people: mask.people)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(record) { try? data.write(to: f.json, options: .atomic) }
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }

    /// 8 位灰度 PNG 读回原样的字节（不经过颜色转换：画进灰度画布会按 PNG 带的灰度曲线换算，值会变）。
    private static func rawGray(_ image: CGImage) -> [UInt8]? {
        let w = image.width
        let h = image.height
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 8, let data = image.dataProvider?.data,
              let base = CFDataGetBytePtr(data) else { return nil }
        let stride = image.bytesPerRow
        guard CFDataGetLength(data) >= stride * (h - 1) + w else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { out[y * w + x] = base[y * stride + x] }
        }
        return out
    }

    /// 磁盘上有、版本和人脸框都对得上才认（缓存是派生数据，不对就重算，从不当真）。
    private static func loadFromDisk(_ photo: CollagePhotoRef) -> Mask? {
        let t0 = Date()
        let key = diskKey(photo)
        guard let f = files(key), let data = try? Data(contentsOf: f.json),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.maskVersion == maskVersion, record.faces == faceSignature(photo),
              let source = CGImageSourceCreateWithURL(f.mask as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width
        let h = image.height
        guard let pixels = rawGray(image), let gray = grayImage(pixels, width: w, height: h) else { return nil }
        let ms = Date().timeIntervalSince(t0) * 1000
        return Mask(key: key, image: gray, pixels: pixels, width: w, height: h, coverage: record.coverage,
                    headTop: record.headTop, instances: record.instances, selected: record.selected, millis: ms,
                    fromDisk: true, people: record.people.filter(CollageCrop.isValidBox))
    }

    /// 这张照片的蒙版文件在哪（maskdump 打印；没有目录 = nil）。
    static func file(for photo: CollagePhotoRef) -> URL? {
        files(diskKey(photo))?.mask
    }
}
