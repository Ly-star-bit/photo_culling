import Foundation

/// 光谱胶片色调的表：spektrafilm（Andrea Volpato，github.com/andreavolpato/spektrafilm）按胶片 + 相纸数据算、
/// 离线烘好的 3D LUT，sRGB 伽马进 → sRGB 伽马出（Scripts/bake_film_luts.py）。表是 CC BY-SA 4.0：
/// 按原样的 .cube 文本随 app 发（Contents/Resources/film-luts，旁边是 SPEKTRAFILM_LICENSE.txt 和 CHANGELOG.txt），
/// 不编进二进制、不加密 —— 许可要求别人拿得出来。
///
/// 一个色调一个 <rawValue>.cube。.app 里只读 Contents/Resources/film-luts（包里没有就是没有，不往上找）；裸的开发
/// 二进制（CI 跑的 .build/release/LabelGUI）往上找仓库里的 third_party/film-luts。读不到 = 这个色调原样（不崩），记一行日志
/// （每款一次，缺哪个文件、在哪找的）：v1.24.0–v1.26.1 漏打包了 .json，颗粒、晕光、冲印区三个版本都静默不起作用，
/// 没人发现。
/// 只烘了逐像素的那一半：颗粒、晕光这些空间效果不在表里。
enum CollageFilmLUTs {

    struct Table {
        /// 每边格点数。
        let size: Int
        /// size³ 组 RGB，R 变得最快、B 最慢（.cube 的顺序，和 CollageLooks.cube 的循环一样）。
        let rgb: [Float]
    }

    /// 光谱色调：在表上三线性取样；读不到表就原样返回。
    static func map(_ look: CollageLook, _ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        guard let t = table(look) else { return (r, g, b) }
        return sample(t, r, g, b)
    }

    static func sample(_ t: Table, _ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        t.rgb.withUnsafeBufferPointer { sample($0, size: t.size, r, g, b) }
    }

    /// 同上，表的内存已经借出来了：按格点算一整张色调表时（CollageFilmEffects.Developer）几个线程一起读同一张表，
    /// 每取一次样都去动数组的引用计数，几个核抢同一个计数，并发反倒比一个线程慢。
    static func sample(_ rgb: UnsafeBufferPointer<Float>, size n: Int, _ r: Double, _ g: Double,
                       _ b: Double) -> (Double, Double, Double) {
        let top = Double(n - 1)
        func split(_ v: Double) -> (Int, Double) {
            let x = min(1, max(0, v)) * top
            let i = min(Int(x), n - 2)
            return (i, x - Double(i))
        }
        let (ri, fr) = split(r)
        let (gi, fg) = split(g)
        let (bi, fb) = split(b)
        var out = (0.0, 0.0, 0.0)
        for db in 0...1 {
            let wb = db == 0 ? 1 - fb : fb
            for dg in 0...1 {
                let wg = dg == 0 ? 1 - fg : fg
                for dr in 0...1 {
                    let w = wb * wg * (dr == 0 ? 1 - fr : fr)
                    guard w > 0 else { continue }
                    let k = (((bi + db) * n + (gi + dg)) * n + (ri + dr)) * 3
                    out.0 += w * Double(rgb[k])
                    out.1 += w * Double(rgb[k + 1])
                    out.2 += w * Double(rgb[k + 2])
                }
            }
        }
        return (min(1, max(0, out.0)), min(1, max(0, out.1)), min(1, max(0, out.2)))
    }

    // MARK: - 读表

    private static let lock = NSLock()
    private static var cache: [CollageLook: Table] = [:]
    private static var missing: Set<CollageLook> = []

    /// 自检用：清掉读过的表和「读不到」的记录（换了 directoryOverride 以后重读、重新记日志）。
    static func resetForTesting() {
        lock.lock()
        cache.removeAll()
        missing.removeAll()
        lock.unlock()
    }

    /// 这个色调的表（第一次用时读，之后常驻；10 张一共约 4 MB）。不是光谱色调、读不到都是 nil。
    /// 读不到时记一行日志：每款只记一次（读不到的记进 missing，之后直接返回 nil、不再读）。
    static func table(_ look: CollageLook) -> Table? {
        guard look.isSpectral else { return nil }
        lock.lock()
        if let hit = cache[look] {
            lock.unlock()
            return hit
        }
        if missing.contains(look) {
            lock.unlock()
            return nil
        }
        lock.unlock()
        // 解析一张表（3 万多行文本）不拿着锁：暗房的样张一次要十五款，以前一款一款排队读，别处（主线程上取色、
        // 判字色深浅）要哪款都得等前面的读完。两个线程同时读同一款就各读一遍，先放进去的那份留着。
        let dir = directory
        let loaded = dir.flatMap { load(look, from: $0) }
        lock.lock()
        if let hit = cache[look] {
            lock.unlock()
            return hit
        }
        var first = false
        if let loaded {
            cache[look] = loaded
        } else {
            first = missing.insert(look).inserted
        }
        lock.unlock()
        if first {
            AppLog.warning("film", "光谱色调「\(look.label)」（\(look.rawValue)）的色调表没读到，这一款不调色（原样）："
                           + missingReason([look.rawValue + ".cube"], in: dir))
        }
        return loaded
    }

