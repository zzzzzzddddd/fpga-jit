# -*- coding: utf-8 -*-
"""
chk_width.py -- 检查【拼接表达式的位宽】是否与左边对不上。

为什么需要它：
    本工程已经【第三次】栽在"Verilog 静默处理位宽"上了：
      (1) top.v  `reg [2:0] img_idx_s; img_idx_s <= {img_idx_s[1:0], img_idx_v};`
          右边 2+3=5 位塞进 3 位 ⇒ 丢高 2 位 ⇒ 它根本不是"3 级移位寄存器"，
          而等于 img_idx_v 本身 ⇒ 外面取 [1] 取到的是"第 1 位比特"。
      (2) top.v  `wire [15:0] diag_sd = {…, img_done_cnt};`
          img_done_cnt 只有 3 位而那一格该是 4 位 ⇒ 拼接只有 15 位
          ⇒ 赋给 [15:0] 时【高位补 0】⇒ 整条诊断总线【整体左移一位】。
          D2 本该读 6 却读成 'E'（= {dg_lvl[0], img_done_cnt}），看着像"功能没动"。
      (3) 同一族的还有"取某一位当某一级用"。

    工具对这两种写法都【不报错、不警告】，只表现为"值不对"——
    而这个工程没有仿真，唯一的验证手段是"改完 → TD 综合 → 上板"，
    一次上板要几分钟，所以必须在下板之前拦住。

能查什么（保守，宁可漏报不误报）：
    拼接（concatenation）的总宽与左值声明的位宽不等。左值可以是
        wire/reg 声明带初始化      wire [15:0] diag_sd = {…};
        assign 语句                assign bus = {…};
        过程赋值                   bus <= {…};
    逐项能算的就算：标识符、位选 x[7:0]、单比特 x[0]、定宽常量 4'd9/8'hFF、
    复制 {3{x}}；含运算符的表达式算不出来，整条跳过（不猜）。

查不出来的（明确记下，别以为它管）：
    - 非拼接的表达式位宽（`a <= b + c;` 这种要完整的位宽推导）
    - 位选越界、移位链的级数、参数化位宽（parameter 当位宽）
    - 拼接里混了算不出来的项 ⇒ 这一条整条跳过

用法：
    python tools/chk_width.py              # 扫 src/ 下全部 .v
    python tools/chk_width.py src/top.v    # 只查指定文件
"""

import os
import re
import sys

# 声明式关键字。用行首附近的这些词找位宽声明。
DECL_KW = r"(?:input|output|inout|wire|reg|integer)"

# `wire [15:0] foo` / `reg [2:0] bar, baz` / `wire foo` / `output reg [3:0] q`
# 捕获：1=位宽(可能空) 2=后面的一串名字
DECL_RE = re.compile(
    r"\b" + DECL_KW + r"\b\s*(?:reg\s+|wire\s+)*"      # wire / reg / output reg
    r"(\[\s*(\d+)\s*:\s*(\d+)\s*\])?"                  # 可选位宽
    r"\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*[;=,\)]",
)

# 标识符的可选位选：[msb:lsb] 或 [idx]
SEL_RE = re.compile(r"^\s*([A-Za-z_]\w*)\s*(\[\s*([^:\]]+)\s*(?::\s*([^\]]+))?\s*\])?\s*$")

# 定宽常量：4'd9 / 8'hFF / 1'b0 / 12'o77
LIT_RE = re.compile(r"^(\d+)\s*'\s*[bBoOdDhH]")

# 复制：{3{x}}  （只支持单层）
REP_RE = re.compile(r"^\s*(\d+)\s*\{\s*(.*?)\s*\}\s*$")

# 会出现的运算符 —— 见到就认为这条项算不出来
OPS = set("+-*/%&|^~!<>=?()")


def strip_comments(text):
    """去掉 // 和 /* */ 注释，同时把字符串常量挖掉（本工程几乎没有）。"""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    out = []
    for line in text.split("\n"):
        i = line.find("//")
        if i >= 0:
            line = line[:i]
        out.append(line)
    return "\n".join(out)


