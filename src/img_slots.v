`timescale 1ns/1ps
// ============================================================
// img_slots.v — ★ 六槽预载器（2026-10-04 第十九版）★
// ============================================================
// 【它解决什么问题】
//   原来的架构是"翻页触发取图"：页一变就按文件名去 SD 卡读一张 921654 字节
//   的 BMP，读完才切帧缓冲。12.5MHz SPI 下这一张要 0.67 秒 —— 而工况页是
//   FPGA 自己画的、当拍就变，所以底图永远追不上页（用户看到的"图片切换有延迟"）。
//
//   本模块改成：上电后把六张图【依次】读进硬核 SDRAM 的六个槽
//       槽 k 的基址 = k * FRAME_WORDS (307200 字)
//   六槽共 1843200 字 < 2^21 = 2097152（EG_PHY_SDRAM_2M_32，2M×32），占 88%。
//   预载完成后翻页【不再碰 SD 卡】，只切换读基址 ⇒ 与工况页真正同步。
//   代价：上电后约 4 秒（6 × 0.67s）的加载时间。
//
// 【推进条件为什么必须是 frame_landed，不能是 bmp_read 的 frame_done】
//   bmp_read 的 state_code 4->1 只表示"最后一个像素刚进写 FIFO"，
//   FIFO 里可能还压着几百个字。此时推进 write_base，那些残留字会写到
//   【下一个槽的头部】，在图上表现为一条错位横带。
//   frame_landed 来自 frame_fifo_write.write_finish（见 top.v 的 wr_tog），
//   而 write_cnt 数的是 App_wr_en —— 即"从写 FIFO 取出多少字"，
//   所以 write_finish 拉高时 FIFO 已经排空。用它推进是安全的。
//   ★ 另外 write_finish 在 125MHz 下只有一拍宽(8ns)，top.v 里已经把它
//     做成翻转握手再送过来，否则 100MHz 的同步器会整次漏掉。★
//
// 【看门狗】
//   若某一张打不开（bmp_read 重试 FAIL_MAX 次后放弃回 S_IDLE），
//   frame_landed 就永远不会来，预载会停在那张上、后面几张永远不加载。
//   stall 计数到 WD_LIMIT 就把状态机踢回 S_GO 重发一次。
//   WD_LIMIT = 1.34 秒（100MHz）：一张正常 0.67 秒的两倍余量，
//   即便音频那条路在抢仲裁把图片读拖慢一倍也不会误触发。
//
// 【复位语义】
//   sd_init_done 掉下去（上电初期、或卡掉线）时整个状态机归零重来。
//   ★ sd_init_done 不是异步复位源，只是同步条件 ★
//     敏感表里只有 rst_n，综合出来仍然是普通同步逻辑。
// ============================================================
module img_slots #(
    parameter FRAME_WORDS = 307200,                 // 一帧占的 32bit 字数
    parameter SLOT_NUM    = 6,                      // 预载几张（= 槽数）
    parameter WD_LIMIT    = 27'd134_217_727         // 1.34s @100MHz
)(
    input  wire        clk,           // sd_card_clk 100MHz
    input  wire        rst_n,         // 异步复位，低有效
    input  wire        sd_init_done,  // SD 卡初始化完成
    input  wire        bmp_ready,     // bmp_read 空闲（= state == S_IDLE）
    input  wire        frame_landed,  // 单拍：整帧真的离开写 FIFO（本域）
    output reg         ld_find,       // 单拍：请 bmp_read 去取 ld_idx 那张
    output reg  [2:0]  ld_idx,        // 要取第几张 0..5 -> sd_card_bmp.img_index
    output reg  [23:0] write_base,    // 当前写槽的基址
    output reg  [2:0]  shown_slot,    // 最近一个【已完整落盘】的槽
    output reg  [2:0]  done_cnt       // 已落盘的张数 0..6
);

localparam [23:0] FW_STEP  = FRAME_WORDS;   // 槽间距（加法的常量操作数）
localparam [2:0]  LAST_IDX = SLOT_NUM - 1;  // 最后一张的序号（= 5）
localparam [2:0]  ALL_DONE = SLOT_NUM;      // 全部就绪时的张数（= 6）

localparam [1:0] S_GO   = 2'd0;   // 发一次取图请求
localparam [1:0] S_WAIT = 2'd1;   // 等这一帧落盘
localparam [1:0] S_DONE = 2'd2;   // 六张齐了，不再动作

reg [1:0]  st;
reg [26:0] stall;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || !sd_init_done) begin
        st         <= S_GO;
        stall      <= 27'd0;
        ld_find    <= 1'b0;
        ld_idx     <= 3'd0;
        write_base <= 24'd0;
        shown_slot <= 3'd0;
        done_cnt   <= 3'd0;
    end else begin
        // ld_find 是单拍脉冲：默认落下，只在 S_GO 里拉高一拍
        ld_find <= 1'b0;

        case (st)
            // ---- 发请求：等 bmp_read 回到空闲 ----
            S_GO: begin
                if (bmp_ready) begin
                    ld_find <= 1'b1;
                    stall   <= 27'd0;
                    st      <= S_WAIT;
                end
            end

            // ---- 等这一帧真的落进 SDRAM ----
            S_WAIT: begin
                if (frame_landed) begin
                    stall      <= 27'd0;
                    shown_slot <= ld_idx;          // 这一张从现在起可以显示了
                    if (ld_idx == LAST_IDX) begin
                        done_cnt   <= ALL_DONE;
                        // ★★ 2026-10-05 第二十七版：把写基址【挪出所有显示槽】★★
                        //   不挪的话它就永久停在槽 5 —— 而槽 5 正是报警页的
                        //   帧缓冲。于是万一有任何一个多余的 write_req 漏进来
                        //   （bmp_read 的重试/看门狗/仲裁毛刺都可能），
                        //   frame_fifo_write 会先去 S_ACK 把 App_wr_addr_r
                        //   拽回 write_addr_0 = 槽 5 的首地址，然后往报警页的
                        //   图里写数据 —— 正好是"只有报警页的图会变"。
                        //   往前挪一格（6 × 307200 = 1843200）就落到六个槽
                        //   之外的空白区，再怎么漏也碰不到任何在显示的图。
                        //   （硬核 SDRAM 是 2M×32 = 2097152 字，放得下。）
                        //   ★ 只是防御，不改任何正常路径的行为 ★
                        write_base <= write_base + FW_STEP;
                        st         <= S_DONE;
                    end else begin
                        ld_idx     <= ld_idx + 3'd1;
                        write_base <= write_base + FW_STEP;   // 推进到下一个槽
                        done_cnt   <= done_cnt + 3'd1;
                        st         <= S_GO;
                    end
                end else if (stall >= WD_LIMIT) begin
                    // 这一张卡太久了 —— 重发一次（bmp_read 自己也会重试，
                    // 但它试够 FAIL_MAX 次就放弃回 S_IDLE，那时只有这里能救）
                    stall <= 27'd0;
                    st    <= S_GO;
                end else
                    stall <= stall + 27'd1;
            end

            // ---- 六张齐了：不再发任何请求，把 SD 总线让给音频 ----
            default: begin
                st <= S_DONE;
            end
        endcase
    end
end

endmodule
