// ============================================================
// top.v — 压力容器多媒体播放系统 顶层（HX4S20C 板）
//
// ============================================================
// 【这版和上一版的根本区别】
// ============================================================
//   上一版：选题一(基础1-4) + 选题二(工业 HUD)，两边靠"节拍统一"硬凑在一起 ——
//           翻页的唯一来源是 img_changed（"屏幕刚换成一张新图"），页号是图片
//           序号的纯函数，两套定时器只能靠 SW4 去对表。
//
//   这一版：比赛主题是【多媒体播放系统】，改成【压力容器】演示。
//           disp_page 是主人，图跟着页走（页变 -> 立刻切界面；同时去读第 N 张图）。
//           TF 卡除了六张底图之外还流式播音频（切页时的播报）。
//           详见 src/hud/hud_top.v 的"页与图彻底解耦"一节。
//
// ============================================================
// 【数据链路】
// ============================================================
//   TF卡 --SPI--> sd_card_top --+--> [sd_arbiter 按扇区仲裁] --+--> bmp_read
//                               |       (音频绝对优先, 3.2%)    |     -> 写FIFO
//                               |                               +--> audio_sd_reader
//                               |                                     -> audio_fifo
//                               |                                        -> hdmi_audio_*
//                               +--> SDRAM 双缓冲 --> video_delay --> hud_top --> HDMI
//
//   ★ sd_card_top 从 sd_card_bmp 里搬出来了 ★
//     旧版 SD 控制器被"读图"独占，音频就没有通路。现在由 sd_arbiter 按
//     【一个 512B 扇区】的粒度仲裁给两个请求方。粒度的理由见 sd_arbiter.v 头注释。
//
// ============================================================
// 【按键】—— 端口名一个都没改（.adc 一行都不用动），但语义全变了
// ============================================================
//   ★ 注意端口名和物理按键的【错位】，这是历史遗留，改端口名就要动 .adc ★
//
//     端口 rst_n  = A2 = 物理 KEY1  -> 软复位（回总览页）  【不再是硬复位】
//     端口 key1   = B2 = 物理 KEY2  -> 翻页
//     端口 key3   = B1 = 物理 KEY3  -> 屏幕亮度 8 档
//     端口 key2   = C1 = 物理 KEY4  -> 轮播 / 手动 切换
//
//   ★ K1(A2) 为什么不再接复位 ★
//     A2 一接 rst_n，按一下整个 FPGA 重启：SD 卡重新初始化、音频 FIFO 清空、
//     画面黑一秒多。演示时"按一下回主页"变成"按一下黑屏"，而且和
//     "回到主界面"这个意图根本不是一回事。现在 A2 只接 hud_keys。
//     ★ 代价：板子上不再有任何硬复位按键，出问题只能断电重上电。已确认接受。★
//
// 【上电复位】改成内部产生（见下面 POR 段）：startup_pulse 用 clk 计满 20ms。
//   ★ 只用延时，【不接任何 PLL 的 lock】★
//     曾经把 PLL_HDMI_AUDIO 的 extlock 接进复位路径，被 TD 按常量折叠，
//     整个设计被优化成空网表（#lut 7585 -> 165），而且日志毫无报错。
//     原因和现象详见下面 POR 段的 ★★★ 说明。
//
// ============================================================
// 【拨动开关】全部在 hud_top 里同步消抖（video_clk 域），本模块用 o_sw_sync
//   SW1(C8) 关闭报警声（界面不关）   SW2(C7) 从报警界面回到正常界面
//   SW3(C6) 强制进报警界面           SW4(C5) 静音 TF 卡播报音频
//
// ============================================================
// 【时钟域】
//   sd_card_clk 100MHz / ext_mem_clk 125MHz / ext_mem_clk_sft 125MHz@180°
//   video_clk 25MHz / hdmi_5x_clk 125MHz / audio_mclk 12.295082MHz
// ============================================================
module top(
    input                       clk,               // 50MHz 板上晶振
    input                       rst_n,             // ★ A2 = 物理 KEY1：软复位（回总览）
    input                       key1,              // ★ B2 = 物理 KEY2：翻页
    input                       key2,              // ★ C1 = 物理 KEY4：轮播/手动
    input                       key3,              // ★ B1 = 物理 KEY3：亮度
    input  [3:0]                sw,                // 拨动开关 SW1-4 (C8/C7/C6/C5)
    output                      buzzer,            // 蜂鸣器 (H11)
    output [7:0]                seg_sel,           // 8 位数码管位选
    output [7:0]                seg_data,          // 8 位数码管段选 + DP
    output                      vga_out_hs,
    output                      vga_out_vs,
    output [11:0]               vga_data,
    //HDMI
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,
    //HDMI DDC (EDID读取, HDMI1.4b音频核心需要)
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,
    output                      sd_ncs,            //SD card chip select (SPI mode)
    output                      sd_dclk,           //SD card clock
    output                      sd_mosi,           //SD card controller data output
    input                       sd_miso            //SD card controller data input
);

parameter MEM_DATA_BITS         = 32  ;            //external memory user interface data width
parameter ADDR_BITS             = 21  ;            //external memory user interface address width
parameter BUSRT_BITS            = 10  ;            //external memory user interface burst width

