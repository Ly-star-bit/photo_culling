import Foundation

/// 一键成套：一次出一整套（一期杂志、一卷印样、一本婚礼相册），替换当前工程，可以撤销。
/// 生成函数各在自己风格的文件里（CollageStyleFashion.issue / CollageStyleFilm.roll / CollageStyleFineArt.weddingAlbum），
/// 这里只管名字、说明和分派：各风格并行开发时互不改对方的文件。还没做的返回 nil，菜单里点了只提示一句。
enum CollageKitID: String, CaseIterable, Identifiable {
    case fashionIssue, contactRoll, weddingAlbum

    var id: String { rawValue }

    var name: String {
        switch self {
        case .fashionIssue: return "出一期"
        case .contactRoll: return "按卷出印样"
        case .weddingAlbum: return "整本婚礼相册"
        }
    }

    /// 菜单上的说明（鼠标悬停）。
    var summary: String {
        switch self {
        case .fashionIssue: return "时尚刊：封面（人物挡字）+ 3 张内页，3:4 多页（小红书轮播），共用刊头、期号、色调"
        case .contactRoll: return "底片印样：按选片结果一个章节一卷（同一章节两台机身各一卷），一卷一页、超过 35 帧接着排下一页（含废片），每场最好那张红笔圈，废片打叉"
        case .weddingAlbum: return "婚礼相册：切到相册、fine-art 样式，按章节开篇、疏密节奏、竖图成对自动编排"
        }
    }

    /// 生成整套；还没做 / 照片不够 = nil。在后台线程跑（CollageStore.applyKit），不碰界面状态。
    func generate(_ context: CollageKits.Context) -> CollageProject? {
        switch self {
        case .fashionIssue: return CollageStyleFashion.issue(context)
        case .contactRoll: return CollageStyleFilm.roll(context)
        case .weddingAlbum: return CollageStyleFineArt.weddingAlbum(context)
        }
    }

    /// 命令行（--kit、ops 的 kit:）按英文 key 或中文名找。
    static func find(_ name: String) -> CollageKitID? {
        allCases.first { $0.rawValue == name || $0.name == name }
    }
}

enum CollageKits {
    /// 生成一套要用的全部东西（值类型 + 一个取批量页照片的闭包，后台线程能直接用）。
    struct Context {
        /// 当前工程：新工程从它改起（托盘、标题、刊头、期号、水印跟着走；页、画布、样式、模式按成套重定）。
        /// 多页的单张拼图（一期杂志）直接把 mode 设成 .single、放好全部页 —— 别走 setMode，它会把多页裁成一页。
        var project: CollageProject
        /// 托盘（= project.photos，单独给出来好读）。
        var tray: [CollagePhotoRef]
        /// 批量页这个场次的全部照片，含废片（印样要整场、整卷的帧）。没开文件夹 / 命令行没给 = 空。
        /// 托盘里没有的照片要用：CollageBridge.ref(from:facts:) 建 ref，加进新工程的 photos。
        var batchItems: () -> [BatchItem]
        /// 场内名次、手动判的（批量页那边才有；建 ref 用）。
        var facts: CollageBridge.Facts
        /// 托盘照片已经算好的路人 / 主体信息（没算到的按需 CollageVision.hints(for:)）。
        var hints: [String: CollageCrop.Hints]
        /// 种子：同一组照片、同一个种子出同一套（「换一套」时换种子）。
        var seed: UInt64
        /// 「换封面」（出一期）：在主图候选里往后轮几张（0 = 照常出一套；当前工程已经是一期时，从它现在的封面往后轮）。
        var coverStep = 0
    }
}
