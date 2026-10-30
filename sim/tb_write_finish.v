`timescale 1ns/1ps
// ============================================================
// tb_write_finish.v — 验证"帧完成"判据为什么必须用 write_finish
//
// 本 TB 完整跑一遍 640x480 一帧的写入：
//   - 行为级 SDRAM（App_wr_en/App_rd_en 接口）记录真正落到 SDRAM 的字数
//   - 记录驱动侧"最后一个 write_en 发出"的时刻 t_last_push
//   - 记录 frame_fifo_write.write_finish 拉高的时刻 t_finish
//
// 判据：
//   1) 最终写入 SDRAM 的字数 == 307200
//   2) t_finish 必须【晚于】t_last_push（证明旧判据 state_code 4->1
//      = "最后一个像素刚进FIFO" 确实提前了，提前量就是 (t_finish - t_last_push)）
//
// 运行：iverilog -g2012 -o tb_write_finish.vvp tb_write_finish.v \
//         ../src/frame_read_write.v ../src/frame_fifo_read.v \
//         ../src/frame_fifo_write.v ../al_ip/afifo_16_32_256.v ../al_ip/afifo_32_16_256.v
//       vvp tb_write_finish.vvp
// ============================================================
module tb_write_finish;

localparam W  = 640;
localparam H  = 480;
localparam N  = W*H;              // 307200

// 写侧 / 存储侧 / 读侧 时钟
reg write_clk = 0;   // 100MHz
reg mem_clk   = 0;   // 125MHz
reg read_clk  = 0;   // 25MHz
always #5   write_clk = ~write_clk;
always #4   mem_clk   = ~mem_clk;
always #20  read_clk  = ~read_clk;

reg  rst = 1'b1;

// ---- 写侧激励 ----
reg         write_req = 1'b0;
reg  [20:0] write_addr_0 = 21'd0;
reg         write_en = 1'b0;
reg  [31:0] write_data = 32'd0;
wire        write_req_ack;
wire        write_finish;

// ---- 读侧激励 ----
reg         read_req = 1'b0;
reg  [20:0] read_addr_0 = 21'd0;
reg         read_en = 1'b0;
wire        read_req_ack;
wire        read_finish;
wire [31:0] read_data;

// ---- SDRAM 接口 ----
wire        App_wr_en;
wire [20:0] App_wr_addr;
wire [31:0] App_wr_din;
wire [3:0]  App_wr_dm;
wire        App_rd_en;
wire [20:0] App_rd_addr;
wire        Sdr_rd_en;
wire [31:0] Sdr_rd_dout;

// ---- 行为级 SDRAM ----
// 容量按 2 帧算; 实际只用基地址 0 + FRAME_WORDS 两处
localparam MEMW = 2*N;
reg [31:0] mem [0:MEMW-1];

integer wr_accepted = 0;          // 真正被 SDRAM 接收的字数
reg     last_push_seen = 1'b0;
time    t_last_push = 0;
time    t_finish    = 0;
integer finish_pulses = 0;

initial begin : mem_init
    integer j;
    for (j = 0; j < MEMW; j = j + 1) mem[j] = 32'hDEADBEEF;
end

always @(posedge mem_clk) begin
    if (App_wr_en) begin
        mem[App_wr_addr] <= App_wr_din;
        wr_accepted = wr_accepted + 1;
    end
end

// ---- 读数据返回模型 (16 拍延迟) ----
reg [31:0] dpipe [0:15];
reg [15:0] vpipe = 16'd0;
integer    ri;
always @(posedge mem_clk) begin
    dpipe[0] <= (App_rd_en) ? mem[App_rd_addr] : 32'd0;
    for (ri = 1; ri < 16; ri = ri + 1) dpipe[ri] <= dpipe[ri-1];
    vpipe <= {vpipe[14:0], App_rd_en};
end
assign Sdr_rd_dout = dpipe[15];
assign Sdr_rd_en   = vpipe[15];

// ---- write_finish 观测 ----
always @(posedge mem_clk) begin
    if (!rst && write_finish) begin
        finish_pulses = finish_pulses + 1;
        if (t_finish == 0) t_finish = $time;
        if (wr_accepted != N)
            $display("[%0t] !!! write_finish 在只写了 %0d / %0d 个字时就拉高了 !!!",
                     $time, wr_accepted, N);
    end
end

// ---- DUT ----
frame_read_write #(
    .MEM_DATA_BITS (32),
    .READ_DATA_BITS(32),
    .WRITE_DATA_BITS(32),
    .ADDR_BITS     (21),
    .BURST_BITS    (9),
    .BURST_SIZE    (256),
    .IMG_WIDTH     (W),
    .IMG_HEIGHT    (H),
    .ROW_REVERSE   (1)
) dut (
    .rst            (rst),
    .mem_clk        (mem_clk),
    .Sdr_init_done  (1'b1),
    .Sdr_init_ref_vld(1'b1),
    .Sdr_busy       (1'b0),

    .App_rd_en      (App_rd_en),
    .App_rd_addr    (App_rd_addr),
    .Sdr_rd_en      (Sdr_rd_en),
    .Sdr_rd_dout    (Sdr_rd_dout),

    .read_clk       (read_clk),
    .read_req       (read_req),
    .read_req_ack   (read_req_ack),
    .read_finish    (read_finish),
    .read_addr_0    (read_addr_0),
    .read_addr_1    (21'd0),
    .read_addr_2    (21'd0),
    .read_addr_3    (21'd0),
    .read_addr_index(2'd0),
    .read_len       (N),
    .read_en        (read_en),
    .read_data      (read_data),

    .App_wr_en      (App_wr_en),
    .App_wr_addr    (App_wr_addr),
    .App_wr_din     (App_wr_din),
    .App_wr_dm      (App_wr_dm),

    .write_clk      (write_clk),
    .write_req      (write_req),
    .write_req_ack  (write_req_ack),
    .write_finish   (write_finish),
    .write_addr_0   (write_addr_0),
    .write_addr_1   (21'd0),
    .write_addr_2   (21'd0),
    .write_addr_3   (21'd0),
    .write_addr_index(2'd0),
    .write_len      (N),
    .write_en       (write_en),
    .write_data     (write_data)
);

integer i;

initial begin
    repeat (40) @(posedge mem_clk);
    rst = 1'b0;
    repeat (20) @(posedge mem_clk);

    // ---------- 写一帧 ----------
    @(posedge write_clk);
    write_req = 1'b1;
    wait (write_req_ack == 1'b1);
    @(posedge write_clk);
    write_req = 1'b0;

    // 每 2 个 write_clk 推 1 个字 (20ns/字), 保证写FIFO不会溢出
    for (i = 0; i < N; i = i + 1) begin
        write_en   <= 1'b1;
        write_data <= {8'h00, i[7:0], i[15:8], i[23:16]};
        @(posedge write_clk);
        write_en   <= 1'b0;
        @(posedge write_clk);
    end
    t_last_push = $time;
    last_push_seen = 1'b1;
    $display("[%0t] 驱动侧已推完最后一个像素 (%0d 个字进写FIFO)", $time, N);

    // 等 write_finish
    wait (t_finish != 0);
    repeat (50) @(posedge mem_clk);

    $display("--------------------------------------------------");
    $display("SDRAM 实际接收字数    : %0d (期望 %0d)", wr_accepted, N);
    $display("t_last_push (推完最后字) : %0t", t_last_push);
    $display("t_finish    (整帧落盘)   : %0t", t_finish);
    $display("提前量 (旧判据的误差)    : %0t ns = %0.0f 个 mem_clk",
             t_finish - t_last_push, (t_finish - t_last_push) / 8.0);
    $display("write_finish 脉冲个数    : %0d", finish_pulses);

    if (wr_accepted == N && t_finish > t_last_push && finish_pulses == 1)
        $display("*** PASS: 写入完整, 且 write_finish 确实晚于最后一个 write_en ***");
    else
        $display("*** FAIL ***");
    $display("--------------------------------------------------");
    $finish;
end

initial begin
    #200_000_000;
    $display("*** TIMEOUT ***");
    $display("wr_accepted=%0d  t_finish=%0t  finish_pulses=%0d", wr_accepted, t_finish, finish_pulses);
    $finish;
end

endmodule
