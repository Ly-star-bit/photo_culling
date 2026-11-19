import Foundation

/// 场次文件里不规矩的输入（优化分析 2026-11-18 edge 维度）：LabelGUI --session-input-selftest。
/// 纯函数，不读写任何文件；要真文件、真分析的那一半（解不开 / 取消没轮到的照片计数、一行坏了重新分析补回、长文件名、
/// thresholds.json 离谱值 --verdicts 不崩）在 Scripts/photo_id_regression.py 的 J、L、M 组。
/// - EC-04：thresholds.json 里四条线都夹到滑杆范围，1e19 / -1e30 / 缺键不崩、不越界；正常值一个不改。
/// - EC-03：manifest / layer1 里一行字段类型不对、缺 id、根本不是对象：只丢这一行，其余照常；分析引擎复用前用的
///   decodablePhotoIDs / reusableIDs 和界面同一个解码器（没有锐度的 layer1 行不复用）。
/// - EC-01：没进网格的照片 = photos 里没结果的 + photos 里解不开的 + photos_without_results（解不开、取消时没轮到），不重复。
enum SessionInputSelfTest {
    @MainActor
    static func run() -> Never {
        let c = Checker()
        thresholds(c)
        lossyRows(c)
        unparsed(c)
        print(c.failed == 0 ? "场次输入自检通过：\(c.total) 条" : "!! 场次输入自检 \(c.failed) / \(c.total) 条失败")
        exit(c.failed == 0 ? 0 : 1)
    }

