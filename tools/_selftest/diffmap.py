# -*- coding: utf-8 -*-
"""临时脚本（用完可删）：画出"卡上 BMP − 现场生成"的差异图（放大 8 倍）。
有文字/水印形状 = 内容真的不同；只是雪花噪点 = 重编码误差。"""
import os
import sys
import tempfile

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import real_assets as RA                                    # noqa: E402

CARD = sys.argv[1] if len(sys.argv) > 1 else "E:/"
W, H = 640, 480
AMP = 8


def to_rgb(img_bytes):
    im = Image.frombytes("RGB", (W, H), bytes(img_bytes)).transpose(Image.FLIP_TOP_BOTTOM)
    b, g, r = im.split()
    return Image.merge("RGB", (r, g, b))


tiles = []
for n in (1, 6):
    page = n - 1
    w, h, rows = RA.decode_png_rgb(os.path.join(ROOT, "sd_assets", "%02d.png" % RA.PAGE_IMG_SRC[page]))
    tf = os.path.join(tempfile.gettempdir(), "m_%02d.bmp" % n)
    RA.write_bmp_24_bottomup(tf, w, h, rows)
    a = to_rgb(open(tf, "rb").read()[54:])
    b = to_rgb(open(os.path.join(CARD, "%02d.bmp" % n), "rb").read()[54:])
    pa, pb = a.load(), b.load()
    d = Image.new("L", (W, H))
    pd = d.load()
    mx = 0
    for y in range(H):
        for x in range(W):
            ra, ga, ba = pa[x, y]
            rb, gb, bb = pb[x, y]
            v = max(abs(ra - rb), abs(ga - gb), abs(ba - bb))
            if v > mx:
                mx = v
            pd[x, y] = min(255, v * AMP)
    tiles.append(("|diff| x%d   max=%d   卡上 %02d.bmp vs 生成 %02d.BMP" % (AMP, mx, n, n), d))

PAD, TOP = 8, 16
th = H // 2                                    # 缩一半省地方
cv = Image.new("RGB", (W + 2 * PAD, len(tiles) * (th + TOP + PAD) + PAD), (20, 20, 24))
dr = ImageDraw.Draw(cv)
for i, (lab, t) in enumerate(tiles):
    y = PAD + i * (th + TOP + PAD)
    dr.text((PAD, y), lab, fill=(255, 255, 130))
    cv.paste(t.convert("RGB").resize((W, th), Image.LANCZOS), (PAD, y + TOP))
out = os.path.join(HERE, "_diffmap.png")
cv.save(out)
print("wrote", out, cv.size)
