import Foundation
import AppKit
import CryptoKit

/// 桥上的方法表（DESIGN §9.4.2）：每个方法一个主线程上的 async 函数 `(请求) -> 回复`，GUI 和 --live-host 是同一份
/// （LiveServer.attach 里注册；test.* 只有 LiveHost 注册）。STEP 3a 是三个读：cull.read、cull.preview、collage.state。
/// - 主线程上只做便宜的：核对场次、按 id 把 BatchItem 复制出来（值类型）、拼摘要；解码、裁切、编码 JPEG、base64、
///   编辑指纹都在 Task.detached 里（§10.3 第 2 步），等的时候主线程是空的。JSON 编码和写 socket 在连接自己的队列上。
/// - 回复一律经 LiveWire.encode → MCPJSON（先 sanitize：NaN / inf 换成 null，isValidJSONObject 不过就回 internal，
///   §10.4），所以 store 里的非有限数不会让用户的 app 闪退。
/// - 参数和 `--mcp` 用同一份校验（MCPArgs，§9.2.3）；`--mcp` 已经查过一遍，这里是权威的那一遍。
@MainActor
enum LiveHandlers {
    /// text 留给 `--mcp` 补 warnings 的余量（它在结果后面接 probe 的提醒、版本不同的提醒）。
    static let textReserve = 1_500

    static func register(_ live: LiveServer, model: AppModel) {
        live.register("cull.read", kind: .read) { [weak live, weak model] req in
            guard let live, let model else { return quitting }
            return cullRead(req, live: live, model: model)
        }
        live.register("cull.preview", kind: .read) { [weak live, weak model] req in
            guard let live, let model else { return quitting }
            return await cullPreview(req, live: live, model: model)
        }
        live.register("collage.state", kind: .read) { [weak live, weak model] req in
            guard let live, let model else { return quitting }
            return await collageState(req, live: live, model: model)
        }
    }

    static let quitting = LiveServer.Reply.failure("not_ready", "选片工具正在退出", nil)

    static func invalid(_ message: String, hint: String = "") -> LiveServer.Reply {
        .failure("invalid_argument", message, hint.isEmpty ? nil : ["hint": hint])
    }

    /// app 当前那一场的 key（没打开任何场次 = nil）。
    static func currentKey(_ batch: BatchStore) -> String? {
        batch.photoDir == nil ? nil : batch.sessionDir.lastPathComponent
    }

    static func sessionNotOpen(_ live: LiveServer, _ model: AppModel) -> LiveServer.Reply {
        let open: Any = live.openSessionObject(model) ?? NSNull()
        return .failure("session_not_open", "app 当前打开的不是这一场", ["open_session": open])
    }

    // MARK: - cull.read（§10.4）

    /// params {"session":"<key>","kind":"overview|photos|get|groups","args":{…MCP 工具的参数，去掉 session…},"text_max":N}
    static func cullRead(_ req: LiveServer.Request, live: LiveServer, model: AppModel) -> LiveServer.Reply {
        guard let raw = req.params["kind"] as? String, let kind = MCPReadModel.Kind(rawValue: raw) else {
            return invalid("kind 只能是 overview / photos / get / groups")
        }
        let args = req.params["args"] as? [String: Any] ?? [:]
        if let p = MCPArgs.check(kind.tool, args) { return invalid(p.message, hint: p.hint) }
        let batch = model.batch
        guard let key = currentKey(batch), req.params["session"] as? String == key else { return sessionNotOpen(live, model) }
        let asked: Int = min(max(LiveWire.int(req.params["text_max"]) ?? 20_000, 1_000), 1_000_000)
        // 余量最多留四分之一：LABELGUI_MCP_TEXT_MAX 设得小（比如 2000）时不至于只剩几百字
        let reserve: Int = min(textReserve, asked / 4)
        switch MCPReadModel.read(kind, store: batch, session: key, args: args, textMax: asked - reserve) {
        case .success(var r):
            r["pending_writes"] = live.pendingWrites
            return .result(r)
        case .failure(let f):
            return .failure(f.code, f.message, ["hint": f.hint])
        }
    }

    // MARK: - cull.preview（§10.3 app 一侧）

