# -*- coding: utf-8 -*-
"""
ttf2bmp.py  --  汉字点阵提取（16x16），给 gen_hud_assets.py 用

【为什么不用 PIL】
  gen_hud_assets.py 的约定是"纯 Python 3、零第三方依赖"，这台机器上 PIL 没装。
  所以这里直接用 ctypes 调 Windows 的 GDI 取字形，不需要装任何包。

【为什么是"画进 DIB 再读像素"，而不是 GetGlyphOutlineW】
  第一版用的是 GetGlyphOutlineW + GGO_BITMAP。走不通，原因很实在：
  GetGlyphOutlineW 只做【纯轮廓栅格化】，GDI 不会为它做任何 hinting，也不会
  替换成字体自带的嵌入点阵。汉字横画密、笔画细，在 15/16px 上直接取出来的
  1bpp 点阵糊成一团 —— 超 / 限 / 警 / 障 基本认不出来，实测过。
  外面套 4 倍超采样也只是把糊的东西算得更平均一点，救不回来（[1]）。

  正路是让 GDI 按【它真正显示文字时的那条路】渲染：
      CreateDIBSection 建一张 32bpp 内存位图 -> 选进内存 DC ->
      SetTextColor(白) + SetBkMode(TRANSPARENT) -> TextOutW 画一个字 ->
      直接从 DIB 的像素指针读回灰度 -> 按比例二值化
  这条路走的是 GDI 的字体引擎主流（hinting + 灰度抗锯齿都在），
  出来的就是记事本里看到的样子。代价是只支持 Windows —— 本工程本来就只在
  这台 Win11 机器上生成，不是问题。

  [1] 其实 GetGlyphOutlineW + ANTIALIASED_QUALITY 也是 1bpp 的：
      GGO_BITMAP 这个 flag 本身就规定了"单色点阵"，quality 对它无效。

【坐标约定】
  取 DEFAULT 的 TA_TOP|TA_LEFT 对齐：TextOutW(x, y) 的 y 是【字符格子顶边】，
  字形占 [y, y+tmHeight]。所以在 cell x cell 的输出格子里，先建一张
  (cell+2*M) 见方的 DIB，把字画在 (M, M)，再裁 [M, M+cell) —— 这样每个字
  都共用同一个 em 格和基线，字与字之间不会上下跳。
  （不要改成"按墨迹包围盒居中"：那样"一"会飘到格子中间，和别的字对不齐。）

【用什么字体 —— 这一条是质量的关键】
  **SimSun（宋体）优先**，因为它带了 12/13/14/15/16px 的内嵌点阵字模
  （TrueType 的 EBDT/EBLC 表）。GDI 的 TextOut 碰到内嵌字模会【直接位图拷贝】，
  不做轮廓栅格化 —— 所以取到的就是 Windows 记事本里那个 16x16 宋体点阵，
  是手工调过的，不是算出来的。

  实测（就是本文件生成的那三张对比）：
    SimSun @16px   警 的 言 部分三横分离、障 的 阝 完整、罐 的 缶 清晰 —— 可用
    SimHei  同尺寸  警 的 言 糊成四条实心横杠、障 的 阝 缺胳膊少腿 —— 不可用
  而且 SimSun 在 quality=ANTIALIASED 和 quality=DRAFT 下输出【逐位相同】，
  反过来证明它走的是内嵌字模那条路（轮廓栅格化不可能两种 quality 一样）。

  注意：内嵌字模只在特定字号上有。本工程固定 cell=16 / pixel_size=16，
  正好命中。**改这两个数之前先重新出预览图确认**，改成 15 或 17 就掉回轮廓
  栅格化，质量立刻崩。

  一个都建不出来就抛异常，让调用方报错退出，不要静默出空字。
"""

import ctypes
from ctypes import wintypes

# ---------------------------------------------------------------------------
# GDI 绑定
# ---------------------------------------------------------------------------
_gdi32 = ctypes.WinDLL("gdi32")
_user32 = ctypes.WinDLL("user32")

# CreateFontW 的部分参数
FW_NORMAL = 400
DEFAULT_CHARSET = 1
OUT_TT_PRECIS = 4
CLIP_DEFAULT_PRECIS = 0
ANTIALIASED_QUALITY = 4
DEFAULT_PITCH = 0
FF_DONTCARE = 0

