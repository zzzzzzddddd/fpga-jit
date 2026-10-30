`timescale 1ns/1ps
// ============================================================
// sd_card_bmp.v — 取图请求路径（压力容器重构版）
//
// ============================================================
// 【这一版最大的结构变化：sd_card_top 搬出去了】
// ============================================================
//   旧版这个模块把 bmp_read 和 sd_card_top 一起包在里面，所以 SD 卡控制器
//   被它独占 —— 音频流式播放就没有通路了。
//
//   新版 SD 卡由 src/sd_arbiter.v 按"一个扇区"的粒度仲裁，
//   sd_card_top 的例化搬到 top.v。本模块降级成纯粹的一侧请求方：
//     输出 sd_sec_read / sd_sec_read_addr 给仲裁器，
//     从仲裁器收回 sd_sec_read_data / _valid / _end。
//   所以 SD_nCS / SD_DCLK / SD_MOSI / SD_MISO 四个引脚从这个模块消失了。
//
//   另一侧请求方是 src/audio_sd_reader.v（音频流）。两者共用同一个仲裁器。
//
// ============================================================
// 【为什么要有"最新目标锁存器"】
// ============================================================
//   旧架构里"翻页"由 bmp_read 自己推进（读完一张才找下一张），所以不存在
//   "读图中途又来了一个请求"的问题 —— 按键被 ax_debounce 那条链锁存，
//   空闲后补发一次"读下一张"就够了。
//
//   新架构里目标变成了**带索引的**（"我要第 3 张"），请求可能在读图中途到达：
//   用户连按两下 K2，第 2 张刚读到一半，第 3 张的请求就来了。
//   如果只锁存"有新请求"这一个 bit，补发时用的还是旧索引 —— 屏幕上会是
//   "页 3 的界面 + 第 2 张的底图"，而且再也对不回来。
//
//   所以锁存的是**索引本身**，而且是"后到的覆盖先到的"（最新目标优先）：
//   连按两下只会读最后那一下对应的图，中间那张直接跳过 —— 既省一次
//   0.3 秒读图，也正好是用户想要的语义。
//
//   按键消抖（ax_debounce）已经整块删掉：旧版用它把 KEY1 这种机械按键
//   接到 SD 域。现在触发源是 HUD 在 video_clk 域产生的"页变化"脉冲，
//   已经是干净的信号，消抖在 hud_keys.v 里做过了。
// ============================================================
module sd_card_bmp(
    input                       clk,          // sd_card_clk 100MHz
    input                       rst,          // 高有效异步复位（沿用本模块原有约定）
    // ---- 取图请求（由 top.v 从 HUD 的 toggle-CDC 边沿检测产生）----
    input                       find,         // 单拍脉冲：请求读一张图
    input[2:0]                  img_index,    // 要读第几张 0..5，与 find 同拍到
    input                       sd_init_done, // SD 卡初始化完成（来自 sd_card_top）
    // ---- 状态与帧缓冲握手 ----
    output[3:0]                 state_code,   // 0=SD初始化 1=空闲 2=核对头部 3=读取中 4=读完
    input[15:0]                 bmp_width,
    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output[31:0]                write_data,
    output                      bmp_ready,    // = bmp_read.ready，空闲可接新请求
    // ---- 到 src/sd_arbiter.v 的取数口（旧版是直连 sd_card_top 的）----
    output                      sd_sec_read,
    output[31:0]                sd_sec_read_addr,
    input[7:0]                  sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end
);

// ------------------------------------------------------------------
// 最新目标锁存器
//
//   find 到达      -> 记下这一拍的 img_index，置 want_pend
//   bmp_read 空闲  -> 把 want_pend 兑现成一个单拍脉冲送给 bmp_read
//
// 优先级用 if/else if 写，find 在前：同一拍既有新请求、又要兑现旧请求时，
// 以【新请求】为准（旧索引会被覆盖），不会出现"先补发旧的、下一拍再发新的"
// 那种多余的一次读图。
// ------------------------------------------------------------------
reg [2:0] want_idx;
reg       want_pend;

// find_go：空闲 + 有欠着的请求 -> 发一拍
wire find_go = want_pend & bmp_ready;
// bmp_read 那一拍采样 img_index。find_go 的那一拍 want_idx 已经稳了很久，
// 所以直接把锁存值接出去就行，不需要再打拍。
wire find_s  = find_go;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        want_idx  <= 3'd0;
        want_pend <= 1'b0;
    end else if (find) begin
        want_idx  <= img_index;
        want_pend <= 1'b1;
    end else if (find_go) begin
        want_pend <= 1'b0;
    end
end

wire             bmp_data_wr_en;
wire [23:0]      bmp_data;

assign write_en   = bmp_data_wr_en;
// 1 像素 = 1 个 SDRAM 字：{R,G,B,8'b0}
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};

bmp_read bmp_read_m0(
    .clk                       (clk                    ),
    .rst                       (rst                    ),
    .ready                     (bmp_ready              ),
    .find                      (find_s                 ),
    .img_index                 (want_idx               ),
    .sd_init_done              (sd_init_done           ),
    .state_code                (state_code             ),
    .bmp_width                 (bmp_width              ),
    .write_req                 (write_req              ),
    .write_req_ack             (write_req_ack          ),
    .sd_sec_read               (sd_sec_read            ),
    .sd_sec_read_addr          (sd_sec_read_addr       ),
    .sd_sec_read_data          (sd_sec_read_data       ),
    .sd_sec_read_data_valid    (sd_sec_read_data_valid ),
    .sd_sec_read_end           (sd_sec_read_end        ),
    .bmp_data_wr_en            (bmp_data_wr_en         ),
    .bmp_data                  (bmp_data               )
);

endmodule