    /// params {"session","ids","crop","max_edge","budget_kb"}。`budget_kb`：这一次合计给多少字节（`--mcp` 按
    /// LABELGUI_MCP_INLINE_KB 给；app 看不到 `--mcp` 的环境变量）。
    static func cullPreview(_ req: LiveServer.Request, live: LiveServer, model: AppModel) async -> LiveServer.Reply {
        // 第 1 步（主线程，便宜）：参数、场次、按 id 复制 BatchItem、受保护位置只按字符串判断
        var args: [String: Any] = [:]
        for name in ["ids", "crop", "max_edge"] { if let v = req.params[name] { args[name] = v } }
        if let p = MCPArgs.check("cull_preview_photos", args) { return invalid(p.message, hint: p.hint) }
        let batch = model.batch
        guard let key = currentKey(batch), req.params["session"] as? String == key else { return sessionNotOpen(live, model) }
        let ids = MCPArgs.uniqueStrings(req.params["ids"])
        var items: [BatchItem] = []
        var missing: [String] = []
        for id in ids {
            if let item = batch.item(withID: id) { items.append(item) } else { missing.append(id) }
        }
        guard !items.isEmpty else {
            return .failure("photo_not_found", "这些 id 在 app 当前这一场里都没有：\(missing.joined(separator: ", "))",
                            ["hint": "id 是文件名去掉扩展名；先 cull_list_photos 看有哪些"])
        }
        let folder = batch.photoDir?.path ?? ""
        let job = PreviewJob(items: items, face: req.params["crop"] as? String == "face",
                             edge: LiveWire.int(req.params["max_edge"]) ?? LiveImages.defaultEdge(count: items.count),
                             protected: isProtectedFolder(folder, live: live),
                             budget: min(max(LiveWire.int(req.params["budget_kb"]) ?? 600, 1), 20_000) * 1024,
                             gone: req.clientGone)
        // 第 2 步（离开主线程）：解码、裁切、缩放、编码、base64
        let box = LiveBox(job)
        let done = await Task.detached(priority: .userInitiated) { LiveBox(await box.value.run()) }.value
        // 第 3 步：回复（编码和写出在连接队列上）
        var out = done.value
        out["missing_ids"] = missing
        out["pending_writes"] = live.pendingWrites
        let images = out["images"] as? [[String: Any]] ?? []
        if !images.contains(where: { $0["jpeg_b64"] != nil }), !(out["truncated"] as? Bool ?? false) {
            return .failure("preview_missing", "这几张的预览文件没有、原图也读不了",
                            ["hint": "请用户在 app 里点「重新分析」补回预览", "failed": out["failed"] ?? []])
        }
        return .result(out)
    }

    /// 照片文件夹是不是受保护位置（§10.4 第 4 条的纯字符串函数，app 一侧是权威判断）。测试宿主另认
    /// LABELGUI_LIVE_TEST_PROTECTED_PREFIX（§10.7 第 33 条：把合成图目录当成受保护前缀；GUI 不读这个变量）。
    static func isProtectedFolder(_ folder: String, live: LiveServer) -> Bool {
        if ProtectedPaths.isProtected(folder) { return true }
        guard let raw = live.testProtectedPrefix, let prefix = testKey(raw), let key = testKey(folder) else { return false }
        return key == prefix || key.hasPrefix(prefix + "/")
    }

    /// 测试前缀按字符串比（和 ProtectedPaths 同一种折叠；/private/tmp 和 /tmp 当成一回事）。
    static func testKey(_ path: String) -> String? {
        guard var k = ProtectedPaths.comparisonKey(path, home: "") else { return nil }
        for p in ["/private/var/", "/private/tmp/", "/private/etc/"] where k.hasPrefix(p) {
            k = String(k.dropFirst("/private".count))
        }
        return k
    }

    // MARK: - collage.state（§9.3 + §10.4）

