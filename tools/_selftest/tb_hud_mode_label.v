`timescale 1ns/1ps
// ============================================================================
// tb_hud_mode_label.v -- 顶栏「轮播/手动」标识到底会不会显示、显示成哪几个字
//
// 为什么需要它：这个标识放在顶栏第一行，而顶栏那一行已经被标题（MIXED=1，
// 字窗 12..364）占掉一大片。hud_label 的 hit 输出是【整个字窗矩形】而不是
// "有墨的那几列"，而 hud_panel 的文本优先级链里 h_title 排在 h_mode 之前
// ⇒ 只要标识的字窗被标题的字窗包住，h_mode 永远轮不到、一个像素都画不出来，
//   而且不报任何错。几何推算能证，但不如逐像素跑一遍硬。
//
// 这个 TB 做的事：
//   ① 在最左列逐格采样 hud_panel 输出的 t_code，断言 6 个格子的编码序列
//      正好等于 "(AUTO)" / "(MANU)"（编码取自 hud_label.v 的 ch2code）；
//   ② 用 hud_rom_font 把整个 48x8 区域重建成点阵打出来，人眼可核；
//   ③ 反向对照：同样采 x=260..308 那 6 格 —— 预期拿到的是【标题】的编码
//      而不是标识的，用来证明"这条判据确实抓得住那个坑"。
//      （若哪天有人把 X0 改回 260，① 和 ③ 会得到同一组编码，① 就会 FAIL。）
//
//   ★ 断言的是【编码序列】不是"t_hit 是不是 1" ★
//     x=260 那会儿 t_hit 也是 1（被标题的 hit 覆盖），只看 t_hit 分辨不出来
//     —— 这正是 [[td-checker-blind-spots]] 里"有无型判据"的老毛病。
//
// 跑法：
//   iverilog -g2005 -o tools/_selftest/mode_label.vvp \
//       src/hud/hud_panel.v src/hud/hud_label.v src/hud/hud_rom_font.v \
//       tools/_selftest/tb_hud_mode_label.v
//   vvp tools/_selftest/mode_label.vvp
// ============================================================================
module tb_hud_mode_label;

    localparam X_MODE = 388;          // 必须与 hud_panel.v 里 u_lbl_mode 的 X0 一致
    localparam X_NEG  = 260;          // 反向对照：旧的那次摆放
    localparam LEN    = 6;            // "(AUTO)" 6 个字符
    localparam CELL   = 8;            // MIXED=0 且 SCALE=1 -> 8px 一格
    localparam Y0     = 10;

    reg  [9:0] x = 10'd0, y = 10'd0;
    reg        carousel_en = 1'b1;

    wire [23:0] o_rgb;  wire [7:0] o_alpha;  wire o_big;
    wire        t_hit, t_font;
    wire [5:0]  t_code;
    wire [7:0]  t_ccode;
    wire [2:0]  t_row, t_gcol;
    wire [3:0]  t_crow, t_gccol;
    wire [23:0] t_color;

    hud_panel dut(
        .x(x), .y(y),
        .disp_page(3'd0), .row_p(20'd0), .row_t(20'd0), .row_l(20'd0),
        .lamp(3'b101), .alarm_on(1'b0), .blink(1'b0),
        .banner_off(6'd48),                 // 横幅完全收在屏幕下方
        .carousel_en(carousel_en),
        .bright(8'd255), .sw(4'b0000),
        .fl_p(1'b0), .fl_t(1'b0), .fl_l(1'b0),
        .o_rgb(o_rgb), .o_alpha(o_alpha), .o_big(o_big),
        .t_hit(t_hit), .t_font(t_font), .t_code(t_code), .t_ccode(t_ccode),
        .t_row(t_row), .t_crow(t_crow), .t_gcol(t_gcol), .t_gccol(t_gccol),
        .t_color(t_color)
    );

    // 5x7 字库：由 TB 直接例化，用面板输出的 (code,row) 取字形位
    wire [4:0] rom_bits;
    hud_rom_font u_rom(.code(t_code), .row(t_row), .bits(rom_bits));

    integer fail = 0;

    // ---- 在 (x0..x0+LEN*CELL-1) × (Y0..Y0+7) 上逐格采样，返回编码序列 ----
    //   约定：每个字格取它最左那一列的 t_code（同一格内 t_code 恒定）
    task sample_codes;
        input  [9:0] x0;
        output [5:0] c0, c1, c2, c3, c4, c5;
        begin
            y = Y0;
            x = x0 + 0*CELL; #1; c0 = t_code;
            x = x0 + 1*CELL; #1; c1 = t_code;
            x = x0 + 2*CELL; #1; c2 = t_code;
            x = x0 + 3*CELL; #1; c3 = t_code;
            x = x0 + 4*CELL; #1; c4 = t_code;
            x = x0 + 5*CELL; #1; c5 = t_code;
        end
    endtask

    // 点阵重建：把 x0..x0+47 × Y0..Y0+7 打出来
    task dump_art;
        input [9:0] x0;
        input [8*16-1:0] tag;
        integer dx, dy;
        reg  ink;
        begin
            $display("  ---- %0s （x=%0d）----", tag, x0);
            for (dy = 0; dy < 8; dy = dy + 1) begin
                y = Y0 + dy[9:0];
                $write("    |");
                for (dx = 0; dx < LEN*CELL; dx = dx + 1) begin
                    x = x0 + dx[9:0]; #1;
                    // 与 hud_overlay 的 ASCII 文字通路同一判据：
                    //   t_hit && 不是汉字 && 列在 0..4 且字库那一位为 1
                    ink = t_hit && !t_font && (t_gcol < 3'd5) && rom_bits[4 - t_gcol];
                    $write("%0s", ink ? "#" : ".");
                end
                $write("|\n");
            end
        end
    endtask

    reg [5:0] m0,m1,m2,m3,m4,m5;
    reg [5:0] n0,n1,n2,n3,n4,n5;

    // ch2code 的期望值（取自 hud_label.v，手工表）：
    //   '('=48  'A'=11  'U'=31  'T'=30  'O'=25  ')'=49
    //   'M'=23  'N'=24
    localparam [5:0] K_LP = 6'd48, K_RP = 6'd49;
    localparam [5:0] K_A  = 6'd11, K_U  = 6'd31, K_T = 6'd30, K_O = 6'd25;
    localparam [5:0] K_M  = 6'd23, K_N  = 6'd24;

    initial begin
        $display("");
        $display("================ 顶栏模式标识 渲染核对 ================");

        // ---------- ① 自动轮播 -> "(AUTO)" ----------
        carousel_en = 1'b1;
        sample_codes(X_MODE, m0,m1,m2,m3,m4,m5);
        $display("  carousel_en=1  采到的编码序列: %0d %0d %0d %0d %0d %0d",
                 m0,m1,m2,m3,m4,m5);
        $display("  期望           ( A U T O ) = %0d %0d %0d %0d %0d %0d",
                 K_LP,K_A,K_U,K_T,K_O,K_RP);
        if (!(m0==K_LP && m1==K_A && m2==K_U && m3==K_T && m4==K_O && m5==K_RP)) begin
            $display("  ★FAIL: 自动模式没渲染成 (AUTO)");
            fail = fail + 1;
        end
        dump_art(X_MODE, "(AUTO)");

        // ---------- ② 手动 -> "(MANU)" ----------
        carousel_en = 1'b0;
        sample_codes(X_MODE, m0,m1,m2,m3,m4,m5);
        $display("  carousel_en=0  采到的编码序列: %0d %0d %0d %0d %0d %0d",
                 m0,m1,m2,m3,m4,m5);
        $display("  期望           ( M A N U ) = %0d %0d %0d %0d %0d %0d",
                 K_LP,K_M,K_A,K_N,K_U,K_RP);
        if (!(m0==K_LP && m1==K_M && m2==K_A && m3==K_N && m4==K_U && m5==K_RP)) begin
            $display("  ★FAIL: 手动模式没渲染成 (MANU)");
            fail = fail + 1;
        end
        dump_art(X_MODE, "(MANU)");

        // ---------- ③ 反向对照：旧位置 x=260 ----------
        carousel_en = 1'b1;
        sample_codes(X_NEG, n0,n1,n2,n3,n4,n5);
        $display("");
        $display("  [对照] x=%0d 处采到的编码: %0d %0d %0d %0d %0d %0d",
                 X_NEG, n0,n1,n2,n3,n4,n5);
        if (n0==K_LP && n1==K_A && n2==K_U && n3==K_T && n4==K_O && n5==K_RP)
            $display("  ★注意: x=%0d 也拿到了 (AUTO) —— 说明这条判据分不出摆放位置★", X_NEG);
        else
            $display("  OK: x=%0d 拿到的是别的东西（标题的字），证明本判据抓得住那个坑", X_NEG);

        $display("");
        if (fail == 0)
            $display("=== PASS: 标识区 6 个字格的编码序列正确，且逐像素点阵已打出 ===");
        else
            $display("=== FAIL: %0d 项不对 ===", fail);
        $finish;
    end

endmodule