wire                            vga_out_de;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire                            read_req;
wire                            read_req_ack;
wire                            read_en;
wire                            write_en;
wire                            write_req;
wire                            write_req_ack;
wire                            sd_card_clk;       //SD card controller clock
wire                            ext_mem_clk;       //external memory clock
wire                            ext_mem_clk_sft;

wire                            video_clk;         //video pixel clock
wire                            hdmi_5x_clk;
// ★ audio_mclk 必须在【例化 audio_fifo 之前】声明 ★
//   它的例化在前、这段声明在后，原来 TD 报
//   HDL-7225 CRITICAL-WARNING: 'audio_mclk' is already implicitly declared。
//   隐式建的是一根 1bit wire，虽然 PLL 输出本来就是 1bit 恰好没出事，
//   但这是撞运气，必须显式提前声明。（下面的 基础3 段不再重复声明。）
wire                            audio_mclk;        // 12.295082MHz 音频主时钟
wire                            hs;
wire                            vs;
wire                            de;
wire [23:0]                     vout_data_raw;     // video_delay 原始输出
wire [23:0]                     vout_data;         // 送 HUD 的底层像素
wire [3:0]                      state_code;        // sd_card_clk 域
reg  [3:0]                      state_code_v1, state_code_v2;

// HUD 送出来的数码管显示内容（video_clk 域）+ 报警电平
wire [31:0]                     hud_seg_dig;
wire [7:0]                      hud_seg_dp;
wire                            hud_seg_tog;
wire                            hud_alarm;         // 已被 SW1 门控（消音只影响声音）

wire                            video_read_req;
wire                            video_read_req_ack;
wire                            video_read_en;
wire [31:0]                     video_read_data;
wire                            sd_card_write_en;
wire [31:0]                     sd_card_write_data;
wire                            sd_card_write_req;
wire                            sd_card_write_req_ack;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS - 1 : 0]Sdr_rd_dout;

wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS - 1 : 0]App_wr_din;
wire [3:0] App_wr_dm;

// ================= 双缓冲（SDRAM 帧缓存）=================
wire                            frame_sel;          // 写域帧号
wire                            frame_sel_v;        // 读域同步后帧号
wire                            frame_done;         // bmp_read.state_code 4->1 单拍脉冲(帧完成)
wire [23:0]                     write_base;         // 写基地址(非显示帧)
wire [23:0]                     read_base;          // 读基地址(显示帧)
reg                             frame_sel_v1, frame_sel_v2;

// ---- 帧完成判据：【已撤回原样，勿再改】 ----
// 曾试图改成 frame_fifo_write.write_finish（等写 FIFO 真正排空），理由是原来那句
// 只表示"最后一个像素刚进 FIFO"。理论更严谨，但实测【整屏雪花】：
//   write_finish 挂在"写 FIFO 排空"上，与本工程的找图流程(bmp_read)错位，
//   frame_sel 的翻转时机和 bmp_read 起新帧的时刻对不上，
//   结果写侧锁存到的 write_base 与读侧的 read_base 指向同一个缓冲区
//   -> 显示端读的是一块没写过的 SDRAM -> 纯雪花。
// 原判据 (state_code 4->1) 挂在"上一帧读完 -> 开始找下一张图"上，与找图流程同步，
// 是这套结构能工作的前提。要再优化必须连同启动时序一起改，不能只换判据。
//
// ★ 用它的 state_code_d 块在【POR 段之后】（那里 por_rst_n 才声明），
//   不要看到这里没写就以为漏了 —— 下方 "帧完成判据实现" 一段。★

// =====================================================================
// 上电复位 (POR)
//
//   只有一个条件：startup_pulse 用 clk(50MHz) 计满 20ms。
//   20ms 对 sys_pll / video_pll / PLL_HDMI_AUDIO 三个 PLL 的锁定时间
//   （通常几十 us）有几百倍余量。
//
//   por_done 是 clk(50MHz) 域的单拍脉冲，por_rst_r 把它锁成电平。
//
//   ★★★ 千万不要把 PLL 的 extlock(audio_pll_lock) 接回复位路径 ★★★
//     曾经写成：
//         always @(posedge clk or negedge audio_pll_lock)
//             if (!audio_pll_lock) por_rst_r <= 1'b0;
//             else if (por_done)   por_rst_r <= 1'b1;
//         assign rst_all = ~por_rst_n | ~audio_pll_lock;
//     结果是【整颗芯片被掏空】，但 TD 一声不吭、照样跑完 bitgen：
//       综合 Optimize Iteratively 13501 实例 -> 1006，
//       #lut 7585 -> 165、#reg 4942 -> 413、#bram 31 -> 2、#dsp 13 -> 0，
//       时钟表里 clk 扇出 0，audio_mclk 整行消失。
//     原因：PLL 是 TD 的 phy 宏，extlock 这种宏输出在 RTL 优化阶段会被
//     按常量（0）处理。于是 !audio_pll_lock 恒真 -> por_rst_r 恒 0 ->
//     por_rst_n 恒 0/rst_all 恒 1 -> 全身异步复位一直按着 -> 所有触发器
//     和它们的组合逻辑全部被常量传播掉，只剩不会消失的硬核（SDRAM IP、
//     PLL、HDMI PHY、LVDS lane）和 I/O 环。
//     ★ 症状是"时序报告干干净净、资源几乎为零"，极具欺骗性：
//       报告里 SWNS 3.575ns / 0 violated 是拿一个几乎空的网表测出来的。★
//     同理：`por_rst_n = por_rst_r & audio_pll_lock` 这种"与进复位"的写法
//     一样会被常量折叠成 0，同样是雷。**这个信号不要出现在复位路径里**，
//     所以下面连 PLL 的 .extlock() 都不接（和 sys_pll/video_pll 一致）。
//
//   ★ 已知的简化 ★
//     本模块内部所有 always 块用 por_rst_n 当异步复位，而释放边沿相对
//     video_clk / sd_card_clk 是异步的。严格来说每个域该再各加一级
//     "复位同步器"（异步置位、同步释放）。没加是因为：
//       a) por_rst_n 从 0 到 1 只发生一次（上电后 20ms），
//       b) 释放时刻离任何一个时钟沿都远了去了，实际不会被采到亚稳。
//     旧版直接用外部 rst_n 也是同样的情况，不是本次引入的新风险。
//     真要严谨就每个域加一个 2FF 复位同步器，代价是 6 个触发器。
//
//   ★ 端口 rst_n(A2) 从此【只是按键】★，见文件头"按键"一节。
// =====================================================================
wire por_done;
startup_pulse #(.CNT_MAX(20'd1_000_000)) u_por_pulse(   // 50MHz * 20ms
    .I_clk                      (clk                      ),
    .I_rst                      (1'b0                     ),
    .O_pulse                    (por_done                 )
);

