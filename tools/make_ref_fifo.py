# -*- coding: utf-8 -*-
"""
make_ref_fifo.py -- 从当前的 frame_fifo_write.v 生成一份"改回原样"的参考模块
                     （模块名改成 frame_fifo_write_ref），用于 A/B 等价性对比。

只做三件事：改模块名、去掉 wr_remain、把 into_burst 换回原来的表达式。
别的都不动，保证参考模块和改动前的源码等价。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "src", "frame_fifo_write.v")
DST = os.path.join(ROOT, "sim", "ref_frame_fifo_write.v")

t = open(SRC, encoding="utf-8").read()

# 1) 改模块名
assert "module frame_fifo_write\n" in t
t = t.replace("module frame_fifo_write\n", "module frame_fifo_write_ref\n", 1)

# 2) 去掉 wr_remain 的声明
decl_start = t.index("// 本帧还差多少字没写")
decl_end = t.index("reg [ADDR_BITS - 1:0]               wr_remain;") + \
           len("reg [ADDR_BITS - 1:0]               wr_remain;") + 1
t = t[:decl_start] + t[decl_end:]

# 3) into_burst 换回原来的表达式
new_start = t.index("// ---------------------------------------------------------------------------\n// into_burst：")
# 整段替换到那一行末尾（含行尾那个"当rd在突发时不会进入burst"注释），别只切到分号
marker = "assign into_burst = ((enough || rdusedw > BURST_SIZE) && ~App_rd_busy);"
new_end = t.index(marker) + len(marker)
new_end = t.index("\n", new_end) + 1
orig = ("wire into_burst;\n"
        "assign into_burst = (((write_len_latch <= (rdusedw + write_cnt))"
        "||rdusedw > BURST_SIZE) && ~App_rd_busy);//当rd在突发时不会进入burst\n")
t = t[:new_start] + orig + t[new_end:]

# 4) 去掉三处 wr_remain 赋值
for line in [
    "\t\twr_remain <= ZERO[ADDR_BITS - 1:0];\n",
    "\t\t\t\t// wr_remain 必须跟着 write_cnt 一起归位，保持 = write_len_latch - write_cnt：\n"
    "\t\t\t\t//   write_req_d2==1 时 write_len_latch 会被更新成 write_len_d1\n"
    "\t\t\t\t//   write_req_d2==0 时 write_len_latch 不变\n"
    "\t\t\t\twr_remain <= (write_req_d2 == 1'b1) ? write_len_d1 : write_len_latch;\n",
    "\t\t\t\t\t// 余量同步递减，必须与 write_cnt 同拍更新\n"
    "\t\t\t\t\twr_remain <= wr_remain - BURST_SIZE[ADDR_BITS - 1:0];\n",
]:
    if line not in t:
        print("!! 没找到要删的片段：%r" % line[:60])
    t = t.replace(line, "", 1)

assert "wr_remain" not in t, "还有 wr_remain 残留"

os.makedirs(os.path.dirname(DST), exist_ok=True)
open(DST, "w", encoding="utf-8", newline="\n").write(t)
print("已生成参考模块: %s" % DST)
