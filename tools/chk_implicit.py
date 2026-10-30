# -*- coding: utf-8 -*-
"""
chk_implicit.py -- 检查"隐式线网"：信号在声明之前就被用了，或者根本没声明。

为什么需要它：
    Verilog 允许"先用后声明"，但那样会**自动建出一个 1 位宽的隐式线网**。
    如果后面又写了 `wire [31:0] sig;`，就是重复声明，TD 报：

        CRITICAL-WARNING: 'sig' is already implicitly declared on line N

    真正危险的不是这条警告本身，而是【宽度】：
      - `bmp_xl_lba` 这种 32 位信号，隐式线网只有 1 位 —— 高 31 位全丢。
      - 1 位信号宽度上碰巧一样，所以现象可能"看起来正常"，
        换个信号就坏了，很难查。
    这次就是 top.v 里把 7 个 wire 的声明放在了例化之后，TD 一次报了 9 条警告。

    前面三个检查器都查不到这一类：
      vcheck.py      语法（隐式线网在语法上完全合法）
      chk_drivers.py 多驱动 / assign 到 reg
      chk_ports.py   端口名是否存在（名字是对的，只是声明位置不对）
      chk_keywords.py 关键字误用

判据（保守）：
    只看命名端口连接 `.port(sig)` 里那个裸的 sig（要求括号里就是单个标识符，
    所以 `.bmp_width(16'd640)` 这种常量不会被算进来）。
    对每个 sig：
      - 在这个模块范围内找不到任何带声明关键字（input/output/inout/wire/reg）
        且含这个名字的行  -> 报"未声明"
      - 最早的那一行在用法之后 -> 报"先用后声明"
    只看 .port() 里的信号，是因为这一类占了实际踩坑的绝大多数，
    而且误报率最低（不会把表达式、模块名、实例名算进来）。

用法：
    python tools/chk_implicit.py                 # 扫 src/ 下全部
    python tools/chk_implicit.py src/top.v       # 只查指定文件
"""

import os
import re
import sys

# 声明关键字。parameter/localparam 也要算 —— 它们虽然不是线网，但
# `#(.CLK_DIV(CLK_DIV))` 这种把参数名当实参传下去的写法很常见，
# 不收进来的话会误报成"未声明"。
DECL_KW = r"(?:input|output|inout|wire|reg|integer|genvar|parameter|localparam)"

# 找"这一行是不是声明行"用的（不要求出现在行首，这样才能覆盖
# `module t(input clk, output reg q);` 这种端口写在同一行的写法）
DECL_KW_RE = re.compile(r"\b" + DECL_KW + r"\b")

# 关键字本身和常见类型词，收集名字时要跳过
SKIP_NAMES = re.compile(
    r"^(?:input|output|inout|wire|reg|integer|genvar|parameter|localparam|"
    r"signed|unsigned)$")

# .portname(sig)  —— 括号里必须【只有】一个标识符，才当作信号连接
CONN_RE = re.compile(r"\.\s*([A-Za-z_]\w*)\s*\(\s*([A-Za-z_]\w*)\s*\)")

MOD_START = re.compile(r"^\s*module\b")
MOD_END = re.compile(r"^\s*endmodule\b")


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


def strip_comments_keep_lines(text):
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    text = re.sub(r"/\*.*?\*/", blank, text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", blank, text)
    return text


def find_param_ranges(text):
    """找出所有 `#( ... )` 覆盖的行号区间。

    ★ 为什么要单独处理这个 ★
      参数覆盖 `#(.PHASE_INC(PHASE_INC))` 在字面上和端口连接
      `.port(sig)` 长得一模一样。不排除的话，参数透传会被误报成
      "这个信号没声明" —— 本工程里 hud_top / sd_card_top /
      frame_read_write / hdmi_phy_wrapper 全都有参数透传，
      不排除就是一片假阳性。
      做法：从每个 `#(` 起按括号配平找到配对的那个 `)`，把跨越的行都标记掉。
    """
    ranges = []
    for m in re.finditer(r"#\s*\(", text):
        start = m.start()
        depth = 0
        i = m.end() - 1
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        l0 = text.count("\n", 0, start) + 1
        l1 = text.count("\n", 0, i) + 1
        ranges.append((l0, l1))
    return ranges


def check_module(lines, mname, skip_lines):
    """lines 是 (行号, 内容) 的列表，范围是本模块。返回问题列表。

    skip_lines 是落在 `#( ... )` 参数覆盖列表里的行号集合。
    """
    # 1) 收集所有"声明行"：只要这一行里出现声明关键字就算
    decl_line_of = {}
    for ln, txt in lines:
        if not DECL_KW_RE.search(txt):
            continue
        # 先把 based literal（16'd123 / 8'hff）里的尾巴去掉，
        # 否则 16'd123 会被当成一个叫 d123 的标识符收进来
        t2 = re.sub(r"'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_]+", " ", txt)
        for m in re.finditer(r"\b([A-Za-z_]\w*)\b", t2):
            nm = m.group(1)
            if SKIP_NAMES.match(nm):
                continue
            if nm not in decl_line_of:
                decl_line_of[nm] = ln

    # 2) 检查每个 .port(sig)，跳过 #() 参数覆盖里的行
    problems = []
    for ln, txt in lines:
        if ln in skip_lines:
            continue
        for m in CONN_RE.finditer(txt):
            sig = m.group(2)
            if sig not in decl_line_of:
                problems.append((ln, sig, "未在本模块找到声明（会生成 1 位隐式线网）"))
            elif decl_line_of[sig] > ln:
                problems.append((ln, sig,
                                 "先用后声明：声明在第 %d 行（会先生成 1 位隐式线网）"
                                 % decl_line_of[sig]))
    return problems


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, ".."))

    args = sys.argv[1:]
    targets = args if args else [os.path.join(root, "src")]
    files = collect(targets)
    if not files:
        print("没有找到 .v 文件")
        return 1

    total = 0
    for path in files:
        rel = os.path.relpath(path, root)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                raw = f.read()
        except OSError as e:
            print("  ??  %-40s 读不了: %s" % (rel, e))
            continue

        text = strip_comments_keep_lines(raw)
        all_lines = list(enumerate(text.splitlines(), 1))

        # #( ... ) 参数覆盖占用的行 —— 这些行里的 .foo(bar) 是参数不是端口
        skip = set()
        for l0, l1 in find_param_ranges(text):
            for x in range(l0, l1 + 1):
                skip.add(x)

        # 按 module ... endmodule 切段
        probs = []
        i = 0
        while i < len(all_lines):
            if MOD_START.match(all_lines[i][1]):
                j = i
                while j < len(all_lines) and not MOD_END.match(all_lines[j][1]):
                    j += 1
                mname = re.match(r"^\s*module\s+([A-Za-z_]\w*)", all_lines[i][1])
                mname = mname.group(1) if mname else "?"
                for ln, sig, why in check_module(all_lines[i:j], mname, skip):
                    probs.append((mname, ln, sig, why))
                i = j
            i += 1

        if probs:
            print("  **  %s" % rel)
            for mname, ln, sig, why in probs:
                print("        %s:%d  '%s'  %s" % (mname, ln, sig, why))
            total += len(probs)
        else:
            print("  OK  %s" % rel)

    print()
    if total:
        print("共发现 %d 处隐式线网风险。" % total)
    else:
        print("没有发现隐式线网。")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
