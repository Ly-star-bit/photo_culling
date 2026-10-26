import Foundation
import CoreGraphics
import CoreText

/// LABELGUI_DATA_DIR=<临时> LabelGUI --minimal-selftest [photo_dir]（照片文件夹要先 --analyze 过）
///
/// 「留白杂志」（CollageStyleMinimal）的自测：
/// 1. 名字：5 个模板，名字都以「留白杂志 · 」开头、全库唯一，分类是「留白杂志」；名字、分类不含别的分类名
///    （--template-sheet --only 和门禁按「包含」匹配，含了就会混进别的分类的总览）；预设 key 唯一。
/// 2. 商标红线：模板里所有字（每行、正文、页脚图层）不含真实刊名、胶片品牌（CollageTypeset.looksLikeRealMasthead
///    的表 + 胶片品牌），按西文单词比（W、TIME 这种短词不能整词出现）。
/// 3. 字体：Athelas 常规 / 斜体解析到 Athelas，Avenir 常规是 AvenirNext-Regular（不是 UltraLight），标题细宋是
///    STSongti-SC-Light，常规、斜体的退路链都先 Charter，New York 是系统衬线（这条退路链的最后一环）。
/// 4. {initial}：拾光 → S，刊头 atelier nord → A，标题「2026 春」→ 2；刊头填中文也取拼音（拾光集 → S、「拾光 Vol.2」→ S），
///    Été → E、さくら → S，只有标点 = 空 —— 永远是一个西文字母 / 数字（Athelas 没有汉字）。{masthead} 照旧。
///    没有 EXIF、没有拍摄时间的照片（截图、转发过的图）：每个模板的每一行、正文、页脚展开后不剩孤零零的
///    「·」「f/」「ISO」「农历」；手动镜头（没有焦距、光圈）那一行是「X-T50 · 1/250s · ISO 200」；数据齐的时候和
///    fill 原样一样。去空段只认 {key|}：别的内置模板、压字预设的每一行、正文在没有 EXIF 时和 fill 原样逐字一样
///    （它们不写 {key|}，这条行为只在本套的字上生效；合并进来的别的套件写了 {key|} 这条会点名）。
/// 4c. 巨字开篇的两个开关：maxZoom、tightEdge 在模板里、存成 JSON 读回来还在；旧 JSON 没有这两个键 = 不限、软边。
/// 5. 字号（照片文件夹给了才做）：每个模板套 8 张照片（竖的全身、半身、近景，亮天空 + 浅石桥那张，远处的全身，
///    三张横的，其中 7225 画边上有路人：裁的话预览和导出会躲得不一样），按排出来的实际字号
///    （文字格、页脚图层都走 CollageTypeset.prepared —— 放不下时缩过之后的那个）对 R4 §A5 的社交画布下限：
///    标题 ≥ 0.06 S、要读的 ≥ 0.028 S、加字距的装饰小字 ≥ 0.024 S、正文 ≥ 0.028 S；铺满宽度的刊头、巨字不算。
///    另验：字块两两不叠、页脚和照片上的字不压脸（人后的巨字本来就让人挡，不算）、字块都在画布里、0.4 预览和
///    导出取的是照片上同一块；
///    巨字开篇每张都打印人物挡字的决定，0.4 预览和 1 倍导出的决定一样，不压眼睛；留在人后时脸框确实碰到
///    巨字（头压进字里 —— 也是投脸算法的对照：算错了这条就不过）。
/// 全过退出 0，否则 1。
enum CollageStyleMinimalSelfTest {

    @MainActor
    static func run(flagIndex: Int) -> Never {
        let args = CommandLine.arguments
        CollageCLI.requireIsolatedDataDir("--minimal-selftest")
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }
        let templates = CollageStyleMinimal.templates
        let prefix = CollageStyleMinimal.category + " · "

