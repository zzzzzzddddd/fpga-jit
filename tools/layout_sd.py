#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
layout_sd.py  --  把底图和音频按【裸扇区】摆进 TF 卡镜像，并打印扇区表

这个脚本干一件事：把 sd_assets/ 下的 6 张底图 (img0..img5.bmp) 和 6 段音频
(aud0..aud5.pcm / .wav) 写到一个【裸盘镜像】sd_image.img 的【固定绝对扇区】上，
再把扇区表打在控制台上，供人工抄进 RTL 常量。

为什么必须裸扇区、不能用 FAT 拷贝
----------------------------------
本工程的 FPGA 直接走 SPI 命令 (CMD17) 按【扇区号】读卡，根本不认识 FAT 文件
系统，也没有任何文件表解析逻辑。所以素材不能像平常那样"拷到卡里"就算数 ——
卡上的 FAT 表、目录项、簇链在 FPGA 眼里全是垃圾数据，而且文件放在哪个扇区完全
由文件系统决定，不是我们说了算。唯一的做法是：绕过文件系统，把字节直接写到
指定的绝对扇区上。这就是"裸扇区写入"。

★ 卡片必须是裸扇区写入，不是普通 FAT 拷贝。★
  用文件管理器拖进去的 img0.bmp 落在哪个扇区是不可控的，FPGA 一定读错。
  正确做法是本脚本 --device 直写物理盘，或者 dd（Windows 上用
  physdiskwrite / HDD Raw Copy 之类）把 sd_image.img 按【整盘镜像】写到卡上。

和 RTL 常量的对应关系（改这里必须同步改 RTL）
---------------------------------------------
  图片  k = 0..5  起始扇区 = IMG_BASE_SEC + k*IMG_STRIDE
        -> RTL: src/bmp_read.v   的 IMG_BASE_SEC / IMG_STRIDE
  音频  段 k = 0..5  起始扇区 = AUDIO_BASE_SEC + k*FRAG_STRIDE
        -> RTL: src/audio_sd_reader.v 的 AUDIO_BASE / FRAG_STRIDE

  ★ 只要本脚本里这几个常量动了，上面两个 .v 里的常量必须【原样】跟着改，
    否则 FPGA 会从错误的扇区读数据 —— 屏幕上花屏、喇叭里噪声，而且综合
    阶段不会报任何错。这两处没有编译期的勾连，只靠人工保持一致。

布局表（单位：扇区，1 扇区 = 512 字节）
--------------------------------------
  IMG_BASE_SEC   = 16000     图 0 起始
  IMG_STRIDE     = 2048      每张图占 2048 扇区 = 1 MiB（够放 640x480x24 的 BMP）
  AUDIO_BASE_SEC = 32768     音频段 0 起始
  FRAG_STRIDE    = 4096      每段音频占 4096 扇区 = 2 MiB ≈ 21.8s @96kB/s
  镜像总大小      = 57344 扇区 = 28 MiB

用法
----
  python tools/layout_sd.py                          # 用 sd_assets/ 下的素材，写 sd_image.img
  python tools/layout_sd.py --src <目录>             # 换素材目录
  python tools/layout_sd.py --out sd_image.img       # 换输出镜像（默认就是这个名）
  python tools/layout_sd.py --check                  # 只校验 + 打扇区表，不写镜像
  python tools/layout_sd.py --device \\.\PhysicalDrive2   # 直写物理盘（危险，需交互确认）