reg por_rst_r;
always @(posedge clk) begin
    if (por_done) por_rst_r <= 1'b1;             // 20ms 到 -> 放开
end
wire por_rst_n = por_rst_r;

wire rst_all;
assign rst_all = ~por_rst_n;

// =====================================================================
// 帧完成判据实现（判据本身的说明见上面"帧完成判据"一段）
//
// ★ 位置说明 ★
//   这段本来写在文件更靠前的地方，但那里 por_rst_n 还没声明，
//   Verilog-2001 会先隐式建一根 1bit wire，TD 报
//   HDL-5373 'por_rst_n' is used before its declaration。
//   1bit 恰好是它的正确位宽，功能上歪打正着，但规范上必须先声明后用，
//   所以整段挪到 POR 段之后。
// =====================================================================
reg [3:0] state_code_d;               // state_code 延迟一拍，用于取 4->1 跳变

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) state_code_d <= 4'd0;
    else            state_code_d <= state_code;
end

assign frame_done = (state_code == 4'd1) && (state_code_d == 4'd4);

// =====================================================================
// 【页 -> 图】跨时钟域：video_clk(25MHz) -> sd_card_clk(100MHz)
//
//   o_img_tog  : 页号每变一次翻转一次的 toggle（不是单拍脉冲）
//   o_img_index: 与 toggle 同步变化的页号
//
//   ★ 为什么必须用 toggle，不能直接送单拍脉冲 ★
//     hud_data_gen 的 page_chg 是 video_clk 域的【单拍】脉冲（40ns）。
//     直接喂两级同步器，理论上可能整个落进建立/保持窗口被吞掉，
//     表现就是"偶尔按一下 K2 不翻图"。转成 toggle 之后，
//     电平宽度 = 半个变化周期，同步器不可能漏。
//
//   ★ 数据为什么可以跟着 toggle 一起走 3FF ★
//     hud_data_gen:  disp_page 在边沿 N 变 -> o_page_chg 在 N+1 拉高一拍
//                    -> hud_top 的 img_tog_r 在 N+2 才翻转。
//     也就是说 toggle 变化时，o_img_index 已经稳了 2 个 video_clk（80ns）。
//     sd_card_clk 侧把数据滤 2 级只要 20ns，80ns 有 4 倍余量。
//     这里 data / toggle 都打 3 级，在边沿检测那一拍采 data 是安全的。
//     ★ 余量只有 2 拍，别再在这条路上插一级寄存器 ★
// =====================================================================
wire        img_tog_v;           // 来自 hud_top
wire [2:0]  img_idx_v;           // 来自 hud_top（= disp_page）
wire [3:0]  sw_v;                // 来自 hud_top（已同步消抖的开关）

reg [2:0] img_tog_s;             // 3FF 同步 toggle
reg [2:0] img_idx_s;             // 3FF 同步数据（与 toggle 同深度）

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        img_tog_s <= 3'd0;
        img_idx_s <= 3'd0;
    end else begin
        img_tog_s <= {img_tog_s[1:0], img_tog_v};
        img_idx_s <= {img_idx_s[1:0], img_idx_v};
    end
end

// 用第 1/2 级之间取沿：那一拍 img_idx_s[1] 正好是新的页号
wire        page_chg_sd = img_tog_s[2] ^ img_tog_s[1];   // 单拍
wire [2:0]  img_idx_sd  = img_idx_s[1];

