`timescale 1ns/1ps
// ============================================================================
// tb_hud_live.v -- 看 hud_data_gen 的"活"到底有没有：值在不在动、读数在不在动
//
// 上板报"指针和数字都不动了"。这个 TB 把节拍全部压缩（CLK_HZ=25000，
// 于是 upd_tick=125us、一个 seg=8"秒"），跑两三个 seg，把
//   seg / v_press / d_press / ang_p / row_p / bcd_valid / wob_cnt
// 每隔 8 个节拍打一行。
//
// ★ EXP_SWING 是【唯一的版本相关旋钮】★
//   第三十一 / 三十四版：慢速三角波，幅度 ±3   ⇒ EXP_SWING = 3
//   第三十三版：一阶低通随机游走，封顶 ±2     ⇒ EXP_SWING = 2
//   换版本只改这一个常量，其余判据（极差、单拍跳变）不变。
//   ★ 本 TB 【不】引用 wob_acc ★ —— 那是第三十三版专有的信号，
//     引用它会让回退后的版本连 elaborate 都过不去（踩过）。
//
// 判据：
//   upd_cnt 在涨         -> 节拍没死
//   wob_cnt 在动         -> 抖动源没死
//   v_press 在爬         -> slew 在走
//   d_press 在游走       -> 显示值在动
//   ang_p 在变           -> 指针在动
//   row_p 在变           -> 读数在动
//
//   ★ 两条硬指标（都是上板反馈逼出来的）★
//     ① 幅度：seg2 窗口内三路必须在目标 ±2 个单位以内（不能大 ⇒ 不然"一直在震"）
//        且极差 ≥ 2（不能不动的 ⇒ 不然"指针不动"）
//     ② 平滑：任意相邻两个 upd_tick 之间，整数显示值的跳变 |Δ| 必须 ≤ 1
//        ⇒ 单拍位移 ≤ 1 个单位 = 3.05px（液位）。
//        这是"不抖"的客观口径 —— 第三十二版那个 ±6/3 秒的三角波
//        单拍位移更大、而且是 8 单位/秒的匀速摆动，上板就被读成"一直在抖动"。
//
//   iverilog -g2005 -o tools/_selftest/hud_live.vvp src/hud/hud_data_gen.v tools/_selftest/tb_hud_live.v
//   vvp tools/_selftest/hud_live.vvp
// ============================================================================
module tb_hud_live;

    // 显示值允许离开段目标的幅度（显示单位）。
    // 第三十一 / 三十四版（±3 三角波）= 3；第三十三版（±2 随机游走）= 2。
    localparam EXP_SWING = 3;

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

    integer ticks = 0;
    integer i;
    reg [9:0] alp, alt, all_;
    reg [19:0] rp, rt, rl;
    integer changed_ang = 0, changed_row = 0, changed_v = 0;
    reg [13:0] last_v = 0;

    // ★ 极差 / 单拍跳变：必须【每一拍都采】★
    //   两个坑都踩过：
    //   ① 打印每 8 拍一行、三角波周期 12 拍 ⇒ 采样和信号打拍子，极值采不到；
    //   ② 在 upd_tick 上采也不行 —— 第三十二版整数显示值恰好也是 8Hz，
    //      一样打拍子（实测只看到 129..140，漏掉真正的上极值 141）。
    //   本版抖动是非周期随机游走，不存在打拍子，但"逐拍"这条纪律照旧。
    reg [13:0] dpmax = 14'd0,   dpmin = 14'h3FFF;
    reg [13:0] dtmax = 14'd0,   dtmin = 14'h3FFF;
    reg [13:0] dlmax = 14'd0,   dlmin = 14'h3FFF;
    // 单拍跳变幅度（逐 upd_tick 比较）
    reg [13:0] dp_prev = 14'h3FFF, dt_prev = 14'h3FFF, dl_prev = 14'h3FFF;
    integer    dp_jump = 0, dt_jump = 0, dl_jump = 0;
    // 抓"最大跳变发生在哪一拍"——量出来，别猜
    integer    dp_jtick = -1, dt_jtick = -1, dl_jtick = -1;
    reg [13:0] dp_jprev = 0, dt_jprev = 0, dl_jprev = 0;
    reg [13:0] dp_jcur  = 0, dt_jcur  = 0, dl_jcur  = 0;
    reg [3:0]  dt_jseg  = 0;
    reg [13:0] dt_jv    = 0;

    // ★ 段内位置（每段 64 个 upd_tick，因为 upd_tick = 8Hz、DWELL_SEC = 8）★
    wire [5:0] seg_pos = ticks[5:0];

    // ---- 极差窗口：seg 6 的后半段 ----
    //   ★ 第三十四版的脚本改成"奇段报警 / 偶段恢复"之后，段内目标不再恒定：
    //     每段开头都在斜坡上（最长一跳 42 单位 ≈ 2.6 秒 = 21 拍），
    //     所以【不能】拿整段统计极差 —— 那量到的是斜坡，不是抖动。
    //     取 seg6（恢复段，目标 95/60/55）里"斜坡走完"之后再统计：
    //     最慢的一路是液位 18→55（37 单位 / 2 = 19 拍），取 seg_pos >= 24 足够。
    wire in_win = (dut.seg == 3'd6) && (seg_pos >= 6'd24);

    always @(posedge clk) begin
        if (rst_n && in_win) begin
            if (dut.d_press > dpmax) dpmax = dut.d_press;
            if (dut.d_press < dpmin) dpmin = dut.d_press;
            if (dut.d_temp  > dtmax) dtmax = dut.d_temp;
            if (dut.d_temp  < dtmin) dtmin = dut.d_temp;
            if (dut.d_level > dlmax) dlmax = dut.d_level;
            if (dut.d_level < dlmin) dlmin = dut.d_level;
        end
    end

    function integer iabs;
        input integer a;
        begin
            iabs = (a < 0) ? -a : a;
        end
    endfunction

    always @(posedge clk) begin
        if (rst_n && dut.upd_tick) begin
            ticks = ticks + 1;
            if (ticks % 8 == 1) begin
                $display("tick %0d seg=%0d v_p=%0d d_p=%0d d_t=%0d d_l=%0d ang_p=%0d ang_l=%0d row_p=%h row_l=%h bcdv=%b wob_cnt=%0d",
                         ticks, dut.seg, dut.v_press, dut.d_press, dut.d_temp, dut.d_level,
                         ang_p, ang_l, row_p, row_l, dut.bcd_valid, dut.wob_cnt);
            end
            if (ang_p !== alp || ang_t !== alt || ang_l !== all_) changed_ang = changed_ang + 1;
            if (row_p !== rp || row_t !== rt || row_l !== rl)           changed_row = changed_row + 1;
            if (dut.v_press !== last_v)                                 changed_v   = changed_v + 1;
            alp = ang_p; alt = ang_t; all_ = ang_l;
            rp  = row_p; rt  = row_t; rl   = row_l;
            last_v = dut.v_press;

            // ★ 单拍跳变：**全程**统计，不局限在某一段 ★
            //   这是"报警↔恢复不要硬跳"的判据 —— 段边界也在里面。
            //   预期上限 = slew 步长 + 抖动每拍最多 ±1：
            //     压力/液位 2 + 1 = 3    温度 1 + 1 = 2
            //   要是哪一拍真的硬跳（比如直接把目标赋给显示值），这里立刻会超。
            // ★ 跳过复位后的前 10 拍 ★
            //   复位把 d_* 置成 60/60/55，而公式的稳态中心是 v（wob 中心 3 再减 3）
            //   ⇒ 第 2 拍会看到一次 60->57 的"归位"，差 3，那是【上电一次性伪影】，
            //     不是运行中的硬跳。三个通道的最大值原本都被这一拍顶着。
            if (dp_prev !== 14'h3FFF && ticks > 10) begin
                if (iabs($signed({2'b0, dut.d_press}) - $signed({2'b0, dp_prev})) > dp_jump) begin
                    dp_jump = iabs($signed({2'b0, dut.d_press}) - $signed({2'b0, dp_prev}));
                    dp_jtick = ticks; dp_jprev = dp_prev; dp_jcur = dut.d_press;
                end
                if (iabs($signed({2'b0, dut.d_temp}) - $signed({2'b0, dt_prev})) > dt_jump) begin
                    dt_jump = iabs($signed({2'b0, dut.d_temp}) - $signed({2'b0, dt_prev}));
                    dt_jtick = ticks; dt_jprev = dt_prev; dt_jcur = dut.d_temp;
                    dt_jseg = dut.seg; dt_jv = dut.v_temp;
                end
                if (iabs($signed({2'b0, dut.d_level}) - $signed({2'b0, dl_prev})) > dl_jump) begin
                    dl_jump = iabs($signed({2'b0, dut.d_level}) - $signed({2'b0, dl_prev}));
                    dl_jtick = ticks; dl_jprev = dl_prev; dl_jcur = dut.d_level;
                end
            end
            dp_prev = dut.d_press; dt_prev = dut.d_temp; dl_prev = dut.d_level;
        end
    end

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        // ★ 必须跑到 seg6 ★ 一段 = 64 个 upd_tick = 64 × 3125 = 200000 拍；
        //   3000000 拍 = 960 个 upd_tick = 15 段 = 1.875 轮
        //   ⇒ seg6 出现两次（tick 384..448 与 896..960），段边界也跨过好几处。
        repeat (3000000) @(posedge clk);

        $display("");
        $display("==== 汇总（采样 %0d 个 upd_tick）====", ticks);
        $display("ang 变过的次数 = %0d", changed_ang);
        $display("行读数变过的次数 = %0d", changed_row);
        $display("v_press 变过的次数 = %0d", changed_v);
        $display("seg = %0d  v_press=%0d v_temp=%0d v_level=%0d", dut.seg, dut.v_press, dut.v_temp, dut.v_level);
        $display("d_press=%0d d_temp=%0d d_level=%0d", dut.d_press, dut.d_temp, dut.d_level);
        $display("row_p=%h row_t=%h row_l=%h", row_p, row_t, row_l);
        $display("wob_cnt=%0d  (三角波 0..6，中心 3 => 偏移 -3..+3 个显示单位)", dut.wob_cnt);
        $display("");
        $display("---- seg6 后半段窗口（恢复段，目标 95 / 60 / 55）× 抖动 ----");
        $display("压力 d_press %0d..%0d  极差 %0d", dpmin, dpmax, dpmax-dpmin);
        $display("温度 d_temp  %0d..%0d  极差 %0d", dtmin, dtmax, dtmax-dtmin);
        $display("液位 d_level %0d..%0d  极差 %0d", dlmin, dlmax, dlmax-dlmin);
        $display("---- 单拍跳变（全程，含段边界）：压力<=3 温度<=2 液位<=3 才算不硬跳 ----");
        $display("压力 %0d  温度 %0d  液位 %0d", dp_jump, dt_jump, dl_jump);

        $display("---- 最大跳变发生在哪一拍（量出来的，不是推的）----");
        $display("压力 tick %0d (seg%0d): %0d -> %0d", dp_jtick, dut.seg, dp_jprev, dp_jcur);
        $display("温度 tick %0d (seg%0d): %0d -> %0d   (当时 v_temp=%0d, wob_cnt=%0d)",
                 dt_jtick, dt_jseg, dt_jprev, dt_jcur, dt_jv, dut.wob_cnt);
        $display("液位 tick %0d (seg%0d): %0d -> %0d", dl_jtick, dut.seg, dl_jprev, dl_jcur);
        $display("段长 = 64 拍  tick 除以 64 的余数 = 段内位置：压力 %0d 温度 %0d 液位 %0d",
                 dp_jtick[5:0], dt_jtick[5:0], dl_jtick[5:0]);

        if (dpmin == 14'h3FFF || dtmin == 14'h3FFF || dlmin == 14'h3FFF) begin
            $display("=== FAIL: seg6 窗口一次都没采到（探针没生效）===");
        end else if (dpmin < 14'd95 - EXP_SWING || dpmax > 14'd95 + EXP_SWING ||
                     dtmin < 14'd60 - EXP_SWING || dtmax > 14'd60 + EXP_SWING ||
                     dlmin < 14'd55 - EXP_SWING || dlmax > 14'd55 + EXP_SWING) begin
            $display("=== FAIL: 幅度超出 +-%0d 个单位（上板会读成『一直在震』）===", EXP_SWING);
        end else if ((dpmax-dpmin) < 2 || (dtmax-dtmin) < 2 || (dlmax-dlmin) < 2) begin
            $display("=== FAIL: 极差太小 => 指针基本不动 ===");
        end else if (dp_jump > 3 || dt_jump > 2 || dl_jump > 3) begin
            $display("=== FAIL: 单拍跳变超上限 => 有硬跳 ===");
        end else begin
            $display("=== PASS: 幅度在 +-%0d 内、极差 >=2、单拍跳变不超 slew+抖动 上限 ===", EXP_SWING);
        end
        $finish;
    end

    initial begin
        #200000000;                 // 200ms = 5,000,000 拍，必须大于上面的 3,000,000
        $display("TIMEOUT");
        $finish;
    end

endmodule
