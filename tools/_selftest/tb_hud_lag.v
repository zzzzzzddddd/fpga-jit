`timescale 1ns/1ps
// ============================================================================
// tb_hud_lag.v -- 量【指针 vs 读数】的相对时序
//
// tb_hud_live.v 是在 upd_tick【那一拍】采样的，那一拍 d_* 和 row_* 都还是旧值
// （都在同一个沿才更新），所以它看不出滞后 —— 打印里两列永远相等。
//
// 这个 TB 改成在 tick 之后 200 拍再采（那时 BCD 早就算完了）：
//   d_level 已经是【本拍的新值】
//   row_l   是 BCD 从【上一拍的值】算出来的
// ⇒ 两者差多少，就是读数相对指针滞后了多少个 tick。
//
//   iverilog -g2005 -o tools/_selftest/hud_lag.vvp src/hud/hud_data_gen.v tools/_selftest/tb_hud_lag.v
//   vvp tools/_selftest/hud_lag.vvp
// ============================================================================
module tb_hud_lag;

    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg rst_n = 1'b0;
    reg vs    = 1'b1;
    reg k1=0,k2=0,k3=0,k4=0;
    reg [3:0] sw = 4'b0000;

    localparam FRAME_CYC = 500;
    reg [15:0] fcnt = 0;
    always @(posedge clk) begin
        if (fcnt == FRAME_CYC-1) fcnt <= 0; else fcnt <= fcnt + 1;
        vs <= (fcnt < 10) ? 1'b0 : 1'b1;
    end

    wire [2:0]  disp_page, rot_page;
    wire        carousel_en;
    wire [7:0]  alpha, bright;
    wire [9:0]  ang_p, ang_t, ang_l, ang_big;
    wire [19:0] row_p, row_t, row_l;
    wire [2:0]  lamp;
    wire        alarm_on, blink;
    wire [5:0]  banner_off;
    wire        fl_p, fl_t, fl_l;
    wire [7:0]  tr_p, tr_t, tr_l;
    wire        trend_push, frame_tick_o, o_page_chg;
    wire [2:0]  o_img_index;

    hud_data_gen #(.CLK_HZ(25000), .FADE_STEP(128), .BANNER_STEP(48)) dut(
        .clk(clk), .rst_n(rst_n), .vs(vs),
        .key1_press(k1), .key2_press(k2), .key3_press(k3), .key4_press(k4),
        .sw(sw),
        .disp_page(disp_page), .rot_page(rot_page), .carousel_en(carousel_en),
        .alpha(alpha), .bright(bright),
        .ang_p(ang_p), .ang_t(ang_t), .ang_l(ang_l), .ang_big(ang_big),
        .row_p(row_p), .row_t(row_t), .row_l(row_l),
        .lamp(lamp), .alarm_on(alarm_on), .blink(blink), .banner_off(banner_off),
        .fl_p(fl_p), .fl_t(fl_t), .fl_l(fl_l),
        .tr_p(tr_p), .tr_t(tr_t), .tr_l(tr_l), .trend_push(trend_push),
        .frame_tick_o(frame_tick_o), .o_page_chg(o_page_chg), .o_img_index(o_img_index)
    );

    // ---- 通用 3 位 BCD 解码（4'hF = 空格 = 0）----
    function integer dec4;
        input [19:0] r;
        reg [3:0] a,b,c,d;
        begin
            a = r[19:16]; b = r[15:12]; c = r[11:8]; d = r[7:4];
            dec4 = ((a==4'hF)?0:a)*1000 + ((b==4'hF)?0:b)*100
                 + ((c==4'hF)?0:c)*10   + d;
        end
    endfunction

    // ---- tick 之后 200 拍再采（BCD 45 拍就算完了）----
    reg [9:0] dly;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             dly <= 10'd0;
        else if (dut.upd_tick)  dly <= 10'd200;
        else if (dly != 10'd0)  dly <= dly - 10'd1;
    end
    wire sample_now = (dly == 10'd1);

    integer t = 0;
    integer n_tick = 0;          // 采样过的 tick 数
    integer n_mis  = 0;          // 指针与读数不一致的 tick 数
    integer n_ne   = 0;          // d_level 这一拍确实变过的 tick 数

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.upd_tick) t = t + 1;
            if (sample_now) begin
                n_tick = n_tick + 1;
                if (dec4(row_l) != dut.d_level) n_mis = n_mis + 1;
                if (t > 60 && t < 120)
                    $display("tick %0d seg=%0d d_l=%0d row_l=%0d  %s   d_p=%0d row_p=%0d",
                             t, dut.seg, dut.d_level, dec4(row_l),
                             (dec4(row_l) != dut.d_level) ? "<<< 对不上" : "",
                             dut.d_press, dec4(row_p));
            end
            if (dut.upd_tick && dut.d_level !== 14'h3FFF) n_ne = n_ne + 1;
        end
    end

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (460000) @(posedge clk);      // 460000/(25000/8) = 147 个 tick

        $display("");
        $display("==== 指针 vs 读数（每个 tick 采一次，tick 后 200 拍）====");
        $display("采样 tick 数        = %0d", n_tick);
        $display("【读数 != 指针】的 tick 数 = %0d  (%.0f%%)",
                 n_mis, (n_tick==0) ? 0.0 : 100.0*n_mis/n_tick);
        $display("");
        $display("判读：整数显示值跟着 upd_tick（8Hz）一起更新，");
        $display("      而 double-dabble 是自由跑的（每 45 拍把当前值重转一遍）");
        $display("      ⇒ 读数【没有】滞后，应当恒为 0%%。");
        $display("      （曾经以为有 125ms 滞后，那是把 BCD 的刷新当成每个 tick 一次了。）");
        $finish;
    end

    initial begin
        #80000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
