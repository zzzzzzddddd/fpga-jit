`timescale 1ns/1ps
// ============================================================
// tb_bmp_read.v — 验证 bmp_read 的 BGR->RGB 装配是否错位
//
// 构造一个假的 BMP 放在扇区 16000：
//   头 54 字节，pixel_offset=54, width=640, height=480, bit_count=24/32
//   像素字节 byte[54+i] = i & 0xFF   （有规律，便于反推）
//
// 期望：第 n 个像素输出 bmp_data = {R,G,B} = {byte[54+3n+2], byte[54+3n+1], byte[54+3n]}
// 错位时（pixel_data_start 归零 bug）会变成 {B_next, R, G}
//
// 运行（Icarus）：
//   iverilog -g2005 -o tb_bmp.vvp -s tb_bmp_read ../src/bmp_read.v tb_bmp_read.v
//   vvp tb_bmp.vvp                 -> 24位
//   ... -DBMP32 ...                -> 32位
//   ... -DPROBE  ...               -> 附带内部量打印
//
// 结论（已跑通）：
//   24位 24/24 正确、32位 24/24 正确；
//   把 bmp_len_cnt_tmp 的强制值改回 2'd0（旧 bug）后两个位深都立刻 FAIL，
//   且错误值恰好整体后移 1 字节 -> 证实就是那一处差一错误。
// ============================================================
module tb_bmp_read;

`ifdef BMP32
localparam BPP = 32;
`else
localparam BPP = 24;
`endif

localparam SB  = (BPP == 32) ? 4 : 3;   // 每像素字节步进(BMP 行内实际字节数)
localparam OFF = 54;                    // pixel_offset

reg clk = 0, rst = 1;
always #5 clk = ~clk;               // 100MHz

reg  find = 0;
reg  sd_init_done = 0;
reg  write_req_ack = 0;
wire [3:0]  state_code;
wire        write_req;
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [23:0] bmp_data;
wire        bmp_data_wr_en;

reg [7:0] sector0 [0:511];

integer pix_cnt = 0;
integer err_cnt = 0;
integer i;

// 期望值：第 n 个像素
function [23:0] expect_px;
    input integer n;
    reg [7:0] b,g,r;
    begin
        b = (OFF + n*SB + 0) & 8'hFF;
        g = (OFF + n*SB + 1) & 8'hFF;
        r = (OFF + n*SB + 2) & 8'hFF;
        expect_px = {r, g, b};
    end
endfunction

// ---- 假 SD 卡：流式返回扇区字节 ----
reg [8:0]  bc;
reg [2:0]  st;                      // 0=IDLE 1=LOAD 2=END
reg [7:0]  dout;
reg        dvalid, dend;

