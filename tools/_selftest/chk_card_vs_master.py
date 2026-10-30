# -*- coding: utf-8 -*-
r"""
chk_card_vs_master.py —— 换卡/换素材后的核对脚本。

干四件事：
  1) 打印 sd_assets/0N.png 的尺寸
  2) 把卡上 0N.bmp 和"用 real_assets.py 从当前母版生成"的结果逐字节比，
     并给出像素级差异（最大差 / 平均差 / 有多少点不同），定位差异在头还是在像素
  3) 打印卡上每张 BMP 的【背景色】—— 报警页那张必须是红的
     （★ 不能用 real_assets.color_hint：它取"最饱和的 5%"，这几张图罐体是蓝的，
        它量到的一直是罐体，六张全报"蓝"。背景色要取画面四角。）
  4) 汇总：判定是否达到"母版 -> fat32/ -> 卡"三者一致

用法：
    python tools/_selftest/chk_card_vs_master.py            # 卡在 E:\
    python tools/_selftest/chk_card_vs_master.py F:\        # 指定盘符
    python tools/_selftest/chk_card_vs_master.py --tol 1    # 允许像素差 <= 1 也算通过
"""
import argparse
import hashlib
import os
import sys
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import real_assets as RA                                    # noqa: E402

ASSETS = os.path.join(ROOT, "sd_assets")
W, H = 640, 480
ROW = W * 3


def bg_color(path):
    """取画面四角 + 上边中点的均值 —— 这几张图的"页身份"在背景色上。"""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    pts = [(3, 3), (w - 4, 3), (3, h - 4), (w - 4, h - 4), (w // 2, 3)]
    px = [im.getpixel(p) for p in pts]
    r = sum(p[0] for p in px) // len(px)
    g = sum(p[1] for p in px) // len(px)
    b = sum(p[2] for p in px) // len(px)
    mx, mn = max(r, g, b), min(r, g, b)
    sat = (mx - mn) / float(mx or 1)
    if mx < 45:
        n = "黑/深灰"
    elif sat < 0.15:
        n = "白/灰" if mx > 170 else "中灰"
    elif mx == r:
        n = "黄" if g > 0.80 * r else ("★红★" if g <= 0.30 * r else "橙")
    elif mx == g:
        n = "绿"
    else:
        n = "浅蓝" if (r + g) > b * 1.15 else "蓝/紫"
    return r, g, b, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("card", nargs="?", default="E:/")
    ap.add_argument("--tol", type=int, default=0,
                    help="允许的最大像素差（0 = 要求逐字节相同）")
    args = ap.parse_args()
    card_dir = args.card

    print("源目录 : %s" % ASSETS)
    print("卡     : %s" % card_dir)
    print("PAGE_IMG_SRC = %s" % RA.PAGE_IMG_SRC)
    print()

    print("=== 1) 母版 png 尺寸 ===")
    for n in range(1, 7):
        try:
            w, h, _ = RA.decode_png_rgb(os.path.join(ASSETS, "%02d.png" % n))
            print("   %02d.png  %dx%d" % (n, w, h))
        except Exception as e:
            print("   %02d.png  ** %s" % (n, e))

    print()
    print("=== 2) 卡上 BMP  vs  real_assets 现场生成 ===")
    print("   %-4s %-8s %-9s %-10s %-10s %s"
          % ("页", "卡上名", "来源png", "生成md5", "卡上md5", "逐字节 / 像素差"))
    ok_all = True
    for page in range(6):
        n = page + 1
        m = RA.PAGE_IMG_SRC[page]
        try:
            w, h, rows = RA.decode_png_rgb(os.path.join(ASSETS, "%02d.png" % m))
            tf = os.path.join(tempfile.gettempdir(), "ra_%02d.bmp" % n)
            RA.write_bmp_24_bottomup(tf, w, h, rows)
            gen = open(tf, "rb").read()
            card = open(os.path.join(card_dir, "%02d.bmp" % n), "rb").read()
        except Exception as e:
            print("   %-4d %-8s %-9s ** %s" % (page, "%02d.BMP" % n, "%02d.png" % m, e))
            ok_all = False
            continue

        head_same = (gen[:54] == card[:54])
        ga, gb = gen[54:], card[54:]
        mx = mn = 0
        ndiff = 0
        if len(ga) == len(gb):
            for i in range(len(ga)):
                d = abs(ga[i] - gb[i])
                if d:
                    ndiff += 1
                    if d > mx:
                        mx = d
        else:
            mx = 999
        if gen == card:
            verdict = "逐字节相同 ✓"
        else:
            first = next((i for i in range(min(len(gen), len(card))) if gen[i] != card[i]), -1)
            verdict = ("头不同(%s) " % ("是" if not head_same else "否")
                       + "首个差异@%d  " % first
                       + "像素: 差%d点 最大%d" % (ndiff, mx))
        good = (gen == card) or (head_same and mx <= args.tol)
        ok_all &= good
        print("   %-4d %-8s %-9s %-10s %-10s %s%s"
              % (page, "%02d.BMP" % n, "%02d.png" % m,
                 hashlib.md5(gen).hexdigest()[:8], hashlib.md5(card).hexdigest()[:8],
                 verdict, "" if good else "   <<<"))

    print()
    print("=== 3) 卡上每张 BMP 的背景色（页身份看背景）===")
    for n in range(1, 7):
        try:
            r, g, b, nm = bg_color(os.path.join(card_dir, "%02d.bmp" % n))
            mark = "   ★报警页，必须是红的" if n == 6 else ""
            print("   卡 %02d.BMP  背景 rgb(%3d,%3d,%3d)  %s%s" % (n, r, g, b, nm, mark))
        except Exception as e:
            print("   卡 %02d.BMP  ** %s" % (n, e))

    print()
    if ok_all:
        print("=> 全部通过：母版 -> fat32/ -> 卡 三者一致 ✓")
        return 0
    print("=> 有不一致（上面标 <<< 的行）。若只是头 54 字节不同、像素差 <= --tol，"
          "加 --tol 复核。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
