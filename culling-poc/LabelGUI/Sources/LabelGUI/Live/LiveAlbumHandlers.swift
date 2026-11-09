import Foundation
import CoreGraphics

/// 相册整本的桥方法（相册 A + B 第 2 波 · M）：分析里说的「MCP 只能操作当前跨页，AI 改不了整本」补上。
/// - collage.pages（collage_pages）：翻页、加 / 删 / 挪 / 锁 / 解锁 / 镜像跨页、单边换版式；
/// - collage.move_photos：照片挪到别的跨页（CollageStore.moveCells / addPhotos：当场落下，后台再精排）；
/// - collage.replace_photo：换一格照片（replacePhoto；编辑封面时 placeOnCover）；
/// - collage.preflight（只读）：导出前检查（CollagePreflight.run，离开主线程跑）；
/// - collage.print_spec：印厂规格读 / 套 / 改规则；
/// - collage.cover：封面做 / 重做 / 去掉 / 改书脊这些 / 进出封面编辑。
/// 只导几个跨页、看版 PDF 并进 collage.export，换照片的候选、整本摘要并进 collage.state（都在 LiveHandlers.swift）。
///
/// 编辑封面时 store 的「当前页」（page / root / selection）指向封面那一块（CollageBookCoverStore）。定下来的规矩：
/// - collage_get_state 照实报（editing_cover: true、page_kind: cover，cells / layout 按封面那一页的画布算）；
/// - collage_replace_photo 换的是封面那块的格子（placeOnCover：封面可以用跨页上已有的照片）；
/// - collage_set_layout / collage_auto_layout / collage_apply_template / collage_set_text 的 cell_text 回 invalid_state：
///   它们按工程的跨页画布算格子（applyDesignedLayout、engineLayout 用的是 project.canvas，不是封面那一页），套到封面上会算错；
/// - collage_pages、collage_move_photos 先退出封面编辑（同界面「点任何跨页卡退出」），再按跨页号做。
extension LiveHandlers {

    // MARK: - 共用的纯函数（--mcp-selftest 直接测）

    /// 跨页号的范围（「3」「1-3, 7」，同「导出 ▾」的范围）→ 从 0 起的下标；不给 = 当前跨页。写错 = 那句话。
    nonisolated static func pageSelection(_ raw: Any?, count: Int, current: Int) -> Result<[Int], CollageExportRange.Bad> {
        guard let text = raw as? String else {
            guard (0..<count).contains(current) else { return .failure(CollageExportRange.Bad(message: "还没有跨页")) }
            return .success([current])
        }
        return CollageExportRange.parse(text, count: count)
    }

    /// move 的 to（挪完以后这几个从第几个开始，从 0 起）→ CollageStore.movePages 认的 destination（SwiftUI onMove 的语义：
    /// 挪之前的下标、挪到它前面）。越界 = nil。
    nonisolated static func moveDestination(count: Int, picked: [Int], start: Int) -> Int? {
        let block = Array(Set(picked)).sorted()
        guard !block.isEmpty, block.allSatisfy({ (0..<count).contains($0) }), start >= 0, start + block.count <= count else {
            return nil
        }
        let order = Array(0..<count)
        for d in 0...count {
            let out = CollageAlbum.moved(order, from: IndexSet(block), to: d)
            if Array(out[start..<(start + block.count)]) == block { return d }
        }
        return nil
    }

