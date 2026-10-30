`timescale 1ns/1ps
module tb;
    reg clk = 0;
    always #5 clk = ~clk;          // 100MHz

    reg        rst_n = 0;
    reg        stb   = 0;
    reg [15:0] pcm   = 16'h1000;
    reg [3:0]  st_code = 4'd6;
    reg        tone  = 0;          // 正常固件
    reg        play  = 0;

    wire [3:0] d4, d2, d5;

    probe_dut dut (
        .sd_card_clk      (clk),
        .por_rst_n        (rst_n),
        .aud_pcm_stb      (stb),
        .aud_pcm          (pcm),
        .wav_state_code   (st_code),
        .AUDIO_TEST_TONE  (tone),
        .wav_play         (play),
        .d4 (d4), .d2 (d2), .d5 (d5)
    );

    integer c;        // 距离下一个 stb 还有几个周期
    integer i;
    integer fails = 0;

    task check(input integer g, input [3:0] exp, input [255:0] name);
        begin
            // 清一次，模拟 wav_play 的 probe_clr
            play = 1; @(posedge clk); play = 0; @(posedge clk);
            c = 0;
            stb = 0;
            // 跑 30M 周期 = 0.30 秒 > 0.25 秒窗口 ⇒ 至少完整走完一个窗口
            for (i = 0; i < 30000000; i = i + 1) begin
                @(posedge clk);
                if (g > 0) begin
                    if (c == 0) begin stb <= 1; c = g - 1; end
                    else        begin stb <= 0; c = c - 1; end
                end else
                    stb <= 0;
            end
            stb = 0;
            @(posedge clk);
            if (d4 === exp)
                $display("  PASS  %0s: D4=%0h (期望 %0h)", name, d4, exp);
            else begin
                $display("  FAIL  %0s: D4=%0h (期望 %0h)", name, d4, exp);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        check(6250,  4'd3, "16kHz  (stb 每 6250 周期)");
        check(12500, 4'd1, "8kHz   (stb 每 12500 周期)");
        check(0,     4'd0, "0Hz    (完全不打 stb)");

        if (fails == 0) $display("\n=> 全部通过：D4 的刻度是对的");
        else            $display("\n=> 有 %0d 个用例失败：探针刻度不对，别上板", fails);
        $finish;
    end
endmodule
