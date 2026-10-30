# -*- coding: utf-8 -*-
"""
sim_mbr_parse.py —— 把 fat32_reader.v 里 MBR 分区表解析那段的
                   【逐字节、非阻塞赋值】语义原样搬到 Python 里跑一遍。

为什么值得单独做：
    那段代码的错误是"顺序上"的（4 个分区项互相覆盖），
    静态检查器（vcheck/chk_drivers/chk_ports/chk_keywords/chk_implicit）
    全部抓不到，上板又只能看到一个最终值 —— 中间怎么覆盖的看不见。
    写成模型之后，可以直接喂一张合成 MBR，把"改前 / 改后"的
    part_start 摆在一起比。

建模要点（必须和 Verilog 对齐，否则结论没意义）：
    * bcnt 就是扇区里的字节序号 0..511，与 fat_valid 同拍前进。
    * pt_idx 在每一项的最后一个字节（base+15）之后才前进 ——
      所以 bcnt 落在 base..base+15 范围内时，base 全程用【同一个】pt_idx。
    * 非阻塞赋值：本拍读到的是【上一拍写下的】this_ok / pt_hit。
      this_ok 在 base+0 被清、在 base+4 被写，所以到 base+8 读它时
      已经是 base+4 那次的结果 —— 这正是逐项把关能成立的原因。
    * 每一项的 4 个 part_start 字节是【依次】写 [7:0]..[31:24] 的，
      所以要逐字节拼，不能一次性赋值。
"""

MASK = 0xFFFFFFFF


def parse_mbr(mbr, gated):
    """mbr: 512 字节；gated=True 走改后的逻辑（this_ok 把关）。

    返回 (part_start, pt_hit)。
    """
    assert len(mbr) == 512
    pt_idx = 0
    pt_hit = 0
    this_ok = 0
    ps = [0, 0, 0, 0]          # part_start 的 4 个字节，小端

    for bcnt in range(512):
        d = mbr[bcnt]
        base = 446 + pt_idx * 16

        # ---- 本拍对 this_ok 的写入（非阻塞：下一拍才生效）----
        this_ok_next = this_ok
        if bcnt == base:
            this_ok_next = 0
        if bcnt == base + 4:
            this_ok_next = 1 if d in (0x0B, 0x0C) else 0
            if d in (0x0B, 0x0C):
                pt_hit = 1

        # ---- 本拍对 part_start 的写入，读的是【上一拍】的 this_ok ----
        if (this_ok if gated else 1):
            if bcnt == base + 8:  ps[0] = d
            if bcnt == base + 9:  ps[1] = d
            if bcnt == base + 10: ps[2] = d
            if bcnt == base + 11: ps[3] = d

        if bcnt == base + 15:
            pt_idx += 1

        this_ok = this_ok_next

    part_start = ps[0] | (ps[1] << 8) | (ps[2] << 16) | (ps[3] << 24)
    return part_start & MASK, pt_hit


def entry(boot=0x00, ctype=0x00, lba=0, size=0):
    """造一个 16 字节分区项。CHS 字段填常见的占位值，不影响解析。"""
    e = bytearray(16)
    e[0] = boot
    e[1:4] = bytes([0x20, 0x21, 0x00]) if boot else bytes([0x00, 0x00, 0x00])
    e[4] = ctype
    e[5:8] = bytes([0xFE, 0xFF, 0xFF]) if ctype else bytes([0x00, 0x00, 0x00])
    e[8:12] = lba.to_bytes(4, "little")
    e[12:16] = size.to_bytes(4, "little")
    return bytes(e)


def std_mbr():
    """标准 Windows 格式化的 FAT32 卡：第 0 项 FAT32，后 3 项全 0。"""
    m = bytearray(512)
    m[0:3] = bytes([0x33, 0xC0, 0x8E])          # 典型 MBR 引导代码头
    m[446:462] = entry(boot=0x80, ctype=0x0C, lba=2048, size=0x0074C000)
    # 第 1/2/3 项保持全 0
    return bytes(m)


def superfloppy():
    """超软盘：LBA0 直接就是 FAT 引导扇区，0x1BE 往后是引导代码。"""
    m = bytearray(512)
    m[0:3] = bytes([0xEB, 0x58, 0x90])          # FAT 引导扇区的跳转指令
    m[3:11] = b"MSDOS5.0"
    for i in range(446, 510):                    # 引导代码糊满分区表位置
        m[i] = (0x37 + i * 7) & 0xFF
    m[510:512] = bytes([0x55, 0xAA])
    return bytes(m)


if __name__ == "__main__":
    cases = [
        ("标准 Windows FAT32 卡（第0项 type=0x0C, LBA=2048）", std_mbr()),
        ("超软盘格式（LBA0 就是引导扇区，没有 MBR）", superfloppy()),
    ]
    print(f"{'情形':<44} {'改前(不判类型)':>16} {'改后(逐项判类型)':>18}")
    print("-" * 84)
    for name, mbr in cases:
        old, _ = parse_mbr(mbr, gated=False)
        new, hit = parse_mbr(mbr, gated=True)
        print(f"{name:<44} {old:>10} (0x{old:05X}) {new:>10} (0x{new:05X})")
        print(f"{'':<44} {'':>16} {'pt_hit=' + str(hit):>18}")