    /// emptySlot → empty_slot（MCP 这边的键都是 snake_case）。
    nonisolated static func snakeCase(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase {
                out += "_" + ch.lowercased()
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// 导出前检查的一条：种类、拦 / 提醒、第几个跨页（从 1 起；整本的事 = null）、格子路径、照片、那句话。
    nonisolated static func issueRow(_ issue: CollagePreflightIssue) -> [String: Any] {
        var row: [String: Any] = ["kind": snakeCase(issue.kind.rawValue), "label": issue.kind.label]
        row["severity"] = issue.severity.rawValue
        row["message"] = issue.message
        row["page"] = issue.page.map { $0 + 1 } ?? NSNull()
        row["path"] = issue.path.map { $0.map(String.init).joined() } ?? NSNull()
        row["photo_id"] = issue.photoID ?? NSNull()
        if issue.item != nil { row["layer"] = true }
        return row
    }

    /// 导出前检查的结果主体：拦和提醒分开、各列前 limit 条；pages = 只导这几页时导出按钮会不会问（同「导出 ▾」）。
    nonisolated static func preflightBody(_ issues: [CollagePreflightIssue], project: CollageProject, pages only: [Int]?,
                                          limit: Int = 30) -> [String: Any] {
        let blocks = issues.filter { $0.severity == .block }
        let warns = issues.filter { $0.severity == .warn }
        var out: [String: Any] = ["summary": CollagePreflight.summary(issues), "block_count": blocks.count]
        out["warn_count"] = warns.count
        out["blocks"] = blocks.prefix(limit).map(issueRow)
        out["warnings"] = warns.prefix(limit).map(issueRow)
        out["truncated"] = blocks.count > limit || warns.count > limit
        if let ask = CollageStore.exportConfirmation(issues, project: project, pages: only) {
            out["export_would_ask"] = ["title": ask.title, "message": ask.message]
        } else {
            out["export_would_ask"] = NSNull()
        }
        out["pages"] = only.map { list in list.map { $0 + 1 } } ?? NSNull()
        return out
    }

    nonisolated static func pageKind(_ page: CollagePage) -> String {
        page.contactSheet != nil ? "contact_sheet" : (page.freeform ? "freeform" : "grid")
    }

    /// 印厂规格的页数（相册整本摘要、印厂规格工具共用）：画布名、装订、规则、几个跨页 = 几 P、合不合规。
    nonisolated static func printSummary(_ project: CollageProject) -> [String: Any] {
        let canvas = project.canvas
        let rules = canvas.effectivePrintRules
        let n = project.pages.count
        var out: [String: Any] = ["canvas": canvas.name, "binding": canvas.binding.rawValue, "rules": rules.summary]
        out["spreads"] = n
        out["pages_p"] = rules.pages(spreads: n)
        // false = 没套过规格：按保守默认查页数（照印厂给的改）
        out["preset"] = canvas.printRules != nil
        let problem: String? = canvas.seams == .fold ? rules.pageProblem(spreads: n) : nil
        out["page_problem"] = problem ?? NSNull()
        return out
    }

    nonisolated static func colorName(_ c: CollageColorSpace) -> String { c == .sRGB ? "srgb" : "adobe_rgb" }

    // MARK: - 整本摘要（collage_get_state 的 album、几个相册写工具的结果）

    static func albumInfo(_ collage: CollageStore) -> [String: Any] {
        let project = collage.project
        var spreads: [[String: Any]] = []
        for (i, page) in project.pages.enumerated() {
            var row: [String: Any] = ["page": i + 1, "photos": page.photoIDs, "locked": page.locked]
            row["kind"] = pageKind(page)
            spreads.append(row)
        }
        var out: [String: Any] = ["spreads": spreads]
        out["locked"] = project.pages.indices.filter { project.pages[$0].locked }.map { $0 + 1 }
        out["print"] = printSummary(project)
        out["cover"] = coverSummary(collage)
        return out
    }

    static func coverSummary(_ collage: CollageStore) -> [String: Any] {
        guard collage.isAlbum, let cover = collage.project.bookCover else { return ["exists": false, "editing": false] }
        var out: [String: Any] = ["exists": true, "editing": collage.editingCover]
        out["spine_mm"] = MCPReadModel.r3(cover.spineWidthMM(spreads: collage.project.pages.count))
        out["spine_estimated"] = cover.spineMM == nil
        return out
    }

    /// 当前页的几样（collage_get_state、翻页 / 改跨页的结果共用）：第几个、一共几个、是不是在编辑封面、格子、版式。
    /// 编辑封面时格子和版式按封面那一页的画布算（editCanvas），page 还是回去的那个跨页。
    static func pageFields(_ collage: CollageStore) -> [String: Any] {
        let project = collage.project
        var out: [String: Any] = ["page": project.pages.isEmpty ? 0 : collage.pageIndex + 1, "pages": project.pages.count]
        out["editing_cover"] = collage.editingCover
        guard let page = collage.page else {
            out["cells"] = [[String: Any]]()
            out["layout"] = NSNull()
            return out
        }
        let canvas = collage.editCanvas
        out["cells"] = cells(page, project: project, canvas: canvas)
        out["page_kind"] = collage.editingCover ? "cover" : pageKind(page)
        out["items"] = page.items.count
        // 这一页的版式（collage_set_layout 的语法）；散落版、印样没有切分树可写
        out["layout"] = page.freeform || page.contactSheet != nil ? NSNull()
            : CollageLayoutSpec.describe(page.root, canvas: canvas, style: project.style)
        return out
    }

    /// 编辑封面时不能用的「当前页」工具（理由见文件头）。
    static func coverEditingRefusal(_ collage: CollageStore, _ what: String) -> Reply? {
        guard collage.editingCover else { return nil }
        var data = notExecuted("先 collage_pages action=go 翻到要改的跨页（或 collage_cover action=done 回到原来那个跨页）；"
                               + "封面那块换照片用 collage_replace_photo，改书脊、封底用 collage_cover")
        data["reason"] = "editing_cover"
        return .failure("invalid_state", "正在编辑相册封面：\(what)只对跨页，这一次什么都没改", data)
    }

    /// 翻到第 index 个跨页（从 0 起）：编辑封面就先退出；暗房开着走暗房的换页（样张的焦点跟着新这一页的色调）。
    /// 返回画面换没换。
    @discardableResult
    static func goTo(_ index: Int, collage: CollageStore) -> Bool {
        var moved = false
        if collage.editingCover {
            collage.setEditingCover(false)
            moved = true
        }
        guard collage.project.pages.indices.contains(index), index != collage.pageIndex else { return moved }
        if let darkroom = collage.darkroom {
            darkroom.goToPage(index - collage.pageIndex)
        } else {
            collage.pageIndex = index
        }
        return true
    }

    /// 只换画面、不进撤销的那几步（翻页、进出封面编辑）的回复。
    static func viewReply(_ req: Request, live: LiveServer, model: AppModel, moved: Bool, text: String, before: String,
                          body: [String: Any]) async -> Reply {
        let collage = model.collage
        var notice: String?
        if moved {
            notice = "AI：" + text
            collage.setNotice(notice ?? text)
        }
        if req.params["reveal"] as? Bool == true { model.tab = .collage }
        var b = body
        b["changed"] = false
        b["view_changed"] = moved
        let undo: [String: Any] = ["target": NSNull(), "steps_added": 0, "how": "只换了画面，不进撤销"]
        return await collageReply(req, live: live, model: model, body: b, digestBefore: before, undo: undo, notice: notice,
                                  warnings: [])
    }

    static func albumBody(_ collage: CollageStore, _ extra: [String: Any]) -> [String: Any] {
        var out = pageFields(collage)
        out["album"] = albumInfo(collage)
        out.merge(extra) { _, new in new }
        return out
    }

    // MARK: - 用户自己在排的时候（挪照片、单边换版式）

    /// 用户自己点的排版还在后台算（换一批、加进现在的版式、自动编排……）：挪照片、换单边切法都会把它作废（store 里后做的
    /// 说了算），AI 不该替用户丢掉它（审查 R3#3：以前 collage_move_photos 不看这个，用户拖的那一下还在排就被 AI 作废了）。
    /// 先等它落下来（最多 min(剩余 − 5 s, 10 s)，Task.sleep，主线程空着）；还在算就回 invalid_state，什么都没做。
    static func waitForUserSolve(_ req: Request, _ collage: CollageStore) async -> Reply? {
        let limit = max(0, min(remainingMs(req) - 5_000, 10_000))
        let start = LiveWire.nowMs()
        while collage.isSolving {
            if LiveWire.nowMs() - start >= limit { return solvingRefusal() }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    static func solvingRefusal() -> Reply {
        var data = notExecuted("过几秒再调（collage_get_state 的 busy.solving 变成 false 以后）")
        data["reason"] = "solving"
        return .failure("invalid_state", "app 还在排用户刚点的那一版（还没落地）：现在动手会把它作废，这一次什么都没改", data)
    }

    // MARK: - collage.pages（翻页 / 改跨页）

    static func pagesOp(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_pages", req) { return bad }
        let action = req.params["action"] as? String ?? ""
        if action == "side_layout" { return await sideLayout(req, live: live, model: model) }
        if let stop = await begin(req, Gate(scope: .collage, digest: true), live: live, model: model) { return stop }
        model.ensureCollageAttached()
        let collage = model.collage
        let count = collage.project.pages.count
        let unit = collage.isAlbum ? "个跨页" : "页"
        guard count > 0 else {
            return .failure("invalid_state", "拼图里还没有任何一页。",
                            notExecuted("先 collage_run_kit kit=weddingAlbum 排一本，或者 collage_apply_template 排一版"))
        }
        if ["lock", "unlock", "mirror"].contains(action), !collage.isAlbum {
            return .failure("invalid_state", "锁住、镜像只对相册的跨页（现在是单张拼图）。", notExecuted(""))
        }
        let before = collage.editDigest
        let page = LiveWire.int(req.params["page"])
        if action == "go" || action == "add" {
            let target = (page ?? collage.pageIndex + 1) - 1
            guard (0..<count).contains(target) else {
                return invalid("没有第 \(target + 1) \(unit)：一共 \(count) \(unit)。", hint: "跨页号从 1 起，看 collage_get_state 的 pages、album.spreads")
            }
            if action == "go" {
                let moved = goTo(target, collage: collage)
                return await viewReply(req, live: live, model: model, moved: moved, text: "翻到第 \(target + 1) \(unit)", before: before,
                                       body: albumBody(collage, ["action": action]))
            }
            goTo(target, collage: collage)
            let pushes = collage.undoPushes
            let changed = collage.externalEdit { collage.addPage() }
            return await collageDone(req, live: live, model: model, tool: "collage_pages", changed: changed, pushesBefore: pushes,
                                     digestBefore: before, summary: "在第 \(target + 1) \(unit)后面加了一个空\(unit == "页" ? "页" : "跨页")",
                                     body: albumBody(collage, ["action": action]))
        }
        let picked: [Int]
        switch pageSelection(req.params["pages"], count: count, current: collage.pageIndex) {
        case .success(let list): picked = list
        case .failure(let bad): return invalid("pages 写错了：\(bad.message)。", hint: "跨页号从 1 起，写成「3」「1-3, 7」")
        }
        let label = CollageExportRange.label(picked)
        let set = IndexSet(picked)
        var summary = ""
        var refusal: Reply?
        switch action {
        case "delete":
            if picked.count >= count {
                refusal = invalid("不能把 \(count) \(unit)全删了：至少留一个。", hint: "要整本重排用 collage_run_kit kit=weddingAlbum")
            }
            summary = "删了第 \(label) \(unit)"
        case "move":
            let to = LiveWire.int(req.params["to"]) ?? 1
            if moveDestination(count: count, picked: picked, start: to - 1) == nil {
                refusal = invalid("to 超出了：挪 \(picked.count) \(unit)，to 只能是 1–\(count - picked.count + 1)。", hint: "to 是挪完以后它们从第几个开始")
            }
            summary = "把第 \(label) \(unit)挪到第 \(to) 个的位置"
        case "lock", "unlock":
            summary = (action == "lock" ? "锁住了" : "解锁了") + "第 \(label) \(unit)"
        case "mirror":
            if let sheet = picked.first(where: { collage.project.pages[$0].contactSheet != nil }) {
                refusal = .failure("invalid_state", "第 \(sheet + 1) 个跨页是印样：按拍摄先后排，不镜像。", notExecuted("pages 里去掉它再调"))
            }
            summary = "左右镜像了第 \(label) \(unit)"
        default:
            refusal = invalid("action 只能是 " + MCPArgs.pageActions.joined(separator: " / ") + "。")
        }
        if let refusal { return refusal }
        // 跨页类的先退出封面编辑（同界面：点任何跨页卡都退出）
        if collage.editingCover { collage.setEditingCover(false) }
        let pushes = collage.undoPushes
        let changed = collage.externalEdit {
            switch action {
            case "delete": collage.deletePages(set)
            case "move":
                if let d = moveDestination(count: count, picked: picked, start: (LiveWire.int(req.params["to"]) ?? 1) - 1) {
                    collage.movePages(set, to: d)
                }
            case "lock", "unlock": collage.setPagesLocked(set, action == "lock")
            default: for i in picked { collage.mirrorPage(i) }
            }
        }
        let body = albumBody(collage, ["action": action, "targets": picked.map { $0 + 1 }])
        return await collageDone(req, live: live, model: model, tool: "collage_pages", changed: changed, pushesBefore: pushes,
                                 digestBefore: before, summary: summary, body: body)
    }

    /// side_layout：只给一边换切法（CollageStore.cycleSideLayout）。第一次在后台算几种切法，之后在缓存里轮（同步）。
    /// 等的是自己这一票（cycleSideLayout 返回的求解代号 + 结局回调，审查 R3#6）：以前等的是「任何求解」（isSolving），
    /// 用户在等的时候点了自动编排，这一步早被作废了还一直等到截止，回 deadline_exceeded 说「会接着落下来」，其实不会；
    /// 真超时后落下来的又没记成 AI 的一步（app_undo 回 undo_not_ours）。现在：落下来 = AI 的一步（计数、深度按落地那一刻
    /// 的记，同 KitLanding）；代号变了 = 立刻回 superseded；到截止还在算 = 把自己这一票作废，回 deadline_exceeded（没有
    /// 落地，过后也不会落）。用户自己的排版还在算时先等它落下来（waitForUserSolve），不替用户把它作废。
    static func sideLayout(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        let collage = model.collage
        let gate = Gate(scope: .collage, digest: true)
        if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
        let now = model.interaction.reasons(model, scope: .collage)
        if now.contains(where: { !$0.transient }) { return userBusy(now, waited: 0) }
        model.indicator.began(workingLabel(req.method))
        model.ensureCollageAttached()
        let side: CollageSpreadSide = req.params["side"] as? String == "left" ? .left : .right
        let step = LiveWire.int(req.params["step"]) ?? 1
        let asked = LiveWire.int(req.params["page"])
        /// 落地前再查一遍（等的时候用户可能翻了页、改了版）：算不出别的切法的几种先挡下，说清楚为什么。
        func refusal() -> Reply? {
            let count = collage.project.pages.count
            guard collage.isAlbum, collage.project.canvas.seams == .fold else {
                return .failure("invalid_state", "左页、右页分开换版式只对相册的跨页。", notExecuted(""))
            }
            let index = (asked ?? collage.pageIndex + 1) - 1
            guard collage.project.pages.indices.contains(index) else {
                return invalid("没有第 \(index + 1) 个跨页：一共 \(count) 个。", hint: "跨页号从 1 起")
            }
            let page = collage.project.pages[index]
            guard !page.freeform, page.contactSheet == nil else {
                return .failure("invalid_state", "第 \(index + 1) 个跨页是\(page.freeform ? "散落版" : "印样")，没有左右两页的切法。", notExecuted(""))
            }
            guard let fold = CollageLayout.foldPath(page.root), let sub = page.root.node(at: fold + [side.rawValue]) else {
                return .failure("invalid_state", "第 \(index + 1) 个跨页找不到中缝那一刀（不是左右两页分开排的）。",
                                notExecuted("先 collage_auto_layout 排一版（或请用户点「换一批」），再换一边的切法"))
            }
            if sub.leaves.contains(where: \.locked) {
                return .failure("invalid_state", "第 \(index + 1) 个跨页的\(side.label)有锁住的格子：先解锁再换这一边的版式。", notExecuted(""))
            }
            if sub.leaves.filter({ $0.kind == .photo }).count < 2 {
                return .failure("invalid_state", "第 \(index + 1) 个跨页的\(side.label)只有一张照片，没有别的切法。",
                                notExecuted("换另一边，或者先用 collage_move_photos 往这一边挪几张"))
            }
            return nil
        }
        if let stop = refusal() { return stop }
        let budget = min(remainingMs(req) - 5_000, 20_000) / 1_000
        let settled = await collage.hintsSettled(timeout: max(0, budget))
        if let stop = await waitForUserSolve(req, collage) { return stop }
        if let stop = await settle(req, gate, live: live, model: model) { return stop }
        // settle 等用户停手的时候用户又点了「换一批」：照样不替用户作废它
        if collage.isSolving { return solvingRefusal() }
        if let stop = refusal() { return stop }
        goTo((asked ?? collage.pageIndex + 1) - 1, collage: collage)
        let pageID = collage.page?.id
        let before = collage.editDigest
        let epoch = model.aiLog.sessionEpoch
        let index = collage.pageIndex
        let box = SideCycleBox()
        let generation = collage.cycleSideLayout(side, step: step) { box.outcome = $0 }
        // 缓存里轮的、当场挡下的：回调已经来了（generation = nil）。后台那一次：等自己这一票。
        if let generation {
            let limit = max(1_000, remainingMs(req) - 1_000)
            let start = LiveWire.nowMs()
            while box.outcome == nil, collage.currentSolveGeneration == generation {
                if LiveWire.nowMs() - start >= limit {
                    guard collage.cancelSolve(generation: generation) else { break }
                    var data = notExecuted("这一次撤回了：没有落地、没有压撤销，过后也不会落下来；可以带长一点的 deadline_seconds 重来")
                    data["reason"] = "deadline"
                    return .failure("deadline_exceeded", "app 在截止时间内没算完这一边的切法", data)
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        // 代号变了、回调还没来（后台那一次要算完才回调，不等它）= 被后来的操作作废了
        guard let outcome = box.outcome else { return sideSuperseded(model, epoch: epoch, pageID: pageID) }
        switch outcome {
        case .superseded:
            return sideSuperseded(model, epoch: epoch, pageID: pageID)
        case .refused(let text):
            return .failure("invalid_state", text + "：这一次什么都没改", notExecuted("先 collage_get_state 看现在的样子"))
        case .landed(let pushes, let depth, _):
            var warnings: [[String: Any]] = []
            if !settled {
                warnings.append(MCPReadModel.warning("hints_pending", "路人信息还没算完：这一边的取景待会儿可能还会变。",
                                                     hint: "过一会儿调 collage_get_state 看预览"))
            }
            // 落下来压了恰好一步（applySideCycle）；计数、深度取落地那一刻的：之后用户按的键不算进 AI 这一步
            let at = LandedCounts(pushes: pushes, depth: depth, epoch: epoch)
            return await collageDone(req, live: live, model: model, tool: "collage_pages", changed: true, pushesBefore: pushes - 1,
                                     digestBefore: before, summary: "第 \(index + 1) 个跨页的\(side.label)换了一种切法",
                                     body: ["action": "side_layout", "side": side == .left ? "left" : "right", "step": step],
                                     warnings: warnings, landed: at).withAlbum(collage)
        }
    }

    /// cycleSideLayout 的结局回调写到这里（桥在主线程上每 20 ms 看一次）。
    final class SideCycleBox {
        var outcome: CollageStore.SideCycleOutcome?
    }

    /// 单边换版式被作废了：换了场次、翻了页、还是用户在拼图里做了新的操作。没落地、没压撤销。
    static func sideSuperseded(_ model: AppModel, epoch: Int, pageID: UUID?) -> Reply {
        guard model.aiLog.sessionEpoch == epoch else {
            var data = notExecuted("用户切了场次：先 app_status 看 open_session")
            data["reason"] = "session_switched"
            return .failure("superseded", "算的时候用户切了场次，这一次作废了：没有落地，没有压撤销", data)
        }
        if model.collage.page?.id != pageID { return pageMoved() }
        var data = notExecuted("用户在拼图里做了新的操作：先 collage_get_state 看现在的样子，再决定要不要重来")
        data["reason"] = "user_edit"
        return .failure("superseded", "算的时候用户在拼图里做了新的操作，这一次作废了：没有落地，没有压撤销", data)
    }

    // MARK: - collage.move_photos（照片挪到别的跨页）

    /// 挪哪几张、从哪来：source = nil 是托盘里还没上版的（addPhotos），否则都在这个跨页的格子里（moveCells，paths 是格子）。
    struct MovePlan {
        var target: Int
        var moving: [String]
        var already: [String]
        var source: Int?
        var paths: [[Int]]
    }

    /// movePlan 的结果：能挪（ok）或者直接回的那一句（stop）。Reply 不是 Error，用不了 Result。
    enum MoveCheck {
        case ok(MovePlan)
        case stop(Reply)
    }

    static func movePlan(_ ids: [String], to target: Int, collage: CollageStore) -> MoveCheck {
        let pages = collage.project.pages
        let unit = collage.isAlbum ? "个跨页" : "页"
        guard pages.indices.contains(target) else {
            return .stop(invalid("没有第 \(target + 1) \(unit)：一共 \(pages.count) \(unit)。", hint: "to 从 1 起，看 collage_get_state 的 album.spreads"))
        }
        if pages[target].contactSheet != nil {
            return .stop(.failure("invalid_state", "第 \(target + 1) \(unit)是印样：照片按拍摄先后排，挪不进去。",
                                     notExecuted("换一个跨页，或者请用户把照片拖进那一页的片条")))
        }
        var plan = MovePlan(target: target, moving: [], already: [], source: nil, paths: [])
        var sources = Set<Int>()
        var fromTray = false
        let map = collage.photoMap
        for id in ids {
            let at = pages.indices.filter { pages[$0].photoIDs.contains(id) }
            if at.contains(target) {
                plan.already.append(id)
                continue
            }
            if at.count > 1 {
                let listed = at.map { "\($0 + 1)" }.joined(separator: "、")
                return .stop(.failure("invalid_state", "「\(id)」在第 \(listed) \(unit)上都有：先删掉一处（collage_replace_photo 换掉一格）。",
                                         notExecuted("")))
            }
            if let s = at.first {
                sources.insert(s)
            } else {
                guard map[id] != nil else {
                    return .stop(invalid("「\(id)」不在拼图托盘里：这个工具只挪托盘和跨页上的照片。",
                                            hint: "先用 collage_set_layout / collage_auto_layout 把它放进某一页（会自动进托盘）"))
                }
                fromTray = true
            }
            plan.moving.append(id)
        }
        if plan.moving.isEmpty { return .ok(plan) }
        if sources.count > 1 || (fromTray && !sources.isEmpty) {
            let what = fromTray ? "有的在托盘里、有的已经在跨页上" : "分在第 " + sources.sorted().map { "\($0 + 1)" }.joined(separator: "、") + " \(unit)上"
            return .stop(invalid("这几张\(what)：一次只挪一个跨页上的，或者只放托盘里的。", hint: "分几次调，每次一组"))
        }
        guard let s = sources.first else { return .ok(plan) }
        let page = pages[s]
        guard !page.freeform, page.contactSheet == nil else {
            return .stop(.failure("invalid_state", "第 \(s + 1) \(unit)是\(page.freeform ? "散落版" : "印样")：那一页上的照片请用户在 app 里拖。",
                                     notExecuted("")))
        }
        for id in plan.moving {
            guard let path = page.root.leafPaths().first(where: { page.root.node(at: $0)?.cell?.photoID == id }) else {
                return .stop(.failure("invalid_state", "「\(id)」在第 \(s + 1) \(unit)上是贴着的相纸，不在格子里：请用户在 app 里拖。",
                                         notExecuted("")))
            }
            plan.paths.append(path)
        }
        plan.source = s
        return .ok(plan)
    }

    /// 照片挪到别的跨页（moveCells / addPhotos）。照片当场落下（同步的一步撤销，externalEdit 保证恰好一步），AI 的一步就是
    /// 这一步（aiLog 照记、app_undo 撤得回）；后台还有一次精排（CollageStore.refinePages，不另记撤销，用户动过的页不落）。
    /// 以前整个放在后台排、等任何求解落下来（审查 R1#2 / R3#6），中间被作废就悄悄没了。现在等的是自己这一次精排：落下来再
    /// 回，回复里的预览、digest_after 就是最后的样子（不然 AI 下一次带的 if_digest 一落就过期）；到截止前还没落下照样算成功，
    /// 多一条 refining。用户自己的排版还在算时先等它落下来（waitForUserSolve），不替用户把它作废（审查 R3#3）。
    static func movePhotos(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_move_photos", req) { return bad }
        let collage = model.collage
        let gate = Gate(scope: .collage, digest: true)
        if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
        let now = model.interaction.reasons(model, scope: .collage)
        if now.contains(where: { !$0.transient }) { return userBusy(now, waited: 0) }
        model.indicator.began(workingLabel(req.method))
        model.ensureCollageAttached()
        let ids = MCPArgs.uniqueStrings(req.params["photos"])
        let target = (LiveWire.int(req.params["to"]) ?? 1) - 1
        if case .stop(let stop) = movePlan(ids, to: target, collage: collage) { return stop }
        // 两页都按人脸排：和成套一样先等路人信息
        let budget = min(remainingMs(req) - 5_000, 20_000) / 1_000
        let settled = await collage.hintsSettled(timeout: max(0, budget))
        if let stop = await waitForUserSolve(req, collage) { return stop }
        if let stop = await settle(req, gate, live: live, model: model) { return stop }
        // settle 等用户停手的时候用户又点了「换一批」：照样不替用户作废它
        if collage.isSolving { return solvingRefusal() }
        let plan: MovePlan
        switch movePlan(ids, to: target, collage: collage) {
        case .stop(let stop): return stop
        case .ok(let p): plan = p
        }
        let before = collage.editDigest
        var extra: [String: Any] = ["to": target + 1, "moved": plan.moving, "already_there": plan.already]
        extra["from"] = plan.source.map { $0 + 1 } ?? NSNull()
        guard !plan.moving.isEmpty else {
            return await collageDone(req, live: live, model: model, tool: "collage_move_photos", changed: false,
                                     pushesBefore: collage.undoPushes, digestBefore: before, summary: "",
                                     body: albumBody(collage, extra))
        }
        if collage.editingCover { collage.setEditingCover(false) }
        if let s = plan.source { goTo(s, collage: collage) }
        let pushes = collage.undoPushes
        let epoch = model.aiLog.sessionEpoch
        var ticket: Int?
        let changed = collage.externalEdit {
            if plan.source != nil {
                ticket = collage.moveCells(plan.paths, toPage: target)
            } else {
                ticket = collage.addPhotos(plan.moving, toPage: target)
            }
        }
        // 计数、深度取落地那一刻的（同 KitLanding）：等精排的时候用户按的键不算进 AI 这一步
        let at = LandedCounts(pushes: collage.undoPushes, depth: collage.undoDepth, epoch: epoch)
        guard changed else {
            // store 自己挡下了（状态栏上说了为什么）；movePlan 已经挡掉了能想到的几种，走到这里很少见
            let why = collage.notice ?? "app 没有挪这几张"
            return .failure("invalid_state", why + "：这一次什么都没改", notExecuted("先 collage_get_state 看现在的样子"))
        }
        var warnings: [[String: Any]] = []
        if !settled {
            warnings.append(MCPReadModel.warning("hints_pending", "路人信息还没算完：这两页的取景待会儿可能还会变。",
                                                 hint: "过一会儿调 collage_get_state 看预览"))
        }
        if let ticket {
            let limit = max(0, remainingMs(req) - 2_500)
            let start = LiveWire.nowMs()
            while collage.isRefining(ticket), LiveWire.nowMs() - start < limit {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if collage.isRefining(ticket) {
                warnings.append(MCPReadModel.warning("refining",
                                                     "照片已经挪过去了（一步撤销），app 还在后台精排这两页：精排落下来时版式会再变一次（不另压撤销，digest 也跟着变）。",
                                                     hint: "过几秒 collage_get_state 看最后的样子（busy.refining 变成 false 以后）"))
            }
        }
        let unit = collage.isAlbum ? "个跨页" : "页"
        let what = plan.source.map { "从第 \($0 + 1) \(unit)" } ?? "从托盘"
        let summary = "\(what)挪了 \(plan.moving.count) 张到第 \(target + 1) \(unit)"
        return await collageDone(req, live: live, model: model, tool: "collage_move_photos", changed: true, pushesBefore: pushes,
                                 digestBefore: before, summary: summary, body: extra, warnings: warnings, landed: at)
            .withAlbum(collage)
    }

    // MARK: - collage.replace_photo（换一格照片）

    static func replacePhotoOp(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_replace_photo", req) { return bad }
        if let stop = await begin(req, Gate(scope: .collage, digest: true), live: live, model: model) { return stop }
        model.ensureCollageAttached()
        let collage = model.collage
        let raw = req.params["path"] as? String ?? ""
        let path = raw.compactMap(\.wholeNumberValue)
        let id = req.params["with"] as? String ?? ""
        guard let page = collage.page, !page.freeform, page.contactSheet == nil else {
            let kind = collage.page.map { $0.freeform ? "散落版" : "印样" } ?? "空的"
            return .failure("invalid_state", "当前页是\(kind)，没有能换的格子。", notExecuted("先 collage_pages action=go 翻到网格版的跨页"))
        }
        guard let node = page.root.node(at: path), node.isLeaf, let cell = node.cell, cell.kind == .photo else {
            return invalid("格子「\(raw)」不是这一页的照片格。", hint: "先 collage_get_state 看 cells（kind 是 photo 的 path）")
        }
        guard collage.photoMap[id] != nil else {
            return invalid("托盘里没有「\(id)」。", hint: "候选用 collage_get_state 的 candidates_for 拿；要用托盘外的照片先 collage_set_layout 放进来")
        }
        let old = cell.photoID
        let before = collage.editDigest
        let pushes = collage.undoPushes
        var extra: [String: Any] = ["path": raw, "with": id, "replaced": old ?? NSNull()]
        extra["target"] = collage.editingCover ? "cover" : "page"
        guard old != id else {
            return await collageDone(req, live: live, model: model, tool: "collage_replace_photo", changed: false,
                                     pushesBefore: pushes, digestBefore: before, summary: "", body: albumBody(collage, extra))
        }
        // 对调：同一页别的格子里有它 = 这一页里对调；相册别的跨页的格子里有它 = 两个跨页对调（store 的 replacePhoto 也这么做）
        var swapped: [String: Any]?
        if let other = page.root.leafPaths().first(where: { $0 != path && page.root.node(at: $0)?.cell?.photoID == id }) {
            swapped = ["page": collage.editingCover ? NSNull() : collage.pageIndex + 1, "path": other.map(String.init).joined()]
        } else if !collage.editingCover, collage.isAlbum, !collage.usedOnOtherSpreads([id]).isEmpty {
            let pages = collage.project.pages
            var hit: (Int, [Int])?
            for (i, p) in pages.enumerated() where i != collage.pageIndex && !p.freeform && p.contactSheet == nil {
                if let q = p.root.leafPaths().first(where: { p.root.node(at: $0)?.cell?.photoID == id }) {
                    hit = (i, q)
                    break
                }
            }
            guard let hit else {
                let at = pages.indices.first { pages[$0].photoIDs.contains(id) } ?? 0
                return .failure("invalid_state", "「\(id)」在第 \(at + 1) 个跨页上是散落的相纸或印样里的一帧，不能对调。",
                                notExecuted("换一张候选，或者请用户在 app 里拖"))
            }
            swapped = ["page": hit.0 + 1, "path": hit.1.map(String.init).joined()]
        }
        extra["swapped"] = swapped ?? NSNull()
        let changed = collage.externalEdit {
            if collage.editingCover {
                collage.placeOnCover(photoID: id, at: path, edge: nil)
            } else {
                collage.replacePhoto(at: path, with: id)
            }
        }
        let place = collage.editingCover ? "封面那块" : "第 \(collage.pageIndex + 1) 个跨页"
        let tail = swapped.map { s in "（和第 \((s["page"] as? Int).map(String.init) ?? "这") 个跨页那一格对调）" } ?? ""
        return await collageDone(req, live: live, model: model, tool: "collage_replace_photo", changed: changed, pushesBefore: pushes,
                                 digestBefore: before, summary: "\(place)的格子「\(raw)」换成了 \(id)\(tail)",
                                 body: albumBody(collage, extra))
    }

    // MARK: - collage.preflight（导出前检查，只读）

    /// params {"session","texts","pages","text_max"}。整本过一遍 CollagePreflight.run（离开主线程：texts 要每页低清排一遍字）。
    static func preflightRead(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        var args: [String: Any] = [:]
        for name in ["texts", "pages"] { if let v = req.params[name] { args[name] = v } }
        if let p = MCPArgs.check("collage_preflight", args) { return invalid(p.message, hint: p.hint) }
        let batch = model.batch
        guard let key = currentKey(batch), req.params["session"] as? String == key else { return sessionNotOpen(live, model) }
        model.ensureCollageAttached()
        let collage = model.collage
        let project = collage.project
        guard !project.pages.isEmpty else {
            return .failure("invalid_state", "拼图里还没有任何一页，没什么可查。", ["hint": "先 collage_run_kit 或 collage_apply_template 排一版"])
        }
        var only: [Int]?
        if let text = req.params["pages"] as? String {
            switch CollageExportRange.parse(text, count: project.pages.count) {
            case .success(let list): only = list
            case .failure(let bad): return invalid("pages 写错了：\(bad.message)。", hint: "跨页号从 1 起，写成「3」「1-3, 7」")
            }
        }
        let texts = req.params["texts"] as? Bool ?? true
        let pending = collage.hintsPending
        let box = LiveBox((project, collage.hints))
        let issues = await Task.detached(priority: .userInitiated) { () -> LiveBox<[CollagePreflightIssue]> in
            let (p, h) = box.value
            return LiveBox(CollagePreflight.run(project: p, hints: h, texts: texts))
        }.value.value
        var out = preflightBody(issues, project: project, pages: only)
        out["session"] = key
        out["texts"] = texts
        out["mode"] = project.mode.rawValue
        out["hints_pending"] = pending
        out["print"] = printSummary(project)
        out["pending_writes"] = live.pendingWrites
        var warnings: [[String: Any]] = []
        if pending {
            warnings.append(MCPReadModel.warning("hints_pending", "路人信息还没算完：放大倍数、脸压不压中缝跟着取景变，待会儿可能不一样。",
                                                 hint: "过一会儿再查一次"))
        }
        out["warnings"] = warnings
        return .result(out)
    }

    // MARK: - collage.export 的 proof（看版 PDF）

    /// 「导出 ▾ › 印刷 › 出看版 PDF」（CollageStore.startProofPDF）：写进输出目录「名_看版.pdf」，同名加 -2 不覆盖，不弹访达。
    /// 前面那几道（场次、忙、输出目录在拍摄文件夹里、卡上）exportCollage 已经查过。
    static func exportProof(_ req: Request, live: LiveServer, model: AppModel, project: CollageProject, name: String,
                            body base: [String: Any], settled: Bool, folderReminder: String?) async -> Reply {
        let collage = model.collage
        let started = Date()
        let folder = collage.outputFolder
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<String, CollageExportRange.Bad>, Never>) in
            collage.startProofPDF(project: project, name: name, reveal: false) { cont.resume(returning: $0) }
        }
        let file: String
        switch result {
        case .failure(let bad):
            return .failure("export_failed", "看版 PDF 没出来：\(bad.message)。",
                            ["hint": "看 app 拼图页底下的提示；输出目录写不进去的话请用户换一个", "executed": false])
        case .success(let f):
            file = f
        }
        var body = base
        var row: [String: Any] = ["name": file]
        if let folder {
            let url = folder.appendingPathComponent(file)
            row["path"] = url.path
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int { row["bytes"] = size }
        }
        // 每个跨页一页，有封面放在最前面
        row["pdf_pages"] = project.pages.count + (project.bookCover != nil ? 1 : 0)
        body["proof"] = true
        body["folder"] = folder?.path ?? NSNull()
        body["files"] = [row]
        body["seconds"] = MCPReadModel.r3(Date().timeIntervalSince(started))
        body["hints_settled"] = settled
        var warnings: [[String: Any]] = []
        if !settled {
            warnings.append(MCPReadModel.warning("hints_pending", "路人信息还没算完：这份看版的裁切可能和算完以后不一样。",
                                                 hint: "想要稳定的结果，过一会儿再出一次"))
        }
        if let note = folderReminder {
            warnings.append(MCPReadModel.warning("export_folder_in_session", note,
                                                 hint: "请用户确认是不是真要导到那一场的拍摄文件夹里；不是的话在拼图页顶栏「导出 ▾」里换个目录"))
        }
        let notice = "AI：出了看版 PDF → \(folder?.lastPathComponent ?? "")"
        collage.setNotice(notice)
        if req.params["reveal"] as? Bool == true { model.tab = .collage }
        let (info, notVisible) = liveInfo(req, live: live, model: model, notice: notice)
        body["live"] = info
        body["warnings"] = warnings + notVisible
        return .result(body)
    }

    // MARK: - collage.print_spec（印厂规格）

    static let printFields = ["spec", "min_pages", "max_pages", "page_step", "single_ends", "color", "jpeg_quality", "fold_mm", "auto"]

    /// 现在这本的规格和能套的规格表。
    static func printInfo(_ collage: CollageStore, withSpecs: Bool) -> [String: Any] {
        let canvas = collage.project.canvas
        let rules = canvas.effectivePrintRules
        let size = canvas.pageSizeCM
        let dpi = max(1, canvas.dpi)
        func mm(_ px: Double) -> Double { (px / dpi * 25.4 * 100).rounded() / 100 }
        var cur: [String: Any] = ["name": canvas.name, "album": collage.isAlbum]
        cur["page_cm"] = [(size.width * 100).rounded() / 100, (size.height * 100).rounded() / 100]
        cur["dpi"] = canvas.dpi
        cur["bleed_mm"] = mm(Double(canvas.bleed))
        cur["safe_mm"] = mm(Double(canvas.safe))
        cur["binding"] = canvas.binding.rawValue
        cur["min_pages"] = rules.minPages
        cur["max_pages"] = rules.maxPages
        cur["page_step"] = rules.pageStep
        cur["single_ends"] = rules.singleEnds
        cur["color"] = colorName(rules.colorSpace)
        cur["jpeg_quality"] = rules.jpegQuality.map(MCPReadModel.r3) ?? NSNull()
        let fold: Double? = canvas.binding == .glued ? rules.gluedFoldMM : rules.layflatFoldMM
        cur["fold_mm"] = canvas.seams == .fold ? mm(canvas.foldBand) : NSNull()
        cur["fold_auto"] = fold == nil
        let matching = collage.printSpecs.first { $0.matches(canvas) }
        cur["spec"] = matching.map { ($0.key ?? $0.name) as Any } ?? NSNull()
        cur.merge(printSummary(collage.project)) { old, _ in old }
        var out: [String: Any] = ["current": cur]
        if withSpecs {
            out["specs"] = collage.printSpecs.map { s -> [String: Any] in
                var row: [String: Any] = ["key": s.key ?? NSNull(), "name": s.name, "detail": s.detail]
                row["current"] = s.matches(canvas)
                row["mine"] = s.key == nil
                return row
            }
        }
        return out
    }

    static func printSpecOp(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_print_spec", req) { return bad }
        let gate = Gate(scope: .collage, digest: true)
        let collage = model.collage
        func given(_ k: String) -> Bool { req.params[k] != nil && !(req.params[k] is NSNull) }
        guard printFields.contains(where: given) else {
            // 只读：不等用户停手（同导入客户选择的 dry_run）
            if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
            model.ensureCollageAttached()
            var body = printInfo(collage, withSpecs: true)
            body["changed"] = false
            let undo: [String: Any] = ["target": NSNull(), "steps_added": 0, "how": "只读，什么都没改"]
            return await collageReply(req, live: live, model: model, body: body, digestBefore: collage.editDigest, undo: undo,
                                      notice: nil, warnings: [])
        }
        if let stop = await begin(req, gate, live: live, model: model) { return stop }
        model.ensureCollageAttached()
        guard collage.isAlbum else {
            return .failure("invalid_state", "印厂规格只对相册（现在是单张拼图）。",
                            notExecuted("先 collage_run_kit kit=weddingAlbum 排一本（会切到相册），或者请用户在 app 里切到「相册」"))
        }
        var spec: CollagePrintSpec?
        if let name = req.params["spec"] as? String {
            guard let found = CollagePrintSpec.find(name, in: collage.userPrintSpecs) else {
                let keys = collage.printSpecs.map { $0.key ?? $0.name }.joined(separator: " / ")
                return invalid("没有规格「\(name)」。", hint: "能用的：\(keys)（不给参数调一次看 specs）")
            }
            spec = found
        }
        let binding = spec?.binding ?? collage.project.canvas.binding
        var rules = spec?.rules ?? collage.project.canvas.effectivePrintRules
        if let n = LiveWire.int(req.params["min_pages"]) { rules.minPages = n }
        if let n = LiveWire.int(req.params["max_pages"]) { rules.maxPages = n }
        if let n = LiveWire.int(req.params["page_step"]) { rules.pageStep = n }
        if let b = req.params["single_ends"] as? Bool { rules.singleEnds = b }
        if let c = req.params["color"] as? String { rules.colorSpace = c == "adobe_rgb" ? .adobeRGB : .sRGB }
        if let q = req.params["jpeg_quality"].flatMap(MCPArgs.number) { rules.jpegQuality = q }
        if let mm = req.params["fold_mm"].flatMap(MCPArgs.number) {
            if binding == .glued { rules.gluedFoldMM = mm } else { rules.layflatFoldMM = mm }
        }
        let auto = MCPArgs.uniqueStrings(req.params["auto"])
        if auto.contains("jpeg_quality") { rules.jpegQuality = nil }
        if auto.contains("fold_mm") {
            if binding == .glued { rules.gluedFoldMM = nil } else { rules.layflatFoldMM = nil }
        }
        guard rules.minPages <= rules.maxPages else {
            return invalid("最少 \(rules.minPages)P 比最多 \(rules.maxPages)P 还多。", hint: "一起给 min_pages、max_pages")
        }
        let before = collage.editDigest
        let pushes = collage.undoPushes
        // 套规格（applyPrintSpec 自己合成一步：换画布 + 换装订）和改规则合在一份规格里套：分两次调的话里面那一组会把外面这一步拆开
        let changed = collage.externalEdit {
            if var s = spec {
                s.rules = rules
                collage.applyPrintSpec(s)
            } else {
                collage.setPrintRules(rules)
            }
        }
        var parts: [String] = []
        if let s = spec { parts.append("套了规格「\(s.name)」") }
        let ruleKeys = ["min_pages", "max_pages", "page_step", "single_ends", "color", "jpeg_quality", "fold_mm", "auto"]
        if ruleKeys.contains(where: given) { parts.append("改了印厂规格的规则") }
        var body = printInfo(collage, withSpecs: false)
        body["album"] = albumInfo(collage)
        return await collageDone(req, live: live, model: model, tool: "collage_print_spec", changed: changed, pushesBefore: pushes,
                                 digestBefore: before, summary: parts.joined(separator: "、"), body: body)
    }

    // MARK: - collage.cover（封面）

    static func coverInfo(_ collage: CollageStore) -> [String: Any] {
        let project = collage.project
        guard collage.isAlbum, let cover = project.bookCover, let layout = collage.coverLayout else {
            return ["exists": false, "editing": false, "album": collage.isAlbum]
        }
        let spreads = project.pages.count
        let dpi = max(1, project.canvas.dpi)
        func mm(_ px: Int) -> Double { (Double(px) / dpi * 25.4 * 10).rounded() / 10 }
        var out: [String: Any] = ["exists": true, "editing": collage.editingCover, "album": true]
        out["spine_mm"] = MCPReadModel.r3(cover.spineWidthMM(spreads: spreads))
        out["spine_estimated"] = cover.spineMM == nil
        out["estimated_spine_mm"] = MCPReadModel.r3(cover.estimatedSpineMM(spreads: spreads))
        out["wrap_mm"] = MCPReadModel.r3(cover.wrapMM)
        out["board_mm"] = MCPReadModel.r3(cover.boardMM)
        out["sheet_mm"] = MCPReadModel.r3(cover.sheetMM)
        out["spine_title"] = cover.spineTitle
        out["spine_date"] = cover.spineDate
        out["back_photo"] = cover.back.photoID ?? NSNull()
        out["back_text"] = cover.back.text
        out["front_photos"] = cover.front.photoIDs
        out["size_px"] = [layout.width, layout.height]
        out["size_mm"] = [mm(layout.width), mm(layout.height)]
        out["notes"] = collage.coverNotes
        out["face_warnings"] = collage.coverFaceWarnings
        return out
    }

    static func coverOp(_ req: Request, live: LiveServer, model: AppModel) async -> Reply {
        if let bad = checkArgs("collage_cover", req) { return bad }
        let gate = Gate(scope: .collage, digest: true)
        let collage = model.collage
        func given(_ k: String) -> Bool { req.params[k] != nil && !(req.params[k] is NSNull) }
        let action = req.params["action"] as? String
        let fields = MCPArgs.coverFields.filter(given)
        if action == nil && fields.isEmpty {
            if let stop = precheck(req, gate, live: live, model: model, waited: false) { return stop }
            model.ensureCollageAttached()
            var body: [String: Any] = ["cover": coverInfo(collage), "changed": false]
            body["editing_cover"] = collage.editingCover
            let undo: [String: Any] = ["target": NSNull(), "steps_added": 0, "how": "只读，什么都没改"]
            return await collageReply(req, live: live, model: model, body: body, digestBefore: collage.editDigest, undo: undo,
                                      notice: nil, warnings: [], coverPreview: true)
        }
        if let stop = await begin(req, gate, live: live, model: model) { return stop }
        model.ensureCollageAttached()
        guard collage.isAlbum else {
            return .failure("invalid_state", "封面只有相册有（现在是单张拼图）。",
                            notExecuted("先 collage_run_kit kit=weddingAlbum 排一本，或者请用户在 app 里切到「相册」"))
        }
        let has = collage.project.bookCover != nil
        let before = collage.editDigest
        if action == "edit" || action == "done" {
            let on = action == "edit"
            if on && !has {
                return .failure("invalid_state", "还没有封面，进不了封面编辑。", notExecuted("先 collage_cover action=make"))
            }
            if on && collage.darkroom != nil {
                return .failure("invalid_state", "暗房开着：封面编辑要在拼图页的画布上。", notExecuted("请用户先关掉暗房"))
            }
            let moved = collage.editingCover != on
            collage.setEditingCover(on)
            var body: [String: Any] = ["cover": coverInfo(collage), "editing_cover": collage.editingCover]
            body.merge(pageFields(collage)) { old, _ in old }
            let text = on ? "进了封面编辑" : "回到第 \(collage.pageIndex + 1) 个跨页"
            // 预览：进了编辑 = 画布上就是整张封面；出来 = 回去的那个跨页
            return await viewReply(req, live: live, model: model, moved: moved, text: text, before: before, body: body)
        }
        switch action {
        case "make" where has:
            return .failure("invalid_state", "已经有封面了。",
                            notExecuted("按现在的扉页重做封面那块用 action=remake；只改书脊、封底直接给字段"))
        case "remake" where !has:
            return .failure("invalid_state", "还没有封面，没什么可重做。", notExecuted("先 collage_cover action=make"))
        case nil where !has:
            return .failure("invalid_state", "还没有封面：先做一个再改。", notExecuted("带 action=make 和这些字段一起调"))
        default:
            break
        }
        if let back = req.params["back_photo"] as? String, !back.isEmpty, collage.photoMap[back] == nil {
            return invalid("托盘里没有「\(back)」：封底只能放托盘里的照片。", hint: "照片 id 见 collage_get_state 的 tray_photos")
        }
        let pushes = collage.undoPushes
        var made = true
        let changed = collage.externalEdit {
            switch action {
            case "make", "remake": made = collage.makeCover(replace: action == "remake")
            case "remove": collage.removeCover()
            default: break
            }
            guard made, collage.project.bookCover != nil else { return }
            if req.params["spine_auto"] as? Bool == true { collage.setCoverSpine(nil) }
            if let v = req.params["spine_mm"].flatMap(MCPArgs.number) { collage.setCoverSpine(v) }
            if let v = req.params["wrap_mm"].flatMap(MCPArgs.number) { collage.setCoverWrap(v) }
            if let v = req.params["board_mm"].flatMap(MCPArgs.number) { collage.setCoverBoard(v) }
            if let v = req.params["sheet_mm"].flatMap(MCPArgs.number) { collage.setCoverSheet(v) }
            let title = req.params["spine_title"] as? String
            let date = req.params["spine_date"] as? String
            if title != nil || date != nil { collage.setCoverSpineText(title: title, date: date) }
            if let back = req.params["back_photo"] as? String { collage.setCoverBackPhoto(back.isEmpty ? nil : back) }
            if let text = req.params["back_text"] as? String { collage.setCoverBackText(text) }
        }
        collage.endCoalescing()
        guard made else {
            return .failure("invalid_state", (collage.notice ?? "封面没做出来") + "。", notExecuted("先往拼图托盘里带几张照片"))
        }
        var parts: [String] = []
        switch action {
        case "make": parts.append("做了封面")
        case "remake": parts.append("按扉页重做了封面")
        case "remove": parts.append("去掉了封面")
        default: break
        }
        if !fields.isEmpty { parts.append("改了封面的" + fields.map(coverFieldLabel).joined(separator: "、")) }
        var body: [String: Any] = ["cover": coverInfo(collage), "editing_cover": collage.editingCover]
        if let action { body["action"] = action }
        return await collageDone(req, live: live, model: model, tool: "collage_cover", changed: changed, pushesBefore: pushes,
                                 digestBefore: before, summary: parts.joined(separator: "，"), body: body, coverPreview: true)
    }

    nonisolated static func coverFieldLabel(_ key: String) -> String {
        let labels: [String: String] = [
            "spine_mm": "书脊宽", "spine_auto": "书脊宽（改回估算）", "wrap_mm": "包边", "board_mm": "板厚", "sheet_mm": "纸厚",
            "spine_title": "书脊标题", "spine_date": "书脊日期", "back_photo": "封底照片", "back_text": "封底的字",
        ]
        return labels[key] ?? key
    }

    /// 整张封面（封底 | 书脊 | 封面，带包边、出血和参考线）的预览：离开主线程渲，长边 1024。没有封面 = 空。
    static func coverPreviewFields(_ collage: CollageStore) async -> [String: Any] {
        guard collage.isAlbum, let layout = collage.coverLayout else { return [:] }
        let scale = min(1, 1024 / Double(max(1, max(layout.width, layout.height))))
        let box = LiveBox((collage.project, collage.hints))
        return await Task.detached(priority: .userInitiated) { () -> LiveBox<[String: Any]> in
            let (p, h) = box.value
            var opts = CollageRender.Options(scale: scale)
            opts.includeBleed = true
            opts.guides = true
            opts.placeholders = true
            opts.watermark = true
            guard let image = CollageBookCoverRender.render(project: p, hints: h, options: opts),
                  let enc = LiveImages.encode(image, maxEdge: 1024) else { return LiveBox([:]) }
            var e: [String: Any] = ["preview_jpeg_b64": enc.data.base64EncodedString()]
            e["preview_width"] = enc.width
            e["preview_height"] = enc.height
            e["preview_bytes"] = enc.data.count
            e["preview_kind"] = "cover"
            return LiveBox(e)
        }.value.value
    }
}

extension LiveServer.Reply {
    /// 相册写工具的结果补上整本摘要（落下来以后的样子：照片现在在哪个跨页）。不是结果（出错）原样返回。
    @MainActor
    func withAlbum(_ collage: CollageStore) -> LiveServer.Reply {
        guard case .result(var r) = self else { return self }
        r["album"] = LiveHandlers.albumInfo(collage)
        r.merge(LiveHandlers.pageFields(collage)) { old, _ in old }
        return .result(r)
    }
}
