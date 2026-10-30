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
    output                      pwm_audio,         // ★ H11（网名本来就是 BUZZER）：
                                                   //   第四十版起接【报警蜂鸣器】，
                                                   //   报警时"嘀嘀嘀"（见 u_buzzer 一段）；
                                                   //   语音走 HDMI，不再从这根脚出去
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
wire [3:0]                      state_code;        // sd_card_clk 域（bmp_read 的显示码）
reg  [3:0]                      state_code_v1, state_code_v2;
// u_fat32_bmp 自己的状态码（sd_card_clk 域）。它原来在例化处【悬空】，
// 而 bmp_read 的 state_code=9 只说明"在等 open_done"，看不出卡在 FAT32 哪一段。
// 接出来之后，数码管 D1 就能分辨是卡在读 MBR / 引导扇区 / 目录项（见下面的 mux）。
wire [3:0]                      fat32_bmp_state;

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

// ---- SDRAM 侧的两个"整帧完成"里程碑（ext_mem_clk 域），只喂数码管诊断 ----
//   write_finish：frame_fifo_write 走到 S_END ⇒ 整帧 307200 字真的写进 SDRAM 了
//   read_finish ：frame_fifo_read  走到 S_END ⇒ 整帧真的从 SDRAM 读出来了
//   ★ 这两个是【精确】判据：write_finish 只在 write_cnt 攒够 write_len_latch
//     时才拉高，而 write_cnt 只靠写突发推进 ⇒ 它是"突发机制到底跑没跑"的
//     直接证据，比任何"数据非零"的粘滞或都要硬。★
wire wr_finish_raw;
wire rd_finish_raw;

// ================= 双缓冲（SDRAM 帧缓存）=================
wire                            frame_done;         // bmp_read.state_code 4->1 单拍脉冲(帧完成)
wire [23:0]                     write_base;         // 写基地址(当前正在预载的槽)
reg  [23:0]                     read_base;          // 读基地址(当前显示页所在的槽)
//   ★ 第二十七版起 read_base 是【ext_mem_clk 域寄存器】、不再是 video 域的组合乘法 ★
//     见下面"读基址整条搬进 ext_mem_clk 域"那一段，别改回 assign。
// ---- ★★ 2026-10-04 第十九版：六槽预载的信号 ★★ ----
//   ★ 这四个 wire 必须在 sd_card_bmp 例化【之前】声明 ★
//     因为 bmp_find 现在由 img_ld_find 驱动，而那段代码在例化之前；
//     先用后声明会先建出一根隐式 1 位线网，TD 报 HDL-5373
//     （por_rst_n 上踩过同一个坑，见 POR 段的说明）。
wire                            img_ld_find;        // 单拍：让 bmp_read 去取一张图
wire [2:0]                      img_ld_idx;         // 取第几张 0..5
wire [2:0]                      img_shown_slot;     // 最近一个【已完整落盘】的槽
wire [2:0]                      img_done_cnt;       // 已落盘的张数 0..6

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
// ★★ 2026-10-04 第十九版：把"整帧落盘"改成【翻转握手】★★
// =====================================================================
//   frame_fifo_write.write_finish 在 ext_mem_clk(125MHz) 下只有【一拍】宽
//   = 8ns。而 sd_card_clk 是 100MHz、周期 10ns —— 拿两级触发器去采一个 8ns
//   的窄脉冲，只要采样沿那一次恰好落在脉冲的高电平之外，就【整次丢失】。
//   两个时钟同源(4:5)，相位关系固定，所以这不是"偶发"，而是【某些对齐下
//   必然每次漏掉】。这正好能解释 D5 为什么偶尔少记一次。
//
//   ⇒ 脉冲只负责翻一个电平，电平的跳变任何同步器都漏不掉：
//       本域：每来一次 wr_finish_raw 翻一次 wr_tog
//       对面：三级同步 + 相邻两位异或 = 单拍脉冲
//   和本工程"页 -> 图"用的 img_tog 是同一个套路。
//
//   ★ 这个脉冲同时是【六槽预载】的推进条件 ★
//     只有整帧真的离开写 FIFO 才能把 write_base 推进到下一个槽，
//     否则残留的字会落进下一个槽的头部。
//     write_cnt 数的是 App_wr_en（= 从写 FIFO 取出多少字），
//     所以 write_finish 拉高时 FIFO 已经排空 —— 这个判据是准的。
// =====================================================================
reg        wr_tog;
always @(posedge ext_mem_clk or negedge por_rst_n) begin
    if (!por_rst_n)         wr_tog <= 1'b0;
    else if (wr_finish_raw) wr_tog <= ~wr_tog;
end

reg [2:0]  wr_tog_s;
always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) wr_tog_s <= 3'd0;
    else            wr_tog_s <= {wr_tog_s[1:0], wr_tog};
end
wire wr_frame_rise = wr_tog_s[2] ^ wr_tog_s[1];   // 单拍：一整帧落进 SDRAM

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

// ★★ 2026-10-04 修复：这里原来少了一个位宽，把"页号"变成了"页号的第 1 位" ★★
// ---------------------------------------------------------------------------
//   原来的写法：
//       reg [2:0] img_idx_s;                       // ← 只有 3 位
//       img_idx_s <= {img_idx_s[1:0], img_idx_v};  // ← 右边是 2+3 = 5 位
//   Verilog 把 5 位赋给 3 位时【丢高 2 位】，留下最低 3 位
//   {img_idx_s[1],img_idx_s[0],img_idx_v[2],img_idx_v[1],img_idx_v[0]} 的低 3 位
//   正好就是 {img_idx_v[2],img_idx_v[1],img_idx_v[0]} ——
//   ⇒ img_idx_s 根本不是"3 级移位寄存器"，它就等于 img_idx_v 本身（打了一拍）。
//   ⇒ 而下面取的是 img_idx_s[1]，于是送给 bmp_read 的图号 =
//        img_idx_v[1] = 【disp_page 的第 1 位比特】，只能是 0 或 1。
//
//   【后果】图号只由 disp_page 的 bit1 决定：
//       页 0 -> 0 -> 01.BMP      页 1 -> 0 -> 01.BMP
//       页 2 -> 1 -> 02.BMP      页 3 -> 1 -> 02.BMP
//       页 4 -> 0 -> 01.BMP      页 5 -> 0 -> 01.BMP
//   ⇒ 页 0↔1 完全同图、页 4↔5 完全同图，只有跨过 bit1 时才换一次。
//     这正是"按 K2 翻页底图基本不动"的来源。
//   ★ 顺带：is_alarm_page = (img_idx_sd == 3'd5) 也因此【永远不可能成立】，
//     "报警页不播切换播报"这条从来没生效过。★
//
//   【上板证据】数码管 D2(=bmp_file_idx) 读 0,0,1 对应 D0=0,1,2 —— 正是
//     disp_page[1] 的序列；若把"D2 比 D0 慢一拍"当成 CDC 时序问题就找反了方向。
//
//   【修法】不动结构，只把"取哪一位"改对：
//     数据寄存器仍然是 1 级 3 位（它本来就等效于 `img_idx_s <= img_idx_v`），
//     但不再写 `{img_idx_s[1:0], img_idx_v}` 这种会被截断的拼接 ——
//     直接 `img_idx_s <= img_idx_v`，语义一目了然，也不会再有人误以为它是深链。
//     取出时取【整个 3 位】`img_idx_s`，而不是 `img_idx_s[1]`。
//
//   【为什么 1 级就够】（这不是降低同步深度，是回到它真实的样子）
//     img_idx_v 比 o_img_tog 早约 2 个 video_clk(≈80ns) 变（见 hud_data_gen：
//     disp_page 先变，o_page_chg 再打一拍，img_tog_r 再翻）。
//     sd_card_clk 周期 10ns ⇒ 等 toggle 的边沿被 img_tog_s[1]/[2] 检出来时，
//     数据早已稳定 8 拍以上 —— 数据由 toggle 这个握手信号"限定"，不靠自身深度。
//     ★ 上板前的旧版【本来】就是这么一级数据同步，这次没有削弱它 ★
//
//   【为什么不用两级】试过写成 img_idx_s0/img_idx_s1 两级，功能正确，但
//     多出来的 3 个触发器改变了布局结果，route 后出现 ext_mem_clk ->
//     sd_card_clk 上 -1.689ns 的 setup 违例（两次重跑数字完全相同 ⇒ 不是随机性）。
//     为了不把一个已验证通过时序的网表推离原位，改回"零新增触发器"的写法。
// ---------------------------------------------------------------------------
reg [2:0] img_tog_s;             // 3FF 同步 toggle
reg [2:0] img_idx_s;             // 数据同步：1 级，整 3 位（见上面说明）

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        img_tog_s <= 3'd0;
        img_idx_s <= 3'd0;
    end else begin
        img_tog_s <= {img_tog_s[1:0], img_tog_v};
        img_idx_s <= img_idx_v;          // ★ 整 3 位，不拼接、不截断 ★
    end
end

// 用第 1/2 级之间取沿：那一拍 img_idx_s 正好是新的页号（整 3 位）
wire        page_chg_sd = img_tog_s[2] ^ img_tog_s[1];   // 单拍
wire [2:0]  img_idx_sd  = img_idx_s;                     // ★ 取整值，不取某一位 ★

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

// ★ SPI_HIGH_SPEED_DIV 的取值过程（每一步都要记着）★
//   公式在 sd_card_top.v:5：spi clk = clk / ((SPI_HIGH_SPEED_DIV + 2) * 2)
//   这里 clk = sd_card_clk = 100MHz。
//
//   默认 0  → 读卡 25MHz：SD SPI 的规格上限。板子上是飞线，实测"背景全黑"，
//             bmp_read 卡在等 open_done。★ 25MHz 从来没上板验证过 ★
//   改成 2  → 读卡 12.5MHz（与 50MHz 探针同频，探针在这个频率读到 4561290F）：
//             背景图出来了，但★ 图上有零散噪点 ★
//   试过 14 → 读卡 3.125MHz（降 4 倍的对照实验），结果：
//     ★ 图上的噪点【数量、位置完全没变】★ ⇒ SD 读速与噪点无关 ⇒ 已收回，
//     仍用 2（12.5MHz，就是这一档第一次把图显示出来的频率）。
//
//   为什么当时要做那个实验：
//     噪点"零散、撒满全图、位置钉死不动"，而整条链里只有 SD 数据没有任何校验
//     （sd_card_cmd 读 512+2 字节，那 2 字节 CRC 直接丢掉、从不比对），
//     所以先怀疑"SPI 线上偶尔采错一位"。降 4 倍后毫无变化 ⇒ 排除。
//   注意：SPI 的采样边沿本身已逐拍核对过是对的（CPHA=1 在奇数边沿采，
//     MISO 那时已稳定整个低半周期），写侧跨时钟 FIFO 也是真正的双时钟 FIFO。
//   ★ 后续排查方向见 fat32-migration-status 的记忆条目，不要重复做降速实验。★
sd_card_top #(
    .SPI_HIGH_SPEED_DIV         (16'd2                   )
) sd_card_top_m0(
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

// ---- 四个请求方 -> 仲裁器 ----
//   bmp : 图片数据（sd_card_bmp -> bmp_read，地址来自 u_fat32_bmp）
//   aud : 音频数据（wav_loader，地址来自 u_fat32_wav）
//   fbm : 图片链的 MBR/目录/FAT 读（u_fat32_bmp 内部发起）
//   fau : 音频链的 MBR/目录/FAT 读（u_fat32_wav 内部发起）
wire        bmp_req,   aud_req,   fbm_req,   fau_req;
wire [31:0] bmp_addr,  aud_addr,  fbm_addr,  fau_addr;
wire        bmp_grant, aud_grant, fbm_grant, fau_grant;
wire        bmp_rdata_valid, aud_rdata_valid, fbm_rdata_valid, fau_rdata_valid;
wire        bmp_rend,        aud_rend,        fbm_rend,        fau_rend;

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
    .fbm_req                    (fbm_req                 ),
    .fbm_addr                   (fbm_addr                ),
    .fbm_grant                  (fbm_grant               ),
    .fbm_rdata_valid            (fbm_rdata_valid         ),
    .fbm_rend                   (fbm_rend                ),
    .fau_req                    (fau_req                 ),
    .fau_addr                   (fau_addr                ),
    .fau_grant                  (fau_grant               ),
    .fau_rdata_valid            (fau_rdata_valid         ),
    .fau_rend                   (fau_rend                ),
    .sd_sec_read                (sd_sec_read             ),
    .sd_sec_read_addr           (sd_sec_read_addr        ),
    .sd_sec_read_data           (sd_sec_read_data        ),
    .sd_sec_read_data_valid     (sd_sec_read_data_valid  ),
    .sd_sec_read_end            (sd_sec_read_end         )
);

