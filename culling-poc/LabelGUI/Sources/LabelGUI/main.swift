import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// 给 AI 用的 MCP（--mcp / --mcp-call / --mcp-tools，见 MCP/MCPServerMain.swift）：第一条可执行语句就接管 stdio。
// 之后 print、NSLog、C 的 stdio 都落到 stderr，协议走私有 fd，任何共用代码打印的东西都混不进 JSON-RPC。
let mcpFDs: StdioTakeover.FDs? = MCPServerMain.mode(CommandLine.arguments) != nil ? StdioTakeover.takeOver() : nil

/// Analysis artifacts (previews, manifest/layer JSONs, labels.csv, settings.json)
/// live in Application Support — always writable by the app, no TCC prompt, works
/// when launched from /Applications, independent of username.
/// 这里只算路径，不建目录（ensureAppDataDir 建）：main.swift 的顶层全局量执行到这一行就求值，
/// 以前在这里建目录，任何启动方式（--mcp、写错参数被挡下的）都会在从没开过 app 的机器上建出数据目录。
let appDataDir: URL = {
    // CI 的无头回归用临时目录，别碰 runner 上的 Application Support。
    if let override = ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("选片工具")
}()

/// 建数据目录（以前 appDataDir 初始化时顺手建的那两处）。MCP 的入口和不开界面的闸都在它前面：它们不往这里写一个字节。
func ensureAppDataDir() {
    try? FileManager.default.createDirectory(at: appDataDir, withIntermediateDirectories: true)
}

/// The Python pipeline (layer2.py etc.) ships INSIDE the app bundle
/// (Contents/Resources/culling-poc) and is synced to App Support on every
/// launch. Two reasons: uv needs to create .venv beside the scripts and the
/// signed bundle is read-only; and scripts must never version-skew from the
/// app again (new app + stale runtime once broke --backend).
func syncEmbeddedPipeline(to dataDir: URL) {
    let fm = FileManager.default
    guard let embedded = Bundle.main.resourceURL?.appendingPathComponent("culling-poc"),
          fm.fileExists(atPath: embedded.path) else { return }  // bare dev binary: keep using the checkout
    let dest = dataDir.appendingPathComponent("runtime/culling-poc")
    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
    // Replace everything except .venv — uv's environment survives app updates
    // and gets reconciled by uv itself when the lockfile changed.
    if let stale = try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil) {
        for url in stale where url.lastPathComponent != ".venv" {
            try? fm.removeItem(at: url)
        }
    }
    if let fresh = try? fm.contentsOfDirectory(at: embedded, includingPropertiesForKeys: nil) {
        for url in fresh {
            try? fm.copyItem(at: url, to: dest.appendingPathComponent(url.lastPathComponent))
        }
    }
}

// 无头参数在任何分派之前认出来：之后走到的共用代码（导出完「在访达里显示」之类）一律不弹界面。
AppRuntime.headless = CommandLine.arguments.contains { AppRuntime.headlessFlags.contains($0) }

// 不开界面的第一道闸（见 MCP/NoGUIGate.swift）：拼错的无头参数、LABELGUI_NO_GUI=1 却没有无头参数、
// 像是被 MCP 客户端起的（父进程不是 launchd、stdin 不是终端）都在这里退出 —— 还什么都没写。
NoGUIGate.early()

// MCP 的三个入口：不建数据目录、不同步 Python 运行时、不注册字体，对数据目录只读（DESIGN §10.0、§10.5）。永不返回。
if let mcpMode = MCPServerMain.mode(CommandLine.arguments), let mcpFDs {
    MCPServerMain.run(mcpMode, fds: mcpFDs)
}
// MCP 这一层纯函数的自检（含不开界面那道闸的判断表）：LabelGUI --mcp-selftest [--json]，不读写任何文件。
if CommandLine.arguments.contains("--mcp-selftest") {
    MCPSelfTest.run()
}

// --app-ui、--live-host 是测试宿主：整套 store 都会写数据目录，所以 LABELGUI_DATA_DIR 没设、或者指到真实数据目录的，
// 在建目录、注册字体之前就退出（它们自己的分派里还会再查一遍，那时已经晚了）。不跑 Python，不同步运行时（§9.7、§10.5）；
// 字体照常注册（要渲染）。
let testHostFlag: String? = CommandLine.arguments.contains("--live-host") ? "--live-host"
    : CommandLine.arguments.contains("--app-ui") ? "--app-ui" : nil
