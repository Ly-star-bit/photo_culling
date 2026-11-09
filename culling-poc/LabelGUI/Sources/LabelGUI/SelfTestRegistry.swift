import Foundation

/// 自检登记表（优化分析 NE8）：每条 `--*-selftest` / `--*-probe` 只在这里登记一次 —— 参数、一句说明、在 main.swift 的哪一段分派、
/// 入口、CI 怎么跑。从它来的：
///   - `AppRuntime.headlessFlags`（认出无头、NoGUIGate 认拼错的参数、启动门控不拦）；
///   - main.swift 的分派：`SelfTestRegistry.dispatch(.beforeDataDir)`、`.dispatch(.afterSetup)` 两处，都在 `LabelGUIApp.main()` 之前；
///   - Scripts/selftests.sh 跑哪些、按什么先后、带什么参数（`LabelGUI --list-selftests` 打印这张表），和它最后「CI 登记」核对的清单。
/// 以前加一条自检要改 AppRuntime.headlessFlags、main.swift 的分派、selftests.sh 的 run 行和说明（有的还要改 ELSEWHERE 表），
/// 并行车道合并时手工冲突大半出在这几处。
///
/// 以后加一条自检，只改这里：在 `all` 里加一行（自检本身的代码照旧写在自己的文件里）。
///   - 入口是 `(flagIndex) -> Never`：自检自己 exit，编译期就保证跑完走不到开界面那一句。
///   - 不要照片、不读写真实数据的：`ci: .selftests()`，selftests.sh 按这张表的先后跑，脚本不用改。要参数就写上：
///     `{fixture}` 换成 Fixtures/photot-session，`{seed}` 按 SELFTEST_SEEDS 每个跑一遍。
///   - 在别的回归脚本里跑的：`.elsewhere("xxx.py")`（那个脚本里要有这个参数的字面量、release.yml 里要有那一步）；
///     CI 跑不了的：`.notInCI("为什么")`。selftests.sh 最后的「CI 登记」都核对。
///   - 不经这张表、直接往 main.swift（或别的文件）里写一个 --xxx-selftest 的分派：Sources 里出现了表里没有的
///     带引号的 --…-selftest / --…-probe 字面量，「CI 登记」红。
enum SelfTestRegistry {
    /// 在 main.swift 的哪一段分派。
    enum Stage: Sendable {
        /// 建数据目录、同步运行时、注册字体之前（还什么都没写）：纯函数、只读的。在钉 batch.* 设置之后。
        case beforeDataDir
        /// 数据目录、内置字体、appConfig 都备好以后，在任何别的无头命令之前。
        case afterSetup
    }

    /// CI 怎么跑。
    enum CI: Sendable {
        /// Scripts/selftests.sh 跑，参数照写（`{fixture}`、`{seed}` 见上面）。
        case selftests(_ args: [String] = [])
        /// 在 Scripts/ 下这个回归脚本里跑。
        case elsewhere(_ script: String)
        /// CI 不跑，写清为什么。
        case notInCI(_ reason: String)
    }

    struct Entry: Sendable {
        let flag: String
        let summary: String
        let stage: Stage
        /// 参数后面至少要跟几个位置参数才分派；不够就照旧往下走（最后被「不认识的参数」挡下，退出码 2）。
        let minArgs: Int
        let ci: CI
        let run: @MainActor @Sendable (_ flagIndex: Int) -> Never

        init(_ flag: String, _ summary: String, stage: Stage = .afterSetup, minArgs: Int = 0, ci: CI,
             run: @escaping @MainActor @Sendable (_ flagIndex: Int) -> Never) {
            self.flag = flag
            self.summary = summary
            self.stage = stage
            self.minArgs = minArgs
            self.ci = ci
            self.run = run
        }
    }

    /// 打印这张表（selftests.sh 用）：不建数据目录、不读写任何文件。
    static let listFlag = "--list-selftests"