// ---- 取图请求 ----
// ★★ 2026-10-04 第十九版：取图【不再由翻页触发】，改由六槽预载器触发 ★★
//   旧版：wire bmp_find = first_find | page_chg_sd;   ← 翻页就重读一张
//   那正是"图片切换慢"的根源：翻页之后要等 SD 卡把整张 921654 字节的 BMP
//   读完（12.5MHz SPI 下约 0.67 秒）才切帧缓冲，而工况页是 FPGA 自己画的、
//   当拍就变 —— 两者当然对不上。
//
//   现在：上电后 u_img_slots 依次把六张图读进 SDRAM 的六个槽（各占 307200 字，
//   六个共 1843200 字，硬核 SDRAM 是 2M×32，放得进），翻页只切换读基址，
//   所以底图与工况页【同一拍】变。代价是上电后约 4 秒的预载时间。
//
//   ★ 报警页（页 5）的底图就是第 5 槽（卡图 06.BMP，红色），
//     在预载里和其他五张一样处理，不需要任何特判。★
//   ★ 音频那条链【一点没动】★：wav_play 仍然挂在 page_chg_sd 上，
//     翻页该播哪段播报还播哪段，和图无关。
wire bmp_find = img_ld_find;

wire        bmp_ready;

// ---- FAT32 地址来源 ----
// ★ 这几个 wire 必须在 sd_card_bmp 例化【之前】声明 ★
//   Verilog 允许"先用后声明"，但那会先自动建出一个【隐式 1 位线网】，
//   等后面再写 `wire [31:0] bmp_xl_lba;` 就是重复声明，TD 会报
//       CRITICAL-WARNING: 'bmp_xl_lba' is already implicitly declared
//
//   对 bmp_xl_sec_idx / bmp_xl_lba 这种 32 位信号，隐式线网只有 1 位 ——
//   LBA 的高 31 位全丢，读图必然读错扇区。
//   （bmp_open_req 这些 1 位信号宽度上碰巧一样，但同样不该这么写。）
//
//   音频侧那几个（wav_open_req 等）是在本段之后、u_fat32_wav 之前声明的，
//   而 u_wav_loader 在更后面的音频段里才用到它们，所以没这个问题。
wire        bmp_open_req;
wire [3:0]  bmp_file_idx;
wire        bmp_open_done, bmp_found;
wire        bmp_xl_req;
wire [31:0] bmp_xl_sec_idx;
wire        bmp_xl_valid, bmp_xl_err;
wire [31:0] bmp_xl_lba;
// ★ 2026-10-04 第十八版新增的诊断线 ★
//   fat32_reader 本来就有 first_cluster 输出（起始簇），但一直留空不接。
//   它回答一个"请求对了、打开对了，但读回来的数据是不是同一个文件"的问题：
//   六个 BMP 的起始簇互不相同，只要它随翻页而变，就证明每次真的打开了不同的文件。
wire [31:0] bmp_first_cluster;

sd_card_bmp sd_card_bmp_m0(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .find                       (bmp_find                ),
    .img_index                  (img_ld_idx              ),
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
    .sd_sec_read_end            (bmp_rend                ),
    // ---- FAT32 地址来源 ----
    .f_open_req                 (bmp_open_req            ),
    .f_file_idx                 (bmp_file_idx            ),
    .f_open_done                (bmp_open_done           ),
    .f_found                    (bmp_found               ),
    .f_xl_req                   (bmp_xl_req              ),
    .f_xl_sec_idx               (bmp_xl_sec_idx          ),
    .f_xl_valid                 (bmp_xl_valid            ),
    .f_xl_lba                   (bmp_xl_lba              ),
    .f_xl_err                   (bmp_xl_err              )
);

// =====================================================================
// FAT32 地址翻译：图片链和音频链各一个实例
//
//   ★ 为什么是两个实例而不是一个共享的 ★
//     两条流读的是不同的文件，各自有一条独立的簇链游标（当前簇 / 链上序号）。
//     共用一个实例的话，两边交替请求翻译时，每次都发现"当前游标不是我要的
//     那个文件"，于是每次都要从起始簇重走一遍簇链 —— 音频每读一个扇区就要
//     重走几百次 FAT 表，SD 带宽会被这种重走吃光。
//     两个实例各自的游标独立，代价只是约 600 个 LUT。
//
//   ★ 它们同时是 u_sd_arb 的 fbm / fau 请求方 ★
//     因为读 MBR / 引导扇区 / 目录项 / FAT 表都要走 sd_card_top。
//     和另外两个数据请求方共用一个仲裁器，优先级见 sd_arbiter.v 文件头。
// =====================================================================
// （bmp_* 那几个 wire 已经在 sd_card_bmp 例化之前声明过了 ——
//   声明必须放在第一次使用之前，否则会先建出 1 位宽的隐式线网。
//   原因见那里的注释。）

fat32_reader u_fat32_bmp(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .sd_init_done               (sd_init_done            ),
    .open_req                   (bmp_open_req            ),
    .file_idx                   (bmp_file_idx            ),
    .open_busy                  (                        ),
    .open_done                  (bmp_open_done           ),
    .found                      (bmp_found               ),
    .file_size                  (                        ),
    .first_cluster              (bmp_first_cluster       ),   // ★ 诊断用（第十八版）
    .xl_req                     (bmp_xl_req              ),
    .xl_sec_idx                 (bmp_xl_sec_idx          ),
    .xl_busy                    (                        ),
    .xl_valid                   (bmp_xl_valid            ),
    .xl_lba                     (bmp_xl_lba              ),
    .xl_err                     (bmp_xl_err              ),
    // MBR/目录/FAT 读口 -> 仲裁器（数据总线是共用的，valid/end 按授权方二分）
    .fat_req                    (fbm_req                 ),
    .fat_addr                   (fbm_addr                ),
    .fat_grant                  (fbm_grant               ),
    .fat_data                   (sd_sec_read_data        ),
    .fat_valid                  (fbm_rdata_valid         ),
    .fat_end                    (fbm_rend                ),
    .state_code                 (fat32_bmp_state         )
);

wire        wav_open_req;
wire [3:0]  wav_file_idx;
wire        wav_open_done, wav_found;
wire        wav_xl_req;
wire [31:0] wav_xl_sec_idx;
wire        wav_xl_valid, wav_xl_err;
wire [31:0] wav_xl_lba;

fat32_reader u_fat32_wav(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .sd_init_done               (sd_init_done            ),
    .open_req                   (wav_open_req            ),
    .file_idx                   (wav_file_idx            ),
    .open_busy                  (                        ),
    .open_done                  (wav_open_done           ),
    .found                      (wav_found               ),
    .file_size                  (                        ),
    .xl_req                     (wav_xl_req              ),
    .xl_sec_idx                 (wav_xl_sec_idx          ),
    .xl_busy                    (                        ),
    .xl_valid                   (wav_xl_valid            ),
    .xl_lba                     (wav_xl_lba              ),
    .xl_err                     (wav_xl_err              ),
    .fat_req                    (fau_req                 ),
    .fat_addr                   (fau_addr                ),
    .fat_grant                  (fau_grant               ),
    .fat_data                   (sd_sec_read_data        ),
    .fat_valid                  (fau_rdata_valid         ),
    .fat_end                    (fau_rend                ),
    .state_code                 (                        )
);

// =====================================================================
// 音频通路（FAT32 + HDMI 版）：wav_loader -> 跨域 -> HDMI 内嵌音频
//
//   切页时按文件名打开 0X.WAV 并从头播放，PCM 走 **HDMI 内嵌音频**出去，
//   由显示器自带喇叭播放。H11 那路 PWM 功放本版已停用（见下面 AUDIO_OUT_HDMI）。
//
//   ★ 第二十五版：输出从 H11 改成 HDMI ★
//   背景（已定案）：板载蜂鸣器物理焊在 H11 上、拆不掉，而 PWM 音频一直在驱动它
//   —— 用户听到的"模糊人声"就是从蜂鸣器出来的，说明整条数字链全通，
//   故障全在【功放/喇叭】那段。所以干脆不走那条路了。
//
//   好消息：HDMI 内嵌音频这条链**早就存在而且是完整接好的**：
//
//       wav_pcm/wav_pcm_stb ──(上一版从没接)──> I_pcm
//            hdmi_audio_tone_i2s_64fs (M_PCM 档)
//              -> I2S_receiver u_i2s_rx -> hdmi_1_4b_transmitter_core_wrapper
//              -> hdmi_phy_wrapper -> LVDS TMDS -> HDMI A 口 -> 显示器喇叭
//
//   上一版只是把 pcm_data 钉死成 0（"保留但不供数据"）。这一版把它接上。
//
//   ★ 为什么【不用】做 3 倍零阶保持 ★
//     WAV 是 16000Hz，HDMI 帧率是 audio_mclk/256 = 48027.7Hz，差了 3 倍。
//     但 u_audio_tone 在 M_PCM 档本来就【每个帧边界采一次 I_pcm】
//     （见 hdmi_audio_tone_i2s_64fs.v 的帧边界一段）。只要 I_pcm 是由 16kHz
//     自由运行地更新，输出就是 16000Hz 信号在 48kHz 栅格上的零阶保持，
//     平均每样本保持 3.0017 帧：时长 48000×3.0017÷48027.7 = 3.0000 秒 ✓、
//     音高不变 ✓、而且 16000 < 48027.7/3 ⇒ 永远不会漏掉源样本 ✓。
//     这正是那个模块文件头写明的预期用法（"直接把 rd_data 接到 I_pcm"）。
//     ⇒ **那个模块一个字都不用改**，改它是零收益、非零风险。
//
//   ★ 跨时钟域（下面是本文件里唯一新增的 CDC）★
//     wav_pcm/wav_pcm_stb 在 sd_card_clk(100MHz) 域，I_pcm 必须在 audio_mclk
//     域并且是【稳定寄存器】（u_audio_tone 按帧边界采它）。
//     用的是本工程已采用过的"数据先稳、toggle 后翻"写法（同 audio_fifo.v
//     的读侧），不新建文件 —— 新建 .v 要同时改 .al + 两个 .prj，本工程在
//     那上面栽过 AutoExcluded 的坑。约束也不用动：top.sdc 里
//     sd_card_clk <-> audio_mclk 两个方向的 set_false_path 早就有了。
//
//   ★ 数据总线 sd_sec_read_data 是共用的，只有 valid/end 按授权方二分 ★
//     所以 wav_loader 和 sd_card_bmp 都把同一根 sd_sec_read_data 接进 sd_data，
//     靠各自的 rdata_valid 区分"这是不是给我的"。
// =====================================================================
// 切页 -> 重新按名打开对应 WAV 并从头播（wav_loader 内部可打断）
//   报警页（页 5）也发 play：按 spec 故障页要播 06.WAV。
//   wav_loader 会把 frag_idx=5 译码成 06.WAV。
wire wav_stop = 1'b0;            // 本版不主动停；一段播满 data_len 自然结束

// ---- SW4 静音：hud_top 已在 video_clk 域同步消抖过，这里再过到 sd 域 ----
//      电平量，2FF 足够。不要在 audio_pwm 里直接用 video 域的 sw_v。
//
//   ★ 关于"KEY_MUTE"★
//     本工程四个按键（A2/B2/B1/C1）已经分别给了复位/翻页/亮度/轮播，
//     没有空闲按键。所以静音沿用这个工程原有的约定：**SW4 拨动开关**。
//     这就是旧 audio_mode 里 `~sw_v[3]` 那一项用的同一个信号。
//     如果你要的是"按一下翻转"的按键静音，在这里把 sw_v[3] 换成一个
//     按键消抖后的电平即可，audio_pwm 那边不用动。
reg [1:0] mute_s;
always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) mute_s <= 2'd0;
    else            mute_s <= {mute_s[0], sw_v[3]};
end
wire aud_mute = mute_s[1];

