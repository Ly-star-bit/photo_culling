import Foundation
import AppKit
import CryptoKit
import ImageIO

/// 桥上的方法表（DESIGN §9.4.2）：每个方法一个主线程上的 async 函数 `(请求) -> 回复`，GUI 和 --live-host 是同一份
/// （LiveServer.attach 里注册；test.* 只有 LiveHost 注册）。三个读：cull.read、cull.preview、collage.state（STEP 3a）；
/// 九个写和 §9.4.3 的流水线在文件后半（STEP 3b）。
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
        // 导出前检查（相册 A + B · M，LiveAlbumHandlers.swift）：只读，离开主线程跑
        live.register("collage.preflight", kind: .read) { [weak live, weak model] req in
            guard let live, let model else { return quitting }
            return await preflightRead(req, live: live, model: model)
        }
        registerWrites(live, model: model)
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
        let protected = previewReadsProtected(folder: folder, items: items) { isProtectedFolder($0, live: live) }
        let job = PreviewJob(items: items, face: req.params["crop"] as? String == "face",
                             edge: LiveWire.int(req.params["max_edge"]) ?? LiveImages.defaultEdge(count: items.count),
                             protected: protected,
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

    /// cull.preview 按不按受保护处理（§10.3 不读原图）：照片文件夹之外，每张要出图的照片自己的 decode_path / raw_path
    /// 也按字符串看一遍，任一受保护就算。GUI 跟着书签打开过挪了的文件夹、「重新定位」过（或者挪了以后点过「重新分析」）的
    /// 场次，manifest 里的照片路径已经在新位置（桌面、外置盘），实时桥按登记的旧路径打开时 photoDir 还停在旧路径上 ——
    /// 只看 photoDir 会替 AI 去读受保护位置的原图（§10.4）。只比字符串，不碰文件系统。
    static func previewReadsProtected(folder: String, items: [BatchItem], isProtected: (String) -> Bool) -> Bool {
        if isProtected(folder) { return true }
        return items.contains { isProtected($0.decodePath) || isProtected($0.rawPath) }
    }

    /// 这一场 manifest 记的拍摄文件夹（photo_dir）：只读数据目录里的 JSON，不碰照片文件夹。读不出来 = nil。
    static func recordedPhotoDir(dataDir: URL, key: String) -> String? {
        let url = dataDir.appendingPathComponent("sessions").appendingPathComponent(key).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["photo_dir"] as? String
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
        for name in ["include_preview", "max_edge", "candidates_for", "candidates_limit"] { if let v = req.params[name] { args[name] = v } }
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
        let key = styleKey(project.style)
        out["style"] = key ?? NSNull()
        out["style_name"] = key.flatMap { k in CollageStyles.all.first { $0.key == k }?.name } ?? NSNull()
        out["look"] = project.style.look.rawValue
        out["look_strength"] = MCPReadModel.r3(project.style.lookStrength)
        out["film_grain"] = MCPReadModel.r3(project.style.filmGrain)
        out["film_halation"] = MCPReadModel.r3(project.style.filmHalation)
        out["film_exposure"] = MCPReadModel.r3(project.style.filmExposure)
        out["film_warmth"] = MCPReadModel.r3(project.style.filmWarmth)
        out["film_format"] = project.style.filmFormat.rawValue
        out["title"] = project.title
        out["subtitle"] = project.subtitle
        out["masthead"] = project.masthead
        out["issue"] = project.issue
        out["tray"] = project.photos.count
        // 相册的目标跨页数（F06）：设了才报
        if let b = project.albumBudget { out["album_target"] = CollageBudgetChange.targetInfo(b) }
        out["canvas"] = canvasInfo(project.canvas)
        out["style_fields"] = styleFields(project.style)
        let (rows, cut) = trayRows(collage)
        out["tray_photos"] = rows
        if cut { out["tray_photos_truncated"] = true }
        // 页码、格子、版式（编辑封面时是封面那一块，editing_cover: true，见 LiveAlbumHandlers 的文件头）
        out.merge(pageFields(collage)) { _, new in new }
        // 相册整本的摘要（相册 A + B · M）：每个跨页的照片、锁、印厂规格的页数、封面
        if collage.isAlbum { out["album"] = albumInfo(collage) }
        // 换照片的候选（S6，同「格式 › 换一张」）
        if let target = req.params["candidates_for"] as? String {
            guard collage.photoMap[target] != nil else {
                return invalid("托盘里没有「\(target)」，拿不了换它的候选。", hint: "照片 id 见 tray_photos 或 cells[].photo_id")
            }
            let limit = LiveWire.int(req.params["candidates_limit"]) ?? 12
            out["candidates"] = candidateRows(collage, for: target, limit: limit)
        }
        out["variants"] = variantsList(collage)
        out["selection"] = collage.selection.map { path in path.map(String.init).joined() } ?? NSNull()
        var undo: [String: Any] = ["collage_depth": collage.undoDepth, "can_undo": collage.canUndo]
        undo["can_redo"] = collage.canRedo
        undo["verdict_can_undo"] = batch.canUndoOverride
        undo["verdict_depth"] = batch.overrideUndoDepth
        // 最上面那一步是不是 AI 做的、现在还能不能用 app_undo 撤（和 app_undo 同一个判断）
        undo["top_is_ai"] = model.aiLog.canUndo(.collage, pushes: collage.undoPushes, depth: collage.undoDepth)
        out["undo"] = undo
        // refining：挪照片、加照片、「拼图 (N)」已经落下，后台还在精排（落下来版式会再变一次，不另压撤销）
        out["busy"] = ["solving": collage.isSolving, "refining": collage.isRefining, "hints_pending": collage.hintsPending]
        out["tab"] = LiveServer.tabName(model.tab)
        let (_, ws) = live.windowState()
        out["window_state"] = ws
        out["window_visible"] = ws == "visible"
        out["pending_writes"] = live.pendingWrites
        let include = req.params["include_preview"] as? Bool ?? true
        let edge = LiveWire.int(req.params["max_edge"]) ?? 768
        // 暗房开着时画布预览攒着不渲（CollageStore.setNeedsRender）：要预览就先渲出来，别给暗房之前那张。
        // 暗房没开时照旧：读手里那张，不等。
        if include && collage.previewDeferred { _ = await collage.previewSettled(timeout: 1.5) }
        let image: CGImage? = include ? collage.preview?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
        // 编辑指纹和预览的编码离开主线程（工程是值类型，复制一份带过去）
        let box = LiveBox((project, image))
        let extra = await Task.detached(priority: .userInitiated) { () -> LiveBox<[String: Any]> in
            let (p, img) = box.value
            var e: [String: Any] = ["digest": CollageStore.editDigest(p)]
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
                ? "先 collage_apply_template 或 collage_run_kit 排一版"
                : "过一秒再调 collage_get_state"))
        }
        out["warnings"] = warnings
        return .result(out)
    }

    /// 当前页的格子（切分树的叶子，按阅读顺序）：path 是孩子下标连起来（"01"），overlays 是压在照片上的字块数，
    /// rect 是这一格在画布上的位置（[x, y, 宽, 高]，相对画布宽高；散落版、印样没有）。canvas：这一页的画布（编辑封面时是
    /// 封面那一页，CollageStore.editCanvas；不给 = 工程的画布）。
    static func cells(_ page: CollagePage, project: CollageProject, canvas pageCanvas: CollageCanvas? = nil) -> [[String: Any]] {
        let canvas = pageCanvas ?? project.canvas
        var rects: [[Int]: [Double]] = [:]
        if !page.freeform, page.contactSheet == nil {
            let w = Double(max(1, canvas.width))
            let h = Double(max(1, canvas.height))
            for f in CollageLayout.pageGeometry(page.root, canvas: canvas, style: project.style).frames {
                let r = f.rect.cgRect
                let box: [Double] = [Double(r.minX) / w, Double(r.minY) / h, Double(r.width) / w, Double(r.height) / h]
                rects[f.path] = box.map(MCPReadModel.r3)
            }
        }
        return page.root.leafPaths().compactMap { path -> [String: Any]? in
            guard let cell = page.root.node(at: path)?.cell else { return nil }
            var row: [String: Any] = ["path": path.map(String.init).joined(), "kind": cell.kind.rawValue]
            row["photo_id"] = cell.photoID ?? NSNull()
            row["overlays"] = cell.overlays.count
            if let rect = rects[path] { row["rect"] = rect }
            return row
        }
    }

    static func canvasInfo(_ canvas: CollageCanvas) -> [String: Any] {
        ["name": canvas.name, "width": canvas.width, "height": canvas.height, "fold": canvas.seams == .fold]
    }

    /// 样式里能单独调的几项（collage_set_style 的同名参数）。
    static func styleFields(_ style: CollageStyle) -> [String: Any] {
        var out: [String: Any] = ["margin": MCPReadModel.r3(style.margin), "gutter": MCPReadModel.r3(style.gutter)]
        out["corner"] = MCPReadModel.r3(style.corner)
        out["background"] = CollageLayoutSpec.hex(style.background)
        // 底色不是纯色（从主图取色、模糊铺底）时 background 不起作用；四边不一样的边距优先于 margin
        out["background_mode"] = style.backgroundMode.rawValue
        if let i = style.insets {
            let insets: [String: Any] = ["top": MCPReadModel.r3(i.top), "bottom": MCPReadModel.r3(i.bottom),
                                         "inner": MCPReadModel.r3(i.inner), "outer": MCPReadModel.r3(i.outer)]
            out["insets"] = insets
        }
        out["shape"] = CollageLayoutSpec.shapes.first { $0.value == style.shape }?.key ?? NSNull()
        return out
    }

    /// 托盘里的照片（设计版式要看比例）：最多 trayRowLimit 行（大场次的托盘可能上千张）。
    static let trayRowLimit = 200

    static func trayRows(_ collage: CollageStore) -> (rows: [[String: Any]], truncated: Bool) {
        let usage = collage.photoUsage
        let rows = collage.project.photos.prefix(trayRowLimit).map { p -> [String: Any] in
            var row: [String: Any] = ["id": p.id, "width": p.width, "height": p.height, "faces": p.faces.count]
            row["pick"] = p.isPick
            // 客户选中才报（没导入过客户选择的场次，行和以前一样）
            if p.clientPick { row["client_pick"] = true }
            row["used"] = usage[p.id] ?? 0
            return row
        }
        return (Array(rows), collage.project.photos.count > trayRowLimit)
    }

    /// 换这张照片的候选（S6 CollageStore.replacementCandidates，同「格式 › 换一张」）：理由（同连拍 / 同场 / 相似）、分数、
    /// 用在第几个跨页（从 1 起；null = 没上版）、废片、客户选中。排序是 store 的：没用过的在前，同连拍 > 同场 > 相似，再按分数。
    static func candidateRows(_ collage: CollageStore, for id: String, limit: Int) -> [String: Any] {
        let list = collage.replacementCandidates(forPhoto: id, limit: limit)
        let rows = list.map { c -> [String: Any] in
            var row: [String: Any] = ["id": c.photoID, "reason": candidateReason(c.reason), "reason_label": c.reason.label]
            row["score"] = MCPReadModel.r3(c.score)
            row["page"] = c.page.map { $0 + 1 } ?? NSNull()
            row["reject"] = c.reject
            row["client_pick"] = c.clientPick
            return row
        }
        var out: [String: Any] = ["photo": id, "rows": rows]
        // 这张自己在第几个跨页（换的时候 path 指它所在的那一格）
        let pages = collage.project.pages
        out["page"] = pages.indices.first { pages[$0].photoIDs.contains(id) }.map { $0 + 1 } ?? NSNull()
        return out
    }

    nonisolated static func candidateReason(_ r: CollageReplacement.Reason) -> String {
        switch r {
        case .burst: return "burst"
        case .take: return "take"
        case .similar: return "similar"
        }
    }

    /// 工程的样式是哪个预设（色调、强度另算，§9.3 的 style / look 分开报）；改过任何一项就不是任何预设 = nil。
    static func styleKey(_ style: CollageStyle) -> String? {
        CollageStyles.all.first { preset in
            // 色调这一类（色调、强度、光谱胶片的颗粒晕光）不算样式：换进光谱色调会带上起始颗粒，样式还是那一套。
            var s = style
            s.look = preset.style.look
            s.lookStrength = preset.style.lookStrength
            s.filmGrain = preset.style.filmGrain
            s.filmHalation = preset.style.filmHalation
            s.filmExposure = preset.style.filmExposure
            s.filmWarmth = preset.style.filmWarmth
            s.filmFormat = preset.style.filmFormat
            return s == preset.style
        }?.key
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

// MARK: - 写（STEP 3b：§9.3 的 9 个写方法，§9.4.3 的流水线）

/// 写方法的流水线（§9.4.3，顺序固定）。LiveServer.execute 已经做了第 3 步（deadline、clientGone）、第 4 步（op_id 缓存）
/// 和写 FIFO；这里接着做：
/// 5. 核对：桥开着、写的是 app 当前那一场、没在分析（改判 / 切场次 / 撤判决）、带了 if_digest 就核对编辑指纹；
/// 6. 忙信号（§9.6b）：一时的原因每 50 ms 看一次、最多等 busy_wait_ms，一直的原因立刻 user_busy；
/// 6a. 等过之后把 deadline、clientGone 和第 5 步原样再做一遍 —— 从这里到执行那一行同步 store 调用之间不再有 await，
///     核对过的就是执行时的状态（等的那 2 s 里用户可能自己切了场次、开始了分析、改了版式）；
/// 7. 拼图操作先 ensureCollageAttached；8. 标题栏 → 「AI 正在操作：套模板…」（settle 放行的那一刻；成套 / 换封面在等路人
///    信息之前就亮：那一段可能等到 20 s，画布不动，标题栏得说 app 在忙 AI 的事）；
/// 9. 执行（同步的拼图写包在 externalEdit 里，成套 / 换封面 await 它的结局）；
/// 10. 改判之后 refreshFromBatch、拼图写之后 flushSaves，记 aiLog（op_id 缓存在 LiveServer）；
/// 11. 提示发到受影响的那一页（拼图页 / 批量页的状态栏，后者经 externalNotice），reveal 时切 tab（不激活 app）；同一句话
///     在标题栏副标题上留 10 s（registerWrites 的包装取结果里的 live.notice 交给 LiveIndicator）；
/// 12–13. 等预览重渲完（最多 1.5 s），编码离开主线程；JSON 编码和写出在连接自己的队列上；标题栏回到「已连接」。
extension LiveHandlers {
    typealias Request = LiveServer.Request
    typealias Reply = LiveServer.Reply

    static func registerWrites(_ live: LiveServer, model: AppModel) {
        let methods: [(String, @MainActor (Request, LiveServer, AppModel) async -> Reply)] = [
            ("session.open", openSession), ("cull.set_verdicts", setVerdicts), ("cull.show", showPhotos),
            ("collage.apply_template", applyTemplate), ("collage.run_kit", runKit), ("collage.next_cover", nextCover),
            ("collage.set_text", setText), ("collage.set_style", setStyle), ("undo", undo),
            ("collage.save_variant", saveVariant), ("collage.open_variant", openVariant),
            ("collage.export", exportCollage), ("collage.set_layout", setLayout), ("collage.auto_layout", autoLayout),
            ("cull.import_client_picks", importClientPicks),
            // 相册整本（相册 A + B · M，LiveAlbumHandlers.swift）
            ("collage.pages", pagesOp), ("collage.move_photos", movePhotos), ("collage.replace_photo", replacePhotoOp),
            ("collage.print_spec", printSpecOp), ("collage.cover", coverOp),
        ]
        for (name, run) in methods {
            live.register(name, kind: .write) { [weak live, weak model] req in
                guard let live, let model else { return quitting }
                let reply = await run(req, live, model)
                // 第 11、13 步的标题栏：做成了就留那句提示 10 s，没做成（user_busy、作废、出错）直接回「已连接」。
                // 写是一个接一个的（FIFO），所以这里收的就是 settle 里点亮的那一个
                var notice: String?
                if case .result(let r) = reply { notice = (r["live"] as? [String: Any])?["notice"] as? String }
                model.indicator.finished(notice: notice)
                return reply
            }
        }
        // 场次换了（侧栏、存储卡导完自动打开、AI 的 app_open_session）：AI 之前的写都撤不了了（§9.5.1）。
        // 不 receive(on:)：赋值的那一刻就记上，紧接着来的 app_undo 不会撞上「换了还没记」。
        live.retain(model.batch.$photoDir.dropFirst().sink { [weak model] _ in
            MainActor.assumeIsolated { model?.aiLog.sessionEpoch += 1 }
        })
    }

    /// 参数（和 `--mcp` 同一份 MCPArgs，这里是权威的那一遍）：桥上多出来的 busy_wait_ms 不算工具参数。
    static func checkArgs(_ tool: String, _ req: Request) -> Reply? {
        var args = req.params
        args["busy_wait_ms"] = nil
        guard let p = MCPArgs.check(tool, args) else { return nil }
        return invalid(p.message, hint: p.hint)
    }

    // MARK: 第 5、6、6a 步

    /// 第 5 步要核对的（6a 再做一遍）。
    struct Gate {
        let scope: LiveInteraction.Scope
        /// 写的必须是 app 当前那一场（params.session）。app_open_session、app_undo 自己核对。
        var session = true
        /// app 正在分析时不行（改判、切场次、撤判决）。
        var analysis = false
        /// 带了 if_digest 就核对拼图的编辑指纹。
        var digest = false
    }

    static func notExecuted(_ hint: String) -> [String: Any] {
        ["executed": false, "hint": hint]
    }

    /// 第 5 步；`waited` = 等过用户以后的那一遍（6a），场次变了另外说明。
    static func precheck(_ req: Request, _ gate: Gate, live: LiveServer, model: AppModel, waited: Bool) -> Reply? {
        // 菜单关了 → bridge_off；锁丢了、开桥 / 重新 bind 失败 → app_unreachable 带真正的原因（不是用户关的）
        if let down = LiveServer.bridgeDownReply(live.bridgeState) { return down }
        let batch = model.batch
        if gate.session {
            let key = currentKey(batch)
            if key == nil || req.params["session"] as? String != key {
                guard waited else { return sessionNotOpen(live, model) }
                var data: [String: Any] = ["open_session": live.openSessionObject(model) ?? NSNull()]
                data["reason"] = "session_switched_while_waiting"
                data["executed"] = false
                return .failure("session_not_open", "等用户停手的时候，用户在 app 里切了场次：这次操作没有执行", data)
            }
        }
        if gate.analysis && batch.isRunning {
            return .failure("analysis_running", "app 正在分析，这时不能改判、切场次、撤销判决：这次操作没有执行",
                            notExecuted("等分析完（app_status 的 live.analysis.running 变成 false）再调"))
        }
        if gate.digest, let want = req.params["if_digest"] as? String {
            let now = model.collage.editDigest
            if want != now {
                var data = notExecuted("先 collage_get_state 看现在的样子，再带新的 digest 调")
                data["digest"] = now
                return .failure("stale_digest", "拼图在你上次 collage_get_state 之后被改过（if_digest 对不上）：这次操作没有执行", data)
            }
        }
        return nil
    }

    static func remainingMs(_ req: Request) -> Double {
        Double(req.deadlineMs) - (LiveWire.nowMs() - req.received)
    }

    static func userBusy(_ reasons: [LiveInteraction.Reason], waited: Int) -> Reply {
        let transient = reasons.allSatisfy(\.transient)
        let lead = reasons.first { !$0.transient } ?? reasons.first
        var data: [String: Any] = ["reasons": reasons.map(\.rawValue), "transient": transient, "waited_ms": waited]
        data["executed"] = false
        data["hint"] = lead?.hint ?? "过几秒再调"
        let names = reasons.map(\.rawValue).joined(separator: "、")
        let message = transient ? "用户正在 app 里拖动 / 打字 / 开着菜单（\(names)），等了 \(waited) ms 还没停：AI 的这次操作没有执行"
                                : "用户在 app 里开着对话框 / 连拍挑选 / 审片 / 裁切这类东西（\(names)）：AI 的这次操作没有执行"
        return .failure("user_busy", message, data)
    }

    /// 第 6 步：只等一时的原因（默认 2 s，请求的 busy_wait_ms 可以调，上限 5 s，再受剩余 deadline 限制）。
    /// 等的时候是 Task.sleep：主线程空着，用户的拖动不受影响。
    static func waitUntilIdle(_ req: Request, _ scope: LiveInteraction.Scope, model: AppModel) async -> Reply? {
        var reasons = model.interaction.reasons(model, scope: scope)
        if reasons.isEmpty { return nil }
        if reasons.contains(where: { !$0.transient }) { return userBusy(reasons, waited: 0) }
        let asked = min(max(LiveWire.int(req.params["busy_wait_ms"]) ?? 2_000, 0), 5_000)
        let room = max(0, remainingMs(req) - 300)
        let limit = min(Double(asked), room)
        let start = LiveWire.nowMs()
        while true {
            let waited = LiveWire.nowMs() - start
            if waited >= limit { return userBusy(reasons, waited: Int(waited)) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            reasons = model.interaction.reasons(model, scope: scope)
            if reasons.isEmpty { return nil }
            if reasons.contains(where: { !$0.transient }) {
                return userBusy(reasons, waited: Int(LiveWire.nowMs() - start))
            }
        }
    }

    /// 第 6、6a 步：等用户不忙，再把 deadline、clientGone（§10.2：等的时候 `--mcp` 取消了 / 走了就不做）和第 5 步原样再查。
    /// 都过了就是第 8 步：标题栏 → 「AI 正在操作：套模板…」（等用户停手的时候还是「已连接」：AI 还没动手）。
    static func settle(_ req: Request, _ gate: Gate, live: LiveServer, model: AppModel) async -> Reply? {
        if let stop = await waitUntilIdle(req, gate.scope, model: model) { return stop }
        if let stop = live.expired(req) { return stop }
        if let stop = live.clientGone(req) { return stop }
        if let stop = precheck(req, gate, live: live, model: model, waited: true) { return stop }
        model.indicator.began(workingLabel(req.method))
        return nil
    }

    /// 标题栏「AI 正在操作：…」里的那个短词（§9.6a 的例子是「套模板」）。不用工具的 title：「在 app 里一键成套」
    /// 「撤销 AI 刚做的一步」放在 app 自己的标题栏上又是「AI」又是「在 app 里」，读着别扭。
    static func workingLabel(_ method: String) -> String {
        let labels: [String: String] = [
            "session.open": "切场次", "cull.set_verdicts": "改判", "cull.show": "定位照片",
            "collage.apply_template": "套模板", "collage.run_kit": "一键成套", "collage.next_cover": "换封面",
            "collage.set_text": "改字", "collage.set_style": "换样式", "undo": "撤销",
            "collage.save_variant": "存方案", "collage.open_variant": "切方案", "collage.export": "导出",
            "collage.set_layout": "设计版式", "collage.auto_layout": "排版",
            "cull.import_client_picks": "导入客户选择",
            "collage.pages": "改跨页", "collage.move_photos": "挪照片", "collage.replace_photo": "换照片",
            "collage.print_spec": "改印厂规格", "collage.cover": "改封面",
        ]
        return labels[method] ?? method
    }

    /// 第 5–6a 步。回 nil = 可以执行。
    static func begin(_ req: Request, _ gate: Gate, live: LiveServer, model: AppModel) async -> Reply? {
        if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
        return await settle(req, gate, live: live, model: model)
    }

    // MARK: 第 10–13 步的共用部分

    /// 每个写结果都带的 live 对象（§9.3），窗口看不见时另加一条 warning（§9.5.6）。
    /// `persisted`：这一步的改动存上盘没有（审查 S01b，batchPersistReport / collagePersistReport）；没存上时那句话不说「已存盘」。
    /// `applied`：这一步真的改了东西没有。没改（dry_run、要标的都已经标过）就不加这条 warning —— 它说「改动已生效…请告诉用户
    /// 切过去看」，可那边什么都没变；live 里的 window_visible / window_state 照给。
    static func liveInfo(_ req: Request, live: LiveServer, model: AppModel, notice: String?,
                         persisted: Bool = true, applied: Bool = true) -> ([String: Any], [[String: Any]]) {
        let (windows, ws) = live.windowState()
        var info: [String: Any] = ["op_id": req.opID ?? NSNull(), "replayed": false, "app_pid": Int(getpid())]
        info["tab"] = LiveServer.tabName(model.tab)
        info["window_visible"] = ws == "visible"
        info["window_state"] = ws
        info["notice"] = notice ?? NSNull()
        guard ws != "visible", applied else { return (info, []) }
        let why: [String: String] = ["hidden": "app 被隐藏了（⌘H）", "minimized": "窗口最小化了",
                                     "occluded": "窗口被挡住了或者在别的桌面上", "no_window": "app 开着但没有窗口"]
        let message = windowNotVisibleText(why[ws] ?? ws, persisted: persisted)
        let hint = windows == 0 ? "用户点程序坞图标重新打开窗口就能看到" : "请告诉用户切到选片工具看"
        return (info, [MCPReadModel.warning("window_not_visible", message, hint: hint)])
    }

    static func undoInfo(_ target: LiveAILog.Target, added: Int, model: AppModel) -> [String: Any] {
        var u: [String: Any] = ["target": target.rawValue, "steps_added": added]
        u["depth"] = target == .collage ? model.collage.undoDepth : model.batch.overrideUndoDepth
        u["how"] = target == .collage ? "在拼图页按 ⌘Z，或调 app_undo target=collage" : "在批量页按 ⌘Z，或调 app_undo target=verdicts"
        return u
    }

    /// 批量页的提示（BatchView 的状态栏显示）：10 s 后自己清掉（还是这一句的话）。
    static func batchNotice(_ batch: BatchStore, _ text: String) {
        batch.externalNotice = text
        Task { @MainActor [weak batch] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if batch?.externalNotice == text { batch?.externalNotice = nil }
        }
    }

    /// 第 12 步：等 app 把预览重渲完（最多 1.5 s），取 CGImage，编码离开主线程（和 collage.state 同一个编码器）。
    /// 返回的 settled = 1.5 s 内重渲完了；false 时手里的可能还是改之前那张（调用方加 warning）。
    static func collagePreview(_ collage: CollageStore) async -> (fields: [String: Any], settled: Bool) {
        let settled = await collage.previewSettled(timeout: 1.5)
        guard let image = collage.preview?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return ([:], settled) }
        let box = LiveBox(image)
        let done = await Task.detached(priority: .userInitiated) { () -> LiveBox<[String: Any]> in
            var e: [String: Any] = [:]
            if let enc = LiveImages.encode(box.value, maxEdge: 768) {
                e["preview_jpeg_b64"] = enc.data.base64EncodedString()
                e["preview_width"] = enc.width
                e["preview_height"] = enc.height
                e["preview_bytes"] = enc.data.count
            }
            return LiveBox(e)
        }.value
        return (done.value, settled)
    }

    /// 拼图写的回复：工程摘要、两个指纹、undo、live、预览。coverPreview：相册有封面、又没在编辑封面时，预览换成整张封面
    /// （collage_cover 用；编辑封面时画布上本来就是封面）。
    static func collageReply(_ req: Request, live: LiveServer, model: AppModel, body: [String: Any], digestBefore: String,
                             undo: [String: Any], notice: String?, warnings: [[String: Any]],
                             coverPreview: Bool = false) async -> Reply {
        let collage = model.collage
        var out = body
        out["session"] = currentKey(model.batch) ?? NSNull()
        out["digest_before"] = digestBefore
        out["digest_after"] = collage.editDigest
        out["pages"] = collage.project.pages.count
        out["page"] = collage.project.pages.isEmpty ? 0 : collage.pageIndex + 1
        out["undo"] = undo
        // 存上盘没有（审查 S01b）：改了的那几条路在这之前都 flushSaves 过，这里读的是那次写的结果
        let saved = collagePersistReport(collage)
        out["persisted"] = saved.persisted
        let (info, notVisible) = liveInfo(req, live: live, model: model, notice: notice, persisted: saved.persisted)
        out["live"] = info
        var all = warnings + saved.warnings + notVisible
        let wholeCover = coverPreview && !collage.editingCover && collage.coverLayout != nil
        var preview: [String: Any]
        var settled = true
        if wholeCover {
            preview = await coverPreviewFields(collage)
        } else {
            (preview, settled) = await collagePreview(collage)
        }
        out.merge(preview) { _, new in new }
        if preview.isEmpty {
            let message = collage.project.pages.isEmpty ? "拼图里还没有任何一页，没有预览。" : "app 的预览 1.5 秒内没渲出来。"
            all.append(MCPReadModel.warning("no_preview", message, hint: "过一秒再调 collage_get_state 看"))
        } else if !settled {
            all.append(MCPReadModel.warning("preview_stale", "app 的预览 1.5 秒内没重渲完：这张可能还是改之前的样子。",
                                            hint: "过一秒再调 collage_get_state 看现在的画面"))
        }
        out["warnings"] = all
        return .result(out)
    }

    /// 成套 / 换封面落地那一刻的撤销计数、深度和场次（KitLanding）；同步的写落地就是现在，不用传。
    struct LandedCounts {
        let pushes: Int
        let depth: Int
        let epoch: Int
    }

    /// 拼图写落地以后（第 10、11 步），再交给 collageReply。
    static func collageDone(_ req: Request, live: LiveServer, model: AppModel, tool: String, changed: Bool, pushesBefore: Int,
                            digestBefore: String, summary: String, body: [String: Any],
                            warnings: [[String: Any]] = [], landed: LandedCounts? = nil,
                            coverPreview: Bool = false) async -> Reply {
        let collage = model.collage
        let after = landed?.pushes ?? collage.undoPushes
        var notice: String?
        if changed {
            collage.flushSaves()
            let depth = landed?.depth ?? collage.undoDepth
            model.aiLog.recordWrite(.collage, op: req.opID ?? "", tool: tool, before: pushesBefore, after: after,
                                    depth: depth, epoch: landed?.epoch)
            let text = "AI：" + summary + " · 在拼图页 ⌘Z 撤销"
            collage.setNotice(text)
            notice = text
        } else {
            model.aiLog.recordNoop(.collage, before: pushesBefore, after: after)
        }
        if req.params["reveal"] as? Bool == true { model.tab = .collage }
        var b = body
        b["changed"] = changed
        let undo = undoInfo(.collage, added: changed ? 1 : 0, model: model)
        return await collageReply(req, live: live, model: model, body: b, digestBefore: digestBefore, undo: undo,
                                  notice: notice, warnings: warnings, coverPreview: coverPreview)
    }

    // MARK: session.open（app_open_session，§10.4）

    /// 在「最近场次」里找目标：先只按 key 和字符串比（不碰文件系统）；都对不上，再对不在受保护位置的那几场逐段解析
    /// 符号链接比（MCPPaths.session 自己也不进受保护位置）。这一遍要 lstat，卡住的网络位置每一段都可能等满 1 s，
    /// 所以放到主线程以外：所有路径同时开始走、共用一个 2 s 的截止时间；回到主线程按 key 再找一次（等的时候列表可能变了）。
    static func findRecent(_ arg: MCPPaths.SessionArg, in batch: BatchStore, live: LiveServer) async -> BatchStore.SessionEntry? {
        let entries = batch.recentSessions
        if let hit = entries.first(where: { MCPPaths.session(arg, matches: $0.key, folder: $0.path, resolve: { _ in nil }) }) {
            return hit
        }
        guard case .path(let p, _) = arg, !isProtectedFolder(p, live: live) else { return nil }
        let candidates: [(key: String, path: String)] = entries.filter { !isProtectedFolder($0.path, live: live) }
            .map { (key: $0.key, path: $0.path) }
        guard !candidates.isEmpty else { return nil }
        let hit = await Task.detached(priority: .userInitiated) { () -> String? in
            let deadline = DispatchTime.now() + 2
            var jobs: [String: WalkJob] = [:]
            for path in [p] + candidates.map(\.path) where jobs[path] == nil { jobs[path] = WalkJob.shared(path) }
            let resolve: (String) -> String? = { path in
                (jobs[path] ?? WalkJob.shared(path)).wait(until: deadline).flatMap(MCPPaths.comparisonPath)
            }
            return candidates.first { MCPPaths.session(arg, matches: $0.key, folder: $0.path, resolve: resolve) }?.key
        }.value
        guard let hit else { return nil }
        return batch.recentSessions.first { $0.key == hit }
    }

    static func openSession(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("app_open_session", req) { return bad }
        guard let raw = req.params["session"] as? String, let arg = MCPPaths.parseSession(raw) else {
            return invalid("session 要填 16 位 session key，或者照片文件夹的绝对路径。", hint: "先 cull_list_sessions")
        }
        let batch = model.batch
        let entry = await findRecent(arg, in: batch, live: live)
        func alreadyOpen() -> Reply {
            var out: [String: Any] = ["opened": false, "already_open": true]
            out["session"] = currentKey(batch) ?? NSNull()
            out["folder"] = batch.photoDir?.path ?? NSNull()
            out["photo_count"] = batch.items.count
            out["live"] = liveInfo(req, live: live, model: model, notice: nil).0
            return .result(out)
        }
        if let key = currentKey(batch) {
            let folder = batch.photoDir?.path ?? ""
            if entry?.key == key || MCPPaths.session(arg, matches: key, folder: folder, resolve: { _ in nil }) { return alreadyOpen() }
        }
        guard let entry else {
            return .failure("session_not_found", "选片工具的「最近场次」里没有这一场",
                            ["hint": "v1 只能打开 app「最近场次」里的场次（cull_list_sessions 列出来的）；别的请用户自己在 app 里打开"])
        }
        // 只按字符串判断，不碰文件系统（§10.4 第 2 条；v1 不留 bookmark 例外）。测试宿主另认它的假受保护前缀
        if isProtectedFolder(entry.path, live: live) {
            return .failure("protected_location",
                            "「\(entry.path)」在系统隐私保护的位置（桌面 / 文稿 / 下载 / iCloud 云盘 / 外置盘或网络卷）。让 app 为 AI 去读它可能弹出系统授权框，AI 不会替你点。",
                            ["hint": "请用户自己在 app 侧栏「最近场次」里点开它", "folder": entry.path])
        }
        // 登记的路径不受保护，可这一场的照片已经挪进了受保护位置：GUI 跟着书签打开过、「重新定位」过（或者挪了以后重新分析过），
        // manifest 记的拍摄文件夹和照片路径都改到了那里，app 打开以后读的就是那里的原图。按 manifest 的 photo_dir 再判一次
        // （只读数据目录里的 JSON，不碰照片文件夹）。
        if let recorded = recordedPhotoDir(dataDir: batch.dataDir, key: entry.key), isProtectedFolder(recorded, live: live) {
            return .failure("protected_location",
                            "「\(entry.path)」这一场的照片已经挪到「\(recorded)」，在系统隐私保护的位置（桌面 / 文稿 / 下载 / iCloud 云盘 / 外置盘或网络卷）。让 app 为 AI 去读它可能弹出系统授权框，AI 不会替你点。",
                            ["hint": "请用户自己在 app 侧栏「最近场次」里点开它", "folder": recorded])
        }
        if let stop = await begin(req, Gate(scope: .session, session: false, analysis: true), live: live, model: model) {
            return stop
        }
        // 等的时候用户自己切到了这一场
        if currentKey(batch) == entry.key { return alreadyOpen() }
        let verdictSteps = batch.overrideUndoDepth
        let collageSteps = model.collage.undoDepth
        // 拼图的重做栈切场次也会清掉（用户 ⌘Z 到底、还想 ⇧⌘Z 回去的时候撤销栈是空的）：一样要先问
        let collageRedo = model.collage.canRedo
        let history: Bool = verdictSteps > 0 || collageSteps > 0 || collageRedo
        // 这一场有原件读不出来、只在内存里的改动（审查 S02 跟进）：切过去就没了，一样先问用户。
        let inMemory: [String] = batch.refusedUnsavedLabels
        if (history || !inMemory.isEmpty) && req.params["confirm"] as? Bool != true {
            var data: [String: Any] = ["verdict_undo_steps": verdictSteps, "collage_undo_steps": collageSteps]
            data["collage_can_redo"] = collageRedo
            data["executed"] = false
            data["hint"] = "切场次会清掉用户在 app 里这一场的撤销记录：先问用户，同意了再带 confirm:true 调"
            var message = "切场次会清掉 app 里这一场的撤销记录（判决 \(verdictSteps) 步、拼图 \(collageSteps) 步）：这次没有切"
            if !inMemory.isEmpty {
                let what = inMemory.joined(separator: "、")
                data["unsaved_in_memory"] = inMemory
                data["hint"] = "照原话告诉用户：这一场的\(what)原件读不出来，这次打开以后的改动没存盘，切过去就没了；" +
                               "用户同意丢掉这些改动再带 confirm:true 调，不同意就请用户先修好或移走那个文件（批量页顶上红条里有位置）"
                let undoNote: String = history ? "另外会清掉撤销记录（判决 \(verdictSteps) 步、拼图 \(collageSteps) 步）" : ""
                message = "这一场的\(what)原件读不出来、这次打开以后的改动只在内存里，切场次就没了；" + undoNote + "：这次没有切"
            }
            return .failure("confirm_required", message, data)
        }
        // = 侧栏「最近场次」里点它（BatchView 的菜单就是这一句），只是不跟 bookmark：文件夹被挪进桌面 / 外置盘以后，
        // bookmark 会把 app 带过去读，绕过上面只按字符串的检查；不跟的话挪走了就是「照片文件夹已不存在」（app_says）。
        // 拼图工程跟着挂过去：AppModel 的订阅是下一拍才跑，这里同步挂一次，回复里的撤销栈和之后的 app_undo 看到的就是新场次的
        // 没切成：这一场还有判决、客户选中、对时没存上（盘满了，审查 S01）—— 切过去内存里的就没了，app 先拦下。
        // 带了 confirm:true（AI 已经问过用户）：只在内存里的改动不再在 app 里弹框问一遍（实时桥的请求不能挂在模态框上）。
        let askLeaving = batch.confirmDiscardRefused
        batch.confirmDiscardRefused = { _, _ in true }
        let switched = batch.switchSession(to: URL(fileURLWithPath: entry.path), followBookmark: false)
        batch.confirmDiscardRefused = askLeaving
        guard switched else {
            if let unsaved = batch.persistError {
                return .failure("save_failed", "app 里这一场还有改动没存上（\(unsaved)），这次没有切场次",
                                ["executed": false, "hint": "照原话告诉用户：先腾出磁盘空间、点批量页顶上红条的「重试」，存上以后再切"])
            }
            // 拼图工程写不上（盘满）：批量页红条不管它，switchSession 离开前再整份写了一次还是失败、拦下了（persistBeforeLeaving）。
            // 原件读坏了那一种上面带 confirm 已经放行，到不了这里。
            let collage = model.collage
            if !batch.isRunning, let why = collage.projectSaveProblem, !collage.projectSaveIsRefused {
                return .failure("save_failed", "app 里这一场的拼图没存上（\(why)），这次没有切场次：切过去拼图改动就没了",
                                ["executed": false,
                                 "hint": "照原话告诉用户：先腾出磁盘空间（看拼图页底下的提示），之后再调一次 app_open_session —— app 切之前会先整份再存一次，存上了才切"])
            }
            return .failure("invalid_state", "选片工具没切场次：\(batch.lastError ?? "正在处理中")", ["executed": false])
        }
        model.ensureCollageAttached()
        live.refreshSnapshot()
        model.aiLog.opened.append(entry.path)
        if req.params["reveal"] as? Bool == true { model.tab = .batch }
        var out: [String: Any] = ["opened": true, "session": currentKey(batch) ?? NSNull(), "folder": entry.path]
        out["photo_count"] = batch.items.count
        out["verdict_undo_cleared"] = verdictSteps
        out["collage_undo_cleared"] = collageSteps
        out["tab"] = LiveServer.tabName(model.tab)
        out["undo"] = ["target": NSNull(), "steps_added": 0, "how": "切场次不进撤销；要回去再调 app_open_session"] as [String: Any]
        let (info, shown) = liveInfo(req, live: live, model: model, notice: nil)
        out["live"] = info
        var warnings = shown
        if let e = batch.lastError {
            warnings.append(MCPReadModel.warning("app_says", "选片工具说：\(e)", hint: "照原话告诉用户"))
        }
        out["warnings"] = warnings
        return .result(out)
    }

    // MARK: cull.set_verdicts（改判）

    static let verdictNames: [String: Verdict] = ["pick": .pick, "usable": .usable, "reject": .reject]

    static func setVerdicts(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("cull_set_verdicts", req) { return bad }
        if let stop = await begin(req, Gate(scope: .verdicts, analysis: true), live: live, model: model) { return stop }
        let batch = model.batch
        // 两种写法：ids + verdict（都改成同一个）、changes（每张各自的，比如一场里一张 pick、其余 reject）。都是一次调用一步撤销
        let wanted: [(id: String, target: Verdict?)]
        let mixed = req.params["changes"] != nil
        if mixed, case .success(let list) = MCPArgs.verdictChanges(req.params["changes"]) {
            wanted = list.map { (id: $0.id, target: verdictNames[$0.verdict]) }
        } else {
            let target: Verdict? = verdictNames[req.params["verdict"] as? String ?? ""]
            wanted = MCPArgs.uniqueStrings(req.params["ids"]).map { (id: $0, target: target) }
        }
        var changed: [String] = []
        var unchanged: [String] = []
        var missing: [String] = []
        var writes: [(id: String, verdict: Verdict?)] = []
        for (id, target) in wanted {
            guard batch.item(withID: id) != nil else {
                missing.append(id)
                continue
            }
            // 已经是这个判决（人工改的，不是「接受推荐」钉的；auto = 没有 override）的不动
            let same = target == nil ? batch.overrides[id] == nil : (batch.isManual(id) && batch.overrides[id] == target)
            if same {
                unchanged.append(id)
            } else {
                changed.append(id)
                writes.append((id: id, verdict: target))
            }
        }
        guard !changed.isEmpty || !unchanged.isEmpty else {
            return .failure("photo_not_found", "这些 id 在 app 当前这一场里都没有：\(missing.joined(separator: ", "))",
                            ["hint": "id 是文件名去掉扩展名；先 cull_list_photos 看有哪些", "executed": false])
        }
        let pushesBefore = batch.overrideUndoPushes
        var notice: String?
        if !changed.isEmpty {
            // = 网格里按 1/2/3/0（一次只压一步撤销），只是另记出处（ai_overrides.json：照样算人工改判，阈值建议不拿它当样本）；
            // 拼图托盘里的判决跟着刷（§9.5.2）。不调 keepPlace：用户的焦点不跟着跳
            batch.applyAIOverrides(writes, opID: req.opID ?? "", tool: "cull_set_verdicts")
            model.collage.refreshFromBatch()
            model.aiLog.recordWrite(.verdicts, op: req.opID ?? "", tool: "cull_set_verdicts", before: pushesBefore,
                                    after: batch.overrideUndoPushes, depth: batch.overrideUndoDepth)
            let text = "AI：" + verdictSummary(writes.map(\.verdict)) + " · 在批量页 ⌘Z 撤销"
            batchNotice(batch, text)
            notice = text
        }
        if req.params["reveal"] as? Bool == true { model.tab = .batch }
        let counts = batch.verdictCounts
        var out: [String: Any] = ["changed": changed, "unchanged": unchanged, "missing_ids": missing]
        if mixed {
            // changes 的写法：changed 里的每张改成了什么（判决名 → id）
            var to: [String: [String]] = [:]
            for w in writes { to[w.verdict.map(MCPReadModel.verdictName) ?? "auto", default: []].append(w.id) }
            out["changed_to"] = to
        }
        out["session"] = currentKey(batch) ?? NSNull()
        out["verdict_counts"] = ["pick": counts.pick, "usable": counts.usable, "reject": counts.reject]
        out["collage_tray_refreshed"] = !changed.isEmpty
        out["undo"] = undoInfo(.verdicts, added: changed.isEmpty ? 0 : 1, model: model)
        // 存上盘没有（审查 S01b）：applyAIOverrides 当场写 overrides.json，盘满时红条和这里一起说
        let saved = batchPersistReport(batch, [.overrides])
        out["persisted"] = saved.persisted
        let (info, warnings) = liveInfo(req, live: live, model: model, notice: notice, persisted: saved.persisted)
        out["live"] = info
        out["warnings"] = saved.warnings + warnings
        return .result(out)
    }

    /// 改判的提示：都改成同一个 =「把 N 张改成精选」（和以前一样）；各不相同 =「改判 N 张（精选 1 · 废片 7）」。
    nonisolated static func verdictSummary(_ targets: [Verdict?]) -> String {
        let first = targets.first ?? nil
        if targets.allSatisfy({ $0 == first }) {
            return "把 \(targets.count) 张" + (first.map { "改成\($0.rawValue)" } ?? "恢复自动判决")
        }
        let order: [Verdict?] = [.pick, .usable, .reject, nil]
        let parts = order.compactMap { v -> String? in
            let n = targets.filter { $0 == v }.count
            return n == 0 ? nil : "\(v?.rawValue ?? "恢复自动") \(n)"
        }
        return "改判 \(targets.count) 张（" + parts.joined(separator: " · ") + "）"
    }

    // MARK: cull.import_client_picks（导入客户选择）

    /// 导入客户选择存上没有：客户选中和客户备注是同一次导入、同一步撤销写的（BatchStore.setClientReply），两份一起算 ——
    /// 以前只看 client_picks.json，备注写不上（client_notes.json 盘满、原件读坏了先不写）也回 persisted:true、说「已存盘」。
    static let clientReplyFiles: [BatchStore.PersistFile] = [.clientPicks, .clientNotes]

    /// app_undo target=verdicts 撤的这一步动过哪几份：撤 AI 导入的客户选择看客户选中 + 客户备注，改判看 overrides.json。
    static func undoPersistFiles(tool: String) -> [BatchStore.PersistFile] {
        tool == "cull_import_client_picks" ? clientReplyFiles : [.overrides]
    }

    /// = 批量页「客户 › 导入客户选择…」：text 走 resolveClientReply（和导入框边打字边预览同一个函数），ids 要全在这一场。
    /// dry_run（默认）只回认出了哪些，不等用户停手、不压撤销；dry_run:false 走 importClientPicks（导入框「标记为客户选中」：
    /// 加到原来的上面，文件名后面的修图要求一起存成客户备注，一步判决撤销，app_undo target=verdicts 能撤）。
    /// 照片都已经是客户选中、只是这次补了备注也算改了（导入框一样会存）。客户选中不改判决，但拼图托盘里的照片带着 clientPick
    /// （紫心；相册编排按它无条件保留客户选中）：标完跟着刷，用户一直停在拼图页、没切 tab 时也对（applyClientImport）。
    static func importClientPicks(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("cull_import_client_picks", req) { return bad }
        let dryRun = req.params["dry_run"] as? Bool ?? true
        if dryRun {
            if let stop = precheck(req, Gate(scope: .verdicts), live: live, model: model, waited: false) { return stop }
        } else if let stop = await begin(req, Gate(scope: .verdicts, analysis: true), live: live, model: model) {
            return stop
        }
        let batch = model.batch
        var resolution = ClientReply.Resolution()
        if let text = req.params["text"] as? String {
            resolution = batch.resolveClientReply(text)
        } else {
            let ids = MCPArgs.uniqueStrings(req.params["ids"])
            let missing = ids.filter { batch.item(withID: $0) == nil }
            guard missing.isEmpty else {
                var data = notExecuted("ids 要全是这一场的照片 id（文件名去掉扩展名）；先 cull_list_photos 看有哪些，或者把客户的原话放进 text")
                data["missing_ids"] = missing
                return .failure("photo_not_found", "这些 id 在 app 当前这一场里没有：\(missing.prefix(20).joined(separator: ", "))：一张都没标", data)
            }
            resolution.ids = ids
        }
        var out = clientPicksBody(resolution, existing: batch.clientPicks, existingNotes: batch.clientNotes)
        out["session"] = currentKey(batch) ?? NSNull()
        out["dry_run"] = dryRun
        var notice: String?
        out["collage_tray_refreshed"] = false
        if !dryRun {
            let pushesBefore = batch.overrideUndoPushes
            let delta = applyClientImport(resolution, batch: batch, collage: model.collage)
            out["collage_tray_refreshed"] = delta.changed
            if delta.changed {
                model.aiLog.recordWrite(.verdicts, op: req.opID ?? "", tool: "cull_import_client_picks", before: pushesBefore,
                                        after: batch.overrideUndoPushes, depth: batch.overrideUndoDepth)
                let text = clientImportNotice(delta)
                batchNotice(batch, text)
                notice = text
            }
        }
        let changed = notice != nil
        out["changed"] = changed
        out["client_pick_count"] = batch.clientPickCount
        if dryRun {
            out["undo"] = ["target": NSNull(), "steps_added": 0, "how": "dry_run 只看认出了哪些，什么都没改；dry_run:false 才标上"] as [String: Any]
        } else {
            out["undo"] = undoInfo(.verdicts, added: changed ? 1 : 0, model: model)
        }
        if !dryRun && req.params["reveal"] as? Bool == true { model.tab = .batch }
        // 存上盘没有（审查 S01b）：dry_run 什么都没写，不报
        let saved = dryRun ? PersistReport(persisted: true, warnings: []) : batchPersistReport(batch, clientReplyFiles)
        if !dryRun { out["persisted"] = saved.persisted }
        // dry_run、什么都没变：窗口看不见那句「改动已生效并已存盘…请告诉用户切过去看」不说（结果照 summary 在对话里讲）
        let (info, shown) = liveInfo(req, live: live, model: model, notice: notice, persisted: saved.persisted,
                                     applied: changed)
        out["live"] = info
        var warnings = saved.warnings + shown
        if resolution.ids.isEmpty {
            warnings.append(MCPReadModel.warning("nothing_recognized", "一张照片都没认出来：什么都没标。",
                                                 hint: "看 unknown 和 summary；文件名、文件号、确认表编号都认不出时请用户自己在 app 里看"))
        }
        out["warnings"] = warnings
        return .result(out)
    }

    /// 这次导入会改什么：新增的客户选中、备注会变的照片（都按认出的顺序）。两样都空 = 导了也什么都不变（不压撤销、changed false）。
    struct ClientImportDelta {
        var fresh: [String] = []
        var renoted: [String] = []
        var changed: Bool { !fresh.isEmpty || !renoted.isEmpty }
    }

    /// 和 BatchStore.importClientPicks 同一条合并规则：同一张原来有备注的换成这次的，这次没写（或写的是空）的留着原来的。纯函数。
    static func clientImportDelta(_ r: ClientReply.Resolution, picks: Set<String>,
                                  notes: [String: String]) -> ClientImportDelta {
        var d = ClientImportDelta()
        d.fresh = r.ids.filter { !picks.contains($0) }
        d.renoted = r.ids.filter { id in
            guard let note = r.notes[id], !note.isEmpty else { return false }
            return notes[id] != note
        }
        return d
    }

    /// dry_run:false 那一步 = 导入框的「标记为客户选中」（客户选中和备注一起，一步撤销）。什么都不变时不调
    /// （不压撤销，状态栏也不写「新增 0 张」）。改了就刷拼图托盘（和 cull_set_verdicts、app_undo 一样）：托盘里那几张的
    /// clientPick 只在 refreshFromBatch 时跟上，不刷的话停在拼图页点「自动编排」会把客户选中的废片、连拍第二张拿掉。
    static func applyClientImport(_ r: ClientReply.Resolution, batch: BatchStore,
                                  collage: CollageStore?) -> ClientImportDelta {
        let delta = clientImportDelta(r, picks: batch.clientPicks, notes: batch.clientNotes)
        guard delta.changed else { return delta }
        batch.importClientPicks(r.ids, notes: r.notes)
        collage?.refreshFromBatch()
        return delta
    }

    /// 批量页状态栏那一句：「AI：标了 2 张客户选中 · 备注 2 张 · 在批量页 ⌘Z 撤销」；只改了备注 =「AI：更新了 1 张的客户备注 · …」。
    static func clientImportNotice(_ d: ClientImportDelta) -> String {
        let undo = " · 在批量页 ⌘Z 撤销"
        guard !d.fresh.isEmpty else { return "AI：更新了 \(d.renoted.count) 张的客户备注" + undo }
        let noted: String = d.renoted.isEmpty ? "" : " · 备注 \(d.renoted.count) 张"
        return "AI：标了 \(d.fresh.count) 张客户选中" + noted + undo
    }

    /// 导入客户选择的结果主体（dry_run 和正式标一样）：认出的、没认出的原文、按哪张确认表对的、导入框里那几行预览、
    /// 客户写的备注。`existingNotes` = 现在存着的客户备注（new_notes 按它比）。纯函数。
    static func clientPicksBody(_ r: ClientReply.Resolution, existing: Set<String>,
                                existingNotes: [String: String] = [:]) -> [String: Any] {
        let delta = clientImportDelta(r, picks: existing, notes: existingNotes)
        let fresh = delta.fresh
        var out: [String: Any] = ["ids": r.ids, "unknown": r.unknown, "new_ids": fresh]
        // 文件名后面的修图要求（照片 id → 客户原话）：dry_run:false 时存成客户备注，复制原片时写成「精修要求.csv」；
        // new_notes = 其中和现在存着的不一样、这次会写进去的
        out["notes"] = r.notes
        out["new_notes"] = delta.renoted
        out["already_picked"] = r.ids.count - fresh.count
        out["existing_count"] = existing.count
        out["summary"] = ClientReply.summary(r, existing: existing)
        out["sheet"] = r.sheet.map { ["id": $0.id, "title": $0.title] as [String: Any] } ?? NSNull()
        out["used_sheet"] = r.usedSheet
        out["header"] = r.header ?? NSNull()
        out["numbers_without_sheet"] = r.numbersWithoutSheet
        if let columns = r.tableColumns { out["table_columns"] = columns }
        return out
    }

    // MARK: cull.show（在 app 里定位照片）

    static func showPhotos(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("cull_show_photos", req) { return bad }
        if let stop = await begin(req, Gate(scope: .show), live: live, model: model) { return stop }
        let batch = model.batch
        var found: [String] = []
        var missing: [String] = []
        for id in MCPArgs.uniqueStrings(req.params["ids"]) {
            if batch.item(withID: id) != nil { found.append(id) } else { missing.append(id) }
        }
        guard let key = currentKey(batch), !found.isEmpty else {
            return .failure("photo_not_found", "这些 id 在 app 当前这一场里都没有：\(missing.joined(separator: ", "))",
                            ["hint": "id 是文件名去掉扩展名；先 cull_list_photos 看有哪些", "executed": false])
        }
        let select = req.params["mode"] as? String != "focus"
        let request = BatchStore.ViewRequest(token: UUID(), session: key, ids: found, select: select)
        batch.viewApplied = nil
        batch.viewRequest = request
        // 这个工具默认把 app 切到批量页（它就是为了给用户看）；切 tab 不激活 app
        if req.params["reveal"] as? Bool ?? true { model.tab = .batch }
        // 最多等 300 ms 看批量页有没有消费掉；用户停在别的页、窗口最小化时 SwiftUI 不一定马上跑 onChange，
        // 那就回 pending:true，用户下次切到批量页时照样选中（§9.3 第二轮补）
        let until = LiveWire.nowMs() + 300
        while batch.viewApplied?.token != request.token && LiveWire.nowMs() < until {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        var out: [String: Any] = ["session": key, "missing_ids": missing, "mode": select ? "select" : "focus"]
        if let done = batch.viewApplied, done.token == request.token {
            out["applied"] = true
            out["pending"] = false
            out["selected"] = done.selected
            out["focus"] = done.focus ?? NSNull()
            out["hidden_by_filter"] = done.hidden
        } else {
            out["applied"] = false
            out["pending"] = true
            out["focus"] = found[0]
            out["hidden_by_filter"] = NSNull()
        }
        out["undo"] = ["target": NSNull(), "steps_added": 0, "how": "只改选中和焦点，不进撤销"] as [String: Any]
        let (info, warnings) = liveInfo(req, live: live, model: model, notice: nil)
        out["live"] = info
        out["warnings"] = warnings
        return .result(out)
    }

    // MARK: collage.apply_template（套模板）

    static func applyTemplate(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_apply_template", req) { return bad }
        let name = req.params["template"] as? String ?? ""
        func unknown() -> Reply {
            invalid("没有叫「\(name)」的模板（全名、内置分类名、名字里的几个字都没找到）。", hint: "取值见 collage_list_templates")
        }
        guard model.collage.template(named: name) != nil else { return unknown() }
        if let stop = await begin(req, Gate(scope: .collage, digest: true), live: live, model: model) { return stop }
        model.ensureCollageAttached()
        let collage = model.collage
        if let stop = coverEditingRefusal(collage, "套模板") { return stop }
        guard let template = collage.template(named: name) else { return unknown() }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        // = 左栏「模板」里点模板（applyTemplate 自己会 setNotice，桥的提示接在它后面）
        let changed = collage.externalEdit { collage.applyTemplate(template) }
        let summary = collage.notice ?? "套了模板「\(template.name)」"
        var body: [String: Any] = ["template": template.name]
        body["category"] = template.builtin ? template.category : "我的模板"
        return await collageDone(req, live: live, model: model, tool: "collage_apply_template", changed: changed,
                                 pushesBefore: pushes, digestBefore: before, summary: summary, body: body)
    }

    // MARK: collage.run_kit / collage.next_cover（一键成套、换封面）

    static func runKit(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_run_kit", req) { return bad }
        guard let kit = (req.params["kit"] as? String).flatMap(CollageKitID.init(rawValue:)) else {
            return invalid("kit 只能是 " + MCPToolDefs.kitIDs.joined(separator: " / "))
        }
        let budget: CollageBudgetChange
        switch CollageBudgetChange.parse(kit: kit, spreads: LiveWire.int(req.params["spreads"]),
                                         min: LiveWire.int(req.params["min_per_spread"]),
                                         max: LiveWire.int(req.params["max_per_spread"])) {
        case .success(let change): budget = change
        case .failure(let bad): return invalid(bad.message)
        }
        return await kitWrite(req, live: live, model: model, kit: kit, coverStep: 0, tool: "collage_run_kit",
                              albumBudget: budget)
    }

    static func nextCover(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_next_cover", req) { return bad }
        let steps = LiveWire.int(req.params["steps"]) ?? 1
        return await kitWrite(req, live: live, model: model, kit: .fashionIssue, coverStep: max(1, steps), tool: "collage_next_cover")
    }

    static func notAnIssue() -> Reply {
        .failure("invalid_state", "当前拼图不是「出一期」的结果，没有封面可换",
                 ["hint": "先 collage_run_kit kit=fashionIssue", "executed": false])
    }

    /// 成套和换封面（§9.5.1「异步操作」）：不包 asOneUndoStep，发起前复位合并状态、等结局、落地后再复位一次。
    /// 发起之前先等路人信息算完（最多「剩余 deadline − 5 s」和 20 s 里小的那个；§10.6「STEP 1 不做了」第 2 条）。
    static func kitWrite(_ req: Request, live: LiveServer, model: AppModel, kit: CollageKitID, coverStep: Int,
                         tool: String, albumBudget: CollageBudgetChange = .keep) async -> Reply {
        let collage = model.collage
        let gate = Gate(scope: .collage, digest: true)
        // 先第 5 步（桥关了、场次不对、if_digest 过期），再看是不是出一期：不然真正的原因被 invalid_state 盖住
        if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
        if coverStep > 0 && CollageStyleFashion.coverPhotoID(collage.project) == nil { return notAnIssue() }
        // 一直的忙（对话框、裁切、导出……）立刻回，不先等路人信息
        let now = model.interaction.reasons(model, scope: .collage)
        if now.contains(where: { !$0.transient }) { return userBusy(now, waited: 0) }
        // 第 8 步提前到等路人信息之前（最多 20 s，画布不动）：标题栏说「AI 正在操作：一键成套…」，不是干巴巴的「已连接」。
        // 之后 settle 再点一次不变；没做成时 registerWrites 的包装照样回「已连接」
        model.indicator.began(workingLabel(req.method))
        let budget = min(remainingMs(req) - 5_000, 20_000) / 1_000
        let settled = await collage.hintsSettled(timeout: max(0, budget))
        if let stop = await settle(req, gate, live: live, model: model) { return stop }
        model.ensureCollageAttached()
        if coverStep > 0 && CollageStyleFashion.coverPhotoID(collage.project) == nil { return notAnIssue() }
        let before = collage.editDigest
        let coverBefore = CollageStyleFashion.coverPhotoID(collage.project)
        // = 「一键成套 ▾」/「换封面」：applyKit 自己按 sessionToken、solveGeneration 丢掉作废的结果
        let epoch = model.aiLog.sessionEpoch
        let landing = await collage.externalKit(kit, coverStep: coverStep, budget: albumBudget)
        let outcome = landing.outcome
        switch outcome {
        case .superseded(let by):
            // 第二轮补：作废了就直接回，不记 aiLog（不然之后的 app_undo 会去撤一步不存在的 AI 操作），也不发提示
            let user = by == .userEdit
            var data = notExecuted(user ? "用户在拼图里做了新的操作：先 collage_get_state 看现在的样子，再决定要不要重来"
                                        : "用户切了场次：先 app_status 看 open_session")
            data["reason"] = user ? "user_edit" : "session_switched"
            let message = user ? "成套还在算的时候用户在拼图里做了新的操作，这一次作废了：没有落地，没有压撤销"
                               : "成套还在算的时候用户切了场次，这一次作废了：没有落地，没有压撤销"
            return .failure("superseded", message, data)
        case .notGenerated:
            return .failure("nothing_to_render", "「\(kit.name)」没出来：托盘（和这一场）里没有能用的照片，工程没动",
                            ["hint": "先改判出几张精选，或者请用户把照片带进拼图托盘", "executed": false])
        case .landed, .unchanged:
            let landed = outcome == .landed
            var body: [String: Any] = ["kit": kit.rawValue, "kit_name": kit.name, "landing": landed ? "landed" : "unchanged"]
            body["cover_id"] = CollageStyleFashion.coverPhotoID(collage.project) ?? NSNull()
            if coverStep > 0 {
                body["cover_before"] = coverBefore ?? NSNull()
                body["steps"] = coverStep
            }
            body["hints_settled"] = settled
            var warnings: [[String: Any]] = []
            // 整本婚礼相册：几个跨页、目标几个、多了几个（F06；多了给一条 over_target）
            if kit == .weddingAlbum {
                let album = CollageBudgetChange.report(collage.project)
                body["album"] = album.body
                if let w = album.warning { warnings.append(w) }
            }
            if !settled {
                warnings.append(MCPReadModel.warning("hints_pending", "路人信息还没算完：这次成套的封面和裁切可能和算完以后不一样。",
                                                     hint: "想要稳定的结果，过一会儿再调一次"))
            }
            // 落地时 applyKit 压了恰好一步（算的时候用户做的不作废的小改动在它下面）。计数、深度、提示都取落地那一刻的
            // （KitLanding）：落地之后、这里接着跑之前用户按的那一下不算进 AI 这一步，之后 app_undo 就是 undo_not_ours /
            // already_undone_by_user，不会撤到用户的那一步；那一下是切场次的话，这一步记在原来那一场上
            let pushes = landed ? landing.undoPushes - 1 : landing.undoPushes
            let summary = landing.notice ?? "「\(kit.name)」"
            let at = LandedCounts(pushes: landing.undoPushes, depth: landing.undoDepth, epoch: epoch)
            return await collageDone(req, live: live, model: model, tool: tool, changed: landed, pushesBefore: pushes,
                                     digestBefore: before, summary: summary, body: body, warnings: warnings, landed: at)
        }
    }

    // MARK: collage.set_text（改标题 / 刊头 / 期号 / 格子里的字）

    static func setText(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_set_text", req) { return bad }
        if let stop = await begin(req, Gate(scope: .collage, digest: true), live: live, model: model) { return stop }
        model.ensureCollageAttached()
        let collage = model.collage
        var cell: (path: [Int], index: Int, text: String)?
        if let obj = req.params["cell_text"] as? [String: Any], let p = obj["path"] as? String,
           let index = LiveWire.int(obj["index"]), let text = obj["text"] as? String {
            if let stop = coverEditingRefusal(collage, "改格子里的字（cell_text）") { return stop }
            let path = p.compactMap(\.wholeNumberValue)
            guard collage.root?.node(at: path)?.cell?.overlays.indices.contains(index) == true else {
                return invalid("格子「\(p)」上没有第 \(index) 个字块（下标从 0 开始）。",
                               hint: "先 collage_get_state 看 cells[].path 和每格的 overlays")
            }
            cell = (path, index, text)
        }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        var parts: [String] = []
        let fields: [(String, String)] = [("title", "标题"), ("subtitle", "副标题"), ("masthead", "刊头"), ("issue", "期号")]
        for (key, label) in fields where req.params[key] is String { parts.append(label) }
        if let cell { parts.append("格子「\(cell.path.map(String.init).joined())」的字") }
        // 不管改几个字段都是一步撤销（§9.5.1）；setter 自己有相等判断，没变的不压步
        let changed = collage.externalEdit {
            if let t = req.params["title"] as? String { collage.setTitle(t) }
            if let t = req.params["subtitle"] as? String { collage.setSubtitle(t) }
            if let t = req.params["masthead"] as? String { collage.setMasthead(t) }
            if let t = req.params["issue"] as? String { collage.setIssue(t) }
            if let cell { collage.setOverlayFirstLine(cell.text, at: cell.path, index: cell.index) }
        }
        let summary = "改了" + parts.joined(separator: "、")
        return await collageDone(req, live: live, model: model, tool: "collage_set_text", changed: changed,
                                 pushesBefore: pushes, digestBefore: before, summary: summary, body: [:])
    }

    // MARK: collage.save_variant / collage.open_variant（方案栏）

    /// 方案栏（collage_get_state 的 variants、两个方案工具的结果里都有）：current = 和现在一模一样（托盘不算）。
    static func variantsList(_ collage: CollageStore) -> [[String: Any]] {
        let current = collage.currentVariantID
        let iso = ISO8601DateFormatter()
        return collage.variants.map { v in
            var d: [String: Any] = ["id": v.id, "name": v.name, "mode": v.project.mode.rawValue]
            d["pages"] = v.project.pages.count
            d["current"] = v.id == current
            d["saved_at"] = iso.string(from: v.savedAt)
            return d
        }
    }

    static func variantInfo(_ v: CollageVariant) -> [String: Any] {
        ["id": v.id, "name": v.name, "mode": v.project.mode.rawValue, "pages": v.project.pages.count,
         "saved_at": ISO8601DateFormatter().string(from: v.savedAt)]
    }

    static func saveVariant(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_save_variant", req) { return bad }
        if let stop = await begin(req, Gate(scope: .collage, digest: true), live: live, model: model) { return stop }
        model.ensureCollageAttached()
        let collage = model.collage
        // 存不了的先挡下（store 里那几句提示是给点按钮的用户看的，不让 AI 的调用在状态栏上留话）
        guard !collage.project.pages.isEmpty else {
            return .failure("invalid_state", "拼图里还没有任何一页，没什么可存。",
                            ["hint": "先 collage_apply_template 或 collage_run_kit 排一版"])
        }
        guard collage.currentVariantID != nil || collage.variants.count < CollageStore.maxVariants else {
            return .failure("invalid_state", "这一场的方案已经满了（\(CollageStore.maxVariants) 个）。",
                            ["hint": "请用户在拼图页的方案栏里右键删掉几个不要的"])
        }
        // 挪照片 / 加照片落下以后还在后台精排（isRefining，一般不到 0.1 秒）：存下来的会是精排之前的快版。
        guard !collage.isSolving, !collage.isRefining else {
            return .failure("invalid_state", "app 还在排版（还没排完），现在存下来的会是排完之前的样子。",
                            ["hint": "过一两秒再调"])
        }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        var body: [String: Any] = [:]
        var notice: String?
        // 方案栏不进撤销（见 CollageStore 方案那一段）：不走 externalEdit（它会压一步、这一步撤了什么都不变），
        // 直接存；changed = 方案栏多了一个
        if let id = collage.currentVariantID, let same = collage.variants.first(where: { $0.id == id }) {
            // 和已有的一模一样：不再存、不动 app（返回那一个）
            body["variant"] = variantInfo(same)
            body["same_as_existing"] = true
            body["changed"] = false
        } else {
            guard case .saved(let v) = collage.saveVariant(name: req.params["name"] as? String) else {
                return .failure("invalid_state", "这一次没存成方案。", ["hint": "先 collage_get_state 看看现在的样子"])
            }
            collage.flushSaves()
            let text = "AI：存成方案「\(v.name)」 · 方案栏里点它切回来"
            collage.setNotice(text)
            notice = text
            body["variant"] = variantInfo(v)
            body["changed"] = true
        }
        model.aiLog.recordNoop(.collage, before: pushes, after: collage.undoPushes)
        if req.params["reveal"] as? Bool == true { model.tab = .collage }
        body["variants"] = variantsList(collage)
        let undo = undoInfo(.collage, added: 0, model: model)
        return await collageReply(req, live: live, model: model, body: body, digestBefore: before, undo: undo,
                                  notice: notice, warnings: [])
    }

    static func openVariant(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_open_variant", req) { return bad }
        if let stop = await begin(req, Gate(scope: .collage, digest: true), live: live, model: model) { return stop }
        model.ensureCollageAttached()
        let collage = model.collage
        let id = req.params["variant"] as? String ?? ""
        guard let variant = collage.variants.first(where: { $0.id == id }) else {
            return invalid("没有这个方案：「\(id)」。", hint: "先 collage_get_state 看 variants[].id")
        }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        var restored = 0
        let changed = collage.externalEdit { restored = collage.openVariant(id) ?? 0 }
        var summary = "切到方案「\(variant.name)」"
        if restored > 0 { summary += "，补回 \(restored) 张照片进托盘" }
        var body: [String: Any] = ["variant": variantInfo(variant), "restored_photos": restored]
        body["variants"] = variantsList(collage)
        return await collageDone(req, live: live, model: model, tool: "collage_open_variant", changed: changed,
                                 pushesBefore: pushes, digestBefore: before, summary: summary, body: body)
    }

    // MARK: collage.export（导出成图片，= 拼图页「导出」）

    /// 输出目录在拍摄文件夹里面、下次分析会扫到（审查 S11）：和导出按钮同一个判断（CollageStore.exportFolderRefusal，
    /// startExport 里也拦），这里先回一个说得清的 invalid_state —— 不然只剩 export_failed「一个文件都没写出来」。
    static func exportFolderRefused(_ collage: CollageStore) -> Reply? {
        guard let folder = collage.outputFolder, let why = collage.exportFolderRefusal(folder) else { return nil }
        let hint = "请用户在拼图页顶栏「导出 ▾」里点「用默认」（拍摄文件夹里的「\(ImageLoader.collageExportSubfolder)/」，分析时跳过），"
            + "或选拍摄文件夹外面的目录"
        return .failure("invalid_state", why, ["hint": hint, "executed": false, "folder": folder.path])
    }

    /// 和导出按钮同一条路（CollageStore.startExport）：同一个输出目录、同样的重名规则；倍数、格式、文件名只管这一次。
    /// 不改拼图、不进撤销、不弹访达；等 app 写完再回。
    static func exportCollage(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_export", req) { return bad }
        let collage = model.collage
        let gate = Gate(scope: .collage, digest: true)
        // 顺序同成套（kitWrite）：先第 5 步，再看一直的忙（对话框、导出……），再等路人信息，最后 settle —— 等的时候
        // 用户点了导出，settle 会回 user_busy（不是 startExport 的「正在导出」）
        if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
        let now = model.interaction.reasons(model, scope: .collage)
        if now.contains(where: { !$0.transient }) { return userBusy(now, waited: 0) }
        model.indicator.began(workingLabel(req.method))
        model.ensureCollageAttached()
        let variantID = req.params["variant"] as? String
        if let id = variantID {
            guard let v = collage.variants.first(where: { $0.id == id }) else {
                return invalid("没有这个方案：「\(id)」。", hint: "先 collage_get_state 看 variants[].id")
            }
            // 它用到、托盘里已经拿掉的照片：补算路人信息（不然那几格没有按人脸的取景）
            let have = Set(collage.project.photos.map(\.id))
            collage.prepareHints(for: v.project.photos.filter { !have.contains($0.id) })
        }
        let budget = min(remainingMs(req) - 5_000, 20_000) / 1_000
        let settled = await collage.hintsSettled(timeout: max(0, budget))
        if let stop = await settle(req, gate, live: live, model: model) { return stop }
        // 等的时候用户可能删了、覆盖了这个方案，或者改了版：落地前再取一次
        var project = collage.project
        var body: [String: Any] = [:]
        if let id = variantID {
            guard let v = collage.variants.first(where: { $0.id == id }) else {
                return invalid("方案「\(id)」刚被删掉了。", hint: "先 collage_get_state 看 variants[].id")
            }
            project = collage.variantProject(v)
            body["variant"] = variantInfo(v)
        }
        guard !project.pages.isEmpty else {
            return .failure("invalid_state", "拼图里还没有任何一页，没什么可导出。",
                            ["hint": "先 collage_apply_template 或 collage_run_kit 排一版", "executed": false])
        }
        guard !collage.isSolving, !collage.isRefining else {
            return .failure("invalid_state", "app 还在排版（还没排完），现在导出的会是排完之前的样子。",
                            ["hint": "过一两秒再调", "executed": false])
        }
        // 批量页这一场开在存储卡上（审查 S07）：默认的「拼图导出/」在卡上不给，选的目录也不能在卡上 —— 不往卡上写。
        if model.batch.isCardSession, collage.outputFolder == nil || collage.cardOutputRefusal != nil {
            let why = collage.cardOutputRefusal ?? "照片在存储卡上：默认的输出目录（卡上的「拼图导出」）不能用，「导出 ▾」里也没选别的目录"
            return .failure("invalid_state", why + "。",
                            ["hint": "请用户先导入这张卡（文件夹菜单「从存储卡导入…」），或者在拼图页顶栏「导出 ▾」里选一个不在卡上的目录",
                             "executed": false])
        }
        guard collage.outputFolder != nil else {
            return .failure("invalid_state", "没有输出目录：app 还没打开照片文件夹，「导出 ▾」里也没选目录。",
                            ["hint": "请用户在拼图页顶栏「导出 ▾」里选一个输出目录", "executed": false])
        }
        if let refused = exportFolderRefused(collage) { return refused }
        let folderReminder = collage.outputFolder.flatMap(collage.exportFolderReminder)
        let name = req.params["name"] as? String ?? ""
        // 看版 PDF（相册 A + B · M，= 「导出 ▾ › 印刷 › 出看版 PDF」）：给客户看的低清合订本，不导跨页图
        if req.params["proof"] as? Bool == true {
            guard project.mode == .album else {
                return .failure("invalid_state", "看版 PDF 只对相册（现在是单张拼图）。", ["hint": "去掉 proof 照常导出图片", "executed": false])
            }
            return await exportProof(req, live: live, model: model, project: project, name: name, body: body,
                                     settled: settled, folderReminder: folderReminder)
        }
        // 只导几个跨页（同「导出 ▾」的范围；文件名里的序号还是原来的跨页号，部分导出不出印刷 PDF、不出封面）
        var only: [Int]?
        if let text = req.params["pages"] as? String {
            switch CollageExportRange.parse(text, count: project.pages.count) {
            case .success(let list): only = list
            case .failure(let bad):
                return invalid("pages 写错了：\(bad.message)。", hint: "跨页号从 1 起，写成「3」「1-3, 7」；一共 \(project.pages.count) 个")
            }
            body["pages"] = (only ?? []).map { $0 + 1 }
        }
        var options = collage.exportOptions
        let askedScale = LiveWire.int(req.params["scale"])
        if let k = askedScale { options.scale = k }
        if let f = (req.params["format"] as? String).flatMap(CollageExport.Format.init(rawValue:)) { options.format = f }
        // 空照片格（和导出按钮的确认框同一个判断）：照样导出，warnings 里报
        let emptySlots = CollageStore.emptyPhotoSlots(project: project).filter { only?.contains($0.page) ?? true }
        let started = Date()
        // 导出前检查（同 collage_preflight、「导出 ▾」的清单）：离开主线程过一遍，照样导出，结果放进 preflight
        let box = LiveBox((project, collage.hints))
        let issues = await Task.detached(priority: .userInitiated) { () -> LiveBox<[CollagePreflightIssue]> in
            let (p, h) = box.value
            return LiveBox(CollagePreflight.run(project: p, hints: h, texts: true))
        }.value.value
        let checked = only.map { picked in issues.filter { $0.page.map(picked.contains) ?? false } } ?? issues
        body["preflight"] = preflightBody(checked, project: project, pages: only, limit: 10)
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<CollageStore.ExportOutcome, Never>) in
            collage.startExport(project: project, options: options, name: name, reveal: false, pages: only) {
                cont.resume(returning: $0)
            }
        }
        if outcome.files.isEmpty {
            let why = outcome.cancelled ? "用户取消了导出" : (outcome.failure ?? "一个文件都没写出来")
            return .failure("export_failed", "导出没成功：\(why)。",
                            ["hint": "看 app 拼图页底下的提示；输出目录写不进去的话请用户换一个", "executed": false])
        }
        var files: [[String: Any]] = []
        if let folder = outcome.folder {
            for file in outcome.files {
                let url = folder.appendingPathComponent(file)
                var f: [String: Any] = ["name": file, "path": url.path]
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int { f["bytes"] = size }
                // 只读文件头（不解码）；PDF 不给尺寸（ImageIO 会报 72 dpi 的点数，不是像素）
                if url.pathExtension.lowercased() != "pdf", let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    f["width"] = props[kCGImagePropertyPixelWidth] ?? NSNull()
                    f["height"] = props[kCGImagePropertyPixelHeight] ?? NSNull()
                }
                files.append(f)
            }
        }
        body["folder"] = outcome.folder?.path ?? NSNull()
        body["files"] = files
        body["scale"] = outcome.scale
        body["format"] = options.format.rawValue
        body["seconds"] = MCPReadModel.r3(Date().timeIntervalSince(started))
        body["hints_settled"] = settled
        var warnings: [[String: Any]] = []
        if let k = askedScale, k > outcome.scale {
            warnings.append(MCPReadModel.warning("scale_capped", "这张画布最多放大到 \(outcome.scale) 倍（整张不超过 5000 万像素；印刷画布不放大）。",
                                                 hint: ""))
        }
        if !settled {
            warnings.append(MCPReadModel.warning("hints_pending", "路人信息还没算完：这次导出的裁切可能和算完以后不一样。",
                                                 hint: "想要稳定的结果，过一会儿再导一次"))
        }
        if let w = CollageStore.emptySlotWarning(emptySlots, project: project) {
            var item = MCPReadModel.warning("empty_slots", w,
                                            hint: "collage_get_state 的 cells 里 kind 是 photo、photo_id 是 null 的就是：用 collage_set_layout 放上照片或者去掉这一格；确实要一块底色就不用管")
            item["pages"] = Set(emptySlots.map { $0.page + 1 }).sorted()
            item["count"] = emptySlots.count
            warnings.append(item)
        }
        // 空照片格以外的「拦」（放大超过 150%、页数不合规、同一张用了两次、胶装脸压中缝）：导出按钮会先问，AI 这边照样导出、说一声
        let blocks = checked.filter { $0.severity == .block && $0.kind != .emptySlot }
        if let first = blocks.first {
            var item = MCPReadModel.warning("preflight_blocks",
                                            "导出前检查还有 \(blocks.count) 条「拦」（第一条：\(first.message)）：导出按钮会先问，这次照样导出了。",
                                            hint: "看结果里的 preflight.blocks（collage_preflight 能单独查全部），改完再导")
            item["count"] = blocks.count
            item["kinds"] = Array(Set(blocks.map { snakeCase($0.kind.rawValue) })).sorted()
            warnings.append(item)
        }
        if let w = outcome.warning {
            warnings.append(MCPReadModel.warning("export_degraded", w, hint: "多半是原图挪走了、移动硬盘没插：请用户看一下"))
        }
        if let note = folderReminder {
            warnings.append(MCPReadModel.warning("export_folder_in_session", note,
                                                 hint: "请用户确认是不是真要导到那一场的拍摄文件夹里；不是的话在拼图页顶栏「导出 ▾」里换个目录"))
        }
        if outcome.cancelled {
            warnings.append(MCPReadModel.warning("export_cancelled", "用户中途取消了导出：只写出了前面几个文件。", hint: ""))
        } else if let failure = outcome.failure {
            warnings.append(MCPReadModel.warning("export_partial", "没导完：\(failure)。前面写出的文件留着。", hint: ""))
        }
        let where_ = outcome.folder?.lastPathComponent ?? ""
        let notice = "AI：导出了 \(files.count) 个文件 → \(where_)"
        collage.setNotice(notice)
        if req.params["reveal"] as? Bool == true { model.tab = .collage }
        let (info, notVisible) = liveInfo(req, live: live, model: model, notice: notice)
        body["live"] = info
        body["warnings"] = warnings + notVisible
        return .result(body)
    }

    // MARK: collage.set_style（换样式 / 色调）

    static func setStyle(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_set_style", req) { return bad }
        if let stop = await begin(req, Gate(scope: .collage, digest: true), live: live, model: model) { return stop }
        model.ensureCollageAttached()
        let collage = model.collage
        let preset = req.params["style"] as? String
        let look = (req.params["look"] as? String).flatMap(CollageLook.init(rawValue:))
        let strength = req.params["look_strength"].flatMap(MCPArgs.number)
        var fields = CollageStore.StyleFields()
        fields.margin = req.params["margin"].flatMap(MCPArgs.number)
        fields.gutter = req.params["gutter"].flatMap(MCPArgs.number)
        fields.corner = req.params["corner"].flatMap(MCPArgs.number)
        fields.background = req.params["background"].flatMap { try? CollageLayoutSpec.color($0, path: "background") }
        fields.shape = (req.params["shape"] as? String).flatMap { CollageLayoutSpec.shapes[$0] }
        fields.filmGrain = req.params["film_grain"].flatMap(MCPArgs.number)
        fields.filmHalation = req.params["film_halation"].flatMap(MCPArgs.number)
        fields.filmExposure = req.params["film_exposure"].flatMap(MCPArgs.number)
        fields.filmWarmth = req.params["film_warmth"].flatMap(MCPArgs.number)
        fields.filmFormat = (req.params["film_format"] as? String).flatMap(CollageFilmFormat.init(rawValue:))
        var parts: [String] = []
        if let preset { parts.append("样式「\(CollageStyles.all.first { $0.key == preset }?.name ?? preset)」") }
        if let look { parts.append("色调「\(look.label)」") }
        if let strength { parts.append(String(format: "色调强度 %.2f", strength)) }
        if fields.margin != nil { parts.append("外边距") }
        if fields.gutter != nil { parts.append("缝宽") }
        if fields.corner != nil { parts.append("圆角") }
        if fields.background != nil { parts.append("底色") }
        if fields.shape != nil { parts.append("格子形状") }
        if fields.filmGrain != nil { parts.append("颗粒") }
        if fields.filmHalation != nil { parts.append("晕光") }
        if fields.filmExposure != nil { parts.append("胶片曝光") }
        if fields.filmWarmth != nil { parts.append("冷暖") }
        if fields.filmFormat != nil { parts.append("画幅") }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        // = 检视器「样式」点预设（不合并），色调、强度在同一步里再改（和界面一样，也会改「下次新建拼图沿用的默认样式」）
        let changed = collage.externalEdit { collage.setStyleParts(preset: preset, look: look, strength: strength, fields: fields) }
        let summary = "换了" + parts.joined(separator: "、")
        var body: [String: Any] = ["look": collage.project.style.look.rawValue]
        body["style"] = styleKey(collage.project.style) ?? NSNull()
        body["look_strength"] = MCPReadModel.r3(collage.project.style.lookStrength)
        body["film_grain"] = MCPReadModel.r3(collage.project.style.filmGrain)
        body["film_halation"] = MCPReadModel.r3(collage.project.style.filmHalation)
        body["film_exposure"] = MCPReadModel.r3(collage.project.style.filmExposure)
        body["film_warmth"] = MCPReadModel.r3(collage.project.style.filmWarmth)
        body["film_format"] = collage.project.style.filmFormat.rawValue
        body["style_fields"] = styleFields(collage.project.style)
        return await collageDone(req, live: live, model: model, tool: "collage_set_style", changed: changed,
                                 pushesBefore: pushes, digestBefore: before, summary: summary, body: body)
    }

    // MARK: collage.set_layout / collage.auto_layout（AI 设计版式、引擎排一版）

    /// 照片 id 认不认得：托盘里的、这一页已经在用的、这一场批量页里的。
    static func photoKnown(_ id: String, model: AppModel) -> Bool {
        let collage = model.collage
        return collage.photoMap[id] != nil || collage.page?.photoIDs.contains(id) == true || model.batch.item(withID: id) != nil
    }

    /// 这几张里托盘没有、这一页也没有的（批量页里的）：离开主线程读尺寸建 ref。读不了的（文件挪走了）放进 unreadable。
    static func newPhotoRefs(_ ids: [String], model: AppModel) async -> (refs: [CollagePhotoRef], unreadable: [String]) {
        let collage = model.collage
        let onPage = Set(collage.page?.photoIDs ?? [])
        let wanted = ids.filter { collage.photoMap[$0] == nil && !onPage.contains($0) }
        guard !wanted.isEmpty else { return ([], []) }
        let items = wanted.compactMap { model.batch.item(withID: $0) }
        let facts = CollageBridge.Facts(batch: model.batch)
        let refs = await Task.detached(priority: .userInitiated) {
            items.compactMap { CollageBridge.ref(from: $0, facts: facts) }
        }.value
        let got = Set(refs.map(\.id))
        return (refs, wanted.filter { !got.contains($0) })
    }

    /// 相册里已经排在别的跨页上的照片不能再用（同一张不能出现在两个跨页上）。
    static func usedElsewhere(_ ids: [String], collage: CollageStore) -> Reply? {
        let used = collage.usedOnOtherSpreads(ids)
        guard let first = used.first else { return nil }
        return invalid("「\(first)」已经排在相册别的跨页上了（一共 \(used.count) 张）：同一张不能出现在两个跨页上。", hint: "换别的照片")
    }

    /// 这一页最多能有几格：语法的上限；这一页本来就更多的，原样发回来不能挡。
    static func cellLimit(_ collage: CollageStore) -> Int {
        max(CollageLayoutSpec.maxLeaves, collage.page?.root.leaves.count ?? 0)
    }

    /// 等的时候用户翻了页（相册翻到别的跨页）：版式是给原来那一页的，落到别的页上会把那一页盖掉。
    static func pageMoved() -> Reply {
        var data = notExecuted("用户翻到了别的页：先 collage_get_state 看现在是哪一页，再决定要不要重来")
        data["reason"] = "user_edit"
        return .failure("superseded", "等 app 的时候用户翻到了别的页，这一次作废了：没有落地，没有压撤销", data)
    }

    /// 两个工具落地以后的回复：版式的语法、每格的位置、提醒。hintsNote：路人信息没等到时说什么（nil = 不用说）。
    static func layoutDone(_ req: Request, live: LiveServer, model: AppModel, tool: String, changed: Bool, pushes: Int, before: String,
                           summary: String, trayAdded: Int, settled: Bool, hintsNote: String, duplicates: [String]) async -> Reply {
        let collage = model.collage
        var body: [String: Any] = ["tray_added": trayAdded, "hints_settled": settled, "canvas": canvasInfo(collage.project.canvas)]
        if let page = collage.page {
            body["layout"] = CollageLayoutSpec.describe(page.root, canvas: collage.project.canvas, style: collage.project.style)
            body["cells"] = cells(page, project: collage.project)
        }
        var warnings: [[String: Any]] = []
        if let first = duplicates.first {
            warnings.append(MCPReadModel.warning("duplicate_photo", "「\(first)」等 \(duplicates.count) 张照片在这一页上出现了不止一次。", hint: "不是故意的话改一下再发"))
        }
        if !settled {
            warnings.append(MCPReadModel.warning("hints_pending", hintsNote, hint: "过一会儿调 collage_get_state 看预览"))
        }
        if collage.crossFoldPages().contains(collage.pageIndex) {
            warnings.append(MCPReadModel.warning("crosses_fold", "有照片压在跨页的中缝上：装订以后中间那一条会被吃掉。",
                                                 hint: "想避开就把顶层切成左右两半（row，两块等分）"))
        }
        return await collageDone(req, live: live, model: model, tool: tool, changed: changed, pushesBefore: pushes,
                                 digestBefore: before, summary: summary, body: body, warnings: warnings)
    }

    static func setLayout(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_set_layout", req) { return bad }
        let collage = model.collage
        let gate = Gate(scope: .collage, digest: true)
        // 顺序同成套（kitWrite）：先第 5 步，再看一直的忙，再等路人信息，最后 settle
        if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
        let now = model.interaction.reasons(model, scope: .collage)
        if now.contains(where: { !$0.transient }) { return userBusy(now, waited: 0) }
        model.indicator.began(workingLabel(req.method))
        model.ensureCollageAttached()
        func canvasShared() -> Reply? {
            guard req.params["canvas"] is String, collage.isAlbum || collage.project.pages.count > 1 else { return nil }
            return .failure("invalid_state", "这一套有好几页，画布是各页共用的：不能只给这一页换画布，这一次什么都没改。",
                            ["hint": "去掉 canvas 再调，或者请用户在 app 里换画布", "executed": false])
        }
        func problem(_ p: CollageLayoutSpec.Problem) -> Reply {
            invalid("版式写错了：\(p.text)", hint: "语法见 collage_list_templates（include 里写 layout_grammar）；照片 id 见 collage_get_state 的 tray_photos 或 cull_list_photos")
        }
        if let stop = canvasShared() { return stop }
        if let stop = coverEditingRefusal(collage, "设计版式") { return stop }
        let first = CollageLayoutSpec.parse(req.params["layout"], maxCells: cellLimit(collage)) { photoKnown($0, model: model) }
        guard case .success(let draft) = first else {
            if case .failure(let p) = first { return problem(p) }
            return invalid("版式写错了")
        }
        if let stop = usedElsewhere(draft.photoIDs, collage: collage) { return stop }
        let pageID = collage.page?.id
        let (refs, unreadable) = await newPhotoRefs(draft.photoIDs, model: model)
        if let bad = unreadable.first {
            return invalid("读不了这张照片：「\(bad)」（原图可能挪走了）。这一次什么都没改。", hint: "换一张，或者请用户把移动硬盘接上")
        }
        // 只等新进托盘的这几张：别的照片的路人信息和这一次的版式没关系，不用让 AI 干等
        var settled = true
        if !refs.isEmpty {
            collage.prepareHints(for: refs)
            let budget = min(remainingMs(req) - 5_000, 20_000) / 1_000
            settled = await collage.hintsSettled(timeout: max(0, budget))
        }
        if let stop = await settle(req, gate, live: live, model: model) { return stop }
        // 等的时候用户可能动过（拿掉照片、翻页、加页）：落地前再核对一遍
        guard collage.page?.id == pageID else { return pageMoved() }
        if let stop = canvasShared() { return stop }
        if let stop = coverEditingRefusal(collage, "设计版式") { return stop }
        let readable = Set(refs.map(\.id))
        let onPage = Set(collage.page?.photoIDs ?? [])
        let again = CollageLayoutSpec.parse(req.params["layout"], maxCells: cellLimit(collage)) {
            collage.photoMap[$0] != nil || onPage.contains($0) || readable.contains($0)
        }
        guard case .success(let parsed) = again else {
            if case .failure(let p) = again { return problem(p) }
            return invalid("版式写错了")
        }
        if let stop = usedElsewhere(parsed.photoIDs, collage: collage) { return stop }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        let canvas = (req.params["canvas"] as? String).map(CollageCLI.canvas)
        let fit = req.params["fit"] as? Bool ?? false
        let added = refs.filter { collage.photoMap[$0.id] == nil }.count
        let changed = collage.externalEdit {
            collage.applyDesignedLayout(parsed.root, canvas: canvas, fit: fit, newPhotos: refs)
        }
        let tail = added > 0 ? "，\(added) 张新照片进托盘" : ""
        return await layoutDone(req, live: live, model: model, tool: "collage_set_layout", changed: changed, pushes: pushes, before: before,
                                summary: "设计了一版（\(parsed.photoIDs.count) 张照片\(tail)）", trayAdded: changed ? added : 0, settled: settled,
                                hintsNote: "新进托盘的照片人脸信息还没算完：这些格子的自动取景待会儿可能还会变。", duplicates: parsed.duplicates)
    }

    static func autoLayout(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_auto_layout", req) { return bad }
        let collage = model.collage
        let gate = Gate(scope: .collage, digest: true)
        if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
        let now = model.interaction.reasons(model, scope: .collage)
        if now.contains(where: { !$0.transient }) { return userBusy(now, waited: 0) }
        model.indicator.began(workingLabel(req.method))
        model.ensureCollageAttached()
        let wanted: [String]? = req.params["photos"] != nil ? MCPArgs.uniqueStrings(req.params["photos"]) : nil
        let count = LiveWire.int(req.params["count"])
        // = 「换一批」不做的两种：fine-art 跨页按编排出版式；印样按拍摄先后排（给了照片才是把这一页换成普通版式）
        func engineRefuses() -> Reply? {
            if let stop = coverEditingRefusal(collage, "引擎排版") { return stop }
            if collage.isAlbum, collage.project.albumTheme == .fineArt {
                return .failure("invalid_state", "婚礼 fine-art 的跨页按编排出版式，引擎排不了，这一次什么都没改。",
                                ["hint": "自己设计就用 collage_set_layout", "executed": false])
            }
            if wanted == nil, count == nil, collage.isContactSheet {
                return .failure("invalid_state", "印样按拍摄先后排，没有别的版，这一次什么都没改。",
                                ["hint": "要把这一页换成普通版式就给 photos 或 count，或者用 collage_set_layout", "executed": false])
            }
            return nil
        }
        if let stop = engineRefuses() { return stop }
        let pageID = collage.page?.id
        var refs: [CollagePhotoRef] = []
        if let wanted {
            if let bad = wanted.first(where: { !photoKnown($0, model: model) }) {
                return invalid("没有这张照片「\(bad)」（要是托盘里或这一场里的）。", hint: "照片 id 见 collage_get_state 的 tray_photos 或 cull_list_photos")
            }
            if let stop = usedElsewhere(wanted, collage: collage) { return stop }
            let built = await newPhotoRefs(wanted, model: model)
            if let bad = built.unreadable.first {
                return invalid("读不了这张照片：「\(bad)」（原图可能挪走了）。这一次什么都没改。", hint: "换一张，或者请用户把移动硬盘接上")
            }
            refs = built.refs
            collage.prepareHints(for: refs)
        }
        // 引擎按人脸裁切、挑主图：和成套一样先等路人信息
        let budget = min(remainingMs(req) - 5_000, 20_000) / 1_000
        let settled = await collage.hintsSettled(timeout: max(0, budget))
        if let stop = await settle(req, gate, live: live, model: model) { return stop }
        guard collage.page?.id == pageID else { return pageMoved() }
        if let stop = engineRefuses() { return stop }
        if let wanted, let stop = usedElsewhere(wanted, collage: collage) { return stop }
        let before = collage.editDigest
        let epoch = model.aiLog.sessionEpoch
        let plan = await collage.engineLayout(photoIDs: wanted, count: count, newPhotos: refs)
        // 引擎在后台算的这一会儿：用户又在拖、在裁（等他们停手、超时、客户端走了都照第 5–6a 步），切了场次、翻了页、改了拼图
        // 就作废（同成套），不盖掉用户刚做的
        guard model.aiLog.sessionEpoch == epoch else {
            var data = notExecuted("用户切了场次：先 app_status 看 open_session")
            data["reason"] = "session_switched"
            return .failure("superseded", "引擎还在排的时候用户切了场次，这一次作废了：没有落地，没有压撤销", data)
        }
        if let stop = await settle(req, gate, live: live, model: model) { return stop }
        guard model.aiLog.sessionEpoch == epoch else {
            var data = notExecuted("用户切了场次：先 app_status 看 open_session")
            data["reason"] = "session_switched"
            return .failure("superseded", "引擎还在排的时候用户切了场次，这一次作废了：没有落地，没有压撤销", data)
        }
        guard collage.page?.id == pageID else { return pageMoved() }
        guard collage.editDigest == before else {
            var data = notExecuted("用户在拼图里做了新的操作：先 collage_get_state 看现在的样子，再决定要不要重来")
            data["reason"] = "user_edit"
            return .failure("superseded", "引擎还在排的时候用户在拼图里做了新的操作，这一次作废了：没有落地，没有压撤销", data)
        }
        guard let plan else {
            return .failure("nothing_to_render", "引擎没排出来：没有能用的照片，或者照片太多、比例差太远，工程没动",
                            ["hint": "先往托盘里带几张照片，或者给 photos 少一点、换个画布比例", "executed": false])
        }
        let pushes = collage.undoPushes
        let added = refs.filter { collage.photoMap[$0.id] == nil }.count
        let changed = collage.externalEdit {
            collage.applyDesignedLayout(plan, aspectsFixed: false, sizesAreShares: false, newPhotos: refs)
        }
        return await layoutDone(req, live: live, model: model, tool: "collage_auto_layout", changed: changed, pushes: pushes, before: before,
                                summary: "排了一版（\(plan.photoIDs.count) 张照片）", trayAdded: changed ? added : 0, settled: settled,
                                hintsNote: "路人信息还没算完：这一版的取景待会儿可能还会变。", duplicates: [])
    }

    // MARK: undo（app_undo：只撤 AI 自己刚做的一步）

    static func undoProblem(_ check: LiveAILog.UndoCheck, target: LiveAILog.Target, model: AppModel) -> Reply? {
        let how = target == .collage ? "在拼图页按 ⌘Z" : "在批量页按 ⌘Z"
        switch check {
        case .ok:
            return nil
        case .notOurs:
            return .failure("undo_not_ours", "撤销栈最上面那一步不是 AI 做的（用户之后又改过）：没有撤",
                            ["hint": "请用户自己在 app 里 ⌘Z（\(how)）", "executed": false])
        case .nothing(let reason):
            let messages: [String: String] = [
                "no_ai_step": "AI 在这一场还没做过可撤销的操作", "already_undone": "AI 刚才那一步已经撤过了",
                "already_undone_by_user": "用户自己已经撤过 AI 那一步了", "session_switched": "场次换过了，之前的撤销记录已经清掉",
            ]
            var data = notExecuted("不用再撤；要看现在的样子调 " + (target == .collage ? "collage_get_state" : "cull_list_photos"))
            data["reason"] = reason
            return .failure("nothing_to_undo", (messages[reason] ?? reason) + "：没有撤", data)
        case .userUndid:
            return undoProblem(.nothing("already_undone_by_user"), target: target, model: model)
        }
    }

    static func undoCheck(_ target: LiveAILog.Target, model: AppModel) -> LiveAILog.UndoCheck {
        let check = target == .collage
            ? model.aiLog.check(.collage, pushes: model.collage.undoPushes, depth: model.collage.undoDepth)
            : model.aiLog.check(.verdicts, pushes: model.batch.overrideUndoPushes, depth: model.batch.overrideUndoDepth)
        if case .userUndid(let i) = check { model.aiLog.markUndone(target, i) }
        return check
    }

    static func undo(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("app_undo", req) { return bad }
        let target: LiveAILog.Target = req.params["target"] as? String == "verdicts" ? .verdicts : .collage
        let batch = model.batch
        // session 可选：给了就核对（§10.2）；不给就是 app 当前那一场（没打开任何场次时下面回 nothing_to_undo）
        let gate = Gate(scope: target == .collage ? .collage : .verdicts, session: req.params["session"] is String,
                        analysis: target == .verdicts)
        if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
        // 先看一眼：撤不了的不用等用户停手
        if let stop = undoProblem(undoCheck(target, model: model), target: target, model: model) { return stop }
        if let stop = await settle(req, gate, live: live, model: model) { return stop }
        let check = undoCheck(target, model: model)
        if let stop = undoProblem(check, target: target, model: model) { return stop }
        guard case .ok(let index) = check, let entry = model.aiLog.entry(target, index) else {
            return undoProblem(.nothing("no_ai_step"), target: target, model: model) ?? quitting
        }
        model.aiLog.markUndone(target, index)
        let undone: [String: Any] = ["op_id": entry.opID, "tool": entry.tool]
        if target == .verdicts {
            // = 批量页顶栏 / 检视器的 ⌘Z；拼图托盘里的判决跟着刷
            let ids = batch.undoLastOverride()
            model.collage.refreshFromBatch()
            let text = "AI：撤销了刚才的改判（\(ids.count) 张）"
            batchNotice(batch, text)
            let counts = batch.verdictCounts
            var out: [String: Any] = ["target": "verdicts", "undone": undone, "ids": ids]
            out["session"] = currentKey(batch) ?? NSNull()
            out["verdict_counts"] = ["pick": counts.pick, "usable": counts.usable, "reject": counts.reject]
            out["undo"] = ["target": "verdicts", "steps_removed": 1, "depth": batch.overrideUndoDepth] as [String: Any]
            // 存上盘没有（审查 S01b）：撤的是 AI 导入的客户选择就看 client_picks.json + client_notes.json，改判看 overrides.json
            let saved = batchPersistReport(batch, undoPersistFiles(tool: entry.tool))
            out["persisted"] = saved.persisted
            let (info, warnings) = liveInfo(req, live: live, model: model, notice: text, persisted: saved.persisted)
            out["live"] = info
            out["warnings"] = saved.warnings + warnings
            return .result(out)
        }
        let collage = model.collage
        let before = collage.editDigest
        // = 拼图页顶栏的 ⌘Z；落盘不等 1 s 防抖（§9.5.3）
        collage.undo()
        collage.flushSaves()
        let text = "AI：撤销了刚才那一步 · 在拼图页 ⇧⌘Z 可以重做"
        collage.setNotice(text)
        let body: [String: Any] = ["target": "collage", "undone": undone]
        let undo: [String: Any] = ["target": "collage", "steps_removed": 1, "depth": collage.undoDepth, "can_redo": collage.canRedo]
        return await collageReply(req, live: live, model: model, body: body, digestBefore: before, undo: undo, notice: text,
                                  warnings: [])
    }
}

