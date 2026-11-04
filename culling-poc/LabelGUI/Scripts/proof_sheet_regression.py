#!/usr/bin/env python3
"""选片确认表端到端回归（无头，不要真照片）：套餐张数、每张备注、精修要求.csv、可选水印。

用 Fixtures/photot-session 的分析结果（21 张、精选 5 张）灌进临时数据目录，照片路径改到一个临时照片文件夹；
预览和原片是现造的图（Python 写 BMP，sips 转 JPEG），所以 CI 上也能跑。

    python3 Scripts/proof_sheet_regression.py <LabelGUI 可执行文件>

查的东西：
1. --proof-sheet：不设张数 / --quota 3 两张表；同一张预览两次导出的图逐字节一样；proof_sheets.json 新表带 lists、
   老字段不变；页面里有套餐张数、写备注的按钮。
2. --client-import：确认表复制格式「文件名 备注：…」、微信写法「7208 黑白」都读回备注，「修 3 处」不把第 3 张认进来；
   预览说带备注、超出套餐；--apply 存 client_notes.json，--undo 选中和备注一起回去；--clear 连备注一起清、能撤销。
3. --copy-originals：目标里写「精修要求.csv」（BOM、表头、转义）；再复制一次一模一样不再写；备注改了另存
   「精修要求-2.csv」，原来那份不动。
4. --proof-sheet --with-watermark --signature：每张图都变了、张数和顺序不变、预览文件一个字节没动；
   没签名也没文字时不导（不悄悄导出不带水印的）；打印每张平均体积（bytesPerPhoto 的依据）。
5. 水印页只开了 EXIF 参数文字（默认模板）：原片没有 EXIF、外接盘没插时一张都画不上 → 不导、不记表、不报「带水印」；
   写一句自定义文字照样导。

只写临时目录，跑完删掉。
"""
import base64
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "Fixtures", "photot-session")

failures = []


def check(ok, name, detail=""):
    if ok:
        print("PASS " + name)
    else:
        failures.append(name)
        print("FAIL " + name + ((" → " + detail) if detail else ""))


