`timescale 1ns/1ps
// ============================================================
// spi_probe_top.v — v8：厂商初始化为什么出不来 sd_init_done
// ============================================================
// 【v8 为什么存在】
// ============================================================
//   fat32_probe 上板读数 `0······E`（左端 d0 = state_code = 0，右端 d7 = E = 没找到）。
//
//   而 fat32_reader.v 里 state_code 只在两处写 0：复位，和
//       else if (!sd_init_done) begin ... state_code <= 4'd0; open_done <= 1'b0; end
//   FSM 各状态写的是 1..9（S_IDLE 写的是 1）。所以 **state_code=0 等价于
//   "sd_init_done 一直是 0"** —— 厂商的 sd_card_top 初始化从来没完成，
//   fat32 的打开流程一次都没跑过。
//
//   厂商序列（sd_card_sec_read_write.v）：
//       S_CMD0 -> S_CMD8 -> S_CMD55 -> S_CMD41 -> S_CMD16 -> sd_init_done=1
//   而响应判定（sd_card_cmd.v:135）是【严格等值匹配】：
//       data_recv != cmd_r1 && data_recv[7]==0  ->  S_ERR
//   各状态期望的 R1：
//       CMD0  : 0x01   出错 -> 重发 CMD0（没有别的出路）
//       CMD8  : 0x01   出错 -> 重发 CMD8（没有别的出路）
//       CMD55 : 0x01   出错 -> 重发 CMD55
//       CMD41 : 0x00   出错 -> 退回 CMD55 重试
//
//   CMD0 已经知道是对的（v6 测到 0x01）。剩下三个嫌疑：
//
//     (A) CMD8 回的如果不是恰好 0x01 —— 比如卡不支持 CMD8 而回 0x05，
//         或者干脆不回 —— 就会在 S_CMD8 里死循环。
//     (B) CMD55 回的不是 0x01（少见，但要排掉；它挂了下面的 ACMD41 就没意义）。
//     (C) ACMD41 的参数是 0x40000000 —— HCC=1，但 VDD 电压窗口位（23:0）
//         全是 0。有些卡因此永远不就绪，于是卡在 CMD55/CMD41 死循环。
//
//   本版把这四个命令**用我们自己已经验证过的 spi_master 挨个发一遍**，
//   分别测它们的响应，并且对 ACMD41 试两种参数：
//       0x40000000（和厂商一样）和 0x40FF8000（标准 VDD 窗口，HCS=1）
//
// ============================================================
// 【怎么测 —— 数 0 的个数，不做任何过滤】
// ============================================================
//   沿用 v6 那套已经在硬件上验证成立的办法：一个阶段数自己窗口里
//   0 比特的【总数】。因为 R1 的 bit7 恒为 0、前面全是 1，所以 0 必然是
//   一整段连续的，总个数就是这段的长度，而且**和字节边界对不对齐无关**。
//
//   ★ 各命令的期望值（这是本轮的判读依据）★
//
//     CMD0   -> R1 = 0x01                     => 7 个 0   => zc1 = 07
//     CMD8   -> R1 = 0x01 + R7(00 00 01 AA)   => 7+8+8+7+4 = 34 个 0
//                                              => zc2 = 22
//               （不支持 CMD8 的卡回 R1 = 0x05 => 6 个 0 => zc2 = 06）
//               （完全不回 => zc2 = 00）
//     CMD55  -> R1 = 0x01                     => zc3 = 7
//     ACMD41 -> R1 = 0x01 表示还在初始化       => 7 个 0
//               R1 = 0x00 表示就绪了           => 8 个 0   ★ 这就是成功 ★
//
//   ACMD41 不是发一次就完事 —— 卡需要时间初始化，必须反复发到它回 0x00。
//   所以 PH_4/PH_5 是循环：每一轮发 CMD55 + CMD41，看 CMD41 那个窗口是不是
//   正好 8 个 0；是就停，不是就再来一轮。最多 14 轮，每轮约 33ms（含填充），
//   合计约 470ms —— 规范允许卡用 1 秒完成初始化，这覆盖了近一半。
//
// ============================================================
// 【上板怎么看 —— 物理从左到右（d0 在最左）】
// ============================================================
//   前 3 秒 8 位全显示 9（启动标记）。然后约 1 秒跑完，永久冻结。
//
//     第 1 位        : 阶段码 9=自检 A=前置 1=CMD0 2=CMD8 3=CMD55
//                              4=ACMD41@0x40000000  5=ACMD41@0x40FF8000  E=完成
//                      小数点约 1Hz 闪 = 心跳（不闪就查时钟/复位）
//     第 2,3 位      : zc1  CMD0  的 0 个数        期望 07
//     第 4,5 位      : zc2  CMD8  的 0 个数        期望 22
//     第 6 位        : zc3  CMD55 的 0 个数        期望 7
//     第 7 位        : rounds1  ACMD41@0x40000000 第几轮就绪
//                              1..E = 第 N 轮（每轮约 33ms）就绪；F = 470ms 都没就绪
//     第 8 位        : rounds2  ACMD41@0x40FF8000 同上
//
//   读数形如 `E0722 7 1 1`  ->  `E0722711`
//
// ============================================================
// 【判读表】
// ============================================================
//   zc2  zc3  rounds1  rounds2   结论 / 下一步
//   ---  ---  -------  -------   ------------------------------------------
//    22   7      1        1      ★ 全通。那厂商卡住的原因就在它自己的
//                                 严格等值判定/时序上，不在卡这边。
//    22   7      F        1      ★★ **就是 ACMD41 的电压窗口** ★★
//                                 厂商那个 0x40000000 卡永远不就绪，
//                                 换成 0x40FF8000 第一轮就绪 -> 改厂商代码
//    22   7      F        F      卡确实一直不就绪（两个参数都不行）-> 卡的问题
//    06   7      F        F      **卡不支持 CMD8**（回 0x05 = 非法命令）
//                                 -> 厂商在 S_CMD8 死循环，需要改成跳过 CMD8
//    00   任意   任意     任意     CMD8 完全没响应 -> 查线/换卡
//    22   6      F        F      CMD55 被拒（回 0x05）-> 少见，报我
//    任意 任意   任意     任意    把 8 位原样报给我
//
// ⚠ 中心留一句：zc3 = 7 才说明 CMD55 正常。如果 zc3 = 6 或 0，
//    下面两个 rounds 都没有意义（ACMD41 前面没有 CMD55 前缀就是非法命令）。
// ============================================================
module spi_probe_top #(
    // 200kHz @ 50MHz（SPI 时钟 = clk/(2*(CLK_DIV_INIT+2))）
    // 每字节 16 个半周期 + 收尾半周期 ~= 42.6us
    parameter [15:0] CLK_DIV_INIT = 16'd123
)(
    input  wire        clk,        // 50MHz 板时钟 R7
    input  wire        rst_n,      // 复位按键 A2（低有效，按一下重跑）
    output wire        sd_ncs,     // A12  <- SD_DAT3
    output wire        sd_dclk,    // A14  <- SD_CLK
    output wire        sd_mosi,    // A13  <- SD_CMD
    input  wire        sd_miso,    // B14  <- SD_DAT0（板上无上拉电阻，靠 FPGA 内部上拉）
    output wire [7:0]  seg_sel,
    output wire [7:0]  seg_data
);

// ==================================================================
// 上电复位：50MHz 下数 20ms
// ==================================================================
reg [19:0] por_cnt;
reg        por_rst_n;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        por_cnt   <= 20'd0;
        por_rst_n <= 1'b0;
    end else if (por_cnt != 20'd1_000_000 - 20'd1) begin
        por_cnt   <= por_cnt + 20'd1;
        por_rst_n <= 1'b0;
    end else
        por_rst_n <= 1'b1;
end

wire rst_all = ~por_rst_n;      // spi_master 要的是高有效复位

// ==================================================================
// 阶段
// ==================================================================
localparam PH_BOOT = 3'd0;      // 3 秒：8 位全 9 + 引脚自检方波
localparam PH_PRE  = 3'd1;      // CS 高，64 字节 0xFF（复位前置时钟）
localparam PH_1    = 3'd2;      // CS 低，CMD0  + 32 字节窗口
localparam PH_2    = 3'd3;      // CS 低，CMD8  + 32 字节窗口
localparam PH_3    = 3'd4;      // CS 低，CMD55 + 16 字节窗口
localparam PH_4    = 3'd5;      // CS 低，循环 CMD55+ACMD41(0x40000000)
localparam PH_5    = 3'd6;      // CS 低，循环 CMD55+ACMD41(0x40FF8000)
localparam PH_DONE = 3'd7;      // 冻结

localparam [28:0] BOOT_MAX = 29'd150_000_000 - 29'd1;   // 3s @50MHz

localparam [15:0] PRE_BYTES = 16'd64;
localparam [15:0] B1_BYTES  = 16'd6 + 16'd32;   // CMD0  + 窗口
localparam [15:0] B2_BYTES  = 16'd6 + 16'd32;   // CMD8  + 窗口
localparam [15:0] B3_BYTES  = 16'd6 + 16'd16;   // CMD55 + 窗口
// 一轮 = CMD55(6) + 窗口(16) + CMD41(6) + 窗口(16) + 填充
//   ★ 为什么要塞 738 字节填充 ★
//     轮数只占一个数码管位，只能显示 1..E，F 表示"跑满上限还没就绪"。
//     如果一轮只有 44 字节（1.87ms），那"第 16 轮"才 30ms —— 卡还在正常
//     初始化就会被显示成 F，误判成"永远不就绪"。
//     把一轮撑到 782 字节（约 33ms）之后，轮数 1..E 覆盖 0..470ms，
//     F 才真正意味着"等了半秒还是不就绪"。
//     填充期间 CS 保持低、MOSI 恒 0xFF，对卡就是空闲，没有副作用
//     （cmd_byte_of 对窗口之外的 idx 本来就返回 0xFF）。
localparam [15:0] ROUND_BYTES = 16'd782;
localparam [15:0] ROUND_CAP   = 16'd14;

reg [2:0]  phase;
reg [28:0] ph_cnt;
reg [15:0] idx;                 // 当前阶段（或当前轮）已发出的字节序号
reg [15:0] rnd;                 // PH_4 / PH_5 已经跑完的轮数

// ==================================================================
// 命令字节译码
//   idx 落在哪个命令的 6 个字节里就出哪个命令，否则 0xFF（空闲填充）。
// ==================================================================
function [7:0] cmd_byte_of;
    input [2:0]  ph;
    input [15:0] i;
    begin
        if (ph == PH_1)
            cmd_byte_of = (i == 16'd0) ? 8'h40 :      // CMD0
                          (i == 16'd1) ? 8'h00 :
                          (i == 16'd2) ? 8'h00 :
                          (i == 16'd3) ? 8'h00 :
                          (i == 16'd4) ? 8'h00 :
                          (i == 16'd5) ? 8'h95 :      // CRC7(0x40)+end
                                         8'hFF;
        else if (ph == PH_2)
            cmd_byte_of = (i == 16'd0) ? 8'h48 :      // CMD8
                          (i == 16'd1) ? 8'h00 :
                          (i == 16'd2) ? 8'h00 :
                          (i == 16'd3) ? 8'h01 :      // 参数 0x000001AA
                          (i == 16'd4) ? 8'hAA :
                          (i == 16'd5) ? 8'h87 :      // CRC7(0x48 00 00 01 AA)+end
                                         8'hFF;
        else if (ph == PH_3)
            cmd_byte_of = (i == 16'd0) ? 8'h77 :      // CMD55
                          (i == 16'd1) ? 8'h00 :
                          (i == 16'd2) ? 8'h00 :
                          (i == 16'd3) ? 8'h00 :
                          (i == 16'd4) ? 8'h00 :
                          (i == 16'd5) ? 8'hFF :
                                         8'hFF;
        else if (ph == PH_4 || ph == PH_5) begin
            if (i <= 16'd5)                           // 每轮开头都是 CMD55
                cmd_byte_of = (i == 16'd0) ? 8'h77 :
                              (i == 16'd1) ? 8'h00 :
                              (i == 16'd2) ? 8'h00 :
                              (i == 16'd3) ? 8'h00 :
                              (i == 16'd4) ? 8'h00 :
                                             8'hFF;
            else if (i >= 16'd22 && i <= 16'd27) begin
                case (i - 16'd22)
                16'd0: cmd_byte_of = 8'h69;           // ACMD41
                16'd1: cmd_byte_of = 8'h40;           // HCS=1
                // 3rd byte: PH_4 -> 0x00（和厂商一样，电压窗口全 0）
                //           PH_5 -> 0xFF（标准 VDD 窗口 0x40FF8000）
                16'd2: cmd_byte_of = (ph == PH_5) ? 8'hFF : 8'h00;
                16'd3: cmd_byte_of = (ph == PH_5) ? 8'h80 : 8'h00;
                16'd4: cmd_byte_of = 8'h00;
                default: cmd_byte_of = 8'hFF;         // CRC，SPI 模式下不检查
                endcase
            end else
                cmd_byte_of = 8'hFF;
        end else
            cmd_byte_of = 8'hFF;
    end
endfunction

// 1 = 引脚自检阶段（三根输出脚打慢速方波，不跑 SPI）
wire pin_test = (phase == PH_BOOT);

// ------------------------------------------------------------------
// ★★ 极性别搞反 ★★
//   spi_master 里是 assign nCS = nCS_ctrl;  —— **低有效**。
//      nCS_ctrl = 0  ->  nCS = 0  ->  CS 拉低  ->  卡被选中
//      nCS_ctrl = 1  ->  nCS = 1  ->  CS 拉高  ->  卡没被选中
//   所以"要选中卡"的阶段（所有命令阶段）这里必须给出 **0**。
//
//   v8 第一版就是漏了下面那个 `!`，把 1 当成"选中"了。结果：
//     PH_PRE（该校验 CS 高）实际 CS 低
//     PH_1..PH_5（该校验 CS 低）实际 CS 高 —— 卡全程没被选中
//   上板读数 zc1=zc2=zc3=00、rounds=FF，一个字都不差地对应这个 bug。
//   这一版留下这行注释：极性类错误静态检查器看不出来，只有上板才暴露。
// ------------------------------------------------------------------
wire cs_n_ctrl = !((phase == PH_1) || (phase == PH_2) || (phase == PH_3) ||
                   (phase == PH_4) || (phase == PH_5));

wire spi_active = (phase == PH_PRE)  || (phase == PH_1) || (phase == PH_2) ||
                  (phase == PH_3)    || (phase == PH_4) || (phase == PH_5);

wire        spi_wr_req  = spi_active;
wire [7:0]  spi_data_in = spi_active ? cmd_byte_of(phase, idx) : 8'hFF;
wire [7:0]  spi_data_out;
wire        spi_wr_ack;

wire spi_ncs_w, spi_dclk_w, spi_mosi_w;

spi_master u_spi (
    .sys_clk    (clk            ),
    .rst        (rst_all        ),
    .nCS        (spi_ncs_w      ),
    .DCLK       (spi_dclk_w     ),
    .MOSI       (spi_mosi_w     ),
    .MISO       (sd_miso        ),
    .CPOL       (1'b1           ),   // SPI 模式 3，和 sd_card_top 里的写法一致
    .CPHA       (1'b1           ),
    .nCS_ctrl   (cs_n_ctrl      ),
    .clk_div    (CLK_DIV_INIT   ),
    .wr_req     (spi_wr_req     ),
    .wr_ack     (spi_wr_ack     ),
    .data_in    (spi_data_in    ),
    .data_out   (spi_data_out   )
);

// ------------------------------------------------------------------
// 引脚自检 mux
//   ★ 自检阶段由 ph_cnt 直接驱动脚，完全不经过 spi_master ★
//     所以"三个脚在摆"只证明铜箔通，不证明 spi_master 在工作。
// ------------------------------------------------------------------
assign sd_ncs  = pin_test ? ph_cnt[26] : spi_ncs_w;
assign sd_dclk = pin_test ? ph_cnt[24] : spi_dclk_w;
assign sd_mosi = pin_test ? ph_cnt[25] : spi_mosi_w;

// ==================================================================
// 0 比特计数
//   ★ 数的是**整个窗口**，不是最后一拍 ★（v4 就栽在只看最后一拍上）
//   ★ 不做 bit7 过滤 ★（v3 就栽在假设"响应和字节边界对齐"上）
// ==================================================================
function [3:0] zcount;              // 一个字节里有几个 0
    input [7:0] b;
    begin
        zcount = {3'd0, ~b[0]} + {3'd0, ~b[1]} + {3'd0, ~b[2]} + {3'd0, ~b[3]}
               + {3'd0, ~b[4]} + {3'd0, ~b[5]} + {3'd0, ~b[6]} + {3'd0, ~b[7]};
    end
endfunction

wire [3:0] b_zc = zcount(spi_data_out);

reg [15:0] zc_run;                  // 当前窗口累计
reg [15:0] zc1, zc2, zc3;           // CMD0 / CMD8 / CMD55 的结果
reg [15:0] acc55, acc41;            // 循环里 CMD55 窗口 / CMD41 窗口
reg [3:0]  rounds1, rounds2;        // 两种 ACMD41 参数各用了多少轮（饱和到 F）

// 阶段结束标记：该阶段（或该轮）的最后一个字节
wire b1_end = (idx + 16'd1 >= B1_BYTES);
wire b2_end = (idx + 16'd1 >= B2_BYTES);
wire b3_end = (idx + 16'd1 >= B3_BYTES);
wire rd_end = (idx + 16'd1 >= ROUND_BYTES);

// 循环里的窗口区间
wire in_win55 = (idx >= 16'd6)  && (idx <= 16'd21);
wire in_win41 = (idx >= 16'd28) && (idx <= 16'd43);

// CMD41 窗口里 0 的个数正好 8 -> R1 = 0x00 -> 卡就绪了
wire [15:0] z41_total = acc41 + {12'd0, b_zc};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || !por_rst_n) begin
        phase   <= PH_BOOT;
        ph_cnt  <= 29'd0;
        idx     <= 16'd0;
        rnd     <= 16'd0;
        zc_run  <= 16'd0;
        zc1     <= 16'd0;
        zc2     <= 16'd0;
        zc3     <= 16'd0;
        acc55   <= 16'd0;
        acc41   <= 16'd0;
        rounds1 <= 4'h0;
        rounds2 <= 4'h0;
    end else case (phase)
    // ---------------- 3 秒自检 ----------------
    PH_BOOT: begin
        if (ph_cnt >= BOOT_MAX) begin
            phase  <= PH_PRE;
            ph_cnt <= 29'd0;
            idx    <= 16'd0;
        end else
            ph_cnt <= ph_cnt + 29'd1;
    end
    // ---------------- CS 高，64 字节前置时钟 ----------------
    PH_PRE: if (spi_wr_ack) begin
        if (idx + 16'd1 >= PRE_BYTES) begin
            phase <= PH_1;
            idx   <= 16'd0;
        end else
            idx <= idx + 16'd1;
    end
    // ---------------- PH_1: CMD0 + 32 字节窗口 ----------------
    PH_1: if (spi_wr_ack) begin
        if (b1_end) begin
            zc1   <= zc_run + {12'd0, b_zc};
            phase <= PH_2;
            idx   <= 16'd0;
            zc_run<= 16'd0;
        end else begin
            // idx 0..5 是命令本身，不计数
            if (idx >= 16'd6) zc_run <= zc_run + {12'd0, b_zc};
            idx <= idx + 16'd1;
        end
    end
    // ---------------- PH_2: CMD8 + 32 字节窗口 ----------------
    PH_2: if (spi_wr_ack) begin
        if (b2_end) begin
            zc2   <= zc_run + {12'd0, b_zc};
            phase <= PH_3;
            idx   <= 16'd0;
            zc_run<= 16'd0;
        end else begin
            if (idx >= 16'd6) zc_run <= zc_run + {12'd0, b_zc};
            idx <= idx + 16'd1;
        end
    end
    // ---------------- PH_3: CMD55 + 16 字节窗口 ----------------
    PH_3: if (spi_wr_ack) begin
        if (b3_end) begin
            zc3   <= zc_run + {12'd0, b_zc};
            phase <= PH_4;
            idx   <= 16'd0;
            rnd   <= 16'd0;
            zc_run<= 16'd0;
            acc55 <= 16'd0;
            acc41 <= 16'd0;
        end else begin
            if (idx >= 16'd6) zc_run <= zc_run + {12'd0, b_zc};
            idx <= idx + 16'd1;
        end
    end
    // ---------------- PH_4 / PH_5: 循环 CMD55 + ACMD41 ----------------
    PH_4, PH_5: if (spi_wr_ack) begin
        // 两个窗口各自累计
        if (idx == 16'd5)
            acc55 <= 16'd0;
        else if (in_win55)
            acc55 <= acc55 + {12'd0, b_zc};

        if (idx == 16'd27)
            acc41 <= 16'd0;
        else if (in_win41)
            acc41 <= acc41 + {12'd0, b_zc};

        if (rd_end) begin
            // 本轮结束：看 ACMD41 那个窗口是不是正好 8 个 0（R1 = 0x00）
            if (z41_total == 16'd8) begin
                // 卡就绪了
                if (phase == PH_4) begin
                    rounds1 <= (rnd >= 16'd15) ? 4'hF : rnd[3:0] + 4'd1;
                    phase   <= PH_5;
                    idx     <= 16'd0;
                    rnd     <= 16'd0;
                    acc55   <= 16'd0;
                    acc41   <= 16'd0;
                end else begin
                    rounds2 <= (rnd >= 16'd15) ? 4'hF : rnd[3:0] + 4'd1;
                    phase   <= PH_DONE;
                    idx     <= 16'd0;
                end
            end else if (rnd + 16'd1 >= ROUND_CAP) begin
                // 跑满 256 轮（约 480ms）还是不就绪
                if (phase == PH_4) begin
                    rounds1 <= 4'hF;
                    phase   <= PH_5;
                    idx     <= 16'd0;
                    rnd     <= 16'd0;
                    acc55   <= 16'd0;
                    acc41   <= 16'd0;
                end else begin
                    rounds2 <= 4'hF;
                    phase   <= PH_DONE;
                    idx     <= 16'd0;
                end
            end else begin
                rnd <= rnd + 16'd1;
                idx <= 16'd0;
                acc55 <= 16'd0;
                acc41 <= 16'd0;
            end
        end else
            idx <= idx + 16'd1;
    end
    default: ;                  // PH_DONE：冻结
    endcase
end

// ------------------------------------------------------------------
// 上数码管：窗口 16/32 字节，最大 256/1024 个 0，饱和到 FF
// ------------------------------------------------------------------
wire [7:0] z1d = (zc1 > 16'd255) ? 8'hFF : zc1[7:0];
wire [7:0] z2d = (zc2 > 16'd255) ? 8'hFF : zc2[7:0];
wire [3:0] z3d = (zc3 > 16'd15 ) ? 4'hF  : zc3[3:0];

// ==================================================================
// 心跳：第 1 位的小数点约 1Hz 闪烁
// ==================================================================
reg [24:0] hb_cnt;
reg        hb;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hb_cnt <= 25'd0;
        hb     <= 1'b0;
    end else if (hb_cnt >= 25'd25_000_000) begin   // 0.5s @50MHz
        hb_cnt <= 25'd0;
        hb     <= ~hb;
    end else
        hb_cnt <= hb_cnt + 25'd1;
end

// ==================================================================
// 数码管译码
// ==================================================================
function [6:0] seg7;
    input [3:0] d;
    begin
        case (d)
            4'h0: seg7 = 7'b100_0000;
            4'h1: seg7 = 7'b111_1001;
            4'h2: seg7 = 7'b010_0100;
            4'h3: seg7 = 7'b011_0000;
            4'h4: seg7 = 7'b001_1001;
            4'h5: seg7 = 7'b001_0010;
            4'h6: seg7 = 7'b000_0010;
            4'h7: seg7 = 7'b111_1000;
            4'h8: seg7 = 7'b000_0000;
            4'h9: seg7 = 7'b001_0000;
            4'ha: seg7 = 7'b000_1000;       // 'A'
            4'hb: seg7 = 7'b000_0011;       // 'b'
            4'hc: seg7 = 7'b100_0110;       // 'C'
            4'hd: seg7 = 7'b010_0001;       // 'd'
            4'he: seg7 = 7'b000_0110;       // 'E'
            // ★ 4'hF 必须显示成 'F'，不能落到 default（全灭）★
            4'hf: seg7 = 7'b000_1110;       // 'F'
            default: seg7 = 7'b111_1111;
        endcase
    end
endfunction

// ---- 阶段码 ----
reg [3:0] phase_code;

always @(*) begin
    case (phase)
    PH_BOOT: phase_code = 4'd9;     // 9
    PH_PRE:  phase_code = 4'ha;     // A
    PH_1:    phase_code = 4'd1;     // 1  CMD0
    PH_2:    phase_code = 4'd2;     // 2  CMD8
    PH_3:    phase_code = 4'd3;     // 3  CMD55
    PH_4:    phase_code = 4'd4;     // 4  ACMD41 @0x40000000
    PH_5:    phase_code = 4'd5;     // 5  ACMD41 @0x40FF8000
    default: phase_code = 4'he;     // E  完成冻结
    endcase
end

// ---- 各位内容（s7 = 物理最左，s0 = 物理最右）----
wire [7:0] s7 = {hb ? 1'b1 : 1'b0, seg7(phase_code)};   // 阶段码 + 心跳
wire [7:0] s6 = {1'b1, seg7(z1d[7:4])};                 // zc1  CMD0
wire [7:0] s5 = {1'b1, seg7(z1d[3:0])};
wire [7:0] s4 = {1'b1, seg7(z2d[7:4])};                 // zc2  CMD8
wire [7:0] s3 = {1'b1, seg7(z2d[3:0])};
wire [7:0] s2 = {1'b1, seg7(z3d)};                      // zc3  CMD55
wire [7:0] s1 = {1'b1, seg7(rounds1)};                  // ACMD41 @0x40000000 轮数
wire [7:0] s0 = {1'b1, seg7(rounds2)};                  // ACMD41 @0x40FF8000 轮数

// ---- 自检阶段 8 位全显示 9 ----
wire [7:0] bt = {1'b1, seg7(4'd9)};

// ------------------------------------------------------------------
// ★ 接线顺序（实测确认过）★
//   自检显示 12345678，上板读回 87654321，
//   证明 seg_data_0 是物理最左位。所以这里 s7 -> seg_data_0。
// ------------------------------------------------------------------
seg_scan u_seg_scan(
    .clk        (clk      ),
    .rst_n      (por_rst_n),
    .seg_sel    (seg_sel  ),
    .seg_data   (seg_data ),
    .seg_data_0 (pin_test ? bt : s7),   // 物理最左 = 阶段码
    .seg_data_1 (pin_test ? bt : s6),
    .seg_data_2 (pin_test ? bt : s5),
    .seg_data_3 (pin_test ? bt : s4),
    .seg_data_4 (pin_test ? bt : s3),
    .seg_data_5 (pin_test ? bt : s2),
    .seg_data_6 (pin_test ? bt : s1),
    .seg_data_7 (pin_test ? bt : s0)    // 物理最右 = ACMD41@0x40FF8000 轮数
);

endmodule