if let testHostFlag {
    CollageCLI.requireIsolatedDataDir(testHostFlag)
    AppUISnapshot.requireNotRealDataDir(testHostFlag)
}
ensureAppDataDir()
if testHostFlag == nil {
    syncEmbeddedPipeline(to: appDataDir)
}
// 内置字体（报纸风刊头的哥特体）进本进程的字体表：按名字找字体的地方也认得它（见 CollageEmbeddedFonts）。
CollageEmbeddedFonts.registerForProcess(in: appDataDir)

let appConfig = AppConfig.load(from: appDataDir)

// Headless mode for testing/automation: LabelGUI --analyze <photo_dir>
// runs the native engine and exits without launching the window.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--analyze"),
   CommandLine.arguments.count > flagIndex + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    do {
        let start = Date()
        // Same per-shoot session dir the GUI uses, so headless runs show up there.
        let sessionDir = appDataDir.appendingPathComponent("sessions/\(BatchStore.sessionKey(for: dir))")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        // 界面上是先打开文件夹（这时定下这一场的阈值）再分析；这里不先定的话，分析完再打开会被当成老场次。
        BatchStore.sessionThresholds(sessionDir: sessionDir, dataDir: appDataDir)
        let summary = try AnalysisEngine.analyzeFolder(dir, dataDir: sessionDir) { message in
            print(message)
        }
        // 登记到 sessions.json：否则下次 GUI 分析任何文件夹时，
        // pruneOrphanedSessions 会把这次跑出来的预览清掉。
        BatchStore.registerSession(dataDir: appDataDir, folder: dir,
                                   photoCount: summary.analyzed + summary.reused)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "Done: %d analyzed, %d reused in %.1fs (%.2fs/photo)",
                     summary.analyzed, summary.reused, elapsed, elapsed / Double(max(1, summary.analyzed))))
        if !summary.failed.isEmpty {
            print("Failed (\(summary.failed.count)): \(summary.failed.joined(separator: ", "))")
        }
        if !summary.corrupt.isEmpty {
            print("Corrupt (\(summary.corrupt.count)): \(summary.corrupt.joined(separator: ", "))")
        }
        print("Artifacts: \(sessionDir.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("analyze failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless watermark smoke test:
// LabelGUI --watermark <photo> <out.jpg> [signature.png] [--config <config.json>]
// Renders with EXIF text + frame enabled so the whole pipeline gets exercised.
// --config：一份 WatermarkEngine.Config 的 JSON（文件路径，或以 { 开头的 JSON 原文），
// 从 Config() 默认值起逐字段宽松解码，不再叠加上面那套硬编码；同一份 JSON 里的
// maxLongSide/quality 等导出选项也认（ExportOptions 同样宽松解码）。回归逐字节对比用。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--watermark"),
   CommandLine.arguments.count > flagIndex + 2 {
    let args = CommandLine.arguments
    let photo = URL(fileURLWithPath: args[flagIndex + 1])
    let out = URL(fileURLWithPath: args[flagIndex + 2])
    var signature: CGImage?
    // 第三个位置参数是 --config 之类的开关时，没有签名。
    if args.count > flagIndex + 3, !args[flagIndex + 3].hasPrefix("--") {
        let sigURL = URL(fileURLWithPath: args[flagIndex + 3])
        if let src = CGImageSourceCreateWithURL(sigURL as CFURL, nil) {
            signature = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
    }
    var config = WatermarkEngine.Config()
    var options = WatermarkEngine.ExportOptions()
    if let configIndex = args.firstIndex(of: "--config"), args.count > configIndex + 1 {
        let arg = args[configIndex + 1]
        let data = arg.hasPrefix("{") ? Data(arg.utf8) : try? Data(contentsOf: URL(fileURLWithPath: arg))
        // 读不了 / 不是 JSON 对象就直接失败：悄悄退回默认配置会让对比测试空跑通过。
        guard let data, let decoded = try? JSONDecoder().decode(WatermarkEngine.Config.self, from: data) else {
            FileHandle.standardError.write("watermark: --config 读不了：\(arg)\n".data(using: .utf8)!)
            exit(1)
        }
        config = decoded
        options = (try? JSONDecoder().decode(WatermarkEngine.ExportOptions.self, from: data)) ?? options
    } else {
        config.tintEnabled = true
        config.tint = .white
        config.exifText.enabled = true
        config.frame.enabled = true
    }
    let ok = WatermarkEngine.exportPhoto(source: photo, to: out, signature: signature,
                                         config: config, options: options)
    print(ok ? "watermark OK: \(out.path)" : "watermark FAILED")
    exit(ok ? 0 : 1)
}

// 存储卡导入确认框离屏快照：LabelGUI --card-ui <card_dir> <out.png> --dest <dir> [--reimport] [--running]
if let flagIndex = CommandLine.arguments.firstIndex(of: "--card-ui"),
   CommandLine.arguments.count > flagIndex + 2 {
    MainActor.assumeIsolated {
        CardImportSnapshot.run(flagIndex: flagIndex)
    }
}

// 存储卡排队自检：两张假卡走 CardImportCenter 的确认 / 排队 / 停下分析，看都导全了、分析在最后跑一次。
// LABELGUI_DATA_DIR=<临时> LabelGUI --card-queue-selftest <cardA> <cardB> --dest <dir>
if let flagIndex = CommandLine.arguments.firstIndex(of: "--card-queue-selftest"),
   CommandLine.arguments.count > flagIndex + 2 {
    MainActor.assumeIsolated {
        CardImportQueueSelftest.run(flagIndex: flagIndex)
    }
}

// 存储卡导入无头测试（账本在 LABELGUI_DATA_DIR，目标必须用 --dest 给）：
// LabelGUI --ingest <card_dir> --dest <dir> [--reimport] [--plan-only] [--cancel-after N]
if let flagIndex = CommandLine.arguments.firstIndex(of: "--ingest"),
   CommandLine.arguments.count > flagIndex + 1 {
    CardImportCLI.run(flagIndex: flagIndex)
}

// LabelGUI --session-key <photo_dir>：打印该文件夹对应的 sessions/<key>，
// 回归脚本用它把 fixture 放到 store 会去找的位置。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--session-key"),
   CommandLine.arguments.count > flagIndex + 1 {
    print(BatchStore.sessionKey(for: URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])))
    exit(0)
}

