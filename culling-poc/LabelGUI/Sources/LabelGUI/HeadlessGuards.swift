import Foundation

// MARK: - 无头命令的两道护栏：数据目录不能是真实的那个、batch.* 设置钉住不落盘

/// LABELGUI_DATA_DIR 是不是解析到了真实的默认数据目录（~/Library/Application Support/选片工具）。
/// 判断拆成对「已经解析好的 (路径, dev, ino)」的纯函数（`isRealDataDir`），--mcp-selftest 拿假的输入逐行测、不碰文件；
/// 真去 realpath / stat 的只有 `resolve`（AppUISnapshot.requireNotRealDataDir 调）。
enum DataDirGuard {
    /// 一个目录解析以后的样子：realpath 出来的路径（解析不了就是原样标准化的路径），stat 得到的话带上 dev / ino。
    struct Resolved: Equatable {
        var path: String
        var dev: Int64?
        var ino: UInt64?
    }

    /// 同一个目录：stat 出来 dev、ino 都一样（大小写不同的写法、符号链接、/System/Volumes/Data 那条路），
    /// 或者路径去掉结尾的 /、NFC、不分大小写以后一样（目录还不存在、stat 不了的时候）。宁可多拦：
    /// 区分大小写的卷上，只差大小写的临时目录也会被拦下（换个名字就行），不会放过真实目录。
    static func isRealDataDir(_ candidate: Resolved, real: Resolved) -> Bool {
        if let a = candidate.dev, let b = real.dev, let ai = candidate.ino, let bi = real.ino, a == b, ai == bi {
            return true
        }
        return loosely(candidate.path) == loosely(real.path)
    }

    static func loosely(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// realpath(3) + stat(2)。realpath 不了（还不存在）就退回标准化的原样路径，stat 不了就不带 dev / ino。
    static func resolve(_ path: String) -> Resolved {
        var out = Resolved(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        if let p = realpath(path, nil) {
            out.path = String(cString: p)
            free(p)
        }
        var st = stat()
        if stat(path, &st) == 0 {
            out.dev = Int64(st.st_dev)
            out.ino = UInt64(st.st_ino)
        }
        return out
    }
}
