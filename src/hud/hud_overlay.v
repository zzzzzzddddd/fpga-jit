`timescale 1ns/1ps
// ============================================================================
// hud_overlay.v -- HUD 叠加总装（插在 video_delay 和 video_rgb_to_axis 之间）
//
// 数据流：
//   video_delay(vout_data/hs/vs/de)
//        ├─(6 级延迟)────────────────────────────────────────┐
//        └─ hud_xy_gen ─┬─ hud_panel ─(4 级延迟)──┐           │
//                       ├─ hud_gauge ────────────┤           │
//                       └─ hud_trend ×3 ─────────┴───> 混合 ──┴─> 输出
//
// 延迟对齐（详见每段注释）：
//   x/y 比 vout_data 晚 1 拍；hud_panel 组合输出，表盘/趋势内部 4 级流水。
//   为了让三者对齐，底层视频走 5 级移位寄存器，HUD 走 4 级，合成后再打 1 拍。
//   => 从 video_delay 输出到本模块输出的总延迟 = 6 拍 (PIPE_DELAY)。
//
// 混合公式：
//   不透明度 ae = hud_alpha * (fade_alpha+1) / 256     （页面淡入淡出）
//   out_ch      = base_ch + (hud_ch - base_ch) * ae / 256
//   out_ch      = out_ch * (bright+1) / 256            （亮度调节）
//   用 (x+1)>>8 而不是 x>>8，是为了让"满档"精确等于原值，不出 1LSB 损失。
//
// 层的优先级：表盘 > 趋势曲线 > 面板 > 底层 SD 卡底图
// ============================================================================
module hud_overlay(
    input  wire        clk,          // video_clk 25MHz
    input  wire        rst_n,
    // ---- 底层视频（来自 video_delay）----
    input  wire        hs,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] vout_data,
    // ---- 控制 / 数据 ----
    input  wire [2:0]  disp_page,
    input  wire [7:0]  fade_alpha,
    input  wire [7:0]  bright,
    input  wire [9:0]  ang_big,      // 大表指针角度（本页主看的那一路）
    input  wire [9:0]  ang_p,        // 三小表各自的指针角度
    input  wire [9:0]  ang_t,
    input  wire [9:0]  ang_l,
    input  wire [19:0] row_p,        // 三行读数（5 个 nibble，BCD）
    input  wire [19:0] row_t,
    input  wire [19:0] row_l,
    input  wire [2:0]  lamp,
    input  wire        alarm_on,
    input  wire        blink,
    input  wire [5:0]  banner_off,
    input  wire        carousel_en,  // ★ 轮播模式 1/0（原样透传给 hud_panel 的顶栏标识）
    input  wire [3:0]  sw,           // 拨动开关 SW1-4
    input  wire        fl_p, fl_t, fl_l,   // 三个量的报警标志（决定横幅文案）
    input  wire [7:0]  tr_p, tr_t, tr_l,   // 三条趋势曲线的采样值 0..115
    input  wire        trend_push,         // 趋势采样脉冲（8Hz）
    // ---- 输出 ----
    output wire        o_hs,
    output wire        o_vs,
    output wire        o_de,
    output wire [23:0] o_rgb
);

    // ==================================================================
    // 1) 像素坐标
    // ==================================================================
    wire [9:0] x, y;
    hud_xy_gen u_xy(
        .clk   (clk),
        .rst_n (rst_n),
        .vs    (vs),
        .de    (de),
        .x     (x),
        .y     (y)
    );

    // 大表形态：页 1/2/3/5。本模块要用它选表盘槽位和趋势曲线使能。
    // ★ 这段判据必须和 hud_panel 里的 big_pg 完全一致 ★
    //   所以 hud_panel 把它的 big_pg 也输出成 o_big，这里直接用，不重写一遍：
    //   两处各写一份的话，将来只要改了一处判据，表盘和面板底版就会错页。

    // ==================================================================
    // 2) 面板图形 + 文本请求
    // ==================================================================
    wire [23:0] p_rgb;
    wire [7:0]  p_alpha;
    wire        t_hit, t_font;
    wire [5:0]  t_code;      // ASCII 字库编码
    wire [7:0]  t_ccode;     // 汉字索引 = ch[6:0]
    wire [2:0]  t_row;       // 5x7 行号
    wire [3:0]  t_crow;      // 16x16 行号
    wire [2:0]  t_gcol;      // 5x7 列号
    wire [3:0]  t_gccol;     // 16x16 列号
    wire [23:0] t_color;
    wire        o_big;

    hud_panel u_panel(
        .x          (x),
        .y          (y),
        .disp_page  (disp_page),
        .row_p      (row_p),
        .row_t      (row_t),
        .row_l      (row_l),
        .lamp       (lamp),
        .alarm_on   (alarm_on),
        .blink      (blink),
        .banner_off (banner_off),
        .bright     (bright),
        .carousel_en(carousel_en),
        .sw         (sw),
        .fl_p       (fl_p),
        .fl_t       (fl_t),
        .fl_l       (fl_l),
        .o_rgb      (p_rgb),
        .o_alpha    (p_alpha),
        .o_big      (o_big),
        .t_hit      (t_hit),
        .t_font     (t_font),
        .t_code     (t_code),
        .t_ccode    (t_ccode),
        .t_row      (t_row),
        .t_crow     (t_crow),
        .t_gcol     (t_gcol),
        .t_gccol    (t_gccol),
        .t_color    (t_color)
    );

    // ==================================================================
    // 3) 字库查表 —— ASCII 5x7 与 汉字 16x16 共用这一处
    //
    // 【R1】先把面板输出打一拍再查字库。原因：面板那条链是
    //   x,y -> 十几个标签选择 -> 字形编码 -> 字库 -> 取某个像素位
    // 一路组合下来接近 20 级 LUT，25MHz(40ns) 下时序太紧。
    // 打一拍切成两段后，每段都在 10 级以内，余量就很舒服了。
    //
    // ------------------------------------------------------------------
    // ★ 两个字库的读法不一样，必须把延迟对齐 ★
    //
    //   hud_rom_font 是【组合读】（5x7 只有 424 位，用 LUT 展开最省）
    //   hud_rom_cjk  是【同步读】（49 字 x 16 行 x 16 位 = 12544 位，
    //                 用 LUT 展开要约 250~350 个 LUT6 —— 这个工程的 LUT
    //                 已经把 125MHz 那条路径的余量啃掉了（见 TD_BUILD_NOTES.md），
    //                 换成 1~2 块 BSRAM 划算得多）
    //
    //   于是：hud_rom_cjk 的地址在本拍锁存、下一拍出数据，天然比
    //   hud_rom_font 晚一拍。这里用 f_* 这一级把两边【对齐到同一拍】：
    //
    //     第 n   拍: q_* = 像素 P(n-1) 的字形请求
    //                hud_rom_font 组合响应 P(n-1)，输出在第 n 拍内有效
    //                hud_rom_cjk 在第 n->n+1 边沿锁存 P(n-1) 的地址
    //     第 n+1 拍: hud_rom_cjk 输出 = P(n-1) 的那一行
    //                f_a_glyph 在第 n->n+1 边沿也锁存了 P(n-1) 的 5x7 行
    //                f_gcol / f_t_gcol 同样锁存了 P(n-1) 的列号
    //     => 下一拍两者同时可用，且列号与各自的行数据同源，不会错位一格
    //
    //   ★ 千万不要把 hud_rom_cjk 的输出再打一拍 ★
    //     它自己已经是寄存器输出，再打一拍就变成 5 记流水，
    //     整个 HUD 层会比表盘/趋势【晚一个像素】，文字整体右移一列。
    //     （这就是 hud_gauge.v 里记的那个"多插一级寄存器底图错位一行"的坑。）
    // ------------------------------------------------------------------
    reg [23:0] qr_rgb;
    reg [7:0]  qr_alpha;
    reg        q_hit, q_font;
    reg [5:0]  q_code;
    reg [7:0]  q_ccode;
    reg [2:0]  q_row;
    reg [3:0]  q_crow;
    reg [2:0]  q_gcol;
    reg [3:0]  q_gccol;
    reg [23:0] q_color;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qr_rgb   <= 24'd0;
            qr_alpha <= 8'd0;
            q_hit    <= 1'b0;
            q_font   <= 1'b0;
            q_code   <= 6'd0;
            q_ccode  <= 8'h20;
            q_row    <= 3'd0;
            q_crow   <= 4'd0;
            q_gcol   <= 3'd0;
            q_gccol  <= 4'd0;
            q_color  <= 24'd0;
        end else begin
            qr_rgb   <= p_rgb;
            qr_alpha <= p_alpha;
            q_hit    <= t_hit;
            q_font   <= t_font;
            q_code   <= t_code;
            q_ccode  <= t_ccode;
            q_row    <= t_row;
            q_crow   <= t_crow;
            q_gcol   <= t_gcol;
            q_gccol  <= t_gccol;
            q_color  <= t_color;
        end
    end

    // ---- ASCII 5x7（组合读）----
    wire [4:0] glyph_a;
    hud_rom_font u_font(
        .code (q_code),
        .row  (q_row),
        .bits (glyph_a)
    );

    // ---- 汉字 16x16（同步读，1 拍）----
    // bits[15] = 最左一列（与 hud_rom_font 的"高位=左边"保持一致）
    wire [15:0] glyph_c;
    hud_rom_cjk u_cjk(
        .clk  (clk),
        .code (q_ccode[6:0]),
        .row  (q_crow),
        .bits (glyph_c)
    );

    // ---- R2：字形输出级 ----
    reg [4:0] f_a_glyph;
    reg [2:0] f_gcol;
    reg [3:0] f_t_gcol;
    reg       f_hit, f_font;
    reg [23:0] f_color;
    reg [23:0] f_rgb;
    reg [7:0]  f_alpha;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_a_glyph <= 5'd0;
            f_gcol    <= 3'd0;
            f_t_gcol  <= 4'd0;
            f_hit     <= 1'b0;
            f_font    <= 1'b0;
            f_color   <= 24'd0;
            f_rgb     <= 24'd0;
            f_alpha   <= 8'd0;
        end else begin
            f_a_glyph <= glyph_a;
            f_gcol    <= q_gcol;
            f_t_gcol  <= q_gccol;
            f_hit     <= q_hit;
            f_font    <= q_font;
            f_color   <= q_color;
            f_rgb     <= qr_rgb;
            f_alpha   <= qr_alpha;
        end
    end

    // ---- 取像素位 ----
    // ASCII：5x7 只用了列 0..4，列 5..7 是字间距。列号 >4 时给 4（钳位保证索引
    //        合法），再用 a_ok 把它挡掉，输出恒空白。
    //        （hud_label 在混排模式下，落在边距上时本来就给 gcol=7。）
    // 汉字：16 列全用。15-gcol 就是按位取反，成本几乎为零。
    wire       a_ok  = f_hit && !f_font && (f_gcol <= 3'd4);
    wire       a_bit = a_ok && f_a_glyph[3'd4 - f_gcol];
    wire       c_ok  = f_hit &&  f_font;
    wire       c_bit = c_ok && glyph_c[4'd15 - f_t_gcol];
    wire       gbit  = a_bit | c_bit;

    wire [23:0] hud0_rgb   = gbit ? f_color : f_rgb;
    wire [7:0]  hud0_alpha = gbit ? 8'd255  : f_alpha;

    // ==================================================================
    // 4) 表盘 + 指针（内部 4 级流水，与面板同拍）
    // ==================================================================
    wire [23:0] g_rgb;
    wire [7:0]  g_alpha;

    hud_gauge u_gauge(
        .clk     (clk),
        .rst_n   (rst_n),
        .x       (x),
        .y       (y),
        .big_en  (o_big),
        .ang_big (ang_big),
        .ang_p   (ang_p),
        .ang_t   (ang_t),
        .ang_l   (ang_l),
        .o_rgb   (g_rgb),
        .o_alpha (g_alpha)
    );

    // ==================================================================
    // 4b) 趋势曲线 ×3（各自 1 块 BSRAM，内部 4 级流水，与表盘同拍）
    //
    // ★ 三个实例的 en 互斥，但 push 是共用的、三个【一直在采样】 ★
    //   这样从总览页切到放大页时曲线是满的，不是从 0 重新长出来。
    //   各实例的 en 只决定"这一页要不要把它画出来"。
    // ==================================================================
    wire [23:0] tp_rgb, tt_rgb, tl_rgb;
    wire [7:0]  tp_al,  tt_al,  tl_al;

    wire en_p = o_big && ((disp_page == 3'd1) || (disp_page == 3'd5));
    wire en_t = o_big &&  (disp_page == 3'd2);
    wire en_l = o_big &&  (disp_page == 3'd3);

    hud_trend u_tr_p(.clk(clk), .rst_n(rst_n), .x(x), .y(y),
                     .sample(tr_p), .push(trend_push), .en(en_p),
                     .o_rgb(tp_rgb), .o_alpha(tp_al));
    hud_trend u_tr_t(.clk(clk), .rst_n(rst_n), .x(x), .y(y),
                     .sample(tr_t), .push(trend_push), .en(en_t),
                     .o_rgb(tt_rgb), .o_alpha(tt_al));
    hud_trend u_tr_l(.clk(clk), .rst_n(rst_n), .x(x), .y(y),
                     .sample(tr_l), .push(trend_push), .en(en_l),
                     .o_rgb(tl_rgb), .o_alpha(tl_al));

    wire        tp_on = (tp_al != 8'd0);
    wire        tt_on = (tt_al != 8'd0);
    wire        tl_on = (tl_al != 8'd0);
    wire        t_on  = tp_on | tt_on | tl_on;
    wire [23:0] t_rgb = tp_on ? tp_rgb : (tt_on ? tt_rgb : tl_rgb);
    wire [7:0]  t_al  = tp_on ? tp_al  : (tt_on ? tt_al  : tl_al);

    // ==================================================================
    // 5) 延迟对齐
    //    q_*(R1) + f_*(R2) + p3(R3) + p4(R4)：面板/HUD 层共 4 级
    //    b1..b5 ：底层视频延迟 5 拍（x/y 本身比 vout_data 晚 1 拍）
    //    最后再打 1 拍输出  => 从 vout_data 到 o_rgb 总共 6 拍
    // ==================================================================
    reg [31:0] p3, p4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p3 <= 32'd0; p4 <= 32'd0;
        end else begin
            p3 <= {hud0_rgb, hud0_alpha};
            p4 <= p3;
        end
    end

    reg [26:0] b1, b2, b3, b4, b5;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b1 <= 27'd0; b2 <= 27'd0; b3 <= 27'd0; b4 <= 27'd0; b5 <= 27'd0;
        end else begin
            b1 <= {de, hs, vs, vout_data};
            b2 <= b1;
            b3 <= b2;
            b4 <= b3;
            b5 <= b4;
        end
    end

    wire        base_de  = b5[26];
    wire        base_hs  = b5[25];
    wire        base_vs  = b5[24];
    wire [23:0] base_rgb = b5[23:0];

    // ==================================================================
    // 6) 混合：表盘 -> 趋势曲线 -> 面板 -> 淡入淡出 -> 亮度
    //
    // 这里做的是【选择】不是【合成】：被选中的那一层直接拿去和底层视频混。
    // 所以趋势层的 alpha 只能是 {0, 255}（hud_trend 已经保证）—— 如果它给出
    // 一个 224 这样的半透明值，它就会去和【底层 SD 底图】混合而不是和面板底版
    // 混合，图框里会凭空透出底图。图框的底色和边框因此画在 hud_panel 里。
    // ==================================================================
    wire        g_on      = (g_alpha != 8'd0);
    wire [23:0] hud_rgb   = g_on ? g_rgb   : (t_on ? t_rgb    : p4[31:8]);
    wire [7:0]  hud_alpha = g_on ? g_alpha : (t_on ? t_al     : p4[7:0]);

    // 注意：fade_alpha 满档是 255，直接写 (fade_alpha+8'd1) 会在 255 处回绕成 0，
    //       整层 HUD 会突然消失。必须先扩到 9 位再 +1。
    wire [8:0]  fa9  = {1'b0, fade_alpha} + 9'd1;            // 1..256
    wire [16:0] ae16 = hud_alpha * fa9;                      // 0..255*256
    wire [7:0]  ae   = ae16[15:8];                           // 0..255
    wire [9:0]  ae9  = {1'b0, ae} + 10'd1;                   // 1..256

    // a 一定要声明成 10 位！$signed(a) 里 8 位数最大只有 +127，
    // 9 位数最大只有 +255，装不下"满不透明度"的 256，会变成负数，
    // 结果整个画面的颜色全部翻掉（实测出来的坑）。
    // 传 ae9 = ae+1：这样 a=256 时 (h-b)*256>>8 恰好等于 h-b，满档精确还原。
    function [7:0] mix8;
        input [7:0] h;      // HUD 通道
        input [7:0] b;      // 底层通道
        input [9:0] a;      // 不透明度+1，1..256
        reg signed [8:0]  d;
        reg signed [18:0] m;
        begin
            d = $signed({1'b0, h}) - $signed({1'b0, b});
            m = d * $signed(a);
            mix8 = b + m[15:8];
        end
    endfunction

    wire [7:0] bl_r = mix8(hud_rgb[23:16], base_rgb[23:16], ae9);
    wire [7:0] bl_g = mix8(hud_rgb[15:8],  base_rgb[15:8],  ae9);
    wire [7:0] bl_b = mix8(hud_rgb[7:0],   base_rgb[7:0],   ae9);

    // 亮度系数（bright=255 时精确等于原值）
    wire [8:0] brt = {1'b0, bright} + 9'd1;

    wire [16:0] or16 = bl_r * brt;
    wire [16:0] og16 = bl_g * brt;
    wire [16:0] ob16 = bl_b * brt;

    wire [23:0] blended = {or16[15:8], og16[15:8], ob16[15:8]};

    // ---- 原来的 SW1「HUD 叠加总开关」已经取消 ----
    // 新语义下 SW1 是「关报警声」，HUD 改成常开。这里不再有旁路开关。
    //
    // 消隐期不叠加（此时 x=y=0，面板逻辑会误判成左上角）
    wire [23:0] composed = base_de ? blended : base_rgb;

    // ==================================================================
    // 7) 输出寄存
    // ==================================================================
    reg        o_de_r, o_hs_r, o_vs_r;
    reg [23:0] o_rgb_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_de_r  <= 1'b0;
            o_hs_r  <= 1'b0;
            o_vs_r  <= 1'b0;
            o_rgb_r <= 24'd0;
        end else begin
            o_de_r  <= base_de;
            o_hs_r  <= base_hs;
            o_vs_r  <= base_vs;
            o_rgb_r <= composed;
        end
    end

    assign o_de  = o_de_r;
    assign o_hs  = o_hs_r;
    assign o_vs  = o_vs_r;
    assign o_rgb = o_rgb_r;

endmodule
