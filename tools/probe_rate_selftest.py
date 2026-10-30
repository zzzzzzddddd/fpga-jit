#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
probe_rate_selftest.py -- 用 iverilog 单独验【第二十四版样本速率探针】的逻辑。

【为什么必须做这一步】
  第二十四版把 D4 从"样本个数（饱和 14）"换成"每秒样本数÷4096"。
  上板时若 D4 读到 0，有两种可能，**光看板子分不开**：

      (a) 样本率真的是 0（＝要抓的那个病）
      (b) 探针本身接错了 / 被优化掉了（＝白烧一版）

  ⇒ 必须在**上板之前**用一个已知输入量把这个探针证一遍，
    这样"板上读到 0"才能唯一地解释成 (a)。

【做法：从 top.v 里【原样抽取】那段代码来跑，不抄一份】
  抄一份会漂移（改了 top.v 忘了改测试）。所以这里按锚点从 src/top.v
  里切出探针那一段（`reg [3:0]  wav_st_max;` 到那个 always 块的 `end`），
  自动包成 probe_dut，再配上 testbench。

【用例与判据】
  100MHz 时钟，按固定间隔打 aud_pcm_stb，看 D4（＝rate_max）：
      stb 每 6250 周期  ⇒ 16kHz   ⇒ D4 应为 3
      stb 每 12500 周期 ⇒ 8kHz    ⇒ D4 应为 1
      完全不打 stb       ⇒ 0       ⇒ D4 应为 0

用法：
    python tools/probe_rate_selftest.py
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOP = os.path.join(ROOT, "src", "top.v")
OUT = os.path.join(ROOT, "tools", "_selftest")

START_ANCHOR = "reg [3:0]  wav_st_max;"


def extract_block():
    with open(TOP, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

    start = None
    for i, ln in enumerate(lines):
        if ln.strip().startswith(START_ANCHOR.strip()) and START_ANCHOR in ln:
            start = i
            break
    if start is None:
        raise SystemExit("找不到起始锚点：%s" % START_ANCHOR)

    # always 块的收尾 `end` 顶格写；块内那些 end 都是缩进的
    end = None
    for j in range(start + 1, len(lines)):
        if lines[j] == "end":
            end = j
            break
    if end is None:
        raise SystemExit("找不到 always 块的收尾 end")

    block = "\n".join(lines[start:end + 1])

    # 自检：抽出来的必须真的是探针那一段
    for must in ("rate_win", "rate_cnt", "rate_max", "RATE_WIN_MAX",
                 "aud_pcm_stb", "probe_clr"):
        if must not in block:
            raise SystemExit("抽出来的块里没有 %s，锚点错了" % must)
    if "RATE_WIN_MAX = 27'd25_000_000" not in block:
        raise SystemExit("RATE_WIN_MAX 不是预期的 25_000_000，窗口长度变了？")
    return block


DUT_TPL = """`timescale 1ns/1ps
// ★ 本文件由 tools/probe_rate_selftest.py 从 src/top.v 自动抽取，不要手改 ★
module probe_dut (
    input  wire        sd_card_clk,
    input  wire        por_rst_n,
    input  wire        aud_pcm_stb,
    input  wire [15:0] aud_pcm,
    input  wire [3:0]  wav_state_code,
    input  wire        AUDIO_TEST_TONE,
    input  wire        wav_play,
    output wire [3:0]  d4,
    output wire [3:0]  d2,
    output wire [3:0]  d5
);
%s
assign d4 = rate_max;
assign d2 = wav_st_max;
assign d5 = wav_mag_max[15:12];
endmodule
"""

TB = """`timescale 1ns/1ps
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

        if (fails == 0) $display("\\n=> 全部通过：D4 的刻度是对的");
        else            $display("\\n=> 有 %0d 个用例失败：探针刻度不对，别上板", fails);
        $finish;
    end
endmodule
"""


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    block = extract_block()
    print("从 %s 抽出 %d 行探针代码" % (os.path.relpath(TOP, ROOT), block.count("\n") + 1))
    print("  首行: %s" % block.split("\n")[0].strip())
    print("  末行: %s" % block.split("\n")[-1].strip())
    print()

    dut_path = os.path.join(OUT, "probe_dut.v")
    tb_path = os.path.join(OUT, "probe_rate_tb.v")
    with open(dut_path, "w", encoding="utf-8") as f:
        f.write(DUT_TPL % block)
    with open(tb_path, "w", encoding="utf-8") as f:
        f.write(TB)

    out_bin = os.path.join(OUT, "probe_rate.vvp")
    # ★ Windows 上 capture_output+text=True 默认按 GBK 解码，仿真器的字节流里
    #   只要有一个非 GBK 字节就 UnicodeDecodeError，然后 stdout 变成 None、
    #   后面 "in r.stdout" 直接 TypeError。必须显式指定编码并容错。★
    def run(cmd):
        return subprocess.run(cmd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace")

    r = run(["iverilog", "-g2001", "-o", out_bin, dut_path, tb_path])
    if r.returncode != 0:
        print("iverilog 编译失败：")
        print(r.stdout or "")
        print(r.stderr or "")
        return 2

    print("仿真中（3 个用例 × 0.3 秒，约一分钟）...")
    r = run(["vvp", out_bin])
    out = r.stdout or ""
    print(out)
    if (r.stderr or "").strip():
        print(r.stderr)
    return 0 if "全部通过" in out else 1


if __name__ == "__main__":
    sys.exit(main())
