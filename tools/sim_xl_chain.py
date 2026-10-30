# -*- coding: utf-8 -*-
"""
sim_xl_chain.py —— 把 fat32_reader.v 的【簇链翻译】路径原样搬到 Python 里，
                   在一张合成的 FAT32 卡上逐扇区对答案。

为什么值得做：
    目录读成功（file_size = 921654 一字不差）已经证明了 spc / spc_log2 /
    data_start / fat_start / root_cluster / reserved_sec / num_fats / fat_size
    这一整套 BPB 解析是对的 —— 因为读出根目录本身就要用它们算地址。
    ★ 唯一没被验证过的是簇链那条路（xl_req/xl_lba）：
      bmp_read 靠它拿每个扇区的实际 LBA，而 01.BMP 有 1801 个扇区、
      226 个簇，中间只要有一步跟错，取到的就是别的扇区的数据 ——
      "画面花掉"和"完全没画面"是两种完全不同的故障，必须先在软件里分开。

怎么保证"对答案"是真的对答案：
    合成卡的数据区里，每个扇区的头 4 字节写成【这个扇区在文件里的序号】。
    于是模型的流程是：给一个文件内扇区号 idx -> 走簇链 -> 算出 LBA ->
    去那个 LBA 读头 4 字节 -> 应当正好等于 idx。
    这同时验了：tgt_ord/tgt_off 的拆位、簇链一步步跟、cluster->LBA 的算式，
    以及 fat_sec/fat_boff 取 FAT 项的字节偏移有没有错位。
    任何一处错了，读回来的序号就对不上（或者读到哨兵值 0xFFFFFFFF）。

建模要点（和 Verilog 对齐）：
    * cur_cluster / cur_ord 是【跨调用保持】的 —— 顺序读时下一次请求
      多半正好落在当前簇，S_XL_CHK 会走 tgt_ord == cur_ord 这条短路。
      这个状态必须在多次 translate() 之间留着，否则默认了顺序读的最优路径。
    * 往回的跳（tgt_ord < cur_ord）会先把游标复位到 first_cluster、cur_ord
      清 0，然后【停在 S_XL_CHK】重新判断（不是直接重走）。
    * chain_end 的改前/改后差别在这里也建了模，可以对照。
"""

SPC_LOG2 = 3
SPC = 1 << SPC_LOG2          # 8 扇区/簇 = 4KB/簇
PART_START = 2048
RESERVED = 32
NUM_FATS = 2
FAT_SIZE = 1000              # 每份 FAT 多少扇区
FAT_START = PART_START + RESERVED            # 2080
DATA_START = FAT_START + NUM_FATS * FAT_SIZE  # 4080

FILE_SECTORS = 1801          # 921654 字节 -> ceil(921654/512) = 1801
NC = (FILE_SECTORS + SPC - 1) // SPC          # 需要的簇数 = 226

EOC = 0x0FFFFFFF


class Card:
    """一张合成卡。fat 区用字节数组，数据区用 LBA->内容 的字典。"""

    def __init__(self):
        self.first_cluster = 5
        # --- 造一条有碎片的簇链 ---
        self.chain = []
        c = self.first_cluster
        for j in range(NC):
            self.chain.append(c)
            c += 1
            if (j % 17) == 16:
                c += 23                      # 每 17 簇断一下，制造不连续
        assert len(set(self.chain)) == NC

        # --- FAT 表 ---
        self.fat_size_bytes = FAT_SIZE * 512
        self.fat = bytearray(b"\x00" * self.fat_size_bytes)
        for j in range(NC - 1):
            self._set_fat(self.chain[j], self.chain[j + 1])
        self._set_fat(self.chain[-1], EOC)

        # --- 数据区：每个文件扇区头 4 字节写自己的序号 ---
        self.data = {}
        for j, clu in enumerate(self.chain):
            for o in range(SPC):
                idx = j * SPC + o
                if idx >= FILE_SECTORS:
                    continue                 # 末尾簇多出来的扇区不属于文件
                lba = DATA_START + (clu - 2) * SPC + o
                self.data[lba] = idx.to_bytes(4, "little")

    def _set_fat(self, c, val):
        self.fat[c * 4: c * 4 + 4] = val.to_bytes(4, "little")

    def read_sector(self, lba):
        """按【绝对 LBA】读一个扇区。区域判断故意严格 —— 算错地址会直接炸，
        不会悄悄读到别的数据。真卡上那一步是"回错误 R1 -> 厂商驱动无限重发"。"""
        if FAT_START <= lba < DATA_START:
            s = (lba - FAT_START) * 512
            return bytes(self.fat[s:s + 512])
        if DATA_START <= lba:
            return self.data.get(lba, b"\xff\xff\xff\xff" + b"\x00" * 508)
        raise AssertionError(
            f"读到了保留区/分区外: LBA {lba} (fat_start={FAT_START}, data_start={DATA_START})")

    # ---- 以下是 fat32_reader.v 里那两个组合量 ----
    def fat_sec_of(self, cluster):
        return FAT_START + (cluster >> 7)              # fat_start + cluster/128

    def fat_entry_of(self, cluster):
        lba = self.fat_sec_of(cluster)
        off = (cluster & 0x7F) << 2                    # (cluster % 128) * 4
        b = self.read_sector(lba)
        return int.from_bytes(b[off:off + 4], "little")


