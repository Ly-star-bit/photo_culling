import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// LABELGUI_DATA_DIR=<临时> LabelGUI --newspaper-selftest [photo_dir]（报纸风 K4 的自检；photo_dir 先 --analyze 过）
///
/// 1. 简转繁（Hans-Hant）：报 / 讯 / 摄 / 腊 / 闰这些一对一的字；已经是繁体的「農曆」「公曆」不再变（模板里的固定字
///    直接写的繁体）；转换缓存两次结果一样。
/// 2. 右起横排：字序倒过来，西文、数字一段不拆（Vol.2、ISO 125），括号换成反向的；画出来第一个字（原文）在最右边。
/// 3. 正文繁体：占位符展开之后再转（臘月、閏）；空正文仍是灰条。
/// 4. 模板名「报纸风 · 」打头、全库唯一、分类「报纸风」，名字和分类不含别的分类名；所有默认字（模板名、每一行、正文、
///    预设名）展开前后都没有真实刊名 / 胶片牌子 / 刊号（CN xx-xxxx、ISSN、刊号）；刊头自检（mastheadLooksReal）不报。
/// 5. 默认正文里的数字全来自占位符（去掉 {…} 之后没有阿拉伯数字）—— 不编张数、不编日期。
/// 6. 读不到 EXIF 的照片（合成：文件不存在）：器材、焦距、光圈、快门、感光度每一项都是「未记录」，没有半句、没有残留的 {
///    （民国竖排的正文不放器材，一处「未記錄」都没有）。
///    相机来的值（机型、参数）里的连字符、斜杠夹了不断行符（X-T50、1/2000 不断行），模板的字、用户打的 {subtitle}
///    不动，不断行符画出来没有墨、不占宽；
///    新键 {issue_n}（不补零）、{issue_cn} / {count_cn}（中文数字）按页码、填的期号算对。
///    照片连拍摄时间也没有：四个模板的字、正文都不剩半句、孤字（「，，」「农历　」「No. 1 · , ,」），今日头版
///    通栏标题是「影像纪事」、导语从「本期题为」起，英文复古日期行只剩「No. 1」；
///    今日头版报头下面的小字：中文标题印拼音、西文标题（刊头 = 标题大写）不重复印、填了刊头照印。
/// 7. 最长的数据（合成：12 月 28 日、闰冬月廿九、11 个字的标题、iPhone 15 Pro Max、1/32000、ISO 102400、第 128 期）
///    在每个模板的正文格里按成品尺寸也排得下：只有正文的横排格，在同宽、高一倍的格子里画出来上面那截一模一样、
///    下面没有墨（一个字没少；今日头版的 5 栏平衡分栏在两个格子里分得一样 = 原格里也是平衡排的，没退回一栏排满）；
///    带标题行的、竖排的格子，后面再接一段字画出来会变（还有地方）。
/// 8. 民国竖排的正文从右往左排：只排几列字时墨都在右边，左边空着。
/// 9. 细线框（报眼）：量尺寸四边各多一份退让、框线真画在格子边上、字形都在框里。
/// 10. 网点：每个模板导出时点距 ≥ 3 像素（出点）；0.4 倍预览按点距换算（不到 3 像素只调影调）；点距跟着渲染缩放走。
/// 11. 平衡分栏（合成的字）：13 行排 5 栏，各栏 3 / 3 / 3 / 2 / 2 行（最多最少差一行）；不平衡时照旧前几栏排满；
///     10 行 = 每栏 2 行；比栏数少的行一栏一行；竖排两条横带也平均分；原字号装不下时字号缩到排得下（照样平衡）；
///     缩到最小也装不下时退回一栏排满。
/// 12. 给了照片文件夹（真照片，photot 是一个模特、一天）：四个模板各套一次，「本报讯」里的日期、星期、机型、ISO、张数
///     （民国竖排另有干支）和独立读出来的照片信息逐项对得上（机型、ISO、实际焦距 FocalLength、光圈按 ImageIO 直接读
///     这一页评分最高那张，35mm 等效焦距不能当「焦距」印出来；张数 = 这一页上的照片）；每张照片都加了网、出了点；
///     印出来的字没有真实刊名、刊号；民国竖排的正文里没有西文、阿拉伯数字（竖排里会一个个立着排）。
/// 全过退出 0，否则 1。
enum CollageStyleNewspaperSelfTest {

