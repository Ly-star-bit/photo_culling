import Foundation
import Vision
import CoreGraphics
import ImageIO

/// Native replacement for YuNet + MediaPipe: Apple's Vision framework handles both
/// jobs (find the face, read the eye state) in one landmarks request, and unlike
/// MediaPipe's selfie-tuned detector it locates small faces in environmental
/// portraits fine.
///
/// Eye-closed here is an eye-aspect-ratio (EAR) heuristic over Vision's eye
/// landmark points — height/width of the eye outline. MediaPipe's learned
/// blendshape was preferred in the Python layer because a fixed EAR cutoff is
/// less robust across eye shapes; keep that caveat in mind when reviewing
/// disagreements, and calibrate EAR_CLOSED_THRESHOLD against labeled data if
/// closed-eye accuracy on real shoots falls short.
enum FaceAnalyzer {
    /// Eye height/width ratio below which the eye counts as closed. Open eyes
    /// typically measure 0.25-0.4; blinks drop under ~0.12.
    static let earClosedThreshold: Double = 0.15
    static let bboxPadding: Double = 0.15

    /// Faces at least this fraction of the LARGEST face's area count as subjects.
    /// Group shots: every subject's eyes matter (Aftershoot behavior). Background
    /// passers-by are far smaller than the subjects and must NOT veto a photo by
    /// blinking somewhere on a bridge.
    static let subjectFaceAreaRatio = 0.25

    /// One subject face: padded normalized top-left bbox + its own eye state.
    /// Persisted per-face so the UI can render a face-crop strip with eye badges
    /// (the Narrative Select / Aftershoot review pattern).
    struct SubjectFace: Sendable {
        let bbox: [Double]  // [x0, y0, x1, y1]
        /// Absolute-threshold call, kept for JSON compat with the Python tooling.
        /// The GUI verdict layer recomputes eye state from `ear` with burst-group
        /// dynamic thresholds instead of trusting this.
        let eyeClosed: Bool?
        /// Raw eye aspect ratio — the verdict layer needs the number, not a
        /// baked-in boolean, to compare against burst-group siblings.
        let ear: Double?
        /// UNPADDED bbox area as a fraction of the frame. Faces under ~2% of the
        /// frame get EAR immunity downstream (too few pixels for reliable
        /// landmarks — hair wisps and squints read as blinks).
        let areaPct: Double
        /// `ear` 是在原图分辨率的脸部裁块上重新量的（合影小脸，见 refineSmallFaces）——
        /// 判决层对这种脸的免检线放低到 0.05%。
        var earFullRes = false
    }

    struct FaceResult {
        /// Primary (largest) face's padded bbox, normalized, TOP-LEFT origin
        /// (converted from Vision's bottom-left). Used for the sharpness crop.
        let bbox: (x0: Double, y0: Double, x1: Double, y1: Double)
        /// True if ANY subject-sized face has closed eyes.
        let eyeClosed: Bool?
        /// WORST (lowest) eye aspect ratio across subject faces; nil if no
        /// landmarks were readable on any of them.
        let eyeAspectRatio: Double?
        /// Apple's learned 0-1 "how well was this face captured" score for the
        /// primary face (blur, exposure, pose, occlusion combined). Trained for
        /// ranking shots of the SAME subject — ideal for burst-group picking;
        /// treat cross-scene absolute thresholds with more care.
        let captureQuality: Double?
        /// All subject-sized faces (excludes small background faces), largest first.
        let subjectFaces: [SubjectFace]
        /// Primary face's UNPADDED area fraction of the frame — drives the
        /// 景别 (framing-scale) compensation curve for quality thresholds.
        let faceAreaPct: Double
        /// Facial-feature rects of the primary face (eye+brow band, mouth),
        /// normalized top-left [x0,y0,x1,y1]. Sharpness measured here instead of
        /// the whole face box keeps hair texture and background (花窗) out of the
        /// focus metric. Empty when landmarks are unreadable.
        let featureRects: [[Double]]
        var subjectFaceCount: Int { subjectFaces.count }
    }

    /// Face analysis + horizon in ONE handler.perform() — the three requests
    /// share the handler's image preparation instead of paying it per request.
    struct Analysis {
        let face: FaceResult?
        let horizonDeg: Double?
    }

