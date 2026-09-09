import Foundation
import CoreGraphics

/// Native replacement for prepare.py + layer1.py. Produces the exact same
/// artifacts (data/previews/*.jpg, data/manifest.json, data/layer1_results.json,
/// snake_case keys, relative preview paths) so layer2.py (VLM), evaluate.py and
/// the existing GUI loaders keep working unchanged — and so native results can be
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
        let highlightClipPct: Double
        let shadowClipPct: Double
        let elapsedSec: Double
        /// Source file's modification time — the incremental-reuse key: same
        /// id + same mtime on the next run means the analysis is still valid.
        let srcMtime: Double?
        let srcSize: Int?
        var burstGroup: Int = 0
    }

    static let hashThreshold = 10
    static let timeWindowSec = 2.0
    /// Bump whenever a metric's scale changes (decode size, sharpness formula,
    /// pHash construction). Old sessions carrying another version are re-analyzed
    /// instead of silently mixing two scales under one slider. Files written
    /// before this key existed are treated as version 1 (the current scale).
    static let analysisVersion = 1

    struct Summary {
        let analyzed: Int
        /// Photos carried over unchanged from the previous run (same id + mtime,
        /// preview still on disk) — a re-analysis after adding 50 photos to a
        /// 3000-photo shoot costs seconds, not minutes.
        let reused: Int
        /// Photos that failed to decode/analyze — surfaced to the user instead of
        /// silently shrinking the set.
        let failed: [String]
        let cancelled: Bool
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
        let photos = ImageLoader.listPhotos(in: photoDir)
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
        if let mData = try? Data(contentsOf: dataDir.appendingPathComponent("manifest.json")),
           let mJson = try? JSONSerialization.jsonObject(with: mData) as? [String: Any],
           let mPhotos = mJson["photos"] as? [[String: Any]],
           let lData = try? Data(contentsOf: dataDir.appendingPathComponent("layer1_results.json")),
           let lJson = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
           (lJson["engine"] as? String) == "native",
           (lJson["analysis_version"] as? Int ?? 1) == analysisVersion,
           let lResults = lJson["results"] as? [[String: Any]] {
            for p in mPhotos { if let id = p["id"] as? String { oldManifestByID[id] = p } }
            for r in lResults where r["error"] == nil {
                if let id = r["id"] as? String { oldLayer1ByID[id] = r }
            }
        }

        var reusedEntries: [(id: String, manifest: [String: Any], layer1: [String: Any])] = []
        var todo: [ImageLoader.PhotoFile] = []
        for file in photos {
            let previewURL = previewDir.appendingPathComponent("\(file.stem).jpg")
            if let l1 = oldLayer1ByID[file.stem],
               var m = oldManifestByID[file.stem],
               let saved = l1["src_mtime"] as? Double,
               let current = ImageLoader.FileStamp.of(file.decodeURL),
               abs(saved - current.mtime) < 1.0,
               // Entries written before src_size existed match on mtime alone.
               (l1["src_size"] as? Int).map({ $0 == current.size }) ?? true,
               fm.fileExists(atPath: previewURL.path) {
                // The analysis numbers are still valid, but the file layout may
                // not be: a RAF copied in next to an analyzed JPG makes the RAW
                // the primary (XMP goes beside it) — refresh paths every run.
                m["raw_path"] = file.primaryURL.path
                m["decode_path"] = file.decodeURL.path
                m["preview_path"] = previewURL.path
                reusedEntries.append((file.stem, m, l1))
            } else {
                todo.append(file)
            }
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
        var slots: [GroupSlot] = reusedEntries.map { entry in
            GroupSlot(
                id: entry.id,
                captureTime: (entry.layer1["capture_time"] as? String).flatMap(isoFormatter.date(from:)),
                subsec: entry.layer1["capture_subsec"] as? Double ?? 0,
                phash: (entry.layer1["phash"] as? String).flatMap { UInt64($0, radix: 16) }
            )
        }
        slots += completed.map {
            GroupSlot(id: $0.id, captureTime: $0.captureTime, subsec: $0.captureSubsec, phash: $0.phash)
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
        // Written even when cancelled: 2900 finished photos of a 3000-photo shoot
        // used to be thrown away (previews on disk, no JSON rows), so the next
        // run redid all of them. Now they become reusable entries.
        try writeManifest(orderedIds.compactMap { manifestByID[$0] }, photoDir: photoDir, dataDir: dataDir)
        try writeLayer1(orderedIds.compactMap { layer1ByID[$0] }, dataDir: dataDir)
        return Summary(analyzed: completed.count, reused: reusedFinal.count,
                       failed: failed, cancelled: cancelled)
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

        // The RGBA buffer (~38MB) is only needed for the pixel metrics; scope
        // it so it's released before Vision runs alongside 7 other workers.
        let hash: UInt64
        let highlightPct: Double, shadowPct: Double
        let gray: [Float]
        let width: Int, height: Int
        do {
            guard let (rgba, w, h) = ImageLoader.rgbaBuffer(loaded.image) else { return nil }
            width = w; height = h
            hash = Metrics.phash(rgba: rgba, width: w, height: h)
            (highlightPct, shadowPct) = Metrics.exposureClipping(rgba: rgba, width: w, height: h)
            gray = Metrics.grayscale(rgba: rgba, width: w, height: h)
        }

        let vision = FaceAnalyzer.analyze(in: loaded.image)
        let face = vision.face
        // Sharpness ladder: facial-feature rects (eyes/brows/mouth — where focus
        // is judged, hair and background excluded) → face bbox → foreground
        // subject (ring/bouquet/detail shots with no face) → whole frame.
        // Max across feature rects: shallow DOF legitimately blurs the mouth
        // while the eyes are tack sharp, and that photo is IN focus.
        let sharpness: Double
        let scope: String
        func pixelRect(_ r: [Double]) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            (Int(r[0] * Double(width)), Int(r[1] * Double(height)),
             Int(r[2] * Double(width)), Int(r[3] * Double(height)))
        }
        func regionScore(_ r: [Double]) -> Double? {
            let p = pixelRect(r)
            guard p.x1 - p.x0 > 4, p.y1 - p.y0 > 4 else { return nil }
            return Metrics.tenengrad(gray: gray, width: width, height: height,
                                     x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y1)
        }
        let featureScores = (face?.featureRects ?? []).compactMap(regionScore)
        if let best = featureScores.max() {
            sharpness = best
            scope = "features"
        } else if let face,
                  let s = regionScore([face.bbox.x0, face.bbox.y0, face.bbox.x1, face.bbox.y1]) {
            sharpness = s
            scope = "face"
        } else if face == nil,
                  let subject = FaceAnalyzer.subjectRect(in: loaded.image),
                  let s = regionScore([subject.x0, subject.y0, subject.x1, subject.y1]) {
            sharpness = s
            scope = "subject"
        } else {
            sharpness = Metrics.tenengrad(gray: gray, width: width, height: height)
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
            subjectFaces: face?.subjectFaces ?? [],
            sharpness: sharpness,
            sharpnessScope: scope,
            highlightClipPct: highlightPct,
            shadowClipPct: shadowPct,
            elapsedSec: Date().timeIntervalSince(start),
            srcMtime: stampAfter.mtime,
            srcSize: stampAfter.size
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
    }

    /// Group id per slot (chronological ids, undated photos get singletons).
    /// Order is (time + subsecond, id): same-second burst frames used to be
    /// compared in INPUT order, which differs between a full run (folder order)
    /// and an incremental one (reused first, fresh last) — groups shifted
    /// between two runs over the same photos.
    private static func assignGroups(_ slots: [GroupSlot]) -> [Int] {
        var result = [Int](repeating: 0, count: slots.count)
        var dated = slots.indices.filter { slots[$0].captureTime != nil }
        let undated = slots.indices.filter { slots[$0].captureTime == nil }
        dated.sort { a, b in
            let ta = slots[a].captureTime!.timeIntervalSince1970 + slots[a].subsec
            let tb = slots[b].captureTime!.timeIntervalSince1970 + slots[b].subsec
            if ta != tb { return ta < tb }
            return slots[a].id < slots[b].id
        }

        var groupId = 0
        var prev: Int?
        for idx in dated {
            if let p = prev {
                let dt = slots[idx].captureTime!.timeIntervalSince(slots[p].captureTime!)
                var sameBurst = false
                if let hp = slots[p].phash, let hi = slots[idx].phash {
                    sameBurst = dt <= timeWindowSec && Metrics.hammingDistance(hp, hi) <= hashThreshold
                }
                if !sameBurst { groupId += 1 }
            } else {
                groupId += 1
            }
            result[idx] = groupId
            prev = idx
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
                 "ear": face.ear as Any, "area_pct": face.areaPct]
            },
            "horizon_deg": p.horizonDeg as Any,
            "sharpness": p.sharpness,
            "sharpness_scope": p.sharpnessScope,
            "highlight_clip_pct": p.highlightClipPct,
            "shadow_clip_pct": p.shadowClipPct,
            "elapsed_sec": p.elapsedSec,
            "burst_group": p.burstGroup,
        ]
    }

    private static func writeManifest(_ entries: [[String: Any]], photoDir: URL, dataDir: URL) throws {
        let manifest: [String: Any] = ["photo_dir": photoDir.path, "photos": entries]
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