    @MainActor
    static func run(flagIndex: Int) -> Never {
        // 自检不碰界面；main.swift 的无头名单里没有这个参数，这里自己设上。
        AppRuntime.headless = true
        // 真照片那一段要切场次（BatchStore 会写 sessions.json）：和别的自检一样，必须指着一份拷出来的数据目录。
        CollageCLI.requireIsolatedDataDir("--newspaper-selftest")
        let args = CommandLine.arguments
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "  通过 " : "  失败 ") + name + (detail.isEmpty ? "" : " · " + detail))
            if !ok { failures.append(name) }
        }
        let paper = CollageStyleNewspaper.self

        // ---------------------------------------------------------------- 1. 简转繁
        print("== 简转繁")
        let hant = CollageTypeset.traditional("本报讯 摄影 腊月 闰六月 春日汉服 写真集")
        check(hant == "本報訊 攝影 臘月 閏六月 春日漢服 寫真集", "Hans-Hant 一对一的字", hant)
        check(CollageTypeset.traditional("農曆 公曆 第01期") == "農曆 公曆 第01期", "已经是繁体的不再变（農曆、公曆）")
        check(CollageTypeset.traditional("本报讯") == CollageTypeset.traditional("本报讯"), "缓存两次一样")
        check(CollageTypeset.traditional("X-T50 ISO 125") == "X-T50 ISO 125", "没有汉字的原样")

        // ---------------------------------------------------------------- 2. 右起横排
        print("== 右起横排")
        let rtl: [(String, String)] = [("拾光", "光拾"), ("拾光 Vol.2", "Vol.2 光拾"), ("《拾光》", "《光拾》"),
                                       ("第12期", "期12第"), ("感光度ISO 125", "ISO 125度光感")]
        for (a, b) in rtl {
            let got = CollageTypeset.rightToLeft(a)
            check(got == b, "右起「\(a)」", got)
        }
        let band = CollageTextLine("{title}", font: .songtiTC, weight: .bold, size: 0.06, color: .ink)
        var bandLine = band
        bandLine.textCase = .traditionalRTL
        check(CollageTypeset.lineString(bandLine, vars: ["title": "春日汉服"]) == "服漢日春", "标题条：繁体再右起",
              CollageTypeset.lineString(bandLine, vars: ["title": "春日汉服"]))
        // 画出来：原文第一个字（拾）的字形在最右边。
        let bandText = CollageText(lines: [bandLine], vertical: false, alignH: .center, alignV: .center)
        let glyphs = CollageTypeset.glyphOutlines(bandText, in: CGRect(x: 0, y: 0, width: 600, height: 200), short: 1000,
                                                  vars: ["title": "拾光"])
        let shiAlone = CollageTypeset.glyphOutlines(
            CollageText(lines: [CollageTextLine("拾", font: .songtiTC, weight: .bold, size: 0.06, color: .ink)],
                        vertical: false, alignH: .center, alignV: .center),
            in: CGRect(x: 0, y: 0, width: 600, height: 200), short: 1000, vars: [:])
        let rightmost = glyphs.max { $0.bounds.midX < $1.bounds.midX }
        let shiArea = shiAlone.first.map { Double($0.bounds.width * $0.bounds.height) } ?? 0
        let rightArea = rightmost.map { Double($0.bounds.width * $0.bounds.height) } ?? -1
        check(glyphs.count == 2 && abs(shiArea - rightArea) < 1, "画出来「拾」在最右边",
              String(format: "%d 个字形，最右那个墨框 %.0f / 拾 %.0f", glyphs.count, rightArea, shiArea))

        // ---------------------------------------------------------------- 3. 正文繁体
        print("== 正文繁体")
        var tb = CollageBody(text: "本报讯　{lunar}", columns: 1)
        tb.traditional = true
        check(CollageTypeset.bodyText(tb, vars: ["lunar": "腊月初八"]) == "本報訊　臘月初八", "正文占位符展开后再转",
              CollageTypeset.bodyText(tb, vars: ["lunar": "腊月初八"]))
        var empty = tb
        empty.text = "{subtitle}"
        check(CollageTypeset.bodyKind(empty, vars: [:]) == "bars", "空正文仍是灰条")

        // ---------------------------------------------------------------- 4. 名字、真实刊名、刊号
        print("== 模板名、默认字")
        let mine = paper.templates
        let names = mine.map(\.name)
        let all = CollageTemplates.builtin
        check(mine.count == 4, "四个模板", names.joined(separator: " / "))
        check(names.allSatisfy { $0.hasPrefix("报纸风 · ") }, "名字「报纸风 · 」打头")
        check(names.allSatisfy { n in all.filter { $0.name == n }.count == 1 }, "全库唯一")
        check(mine.allSatisfy { $0.category == "报纸风" && $0.builtin }, "分类「报纸风」、内置")
        let others = ["小红书封面", "日系杂志", "中式", "九宫格", "手账散落", "电影感", "基础", "时尚刊", "底片印样", "留白杂志",
                      "瑞士网格", "婚礼相册"]
        let clash = mine.flatMap { t in others.filter { t.name.contains($0) || t.category.contains($0) } }
        check(clash.isEmpty, "名字、分类不含别的分类名", clash.joined(separator: " "))
        check(all.filter { $0.category.contains("报纸风") || $0.name.contains("报纸风") }.count == 4,
              "--only 报纸风 只挑出这四个")
        var literals = names + paper.presets.map(\.name)
        for t in mine {
            for cell in t.root.leaves {
                guard let text = cell.text else { continue }
                literals += text.lines.map(\.text)
                if let body = text.body { literals.append(body.text) }
            }
        }
        // 展开之后也查（标题空 = 拾光，刊头 = SHIGUANG；有照片文件夹时下面第 11 段再用真 EXIF 查一遍）。
        let sample = sampleVariables()
        let expanded = literals.map { CollageTypeset.fill($0, vars: sample) }
        let banned = bannedHits(literals + expanded)
        check(banned.isEmpty, "没有真实刊名、胶片牌子、刊号", banned.joined(separator: " / "))
        check(!CollageTypeset.mastheadLooksReal(masthead: "", title: ""), "默认刊头不像真实刊名",
              CollageTypeset.mastheadText("", title: "拾光"))

        // ---------------------------------------------------------------- 5. 数字只来自占位符
        print("== 默认正文的数字")
        let copies = [("今日头版", paper.frontCopy), ("民国竖排", paper.minguoCopy), ("英文复古", paper.englishCopy)]
        for (name, copy) in copies {
            let bare = copy.replacingOccurrences(of: "\\{[^{}]*\\}", with: "", options: .regularExpression)
            let digits = bare.filter { $0.isASCII && $0.isNumber }
            check(digits.isEmpty, "\(name)：去掉占位符后没有数字", digits.isEmpty ? "" : String(digits))
        }

        // ---------------------------------------------------------------- 6. 读不到 EXIF
        print("== 读不到 EXIF（合成：文件不存在）")
        let missing = syntheticVariables(path: "/nonexistent/newspaper-selftest.jpg")
        for (name, copy) in copies {
            let s = CollageTypeset.fill(copy, vars: missing)
            let unrecorded = s.components(separatedBy: name == "英文复古" ? "unrecorded" : (name == "民国竖排" ? "未記錄" : "未记录")).count - 1
            let broken = ["{", "：；", "，，", "f/", "、、", "  ,"].filter { s.contains($0) }
            let want = name == "民国竖排" ? 0 : 5
            check(unrecorded == want && broken.isEmpty, "\(name)：缺的每一项都是「未记录」",
                  "\(unrecorded) 处" + (broken.isEmpty ? "" : "，半句 \(broken)"))
        }
        let shortDate = CollageTypeset.dateVariables(dateFromParts(2026, 3, 3))
        check(shortDate["day_n"] == "3" && shortDate["day"] == "03", "{day_n} 不补零（3 月 3 日）")
        // 照片也没有拍摄时间（截图、微信转过的图、「添加文件」进来的）：靠日期的那几段（[[…]]）整段不印 —— 不剩
        // 「本报讯　，，农历。」「农历 / 年」「农历　第1期」「No. 1 · , ,」「, .—」，通栏标题换成「影像纪事」。
        let undated = syntheticVariables(path: "/nonexistent/newspaper-selftest.jpg", dated: false)
        check(undated["date"] == nil && undated["lunar"] == nil && undated["weekday_cn"] == nil,
              "合成：没有拍摄时间（日期占位符都没有值）")
        let wjStrip = { (s: String) in s.replacingOccurrences(of: "\u{2060}", with: "") }
        let dangling = ["，，", "　，", "农历　", "农历。", "農曆　", "即公曆，", "— ,", "   ,", ", .", "·   ,", "影像里的"]
        for t in paper.templates {
            var printed: [String] = []
            for cell in t.root.leaves {
                guard let text = cell.text else { continue }
                printed += text.lines.map { wjStrip(CollageTypeset.lineString($0, vars: undated)) }
                if let body = text.body { printed.append(wjStrip(CollageTypeset.fillBody(body.text, vars: undated))) }
            }
            let lone: Set<String> = ["年", "農曆", "农历", "公曆", ",", "，", "·"]
            let bad = printed.filter { p in
                dangling.contains { p.contains($0) } || lone.contains(p.trimmingCharacters(in: .whitespaces))
                    || p.hasPrefix("，") || p.hasPrefix(",")
            }
            check(bad.isEmpty, "\(t.name)：没有拍摄时间不剩半句、孤字", bad.joined(separator: " | "))
        }
        let frontLines = paper.front.root.leaves.compactMap(\.text).flatMap { text in
            text.lines.map { wjStrip(CollageTypeset.lineString($0, vars: undated)) }
        }
        let frontBody = wjStrip(CollageTypeset.fillBody(paper.frontCopy, vars: undated))
        check(frontLines.contains("影像纪事") && frontLines.contains("第1期") && frontBody.hasPrefix("本报讯　本期题为"),
              "今日头版：通栏标题「影像纪事」、日期栏只剩「第1期」、导语从「本期题为」起",
              String(frontBody.prefix(16)) + " · " + frontLines.filter { !$0.isEmpty }.joined(separator: " / "))
        let englishBody = CollageTypeset.fillBody(paper.englishCopy, vars: undated)
        let englishLines = paper.english.root.leaves.compactMap(\.text).flatMap { text in
            text.lines.map { CollageTypeset.lineString($0, vars: undated) }
        }
        check(englishBody.hasPrefix("Photographs on this page") && englishLines.contains("No. 1"),
              "英文复古：日期行只剩「No. 1」、正文从「Photographs」起", String(englishBody.prefix(24)))

        // 报头下面那行小字（{masthead}，onlyWhenFilled = masthead_alt）：中文标题印拼音；西文标题没填刊头时刊头就是
        // 标题的大写，不再印一遍；自己填了别的刊头照印。
        func frontSub(title: String, masthead: String) -> String {
            var project = CollageProject()
            project.title = title
            project.masthead = masthead
            let vars = CollageTypeset.variables(project: project, root: .leaf(CollageCell()), photos: [:])
            let flag = paper.front.root.leaves.compactMap(\.text).first { $0.lines.contains { $0.text == "{title}" } }
            return flag.map { CollageTypeset.expandedLines($0, vars: vars).map(\.text).joined(separator: " ⏎ ") } ?? "—"
        }
        let subs = [frontSub(title: "拾光", masthead: ""), frontSub(title: "Spring Portraits", masthead: ""),
                    frontSub(title: "Spring Portraits", masthead: "Atelier Nord")]
        check(subs == ["拾光 ⏎ SHIGUANG", "Spring Portraits", "Spring Portraits ⏎ ATELIER NORD"],
              "今日头版报头：中文标题下面印拼音、西文标题不重复印一遍、填了刊头照印", subs.joined(separator: " | "))

        print("== 正文里的机型、参数不断行")
        let wj = "\u{2060}"
        let joinBody = CollageBody(text: "highest-rated {model}，{shutter}", columns: 1)
        let joined = CollageTypeset.bodyText(joinBody, vars: ["model": "X-T50", "shutter": "1/2000"])
        check(joined == "highest-rated X\(wj)-\(wj)T50，1\(wj)/\(wj)2000", "值里的 - / 夹不断行符、模板的字不动",
              joined.replacingOccurrences(of: wj, with: "⁀"))
        check(CollageTypeset.fill("{model}", vars: ["model": "X-T50"]) == "X-T50", "别处（行、水印）的占位符不加")
        let typedBody = CollageTypeset.bodyText(CollageBody(text: "{subtitle}", columns: 1),
                                                vars: ["subtitle": "日系/胶片/人像-旅拍"])
        check(typedBody == "日系/胶片/人像-旅拍", "用户打的字（{subtitle}）照常能断", typedBody)
        // 不断行符没有墨、不占宽：同一行字直接写和从占位符展开，画出来逐像素一样。
        var literal = CollageText(lines: [], vertical: false, alignH: .leading, alignV: .leading)
        literal.body = CollageBody(text: "器材X-T50，快门1/2000", columns: 1)
        literal.body?.size = 0.03
        var templated = literal
        templated.body?.text = "器材{model}，快门{shutter}"
        let wjVars = ["model": "X-T50", "shutter": "1/2000"]
        let inkLiteral = ink(literal, size: CGSize(width: 900, height: 120), short: 1000, vars: wjVars)
        let inkTemplated = ink(templated, size: CGSize(width: 900, height: 120), short: 1000, vars: wjVars)
        check(inkLiteral != nil && inkLiteral == inkTemplated, "不断行符画出来不占地方、没有字形")

        print("== 期号、张数")
        let counts: [(Int, String)] = [(0, "〇"), (7, "七"), (12, "十二"), (20, "二十"), (105, "一百零五"), (110, "一百一十"),
                                       (128, "一百二十八"), (1005, "一千零五"), (2010, "二千零一十")]
        let wrongCounts = counts.filter { CollageTypeset.chineseCount($0.0) != $0.1 }.map { "\($0.0)→\(CollageTypeset.chineseCount($0.0))" }
        check(wrongCounts.isEmpty, "中文数字（一百零五、一百一十、一千零五）", wrongCounts.joined(separator: " "))
        let page1 = CollageTypeset.variables(project: CollageProject(), root: CollageNode.leaf(CollageCell()), photos: [:])
        check(page1["issue"] == "01" && page1["issue_n"] == "1" && page1["issue_cn"] == "一" && page1["count_cn"] == "〇",
              "没填期号：{issue} 01 · {issue_n} 1 · {issue_cn} 一",
              "\(page1["issue"] ?? "") · \(page1["issue_n"] ?? "") · \(page1["issue_cn"] ?? "")")
        var typed = CollageProject()
        typed.issue = "007"
        let typedVars = CollageTypeset.variables(project: typed, root: CollageNode.leaf(CollageCell()), photos: [:])
        typed.issue = "春季号"
        let wordVars = CollageTypeset.variables(project: typed, root: CollageNode.leaf(CollageCell()), photos: [:])
        check(typedVars["issue_n"] == "7" && typedVars["issue_cn"] == "七" && wordVars["issue_n"] == "春季号"
              && wordVars["issue_cn"] == "春季号", "填了期号：007 → 7 / 七；春季号原样")

        // ---------------------------------------------------------------- 7. 最长的数据也排得下
        print("== 最长的数据（合成）")
        var worst = sample
        let worstValues: [String: String] = [
            "date_cn_full": "二〇二六年十二月二十八日", "weekday_cn": "星期三", "lunar": "闰冬月廿九", "ganzhi": "丙午",
            "count": "12", "model": "iPhone 15 Pro Max", "focal": "1200mm", "fnumber": "22.0", "shutter": "1/32000",
            "iso": "102400", "title": "春日汉服写真集·第二辑", "issue": "128", "masthead": "ATELIER NORD SPRING",
            "month_en_title": "September", "day_n": "28", "year": "2026", "weekday_en": "WEDNESDAY",
            "focal_mm": "1200mm", "fstop": "f/22.0", "issue_n": "128", "issue_cn": "一百二十八", "count_cn": "十二",
        ]
        for (k, v) in worstValues { worst[k] = v }
        for t in mine {
            let canvas = t.canvas ?? CollageCanvas()
            let style = t.style ?? CollageStyle()
            let frames = CollageLayout.pageGeometry(t.root, canvas: canvas, style: style).frames
            for frame in frames {
                guard let text = frame.cell.text, let body = text.body, !body.text.isEmpty else { continue }
                let size = frame.rect.cgRect.size
                if text.lines.isEmpty, !body.vertical {
                    // 只有正文的横排格：同宽、高一倍的格子里正文照样从顶上排，上面那截一样、下面没墨 = 原格里一个字没少。
                    // 栏线和格子一样高（高一倍的格子里会伸到下半截），比的时候不画栏线。
                    var text = text
                    text.body?.columnRule = false
                    let w = Int(size.width.rounded())
                    let h = Int(size.height.rounded())
                    let base = ink(text, size: CGSize(width: w, height: h), short: canvas.shortSide, vars: worst)
                    let tall = ink(text, size: CGSize(width: w, height: 2 * h), short: canvas.shortSide, vars: worst)
                    var fits = false
                    var spare = 0
                    if let base, let tall, tall.count == 2 * base.count {
                        let below = tall[base.count...]
                        fits = Array(tall[..<base.count]) == base && below.allSatisfy { $0 > 200 }
                        // 最后一行墨的下面还剩几像素（报告里看格子留得紧不紧）。
                        var lastInk = 0
                        for y in 0..<h where (0..<w).contains(where: { base[y * w + $0] < 128 }) { lastInk = y }
                        spare = h - 1 - lastInk
                    }
                    check(fits, "\(t.name)：正文排得下（一字不少）", "格子 \(w)×\(h) · 最后一行下面空 \(spare) px")
                    continue
                }
                let base = ink(text, size: size, short: canvas.shortSide, vars: worst)
                var more = text
                more.body?.text = body.text + (body.vertical || body.font.isChinese ? "\n囗囗囗囗" : "\nMMMM MMMM")
                let extended = ink(more, size: size, short: canvas.shortSide, vars: worst)
                check(base != nil && base != extended, "\(t.name)：正文排得下", String(format: "格子 %.0f×%.0f", size.width, size.height))
            }
        }

        // ---------------------------------------------------------------- 8. 竖排从右往左
        print("== 民国竖排正文的方向")
        var vbody = CollageBody(text: "本報訊　二〇二六年三月二十一日，星期六。本版刊圖四幀。", columns: 1)
        vbody.vertical = true
        vbody.font = .songtiTC
        vbody.size = 0.03
        vbody.traditional = true
        var vtext = CollageText(lines: [], vertical: true, alignH: .trailing, alignV: .leading)
        vtext.body = vbody
        if let px = ink(vtext, size: CGSize(width: 900, height: 500), short: 1000, vars: [:]) {
            let thirds = inkByThirds(px, width: 900, height: 500)
            check(thirds.right > 0 && thirds.left == 0, "竖排正文从右边起排",
                  String(format: "墨：右 %d · 中 %d · 左 %d", thirds.right, thirds.middle, thirds.left))
        } else {
            check(false, "竖排正文从右边起排", "画不出来")
        }

        // ---------------------------------------------------------------- 9. 细线框
        print("== 细线框（报眼）")
        var boxed = CollageText(lines: [CollageTextLine("星期六", font: .songti, weight: .bold, size: 0.03, color: .ink)],
                                vertical: false, alignH: .center, alignV: .center)
        boxed.rule = true
        boxed.ruleStyle = .box
        var plain = boxed
        plain.rule = false
        let mBox = CollageTypeset.measure(boxed, short: 1000, vars: [:])
        let mPlain = CollageTypeset.measure(plain, short: 1000, vars: [:])
        let padW = Double(mBox.width - mPlain.width) / 2
        let padH = Double(mBox.height - mPlain.height) / 2
        check(padW > 15 && abs(padW - padH) < 0.01, "量尺寸四边各多一份退让", String(format: "%.1f / %.1f px", padW, padH))
        let boxRect = CGRect(x: 0, y: 0, width: 300, height: 160)
        if let px = ink(boxed, size: boxRect.size, short: 1000, vars: [:]) {
            // 上边框那一行、左边框那一列都是墨；正中一行的左右边上也是。
            let top = (20..<280).allSatisfy { px[$0] < 128 }
            let left = (20..<140).allSatisfy { px[$0 * 300] < 128 }
            check(top && left, "框线画在格子边上")
        } else {
            check(false, "框线画在格子边上", "画不出来")
        }
        let inner = boxRect.insetBy(dx: CGFloat(padW * 0.95), dy: CGFloat(padH * 0.95))
        let outlines = CollageTypeset.glyphOutlines(boxed, in: boxRect, short: 1000, vars: [:])
        check(!outlines.isEmpty && outlines.allSatisfy { inner.contains($0.bounds) }, "字形都在框里",
              "\(outlines.count) 个字形")

        // ---------------------------------------------------------------- 10. 网点
        print("== 网点点距")
        for t in mine {
            guard let ht = t.style?.halftone, let canvas = t.canvas else {
                check(false, "\(t.name)：开了网点")
                continue
            }
            let export = CollageScreening.spec(ht, canvas: canvas, scale: 1, background: t.style?.background ?? .paper)
            let preview = CollageScreening.spec(ht, canvas: canvas, scale: 0.4, background: t.style?.background ?? .paper)
            let ratio = (preview?.pitchPx ?? 0) / max(1e-9, export?.pitchPx ?? 1)
            let screenedPreview = preview?.screened ?? false
            check((export?.screened ?? false) && abs(ratio - 0.4) < 1e-9, "\(t.name)：导出出点、点距跟着缩放",
                  String(format: "%@ 导出 %.2f px · 0.4 预览 %.2f px（%@）", ht.screen.label, export?.pitchPx ?? 0,
                         preview?.pitchPx ?? 0, screenedPreview ? "出点" : "只调影调"))
        }
        if let a4 = CollageCanvas.social.first(where: { $0.isPrint }), let ht = paper.frontStyle.halftone {
            let spec = CollageScreening.spec(ht, canvas: a4, scale: 1, background: paper.paper)
            check(spec?.screened ?? false, "「报纸」预设套到 A4：出点", String(format: "%.1f px", spec?.pitchPx ?? 0))
        }

        // ---------------------------------------------------------------- 11. 平衡分栏
        print("== 平衡分栏（合成的字）")
        balancedColumns(check: check)

        // ---------------------------------------------------------------- 12. 真照片
        if args.count > flagIndex + 1, !args[flagIndex + 1].hasPrefix("--") {
            realPhotos(URL(fileURLWithPath: args[flagIndex + 1]), check: check)
        }

        print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项：" + failures.joined(separator: "；"))
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - 真照片

    @MainActor
    private static func realPhotos(_ dir: URL, check: (Bool, String, String) -> Void) {
        let batch = BatchStore(dataDir: appDataDir, pythonRoot: appConfig.resolvedPythonRoot(dataDir: appDataDir))
        batch.switchSession(to: dir)
        let facts = CollageBridge.Facts(batch: batch)
        let refs = batch.items.filter { $0.verdict != .reject }.compactMap { CollageBridge.ref(from: $0, facts: facts) }
        print("== 真照片 \(refs.count) 张（\(dir.lastPathComponent)）")
        check(!refs.isEmpty, "照片文件夹分析过（拿得到照片）", refs.isEmpty ? "先 --analyze" : "")
        guard !refs.isEmpty else { return }
        var photoMap: [String: CollagePhotoRef] = [:]
        for p in refs { photoMap[p.id] = p }
        let paper = CollageStyleNewspaper.self
        let copies: [String: String] = ["报纸风 · 今日头版": paper.frontCopy, "报纸风 · 民国竖排": paper.minguoCopy,
                                        "报纸风 · 英文复古": paper.englishCopy]
        for t in paper.templates {
            var project = CollageProject()
            project.photos = refs
            project.canvas = t.canvas ?? CollageCanvas()
            project.style = t.style ?? CollageStyle()
            let context = CollageLayout.Context(canvas: project.canvas, style: project.style, photos: photoMap,
                                                hints: [:], heroID: nil)
            let page = CollageTemplates.apply(t, photos: refs, context: context)
            project.pages = [page]
            let onPage = page.photoIDs.compactMap { photoMap[$0] }
            let vars = CollageTypeset.variables(project: project, root: page.root, photos: photoMap,
                                                pagePhotoIDs: page.photoIDs, pageID: page.id)
            // 独立读：这一页评分最高那张的机型、ISO（ImageIO 直接读，不走占位符）；最早那张的星期（系统日历）。
            let hero = onPage.max { $0.score < $1.score }
            let exif = hero.flatMap { exifFacts($0.path) }
            // 实际焦距（镜头上的那个数）、35mm 等效、光圈：同样直接读。
            let lens = hero.flatMap { lensFacts($0.path) }
            let first = onPage.compactMap(\.captureTime).min()
            let weekday = first.map { weekdayCN($0) } ?? ""
            if let copy = copies[t.name] {
                var s = CollageTypeset.fill(copy, vars: vars)
                if t.name.contains("民国") { s = CollageTypeset.traditional(s) }
                // 「第 1 期」「4 幅」中间的不断行符（不占宽、没有字形）不算字。
                s = s.replacingOccurrences(of: "\u{2060}", with: "")
                let english = t.name.contains("英文")
                var missing: [String] = []
                if t.name.contains("民国") {
                    // 竖排正文里西文、阿拉伯数字会一个个立着排：一个都不该有（标题是默认的「拾光」）。
                    let latin = s.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) }
                    if !latin.isEmpty { missing.append("竖排里的西文 \(String(String.UnicodeScalarView(latin)))") }
                } else if let model = exif?.model, !s.contains(model) { missing.append("机型 \(model)") }
                if !english, let iso = exif?.iso, !t.name.contains("民国"), !s.contains("感光度\(iso)") { missing.append("ISO \(iso)") }
                if english, let iso = exif?.iso, !s.contains("ISO, \(iso)") { missing.append("ISO \(iso)") }
                if !t.name.contains("民国"), let lens {
                    let focalLabel = english ? "focal length, \(lens.focal)" : "焦距\(lens.focal)"
                    if !s.contains(focalLabel) { missing.append("实际焦距 \(lens.focal)") }
                    // 35mm 等效和实际不一样时（APS-C），等效那个数不能印在「焦距」后面。
                    if let eq = lens.equivalent, eq != lens.focal,
                       s.contains(english ? "focal length, \(eq)" : "焦距\(eq)") { missing.append("把等效 \(eq) 当焦距") }
                    if let f = lens.fstop, !s.contains(english ? "aperture, \(f)" : "光圈\(f)") { missing.append("光圈 \(f)") }
                }
                if !english, !weekday.isEmpty, !s.contains(weekday) { missing.append(weekday) }
                // 民国竖排的张数是中文数字（自己查表，不走 chineseCount）。
                let cn = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
                let countCN = onPage.count < cn.count ? cn[onPage.count] : "\(onPage.count)"
                let countText = english ? "Photographs on this page: \(onPage.count)." : (t.name.contains("民国")
                    ? "刊圖\(countCN)幀" : "本版刊图\(onPage.count)幅")
                if !s.contains(countText) { missing.append("张数 \(onPage.count)") }
                // photot 的拍摄日（S1 核过的那天）：日期、农历、干支逐字对。
                if let first, Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: first)
                    == DateComponents(year: 2026, month: 3, day: 21) {
                    let want = english ? ["March 21, 2026"]
                        : ["二〇二六年三月二十一日", "二月初三"] + (t.name.contains("民国") ? ["丙午"] : [])
                    missing += want.filter { !s.contains($0) }
                }
                let banned = bannedHits([s])
                let lensNote = lens.map { "焦距 \($0.focal)（等效 \($0.equivalent ?? "无")）· \($0.fstop ?? "无光圈") · " } ?? ""
                check(missing.isEmpty && banned.isEmpty, "\(t.name)：本报讯每一项和照片对得上",
                      "张数 \(onPage.count) · \(exif?.model ?? "无机型") · " + lensNote
                        + (missing.isEmpty ? "" : "对不上 \(missing) ") + (banned.isEmpty ? "" : "刊名 \(banned)"))
                print("    " + s.replacingOccurrences(of: "\n", with: " ⏎ "))
            }
            // 每一格的照片都有（模板格数 ≤ 托盘张数），网点都出了点。
            var opts = CollageRender.Options(scale: 1)
            opts.includeBleed = false
            let report = CollageRender.RenderReport()
            opts.report = report
            _ = CollageRender.render(page: page, project: project, hints: [:], options: opts)
            let screened = report.halftone.allSatisfy { $0.screened }
            check(!report.halftone.isEmpty && screened && report.halftone.count == onPage.count, "\(t.name)：每张照片都加了网",
                  "\(report.halftone.count) 张 · 点距 " + String(format: "%.2f px", report.halftone.first?.pitchPx ?? 0))
            let texts = report.texts.map { $0.lines.joined(separator: " ") }
            let banned = bannedHits(texts)
            check(banned.isEmpty, "\(t.name)：印出来的字没有真实刊名、刊号", banned.joined(separator: " / "))
        }
    }

    // MARK: - 平衡分栏

    /// 合成的正文：每段正好 10 个「囗」= 一行（不缩进，栏宽 10.25 个字），几段就是几行；数每一栏画出来几行墨。
    private static func balancedColumns(check: (Bool, String, String) -> Void) {
        let short = 1000.0
        let size = 0.02
        let pitch: Double = 1.6 * size * short
        let colW = 205.0
        let gapPx: Double = size * short
        func body(_ lines: Int, columns: Int, balanced: Bool, vertical: Bool = false) -> CollageText {
            var b = CollageBody(text: Array(repeating: "囗囗囗囗囗囗囗囗囗囗", count: lines).joined(separator: "\n"),
                                columns: columns)
            b.size = size
            b.leading = 1.6
            b.firstLineIndent = 0
            b.gap = 1
            b.justified = false
            b.vertical = vertical
            b.balanced = balanced
            var t = CollageText(lines: [], vertical: vertical, alignH: .leading, alignV: .leading)
            t.body = b
            return t
        }
        // 横排 5 栏：每栏几行（一段段有墨的行，中间隔着空行）。
        let width: Double = 5 * colW + 4 * gapPx
        func perColumn(_ text: CollageText, rows: Double) -> [Int]? {
            let w = Int(width.rounded())
            let h = Int((rows * pitch).rounded())
            guard let px = ink(text, size: CGSize(width: w, height: h), short: short, vars: [:]) else { return nil }
            return (0..<5).map { c in
                let x0 = Int((Double(c) * (colW + gapPx)).rounded())
                let x1 = min(w, x0 + Int(colW))
                var runs = 0
                var inside = false
                for y in 0..<h {
                    let hit = (x0..<x1).contains { px[y * w + $0] < 128 }
                    if hit && !inside { runs += 1 }
                    inside = hit
                }
                return runs
            }
        }
        let cases: [(lines: Int, rows: Double, balanced: Bool, want: [Int], name: String)] = [
            (13, 10, true, [3, 3, 3, 2, 2], "13 行平衡：3 / 3 / 3 / 2 / 2"),
            (13, 10, false, [10, 3, 0, 0, 0], "13 行不平衡：照旧前面排满"),
            (10, 3.5, true, [2, 2, 2, 2, 2], "10 行平衡：每栏 2 行"),
            (3, 3.5, true, [1, 1, 1, 0, 0], "3 行平衡：一栏一行"),
        ]
        for c in cases {
            let got = perColumn(body(c.lines, columns: 5, balanced: c.balanced), rows: c.rows)
            check(got == c.want, c.name, got.map { $0.map(String.init).joined(separator: " / ") } ?? "画不出来")
        }
        // 原字号装不下（13 行、每栏只放得下 2 行）：字号缩到排得下（最多缩到 75%，CollageTypeset.fittedBody），
        // 缩完照样平衡分栏，13 行一行不少。
        let shrunk = perColumn(body(13, columns: 5, balanced: true), rows: 2.5)
        check(shrunk == [3, 3, 3, 2, 2], "原字号装不下：字号缩到排得下、照样平衡（13 行一行不少）",
              shrunk.map { $0.map(String.init).joined(separator: " / ") } ?? "画不出来")
        // 缩到 75% 也装不下（每栏只有 1.2 行高）：退回一栏排满，和不平衡画得一模一样。
        let w = Int(width.rounded())
        let h = Int((1.2 * pitch).rounded())
        let tight = ink(body(13, columns: 5, balanced: true), size: CGSize(width: w, height: h), short: short, vars: [:])
        let plain = ink(body(13, columns: 5, balanced: false), size: CGSize(width: w, height: h), short: short, vars: [:])
        check(tight != nil && tight == plain, "缩到最小也装不下时退回一栏排满（和不平衡一样）", "")
        // 竖排两条横带：7 列平均分成 4 / 3（每条带从右往左数有墨的列）。
        let bandH: Double = colW
        let vh = Int((2 * bandH + gapPx).rounded())
        let vw = Int((10 * pitch).rounded())
        func perBand(_ text: CollageText) -> [Int]? {
            guard let px = ink(text, size: CGSize(width: vw, height: vh), short: short, vars: [:]) else { return nil }
            return (0..<2).map { b in
                let y0 = Int((Double(b) * (bandH + gapPx)).rounded())
                let y1 = min(vh, y0 + Int(bandH))
                var runs = 0
                var inside = false
                for x in 0..<vw {
                    let hit = (y0..<y1).contains { px[$0 * vw + x] < 128 }
                    if hit && !inside { runs += 1 }
                    inside = hit
                }
                return runs
            }
        }
        let vBalanced = perBand(body(7, columns: 2, balanced: true, vertical: true))
        let vPlain = perBand(body(7, columns: 2, balanced: false, vertical: true))
        check(vBalanced == [4, 3] && vPlain == [7, 0], "竖排两条带：平衡 4 / 3，不平衡 7 / 0",
              "\(vBalanced ?? []) · \(vPlain ?? [])")
    }

    // MARK: - 工具

    /// 真实刊名、胶片牌子、刊号的样子（DESIGN §0.4）。短词按整词比（Excellent 里的 elle 不算）。
    static func bannedHits(_ strings: [String]) -> [String] {
        let words = ["VOGUE", "ELLE", "BAZAAR", "MUSE", "W", "GQ", "TIME", "KINFOLK", "CEREAL", "KODAK", "ILFORD", "PORTRA",
                     "ISSN"]
        var hits: [String] = []
        for s in strings {
            let upper = s.uppercased()
            let tokens = Set(upper.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            hits += words.filter { tokens.contains($0) }.map { "\($0) ← \(s)" }
            if upper.contains("FUJI") { hits.append("FUJI ← \(s)") }
            if s.contains("刊号") || s.contains("刊號") { hits.append("刊号 ← \(s)") }
            if upper.range(of: "CN\\s*\\d{2}\\s*-\\s*\\d{3,4}", options: .regularExpression) != nil { hits.append("CN 刊号 ← \(s)") }
        }
        return hits
    }

    /// 没有照片时的占位符（标题空 = 拾光、刊头 = SHIGUANG、期号 = 页码），外加一个固定日期。
    private static func sampleVariables() -> [String: String] {
        var vars = CollageTypeset.variables(project: CollageProject(), root: CollageNode.leaf(CollageCell()), photos: [:])
        for (k, v) in CollageTypeset.dateVariables(dateFromParts(2026, 3, 21)) { vars[k] = v }
        return vars
    }

    /// 合成的一页：一张照片，path 指向读不了 EXIF 的地方；dated = false 连拍摄时间也没有。
    private static func syntheticVariables(path: String, dated: Bool = true) -> [String: String] {
        var ref = CollagePhotoRef(id: "synthetic-noexif", path: path, width: 4000, height: 6000)
        ref.captureTime = dated ? dateFromParts(2026, 3, 21) : nil
        ref.score = 1
        var project = CollageProject()
        project.photos = [ref]
        let root = CollageNode.leaf(CollageCell.photo(ref.id, role: .hero))
        return CollageTypeset.variables(project: project, root: root, photos: [ref.id: ref])
    }

    private static func dateFromParts(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = 14
        return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    private static func weekdayCN(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    /// ImageIO 直接读机型、ISO（和占位符的读法无关）。
    private static func exifFacts(_ path: String) -> (model: String?, iso: String?)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first.map { "\($0)" }
        return (model, iso)
    }

    /// ImageIO 直接读实际焦距（FocalLength）、35mm 等效（FocalLenIn35mmFilm）、光圈，按正文的写法（36mm、f/4.5）。
    private static func lensFacts(_ path: String) -> (focal: String, equivalent: String?, fstop: String?)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        guard let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0 else { return nil }
        let text = focal < 10 ? String(format: "%.1fmm", focal) : String(format: "%.0fmm", focal)
        let eq = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int).map { "\($0)mm" }
        let f = (exif[kCGImagePropertyExifFNumber] as? Double).map { String(format: "f/%.1f", $0) }
        return (text, eq, f)
    }

    /// 一块字按成品尺寸画在白底灰度图上（左上原点，同 render(page:) 的翻法），返回像素；画不出来 = nil。
    private static func ink(_ text: CollageText, size: CGSize, short: Double, vars: [String: String]) -> [UInt8]? {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        CollageTypeset.draw(text, in: CGRect(x: 0, y: 0, width: w, height: h), ctx: ctx, short: short, vars: vars,
                            canvasHeight: h)
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        return Array(UnsafeBufferPointer(start: bytes, count: w * h))
    }

    /// 左 / 中 / 右三分之一里各有多少个墨点（< 128）。
    private static func inkByThirds(_ px: [UInt8], width: Int, height: Int) -> (left: Int, middle: Int, right: Int) {
        var counts = [0, 0, 0]
        for y in 0..<height {
            for x in 0..<width where px[y * width + x] < 128 {
                counts[min(2, x * 3 / width)] += 1
            }
        }
        return (counts[0], counts[1], counts[2])
    }
}
