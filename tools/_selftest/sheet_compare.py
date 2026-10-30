# -*- coding: utf-8 -*-
"""临时脚本（用完可删）：把卡上 6 张 BMP 和 sd_assets 里 6 张母版 png 各拼一张对照图。"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = HERE
CARD = sys.argv[1] if len(sys.argv) > 1 else "E:/"

CW, CH = 320, 240          # 缩略图尺寸
COLS, ROWS = 3, 2
PAD, TOP = 6, 18


def sheet(items, out_path, title):
    """items: [(标签, PIL.Image), ...]，6 张，3x2"""
    W = COLS * (CW + PAD) + PAD
    H = ROWS * (CH + TOP + PAD) + PAD
    cv = Image.new("RGB", (W, H), (24, 24, 28))
    dr = ImageDraw.Draw(cv)
    dr.text((8, 4), title, fill=(255, 255, 120))
    for i, (lab, im) in enumerate(items):
        cx = i % COLS
        cy = i // COLS
        x = PAD + cx * (CW + PAD)
        y = PAD + cy * (CH + TOP + PAD)
        dr.text((x, y), lab, fill=(180, 255, 180))
        cv.paste(im.resize((CW, CH), Image.LANCZOS), (x, y + TOP))
    cv.save(out_path)
    print("wrote", out_path, cv.size)


card = []
for n in range(1, 7):
    p = os.path.join(CARD, "%02d.bmp" % n)
    card.append(("CARD %02d.BMP" % n, Image.open(p).convert("RGB")))
sheet(card, os.path.join(OUT, "_sheet_card_new.png"), "TF card  E:\\  (what the FPGA will read)")

masters = []
for n in range(1, 7):
    p = os.path.join(ROOT, "sd_assets", "%02d.png" % n)
    masters.append(("MASTER %02d.png" % n, Image.open(p).convert("RGB")))
sheet(masters, os.path.join(OUT, "_sheet_master.png"), "masters  sd_assets/*.png  (real_assets.py source)")

old = []
for n in range(1, 7):
    p = os.path.join(ROOT, "sd_assets", "_backup_before_20261014", "png", "%02d.png" % n)
    old.append(("OLD %02d.png" % n, Image.open(p).convert("RGB")))
sheet(old, os.path.join(OUT, "_sheet_master_old.png"), "old masters  _backup_before_20261014/png")
