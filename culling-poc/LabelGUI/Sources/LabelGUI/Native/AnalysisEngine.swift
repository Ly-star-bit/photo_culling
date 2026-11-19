import Foundation
import CoreGraphics

/// Native replacement for prepare.py + layer1.py. Produces the exact same
/// artifacts (data/previews/*.jpg, data/manifest.json, data/layer1_results.json,
/// snake_case keys, relative preview paths) so layer2.py (VLM) and the existing
/// GUI loaders keep working unchanged — and so native results can be
/// diffed against the Python pipeline's on the same photos.
enum AnalysisEngine {
    struct PhotoAnalysis: Sendable {
        let id: String
        let rawPath: String
        /// The JPEG half of a RAW+JPEG pair (or the file itself) — the fast,
        /// identical-looking decode source for on-demand full-res viewing.
        let decodePath: String
        let previewRelPath: String
        let captureTime: Date?
        /// Sub-second part of the capture time (0 when the camera didn't write
        /// SubSecTimeOriginal) — orders same-second burst frames deterministically.
        let captureSubsec: Double
        let cameraModel: String?
        /// 机身序列号（读不到 = nil）：同型号的两台机身靠它分开（近似重复、场都按机身分）。
        let bodySerial: String?
        let shutterSec: Double?
        let aperture: Double?
        let iso: Int?
        let focal35: Int?
        let lensModel: String?
        let horizonDeg: Double?
        let phash: UInt64
        let faceFound: Bool
        let eyeClosed: Bool?
        let eyeAspectRatio: Double?
        let faceQuality: Double?
        let subjectFaceCount: Int
        /// Primary face padded bbox [x0, y0, x1, y1], normalized top-left origin.
        let faceBbox: [Double]?
        /// Primary face's UNPADDED area fraction — 景别 signal for the verdict layer.
        let faceAreaPct: Double?
        /// Every subject face's bbox + eye state + raw EAR + area, for the
        /// face-crop strip and the dynamic (burst-relative) eye verdicts.
        let subjectFaces: [FaceAnalyzer.SubjectFace]
        let sharpness: Double
        let sharpnessScope: String
        /// 判「虚焦」用的清晰比（Metrics.focusRatio），和 sharpness 量的是同一块。sharpness 留给排序和近似重复组里比谁更清楚。
        let focusRatio: Double
        let highlightClipPct: Double
        let shadowClipPct: Double
        /// 同一个裁切口径，只数主体区域（主体脸扩到头 + 上半身的并集）；没有脸、或者人在画面里太小
        /// （FaceAnalyzer.minSubjectRegionShare）= 整张。判决用这两个 ——
        /// 屋檐下的死黑背景不该把曝光正常的人像判废（DSCF7221：整张暗部 15.3%，主体区域 2.5%）。
        let subjectHighlightClipPct: Double
        let subjectShadowClipPct: Double
        /// 主体脸的亮度中位数（0–255，几张脸合起来；没有脸 = nil）。
        let faceLuma: Double?
        /// 整张的亮度中位数和 p99 —— p99 低 = 画面里没有一处是亮的。
        let frameLuma: Double
        let frameLumaP99: Double
        let elapsedSec: Double
        /// Source file's modification time — the incremental-reuse key: same
        /// id + same mtime on the next run means the analysis is still valid.
        let srcMtime: Double?
        let srcSize: Int?
        /// JPEG 尾巴缺了（没有结束标记）：判决层带「文件损坏」直接废，不进 VLM。
        let fileCorrupt: Bool
        var burstGroup: Int = 0
    }

