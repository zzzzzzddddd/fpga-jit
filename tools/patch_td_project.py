# -*- coding: utf-8 -*-
"""
patch_td_project.py -- 把 HUD 源码文件补进安路 TD 工程文件（pic_sdram.al）

什么时候需要跑：
  * 第一次拿到这份代码时（正常情况下我已经帮你补好了，脚本会说"已存在"）
  * **TD 开着的时候被改过 .al**：TD 关闭时会用自己的内存内容覆盖 .al，
    我加的 HUD 条目就没了。这时先关掉 TD，再跑一次这个脚本即可。

用法：
    python tools/patch_td_project.py                 # 默认补 pic_sdram.al
    python tools/patch_td_project.py 别的工程.al

脚本会先把原文件备份成 <工程>.al.bak，再写回（UTF-8 无 BOM，与原文件一致）。
重复跑是安全的：按【单个文件】判断，已经加过的跳过、缺哪个补哪个，不会重复插入。
（早先版本用整个列表的第一个文件当哨兵，新加的文件会被静默丢弃，已改掉。）
"""

import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 顺序不影响综合（TD 自己解析模块依赖），CompileOrder 接在现有最大值后面
HUD_FILES = [
    "src/hud/hud_rom_dial.v",
    "src/hud/hud_rom_font.v",
    "src/hud/hud_rom_sincos.v",
    "src/hud/hud_xy_gen.v",
    "src/hud/hud_label.v",
    "src/hud/hud_gauge.v",
    "src/hud/hud_panel.v",
    "src/hud/hud_keys.v",
    "src/hud/hud_switches.v",
    "src/hud/hud_trend.v",
    "src/hud/hud_seg_data.v",
    "src/hud/hud_data_gen.v",
    "src/hud/hud_overlay.v",
    "src/hud/hud_top.v",
    "src/seg_disp_top.v",
    "src/buzzer_beep.v",
]

TEMPLATE = """            <File Path="{path}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="{order}"/>
                </FileInfo>
            </File>
"""


def main():
    al_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "pic_sdram.al")

    if not os.path.isfile(al_path):
        print("找不到工程文件：%s" % al_path)
        return 1

    with open(al_path, "r", encoding="utf-8") as f:
        txt = f.read()

    # 先检查源文件是否真的都在
    missing = [p for p in HUD_FILES
               if not os.path.isfile(os.path.join(ROOT, p))]
    if missing:
        print("工程目录下缺这些文件，先确认代码是完整的：")
        for p in missing:
            print("   %s" % p)
        return 1

    # 【逐文件检查，不要用整体哨兵】
    # 曾经的写法是 `if "hud_rom_dial.v" in txt: return 0`，那是个整体判据：
    # hud_rom_dial.v 早就已经在工程里了，后来新增的文件（hud_switches /
    # hud_trend / hud_seg_data / seg_disp_top / buzzer_beep）会被这一句
    # 静默丢掉 —— TD 层次里没有它们，hud_top 就变成黑盒，整条 HUD 链报废。
    # 所以只跳过"路径已经出现过"的那些，缺哪个补哪个。
    todo = [p for p in HUD_FILES if ('File Path="%s"' % p) not in txt]
    if not todo:
        print("这 %d 个文件工程里都有了，不用再加。（%s）"
              % (len(HUD_FILES), os.path.basename(al_path)))
        return 0

    if "</Verilog>" not in txt:
        print("这个 .al 里找不到 </Verilog>，格式和预期不一样，我没敢动。")
        return 1

    # 接着现有 CompileOrder 的最大值往下排
    orders = [int(m) for m in re.findall(r'CompileOrder"\s+Val="(\d+)"', txt)]
    order = max(orders) + 10 if orders else 100

    block = ""
    for p in todo:
        block += TEMPLATE.format(path=p, order=order)
        order += 1

    txt = txt.replace("        </Verilog>", block + "        </Verilog>", 1)

    shutil.copyfile(al_path, al_path + ".bak")
    with open(al_path, "w", encoding="utf-8", newline="") as f:
        f.write(txt)

    print("已把 %d 个文件加进 %s：" % (len(todo), al_path))
    for p in todo:
        print("   + %s" % p)
    print("原文件备份在 %s.bak" % al_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