// Headless verdict smoke test (连拍去重用):
// LabelGUI --verdicts <photo_dir> [--dedupe] [--per-photo]
// 加载该场次的缓存结果，套用当前阈值，打印判决/理由统计和多张连拍组的组内判决。
// --per-photo：最后再逐张打印「id 判决 理由」（单张的场上面不打印），对比两次分析用。
//   两台以上机身时每行后面再带机身、对时后的拍摄时间、章节，最后打每台机身和按拍摄时间的顺序（单机身输出不变）。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--verdicts"),
   CommandLine.arguments.count > flagIndex + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let dedupe = CommandLine.arguments.contains("--dedupe")
    // --gap <秒> 覆盖「同一场最大间隔」，用来扫参数而不必动 GUI 里的滑杆。
    var gapOverride: Double?
    if let gi = CommandLine.arguments.firstIndex(of: "--gap"), CommandLine.arguments.count > gi + 1 {
        gapOverride = Double(CommandLine.arguments[gi + 1])
    }
    MainActor.assumeIsolated {
        let store = BatchStore(dataDir: appDataDir,
                               pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.rejectBurstDuplicates = dedupe
        // 章节警告受这个设置影响；固定成 0，CI 的期望输出不跟着 UserDefaults 漂。
        store.minKeepersPerChapter = 0
        store.switchSession(to: dir)
        if let gap = gapOverride { store.takeGapSec = gap }
        // --accept-all：跑一遍「全部只留精选」再打印（写进该数据目录的 overrides.json，
        // 所以只在临时 LABELGUI_DATA_DIR 下用）。--undo 紧接着撤销一次，验证单条撤销记录。
        if CommandLine.arguments.contains("--accept-all") {
            let n = store.acceptAllRecommendations()
            print("接受全部推荐: 动了 \(n) 场 · overrides \(store.overrides.count) 条 · 人工改判 \(store.manualOverrideCount) 条")
            if CommandLine.arguments.contains("--undo") {
                store.undoLastOverride()
                print("撤销一次后: overrides \(store.overrides.count) 条 · 人工改判 \(store.manualOverrideCount) 条")
            }
        }
        let counts = store.verdictCounts
        print("连拍去重: \(dedupe ? "开" : "关")")
        print("照片 \(store.items.count) · 精选 \(counts.pick) · 可用 \(counts.usable) · 废片 \(counts.reject)")
        let stats = store.burstGroupStats
        let takes = store.takeStats
        print("近似重复 \(stats.groups) 组 / \(stats.photos) 张 (phash 层，自动规则作用范围)")
        print("场 (间隔≤\(Int(store.takeGapSec))s) \(takes.takes) 个多张场 / \(takes.photos) 张 · 待处理 \(store.pendingTakeCount)")
        for reason in BatchStore.reasonOrder {
            if let n = store.reasonCounts[reason] { print("  理由 \(reason): \(n)") }
        }
        for w in store.chapterWarnings { print("  章节警告: \(w)") }
        for sug in store.thresholdSuggestions {
            print("  阈值建议: 放行 \(sug.released) 张「\(sug.kind.rawValue)」→ \(sug.currentText) → \(sug.suggestedText) (能救回 \(sug.rescued)/\(sug.released))")
        }
        if store.manualRejectsWithoutReason > 0 { print("  滑杆漏掉(手动废且无理由): \(store.manualRejectsWithoutReason)") }
        let byTake = Dictionary(grouping: store.items, by: \.take)
        for take in byTake.keys.sorted() where (byTake[take]?.count ?? 0) > 1 {
            let line = byTake[take]!
                .sorted { ($0.captureTime ?? .distantPast) < ($1.captureTime ?? .distantPast) }
                .map { "\($0.id)=\($0.verdict.rawValue)" + (store.takeRank[$0.id].map { "#\($0)" } ?? "") }
                .joined(separator: " ")
            print("  场 \(take) (\(byTake[take]!.count) 张): \(line)")
        }
        if CommandLine.arguments.contains("--per-photo") {
            let preset = store.currentPreset?.rawValue ?? "自定义"
            print("阈值: 锐度 \(store.sharpnessThreshold) · 曝光裁切 \(store.exposureThreshold) · 人脸质量 \(store.faceQualityThreshold) · 预设 \(preset)")
            let multiBody = store.bodies.count >= 2
            for item in store.items.sorted(by: { $0.id < $1.id }) {
                let reasons = item.rejectReasons.isEmpty ? "-" : item.rejectReasons.joined(separator: ",")
                let body = multiBody ? BodyClockCLI.perPhotoSuffix(item, store: store) : ""
                print("  \(item.id) \(item.verdict.rawValue) \(reasons)" + body)
            }
            if multiBody { BodyClockCLI.printTimeline(store) }
        }
        // --clear-recents：打印完再点一次「全部清除」，数还剩哪些场次目录 —— 验证掉出菜单的旧场次
        // 判决不被顺手删掉。会删数据目录里的场次：只在临时 LABELGUI_DATA_DIR 下跑。
        if CommandLine.arguments.contains("--clear-recents") {
            guard !(ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? "").isEmpty else {
                print("--clear-recents 会删场次缓存：先设 LABELGUI_DATA_DIR=<临时目录>")
                exit(2)
            }
            store.clearRecentSessions()
            let root = appDataDir.appendingPathComponent("sessions")
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0 != "default" && !$0.hasPrefix(".") }.sorted()
            print("全部清除后: 剩 \(left.count) 个场次目录 \(left.joined(separator: " "))")
        }
    }
    exit(0)
}

