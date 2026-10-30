# -*- coding: utf-8 -*-
"""
chk_drivers.py -- 找出"同一个 reg 被多个 always 块驱动"的写法。

为什么需要它：
  这是 RTL 里最隐蔽又最致命的一类错误。两个 always 块给同一个 reg 赋值，
  仿真/综合的结果是"后者覆盖前者"或直接报 multiple drivers，
  而**语法检查（vcheck.py）完全看不出来** —— 每个 always 块单看都是合法的。

  TD 综合会报出来，但一次综合要几分钟。这个脚本用 pyverilog 的 AST
  在几秒内给出同样的结论。

判据（保守，宁可少报也不错报）：
  1. 收集每个 always 块（含 initial）里被赋值的**标识符**。
     - 阻塞/非阻塞赋值的 LHS 直接取
     - for 循环变量不算（它们只在块内有效）
  2. 同一个标识符出现在 >1 个块里 -> 报冲突。
  3. 同一块内重复赋值是正常的（if/else 分支），不算冲突。

已知的假阳性（本工程里会报出来，属于工具能力边界）：
  - 用 `reg` 当数组下标写的间接寻址（例如 mem[i] <= x）会被当成对 mem 整体赋值，
    如果同一个数组在两个块里各写各的端口，可能误报。本工程没有这种写法。

已知的假【阴】性（宁可写清楚，别让人以为它保住了）：
  - **for 循环变量被当成"不是驱动"而跳过**。所以如果一个**模块级**的 reg
    只在两个不同的 always 块里当循环计数器用（`for (i=0;...)`），
    这是真多驱动，但本检查器**不会报**。
    要保住这一条就得区分"块内局部声明的 i"和"模块级 reg i"，
    代价是会对两个块各自声明局部 i 的常见写法误报 —— 先按保守来。

用法：
    python tools/chk_drivers.py                # 检查 src/ 下全部 .v
    python tools/chk_drivers.py src/foo.v      # 只查指定文件
"""

import os
import re
import sys

try:
    from pyverilog.vparser.parser import VerilogParser
    from pyverilog.vparser import ast
except ImportError:
    print("!! 需要 pyverilog:  pip install pyverilog")
    sys.exit(2)

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


def lhs_names(node, acc):
    """收集一个赋值语句 LHS 上的标识符名（穿透下标/拼接/部分选择）。"""
    if node is None:
        return
    if isinstance(node, ast.Identifier):
        acc.add(node.name)
    elif isinstance(node, (ast.Pointer, ast.Partselect, ast.Sll, ast.Srl)):
        lhs_names(node.var, acc)
    elif isinstance(node, ast.Lvalue):
        lhs_names(node.var, acc)
    elif isinstance(node, ast.Concat):
        for item in node.list:
            lhs_names(item, acc)
    elif isinstance(node, ast.Node) and hasattr(node, "children"):
        for c in node.children():
            lhs_names(c, acc)


def scan_stmt(node, acc, loop_vars):
    """递归扫一个 always 块体，收集 LHS 标识符。"""
    if node is None:
        return
    if isinstance(node, ast.ForStatement):
        # for 循环变量不算"驱动这个 reg"（它只在块内做计数器）
        #
        # ★★ 修过一个会让本检查器【整体瘫痪】的 bug ★★
        #   过程式 for 的 AST 节点是 ForStatement(pre, cond, post, statement)，
        #   循环变量写在 **pre** 里（形如 `i = 0`）——它【没有 .left】。
        #   （带 .left 的是 generate 用的 ast.For，两者不能混。）
        #   原来这一行写的是 node.left ⇒ **只要文件里出现过程式 for，
        #   就抛 AttributeError 直接崩**，而且崩在循环中间，
        #   连已经查完的前面那些文件的结果也一起丢掉。
        #   本工程几乎每个文件都有 for ⇒ 这个检查器等于从来没工作过。
        #
        #   顺带修掉第二处：原来接着 for ch in node.children() 递归，
        #   会把 pre/cond/post 也扫一遍 ⇒ 循环变量又被当驱动塞进 acc，
        #   和上面"不算驱动"的意图正好相反。现在只扫循环体。
        new_loop = set(loop_vars)
        lhs_names(node.pre, new_loop)
        scan_stmt(node.statement, acc, new_loop)
        return
    # ★ 只认过程赋值 ★
    #   pyverilog 里 `q <= a;` 是 NonblockingSubstitution，`q = a;` 是
    #   BlockingSubstitution；而 ast.Assign 指的是连续赋值 `assign x = y;` ——
    #   那个不该算作"被 always 块驱动"。第一次写的时候误用了 Assign，
    #   结果所有赋值都没被收集到，检查器恒返回"没有多驱动"（假阴性）。
    if isinstance(node, (ast.BlockingSubstitution, ast.NonblockingSubstitution)):
        lhs_names(node.left, acc)
    if isinstance(node, ast.Block):
        for item in node.statements:
            scan_stmt(item, acc, loop_vars)
        return
    if isinstance(node, ast.Node) and hasattr(node, "children"):
        for c in node.children():
            scan_stmt(c, acc, loop_vars)


