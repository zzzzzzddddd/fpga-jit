`timescale 1ns/1ps
// ★ 本文件由 tools/probe_rate_selftest.py 从 src/top.v 自动抽取，不要手改 ★
module probe_dut (
    input  wire        sd_card_clk,
    input  wire        por_rst_n,
    input  wire        aud_pcm_stb,
    input  wire [15:0] aud_pcm,
    input  wire [3:0]  wav_state_code,
    input  wire        AUDIO_TEST_TONE,
    input  wire        wav_play,
    output wire [3:0]  d4,
    output wire [3:0]  d2,
    output wire [3:0]  d5
);
reg [3:0]  wav_st_max;      // 本次 play 以来 state_code 达到过的最大值（粘滞）
reg [15:0] wav_mag_max;
// |样本|：pcm 是有符号 16bit，先取绝对值再看高 4 位
//   ★ 量的位置 = audio_pwm 真正收到的那个源（见上面 aud_pcm 的说明）★
wire [15:0] wav_mag = aud_pcm[15] ? (~aud_pcm + 16'd1) : aud_pcm;

// 计数清零沿：正常固件用 wav_play（每次发起播放清零重爬）；
// 测试音固件下【不清零】—— 那边是连续的正弦，每按一次键就清零反而
// 让 D4/D5 变得一会儿 0 一会儿 E，读不出"一直在出"这个事实。
wire probe_clr = AUDIO_TEST_TONE ? 1'b0 : wav_play;

// ---------------------------------------------------------------------
// ★★ 第二十四版：D4 从"样本【个数】"换成"样本【速率】" ★★
// ---------------------------------------------------------------------
// 【旧口径的病，务必记住】
//   第二十版的 D4 = "本次 play 以来收到的 pcm_stb 个数，饱和在 14"。
//   于是 **"每秒 16000 个样本" 和 "整段总共只来了 14 个样本"
//   在面板上读出来一模一样** —— 这是典型的"有无"型判据。
//
//   更坏的是它会**假装自己是对的**：D5 取的是"本次最大|样本|"，
//   而只要整段文件最终都被过了一遍，**哪怕是以极低的速率涓流出来的**，
//   D5 也会爬到正确的峰值（当时是 4/4/3/7/7/6；第二十七版归一后是 7/5/5/2/2/6）。
//   ⇒ **"D4=E 且 D5 是正确峰值"完全兼容"样本稀疏到听不出语音"这种情况。**
//   （上板实测就是 D3=E / D4=E / D5 对，却仍然没声。）
//   ⇒ 判据从"有无"改成"计数"，和 [[fat32-migration-status]] 的教训同一条。
//
// 【新口径】
//   0.25 秒窗口内数 aud_pcm_stb 个数，折算成"每秒样本数 ÷ 4096"：
//       16kHz ⇒ 0.25 秒里 4000 个 ⇒ 4000 >> 10 = 3  ⇒ **D4 应读 '3'**
//       ≈8kHz ⇒ 2000 ⇒ >>10 = 1                      ⇒ 读 '1'（半速！）
//       涓流 / 没有 ⇒ 0                                ⇒ 读 '0'
//   取"本次 play 以来见过的最大值"（粘滞）⇒ **什么时候抬头看都是同一个数**，
//   不用掐着 2~4 秒的播报窗口去抢时间看。
//   窗口取 0.25 秒而不是 1 秒：最短的 05.WAV 只有 2.08 秒，
//   0.25 秒能出 8 个窗口，不会出现"一个整窗都没走完"而误读 0。
// ---------------------------------------------------------------------
localparam [26:0] RATE_WIN_MAX = 27'd25_000_000 - 27'd1;   // 0.25s @100MHz
reg [26:0] rate_win;
reg [15:0] rate_cnt;
reg [3:0]  rate_max;
wire [5:0] rate_cand = rate_cnt[15:10];                    // = 每秒样本数 ÷ 4096
//   ★ 必须显式钳到 14 ★
//     直接把 6 位塞进 4 位会截断、可能得到 4'hF，
//     而 4'hF 会被 blank_if_ff 整位熄灭 —— 那正好把"速率爆表"显示成"什么都没有"。
wire [3:0] rate_now  = (rate_cand > 6'd14) ? 4'd14 : rate_cand[3:0];

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        wav_st_max  <= 4'd0;
        wav_mag_max <= 16'd0;
        rate_win    <= 27'd0;
        rate_cnt    <= 16'd0;
        rate_max    <= 4'd0;
    end else if (probe_clr) begin
        // 每次发起播放就清零重爬 —— 这样读到的永远是"刚刚那一次"
        wav_st_max  <= 4'd0;
        wav_mag_max <= 16'd0;
        rate_win    <= 27'd0;
        rate_cnt    <= 16'd0;
        rate_max    <= 4'd0;
    end else begin
        if (wav_state_code > wav_st_max)
            wav_st_max  <= wav_state_code;
        if (aud_pcm_stb && (wav_mag > wav_mag_max))
            wav_mag_max <= wav_mag;

        if (rate_win == RATE_WIN_MAX) begin
            // 窗口满：把本窗口的计数收进 rate_max，然后重开一个窗口
            //   （这一拍不计数，最多丢 1 个样本/窗口 = 4 个/秒，可忽略）
            rate_win <= 27'd0;
            rate_cnt <= 16'd0;
            if (rate_now > rate_max) rate_max <= rate_now;
        end else begin
            rate_win <= rate_win + 27'd1;
            if (aud_pcm_stb && (rate_cnt != 16'hFFFF))
                rate_cnt <= rate_cnt + 16'd1;
        end
    end
end
assign d4 = rate_max;
assign d2 = wav_st_max;
assign d5 = wav_mag_max[15:12];
endmodule