// Headless sharpen smoke test (适应视图管线):
// LabelGUI --sharp <photo> <out.jpg> [longEdge]
// 走和检视器一模一样的 4096 解码 → Lanczos 缩到 longEdge → unsharp，落成 JPEG。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--sharp"),
   CommandLine.arguments.count > flagIndex + 2 {
    let photo = CommandLine.arguments[flagIndex + 1]
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    let edge = CommandLine.arguments.count > flagIndex + 3 ? Int(CommandLine.arguments[flagIndex + 3]) ?? 2560 : 2560
    let start = Date()
    guard let decoded = ThumbCache.load(path: photo, maxPixel: SharpImageView.fitMaxPixel) else {
        FileHandle.standardError.write("decode failed\n".data(using: .utf8)!); exit(1)
    }
    let t1 = Date()
    guard let rendered = SharpRenderer.render(decoded, longEdge: edge),
          let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("render failed\n".data(using: .utf8)!); exit(1)
    }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
    print(String(format: "decode %.0fx%.0f in %.2fs · render %dx%d in %.3fs · %@",
                 decoded.size.width, decoded.size.height, t1.timeIntervalSince(start),
                 cg.width, cg.height, Date().timeIntervalSince(t1), out.path))
    exit(0)
}

// Headless focus-peaking smoke test: LabelGUI --focus <photo> <out.png>
// 把对焦高亮遮罩叠在 ≤2048 的缩图上落成 PNG，肉眼看合焦区域标得对不对。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--focus"),
   CommandLine.arguments.count > flagIndex + 2 {
    let photo = CommandLine.arguments[flagIndex + 1]
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    guard let full = FullResCache.load(path: photo) else { FileHandle.standardError.write("decode failed\n".data(using: .utf8)!); exit(1) }
    let t0 = Date()
    guard let mask = FocusMask.compute(from: full, key: photo) else { FileHandle.standardError.write("mask failed\n".data(using: .utf8)!); exit(1) }
    let dt = Date().timeIntervalSince(t0)
    guard let base = ThumbCache.load(path: photo, maxPixel: FocusMask.maxEdge),
          let bcg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(data: nil, width: bcg.width, height: bcg.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
    let rect = CGRect(x: 0, y: 0, width: bcg.width, height: bcg.height)
    ctx.draw(bcg, in: rect); ctx.draw(mask, in: rect)
    guard let composed = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, composed, nil); CGImageDestinationFinalize(dest)
    print(String(format: "mask %dx%d in %.2fs · %@", mask.width, mask.height, dt, out.path))
    exit(0)
}

