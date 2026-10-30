// ============================================================================
// buzzer_beep.v -- 报警蜂鸣器（clk 50MHz 域）
//
// 板上 BUZZER 网名接到 H11（厂商原理图 2_FPGA.pdf），厂商的 13_music 例程
// 就是用方波直接驱动这个脚（SPKER.v + spk 绑 H11），所以这里是同样做法：
// 约 2kHz 方波，不是 PPM/I2C 之类的有源蜂鸣器协议。
//
// 【间歇而不是长鸣】：报警一次持续 3~4 秒，连续方波非常吵，
// 所以做成"每 1 秒响 200ms"的断续音，既是提示音也不会让人想拔电。
//
// 复位：alarm_on 从 video_clk 域过来，走 2 级同步器。
// ★ 复位用 rst_n 而不是 rst_all ★
//   rst_all 里含 audio_pll_lock（audio_mclk 域），对 clk 是异步的，
//   拿它当 clk 域的复位会凭空造出一条 CDC。
//   而且复位时 buzzer 必须强制为 0，否则带配置后可能一直是高电平。
// ============================================================================
module buzzer_beep #(
    parameter CLK_HZ  = 50000000,
    parameter TONE_HZ = 2000,      // 音调
    parameter ON_MS   = 200,       // 每个周期响多久
    parameter PER_MS  = 1000       // 周期长度
)(
    input  wire clk,
    input  wire rst_n,
    input  wire alarm_on,          // video_clk 域，异步
    output reg  buzzer
);

    localparam HALF = CLK_HZ / (2 * TONE_HZ);      // 半个方波周期
    localparam PER  = (CLK_HZ / 1000) * PER_MS;    // 断续周期
    localparam ONC  = (CLK_HZ / 1000) * ON_MS;     // 其中响的时间

    // ---- 2 级同步 ----
    reg [2:0] async_s;

    // ---- 计数器 ----
    reg [31:0] tone_cnt;
    reg [31:0] per_cnt;
    reg        tone;

    wire       en = async_s[2];                    // 同步后的报警使能

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            async_s  <= 3'b000;
            tone_cnt <= 32'd0;
            per_cnt  <= 32'd0;
            tone     <= 1'b0;
            buzzer   <= 1'b0;
        end else begin
            async_s <= {async_s[1:0], alarm_on};

            // 断续周期计数
            if (per_cnt >= PER[31:0] - 32'd1) per_cnt <= 32'd0;
            else                              per_cnt <= per_cnt + 32'd1;

            // 2kHz 方波
            if (tone_cnt >= HALF[31:0] - 32'd1) begin
                tone_cnt <= 32'd0;
                tone     <= ~tone;
            end else begin
                tone_cnt <= tone_cnt + 32'd1;
            end

            buzzer <= en && (per_cnt < ONC[31:0]) && tone;
        end
    end

endmodule