    /// params {"session"?,"include_preview","max_edge"}。不带 session = app 当前那一场（没打开任何场次时 session:null）。
    static func collageState(_ req: LiveServer.Request, live: LiveServer, model: AppModel) async -> LiveServer.Reply {
        var args: [String: Any] = [:]
        for name in ["include_preview", "max_edge"] { if let v = req.params[name] { args[name] = v } }
        if let p = MCPArgs.check("collage_get_state", args) { return invalid(p.message, hint: p.hint) }
        if let raw = req.params["session"], !(raw is NSNull), !(raw is String) { return invalid("session 要是字符串") }
        // §9.4.3 第 5 步在第 7 步之前：场次不对就不去碰拼图工程（挂的时候会按批量页刷托盘，可能写 collage.json）
        let batch = model.batch
        let current = currentKey(batch)
        if let want = req.params["session"] as? String, want != current { return sessionNotOpen(live, model) }
        // 第 7 步：先挂好（STEP 0 以后通常是空操作）
        model.ensureCollageAttached()
        let collage = model.collage
        let project = collage.project
        var out: [String: Any] = ["source": "app"]
        out["session"] = current ?? NSNull()
        out["mode"] = project.mode.rawValue
        out["page"] = project.pages.isEmpty ? 0 : collage.pageIndex + 1
        out["pages"] = project.pages.count
        let key = styleKey(project.style)
        out["style"] = key ?? NSNull()
        out["style_name"] = key.flatMap { k in CollageStyles.all.first { $0.key == k }?.name } ?? NSNull()
        out["look"] = project.style.look.rawValue
        out["look_strength"] = MCPReadModel.r3(project.style.lookStrength)
        out["title"] = project.title
        out["subtitle"] = project.subtitle
        out["masthead"] = project.masthead
        out["issue"] = project.issue
        out["tray"] = project.photos.count
        if let page = collage.page {
            out["cells"] = cells(page)
            out["page_kind"] = page.contactSheet != nil ? "contact_sheet" : (page.freeform ? "freeform" : "grid")
            out["items"] = page.items.count
        } else {
            out["cells"] = [[String: Any]]()
        }
        out["selection"] = collage.selection.map { path in path.map(String.init).joined() } ?? NSNull()
        var undo: [String: Any] = ["collage_depth": collage.undoDepth, "can_undo": collage.canUndo]
        undo["can_redo"] = collage.canRedo
        undo["verdict_can_undo"] = batch.canUndoOverride
        // AI 自己的操作记录（aiLog）在 STEP 3b 才有：这一步桥上还没有任何写，最上面那一步一定不是 AI 做的
        undo["top_is_ai"] = false
        out["undo"] = undo
        out["busy"] = ["solving": collage.isSolving, "hints_pending": collage.hintsPending]
        out["tab"] = LiveServer.tabName(model.tab)
        let (_, ws) = live.windowState()
        out["window_state"] = ws
        out["window_visible"] = ws == "visible"
        out["pending_writes"] = live.pendingWrites
        let include = req.params["include_preview"] as? Bool ?? true
        let edge = LiveWire.int(req.params["max_edge"]) ?? 768
        let image: CGImage? = include ? collage.preview?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
        // 编辑指纹和预览的编码离开主线程（工程是值类型，复制一份带过去）
        let box = LiveBox((project, image))
        let extra = await Task.detached(priority: .userInitiated) { () -> LiveBox<[String: Any]> in
            let (p, img) = box.value
            var e: [String: Any] = ["digest": editDigest(p)]
            if let img, let enc = LiveImages.encode(img, maxEdge: edge) {
                e["preview_jpeg_b64"] = enc.data.base64EncodedString()
                e["preview_width"] = enc.width
                e["preview_height"] = enc.height
                e["preview_bytes"] = enc.data.count
            }
            return LiveBox(e)
        }.value
        out.merge(extra.value) { _, new in new }
        var warnings: [[String: Any]] = []
        if include && out["preview_jpeg_b64"] == nil {
            let message = project.pages.isEmpty ? "拼图里还没有任何一页，没有预览。" : "app 的预览还没渲出来。"
            warnings.append(MCPReadModel.warning("no_preview", message, hint: project.pages.isEmpty
                ? "先 collage_apply_template 或 collage_run_kit 排一版（STEP 3b）"
                : "过一秒再调 collage_get_state"))
        }
        out["warnings"] = warnings
        return .result(out)
    }

