`timescale 1ns/1ps
// ============================================================
// dbl_buf_ctl.v  — 基础2 双缓冲帧切换控制器（消除切图闪烁/撕裂）
//
// 原理：SDRAM 中划出两个帧区（基地址 0 和 FRAME_WORDS）。
//       bmp_read 写入"非显示帧"，视频侧读取"显示帧"；
//       一帧写完后 frame_done 拉一脉冲，frame_sel 翻转，
//       显示切换到刚写完的帧，同时写入目标切到另一帧。
//       => 显示侧永远读到完整一帧，切图无撕裂。
//
// 时钟域处理（见集成说明）：
//   frame_sel 为单比特，跨时钟域安全（video_clk 域打两拍使用）。
//
// 接口极简：只维护一个 frame_sel 翻转寄存器。
// ============================================================
module dbl_buf_ctl #(
    parameter ADDR_BITS   = 21,
    parameter FRAME_WORDS = 307200     // 640*480*24/32，一帧占用的 32bit 字数
)(
    input  clk,              // 与 bmp_read 同域（sd_card_clk）
    input  rst_n,
    input  frame_done,       // 一帧写入完成脉冲（state_code 4->1 沿检测）
    output reg frame_sel     // 0=显示帧0/写帧1；1=显示帧1/写帧0
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            frame_sel <= 1'b0;
        else if (frame_done)
            frame_sel <= ~frame_sel;
    end

endmodule
