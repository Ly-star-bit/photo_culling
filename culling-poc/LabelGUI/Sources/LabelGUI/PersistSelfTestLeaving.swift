import Foundation

/// --persist-selftest：拼图工程写不上（盘满）时离开这一场（最终审查 P 车道）。以前 persistBeforeLeaving 只拦批量页自己的
/// 几份和「原件读坏了」那一种，collage.json 写失败照样切过去，attach 换上新场次的工程，相册改动一声不响就没了。
extension PersistSelfTestHarness {
    /// collage.json 盘上那一份的缝宽（读不出来 = nil）。
    func collageDiskGutter(_ url: URL) -> Double? {
        guard let data = read(url), let project = try? JSONDecoder().decode(CollageProject.self, from: data) else { return nil }
        return Double(project.style.gutter)
    }

    func collageWriteFailureBlocksLeaving() {
        print("— 拼图工程写不上（盘满）：切场次、移除当前这一场前再整份写一次，还写不上就拦下，相册改动不丢；腾出空间以后不用再改一下就能切")
        guard chmodBlocks else {
            print("SKIP root 跑时 chmod 挡不住写，这一段测不了")
            return
        }
        freshIndex()
        typealias Fake = FileSafetySelfTest.Fake
        let dir = dataDir.appendingPathComponent("photos/collage-leave", isDirectory: true)
        let otherDir = dataDir.appendingPathComponent("photos/collage-leave-other", isDirectory: true)
        FileSafetySelfTest.writeShoot(dir, [Fake(id: "a", raw: "a.JPG", jpeg: true)])
        FileSafetySelfTest.writeShoot(otherDir, [Fake(id: "x", raw: "x.JPG", jpeg: true)])
        // 和 app 同一套接线（AppModel.make），不开实时桥。app 里切完场次拼图跟着挂过去是 photoDirWatch 下一拍做的，这里同步做。
        let model = AppModel.make(dataDir: dataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: dataDir), bridge: .none)
        let batch = model.batch
        let collage = model.collage
        batch.switchSession(to: otherDir)
        model.ensureCollageAttached()
        batch.switchSession(to: dir)
        model.ensureCollageAttached()
        let session = batch.sessionDir
        let url = session.appendingPathComponent("collage.json")
        touchCollage(collage)
        let before = collageDiskGutter(url)
        check(before != nil && collage.projectSaveProblem == nil, "（对照）盘是好的：拼图改一下就写进 collage.json")

        // 写失败（场次目录只读 = 写不进去，和盘满走同一条路）
        setMode(session, 0o500)
        defer { setMode(session, 0o755) }
        touchCollage(collage)
        let want = Double(collage.project.style.gutter)
        let failedNow: Bool = collage.projectSaveProblem != nil && batch.persistError == nil && collageDiskGutter(url) == before
        check(failedNow, "（对照）拼图写不上：CollageStore 记着写失败，批量页没有红条，盘上还是旧的")

        let switched = batch.switchSession(to: otherDir)
        model.ensureCollageAttached()
        let said = batch.lastError ?? ""
        let stayed: Bool = !switched && batch.sessionDir == session && Double(collage.project.style.gutter) == want
        check(stayed && said.contains("拼图没存上") && said.contains("切场次"),
              "切场次：离开前再写一次还是写不上，拦下不切，内存里的拼图改动还在：\(said)")
        if let entry = batch.recentSessions.first(where: { $0.key == session.lastPathComponent }) {
            batch.removeSession(entry)
            model.ensureCollageAttached()
            let kept: Bool = batch.photoDir != nil && batch.sessionDir == session && Double(collage.project.style.gutter) == want
            check(kept && (batch.lastError ?? "").contains("移除这一场") && batch.recentSessions.contains { $0.key == entry.key },
                  "移除当前这一场：一样拦下，这一场还在「最近场次」里：\(batch.lastError ?? "nil")")
        } else {
            check(false, "这一场在「最近场次」里")
        }
        // 改完还没到点存（防抖里排着）就切：离开前那次写失败，一样拦下
        var style = collage.project.style
        style.gutter += 0.002
        collage.setStyle(style, coalesce: false)
        let pendingWant = Double(collage.project.style.gutter)
        let pendingSwitched = batch.switchSession(to: otherDir)
        model.ensureCollageAttached()
        let pendingKept: Bool = !pendingSwitched && Double(collage.project.style.gutter) == pendingWant
        check(pendingKept && collageDiskGutter(url) == before, "刚改完（还没到点存）就切：离开前那次写不上，一样不切、改动还在")

        // 腾出空间以后、没再改拼图：切之前整份再存一次，存上了才切
        setMode(session, 0o755)
        let left = batch.switchSession(to: otherDir)
        model.ensureCollageAttached()
        let rewritten: Bool = collageDiskGutter(url) == pendingWant
        check(left && batch.sessionDir != session && rewritten,
              "腾出空间以后、没再改拼图：切之前整份再存了一次，切过去了，盘上是切走前的最新一版")
        batch.switchSession(to: dir)
        model.ensureCollageAttached()
        check(Double(collage.project.style.gutter) == pendingWant && collage.projectSaveProblem == nil,
              "切回来：拼图读回来就是切走前的样子")
        batch.switchSession(to: otherDir)
        model.ensureCollageAttached()
    }
}