纯 Python 3，零第三方依赖。
"""

import argparse
import os
import struct
import sys

# 控制台按 UTF-8 输出，否则中文提示在 GBK 终端里是乱码（和 gen_hud_assets.py 一致）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass

# ----------------------------------------------------------------------------
# 路径
# ----------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_SRC = os.path.join(ROOT, "sd_assets")
DEFAULT_OUT = "sd_image.img"

# ============================================================================
# 布局常量（写死在脚本里；改这里必须同步改 RTL，见文件头）
# ============================================================================
SECTOR         = 512        # 扇区大小（字节）
N_IMG          = 6          # 底图张数
N_AUD          = 6          # 音频段数

IMG_BASE_SEC   = 16000      # 图 0 的起始扇区
IMG_STRIDE     = 2048       # 每张图占的扇区数（相邻图间距）
AUDIO_BASE_SEC = 32768      # 音频段 0 的起始扇区
FRAG_STRIDE    = 4096       # 每段音频占的扇区数（2 MiB ≈ 21.8s @96kB/s）

IMG_TOTAL_SEC  = AUDIO_BASE_SEC + N_AUD * FRAG_STRIDE   # 57344 扇区 = 28 MiB

# ---- 图片格式常量（这里就是 bmp_read.v 期望的格式，不能放宽）----
BMP_W          = 640
BMP_H          = 480
BMP_BPP        = 24
BMP_HDR_BYTES  = 14 + 40    # BITMAPFILEHEADER(14) + BITMAPINFOHEADER(40) = 54
BMP_PIX_BYTES  = BMP_W * BMP_H * 3      # 640*480*3 = 921600（行宽 1920 已是 4 的倍数，无填充）
BMP_FILE_BYTES = BMP_HDR_BYTES + BMP_PIX_BYTES   # 54 + 921600 = 921654

# ---- 音频格式常量（wav 只接受这一种，其它一律报错让用户自己转）----
AUD_RATE       = 48000
AUD_CHANNELS   = 1
AUD_BITS       = 16
AUD_FORMAT_PCM = 1          # wFormatTag: 1 = PCM

# ============================================================================
# 区域不重叠断言（编译期常量，任何一条不成立就别跑了）
# ============================================================================
# 图片区末端必须不撞上音频区起点
assert IMG_BASE_SEC + N_IMG * IMG_STRIDE <= AUDIO_BASE_SEC, \
    "图片区 (末端 %d) 和音频区 (起点 %d) 重叠了" % (
        IMG_BASE_SEC + N_IMG * IMG_STRIDE, AUDIO_BASE_SEC)
# 镜像总大小 = 音频区末端
assert IMG_TOTAL_SEC == AUDIO_BASE_SEC + N_AUD * FRAG_STRIDE == 57344, \
    "镜像总扇区数算错了：%d（应为 57344）" % IMG_TOTAL_SEC


def _ceil_div(a, b):
    """向上取整除法：a 字节需要几个 b 字节的扇区"""
    return (a + b - 1) // b


# 静态断言：单张图 / 单段音频都不能超出一格 stride（常量本身就不该越界）
assert _ceil_div(BMP_FILE_BYTES, SECTOR) <= IMG_STRIDE, \
    "一张图 %d 字节需要 %d 扇区，超过 IMG_STRIDE=%d" % (
        BMP_FILE_BYTES, _ceil_div(BMP_FILE_BYTES, SECTOR), IMG_STRIDE)
assert _ceil_div(AUD_RATE * AUD_CHANNELS * (AUD_BITS // 8), SECTOR) <= FRAG_STRIDE, \
    "1 秒音频需要的扇区数超过 FRAG_STRIDE"


class LayoutError(Exception):
    """素材校验失败。带这句就中止，绝不写出坏镜像。"""
    pass


def _human(nbytes):
    """字节数格式化成人看的 MiB / KiB"""
    if nbytes >= 1024 * 1024:
        return "%.2f MiB" % (nbytes / 1048576.0)
    if nbytes >= 1024:
        return "%.1f KiB" % (nbytes / 1024.0)
    return "%d B" % nbytes


# ============================================================================
# 图片校验：BMP 头解析 + 断言
# ============================================================================
def check_image(path, k):
    """
    校验一张底图。全部通过返回 dict（含整数字节数、扇区数、BMP 头字段）；
    任一不满足抛 LayoutError（报错信息带文件名和第几张图）。
    断言清单见文件头 / 任务约定：
      1) 文件存在          2) 头两字节 'BM'
      3) 640x480 24bpp 无压缩(biCompression==0)
      4) 文件字节数 == 54 + 640*480*3 == 921654
      5) 921654 字节需要的扇区数 <= IMG_STRIDE
    """
    name = "img%d.bmp" % k
    if not os.path.isfile(path):
        raise LayoutError("找不到图片 %s" % name)

    size = os.path.getsize(path)

    # ---- 读 54 字节文件+信息头（BITMAPFILEHEADER 14 + BITMAPINFOHEADER 40）----
    with open(path, "rb") as f:
        head = f.read(BMP_HDR_BYTES)
    if len(head) < BMP_HDR_BYTES:
        raise LayoutError("%s 短于 54 字节，连头都不全（实际 %d 字节）"
                          % (name, len(head)))

    # 2) 魔数
    if head[0:2] != b"BM":
        raise LayoutError("%s 头两字节不是 'BM'（实际 %r），不是 BMP"
                          % (name, head[0:2]))

    bf_size,  = struct.unpack_from("<I", head, 2)     # bfSize
    bf_off,   = struct.unpack_from("<I", head, 10)    # bfOffBits
    bi_size,  = struct.unpack_from("<I", head, 14)    # biSize
    bi_w,     = struct.unpack_from("<i", head, 18)    # biWidth
    bi_h,     = struct.unpack_from("<i", head, 22)    # biHeight (正=bottom-up)
    bi_planes, = struct.unpack_from("<H", head, 26)   # biPlanes
    bi_bpp,   = struct.unpack_from("<H", head, 28)    # biBitCount
    bi_comp,  = struct.unpack_from("<I", head, 30)    # biCompression

    # 3) 尺寸 / 位深 / 压缩
    if bi_w != BMP_W or bi_h != BMP_H:
        raise LayoutError("%s 尺寸 %dx%d，要求 %dx%d%s"
                          % (name, bi_w, bi_h, BMP_W, BMP_H,
                             "（biHeight 为负 = 自上而下，本工程要 bottom-up）"
                             if bi_h == -BMP_H else ""))
    if bi_bpp != BMP_BPP:
        raise LayoutError("%s 是 %dbpp，要求 %dbpp" % (name, bi_bpp, BMP_BPP))
    if bi_comp != 0:
        raise LayoutError("%s biCompression=%d，要求 0（无压缩 BI_RGB）"
                          % (name, bi_comp))

    # 4) 文件字节数 == 54 + 640*480*3 == 921654
    #    54 = BITMAPFILEHEADER(14) + BITMAPINFOHEADER(40)；640*480*3 是像素数据，
    #    行宽 640*3=1920 已是 4 的倍数，没有行填充，所以像素区正好 921600 字节。
    if size != BMP_FILE_BYTES:
        raise LayoutError("%s 文件 %d 字节，要求正好 %d 字节 (= 54 + 640*480*3)"
                          % (name, size, BMP_FILE_BYTES))
    # 头里的 bfSize 也应和实际一致（有些工具会写错）
    if bf_size != BMP_FILE_BYTES:
        raise LayoutError("%s 头部 bfSize=%d 和要求的 %d 不符"
                          % (name, bf_size, BMP_FILE_BYTES))
    # 像素数据必须紧跟 54 字节头（bfOffBits==54），否则 RTL 按下标读像素会错位
    if bf_off != BMP_HDR_BYTES:
        raise LayoutError("%s bfOffBits=%d，期望 %d（像素紧跟在 54 字节头之后）"
                          % (name, bf_off, BMP_HDR_BYTES))
    if bi_size != 40:
        raise LayoutError("%s biSize=%d，期望 40（BITMAPINFOHEADER）"
                          % (name, bi_size))
    if bi_planes != 1:
        raise LayoutError("%s biPlanes=%d，期望 1" % (name, bi_planes))

    need_sec = _ceil_div(size, SECTOR)
    # 5) 需要扇区数 <= IMG_STRIDE
    if need_sec > IMG_STRIDE:
        raise LayoutError("%s 需要 %d 扇区，超过 IMG_STRIDE=%d"
                          % (name, need_sec, IMG_STRIDE))

    return {"name": name, "path": path, "size": size, "sectors": need_sec}


# ============================================================================
# 音频校验：偶数长度 + 上限 + (wav) 格式
# ============================================================================
def _iter_riff_chunks(buf):
    """遍历 RIFF 容器里的块，产出 (chunk_id, data_offset, data_size)。"""
    off = 12                      # 跳过 'RIFF' size 'WAVE'
    n = len(buf)
    while off + 8 <= n:
        cid = buf[off:off + 4]
        csz, = struct.unpack_from("<I", buf, off + 4)
        data_off = off + 8
        yield cid, data_off, csz
        off = data_off + csz + (csz & 1)   # RIFF 块按偶数字节对齐


def _parse_wav(path, name, buf):
    """解析 wav，只接受 16bit/单声道/48000Hz/PCM，返回 data 块的裸样本字节。"""
    if buf[0:4] != b"RIFF" or buf[8:12] != b"WAVE":
        raise LayoutError("%s 不是 RIFF/WAVE（头是 %r %r）"
                          % (name, buf[0:4], buf[8:12]))

    fmt = None
    data = None
    for cid, off, csz in _iter_riff_chunks(buf):
        if cid == b"fmt ":
            fmt = (off, csz)
        elif cid == b"data":
            data = (off, csz)

    if fmt is None:
        raise LayoutError("%s 缺 fmt 块" % name)
    if data is None:
        raise LayoutError("%s 缺 data 块" % name)

    foff, fsz = fmt
    if fsz < 16:
        raise LayoutError("%s 的 fmt 块只有 %d 字节" % (name, fsz))
    w_format, = struct.unpack_from("<H", buf, foff + 0)
    w_ch,     = struct.unpack_from("<H", buf, foff + 2)
    w_rate,   = struct.unpack_from("<I", buf, foff + 4)
    w_bits,   = struct.unpack_from("<H", buf, foff + 14)

    # 实际格式先攒好，报错时能说明白到底哪里不对
    desc = "format=%d, %d 声道, %d Hz, %d bit" % (w_format, w_ch, w_rate, w_bits)

    if w_format != AUD_FORMAT_PCM:
        raise LayoutError("%s 不是 PCM（实际 %s）。这是压缩格式，请先用 ffmpeg 转成 "
                          "16bit/单声道/48000Hz PCM WAV。" % (name, desc))
    if w_bits != AUD_BITS:
        raise LayoutError("%s 位深不对（实际 %s），只接受 %dbit。请先用 ffmpeg -ar 48000 "
                          "-ac 1 -sample_fmt s16 转换。" % (name, desc, AUD_BITS))
    if w_ch != AUD_CHANNELS:
        raise LayoutError("%s 声道数不对（实际 %s），只接受单声道。请先用 ffmpeg -ac 1 转换。"
                          % (name, desc))
    if w_rate != AUD_RATE:
        raise LayoutError("%s 采样率不对（实际 %s），只接受 %dHz。请先用 ffmpeg -ar %d 转换。"
                          % (name, desc, AUD_RATE, AUD_RATE))

    doff, dsz = data
    # RIFF 的 data 块声明长度可能大于实际剩余字节（截断文件），取两者较小
    avail = len(buf) - doff
    if dsz > avail:
        raise LayoutError("%s 的 data 块声明 %d 字节，但文件只剩 %d 字节（被截断？）"
                          % (name, dsz, avail))
    return bytes(buf[doff:doff + dsz])


def check_audio(path, k):
    """
    校验一段音频，返回 (裸 PCM 字节, 来源描述)。
    断言：
      6) 文件存在
      7) 字节数是偶数（16bit 小端样本，奇数会破坏样本对齐）
      8) 字节数 <= FRAG_STRIDE*512
      9) 若为 .wav：必须是 16bit/单声道/48000Hz/PCM，取 data 块裸样本
    """
    name = os.path.basename(path)
    if not os.path.isfile(path):
        raise LayoutError("找不到音频 aud%d(.pcm/.wav)" % k)

    with open(path, "rb") as f:
        raw = f.read()

    ext = os.path.splitext(path)[1].lower()
    if ext == ".wav":
        payload = _parse_wav(path, name, raw)
        kind = "wav(data 裸样本)"
    else:
        payload = raw
        kind = "pcm(裸)"

    # 7) 偶数长度：16bit 小端样本，奇数字节会让所有后续样本错半字节
    if len(payload) % 2 != 0:
        raise LayoutError("%s 数据 %d 字节是奇数，16bit 样本会对不齐（必须偶数）"
                          % (name, len(payload)))

    # 8) 不超出一格
    cap = FRAG_STRIDE * SECTOR
    if len(payload) > cap:
        raise LayoutError("%s 有 %d 字节 (%s)，超过每段上限 %d 字节 (%s)"
                          % (name, len(payload), _human(len(payload)),
                             cap, _human(cap)))

    return payload, {"name": name, "path": path, "size": len(payload),
                     "kind": kind, "sectors": _ceil_div(len(payload), SECTOR)}


# ============================================================================
# 扇区表打印
# ============================================================================
def print_table(imgs, auds):
    total_sec = IMG_TOTAL_SEC
    print("镜像总大小: %d 扇区 (%.2f MiB)"
          % (total_sec, total_sec * SECTOR / 1048576.0))

    print("  [图片]  base=%d  stride=%d" % (IMG_BASE_SEC, IMG_STRIDE))
    for k, a in enumerate(imgs):
        base = IMG_BASE_SEC + k * IMG_STRIDE
        print("    图 %d  起始扇区 %5d   %5d 扇区   %8d 字节  <- %-10s   = %d + %d*k"
              % (k, base, a["sectors"], a["size"], a["name"],
                 IMG_BASE_SEC, IMG_STRIDE))

    print("  [音频]  base=%d  stride=%d" % (AUDIO_BASE_SEC, FRAG_STRIDE))
    for k, (payload, a) in enumerate(auds):
        base = AUDIO_BASE_SEC + k * FRAG_STRIDE
        print("    段 %d  起始扇区 %5d   %5d 扇区   %8d 字节  <- %-10s   (%s)"
              % (k, base, a["sectors"], a["size"], a["name"], a["kind"]))

    # ---- 供直接贴进 RTL 的常量建议 ----
    print("")
    print("  ---- 可直接贴进 RTL 的 Verilog 常量 ----")
    print("  // 图片：src/bmp_read.v")
    print("  localparam [31:0] IMG_BASE_SEC = 32'd%d;" % IMG_BASE_SEC)
    print("  localparam [31:0] IMG_STRIDE   = 32'd%d;   // 图 k 起始 = IMG_BASE_SEC + IMG_STRIDE*k"
          % IMG_STRIDE)
    print("  // 图 0..5 的起始扇区：")
    print("  //   " + "  ".join("%d: 32'd%d" % (k, IMG_BASE_SEC + k * IMG_STRIDE)
                                for k in range(N_IMG)))
    print("  // 音频：src/audio_sd_reader.v")
    print("  localparam [31:0] AUDIO_BASE   = 32'd%d;" % AUDIO_BASE_SEC)
    print("  localparam [31:0] FRAG_STRIDE  = 32'd%d;   // 段 k 起始 = AUDIO_BASE + FRAG_STRIDE*k"
          % FRAG_STRIDE)
    print("  // 段 0..5 的起始扇区：")
    print("  //   " + "  ".join("%d: 32'd%d" % (k, AUDIO_BASE_SEC + k * FRAG_STRIDE)
                                for k in range(N_AUD)))


# ============================================================================
# 收集 + 校验全部素材
# ============================================================================
def locate_assets(src_dir):
    """返回 (图片路径或 None 的列表, 音频路径或 None 的列表)，不抛错。"""
    img_paths = []
    for k in range(N_IMG):
        img_paths.append(os.path.join(src_dir, "img%d.bmp" % k))
    aud_paths = []
    for k in range(N_AUD):
        found = None
        for ext in (".pcm", ".wav"):
            p = os.path.join(src_dir, "aud%d%s" % (k, ext))
            if os.path.isfile(p):
                found = p
                break
        # 两种都在时优先用 .pcm（裸 PCM，本来就是第一手素材），但要说一声，
        # 免得用户以为改的是 .wav 却没生效
        if found and os.path.isfile(os.path.join(src_dir, "aud%d.wav" % k)) \
                and os.path.isfile(os.path.join(src_dir, "aud%d.pcm" % k)):
            print("[提示] aud%d 同时有 .pcm 和 .wav，按约定优先用 aud%d.pcm。"
                  % (k, k))
        aud_paths.append(found)
    return img_paths, aud_paths


def validate_all(src_dir):
    """
    校验全部素材。返回 (imgs, auds)。
    先集中报告所有【缺失】文件，再逐项做格式校验并集中报告错误；任一失败都抛
    LayoutError，调用方不得写出任何镜像。
    """
    if not os.path.isdir(src_dir):
        raise LayoutError("素材目录不存在: %s\n"
                          "      请把 img0..img5.bmp / aud0..aud5.pcm 放进该目录，"
                          "或用 --src <目录> 指定。" % src_dir)

    img_paths, aud_paths = locate_assets(src_dir)

    # ---- 第一步：把缺失的一次性列清楚 ----
    missing = []
    for k, p in enumerate(img_paths):
        if not os.path.isfile(p):
            missing.append("img%d.bmp" % k)
    for k, p in enumerate(aud_paths):
        if p is None:
            missing.append("aud%d.pcm (或 aud%d.wav)" % (k, k))
    if missing:
        raise LayoutError("素材缺失 %d 个：\n        %s"
                          % (len(missing), "\n        ".join(missing)))

    # ---- 第二步：逐个校验，集中报错 ----
    errors = []
    imgs = []
    for k, p in enumerate(img_paths):
        try:
            imgs.append(check_image(p, k))
        except LayoutError as e:
            errors.append(str(e))

    auds = []
    for k, p in enumerate(aud_paths):
        try:
            auds.append(check_audio(p, k))
        except LayoutError as e:
            errors.append(str(e))

    if errors:
        raise LayoutError("素材校验失败 %d 项：\n        %s"
                          % (len(errors), "\n        ".join(errors)))
    return imgs, auds


# ============================================================================
# 写镜像 / 写物理盘
# ============================================================================
def write_image(out_path, imgs, auds):
    """
    写裸盘镜像：先用 truncate 把文件撑到 28MiB（空洞自然是 0），再 seek 到各素材
    的绝对扇区写入。不把 28MB 拼在内存里。
    """
    total_bytes = IMG_TOTAL_SEC * SECTOR
    with open(out_path, "wb") as f:
        f.truncate(total_bytes)          # 预分配，未写入的区域是 0
        for k, a in enumerate(imgs):
            with open(a["path"], "rb") as src:
                data = src.read()
            f.seek((IMG_BASE_SEC + k * IMG_STRIDE) * SECTOR)
            f.write(data)
            assert f.tell() <= (IMG_BASE_SEC + (k + 1) * IMG_STRIDE) * SECTOR, \
                "图 %d 越过了它那一格" % k
        for k, (payload, a) in enumerate(auds):
            f.seek((AUDIO_BASE_SEC + k * FRAG_STRIDE) * SECTOR)
            f.write(payload)
            assert f.tell() <= (AUDIO_BASE_SEC + (k + 1) * FRAG_STRIDE) * SECTOR, \
                "音频段 %d 越过了它那一格" % k
    assert os.path.getsize(out_path) == total_bytes
    return total_bytes


def _win_device_size(path):
    """
    尽力查物理盘的字节容量（ctypes 调 IOCTL_DISK_GET_LENGTH_INFO）。
    失败返回 None —— 查不到容量不影响后续写盘，只是提示信息少一行。
    """
    try:
        import ctypes
        from ctypes import wintypes
        GENERIC_READ = 0x80000000
        FILE_SHARE_READ = 0x00000001
        FILE_SHARE_WRITE = 0x00000002
        OPEN_EXISTING = 3
        IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C

        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateFileW.restype = wintypes.HANDLE
        k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                    ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                                    wintypes.HANDLE]
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        k32.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p,
                                        wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
                                        ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        h = k32.CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                            None, OPEN_EXISTING, 0, None)
        invalid = ctypes.c_void_p(-1).value
        if not h or h == invalid:
            return None
        try:
            buf = ctypes.c_longlong(0)
            ret = wintypes.DWORD(0)
            ok = k32.DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO,
                                     None, 0, ctypes.byref(buf),
                                     ctypes.sizeof(buf), ctypes.byref(ret), None)
            return buf.value if ok else None
        finally:
            k32.CloseHandle(h)
    except Exception:
        return None


def write_device(device_path, imgs, auds):
    """
    直写物理盘。安全闸门：
      * stdin 不是 tty（CI / 管道 / 重定向）-> 直接拒绝；
      * 先打印目标盘信息和"这将覆盖该盘上的一切数据"；
      * 必须交互式输入大写的 YES 才动手。
    """
    print("")
    print("=" * 70)
    print("★ 危险操作：即将直写物理盘 ★")
    print("  目标: %s" % device_path)
    size = _win_device_size(device_path)
    if size is not None:
        print("  容量: %d 字节 (%s, %.2f GiB)"
              % (size, _human(size), size / 1073741824.0))
    else:
        print("  容量: 未知（未能查询到，继续前请自行确认盘符没选错）")
    print("  需要写入: 前 %d 字节 (%s) 的固定扇区区域" %
          (IMG_TOTAL_SEC * SECTOR, _human(IMG_TOTAL_SEC * SECTOR)))
    print("")
    print("  这将覆盖该盘上的一切数据，且不可恢复！分区表、文件系统、" \
          "其它所有文件全部没了。")
    print("=" * 70)

    if not sys.stdin.isatty():
        print("[错误] 当前 stdin 不是交互式终端（tty），拒绝写物理盘。")
        print("       这是在 CI / 管道 / 重定向环境里运行，危险操作一律不执行。")
        return 1

    if size is not None and size < IMG_TOTAL_SEC * SECTOR:
        print("[错误] 目标盘容量 %d 字节，装不下镜像所需的 %d 字节。已中止。"
              % (size, IMG_TOTAL_SEC * SECTOR))
        return 1

    ans = input("  确认要写这个盘吗？输入大写 YES 继续，其它任何输入都中止: ")
    if ans != "YES":
        print("  已取消，未写入任何数据。")
        return 1

    # 按约定用 open(path, 'r+b')（\\.\PhysicalDriveN 走的就是这条路）
    with open(device_path, "r+b") as f:
        for k, a in enumerate(imgs):
            with open(a["path"], "rb") as src:
                data = src.read()
            f.seek((IMG_BASE_SEC + k * IMG_STRIDE) * SECTOR)
            f.write(data)
        for k, (payload, a) in enumerate(auds):
            f.seek((AUDIO_BASE_SEC + k * FRAG_STRIDE) * SECTOR)
            f.write(payload)
    print("  已写入物理盘 %s。" % device_path)
    return 0


# ============================================================================
def main():
    ap = argparse.ArgumentParser(
        description="把底图/音频按固定绝对扇区摆进 TF 卡裸盘镜像（配合 src/bmp_read.v、"
                    "src/audio_sd_reader.v 的常量）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=DEFAULT_SRC,
                    help="素材目录（默认 %s）" % DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT,
                    help="输出镜像路径（默认 %s）" % DEFAULT_OUT)
    ap.add_argument("--device", default=None,
                    help="直接写物理盘，如 \\\\.\\PhysicalDrive2（危险，需交互确认）")
    ap.add_argument("--check", action="store_true",
                    help="只校验并打印扇区表，不写镜像")
    args = ap.parse_args()

    print("布局常量: IMG_BASE_SEC=%d IMG_STRIDE=%d AUDIO_BASE_SEC=%d FRAG_STRIDE=%d "
          "SECTOR=%d" % (IMG_BASE_SEC, IMG_STRIDE, AUDIO_BASE_SEC, FRAG_STRIDE, SECTOR))
    print("素材目录: %s" % args.src)

    # ---- 先校验，过了才可能写 ----
    try:
        imgs, auds = validate_all(args.src)
    except LayoutError as e:
        print("[错误] %s" % e)
        print("已中止，未写出任何镜像/未碰任何设备。")
        return 1

    print("校验通过：6 张图 + 6 段音频。")
    print("")
    print_table(imgs, auds)
    print("")

    if args.device:
        if args.out != DEFAULT_OUT:
            print("[提示] 同时给了 --out 和 --device，以 --device 为准，--out 被忽略。")
        return write_device(args.device, imgs, auds)

    if args.check:
        print("--check 模式：未写镜像。")
        return 0

    out_path = os.path.abspath(args.out)
    n = write_image(out_path, imgs, auds)
    used = sum(a["sectors"] for a in imgs) + sum(a["sectors"] for _, a in auds)
    print("已写出镜像: %s" % out_path)
    print("  大小 %d 字节 (%s)，其中素材实际占用 %d 扇区 (%s)，其余为 0 填充。"
          % (n, _human(n), used, _human(used * SECTOR)))
    print("")
    print("★ 提醒：请用整盘写入方式把该镜像写到 TF 卡（裸扇区），不要用文件管理器")
    print("  把它当普通文件拷进 FAT。改了上面的常量，记得同步改 RTL 里的常量。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
