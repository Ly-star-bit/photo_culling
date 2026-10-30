import Foundation
import AppKit
import CryptoKit

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
        undo["verdict_depth"] = batch.overrideUndoDepth
        // 最上面那一步是不是 AI 做的、现在还能不能用 app_undo 撤（和 app_undo 同一个判断）
        undo["top_is_ai"] = model.aiLog.canUndo(.collage, pushes: collage.undoPushes, depth: collage.undoDepth)
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
        guard live.bridgeState == .on else {
            return .failure("bridge_off", "用户在选片工具菜单里关了「允许 AI 实时操作」：这次操作没有执行",
                            notExecuted("请用户在选片工具菜单里打开它；MCP 不会替用户打开"))
        }
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
    static func liveInfo(_ req: Request, live: LiveServer, model: AppModel, notice: String?) -> ([String: Any], [[String: Any]]) {
        let (windows, ws) = live.windowState()
        var info: [String: Any] = ["op_id": req.opID ?? NSNull(), "replayed": false, "app_pid": Int(getpid())]
        info["tab"] = LiveServer.tabName(model.tab)
        info["window_visible"] = ws == "visible"
        info["window_state"] = ws
        info["notice"] = notice ?? NSNull()
        guard ws != "visible" else { return (info, []) }
        let why: [String: String] = ["hidden": "app 被隐藏了（⌘H）", "minimized": "窗口最小化了",
                                     "occluded": "窗口被挡住了或者在别的桌面上", "no_window": "app 开着但没有窗口"]
        let message = "改动已生效并已存盘，但用户现在看不到选片工具的窗口（\(why[ws] ?? ws)）：请告诉用户切过去看；MCP 不会替用户把窗口拉出来。"
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

    /// 拼图写的回复：工程摘要、两个指纹、undo、live、预览。
    static func collageReply(_ req: Request, live: LiveServer, model: AppModel, body: [String: Any], digestBefore: String,
                             undo: [String: Any], notice: String?, warnings: [[String: Any]]) async -> Reply {
        let collage = model.collage
        var out = body
        out["session"] = currentKey(model.batch) ?? NSNull()
        out["digest_before"] = digestBefore
        out["digest_after"] = collage.editDigest
        out["pages"] = collage.project.pages.count
        out["page"] = collage.project.pages.isEmpty ? 0 : collage.pageIndex + 1
        out["undo"] = undo
        let (info, notVisible) = liveInfo(req, live: live, model: model, notice: notice)
        out["live"] = info
        var all = warnings + notVisible
        let (preview, settled) = await collagePreview(collage)
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
                            warnings: [[String: Any]] = [], landed: LandedCounts? = nil) async -> Reply {
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
                                  notice: notice, warnings: warnings)
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
        if history && req.params["confirm"] as? Bool != true {
            var data: [String: Any] = ["verdict_undo_steps": verdictSteps, "collage_undo_steps": collageSteps]
            data["collage_can_redo"] = collageRedo
            data["executed"] = false
            data["hint"] = "切场次会清掉用户在 app 里这一场的撤销记录：先问用户，同意了再带 confirm:true 调"
            return .failure("confirm_required",
                            "切场次会清掉 app 里这一场的撤销记录（判决 \(verdictSteps) 步、拼图 \(collageSteps) 步）：这次没有切", data)
        }
        // = 侧栏「最近场次」里点它（BatchView 的菜单就是这一句），只是不跟 bookmark：文件夹被挪进桌面 / 外置盘以后，
        // bookmark 会把 app 带过去读，绕过上面只按字符串的检查；不跟的话挪走了就是「照片文件夹已不存在」（app_says）。
        // 拼图工程跟着挂过去：AppModel 的订阅是下一拍才跑，这里同步挂一次，回复里的撤销栈和之后的 app_undo 看到的就是新场次的
        batch.switchSession(to: URL(fileURLWithPath: entry.path), followBookmark: false)
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
        let raw = req.params["verdict"] as? String ?? ""
        let target: Verdict? = verdictNames[raw]
        var changed: [String] = []
        var unchanged: [String] = []
        var missing: [String] = []
        for id in MCPArgs.uniqueStrings(req.params["ids"]) {
            guard batch.item(withID: id) != nil else {
                missing.append(id)
                continue
            }
            // 已经是这个判决（人工改的，不是「接受推荐」钉的；auto = 没有 override）的不动
            let same = target == nil ? batch.overrides[id] == nil : (batch.isManual(id) && batch.overrides[id] == target)
            if same { unchanged.append(id) } else { changed.append(id) }
        }
        guard !changed.isEmpty || !unchanged.isEmpty else {
            return .failure("photo_not_found", "这些 id 在 app 当前这一场里都没有：\(missing.joined(separator: ", "))",
                            ["hint": "id 是文件名去掉扩展名；先 cull_list_photos 看有哪些", "executed": false])
        }
        let pushesBefore = batch.overrideUndoPushes
        var notice: String?
        if !changed.isEmpty {
            // = 网格里按 1/2/3/0（一次只压一步撤销）；拼图托盘里的判决跟着刷（§9.5.2）。不调 keepPlace：用户的焦点不跟着跳
            batch.setOverrideBatch(changed, target)
            model.collage.refreshFromBatch()
            model.aiLog.recordWrite(.verdicts, op: req.opID ?? "", tool: "cull_set_verdicts", before: pushesBefore,
                                    after: batch.overrideUndoPushes, depth: batch.overrideUndoDepth)
            let what = target.map { "改成\($0.rawValue)" } ?? "恢复自动判决"
            let text = "AI：把 \(changed.count) 张\(what) · 在批量页 ⌘Z 撤销"
            batchNotice(batch, text)
            notice = text
        }
        if req.params["reveal"] as? Bool == true { model.tab = .batch }
        let counts = batch.verdictCounts
        var out: [String: Any] = ["changed": changed, "unchanged": unchanged, "missing_ids": missing]
        out["session"] = currentKey(batch) ?? NSNull()
        out["verdict_counts"] = ["pick": counts.pick, "usable": counts.usable, "reject": counts.reject]
        out["collage_tray_refreshed"] = !changed.isEmpty
        out["undo"] = undoInfo(.verdicts, added: changed.isEmpty ? 0 : 1, model: model)
        let (info, warnings) = liveInfo(req, live: live, model: model, notice: notice)
        out["live"] = info
        out["warnings"] = warnings
        return .result(out)
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
        guard let template = collage.template(named: name) else { return unknown() }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        // = 检视器里点模板（applyTemplate 自己会 setNotice，桥的提示接在它后面）
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
        return await kitWrite(req, live: live, model: model, kit: kit, coverStep: 0, tool: "collage_run_kit")
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
                         tool: String) async -> Reply {
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
        let landing = await collage.externalKit(kit, coverStep: coverStep)
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

    // MARK: collage.set_style（换样式 / 色调）

    static func setStyle(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_set_style", req) { return bad }
        if let stop = await begin(req, Gate(scope: .collage, digest: true), live: live, model: model) { return stop }
        model.ensureCollageAttached()
        let collage = model.collage
        let preset = req.params["style"] as? String
        let look = (req.params["look"] as? String).flatMap(CollageLook.init(rawValue:))
        let strength = req.params["look_strength"].flatMap(MCPArgs.number)
        var parts: [String] = []
        if let preset { parts.append("样式「\(CollageStyles.all.first { $0.key == preset }?.name ?? preset)」") }
        if let look { parts.append("色调「\(look.label)」") }
        if let strength { parts.append(String(format: "色调强度 %.2f", strength)) }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        // = 样式页点预设（不合并），色调、强度在同一步里再改（和界面一样，也会改「下次新建拼图沿用的默认样式」）
        let changed = collage.externalEdit { collage.setStyleParts(preset: preset, look: look, strength: strength) }
        let summary = "换了" + parts.joined(separator: "、")
        var body: [String: Any] = ["look": collage.project.style.look.rawValue]
        body["style"] = styleKey(collage.project.style) ?? NSNull()
        body["look_strength"] = MCPReadModel.r3(collage.project.style.lookStrength)
        return await collageDone(req, live: live, model: model, tool: "collage_set_style", changed: changed,
                                 pushesBefore: pushes, digestBefore: before, summary: summary, body: body)
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
            let (info, warnings) = liveInfo(req, live: live, model: model, notice: text)
            out["live"] = info
            out["warnings"] = warnings
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
