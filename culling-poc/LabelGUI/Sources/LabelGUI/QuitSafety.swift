import Foundation
import Darwin

// 长任务和退出（全项目审查 S05）：VLM 子进程不变孤儿（S05b）。

/// VLM / 复审跑的是 `uv run python layer2.py`：Foundation 的 Process 让 uv 自己当进程组长，uv 起的 python 在同一组
/// （本机 uv 0.13 实测：组号 = uv 的 pid）。app 退出时没人给它们发信号的话，父进程一退 layer2 打下一行进度就 BrokenPipe、
/// 不再落盘，可线程池会把事先提交的照片全部发给 Ollama 跑完才退 —— 白占 GPU 和电量，重开再点 VLM 还要和它抢。
///
/// 退出和「取消」都只给 uv 发 SIGTERM（ProcessBox.signalLeader，kill(pid)）：uv 转给 python 一次，layer2 的 on_sigterm 落盘后
/// os._exit，一般几十毫秒整组就没了。等不到（老版本 uv 不转发、自己先被 SIGTERM 结束；python 卡住）才给整组补刀。
/// 不一上来就整组发（Foundation 的 Process.terminate() 在 macOS 上就是整组发）：uv 活着时整组发，python 会收到两次
/// （直接一次、uv 转发一次），第二次嵌套进 on_sigterm、正好打断第一次的落盘。
enum SubprocessGroup {
    enum Outcome: String {
        case exited = "收到 SIGTERM 自己退了"
        case terminated = "等不到，整组补发 SIGTERM 后退了"
        case killed = "整组 SIGKILL"
        case stuck = "SIGKILL 以后还在"
        case notOwnGroup = "不是它自己的进程组，只给 uv 发了 SIGTERM"
    }

    /// 能不能整组发信号：组号就是这个子进程自己（它当组长），不是 0 / 1，也不是我们自己这一组 ——
    /// 不然 kill(-组号) 会打到别的进程（终端里一起起来的、launchd 底下的，甚至我们自己）。
    static func ownsGroup(child: pid_t, group: pid_t, ownGroup: pid_t) -> Bool {
        child > 1 && group == child && group != ownGroup
    }

    /// 这一组里还有进程吗（刚退、还没被收的僵尸也算 —— Foundation 在后台很快收掉 uv，python 归 launchd 收）。
    static func alive(_ group: pid_t) -> Bool {
        guard group > 1 else { return false }
        if kill(-group, 0) == 0 { return true }
        return errno != ESRCH  // EPERM：组里还有，只是轮不到我们发
    }

    /// 等到这一组没人了（true），或者超时（false）。
    static func waitGone(_ group: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while alive(group) {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }

    /// SIGTERM 已经发给 uv 了（ProcessBox.terminateForQuit）。等 grace；还有活着的就整组补一个 SIGTERM（这时 uv 一般已经不在，
    /// python 只收到这一次），再等 termGrace，还在就整组 SIGKILL。最多阻塞 grace + termGrace + 0.5 s。
    static func reap(child: pid_t, group: pid_t, grace: TimeInterval = 1.5, termGrace: TimeInterval = 0.5) -> Outcome {
        guard ownsGroup(child: child, group: group, ownGroup: getpgrp()) else { return .notOwnGroup }
        if waitGone(group, timeout: grace) { return .exited }
        kill(-group, SIGTERM)
        if waitGone(group, timeout: termGrace) { return .terminated }
        kill(-group, SIGKILL)
        return waitGone(group, timeout: 0.5) ? .killed : .stuck
    }
}