    static let hashThreshold = 10
    static let timeWindowSec = 2.0
    /// Bump whenever a metric's scale changes (decode size, sharpness formula,
    /// pHash construction). Old sessions carrying another version are re-analyzed
    /// instead of silently mixing two scales under one slider. Files written
    /// before this key existed are treated as version 1.
    /// 2：曝光裁切改按主体区域算，加了欠曝 / 过曝要的亮度、合影小脸的原图 EAR。
    /// 3：人脸质量改成喂 landmarks 的脸框单独算（FaceAnalyzer.analyze）—— 以前同一张图每次分析出两种分，
    ///    新分落在哪一种不固定，和老结果混在一场里组内比较就不公平。
    ///    同一版（还没发出去）里锐度也改了口径：只量眼眉带（裁回脸框），不再和嘴那块取大；sharpness_scope
    ///    从 "features" 变成 "eyes" / "mouth"。闭眼的 EAR（blink_score、faces[].ear）也改了：按两眼连线转平再量
    ///    （FaceAnalyzer.levelledEyeAspectRatio），歪着的脸读数变小（photot 歪 21–23° 的 0.51–0.55 → 0.30–0.35）。
    ///    主体曝光裁切（subject_*_clip_pct）也改了：矩形里有 ≥ 0.5% 裁切的，跑人像分割只数人（Metrics.personClipping），
    ///    白底 / 黑底 / 逆光背景不再算进来。
    /// 4：加了 focus_ratio（判虚焦的清晰比，Metrics.focusRatio，量的还是锐度那块）。3 没发过版，用户手里都是 2，
    ///    2 → 4 和 2 → 3 一样是整场重分析一回；升这一次是让开发中用 3 分析过的数据目录（没有 focus_ratio）也整场重算，
    ///    不留在「按锐度折算」的老路上（BatchStore.legacyFocus）。
    static let analysisVersion = 4

    struct Summary {
        let analyzed: Int
        /// Photos carried over unchanged from the previous run (same id + mtime,
        /// preview still on disk) — a re-analysis after adding 50 photos to a
        /// 3000-photo shoot costs seconds, not minutes.
        let reused: Int
        /// Photos that failed to decode/analyze — surfaced to the user instead of
        /// silently shrinking the set.
        let failed: [String]
        /// 解得出来、但文件是坏的（JPEG 截断）：照常进网格，带「文件损坏」判废片。
        let corrupt: [String]
        let cancelled: Bool
        /// 这一次写了预览图（previews/<id>.jpg）的照片，按文件夹顺序：分析了的（新的、改过的）和分析结果还能用、
        /// 只是预览图没了补回来的。原样复用的不在里面。界面只清这些照片的缓存（BatchStore.runAnalysis 收尾）。
        var previewsWritten: [String] = []
        /// 改了名（或挪了子文件夹）、按文件大小 + 修改时间认回原来 id 的照片（PhotoIDMemory 第三遍，EC-02），按文件夹顺序。
        var refound: [String] = []
    }