// 报警页（页 5）是特例：底图照读（卡图 5），但【不播切换播报音频】，
// 那一页只有警报声。
wire        is_alarm_page = (img_idx_sd == 3'd5);

// =====================================================================
// SD 卡控制器：从 sd_card_bmp 里搬出来，改由 sd_arbiter 共享
// =====================================================================
wire        sd_init_done;
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [7:0]  sd_sec_read_data;
wire        sd_sec_read_data_valid;
wire        sd_sec_read_end;

sd_card_top sd_card_top_m0(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .SD_nCS                     (sd_ncs                  ),
    .SD_DCLK                    (sd_dclk                 ),
    .SD_MOSI                    (sd_mosi                 ),
    .SD_MISO                    (sd_miso                 ),
    .sd_init_done               (sd_init_done            ),
    .sd_sec_read                (sd_sec_read             ),
    .sd_sec_read_addr           (sd_sec_read_addr        ),
    .sd_sec_read_data           (sd_sec_read_data        ),
    .sd_sec_read_data_valid     (sd_sec_read_data_valid  ),
    .sd_sec_read_end            (sd_sec_read_end         ),
    // 本工程只读不写，写口全接 0（不接的话会浮空，综合会报警告）
    .sd_sec_write               (1'b0                    ),
    .sd_sec_write_addr          (32'd0                   ),
    .sd_sec_write_data          (8'd0                    ),
    .sd_sec_write_data_req      (                        ),
    .sd_sec_write_end           (                        )
);

// ---- 两侧请求方 -> 仲裁器 ----
wire        bmp_req,   aud_req;
wire [31:0] bmp_addr,  aud_addr;
wire        bmp_grant, aud_grant;
wire        bmp_rdata_valid, aud_rdata_valid;
wire        bmp_rend,        aud_rend;

sd_arbiter u_sd_arb(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .sd_init_done               (sd_init_done            ),
    .bmp_req                    (bmp_req                 ),
    .bmp_addr                   (bmp_addr                ),
    .bmp_grant                  (bmp_grant               ),
    .bmp_rdata_valid            (bmp_rdata_valid         ),
    .bmp_rend                   (bmp_rend                ),
    .aud_req                    (aud_req                 ),
    .aud_addr                   (aud_addr                ),
    .aud_grant                  (aud_grant               ),
    .aud_rdata_valid            (aud_rdata_valid         ),
    .aud_rend                   (aud_rend                ),
    .sd_sec_read                (sd_sec_read             ),
    .sd_sec_read_addr           (sd_sec_read_addr        ),
    .sd_sec_read_data           (sd_sec_read_data        ),
    .sd_sec_read_data_valid     (sd_sec_read_data_valid  ),
    .sd_sec_read_end            (sd_sec_read_end         )
);

// ---- 取图请求 ----
// 两个来源，或成一拍：
//   1) sd_init_done 上升沿自动读第一张（上电就出图，不用按任何键）
//   2) 页变化
// ★ 注意读图请求【报警页也要发】★ 报警界面也有底图（卡图 5），
//   和音频的"报警页不播报"不是一回事。
reg  sd_init_d;

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) sd_init_d <= 1'b0;
    else            sd_init_d <= sd_init_done;
end

wire first_find = sd_init_done & ~sd_init_d;
wire bmp_find   = first_find | page_chg_sd;

wire        bmp_ready;
sd_card_bmp sd_card_bmp_m0(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .find                       (bmp_find                ),
    .img_index                  (img_idx_sd              ),
    .sd_init_done               (sd_init_done            ),
    .state_code                 (state_code              ),
    .bmp_width                  (16'd640                  ),
    .write_req                  (sd_card_write_req       ),
    .write_req_ack              (sd_card_write_req_ack   ),
    .write_en                   (sd_card_write_en        ),
    .write_data                 (sd_card_write_data      ),
    .bmp_ready                  (bmp_ready               ),
    .sd_sec_read                (bmp_req                 ),
    .sd_sec_read_addr           (bmp_addr                ),
    .sd_sec_read_data           (sd_sec_read_data        ),
    .sd_sec_read_data_valid     (bmp_rdata_valid         ),
    .sd_sec_read_end            (bmp_rend                )
);

// =====================================================================
// 音频通路：audio_sd_reader -> audio_fifo -> hdmi_audio_tone_i2s_64fs
//
//   切页时播一小段（1 秒）TF 卡音频。报警页不播报，只报警。
//   ★ 数据总线 sd_sec_read_data 是共用的，只有 valid/end 按授权方二分 ★
//     所以两边都把同一根 sd_sec_read_data 接进 rdata 端口，靠 rdata_valid
//     区分"这是不是给我的"。
// =====================================================================
reg  pcm_run;                    // 1 = 上一次切页是"要播报"的页

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n)      pcm_run <= 1'b0;
    else if (page_chg_sd) pcm_run <= ~is_alarm_page;
end

wire        aud_play = page_chg_sd & ~is_alarm_page;
wire        aud_stop = page_chg_sd &  is_alarm_page;

wire        fifo_flush, fifo_wr_en, fifo_low;
wire [15:0] fifo_wr_data;
wire [15:0] pcm_data;
wire        pcm_req;

audio_sd_reader #(
    .AUDIO_BASE                 (32'd32768                ),
    .FRAG_STRIDE                (32'd4096                 )
) u_aud_reader(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .sd_init_done               (sd_init_done            ),
    .play                       (aud_play                ),
    .frag_idx                   (img_idx_sd              ),
    .stop                       (aud_stop                ),
    .fifo_low                   (fifo_low                ),
    .fifo_wr_en                 (fifo_wr_en              ),
    .fifo_wr_data               (fifo_wr_data            ),
    .fifo_flush                 (fifo_flush              ),
    .req                        (aud_req                 ),
    .addr                       (aud_addr                ),
    .rdata_valid                (aud_rdata_valid         ),
    .rdata                      (sd_sec_read_data        ),
    .rend                       (aud_rend                )
);

// 4096 个样本 = 8 KiB，低水位 2048 个样本 = 4 KiB ≈ 43ms 缓冲。
// 深度推算见 audio_fifo.v / audio_sd_reader.v 文件头。
audio_fifo #(
    .AW                         (12                      ),
    .LOW_WATER                  (13'd2048                )
) u_audio_fifo(
    .wclk                       (sd_card_clk             ),
    .wrst_n                     (por_rst_n               ),
    .flush                      (fifo_flush              ),
    .wr_en                      (fifo_wr_en              ),
    .wr_data                    (fifo_wr_data            ),
    .wr_full                    (                        ),
    .wr_low                     (fifo_low                ),
    .wr_level                   (                        ),
    .rclk                       (audio_mclk              ),
    .rrst_n                     (por_rst_n               ),
    .rd_pulse                   (pcm_req                 ),
    .rd_data                    (pcm_data                ),
    .rd_valid                   (                        )
);

// =====================================================================
// 音频模式：三选一（详见 hdmi_audio_tone_i2s_64fs.v 文件头）
//   报警优先 > TF 卡播报 > 静音
//
//   三项都在 video_clk 域里算，模式信号本身是干净的寄存器输出，
//   再由 hdmi_audio_tone_i2s_64fs 内部 2FF 同步到 audio_mclk 域。
//   （不要在这里直接把 sd 域的 pcm_run 和 video 域的 hud_alarm_r 混着选，
//     那才是真正的混域。）
//
//   hud_alarm 已经在 hud_top 里被 SW1 门控过了（alarm_on & ~sw[0]），
//   所以这里不用再管 SW1；SW4 管的是 TF 卡播报，单独一项。
// =====================================================================
localparam M_MUTE  = 2'd0;
localparam M_PCM   = 2'd1;
localparam M_ALARM = 2'd2;

// hud_alarm 是 hud_data_gen 的【组合】输出（比较器 + 与门译码），
// 直接跨域可能采到译码毛刺，所以先在 video 域寄存一拍再送出去。
reg hud_alarm_r;
always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) hud_alarm_r <= 1'b0;
    else            hud_alarm_r <= hud_alarm;
end

// pcm_run 从 sd 域同步到 video 域（电平量，2FF 足够）
reg [1:0] pcm_run_s;
always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) pcm_run_s <= 2'd0;
    else            pcm_run_s <= {pcm_run_s[0], pcm_run};
end
wire pcm_run_v = pcm_run_s[1];

wire [1:0] audio_mode = hud_alarm_r            ? M_ALARM   // 报警界面 -> 只报警
                      : (pcm_run_v & ~sw_v[3]) ? M_PCM     // 播报中 + SW4 未静音
                      :                          M_MUTE;

// =====================================================================
// 双缓冲帧切换 (sd_card_clk 域)
// =====================================================================
dbl_buf_ctl #(.ADDR_BITS(21), .FRAME_WORDS(307200)) dbl_buf_m0(
    .clk           (sd_card_clk),
    .rst_n         (por_rst_n),
    .frame_done    (frame_done),
    .frame_sel     (frame_sel)
);

dbl_buf_addr #(.FRAME_WORDS(307200)) dbl_buf_addr_m0(
    .frame_sel     (frame_sel),
    .frame_sel_v   (frame_sel_v),
    .write_base    (write_base),
    .read_base     (read_base)
);

