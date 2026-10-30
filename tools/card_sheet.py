# -*- coding: utf-8 -*-
"""
card_sheet.py -- 把【TF 卡上真实的】六张 BMP 拼成一张联络表，并按主色打印。

★ 为什么必须用卡上的文件而不是本地 sd_assets/ ★
  之前那张 `_sheet_pages.png` 是从**本地** `sd_assets/fat32/` 生成的，
  而卡上的文件可能是**另一套映射**（换 `PAGE_IMG_SRC` 之前拷的）。
  两套映射里同一个文件名对应的图完全不同 —— 拿错参照物，
  "屏幕上是哪张图"这个判断就整个错掉。所以判读时【必须】用本工具。

纯标准库实现（不依赖 PIL），照 tools/bmp2png.py 的路子自己编 PNG。

用法：
    python tools/card_sheet.py E:\\                  # 只打印每张的主色
    python tools/card_sheet.py E:\\ --sheet out.png  # 再拼一张 2x3 联络表
"""
import os
import struct
import sys
import zlib


def read_bmp24(path):
    """读 24 位 BMP，返回 (width, height, rows)，rows 是自上而下的 RGB bytearray 列表。"""
    d = open(path, "rb").read()
    off = struct.unpack_from("<I", d, 10)[0]
    w = struct.unpack_from("<i", d, 18)[0]
    h = struct.unpack_from("<i", d, 22)[0]
    bpp = struct.unpack_from("<H", d, 28)[0]
    if bpp != 24:
        raise ValueError("%s: 只支持 24 位 BMP，实测 %d 位" % (path, bpp))
    flip = h > 0                       # 正高度 = 自下而上
    h = abs(h)
    stride = ((w * 3 + 3) // 4) * 4
    px = d[off:]
    rows = []
    for row in range(h):
        y = (h - 1 - row) if flip else row
        s = px[y * stride:y * stride + w * 3]
        rgb = bytearray(w * 3)
        for i in range(w):
            rgb[3 * i] = s[3 * i + 2]
            rgb[3 * i + 1] = s[3 * i + 1]
            rgb[3 * i + 2] = s[3 * i]
        rows.append(rgb)
    return w, h, rows


def half(rows, w, h):
    """2x2 盒式抽样，640x480 -> 320x240。"""
    nw, nh = w // 2, h // 2
    out = []
    for y in range(nh):
        r0, r1 = rows[2 * y], rows[2 * y + 1]
        o = bytearray(nw * 3)
        for x in range(nw):
            for c in range(3):
                o[3 * x + c] = (r0[6 * x + c] + r0[6 * x + 3 + c]
                                + r1[6 * x + c] + r1[6 * x + 3 + c]) >> 2
        out.append(o)
    return nw, nh, out


def main_color(rows, w, h):
    """按【绝对彩度】取前 5% 像素求主色 —— 与 real_assets.py 同一套判据。"""
    cand = []
    for y in range(0, h, 2):
        r = rows[y]
        for x in range(0, w, 2):
            R, G, B = r[3 * x], r[3 * x + 1], r[3 * x + 2]
            cand.append((max(R, G, B) - min(R, G, B), R, G, B))
    cand.sort(reverse=True)
    top = cand[:max(1, len(cand) // 20)]
    R = sum(c[1] for c in top) // len(top)
    G = sum(c[2] for c in top) // len(top)
    B = sum(c[3] for c in top) // len(top)
    mx = max(R, G, B)
    if mx == R:
        name = "黄" if G > 0.80 * R else ("橙" if G > 0.30 * R else "红")
    elif mx == G:
        name = "绿"
    else:
        name = "浅蓝" if (R + G) > B * 1.15 else "蓝"
    return (R, G, B), name


def write_png(path, w, h, getrow):
    """getrow(y) -> bytearray(w*3)，写出 8bit RGB PNG。"""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += getrow(y)

    def chunk(tag, data):
        c = tag + data
        return (struct.pack(">I", len(data)) + c
                + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "E:/"
    sheet = sys.argv[sys.argv.index("--sheet") + 1] if "--sheet" in sys.argv else None

    names = ["0%d.BMP" % i for i in range(1, 7)]
    tiles = []
    print("=== 卡上真实素材（%s）===" % src)
    for idx, n in enumerate(names):
        p = os.path.join(src, n)
        if not os.path.exists(p):
            print("  位置%d  %-8s 【缺失】" % (idx + 1, n))
            tiles.append(None)
            continue
        w, h, rows = read_bmp24(p)
        rgb, cn = main_color(rows, w, h)
        print("  位置%d  %-8s %dx%d  主色 rgb%-18s %s" % (idx + 1, n, w, h, str(rgb), cn))
        tiles.append(half(rows, w, h))

    if not sheet:
        return

    TW, TH = 320, 240
    CW, CH = TW * 3, TH * 2
    grid = [bytearray(CW * 3) for _ in range(CH)]      # 全黑底

    for i, t in enumerate(tiles):
        cx, cy = (i % 3) * TW, (i // 3) * TH
        if t is None:
            continue
        nw, nh, rows = t
        for y in range(nh):
            dst = grid[cy + y]
            dst[3 * cx:3 * cx + nw * 3] = rows[y]

    # 左上角画 (i+1) 个白色小方块 —— 方便一眼认出这是第几个文件
    for i in range(6):
        cx, cy = (i % 3) * TW, (i // 3) * TH
        for k in range(i + 1):
            bx, by = cx + 6 + k * 22, cy + 6
            for y in range(by, by + 16):
                for x in range(bx, bx + 16):
                    o = 3 * x
                    grid[y][o] = 255
                    grid[y][o + 1] = 255
                    grid[y][o + 2] = 0          # 黄块

    write_png(sheet, CW, CH, lambda y: grid[y])
    print("\n联络表已写出: %s" % sheet)
    print("布局（每块左上角的黄色小方块个数 = 文件名序号）：")
    print("  [1] 01.BMP   [2] 02.BMP   [3] 03.BMP")
    print("  [4] 04.BMP   [5] 05.BMP   [6] 06.BMP")


if __name__ == "__main__":
    main()
