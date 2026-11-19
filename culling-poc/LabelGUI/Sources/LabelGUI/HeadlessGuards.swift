import Foundation

// MARK: - 无头命令的三道护栏：数据目录不能是真实的那个、batch.* 设置钉住不落盘、视图设置（@AppStorage）不碰设置域

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

// MARK: - 视图级设置（@AppStorage）：无头时不读也不写设置域

extension AppRuntime {
    /// 各视图的 @AppStorage 读写用的那份 UserDefaults。**新加 @AppStorage 一律写 `store: AppRuntime.viewDefaults`**
    /// （不写就回到 UserDefaults.standard：无头一拨控件又写进设置域；--view-prefs-selftest 只拨得到网格模式和缩略图滑杆）。
    ///
    /// 界面：就是 UserDefaults.standard，照旧记在 app 自己的设置域，下次打开还在。
    /// 无头（命令行带无头参数 —— 和 main.swift 认无头同一个判断；不看 AppRuntime.headless，有的自检中途会把它拨回 false）：
    /// 一份临时的 —— suite 名写系统临时目录下的绝对路径，cfprefsd 只读写那个 plist（目录它自己建），退出时整个目录删掉。于是
    ///   - 读：只看参数域（命令行 `-batch.gridMode 按分组`）和代码里的默认，**看不到** app 自己的持久设置域。以前某次无头拨过的
    ///     batch.gridMode / batch.thumbSize 留在裸二进制的 LabelGUI 域里，之后所有不传参的 --batch-ui 快照、BatchPerf 都按它画，
    ///     数对不上也不报错（优化分析 2026-11-18 perf-ui 复核「漏-1」）；
    ///   - 写：--events 点「按分组」、拖缩略图滑杆、--perf 里拨控件在这个进程里照常生效，落在临时 plist，设置域一个字节不写。
    ///
    /// 为什么不照 pinBatchSettings 把这些键也钉进参数域：参数域只管读。实测带 `-k a` 启动再 set(b)：持久域照样多出 k = b，
    /// 读出来还是 a —— 写照样落盘，控件还被钉死（点了不变）。pinBatchSettings 那三个键不落盘，靠的是 BatchStore 里 didSet 前面那句
    /// `!AppRuntime.headless`；@AppStorage 没有这道闸。
    ///
    /// 走它的键（2026-11-18，全部 @AppStorage + 插卡框「不导入」的记忆）：
    ///   BatchView：batch.thumbSize、batch.gridMode、batch.showSingles、batch.showControls、batch.pendingTakesOnly、
    ///     batch.takeSortByScore、batch.jpegQuality、batch.jpegIncludeUsable、batch.jpegOverwrite、batch.jpegMaxPixel、
    ///     batch.jpegDelivery、batch.highlightsCount、batch.highlightsMaxPixel、batch.highlightsDelivery、batch.isoThreshold、
    ///     batch.isoKeepersOnly、batch.proofWatermark；审片 review.skipRejects；
    ///   DetailView：labelAutoAdvanceAfterScore；PickView（连拍挑选）：pick.autoAdvance；
    ///   CardImportView：cardImport.analyzeAfter、cardImport.dismissed。
    /// 不走它的：BatchStore 的 batch.rejectBurstDuplicates / minKeepersPerChapter / sortOrder（pinBatchSettings + didSet 的闸）、
    /// ui.theme（ThemeCenter 自己的闸）、拼图偏好（CollageWorkspace 自己的闸）、whatsNew.*、live.bridgeEnabled（只有界面写）。
    static let viewDefaults: UserDefaults = {
        guard CommandLine.arguments.contains(where: { headlessFlags.contains($0) }) else { return .standard }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LabelGUI-view-settings-\(UUID().uuidString)", isDirectory: true)
        headlessViewDefaultsDir = dir.path
        atexit {
            if let dir = AppRuntime.headlessViewDefaultsDir { try? FileManager.default.removeItem(atPath: dir) }
        }
        // 绝对路径的 suite 名：只读写 <路径>.plist。init(suiteName:) 只在名字是 app 自己的 bundle id 或 NSGlobalDomain 时
        // 返回 nil，这里走不到；真走到了也不退回 .standard（那就又写设置域了）。
        guard let defaults = UserDefaults(suiteName: dir.appendingPathComponent("view").path) else {
            fatalError("建不了无头的视图设置（\(dir.path)）")
        }
        return defaults
    }()

    /// 无头时那份视图设置的临时目录（退出时删）；界面运行时是 nil。--view-prefs-selftest 核对它在临时目录里。
    static var headlessViewDefaultsDir: String?
}
