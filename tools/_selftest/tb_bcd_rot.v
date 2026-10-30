`timescale 1ns/1ps
// ============================================================================
// tb_bcd_rot.v -- 单独验 hud_data_gen 里 double-dabble 的【源选择对不对路】
//
// 要证明的事（一个断言）：
//     bcd_res[0] 必须是【压力】、bcd_res[1] 必须是【温度】、bcd_res[2] 必须是【液位】
// 因为下游是：
//     row_p <= fmt_bcdpress(bcd_res[0])   面板上写在「压力」那一栏
//     row_t <= fmt_bcd4    (bcd_res[1])   面板上写在「温度」那一栏
//     row_l <= fmt_bcd4    (bcd_res[2])   面板上写在「液位」那一栏
// 三者一旦错位，屏幕上的数字就和旁边的表盘指的不是同一个量。
//
// 做法：把三个量 force 成三个【一眼能区分】的数（111 / 222 / 33），
//       等它跑完几轮转换，再看 bcd_res 落在谁身上。
//
// 运行：
//   iverilog -g2005 -o tools/_selftest/bcd_rot.vvp src/hud/hud_data_gen.v tools/_selftest/tb_bcd_rot.v
//   vvp tools/_selftest/bcd_rot.vvp
// ============================================================================
module tb_bcd_rot;

    reg clk = 1'b0;
    always #20 clk = ~clk;                 // 25MHz

    reg rst_n = 1'b0;
    reg vs    = 1'b1;
    reg k1 = 0, k2 = 0, k3 = 0, k4 = 0;
    reg [3:0] sw = 4'b0000;

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

    // CLK_HZ 取小值把 8Hz 节拍压缩到 3125 拍，仿真几十微秒就跑完
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

    integer errs = 0;

    function [15:0] bcd4;
        input [13:0] v;
        reg [3:0] d3, d2, d1, d0;
        begin
            d3 = (v / 14'd1000) % 14'd10;
            d2 = (v / 14'd100)  % 14'd10;
            d1 = (v / 14'd10)   % 14'd10;
            d0 = v % 14'd10;
            bcd4 = {d3, d2, d1, d0};
        end
    endfunction

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (300) @(posedge clk);

        force dut.d_press = 14'd111;
        force dut.d_temp  = 14'd222;
        force dut.d_level = 14'd33;
        repeat (4000) @(posedge clk);

        $display("d_press=%0d  d_temp=%0d  d_level=%0d",
                 dut.d_press, dut.d_temp, dut.d_level);
        $display("bcd_res[0]=%h  期望 %h   (=压力 111)", dut.bcd_res[0], bcd4(14'd111));
        $display("bcd_res[1]=%h  期望 %h   (=温度 222)", dut.bcd_res[1], bcd4(14'd222));
        $display("bcd_res[2]=%h  期望 %h   (=液位  33)", dut.bcd_res[2], bcd4(14'd33));
        $display("row_p=%h  row_t=%h  row_l=%h", row_p, row_t, row_l);

        if (dut.bcd_res[0] !== bcd4(14'd111)) errs = errs + 1;
        if (dut.bcd_res[1] !== bcd4(14'd222)) errs = errs + 1;
        if (dut.bcd_res[2] !== bcd4(14'd33 )) errs = errs + 1;

        if (errs == 0) $display("=== BCD ROUTING PASS ===");
        else           $display("=== BCD ROUTING FAIL, mismatches=%0d ===", errs);
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