// frame_sel 跨时钟域: 写域(sd_card_clk) -> 读域(video_clk) 两级触发器同步
always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        frame_sel_v1 <= 1'b0;
        frame_sel_v2 <= 1'b0;
    end else begin
        frame_sel_v1 <= frame_sel;
        frame_sel_v2 <= frame_sel_v1;
    end
end
assign frame_sel_v = frame_sel_v2;

// state_code 跨时钟域: sd_card_clk(100MHz) -> video_clk(25MHz) 两级同步。
// 只给数码管显示用（上板诊断）。它是人手速度的量，2 级同步足够。
always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        state_code_v1 <= 4'd0;
        state_code_v2 <= 4'd0;
    end else begin
        state_code_v1 <= state_code;
        state_code_v2 <= state_code_v1;
    end
end

// ================= 基础3: HDMI 1.4b 内嵌音频信号 =================
// （audio_mclk 在本文件顶部已经声明，这里不再重复 —— 重复声明 TD 会报
//   HDL-7225，而且真正生效的是先出现的那一根。）
wire                            audio_i2s_bclk;     // I2S位时钟(64fs=3.075MHz)
wire                            audio_i2s_lrck;     // I2S帧时钟(48kHz)
wire                            audio_i2s_dout;     // I2S串行数据
wire                            audio_valid;         // 音频采样有效
wire [23:0]                     audio_left_data;    // 左声道24bit
wire [23:0]                     audio_right_data;   // 右声道24bit
wire                            acr_valid;           // ACR有效
wire [19:0]                     acr_cts;             // ACR CTS值
wire [19:0]                     acr_n;               // ACR N值
// AXIS视频流(RGB->AXIS转换)
wire                            axis_s_user;
wire                            axis_s_valid;
wire                            axis_s_last;
wire [23:0]                     axis_s_data;
wire                            axis_s_ready;
// EDID
wire                            edid_trig;
wire                            edid_valid;
wire [7:0]                      edid_data;
// TMDS 10bit数据(HDMI核心->PHY)
wire [9:0]                      tmds_ch0_data;
wire [9:0]                      tmds_ch1_data;
wire [9:0]                      tmds_ch2_data;
wire [9:0]                      tmds_clk_data;