    /// 先后 = selftests.sh 跑的先后；同一段里命令行同时带两条自检时，排在前面的那条先跑（跑完就退出）。
    static let all: [Entry] = [
        .init("--ux-selftest", "网格改判后焦点落在哪（BatchView.placeAfterChange）；另挂 EXIF 快门 0、网格多选规则、水印页 RAW+JPG 配对、拼图检视器的去那儿、这一版新增",
              ci: .selftests()) { _ in UXSelfTest.run() },
        .init("--timeline-selftest", "时间轴 3000 组随机章节不出界、不重叠；随机数按 seed 播种（--seed N 或 LABELGUI_SELFTEST_SEED，--trial K 只重跑那一组），CI 跑三个 seed（三批互不相同的 3000 组，自检开头核对）",
              ci: .selftests(["--seed", "{seed}"])) { _ in ChapterTimelineSelfTest.runFromCommandLine() },
        .init("--swiss-selftest", "瑞士风版式规则（完全不收照片参数）",
              ci: .selftests()) { _ in CollageSwissSelfTest.run() },
        .init("--minimal-selftest", "留白杂志模板（[photo_dir]；不给照片文件夹时只验合成数据）",
              ci: .selftests()) { i in CollageStyleMinimalSelfTest.run(flagIndex: i) },
        .init("--mask-selftest", "主体蒙版 / 人物挡字（[photo_dir]；不给照片文件夹时只验合成数据）",
              ci: .selftests()) { i in CollageMaskSelfTest.run(flagIndex: i) },
        .init("--album-selftest", "婚礼相册 fine-art 编排（[<photo_dir> --out <dir>]；不给照片文件夹时只验合成数据）",
              ci: .selftests()) { i in CollageStyleFineArtSelfTest.run(flagIndex: i) },
        .init("--fashion-selftest", "时尚刊：挑主图、出一期、换封面、文案商标、字块不重叠（[photo_dir]；不给照片文件夹时只验合成数据）",
              ci: .selftests()) { i in CollageStyleFashionSelfTest.run(flagIndex: i) },
        .init("--newspaper-selftest", "报纸风（[photo_dir]；不给照片文件夹时只验合成数据）",
              ci: .selftests()) { i in CollageStyleNewspaperSelfTest.run(flagIndex: i) },
        .init("--delivery-selftest", "交付环节的数据安全：XMP 归属 / 合并、同名另存 -2、截断 JPEG、同一个文件、两条去 GPS（端到端在 Scripts/delivery_regression.py）",
              ci: .selftests()) { _ in DeliverySelfTest.run() },
        .init("--session-move-selftest", "挪了的文件夹认得回来：同卷改名 / 拷贝不认 / 重新定位 / 实时桥不跟书签（造假的拍摄、真改名）",
              ci: .selftests()) { _ in SessionMoveSelfTest.run() },
        .init("--quit-selftest", "长任务和退出：VLM 的 uv、python 子进程整组停掉（假的 uv）、阈值防抖写掉、防闲置睡眠、⌘Q 确认的判断表和「停下并退出」流程",
              ci: .selftests()) { _ in QuitSelfTest.run() },
        .init("--diag-selftest", "诊断：状态栏提示历史、日志轮转、诊断包里没有照片和客户原话、逐张失败的原因、文件夹没权限（端到端在 Scripts/diag_regression.py）",
              ci: .selftests()) { _ in DiagnosticsSelfTest.run() },
        .init("--followup-selftest", "跟进小修：写盘失败报给 MCP（persisted / save_failed）、水印页按客户选中导入、复制原片连续失败就停……",
              ci: .selftests()) { _ in FollowupSelfTest.run() },
        .init("--persist-selftest", "场次持久化：删场次留判决、坏文件挪开不盖、读不了的拒绝切场次、写盘失败看得见（<Fixtures/photot-session>）",
              minArgs: 1, ci: .selftests(["{fixture}"])) { i in PersistSelfTest.run(flagIndex: i) },
        .init("--cull-mcp-selftest", "选片 MCP 在真的 BatchStore 上：XMP 待更新、导入客户选择、AI 改判的出处、一次定一场（<Fixtures/photot-session>，要空的数据目录）",
              ci: .selftests(["{fixture}"])) { i in CullMCPSelfTest.run(flagIndex: i) },
        .init("--files-selftest", "文件安全：XMP 只写改了的、同名共用 .xmp、废片避开拼图、高 ISO RAW 复制不互相顶掉",
              ci: .selftests()) { _ in FileSafetySelfTest.run() },
        .init("--collage-export-selftest", "拼图 / 相册导出：PDF 先写临时文件再改名、缺跨页不出 PDF、空照片格先确认",
              ci: .selftests()) { _ in CollageExportSelfTest.run() },
        .init("--proof-selftest", "选片确认表页面脚本（JavaScriptCore）：套餐张数、每张备注、复制的文字、客户回复里的备注、确认表水印；不读写数据目录",
              stage: .beforeDataDir, ci: .selftests()) { _ in ProofSheetSelfTest.run() },
        .init("--film-looks-selftest", "光谱胶片色调的表：读得到（裸二进制往上找 third_party/film-luts，.app 里只读包里那份）、名字不带品牌、GPU 和 CPU 同色",
              ci: .selftests()) { _ in CollageFilmLooksSelfTest.run() },
        .init("--darkroom-selftest", "暗房：悬停只预览、整组 / 这一页 / 这一格各改各的、强度、颗粒晕光、←→、原图、撤销；1:1 细节只渲那一块和渲整页再裁逐字节相同",
              ci: .selftests()) { _ in CollageDarkroomSelfTest.run() },
        .init("--mcp-selftest", "MCP 这一层的纯函数（含不开界面那道闸的判断表）：不起服务器、不读写任何文件（[--json]）",
              stage: .beforeDataDir, ci: .elsewhere("mcp_smoke.py")) { _ in MCPSelfTest.run() },
        .init("--card-queue-selftest", "存储卡排队：两张假卡走确认 / 排队 / 停下分析，看都导全了、分析在最后跑一次（<cardA> <cardB> --dest <dir>）",
              minArgs: 2, ci: .elsewhere("card_import_regression.py")) { i in CardImportQueueSelftest.run(flagIndex: i) },
        .init("--launch-gate-probe", "GUI 启动门控的探锁、认人走一遍，只打印结论、不弹框（[--budget-ms N]）；只读，不建目录",
              stage: .beforeDataDir, ci: .elsewhere("cli_guard_regression.py")) { _ in LaunchGate.runProbe() },
        .init("--film-selftest", "底片印样：按卷出印样、合成帧（<photo_dir> [--out 目录]）",
              ci: .notInCI("要先分析过的真照片（按卷出印样、合成帧都从真的像素来），Fixtures 里只有 JSON")) { i in
            CollageStyleFilmSelfTest.run(flagIndex: i)
        },
    ]

