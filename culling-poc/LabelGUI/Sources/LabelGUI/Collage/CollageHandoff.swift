import Foundation

/// 水印页 → 拼图页的交接。界面（ContentView）和命令行（--collage-ops 的 wmhandoff）走同一个函数。
@MainActor
enum CollageHandoff {

    static func fromWatermark(_ req: WatermarkCollageRequest, batch: BatchStore, collage: CollageStore) {
        collage.attach(sessionDir: batch.photoDir == nil ? nil : batch.sessionDir, photoDir: batch.photoDir)
        switch req.action {
        case .newCollage(let urls):
            // 认得出是批量页的照片（解码路径或原文件路径相同）就按批量 id 带：人脸、分数、景别都有现成的；
            // 认不出的（别的文件夹拖进水印页的）按文件带，现场跑人脸。
            let index = batchIndex(batch)
            var items: [BatchItem] = []
            var files: [URL] = []
            var order: [String] = []
            // 同一张的 RAW 和 JPEG 都在水印页列表里时会映射到同一个 id：只带一次（托盘去重只防已在托盘里的）。
            var seen = Set<String>()
            for url in urls {
                if let item = index[url.standardizedFileURL.path] {
                    guard seen.insert(item.id).inserted else { continue }
                    items.append(item)
                    order.append(item.id)
                } else {
                    guard seen.insert(CollageBridge.fileID(url)).inserted else { continue }
                    files.append(url)
                    order.append(CollageBridge.fileID(url))
                }
            }
            // 照片读完、排版发起之后再套水印（进托盘、排版、套水印是同一步撤销，撤销一次全回去）。
            // 先占个号：等照片的时候又来了一次交接、或者手动改了水印，这一次就不再盖上去。
            let ticket = collage.reserveWatermarkRevision()
            collage.importMixed(items: items, files: files, order: order) { [weak collage] landed in
                guard let collage else { return }
                // 一张都没带进来：这次什么都没套，号还回去（还在等照片的上一次交接照常套）。
                guard landed else {
                    collage.releaseWatermarkRevision(ticket)
                    return
                }
                land(req, revision: ticket.revision, into: collage)
            }
        case .applyToCurrent(let layer):
            adopt(req, layer: layer, into: collage)
        }
    }

    /// 交接的照片读完、排版发起之后：套水印，几条提示（放了几张 / 相框没带 / 整本相册都加了）合成一条
    /// —— 提示只有一个位置，后一条会把前一条盖掉。
    private static func land(_ req: WatermarkCollageRequest, revision: Int, into collage: CollageStore) {
        let placed = collage.notice
        guard collage.watermarkRevision == revision else {
            // 后面又来了一次交接：那一次自己会套，不吭声。是等照片时手动改过水印：说一声，不盖掉。
            if collage.latestHandoffRevision == revision {
                collage.setNotice(joined([placed, "等照片的时候水印改过了，这次没套水印页的设置（要的话在右边「水印」里点「用水印页的设置」）"]))
            }
            return
        }
        let adopted = adopt(req, layer: .photos, into: collage)
        var parts = [placed]
        if collage.notice != placed { parts.append(collage.notice) }
        if adopted, collage.isAlbum {
            parts.append("「每张照片」水印对整本相册的照片都生效（单张选中后在右边「水印」里关掉）")
        }
        let text = joined(parts)
        if !text.isEmpty { collage.setNotice(text) }
    }

    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: "；")
    }

    /// 把请求里的设置套进拼图的某一层（拼图检视器「用水印页的设置」「预设 ▸」也走这里）。返回套没套上。
    @discardableResult
    static func adopt(_ req: WatermarkCollageRequest, layer: CollageMarkLayerKind, into collage: CollageStore) -> Bool {
        collage.adoptWatermark(config: req.config, signatureURL: req.signatureURL, layer: layer,
                               refShort: req.refShort, presetName: req.presetName)
    }

    /// 批量页这一场：路径 → 照片（解码路径、原文件路径都认，RAW+JPEG 配对时水印页拿的是 JPEG）。
    private static func batchIndex(_ batch: BatchStore) -> [String: BatchItem] {
        var index: [String: BatchItem] = [:]
        for item in batch.items {
            for path in [item.decodePath, item.rawPath] {
                let key = URL(fileURLWithPath: path).standardizedFileURL.path
                if index[key] == nil { index[key] = item }
            }
        }
        return index
    }
}
