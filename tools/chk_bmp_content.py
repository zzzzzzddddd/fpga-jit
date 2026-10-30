#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
chk_bmp_content.py -- 看看卡上那几张 BMP 到底是什么内容。

用途：屏幕背景全黑时，先排除"图本身就是黑的/文件是坏的"这一项。
（这一步是免费的，比再烧一版位流快得多。）

检查项：
  * BM 签名 / bfSize / bfOffBits / 宽高 / 位深 / 压缩方式
  * 文件实际字节数 vs 头里写的 bfSize
  * 像素区平均亮度、最大亮度、亮像素占比
    - 平均 < 20 且 亮像素占比 < 5%  -> 这张图基本就是黑的
"""
import glob
import os
import struct
import sys


def check(path):
    d = open(path, "rb").read()
    name = os.path.basename(path)
    if len(d) < 54:
        print("%-10s  !! 文件太短 (%d 字节)" % (name, len(d)))
        return
    sig = d[0:2]
    bfsize = struct.unpack_from("<I", d, 2)[0]
    off = struct.unpack_from("<I", d, 10)[0]
    w, h = struct.unpack_from("<ii", d, 18)
    bpp = struct.unpack_from("<H", d, 28)[0]
    comp = struct.unpack_from("<I", d, 30)[0]

    px = d[off:]
    n = len(px)
    if n == 0:
        print("%-10s  !! 像素区为空 (off=%d)" % (name, off))
        return
    avg = sum(px) / n
    mx = max(px)
    nz = sum(1 for b in px if b > 8)
    ok_sig = "OK " if sig in (b"BM",) else "BAD"
    ok_len = "OK " if bfsize == len(d) else "BAD"

    print("%-10s sig=%s(%s) len=%s(%d vs %d) off=%d %dx%d bpp=%d comp=%d "
          "avg=%5.1f max=%3d 亮像素占比=%5.3f"
          % (name, sig, ok_sig, ok_len, bfsize, len(d), off, w, h, bpp, comp,
             avg, mx, nz / n))
    if avg < 20 and nz / n < 0.05:
        print("           ^^^ 这张图基本上就是【全黑】的")


def main():
    roots = sys.argv[1:] or ["sd_assets/fat32"]
    found = []
    for r in roots:
        found += sorted(glob.glob(os.path.join(r, "*.BMP")))
        found += sorted(glob.glob(os.path.join(r, "*.bmp")))
    seen = set()
    found = [p for p in found if not (p.lower() in seen or seen.add(p.lower()))]
    if not found:
        print("没找到 BMP：%s" % roots)
        return 1
    for p in found:
        check(p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
