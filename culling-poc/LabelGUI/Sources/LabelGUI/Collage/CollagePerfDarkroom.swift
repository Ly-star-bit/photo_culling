import AppKit
import Combine
import Darwin

/// `--collage-ui … --darkroom --perf darkroom`：暗房里拖滑杆、悬停样张时后台渲了什么、渲了几次、松手以后多久全部落下。
/// 先单量一遍每一类渲染（大预览、原图、27 张样张、试条、底片条、1:1 细节、一张冲印区色调表）各要多久，
/// 再跑几个手势（每下隔 16 ms = 一帧），每个手势报：暗房每一类渲染跑了几次、合计多少毫秒，藏在暗房后面的画布预览
/// 渲了几张，新生成了几张色调表，整个进程用掉的 CPU 毫秒（所有线程，含渲染线程；GPU 的时间不在里面）和指令数，
/// 松手到大预览 / 1:1 细节都落下来的毫秒。
/// 毫秒只作参考（CollagePerfTray 开头说的：离屏进程可能被放到能效核上，同一份二进制差 3–5 倍）；次数、指令数可比。
@MainActor
extension CollagePerf {
    /// 暗房每一类渲染跑了几次、合计几毫秒（CollageDarkroom.pump 里记）。
    static var laneRuns: [String: Int] = [:]
    static var laneMS: [String: Double] = [:]
    /// 最后一类渲完的时刻。
    static var lastLaneDone: Date?

    static func lane(_ name: String, ms: Double) {
        guard enabled else { return }
        laneRuns[name, default: 0] += 1
        laneMS[name, default: 0] += ms
        lastLaneDone = Date()
    }

    /// 暗房各视图 body 重算的次数，报告里按这个顺序列。
    private static let darkroomViews = ["暗房", "暗房顶栏", "暗房样张栏", "暗房样张", "暗房预览", "暗房右栏", "暗房冲印",
                                        "暗房试条", "暗房细节", "暗房底片条"]

    /// 报告里的顺序和中文名。
    private static let lanes: [(key: String, label: String)] = [
        ("preview", "大预览"), ("original", "原图"), ("frames", "样张"), ("strip", "试条"), ("reel", "底片条"),
        ("loupe", "1:1 细节"),
    ]

    static func darkroomScenario(store: CollageStore, spin: (Double) -> Void) {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "暗房计时")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        if store.darkroom == nil { store.openDarkroom() }
        guard let dr = store.darkroom else {
            print("perf darkroom：开不了暗房")
            return
        }
        // 光谱色调、颗粒晕光开着（下一版起套光谱色调就自动带颗粒）：没开就开上，量的是常见的那种情况。
        var st = store.project.style
        if !st.look.isSpectral { st.look = .filmWarmSkin }
        if st.filmGrain == 0 { st.filmGrain = 0.6 }
        if st.filmHalation == 0 { st.filmHalation = 0.2 }
        if st != store.project.style { store.setStyle(st, coalesce: false) }
        settle(store: store, dr: dr, spin: spin)

        singles(store: store, dr: dr)

