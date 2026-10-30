`timescale 1ns/1ps
// ============================================================
// audio_sd_reader.v — 从 TF 卡流式读音频片段，写进 audio_fifo
//
// ============================================================
// 【卡上的音频怎么摆的】
// ============================================================
//   无头裸 PCM：16bit 有符号、小端、单声道、48kHz。
//   故意不放 44 字节 WAV 头 —— 44 不是 2 的倍数，会把"2 字节 = 1 样本"
//   的对齐整个打乱，每读一段都要多写一段对齐修补逻辑。想在 PC 上试听
//   就让 tools/layout_sd.py 额外另存一份 .wav，卡上这份保持裸的。
//
//   第 k 段 = 扇区 AUDIO_BASE + k*FRAG_STRIDE，长度由 frag_info() 给出。
//   段起点在扇区边界、字节数为偶 -> 16bit 天然对齐，不需要任何拼接修补。
//
//   片段表用 function + case 而不是 localparam 数组 / $readmemh：
//   后者在 Verilog-2001 里要么不合法（数组型 localparam），要么需要额外的
//   文件依赖（$readmemh 读不到就静默留 0）。function + case 是纯组合逻辑，
//   综合成一小片 LUT，没有文件依赖，TD 也不会因为找不到 .mem 而黑盒。
//
// ============================================================
// ★★ 最要命的一条：req 一旦拉高，必须一路保持到 rend ★★
// ============================================================
//   src/sd_arbiter.v 把 sd_sec_read 做成【电平】透传给 sd_card_top：
//       assign sd_sec_read = active & (grant ? aud_req : bmp_req);
//   而 sd_card_sec_read_write.v 的 S_READ 状态【中途没法取消】——
//   读到一个扇区的一半时把 sd_sec_read 拉低，控制器会卡在半路，
//   下一次读的地址和内部状态全乱，而且现象是"偶尔读出一坨垃圾"，
//   上板根本定位不到。
//
//   所以本模块的状态机刻意做成"请求-等待"两段：
//       S_REQ  : 抬 req，一拍后进 S_WAIT
//       S_WAIT : req 全程保持 1，唯一的出口是 rend
//   于是 req 的下落沿只可能出现在 rend 那一拍（在 S_WAIT 里给 req 赋 0，
//   实际生效是在 rend 的下一拍，那时仲裁器的 active 也正好归 0），
//   绝不会落在扇区中间。
//
//   切歌 / 停止同理：不在当下动 req，而是先记进 play_pend / stop_pend，
//   等到 rend 这个安全点上再执行。
//
// ============================================================
// 【为什么节流用 fifo_low 而不是 fifo_full】
// ============================================================
//   片段长 96000 字节 = 1.0 秒 = 187.5 个扇区，而 FIFO 只有 4096 个样本
//   （85ms）。要是敞开了读，32ms 就把 1 秒的数据全倒进去，FIFO 直接溢出。
//
//   用 wr_full 当刹车也不行：那样读得比放得快，FIFO 会长期挂在"满"附近，
//   SD 总线被音频持续占据，读图被压得很慢。
//
//   正确的做法是用【低水位 + 滞回】：
//     一个扇区读完时，只有当 FIFO 存量 < 低水位(2048 样本) 才再要下一个。
//   算一下就正好自洽：
//     一个扇区 = 512 字节 = 256 样本
//     存量从 2047 涨到 2303 -> 超过低水位 -> 停手
//     2303 样本按 48kHz 放掉，5.3ms 后回到 2047 -> 再要一个扇区
//     于是平均 5.3ms 一个扇区 = 187.5 扇区/秒 —— 正好是音频本身的速率。
//
//   音频不是"一直抢总线"，而是"每 5.3ms 抢一个扇区"。
//   配合 sd_arbiter 里那笔 3.2% 的账，读图从 306ms 只涨到约 316ms。
//
//   片段刚起头时 FIFO 是空的（flush 过），存量 0 < 低水位 -> 连读 8 个扇区
//   把它填到低水位，约 1.4ms。期间音频侧读到的是 flush 清出来的 0
//   （静音，不是爆音），第一个扇区到齐后就开始有声音了。
//
// ============================================================
module audio_sd_reader #(
    // ---- 卡上的固定布局（必须和 tools/layout_sd.py 的常量一致）----
    parameter [31:0] AUDIO_BASE  = 32'd32768,
    parameter [31:0] FRAG_STRIDE = 32'd4096
)(
    input  wire        clk,           // sd_card_clk 100MHz
    input  wire        rst,           // 高有效异步复位（沿用 SD 侧约定）
    input  wire        sd_init_done,  // 来自 sd_card_top

    // ---- 播放控制（来自 top.v，video_clk 域经 toggle-CDC 过来的单拍脉冲）----
    input  wire        play,          // 单拍：开始 / 切到 frag_idx 这一段
    input  wire [2:0]  frag_idx,      // 与 play 同拍到
    input  wire        stop,          // 单拍：停播（清 FIFO 立即静音）

    // ---- 到 audio_fifo（同域，直连）----
    input  wire        fifo_low,      // FIFO 存量低于低水位，可以再抢了
    output reg         fifo_wr_en,
    output reg  [15:0] fifo_wr_data,
    output reg         fifo_flush,

    // ---- 到 src/sd_arbiter.v（音频侧）----
    output reg         req,
    output reg  [31:0] addr,
    input  wire        rdata_valid,   // = sd_sec_read_data_valid & aud_grant
    input  wire [7:0]  rdata,
    input  wire        rend           // = sd_sec_read_end & aud_grant
);

// ==================================================================
// 状态编码
// ==================================================================
localparam S_IDLE = 2'd0;   // 没有在播的片段，等 play
localparam S_REQ  = 2'd1;   // 抬 req 要下一个扇区
localparam S_WAIT = 2'd2;   // req 保持高，等 rend
localparam S_HOLD = 2'd3;   // 片段没读完但 FIFO 存量够了，req 拉低等水位

// ==================================================================
// 寄存器声明
//   ★ 必须全部放在下面的 wire 之前 ★
//     Verilog-2001 里用了还没声明的标识符会【隐式建一根 1bit wire】，
//     等后面再 "reg [1:0] state;" 就是重复声明，直接报错。
// ==================================================================
reg  [1:0]  state;
reg  [31:0] fr_len;      // 本片段字节数
reg  [31:0] byte_cnt;    // 本片段已收字节数（到 fr_len 就饱和，不涨）
reg  [7:0]  byte_low;    // 一对字节里先到的那个（低字节）
reg         byte_sel;    // 0 = 下一个字节是低字节, 1 = 下一个是高字节

reg         play_pend;
reg  [2:0]  play_idx;
reg         stop_pend;

// ==================================================================
// 片段表：{字节长度[31:0], 起始扇区[31:0]}
//
//   六段对应六个界面。页 5（储气罐故障巡检）【没有】切换播报音频，
//   只有警报声，所以 top.v 进页 5 时不会发 play，只会发 stop。
//   长度都是 96000 字节 = 48000 样本 = 1.0 秒。改成别的长度只要保证
//   【是偶数】且【不超过 FRAG_STRIDE*512】即可。
//
//   注意 Frag_STRIDE = 4096 扇区 = 2 MiB，而一段只有 96000 字节
//   ≈ 188 个扇区，所以段与段之间留了大片空洞 —— 这是故意留的余量，
//   换更长的语音播报时不用改顶层的扇区布局。
// ==================================================================
function [63:0] frag_info;
    input [2:0] i;
    begin
        case (i)
        3'd0: frag_info = {32'd96000, AUDIO_BASE + 32'd0 * FRAG_STRIDE};
        3'd1: frag_info = {32'd96000, AUDIO_BASE + 32'd1 * FRAG_STRIDE};
        3'd2: frag_info = {32'd96000, AUDIO_BASE + 32'd2 * FRAG_STRIDE};
        3'd3: frag_info = {32'd96000, AUDIO_BASE + 32'd3 * FRAG_STRIDE};
        3'd4: frag_info = {32'd96000, AUDIO_BASE + 32'd4 * FRAG_STRIDE};
        3'd5: frag_info = {32'd96000, AUDIO_BASE + 32'd5 * FRAG_STRIDE};
        default: frag_info = {32'd96000, AUDIO_BASE};
        endcase
    end
endfunction

// ★ 不要写 frag_info(play_idx)[31:0] ★
//   Verilog-2001 只允许对 net / reg / integer / time 做位选和部分选，
//   函数调用结果是表达式，部分选不合法（有些工具当扩展收，TD 不一定）。
//   先落到一根 wire 上，再选它的位，就完全是标准写法了。
wire [63:0] frag_sel = frag_info(play_idx);

// ==================================================================
// play / stop 的待办锁存
//
//   play / stop 可能在任何时刻到达，包括扇区读到一半的时候。
//   那一刻【不能】动 req，所以先记下来，等 safe_pt 再兑现。
//
//   优先级：play > stop > consume
//     同一拍既有新 play 又有 consume 时，以新 play 为准 ——
//     否则会出现"刚清掉待办、新歌就丢了"的漏拍。
// ==================================================================
wire safe_pt = sd_init_done &&
               ((state == S_IDLE) || (state == S_HOLD) ||
                ((state == S_WAIT) && rend));
wire consume = safe_pt && (play_pend || stop_pend);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        play_pend <= 1'b0;
        play_idx  <= 3'd0;
        stop_pend <= 1'b0;
    end else if (play) begin
        play_pend <= 1'b1;
        play_idx  <= frag_idx;
        stop_pend <= 1'b0;
    end else if (stop) begin
        play_pend <= 1'b0;
        stop_pend <= 1'b1;
    end else if (consume) begin
        play_pend <= 1'b0;
        stop_pend <= 1'b0;
    end
end

// ==================================================================
// 主状态机
// ==================================================================
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state        <= S_IDLE;
        req          <= 1'b0;
        addr         <= AUDIO_BASE;
        fr_len       <= 32'd0;
        byte_cnt     <= 32'd0;
        byte_low     <= 8'd0;
        byte_sel     <= 1'b0;
        fifo_wr_en   <= 1'b0;
        fifo_wr_data <= 16'd0;
        fifo_flush   <= 1'b0;
    end else begin
        // 两个输出都是单拍脉冲，先给默认值
        fifo_wr_en <= 1'b0;
        fifo_flush <= 1'b0;

        // ----------------------------------------------------------
        // 字节流 -> 样本
        //   每 2 个字节拼 1 个 16bit 样本，小端：先到的在低 8 位。
        //   第 2 个字节到齐的那一拍写 FIFO。
        //
        //   长度门控用的是"拼之前"的 byte_cnt（此时是这一对里第二个
        //   字节的下标，必为奇数）。fr_len 为偶数，所以
        //   byte_cnt < fr_len 等价于"这一对完整落在片段内"。
        //   ⚠ 如果哪天把 fr_len 改成奇数，最后一个字节会被丢掉。
        // ----------------------------------------------------------
        if (rdata_valid && (state == S_WAIT)) begin
            if (byte_sel == 1'b0) begin
                byte_low <= rdata;
                byte_sel <= 1'b1;
            end else begin
                byte_sel <= 1'b0;
                if (byte_cnt < fr_len) begin
                    fifo_wr_en   <= 1'b1;
                    fifo_wr_data <= {rdata, byte_low};
                end
            end
            if (byte_cnt < fr_len)
                byte_cnt <= byte_cnt + 32'd1;
        end

        // ----------------------------------------------------------
        // SD 卡没初始化完就什么都不做。req 必须为 0，
        // 否则仲裁器会带着一个陈旧的授权跑起来。
        // （play_pend 故意【不】在这里清 —— 上电时 top.v 可能先发了 play
        //   再等卡初始化，这时候待办要留着，初始化一完成就自动开播。）
        // ----------------------------------------------------------
        if (!sd_init_done) begin
            state      <= S_IDLE;
            req        <= 1'b0;
            byte_cnt   <= 32'd0;
            byte_sel   <= 1'b0;
            fifo_wr_en <= 1'b0;
        end else case (state)

        // --------------------------------------------------------
        S_IDLE: begin
            req <= 1'b0;
            if (play_pend) begin
                addr       <= frag_sel[31:0];
                fr_len     <= frag_sel[63:32];
                byte_cnt   <= 32'd0;
                byte_sel   <= 1'b0;
                fifo_flush <= 1'b1;         // 先清干净，别把上一段的尾巴带进来
                state      <= S_REQ;
            end else if (stop_pend) begin
                fifo_flush <= 1'b1;         // 已经没在播了，这是让残留立刻静音
            end
        end

        // --------------------------------------------------------
        S_REQ: begin
            req   <= 1'b1;
            state <= S_WAIT;
        end

        // --------------------------------------------------------
        // ★ req 在这个状态里全程保持 1，唯一的出口是 rend ★
        // --------------------------------------------------------
        S_WAIT: begin
            req <= 1'b1;
            if (rend) begin
                addr     <= addr + 32'd1;
                // 512 字节是偶数，正常情况下 byte_sel 到扇区尾自然回 0。
                // 这里强制归零是兜底：万一某个扇区的 data_valid 个数不是
                // 偶数，也不至于让后面所有样本的高低字节整个反掉。
                byte_sel <= 1'b0;

                if (play_pend) begin
                    // 切歌：本扇区刚结束，现在是安全的
                    addr       <= frag_sel[31:0];
                    fr_len     <= frag_sel[63:32];
                    byte_cnt   <= 32'd0;
                    fifo_flush <= 1'b1;
                    state      <= S_REQ;    // req 不回 0，无缝接着读下一段
                end else if (stop_pend) begin
                    req        <= 1'b0;
                    fifo_flush <= 1'b1;
                    state      <= S_IDLE;
                end else if (byte_cnt >= fr_len) begin
                    req        <= 1'b0;
                    state      <= S_IDLE;   // 这一段播完了
                end else if (fifo_low) begin
                    state      <= S_REQ;    // 存量还偏低，继续抢（req 不回 0）
                end else begin
                    req        <= 1'b0;
                    state      <= S_HOLD;   // 存量够了，先歇着
                end
            end
        end

        // --------------------------------------------------------
        // 片段没读完，但 FIFO 存量已经够用。req 拉低，等水位掉下去。
        // 这个状态里 req 是 0，所以 play / stop 可以立刻执行。
        // --------------------------------------------------------
        S_HOLD: begin
            req <= 1'b0;
            if (play_pend) begin
                addr       <= frag_sel[31:0];
                fr_len     <= frag_sel[63:32];
                byte_cnt   <= 32'd0;
                byte_sel   <= 1'b0;
                fifo_flush <= 1'b1;
                state      <= S_REQ;
            end else if (stop_pend) begin
                fifo_flush <= 1'b1;
                state      <= S_IDLE;
            end else if (byte_cnt >= fr_len) begin
                state      <= S_IDLE;
            end else if (fifo_low) begin
                state      <= S_REQ;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
