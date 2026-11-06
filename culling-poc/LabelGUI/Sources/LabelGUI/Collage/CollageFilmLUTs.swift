import Foundation

/// 光谱胶片色调的表：spektrafilm（Andrea Volpato，github.com/andreavolpato/spektrafilm）按胶片 + 相纸数据算、
/// 离线烘好的 3D LUT，sRGB 伽马进 → sRGB 伽马出（Scripts/bake_film_luts.py）。表是 CC BY-SA 4.0：
/// 按原样的 .cube 文本随 app 发（Contents/Resources/film-luts，旁边是 SPEKTRAFILM_LICENSE.txt 和 CHANGELOG.txt），
/// 不编进二进制、不加密 —— 许可要求别人拿得出来。
///
/// 一个色调一个 <rawValue>.cube。.app 里读 Contents/Resources/film-luts；裸的开发二进制（CI 跑的
/// .build/release/LabelGUI）往上找仓库里的 third_party/film-luts。读不到 = 这个色调原样（不崩）。
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

    /// 这个色调的表（第一次用时读，之后常驻；10 张一共约 4 MB）。不是光谱色调、读不到都是 nil。
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
        let loaded = directory.flatMap { load(look, from: $0) }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[look] { return hit }
        if let loaded {
            cache[look] = loaded
        } else {
            missing.insert(look)
        }
        return loaded
    }

    static func load(_ look: CollageLook, from dir: URL) -> Table? {
        let url = dir.appendingPathComponent(look.rawValue + ".cube")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// 放表的目录：.app 的 Resources/film-luts，否则从可执行文件往上找 third_party/film-luts（开发树、CI）。
    static let directory: URL? = {
        let fm = FileManager.default
        func hasCubes(_ url: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).contains { $0.hasSuffix(".cube") }
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("film-luts"), hasCubes(res) { return res }
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("third_party/film-luts")
            if hasCubes(cand) { return cand }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        return nil
    }()

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
