import Foundation
import AppKit

/// 用户此刻是不是正在 app 里操作（DESIGN §9.6b）：桥在执行写之前问它（§9.4.3 第 6 步）。
/// - 一时的原因（按着鼠标、拖动、打字、输入法拼字、开着菜单、连续编辑）：桥在主线程上每 50 ms 看一次，等到不忙再写，
///   等满 busy_wait_ms 还忙就回 user_busy（transient:true）。等的时候主线程是空的，用户的拖动不受影响。
/// - 一直的原因（对话框、批量页的 sheet、连拍挑选、审片 / 检视器、裁切、导出）：不等，立刻 user_busy（transient:false），
///   hint 点名请用户关掉哪一个 —— 等 2 s 对开着的对话框没有用，模型照「过几秒再调」重试只会一直失败。
/// 原因从哪来：store 上的字段（视图往它手里已有的 store 上写：liveUI、liveCanvasDragging，store 自己的
/// continuousEditDepth、cropEditing、isExporting）；GUI 另外看 AppKit（本 app 里按下的鼠标、key window 的输入框、
/// 正开着的菜单、模态窗口和 sheet）。测试宿主不看 AppKit（宿主没有 key window，也不能让跑测试的人手上的鼠标影响结果），
/// 用 test.set_busy 模拟（§9.8.1），真窗口里的表现只能靠验收（§9.9）。
/// 这里只看，不碰任何窗口、不激活 app。
@MainActor
final class LiveInteraction {
    enum Reason: String, CaseIterable {
        case pointer, dragging, typing, composing, menu
        case continuousEdit = "continuous_edit"
        case modal
        case batchSheet = "batch_sheet"
        case pickSession = "pick_session"
        case batchViewing = "batch_viewing"
        case cropEditing = "crop_editing"
        case exporting

        /// 一时的（等一会儿）还是一直的（立刻回）。
        var transient: Bool {
            switch self {
            case .pointer, .dragging, .typing, .composing, .menu, .continuousEdit: return true
            case .modal, .batchSheet, .pickSession, .batchViewing, .cropEditing, .exporting: return false
            }
        }

        /// 一直的原因给模型的 hint：请用户关掉哪一个。
        var hint: String {
            switch self {
            case .pointer, .dragging: return "用户正在 app 里拖动：过几秒再调；不要连着重试超过 3 次，可以请用户停一下手"
            case .typing, .composing: return "用户正在 app 的输入框里打字：过几秒再调；不要连着重试超过 3 次，可以请用户停一下手"
            case .menu: return "用户正开着选片工具的菜单：过几秒再调"
            case .continuousEdit: return "用户正在拼图里拖缝 / 拖字：过几秒再调"
            case .modal: return "选片工具里开着对话框（确认框、导出框、选文件夹……）：请用户先关掉它，再调"
            case .batchSheet: return "选片工具的批量页开着面板（「移到废纸篓」「接受推荐」确认框、导出、对时、导入客户选择……）：请用户先关掉它"
            case .pickSession: return "用户正在连拍挑选里（它有自己的撤销记录）：请用户先退出连拍挑选，再改判"
            case .batchViewing: return "用户正在审片 / 检视器里看照片：请用户先退出（Esc），再切场次或定位照片；改判不受影响"
            case .cropEditing: return "用户正在拼图里裁切照片：请用户先按 Esc 退出裁切，再调"
            case .exporting: return "拼图正在导出：等导出完再调"
            }
        }
    }

    /// 哪一类写（挡哪些写见 §9.6b 的表）。
    enum Scope {
        /// 拼图写（含 app_undo target=collage）。
        case collage
        /// 改判（含 app_undo target=verdicts）。
        case verdicts
        /// 切场次（app_open_session）。
        case session
        /// 在 app 里定位照片（cull_show_photos）。
        case show
    }

    nonisolated static func blocks(_ reason: Reason, _ scope: Scope) -> Bool {
        switch reason {
        case .pointer, .typing, .composing, .menu, .modal:
            // 菜单（含右键菜单）里的项目记着打开菜单那一刻的页 / 选中：这时换掉数据，用户点的就落到别的东西上
            return true
        case .dragging, .continuousEdit, .cropEditing, .exporting:
            return scope == .collage
        case .batchSheet, .pickSession:
            return scope != .collage
        case .batchViewing:
            // 审片 / 检视器开着不挡改判（§9.6b 第二轮改：翻页顺序进来时就冻结了，改了正在看的那张画面当场变）
            return scope == .session || scope == .show
        }
    }

