// 故意写错的样本 —— 用来验证 chk_drivers.py 在修好 for 崩溃之后
// 仍然真的能报出多驱动。不要综合它，只是给检查器吃的。
module drv_bad (
    input  wire clk,
    input  wire a,
    output reg  q,      // 只在下面一个块里驱动 -> 不该报
    output reg  r,      // 被两个块驱动 -> 必须报
    output reg  s       // assign 到 reg -> 必须报（另一条判据）
);

    integer i;

    // 这一块里带过程式 for：修 bug 之前，整份文件会在这里 AttributeError 崩掉
    always @(posedge clk) begin
        for (i = 0; i < 8; i = i + 1) begin
            q <= a;
        end
    end

    always @(posedge clk) begin
        r <= a;
    end

    always @(posedge clk) begin
        r <= ~a;
    end

    assign s = a;

endmodule
