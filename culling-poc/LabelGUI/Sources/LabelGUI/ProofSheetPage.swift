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

/// 导出过的一张确认表：表号 + 当时的照片顺序（编号 #n = ids[n-1]）。存 sessions/<key>/proof_sheets.json。
struct ProofSheet: Codable, Equatable {
    let id: String
    let date: Date
    /// 「仅精选」「精选 + 可用」「选中的照片」。
    let scope: String
    let ids: [String]

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
}

enum ProofSheetPage {
    /// 「复制我的选择」第一行的开头。导入时认它找表号（ClientReply）。
    static let header = "选片工具确认表"
    /// 每张约 122 KB：800px、q0.72 的 JPEG 再 base64（21 张真实预览实测平均 121,910 字节）。
    static let bytesPerPhoto: Int64 = 122_000
    /// 超过这个就提醒：微信传得慢，手机浏览器可能打不开。
    static let largeBytes: Int64 = 40_000_000

    /// 导出前的体积估计（菜单上显示）。
    static func estimate(_ count: Int) -> String {
        "约 " + BatchStore.sizeText(Int64(count) * bytesPerPhoto)
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

    /// 一格：大图、右上角的选中标记（脚本跑起来才显示），下面文件名大字、编号小字。
    static func cell(number: Int, id: String, pick: Bool, jpeg: Data) -> String {
        let name = escape(id)
        let star = pick ? " ★" : ""
        return "<div class=\"cell\" data-name=\"\(name)\"><img src=\"data:image/jpeg;base64,"
            + jpeg.base64EncodedString() + "\" alt=\"\(name)\"><span class=\"mark\">♥</span>"
            + "<div class=\"cap\"><b>\(name)</b> · #\(number)\(star)</div></div>\n"
    }

    static func html(title: String, sheetID: String, count: Int, date: String, cells: String) -> String {
        let t = escape(title)
        let tip = "点照片选中（右上角 ♥ 变紫），再点一下取消；选好后点底部「复制我的选择」，到微信里粘贴发给摄影师。" +
            "点不了也没关系：直接在微信里回复照片下面的文件名（如 DSCF7207）或编号（如 12、35、78）也行。"
        return """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>选片确认 · \(t)</title>
        <style>\(style)</style></head><body>
        <h1>选片确认 · \(t) · \(count) 张 · \(escape(date))</h1>
        <p class="tip">\(tip)<br>★ = 摄影师精选 · 表号 \(sheetID)</p>
        <div class="grid">\(cells)</div>
        <div class="bar"><span id="count">已选 0 张</span><button id="copy" type="button">复制我的选择</button></div>
        <div id="toast"></div>
        <div id="panel"><p>长按全选复制，发给摄影师</p><textarea id="out" readonly></textarea>
        <button id="close" type="button">关闭</button></div>
        <script>\(script(sheetID: sheetID))</script>
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
    """

    /// 页面脚本。纯 ES5，只碰 querySelectorAll / getElementById / createElement / execCommand、
    /// window.localStorage、navigator.clipboard、setTimeout —— 离线测试（--proof-sheet 的检查用 jsc）
    /// 给这几样做个假的就能跑。localStorage 取不到、存不进都包在 try 里。
    static func script(sheetID: String) -> String {
        #"""
        (function () {
          var SHEET = "\#(sheetID)";
          var KEY = "xuanpian-sheet-" + SHEET;
          var picked = {};
          var cells = document.querySelectorAll(".cell");
          var countEl = document.getElementById("count");
          var panel = document.getElementById("panel");
          var out = document.getElementById("out");
          var toastEl = document.getElementById("toast");
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
          function load() {
            try {
              var s = storage();
              var raw = s ? s.getItem(KEY) : null;
              var list = raw ? JSON.parse(raw) : [];
              for (var i = 0; i < list.length; i++) picked[String(list[i])] = true;
            } catch (e) {}
          }
          function save() {
            try {
              var s = storage();
              if (s) s.setItem(KEY, JSON.stringify(names()));
            } catch (e) {}
          }
          function text() {
            return "\#(header) " + SHEET + "\n" + names().join("\n") + "\n";
          }
          function paint(cell) {
            cell.className = picked[cell.getAttribute("data-name")] === true ? "cell on" : "cell";
          }
          function refresh() {
            countEl.textContent = "已选 " + names().length + " 张";
          }
          function toggle(cell) {
            var n = cell.getAttribute("data-name");
            if (picked[n] === true) { delete picked[n]; } else { picked[n] = true; }
            paint(cell);
            refresh();
            save();
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
            var t = text(), n = names().length;
            if (n === 0) { toast("还没选照片：点照片选中，再点一下取消", false); return; }
            function done(ok) {
              if (ok) { toast("已复制 " + n + " 张的选择，到微信里粘贴发给摄影师（粘贴不出来就点这里）", true); }
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
          }
          document.getElementById("copy").onclick = copy;
          document.getElementById("close").onclick = function () { panel.style.display = "none"; };
          document.body.className = "js";
          refresh();
        })();
        """#
    }
}
