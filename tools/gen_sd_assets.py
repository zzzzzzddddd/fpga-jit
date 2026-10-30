#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_sd_assets.py — 生成 sd_assets/ 下的 6 张占位底图 + 6 段占位音频

============================================================================
【这是占位素材，不是最终美术素材】
============================================================================
目的是先把 SD 通路（固定扇区取图 + 流式播音频）整条跑通、能上板验证。
换成真素材时只要把 sd_assets/ 里同名的文件替换掉，重跑 tools/layout_sd.py
即可 —— RTL 一行都不用改（素材名和扇区位置都是脚本约定的）。

底图的设计目标只有三个：
  1. 一眼看出【现在显示的是第几张图】—— 大页码牌（P0..P5）+ 每页一个专属主色
  2. 一眼看出【图有没有跟着页走】—— 6 张图的主色都不同，换页必看得出来
  3. 【不干扰 HUD 叠加层】—— HUD 自己会盖住的地方一律不画；
     页码牌和色带只放在"底图真的露得出来"的那几块矩形里
     （几何依据见下面 LAYOUT 一节，是照着 hud_panel.v 实测的，不是估的）

音频的设计目标：每页一个不同的音高，一听就知道播的是哪一段。
第 5 段（报警页）RTL 里不会播，但 layout_sd.py 要求 6 段都在，所以照生成。

============================================================================
【产出格式：必须严格符合，layout_sd.py 会逐条断言】
============================================================================
  sd_assets/img0..5.bmp   640x480x24 未压缩 BI_RGB BMP
                          正好 921654 字节 = 54 + 640*480*3
                          头 54 字节，像素紧跟在后面（bfOffBits=54）
                          biHeight 为正（bottom-up），RTL 就是这么读的
  sd_assets/aud0..5.pcm   48000Hz / 16bit / 单声道 / 小端 / 裸 PCM
                          各 96000 字节 = 48000 个样本 = 1.000 秒
                          （音频无 WAV 头：44 字节不是 2 的倍数，会毁掉样本对齐）

复用 tools/gen_hud_assets.py 的 5x7 ASCII 字库和 write_bmp()，保证 BMP 头
和 HUD 预览图是同一套写法（那套已经被 hud_rom_font.v 验证过能对上）。

用法：
    python tools/gen_sd_assets.py            # 生成到 sd_assets/
    python tools/gen_sd_assets.py --out DIR  # 换输出目录
