`timescale 1ns/1ps
// ============================================================================
// hud_switches.v -- 板上拨动开关 SW1-4 的同步 + 消抖
//
// 板上 SW1..SW4 的网名是 SWKEY01..SWKEY04，引脚 C8 / C7 / C6 / C5
// （依据厂商原理图 2_FPGA.pdf，并与 8_key_sw / 6_cnt10 例程交叉核对）。
// 四个开关是【各自独立的电平信号】，不是编码总线，所以逐位同步就是正确做法，
// 不需要像 frame_sel 那样额外加"总线一致性"的握手。
//
// 时序：2 级同步 + 20ms 电平消抖。开关是机械触点，抖动按毫秒计，
//       20ms 足够；同步级数按 top.v 里 frame_sel 的既有风格（2 级）。
//
// ★ 参数 CLK_HZ 一定要传对★
//   本模块被例化两次：video_clk(25MHz) 域和 clk(50MHz) 域各一份。
//   传错的话消抖窗口会差一倍（50MHz 传成 25MHz -> 实际 40ms；反之 10ms），
//   极端情况下等于没消抖，拨一次开关会被认成好几次。
// ============================================================================
module hud_switches #(
    parameter CLK_HZ  = 25000000,
    parameter DEB_MS  = 20,
    // 每位一个极性掩码：1 = 该位取反后再用。
    // ★ 本次第一号上板风险★ sw[i]=1 到底是"拨上"还是"拨下"必须实测。
    //   默认 0（原样）。上板后如果看到"拨上 SW1 反而把 HUD 关掉"，
    //   就把它改成 4'b1111，不要改下游逻辑。
    parameter [3:0] INVERT = 4'b0000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] sw_in,      // 直接来自引脚
    output reg  [3:0] sw_out      // 干净、消抖后的电平（已按 INVERT 处理）
);

    localparam DEB_CNT = (CLK_HZ / 1000) * DEB_MS;
    // 25MHz*20ms = 500000，50MHz*20ms = 1000000，20 位（最大 1048575）刚好够

    reg [2:0]  sync   [0:3];
    reg [19:0] deb    [0:3];
    reg [3:0]  stable;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                sync[i] <= 3'b000;
                deb[i]  <= 20'd0;
            end
            stable <= 4'b0000;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                sync[i] <= {sync[i][1:0], sw_in[i]};

                // 与 hud_keys.v 同一套消抖结构：电平一变就重新计时，
                // 连续稳定 DEB_CNT 拍才认账。
                // 这里读的 sync[i][2] 是移位【前】的值（非阻塞赋值），
                // 相当于比引脚晚 2 拍，仍然是合规的多级同步，与 hud_keys 一致。
                if (sync[i][2] != stable[i]) begin
                    if (deb[i] >= DEB_CNT[19:0]) begin
                        stable[i] <= sync[i][2];
                        deb[i]    <= 20'd0;
                    end else begin
                        deb[i] <= deb[i] + 20'd1;
                    end
                end else begin
                    deb[i] <= 20'd0;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sw_out <= 4'b0000;
        else        sw_out <= stable ^ INVERT;
    end

endmodule