    /// 测试宿主的 test.set_busy：原因 → 到什么时候为止（LiveWire.nowMs）。GUI 从不设。
    private var simulated: [Reason: Double] = [:]
    /// GUI 才装的本地事件监视器（只看本 app 的事件）。
    private var monitors: [Any] = []
    private var resignToken: NSObjectProtocol?
    private var menuTokens: [NSObjectProtocol] = []
    /// 按下发生在本 app 里（判定时再看硬件状态：拖滑杆时 AppKit 的 tracking loop 可能吞掉 mouseUp）。
    private var pressedInApp = false
    /// 菜单（菜单栏、右键菜单、「一键成套 ▾」这类弹出菜单）正开着。主队列按 common modes 服务，菜单跟踪时 AI 的写
    /// 多半照样会跑（§8 第 20 条，未验证），落在用户眼前开着的菜单底下。
    private var menuOpen = false
    private var lastKeyDown = 0.0

    var watchesAppKit: Bool { !monitors.isEmpty }

    /// GUI（.gui）在开桥时装：记「按下在本 app 里」和最近一次按键。只是观察，事件原样放过去。
    /// AppModel.make 在 LabelGUIApp.init 里跑，那时应用对象可能还没建好：等它建好（每 0.5 s 看一次）再装，不去建它。
    func startWatchingAppKit() {
        guard monitors.isEmpty else { return }
        guard NSApp != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.startWatchingAppKit() }
            }
            return
        }
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                            .leftMouseUp, .rightMouseUp, .otherMouseUp]
        let downs: [NSEvent.EventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            let down = downs.contains(event.type)
            MainActor.assumeIsolated { self?.pressedInApp = down || NSEvent.pressedMouseButtons != 0 }
            return event
        }) {
            monitors.append(m)
        }
        if let k = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.lastKeyDown = LiveWire.nowMs() }
            return event
        }) {
            monitors.append(k)
        }
        // app 退到后台：之前那次按下不再算（不然用户之后在终端里拖选文字也会被当成在 app 里忙）
        resignToken = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pressedInApp = false
                self?.menuOpen = false
            }
        }
        // 任何一个菜单开始 / 结束跟踪（object: nil = 不管哪个菜单）
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = open }
            }
            menuTokens.append(token)
        }
    }

    /// test.set_busy：这几个原因在 ms 毫秒内算忙（ms 为 0 = 清掉）。
    func simulate(_ reasons: [Reason], ms: Int) {
        let until = LiveWire.nowMs() + Double(ms)
        for r in reasons { simulated[r] = ms > 0 ? until : nil }
    }

    /// 此刻挡住这一类写的原因（按 Reason 的顺序）。
    func reasons(_ model: AppModel, scope: Scope) -> [Reason] {
        var now = Set<Reason>()
        let t = LiveWire.nowMs()
        simulated = simulated.filter { $0.value > t }
        now.formUnion(simulated.keys)
        let collage = model.collage
        if collage.liveCanvasDragging { now.insert(.dragging) }
        if collage.continuousEditDepth > 0 { now.insert(.continuousEdit) }
        if collage.cropEditing { now.insert(.cropEditing) }
        if collage.isExporting { now.insert(.exporting) }
        let ui = model.batch.liveUI
        if ui.sheet { now.insert(.batchSheet) }
        if ui.pick { now.insert(.pickSession) }
        if ui.viewing { now.insert(.batchViewing) }
        if watchesAppKit { appKitReasons(into: &now) }
        return Reason.allCases.filter { now.contains($0) && Self.blocks($0, scope) }
    }

    /// GUI 才看的那几样（§9.6b 的表）。
    private func appKitReasons(into now: inout Set<Reason>) {
        guard let app = NSApp else { return }
        if pressedInApp {
            // 任何一次判定看到硬件上没按着，就把「按下在本 app」清掉（第二轮补的清除规则）
            if NSEvent.pressedMouseButtons != 0 { now.insert(.pointer) } else { pressedInApp = false }
        }
        if menuOpen { now.insert(.menu) }
        // 任何一个窗口挂着 sheet 都算（第二轮改：用户在 Claude Code 里打字时 app 不是活跃的，keyWindow 是 nil）
        if app.modalWindow != nil || app.windows.contains(where: { $0.attachedSheet != nil }) { now.insert(.modal) }
        // 焦点在输入框里而且最近在打字（只看焦点的话，一个忘了移开焦点的输入框会永远挡住 AI）。app 在后台时没有 key window
        if let text = app.keyWindow?.firstResponder as? NSTextView, text.isFieldEditor || text.isEditable {
            if text.hasMarkedText() {
                now.insert(.composing)
            } else if LiveWire.nowMs() - lastKeyDown < 2_000 {
                now.insert(.typing)
            }
        }
    }

    /// test.state 用：此刻全部原因（不分挡哪一类写）。
    func allReasons(_ model: AppModel) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for scope in [Scope.collage, .verdicts, .session, .show] {
            for r in reasons(model, scope: scope) where seen.insert(r.rawValue).inserted { out.append(r.rawValue) }
        }
        return out
    }
}
