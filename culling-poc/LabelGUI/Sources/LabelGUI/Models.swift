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
        // 快门 0（老 manifest 里存过的 0/1）或极小正数时跳过这一段，不再 Int(+inf) 崩。
        if let s = shutterSec, let text = Self.shutterText(s) { parts.append(text) }
        if let a = aperture, a.isFinite, a > 0 { parts.append(String(format: "f/%.1f", a)) }
        if let i = iso { parts.append("ISO \(i)") }
        if let f = focal35, f > 0 { parts.append("\(f)mm") }
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
    /// 机身序列号。nil = 这一版之前分析的（没读过，打开时补）；"" = 读过、没有。
    var bodySerial: String?
    let exif: ExifMeta?

    enum CodingKeys: String, CodingKey {
        case id, camera, exif
        case bodySerial = "body_serial"
        case rawPath = "raw_path"
        case decodePath = "decode_path"
        case previewPath = "preview_path"
        case captureTime = "capture_time"
    }
}

/// 数组里的一行：按 T 解，解不开不往外抛 —— 整个数组照常往下解，坏的只丢它自己（审查 EC-03：以前 manifest / layer1 里
/// 一行字段类型不对，整份解不开、整场显示「还没有分析结果」）。解不开的那行另外宽松地认一下 id、raw_path、decode_path
/// （认得出几样记几样），没进网格的计数和认旧键还要用。
struct LossyRow<T: Decodable>: Decodable {
    let value: T?
    /// value 是 nil 时才有（这一行连对象都不是 = 各字段都是 nil）。
    let fallback: Manifest.IDOnlyRow?

    init(from decoder: Decoder) throws {
        let decoded = try? T(from: decoder)
        value = decoded
        fallback = decoded == nil ? try? Manifest.IDOnlyRow(from: decoder) : nil
    }
}

struct Manifest: Codable {
    let photoDir: String
    let photos: [Photo]
    /// 这一次没分析成、只记了 id 的那几张（PhotoIDMemory 的 idOnlyKey：取消时没轮到的、解码失败的），只有 id、raw_path、
    /// decode_path。打开场次时认旧键（BatchStore.remapOrphanKeys）它们也算照片。老 manifest 没有；这一列解不开只当没有，
    /// 不连累 photos。
    var photosWithoutResults: [IDOnlyRow]? = nil
    /// photos 里按 Photo 解不开的那几行（一个字段类型不对、缺 id / raw_path / preview_path）：只丢这一行（EC-03）。
    /// 它们也是照片：没进网格的计数（BatchStore.unparsedNames）、认旧键（BatchStore.manifestRows）都算上。不写回文件。
    var undecodableRows: [IDOnlyRow] = []

    /// photos_without_results 的一行：每个字段解不开就当没有（和以前按字典读、`as? String` 一样宽）。
    struct IDOnlyRow: Codable {
        var id: String?
        var rawPath: String?
        var decodePath: String?

        enum CodingKeys: String, CodingKey {
            case id
            case rawPath = "raw_path"
            case decodePath = "decode_path"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            rawPath = try? c.decodeIfPresent(String.self, forKey: .rawPath)
            decodePath = try? c.decodeIfPresent(String.self, forKey: .decodePath)
        }
    }

    enum CodingKeys: String, CodingKey {
        case photoDir = "photo_dir"
        case photos
        case photosWithoutResults = "photos_without_results"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photoDir = try c.decode(String.self, forKey: .photoDir)
        let rows = try c.decode([LossyRow<Photo>].self, forKey: .photos)
        photos = rows.compactMap(\.value)
        undecodableRows = rows.compactMap { $0.value == nil ? ($0.fallback ?? IDOnlyRow()) : nil }
        photosWithoutResults = try? c.decodeIfPresent([IDOnlyRow].self, forKey: .photosWithoutResults)
    }

    /// manifest.json 的 photos 里按 Photo 解得开的那些 id（和 BatchStore 打开场次同一个解码器）。分析引擎复用旧结果前先过它：
    /// 界面解不开的行不复用、重新分析，「开始分析」才修得好（EC-03：以前复用按字典宽松读，坏行原样抄回新 manifest）。
    /// 只解 photos 这一列（photo_dir 缺了的老 manifest 照样认）；整份不是 JSON、没有 photos = nil。
    static func decodablePhotoIDs(_ data: Data) -> Set<String>? {
        struct PhotosOnly: Decodable {
            let photos: [LossyRow<Photo>]
        }
        guard let file = try? JSONDecoder().decode(PhotosOnly.self, from: data) else { return nil }
        return Set(file.photos.compactMap { $0.value?.id })
    }
}