class Xl:
    """fat32_reader 的翻译状态机。cur_cluster/cur_ord 跨调用保持。"""

    def __init__(self, card, chain_end_fixed=True):
        self.card = card
        self.fixed = chain_end_fixed
        self.cur_cluster = card.first_cluster
        self.cur_ord = 0
        self.next_cluster = 0      # 只为复现改前那个"用陈旧值判链尾"的行为
        self.fat_reads = 0

    def translate(self, idx):
        """返回 (xl_lba, xl_err)。"""
        card = self.card
        tgt_ord = idx >> SPC_LOG2
        tgt_off = idx & (SPC - 1)
        state = "CHK"
        guard = 0
        while True:
            guard += 1
            assert guard < 1_000_000, "状态机不收敛（真机上就是挂死）"

            if state == "CHK":
                if tgt_ord == self.cur_ord:
                    state = "DONE"
                elif tgt_ord == self.cur_ord + 1:
                    state = "FAT_REQ"
                elif tgt_ord > self.cur_ord:
                    state = "FAT_REQ"
                else:
                    # 往回跳：游标复位，然后【留在 CHK】重新判断
                    self.cur_cluster = card.first_cluster
                    self.cur_ord = 0

            elif state == "FAT_REQ":
                state = "FAT_RD"

            elif state == "FAT_RD":
                entry = card.fat_entry_of(self.cur_cluster)
                self.fat_reads += 1
                nxt = entry & 0x0FFFFFFF
                if self.fixed:
                    end = nxt >= 0x0FFFFFF8
                else:
                    end = self.next_cluster >= 0x0FFFFFF8   # 改前的陈旧判定
                self.next_cluster = nxt
                if end:
                    return 0, True                          # xl_err, xl_lba = 0
                self.cur_cluster = nxt
                self.cur_ord += 1
                state = "CHK"

            elif state == "DONE":
                lba = (DATA_START + ((self.cur_cluster - 2) << SPC_LOG2) + tgt_off) & 0xFFFFFFFF
                return lba, False


def run(fixed):
    card = Card()
    xl = Xl(card, chain_end_fixed=fixed)
    bad = []
    for idx in range(FILE_SECTORS):
        lba, err = xl.translate(idx)
        if err:
            bad.append((idx, "xl_err", lba)); continue
        got = int.from_bytes(card.read_sector(lba)[:4], "little")
        want = idx
        if got != want:
            bad.append((idx, f"LBA={lba} 读回 {got}", want))
    return xl, bad


def run_past_eof(fixed):
    """请求超出文件末尾的扇区号 —— 正是 xl_err 该起作用的地方。"""
    card = Card()
    xl = Xl(card, chain_end_fixed=fixed)
    for idx in range(FILE_SECTORS):      # 先顺序读完整个文件
        xl.translate(idx)
    out = []
    for idx in (FILE_SECTORS, FILE_SECTORS + 8, FILE_SECTORS + 16):
        lba, err = xl.translate(idx)
        out.append((idx, lba, err))
    return out


if __name__ == "__main__":
    print(f"文件 {FILE_SECTORS} 扇区 / {NC} 簇，数据区起始 LBA {DATA_START}\n")

    print("【改后】chain_end 用刚读回来的 fat_entry")
    xl, bad = run(fixed=True)
    print(f"  顺序读完 {FILE_SECTORS} 个扇区：错 {len(bad)} 个，"
          f"共发起 {xl.fat_reads} 次 FAT 扇区读（≈每簇一次，符合预期）")
    for b in bad[:5]:
        print("   ", b)

    # 往回跳（随机访问）也要对
    xl2 = Xl(Card(), chain_end_fixed=True)
    card2 = xl2.card
    back_bad = []
    for idx in (1700, 3, 900, 0, 1800, 7):
        lba, err = xl2.translate(idx)
        got = int.from_bytes(card2.read_sector(lba)[:4], "little") if not err else -1
        if err or got != idx:
            back_bad.append((idx, lba, got))
    print(f"  乱序/往回跳 6 次：错 {len(back_bad)} 个  {back_bad if back_bad else ''}")

    print("\n【改后】超出文件末尾")
    for idx, lba, err in run_past_eof(fixed=True):
        print(f"  idx={idx:<6} xl_err={int(err)}  xl_lba={lba}")

    print("\n【改前】超出文件末尾（复现那个假安全网）")
    for idx, lba, err in run_past_eof(fixed=False):
        print(f"  idx={idx:<6} xl_err={int(err)}  xl_lba={lba} (0x{lba:08X})"
              + ("   ← 天文数字，且 err=0" if (not err and lba > 0xFFFFF) else ""))
