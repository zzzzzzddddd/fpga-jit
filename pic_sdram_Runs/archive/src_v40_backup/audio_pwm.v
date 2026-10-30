`timescale 1ns/1ps
// ============================================================
// audio_pwm.v — 16bit 单声道 PCM -> 1 位 PWM 输出（H11 -> RC -> PAM8403）
// ============================================================
// 【为什么用一阶 sigma-delta 而不是朴素计数器 PWM】
// ============================================================
//   朴素 PWM 的载波频率 = f_clk / 2^N。要用 16bit 分辨率，载波只有
//   100MHz/65536 = 1.53kHz —— 直接落在人耳最敏感的中频段，喇叭里就是
//   一阵啸叫。降分辨率到 12bit 载波也才 24.4kHz。
//
//   而板子上给定的 RC 是 100Ω + 0.1µF，截止频率
//
//       fc = 1/(2*pi*100*1e-7) = 15.9kHz
//
//   一阶低通在 24.4kHz 处只有 -3.7dB 衰减 —— 拿它滤 12bit 朴素 PWM 的
//   载波根本不够，啸叫会清晰地混在语音里。
//
//   一阶 sigma-delta 把量化噪声整形成 f^2 的形状推到高频，音频带内
//   (0~8kHz) 的信噪比只取决于过采样率：本设计 OSR = 100MHz/16kHz = 6250，
//   带内理论 SNR 远超 16bit 音频本身。同一个 RC 就能滤干净。
//
//   ★ 代价：PWM 输出不再是"固定周期、占空比可变"，边沿是抖动的。
//     对 RC->功放这条模拟通路无所谓（它只看平均值），但如果哪天要拿这个
//     信号去驱动别的数字电路，要重新考虑。
//
// 【静音为什么是"喂 0"而不是"输出恒定低"】
// ============================================================
//   恒定低电平在 RC 之后是 -Vcc/2 的直流跳变，PAM8403 输入端的耦合电容
//   会把它变成一个"咔哒"声。喂 0 时调制器输出 50% 占空比，平均值 = Vcc/2，
//   与静音前的直流工作点相同 —— 不产生直流跳变，是真正的无声。
// ============================================================
module audio_pwm #(
    // 采样率，仅用于注释/自检，模块本身不依赖它（靠 pcm_stb 节拍）
    parameter integer SAMPLE_HZ = 16000
)(
    input  wire        clk,        // sd_card_clk 100MHz
    input  wire        rst,        // 高有效异步复位（沿用本工程约定）
    input  wire [15:0] pcm,        // 有符号 16bit 小端组装后的样本
    input  wire        pcm_stb,    // 单拍：pcm 有效
    input  wire        mute,       // 1 = 静音（喂 0，输出 50% 占空比）
    output reg         pwm_out     // -> PWM_AUDIO (H11)
);

    reg  signed [15:0] sample;     // 当前锁存的样本
    reg  signed [17:0] acc;        // 积分器，多留 2 位防溢出

    // 反馈量：输出 1 时 +32767，输出 0 时 -32768（满幅对称）
    wire signed [17:0] fb      = pwm_out ? 18'sd32767 : -18'sd32768;
    // 输入符号扩展到 18 位后与误差求和
    wire signed [17:0] x_ext   = {{2{sample[15]}}, sample};
    wire signed [17:0] acc_nxt = acc + x_ext - fb;

    always @(posedge clk or posedge rst) begin
        if (rst)
            sample <= 16'sd0;
        else if (pcm_stb)
            sample <= mute ? 16'sd0 : $signed(pcm);
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc     <= 18'sd0;
            pwm_out <= 1'b0;
        end else begin
            acc     <= acc_nxt;
            // acc_nxt >= 0  <=>  符号位为 0
            pwm_out <= ~acc_nxt[17];
        end
    end

endmodule
