import SwiftUI
import AppKit

// MARK: - 这一版新增（NU12）
//
// 升级后第一次打开弹一次：本地记上次见过的版本号（UserDefaults 的 whatsNew.lastSeenVersion，不联网），菜单「帮助 › 这一版新增」
// 随时再看。内容是下面一张数据表（标题、一句话、「带我去」去哪），「带我去」走拼图的「去那儿」（CollageNav / AppModel.go）。
// 只有真的开界面（LabelGUIApp）才会去查、去弹：无头命令、--app-ui、--live-host、自检都不弹（AppRuntime.headless），
// 裸二进制（版本号是 dev）也不弹、不记。

/// 「带我去」能去的地方：大页签，或者拼图页里的某一块（左栏 / 右栏的页签 + 滚过去 + 描边）。
enum UIDestination: Hashable {
    case batch
    case watermark
    case collage(CollageSpot)
}

enum WhatsNew {
    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        /// nil = 没有「带我去」。
        let destination: UIDestination?
    }

    struct Notes {
        /// 这张表是哪一版的：升级到这一版（或更新）、上次见过的比它旧，才弹。
        let version: String
        let entries: [Entry]
    }

    /// 这一版新增的条目。占位：发版前换成 v1.27.0 的（两三条就好，一条一句话，能「带我去」的都带上）。
    static let notes = Notes(version: "1.27.0", entries: [
        Entry(id: "inspector",
              title: "右栏跟着选中走",
              detail: "点画布上的照片、文字、贴纸，右栏自动切到「格式」；点空白处是这一页的设置。",
              destination: .collage(.format)),
        Entry(id: "left-pane",
              title: "模板、素材搬到左栏",
              detail: "一键成套和 65 个模板在左栏「模板」，文字格、手写字、贴纸在「素材」。",
              destination: .collage(.kits)),
        Entry(id: "darkroom",
              title: "暗房进了顶栏",
              detail: "顶栏「暗房」一点就进；只想调一格，选中它在「格式 › 色调」里点「在暗房里挑…」。",
              destination: .collage(.darkroom)),
    ])

    /// 记「上次见过哪一版」的键（app 自己的 UserDefaults 域；自检写进参数域，不碰这里）。
    static let defaultsKey = "whatsNew.lastSeenVersion"

    /// 这个程序的版本号（打包时写进 Info.plist；裸二进制是 dev）。
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: 判断（纯函数，--ux-selftest 逐条测）

    /// 「1.27.0」→ [1, 27, 0]；不是这种写法（dev、空）→ nil。
    static func parse(_ version: String) -> [Int]? {
        let parts = version.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// a < b（少的那段按 0 补：1.27 = 1.27.0）。
    static func older(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// 打开时要不要弹。headless：无头 / 测试宿主 / 自检；hasHistory：这台机器上用过（最近场次不空）——
    /// 没记过版本号的有两种：从还没有这个功能的旧版升上来的（用过，要弹），新装的（没用过，不弹、只记下）。
    static func shouldShow(current: String, lastSeen: String?, notesVersion: String, hasHistory: Bool,
                           headless: Bool) -> Bool {
        guard !headless, let cur = parse(current), let notes = parse(notesVersion) else { return false }
        // 表是给更新的版本写的（开发中）：这一版用不着。
        if older(cur, than: notes) { return false }
        guard let seen = lastSeen.flatMap(parse) else { return hasHistory }
        return older(seen, than: notes)
    }

    // MARK: 记账

    /// 上次见过的版本号。读一律走 UserDefaults.standard；写：app 里写它自己的设置域（.standard），自检写参数域
    /// （.argumentDomain：只在这个进程的内存里、读的时候排在最前，和 AppRuntime.pinBatchSettings 同一个办法）——
    /// 以前试过独立的 suite，removePersistentDomain 以后 cfprefsd 过一会儿还会在 ~/Library/Preferences 留一个空 plist。
    struct Ledger {
        let write: (String) -> Void

        var lastSeen: String? { UserDefaults.standard.string(forKey: WhatsNew.defaultsKey) }

        func record(_ version: String) { write(version) }

        static var standard: Ledger { Ledger { UserDefaults.standard.set($0, forKey: WhatsNew.defaultsKey) } }

        static var argumentDomain: Ledger {
            Ledger { version in
                let defaults = UserDefaults.standard
                var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
                domain[WhatsNew.defaultsKey] = version
                defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            }
        }
    }

    // MARK: 打开时

    /// 这个进程查过没有（窗口恢复出好几个、onAppear 来几次，只查一次）。
    @MainActor private static var checked = false

    /// LabelGUIApp 的窗口出现时调（只有开界面这一条路调它）。要弹就设 model.whatsNewShown；版本号在弹的时候记（新装的、
    /// 不用弹的直接记）。插卡的导入框正开着时这次先不弹、也不记：下次打开再弹。
    @MainActor
    static func checkOnLaunch(_ model: AppModel) {
        guard !checked else { return }
        checked = true
        let headless = AppRuntime.headless || ProcessInfo.processInfo.environment["LABELGUI_NO_GUI"] == "1"
        let current = appVersion
        guard !headless, parse(current) != nil else { return }
        let ledger = Ledger.standard
        let show = shouldShow(current: current, lastSeen: ledger.lastSeen, notesVersion: notes.version,
                              hasHistory: !model.batch.recentSessions.isEmpty, headless: headless)
        guard show else {
            ledger.record(current)
            return
        }
        // 等窗口站稳了再弹（第一次出现的那一帧就弹 sheet 有时弹不出来）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard model.cardCenter.offer == nil else { return }
            Ledger.standard.record(current)
            model.whatsNewShown = true
        }
    }
}