// Headless 连拍挑选：LabelGUI --compare <photo_dir> [--take N | --select id,id,...]
//     [--keys "3,cmd:<id>,click:<id>,space,shift-space,left,right,up,down,enter,undo,0"] [--auto] [--gap 秒]
// 用和界面同一个 PickSession 按键脚本跑一遍，每步打印这一组的草稿和 ⏎ 会怎么定。⏎ 会写
// overrides.json（--gap 写本场阈值文件）—— 只在临时 LABELGUI_DATA_DIR 下用。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--compare"),
   CommandLine.arguments.count > flagIndex + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    func option(_ flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > i + 1 else { return nil }
        return CommandLine.arguments[i + 1]
    }
    MainActor.assumeIsolated {
        // 不碰 minKeepersPerChapter 这类设置：它们写的是全局 UserDefaults，LABELGUI_DATA_DIR
        // 隔离不了 —— 跑一次测试会把 GUI 里的设置改掉。
        let store = BatchStore(dataDir: appDataDir,
                               pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        if let gap = option("--gap").flatMap(Double.init) { store.takeGapSec = gap }
        let request: PickRequest
        if let list = option("--select") {
            let ids = list.split(separator: ",").map { String($0) }
            guard let r = PickRequest.forSelection(ids, store: store) else {
                print("--select 至少要 2 张"); exit(1)
            }
            request = r
        } else if let take = option("--only").flatMap(Int.init) {
            // 审片里按 C：只挑这一场，⏎ 定完就结束（界面上自动回审片）。
            request = .only(take, focus: nil)
        } else if let take = option("--take").flatMap(Int.init) {
            request = .take(take, chapter: option("--chapter").flatMap(Int.init).map { $0 - 1 })
        } else {
            // --chapter N：和界面「只看这一章」时一样，这一轮只过第 N 章（从 1 数）的待处理场。
            let chapter = option("--chapter").flatMap(Int.init).map { $0 - 1 }
            let pending = store.pendingTakes.filter { t in
                chapter == nil || store.members(ofTake: t).first.map(BatchStore.timelineChapter(of:)) == chapter
            }
            guard let first = pending.first else { print("没有待处理的场"); exit(0) }
            request = .take(first, chapter: chapter)
        }
        let session = PickSession(store: store, request: request, sortByScore: false)
        // --auto：数字键选完直接下一组（界面上那个勾）。
        session.autoAdvance = CommandLine.arguments.contains("--auto")
        print(session.describe())
        for raw in (option("--keys") ?? "").split(separator: ",") {
            let key = raw.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            print("-- \(key)")
            if !session.handle(key) { print("未知按键 \(key)"); continue }
            print(session.describe())
        }
        // 台面排布：常见窗口里 1–12 张竖拍/横拍是一屏铺满（行×列）还是单行左右滚。
        for size in [CGSize(width: 1256, height: 640), CGSize(width: 1416, height: 720)] {
            for aspect in [CGFloat(2.0 / 3.0), 1.5] {
                let rows = (1...12).map { n -> String in
                    let r = PickLayout.compute(count: n, in: size, aspect: aspect, hasFaces: true)
                    switch r.arrangement {
                    case .grid(let rows, let cols): return "\(n)=\(rows)×\(cols)(\(Int(r.image.width))×\(Int(r.image.height)))"
                    case .strip: return "\(n)=滚(\(Int(r.image.width))×\(Int(r.image.height)))"
                    }
                }
                print("排布 \(Int(size.width))×\(Int(size.height)) \(aspect < 1 ? "竖拍" : "横拍"): " + rows.joined(separator: " "))
            }
        }
    }
    exit(0)
}

// Headless 拼图 / 相册：LabelGUI --collage <photo_dir> [选项]（选项见 CollageCLI.swift）。
// 只读分析结果、只写 --out —— 界面不开也能逐像素看版式和裁切。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--collage"),
   CommandLine.arguments.count > flagIndex + 1 {
    MainActor.assumeIsolated {
        CollageCLI.run(flagIndex: flagIndex)
    }
}

// 拼图界面离屏快照：LabelGUI --collage-ui <photo_dir> <out.png> [...]（见 CollageCLI.swift）。
// 禁止激活、窗口从不显示 —— 不开 GUI 也能看界面排布。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--collage-ui"),
   CommandLine.arguments.count > flagIndex + 2 {
    MainActor.assumeIsolated {
        CollageUISnapshot.run(flagIndex: flagIndex)
    }
}

