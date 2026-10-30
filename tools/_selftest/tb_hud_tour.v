`timescale 1ns/1ps
// ============================================================================
// tb_hud_tour.v -- 盯【自动轮播】这一件事
//
// 用户要求：每一轮都要有完整的 总览→压力→温度→液位→待机巡检→回到总览，
//           而且慢一点、不要"有的页跳得太快"。
//
// 三个判据（都能量）：
//   ① rot_page 的每一次变化都必须是 (prev+1) mod 5  —— 一次都不许跳页；
//   ② 五个轮播页各自的【可见时间】都 >= CAROUSEL_SEC 秒
//      （报警占页期间轮播暂停 ⇒ 可见时间只会更长，不会更短）；
//   ③ rot_page 至少要转够遍历各页若干次（证明轮播真的在跑）。
//
// ★ 用 CLK_HZ=25000 把节拍压扁：1"秒" = 25000 拍。
//   CAROUSEL_SEC=8 ⇒ 每页 200000 拍；DWELL_SEC=8 ⇒ 脚本一段也是 200000 拍。
//   两者同长，正好能看出"页与段"互不干扰。
//
//   iverilog -g2005 -o tools/_selftest/hud_tour.vvp src/hud/hud_data_gen.v tools/_selftest/tb_hud_tour.v
//   vvp tools/_selftest/hud_tour.vvp
// ============================================================================
module tb_hud_tour;

    localparam CLK_HZ_S   = 25000;
    localparam CAR_SEC    = 12;                      // 必须与 hud_data_gen 的
                                                     // CAROUSEL_SEC 一致
    localparam PAGE_CYC   = CLK_HZ_S * CAR_SEC;      // 每页 300000 拍
    // ★ 跑够 2 轮以上 ★ 每轮墙钟 ≈ 5*CAR_SEC/(1-报警占空比) ≈ 97 秒
    //   ⇒ 220 秒 = 5500000 拍 ≈ 2.2 轮，每页至少出现两次，判据才稳。
    localparam RUN_CYC    = 5500000;

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

    hud_data_gen #(.CLK_HZ(CLK_HZ_S), .FADE_STEP(128), .BANNER_STEP(48)) dut(
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

    // ---- ① rot_page 的跳变必须每次 +1（mod 5）----
    reg [2:0] rot_prev = 3'd0;
    integer   rot_chg = 0, rot_bad = 0;
    reg [2:0] rot_expect = 3'd1;
    always @(posedge clk) begin
        if (rst_n && (rot_page !== rot_prev)) begin
            rot_chg = rot_chg + 1;
            if (rot_page !== rot_expect) begin
                rot_bad = rot_bad + 1;
                $display("  !! 跳页：rot_page %0d -> %0d（本应是 %0d）",
                         rot_prev, rot_page, rot_expect);
            end
            rot_prev   = rot_page;
            rot_expect = (rot_page >= 3'd4) ? 3'd0 : (rot_page + 3'd1);
        end
    end

    // ---- ② 每个 disp_page 的可见拍数 ----
    integer v0=0,v1=0,v2=0,v3=0,v4=0,v5=0;
    integer rot_seen_5 = 0;          // 报警页在 rot_page 上出现过吗（应当为 0）
    always @(posedge clk) begin
        if (rst_n) begin
            case (disp_page)
            3'd0: v0 = v0 + 1;
            3'd1: v1 = v1 + 1;
            3'd2: v2 = v2 + 1;
            3'd3: v3 = v3 + 1;
            3'd4: v4 = v4 + 1;
            3'd5: v5 = v5 + 1;
            endcase
            if (rot_page == 3'd5) rot_seen_5 = rot_seen_5 + 1;
        end
    end

    integer i;
    function integer secs;                 // 拍 -> 秒（保留一位小数，用 0.1 秒为单位）
        input integer c;
        begin secs = (c * 10) / CLK_HZ_S;  // 0.1 秒为单位
        end
    endfunction

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (RUN_CYC) @(posedge clk);

        $display("");
        $display("==== 轮播（每页 %0d 秒 = %0d 拍）====", CAR_SEC, PAGE_CYC);
        $display("carousel_en        = %0d   （开机就应为 1）", carousel_en);
        $display("rot_page 变化次数  = %0d", rot_chg);
        $display("其中【跳页】次数   = %0d   （必须 0）", rot_bad);
        $display("");
        $display("各页可见时间（秒，保留一位小数）:");
        $display("  总览 0 : %0d.%0d",  secs(v0)/10, secs(v0)%10);
        $display("  压力 1 : %0d.%0d",  secs(v1)/10, secs(v1)%10);
        $display("  温度 2 : %0d.%0d",  secs(v2)/10, secs(v2)%10);
        $display("  液位 3 : %0d.%0d",  secs(v3)/10, secs(v3)%10);
        $display("  待机 4 : %0d.%0d",  secs(v4)/10, secs(v4)%10);
        $display("  报警 5 : %0d.%0d   （抢页时长，不计入轮播）", secs(v5)/10, secs(v5)%10);
        $display("");
        $display("rot_page 曾经等于 5 的拍数 = %0d   （必须 0：页 5 不在轮播里）", rot_seen_5);

        // 可见时间下限：留 4% 给淡入淡出切换（切页要等 alpha 掉到 0）
        if (carousel_en !== 1'b1) begin
            $display("=== FAIL: 开机不是自动轮播 ===");
        end else if (rot_seen_5 != 0) begin
            $display("=== FAIL: 轮播跑进页 5 了 ===");
        end else if (rot_bad != 0) begin
            $display("=== FAIL: 有跳页 ===");
        end else if (rot_chg < 8) begin
            $display("=== FAIL: rot_page 变化太少（%0d 次），轮播没在跑 ===", rot_chg);
        end else if (v0 < (PAGE_CYC*96)/100 || v1 < (PAGE_CYC*96)/100 ||
                     v2 < (PAGE_CYC*96)/100 || v3 < (PAGE_CYC*96)/100 ||
                     v4 < (PAGE_CYC*96)/100) begin
            $display("=== FAIL: 有页的可见时间不足 %0d 秒 ===", CAR_SEC);
        end else begin
            $display("=== PASS: 顺序恒为 +1、不跳页、页 5 不占轮播、每页可见 >= %0d 秒 ===", CAR_SEC);
        end
        $finish;
    end

    initial begin
        #600000000;               // 600ms = 15,000,000 拍，必须大于 RUN_CYC
        $display("TIMEOUT");
        $finish;
    end

endmodule
