# -*- coding: utf-8 -*-
"""
hex2bmp.py -- 把 tb_hud_frame.v 用 $writememh 导出的 .hex 帧数据转成 BMP

在 Verilog 里逐字节 $fwrite 拼 BMP 太慢（一帧 92 万次），所以仿真只导出
"每行一个 24bit 十六进制像素"的 .hex，转换交给这个脚本做。

用法：
    python tools/hex2bmp.py                 # 转换 sim/out_hud_*.hex
    python tools/hex2bmp.py a.hex b.bmp     # 指定单个文件
"""

import glob
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

W, H = 640, 480


def write_bmp(path, w, h, pixels):
    """pixels: 自上而下、每行 w 个 (r,g,b)"""
    rowsize = (w * 3 + 3) & ~3
    pad = rowsize - w * 3
    data = bytearray()
    for y in range(h - 1, -1, -1):          # BMP 是自下而上存
        row = pixels[y]
        for (r, g, b) in row:
            data += bytes((b, g, r))
        data += b"\0" * pad
    filesize = 54 + len(data)
    hdr = b"BM" + struct.pack("<IHHI", filesize, 0, 0, 54)
    dib = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(data), 2835, 2835, 0, 0)
    with open(path, "wb") as f:
        f.write(hdr + dib + bytes(data))


def convert(hex_path, bmp_path):
    # $writememh 会夹杂 "// 0x00000000" 这类地址注释，统一剥掉
    vals = []
    with open(hex_path, "r") as f:
        for line in f:
            line = line.split("//")[0].strip()
            if line:
                vals.append(int(line, 16))
    if len(vals) < W * H:
        raise ValueError("%s 里只有 %d 个像素，期望 %d" % (hex_path, len(vals), W * H))
    pixels = []
    for y in range(H):
        row = []
        base = y * W
        for x in range(W):
            v = vals[base + x]
            row.append(((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF))
        pixels.append(row)
    write_bmp(bmp_path, W, H, pixels)
    print("  %s -> %s" % (os.path.basename(hex_path), os.path.basename(bmp_path)))


def main():
    if len(sys.argv) == 3:
        convert(sys.argv[1], sys.argv[2])
        return
    pattern = os.path.join(ROOT, "sim", "out_hud_*.hex")
    files = sorted(glob.glob(pattern))
    if not files:
        print("没找到 %s，先跑 sim/tb_hud_frame.v" % pattern)
        return
    for h in files:
        convert(h, h[:-4] + ".bmp")


if __name__ == "__main__":
    main()