// 水印页离屏快照：LabelGUI --watermark-ui <photo_dir> <out.png> [--width 1100] [--light]（见 WatermarkSnapshot.swift）。
// 和 --collage-ui 一样禁止激活、窗口从不显示。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--watermark-ui"),
   CommandLine.arguments.count > flagIndex + 2 {
    MainActor.assumeIsolated {
        WatermarkUISnapshot.run(flagIndex: flagIndex)
    }
}

// 水印页批量导出（同名不覆盖）：LABELGUI_DATA_DIR=<临时> LabelGUI --watermark-batch <photo_dir> <out_dir> [--signature sig.png] [--exif]
if let flagIndex = CommandLine.arguments.firstIndex(of: "--watermark-batch"),
   CommandLine.arguments.count > flagIndex + 2 {
    MainActor.assumeIsolated {
        WatermarkBatchCLI.run(flagIndex: flagIndex)
    }
}

// 网格「改判后保持位置」自检：LabelGUI --ux-selftest。
if CommandLine.arguments.contains("--ux-selftest") {
    MainActor.assumeIsolated {
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
        exit(failed == 0 ? 0 : 1)
    }
}

// XMP 写入 + 「XMP 过期」提醒的端到端检查：LABELGUI_DATA_DIR=<临时> LabelGUI --export-xmp <photo_dir> [--then id=精选|可用|废片]
// 会在 photo_dir 里原图旁边写 .xmp —— 只对拷出来的临时文件夹跑。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--export-xmp"),
   CommandLine.arguments.count > flagIndex + 1 {
    MainActor.assumeIsolated {
        guard !(ProcessInfo.processInfo.environment["LABELGUI_DATA_DIR"] ?? "").isEmpty else {
            print("--export-xmp 会改这一场的 xmp_state.json，还会在照片旁边写 .xmp：先设 LABELGUI_DATA_DIR=<临时目录>，" +
                  "并且只对拷出来的临时照片文件夹跑")
            exit(2)
        }
        let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
        let store = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        print("写之前：XMP 过期 \(store.xmpStaleCount) 张（从没写过 = 0）")
        store.exportXMP()
        let deadline = Date().addingTimeInterval(30)
        while store.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // 有张没写进去（别人的 XMP 合并不了）时 lastError 是提醒、progressText 是完成摘要：两行都打。
        let exportError = store.lastError
        print(store.progressText)
        if let exportError { print(exportError) }
        print("写完：XMP 过期 \(store.xmpStaleCount) 张")
        if let i = CommandLine.arguments.firstIndex(of: "--then"), CommandLine.arguments.count > i + 1 {
            let parts = CommandLine.arguments[i + 1].split(separator: "=").map(String.init)
            if parts.count == 2, let v = Verdict(rawValue: parts[1]) {
                store.setOverride(parts[0], v)
                print("改判 \(parts[0]) → \(v.rawValue)：XMP 过期 \(store.xmpStaleCount) 张")
                store.undoLastOverride()
                print("撤销后：XMP 过期 \(store.xmpStaleCount) 张")
            }
        }
        // 重开这一场：过期状态要从 xmp_state.json 读回来。
        let reopened = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        reopened.switchSession(to: dir)
        print("重开后：XMP 过期 \(reopened.xmpStaleCount) 张")
        if exportError != nil { exit(1) }
    }
    exit(0)
}

// 按机身对时（会写这一场的 body_offsets.json，只在临时数据目录下跑）：
// LABELGUI_DATA_DIR=<临时> LabelGUI --body-offset <photo_dir> [--body '<机身 key>' --seconds +180 | --align id,id] [--undo]
if let flagIndex = CommandLine.arguments.firstIndex(of: "--body-offset"),
   CommandLine.arguments.count > flagIndex + 1 {
    MainActor.assumeIsolated {
        BodyClockCLI.run(flagIndex: flagIndex)
    }
}

// 时间轴布局自检：LabelGUI --timeline-selftest（随机章节数/张数/宽度，验证不出界、不重叠）。
if CommandLine.arguments.contains("--timeline-selftest") {
    MainActor.assumeIsolated { ChapterTimelineSelfTest.run() }
}

// 批量页 / 连拍挑选离屏快照：LabelGUI --batch-ui|--compare-ui <photo_dir> <out.png> [...]（见 UISnapshot.swift）。
for flag in ["--batch-ui", "--compare-ui"] {
    if let flagIndex = CommandLine.arguments.firstIndex(of: flag),
       CommandLine.arguments.count > flagIndex + 2 {
        MainActor.assumeIsolated {
            BatchUISnapshot.run(flagIndex: flagIndex, compare: flag == "--compare-ui")
        }
    }
}