// =====================================================================
// 故障页 6 秒重播
//
//   故障页（页 5，即 img_idx_sd==5）停留期间，每 6 秒重播一次 06.WAV。
//
//   ★ 计时起点是"进入故障页"而不是"进入后等 6 秒" ★
//     进故障页那一拍 page_chg_sd 已经播了第一次（wav_loader 把 frag_idx=5
//     译码成 06.WAV），所以这里计数器从 0 起数，满 6 秒再补一次。
//     即"进页立刻响，之后每隔 6 秒重复"。
//
//   ★ 静音时不重播 ★
//     条件里带 !aud_mute。静音期间计数一直清零，所以解除静音后是
//     "从解除那一刻重新数 6 秒"，不会立刻补播一次。
//     已经在播的那一段靠 audio_pwm 的 mute 静掉（喂 0，输出 50% 占空比，
//     不产生直流跳变，不会"咔"一声）。
//
//   ★ 离开故障页自动恢复正常 ★
//     不在故障页时计数同样清零。故障解除回总览页时 page_chg_sd 会正常发
//     play，播的是新页对应的 WAV —— 恢复切页播报不需要任何额外状态。
//
//   ★★ 2026-10-14：间隔 5 秒 → 6 秒 ★★
//     换卡后卡上 06.WAV 变成了 5.180 秒（换卡前那份是 4.181 秒）。
//     间隔仍按 5 秒的话，每次都会在还剩 0.18 秒时把文件打断重来 ——
//     尾巴那 0.18 秒永远听不到。所以间隔必须【大于文件本身长度】，
//     取 6 秒（比 5.180 秒多 0.82 秒余量）。旧值 5.000 秒是照着
//     旧的 4.181 秒文件定的，那条前提已经不成立了。
//     ★ 以后再换素材，记得回头核对这个间隔 > 06.WAV 的时长 ★
//
//   6 秒 @ 100MHz = 600_000_000，需要 30 位
//     （2^29 = 536,870,912 < 6e8 ≤ 2^30 = 1,073,741,824）⇒ 位宽从 29 加到 30。
// =====================================================================
localparam [29:0] ALARM_RPT_MAX = 30'd600_000_000 - 30'd1;

reg [29:0] alarm_rpt_cnt;
reg        alarm_rpt;            // 单拍：该重播了

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        alarm_rpt_cnt <= 30'd0;
        alarm_rpt     <= 1'b0;
    end else begin
        alarm_rpt <= 1'b0;
        if (is_alarm_page && !aud_mute) begin
            if (alarm_rpt_cnt >= ALARM_RPT_MAX) begin
                alarm_rpt_cnt <= 30'd0;
                alarm_rpt     <= 1'b1;
            end else
                alarm_rpt_cnt <= alarm_rpt_cnt + 30'd1;
        end else
            alarm_rpt_cnt <= 30'd0;
    end
end

wire wav_play = page_chg_sd | alarm_rpt;

// ---- WAV -> PCM ----
wire        wav_playing, wav_done, wav_err;
wire [15:0] wav_pcm;
wire        wav_pcm_stb;
wire [3:0]  wav_state_code;
wire        wav_rate_ok, wav_fmt_ok;

wav_loader u_wav_loader(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .sd_init_done               (sd_init_done            ),
    .play                       (wav_play                ),
    .frag_idx                   (img_idx_sd              ),
    .stop                       (wav_stop                ),
    .playing                    (wav_playing             ),
    .done                       (wav_done                ),
    .err                        (wav_err                 ),
    .f_open_req                 (wav_open_req            ),
    .f_file_idx                 (wav_file_idx            ),
    .f_open_done                (wav_open_done           ),
    .f_found                    (wav_found               ),
    .f_file_size                (                        ),
    .f_xl_req                   (wav_xl_req              ),
    .f_xl_sec_idx               (wav_xl_sec_idx          ),
    .f_xl_valid                 (wav_xl_valid            ),
    .f_xl_lba                   (wav_xl_lba              ),
    .f_xl_err                   (wav_xl_err              ),
    .sd_req                     (aud_req                 ),
    .sd_addr                    (aud_addr                ),
    .sd_grant                   (aud_grant               ),
    .sd_data                    (sd_sec_read_data        ),
    .sd_valid                   (aud_rdata_valid         ),
    .sd_end                     (aud_rend                ),
    .pcm                        (wav_pcm                 ),
    .pcm_stb                    (wav_pcm_stb             ),
    .state_code                 (wav_state_code          ),
    .rate_ok                    (wav_rate_ok             ),
    .fmt_ok                     (wav_fmt_ok              )
);

// =====================================================================
// ★★ 第二十五版：HDMI 内嵌音频 —— 跨域（sd_card_clk 100MHz -> audio_mclk）★★
// =====================================================================
// wav_pcm/wav_pcm_stb 是 sd 域的（wav_loader 的 [3/3] 播放侧，同一拍寄存，
// 所以 pcm_stb 为高的那一拍 pcm 已经是完整样本）。u_audio_tone 要的 I_pcm
// 必须是 **audio_mclk 域的稳定寄存器**（它在每个帧边界采，见那个模块的头注释）。
//
// 【写法：数据先稳、toggle 后翻】
//   和 audio_fifo.v 读侧同一个模式（那个模式在本工程是既有的）：
//     写侧：数据与 toggle **在同一个沿**非阻塞赋值
//     读侧：toggle 过 3 级同步后才边沿检测 -> 那时数据早已稳定 -> 直接锁存
//
// 【为什么直接读 cdc_hold_data 是安全的（同沿纪律 + 速率纪律）】
//   1) 同沿：cdc_hold_data 与 cdc_hold_tog 在同一条 always、同一个 posedge 赋值，
//      所以 toggle 被读侧看到时，数据至少已稳了 3 个 audio_mclk（≈244ns）。
//   2) 速率：wav_pcm_stb 的周期是 62.5us（16kHz），是同步窗口的约 250 倍
//      ⇒ 数据在整个捕获窗口内【不会变化】，16bit 总线不可能撕裂。
//   ★ 第 2) 条是这套写法成立的前提。若以后把音频源换成更高的采样率
//     （≥几百 kHz），必须重新算这个余量，不能照抄。★
//   新样本比读侧慢一点点也无所谓：I_pcm 没变时 u_audio_tone 重复采同一个值，
//   就是零阶保持（这正是我们要的重采样行为）。
// =====================================================================
reg [15:0] cdc_hold_data;            // sd 域：最近一个样本（保持到下一个）
reg        cdc_hold_tog;             // sd 域：每来一个样本翻一次

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        cdc_hold_data <= 16'd0;
        cdc_hold_tog  <= 1'b0;
    end else if (wav_pcm_stb) begin
        cdc_hold_data <= wav_pcm;
        cdc_hold_tog  <= ~cdc_hold_tog;
    end
end

reg [2:0] cdc_tog_sync;              // audio_mclk 域：3FF 同步

always @(posedge audio_mclk or negedge por_rst_n) begin
    if (!por_rst_n) cdc_tog_sync <= 3'd0;
    else            cdc_tog_sync <= {cdc_tog_sync[1:0], cdc_hold_tog};
end

wire cdc_rd_edge = cdc_tog_sync[2] ^ cdc_tog_sync[1];

// ★ pcm_data 必须落在 audio_mclk 域，并且直接接给 u_audio_tone.I_pcm ★
reg [15:0] pcm_data;

always @(posedge audio_mclk or negedge por_rst_n) begin
    if (!por_rst_n)       pcm_data <= 16'd0;
    else if (cdc_rd_edge) pcm_data <= cdc_hold_data;
end

// ---------------------------------------------------------------------
// 本段"确实在出样本"的粘滞标志（sd 域，给 audio_mode 用）
//
//   ★ 为什么不能用 wav_loader 的 playing 输出 ★
//     wav_loader.v 里是 `playing <= (st == A_WAITPLY) && (rd_remain != 0)`，
//     而每腾出一个半区去回填时 FSM 会 `st <= A_SEEK` **离开 A_WAITPLY**。
//     半区 512 字节 = 16ms 播完一次、回填约 340us
//     ⇒ playing 会【每 16ms 掉 0 一次】。
//     拿它选 audio_mode 就会每 16ms 硬切 M_PCM->M_MUTE 一次，而 M_MUTE 分支
//     把样本强制成 0 ⇒ 周期性断音/咔哒（约 62Hz）。所以必须用粘滞量。
//
//   ★ 为什么用 wav_pcm_stb 置位、而不是用 wav_play ★
//     wav_play 之后还要开门、解 RIFF 头、预填（几毫秒），那段时间 I_pcm 还是
//     上一段的残值，M_PCM 会把它当直流按住。用【第一个真样本】置位就干净了：
//     引导段保持 M_MUTE（真静音）。
//
//   ★ 段尾一定要清 ★（done / err）
//     否则段播完之后 pcm_data 被 u_audio_tone 永久重复 => 一个持续的直流电平，
//     听起来是"嗡"一声闷响（audio_fifo.v 文件头专门警告过这个坑）。
// ---------------------------------------------------------------------
reg wav_active;

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n)              wav_active <= 1'b0;
    else if (wav_play)           wav_active <= 1'b0;   // 新段：先关（wav_play 优先）
    else if (wav_done | wav_err) wav_active <= 1'b0;   // 段尾/出错：回落静音
    else if (wav_pcm_stb)        wav_active <= 1'b1;   // 第一个真样本到了才开
end

// =====================================================================
// ★★ 2026-10-04 第二十二版：音频【测试音】固件 ★★
// =====================================================================
// 【为什么要做这一版】
//   前面的诊断已经把 FPGA 内部**全部验完**了：
//     打开文件 ✓（D3='E'）/ 解析 RIFF ✓ / 没被静音 ✓（D3 低位=0）
//     样本拼装正确 ✓（D5 每页不同）/ sigma-delta 占空比紧跟样本 ✓
//     （tools/audio_pwm_check.py，相关系数 +1.0000）/ 引脚确实在 H11 ✓
//   可是喇叭里还是没有语音。
//   ⇒ 剩下的只可能是【RC 网络 / 功放 / 接线】这一段。
//   而"数字侧没信号"和"模拟侧不通"在喇叭上听起来一模一样，必须切开。
//
//   ⇒ 这一版把音频源换成【上电就出、完全不依赖 TF 卡】的 1kHz 正弦，
//     好让 H11 上有一个**已知的、响亮的、能用示波器量的**信号。
//     有了它，一次就能把"FPGA→RC"和"RC→功放"两段切开。
//
// 【切回去只要改这一行】
//   AUDIO_TEST_TONE 改回 1'b0 就是原来的"切页播 WAV"。整段都可以删掉。
//   下面的探针 D4/D5 跟着这个开关走，两种固件下面板都读得懂。
//
// 【为什么复用 audio_gen 而不是新写一个】
//   src/audio_gen.v 本来就列在两个 .prj 里（旧的 HDMI 48kHz 测试音用的），
//   写法**已经上板验证过**：同一拍里锁样本、锁 data_valid，天然对齐：
//       if (fsync) begin d <= sin_val; valid <= 1'b1; phase <= phase + INC; end
//   复用它 ⇒ **不用动 .prj、不新增文件**，退回去也只要删掉这一段。
//   （sin_lut.v 同样早就在 .prj 里。）
//
// 【采样率为什么是 1.5625MHz，不是 16kHz】
//   1kHz 正弦若按 16kHz 采样，一个周期只有 16 个点，阶梯的镜像落在
//   15k/17kHz —— 正好在 RC 的截止频率(15.9kHz)附近，滤不掉，听感是"嗡嗡"。
//   取 100MHz/64 = 1.5625MHz ⇒ 一个周期 1562 个点，镜像被推到 1.56MHz，
//   RC 衰减 40dB 以上。
//   离线复算（tools/audio_rc_snr.py --tone 1000 --amp 1.0 --osr 64）：
//   **满幅时 THD+N = 40.5dB（0.94%）**，又响又干净，且加载长记录不劣化
//   ⇒ 不需要为了"环路稳定"把幅度降下来，可以按要求的满幅给。
//
// 【和 TF 卡完全无关】
//   这里所有的复位只接 por_rst_n，**没有一处接 sd_init_done**
//   ⇒ **把 TF 卡拔了，测试音一样响**。那是最干净的一次测试。
// =====================================================================
localparam AUDIO_TEST_TONE = 1'b0;      // ★ 1 = 测试音固件；0 = 正常播 WAV ★

// audio_pwm 的 SAMPLE_HZ 参数只用于注释/自检（模块靠 pcm_stb 定节拍），
// 但既然两种固件的采样率差了 100 倍，就别写死 16000 让它误导人。
localparam integer AUDIO_SAMPLE_HZ = AUDIO_TEST_TONE ? 1_562_500 : 16_000;

