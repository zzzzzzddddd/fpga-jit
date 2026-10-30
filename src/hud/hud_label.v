`timescale 1ns/1ps
// ============================================================================
// hud_label.v -- 单个文本标签的"取字"单元（纯组合逻辑）
//
// 两种模式：
//
// 【MIXED=0】旧模式：纯 ASCII，字符格 8x8（5x7 点阵 + 右 3 列 + 下 1 行间距）
//   字符格宽固定 8，所以"字符下标 = 列号 >> 3"，不需要除法器。
//   输出 code[5:0] 送 hud_rom_font。
//
// 【MIXED=1】新模式：中英混排，字符格 16x16（×SCALE）
//   每个字节是一个"字格内容"：
//     ch[7] == 0 -> ASCII，查 5x7 字库（hud_rom_font）
//     ch[7] == 1 -> 汉字，ch[6:0] 是 hud_rom_cjk 里的字索引
//   ASCII 在 16px 格里放大 2 倍（10x14）并居中，汉字 16x16 占满格。
//   两种字在屏幕上都是 16px 宽一格，所以"字格下标 = 列号 >> 4"，
//   依然是移位，不用除法器。
//
//   为什么 ASCII 放大 2 倍而不是原尺寸：16px 的格里放 5x7 会显得空，
//   放大 2 倍后 10x14 把格子填得比较满，中英文并排时字高才一致。
//   横向前后各留 3px（原 6px 全留在右侧会像是字间距不均）。
//
// 字符串以【输入端口】形式给出（不是 parameter），这样上层可以按页号
// 动态选择不同的标签文字。
//
// 支持 SCALE = 1 / 2 / 4（2 的幂，取列号用移位即可，不用除法器）。
// 字库编码 CHARSET 见 tools/gen_hud_assets.py / hud_rom_font.v
// 汉字索引见 tools/gen_hud_assets.py 的 CJK_CHARS / hud_rom_cjk.v 头注释
// ============================================================================
module hud_label #(
    parameter LEN   = 8,          // 字格个数
    parameter SCALE = 2,          // 放大倍数 1/2/4
    parameter X0    = 0,          // 左上角 x
    parameter Y0    = 0,          // 左上角 y
    parameter MIXED = 0,          // 0 = 纯 ASCII（8px 格）；1 = 中英混排（16px 格）
    parameter [23:0] COLOR = 24'hD8E4F0
)(
    input  wire [9:0]       px_v,
    input  wire [9:0]       py_v,
    input  wire [8*LEN-1:0] str,
    output reg              hit,
    output reg  [5:0]       code,      // ASCII 字库编码（MIXED=1 时也有效）
    output reg  [2:0]       row,       // 5x7 字库的行号 0..7
    output reg  [2:0]       gcol,      // 字符格内列号 0..7（0..4 才是真正的字形列）
    output reg  [23:0]      color,
    // ---- MIXED=1 专用（MIXED=0 时恒 0，可以悬空）----
    output reg              t_font,    // 0 = 走 hud_rom_font(5x7)，1 = 走 hud_rom_cjk(16x16)
    output reg  [7:0]       t_code,    // CJK 字索引 = ch[6:0]
    output reg  [3:0]       t_row,     // CJK 行号 0..15
    output reg  [3:0]       t_gcol     // CJK 格内列号 0..15
);

    localparam LG      = (SCALE == 4) ? 2 : ((SCALE == 2) ? 1 : 0);
    localparam CELLW   = MIXED ? 16 : 8;              // 一个字格多少像素（未放大）
    localparam CELLLG   = MIXED ? 4 : 3;              // log2(CELLW)
    localparam WIDTH   = LEN * CELLW * SCALE;
    localparam HEIGHT  = CELLW * SCALE;
    localparam XEND    = X0 + WIDTH;
    localparam YEND    = Y0 + HEIGHT;

    wire in_x = (px_v >= X0) && (px_v < XEND);
    wire in_y = (py_v >= Y0) && (py_v < YEND);

    wire [9:0] dx   = px_v - X0;
    wire [9:0] dy   = py_v - Y0;
    wire [9:0] col  = dx >> LG;            // 0 .. LEN*CELLW-1
    wire [9:0] rowu = dy >> LG;            // 0 .. CELLW-1

    wire [9:0] ci = col >> CELLLG;         // 字格下标 0..LEN-1

    // ---- 取第 ci 个字节 ----
    // 故意写成"for 循环 + 常量下标"，而不是 str[8*(LEN-1-ci) +: 8] 这种
    // 变址部分选择：for 循环在展开后每一路的基址都是常数，任何综合器都认；
    // 变址 part-select 基址是变量，个别工具会报错或综合出奇怪的东西。
    // ci 越界时（像素不在本标签范围内）一个 case 都不匹配，ch 保持空格。
    reg [7:0] ch;
    integer   k;
    always @(*) begin
        ch = 8'h20;
        for (k = 0; k < LEN; k = k + 1)
            if (ci == k[5:0])
                ch = str[8*(LEN-1-k) +: 8];
    end

    // ---- ASCII -> 字库编码（顺序必须与 gen_hud_assets.py 的 CHARSET 一致）----
    // CHARSET = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.,:;!?%-/<>()=+*"
    function [5:0] ch2code;
        input [7:0] c;
        begin
            if      (c == 8'h20)               ch2code = 6'd0;
            else if (c >= 8'h30 && c <= 8'h39) ch2code = 6'd1  + (c - 8'h30);
            else if (c >= 8'h41 && c <= 8'h5A) ch2code = 6'd11 + (c - 8'h41);
            else case (c)
                8'h2E: ch2code = 6'd37;   // '.'
                8'h2C: ch2code = 6'd38;   // ','
                8'h3A: ch2code = 6'd39;   // ':'
                8'h3B: ch2code = 6'd40;   // ';'
                8'h21: ch2code = 6'd41;   // '!'
                8'h3F: ch2code = 6'd42;   // '?'
                8'h25: ch2code = 6'd43;   // '%'
                8'h2D: ch2code = 6'd44;   // '-'
                8'h2F: ch2code = 6'd45;   // '/'
                8'h3C: ch2code = 6'd46;   // '<'
                8'h3E: ch2code = 6'd47;   // '>'
                8'h28: ch2code = 6'd48;   // '('
                8'h29: ch2code = 6'd49;   // ')'
                8'h3D: ch2code = 6'd50;   // '='
                8'h2B: ch2code = 6'd51;   // '+'
                8'h2A: ch2code = 6'd52;   // '*'
                default: ch2code = 6'd0;
            endcase
        end
    endfunction

    // ---- 混排模式下的格内坐标 ----
    wire [3:0] ccol = col[3:0];            // 16px 格内列 0..15
    wire [3:0] crow = rowu[3:0];           // 16px 格内行 0..15

    // ASCII 在混排格里放大 2 倍：字形 5x7 -> 10x14。
    // 横向留左右各 3px（字形占列 3..12），纵向留上下各 1px（字形占行 1..14）。
    // 这样中英文并排时，字的视觉高度基本一致。
    wire       a_x_ok  = (ccol >= 4'd3) && (ccol < 4'd13);
    wire       a_y_ok  = (crow >= 4'd1) && (crow < 4'd15);
    wire [3:0] a_gx    = (ccol - 4'd3) >> 1;   // 0..4
    wire [3:0] a_gy    = (crow - 4'd1) >> 1;   // 0..6

    always @(*) begin
        hit    = in_x & in_y;
        code   = ch2code(ch);
        color  = COLOR;
        if (!MIXED) begin
            // ---- 旧路径：8px 纯 ASCII 格 ----
            t_font = 1'b0;
            t_code = 8'h20;
            t_row  = 4'd0;
            t_gcol = 4'd0;
            row    = in_y ? rowu[2:0] : 3'd0;
            gcol   = in_x ? col[2:0]  : 3'd0;
        end else begin
            t_code = {1'b0, ch[6:0]};
            t_font = ch[7];
            t_row  = crow;
            t_gcol = ccol;
            if (ch[7]) begin
                // 汉字：16x16 占满格
                row  = 3'd0;
                gcol = 3'd0;
            end else begin
                // ASCII：5x7 放大 2 倍后居中。落在边距上时给 gcol=7（>4，
                // hud_overlay 里被 gcol<=4 的掩码挡掉，恒为空白）。
                row  = (a_x_ok && a_y_ok) ? a_gy[2:0] : 3'd0;
                gcol = (a_x_ok && a_y_ok) ? a_gx[2:0] : 3'd7;
            end
        end
    end

endmodule