DIB_RGB_COLORS = 0
BI_RGB = 0
TRANSPARENT = 1


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize",          wintypes.DWORD),
        ("biWidth",         wintypes.LONG),
        ("biHeight",        wintypes.LONG),   # 负值 = 自上而下的 DIB
        ("biPlanes",        wintypes.WORD),
        ("biBitCount",      wintypes.WORD),
        ("biCompression",   wintypes.DWORD),
        ("biSizeImage",     wintypes.DWORD),
        ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG),
        ("biClrUsed",       wintypes.DWORD),
        ("biClrImportant",  wintypes.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER),
                ("bmiColors", wintypes.DWORD * 3)]


class TEXTMETRICW(ctypes.Structure):
    _fields_ = [
        ("tmHeight",           wintypes.LONG),
        ("tmAscent",           wintypes.LONG),
        ("tmDescent",          wintypes.LONG),
        ("tmInternalLeading",  wintypes.LONG),
        ("tmExternalLeading",  wintypes.LONG),
        ("tmAveCharWidth",     wintypes.LONG),
        ("tmMaxCharWidth",     wintypes.LONG),
        ("tmWeight",           wintypes.LONG),
        ("tmOverhang",         wintypes.LONG),
        ("tmDigitizedAspectX", wintypes.LONG),
        ("tmDigitizedAspectY", wintypes.LONG),
        ("tmFirstChar",        wintypes.WCHAR),
        ("tmLastChar",         wintypes.WCHAR),
        ("tmDefaultChar",      wintypes.WCHAR),
        ("tmBreakChar",        wintypes.WCHAR),
        ("tmItalic",           ctypes.c_byte),
        ("tmUnderlined",       ctypes.c_byte),
        ("tmStruckOut",        ctypes.c_byte),
        ("tmPitchAndFamily",   ctypes.c_byte),
        ("tmCharSet",          ctypes.c_byte),
    ]


# ★ 每个入口都要写清楚 argtypes/restype ★
#   HDC/HGDIOBJ/HBITMAP 都是 64 位指针。不声明 argtypes 的话 ctypes 会按 C int 传，
#   Win11 64 位上直接 "OverflowError: int too long to convert"。
_gdi32.CreateCompatibleDC.restype = wintypes.HDC
_gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]

_gdi32.CreateFontW.restype = wintypes.HGDIOBJ
# 5 个 int（高/宽/escapement/倾斜/字重）+ 8 个 DWORD + 1 个字体名 = 14
_gdi32.CreateFontW.argtypes = [
    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    ctypes.c_int,
    wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,   # italic/underline/strikeout
    wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,   # charset/outprec/clipprec
    wintypes.DWORD, wintypes.DWORD,                   # quality/pitch
    wintypes.LPCWSTR,
]

_gdi32.CreateDIBSection.restype = wintypes.HBITMAP
_gdi32.CreateDIBSection.argtypes = [
    wintypes.HDC, ctypes.POINTER(BITMAPINFO), wintypes.UINT,
    ctypes.POINTER(ctypes.c_void_p), wintypes.HANDLE, wintypes.DWORD,
]

_gdi32.SelectObject.restype = wintypes.HGDIOBJ
_gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]

_gdi32.SetTextColor.restype = wintypes.DWORD      # COLORREF = 0x00BBGGRR
_gdi32.SetTextColor.argtypes = [wintypes.HDC, wintypes.DWORD]

_gdi32.SetBkMode.restype = ctypes.c_int
_gdi32.SetBkMode.argtypes = [wintypes.HDC, ctypes.c_int]

_gdi32.TextOutW.restype = wintypes.BOOL
_gdi32.TextOutW.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int,
                            wintypes.LPCWSTR, ctypes.c_int]

_gdi32.GetTextMetricsW.restype = wintypes.BOOL
_gdi32.GetTextMetricsW.argtypes = [wintypes.HDC, ctypes.POINTER(TEXTMETRICW)]

_gdi32.DeleteObject.restype = wintypes.BOOL
_gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]

_gdi32.DeleteDC.restype = wintypes.BOOL
_gdi32.DeleteDC.argtypes = [wintypes.HDC]


# 候选字体顺序：SimSun 有 16px 内嵌点阵，质量断层领先（见文件头）；NSimSun 是
# 它的等宽别名，输出逐位相同，放第二个纯属兜底；后面的只在 SimSun 缺失时才用得上，
# 都是纯轮廓栅格化，16px 下明显更糊。
FONT_CANDIDATES = ["SimSun", "NSimSun", "SimHei", "Microsoft YaHei", "DengXian"]

