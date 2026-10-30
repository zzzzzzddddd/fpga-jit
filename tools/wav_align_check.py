#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wav_align_check.py -- 离线判断"播放侧取字节有没有错位"。

【为什么要这个工具】
  wav_loader 的播放侧从乒乓缓冲里"每拍取 1 个字节、两拍拼 1 个样本"。
  如果相位数错了（少一拍），样本就会**整体错开一个字节** ——
  对 16bit PCM 来说等于把高字节换成噪声，放出来是一片刺耳的电流声，
  而不是语音。而 RTL 里这种错**没有任何编译器/检查器会报**。

  数码管上的探针 D5 = max|样本| >> 12 正是它的指纹：
    16 位有符号 |x| <= 32768  ⇒  D5 只可能是 0..8，
    且 D5=8 **当且仅当**样本里出现过恰好 0x8000 这一个值。

  于是判据（对着板上的读数看）：
    对齐正确 -> 每页的 D5 = 各文件自己的 peak>>12，**各页互不相同**
    错开一个字节 -> 各页**全都是 8**（因为错位后六页都会撞出 0x8000）

【用法】
  python tools/wav_align_check.py                # 检查 sd_assets/*.wav
  python tools/wav_align_check.py --dir <目录>   # 换目录

【输出怎么读】
  每个文件一行：shift=0 是"取对了"时应有的 D5；
  后面几列是"错开 1/2/3 个字节"时分别会是几。
  最后一节会把"哪些 shift 会让六页全都变成 8"列出来。
"""
import argparse
import glob
import os
import struct
import sys


def chunks(b):
    """走一遍 RIFF chunk 链，返回 [(id, 载荷偏移, 载荷长度), ...]。"""
    out = []
    if len(b) < 12 or b[0:4] != b"RIFF" or b[8:12] != b"WAVE":
        return out
    i = 12
    while i + 8 <= len(b):
        cid = b[i:i + 4]
        csz = struct.unpack("<I", b[i + 4:i + 8])[0]
        out.append((cid, i + 8, csz))
        if cid == b"data":
            break
        i += 8 + csz + (csz & 1)   # RIFF 规定长度向上取偶
    return out


def samples(buf):
    """按小端 16 位有符号解释；尾字节丢掉。"""
    n = len(buf) // 2 * 2
    if n == 0:
        return ()
    return struct.unpack("<%dh" % (n // 2), buf[:n])


def d5(buf):
    """max|样本| >> 12，就是数码管 D5 该读到的值。"""
    s = samples(buf)
    if not s:
        return 0, 0
    peak = max(abs(v) for v in s)
    return peak, peak >> 12


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="sd_assets",
                    help="WAV 目录（默认 sd_assets）")
    ap.add_argument("--shifts", type=int, default=4,
                    help="检查前几个字节偏移（默认 4）")
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.dir, "*.wav")))
    if not files:
        print("没找到 WAV：%s" % a.dir)
        return 1

    print("目录：%s" % a.dir)
    print()

    per_shift = {}     # shift -> {basename: D5}

    for p in files:
        b = open(p, "rb").read()
        ch = chunks(b)
        if not ch:
            print("%-10s 不是 RIFF/WAVE，跳过" % os.path.basename(p))
            continue
        dc = [c for c in ch if c[0] == b"data"]
        if not dc:
            print("%-10s 没有 data 块，跳过" % os.path.basename(p))
            continue
        doff, dlen = dc[0][1], dc[0][2]
        data = b[doff:doff + dlen]
        name = os.path.basename(p)

        cols = []
        for sh in range(a.shifts):
            pk, v = d5(data[sh:])
            cols.append("%6d->%X" % (pk, v))
            per_shift.setdefault(sh, {})[name] = v
        print("%-10s data 偏移 %4d 长度 %7d  |  " % (name, doff, dlen)
              + "  ".join("shift%d %s" % (i, c) for i, c in enumerate(cols)))

    print()
    print("★ shift0 是【取对了】时应有的 D5 —— 各文件应当互不相同。")
    print("★ 若 shift1..N 里有一个让**所有**文件都变成 8，而在板上看到的")
    print("  正是「六页全 8」，那就坐实了「样本错开一个字节」。")

    print()
    all8 = []
    for sh in range(a.shifts):
        vals = per_shift.get(sh, {})
        if vals and all(v == 8 for v in vals.values()):
            all8.append(sh)
    base = per_shift.get(0, {})
    print("六个文件全都得到 D5=8 的 shift：%s" % (all8 if all8 else "无"))
    print("shift0（正确对齐）的 D5：%s" % (
        " ".join("%s=%X" % (k, v) for k, v in sorted(base.items())) or "无"))
    if 0 in all8:
        print("!! shift0 自己也全是 8 —— 那说明这些素材的 peak 恰好就是 0x8000，"
              "本判据不适用 !!")
        return 2
    if all8:
        print("=> 错位指纹成立：板上一旦读到「六页全 8」，就是取字节错开了一位。")
        return 0
    print("=> 这些素材里没有「错位即全 8」的指纹，本判据对它们不敏感。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
