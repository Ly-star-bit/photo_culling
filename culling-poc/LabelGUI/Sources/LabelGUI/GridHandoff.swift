import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 网格照片交给别的 app（优化分析 GP-07 / UX-02）
//
// 格子右键菜单里的「在访达中显示」「用…打开」，和拖出去（GridDragOut.swift）用的都是这里：给哪几个文件、哪些 app 能开。
// 只把原片交给对方（打开、在访达里选中、拖出是复制），不写任何 app 的目录库 / session，原片一个字节不动。

/// 网格格子的右键菜单（BatchView 的 CellMenu 盯着它）：菜单内容怎么建、现在选中了哪些。批量页拿 @State 存着、自己不订阅
/// （和 GridViewport 同一个办法），body 每跑一次把选中和建菜单的闭包抄进来（sync，不发通知）；选中的张数一变 bump 一下，
/// 弹过的菜单下次弹时重建。
///
/// 为什么要它（实测，--events-selftest 那条「选中了别的一张再右键」）：
///   - 菜单弹过一次，SwiftUI 就留着那份内容；格子没重算（这一格没选上、判决没变），下次弹的还是旧的。
///   - 菜单内容要是用格子自己留着的闭包建，闭包里抓的是批量页上次画这一格时的那一份：在菜单的 body 里读批量页的 @State
///     （selectedIDs），读到的是那时候的旧值。所以选中从这里拿；点菜单项时（body 外面）读的是现在的，动作照旧现取。
///   - 建菜单的闭包放这里、不放进每一格的 GridCell.Actions：Actions 每格每次重算都要新建，多一个抓着整个批量页的闭包，
///     --perf grid 的方向键每下多约 0.8 百万条指令（release 实测）；放这里一次 body 只建一个。
final class GridMenuState: ObservableObject {
    private(set) var selected: Set<String> = []
    private(set) var build: ((String, Set<String>) -> AnyView)?
    @Published private(set) var version = 0

    func sync(_ selected: Set<String>, build: @escaping (String, Set<String>) -> AnyView) {
        self.selected = selected
        self.build = build
    }

    func bump() { version &+= 1 }
}

enum GridHandoff {
    /// 一张照片的原片文件：原图（RAW 或 JPG），RAW+JPG 双存时再加 JPG 那一半 —— 和「复制原片到…」同一个规则
    /// （OriginalsCopier.copy 的 images）。旁边的 .xmp 不给：拖出 / 在访达里选中是交给别的 app 或文件夹的，xmp 拖进
    /// Photoshop、微信是一个打不开的怪文件；C1 / LR 打开原片时自己读旁边的 xmp。要连 xmp 一起带走的用「复制原片到…」。
    /// 磁盘上已经没有的（盘没挂、文件被挪走）不给。
    static func originals(rawPath: String, decodePath: String) -> [URL] {
        var paths = [rawPath]
        if decodePath != rawPath { paths.append(decodePath) }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// 「用…打开」打开哪个文件：原图（RAW+JPG 双存时只开 RAW）。两个都开的话，Photoshop 一张照片开两个文档、
    /// Capture One 导进两份；要 JPG 那一半的拖出去或在访达里拿。磁盘上没有的不给。
    static func primary(rawPath: String) -> URL? {
        FileManager.default.fileExists(atPath: rawPath) ? URL(fileURLWithPath: rawPath) : nil
    }

    /// 「用…打开」列出来的一个 app。
    struct App: Identifiable {
        let url: URL
        let name: String
        let isDefault: Bool
        var id: String { url.path }
    }

    /// 常用的修图软件（bundle id，不是路径）：装了就列上，哪怕它的 Info.plist 没声明这种 RAW（新机身的扩展名
    /// 它还没登记）。Capture One 每个大版本换一次 id，几个都问一遍，没装的问不到就算了。
    static let knownEditors = [
        "com.adobe.LightroomClassicCC7", "com.adobe.lightroomCC", "com.adobe.mas.lightroomCC", "com.adobe.Photoshop",
        "com.captureone.captureone16", "com.captureone.captureone15", "com.captureone.captureone14",
        "com.phaseone.captureone13", "com.phaseone.captureone12",
    ]

    /// 能打开这些文件的 app（问 LaunchServices，不写死路径）：几种扩展名混在一起时只列每种都能开的。
    /// 排序：第一张那种文件的默认 app 打头，再是装了的常用修图软件，其余按名字。本程序自己不列。
    /// 右键菜单弹出时现查（每次几毫秒），不在格子里算。
    static func apps(toOpen files: [URL]) -> [App] {
        let workspace = NSWorkspace.shared
        var types: [UTType] = []
        for file in files {
            if let type = UTType(filenameExtension: file.pathExtension), !types.contains(type) { types.append(type) }
        }
        guard let firstType = types.first else { return [] }
        func key(_ url: URL) -> String { Bundle(url: url)?.bundleIdentifier ?? url.standardizedFileURL.path }
        // 每种都能开：第一种的列表按顺序留，后面几种取交集（按 bundle id 认，同一个 app 装了两份只算一个）。
        var list: [URL] = []
        var seen = Set<String>()
        for url in workspace.urlsForApplications(toOpen: firstType) where seen.insert(key(url)).inserted { list.append(url) }
        for type in types.dropFirst() {
            let others = Set(workspace.urlsForApplications(toOpen: type).map(key))
            list.removeAll { !others.contains(key($0)) }
        }
        let editors: [URL] = knownEditors.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        for url in editors where seen.insert(key(url)).inserted { list.append(url) }
        let me = Bundle.main.bundleIdentifier
        list.removeAll { me != nil && key($0) == me }

        let defaultKey = workspace.urlForApplication(toOpen: firstType).map(key)
        let editorKeys = editors.map(key)
        func rank(_ url: URL) -> Int {
            let k = key(url)
            if k == defaultKey { return 0 }
            return editorKeys.contains(k) ? 1 : 2
        }
        let apps = list.map { url in
            App(url: url, name: FileManager.default.displayName(atPath: url.path), isDefault: key(url) == defaultKey)
        }
        return apps.sorted { a, b in
            let ra = rank(a.url), rb = rank(b.url)
            return ra != rb ? ra < rb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 菜单里那个 app 的小图标（16pt）。
    static func icon(_ app: App) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        let image = (icon.copy() as? NSImage) ?? icon
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// 用这个 app 打开这些文件（等于拖到它的图标上）。无头不开：只打印要开什么（脚本、自检里不会拉起别的 app）。
    /// 打不开（app 被删了、对方拒收）写进 store.lastError。
    @MainActor
    static func open(_ files: [URL], with app: App, store: BatchStore) {
        guard !files.isEmpty else { return }
        guard !AppRuntime.headless else {
            print("用…打开（无头不开）：\(app.name) ← \(files.map(\.lastPathComponent).joined(separator: ", "))")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: app.url, configuration: configuration) { _, error in
            guard let error else { return }
            let text = "用「\(app.name)」打开没成功：\(error.localizedDescription)"
            DispatchQueue.main.async { store.lastError = text }
        }
    }
}
