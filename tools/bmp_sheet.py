#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bmp_sheet.py -- 把六张底图拼成一张 2x3 联络表 PNG，一眼看完六张。

为什么要它：
  "底图到底长什么样"只能看图回答。一张一张看太贵，
  拼成一张 960x480 的联络表，Read 一次就全看到了。
"""
import struct
import sys
import zlib

COLS, ROWS = 3, 2
TW, TH = 320, 240          # 每张缩到 320x240
SC = 2                     # 整数降采样倍数（640/2=320, 480/2=240）


def load(path):
    d = open(path, "rb").read()
    off = struct.unpack_from("<I", d, 10)[0]
    w = struct.unpack_from("<i", d, 18)[0]
    h = struct.unpack_from("<i", d, 22)[0]
    flip = h > 0
    h = abs(h)
    px = d[off:]
    stride = ((w * 3 + 3) // 4) * 4
    rows = []
    for r in range(h):
        y = (h - 1 - r) if flip else r
        s = px[y * stride:y * stride + w * 3]
        rows.append(s)
    return w, h, rows


def main(paths, dst):
    W, H = COLS * TW, ROWS * TH
    canvas = [bytearray(b"\x00" * (W * 3)) for _ in range(H)]

    for idx, p in enumerate(paths[:COLS * ROWS]):
        w, h, rows = load(p)
        cx, cy = idx % COLS, idx // COLS
        for ty in range(TH):
            sy = ty * SC
            if sy >= h:
                break
            s = rows[sy]
            out = canvas[cy * TH + ty]
            base = cx * TW * 3
            for tx in range(TW):
                sx = tx * SC
                if sx >= w:
                    break
                i = sx * 3
                o = base + tx * 3
                out[o] = s[i + 2]
                out[o + 1] = s[i + 1]
                out[o + 2] = s[i]

    raw = bytearray()
    for y in range(H):
        raw.append(0)
        raw += canvas[y]

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    open(dst, "wb").write(png)
    print("wrote %s (%dx%d) from %d images" % (dst, W, H, len(paths[:COLS * ROWS])))


if __name__ == "__main__":
    main(sys.argv[1:-1] or ["sd_assets/img%d.bmp" % i for i in range(6)],
         sys.argv[-1] if len(sys.argv) > 1 else "sheet.png")