/// AI 经桥做过的写（§9.3 app_undo）：每个 target 一条记录。只撤 AI 自己最近一步、还没撤过、而且仍然在栈顶的那一步：
/// - 记下每一步之前 / 之后的 push 计数（CollageStore.undoPushes、BatchStore.overrideUndoPushes，只增不减）和之后的深度；
/// - 当前计数 ≠ AI 最后一次动它之后的计数，或者 AI 的几步之间插过别的 push → 用户之后又改过 → undo_not_ours；
/// - 计数对得上、深度比那一步之后的小 → 用户自己撤过了 → nothing_to_undo（already_undone_by_user）；
/// - 场次换过（sessionEpoch 变了；app_open_session 和用户自己切都算）→ nothing_to_undo（session_switched）。
/// 没改出东西的写不记一步（asOneUndoStep 把空步撤掉了，计数却 +1）：这之前用户没动过的话，这个空 push 算进 AI 上一步里，
/// 不然 AI 改了一下没变化，紧接着的 app_undo 会被当成「用户又改过」。
struct LiveAILog {
    enum Target: String {
        case verdicts, collage
    }

    struct Entry {
        let opID: String
        let tool: String
        let pushesBefore: Int
        var pushesAfter: Int
        let depthAfter: Int
        let epoch: Int
        var undone = false
    }