// 整窗离屏快照（测试用，窗口不显示）：LABELGUI_DATA_DIR=<临时> LabelGUI --app-ui <photo_dir> <out.png>
//     [--tab 批量处理|水印|拼图|标注校准] [--size 1440x900] [--wait 4]（见 AppSnapshot.swift）。
// 和 app 同一个 AppModel.make、同一个 ContentView —— 只有它拍得到 tab 之间的接线和标注校准 tab。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--app-ui"),
   CommandLine.arguments.count > flagIndex + 2 {
    MainActor.assumeIsolated {
        AppUISnapshot.run(flagIndex: flagIndex)
    }
}

// 实时桥的无头测试宿主（测试用，窗口不显示）：LABELGUI_DATA_DIR=<临时> LABELGUI_LIVE_SOCK_ROOT=<测试目录>
// LABELGUI_LIVE_TEST_OUT=<快照目录> LabelGUI --live-host <photo_dir> [--size …] [--tab …] [--no-view | --titled]（见 Live/LiveHost.swift）。
// 和 app 同一个 AppModel.make、同一个 LiveServer，只差 socket 根目录和 test.* 方法；测试脚本是 Scripts/live_smoke.py。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--live-host") {
    MainActor.assumeIsolated {
        LiveHost.run(flagIndex: flagIndex)
    }
}

// 主体蒙版 / 人物挡字自检：LabelGUI --mask-selftest <photo_dir>（见 CollageMaskSelfTest.swift）。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--mask-selftest") {
    MainActor.assumeIsolated {
        CollageMaskSelfTest.run(flagIndex: flagIndex)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--film-selftest") { MainActor.assumeIsolated { CollageStyleFilmSelfTest.run(flagIndex: i) } }  // 底片印样自检：LabelGUI --film-selftest <photo_dir> [--out 目录]
// 留白杂志模板自检：LabelGUI --minimal-selftest [photo_dir]（见 CollageStyleMinimalSelfTest.swift）。
if let i = CommandLine.arguments.firstIndex(of: "--minimal-selftest") { MainActor.assumeIsolated { CollageStyleMinimalSelfTest.run(flagIndex: i) } }
if CommandLine.arguments.contains("--swiss-selftest") { MainActor.assumeIsolated { CollageSwissSelfTest.run() } }
// 婚礼相册 fine-art 编排自检：LabelGUI --album-selftest [<photo_dir> --out <dir>]（见 CollageStyleFineArtSelfTest.swift）。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--album-selftest") {
    MainActor.assumeIsolated { CollageStyleFineArtSelfTest.run(flagIndex: flagIndex) }
}
// 时尚刊自检（挑主图、出一期、换封面、文案商标、字块不重叠）：LabelGUI --fashion-selftest <photo_dir>（CollageStyleFashionSelfTest.swift）。
if let i = CommandLine.arguments.firstIndex(of: "--fashion-selftest") { MainActor.assumeIsolated { CollageStyleFashionSelfTest.run(flagIndex: i) } }
if let i = CommandLine.arguments.firstIndex(of: "--newspaper-selftest") { MainActor.assumeIsolated { CollageStyleNewspaperSelfTest.run(flagIndex: i) } }  // 报纸风自检（CollageStyleNewspaperSelfTest.swift）

// 拼图编辑操作脚本：LabelGUI --collage-ops <photo_dir> --ops "..."（见 CollageCLI.swift）。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--collage-ops"),
   CommandLine.arguments.count > flagIndex + 1 {
    MainActor.assumeIsolated {
        CollageOpsScript.run(flagIndex: flagIndex)
    }
}

