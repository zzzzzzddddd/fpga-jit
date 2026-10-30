#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
view_bmp.py -- 把 BMP 画成 ASCII 亮度图 + 亮度直方图。

为什么要看这个：
  屏幕上"全黑"只有两种可能：
    (a) 数据根本没送到显示端      -> 图本身必须是有内容的
    (b) 数据送到了，但图本身就是暗的 -> 那么"全黑"其实是"图就是这张"
  先把图本身看成什么样子，才能把 (a)/(b) 分开。
"""
import struct
import sys
import statistics


def main(path):
    d = open(path, "rb").read()
    off = struct.unpack_from("<I", d, 10)[0]
    w = struct.unpack_from("<i", d, 18)[0]
    h = struct.unpack_from("<i", d, 22)[0]
    bpp = struct.unpack_from("<H", d, 28)[0]
    comp = struct.unpack_from("<I", d, 30)[0]
    print("%s  w=%d h=%d bpp=%d comp=%d off=%d len=%d" %
          (path, w, h, bpp, comp, off, len(d)))
    px = d[off:]
    stride = ((w * 3 + 3) // 4) * 4
    lum = []
    for y in range(h):
        row = px[y * stride:y * stride + w * 3]
        for x in range(w):
            b, g, r = row[x * 3], row[x * 3 + 1], row[x * 3 + 2]
            lum.append((r * 299 + g * 587 + b * 114) // 1000)

    s = lum[::7]
    print("  lum  min=%d max=%d mean=%.1f median=%d" %
          (min(lum), max(lum), sum(lum) / len(lum), statistics.median(lum)))
    for t in (8, 16, 32, 48, 64, 96, 128, 192):
        print("    P(lum>=%3d) = %.4f" % (t, sum(1 for v in s if v >= t) / len(s)))
    print()
    chars = " .:-=+*#%@"
    for yy in range(0, h, 16):
        line = "".join(chars[min(9, lum[yy * w + xx] * 10 // 256)]
                       for xx in range(0, w, 8))
        print("  " + line)
    print()


if __name__ == "__main__":
    for p in (sys.argv[1:] or ["sd_assets/img0.bmp"]):
        main(p)
