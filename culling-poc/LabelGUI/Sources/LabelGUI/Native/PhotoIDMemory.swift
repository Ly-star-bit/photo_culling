import Foundation

/// 照片 id 要稳：overrides、accepted、client_picks、xmp_state、layer2、appeal、previews/<id>.jpg、拼图托盘全按 id 记，
/// 没有任何改名迁移。listPhotos 以前只看「这一次」有没有撞名来起名：后加了同名子文件夹、或者移走了同名的一张以后，
/// 没动过的照片 id 跟着变（DSCF0001 ↔ 主机位_DSCF0001），人工改判、客户选中、XMP 记录全对不上，还整张重分析；
/// 根目录新来的同名文件算出来正好是裸 stem，会顶替原来那张的 id，继承它的改判、盖掉它的预览图。
/// 现在上一次分析过的照片按「相对拍摄根目录的路径」沿用上一次的 id（listPhotos 第一遍先全部占上），只给新来的起名。
/// 老场次第一次跑就是原样留着 manifest 里的 id，判决尺度、XMP 都不动。
extension ImageLoader {
    struct PreviousIDs {
        /// 相对路径（各级用 / 连，带扩展名）→ 旧 id。raw_path、decode_path 各记一条：RAW 后补进来（主文件从 JPG
        /// 换成 RAF）、JPG 删掉只剩 RAW，都还认得。
        private var byFile: [String: String] = [:]
        /// 相对路径去掉扩展名 → 这个位置上的旧 id。文件整个换了格式（JPG 换成 HEIC）时的退路，只剩一个没人要的才用。
        private var byKey: [String: Set<String>] = [:]

        var isEmpty: Bool { byFile.isEmpty }

        init() {}

        /// manifest.json 里和 photos 并列的一份：上一次列出来、却没进 photos 的照片（取消时还没轮到的、这一次解码失败的），
        /// 只记 id、raw_path、decode_path。只靠 photos 的话，沿用下来的 id 掉出去一次，下一次就按撞名规矩重新起名
        /// （仪式_DSC_0001 又变回 DSC_0001）。每次分析只写这一次列出来的，不和更早的合并：移走了的照片照旧放掉它的 id。
        static let idOnlyKey = "photos_without_results"

        /// 从上一次的 manifest 建表 —— 不管哪个引擎、哪个分析版本写的：版本升级整场重分析时 id 也得沿用。
        /// 路径先相对旧 manifest 的 photo_dir 算（拍摄文件夹挪过、外置盘换了挂载点也对得上），套不上再相对这一次的根目录。
        /// photos 先、idOnlyKey 那份后（同一个文件先记下的算）。
        init(manifest: [String: Any]?, photoDir: URL) {
            let analyzed = manifest?["photos"] as? [[String: Any]] ?? []
            let idOnly = manifest?[Self.idOnlyKey] as? [[String: Any]] ?? []
            let rows = analyzed + idOnly
            guard !rows.isEmpty else { return }
            var roots: [String] = []
            if let old = manifest?["photo_dir"] as? String, !old.isEmpty { roots.append(old) }
            roots.append(photoDir.path)
            let relativizer = PathRelativizer(roots: roots)
            for row in rows {
                guard let id = row["id"] as? String, !id.isEmpty else { continue }
                for field in ["raw_path", "decode_path"] {
                    guard let path = row[field] as? String, !path.isEmpty,
                          let rel = relativizer.relative(path) else { continue }
                    if byFile[rel] == nil { byFile[rel] = id }
                    byKey[PathRelativizer.dropExtension(rel), default: []].insert(id)
                }
            }
        }

        /// 第一遍：给这一次的照片找上一次的 id。pairs[i] 是第 i 张配对照片的文件（解码用的 JPG 在前、RAW 在后），
        /// extras 是同一个文件夹里同名同类多出来的单张（IMG_0001.HEIC 旁边的 IMG_0001.JPG）。一个旧 id 只给一张：
        /// 先按文件认（配对的先、多出来的后），都认不出来的配对照片再按去掉扩展名的位置认（只剩一个没人要的旧 id 才算）。
        /// 认不出来的 = nil，listPhotos 第二遍照老规矩起名。
        func match(pairs: [[URL]], extras: [URL], root: URL) -> (pairs: [String?], extras: [String?]) {
            var pairIDs = [String?](repeating: nil, count: pairs.count)
            var extraIDs = [String?](repeating: nil, count: extras.count)
            guard !byFile.isEmpty else { return (pairIDs, extraIDs) }
            let relativizer = PathRelativizer(roots: [root.path])
            var taken = Set<String>()
            func take(_ rel: String?) -> String? {
                guard let rel, let id = byFile[rel], !taken.contains(id) else { return nil }
                taken.insert(id)
                return id
            }
            let pairRels = pairs.map { files in files.map { relativizer.relative($0.path) } }
            for i in pairs.indices {
                for rel in pairRels[i] {
                    if let id = take(rel) { pairIDs[i] = id; break }
                }
            }
            for (j, url) in extras.enumerated() {
                extraIDs[j] = take(relativizer.relative(url.path))
            }
            for i in pairs.indices where pairIDs[i] == nil {
                guard let rel = pairRels[i].compactMap({ $0 }).first else { continue }
                let free = (byKey[PathRelativizer.dropExtension(rel)] ?? []).subtracting(taken)
                guard free.count == 1, let id = free.first else { continue }
                taken.insert(id)
                pairIDs[i] = id
            }
            return (pairIDs, extraIDs)
        }
    }

    /// 文件路径 → 相对拍摄根目录的路径（各级用 / 连）。按路径的各级比，不按字符串前缀；先比原样的写法，
    /// 套不上再比解析过符号链接的（枚举器给的路径和传进来的根目录写法不一样、拍摄文件夹在符号链接底下）。
    /// /private/tmp、/private/var 当成 /tmp、/var：macOS 上同一个地方的两种写法，不用碰磁盘就对得上。
    struct PathRelativizer {
        private let plainRoots: [[String]]
        private let resolvedRoots: [[String]]

        init(roots: [String]) {
            let urls = roots.map { URL(fileURLWithPath: $0) }
            plainRoots = urls.map { Self.folded($0.standardizedFileURL.pathComponents) }
            resolvedRoots = urls.map { Self.folded($0.resolvingSymlinksInPath().standardizedFileURL.pathComponents) }
        }

        func relative(_ path: String) -> String? {
            let url = URL(fileURLWithPath: path)
            let plain = Self.folded(url.standardizedFileURL.pathComponents)
            if let rel = Self.strip(plain, roots: plainRoots) ?? Self.strip(plain, roots: resolvedRoots) {
                return rel
            }
            let resolved = Self.folded(url.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
            return Self.strip(resolved, roots: resolvedRoots) ?? Self.strip(resolved, roots: plainRoots)
        }

        static func dropExtension(_ rel: String) -> String {
            (rel as NSString).deletingPathExtension
        }

        private static func strip(_ parts: [String], roots: [[String]]) -> String? {
            for root in roots where parts.count > root.count {
                guard Array(parts.prefix(root.count)) == root else { continue }
                return parts.dropFirst(root.count).joined(separator: "/")
            }
            return nil
        }

        private static func folded(_ parts: [String]) -> [String] {
            let aliased: Set<String> = ["tmp", "var", "etc"]
            guard parts.count >= 3, parts[0] == "/", parts[1] == "private", aliased.contains(parts[2]) else { return parts }
            var out = parts
            out.remove(at: 1)
            return out
        }
    }
}
