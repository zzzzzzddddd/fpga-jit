# -*- coding: utf-8 -*-
"""临时脚本（用完可删）：卡上 BMP 和"从某套 png 生成"的结果差多少像素。"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import real_assets as RA                                    # noqa: E402

CARD = sys.argv[1] if len(sys.argv) > 1 else "E:/"

# 候选源目录：(名字, 目录, 是否按 PAGE_IMG_SRC 重排)
SOURCES = [
    ("sd_assets/*.png        (当前母版)", os.path.join(ROOT, "sd_assets"), True),
    ("_backup_before_20261014/png (10-04 备份)", os.path.join(ROOT, "sd_assets", "_backup_before_20261014", "png"), True),
]


def gen_from(src_dir, page, remap):
    m = RA.PAGE_IMG_SRC[page] if remap else page + 1
    p = os.path.join(src_dir, "%02d.png" % m)
    w, h, rows = RA.decode_png_rgb(p)
    tf = os.path.join(tempfile.gettempdir(), "d_%s_%d.bmp" % (os.path.basename(src_dir), page))
    RA.write_bmp_24_bottomup(tf, w, h, rows)
    return open(tf, "rb").read(), m


for name, d, remap in SOURCES:
    if not os.path.isdir(d):
        print("跳过（不存在）：%s" % name)
        continue
    print("=== 源：%s ===" % name)
    for page in range(6):
        n = page + 1
        try:
            gen, m = gen_from(d, page, remap)
            card = open(os.path.join(CARD, "%02d.bmp" % n), "rb").read()
            if gen == card:
                print("  页%d  %02d.BMP  <- %02d.png   逐字节相同" % (page, n, m))
                continue
            a, b = gen[54:], card[54:]
            diff = [abs(a[i] - b[i]) for i in range(0, len(a), 997)]     # 抽样
            nz = sum(1 for x in diff if x)
            print("  页%d  %02d.BMP  <- %02d.png   不同：抽样 %d 点，%d 点有差，最大差 %d，平均差 %.2f"
                  % (page, n, m, len(diff), nz, max(diff), sum(diff) / float(len(diff))))
        except Exception as e:
            print("  页%d  %02d.BMP  ** %s" % (page, n, e))
    print()