    /// 登记表带来的无头参数（AppRuntime.headlessFlags 并上它）。
    static var flags: Set<String> { Set(all.map(\.flag)).union([listFlag]) }

    /// main.swift 在两处调：命令行里有这一段的自检就跑（跑完自己 exit），没有就原样返回。
    @MainActor
    static func dispatch(_ stage: Stage, args: [String] = CommandLine.arguments) {
        if stage == .beforeDataDir, args.contains(listFlag) { printList() }
        for entry in all where entry.stage == stage {
            guard let i = args.firstIndex(of: entry.flag), args.count > i + entry.minArgs else { continue }
            entry.run(i)
        }
    }

    /// `LabelGUI --list-selftests`：一条一行，tab 分开四列 —— 参数、CI 怎么跑（selftests.sh / 回归脚本名 / none）、
    /// selftests.sh 给的参数（没有 = -）、说明（none 的再带一列为什么不跑）。# 开头的是表头。
    static func printList() -> Never {
        var lines = ["# flag\tci\targs\tsummary\t[why not in CI]"]
        for entry in all {
            let row: [String]
            switch entry.ci {
            case .selftests(let args):
                row = [entry.flag, "selftests.sh", args.isEmpty ? "-" : args.joined(separator: " "), entry.summary]
            case .elsewhere(let script):
                row = [entry.flag, script, "-", entry.summary]
            case .notInCI(let reason):
                row = [entry.flag, "none", "-", entry.summary, reason]
            }
            lines.append(row.joined(separator: "\t"))
        }
        print(lines.joined(separator: "\n"))
        exit(0)
    }
}

// MARK: - 原来直接写在 main.swift 里的两条

