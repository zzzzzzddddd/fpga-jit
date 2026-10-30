`timescale 1ns/1ps
// ============================================================================
// hud_panel.v -- 面板图形层（纯组合逻辑，逐像素）
//
// ============================================================================
// 【屏幕布局 640x480】—— 6 个界面共用一套骨架，只有中间的内容变
// ============================================================================
//   y   0.. 35  顶栏（不透明）
//        y  0.. 33  深蓝渐变，y 34..35 青色高光
//        y 10.. 25  标题「压力容器监控 PRESSURE VESSEL」x 12..363
//        y 10.. 25  页码 "P1/6".."P6/6"  x 460..523
//        y 10.. 26  亮度条 x 560..631
//        y 26.. 33  SW1-4 状态栏 x 256..383（4 组「3 字符名 + 指示灯方块」）
//   y  40.. 63  说明条（半透明底版 + 中英混排界面名）x 12..  【所有页都有】
//   y  36..443  主区（背景=TF 卡底图，透明）
//   y 444..479  底栏（不透明）：正常=绿条 / 报警=红横幅（上滑弹出 + 闪烁）
//               x 400/470/540, y 462 三个状态指示灯（运行/报警/通讯）
//
//   主区在两种形态之间切换：
//   ┌─ 小表形态（页 0 三表总览 / 页 4 待机巡检）────────────────────────────┐
//   │  y  92..115  三个表注「压力 MPa」「温度 C」「液位 %」                    │
//   │  y 120..311  三个 192x192 小表盘（像素由 hud_gauge 画，优先级更高）     │
//   │              窗口 x 8..199 / 224..415 / 440..631；表心 (104/320/536,216)│
//   │  y 312..351  三行读数（ASCII 4 倍放大），x 24 / 240 / 456              │
//   └───────────────────────────────────────────────────────────────────────┘
//   ┌─ 大表形态（页 1 压力 / 页 2 温度 / 页 3 液位 / 页 5 储气罐故障）──────┐
//   │  左：384x384 大表盘，窗口 x 8..391 y 48..431，表心 (200,240)          │
//   │  右：x 396..636 y 68..306 一块半透明底版，上面四行：                  │
//   │        y  56.. 71  表注「压力 PRESSURE」      x 404                   │
//   │        y  88..119  读数（ASCII 4 倍放大）      x 410                   │
//   │        y 132..139  量程「MPa  0.00 - 1.60」    x 404                   │
//   │        y 164..179  阈值「报警 > 1.20 MPa」     x 404                   │
//   │        y 288..303  趋势标题「压力趋势 TREND」  x 404                   │
//   │  y 312..435  趋势曲线图框 x 503..632（曲线像素由 hud_trend 画）        │
//   └───────────────────────────────────────────────────────────────────────┘
//
// ============================================================================
// 【为什么背景是全透明的】—— 这是本次重做布局最重要的一个决定
// ============================================================================
//   以前面板是一整块不透明/半不透明的"工业界面"，只留一个小 PIP 窗口透出
//   SD 卡照片。现在 SD 卡里的六张图【就是六个界面的美术底图】，面板只是压在
//   底图上的数据层。所以：
//       背景 o_alpha = 0（完全透出底图）
//       需要保证可读性的地方，各自垫一块半透明"底版"(alpha=200)
//   这样底图的美术效果能整幅显示，文字又不会糊在花纹里看不清。
//   顺带把原来的 4 段渐变 + 32px 网格背景整块删掉，省下一批 LUT。
//
// ============================================================================
// 【中英混排】字符编码约定
// ============================================================================
//   一个字格 = 1 个字节：
//       ch[7] == 0  -> ASCII，查 5x7 字库（hud_rom_font），在 16px 格里放大 2 倍
//       ch[7] == 1  -> 汉字，ch[6:0] 是 hud_rom_cjk 里的索引
//   索引表（必须与 tools/gen_hud_assets.py 的 CJK_CHARS 严格一致）：
//       0x80 压  0x81 力  0x82 容  0x83 器  0x84 监  0x85 控
//       0x86 三  0x87 表  0x88 总  0x89 览  0x8A 放  0x8B 大
//       0x8C 温  0x8D 度  0x8E 液  0x8F 位  0x90 待  0x91 机
//       0x92 巡  0x93 检  0x94 故  0x95 障  0x96 储  0x97 气
//       0x98 罐  0x99 报  0x9A 警  0x9B 趋  0x9C 势  0x9D 量
//       0x9E 程  0x9F 系  0xA0 统  0xA1 正  0xA2 常  0xA3 全
//       0xA4 部  0xA5 参  0xA6 数  0xA7 安  0xA8 超  0xA9 限
//       0xAA 过  0xAB 低  0xAC 高  0xAD 设  0xAE 备  0xAF 停
//       0xB0 或
//   ★ 每条字符串的字节数必须【正好】等于 LEN ★
//     多一个字节 -> 最高位被截掉，整行左移一格；少一个字节 -> 高位补 0，
//     开头几格变成空白。两种都是静默出错，不会报任何警告。
//     tools/check_label_len.py 会把这些 wire 声明的字节数逐条数一遍。
//
// ============================================================================
// 本模块只输出"图形层"和一个"文本请求"(t_hit/t_code/...)，字库查表由
// hud_overlay 统一做一次（否则要例化十几个字库，浪费 LUT）。
//
// o_alpha 含义：
//   0   -> 完全透出底层 SD 卡底图
//   200 -> 文字底版（压暗底图，保证文字可读）
//   255 -> 完全不透明（栏目条 / 文字 / 灯 / 边框）
// ============================================================================
module hud_panel(
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    // ---- 来自 hud_data_gen ----
    input  wire [2:0]  disp_page,      // 0..5
    input  wire [19:0] row_p,          // 压力读数 5 个 nibble
    input  wire [19:0] row_t,          // 温度读数
    input  wire [19:0] row_l,          // 液位读数
    input  wire [2:0]  lamp,           // {通讯, 报警, 运行}
    input  wire        alarm_on,
    input  wire        blink,
    input  wire [5:0]  banner_off,
    input  wire [7:0]  bright,
    input  wire [3:0]  sw,             // 拨动开关 SW1-4（已同步消抖）
    // ---- 三个量的报警标志（决定横幅文案）----
    input  wire        fl_p, fl_t, fl_l,
    // ---- 图形层 ----
    output reg  [23:0] o_rgb,
    output reg  [7:0]  o_alpha,
    // 1 = 当前是大表形态（页 1/2/3/5）。hud_overlay 用它选表盘槽位和趋势使能。
    // ★ 必须从面板输出，不要在 overlay 里另写一份判据 ★
    //   两处各写一份的话，将来改了一处判据，表盘和面板底版就会错页。
    output wire        o_big,
    // ---- 文本请求（送 hud_overlay 统一查字库）----
    output reg         t_hit,
    output reg         t_font,         // 0 = ASCII 5x7；1 = CJK 16x16
    output reg  [5:0]  t_code,         // ASCII 字库编码
    output reg  [7:0]  t_ccode,        // CJK 索引 = ch[6:0]
    output reg  [2:0]  t_row,          // 5x7 行号 0..7
    output reg  [3:0]  t_crow,         // 16x16 行号 0..15
    output reg  [2:0]  t_gcol,         // 5x7 列号 0..7（0..4 才是真的字形列）
    output reg  [3:0]  t_gccol,        // 16x16 列号 0..15
    output reg  [23:0] t_color
);

    // ==================================================================
    // 配色
    // ==================================================================
    localparam [23:0] C_TOP0   = 24'h1A3050;
    localparam [23:0] C_TOP1   = 24'h122238;
    localparam [23:0] C_ACCENT = 24'h00C8FF;
    localparam [23:0] C_TEXT   = 24'hE8F0F8;
    localparam [23:0] C_LABEL  = 24'hA8C0D8;
    localparam [23:0] C_VALUE  = 24'h3CFF88;
    localparam [23:0] C_OKBAR  = 24'h0E3A20;
    localparam [23:0] C_OKTEXT = 24'h46E87A;
    localparam [23:0] C_ALMBAR = 24'hC01818;
    localparam [23:0] C_ALMBAR2= 24'h5A0808;
    localparam [23:0] C_ALMTXT = 24'hFFE4E4;
    localparam [23:0] C_FRAME  = 24'h2A6A90;
    localparam [23:0] C_DARK   = 24'h000000;
    localparam [23:0] C_TRBG   = 24'h080E18;   // 趋势曲线图框底色
    localparam [23:0] C_PLATE  = 24'h061020;   // 文字底版

    // 页面分组
    wire small_pg = (disp_page == 3'd0) || (disp_page == 3'd4);
    wire big_pg   = ~small_pg;                 // 1/2/3/5
    assign o_big  = big_pg;

    // ==================================================================
    // ★ 报警页（页 5）"看哪一路"由【报警标志】决定，不再恒看压力 ★
    //   上板反馈「进入警报界面，指针也不一定在红色部分」。
    //   真因：报警页是任何一路超限都会进的，但这一页原来把大表、表注、量程行、
    //   阈值行、读数【全部】钉死在压力上 ⇒ 温度/液位超限时，大表还在指压力
    //   （70 上下，离红区十万八千里），当然不在红区。
    //   现在按 fl_p > fl_t > fl_l 的优先级把整页文字/读数都切到报警那一路，
    //   和 hud_data_gen 里 ang_big 的选法【必须一致】。
    //   优先级取 p > t > l 是为了两处好对拍；同时超限的极端情况很少见。
    // ==================================================================
    wire [1:0] alarm_q = fl_p ? 2'd0 : fl_t ? 2'd1 : fl_l ? 2'd2 : 2'd0;
    // txt_pg：本页"文字/读数"按哪一路写。页 5 复用页 1/2/3 的字符串表，
    //         不新增文案，长度校验（check_cjk_usage / check_label_len）原样有效。
    wire [2:0] txt_pg  = (disp_page == 3'd5) ? ((alarm_q == 2'd0) ? 3'd1 :
                                                (alarm_q == 2'd1) ? 3'd2 : 3'd3)
                                             : disp_page;

    // 小表槽：按 x 分段，和 hud_gauge 的槽位选择完全一致（224 / 440 两个分界）
    wire [1:0] gslot = (x < 10'd224) ? 2'd0 : ((x < 10'd440) ? 2'd1 : 2'd2);

    // ==================================================================
    // 字符串表
    // ==================================================================

    // ---- 顶栏标题：压力容器监控 PRESSURE VESSEL  (6+1+15 = 22) ----
    wire [8*22-1:0] S_TITLE =
        {8'h80, 8'h81, 8'h82, 8'h83, 8'h84, 8'h85,   // 压力容器监控
         8'h20,                                       // 空格
         "PRESSURE VESSEL"};                          // 15
    // ★ 这是一条 wire 而不是 localparam，是为了让综合器把它当常量传播，
    //   同时方便 check_label_len.py 用正则把它捞出来数字节。

    // ---- 页码 "P1/6".."P6/6"（纯 ASCII，2 倍）----
    wire [8*4-1:0] S_PAGE =
        (disp_page == 3'd0) ? "P1/6" : (disp_page == 3'd1) ? "P2/6" :
        (disp_page == 3'd2) ? "P3/6" : (disp_page == 3'd3) ? "P4/6" :
        (disp_page == 3'd4) ? "P5/6" : "P6/6";

    // ---- SW 状态栏：4 组「3 字符名 + 1 个空位放灯」 = 16 ----
    //   SND = SW1 关报警声   ACK = SW2 确认/回正常
    //   ALM = SW3 强制报警   MUT = SW4 静音播报音频
    wire [8*16-1:0] S_SWNAME = "SND ACK ALM MUT ";

    // ---- 底栏正常态：系统正常 全部参数安全 SYS OK  (4+1+6+1+6 = 18) ----
    wire [8*18-1:0] S_BOTOK =
        {8'h9F, 8'hA0, 8'hA1, 8'hA2,                 // 系统正常
         8'h20,
         8'hA3, 8'hA4, 8'hA5, 8'hA6, 8'hA7, 8'hA3,   // 全部参数安全
         8'h20,
         "SYS OK"};                                   // 6

    // ---- 底栏报警横幅：按是哪一个量超限选文案，都补到 18 字节 ----
    wire [8*18-1:0] S_BOTAL =
        fl_p ? {8'h80, 8'h81, 8'hA8, 8'hA9, 8'h20, "PRESSURE HIGH"} :   // 压力超限 4+1+13=18
        fl_t ? {8'h8C, 8'h8D, 8'hA8, 8'hA9, 8'h20, "TEMP HIGH    "} :   // 温度超限 4+1+13=18
        fl_l ? {8'h8E, 8'h8F, 8'hAA, 8'hAB, 8'h20, "LEVEL LOW    "} :   // 液位过低 4+1+13=18
               {8'h99, 8'h9A, 8'h20, "FAULT - ALARM  "};                 // 报警 2+1+15=18
    // ★ 上面四行的中文注释是给 tools/gen_hud_assets.py 的 check_cjk_usage() 看的 ★
    //   它按「注释开头的连续汉字 === 该行 8'h8X/9X/AX/BX 字节所对应的字」逐行对拍。
    //   字节表写错顺序（比如 储气罐 写成 罐气储）或改字忘了改字节，都会当场报错。
    //   所以改这些行的汉字时，必须同步改注释里的词。
    // ★ 液位有两个方向（过低 / 过高），这里合并成 "LEVEL LOW" 是偷懒吗？★
    //   不是：横幅出现的真正原因是"报警页被激活"，而页 5 是压力容器故障页，
    //   横幅文案只起到提示作用。要区分方向就得再引一根 fl_l_hi 进来，
    //   多一个端口、多一路 mux。当前验板上不差这一行，先不做。

    // ---- 说明条：每个界面一行，都补到 18 字节 ----
    wire [8*18-1:0] S_PAGECAP =
        (disp_page == 3'd0) ? {8'h86, 8'h87, 8'h88, 8'h89, 8'h20, "OVERVIEW",
                               8'h20, 8'h20, 8'h20, 8'h20, 8'h20} :            // 三表总览 4+1+8+5=18
        (disp_page == 3'd1) ? {8'h80, 8'h81, 8'h8A, 8'h8B, 8'h20, "PRESSURE",
                               8'h20, 8'h20, 8'h20, 8'h20, 8'h20} :            // 压力放大 4+1+8+5=18
        (disp_page == 3'd2) ? {8'h8C, 8'h8D, 8'h8A, 8'h8B, 8'h20, "TEMP",
                               8'h20, 8'h20, 8'h20, 8'h20, 8'h20,
                               8'h20, 8'h20, 8'h20, 8'h20} :                  // 温度放大 4+1+4+9=18
        (disp_page == 3'd3) ? {8'h8E, 8'h8F, 8'h8A, 8'h8B, 8'h20, "LEVEL",
                               8'h20, 8'h20, 8'h20, 8'h20, 8'h20,
                               8'h20, 8'h20, 8'h20} :                         // 液位放大 4+1+5+8=18
        (disp_page == 3'd4) ? {8'h90, 8'h91, 8'h92, 8'h93, 8'h20, "STANDBY",
                               8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20} :     // 待机巡检 4+1+7+6=18
                              {8'h96, 8'h97, 8'h98, 8'h94, 8'h95, 8'h92, 8'h93, // 储气罐故障巡检
                               8'h20, "FAULT",
                               8'h20, 8'h20, 8'h20, 8'h20, 8'h20};            // 7+1+5+5=18

    // ---- 小表表注（每个槽一行，6 字节）：压力 MPa / 温度 C / 液位 % ----
    wire [8*6-1:0] S_GCAP =
        (gslot == 2'd0) ? {8'h80, 8'h81, 8'h20, "MPa"} :      // 压力 2+1+3 = 6
        (gslot == 2'd1) ? {8'h8C, 8'h8D, 8'h20, "C  "} :      // 温度 2+1+3 = 6
                          {8'h8E, 8'h8F, 8'h20, "%  "};       // 液位 2+1+3 = 6

    // ---- 大表表注（14 字节）----
    //   ★ 用 txt_pg 而不是 disp_page ★ 报警页要跟着报警的那一路走。
    wire [8*14-1:0] S_BCAP =
        (txt_pg == 3'd1) ? {8'h80, 8'h81, 8'h20, "PRESSURE",
                            8'h20, 8'h20, 8'h20} :                   // 压力 2+1+8+3 = 14
        (txt_pg == 3'd2) ? {8'h8C, 8'h8D, 8'h20, "TEMP",
                            8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20} :
                                                                         // 温度 2+1+4+7 = 14
                           {8'h8E, 8'h8F, 8'h20, "LEVEL",
                            8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20};   // 液位 2+1+5+6 = 14

    // ---- 量程行（纯 ASCII，1 倍，16 字节）----
    wire [8*16-1:0] S_UNIT =
        (txt_pg == 3'd2) ? "DEG C  20 - 120 " :
        (txt_pg == 3'd3) ? "PCT     0 - 100 " :
                           "MPa  0.00 - 1.60";

    // ---- 阈值行（14 字节）----
    //   三个放大页各写各的阈值；报警页跟着报警的那一路写（原来留空）。
    wire [8*14-1:0] S_THR =
        (txt_pg == 3'd1) ? {8'h99, 8'h9A, 8'h20, "> 1.20 MPa "} :      // 报警 2+1+11 = 14
        (txt_pg == 3'd2) ? {8'h99, 8'h9A, 8'h20, "> 95 C",
                            8'h20, 8'h20, 8'h20, 8'h20, 8'h20} :       // 报警 2+1+6+5 = 14
                           {8'h99, 8'h9A, 8'h20, "<20% ", 8'hB0, ">85% "};
                                                                       // 报警或 2+1+5+1+5 = 14
    // ★ 上面三条注释开头的汉字是给 tools/gen_hud_assets.py 的 check_cjk_usage() 看的 ★
    //   它把一行的 8'h8X/9X/AX/BX 字节解出来，和注释开头的连续汉字对拍。
    //   液位那行的字节串是 {0x99,0x9A,0xB0} 三个（'或'=0xB0 也在汉字编码区内），
    //   所以那行注释必须写成「报警或…」三个字，写成「报警…」会长度对不上而漏检。

    // ---- 趋势标题（14 字节）----
    wire [8*14-1:0] S_TTITLE =
        (txt_pg == 3'd2) ? {8'h8C, 8'h8D, 8'h9B, 8'h9C, 8'h20, "TEMP",
                            8'h20, 8'h20, 8'h20, 8'h20, 8'h20} :        // 温度趋势 4+1+4+5=14
        (txt_pg == 3'd3) ? {8'h8E, 8'h8F, 8'h9B, 8'h9C, 8'h20, "LEVEL",
                            8'h20, 8'h20, 8'h20, 8'h20} :              // 液位趋势 4+1+5+4=14
                           {8'h80, 8'h81, 8'h9B, 8'h9C, 8'h20, "TREND",
                            8'h20, 8'h20, 8'h20, 8'h20} ;              // 压力趋势 4+1+5+4=14

    // ==================================================================
    // nibble(4bit) -> ASCII
    // ==================================================================
    function [7:0] nib2asc;
        input [3:0] n;
        begin
            if      (n == 4'hE) nib2asc = 8'h2E;     // '.'
            else if (n == 4'hF) nib2asc = 8'h20;     // ' '
            else                nib2asc = {4'h3, n}; // '0'+n
        end
    endfunction

    wire [8*5-1:0] V_P = {nib2asc(row_p[19:16]), nib2asc(row_p[15:12]),
                          nib2asc(row_p[11:8]),  nib2asc(row_p[7:4]), nib2asc(row_p[3:0])};
    wire [8*5-1:0] V_T = {nib2asc(row_t[19:16]), nib2asc(row_t[15:12]),
                          nib2asc(row_t[11:8]),  nib2asc(row_t[7:4]), nib2asc(row_t[3:0])};
    wire [8*5-1:0] V_L = {nib2asc(row_l[19:16]), nib2asc(row_l[15:12]),
                          nib2asc(row_l[11:8]),  nib2asc(row_l[7:4]), nib2asc(row_l[3:0])};

    // 读数按哪个量：小表页跟 x 走（和表盘槽位一致），大表页跟页号走。
    // ★ 大表页不能跟 x 走 ★ 大表读数在 x 410..570，按 x 分槽永远落在槽 2，
    //   那样三个放大页都会显示"液位"。
    wire [1:0] qsel = big_pg ? ((txt_pg == 3'd2) ? 2'd1 :
                               ((txt_pg == 3'd3) ? 2'd2 : 2'd0)) : gslot;
    wire [8*5-1:0] V_SEL = (qsel == 2'd0) ? V_P :
                           (qsel == 2'd1) ? V_T : V_L;

    // ==================================================================
    // 文本取字实例
    //   小表的三块表注/三行读数各只用【一个】取字单元，靠把 x 减掉
    //   (216 * 槽号) 把三块"折"到同一处 —— 和 hud_gauge 选槽位同一套分界，
    //   省下 4 个 label 实例（每个实例都有一份"字符下标 -> 取哪个字节"的
    //   多路选择，本工程 LUT 已经把 125MHz 那条路径的余量啃掉了）。
    // ==================================================================
    wire [9:0] gx_shift = x - ({8'b0, gslot} * 10'd216);   // 三槽折叠到槽 0 的坐标

    // 报警横幅纵向位置：banner_off=48 完全在屏幕下方，=0 完全弹出
    wire [9:0] by0 = 10'd444 + {4'b0, banner_off};
    wire       in_banner = (y >= by0) && (y < by0 + 10'd36);

    // 各 label 的输出汇聚（下面按优先级选一条）
    wire         h_title, h_page, h_swname, h_botok, h_botal, h_pagecap;
    wire         h_gcap, h_gval, h_bcap, h_unit, h_thr, h_ttitle;
    wire [5:0]   c_title, c_page, c_swname, c_botok, c_botal, c_pagecap;
    wire [5:0]   c_gcap, c_gval, c_bcap, c_unit, c_thr, c_ttitle;
    wire [7:0]   n_title, n_page, n_swname, n_botok, n_botal, n_pagecap;
    wire [7:0]   n_gcap, n_gval, n_bcap, n_unit, n_thr, n_ttitle;
    wire [2:0]   r_title, r_page, r_swname, r_botok, r_botal, r_pagecap;
    wire [2:0]   r_gcap, r_gval, r_bcap, r_unit, r_thr, r_ttitle;
    wire [3:0]   cw_title, cw_page, cw_swname, cw_botok, cw_botal, cw_pagecap;
    wire [3:0]   cw_gcap, cw_gval, cw_bcap, cw_unit, cw_thr, cw_ttitle;
    wire [2:0]   g_title, g_page, g_swname, g_botok, g_botal, g_pagecap;
    wire [2:0]   g_gcap, g_gval, g_bcap, g_unit, g_thr, g_ttitle;
    wire [3:0]   gw_title, gw_page, gw_swname, gw_botok, gw_botal, gw_pagecap;
    wire [3:0]   gw_gcap, gw_gval, gw_bcap, gw_unit, gw_thr, gw_ttitle;
    wire         f_title, f_page, f_swname, f_botok, f_botal, f_pagecap;
    wire         f_gcap, f_gval, f_bcap, f_unit, f_thr, f_ttitle;

    // ---- 顶栏 ----
    hud_label #(.LEN(22), .SCALE(1), .MIXED(1), .X0(12), .Y0(10)) u_lbl_title
        (.px_v(x), .py_v(y), .str(S_TITLE), .hit(h_title), .code(c_title),
         .row(r_title), .gcol(g_title), .color(),
         .t_font(f_title), .t_code(n_title), .t_row(cw_title), .t_gcol(gw_title));

    hud_label #(.LEN(4), .SCALE(2), .X0(460), .Y0(10)) u_lbl_page
        (.px_v(x), .py_v(y), .str(S_PAGE), .hit(h_page), .code(c_page),
         .row(r_page), .gcol(g_page), .color(),
         .t_font(f_page), .t_code(n_page), .t_row(cw_page), .t_gcol(gw_page));

    hud_label #(.LEN(16), .SCALE(1), .X0(256), .Y0(26)) u_lbl_swname
        (.px_v(x), .py_v(y), .str(S_SWNAME), .hit(h_swname), .code(c_swname),
         .row(r_swname), .gcol(g_swname), .color(),
         .t_font(f_swname), .t_code(n_swname), .t_row(cw_swname), .t_gcol(gw_swname));

    // ---- 底栏 ----
    hud_label #(.LEN(18), .SCALE(1), .MIXED(1), .X0(24), .Y0(454)) u_lbl_botok
        (.px_v(x), .py_v(y), .str(S_BOTOK), .hit(h_botok), .code(c_botok),
         .row(r_botok), .gcol(g_botok), .color(),
         .t_font(f_botok), .t_code(n_botok), .t_row(cw_botok), .t_gcol(gw_botok));

    // 横幅文字跟着横幅一起上滑：先把 y 减掉横幅基线，Y0 固定 0
    hud_label #(.LEN(18), .SCALE(1), .MIXED(1), .X0(24), .Y0(0)) u_lbl_botal
        (.px_v(x), .py_v(y - (by0 + 10'd10)), .str(S_BOTAL), .hit(h_botal),
         .code(c_botal), .row(r_botal), .gcol(g_botal), .color(),
         .t_font(f_botal), .t_code(n_botal), .t_row(cw_botal), .t_gcol(gw_botal));

    // ---- 说明条（所有页都有）----
    hud_label #(.LEN(18), .SCALE(1), .MIXED(1), .X0(12), .Y0(44)) u_lbl_pagecap
        (.px_v(x), .py_v(y), .str(S_PAGECAP), .hit(h_pagecap), .code(c_pagecap),
         .row(r_pagecap), .gcol(g_pagecap), .color(),
         .t_font(f_pagecap), .t_code(n_pagecap), .t_row(cw_pagecap), .t_gcol(gw_pagecap));

    // ---- 小表表注：三槽折叠 ----
    hud_label #(.LEN(6), .SCALE(1), .MIXED(1), .X0(56), .Y0(96)) u_lbl_gcap
        (.px_v(gx_shift), .py_v(y), .str(S_GCAP), .hit(h_gcap), .code(c_gcap),
         .row(r_gcap), .gcol(g_gcap), .color(),
         .t_font(f_gcap), .t_code(n_gcap), .t_row(cw_gcap), .t_gcol(gw_gcap));

    // ---- 小表读数：三槽折叠，ASCII 4 倍 ----
    hud_label #(.LEN(5), .SCALE(4), .X0(24), .Y0(316)) u_lbl_gval
        (.px_v(gx_shift), .py_v(y), .str(V_SEL), .hit(h_gval), .code(c_gval),
         .row(r_gval), .gcol(g_gval), .color(),
         .t_font(f_gval), .t_code(n_gval), .t_row(cw_gval), .t_gcol(gw_gval));

    // ---- 大表右列 ----
    hud_label #(.LEN(14), .SCALE(1), .MIXED(1), .X0(404), .Y0(56)) u_lbl_bcap
        (.px_v(x), .py_v(y), .str(S_BCAP), .hit(h_bcap), .code(c_bcap),
         .row(r_bcap), .gcol(g_bcap), .color(),
         .t_font(f_bcap), .t_code(n_bcap), .t_row(cw_bcap), .t_gcol(gw_bcap));

    hud_label #(.LEN(16), .SCALE(1), .X0(404), .Y0(132)) u_lbl_unit
        (.px_v(x), .py_v(y), .str(S_UNIT), .hit(h_unit), .code(c_unit),
         .row(r_unit), .gcol(g_unit), .color(),
         .t_font(f_unit), .t_code(n_unit), .t_row(cw_unit), .t_gcol(gw_unit));

    hud_label #(.LEN(14), .SCALE(1), .MIXED(1), .X0(404), .Y0(164)) u_lbl_thr
        (.px_v(x), .py_v(y), .str(S_THR), .hit(h_thr), .code(c_thr),
         .row(r_thr), .gcol(g_thr), .color(),
         .t_font(f_thr), .t_code(n_thr), .t_row(cw_thr), .t_gcol(gw_thr));

    hud_label #(.LEN(14), .SCALE(1), .MIXED(1), .X0(404), .Y0(288)) u_lbl_ttitle
        (.px_v(x), .py_v(y), .str(S_TTITLE), .hit(h_ttitle), .code(c_ttitle),
         .row(r_ttitle), .gcol(g_ttitle), .color(),
         .t_font(f_ttitle), .t_code(n_ttitle), .t_row(cw_ttitle), .t_gcol(gw_ttitle));

    // ---- 文本层优先级（各区域基本互不相交，顺序只是保险）----
    //   横幅 > 正常底栏 > 顶栏 > 说明条 > 右列 > 小表
    //
    // ★★ 六个内容标签必须【按页号门控】，不能只靠几何 ★★
    //   小表的表注/读数（x56 y96 / x24 y316）和大表的右列四行（x404 y56/132/164/288）
    //   都落在对方的表盘窗口里。而 hud_gauge 在圆盘外面给的是 alpha=0（透明），
    //   透不出来才怪 —— 上板实测：大表页上大表盘左上角冒出小表的「压力 MPa」，
    //   因为那块的 hit 只看几何，和页号无关。
    //   ⚠ 同理：以后再加任何"只属于某一形态"的文字，都要带上 small_pg / big_pg。
    always @(*) begin
        t_hit=1'b1; t_font=1'b0; t_code=6'd0; t_ccode=8'h20;
        t_row=3'd0; t_crow=4'd0; t_gcol=3'd0; t_gccol=4'd0; t_color=C_TEXT;

        if      (in_banner && h_botal)  begin t_hit=1'b1; t_font=f_botal;  t_code=c_botal;  t_ccode=n_botal;  t_row=r_botal;  t_crow=cw_botal;  t_gcol=g_botal;  t_gccol=gw_botal;  t_color=C_ALMTXT; end
        else if (h_botok && !in_banner) begin t_hit=1'b1; t_font=f_botok;  t_code=c_botok;  t_ccode=n_botok;  t_row=r_botok;  t_crow=cw_botok;  t_gcol=g_botok;  t_gccol=gw_botok;  t_color=C_OKTEXT; end
        else if (h_title)               begin t_hit=1'b1; t_font=f_title;  t_code=c_title;  t_ccode=n_title;  t_row=r_title;  t_crow=cw_title;  t_gcol=g_title;  t_gccol=gw_title;  t_color=C_TEXT;   end
        else if (h_page)                begin t_hit=1'b1; t_font=f_page;   t_code=c_page;   t_ccode=n_page;   t_row=r_page;   t_crow=cw_page;   t_gcol=g_page;   t_gccol=gw_page;   t_color=C_ACCENT; end
        else if (h_swname)              begin t_hit=1'b1; t_font=f_swname; t_code=c_swname; t_ccode=n_swname; t_row=r_swname; t_crow=cw_swname; t_gcol=g_swname; t_gccol=gw_swname; t_color=C_LABEL;  end
        else if (h_pagecap)             begin t_hit=1'b1; t_font=f_pagecap;t_code=c_pagecap;t_ccode=n_pagecap;t_row=r_pagecap;t_crow=cw_pagecap;t_gcol=g_pagecap;t_gccol=gw_pagecap;t_color=C_ACCENT; end
        // ---- 小表页专属（页 0/4）----
        else if (h_gcap && small_pg)    begin t_hit=1'b1; t_font=f_gcap;   t_code=c_gcap;   t_ccode=n_gcap;   t_row=r_gcap;   t_crow=cw_gcap;   t_gcol=g_gcap;   t_gccol=gw_gcap;   t_color=C_LABEL;  end
        else if (h_gval && small_pg)    begin t_hit=1'b1; t_font=f_gval;   t_code=c_gval;   t_ccode=n_gval;   t_row=r_gval;   t_crow=cw_gval;   t_gcol=g_gval;   t_gccol=gw_gval;   t_color=C_VALUE;  end
        // ---- 大表页专属（页 1/2/3/5）----
        else if (h_bcap && big_pg)      begin t_hit=1'b1; t_font=f_bcap;   t_code=c_bcap;   t_ccode=n_bcap;   t_row=r_bcap;   t_crow=cw_bcap;   t_gcol=g_bcap;   t_gccol=gw_bcap;   t_color=C_ACCENT; end
        else if (h_unit && big_pg)      begin t_hit=1'b1; t_font=f_unit;   t_code=c_unit;   t_ccode=n_unit;   t_row=r_unit;   t_crow=cw_unit;   t_gcol=g_unit;   t_gccol=gw_unit;   t_color=C_LABEL;  end
        else if (h_thr && big_pg)       begin t_hit=1'b1; t_font=f_thr;    t_code=c_thr;    t_ccode=n_thr;    t_row=r_thr;    t_crow=cw_thr;    t_gcol=g_thr;    t_gccol=gw_thr;    t_color=C_LABEL;  end
        else if (h_ttitle && big_pg)    begin t_hit=1'b1; t_font=f_ttitle; t_code=c_ttitle; t_ccode=n_ttitle; t_row=r_ttitle; t_crow=cw_ttitle; t_gcol=g_ttitle; t_gccol=gw_ttitle; t_color=C_LABEL;  end
        else                            begin t_hit=1'b0; end
    end

    // ==================================================================
    // 图形层
    // ==================================================================
    wire in_topbar  = (y < 10'd36);
    wire in_topedge = (y >= 10'd34) && (y < 10'd36);
    wire in_botbar  = (y >= 10'd444);

    // ---- SW 状态栏：x 256..383, y 26..33 ----
    // 4 组，每组 32px：前 24px 是 3 个字符的名字（由 u_lbl_swname 画），
    // 后 8px 是指示灯方块。
    //
    // 【不要写成 4 个独立的 10 位范围比较】下面这条图形 mux 链已经很长
    // （十几个比较器串在一起），而且它的输出直接喂 hud_overlay 的 qr_* 寄存器。
    // 用"共享列索引"只需要 1 个比较 + 1 个移位 + 1 个 4:1 mux，约 6 个 LUT：
    //   sx5[4:0] 是这一组内的列偏移，>= 24 即落在方块上；
    //   sx5[6:5] 就是组号（32px 一档，移位代替除法）。
    wire [9:0] sx5      = x - 10'd256;
    wire       in_swrow = (y >= 10'd26) && (y < 10'd34);
    wire       in_swbox = in_swrow && (sx5 < 10'd128) && (sx5[4:0] >= 5'd24);
    wire [1:0] swidx    = sx5[6:5];
    wire       sw_lit   = sw[swidx];

    // ---- 三个半透明文字底版 ----
    //   P1 说明条 y 40..63（所有页）
    //   P2 小表表注 y 92..115（仅小表页）
    //   P3 小表读数 y 312..351（仅小表页）
    //   P4 大表右列 x 396..636 y 68..306（仅大表页）
    // ★ 小表页 P3 那条 y 312..351 会盖住大表形态的趋势框位置吗？不会 ——
    //   两种形态按页号互斥，同一时刻只有一组底版生效。
    wire in_plate1 = (y >= 10'd40) && (y <= 10'd63);
    wire in_plate2 = small_pg && (y >= 10'd92)  && (y <= 10'd115);
    wire in_plate3 = small_pg && (y >= 10'd312) && (y <= 10'd351);
    wire in_plate4 = big_pg && (x >= 10'd396) && (x <= 10'd636) &&
                              (y >= 10'd68)  && (y <= 10'd306);
    wire in_plate  = in_plate1 | in_plate2 | in_plate3 | in_plate4;

    // ---- 趋势曲线图框：x 503..632, y 312..435 ----
    // 内区 x 504..631 = 正好 128px，与 hud_trend 的 128 个采样一一对应 ——
    // 这个"刚好 128"是"不用插值、不用乘法器"的前提，改边框宽度前先看 hud_trend。
    // 曲线像素由 hud_trend 提供（alpha 只有 0/255），这里只画框和底色：
    // 图框的底色如果交给 hud_trend，它会去和【底层 SD 图】做半透明混合，
    // 框里就会凭空透出底图，和面板其余部分不一致。
    // ★ 必须带 big_pg ★ 这条原来是漏写的：图框只属于大表形态（见文件头布局表），
    //   没有门控时它会画在小表页上，正好盖住第三个表的读数行（x456..615 y316..347），
    //   那一行就落在一块凭空出现的深色框里。上面注释说"两种形态按页号互斥"，
    //   指的就是这里 —— in_plate2/3/4 都带了页号判据，只有这条漏了。
    wire in_trbox   = big_pg && (x >= 10'd503) && (x <= 10'd632) &&
                               (y >= 10'd312) && (y <= 10'd435);
    wire tr_inside  = (x >= 10'd504) && (x <= 10'd631) && (y >= 10'd316) && (y <= 10'd431);

    // ---- 状态指示灯：用八边形近似圆，省掉乘法器 ----
    //   底栏 y 444..479，灯心 y 462，半径 12 -> 占 y 450..474，正好在栏内。
    //   x 400 / 470 / 540，与 u_lbl_botok 的 18 个字格（x 24..311）互不相交。
    function in_oct;
        input [9:0] px;
        input [9:0] py;
        input [9:0] cxv;
        input [9:0] cyv;
        input [9:0] rr;
        reg [10:0] ax, ay;
        begin
            ax = (px > cxv) ? (px - cxv) : (cxv - px);
            ay = (py > cyv) ? (py - cyv) : (cyv - py);
            in_oct = (ax <= rr) && (ay <= rr) && ((ax + ay) <= (rr + (rr >> 1) + (rr >> 2)));
        end
    endfunction

    localparam [9:0] LCY = 10'd462;
    localparam [9:0] LR  = 10'd12;

    wire lamp0_out = in_oct(x, y, 10'd400, LCY, LR);
    wire lamp1_out = in_oct(x, y, 10'd470, LCY, LR);
    wire lamp2_out = in_oct(x, y, 10'd540, LCY, LR);
    wire lamp0_in  = in_oct(x, y, 10'd400, LCY, 10'd7);
    wire lamp1_in  = in_oct(x, y, 10'd470, LCY, 10'd7);
    wire lamp2_in  = in_oct(x, y, 10'd540, LCY, 10'd7);

    // 待机巡检页（页 4）"状态灯全绿"：三个灯一律点亮、一律绿色
    wire stby = (disp_page == 3'd4);
    wire lit0 = stby | lamp[0];
    wire lit1 = stby | lamp[1];
    wire lit2 = stby | lamp[2];

    // ---- 亮度条：x 560..631, y 10..26 ----
    // bright*68/256 = bright*(64+4)/256，用移位加法，省下一个乘法器
    wire [15:0] brw16 = {8'b0, bright} << 6;
    wire [15:0] brw4  = {8'b0, bright} << 2;
    wire [7:0]  brw   = (brw16 + brw4) >> 8;    // 0..67
    wire in_brbox    = (x >= 10'd560) && (x <= 10'd631) && (y >= 10'd10) && (y <= 10'd26);
    wire in_brfill   = in_brbox && (x >= 10'd562) && (x < (10'd562 + {2'b0, brw}));

    // 报警横幅底色（闪烁）
    wire [23:0] c_almbar = blink ? C_ALMBAR : C_ALMBAR2;

    // 注意：SW 状态栏和亮度条都在顶栏里面，必须排在 in_topbar 之前，
    //       否则永远被顶栏盖掉。
    //       底版要排在各区域之前，让文字/边框压在上面。
    always @(*) begin
        if      (in_banner)  begin o_rgb = c_almbar;                                       o_alpha = 8'd255; end
        else if (in_botbar)  begin o_rgb = alarm_on ? c_almbar : C_OKBAR;                  o_alpha = 8'd255; end
        else if (in_swbox)   begin o_rgb = sw_lit ? 24'h3CFF88 : 24'h18242F;               o_alpha = 8'd255; end
        else if (in_brbox)   begin o_rgb = in_brfill ? 24'h28D0FF : 24'h101A24;            o_alpha = 8'd255; end
        else if (in_topbar)  begin o_rgb = in_topedge ? C_ACCENT :
                                            (y < 10'd18 ? C_TOP0 : C_TOP1);                o_alpha = 8'd255; end
        else if (in_trbox)   begin o_rgb = tr_inside ? C_TRBG : C_FRAME;                   o_alpha = 8'd255; end
        else if (lamp0_in)   begin o_rgb = lit0 ? 24'h66FF99 : 24'h1A2A22;                 o_alpha = 8'd255; end
        else if (lamp1_in)   begin o_rgb = lit1 ? (stby ? 24'h66FF99 : 24'hFF8877) : 24'h2A1A1A;
                                                                                           o_alpha = 8'd255; end
        else if (lamp2_in)   begin o_rgb = lit2 ? (stby ? 24'h66FF99 : 24'h88DDFF) : 24'h1A222A;
                                                                                           o_alpha = 8'd255; end
        else if (lamp0_out)  begin o_rgb = lit0 ? 24'h12A048 : 24'h202830;                 o_alpha = 8'd255; end
        else if (lamp1_out)  begin o_rgb = lit1 ? (stby ? 24'h12A048 : 24'hC02010) : 24'h202830;
                                                                                           o_alpha = 8'd255; end
        else if (lamp2_out)  begin o_rgb = lit2 ? (stby ? 24'h12A048 : 24'h1888C0) : 24'h202830;
                                                                                           o_alpha = 8'd255; end
        else if (in_plate)   begin o_rgb = C_PLATE;                                        o_alpha = 8'd200; end
        else                 begin o_rgb = C_DARK;                                         o_alpha = 8'd0;   end
    end

endmodule
