import Foundation

// MARK: - 选片确认表（发客户的单文件 HTML）
//
// 客户在页面上点照片选中（再点取消），底部「已选 N 张 · 复制我的选择」把选择复制成一段文字：
// 第一行「选片工具确认表 <表号>」，下面一行一个文件名（照片 id，导出几次都不变）。客户粘贴进微信发回来，
// 摄影师在 app 里「导入客户选择…」粘贴进去就标好了。编号（#12）只是辅助：同一张照片在「仅精选」和
// 「精选 + 可用」两次导出里编号不一样，所以每次导出把当时的顺序记进 proof_sheets.json（ProofSheet），
// 客户只回编号时按对的那张表认。
//
// 页面上的脚本只用 ES5、不联网、不引任何库：微信内置浏览器、老手机、本地打开都要能跑。
// 选择记在 localStorage（按表号分开），存不了（无痕模式、微信预览）也照样能点、能复制。
// 复制先试 navigator.clipboard，再试 execCommand('copy')，都不行就把文字摆在一个选好了的框里让人长按复制。
// 脚本整个跑不起来（微信里直接预览 HTML 时常见）也没关系：每张照片下面都写着文件名和编号，回文字照样能导。

/// 确认表上的一个清单。现在只有一个、不带名字（客户选中），带着套餐张数；以后分「精修 30 · 入册 60」
/// 这种多个清单时每个一条（名字、上限），客户选中也按清单记 —— 存的格式现在就按多个定好，不用再迁移一次。
struct ProofList: Codable, Equatable {
    /// 清单名（「精修」「入册」）；空 = 默认那一个。
    var name: String = ""
    /// 套餐张数：客户选超了只提示、不拦（国内超出的算加片）。nil = 不限。
    var quota: Int?
}

/// 导出过的一张确认表：表号 + 当时的照片顺序（编号 #n = ids[n-1]）。存 sessions/<key>/proof_sheets.json。
struct ProofSheet: Codable, Equatable {
    let id: String
    let date: Date
    /// 「仅精选」「精选 + 可用」「选中的照片」。
    let scope: String
    let ids: [String]
    /// 这张表上的清单（套餐张数）；nil = 没设张数（老版本导出的表也是 nil，照样读）。
    var lists: [ProofList]? = nil

    /// 套餐张数（第一个清单的上限）；nil = 不限。
    var quota: Int? { lists?.first?.quota }

    /// 表号 = 导出时间到秒（yyyyMMdd-HHmmss）：好认、自带日期，也够唯一。
    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    static func newID(_ date: Date = Date()) -> String { idFormatter.string(from: date) }

    /// 预览里说「编号按哪张表对的」用。
    var title: String { "\(Self.displayFormatter.string(from: date)) 导出的确认表（\(scope) · \(ids.count) 张）" }

    /// 套餐张数 → 清单（不限 = nil，和老表一样不写这个字段）。
    static func lists(quota: Int?) -> [ProofList]? {
        guard let quota, quota > 0 else { return nil }
        return [ProofList(quota: quota)]
    }
}

enum ProofSheetPage {
    /// 「复制我的选择」第一行的开头。导入时认它找表号（ClientReply）。
    static let header = "选片工具确认表"
    /// 每张约 122 KB：800px、q0.72 的 JPEG 再 base64（21 张真实预览实测平均 121,910 字节）。
    static let bytesPerPhoto: Int64 = 122_000
    /// 超过这个就提醒：微信传得慢，手机浏览器可能打不开。
    static let largeBytes: Int64 = 40_000_000

    /// 带水印时每张多大：同样 21 张真实预览（2026-11-04 重测，不带水印 121,911 字节），左下签名角标平均 122,094，
    /// 文字角标（带半透明底条）124,558 —— 按大的那个估。
    static let watermarkedBytesPerPhoto: Int64 = 125_000

    /// 导出前的体积估计（菜单上显示）。
    static func estimate(_ count: Int, watermark: Bool = false) -> String {
        "约 " + BatchStore.sizeText(Int64(count) * (watermark ? watermarkedBytesPerPhoto : bytesPerPhoto))
    }