/// 网格「改判后保持位置」自检（另外几组纯函数的也挂在这里）：LabelGUI --ux-selftest。
enum UXSelfTest {
    @MainActor
    static func run() -> Never {
        // (说明, 改判前顺序, 改判后顺序, 焦点那张, 期望新焦点 / nil = 不动)
        let cases: [(String, [String], [String], String, String?)] = [
            ("精选区里按 3：跳到废片区 → 焦点落到原来的下一张", ["p1", "p2", "p3", "u1", "r1"], ["p1", "p3", "u1", "r1", "p2"], "p2", "p3"),
            ("分组行里按 2：位置没变 → 不动", ["a1", "a2", "a3", "b1"], ["a1", "a2", "a3", "b1"], "a2", nil),
            ("定完一场被叠起来：这张藏了 → 下一场第一张", ["a1", "a2", "b1", "b2"], ["a1", "b1", "b2"], "a2", "b1"),
            ("只看精选时废掉最后一张 → 往前找", ["p1", "p2", "p3"], ["p1", "p2"], "p3", "p2"),
            ("唯一一张被筛掉 → 没得落", ["p1"], [], "p1", nil),
            ("这张前后的邻居变了（排序挪动）→ 落到原来的下一张", ["p1", "u1", "u2", "u3"], ["p1", "u2", "u1", "u3"], "u1", "u2"),
            ("同一场里别的照片被叠掉、它自己没动 → 不动", ["a", "r", "b", "c1"], ["a", "b", "c1"], "b", nil),
            ("按 0 让定完的场重新展开、废片冒出来围着它 → 不动", ["k", "n1"], ["r1", "k", "r2", "n1"], "k", nil),
        ]
        var failed = 0
        for (name, before, after, id, expected) in cases {
            let got = BatchView.placeAfterChange(of: id, before: before, after: after)
            let ok = got == expected
            if !ok { failed += 1 }
            // 拆开拼：一长串 + 和三元在 CI 的 Xcode 16 上类型检查会慢。
            let head: String = ok ? "PASS " : "FAIL "
            let result: String = got ?? "不动"
            let want: String = ok ? "" : "（期望 \(expected ?? "不动")）"
            print(head + name + " → " + result + want)
        }
        failed += GridExifImportSelfTest.run()  // EXIF 快门 0 不崩、网格多选规则、水印页 RAW+JPG 配对
        failed += CollageNavSelfTest.run()      // 拼图检视器重排：去那儿（页签、滚动请求）、--tab 新老名字、色调两节
        failed += WhatsNewSelfTest.run()        // 这一版新增：版本号、弹不弹、记账只写独立的 suite、数据表
        exit(failed == 0 ? 0 : 1)
    }
}

extension ChapterTimelineSelfTest {
    /// 时间轴布局自检：LabelGUI --timeline-selftest [--seed N] [--trial K]（随机章节数/张数/宽度，验证不出界、不重叠）。
    /// 随机数按 seed 播种（--seed，或环境变量 LABELGUI_SELFTEST_SEED；都没给 = 1），同一个 seed 每次跑的都是同样的 3000 组；
    /// FAIL 行带 seed 和 trial，--trial 只重跑那一组。CI（Scripts/selftests.sh）固定跑几个 seed。
    @MainActor
    static func runFromCommandLine(_ args: [String] = CommandLine.arguments) -> Never {
        func number<T: FixedWidthInteger>(_ flag: String, _ env: String?) -> T? {
            let raw: String?
            if let i = args.firstIndex(of: flag) {
                raw = args.count > i + 1 ? args[i + 1] : ""
            } else {
                raw = env.flatMap { ProcessInfo.processInfo.environment[$0] }
            }
            guard let raw else { return nil }
            // 写错了直接退出：悄悄退回默认 seed，以为在复现的其实是另一组。
            guard let value = T(raw) else {
                print("--timeline-selftest：\(flag) 要一个非负整数，拿到的是「\(raw)」")
                exit(2)
            }
            return value
        }
        let seed: UInt64 = number("--seed", "LABELGUI_SELFTEST_SEED") ?? 1
        let trial: UInt32? = number("--trial", nil)
        run(seed: seed, onlyTrial: trial.map { Int($0) })
    }
}
