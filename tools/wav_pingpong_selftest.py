#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wav_pingpong_selftest.py -- 证明（并量化）wav_loader 乒乓缓冲的那个停顿缺陷。

【要证的两件事】
  A) 第二十五版【改之前】：播放侧被 `st == A_WAITPLY` 门控，而在 A_SEEK/A_SRD
     回填一个扇区的整个过程中 FSM 都不在 A_WAITPLY ⇒ **每次回填都把播放冻住**。
     ⇒ 板上听到「不规则断续」＋「整个声音缓慢地一起一伏」。
  B) 第二十五版【改之后】：回填期间播放继续（读另一个半区）
     ⇒ 采样节拍不再断。

【判据：不是"有没有声音"，是"pcm_stb 的最大间隔"】
  采样节拍 strobe_div = 6250（100MHz / 16kHz）。
    ⇒ 正常：两个样本之间恒为 **6250 个周期**
    ⇒ 被冻住：每 256 个样本要多出**一整个回填的时间**
                （仿真里 grant 延迟 200 + 512 字节 × 64 拍/字节 ≈ 33000 拍）

  于是只要看一个数：
    MAXGAP ≈ 6250       → 没有停顿（修复生效）
    MAXGAP ≈ 6250+33000 → 存在停顿（缺陷成立）

【A/B 怎么跑】
  用真实的 src/wav_loader.v 跑一次；
  再把【旧门控】还原到一份临时副本上跑一次 —— 用故意写回去的错版本，
  证明这个测试确实抓得住那个缺陷（本工程的老规矩：检查器必须用故意写错的
  样本证明它会报，否则"全过"没有信息量）。

【测试台怎么搭】
  wav_loader 的两条外部依赖都用桩：
    · FAT32 桩：f_open_req -> f_open_done/f_found；f_xl_req -> f_xl_valid/f_xl_lba
                （LBA 用恒等映射，于是"文件扇区 k"就是"卡的扇区 k"）
    · SD 桩  ：sd_req -> 若干拍后 sd_grant -> 每 64 拍送一个字节 -> sd_end
                字节内容 = 一个内存里现造的 WAV 文件（44 字节头 + 2KB 递增样本）
  样本是【严格 +1 的递增序列】⇒ 还能顺带查有没有重采样错位/丢样本。

用法：
    python tools/wav_pingpong_selftest.py
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "wav_loader.v")
OUT = os.path.join(ROOT, "tools", "_selftest")

# 第二十五版引入的新门控 / 旧门控（还原用）
NEW_GATE = "end else if (!prefill && !fill_danger) begin"
OLD_GATE = "end else if (st == A_WAITPLY) begin"
NEW_VAC = "if (vacate_now && !prefill)"
OLD_VAC = "if (vacate_now && !prefill && (st == A_WAITPLY))"

TB = """`timescale 1ns/1ps
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
"""


def run_variant(tag, top_path, vvp):
    tb_path = os.path.join(OUT, "wav_pingpong_tb.v")
    cmd = ["iverilog", "-g2001", "-o", vvp, top_path, tb_path]
    # ★ PS5.1 的 GBK 解码坑：必须显式指定编码并容错 ★
    r = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print("iverilog 编译失败（%s）：" % tag)
        print(r.stdout or "")
        print(r.stderr or "")
        return None
    r = subprocess.run(["vvp", vvp], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = r.stdout or ""
    if (r.stderr or "").strip():
        print(r.stderr)
    print("  --- %s ---" % tag)
    for ln in out.splitlines():
        if ln.strip():
            print("  " + ln)
    m = re.search(r"MAXGAP\s+(\d+)", out)
    s = re.search(r"SAMPLES\s+(\d+)", out)
    b = re.search(r"SEQBAD\s+(\d+)", out)
    if not (m and s and b):
        return None
    return int(m.group(1)), int(s.group(1)), int(b.group(1))


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    with open(SRC, "r", encoding="utf-8") as f:
        src_text = f.read()

    # 新版本必须真的在文件里，否则说明锚点过期了
    for must in (NEW_GATE, NEW_VAC):
        if must not in src_text:
            raise SystemExit("src/wav_loader.v 里找不到 %r —— 锚点过期，"
                             "请先核对第二十五版的门控写法" % must)

    tb_path = os.path.join(OUT, "wav_pingpong_tb.v")
    with open(tb_path, "w", encoding="utf-8") as f:
        f.write(TB)

    # ---- A：当前源码（修复后）----
    print("跑 A：当前 src/wav_loader.v（第二十五版：回填时不停播）")
    gotA = run_variant("A 修复后", SRC, os.path.join(OUT, "wav_pp_A.vvp"))

    # ---- B：把旧门控还原到一份临时副本上 ----
    old_text = src_text.replace(NEW_GATE, OLD_GATE).replace(NEW_VAC, OLD_VAC)
    if old_text == src_text:
        raise SystemExit("还原旧门控失败（替换没生效）")
    old_path = os.path.join(OUT, "wav_loader_oldgate.v")
    with open(old_path, "w", encoding="utf-8") as f:
        f.write(old_text)

    print()
    print("跑 B：同一份代码，但把 `st == A_WAITPLY` 旧门控还原回去")
    gotB = run_variant("B 修复前", old_path, os.path.join(OUT, "wav_pp_B.vvp"))

    if gotA is None or gotB is None:
        return 2

    gapA, nsA, badA = gotA
    gapB, nsB, badB = gotB

    print()
    print("================== 结论 ==================")
    print("  修复后 MAXGAP = %d   样本 %d   错位 %d" % (gapA, nsA, badA))
    print("  修复前 MAXGAP = %d   样本 %d   错位 %d" % (gapB, nsB, badB))
    print()

    ok = True
    # 采样节拍 6250；允许几个周期的相位开销
    if gapA <= 6400:
        print("  PASS  修复后两个样本之间恒为一个采样节拍（%d ≤ 6400）"
              " ⇒ 回填期间播放没有停" % gapA)
    else:
        print("  FAIL  修复后仍有 %d 拍的空档 —— 停并没有消除" % gapA)
        ok = False
    if gapB >= 20000:
        print("  PASS  修复前存在 %d 拍的长空档（一整个回填的时间）"
              " ⇒ 缺陷成立，这个测试抓得住它" % gapB)
    else:
        print("  FAIL  修复前没测出长空档（%d）—— 测试台没造出该有的场景" % gapB)
        ok = False
    if nsA == 1024 and badA == 0:
        print("  PASS  修复后样本数 = 1024、序号严格 +1 ⇒ 没有丢样本/错位")
    else:
        print("  FAIL  修复后样本数 %d（应 1024）、错位 %d" % (nsA, badA))
        ok = False

    print()
    print("=> 全部通过" if ok else "=> 有项目不通过")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
