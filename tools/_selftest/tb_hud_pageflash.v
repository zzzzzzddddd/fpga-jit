`timescale 1ns/1ps
// ============================================================================
// tb_hud_pageflash.v -- 用户报「屏幕上有闪烁，好像漏电一样」
//
// 上一版 tb_hud_tour 用的是 .FADE_STEP(128)（把淡入淡出压到最短，好让统计快）。
// 这一版【故意用真实参数】：FADE_STEP=12 / ALARM_STEP=64 / 帧 60Hz，
// 目的不是"页对不对"，而是【disp_page 多久变一次】——
//   整屏闪 = 淡入淡出被反复触发 = dst_page 在反复变 = alarm_active 或 rot_page 在抖。
//
// CLK_HZ_S = 25000（1 秒 = 25000 拍），FRAME_CYC = 417（≈60.0Hz，和真板一致）
//   ⇒ 淡出 255/12 = 21 帧 = 0.355 秒、报警快切 255/64 = 4 帧 = 67ms —— 与上板同量级。
//
// 判据：任何一次 disp_page 变化，若离上一次 < 0.5 秒，就记一次【闪】。
//       一段 8 秒内出现 >=2 次翻页 = 屏幕上就是"在闪"。
//
//   iverilog -g2005 -o tools/_selftest/pageflash.vvp src/hud/hud_data_gen.v tools/_selftest/tb_hud_pageflash.v
//   vvp tools/_selftest/pageflash.vvp
// ============================================================================
module tb_hud_pageflash;

    localparam CLK_HZ_S  = 25000;
    localparam FRAME_CYC = 417;                    // 25000/417 = 59.95Hz
    localparam RUN_CYC   = CLK_HZ_S * 130;         // 130 秒 ≈ 2 个脚本周期
    localparam FLASH_GAP = CLK_HZ_S / 2;           // 0.5 秒 = "闪"的门限

    reg clk = 1'b0;
    always #20 clk = ~clk;                         // 25MHz

    reg rst_n = 1'b0;
    reg vs    = 1'b1;
    reg k1=0,k2=0,k3=0,k4=0;
    reg [3:0] sw = 4'b0000;

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

    hud_data_gen #(.CLK_HZ(CLK_HZ_S),
                   .FADE_STEP(12), .ALARM_STEP(64), .BANNER_STEP(4)
                  ) dut(
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

    // ---- 计时与事件统计 ----
    integer tcyc = 0;
    always @(posedge clk) if (rst_n) tcyc = tcyc + 1;

    reg [2:0] dp_prev = 3'd7;                       // 7 = 还没开始
    integer   n_change = 0, n_flash = 0, n_burst_max = 0, burst = 0;
    real      last_t = 0.0;

    // 报警标志的跳变（chatter 的直接证据）
    integer n_flp = 0, n_flt = 0, n_fll = 0, n_alarm = 0;
    reg     p_flp=0, p_flt=0, p_fll=0, p_alm=0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (dp_prev !== 3'd7 && disp_page !== dp_prev) begin
                n_change = n_change + 1;
                if (($itor(tcyc) - last_t) < (FLASH_GAP/1.0)) begin
                    n_flash = n_flash + 1;
                    burst   = burst + 1;
                    if (burst > n_burst_max) n_burst_max = burst;
                    $display("  [闪 %0d] t=%0.2fs  disp_page %0d -> %0d   (alarm_active=%b fl=%b%b%b)",
                             n_flash, tcyc/25000.0, dp_prev, disp_page, dut.alarm_active,
                             fl_p, fl_t, fl_l);
                end else begin
                    burst = 0;
                end
                last_t = $itor(tcyc);
            end
            if (dp_prev === 3'd7) last_t = $itor(tcyc);
            dp_prev = disp_page;

            if (fl_p  !== p_flp) begin n_flp = n_flp + 1; p_flp = fl_p; end
            if (fl_t  !== p_flt) begin n_flt = n_flt + 1; p_flt = fl_t; end
            if (fl_l  !== p_fll) begin n_fll = n_fll + 1; p_fll = fl_l; end
            if (dut.alarm_active !== p_alm) begin
                n_alarm = n_alarm + 1; p_alm = dut.alarm_active;
            end
        end
    end

    // 最长的"稳定"间隔（页停多久不换）
    real max_stable = 0.0, stable_start = 0.0;
    always @(posedge clk) begin
        if (rst_n && dp_prev !== 3'd7 && disp_page !== dp_prev) begin
            if (($itor(tcyc) - stable_start) > max_stable)
                max_stable = $itor(tcyc) - stable_start;
            stable_start = $itor(tcyc);
        end
    end

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (RUN_CYC) @(posedge clk);

        $display("");
        $display("================ 结果（跑了 %0d 秒）================", RUN_CYC/CLK_HZ_S);
        $display("disp_page 变化次数        = %0d", n_change);
        $display("其中【距上次 < 0.5 秒】    = %0d   <-- 这就是屏幕在闪", n_flash);
        $display("最长连续闪的次数          = %0d", n_burst_max);
        $display("最长一次稳定不换页        = %0.2f 秒", max_stable/25000.0);
        $display("");
        $display("fl_p 跳变 %0d 次 / fl_t %0d 次 / fl_l %0d 次", n_flp, n_flt, n_fll);
        $display("alarm_active 跳变 %0d 次", n_alarm);
        $display("（2 个脚本周期 = 8 次报警 ⇒ 每个标志理想 8~10 次跳变）");
        if (n_flash == 0)
            $display("=== PASS: 没有任何快翻页 —— 整屏闪不是这一层引起的 ===");
        else
            $display("=== FAIL: 检出 %0d 次快翻页 ===", n_flash);
        $finish;
    end

    initial begin
        #500000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
