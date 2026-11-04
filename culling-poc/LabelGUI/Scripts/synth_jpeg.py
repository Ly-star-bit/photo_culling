"""合成测试图（不要真照片）：BMP 手写像素 → sips 转 JPEG → 手写 EXIF APP1（拍摄时间、方向、机型、GPS）塞进去；
再反过来读 JPEG 的 EXIF / XMP 有没有 GPS、读 BMP 的像素。native_analysis_smoke.py、delivery_regression.py 共用。

这些脚本按仓库习惯用 python3 -I 跑（不把脚本目录放进 sys.path），所以别处用 importlib 按路径加载：
    spec = importlib.util.spec_from_file_location("synth_jpeg", os.path.join(os.path.dirname(__file__), "synth_jpeg.py"))
只用标准库。"""
import os, random, struct, subprocess

# ---------------------------------------------------------------- BMP

def write_bmp(path, w, h, row):
    """24 位 BMP。row(y) 给第 y 行（从上往下数）的像素字节，按 B G R 排，长度 w*3。"""
    rb = w * 3
    pad = b"\0" * ((4 - rb % 4) % 4)
    body = bytearray()
    for y in range(h - 1, -1, -1):  # BMP 从下往上存
        data = row(y)
        assert len(data) == rb
        body += data + pad
    hdr = struct.pack("<2sIHHI", b"BM", 54 + len(body), 0, 0, 54)
    hdr += struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(body), 2835, 2835, 0, 0)
    with open(path, "wb") as f:
        f.write(hdr + body)


def bmp_flat(path, w, h, rgb):
    px = bytes((rgb[2], rgb[1], rgb[0])) * w
    write_bmp(path, w, h, lambda y: px)


def bmp_gradient(path, w, h, lo=30, hi=220):
    """横向平滑渐变（灰，lo → hi）：没有一处边缘，锐度接近 0；两端不到 0 / 255，不会算成曝光裁切。"""
    px = bytearray()
    for x in range(w):
        v = lo + (hi - lo) * x // max(1, w - 1)
        px += bytes((v, v, v))
    px = bytes(px)
    write_bmp(path, w, h, lambda y: px)


# 四个象限的颜色（R, G, B）：左上红、右上绿、左下蓝、右下黄。都在 60–190 之间，加上棋盘格 ±30、噪声 +8
# 也不到 0 / 255（不算曝光裁切）。
QUADS = ((190, 60, 60), (60, 180, 60), (60, 70, 190), (190, 180, 60))
QUADS_SWAPPED = ((60, 70, 190), (190, 180, 60), (190, 60, 60), (60, 180, 60))  # 上下两半对调：pHash 差很远


