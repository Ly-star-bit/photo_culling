import Foundation

/// Shooting parameters from the manifest's per-photo "exif" dict.
struct ExifMeta: Codable, Hashable {
    let shutterSec: Double?
    let aperture: Double?
    let iso: Int?
    let focal35: Int?
    let lens: String?

    enum CodingKeys: String, CodingKey {
        case shutterSec = "shutter_sec"
        case aperture, iso, lens
        case focal35 = "focal_35"
    }

    /// Human-readable "1/125 · f/2.8 · ISO 800 · 85mm" line.
    var summary: String {
        var parts: [String] = []
        if let s = shutterSec {
            parts.append(s >= 1 ? String(format: "%.0fs", s) : "1/\(Int((1 / s).rounded()))")
        }
        if let a = aperture { parts.append(String(format: "f/%.1f", a)) }
        if let i = iso { parts.append("ISO \(i)") }
        if let f = focal35 { parts.append("\(f)mm") }
        return parts.joined(separator: " · ")
    }

    /// Below the 1/focal safety-shutter rule — motion blur becomes likely.
    var slowShutter: Bool {
        guard let s = shutterSec, let f = focal35, f > 0 else { return false }
        return s > 1.0 / Double(f)
    }
}

struct Photo: Codable, Identifiable {
    let id: String
    var rawPath: String
    var decodePath: String?
    var previewPath: String
    let captureTime: String?
    let camera: String?
    let exif: ExifMeta?

    enum CodingKeys: String, CodingKey {
        case id, camera, exif
        case rawPath = "raw_path"
        case decodePath = "decode_path"
        case previewPath = "preview_path"
        case captureTime = "capture_time"
    }
}

struct Manifest: Codable {
    let photoDir: String
    let photos: [Photo]

    enum CodingKeys: String, CodingKey {
        case photoDir = "photo_dir"
        case photos
    }
}

/// One subject face as stored in layer1 JSON: normalized top-left bbox + eye
/// state. `ear`/`areaPct` are nil on sessions analyzed by older builds — the
/// verdict layer falls back to the baked `eyeClosed` boolean for those.
struct FaceInfo: Codable, Hashable {
    let bbox: [Double]
    let eyeClosed: Bool?
    let ear: Double?
    let areaPct: Double?

    enum CodingKeys: String, CodingKey {
        case bbox, ear
        case eyeClosed = "eye_closed"
        case areaPct = "area_pct"
    }
}

struct Layer1Result: Codable {
    let id: String
    let faceFound: Bool?
    let eyeClosed: Bool?
    let blinkScore: Double?
    let faceQuality: Double?
    let faceCount: Int?
    let faceBbox: [Double]?
    let faceAreaPct: Double?
    let faces: [FaceInfo]?
    let horizonDeg: Double?
    let sharpness: Double?
    let highlightClipPct: Double?
    let shadowClipPct: Double?
    let burstGroup: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, error
        case faceFound = "face_found"
        case eyeClosed = "eye_closed"
        case blinkScore = "blink_score"
        case faceQuality = "face_quality"
        case faceCount = "face_count"
        case faceBbox = "face_bbox"
        case faceAreaPct = "face_area_pct"
        case faces
        case horizonDeg = "horizon_deg"
        case sharpness
        case highlightClipPct = "highlight_clip_pct"
        case shadowClipPct = "shadow_clip_pct"
        case burstGroup = "burst_group"
    }
}

struct Layer1File: Codable {
    let results: [Layer1Result]
}

struct Layer2Result: Codable {
    let id: String
    let closedEyes: Bool?
    let compositionIssues: [String]?
    let expressionScore: Int?
    let rejectRecommended: Bool?
    let confidence: Double?
    let reason: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, error, confidence, reason
        case closedEyes = "closed_eyes"
        case compositionIssues = "composition_issues"
        case expressionScore = "expression_score"
        case rejectRecommended = "reject_recommended"
    }
}

struct Layer2File: Codable {
    let results: [Layer2Result]
}

/// One row of labels.csv. group_id and composition_issue stay free-form strings;
/// blur/closed_eyes/exposure_issue are tri-state (nil = not yet labeled).
struct LabelRow {
    var blur: Bool?
    var closedEyes: Bool?
    var groupId: String = ""
    var compositionIssue: String = ""
    var exposureIssue: Bool?
    var humanScore: Int?

    var isComplete: Bool {
        blur != nil && closedEyes != nil && exposureIssue != nil && humanScore != nil
    }
}