        // ---------------------------------------------------------------- 1. 名字
        print("== 名字、分类、预设")
        check(templates.count == 5, "5 个模板", "\(templates.count) 个")
        let others = ["小红书封面", "日系杂志", "中式", "九宫格", "手账散落", "电影感", "基础",
                      "时尚刊", "底片印样", "报纸风", "瑞士网格", "婚礼相册"]
        let all = CollageTemplates.builtin
        for t in templates {
            check(t.name.hasPrefix(prefix), "\(t.name) 以「\(prefix)」开头")
            check(t.category == CollageStyleMinimal.category, "\(t.name) 分类是「\(CollageStyleMinimal.category)」")
            check(all.filter { $0.name == t.name }.count == 1, "\(t.name) 全库唯一")
            let hit = others.filter { t.name.contains($0) || t.category.contains($0) }
            check(hit.isEmpty, "\(t.name) 不含别的分类名", hit.joined(separator: " "))
            check(t.builtin && t.photoSlots == 1, "\(t.name) 内置、1 张照片", "\(t.photoSlots) 张")
        }
        // 反过来：别的模板的名字、分类不含「留白杂志」（不然 --only 留白杂志 会把它们也拉进来）。
        let strays = all.filter { $0.category != CollageStyleMinimal.category && ($0.name + $0.category).contains("留白杂志") }
        check(strays.isEmpty, "别的模板不含「留白杂志」", strays.map(\.name).joined(separator: " "))
        let keys = CollageStyles.all.map(\.key)
        check(keys.filter { $0 == "minimal" }.count == 1, "预设 key minimal 唯一")
        check(CollageStyles.all.contains { $0.key == "minimal" && $0.name == "留白杂志" }, "预设「留白杂志」在列表里")

        // ---------------------------------------------------------------- 2. 商标红线
        print("== 商标红线（模板里所有字）")
        // 刊名按 CollageTypeset 的那张比对表（含 W、TIME 这种短词）；那张表里没有胶片品牌，这里补上。
        // 只用来比对，不进任何默认值（DESIGN §0.4）。
        let filmBrands: Set<String> = ["KODAK", "FUJI", "FUJIFILM", "ILFORD", "PORTRA"]
        for t in templates {
            var strings: [String] = [t.name]
            for leaf in t.root.leaves {
                if let text = leaf.text { strings += texts(of: text) }
                for o in leaf.overlays { strings += texts(of: o.text) }
            }
            for item in t.items { if let text = item.text { strings += texts(of: text) } }
            var found: [String] = []
            for s in strings {
                let words = s.uppercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
                found += words.filter { filmBrands.contains($0) || CollageTypeset.looksLikeRealMasthead($0) }
            }
            check(found.isEmpty, "\(t.name) 没有真实刊名、胶片品牌", found.joined(separator: " "))
        }

        // ---------------------------------------------------------------- 3. 字体
        print("== 字体")
        func ps(_ f: CollageFont, _ w: CollageWeight, italic: Bool = false) -> String {
            CTFontCopyPostScriptName(CollageTypeset.font(f, w, italic: italic, size: 40)) as String
        }
        let athelas = ps(.athelas, .regular)
        check(athelas == "Athelas-Regular" || athelas == "Charter-Roman", "Athelas 常规 → \(athelas)")
        let italic = ps(.athelas, .regular, italic: true)
        check(italic == "Athelas-Italic" || italic == "Charter-Italic", "Athelas 斜体 → \(italic)")
        let italicChain = CollageTypeset.postScriptNames(.athelas, .regular, italic: true)
        check(italicChain.first == "Athelas-Italic" && italicChain.contains("Charter-Italic"), "Athelas 斜体的退路链先 Charter 斜体",
              italicChain.joined(separator: " → "))
        check(ps(.avenir, .regular) == "AvenirNext-Regular", "Avenir 常规 → \(ps(.avenir, .regular))（不是 UltraLight）")
        check(ps(.songti, .light) == "STSongti-SC-Light", "细宋 → \(ps(.songti, .light))")
        let chain = CollageTypeset.postScriptNames(.athelas, .regular, italic: false)
        check(chain.first == "Athelas-Regular" && chain.contains("Charter-Roman"), "Athelas 的退路链先 Charter",
              chain.joined(separator: " → "))
        let ny = ps(.newYork, .regular)
        check(ny.hasPrefix(".NewYork"), "退路链的最后一环 New York → \(ny)（Athelas、Charter 都缺时走这里）")

