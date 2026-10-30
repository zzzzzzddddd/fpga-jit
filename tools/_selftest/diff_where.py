# -*- coding: utf-8 -*-
"""临时脚本（用完可删）：卡上 BMP 与 real_assets 现场生成版，
把差异像素的位置分布打出来 —— 判断差异是"全局微量重编码"还是"集中在某个角落"。"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import real_assets as RA                                    # noqa: E402

CARD = sys.argv[1] if len(sys.argv) > 1 else "E:/"
W, H = 640, 480
ROW = W * 3


def rows_to_grid(buf):
    """bottom-up BGR 像素流 -> grid[y][x] = (r,g,b)，y 自下而上与原文件同序。"""
    g = []
    for y in range(H):
        line = buf[y * ROW:(y + 1) * ROW]
        g.append([(line[i + 2], line[i + 1], line[i]) for i in range(0, ROW, 3)])
    return g


for page in range(6):
    n = page + 1
    m = RA.PAGE_IMG_SRC[page]
    w, h, rows = RA.decode_png_rgb(os.path.join(ROOT, "sd_assets", "%02d.png" % m))
    tf = os.path.join(tempfile.gettempdir(), "w_%02d.bmp" % n)
    RA.write_bmp_24_bottomup(tf, w, h, rows)
    gen = open(tf, "rb").read()[54:]
    card = open(os.path.join(CARD, "%02d.bmp" % n), "rb").read()[54:]
    ga = rows_to_grid(gen)
    gb = rows_to_grid(card)

    big = []          # 差 > 10 的像素位置
    nbig = 0
    for y in range(H):
        ra, rb = ga[y], gb[y]
        for x in range(W):
            d = max(abs(ra[x][0] - rb[x][0]), abs(ra[x][1] - rb[x][1]), abs(ra[x][2] - rb[x][2]))
            if d > 10:
                nbig += 1
                if nbig <= 400000:
                    big.append((x, y, d))
    if not big:
        print("%02d.BMP  没有差 >10 的像素" % n)
        continue
    xs = [b[0] for b in big]
    ys = [b[1] for b in big]
    ds = [b[2] for b in big]
    print("%02d.BMP  差>10 的像素 %6d 个 (%.3f%%)  x:%d..%d  y:%d..%d  最大差 %d"
          % (n, nbig, 100.0 * nbig / (W * H), min(xs), max(xs), min(ys), max(ys), max(ds)))
    # 按 8x8 网格看热点
    cellw, cellh = W // 8, H // 8
    hot = {}
    for x, y, d in big:
        hot[(x // cellw, y // cellh)] = hot.get((x // cellw, y // cellh), 0) + 1
    top = sorted(hot.items(), key=lambda kv: -kv[1])[:4]
    print("        热点(列,行 各8格, y 自下而上)：%s" % ", ".join(
        "(col%d,row%d)=%d" % (k[0], k[1], v) for k, v in top))
