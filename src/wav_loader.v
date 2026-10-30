`timescale 1ns/1ps
// ============================================================
// wav_loader.v — 从 FAT32 打开 WAV、解析 RIFF、流式送出 16bit PCM
// ============================================================
// 【和旧 audio_sd_reader.v 的根本区别】
// ============================================================
//   旧的 audio_sd_reader 是"固定 LBA + 写死常量"：
//     frag_info() 里每段长度硬编码 96000 字节、起始扇区 = AUDIO_BASE + i*FRAG_STRIDE，
//     采样率隐含假设 48kHz。换一段素材就得重跑 tools/layout_sd.py 重写整张卡。
//
//   本模块按文件名打开，并且**真的去走 RIFF chunk 链**：
//     - 不假设头是 44 字节（可能是 44/46/58，或中间夹了 LIST/fact 块）
//     - 不假设 data 紧跟在 fmt 后面
//     - 采样率从 fmt 块里读，而不是写死
//
// ============================================================
// 【为什么必须缓冲，而且必须是乒乓】
// ============================================================
//   一个扇区 = 512 字节 = 256 个样本。16kHz 下 256 样本 = 16ms。
//   而读一个扇区（含可能的 FAT 表读）最坏约 340us。
//   不缓冲的话每 16ms 断流 340us，喇叭里就是每 16ms 一次的"咔"。
//
//   乒乓（两个 512 字节半区）：播半区 A 的 16ms 期间去填 B；
//   播完 A 翻到 B 时 A 空出来，立刻填 A。填充 340us / 可用 16ms，
//   余量 47 倍 —— 就算图片流正在猛读、音频要排队等仲裁器也追得上。
//
// ============================================================
// 【播放长度靠 rd_remain 而不是半区边界】
// ============================================================
//   最后一轮填充可能不满 512 字节（data 长度不是 512 的整数倍，
//   素材里 06 段 165760、05 段 96176 都是除不尽 512 的长度）。
//   若靠"读到半区末尾就翻页"推进，翻页点会落在过期数据上。
//   这里用从 data_len 递减的 rd_remain 精确控制播放长度，减到 0 就停，
//   与半区边界无关。半区只是缓冲，不是计数单位。
//
// ============================================================
// 【寄存器驱动的硬约束 —— 改这个文件时不要破坏】
// ============================================================
//   见下面每个 always 块前的"本块独占驱动"清单。三条要点：
//
//   1. data_off / data_len / strobe_div / rate_ok / fmt_ok 只在**头解析器**
//      那一个 always 块里赋值，且都只在"那一拍"赋一次。
//      绝不能写成 `if (hp == HP_DONE) ...`：hp 到达 HP_DONE 后永远停在那里，
//      那种写法会每个时钟周期用已推进的偏移重新覆盖 data_off，结果立刻被冲掉。
//
//   2. rd_half / rd_ph / rd_idx / rd_remain / strobe_cnt / pcm / pcm_stb
//      只由**播放侧**那一个 always 块驱动。主状态机不得赋值，
//      否则两个 always 驱动同一个 reg，综合直接报 multiple drivers。
//
//   3. 头解析器不用 task，而是一个独立的 always 块（hp_stb/hp_data/hp_off
//      由主状态机驱动）。原因有两个：
//        - tools/vcheck.py 用的 pyverilog 裸解析器**不接受 task 调用语句**
//          （`task_name(args);` 会报 "before: ("），用 task 会让这个
//          几秒级的快速语法检查对整份文件失效，只能等 TD 几分钟的综合。
//        - task 里读到的 fetch_off 是"调用那一拍"的值，而字节偏移到底该
//          取调用拍还是下一拍，是个很容易搞错又很难看出来的 off-by-one。
//          改成显式传 hp_off，语义就没歧义了。
// ============================================================
module wav_loader (
    input  wire        clk,           // sd_card_clk 100MHz
    input  wire        rst,
    input  wire        sd_init_done,

    // ---------------- 播放控制 ----------------
    input  wire        play,          // 单拍：从头播放 frag_idx 对应的 WAV（可打断）
    input  wire [2:0]  frag_idx,      // 0..5 -> 01.WAV..06.WAV
    input  wire        stop,          // 单拍：立即停止
    output reg         playing,       // 1 = 正在出声
    output reg         done,          // 单拍：一段播完（自然结束）
    output reg         err,           // 1 = 打开失败 / 头非法（保持到下次 play）

    // ---------------- 到 fat32_reader（u_fat32_wav）----------------
    output reg         f_open_req,
    output reg  [3:0]  f_file_idx,    // 6..11
    input  wire        f_open_done,
    input  wire        f_found,
    input  wire [31:0] f_file_size,
    output reg         f_xl_req,
    output reg  [31:0] f_xl_sec_idx,
    input  wire        f_xl_valid,
    input  wire [31:0] f_xl_lba,
    input  wire        f_xl_err,

    // ---------------- 到 sd_arbiter 的数据读口 ----------------
    output reg         sd_req,
    output reg  [31:0] sd_addr,
    input  wire        sd_grant,
    input  wire [7:0]  sd_data,
    input  wire        sd_valid,
    input  wire        sd_end,

    // ---------------- 到 audio_pwm ----------------
    output reg  [15:0] pcm,
    output reg         pcm_stb,       // 单拍：新的 16bit 样本

    // ---------------- 诊断 ----------------
    output reg  [3:0]  state_code,
    output reg         rate_ok,       // 1 = fmt 里的采样率在支持表内
    output reg         fmt_ok         // 1 = PCM/单声道/16bit 三项都对
);

// ------------------------------------------------------------------
// 主状态机编码
// ------------------------------------------------------------------
localparam A_IDLE    = 4'd0;
localparam A_OPEN    = 4'd1;
localparam A_OPEN_W  = 4'd2;
localparam A_SEEK    = 4'd3;   // 对"下一个需要的文件扇区"发起翻译
localparam A_SEEK_W  = 4'd4;
localparam A_SREQ    = 4'd5;   // 向仲裁器发起扇区读
localparam A_SRD     = 4'd6;   // 收字节
localparam A_WAITPLY = 4'd7;   // 等播放侧腾出半区
localparam A_ERR     = 4'd8;

reg [3:0]  st;

// 取数模式：0 = 读 WAV 头，1 = 读 data 区填缓冲
reg        mode_data;

// 下一个需要的**文件内字节偏移**。两种模式都靠它推导扇区号和扇区内偏移：
//   扇区号 = fetch_off >> 9      扇区内偏移 = fetch_off[8:0]
// 用字节偏移而不是"扇区号 + 计数器"，跨扇区时自动就对了。
reg [31:0] fetch_off;
wire [31:0] need_sec  = fetch_off >> 9;
wire [8:0]  need_skip = fetch_off[8:0];

reg [9:0]  bcnt;              // 当前扇区已收字节数 0..511

// ------------------------------------------------------------------
// 主状态机 -> 头解析器的握手
//   hp_stb 单拍 + hp_data（这一字节）+ hp_off（这一字节在文件内的偏移）
//   把偏移显式传过去，解析器就不需要自己猜"读的是调用拍还是下一拍的值"。
// ------------------------------------------------------------------
reg        hp_stb;
reg [7:0]  hp_data;
reg [31:0] hp_off;
reg        hp_rst;            // 主状态机单拍：让解析器回到初始状态

// ------------------------------------------------------------------
// WAV 头解析器状态（下面第三个 always 块独占驱动）
// ------------------------------------------------------------------
localparam HP_RIFF = 3'd0;    // 前 12 字节：RIFF + size + WAVE
localparam HP_CID  = 3'd1;    // chunk id 4 字节
localparam HP_CSZ  = 3'd2;    // chunk size 4 字节
localparam HP_FMT  = 3'd3;    // fmt 块内容前 16 字节
localparam HP_SKIP = 3'd4;    // 跳过本块剩余字节
localparam HP_DONE = 3'd5;    // 已定位到 data 块

reg [2:0]  hp;
reg [3:0]  hp_cnt;
reg [31:0] hp_cid;
reg [31:0] hp_csz;
reg [31:0] hp_skip;
reg        hdr_bad;

reg [15:0] fmt_audio;
reg [15:0] fmt_chan;
reg [31:0] fmt_rate;
reg [15:0] fmt_bits;

reg [31:0] data_off;          // data 载荷在文件内的字节偏移
reg [31:0] data_len;          // data 载荷字节数
reg [15:0] strobe_div;        // 采样节拍分频（100MHz / 采样率）

// ------------------------------------------------------------------
// 采样率 -> 100MHz 下的分频系数
//   不在表里的按 16kHz 走并把 rate_ok 拉低，这样"素材采样率不标准"和
//   "根本没读出来"在诊断位上能区分开。
// ------------------------------------------------------------------
function [15:0] rate_div;
    input [31:0] hz;
    begin
        case (hz)
            32'd8000 : rate_div = 16'd12500;
            32'd11025: rate_div = 16'd9070;
            32'd16000: rate_div = 16'd6250;
            32'd22050: rate_div = 16'd4535;
            32'd24000: rate_div = 16'd4167;
            32'd32000: rate_div = 16'd3125;
            32'd44100: rate_div = 16'd2268;
            32'd48000: rate_div = 16'd2083;
            default  : rate_div = 16'd6250;
        endcase
    end
endfunction

function rate_known;
    input [31:0] hz;
    begin
        rate_known = (hz == 32'd8000 ) || (hz == 32'd11025) || (hz == 32'd16000) ||
                     (hz == 32'd22050) || (hz == 32'd24000) || (hz == 32'd32000) ||
                     (hz == 32'd44100) || (hz == 32'd48000);
    end
endfunction

// ------------------------------------------------------------------
// 乒乓缓冲：1024 字节 = 两个 512 字节半区。addr[9] = 半区号
//
// ★ 数组名不能用 buf ★
//   buf 是 Verilog-2001 的保留关键字（门原语 buf/not/and/or/nand/nor/xor...）。
//   写成 `reg [7:0] buf [0:1023];` 时 TD 会直接报
//       ERROR: Verilog 2000 keyword 'buf' used in incorrect context
//   而且失败会往上传染：整个文件分析不过 -> 模块未定义 -> TD 把它标成
//   AutoExcluded -> top.v 引用它时报"模块找不到"。
//   症状离根因很远，很难一眼看出来，所以这里特地记一笔。
//   同理要避开的还有 not / and / or / xor / time / event / small / medium /
//   large / tri / wire 这类看着像普通变量的关键字。
// ------------------------------------------------------------------
reg [7:0]  pcm_buf [0:1023];
reg [7:0]  buf_rdata;
reg [9:0]  buf_waddr;
reg [7:0]  buf_wdata;
reg        buf_we;
reg [9:0]  buf_raddr;

always @(posedge clk) begin
    if (buf_we) pcm_buf[buf_waddr] <= buf_wdata;
    buf_rdata <= pcm_buf[buf_raddr];
end

// ------------------------------------------------------------------
// 填充侧状态（主状态机独占驱动）
// ------------------------------------------------------------------
reg [1:0]  free_mask;         // 位 H = 半区 H 空着、需要填
reg        rf_half;
reg [8:0]  rf_idx;
reg [9:0]  rf_need;
reg [31:0] wr_remain;         // 还没从 SD 取回来的 data 字节数
reg        prefill;
reg        start_play;        // 单拍：两个半区都填好了，通知播放侧

// ------------------------------------------------------------------
// 播放侧状态（播放侧那个 always 块独占驱动）
// ------------------------------------------------------------------
reg [1:0]  rd_ph;
reg        rd_half;
reg [8:0]  rd_idx;
reg [31:0] rd_remain;         // 还没播出去的 data 字节数
reg [15:0] strobe_cnt;

// 主状态机 -> 播放侧："把这一段的总长度装进 rd_remain"
//   rd_remain 归播放侧独占驱动，主状态机不能直接写它（否则就是
//   multiple drivers）。所以用 load_len 单拍 + len_val 带值过去。
reg        load_len;
reg [31:0] len_val;

wire sample_tick = (strobe_cnt == strobe_div - 16'd1);

// 腾空检测：rd_half 翻转 = 播放侧刚离开一个半区
reg  rd_half_d;
wire vacate_now   = (rd_half != rd_half_d);
wire vacate_which = rd_half_d;

// ==================================================================
// [1/3] 主状态机
//   本块独占驱动：st, mode_data, fetch_off, bcnt, hp_stb/hp_data/hp_off/hp_rst,
//                 f_*, sd_req/addr, playing, done, err,
//                 free_mask, rf_half, rf_idx, rf_need, wr_remain, prefill,
//                 start_play, state_code, buf_we
//   ★ 不得给 hp / hp_cnt / data_off / data_len / strobe_div / rate_ok /
//     fmt_ok 赋值 —— 它们归头解析器；也不得给 rd_* / pcm / pcm_stb /
//     strobe_cnt 赋值 —— 它们归播放侧。
// ==================================================================
always @(posedge clk or posedge rst) begin
    if (rst) begin
        st           <= A_IDLE;
        mode_data    <= 1'b0;
        fetch_off    <= 32'd0;
        bcnt         <= 10'd0;
        hp_stb       <= 1'b0;
        hp_data      <= 8'd0;
        hp_off       <= 32'd0;
        hp_rst       <= 1'b1;      // 复位时也让解析器归位（下面解析器自带复位，这里只是稳妥）
        f_open_req   <= 1'b0;
        f_file_idx   <= 4'd6;
        f_xl_req     <= 1'b0;
        f_xl_sec_idx <= 32'd0;
        sd_req       <= 1'b0;
        sd_addr      <= 32'd0;
        playing      <= 1'b0;
        done         <= 1'b0;
        err          <= 1'b0;
        free_mask    <= 2'b00;
        rf_half      <= 1'b0;
        rf_idx       <= 9'd0;
        rf_need      <= 10'd0;
        wr_remain    <= 32'd0;
        prefill      <= 1'b0;
        start_play   <= 1'b0;
        state_code   <= 4'd0;
        buf_we       <= 1'b0;
    end else if (!sd_init_done) begin
        // 卡重新初始化：停下来，别带着半截状态跑
        st         <= A_IDLE;
        playing    <= 1'b0;
        f_open_req <= 1'b0;
        f_xl_req   <= 1'b0;
        sd_req     <= 1'b0;
        hp_stb     <= 1'b0;
        hp_rst     <= 1'b1;
        buf_we     <= 1'b0;
        state_code <= 4'd0;
    end else begin
        done       <= 1'b0;
        start_play <= 1'b0;
        load_len   <= 1'b0;          // 每拍默认不装长度
        hp_stb     <= 1'b0;          // 每拍默认不喂字节
        hp_rst     <= 1'b0;
        buf_we     <= 1'b0;          // 每拍默认不写，A_SRD 里显式置起
        playing    <= (st == A_WAITPLY) && (rd_remain != 32'd0);

        // ------------------------------------------------------------------
        // play / stop 是**全局**的，不能写在 case 里面
        //
        //   写在 A_IDLE 分支里的话，只有 FSM 恰好停在 A_IDLE 那一拍才认这个请求。
        //   而切页是随时可能发生的（上一段可能还在填缓冲、还在出声），
        //   那样新的一段就会被丢掉，必须等旧的播完才能响应 —— 与"切页可打断"不符。
        // ------------------------------------------------------------------
        if (play) begin
            err        <= 1'b0;
            hp_rst     <= 1'b1;      // 让解析器回到 HP_RIFF
            fetch_off  <= 32'd0;
            free_mask  <= 2'b00;
            prefill    <= 1'b1;
            rf_half    <= 1'b0;
            rf_idx     <= 9'd0;
            mode_data  <= 1'b0;
            wr_remain  <= 32'd0;
            f_file_idx <= {1'b0, frag_idx} + 4'd6;   // 0..5 -> 6..11
            f_open_req <= 1'b1;
            st         <= A_OPEN;
        end else if (stop) begin
            free_mask  <= 2'b00;
            f_open_req <= 1'b0;
            f_xl_req   <= 1'b0;
            sd_req     <= 1'b0;
            st         <= A_IDLE;
        end else case (st)

        // ========================= 空闲 =========================
        A_IDLE: begin
            state_code <= 4'd0;
            bcnt       <= 10'd0;
        end

        // ==================== 打开文件 ====================
        A_OPEN: begin
            state_code <= 4'd1;
            f_open_req <= 1'b0;
            st         <= A_OPEN_W;
        end
        A_OPEN_W: begin
            state_code <= 4'd2;
            if (f_open_done) begin
                if (!f_found) begin
                    err <= 1'b1;
                    st  <= A_ERR;
                end else
                    st <= A_SEEK;
            end
        end

        // ==================== 翻译当前需要的扇区 ====================
        A_SEEK: begin
            state_code   <= 4'd3;
            f_xl_sec_idx <= need_sec;
            f_xl_req     <= 1'b1;
            st           <= A_SEEK_W;
        end
        A_SEEK_W: begin
            f_xl_req <= 1'b0;
            if (f_xl_valid) begin
                if (f_xl_err) begin
                    if (mode_data) begin
                        // data 区提前到头（文件比 data_len 短）：正常收尾
                        wr_remain <= 32'd0;
                        st        <= A_WAITPLY;
                    end else begin
                        err <= 1'b1;
                        st  <= A_ERR;
                    end
                end else begin
                    sd_addr <= f_xl_lba;
                    st      <= A_SREQ;
                end
            end
        end

        // ==================== 向仲裁器发起读 ====================
        A_SREQ: begin
            state_code <= 4'd4;
            sd_req     <= 1'b1;
            if (sd_grant) begin
                bcnt <= 10'd0;      // 换扇区，字节计数归零
                st   <= A_SRD;
            end
        end

        // ==================== 收一个扇区的字节 ====================
        A_SRD: begin
            state_code <= 4'd5;
            if (sd_valid) begin
                bcnt <= bcnt + 10'd1;
                // 扇区内偏移 >= need_skip 的字节才是真正要的
                if (bcnt >= {1'b0, need_skip}) begin
                    if (!mode_data) begin
                        // 喂给头解析器：值 + 该字节在文件内的偏移一起送过去
                        hp_stb  <= 1'b1;
                        hp_data <= sd_data;
                        hp_off  <= fetch_off;
                        fetch_off <= fetch_off + 32'd1;
                    end else if (rf_need != 10'd0) begin
                        // ★ rf_need != 0 这个守卫不能省 ★
                        //   跨扇区时本半区会在扇区中间填满，此时 rf_need 已经到 0。
                        //   若继续写，rf_idx 会在 511 之后回绕到 0，
                        //   把半区开头的字节覆盖掉 —— 播放出来就是一小段回声。
                        buf_waddr <= {rf_half, rf_idx};
                        buf_wdata <= sd_data;
                        buf_we    <= 1'b1;
                        rf_idx    <= rf_idx + 9'd1;
                        fetch_off <= fetch_off + 32'd1;
                        if (wr_remain != 32'd0) wr_remain <= wr_remain - 32'd1;
                        rf_need   <= rf_need - 10'd1;
                    end
                end
            end

            if (sd_end) begin
                sd_req <= 1'b0;
                if (!mode_data) begin
                    if (hdr_bad) begin
                        err <= 1'b1;
                        st  <= A_ERR;
                    end else if (hp == HP_DONE) begin
                        // 头解析完毕：切到数据模式。
                        // data_off / data_len 是解析器在【很多拍之前】就锁好的，
                        // 到这里早已稳定。
                        mode_data  <= 1'b1;
                        fetch_off  <= data_off;
                        wr_remain  <= data_len;
                        // ★ 播放长度必须在这里交给播放侧 ★
                        //   rd_remain 归播放侧那个 always 块独占驱动，
                        //   主状态机只能发 load_len 脉冲把值带过去，
                        //   直接写就是 multiple drivers。
                        //
                        //   也【不能】放在 play 那一拍初始化：play 到达时头还
                        //   没解析，data_len 还是 0，那样播放长度会是 0，
                        //   结果就是永远不出声。
                        load_len   <= 1'b1;
                        len_val    <= data_len;
                        rf_half    <= 1'b0;
                        rf_idx     <= 9'd0;
                        rf_need    <= (data_len >= 32'd512) ? 10'd512 : data_len[9:0];
                        st         <= A_SEEK;      // 立即预填半区 0
                    end else
                        st <= A_SEEK;              // 接着读下一个头扇区
                end else begin
                    // ---- 数据模式 ----
                    if (rf_need == 10'd0) begin
                        if (prefill) begin
                            if (rf_half == 1'b0) begin
                                // 半区 0 好了，预填半区 1
                                rf_half <= 1'b1;
                                rf_idx  <= 9'd0;
                                rf_need <= (wr_remain >= 32'd512) ? 10'd512 : wr_remain[9:0];
                                st      <= A_SEEK;
                            end else begin
                                // 两个半区都好了，开播
                                prefill    <= 1'b0;
                                free_mask  <= 2'b00;
                                start_play <= 1'b1;
                                st         <= A_WAITPLY;
                            end
                        end else begin
                            // 播放中途的补填，交差等下一次腾空
                            st <= A_WAITPLY;
                        end
                    end else
                        st <= A_SEEK;              // 本半区还没满，接着读
                end
            end
        end

        // ==================== 等播放侧腾出半区 ====================
        A_WAITPLY: begin
            state_code <= 4'd6;
            if ((free_mask != 2'b00) && (wr_remain != 32'd0)) begin
                // 有半区空着而且还有数据可填 -> 立刻补
                if (free_mask[0]) begin
                    rf_half   <= 1'b0;
                    free_mask <= {free_mask[1], 1'b0};
                end else begin
                    rf_half   <= 1'b1;
                    free_mask <= 2'b00;
                end
                rf_idx  <= 9'd0;
                rf_need <= (wr_remain >= 32'd512) ? 10'd512 : wr_remain[9:0];
                st      <= A_SEEK;
            end else if ((rd_remain == 32'd0) && (wr_remain == 32'd0)) begin
                playing <= 1'b0;
                done    <= 1'b1;
                st      <= A_IDLE;
            end
        end

        // ========================= 出错 =========================
        A_ERR: begin
            state_code <= 4'd7;
            playing    <= 1'b0;
        end

        default: st <= A_IDLE;
        endcase

        // ------------------------------------------------------------------
        // 腾空检测放在 case 之后：本拍刚腾出的半区一定被记上。
        //
        // 为什么这里能安全地"覆盖" case 里的赋值：一次填充通常只要几百 us，
        // 而一个半区能播 16ms —— 腾空事件很少和"正在兑现上一次腾空"
        // 撞在同一拍上。真撞上也不会丢，因为 free_mask 是 2 位位图，
        // 两个半区可以各记各的。
        //
        // ★★ 这里【不能】再要求 st == A_WAITPLY ★★
        //   播放侧现在【不再】被 st 门控（见下面播放侧那个 always 块），
        //   所以 rd_half 翻面可能发生在 FSM 正处于 A_SEEK/A_SRD 的时候。
        //   要是这里还把 st==A_WAITPLY 当条件，那几次腾空就【不会被记上】，
        //   free_mask 一直是 0 ⇒ FSM 永远等不到可填的半区 ⇒ 回填彻底停摆。
        //   （这两处是一对，只能同时改 —— 改了播放侧不改这里 = 死锁。）
        // ------------------------------------------------------------------
        rd_half_d <= rd_half;
        if (vacate_now && !prefill)
            free_mask[vacate_which] <= 1'b1;
    end
end

// ==================================================================
// [2/3] WAV 头解析器（独立 always 块，不用 task）
//   本块独占驱动：hp, hp_cnt, hp_cid, hp_csz, hp_skip, hdr_bad,
//                 fmt_audio/chan/rate/bits, data_off, data_len,
//                 strobe_div, rate_ok, fmt_ok
//
//   输入：hp_stb（单拍）+ hp_data（字节值）+ hp_off（该字节在文件内的偏移）
//         hp_rst（单拍，回到 HP_RIFF）
//
//   hp_off 是主状态机显式传进来的，所以 data_off = hp_off + 1 这一步
//   不依赖"读的是调用拍还是下一拍"的时序假设。
// ==================================================================
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hp        <= HP_RIFF;
        hp_cnt    <= 4'd0;
        hp_cid    <= 32'd0;
        hp_csz    <= 32'd0;
        hp_skip   <= 32'd0;
        hdr_bad   <= 1'b0;
        fmt_audio <= 16'd0;
        fmt_chan  <= 16'd1;
        fmt_rate  <= 32'd16000;
        fmt_bits  <= 16'd16;
        data_off  <= 32'd0;
        data_len  <= 32'd0;
        strobe_div<= 16'd6250;
        rate_ok   <= 1'b1;
        fmt_ok    <= 1'b0;
    end else if (hp_rst) begin
        hp        <= HP_RIFF;
        hp_cnt    <= 4'd0;
        hp_cid    <= 32'd0;
        hp_csz    <= 32'd0;
        hp_skip   <= 32'd0;
        hdr_bad   <= 1'b0;
        fmt_ok    <= 1'b0;
    end else if (hp_stb) begin
        case (hp)
        // ---------------- RIFF 头 12 字节 ----------------
        HP_RIFF: begin
            case (hp_cnt)
                4'd0 : if (hp_data != "R") hdr_bad <= 1'b1;
                4'd1 : if (hp_data != "I") hdr_bad <= 1'b1;
                4'd2 : if (hp_data != "F") hdr_bad <= 1'b1;
                4'd3 : if (hp_data != "F") hdr_bad <= 1'b1;
                // 4..7 是 RIFF 块长度，不信它，按实际 chunk 链走
                4'd8 : if (hp_data != "W") hdr_bad <= 1'b1;
                4'd9 : if (hp_data != "A") hdr_bad <= 1'b1;
                4'd10: if (hp_data != "V") hdr_bad <= 1'b1;
                4'd11: if (hp_data != "E") hdr_bad <= 1'b1;
                default: ;
            endcase
            if (hp_cnt == 4'd11) begin
                hp     <= HP_CID;
                hp_cnt <= 4'd0;
            end else
                hp_cnt <= hp_cnt + 4'd1;
        end

        // ---------------- chunk id 4 字节（左移拼，读出来是正序 ASCII）----
        HP_CID: begin
            hp_cid <= {hp_cid[23:0], hp_data};
            if (hp_cnt == 4'd3) begin
                hp     <= HP_CSZ;
                hp_cnt <= 4'd0;
            end else
                hp_cnt <= hp_cnt + 4'd1;
        end

        // ---------------- chunk size 4 字节（小端）----------------
        HP_CSZ: begin
            case (hp_cnt)
                4'd0: hp_csz[7:0]   <= hp_data;
                4'd1: hp_csz[15:8]  <= hp_data;
                4'd2: hp_csz[23:16] <= hp_data;
                4'd3: hp_csz[31:24] <= hp_data;
                default: ;
            endcase
            if (hp_cnt == 4'd3) begin
                hp_cnt <= 4'd0;
                if (hp_cid == "fmt ")
                    hp <= HP_FMT;
                else if (hp_cid == "data") begin
                    // 本拍处理的是 chunk size 的最后一字节，
                    // 下一个字节就是 data 载荷 -> 偏移 = hp_off + 1。
                    data_off <= hp_off + 32'd1;
                    data_len <= hp_csz;
                    hp       <= HP_DONE;
                end else begin
                    // 其它块整块跳过，长度按 RIFF 规则向上取偶
                    hp_skip <= hp_csz + {31'd0, hp_csz[0]};
                    hp      <= HP_SKIP;
                end
            end else
                hp_cnt <= hp_cnt + 4'd1;
        end

        // ---------------- fmt 块前 16 字节 ----------------
        HP_FMT: begin
            case (hp_cnt)
                4'd0 : fmt_audio[7:0]  <= hp_data;
                4'd1 : fmt_audio[15:8] <= hp_data;
                4'd2 : fmt_chan[7:0]   <= hp_data;
                4'd3 : fmt_chan[15:8]  <= hp_data;
                4'd4 : fmt_rate[7:0]   <= hp_data;
                4'd5 : fmt_rate[15:8]  <= hp_data;
                4'd6 : fmt_rate[23:16] <= hp_data;
                4'd7 : fmt_rate[31:24] <= hp_data;
                4'd14: fmt_bits[7:0]   <= hp_data;
                4'd15: begin
                    // ★ fmt_bits 的高字节和 fmt_ok 必须在同一拍一起算 ★
                    //   fmt_bits[15:8] 是这一拍才写进去的（非阻塞），
                    //   若在这里读 fmt_bits 整体，拿到的是上一拍的旧值。
                    //   直接拼 {hp_data, fmt_bits[7:0]} 就没有这个坑。
                    fmt_bits[15:8] <= hp_data;
                    fmt_ok <= (fmt_audio == 16'd1) && (fmt_chan == 16'd1) &&
                              ({hp_data, fmt_bits[7:0]} == 16'd16);
                    // fmt_rate 的高字节在 hp_cnt==7 就写完了，这里读到的是稳定值
                    strobe_div <= rate_div(fmt_rate);
                    rate_ok    <= rate_known(fmt_rate);
                end
                default: ;
            endcase
            if (hp_cnt == 4'd15) begin
                hp_cnt <= 4'd0;
                // fmt 块可能比 16 字节长（WAVE_FORMAT_EXTENSIBLE 是 40），
                // 多出来的按长度跳过
                if (hp_csz > 32'd16) begin
                    hp_skip <= hp_csz - 32'd16 + {31'd0, hp_csz[0]};
                    hp      <= HP_SKIP;
                end else
                    hp <= HP_CID;
            end else
                hp_cnt <= hp_cnt + 4'd1;
        end

        // ---------------- 跳过本块剩余字节 ----------------
        HP_SKIP: begin
            if (hp_skip <= 32'd1) begin
                hp_skip <= 32'd0;
                hp      <= HP_CID;
                hp_cnt  <= 4'd0;
            end else
                hp_skip <= hp_skip - 32'd1;
        end

        default: ;
        endcase
    end
end

// ==================================================================
// [3/3] 播放侧
//   本块独占驱动：rd_ph, rd_half, rd_idx, rd_remain, pcm, pcm_stb, strobe_cnt
//
//   按采样节拍从乒乓缓冲取 2 字节组一个样本，分【四个】相位。
//
//   ★★ 为什么必须是四个相位而不是三个（第二十一版修的 bug）★★
//
//     pcm_buf 是推断出来的【同步】RAM（`buf_rdata <= pcm_buf[buf_raddr]`），
//     而 buf_raddr 本身就是一个寄存器 ⇒ **地址寄存器"本拍"的值，
//     要到"下一拍"才成为 RAM 的输出**：
//
//         buf_rdata(第 n 拍) = pcm_buf[ buf_raddr 在第 n-1 拍的值 ]
//
//     ★ 这条关系在本工程里是【上板验证过】的，不是我推的：hud_overlay.v
//       里的 hud_rom_cjk 用的是同一个写法，它那段注释（"地址在本拍锁存、
//       下一拍出数据"）正是靠板上文字的对齐反推出来的，还专门警告
//       "再打一拍整个 HUD 层会比表盘晚一个像素、文字整体右移一列"。
//       字体渲染在板上是对的 ⇒ 这条 1 拍关系成立。★
//
//     旧版只有三个相位：ph0 置地址、ph1 锁"低字节"、ph2 锁"高字节"。
//     按上面那条关系，ph1 锁到的其实是【上一个地址】的数据，ph2 锁到的
//     才是 rd_idx 那个字节。于是组出来的样本是
//         低字节 = mem[rd_idx - 1]   ← 上一个字节
//         高字节 = mem[rd_idx]       ← 本该是低字节的那个
//     也就是**整个样本错开了一个字节**。对 16bit PCM 而言，这等于把高字节
//     换成噪声、低字节换成上一拍的粗值 —— 放出来是一片刺耳的电流声，
//     而不是语音。
//
//   ★ 探针上看到的正是它的指纹 ★
//     D5（max|样本| >> 12）六页全读到 **8**。16 位有符号里 8 只可能来自
//     0x8000 这一个值。离线把六个 data 块按各种字节对齐都算过：
//       对齐正确 -> 4 / 4 / 3 / 7 / 7 / 6（六页互不相同）
//       错开一个字节 -> 六页**全都是 8**
//     板上的读数只和后者相符 ⇒ 数据本身没错，是取字节的时候错了一位。
//
//   四个相位（每拍只干一件事，前两拍喂地址、后两拍收数据）：
//     ph0: raddr <- rd_idx         （地址进寄存器；它的数据下一拍才出来）
//     ph1: raddr <- rd_idx + 1
//     ph2: 低字节 <- buf_rdata     （= mem[rd_idx]）
//     ph3: 高字节 <- buf_rdata     （= mem[rd_idx + 1]）
//          发 pcm_stb，指针 +2
//   ★ 前两拍不能省、也不能并成一拍：少任何一拍都会退回到"错开一个字节"。
//     16kHz 下四个相位占 4/6250 个采样周期，写侧完全不受影响。★
// ==================================================================
// ★ 第二十五版新增的安全闸（用法见下面那个 always 块的第二段注释）★
//   fill_busy   = FSM 正处于"往乒乓缓冲写字节"的状态里
//   fill_danger = 它要写的正是播放侧此刻在读的那个半区
//                 （正常情况恒为假 —— 填充的是刚腾出来的另一半；
//                  只有播放侧跑赢填充侧这种异常才会命中）
wire fill_busy   = (st == A_SEEK) || (st == A_SEEK_W) ||
                   (st == A_SREQ) || (st == A_SRD);
wire fill_danger = fill_busy && (rf_half == rd_half);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_ph      <= 2'd0;
        rd_half    <= 1'b0;
        rd_idx     <= 9'd0;
        rd_remain  <= 32'd0;
        pcm        <= 16'd0;
        pcm_stb    <= 1'b0;
        strobe_cnt <= 16'd0;
    end else begin
        pcm_stb <= 1'b0;

        if (!sd_init_done || stop || play || (st == A_IDLE) || (st == A_ERR)) begin
            // 停止 / 复位 / 换段 / 出错：指针归零，等下一次 start_play
            strobe_cnt <= 16'd0;
            rd_ph      <= 2'd0;
            rd_half    <= 1'b0;
            rd_idx     <= 9'd0;
            rd_remain  <= 32'd0;
        end else if (load_len) begin
            // 头解析完毕，主状态机把这一段的总长度交过来
            rd_remain <= len_val;
        end else if (start_play) begin
            // 两个半区都填好了，从半区 0 开头起播
            strobe_cnt <= 16'd0;
            rd_ph      <= 2'd0;
            rd_half    <= 1'b0;
            rd_idx     <= 9'd0;
        // ==============================================================
        // ★★ 第二十五版：这里【不再】用 `st == A_WAITPLY` 做门控 ★★
        //
        // 【为什么必须改】
        //   一个半区能播 16ms，而回填时必须离开 A_WAITPLY 去读一个扇区。
        //   原来的门控 = **每次回填都把播放整个冻住**。
        //   作者注释里估的是"一次填充只要约 340us"，但真实 SD 卡的读延迟
        //   会在毫秒级突刺，而且会随时间缓慢漂移 ⇒ 板上听到的正是
        //   「不规则断续」＋「整个声音缓慢地一起一伏」（有声占比在慢慢变）。
        //   这等于把乒乓缓冲的意义整个抵消掉了 —— 乒乓本来就是为
        //   "填一个半区的同时继续播另一个半区"而存在的。
        //
        // 【改成什么】  !prefill && !fill_danger
        //   !prefill      ⇒ 两个半区都预填好了才允许播。
        //                    prefill 覆盖"开门/解头/预填"全过程，而这段时间
        //                    rd_remain 已经有值了（load_len 在预填之前就发了），
        //                    所以少了这一项，播放会先跑起来去读还没填的缓冲。
        //   !fill_danger  ⇒ 安全闸：只在 FSM 正写【播放侧正在读的那个半区】
        //                    时才停。正常情况下填充的是"刚腾出来的另一半"，
        //                    恒为假 ⇒ 一次都不会停。
        //                    只有播放侧跑赢填充侧（填充慢到超过 16ms，异常）
        //                    才会命中，那时停在 rd_idx=0 处、等填完再读 ⇒
        //                    **绝不会读到正在被写的半区**（那会放出一片垃圾
        //                    噪声），而且填完回到 A_WAITPLY 就自动放开 ⇒
        //                    不会死锁。
        // ==============================================================
        end else if (!prefill && !fill_danger) begin
            // ---- 采样节拍 ----
            if (strobe_cnt == strobe_div - 16'd1)
                strobe_cnt <= 16'd0;
            else
                strobe_cnt <= strobe_cnt + 16'd1;

            case (rd_ph)
            2'd0: begin
                // 还有整字节可播，且节拍到点 -> 起一个样本，先把地址喂进寄存器
                if (sample_tick && (rd_remain > 32'd1)) begin
                    buf_raddr <= {rd_half, rd_idx};
                    rd_ph     <= 2'd1;
                end
            end
            2'd1: begin
                // 第二个地址。★ 这一拍【不能】去锁 buf_rdata ★ ——
                // 此刻 buf_rdata 还对应上一个样本留下的地址。
                buf_raddr <= {rd_half, (rd_idx + 9'd1)};
                rd_ph     <= 2'd2;
            end
            2'd2: begin
                pcm[7:0] <= buf_rdata;      // = mem[rd_idx]，低字节
                rd_ph    <= 2'd3;
            end
            2'd3: begin
                pcm[15:8] <= buf_rdata;     // = mem[rd_idx+1]，高字节
                pcm_stb   <= 1'b1;
                rd_remain <= rd_remain - 32'd2;
                // 半区内偏移 +2；走到 510 就翻半区（最后一个是 510+511）
                if (rd_idx == 9'd510) begin
                    rd_idx  <= 9'd0;
                    rd_half <= ~rd_half;
                end else
                    rd_idx <= rd_idx + 9'd2;
                rd_ph <= 2'd0;
            end
            default: rd_ph <= 2'd0;
            endcase
        end
    end
end

endmodule