extension AppModel {
    /// 「带我去」：切到那个大页签；拼图页里的再切左栏 / 右栏的页签、滚过去、描边（拼图页这时可能还没建出来：页签和滚动请求
    /// 记在 collage.nav 上，那一栏出现时接）。
    func go(_ destination: UIDestination) {
        switch destination {
        case .batch: tab = .batch
        case .watermark: tab = .watermark
        case .collage(let spot):
            tab = .collage
            collage.go(spot)
        }
    }
}

// MARK: - 界面

/// 「这一版新增」的弹框：一条一行（标题、一句话、带我去），底下「知道了」。
struct WhatsNewSheet: View {
    let notes: WhatsNew.Notes
    /// 点「带我去」：先关弹框，再去。
    let onGo: (UIDestination) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("这一版新增", systemImage: "sparkles").font(.title2.bold())
                Spacer()
                Text("v\(notes.version)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(notes.entries) { entry in
                    row(entry)
                }
            }
            Divider()
            HStack {
                Text("以后在「帮助 › 这一版新增」里还能再看")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("知道了", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func row(_ entry: WhatsNew.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.headline)
                Text(entry.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let destination = entry.destination {
                Button("带我去") { onGo(destination) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 自检（--ux-selftest）

/// 版本号的比较、弹不弹的判断表、记账只写参数域（内存里；app 自己的设置域一个键都不动）、数据表本身。返回没过的条数。
@MainActor
enum WhatsNewSelfTest {
    static func run() -> Int {
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if !ok { failed += 1 }
            let tail = ok ? "" : "（\(detail())）"
            print((ok ? "PASS " : "FAIL ") + "这一版新增：" + name + tail)
        }

        // 版本号
        check(WhatsNew.parse("1.27.0") == [1, 27, 0] && WhatsNew.parse("dev") == nil && WhatsNew.parse("") == nil
              && WhatsNew.parse("1..2") == nil, "版本号：1.27.0 认得，dev、空、1..2 不认")
        check(WhatsNew.older([1, 26, 3], than: [1, 27, 0]) && !WhatsNew.older([1, 27], than: [1, 27, 0])
              && !WhatsNew.older([1, 27, 1], than: [1, 27, 0]) && WhatsNew.older([1, 9], than: [1, 10]),
              "版本号按段比（1.9 < 1.10，1.27 = 1.27.0）")

        // 弹不弹
        let n = "1.27.0"
        let cases: [(String, String, String?, Bool, Bool, Bool)] = [
            ("从 1.26.3 升上来", "1.27.0", "1.26.3", true, false, true),
            ("这一版已经看过", "1.27.0", "1.27.0", true, false, false),
            ("跳过 1.27.0 直接装 1.27.1", "1.27.1", "1.26.3", true, false, true),
            ("1.27.0 看过以后升到 1.27.1（表还是 1.27.0 的）", "1.27.1", "1.27.0", true, false, false),
            ("从没有这个功能的旧版升上来（没记过、用过）", "1.27.0", nil, true, false, true),
            ("新装的（没记过、没用过）", "1.27.0", nil, false, false, false),
            ("记的是读不懂的字（用过）", "1.27.0", "abc", true, false, true),
            ("表是给更新的版本写的", "1.26.3", "1.26.0", true, false, false),
            ("裸二进制（dev）", "dev", nil, true, false, false),
            ("无头 / 测试宿主 / 自检", "1.27.0", "1.26.3", true, true, false),
        ]
        for (name, current, seen, history, headless, want) in cases {
            let got = WhatsNew.shouldShow(current: current, lastSeen: seen, notesVersion: n, hasHistory: history,
                                          headless: headless)
            check(got == want, name + (want ? " → 弹" : " → 不弹"), "\(got)")
        }
        check(AppRuntime.headless, "--ux-selftest 跑在无头模式（checkOnLaunch 走不到弹）")

        // 记账：写进参数域（内存里），读照样走 UserDefaults.standard；app 自己的设置域那个键跑前跑后一样、一次没写
        let prefsDomain: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        func persisted() -> String? {
            UserDefaults.standard.persistentDomain(forName: prefsDomain)?[WhatsNew.defaultsKey] as? String
        }
        let before = persisted()
        let ledger = WhatsNew.Ledger.argumentDomain
        ledger.record("1.26.3")
        check(ledger.lastSeen == "1.26.3"
              && WhatsNew.shouldShow(current: "1.27.0", lastSeen: ledger.lastSeen, notesVersion: n, hasHistory: true,
                                     headless: false),
              "记下 1.26.3（参数域）读得回来：升到 1.27.0 要弹", ledger.lastSeen ?? "nil")
        ledger.record("1.27.0")
        check(ledger.lastSeen == "1.27.0"
              && !WhatsNew.shouldShow(current: "1.27.0", lastSeen: ledger.lastSeen, notesVersion: n, hasHistory: true,
                                      headless: false),
              "记下 1.27.0 以后同一版不再弹", ledger.lastSeen ?? "nil")
        check(persisted() == before, "app 自己的设置域（\(prefsDomain)）里 \(WhatsNew.defaultsKey) 一次没写",
              "\(String(describing: before)) → \(String(describing: persisted()))")
        // 参数域里的拿掉（同一个进程后面的自检别读到它）
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[WhatsNew.defaultsKey] = nil
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)

        // 数据表
        let notes = WhatsNew.notes
        let ids = notes.entries.map(\.id)
        check(WhatsNew.parse(notes.version) != nil && !notes.entries.isEmpty && notes.entries.count <= 6
              && Set(ids).count == ids.count,
              "数据表：版本号认得、1–6 条、id 不重", "\(notes.version) \(ids)")
        check(notes.entries.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty }, "每条都有标题和一句话")
        return failed
    }
}
