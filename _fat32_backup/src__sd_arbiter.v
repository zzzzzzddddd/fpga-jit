`timescale 1ns/1ps
// ============================================================
// sd_arbiter.v — TF 卡单扇区仲裁器（bmp_read 与音频流共用 sd_card_top）
//
// ============================================================
// 【为什么授权粒度必须是"一个 512B 扇区"，不能再细】
// ============================================================
//   sd_card_sec_read_write.v 的 S_READ 一旦开始就没法取消 —— 它在一个扇区的
//   中间被拉低 sd_sec_read，控制器会卡在半路，下一次读的地址/状态全乱。
//   所以这是整套 SD 控制器唯一正确的粒度：授权一旦给出，就必须跑完整个扇区
//   （等 sd_sec_read_end）才换人。
//
//   代价是一次授权最长要等 170us。这个量级对两条请求方都无所谓：
//     读图   : 一整张图 1801 扇区 ≈ 306ms，多等一两个扇区完全看不出来
//     音频   : 见下面的速率账
//
// ============================================================
// 【为什么音频可以有绝对优先级，不会把读图饿死】
// ============================================================
//   音频 48kHz x 16bit 单声道 = 96 kB/s = 187.5 扇区/秒
//   读图独占时                = 5882 扇区/秒
//   音频占用比例 = 187.5 / 5882 = 3.2%
//
//   而且 audio_sd_reader 只在 FIFO 里存量【低于低水位(4 KiB ≈ 43ms)】时才
//   拉 aud_req，装满就停手。所以音频不是"一直抢"，是"每 43ms 抢 8 个扇区"。
//   读图耗时从 306ms 涨到约 316ms，肉眼无感。
//
//   ★ 反过来说：这个优先级是【建立在上面的速率账之上的】★
//     如果哪天改了采样率（比如上到 48kHz 立体声 = 375 扇区/秒），
//     或者低水位设得离谱（比如设成 64 KiB），占用比例就不再是 3.2%，
//     音频会把读图压得很慢。改采样率时必须重算这笔账。
//
// ============================================================
// 【响应路径必须按授权方二分，不能广播】
// ============================================================
//   如果把 sd_sec_read_data_valid / sd_sec_read_end 直接给两边，
//   bmp_read 会把音频的扇区当成自己的像素数据（颜色全乱），
//   而且它的 bmp_len_cnt 会提前累加、sd_sec_read_end 提前触发导致地址错乱。
//   所以必须用 grant 把响应切开，各自只看到属于自己的那一份。
//
//   同理 sd_sec_read 也必须是 "active & 当前授权方的 req"：
//   授权方中途把 req 拉低时，请求要跟着拉低（但 active 不变，
//   等这个扇区跑完才释放）。
// ============================================================
module sd_arbiter(
    input  wire        clk,              // sd_card_clk 100MHz
    input  wire        rst,              // 高有效异步复位
    input  wire        sd_init_done,     // 来自 sd_card_top

    // ---- 请求方 A：读图（src/sd_card_bmp.v / bmp_read.v）----
    input  wire        bmp_req,          // = bmp_read.sd_sec_read
    input  wire [31:0] bmp_addr,         // = bmp_read.sd_sec_read_addr
    output wire        bmp_grant,
    output wire        bmp_rdata_valid,
    output wire        bmp_rend,         // 本扇区读完，交回 bmp_read

    // ---- 请求方 B：音频流（src/audio_sd_reader.v）----
    input  wire        aud_req,
    input  wire [31:0] aud_addr,
    output wire        aud_grant,
    output wire        aud_rdata_valid,
    output wire        aud_rend,

    // ---- 到 sd_card_top ----
    output wire        sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);

    reg grant;      // 0 = 授权给读图, 1 = 授权给音频
    reg active;     // 1 = 有一个扇区正在传输中，期间不换人

    // ------------------------------------------------------------------
    // 仲裁
    //
    //   !active 时才可能换人；一旦 active，必须等 sd_sec_read_end 才释放。
    //   active 期间 grant/addr/req 全部冻结，所以 sd_card_top 看到的是一个
    //   稳定的、不会被中途改写的请求。
    //
    //   sd_init_done 为低时强行清空 active：SD 卡初始化期间任何传输都不成立，
    //   如果此时还留着 active=1，初始化一结束就会带着一个陈旧的授权跑起来。
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst || !sd_init_done) begin
            grant  <= 1'b0;
            active <= 1'b0;
        end else if (!active) begin
            if (aud_req) begin
                // 音频绝对优先（速率账见文件头）
                grant  <= 1'b1;
                active <= 1'b1;
            end else if (bmp_req) begin
                grant  <= 1'b0;
                active <= 1'b1;
            end
        end else if (sd_sec_read_end) begin
            active <= 1'b0;
        end
    end

    assign bmp_grant = active & ~grant;
    assign aud_grant = active &  grant;

    // 给 sd_card_top 的请求：active 期间只透传【当前授权方】的 req，
    // 地址也只给当前授权方的。这样另一方的地址变化不会影响正在跑的传输。
    assign sd_sec_read      = active & (grant ? aud_req : bmp_req);
    assign sd_sec_read_addr = grant ? aud_addr : bmp_addr;

    // 响应按授权方二分（见文件头"响应路径必须按授权方二分"）
    assign bmp_rdata_valid = sd_sec_read_data_valid & bmp_grant;
    assign bmp_rend        = sd_sec_read_end         & bmp_grant;
    assign aud_rdata_valid = sd_sec_read_data_valid & aud_grant;
    assign aud_rend        = sd_sec_read_end         & aud_grant;

endmodule