    enum UndoCheck: Equatable {
        /// 能撤：entries 里第几条。
        case ok(Int)
        case notOurs
        case nothing(String)
        /// 用户自己撤过了（这一条要标成已撤）。
        case userUndid(Int)
    }

    /// 场次换一次 +1（LiveHandlers.registerWrites 订阅 photoDir）。
    var sessionEpoch = 0
    /// 桥切过去的场次（test.state 看：受保护的那一场从没走到 switchSession）。
    var opened: [String] = []
    private(set) var entries: [Target: [Entry]] = [:]
    /// AI 最后一次动这个 target（写、或者没改出东西的写）之后的 push 计数。
    private(set) var aiPushes: [Target: Int] = [:]

    /// `epoch`：成套落地那一刻的场次（落地之后、记账之前用户切了场次，这一步算原来那一场的）；不给 = 现在的。
    mutating func recordWrite(_ t: Target, op: String, tool: String, before: Int, after: Int, depth: Int, epoch: Int? = nil) {
        var list = entries[t] ?? []
        let e = Entry(opID: op, tool: tool, pushesBefore: before, pushesAfter: after, depthAfter: depth,
                      epoch: epoch ?? sessionEpoch)
        list.append(e)
        if list.count > 64 { list.removeFirst(list.count - 64) }
        entries[t] = list
        aiPushes[t] = after
    }

