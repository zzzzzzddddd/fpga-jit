`timescale 1ns/1ps
// ============================================================
// dbl_buf_addr.v — 基础2 双缓冲读写基地址生成（可独立仿真）
//
// 与 dbl_buf_ctl 配合：frame_sel 只做帧切换，本模块把帧号
// 换算成 SDRAM 读写基地址。
//   - 写侧（sd_card_clk 域）：永远写"非显示帧"
//       frame_sel=0 -> 显示帧0, 写帧1(FRAME_WORDS)
//       frame_sel=1 -> 显示帧1, 写帧0(0)
//   - 读侧（video_clk 域，frame_sel 打两拍同步后）：永远读"显示帧"
//       frame_sel_v=0 -> 读帧0(0)
//       frame_sel_v=1 -> 读帧1(FRAME_WORDS)
// ============================================================
module dbl_buf_addr #(
    parameter FRAME_WORDS = 307200     // 640*480*24/32 = 一帧 32bit 字数
)(
    input  wire        frame_sel,      // 写域帧号（dbl_buf_ctl 输出）
    input  wire        frame_sel_v,    // 读域同步后的帧号（两级触发器同步）
    output wire [23:0] write_base,     // 写基地址
    output wire [23:0] read_base       // 读基地址
);
    assign write_base = frame_sel   ? 24'd0           : FRAME_WORDS;
    assign read_base  = frame_sel_v ? FRAME_WORDS     : 24'd0;

endmodule
