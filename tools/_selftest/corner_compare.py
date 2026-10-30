# -*- coding: utf-8 -*-
"""临时脚本（用完可删）：放大对比【右下角】—— 卡上 vs real_assets 现场生成。
BMP 是 bottom-up，所以图像的"底部"在文件像素流的开头。"""
import os
import sys
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import real_assets as RA                                    # noqa: E402

CARD = sys.argv[1] if len(sys.argv) > 1 else "E:/"
CW, CH, Z = 210, 80, 6                    # 右下角裁 210x80，放大 6 倍


def raw_to_img(buf, w, h):
    """bottom-up BGR -> PIL Image（正立）"""
    im = Image.frombytes("RGB", (w, h), bytes(buf))
    im = im.transpose(Image.FLIP_TOP_BOTTOM)          # 文件 bottom-up -> 正立
    b, g, r = im.split()                              # 文件是 BGR
    return Image.merge("RGB", (r, g, b))


tiles = []
for n in (1, 6):
    page = n - 1
    m = RA.PAGE_IMG_SRC[page]
    w, h, rows = RA.decode_png_rgb(os.path.join(ROOT, "sd_assets", "%02d.png" % m))
    tf = os.path.join(tempfile.gettempdir(), "c_%02d.bmp" % n)
    RA.write_bmp_24_bottomup(tf, w, h, rows)

    card = raw_to_img(open(os.path.join(CARD, "%02d.bmp" % n), "rb").read()[54:], w, h)
    gen = raw_to_img(open(tf, "rb").read()[54:], w, h)

    tiles.append(("CARD %02d.bmp (卡上)" % n, card.crop((w - CW, h - CH, w, h))))
    tiles.append(("GEN  %02d.BMP (现场生成)" % n, gen.crop((w - CW, h - CH, w, h))))

from PIL import ImageDraw                                  # noqa: E402

PAD, TOP = 8, 16
tmw, tmh = CW * Z, CH * Z
cv = Image.new("RGB", (tmw + 2 * PAD, len(tiles) * (tmh + TOP + PAD) + PAD), (20, 20, 24))
dr = ImageDraw.Draw(cv)
for i, (lab, t) in enumerate(tiles):
    y = PAD + i * (tmh + TOP + PAD)
    dr.text((PAD, y), lab + "   bottom-right corner x4", fill=(255, 255, 130))
    cv.paste(t.resize((tmw, tmh), Image.NEAREST), (PAD, y + TOP))
out = os.path.join(HERE, "_corner_compare.png")
cv.save(out)
print("wrote", out, cv.size)