    mutating func recordNoop(_ t: Target, before: Int, after: Int) {
        guard after != before, aiPushes[t] == before, var list = entries[t], let i = list.indices.last else { return }
        list[i].pushesAfter = after
        entries[t] = list
        aiPushes[t] = after
    }

    func entry(_ t: Target, _ i: Int) -> Entry? {
        guard let list = entries[t], list.indices.contains(i) else { return nil }
        return list[i]
    }

    mutating func markUndone(_ t: Target, _ i: Int) {
        guard entries[t]?.indices.contains(i) == true else { return }
        entries[t]?[i].undone = true
    }

    func check(_ t: Target, pushes: Int, depth: Int) -> UndoCheck {
        let list = entries[t] ?? []
        guard let i = list.lastIndex(where: { !$0.undone }) else {
            return .nothing(list.isEmpty ? "no_ai_step" : "already_undone")
        }
        let e = list[i]
        if e.epoch != sessionEpoch { return .nothing("session_switched") }
        // 这一步之后 AI 又做过、又自己撤掉了的那几步之间，不能插着别人的 push（不然栈顶是用户那一步）
        var expect = e.pushesAfter
        for later in list[(i + 1)...] {
            guard later.pushesBefore == expect else { return .notOurs }
            expect = later.pushesAfter
        }
        guard expect == pushes, aiPushes[t] == pushes else { return .notOurs }
        if depth < e.depthAfter { return .userUndid(i) }
        // 深度比那一步之后还多（计数没变）只可能是用户撤了又重做到更前面：保守，不撤
        guard depth == e.depthAfter else { return .nothing("already_undone_by_user") }
        return .ok(i)
    }

    /// collage_get_state 的 undo.top_is_ai：现在 app_undo 能不能撤。
    func canUndo(_ t: Target, pushes: Int, depth: Int) -> Bool {
        if case .ok = check(t, pushes: pushes, depth: depth) { return true }
        return false
    }
}
