`timescale 1ns/1ps
// ============================================================================
// hud_data_gen.v -- 压力容器的"数据源 + 播放时序控制器"
//
// 这一模块没有任何像素逻辑，只负责产生会变化的东西：
//   * 三个监测量：罐内压力 / 罐体温度 / 液位（脚本化分段爬升，不是随机游走）
//   * 三个小表盘 + 一个大表盘的指针角度索引
//   * 显示界面号 disp_page（0..5）+ 淡入淡出系数 alpha
//   * 亮度档 bright（K3 短按循环 8 档）
//   * 报警判定 / 锁存 / SW2 确认 / 横幅上滑 banner_off
//   * 指示灯 lamp 与 2Hz 闪烁位 blink
//   * 三路趋势曲线采样 tr_p / tr_t / tr_l + 采样脉冲 trend_push
//
// ---------------------------------------------------------------------------
// 【三个监测量与量程】
//     压力  0..160   单位 0.01 MPa（即 0.00..1.60 MPa）  报警 > 120
//     温度  20..120  ℃                                   报警 > 95
//     液位  0..100   %                                   报警 < 20 或 > 85
//
//   三个阈值都带【回差】（见 ALARM 段的注释）：不然示数在阈值附近抖一下，
//   报警横幅就会疯狂地来回弹。
//
//   ★ 第三十三版：显示值 = 平滑值 + **一阶低通的随机游走**（±2 个单位封顶、
//     σ≈1.16、相关时间 4 秒、单拍位移 <1px）。目标是让指针像真实仪表那样
//     【小幅、平滑、不规则地漂】，既不是"到位就死"，也不是"一直在震" ——
//     详见下面「第三十三版」那一节。抖动的来龙去脉（白噪声 → 三角波 → 低通
//     随机游走，三代都上过板）都写在那一节里，改之前先读一遍。
//
// ---------------------------------------------------------------------------
// 【六个界面】disp_page[2:0]
//     0 三表总览（开机默认）   1 压力放大   2 温度放大
//     3 液位放大               4 待机巡检   5 储气罐故障巡检
//
//   轮播/手动只在 0..4 里转（rot_page）。【页 5 不在轮播里】，
//   它只能由"参数超限自动跳转"或 SW3 强制进入。
//     disp_page = 报警有效 ? 5 : rot_page
//
// ---------------------------------------------------------------------------
// 【按键】全部是 video_clk 域的单拍脉冲（hud_keys.press），已同步消抖
//     K1 -> 回总览页（rot_page=0）。★软复位，不重启 FPGA★
//     K2 -> 翻页 rot_page+1（在 0..4 内环绕）
//     K3 -> 亮度循环 8 档
//     K4 -> 轮播 <-> 手动 切换
//
//   ★ 为什么 K1 不再接 A2 的硬复位 ★
//     A2 一旦接 rst_n，按一下整个 FPGA 就重启：SD 卡要重新初始化、
//     音频 FIFO 清空、图片黑屏 —— 演示里"按一下回主页"变成"按一下黑屏 2 秒"。
//     现在 A2 只接 hud_keys，K1 变成纯界面动作，图/音频完全不中断。
//     代价：板子上再也没有任何硬复位按键，出问题只能断电重上电。
//
// ---------------------------------------------------------------------------
// 【拨动开关】已在外面同步消抖，这里直接用
//     SW1 -> 关闭报警声，但【不关掉报警界面】（buzzer + HDMI 报警音都被它门控）
//     SW2 -> 从报警界面回到正常界面。置位即压制自动跳转；三个量全回安全后
//            自动复位（重新武装），下次超限还能再跳。
//     SW3 -> 手动强制进入报警界面（电平，最高优先级）
//     SW4 -> 静音切换播报音频（在 top.v 里门控音频，不在这里）
//   ★ 优先级： SW3 > 自动报警 > rot_page ★
//
// ---------------------------------------------------------------------------
// 【脚本化爬升】seg 0..7，每段 dwell 8 秒，8 段 = 64 秒一轮：
//     seg 0  压力 60->95   温度 60      液位 55    全部正常
//     seg 1  压力 ->135    温度 60      液位 55    压力越 1.20 -> 报警
//     seg 2  压力 135      温度 60      液位 55    报警保持
//     seg 3  压力 ->70     温度 ->102   液位 55    压力恢复；温度越 95 -> 报警
//     seg 4  压力 70       温度 102     液位 55    温度报警保持
//     seg 5  压力 70       温度 ->62    液位 ->18  温度恢复；液位跌破 20 -> 报警
//     seg 6  压力 70       温度 62      液位 18    液位报警保持
//     seg 7  压力 ->60     温度 ->35    液位 ->88  液位超 85 -> 报警；段末回安全
//
//   步进（每 1/8 秒一次）：压力 2、温度 1、液位 2。
//   选这个组合是为了让每一段的行程都能在 8 秒内走完（最远的 135->70 需要
//   65/2/8 = 4.1 秒）；步骤再小就有段落走不到位，报警永远等不来。
//
// 【页 4 待机巡检是特例】进入该页时三个量的目标被强制钉在安全待机值
//   （压力 30 / 温度 25 / 液位 55），离开后自动回到当前 seg 的目标。
//   所以"参数回到安全值、状态灯全绿"是页面的天然属性，不靠额外逻辑。
//   ★ 副作用要提前知道 ★ 在待机页上待久了，爬升会被拉回安全区，
//     离开待机页后要重新爬。演示时想一口气看到报警就别停在待机页。
//
// 时钟：video_clk (25MHz)。所有输出在整帧内稳定，像素流水线直接使用。
// ============================================================================
module hud_data_gen #(
    parameter CLK_HZ    = 25000000,
    // 每帧 淡入/淡出 的 alpha 步进。12 步/帧 -> 约 21 帧 ≈ 0.35s @60Hz。
    parameter FADE_STEP = 12,
    // 去报警界面时用的快进版步进：报警要"立刻"看到，不能等 0.7 秒淡入淡出。
    parameter ALARM_STEP= 64,
    // 报警横幅每帧上滑的像素数。4 像素/帧 -> 48/4 = 12 帧 ≈ 0.2s。
    parameter BANNER_STEP = 4,
    // 轮播间隔（秒）
    parameter CAROUSEL_SEC = 5,
    // 爬升每段驻留（秒）
    parameter DWELL_SEC = 8
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,            // video_delay 的 vs_r，用于取帧节拍
    // ---- 四个按键，各是一个 video_clk 域的单拍脉冲 ----
    input  wire        key1_press,    // 回总览页
    input  wire        key2_press,    // 翻页
    input  wire        key3_press,    // 调亮度
    input  wire        key4_press,    // 轮播/手动 切换
    input  wire [3:0]  sw,            // 拨动开关 SW1-4（已同步消抖）
    // ---- 输出 ----
    output reg  [2:0]  disp_page,     // 0..5 当前显示界面
    output reg  [2:0]  rot_page,      // 0..4 轮播/手动选择位（不含报警页）
    output reg         carousel_en,   // 1 = 轮播，0 = 手动（开机默认手动）
    output reg  [7:0]  alpha,         // 0..255 界面淡入淡出
    output reg  [7:0]  bright,        // 0..255 亮度系数
    // ---- 指针角度索引 (0..1023，0=12 点，顺时针) ----
    output reg  [9:0]  ang_p,         // 小表·压力
    output reg  [9:0]  ang_t,         // 小表·温度
    output reg  [9:0]  ang_l,         // 小表·液位
    output reg  [9:0]  ang_big,       // 大表（按页选量）
    // ---- 三行读数，每行 5 个 nibble，[19:16] 是第 1 个字符 ----
    output reg  [19:0] row_p,         // "1.60 "
    output reg  [19:0] row_t,         // " 120 "
    output reg  [19:0] row_l,         // "  55 "
    output reg  [2:0]  lamp,          // {通讯, 报警, 运行}
    output reg         alarm_on,      // 报警有效（界面 + 横幅 + 蜂鸣器都看它）
    output reg         blink,         // 2Hz 方波
    output reg  [5:0]  banner_off,    // 报警横幅上滑偏移：48=完全隐藏，0=完全弹出
    // ---- 三个量的报警标志（未锁存，给数码管做上板诊断）----
    output wire        fl_p, fl_t, fl_l,
    // ---- 给 hud_trend 的采样（三路 + 一个公共节拍）----
    output wire [7:0]  tr_p,
    output wire [7:0]  tr_t,
    output wire [7:0]  tr_l,
    output wire        trend_push,    // 单拍脉冲，8Hz
    // ---- 给 hud_seg_data 的握手节拍 ----
    output wire        frame_tick_o,
    // ---- 【页图解耦】disp_page 变化的单拍脉冲 + 当前的图序号 ----
    // hud_top 用 toggle+3FF 把它同步到 sd_card_clk 域，令 bmp_read 去读第 N 张。
    // ★ 这是【唯一的】取图触发源 ★ 不再有 img_changed 那条"图读完才翻页"的回路。
    output reg         o_page_chg,
    output wire [2:0]  o_img_index
);

    // ---- 更新节拍：8Hz ----
    localparam UPD_DIV = CLK_HZ / 8;
    reg [21:0] upd_cnt;
    wire       upd_tick = (upd_cnt == UPD_DIV[21:0] - 22'd1);

    // ---- 帧节拍 ----
    // 用 vs 的【下降沿】而不是"任意跳变"：vs 每帧只会产生 1 个下降沿
    // （负极性时是同步头开始，正极性时是同步头结束），与极性无关，每帧恰好一次。
    // 若用 vs != vs_d，每帧会出现 2 次，淡入淡出/横幅滑动会快一倍。
    reg vs_d;
    wire frame_tick = (~vs) & vs_d;
    assign frame_tick_o = frame_tick;

    // ---- 闪烁：2Hz ----
    localparam BLINK_DIV = CLK_HZ / 4;     // 半个周期 0.25s
    reg [22:0] blink_cnt;
    reg        blink_slow;                 // 1Hz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            upd_cnt   <= 22'd0;
            vs_d      <= 1'b0;
            blink_cnt <= 23'd0;
            blink     <= 1'b0;
            blink_slow<= 1'b0;
        end else begin
            vs_d <= vs;

            if (upd_tick) upd_cnt <= 22'd0;
            else          upd_cnt <= upd_cnt + 22'd1;

            if (blink_cnt >= BLINK_DIV[22:0] - 23'd1) begin
                blink_cnt  <= 23'd0;
                blink      <= ~blink;
                blink_slow <= blink;           // 慢一半 -> 1Hz
            end else begin
                blink_cnt <= blink_cnt + 23'd1;
            end
        end
    end

    // ==================================================================
    // 脚本化爬升：seg 0..7，每段 DWELL_SEC 秒
    // ==================================================================
    localparam SEG_DIV = CLK_HZ * DWELL_SEC;
    reg [27:0] seg_cnt;
    reg [3:0]  seg;
    wire       seg_tick = (seg_cnt == SEG_DIV[27:0] - 28'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_cnt <= 28'd0;
            seg     <= 4'd0;
        end else if (seg_tick) begin
            seg_cnt <= 28'd0;
            seg     <= (seg == 4'd7) ? 4'd0 : (seg + 4'd1);
        end else begin
            seg_cnt <= seg_cnt + 28'd1;
        end
    end

    // 每段的三个目标值（组合查表，综合成 LUT）
    reg [13:0] seg_tp, seg_tt, seg_tl;
    always @(*) begin
        case (seg)
        4'd0:    begin seg_tp = 14'd95;  seg_tt = 14'd60;  seg_tl = 14'd55; end
        4'd1:    begin seg_tp = 14'd135; seg_tt = 14'd60;  seg_tl = 14'd55; end
        4'd2:    begin seg_tp = 14'd135; seg_tt = 14'd60;  seg_tl = 14'd55; end
        4'd3:    begin seg_tp = 14'd70;  seg_tt = 14'd102; seg_tl = 14'd55; end
        4'd4:    begin seg_tp = 14'd70;  seg_tt = 14'd102; seg_tl = 14'd55; end
        4'd5:    begin seg_tp = 14'd70;  seg_tt = 14'd62;  seg_tl = 14'd18; end
        4'd6:    begin seg_tp = 14'd70;  seg_tt = 14'd62;  seg_tl = 14'd18; end
        default: begin seg_tp = 14'd60;  seg_tt = 14'd35;  seg_tl = 14'd88; end
        endcase
    end

    // ==================================================================
    // ★★★ 第三十三版：三角波 → 【低通随机游走】（小、慢、平滑、不规则）★★★
    // ==================================================================
    // 上板反馈（v32，±6、3 秒周期、32Hz 的三角波）：
    //     「指针一直在抖动，而且指针特别生硬不真实」
    //   两条都成立，而且原因是分开的：
    //
    //   【一】"一直在抖动" = 幅度太大 + 永远不停。
    //         ±6 单位 ⇒ 液位针尖 **±18px** 的来回摆；而且它是【周期】的，
    //         一秒不停地摆，观感就是一台在震的机器。
    //         真实仪表静下来的时候针是稳的，动也是小幅、不规则的。
    //
    //   【二】"特别生硬" = 波形本身。三角波是【匀速走到底再瞬间掉头】，
    //         拐点处速度突变 ⇒ 机械、发条味。真实的过程是慢慢减速再加速。
    //
    // 【做法】白噪声过一级低通（泄漏积分器）：
    //        wob ← wob − (wob >>> 5) + noise          （α = 1/32）
    //   * 泄漏项就是"朝 0 拉的弹簧"，系数 1/32 ⇒ 相关时间 = 32 拍
    //   * 拍子用 upd_tick（8Hz）⇒ 相关时间 **4 秒**（缓，不是抖）
    //   * 噪声每拍 ±1/64 个显示单位 ⇒ 单拍位移 ≈ 0.28 单位 ≈ **0.87px**（液位）
    //     ⇒ 单拍位移小于 1 像素，眼睛看到的是【缓慢漂移】而不是【抖】
    //   * 非周期、不规则 ⇒ 不会像节拍器（这正是"生硬"的解药）
    //
    // 【幅度】±2.0 个显示单位封顶（液位针尖 ±6px、压力 ±3.8px），
    //   稳态 σ ≈ 1.16 单位 ⇒ 绝大多数时间在 ±1.5 单位以内。
    //   HMI 上这叫"活的过程上的读数"，不叫"抖动"。
    //   ★ 封顶用【软限幅】（见下面 wob_ovr/wob_sat），不是硬钳位 ★
    //     硬钳位实测有 12.5% 的时间平顶停在 ±2.00 —— 那本身就是"生硬"。
    //
    // 【★ 分辨率为什么必须是 1/64 单位 ★】
    //   泄漏项 = 偏差/32。若只用 1/4 单位表示，偏差最大才 8，8>>5 = 0
    //   ⇒ 泄漏恒为 0，那就不是低通而是纯随机游走，会一路飘到限幅、贴着限幅走。
    //   所以累加器比"指针用的分辨率"细 16 倍；指针仍旧只吃 1/4 单位那一段
    //   （wob_q），单拍步进 0.87px 已经足够滑。
    //
    // 【★ 报警不受影响 ★】抖动只加在显示值 d_* 上；报警判的是平滑值 v_*。
    //   （这条解耦是第三十二版做的，本版继续沿用 ⇒ 抖动幅度怎么调都不碰报警。）
    // ==================================================================
    localparam signed [8:0] WOB_LIM = 9'sd128;   // ±128/64 = ±2.0 个显示单位
    reg  signed [8:0] wob_acc;                   // 抖动，单位 1/64 个显示单位
    reg        [31:0] wob_lfsr;                  // 白噪声源（32 位最大长度 LFSR）

    wire signed [8:0] wob_pull  = wob_acc >>> 5;            // /32 的弹簧力
    wire        [5:0] wob_rnd   = wob_lfsr[5:0];            // 0..63
    wire signed [8:0] wob_noise = $signed({3'b0, wob_rnd}) - 9'sd32;  // −32..+31
    wire signed [9:0] wob_nxt   = wob_acc - wob_pull + wob_noise;

    // ★★ 软限幅，不是硬钳位 ★★
    //   硬钳位（超过就按到 ±WOB_LIM）会留下【平顶】的游走 —— 实测 12.5% 的
    //   时间顶在限幅上不动，那正是用户说的"生硬"（数值恰好停在 ±2.00 并保持）。
    //   改成：越界部分每拍砍掉一半（相当于一个随越界量变大的回推力），
    //   游走会在 ±WOB_LIM 附近【圆滑地掉头】，不会平顶。
    //   峰值约 ±2.3 单位，而指针只吃 1/4 单位那一段，显示上仍旧封在 ±2。
    wire signed [9:0] wob_ovr = (wob_nxt >  WOB_LIM) ? (wob_nxt - 10'sd128) :
                                (wob_nxt < -WOB_LIM) ? (wob_nxt + 10'sd128) : 10'sd0;
    wire signed [9:0] wob_sat = wob_nxt - (wob_ovr >>> 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wob_acc  <= 9'sd0;
            wob_lfsr <= 32'h5A3C91E7;
        end else if (upd_tick) begin
            // x^32 + x^22 + x^2 + x + 1（最大长度）
            wob_lfsr <= {wob_lfsr[30:0],
                         wob_lfsr[31]^wob_lfsr[21]^wob_lfsr[1]^wob_lfsr[0]};
            // 软限幅后仍要砍到 9 位（回推只砍一半 ⇒ 峰值 ≈ ±146，仍在 9 位内）
            wob_acc  <= wob_sat[8:0];
        end
    end

    // 指针用的 1/4 单位偏移：−8..+8（= ±2 个显示单位），再偏成 0..16 的无符号
    wire signed [4:0] wob_q = wob_acc >>> 4;        // 带符号，−8..+8
    wire        [4:0] wob_u = wob_q[4:0] + 5'd8;    // 偏移二进制，0..16

    // ---- 每 1/8 秒朝目标滑动一小步 ----
    function [13:0] slew;
        input [13:0] cur;
        input [13:0] tgt;
        input [3:0]  step;
        begin
            if      (tgt > cur) slew = ((tgt - cur) > step) ? (cur + step) : tgt;
            else if (tgt < cur) slew = ((cur - tgt) > step) ? (cur - step) : tgt;
            else                slew = cur;
        end
    endfunction

    // ---- 待机页（页 4）把目标钉在安全待机值 ----
    wire        standby   = (disp_page == 3'd4);
    wire [13:0] tgt_p_now = standby ? 14'd30 : seg_tp;
    wire [13:0] tgt_t_now = standby ? 14'd25 : seg_tt;
    wire [13:0] tgt_l_now = standby ? 14'd55 : seg_tl;

    reg [13:0] v_press, v_temp, v_level;    // 平滑值
    reg [13:0] d_press, d_temp, d_level;    // 显示值（含抖动）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_press <= 14'd60;
            v_temp  <= 14'd60;
            v_level <= 14'd55;
        end else if (upd_tick) begin
            v_press <= slew(v_press, tgt_p_now, 4'd2);
            v_temp  <= slew(v_temp,  tgt_t_now, 4'd1);
            v_level <= slew(v_level, tgt_l_now, 4'd2);
        end
    end

    // ==================================================================
    // 显示值 = 平滑值 + 抖动（抖动源见上面「第三十三版」一节）
    //
    //   全部在【1/4 单位】域里算，避免有符号运算（本工程在有符号/位宽上栽过
    //   三次，见 tools/chk_width.py）：
    //     4×v + wob_u，wob_u ∈ 0..16（中心 8）⇒ 偏移 −8..+8 = **−2..+2 个显示单位**
    //   一次钳位后分成两份：
    //     整数显示值 d_*（读数 / 报警 / 趋势用） = 钳后/4 − 2
    //     1/4 单位显示值 q_*（指针角度用）       = 钳后 − 8
    //
    //   ★ 指针吃 q_*（细），数字/趋势吃 d_*（整）★
    //     指针才是【滑】的，不是每 1 单位蹦一格（1 单位 = 3.05px，台阶一眼可见）。
    //     数字跟着同一个值取整 ⇒ 读数 = 指针的四舍五入，不会"对不上"。
    //
    //   ★ 两头上限都显式钳 ★
    //     下钳 8（= 0 单位 + 抖动下限）—— 不钳的话，温度量程从 20 起、液位
    //     目标最低 18，抖动把值压到 0 以下就会回绕成巨大值 ⇒ 指针瞬间甩到
    //     满量程（第三十版同款坑）。上钳 = 4×量程 + 8。
    // ==================================================================
    wire [15:0] wp4 = {v_press, 2'b00} + {11'b0, wob_u};
    wire [15:0] wt4 = {v_temp , 2'b00} + {11'b0, wob_u};
    wire [15:0] wl4 = {v_level, 2'b00} + {11'b0, wob_u};

    wire [15:0] wpq = (wp4 < 16'd8) ? 16'd8 : (wp4 > 16'd648) ? 16'd648 : wp4;  // 4×160+8
    wire [15:0] wtq = (wt4 < 16'd8) ? 16'd8 : (wt4 > 16'd488) ? 16'd488 : wt4;  // 4×120+8
    wire [15:0] wlq = (wl4 < 16'd8) ? 16'd8 : (wl4 > 16'd408) ? 16'd408 : wl4;  // 4×100+8

    // 整数显示值（读数 / 趋势）
    wire [13:0] dn_press = wpq[15:2] - 14'd2;
    wire [13:0] dn_temp  = wtq[15:2] - 14'd2;
    wire [13:0] dn_level = wlq[15:2] - 14'd2;

    // 1/4 单位显示值（指针角度 —— 让针【滑】而不是【跳】）
    wire [14:0] q_press = wpq[14:0] - 15'd8;
    wire [14:0] q_temp  = wtq[14:0] - 15'd8;
    wire [14:0] q_level = wlq[14:0] - 15'd8;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_press <= 14'd60;
            d_temp  <= 14'd60;
            d_level <= 14'd55;
        end else if (upd_tick) begin
            // ★ 就按 upd_tick(8Hz) 采，不会有打拍子问题 ★
            //   抖动本身就是在 upd_tick 上更新的【非周期随机游走】，
            //   采样率和它 1:1 ⇒ 每一次跳变都被采到。
            //   （第三十二版的抖动是 32Hz 的整格三角波，整数显示值恰好 8Hz，
            //     那时才必须小心采样率；本版不存在这个问题。）
            d_press <= dn_press;
            d_temp  <= dn_temp;
            d_level <= dn_level;
        end
    end

    // ==================================================================
    // 报警判定（带回差）
    //
    // ★★ 第三十二版：判的是【平滑值 v_*】，不再是显示值 d_* ★★
    //   这是本版把抖动从 ±3 放大到 ±6 的【前提】。v31 判的是 d_*，而抖动
    //   幅度 W 会让"置位带"和"复位带"各自往中间扩 W ⇒ 想不来回翻就必须
    //   W ≤ 回差/2（压力回差 6 ⇒ W ≤ 3），幅度被卡死，针尖只走 ±9px，
    //   上板就被读成"指针不动"。
    //   现在报警看真值、抖动只加在显示上 ⇒ 抖动再大也碰不到报警。
    //   这也是 HMI 的常规做法：报警看过程真值，显示可以有自己的动态。
    //   四条回差保持原来的 6 / 4 / 4 / 3 不变。
    //
    //   ★ 副作用（要知道，不是 bug）★
    //     爬升穿过门限的那零点几秒里，读数因为带 ±6 抖动，可能显示在门限的
    //     另一侧（例：刚报警时读数还显示 1.14）。报警本身是对的。
    //
    //   ★ 仍然必须带回差 ★
    //     v_* 本身是干净的斜坡，但停住时 v_* 恒定；回差是为了让"刚好停在
    //     门限附近"的段目标不会让报警反复起落。四条门限的段目标都远离门限。
    // ==================================================================
    reg fl_p_r, fl_t_r, fl_l_lo_r, fl_l_hi_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fl_p_r    <= 1'b0;
            fl_t_r    <= 1'b0;
            fl_l_lo_r <= 1'b0;
            fl_l_hi_r <= 1'b0;
        end else if (upd_tick) begin
            // 压力 > 120 置位，< 114 复位
            if      (v_press > 14'd120) fl_p_r <= 1'b1;
            else if (v_press < 14'd114) fl_p_r <= 1'b0;
            // 温度 > 95 置位，< 91 复位
            if      (v_temp  > 14'd95 ) fl_t_r <= 1'b1;
            else if (v_temp  < 14'd91 ) fl_t_r <= 1'b0;
            // 液位 < 20 置位，> 24 复位
            if      (v_level < 14'd20 ) fl_l_lo_r <= 1'b1;
            else if (v_level > 14'd24 ) fl_l_lo_r <= 1'b0;
            // 液位 > 85 置位，< 82 复位
            if      (v_level > 14'd85 ) fl_l_hi_r <= 1'b1;
            else if (v_level < 14'd82 ) fl_l_hi_r <= 1'b0;
        end
    end

    assign fl_p = fl_p_r;
    assign fl_t = fl_t_r;
    assign fl_l = fl_l_lo_r | fl_l_hi_r;

    wire alarm_any = fl_p_r | fl_t_r | fl_l_lo_r | fl_l_hi_r;

    // ---- SW2：确认报警，压制自动跳转；全回安全后自动重新武装 ----
    //   ★ 清条件用 alarm_any 而不是 SW2 的电平 ★
    //     拨上去之后即使再拨回来，也要等参数真的回到安全区才解除压制，
    //     否则"拨一下就永远看不到报警页"变成"手一松就又跳过去"。
    reg alarm_ack;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          alarm_ack <= 1'b0;
        else if (!alarm_any) alarm_ack <= 1'b0;   // 重新武装
        else if (sw[1])      alarm_ack <= 1'b1;   // SW2 置位 -> 确认
    end

    // ---- 报警界面是否有效：SW3 强制 或 未确认的超限 ----
    wire force_alarm  = sw[2];                       // SW3
    wire auto_alarm   = alarm_any & ~alarm_ack;
    wire alarm_active = force_alarm | auto_alarm;

    // ==================================================================
    // 界面选择
    //   ★ disp_page 由下面的淡入淡出状态机在 alpha 掉到 0 的那一拍更新 ★
    //     （见 F_OUT 分支）。这里只给出"应该去哪一页"。
    // ==================================================================
    wire [2:0] dst_page = alarm_active ? 3'd5 : rot_page;

    assign o_img_index = disp_page;

    // disp_page 变化 -> 单拍脉冲，交给 hud_top 跨域去取第 N 张图
    reg [2:0] disp_page_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            disp_page_d <= 3'd0;
            o_page_chg  <= 1'b0;
        end else begin
            disp_page_d <= disp_page;
            o_page_chg  <= (disp_page != disp_page_d);
        end
    end

    // ==================================================================
    // 按键：轮播开关 / 翻页 / 回总览
    // ==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      carousel_en <= 1'b0;      // ★ 开机默认手动 ★
        else if (key4_press) carousel_en <= ~carousel_en;
    end

    // 轮播计时：只在轮播模式下跑；任何手动干预都清零，避免"刚按完 K2
    // 立刻又被自动翻一次"的重锁。CAROUSEL_SEC*CLK_HZ 需要 27 位
    // （5*25e6 = 1.25e8 < 2^27）。
    localparam CAR_DIV = CLK_HZ * CAROUSEL_SEC;
    reg [26:0] car_cnt;
    wire       car_tick = (car_cnt == CAR_DIV[26:0] - 27'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                          car_cnt <= 27'd0;
        else if (car_tick || !carousel_en || key2_press || key1_press)
                                                             car_cnt <= 27'd0;
        else                                                 car_cnt <= car_cnt + 27'd1;
    end

    wire rot_adv = key2_press | (carousel_en & car_tick);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       rot_page <= 3'd0;
        else if (key1_press)              rot_page <= 3'd0;   // K1 回总览
        else if (rot_adv)                 rot_page <= (rot_page >= 3'd4) ? 3'd0
                                                                        : (rot_page + 3'd1);
    end

    // ==================================================================
    // 界面淡入淡出
    //   IDLE -> 目标页变了 -> FADE_OUT(alpha 255->0) -> 换页 -> FADE_IN(0->255)
    //   ★ 目的页是报警页时用 ALARM_STEP，快进快出 ★
    //     报警要"立刻"看到；普通的 0.35s+0.35s 对报警来说太慢。
    // ==================================================================
    localparam F_IDLE = 2'd0, F_OUT = 2'd1, F_IN = 2'd2;
    reg [1:0] fstate;
    reg [2:0] dst_latch;       // 本次过渡的目的页

    // 目的页是报警页时用快进版步进
    wire [7:0] fstep = (dst_latch == 3'd5) ? ALARM_STEP[7:0] : FADE_STEP[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate    <= F_IDLE;
            alpha     <= 8'd255;
            disp_page <= 3'd0;
            dst_latch <= 3'd0;
        end else if (frame_tick) begin
            case (fstate)
                F_IDLE: begin
                    alpha <= 8'd255;
                    if (dst_page != disp_page) begin
                        dst_latch <= dst_page;
                        fstate    <= F_OUT;
                    end
                end
                F_OUT: begin
                    if (alpha <= fstep) begin
                        // ★ alpha 掉到 0 的这一拍才真正换页 ★
                        //   这正是"淡出-换页-淡入"的中间点，内容换了也看不见。
                        alpha     <= 8'd0;
                        disp_page <= dst_latch;
                        fstate    <= F_IN;
                    end else begin
                        alpha <= alpha - fstep;
                    end
                end
                F_IN: begin
                    if (dst_page != dst_latch) begin
                        // 淡入途中目标又变了（比如报警来了）：记下新目标，掉头再淡出
                        dst_latch <= dst_page;
                        fstate    <= F_OUT;
                    end else if (alpha >= (8'd255 - fstep)) begin
                        alpha  <= 8'd255;
                        fstate <= F_IDLE;
                    end else begin
                        alpha <= alpha + fstep;
                    end
                end
                default: fstate <= F_IDLE;
            endcase
        end
    end

    // ==================================================================
    // 亮度：K3 短按循环 8 档  (255,223,191,159,127,95,63,31)
    //   ★ 原来是挂在"长按"上的 ★ 现在 K3 只有短按一个动作，长按没有功能；
    //     hud_keys 的 long_press 输出不再接进来。
    // ==================================================================
    reg [2:0] blevel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          blevel <= 3'd0;
        else if (key3_press) blevel <= blevel + 3'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bright <= 8'd255;
        else        bright <= 8'd255 - {blevel, 5'b00000};
    end

    // ==================================================================
    // 指针角度
    //   量程线性映射到 250° 扫角：B = 1024 对应 360°，
    //   起点 -125° 对应索引 668，扫角 711（= round(250*1024/360)）。
    //   即 角度 = (668 + 归一化*711) & 1023
    //
    //   全部用"乘常数再右移"实现 —— 常数乘法在综合时展开成移位相加，
    //   一个 DSP 都不吃（这个器件总共只有 29 个 DSP）。
    //   ★ 常数一定写成 32 位 ★ Verilog 里 a*b 的位宽取两个操作数位宽的
    //     最大值，写成 14'd1 之类会让高位被截掉。
    // ==================================================================
    localparam [9:0]  ANG_BASE = 10'd668;

    // ★ 角度吃 q_*（1/4 单位），不吃 d_* ★
    //   q_* 已经是"显示值 ×4"，所以右移要从 10 改成 12（多除以 4），
    //   这样满量程仍然是 711 —— 刻度和底图一点没动。
    //   压力 0..160 -> 711/160 = 4.4438 -> *4550>>12
    wire [23:0] off_p = (q_press * 32'd4550) >> 12;
    // 温度 20..120 -> 711/100 = 7.11 -> *7280>>12
    //   ★ 必须钳 80（= 20 × 4）★ 抖动 ±6 会把温度压到 19℃，减 80 就下溢成
    //     巨大值、指针瞬间甩到满量程（第三十版同款坑，这里是同一个数换了个域）。
    wire [14:0] q_t2  = (q_temp < 15'd80) ? 15'd80 : q_temp;
    wire [23:0] off_t = ((q_t2 - 15'd80) * 32'd7280) >> 12;
    // 液位 0..100 -> 711/100 = 7.11 -> *7281>>12（7281 比 7280 更贴近 711.0）
    wire [23:0] off_l = (q_level * 32'd7281) >> 12;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ang_p <= ANG_BASE;
            ang_t <= ANG_BASE;
            ang_l <= ANG_BASE;
        end else begin
            ang_p <= (ANG_BASE + off_p[9:0]) & 10'h3FF;
            ang_t <= (ANG_BASE + off_t[9:0]) & 10'h3FF;
            ang_l <= (ANG_BASE + off_l[9:0]) & 10'h3FF;
        end
    end

    // 大表盘：按当前页选量。
    //   页 1 压力 / 页 2 温度 / 页 3 液位
    //   ★ 页 5（报警页）跟【报警的那一路】走，不再永远是压力 ★
    //     上板反馈「进入警报界面，指针也不一定在红色部分」。原因就是这里：
    //     页 5 恒选 ang_p，可报警页是【任何一路】超限都会进 —— 温度/液位超限
    //     时大表还在指压力（70 上下、离红区十万八千里），当然不在红区。
    //     现在按 fl_p > fl_t > fl_l 的优先级选报警那一路，指针才指在故障上。
    wire [1:0] alarm_q = fl_p_r ? 2'd0 : fl_t_r ? 2'd1 : (fl_l_lo_r | fl_l_hi_r) ? 2'd2 : 2'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ang_big <= ANG_BASE;
        else        ang_big <= (disp_page == 3'd2) ? ang_t :
                               (disp_page == 3'd3) ? ang_l :
                               (disp_page == 3'd5) ? ((alarm_q == 2'd1) ? ang_t :
                                                      (alarm_q == 2'd2) ? ang_l : ang_p)
                                                   : ang_p;
    end

    // ==================================================================
    // 三路趋势曲线采样：映射成 0..115 的显示高度
    //   压力 0..160 -> *736 >>10  (736/1024 = 0.71875 = 115/160)
    //   温度 20..120、液位 0..100 -> *1178>>10 (1178/1024 = 1.15039 ≈ 115/100)
    //   最后统一限幅到 115，保证喂给 hud_trend 的值一定在框内。
    // ==================================================================
    // ★ 温度量程从 20 起，而抖动 ±6 会把待机页的 25℃ 压到 19℃ ★
    //   直接 (d_temp - 20) 会下溢成巨大值，趋势曲线瞬间顶到满高。先钳 20。
    wire [13:0] d_temp_t = (d_temp < 14'd20) ? 14'd20 : d_temp;

    wire [23:0] t_p_raw = (d_press * 32'd736) >> 10;
    wire [23:0] t_t_raw = ((d_temp_t - 14'd20) * 32'd1178) >> 10;
    wire [23:0] t_l_raw = (d_level * 32'd1178) >> 10;

    assign tr_p = (t_p_raw > 24'd115) ? 8'd115 : t_p_raw[7:0];
    assign tr_t = (t_t_raw > 24'd115) ? 8'd115 : t_t_raw[7:0];
    assign tr_l = (t_l_raw > 24'd115) ? 8'd115 : t_l_raw[7:0];

    // 三路共用一个采样节拍（8Hz）。hud_trend 的 en 只门控输出、不门控采样，
    // 所以从总览页切到放大页时曲线是满的，不是从 0 重新长出来。
    assign trend_push = upd_tick;

    // ==================================================================
    // 二进制 -> BCD：串行"双 dabble"（移位-加3）
    //
    // 为什么不用 t/1000、t%100：综合器会把常数除法变成"乘一个魔数再移位"，
    // 每个都要吃掉 1 个 DSP。双 dabble 只用比较、加法、移位，一个都不要。
    // 三路各 14 拍，顺序跑约 45 拍；数据 8Hz 才变一次，时间上毫无压力。
    // ==================================================================
    function [29:0] dd_step;
        input [29:0] s;                 // s[13:0]=二进制, s[29:14]=4 位 BCD
        reg [29:0] t;
        begin
            t = s;
            if (t[17:14] >= 4'd5) t[17:14] = t[17:14] + 4'd3;
            if (t[21:18] >= 4'd5) t[21:18] = t[21:18] + 4'd3;
            if (t[25:22] >= 4'd5) t[25:22] = t[25:22] + 4'd3;
            if (t[29:26] >= 4'd5) t[29:26] = t[29:26] + 4'd3;
            dd_step = t << 1;
        end
    endfunction

    reg [3:0]  dd_sel;
    reg [3:0]  dd_it;
    reg [29:0] dd_s;
    reg [15:0] bcd_res [0:2];
    reg        bcd_valid;          // 第一轮转换完成前，读数保持复位初值

    // 3 路待转换：0 压力 / 1 温度 / 2 液位
    // ★ 这根 wire 必须放在 dd_sel 的 reg 声明【之后】★
    //   Verilog-2001 里用了还没声明的标识符会【隐式建一根 1bit wire】。
    //   原来这里写在 reg 前面，TD 报 HDL-5373，等于把 4bit 的 dd_sel 当成
    //   1bit 使 —— 三路选择会退化成只看最低位，读数就会串路。
    //
    // ★★★ 第三十版修正：选源必须看【下一个】下标，不是当前下标 ★★★
    //   写下面那句 `dd_s <= dd_src_nxt` 的同一拍，`dd_sel` 正要 +1，
    //   而 dd_src_nxt 是【组合】的、看的还是【当前】的 dd_sel
    //   ⇒ 每一路都装进了"上一路"的源，三行读数整体错位一格：
    //         bcd_res[0] = 液位   bcd_res[1] = 压力   bcd_res[2] = 温度
    //   屏幕上的后果：压力栏的数字其实是液位、温度栏是压力、液位栏是温度
    //   —— 数字和它旁边那块表盘指的【不是同一个量】。
    //   （上板前的自检：tools/_selftest/tb_bcd_rot.v，改之前 3 处 mismatch。）
    //   改法：先算【下一个】下标 dd_sel_nxt，再用它选源，零新增触发器。
    wire [1:0]  dd_sel_nxt = (dd_sel == 4'd2) ? 2'd0 : (dd_sel[1:0] + 2'd1);
    wire [13:0] dd_src_nxt = (dd_sel_nxt == 2'd0) ? d_press :
                             (dd_sel_nxt == 2'd1) ? d_temp  : d_level;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dd_sel    <= 4'd0;
            dd_it     <= 4'd0;
            dd_s      <= 30'd0;
            bcd_valid <= 1'b0;
        end else begin
            // 第 3 路（液位）转换完成 -> 之后读数才有意义
            if (dd_sel == 4'd2 && dd_it == 4'd14)
                bcd_valid <= 1'b1;

            if (upd_tick) begin
                dd_sel <= 4'd0;
                dd_it  <= 4'd0;
                dd_s   <= {16'd0, d_press};
            end else if (dd_it < 4'd14) begin
                dd_s  <= dd_step(dd_s);
                dd_it <= dd_it + 4'd1;
            end else begin
                bcd_res[dd_sel] <= dd_s[29:14];
                dd_it  <= 4'd0;
                dd_sel <= {2'b0, dd_sel_nxt};
                dd_s   <= {16'd0, dd_src_nxt};
            end
        end
    end

    // ---- BCD -> 显示字符（纯选择，无运算）----
    // nibble 编码：0..9 = 数字，4'hE = '.'，4'hF = 空格
    function [19:0] fmt_bcd4;
        input [15:0] b;                 // {千,百,十,个}
        begin
            fmt_bcd4[19:16] = (b[15:12] == 4'd0) ? 4'hF : b[15:12];
            fmt_bcd4[15:12] = ((b[15:12] == 4'd0) && (b[11:8] == 4'd0)) ? 4'hF : b[11:8];
            fmt_bcd4[11:8]  = ((b[15:12] == 4'd0) && (b[11:8] == 4'd0) &&
                               (b[7:4]  == 4'd0)) ? 4'hF : b[7:4];
            fmt_bcd4[7:4]   = b[3:0];
            fmt_bcd4[3:0]   = 4'hF;
        end
    endfunction

    function [19:0] fmt_bcdpress;
        input [15:0] b;                 // 0..999，单位 0.01MPa -> "X.XX"
        begin
            fmt_bcdpress[19:16] = b[11:8];     // 整数位 0..9
            fmt_bcdpress[15:12] = 4'hE;        // '.'
            fmt_bcdpress[11:8]  = b[7:4];
            fmt_bcdpress[7:4]   = b[3:0];
            fmt_bcdpress[3:0]   = 4'hF;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_p <= {4'h0, 4'hE, 4'h6, 4'h0, 4'hF};   // "0.60 "
            row_t <= {4'hF, 4'hF, 4'h6, 4'h0, 4'hF};   // "  60 "
            row_l <= {4'hF, 4'hF, 4'h5, 4'h5, 4'hF};   // "  55 "
        end else if (bcd_valid) begin
            row_p <= fmt_bcdpress(bcd_res[0]);
            row_t <= fmt_bcd4(bcd_res[1]);
            row_l <= fmt_bcd4(bcd_res[2]);
        end
    end

    // ==================================================================
    // 报警输出 + 横幅上滑：48(隐藏) -> 0(完全弹出)
    // ==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      alarm_on <= 1'b0;
        else             alarm_on <= alarm_active;
    end

    wire [5:0] bstep = BANNER_STEP[5:0];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) banner_off <= 6'd48;
        else if (frame_tick) begin
            if (alarm_on && banner_off > bstep)                banner_off <= banner_off - bstep;
            else if (alarm_on)                                 banner_off <= 6'd0;
            else if (!alarm_on && banner_off < (6'd48 - bstep)) banner_off <= banner_off + bstep;
            else if (!alarm_on)                                banner_off <= 6'd48;
        end
    end

    // ==================================================================
    // 指示灯：{通讯, 报警, 运行}
    //   ★ 待机页（页 4）"状态灯全绿" 由 hud_panel 按页配色实现 ★
    //     这里只给状态，不给颜色。
    // ==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lamp <= 3'b000;
        else begin
            lamp[0] <= ~alarm_on;                    // 运行：正常时常亮
            lamp[1] <= alarm_on & blink;             // 报警：快闪
            lamp[2] <= blink_slow;                   // 通讯：慢闪
        end
    end

endmodule
