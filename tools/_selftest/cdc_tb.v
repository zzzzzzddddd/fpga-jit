`timescale 1ns/1ps
module tb;
    // ---- 两个真实时钟 ----
    //   sd_card_clk = 100MHz     (10ns)
    //   audio_mclk  = 12.295082MHz (81.334ns)  = 256 x 48027.7Hz
    reg sd_clk = 0;
    reg au_clk = 0;
    always #5.000     sd_clk = ~sd_clk;
    always #40.667    au_clk = ~au_clk;

    reg        rst_n = 0;
    reg        stb   = 0;
    reg [15:0] wval  = 16'd0;

    wire [15:0] pcm;

    cdc_dut dut (
        .sd_card_clk (sd_clk),
        .audio_mclk  (au_clk),
        .por_rst_n   (rst_n),
        .wav_pcm_stb (stb),
        .wav_pcm     (wval),
        .pcm_data    (pcm)
    );

    // ---- 读侧监视：pcm 每变一次就算"收到一个样本" ----
    integer    got  = 0;      // 累计收到几个
    integer    bad  = 0;      // 顺序/值不对的个数
    reg [15:0] pcm_d = 16'd0;
    integer    n;

    always @(posedge au_clk) begin
        pcm_d <= pcm;
        if (pcm !== pcm_d) begin
            got = got + 1;
            // 期望：第 n 个收到的就是 n（写侧写的是 1,2,3,...）
            if (pcm !== got) begin
                bad = bad + 1;
                if (bad <= 5)
                    $display("    !! 第 %0d 个样本 = %0d（期望 %0d）", got, pcm, got);
            end
        end
    end

    integer i;
    initial begin
        repeat (20) @(posedge sd_clk);
        rst_n = 1;
        repeat (10) @(posedge sd_clk);

        // ---- 灌 0.30 秒的 16kHz 样本流 ----
        //   0.30s x 100MHz = 30_000_000 个 sd 周期
        //   每 6250 个周期打一次 stb  => 4800 个样本  => 16000Hz
        for (i = 0; i < 30000000; i = i + 1) begin
            @(posedge sd_clk);
            if ((i % 6250) == 0) begin
                wval <= wval + 16'd1;
                stb  <= 1'b1;
            end else
                stb  <= 1'b0;
        end
        stb = 1'b0;
        repeat (200) @(posedge au_clk);     // 让读侧把尾巴收干净

        $display("");
        $display("  收到 %0d 个样本（0.30 秒 @16kHz，期望约 4800）", got);
        $display("  顺序错位 %0d 个", bad);

        n = 0;
        if (bad != 0) begin
            $display("  FAIL  有错位/撕裂：CDC 的【数据先稳、toggle 后翻】没成立");
            n = n + 1;
        end else
            $display("  PASS  顺序正确：每个样本都被如数、按序收到");

        if (got >= 4700 && got <= 4900)
            $display("  PASS  计数正确：%0d 在 4700..4900 内 => 速率就是 16kHz", got);
        else begin
            $display("  FAIL  计数是 %0d，不在 4700..4900 内", got);
            n = n + 1;
        end

        if (n == 0) $display("\n=> 全部通过：这段 CDC 的刻度和顺序都是对的");
        else        $display("\n=> 有 %0d 项失败：CDC 不对，别上板", n);
        $finish;
    end
endmodule
