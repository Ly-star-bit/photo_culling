import Foundation
import JavaScriptCore

// MARK: - 选片确认表自检（LabelGUI --proof-selftest，不读写数据目录、不开界面）
//
// 1. 页面脚本：用 JavaScriptCore 跑 ProofSheetPage 生成的那段 ES5（给 document / localStorage / clipboard 做个假的，
//    元素按 HTML 里真有的 id 建 —— 脚本找一个不存在的 id 就会在这里炸），点选、超套餐、写备注、复制、重开页面读回来。
// 2. 复制出来的那段文字原样喂给 ClientReply.resolve：认出的照片和备注要和页面上点的一样（来回一趟）。
// 3. ClientReply 的备注写法：「DSCF7207 修 3 处」不再把第 3 张认进来、「7207 7208」还是两张、全角标点原样留着……
enum ProofSheetSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            print("PASS " + name)
        } else {
            failures += 1
            let extra = detail()
            print("FAIL " + name + (extra.isEmpty ? "" : " → " + extra))
        }
    }

    static func run() -> Never {
        pageScript()
        replyNotes()
        extraChecks()
        print(failures == 0 ? "确认表自检全部通过" : "确认表自检 \(failures) 条没过")
        exit(failures == 0 ? 0 : 1)
    }

    /// 给 M06 等后面的检查留的口子（同一个 --proof-selftest 里跑）。
    private static func extraChecks() {}

    // MARK: 页面脚本（JavaScriptCore）

    static let sheetID = "20261104-101500"
    static let names = ["DSCF7207", "DSCF7208", "DSCF7209", "DSCF7210", "DSCF7211"]

    /// 一页确认表（图是 1 字节的假数据：脚本不看图）。
    static func page(quota: Int?) -> String {
        var cells = ""
        for (i, name) in names.enumerated() {
            cells += ProofSheetPage.cell(number: i + 1, id: name, pick: i == 0, jpeg: Data([0]))
        }
        return ProofSheetPage.html(title: "自检", sheetID: sheetID, count: names.count, date: "2026-11-04",
                                   cells: cells, quota: quota)
    }

    /// 假的 DOM：HTML 里有的 id 一个一个建出来，.cell 按 data-name / data-n 建。
    static func prelude(html: String, storage: String) -> String {
        let ids = matches(#"id="([^"]+)""#, in: html)
        let cells = matchPairs(#"class="cell" data-name="([^"]*)" data-n="([0-9]+)""#, in: html)
        var js = #"""
        var __byId = {}, __cells = [], __exec = false, __clip = null;
        function __El(id) { this.id = id; this.attrs = {}; this.style = {}; this.className = ""; this.textContent = ""; this.value = ""; this.onclick = null; }
        __El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
        __El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
        __El.prototype.focus = function () {};
        __El.prototype.select = function () {};
        __El.prototype.setSelectionRange = function () {};
        var __store = STORE;
        var document = {
          body: new __El("body"),
          getElementById: function (id) { return __byId[id] || null; },
          querySelectorAll: function (sel) { return sel === ".cell" ? __cells : []; },
          createElement: function () { return new __El(""); },
          execCommand: function () { return __exec; }
        };
        document.body.appendChild = function () {};
        document.body.removeChild = function () {};
        var localStorage = {
          getItem: function (k) { return Object.prototype.hasOwnProperty.call(__store, k) ? __store[k] : null; },
          setItem: function (k, v) { __store[k] = String(v); }
        };
        var window = { localStorage: localStorage, isSecureContext: true, event: null };
        var navigator = {};
        function setTimeout(f, ms) { return 1; }
        function clearTimeout(t) {}
        function __click(id) { var e = { stopped: false, stopPropagation: function () { this.stopped = true; } }; __byId[id].onclick(e); return e.stopped; }
        """#.replacingOccurrences(of: "STORE", with: storage)
        for id in ids { js += "\n__byId[\(jsString(id))] = new __El(\(jsString(id)));" }
        for (name, n) in cells {
            js += "\n(function () { var c = new __El(''); c.attrs['data-name'] = \(jsString(name)); c.attrs['data-n'] = \(jsString(n)); __cells.push(c); })();"
        }
        return js
    }

    static func script(in html: String) -> String {
        guard let start = html.range(of: "<script>"), let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex)
        else { return "" }
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// 一个跑着确认表脚本的 JS 环境；`storage` = localStorage 里原来有的（JSON 对象原文）。
    static func context(html: String, storage: String = "{}") -> JSContext? {
        guard let ctx = JSContext() else {
            check(false, "建得出 JavaScriptCore 环境")
            return nil
        }
        // 任何时候抛错（脚本本身、或者找不到元素）都算一条没过。
        ctx.exceptionHandler = { _, value in check(false, "页面脚本不抛错", value?.toString() ?? "?") }
        ctx.evaluateScript(prelude(html: html, storage: storage))
        let code = script(in: html)
        check(!code.isEmpty, "页面里找得到脚本")
        ctx.evaluateScript(code)
        return ctx
    }

    static func eval(_ ctx: JSContext, _ code: String) -> String {
        ctx.evaluateScript(code)?.toString() ?? "<nil>"
    }

    private static func pageScript() {
        let html = page(quota: 3)
        guard let ctx = context(html: html) else { return }
        check(eval(ctx, "document.body.className") == "js", "脚本跑起来（body 加上 js）")
        check(eval(ctx, "__byId['count'].textContent") == "已选 0 / 3 张", "套餐 3 张：底栏「已选 0 / 3 张」",
              eval(ctx, "__byId['count'].textContent"))
        // 选第 1、2、4、5 张（第 3 张 DSCF7209 不选：下面「修 3 处」那个 3 不能把它认进来）。
        ctx.evaluateScript("__cells[0].onclick(); __cells[1].onclick(); __cells[3].onclick();")
        check(eval(ctx, "__byId['count'].textContent") == "已选 3 / 3 张", "选满 3 张")
        ctx.evaluateScript("__cells[4].onclick();")
        check(eval(ctx, "__byId['count'].textContent") == "已选 4 / 3，超出 1 张", "选超了只提示「超出 1 张」",
              eval(ctx, "__byId['count'].textContent"))
        check(eval(ctx, "__byId['count'].className") == "over", "超出时底栏变色")
        check(eval(ctx, "__cells[4].className") == "cell on", "超出套餐也照样选上（不拦）")
        check(eval(ctx, "__byId['toast'].textContent").contains("超出套餐的 3 张"), "超出那一下有提示",
              eval(ctx, "__byId['toast'].textContent"))

        // 第 2 张写备注：点「写备注」不能把这张取消选中。
        check(eval(ctx, "__click('nb2')") == "true", "点「写备注」不往格子上冒（stopPropagation）")
        check(eval(ctx, "__cells[1].className") == "cell on", "写备注不改选中")
        check(eval(ctx, "__byId['note'].style.display") == "block", "备注框打开")
        check(eval(ctx, "__byId['note-name'].textContent") == names[1], "备注框写着是哪张")
        ctx.evaluateScript("__byId['note-text'].value = '  去掉后面的路人\\n脸瘦一点，修 3 处 '; __byId['note-save'].onclick();")
        let note = "去掉后面的路人 脸瘦一点，修 3 处"
        check(eval(ctx, "__byId['note'].style.display") == "none", "保存后备注框关上")
        check(eval(ctx, "__byId['nt2'].textContent") == ProofSheetPage.noteMarker + note, "格子下面显示备注（换行并成空格）",
              eval(ctx, "__byId['nt2'].textContent"))
        check(eval(ctx, "__byId['nb2'].textContent") == "改备注", "按钮变成「改备注」")
        let saved = eval(ctx, "__store['xuanpian-sheet-\(sheetID)-notes']")
        check(saved.contains("去掉后面的路人"), "备注存进 localStorage（单独一个键）", saved)

        // 写了又清空 = 删掉。
        ctx.evaluateScript("__click('nb4'); __byId['note-text'].value = '黑白'; __byId['note-save'].onclick();")
        ctx.evaluateScript("__click('nb4'); __byId['note-text'].value = '   '; __byId['note-save'].onclick();")
        check(eval(ctx, "__byId['nt4'].textContent") == "", "备注清空就删掉")
        // 取消不存。
        ctx.evaluateScript("__click('nb5'); __byId['note-text'].value = '不要了'; __byId['note-cancel'].onclick();")
        check(eval(ctx, "__byId['nt5'].textContent") == "", "取消不存备注")

        // 复制：剪贴板接口没有、execCommand 也不行 → 摆在框里让人长按复制。
        ctx.evaluateScript("__byId['copy'].onclick();")
        let copied = eval(ctx, "__byId['out'].value")
        let expected = ProofSheetPage.header + " " + sheetID + "\n" + names[0] + "\n" + names[1] + " "
            + ProofSheetPage.noteMarker + note + "\n" + names[3] + "\n" + names[4] + "\n"
        check(copied == expected, "复制的文字：一张一行，带备注的「文件名 备注：…」", copied.debugDescription)
        // 有剪贴板接口：提示里说超了几张、几张带备注。
        ctx.evaluateScript("navigator.clipboard = { writeText: function (t) { __clip = t; return { then: function (ok) { ok(); } }; } }; __byId['copy'].onclick();")
        check(eval(ctx, "__clip") == expected, "剪贴板里是同一段")
        check(eval(ctx, "__byId['toast'].textContent").hasPrefix("已复制 4 张的选择（超出套餐 1 张，1 张带备注）"),
              "复制后的提示说超出、带备注", eval(ctx, "__byId['toast'].textContent"))

        // 来回一趟：复制出来的这段原样导入。
        let r = ClientReply.resolve(copied, items: items(), sheets: [sheet(quota: 3)])
        check(r.ids == [names[0], names[1], names[3], names[4]], "导入认出的就是页面上点的四张（「修 3 处」不认第 3 张）",
              r.ids.joined(separator: " "))
        check(r.notes == [names[1]: note], "导入读回备注", r.notes.description)
        check(r.header == sheetID, "认出表号")
        let lines = ClientReply.summary(r, existing: [])
        check(lines.contains { $0.hasPrefix("带备注 1 张：\(names[1])「") }, "导入预览说几张带备注", lines.joined(separator: " / "))
        check(lines.contains("套餐含 3 张：这次认出 4 张，超出 1 张（加片）"), "导入预览说超出套餐", lines.joined(separator: " / "))

        // 重开页面：选择、备注都从 localStorage 读回来。
        let store = eval(ctx, "JSON.stringify(__store)")
        if let again = context(html: html, storage: store) {
            check(eval(again, "__byId['count'].textContent") == "已选 4 / 3，超出 1 张", "重开页面：选择读回来")
            check(eval(again, "__byId['nt2'].textContent") == ProofSheetPage.noteMarker + note, "重开页面：备注读回来")
            check(eval(again, "__byId['nb2'].textContent") == "改备注", "重开页面：按钮是「改备注」")
        }

        // 不设张数：和以前一样「已选 N 张」，复制的文字没有备注时和以前逐字一样。
        let plain = page(quota: nil)
        check(plain.contains("<span id=\"count\">已选 0 张</span>"), "不设张数：底栏初始「已选 0 张」")
        check(!plain.contains("套餐含"), "不设张数：页面上不提套餐")
        // 老页面存下的选择（只有选择那个键）照样读。
        let old = "{\"xuanpian-sheet-\(sheetID)\": \"[\\\"\(names[2])\\\"]\"}"
        if let ctx2 = context(html: plain, storage: old) {
            check(eval(ctx2, "__byId['count'].textContent") == "已选 1 张", "不设张数：读回老的选择、底栏「已选 1 张」",
                  eval(ctx2, "__byId['count'].textContent"))
            ctx2.evaluateScript("__cells[0].onclick(); __byId['copy'].onclick();")
            let text = eval(ctx2, "__byId['out'].value")
            let want = ProofSheetPage.header + " " + sheetID + "\n" + names[0] + "\n" + names[2] + "\n"
            check(text == want, "没写备注：复制的文字和以前一样（表号一行、一行一个文件名）", text.debugDescription)
            check(eval(ctx2, "__byId['count'].className") == "", "不设张数不变色")
        }
        // localStorage 一碰就抛（无痕、微信预览）也照样能点、能写备注、能复制。
        if let ctx3 = context(html: plain, storage: "{}") {
            ctx3.evaluateScript("localStorage.getItem = localStorage.setItem = function () { throw new Error('denied'); };")
            ctx3.evaluateScript("__cells[1].onclick(); __click('nb2'); __byId['note-text'].value = '黑白'; __byId['note-save'].onclick(); __byId['copy'].onclick();")
            check(eval(ctx3, "__byId['count'].textContent") == "已选 1 张", "存不了也照样能点")
            check(eval(ctx3, "__byId['out'].value").contains(names[1] + " " + ProofSheetPage.noteMarker + "黑白"),
                  "存不了也照样能写备注、复制")
        }
    }

    // MARK: ClientReply 的备注写法

    /// 40 张（DSCF7201…DSCF7240，确认表上 #n = DSCF72nn）+ 一张带空格的「IMG 0001.JPG」。
    static func items() -> [BatchItem] {
        var out = (1...40).map { n in item(String(format: "DSCF72%02d", n)) }
        out.append(item("IMG 0001"))
        // 页面脚本那段用的 DSCF7207…7211 也在这 40 张里。
        return out
    }

    static func item(_ id: String) -> BatchItem {
        let path = "/nonexistent/proof-selftest/\(id).JPG"
        return BatchItem(
            id: id, previewPath: "", rawPath: path, decodePath: path, sharpness: 0, worstClipPct: 0,
            eyeClosed: nil, faceQuality: nil, faceCount: 0, faceBbox: nil, faceAreaPct: nil, faces: [],
            burstGroup: 0, expressionScore: nil, vlmReject: false, vlmCompositionIssues: [], vlmReason: nil,
            appealClosedEyes: nil, appealSubjectSharp: nil, appealIntentionalExposure: nil, appealReason: nil,
            exif: nil, horizonDeg: nil)
    }

    /// 页面脚本那张表（DSCF7207…7211，#3 = DSCF7209）。
    static func sheet(quota: Int?) -> ProofSheet {
        ProofSheet(id: sheetID, date: Date(timeIntervalSince1970: 1_793_000_000), scope: "仅精选", ids: names,
                   lists: ProofSheet.lists(quota: quota))
    }

    /// 40 张那张表（#n = DSCF72nn）。
    static let bigSheet = ProofSheet(id: "20261104-090000", date: Date(timeIntervalSince1970: 1_792_990_000),
                                     scope: "精选 + 可用", ids: (1...40).map { String(format: "DSCF72%02d", $0) })

    private static func replyNotes() {
        let all = items()
        func resolve(_ text: String) -> ClientReply.Resolution {
            ClientReply.resolve(text, items: all, sheets: [bigSheet])
        }
        func expect(_ text: String, ids: [String], notes: [String: String], _ name: String) {
            let r = resolve(text)
            let ok = r.ids == ids && r.notes == notes
            check(ok, name, "认出 \(r.ids.joined(separator: " ")) · 备注 \(r.notes) · 没认出 \(r.unknown)")
        }
        expect("DSCF7207 修 3 处", ids: ["DSCF7207"], notes: ["DSCF7207": "修 3 处"],
               "「DSCF7207 修 3 处」：3 处是备注，不把表上第 3 张认进来")
        expect("7207 7208", ids: ["DSCF7207", "DSCF7208"], notes: [:], "「7207 7208」还是两张、没有备注")
        expect("12、35", ids: ["DSCF7212", "DSCF7235"], notes: [:], "「12、35」按编号认两张")
        expect("DSCF7207 12 35", ids: ["DSCF7207", "DSCF7212", "DSCF7235"], notes: [:], "文件名后面全是数字：都是要的照片")
        expect("7207、12、35 都要", ids: ["DSCF7207", "DSCF7212", "DSCF7235"], notes: [:], "后面两个以上数字：不是备注")
        expect("7207 去路人，瘦脸（背景虚一点）！", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人，瘦脸（背景虚一点）！"],
               "文件号后面的话是备注，全角标点原样留着")
        expect("７２０７ 黑白", ids: ["DSCF7207"], notes: ["DSCF7207": "黑白"], "全角数字的文件号也认、备注照留")
        expect("DSCF7207：脸瘦一点", ids: ["DSCF7207"], notes: ["DSCF7207": "脸瘦一点"], "「文件名：备注」")
        expect("7207去路人", ids: ["DSCF7207"], notes: ["DSCF7207": "去路人"], "中文紧贴着文件号（以前整个算没认出）")
        expect("DSCF7207, DSCF7208 都要", ids: ["DSCF7207", "DSCF7208"], notes: [:], "后面还有文件名：不是备注，两张都要")
        expect("IMG 0001.JPG 黑白", ids: ["IMG 0001"], notes: ["IMG 0001": "黑白"], "带空格的文件名后面跟备注")
        expect("12 去路人", ids: ["DSCF7212"], notes: [:], "开头是编号不带备注（「12、35 都要」那种不能误当备注）")
        expect("DSCF7207 第12张 谢谢", ids: ["DSCF7207", "DSCF7212"], notes: [:], "后面明说「第 12 张」：照旧是要的照片")
        expect("DSCF7207 修 2 处，这张也要", ids: ["DSCF7207"], notes: ["DSCF7207": "修 2 处，这张也要"],
               "「这张」不是第几张：整句是备注")
        expect("DSCF7207\nDSCF7208 黑白\n7210 7211", ids: ["DSCF7207", "DSCF7208", "DSCF7210", "DSCF7211"],
               notes: ["DSCF7208": "黑白"], "一行一行各认各的")
        expect("DSCF7207 去路人\nDSCF7207 还要瘦脸", ids: ["DSCF7207"], notes: ["DSCF7207": "还要瘦脸"], "同一张写两次取后一次")
        let header = ProofSheetPage.header + " " + bigSheet.id + "\n"
        expect(header + "DSCF7207 " + ProofSheetPage.noteMarker + "和 DSCF7208 一样的调色，修 3 处\nDSCF7210\n",
               ids: ["DSCF7207", "DSCF7210"], notes: ["DSCF7207": "和 DSCF7208 一样的调色，修 3 处"],
               "确认表的「备注：」后面整段原样算备注，里面的文件名、数字不认")
        expect(header + "DSCF7207\nDSCF7208\n", ids: ["DSCF7207", "DSCF7208"], notes: [:], "老格式（没有备注）照旧")
        expect("文件名,备注\nDSCF7207,瘦脸\nDSCF7208,\n", ids: ["DSCF7207", "DSCF7208"], notes: [:], "CSV 照旧按表格认（备注列不收）")
        let unknown = resolve("DSCF9999 去路人")
        check(unknown.ids.isEmpty && unknown.notes.isEmpty && unknown.unknown == ["DSCF9999"],
              "不是这一场的文件名：照旧列在没认出、不带备注", "\(unknown.unknown)")
        let chatter = resolve("要这几张：7207、7208，谢谢")
        check(chatter.ids == ["DSCF7207", "DSCF7208"] && chatter.notes.isEmpty, "聊天的字照旧跳过",
              "\(chatter.ids) \(chatter.notes)")
        // 没导出过确认表：文件号后面的话照样算备注。
        let noSheet = ClientReply.resolve("7207 去路人", items: all, sheets: [])
        check(noSheet.ids == ["DSCF7207"] && noSheet.notes == ["DSCF7207": "去路人"], "没有确认表也认备注")
        // 编号也对得上另一张的 ≥3 位数（表上有 120 张以上才会碰到）：不当开头，照旧报「文件号还是编号？」。
        let many = (1...130).map { item(String(format: "IMG_%04d", $0 + 1000)) } + [item("DSCF0120")]
        let manySheet = ProofSheet(id: "20261104-080000", date: Date(), scope: "精选 + 可用", ids: many.map(\.id))
        let ambiguous = ClientReply.resolve("120 去路人", items: many, sheets: [manySheet])
        check(ambiguous.notes.isEmpty && ambiguous.unknown.contains { $0.hasPrefix("120") },
              "文件号、编号对不上的照旧说不准、不带备注", "\(ambiguous.ids) \(ambiguous.unknown)")

        // 套餐张数跟着表存、老表照样读。
        let decoded = try? JSONDecoder().decode([ProofSheet].self, from: Data(
            #"[{"id":"20261021-153012","date":782000000,"scope":"仅精选","ids":["a","b"]}]"#.utf8))
        check(decoded?.first?.quota == nil && decoded?.first?.ids == ["a", "b"], "老的 proof_sheets.json 照样读（没有张数）")
        let round = (try? JSONEncoder().encode(sheet(quota: 30)))
            .flatMap { try? JSONDecoder().decode(ProofSheet.self, from: $0) }
        check(round?.quota == 30, "套餐张数存了读回来一样")
        let plainJSON = (try? JSONEncoder().encode(sheet(quota: nil))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!plainJSON.contains("lists"), "不设张数不写 lists（老版本读新文件也不受影响）", plainJSON)
        check(ProofSheetSaveAccessory.parse(" ３０ ") == 30 && ProofSheetSaveAccessory.parse("0") == nil
              && ProofSheetSaveAccessory.parse("") == nil, "张数输入框：全角数字认、0 和空着 = 不限")

        // 精修要求.csv：表头、BOM、逗号引号转义。
        let csv = String(decoding: OriginalsCopier.retouchCSV([
            OriginalsCopier.RetouchRow(file: "DSCF7207.RAF", note: "去路人，瘦脸"),
            OriginalsCopier.RetouchRow(file: "DSCF7208.RAF", note: "和\"7207\"一样, 黑白"),
        ]), as: UTF8.self)
        let wantCSV = "\u{FEFF}文件名,备注\r\nDSCF7207.RAF,去路人，瘦脸\r\nDSCF7208.RAF,\"和\"\"7207\"\"一样, 黑白\"\r\n"
        check(csv == wantCSV, "精修要求.csv 的内容（BOM、表头、转义）", csv.debugDescription)
    }

    // MARK: 小工具

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func matchPairs(_ pattern: String, in text: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