extension Manifest.IDOnlyRow {
    /// 全空的一行（坏行连对象都不是）。
    init() {
        id = nil
        rawPath = nil
        decodePath = nil
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
    /// `ear` 是在原图分辨率上量的（合影小脸）—— 免检线按 BatchStore.minFullResEarFaceAreaPct。
    /// 老版本分析的没有这个字段 = 没重量过。
    var earFullRes: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case bbox, ear
        case eyeClosed = "eye_closed"
        case areaPct = "area_pct"
        case earFullRes = "ear_full_res"
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
    /// 锐度量的哪块：eyes（眼眉带）/ mouth / face / subject / whole；analysis_version 3 以前的是 features（眼眉带和嘴取大）。
    /// 近似重复组里比谁更清楚只在同一种口径之间比（BatchStore.softerInBurst）。老结果没有 = nil，自成一种。
    let sharpnessScope: String?
    /// 判「虚焦」用的清晰比（Metrics.focusRatio，0.08–0.12 是清楚的），和 sharpness 量同一块。analysis_version 4 起才有；
    /// 老结果没有 = 判决按锐度折算（BatchStore.legacyFocus），老场次的虚焦判决不因升级变。
    let focusRatio: Double?
    let highlightClipPct: Double?
    let shadowClipPct: Double?
    /// 主体区域（脸 → 头 + 上半身）的裁切占比、脸 / 整张的亮度。analysis_version 2 起才有；
    /// 老结果没有 = 判决退回整张的裁切、不判欠曝 / 过曝（判决不因升级变）。
    let subjectHighlightClipPct: Double?
    let subjectShadowClipPct: Double?
    let faceLuma: Double?
    let frameLuma: Double?
    let frameLumaP99: Double?
    let burstGroup: Int?
    /// 拍摄时间的小数秒（EXIF SubSecTimeOriginal）。引擎一直写进 JSON，以前没解码；同一秒连拍的先后靠它。
    /// 老结果、没有这个 EXIF 的 = nil。
    let captureSubsec: Double?
    /// 引擎查出文件是坏的（JPEG 截断）。旧版本分析的没有这个字段 = 没查过、当好的。
    let fileCorrupt: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, error
        case fileCorrupt = "file_corrupt"
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
        case sharpnessScope = "sharpness_scope"
        case focusRatio = "focus_ratio"
        case highlightClipPct = "highlight_clip_pct"
        case shadowClipPct = "shadow_clip_pct"
        case subjectHighlightClipPct = "subject_highlight_clip_pct"
        case subjectShadowClipPct = "subject_shadow_clip_pct"
        case faceLuma = "face_luma"
        case frameLuma = "frame_luma"
        case frameLumaP99 = "frame_luma_p99"
        case burstGroup = "burst_group"
        case captureSubsec = "capture_subsec"
    }
}

struct Layer1File: Codable {
    let results: [Layer1Result]

    enum CodingKeys: String, CodingKey {
        case results
    }

    /// 一行解不开（字段类型不对）只丢这一行（EC-03）：那张照片没有 layer1 结果，算没进网格，其余照常显示。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([LossyRow<Layer1Result>].self, forKey: .results).compactMap(\.value)
    }

    /// layer1_results.json 里分析引擎能原样复用的 id：按 Layer1Result 解得开、没有 error、有锐度（BatchStore.loadResults
    /// 要它，没有就不进网格 —— 复用这种行，这张就永远进不了网格）。burst_group 不看：复用时整场重新分组、重写。
    static func reusableIDs(_ data: Data) -> Set<String>? {
        guard let file = try? JSONDecoder().decode(Layer1File.self, from: data) else { return nil }
        return Set(file.results.filter { $0.error == nil && $0.sharpness != nil }.map(\.id))
    }
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

/// One row of appeal_results.json — the VLM's re-examination of an auto-reject.
/// Each field is nil unless that charge was re-checked; the verdict layer drops
/// a charge its value clears (eyes NOT closed / subject IS sharp / exposure IS
/// intentional).
struct AppealResult: Codable {
    let id: String
    let closedEyes: Bool?
    let subjectSharp: Bool?
    let intentionalExposure: Bool?
    /// The eye re-check scores expression too — feeds pick ranking for free.
    let expressionScore: Int?
    let reason: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, reason, error
        case closedEyes = "closed_eyes"
        case subjectSharp = "subject_sharp"
        case intentionalExposure = "intentional_exposure"
        case expressionScore = "expression_score"
    }
}

struct AppealFile: Codable {
    let results: [AppealResult]
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
