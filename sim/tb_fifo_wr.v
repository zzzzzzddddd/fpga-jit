`timescale 1ns/1ps
// ============================================================================
// tb_fifo_wr.v -- frame_fifo_write 的功能仿真（快，只跑小帧）
//
// 目的：验证把 into_burst 里那个 21 位加法器换成"递减寄存器 wr_remain"之后，
//       突发写入的行为跟改之前完全一样。改前后各跑一次，输出应该逐行相同。
//
// 模型：用行为级 FIFO 代替真实异步 FIFO ——
//       生产端以 1 字/拍往里灌，灌满 N 个为止；FIFO 深度 512；
//       消费端就是 DUT 的 App_wr_en，每拍取走 1 字。
//
// 运行：
//   iverilog -g2005 -o tb_fifo_wr.vvp -s tb_fifo_wr ../src/frame_fifo_write.v tb_fifo_wr.v
//   vvp tb_fifo_wr.vvp
// ============================================================================
module tb_fifo_wr;

    localparam N         = 2048;      // 一帧字数（真实是 307200，这里缩小跑得快）
    localparam BURST     = 128;
    localparam FIFO_DEPTH= 512;
    localparam AB        = 21;

    reg mem_clk = 1'b0;
    reg rst     = 1'b1;
    always #4 mem_clk = ~mem_clk;      // 125MHz

    // ---- 行为级 FIFO ----
    reg [12:0] produced = 13'd0;
    reg [12:0] consumed = 13'd0;
    wire [12:0] level    = produced - consumed;

    wire        App_wr_en;
    reg  [9:0]  rdusedw;

    always @(*) rdusedw = level[9:0];

    // ---- DUT ----
    wire        App_wr_en_dut;
    wire [AB-1:0] App_wr_addr;
    wire        write_req_ack;
    wire        write_finish;
    wire        O_wr_busy;
    wire        fifo_aclr;

    assign App_wr_en = App_wr_en_dut;

    reg write_req = 1'b0;

    frame_fifo_write #(
        .ADDR_BITS  (AB),
        .BURST_SIZE (BURST)
    ) dut (
        .rst            (rst),
        .mem_clk        (mem_clk),
        .Sdr_init_done  (1'b1),
        .Sdr_init_ref_vld(1'b1),
        .Sdr_busy       (1'b0),
        .App_rd_busy    (1'b0),
        .O_wr_busy      (O_wr_busy),
        .App_wr_en      (App_wr_en_dut),
        .App_wr_addr    (App_wr_addr),
        .write_req      (write_req),
        .write_req_ack  (write_req_ack),
        .write_finish   (write_finish),
        .write_addr_0   (24'd0),
        .write_addr_1   (24'd0),
        .write_addr_2   (24'd0),
        .write_addr_3   (24'd0),
        .write_addr_index(2'd0),
        .write_len      (N[AB-1:0]),
        .fifo_aclr      (fifo_aclr),
        .rdusedw        (rdusedw)
    );

    // ---- 生产端 ----
    always @(posedge mem_clk or posedge rst) begin
        if (rst) produced <= 13'd0;
        else if (produced < N && level < FIFO_DEPTH) produced <= produced + 13'd1;
    end

    // ---- 消费端：DUT 每发出一个 App_wr_en 就取走 1 字 ----
    always @(posedge mem_clk or posedge rst) begin
        if (rst) consumed <= 13'd0;
        else if (App_wr_en_dut && level > 0) consumed <= consumed + 13'd1;
    end

    // ---- 统计 ----
    integer wr_cycles = 0;
    integer bursts    = 0;
    reg     prev_en   = 1'b0;
    reg [AB-1:0] last_addr = 0;
    integer addr_errs = 0;      // 突发起始地址不是 128 对齐
    integer step_errs = 0;      // 相邻两次突发起始地址之差 != 128
    integer rd_errs   = 0;      // FIFO 空时还在读

    always @(posedge mem_clk) begin
        if (!rst) begin
            if (App_wr_en_dut) begin
                wr_cycles = wr_cycles + 1;
                if (!prev_en) begin
                    bursts = bursts + 1;
                    // 每次突发必须从 128 对齐的地址开始
                    if (App_wr_addr[6:0] != 7'd0) addr_errs = addr_errs + 1;
                    // 相邻两次突发的起始地址必须正好差 BURST
                    if (bursts > 1 && (App_wr_addr - last_addr) != BURST)
                        step_errs = step_errs + 1;
                    last_addr = App_wr_addr;
                end
                // 关键：突发期间 FIFO 里必须有数据
                if (level == 0) rd_errs = rd_errs + 1;
            end
            prev_en <= App_wr_en_dut;
        end
    end

    integer t;
    initial begin
        repeat (10) @(posedge mem_clk);
        rst = 1'b0;
        repeat (10) @(posedge mem_clk);

        // 发一次写请求
        write_req = 1'b1;
        @(posedge mem_clk);
        while (!write_req_ack) @(posedge mem_clk);
        write_req = 1'b0;

        // 等写完（或超时）
        t = 0;
        while (!write_finish && t < 200000) begin
            @(posedge mem_clk);
            t = t + 1;
        end

        repeat (20) @(posedge mem_clk);

        $display("---------------------------------------------");
        $display("  write_finish 出现过     : %0d", (t < 200000));
        $display("  App_wr_en 总拍数         : %0d   (期望 %0d)", wr_cycles, N);
        $display("  突发次数                 : %0d   (期望 %0d)", bursts, N/BURST);
        $display("  FIFO 空时还读的次数      : %0d   (期望 0)", rd_errs);
        $display("  突发起始地址未对齐次数   : %0d   (期望 0)", addr_errs);
        $display("  突发起始地址步长错误次数 : %0d   (期望 0)", step_errs);
        $display("---------------------------------------------");
        if (wr_cycles == N && bursts == N/BURST && rd_errs == 0 &&
            addr_errs == 0 && step_errs == 0)
            $display("=== FIFO WRITE TEST PASS ===");
        else
            $display("=== FIFO WRITE TEST FAIL ===");
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT  App_wr_en=%0d bursts=%0d", wr_cycles, bursts);
        $finish;
    end

endmodule
