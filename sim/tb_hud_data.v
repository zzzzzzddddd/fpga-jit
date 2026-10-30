`timescale 1ns/1ps
// ============================================================================
// tb_hud_data.v -- 专门验证 hud_data_gen 里"二进制 -> BCD 双 dabble"的转换
//
// 这一段是全工程唯一"算法型"的逻辑（其余都是查表/叠加），单独测一遍比在
// 整帧仿真里看错位的数字快得多：连同 3000 组随机值只要几十万拍。
//
// 双 dabble 一轮 = 10 路 x 15 拍，会连续循环跑，所以"置好值再等 200 拍"就
// 一定能等到那一路被重新转换。force/release 只用于测试，不影响综合。
//
// 【基础融合后】原来靠 key_press 直接翻页，现在翻页的唯一来源是 img_changed
//   （"屏幕刚换成一张新图"）。所以本 TB 把原来的 kp 改成 img_chg：
//   打一拍 img_chg 的效果 = "SD 卡换了一张图"，与按一次 K3 等价。
//   下面所有 page 断言（短按后 P2、再按后 P3）语义不变。
//
// 运行：
//   iverilog -g2005 -o tb_hud_data.vvp -s tb_hud_data \
//       ../src/hud/hud_data_gen.v tb_hud_data.v
//   vvp tb_hud_data.vvp
// ============================================================================
module tb_hud_data;

    reg clk = 1'b0;
    always #20 clk = ~clk;          // 25MHz

    reg rst_n  = 1'b0;
    reg vs     = 1'b1;
    reg img_chg = 1'b0;             // 原 kp：现在代表"换了一张新图"
    reg kl     = 1'b0;

    // 【选题二扩展后新增】sw 必须驱动，悬空会让 hud_data_gen 里的 upd_act 变 X。
    //   SW1 = 0（本 TB 不看 HUD 叠加）
    //   SW2 = 1（报警使能，保持 alarm_on 这条路活着）
    //   SW3 = 0（不冻结，否则 upd_act 恒 0、BCD 不再更新，全部断言失效）
    //   SW4 = 0（关自动轮播。★关键★ CLK_HZ=25000 把 6 秒加速成 6ms，
    //            开着的话 page 会在测试中途自己跳，页相关断言全乱）
    reg [3:0] sw = 4'b0010;

    // 简易场同步：每 FRAME_CYC 拍一个低脉冲（负极性），用来产生 frame_tick
    localparam FRAME_CYC = 5000;
    reg [15:0] fcnt = 16'd0;
    always @(posedge clk) begin
        if (fcnt == FRAME_CYC - 1) fcnt <= 16'd0;
        else                       fcnt <= fcnt + 16'd1;
        vs <= (fcnt < 16'd10) ? 1'b0 : 1'b1;
    end

    wire [1:0]  page;
    wire [7:0]  alpha, bright;
    wire [9:0]  ang_a, ang_b;
    wire [19:0] row1, row2, row3, row4;
    wire [2:0]  lamp;
    wire        alarm_on, blink;
    wire [5:0]  banner_off;
    wire        frame_tick;              // 新增输出，本 TB 不做断言
    wire [7:0]  trend_val;               // 新增输出，同上
    wire        trend_push;
    wire        sw4_beat;                // 基础融合新增输出，本 TB 不做断言

    hud_data_gen #(.CLK_HZ(25000), .FADE_STEP(128), .BANNER_STEP(48)) dut(
        .clk(clk), .rst_n(rst_n), .vs(vs), .key_long(kl),
        .sw(sw),
        .img_changed(img_chg),
        .page(page), .alpha(alpha), .bright(bright),
        .ang_a(ang_a), .ang_b(ang_b),
        .row1(row1), .row2(row2), .row3(row3), .row4(row4),
        .lamp(lamp), .alarm_on(alarm_on), .blink(blink), .banner_off(banner_off),
        .frame_tick_o(frame_tick), .trend_val(trend_val), .trend_push(trend_push),
        .o_sw4_beat(sw4_beat)
    );

    integer errors = 0;
    integer t;
    integer t0;
    integer i;

    function [15:0] to_bcd4;
        input [13:0] v;
        reg [3:0] d3, d2, d1, d0;
        begin
            d3 = (v / 14'd1000) % 14'd10;
            d2 = (v / 14'd100)  % 14'd10;
            d1 = (v / 14'd10)   % 14'd10;
            d0 = v % 14'd10;
            to_bcd4 = {4'd0, d3, d2, d1, d0};
        end
    endfunction

    // ---- 一路一路测：先置值，等整轮扫描，再比 ----
    task test_sel;
        input [3:0]  sel;
        input [13:0] v;
        begin
            case (sel)
                4'd0: force dut.d_rpm   = v;
                4'd1: force dut.d_press = v;
                4'd2: force dut.d_temp  = v;
                4'd3: force dut.d_load  = v;
                4'd4: force dut.x_flow  = v;
                4'd5: force dut.x_pow   = v;
                4'd6: force dut.x_vib   = v;
                4'd7: force dut.x_wear  = v;
                4'd8: force dut.hrs     = v;
                4'd9: force dut.cyc     = v;
            endcase
            repeat (320) @(posedge clk);       // > 2 个扫描周期(150)，确保新值已被转换
            if (dut.bcd_res[sel] !== to_bcd4(v)) begin
                errors = errors + 1;
                $display("FAIL sel=%0d v=%0d got=%h exp=%h",
                         sel, v, dut.bcd_res[sel], to_bcd4(v));
            end else begin
                $display("ok   sel=%0d v=%0d bcd=%h", sel, v, dut.bcd_res[sel]);
            end
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (400) @(posedge clk);           // 等第一轮扫描完成

        // ---- 先做一次"无 force"的自然计数检查：小时/循环计数器必须稳定增长 ----
        $display("自然计数起点: hrs=%0d cyc=%0d", dut.hrs, dut.cyc);
        repeat (200000) @(posedge clk);
        $display("20 万拍后    : hrs=%0d cyc=%0d  (期望 hrs≈1244 cyc≈334)", dut.hrs, dut.cyc);
        if (dut.hrs < 14'd1240 || dut.cyc < 14'd318) begin
            errors = errors + 1;
            $display("FAIL 计数器不应该倒退");
        end

        // ---- 边界值 ----
        test_sel(4'd0, 14'd0);     test_sel(4'd0, 14'd7);
        test_sel(4'd0, 14'd10);    test_sel(4'd0, 14'd99);
        test_sel(4'd0, 14'd100);   test_sel(4'd0, 14'd999);
        test_sel(4'd0, 14'd1000);  test_sel(4'd0, 14'd2500);
        test_sel(4'd0, 14'd9999);
        test_sel(4'd1, 14'd85);    test_sel(4'd1, 14'd999);
        test_sel(4'd2, 14'd3);     test_sel(4'd2, 14'd103);
        test_sel(4'd3, 14'd55);
        test_sel(4'd4, 14'd852);   test_sel(4'd5, 14'd401);
        test_sel(4'd6, 14'd47);    test_sel(4'd7, 14'd98);
        test_sel(4'd8, 14'd1240);  test_sel(4'd9, 14'd318);

        // ---- 随机全覆盖 ----
        t0 = errors;
        for (t = 0; t < 2000; t = t + 1) begin
            force dut.d_rpm = t[13:0];         // 0..1999 连续扫
            repeat (320) @(posedge clk);
            if (dut.bcd_res[0] !== to_bcd4(t[13:0])) begin
                errors = errors + 1;
                if (errors - t0 < 10)
                    $display("FAIL 随机 v=%0d got=%h exp=%h",
                             t, dut.bcd_res[0], to_bcd4(t[13:0]));
            end
        end
        $display("随机扫描 2000 组完成，新增错误 %0d", errors - t0);
        $display("release 前: hrs=%0d cyc=%0d div16=%0d bcd8=%h bcd9=%h",
                 dut.hrs, dut.cyc, dut.div16, dut.bcd_res[8], dut.bcd_res[9]);

        release dut.d_rpm;  release dut.d_press; release dut.d_temp;
        release dut.d_load; release dut.x_flow;  release dut.x_pow;
        release dut.x_vib;  release dut.x_wear;  release dut.hrs; release dut.cyc;

        // ---- 读数显示格式 ----
        repeat (2000) @(posedge clk);
        $display("release 后: hrs=%0d cyc=%0d div16=%0d bcd8=%h bcd9=%h",
                 dut.hrs, dut.cyc, dut.div16, dut.bcd_res[8], dut.bcd_res[9]);
        $display("P%0d row1=%h row2=%h row3=%h row4=%h  (rpm=%0d press=%0d temp=%0d load=%0d)",
                 page+1, row1, row2, row3, row4,
                 dut.d_rpm, dut.d_press, dut.d_temp, dut.d_load);

        // ---- 翻页：逐帧打出 page/alpha，检查淡出->换页->淡入 ----
        img_chg = 1'b1; @(posedge clk); img_chg = 1'b0;
        for (i = 0; i < 6; i = i + 1) begin
            @(posedge vs); @(negedge vs);
            $display("  翻页中 帧%0d: page=P%0d alpha=%0d", i, page+1, alpha);
        end
        if (page !== 2'd1) begin
            errors = errors + 1;
            $display("FAIL 短按后页号应为 1，实际 %0d", page);
        end
        repeat (3000) @(posedge clk);
        $display("翻页后 P%0d row1=%h row2=%h row3=%h row4=%h (flow=%0d pow=%0d)",
                 page+1, row1, row2, row3, row4, dut.x_flow, dut.x_pow);

        img_chg = 1'b1; @(posedge clk); img_chg = 1'b0;
        repeat (20000) @(posedge clk);
        if (page !== 2'd2) begin
            errors = errors + 1;
            $display("FAIL 第二次短按后页号应为 2，实际 %0d", page);
        end
        $display("翻页后 P%0d row1=%h row2=%h row3=%h row4=%h (hrs=%0d cyc=%0d)",
                 page+1, row1, row2, row3, row4, dut.hrs, dut.cyc);

        // ---- 亮度 ----
        $display("bright 初始 = %0d", bright);
        kl = 1'b1; @(posedge clk); kl = 1'b0;
        repeat (10) @(posedge clk);
        $display("长按一次后 bright = %0d", bright);

        // ---- 指针角度应落在 -125..+125 度对应区间 ----
        $display("ang_a=%0d ang_b=%0d  (合法区间 668..1379 取模)", ang_a, ang_b);

        if (errors == 0) $display("=== BCD TEST PASS ===");
        else             $display("=== BCD TEST FAIL, errors=%0d ===", errors);
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