    final class Checker {
        var failed = 0
        var total = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            total += 1
            if ok {
                print("PASS " + name)
            } else {
                failed += 1
                print("FAIL " + name + " " + detail())
            }
        }
    }

    // MARK: - EC-04 thresholds.json 的离谱值

    static func thresholds(_ c: Checker) {
        func decoded(_ json: String) -> BatchStore.ThresholdState? {
            try? JSONDecoder().decode(BatchStore.ThresholdState.self, from: Data(json.utf8))
        }
        func line(_ s: BatchStore.ThresholdState) -> String {
            "对焦 \(s.resolvedFocus) 曝光 \(s.resolvedExposure) 人脸 \(s.resolvedFaceQuality) 间隔 \(s.resolvedTakeGap)"
        }
        // (json, 对焦, 曝光, 人脸质量, 间隔)
        let cases: [(String, Double, Double, Double, Double)] = [
            ("{\"sharpness\":45,\"faceQuality\":0.3,\"exposure\":0.15,\"takeGap\":1e19}", 60, 0.15, 0.3, 60),
            ("{\"sharpness\":45,\"faceQuality\":0.3,\"exposure\":0.15,\"takeGap\":-1e30}", 60, 0.15, 0.3, 1),
            ("{\"sharpness\":45,\"faceQuality\":99,\"exposure\":-5,\"takeGap\":-3}", 60, 0.005, 1, 1),
            ("{\"sharpness\":1e19,\"faceQuality\":-1e30,\"exposure\":1e19}", 150, 0.5, 0, 8),
            ("{\"sharpness\":45,\"faceQuality\":0.3,\"exposure\":0.15}", 60, 0.15, 0.3, 8),
            ("{\"sharpness\":45,\"focus\":72.5,\"faceQuality\":0.42,\"exposure\":0.07,\"takeGap\":13}", 72.5, 0.07, 0.42, 13),
        ]
        for (json, focus, exposure, quality, gap) in cases {
            guard let s = decoded(json) else {
                c.check(false, json, "解不开")
                continue
            }
            let ok = s.resolvedFocus == focus && s.resolvedExposure == exposure
                && s.resolvedFaceQuality == quality && s.resolvedTakeGap == gap
            c.check(ok, "\(json) → 对焦 \(focus) 曝光 \(exposure) 人脸 \(quality) 间隔 \(gap)", line(s))
        }
        // 三档预设、滑杆两头：原样（夹住不改任何 app 自己写得出的值）。
        for preset in BatchStore.CullPreset.allCases {
            let (focus, exposure, quality) = preset.thresholds
            let s = BatchStore.ThresholdState(focus: focus, exposure: exposure, faceQuality: quality, takeGap: 1)
            c.check(s.resolvedFocus == focus && s.resolvedExposure == exposure && s.resolvedFaceQuality == quality
                  && s.resolvedTakeGap == 1, "预设\(preset.rawValue)原样", line(s))
        }
        let edges = BatchStore.ThresholdState(focus: 150, exposure: 0.5, faceQuality: 1, takeGap: 60)
        c.check(edges.resolvedFocus == 150 && edges.resolvedExposure == 0.5 && edges.resolvedFaceQuality == 1
              && edges.resolvedTakeGap == 60, "滑杆最右边原样", line(edges))
        // 非有限（JSONDecoder 不收 NaN / Infinity，只能是代码里来的）：给默认，不越界。
        let weird = BatchStore.ThresholdState(focus: .nan, exposure: .infinity, faceQuality: -.infinity, takeGap: .nan)
        c.check(weird.resolvedFocus == 60 && weird.resolvedExposure == 0.15 && weird.resolvedFaceQuality == 0.3
              && weird.resolvedTakeGap == BatchStore.defaultTakeGapSec, "NaN / ±∞ → 标准那一份", line(weird))
        // 1e400 超出 Double：要么整份解不开（走 thresholds.corrupt 那条路），要么读成有限的范围内的数，不能崩。
        if let huge = decoded("{\"sharpness\":45,\"faceQuality\":0.3,\"exposure\":0.15,\"takeGap\":1e400}") {
            c.check(BatchStore.takeGapRange.contains(huge.resolvedTakeGap), "takeGap 1e400：读成范围内的数", line(huge))
        } else {
            c.check(true, "takeGap 1e400：整份解不开（走挪开 .corrupt 那条路）")
        }
    }

    // MARK: - EC-03 一行坏了只丢那一行

    static func lossyRows(_ c: Checker) {
        let manifestJSON = """
        {"photo_dir": "/p", "photos": [
          {"id": "a", "raw_path": "/p/a.jpg", "preview_path": "/d/a.jpg", "exif": {"iso": 400}},
          {"id": "b", "raw_path": "/p/b.jpg", "preview_path": "/d/b.jpg", "exif": {"iso": "四百"}},
          {"id": "c", "raw_path": "/p/c.jpg", "decode_path": "/p/c.JPG", "preview_path": "/d/c.jpg"},
          {"raw_path": "/p/noid.jpg", "preview_path": "/d/noid.jpg"},
          {"id": "e", "raw_path": "/p/e.jpg"},
          42,
          {"id": "g", "raw_path": "/p/g.jpg", "preview_path": "/d/g.jpg", "capture_time": 7}
        ], "photos_without_results": [{"id": "x", "raw_path": "/p/x.jpg"}]}
        """
        let data = Data(manifestJSON.utf8)
        let m = try? JSONDecoder().decode(Manifest.self, from: data)
        c.check(m?.photos.map(\.id) == ["a", "c"], "manifest：好的两行照常（a、c）", "\(m?.photos.map(\.id) ?? [])")
        let bad = m?.undecodableRows.map { $0.id ?? "-" } ?? []
        c.check(bad == ["b", "-", "e", "-", "g"], "解不开的五行各记一笔（iso 是字符串、缺 id、缺 preview_path、不是对象、时间是数字）",
                "\(bad)")
        c.check(m?.undecodableRows.first?.rawPath == "/p/b.jpg", "解不开的行也认得出路径（认旧键要用）")
        c.check(m?.photosWithoutResults?.map { $0.id } == ["x"], "photos_without_results 照常")
        c.check(Manifest.decodablePhotoIDs(data) == ["a", "c"], "复用前的校验：只有 a、c 能复用",
                "\(Manifest.decodablePhotoIDs(data) ?? [])")
        let noDir = Data(#"{"photos": [{"id": "a", "raw_path": "/p/a.jpg", "preview_path": "/d/a.jpg"}]}"#.utf8)
        c.check(Manifest.decodablePhotoIDs(noDir) == ["a"], "没有 photo_dir 的老 manifest：校验照样认行")
        c.check(Manifest.decodablePhotoIDs(Data("{\"photos\": 3}".utf8)) == nil
                && Manifest.decodablePhotoIDs(Data("截断的{".utf8)) == nil, "photos 不是数组、不是 JSON：nil（整份不复用）")

        let layer1JSON = """
        {"results": [
          {"id": "a", "sharpness": 80.5, "burst_group": 1},
          {"id": "b", "sharpness": "高", "burst_group": 2},
          {"id": "c", "burst_group": 3},
          {"id": "d", "sharpness": 70, "burst_group": 4, "error": "decode"},
          {"id": "e", "sharpness": 75, "burst_group": "五"},
          {"id": "f", "sharpness": 60, "burst_group": 6, "faces": [{"bbox": "x"}]},
          null
        ]}
        """
        let l = try? JSONDecoder().decode(Layer1File.self, from: Data(layer1JSON.utf8))
        c.check(l?.results.map(\.id) == ["a", "c", "d"], "layer1：类型不对的三行（锐度、分组、人脸框）和 null 只丢自己",
                "\(l?.results.map(\.id) ?? [])")
        let reusable = Layer1File.reusableIDs(Data(layer1JSON.utf8))
        c.check(reusable == ["a"], "复用前的校验：没有锐度（c）、带 error（d）的也不复用", "\(reusable ?? [])")
    }

    // MARK: - EC-01 没进网格的照片

    static func unparsed(_ c: Checker) {
        let json = """
        {"photo_dir": "/p", "photos": [
          {"id": "a", "raw_path": "/p/a.jpg", "preview_path": "/d/a.jpg"},
          {"id": "b", "raw_path": "/p/b.jpg", "preview_path": "/d/b.jpg"},
          {"id": "c", "raw_path": "/p/c.jpg", "exif": {"iso": "四百"}, "preview_path": "/d/c.jpg"},
          {"raw_path": "/p/q.jpg"}
        ], "photos_without_results": [{"id": "bad"}, {"id": "b"}, {"id": "late"}, {"raw_path": "/p/nameless.jpg"}]}
        """
        guard let m = try? JSONDecoder().decode(Manifest.self, from: Data(json.utf8)) else {
            c.check(false, "没进网格：manifest 解不开")
            return
        }
        let names = BatchStore.unparsedNames(manifest: m, loadedIDs: ["a"])
        c.check(names == ["b", "c", "manifest 里第 2 个解不开的行", "bad", "late"],
                "没进网格 = 没结果的 b + 解不开的 c 和没 id 的那行 + 解不开 / 没轮到的 bad、late（b 不重复）", "\(names)")
        let none = BatchStore.unparsedNames(manifest: m, loadedIDs: ["a", "b", "c", "bad", "late"])
        c.check(none == ["manifest 里第 2 个解不开的行"], "都进了网格：只剩认不出 id 的那行", "\(none)")
    }
}