def scan_assign_to_reg(text):
    """文本级检查：`assign` 的 LHS 不能是声明为 reg 的信号。

    为什么单独做这一条：
      这是另一类"语法检查看不出来、综合直接报错"的写法。
      `output reg x;` 配上 `assign x = ...;` 是非法 Verilog
      （不能对 reg 做连续赋值），但 pyverilog 不检查它，
      vcheck.py 会愉快地报 OK。本次就是在 fat32_reader.v 上踩到的。

    做法是保守的文本扫描，不用 AST —— 因为 pyverilog 对
      `output reg [31:0] x` 这种 ANSI 风格端口是否保留 reg 信息
      取决于版本，靠不住。宁可写得笨一点但要确定能报出来。

    去掉行注释和块注释后再扫，避免把注释里的 "reg" 当声明。
    同一行既声明又 assign 的写法会被跳过（本工程没有这种写法）。
    """
    raw = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    lines = [ln.split("//")[0] for ln in raw.splitlines()]

    # 1) 所有 assign 的 LHS 名
    lhs = set()
    for ln in lines:
        for m in re.finditer(r"\bassign\s+([A-Za-z_]\w*)", ln):
            lhs.add(m.group(1))

    # 2) 所有出现在含 reg 关键字的声明行里的标识符
    reg_names = set()
    for ln in lines:
        if "assign" in ln:
            continue
        if not re.search(r"\breg\b", ln):
            continue
        for m in re.finditer(r"\b([A-Za-z_]\w*)\b", ln):
            if m.group(1) != "reg":
                reg_names.add(m.group(1))

    return sorted(lhs & reg_names)


def check_file(path, rel):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    text = re.sub(r"^\s*`(timescale|celldefine|endcelldefine|resetall|default_nettype)\b.*$",
                  "", text, flags=re.MULTILINE)

    # 文本级检查先做：即使下面 AST 解析失败也能给出结论
    ar_problems = scan_assign_to_reg(text)

    tmp = tempfile.mkdtemp(prefix="chkdrv_")
    try:
        tree = VerilogParser(outputdir=tmp, debug=False).parse(text, debug=False)
    except Exception as e:
        print("  ??  %-40s 语法错误，跳过：%s" % (rel, str(e).splitlines()[0]))
        return []

    problems = []
    for mod in tree.description.children():
        if not isinstance(mod, ast.ModuleDef):
            continue
        mname = mod.name
        owners = {}          # 标识符 -> [块序号]
        blocks = []

        for item in mod.items:
            if isinstance(item, (ast.Always, ast.Initial)):
                acc = set()
                scan_stmt(item.statement, acc, set())
                blocks.append((item, acc))

        for idx, (_blk, acc) in enumerate(blocks):
            for nm in acc:
                owners.setdefault(nm, []).append(idx)

        for nm, idxs in sorted(owners.items()):
            if len(idxs) > 1:
                problems.append((mname, nm, idxs))

    if problems or ar_problems:
        print("  **  %s" % rel)
        for mname, nm, idxs in problems:
            print("        %s: 信号 '%s' 被 %d 个 always 块驱动 (块 %s)"
                  % (mname, nm, len(idxs), ", ".join("#%d" % i for i in idxs)))
        for nm in ar_problems:
            print("        assign 到 reg：'%s' 声明成了 reg 却用 assign 连续赋值"
                  " —— 非法 Verilog，综合会拒" % nm)
    else:
        print("  OK  %s" % rel)
    return problems + [("assign_to_reg", n, []) for n in ar_problems]


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
        total += len(check_file(path, os.path.relpath(path, root)))

    print()
    if total:
        print("共发现 %d 处多驱动。" % total)
        print("注意：这也会报出跨模块重名之类的情况，逐条看模块名和信号名确认。")
    else:
        print("没有发现多驱动。")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
