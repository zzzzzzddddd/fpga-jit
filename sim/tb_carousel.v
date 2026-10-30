`timescale 1ns/1ps
// ============================================================
// tb_carousel.v — 验证"张数无上限 + 正常绕回"的轮播
//
// 假 SD 卡上连续摆 M 张图：第 k 张占扇区 16000+8k .. 16000+8k+7
// (每张 8 扇区 = 4096 字节, 刚好让 S_READ 推进后能被 S_IDLE 对齐到 8 扇区边界,
//  与真实卡上"簇对齐"的排布一致)
//
// 每张图的所有像素字节都填成 k, 所以看像素值就知道在读第几张图。
//
// 期望: 读图顺序 = 0,1,2,0,1,2,... 一直循环下去 (旧代码读满4张就绕回,
//       且张数写死; 新代码由"扫描到底"自然绕回, 张数无上限)
//
// 运行:
//   iverilog -g2005 -o tb_car.vvp -s tb_carousel ../src/bmp_read.v tb_carousel.v
//   vvp tb_car.vvp
// ============================================================
module tb_carousel;

localparam M         = 6;         // 卡上图片张数(故意 >4, 跨过旧的 MAX_BMP_NUM 界限)
localparam IMG_BYTES = 4096;      // 每张图字节数(8扇区)
localparam IMG_SECS  = IMG_BYTES / 512;
localparam BASE_SEC  = 16000;     // 第一张图所在扇区

reg clk = 0, rst = 1;
always #5 clk = ~clk;             // 100MHz

reg  find = 0;
reg  sd_init_done = 0;
reg  write_req_ack = 0;
wire [3:0]  state_code;
wire        write_req;
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
reg  [7:0]  dout;
wire        bmp_data_wr_en;
wire [23:0] bmp_data;
wire        unused_ready;
wire [23:0] unused_w;

// ---- 构造假图片内容 ----
reg [7:0] img [0:M*IMG_BYTES-1];
integer kk, jj;
initial begin
    for (kk = 0; kk < M; kk = kk + 1) begin
        for (jj = 0; jj < IMG_BYTES; jj = jj + 1)
            img[kk*IMG_BYTES + jj] = 8'h00;
        img[kk*IMG_BYTES + 0]  = "B";
        img[kk*IMG_BYTES + 1]  = "M";
        img[kk*IMG_BYTES + 3]  = 8'h10;   // file_len = 0x1000 = 4096
        img[kk*IMG_BYTES + 10] = 8'd54;   // pixel_offset
        img[kk*IMG_BYTES + 18] = 8'h80;
        img[kk*IMG_BYTES + 19] = 8'h02;   // width = 640
        img[kk*IMG_BYTES + 22] = 8'hE0;
        img[kk*IMG_BYTES + 23] = 8'h01;   // height = 480
        img[kk*IMG_BYTES + 28] = 8'd24;   // bit_count = 24
        for (jj = 54; jj < IMG_BYTES; jj = jj + 1)
            img[kk*IMG_BYTES + jj] = kk[7:0];   // 像素值 = 图片序号
    end
end

// 扇区 a 的第 off 个字节。若该扇区落在某张图里就返回图片内容，否则返回 0
// (0 开头 -> 永远不会误判成 'B','M' 头部)
function [7:0] byte_at;
    input [31:0] a;
    input [8:0]  off;
    integer rel, k, s;
    begin
        byte_at = 8'h00;
        if (a >= BASE_SEC) begin
            rel = a - BASE_SEC;
            k   = rel / 8;          // 哪一张图(按 8 扇区分块)
            s   = rel % 8;          // 该图内第几个扇区
            if (k < M)
                byte_at = img[k*IMG_BYTES + s*512 + off];
        end
    end
endfunction

// ---- 假 SD 卡: 流式返回扇区字节 ----
reg [8:0] bc;
reg [2:0] st;
reg       sdv, sden;

always @(posedge clk) begin
    sdv  <= 1'b0;
    sden <= 1'b0;
    if (rst) begin
        st <= 3'd0; bc <= 9'd0;
    end else if (!sd_sec_read) begin
        st <= 3'd0; bc <= 9'd0;      // 请求撤了立刻停
    end else case (st)
        3'd0: begin bc <= 9'd0; st <= 3'd1; end
        3'd1: begin
            dout <= byte_at(sd_sec_read_addr, bc);
            sdv  <= 1'b1;
            if (bc == 9'd511) st <= 3'd2;
            else              bc <= bc + 9'd1;
        end
        3'd2: begin sden <= 1'b1; bc <= 9'd0; st <= 3'd3; end
        // 空一拍: DUT 在 sden 那一拍才改写 sd_sec_read_addr, 而本 TB 的
        // byte_at(sd_sec_read_addr,..) 是组合的。不隔这一拍就会用旧地址取
        // 新扇区的第 0 个字节 -> 头部误判。真实 SD 控制器走 CMD17, 地址早就稳了。
        3'd3: begin bc <= 9'd0; st <= 3'd1; end
        default: st <= 3'd0;
    endcase
end
assign sd_sec_read_data       = dout;
assign sd_sec_read_data_valid = sdv;
assign sd_sec_read_end        = sden;

// ---- DUT ----
bmp_read dut (
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (unused_ready),
    .find                   (find),
    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (16'd640),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (dout),
    .sd_sec_read_data_valid (sdv),
    .sd_sec_read_end        (sden),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

always @(posedge clk) begin
    if (rst) write_req_ack <= 1'b0;
    else     write_req_ack <= write_req && !write_req_ack;
end

// ---- 记录每张被读出来的图 ----
localparam NFRAME = 9;           // 看 9 帧, 期望 0..5 后再回到 0,1,2
reg [7:0] got [0:NFRAME-1];
reg [7:0] last_val = 8'hFF;
integer   fcnt = 0;
integer   err  = 0;
integer   n;
integer   frames_done;

always @(posedge clk) begin
    if (!rst && bmp_data_wr_en) begin
        if (bmp_data[7:0] !== last_val) begin
            // 一帧内所有像素同值, 所以"值变化"=新的一帧开始
            last_val = bmp_data[7:0];
            if (fcnt < NFRAME) begin
                got[fcnt] = bmp_data[7:0];
                $display(">>> [%0t] 第%0d帧: 读到图片 #%0d  (R,G,B = %02h,%02h,%02h)  addr=%0d",
                    $time, fcnt, bmp_data[7:0],
                    bmp_data[23:16], bmp_data[15:8], bmp_data[7:0],
                    sd_sec_read_addr);
                if (bmp_data[23:16] !== bmp_data[7:0] || bmp_data[15:8] !== bmp_data[7:0])
                    $display("    !! 通道不一致 R/G/B=%02h/%02h/%02h",
                        bmp_data[23:16], bmp_data[15:8], bmp_data[7:0]);
            end
            fcnt = fcnt + 1;
            if (fcnt >= NFRAME) begin
                $display("--------------------------------------------------");
                err = 0;
                for (n = 0; n < NFRAME; n = n + 1) begin
                    if (got[n] !== (n % M)) begin
                        $display("  第%0d帧 期望 #%0d 实际 #%0d  <-- 不对", n, n % M, got[n]);
                        err = err + 1;
                    end
                end
                $write("读图序列: ");
                for (n = 0; n < NFRAME; n = n + 1) $write("%0d ", got[n]);
                $write("  (期望 ");
                for (n = 0; n < NFRAME; n = n + 1) $write("%0d ", n % M);
                $display(")");
                if (err == 0)
                    $display("*** PASS: 连续 %0d 张图, 绕回正常, 张数无上限 ***", M);
                else
                    $display("*** FAIL: 轮播序列错误 (%0d 处) ***", err);
                $display("--------------------------------------------------");
                $finish;
            end
        end
    end
end

// ---- 搜索轨迹：只打印绕回附近的探测 (-DTRACE 打开) ----
`ifdef TRACE
always @(posedge clk) begin
    if (!rst && dut.state == 4'd1 && sden &&
        (sd_sec_read_addr < 32'd16024 || sd_sec_read_addr > 32'd20104))
        $display("    [search] 探测 %0d  found=%b  rd_cnt=%0d hdr=%02h%02h width=%0d",
                 sd_sec_read_addr, dut.found, dut.rd_cnt,
                 dut.header_0, dut.header_1, dut.width);
end
`endif

// ---- 激励: 空闲就立刻触发下一次搜索(相当于轮播) ----
initial begin
    repeat (10) @(posedge clk);
    rst = 1'b0;
    sd_init_done = 1'b1;
    repeat (5) @(posedge clk);
    find = 1'b1;                  // 一直触发, 连续轮播
end

initial begin
    #20_000_000;
    $display("*** TIMEOUT 20ms *** 已读帧数=%0d state_code=%0d addr=%0d",
             fcnt, state_code, sd_sec_read_addr);
    $finish;
end

endmodule
