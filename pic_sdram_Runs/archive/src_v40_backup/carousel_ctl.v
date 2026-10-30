`timescale 1ns/1ps
// ============================================================
// carousel_ctl.v  — 基础2 自动轮播 + 手动翻图控制器
// 功能：
//   1) 手动模式：按键按下(已消抖的下降沿) -> 输出单拍 find_pulse
//   2) 轮播模式：每 INTERVAL_MS 毫秒自动输出单拍 find_pulse
//   3) 模式切换：mode_key 每按一次翻转 carousel_en
// 输出 find_pulse 直接替代原 bmp_read.find 的按键输入
// 说明：轮播触发 find 后 bmp_read 会继续搜索 SD 卡上的下一张图；
//       配合 bmp_read_wrap.v（搜索回绕）可无限循环播放。
//
// 【基础融合 2026-09-29】新增 ext_hold / timer_rst，并修掉一个丢节拍的 bug。
//       详见下面两个 always 块的注释。
// ============================================================
module carousel_ctl #(
    parameter FREQ_MHZ   = 100,          // 输入时钟频率(MHz)，接 sd_card_clk 时用 100
    parameter INTERVAL_MS = 5000,        // 轮播间隔(ms)
    parameter TIMER_BITS = 32
)(
    input  clk,
    input  rst_n,
    input  key_mode_nedge,     // 模式切换按键（ax_debounce 的 button_negedge）
    input  ready,              // bmp_read.ready（=1 时才允许触发新搜索）
    // ---- 【基础融合】新增 ----
    input  ext_hold,           // 1=暂停自动轮播。SW4“节拍统一”打开时置位，
                               //   节拍改由 hud_data_gen 的 6s 定时器统一驱动（图+页同拍）
    input  timer_rst,          // 单拍：刚发生过一次搜索，5s 重新计时
    output reg  carousel_en,   // 1=轮播模式 0=手动模式
    output reg  find_pulse     // 单拍脉冲 -> bmp_read.find
);

    // 轮播定时器最大值（周期数）
    localparam TIMER_MAX = INTERVAL_MS * FREQ_MHZ * 1000;

    reg [TIMER_BITS-1:0] timer;
    wire timer_ovf = (timer == TIMER_MAX - 1);

    // ---- 模式切换：key_mode_nedge 已是消抖单拍脉冲，直接触发翻转 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            carousel_en <= 1'b1;          // 上电默认轮播模式
        else if (key_mode_nedge)
            carousel_en <= ~carousel_en;
    end

    // ---- 轮播定时器：仅轮播模式计数 ----
    // 【基础融合】两处修复：
    //
    //  1) ext_hold / timer_rst 时清零。
    //     timer_rst 由 top.v 用 state_code 1->2 的沿（=“开始一次搜索”）驱动，
    //     在 sd 域内检测、不需要 CDC，且天然覆盖 K1/K2/K3 三条手动路径。
    //     ★ 原来定时器【永不因手动翻图重置】★，所以按一下 K2/K3 翻一张后，
    //       最多 5s 内会被轮播再翻一张，观感就是“按一下跳两张”。
    //       （它自己轮播产生的搜索也会重置自己，无副作用。）
    //
    //  2) 溢出那一拍若 ready==0，原来会直接清零 —— 那一整个轮播节拍就【丢了】，
    //     间隔变成 10s。读帧占 5s 里约 300ms，所以约每 80 秒静默漏一次。
    //     改成停在上限等 ready：timer_ovf 保持为 1，ready 一到立刻出脉冲。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            timer <= {TIMER_BITS{1'b0}};
        else if (ext_hold || timer_rst)
            timer <= {TIMER_BITS{1'b0}};
        else if (carousel_en) begin
            if (timer_ovf) begin
                if (ready) timer <= {TIMER_BITS{1'b0}};   // 正常：溢出后清零
                else       timer <= timer;                // 忙：停在上限，等下拍
            end else
                timer <= timer + 1'b1;
        end else
            timer <= {TIMER_BITS{1'b0}};
    end

    // ---- 触发逻辑：轮播定时溢出产生单拍触发 ----
    // 手动翻图由 sd_card_bmp 内部按键直连 find（含忙时锁存），本模块只负责轮播触发。
    wire trig = carousel_en & timer_ovf & ~ext_hold;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            find_pulse <= 1'b0;
        else if (ready && trig)
            find_pulse <= 1'b1;
        else
            find_pulse <= 1'b0;
    end

endmodule
