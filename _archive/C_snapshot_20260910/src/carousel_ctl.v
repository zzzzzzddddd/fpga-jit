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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            timer <= {TIMER_BITS{1'b0}};
        else if (carousel_en) begin
            if (timer_ovf)
                timer <= {TIMER_BITS{1'b0}};
            else
                timer <= timer + 1'b1;
        end else
            timer <= {TIMER_BITS{1'b0}};
    end

    // ---- 触发逻辑：轮播定时溢出产生单拍触发 ----
    // 手动翻图由 sd_card_bmp 内部按键直连 find（含忙时锁存），本模块只负责轮播触发。
    wire trig = carousel_en & timer_ovf;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            find_pulse <= 1'b0;
        else if (ready && trig)
            find_pulse <= 1'b1;
        else
            find_pulse <= 1'b0;
    end

endmodule
