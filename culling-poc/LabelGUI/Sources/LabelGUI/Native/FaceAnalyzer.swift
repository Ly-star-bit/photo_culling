import Foundation
import Vision
import CoreGraphics

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
    struct SubjectFace {
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
            var ear: Double?
            if let landmarks = face.landmarks,
               let left = landmarks.leftEye, let right = landmarks.rightEye {
                let leftRatio = aspectRatio(of: left)
                let rightRatio = aspectRatio(of: right)
                if let l = leftRatio, let r = rightRatio {
                    ear = (l + r) / 2
                } else {
                    ear = leftRatio ?? rightRatio
                }
            }
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
