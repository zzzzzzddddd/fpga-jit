`timescale 1ns/1ps
// ============================================================
// tb_carousel_real.v — 用【真实卡几何】验证轮播搜索
//
// 旧 tb_carousel.v 的毛病：每张图只占 8 扇区(4096字节)，于是
//   S_READ 读完 8 扇区 -> addr = start+8 -> S_IDLE 对齐后【正好等于下一张图的首扇区】，
//   搜索第一步就命中。这是退化情况，掩盖了"对齐后还要 +8 步进才追得上下一张"的真实过程。
//
// 本 TB 换成真实结构(等比缩小，省仿真时间)：
//   bfSize   FL    = 4980 字节  -> S_READ 读 ceil(4980/512) = 10 个扇区
//   卡上占位 SECS  = 16 个扇区  (簇对齐, 比文件实际字节数大, 和真卡一致)
//   -> 读完后 addr = start+10, S_IDLE 对齐到 start+8 (还落在【本张图内部】)
//   -> 必须再 +8 才能走到下一张图的首扇区 start+16
//
// SD 控制器时序照抄 sd_card_sec_read_write.v：
//   sden(state==S_READ_END) 一拍 -> S_WAIT_READ_WRITE 一拍 -> 才锁存 sec_addr 进 CMD17
// 所以取数用【锁存的 sec_addr】，不是 DUT 的活地址。
// (旧 TB 用活地址，才会看到"旧地址第0字节"的假象，需要一个 3'd3 空拍去遮。)
//
// 运行(Icarus)：
//   iverilog -g2005 -o tb_cr.vvp -s tb_carousel_real ../src/bmp_read.v tb_carousel_real.v
//   vvp tb_cr.vvp                -> GAP=8  (图挨着图, 正常卡)
//   iverilog -g2005 -DGAP=300 ... -> 两张图之间夹了别的东西
// ============================================================
module tb_carousel_real;

`ifdef GAP
localparam GAP = `GAP;
`else
localparam GAP = 8;
`endif

`ifdef BASE
localparam BASE_SEC = `BASE;                     // 第一张图所在扇区(测"离16000很远")
`else
localparam BASE_SEC = 16000;
`endif

localparam FL        = 4980;                     // bfSize = 54 + 3*1642
localparam IMG_SECS  = 16;                       // 一张图在卡上占的扇区(簇对齐占位)
localparam STRIDE    = IMG_SECS + GAP;           // 相邻两张图首扇区之差
localparam M         = 6;                        // 卡上图片张数(>4, 跨过旧 MAX_BMP_NUM)

reg clk = 0, rst = 1;
always #5 clk = ~clk;                            // 100MHz

// ---- 图片内容: 过程式生成 ----
function [7:0] img_byte;
    input integer k;
    input integer fo;
    begin
        if (fo >= FL)
            img_byte = 8'h00;                    // 簇尾填充(不是图像数据)
        else if (fo < 54) begin
            case (fo)
                8'd0 : img_byte = "B";
                8'd1 : img_byte = "M";
                // bfSize = 4980 = 0x00001374 (小端)
                8'd2 : img_byte = 8'h74;
                8'd3 : img_byte = 8'h13;
                8'd4 : img_byte = 8'h00;
                8'd5 : img_byte = 8'h00;
                8'd10: img_byte = 8'd54;         // bfOffBits
                8'd18: img_byte = 8'h80;         // width  = 640
                8'd19: img_byte = 8'h02;
                8'd22: img_byte = 8'hE0;         // height = 480
                8'd23: img_byte = 8'h01;
                8'd28: img_byte = 8'd24;         // bit_count
                default: img_byte = 8'h00;
            endcase
        end
        else
            img_byte = k[7:0];                   // 像素值 = 图片序号
    end
endfunction

function [7:0] byte_at;
    input [31:0] a;
    input [8:0]  off;
    integer rel, k, s, fo;
    begin
        byte_at = 8'h00;
        if (a >= BASE_SEC) begin
            rel = a - BASE_SEC;
            k   = rel / STRIDE;
            s   = rel % STRIDE;
            fo  = s*512 + off;
            if (k < M) byte_at = img_byte(k, fo);
        end
    end
endfunction

// ---- 假 SD 控制器: 时序对齐真实 sd_card_sec_read_write.v ----
localparam C_IDLE = 2'd0, C_DATA = 2'd1, C_END = 2'd2, C_WAIT = 2'd3;
reg [1:0]  cs;
reg [31:0] sec_addr;                             // ← 锁存地址
reg [8:0]  bc;
reg [7:0]  dout;

// 真实 RTL 里这两个信号来自互斥状态:
//   sd_sec_read_data_valid = (state==S_READ) && block_read_valid
//   sd_sec_read_end        = (state==S_READ_END)
// 所以它们【永远不会同一拍拉高】。这里必须照做:
// 若让 data_valid 多拖一拍撞上 end，bmp_read 的 rd_cnt 会走
//   if (data_valid) rd_cnt<=rd_cnt+1; else if (end) rd_cnt<=0;
// 的 if 分支而不清零 -> 头部再也捕获不到 -> 搜索永远 found=0。
// (这正是上一版 TB 用寄存 sdv 犯的错, 是 TB 伪影, 不是 RTL 问题。)
wire sdv  = (cs == C_DATA);
wire sden = (cs == C_END);

always @(posedge clk) begin
    if (rst) begin
        cs <= C_IDLE; bc <= 9'd0; sec_addr <= 32'd0;
    end else case (cs)
        C_IDLE: begin
            if (sd_sec_read) begin
                sec_addr <= sd_sec_read_addr;    // 关键: 之后不再跟随 DUT 活地址
                bc       <= 9'd0;
                dout     <= byte_at(sd_sec_read_addr, 9'd0);  // 预取第0字节
                cs       <= C_DATA;
            end
        end
        C_DATA: begin
            if (bc == 9'd511)
                cs <= C_END;
            else begin
                bc   <= bc + 9'd1;
                dout <= byte_at(sec_addr, bc + 9'd1);         // 预取下一字节
            end
        end
        C_END:  cs <= C_WAIT;
        C_WAIT: cs <= C_IDLE;
        default: cs <= C_IDLE;
    endcase
end

assign sd_sec_read_data       = dout;
assign sd_sec_read_data_valid = sdv;
assign sd_sec_read_end        = sden;

// ---- DUT ----
reg  find = 0;
reg  sd_init_done = 0;
reg  write_req_ack = 0;
wire [3:0]  state_code;
wire        write_req;
wire        bmp_ready;
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire        bmp_data_wr_en;
wire [23:0] bmp_data;

bmp_read dut (
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),
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

// ---- 轮播驱动: 模拟 carousel_ctl, 空闲时每 IDLE_GAP 拍发一发 find ----
localparam IDLE_GAP = 300;
integer idle_cnt = 0;
always @(posedge clk) begin
    if (rst) begin
        find <= 1'b0; idle_cnt <= 0;
    end else if (bmp_ready) begin
        if (idle_cnt >= IDLE_GAP) begin
            find <= 1'b1; idle_cnt <= 0;          // 单拍脉冲
        end else begin
            find <= 1'b0; idle_cnt <= idle_cnt + 1;
        end
    end else begin
        find <= 1'b0; idle_cnt <= 0;
    end
end

// ---- 记录每张被读出来的图 ----
localparam NFRAME = 7;                            // 0..5 再回 0
reg [7:0] got [0:NFRAME-1];
reg [7:0] last_val = 8'hFF;
integer   fcnt = 0;
integer   err  = 0;
integer   n;

always @(posedge clk) begin
    if (!rst && bmp_data_wr_en) begin
        if (bmp_data[7:0] !== last_val) begin
            last_val = bmp_data[7:0];
            if (fcnt < NFRAME) begin
                got[fcnt] = bmp_data[7:0];
                $display(">>> [%0t] 第%0d帧: 图片 #%0d  (DUT地址=%0d, 锁存扇区=%0d)",
                    $time, fcnt, bmp_data[7:0], sd_sec_read_addr, sec_addr);
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
                    $display("*** PASS: GAP=%0d  张数无上限, 绕回正常 ***", GAP);
                else
                    $display("*** FAIL: GAP=%0d  轮播序列错误 ***", GAP);
                $display("--------------------------------------------------");
                $finish;
            end
        end
    end
end

// ---- 搜索轨迹: 只看绕回附近(地址 <= 16040) ----
`ifdef TRACE
always @(posedge clk) begin
    if (!rst && dut.state == 4'd1 && sden && sd_sec_read_addr <= 32'd16040)
        $display("    [search] DUT地址=%0d 锁存=%0d found=%b rd_cnt=%0d hdr=%02h%02h w=%0d",
                 sd_sec_read_addr, sec_addr, dut.found, dut.rd_cnt,
                 dut.header_0, dut.header_1, dut.width);
    if (!rst && dut.state == 4'd1 && sden && sd_sec_read_addr >= dut.search_end_addr)
        $display("    [WRAP ] DUT地址=%0d >= 终点=%0d -> 回 16000",
                 sd_sec_read_addr, dut.search_end_addr);
end
`endif

// ---- 激励 ----
initial begin
    repeat (10) @(posedge clk);
    rst = 1'b0;
    sd_init_done = 1'b1;
end

initial begin
    #200_000_000;                                // 200ms: 够扫完 IMG_GAP_LIMIT(16384扇区≈10.5ms)
                                                 // 和一次大的首次扫描
    $display("*** TIMEOUT 200ms *** 已读帧数=%0d state_code=%0d DUT地址=%0d 锁存=%0d",
             fcnt, state_code, sd_sec_read_addr, sec_addr);
    $finish;
end

endmodule
