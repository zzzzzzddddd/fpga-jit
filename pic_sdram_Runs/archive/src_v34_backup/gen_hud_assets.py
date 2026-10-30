# -*- coding: utf-8 -*-
"""
gen_hud_assets.py  --  压力容器多媒体播放系统 HUD 资源 ROM 生成器

纯 Python 3 (无第三方依赖)，生成 4 个可综合的 Verilog ROM：

  1) src/hud/hud_rom_dial.v    表盘静态底图  96x96 4bit 调色板   (硬件按 2x/4x 放大显示)
  2) src/hud/hud_rom_font.v    5x7 字库      53 个字符 x 8 行     (组合逻辑 case)
  3) src/hud/hud_rom_sincos.v  sin/cos 查表  1024 点 x 24bit      (Q1.11, 单口 ROM)
  4) src/hud/hud_rom_cjk.v     16x16 汉字点阵 49 字 x 16 行 x 16bit (同步单读口 BSRAM)

并输出预览图：
  photo/hud_dial_preview.bmp    表盘底图 + 若干角度的指针（放大 2x，方便肉眼确认）
  photo/hud_font_preview.bmp    字库预览
  photo/hud_cjk_preview.png     汉字点阵预览（这一版唯一能替代仿真的自检手段）

用法：
  python tools/gen_hud_assets.py
  python tools/gen_hud_assets.py --no-preview      # 只出 ROM，不出预览图

设计约束（与 RTL 严格对应，改这里必须同步改 src/hud/hud_defs.vh）：
  DIAL_SRC      = 96         表盘源图边长(像素)
  DIAL_SCALE    = 2          硬件放大倍数
  DIAL_R_OUT    = 42.0       源图里外圈半径 -> 显示半径 84
  NEEDLE_LEN    = 72         指针长度(显示像素)
"""

import math
import os
import re
import struct
import sys

# 控制台按 UTF-8 输出，否则中文提示在 GBK 终端里是乱码
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass

# 汉字点阵走 ttf2bmp.py（ctypes 调 Windows GDI，见那个文件头的说明）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ttf2bmp

# ----------------------------------------------------------------------------
# 路径
# ----------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HUD_DIR = os.path.join(ROOT, "src", "hud")
PHOTO_DIR = os.path.join(ROOT, "photo")

# ----------------------------------------------------------------------------
# 调色板：4bit 索引 -> RGB444（必须与 src/hud/hud_overlay.v 里的 case 一致）
# ----------------------------------------------------------------------------
#  0 transparent   1 face-a   2 face-b   3 bezel    4 tick-major  5 tick-minor
#  6 redzone       7 hub      8 sweep-mark
DIAL_PALETTE = {
    0: (0x0, 0x0, 0x0),      # 透明（硬件里 hit=0）
    1: (0x1, 0x3, 0x5),      # 盘面外环 深蓝
    2: (0x1, 0x2, 0x4),      # 盘面内圈 更深的蓝
    3: (0x9, 0xA, 0xC),      # 外圈金属灰
    4: (0xF, 0xF, 0xF),      # 长刻度 白
    5: (0x8, 0x9, 0x9),      # 短刻度 灰
    6: (0xF, 0x2, 0x1),      # 红区
    7: (0xD, 0xE, 0xF),      # 中心轴
    8: (0xF, 0xC, 0x0),      # 量程端点标记 琥珀
}

# ----------------------------------------------------------------------------
# 表盘几何（源图像素坐标，边长 DIAL_SRC）
# ----------------------------------------------------------------------------
DIAL_SRC   = 96
DIAL_C     = (DIAL_SRC - 1) / 2.0     # 47.5
R_OUT      = 42.0     # 外圈外沿
R_BEZEL    = 38.5     # 外圈内沿
R_FACE     = 38.5     # 盘面半径
R_TICK_O   = 36.0     # 刻度外端
R_TICK_MAJ = 29.0     # 长刻度内端
R_TICK_MIN = 33.0     # 短刻度内端
R_GRAD     = 22.0     # 盘面配色分界半径
R_HUB      = 5.0      # 中心轴半径

SWEEP_MIN  = -125.0   # 量程起点（相对 12 点方向，顺时针为正）
SWEEP_MAX  = 125.0
# 红区（超限区）起点 = 报警点所在的角度。
#   ★ 原来是 88.0（= 85.2% 量程），那是照【液位高 >85%】画的 ★
#   可压力和温度的报警点是 75% 量程（>120/160、>95 于 20..120），
#   比红区起点低 ⇒ 报警时指针停在红区【外面】（上板实测："进入警报界面
#   指针不一定在红色部分"）。
#   改成 62.5 = -125 + 0.75*250 ⇒ 红区正好从压力/温度的报警点开始；
#   液位高（85%）落在红区里更靠内的位置，仍然对。
RED_MIN    = 62.5
RED_MAX    = 125.0