    /// Thread-safe cooperative cancellation flag shared with the UI.
    final class CancelFlag: @unchecked Sendable {
        private var flag = false
        private let lock = NSLock()
        func set() { lock.lock(); flag = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// `onPhoto` fires as EACH photo's analysis completes (from worker threads) —
    /// the GUI streams provisional results into the grid instead of staring at a
    /// progress bar for a 3000-photo shoot. Final authoritative data (with burst
    /// groups) still lands via the JSON files at the end.
    static func analyzeFolder(_ photoDir: URL, dataDir: URL,
                              cancel: CancelFlag = CancelFlag(),
                              onPhoto: (@Sendable (PhotoAnalysis) -> Void)? = nil,
                              progress: @escaping @Sendable (String) -> Void) throws -> Summary {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: photoDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "AnalysisEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "照片文件夹不存在或无法访问: \(photoDir.path) (被删除、改名或所在硬盘未挂载)"])
        }
        // 上一次的 manifest 不管哪个引擎、哪个分析版本写的都读：listPhotos 按它沿用上一次的 id（PhotoIDMemory.swift）。
        // 下面增量复用的门控只管分析数值能不能直接用；id 不跟着它走 —— 版本一升整场重分析，id 也得原样留着。
        let oldManifestData = try? Data(contentsOf: dataDir.appendingPathComponent("manifest.json"))
        let oldManifest = oldManifestData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let oldLayer1Data = try? Data(contentsOf: dataDir.appendingPathComponent("layer1_results.json"))
        let oldLayer1 = oldLayer1Data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let previousIDs = ImageLoader.PreviousIDs(manifest: oldManifest, layer1: oldLayer1, photoDir: photoDir)
        // 顶层列不出来（多半是系统隐私权限没给）就照实说、点名系统设置的开关，不再报「没有支持的图片文件」（审查 D03）。
        if let problem = ImageLoader.folderReadProblem(photoDir) {
            throw NSError(domain: "AnalysisEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        let photos = ImageLoader.listPhotos(in: photoDir, previous: previousIDs)
        guard !photos.isEmpty else {
            throw NSError(domain: "AnalysisEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "这个文件夹 (含子文件夹) 里没有支持的图片文件 (RAW/JPG/PNG/HEIC/TIFF)"])
        }

        let previewDir = dataDir.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        // --- Incremental reuse: photos already analyzed by a previous NATIVE
        // run, whose source file hasn't changed (id + mtime) and whose preview
        // still exists, keep their old JSON entries verbatim. Only the rest is
        // analyzed; burst groups are recomputed over the merged set (new
        // photos may join existing groups).
        let fm = FileManager.default
        var oldManifestByID: [String: [String: Any]] = [:]
        var oldLayer1ByID: [String: [String: Any]] = [:]
        if let mData = oldManifestData, let mJson = oldManifest,
           let mPhotos = JSONRows.objects(mJson["photos"]),
           let lData = oldLayer1Data, let lJson = oldLayer1,
           (lJson["engine"] as? String) == "native",
           (lJson["analysis_version"] as? Int ?? 1) == analysisVersion,
           let lResults = JSONRows.objects(lJson["results"]) {
            // 只复用界面读得懂的行（审查 EC-03）：按字典宽松读的话，一行字段类型不对（手改、以后改了字段类型又装回旧版本）
            // 会被当成「未变」原样抄回新 manifest，界面那边永远解不开、这一场一直空着，点「开始分析」也修不好。
            // 和 BatchStore 打开场次用同一个解码器（Photo / Layer1Result）验一遍，解不开的重新分析。
            let readableManifest = Manifest.decodablePhotoIDs(mData) ?? []
            let readableLayer1 = Layer1File.reusableIDs(lData) ?? []
            for p in mPhotos {
                if let id = p["id"] as? String, readableManifest.contains(id) { oldManifestByID[id] = p }
            }
            for r in lResults where r["error"] == nil {
                if let id = r["id"] as? String, readableLayer1.contains(id) { oldLayer1ByID[id] = r }
            }
        }

        var reusedEntries: [(id: String, manifest: [String: Any], layer1: [String: Any])] = []
        var todo: [ImageLoader.PhotoFile] = []
        var candidates: [(file: ImageLoader.PhotoFile, manifest: [String: Any], layer1: [String: Any])] = []
        for file in photos {
            let previewURL = previewDir.appendingPathComponent("\(file.stem).jpg")
            if let l1 = oldLayer1ByID[file.stem],
               var m = oldManifestByID[file.stem],
               let saved = l1["src_mtime"] as? Double,
               let current = ImageLoader.FileStamp.of(file.decodeURL),
               abs(saved - current.mtime) < 1.0,
               // Entries written before src_size existed match on mtime alone.
               (l1["src_size"] as? Int).map({ $0 == current.size }) ?? true {
                var l1 = l1
                // 旧版本分析的没查过文件完整性：补查一次尾巴（只读最后 64KB），之后就记在结果里了。
                if l1["file_corrupt"] == nil { l1["file_corrupt"] = ImageLoader.jpegTruncated(file.decodeURL) }
                // 旧版本没记机身序列号：只读文件头补上（不解码），近似重复才能按机身分开串。
                if m["body_serial"] == nil { m["body_serial"] = ImageLoader.bodySerial(of: file.decodeURL) ?? "" }
                // The analysis numbers are still valid, but the file layout may
                // not be: a RAF copied in next to an analyzed JPG makes the RAW
                // the primary (XMP goes beside it) — refresh paths every run.
                m["raw_path"] = file.primaryURL.path
                m["decode_path"] = file.decodeURL.path
                m["preview_path"] = previewURL.path
                candidates.append((file, m, l1))
            } else {
                todo.append(file)
            }
        }
        // 分析结果还有效、只是预览图没了（掉出最近 15 场被清掉的）：只重做预览，数值原样复用 —— 省时间；
        // 分析版本 3 以前人脸质量每次有点抖，整张重分析的话人工改判以外的判决可能悄悄变掉。重做失败的才整张重分析。
        let missing = candidates.indices.filter {
            !fm.fileExists(atPath: previewDir.appendingPathComponent("\(candidates[$0].file.stem).jpg").path)
        }
        var regenerated = [Bool](repeating: true, count: candidates.count)
        if !missing.isEmpty {
            progress("补回 \(missing.count) 张预览图...")
            for i in missing { regenerated[i] = false }
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: missing.count) { k in
                guard !cancel.isSet else { return }
                let c = candidates[missing[k]]
                let url = previewDir.appendingPathComponent("\(c.file.stem).jpg")
                let ok = ImageLoader.load(c.file.decodeURL).map { ImageLoader.savePreview($0.image, to: url) } ?? false
                lock.lock(); regenerated[missing[k]] = ok; lock.unlock()
            }
        }
        // 取消了：没来得及补的照样留着（分析结果不丢，只是还没预览，下次再补）。
        let keepAll = cancel.isSet
        for (i, c) in candidates.enumerated() {
            if regenerated[i] || keepAll { reusedEntries.append((c.file.stem, c.manifest, c.layer1)) } else { todo.append(c.file) }
        }
        if !reusedEntries.isEmpty {
            progress("复用 \(reusedEntries.count) 张未变照片，分析 \(todo.count) 张...")
        }

        let total = todo.count
        let counter = AtomicCounter()
        var results = [PhotoAnalysis?](repeating: nil, count: total)

        // Vision + decode are internally threaded, so a modest worker count
        // saturates the machine without exhausting memory on big folders
        // (each in-flight photo holds a ~38MB RGBA + ~38MB gray buffer).
        let workers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let queue = DispatchQueue(label: "analysis", attributes: .concurrent)
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: workers)
        let resultLock = NSLock()

        for (index, file) in todo.enumerated() {
            if cancel.isSet { break }
            semaphore.wait()
            group.enter()
            queue.async {
                defer { semaphore.signal(); group.leave() }
                if cancel.isSet { return }
                let analysis = analyzePhoto(file, previewDir: previewDir)
                resultLock.lock()
                results[index] = analysis
                resultLock.unlock()
                if let analysis { onPhoto?(analysis) }
                let done = counter.increment()
                if done % 5 == 0 || done == total {
                    progress("分析中 \(done)/\(total)...")
                }
            }
        }
        group.wait()

        var completed = results.compactMap { $0 }
        let completedIds = Set(completed.map(\.id))
        // On cancel the never-started photos are not failures; on a full run
        // anything that produced no result is.
        let cancelled = cancel.isSet
        let failed = cancelled ? [] : todo.map(\.stem).filter { !completedIds.contains($0) }

        // Burst grouping over the MERGED set: reused entries contribute their
        // stored capture time + phash so a new frame can join an old group.
        // A phash that fails to parse must match NOTHING (nil), not everything
        // (the old `?? 0` matched every neighbour within the time window).
        // 双机位：按机身分开串（机身 key 和「场」用的同一套，CameraBody.keys）。
        let models = reusedEntries.map { $0.manifest["camera"] as? String } + completed.map(\.cameraModel)
        let serials = reusedEntries.map { $0.manifest["body_serial"] as? String } + completed.map(\.bodySerial)
        let bodies = CameraBody.keys(models: models, serials: serials)
        var slots: [GroupSlot] = reusedEntries.enumerated().map { i, entry in
            GroupSlot(
                id: entry.id,
                captureTime: (entry.layer1["capture_time"] as? String).flatMap(isoFormatter.date(from:)),
                subsec: entry.layer1["capture_subsec"] as? Double ?? 0,
                phash: (entry.layer1["phash"] as? String).flatMap { UInt64($0, radix: 16) },
                body: bodies[i]
            )
        }
        slots += completed.enumerated().map { i, p in
            GroupSlot(id: p.id, captureTime: p.captureTime, subsec: p.captureSubsec, phash: p.phash,
                      body: bodies[reusedEntries.count + i])
        }
        let groups = assignGroups(slots)
        var reusedFinal = reusedEntries
        for i in reusedFinal.indices { reusedFinal[i].layer1["burst_group"] = groups[i] }
        for i in completed.indices { completed[i].burstGroup = groups[reusedFinal.count + i] }

        // Files ordered like the folder listing, mixing reused + fresh entries.
        var manifestByID: [String: [String: Any]] = [:]
        var layer1ByID: [String: [String: Any]] = [:]
        for entry in reusedFinal {
            manifestByID[entry.id] = entry.manifest
            layer1ByID[entry.id] = entry.layer1
        }
        for p in completed {
            manifestByID[p.id] = manifestEntry(p)
            layer1ByID[p.id] = layer1Entry(p)
        }
        let orderedIds = photos.map(\.stem).filter { manifestByID[$0] != nil }
        // 这一次列出来、没进 photos 的（取消时还没轮到的、解码失败的）也记下 id：id 记忆不跟着「这次分析完了哪些」走
        // （PhotoIDMemory.swift 的 idOnlyKey），不然沿用下来的 id 掉出去一次，下一次就按撞名规矩重新起名。
        let idOnly = photos.filter { manifestByID[$0.stem] == nil }.map { file -> [String: Any] in
            ["id": file.stem, "raw_path": file.primaryURL.path, "decode_path": file.decodeURL.path]
        }
        // Written even when cancelled: 2900 finished photos of a 3000-photo shoot
        // used to be thrown away (previews on disk, no JSON rows), so the next
        // run redid all of them. Now they become reusable entries.
        try writeManifest(orderedIds.compactMap { manifestByID[$0] }, idOnly: idOnly, photoDir: photoDir, dataDir: dataDir)
        try writeLayer1(orderedIds.compactMap { layer1ByID[$0] }, dataDir: dataDir)
        let corrupt = orderedIds.filter { layer1ByID[$0]?["file_corrupt"] as? Bool == true }
        let regeneratedIDs = missing.filter { regenerated[$0] }.map { candidates[$0].file.stem }
        let written = Set(regeneratedIDs).union(completedIds)
        return Summary(analyzed: completed.count, reused: reusedFinal.count,
                       failed: failed, corrupt: corrupt, cancelled: cancelled,
                       previewsWritten: orderedIds.filter(written.contains),
                       refound: photos.filter(\.refound).map(\.stem))
    }

    // MARK: - Per-photo

    private static func analyzePhoto(_ file: ImageLoader.PhotoFile, previewDir: URL) -> PhotoAnalysis? {
        let start = Date()
        // Stamp before and after the decode: ImageIO happily decodes a file
        // that is still being copied from the card (the missing part comes out
        // gray, no error) and the mtime settles afterwards, so that gray frame
        // would be reused forever. A stamp that moved means "not this time".
        guard let stampBefore = ImageLoader.FileStamp.of(file.decodeURL),
              let loaded = ImageLoader.load(file.decodeURL),
              let stampAfter = ImageLoader.FileStamp.of(file.decodeURL),
              stampAfter == stampBefore else {
            return nil
        }

        let id = file.stem
        let previewURL = previewDir.appendingPathComponent("\(id).jpg")
        // No preview = a gray cell in the grid and a photo the VLM can't see;
        // count it as failed instead of pretending.
        guard ImageLoader.savePreview(loaded.image, to: previewURL) else { return nil }

        // Vision 先跑：曝光要按主体区域（人脸 → 头 + 上半身）算，得先知道脸在哪。RGBA / 灰度图都在它之后
        // 才分配，Vision 跑的时候手里只有分析图，峰值内存不比以前高。
        let vision = FaceAnalyzer.analyze(in: loaded.image)
        let face = vision.face
        // 合影小脸在原图分辨率上重量 EAR（没有这种脸的照片不解原图，零开销）。
        let subjectFaces = face.map { FaceAnalyzer.refineSmallFaces($0.subjectFaces, decodeURL: file.decodeURL) } ?? []
        let regions = FaceAnalyzer.exposureRegions(subjectFaces)

        // The RGBA buffer (~38MB) is only needed for the pixel metrics; scope
        // it so it's released before the sharpness ROI work below.
        let hash: UInt64
        let highlightPct: Double, shadowPct: Double
        let subjectClip: (highlightPct: Double, shadowPct: Double)?
        let gray: [Float]
        let width: Int, height: Int
        do {
            guard let (rgba, w, h) = ImageLoader.rgbaBuffer(loaded.image) else { return nil }
            width = w; height = h
            hash = Metrics.phash(rgba: rgba, width: w, height: h)
            (highlightPct, shadowPct) = Metrics.exposureClipping(rgba: rgba, width: w, height: h)
            let bodySpans = Metrics.spans(of: regions.bodies, width: w, height: h)
            let bodyPixels = bodySpans.reduce(0) { $0 + $1.x1 - $1.x0 }
            // 人在画面里太小（远景、旅拍里的小人）：画面本身才是主体，照旧按整张算 —— 不然一张碰巧认出来的
            // 小脸就把一大片死白天空排除在外，认没认出来脸，判决就翻。
            let bigEnough = Double(bodyPixels) >= FaceAnalyzer.minSubjectRegionShare * Double(w * h)
            var clip = bigEnough ? Metrics.exposureClipping(rgba: rgba, width: w, spans: bodySpans) : nil
            // 矩形里有背景：白底、黑底、逆光打爆的背景会把曝光正常的人判成「曝光裁切」（VQ-01）。矩形里有点裁切的，
            // 再跑一次人像分割、只数人（Metrics.personClipping 写了怎么判、为什么不直接取交集）；分割失败照旧用矩形。
            if let rect = clip, max(rect.highlightPct, rect.shadowPct) >= Metrics.personClipGate,
               let mask = FaceAnalyzer.personMask(in: loaded.image),
               let person = Metrics.personClipping(rgba: rgba, width: w, height: h, bodies: bodySpans,
                                                   faces: regions.faces, mask: mask) {
                clip = person
            }
            subjectClip = clip
            gray = Metrics.grayscale(rgba: rgba, width: w, height: h)
        }
        // 欠曝 / 过曝的依据：脸的亮度中位数（没有脸 = nil），整张的中位数和 p99（「画面里有没有亮的东西」）。
        let frameHist = Metrics.lumaHistogram(gray: gray, width: width, height: height)
        let faceHist = Metrics.lumaHistogram(gray: gray, width: width, height: height,
                                             spans: Metrics.spans(of: regions.faces, width: width, height: height))
        // 截断的 JPEG 解码不报错（缺的补灰，人脸在上半截照样认得出），不查就会被当好片、甚至提名精选。
        // 只看文件结束标记，不看解出来的图有没有整条纯灰：灰底棚拍、加了灰边的导出图也是整条 128 灰，
        // 会被冤成「文件损坏」，还叫人别格式化卡（审查发现）。截断的那些 EOI 检查已经全认得出。
        let fileCorrupt = ImageLoader.jpegTruncated(file.decodeURL)

        // Sharpness ladder: eye+brow band (where focus is judged, hair and
        // background excluded) → mouth (only when the eyes' landmarks are
        // unreadable) → face bbox → foreground subject (ring/bouquet/detail shots
        // with no face) → whole frame.
        // 以前取眼眉带和嘴两块里大的那个（怕景深浅、眼睛清楚嘴糊的被冤）。可嘴清楚眼睛糊（前焦、焦点落在嘴唇鼻尖，
        // f/1.2–2 近景人像最常见的失焦）也靠嘴过关：photot 21 张里 18 张是嘴那块大（汉服妆红唇轮廓对比强），
        // 只糊眼眉 σ8 锐度纹丝不动、三档全放过（优化分析 2026-11-18 复核 M1、11-04 A03-a）。现在只看眼眉带：
        // 眼睛清楚嘴糊的照样清楚；只糊眼眉和整张糊一样掉到 36–48。眼眉带在 photot 上 64–91，和以前的 68–93
        // 差不多。
        // 判虚焦用的清晰比（focusRatio）在同一块上算：锐度跟亮度、景别、分辨率走，判虚焦不再用它（VQ-02）。
        let sharpness: Double
        let focusRatio: Double
        let scope: String
        func pixelRect(_ r: [Double]) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            (Int(r[0] * Double(width)), Int(r[1] * Double(height)),
             Int(r[2] * Double(width)), Int(r[3] * Double(height)))
        }
        func regionScore(_ r: [Double]) -> (sharp: Double, focus: Double)? {
            let p = pixelRect(r)
            guard p.x1 - p.x0 > 4, p.y1 - p.y0 > 4 else { return nil }
            let sharp = Metrics.tenengrad(gray: gray, width: width, height: height,
                                          x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y1)
            let focus = Metrics.focusRatio(gray: gray, width: width, height: height,
                                           x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y1)
            return (sharp, focus)
        }
        if let s = face?.eyeBandRect.flatMap(regionScore) {
            (sharpness, focusRatio) = s
            scope = "eyes"
        } else if let s = face?.mouthRect.flatMap(regionScore) {
            (sharpness, focusRatio) = s
            scope = "mouth"
        } else if let face,
                  let s = regionScore([face.bbox.x0, face.bbox.y0, face.bbox.x1, face.bbox.y1]) {
            (sharpness, focusRatio) = s
            scope = "face"
        } else if face == nil,
                  let subject = FaceAnalyzer.subjectRect(in: loaded.image),
                  let s = regionScore([subject.x0, subject.y0, subject.x1, subject.y1]) {
            (sharpness, focusRatio) = s
            scope = "subject"
        } else {
            sharpness = Metrics.tenengrad(gray: gray, width: width, height: height)
            focusRatio = Metrics.focusRatio(gray: gray, width: width, height: height)
            scope = "whole"
        }

        return PhotoAnalysis(
            id: id,
            // The RAW half of a RAW+JPEG pair when both exist — where the XMP
            // sidecar belongs, since Lightroom masters the pair on the RAW.
            rawPath: file.primaryURL.path,
            decodePath: file.decodeURL.path,
            // Absolute path: the data dir lives in Application Support now, so
            // "relative to the Python project cwd" no longer means anything.
            previewRelPath: previewURL.path,
            captureTime: loaded.captureTime,
            captureSubsec: loaded.captureSubsec,
            cameraModel: loaded.cameraModel,
            bodySerial: loaded.bodySerial,
            shutterSec: loaded.shutterSec,
            aperture: loaded.aperture,
            iso: loaded.iso,
            focal35: loaded.focal35,
            lensModel: loaded.lensModel,
            horizonDeg: vision.horizonDeg,
            phash: hash,
            faceFound: face != nil,
            eyeClosed: face?.eyeClosed,
            eyeAspectRatio: face?.eyeAspectRatio,
            faceQuality: face?.captureQuality,
            subjectFaceCount: face?.subjectFaceCount ?? 0,
            faceBbox: face.map { [$0.bbox.x0, $0.bbox.y0, $0.bbox.x1, $0.bbox.y1] },
            faceAreaPct: face?.faceAreaPct,
            subjectFaces: subjectFaces,
            sharpness: sharpness,
            sharpnessScope: scope,
            focusRatio: focusRatio,
            highlightClipPct: highlightPct,
            shadowClipPct: shadowPct,
            subjectHighlightClipPct: subjectClip?.highlightPct ?? highlightPct,
            subjectShadowClipPct: subjectClip?.shadowPct ?? shadowPct,
            faceLuma: Metrics.percentile(faceHist, 0.5),
            frameLuma: Metrics.percentile(frameHist, 0.5) ?? 0,
            frameLumaP99: Metrics.percentile(frameHist, 0.99) ?? 0,
            elapsedSec: Date().timeIntervalSince(start),
            srcMtime: stampAfter.mtime,
            srcSize: stampAfter.size,
            fileCorrupt: fileCorrupt
        )
    }

