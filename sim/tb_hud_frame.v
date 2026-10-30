`timescale 1ns/1ps
// ============================================================================
// tb_hud_frame.v -- 工业 HUD 整链仿真：真实时序 + 真图 ROM -> 导出整帧
//
// 链路：自建 640x480@60 时序 -> video_delay(20 拍，模拟 SDRAM 帧缓存)
//        -> hud_top(HUD 叠加) -> 抓一帧 -> $writememh 成 .hex
//        -> tools/hex2bmp.py 转成 BMP
//        （在 Verilog 里逐字节拼 BMP 要 92 万次 $fwrite，慢得离谱，
//          所以仿真只导 hex，转换交给 Python）
//
// 【注意】下面的输出文件名是相对路径，请在 sim 目录下运行 vvp：
//     cd sim
//     vvp tb_hud.vvp
//     python ../tools/hex2bmp.py
//
// 仿真加速（只影响秒级定时器，不影响像素流水线和画面的最终形态）：
//   CLK_HZ=25000   消抖/数据刷新/报警计时 快 1000 倍
//   FADE_STEP=128  翻页淡入淡出 2 帧走完（真实 12，约 21 帧）
//   BANNER_STEP=48 报警横幅 1 帧弹满（真实 4，约 12 帧）
// 报警那一帧用 force 直接按住 alarm_hold，纯粹为了省仿真时间。
//
// 【选题二扩展后新增：sw / state_code / 数码管输出】
//   sw 必须显式驱动，不能悬空（Z 会让 hud_data_gen 里的 upd_act 变 X）。
//   本 TB 用的是 4'b0011，即：
//     SW1 = 1  HUD 叠加总开关【必须为 1】，否则 hud_overlay 直接旁路，
//              抓出来的就是纯底图，所有 golden 帧全部失效；
//     SW2 = 1  报警使能【必须为 1】，alarm_on = (alarm_hold!=0) && sw[1]，
//              下面 force alarm_hold 的那两个场景靠它才出得来；
//     SW3 = 0  不冻结；
//     SW4 = 0  关自动轮播。★这条最关键★ CLK_HZ=25000 把 6 秒定时器加速成
//              6ms，sw[3]=1 的话一帧之内就会自动翻页，跑旧场景会在中途切页。
//   state_code 是报警时右字段数码管要显示的诊断码，这里给个固定值。
//   数码管三根输出本 TB 不检查，但要接出来避免悬空告警。
//
// 【基础融合后新增：frame_sel_v】
//   K3 短按不再直接翻页 —— 翻页的唯一来源是 hud_top 内部的 img_changed，
//   而它由 frame_sel_v 的跳变（"屏幕刚换成一张新图"）生成。
//   所以本 TB 自建了 frame_sel_v：
//     * 复位后先翻转一次，模拟"上电第一张图到达"。这一次会被 first_done
//       抑制掉（页仍是 P1）—— 顺便把 first_done 置起来；
//     * press_key3 任务里再翻转一次，模拟"K3 按下后 SD 卡换了图"，
//       这时才会真正翻页。
//   若只按 K3 而不动 frame_sel_v，页是不会翻的（这是设计如此，不是 TB 的问题）。
// ============================================================================
module tb_hud_frame;

    localparam CLK_HZ_SIM  = 25000;     // 真实值 25000000
    localparam FADE_SIM    = 128;
    localparam BANNER_SIM  = 48;

    // ---- 640x480@60 时序参数（与 color_bar.v 的 VIDEO_640_480 一致）----
    localparam H_SYNC = 96, H_BP = 48, H_FP = 16, H_TOT = 800;
    localparam V_SYNC = 2,  V_BP = 33, V_FP = 10, V_ACT = 480, V_TOT = 525;

    reg video_clk = 1'b0;
    always #20 video_clk = ~video_clk;   // 25MHz 像素时钟

    reg rst_n = 1'b0;
    reg key3  = 1'b1;                    // 低有效
    reg [3:0] sw         = 4'b0011;      // SW1=HUD on, SW2=报警使能, SW4=关自动翻页
    reg [3:0] state_code = 4'd0;         // 报警时数码管右字段改显的诊断码

    // 【基础融合后】K3 短按不再直接翻页 —— 翻页由 frame_sel_v 的跳变
    // （"屏幕刚换成一张新图"）驱动。本 TB 自建这个信号：
    // press_key3 里翻转一次 = SD 卡换了一张图。
    reg frame_sel_v = 1'b0;

    // ---------------- 自建视频时序 ----------------
    reg [9:0] hc, vc;
    always @(posedge video_clk) begin
        if (hc == H_TOT - 1) begin
            hc <= 10'd0;
            vc <= (vc == V_TOT - 1) ? 10'd0 : (vc + 10'd1);
        end else begin
            hc <= hc + 10'd1;
        end
    end

    wire hs_i = ~((hc >= H_FP) && (hc < H_FP + H_SYNC));                  // 负极性
    wire vs_i = ~((vc >= V_FP) && (vc < V_FP + V_SYNC));
    wire de_i = (hc >= H_FP + H_SYNC + H_BP) &&
                (vc >= V_FP + V_SYNC + V_BP) &&
                (vc <  V_FP + V_SYNC + V_BP + V_ACT);

    // ---------------- 源图像（代替 SD 卡 BMP，一块斜向渐变）----------------
    reg [9:0] sx, sy;
    reg       de_i_d, vs_i_d;
    always @(posedge video_clk) begin
        de_i_d <= de_i;
        vs_i_d <= vs_i;
        if (!de_i)                sx <= 10'd0;
        else                      sx <= sx + 10'd1;
        if (vs_i != vs_i_d)       sy <= 10'd0;
        else if (de_i && !de_i_d) sy <= sy + 10'd1;
    end

    wire [23:0] src_pix = {sy[8:1], sx[8:1], 8'h38};

    wire        hs_d, vs_d, de_d;
    wire [23:0] vout;

    video_delay u_dly(
        .video_clk (video_clk),
        .rst       (~rst_n),
        .read_en   (),
        .read_data (src_pix),
        .hs        (hs_i),
        .vs        (vs_i),
        .de        (de_i),
        .hs_r      (hs_d),
        .vs_r      (vs_d),
        .de_r      (de_d),
        .vout_data (vout)
    );

    // ---------------- 被测 HUD ----------------
    wire        o_hs, o_vs, o_de;
    wire [23:0] o_rgb;
    // 【选题二扩展后新增】数码管和报警输出本 TB 不做断言，
    // 但必须接出来 —— 悬空会在部分仿真器里报 warning。
    wire [31:0] seg_dig;
    wire [7:0]  seg_dp;
    wire        seg_tog;
    wire        alarm_out;
    // 【基础融合】K3 短按 / SW4 6 秒节拍，两个"请求下一张图"的单拍脉冲
    wire        key3_short;
    wire        sw4_beat;

    hud_top #(
        .CLK_HZ      (CLK_HZ_SIM),
        .FADE_STEP   (FADE_SIM),
        .BANNER_STEP (BANNER_SIM)
    ) dut(
        .clk          (video_clk),
        .rst_n        (rst_n),
        .key3         (key3),
        .sw           (sw),
        .state_code   (state_code),
        .frame_sel_v  (frame_sel_v),   // 基础融合: 本 TB 自建的"换图"信号
        .hs           (hs_d),
        .vs           (vs_d),
        .de           (de_d),
        .vout_data    (vout),
        .o_hs         (o_hs),
        .o_vs         (o_vs),
        .o_de         (o_de),
        .o_rgb        (o_rgb),
        .o_seg_dig    (seg_dig),
        .o_seg_dp     (seg_dp),
        .o_seg_tog    (seg_tog),
        .o_alarm      (alarm_out),
        .o_key3_short (key3_short),    // 本 TB 不检查，接出来避免悬空告警
        .o_sw4_beat   (sw4_beat)       // 同上
    );

    // ---------------- 抓帧 ----------------
    reg [9:0] fx, fy;
    reg       o_de_d, o_vs_d;
    always @(posedge video_clk) begin
        o_de_d <= o_de;
        o_vs_d <= o_vs;
        if (!o_de)                fx <= 10'd0;
        else                      fx <= fx + 10'd1;
        if (o_vs != o_vs_d)       fy <= 10'd0;
        else if (o_de && !o_de_d) fy <= fy + 10'd1;
    end

    reg [23:0] fb [0:307199];

    reg            cap_req;
    reg            cap_armed;
    reg [8*64-1:0] cap_name;
    integer        i;
    integer        fcount = 0;

    // 抓帧 + 落盘必须放在同一个 always 里，否则 cap_armed 会有两个驱动源
    always @(posedge video_clk) begin
        if (o_vs != o_vs_d) begin
            fcount <= fcount + 1;
            if (cap_req) begin
                cap_armed <= 1'b1;
                cap_req   <= 1'b0;
            end else begin
                cap_armed <= 1'b0;
            end
        end else if (cap_armed && o_de) begin
            if ((fy == 10'd479) && (fx == 10'd639)) begin
                // 最后一个像素用阻塞写：$writememh 立刻读，非阻塞赋值此时还没生效
                fb[307199] = o_rgb;
                cap_armed <= 1'b0;
                $display("[%0t] dumping %0s", $time, cap_name);
                $writememh(cap_name, fb);
            end else if ((fx < 10'd640) && (fy < 10'd480)) begin
                fb[fy*640 + fx] <= o_rgb;
            end
        end
    end

    // ---------------- 激励 ----------------
    task wait_frames;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge o_vs);
            end
        end
    endtask

    task press_key3;
        begin
            key3 = 1'b0;
            repeat (4000) @(posedge video_clk);   // > 消抖 500 拍，< 长按 25000 拍
            key3 = 1'b1;
            repeat (4000) @(posedge video_clk);
            // 【基础融合】K3 按下之后，SD 卡会跟着换一张图 —— 现在翻页靠的是这个，
            // 不再靠 key3 本身。这里翻转 frame_sel_v 来模拟图换好了。
            frame_sel_v = ~frame_sel_v;
            repeat (4) @(posedge video_clk);
        end
    endtask

    task cap_next_frame;
        input [8*64-1:0] nm;
        begin
            cap_name = nm;
            cap_req  = 1'b1;
            @(posedge video_clk);
            wait (cap_armed == 1'b1);
            wait (cap_armed == 1'b0);          // 抓完自动清掉
            @(posedge video_clk);
        end
    endtask

    initial begin
        cap_req   = 1'b0;
        cap_armed = 1'b0;
        cap_name  = "out_hud_p0.hex";
        for (i = 0; i < 307200; i = i + 1) fb[i] = 24'd0;

        rst_n = 1'b0;
        repeat (20) @(posedge video_clk);
        rst_n = 1'b1;

        // ---- 0. 上电第一张图到达 ----
        // frame_sel_v 跳变一次，但被 hud_top 里的 first_done 抑制（页仍然是 P1）
        // —— 真机上就是"第一张图配 P1"，不是配 P2。
        // 这一步同时把 first_done 置起来，后面的 press_key3 才能真正翻页。
        frame_sel_v = 1'b1;
        repeat (4) @(posedge video_clk);

        // ---- 1. 正常运行画面：P1 RUN MODE ----
        wait_frames(1);
        cap_next_frame("out_hud_p0.hex");

        // ---- 2. 按 K3 切页，抓淡出进行到一半的那一帧（FADE_STEP=128，刚好 -128）----
        press_key3;
        cap_next_frame("out_hud_fade.hex");

        // ---- 3. 报警横幅（force 按住报警状态，纯为省仿真时间）----
        force dut.u_data.alarm_hold = 8'd255;
        wait_frames(1);
        cap_next_frame("out_hud_alarm.hex");
        release dut.u_data.alarm_hold;

        // ---- 4. 淡入完成后的 P2 ECO MODE ----
        wait_frames(2);
        cap_next_frame("out_hud_p1.hex");

        $display("=== ALL CAPTURES DONE ===");
        $finish;
    end

    initial begin
        #4000000000;
        $display("!!! TIMEOUT at %0t !!!", $time);
        $finish;
    end

endmodule
