# -*- coding: utf-8 -*-
"""
bmp_noise_check.py —— 检查 sd_assets/img*.bmp 自己有没有"噪点"，
                       并把图转成 PNG 供人眼查看。

为什么要做：
    上板看到"零散的点撒满全图、位置钉死不动、SD 读时钟降 4 倍也一模一样"。
    这个组合跟"实时信号完整性问题"矛盾 —— 后者应当是随机的。
    所以先要排掉一个最朴素的可能：**点本来就在图片文件里**。
    如果源图自己就有孤立噪点，那 FPGA 什么错都没有。

"孤立噪点"的判据（故意保守，只抓明显的）：
    一个像素如果和【上下左右四个邻居全都】差得很远（每通道 > DIFF），
    就算孤立点。整片纹理、边缘、渐变都不会被算进去 ——
    只有"孤零零一个像素跟周围完全不同"才算。

同时输出 PNG（按 BMP 规范：h>0 表示文件第 0 行是图像【底】行，
所以要翻转行序才是人眼看到的朝向）。看图能直接确认文件本身正不正常。
"""
import struct
import zlib
import glob
import os

DIFF = 60          # 每通道差值阈值
OUT_PNG = True


def read_bmp(path):
    d = open(path, "rb").read()
    assert d[:2] == b"BM", path + " 不是 BMP"
    off = struct.unpack_from("<I", d, 10)[0]
    w = struct.unpack_from("<i", d, 18)[0]
    h = struct.unpack_from("<i", d, 22)[0]
    bpp = struct.unpack_from("<H", d, 28)[0]
    comp = struct.unpack_from("<I", d, 30)[0]
    assert bpp == 24 and comp == 0, f"{path}: 只处理 24 位未压缩 (bpp={bpp} comp={comp})"
    ah = abs(h)
    stride = (w * 3 + 3) & ~3                 # 行按 4 字节对齐
    rows = []
    for r in range(ah):
        s = off + r * stride
        row = d[s:s + w * 3]
        # BGR -> RGB
        rows.append(bytes(b for i in range(0, w * 3, 3)
                          for b in (row[i + 2], row[i + 1], row[i])))
    if h > 0:
        rows.reverse()                        # 文件底行在前 -> 翻成自上而下
    return w, ah, rows


def count_isolated(w, h, rows):
    """返回 (孤立点数, 位置列表前若干个)。"""
    def px(r, c):
        i = c * 3
        return rows[r][i], rows[r][i + 1], rows[r][i + 2]

    def far(a, b):
        return (abs(a[0] - b[0]) > DIFF and abs(a[1] - b[1]) > DIFF
                and abs(a[2] - b[2]) > DIFF)

    hits = []
    for r in range(1, h - 1):
        for c in range(1, w - 1):
            p = px(r, c)
            if (far(p, px(r - 1, c)) and far(p, px(r + 1, c))
                    and far(p, px(r, c - 1)) and far(p, px(r, c + 1))):
                hits.append((r, c))
    return hits


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + rows[r] for r in range(h))
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)


if __name__ == "__main__":
    # ★ 2026-10-05 改到【当前真素材】：sd_assets/fat32/0N.BMP 就是 FPGA 真正
    #   流进 SDRAM 的那批字节，所以它才是该查的对象。
    #   （旧的 sd_assets/img*.bmp 是已退役的占位素材，早已不存在。）
    #   ★ 但判据只是"排掉最朴素的可能"，别把它当结论 —— 真正该做的是
    #     把图【打开看】（tools/bmp2png.py），这条在 fat32-migration-status 里
    #     记着一次很贵的教训。现在的真素材全过（只抓到照片本身的细斜线误报）。★
    pats = sorted(glob.glob("sd_assets/fat32/[0-9][0-9].BMP"))
    if not pats:
        pats = sorted(glob.glob("sd_assets/img*.bmp"))
    for p in pats + ["photo/logo.bmp", "1.bmp", "3.bmp"]:
        if not os.path.exists(p):
            continue
        w, h, rows = read_bmp(p)
        hits = count_isolated(w, h, rows)
        print(f"{os.path.basename(p):<14} {w}x{h}  孤立噪点 = {len(hits)}")
        if hits:
            print(f"{'':<14}  前 8 个位置 (行,列): {hits[:8]}")
        if OUT_PNG and len(pats) and p == pats[0]:
            out = os.path.splitext(os.path.basename(p))[0] + "_noise_check.png"
            write_png(out, w, h, rows)
            print(f"{'':<14}  -> 已写出 {out}（按 BMP 规范摆正后的人眼朝向）")
