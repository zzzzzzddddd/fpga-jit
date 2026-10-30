#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
chk_bmp_zeroth.py -- 看 BMP 里几个关键区段的亮度分布。

为什么要看这个：
  如果 FAT32 的簇/LBA 翻译卡死在第一个扇区，帧缓冲里就会是
  "文件前 512 字节（54 字节头 + 458 字节像素）重复 1801 次"。
  这时屏幕上什么都看不出来【当且仅当】那 458 个像素本身就是暗的。
  所以先把这几个区段的平均亮度算出来，判断这种情形能不能解释"没有图"。

关键区段：
  [0:54]         BMP 头（不是像素）
  [54:512]       第 0 扇区里的 458 个像素字节  ← 重复假说下会铺满全屏
  [54:512+512]   前两个扇区的像素
  [全部像素]     整图
  [最后 512]     文件尾部
"""
import struct
import sys


def region(px, a, b):
    s = px[a:b]
    if not s:
        return None
    return len(s), sum(s) / len(s), max(s), sum(1 for v in s if v > 32) / len(s)


def main(path):
    d = open(path, "rb").read()
    off = struct.unpack_from("<I", d, 10)[0]
    px = d[off:]
    print("文件 %s  像素区 %d 字节  偏移 %d" % (path, len(px), off))
    print()
    print("%-22s %8s %8s %6s %10s" % ("区段", "字节数", "平均", "最大", ">32 占比"))
    for name, a, b in [
        ("[54:512] 第0扇区像素", 0, 458),
        ("[54:1024] 前两扇区像素", 0, 970),
        ("[54:4096+54] 前4KB", 0, 4042),
        ("全图", 0, len(px)),
        ("最后 512 字节", len(px) - 512, len(px)),
    ]:
        r = region(px, a, b)
        if r:
            print("%-22s %8d %8.1f %6d %9.3f" % (name, r[0], r[1], r[2], r[3]))
    print()
    print("前 24 个像素字节 (B,G,R 顺序):")
    print("  " + " ".join("%02X" % v for v in px[0:24]))


if __name__ == "__main__":
    for p in (sys.argv[1:] or ["sd_assets/img0.bmp"]):
        main(p)
        print()
