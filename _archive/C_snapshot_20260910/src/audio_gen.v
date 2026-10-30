`timescale 1ns/1ps


// ============================================================================
// audio_gen.v — 48kHz 双声道正弦测试音发生器
// 基础三：HDMI 输出 48kHz 测试音频
//
// 原理：相位累加器 (PHASE_BITS 位) + 256 点正弦查找表
//   PHASE_INC = TONE_FREQ * 2^PHASE_BITS / 48000
//   默认 1kHz: 2^32 * 1000 / 48000 = 89478485
//
// 接口：fsync 为 48kHz 帧脉冲（来自 i2s_tx.frame_sync），
//       每个 fsync 输出一对左右声道采样并拉 data_valid。
// ============================================================================

module audio_gen #(
    parameter PHASE_BITS = 32,
    parameter PHASE_INC  = 32'd89478485   // 1 kHz 测试音 @ 48 kHz
)(
    input  wire        clk,              // 12.288 MHz 音频主时钟
    input  wire        rst_n,
    input  wire        fsync,            // 48 kHz 帧同步脉冲
    output reg  [15:0] l_data,           // 左声道 16bit 有符号
    output reg  [15:0] r_data,           // 右声道
    output reg         data_valid
);

    reg [PHASE_BITS-1:0] phase;
    wire [7:0] addr = phase[PHASE_BITS-1 -: 8];   // 高 8 位做查表地址
    wire [15:0] sin_val;

    sin_lut u_sin_lut (
        .addr (addr),
        .data (sin_val)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase      <= {PHASE_BITS{1'b0}};
            l_data     <= 16'h0000;
            r_data     <= 16'h0000;
            data_valid <= 1'b0;
        end else begin
            data_valid <= 1'b0;
            if (fsync) begin
                l_data     <= sin_val;           // 当前相位查表
                r_data     <= sin_val;           // 双声道相同测试音
                data_valid <= 1'b1;
                phase      <= phase + PHASE_INC; // 更新相位
            end
        end
    end

endmodule