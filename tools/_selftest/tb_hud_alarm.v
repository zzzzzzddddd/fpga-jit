`timescale 1ns/1ps
// ============================================================================
// tb_hud_alarm.v -- 跑满两个完整的 64 秒脚本周期，看报警标志有没有【乱翻】
//
// 为什么必须有这个 TB：
//   第三十二版把报警的判据从【显示值 d_*】改成了【平滑值 v_*】，同时把显示
//   抖动从 ±3 放大到 ±6。这两件事都要证明"报警不会来回翻"：
//     * 判 v_* ⇒ 抖动碰不到报警（这是放开幅度的前提）；
//     * 回差 6/4/4/3 保持 ⇒ 段目标停在门限附近也不会抖。
//   "报警乱翻"在屏幕上就是【报警页一闪一闪 + 蜂鸣器哒哒响】，是最像"坏了"的
//   一种症状，所以这条必须量，不能靠推。
//
// 脚本一轮的预期（每段 8 秒，64 秒一轮）：
//   seg1  压力越 120          -> fl_p 置位
//   seg3  压力回 70           -> fl_p 复位；温度越 95 -> fl_t 置位
//   seg5  温度回 62           -> fl_t 复位；液位跌破 20 -> fl_l_lo 置位
//   seg7  液位回 88（先过 24） -> fl_l_lo 复位；液位越 85 -> fl_l_hi 置位
//   seg0  液位回 55（过 82）  -> fl_l_hi 复位
//   ⇒ 四个标志，每个周期各置位一次、复位一次 = 每周期各 2 次跳变。
//     跑两个周期 ⇒ 各 4 次。多于 4 次就是翻。
//
//   iverilog -g2005 -o tools/_selftest/hud_alarm.vvp src/hud/hud_data_gen.v tools/_selftest/tb_hud_alarm.v
//   vvp tools/_selftest/hud_alarm.vvp
// ============================================================================
module tb_hud_alarm;

    reg clk = 1'b0;
    always #20 clk = ~clk;                 // 25MHz

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

    reg [3:0] last     = 4'hF;
    integer   n_p = 0, n_t = 0, n_lo = 0, n_hi = 0;
    reg [3:0] last_seg = 4'hF;
    integer   tick = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.upd_tick) tick = tick + 1;

            if (dut.seg !== last_seg) begin
                last_seg = dut.seg;
                $display("  seg -> %0d   v_p=%0d v_t=%0d v_l=%0d",
                         dut.seg, dut.v_press, dut.v_temp, dut.v_level);
            end

            if (dut.fl_p_r    !== last[3]) begin n_p  = n_p  + 1; $display("    fl_p    -> %b  (tick %0d)", dut.fl_p_r,    tick); end
            if (dut.fl_t_r    !== last[2]) begin n_t  = n_t  + 1; $display("    fl_t    -> %b  (tick %0d)", dut.fl_t_r,    tick); end
            if (dut.fl_l_lo_r !== last[1]) begin n_lo = n_lo + 1; $display("    fl_l_lo -> %b  (tick %0d)", dut.fl_l_lo_r, tick); end
            if (dut.fl_l_hi_r !== last[0]) begin n_hi = n_hi + 1; $display("    fl_l_hi -> %b  (tick %0d)", dut.fl_l_hi_r, tick); end
            last = {dut.fl_p_r, dut.fl_t_r, dut.fl_l_lo_r, dut.fl_l_hi_r};
        end
    end

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        // 两个完整周期：2 × 8 段 × 200000 拍 = 3.2e6 拍
        // ★ 跑 2 个周期【再多 1 段】★
        //   fl_l_hi 是"seg7 置位、下一个 seg0 复位"，它的复位跨周期边界；
        //   只跑整 2 个周期的话第二个周期的那次复位落在窗口外，
        //   四个标志的跳变次数就不齐，判据也跟着难写。多跑一段 seg0 正好补齐。
        repeat (3400000) @(posedge clk);

        $display("");
        $display("==== 两个完整周期（128 秒脚本时间）的报警跳变次数 ====");
        // 计数含 t=0 那次（last 复位成 4'hF，第一拍四个标志都算跳了一次）
        // ⇒ 期望 = 1 + 2 个周期 × 每周期 2 次（置位 + 复位）= 5
        $display("  fl_p    = %0d  (期望 5 = 1 次初值 + 2 周期 × 2)", n_p);
        $display("  fl_t    = %0d  (期望 5)", n_t);
        $display("  fl_l_lo = %0d  (期望 5)", n_lo);
        $display("  fl_l_hi = %0d  (期望 5)", n_hi);
        if (n_p == 5 && n_t == 5 && n_lo == 5 && n_hi == 5)
            $display("=== PASS: 四个报警标志每周期各置位/复位一次，没有来回翻 ===");
        else
            $display("=== FAIL: 跳变次数不对 ⇒ 报警在翻（查回差/门限）===");
        $finish;
    end

    initial begin
        #400000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
