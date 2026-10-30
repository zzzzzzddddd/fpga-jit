`timescale 1ns/1ps
// ============================================================
// sd_card_bmp.v — 取图请求路径（FAT32 按文件名版）
//
// ============================================================
// 【相对固定 LBA 版的改动：只多了一组"到 fat32_reader 的透传端口"】
// ============================================================
//   旧版 bmp_read 自己用 IMG_BASE_SEC + img_index*IMG_STRIDE 算绝对扇区，
//   所以它对外的 SD 接口只有 sd_sec_read / sd_sec_read_addr 一对。
//
//   新版 bmp_read 自己不算地址了，改成向 fat32_reader 要：
//     "打开第 img_index 个文件" + "给我这个文件的第 sec_idx 个扇区"。
//   于是本包装层多出一组端口，把 bmp_read 和外部例化的 u_fat32_bmp 连起来。
//
//   ★ 为什么 fat32_reader 不在这个模块里例化 ★
//     因为它同时是 sd_arbiter 的一个请求方（要读 FAT 表），
//     而 sd_arbiter 在 top.v 里。把 fat32 放在 top.v 例化，
//     仲裁器的四个请求方才能在同一个层次上连着，不用穿透两层包装。
//
// ============================================================
// 【"最新目标锁存器"原样保留】
// ============================================================
//   旧的 bmp_read 是"读完一张才找下一张"，不存在读图中途来新请求的问题。
//   新架构里目标变成**带索引的**（"我要第 3 张"），请求可能在读图中途到达：
//   用户连按两下 K2，第 2 张刚读到一半，第 3 张的请求就来了。
//   如果只锁存"有新请求"这一个 bit，补发时用的还是旧索引 —— 屏幕上会是
//   "页 3 的界面 + 第 2 张的底图"，而且再也对不回来。
//
//   所以锁存的是**索引本身**，且"后到的覆盖先到的"（最新目标优先）：
//   连按两下只会读最后那一下对应的图，中间那张直接跳过。
//
//   改成 FAT32 之后这个语义更加重要：打开+解析目录是有开销的，
//   中间那张直接跳过能省掉一次完整的 open 流程。
//
//   按键消抖（ax_debounce）已经整块删掉：触发源是 HUD 在 video_clk 域
//   产生的"页变化"脉冲，已经是干净的信号，消抖在 hud_keys.v 里做过了。
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
    // ---- 到 src/sd_arbiter.v 的取数口 ----
    output                      sd_sec_read,
    output[31:0]                sd_sec_read_addr,
    input[7:0]                  sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,
    // ---- 到 fat32_reader（顶层例化的 u_fat32_bmp）----
    output                      f_open_req,
    output[3:0]                 f_file_idx,
    input                       f_open_done,
    input                       f_found,
    output                      f_xl_req,
    output[31:0]                f_xl_sec_idx,
    input                       f_xl_valid,
    input[31:0]                 f_xl_lba,
    input                       f_xl_err
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

// ============================================================================
// 【已完成】2026-10-03 的"已知图案"实验结论
// ============================================================================
//   曾把这里临时改成 assign write_data = {8'hFF, dbg_pat[16:9], 8'h00, 8'b0};
//   （R 恒 255 ⇒ 绝不可能全黑），上板**出现红黄竖条** ⇒
//     **SDRAM 写 -> SDRAM 读 -> video_delay -> hud_overlay -> HDMI 整条通路是好的。**
//   而同一版位流的 D7=7 说明整帧确实在 SDRAM 里来回走过。
//   ⇒ 结论：**问题在 BMP 像素数据本身**（bmp_data 的值不对），不在存储/显示通路。
//   所以这里换回真数据，下一步改为探测"文件前半/后半的读回数据是否非零"。
// ============================================================================
// 1 像素 = 1 个 SDRAM 字：{R,G,B,8'b0}
// ★★ 图案实验已完成（2026-10-03）：红黄竖条正常出现 ⇒
//    SDRAM 写 -> SDRAM 读 -> video_delay -> hud_overlay -> HDMI 整条通路是好的。
//    所以问题在 BMP 像素数据本身，图案实验到此结束，这里【已换回真数据】。★★
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
    .bmp_data                  (bmp_data               ),
    // ---- FAT32 地址来源 ----
    .f_open_req                (f_open_req             ),
    .f_file_idx                (f_file_idx             ),
    .f_open_done               (f_open_done            ),
    .f_found                   (f_found                ),
    .f_xl_req                  (f_xl_req               ),
    .f_xl_sec_idx              (f_xl_sec_idx           ),
    .f_xl_valid                (f_xl_valid             ),
    .f_xl_lba                  (f_xl_lba               ),
    .f_xl_err                  (f_xl_err               )
);

endmodule