        // ---------------------------------------------------------------- 4. {initial}
        print("== {initial}（刊头的第一个字母）")
        let initialCases = [("拾光", "", "S"), ("拾光", "atelier nord", "A"), ("2026 春", "", "2"), ("拾光", "拾光集", "S"),
                            ("拾光", "拾光 Vol.2", "S"), ("拾光", "Été", "E"), ("拾光", "さくら", "S"), ("拾光", "·—·", "")]
        for (title, masthead, want) in initialCases {
            var p = CollageProject()
            p.title = title
            p.masthead = masthead
            let v = CollageTypeset.variables(project: p, root: .leaf(CollageCell()), photos: [:])
            check(v["initial"] == want, "标题「\(title)」刊头「\(masthead)」→「\(want)」", v["initial"] ?? "nil")
        }
        // {masthead} 抽出 romanized 之后照旧（K1 的封面、白边封面都用它）。
        for (title, masthead, want) in [("拾光", "", "SHIGUANG"), ("拾光·春日 2026", "", "SHIGUANG·CHUNRI 2026"),
                                        ("Atelier", "", "ATELIER"), ("拾光", "拾光集", "拾光集")] {
            let got = CollageTypeset.mastheadText(masthead, title: title)
            check(got == want, "{masthead} 标题「\(title)」刊头「\(masthead)」→ \(want)", got)
        }