        let base = store.project.style
        gesture("颗粒滑杆 30 下", store: store, dr: dr, spin: spin) { i in
            dr.setStyleValue(\.filmGrain, 0.3 + Double(i) * 0.01)
        }
        gesture("胶片曝光滑杆 30 下（0 → +1.5 档）", store: store, dr: dr, spin: spin) { i in
            dr.setStyleValue(\.filmExposure, Double(i + 1) * 0.05, range: -1...2)
        }
        gesture("冷暖滑杆 30 下（0 → +0.6）", store: store, dr: dr, spin: spin) { i in
            dr.setStyleValue(\.filmWarmth, Double(i + 1) * 0.02, range: -1...1)
        }
        gesture("强度滑杆 30 下", store: store, dr: dr, spin: spin) { i in
            dr.setStrength(0.8 - Double(i) * 0.01)
        }
        let looks = CollageDarkroom.looks(in: .film).prefix(6)
        gesture("悬停样张 \(looks.count) 张（每张停 150 ms）", store: store, dr: dr, spin: spin, steps: looks.count,
                gap: 0.15) { i in
            dr.hover = looks[looks.index(looks.startIndex, offsetBy: i)]
        }
        dr.hover = nil
        settle(store: store, dr: dr, spin: spin)
        gesture("拖对比竖线 30 下", store: store, dr: dr, spin: spin) { i in
            dr.split = 0.2 + Double(i) * 0.02
        }
        var back = store.project.style
        back.filmGrain = base.filmGrain
        back.filmExposure = 0
        back.filmWarmth = 0
        store.setStyle(back, coalesce: false)
        settle(store: store, dr: dr, spin: spin)
    }

    /// 每一类渲染单独跑一次（先热一次缓存，再量 3 次取中位数）。
    private static func singles(store: CollageStore, dr: CollageDarkroom) {
        guard let page = store.page, let id = dr.subjectPhotoID else { return }
        let project = store.project
        let hints = store.hints
        let pageIndex = store.pageIndex
        let c = project.canvas
        let px = dr.previewPixels
        let scale = max(0.05, min(1, min(Double(px.width) / Double(c.width), Double(px.height) / Double(c.height))))
        let exportScale = Double(CollageStore.exportScale(canvas: c, options: store.exportOptions))
        let cells = store.geometry.frames.compactMap { $0.cell.kind == .photo ? $0.cell.photoID : nil }
        func median(_ body: () -> Void) -> Double {
            body()
            var t: [Double] = []
            for _ in 0..<3 {
                let start = Date()
                body()
                t.append(Date().timeIntervalSince(start) * 1000)
            }
            return t.sorted()[1]
        }
        let preview = median {
            _ = CollageDarkroom.renderPage(project, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale)
        }
        let original = CollageDarkroom.original(project, pageIndex: pageIndex)
        let plain = median {
            _ = CollageDarkroom.renderPage(original, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale)
        }
        let strength = dr.current.strength
        let frames = median {
            for look in CollageDarkroom.order {
                _ = CollageDarkroom.sample(id, base: project, hints: hints, look: look, strength: strength,
                                           width: 330, height: 220)
            }
        }
        let reel = median {
            for cell in cells {
                _ = CollageDarkroom.sample(cell, base: project, hints: hints, look: project.style.look,
                                           strength: project.style.lookStrength, width: 180, height: 120)
            }
        }
        let center = dr.loupeCenter
        // 暗房里的样子：原图解码在缓存里（停手一次渲一次，同几格照片）；另量一次原图现解（刚换位置、刚换页）。
        let originals = CollageImages.Recent(capacity: 2)
        let loupe = median {
            _ = CollageDarkroom.renderLoupe(project, pageIndex: pageIndex, fallback: page, hints: hints,
                                            scale: exportScale, center: center, originals: originals)
        }
        let loupeCold = median {
            _ = CollageDarkroom.renderLoupe(project, pageIndex: pageIndex, fallback: page, hints: hints,
                                            scale: exportScale, center: center)
        }
        // Retina 上的真 1:1：边长两倍的像素（loupeSide × 2）。
        let retina = CollageDarkroom.loupeSide * 2
        let loupeRetina = median {
            _ = CollageDarkroom.renderLoupe(project, pageIndex: pageIndex, fallback: page, hints: hints,
                                            scale: exportScale, center: center, side: retina, density: 2,
                                            originals: originals)
        }
        let loupeWhole = median {
            _ = CollageDarkroom.renderLoupe(project, pageIndex: pageIndex, fallback: page, hints: hints,
                                            scale: exportScale, center: center, wholePage: true)
        }
        let digest = median { _ = CollageStore.editDigest(project) }
        // 婚礼相册的量：托盘复制 15 份、页复制到 30 页（暗房每一类的键都要算一次编辑指纹）。
        var big = project
        big.photos = (0..<15).flatMap { k in project.photos.map { p -> CollagePhotoRef in
            var q = p
            if k > 0 { q.id = p.id + "~\(k)" }
            return q
        } }
        big.pages = (0..<30).map { i in
            var pg = project.pages[i % project.pages.count]
            pg.id = UUID()
            return pg
        }
        let bigDigest = median { _ = CollageStore.editDigest(big) }
        // 冲印区的色调表：每次换一个没生成过的档（缓存里没有）。
        var k = 0
        let cube = median {
            k += 1
            let p = CollageFilmEffects.Printing(exposure: 0.1 * Double(k), warmth: -0.05 * Double(k))
            _ = CollageLooks.cube(project.style.look, strength: 0.8, printing: p)
        }
        print(String(format: "perf darkroom 单次：大预览（%.2f 倍）%.1f ms · 原图 %.1f · 样张 %d 张 %.1f · 底片条 %d 格 %.1f · "
                     + "1:1 细节（%d 倍）%.1f（原图现解 %.1f · 渲整页再裁 %.1f · Retina %d² %.1f）· 冲印区色调表一张 %.1f · 编辑指纹 %.2f ms"
                     + "（%d 张 / %d 页 %.2f ms）",
                     scale, preview, plain, CollageDarkroom.order.count, frames, cells.count, reel, Int(exportScale),
                     loupe, loupeCold, loupeWhole, retina, loupeRetina, cube, digest, big.photos.count, big.pages.count,
                     bigDigest))
        let centers = store.geometry.frames.map { f in
            CGPoint(x: Double(f.rect.x0 + f.rect.x1) / 2, y: Double(f.rect.y0 + f.rect.y1) / 2)
        } + [CGPoint(x: 0, y: 0), CGPoint(x: Double(c.width), y: Double(c.height)),
             CGPoint(x: Double(c.width) / 2, y: Double(c.height) / 2)]
        for side in [CollageDarkroom.loupeSide, retina] {
            loupeIdentity(project, page: page, pageIndex: pageIndex, hints: hints, scale: exportScale, centers: centers,
                          side: side)
        }
    }

    /// 1:1 细节只渲够得着的那几格（Options.region）和渲整页再裁，逐字节核对：每格中心、四角里的两个、画布中心。
    /// 核对本身在 CollageDarkroom.loupeIdentity（--darkroom-selftest 用合成图核对同一个函数，不同就失败）。
    static func loupeIdentity(_ project: CollageProject, page: CollagePage, pageIndex: Int,
                              hints: [String: CollageCrop.Hints], scale: Double, centers: [CGPoint], side: Int) {
        let same = CollageDarkroom.loupeIdentity(project, pageIndex: pageIndex, fallback: page, hints: hints, scale: scale,
                                                 centers: centers, side: side).filter { $0 }.count
        print((same == centers.count ? "PASS" : "FAIL")
              + " 1:1 细节只渲够得着的格子（\(side)²）：\(same) / \(centers.count) 处和渲整页再裁逐字节相同")
    }

    /// 暗房每一类、画布预览都落下来（最多等 90 秒）。返回等了多少毫秒。先等过暗房的 120 ms 去抖和 1:1 细节的
    /// 0.35 秒停手：这之前 busy 可能还是 false（去抖还没触发），不等就量早了。
    @discardableResult
    private static func settle(store: CollageStore, dr: CollageDarkroom, spin: (Double) -> Void) -> Double {
        let start = Date()
        spin(0.6)
        while Date().timeIntervalSince(start) < 90 {
            if !dr.busy && store.previewIdle { break }
            spin(0.01)
        }
        return Date().timeIntervalSince(start) * 1000
    }

    private static func gesture(_ label: String, store: CollageStore, dr: CollageDarkroom, spin: (Double) -> Void,
                                steps: Int = 30, gap: Double = 0.016, _ step: (Int) -> Void) {
        settle(store: store, dr: dr, spin: spin)
        laneRuns = [:]
        laneMS = [:]
        bodies = [:]
        var canvasPreviews = 0
        let sub = store.previewState.$scale.dropFirst().sink { _ in canvasPreviews += 1 }
        let cubes0 = CollageLooks.cubeBuilds
        var loupeAt: Date?
        var processedAt: Date?
        var released: Date?
        var shownWhileDragging = 0
        let subs = [
            dr.output.$loupe.dropFirst().sink { _ in loupeAt = Date() },
            dr.output.$processed.dropFirst().sink { _ in
                processedAt = Date()
                if released == nil { shownWhileDragging += 1 }
            },
        ]
        enabled = true
        lastLaneDone = nil
        let probe = MainStallProbe()
        probe.start()
        let cpu0 = processCPUMS(), instr0 = processInstructionsM(), main0 = mainThreadMS()
        for i in 0..<steps {
            step(i)
            spin(gap)
        }
        let mainDragging = mainThreadMS() - main0
        let stall = probe.stop()
        released = Date()
        settle(store: store, dr: dr, spin: spin)
        let cpu = processCPUMS() - cpu0, instr = processInstructionsM() - instr0
        enabled = false
        sub.cancel()
        subs.forEach { $0.cancel() }
        let ran = lanes.map { l in
            String(format: "%@ %d 次 %.0f ms", l.label, laneRuns[l.key] ?? 0, laneMS[l.key] ?? 0)
        }.joined(separator: " · ")
        func after(_ d: Date?) -> String {
            guard let d, let released, d > released else { return "—" }
            return String(format: "%.0f", d.timeIntervalSince(released) * 1000)
        }
        print(String(format: "perf darkroom %@：拖的时候大预览换了 %d 张、主线程 %.0f ms、主线程最长卡 %.0f ms（p95 %.0f）"
                     + " · 松手后 大预览 %@ ms · 1:1 细节 %@ · 全部渲完 %@ · 进程 CPU %.0f ms · %.0f 百万条指令 · 画布预览 %d 张"
                     + " · 新色调表 %d 张",
                     label, shownWhileDragging, mainDragging, stall.worst, stall.p95, after(processedAt), after(loupeAt),
                     after(lastLaneDone), cpu, instr, canvasPreviews, CollageLooks.cubeBuilds - cubes0))
        print("  暗房渲染：" + ran)
        print("  body：" + darkroomViews.map { "\($0) \(bodies[$0] ?? 0)" }.joined(separator: " · "))
    }

    /// 主线程用掉的 CPU 毫秒（拖的时候界面卡不卡看它；能效核上会多算几倍，只作参考）。
    static func mainThreadMS() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    /// 整个进程（所有线程）用掉的 CPU 毫秒。
    static func processCPUMS() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
        return ms(u.ru_utime) + ms(u.ru_stime)
    }

    /// 整个进程到现在执行了多少条指令（百万）。
    static func processInstructionsM() -> Double {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Double(info.ri_instructions) / 1e6 : 0
    }
}

/// 主线程卡没卡：后台每 4 ms 往主队列丢一个空活，记它等了多久才轮到。主线程在算、在等锁都算卡（等锁不花 CPU，
/// 主线程 CPU 毫秒看不出来）。离屏的主线程也会被放到能效核上，只作参考。
private final class MainStallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Double] = []
    private var timer: DispatchSourceTimer?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(4))
        t.setEventHandler { [weak self] in
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                self?.record(ms)
            }
        }
        timer = t
        t.resume()
    }

    private func record(_ ms: Double) {
        lock.lock()
        waits.append(ms)
        lock.unlock()
    }

    func stop() -> (worst: Double, p95: Double) {
        timer?.cancel()
        timer = nil
        lock.lock()
        defer { lock.unlock() }
        let sorted = waits.sorted()
        guard !sorted.isEmpty else { return (0, 0) }
        return (sorted.last ?? 0, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }
}