# 画布四周留多少像素，字形不会被裁掉
MARGIN = 8


class _FontCtx(object):
    """
    一个 GDI 内存 DC + 一张 32bpp 自上而下的 DIB + 一个选好的字体。
    整批字复用同一份，避免每个字都建/删 GDI 对象。
    """

    def __init__(self, cell, pixel_size, margin=MARGIN):
        self.cell = cell
        self.margin = margin
        self.w = cell + 2 * margin
        self.h = cell + 2 * margin
        self.hdc = None
        self.hfont = None
        self.hbmp = None
        self.ppv = None
        self.name = None
        self.tm = None

        self.hdc = _gdi32.CreateCompatibleDC(None)
        if not self.hdc:
            raise RuntimeError("CreateCompatibleDC 失败")

        for name in FONT_CANDIDATES:
            hf = _gdi32.CreateFontW(
                -int(pixel_size),      # 负值 = 字符高度（不是格子高度）
                0, 0, 0,
                FW_NORMAL,
                0, 0, 0,
                DEFAULT_CHARSET,
                OUT_TT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                ANTIALIASED_QUALITY,   # 灰度抗锯齿，二值化前拿到的是覆盖率
                DEFAULT_PITCH | FF_DONTCARE,
                name,
            )
            if hf:
                self.hfont = hf
                self.name = name
                break
        if not self.hfont:
            raise RuntimeError("GDI 字体一个都建不出来: %s" % (FONT_CANDIDATES,))
        _gdi32.SelectObject(self.hdc, self.hfont)

        # ---- 32bpp 自上而下 DIB ----
        bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bmi.bmiHeader.biWidth = self.w
        bmi.bmiHeader.biHeight = -self.h          # 负 = top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = BI_RGB
        self.ppv = ctypes.c_void_p()
        self.hbmp = _gdi32.CreateDIBSection(
            self.hdc, ctypes.byref(bmi), DIB_RGB_COLORS,
            ctypes.byref(self.ppv), None, 0)
        if not self.hbmp or not self.ppv:
            raise RuntimeError("CreateDIBSection 失败")
        _gdi32.SelectObject(self.hdc, self.hbmp)

        _gdi32.SetBkMode(self.hdc, TRANSPARENT)   # 背景不清，靠我们自己 memset
        _gdi32.SetTextColor(self.hdc, 0x00FFFFFF)  # 白字

        self.tm = TEXTMETRICW()
        _gdi32.GetTextMetricsW(self.hdc, ctypes.byref(self.tm))

    def close(self):
        if self.hbmp:
            _gdi32.DeleteObject(self.hbmp)
            self.hbmp = None
        if self.hfont:
            _gdi32.DeleteObject(self.hfont)
            self.hfont = None
        if self.hdc:
            _gdi32.DeleteDC(self.hdc)
            self.hdc = None


def _draw_gray(ctx, ch):
    """
    把 ch 画到 ctx 的 DIB 上，返回 w x h 的灰度矩阵（0..255，自上而下）。
    32bpp BI_RGB 在内存里是 B,G,R,A 四字节，字体是白色，所以三个通道值相同；
    取 blue 通道即可（alpha 通道 GDI 文字绘制不保证有效，不要用它）。
    """
    n = ctx.w * ctx.h * 4
    ctypes.memset(ctx.ppv, 0, n)                  # 清成黑底
    if ch != " ":
        ok = _gdi32.TextOutW(ctx.hdc, ctx.margin, ctx.margin, ch, 1)
        if not ok:
            return [[0] * ctx.w for _ in range(ctx.h)]

    raw = ctypes.string_at(ctx.ppv, n)
    gray = [[0] * ctx.w for _ in range(ctx.h)]
    for y in range(ctx.h):
        base = y * ctx.w * 4
        row = gray[y]
        for x in range(ctx.w):
            # 偏移 +0 = blue。文字是纯白，任取一通道都一样
            row[x] = raw[base + x * 4]
    return gray


def _render_one(ctx, ch, thresh_ratio=0.40):
    """
    返回 cell x cell 的 0/1 矩阵（自上而下），1 = 有笔画。

    thresh_ratio 是【覆盖率的比例阈值】：抗锯齿出来的灰度 0..255 就是笔画覆盖
    这个像素的比例，>= thresh_ratio*255 算实心。
    实测 0.40 是平衡点 —— 低了笔画糊成一坨（0.25 时 警/障/罐 内部结构全丢），
    高了细横画会断（0.55 时 障 左边的 阝 会散开）。
    """
    gray = _draw_gray(ctx, ch)
    m = ctx.margin
    cut = thresh_ratio * 255.0
    out = [[0] * ctx.cell for _ in range(ctx.cell)]
    for y in range(ctx.cell):
        gsrc = gray[m + y]
        orow = out[y]
        for x in range(ctx.cell):
            orow[x] = 1 if gsrc[m + x] >= cut else 0
    return out


