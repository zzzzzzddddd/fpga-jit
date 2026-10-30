# -*- coding: utf-8 -*-
"""
check_label_len.py -- 数一数 RTL 里每条「标签字符串」到底有几个字节。

为什么需要：
  取字是 str[8*(LEN-1-k) +: 8]，字符串【左对齐】放在 wire 的高位，所以
      多写一个字节 -> 最高位被截掉，整行左移一格
      少写一个字节 -> 高位补 0，开头几格变成空白
  两种都不报错。pyverilog 不报（语法合法），TD 不报（只是常量），
  只有上板拿眼睛看才发现。所以这里用脚本逐条数。

它认得的表达式形状（本工程用到的那几种）：
  8'hXX                     -> 1 字节
  "ASCII"                   -> len(字符)  字节
  {a, b, {c, ...}}          -> 各分量相加（可嵌套）
  cond ? x : y              -> 各分支必须一样宽，否则报错
  另一个 S_xxx / V_xxx 名字 -> 查前面算过的表

用法：
    python tools/check_label_len.py                     # 默认查 src/hud
    python tools/check_label_len.py src/hud/hud_panel.v
"""

import os
import re
import sys

# 控制台默认是 cp936，中文提示会变成乱码
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SKIP = "<skip>"          # "这条不是字符串表"，不报错也不记宽度


# ----------------------------------------------------------------------
# 去掉注释。字符串里的 "//" 不是注释，所以必须一遍扫过去而不是用正则replace。
# ----------------------------------------------------------------------
def strip_comments(text):
    out = []
    i, n = 0, len(text)
    in_str = False
    in_block = False
    while i < n:
        c = text[i]
        if in_block:
            if text.startswith("*/", i):
                in_block = False
                i += 2
            else:
                i += 1
            continue
        if in_str:
            out.append(c)
            if c == '"':
                in_str = False
            elif c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            in_block = True
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


DECL_RE = re.compile(
    r"\bwire\s*\[\s*8\s*\*\s*(\d+)\s*-\s*1\s*:\s*0\s*\]\s*(\w+)\s*=")


def grab_expr(text, start):
    """从 '=' 之后开始，取到同层的 ';'（跳过字符串、花括号、圆括号）。"""
    depth = 0
    in_str = False
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
        elif c in "{([":
            depth += 1
        elif c in "})]":
            depth -= 1
        elif c == ";" and depth == 0:
            return text[start:i], i
        i += 1
    return text[start:], n


# ----------------------------------------------------------------------
# 表达式求值（返回字节数；None = 认不出来）
# ----------------------------------------------------------------------
NUM_RE = re.compile(r"^\s*(\d+)'\s*([hHdDbBoO])\s*([0-9A-Fa-fxXzZ_]+)\s*$")
STR_RE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*$')
IDENT_RE = re.compile(r"^\s*[A-Za-z_]\w*\s*$")


def split_top(expr, seps):
    """按 seps 里的字符在括号深度 0 处切分（不进字符串）。

    返回 [(片段, 分隔符), ...]，最后一段的分隔符是 ''。
    三目里"条件"和"结果"都是片段，靠分隔符区分：后面跟 '?' 的是条件，
    后面跟 ':' 或者什么都不跟的是结果 —— 不比条件，只比结果。
    """
    parts = []
    depth = 0
    in_str = False
    cur = []
    for c in expr:
        if in_str:
            cur.append(c)
            if c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
            cur.append(c)
        elif c in "{([":
            depth += 1
            cur.append(c)
        elif c in "})]":
            depth -= 1
            cur.append(c)
        elif c in seps and depth == 0:
            parts.append(("".join(cur), c))
            cur = []
        else:
            cur.append(c)
    parts.append(("".join(cur), ""))
    return parts


def eval_expr(expr, env):
    expr = expr.strip()
    if not expr:
        return None

    # ---- 三目：cond ? a : b（可能串成一条链）----
    if "?" in expr:
        # 先剥掉最外层的 { }，否则 {cond ? a : b} 里的 ? 被包在括号里
        inner = expr
        if inner.startswith("{") and inner.endswith("}"):
            inner = inner[1:-1]
        vals = []
        for piece, sep in split_top(inner, "?:"):
            if sep == "?" or not piece.strip():
                continue                       # 条件，或空段
            v = eval_expr(piece, env)
            if v == SKIP:
                return SKIP
            if v is None:
                return None
            if isinstance(v, tuple):
                return v
            vals.append(v)
        if not vals:
            return None
        if len(set(vals)) != 1:
            return ("MISMATCH", vals)
        return vals[0]

    # ---- 拼接 ----
    inner = expr
    if inner.startswith("{") and inner.endswith("}"):
        inner = inner[1:-1]
    items = [p for p, _sep in split_top(inner, ",") if p.strip()]
    total = 0
    for it in items:
        it = it.strip()
        # 函数调用（nib2asc(...) 之类）说明这条 wire 不是字符串表，整条跳过
        if re.match(r"^[A-Za-z_]\w*\s*\(", it):
            return SKIP
        m = STR_RE.match(it)
        if m:
            total += len(m.group(1))
            continue
        m = NUM_RE.match(it)
        if m:
            bits = int(m.group(1))
            base = m.group(2).lower()
            if base == "h":
                bits = bits
            elif base == "d":
                pass
            elif base == "b":
                pass
            elif base == "o":
                bits = bits * 3
            total += (bits + 7) // 8
            continue
        if it.startswith("{"):
            v = eval_expr(it, env)
            if v == SKIP:
                return SKIP
            if v is None:
                return None
            if isinstance(v, tuple):
                return v
            total += v
            continue
        m = IDENT_RE.match(it)
        if m:
            name = m.group(0).strip()
            if env.get(name) == SKIP:
                return SKIP
            if name in env:
                total += env[name]
                continue
        return None
    return total


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, ".."))

    args = sys.argv[1:]
    if args:
        files = [p for p in args if os.path.isfile(p)]
    else:
        d = os.path.join(root, "src", "hud")
        files = [os.path.join(d, f) for f in sorted(os.listdir(d))
                 if f.endswith(".v")]

    bad = 0
    total = 0
    for path in files:
        rel = os.path.relpath(path, root)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = strip_comments(f.read())

        env = {}
        for m in DECL_RE.finditer(text):
            want = int(m.group(1))
            name = m.group(2)
            expr, _ = grab_expr(text, m.end())
            got = eval_expr(expr, env)

            if got == SKIP:                     # 不是字符串表（比如 V_P 是编码转换）
                env[name] = SKIP
                continue

            total += 1
            if got is None:
                print("  ??  %-46s [8*%d-1:0] 认不出的表达式" % (rel + ":" + name, want))
                bad += 1
                continue
            if isinstance(got, tuple):          # 三目各分支宽度不一致
                print("  **  %-46s [8*%d-1:0] 三目分支宽度不一致: %s"
                      % (rel + ":" + name, want, got[1]))
                bad += 1
                continue
            env[name] = got
            if got != want:
                print("  **  %-46s 声明 %d 字节，实际 %d 字节  (%+d)"
                      % (rel + ":" + name, want, got, got - want))
                bad += 1

    print()
    print("共 %d 条字符串声明，%d 条有问题" % (total, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
