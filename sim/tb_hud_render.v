`timescale 1ns/1ps
// ============================================================================
// tb_hud_render.v -- 快速整帧渲染：把 HUD 四层画出来导成 .hex（再转 BMP）
//
// 为什么不直接跑 hud_top：
//   hud_top 里的 hud_xy_gen 依赖真实的 800x525 时序（而且本工程的 de 波形很特殊，
//   每行的有效区被 20 拍延迟切成了两段），跑一帧要 42 万拍，再乘上要展示的几种
//   画面状态，iverilog 下要跑十几分钟。
//
// 本 TB 的做法：直接把坐标 (px,py) 一拍一个像素地喂给 hud_panel / hud_gauge /
//   hud_rom_font，并在 TB 里复刻 hud_overlay 的延迟对齐 + 混合公式。
//   一帧只要 307200 拍 ≈ 10 秒，四种画面状态一分钟内跑完。
//
//   它验证的是【画面内容与版式】（表盘位置、刻度、指针、四行读数、指示灯、
//   现场画面窗口、报警横幅、亮度）；像素级流水对齐关系由 hud_overlay.v 的
//   注释验算保证（见 HUD_README.md 5.3）。
//
// 运行（在 sim 目录下）：
//   iverilog -g2005 -o tb_render.vvp -s tb_hud_render \
//       ../src/hud/hud_label.v ../src/hud/hud_panel.v ../src/hud/hud_gauge.v \
//       ../src/hud/hud_rom_dial.v ../src/hud/hud_rom_font.v ../src/hud/hud_rom_sincos.v \
//       tb_hud_render.v
//   vvp tb_render.vvp
//   python ../tools/hex2bmp.py
//
// ============================================================================
// ★★★ 警告：本 TB 复刻的公式已过期（选题二扩展之后）★★★
//
// 下面 `---- 复刻 hud_overlay 的延迟对齐 + 混合 ----` 那一段是把
// hud_overlay.v 的流水和混合【手抄】过来的第二处真相源。选题二扩展同时
// 改了 hud_overlay.v，两边已经不一致了，具体差在三处：
//
//   1) 混合从"表盘 : 面板"二选一变成了【表盘 > 趋势 > 面板】三选一，
//      并且多出一层 hud_trend（本 TB 里【根本没有例化】，
//      所以趋势图框那块区域画出来一定是空的）；
//   2) hud_overlay 新增了 SW1 旁路 `(hud_en && base_de) ? blended : base_rgb`，
//      本 TB 没有；
//   3) hud_panel 本身的版式也变了：PIP 缩窄到 x 248..495、
//      y 26..33 多了 SW 状态栏、右侧新增 x 503..632 的趋势图框。
//      （这一条会通过例化自动跟上，1/2 两条不会。）
//
// 所以【本 TB 出图不再等价于 RTL】。它仍然可以用来快速看版式，
// 但任何"对照 BMP 验收功能"的用途都必须改用 tb_hud_frame.v。
//
// 输出的文件名已全部改成 out_render_*.hex 前缀 —— 原来它和 tb_hud_frame.v
// 写的是同一批 out_hud_*.hex，一旦重跑这个过期的 TB，就会把整链仿真出的
// golden 帧【静默覆盖】成按旧公式算的图，而且 BMP 看起来仍然"像那么回事"。
// 要重新信任本 TB，必须先把上面 1/2 两条补齐。
//
// tools/hex2bmp.py 的默认 glob 是 sim/out_hud_*.hex，所以改名之后
// 直接跑它【不会】碰到本 TB 的输出（这正是想要的）。要看本 TB 的图，
// 得显式指定文件名：
//     python ../tools/hex2bmp.py out_render_p0.hex out_render_p0.bmp
// ============================================================================
module tb_hud_render;

    reg clk = 1'b0;
    always #20 clk = ~clk;          // 25MHz

    reg rst_n = 1'b0;

    // 【选题二扩展后新增】hud_panel 多了 sw 端口（SW 状态栏要用）。
    // 全 0 = 四个方块全灭，不使能任何功能开关。
    reg [3:0] sw = 4'b0000;

    // ---------------- 画面状态（由 initial 里逐帧设置）----------------
    reg [1:0]  page     = 2'd0;
    reg [7:0]  fade     = 8'd255;
    reg [7:0]  bright   = 8'd255;
    reg [19:0] r1 = 20'h0C7AF, r2 = 20'h0E850, r3 = 20'hFF62F, r4 = 20'hFF78F;
    reg [2:0]  lamp     = 3'b101;
    reg        alarm_on = 1'b0;
    reg        blink    = 1'b0;
    reg [5:0]  banner   = 6'd48;
    reg [9:0]  ang_a    = 10'd700;
    reg [9:0]  ang_b    = 10'd760;

    // ---------------- 坐标扫描 ----------------
    reg [9:0] px = 10'd0, py = 10'd0;
    always @(posedge clk) begin
        if (px == 10'd639) begin
            px <= 10'd0;
            py <= (py == 10'd479) ? 10'd0 : (py + 10'd1);
        end else begin
            px <= px + 10'd1;
        end
    end

    // 底层视频（代替 SD 卡照片，一块斜向渐变）
    wire [23:0] base_rgb = {px[9:2], py[9:2], 8'h30};

    // ---------------- HUD 三层 ----------------
    wire [23:0] p_rgb;
    wire [7:0]  p_alpha;
    wire        t_hit;
    wire [5:0]  t_code;
    wire [2:0]  t_row, t_gcol;
    wire [23:0] t_color;

    hud_panel u_panel(
        .x(px), .y(py), .page(page),
        .row1(r1), .row2(r2), .row3(r3), .row4(r4),
        .lamp(lamp), .alarm_on(alarm_on), .blink(blink),
        .banner_off(banner), .bright(bright),
        .sw(sw),
        .o_rgb(p_rgb), .o_alpha(p_alpha),
        .t_hit(t_hit), .t_code(t_code), .t_row(t_row),
        .t_gcol(t_gcol), .t_color(t_color)
    );

    wire [4:0] glyph;
    hud_rom_font u_font(.code(t_code), .row(t_row), .bits(glyph));

    wire [23:0] g_rgb;
    wire [7:0]  g_alpha;
    hud_gauge u_gauge(
        .clk(clk), .rst_n(rst_n), .x(px), .y(py),
        .ang_a(ang_a), .ang_b(ang_b),
        .o_rgb(g_rgb), .o_alpha(g_alpha)
    );

    // ---------------- 复刻 hud_overlay 的延迟对齐 + 混合 ----------------
    // R1：面板输出打一拍，再查字库
    reg [23:0] qr_rgb; reg [7:0] qr_alpha;
    reg q_hit; reg [5:0] q_code; reg [2:0] q_row, q_gcol; reg [23:0] q_color;

    // 同时把"当拍是哪个像素"也一起延迟，取帧时按延迟后的坐标存
    reg [9:0] px1, py1, px2, py2, px3, py3, px4, py4;
    reg [23:0] base1, base2, base3, base4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qr_rgb <= 24'd0; qr_alpha <= 8'd0; q_hit <= 1'b0;
            q_code <= 6'd0; q_row <= 3'd0; q_gcol <= 3'd0; q_color <= 24'd0;
            px1 <= 10'd0; py1 <= 10'd0; base1 <= 24'd0;
        end else begin
            qr_rgb   <= p_rgb;
            qr_alpha <= p_alpha;
            q_hit    <= t_hit;
            q_code   <= t_code;
            q_row    <= t_row;
            q_gcol   <= t_gcol;
            q_color  <= t_color;
            px1 <= px;     py1 <= py;     base1 <= base_rgb;
        end
    end

    wire [2:0] gci  = (q_gcol <= 3'd4) ? q_gcol : 3'd4;
    wire       gbit = q_hit && (q_gcol <= 3'd4) && glyph[3'd4 - gci];
    wire [23:0] h0_rgb   = gbit ? q_color : qr_rgb;
    wire [7:0]  h0_alpha = gbit ? 8'd255  : qr_alpha;

    // R2/R3/R4
    reg [31:0] p2, p3, p4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2 <= 32'd0; p3 <= 32'd0; p4 <= 32'd0;
            px2 <= 10'd0; py2 <= 10'd0; base2 <= 24'd0;
            px3 <= 10'd0; py3 <= 10'd0; base3 <= 24'd0;
            px4 <= 10'd0; py4 <= 10'd0; base4 <= 24'd0;
        end else begin
            p2 <= {h0_rgb, h0_alpha};  p3 <= p2;  p4 <= p3;
            px2 <= px1; py2 <= py1; base2 <= base1;
            px3 <= px2; py3 <= py2; base3 <= base2;
            px4 <= px3; py4 <= py3; base4 <= base3;
        end
    end

    // 混合（与 hud_overlay.v 里的公式完全一致）
    wire        g_on      = (g_alpha != 8'd0);
    wire [23:0] hud_rgb   = g_on ? g_rgb   : p4[31:8];
    wire [7:0]  hud_alpha = g_on ? g_alpha : p4[7:0];

    wire [8:0]  fa9  = {1'b0, fade} + 9'd1;
    wire [16:0] ae16 = hud_alpha * fa9;
    wire [7:0]  ae   = ae16[15:8];
    wire [9:0]  ae9  = {1'b0, ae} + 10'd1;      // a 必须 10 位，见 hud_overlay.v 注释

    function [7:0] mix8;
        input [7:0] h, b;
        input [9:0] a;
        reg signed [8:0]  d;
        reg signed [18:0] m;
        begin
            d = $signed({1'b0, h}) - $signed({1'b0, b});
            m = d * $signed(a);
            mix8 = b + m[15:8];
        end
    endfunction

    wire [7:0] bl_r = mix8(hud_rgb[23:16], base4[23:16], ae9);
    wire [7:0] bl_g = mix8(hud_rgb[15:8],  base4[15:8],  ae9);
    wire [7:0] bl_b = mix8(hud_rgb[7:0],   base4[7:0],   ae9);

    wire [8:0]  brt  = {1'b0, bright} + 9'd1;
    wire [16:0] or16 = bl_r * brt;
    wire [16:0] og16 = bl_g * brt;
    wire [16:0] ob16 = bl_b * brt;

    wire [23:0] out_rgb = {or16[15:8], og16[15:8], ob16[15:8]};

    // ---------------- 抓帧 ----------------
    reg [23:0] fb [0:307199];
    reg [8*64-1:0] fname;
    integer i;

    always @(posedge clk) begin
        if (px4 < 10'd640 && py4 < 10'd480)
            fb[py4*640 + px4] <= out_rgb;
    end

    task render_to;
        input [8*64-1:0] nm;
        begin
            fname = nm;
            repeat (307200 + 8) @(posedge clk);   // 扫完一整帧
            $display("[%0t] dumping %0s", $time, fname);
            $writememh(fname, fb);
        end
    endtask

    initial begin
        for (i = 0; i < 307200; i = i + 1) fb[i] = 24'd0;
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;

        // 读数 nibble 编码：0..9=数字，E='.'，F=空格
        // ---- 状态 1：P1 RUN MODE，系统正常 ----
        page = 2'd0; fade = 8'd255; bright = 8'd255;
        r1 = 20'h1850F;   // "1850 "
        r2 = 20'h0E85F;   // "0.85 "
        r3 = 20'hFF62F;   // "  62 "
        r4 = 20'hFF78F;   // "  78 "
        lamp = 3'b101; alarm_on = 1'b0; banner = 6'd48;
        ang_a = 10'd830; ang_b = 10'd900;
        render_to("out_render_p0.hex");

        // ---- 状态 2：切页淡出到一半（整层 alpha=127）----
        fade = 8'd127;
        render_to("out_render_fade.hex");

        // ---- 状态 3：P2 ECO MODE，淡入完成 ----
        page = 2'd1; fade = 8'd255;
        r1 = 20'hF684F;   // " 684"  FLOW LPM
        r2 = 20'hF321F;   // " 321"  POWER KW
        ang_a = 10'd900; ang_b = 10'd850;
        render_to("out_render_p1.hex");

        // ---- 状态 4：报警横幅弹出 + 报警灯闪，指针压进红区 ----
        alarm_on = 1'b1; banner = 6'd0; blink = 1'b0;   // blink=0 -> 亮红底
        lamp = 3'b111;
        r2 = 20'h9E95F;   // "9.95 " 油压超限
        r3 = 20'hFF89F;   // "  89 " 温度超限
        ang_b = 10'h15A;  // 668+702 = 1370 -> &0x3FF = 346，落进红区
        render_to("out_render_alarm.hex");

        // ---- 状态 5：P3 MAINT MODE + 亮度调低到第 3 档（bright=191）----
        alarm_on = 1'b0; banner = 6'd48; blink = 1'b0; lamp = 3'b101;
        page = 2'd2; bright = 8'd191;
        r1 = 20'hF320F;   // " 320"  RUNHOUR H
        r2 = 20'hF078F;   // " 078"  CYCLE K
        r3 = 20'hFF35F;   // "  35"  VIBRA MM
        r4 = 20'hFF42F;   // "  42"  WEAR PCT
        ang_a = 10'd700; ang_b = 10'd780;
        render_to("out_render_dim.hex");

        $display("=== RENDER DONE ===");
        $finish;
    end

    initial begin
        #900000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