// ---- 采样节拍：100MHz / 64 = 1.5625MHz ----
reg [5:0] tone_div;
always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n)              tone_div <= 6'd0;
    else if (tone_div == 6'd63)  tone_div <= 6'd0;
    else                         tone_div <= tone_div + 6'd1;
end
wire tone_fsync = (tone_div == 6'd63);   // 单拍脉冲

wire [15:0] tone_l, tone_r;
wire        tone_valid;
audio_gen #(
    // 相位步进 = 2^32 * 1000Hz / 1.5625MHz = 2748779.07
    //          ⇒ 实测 999.99997Hz，误差 3e-8，可以认为就是 1kHz
    .PHASE_BITS (32),
    .PHASE_INC  (32'd2748779)
    // ★ 实例名【不能】叫 u_audio_tone ★
    //   那个名字已经被 HDMI 那条链用了（本文件后面
    //   hdmi_audio_tone_i2s_64fs 那一处），重名会让 TD 直接
    //   HDL-8007 报错停在这里。踩过一次，留个记号。
) u_audio_tone_1k (
    .clk                        (sd_card_clk             ),
    .rst_n                      (por_rst_n               ),
    .fsync                      (tone_fsync              ),
    .l_data                     (tone_l                  ),
    .r_data                     (tone_r                  ),   // 单声道，丢弃
    .data_valid                 (tone_valid              )
);

// ---- 两条音频源在这里选一条送给 audio_pwm ----
wire [15:0] aud_pcm     = AUDIO_TEST_TONE ? tone_l     : wav_pcm;
wire        aud_pcm_stb = AUDIO_TEST_TONE ? tone_valid : wav_pcm_stb;

// ★★ 测试音固件里【静音被强制旁路】★★
//   本意：绝不能有一个开关位置能把测试音悄悄吃掉。一旦被静音，
//   测出来的"没声"就又分不清是 FPGA 侧还是模拟侧了 —— 那就白测一次。
//   正常固件（AUDIO_TEST_TONE=0）SW4 仍然照常有效。
wire        aud_mute_eff = AUDIO_TEST_TONE ? 1'b0 : aud_mute;

// ---- PCM -> 1bit PWM -> H11 -> RC -> PAM8403（★第二十五版停用 / 第四十版被蜂鸣器接手★）----
//
//   ★ 为什么停用 ★
//   板上 BUZZER 就焊在 H11 上（top.adc 里这个脚的网名本来就是 BUZZER），
//   拆不掉。上一版音频走的就是它 —— 所以现象是"喇叭没声、板子在响"。
//   第二十五版起语音改从 HDMI 内嵌音频出去（见本文件后面 u_audio_tone 那一段）。
//   ★ 第四十版：H11 这根脚被【报警蜂鸣器】接手了（见下面 u_buzzer），
//     所以它不再是"恒输出低"，但语音仍然只走 HDMI —— 二者互不干扰。★
//
//   ★ 已知副作用（接受）★
//   AUDIO_OUT_HDMI 是 localparam，常量传播后 pwm_out 没有消费者，综合会把
//   u_audio_pwm（连同只服务它的 audio_gen / sin_lut / tone_div）整块裁掉。
//   所以"保留 PWM 代码"只是名义上的：源码还在，网表里没有。
//   引脚配置【不会丢】—— I/O 标准和位置来自 top.adc，端口还在就会被常量驱动。
//   切回 H11：把 AUDIO_OUT_HDMI 改成 1'b0 即可，不需要动别的。
//
//   ★ 面板探针不受影响 ★
//   D2/D3/D4/D5 量的是 aud_pcm/aud_pcm_stb（= wav_pcm/wav_pcm_stb），
//   它们的消费者除了 audio_pwm 还有下面的探针块本身 ⇒ 裁掉 audio_pwm
//   后面板读数依然有效。
localparam AUDIO_OUT_HDMI = 1'b1;    // 1 = 语音只走 HDMI；H11 留给报警蜂鸣器

wire pwm_out;

audio_pwm #(.SAMPLE_HZ(AUDIO_SAMPLE_HZ)) u_audio_pwm(
    .clk                        (sd_card_clk             ),
    .rst                        (~por_rst_n              ),
    .pcm                        (aud_pcm                 ),
    .pcm_stb                    (aud_pcm_stb             ),
    .mute                       (aud_mute_eff            ),
    .pwm_out                    (pwm_out                 )
);

// =====================================================================
// ★★ 2026-10-06 第四十版：H11 改接【报警蜂鸣器】—— 报警时"嘀嘀嘀" ★★
// =====================================================================
// 【用户要求】"在报警的同时蜂鸣器让它有嘀嘀嘀的声音"。
//
// 【为什么能这么做】H11 这个脚的网名本来就是 BUZZER（见 top.adc），
//   厂商的 13_music 例程（SPKER.v）就是【拿方波直接驱动这个脚】——
//   不需要 PPM/I2C 那类有源蜂鸣器协议，buzzer_beep.v 走的是同一条路。
//   上板证据：AUDIO_TEST_TONE 那一版（1kHz 经 PWM 送到 H11）用户报"它在响"
//   ⇒ 方波驱动这个脚确实能出声。
//
// 【和 HDMI 语音的关系：互不干扰】
//       HDMI 内嵌音频 → 显示器喇叭   语音播报（受 SW4 静音）
//       H11 方波      → 板载蜂鸣器   报警"嘀嘀嘀"（受 SW1 关报警声）
//   两路物理分开，只是 H11 只有一根脚，所以下面用 AUDIO_OUT_HDMI 二选一：
//     AUDIO_OUT_HDMI = 1（当前值）⇒ H11 只出蜂鸣器，语音走 HDMI；
//     AUDIO_OUT_HDMI = 0         ⇒ H11 恢复出 PWM 语音（此时就没有蜂鸣器了）。
//
// 【使能为什么用 hud_alarm】它就是 o_alarm = alarm_on & ~sw[0]（本文件 :135），
//   已被 SW1 门控 ⇒ SW1 一拨就静音，和面板 SND/ALM 两个灯与标签的语义一致。
//   SW4（MUT，"静音播报音频"）管的是语音播报、不该管报警音，所以不接它。
//
// 【音调 / 节奏】2kHz 方波，响 120ms、停 180ms（周期 300ms ⇒ 每秒 3.3 声）。
//   模块原来注释里写的是"每 1 秒响 200ms"，听感是"嘀——嘀——"，
//   改成 120/300 才是"嘀 嘀 嘀 嘀"。要调就改这两个数字，别的都不用动。
//
// 【★ 复活它必须先去掉 AutoExcluded ★】
//   buzzer_beep.v 一直躺在工程文件列表里，但带着 <Attr Name="AutoExcluded"
//   Val="true"/> ⇒ 它【根本不进 elaborate】。直接例化的话 TD 只报
//   HDL-7144 / HDL-8007（黑盒），**不当致命错误**，照样跑完 bitgen 出 bit，
//   烧上去蜂鸣器是死的（和 audio_gen.v/sin_lut.v 那次同一个坑）。
//   本次已用 tools/unexclude_src.py 把 .al + 两个 .prj 三处一起改掉。
//
// 【pwm_out 会怎样】AUDIO_OUT_HDMI 是 localparam，=1 时 pwm_out 没有消费者，
//   综合会把 u_audio_pwm（连同只服务它的 audio_gen/sin_lut/tone_div）整块裁掉
//   —— 源码还在、网表里没有。引脚配置不会丢（top.adc 里端口还在）。
wire buzzer_out;

buzzer_beep #(.CLK_HZ (50000000),      // clk = 板上 50MHz 晶振
              .TONE_HZ(2000),          // 2kHz 方波
              .ON_MS  (120),           // 每个周期响 120ms
              .PER_MS (300)            // 周期 300ms ⇒ 每秒 3.3 声
             ) u_buzzer(
    .clk      (clk),
    .rst_n    (rst_n),                 // 用 rst_n 而不是 rst_all：后者含 audio_mclk
                                       // 域的 audio_pll_lock，对 clk 是异步的，
                                       // 拿来当 clk 域复位会凭空造一条 CDC
    .alarm_on (hud_alarm),             // 已被 SW1 门控（只影响声音，不影响界面）
    .buzzer   (buzzer_out)
);

assign pwm_audio = AUDIO_OUT_HDMI ? buzzer_out : pwm_out;

// =====================================================================
// ★★ 2026-10-04 第二十版：音频链路探针（只喂数码管，不参与任何逻辑）★★
// =====================================================================
// 【为什么加】
//   卡上第一次有 WAV 文件，结果**只有底噪、没有语音**。
//   而在喇叭上，"数字侧一个样本都没送出来" / "被静音喂 0" / "模拟侧 RC 没接好"
//   这三种情况听起来【一模一样】——都是一片电流声。
//   光靠听永远分不开，必须把数字侧的中间量引到数码管上。
//
//   在这之前整条音频链在板子上【一个可读的量都没有】：
//   wav_state_code 在 top.v 里接了线，却一个数码管位都没用上。
//
// 【口径：全部是"本次 play 以来"的量】（本工程的探针铁律）
//   play = wav_play = page_chg_sd | alarm_rpt，是单拍脉冲，用它做清零沿。
//
//   D2 = ★本次 play 以来 wav_state_code 达到过的最大值 0..7★（粘滞）
//        0=空闲 1=发open 2=等open 3=发翻译 4=发扇区读 5=收字节
//        6=等播放(★正在出声★) 7=出错
//        ★ 为什么取"最大值"而不是直接显示 wav_state_code ★
//          一段 WAV 只有 2.7~5.2 秒（见下），播完 FSM 就回 A_IDLE ——
//          直接显示的话，等用户抬头看数码管早就回到 0 了，读到的永远是 0，
//          根本区分不了"播成功了"和"压根没播"。
//          取"本次达到过的最大值"就变成停车后仍然可读：
//            7 ⇒ 出过错（打开失败/头非法）
//            6 ⇒ ★进过播放态★，这时候就该有样本在流
//            4/5 ⇒ open 好了、正在读，但一直没进播放态
//            2 ⇒ 卡上根本没打开这个 WAV（文件名/目录项）
//        ★ 这条正是本工程的探针铁律：只用"粘滞/本次"量，不用瞬时量 ★
//   D3 = {!wav_err, wav_fmt_ok, wav_rate_ok, aud_mute}
//        bit3 ★取反的 err★（1 = 没出错）/ bit2 PCM+单声道+16bit 全对
//        bit1 采样率在支持表内 / bit0 ★静音标志★（SW4）
//        ⇒ ★健康值 'E' = 1110★（没出错 / 格式对 / 采样率对 / 没静音）
//          读 'D' = 只有静音那一位是 0 ⇒ SW4 在静音侧
//          读 'A' = 格式不对  读 '6'/'4'… = bit3=0 ⇒ wav_err 置位了
//        ★ err 是粘滞的（保持到下次 play），不是瞬时脉冲 ⇒ 停车后仍可读 ★
//        ★ 这一位取反是为了让"健康"仍然读作 E —— 上一版 D3 的健康值就是
//          E，换成这个探针时不该把"什么算正常"也一起改掉，会看错。★
//   D4 = ★★ 第二十四版：样本【速率】★★ = 每秒样本数 ÷ 4096，取本次 play
//        以来见过的最大值（粘滞）。**正常应读 '3'**（16000 ÷ 4096 = 3）
//          3    ⇒ 约 16kHz，速率正常
//          1    ⇒ 约 8kHz —— 只有一半！多半是 FSM 频繁离开播放态，
//                 strobe_cnt 每次被清零、够不到 6250 ⇒ sample_tick 稀疏
//          0    ⇒ 一个样本都没送进来（或稀疏到 <4096/秒）
//        ★ 为什么把旧的"个数（饱和 14）"换掉 ★
//          旧口径下 **"每秒 16000 个" 和 "整段总共只来 14 个" 读数完全一样**，
//          而 D5 只要整段被过一遍就会爬到正确峰值 —— 哪怕是以极低速率涓流。
//          ⇒ "D4=E + D5 对" 完全兼容 "样本稀疏到听不出语音"，
//            这正是第二十三版上板"三项全对却没声"时面板留下的空洞。
//          判据从"有无"改成"计数"（同 fat32-migration-status 那条教训）。
//        ★ 钳到 14 是必须的：6 位直接截成 4 位可能得 4'hF，会被熄灭 ★
//   D5 = 本次 play 以来见过的【最大 |样本|】的高 4 位
//        ★ 这是"数字侧到底有没有真音频数据"的唯一硬证据 ★
//          0     ⇒ 样本全是 0（没数据 / 读到一片零区）
//          1..8  ⇒ 真有信号，数字就是 PCM 幅度量级
//        ★ 用"最大值"而不是"瞬时值" ★
//          瞬时的样本在 16kHz 上一直在变，数码管根本读不了
//          （本工程踩过两次"瞬时量探针"的坑，见 hud_seg_data.v 头注释）
//        ★★ 注意：这里量的是【静音之前】的样本 ★★
//          也就是音频源直接吐出来的 pcm，不经过 audio_pwm 的 mute。
//          这是故意的 —— 于是 D4/D5 非零 + D3 的低位=1（静音）
//          就唯一地指向"数字侧全好，只是被 SW4 静音了"。
//
//   ★★ 第二十二版起，D4/D5 量的是【audio_pwm 真正收到的那个源】★★
//      也就是上面 aud_pcm / aud_pcm_stb（测试音固件下 = 1kHz 正弦，
//      正常固件下 = wav_pcm）。所以两种固件下面板都读得懂：
//        测试音固件：D4 **饱和在 'E'**（1.5625MHz 的样本率 ÷4096 早就爆表，
//                    被钳到 14；注意这个 'E' 是"钳位值"，不是"速率=E"），
//                    D5 恒为 **7**（LUT 峰值 32767=0x7FFF ⇒ >>12=7，不随翻页变）
//        正常固件  ：D4 应读 **3**（16kHz ÷4096）；D5 随翻页在 3/4/3/7/3/7 之间变
//                    （★2026-10-14 换卡后重测：卡上六段是新的一批素材★）
//      ★ 测试音固件下 D2（WAV 状态）仍然在动，那只是 WAV 那条链照常在跑，
//        和从 H11 出去的音无关 —— 别被它带偏。★
//
//   ★★★ 具体该读到几：我离线把六个 WAV 的 peak（最大 |样本|）量过了 ★★★
//     WAV 源文件在 sd_assets/，工具 tools/asset_info.py 能看格式。
//     D5 = (本次最大 |样本|) >> 12，而 wav_loader 会把整段 data 播完，
//     所以"本次最大 |样本|" == 这个文件的 peak。
//     ★★ 2026-10-14 换卡后重测：卡上这六段是【新的一批】素材，
//        peak 和上一批完全不同。上一批是 29490/20511/22445/11226/10318/26835
//        （对应 7/5/5/2/2/6，再往上一批是 18440/18358/15172/29829/30452/27123，
//        对应 4/4/3/7/7/6）—— 三批数字各不相同，**对不上先看是不是换过卡**。★★
//              page0 01.WAV peak=15109 → D5=3
//              page1 02.WAV peak=17851 → D5=4
//              page2 03.WAV peak=16309 → D5=3
//              page3 04.WAV peak=30996 → D5=7
//              page4 05.WAV peak=16169 → D5=3
//              page5 06.WAV peak=28914 → D5=7   ← 报警页
//        （重测方法：读 sd_assets/fat32/*.WAV 的 data 块，取 max|样本| 再 >>12；
//          卡上文件和 sd_assets/fat32/ 现在是一样的，已逐项 MD5 核对。）
//     ★ 只要数字侧通了，D5 应当是上面那一列数；恒为 0 ⇒ 样本全是 0。
//     ★★ 读数撞车的副作用，务必记住 ★★
//       现在有【三页同读 3】（page0/2/4）和【两页同读 7】（page3/5）
//       ⇒ **"翻页时 D5 必须跟着变"这条判据不再逐页成立**。
//       D5 现在只能回答"这一段到底有没有真数据"，
//       不要再拿它当"翻页/取文件链路"的判据。
//     ★★ 实测过一次"六页恒为 8" ★★（第二十版）：那**不是**"每次都打开
//       同一个文件" —— 8 只可能来自 0x8000 这一个值，而六个 WAV 在正确
//       对齐下都不含它。真因是**播放侧取字节错开了一位**（少一个相位），
//       见 src/wav_loader.v [3/3] 那段和第二十一版的修法。
//       离线复算的工具：tools/wav_align_check.py（会打印每个字节偏移下
//       各页的 D5，一眼看出"错位 ⇒ 六页全 8"这个指纹）。
// =====================================================================
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
//   D5 也会爬到正确的峰值（当时是 4/4/3/7/7/6；第二十七版归一后是 7/5/5/2/2/6；
//   2026-10-14 换卡后是 3/4/3/7/3/7）。
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
//   窗口取 0.25 秒而不是 1 秒：最短的 05.WAV 也有 3.006 秒，
//   0.25 秒能出 12 个窗口，不会出现"一个整窗都没走完"而误读 0。
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