"""

import argparse
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_hud_assets as G          # noqa: E402  (要先把 tools/ 放进 sys.path)
import ttf2bmp                      # noqa: E402  (借它的纯 Python PNG 写出)

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_OUT = os.path.join(ROOT, "sd_assets")

# ---------------------------------------------------------------------------
# 格式常量（和 tools/layout_sd.py、src/bmp_read.v、src/audio_sd_reader.v 对齐）
# ---------------------------------------------------------------------------
W, H = 640, 480
BMP_FILE_BYTES = 54 + W * H * 3          # 921654

AUD_RATE = 48000
FRAG_SAMPLES = 48000                      # 1.000 秒
FRAG_BYTES = FRAG_SAMPLES * 2             # 96000

# ---------------------------------------------------------------------------
# LAYOUT —— 底图上哪几块地方是"看得见"的
# ---------------------------------------------------------------------------
# 照着 src/hud/hud_panel.v 的几何实测出来的（文件头【屏幕布局】注释 +
# 图形 mux 链里的 in_topbar/in_plate*/in_trbox）。HUD 在这些地方画了不透明
# 或半透明的底版，底图画在那里等于白画：
#
#   所有页：
#     y   0.. 35  顶栏（o_alpha=255，全宽）            in_topbar
#     y  40.. 63  说明条底版（半透明，全宽）            in_plate1
#     y 444..479  底栏 / 报警横幅（o_alpha=255）        in_botbar / in_banner
#   小表页（页 0 三表总览 / 页 4 待机巡检）：
#     y  92..115  表注底版（全宽）                      in_plate2
#     y 120..311  三个 192x192 表盘窗口                 hud_gauge
#                 x 8..199 / 224..415 / 440..631
#     y 312..351  三行读数底版（全宽）                  in_plate3
#   大表页（页 1 压力 / 页 2 温度 / 页 3 液位 / 页 5 储气罐故障）：
#     x   8..391, y  48..431  大表盘窗口                hud_gauge
#     x 396..636, y  68..306  右列四行底版              in_plate4
#     x 503..632, y 312..435  趋势曲线图框              in_trbox
#
# 于是"底图真的能露出来"的只剩这几块：
#
#   小表页： y  64.. 91  全宽（28 行）
#           y 352..443  全宽（92 行）★ 最宽敞，页码牌放这
#           x 200..223 / x 416..439, y 120..311（表盘之间两条竖缝）
#   大表页： x 392..502, y 307..443  (107 x 137) ★ 唯一一块方方正正的：
#                                    左边是大表盘窗口(x<=391)、右边是右列
#                                    底版(x>=396,y<=306)和趋势框(x>=503)，
#                                    上下都躲开了
#           y 436..443  全宽（432..435 那四行在 x>=503 处仍被趋势框盖住，
#                        所以色带只取 436 往下，避免一条带子被啃掉半截）
#           y  36.. 39  全宽（4 行，太窄，没用）
#           x   0..  7 / x 633..639（两条竖缝）
#
# ★ 改这张表之前先回去看 hud_panel.v ★
#   底图一旦画到被盖住的地方，现象是"底图少了一块"，很容易被误当成
#   取图错位去查 SD 通路，白花半天。
# ---------------------------------------------------------------------------
BG       = (14, 18, 26)      # 主背景（深藏青，叠加层对比度够）
BG2      = (20, 26, 38)      # 顶栏下面一档的过渡色
PANEL    = (26, 33, 46)      # 表盘窗口里垫的深色底（比背景略亮一点点）

PAGES = [
    # (主色,                  顶栏标题,                  页码牌文字, 形态)
    #
    # ★ 页码牌用【1 基】：img0 -> "P1" … img5 -> "P6" ★
    #   必须和 hud_panel.v:153 的 S_PAGE（disp_page==0 显示 "P1/6"）对齐。
    #   牌子上的数 = 顶栏里 "Pk/6" 的那个 k。内部 disp_page 是 0 基，
    #   两套编号一旦混用，屏幕上会同时出现 "P1/6" 和 "P0"，看着像出错。
    (( 40, 200, 220), "PAGE 1  OVERVIEW",               "P1", "SMALL"),
    ((240, 180,  40), "PAGE 2  PRESSURE  ZOOM",         "P2", "BIG"  ),
    ((240, 120,  50), "PAGE 3  TEMPERATURE  ZOOM",      "P3", "BIG"  ),
    (( 70, 150, 240), "PAGE 4  LEVEL  ZOOM",            "P4", "BIG"  ),
    (( 60, 210, 120), "PAGE 5  STANDBY  PATROL",        "P5", "SMALL"),
    ((230,  50,  50), "PAGE 6  TANK  FAULT",            "P6", "BIG"  ),
]

# 页码牌的位置（文字左上角）和字号。两处都落在上面 LAYOUT 列的可见区里：
#   SMALL：y 352..443 那条 92 行高的通栏里，牌占 y 352..417
#   BIG  ：x 392..502 / y 307..443 那个 107x137 方块里，牌占 x 392..485 / y 322..387
BADGE_SCALE = 7
BADGE_POS   = {"SMALL": (16, 360), "BIG": (400, 330)}

# 页 5 的故障标记文字（只有页 5 画）
FAULT_TEXT = "FAULT"

# 每页音频的两个音（Hz）。第 5 段 RTL 不播，配一个低沉音备用。
AUD_NOTES = [
    (523.25,  783.99),      # C5  -> G5
    (587.33,  880.00),      # D5  -> A5
    (659.25,  987.77),      # E5  -> B5
    (698.46, 1046.50),      # F5  -> C6
    (783.99, 1174.66),      # G5  -> D6
    (440.00,  415.30),      # A4  -> G#4（报警页用不到）
]


# ---------------------------------------------------------------------------
# 画布：每行一个 640 长的列表，元素是 (r,g,b)。初始全是同一个 tuple 的引用，
# 用不可变 tuple 所以共享是安全的，还省内存。
# ---------------------------------------------------------------------------
def new_canvas():
    rows = []
    for y in range(H):
        # 极轻的纵向渐变，让"是图片"这件事看得出来
        k = y / float(H - 1)
        c = (int(BG[0] + (BG2[0] - BG[0]) * k),
             int(BG[1] + (BG2[1] - BG[1]) * k),
             int(BG[2] + (BG2[2] - BG[2]) * k))
        rows.append([c] * W)
    return rows


def fill_rect(rows, x0, y0, x1, y1, color):
    """闭区间填充，自动裁到画布内。"""
    x0 = max(0, x0); y0 = max(0, y0)
    x1 = min(W - 1, x1); y1 = min(H - 1, y1)
    for y in range(y0, y1 + 1):
        r = rows[y]
        for x in range(x0, x1 + 1):
            r[x] = color


def rect_outline(rows, x0, y0, x1, y1, color, t=1):
    """空心矩框，线宽 t。"""
    fill_rect(rows, x0, y0, x1, y0 + t - 1, color)
    fill_rect(rows, x0, y1 - t + 1, x1, y1, color)
    fill_rect(rows, x0, y0, x0 + t - 1, y1, color)
    fill_rect(rows, x1 - t + 1, y0, x1, y1, color)


def text_width(text, scale):
    """5x7 字格，字间距 1 格。"""
    return len(text) * 6 * scale - scale


def draw_text(rows, x, y, text, color, scale=1):
    """用 gen_hud_assets 的 5x7 字库画 ASCII。未知字符当空格处理。"""
    cx = x
    for ch in text:
        glyph = G.FONT.get(ch)
        if glyph is None:
            glyph = G.FONT[' ']
        for ry, line in enumerate(glyph):
            for rx, px in enumerate(line):
                if px != '#':
                    continue
                fill_rect(rows, cx + rx * scale, y + ry * scale,
                          cx + (rx + 1) * scale - 1, y + (ry + 1) * scale - 1,
                          color)
        cx += 6 * scale


# ---------------------------------------------------------------------------
# 生成一张底图
# ---------------------------------------------------------------------------
def make_image(k):
    accent, title, code, form = PAGES[k]
    rows = new_canvas()

    # ---- 顶栏 ----
    # ★ HUD 会整条盖掉（in_topbar: y<36 且 o_alpha=255）★
    #   画它【只是为了预览图好认这块该是第几页】，板上一个字都看不见。
    #   别指望它当标题用，真正的标题是 hud_panel.v 里的 S_TITLE 画的。
    fill_rect(rows, 0, 0, W - 1, 33, accent)
    draw_text(rows, 10, 6, title, (8, 10, 14), 3)

    # ---- 外框：只有左右两条竖边会露出来（上下两条被顶栏/底栏盖掉）----
    rect_outline(rows, 0, 0, W - 1, H - 1, accent, 2)

    # ---- 底部主色带 y 436..443 ----
    #   这是【大小两种形态都看得见】的唯一一条通栏（见上面 LAYOUT）。
    fill_rect(rows, 0, 436, W - 1, 443, accent)

    # ---- 页码牌 ----
    #   整块用主色铺底 + 深色字，这样"牌子本身就是色卡"，
    #   一眼同时得到两个信息：第几页 + 主色对不对。
    bx, by = BADGE_POS[form]
    s = BADGE_SCALE
    bw = text_width(code, s)
    fill_rect(rows, bx - 8, by - 8, bx + bw + 8, by + 7 * s + 8, accent)
    rect_outline(rows, bx - 8, by - 8, bx + bw + 8, by + 7 * s + 8,
                 (240, 246, 252), 2)
    draw_text(rows, bx, by, code, (10, 12, 16), s)

    # ---- 表盘窗口垫深色底 ----
    #   窗口本身由 hud_gauge 画（盘面/刻度/指针），这里只是把窗口里
    #   【表盘圆以外】的四个角落压暗，免得指针压在一张花图上。
    #   矩形按 hud_panel.v 的注释取，与上面 LAYOUT 表一致。
    if form == "SMALL":
        # 三个小表盘窗口 192x192，x = 8 + 216*i，y = 120..311
        for i in range(3):
            x0 = 8 + 216 * i
            fill_rect(rows, x0, 120, x0 + 191, 311, PANEL)
            rect_outline(rows, x0, 120, x0 + 191, 311, (44, 54, 72), 1)
    else:
        # 大表盘窗口 384x384 在 x 8..391 / y 48..431
        fill_rect(rows, 8, 48, 391, 431, PANEL)
        rect_outline(rows, 8, 48, 391, 431, (44, 54, 72), 1)
        # 趋势框 x 503..632 / y 312..435
        fill_rect(rows, 503, 312, 632, 435, PANEL)
        rect_outline(rows, 503, 312, 632, 435, (44, 54, 72), 1)

    # ---- 页 5 的故障标记（需求："背景 UI 可以增加故障标记色块"）----
    #   本来想画在右边那块大底版上（x 402..632 y 96..200），实测发现
    #   那里整块被 in_plate4（x 396..636 y 68..306，alpha=200）压住，
    #   红色会被冲成暗紫。改画在页码牌下面 —— 那块 107x137 的方块里，
    #   牌占 y 322..387，387 往下到 435 还是空的。
    if k == 5:
        draw_text(rows, 400, 400, FAULT_TEXT, (255, 200, 200), 3)

    return rows


# ---------------------------------------------------------------------------
# 生成一段音频：两个音，各 0.5 秒，带包络（防止开头结尾"啪"一声）
# ---------------------------------------------------------------------------
def make_audio(k):
    f1, f2 = AUD_NOTES[k]
    seg = FRAG_SAMPLES // 2                       # 每个音 24000 个样本
    amp = 0.55 * 32767.0
    attack = int(AUD_RATE * 0.015)                # 15ms 淡入
    out = bytearray()

    for i in range(FRAG_SAMPLES):
        if i < seg:
            t = i / float(AUD_RATE)
            u = i / float(seg - 1)                # 0..1 在本音内
            f = f1
        else:
            t = i / float(AUD_RATE)
            u = (i - seg) / float(seg - 1)
            f = f2
        # 包络：短淡入 + 幂次衰减，末尾自然归零（相邻两音的接缝处两边都是 0，
        # 所以不会"啪"一声）
        env = min(1.0, (i % seg) / float(attack))
        env *= (1.0 - u) ** 1.6
        v = int(amp * env * math.sin(2.0 * math.pi * f * t))
        if v > 32767:
            v = 32767
        elif v < -32768:
            v = -32768
        out += struct.pack("<h", v)

    return bytes(out)


# ---------------------------------------------------------------------------
# 接触印相：把 6 张图缩到 1/2 拼成 3x2 一张 PNG，肉眼过一遍
# 本工程不跑仿真，看图是唯一能替代仿真的自检手段（同 hud_cjk_preview.png）
# ---------------------------------------------------------------------------
PREVIEW_OUT = os.path.join(ROOT, "photo", "sd_assets_preview.png")
PREVIEW_SCALE = 2        # 1/2 缩
PREVIEW_GAP = 8


def make_preview(images):
    tw, th = W // PREVIEW_SCALE, H // PREVIEW_SCALE
    cols, rows_n = 3, 2
    gw = cols * tw + (cols + 1) * PREVIEW_GAP
    gh = rows_n * th + (rows_n + 1) * PREVIEW_GAP
    gapc = (48, 48, 56)
    out = [[gapc] * gw for _ in range(gh)]

    for k, rows in enumerate(images):
        cx = PREVIEW_GAP + (k % cols) * (tw + PREVIEW_GAP)
        cy = PREVIEW_GAP + (k // cols) * (th + PREVIEW_GAP)
        for y in range(th):
            src = rows[y * PREVIEW_SCALE]
            dst = out[cy + y]
            for x in range(tw):
                dst[cx + x] = src[x * PREVIEW_SCALE]

    ttf2bmp.write_png(PREVIEW_OUT, gw, gh, out)
    return gw, gh


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="生成 sd_assets/ 的占位底图 + 音频")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录（默认 sd_assets/）")
    ap.add_argument("--no-preview", action="store_true", help="不输出 photo/ 下的预览图")
    args = ap.parse_args()

    # ---- 先断言：要用到的字符必须在 5x7 字库里，缺字直接报错 ----
    #   缺字不会报错、只会被 draw_text 画成空格 —— 预览图上看是"整块空白"，
    #   很容易怀疑到 SD 取图上。宁可在生成阶段就崩。
    missing = set()
    for _, title, code, _ in PAGES:
        for s in (title, code, FAULT_TEXT):
            for ch in s:
                if ch not in G.FONT:
                    missing.add(ch)
    if missing:
        print("错误：下面这些字符不在 gen_hud_assets.FONT 里，会画成空格：%r"
              % "".join(sorted(missing)))
        return 1

    os.makedirs(args.out, exist_ok=True)
    print("输出目录：%s" % os.path.abspath(args.out))
    print()

    print("[1/3] 生成 6 张底图 ...")
    images = []
    for k in range(len(PAGES)):
        rows = make_image(k)
        images.append(rows)
        path = os.path.join(args.out, "img%d.bmp" % k)
        G.write_bmp(path, W, H, rows)
        size = os.path.getsize(path)
        assert size == BMP_FILE_BYTES, \
            "img%d.bmp 写了 %d 字节，应为 %d" % (k, size, BMP_FILE_BYTES)
        print("      img%d.bmp  %8d 字节  %s  (主色 RGB%s)"
              % (k, size, "OK" if size == BMP_FILE_BYTES else "!!!", PAGES[k][0]))

    print()
    print("[2/3] 生成 6 段音频 ...")
    for k in range(len(AUD_NOTES)):
        data = make_audio(k)
        path = os.path.join(args.out, "aud%d.pcm" % k)
        with open(path, "wb") as f:
            f.write(data)
        size = os.path.getsize(path)
        assert size == FRAG_BYTES, \
            "aud%d.pcm 写了 %d 字节，应为 %d" % (k, size, FRAG_BYTES)
        f1, f2 = AUD_NOTES[k]
        print("      aud%d.pcm  %8d 字节  %d 样本  %.2f 秒  %.0f/%.0f Hz"
              % (k, size, FRAG_SAMPLES, FRAG_SAMPLES / float(AUD_RATE), f1, f2))

    if args.no_preview:
        print()
        print("      （跳过预览图）")
    else:
        print()
        print("[3/3] 输出预览图 ...")
        gw, gh = make_preview(images)
        print("      -> photo/sd_assets_preview.png  (%dx%d，6 张图各 1/2 缩，"
              "3x2 排)" % (gw, gh))
        print("      ★ 上板前请【看过这张图】：每格应能看清页码、主色各不相同、"
              "深色方块就是 HUD 叠加层要盖的位置 ★")

    print()
    print("完成。下一步：python tools/layout_sd.py --check   （只打印扇区表，不写文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
