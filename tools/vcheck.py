# -*- coding: utf-8 -*-
"""
vcheck.py -- 用 pyverilog 对所有 RTL 源文件做一次【纯语法】检查。

为什么需要它：
  这个工程不跑仿真（iverilog 没装），唯一的验证手段是"改完 → TD 综合 → 上板"。
  TD 一次综合要几分钟，而一个少写的 endcase 会让整轮白跑。
  这里用 pyverilog（纯 Python 的 Verilog-2001 前端）在几秒内把语法错误挑出来。

它【只查语法】，不查位宽、不查时序、不查悬空端口 —— 那些还是得上 TD。

用法：
    python tools/vcheck.py            # 检查 src/ 下全部 .v
    python tools/vcheck.py src/hud    # 只查某个目录/文件
"""

import os
import sys

try:
    # ★ 用裸解析器 VerilogParser，不用 VerilogCodeParser ★
    #   VerilogCodeParser 会先调外部预处理器的可执行文件（iverilog -E），
    #   这台机器上没有 iverilog，直接 WinError 2。
    #   本工程的源文件只用到了 `timescale 这一条编译指令，没有
    #   `include / `define / `ifdef，所以在下面手工剥掉它再喂给裸解析器就够了。
    from pyverilog.vparser.parser import VerilogParser
except ImportError:
    print("!! 需要 pyverilog:  pip install pyverilog")
    sys.exit(2)

import re
import tempfile


def collect(paths):
    out = []
    for p in paths:
        if os.path.isfile(p) and p.endswith(".v"):
            out.append(p)
        elif os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in sorted(files):
                    if f.endswith(".v"):
                        out.append(os.path.join(root, f))
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, ".."))

    args = sys.argv[1:]
    if args:
        targets = args
    else:
        targets = [os.path.join(root, "src")]

    files = collect(targets)
    if not files:
        print("没有找到 .v 文件")
        return 1

    # 解析器的中间产物写到临时目录，不要在工程里撒文件
    tmp = tempfile.mkdtemp(prefix="vcheck_")

    directive_re = re.compile(r"^\s*`(timescale|celldefine|endcelldefine|resetall|default_nettype)\b.*$",
                              re.MULTILINE)

    bad = []
    for path in files:
        rel = os.path.relpath(path, root)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            print("  ??  %-44s 读不了: %s" % (rel, e))
            bad.append(rel)
            continue

        # 剥掉认识的编译指令；剩下不认识的（`include / `define / `ifdef …）
        # 单独报出来，不然会被解析器当成语法错误，指错方向。
        strippable = ("timescale", "celldefine", "endcelldefine",
                      "resetall", "default_nettype")
        leftover = [d for d in re.findall(r"^\s*`(\w+)", text, re.MULTILINE)
                    if d not in strippable]
        text = directive_re.sub("", text)

        try:
            VerilogParser(outputdir=tmp, debug=False).parse(text, debug=False)
            if leftover:
                print("  !!  %s  （含未剥除的编译指令: %s）"
                      % (rel, ", ".join(sorted(set(x.strip() for x in leftover)))))
                bad.append(rel)
            else:
                print("  OK  %s" % rel)
        except Exception as e:
            bad.append(rel)
            # pyverilog 的报错里通常带着行号，原样打出来最有用
            print("  **  %s" % rel)
            for line in str(e).splitlines():
                print("        %s" % line)

    print()
    print("共 %d 个文件，%d 个有问题" % (len(files), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
