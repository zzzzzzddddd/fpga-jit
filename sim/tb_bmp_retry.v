`timescale 1ns/1ps
// ============================================================
// tb_bmp_retry.v — 验 bmp_read 的【重试机制】到底有没有用
// ============================================================
// 【为什么写这个】
//   上板现象：同一版位流，有时出完整图、有时只出三分之一、有时满屏噪点。
//   我据此在 bmp_read 里加了 S_RETRY + 看门狗，但那全是"推理"，没验证过。
//   而"还是没有图片"这句话有两种完全不同的解释，仿真能把它们分开：
//     (A) 重试逻辑本身写坏了（比如死锁、或者再也不发 open）—— 连正常路径都废了
//     (B) 重试逻辑是对的，只是卡那头一直没成功
//   这个 TB 就是回答这个问题：把 fat32_reader 换成一个**可控的假模型**，
//   故意让它前 N 次失败，看 bmp_read 能不能自己爬回来、把一整帧读完。
//
// 【这个 TB 覆盖 bmp_read 的哪些行为】
//   · 正常路径：open 成功 -> 翻译 -> 读头 -> 读像素 -> S_END，出满一帧
//   · open 失败一次后成功（S_OPEN_W !f_found -> S_RETRY -> 重开）★ 新增功能
//   · 簇链翻译报错一次后成功（S_XL_W f_xl_err -> S_RETRY -> 重开）★ 新增功能
//   · 每次进 S_RETRY，数码管显示码 D1 应当看到 7
//
// 【不覆盖】
//   · 看门狗（force_retry）：要等 WD_LIMIT = 5 秒 = 5e8 拍，仿真跑不动。
//     那一条只能靠代码审查（已确认 force_retry 必须进自己的清零条件，
//     否则 stuck_cnt 永远停在 WD_LIMIT、状态机卡死在重开 open 那一支）。
//
// 【假模型的行为】
//   fat32_reader：收到 f_open_req 后等 20 拍，回 f_open_done；
//                 f_found = (本次是第几次 open) > FAIL_OPEN
//                 收到 f_xl_req 后 1 拍回 f_xl_valid，f_xl_lba = 16000 + sec_idx
//   SD 卡：sd_sec_read 高时按《文件内字节偏移》吐 512 字节，末尾给 read_end。
//          合成扇区里 byte[i] = i & 0xFF，头 54 字节按 BMP 规范填好，
//          于是第 n 个像素的期望值可以算出来（见 expect_px）。
//
// 【跑法】iverilog 在 D:\iverilog\bin
//   cd sim
//   iverilog -g2005-sv -o tb_retry.vvp -s tb_bmp_retry ../src/bmp_read.v tb_bmp_retry.v
//   vvp tb_retry.vvp                     -> 干净路径
//   vvp tb_retry.vvp +fail_open=1        -> 头一次 open 报 "没找到"
//   vvp tb_retry.vvp +fail_xl=1          -> 头一次翻译报 f_xl_err
// ============================================================
module tb_bmp_retry;

localparam OFF   = 54;          // pixel_offset
localparam NPIX  = 100;         // 合成图只放 100 个像素（一个扇区装得下）
localparam FLEN  = OFF + 3*NPIX;// file_len = 354，正好在这一个扇区里结束
localparam SBASE = 32'd16000;   // 假 fat32 翻译出来的 LBA

reg clk = 0, rst = 1;
always #5 clk = ~clk;           // 100MHz

// ---- 脚本参数 ----
integer FAIL_OPEN = 0;          // 前几次 open 报 found=0
integer FAIL_XL   = 0;          // 前几次翻译报 f_xl_err
integer GIVEUP    = 0;          // 1 = 先让第一轮试满并放弃，再发一次 find

// ---- DUT 端口 ----
reg         find      = 0;
reg  [2:0]  img_index = 3'd1;
reg         sd_init_done = 0;
reg  [15:0] bmp_width = 16'd640;
reg         write_req_ack = 0;
reg         f_open_done = 0;
reg         f_found     = 0;
reg         f_xl_valid  = 0;
reg  [31:0] f_xl_lba    = 0;
reg         f_xl_err    = 0;

wire [3:0]  state_code;
wire        write_req;
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [23:0] bmp_data;
wire        bmp_data_wr_en;
wire        f_open_req;
wire [3:0]  f_file_idx;
wire        f_xl_req;
wire [31:0] f_xl_sec_idx;
wire        ready;

bmp_read dut (
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (ready),
    .find                   (find),
    .img_index              (img_index),
    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (dout),
    .sd_sec_read_data_valid (dvalid),
    .sd_sec_read_end        (dend),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .f_open_req             (f_open_req),
    .f_file_idx             (f_file_idx),
    .f_open_done            (f_open_done),
    .f_found                (f_found),
    .f_xl_req               (f_xl_req),
    .f_xl_sec_idx           (f_xl_sec_idx),
    .f_xl_valid             (f_xl_valid),
    .f_xl_lba               (f_xl_lba),
    .f_xl_err               (f_xl_err)
);

// ============================================================
// 合成扇区：byte[i] = i & 0xFF，头 54 字节按 BMP 规范覆盖
// ============================================================
reg [7:0] sector [0:511];
initial begin
    integer i;
    for (i = 0; i < 512; i = i + 1) sector[i] = i & 8'hFF;
    sector[0] = "B"; sector[1] = "M";
    // file_len (2..5) 小端（FLEN=354 -> 62 01 00 00）
    sector[2] = FLEN; sector[3] = FLEN >> 8;
    sector[4] = 0;                    sector[5] = 0;
    // pixel_offset (10..13) = 54
    sector[10] = OFF; sector[11] = 0; sector[12] = 0; sector[13] = 0;
    // width (18..21) = 640
    sector[18] = 8'h80; sector[19] = 8'h02; sector[20] = 0; sector[21] = 0;
    // height (22..25) = 480
    sector[22] = 8'hE0; sector[23] = 8'h01; sector[24] = 0; sector[25] = 0;
    // bit_count (28..29) = 24
    sector[28] = 8'd24; sector[29] = 0;
    // compression (30..33) = 0
    sector[30] = 0; sector[31] = 0; sector[32] = 0; sector[33] = 0;
end

// 第 n 个像素的期望值：{R,G,B} = {byte[54+3n+2], byte[54+3n+1], byte[54+3n]}
function [23:0] expect_px;
    input integer n;
    reg [7:0] b, g, r;
    begin
        b = (OFF + n*3 + 0) & 8'hFF;
        g = (OFF + n*3 + 1) & 8'hFF;
        r = (OFF + n*3 + 2) & 8'hFF;
        expect_px = {r, g, b};
    end
endfunction

// ============================================================
// 假 SD 卡：sd_sec_read 高时流式吐一个扇区
// ============================================================
reg [8:0]  bc;
reg [2:0]  st;
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
            dout   <= (sd_sec_read_addr == SBASE) ? sector[bc] : 8'h00;
            dvalid <= 1'b1;
            if (bc == 9'd511) st <= 3'd2;
            else              bc <= bc + 9'd1;
        end
        3'd2: begin
            dend <= 1'b1;
            bc   <= 9'd0;
            st   <= 3'd1;
        end
        default: st <= 3'd0;
    endcase
end

// ============================================================
// 假 fat32_reader
// ============================================================
integer open_cnt = 0;           // 已经回了几次 open_done
integer xl_cnt   = 0;           // 已经回了几次 xl_valid
reg [5:0] open_dly = 6'd0;
reg       open_pending = 1'b0;
integer   retry_seen = 0;       // 进过几次 S_RETRY（state_code == 7）

always @(posedge clk) begin
    f_open_done <= 1'b0;
    f_xl_valid  <= 1'b0;
    if (rst) begin
        open_dly     <= 6'd0;
        open_pending <= 1'b0;
        open_cnt     <= 0;
        xl_cnt       <= 0;
        retry_seen   <= 0;
        f_found      <= 1'b0;
        f_xl_err     <= 1'b0;
        f_xl_lba     <= 32'd0;
    end else begin
        // ---- open：收到 req 后延迟 20 拍再回 ----
        if (f_open_req && !open_pending && open_dly == 6'd0) begin
            open_dly     <= 6'd20;
            open_pending <= 1'b1;
        end else if (open_dly != 6'd0) begin
            open_dly <= open_dly - 6'd1;
            if (open_dly == 6'd1) begin
                f_open_done  <= 1'b1;
                // 第 (open_cnt+1) 次 open；前 FAIL_OPEN 次报"没找到"
                f_found      <= ((open_cnt + 1) > FAIL_OPEN);
                open_cnt     <= open_cnt + 1;
                open_pending <= 1'b0;
            end
        end
        // ---- 翻译：1 拍就回 ----
        if (f_xl_req) begin
            f_xl_valid <= 1'b1;
            f_xl_lba   <= SBASE + f_xl_sec_idx;
            f_xl_err   <= ((xl_cnt + 1) <= FAIL_XL);   // 前 FAIL_XL 次报错
            xl_cnt     <= xl_cnt + 1;
        end
        // ---- 看 S_RETRY（D1 显示码 7）进过几次 ----
        if (state_code == 4'd7) retry_seen <= retry_seen + 1;
    end
end

// ---- 应答 write_req（模拟 frame_fifo_write 的 S_ACK）----
always @(posedge clk) begin
    if (rst) write_req_ack <= 1'b0;
    else     write_req_ack <= write_req && !write_req_ack;
end

// ============================================================
// 检查
// ============================================================
integer pix_cnt = 0;
integer err_cnt = 0;
reg [23:0] exp;
integer frame_done_cnt = 0;
reg [3:0] code_d;
reg       done = 0;

always @(posedge clk) begin
    code_d <= state_code;
    if (!rst) begin
        // 与 top.v 的 frame_done 判据一致：4(读完) -> 1(空闲)
        if (state_code == 4'd1 && code_d == 4'd4) frame_done_cnt <= frame_done_cnt + 1;
        if (bmp_data_wr_en) begin
            exp = expect_px(pix_cnt);
            if (bmp_data !== exp) begin
                if (err_cnt < 5)
                    $display("  ERROR 第%0d个像素: 得到 (%02h,%02h,%02h) 期望 (%02h,%02h,%02h)",
                        pix_cnt, bmp_data[23:16], bmp_data[15:8], bmp_data[7:0],
                        exp[23:16], exp[15:8], exp[7:0]);
                err_cnt <= err_cnt + 1;
            end
            pix_cnt <= pix_cnt + 1;
        end
    end
end

// ============================================================
// 激励
// ============================================================
initial begin
    if (!$value$plusargs("fail_open=%d", FAIL_OPEN)) FAIL_OPEN = 0;
    if (!$value$plusargs("fail_xl=%d",   FAIL_XL))   FAIL_XL   = 0;
    if (!$value$plusargs("giveup=%d",    GIVEUP))    GIVEUP    = 0;
    if (GIVEUP) FAIL_OPEN = 8;      // 前 8 次 open 全失败 = 正好试满 FAIL_MAX
    $display("==================================================");
    $display("场景: FAIL_OPEN=%0d  FAIL_XL=%0d  GIVEUP=%0d",
             FAIL_OPEN, FAIL_XL, GIVEUP);
    $display("==================================================");

    repeat (10) @(posedge clk);
    rst = 1'b0; sd_init_done = 1'b1;
    repeat (5) @(posedge clk);

    @(posedge clk); find = 1'b1;
    @(posedge clk); find = 1'b0;

    // ---- 第二轮（+giveup=1）：等第一轮放弃（回 S_IDLE）后再发一次 find ----
    //   这一条验的是【最关键的回归】：
    //   无界重试会让 bmp_read 永远不回 S_IDLE，于是 ready 恒 0，
    //   sd_card_bmp 的 find_go 永远发不出来 —— 用户再怎么切页都进不来。
    //   正确行为：试满 FAIL_MAX 次 -> 放弃回 S_IDLE -> 新的 find 能立刻被接受。
    if (GIVEUP) begin
        wait (open_cnt >= 8 && state_code == 4'd1);
        $display("  [give-up] 已放弃并回到 S_IDLE (open_cnt=%0d)，现在再发一次 find", open_cnt);
        repeat (5) @(posedge clk);
        @(posedge clk); find = 1'b1;
        @(posedge clk); find = 1'b0;
    end

    // 等 frame_done（或超时）—— 重试要等 RETRY_WAIT = 5e6 拍，给足时间。
    // ★ 单位坑：这个 TB 里 $time 的数值是【ps】不是 ns ★
    //   （timescale 是 1ns/1ps，但 $time 按精度 1ps 计数）
    //   写成 300_000_000 其实是 300us —— 第一轮重试就要 35ms，
    //   结果 wait 一到就立刻放行，把第二轮的 find 还没跑完就判了 FAIL。
    wait (frame_done_cnt >= 1 || $time > 500_000_000_000);

    repeat (20) @(posedge clk);
    done = 1;

    $display("--------------------------------------------------");
    $display("  抓到像素        = %0d  (期望 %0d)", pix_cnt, NPIX);
    $display("  像素值错误      = %0d", err_cnt);
    $display("  frame_done 次数 = %0d  (期望 >= 1)", frame_done_cnt);
    $display("  S_RETRY 进入次数= %0d  (D1 显示码 7)", retry_seen);
    $display("  假 fat32: open 请求回来 %0d 次, 翻译请求回来 %0d 次", open_cnt, xl_cnt);
    $display("--------------------------------------------------");
    if (err_cnt == 0 && pix_cnt == NPIX && frame_done_cnt >= 1)
        $display("*** PASS: 一整帧读完，像素全对 ***");
    else if (frame_done_cnt == 0)
        $display("*** FAIL: 从来没读完过一帧 —— bmp_read 卡死了 ***");
    else
        $display("*** FAIL: 帧读完了但内容/数量不对 ***");
    $display("--------------------------------------------------");
    $finish;
end

// 硬超时
initial begin
    #400_000_000;
    $display("*** TIMEOUT *** pix=%0d state_code=%0d sec_idx=%0d open_cnt=%0d xl_cnt=%0d",
             pix_cnt, state_code, dut.sec_idx, open_cnt, xl_cnt);
    $finish;
end

endmodule