def get_glyphs(text, cell=16, pixel_size=None, thresh_ratio=0.40,
               first_only=False, verbose=False):
    """
    输入一串汉字，返回 ({字: [[0/1]*cell]*cell}, 字体名)。

    pixel_size 是【输出分辨率下】的字号，默认 cell（16x16 的格子用 16px 的字）。
    用 cell 而不是 cell-1：GDI 的 CJK em 格本来就比字身略大一点点留白，
    再手动缩一号反而让笔画挤在一起变糊。
    """
    if pixel_size is None:
        pixel_size = cell
    ctx = _FontCtx(cell, pixel_size)
    if verbose:
        tm = ctx.tm
        print("      GDI 字体: %s, 字号 %dpx, 格子 %dx%d, 画布 %dx%d(边距 %d)"
              % (ctx.name, pixel_size, cell, cell, ctx.w, ctx.h, ctx.margin))
        print("      tmHeight=%d tmAscent=%d tmDescent=%d tmInternalLeading=%d "
              "tmAveCharWidth=%d"
              % (tm.tmHeight, tm.tmAscent, tm.tmDescent,
                 tm.tmInternalLeading, tm.tmAveCharWidth))
    try:
        out = {}
        for ch in text:
            if ch in out:
                continue
            out[ch] = _render_one(ctx, ch, thresh_ratio)
            if first_only:
                break
        return out, ctx.name
    finally:
        ctx.close()


# ---------------------------------------------------------------------------
# 预览：纯 Python 写 PNG（zlib 是标准库），用来肉眼逐字检查
# ---------------------------------------------------------------------------
def write_png(path, w, h, rgb_rows):
    """rgb_rows: 自上而下，每行 w 个 (r,g,b)"""
    import zlib
    import struct

    raw = bytearray()
    for row in rgb_rows:
        raw.append(0)                       # filter type 0
        for (r, g, b) in row:
            raw += bytes((r, g, b))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        c += struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        return c

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def preview_png(path, glyphs, chars, cell=16, scale=3, cols=16):
    """把一排字排成格子图，每个字放大 scale 倍"""
    n = len(chars)
    rows_n = (n + cols - 1) // cols
    cw = cell * scale
    W, H = cols * cw, rows_n * cw
    bg, fg, grid = (12, 16, 26), (230, 238, 246), (40, 60, 90)
    canvas = [[bg] * W for _ in range(H)]
    for i, ch in enumerate(chars):
        ox = (i % cols) * cw
        oy = (i // cols) * cw
        g = glyphs.get(ch)
        if g is None:
            continue
        for y in range(cell):
            for x in range(cell):
                if not g[y][x]:
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        yy, xx = oy + y * scale + dy, ox + x * scale + dx
                        if 0 <= yy < H and 0 <= xx < W:
                            canvas[yy][xx] = fg
        # 格子边框（画在放大后的格线位置）
        for k in range(cw):
            if oy < H:
                canvas[oy][min(ox + k, W - 1)] = grid
            if ox < W:
                canvas[min(oy + k, H - 1)][ox] = grid
    write_png(path, W, H, canvas)
    return W, H, rows_n


def ascii_art(g, cell=16):
    return "\n".join("".join("#" if v else "." for v in row) for row in g)


if __name__ == "__main__":
    import os
    import sys

    # 自带一个自检：把常用字渲染出来存成 PNG，肉眼看
    demo = "压力容器罐内温度液位锅炉水报警正常故障总览待机巡检趋势安全超标"
    g, fname = get_glyphs(demo, verbose=True)
    out = os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "photo", "cjk_check.png"))
    try:
        W, H, rn = preview_png(out, g, demo)
        print("已写出 %s  (%dx%d, %d 行)" % (out, W, H, rn))
    except IOError as e:
        print("写预览失败（%s），只打字符画" % e)

    print("字体: %s" % fname)
    for ch in demo[:6]:
        print("---- %s ----" % ch)
        print(ascii_art(g[ch]))
