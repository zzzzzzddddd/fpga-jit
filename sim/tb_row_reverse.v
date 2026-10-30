`timescale 1ns/1ps
// ============================================================
// tb_row_reverse.v — 验证 frame_fifo_read 的 ROW_REVERSE 行倒序寻址
//
// 背景：BMP 像素是 bottom-to-top 存储的，写 SDRAM 时按线性地址
//       （BMP第0行 -> 地址 base+0，第1行 -> base+640，...）。
//       显示必须从 BMP 的"最后一行"(=图像顶部) 开始读，逐行递减，
//       否则图像上下颠倒。
//
// 本 TB 直接用 wrusedw=0 骗过 FIFO 水位判断，让读状态机连续突发，
// 抓取 App_rd_en 有效时的 App_rd_addr 序列，检查：
//   1) 地址序列恰好覆盖 [base, base+W*H) 每个地址一次，无重复无遗漏
//   2) 顺序确实是"行倒序、行内正序"：base+(H-1)*W ... base+(H-2)*W ...
//
// 运行：iverilog -o tb_row_reverse.vvp tb_row_reverse.v ../src/frame_fifo_read.v
//       vvp tb_row_reverse.vvp
// ============================================================
module tb_row_reverse;

localparam W = 640;
localparam H = 480;
localparam N = W*H;            // 307200
localparam AB = 21;
localparam BASE = 24'd0;

reg         mem_clk = 0;
reg         rst;
reg  [9:0]  wrusedw = 10'd0;      // 0 => 读FIFO永远"有空间"
reg         read_req;
wire        read_req_ack;
reg  [AB-1:0] read_addr_0 = BASE;
wire [AB-1:0] App_rd_addr;
wire        App_rd_en;

integer     i;
integer     addr_cnt = 0;         // App_rd_en 计数
integer     err_cnt  = 0;

// 覆盖位图：每个地址是否被访问过
reg seen [0:N-1];
integer k;
initial for (k = 0; k < N; k = k + 1) seen[k] = 1'b0;

// 行倒序时，第 n 次读操作期望的地址
//   第 r 行 (r=0..H-1 表示显示的第 r 行) 对应 BMP 文件第 (H-1-r) 行
//   期望地址 = base + (H-1-r)*W + c
function [AB-1:0] expect_addr;
    input integer n;              // 第 n 个像素 (0..N-1)
    integer r, c;
    begin
        r = n / W;
        c = n % W;
        expect_addr = BASE + (H-1-r)*W + c;
    end
endfunction

always #4 mem_clk = ~mem_clk;     // 125MHz

frame_fifo_read #(
    .MEM_DATA_BITS (32),
    .ADDR_BITS     (AB),
    .BURST_BITS    (9),
    .FIFO_DEPTH    (512),
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
    .Sdr_rd_en      (1'b0),
    .App_wr_busy    (1'b0),
    .O_rd_busy      (),
    .App_rd_en      (App_rd_en),
    .App_rd_addr    (App_rd_addr),
    .read_req       (read_req),
    .read_req_ack   (read_req_ack),
    .read_finish    (read_finish),
    .read_addr_0    (read_addr_0),
    .read_addr_1    (24'd0),
    .read_addr_2    (24'd0),
    .read_addr_3    (24'd0),
    .read_addr_index(2'd0),
    .read_len       (N),
    .fifo_aclr      (),
    .wrusedw        (wrusedw)
);

wire read_finish;

// ---- 抓地址 ----
always @(posedge mem_clk) begin
    if (!rst && App_rd_en) begin
        if (App_rd_addr >= BASE && App_rd_addr < BASE + N) begin
            if (seen[App_rd_addr - BASE]) begin
                if (err_cnt < 20)
                    $display("[%0t] ERROR: 地址 %0d 重复访问 (第 %0d 次)", $time, App_rd_addr, addr_cnt);
                err_cnt = err_cnt + 1;
            end
            seen[App_rd_addr - BASE] = 1'b1;

            if (App_rd_addr !== expect_addr(addr_cnt)) begin
                if (err_cnt < 20)
                    $display("[%0t] ERROR: 第 %0d 个地址 = %0d, 期望 %0d",
                             $time, addr_cnt, App_rd_addr, expect_addr(addr_cnt));
                err_cnt = err_cnt + 1;
            end
        end else begin
            $display("[%0t] ERROR: 地址 %0d 越界 [%0d,%0d)", $time, App_rd_addr, BASE, BASE+N);
            err_cnt = err_cnt + 1;
        end
        addr_cnt = addr_cnt + 1;
    end
end

// ---- 激励 ----
initial begin
    rst      = 1'b1;
    read_req = 1'b0;
    repeat (20) @(posedge mem_clk);
    rst = 1'b0;
    repeat (10) @(posedge mem_clk);

    // VS 沿触发一次整帧读
    @(posedge mem_clk);
    read_req = 1'b1;
    wait (read_req_ack == 1'b1);
    @(posedge mem_clk);
    read_req = 1'b0;

    // 等整帧读完
    wait (read_finish == 1'b1);
    repeat (20) @(posedge mem_clk);

    $display("--------------------------------------------------");
    $display("抓到 App_rd_en 次数 : %0d (期望 %0d)", addr_cnt, N);
    $display("错误数              : %0d", err_cnt);

    // 遗漏检查
    begin
        integer miss;
        miss = 0;
        for (k = 0; k < N; k = k + 1)
            if (!seen[k]) miss = miss + 1;
        if (miss != 0) begin
            $display("ERROR: 有 %0d 个地址从未被访问", miss);
            err_cnt = err_cnt + 1;
        end
    end

    if (addr_cnt == N && err_cnt == 0)
        $display("*** PASS: ROW_REVERSE 行倒序寻址覆盖完整且顺序正确 ***");
    else
        $display("*** FAIL ***");
    $display("--------------------------------------------------");
    $finish;
end

initial begin
    #60_000_000;
    $display("*** TIMEOUT ***");
    $finish;
end

endmodule
