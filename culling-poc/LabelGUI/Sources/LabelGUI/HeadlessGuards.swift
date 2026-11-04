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

extension AppRuntime {
    /// 三个 batch.* 设置钉进 argument domain（只在内存里，不落盘）：无头入口构造 BatchStore 之前调。
    /// 属性的初值在 BatchStore.init 时从 UserDefaults 读，argument domain 排在最前，所以钉了就读到这里的值；
    /// 不给属性赋值，didSet 也就不会把它写回设置域（裸二进制是 LabelGUI 域，从 .app 里跑就是用户真实的 local.culling.labelgui）。
    /// setVolatileDomain 换的是整个 argument domain：先取出原来的（命令行里的 -key value）再合进去。
    /// 默认值 = 去重关 / 每章最少保留 0 / 按拍摄时间，和 --live-host 不设 LABELGUI_LIVE_TEST_SETTINGS 时一样。
    /// --mcp 不钉：它报的是 app 的真实设置。
    /// 去重开关按场次存以后（审查 S20a），这里钉的 batch.rejectBurstDuplicates 是「全局值」：只管 thresholds.json 里还没有这个键的
    /// 老场次回落到什么、新场次没有「上次用的」时打底；存了的场次按自己的。要盖过场次里存的值用 pinnedRejectBurstDuplicates。
    static func pinBatchSettings(rejectBurstDuplicates: Bool = false, minKeepersPerChapter: Int = 0,
                                 sortOrder: BatchStore.SortOrder = .captureTime) {
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["batch.rejectBurstDuplicates"] = rejectBurstDuplicates
        domain["batch.minKeepersPerChapter"] = minKeepersPerChapter
        domain["batch.sortOrder"] = sortOrder.rawValue
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    /// 命令行钉的「近似重复只留最佳」（--verdicts --dedupe）：不是 nil 就盖过每一场 thresholds.json 里存的值，**只在内存里** ——
    /// BatchStore 打开场次时用它、拨开关 / 拖滑杆 / --gap 写盘时写的照样是这一场原来存的（审查 S20a 要的不落盘的设法）。
    /// 建 store 之前设：BatchStore.init 会先打开「最近」里的第一场。nil = 按场次存的走（界面、测试宿主都是 nil）。
    static var pinnedRejectBurstDuplicates: Bool?
}
