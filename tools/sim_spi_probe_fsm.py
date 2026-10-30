# -*- coding: utf-8 -*-
"""
逐拍模型：spi_probe_top 的整条 CMD0 链路，验证它会不会卡住。

为什么只建到 S_F1：
    上板看到的是"不插卡时 d7 一直停在 0"。
    按代码，CMD0 超时约 5ms 后 d7 应该变成 1（S_F1）。
    所以嫌疑在 S_PWR 之后的某处。这里把 S_PWR -> S_TX6 -> S_R1W -> S_C0V -> S_F1
    整条走完，看它到底停不停得下来、要多久。

建模依据：
    - spi_master 的时序：状态转移一拍一次（它的 next_state 只用 <= 写、
      不被读，所以对敏感列表没有贡献，对外等价于"组合 + 一级寄存器"）。
    - MISO 恒为 1（不插卡，内部上拉把它拉高）
      -> spi_master 收到的每个字节都是 0xFF
      -> S_R1W 里 spi_data_out[7] 永远是 1，收不到有效 R1
    - CLK_DIV_INIT=123 -> 半周期 124 拍，一个字节 16 个边沿

注意：这是按 Verilog 语义重写的一份模型，不是仿真器跑原码。
它只能证明"我的理解下不会死锁"，不能代替上板。
但它能抓住 off-by-one / 状态漏跳这类错误 —— 这正是要查的。
"""

IDLE, DCLK_EDGE, DCLK_IDLE, ACK, LAST_HALF_CYCLE, ACK_WAIT = range(6)
MNAME = {IDLE: "IDLE", DCLK_EDGE: "DCLK_EDGE", DCLK_IDLE: "DCLK_IDLE",
         ACK: "ACK", LAST_HALF_CYCLE: "LAST_HALF", ACK_WAIT: "ACK_WAIT"}

S_PWR, S_TX6, S_R1W, S_C0V, S_C8V, S_55D, S_41V, S_OK, S_F1, S_F2, S_F3 = range(11)
SNAME = {S_PWR: "S_PWR", S_TX6: "S_TX6", S_R1W: "S_R1W", S_C0V: "S_C0V",
         S_C8V: "S_C8V", S_55D: "S_55D", S_41V: "S_41V", S_OK: "S_OK",
         S_F1: "S_F1", S_F2: "S_F2", S_F3: "S_F3"}

CLK_DIV = 123
R1_MAX = 128
ACMD_MAX = 2048


