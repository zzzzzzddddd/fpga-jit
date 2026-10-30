`timescale 1ns/1ps
// ★ 本文件由 tools/i2s_roundtrip_selftest.py 生成 ★
module tb;
    // ---- 两个真实时钟 ----
    reg mclk = 0;
    reg vclk = 0;
    always #40.6665 mclk = ~mclk;   // 周期 81.333ns  -> 12.295082MHz
    always #20      vclk = ~vclk;   // 周期 40ns      -> 25MHz

    reg        rst  = 1;
    reg [1:0]  mode = 2'd1;         // M_PCM
    reg [15:0] pcm  = 16'd0;

    wire        req;
    wire        bclk, lrck, dout;
    wire        valid;
    wire [23:0] L, R;

    hdmi_audio_tone_i2s_64fs #(
        .PHASE_INC (32'd39370534),
        .AMP       (24'sd2000000)
    ) dut (
        .I_mclk    (mclk),
        .I_rst     (rst),
        .I_mode    (mode),
        .I_pcm     (pcm),
        .O_pcm_req (req),
        .O_i2s_BCLK(bclk),
        .O_i2s_LRCK(lrck),
        .O_i2s_DOUT(dout)
    );

    I2S_receiver rx (
        .I_clk              (vclk),
        .I_rst              (rst),
        .I_i2s_BCLK         (bclk),
        .I_i2s_LRCK         (lrck),
        .I_i2s_DOUT         (dout),
        .O_audio_valid      (valid),
        .O_audio_left_data  (L),
        .O_audio_right_data (R)
    );

    // 发送端的映射：低 2 位截断后放到 bit[23:10]
    function [23:0] expect24(input [15:0] v);
        expect24 = {v[15:2], 10'd0};
    endfunction

    integer i, k, bad;
    integer nfail = 0;
    reg [15:0] vec [0:19];
    reg [23:0] got;
    reg [23:0] exp;
    integer    ngot;

    initial begin
        vec[0]=16'd0;      vec[1]=16'd1;      vec[2]=16'hFFFF;  vec[3]=16'd100;
        vec[4]=16'hFF9C;   vec[5]=16'd1000;   vec[6]=16'hFC18;  vec[7]=16'd8191;
        vec[8]=16'hE001;   vec[9]=16'd16383;  vec[10]=16'hC000; vec[11]=16'd32767;
        vec[12]=16'h8000;  vec[13]=16'd12345; vec[14]=16'hCFC7; vec[15]=16'd20000;
        vec[16]=16'hB1E0;  vec[17]=16'd3;     vec[18]=16'hFFFB; vec[19]=16'd25000;

        repeat (50) @(posedge mclk);
        rst = 0;
        mode = 2'd1;
        repeat (300) @(posedge mclk);

        $display("  发送值    期望24bit   实收24bit   <== 不一致的会标出来");
        for (i = 0; i < 20; i = i + 1) begin
            pcm = vec[i];
            exp  = expect24(vec[i]);
            // ★ 按【有效帧】对齐，不按时间 ★
            //   O_audio_valid 每帧（20.8us）才来一次，用固定时钟数去等
            //   会跨帧抓到上一条（第一版就是这么错的，现象是"实收=上一条期望"）。
            //   先扔掉前 6 个有效帧（发送流水线 + 两级跨域同步的延迟），再取 1 个。
            for (k = 0; k < 6; k = k + 1) begin
                @(posedge vclk);
                while (!valid) @(posedge vclk);
            end
            @(posedge vclk);
            while (!valid) @(posedge vclk);
            got = L;

            if (got !== exp) begin
                $display("  %6d   %8h   %8h   <== 不一致", vec[i], exp, got);
                nfail = nfail + 1;
            end else begin
                $display("  %6d   %8h   %8h", vec[i], exp, got);
            end
        end

        $display("");
        if (nfail == 0)
            $display("=> 全部 20 个测试值都一致：I2S 往返的位对齐是对的");
        else
            $display("=> 有 %0d 个值不一致：I2S 往返会改变样本值（位对齐滑移）", nfail);
        $finish;
    end

    // 兜底：仿真别跑飞
    initial begin
        #400000000;
        $display("=> 超时（仿真跑飞了）");
        $finish;
    end
endmodule