TICK_MAJ_STEP = 25.0  # 长刻度间隔
TICK_MIN_STEP = 5.0   # 短刻度间隔

SUPERSAMPLE = 4       # 超采样倍数，抗锯齿

# ----------------------------------------------------------------------------
# 字库：5x7，'#'=亮
# ----------------------------------------------------------------------------
CHARSET = (" 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
           ".,:;!?%-/<>()=+*")

FONT = {
    ' ': [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    '0': [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    '1': ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    '2': [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    '3': ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
    '4': ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    '5': ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    '6': ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    '7': ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    '8': [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    '9': [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    'A': ["..#..", ".#.#.", "#...#", "#...#", "#####", "#...#", "#...#"],
    'B': ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    'C': [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    'D': ["###..", "#..#.", "#...#", "#...#", "#...#", "#..#.", "###.."],
    'E': ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    'F': ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    'G': [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
    'H': ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    'I': [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    'J': ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    'K': ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    'L': ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    'M': ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    'N': ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
    'O': [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    'P': ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    'Q': [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    'R': ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    'S': [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    'T': ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    'U': ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    'V': ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    'W': ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
    'X': ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    'Y': ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    'Z': ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    '.': [".....", ".....", ".....", ".....", ".....", ".#.#.", ".#.#."],
    ',': [".....", ".....", ".....", ".....", "..#..", "..#..", ".#..."],
    ':': [".....", "..#..", "..#..", ".....", "..#..", "..#..", "....."],
    ';': [".....", "..#..", "..#..", ".....", "..#..", "..#..", ".#..."],
    '!': ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    '?': [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
    '%': ["##..#", "##.#.", "...#.", "..#..", ".#...", ".#.##", "#..##"],
    '-': [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    '/': ["....#", "...#.", "...#.", "..#..", ".#...", ".#...", "#...."],
    '<': ["....#", "...#.", "..#..", ".#...", "..#..", "...#.", "....#"],
    '>': ["#....", ".#...", "..#..", "...#.", "..#..", ".#...", "#...."],
    '(': ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
    ')': [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
    '=': [".....", ".....", "#####", ".....", "#####", ".....", "....."],
    '+': [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    '*': ["..#..", "#.#.#", ".###.", "#.#.#", "..#..", ".....", "....."],
}


# ============================================================================
# 表盘渲染
# ============================================================================
def _angle_of(dx, dy):
    """屏幕坐标下 (dx,dy) 相对 12 点方向顺时针的角度，单位度，范围 (-180,180]"""
    return math.degrees(math.atan2(dx, -dy))


def _seg_dist(px, py, x0, y0, x1, y1):
    """点到线段距离"""
    vx, vy = x1 - x0, y1 - y0
    wx, wy = px - x0, py - y0
    L2 = vx * vx + vy * vy
    if L2 <= 1e-9:
        return math.hypot(wx, wy)
    t = (wx * vx + wy * vy) / L2
    t = max(0.0, min(1.0, t))
    return math.hypot(wx - t * vx, wy - t * vy)


def _tick_angles():
    """返回 [(角度, 是否长刻度), ...]"""
    out = []
    a = SWEEP_MIN
    while a <= SWEEP_MAX + 1e-6:
        is_maj = (abs(a / TICK_MAJ_STEP - round(a / TICK_MAJ_STEP)) < 1e-6)
        out.append((a, is_maj))
        a += TICK_MIN_STEP
    return out


def render_dial_hires():
    """在超采样分辨率下渲染表盘，返回 (W, H, 颜色索引二维数组)"""
    W = H = DIAL_SRC * SUPERSAMPLE
    img = [[0] * W for _ in range(H)]
    c = DIAL_C * SUPERSAMPLE
    r_out = R_OUT * SUPERSAMPLE
    r_bez = R_BEZEL * SUPERSAMPLE
    r_grad = R_GRAD * SUPERSAMPLE
    r_hub = R_HUB * SUPERSAMPLE

    # 1) 盘面 + 外圈
    for y in range(H):
        dy = y + 0.5 - c
        for x in range(W):
            dx = x + 0.5 - c
            r = math.hypot(dx, dy)
            if r > r_out:
                col = 0
            elif r >= r_bez:
                col = 3                      # 外圈金属
            elif r >= r_grad:
                col = 1                      # 盘面外环
            else:
                col = 2                      # 盘面内圈
            img[y][x] = col

    # 2) 红区（覆盖在外圈上）
    a0, a1 = RED_MIN, RED_MAX
    for y in range(H):
        dy = y + 0.5 - c
        for x in range(W):
            dx = x + 0.5 - c
            r = math.hypot(dx, dy)
            if r_bez <= r <= r_out:
                ang = _angle_of(dx, dy)
                if a0 <= ang <= a1:
                    img[y][x] = 6

    # 3) 刻度
    ticks = _tick_angles()
    for ang, is_maj in ticks:
        rad = math.radians(ang)
        ux, uy = math.sin(rad), -math.cos(rad)     # 单位方向（屏幕坐标）
        r0 = (R_TICK_MAJ if is_maj else R_TICK_MIN) * SUPERSAMPLE
        r1 = R_TICK_O * SUPERSAMPLE
        hw = (1.05 if is_maj else 0.75) * SUPERSAMPLE
        x0, y0 = c + ux * r0, c + uy * r0
        x1, y1 = c + ux * r1, c + uy * r1
        in_red = (RED_MIN <= ang <= RED_MAX)
        col = 6 if in_red else (4 if is_maj else 5)
        x_lo = max(0, int(min(x0, x1) - hw - 2))
        x_hi = min(W - 1, int(max(x0, x1) + hw + 2))
        y_lo = max(0, int(min(y0, y1) - hw - 2))
        y_hi = min(H - 1, int(max(y0, y1) + hw + 2))
        for y in range(y_lo, y_hi + 1):
            for x in range(x_lo, x_hi + 1):
                if _seg_dist(x + 0.5, y + 0.5, x0, y0, x1, y1) <= hw:
                    img[y][x] = col

    # 4) 量程端点标记（琥珀色小三角，位于 SWEEP_MIN / SWEEP_MAX 外侧）
    for ang in (SWEEP_MIN, SWEEP_MAX):
        rad = math.radians(ang)
        ux, uy = math.sin(rad), -math.cos(rad)
        x0, y0 = c + ux * (R_TICK_O + 0.5) * SUPERSAMPLE, c + uy * (R_TICK_O + 0.5) * SUPERSAMPLE
        x1, y1 = c + ux * (R_TICK_O + 2.5) * SUPERSAMPLE, c + uy * (R_TICK_O + 2.5) * SUPERSAMPLE
        hw = 1.4 * SUPERSAMPLE
        x_lo = max(0, int(min(x0, x1) - hw - 2)); x_hi = min(W - 1, int(max(x0, x1) + hw + 2))
        y_lo = max(0, int(min(y0, y1) - hw - 2)); y_hi = min(H - 1, int(max(y0, y1) + hw + 2))
        for y in range(y_lo, y_hi + 1):
            for x in range(x_lo, x_hi + 1):
                if _seg_dist(x + 0.5, y + 0.5, x0, y0, x1, y1) <= hw:
                    img[y][x] = 8

    # 5) 中心轴
    for y in range(H):
        dy = y + 0.5 - c
        for x in range(W):
            dx = x + 0.5 - c
            if math.hypot(dx, dy) <= r_hub:
                img[y][x] = 7

    return W, H, img


def downsample(W, H, img, factor):
    """多数表决降采样，平局时取优先级高的颜色（刻度 > 外圈 > 盘面）"""
    priority = {0: 0, 2: 1, 1: 2, 3: 3, 5: 4, 4: 5, 8: 6, 6: 7, 7: 8}
    ow, oh = W // factor, H // factor
    out = [[0] * ow for _ in range(oh)]
    for oy in range(oh):
        for ox in range(ow):
            cnt = {}
            for sy in range(factor):
                for sx in range(factor):
                    cc = img[oy * factor + sy][ox * factor + sx]
                    cnt[cc] = cnt.get(cc, 0) + 1
            best, best_n, best_p = 0, -1, -1
            for cc, n in cnt.items():
                p = priority.get(cc, 0)
                if n > best_n or (n == best_n and p > best_p):
                    best, best_n, best_p = cc, n, p
            out[oy][ox] = best
    return out


# ============================================================================
# 指针几何（与 RTL 一致，仅用于预览）
# ============================================================================
NEEDLE_LEN   = 72       # 显示像素
NEEDLE_TAIL  = 12
NEEDLE_HW    = 5        # 根部半宽（显示像素）
NEEDLE_HW_TIP= 1


def needle_hit(u, w):
    """u: 沿指针方向距中心距离；w: 垂直方向偏移。均在“显示像素”尺度"""
    if u < -NEEDLE_TAIL or u > NEEDLE_LEN:
        return 0
    if u >= 0:
        lim = NEEDLE_HW * (NEEDLE_LEN - u) // NEEDLE_LEN + 1
    else:
        lim = (NEEDLE_HW * (u + NEEDLE_TAIL)) // NEEDLE_TAIL + 1
    if abs(w) > lim:
        return 0
    return 1 if abs(w) <= 1 else 2     # 1=白色芯，2=红色体


# ============================================================================
# BMP 输出
# ============================================================================
def write_bmp(path, w, h, pixel_rows):
    """pixel_rows: 自上而下，每行 w 个 (r,g,b)，取值 0..255"""
    rowsize = (w * 3 + 3) & ~3
    pad = rowsize - w * 3
    data = bytearray()
    for y in range(h - 1, -1, -1):
        for (r, g, b) in pixel_rows[y]:
            data += bytes((b, g, r))
        data += b"\0" * pad
    filesize = 54 + len(data)
    hdr = b"BM" + struct.pack("<IHHI", filesize, 0, 0, 54)
    dib = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(data), 2835, 2835, 0, 0)
    with open(path, "wb") as f:
        f.write(hdr + dib + bytes(data))


def pal8(idx):
    """4bit 调色板 -> 8bit RGB"""
    if idx not in DIAL_PALETTE:
        return (0, 0, 0)
    r, g, b = DIAL_PALETTE[idx]
    return (r * 17, g * 17, b * 17)


def make_preview(dial):
    """表盘 + 8 个角度的指针，横向拼成一张大图"""
    scale = 2
    n_ang = 8
    tw = DIAL_SRC * scale
    W, H = tw * n_ang, tw
    rows = [[(0, 0, 0)] * W for _ in range(H)]
    cx = cy = DIAL_C * scale         # 源图中心（以 96x96 为单位）
    cdisp = (DIAL_SRC / 2.0) * scale  # 92.x 附近
    for k in range(n_ang):
        ang = SWEEP_MIN + (SWEEP_MAX - SWEEP_MIN) * k / (n_ang - 1)
        rad = math.radians(ang)
        ux, uy = math.sin(rad), -math.cos(rad)
        ox = k * tw
        for y in range(H):
            for x in range(tw):
                sx, sy = x // scale, y // scale
                base = dial[sy][sx]
                # 指针：以显示像素为单位
                ddx = x - (tw - 1) / 2.0
                ddy = y - (H - 1) / 2.0
                u = ddx * ux + ddy * uy
                w = -ddx * uy + ddy * ux
                nh = needle_hit(u, w)
                if nh == 1:
                    col = (255, 255, 255)
                elif nh == 2:
                    col = (255, 40, 20)
                elif base == 0:
                    col = (8, 10, 14)
                else:
                    col = pal8(base)
                rows[y][ox + x] = col
    return W, H, rows


def make_font_preview():
    scale = 3
    cols = 13
    cell_w, cell_h = 8 * scale, 10 * scale
    n = len(CHARSET)
    rows_n = (n + cols - 1) // cols
    W, H = cols * cell_w, rows_n * cell_h
    rows = [[(10, 12, 18)] * W for _ in range(H)]
    for i, gc in enumerate(CHARSET):
        gx = (i % cols) * cell_w + 4
        gy = (i // cols) * cell_h + 6
        for r in range(7):
            for c in range(5):
                if FONT[gc][r][c] == '#':
                    for dy in range(scale):
                        for dx in range(scale):
                            yy, xx = gy + r * scale + dy, gx + c * scale + dx
                            if 0 <= yy < H and 0 <= xx < W:
                                rows[yy][xx] = (230, 235, 240)
    return W, H, rows


# ============================================================================
# 汉字点阵（16x16）
# ============================================================================
# 【CJK_CHARS 的顺序就是 RTL 里的字节编码，一个都不能乱】
#   汉字字节 = 0x80 + 索引，索引 = CJK_CHARS 里的下标。
#   例如 CJK_CHARS[0] = '压' -> hud_panel.v 里写 8'h80。
#   hud_label.v 里 ch[7]==1 表示"这一格是汉字"，ch[6:0] 就是索引。
#
#   这份表和 src/hud/hud_panel.v 的字符串表必须严格一致。手写两份必然会漂，
#   所以下面 check_cjk_usage() 会在生成前【逐行对拍】hud_panel.v：
#   每一行汉字字节后面的注释里开头的连续汉字，必须正好是那几个字节对应的字。
#   顺序写反（把 储气罐 写成 罐气储）、改字忘了改字节、字节数对不上，都会当场报错。
CJK_CHARS = ("压力容器监控三表总览放大温度液位待机巡检故障储气罐报警趋势量程"
             "系统正常全部参数安超限过低高设备停或")
CJK_BASE = 0x80          # 第一个汉字的字节编码
CJK_CELL = 16            # 点阵边长
CJK_SS   = 4             # 超采样倍数（见 ttf2bmp.py；SimSun 有内嵌点阵，实际用不上）
CJK_THRESH = 0.40        # 覆盖率二值化阈值；0.40~0.50 结果一致，0.30 会粘连

# hud_panel.v 里被当作汉字字节的编码范围（8'h80 .. 8'hBF）
_CJK_CODE_MIN = 0x80
_CJK_CODE_MAX = 0xBF
_RE_HEXBYTE = re.compile(r"8'h([0-9A-Fa-f]{2})")
_RE_CJK_RUN = re.compile(u"[一-鿿]+")


def check_cjk_usage(verbose=True):
    """
    扫描 src/hud 下所有 .v，核对汉字字节编码。

    做两件事：
      A) 范围检查：任何出现在 8'h80..8'hBF 里的编码都必须是合法索引
         （否则 hud_rom_cjk 会被读出界，屏幕上是随机噪声，而且综合不报错）。
      B) 对拍检查：每个"汉字字节串"后面的注释里开头的连续汉字，必须正好
         对应那串字节。这是唯一能自动发现"顺序写反"和"索引错位"的手段。

    返回 True/False，False 时调用方必须中止（不要写出坏 ROM）。
    """
    n = len(CJK_CHARS)
    errors = []
    warnings = []
    matched_lines = 0

    for name in sorted(os.listdir(HUD_DIR)):
        if not name.endswith(".v"):
            continue
        path = os.path.join(HUD_DIR, name)
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        # 按行收集事件，再让"注释里的词"去认领前面最近的一串待匹配字节。
        # 这样跨行的拼接（字节在前一行、注释在后一行）也能对上。
        #
        # 只有 hud_panel.v 有汉字字节常量，对拍只对它做。别的文件里满篇
        # 中文注释（"右边界" "调用者" ...），逐行拿去对拍只会刷屏，
        # 它们只参与下面的范围检查。
        pending = []      # [(line_no, [code, ...]), ...]
        do_words = (name == "hud_panel.v")

        for ln, raw in enumerate(lines, 1):
            codes = [int(m, 16) for m in _RE_HEXBYTE.findall(raw)
                     if _CJK_CODE_MIN <= int(m, 16) <= _CJK_CODE_MAX]

            # --- A) 范围检查（所有文件）---
            for c in codes:
                if c >= CJK_BASE + n:
                    errors.append("%s:%d 汉字字节 8'h%02X 超出字库范围 "
                                  "(合法 0x%02X..0x%02X)"
                                  % (name, ln, c, CJK_BASE, CJK_BASE + n - 1))
            if not do_words:
                continue

            if codes:
                pending.append((ln, codes))

            # --- B) 对拍（只 hud_panel.v）---
            # 注释文本【原样】取，只 lstrip 空格/Tab（不剥 '-'），
            # 这样 "// ---- 顶栏标题：xxx" 这种说明性注释开头不是汉字，直接跳过，
            # 不会被误当成"词"。真正的表项写成 "// 压力超限 4+1+13=18"。
            ci = raw.find("//")
            if ci < 0:
                continue
            txt = raw[ci + 2:].lstrip(" \t")
            m = _RE_CJK_RUN.match(txt)
            if not m:
                continue
            word = m.group(0)
            if len(word) < 2:
                continue

            hit = None
            for i in range(len(pending) - 1, -1, -1):
                if len(pending[i][1]) == len(word):
                    hit = i
                    break
            if hit is None:
                continue          # 说明性注释，正常
            bln, cs = pending.pop(hit)
            # 越界的编码上面已经记过错了，这里不能再拿它去索引字库（会 IndexError）
            if any(c < CJK_BASE or c >= CJK_BASE + n for c in cs):
                continue
            expect = "".join(CJK_CHARS[c - CJK_BASE] for c in cs)
            if expect != word:
                # 行号报【字节那一行】，那才是要改的地方
                errors.append("%s:%d 字节 %s 解出来是「%s」，但第 %d 行的注释写的是「%s」"
                              % (name, bln,
                                 " ".join("8'h%02X" % c for c in cs), expect, ln, word))
            else:
                matched_lines += 1

        # hud_panel.v 里没被注释认领的字节串：不算错，但列出来，
        # 好知道哪些行还没被对拍覆盖到（想全覆盖就给它补个中文注释词）。
        for ln, cs in pending:
            if len(cs) >= 2:
                warnings.append("%s:%d 字节串 %s 没有中文注释，未参与对拍"
                                % (name, ln, " ".join("8'h%02X" % c for c in cs)))

    if verbose:
        print("      字库 %d 字 (0x%02X..0x%02X)，字节表对拍通过 %d 行"
              % (n, CJK_BASE, CJK_BASE + n - 1, matched_lines))
        for w in warnings:
            print("      [提示] %s" % w)
    for e in errors:
        print("      [错误] %s" % e)
    return not errors


def gen_cjk_verilog(glyphs):
    path = os.path.join(HUD_DIR, "hud_rom_cjk.v")
    n = len(CJK_CHARS)
    total = n * CJK_CELL

    # 地址 = {code, row} = code*16 + row，一个字 16 行
    words = []
    for ch in CJK_CHARS:
        g = glyphs[ch]
        for r in range(CJK_CELL):
            v = 0
            for c in range(CJK_CELL):
                if g[r][c]:
                    v |= (1 << (CJK_CELL - 1 - c))   # bit15 = 最左一列
            words.append(v)
    gen_mem(os.path.join(ROOT, "hud_rom_cjk.mem"), words, CJK_CELL)

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        emit_header(f, "hud_rom_cjk.v",
                    "%d 个汉字 x %d 行的 16x16 点阵 ROM（1bit/像素，bit15 = 最左一列）"
                    % (n, CJK_CELL))
        f.write("// 字样板来源：SimSun(宋体) 的 16px 内嵌点阵，由 tools/ttf2bmp.py 提取。\n")
        f.write("// 索引表（索引 = 下面的下标，字节编码 = 0x%02X + 索引）：\n" % CJK_BASE)
        per = 10
        for base in range(0, n, per):
            chunk = "".join("%2d=%-3s" % (i, CJK_CHARS[i])
                            for i in range(base, min(base + per, n)))
            f.write("//   %s\n" % chunk.rstrip())
        f.write("//\n")
        f.write("// ★ 别给这个 ROM 的输出再加一级寄存器 ★\n")
        f.write("//   hud_rom_font 是组合逻辑，hud_rom_cjk 是同步 BSRAM。\n")
        f.write("//   hud_overlay.v 用 f_* 那一级（R2）同时接住两者的输出，\n")
        f.write("//   专门把两条路的流水线级数凑成一样。硬加一级会让汉字整体右移一列。\n")
        f.write("\n")
        f.write("module hud_rom_cjk(\n")
        f.write("    input  wire        clk,\n")
        f.write("    input  wire [6:0]  code,     // 汉字索引 0..%d\n" % (n - 1))
        f.write("    input  wire [3:0]  row,      // 行 0..%d\n" % (CJK_CELL - 1))
        f.write("    output reg  [15:0] bits      // 16 个像素，bit15 在最左\n")
        f.write(");\n")
        f.write("    reg [15:0] mem [0:%d];\n\n" % (total - 1))
        f.write("    // 无复位、单口同步读（和 hud_rom_dial / hud_rom_sincos 同一模板）。\n")
        f.write("    // 加复位或加第二个读口都会把它从 BSRAM 变成一千多个 LUT。\n")
        f.write("    // 若综合器不认 initial 初始化 BSRAM，把下面整段换成：\n")
        f.write("    //   initial $readmemh(\"hud_rom_cjk.mem\", mem);\n")
        f.write("    // （工程根目录下的 hud_rom_cjk.mem 就是同一份数据）\n")
        f.write("    initial begin\n")
        per_line = 16
        for base in range(0, total, per_line):
            chunk = []
            for i in range(base, min(base + per_line, total)):
                chunk.append("mem[%d]=16'h%04X;" % (i, words[i]))
            f.write("        " + " ".join(chunk) + "\n")
        f.write("    end\n\n")
        f.write("    always @(posedge clk) bits <= mem[{code, row}];\n")
        f.write("endmodule\n")
    return path


def make_cjk_preview(glyphs):
    """汉字点阵预览 PNG —— 本工程不跑仿真，这是唯一能替代仿真的自检手段"""
    path = os.path.join(PHOTO_DIR, "hud_cjk_preview.png")
    chars = list(CJK_CHARS)
    W, H, rn = ttf2bmp.preview_png(path, glyphs, chars,
                                   cell=CJK_CELL, scale=4, cols=10)
    return path, W, H, rn


# ============================================================================
# Verilog 输出
# ============================================================================
def emit_header(f, title, desc):
    f.write("// ============================================================================\n")
    f.write("// %s\n" % title)
    f.write("// %s\n" % desc)
    f.write("// 本文件由 tools/gen_hud_assets.py 自动生成，请勿手工修改！\n")
    f.write("// ============================================================================\n\n")


def gen_mem(path, values, width):
    """同时导出一份 .mem，万一综合器对 initial 初始化 BSRAM 不认账可以改用 $readmemh"""
    hexw = (width + 3) // 4
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for v in values:
            f.write("%0*X\n" % (hexw, v & ((1 << width) - 1)))


def gen_dial_verilog(dial):
    path = os.path.join(HUD_DIR, "hud_rom_dial.v")
    n = DIAL_SRC * DIAL_SRC
    flat = [dial[i // DIAL_SRC][i % DIAL_SRC] for i in range(n)]
    gen_mem(os.path.join(ROOT, "hud_rom_dial.mem"), flat, 4)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        emit_header(f, "hud_rom_dial.v", "%dx%d 表盘静态底图 ROM（4bit 调色板，硬件 2x 放大 -> %d 见方）"
                    % (DIAL_SRC, DIAL_SRC, DIAL_SRC * 2))
        f.write("module hud_rom_dial(\n")
        f.write("    input  wire        clk,\n")
        f.write("    input  wire [13:0] addr,      // 0 .. %d\n" % (n - 1))
        f.write("    output reg  [3:0]  dout\n")
        f.write(");\n")
        f.write("    reg [3:0] mem [0:%d];\n\n" % (n - 1))
        f.write("    // 若综合器不认 initial 初始化 BSRAM，把下面整段换成：\n")
        f.write("    //   initial $readmemh(\"hud_rom_dial.mem\", mem);\n")
        f.write("    // （工程根目录下的 hud_rom_dial.mem 就是同一份数据）\n")
        f.write("    initial begin\n")
        per_line = 16
        for base in range(0, n, per_line):
            chunk = []
            for i in range(base, min(base + per_line, n)):
                chunk.append("mem[%d]=4'h%X;" % (i, flat[i]))
            f.write("        " + " ".join(chunk) + "\n")
        f.write("    end\n\n")
        f.write("    always @(posedge clk) dout <= mem[addr];\n")
        f.write("endmodule\n")
    return path


def gen_font_verilog():
    path = os.path.join(HUD_DIR, "hud_rom_font.v")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        emit_header(f, "hud_rom_font.v", "5x7 ASCII 字库 ROM（组合逻辑，字符编码见 hud_defs.vh）")
        f.write("module hud_rom_font(\n")
        f.write("    input  wire [5:0] code,     // 字符编码 0..%d\n" % (len(CHARSET) - 1))
        f.write("    input  wire [2:0] row,      // 行 0..7 (第 7 行为空白)\n")
        f.write("    output reg  [4:0] bits      // 5 个像素，bit4 在最左\n")
        f.write(");\n")
        f.write("    wire [8:0] addr = {code, row};\n\n")
        f.write("    always @(*) begin\n")
        f.write("        case (addr)\n")
        for i, ch in enumerate(CHARSET):
            for r in range(8):
                if r < 7:
                    v = 0
                    for c in range(5):
                        if FONT[ch][r][c] == '#':
                            v |= (1 << (4 - c))
                else:
                    v = 0
                f.write("            9'd%d: bits = 5'b%s;  // '%s'\n"
                        % (i * 8 + r, format(v, "05b"), ch))
        f.write("            default: bits = 5'b00000;\n")
        f.write("        endcase\n")
        f.write("    end\n")
        f.write("endmodule\n")
    return path


def gen_sincos_verilog():
    """1024 点，24bit：低 12 位 = sin，高 12 位 = cos，Q1.11（范围 -2048..2047）"""
    path = os.path.join(HUD_DIR, "hud_rom_sincos.v")
    N = 1024
    data = []
    for i in range(N):
        s = int(round(math.sin(2 * math.pi * i / N) * 2047))
        c = int(round(math.cos(2 * math.pi * i / N) * 2047))
        s = max(-2048, min(2047, s))
        c = max(-2048, min(2047, c))
        data.append(((c & 0xFFF) << 12) | (s & 0xFFF))
    gen_mem(os.path.join(ROOT, "hud_rom_sincos.mem"), data, 24)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        emit_header(f, "hud_rom_sincos.v",
                    "1024 点 sin/cos 查表 ROM，Q1.11；低 12bit=sin，高 12bit=cos，单口同步读")
        f.write("module hud_rom_sincos(\n")
        f.write("    input  wire        clk,\n")
        f.write("    input  wire [9:0]  addr,     // 角度索引 0..1023  => 0..360 度\n")
        f.write("    output reg  [11:0] o_sin,\n")
        f.write("    output reg  [11:0] o_cos\n")
        f.write(");\n")
        f.write("    reg [23:0] mem [0:%d];\n\n" % (N - 1))
        f.write("    // 若综合器不认 initial 初始化 BSRAM，把下面整段换成：\n")
        f.write("    //   initial $readmemh(\"hud_rom_sincos.mem\", mem);\n")
        f.write("    initial begin\n")
        per_line = 8
        for base in range(0, N, per_line):
            chunk = []
            for i in range(base, min(base + per_line, N)):
                chunk.append("mem[%d]=24'h%06X;" % (i, data[i]))
            f.write("        " + " ".join(chunk) + "\n")
        f.write("    end\n\n")
        f.write("    always @(posedge clk) begin\n")
        f.write("        o_sin <= mem[addr][11:0];\n")
        f.write("        o_cos <= mem[addr][23:12];\n")
        f.write("    end\n")
        f.write("endmodule\n")
    return path


# ============================================================================
def main():
    os.makedirs(HUD_DIR, exist_ok=True)
    os.makedirs(PHOTO_DIR, exist_ok=True)

    # ★ 先做一致性检查，过了才写文件 ★
    #   字库索引和 hud_panel.v 的字节表对不上，综合不会报错，
    #   屏幕上只是"字不对/顺序乱"，上板才发现就太晚了。
    print("[0/5] 核对 hud_panel.v 的汉字字节表 ...")
    if not check_cjk_usage():
        print("汉字字节表和字库对不上，已中止，未写出任何 ROM。")
        return 1

    print("[1/5] 渲染表盘底图 (%dx%d, %dx 超采样)..." % (DIAL_SRC, DIAL_SRC, SUPERSAMPLE))
    W, H, hi = render_dial_hires()
    dial = downsample(W, H, hi, SUPERSAMPLE)

    print("[2/5] 生成 hud_rom_dial.v ...")
    p1 = gen_dial_verilog(dial)
    print("      -> %s" % p1)

    print("[3/5] 生成 hud_rom_font.v / hud_rom_sincos.v ...")
    p2 = gen_font_verilog()
    p3 = gen_sincos_verilog()
    print("      -> %s" % p2)
    print("      -> %s" % p3)

    print("[4/5] 提取汉字点阵 (%d 字 x %dx%d, SimSun 16px 内嵌点阵) 并生成 hud_rom_cjk.v ..."
          % (len(CJK_CHARS), CJK_CELL, CJK_CELL))
    try:
        glyphs, font_name = ttf2bmp.get_glyphs(CJK_CHARS, cell=CJK_CELL,
                                               thresh_ratio=CJK_THRESH, verbose=True)
    except Exception as e:
        print("      汉字点阵提取失败：%s" % e)
        print("      这一路只能在 Windows 上跑（ctypes 调 GDI）。已中止。")
        return 1
    missing = [c for c in CJK_CHARS if c not in glyphs]
    if missing:
        print("      字体 %s 缺字：%s —— 已中止，绝不静默出空格"
              % (font_name, "".join(missing)))
        return 1
    p4 = gen_cjk_verilog(glyphs)
    print("      -> %s" % p4)

    if "--no-preview" not in sys.argv:
        print("[5/5] 输出预览图 ...")
        pw, ph, rows = make_preview(dial)
        write_bmp(os.path.join(PHOTO_DIR, "hud_dial_preview.bmp"), pw, ph, rows)
        fw, fh, frows = make_font_preview()
        write_bmp(os.path.join(PHOTO_DIR, "hud_font_preview.bmp"), fw, fh, frows)
        cpath, cw, chh, crn = make_cjk_preview(glyphs)
        print("      -> photo/hud_dial_preview.bmp")
        print("      -> photo/hud_font_preview.bmp")
        print("      -> %s  (%dx%d, %d 行)" % (cpath, cw, chh, crn))
        print("      ★ 汉字预览图请【逐字看过】再综合 ★")
    else:
        print("[5/5] 跳过预览图")

    print("完成。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
