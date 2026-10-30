`timescale 1ns/1ps
// ============================================================
// audio_fifo.v — TF 卡音频流的缓冲 FIFO（16bit 样本）
//
// ============================================================
// 【为什么不是教科书上的"格雷码异步 FIFO"】
// ============================================================
//   本工程【不跑仿真】，唯一的验证手段是上板。格雷码异步 FIFO 是整套设计里
//   最容易写错、又最难在上板上看出错在哪的一块（满/空判据差一位就永久
//   卡死或数据错位，而且现象是"声音偶尔怪一下"，根本定位不到）。
//
//   所以这里换成一个【完全在 sd_card_clk 单时钟域里】的同步 FIFO，
//   跨到 audio_mclk 域只走"一次要一个样本"的 toggle 握手：
//
//     audio_mclk 侧：每 256 拍（= 一个 I2S 采样周期）翻一次 req_tog
//     sd_card_clk 侧：2FF 同步 + 边沿检测 -> 弹一个样本 -> 数据先锁好，
//                     再翻 ack_tog
//     audio_mclk 侧：2FF 同步 + 边沿检测 -> 锁存 rd_data
//
//   于是"满/空/指针"全部是单时钟逻辑，只有一个 2FF 同步器和两条
//   "数据先稳、toggle 后翻"的约束，是跨域里最不容易错的一种。
//
//   ── 时序账（为什么 20.8us 的采样周期绝对够）──
//     req_tog 变化 -> 3FF 同步到 wclk        ≈ 3 个 wclk = 30ns
//     wclk 边沿检测 + 弹样本 + 翻 ack_tog    = 2 个 wclk = 20ns
//     ack_tog -> 3FF 同步到 rclk             ≈ 3 个 rclk = 244ns
//     合计 ≈ 0.3us  <<  20.8us（256 拍 @12.295MHz）
//
// ============================================================
// 【空的时候怎么办：补零，不是 sample-and-hold】
// ============================================================
//   FIFO 空时【照常 ack】，但把 rd_data_w 清成 0 —— audio 侧拿到的是静音。
//
//   ★ 这里【故意不用】sample-and-hold（保持上一个样本）★
//     一开始的想法是"保持住上一个值，避免在波形中间插一个跳变造成爆音"。
//     这个理由在【本设计里不成立】：
//
//     1) 欠载根本不会发生。audio_sd_reader 用低水位滞回节流（见那个文件头），
//        FIFO 存量一直在 2047~2303 之间小幅摆动，最坏的授权等待（2 个扇区
//        ≈ 340us ≈ 16 个样本）只把它压到 2031，离空差得远。
//        所以"短暂欠载需要平滑"这个前提是假的。
//
//     2) 而它有一个【真实的、持续的】害处：片段播完之后 FIFO 就是空的，
//        sample-and-hold 会把最后一个样本值【永久】维持在输出上 ——
//        一个持续的直流电平，听起来是"嗡"的一声闷响或者干脆让后级静音检测失效。
//        补零则是干净地回到静音，正是"这一段播完了"该有的行为。
//
//   I2S 的位时钟必须连续，所以 audio 侧本来就是每 256 拍固定要一次，
//   这里不给它"要不要"的选择，接口更简单。
//
// ============================================================
// 【BRAM 推断：两个 always 都不能带复位】
// ============================================================
//   mem 的写口和读口各自放在一个【没有复位】的 always 里，
//   这是 simple dual-port BSRAM 的标准模板。
//
//   ★ 千万别图省事把 "if (!rst_n) rd_data <= 0;" 加进读口 ★
//     带异步复位的存储体综合器会直接放弃 BSRAM，改用分布式 RAM ——
//     4096 x 16 就是约 4000 个 LUT，本项目 LUT 本来就是最紧的资源
//     （TD_BUILD_NOTES.md 记着 HUD 那 3200 个 LUT 曾把 125MHz 时序压坏）。
//     所以复位只加在【指针和输出寄存器】上，绝不碰 mem 和它的同步读口。
//     同理 hud_rom_dial / hud_trend 也是这么写的。
//
//   因为读口天然慢一拍，"弹样本"分两级：
//     req_edge 那一拍决定弹 -> rd_ptr 前进（BRAM 地址给出）
//     下一拍 mem_q 里就是被弹出的样本 -> 再一拍锁进 rd_data_w 并翻 ack_tog
//   这样 rd_data_w 和 ack_tog 严格同拍，读侧 244ns 后来取时数据一定已经稳。
//
// ============================================================
// 【flush】
// ============================================================
//   换页 -> 开始播新片段时必须清空。写侧一拍 flush 把两边的指针归零并把
//   rd_data_w 清 0，读侧最多再保持一拍旧值就变成静音，不会把上一段的尾巴
//   拖进新片段。与 wr_en 同拍时以 flush 优先，调用方不用自己避让。
// ============================================================
module audio_fifo #(
    parameter AW = 12,                    // 深度 = 2^AW 个样本
    // 低水位（样本数）：存量低于它就告诉调用方"该去 TF 卡抢扇区了"。
    // 2048 个样本 = 4 KiB = 4096 字节 = 42.6ms @ 48kHz/16bit 单声道。
    // 最坏授权等待是 2 个扇区 ≈ 340us，42.6ms 的缓冲有 125 倍余量。
    parameter [AW:0] LOW_WATER = 13'd2048
)(
    // ---- 写侧：sd_card_clk 100MHz ----
    input  wire        wclk,
    input  wire        wrst_n,
    input  wire        flush,             // 单拍：清空（与 wr_en 同拍时优先）
    input  wire        wr_en,
    input  wire [15:0] wr_data,
    output wire        wr_full,
    output wire        wr_low,            // 存量 < LOW_WATER
    output wire [AW:0] wr_level,          // 存量（样本数）

    // ---- 读侧：audio_mclk 12.295082MHz ----
    input  wire        rclk,
    input  wire        rrst_n,
    input  wire        rd_pulse,          // 单拍：要一个样本（每 256 拍来一次）
    output reg  [15:0] rd_data,           // 稳定；在 rd_valid 那拍更新
    output reg         rd_valid           // 单拍：rd_data 本拍有效
);

    localparam DEPTH = (1 << AW);

    reg [15:0] mem [0:DEPTH-1];

    reg [AW:0] wr_ptr;                    // 多一位做回绕，level 才好算
    reg [AW:0] rd_ptr;

    wire empty = (wr_ptr == rd_ptr);
    wire full  = (wr_ptr[AW] != rd_ptr[AW]) &&
                 (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);

    assign wr_level = wr_ptr - rd_ptr;
    assign wr_full  = full;
    assign wr_low   = (wr_ptr - rd_ptr) < LOW_WATER;

    // ==================================================================
    // BRAM 本体：写口 + 同步读口。【这两个 always 都没有复位】
    // ==================================================================
    always @(posedge wclk) begin
        if (wr_en && !full && !flush)
            mem[wr_ptr[AW-1:0]] <= wr_data;
    end

    reg [15:0] mem_q;
    always @(posedge wclk) begin
        mem_q <= mem[rd_ptr[AW-1:0]];     // 同步读，下一拍出数
    end

    // ==================================================================
    // req_tog 的 3FF 同步 + 边沿检测（写域）
    //
    // ★ 这一段必须整体放在【指针块之前】★
    //   指针块里用到 req_edge，而 req_edge 又依赖 req_tog（在本模块末尾的
    //   读侧 always 里赋值）。Verilog-2001 里用了还没声明的标识符会
    //   【隐式建一根 1bit wire】，等到后面再正式声明就是重复声明 ——
    //   TD 报 HDL-5373（'req_edge'/'req_tog' is used before its declaration）。
    //   1bit 恰好也是它俩的正确位宽，所以功能上歪打正着，但这是撞运气：
    //   一旦哪天给 req_edge 加了逻辑，隐式 1bit 会静默截断。所以规规矩矩
    //   先声明后用。
    // ==================================================================
    reg  req_tog;                          // 读侧翻转，这里只采
    reg  req_tog_s1, req_tog_s2, req_tog_s3;
    wire req_edge = req_tog_s2 ^ req_tog_s3;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            req_tog_s1 <= 1'b0;
            req_tog_s2 <= 1'b0;
            req_tog_s3 <= 1'b0;
        end else begin
            req_tog_s1 <= req_tog;
            req_tog_s2 <= req_tog_s1;
            req_tog_s3 <= req_tog_s2;
        end
    end

    // ==================================================================
    // 指针（带复位）
    // ==================================================================
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wr_ptr <= {(AW+1){1'b0}};
            rd_ptr <= {(AW+1){1'b0}};
        end else if (flush) begin
            wr_ptr <= {(AW+1){1'b0}};
            rd_ptr <= {(AW+1){1'b0}};
        end else begin
            if (wr_en && !full)
                wr_ptr <= wr_ptr + 1'b1;
            if (req_edge && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // ==================================================================
    // 弹出收尾：rd_data_w 与 ack_tog 【严格同拍】
    //
    //   pop_q : 上一拍"确实弹了"   -> 这一拍 mem_q 里就是被弹出的样本
    //   req_q : 上一拍"收到了请求" -> 无论弹没弹都要 ack
    //
    //   ★ 空的时候要补零 ★
    //     空的那些拍里 mem_q 里是【同一块 BSRAM 的残留内容】（FIFO 的读指针
    //     已经绕到写指针前面去了），不是"上一个样本"，直接输出会是垃圾数据，
    //     比静音难听得多。所以必须显式补 0。
    // ==================================================================
    reg        pop_q;
    reg        pop_empty_q;
    reg        req_q;
    reg [15:0] rd_data_w;
    reg        ack_tog;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            pop_q       <= 1'b0;
            pop_empty_q <= 1'b0;
            req_q       <= 1'b0;
            rd_data_w   <= 16'd0;
            ack_tog     <= 1'b0;
        end else if (flush) begin
            pop_q       <= 1'b0;
            pop_empty_q <= 1'b0;
            req_q       <= 1'b0;
            rd_data_w   <= 16'd0;         // 清成静音
        end else begin
            pop_q       <= req_edge & ~empty;
            pop_empty_q <= req_edge &  empty;
            req_q       <= req_edge;
            if (pop_q)
                rd_data_w <= mem_q;       // 弹出上一拍取到的那个
            else if (pop_empty_q)
                rd_data_w <= 16'd0;       // 空 -> 补零（见上面 ★ 段）
            if (req_q)
                ack_tog   <= ~ack_tog;
        end
    end

    // ==================================================================
    // 读侧：audio_mclk 域
    //
    //   req_tog 的声明在【上面写域那一段里】（那里同步它，必须先声明）。
    //   这里只负责翻转它 —— 每 256 拍（一个 I2S 采样周期）翻一次。
    // ==================================================================
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n)
            req_tog <= 1'b0;
        else if (rd_pulse)
            req_tog <= ~req_tog;
    end

    reg ack_tog_s1, ack_tog_s2, ack_tog_s3;
    wire ack_edge = ack_tog_s2 ^ ack_tog_s3;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            ack_tog_s1 <= 1'b0;
            ack_tog_s2 <= 1'b0;
            ack_tog_s3 <= 1'b0;
        end else begin
            ack_tog_s1 <= ack_tog;
            ack_tog_s2 <= ack_tog_s1;
            ack_tog_s3 <= ack_tog_s2;
        end
    end

    // ★ "数据先稳、toggle 后翻"由写侧保证 ★
    //   写侧 rd_data_w 和 ack_tog 是同一个时钟沿上的两个赋值，
    //   而 ack_tog 还要过 3 拍同步才被 rclk 看到（≥ 244ns），
    //   那时 rd_data_w 早已稳定。所以这里直接锁存是安全的。
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rd_data  <= 16'd0;
            rd_valid <= 1'b0;
        end else if (ack_edge) begin
            rd_data  <= rd_data_w;
            rd_valid <= 1'b1;
        end else begin
            rd_valid <= 1'b0;
        end
    end

endmodule
