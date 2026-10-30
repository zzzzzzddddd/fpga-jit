`timescale 1ns/1ps
// ============================================================================
// hud_trend.v -- 滚动趋势曲线（面积图），画在右列下部
//
// 位置（与 hud_panel.v 里的图框严格对应）
//   图框（边框）  x 503..632, y 312..435
//   内区（可画）  x 504..631, y 316..431   -> 正好 128 列 x 116 行
//
// 【为什么内区必须正好 128 列】
//   采样数也是 128，"图宽 = 采样数" 意味着每一列正好对应一个采样点，
//   连线天然连续，不需要任何插值 —— 整个模块一个乘法器/除法器都不用。
//   宽度一旦不等于 128，要么插值要么留缝，两个都不划算。
//
// 【为什么避开表盘】
//   两个表盘的 ROM 窗口是 x 16..207（y 30..221 / y 226..417），图框在 x 503 起，
//   完全不相交。表盘叠加优先级又比面板高，交叠会被盖掉，所以必须错开。
//
// 采样：每 push 一个点（8Hz，由 hud_data_gen 的 upd_act 驱动）
//       -> 128 点 = 16 秒滚动窗口。列 c 显示 (127-c) 次 push 之前的样本，
//          即最新样本在最右边。
//       地址 = (wr_ptr + col) & 7'h7F，128 是 2 的幂，取模退化成按位与。
//
// 【存储必须按 ROM 模板写，不能带复位】
//   写成 `if(!rst_n) for(i) mem[i]<=0` 会被综合成 1024 个 FF 加一个 128:1 mux，
//   约 1500+ LUT（本设计 25MHz 域余量很大，但 LUT 已经把 125MHz 那条路径的
//   布局裕量啃掉了，见 TD_BUILD_NOTES.md）。照 hud_rom_dial.v 的模板写成
//   "不复位 + 同步单读口" 就只占 1 块 BSRAM9K。
//   上电时 BSRAM 默认全 0，所以开机后曲线从 0 开始、16 秒填满，是正常现象。
//
// 【流水线：正好 4 级】
//   hud_overlay 的契约是 t_rgb(k) = T(x(k-4), y(k-4))，混合在第 4 级同一拍做。
//   x/y 本身比 vout_data 晚 1 拍（hud_xy_gen），p4 是 4 拍，两边对齐。
//   本模块：stage0 组合 -> mem(同步读, 1 拍) -> r1 -> r2 -> r3 -> 输出寄存器
//   同步读自带的那 1 拍已经折进 r1 的级边界里（地址由【stage0 的 x】驱动，
//   数据在 r2 与同拍坐标一起消费），不要再额外打一拍 —— 那会变成 5 级，
//   曲线整体右偏一列。这正是 hud_gauge.v 里记的那个坑。
// ============================================================================
module hud_trend(
    input  wire        clk,          // video_clk 25MHz
    input  wire        rst_n,
    // ---- stage0：像素坐标（与 hud_panel / hud_gauge 同一组）----
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    // ---- 采样 ----
    input  wire [7:0]  sample,       // 显示高度 0..115（由 hud_data_gen 算好）
    input  wire        push,         // 单拍脉冲，8Hz
    // ---- 本实例当前是否要显示 ----
    // ★ en 只门控输出，不门控采样 ★
    //   压力/温度/液位三条曲线各占一块 BSRAM，采样【一直在跑】，
    //   这样从总览页切到放大页时曲线是满的，不是从 0 重新长出来。
    input  wire        en,
    // ---- 叠加输出（alpha 只有 0 / 255 两种值，见下）----
    output reg  [23:0] o_rgb,
    output reg  [7:0]  o_alpha
);

    // ------------------------------------------------------------------
    // 几何常量
    // ------------------------------------------------------------------
    localparam [9:0] X0 = 10'd504;   // 内区左边界
    localparam [9:0] X1 = 10'd631;   // 内区右边界（含）
    localparam [9:0] Y0 = 10'd316;   // 内区上边界
    localparam [9:0] Y1 = 10'd431;   // 内区下边界（含）
    localparam [9:0] HB = 10'd116;   // 内区高度 = Y1-Y0+1

    // 配色
    localparam [23:0] C_LINE = 24'h3CFF88;   // 曲线描边（与屏幕读数同色）
    localparam [23:0] C_FILL = 24'h0E3A28;   // 面积填充
    localparam [23:0] C_GRID = 24'h1C3A54;   // 50% 参考线（与面板分隔线同色）

    // ==================================================================
    // 采样存储：单写口 + 同步单读口 -> 1 块 BSRAM9K
    //
    // ★ 故意不写复位 ★  见文件头说明。
    // ==================================================================
    reg [7:0] mem [0:127];

    reg [6:0] wr_ptr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    wr_ptr <= 7'd0;
        else if (push) wr_ptr <= wr_ptr + 7'd1;
    end

    always @(posedge clk) begin
        if (push) mem[wr_ptr] <= sample;
    end

    // ==================================================================
    // stage0 组合：算这一列的读地址 + 这一行离底边多远
    // ==================================================================
    wire [9:0] col  = x - X0;                  // 0..127（越界时下溢成大数，被 in_box 排除）
    wire [9:0] rbot = Y1 - y;                  // 0(=底) .. 115(=顶)
    wire       in_box = (x >= X0) && (x <= X1) && (y >= Y0) && (y <= Y1);

    // 列 c 对应 (127-c) 次 push 之前的样本：mem[(wr_ptr-1-(127-c)) & 127]
    //                                         = mem[(wr_ptr + c) & 127]
    wire [7:0] rd_addr = {1'b0, wr_ptr} + {3'b0, col[6:0]};
    // ★ rd 必须是 reg ★ 它是在 always 里被赋值的。
    //   hud_gauge 那边看着像"wire 直接吃 ROM"是因为 ROM 是独立模块、
    //   读寄存器在 ROM 内部、对外是 output 端口；这里把存储内联了，
    //   读寄存器就落在本模块里，只能声明成 reg
    //   （TD 会报 procedural assignment to a non-register）。
    reg  [7:0] rd;

    always @(posedge clk) rd <= mem[rd_addr[6:0]];

    // ==================================================================
    // R1：把坐标跟着记忆体输出一起往前走一拍
    //     （rd 在下一拍有效，正好等于 mem[col(本拍)]）
    // ==================================================================
    reg        r1_inbox;
    reg [9:0]  r1_rbot;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_inbox <= 1'b0;
            r1_rbot  <= 10'd0;
        end else begin
            r1_inbox <= in_box;
            r1_rbot  <= rbot;
        end
    end

    // ==================================================================
    // R2：rd 与同一拍的坐标汇合
    // ==================================================================
    reg        r2_inbox;
    reg [9:0]  r2_rbot;
    reg [7:0]  r2_rd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_inbox <= 1'b0;
            r2_rbot  <= 10'd0;
            r2_rd    <= 8'd0;
        end else begin
            r2_inbox <= r1_inbox;
            r2_rbot  <= r1_rbot;
            r2_rd    <= rd;
        end
    end

    // ==================================================================
    // R3：形状判定
    // ==================================================================
    // 限幅：正常写入的 sample 已经 <= 115，这里再夹一次，
    // 是防止上电初期 BSRAM 内容还没被写过时把整列画满。
    wire [7:0] rd_h = (r2_rd > 8'd115) ? 8'd115 : r2_rd;

    wire       is_fill = (r2_rbot <  {2'b0, rd_h});                       // 面积：底部填到曲线
    wire       is_line = (r2_rbot == {2'b0, rd_h}) ||
                         (r2_rbot == ({2'b0, rd_h} + 10'd1));             // 描边：2 行
    wire       is_grid = (r2_rbot == (HB >> 1));                          // 50% 参考线

    reg        r3_inbox, r3_fill, r3_line, r3_grid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r3_inbox <= 1'b0;
            r3_fill  <= 1'b0;
            r3_line  <= 1'b0;
            r3_grid  <= 1'b0;
        end else begin
            r3_inbox <= r2_inbox;
            r3_fill  <= is_fill;
            r3_line  <= is_line;
            r3_grid  <= is_grid;
        end
    end

    // ==================================================================
    // R4：输出
    //
    // ★ 框外必须强制 alpha = 0 ★
    //   hud_overlay 的合并是 `t_on ? t_rgb : 面板`（选择，不是合成）。
    //   框外只要有一个 alpha != 0 的像素，整块趋势层就会把面板【整片替换】掉，
    //   全屏花掉。所以这里用 r3_inbox 做硬门控。
    //   en=0（本页不显示这条曲线）走同一条路 —— 同样必须 alpha=0，
    //   否则会盖掉别的层。
    // ==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_rgb   <= 24'h000000;
            o_alpha <= 8'd0;
        end else if (!r3_inbox || !en) begin
            o_rgb   <= 24'h000000;
            o_alpha <= 8'd0;
        end else if (r3_line) begin
            o_rgb   <= C_LINE;
            o_alpha <= 8'd255;
        end else if (r3_grid) begin
            o_rgb   <= C_GRID;
            o_alpha <= 8'd255;
        end else if (r3_fill) begin
            o_rgb   <= C_FILL;
            o_alpha <= 8'd255;
        end else begin
            o_rgb   <= 24'h000000;
            o_alpha <= 8'd0;
        end
    end

endmodule