// Headless 放大裁块：LabelGUI --compare-crop <photo_dir> <id> <out.jpg>
// 走和连拍挑选放大一模一样的"按人脸裁原图"，落成 JPEG，并打印锚点 —— 用来肉眼
// 核对裁块居中在脸上、竖拍没转歪。
if let flagIndex = CommandLine.arguments.firstIndex(of: "--compare-crop"),
   CommandLine.arguments.count > flagIndex + 3 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let id = CommandLine.arguments[flagIndex + 2]
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 3])
    MainActor.assumeIsolated {
        let store = BatchStore(dataDir: appDataDir,
                               pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        store.switchSession(to: dir)
        guard let item = store.item(withID: id) else { print("没有这张: \(id)"); exit(1) }
        let start = Date()
        guard let crop = CompareZoom.crop(item),
              let cg = crop.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            print("裁块失败"); exit(1)
        }
        // 在锚点（主脸中心）画一个十字，看是不是落在脸上。
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ax = crop.anchor.x * CGFloat(w), ay = (1 - crop.anchor.y) * CGFloat(h)
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(max(4, CGFloat(w) / 300))
        ctx.move(to: CGPoint(x: ax - 60, y: ay)); ctx.addLine(to: CGPoint(x: ax + 60, y: ay))
        ctx.move(to: CGPoint(x: ax, y: ay - 60)); ctx.addLine(to: CGPoint(x: ax, y: ay + 60))
        ctx.strokePath()
        guard let marked = ctx.makeImage() else { exit(1) }
        CGImageDestinationAddImage(dest, marked, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { exit(1) }
        print(String(format: "裁块 %dx%d · 锚点 (%.2f, %.2f) · 人脸 %d · %.2fs · %@",
                     w, h, crop.anchor.x, crop.anchor.y, item.faces.count,
                     Date().timeIntervalSince(start), out.path))
    }
    exit(0)
}

// 客户选片闭环的无头入口（确认表 / 导入客户选择 / 复制文件名清单 / 复制原片，见 ClientPicksView.swift）：
// LABELGUI_DATA_DIR=<临时> LabelGUI --proof-sheet|--client-import|--copy-list|--copy-originals <photo_dir> [...]
for flag in ClientPicksCLI.flags {
    if let flagIndex = CommandLine.arguments.firstIndex(of: flag),
       CommandLine.arguments.count > flagIndex + 1 {
        MainActor.assumeIsolated {
            ClientPicksCLI.run(flag: flag, flagIndex: flagIndex)
        }
    }
}

// 导出 JPG / 精华 Top N 的无头入口（只往 --dest 里写）：
// LABELGUI_DATA_DIR=<临时> LabelGUI --export-jpeg <photo_dir> --dest <dir> [--scope picks|picks+usable|top:N] [...]（见 DeliveryExportView.swift）
if let flagIndex = CommandLine.arguments.firstIndex(of: "--export-jpeg"),
   CommandLine.arguments.count > flagIndex + 1 {
    MainActor.assumeIsolated {
        JPEGExportCLI.run(flagIndex: flagIndex)
    }
}

// 走到这里就要开界面了。命令行里带着不认识的 `--参数`（拼错了、或者拿新的测试脚本跑旧版程序）时
// 不开：测试 / 自动化以为自己在无头跑，结果弹出一个窗口。系统自己传的参数是单横线（-NSDocument…、-psn_…）。
if let unknown = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
    FileHandle.standardError.write("不认识的参数 \(unknown)，不开界面（无头参数见 README「从源码构建」；给 AI 用：--mcp）\n".data(using: .utf8)!)
    exit(2)
}

struct LabelGUIApp: App {
    /// 五个 store 和当前 tab（见 AppModel.swift）：跟着 app 活，整个进程一份。
    @StateObject private var model: AppModel

    init() {
        // 先建好再包：store 在这里就建出来，不等 SwiftUI 第一次取。
        let model = AppModel.make(
            dataDir: appDataDir,
            pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir),
            bridge: .gui
        )
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // 深色是产品的一部分，不跟随系统外观：照片必须在中性深底上
                // 判断，浅色系统下半白半黑的窗口曾被当成"主题坏了"报障。
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 850)
        // 没有「新建窗口」（⌘N）：五个 store 只有一份（AppModel），第二个窗口和第一个共用同一套 store、同一个 tab，
        // 像镜子一样，没有用处；AI 的实时桥也就不用分「该发给哪个窗口」（DESIGN §9.5.6）。系统恢复出来的多个窗口照样能用。
        .commands {
            CommandGroup(replacing: .newItem) {}
            // 「选片工具」菜单里带勾的「允许 AI 实时操作（MCP）」（DESIGN §9.6a）：默认开（没有这个键 = 开）。关掉以后 AI 读写
            // 都回 bridge_off、标题栏不再显示 AI，app 照常开着；再打开就恢复。设置只在这里写（app 自己的 UserDefaults 域）：
            // 桥那边（AppModel.setLiveBridge）和测试宿主的 test.set_bridge 都不碰 UserDefaults。
            CommandGroup(after: .appInfo) {
                LiveBridgeToggle(indicator: model.indicator) { on in
                    UserDefaults.standard.set(on, forKey: "live.bridgeEnabled")
                    model.setLiveBridge(on)
                }
            }
        }
    }
}

// 不开界面的最后一道闸：LABELGUI_NO_GUI=1，或者父进程不是 launchd 而且 stdin 不是终端（LABELGUI_ALLOW_GUI=1 绕过）→ 退出。
NoGUIGate.last()
LabelGUIApp.main()
