# -*- coding: utf-8 -*-
"""
patch_run_prj.py -- 把新增的 HUD 源文件同步进 TD 各 run 目录的 pic_sdram.prj

【为什么需要这个脚本】
TD 的批处理流程执行的是 `open_project pic_sdram.prj` —— 读的是 run 目录
(syn_1/ / phy_1/) 里的 .prj，【不是】工程根目录的 pic_sdram.al。

.prj 是 IDE 每次启动流程时从 .al 生成的。如果流程一直是从 IDE 跑的，
只改 .al 就够了；但若是直接跑 run.bat 批处理，.prj 不会重新生成，
新文件就永远进不去 —— 现象是 elaborate 报
    HDL-7144 CRITICAL-WARNING: instantiate unknown module xxx
    HDL-8007 ERROR: xxx is a black box
而 TD 不把这些当致命错误，照样跑完 bitgen，烧到板子上就是旧功能。

【幂等】逐文件检查 Path，已在就跳过；不碰 .al。
【备份】第一次修改前写 <prj>.bak。
"""
import io
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AL = os.path.join(ROOT, "pic_sdram.al")

# 需要同步进 .prj 的文件（相对工程根目录，与 .al 里的写法一致）
#
# 【压力容器重构】新增 4 个：
#   hud_rom_cjk.v     中文字库（由 tools/gen_hud_assets.py 生成，不是手写的）
#   sd_arbiter.v      单扇区仲裁器：读图 / 音频流 共用 sd_card_top
#   audio_sd_reader.v 按"起始扇区 + 字节数"把音频片段读进 FIFO
#   audio_fifo.v      16bit 样本缓冲（写侧 sd_card_clk / 读侧 audio_mclk）
#
# ★ 这 4 个文件必须和 pic_sdram.al 里的 <File> 块【同时】存在 ★
#   本脚本是从 .al 里抽块再插进 .prj 的，.al 里没有就直接报错退出。
#   正确顺序：① 改 .al（TD 必须关着）② 跑本脚本 ③ 再跑 TD 批处理。
NEW_FILES = [
    "src/hud/hud_switches.v",
    "src/hud/hud_trend.v",
    "src/hud/hud_seg_data.v",
    "src/seg_disp_top.v",
    "src/buzzer_beep.v",
    "src/hud/hud_rom_cjk.v",
    "src/sd_arbiter.v",
    "src/audio_sd_reader.v",
    "src/audio_fifo.v",
]

PRJ_LIST = [
    os.path.join(ROOT, "pic_sdram_Runs", "syn_1", "pic_sdram.prj"),
    os.path.join(ROOT, "pic_sdram_Runs", "phy_1", "pic_sdram.prj"),
]


def read(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()


def write(p, txt):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(txt)


def main():
    if not os.path.isfile(AL):
        sys.exit("!! 找不到 %s" % AL)
    al = read(AL)

    # ---- 1. 从 .al 抽出这 5 个 <File> 块 ----
    blocks = []
    for rel in NEW_FILES:
        pat = r'[ \t]*<File Path="%s">.*?</File>\n' % re.escape(rel)
        m = re.search(pat, al, re.S)
        if not m:
            sys.exit("!! pic_sdram.al 里找不到 <File Path=\"%s\">，先跑 patch_td_project.py" % rel)
        blk = m.group(0)
        # run 目录在工程根目录下两级，路径要加 ../../ 前缀
        blk = blk.replace('Path="%s"' % rel, 'Path="../../%s"' % rel, 1)
        blocks.append(blk)
    print("从 .al 抽出 %d 个 File 块" % len(blocks))

    # ---- 2. 逐个 .prj 插入 ----
    rc = 0
    for prj in PRJ_LIST:
        if not os.path.isfile(prj):
            print("-- %s 不存在，跳过" % prj)
            continue

        txt = read(prj)
        todo = [b for b, rel in zip(blocks, NEW_FILES)
                if ('Path="../../%s"' % rel) not in txt]
        if not todo:
            print("-- %s 已经有了，跳过（File 条目 %d）"
                  % (prj, len(re.findall(r'<File Path=', txt))))
            continue

        if "</Verilog>" not in txt:
            print("!! %s 里找不到 </Verilog>，跳过" % prj)
            rc = 1
            continue

        before = len(re.findall(r'<File Path=', txt))
        if not os.path.isfile(prj + ".bak"):
            shutil.copy2(prj, prj + ".bak")
            print("   备份 -> %s.bak" % prj)

        txt = txt.replace("        </Verilog>",
                          "".join(todo) + "        </Verilog>", 1)
        write(prj, txt)
        after = len(re.findall(r'<File Path=', txt))
        print("++ %s: 插入 %d 个，File 条目 %d -> %d"
              % (prj, len(todo), before, after))

    print()
    print("完成。接下来按顺序跑：syn_1/run.bat 再 phy_1/run.bat")
    return rc


if __name__ == "__main__":
    sys.exit(main())