// ================= HUD 叠加（压力容器六界面）=================
// 插在 video_delay 之后、AXIS/HDMI 之前：像素坐标 -> 面板/表盘/数字/报警 -> 混合输出
// 内部自带 6 拍流水延迟，hs/vs/de 同步延迟，不破坏原有时序关系。
wire        hud_hs;
wire        hud_vs;
wire        hud_de;
wire [23:0] hud_rgb;

hud_top #(.CLK_HZ(25000000)) u_hud(
    .clk          (video_clk),
    .rst_n        (por_rst_n),
    // ★ 端口名和物理按键的错位见文件头"按键"一节 ★
    .key1         (rst_n),            // A2 = 物理 KEY1 -> 软复位（回总览页）
    .key2         (key1),             // B2 = 物理 KEY2 -> 翻页
    .key3         (key3),             // B1 = 物理 KEY3 -> 亮度
    .key4         (key2),             // C1 = 物理 KEY4 -> 轮播/手动
    .sw           (sw),
    .state_code   (state_code_v2),
    .hs           (hs),
    .vs           (vs),
    .de           (de),
    .vout_data    (vout_data),
    .o_hs         (hud_hs),
    .o_vs         (hud_vs),
    .o_de         (hud_de),
    .o_rgb        (hud_rgb),
    .o_seg_dig    (hud_seg_dig),
    .o_seg_dp     (hud_seg_dp),
    .o_seg_tog    (hud_seg_tog),
    .o_alarm      (hud_alarm),        // 已被 SW1 门控（只影响声音，不影响界面）
    .o_img_tog    (img_tog_v),        // 页变化 toggle -> 跨到 sd 域取图 + 播报
    .o_img_index  (img_idx_v),        // 当前页号 = 要读的图序号
    .o_sw_sync    (sw_v)
);

assign vga_out_hs = hud_hs;
assign vga_out_vs = hud_vs;
assign vga_out_de = hud_de;
assign vga_data = {hud_rgb[23:20],hud_rgb[15:12],hud_rgb[7:4]};

