import Foundation

/// 拼图、水印导出不写进拍摄文件夹（审查 S11）。导出 JPG（BatchStore.exportJPEGs）和复制原片（copyOriginals）早就用
/// OriginalsCopier.insideAnalysis 挡着；拼图（CollageStore.startExport —— 导出按钮、MCP collage_export、命令行 export:
/// 都走它 —— 和「选择…」面板的 chooseOutputFolder）、水印页（WatermarkStore.exportAll、chooseOutputDir）用这里同一套判断：
/// 输出目录落在拍摄文件夹里面、下次分析会扫到的地方就拦下。成品进了拍摄文件夹，下次分析（重新分析、同一天第二张卡导进来、
/// 分析版本升级）就当成新照片：水印副本带着原片的 EXIF（拍摄时间、机身一样），会插进原片的连拍分组；{原名} 模板在纯 RAW
/// 场次还会和 RAF 配成 RAW+JPG。拍摄文件夹里的「水印导出」「拼图导出」这些分析跳过的子文件夹照常。
/// 批量页的最近场次（recentSessions）只提醒、不拦：用户把 ~/Desktop 这种大文件夹当场次开过一次，以后往桌面上导都拦就误伤了。
enum ExportFolderGuard {
    /// 水印页「导出到 水印导出/」用的子文件夹（ImageLoader.excludedSubfolders 里那个，分析时跳过）。
    static let watermarkSubfolder = "水印导出"

    /// `folder` 在 `shoots` 里哪一个拍摄文件夹里面、会被它的分析扫到：返回那个拍摄文件夹；都不在 = nil。
    /// 同一个目录只查一次（水印页几百张照片多半就在一两个文件夹里）。
    static func blockingShoot(_ folder: URL, among shoots: [URL]) -> URL? {
        var seen = Set<String>()
        for shoot in shoots where seen.insert(shoot.standardizedFileURL.path).inserted {
            if OriginalsCopier.insideAnalysis(folder, shoot: shoot) { return shoot }
        }
        return nil
    }

    /// 水印页要查的拍摄文件夹：批量页开着的那一场（WatermarkView 传 batchStore.photoDir）+ 每张照片所在的文件夹
    /// （水印页的照片能从任意文件夹 ⌘O、拖进来，不一定属于哪一场）。按出现的顺序、去重。
    /// 照片所在的文件夹是 app 自己的输出文件夹（路径里有「导出JPG」「水印导出」这些分析跳过的名字）时，拍摄文件夹是
    /// 最上面那一段的上一级（S/导出JPG/精华、S/水印导出、S/导出JPG/水印导出 → S）：这些文件夹分析时根本不扫，
    /// 当成拍摄文件夹会把 S/导出JPG/带水印 误拦下、还说「拍摄文件夹「导出JPG」」；改成 S 以后 S/交付 照样挡住。
    /// 点开头的文件夹不往上推（它的上一级不一定是一场：/Volumes/.timemachine/… 推成 /Volumes 会把所有外置盘都拦了），
    /// 只在它落在别的候选（批量页那一场、别的照片文件夹）分析跳过的子树里时去掉（S/.cache/x 有 S 就不用再查）。
    /// 批量页那一场原样查，不推、不去掉。
    static func watermarkShoots(batch: URL?, photos: [URL]) -> [URL] {
        var dirs: [URL] = []
        var fromPhotos: [Bool] = []
        var seen = Set<String>()
        let batchDirs: [(URL, Bool)] = batch.map { [($0, false)] } ?? []
        let photoDirs: [(URL, Bool)] = photos.map { (photoShootRoot($0.deletingLastPathComponent()), true) }
        for (dir, isPhoto) in batchDirs + photoDirs where seen.insert(dir.standardizedFileURL.path).inserted {
            dirs.append(dir)
            fromPhotos.append(isPhoto)
        }
        var kept: [URL] = []
        for (index, dir) in dirs.enumerated() {
            let covered: Bool = fromPhotos[index] && hasHiddenSegment(dir)
                && dirs.indices.contains { $0 != index && skipped(dir, under: dirs[$0]) }
            if !covered { kept.append(dir) }
        }
        return kept
    }

    /// 照片所在的文件夹往上推到拍摄文件夹：路径里最上面那一段分析跳过的子文件夹名（ImageLoader.excludedSubfolders，
    /// 和 listPhotos 一样按原名比）的上一级；没有就是它自己。
    private static func photoShootRoot(_ dir: URL) -> URL {
        var url = URL(fileURLWithPath: dir.path, isDirectory: true).standardizedFileURL
        var root = url
        while true {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if ImageLoader.excludedSubfolders.contains(url.lastPathComponent) { root = parent }
            guard parent.path != url.path, url.path != "/" else { return root }
            url = parent
        }
    }

    /// 解开软链接以后路径里有点开头的一段（去掉别的候选只可能是因为这个：分析跳过的名字已经在 photoShootRoot 推掉了）。
    /// 先粗筛，几百个照片文件夹两两 stat 不划算（选完目录、点导出都在主线程上）。
    private static func hasHiddenSegment(_ dir: URL) -> Bool {
        let parts = dir.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return parts.contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }

    /// `folder` 在 `shoot` 里面、而且落在它分析跳过的子树里（中间有一段是排除的子文件夹名或点开头）：`shoot` 的分析扫不到它。
    /// 和 OriginalsCopier.insideAnalysis 同一种往上走法（设备号 + inode）；stat 不到 `shoot`、不在里面 = false。
    private static func skipped(_ folder: URL, under shoot: URL) -> Bool {
        var root = stat()
        guard stat(shoot.path, &root) == 0 else { return false }
        var url = folder.resolvingSymlinksInPath().standardizedFileURL
        var below: [String] = []
        while true {
            var here = stat()
            if stat(url.path, &here) == 0, here.st_dev == root.st_dev, here.st_ino == root.st_ino {
                return below.contains { ImageLoader.excludedSubfolders.contains($0) || $0.hasPrefix(".") }
            }
            guard url.path != "/" else { return false }
            below.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
    }

    /// 拦下时那句话，照导出 JPG 的写（那边多一句「勾了覆盖……」，这两处没有覆盖选项）。
    /// `what` = 导出的是什么（「水印副本」「拼图」），`fix` = 该点哪个（「用「导出到 水印导出/」」）。
    static func refusal(shoot: URL, what: String, fix: String) -> String {
        let head = "不能导出到拍摄文件夹「\(shoot.lastPathComponent)」里面：下次分析会把\(what)当成新照片。"
        return head + "请\(fix)，或选拍摄文件夹外面的文件夹"
    }

    /// 最近场次里有哪一场的拍摄文件夹装着 `folder`（以后分析那一场会扫到）：提醒的那句话；都没有 = nil。只提醒、不拦。
    /// 先按名字粗筛（场次文件夹的名字得出现在输出目录的路径里）再 stat：不相干的盘、断了的网络盘一个都不碰
    /// （选完目录、点导出都在主线程上）。场次路径最后一段本身是软链接、名字和真目录不同的认不出来 —— 只是提醒，不追。
    static func sessionReminder(_ folder: URL, sessions: [BatchStore.SessionEntry], what: String) -> String? {
        let parts = Set(folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() })
        for session in sessions {
            let shoot = URL(fileURLWithPath: session.path)
            guard parts.contains(shoot.lastPathComponent.lowercased()) else { continue }
            if OriginalsCopier.insideAnalysis(folder, shoot: shoot) {
                return "提醒：输出目录在场次「\(session.name)」的拍摄文件夹里，以后再分析那一场会把\(what)当成新照片"
            }
        }
        return nil
    }
}
