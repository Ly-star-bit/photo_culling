import SwiftUI
import AppKit
import CryptoKit

// MARK: - 无头测试宿主（DESIGN §9.8.1；测试用，不开 GUI：禁止激活、窗口从不显示）

/// LABELGUI_DATA_DIR=<临时> LABELGUI_LIVE_SOCK_ROOT=<测试 socket 根目录> LABELGUI_LIVE_TEST_OUT=<快照目录>
///   LabelGUI --live-host <photo_dir> [--size 1440x900] [--tab 批量处理|水印|拼图|标注校准] [--no-view]
///
/// 和 GUI 同一个 AppModel.make、同一个 LiveServer（bridge: .testHost），区别只在 socket 根目录、测试开关和 test.* 方法；
/// 和 --app-ui 同一个离屏窗口（AppUISnapshot.offscreenWindow）。`--no-view`：只建 AppModel 和桥，不建 ContentView、
/// 不建任何 NSWindow（CI 上建不了离屏窗口时的退路，test.snapshot 回 unknown_method）。
/// 就绪时往 stdout 打一行 `ready sock=<S> pid=<pid> data_dir_id=<dev:ino> bridge=<on|off|unavailable> reason=<…>`，
/// 测试脚本只用这一行里的 S（§9.2.1：脚本不自己算）。收到 test.quit 或 SIGTERM / SIGINT 退出。
/// 用户永远走不到这里：只认 `--` 开头的参数，必须设临时数据目录和测试 socket 根目录，从不读写 UserDefaults。
enum LiveHost {
    @MainActor private static var model: AppModel?
    @MainActor private static var window: NSWindow?
    @MainActor private static var hostView: NSView?
    @MainActor private static var outDir: URL?
    /// test.write 写进来的值（不碰任何 store：STEP 2 还没有写方法，这个只给 FIFO / op_id / expired 的用例用）。
    @MainActor private static var testValues: [String: String] = [:]
    @MainActor private static var testApplied = 0
    /// 主线程最大间隔（5 ms 一拍）：看桥上的请求有没有卡住界面（R6 T2、T3）。
    @MainActor private static var maxGapMs = 0.0
    @MainActor private static var lastTick = LiveWire.nowMs()
    @MainActor private static var gapTimer: DispatchSourceTimer?
    @MainActor private static var signalSources: [DispatchSourceSignal] = []

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return args[i + 1]
        }
        guard args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") else {
            print("用法: --live-host <photo_dir> [--size 1440x900] [--tab 批量处理|水印|拼图|标注校准] [--no-view]")
            exit(1)
        }
        // 整套 store 都会写数据目录：只在临时数据目录里跑，而且不能就是真实的那个。
        CollageCLI.requireIsolatedDataDir("--live-host")
        AppUISnapshot.requireNotRealDataDir("--live-host")
        guard let root = env["LABELGUI_LIVE_SOCK_ROOT"], root.hasPrefix("/") else {
            print("--live-host 要设 LABELGUI_LIVE_SOCK_ROOT=<测试自己的 socket 根目录，绝对路径>（不能碰用户的 app）")
            exit(2)
        }
        if LivePaths.isRealSockDir(root) {
            print("--live-host 的 LABELGUI_LIVE_SOCK_ROOT 指到了真实的 socket 目录 \(LivePaths.realSockDir ?? "?")：换一个测试目录再跑")
            exit(2)
        }
        guard let out = env["LABELGUI_LIVE_TEST_OUT"], out.hasPrefix("/") else {
            print("--live-host 要设 LABELGUI_LIVE_TEST_OUT=<快照目录，绝对路径>")
            exit(2)
        }
        outDir = URL(fileURLWithPath: out, isDirectory: true)
        var tab = AppTab.batch
        if let name = option("--tab") {
            guard let found = AppUISnapshot.tabNames.first(where: { $0.0 == name }) else {
                print("--tab 只认 " + AppUISnapshot.tabNames.map(\.0).joined(separator: "|") + "，没有「\(name)」")
                exit(1)
            }
            tab = found.1
        }
        guard let options = testOptions(env, sockRoot: root) else { exit(2) }
        guard pinBatchSettings(env["LABELGUI_LIVE_TEST_SETTINGS"]) else { exit(2) }
        // 就绪那一行要马上出去（stdout 接管道时默认是全缓冲）
        setvbuf(stdout, nil, _IOLBF, 0)

        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = AppModel.make(dataDir: appDataDir,
                                  pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir),
                                  bridge: .testHost(options))
        self.model = model
        model.batch.switchSession(to: URL(fileURLWithPath: args[flagIndex + 1], isDirectory: true))
        model.tab = tab
        if !args.contains("--no-view") {
            let parts = (option("--size") ?? "1440x900").split(separator: "x").compactMap { Double($0) }
            let size = NSSize(width: parts.first ?? 1440, height: parts.count > 1 ? parts[1] : 900)
            let (w, host) = AppUISnapshot.offscreenWindow(model: model, size: size)
            host.layoutSubtreeIfNeeded()
            window = w
            hostView = host
        }
        guard let live = model.live, let paths = live.paths else {
            print("--live-host：数据目录解析不了（\(appDataDir.path)），没有桥")
            exit(2)
        }
        registerTestMethods(live, model: model, view: hostView != nil)
        live.refreshSnapshot()
        installSignals(live)
        startGapMeter()
        let bridge = live.bridgeState
        print("ready sock=\(paths.socketPath) pid=\(getpid()) data_dir_id=\(paths.dataDirID) bridge=\(bridge.word)"
              + " reason=\(bridge.reason ?? "-")")
        RunLoop.main.run()
        exit(0)
    }

    /// 只有宿主认的测试变量（§9.8.1）；写错了就不跑（悄悄退回默认值会让用例空跑通过）。
    private static func testOptions(_ env: [String: String], sockRoot: String) -> LiveTestOptions? {
        var o = LiveTestOptions(sockRoot: sockRoot)
        if let raw = env["LABELGUI_LIVE_TEST_PROTO"], !raw.isEmpty {
            let parts = raw.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2, parts[0] <= parts[1] else {
                print("LABELGUI_LIVE_TEST_PROTO 要写成 min,max：\(raw)")
                return nil
            }
            o.proto = (parts[0], parts[1])
        }
        if let raw = env["LABELGUI_LIVE_TEST_DROP_CAP"], !raw.isEmpty { o.dropCapability = raw }
        if let raw = env["LABELGUI_LIVE_TEST_SELFCHECK_MS"], !raw.isEmpty {
            guard let ms = Int(raw), ms >= 100 else {
                print("LABELGUI_LIVE_TEST_SELFCHECK_MS 要是 ≥100 的整数：\(raw)")
                return nil
            }
            o.selfCheckMs = ms
        }
        if let raw = env["LABELGUI_LIVE_TEST_SIGPIPE"], !raw.isEmpty {
            guard let layers = LiveServer.SigpipeLayers.named(raw) else {
                print("LABELGUI_LIVE_TEST_SIGPIPE 只认 all|none|accepted_only|listen_inherit|msg_nosignal：\(raw)")
                return nil
            }
            o.sigpipe = layers
        }
        o.rejectPeers = env["LABELGUI_LIVE_TEST_REJECT_PEERS"] == "1"
        if let raw = env["LABELGUI_LIVE_TEST_PROTECTED_PREFIX"], !raw.isEmpty {
            guard raw.hasPrefix("/") else {
                print("LABELGUI_LIVE_TEST_PROTECTED_PREFIX 要是绝对路径：\(raw)")
                return nil
            }
            o.protectedPrefix = raw
        }
        return o
    }

    /// 三个 batch.* 设置在 AppModel.make 之前钉进 argument domain（§10.7「宿主的设置钉死」）：只在内存里，不落盘。
    /// 裸二进制的设置域是 LabelGUI，本机这个域被写过 batch.rejectBurstDuplicates 这些；不钉的话 fixture 的判决计数会跟着
    /// 本机设置变。setVolatileDomain 换的是整个 argument domain，所以先取出原来的（命令行里的 -key value）再合进去
    /// （STEP 2 实测：换得掉，读得到，~/Library/Preferences 里不多文件）。LABELGUI_LIVE_TEST_SETTINGS 可以改，
    /// 写成 `rejectBurstDuplicates=1,minKeepersPerChapter=2,sortOrder=filename`。
    private static func pinBatchSettings(_ raw: String?) -> Bool {
        var reject = false
        var minKeepers = 0
        var sort = BatchStore.SortOrder.captureTime
        for pair in (raw ?? "").split(separator: ",") where !pair.isEmpty {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else {
                print("LABELGUI_LIVE_TEST_SETTINGS 要写成 key=value,…：\(pair)")
                return false
            }
            switch kv[0] {
            case "rejectBurstDuplicates":
                reject = kv[1] == "1" || kv[1] == "true"
            case "minKeepersPerChapter":
                guard let n = Int(kv[1]), n >= 0 else {
                    print("minKeepersPerChapter 要是非负整数：\(kv[1])")
                    return false
                }
                minKeepers = n
            case "sortOrder":
                let names: [String: BatchStore.SortOrder] = ["captureTime": .captureTime, "filename": .filename, "score": .score]
                guard let s = names[kv[1]] ?? BatchStore.SortOrder(rawValue: kv[1]) else {
                    print("sortOrder 只认 captureTime|filename|score：\(kv[1])")
                    return false
                }
                sort = s
            default:
                print("LABELGUI_LIVE_TEST_SETTINGS 只认 rejectBurstDuplicates、minKeepersPerChapter、sortOrder：\(kv[0])")
                return false
            }
        }
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["batch.rejectBurstDuplicates"] = reject
        domain["batch.minKeepersPerChapter"] = minKeepers
        domain["batch.sortOrder"] = sort.rawValue
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        return true
    }

    /// SIGTERM / SIGINT：关监听 fd、删自己的 socket，再以 0 退出。
    @MainActor
    private static func installSignals(_ live: LiveServer) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                live.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @MainActor
    private static func startGapMeter() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                let now = LiveWire.nowMs()
                maxGapMs = max(maxGapMs, now - lastTick)
                lastTick = now
            }
        }
        timer.resume()
        gapTimer = timer
    }

    /// 同步占住主线程（模拟界面卡住）。放在同步函数里：async 上下文里不能直接 Thread.sleep。
    private static func blockMain(ms: Int) {
        usleep(useconds_t(ms) * 1_000)
    }

    // MARK: - test.*（§9.8.1；只有宿主注册，GUI 调了回 unknown_method）

    @MainActor
    private static func registerTestMethods(_ live: LiveServer, model: AppModel, view: Bool) {
        live.register("test.state", kind: .read) { _ in .result(state(live, model: model)) }
        live.register("test.block_main", kind: .read) { req in
            let ms = min(max(LiveWire.int(req.params["ms"]) ?? 1_000, 0), 30_000)
            blockMain(ms: ms)
            return .result(["blocked_ms": ms])
        }
        live.register("test.write", kind: .write) { req in
            guard let key = req.params["key"] as? String, let value = req.params["value"] as? String else {
                return .failure("invalid_argument", "test.write 要 key、value（字符串）", nil)
            }
            let wait = min(max(LiveWire.int(req.params["async_ms"]) ?? 0, 0), 30_000)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000) }
            testValues[key] = value
            testApplied += 1
            return .result(["applied": testApplied, "key": key])
        }
        live.register("test.blob", kind: .read) { req in
            // 大回复（R6 store.blob）：主线程上只拼字节，JSON 编码和写 socket 在连接自己的队列上。
            let n = min(max(LiveWire.int(req.params["bytes"]) ?? 0, 0), 32 << 20)
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
            var bytes = [UInt8](repeating: 0, count: n)
            for i in 0..<n { bytes[i] = alphabet[(i &* 7 &+ i / 64) & 63] }
            let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return .result(["data": String(decoding: bytes, as: UTF8.self), "bytes": n, "sha256": sha])
        }
        live.register("test.reset_stats", kind: .read) { _ in
            maxGapMs = 0
            lastTick = LiveWire.nowMs()
            return .result([:])
        }
        live.registerDirect("test.pause_accept") { params in
            let ms = min(max(LiveWire.int(params["ms"]) ?? 0, 0), 10_000)
            live.pauseAccept(ms: ms)
            return .result(["paused_ms": ms])
        }
        live.register("test.set_bridge", kind: .read) { req in
            // 模拟菜单里关掉桥：for_ms 后自己重新打开（关着的时候 socket 不在，测试没法再发「打开」）。只改内存，不写 UserDefaults。
            guard req.params["enabled"] as? Bool == false, let ms = LiveWire.int(req.params["for_ms"]), (1...60_000).contains(ms) else {
                return .failure("invalid_argument", "test.set_bridge 只认 {enabled:false, for_ms:1–60000}", nil)
            }
            live.closeBridge("test")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                live.openBridge()
            }
            return .result(["off_ms": ms])
        }
        live.register("test.set_window_state", kind: .read) { req in
            let allowed = ["visible", "occluded", "minimized", "hidden", "no_window"]
            guard let s = req.params["state"] as? String, allowed.contains(s) else {
                return .failure("invalid_argument", "state 只认 " + allowed.joined(separator: "|"), nil)
            }
            live.windowOverride = s
            live.refreshSnapshot()
            return .result(["window_state": s])
        }
        live.register("test.switch_session", kind: .read) { req in
            // 模拟用户在侧栏切场次（走 switchSession，§9.8.1）
            guard let dir = req.params["photo_dir"] as? String, dir.hasPrefix("/") else {
                return .failure("invalid_argument", "photo_dir 要是绝对路径", nil)
            }
            model.batch.switchSession(to: URL(fileURLWithPath: dir, isDirectory: true))
            live.refreshSnapshot()
            return .result(["session": model.batch.photoDir == nil ? NSNull() : model.batch.sessionDir.lastPathComponent])
        }
        live.register("test.set_override", kind: .read) { req in
            // 模拟用户在网格里按 1/2/3/0 改判（setOverride，和界面同一条路）：给 cursor 的 session_changed 用例
            // （cull_set_verdicts 在 STEP 3b）。只有宿主有。
            let names: [String: Verdict?] = ["pick": .pick, "usable": .usable, "reject": .reject, "auto": nil]
            guard let id = req.params["id"] as? String, model.batch.item(withID: id) != nil,
                  let raw = req.params["verdict"] as? String, let verdict = names[raw] else {
                return .failure("invalid_argument", "test.set_override 要 {id: 这一场有的 id, verdict: pick|usable|reject|auto}", nil)
            }
            model.batch.setOverride(id, verdict)
            return .result(["id": id, "verdict": raw])
        }
        live.register("test.poke_nonfinite", kind: .read) { req in
            // §10.7 第 38 条：往 store 里塞非有限数（JSON 文件里写不进 NaN / inf：JSONDecoder 整个文件都不认，
            // STEP 3a 实测），看读工具的回复是不是 null、宿主有没有闪退。只改这一张的几个可变字段，只有宿主有。
            guard let id = req.params["id"] as? String,
                  let idx = model.batch.items.firstIndex(where: { $0.id == id }) else {
                return .failure("invalid_argument", "test.poke_nonfinite 要 {id: 这一场有的 id}", nil)
            }
            model.batch.items[idx].faceLuma = .nan
            model.batch.items[idx].frameLuma = .infinity
            model.batch.items[idx].frameLumaP99 = -.infinity
            model.batch.items[idx].captureSubsec = .nan
            return .result(["id": id, "fields": ["face_luma", "frame_luma", "frame_luma_p99", "capture_subsec"]])
        }
        live.register("test.quit", kind: .read) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                live.shutdown()
                exit(0)
            }
            return .result(["quitting": true])
        }
        if view {
            live.register("test.snapshot", kind: .read) { req in await snapshot(req, model: model) }
        }
    }

    @MainActor
    private static func state(_ live: LiveServer, model: AppModel) -> [String: Any] {
        var out = live.debugState()
        let (windows, ws) = live.windowState()
        out["window_state"] = ws
        out["windows"] = windows
        out["tab"] = LiveServer.tabName(model.tab)
        out["session"] = model.batch.photoDir == nil ? NSNull() : model.batch.sessionDir.lastPathComponent
        out["photo_count"] = model.batch.items.count
        out["pending_writes"] = live.pendingWrites
        out["test_values"] = testValues
        out["test_applied"] = testApplied
        out["max_main_gap_ms"] = (maxGapMs * 10).rounded() / 10
        // 钉进 argument domain 的三个设置在 store 里是不是真的生效了（§10.7「宿主的设置钉死」）
        var settings: [String: Any] = ["rejectBurstDuplicates": model.batch.rejectBurstDuplicates]
        settings["minKeepersPerChapter"] = model.batch.minKeepersPerChapter
        settings["sortOrder"] = model.batch.sortOrder.rawValue
        out["settings"] = settings
        // 受保护位置不读原图（§10.7 第 33 条）：cull.preview 每次要从原图解码之前都记一笔
        let opens = LiveImages.originalOpens.snapshot
        out["original_opens"] = ["count": opens.count, "recent": opens.recent]
        // 拼图的两个指纹（§9.8.1 第二轮加）：编辑指纹和 collage_get_state 的 digest 是同一个函数；整工程的只给测试
        out["edit_digest"] = LiveHandlers.editDigest(model.collage.project)
        out["full_digest"] = CollageWatermarkCLI.digest(model.collage.project)
        out["hints_pending"] = model.collage.hintsPending
        // 宿主从不变成前台 / key（§10.7 第 39 条之外的另一半证据）：只读 NSApp 的状态，不调任何会改它的方法
        var app: [String: Any] = ["active": NSApp.isActive, "key_window": NSApp.keyWindow != nil]
        app["main_window"] = NSApp.mainWindow != nil
        app["activation_policy"] = NSApp.activationPolicy().rawValue
        app["visible_windows"] = NSApp.windows.filter { $0.isVisible }.count
        app["host_window_visible"] = window?.isVisible ?? false
        app["host_window_key"] = window?.isKeyWindow ?? false
        out["nsapp"] = app
        return out
    }

    /// test.snapshot {tab, name, wait_ms}：先设 tab、等渲染，cacheDisplay 存成 <LABELGUI_LIVE_TEST_OUT>/<name>.png。
    /// name 只能是 [A-Za-z0-9_-]，不接受路径。
    @MainActor
    private static func snapshot(_ req: LiveServer.Request, model: AppModel) async -> LiveServer.Reply {
        guard let name = req.params["name"] as? String, (1...64).contains(name.count),
              name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else {
            return .failure("invalid_argument", "name 只能是 1–64 个 [A-Za-z0-9_-]", nil)
        }
        if let t = req.params["tab"] as? String {
            guard let found = AppUISnapshot.tabNames.first(where: { $0.0 == t }) else {
                return .failure("invalid_argument", "tab 只认 " + AppUISnapshot.tabNames.map(\.0).joined(separator: "|"), nil)
            }
            model.tab = found.1
        }
        let wait = min(max(LiveWire.int(req.params["wait_ms"]) ?? 1_500, 0), 20_000)
        try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
        guard let host = hostView, let dir = outDir, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return .failure("internal", "拍不了快照", nil)
        }
        host.layoutSubtreeIfNeeded()
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return .failure("internal", "PNG 编不出来", nil) }
        let file = dir.appendingPathComponent(name + ".png", isDirectory: false)
        do {
            try data.write(to: file)
        } catch {
            return .failure("internal", "写不出 \(file.path)", nil)
        }
        return .result(["file": file.path, "bytes": data.count])
    }
}