// =====================================================================
// 音频模式：三选一（详见 hdmi_audio_tone_i2s_64fs.v 文件头）
//   TF 卡播报 > 静音（默认）；报警两音只作 bring-up 自检，见下
//
//   模式信号本身是干净的电平，再由 hdmi_audio_tone_i2s_64fs 内部 2FF
//   同步到 audio_mclk 域。不要在 sd 域直接选 M_PCM —— 这里是在 video 域里
//   用已经同步过来的 wav_active_v 算，单域。★第二十五版改动★
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

// wav_active 从 sd 域同步到 video 域（电平量，2FF 足够）
reg [1:0] wav_active_s;
always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) wav_active_s <= 2'd0;
    else            wav_active_s <= {wav_active_s[0], wav_active};
end
wire wav_active_v = wav_active_s[1];

// ---------------------------------------------------------------------
// ★第二十五版★ 音频模式
//
//   默认（ALARM_TONE_SELFTEST = 0）：
//     段播报期间 -> M_PCM（喂 TF 卡 PCM），其余 M_MUTE。
//     报警页也走 M_PCM —— 那一页 WAV 也照常按名打开从头播（见 wav_play），
//     所以故障页播的是 06.WAV，符合规格。
//
//   ★ 为什么不再让报警页抢 M_ALARM ★
//     旧版是 `hud_alarm_r ? M_ALARM : ...`，报警页会盖掉 TF 卡播报。
//     但规格要求故障页播 06.WAV，而且报警两音和 06.WAV 也【不该混着放】。
//     M_ALARM 那一路现在只当 bring-up 自检用（下面那个开关）。
//
//   ★ ALARM_TONE_SELFTEST 是零依赖自检源 ★
//     换成 1'b1 重综合，进报警页就能听到 hdmi_audio_tone_i2s_64fs 内部
//     合成的 800/640Hz 两音 —— 它不经过 TF 卡、不经过上面新增的 CDC、
//     也不经过 wav_loader。所以：
//        响   => I2S_receiver -> HDMI 核 -> TMDS -> 显示器 这条链是通的，
//                问题只会出在 CDC / I_pcm 那一小段
//        不响 => 问题在 HDMI 音频发射本身，跟本次改动无关
//     这就是"先证链路、再证数据"。平时保持 0。
// ---------------------------------------------------------------------
localparam ALARM_TONE_SELFTEST = 1'b0;

wire [1:0] audio_mode = (ALARM_TONE_SELFTEST && hud_alarm_r) ? M_ALARM
                      : (wav_active_v & ~sw_v[3])            ? M_PCM
                      :                                        M_MUTE;

// =====================================================================
// ★★ 第十九版：双缓冲 -> 六槽预载 (sd_card_clk 域) ★★
// =====================================================================
// 【为什么必须换掉双缓冲】
//   双缓冲的语义是"翻页 -> 重读一张 -> 写非显示帧 -> frame_done 翻 frame_sel"。
//   它天生带一个"读完整张图"的延迟（0.67 秒），而工况页是 FPGA 自己画的、
//   当拍就变 —— 所以底图永远追不上页。
//
// 【换成了什么】
//   上电后 u_img_slots 顺序把六个文件读进 SDRAM 的六个槽：
//       槽 k 的基址 = k * 307200（字）
//   之后翻页【不再读卡】，只把读基址指到对应槽 ⇒ 当拍同步。
//
//   写侧：write_base 由预载器推进（每落盘一张 +307200）
//   读侧：read_base = 当前页号 * 307200，但【只允许指到已就绪的槽】
//
// 【为什么读侧要钳位】
//   六张是陆续就绪的（一共约 4 秒）。这期间如果用户翻到还没加载的页，
//   直接把读地址指过去就会读到一块从没写过的 SDRAM（整屏雪花）。
//   所以用"最近一个已完整落盘的槽号"做上限。
//   ★ 这条钳位顺带保证了 read_slot < 正在写的槽 ★
//     ⇒ 读的槽和写的槽永远不是同一个 ⇒ 不可能出现旧版那种
//       "write_base 与 read_base 指向同一块"的雪花（见本文件 :171 那段）。
//
// 【时序上的好处】
//   六个槽共 1843200 字 < 2^21 = 2097152（硬核 SDRAM 是 EG_PHY_SDRAM_2M_32），
//   占 88%，不用改任何地址位宽。
//
// 【为什么 frame_done 不再参与地址】
//   frame_done = bmp_read 的 state_code 4->1，只表示"最后一个像素刚进写 FIFO"，
//   FIFO 里可能还压着几百个字。用它推进 write_base 会把残留字写进下一个槽。
//   改用 wr_frame_rise（write_finish 的翻转握手版，见本文件 POR 段之后）。
// =====================================================================
img_slots #(.FRAME_WORDS(307200)) u_img_slots(
    .clk           (sd_card_clk),
    .rst_n         (por_rst_n),
    .sd_init_done  (sd_init_done),
    .bmp_ready     (bmp_ready),
    .frame_landed  (wr_frame_rise),
    .ld_find       (img_ld_find),
    .ld_idx        (img_ld_idx),
    .write_base    (write_base),
    .shown_slot    (img_shown_slot),
    .done_cnt      (img_done_cnt)
);

// ---- img_shown_slot 跨到 video 域（3 位电平，秒级变化，两级同步足够）----
reg [2:0] shown_s1, shown_s2;
always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        shown_s1 <= 3'd0;
        shown_s2 <= 3'd0;
    end else begin
        shown_s1 <= img_shown_slot;
        shown_s2 <= shown_s1;
    end
end

// =====================================================================
// ★★ 2026-10-05 第二十七版：读基址【整条搬进 ext_mem_clk 域】★★
// =====================================================================
// 【改之前长什么样】
//       reg [2:0] read_slot;                       // video_clk 25MHz
//       assign read_base = read_slot * 24'd307200; // 组合乘法，也在 video 域
//   而 read_base 直接接进 frame_fifo_read（ext_mem_clk 125MHz）的 read_addr_0，
//   在 S_ACK 被锁进 row_base / App_rd_addr_r。
//   ⇒ 一条【24 位宽、跨时钟域、没有同步器、也没有 SDC 例外】的多位数据通路。
//
// 【为什么这正是"图上有零散噪点"的根因】
//   一个像素 = 从 SDRAM 读一个字，读哪个字完全由 App_rd_addr_r 决定。
//   这条地址总线只要某一位被采错，这一次读回来的就是【别的地址上的字】
//   ⇒ 屏幕上多一个错色像素 = 一个噪点。
//   而"哪一位会出事"由地址值决定 ⇒ 噪点位置【钉死不动】。
//
// 【证据：TD 自己的 hold-fix 日志（seed 7，就是烧到板上的那一版）】
//     Hold: WNS(ns) = -1.203, TNS(ns) = -8.780, FEP = 17
//     Stage 3 | Hold Fix
//       read_slot[0]      -> frame_fifo_read_m0/App_rd_addr_r_reg[12]  -1119ps
//       read_addr_0[13]   -> frame_fifo_read_m0/App_rd_addr_r_reg[13]   -680ps
//       read_addr_0[15]   -> frame_fifo_read_m0/App_rd_addr_r_reg[16]   -773ps
//       add3_syn_9[5]     -> frame_fifo_read_m0/App_rd_addr_r_reg[17]   -231ps
//       add3_syn_9[6]     -> frame_fifo_read_m0/App_rd_addr_r_reg[19]    -99ps
//   17 个违例端点【全部】落在这条地址通路上。TD 只能靠插 hold buffer 把它们
//   拉到 +12ps（final_timing.rpt：ext_mem_clk 的 HWNS = 0.012ns）。
//   +12ps 不是余量，是"刚好不为负"——一热、一飘就翻负 ⇒
//   错位数随时间变多 ⇒ 用户看到"警报页噪点越来越多"（那一页蹲得最久）。
//
// 【改法：只让 3 位槽号跨域，基址在目的域算】
//   源域 video_clk  ：钳出读槽号，值一变就翻 toggle
//   目的域 ext_mem_clk：3FF 同步 toggle -> 检沿 -> 锁 3 位槽号 -> 本域做乘法
//   ⇒ App_rd_addr_r / row_base 的 D 通路全部变成【本域】路径，拿到真正的
//     8ns 预算；地址也不可能被采到"一半新一半旧"的值。
//   ⇒ 跨域只剩 3 位槽号（短、慢、且由 toggle 限定），
//     已在 top.sdc 里按本工程其他几对 CDC 的同一写法声明为 false path。
//
//   ★ 时序语义没变：read_base 只在翻页那一刻变，而 S_ACK 一帧才一次，
//     锁存最多晚 3 个 ext_mem_clk(24ns)，肉眼不可见。★
// ---------------------------------------------------------------------
// 读槽：当前页号，但被"已就绪的最大槽号"钳住（见上）
//   ★ 页号可能到 5、shown_s2 最大也是 5 ⇒ 读槽号恒在 0..5 ★
//     所以 槽号*307200 最大 1536000，碰不到 2^21，不会绕回。
wire [2:0] read_slot_v = (img_idx_v <= shown_s2) ? img_idx_v : shown_s2;

// ---- 源域（video_clk 25MHz）：值变了才翻 toggle ----
reg [2:0] read_slot_vr;          // 与 read_slot_v 同值，打一拍做"变化检测"
reg       rb_tog_v;

