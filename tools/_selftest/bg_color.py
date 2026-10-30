# -*- coding: utf-8 -*-
"""临时脚本（用完可删）：取每张图【背景】的颜色（画面四角 + 上边中点），
用来一眼看出"哪张是红的""红色在第几号文件"。"""
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CARD = sys.argv[1] if len(sys.argv) > 1 else "E:/"


def name(r, g, b):
    mx, mn = max(r, g, b), min(r, g, b)
    sat = (mx - mn) / float(mx or 1)
    if mx < 45:
        return "黑/深灰"
    if sat < 0.15:
        return "白/灰" if mx > 170 else "中灰"
    if mx == r:
        if g > 0.80 * r:
            return "黄"
        if g > 0.30 * r:
            return "橙"
        return "★红★"
    if mx == g:
        return "绿"
    return "浅蓝" if (r + g) > b * 1.15 else "蓝/紫"


def probe(im):
    w, h = im.size
    pts = [(3, 3), (w - 4, 3), (3, h - 4), (w - 4, h - 4), (w // 2, 3)]
    px = [im.getpixel(p) for p in pts]
    r = sum(p[0] for p in px) // len(px)
    g = sum(p[1] for p in px) // len(px)
    b = sum(p[2] for p in px) // len(px)
    return r, g, b, name(r, g, b)


def show(title, paths):
    print("=== %s ===" % title)
    for lab, p in paths:
        if not os.path.isfile(p):
            print("  %-22s (没有)" % lab)
            continue
        r, g, b, n = probe(Image.open(p).convert("RGB"))
        print("  %-22s 背景 rgb(%3d,%3d,%3d)  %s" % (lab, r, g, b, n))
    print()


show("卡上 E:\\*.bmp",
     [("%02d.bmp" % n, os.path.join(CARD, "%02d.bmp" % n)) for n in range(1, 7)])

show("当前母版 sd_assets/*.png",
     [("%02d.png" % n, os.path.join(ROOT, "sd_assets", "%02d.png" % n)) for n in range(1, 7)])

show("旧母版备份 _backup_before_20261014/png/*.png",
     [("%02d.png" % n, os.path.join(ROOT, "sd_assets", "_backup_before_20261014", "png", "%02d.png" % n))
      for n in range(1, 7)])

show("更早的 _png_orig/*.png",
     [("%02d.png" % n, os.path.join(ROOT, "sd_assets", "_png_orig", "%02d.png" % n))
      for n in range(1, 7)])
