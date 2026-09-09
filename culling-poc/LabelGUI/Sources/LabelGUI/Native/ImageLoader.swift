import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Native replacement for prepare.py's decode path: ImageIO reads every camera
/// vendor's RAW plus JPEG through one API, applies EXIF orientation during
/// thumbnail generation (kCGImageSourceCreateThumbnailWithTransform), and gives
/// us EXIF capture time without shelling out to exiftool.
enum ImageLoader {
    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "dng", "rw2", "pef", "srw",
    ]
    /// 手机图 (heic) / 截图 (png) / 扫描件 (tiff) 都交给 ImageIO 解码 — 网格空着
    /// 却说"文件夹里明明有图"的工单基本都是格式不在名单里。
    static let imageExtensions: Set<String> = rawExtensions.union([
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp",
    ])

    /// Subfolder (inside the shoot folder) where the 高ISO RAW copies for the
    /// denoising workflow land. Excluded from listPhotos so a re-analysis of the
    /// shoot doesn't see every high-ISO frame twice.
    static let denoiseSubfolder = "高ISO降噪"

    /// Long edge for the analysis decode. Sharpness numbers scale with resolution,
    /// so this is fixed for every photo (unlike the Python layer, which used
    /// half-size RAW but full-size JPEG) — one consistent basis for the slider.
    static let analysisMaxPixel = 3072
    static let previewMaxPixel = 1024

    /// Output subfolders (inside the shoot folder) that must never be scanned
    /// as photos: the 高ISO RAW copies for denoising, and the app's own JPG /
    /// watermark exports. Without this, exporting into the shoot folder makes
    /// the next 开始分析 pick the outputs up as new "_jpg" photos.
    static let excludedSubfolders: Set<String> = [denoiseSubfolder, jpegExportSubfolder, "水印导出"]
    static let jpegExportSubfolder = "导出JPG"

    /// Size + modification time of a source file, the incremental-reuse key and
    /// the "did this file change under us while we decoded it" guard.
    struct FileStamp: Equatable {
        let size: Int
        let mtime: Double
        static func of(_ url: URL) -> FileStamp? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard let date = attrs[.modificationDate] as? Date else { return nil }
            return FileStamp(size: size, mtime: date.timeIntervalSince1970)
        }
    }

    struct Loaded {
        let image: CGImage
        let captureTime: Date?
        /// EXIF SubSecTimeOriginal as a fraction of a second (0 when absent):
        /// burst frames share the same whole second, this breaks the tie.
        let captureSubsec: Double
        let cameraModel: String?
        /// Shooting parameters — the photographer's own language for judging a
        /// frame ("1/60 for action, of course it's soft").
        let shutterSec: Double?
        let aperture: Double?
        let iso: Int?
        let focal35: Int?
        let lensModel: String?
    }

    /// One shutter press, one entry. Photographers often shoot RAW+JPEG: the same
    /// frame exists twice with the same stem (DSCF7207.RAF + DSCF7207.JPG). Those
    /// are paired here, NOT treated as two photos:
    /// - decodeURL: the JPEG when present (decodes faster, identical picture)
    /// - primaryURL: the RAW when present — the file the XMP sidecar belongs next
    ///   to, since Lightroom treats the RAW as the master of a RAW+JPEG pair.
    struct PhotoFile {
        /// Unique id for this shot. Filename stem normally; when the same stem
        /// appears in several subfolders (per-scene folders reusing camera
        /// numbering), the parent folder name is prefixed to keep ids unique.
        let stem: String
        let primaryURL: URL
        let decodeURL: URL
    }

    /// Recursive: wedding shoots routinely arrive as 仪式/晚宴/花絮 subfolders.
    /// RAW+JPEG pairing happens per-directory — same stem in different folders is
    /// two different shots, not a pair.
    static func listPhotos(in directory: URL) -> [PhotoFile] {
        let fm = FileManager.default
        var images: [URL] = []
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                if url.hasDirectoryPath, excludedSubfolders.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                if imageExtensions.contains(url.pathExtension.lowercased()) {
                    images.append(url)
                }
            }
        }

        // Same-stem collisions WITHIN a kind (IMG_0001.HEIC + IMG_0001.JPG, or a
        // stray DNG beside its RAF) are NOT pairs — only RAW+one-JPEG pairs are.
        // Extras become standalone photos with the extension folded into the id;
        // letting the dictionary overwrite would silently drop a photo.
        var rawByKey: [String: URL] = [:]
        var jpegByKey: [String: URL] = [:]
        var extras: [URL] = []
        for url in images.sorted(by: { $0.path < $1.path }) {
            let key = url.deletingPathExtension().path
            if rawExtensions.contains(url.pathExtension.lowercased()) {
                if rawByKey[key] == nil { rawByKey[key] = url } else { extras.append(url) }
            } else {
                if jpegByKey[key] == nil { jpegByKey[key] = url } else { extras.append(url) }
            }
        }

        let keys = Set(rawByKey.keys).union(jpegByKey.keys).sorted()
        var stemCounts: [String: Int] = [:]
        for key in keys {
            stemCounts[URL(fileURLWithPath: key).lastPathComponent, default: 0] += 1
        }

        // Ids must be unique: they name previews/<id>.jpg and key every result
        // JSON. Prefixing only ONE parent level collided across scene folders
        // (仪式/JPG/DSC_0001 vs 晚宴/JPG/DSC_0001 → both "JPG_DSC_0001"), which
        // dropped a photo from the manifest and had two workers writing the same
        // preview file. Colliding stems now carry their whole path below the
        // shoot root; unique ones keep the bare stem so existing sessions still
        // match on incremental re-analysis.
        // Compare path COMPONENTS with symlinks resolved on both sides: a plain
        // string prefix test fails whenever the shoot lives under a symlinked
        // parent (/tmp → /private/tmp is the everyday case) and would bake the
        // whole absolute path into the id.
        let rootParts = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        func pathScopedID(_ fileURL: URL) -> String {
            let fileParts = fileURL.resolvingSymlinksInPath().standardizedFileURL
                .deletingPathExtension().pathComponents
            let parts: [String]
            if fileParts.count > rootParts.count,
               Array(fileParts.prefix(rootParts.count)) == rootParts {
                parts = Array(fileParts.dropFirst(rootParts.count))
            } else {
                // 兜底：拿不到相对路径也只取最后几级，别把整条绝对路径写进文件名
                parts = Array(fileParts.suffix(3))
            }
            return parts.isEmpty ? fileURL.deletingPathExtension().lastPathComponent
                                 : parts.joined(separator: "_")
        }
        var usedIDs = Set<String>()
        func claim(_ candidate: String) -> String {
            var id = candidate
            var n = 2
            while usedIDs.contains(id) {
                id = "\(candidate)_\(n)"
                n += 1
            }
            usedIDs.insert(id)
            return id
        }

        let paired = keys.map { key -> PhotoFile in
            let keyURL = URL(fileURLWithPath: key)
            let bareStem = keyURL.lastPathComponent
            let candidate = stemCounts[bareStem]! > 1 ? pathScopedID(keyURL) : bareStem
            let raw = rawByKey[key]
            let jpeg = jpegByKey[key]
            return PhotoFile(
                stem: claim(candidate),
                primaryURL: raw ?? jpeg!,
                decodeURL: jpeg ?? raw!
            )
        }
        let extraFiles = extras.map { url -> PhotoFile in
            let ext = url.pathExtension.lowercased()
            let bare = "\(url.deletingPathExtension().lastPathComponent)_\(ext)"
            // Only reach for the path-scoped form when the cheap one is taken —
            // keeps ids stable for the common no-collision case.
            let candidate = usedIDs.contains(bare) ? "\(pathScopedID(url))_\(ext)" : bare
            return PhotoFile(stem: claim(candidate), primaryURL: url, decodeURL: url)
        }
        return paired + extraFiles
    }

    static func load(_ url: URL) -> Loaded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        var captureTime: Date?
        var captureSubsec = 0.0
        var cameraModel: String?
        var shutterSec: Double?
        var aperture: Double?
        var iso: Int?
        var focal35: Int?
        var lensModel: String?
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                // DateTimeOriginal first; scans/screenshots/some HEIC only carry
                // Digitized or the TIFF DateTime — better than undated, which
                // drops the photo out of chapters and time ordering entirely.
                let candidates: [String?] = [
                    exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                    exif[kCGImagePropertyExifDateTimeDigitized] as? String,
                    tiff?[kCGImagePropertyTIFFDateTime] as? String,
                ]
                for case let dateString? in candidates {
                    if let date = Self.exifDateFormatter.date(from: dateString) {
                        captureTime = date
                        break
                    }
                }
                if let sub = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                   let digits = Double("0." + sub.trimmingCharacters(in: .whitespaces)) {
                    captureSubsec = digits
                }
                shutterSec = exif[kCGImagePropertyExifExposureTime] as? Double
                aperture = exif[kCGImagePropertyExifFNumber] as? Double
                iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
                focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
                if focal35 == nil, let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                    focal35 = Int(focal)  // fallback: raw focal length, close enough for the warning
                }
                lensModel = exif[kCGImagePropertyExifLensModel] as? String
            }
            cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        }

        return Loaded(image: image, captureTime: captureTime, captureSubsec: captureSubsec,
                      cameraModel: cameraModel,
                      shutterSec: shutterSec, aperture: aperture, iso: iso,
                      focal35: focal35, lensModel: lensModel)
    }

    static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Downscale an already-decoded analysis image to preview size and save as JPEG.
    static func savePreview(_ image: CGImage, to url: URL) -> Bool {
        let scale = Double(previewMaxPixel) / Double(max(image.width, image.height))
        let w = min(image.width, Int(Double(image.width) * scale))
        let h = min(image.height, Int(Double(image.height) * scale))

        guard let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return false }

        // Write beside the target and rename: a crash mid-write used to leave a
        // truncated preview that the reuse check ("file exists") trusted forever.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// Extract an 8-bit RGBA pixel buffer (4 bytes/px, alpha ignored) from a
    /// CGImage. One buffer feeds exposure clipping, grayscale conversion, and
    /// pHash — the metrics read stride-4 directly, so no repack pass (which was
    /// a full extra ~28MB copy per photo) is needed.
    static func rgbaBuffer(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        // The context must be created AND drawn inside the pointer's scope — an
        // inout `&rgba` handed to CGContext only stays valid for that one call.
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (rgba, w, h) : nil
    }
}
