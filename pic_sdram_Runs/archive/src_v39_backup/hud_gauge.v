`timescale 1ns/1ps
// ============================================================================
// hud_gauge.v -- 表盘（静态底图 ROM + 实时旋转指针），四槽位共用一套硬件
//
// 【静态部分】表盘刻度/外圈/红区/中心轴 = 96x96 的 4bit 位图，存在
//              hud_rom_dial 里，放大后显示。硬件只做"查表 + 像素叠加"，
//              没有任何实时绘制。
//
// 【动态部分】只有指针。用"反变换"法，不做 atan2、不做除角度：
//              把像素相对表心的向量 (dx,dy) 旋转到【指针坐标系】：
//                  u =  dx*sin(θ) - dy*cos(θ)     // 沿指针方向
//                  w =  dx*cos(θ) + dy*sin(θ)     // 垂直指针方向
//              然后判 (u,w) 是否落在一个"底宽 N_HW*2、长 N_LEN"的三角条里。
//              sin/cos 查 hud_rom_sincos（1024 点 Q1.11，分辨率 0.35°）。
//              4 个乘法器 + 2 个 ROM，指针转动连续无台阶。
//
// ---------------------------------------------------------------------------
// 【四槽位】为什么不是"小表一个实例、大表一个实例"
//   hud_rom_dial 是 96x96x4bit = 36Kbit，hud_rom_sincos 是 1024x12x2 = 24Kbit。
//   例化两份等于白白多花 60Kbit 的 BSRAM。而屏幕上同时只会有一组表盘亮着
//   （总览页/待机页是小表，放大页/报警页是大表），所以按【槽位】选一组几何参数，
//   ROM 和乘法器全部共用：
//
//     槽位 0  = 大表盘（窗口 384x384，源图 96x96 放大 4 倍 -> 表心在窗口正中）
//     槽位 1  = 小表盘·压力（192x192）
//     槽位 2  = 小表盘·温度
//     槽位 3  = 小表盘·液位
//
//   big_en=1 时永远用槽位 0；big_en=0 时按 x 落在哪个横向区间选 1/2/3。
//   三块小表盘的窗口互不相交，大表窗口虽然与它们【几何上】重叠，
//   但 big_en 保证了同一时刻只有一组参与，所以不会画重。
//
//   角度：槽位 0 用 ang_big（本页当前主看的那一路），槽位 1/2/3 分别用
//         ang_p / ang_t / ang_l。
//
// ---------------------------------------------------------------------------
// 几何（与 hud_panel.v 的布局严格对应，改这里必须同步改那里）
//
//   槽位 0 大表：窗口 x 8..391, y 48..431；表心 (200,240)；源图放大 4 倍
//                盘面半径 42 源像素 -> 显示 168；圆占 x 32..368, y 72..408
//   槽位 1 小表：窗口 x 8..199,   y 120..311；表心 (104,216)
//   槽位 2 小表：窗口 x 224..415, y 120..311；表心 (320,216)
//   槽位 3 小表：窗口 x 440..631, y 120..311；表心 (536,216)
//                小表源图放大 2 倍，盘面半径 84；圆占 y 132..300
//
//   大表窗口（x>=440 的部分不存在，x<=391）与趋势框（x 503..632）
//   完全不相交 —— 这是刻意的，见 hud_trend.v 的几何约束。
//
// ---------------------------------------------------------------------------
// 【不要动的地方】
//   * N_HW / N_TIP / N_TAIL / 移位位数 全部按槽位写成【两个常量分支再 mux】，
//     不是变量。一旦写成变量，(N_LEN - u) * N_HW 就变成真乘法器，多花 DSP。
//   * dial_rom 的取数时序：ROM 在本拍锁存 addr，下一拍出数据，所以
//     r1_*（第 m 拍坐标）与 dial_rom（mem[addr(m)]）必须配在同一拍，
//     中间【不能】再插寄存器，否则底图错位一行。
//
// 流水线：共 4 级寄存器，输出比输入 (x,y) 晚 4 拍。
//         x/y 本身比 vout_data 晚 1 拍（见 hud_xy_gen），总延迟由
//         hud_overlay 的 PIPE_DELAY 统一对齐。
// ============================================================================
module hud_gauge(
    input  wire        clk,
    input  wire        rst_n,
    // ---- stage0：像素坐标 ----
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    // ---- 槽位选择 ----
    input  wire        big_en,     // 1 = 用槽位 0（大表）；0 = 用槽位 1/2/3（三小表）
    // ---- 指针角度索引 (0..1023，0=12 点方向，顺时针增大) ----
    input  wire [9:0]  ang_big,    // 槽位 0
    input  wire [9:0]  ang_p,      // 槽位 1
    input  wire [9:0]  ang_t,      // 槽位 2
    input  wire [9:0]  ang_l,      // 槽位 3
    // ---- stage4：叠加输出 ----
    output reg  [23:0] o_rgb,
    output reg  [7:0]  o_alpha     // 0=透明, 255=不透明
);

    // ==================================================================
    // 槽位几何参数表
    // ==================================================================
    // big_en=1 时恒为槽位 0；否则按 x 分三段。
    wire [1:0] slot = big_en ? 2'd0
                            : ((x < 10'd224) ? 2'd1
                            : ((x < 10'd440) ? 2'd2 : 2'd3));
    wire       slot_big = (slot == 2'd0);

    // 窗口左上角
    function [9:0] s_wx;
        input [1:0] s;
        begin
            case (s)
                2'd0: s_wx = 10'd8;
                2'd1: s_wx = 10'd8;
                2'd2: s_wx = 10'd224;
                default: s_wx = 10'd440;
            endcase
        end
    endfunction

    function [9:0] s_wy;
        input [1:0] s;
        begin
            s_wy = (s == 2'd0) ? 10'd48 : 10'd120;
        end
    endfunction

    // 显示边长与源图放大倍数(2 的幂)
    function [9:0] s_src2;
        input [1:0] s;
        begin
            s_src2 = (s == 2'd0) ? 10'd384 : 10'd192;
        end
    endfunction

    function [1:0] s_lg;
        input [1:0] s;
        begin
            s_lg = (s == 2'd0) ? 2'd2 : 2'd1;   // x4 或 x2
        end
    endfunction

    // ==================================================================
    // stage0 组合：窗口内坐标、源图坐标、ROM 地址、角度选择
    // ==================================================================
    wire [9:0] wx0 = s_wx(slot);
    wire [9:0] wy0 = s_wy(slot);
    wire [9:0] lim = s_src2(slot);
    wire [1:0] lg  = s_lg(slot);

    wire [9:0] gx = x - wx0;
    wire [9:0] gy = y - wy0;
    wire in_win = (gx < lim) && (gy < lim);   // 窗口外的会下溢成大数，自动排除

    // ★★ 位宽陷阱（上板实测：大表页底图"弄反+乱码"，小表页正常）★★
    //   大表是 x4：源列 = gx/4，gx 最大 383，商最大 95，【必须带上 gx 的第 8 位】。
    //   原来写 gx[7:2]，只取 6 位（0..63），于是 gx >= 256（窗口右边 1/3）
    //   的源列会回绕成 0..31 —— 底图右 1/3 变成左侧的重影/镜像，纵向同理。
    //   小表是 x2：gx 最大 191 < 256，gx[7:1] 不会溢出，所以小表页一直是对的。
    //   改这里时必须保证商位宽够：x4 取 gx[8:2]，x2 取 gx[7:1]。
    wire [7:0] sx = (lg == 2'd2) ? {1'b0, gx[8:2]} : {1'b0, gx[7:1]};   // 0..95
    wire [7:0] sy = (lg == 2'd2) ? {1'b0, gy[8:2]} : {1'b0, gy[7:1]};   // 0..95
    wire [13:0] dial_addr = ({6'b0, sy} << 6) + ({6'b0, sy} << 5) + {6'b0, sx};  // sy*96+sx

    // 共用的 sin/cos 查表（角度在整帧内稳定，按槽位选一路即可）
    wire [9:0] ang_sel = (slot == 2'd0) ? ang_big :
                         (slot == 2'd1) ? ang_p   :
                         (slot == 2'd2) ? ang_t   : ang_l;

    wire [11:0] sinv_rom;
    wire [11:0] cosv_rom;
    hud_rom_sincos u_sincos(
        .clk   (clk),
        .addr  (ang_sel),
        .o_sin (sinv_rom),
        .o_cos (cosv_rom)
    );

    wire [3:0] dial_rom;
    hud_rom_dial u_dial(
        .clk   (clk),
        .addr  (dial_addr),
        .dout  (dial_rom)
    );

    // 调色板：4bit 索引 -> RGB888（必须与 gen_hud_assets.py 的 DIAL_PALETTE 一致）
    function [23:0] dial_pal;
        input [3:0] idx;
        begin
            case (idx)
                4'd0: dial_pal = 24'h000000;   // 透明（alpha 单独处理）
                4'd1: dial_pal = 24'h113355;   // 盘面外环
                4'd2: dial_pal = 24'h112244;   // 盘面内圈
                4'd3: dial_pal = 24'h99AACC;   // 金属外圈
                4'd4: dial_pal = 24'hFFFFFF;   // 长刻度
                4'd5: dial_pal = 24'h889999;   // 短刻度
                4'd6: dial_pal = 24'hFF2211;   // 红区
                4'd7: dial_pal = 24'hDDEEFF;   // 中心轴
                4'd8: dial_pal = 24'hFFCC00;   // 量程端点
                default: dial_pal = 24'h000000;
            endcase
        end
    endfunction

    // ==================================================================
    // R1：窗口内偏移（显示像素，相对表心）
    // ==================================================================
    // 注意 dial_rom 的时序：ROM 在本拍锁存 addr，下一拍才有数据。
    //   第 m   拍: dial_addr 由 (x,y) 组合产生，ROM 在 m->m+1 边沿锁存地址
    //   第 m+1 拍: dial_rom = mem[addr(m)]，同时 r1_* 里装的也是第 m 拍的坐标
    // 所以【不能】再打一拍，直接在第 m+1 拍用 dial_rom 即可，否则底图会错位一行。
    reg               r1_inwin;
    reg signed [10:0] r1_dx;
    reg signed [10:0] r1_dy;
    reg               r1_big;

    // 表心在窗口内的坐标 = 显示半边长 = lim/2
    wire [9:0] half = s_src2(slot) >> 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_inwin <= 1'b0;
            r1_dx    <= 11'sd0;
            r1_dy    <= 11'sd0;
            r1_big   <= 1'b0;
        end else begin
            r1_inwin <= in_win;
            // gx,gy ∈ [0,lim-1] -> 减半边长得到相对表心的有符号偏移
            r1_dx    <= $signed({1'b0, gx}) - $signed({1'b0, half});
            r1_dy    <= $signed({1'b0, gy}) - $signed({1'b0, half});
            r1_big   <= slot_big;
        end
    end

    // ==================================================================
    // R2：旋转到指针坐标系
    //   sin/cos 为 Q1.11，所以乘积要算术右移 11 位才是像素
    // ==================================================================
    wire signed [11:0] sin_q = $signed(sinv_rom);
    wire signed [11:0] cos_q = $signed(cosv_rom);

    wire signed [23:0] p_us = r1_dx * sin_q;      // 11b x 12b -> 23b
    wire signed [23:0] p_uc = r1_dy * cos_q;
    wire signed [23:0] p_ws = r1_dx * cos_q;
    wire signed [23:0] p_wc = r1_dy * sin_q;

    wire signed [24:0] u_full = p_us - p_uc;      // u = dx*sin - dy*cos
    wire signed [24:0] w_full = p_ws + p_wc;      // w = dx*cos + dy*sin

    wire signed [12:0] u_now = $signed(u_full[23:11]);
    wire signed [12:0] w_now = $signed(w_full[23:11]);

    reg               r2_inwin;
    reg signed [12:0] r2_u;
    reg signed [12:0] r2_w;
    reg [3:0]         r2_dial;
    reg               r2_big;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_inwin <= 1'b0;
            r2_u     <= 13'sd0;
            r2_w     <= 13'sd0;
            r2_dial  <= 4'd0;
            r2_big   <= 1'b0;
        end else begin
            r2_inwin <= r1_inwin;
            r2_u     <= u_now;
            r2_w     <= w_now;
            r2_dial  <= dial_rom;        // 与 r1_* 同属第 m 拍像素，见上方说明
            r2_big   <= r1_big;
        end
    end

    // ==================================================================
    // R3：指针形状判定（三角条，根部半宽 N_HW，向尖端收成 0）
    //
    // ★ 两支都写成【常量】系数，最后 mux ★
    //   写成 (N_LEN - u) * N_HW 且两者都是变量的话，就等于实例化一个
    //   13x13 乘法器，直接吃 DSP。常量乘在综合时展开成移位相加。
    // ==================================================================
    wire signed [12:0] w_abs = r2_w[12] ? (-r2_w) : r2_w;

    // 大表（槽位0）：长 144、半宽 10、锥度 >>7（= /128，比 /144 略宽 12.5%）
    // 小表（槽位1/2/3）：长 72、半宽 5、尾 12、锥度 >>6（= /64，比 /72 略宽 12.5%）
    // u 超过指针长度时差值为负，算术右移后符号位为 1；明确钳成 0，
    // 不要依赖后面的 r2_u <= tip 去挡 —— 那种依赖一旦谁调了 tip 就会静默画错。
    wire signed [13:0] hl_big_s = ((14'sd144 - $signed(r2_u)) * 14'sd10) >>> 7;
    wire signed [13:0] hl_sml_s = ((14'sd72  - $signed(r2_u)) * 14'sd5 ) >>> 6;
    wire        [12:0] hl_big = (hl_big_s[13] | (hl_big_s > 14'sd8191)) ? 13'd0 : hl_big_s[12:0];
    wire        [12:0] hl_sml = (hl_sml_s[13] | (hl_sml_s > 14'sd8191)) ? 13'd0 : hl_sml_s[12:0];
    wire        [12:0] head_lim = r2_big ? hl_big : hl_sml;

    wire signed [12:0] tip  = r2_big ? 13'sd140 : 13'sd70;   // 尖端判定上限
    wire signed [12:0] tail = r2_big ? 13'sd24  : 13'sd12;   // 配重尾长
    wire        [12:0] tw   = r2_big ? 13'd8    : 13'd4;     // 尾部半宽
    wire        [12:0] corew= r2_big ? 13'd2    : 13'd1;     // 中央高光半宽

    wire head_ok = (r2_u >= 13'sd0) && (r2_u <= tip) && (w_abs <= head_lim);
    wire tail_ok = (r2_u >= -tail) && (r2_u < 13'sd0) && (w_abs <= tw);

    wire is_needle = head_ok | tail_ok;
    wire is_core   = is_needle && (w_abs <= corew);   // 中间白色高光

    reg               r3_inwin;
    reg               r3_needle;
    reg               r3_core;
    reg [3:0]         r3_dial;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r3_inwin  <= 1'b0;
            r3_needle <= 1'b0;
            r3_core   <= 1'b0;
            r3_dial   <= 4'd0;
        end else begin
            r3_inwin  <= r2_inwin;
            r3_needle <= is_needle;
            r3_core   <= is_core;
            r3_dial   <= r2_dial;
        end
    end

    // ==================================================================
    // R4：输出（指针压在表盘底图之上）
    // ==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_rgb   <= 24'h000000;
            o_alpha <= 8'd0;
        end else begin
            if (r3_inwin && r3_needle) begin
                o_rgb   <= r3_core ? 24'hFFFFFF : 24'hE63A18;
                o_alpha <= 8'd255;
            end else if (r3_inwin && (r3_dial != 4'd0)) begin
                o_rgb   <= dial_pal(r3_dial);
                o_alpha <= 8'd255;
            end else begin
                o_rgb   <= 24'h000000;
                o_alpha <= 8'd0;
            end
        end
    end

endmodule
