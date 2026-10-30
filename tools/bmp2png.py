#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bmp2png.py -- 把 24 位 BMP 转成 PNG（纯标准库，不依赖 PIL）。

为什么要有它：
  判断"底图是不是本来就黑"这件事，用 ASCII 亮度图推断太间接了 ——
  直接看图，一眼就够。Read 工具能直接显示 PNG。
"""
import struct
import sys
import zlib


def main(src, dst):
    d = open(src, "rb").read()
    off = struct.unpack_from("<I", d, 10)[0]
    w = struct.unpack_from("<i", d, 18)[0]
    h = struct.unpack_from("<i", d, 22)[0]
    flip = h > 0                      # 正数 = 自下而上
    h = abs(h)
    px = d[off:]
    stride = ((w * 3 + 3) // 4) * 4

    raw = bytearray()
    for row in range(h):
        y = (h - 1 - row) if flip else row
        s = px[y * stride:y * stride + w * 3]
        rgb = bytearray()
        for i in range(0, w * 3, 3):
            rgb += bytes((s[i + 2], s[i + 1], s[i]))     # BGR -> RGB
        raw.append(0)                                    # filter type 0
        raw += rgb

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    open(dst, "wb").write(png)
    print("wrote %s  (%dx%d)" % (dst, w, h))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "sd_assets/img0.bmp",
         sys.argv[2] if len(sys.argv) > 2 else "img0.png")
