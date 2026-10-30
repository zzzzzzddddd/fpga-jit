`timescale 1ns/1ps
// ============================================================================
// hud_keys.v -- 按键消抖 + 短按/长按识别
//
// 用于 K3（板上 KEY_3，引脚 B1）：
//   短按（按下即松开）      -> press      单拍脉冲
//   长按（按住 >= 1 秒）    -> long_press 单拍脉冲（按下满 1 秒时立刻产生）
//
// 消抖：同步 3 拍 + 电平稳定 20ms 才认账。按键为低有效。
// ============================================================================
module hud_keys #(
    parameter CLK_HZ  = 25000000,
    parameter DEB_MS  = 20,
    parameter LONG_MS = 1000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,          // 低有效
    output reg  press,           // 短按
    output reg  long_press       // 长按
);

    localparam DEB_CNT  = (CLK_HZ / 1000) * DEB_MS;
    localparam LONG_CNT = (CLK_HZ / 1000) * LONG_MS;

    // ---- 同步 + 消抖 ----
    reg [2:0]  sync;
    reg        stable;
    reg [19:0] deb_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync    <= 3'b111;
            stable  <= 1'b1;
            deb_cnt <= 20'd0;
        end else begin
            sync <= {sync[1:0], key_in};
            if (sync[2] != stable) begin
                if (deb_cnt >= DEB_CNT[19:0]) begin
                    stable  <= sync[2];
                    deb_cnt <= 20'd0;
                end else begin
                    deb_cnt <= deb_cnt + 20'd1;
                end
            end else begin
                deb_cnt <= 20'd0;
            end
        end
    end

    // ---- 短按 / 长按 ----
    reg        holding;
    reg        long_fired;
    reg [21:0] hold_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding    <= 1'b0;
            long_fired <= 1'b0;
            hold_cnt   <= 22'd0;
            press      <= 1'b0;
            long_press <= 1'b0;
        end else begin
            press      <= 1'b0;
            long_press <= 1'b0;

            if (!stable) begin                     // 按下（低有效）
                holding <= 1'b1;
                if (hold_cnt < LONG_CNT[21:0]) begin
                    hold_cnt <= hold_cnt + 22'd1;
                end else if (!long_fired) begin
                    long_fired <= 1'b1;
                    long_press <= 1'b1;            // 满 1 秒立刻报长按
                end
            end else begin                         // 松开
                if (holding && !long_fired)
                    press <= 1'b1;                 // 没到 1 秒就松手 -> 短按
                holding    <= 1'b0;
                long_fired <= 1'b0;
                hold_cnt   <= 22'd0;
            end
        end
    end

endmodule
