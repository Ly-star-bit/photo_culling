import Foundation

/// v1 的 18 个工具定义和两版 instructions（DESIGN §10.1；schema 规则见 §3.0）。
/// - 全部写在下面一个原始 JSON 字符串里，启动时解析一次：大字典字面量会让 Xcode 16 / Swift 6.1 的类型检查超时（5277c01）。
/// - 会随代码变的名单不写死：style / look / kit 的 enum、模板和分类的数目，启动时从 CollageStyles.all、CollageLook、
///   CollageKitID、CollageTemplates.builtin 算出来填进去。
/// - 占位：值是 "$XXX" 的字符串换成 `snippets` 里同名的那一段（通用参数、注解）或者上面那几张名单；
///   字符串里的 {{xxx}} 换成数字和名字。
/// - 前 3 个在 LABELGUI_MCP_LIVE=0 时用 description_disabled：那时 tools/list 里只有它们 3 个，
///   描述里不能提不在列表里的工具（CI 检查）。
enum MCPToolDefs {
    /// app 没开时也能用的 3 个（§10.1 第 1–3 个），LABELGUI_MCP_LIVE=0 时只注册它们。
    static let alwaysAvailable = ["app_status", "cull_list_sessions", "collage_list_templates"]

    static func tools(live: Bool) -> [[String: Any]] { live ? liveTools : disabledTools }
    static func instructions(live: Bool) -> String { live ? liveInstructions : disabledInstructions }

    static var styleKeys: [String] { CollageStyles.all.map(\.key) }
    static var lookKeys: [String] { CollageLook.allCases.map(\.rawValue) }
    static var kitIDs: [String] { CollageKitID.allCases.map(\.rawValue) }

