#!/usr/bin/env python3
"""合成图跑原生分析冒烟（CI 的「合成图跑原生分析」步骤）：手写几张能确定结果的合成图，真跑 `--analyze`（ImageIO 解码、
EXIF 方向和拍摄时间、Vision、锐度 / 裁切、截断 JPEG、pHash 分组），再跑 `--verdicts --per-photo`，按正则断言理由和标志，
不比具体数值（锐度、人脸质量这些每次有点抖，换了公式也不该在这里红）。

    blur.jpg      横向平滑渐变（30 → 220）：没有边缘 → 虚焦（不用噪声图：噪声会把锐度抬高）
    white.jpg     整张 255：曝光裁切；没有脸 → 不判过曝（过曝只看脸，BatchStore.toneReason）
    control.jpg   四色象限 + 噪声：清晰、不裁切、不损坏 —— 对照
    trunc.jpg     噪声图截掉后 40%（> 64KB，最后 64KB 里没有 FF D9）：文件损坏；后缀必须是 .jpg（jpegTruncated 只认 jpg / jpeg）
    motion.jpg    完整 JPEG 后面接 70000 字节不含 FF 的尾巴（像动态照片接的视频）：按段走到主图的 EOI，不算损坏
    burst_a/b.jpg 同一套象限、不同噪声，手写 APP1：DateTimeOriginal 差 1 秒、Orientation=6 → 同一个近似重复组；
                  预览按方向转正（竖的，左上角是原图的左下角 —— 蓝）
    other_c.jpg   象限上下对调、再晚 1 秒：时间窗口里、pHash 差得远 → 另一组
sips 出的图没有拍摄时间（没有时间的每张单独成组），所以分组要手写 APP1。
第二次 --analyze 应该全部复用（0 analyzed）。

最后是规模守护：把 photot-session 的 21 行克隆成 2000 / 8000 行（只有 JSON，不要图），给 `--verdicts` 计时；
共享 runner 计时抖得厉害，只卡很宽的上限和「8000 比 2000 的耗时比」（线性 ≈ 4，O(n²) ≈ 16），各取几次里最快的。

每条命令都带临时 LABELGUI_DATA_DIR、LABELGUI_NO_GUI=1；CI 里放在 MCP 冒烟后面（见 release.yml 那段注释）。
用法: python3 -I Scripts/native_analysis_smoke.py <LabelGUI> [--keep] [--no-scale]
"""
import importlib.util, json, os, re, shutil, subprocess, sys, tempfile, time

ARGS = sys.argv[1:]
if not ARGS or ARGS[0].startswith("-"):
    print(__doc__)
    sys.exit(2)
BIN = os.path.abspath(ARGS[0])
KEEP = "--keep" in ARGS
SCALE = "--no-scale" not in ARGS
ON_GITHUB = os.environ.get("GITHUB_ACTIONS") == "true"
SLACK = 4.0 if ON_GITHUB else 1.0
HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(os.path.dirname(HERE), "Fixtures", "photot-session")
_spec = importlib.util.spec_from_file_location("synth_jpeg", os.path.join(HERE, "synth_jpeg.py"))
sj = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sj)

REAL_DATA = os.path.expanduser("~/Library/Application Support/选片工具")
REAL_BEFORE = os.path.exists(REAL_DATA)
WORK = tempfile.mkdtemp(prefix="native-smoke-")
os.makedirs(os.path.join(WORK, "mcp-out"))
FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)
        if ON_GITHUB:
            print(f"::error title=合成图原生分析::{msg}")
    return cond


def env_for(data):
    sock = tempfile.mkdtemp(prefix="sock-", dir=WORK)
    e = {k: v for k, v in os.environ.items() if not k.startswith("LABELGUI_")}
    e.update(LABELGUI_DATA_DIR=data, LABELGUI_NO_GUI="1", LABELGUI_LIVE_SOCK_ROOT=sock,
             LABELGUI_MCP_OUT=os.path.join(WORK, "mcp-out"))
    return e


def run(args, data, timeout=300):
    t = time.monotonic()
    r = subprocess.run([BIN] + args, env=env_for(data), capture_output=True, text=True, timeout=timeout * SLACK,
                       stdin=subprocess.DEVNULL, cwd=WORK)
    return r, time.monotonic() - t