def collect_widths(text, table):
    """把 `wire [15:0] a, b;` 这类声明收进 table[name] = 位宽。"""
    for m in DECL_RE.finditer(text):
        width = None
        if m.group(1):
            msb, lsb = int(m.group(2)), int(m.group(3))
            width = abs(msb - lsb) + 1
        for name in m.group(4).split(","):
            name = name.strip()
            if not name:
                continue
            # 后声明覆盖前声明没意义；只在没有更确切的信息时才写
            if name not in table or width is not None:
                table[name] = width if width is not None else table.get(name, 1)
        # 没有位宽的默认 1 位（对 wire/reg 是准确的；input/output 同）


def split_top_level(s):
    """按顶层逗号切分拼接项（不切开 {} 里的）。"""
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


def item_width(item, table):
    """算一项的位宽；算不出来返回 None。"""
    item = item.strip()
    if not item:
        return None

    # 复制 {3{x}}
    m = REP_RE.match(item)
    if m:
        inner = item_width(m.group(2), table)
        return None if inner is None else int(m.group(1)) * inner

    # 定宽常量
    m = LIT_RE.match(item)
    if m:
        return int(m.group(1))

    # 纯十进制无位宽常量：Verilog 不允许出现在拼接里，真见了也算 32 位
    if re.match(r"^\d+$", item):
        return 32

    # 标识符 + 可选位选
    m = SEL_RE.match(item)
    if m:
        name, sel, a, b = m.group(1), m.group(2), m.group(3), m.group(4)
        if sel:
            if b is None:
                return 1                       # x[3]
            try:
                return abs(int(a) - int(b)) + 1  # x[7:0]
            except ValueError:
                return None
        # 整个标识符
        if name in table and table[name] is not None:
            return table[name]
        return None

    # 有运算符 ⇒ 不猜
    return None


def find_concat_assignments(text):
    """产出 (lhs, lhs_sel, rhs_concat, 行号)。"""
    # 先把 `=` 后面紧跟 `{` 的位置找出来，再配对右花括号
    for m in re.finditer(r"([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*(?:<=|=)\s*\{", text):
        start = m.end() - 1
        depth = 0
        end = None
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end is None:
            continue
        inner = text[start + 1:end]
        # 后面必须是 ; 或 逗号/换行结尾，避免把 `a = {…} + {…}` 也算进来
        tail = text[end + 1:end + 3]
        if not tail.lstrip().startswith(";"):
            continue
        line = text.count("\n", 0, m.start()) + 1
        yield m.group(1), m.group(2), inner, line


def check_file(path, rel, table):
    try:
        raw = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError as e:
        print("  ??  %s 打不开：%s" % (rel, e))
        return 0

    text = strip_comments(raw)
    collect_widths(text, table)

    bad = 0
    for lhs, lhs_sel, inner, line in find_concat_assignments(text):
        # 左值位宽
        if lhs_sel:
            try:
                a, b = lhs_sel.strip("[]").split(":")
                lhs_w = abs(int(a.strip()) - int(b.strip())) + 1
            except ValueError:
                continue
        else:
            lhs_w = table.get(lhs)
            if lhs_w is None:
                continue

        items = split_top_level(inner)
        widths = [item_width(it, table) for it in items]
        if any(w is None for w in widths):
            continue                     # 有算不出来的 ⇒ 整条跳过
        total = sum(widths)
        if total != lhs_w:
            print("  **  %s:%d" % (rel, line))
            print("        左边 %s 是 %d 位，右边拼接是 %d 位（%s）"
                  % (lhs, lhs_w, total,
                     " + ".join(str(w) for w in widths)))
            d = total - lhs_w
            if d > 0:
                print("        ⇒ 右边【宽 %d 位】，高 %d 位会被静默丢弃" % (d, d))
            else:
                print("        ⇒ 右边【窄 %d 位】，左边高位被静默补 0"
                      "（整条总线会整体左移 %d 位）" % (-d, -d))
            bad += 1
    return bad


def collect(paths):
    out = []
    for p in paths:
        if os.path.isfile(p) and p.endswith(".v"):
            out.append(p)
        elif os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in files:
                    if f.endswith(".v"):
                        out.append(os.path.join(root, f))
    return sorted(out)


def main():
    args = sys.argv[1:] or ["src"]
    root = os.getcwd()
    files = collect(args)
    total = 0
    for path in files:
        rel = os.path.relpath(path, root)
        table = {}
        n = check_file(path, rel, table)
        total += n
        if n == 0:
            print("  OK  %s" % rel)
    print("\n共 %d 个文件，%d 处位宽不匹配。" % (len(files), total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
