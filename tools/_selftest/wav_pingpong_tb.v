`timescale 1ns/1ps
// ★ 本文件由 tools/wav_pingpong_selftest.py 生成 ★
module tb;
    localparam integer DATA_LEN = 2048;          // data 区字节数 = 1024 个样本
    localparam integer FILE_LEN = 44 + DATA_LEN;
    localparam integer SD_GRANT_DLY = 200;       // 仲裁/命令开销
    localparam integer BYTE_CYCLES  = 64;        // 12.5MHz SPI 下一个字节 ≈ 64 拍

    reg clk = 0;
    always #5 clk = ~clk;                        // 100MHz
    reg rst = 1;

    reg [7:0] fbyte [0:8191];                    // 现造的 WAV 文件

    // ---------------- DUT 接口 ----------------
    reg         sd_init_done;
    reg         play;

    wire        f_open_req;
    wire [3:0]  f_file_idx;
    reg         f_open_done;
    reg         f_found;
    reg  [31:0] f_file_size;
    wire        f_xl_req;
    wire [31:0] f_xl_sec_idx;
    reg         f_xl_valid;
    reg  [31:0] f_xl_lba;
    reg         f_xl_err;

    wire        sd_req;
    wire [31:0] sd_addr;
    reg         sd_grant;
    reg  [7:0]  sd_data;
    reg         sd_valid;
    reg         sd_end;

    wire [15:0] pcm;
    wire        pcm_stb;
    wire        playing, wdone, werr;
    wire [3:0]  state_code;
    wire        rate_ok, fmt_ok;

    wav_loader dut (
        .clk(clk), .rst(rst), .sd_init_done(sd_init_done),
        .play(play), .frag_idx(3'd0), .stop(1'b0),
        .playing(playing), .done(wdone), .err(werr),
        .f_open_req(f_open_req), .f_file_idx(f_file_idx),
        .f_open_done(f_open_done), .f_found(f_found), .f_file_size(f_file_size),
        .f_xl_req(f_xl_req), .f_xl_sec_idx(f_xl_sec_idx),
        .f_xl_valid(f_xl_valid), .f_xl_lba(f_xl_lba), .f_xl_err(f_xl_err),
        .sd_req(sd_req), .sd_addr(sd_addr), .sd_grant(sd_grant),
        .sd_data(sd_data), .sd_valid(sd_valid), .sd_end(sd_end),
        .pcm(pcm), .pcm_stb(pcm_stb),
        .state_code(state_code), .rate_ok(rate_ok), .fmt_ok(fmt_ok)
    );

    // ================= FAT32 桩 =================
    reg [2:0] ocnt = 0, xcnt = 0;
    reg open_done_r = 0, xl_valid_r = 0;

    always @(posedge clk) begin
        open_done_r <= 1'b0;
        xl_valid_r  <= 1'b0;
        if (f_open_req) ocnt <= 3'd1;
        else if (ocnt != 0) begin
            if (ocnt == 3'd3) begin open_done_r <= 1'b1; ocnt <= 3'd0; end
            else ocnt <= ocnt + 3'd1;
        end
        if (f_xl_req) xcnt <= 3'd1;
        else if (xcnt != 0) begin
            if (xcnt == 3'd3) begin xl_valid_r <= 1'b1; xcnt <= 3'd0; end
            else xcnt <= xcnt + 3'd1;
        end
    end

    always @(*) begin
        f_open_done = open_done_r;
        f_found     = 1'b1;
        f_file_size = FILE_LEN;
        f_xl_valid  = xl_valid_r;
        f_xl_lba    = f_xl_sec_idx;      // 恒等映射
        f_xl_err    = 1'b0;
    end

    // ================= SD 桩 =================
    integer sd_ph = 0, t = 0, boff = 0;

    always @(posedge clk) begin
        case (sd_ph)
        0: begin
            sd_valid <= 1'b0; sd_end <= 1'b0; sd_grant <= 1'b0;
            if (sd_req) begin sd_ph <= 1; t <= 0; end
        end
        1: begin
            if (t == SD_GRANT_DLY) begin sd_grant <= 1'b1; sd_ph <= 2; end
            else t <= t + 1;
        end
        2: begin
            sd_grant <= 1'b0; t <= 0; sd_ph <= 3;
        end
        3: begin
            // 每 BYTE_CYCLES 拍送一个字节
            if ((t % BYTE_CYCLES) == 0 && t < 512*BYTE_CYCLES) begin
                boff = (sd_addr * 512) + (t / BYTE_CYCLES);
                sd_valid <= 1'b1;
                sd_data  <= fbyte[boff % 8192];
            end else
                sd_valid <= 1'b0;
            t <= t + 1;
            if (t == 512*BYTE_CYCLES) begin
                sd_valid <= 1'b0; sd_end <= 1'b1; sd_ph <= 4;
            end
        end
        4: begin
            sd_end <= 1'b0;
            if (!sd_req) sd_ph <= 0;
        end
        default: sd_ph <= 0;
        endcase
    end

    // ================= 采样节拍监视 =================
    integer cyc = 0, last_stb = -1, maxgap = 0, nsamp = 0;
    integer expnext = -1, seqbad = 0;
    reg     done_seen = 0;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (wdone) done_seen = 1;
        if (pcm_stb) begin
            nsamp = nsamp + 1;
            if (last_stb >= 0)
                if ((cyc - last_stb) > maxgap) maxgap = cyc - last_stb;
            last_stb = cyc;
            if (expnext < 0) expnext = pcm;
            else begin
                if (pcm !== ((expnext + 1) & 16'hFFFF)) begin
                    if (seqbad < 3)
                        $display("    !! 第 %0d 个样本 = %0d，期望 %0d",
                                 nsamp, pcm, (expnext + 1) & 16'hFFFF);
                    seqbad = seqbad + 1;
                end
                expnext = (expnext + 1) & 16'hFFFF;
            end
        end
    end

    // ================= 主流程 =================
    integer i, k;
    initial begin
        // ---- 造一个合法的 16kHz/单声道/16bit WAV ----
        for (i = 0; i < 8192; i = i + 1) fbyte[i] = 8'h00;

        fbyte[ 0]="R"; fbyte[ 1]="I"; fbyte[ 2]="F"; fbyte[ 3]="F";
        fbyte[ 8]="W"; fbyte[ 9]="A"; fbyte[10]="V"; fbyte[11]="E";
        fbyte[12]="f"; fbyte[13]="m"; fbyte[14]="t"; fbyte[15]=" ";
        fbyte[16]=8'd16;                       // fmt chunk 大小
        fbyte[20]=8'd1;  fbyte[21]=8'd0;       // PCM
        fbyte[22]=8'd1;  fbyte[23]=8'd0;       // 单声道
        fbyte[24]=8'h80; fbyte[25]=8'h3E;      // 16000 Hz
        fbyte[26]=8'd0;  fbyte[27]=8'd0;
        fbyte[28]=8'h00; fbyte[29]=8'h7D;      // byte rate 32000
        fbyte[30]=8'd0;  fbyte[31]=8'd0;
        fbyte[32]=8'd2;  fbyte[33]=8'd0;       // block align
        fbyte[34]=8'd16; fbyte[35]=8'd0;       // 16bit
        fbyte[36]="d"; fbyte[37]="a"; fbyte[38]="t"; fbyte[39]="a";
        fbyte[40]=DATA_LEN[7:0]; fbyte[41]=DATA_LEN[15:8];
        fbyte[42]=8'd0; fbyte[43]=8'd0;

        // 样本 k = k（16bit 小端）⇒ 期望 pcm_stb 上读到的就是 0,1,2,3,...
        for (i = 0; i < DATA_LEN; i = i + 1) begin
            k = i >> 1;
            fbyte[44 + i] = (i & 1) ? k[15:8] : k[7:0];
        end

        sd_init_done = 0; play = 0;
        sd_grant = 0; sd_valid = 0; sd_end = 0; sd_data = 0;

        repeat (20) @(posedge clk);
        rst = 0;
        sd_init_done = 1;
        repeat (10) @(posedge clk);
        play = 1; @(posedge clk); play = 0;

        // 等播完或超时（1024 个样本 × 6250 拍 ≈ 6.4M 拍，留 4 倍余量）
        for (i = 0; i < 26000000; i = i + 1) begin
            @(posedge clk);
            if (done_seen) i = 26000001;
        end

        $display("");
        $display("  MAXGAP  %0d", maxgap);
        $display("  SAMPLES %0d", nsamp);
        $display("  SEQBAD  %0d", seqbad);
        $display("  DONE    %0d", done_seen);
        $finish;
    end
endmodule
