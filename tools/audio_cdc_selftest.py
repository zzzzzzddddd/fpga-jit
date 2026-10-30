#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
audio_cdc_selftest.py -- 用 iverilog 单独验【第二十五版新增的那段跨时钟域】。

【为什么必须做这一步】
  第二十五版把 wav_pcm/wav_pcm_stb（sd_card_clk 100MHz 域）跨到 audio_mclk
  (12.295082MHz) 域，变成 pcm_data 接给 hdmi_audio_tone_i2s_64fs 的 I_pcm。

  ★ 这段 CDC 一旦坏了，上板现象是【显示器一点声音都没有】，
    而 8 位数码管面板会【全部读数正常】★
    因为 D2/D3/D4/D5 量的都是 CDC【之前】的量（wav_pcm / wav_pcm_stb /
    wav_state_code / ...），CDC 死了它们照样好看。
  ⇒ 这是本工程"探针铁律"里最怕的一种：**沉默的失败**。

  所以必须在【上板之前】用 iverilog 把它证一遍。这和海平面以下那一条
  （tools/probe_rate_selftest.py，D4 速率探针的刻度先证再上板）是同一个做法。

【做法：从 top.v 里【原样抽取】那段代码来跑，不抄一份】
  抄一份会漂移（改了 top.v 忘了改测试）。这里按锚点从 src/top.v 里切出
  CDC 那一段（`reg [15:0] cdc_hold_data;` 到 `pcm_data` 那个 always 的 `end`），
  自动包成 cdc_dut，再配上 testbench。

【判据（两条，一条防"丢/错位"，一条防"根本不动"）】
  1) 不丢不错位：写侧每 6250 个 sd 周期（= 16kHz）写一个递增样本 1,2,3,...，
     读侧 pcm_data 必须【按同样的顺序、逐个】跟住（第 n 个收到的必须是 n）。
     —— 这抓的是"撕裂/错位/吞样本"。
  2) 计数（不是"有无"）：0.30 秒里 pcm_data 的更新次数应 ≈ 4800（16000 × 0.3）。
     —— 这抓的是"toggle 根本没翻 / 读侧根本没锁"这种【全 0 却看不出】的病。
        本工程已经因为"用有无代替计数"吃过一次亏（旧的 D4），这里改成计数。

用法：
    python tools/audio_cdc_selftest.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOP = os.path.join(ROOT, "src", "top.v")
OUT = os.path.join(ROOT, "tools", "_selftest")

START_ANCHOR = "reg [15:0] cdc_hold_data;"
END_ANCHOR = "else if (cdc_rd_edge) pcm_data <= cdc_hold_data;"

# 希望抽出来的那块里必须出现的东西 —— 锚点错了要当场发现，不能"抽到个空块也当通过"
MUST_HAVE = (
    "cdc_hold_data", "cdc_hold_tog", "cdc_tog_sync", "cdc_rd_edge",
    "pcm_data", "wav_pcm", "wav_pcm_stb", "sd_card_clk", "audio_mclk",
    "por_rst_n",
)


def extract_block():
    with open(TOP, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

    start = None
    for i, ln in enumerate(lines):
        if ln.startswith(START_ANCHOR):
            start = i
            break
    if start is None:
        raise SystemExit("找不到起始锚点：%s" % START_ANCHOR)

    end_anchor = None
    for j in range(start, len(lines)):
        if END_ANCHOR in lines[j]:
            end_anchor = j
            break
    if end_anchor is None:
        raise SystemExit("找不到收尾锚点：%s" % END_ANCHOR)

    # 收尾锚点往下的第一个【顶格】end 就是那个 always 块的结束
    end = None
    for k in range(end_anchor, len(lines)):
        if lines[k] == "end":
            end = k
            break
    if end is None:
        raise SystemExit("找不到 always 块的收尾 end")

    # ★ 抽出来的是"从 cdc_hold_data 声明"到"pcm_data 的 always 收尾" ★
    block = "\n".join(lines[start:end + 1])

    for must in MUST_HAVE:
        if must not in block:
            raise SystemExit("抽出来的块里没有 %s，锚点错了" % must)
    return block


DUT_TPL = """`timescale 1ns/1ps
// ★ 本文件由 tools/audio_cdc_selftest.py 从 src/top.v 自动抽取，不要手改 ★
module cdc_dut (
    input  wire        sd_card_clk,
    input  wire        audio_mclk,
    input  wire        por_rst_n,
    input  wire        wav_pcm_stb,
    input  wire [15:0] wav_pcm,
    output       [15:0] pcm_data   // 抽出块内部用 "reg [15:0] pcm_data;" 重声明
);
%s
endmodule
"""

TB = """`timescale 1ns/1ps
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

        if (n == 0) $display("\\n=> 全部通过：这段 CDC 的刻度和顺序都是对的");
        else        $display("\\n=> 有 %0d 项失败：CDC 不对，别上板", n);
        $finish;
    end
endmodule
"""


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    block = extract_block()
    print("从 %s 抽出 %d 行 CDC 代码" % (os.path.relpath(TOP, ROOT), block.count("\n") + 1))
    print("  首行: %s" % block.split("\n")[0].strip())
    print("  末行: %s" % block.split("\n")[-1].strip())
    print()

    dut_path = os.path.join(OUT, "cdc_dut.v")
    tb_path = os.path.join(OUT, "cdc_tb.v")
    with open(dut_path, "w", encoding="utf-8") as f:
        f.write(DUT_TPL % block)
    with open(tb_path, "w", encoding="utf-8") as f:
        f.write(TB)

    out_bin = os.path.join(OUT, "cdc.vvp")

    # ★ Windows 上 capture_output+text=True 默认按 GBK 解码，仿真器的字节流里
    #   只要有一个非 GBK 字节就 UnicodeDecodeError，然后 stdout 变成 None、
    #   后面 "in r.stdout" 直接 TypeError。必须显式指定编码并容错。★
    #   （tools/probe_rate_selftest.py 踩过这个坑）
    def run(cmd):
        return subprocess.run(cmd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace")

    r = run(["iverilog", "-g2001", "-o", out_bin, dut_path, tb_path])
    if r.returncode != 0:
        print("iverilog 编译失败：")
        print(r.stdout or "")
        print(r.stderr or "")
        return 2

    print("仿真中（0.30 秒，约一分钟）...")
    r = run(["vvp", out_bin])
    out = r.stdout or ""
    print(out)
    if (r.stderr or "").strip():
        print(r.stderr)
    return 0 if "全部通过" in out else 1


if __name__ == "__main__":
    sys.exit(main())
