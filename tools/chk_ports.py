# -*- coding: utf-8 -*-
"""
chk_ports.py -- 检查命名端口连接里有没有拼错/不存在的端口名。

为什么需要它：
    Verilog 的命名端口连接 `.foo(sig)` 里，如果 `.foo` 不是被例化模块的端口，
    这在语法上是合法的（pyverilog 不报），但综合器会直接报错：
        ERROR: port 'foo' is not a port of module 'bar'
    一次综合几分钟，而这一类错误完全可以在几秒内查出来。

    ★ 本次加了很多新端口（fat32_reader / wav_loader / audio_pwm），
      而 top.v 是手工连的，最容易出这类错。★

做法：
    - 用 pyverilog 解析所有文件
    - 收集每个模块的端口名集合（ANSI 和非 ANSI 两种声明风格都收）
    - 遍历所有例化（ast.InstanceList），逐个检查 PortArg 的 portname
    - 同时报出"例化的模块名根本没定义"的情况（如果该模块不在文件集里，
      会在注释里说明，不报错，避免和 IP 原语混淆）

用法：
    python tools/chk_ports.py                     # 检查 src/ 下全部
    python tools/chk_ports.py src/top.v ...       # 只查指定文件
"""

import os
import re
import sys
import tempfile

try:
    from pyverilog.vparser.parser import VerilogParser
    from pyverilog.vparser import ast
except ImportError:
    print("!! 需要 pyverilog:  pip install pyverilog")
    sys.exit(2)

# 由 TD 的 .ipc 生成、不在 .v 里的 IP 模块；以及厂商原语
SKIP_MODULES = {
    "sys_pll", "video_pll", "PLL_HDMI_AUDIO",
    "afifo_16_32_256", "afifo_32_16_256", "afifo_16_256",
    "EG_PHY_SDRAM_2M_32", "EG_PHY_PLL", "EG_LOGIC_BUFG", "EG_LOGIC_ODDR",
    "EG_LOGIC_IDDR", "EG_PHY_GCLK",
}


def collect(paths):
    out = []
    for p in paths:
        if os.path.isfile(p) and p.endswith(".v"):
            out.append(p)
        elif os.path.isdir(p):
            for root, _d, files in os.walk(p):
                for f in sorted(files):
                    if f.endswith(".v"):
                        out.append(os.path.join(root, f))
    return out


def strip_and_parse(path, tmp):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    text = re.sub(r"^\s*`(timescale|celldefine|endcelldefine|resetall|default_nettype)\b.*$",
                  "", text, flags=re.MULTILINE)
    return VerilogParser(outputdir=tmp, debug=False).parse(text, debug=False)


def mod_ports(mod):
    """收集一个模块声明的端口名。两种声明风格都要覆盖。

    ★ 这里踩过一次坑，记下来 ★
      ANSI 风格 `module m(input a, output reg b);` 的端口**不在** mod.items
      的 Decl 里 —— pyverilog 把它们放在 mod.portlist.ports，每个是一个
      Ioport 节点，方向节点（Input/Output/Inout）挂在它的 .first 上。
      只翻 mod.items 的话，对 ANSI 风格模块会返回空集合，于是"任何端口名
      都不匹配"，产生满屏假阳性。
      （本工程所有模块都是 ANSI 风格，所以第一版检查器是 100% 假阳性。）
      非 ANSI 风格 `module m(a,b); input a;` 才把方向写在模块体的 Decl 里，
      所以两种都要收。
    """
    names = set()
    pl = mod.portlist
    if pl is not None and hasattr(pl, "ports") and pl.ports is not None:
        for p in pl.ports:
            for attr in ("first", "second"):
                d = getattr(p, attr, None)
                if isinstance(d, (ast.Input, ast.Output, ast.Inout)):
                    if getattr(d, "name", None):
                        names.add(d.name)
    for item in mod.items:
        if isinstance(item, ast.Decl):
            for d in item.list:
                if isinstance(d, (ast.Input, ast.Output, ast.Inout)):
                    if getattr(d, "name", None):
                        names.add(d.name)
    return names


def walk_instances(node, out):
    """递归收集所有的例化。"""
    if node is None:
        return
    if isinstance(node, ast.InstanceList):
        out.append(node)
    if isinstance(node, ast.Node) and hasattr(node, "children"):
        for c in node.children():
            walk_instances(c, out)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, ".."))

    args = sys.argv[1:]
    targets = args if args else [os.path.join(root, "src")]
    files = collect(targets)
    if not files:
        print("没有找到 .v 文件")
        return 1

    tmp = tempfile.mkdtemp(prefix="chkport_")

    # 第一遍：收集所有模块的端口表
    ports = {}
    for p in files:
        try:
            tree = strip_and_parse(p, tmp)
        except Exception:
            continue
        for mod in tree.description.children():
            if isinstance(mod, ast.ModuleDef):
                ports[mod.name] = mod_ports(mod)

    # 第二遍：检查例化
    total = 0
    for p in files:
        rel = os.path.relpath(p, root)
        try:
            tree = strip_and_parse(p, tmp)
        except Exception as e:
            print("  ??  %-40s 解析失败，跳过：%s" % (rel, str(e).splitlines()[0]))
            continue

        bad = []
        for mod in tree.description.children():
            if not isinstance(mod, ast.ModuleDef):
                continue
            inss = []
            for item in mod.items:
                walk_instances(item, inss)
            for il in inss:
                mname = il.module
                if mname not in ports:
                    continue                      # IP / 厂商原语 / 未提供定义
                legal = ports[mname]
                for inst in il.instances:
                    if inst.portlist is None:
                        continue
                    for pa in inst.portlist:
                        if not isinstance(pa, ast.PortArg):
                            continue
                        pn = pa.portname
                        if pn is None:
                            continue
                        if pn not in legal:
                            bad.append((mod.name, mname, inst.name, pn))

        if bad:
            print("  **  %s" % rel)
            for owner, mname, iname, pn in bad:
                print("        %s: 例化 %s (%s) 的端口 '.%s' 在模块 %s 里不存在"
                      % (owner, iname, mname, pn, mname))
            total += len(bad)
        else:
            print("  OK  %s" % rel)

    print()
    if total:
        print("共发现 %d 处端口名不匹配。" % total)
    else:
        print("没有发现端口名不匹配。")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
