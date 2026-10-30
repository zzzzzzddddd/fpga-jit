#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wav_level_match.py -- 把六段播报的音量调成一样大。

【为什么不能只看 peak】
  六段 WAV 的峰值本来就差着约 6dB（15172..30452）。但**峰值不一样 ≠ 听起来
  响度不一样**：语音的"响度"更接近均方根（RMS），峰值相同的两句话，动态范围
  不同、听起来可以差很多。所以这里按 **RMS（带静音门限）** 对齐，峰值只用来
  限制增益、防止削顶。

【口径：带门限的 RMS（近似"只算有人说话的那些帧"）】
  1) 按 20ms 分帧（16kHz ⇒ 320 点/帧），算每帧 RMS
  2) 门限 = 本文件最大帧 RMS 的 -35dB，**只统计高于门限的帧**
     —— 把首尾静音和背景底噪排除掉，否则"静音多的一段"会被算得更轻。
  3) 该文件的响度 = 这些帧的能量平均再开方

【目标电平怎么定（保证六段都不会削顶）】
  对第 i 段：g_i_max = CEIL / peak_i     （使它自己刚好不削顶的最大增益）
  取   T = min_i ( loud_i × g_i_max )
  ⇒ 每段的增益 g_i = T / loud_i，恒有 g_i ≤ g_i_max ⇒ **一段都不会削顶**，
    而且 T 是"所有段都能同时达到"的最高公共电平（至少有一段正好顶到 CEIL）。

【用法】
    python tools/wav_level_match.py            # 只量，不改（打印对照表）
    python tools/wav_level_match.py --apply    # 改（原文件先备份到 _wav_orig/）
