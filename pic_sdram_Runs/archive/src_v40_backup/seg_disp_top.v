// ============================================================================
// seg_disp_top.v -- 8 位数码管总装（clk 50MHz 域）
//
// video_clk 域送过来的东西没法直接吃：25MHz 和 50MHz 是两个域，
// hud_seg_data 那边用"数据先装、toggle 后翻"的握手送过来，
// 这里用 2 级同步器 + 边沿检测把 toggle 变成单拍脉冲，再整体锁存 40bit 载荷。
//
//   seg_tog(25M) ──2FF──> 边沿检测 ──> 锁存 {seg_dp, seg_dig}
//   8 位 nibble ──> 8 个 seg_decoder ──> seg_data_k = {dp_k, 7段码}
//                                       └─> seg_scan 逐位扫描
//
// 复用现成的 seg_decoder（低有效 7 段译码），不重新写一份。
//
// 【位数顺序】dig 的位号 0 定义为"最左一位"。上板第一步先让它显示
// 12345678 确认物理顺序；如果左右颠倒，改 top.adc 里 seg_sel 的引脚映射即可
// （那是整个设计里唯一一处"逻辑位号 -> 物理数码管"的映射）。
// ============================================================================
module seg_disp_top(
    input  wire        clk,        // 50MHz 板上晶振
    input  wire        rst_n,
    // ---- 来自 video_clk 域（hud_top）----
    input  wire [31:0] seg_dig,    // 8 个 nibble，[3:0] = 最左一位
    input  wire [7:0]  seg_dp,     // 8 个小数点，低有效
    input  wire        seg_tog,
    // ---- 板上的数码管 ----
    output wire [7:0]  seg_sel,    // 位选，低有效
    output wire [7:0]  seg_data    // 段选 + DP，低有效；MSB 是小数点
);

    // ------------------------------------------------------------------
    // 1) toggle 同步 + 边沿检测
    //    复位时把同步链初始化成 0，避免上电时锁到一个假边沿，
    //    把复位初值（全空白）当成有效数据。
    // ------------------------------------------------------------------
    reg [2:0] tog_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tog_sync <= 3'b000;
        else        tog_sync <= {tog_sync[1:0], seg_tog};
    end

    wire tog_pulse = tog_sync[2] ^ tog_sync[1];

    // ------------------------------------------------------------------
    // 2) 整体锁存载荷
    //    hud_seg_data 保证 toggle 翻转前数据已经稳定 >= 1 个源周期，
    //    再过 2 级同步器，这里采到的数据一定和那个 toggle 配套。
    // ------------------------------------------------------------------
    reg [39:0] pay_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          pay_r <= 40'hFF_FFFF_FFFF;   // 全空白
        else if (tog_pulse)  pay_r <= {seg_dp, seg_dig};
    end

    wire [31:0] dig_r = pay_r[31:0];
    wire [7:0]  dp_r  = pay_r[39:32];

    // ------------------------------------------------------------------
    // 3) 8 路 7 段译码（复用 seg_decoder）
    // ------------------------------------------------------------------
    wire [6:0] h0, h1, h2, h3, h4, h5, h6, h7;

    seg_decoder u_dec0(.bin_data(dig_r[3:0]),   .seg_data(h0));
    seg_decoder u_dec1(.bin_data(dig_r[7:4]),   .seg_data(h1));
    seg_decoder u_dec2(.bin_data(dig_r[11:8]),  .seg_data(h2));
    seg_decoder u_dec3(.bin_data(dig_r[15:12]), .seg_data(h3));
    seg_decoder u_dec4(.bin_data(dig_r[19:16]), .seg_data(h4));
    seg_decoder u_dec5(.bin_data(dig_r[23:20]), .seg_data(h5));
    seg_decoder u_dec6(.bin_data(dig_r[27:24]), .seg_data(h6));
    seg_decoder u_dec7(.bin_data(dig_r[31:28]), .seg_data(h7));

    // 4'hF -> seg_decoder 给出 7'b000_1110（中间一横），不是全灭。
    // nibble 4'hF 在本设计里表示"空白"，所以这里单独把全灭塞回去。
    function [7:0] blank_if_ff;
        input [3:0] nib;
        input [6:0] seg;
        input       dp;
        begin
            blank_if_ff = (nib == 4'hF) ? 8'hFF : {dp, seg};
        end
    endfunction

    wire [7:0] s0 = blank_if_ff(dig_r[3:0],   h0, dp_r[0]);
    wire [7:0] s1 = blank_if_ff(dig_r[7:4],   h1, dp_r[1]);
    wire [7:0] s2 = blank_if_ff(dig_r[11:8],  h2, dp_r[2]);
    wire [7:0] s3 = blank_if_ff(dig_r[15:12], h3, dp_r[3]);
    wire [7:0] s4 = blank_if_ff(dig_r[19:16], h4, dp_r[4]);
    wire [7:0] s5 = blank_if_ff(dig_r[23:20], h5, dp_r[5]);
    wire [7:0] s6 = blank_if_ff(dig_r[27:24], h6, dp_r[6]);
    wire [7:0] s7 = blank_if_ff(dig_r[31:28], h7, dp_r[7]);

    // ------------------------------------------------------------------
    // 4) 扫描输出
    // ------------------------------------------------------------------
    seg_scan u_scan(
        .clk        (clk),
        .rst_n      (rst_n),
        .seg_sel    (seg_sel),
        .seg_data   (seg_data),
        .seg_data_0 (s0),
        .seg_data_1 (s1),
        .seg_data_2 (s2),
        .seg_data_3 (s3),
        .seg_data_4 (s4),
        .seg_data_5 (s5),
        .seg_data_6 (s6),
        .seg_data_7 (s7)
    );

endmodule
