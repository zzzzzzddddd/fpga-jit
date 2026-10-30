`timescale 1ns/1ps
// ============================================================
// hdmi_audio_tone_i2s_64fs.v — HDMI 音频输出（I2S 64fs 时序）
//
// ============================================================
// 【本版改动：从"要么音阶要么报警"改成三选一】
// ============================================================
//   旧版只有一个 I_alarm 电平：低 = do-re-mi 音阶，高 = 800/640Hz 两音交替。
//   现在音频有两个真实来源（TF 卡 PCM 流 + 报警提示音），
//   再加一个静音档，所以换成 I_mode[1:0]：
//
//     I_mode = 0  静音      输出全 0
//     I_mode = 1  播报      TF 卡 PCM，由 audio_fifo 供样，本模块发 O_pcm_req 要
//     I_mode = 2  报警      800Hz / 640Hz 两音交替（原有的合成方波）
//
// ============================================================
// 【do-re-mi 音阶为什么整块删掉】
// ============================================================
//   它是"没有别的音源时拿来做背景音"的占位实现。现在 mode 1 被 TF 卡 PCM
//   占用了，mode 2 是报警音，音阶【在任何 mode 下都到不了】—— 是彻底的死代码。
//   而 note_inc_lut（8 项 32bit）+ S_note_idx + S_note_frame_cnt 大约 40 个 LUT，
//   本项目 LUT 是最紧的资源（TD_BUILD_NOTES.md 记着 HUD 那 3200 个 LUT 曾经
//   把 125MHz 的 ext_mem_clk 压出 -0.328ns），所以留着没意义。
//   报警音用的是自己的 INC_ALARM_HI / INC_ALARM_LO 常量，不依赖音阶表。
//
// ============================================================
// 【和 audio_fifo 的握手：提前一拍要下一个样本】
// ============================================================
//   帧边界（右声道发完）每 256 个 I_mclk 出现一次 = 20.8us @ 12.295082MHz。
//   在这个点做两件事：
//     1) 把【当前】的 I_pcm 收进 S_sample_next  （数据先稳）
//     2) 同时发一个单拍 O_pcm_req 去要【下一个】样本
//
//   audio_fifo 的取数往返 ≈ 0.3us（req_tog 3FF 同步 + 弹栈 + ack_tog 3FF 同步，
//   见 audio_fifo.v 文件头），相对 20.8us 的帧周期有 60 倍余量。
//   所以到下一个帧边界时，I_pcm 早已换成新样本，绝无欠载。
//
//   ★ 直接把 audio_fifo.rd_data 接到 I_pcm 即可，不需要 I_pcm_valid ★
//     rd_data 是"一直稳定、在被取走时才更新"的寄存器，本模块在帧边界采样它，
//     两者异步但周期比是 1:256，采到的一定是稳定值。
//     （FIFO 空时是 sample-and-hold，保持上一个样本，不是补零 —— 理由见
//       audio_fifo.v 文件头：补零会在波形中间插一个跳变，更响。）
//
// ============================================================
// 【16bit 样本怎么塞进 24bit 时隙】
// ============================================================
//   I2S 惯例是左对齐：16bit 数据占 24bit 时隙的【高】16 位。
//   但这里再右移 2 位（即 {I_pcm[15:2], 10'd0}），把满量程压到 ÷4：
//   默认 AMP = 2000000 ≈ 满量程(2^23)的 0.24，如果 PCM 走满量程，
//   语音会比报警方波响 4 倍 —— 报警是警示音，被播报盖住就失去意义了。
//   想改响度平衡：调 AMP（往上还有 4 倍空间不会削顶），或者改这里的移位数。
//
// ============================================================
// 【已知的听感问题：切 mode 时会有一声"咔"】
// ============================================================
//   mode 切换是硬切，样本会从 ±AMP（方波）或者一个语音样值直接跳到另一个值，
//   最大跳变约 2*AMP ≈ 0.48 满量程 —— 会听见一声轻响。
//   没做淡入淡出是权衡后的决定：淡变需要一个 24bit 加法器 + 一小段状态机，
//   在本项目最紧的 LUT 上不划算，而 mode 切换是用户按键/拨开关触发的，
//   一秒里最多响一次。
//   如果上板听着确实刺耳，加一个 16 帧线性斜坡是最小的修法（约 50 LUT）。
// ============================================================
module hdmi_audio_tone_i2s_64fs #(
    parameter [31:0] PHASE_INC = 32'd39370534,   // 兼容旧顶层，本版内部不用它
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer ALARM_HOLD_FRAMES = 12000  // 报警两音交替 0.25s @ 48kHz
)(
    input  wire        I_mclk,      // 12.295082MHz（= 256fs，fs = 48.028kHz）
    input  wire        I_rst,
    // 【压力容器重构】音频模式。由 top.v 计算，本模块内再做 2FF 同步
    // （它是跨域过来的电平，且 mode 走线跨越较远，直接采可能碰到译码毛刺）
    input  wire [1:0]  I_mode,      // 0=静音 / 1=TF卡PCM / 2=报警两音
    input  wire [15:0] I_pcm,       // 来自 audio_fifo.rd_data（始终稳定）
    output reg         O_pcm_req,   // 单拍：请 audio_fifo 备下一个样本
    output reg         O_i2s_BCLK,
    output reg         O_i2s_LRCK,
    output reg         O_i2s_DOUT
);

localparam M_MUTE  = 2'd0;
localparam M_PCM   = 2'd1;
localparam M_ALARM = 2'd2;

// ============================================================================
// 报警提示音：800Hz / 640Hz 两音交替
//
// 频率换算关系（采样率 48kHz，方波取自相位累加器的最高位）：
//     freq = 48000 * inc / 2^32        即      inc = freq * 89478.4853
// 用旧版 la = A4 = 440Hz 的 39370534 复核：48000 * 39370534 / 2^32 = 440.0Hz ✓
//
// AMP 保持不变：输出是方波，任意时刻样本都是 ±AMP，音量只能靠加大而会削顶；
// 两音的区分度来自音高交替。而且正因为是方波，切频率时样本永远在 ±AMP 之间，
// 相位累加器本身还连续推进 —— 天然没有爆音，不需要任何淡入淡出。
// ============================================================================
localparam [31:0] INC_ALARM_HI = 32'd71582788;   // 800Hz
localparam [31:0] INC_ALARM_LO = 32'd57266231;   // 640Hz

// ---- I_mode 跨到本域（2FF）----
reg [1:0] mode_s1, mode_s2;
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin mode_s1 <= M_MUTE; mode_s2 <= M_MUTE; end
    else       begin mode_s1 <= I_mode; mode_s2 <= mode_s1; end
end

wire mode_alarm = (mode_s2 == M_ALARM);
wire mode_pcm   = (mode_s2 == M_PCM);

reg  [5:0]  S_bit_cnt;
reg  [63:0] S_shift_reg;
reg  [31:0] S_phase_acc;
reg signed [23:0] S_sample_word;
reg signed [23:0] S_sample_next;
// 报警音的两音交替状态
reg [15:0]  S_alarm_frame_cnt;
reg         S_alarm_hi;

wire [31:0] W_alarm_inc = S_alarm_hi ? INC_ALARM_HI : INC_ALARM_LO;

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK        <= 1'b0;
        O_i2s_LRCK        <= 1'b0;
        O_i2s_DOUT        <= 1'b0;
        O_pcm_req         <= 1'b0;
        S_bit_cnt         <= 6'd0;
        S_shift_reg       <= 64'd0;
        S_phase_acc       <= 32'd0;
        S_sample_word     <= 24'sd0;
        S_sample_next     <= 24'sd0;
        S_alarm_frame_cnt <= 16'd0;
        S_alarm_hi        <= 1'b0;
    end
    else begin
        // 保持和你现有接收端兼容的 64fs 发送时序
        O_i2s_BCLK <= ~O_i2s_BCLK;
        // 单拍脉冲，默认拉低；只在下面的帧边界（且是 PCM 模式）才抬起来
        O_pcm_req  <= 1'b0;

        if (O_i2s_BCLK == 1'b1) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;

                if (O_i2s_LRCK == 1'b0) begin
                    // 左声道发完，右声道复用同一个样本
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_sample_word[23:0], 40'd0};
                end
                else begin
                    // ---------------- 帧边界：产生下一个样本 ----------------
                    // 右声道发完，进入下一帧样本
                    O_i2s_LRCK  <= 1'b0;

                    // 注意这里的流水线：本拍算出的 S_sample_next 要到【下一个】
                    // 帧边界才会被装进 S_shift_reg / S_sample_word（下行用的是
                    // 旧值）。所以"本拍采样 I_pcm + 本拍发 O_pcm_req"正好对齐 ——
                    // 新样本有整整一个帧周期（20.8us）的时间到位。
                    if (mode_pcm) begin
                        // 16bit 左对齐进 24bit 时隙，再右移 2 位压到 ÷4 响度
                        S_sample_next <= {I_pcm[15:2], 10'd0};
                        O_pcm_req     <= 1'b1;      // 提前一手要下一个
                    end
                    else if (mode_alarm) begin
                        S_phase_acc   <= S_phase_acc + W_alarm_inc;
                        if (S_phase_acc[31])
                            S_sample_next <= AMP;
                        else
                            S_sample_next <= -AMP;
                    end
                    else begin
                        // 静音：输出真正的 0，而不是保持上一个样本。
                        // （这里和 FIFO 空时用 sample-and-hold 的处理不同：
                        //   FIFO 空是"短暂、意外的"，补零会在波形中间插跳变；
                        //   静音是"用户要的、持续的"，就该是干净的 0。）
                        S_sample_next <= 24'sd0;
                    end

                    S_sample_word <= S_sample_next;
                    S_shift_reg   <= {S_sample_next[23:0], 40'd0};

                    if (mode_alarm) begin
                        // 报警：两音交替计时。退出报警时计数清零，
                        // 下次进来从 800Hz 那一半重新开始。
                        if (S_alarm_frame_cnt == ALARM_HOLD_FRAMES - 1) begin
                            S_alarm_frame_cnt <= 16'd0;
                            S_alarm_hi        <= ~S_alarm_hi;
                        end
                        else begin
                            S_alarm_frame_cnt <= S_alarm_frame_cnt + 16'd1;
                        end
                    end
                    else begin
                        S_alarm_frame_cnt <= 16'd0;
                        S_alarm_hi        <= 1'b0;   // 下次进报警从 800Hz 起
                    end
                end
            end
            else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
            end
        end
    end
end

endmodule
