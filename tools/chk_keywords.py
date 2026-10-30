# -*- coding: utf-8 -*-
"""
chk_keywords.py -- 找出"把 Verilog 保留关键字当标识符用"的写法。

为什么需要它：
    Verilog-2001 里有一批关键字长得像普通变量名，最容易误用。
    写成 `reg [7:0] buf [0:1023];` 时 TD 报的是：

        ERROR: Verilog 2000 keyword 'buf' used in incorrect context

    而这**三个已有检查器全都查不出来**：
        vcheck.py      (pyverilog 裸解析器) —— 它接受 buf 当标识符
        chk_drivers.py (多驱动 / assign 到 reg)
        chk_ports.py   (端口名)
    这次就是在这个盲区上栽的：TD 先报 buf，分析失败，
    然后把这个文件连带标成 AutoExcluded，最后 top.v 引用它时报
    "模块不存在"。现象离根因隔了好几层。

哪些关键字要查：
    只查"很容易被当成变量名"的那批。像 always/begin/case/if 这些
    不可能被误用的不查，免得刷屏。
    门原语（buf/not/and/or/...）是重灾区 —— 它们没有任何视觉提示，
    看起来就是普通单词。

判据：
    去掉注释和字符串后，按词边界找这批关键字。命中了就报行号和整行，
    由人判断 —— 因为这个检查不做语法分析，宁可多报一点也不要漏。

用法：
    python tools/chk_keywords.py                # 扫 src/ 下全部
    python tools/chk_keywords.py src/foo.v      # 只查指定文件
"""

import os
import re
import sys

# 只收"看起来像普通单词"的关键字。门原语 + 少数几个类型/存储类词。
KEYWORDS = [
    # ---- 门原语（重灾区，完全没有视觉提示）----
    "buf", "not", "and", "or", "xor", "nand", "nor", "xnor",
    "bufif0", "bufif1", "notif0", "notif1",
    "pmos", "nmos", "cmos", "rcmos",
    "pullup", "pulldown",
    "tran", "tranif0", "tranif1", "rtran", "rtranif0", "rtranif1",
    "tri", "tri0", "tri1", "triand", "trior", "trireg",
    "wand", "wor", "supply0", "supply1",
    # ---- 容易被当成普通名词的 ----
    "time", "event", "edge", "table", "cell", "config", "design",
    "use", "instance", "liblist", "library", "macromodule",
    "primitive", "specparam", "specify", "endspecify",
    "small", "medium", "large", "scalared", "vectored",
    "automatic", "string",
]


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


def strip_comments(text):
    """把"不该参与扫描"的部分换成等长空格，保持行号不变。

    要剥三类：
      1. 注释            —— 里面出现什么词都不算
      2. 敏感列表 @(...) —— 里面的 or 是【事件分隔符】，是合法用法，
                            不剥的话每个 always 块都会刷一条假阳性
      3. $系统任务       —— $time / $display 里的 time 也是合法用法

    换成等长空格而不是删掉，是为了行号和列位置都不变，
    报出来的行号才对得上原文。
    """
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))

    text = re.sub(r"/\*.*?\*/", blank, text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", blank, text)
    # 敏感列表：@( ... )，只要没有嵌套括号就够（本工程的写法都是平的）
    text = re.sub(r"@\s*\([^()]*\)", blank, text)
    # 系统任务/函数：$time / $display(...) 等
    text = re.sub(r"\$[A-Za-z_]\w*", blank, text)
    return text


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, ".."))

    args = sys.argv[1:]
    targets = args if args else [os.path.join(root, "src")]
    files = collect(targets)
    if not files:
        print("没有找到 .v 文件")
        return 1

    pat = re.compile(r"\b(" + "|".join(KEYWORDS) + r")\b")

    total = 0
    for path in files:
        rel = os.path.relpath(path, root)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                raw = f.read()
        except OSError as e:
            print("  ??  %-40s 读不了: %s" % (rel, e))
            continue

        text = strip_comments(raw)
        hits = []
        for i, line in enumerate(text.splitlines(), 1):
            for m in pat.finditer(line):
                hits.append((i, m.group(1), line.strip()))

        if hits:
            print("  **  %s" % rel)
            for ln, kw, ln_txt in hits:
                print("        %4d  '%s'  |  %s" % (ln, kw, ln_txt))
            total += len(hits)
        else:
            print("  OK  %s" % rel)

    print()
    if total:
        print("共发现 %d 处关键字用作标识符的可疑写法。" % total)
        print("逐条看：如果那一行是在声明/赋值一个同名信号，就是真错误，必须改名。")
    else:
        print("没有发现关键字误用。")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
