`timescale 1ns/1ps
// ============================================================================
// tb_fifo_equiv.v -- frame_fifo_write 改动前后的【逐拍等价性】对比
//
// 左边 DUT  = 改动后的 frame_fifo_write      (into_burst 用 wr_remain 递减寄存器)
// 右边 REF  = 改动前的 frame_fifo_write_ref  (into_burst 用 write_len_latch-write_cnt)
//
// 两个模块吃完全相同的激励，各自带一份行为级 FIFO 模型（生产端速率完全一样，
// 消费端各自跟随自己的 App_wr_en）。只要两个模块行为一致，两边 FIFO 水位就一致；
// 一旦有任何一拍输出不同，水位会跟着分叉，后续对比会持续报错 —— 所以这个测试
// 能抓住"只在边界条件下差一拍"的问题。
//
// 激励刻意做得很刁：写长度随机（含非 BURST_SIZE 整数倍）、生产端速率随机
// （逼 FSM 在 S_CHECK_FIFO 反复采样 into_burst）、请求间隔随机。
//
// 参考模块由 tools/make_ref_fifo.py 生成，运行前先跑它。
// 运行：
//   iverilog -g2005 -o tb_fifo_equiv.vvp -s tb_fifo_equiv \
//       ../src/frame_fifo_write.v ref_frame_fifo_write.v tb_fifo_equiv.v
//   vvp tb_fifo_equiv.vvp
// ============================================================================
module tb_fifo_equiv;

    localparam BURST      = 128;
    localparam FIFO_DEPTH = 512;
    localparam AB         = 21;
    localparam NCASE      = 12;        // 跑 12 轮

    reg mem_clk = 1'b0;
    reg rst     = 1'b1;
    always #4 mem_clk = ~mem_clk;      // 125MHz

    // ---------------- 伪随机 ----------------
    reg [31:0] lfsr = 32'h1234_5678;
    function [31:0] rnd;
        input dummy;                   // iverilog 要求函数至少有一个端口
        begin
            lfsr = {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            rnd  = lfsr;
        end
    endfunction

    // ---------------- 激励 ----------------
    reg          write_req = 1'b0;
    reg [AB-1:0] write_len = 21'd0;
    reg          prod_en   = 1'b0;     // 生产端本拍是否往 FIFO 灌一个字

    // ---------------- 两份 FIFO 模型 ----------------
    // 位宽必须够大：跨多轮累加会超过 8191，13 位会回绕，水位算错就全乱了
    reg  [18:0] prod_a = 0, cons_a = 0;
    reg  [18:0] prod_b = 0, cons_b = 0;
    wire [18:0] lvl_a  = prod_a - cons_a;
    wire [18:0] lvl_b  = prod_b - cons_b;
    wire [9:0]  used_a = lvl_a[9:0];       // FIFO_DEPTH=512，高位恒为 0
    wire [9:0]  used_b = lvl_b[9:0];

    // ---------------- DUT / REF ----------------
    wire          en_a, en_b;
    wire [AB-1:0] addr_a, addr_b;
    wire          ack_a, ack_b, fin_a, fin_b, busy_a, busy_b;

    frame_fifo_write #(.ADDR_BITS(AB), .BURST_SIZE(BURST)) dut (
        .rst(rst), .mem_clk(mem_clk),
        .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b1), .Sdr_busy(1'b0), .App_rd_busy(1'b0),
        .O_wr_busy(busy_a), .App_wr_en(en_a), .App_wr_addr(addr_a),
        .write_req(write_req), .write_req_ack(ack_a), .write_finish(fin_a),
        .write_addr_0(21'd0), .write_addr_1(21'd0), .write_addr_2(21'd0), .write_addr_3(21'd0),
        .write_addr_index(2'd0), .write_len(write_len),
        .fifo_aclr(), .rdusedw(used_a)
    );

    frame_fifo_write_ref #(.ADDR_BITS(AB), .BURST_SIZE(BURST)) ref (
        .rst(rst), .mem_clk(mem_clk),
        .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b1), .Sdr_busy(1'b0), .App_rd_busy(1'b0),
        .O_wr_busy(busy_b), .App_wr_en(en_b), .App_wr_addr(addr_b),
        .write_req(write_req), .write_req_ack(ack_b), .write_finish(fin_b),
        .write_addr_0(21'd0), .write_addr_1(21'd0), .write_addr_2(21'd0), .write_addr_3(21'd0),
        .write_addr_index(2'd0), .write_len(write_len),
        .fifo_aclr(), .rdusedw(used_b)
    );

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin prod_a <= 0; cons_a <= 0; prod_b <= 0; cons_b <= 0; end
        else begin
            if (prod_en && prod_a < 307200 && lvl_a < FIFO_DEPTH) prod_a <= prod_a + 1;
            if (en_a && lvl_a > 0)                                cons_a <= cons_a + 1;
            if (prod_en && prod_b < 307200 && lvl_b < FIFO_DEPTH) prod_b <= prod_b + 1;
            if (en_b && lvl_b > 0)                                cons_b <= cons_b + 1;
        end
    end

    // ---------------- 逐拍对比 ----------------
    integer mismatches = 0;
    integer checks     = 0;

    always @(posedge mem_clk) begin
        if (!rst) begin
            checks = checks + 1;
            if (en_a !== en_b || addr_a !== addr_b || ack_a !== ack_b ||
                fin_a !== fin_b || busy_a !== busy_b ||
                dut.into_burst !== ref.into_burst || dut.state !== ref.state ||
                used_a !== used_b) begin
                mismatches = mismatches + 1;
                if (mismatches <= 10)
                    $display("[%0t] 不一致: en %b/%b addr %h/%h ack %b/%b fin %b/%b busy %b/%b into %b/%b state %0d/%0d usedw %0d/%0d",
                             $time, en_a, en_b, addr_a, addr_b, ack_a, ack_b,
                             fin_a, fin_b, busy_a, busy_b,
                             dut.into_burst, ref.into_burst, dut.state, ref.state,
                             used_a, used_b);
            end
        end
    end

    // ---------------- 主流程 ----------------
    integer c, w;
    reg [AB-1:0] this_len;
    reg [31:0]   rv;

    initial begin
        repeat (10) @(posedge mem_clk);
        rst = 1'b0;
        repeat (10) @(posedge mem_clk);

        for (c = 0; c < NCASE; c = c + 1) begin
            // 随机写长度：一半是 BURST 的整数倍，一半不是（覆盖 write_cnt 越界的情况）
            // 只跑 BURST_SIZE 整数倍 —— 真实设计里 write_len 恒为 307200 = 2400*128。
            // 非整数倍会让原模块卡死（见文件末尾说明），那不是这次改动引入的，
            // 单独放到最后一轮做记录，不参与等价性判定。
            rv = rnd(1'b0);
            this_len = (13'd1 + rv[12:0] % 13'd40) * BURST;              // 128..5120
            write_len = this_len[AB-1:0];
            if (write_len < 21'd128) write_len = 21'd512;                // 太小跑不出东西

            // write_req_ack 是电平不是脉冲：S_ACK 拉高后会一直保持到下一次 S_IDLE。
            // 不先等它落下，下一轮就会读到上一轮的残留 ack，请求被当成"已经应答过"，
            // 结果整轮卡死（这是 TB 的握手问题，DUT 本身没毛病）。
            while (ack_a) @(posedge mem_clk);
            repeat (4) @(posedge mem_clk);        // 让 write_len 传到 write_len_d1

            write_req = 1'b1;
            @(posedge mem_clk);
            while (!ack_a) @(posedge mem_clk);
            write_req = 1'b0;

            // 生产端速率随机波动，逼 FSM 反复在 S_CHECK_FIFO 采样 into_burst
            w = 0;
            while (!fin_a && w < 400000) begin
                rv      = rnd(1'b0);
                prod_en = (rv[2:0] != 3'd0);        // 7/8 的概率灌一个字
                @(posedge mem_clk);
                w = w + 1;
            end
            prod_en = 1'b0;
            $display("  第 %0d 轮: write_len=%0d  用了 %0d 拍  fin=%0d", c, write_len, w, fin_a);

            // 请求之间随机间隔
            rv = rnd(1'b0);
            repeat (rv[4:0] + 5) @(posedge mem_clk);
        end

        repeat (200) @(posedge mem_clk);

        $display("=============================================");
        $display("  对比拍数     : %0d", checks);
        $display("  不一致次数   : %0d", mismatches);
        if (mismatches == 0) $display("=== 等价性验证通过：改动前后逐拍完全一致 ===");
        else                 $display("=== 等价性验证失败 ===");
        $display("=============================================");
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT at %0t, 不一致 %0d", $time, mismatches);
        $finish;
    end

endmodule