    /// 内置模板的分类，按模板库里的顺序（第一次出现的位置）。
    static var templateCategories: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in CollageTemplates.builtin where !t.category.isEmpty && !seen.contains(t.category) {
            seen.insert(t.category)
            out.append(t.category)
        }
        return out
    }

    // MARK: - instructions（§10.1 定稿，原样）

    static let liveInstructions = """
    xuanpian 是本机「选片工具」（photo culling + collage）的接口，这一版只做实时：用户开着 app 时，读 app 当前打开的那一场（判决 pick/usable/reject、废片理由、章节、场、近似重复、人脸/闭眼/锐度/EXIF、预览图），以及改判、在 app 里定位照片、切场次、套拼图模板、一键成套、换封面、改标题/刊头/期号、换样式色调、撤销，都由 app 自己执行，窗口里当场看得到，用户按 ⌘Z 能撤。app 没开时只能看状态、列场次、列模板，其余工具返回 app_not_running：MCP 绝不会启动 app，请用户自己打开。先调 app_status。
    流程：app_status（live.state 是 live 才能用其余工具；live.open_session 是 app 当前打开的那一场，所有 session 参数都填它）→ cull_session_overview → cull_list_groups / cull_list_photos → cull_get_photos / cull_preview_photos（看眼睛、对焦用 crop=face）。要别的场次：cull_list_sessions 找到它，再 app_open_session（只能打开 app「最近场次」里的；会清掉 app 里这一场的撤销记录，先问用户）。改判用 cull_set_verdicts，给用户看用 cull_show_photos；拼图先 collage_get_state，再 collage_apply_template / collage_run_kit / collage_next_cover / collage_set_text / collage_set_style，结果里有 app 当前画面的预览；撤销 AI 自己刚做的一步用 app_undo。
    出错时：user_busy 的 data.transient 为 true 是用户正在拖动或打字，等几秒再调；为 false 是开着对话框、连拍挑选或裁切，请用户先关掉，不要重试。app_outcome_unknown：用结果里的 op_id 原样再调同一个工具，不要换工具。session_not_open：先 app_status 看 open_session。其他错误按 hint 改。读到的是 app 内存里的状态（含还没存盘的改动）。图片是缩小预览，文字结果里有预览文件的路径；不要直接读原图（几十 MB）。session 可以填照片文件夹的绝对路径，也可以填 16 位 session key。
    """

    static let disabledInstructions = "xuanpian 是本机「选片工具」的接口。这个服务器设了 LABELGUI_MCP_LIVE=0：只能看状态（app_status）、列已分析的场次（cull_list_sessions）、列拼图模板（collage_list_templates）；不连正在运行的 app，也不会启动它。"

    // MARK: - 解析、填名单

    private static let liveTools: [[String: Any]] = build(live: true)
    private static let disabledTools: [[String: Any]] = build(live: false)

    private static func build(live: Bool) -> [[String: Any]] {
        guard let defs = (try? JSONSerialization.jsonObject(with: Data(definitionsJSON.utf8))) as? [[String: Any]],
              let snippets = (try? JSONSerialization.jsonObject(with: Data(snippetsJSON.utf8))) as? [String: Any] else {
            fatalError("MCPToolDefs：工具定义的 JSON 坏了")  // 字面量写错是代码 bug，mcp_smoke / --mcp-selftest 第一时间就会红
        }
        var lists: [String: Any] = ["$STYLES": styleKeys, "$LOOKS": lookKeys, "$KITS": kitIDs]
        lists["$DEADLINE_30"] = deadline(defaultSec: 30)
        lists["$DEADLINE_50"] = deadline(defaultSec: 50)
        for (k, v) in snippets { lists["$" + k] = v }
        let categories = templateCategories
        let kitNames = CollageKitID.allCases.map { "\($0.rawValue) \($0.name)" }.joined(separator: " / ")
        var words: [String: String] = ["kits": kitNames, "categories": categories.joined(separator: "、")]
        words["template_count"] = String(CollageTemplates.builtin.count)
        words["category_count"] = String(categories.count)

        var out: [[String: Any]] = []
        for def in defs {
            let name = def["name"] as? String ?? ""
            if !live && !alwaysAvailable.contains(name) { continue }
            var d = def
            if let alt = d.removeValue(forKey: "description_disabled"), !live { d["description"] = alt }
            guard let filled = fill(d, lists: lists, words: words) as? [String: Any] else { continue }
            out.append(filled)
        }
        return out
    }

    /// deadline_seconds：范围 5 到 LABELGUI_MCP_DEADLINE_SEC（§10.2），默认值超过上限时按上限。
    private static func deadline(defaultSec: Int) -> [String: Any] {
        let cap = MCPConfig.deadlineCap
        let def = min(defaultSec, cap)
        var d: [String: Any] = ["type": "integer", "minimum": 5, "maximum": cap, "default": def]
        d["description"] = "这次调用最多等几秒（默认 \(def)）"
        return d
    }

    private static func fill(_ value: Any, lists: [String: Any], words: [String: String]) -> Any {
        switch value {
        case let s as String:
            if s.hasPrefix("$"), let replacement = lists[s] { return replacement }
            guard s.contains("{{") else { return s }
            var t = s
            for (k, v) in words { t = t.replacingOccurrences(of: "{{\(k)}}", with: v) }
            return t
        case let d as [String: Any]:
            return d.mapValues { fill($0, lists: lists, words: words) }
        case let a as [Any]:
            return a.map { fill($0, lists: lists, words: words) }
        default:
            return value
        }
    }

    // MARK: - 通用参数和注解（§3.0、§9.3）

    private static let snippetsJSON = #"""
    {
      "SESSION": {"type":"string","minLength":1,"maxLength":1024,"description":"照片文件夹的绝对路径，或 cull_list_sessions 返回的 16 位 session key"},
      "OP_ID": {"type":"string","minLength":8,"maxLength":64,"description":"上一次返回 app_outcome_unknown 时，用结果里的 op_id 原样再调"},
      "REVEAL": {"type":"boolean","default":false,"description":"true = 把 app 切到对应的 tab 给用户看（不会把 app 拉到前台）"},
      "REVEAL_SHOW": {"type":"boolean","default":true,"description":"true = 把 app 切到批量页给用户看（不会把 app 拉到前台）"},
      "IF_DIGEST": {"type":"string","maxLength":64,"description":"collage_get_state 返回的 digest；对不上说明用户刚改过，返回 stale_digest"},
      "INLINE": {"type":"boolean","default":true,"description":"false = 只返回文件路径，不内联图片"},
      "READ": {"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false},
      "WRITE_IDEMPOTENT": {"readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false},
      "WRITE": {"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false},
      "DESTRUCTIVE": {"readOnlyHint":false,"destructiveHint":true,"idempotentHint":true,"openWorldHint":false},
      "ALWAYS_LOAD": {"anthropic/alwaysLoad":true,"antigravity/alwaysLoad":true}
    }
    """#

    // MARK: - 18 个工具（顺序 = §10.1 表的 1–18）

    private static let definitionsJSON = #"""
    [
    {"name":"app_status","title":"状态自检",
     "description":"先调这个（call first）。返回服务器版本、数据目录、已分析的场次数、app 是否开着以及能不能实时操作（live.state：live 才能用读场次、改判、拼图这些要 app 的工具；not_running 时它们都回 app_not_running，MCP 不会替你启动 app）、app 当前打开的场次（live.open_session，其他工具的 session 参数都填它）和 tab、预览输出目录、各种上限（单次超时、图片预算、文字上限）。不读照片，很快。live 时下一步用 cull_session_overview。",
     "description_disabled":"先调这个（call first）。返回服务器版本、数据目录、已分析的场次数、预览输出目录和各种上限。这个服务器设了 LABELGUI_MCP_LIVE=0：不连正在运行的 app，也不会启动它；另外只能列场次（cull_list_sessions）和拼图模板（collage_list_templates）。不读照片，很快。",
     "inputSchema":{"type":"object","properties":{},"additionalProperties":false},
     "annotations":"$READ","_meta":"$ALWAYS_LOAD"},

    {"name":"cull_list_sessions","title":"列出已分析的场次",
     "description":"列出选片工具里已经分析过的拍摄场次（shoot/session，就是 app 侧栏「最近场次」里的，最多 15 场）：session key、照片文件夹、张数、最后分析时间、文件夹现在是否在线、是否在受系统隐私保护的位置、是不是 app 当前打开的那一场（open_in_app）。要读或改某一场，它必须是 app 当前打开的那一场，不是就 app_open_session（会清掉 app 里这一场的撤销记录，先问用户）。不能分析新文件夹，请用户在 app 里分析。",
     "description_disabled":"列出选片工具里已经分析过的拍摄场次（shoot/session，就是 app 侧栏「最近场次」里的，最多 15 场）：session key、照片文件夹、张数、最后分析时间、文件夹现在是否在线、是否在受系统隐私保护的位置。这个服务器设了 LABELGUI_MCP_LIVE=0，不连 app，只能列出来看。不能分析新文件夹，请用户在 app 里分析。",
     "inputSchema":{"type":"object","properties":{
       "limit":{"type":"integer","minimum":1,"maximum":100,"default":30,"description":"最多列几场"}},
      "additionalProperties":false},
     "annotations":"$READ","_meta":"$ALWAYS_LOAD"},

    {"name":"collage_list_templates","title":"拼图模板与成套",
     "description":"列出拼图和相册能用的东西：内置模板（现在 {{template_count}} 个，{{category_count}} 个分类：{{categories}}），每个模板的分类、照片格数、需要几张横图和竖图；一键成套 kits（{{kits}}）；样式 style、色调 look、画布 canvas。collage_apply_template 的 template、collage_run_kit 的 kit、collage_set_style 的 style/look 就取这里的值。",
     "description_disabled":"列出拼图和相册能用的东西：内置模板（现在 {{template_count}} 个，{{category_count}} 个分类：{{categories}}），每个模板的分类、照片格数、需要几张横图和竖图；一键成套 kits（{{kits}}）；样式 style、色调 look、画布 canvas。这个服务器设了 LABELGUI_MCP_LIVE=0，不连 app，只能列出来看。",
     "inputSchema":{"type":"object","properties":{
       "category":{"type":"string","maxLength":40,"description":"只列这个分类（或名字里含这几个字）的模板"},
       "include":{"type":"array","items":{"type":"string","enum":["templates","kits","styles","looks","canvases"]},"uniqueItems":true,"description":"只要这几部分，默认全部"}},
      "additionalProperties":false},
     "annotations":"$READ"},

    {"name":"cull_session_overview","title":"场次概览",
     "description":"app 当前打开的那一场的选片概览：精选/可用/废片（pick/usable/reject）各多少张、废片理由计数、当前阈值和放宽建议、章节列表和每章的计数、场（scene，按快门间隔切开的一串连拍）和近似重复组（near_duplicate）的统计、还没处理的场、多机身和对时偏移、警告、app 是否正在分析。读的是 app 内存里的状态（含还没存盘的改动），和窗口里看到的一致。要看具体照片用 cull_list_photos。",
     "inputSchema":{"type":"object","properties":{"session":"$SESSION"},"required":["session"],"additionalProperties":false},
     "annotations":"$READ"},

    {"name":"cull_list_photos","title":"列照片",
     "description":"按条件列出 app 当前打开的那一场里的照片，每张一行精简数据：id、判决、废片理由、拍摄时间（已加机身对时偏移）、章节、场和场内名次、近似重复组、锐度、曝光裁切、人脸质量、人脸数和闭眼数、是否人工改判。条件之间是 AND。分页：结果里有 next_cursor，原样传回 cursor 就是下一页；翻页中间判决变了会带 session_changed:true。要完整细节（EXIF、每张脸）用 cull_get_photos；要看图用 cull_preview_photos。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "verdict":{"type":"array","items":{"type":"string","enum":["pick","usable","reject"]},"uniqueItems":true,"description":"只列这些判决"},
       "reason":{"type":"string","maxLength":40,"description":"废片理由，取值见 cull_session_overview 的 reason_counts 键"},
       "chapter":{"type":"integer","minimum":0,"description":"只列这一章"},
       "scene":{"type":"integer","minimum":0,"description":"只列这一场"},
       "near_duplicate":{"type":"integer","minimum":0,"description":"只列这一个近似重复组"},
       "body":{"type":"string","maxLength":120,"description":"只列这台机身（型号或序列号）"},
       "manual_only":{"type":"boolean","default":false,"description":"只列人工改判过的"},
       "sort":{"type":"string","enum":["time","id","sharpness"],"default":"time"},
       "limit":{"type":"integer","minimum":1,"maximum":100,"default":50},
       "cursor":{"type":"string","maxLength":512,"description":"上一页结果里的 next_cursor，原样传回"}},
      "required":["session"],"additionalProperties":false},
     "annotations":"$READ"},

    {"name":"cull_get_photos","title":"照片详情",
     "description":"app 当前打开的那一场里 1–20 张照片的完整分析：判决和理由；原图路径；相机、机身、序列号；拍摄时间（原始的和对时后的）；EXIF（快门、光圈、ISO、等效焦距、镜头）；锐度、曝光裁切、人脸质量；每张脸的位置（bbox = [x0,y0,x1,y1]，0–1 归一化，左上角为原点，按 EXIF 转正后的画面，四边各外扩了 15%）、是否闭眼、眼睛开合度、面积占比；章节、场、名次、近似重复组；VLM 复审和申诉结果（有的话）；人工改判和客户选片标记。不存在的 id 列在 missing_ids。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "ids":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128},"minItems":1,"maxItems":20,"uniqueItems":true,"description":"照片 id（文件名去掉扩展名，比如 DSCF7208）"}},
      "required":["session","ids"],"additionalProperties":false},
     "annotations":"$READ"},

    {"name":"cull_list_groups","title":"分组",
     "description":"列出 app 当前打开的那一场里的分组和成员。chapter：章节，按时间断档分出来的大段落。scene：场，相邻间隔不超过 scene_gap 秒的一串连拍，也就是 app 里的「场」；组内有名次，#1 是推荐保留的那张。near_duplicate：近似重复，画面几乎一样的照片（phash）。每组给出成员 id、判决、名次、推荐的那张，以及这一场是否还没处理。审连拍时先用它找组，再用 cull_preview_photos 看（一次最多 4 张）。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "kind":{"type":"string","enum":["chapter","scene","near_duplicate"]},
       "min_size":{"type":"integer","minimum":1,"maximum":100,"default":2,"description":"只列至少这么多张的组"},
       "limit":{"type":"integer","minimum":1,"maximum":100,"default":30},
       "cursor":{"type":"string","maxLength":512,"description":"上一页结果里的 next_cursor，原样传回"}},
      "required":["session","kind"],"additionalProperties":false},
     "annotations":"$READ"},

    {"name":"cull_preview_photos","title":"看照片",
     "description":"看 app 当前打开的那一场里 1–4 张照片的缩小预览（内联图片），用来判断表情、闭眼、对焦、构图。图由 app 出：crop=full 是整张；crop=face 是从原图按主脸裁一块放大，和 app 连拍挑选里的放大是同一个算法，看眼睛和对焦用它（照片在受系统隐私保护的位置时只在 1024 预览上裁，细节有限）。一张时长边默认 1024，多张时每张 768，max_edge 可以在 256–1568 之间调。文字结果里有每张预览文件（存在预览输出目录里）和原图的绝对路径；inline:false 只给路径、不内联图片。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "ids":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128},"minItems":1,"maxItems":4,"uniqueItems":true,"description":"照片 id（文件名去掉扩展名，比如 DSCF7208）"},
       "crop":{"type":"string","enum":["full","face"],"default":"full"},
       "max_edge":{"type":"integer","minimum":256,"maximum":1568,"description":"长边像素；默认一张 1024、多张每张 768"},
       "inline":"$INLINE",
       "deadline_seconds":"$DEADLINE_30"},
      "required":["session","ids"],"additionalProperties":false},
     "annotations":"$READ"},

    {"name":"collage_get_state","title":"看 app 里的拼图",
     "description":"看 app 里当前拼图工程的状态（读的是 app 内存，含还没存盘的改动）：模式、页码和页数、模板、样式、色调、标题/副标题/刊头/期号、托盘张数、每个格子（path、照片 id、文字块数）、选中的格子、撤销深度（最上面那一步是不是 AI 做的）、是否还在算、digest（拼图写工具的 if_digest 就填它），后面跟一张 app 当前画面的预览图。session 不填就是 app 当前打开的那一场；填了别的场次回 session_not_open。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "include_preview":{"type":"boolean","default":true,"description":"要不要带 app 当前画面的预览图"},
       "max_edge":{"type":"integer","minimum":256,"maximum":1024,"default":768,"description":"预览图长边像素"},
       "inline":"$INLINE"},
      "additionalProperties":false},
     "annotations":"$READ"},

    {"name":"app_open_session","title":"在 app 里打开场次",
     "description":"让 app 打开另一场（= 侧栏「最近场次」里点它），之后其他工具就读写这一场。只能打开 cull_list_sessions 列出来的场次；照片在桌面、文稿、下载、外置盘等受系统隐私保护位置的场次回 protected_location，请用户自己在 app 里点开。切场次会清掉 app 里这一场的判决和拼图撤销记录：撤销栈不空时先回 confirm_required（data 里有会清掉几步），问过用户再带 confirm:true 调。app 正在分析时回 analysis_running。不会把 app 拉到前台。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "confirm":{"type":"boolean","default":false,"description":"用户已经同意清掉 app 里这一场的撤销记录"},
       "reveal":"$REVEAL",
       "op_id":"$OP_ID"},
      "required":["session"],"additionalProperties":false},
     "annotations":"$DESTRUCTIVE"},

    {"name":"cull_set_verdicts","title":"改判",
     "description":"在 app 里改判（= 网格里按 1/2/3/0）：pick 精选、usable 可用、reject 废片、auto 恢复自动判决。用户在窗口里当场看到；一次调用是一步撤销，用户按 ⌘Z 能撤，也可以 app_undo target=verdicts。已经是这个判决的照片不动（列在 unchanged）。连拍挑选开着时回 user_busy，app 正在分析时回 analysis_running。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "ids":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128},"minItems":1,"maxItems":500,"uniqueItems":true,"description":"照片 id（文件名去掉扩展名，比如 DSCF7208）"},
       "verdict":{"type":"string","enum":["pick","usable","reject","auto"]},
       "reveal":"$REVEAL",
       "op_id":"$OP_ID"},
      "required":["session","ids","verdict"],"additionalProperties":false},
     "annotations":"$WRITE_IDEMPOTENT"},

    {"name":"cull_show_photos","title":"在 app 里定位照片",
     "description":"在 app 里把这些照片指给用户看（= 点选、⌘ 点选）：mode=select 选中它们、焦点落到第一张，mode=focus 只把焦点移到第一张；网格滚到那里。只改视图：不改判决、不进撤销，也不改用户的筛选（被筛选藏起来的列在 hidden_by_filter）。reveal 默认 true，切到批量页给用户看（不会把 app 拉到前台）。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "ids":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128},"minItems":1,"maxItems":200,"uniqueItems":true,"description":"照片 id（文件名去掉扩展名，比如 DSCF7208）"},
       "mode":{"type":"string","enum":["select","focus"],"default":"select"},
       "reveal":"$REVEAL_SHOW"},
      "required":["session","ids"],"additionalProperties":false},
     "annotations":"$WRITE_IDEMPOTENT"},

    {"name":"collage_apply_template","title":"套模板",
     "description":"给 app 里当前的拼图套一个模板（= 检视器里点模板），画布当场换版式。template 可以写模板全名、分类名（套这个分类的第一个）或名字里的几个字，取值见 collage_list_templates。一次调用是一步撤销（拼图页 ⌘Z，或 app_undo target=collage）。结果里有 app 当前画面的预览图。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "template":{"type":"string","minLength":1,"maxLength":80,"description":"模板全名、分类名或名字里的几个字"},
       "if_digest":"$IF_DIGEST",
       "reveal":"$REVEAL",
       "op_id":"$OP_ID",
       "inline":"$INLINE"},
      "required":["session","template"],"additionalProperties":false},
     "annotations":"$WRITE_IDEMPOTENT"},

    {"name":"collage_run_kit","title":"在 app 里一键成套",
     "description":"在 app 里一键成套（= 拼图页「一键成套 ▾」）：{{kits}}。替换当前拼图工程，落地时是一步撤销。要等 app 算完（最长约 50 秒）；被用户的新操作作废或用户切了场次回 superseded，托盘里没有能用的照片回 nothing_to_render。结果里有页数、封面和 app 当前画面的预览图。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "kit":{"type":"string","enum":"$KITS"},
       "if_digest":"$IF_DIGEST",
       "reveal":"$REVEAL",
       "op_id":"$OP_ID",
       "deadline_seconds":"$DEADLINE_50",
       "inline":"$INLINE"},
      "required":["session","kit"],"additionalProperties":false},
     "annotations":"$WRITE"},

    {"name":"collage_next_cover","title":"换封面",
     "description":"「出一期」换下一张封面（= 拼图页「换封面」），steps 是往后换几张。当前拼图不是 collage_run_kit kit=fashionIssue 出来的回 invalid_state。落地时是一步撤销；被用户的新操作作废回 superseded。结果里有 app 当前画面的预览图。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "steps":{"type":"integer","minimum":1,"maximum":20,"default":1,"description":"往后换几张"},
       "if_digest":"$IF_DIGEST",
       "reveal":"$REVEAL",
       "op_id":"$OP_ID",
       "deadline_seconds":"$DEADLINE_50",
       "inline":"$INLINE"},
      "required":["session"],"additionalProperties":false},
     "annotations":"$WRITE"},

    {"name":"collage_set_text","title":"改标题/刊头/期号/文字",
     "description":"改 app 里当前拼图的文字（= 检视器「文字」页）：title 标题、subtitle 副标题、masthead 刊头、issue 期号；cell_text 改某个格子里第 index 个字块的第一行，必须同时带 if_digest（用户改过版式以后格子下标会指错地方）。至少给一个字段，文字里可以有逗号；不管改几个字段都是一步撤销。用户正在输入框里打字时回 user_busy。结果里有 app 当前画面的预览图。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "title":{"type":"string","maxLength":60},
       "subtitle":{"type":"string","maxLength":120},
       "masthead":{"type":"string","maxLength":40},
       "issue":{"type":"string","maxLength":20},
       "cell_text":{"type":"object","properties":{
         "path":{"type":"string","maxLength":8,"pattern":"^[0-9]{0,8}$","description":"格子路径，collage_get_state 的 cells[].path"},
         "index":{"type":"integer","minimum":0,"description":"这个格子里第几个字块（从 0 开始）"},
         "text":{"type":"string","description":"新的第一行"}},
        "required":["path","index","text"],"additionalProperties":false},
       "if_digest":"$IF_DIGEST",
       "reveal":"$REVEAL",
       "op_id":"$OP_ID",
       "inline":"$INLINE"},
      "required":["session"],"additionalProperties":false},
     "annotations":"$WRITE_IDEMPOTENT"},

    {"name":"collage_set_style","title":"换样式/色调",
     "description":"换 app 里当前拼图的样式和色调（= 检视器样式页点预设）：style 是整套「纸、缝、边、框」的预设，look 是整组照片统一的色调，look_strength 是色调强度 0–1。至少给一个；一次调用是一步撤销。和界面一样，换样式也会改「下次新建拼图沿用的默认样式」。取值见 collage_list_templates。结果里有 app 当前画面的预览图。",
     "inputSchema":{"type":"object","properties":{
       "session":"$SESSION",
       "style":{"type":"string","enum":"$STYLES"},
       "look":{"type":"string","enum":"$LOOKS"},
       "look_strength":{"type":"number","minimum":0,"maximum":1},
       "if_digest":"$IF_DIGEST",
       "reveal":"$REVEAL",
       "op_id":"$OP_ID",
       "inline":"$INLINE"},
      "required":["session"],"additionalProperties":false},
     "annotations":"$WRITE_IDEMPOTENT"},

    {"name":"app_undo","title":"撤销 AI 刚做的一步",
     "description":"在 app 里撤销 AI 自己刚做的那一步（用户自己的改动不会被撤）。target 必填，因为撤销按页分开：verdicts 撤判决，collage 撤拼图。只在那一步还在撤销栈顶时撤：用户之后又改过回 undo_not_ours（请用户自己在 app 里 ⌘Z），已经撤过或切过场次回 nothing_to_undo。",
     "inputSchema":{"type":"object","properties":{
       "target":{"type":"string","enum":["verdicts","collage"]},
       "session":"$SESSION",
       "op_id":"$OP_ID"},
      "required":["target"],"additionalProperties":false},
     "annotations":"$WRITE"}
    ]
    """#
}