always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        read_slot_vr <= 3'd0;
        rb_tog_v     <= 1'b0;
    end else begin
        read_slot_vr <= read_slot_v;
        // 只在值真的变了才翻：这样一次变化 = 一次 toggle 边沿，
        // 对面锁存一次，不会因为"抖动"反复锁。
        if (read_slot_v != read_slot_vr) rb_tog_v <= ~rb_tog_v;
    end
end

// ---- 目的域（ext_mem_clk 125MHz）：3FF 同步 toggle，检沿锁槽号 ----
reg [2:0] rb_tog_s;

always @(posedge ext_mem_clk or negedge por_rst_n) begin
    if (!por_rst_n) rb_tog_s <= 3'd0;
    else            rb_tog_s <= {rb_tog_s[1:0], rb_tog_v};
end

wire rb_rd_edge = rb_tog_s[2] ^ rb_tog_s[1];      // 单拍

reg [2:0] read_slot_m;           // 目的域里的槽号

always @(posedge ext_mem_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        read_slot_m <= 3'd0;
        read_base   <= 24'd0;
    end else begin
        // ★ 跨域的只有这 3 位，而且在 toggle 边沿那一拍采：
        //   read_slot_vr 每次变化都比 toggle 边沿早 ≥3 个 ext_mem_clk
        //   （同样的"数据先稳、toggle 后翻"纪律，见 top.sdc 里那段说明）★
        if (rb_rd_edge) read_slot_m <= read_slot_vr;
        // 槽基址 = 槽号 × 307200（307200 = 0x4B000）
        //   ★ 这条乘法的两端都在本域 ⇒ 是干净的 intra-domain 路径 ★
        read_base <= {1'b0, read_slot_m} * 24'd307200;
    end
end

// =====================================================================
// 数码管 D1 显示哪个状态码 ★ 读 D1 之前先看这段 ★
// =====================================================================
//   原来 D1 固定显示 bmp_read 的 state_code，而它的码很粗：
//       9 = S_OPEN / S_OPEN_W（已经在等 open_done）
//       10 = S_XL   2 = 找图中   3 = 头部匹配   11 = 等写 ack   4 = 读像素
//   看到 9 只能知道"open 没回来"；但 FAT32 内部是卡在读 MBR、读引导扇区、
//   还是读目录项 —— 一个都看不出来，而这三段的排查方向完全不同。
//
//   所以改成两段式：**open 成功走完之前**，D1 显示 fat32_reader 自己的码
//       0 = 还没初始化（sd_init_done=0）    1 = 空闲
//       2 = 在等 MBR(LBA0) 这次读           ← 连第一个扇区都没回来
//       3 = 在等引导扇区(BPB)                ← MBR 读到了，BPB 那段挂住
//       4 = 在等目录项扇区    5 = 在跟目录簇链
//       6 = open 结束（这一拍置起 fbm_open_seen）
//   **open 成功过之后**，fat32 的码就没信息量了（之后长期停在 1=S_IDLE），
//   这时自动换回 bmp_read 的码 —— 那个阶段该看的是 bmp_read 走到哪。
//
//   所以：**一上电看到的 2..6 是 fat32 的码；看到 9/10/11 则说明 open 已经成功过**，
//   现在显示的是 bmp_read 的码。
// =====================================================================
reg fbm_open_seen;

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n)                    fbm_open_seen <= 1'b0;
    else if (fat32_bmp_state == 4'd6)  fbm_open_seen <= 1'b1;
end

wire [3:0] seg_state_code = fbm_open_seen ? state_code : fat32_bmp_state;

// state_code 跨时钟域: sd_card_clk(100MHz) -> video_clk(25MHz) 两级同步。
// 只给数码管显示用（上板诊断）。它是人手速度的量，2 级同步足够。
always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        state_code_v1 <= 4'd0;
        state_code_v2 <= 4'd0;
    end else begin
        state_code_v1 <= seg_state_code;
        state_code_v2 <= state_code_v1;
    end
end

// ==================================================================
// ★ 诊断总线（2026-10-03 加）—— 只喂数码管的 D2..D5，不参与任何逻辑 ★
// ==================================================================
//   为什么需要：D1 只有一个码，而且它前面挂了个"open 成功过就切源"的二段开关，
//   最容易误读。把 fat32_reader 的状态码原样搬到 D2，就能直接看出
//   "u_fat32_bmp 到底有没有在动"：
//       1 = 空闲（说明 open 请求根本没到它）
//       2 = 在等 MBR 扇区   3 = 在等引导扇区(BPB)   4 = 在等目录项
//       5 = 在跟目录簇链    6 = open 结束
//       7 = 跟簇链检查      8 = 在等 FAT 项        9 = 翻译完成
//   ★ 2026-10-03 第二版：D3 和 D4 也接上了 ★
//     先前那版同时搬了 fbm/bmp 的 req/grant 和仲裁器状态，一共 16 位，
//     结果 TD 的 route 阶段必定崩溃（coredump，见 build_phy*.log）。
//     所以这次【只加 8 位，而且全是粘滞标志】，一位一位地加回来。
//
//   ★ 为什么必须是"粘滞"而不是实时 ★
//     fbm_req / bmp_req / sd_sec_read_data_valid 这些是 100MHz 下
//     随时在变的电平和一拍脉冲。直接送到 25MHz 域的数码管，只会得到
//     一片乱跳的鬼影，人眼一位都读不出来。
//     做成"上电以来是否发生过"，每一位就都能用眼睛读。
//
//   D3 = 粘滞版请求/授权对（十六进制）：
//     bit3 = fbm_req  图片链的 FAT 读被发起过
//     bit2 = fbm_grant 被授权过   ★ 若 bit3=1 而 bit2=0 -> 仲裁器从没授权过
//                                    -> sd_arbiter 的 active 卡死 ★
//     bit1 = bmp_req  图片数据链路要过扇区
//     bit0 = bmp_grant 图片数据被授权过
//     典型：'F' = 四条都见过（健康）
//           '8' = 只有 fbm_req 见过，从没被授权 -> 死锁
//   D4 = SD 链路（十六进制）：
//     bit3 = sd_init_done  必须为 1。为 0 说明卡在更前面，下面几位无意义
//     bit2 = 读完过至少一个扇区（粘滞）
//     bit1 = 触发过超时兜底（粘滞）★ 扇区"结束"了却一个有效字节都没有 ★
//            = sd_card_cmd.v 里新加的 S_READ_WAIT 超时真的救过场
//     bit0 = 恒 0
//     典型：'C' = 1000+0100 = init 好了、读完过、没超时  -> 链路本来正常
//           'E' = init 好了、读完过、超时过              -> 兜底在救场，卡在丢令牌
//           '8' = init 好了但一次都没读完过              -> 卡在更前面
//
//   这是 sd_card_clk 域的量，人手速度，两级同步足够（同 state_code 那条）。
// ==================================================================
// ---- D3：进度阶梯（0..5）★ 这一版的核心诊断 ★ ----
//   出图要经过一串里程碑，任何一环断了后面都不会发生。
//   与其反复猜"卡在哪一步"，不如直接读"走到了第几级"：
//     0 = 什么都没发生
//     1 = bmp_read 发起过 open 请求
//     2 = fat32 回过 open_done
//     3 = 文件真的找到了（open_done 那一拍 found=1）
//     4 = bmp_read 进入过 S_READ（开始读像素）
//     5 = frame_done 来过 ★ 一整帧完整读完 —— 到这一级屏幕就该有图了 ★
//   ★ 最大 5 ⇒ 永远不会出现 4'hF ★
//     （4'hF 会被 seg_disp_top.v 的 blank_if_ff 变成全灭，和"这位坏了"分不开）
//   多个条件同时成立时按【高的】算：下面 if 的顺序就是优先级，
//   Verilog 里同一 always 块内后面的赋值覆盖前面的。
//
//   ★★ 2026-10-04 第十六版：从"只增不减"改成【每次取图尝试重新爬】★★
//     原来它是"上电以来到过几级"，一旦到 5 就永远是 5 —— 于是"按 K2 之后
//     这一次到底走到哪一级"完全看不见，而这恰恰是现在要找的东西。现在
//     bmp_find（每次取图那一拍）把它清零重爬：
//       D3=0 → 这次取图连 open 都没发起（触发链断在 page_chg_sd 之前）
//       D3=3 → 文件找到了，但一直没进 S_READ ⇒ 死在 S_XL 翻译那一段
//       D3=4 → 进了 S_READ 但一直出不来 ⇒ 死在读扇区上
//       D3=5 → 这一帧完整读完了 ⇒ 若屏幕仍不换图，问题在【帧缓冲/视频侧】，
//              不在读卡 —— 这是一次就能分开的岔路口，所以才这么改。
//     ★ 配套：原来那个粘滞的 dg_found_seen 必须一起删 ★
//       否则 bmp_find 清零后，下一拍它又把 dg_lvl 顶回 3，等于没清。
//       第 3 级改成直接判 `bmp_open_done && bmp_found`（bmp_found 只在
//       open_done 那一拍有效），语义等价，而且天生就是"本次"的。
reg [3:0]  dg_lvl;         // D3：本次取图尝试爬到第几级
reg        dg_end_seen;    // 粘滞：见过 sd_sec_read_end
reg        dg_last_err;    // 最近一次读完的扇区是不是【零有效字节】
reg [9:0]  sd_dv_cnt;      // 本次传输累计收到的有效字节数
// ★ 第十七版：D5 从"读完几帧"改成"整帧真的写进 SDRAM 了几次"（wr_finish_raw）★
//   为什么换：现在已知"读"这条链完全正常（D3 每页都到 5、D4 健康、D2 严格等于 D0、
//   卡上六个文件确实不同），可屏幕就是不换图。于是唯一没被验证过的环节是
//   【写完到底有没有落进 SDRAM】—— `bmp_read.state_code 4->1` 只表示
//   "最后一个像素刚进写 FIFO"，FIFO 里的 256 个字可能压根没排空。
//   `wr_finish_raw`（frame_fifo_write.write_finish）只在 write_cnt 攒够
//   write_len_latch 时才拉高，而 write_cnt 只靠写突发推进 ⇒ 它是"突发机制
//   到底跑没跑"的直接证据（见本文件 :157 那段注释）。
//   判读：D3=5 而 D5=0 ⇒ 帧"读完"了却一个字节都没落盘 ⇒ 问题在写通路。
reg [3:0]  dg_wrfin_cnt;   // D5：wr_finish 累计次数（饱和在 9，不回绕）

// ★ wr_finish_raw 是【mem_clk(ext_mem_clk) 域】的信号，必须两级同步 ★
//   依据 frame_read_write.v:118 —— frame_fifo_write_m0 只接 `.mem_clk(mem_clk)`，
//   根本没有 write_clk；它的状态机（state_reg / fifo_aclr_reg）都在 mem_clk 上，
//   所以 write_finish 也在 mem_clk 域。第一次写探针时当成同域直接采样，
//   route 后立刻冒出 7 条 ext_mem_clk -> sd_card_clk 的 hold/removal 违例
//   （端点正是 dg_wrfin_cnt_reg[*]），根子就在这里。
//   ★★ 2026-10-04 第十九版：这里不再自己采窄脉冲 ★★
//     原来这两行是
//         reg [1:0] wr_fin_s;
//         wr_fin_s <= {wr_fin_s[0], wr_finish_raw};
//         wire wr_fin_rise = wr_fin_s[0] & ~wr_fin_s[1];
//     也就是"拿两级触发器去采 8ns 的脉冲"——会整次丢失（见 POR 段之后
//     wr_tog 那一段的说明）。现在改用它生成的 wr_frame_rise，
//     那个是翻转握手，漏不掉。wr_fin_rise 这个名字保留给下面两处引用。
wire       wr_fin_rise = wr_frame_rise;

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        dg_lvl       <= 4'd0;
        dg_end_seen  <= 1'b0;
        dg_last_err  <= 1'b0;
        sd_dv_cnt    <= 10'd0;
        dg_wrfin_cnt <= 4'd0;
    end else begin
        // ---------------- 进度阶梯（低 -> 高，后面的覆盖前面的）----------------
        // ★ 清零写在本块【最前面】，靠"同一 always 块内后写覆盖先写"让后面几行
        //   照常往上顶。bmp_find 与 open_req / open_done 不可能同一拍：
        //   open_req 是 bmp_read 的寄存输出，比 find 至少晚一拍。★
        if (bmp_find)                   dg_lvl <= 4'd0;
        if (bmp_open_req)               dg_lvl <= (dg_lvl < 4'd1) ? 4'd1 : dg_lvl;
        if (bmp_open_done)              dg_lvl <= (dg_lvl < 4'd2) ? 4'd2 : dg_lvl;
        if (bmp_open_done && bmp_found) dg_lvl <= (dg_lvl < 4'd3) ? 4'd3 : dg_lvl;
        if (state_code == 4'd4)         dg_lvl <= (dg_lvl < 4'd4) ? 4'd4 : dg_lvl;
        if (frame_done)                 dg_lvl <= 4'd5;

        // ---------------- SD 链路 ----------------
        // sd_dv_cnt 在【每次 sd_sec_read_end】清零，而不是靠 sd_sec_read 电平，
        // 因为连续读扇区时 sd_sec_read 会一直保持高，用低电平清零会跨传输累加。
        // 这样在 end 那一拍，sd_dv_cnt 正好等于刚结束那次传输的有效字节数。
        if (sd_sec_read_end) begin
            dg_end_seen <= 1'b1;
            dg_last_err <= (sd_dv_cnt == 10'd0);   // 本次读完但零有效字节 = 超时兜底救的场
            sd_dv_cnt   <= 10'd0;
        end else begin
            if (sd_sec_read_data_valid) sd_dv_cnt <= sd_dv_cnt + 10'd1;
        end

        // ---------------- D5：整帧写进 SDRAM 完成过几次 ----------------
        // ★ 第十七版：数 wr_finish_raw，不再数 frame_done ★
        //   两者的区别正是现在要问的问题：
        //     frame_done    = 最后一个像素【刚进写 FIFO】（bmp_read 的 4->1）
        //     wr_finish_raw = write_cnt 攒够 307200 ⇒ 突发机制真的把整帧推走了
        //   所以 D5=0 而 D3=5 ⇒ "读完了但一个字节都没落盘"。
        //   饱和在 9（9->9 不回绕），于是 D5=0 明确表示"一次都没有"。
        // ★ 第十九版：改数 wr_fin_rise（= wr_frame_rise，翻转握手版）★
        //   它同时是六槽预载器的推进条件。
        //   ★ 口径也跟着回去了：不再按 bmp_find 清零，改成【上电以来累计】★
        //     第十八版做成"每次取图清零"是对的，但那是为"翻页触发取图"设计的；
        //     现在整条链一共只有 6 次落盘（预载六张），累计值就是最直接的读数：
        //     **上电后 D5 应当从 0 一路数到 6**。若停在某个数不动，
        //     那一位就是预载卡住的那张（配合 D2 的"已落盘张数"一起看）。
        //   饱和在 9（9->9 不回绕）—— 6 < 9，所以不会饱和，看到的就是真值。
        if (wr_fin_rise) dg_wrfin_cnt <= (dg_wrfin_cnt == 4'd9) ? 4'd9
                                                                : (dg_wrfin_cnt + 4'd1);
    end
end

// ==================================================================
// ★ 2026-10-03 第七版诊断：D6 / D7 = 写数据的【前半帧 / 后半帧】按位或 ★
// ==================================================================
//   逐版排掉的过程（每一版都是上板实测）：
//     第三版 D6=7 -> 写侧确实产生了真实像素（三通道都出现过非零）
//                    ⇒ 采样、BMP 头解析、像素装配这一段是对的
//     第三版 D7=7 -> **不可信**（那是"上电以来"的粘滞或，上电头一秒显示的
//                    是一块从没写过的 SDRAM，内容本来就随机）⇒ 探针设计教训
//     第五版 D7=7 -> **精确**判据：write_finish + read_finish + frame_sel 全为真
//                    ⇒ 整帧确实写进了 SDRAM、又整帧读了出来
//     第六版      -> "已知图案"实验（把写进 SDRAM 的像素换成 R 恒 255 的
//                    红黄竖条）上板**出现竖条** ⇒
//                    **SDRAM 写 -> 读 -> video_delay -> hud_overlay -> HDMI
//                      整条通路是好的。**
//   同时卡上六张 BMP 用 tools/chk_bmp_content.py 验过：头/长度/尺寸全对、
//   亮像素占比 99.7%，不是黑图；bright 上电满档；hud_panel 背景是透明的。
//
//   ⇒ 只剩一个解释：**BMP 像素数据本身不对**。而 D3=5（整帧读完）又要求
//     ~1801 个扇区每个都吐了 512 个有效字节 ⇒ 数据是在流的。
//     两者能同时成立，只有一种情形：
//       **前半段文件读对了，后半段的簇/LBA 翻译跑偏，读到一片 0x00 空区域。**
//     全零的像素不会让 bmp_len_cnt 停住，所以"整帧读完"和"画面全黑"并存。
//
//   D6 = 本帧【前半帧】写进帧缓冲的像素里，**有没有出现过 R>=32 的像素**（0/1）
//   D7 = 本帧【后半帧】同样的问题（0/1）
//     标定（直接统计 sd_assets/img0.bmp）：
//       R 通道平均 23.0，**P(R>=32) = 11%**（33773 个像素，铺满整幅图）
//       ⇒ 真图：两个半帧都必然是 1
//       ⇒ 近乎全黑的重复数据：一个都没有，是 0
//     读法：D6=1 且 D7=1 -> 写进去的确实是这张图（有 11% 的亮像素）
//           D6=1 且 D7=0 -> **后半段写进去的是暗数据** ⇒ LBA/簇链中途跑偏 ★
//           D6=0         -> 连前半段都是暗的
//   ★ 为什么不用"按位或"也不用"累加求和"：见下面代码里的说明。
//     按位或太弱（黑数据也能点亮）；累加求和会把 125MHz 那条擦边路径顶翻。★
// ==================================================================
// ---- SDRAM 侧里程碑：先在 ext_mem_clk 域做成粘滞，再同步到 sd_card_clk ----
//   write_finish / read_finish 在 125MHz 下都只有【一拍】宽，
//   直接拿两级触发器去采会丢。先在本域做成"上电以来是否发生过"的电平，
//   电平的 0->1 跳变只发生一次，任何同步器都不会漏。
reg wr_fin_seen, rd_fin_seen;
always @(posedge ext_mem_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        wr_fin_seen <= 1'b0;
        rd_fin_seen <= 1'b0;
    end else begin
        if (wr_finish_raw) wr_fin_seen <= 1'b1;
        if (rd_finish_raw) rd_fin_seen <= 1'b1;
    end
end

reg wr_fin_s1, wr_fin_s2, rd_fin_s1, rd_fin_s2;
always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        wr_fin_s1 <= 1'b0; wr_fin_s2 <= 1'b0;
        rd_fin_s1 <= 1'b0; rd_fin_s2 <= 1'b0;
    end else begin
        wr_fin_s1 <= wr_fin_seen; wr_fin_s2 <= wr_fin_s1;
        rd_fin_s1 <= rd_fin_seen; rd_fin_s2 <= rd_fin_s1;
    end
end

// =====================================================================
// D6 / D7：★ 判决性探针（第十版）—— 测显示端，不测写端 ★
// =====================================================================
// 【为什么要整块换掉】
//   前九版探针测的全是【写侧】——"写进帧缓冲的数据亮不亮"。
//   第七版（按位或）读到 7/7，第九版（R>=32）读到 1/1，都回答"亮"。
//   可屏幕仍然是黑的。
//
//   ★ 关键：写侧和显示端读的是【两个不同的缓冲区】★
//       write_base = frame_sel      ? 0 : FRAME_WORDS
//       read_base  = frame_sel_v    ? FRAME_WORDS : 0
//     两者永远相差一个缓冲区（这正是双缓冲该有的样子：写非显示帧、
//     显示上一帧写好的帧）。所以"写进去的数据是亮的"**推不出**
//     "屏幕上那张是亮的" —— 显示端看的是**上一帧**写完的那块。
//     如果帧从来没读完过一次（frame_done 不来），frame_sel 永远是 0，
//     显示端就一直读【从没被写过的】buffer A：黑屏，而写侧一路都是亮的。
//     ⇒ 这就是"写侧证据全对、屏幕全黑"唯一自洽的解释，所以这一版直接测显示端。
//
// 【测什么】
//   v_last      = 上一整帧（DE 期间）在 vout_data_raw 上见过 R>=32 的像素吗
//                 vout_data_raw 就是 video_delay 的输出，中间只隔一句
//                 `assign vout_data = vout_data_raw;` 直通，所以它是
//                 "屏幕上到底有没有图"的直接证据，没有任何中间假设。
//   frame_sel_v = 显示端此刻在读哪个缓冲区（= read_base[18]，1 就是 buffer B）
//
// 【读法】
//   D6 = 叠加层【输出】侧(hud_rgb -> HDMI)亮像素个数的高 4 位
//   D7 = 叠加层【输入】侧(vout_data_raw)亮像素个数的高 4 位
//        ★ 两边用完全相同的判据，所以这两个数可以直接 A/B 对比 ★
//
//   D6  D7  含义
//   8   8   两头一样 ⇒ 底图确实被送进 HDMI 核了
//            ⇒ **问题在 HDMI 核 / PHY / 显示器那一段**，与叠加层无关
//   0   8   ★ **hud_overlay 把底图吃掉了** ★
//            ⇒ 叠加层内部的问题（面板/表盘/趋势某一层的 alpha 盖住了全屏）
//   0   0   叠加层输入侧也是空的 ⇒ 回到帧缓冲/读回那条链去查
//   其他    中间值 ⇒ 叠加层只盖掉了一部分
//
//   ★ 标定（DE 期间 R>=32 的像素个数，整帧 307200 个像素）：
//     真图铺满整帧：11% × 307200 = 33792 = 0x8400 → 高 4 位 = 8
//     只写 1/4 帧：8448 ≈ 0x2100 → 2     只写 1/8 帧：4224 ≈ 0x1080 → 1
//   ★ 为什么不用"有没有"：第十版的 v_last 是一位，**一个亮像素就能点亮**，
//     分不开"整幅图都在"和"只写了一小块"。踩过两次的坑，不再踩第三次。
//
// 【为什么顺便把探针从 sd_card_clk 搬到 video_clk】
//   前几版把 19 位计数器放在 100MHz 域，两次把 125MHz 域压到负余量
//   （-194ps / -226ps，各 2 个失败端点，两次都被我拦下没出）。video_clk
//   只有 25MHz，三个触发器加一个比较器不可能影响任何时序。
//   ★ 所以这一版同时是"把探针负担移出紧时序域"的修复 ★
// =====================================================================
// ★ 第十一版：判据从"有没有"升级成"有多少" ★
//   第十版的 v_last 是 1 位"见过 R>=32 没有" —— **一个亮像素就能点亮它**，
//   所以它无法区分"整幅图都在"和"只写了一小块"。这正是我自己记在
//   [[fat32-migration-status]] 里的教训（按位或判据太弱，踩过两次）。
//   换成**饱和计数器**，D6 直接给数量级：
//
//     标定（DE 期间 R>=32 的像素个数，整帧 307200 个像素）：
//       真图铺满整帧：11% × 307200 = **33792 = 0x8400** → 高 4 位 = **8**
//       只写了 1/4 帧：8448 ≈ 0x2100                          → **2**
//       只写了 1/8 帧：4224 ≈ 0x1080                          → **1**
//       只落下几百个像素 / 基本没写                            → **0**
//       整屏纯白（会饱和）：                                   → **E**
//
//   ⇒ D6 = 8 说明**整幅图确实在显示端那块缓冲区里**；
//     D6 = 0~2 说明**只写进去了一部分**，屏幕当然看着是黑的。
//   这一版不再需要任何推理，读一个十六进制数就有结论。
// ---- 输入侧：hud_overlay 的输入（vout_data_raw）----
//   上板实测 D6=8 ⇒ 这里是 33792 个亮像素 ⇒ 整幅图都在。
reg [15:0] vb_cnt;    // 本帧 DE 期间 R>=32 的像素个数（饱和在 65535）
reg [15:0] vb_hold;   // 上一帧的终值（在 VS 处锁存，稳定保持一整帧）
reg        vs_dv;

always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        vb_cnt  <= 16'd0;
        vb_hold <= 16'd0;
        vs_dv   <= 1'b0;
    end else begin
        vs_dv <= vs;
        if (vs & ~vs_dv) begin           // VS 上升沿 = 新一帧开始
            vb_hold <= vb_cnt;           // 上一帧的终值挪进稳定那一格
            vb_cnt  <= 16'd0;
        end else if (de && (vout_data_raw[23:16] >= 8'd32) && (vb_cnt != 16'd65535)) begin
            vb_cnt <= vb_cnt + 16'd1;
        end
    end
end

// ---- 输出侧：hud_top 出去的 hud_rgb / hud_de ----
//   ★ 这两根线就是【真正送进 HDMI 核】的那一对 ★（top.v 里
//     video_rgb_to_axis 的 .I_rgb(hud_rgb) / .I_de(hud_de)）。
//   和输入侧用【完全相同】的判据，就是为了做一次干净的 A/B：
//     两头都是 8  → 底图确实被送进了 HDMI ⇒ 问题在 HDMI 核/PHY/显示器
//     输入 8、输出 0 → **hud_overlay 把底图吃掉了** ⇒ 问题就在叠加层
reg [15:0] hb_cnt;
reg [15:0] hb_hold;
reg        hvs_dv;

always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        hb_cnt  <= 16'd0;
        hb_hold <= 16'd0;
        hvs_dv  <= 1'b0;
    end else begin
        hvs_dv <= hud_vs;
        if (hud_vs & ~hvs_dv) begin
            hb_hold <= hb_cnt;
            hb_cnt  <= 16'd0;
        end else if (hud_de && (hud_rgb[23:16] >= 8'd32) && (hb_cnt != 16'd65535)) begin
            hb_cnt <= hb_cnt + 16'd1;
        end
    end
end

// ★ 4'hF 会被 seg_disp_top.v 的 blank_if_ff 显示成【全灭】，和"这位坏了"分不开 ★
//   所以把饱和值的最高半字节钳到 E。真图的 8 不受影响。
wire [3:0] d6_raw = hb_hold[15:12];                          // 输出侧（HDMI 入口）
wire [3:0] d6_val = (d6_raw == 4'hF) ? 4'hE : d6_raw;
wire [3:0] d7_raw = vb_hold[15:12];                          // 输入侧（叠加层入口）
wire [3:0] d7_val = (d7_raw == 4'hF) ? 4'hE : d7_raw;

// D5..D0 仍然来自 sd_card_clk 域（和之前一样），只是缩成 16 位。
// ★ 2026-10-04 第十六版：改成"按一次 K2 就能定性"的四组 ★
//   第十五版把 D2 放 fat32_bmp_state、D5 放"最近一秒读完成几个扇区"，
//   但两处都有毛病：
//     (a) fat32_bmp_state 是【瞬时】量，机器停下来之后它回到空闲，读到的
//         是停车后的值，不是出事那一刻的值 —— 而事故是瞬时的，抓不住。
//     (b) D5 数的 sd_sec_read_end 是【整条 SD 总线】的，而按 K2 会顺带触发
//         WAV 播报（wav_play = page_chg_sd | alarm_rpt），音频读扇区一样计入。
//         所以"D5 跳一下 7 再归 0"很可能只是音频读完了，跟底图没关系；
//         而且它 9->0 回绕，"读了 7 个"和"读了 17 个"长得一样。
//   ⇒ 全部换成【粘滞 / 本次】的量，停车后仍然可读：
//     D2 = bmp_file_idx   本次实际请求的文件号 0..5（0=01.BMP … 5=06.BMP）
//                         ★ 它不等于 D0(disp_page) 就说明"页->图"这条链断在
//                           跨域那一段（img_idx_sd / page_chg_sd），与读卡无关 ★
//     D3 = dg_lvl         本次取图爬到第几级 0..5，见上面那段说明
//                         ★ 3=找到文件但没进 S_READ；4=进了 S_READ 出不来；
//                           5=这一帧读完整了 ⇒ 该去查帧缓冲/视频侧，不是读卡 ★
//     D4 = {wr_finish_seen, dg_end_seen, dg_last_err, 1'b0}
//                         bit3=1 ⇒ ★整帧真的写进过 SDRAM★（wr_finish_raw 见过）
//                         bit2=1 ⇒ 读完过至少一个扇区
//                         bit1=1 ⇒ 最近一次"读完"是【零有效字节】
//                         ★ 健康值 'E'(1110)；bit3=0（读得到 '6'/'4'/'2'）就说明
//                           帧读完了却没落盘 —— 那就是现在要找的东西 ★
//     D5 = dg_wrfin_cnt   wr_finish_raw 累计次数 0..9，饱和不回绕
//                         ★ 0 ⇒ 本次上电从没把一整帧推进 SDRAM ★
//                         ★ 与 D3 对照：D3=5 而 D5=0 = 读完不落盘 ★
//   ★ 四个 nibble：D2 0..5、D3 0..5、D4 见上、D5 0..9，都碰不到 4'hF ★
// ★★ 2026-10-04 第十八版：D2 换成【当前打开文件的起始簇】低 4 位 ★★
//   为什么换：
//     D0(界面号) → 请求的图号 → fat32 按名扫描目录项 → first_cluster
//     → 翻译出的扇区 → 像素 → 帧缓冲。前面几环都实测对了：图号严格等于 D0、
//     每页 D3=5（读完）、D4 bit3=1（落盘）。唯独"目录扫描到底命中了哪个文件"
//     这一环从没被验证过 —— 而它正好能解释"每页都读完、都落盘、图却不变"。
//   first_cluster 是它的直接证据：六个 BMP 各占约 226 个簇、顺序分配，
//   起始簇相差 226 的整数倍 ⇒ **低 4 位相差 2 的整数倍，六个文件互不相同**。
//     ★ 它随翻页而变 ⇒ 每次确实打开了不同的文件，这条链全对
//       它恒定不变 ⇒ 目录扫描每次命中同一个文件 ⇒ 那就是病根 ★
//   ★ 为什么只用 4 位：D3 还得留着 dg_lvl（一去掉它就没人用了，综合会直接
//     把它裁掉，反而改变网表）。这一版刻意保持"改动最小"，就是为了不把
//     时序推过线（前两版因为多几个触发器各白烧一次）★
// ★★★ 拼接的总宽必须是 16 —— 少一位会让【整条诊断总线整体左移一位】★★★
//   第十九版第一次上板就是这个病：D2 本来要放 img_done_cnt(3 位)，
//   而 dg_lvl 是 4 位，于是我写的拼接只有 15 位，赋给 [15:0] 时高位补 0，
//   结果是 dg_lvl 的最低位挤进了 D2 的最高位：
//       D2 读到 'E' = {dg_lvl[0]=1, img_done_cnt=110} —— 看着像"预载没动"，
//       其实 img_done_cnt 已经是 6（六张全落盘），是面板在说谎。
//   三个数同时偏移一位就是它的指纹：
//       D2 = E(应为 6)  D3 = 2(应为 5=0101)  D5 = 3(应为 6=0110)
//   ⇒ 通用判据：**拼接表达式的宽度要一位一位数一遍，或者干脆给每段
//     显式补零（{1'b0, x}）**，别指望工具报错 —— 它只会静默补零。
//     同类教训见 [[cdc-multibit-width]]（那里是移位链被截断，这里是拼接少一位）。
// ★★ 第二十版：D2..D5 全部换成【音频链路】的量 ★★
//   第十九版那四个（预载张数 / 取图进度 / 写-读状态 / 落盘帧数）已经把
//   "六图预载"那条链验完了（D2 曾读 'E' = 其实已经是 6，是拼接少一位，
//   已修）。现在要查的是音频，而音频链在板子上原本【一个可读量都没有】。
//   旧的那几个寄存器（dg_lvl / dg_wrfin_cnt / img_done_cnt / dg_end_seen /
//   dg_last_err）不再被引用，综合会把它们和它们对应的逻辑裁掉 —— 这是预期的。
//   ★ 拼接总宽仍然是 16 位（4 个 nibble），别再少写一位 ★
//     （第十九版就是因为 img_done_cnt 少写一位，整条总线整体左移）
wire [15:0] diag_sd = {wav_mag_max[15:12],                            // D5 本次最大|样本|的高4位
                       rate_max,                                      // D4 ★第二十四版★ 每秒样本数÷4096 0..14（16kHz 读 3）
                       ~wav_err, wav_fmt_ok, wav_rate_ok, aud_mute,   // D3 健康'E'=没出错/格式对/采样率对/没静音
                       wav_st_max};                                   // D2 本次到达过的最大状态 0..7

// D7 / D6 —— 视频域自己的量：两个计数器的最高半字节（A/B 对照，见上）
wire [7:0] diag_vid = {d7_val,   // D7 = 叠加层【输入】侧(vout_data_raw)亮像素个数高 4 位
                       d6_val};  // D6 = 叠加层【输出】侧(hud_rgb 送 HDMI)同口径个数高 4 位

// ★ 两个域不能混在一条总线里过同步器 ★
//   diag_sd 在 sd 域产生，走两级同步到 video 域；
//   D7/D6 本来就在 video 域，合并放在【同步之后】那一拍拼上去，天然安全。
reg [15:0] ds1, ds2;
reg [23:0] diag_v2;

always @(posedge video_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        ds1     <= 16'd0;
        ds2     <= 16'd0;
        diag_v2 <= 24'd0;
    end else begin
        ds1     <= diag_sd;
        ds2     <= ds1;
        diag_v2 <= {diag_vid, ds2};
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
    .diag         (diag_v2),
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

// ================= 报警蜂鸣器：第四十版【重新启用】=================
// 板上 BUZZER = H11（top.adc 里这个脚的网名本来就是 BUZZER）。
//
// 沿革：buzzer_beep(u_buzzer) 曾在第二十五版被整块删除 —— 当时是为了把
//   "语音"从 H11 挪到 HDMI，免得那颗拆不掉的蜂鸣器干扰判断。
// 第四十版按用户要求把它请回来，但【只当报警蜂鸣器】，不再承担语音：
//   · 例化在文件上半部分 audio_pwm 后面（u_buzzer：2kHz 方波、响 120ms 停 180ms）
//   · 使能 hud_alarm（已被 SW1 门控）⇒ 报警时"嘀嘀嘀"，SW1 一拨就静音
//   · 语音照旧只走 HDMI（AUDIO_OUT_HDMI = 1）
//   ★ 复活它【必须先把 buzzer_beep.v 的 AutoExcluded 去掉】，否则 TD 只报
//     黑盒、不当致命错误、照样出 bit，烧上去蜂鸣器是死的 ★
//     本次已用 tools/unexclude_src.py 把 .al + 两个 .prj 三处一起改掉。

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
//
// ★★ ROW_REVERSE 最终定在 1 ★★（2026-10-03 晚）
//
//   整条通路的行序【只由这一个参数决定】，把四个环节串起来就能推死：
//     · bmp_read.v:199  header_match = ('B')&&('M')&&(width==640)
//                       —— 【不看 height 的符号】，像素按文件字节顺序线性搬运
//     · bmp_read.v:204  bmp_data_valid = pixel_offset <= cnt < file_len（纯数字节）
//     · frame_fifo_write 纯计数，地址线性递增
//     · frame_fifo_read  0 = 线性 +1（:183）；1 = 从最后一行起逐行递减（:151/:171）
//     · 显示侧从读 FIFO 按光栅顺序取 ⇒ 帧缓冲低地址 = 屏幕上方
//   ⇒ 文件第 0 行会落到屏幕最上面。标准 BMP 第 0 行是【图像底行】，
//     所以要 1（倒序读）才对得上。
//
//   ★ 中间一度改成 0，理由是"上板实测倒了"。那次观察到的是真的，
//     但据此改这个参数是【错的方向】—— 现在用 0 上板仍然倒。
//     0 的正确含义是"帧缓冲低地址对应文件第 0 行"，而文件第 0 行是图像【底】行，
//     所以 0 必然倒；这件事不需要上板就能定。
//   ★ 配套铁律：ROW_REVERSE 的值 和 【素材的行序】是一对，只能一起改 ★
//        (bottom-up 素材 + ROW_REVERSE=1)  ← 现在这套，也是 BMP 的标准写法
//        (top-down  素材 + ROW_REVERSE=0)
//     只改一边的结果就是图像上下颠倒。
//     tools/real_assets.py 是按 bottom-up（biHeight=+480）写的，别改回去。
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
    .read_finish                (rd_finish_raw            ),
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
    .write_finish               (wr_finish_raw            ), //诊断：整帧写进SDRAM完成
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
// ★第二十五版：这是本设计【唯一的音频输出通路】★
//   I_pcm 由 pcm_data 驱动 —— 它是 sd 域 wav_pcm 经过上面那段
//   "HDMI 内嵌音频：跨域"CDC 同步到 audio_mclk 域的稳定寄存器。
//
//   模块仍保留三个档（详见 hdmi_audio_tone_i2s_64fs.v 文件头）：
//     0 静音 / 1 TF 卡 PCM / 2 报警两音（800/640Hz，内部合成）
//   由 I_mode 选。本版正常工作只用 M_MUTE 和 M_PCM（见 audio_mode）；
//   M_ALARM 只被 ALARM_TONE_SELFTEST 那个自检开关用到。
//
//   频率关系（不需要额外做重采样，见文件头"为什么不用做 3 倍保持"）：
//     模块每帧边界采一次 I_pcm（帧率 = audio_mclk/256 = 48027.7Hz），
//     而 I_pcm 由 16kHz 自由运行地更新 => 零阶保持重采样，音高不变。
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
    // 本版不用请求语义：pcm_data 是自由运行的（CDC 由 wav_pcm_stb 驱动），
    // 模块每个帧边界直接采它。留空不接，不动机器生成的核。
    .O_pcm_req                 (                        ),
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
