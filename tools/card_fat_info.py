# -*- coding: utf-8 -*-
"""
card_fat_info.py -- 直接解析 FAT32 卡，打印根目录每一项的
【名字 / 属性 / 起始簇 / 大小 / 起始簇的低4位】。

为什么需要它：
  板上 `fat32_reader` 有一个现成的输出 `first_cluster`（起始簇）。
  如果把它显示在数码管上，"每次打开的是不是同一个文件"就一眼可判 ——
  但前提是【六个文件的起始簇低 4 位互不相同】，否则这个探针分辨不出来。
  本工具就是用卡上真实数据把这个前提验掉，顺便看清目录项的排列顺序
  （扫描是"第一个命中的赢"，顺序会影响结果）。

用法： python tools/card_fat_info.py E:\\
"""
import struct
import sys


def main():
    dev = sys.argv[1] if len(sys.argv) > 1 else "E:"
    dev = dev.rstrip("\\/")
    # Windows 上要读裸卷必须用 \\.\X: 这种写法（普通 open("E:/") 会被当成目录）
    raw = "\\\\.\\" + dev if len(dev) <= 3 and dev.endswith(":") else dev
    f = open(raw, "rb")

    # 读 MBR 时还不知道 BPS（它在引导扇区里），先按 512 读；读到 VBR 再改成真值
    BPS_H = [512]

    def rd_lba(lba, n):
        f.seek(lba * BPS_H[0])
        return f.read(n)

    mbr = rd_lba(0, 512)
    if mbr[510:512] != b"\x55\xaa":
        print("不是合法 MBR")
        return

    # ★ 和 src/fat32_reader.v 同一套判据 ★
    #   4 个分区项里没有任何一项的类型字节是 0x0B/0x0C，就认为这张卡是
    #   "超级软盘"格式（没有 MBR，LBA0 直接是 FAT32 引导扇区），part_start = 0。
    #   新这张卡就是这种：LBA0 = EB 58 90 'MSDOS5.0'。
    part_lba = 0
    for i in range(4):
        e = mbr[446 + i * 16: 446 + (i + 1) * 16]
        if e[4] in (0x0B, 0x0C):
            part_lba = struct.unpack_from("<I", e, 8)[0]
            print("分区表项 %d 是 FAT32，分区起始 LBA = %d" % (i, part_lba))
            break
    else:
        print("★ 四个分区项都没有 FAT32 类型 ⇒ 超级软盘格式（无 MBR），按 part_start=0 处理")
        print("  LBA0 头 3 字节 = %s（EB/8'hEB 开头就是引导扇区跳转指令）"
              % " ".join("%02X" % b for b in mbr[0:3]))

    vbr = rd_lba(part_lba, 512)
    BPS = struct.unpack_from("<H", vbr, 11)[0]        # 每扇区字节数
    BPS_H[0] = BPS
    SPC = vbr[13]                                     # 每簇扇区数
    RSV = struct.unpack_from("<H", vbr, 14)[0]        # 保留扇区
    NFAT = vbr[16]
    FATSZ = struct.unpack_from("<I", vbr, 36)[0]
    ROOT = struct.unpack_from("<I", vbr, 44)[0]
    print("BPS=%d  SPC=%d(簇=%d字节)  保留=%d  FAT数=%d  FAT大小=%d  根簇=%d"
          % (BPS, SPC, BPS * SPC, RSV, NFAT, FATSZ, ROOT))

    fat_start = part_lba + RSV
    data_start = part_lba + RSV + NFAT * FATSZ

    def cluster_lba(cl):
        return data_start + (cl - 2) * SPC

    def next_cluster(cl):
        bo = cl * 4
        sec = fat_start + bo // BPS
        off = bo % BPS
        return struct.unpack("<I", rd_lba(sec, BPS)[off:off + 4])[0] & 0x0FFFFFFF

    # 走根目录的簇链
    entries = []
    cl, guard = ROOT, 0
    while 2 <= cl < 0x0FFFFFF8 and guard < 200:
        guard += 1
        for s in range(SPC):
            sec = rd_lba(cluster_lba(cl) + s, BPS)
            for i in range(0, BPS, 32):
                e = sec[i:i + 32]
                if e[0] == 0x00:
                    break
                if e[0] == 0xE5 or e[11] == 0x0F:
                    continue          # 已删 / 长文件名项
                name = e[0:8].decode("latin1").rstrip()
                ext = e[8:11].decode("latin1").rstrip()
                attr = e[11]
                hi = struct.unpack_from("<H", e, 20)[0] & 0x0FFF
                lo = struct.unpack_from("<H", e, 26)[0]
                fc = (hi << 16) | lo
                size = struct.unpack_from("<I", e, 28)[0]
                entries.append(("%s.%s" % (name, ext), attr, fc, size, e[0:11], e[12]))
        cl = next_cluster(cl)

    print("\n根目录共 %d 项：" % len(entries))
    print("  %-14s %-4s %-12s %-10s %-6s %-26s %s"
          % ("名字", "属性", "起始簇", "大小", "簇低4", "目录项原始11字节", "NT大小写标志"))
    for (n, a, fc, sz, rawname, ntcase) in entries:
        print("  %-14s 0x%02X %-12d %-10d %-6X %-26s 0x%02X"
              % (n, a, fc, sz, fc & 0xF, repr(rawname), ntcase))

    bmps = [e for e in entries if e[0].upper().endswith(".BMP")]
    lows = [e[2] & 0xF for e in bmps]
    print("\nBMP 文件起始簇低4位：", ",".join("%X" % v for v in lows))
    if len(set(lows)) == len(lows):
        print("⇒ 【互不相同】—— 把 first_cluster[3:0] 显示到数码管上可以分辨每个文件 ✓")
    else:
        print("⇒ 【有重复】—— 单看低4位分辨不了，探针要取更多位")


if __name__ == "__main__":
    main()