    // MARK: - Burst grouping (port of common.py group_bursts)

    /// Grouping input decoupled from PhotoAnalysis so reused JSON entries and
    /// fresh analyses group together in one pass.
    struct GroupSlot {
        let id: String
        let captureTime: Date?
        let subsec: Double
        /// nil = unknown hash (unparseable legacy entry): never matches.
        let phash: UInt64?
        /// 机身 key（CameraBody.keys）：只和同一台机身的照片串。
        let body: String
    }

    /// Group id per slot (chronological ids, undated photos get singletons).
    /// Order is (time + subsecond, id): same-second burst frames used to be
    /// compared in INPUT order, which differs between a full run (folder order)
    /// and an incremental one (reused first, fresh last) — groups shifted
    /// between two runs over the same photos.
    ///
    /// 每台机身各串各的：以前全部照片排成一条链只比相邻两张，第二机位插进来一张就把主机位的
    /// 一组连拍拆成两个单张（组内闭眼基线、人脸质量对比、连拍去重全都失效）。串完按每组第一张的
    /// 时间统一编号 —— 单机身时链本来就是按时间排的，组号和以前一模一样。
    private static func assignGroups(_ slots: [GroupSlot]) -> [Int] {
        var result = [Int](repeating: 0, count: slots.count)
        func before(_ a: Int, _ b: Int) -> Bool {
            let ta = slots[a].captureTime!.timeIntervalSince1970 + slots[a].subsec
            let tb = slots[b].captureTime!.timeIntervalSince1970 + slots[b].subsec
            if ta != tb { return ta < tb }
            return slots[a].id < slots[b].id
        }
        let undated = slots.indices.filter { slots[$0].captureTime == nil }
        let byBody = Dictionary(grouping: slots.indices.filter { slots[$0].captureTime != nil },
                                by: { slots[$0].body })

        var chains: [[Int]] = []
        for key in byBody.keys.sorted() {
            var prev: Int?
            for idx in byBody[key]!.sorted(by: before) {
                var sameBurst = false
                if let p = prev, let hp = slots[p].phash, let hi = slots[idx].phash {
                    let dt = slots[idx].captureTime!.timeIntervalSince(slots[p].captureTime!)
                    sameBurst = dt <= timeWindowSec && Metrics.hammingDistance(hp, hi) <= hashThreshold
                }
                if sameBurst { chains[chains.count - 1].append(idx) } else { chains.append([idx]) }
                prev = idx
            }
        }
        chains.sort { before($0[0], $1[0]) }
        var groupId = 0
        for chain in chains {
            groupId += 1
            for idx in chain { result[idx] = groupId }
        }
        for idx in undated {
            groupId += 1
            result[idx] = groupId
        }
        return result
    }

