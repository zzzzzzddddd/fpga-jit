#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
real_assets.py -- 把【真素材】sd_assets/0N.png + 0N.wav 打成可以拖进 FAT32 卡根目录的一套文件

============================================================================
【为什么需要这个脚本 —— 之前卡上装的一直是占位素材】
============================================================================
tools/gen_sd_assets.py 的文件头第一句就写着「这是占位素材，不是最终美术素材」。
它产出的是 img0..5.bmp —— 六张"深色 HMI 空模板"（只有 P0..P5 页码牌和色带，
主体是空面板），那是用来跑通 SD 通路的。**真素材 01..06.png（六张储罐实景照片）
一直没有被转换、也从来没进过卡。**

后果极具迷惑性：整条链路（SD → FAT32 → 帧缓冲 → HDMI）全都是好的，
但屏幕上是一张本来就很暗的空模板 ⇒ 看起来像"底图全黑 / 不出图"。

============================================================================
【页 -> 卡上文件名 -> 源素材】（2026-10-04 按要求排定）
============================================================================
  页0  01.BMP <- 01.png   深蓝底
  页1  02.BMP <- 02.png   浅蓝底
  页2  03.BMP <- 03.png   橙底
  页3  04.BMP <- 04.png   紫底
  页4  05.BMP <- 05.png   绿底
  页5  06.BMP <- 06.png   ★红底 = 报警页★

  ★★ 2026-10-14：母版已从卡上【回灌】，映射是恒等 —— 但"06 必须是红的"没变 ★★
    这一天换素材的来龙去脉，记下来免得再踩：
      · 上一批（_backup_before_20261014/png/）是【实景照】，颜色在【罐体】上：
          01=白罐 02=红罐 03=浅蓝罐 04=绿罐 05=深蓝罐 06=橙罐
        所以那时的映射是 [1,3,4,5,6,2] —— 把红罐 02.png 送去页5。
      · 这一批是重新渲染的：罐体【全变蓝】，颜色改由【背景】区分。
        红的那张挪到了 06.png，映射没跟着改 ⇒ 报警页一度显示的是绿底那张。
      · 修法：卡上 05/06 对调，再把卡上的图【回灌成母版】（tools/bmp2png.py，
        旧母版备份在 _backup_png_before_backfill/）。
        ⇒ 母版编号现在【就是】卡的编号，所以 PAGE_IMG_SRC = [1,2,3,4,5,6]，
          06.png 天然就是红色的那张，要求由"编号本身"保证。

  ★ 仍然要守的规矩：**06.png 必须一直是红色那张**。
    将来换 06.png 时先看一眼颜色，红的放 06，否则报警页会显示错图。

  改顺序只改一个常量：下面的 PAGE_IMG_SRC（下标 = 页号，值 = 源素材编号）。

  ★ 为什么红色那张【必须】落在 06 ★
      src/hud/hud_data_gen.v:330   assign o_img_index = disp_page;
      src/bmp_read.v:410           f_file_idx <= {1'b0, img_index};   // 0..5 -> 01..06.BMP
      src/hud/hud_data_gen.v:328   dst_page = alarm_active ? 3'd5 : rot_page;
    ⇒ 报警页永远是【页 5】⇒ 它取到的图永远是 06.BMP。
      所以"红色的那张对应报警页"这件事，把红图放进 06.BMP 就完了，**RTL 一行都不用动**。
      页3/页5 的对应关系也可以反过来验：`bmp_read` 的 `img_index` 就是 `disp_page`。

  ★ 音频不跟着底图跑 ★
    0N.WAV 是【页 N 的播报】，不是【第 N 张图】的解说 —— 所以底图换位之后，
    01..06.WAV 的编号一个都不动。
    依据：top.v 里"故障页停留期间每 6 秒重播"写死 `frag_idx = 5` -> 06.WAV，
    SPEC 也写着「故障 -> 显示 06、播 06.WAV」。
    （万一你那六段其实是"第 N 张图"的解说，把下面的 WAV_FOLLOW_IMG 改成 True
      重跑一次即可，图挪到哪音频跟到哪。）

============================================================================
【输出格式：必须严格符合，RTL 就是这个读法】
============================================================================
  sd_assets/fat32/0N.BMP   640x480x24 未压缩 BI_RGB
                           正好 921654 字节 = 54 + 640*480*3
                           头 54 字节，bfOffBits=54，像素紧跟其后
                           ★ biHeight = +480，【自下而上】(bottom-up) 写 ★

  ==========================================================================
  【★ 行序必须是 bottom-up —— 它和 top.v 的 ROW_REVERSE 是一对 ★】
  ==========================================================================
  BMP 的标准写法就是 bottom-up（文件第 0 行 = 图像【底】行），这里就用标准的。

  为什么必须是 bottom-up，从 RTL 一步步推（不用猜）：

    bmp_read.v:199  header_match = ('B') && ('M') && (width[15:0]==640)
                    —— 【不看 height 的符号】；:204 的 bmp_data_valid 也是纯数字节
    ⇒ 像素按【文件字节顺序】线性搬进帧缓冲，fb 低地址 = 文件第 0 行
    frame_fifo_read.v:183  ROW_REVERSE=0 = 线性 +1；:151/:171 = 1 = 从最后一行递减
    ⇒ top.v 现在传的是 ROW_REVERSE=1（从 fb 最后一行开始读）
    ⇒ 屏幕第 0 行 = fb 最后一行 = 文件最后一行 = 图像【顶】行  ✓ 正像

  ★★ ROW_REVERSE 的值 和 素材行序 是【一对】，只能一起改 ★★
        (bottom-up 素材 + ROW_REVERSE=1)   ← 现在这套
        (top-down  素材 + ROW_REVERSE=0)
     只改一边 = 图像上下颠倒。**动这里之前先看 top.v 那段 ROW_REVERSE 注释。**

  ★ 别再引用"和 gen_hud_assets.write_bmp() 同一套、方向已上板验证过"★
    gen_hud_assets.py:322 的 write_bmp() 确实是 bottom-up（写法一致），
    但"方向已验证"那句是**没验证过的假设**，不能当依据。
  sd_assets/fat32/0N.WAV   源 0N.wav 原样拷贝

  ★ WAV 为什么原样拷贝、不重采样 ★
    src/wav_loader.v 里有 rate_div()，是按【WAV 头里的采样率】算播放分频的：
        16000 -> 6250     48000 -> 2083     （都是 100MHz / rate）
    源素材是 16000Hz，在 rate_known 表里 ⇒ RTL 本来就按 16kHz 播，音高是对的。
    （旧的 make_fat32_card.py 把 WAV_RATE 写死 48000、PCM 写死 96000 字节，
      那是因为它处理的是【无头的裸 PCM】aud*.pcm —— 现在这批源素材是完整
      WAV 文件，不需要重采样，也不该用那个脚本。）

  文件名严格 8.3、全大写，对应 fat32_reader.v 的 tgt_name()：
      页号 0..5 -> "0" + (页号+1) + "BMP" / "WAV"

用法
----
    python tools/real_assets.py              # 生成到 sd_assets/fat32/
    python tools/real_assets.py --check      # 只校验源素材，不写文件
    python tools/real_assets.py --out DIR

纯 Python 3，零第三方依赖（PNG 解码用 stdlib 的 zlib 手写）。
"""

import argparse
import os
import struct
import sys
import zlib

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASSETS = os.path.join(ROOT, "sd_assets")
DEFAULT_OUT = os.path.join(ASSETS, "fat32")

N_FILES = 6
BMP_W, BMP_H, BMP_BPP = 640, 480, 24
BMP_EXPECT = 54 + BMP_W * BMP_H * BMP_BPP // 8          # 921654

# 与 src/wav_loader.v 的 rate_known() 一致
RATE_KNOWN = {8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000}

# ---------------------------------------------------------------------------
# ★ 页 -> 源素材编号 ★  下标 = 页号 0..5，值 = sd_assets 里的素材编号
#   页5 = 报警页，它必须拿到 06.BMP，所以红图（现在这批里是 06.png）放在这里。
#   依据见文件头那段：o_img_index=disp_page (hud_data_gen.v:330)，
#   bmp_read.v:410 把 index 0..5 译成 01.BMP..06.BMP。
#   ★ 2026-10-14：母版已从卡上回灌，编号与卡一致，所以这里是恒等映射。
#     不恒等的时候（比如上一批是 [1,3,4,5,6,2]）红图会被搬来搬去，见文件头那段。★
# ---------------------------------------------------------------------------
PAGE_IMG_SRC = [1, 2, 3, 4, 5, 6]

# 音频是否跟着底图一起重排？
#   False（默认）: 0N.WAV = 【页 N 的播报】，换底图不动音频。
#   True         : 0N.WAV = 【第 N 张图】的解说，图挪到哪音频跟到哪。
WAV_FOLLOW_IMG = False


# ---------------------------------------------------------------------------
# PNG 解码：只支持 8bit / colortype 2(RGB) / 非交错 —— 这正是本工程六张源图的格式
# ---------------------------------------------------------------------------
def decode_png_rgb(path):
    """返回 (w, h, rows)，rows[y] 是自上而下第 y 行的 RGB 字节串（w*3 字节）。"""
    d = open(path, "rb").read()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG")
    w, h, bd, ct, cm, fm, il = struct.unpack_from(">IIBBBBB", d, 16)
    if (bd, ct, il) != (8, 2, 0):
        raise ValueError("只支持 8bit/RGB/非交错，本文件是 bitdepth=%d colortype=%d interlace=%d"
                         % (bd, ct, il))

    idat = bytearray()
    pos = 8
    while pos + 8 <= len(d):
        ln, = struct.unpack_from(">I", d, pos)
        tag = d[pos + 4:pos + 8]
        if tag == b"IDAT":
            idat += d[pos + 8:pos + 8 + ln]
        elif tag == b"IEND":
            break
        pos += 12 + ln
    raw = zlib.decompress(bytes(idat))

    stride = w * 3
    need = h * (stride + 1)
    if len(raw) != need:
        raise ValueError("解压后 %d 字节 != 期望 %d" % (len(raw), need))

    rows = []
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 0:
            pass
        elif ft == 1:                                   # Sub
            for i in range(3, stride):
                line[i] = (line[i] + line[i - 3]) & 0xFF
        elif ft == 2:                                   # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:                                   # Average
            for i in range(stride):
                a = line[i - 3] if i >= 3 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:                                   # Paeth
            for i in range(stride):
                a = line[i - 3] if i >= 3 else 0
                b = prev[i]
                c = prev[i - 3] if i >= 3 else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        else:
            raise ValueError("未知 PNG 滤波器类型 %d" % ft)
        rows.append(bytes(line))
        prev = line
    return w, h, rows


def write_bmp_24_bottomup(path, w, h, rows_rgb):
    """
    头 54 字节：
      "BM" + (filesize,0,0,54) + DIB(40, w, h, 1, 24, 0, **0**, **3780**,**3780**, 0,0)
      ★ biSizeImage=0、分辨率=3780(96dpi) 是【照着卡上那批 BMP 的头部写的】★
        （原来写的是 len(data) / 2835，和卡上差 6 个字节，导致"重新生成"的
          文件不能和卡上逐字节相同。见下面 dib 那行的注释。）

    ★ 像素【自下而上】写：先写图像最后一行（底部），最后写第 0 行（顶部）★
      biHeight = +h。这是 BMP 的标准写法，配上 top.v 的 ROW_REVERSE=1
      在板子上就是正像（推导见文件头那段，以及 top.v 里 ROW_REVERSE 的注释）。

    每像素 (B,G,R)，行按 4 字节对齐（640*3=1920 本来就对齐，pad 恒为 0）。
    """
    rowsize = (w * 3 + 3) & ~3
    pad = rowsize - w * 3
    data = bytearray()
    for y in range(h - 1, -1, -1):            # ★ bottom-up：图像底行先写 ★
        line = rows_rgb[y]
        for x in range(w):
            i = x * 3
            data += bytes((line[i + 2], line[i + 1], line[i]))   # R,G,B -> B,G,R
        data += b"\0" * pad
    filesize = 54 + len(data)
    hdr = b"BM" + struct.pack("<IHHI", filesize, 0, 0, 54)
    # ★ biSizeImage 写 0、分辨率写 3780 —— 这两处是【刻意对齐卡上那批文件】★
    #   BI_RGB 的 biSizeImage 允许为 0（可以算出来，很多写入器就写 0），
    #   3780 ppm = 96dpi，是 Windows 系的默认值。
    #   src/bmp_read.v 只读字节 10-13(pixel_offset)、18-21(width)、22-25(height)、
    #   28-29(bit_count)、30-33(compression)，**不读 biSizeImage 也不读分辨率**
    #   ⇒ 这两个值对 RTL 完全没有影响，写它们纯粹是为了让"重新生成的 BMP"
    #     和卡上的文件【逐字节相同】，好在 tools/_selftest/chk_card_vs_master.py
    #     里用一次逐字节比较就把"母版 -> fat32/ -> 卡"三者一致性验掉。
    dib = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, 0, 3780, 3780, 0, 0)
    with open(path, "wb") as f:
        f.write(hdr + dib + bytes(data))
    return filesize


# ---------------------------------------------------------------------------
# 主色识别：用来【打印】每页底图到底是哪张，别靠文件名猜
#
#   不能对整幅图取均值 —— 背景（灰厂房 / 灰展板）面积比储罐大得多，
#   均值会全被冲成灰的。"最饱和的那一小撮像素"才是主体（储罐本体），
#   取它（最饱和的 5%）的均值再起个中文色名，一眼就能看出哪张是红的。
# ---------------------------------------------------------------------------
def color_name(r, g, b):
    mx, mn = max(r, g, b), min(r, g, b)
    sat = (mx - mn) / float(mx or 1)
    if mx < 50:
        return "黑"
    if sat < 0.18:
        return "白/灰" if mx > 170 else "暗灰"
    if mx == r:
        if g > 0.80 * r:
            return "黄"
        if g > 0.30 * r:
            return "橙"
        return "红"
    if mx == g:
        return "绿"
    return "浅蓝" if (r + g) > b * 1.15 else "蓝"


def color_hint(rows, w, h):
    """返回 (r, g, b, 色名)，取自画面里最饱和的 5% 像素。"""
    cand = []
    for y in range(0, h, 3):
        line = rows[y]
        for x in range(0, w, 3):
            i = x * 3
            r, g, b = line[i], line[i + 1], line[i + 2]
            mx = max(r, g, b)
            cand.append((mx - min(r, g, b), r, g, b))    # 绝对色度：又艳又亮的像素排前面
    cand.sort(reverse=True)
    top = cand[:max(1, len(cand) // 20)]
    r = sum(c[1] for c in top) // len(top)
    g = sum(c[2] for c in top) // len(top)
    b = sum(c[3] for c in top) // len(top)
    return r, g, b, color_name(r, g, b)


# ---------------------------------------------------------------------------
# WAV：按 wav_loader.v 的算法回读一遍（真的走 chunk 链），确认它读得对
# ---------------------------------------------------------------------------
def parse_wav(data):
    if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("不是 RIFF/WAVE")
    pos, got, doff, dlen = 12, None, None, None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        csz, = struct.unpack_from("<I", data, pos + 4)
        body = pos + 8
        if cid == b"fmt ":
            af, ch, rate, _br, _ba, bits = struct.unpack_from("<HHIIHH", data, body)
            got = (af, ch, rate, bits)
        elif cid == b"data":
            doff, dlen = body, csz
        pos = body + csz + (csz & 1)
    if got is None:
        raise ValueError("没有 fmt 块")
    if doff is None:
        raise ValueError("没有 data 块")
    if doff + dlen > len(data):
        raise ValueError("data 块长度 %d 超出文件" % dlen)
    return got + (doff, dlen)


def check_bmp(data):
    if len(data) != BMP_EXPECT:
        return False, "大小 %d != %d" % (len(data), BMP_EXPECT)
    if data[:2] != b"BM":
        return False, "签名不是 BM"
    fsize, = struct.unpack_from("<I", data, 2)
    offbits, = struct.unpack_from("<I", data, 10)
    hdrsize, = struct.unpack_from("<I", data, 14)
    w, = struct.unpack_from("<i", data, 18)
    h, = struct.unpack_from("<i", data, 22)
    planes, bpp = struct.unpack_from("<HH", data, 26)
    comp, = struct.unpack_from("<I", data, 30)
    bad = []
    if fsize != BMP_EXPECT:
        bad.append("bfSize=%d" % fsize)
    if offbits != 54:
        bad.append("bfOffBits=%d" % offbits)
    if hdrsize != 40:
        bad.append("biSize=%d" % hdrsize)
    if w != BMP_W:
        bad.append("宽=%d" % w)
    if h != BMP_H:
        bad.append("高=%d（须 +480 = 自下而上）" % h)
    if planes != 1 or bpp != BMP_BPP:
        bad.append("planes=%d bpp=%d" % (planes, bpp))
    if comp != 0:
        bad.append("biCompression=%d" % comp)
    return (not bad), ("%dx%d %dbpp BI_RGB bottom-up" % (w, h, bpp) if not bad else ", ".join(bad))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    print("=" * 74)
    print("real_assets.py -- 真素材 -> 可直接拖进 FAT32 卡根目录")
    print("=" * 74)
    print("源目录  : %s" % ASSETS)
    if not args.check:
        print("输出目录: %s" % args.out)
    print()

    if not args.check:
        os.makedirs(args.out, exist_ok=True)

    bad = 0
    print("%-4s %-9s %-11s %-10s %s" % ("页", "卡上名字", "来源", "大小", "校验 / 内容"))
    print("-" * 96)

    for page in range(N_FILES):
        n = page + 1                     # 卡上文件名编号 = 页号 + 1
        m = PAGE_IMG_SRC[page]           # 源素材编号（见文件头那张映射表）
        msrc = m if WAV_FOLLOW_IMG else n
        tag = "   ★报警页" if page == 5 else ""

        # ---------------- 底图 ----------------
        src = os.path.join(ASSETS, "%02d.png" % m)
        dst = os.path.join(args.out, "%02d.BMP" % n)
        if not os.path.isfile(src):
            print("%-4d %-9s %-11s %-10s 缺文件%s" % (page, "%02d.BMP" % n, "%02d.png" % m, "-", tag))
            bad += 1
        else:
            try:
                w, h, rows = decode_png_rgb(src)
                if (w, h) != (BMP_W, BMP_H):
                    raise ValueError("尺寸 %dx%d != %dx%d" % (w, h, BMP_W, BMP_H))
                cr, cg, cb, cname = color_hint(rows, w, h)
                hint = "主色 rgb(%3d,%3d,%3d) %s" % (cr, cg, cb, cname)
                if args.check:
                    print("%-4d %-9s %-11s %-10s OK  源图 %dx%d RGB8  %s%s"
                          % (page, "%02d.BMP" % n, "%02d.png" % m, "-", w, h, hint, tag))
                else:
                    size = write_bmp_24_bottomup(dst, w, h, rows)
                    ok, why = check_bmp(open(dst, "rb").read())
                    print("%-4d %-9s %-11s %-10d %s  %s%s"
                          % (page, "%02d.BMP" % n, "%02d.png" % m, size,
                             ("OK  " + why) if ok else ("** " + why), hint, tag))
                    if not ok:
                        bad += 1
            except Exception as e:
                print("%-4d %-9s %-11s %-10s ** %s%s"
                      % (page, "%02d.BMP" % n, "%02d.png" % m, "-", e, tag))
                bad += 1

        # ---------------- 音频 ----------------
        # ★ 音频按【页】编号，不跟着底图跑 ★（除非 WAV_FOLLOW_IMG 打开，见文件头）
        src = os.path.join(ASSETS, "%02d.wav" % msrc)
        dst = os.path.join(args.out, "%02d.WAV" % n)
        if not os.path.isfile(src):
            print("%-4d %-9s %-11s %-10s 缺文件%s" % (page, "%02d.WAV" % n, "%02d.wav" % msrc, "-", tag))
            bad += 1
        else:
            try:
                data = open(src, "rb").read()
                af, ch, rate, bits, doff, dlen = parse_wav(data)
                problems = []
                if af != 1:
                    problems.append("audio_format=%d(须1=PCM)" % af)
                if ch != 1:
                    problems.append("声道=%d(须1)" % ch)
                if bits != 16:
                    problems.append("位深=%d(须16)" % bits)
                if rate not in RATE_KNOWN:
                    problems.append("采样率=%d 不在 rate_known 表内" % rate)
                why = "%dHz/%dbit/%dch %.3fs 头%d字节" % (rate, bits, ch, dlen / (rate * ch * bits / 8), doff)
                if problems:
                    print("%-4d %-9s %-11s %-10d ** %s%s"
                          % (page, "%02d.WAV" % n, "%02d.wav" % msrc, len(data), "; ".join(problems), tag))
                    bad += 1
                else:
                    if not args.check:
                        with open(dst, "wb") as f:
                            f.write(data)
                    print("%-4d %-9s %-11s %-10d OK  %s%s"
                          % (page, "%02d.WAV" % n, "%02d.wav" % msrc, len(data), why, tag))
            except Exception as e:
                print("%-4d %-9s %-11s %-10s ** %s%s"
                      % (page, "%02d.WAV" % n, "%02d.wav" % msrc, "-", e, tag))
                bad += 1

    print("-" * 96)
    print()
    if bad:
        print("!! %d 个素材不合格。" % bad)
        return 1
    print("全部 %d 个素材合格。" % (N_FILES * 2))
    print()
    print("页 -> 卡上文件：")
    for page in range(N_FILES):
        n = page + 1
        msrc = PAGE_IMG_SRC[page] if WAV_FOLLOW_IMG else n
        print("  页%d : %02d.BMP <- %02d.png    %02d.WAV <- %02d.wav%s"
              % (page, n, PAGE_IMG_SRC[page], n, msrc,
                 "   ★报警页（红色那张）" if page == 5 else ""))
    if not args.check:
        print()
        print("下一步：把 %s 里的 12 个文件【整个拖到卡的根目录】，不要放进任何文件夹。" % args.out)
        print("         卡必须是 FAT32 格式化的普通卡（不是裸扇区镜像）。")
        print()
        print("  ★ 别再跑 tools/make_fat32_card.py / layout_sd.py ★")
        print("    make_fat32_card.py 是占位素材那套（源是 img*.bmp + 无头 aud*.pcm，")
        print("    且把 WAV_RATE 写死 48000/96000 字节），对这批真素材不适用；")
        print("    layout_sd.py 是更早的裸扇区写入，会冲掉 FAT 表。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
