# -*- coding: utf-8 -*-
"""逐字节比对两份 .bit，判断差异是"逻辑不同"还是"只是元数据"。

用法：
    python tools/_selftest/cmp_bit.py <A.bit> <B.bit>
不传参数时用下面两个默认路径。
"""
import sys

_DEF_A = r"D:\fpga_anlu\C_1\C_1\pic_sdram_Runs\archive\pic_sdram_v31_wobble_seed6.bit"
_DEF_B = r"D:\fpga_anlu\C_1\C_1\pic_sdram_Runs\phy_1\pic_sdram.bit"

A = sys.argv[1] if len(sys.argv) > 2 else _DEF_A
B = sys.argv[2] if len(sys.argv) > 2 else _DEF_B

a = open(A, "rb").read()
b = open(B, "rb").read()
print("v31 存档 %d B  重建 %d B" % (len(a), len(b)))
if len(a) != len(b):
    print("长度不同 => 不是同一份布局，一定要查")
    sys.exit(1)

d = [i for i in range(len(a)) if a[i] != b[i]]
print("不同字节数 = %d / %d  (%.4f%%)" % (len(d), len(a), 100.0 * len(d) / len(a)))
if not d:
    print("完全相同")
    sys.exit(0)

print("第一个不同 offset = %d (0x%X)" % (d[0], d[0]))
print("最后一个不同 offset = %d (0x%X)" % (d[-1], d[-1]))

runs = []
s = d[0]
p = d[0]
for i in d[1:]:
    if i != p + 1:
        runs.append((s, p))
        s = i
    p = i
runs.append((s, p))
print("差异区段数 = %d" % len(runs))
for (s, e) in runs[:15]:
    print("   [%d..%d]  共 %d 字节" % (s, e, e - s + 1))

print()
print("头部 192 字节（非可打印显示为 .）:")
for tag, x in (("v31 ", a), ("重建", b)):
    s = "".join(chr(c) if 32 <= c < 127 else "." for c in x[:192])
    print("  %s: %s" % (tag, s))