    /// 导出后太大时的提醒。
    static func largeNote(_ bytes: Int64) -> String {
        "确认表有 \(BatchStore.sizeText(bytes))，微信传得慢、手机可能打不开：可以只导「仅精选」，" +
            "或者分批导（选中一部分照片，用「选中的照片」导出）"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// 一格：大图、右上角的选中标记（脚本跑起来才显示），下面文件名大字、编号小字；选中以后文件名旁边出来
    /// 「写备注」，备注写在下面一行（都是脚本跑起来才有）。按钮、备注行的 id 带编号（nb12 / nt12），脚本按 data-n 找。
    static func cell(number: Int, id: String, pick: Bool, jpeg: Data) -> String {
        let name = escape(id)
        let star = pick ? " ★" : ""
        // 拆成几段：一长串 + 在 CI 的 Xcode 16 上类型检查会慢。
        let open = "<div class=\"cell\" data-name=\"\(name)\" data-n=\"\(number)\"><img src=\"data:image/jpeg;base64,"
        let image = jpeg.base64EncodedString() + "\" alt=\"\(name)\"><span class=\"mark\">♥</span>"
        let caption = "<div class=\"cap\"><b>\(name)</b> · #\(number)\(star)"
            + "<button class=\"nb\" id=\"nb\(number)\" type=\"button\">写备注</button></div>"
        let note = "<div class=\"nt\" id=\"nt\(number)\"></div></div>\n"
        return open + image + caption + note
    }

    /// 备注最长多少字（页面上的输入框按它限）。
    static let noteMaxLength = 200

    /// `quota` = 套餐张数（nil = 不限）：底栏显示「已选 12 / 30 张」，选超了变色、只提示不拦。
    static func html(title: String, sheetID: String, count: Int, date: String, cells: String,
                     quota: Int? = nil) -> String {
        let t = escape(title)
        let limit = quota.map { max(0, $0) } ?? 0
        var tip = "点照片选中（右上角 ♥ 变紫），再点一下取消；选好后点底部「复制我的选择」，到微信里粘贴发给摄影师。"
        if limit > 0 {
            tip += "套餐含 \(limit) 张：可以多选，超出的张数摄影师会和你确认。"
        }
        tip += "选中的照片下面点「写备注」可以写修图要求（比如去掉路人、脸瘦一点），会跟着选择一起复制。" +
            "点不了也没关系：直接在微信里回复照片下面的文件名（如 DSCF7207）或编号（如 12、35、78）也行，" +
            "要求写在文件名后面（如「DSCF7207 去路人」）。"
        let counter = limit > 0 ? "已选 0 / \(limit) 张" : "已选 0 张"
        let notePlaceholder = "比如：去掉后面的路人、脸瘦一点"
        return """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>选片确认 · \(t)</title>
        <style>\(style)</style></head><body>
        <h1>选片确认 · \(t) · \(count) 张 · \(escape(date))</h1>
        <p class="tip">\(tip)<br>★ = 摄影师精选 · 表号 \(sheetID)</p>
        <div class="grid">\(cells)</div>
        <div class="bar"><span id="count">\(counter)</span><button id="copy" type="button">复制我的选择</button></div>
        <div id="toast"></div>
        <div id="panel"><p>长按全选复制，发给摄影师</p><textarea id="out" readonly></textarea>
        <button id="close" type="button">关闭</button></div>
        <div id="note"><p>给 <b id="note-name"></b> 写备注（修图要求，不写就清空）</p>
        <textarea id="note-text" maxlength="\(noteMaxLength)" placeholder="\(notePlaceholder)"></textarea>
        <p><button id="note-save" type="button">保存</button> <button id="note-cancel" type="button" class="ghost">取消</button></p></div>
        <script>\(script(sheetID: sheetID, quota: limit))</script>
        </body></html>
        """
    }

    private static let style = """
    body{font-family:-apple-system,sans-serif;background:#111;color:#eee;margin:1rem;padding-bottom:5rem}
    h1{font-size:1.1rem} .tip{color:#999;font-size:.85rem;line-height:1.5}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:10px}
    .cell{position:relative;cursor:pointer;-webkit-tap-highlight-color:transparent}
    .cell img{width:100%;border-radius:6px;display:block}
    .cell.on img{outline:4px solid #9b51e0;outline-offset:-4px}
    .mark{display:none;position:absolute;top:8px;right:8px;width:36px;height:36px;border-radius:50%;
    background:rgba(0,0,0,.45);color:rgba(255,255,255,.7);font-size:20px;line-height:36px;text-align:center}
    .js .mark{display:block} .cell.on .mark{background:#9b51e0;color:#fff}
    .cap{font-size:.8rem;color:#999;padding:4px 2px} .cap b{font-size:1rem;color:#fff;font-weight:600}
    .bar{display:none;position:fixed;left:0;right:0;bottom:0;padding:.7rem 1rem;background:rgba(24,24,24,.96);
    border-top:1px solid #333;align-items:center;justify-content:space-between}
    .js .bar{display:flex} #count{font-size:1rem}
    button{font-size:1rem;padding:.55rem 1.1rem;border:0;border-radius:8px;background:#9b51e0;color:#fff}
    #toast{display:none;position:fixed;left:1rem;right:1rem;bottom:4.8rem;padding:.7rem 1rem;background:#333;
    border-radius:8px;font-size:.9rem;text-align:center}
    #panel{display:none;position:fixed;left:0;right:0;top:0;bottom:0;background:rgba(0,0,0,.9);padding:1.2rem}
    #panel textarea{width:100%;height:55%;box-sizing:border-box;font-size:1rem;background:#fff;color:#000;
    border-radius:6px;padding:.5rem}
    .nb{display:none;margin-left:8px;font-size:.8rem;padding:.25rem .7rem;background:#3a3a3a;color:#ddd}
    .js .cell.on .nb{display:inline-block}
    .nt{display:none;font-size:.85rem;color:#d9bdf7;padding:0 2px 6px;line-height:1.4;word-break:break-all}
    .cell.on .nt{display:block} #count.over{color:#ff9e7a}
    #note{display:none;position:fixed;left:0;right:0;top:0;bottom:0;background:rgba(0,0,0,.92);padding:1.2rem}
    #note textarea{width:100%;height:30%;box-sizing:border-box;font-size:1rem;background:#fff;color:#000;
    border-radius:6px;padding:.5rem} button.ghost{background:#444}
    """

    /// 复制出来的文字里，文件名和备注之间的记号（「DSCF7207 备注：去路人」）。导入时认它：记号后面整段原样
    /// 算备注，里面再出现文件名、数字也不拿来认（ClientReply）。老版本 app 导入时会把它当聊天的字跳过。
    static let noteMarker = "备注："

    /// 页面脚本。纯 ES5，只碰 querySelectorAll / getElementById / createElement / execCommand、
    /// window.localStorage、navigator.clipboard、setTimeout —— 离线测试（--proof-selftest 用 JavaScriptCore）
    /// 给这几样做个假的就能跑。localStorage 取不到、存不进都包在 try 里。
    /// `quota` = 套餐张数（0 = 不限）：只提示、不拦。备注只给选中的照片写，存 localStorage（和选择分两个键，
    /// 老页面存的选择照样读），复制时一张一行「文件名 备注：…」，没写备注的那行和以前一样只有文件名。
    static func script(sheetID: String, quota: Int = 0) -> String {
        #"""
        (function () {
          var SHEET = "\#(sheetID)";
          var QUOTA = \#(max(0, quota));
          var KEY = "xuanpian-sheet-" + SHEET;
          var NOTE_KEY = KEY + "-notes";
          var MARK = "\#(noteMarker)";
          var picked = {};
          var notes = {};
          var cells = document.querySelectorAll(".cell");
          var countEl = document.getElementById("count");
          var panel = document.getElementById("panel");
          var out = document.getElementById("out");
          var toastEl = document.getElementById("toast");
          var notePanel = document.getElementById("note");
          var noteName = document.getElementById("note-name");
          var noteText = document.getElementById("note-text");
          var editing = null;
          var timer = null;
          function storage() {
            try { return window.localStorage || null; } catch (e) { return null; }
          }
          function names() {
            var list = [];
            for (var i = 0; i < cells.length; i++) {
              var n = cells[i].getAttribute("data-name");
              if (picked[n] === true) list.push(n);
            }
            return list;
          }
          function oneLine(t) {
            return String(t).replace(/[\r\n\t]+/g, " ").replace(/^\s+|\s+$/g, "");
          }
          function load() {
            try {
              var s = storage();
              var raw = s ? s.getItem(KEY) : null;
              var list = raw ? JSON.parse(raw) : [];
              for (var i = 0; i < list.length; i++) picked[String(list[i])] = true;
            } catch (e) {}
            try {
              var s2 = storage();
              var rawNotes = s2 ? s2.getItem(NOTE_KEY) : null;
              var saved = rawNotes ? JSON.parse(rawNotes) : {};
              for (var k in saved) {
                if (saved.hasOwnProperty(k) && typeof saved[k] === "string" && oneLine(saved[k]) !== "") {
                  notes[k] = oneLine(saved[k]);
                }
              }
            } catch (e) {}
          }
          function save() {
            try {
              var s = storage();
              if (s) s.setItem(KEY, JSON.stringify(names()));
            } catch (e) {}
          }
          function saveNotes() {
            try {
              var s = storage();
              if (s) s.setItem(NOTE_KEY, JSON.stringify(notes));
            } catch (e) {}
          }
          function noted() {
            var list = names(), n = 0;
            for (var i = 0; i < list.length; i++) if (notes[list[i]]) n++;
            return n;
          }
          function text() {
            var list = names(), lines = ["\#(header) " + SHEET];
            for (var i = 0; i < list.length; i++) {
              lines.push(notes[list[i]] ? list[i] + " " + MARK + notes[list[i]] : list[i]);
            }
            return lines.join("\n") + "\n";
          }
          function paintNote(cell) {
            var n = cell.getAttribute("data-n");
            var note = notes[cell.getAttribute("data-name")] || "";
            var nt = document.getElementById("nt" + n);
            var nb = document.getElementById("nb" + n);
            if (nt) nt.textContent = note ? MARK + note : "";
            if (nb) nb.textContent = note ? "改备注" : "写备注";
          }
          function paint(cell) {
            cell.className = picked[cell.getAttribute("data-name")] === true ? "cell on" : "cell";
            paintNote(cell);
          }
          function refresh() {
            var n = names().length;
            if (QUOTA > 0) {
              var over = n - QUOTA;
              countEl.textContent = over > 0 ? "已选 " + n + " / " + QUOTA + "，超出 " + over + " 张"
                : "已选 " + n + " / " + QUOTA + " 张";
              countEl.className = over > 0 ? "over" : "";
            } else {
              countEl.textContent = "已选 " + n + " 张";
            }
          }
          function toggle(cell) {
            var n = cell.getAttribute("data-name");
            var was = picked[n] === true;
            if (was) { delete picked[n]; } else { picked[n] = true; }
            paint(cell);
            refresh();
            save();
            if (!was && QUOTA > 0 && names().length === QUOTA + 1) {
              toast("超出套餐的 " + QUOTA + " 张了：可以接着选，超出的张数摄影师会和你确认", false);
            }
          }
          function stop(e) {
            e = e || window.event;
            if (e) {
              e.cancelBubble = true;
              if (e.stopPropagation) e.stopPropagation();
            }
          }
          function openNote(cell) {
            editing = cell;
            noteName.textContent = cell.getAttribute("data-name");
            noteText.value = notes[cell.getAttribute("data-name")] || "";
            toastEl.style.display = "none";
            notePanel.style.display = "block";
            try { noteText.focus(); } catch (e) {}
          }
          function closeNote() {
            notePanel.style.display = "none";
            editing = null;
          }
          function saveNote() {
            if (editing) {
              var n = editing.getAttribute("data-name");
              var t = oneLine(noteText.value).slice(0, \#(noteMaxLength));
              if (t !== "") { notes[n] = t; } else { delete notes[n]; }
              saveNotes();
              paintNote(editing);
            }
            closeNote();
          }
          function showText(t) {
            toastEl.style.display = "none";
            panel.style.display = "block";
            out.value = t;
            try { out.focus(); out.select(); out.setSelectionRange(0, t.length); } catch (e) {}
          }
          function toast(msg, canShowText) {
            toastEl.textContent = msg;
            toastEl.style.display = "block";
            toastEl.onclick = canShowText ? function () { showText(text()); } : null;
            if (timer) clearTimeout(timer);
            timer = setTimeout(function () { toastEl.style.display = "none"; }, 8000);
          }
          function legacyCopy(t) {
            var ok = false, ta = null;
            try {
              ta = document.createElement("textarea");
              ta.value = t;
              ta.setAttribute("readonly", "");
              ta.style.position = "fixed";
              ta.style.top = "0";
              ta.style.opacity = "0";
              document.body.appendChild(ta);
              ta.select();
              ta.setSelectionRange(0, t.length);
              ok = document.execCommand("copy") === true;
            } catch (e) { ok = false; }
            try { if (ta) document.body.removeChild(ta); } catch (e) {}
            return ok;
          }
          function copy() {
            var t = text(), n = names().length, m = noted(), extra = [];
            if (n === 0) { toast("还没选照片：点照片选中，再点一下取消", false); return; }
            if (QUOTA > 0 && n > QUOTA) extra.push("超出套餐 " + (n - QUOTA) + " 张");
            if (m > 0) extra.push(m + " 张带备注");
            var tail = extra.length > 0 ? "（" + extra.join("，") + "）" : "";
            function done(ok) {
              if (ok) { toast("已复制 " + n + " 张的选择" + tail + "，到微信里粘贴发给摄影师（粘贴不出来就点这里）", true); }
              else { showText(t); }
            }
            var clip = null;
            try { clip = navigator.clipboard; } catch (e) { clip = null; }
            if (clip && clip.writeText && window.isSecureContext !== false) {
              try {
                clip.writeText(t).then(function () { done(true); }, function () { done(legacyCopy(t)); });
                return;
              } catch (e) {}
            }
            done(legacyCopy(t));
          }
          load();
          for (var i = 0; i < cells.length; i++) {
            paint(cells[i]);
            cells[i].onclick = (function (c) { return function () { toggle(c); }; })(cells[i]);
            // 「写备注」在格子里面：点它不能顺带把这张取消选中。
            var nb = document.getElementById("nb" + cells[i].getAttribute("data-n"));
            if (nb) nb.onclick = (function (c) { return function (e) { stop(e); openNote(c); }; })(cells[i]);
          }
          document.getElementById("copy").onclick = copy;
          document.getElementById("close").onclick = function () { panel.style.display = "none"; };
          document.getElementById("note-save").onclick = saveNote;
          document.getElementById("note-cancel").onclick = closeNote;
          document.body.className = "js";
          refresh();
        })();
        """#
    }
}