def bmp_quadrants(path, w, h, seed, quads=QUADS, checker=30, cell=4, amp=8):
    """四个象限四种颜色，每个象限里叠一层 cell 像素的棋盘格（亮暗差 2×checker，锐度高，像对焦清楚的细节）
    和每像素噪声（JPEG 才有几百 KB）。同一套象限 + 同一个 seed = 同一张图。"""
    rnd = random.Random(seed)
    table = bytes((b * amp) // 256 for b in range(256))
    half_w, half_h = w // 2, h // 2

    def px(c, d):
        return bytes((c[2] + d, c[1] + d, c[0] + d))

    def line(left, right, parity):
        out = bytearray()
        for x in range(w):
            d = checker if ((x // cell) + parity) % 2 == 0 else -checker
            out += px(left if x < half_w else right, d)
        return int.from_bytes(out, "big")
    rows = {(half, parity): line(quads[0 if half == 0 else 2], quads[1 if half == 0 else 3], parity)
            for half in (0, 1) for parity in (0, 1)}
    rb = w * 3

    def row(y):
        base = rows[(0 if y < half_h else 1, (y // cell) % 2)]
        noise = int.from_bytes(rnd.randbytes(rb).translate(table), "big") if amp else 0
        return (base + noise).to_bytes(rb, "big")
    write_bmp(path, w, h, row)


def read_bmp(path):
    """sips 转出来的 BMP（24 / 32 位，自下而上或自上而下）→ (w, h, pixel(x, y) -> (r, g, b))，y 从上往下数。"""
    data = open(path, "rb").read()
    off = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    step = bpp // 8
    rb = (w * step + 3) // 4 * 4
    top_down = h < 0
    h = abs(h)

    def pixel(x, y):
        yy = y if top_down else h - 1 - y
        i = off + yy * rb + x * step
        b, g, r = data[i], data[i + 1], data[i + 2]
        return r, g, b
    return w, h, pixel


def to_jpeg(bmp, jpg, quality=80):
    r = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", str(quality), bmp, "--out", jpg],
                       capture_output=True)
    if r.returncode != 0 or not os.path.isfile(jpg):
        raise RuntimeError(f"sips 转不出 JPEG：{r.stderr[-300:]!r}")


def to_bmp(src, bmp):
    r = subprocess.run(["sips", "-s", "format", "bmp", src, "--out", bmp], capture_output=True)
    if r.returncode != 0 or not os.path.isfile(bmp):
        raise RuntimeError(f"sips 转不出 BMP：{r.stderr[-300:]!r}")


def pixel_size(path):
    r = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True)
    vals = {}
    for line in r.stdout.splitlines():
        parts = line.split(":")
        if len(parts) == 2 and parts[0].strip() in ("pixelWidth", "pixelHeight"):
            vals[parts[0].strip()] = int(parts[1])
    return vals.get("pixelWidth"), vals.get("pixelHeight")


# ---------------------------------------------------------------- EXIF APP1（小端 TIFF）

SHORT, LONG, ASCII, RATIONAL, BYTE = 3, 4, 2, 5, 1


def _ascii(s):
    b = s.encode("ascii") + b"\0"
    return (ASCII, len(b), b)


def _rationals(vals):
    out = b""
    for num, den in vals:
        out += struct.pack("<II", num, den)
    return (RATIONAL, len(vals), out)


def _ifd(entries, start):
    """entries: {tag: (type, count, bytes)}，start = 这个 IFD 在 TIFF 里的偏移。返回字节（含放不下 4 字节的值）。"""
    n = len(entries)
    data_at = start + 2 + 12 * n + 4
    head = struct.pack("<H", n)
    extra = b""
    for tag in sorted(entries):
        typ, count, val = entries[tag]
        if len(val) <= 4:
            head += struct.pack("<HHI", tag, typ, count) + val.ljust(4, b"\0")
        else:
            head += struct.pack("<HHII", tag, typ, count, data_at + len(extra))
            extra += val + (b"\0" if len(val) % 2 else b"")
    return head + struct.pack("<I", 0) + extra


def exif_app1(orientation=None, datetime_original=None, subsec=None, make=None, model=None, gps=None):
    """手写的 EXIF APP1 段（FF E1 …）。gps = (lat, lon) 十进制度（北纬 / 东经为正）。"""
    ifd0 = {}
    if make:
        ifd0[0x010F] = _ascii(make)
    if model:
        ifd0[0x0110] = _ascii(model)
    if orientation:
        ifd0[0x0112] = (SHORT, 1, struct.pack("<H", orientation))
    exif = {}
    if datetime_original:
        exif[0x9003] = _ascii(datetime_original)
    if subsec:
        exif[0x9291] = _ascii(subsec)
    gps_ifd = {}
    if gps:
        lat, lon = gps

        def dms(v):
            v = abs(v)
            d = int(v)
            m = int((v - d) * 60)
            s = round(((v - d) * 60 - m) * 60 * 100)
            return [(d, 1), (m, 1), (s, 100)]
        gps_ifd[0x0000] = (BYTE, 4, bytes((2, 3, 0, 0)))
        gps_ifd[0x0001] = _ascii("N" if lat >= 0 else "S")
        gps_ifd[0x0002] = _rationals(dms(lat))
        gps_ifd[0x0003] = _ascii("E" if lon >= 0 else "W")
        gps_ifd[0x0004] = _rationals(dms(lon))
    # 指针先占位（LONG 放得下，IFD0 的长度不变），算出子 IFD 的位置再填真值。
    if exif:
        ifd0[0x8769] = (LONG, 1, struct.pack("<I", 0))
    if gps_ifd:
        ifd0[0x8825] = (LONG, 1, struct.pack("<I", 0))
    first = _ifd(ifd0, 8)
    pos = 8 + len(first)
    exif_at = pos
    exif_bytes = _ifd(exif, exif_at) if exif else b""
    pos += len(exif_bytes)
    gps_at = pos
    gps_bytes = _ifd(gps_ifd, gps_at) if gps_ifd else b""
    if exif:
        ifd0[0x8769] = (LONG, 1, struct.pack("<I", exif_at))
    if gps_ifd:
        ifd0[0x8825] = (LONG, 1, struct.pack("<I", gps_at))
    tiff = b"II*\0" + struct.pack("<I", 8) + _ifd(ifd0, 8) + exif_bytes + gps_bytes
    payload = b"Exif\0\0" + tiff
    return b"\xFF\xE1" + struct.pack(">H", len(payload) + 2) + payload


def segments(data):
    """JPEG 的段（SOS 之前）：[(marker, 整段字节)]，和 SOS 起的剩余字节。"""
    assert data[:2] == b"\xFF\xD8", "不是 JPEG"
    i = 2
    segs = []
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            raise ValueError(f"第 {i} 字节不是段标记")
        marker = data[i + 1]
        if marker == 0xDA:
            return segs, data[i:]
        length = struct.unpack_from(">H", data, i + 2)[0]
        segs.append((marker, data[i:i + 2 + length]))
        i += 2 + length
    return segs, b""


def with_exif(data, **kw):
    """把 JPEG 里原有的 EXIF APP1 换成手写的那段（放在 APP0 后面）。"""
    segs, rest = segments(data)
    out = b"\xFF\xD8"
    app1 = exif_app1(**kw)
    placed = False
    for marker, seg in segs:
        if marker == 0xE1 and seg[4:10] == b"Exif\0\0":
            continue
        if not placed and marker != 0xE0:
            out += app1
            placed = True
        out += seg
    if not placed:
        out += app1
    return out + rest


def exif_info(data):
    """JPEG 里 EXIF 的几样：orientation、datetime_original、gps_entries（GPS IFD 的条目数，没有 = 0）。"""
    info = {"orientation": None, "datetime_original": None, "gps_entries": 0, "xmp_gps": False}
    try:
        segs, _ = segments(data)
    except (AssertionError, ValueError, struct.error):
        return info
    for marker, seg in segs:
        if marker == 0xE1 and b"http://ns.adobe.com/xap/1.0/" in seg[:40]:
            info["xmp_gps"] = info["xmp_gps"] or b"GPSLatitude" in seg or b"GPSLongitude" in seg
        if marker != 0xE1 or seg[4:10] != b"Exif\0\0":
            continue
        t = seg[10:]
        le = t[:2] == b"II"
        e = "<" if le else ">"

        def entries(off):
            n = struct.unpack_from(e + "H", t, off)[0]
            for k in range(n):
                tag, typ, count = struct.unpack_from(e + "HHI", t, off + 2 + 12 * k)
                yield tag, typ, count, off + 2 + 12 * k + 8

        def value_off(typ, count, at):
            size = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1}.get(typ, 1) * count
            return at if size <= 4 else struct.unpack_from(e + "I", t, at)[0]
        ifd0 = struct.unpack_from(e + "I", t, 4)[0]
        for tag, typ, count, at in entries(ifd0):
            if tag == 0x0112:
                info["orientation"] = struct.unpack_from(e + "H", t, at)[0]
            elif tag == 0x8769:
                sub = struct.unpack_from(e + "I", t, at)[0]
                for tag2, typ2, count2, at2 in entries(sub):
                    if tag2 == 0x9003:
                        o = value_off(typ2, count2, at2)
                        info["datetime_original"] = t[o:o + count2].rstrip(b"\0").decode("ascii", "replace")
            elif tag == 0x8825:
                sub = struct.unpack_from(e + "I", t, at)[0]
                info["gps_entries"] = struct.unpack_from(e + "H", t, sub)[0]
    return info


def has_gps(data):
    info = exif_info(data)
    return info["gps_entries"] > 0 or info["xmp_gps"]