    static func analyze(in image: CGImage) -> Analysis {
        let request = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let horizonRequest = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request, qualityRequest, horizonRequest])) != nil else {
            return Analysis(face: nil, horizonDeg: nil)
        }
        let horizonDeg = horizonRequest.results?.first.map { Double($0.angle) * 180.0 / .pi }
        return Analysis(face: faceResult(from: request, quality: qualityRequest),
                        horizonDeg: horizonDeg)
    }

    private static func faceResult(from request: VNDetectFaceLandmarksRequest,
                                   quality qualityRequest: VNDetectFaceCaptureQualityRequest) -> FaceResult? {
        guard let faces = request.results, !faces.isEmpty else {
            return nil
        }

        func area(_ f: VNFaceObservation) -> CGFloat {
            f.boundingBox.width * f.boundingBox.height
        }
        let primary = faces.max { area($0) < area($1) }!
        let subjects = faces.filter { area($0) >= area(primary) * subjectFaceAreaRatio }

        // Vision bbox is normalized with bottom-left origin; flip to top-left.
        let bb = primary.boundingBox
        let x0 = bb.minX, x1 = bb.maxX
        let y0 = 1.0 - bb.maxY, y1 = 1.0 - bb.minY
        let padX = (x1 - x0) * bboxPadding
        let padY = (y1 - y0) * bboxPadding
        let padded = (
            x0: max(0.0, x0 - padX),
            y0: max(0.0, y0 - padY),
            x1: min(1.0, x1 + padX),
            y1: min(1.0, y1 + padY)
        )

        // One blink anywhere among the subjects spoils the shot, so keep the
        // WORST (minimum) eye-openness across all of them — plus each face's own
        // state for the face-crop strip.
        var worstEar: Double?
        var subjectFaces: [SubjectFace] = []
        for face in subjects.sorted(by: { area($0) > area($1) }) {
            let ear = eyeAspectRatio(of: face)
            if let ear {
                worstEar = min(worstEar ?? .infinity, ear)
            }
            let fb = face.boundingBox
            let fx0 = fb.minX, fx1 = fb.maxX
            let fy0 = 1.0 - fb.maxY, fy1 = 1.0 - fb.minY
            let fpadX = (fx1 - fx0) * bboxPadding
            let fpadY = (fy1 - fy0) * bboxPadding
            subjectFaces.append(SubjectFace(
                bbox: [max(0.0, fx0 - fpadX), max(0.0, fy0 - fpadY),
                       min(1.0, fx1 + fpadX), min(1.0, fy1 + fpadY)],
                eyeClosed: ear.map { $0 < earClosedThreshold },
                ear: ear,
                areaPct: Double(fb.width * fb.height)
            ))
        }

        // Quality results are separate observations; match the primary subject
        // by picking the largest face there too.
        let quality = qualityRequest.results?
            .max { area($0) < area($1) }?
            .faceCaptureQuality
            .map(Double.init)

        return FaceResult(
            bbox: padded,
            eyeClosed: worstEar.map { $0 < earClosedThreshold },
            eyeAspectRatio: worstEar,
            captureQuality: quality,
            subjectFaces: subjectFaces,
            faceAreaPct: Double(bb.width * bb.height),
            featureRects: featureRects(for: primary)
        )
    }

    // MARK: - 曝光的主体区域

    /// 主体区域（下面 exposureRegions 的头 + 上半身并集，裁到画面内）至少占画面这么多，曝光裁切才只看主体：
    /// 约等于一张 0.23% 的脸扩成头 + 上半身（人占画面高度一半左右的全身照）。再小就是远景里的人，照旧算整张。
    /// photot 的环境人像最小 3.6%，合影（3×3 到 5×5）6–11%，大片死白天空下一张 0.08% 的小脸只有 0.7%。
    static let minSubjectRegionShare = 0.02

    /// 曝光看的「主体区域」：每张主体脸扩到头 + 上半身（宽 2 倍脸宽，往上 0.3 个脸高带上头发，往下 3 个脸高
    /// 到腰），几张脸取并集；另给只有脸的框 —— 亮度只看脸，上半身里一身黑西装会把中位数拉下去。
    /// 归一化左上原点；SubjectFace.bbox 带 15% padding，这里先还原成原始脸框。
    static func exposureRegions(_ faces: [SubjectFace]) -> (bodies: [[Double]], faces: [[Double]]) {
        var bodies: [[Double]] = [], boxes: [[Double]] = []
        for f in faces {
            let w = (f.bbox[2] - f.bbox[0]) / (1 + 2 * bboxPadding)
            let h = (f.bbox[3] - f.bbox[1]) / (1 + 2 * bboxPadding)
            let cx = (f.bbox[0] + f.bbox[2]) / 2, top = (f.bbox[1] + f.bbox[3]) / 2 - h / 2
            boxes.append([cx - w / 2, top, cx + w / 2, top + h])
            bodies.append([cx - w, top - 0.3 * h, cx + w, top + 4 * h])
        }
        return (bodies, boxes)
    }

    // MARK: - 合影小脸：原图分辨率重量 EAR

    /// 3072 分析图上小于这个面积的脸 landmark 不可靠 —— 判决层的小脸免检线（BatchStore.minEarFaceAreaPct）。
    static let smallFaceAreaPct = 0.003
    /// 原图上的脸至少要这么多像素才重量：≈ 3072×2048 分析图上 0.3% 的脸（约 137px 见方），也就是小脸免检
    /// 原来那条「landmark 读得准」的线，换成像素数。4000 万像素的机身约 0.05%，2400 万像素约 0.08%。
    static let minLandmarkFacePixels = 0.003 * 3072 * 2048
    /// 同时解原图的上限：4000 万像素一张 RGBA 就 160MB，8 个 worker 一起解会吃掉好几 GB。
    private static let fullResGate = DispatchSemaphore(value: 2)

    /// 合影里的小脸（3072 分析图上 < 0.3%：以前一律免检，9 人以上的合影整张免检）：从原图（decodeURL，按
    /// EXIF 方向转正）按脸框裁出原分辨率的块，在块上重跑 landmark，EAR 按原分辨率算，标 earFullRes。
    /// 只做「像主体」的小脸：面积 ≥ 最大脸的一半；或者是合影（没有哪张脸独大）、并且有 ≥3 张差不多大的脸。
    /// 一个人的街拍，主角的脸独大，背后路人再多也不重量，照旧免检。裁块里找不到这张脸 / 读不出眼睛的
    /// 保持原样（照旧免检），绝不拿 3072 上那个不可靠的 EAR 顶上。
    static func refineSmallFaces(_ faces: [SubjectFace], decodeURL: URL) -> [SubjectFace] {
        let areas = faces.map(\.areaPct).sorted(by: >)
        guard let largest = areas.first else { return faces }
        let group = areas.count > 1 && areas[1] >= largest * 0.5
        func plausible(_ a: Double) -> Bool {
            a >= largest * 0.5 || (group && areas.filter { $0 >= a / 2 && $0 <= a * 2 }.count >= 3)
        }
        var todo = faces.indices.filter { faces[$0].areaPct < smallFaceAreaPct && plausible(faces[$0].areaPct) }
        guard !todo.isEmpty,
              let source = CGImageSourceCreateWithURL(decodeURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int else { return faces }
        todo = todo.filter { faces[$0].areaPct * Double(pw * ph) >= minLandmarkFacePixels }
        // 原图没比分析图大多少（手机小图、导出的 JPG）：重解一遍什么也得不到。
        guard !todo.isEmpty, max(pw, ph) > ImageLoader.analysisMaxPixel * 3 / 2 else { return faces }

        fullResGate.wait()
        defer { fullResGate.signal() }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return faces }
        var out = faces
        for i in todo {
            guard let ear = fullResEar(of: faces[i].bbox, in: full) else { continue }
            out[i] = SubjectFace(bbox: faces[i].bbox, eyeClosed: ear < earClosedThreshold, ear: ear,
                                 areaPct: faces[i].areaPct, earFullRes: true)
        }
        return out
    }

    /// 一张脸（归一化左上原点、带 padding 的框）在原图上的 EAR：四周再放出半张脸的余量裁块，取块里中心落在
    /// 这张脸框内、离它中心最近的那张脸 —— 挤在一起的合影里，裁块边上的邻居不能顶替。
    private static func fullResEar(of bbox: [Double], in image: CGImage) -> Double? {
        let w = Double(image.width), h = Double(image.height)
        let bw = bbox[2] - bbox[0], bh = bbox[3] - bbox[1]
        let x0 = max(0, (bbox[0] - bw * 0.5) * w), x1 = min(w, (bbox[2] + bw * 0.5) * w)
        let y0 = max(0, (bbox[1] - bh * 0.5) * h), y1 = min(h, (bbox[3] + bh * 0.5) * h)
        // CGImage 的裁切坐标左上原点，和 bbox 一样。
        let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral
        guard rect.width >= 32, rect.height >= 32, let crop = image.cropping(to: rect) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil,
              let found = request.results else { return nil }
        // 目标脸中心换到裁块坐标（Vision 左下原点），允许偏半个脸框。
        let cx = ((bbox[0] + bbox[2]) / 2 * w - rect.minX) / rect.width
        let cy = 1 - ((bbox[1] + bbox[3]) / 2 * h - rect.minY) / rect.height
        let tolX = bw * w / rect.width / 2, tolY = bh * h / rect.height / 2
        let near = found.filter {
            abs(Double($0.boundingBox.midX) - cx) < tolX && abs(Double($0.boundingBox.midY) - cy) < tolY
        }
        func distance(_ f: VNFaceObservation) -> Double {
            hypot(Double(f.boundingBox.midX) - cx, Double(f.boundingBox.midY) - cy)
        }
        return near.min { distance($0) < distance($1) }.flatMap(eyeAspectRatio(of:))
    }

    /// Eye+brow band and mouth rects of one face, image-normalized top-left
    /// origin. Landmark points come in face-bbox space (bottom-left); each rect
    /// is padded by 25% of its own size so the edge gradients that carry the
    /// focus signal (lash line, lip contour) stay inside the crop.
    private static func featureRects(for face: VNFaceObservation) -> [[Double]] {
        guard let landmarks = face.landmarks else { return [] }
        let bb = face.boundingBox

        func rect(from regions: [VNFaceLandmarkRegion2D?]) -> [Double]? {
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            var count = 0
            for region in regions {
                guard let region else { continue }
                for p in region.normalizedPoints {
                    let ix = bb.minX + p.x * bb.width
                    let iy = bb.minY + p.y * bb.height
                    minX = min(minX, ix); maxX = max(maxX, ix)
                    minY = min(minY, iy); maxY = max(maxY, iy)
                    count += 1
                }
            }
            guard count >= 4 else { return nil }
            let padX = (maxX - minX) * 0.25
            let padY = (maxY - minY) * 0.25
            let x0 = max(0.0, minX - padX), x1 = min(1.0, maxX + padX)
            // flip bottom-left → top-left
            let y0 = max(0.0, 1.0 - (maxY + padY)), y1 = min(1.0, 1.0 - (minY - padY))
            guard x1 > x0, y1 > y0 else { return nil }
            return [Double(x0), Double(y0), Double(x1), Double(y1)]
        }

        var rects: [[Double]] = []
        if let eyes = rect(from: [landmarks.leftEye, landmarks.rightEye,
                                  landmarks.leftEyebrow, landmarks.rightEyebrow]) {
            rects.append(eyes)
        }
        if let mouth = rect(from: [landmarks.outerLips]) {
            rects.append(mouth)
        }
        return rects
    }

    /// Normalized top-left bbox of the photo's foreground subject (ring shot,
    /// bouquet, venue detail — anything, class-free), via the same
    /// subject-lifting model behind the system's "lift subject" feature. Used as
    /// the sharpness ROI for photos WITHOUT a face, so background texture stops
    /// polluting the focus score there too. nil when separation fails or the
    /// "subject" is degenerate (almost nothing or almost the whole frame).
    static func subjectRect(in image: CGImage) -> (x0: Double, y0: Double, x1: Double, y1: Double)? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }

        // The low-res instance mask (top-left raster, 0 = background) is enough
        // for a bounding box — no need to render the expensive full-res mask.
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var minX = w, maxX = -1, minY = h, maxY = -1
        var count = 0
        for y in 0..<h {
            let row = y * stride
            for x in 0..<w where pixels[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                count += 1
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let areaFraction = Double(count) / Double(w * h)
        guard areaFraction > 0.02, areaFraction < 0.95 else { return nil }
        return (Double(minX) / Double(w), Double(minY) / Double(h),
                Double(maxX + 1) / Double(w), Double(maxY + 1) / Double(h))
    }

    /// Both eyes' aspect ratios averaged (one when only one is readable); nil
    /// when the landmarks have no eyes.
    private static func eyeAspectRatio(of face: VNFaceObservation) -> Double? {
        guard let landmarks = face.landmarks,
              let left = landmarks.leftEye, let right = landmarks.rightEye else { return nil }
        let leftRatio = aspectRatio(of: left)
        let rightRatio = aspectRatio(of: right)
        if let l = leftRatio, let r = rightRatio { return (l + r) / 2 }
        return leftRatio ?? rightRatio
    }

    /// Height/width of the eye outline's bounding extent. Point order in Vision's
    /// eye region isn't documented, so extent-based ratio is safer than assuming
    /// dlib-style indexing.
    private static func aspectRatio(of region: VNFaceLandmarkRegion2D) -> Double? {
        let points = region.normalizedPoints
        guard points.count >= 4 else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let width = maxX - minX
        guard width > 0 else { return nil }
        return Double((maxY - minY) / width)
    }
}
