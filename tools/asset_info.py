#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
asset_info.py -- 看一眼 sd_assets 里源素材的真实格式。

为什么要有它：
  make_fat32_card.py 要的是 img0..5.bmp (640x480x24 BI_RGB, 921654 字节)
  和 aud0..5.pcm (48000Hz/16bit/单声道, 恰好 96000 字节)。
  而 sd_assets 里的源素材是 01..06.png / 01..06.wav，格式未知。
  转之前先量清楚，别猜。
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(HERE), "sd_assets")

PNG_CT = {0: "gray", 2: "RGB", 3: "palette", 4: "gray+alpha", 6: "RGBA"}


def png_info(path):
    d = open(path, "rb").read()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        return "不是 PNG"
    w, h, bd, ct, cm, fm, il = struct.unpack_from(">IIBBBBB", d, 16)
    out = "%dx%d  bitdepth=%d  colortype=%s  interlace=%d" % (w, h, bd, PNG_CT.get(ct, ct), il)
    # 数一下 chunk
    pos, chunks = 8, []
    while pos + 8 <= len(d):
        ln, = struct.unpack_from(">I", d, pos)
        tag = d[pos + 4:pos + 8]
        chunks.append(tag.decode("latin1"))
        if tag == b"tRNS":
            out += "  (有 tRNS 透明块)"
        pos += 12 + ln
    out += "  chunks=%s" % ",".join(chunks[:10])
    return out


def wav_info(path):
    d = open(path, "rb").read()
    if d[:4] != b"RIFF" or d[8:12] != b"WAVE":
        return "不是 RIFF/WAVE"
    pos, got, doff, dlen = 12, {}, None, None
    while pos + 8 <= len(d):
        cid = d[pos:pos + 4]
        csz, = struct.unpack_from("<I", d, pos + 4)
        body = pos + 8
        if cid == b"fmt ":
            af, ch, rate, br, ba, bits = struct.unpack_from("<HHIIHH", d, body)
            got = dict(fmt=af, ch=ch, rate=rate, bits=bits)
        elif cid == b"data":
            doff, dlen = body, csz
        pos = body + csz + (csz & 1)
    if not got:
        return "没有 fmt 块"
    dur = dlen / (got["rate"] * got["ch"] * got["bits"] / 8)
    return ("fmt=%d ch=%d rate=%d bits=%d  data=%d字节 (%.3fs)"
            % (got["fmt"], got["ch"], got["rate"], got["bits"], dlen, dur))


def main():
    print("素材目录: %s\n" % ASSETS)
    for k in range(6):
        p = os.path.join(ASSETS, "%02d.png" % (k + 1))
        tag = "0%d.png" % (k + 1)
        try:
            print("%-10s %s" % (tag, png_info(p)))
        except Exception as e:
            print("%-10s !! %s" % (tag, e))
    print()
    for k in range(6):
        p = os.path.join(ASSETS, "%02d.wav" % (k + 1))
        tag = "0%d.wav" % (k + 1)
        try:
            print("%-10s %s" % (tag, wav_info(p)))
        except Exception as e:
            print("%-10s !! %s" % (tag, e))


if __name__ == "__main__":
    sys.exit(main())