"""
import argparse
import math
import os
import shutil
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "sd_assets")
BACKUP = os.path.join(ASSETS, "_wav_orig")
FILES = ["%02d.wav" % n for n in range(1, 7)]

CEIL = 0.90            # 允许的最高峰值（占满量程的比例）⇒ 留约 -1dB 余量
GATE_DB = -35.0        # 相对门限：低于"本文件最大帧"这个数的帧不算进响度


def read_wav(path):
    """返回 (rate, channels, bits, samples[list[int]], raw_header_bytes)"""
    raw = open(path, "rb").read()
    if raw[0:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError("%s 不是 RIFF/WAVE" % path)
    pos = 12
    fmt = None
    data_off = data_len = None
    while pos + 8 <= len(raw):
        cid = raw[pos:pos + 4]
        csz = struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", raw[body:body + 16])
        elif cid == b"data":
            data_off, data_len = body, csz
        pos = body + csz + (csz & 1)      # chunk 按偶数字节对齐
    if fmt is None or data_off is None:
        raise ValueError("%s 缺 fmt 或 data 块" % path)
    _, ch, rate, _, _, bits = fmt
    if bits != 16:
        raise ValueError("%s 不是 16bit（%d）" % (path, bits))
    n = data_len // 2
    samples = list(struct.unpack("<%dh" % n, raw[data_off:data_off + n * 2]))
    return rate, ch, bits, samples, raw, data_off, data_len


def gated_rms(x, frame_len):
    """带门限的 RMS（见文件头）。返回 (loud, plain_rms, peak)"""
    n = len(x)
    peak = max(abs(v) for v in x) if n else 0
    if n == 0:
        return 0.0, 0.0, 0
    plain = math.sqrt(sum(v * v for v in x) / n)

    fr = []
    for i in range(0, n - frame_len + 1, frame_len):
        s = 0
        for v in x[i:i + frame_len]:
            s += v * v
        fr.append(math.sqrt(s / frame_len))
    if not fr:
        fr = [plain]
    mx = max(fr)
    thr = mx * (10.0 ** (GATE_DB / 20.0))
    keep = [v for v in fr if v >= thr]
    if not keep:
        keep = [mx]
    # 能量平均（不是把帧 RMS 直接平均）
    loud = math.sqrt(sum(v * v for v in keep) / len(keep))
    return loud, plain, peak


def db(x):
    return 20.0 * math.log10(x / 32768.0) if x > 0 else -999.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="真的写回（默认只量）")
    ap.add_argument("--dir", default=ASSETS,
                    help="素材目录（默认 sd_assets/）。用 E:\\ 可以直接量卡上的文件")
    a = ap.parse_args()

    assets = a.dir
    if not os.path.isdir(assets):
        raise SystemExit("目录不存在：%s" % assets)

    info = {}
    for f in FILES:
        p = os.path.join(assets, f)
        if not os.path.isfile(p):
            raise SystemExit("找不到 %s" % p)
        rate, ch, bits, x, raw, doff, dlen = read_wav(p)
        frame = int(rate * 0.020)
        loud, plain, peak = gated_rms(x, frame)
        info[f] = dict(rate=rate, ch=ch, x=x, raw=raw, doff=doff, dlen=dlen,
                       loud=loud, plain=plain, peak=peak)

    print("=== 改之前 ===")
    print("  %-9s %8s %8s %9s %10s %9s %10s" %
          ("文件", "样本数", "峰值dB", "峰值因数", "响度(带门限)", "门限dB",
           "全段RMS dB"))
    for f in FILES:
        d = info[f]
        crest = db(d["peak"]) - db(d["loud"])
        print("  %-9s %8d %8.1f %8.1f %12.0f %9.1f %10.1f" %
              (f, len(d["x"]), db(d["peak"]), crest, d["loud"], db(d["loud"]),
               db(d["plain"])))
    print("  （门限 dB 和全段 RMS dB 差得多 = 门限筛掉了不少静音段，属正常）")

    # ---- 目标电平：所有段都能达到的最高公共 RMS ----
    T = min(info[f]["loud"] * (CEIL * 32767.0 / max(info[f]["peak"], 1))
            for f in FILES)
    print()
    print("  公共目标响度 T = %.0f  (%.1f dBFS)，峰值上限 = %.0f (%.1f dBFS)"
          % (T, db(T), CEIL * 32767, db(CEIL * 32767)))

    print()
    print("=== 各段增益（并核对峰值不会超上限）===")
    print("  %-9s %9s %10s %10s %8s" %
          ("文件", "增益dB", "新峰值", "新峰值dB", "削顶"))
    plan = {}
    for f in FILES:
        d = info[f]
        g = T / d["loud"]
        newpeak = d["peak"] * g
        clip = "是" if newpeak > CEIL * 32767 + 0.5 else "否"
        plan[f] = g
        print("  %-9s %+9.2f %10.0f %9.1f %8s" %
              (f, 20.0 * math.log10(g), newpeak, db(newpeak), clip))

    if not a.apply:
        print()
        print("（只是量了一遍，没有改动任何文件。要写回请加 --apply）")
        return 0

    # ---- 写回 ----
    if not os.path.isdir(BACKUP):
        os.makedirs(BACKUP)
    for f in FILES:
        src = os.path.join(assets, f)
        bakf = os.path.join(BACKUP, f)
        if not os.path.exists(bakf):
            shutil.copy2(src, bakf)
        d = info[f]
        g = plan[f]
        out = []
        for v in d["x"]:
            y = int(round(v * g))
            if y > 32767:
                y = 32767
            elif y < -32768:
                y = -32768
            out.append(y)
        blob = d["raw"][:d["doff"]] + struct.pack("<%dh" % len(out), *out)
        if len(blob) != len(d["raw"]):
            raise SystemExit("%s 长度变了（%d != %d）—— 不能改，卡上目录项会错"
                             % (f, len(blob), len(d["raw"])))
        with open(src, "wb") as fh:
            fh.write(blob)

    print()
    print("★ 已写回 sd_assets/0N.wav（原文件备份在 sd_assets/_wav_orig/）")
    print("  文件长度【逐字节不变】—— 覆盖到卡上时目录项不动，顺序不受影响。")

    # ---- 复量 ----
    print()
    print("=== 改之后（复核）===")
    print("  %-9s %10s %10s %10s" % ("文件", "峰值", "峰值dB", "响度dB"))
    worst = 0.0
    for f in FILES:
        _, _, _, x, _, _, _ = read_wav(os.path.join(assets, f))
        loud, _, peak = gated_rms(x, int(16000 * 0.020))
        print("  %-9s %10d %9.1f %9.1f" % (f, peak, db(peak), db(loud)))
        worst = max(worst, abs(db(loud) - db(T)))
    print()
    print("  与目标的最大偏差 = %.2f dB" % worst)
    print("  通过" if worst < 0.5 else "  ★ 偏差偏大，检查一下")
    return 0


if __name__ == "__main__":
    sys.exit(main())
