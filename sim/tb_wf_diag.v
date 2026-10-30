`timescale 1ns/1ps
// ============================================================
// tb_wf_diag.v — 小帧快速定位 frame_fifo_write 卡死点
//
// tb_write_finish 跑 640x480 时，驱动侧推完 307200 个字后
// write_finish 一直不拉高（t=6.14ms 之后无进展），怀疑写状态机卡在
// S_CHECK_FIFO 等不到 into_burst。
//
// 本 TB 用 N = 2048 (8 个突发 x 256) 重现，并周期打印状态机内部量。
// ============================================================
module tb_wf_diag;

localparam W  = 640;
localparam H  = 480;
localparam N  = 2048;            // 8 * 256，小帧，几十微秒跑完

reg write_clk = 0;
reg mem_clk   = 0;
reg read_clk  = 0;
always #5   write_clk = ~write_clk;
always #4   mem_clk   = ~mem_clk;
always #20  read_clk  = ~read_clk;

reg  rst = 1'b1;

reg         write_req = 1'b0;
reg  [20:0] write_addr_0 = 21'd0;
reg         write_en = 1'b0;
reg  [31:0] write_data = 32'd0;
wire        write_req_ack;
wire        write_finish;

reg         read_req = 1'b0;
reg  [20:0] read_addr_0 = 21'd0;
reg         read_en = 1'b0;
wire        read_req_ack;
wire        read_finish;
wire [31:0] read_data;

wire        App_wr_en;
wire [20:0] App_wr_addr;
wire [31:0] App_wr_din;
wire [3:0]  App_wr_dm;
wire        App_rd_en;
wire [20:0] App_rd_addr;
wire        Sdr_rd_en;
wire [31:0] Sdr_rd_dout;

reg [31:0] mem [0:4095];
integer wr_accepted = 0;
integer pushed = 0;
reg     push_done = 1'b0;
time    t_finish = 0;

always @(posedge mem_clk) begin
    if (App_wr_en) wr_accepted = wr_accepted + 1;
end

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

always @(posedge mem_clk) if (!rst && write_finish && t_finish == 0) t_finish = $time;

// ---- 周期打印状态机内部量 ----
integer k = 0;
always @(posedge mem_clk) begin
    k = k + 1;
    if ((k % 200) == 0 && !rst) begin
        $display("t=%0t st=%0d wr_cnt=%0d len_latch=%0d rdusedw=%0d into_burst=%b Rdbusy=%b wr_req_d2=%b App_wr_en=%b | pushed=%0d landed=%0d fifo=%0d",
            $time,
            dut.frame_fifo_write_m0.state,
            dut.frame_fifo_write_m0.write_cnt,
            dut.frame_fifo_write_m0.write_len_latch,
            dut.rdusedw,
            dut.frame_fifo_write_m0.into_burst,
            dut.App_rd_busy,
            dut.frame_fifo_write_m0.write_req_d2,
            App_wr_en,
            pushed, wr_accepted, pushed - wr_accepted);
    end
end

frame_read_write #(
    .MEM_DATA_BITS (32), .READ_DATA_BITS(32), .WRITE_DATA_BITS(32),
    .ADDR_BITS(21), .BURST_BITS(9), .BURST_SIZE(256),
    .IMG_WIDTH(W), .IMG_HEIGHT(H), .ROW_REVERSE(1)
) dut (
    .rst(rst), .mem_clk(mem_clk),
    .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b1), .Sdr_busy(1'b0),
    .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
    .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
    .read_clk(read_clk), .read_req(read_req), .read_req_ack(read_req_ack),
    .read_finish(read_finish), .read_addr_0(read_addr_0),
    .read_addr_1(21'd0), .read_addr_2(21'd0), .read_addr_3(21'd0),
    .read_addr_index(2'd0), .read_len(N), .read_en(read_en), .read_data(read_data),
    .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr),
    .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
    .write_clk(write_clk), .write_req(write_req), .write_req_ack(write_req_ack),
    .write_finish(write_finish), .write_addr_0(write_addr_0),
    .write_addr_1(21'd0), .write_addr_2(21'd0), .write_addr_3(21'd0),
    .write_addr_index(2'd0), .write_len(N), .write_en(write_en), .write_data(write_data)
);

integer i;
initial begin
    repeat (40) @(posedge mem_clk);
    rst = 1'b0;
    repeat (20) @(posedge mem_clk);

    @(posedge write_clk);
    write_req = 1'b1;
    wait (write_req_ack == 1'b1);
    @(posedge write_clk);
    write_req = 1'b0;

    for (i = 0; i < N; i = i + 1) begin
        write_en   <= 1'b1;
        write_data <= i;
        @(posedge write_clk);
        write_en   <= 1'b0;
        @(posedge write_clk);
        pushed = pushed + 1;
    end
    push_done = 1'b1;
    $display(">>> [%0t] 推完 %0d 个字, 等 write_finish", $time, N);

    wait (t_finish != 0);
    repeat (50) @(posedge mem_clk);
    $display("--------------------------------------------------");
    $display("落进 SDRAM 字数 : %0d (期望 %0d)", wr_accepted, N);
    $display("write_finish 时刻: %0t", t_finish);
    if (wr_accepted == N && t_finish != 0)
        $display("*** PASS: 小帧写通了, 说明结构没问题 ***");
    else
        $display("*** FAIL: 写状态机卡住 (看上面最后几行 st/rdusedw/into_burst) ***");
    $display("--------------------------------------------------");
    $finish;
end

initial begin
    #2_000_000;
    $display("*** TIMEOUT 2ms ***  pushed=%0d landed=%0d t_finish=%0t", pushed, wr_accepted, t_finish);
    $display("最后状态: st=%0d wr_cnt=%0d len_latch=%0d rdusedw=%0d into_burst=%b Rdbusy=%b",
        dut.frame_fifo_write_m0.state,
        dut.frame_fifo_write_m0.write_cnt,
        dut.frame_fifo_write_m0.write_len_latch,
        dut.rdusedw,
        dut.frame_fifo_write_m0.into_burst,
        dut.App_rd_busy);
    $finish;
end

endmodule
