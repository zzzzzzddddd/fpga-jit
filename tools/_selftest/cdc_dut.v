`timescale 1ns/1ps
// ★ 本文件由 tools/audio_cdc_selftest.py 从 src/top.v 自动抽取，不要手改 ★
module cdc_dut (
    input  wire        sd_card_clk,
    input  wire        audio_mclk,
    input  wire        por_rst_n,
    input  wire        wav_pcm_stb,
    input  wire [15:0] wav_pcm,
    output       [15:0] pcm_data   // 抽出块内部用 "reg [15:0] pcm_data;" 重声明
);
reg [15:0] cdc_hold_data;            // sd 域：最近一个样本（保持到下一个）
reg        cdc_hold_tog;             // sd 域：每来一个样本翻一次

always @(posedge sd_card_clk or negedge por_rst_n) begin
    if (!por_rst_n) begin
        cdc_hold_data <= 16'd0;
        cdc_hold_tog  <= 1'b0;
    end else if (wav_pcm_stb) begin
        cdc_hold_data <= wav_pcm;
        cdc_hold_tog  <= ~cdc_hold_tog;
    end
end

reg [2:0] cdc_tog_sync;              // audio_mclk 域：3FF 同步

always @(posedge audio_mclk or negedge por_rst_n) begin
    if (!por_rst_n) cdc_tog_sync <= 3'd0;
    else            cdc_tog_sync <= {cdc_tog_sync[1:0], cdc_hold_tog};
end

wire cdc_rd_edge = cdc_tog_sync[2] ^ cdc_tog_sync[1];

// ★ pcm_data 必须落在 audio_mclk 域，并且直接接给 u_audio_tone.I_pcm ★
reg [15:0] pcm_data;

always @(posedge audio_mclk or negedge por_rst_n) begin
    if (!por_rst_n)       pcm_data <= 16'd0;
    else if (cdc_rd_edge) pcm_data <= cdc_hold_data;
end
endmodule