    /// 当前页的格子（切分树的叶子，按阅读顺序）：path 是孩子下标连起来（"01"），overlays 是压在照片上的字块数。
    static func cells(_ page: CollagePage) -> [[String: Any]] {
        page.root.leafPaths().compactMap { path -> [String: Any]? in
            guard let cell = page.root.node(at: path)?.cell else { return nil }
            var row: [String: Any] = ["path": path.map(String.init).joined(), "kind": cell.kind.rawValue]
            row["photo_id"] = cell.photoID ?? NSNull()
            row["overlays"] = cell.overlays.count
            return row
        }
    }

    /// 工程的样式是哪个预设（色调、强度另算，§9.3 的 style / look 分开报）；改过任何一项就不是任何预设 = nil。
    static func styleKey(_ style: CollageStyle) -> String? {
        CollageStyles.all.first { preset in
            var s = style
            s.look = preset.style.look
            s.lookStrength = preset.style.lookStrength
            return s == preset.style
        }?.key
    }

    /// 编辑指纹（§9.3 第二轮改）：工程的 JSON（键排序）取 SHA-1 前 12 位，但托盘照片只留按顺序的 id —— 判决、
    /// 亮度、黑白这些后台自己会刷新的字段不算（改判后刷新托盘、路人信息算完都不让 if_digest 失效）。
    /// STEP 3b 的 CollageStore.editDigest 要和它一致（或者挪过去）；这一步不改 store。
    nonisolated static func editDigest(_ project: CollageProject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(project),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "?" }
        object["photos"] = project.photos.map(\.id)
        guard let reduced = MCPJSON.data(object) else { return "?" }
        return Insecure.SHA1.hash(data: reduced).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}

/// cull.preview 的第 2 步（§10.3）：一张张出图。不在主线程上，不碰任何 store：只拿主线程复制出来的 BatchItem。
/// - crop=full、max_edge ≤ 1024：ImageIO 从分析预览缩，source "preview"。
/// - crop=full、max_edge > 1024：文件夹不受保护 → 从原图解缩略图（只解到目标尺寸），source "original"；
///   受保护或原图读不到 → 退回 1024 预览，warning 写原因。
/// - crop=face：文件夹不受保护 → CompareZoom.load（和连拍挑选的放大同一个算法、同一条队列、同一份缓存），source "original"；
///   受保护或原图读不到 → 在 1024 预览上按 CompareZoom.region 裁，source "preview"，warning。
///   **受保护位置不读原图**（§10.3 的保守决定）：一次都不去打开它，LiveImages.originalOpens 里也就没有记录。
/// - 预览文件没有、原图也读不了 → failed；合计超过 budget 以后，后面的不给字节、标 truncated（§10.3、§4.4）。
/// - 客户端走了（clientGone，§10.2）：还没开始的就不做了；交给 CompareZoom 的那个取消旗子跟着置上。
struct PreviewJob: @unchecked Sendable {
    let items: [BatchItem]
    let face: Bool
    let edge: Int
    let protected: Bool
    let budget: Int
    let gone: LiveFlag

    enum One {
        case ok(LiveImages.Encoded, source: String, warning: [String: Any]?)
        case failed(String)
    }

    func run() async -> [String: Any] {
        var images: [[String: Any]] = []
        var failed: [[String: Any]] = []
        var warnings: [[String: Any]] = []
        var used = 0
        var truncated = false
        for item in items {
            if gone.isSet { break }
            if truncated {
                images.append(entry(item, nil, source: nil))
                continue
            }
            switch await render(item) {
            case .failed(let reason):
                failed.append(["id": item.id, "reason": reason])
            case .ok(let enc, let source, let warning):
                if var w = warning {
                    w["id"] = item.id
                    warnings.append(w)
                }
                if used + enc.data.count > budget {
                    truncated = true
                    images.append(entry(item, nil, source: nil))
                    continue
                }
                used += enc.data.count
                images.append(entry(item, enc, source: source))
            }
        }
        if truncated {
            let message = "这几张加起来超过了这一次的图片预算 \(budget / 1024) KB：后面的没有给图。"
            warnings.append(MCPReadModel.warning("budget_truncated", message,
                                                 hint: "少看几张、调小 max_edge 再调；或者 LABELGUI_MCP_INLINE_KB 调大"))
        }
        var out: [String: Any] = ["images": images, "failed": failed, "truncated": truncated, "warnings": warnings]
        out["total_bytes"] = used
        return out
    }