def bmp(path, w, h, seed):
    """24 位 BMP：渐变 + 几块色块（每张不一样），sips 转成 JPEG。"""
    row_pad = (4 - (w * 3) % 4) % 4
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r = (x * 255 // w + seed * 37) % 256
            g = (y * 255 // h + seed * 11) % 256
            b = ((x // 64 + y // 64 + seed) % 2) * 160 + 40
            row += bytes((b, g, r))
        row += b"\0" * row_pad
        rows.append(bytes(row))
    pixels = b"".join(reversed(rows))
    header = b"BM" + struct.pack("<IHHI", 54 + len(pixels), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    with open(path, "wb") as f:
        f.write(header + info + pixels)


def jpeg(src_bmp, out, size=None):
    cmd = ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "85"]
    if size:
        cmd += ["-z", str(size[1]), str(size[0])]
    subprocess.run(cmd + [src_bmp, "--out", out], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def png_signature(path, w=360, h=120):
    """白字底透明的签名图（一块带边的白色横条）。"""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            inside = 10 <= x < w - 10 and 30 <= y < h - 30
            raw += bytes((255, 255, 255, 255 if inside else 0))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def cells(html):
    """[(id, base64)]，按页面上的顺序。"""
    return re.findall(r'<div class="cell" data-name="([^"]*)" data-n="[0-9]+"><img src="data:image/jpeg;base64,([^"]+)"', html)


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    binary = os.path.abspath(sys.argv[1])
    work = tempfile.mkdtemp(prefix="proof-regression-")
    try:
        return run(binary, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(binary, work):
    data = os.path.join(work, "data")
    photos = os.path.join(work, "photos")
    dest = os.path.join(work, "精修")
    out = os.path.join(work, "out")
    for d in (data, photos, out):
        os.makedirs(d)
    env = dict(os.environ)
    env.update({
        "LABELGUI_DATA_DIR": data,
        "LABELGUI_NO_GUI": "1",
        "LABELGUI_LIVE_SOCK_ROOT": os.path.join(work, "sock"),
        "LABELGUI_MCP_OUT": os.path.join(work, "mcp-out"),
    })
    os.makedirs(env["LABELGUI_LIVE_SOCK_ROOT"])

    def lg(*args, ok=True):
        p = subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
        if ok and p.returncode != 0:
            print(p.stdout + p.stderr)
        return p

    key = lg("--session-key", photos).stdout.strip()
    session = os.path.join(data, "sessions", key)
    os.makedirs(os.path.join(session, "previews"))
    with open(os.path.join(FIX, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    manifest["photo_dir"] = photos
    for p in manifest["photos"]:
        for field in ("raw_path", "decode_path"):
            p[field] = p[field].replace("/tmp/labelgui-fixture-photot", photos)
    with open(os.path.join(session, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False)
    shutil.copy(os.path.join(FIX, "layer1_results.json"), session)
    ids = [p["id"] for p in manifest["photos"]]
    # 预览 1024×683（和分析出来的一样大），原片 3000×2000（水印边距按原片换算）。
    for i, pid in enumerate(ids):
        src = os.path.join(work, pid + ".bmp")
        bmp(src, 1024, 683, i)
        jpeg(src, os.path.join(session, "previews", pid + ".jpg"))
        jpeg(src, os.path.join(photos, pid + ".JPG"), size=(3000, 2000))
        os.remove(src)
    preview_hash = {pid: sha(os.path.join(session, "previews", pid + ".jpg")) for pid in ids}

    # 1. 确认表：不设张数 / 套餐 3 张。
    a_html = os.path.join(out, "a.html")
    a = lg("--proof-sheet", photos, "--out", a_html)
    check(a.returncode == 0, "导出确认表（不设张数）", a.stdout + a.stderr)
    m = re.search(r"表号 (\S+) · 仅精选 · (\d+) 张: (.*)", a.stdout)
    check(m is not None and int(m.group(2)) == 5, "精选 5 张进了确认表", a.stdout)
    picks = m.group(3).split() if m else []
    sheet_a = m.group(1) if m else ""
    with open(a_html, encoding="utf-8") as f:
        page_a = f.read()
    check([c[0] for c in cells(page_a)] == picks, "页面上的照片和顺序跟记下的表一样")
    check("套餐含" not in page_a and "var QUOTA = 0;" in page_a, "不设张数：页面上不提套餐")
    check('id="nb1"' in page_a and "写备注" in page_a, "每格有「写备注」")

    b_html = os.path.join(out, "b.html")
    time.sleep(1.1)  # 表号是导出时间到秒：同一秒导两张会是同一个表号
    b = lg("--proof-sheet", photos, "--out", b_html, "--quota", "3")
    m = re.search(r"表号 (\S+) · 仅精选 · 5 张 · 套餐 3 张: ", b.stdout)
    check(b.returncode == 0 and m is not None, "导出确认表（--quota 3）", b.stdout + b.stderr)
    sheet_b = m.group(1) if m else ""
    with open(b_html, encoding="utf-8") as f:
        page_b = f.read()
    check("套餐含 3 张" in page_b and "var QUOTA = 3;" in page_b and "已选 0 / 3 张" in page_b, "页面上有套餐 3 张")
    check(cells(page_a) == cells(page_b), "同样的预览两次导出，图逐字节一样")
    with open(os.path.join(session, "proof_sheets.json"), encoding="utf-8") as f:
        sheets = json.load(f)
    check(len(sheets) >= 2 and "lists" not in sheets[-2] and sheets[-1].get("lists") == [{"name": "", "quota": 3}],
          "proof_sheets.json：设了张数的表带 lists，没设的不写", json.dumps(sheets[-2:], ensure_ascii=False)[:300])
    check(sheets[-1]["ids"] == picks, "表上记的照片顺序不变")

    # 2. 导入客户选择：确认表复制格式 + 微信写法。
    n2 = picks[1]
    reply = os.path.join(work, "reply.txt")
    # 「修 3 处」：表上第 3 张不能被认进来。
    lines = ["选片工具确认表 " + sheet_b,
             picks[0] + " 备注：去路人，瘦脸（背景虚一点）",
             n2 + " 修 3 处",
             picks[3],
             re.sub(r"^\D*", "", picks[4]) + " 黑白"]
    with open(reply, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    r = lg("--client-import", photos, "--text", reply, "--apply", "--undo")
    want_ids = [picks[0], n2, picks[3], picks[4]]
    check(("认出: " + " ".join(want_ids)) in r.stdout, "认出四张（「修 3 处」不认第 3 张）", r.stdout)
    want_notes = "备注: {}=去路人，瘦脸（背景虚一点） | {}=修 3 处 | {}=黑白".format(picks[0], n2, picks[4])
    check(want_notes in r.stdout, "读回三条备注（全角标点原样）", r.stdout)
    check("预览: 带备注 3 张：" in r.stdout, "预览说几张带备注")
    check("预览: 套餐含 3 张：这次认出 4 张，超出 1 张（加片）" in r.stdout, "预览说超出套餐")
    check("编号表: {} · 套餐 3 张".format(sheet_b) in r.stdout, "认出表号和套餐", r.stdout)
    after = r.stdout.split("导入后")[1].split("撤销后")[0] if "导入后" in r.stdout and "撤销后" in r.stdout else ""
    check("客户备注: " + want_notes[len("备注: "):] in after, "--apply 以后客户备注存上", after)
    check("· 备注 3 张 · ⌘Z 撤销" in r.stdout, "状态栏说带了几条备注")
    undone = r.stdout.split("撤销后")[1] if "撤销后" in r.stdout else ""
    check("客户选中 0 张" in undone and "客户备注: -" in undone, "⌘Z 一步：选中和备注一起回去", undone)
    check(not os.path.exists(os.path.join(session, "client_notes.json")), "撤销后 client_notes.json 也删掉")

    r = lg("--client-import", photos, "--text", reply, "--apply")
    notes_path = os.path.join(session, "client_notes.json")
    saved = json.load(open(notes_path, encoding="utf-8")) if os.path.exists(notes_path) else {}
    check(saved == {picks[0]: "去路人，瘦脸（背景虚一点）", n2: "修 3 处", picks[4]: "黑白"}, "client_notes.json 内容", str(saved))

    # 3. 复制原片：精修要求.csv。
    c = lg("--copy-originals", photos, "--dest", dest, "--scope", "client")
    check(c.returncode == 0 and "写了 精修要求.csv（3 张的客户备注）" in c.stdout, "复制原片时写精修要求.csv", c.stdout + c.stderr)
    csv_path = os.path.join(dest, "精修要求.csv")
    raw = open(csv_path, "rb").read() if os.path.exists(csv_path) else b""
    text = raw.decode("utf-8", "replace")
    check(raw.startswith(b"\xef\xbb\xbf") and text.lstrip("﻿").startswith("文件名,备注\r\n"), "UTF-8 BOM + 表头")
    check(picks[0] + ".JPG,去路人，瘦脸（背景虚一点）\r\n" in text and picks[4] + ".JPG,黑白\r\n" in text, "一张一行（原片文件名、备注）", text)
    first_csv = raw
    c = lg("--copy-originals", photos, "--dest", dest, "--scope", "client")
    check("精修要求.csv 已经有了" in c.stdout and not os.path.exists(os.path.join(dest, "精修要求-2.csv")),
          "再复制一次：一模一样就不再写", c.stdout)
    with open(reply, "w", encoding="utf-8") as f:
        f.write(picks[0] + " 备注：换成调亮一点\n")
    lg("--client-import", photos, "--text", reply, "--apply")
    c = lg("--copy-originals", photos, "--dest", dest, "--scope", "client")
    check("写了 精修要求-2.csv" in c.stdout and "没覆盖" in c.stdout, "备注改了：另存精修要求-2.csv", c.stdout)
    check(open(csv_path, "rb").read() == first_csv, "原来那份精修要求.csv 一个字节没动")

    # 清除客户选中：备注一起清，⌘Z 一起回来。
    r = lg("--client-import", photos, "--clear", "--apply", "--undo")
    mid = r.stdout.split("导入后")[1].split("撤销后")[0] if "撤销后" in r.stdout else ""
    check("客户备注: -" in mid and "已清除客户选中 4 张、备注 3 条" in r.stdout, "清除客户选中连备注一起清", r.stdout)
    check("客户备注: " + picks[0] + "=换成调亮一点" in r.stdout.split("撤销后")[-1], "清除也能 ⌘Z 回来")

    watermark(lg, work, photos, session, ids, picks, preview_hash, page_a)
    blank_watermark(lg, work, data, photos, session)

    print("确认表回归: " + ("全部通过" if not failures else "{} 条没过: {}".format(len(failures), "；".join(failures))))
    return 0 if not failures else 1


def watermark(lg, work, photos, session, ids, picks, preview_hash, page_a):
    """M06：确认表可选水印（用水印页的签名）。像素位置、淡不淡在 --proof-selftest 里查，这里查整条路。"""
    out = os.path.join(work, "out")
    sig = os.path.join(work, "sig.png")
    png_signature(sig)
    sheets_path = os.path.join(session, "proof_sheets.json")

    # 没签名也没文字：不导（不悄悄导出一张不带水印的），也不记表。
    before = open(sheets_path, encoding="utf-8").read()
    p = lg("--proof-sheet", photos, "--out", os.path.join(out, "none.html"), "--with-watermark", ok=False)
    check(p.returncode != 0 and "水印页没有签名也没开文字" in p.stdout, "带水印却没东西可画：不导", p.stdout + p.stderr)
    check(not os.path.exists(os.path.join(out, "none.html")) and open(sheets_path, encoding="utf-8").read() == before,
          "没导的不写 HTML、不记表")

    time.sleep(1.1)
    c_html = os.path.join(out, "c.html")
    p = lg("--proof-sheet", photos, "--out", c_html, "--with-watermark", "--signature", sig)
    check(p.returncode == 0 and "水印: 签名 360×120 · 没有文字 · 左下 · 不透明度 0.5" in p.stdout, "带水印导出（签名）", p.stdout + p.stderr)
    check("选片确认表已导出（带水印）: 5 张" in p.stdout, "状态栏说带水印")
    with open(c_html, encoding="utf-8") as f:
        page_c = f.read()
    plain, marked = cells(page_a), cells(page_c)
    check([c[0] for c in marked] == picks, "带水印：照片和顺序不变")
    check(len(marked) == len(plain) and all(a[1] != b[1] for a, b in zip(plain, marked)), "带水印：每张图都变了")
    sheets = json.load(open(sheets_path, encoding="utf-8"))
    check(sheets[-1]["ids"] == picks and "lists" not in sheets[-1], "带水印：表上记的照片顺序一样（水印不进 proof_sheets.json）")
    now = {pid: sha(os.path.join(session, "previews", pid + ".jpg")) for pid in ids}
    check(now == preview_hash, "预览文件一个字节没动")

    time.sleep(1.1)
    d_html = os.path.join(out, "d.html")
    p = lg("--proof-sheet", photos, "--out", d_html, "--with-watermark", "--watermark-text", "样片 · 小何摄影")
    check(p.returncode == 0 and "水印: 没有签名 · 文字" in p.stdout, "只有文字也能导", p.stdout + p.stderr)
    with open(d_html, encoding="utf-8") as f:
        page_d = f.read()
    check(all(a[1] != b[1] for a, b in zip(plain, cells(page_d))), "文字水印：每张图都变了")

    # 体积：bytesPerPhoto / watermarkedBytesPerPhoto 的依据（这里是造的图，真实照片的数在提交说明里）。
    def avg(cs):
        return sum(len(c[1]) for c in cs) // max(1, len(cs))
    print("体积: 每张平均 base64 {} 字节（不带水印）· {}（签名角标）· {}（文字角标）".format(
        avg(plain), avg(marked), avg(cells(page_d))))


def blank_watermark(lg, work, data, photos, session):
    """水印页只开了 EXIF 参数文字（默认模板、没签名、没自定义文字），原片没有 EXIF / 外接盘没插：一张都画不上，
    不导出一份干净的确认表还报「带水印」。"""
    out = os.path.join(work, "out")
    state_dir = os.path.join(data, "watermark")
    os.makedirs(state_dir, exist_ok=True)
    state = os.path.join(state_dir, "state.json")
    with open(state, "w", encoding="utf-8") as f:
        json.dump({"config": {"signatureEnabled": False, "exifText": {"enabled": True, "customText": ""}}}, f)
    sheets_path = os.path.join(session, "proof_sheets.json")
    before = open(sheets_path, encoding="utf-8").read()
    try:
        # 原片在，可是没有 EXIF（sips 转出来的 JPEG 不带机身型号）。
        time.sleep(1.1)
        e_html = os.path.join(out, "e.html")
        p = lg("--proof-sheet", photos, "--out", e_html, "--with-watermark", ok=False)
        check("水印: 没有签名 · 文字" in p.stdout, "只开 EXIF 模板文字：照样做得出角标", p.stdout + p.stderr)
        check(p.returncode != 0 and "选片确认表没导出：5 张都没画上水印" in p.stdout and "原片" in p.stdout,
              "原片没有 EXIF：一张都画不上就不导、说清楚要读原片", p.stdout + p.stderr)
        check("选片确认表已导出（带水印）" not in p.stdout, "不报「带水印」")
        check(not os.path.exists(e_html) and open(sheets_path, encoding="utf-8").read() == before, "没导的不写 HTML、不记表")

        # 外接盘没插：拍摄文件夹整个不在（预览在数据目录，场次照样打开）。
        offline = photos + ".offline"
        os.rename(photos, offline)
        try:
            time.sleep(1.1)
            f_html = os.path.join(out, "f.html")
            p = lg("--proof-sheet", photos, "--out", f_html, "--with-watermark", ok=False)
            check(p.returncode != 0 and "都没画上水印" in p.stdout and not os.path.exists(f_html),
                  "原片读不到（外接盘没插）：不导、不报带水印", p.stdout + p.stderr)
            check(open(sheets_path, encoding="utf-8").read() == before, "外接盘没插：不记表")
        finally:
            os.rename(offline, photos)

        # 同样的设置写一句自定义文字：照样导（不靠原片）。
        time.sleep(1.1)
        g_html = os.path.join(out, "g.html")
        p = lg("--proof-sheet", photos, "--out", g_html, "--with-watermark", "--watermark-text", "样片")
        check(p.returncode == 0 and "选片确认表已导出（带水印）: 5 张" in p.stdout, "写了自定义文字：照样导 5 张", p.stdout + p.stderr)
    finally:
        os.remove(state)


if __name__ == "__main__":
    sys.exit(main())