    // MARK: - JSON output (Python-compatible)

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func manifestEntry(_ p: PhotoAnalysis) -> [String: Any] {
        [
            "id": p.id,
            "raw_path": p.rawPath,
            "decode_path": p.decodePath,
            "preview_path": p.previewRelPath,
            "capture_time": p.captureTime.map(isoFormatter.string(from:)) as Any,
            "camera": p.cameraModel as Any,
            // "" = 读过、没有序列号（区别于老 manifest 里没有这个字段 = 没读过，打开时会补）。
            "body_serial": p.bodySerial ?? "",
            "orientation": NSNull(),
            "exif": [
                "shutter_sec": p.shutterSec as Any,
                "aperture": p.aperture as Any,
                "iso": p.iso as Any,
                "focal_35": p.focal35 as Any,
                "lens": p.lensModel as Any,
            ],
        ]
    }

    private static func layer1Entry(_ p: PhotoAnalysis) -> [String: Any] {
        [
            "id": p.id,
            "phash": Metrics.phashHex(p.phash),
            "capture_time": p.captureTime.map(isoFormatter.string(from:)) as Any,
            "capture_subsec": p.captureSubsec,
            "src_mtime": p.srcMtime as Any,
            "src_size": p.srcSize as Any,
            "face_found": p.faceFound,
            "eye_closed": p.eyeClosed as Any,
            // Vision path reports eye-aspect-ratio (LOWER = more closed), unlike
            // MediaPipe's blink score (higher = closed). eye_closed already
            // encodes the decision; this is kept for review/debugging only.
            "blink_score": p.eyeAspectRatio as Any,
            "face_quality": p.faceQuality as Any,
            "face_count": p.subjectFaceCount,
            "face_bbox": p.faceBbox as Any,
            "face_area_pct": p.faceAreaPct as Any,
            "faces": p.subjectFaces.map { face -> [String: Any] in
                ["bbox": face.bbox, "eye_closed": face.eyeClosed as Any,
                 "ear": face.ear as Any, "area_pct": face.areaPct, "ear_full_res": face.earFullRes]
            },
            "horizon_deg": p.horizonDeg as Any,
            "sharpness": p.sharpness,
            "sharpness_scope": p.sharpnessScope,
            "focus_ratio": p.focusRatio,
            // 整张的两个照旧写（标注校准页的「高光裁切 / 暗部裁切」读它们，和老版本的结果同一个字段）；判决用 subject_*。
            "highlight_clip_pct": p.highlightClipPct,
            "shadow_clip_pct": p.shadowClipPct,
            "subject_highlight_clip_pct": p.subjectHighlightClipPct,
            "subject_shadow_clip_pct": p.subjectShadowClipPct,
            "face_luma": p.faceLuma as Any,
            "frame_luma": p.frameLuma,
            "frame_luma_p99": p.frameLumaP99,
            "elapsed_sec": p.elapsedSec,
            "burst_group": p.burstGroup,
            "file_corrupt": p.fileCorrupt,
        ]
    }

    private static func writeManifest(_ entries: [[String: Any]], idOnly: [[String: Any]],
                                      photoDir: URL, dataDir: URL) throws {
        var manifest: [String: Any] = ["photo_dir": photoDir.path, "photos": entries]
        // 和 photos 同一次原子写：两份不会一新一旧。没有就不写这个键（平常整场都分析完了）。
        if !idOnly.isEmpty { manifest[ImageLoader.PreviousIDs.idOnlyKey] = idOnly }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        // .atomic: 一场 3000 张的 manifest 要写好一会儿，中途被强退/断电会留下截断的
        // JSON —— 下次启动网格全空，而且整批要重新分析。
        try data.write(to: dataDir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func writeLayer1(_ entries: [[String: Any]], dataDir: URL) throws {
        let payload: [String: Any] = [
            "hash_threshold": hashThreshold,
            "time_window_sec": timeWindowSec,
            "engine": "native",
            "analysis_version": analysisVersion,
            "results": entries,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dataDir.appendingPathComponent("layer1_results.json"), options: .atomic)
    }
}

final class AtomicCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