def session_key(path):
    r, _ = run(["--session-key", path], os.path.join(WORK, "key-data"))
    key = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
    if not re.match(r"^[0-9a-f]{16}$", key):
        print(f"--session-key 算不出 {path} 的 key：{r.stdout!r} {r.stderr[-300:]!r}")
        sys.exit(2)
    return key


def per_photo(text):
    """`--verdicts --per-photo` 里「阈值:」后面的逐张行 → {id: (判决, [理由])}。"""
    out, on = {}, False
    for line in text.splitlines():
        if line.startswith("阈值: "):
            on = True
            continue
        m = re.match(r"^  (\S+) (精选|可用|废片) (\S+)$", line) if on else None
        if m:
            out[m.group(1)] = (m.group(2), [] if m.group(3) == "-" else m.group(3).split(","))
        elif on:
            on = False
    return out


def eoi_in_tail(data):
    return b"\xFF\xD9" in data[-65536:]


# ---------------------------------------------------------------- 1. 合成图

def build_photos(photos):
    os.makedirs(photos)
    tmp = os.path.join(WORK, "bmp")
    os.makedirs(tmp)
    w, h = 1500, 1000

    def jpeg(name, make_bmp, quality=80):
        bmp = os.path.join(tmp, name + ".bmp")
        make_bmp(bmp)
        jpg = os.path.join(tmp, name + ".jpg")
        sj.to_jpeg(bmp, jpg, quality)
        return open(jpg, "rb").read()

    def put(name, data):
        with open(os.path.join(photos, name + ".jpg"), "wb") as f:
            f.write(data)

    put("blur", jpeg("blur", lambda p: sj.bmp_gradient(p, w, h)))
    put("white", jpeg("white", lambda p: sj.bmp_flat(p, w, h, (255, 255, 255))))
    put("control", jpeg("control", lambda p: sj.bmp_quadrants(p, w, h, seed=1)))
    full = jpeg("trunc", lambda p: sj.bmp_quadrants(p, w, h, seed=2))
    cut = full[: int(len(full) * 0.6)]
    ok = check(len(cut) > 65536 and not eoi_in_tail(cut),
               f"前提：截断样本 {len(cut)} B > 64KB，最后 64KB 里没有 FF D9（走 jpegHasEOI 的按段扫描）")
    put("trunc", cut)
    motion = jpeg("motion", lambda p: sj.bmp_quadrants(p, w, h, seed=3))
    tail = bytes(range(0xFE)) * (70000 // 0xFE + 1)
    ok &= check(b"\xFF" not in tail and len(tail) > 65536 and motion.endswith(b"\xFF\xD9"),
                f"前提：动态照片样本的尾巴 {len(tail)} B > 64KB、不含 FF，主图自己以 FF D9 结尾")
    put("motion", motion + tail)
    # burst_a / burst_b：同一张图（像连拍里不动的场景），只有拍摄时间不同；other_c 象限上下对调。
    # 别用「换个 JPEG 质量」造近似：这种对称的象限图低频系数多半贴着中位数，质量 80 和 90 的 pHash 就差到 10（正好卡线）。
    for name, seed, quads, sec in (("burst_a", 4, sj.QUADS, 0), ("burst_b", 4, sj.QUADS, 1),
                                   ("other_c", 6, sj.QUADS_SWAPPED, 2)):
        data = jpeg(name, lambda p, s=seed, q=quads: sj.bmp_quadrants(p, w, h, seed=s, quads=q))
        data = sj.with_exif(data, orientation=6, datetime_original=f"2026:03:21 10:00:0{sec}",
                            make="SYNTH", model="SYN-1")
        info = sj.exif_info(data)
        ok &= check(info["orientation"] == 6 and info["datetime_original"] == f"2026:03:21 10:00:0{sec}",
                    f"前提：{name} 的手写 APP1 读回来 Orientation=6、DateTimeOriginal 10:00:0{sec}")
        put(name, data)
    shutil.rmtree(tmp)
    return ok


def color_class(rgb):
    r, g, b = rgb
    if r > 150 and g < 100 and b < 100:
        return "红"
    if b > 150 and r < 100 and g < 120:
        return "蓝"
    if g > 140 and r < 100 and b < 100:
        return "绿"
    if r > 150 and g > 150 and b < 100:
        return "黄"
    return f"?{rgb}"


def corner_colors(jpg):
    bmp = os.path.join(WORK, "corner.bmp")
    sj.to_bmp(jpg, bmp)
    w, h, px = sj.read_bmp(bmp)
    os.unlink(bmp)

    def mean(cx, cy):
        # 离边 10% 处 16×16 一块取平均：棋盘格、噪声、JPEG 色度下采样都抹平了，只剩象限的底色。
        pts = [px(cx + dx, cy + dy) for dx in range(-8, 8) for dy in range(-8, 8)]
        return tuple(sum(p[k] for p in pts) // len(pts) for k in range(3))
    return w, h, color_class(mean(w // 10, h // 10)), color_class(mean(w - 1 - w // 10, h // 10))


def native_section():
    print("1. 合成图 → --analyze")
    photos = os.path.join(WORK, "photos")
    if not build_photos(photos):
        return
    data = os.path.join(WORK, "data")
    os.makedirs(data)
    r, dt = run(["--analyze", photos], data)
    out = r.stdout
    check(r.returncode == 0, f"--analyze 退出码 0（{dt:.1f}s）{'' if r.returncode == 0 else r.stderr[-400:]}")
    check(re.search(r"^Done: 8 analyzed, 0 reused in ", out, re.M) is not None,
          f"8 张都分析了：{(re.search(r'^Done: .*$', out, re.M) or [''])[0]}")
    check(re.search(r"^Failed ", out, re.M) is None, "没有解码失败的")
    check(re.search(r"^Corrupt \(1\): trunc$", out, re.M) is not None,
          f"Corrupt 只列截断的那张（动态照片的尾巴不算）：{(re.search(r'^Corrupt.*$', out, re.M) or ['（没有 Corrupt 行）'])[0]}")

    key = session_key(photos)
    sdir = os.path.join(data, "sessions", key)
    try:
        man = {p["id"]: p for p in json.load(open(os.path.join(sdir, "manifest.json")))["photos"]}
        l1 = {x["id"]: x for x in json.load(open(os.path.join(sdir, "layer1_results.json")))["results"]}
    except (OSError, ValueError, KeyError) as e:
        check(False, f"读不了 {sdir} 的 manifest / layer1：{e}")
        return
    ids = ["blur", "white", "control", "trunc", "motion", "burst_a", "burst_b", "other_c"]
    check(sorted(man) == sorted(ids) and sorted(l1) == sorted(ids), f"manifest / layer1 各 8 行：{sorted(l1)}")
    check([i for i in ids if l1.get(i, {}).get("file_corrupt") is True] == ["trunc"],
          f"file_corrupt 只有 trunc：{[i for i in ids if l1.get(i, {}).get('file_corrupt')]}")
    for i in ids:
        check(os.path.isfile(os.path.join(sdir, "previews", i + ".jpg")), f"{i} 有预览图")
    ga, gb, gc = (l1.get(i, {}).get("burst_group") for i in ("burst_a", "burst_b", "other_c"))

    def hamming(x, y):
        try:
            return bin(int(l1[x]["phash"], 16) ^ int(l1[y]["phash"], 16)).count("1")
        except (KeyError, TypeError, ValueError):
            return None
    check(ga is not None and ga == gb, f"burst_a / burst_b 同一个近似重复组（{ga} / {gb}，pHash 差 {hamming('burst_a', 'burst_b')} 位）")
    check(gc is not None and gc != ga,
          f"other_c 在时间窗口里、但 pHash 差得远 → 另一组（{gc}，和 burst_b 差 {hamming('burst_b', 'other_c')} 位）")
    others = [l1.get(i, {}).get("burst_group") for i in ("blur", "white", "control", "trunc", "motion")]
    check(len(set(others)) == 5 and ga not in others, f"没有拍摄时间的 5 张各自一组：{others}")
    check(man.get("burst_a", {}).get("capture_time") == "2026-03-21T10:00:00"
          and man.get("burst_b", {}).get("capture_time") == "2026-03-21T10:00:01",
          f"手写 APP1 的拍摄时间读进了 manifest：{man.get('burst_a', {}).get('capture_time')} / "
          f"{man.get('burst_b', {}).get('capture_time')}")
    check(man.get("blur", {}).get("capture_time") is None, "sips 出的图没有拍摄时间（capture_time 为 null）")
    check(man.get("burst_a", {}).get("camera") == "SYN-1", f"机型从 EXIF 读出来：{man.get('burst_a', {}).get('camera')}")

    prev = os.path.join(sdir, "previews", "burst_a.jpg")
    if os.path.isfile(prev):
        pw, ph = sj.pixel_size(prev)
        ori = sj.exif_info(open(prev, "rb").read())["orientation"]
        check(pw is not None and ph is not None and pw < ph and ori in (None, 1),
              f"Orientation=6 的横图，预览按方向转正存成竖的（{pw}×{ph}，预览自己的方向标记 {ori}）")
        _, _, tl, tr = corner_colors(prev)
        check((tl, tr) == ("蓝", "红"), f"转对了方向（顺时针 90°）：左上 {tl}、右上 {tr}（应是原图左下的蓝、左上的红）")
    prev = os.path.join(sdir, "previews", "control.jpg")
    if os.path.isfile(prev):
        pw, ph = sj.pixel_size(prev)
        _, _, tl, tr = corner_colors(prev)
        check(pw is not None and ph is not None and pw > ph and (tl, tr) == ("红", "绿"),
              f"没有方向标记的照原样：{pw}×{ph}，左上 {tl}、右上 {tr}")

    print("2. 再跑一次 --analyze：全部复用")
    r, dt = run(["--analyze", photos], data)
    check(r.returncode == 0 and re.search(r"^Done: 0 analyzed, 8 reused in ", r.stdout, re.M) is not None,
          f"没变的 8 张全部复用（{dt:.1f}s）：{(re.search(r'^Done: .*$', r.stdout, re.M) or [r.stderr[-200:]])[0]}")
    check(re.search(r"^Corrupt \(1\): trunc$", r.stdout, re.M) is not None, "复用的结果里截断那张照样报损坏")

    print("3. --verdicts --per-photo")
    r, dt = run(["--verdicts", photos, "--per-photo"], data)
    check(r.returncode == 0, f"--verdicts 退出码 0（{dt:.1f}s）")
    text = r.stdout
    pp = per_photo(text)
    check(sorted(pp) == sorted(ids), f"逐张 8 行：{sorted(pp)}")
    th = re.search(r"^阈值: .*$", text, re.M)
    check(th is not None and th.group(0).endswith("预设 标准"),
          f"新分析的场次按「标准」阈值（人脸质量那条开着）：{th.group(0) if th else '（没有阈值行）'}")
    check(re.search(r"^近似重复 1 组 / 2 张 ", text, re.M) is not None,
          f"近似重复 1 组 2 张：{(re.search(r'^近似重复.*$', text, re.M) or [''])[0]}")

    def reasons(i):
        return pp.get(i, ("?", ["?"]))[1]

    def verdict(i):
        return pp.get(i, ("?", []))[0]
    check("虚焦" in reasons("blur") and verdict("blur") == "废片", f"渐变 → 废片 虚焦：{pp.get('blur')}")
    check("曝光裁切" in reasons("white") and "过曝" not in reasons("white") and verdict("white") == "废片",
          f"死白 → 曝光裁切、不判过曝（没有脸）：{pp.get('white')}")
    check(reasons("trunc")[:1] == ["文件损坏"] and verdict("trunc") == "废片", f"截断 → 废片、理由第一条文件损坏：{pp.get('trunc')}")
    for i in ("control", "motion", "burst_a", "burst_b", "other_c"):
        bad = [x for x in reasons(i) if x in ("文件损坏", "虚焦", "曝光裁切")]
        check(not bad, f"{i}（清晰的噪声象限图）没有文件损坏 / 虚焦 / 曝光裁切：{pp.get(i)}")


# ---------------------------------------------------------------- 4. 规模守护

def scale_session(n):
    """photot-session 的 21 行克隆成 n 行：每 3 张一个近似重复组，同组隔 1 秒，组间 5–20 秒，每 400 张停 20 分钟（新章节）。"""
    man = json.load(open(os.path.join(FIX, "manifest.json")))
    l1 = json.load(open(os.path.join(FIX, "layer1_results.json")))
    photos = f"/tmp/labelgui-scale-{n}"
    key = session_key(photos)
    data = os.path.join(WORK, f"scale-{n}")
    sdir = os.path.join(data, "sessions", key)
    os.makedirs(sdir)
    t = 1_774_000_000
    rows_m, rows_l = [], []
    for i in range(n):
        if i % 400 == 0 and i:
            t += 1200
        elif i % 3 == 0:
            t += 5 + (i * 7) % 16
        else:
            t += 1
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t))
        pid = f"P{i:05d}"
        m = dict(man["photos"][i % 21], id=pid, capture_time=stamp, preview_path=f"previews/{pid}.jpg")
        m["raw_path"] = m["decode_path"] = f"{photos}/{pid}.JPG"
        r = dict(l1["results"][i % 21], id=pid, capture_time=stamp, burst_group=i // 3 + 1)
        rows_m.append(m)
        rows_l.append(r)
    json.dump({"photo_dir": photos, "photos": rows_m}, open(os.path.join(sdir, "manifest.json"), "w"))
    json.dump(dict(l1, results=rows_l), open(os.path.join(sdir, "layer1_results.json"), "w"))
    json.dump({"sharpness": 45, "exposure": 0.15, "faceQuality": 0.30}, open(os.path.join(sdir, "thresholds.json"), "w"))
    return photos, data


def scale_section():
    print("4. 规模守护：--verdicts 2000 / 8000 行")
    sizes = {}
    for n in (21, 2000, 8000):
        photos, data = scale_session(n)
        best, line = None, ""
        for _ in range(3):
            r, dt = run(["--verdicts", photos], data, timeout=600)
            if r.returncode != 0:
                check(False, f"{n} 行 --verdicts 退出码 {r.returncode}：{r.stderr[-300:]}")
                return
            line = (re.search(r"^照片 .*$", r.stdout, re.M) or [""])[0]
            best = dt if best is None else min(best, dt)
        check(line.startswith(f"照片 {n} "), f"{n} 行都进了网格：{line}")
        sizes[n] = best
        print(f"    {n} 行：最快 {best:.2f}s")
    base = sizes[21]
    ratio = (sizes[8000] - base) / max(0.05, sizes[2000] - base)
    limit = 60 * SLACK
    check(sizes[8000] < limit, f"8000 行 --verdicts {sizes[8000]:.1f}s < {limit:.0f}s（很宽的上限，只抓数量级的退化）")
    # 耗时比只在 8000 行真花了点时间（本机 ≥ 0.5s，CI 上 ×4 = 2s）时才算数：零点几秒的量级上，runner 抖一下比例就乱了。
    # 本机线性的 8000 行约 0.3s，到不了门槛；O(n²) 的变化部分 ≈ 16 倍，一定过门槛、比例也一定超。
    spent = sizes[8000] - base
    floor = 0.5 * SLACK
    check(ratio < 10 or spent < floor,
          f"8000 行比 2000 行（减掉进程启动 {base:.2f}s）耗时比 {ratio:.1f}（< 10，或者 8000 行总共不到 {floor:.1f}s；"
          f"线性 ≈ 4，O(n²) ≈ 16）")


try:
    native_section()
    if SCALE:
        scale_section()
    if not REAL_BEFORE:
        check(not os.path.exists(REAL_DATA), f"跑之前没有 {REAL_DATA}，跑完也没有（每条命令都走临时数据目录）")
finally:
    if KEEP:
        print(f"工作目录留着：{WORK}")
    else:
        shutil.rmtree(WORK, ignore_errors=True)

if FAILS:
    print(f"\n!! 合成图原生分析冒烟 {len(FAILS)} 条 FAIL")
    sys.exit(1)
print("\n合成图原生分析冒烟全部通过")