//generate SD card controller clock and SDRAM controller clock
sys_pll sys_pll_m0(
    .refclk                     (clk),
    .clk0_out                   (sd_card_clk),
    .clk1_out                   (ext_mem_clk),
    .clk2_out                   (ext_mem_clk_sft),
    .reset                      (1'b0)
);

//generate video pixel clock
video_pll video_pll_m0(
    .refclk                     (clk),
    .clk0_out                   (video_clk),
    .clk1_out                   (hdmi_5x_clk),
    .reset                      (1'b0)
);

//基础3: 精确 12.295082MHz 音频主时钟 PLL (clk2_out, VCO=75MHz/61分频)
//   ★ 这里的 .extlock() 必须【悬空】★
//   它曾经用来做上电复位的条件之一，结果 TD 的 phy 宏输出在优化阶段被按
//   常量 0 处理，把整个设计常量传播成空网表。详见上面 POR 段的 ★★★ 说明。
//   复位现在只靠 startup_pulse 的 20ms 延时，不依赖任何 PLL 的 lock。
PLL_HDMI_AUDIO u_audio_pll(
    .refclk                     (clk),
    .reset                      (1'b0),
    .extlock                    (),
    .clk0_out                   (),
    .clk1_out                   (),
    .clk2_out                   (audio_mclk)
);

// ================= 8 位数码管（上板诊断面板）=================
// 内容 = {disp_page, SD state_code, sw[3:0], 三个报警标志}，
// 没有仿真，这是唯一的运行时观察窗口。详见 hud_seg_data.v 头注释。
//
// 跨域：hud_seg_dig / hud_seg_dp / hud_seg_tog 来自 video_clk(25MHz)，
//       seg_disp_top 在 clk(50MHz) 里用 2 级同步 + toggle 边沿握手接收。
//       top.sdc 里为这条通路加了 set_false_path，见那里的说明。
seg_disp_top seg_disp_top_m0(
    .clk                        (clk                      ),
    .rst_n                      (por_rst_n                ),
    .seg_dig                    (hud_seg_dig              ),
    .seg_dp                     (hud_seg_dp               ),
    .seg_tog                    (hud_seg_tog              ),
    .seg_sel                    (seg_sel                  ),
    .seg_data                   (seg_data                 )
);

// ================= 报警蜂鸣器 (clk 50MHz 域) =================
// 板上 BUZZER = H11，厂商 13_music 例程就是用方波直接驱动这个脚。
// 报警时每 1 秒响 200ms 的间歇提示音（连着响 3~4 秒太吵）。
// ★ SW1 关掉报警声时 hud_alarm 已经是低，蜂鸣器自然不响 ★ —— 不需要再门控一次。
buzzer_beep #(.CLK_HZ(50000000)) u_buzzer(
    .clk                        (clk                      ),
    .rst_n                      (por_rst_n                ),
    .alarm_on                   (hud_alarm                ),
    .buzzer                     (buzzer                   )
);

wire hs_0;
wire vs_0;
wire de_0;
video_timing_data video_timing_data_m0(
    .video_clk                  (video_clk                ),
    .rst                        (~por_rst_n               ),
    .read_req                   (video_read_req           ),
    .read_req_ack               (video_read_req_ack       ),
    .hs                         (hs_0                     ),
    .vs                         (vs_0                     ),
    .de                         (de_0                     )
);

video_delay video_delay_m0(
    .video_clk                  (video_clk                ),
    .rst                        (~por_rst_n               ),
    .read_en                    (video_read_en            ),
    .read_data                  (video_read_data[31:8]    ),
    .hs                         (hs_0                     ),
    .vs                         (vs_0                     ),
    .de                         (de_0                     ),
    .hs_r                       (hs                       ),
    .vs_r                       (vs                       ),
    .de_r                       (de                       ),
    .vout_data                  (vout_data_raw            )
);

// 直通。首帧门控已停用(见下方说明)，保证 vout_data 永远有画面。
assign vout_data = vout_data_raw;

// ---- 首帧门控：已【停用】 ----
// 曾加过 display_valid 门控（第一帧写完前强制输出 24'd0）。实测会导致黑屏：
// 只要 frame_done 这条链上任何一环没出脉冲，vout_data 就永久为 0。
// 而且它是"锦上添花"的稳定性措施，不是赛题硬性要求，先去掉以保证一定能出图。
// 若日后要恢复，请务必同时加一个超时兜底，不要让画面完全依赖 frame_done。

//基础3: RGB/DE/VS 转 AXIS 视频流 (640x480)
//【HUD】输入改用叠加后的 hud_* —— 送进 HDMI 的画面 = 原图 + 压力容器面板
video_rgb_to_axis_640x480 u_video_rgb_to_axis(
    .I_clk                     (video_clk),
    .I_rst                     (rst_all),
    .I_vs                      (hud_vs),
    .I_de                      (hud_de),
    .I_rgb                     (hud_rgb),
    .O_video_user              (axis_s_user),
    .O_video_valid             (axis_s_valid),
    .O_video_last              (axis_s_last),
    .O_video_data              (axis_s_data)
);

//上电后自动打一拍, 触发一次EDID读取
startup_pulse #(.CNT_MAX(20'd100000)) u_startup_pulse(
    .I_clk                     (video_clk),
    .I_rst                     (rst_all),
    .O_pulse                   (edid_trig)
);

//基础3: HDMI 1.4b 发送器核心 (视频AXIS + 音频I2S打包 + ACR + DDC/EDID + TMDS编码)
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                    ("EG"),
    .HTOTAL                    (800),
    .HSA                       (96),
    .HFP                       (16),
    .HBP                       (48),
    .HACTIVE                   (640),
    .VTOTAL                    (525),
    .VSA                       (2),
    .VFP                       (10),
    .VBP                       (33),
    .VACTIVE                   (480),
    .VIDEO_VIC                 (1),
    .VIDEO_TPG                 ("Disable"),
    .VIDEO_FORMAT              ("RGB"),
    .AUDIO_SAMPLE_RATE         ("48K"),
    .IIC_SCL_DIV               (250)
) u_hdmi_core(
    .I_pixel_clk               (video_clk),
    .I_rst                     (rst_all),
    .I_edid_read_trig          (edid_trig),
    .O_edid_read_valid         (edid_valid),
    .O_edid_read_data          (edid_data),
    .I_axis_s_user             (axis_s_user),
    .I_axis_s_valid            (axis_s_valid),
    .I_axis_s_last             (axis_s_last),
    .I_axis_s_data             (axis_s_data),
    .O_axis_s_ready            (axis_s_ready),
    .I_audio_valid             (audio_valid),
    .I_audio_left_data         (audio_left_data),
    .I_audio_right_data        (audio_right_data),
    .I_acr_valid               (acr_valid),
    .I_acr_cts                 (acr_cts),
    .I_acr_n                   (acr_n),
    .O_video_locked            (),
    .O_ddc_scl                 (HDMI_DDC_SCL),
    .IO_ddc_sda                (HDMI_DDC_SDA),
    .O_ch0_tmds_data           (tmds_ch0_data),
    .O_ch1_tmds_data           (tmds_ch1_data),
    .O_ch2_tmds_data           (tmds_ch2_data),
    .O_clk_tmds_data           (tmds_clk_data)
);

//基础3: HDMI PHY封装 (10bit TMDS -> LVDS串行输出, 4通道10:1序列化)
hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi_phy(
    .I_pixel_clk               (video_clk),
    .I_serial_clk              (hdmi_5x_clk),
    .I_rst                     (rst_all),
    .I_tmds_channel_0          (tmds_ch0_data),
    .I_tmds_channel_1          (tmds_ch1_data),
    .I_tmds_channel_2          (tmds_ch2_data),
    .I_tmds_channel_clk        (tmds_clk_data),
    .O_tmds_ch0_p              (HDMI_D0_P),
    .O_tmds_ch1_p              (HDMI_D1_P),
    .O_tmds_ch2_p              (HDMI_D2_P),
    .O_tmds_clk_p              (HDMI_CLK_P)
);

