`timescale 1ns/1ps
// ============================================================================
// hud_top.v -- 压力容器多媒体演示 HUD 顶层
//
// 把"按键 -> 数据/页面 -> 叠加"三块包成一个，top.v 只需要例化这一个模块。
//
// ============================================================================
// 【六个界面】
//   页 0  三表总览      三个小表盘 + 三行读数        （开机默认）
//   页 1  压力放大      大压力表 + 压力趋势
//   页 2  温度放大      大温度表 + 温度趋势
//   页 3  液位放大      大液位表 + 液位趋势
//   页 4  待机巡检      三个量强制回安全值、状态灯全绿
//   页 5  储气罐故障    大压力表 + 压力趋势 + 红横幅
//
//   轮播只在 0->1->2->3->4->0 里转。**页 5 不在轮播里**，
//   只能由"参数超限自动跳转"或 SW3 强制进入。
//
// ============================================================================
// 【四个按键】—— 全部是 video_clk 域的单拍脉冲，只在 hud_data_gen 里消费
// ============================================================================
//   K1 -> 软复位：回总览页 0。【不重启 FPGA】，图和音频不中断
//   K2 -> 翻页：0->1->2->3->4->0
//   K3 -> 屏幕亮度 8 档循环
//   K4 -> 轮播 / 手动 切换（开机默认【手动】）
//
// ★ K1 为什么要改成软复位 ★
//   板上的 A2 原来是 rst_n 的硬复位。本工程改架构后，硬复位按一下会把 SD 卡、
//   HDMI、音频全重新初始化一遍，屏要黑一秒多，演示时很难看，而且和"回到主界面"
//   这个意图根本不是一回事。现在 A2 只接到这里当普通按键。
//   代价：板子上【不再有任何硬复位键】，出问题只能断电重上电。已和用户确认接受。
//   上电复位改成 top.v 里的 startup_pulse + PLL 锁定（见 top.v）。
//
// ============================================================================
// 【四个拨动开关】
// ============================================================================
//   SW1 -> 关闭"到报警界面时的警报声"，但【不关掉报警界面】
//   SW2 -> 从报警界面回到正常界面（确认）；三个量全回安全后自动重新武装
//   SW3 -> 手动强制进入报警界面（最高优先级）
//   SW4 -> 静音"切换播报音频"（TF 卡音频）
//
// ★ 和旧语义的差异（README 里也要写）★
//   旧的 SW1「HUD 叠加总开关」取消了 —— HUD 现在常开。
//   旧的 SW2「报警使能」、SW3「数据冻结」、SW4「节拍统一」全部取消。
//   `src/carousel_ctl.v` 不再例化（轮播计时搬进 hud_data_gen 的视频域），
//   文件保留不动，避免动 .prj。
//
// ============================================================================
// 【页与图彻底解耦】—— 本次最重要的结构性改动
// ============================================================================
//   旧架构：翻页的唯一来源是 img_changed（"屏幕刚换成一张新图"），
//           即"图读完 -> 才翻页"，页号是图片序号的纯函数。
//   新架构：【disp_page 是主人，图跟着页走】。
//           disp_page 一变 -> 立刻淡入淡出 + 切界面（不等图），
//           同时把页号经 toggle 送到 sd_card_clk 域，令 bmp_read 去读第 N 张。
//           图什么时候到就什么时候在淡出后面亮出来。
//
//   所以 frame_sel_v / img_changed / first_done 那一整套抑制机制整块删掉，
//   本模块不再需要 frame_sel_v 输入。
//
//   ★ 报警界面因此是【立刻】出现的，不用等 0.3 秒读图 ★ —— 这正是解耦的好处。
//   ★ 没插 SD 卡时：页面/表盘/读数/中文全部照常工作，只是底图是黑的。
//
// 插入位置：video_delay 之后、video_rgb_to_axis 之前。
// ============================================================================
module hud_top #(
    parameter CLK_HZ      = 25000000,
    parameter FADE_STEP   = 12,
    parameter BANNER_STEP = 4
)(
    input  wire        clk,          // video_clk 25MHz
    input  wire        rst_n,
    // ---- 板上四个按键（低有效）----
    input  wire        key1,         // KEY1 回总览
    input  wire        key2,         // KEY2 翻页
    input  wire        key3,         // KEY3 亮度
    input  wire        key4,         // KEY4 轮播/手动
    input  wire [3:0]  sw,           // 拨动开关 SW1-4
    input  wire [3:0]  state_code,   // SD 卡状态码（已同步到 video_clk）
    // ★ 诊断总线（已同步到 video_clk）—— 只喂数码管的 D2..D5 ★
    //   透传给 hud_seg_data。每一位的含义见 hud_seg_data.v 里的注释。
    input  wire [23:0] diag,
    // ---- 底层视频（video_delay 输出）----
    input  wire        hs,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] vout_data,
    // ---- 叠加后的视频 ----
    output wire        o_hs,
    output wire        o_vs,
    output wire        o_de,
    output wire [23:0] o_rgb,
    // ---- 给 clk(50MHz) 域的 seg_disp_top ----
    output wire [31:0] o_seg_dig,
    output wire [7:0]  o_seg_dp,
    output wire        o_seg_tog,
    // ---- 报警声（【已经被 SW1 门控】，给蜂鸣器 + HDMI 报警音）----
    // 界面本身不受它影响：hud_overlay 拿的是未门控的 alarm_on，
    // 所以 SW1 拨上去只是"消音"，报警界面还在。这就是需求要的行为。
    output wire        o_alarm,
    // ---- 给 top.v 的取图请求 ----
    // o_img_tog  : 页号每变一次翻转一次的 toggle。
    //              top.v 用 toggle + 3FF 同步 + XOR 边沿检测跨到 sd_card_clk 域。
    //              ★ 这里输出 toggle 而不是单拍脉冲 ★
    //              单拍脉冲（25MHz 域，40ns）直接喂两级同步器，理论上可能被
    //              整个吞掉（建立/保持窗口）。先在本域转成 toggle，
    //              宽到"半个变化周期"，同步器就不可能漏。
    //              跨过去之后 top.v 用 3FF + XOR 还原成单拍。
    //              下面的 hud_seg_data -> seg_disp_top 用的是同一套办法。
    output wire        o_img_tog,
    // o_img_index: 当前要显示第几张图（= disp_page）。toggle 传到之后，
    //              这个值已经稳了很久，可以直接在 sd 域采。
    output wire [2:0]  o_img_index,
    // ---- 已同步消抖的拨动开关（video_clk 域）----
    // top.v 要用 SW4 门控 TF 卡播报音频，但它自己那份 sw 是 50MHz 域的裸端口，
    // 直接拿去和本域的 hud_alarm / 页号做逻辑会混域。
    // ★ 不要再在 top.v 里另建一份开关同步 ★
    //   两份 INVERT 一旦不一致（这个极性本来就没实测过），
    //   SW4 静音和别处的开关语义就会对不上，而且很难看出来。
    output wire [3:0]  o_sw_sync
);

    // ==================================================================
    // 四个按键消抖
    //
    // hud_keys.press 是【严格单拍脉冲】（松手且未满 1 秒）。
    // long_press（按住 >= 1 秒）现在四个键都不用，四个键全是短按语义：
    //   K1 回总览 / K2 翻页 / K3 亮度 / K4 轮播切换
    // ==================================================================
    wire k1_press, k2_press, k3_press, k4_press;
    wire k1_long,  k2_long,  k3_long,  k4_long;   // 故意不用（见上）

    hud_keys #(.CLK_HZ(CLK_HZ)) u_keys1(
        .clk(clk), .rst_n(rst_n), .key_in(key1),
        .press(k1_press), .long_press(k1_long));
    hud_keys #(.CLK_HZ(CLK_HZ)) u_keys2(
        .clk(clk), .rst_n(rst_n), .key_in(key2),
        .press(k2_press), .long_press(k2_long));
    hud_keys #(.CLK_HZ(CLK_HZ)) u_keys3(
        .clk(clk), .rst_n(rst_n), .key_in(key3),
        .press(k3_press), .long_press(k3_long));
    hud_keys #(.CLK_HZ(CLK_HZ)) u_keys4(
        .clk(clk), .rst_n(rst_n), .key_in(key4),
        .press(k4_press), .long_press(k4_long));

    // ==================================================================
    // 拨动开关同步消抖
    // ★ CLK_HZ 必须传对★ 这里在 video_clk(25MHz) 域，
    //   clk(50MHz) 域那一份在 top.v 里，两边都要传对自己的频率。
    // ★ INVERT 的极性【从来没有实测过】★
    //   上板第一步就是用数码管的 D2..D5 读出四个开关的实际电平，据此确认。
    // ==================================================================
    wire [3:0] sw_sync;
    hud_switches #(.CLK_HZ(CLK_HZ)) u_sw(
        .clk(clk), .rst_n(rst_n), .sw_in(sw), .sw_out(sw_sync));

    assign o_sw_sync = sw_sync;

    // ==================================================================
    // 数据层 + 页面状态机
    // ==================================================================
    wire [2:0]  disp_page;
    wire [2:0]  rot_page;        // 轮播位，top.v 不用，留作调试观察
    wire        carousel_en;
    wire [7:0]  fade_alpha;
    wire [7:0]  bright;
    wire [9:0]  ang_p, ang_t, ang_l, ang_big;
    wire [19:0] row_p, row_t, row_l;
    wire [2:0]  lamp;
    wire        alarm_on;
    wire        blink;
    wire [5:0]  banner_off;
    wire        fl_p, fl_t, fl_l;
    wire [7:0]  tr_p, tr_t, tr_l;
    wire        trend_push;
    wire        frame_tick;
    wire        page_chg;

    hud_data_gen #(.CLK_HZ(CLK_HZ), .FADE_STEP(FADE_STEP),
                   .BANNER_STEP(BANNER_STEP)) u_data(
        .clk          (clk),
        .rst_n        (rst_n),
        .vs           (vs),
        .key1_press   (k1_press),
        .key2_press   (k2_press),
        .key3_press   (k3_press),
        .key4_press   (k4_press),
        .sw           (sw_sync),
        .disp_page    (disp_page),
        .rot_page     (rot_page),
        .carousel_en  (carousel_en),
        .alpha        (fade_alpha),
        .bright       (bright),
        .ang_p        (ang_p),
        .ang_t        (ang_t),
        .ang_l        (ang_l),
        .ang_big      (ang_big),
        .row_p        (row_p),
        .row_t        (row_t),
        .row_l        (row_l),
        .lamp         (lamp),
        .alarm_on     (alarm_on),
        .blink        (blink),
        .banner_off   (banner_off),
        .fl_p         (fl_p),
        .fl_t         (fl_t),
        .fl_l         (fl_l),
        .tr_p         (tr_p),
        .tr_t         (tr_t),
        .tr_l         (tr_l),
        .trend_push   (trend_push),
        .frame_tick_o (frame_tick),
        .o_page_chg   (page_chg),
        .o_img_index  (o_img_index)
    );

    // ---- 页变化脉冲 -> toggle（供 top.v 跨到 sd_card_clk 域）----
    reg img_tog_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        img_tog_r <= 1'b0;
        else if (page_chg) img_tog_r <= ~img_tog_r;
    end
    assign o_img_tog = img_tog_r;

    // ==================================================================
    // 8 位数码管：上板诊断面板（不是读数面板，见 hud_seg_data.v 头注释）
    // ==================================================================
    hud_seg_data u_seg(
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_tick (frame_tick),
        .disp_page  (disp_page),
        .rot_page   (rot_page),     // ★ 第十三版新增：报警钉住 disp_page 时，
                                    //   rot_page 仍反映 K2/轮播的真实选择 ★
        .state_code (state_code),
        .sw         (sw_sync),
        .diag       (diag),
        .fl_p       (fl_p),
        .fl_t       (fl_t),
        .fl_l       (fl_l),
        .alarm_on   (alarm_on),
        .seg_dig    (o_seg_dig),
        .seg_dp     (o_seg_dp),
        .seg_tog    (o_seg_tog)
    );

    // ---- SW1 只门控"声音"，不门控界面 ----
    // hud_overlay 拿的是未门控的 alarm_on，所以报警界面和红横幅照常显示；
    // 出去的 o_alarm 才是消音后的，接蜂鸣器和 HDMI 报警音。
    assign o_alarm = alarm_on & ~sw_sync[0];

    // ==================================================================
    // 像素级叠加
    // ==================================================================
    hud_overlay u_overlay(
        .clk        (clk),
        .rst_n      (rst_n),
        .hs         (hs),
        .vs         (vs),
        .de         (de),
        .vout_data  (vout_data),
        .disp_page  (disp_page),
        .fade_alpha (fade_alpha),
        .bright     (bright),
        .ang_big    (ang_big),
        .ang_p      (ang_p),
        .ang_t      (ang_t),
        .ang_l      (ang_l),
        .row_p      (row_p),
        .row_t      (row_t),
        .row_l      (row_l),
        .lamp       (lamp),
        .alarm_on   (alarm_on),
        .blink      (blink),
        .banner_off (banner_off),
        .carousel_en(carousel_en),
        .sw         (sw_sync),
        .fl_p       (fl_p),
        .fl_t       (fl_t),
        .fl_l       (fl_l),
        .tr_p       (tr_p),
        .tr_t       (tr_t),
        .tr_l       (tr_l),
        .trend_push (trend_push),
        .o_hs       (o_hs),
        .o_vs       (o_vs),
        .o_de       (o_de),
        .o_rgb      (o_rgb)
    );

endmodule