    /// 读不到的原因（日志、诊断包用）：没找到放表的目录 / 缺哪几个文件（带目录）/ 文件都在但读不出来。
    static func missingReason(_ files: [String], in dir: URL?) -> String {
        guard let dir else {
            return isAppBundle(Bundle.main.bundleURL)
                ? "没找到放表的目录（.app 里只认 Contents/Resources/film-luts，那里没有 .cube：打包漏了）"
                : "没找到放表的目录（可执行文件旁边的 film-luts、往上的 third_party/film-luts 里都没有 .cube）"
        }
        let fm = FileManager.default
        let absent = files.filter { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        if absent.isEmpty {
            return "\(files.joined(separator: "、")) 都在 \(dir.path)，但读不出来（格式不对或者没有读权限）"
        }
        return "缺 \(absent.joined(separator: "、"))（在 \(dir.path) 里找的）"
    }

    static func load(_ look: CollageLook, from dir: URL) -> Table? {
        let url = dir.appendingPathComponent(look.rawValue + ".cube")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// 放表的目录（自检指到别处时是 directoryOverride）。
    static var directory: URL? { directoryOverride ?? foundDirectory }

    /// 自检用：把放表的目录指到别处（空目录 = 模拟漏打包）。nil = 照常找。改了以后要 resetForTesting
    /// （CollageFilmEffects 的也要），不然读过的还在缓存里。
    static var directoryOverride: URL?

    /// 找到的放表目录（怎么找见 search）。
    static let foundDirectory: URL? = search(
        bundle: Bundle.main.bundleURL, resources: Bundle.main.resourceURL,
        executable: (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath())

    /// 放表的目录怎么找。在 .app 里（Bundle.main 是 .app）只认 Contents/Resources/film-luts，包里没有就是 nil（每款记一行
    /// 日志），不往上找：以前不管在不在 .app 里都会退到往上找，CI 在仓库根目录下跑 选片工具.app 里的二进制，包里漏了表也会
    /// 往上找到仓库里的 third_party/film-luts，打包后的检查测不出漏装（优化分析 NE6）。裸二进制（.build/release/LabelGUI，
    /// 开发树、CI 的测试）先看可执行文件旁边的 film-luts，再从可执行文件往上找 third_party/film-luts。
    /// hasCubes 只有自检换（假路径，不碰盘、不起 .app）。
    static func search(bundle: URL, resources: URL?, executable: URL,
                       hasCubes: (URL) -> Bool = CollageFilmLUTs.hasCubes) -> URL? {
        let res = resources?.appendingPathComponent("film-luts")
        if isAppBundle(bundle) {
            guard let res, hasCubes(res) else { return nil }
            return res
        }
        if let res, hasCubes(res) { return res }
        var dir = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("third_party/film-luts")
            if hasCubes(cand) { return cand }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        return nil
    }

    /// 是不是 .app（扩展名不分大小写：APFS 默认不分，LaunchServices 也不分）。裸二进制的 bundleURL 是它所在的目录。
    static func isAppBundle(_ bundle: URL) -> Bool {
        bundle.pathExtension.lowercased() == "app"
    }

    /// 目录里有没有 .cube。
    static func hasCubes(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).contains { $0.hasSuffix(".cube") }
    }

    /// .cube 文本 → 表。认 LUT_3D_SIZE、跳过 TITLE / DOMAIN_* / # 注释；格点数不对、有非有限数 = nil。
    static func parse(_ text: String) -> Table? {
        var size = 0
        var rgb: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, first != "#" else { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0
                guard size >= 2, size <= 128 else { return nil }
                rgb.reserveCapacity(size * size * size * 3)
                continue
            }
            if first.isLetter { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { return nil }
            for p in parts.prefix(3) {
                guard let v = Float(p), v.isFinite else { return nil }
                rgb.append(v)
            }
        }
        guard size >= 2, rgb.count == size * size * size * 3 else { return nil }
        return Table(size: size, rgb: rgb)
    }
}
