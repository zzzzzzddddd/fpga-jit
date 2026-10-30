#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
make_fat32_card.py -- 把 sd_assets/ 的占位素材整理成【可直接拖进 FAT32 卡根目录】的一套文件

============================================================================
【这个工具解决的是"两代设计对卡片的用法正好相反"这件事】
============================================================================
旧设计（固定 LBA，tools/layout_sd.py 那套）：
    FPGA 直接发 CMD17 按【扇区号】读卡，根本不认识 FAT。
    所以素材必须【裸扇区写入】，用文件管理器拖进去是错的（落在哪个扇区不可控）。
    音频也因此是【裸 PCM 无头】（44 字节的头不是 2 的倍数，会毁掉样本对齐）。

现设计（FAT32 按文件名，fat32_reader.v 那套）：
    FPGA 自己解析 MBR / BPB / 根目录 / 簇链，按 8.3 短名找文件。
    所以素材就是【普通 FAT 文件】：拖进卡根目录、名字对，就行。
    ★ 卡必须是 FAT32 格式化的普通卡，不是裸扇区镜像 ★

============================================================================
【为什么必须"包一层 WAV 头"，不能直接拷 aud*.pcm】
============================================================================
src/wav_loader.v 是真的去走 RIFF chunk 链的（不是"假设 data 紧跟 fmt"），
它要求 fmt 块满足（见 wav_loader.v 的 fmt_ok）：
    audio_format == 1     PCM
    channels     == 1     单声道
    bits         == 16    16bit
且采样率必须是它认识的那几个之一（wav_loader.v 的 rate_known）：
    8000 11025 16000 22050 24000 32000 44100 48000

裸 PCM 喂进去连 "fmt " 块都找不到 -> fmt_ok 永远 0 -> 一声不响。
而 aud*.pcm 的内容本身【格式已经对了】：96000 字节 = 48000 样本 = 1.000 秒
@ 48000Hz / 16bit / 单声道。所以只缺一个标准的 44 字节头，音频数据一个字节都不用动。

============================================================================
【输出：sd_assets/fat32/ ，整个目录拖到卡根目录即可】
============================================================================
    01.BMP .. 06.BMP     <- 由 img0..img5.bmp 改名
    01.WAV .. 06.WAV     <- 由 aud0..aud5.pcm 加 44 字节 RIFF 头

文件名严格 8.3、全大写 —— 这是 RTL 里检索的名字（fat32_reader.v 的 tgt_name()）：
    页号 0..5  -> "0" + (页号+1) + 6个空格填充 + "BMP" / "WAV"
即 01.BMP..06.BMP 和 01.WAV..06.WAV。
    ★ 名字或大小写一变就对不上，而且【不会有任何报错】，只表现为"找不到图/没声音" ★

用法
----
    python tools/make_fat32_card.py                  # 生成到 sd_assets/fat32/
    python tools/make_fat32_card.py --out DIR        # 换输出目录
    python tools/make_fat32_card.py --check          # 只校验素材，不写文件