//video frame data read-write control
frame_read_write #(
    .IMG_WIDTH  (640),
    .IMG_HEIGHT (480),
    .ROW_REVERSE(1)
) frame_read_write_m0(
    .mem_clk                    (ext_mem_clk              ),
    .rst                        (~por_rst_n               ),
    .Sdr_init_done              (Sdr_init_done            ),
    .Sdr_init_ref_vld           (Sdr_init_ref_vld         ),
    .Sdr_busy                   (Sdr_busy                 ),

    .App_rd_en                  (App_rd_en                ),
    .App_rd_addr                (App_rd_addr              ),
    .Sdr_rd_en                  (Sdr_rd_en                ),
    .Sdr_rd_dout                (Sdr_rd_dout              ),

    .read_clk                   (video_clk                ),
    .read_req                   (video_read_req           ),
    .read_req_ack               (video_read_req_ack       ),
    .read_finish                (                         ),
    .read_addr_0                (read_base                ), //基础2: 读显示帧(动态)
    .read_addr_1                (24'd0                    ),
    .read_addr_2                (24'd0                    ),
    .read_addr_3                (24'd0                    ),
    .read_addr_index            (2'd0                     ), //use only read_addr_0
    .read_len                   (24'd307200               ), //frame size
    .read_en                    (video_read_en            ),
    .read_data                  (video_read_data          ),

    .App_wr_en                  (App_wr_en                ),
    .App_wr_addr                (App_wr_addr              ),
    .App_wr_din                 (App_wr_din               ),
    .App_wr_dm                  (App_wr_dm                ),

    .write_clk                  (sd_card_clk              ),
    .write_req                  (sd_card_write_req        ),
    .write_req_ack              (sd_card_write_req_ack    ),
    .write_addr_0               (write_base               ), //基础2: 写非显示帧(动态)
    .write_addr_1               (24'd0                    ),
    .write_addr_2               (24'd0                    ),
    .write_addr_3               (24'd0                    ),
    .write_addr_index           (2'd0                     ), //use only write_addr_0
    .write_len                  (24'd307200               ), //frame size
    .write_en                   (sd_card_write_en         ),
    .write_data                 (sd_card_write_data       )
);

sdram U3(
    .Clk                        (ext_mem_clk              ),
    .Clk_sft                    (ext_mem_clk_sft          ),
    .Rst                        (~por_rst_n               ),

    .Sdr_init_done              (Sdr_init_done            ),
    .Sdr_init_ref_vld           (Sdr_init_ref_vld         ),
    .Sdr_busy                   (Sdr_busy                 ),

    .App_wr_en                  (App_wr_en                ),
    .App_wr_addr                (App_wr_addr              ),
    .App_wr_dm                  (App_wr_dm                ),
    .App_wr_din                 (App_wr_din               ),

    .App_rd_en                  (App_rd_en                ),//data_req
    .App_rd_addr                (App_rd_addr              ),
    .Sdr_rd_en                  (Sdr_rd_en                ),//data_valid
    .Sdr_rd_dout                (Sdr_rd_dout              )
);

// ================= 基础3: HDMI内嵌音频 =================
// 音频源本版有两个：
//   1) TF 卡流式 PCM（audio_fifo 供样，本模块发 O_pcm_req 提前一拍去要）
//   2) 报警提示音（800/640Hz 两音交替，内部合成，不占 TF 卡带宽、不占 BRAM）
// 由 I_mode 三选一。详见 hdmi_audio_tone_i2s_64fs.v 文件头。
//
// 音画同步: 音频时钟(12.295082MHz)与视频像素时钟(25MHz)同源(都由50MHz晶振PLL产生),
//           ACR机制让接收端恢复音频时钟, 保证音画同步。
hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC                 (32'd39370534),
    .AMP                       (24'sd2000000)
) u_audio_tone(
    .I_mclk                    (audio_mclk),
    .I_rst                     (rst_all),
    .I_mode                    (audio_mode),
    .I_pcm                     (pcm_data),
    .O_pcm_req                 (pcm_req),
    .O_i2s_BCLK                (audio_i2s_bclk),
    .O_i2s_LRCK                (audio_i2s_lrck),
    .O_i2s_DOUT                (audio_i2s_dout)
);

// I2S接收器: 串行I2S -> 24bit并行左右声道 (video_clk域, 跨时钟域同步)
I2S_receiver u_i2s_rx(
    .I_clk                     (video_clk),
    .I_rst                     (rst_all),
    .I_i2s_BCLK                (audio_i2s_bclk),
    .I_i2s_LRCK                (audio_i2s_lrck),
    .I_i2s_DOUT                (audio_i2s_dout),
    .O_audio_valid             (audio_valid),
    .O_audio_left_data         (audio_left_data),
    .O_audio_right_data        (audio_right_data)
);

// HDMI ACR (Audio Clock Regeneration) 计算: 让接收端从视频时钟恢复音频时钟
audio_arc_calculate #(.ACR_N(6144)) u_audio_arc(
    .I_clk                     (video_clk),
    .I_rst                     (rst_all),
    .I_audio_valid             (audio_valid),
    .O_acr_valid               (acr_valid),
    .O_acr_cts                 (acr_cts),
    .O_acr_n                   (acr_n)
);
// ====================================================================================

endmodule