        // ---------------------------------------------------------------- 4b. 没有 EXIF 的照片
        print("== 没有 EXIF、没有拍摄时间（不剩孤零零的分隔点、单位）")
        let bare = CollageTypeset.variables(project: CollageProject(), root: .leaf(CollageCell()), photos: [:])
        var manual = bare
        for (k, v) in [("model", "X-T50"), ("shutter", "1/250"), ("iso", "200")] { manual[k] = v }
        var full = manual
        for (k, v) in [("focal", "92mm"), ("focal_mm", "62mm"), ("day_n", "21"), ("fnumber", "4.5"), ("date_cn_full", "二〇二六年三月二十一日"), ("weekday_cn", "星期六"),
                       ("lunar", "二月初三"), ("ganzhi", "丙午"), ("month_en", "MARCH"), ("year", "2026"), ("day", "21"),
                       ("date", "2026.03.21")] { full[k] = v }
        // 孤字：单位、前缀单独剩下；分隔点在头、在尾、或者两个挨着（中间那段没了）。两段真字中间的「·」不算
        // （页脚「SHIGUANG · 01」）。
        let leftovers: Set<String> = ["f/", "ISO", "农历", "秒", "s", ",", "年"]
        func orphaned(_ r: String) -> Bool {
            let tokens = r.split { $0 == " " || $0 == "\n" }.map(String.init)
            let doubled = zip(tokens, tokens.dropFirst()).contains { $0 == "·" && $1 == "·" }
            return r.hasPrefix("·") || r.hasSuffix("·") || doubled || tokens.contains { leftovers.contains($0) }
                || r.split(separator: "\n").contains { $0.hasPrefix("·") || $0.hasSuffix("·") }
        }
        // 对照：不去空段的 fill 确实会剩孤字（查孤字的这条判断没写成永远通过）。
        let raw = CollageTypeset.fill("{model} · {focal} · f/{fnumber} · {shutter}s · ISO {iso}", vars: bare)
        check(orphaned(raw), "对照：原样 fill 剩孤字", raw)
        for t in templates {
            var lines: [CollageTextLine] = []
            var bodies: [String] = []
            for leaf in t.root.leaves {
                if let text = leaf.text { lines += text.lines; bodies += text.body.map { [$0.text] } ?? [] }
                for o in leaf.overlays { lines += o.text.lines }
            }
            for item in t.items { if let text = item.text { lines += text.lines } }
            let bad = lines.map { CollageTypeset.lineString($0, vars: bare) }.filter(orphaned)
                + bodies.map { CollageTypeset.fillBody($0, vars: bare) }.filter(orphaned)
            check(bad.isEmpty, "\(t.name) 没有 EXIF 时不剩孤字", bad.joined(separator: " | "))
            let same = lines.allSatisfy { CollageTypeset.fillDroppingEmpty($0.text, vars: full) == CollageTypeset.fill($0.text, vars: full) }
                && bodies.allSatisfy { CollageTypeset.fillBody($0, vars: full) == CollageTypeset.fill($0, vars: full) }
            check(same, "\(t.name) 数据齐的时候和 fill 原样一样")
        }
        let ledeLine = "{model|} · {focal_mm|} · f/{fnumber|} · {shutter|}s · ISO {iso|}"
        let lede = CollageTypeset.fillDroppingEmpty(ledeLine, vars: manual)
        check(lede == "X-T50 · 1/250s · ISO 200", "手动镜头（没有焦距、光圈）的参数行", lede)
        let inSmallPhoto = CollageStyleMinimal.smallPhotoTitle.root.leaves.contains { $0.text?.lines.contains { $0.text == ledeLine } ?? false }
        check(inSmallPhoto, "小图标题的参数行就是上面这一行")
        // 只认 {key|}：不写竖线的同一行照旧剩孤字（和改之前一样）。
        let unmarked = CollageTypeset.fillDroppingEmpty("{model} · {focal} · f/{fnumber} · {shutter}s · ISO {iso}", vars: manual)
        check(unmarked == CollageTypeset.fill("{model} · {focal} · f/{fnumber} · {shutter}s · ISO {iso}", vars: manual),
              "不写 {key|} 的行逐字照 fill", unmarked)
        // 别的内置模板、压字预设：没有 EXIF 时 lineString / 正文和 fill 原样逐字一样（门禁的照片都有 EXIF，看不到这条）。
        var foreign: [String] = []
        var foreignCount = 0
        func audit(_ text: CollageText, _ owner: String) {
            for l in text.lines {
                foreignCount += 1
                if CollageTypeset.lineString(l, vars: bare) != CollageTypeset.cased(CollageTypeset.fill(l.text, vars: bare), l.textCase) {
                    foreign.append("\(owner)「\(l.text)」")
                }
            }
            if let b = text.body {
                foreignCount += 1
                if CollageTypeset.fillBody(b.text, vars: bare) != CollageTypeset.fill(b.text, vars: bare) { foreign.append("\(owner) 正文") }
            }
        }
        for t in CollageTemplates.builtin where t.category != CollageStyleMinimal.category {
            for leaf in t.root.leaves {
                if let text = leaf.text { audit(text, t.name) }
                for o in leaf.overlays { audit(o.text, t.name) }
            }
            for item in t.items { if let text = item.text { audit(text, t.name) } }
        }
        for preset in CollageOverlays.presets { audit(preset.overlay.text, "压字预设 \(preset.name)") }
        check(foreign.isEmpty, "别的内置模板、压字预设没有 EXIF 时照旧（\(foreignCount) 行）", foreign.joined(separator: " "))
        let notes = CollageStyleMinimal.narrowColumn.root.leaves.compactMap { $0.text?.body?.text }.first ?? ""
        let manualNotes = CollageTypeset.fillBody(notes, vars: manual)
        check(manualNotes == "X-T50\n1/250 秒 · ISO 200", "窄栏文字的手记：手动镜头、没有拍摄时间",
              manualNotes.replacingOccurrences(of: "\n", with: " / "))
        // 白边封面三栏：值是空的那一栏小标签也不印（查孤字那条管不到：CAMERA 一个词不算孤字）。
        let bandLines = CollageStyleMinimal.whiteBandCover.root.leaves.flatMap { $0.text?.lines ?? [] }
        func bandLabels(_ vars: [String: String]) -> [String] {
            bandLines.map { CollageTypeset.lineString($0, vars: vars) }.filter { ["PORTRAIT", "CAMERA", "DATE"].contains($0) }
        }
        var untitled = full
        untitled["title"] = ""
        check(bandLabels(full) == ["PORTRAIT", "CAMERA", "DATE"], "白边封面数据齐时三个小标签都在",
              bandLabels(full).joined(separator: " "))
        check(bandLabels(manual) == ["PORTRAIT", "CAMERA"], "白边封面没有拍摄时间：不印 DATE",
              bandLabels(manual).joined(separator: " "))
        check(!bandLabels(bare).contains("CAMERA") && !bandLabels(bare).contains("DATE"),
              "白边封面没有 EXIF：不印 CAMERA / DATE", bandLabels(bare).joined(separator: " "))
        check(bandLabels(untitled) == ["CAMERA", "DATE"], "白边封面 {title} 展开是空（填不出来，标题空着时是「拾光」）：三栏同一个规则，不印 PORTRAIT",
              bandLabels(untitled).joined(separator: " "))
        let gated = bandLines.first { $0.onlyWhenFilled == "model" }
        let gatedBack = (try? JSONEncoder().encode(gated)).flatMap { try? JSONDecoder().decode(CollageTextLine.self, from: $0) }
        check(gated != nil && gatedBack == gated, "小标签的开关存盘再读回来还在")
        let oldLine = try? JSONDecoder().decode(CollageTextLine.self, from: Data(#"{"text":"CAMERA"}"#.utf8))
        check(oldLine?.onlyWhenFilled == nil && CollageTypeset.lineString(oldLine ?? CollageTextLine(""), vars: bare) == "CAMERA",
              "旧工程的行（没有这个键）照常印")

        // ---------------------------------------------------------------- 4c. 巨字开篇的开关
        print("== 巨字开篇：封面取景最多拉近 1.6 倍、人的边压利落")
        let giantOverlay = CollageStyleMinimal.giantInitial.root.leaves.compactMap { $0.overlays.first }.first
        check(giantOverlay?.maxZoom == 1.6 && giantOverlay?.tightEdge == true, "模板里 maxZoom 1.6、tightEdge 开",
              "\(giantOverlay?.maxZoom.map { "\($0)" } ?? "nil") / \(giantOverlay?.tightEdge ?? false)")
        if let o = giantOverlay, let data = try? JSONEncoder().encode(o),
           let back = try? JSONDecoder().decode(CollageOverlay.self, from: data) {
            check(back.maxZoom == 1.6 && back.tightEdge, "存成 JSON 读回来还在")
            var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            json["maxZoom"] = nil
            json["tightEdge"] = nil
            let old = (try? JSONSerialization.data(withJSONObject: json))
                .flatMap { try? JSONDecoder().decode(CollageOverlay.self, from: $0) }
            check(old != nil && old?.maxZoom == nil && old?.tightEdge == false, "旧 JSON 没有这两个键：不限、软边")
            json["maxZoom"] = 0.3
            let bad = (try? JSONSerialization.data(withJSONObject: json))
                .flatMap { try? JSONDecoder().decode(CollageOverlay.self, from: $0) }
            check(bad?.maxZoom == nil, "maxZoom < 1 读成不限")
        } else {
            check(false, "巨字的压字能编码、解码")
        }

        // ---------------------------------------------------------------- 5. 套真照片
        if args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") {
            let dir = URL(fileURLWithPath: args[flagIndex + 1])
            let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
            batch.switchSession(to: dir)
            CollageMasks.setDirectory(batch.sessionDir.appendingPathComponent("collage_masks"))
            let facts = CollageBridge.Facts(batch: batch)
            let refs = batch.items.compactMap { CollageBridge.ref(from: $0, facts: facts) }
            print("== 套真照片 \(refs.count) 张（\(dir.lastPathComponent)）")
            check(!refs.isEmpty, "照片文件夹分析过（拿得到照片）",
                  refs.isEmpty ? "0 张：先 LABELGUI_DATA_DIR=同一个目录 LabelGUI --analyze \(dir.path)" : "")
            // 竖的全身、半身、近景、亮背景各一张，横的三张，再加一张远处的全身（7216：不限拉近时巨字开篇拉近四倍多）；
            // photot 以外的文件夹按竖横各取前几张。
            let wanted = ["DSCF7207", "DSCF7221", "DSCF7232", "DSCF7209", "DSCF7229", "DSCF7224", "DSCF7225", "DSCF7216"]
            var chosen = wanted.compactMap { id in refs.first { $0.id == id } }
            if chosen.count < 3 {
                chosen = Array(refs.filter(\.isPortrait).prefix(3)) + Array(refs.filter { !$0.isPortrait }.prefix(2))
            }
            var photoMap: [String: CollagePhotoRef] = [:]
            for p in refs { photoMap[p.id] = p }
            var hints: [String: CollageCrop.Hints] = [:]
            for p in chosen { hints[p.id] = CollageVision.hints(for: p) }
            for t in templates {
                print("  -- \(t.name)")
                for p in chosen {
                    rendered(t, photo: p, photoMap: photoMap, hints: hints, check: check)
                }
            }
        } else {
            print("== 套真照片：没给照片文件夹，跳过（只验名字、红线、字体、占位符）")
        }

        print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    /// 一块字里的全部原文（每行、正文）。
    private static func texts(of text: CollageText) -> [String] {
        text.lines.map(\.text) + (text.body.map { [$0.text] } ?? [])
    }

    /// 一行字该守哪一档下限（R4 §A5）：铺满宽度的（刊头、巨字）= nil 不管；加字距的 Avenir = 装饰小字；
    /// 声明 ≥ 0.06 的 = 标题；其余 = 要读的字。
    private static func floor(of line: CollageTextLine) -> (Double, String)? {
        if line.fitWidth { return nil }
        if line.font == .avenir { return (0.024, "装饰") }
        if line.size >= 0.06 { return (0.06, "标题") }
        return (0.028, "要读")
    }

    /// 套一张照片：按实际排出来的字号核对下限；出图（1 倍、0.4）核对字块不叠、不压脸、在画布里、巨字的决定一致。
    @MainActor
    private static func rendered(_ template: CollageTemplate, photo: CollagePhotoRef,
                                 photoMap: [String: CollagePhotoRef], hints: [String: CollageCrop.Hints],
                                 check: (Bool, String, String) -> Void) {
        var project = CollageProject()
        project.photos = Array(photoMap.values)
        project.canvas = template.canvas ?? CollageCanvas.social[0]
        project.style = template.style ?? CollageStyle()
        let context = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap,
                                            hints: hints, heroID: nil)
        let page = CollageTemplates.apply(template, photos: [photo], context: context)
        project.pages = [page]
        let canvas = project.canvas
        let short = canvas.shortSide
        let vars = CollageTypeset.variables(project: project, root: page.root, photos: photoMap,
                                            pagePhotoIDs: page.photoIDs, pageID: page.id)
        let tag = "\(template.name) × \(photo.id)"

        // 字号：文字格、页脚图层按 draw 用的同一个 prepared 排（放不下缩过之后的字号），对声明的那一档。
        var low: [String] = []
        var smallest = Double.infinity
        func audit(_ text: CollageText, in rect: CGRect) {
            let laid = CollageTypeset.prepared(text, in: rect, short: short, vars: vars)
            for (orig, line) in zip(text.lines, laid.text.lines) {
                guard !CollageTypeset.lineString(orig, vars: vars).isEmpty, let (floor, kind) = floor(of: orig) else { continue }
                let actual: Double = line.size * laid.short / short
                smallest = min(smallest, actual)
                if actual < floor - 0.0005 {
                    low.append(String(format: "%@「%@」%.4f < %.3f", kind, CollageTypeset.lineString(orig, vars: vars), actual, floor))
                }
            }
            if let body = text.body {
                let actual: Double = body.size * laid.short / short
                if actual < 0.028 - 0.0005 { low.append(String(format: "正文 %.4f < 0.028", actual)) }
            }
        }
        let geo = CollageLayout.pageGeometry(page.root, canvas: canvas, style: project.style)
        for frame in geo.frames where frame.cell.kind == .text {
            if let text = frame.cell.text { audit(text, in: frame.rect.cgRect) }
        }
        for item in page.items where item.kind == .text {
            if let text = item.text { audit(text, in: CollageItems.bounds(item, canvas: canvas)) }
        }
        check(low.isEmpty, "\(tag) 字号守住社交画布下限", low.isEmpty ? String(format: "最小 %.4f S", smallest)
              : low.joined(separator: "；"))

        // 出图：1 倍（导出同款）和 0.4（预览同款）。
        func render(_ scale: Double) -> CollageRender.RenderReport {
            var opts = CollageRender.Options(scale: scale)
            opts.includeBleed = false
            opts.export = scale >= 1
            let report = CollageRender.RenderReport()
            opts.report = report
            _ = CollageRender.render(page: page, project: project, hints: hints, options: opts)
            return report
        }
        let full = render(1)
        let preview = render(0.4)
        let bounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        var overlaps: [String] = []
        let records = full.texts
        for i in records.indices {
            for j in records.indices where j > i {
                let a = records[i].rect.intersection(records[j].rect)
                if !a.isNull, a.width > 0.5, a.height > 0.5 {
                    overlaps.append("\(records[i].owner)×\(records[j].owner)")
                }
            }
        }
        check(overlaps.isEmpty, "\(tag) 字块两两不叠", overlaps.joined(separator: " "))
        let outside = records.filter { !bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) }.map(\.owner)
        check(outside.isEmpty, "\(tag) 字块都在画布里", outside.joined(separator: " "))
        // 压脸：照片按取景投到成品坐标的脸框（外扩过 15%）；人后的字本来就让人挡，不算。
        var onFace: [String] = []
        // 反过来的对照：人后的巨字确实碰到了脸框（头压进字里）—— 也顺带证明上面把脸投到成品坐标的算法没算错。
        var behindOnFace = false
        for crop in full.crops {
            guard let p = photoMap[crop.photoID], crop.window.width > 0, crop.window.height > 0 else { continue }
            for f in p.faces where f.count >= 4 {
                let sx: Double = Double(crop.drawn.width) / Double(crop.window.width)
                let sy: Double = Double(crop.drawn.height) / Double(crop.window.height)
                let x0: Double = Double(crop.drawn.minX) + (f[0] - Double(crop.window.minX)) * sx
                let y0: Double = Double(crop.drawn.minY) + (f[1] - Double(crop.window.minY)) * sy
                let face = CGRect(x: x0, y: y0, width: (f[2] - f[0]) * sx, height: (f[3] - f[1]) * sy)
                for t in records {
                    let a = t.rect.intersection(face)
                    guard !a.isNull, a.width > 0.5, a.height > 0.5 else { continue }
                    if t.layer == "behindSubject" { behindOnFace = true } else { onFace.append(t.owner) }
                }
            }
        }
        check(onFace.isEmpty, "\(tag) 人前的字不压脸", onFace.joined(separator: " "))
        // 取景：0.4 预览和导出取的是照片上同一块 —— 用户在编辑器里看到的就是导出的那一块。预览的格子按缩放取整，
        // 宽高差一两个像素，窗口跟着差千分之几；差到 1% 以上就是取景的决定变了（躲没躲路人）。
        var drift: [String] = []
        for c in full.crops {
            guard let q = preview.crops.first(where: { $0.owner == c.owner }) else { drift.append("\(c.owner) 预览没有"); continue }
            let d = max(abs(c.window.minX - q.window.minX), abs(c.window.minY - q.window.minY),
                        abs(c.window.width - q.window.width), abs(c.window.height - q.window.height))
            if d > 0.01 { drift.append(String(format: "%@ 差 %.3f", c.owner, Double(d))) }
        }
        check(drift.isEmpty, "\(tag) 0.4 预览和导出的取景一样", drift.joined(separator: " "))
        // 巨字开篇：封面取景不比这一格放得下的最大窗口拉近 1.6 倍以上（全身照不被拉成大头，蒙版不放大四五倍）。
        if let zoom = template.root.leaves.compactMap({ $0.overlays.first?.maxZoom }).first {
            for c in full.crops {
                guard let p = photoMap[c.photoID], c.drawn.height > 0 else { continue }
                let maxW = CollageCrop.maxWindow(photoAspect: p.aspect, cellAspect: Double(c.drawn.width / c.drawn.height))
                let ratio: Double = maxW.h / Double(c.window.height)
                check(ratio <= zoom + 0.01, "\(tag) 封面取景拉近不超过 \(zoom) 倍", String(format: "%.2f 倍", ratio))
            }
        }
        // 巨字开篇：人物挡字的决定，预览和导出一样。
        let decided = records.compactMap { t in t.occlusion.map { (t, $0) } }
        if let (t, o) = decided.first {
            let line = String(format: "%@ · %@ · 总 %.1f%% · 眼睛%@%@", t.layer, o.decision, o.total * 100,
                              o.eyesClear == false ? "被字压了" : "没被字压", o.reason.map { " · " + $0 } ?? "")
            print("      \(photo.id) 巨字：" + line)
            let previewOcc = preview.texts.compactMap(\.occlusion).first
            check(previewOcc?.decision == o.decision && preview.texts.first { $0.occlusion != nil }?.layer == t.layer,
                  "\(tag) 0.4 预览和导出的人物挡字决定一样", previewOcc.map { "\($0.decision) / \(o.decision)" } ?? "预览没有")
            check(o.eyesClear != false, "\(tag) 巨字不压眼睛", "")
            if t.layer == "behindSubject" {
                check(behindOnFace, "\(tag) 人在字前：脸框碰到人后的巨字（头压进字里）", "")
            }
        }
    }
}
