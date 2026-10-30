`timescale 1ns/1ps
// ============================================================
// sd_arbiter.v — TF 卡单扇区仲裁器（FAT32 改造版：4 个请求方）
//
// ============================================================
// 【这一版相对固定 LBA 版本的改动】
// ============================================================
//   旧版只有两个请求方：读图(bmp) 和 音频流(aud)，两边各自内部算出绝对 LBA。
//   改成 FAT32 按文件名读之后，多出来一条**元数据读**的通路：
//
//     - fat32_reader 自己也要读扇区（读 MBR / 引导扇区 / 目录项 / FAT 表），
//       它和数据流一样是 sd_card_top 的请求方。
//     - 图片和音频各有一个独立的 fat32_reader 实例（各自的簇链游标），
//       所以是两条 FAT 请求，不是一条。
//
//   于是请求方从 2 个变成 4 个：
//     bmp  : 图片数据      (bmp_read 发起，地址来自 u_fat32_bmp)
//     aud  : 音频数据      (wav_loader 发起，地址来自 u_fat32_wav)
//     fbm  : 图片链的 FAT/目录/MBR 读 (u_fat32_bmp 内部)
//     fau  : 音频链的 FAT/目录/MBR 读 (u_fat32_wav 内部)
//
// ============================================================
// 【优先级：FAT 元数据 > 音频数据 > 图片数据】
// ============================================================
//   FAT 读排最前，是因为它**卡着数据流的脖子**：
//   bmp_read / wav_loader 在等一次翻译结果时，自己并没有占用仲裁器
//   （见 fat32_reader.v 里"无死锁的时序依据"一节），此时 FAT 读必须
//   尽快拿得到，否则整个流就停在那里。
//
//   而 FAT 读的出现频率极低：每跨一个簇才来一次。4KB/簇（Windows 对
//   4~8GB 卡的默认值，8 扇区/簇）时，每 8 个数据扇区才插进来 1 次，
//   占用比例 1/9。对两个数据流都无感。
//
//   音频数据排在图片数据之前，沿用旧版的比例论证：
//     16kHz 16bit 单声道 = 32 kB/s = 62.5 扇区/秒
//     读图独占 = 5882 扇区/秒
//     音频占用 62.5/5882 = 1.1%
//   而且 wav_loader 只在乒乓半区腾空时才拉 req，不是一直抢。
//
//   ★ 这个优先级建立在上面这笔速率账上。改采样率（比如上到 48kHz 立体声
//     = 375 扇区/秒）或改簇大小时要重算。
//
// ============================================================
// 【授权粒度必须是一个完整扇区，不能更细】
// ============================================================
//   sd_card_sec_read_write.v 的 S_READ 一旦开始就没法取消 —— 它在扇区中间
//   被拉低 sd_sec_read 会卡在半路，下一次读的地址/状态全乱。
//   所以授权给出后必须跑完整个扇区（等 sd_sec_read_end）才换人。
//
// ============================================================
// 【响应路径必须按授权方二分，不能广播】
// ============================================================
//   如果直接把 sd_sec_read_data_valid / sd_sec_read_end 给四个请求方，
//   bmp_read 会把音频的扇区当成自己的像素数据（颜色全乱），
//   wav_loader 也会把图片的字节填进音频缓冲（听到图片数据的噪声）。
//   必须用 grant 切开，各自只看属于自己的那一份。
// ============================================================
module sd_arbiter(
    input  wire        clk,              // sd_card_clk 100MHz
    input  wire        rst,              // 高有效异步复位
    input  wire        sd_init_done,     // 来自 sd_card_top

    // ---- 请求方 A：图片数据（src/sd_card_bmp.v -> bmp_read.v）----
    input  wire        bmp_req,
    input  wire [31:0] bmp_addr,
    output wire        bmp_grant,
    output wire        bmp_rdata_valid,
    output wire        bmp_rend,

    // ---- 请求方 B：音频数据（src/wav_loader.v）----
    input  wire        aud_req,
    input  wire [31:0] aud_addr,
    output wire        aud_grant,
    output wire        aud_rdata_valid,
    output wire        aud_rend,

    // ---- 请求方 C：图片链的 FAT/目录读（u_fat32_bmp 内部）----
    input  wire        fbm_req,
    input  wire [31:0] fbm_addr,
    output wire        fbm_grant,
    output wire        fbm_rdata_valid,
    output wire        fbm_rend,

    // ---- 请求方 D：音频链的 FAT/目录读（u_fat32_wav 内部）----
    input  wire        fau_req,
    input  wire [31:0] fau_addr,
    output wire        fau_grant,
    output wire        fau_rdata_valid,
    output wire        fau_rend,

    // ---- 到 sd_card_top ----
    output wire        sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);

    // 授权编码：0=bmp 1=aud 2=fbm 3=fau
    localparam G_BMP = 2'd0;
    localparam G_AUD = 2'd1;
    localparam G_FBM = 2'd2;
    localparam G_FAU = 2'd3;

    reg [1:0] grant;
    reg       active;      // 1 = 一个扇区正在传输，期间不换人

    // ------------------------------------------------------------------
    // ★★ 2026-10-03 加的"授权锁存"—— 修的是 active 被悬空闩死 ★★
    //
    // 【原来的死锁】
    //   active 在【采样到某个 client 的 req 为高】时置 1，但真正开跑要等
    //   sd_card_top 采样到 sd_sec_read = active & cur_req。
    //   只要那个 client 的 req 在那一拍之前撤掉：
    //       active=1 但 cur_req=0  ->  sd_sec_read 恒为 0
    //       -> sd_card_top 一直空闲 -> sd_sec_read_end 永远不来
    //       -> active 永远停在 1 -> bmp/aud/fbm/fau 四条通路同时饿死
    //   ★ 而且没有任何超时能救：压根没在传输，没有任何东西会超时 ★
    //
    //   触发源就是 bmp_read 的看门狗：force_retry 触发时会【无条件】把
    //   sd_sec_read 拉低，不管仲裁器刚有没有把总线授给它。
    //
    // 【修法】
    //   授权那一刻把"这个扇区要读"锁存成 req_lat，sd_sec_read 用它：
    //       sd_sec_read = active & (cur_req | req_lat)
    //   于是不管 client 后来怎么撤 req，这次授权都必然跑完一个扇区、
    //   必然产生 sd_sec_read_end、active 必然被释放。
    //   ★ active 与 sd_sec_read_end 的严格配对就此恢复 ★
    //
    // 【为什么对正常流程零影响】
    //   正常 client 拿到授权后本来就会一直举着 req 直到收到自己的 rend，
    //   所以 req_lat 在正常情况下【完全没有作用】—— 它只在那条病态路径上生效。
    //   万一某个 client 真的只脉冲了一拍 req，代价也只是多读一个无人认领的
    //   扇区（约 350us），而不是整个系统闩死到断电。
    // ------------------------------------------------------------------
    reg       req_lat;     // 1 = 本次授权必须跑完一个扇区（不依赖 client 的实时 req）

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
            grant   <= G_BMP;
            active  <= 1'b0;
            req_lat <= 1'b0;
        end else if (!active) begin
            // FAT 元数据优先（它卡着两条数据流的脖子）
            if (fbm_req) begin
                grant   <= G_FBM;
                active  <= 1'b1;
                req_lat <= 1'b1;
            end else if (fau_req) begin
                grant   <= G_FAU;
                active  <= 1'b1;
                req_lat <= 1'b1;
            end else if (aud_req) begin
                grant   <= G_AUD;
                active  <= 1'b1;
                req_lat <= 1'b1;
            end else if (bmp_req) begin
                grant   <= G_BMP;
                active  <= 1'b1;
                req_lat <= 1'b1;
            end
        end else if (sd_sec_read_end) begin
            active  <= 1'b0;
            req_lat <= 1'b0;
        end
    end

    assign bmp_grant = active & (grant == G_BMP);
    assign aud_grant = active & (grant == G_AUD);
    assign fbm_grant = active & (grant == G_FBM);
    assign fau_grant = active & (grant == G_FAU);

    // ------------------------------------------------------------------
    // 给 sd_card_top 的请求：active 期间只透传【当前授权方】的 req，
    // 地址也只给当前授权方的。这样别方的地址变化不会影响正在跑的传输。
    // ------------------------------------------------------------------
    reg [31:0] cur_addr;
    reg        cur_req;

    always @(*) begin
        case (grant)
            G_BMP: begin cur_req = bmp_req; cur_addr = bmp_addr; end
            G_AUD: begin cur_req = aud_req; cur_addr = aud_addr; end
            G_FBM: begin cur_req = fbm_req; cur_addr = fbm_addr; end
            default: begin cur_req = fau_req; cur_addr = fau_addr; end
        endcase
    end

    // ★ 用 (cur_req | req_lat) 而不是 cur_req ★
    //   一旦授权，本次传输就必然跑完，不再依赖 client 还举不举着 req。
    //   见 req_lat 声明处那段说明（它同时是"active 能被终止"这条不变量的保证）。
    assign sd_sec_read      = active & (cur_req | req_lat);
    assign sd_sec_read_addr = cur_addr;

    // ------------------------------------------------------------------
    // 响应按授权方二分（见文件头"响应路径必须按授权方二分"）
    // ------------------------------------------------------------------
    assign bmp_rdata_valid = sd_sec_read_data_valid & bmp_grant;
    assign bmp_rend        = sd_sec_read_end         & bmp_grant;
    assign aud_rdata_valid = sd_sec_read_data_valid & aud_grant;
    assign aud_rend        = sd_sec_read_end         & aud_grant;
    assign fbm_rdata_valid = sd_sec_read_data_valid & fbm_grant;
    assign fbm_rend        = sd_sec_read_end         & fbm_grant;
    assign fau_rdata_valid = sd_sec_read_data_valid & fau_grant;
    assign fau_rend        = sd_sec_read_end         & fau_grant;

endmodule
