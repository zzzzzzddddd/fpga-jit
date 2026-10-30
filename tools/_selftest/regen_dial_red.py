# -*- coding: utf-8 -*-
"""
regen_dial_red.py  --  只重生成 hud_rom_dial.v 的红区角度

为什么只做表盘
--------------
红区（超限区）是【烤进底图】的，不是 RTL 画的。原来的 RED_MIN = 88.0°
对应扫角 -125..+125 里的 85.2% 量程，而压力(>120/160)和温度(>95，量程 20..120)
的报警点都在 **75%**，低于红区起点 ⇒ 报警时指针停在红区【外面】
（上板反馈"进入警报界面指针不一定在红色部分"）。

改 RED_MIN = 62.5°（= 75% 量程）让红区起点正好落在压力/温度的报警点上。

为什么【不】直接跑 gen_hud_assets.py
------------------------------------
那个脚本还会顺带重生成 hud_rom_cjk.v（走 Windows GDI 取字体点阵）。
字体一旦不同，屏幕上的中文就会变 —— 那不是这次要动的东西。
这里只调它的表盘那三个函数。

用法
----
  python tools/_selftest/regen_dial_red.py --check     # 只核对：确定性能否复现现有文件
  python tools/_selftest/regen_dial_red.py --write     # 用新的 RED_MIN 重写表盘
"""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import gen_hud_assets as g                                    # noqa: E402

CUR_DIAL = os.path.join(ROOT, "src", "hud", "hud_rom_dial.v")

OLD_RED_MIN = 88.0        # 现状（= 85.2% 量程，照"液位高 >85%"画的）
NEW_RED_MIN = 62.5        # = 扫角 -125..+125 的 75% ⇒ 压力/温度报警点


def gen_into(tmpdir, red_min):
    """用指定的 RED_MIN 生成一份 hud_rom_dial.v 到 tmpdir，返回路径"""
    g.RED_MIN  = red_min
    g.HUD_DIR  = tmpdir
    g.ROOT     = tmpdir
    W, H, hi   = g.render_dial_hires()
    dial       = g.downsample(W, H, hi, g.SUPERSAMPLE)
    return g.gen_dial_verilog(dial)


def main():
    mode = "--write" if "--write" in sys.argv else "--check"

    with open(CUR_DIAL, "r", encoding="utf-8", newline="") as f:
        cur = f.read()

    with tempfile.TemporaryDirectory() as tmp:
        p = gen_into(tmp, OLD_RED_MIN)
        with open(p, "r", encoding="utf-8", newline="") as f:
            same = f.read()

    if same != cur:
        print("!! 生成器【不能】逐字节复现现有表盘 —— 不要往下做，先查清差异")
        for i, (a, b) in enumerate(zip(cur.splitlines(), same.splitlines())):
            if a != b:
                print("   第一处不同在第 %d 行:" % (i + 1))
                print("     现有: %s" % a[:100])
                print("     重算: %s" % b[:100])
                break
        print("   (现有 %d 行, 重算 %d 行)" % (len(cur.splitlines()), len(same.splitlines())))
        return 1

    print("OK  RED_MIN=%.1f 能逐字节复现现有表盘 ⇒ 生成器是确定性的，可以安全重写"
          % OLD_RED_MIN)

    if mode != "--write":
        print("    (--check 模式，没有写文件。要真正重写请加 --write)")
        return 0

    # 真正重写：用真实的 HUD_DIR / ROOT
    g.HUD_DIR = os.path.join(ROOT, "src", "hud")
    g.ROOT    = ROOT
    g.RED_MIN = NEW_RED_MIN
    W, H, hi  = g.render_dial_hires()
    dial      = g.downsample(W, H, hi, g.SUPERSAMPLE)
    out       = g.gen_dial_verilog(dial)
    print("已重写 %s（RED_MIN %.1f -> %.1f）" % (out, OLD_RED_MIN, NEW_RED_MIN))

    with open(out, "r", encoding="utf-8", newline="") as f:
        new = f.read()
    # 只统计"变了多少个像素"，确认改动范围就在红区那一段弧上
    n = 0
    for a, b in zip(cur.splitlines(), new.splitlines()):
        if a != b:
            n += 1
    print("   与原文件相比有 %d 行不同（共 %d 行）" % (n, len(cur.splitlines())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