class Sim:
    def __init__(self):
        # spi_master
        self.ms = IDLE
        self.clk_cnt = 0
        self.edge_cnt = 0
        # spi_probe_top
        self.st = S_PWR
        self.rcnt = 0          # R1 等待中已发的 0xFF 个数
        self.bcnt = 0          # 命令里发到第几字节
        self.acnt = 0          # ACMD41 重试次数
        self.r7cnt = 0
        self.wr_req = 0
        self.cur_cmd = 0
        self.tx_ok = S_C0V
        self.tx_to = S_F1
        self.r1_c0 = 0xFF
        self.r1_c8 = 0xFF
        self.r1_41 = 0xFF
        # 统计
        self.n = 0
        self.events = []

    # ---- spi_master 的组合输出 ----
    def ns(self):
        s, w, c, cc = self.ms, self.wr_req, self.clk_cnt, self.edge_cnt
        if s == IDLE:
            return DCLK_IDLE if w else IDLE
        if s == DCLK_IDLE:
            return DCLK_EDGE if c == CLK_DIV else DCLK_IDLE
        if s == DCLK_EDGE:
            return LAST_HALF_CYCLE if cc == 15 else DCLK_IDLE
        if s == LAST_HALF_CYCLE:
            return ACK if c == CLK_DIV else LAST_HALF_CYCLE
        if s == ACK:
            return ACK_WAIT
        return IDLE

    def status(self):
        if self.st == S_F1:
            return 1
        if self.st == S_F2:
            return 2
        if self.st == S_F3:
            return 3
        if self.st == S_OK:
            return 4
        return 0

    def tick(self):
        ns = self.ns()
        ack = (self.ms == ACK)
        st0 = self.st
        rcnt0, bcnt0 = self.rcnt, self.bcnt

        # ---------------- spi_probe_top 的时钟块 ----------------
        if self.st == S_PWR:
            if self.rcnt >= 10:
                self.rcnt, self.wr_req, self.bcnt = 0, 0, 0
                self.cur_cmd, self.tx_ok, self.tx_to = 0, S_C0V, S_F1
                self.st = S_TX6
            elif ack:
                self.rcnt += 1
            else:
                self.wr_req = 1
        elif self.st == S_TX6:
            if ack:
                if self.bcnt == 5:
                    self.wr_req, self.bcnt, self.rcnt = 0, 0, 0
                    self.st = S_R1W
                else:
                    self.bcnt += 1
            else:
                self.wr_req = 1
        elif self.st == S_R1W:
            if ack:
                rx = 0xFF          # MISO 恒 1 -> 收到的字节恒为 0xFF
                if self.cur_cmd == 0:
                    self.r1_c0 = rx
                elif self.cur_cmd == 1:
                    self.r1_c8 = rx
                elif self.cur_cmd == 3:
                    self.r1_41 = rx
                if rx & 0x80 == 0:
                    self.wr_req, self.rcnt = 0, 0
                    self.st = self.tx_ok
                elif self.rcnt >= R1_MAX - 1:
                    self.wr_req, self.rcnt = 0, 0
                    self.st = self.tx_to
                else:
                    self.rcnt += 1
            else:
                self.wr_req = 1
        elif self.st == S_C0V:
            if self.r1_c0 == 0x01:
                self.cur_cmd, self.tx_ok, self.tx_to, self.bcnt = 1, S_C8V, S_F2, 0
                self.st = S_TX6
            else:
                self.st = S_F2
        else:
            pass   # 终态保持

        # ---------------- spi_master 的时钟块 ----------------
        old = self.ms
        if old in (DCLK_IDLE, LAST_HALF_CYCLE):
            self.clk_cnt += 1
        else:
            self.clk_cnt = 0
        if old == DCLK_EDGE:
            self.edge_cnt += 1
        elif old == IDLE:
            self.edge_cnt = 0
        self.ms = ns

        self.n += 1
        if self.st != st0:
            self.events.append((self.n, SNAME[self.st], self.status()))


def main():
    s = Sim()
    guard = 5000000
    while s.st not in (S_OK, S_F1, S_F2, S_F3) and s.n < guard:
        s.tick()

    print("=== CMD0 链路逐拍模拟（不插卡，MISO 恒 1）===")
    print()
    print("状态转移：")
    for n, name, st in s.events:
        print("   %8d 拍 (%8.1f us)  ->  %-6s   d7 显示 %d"
              % (n, n / 50.0, name, st))
    print()
    if s.st in (S_OK, S_F1, S_F2, S_F3):
        final = "停在 %s" % SNAME[s.st]
    else:
        final = "*** 卡死：%d 拍还没结束 ***" % s.n
    print("结果：%s" % final)
    print("总耗时：%d 拍 = %.2f ms @50MHz" % (s.n, s.n / 50000.0))
    print("最终 d7 = %d，d6d5 = %02X" % (s.status(), s.r1_c0))
    print()
    if s.st == S_F1:
        print("=> 与预期一致：不插卡时约 %.1f ms 后 d7 应该变成 1。" % (s.n / 50000.0))
        print("   上板看到 d7 一直是 0，与这个模型矛盾 -> 更可能是跑的不是这份源码的位流。")
    elif s.n >= guard:
        print("=> 找到问题：状态机卡住了。上面最后一次转移就是卡住的位置。")
    else:
        print("=> 停在了非预期的状态，检查上面的转移序列。")


if __name__ == "__main__":
    main()
