#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
audio_pwm_check.py -- 逐拍复算 audio_pwm.v 的 sigma-delta。

【为什么要它】
  本工程不跑仿真，audio_pwm 又只有三行算术。数位错了一位、反馈符号反了、
  积分器溢出之后卡死 —— 这几种错都会让输出变成"恒定不动"或者"占空比
  和样本无关"，在喇叭上听起来都是一片电流声，分不出来。

  这个脚本把 audio_pwm.v 的两个 always 块【逐拍照抄】成 Python，
  喂真实 WAV 的样本，然后量：
    1. 输出到底有没有在翻转（翻转次数）；
    2. 每个样本周期内的平均占空比，和"理论上应有的占空比"
       (x + 32768) / 65535 差多少（相关系数）。
  两者都对，就说明数字侧到 H11 这一端是好的，问题在 RC/功放/接线。

【用法】
  python tools/audio_pwm_check.py                     # 用 sd_assets/01.wav
  python tools/audio_pwm_check.py --wav <文件> --ms 100
"""
import argparse
import os
import struct
import sys


def load_wav_samples(path, limit=None, skip=0):
    b = open(path, "rb").read()
    if b[0:4] != b"RIFF" or b[8:12] != b"WAVE":
        raise ValueError("不是 RIFF/WAVE")
    i = 12
    while i + 8 <= len(b):
        cid = b[i:i + 4]
        csz = struct.unpack("<I", b[i + 4:i + 8])[0]
        if cid == b"data":
            d = b[i + 8:i + 8 + csz]
            n = len(d) // 2
            a = min(skip, n)
            n = n - a
            if limit is not None:
                n = min(n, limit)
            return list(struct.unpack("<%dh" % n, d[2 * a:2 * (a + n)]))
        i += 8 + csz + (csz & 1)
    raise ValueError("没有 data 块")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", default=os.path.join("sd_assets", "01.wav"))
    ap.add_argument("--ms", type=float, default=60.0,
                    help="模拟多少毫秒音频（默认 60ms）")
    ap.add_argument("--osr", type=int, default=6250,
                    help="每个样本占几个 clk（100MHz/16kHz = 6250）")
    ap.add_argument("--skip", type=int, default=4000,
                    help="跳过开头多少个样本（默认 4000；这些 WAV 开头是静音，"
                         "静音段里占空比恒为 0.5，相关系数没有意义）")
    a = ap.parse_args()

    nsamp = int(16000 * a.ms / 1000.0)
    x = load_wav_samples(a.wav, limit=nsamp, skip=a.skip)
    if not x:
        print("没读到样本")
        return 1
    pk = max(abs(v) for v in x)
    print("WAV：%s   跳过 %d 个样本后取 %d 个（约 %.1f ms）  OSR=%d"
          % (a.wav, a.skip, len(x), len(x) / 16.0, a.osr))
    print("这一段自己的 peak = %d  （太小就换一段，静音段没有判据意义）" % pk)
    if pk < 1000:
        print("!! 这一段几乎是静音，占空比会恒等于 0.5，判据无效 !!")
        return 2

    # ---- 逐拍照抄 audio_pwm.v ----
    #   sample 在 pcm_stb 那一拍更新；pcm_stb 每 osr 拍来一次
    #   acc(n+1) = acc(n) + x - fb(n)
    #   pwm_out(n+1) = 1 if acc(n+1) >= 0 else 0     （即 ~acc_nxt[17]）
    #   fb(n) = +32767 if pwm_out(n) else -32768
    S18 = 1 << 17          # 18 位有符号的模
    MASK = (1 << 18) - 1

    def wrap18(v):
        v &= MASK
        return v - (1 << 18) if v & S18 else v

    acc = 0
    pwm = 0                       # reset 值
    ones = 0
    cycles = 0
    edges = 0
    prev = 0
    overflows = 0
    duties = []                   # 每个样本周期内的平均占空比
    per_ones = 0
    per_n = 0

    for s in x:
        for _ in range(a.osr):
            fb = 32767 if pwm else -32768
            nxt = acc + s - fb
            if nxt > 131071 or nxt < -131072:
                overflows += 1
            acc = wrap18(nxt)
            pwm = 1 if acc >= 0 else 0
            ones += pwm
            cycles += 1
            if pwm != prev:
                edges += 1
                prev = pwm
            per_ones += pwm
            per_n += 1
        duties.append(per_ones / per_n)
        per_ones = 0
        per_n = 0

    print()
    print("输出翻转次数：%d  （%d 拍里）  ⇒ %.1f MHz 的平均边沿率"
          % (edges, cycles, edges / cycles * 100.0 / 2.0))
    print("整体平均占空比：%.4f  （静音应当 ≈ 0.5000）" % (ones / cycles))
    print("积分器越界次数：%d  （应当是 0）" % overflows)

    # 理论占空比
    theory = [(v + 32768) / 65535.0 for v in x]
    # 相关系数
    md = sum(duties) / len(duties)
    mt = sum(theory) / len(theory)
    num = sum((d - md) * (t - mt) for d, t in zip(duties, theory))
    den = (sum((d - md) ** 2 for d in duties) *
           sum((t - mt) ** 2 for t in theory)) ** 0.5
    corr = num / den if den else float("nan")

    print("每个样本周期的占空比 vs 理论值 (x+32768)/65535：")
    print("  相关系数 = %+.4f   （>0.99 才说明输出真的跟着样本走）" % corr)
    print("  占空比范围 = %.4f .. %.4f   理论范围 = %.4f .. %.4f"
          % (min(duties), max(duties), min(theory), max(theory)))

    print()
    if edges < 1000 or abs(corr) < 0.99:
        print("=> ✗ 输出没有跟着样本走 ⇒ 问题在 audio_pwm 内部")
        return 1
    print("=> ✓ sigma-delta 正常：输出在翻转，占空比紧跟样本")
    print("   ⇒ 数字侧到 H11 引脚这一端没问题，去查 RC / 功放 / 接线。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
