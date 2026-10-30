`timescale 1ns/1ps
// ============================================================================
// hud_xy_gen.v -- 像素坐标生成器（HUD 所有几何运算的基准）
//
// 输入接 video_delay 的 hs_r / vs_r / de_r（这三个与 vout_data 严格同拍），
// 输出当前像素在"有效显示区"里的坐标：
//     x = 0..639   —— 一行里第几个有效像素（de 的第一个像素为 0）
//     y = 0..479   —— 第几行（VS 之后的第一个有效行为 0）
//
// 时序：x/y 比 vout_data 晚 1 拍。这个"晚 1 拍"已经算进 hud_overlay 的
//       总延迟 PIPE_DELAY 里，不需要在外面再补。
// ============================================================================
module hud_xy_gen(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,          // 场同步（极性无关，只看跳变）
    input  wire        de,          // 数据有效
    output reg  [9:0]  x,           // 0..639
    output reg  [9:0]  y            // 0..479
);

    reg vs_d;
    reg de_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d <= 1'b0;
            de_d <= 1'b0;
            x    <= 10'd0;
            y    <= 10'd0;
        end else begin
            vs_d <= vs;
            de_d <= de;

            // ---- 行号：VS 跳变清零，每行第一个有效像素 +1 ----
            // 第一个有效行的 y 保持 0（清零后还没被加过），符合预期
            if (vs != vs_d)
                y <= 10'd0;
            else if (de && !de_d)
                y <= y + 10'd1;

            // ---- 列号：消隐期清零，第一个有效像素即为 0 ----
            if (!de)
                x <= 10'd0;
            else
                x <= x + 10'd1;
        end
    end

endmodule