纯 Python 3，零第三方依赖。
"""

import argparse
import os
import struct
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASSETS = os.path.join(ROOT, "sd_assets")
DEFAULT_OUT = os.path.join(ASSETS, "fat32")

# ---------------------------------------------------------------------------
# 与 RTL 严格对应的常量
# ---------------------------------------------------------------------------
N_FILES = 6

# BMP：bmp_read.v 读 640 宽、24bpp、bottom-up（biHeight 为正）
BMP_W, BMP_H, BMP_BPP = 640, 480, 24
BMP_HDR = 54
BMP_EXPECT = BMP_HDR + BMP_W * BMP_H * BMP_BPP // 8      # 921654

# WAV：wav_loader.v 的 fmt_ok / rate_known
WAV_RATE = 48000
WAV_CHAN = 1
WAV_BITS = 16
PCM_EXPECT = 96000                                       # 48000 样本 * 2 字节
RATE_KNOWN = {8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000}


def log(msg=""):
    print(msg)


def check_bmp(data, tag):
    """校验 BMP 头。返回 (ok, 说明)。"""
    if len(data) != BMP_EXPECT:
        return False, "大小 %d != 期望 %d" % (len(data), BMP_EXPECT)
    if data[:2] != b"BM":
        return False, "签名不是 'BM'"
    fsize, = struct.unpack_from("<I", data, 2)
    offbits, = struct.unpack_from("<I", data, 10)
    hdrsize, = struct.unpack_from("<I", data, 14)
    w, = struct.unpack_from("<i", data, 18)
    h, = struct.unpack_from("<i", data, 22)
    planes, bpp = struct.unpack_from("<HH", data, 26)
    comp, = struct.unpack_from("<I", data, 30)
    problems = []
    if fsize != BMP_EXPECT:
        problems.append("bfSize=%d" % fsize)
    if offbits != BMP_HDR:
        problems.append("bfOffBits=%d(应为54)" % offbits)
    if hdrsize != 40:
        problems.append("biSize=%d(应为40)" % hdrsize)
    if w != BMP_W:
        problems.append("宽=%d" % w)
    if h != BMP_H:
        problems.append("高=%d(必须为正=bottom-up)" % h)
    if planes != 1:
        problems.append("planes=%d" % planes)
    if bpp != BMP_BPP:
        problems.append("bpp=%d" % bpp)
    if comp != 0:
        problems.append("biCompression=%d(应为0=BI_RGB)" % comp)
    if problems:
        return False, ", ".join(problems)
    return True, "%dx%d %dbpp BI_RGB 头54字节 bottom-up" % (w, h, bpp)


def make_wav(pcm):
    """给裸 PCM 加上标准的 44 字节 RIFF/WAVE 头。"""
    byte_rate = WAV_RATE * WAV_CHAN * WAV_BITS // 8
    block_align = WAV_CHAN * WAV_BITS // 8
    hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH",
                                 16,                              # ckSize = 16
                                 1,                               # wFormatTag = 1 (PCM)
                                 WAV_CHAN, WAV_RATE, byte_rate,
                                 block_align, WAV_BITS)
    hdr += b"data" + struct.pack("<I", len(pcm))
    return hdr + pcm


def parse_wav(data):
    """
    按 wav_loader.v 的算法回读一遍（真的走 chunk 链，不假设 data 紧跟 fmt），
    返回 (fmt_audio, fmt_chan, fmt_rate, fmt_bits, data_off, data_len)。
    任何一步对不上就抛异常 —— 这样"工具写对了"和"RTL 能读对"是同一件事被验了两遍。
    """
    if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("不是 RIFF/WAVE")
    pos = 12
    got = {}
    data_off = data_len = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        csz, = struct.unpack_from("<I", data, pos + 4)
        body = pos + 8
        if cid == b"fmt ":
            (afmt, chan, rate, _br, _ba, bits) = struct.unpack_from("<HHIIHH", data, body)
            got = dict(audio=afmt, chan=chan, rate=rate, bits=bits)
        elif cid == b"data":
            data_off, data_len = body, csz
        pos = body + csz + (csz & 1)          # RIFF 规定奇数长度补齐到偶
    if not got:
        raise ValueError("没有 fmt 块")
    if data_off is None:
        raise ValueError("没有 data 块")
    return got["audio"], got["chan"], got["rate"], got["bits"], data_off, data_len


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录（默认 sd_assets/fat32/）")
    ap.add_argument("--check", action="store_true", help="只校验，不写文件")
    args = ap.parse_args()

    log("=" * 74)
    log("make_fat32_card.py -- 整理出可直接拖进 FAT32 卡根目录的素材")
    log("=" * 74)
    log("素材目录: %s" % ASSETS)
    if not args.check:
        log("输出目录: %s" % args.out)
    log()

    if not os.path.isdir(ASSETS):
        log("!! 找不到素材目录 %s" % ASSETS)
        return 1

    if not args.check:
        os.makedirs(args.out, exist_ok=True)

    bad = 0
    log("-" * 74)
    log("%-10s %-12s %-10s %s" % ("卡上名字", "来源", "大小", "校验"))
    log("-" * 74)

    for k in range(N_FILES):
        n = k + 1

        # ---------------- 底图 ----------------
        src = os.path.join(ASSETS, "img%d.bmp" % k)
        dst_name = "%02d.BMP" % n
        if not os.path.isfile(src):
            log("%-10s %-12s %-10s 缺文件" % (dst_name, "img%d.bmp" % k, "-"))
            bad += 1
        else:
            with open(src, "rb") as f:
                data = f.read()
            ok, why = check_bmp(data, dst_name)
            log("%-10s %-12s %-10d %s" % (dst_name, "img%d.bmp" % k, len(data),
                                          ("OK  " + why) if ok else ("** " + why)))
            if not ok:
                bad += 1
            elif not args.check:
                with open(os.path.join(args.out, dst_name), "wb") as f:
                    f.write(data)

        # ---------------- 音频 ----------------
        src = os.path.join(ASSETS, "aud%d.pcm" % k)
        dst_name = "%02d.WAV" % n
        if not os.path.isfile(src):
            log("%-10s %-12s %-10s 缺文件" % (dst_name, "aud%d.pcm" % k, "-"))
            bad += 1
        else:
            with open(src, "rb") as f:
                pcm = f.read()
            problems = []
            if len(pcm) != PCM_EXPECT:
                problems.append("PCM %d 字节 != %d" % (len(pcm), PCM_EXPECT))
            if len(pcm) % 2:
                problems.append("字节数不是偶数，样本对不齐")
            wav = make_wav(pcm)
            try:
                afmt, chan, rate, bits, doff, dlen = parse_wav(wav)
                if afmt != 1:
                    problems.append("audio_format=%d(必须1=PCM)" % afmt)
                if chan != WAV_CHAN:
                    problems.append("声道=%d(必须1)" % chan)
                if bits != WAV_BITS:
                    problems.append("位深=%d(必须16)" % bits)
                if rate not in RATE_KNOWN:
                    problems.append("采样率=%d 不在 rate_known 表内" % rate)
                if dlen != len(pcm):
                    problems.append("data 长度=%d != PCM %d" % (dlen, len(pcm)))
                why = "%dHz/%dbit/%dch %.3fs，头%d字节" % (
                    rate, bits, chan, dlen / (rate * chan * bits / 8), doff)
            except ValueError as e:
                problems.append(str(e))
                why = "-"
            log("%-10s %-12s %-10d %s" % (dst_name, "aud%d.pcm" % k, len(wav),
                                          ("OK  " + why) if not problems else ("** " + "; ".join(problems))))
            if problems:
                bad += 1
            elif not args.check:
                with open(os.path.join(args.out, dst_name), "wb") as f:
                    f.write(wav)

    log("-" * 74)
    log()

    if bad:
        log("!! %d 个素材不合格，先修素材再往卡里拷。" % bad)
        return 1

    log("全部 %d 个素材合格。" % (N_FILES * 2))
    if not args.check:
        log()
        log("下一步（★ 卡必须是 FAT32 格式化的普通卡 ★）：")
        log("  把 %s 里的 12 个文件【整个拖到卡的根目录】，不要放进任何文件夹。" % args.out)
        log()
        log("  ★ 不要再跑旧的 tools/layout_sd.py / write_sd.py ★")
        log("    那是固定 LBA 那套的【裸扇区写入】，会把 FAT 表冲掉，")
        log("    而现设计正是靠 FAT 表按文件名找文件的，跑了就再也找不到文件了。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
