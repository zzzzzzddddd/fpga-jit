#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
unexclude_src.py -- 把一个源文件的 `AutoExcluded` 去掉，让 TD 真的编译它。

【为什么需要它】
  TD 的 .al / .prj 里每个源文件有一个 `<Attr Name="AutoExcluded" Val="true"/>`。
  带这个属性的文件**根本不进 elaborate**。于是例化它的时候报的是一对
  【看起来不致命】的消息：

      HDL-7144 CRITICAL-WARNING: instantiate unknown module xxx
      HDL-8007 ERROR: xxx is a black box

  ★★★ 最要命的一点：TD **不把 HDL-8007 当致命错误**，照样一路跑完
       place/route/bitgen，日志尾部一切正常、bit 文件也照样生成。
      烧到板子上跑的是【旧功能】，而且不看编译日志根本发现不了。★★★
  ⇒ 判据：每次综合完，除了扫 ERROR，**还要专门扫
       `HDL-8007` / `is a black box` / `instantiate unknown module`**。

  反过来，文件如果**已经在 .al 里但被 AutoExcluded**（本工程里的
  `audio_gen.v` / `sin_lut.v` / `ax_debounce.v` 就是），
  `tools/patch_run_prj.py` 帮不上忙 —— 它的逻辑是"Path 已在就跳过"。

【本工程这一次的由来】
  第二十二版测试音固件复用 `audio_gen.v`（它早就在 .al/.prj 里），
  结果撞上这个坑。去掉这两个文件的 AutoExcluded 即可。

【用法】
  python tools/unexclude_src.py --check audio_gen.v sin_lut.v
  python tools/unexclude_src.py audio_gen.v sin_lut.v
  python tools/unexclude_src.py --restore audio_gen.v sin_lut.v

  会同时改三处：pic_sdram.al、syn_1/pic_sdram.prj、phy_1/pic_sdram.prj。
  第一次改动前自动备份为 <文件>.unexcl.bak。
"""
import argparse
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS = [
    os.path.join(ROOT, "pic_sdram.al"),
    os.path.join(ROOT, "pic_sdram_Runs", "syn_1", "pic_sdram.prj"),
    os.path.join(ROOT, "pic_sdram_Runs", "phy_1", "pic_sdram.prj"),
]

# 一个 <File Path="...xxx.v"> 后面紧跟 <FileInfo> 再跟 AutoExcluded 的块
BLOCK = re.compile(
    r'(<File\s+Path="[^"]*?(?P<base>[\w.]+\.v)">\s*\n'
    r'\s*<FileInfo>\s*\n)'
    r'(?P<attr>\s*<Attr\s+Name="AutoExcluded"\s+Val="true"/>\s*\n)'
)


def process(path, names, check, restore):
    if not os.path.isfile(path):
        return [("MISSING", path, "")]
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    orig = text
    hits = []

    def sub(m):
        base = m.group("base")
        if base not in names:
            return m.group(0)
        hits.append(base)
        head = m.group(1)
        if restore:
            # 没有备份就用推断：AutoExcluded 是第一个属性，放回它
            return head + '                    <Attr Name="AutoExcluded" Val="true"/>\n'
        return head   # 去掉那一行

    if check:
        for m in BLOCK.finditer(text):
            if m.group("base") in names:
                hits.append(m.group("base"))
        return [("WOULD-UNEXCLUDE", path, b) for b in hits]

    text = BLOCK.sub(sub, text)
    if text == orig:
        return [("NOCHANGE", path, b) for b in hits] or [("NOCHANGE", path, "")]

    bak = path + ".unexcl.bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return [("RESTORED" if restore else "UNEXCLUDED", path, b) for b in hits]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+", help="要处理的源文件名（如 audio_gen.v）")
    ap.add_argument("--check", action="store_true", help="只报告不改")
    ap.add_argument("--restore", action="store_true", help="把 AutoExcluded 加回去")
    a = ap.parse_args()

    names = set(a.files)
    total = 0
    for t in TARGETS:
        for act, path, base in process(t, names, a.check, a.restore):
            rel = os.path.relpath(path, ROOT)
            print("  %-16s %-44s %s" % (act, rel, base))
            total += 1

    print()
    if a.check:
        print("（--check 模式，没有改动任何文件）")
    else:
        print("★ 改完必须重新跑综合，并【专门扫一遍】日志里的")
        print("  HDL-8007 / is a black box / instantiate unknown module")
        print("  —— 这几条 TD 不当致命错误，会把旧功能烧进板子。")
    return 0 if total else 1


if __name__ == "__main__":
    sys.exit(main())