    func entry(_ item: BatchItem, _ enc: LiveImages.Encoded?, source: String?) -> [String: Any] {
        var e: [String: Any] = ["id": item.id, "verdict": MCPReadModel.verdictName(item.verdict), "crop": face ? "face" : "full"]
        e["faces"] = item.faceCount
        e["original_path"] = item.rawPath
        guard let enc, let source else {
            e["truncated"] = true
            return e
        }
        e["width"] = enc.width
        e["height"] = enc.height
        e["bytes"] = enc.data.count
        e["source"] = source
        e["jpeg_b64"] = enc.data.base64EncodedString()
        return e
    }

    static let protectedWarning = MCPReadModel.warning(
        "protected_location", "照片在系统隐私保护的位置（桌面、文稿、下载、外置盘……）：没有读原图，这是 1024 预览上的裁块 / 缩图，细节有限。",
        hint: "要看原图细节，请用户把照片挪到别处（比如 ~/Pictures）重新分析")

    static func unreadableWarning(_ path: String) -> [String: Any] {
        MCPReadModel.warning("original_unreadable", "原图读不到（\(path)）：这是 1024 预览上的裁块 / 缩图，细节有限。",
                             hint: "照片文件夹可能被挪走了或者卷没挂上；请用户在 app 里看一下")
    }

    func render(_ item: BatchItem) async -> One {
        var warning: [String: Any]?
        if face {
            if !protected {
                LiveImages.originalOpens.record(item.decodePath)
                let cancel = AnalysisEngine.CancelFlag()
                gone.link(cancel)
                if let crop = await CompareZoom.load(item, cancel: cancel),
                   let cg = crop.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let enc = LiveImages.encode(cg, maxEdge: edge) {
                    return .ok(enc, source: "original", warning: nil)
                }
                if gone.isSet { return .failed("客户端已经断开") }
                warning = Self.unreadableWarning(item.decodePath)
            } else {
                warning = Self.protectedWarning
            }
            if let cg = LiveImages.faceCropOnPreview(item), let enc = LiveImages.encode(cg, maxEdge: edge) {
                return .ok(enc, source: "preview", warning: warning)
            }
            return .failed("预览文件没有（\(item.previewPath)）" + (protected ? "；照片在受保护位置，不读原图" : "，原图也读不了"))
        }
        let previewEdge = min(edge, ImageLoader.previewMaxPixel)
        if edge > ImageLoader.previewMaxPixel {
            if protected {
                warning = Self.protectedWarning
            } else {
                LiveImages.originalOpens.record(item.decodePath)
                if let cg = LiveImages.thumbnail(item.decodePath, maxEdge: edge), let enc = LiveImages.encode(cg, maxEdge: edge) {
                    return .ok(enc, source: "original", warning: nil)
                }
                warning = Self.unreadableWarning(item.decodePath)
            }
        }
        if let cg = LiveImages.thumbnail(item.previewPath, maxEdge: previewEdge),
           let enc = LiveImages.encode(cg, maxEdge: previewEdge) {
            return .ok(enc, source: "preview", warning: warning)
        }
        // 预览被清掉了（掉出最近 15 场）：不受保护就从原图解（§3.2），受保护就只能算失败
        if !protected && edge <= ImageLoader.previewMaxPixel {
            LiveImages.originalOpens.record(item.decodePath)
            if let cg = LiveImages.thumbnail(item.decodePath, maxEdge: edge), let enc = LiveImages.encode(cg, maxEdge: edge) {
                let w = MCPReadModel.warning("preview_file_missing", "分析预览不在了，这张是从原图现解的。",
                                             hint: "请用户在 app 里点「重新分析」补回预览")
                return .ok(enc, source: "original", warning: w)
            }
        }
        return .failed("预览文件没有（\(item.previewPath)）" + (protected ? "；照片在受保护位置，不读原图" : "，原图也读不了"))
    }
}
