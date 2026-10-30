`timescale 1ns/1ps


// ============================================================================
// i2s_tx.v — I2S transmitter (FPGA master mode)
// 基础三：48kHz 测试音频的 I2S 串行输出
//
// 时钟关系（HDMI 音频标准）：
//   MCLK  = 12.288 MHz  (256 * fs, fs = 48 kHz)
//   BCLK  = 1.536 MHz   (32 * fs = MCLK / 8)
//   LRCLK = 48 kHz      (BCLK / 32)
//
// 时序（标准 I2S）：
//   LRCLK 低电平 = 左声道, 高电平 = 右声道
//   数据 MSB-first, LRCLK 翻转后延迟 1 个 BCLK 开始有效
//   数据在 BCLK 稳定期更新, BCLK 上升沿时接收端采样
//
// 单时钟单 always 块实现, 全部逻辑在 mclk 域:
//   tick 0..7 循环 -> BCLK 8 分频 (tick==3 时翻转, 上升/下降沿都在 tick==3)
//   数据/位计数/帧同步在 tick==1 更新 (BCLK 稳定期, 距边沿 2 个 mclk)
//
// 用法：与 audio_gen 闭环 —— frame_sync 每帧 1 个 mclk 宽脉冲,
//       audio_gen 收到后更新采样, 通过 data_valid 送回本模块。
// ============================================================================

module i2s_tx (
    input  wire       mclk,           // 12.288 MHz 音频主时钟
    input  wire       rst_n,
    // 并行音频数据（来自 audio_gen）
    input  wire [15:0] l_data,
    input  wire [15:0] r_data,
    input  wire        data_valid,
    // I2S 串行输出
    output wire        bclk,           // 位时钟 1.536 MHz
    output reg         lrclk,          // 帧时钟 48 kHz
    output reg         dout,           // 串行数据
    // 帧同步（回送 audio_gen）
    output reg         frame_sync
);

    reg  [2:0]  tick;          // 0..7 mclk 分频计数
    reg         bclk_r;        // BCLK 寄存器输出
    reg  [4:0]  bit_cnt;       // 位计数 0..31 (一帧 = 16bit L + 16bit R)
    reg  [15:0] shift;         // 移位寄存器
    reg  [15:0] lq, rq;        // 采样锁存

    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            tick       <= 3'd0;
            bclk_r     <= 1'b0;
            bit_cnt    <= 5'd0;
            shift      <= 16'h0000;
            dout       <= 1'b0;
            lq         <= 16'h0000;
            rq         <= 16'h0000;
            lrclk      <= 1'b0;
            frame_sync <= 1'b0;
        end else begin
            // ---- tick 计数 (0..7 循环) ----
            if (tick == 3'd7)
                tick <= 3'd0;
            else
                tick <= tick + 3'd1;

            // ---- BCLK 翻转 (tick==3 与 tick==7: 每 4 mclk 翻转 = 8 分频) ----
            if (tick == 3'd3 || tick == 3'd7)
                bclk_r <= ~bclk_r;

            // ---- 采样数据锁存（任意时刻）----
            if (data_valid) begin
                lq <= l_data;
                rq <= r_data;
            end

            // ---- 数据/位计数/帧时钟更新 (tick==1, 每 8 mclk 一次 = 每 BCLK 一次) ----
            if (tick == 3'd1) begin
                if (bit_cnt == 5'd0)       shift <= lq;              // 左声道
                else if (bit_cnt == 5'd16) shift <= rq;              // 右声道
                else                       shift <= {shift[14:0], 1'b0};
                dout    <= shift[15];                                 // MSB-first
                bit_cnt <= (bit_cnt == 5'd31) ? 5'd0 : bit_cnt + 5'd1;
                lrclk   <= bit_cnt[4];      // bit 0..15 低(左), 16..31 高(右)
            end

            // ---- 帧同步脉冲: 每帧开始 1 个 mclk 宽 ----
            frame_sync <= (tick == 3'd1 && bit_cnt == 5'd0) ? 1'b1 : 1'b0;
        end
    end

    assign bclk = bclk_r;

endmodule