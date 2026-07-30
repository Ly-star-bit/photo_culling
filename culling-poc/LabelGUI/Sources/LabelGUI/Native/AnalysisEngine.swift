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
        var burstGroup: Int = 0
    }

    static let hashThreshold = 10
    static let timeWindowSec = 2.0

    struct Summary {
        let analyzed: Int
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
        let photos = ImageLoader.listPhotos(in: photoDir)
        guard !photos.isEmpty else {
            throw NSError(domain: "AnalysisEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "这个文件夹 (含子文件夹) 里没有支持的图片文件 (RAW/JPG/PNG/HEIC/TIFF)"])
        }

        let previewDir = dataDir.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        let total = photos.count
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

        for (index, file) in photos.enumerated() {
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

        if cancel.isSet {
            return Summary(analyzed: 0, failed: [], cancelled: true)
        }

        var completed = results.compactMap { $0 }
        let completedIds = Set(completed.map(\.id))
        let failed = photos.map(\.stem).filter { !completedIds.contains($0) }
        assignBurstGroups(&completed)

        try writeManifest(completed, photoDir: photoDir, dataDir: dataDir)
        try writeLayer1(completed, dataDir: dataDir)
        return Summary(analyzed: completed.count, failed: failed, cancelled: false)
    }

    // MARK: - Per-photo

    private static func analyzePhoto(_ file: ImageLoader.PhotoFile, previewDir: URL) -> PhotoAnalysis? {
        let start = Date()
        guard let loaded = ImageLoader.load(file.decodeURL),
              let (rgba, width, height) = ImageLoader.rgbaBuffer(loaded.image) else {
            return nil
        }

        let id = file.stem
        let previewURL = previewDir.appendingPathComponent("\(id).jpg")
        _ = ImageLoader.savePreview(loaded.image, to: previewURL)

        let hash = Metrics.phash(rgba: rgba, width: width, height: height)
        let (highlightPct, shadowPct) = Metrics.exposureClipping(rgba: rgba, width: width, height: height)
        let gray = Metrics.grayscale(rgba: rgba, width: width, height: height)

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
            elapsedSec: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Burst grouping (port of common.py group_bursts)

    private static func assignBurstGroups(_ photos: inout [PhotoAnalysis]) {
        var dated = photos.indices.filter { photos[$0].captureTime != nil }
        let undated = photos.indices.filter { photos[$0].captureTime == nil }
        dated.sort { photos[$0].captureTime! < photos[$1].captureTime! }

        var groupId = 0
        var prev: Int?
        for idx in dated {
            if let p = prev {
                let dt = photos[idx].captureTime!.timeIntervalSince(photos[p].captureTime!)
                let dist = Metrics.hammingDistance(photos[p].phash, photos[idx].phash)
                if !(dt <= timeWindowSec && dist <= hashThreshold) {
                    groupId += 1
                }
            } else {
                groupId += 1
            }
            photos[idx].burstGroup = groupId
            prev = idx
        }
        for idx in undated {
            groupId += 1
            photos[idx].burstGroup = groupId
        }
    }

    // MARK: - JSON output (Python-compatible)

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func writeManifest(_ photos: [PhotoAnalysis], photoDir: URL, dataDir: URL) throws {
        let entries: [[String: Any]] = photos.map { p in
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
        let manifest: [String: Any] = ["photo_dir": photoDir.path, "photos": entries]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dataDir.appendingPathComponent("manifest.json"))
    }

    private static func writeLayer1(_ photos: [PhotoAnalysis], dataDir: URL) throws {
        let entries: [[String: Any]] = photos.map { p in
            [
                "id": p.id,
                "phash": Metrics.phashHex(p.phash),
                "capture_time": p.captureTime.map(isoFormatter.string(from:)) as Any,
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
        let payload: [String: Any] = [
            "hash_threshold": hashThreshold,
            "time_window_sec": timeWindowSec,
            "engine": "native",
            "results": entries,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dataDir.appendingPathComponent("layer1_results.json"))
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