always @(posedge clk) begin
    dvalid <= 1'b0;
    dend   <= 1'b0;
    if (rst) begin
        st <= 3'd0; bc <= 9'd0;
    end else if (!sd_sec_read) begin
        // 请求撤了必须立刻停：否则 DUT 在 S_READ_WAIT 期间模型还在吐字节，
        // 等 S_READ 开始计数时已经错过前面几个字节 -> 整体错位（TB 伪影）
        st <= 3'd0; bc <= 9'd0;
    end else case (st)
        3'd0: begin bc <= 9'd0; st <= 3'd1; end
        3'd1: begin
            dout   <= (sd_sec_read_addr == 32'd16000) ? sector0[bc] : 8'h00;
            dvalid <= 1'b1;
            if (bc == 9'd511) st <= 3'd2;
            else              bc <= bc + 9'd1;
        end
        3'd2: begin
            dend <= 1'b1;
            bc   <= 9'd0;
            st   <= 3'd1;               // 若 sd_sec_read 仍高则接着下一扇区
        end
        default: st <= 3'd0;
    endcase
end

assign sd_sec_read_data       = dout;
assign sd_sec_read_data_valid = dvalid;
assign sd_sec_read_end        = dend;

// ---- DUT ----
bmp_read #(
    .IMG_GAP_LIMIT (32'd4096),
    .BMP_HEIGHT    (16'd480)
) dut (
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (),
    .find                   (find),
    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (16'd640),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (dout),
    .sd_sec_read_data_valid (dvalid),
    .sd_sec_read_end        (dend),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

// ---- 应答 write_req（模拟 frame_fifo_write 的 S_ACK）----
always @(posedge clk) begin
    if (rst) write_req_ack <= 1'b0;
    else     write_req_ack <= write_req && !write_req_ack;
end

// ---- 检查输出 ----
reg [23:0] exp;
always @(posedge clk) begin
    if (!rst && bmp_data_wr_en) begin
        exp = expect_px(pix_cnt);
        if (bmp_data !== exp) begin
            if (err_cnt < 8)
                $display("[%0t] ERROR 第%0d个像素: 得到 (%02h,%02h,%02h)=%06h, 期望 (%02h,%02h,%02h)=%06h",
                    $time, pix_cnt,
                    bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], bmp_data,
                    exp[23:16], exp[15:8], exp[7:0], exp);
            err_cnt = err_cnt + 1;
        end
        pix_cnt = pix_cnt + 1;
        if (pix_cnt >= 24) begin
            $display("--------------------------------------------------");
            $display("BPP=%0d  抓到 %0d 个像素, 错误 %0d 个", BPP, pix_cnt, err_cnt);
            if (err_cnt == 0)
                $display("*** PASS: BGR->RGB 装配正确 (R,G,B 顺序无误) ***");
            else
                $display("*** FAIL: 通道错位 ***");
            $display("--------------------------------------------------");
            $finish;
        end
    end
end

// ---- 探针（只在 -DPROBE 时打开）----
`ifdef PROBE
always @(posedge clk) begin
    if (!rst && dut.state == 4'd3 && dut.bmp_len_cnt >= 32'd50 && dut.bmp_len_cnt <= 32'd62)
        $display("  [probe] len=%0d cnt=%0d dv=%b data=%02h wr=%b -> bmp=%06h",
            dut.bmp_len_cnt, dut.bmp_len_cnt_tmp, sd_sec_read_data_valid,
            dout, bmp_data_wr_en, bmp_data);
end
`endif

// ---- 激励 ----
initial begin
    // 构造假 BMP 头
    for (i = 0; i < 512; i = i + 1) sector0[i] = (i & 8'hFF);
    sector0[0]  = "B"; sector0[1] = "M";
    // file_len (offset 2..5) = 很大，保证不会提前结束
    sector0[2]  = 8'h00; sector0[3] = 8'h00; sector0[4] = 8'h10; sector0[5] = 8'h00;
    // pixel_offset = 54 (offset 10..13)
    sector0[10] = 8'd54; sector0[11] = 8'h00; sector0[12] = 8'h00; sector0[13] = 8'h00;
    // width = 640 (18..21)
    sector0[18] = 8'h80; sector0[19] = 8'h02; sector0[20] = 8'h00; sector0[21] = 8'h00;
    // height = 480 (22..25)
    sector0[22] = 8'hE0; sector0[23] = 8'h01; sector0[24] = 8'h00; sector0[25] = 8'h00;
    // bit_count = 24 或 32 (28..29)
    sector0[28] = BPP[7:0]; sector0[29] = 8'h00;
    // compression = 0 (30..33)
    sector0[30] = 8'h00; sector0[31] = 8'h00; sector0[32] = 8'h00; sector0[33] = 8'h00;

    repeat (10) @(posedge clk);
    rst = 1'b0; sd_init_done = 1'b1;
    repeat (5) @(posedge clk);

    @(posedge clk); find = 1'b1;
    @(posedge clk); find = 1'b0;
end

initial begin
    #500_000;
    $display("*** TIMEOUT *** 已出像素=%0d  state_code=%0d  sec_addr=%0d",
             pix_cnt, state_code, sd_sec_read_addr);
    $finish;
end

endmodule
