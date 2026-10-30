`timescale 1ns/1ps
// ============================================================
// bmp_read.v — BMP 读取控制器（压力容器重构版：固定扇区直读）
//
// ============================================================
// 【这一版和上一版的根本区别：从"往后扫着找"改成"按索引直接算扇区"】
// ============================================================
// 旧版：翻页的唯一来源是"屏幕刚换成一张新图"，所以 bmp_read 靠
//       "从当前位置往后扫，扫到下一个 BM 头就是下一张"来自主推进，
//       张数无上限，靠"扫不到就绕回第一张"收尾。
//       代价是页号 = 图片序号的纯函数，页和图绑死，改一张图就要重扫。
//
// 新版：图 k 恒定放在扇区 IMG_BASE_SEC + k*IMG_STRIDE（由 tools/layout_sd.py
//       保证），所以给个索引就能直接算出地址，**不再需要扫描顺序，
//       也就没有"绕回"这回事**。
//       于是页号可以当主人、图跟着页走：hud_data_gen 说"我要第 3 张"，
//       这里就去读第 3 张，两张图之间没有任何隐含顺序依赖。
//
// 好处（见 hud_top.v 的"页与图彻底解耦"一节）：
//   - 报警界面立刻出现，不用等 0.3 秒读图
//   - SD 通路和 HUD 通路可以各自独立排错
//
// ============================================================
// 【S_FIND 为什么必须保留】
// ============================================================
//   即使地址是直接算出来的，也还是得先读一个扇区把 BMP 头解析出来：
//   file_len（读到哪停）和 pixel_offset（从哪开始是像素）只有头里有。
//   跳过 S_FIND 就不知道这两个数，整帧读不完或者读出一堆头字节当像素。
//
//   S_FIND 在这一版里的职责变了：不再是"搜索"，而是"**在已知位置的
//   一个小窗口里确认并解析头部**"。窗口 = [目标, 目标 + IMG_STRIDE)。
//   正常情况下第一次读（就在目标扇区上）就命中，256 步的窗口纯粹是兜底 ——
//   万一 layout_sd.py 的常量抄错了，坏的是"这一张读不出来、保留上一帧"，
//   而不是像旧版那样绕回去显示一张完全不相干的图。
//
//   头合法时 found 在第一个扇区结束前必为 1（头部全在前 54 字节内，found 是
//   sticky）。
//
// ★ 不要按"步进"的直觉写 {18'd0,img_index} << 11 ★
//   移位表达式的位宽取【左操作数】的位宽。21 位左移 11 位会在这里截断。
//   用 img_index * IMG_STRIDE，parameter 是 32 位，乘积按 32 位求值，不会截。
// ============================================================
module bmp_read #(
    // ---- 卡上的固定布局（必须和 tools/layout_sd.py 的常量一致）----
    // 图 k 的首扇区 = IMG_BASE_SEC + k * IMG_STRIDE
    // 两者都是 8 的倍数，所以天然满足下面 S_IDLE 的 8 扇区对齐要求。
    parameter [31:0] IMG_BASE_SEC = 32'd16000,
    parameter [31:0] IMG_STRIDE   = 32'd2048,
    parameter [15:0] BMP_HEIGHT   = 16'd480
)(
    input                       clk,
    input                       rst,
    output                      ready,
    input                       find,            // 单拍：请求读一张图
    // find 那一拍采样。由 sd_card_bmp 的"最新目标锁存器"给，值已经稳了很久。
    input[2:0]                  img_index,       // 读第几张图 0..5
    input                       sd_init_done,
    output reg[3:0]             state_code,
    input[15:0]                 bmp_width,
    output reg                  write_req,
    input                       write_req_ack,
    output reg                  sd_sec_read,
    output reg[31:0]            sd_sec_read_addr,
    input[7:0]                  sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,
    output reg                  bmp_data_wr_en,
    output reg[23:0]            bmp_data
);

localparam S_IDLE         = 0;
localparam S_FIND         = 1;
localparam S_READ_WAIT    = 2;
localparam S_READ         = 3;
localparam S_END          = 4;
// 单次扇区读的超时（100MHz 下 1 秒）。一次正常读约 170us，差三个数量级，
// 只用来兜住"卡被拔了 / 没插卡"这种彻底没响应的情况。
localparam TIMEOUT_LIMIT  = 32'd100_000_000;

reg[3:0]         state;
reg[9:0]         rd_cnt;
reg[7:0]         header_0, header_1;
reg[31:0]        file_len;
reg[31:0]        pixel_offset;
reg[31:0]        width, height;
reg[15:0]        bit_count;
reg[31:0]        compression;
reg[31:0]        bmp_len_cnt;
reg              found;
reg[1:0]         bmp_len_cnt_tmp;
reg[31:0]        timeout_cnt;
reg[31:0]        search_end_addr;   // 本次 S_FIND 窗口的终点 = 目标首扇区 + IMG_STRIDE
reg              is_32bit;          // 1=32位BMP(每像素4字节), 0=24位BMP(每像素3字节)

wire bmp_data_valid;
wire header_match;

assign ready = (state == S_IDLE);

// BMP 头部匹配：仅校验 BM签名 + 宽度（避免过于严格导致读不出来）
assign header_match = (header_0 == "B") && (header_1 == "M") &&
                      (width[15:0] == bmp_width);

// 像素数据有效范围：从 pixel_offset 开始到 file_len 结束
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt < file_len);

// ---- 读计数器 ----
always @(posedge clk or posedge rst) begin
    if (rst)
        rd_cnt <= 10'd0;
    else if (state == S_FIND) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else
        rd_cnt <= 10'd0;
end

// ---- BMP 头部解析 ----
always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;   header_1     <= 8'd0;
        file_len     <= 32'd0;  pixel_offset <= 32'd54;
        width        <= 32'd0;  height       <= 32'd0;
        bit_count    <= 16'd0;  compression  <= 32'd0;
        found        <= 1'b0;   is_32bit     <= 1'b0;
    end else if (state == S_FIND && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0:  header_0 <= sd_sec_read_data;
            10'd1:  header_1 <= sd_sec_read_data;
            // 文件长度 (字节2-5, 小端序)
            10'd2:  file_len[7:0]   <= sd_sec_read_data;
            10'd3:  file_len[15:8]  <= sd_sec_read_data;
            10'd4:  file_len[23:16] <= sd_sec_read_data;
            10'd5:  file_len[31:24] <= sd_sec_read_data;
            // 像素数据偏移 (字节10-13, 小端序)
            10'd10: pixel_offset[7:0]   <= sd_sec_read_data;
            10'd11: pixel_offset[15:8]  <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;
            // 图像宽度 (字节18-21)
            10'd18: width[7:0]   <= sd_sec_read_data;
            10'd19: width[15:8]  <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;
            // 图像高度 (字节22-25)
            10'd22: height[7:0]   <= sd_sec_read_data;
            10'd23: height[15:8]  <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;
            // 位深 (字节28-29)
            10'd28: bit_count[7:0]  <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;
            // 压缩方式 (字节30-33)
            10'd30: compression[7:0]   <= sd_sec_read_data;
            10'd31: compression[15:8]  <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
        // 头部读完后校验（仅在匹配时置1，不匹配时保持原值）
        if (rd_cnt == 10'd54 && header_match) begin
            found    <= 1'b1;
            is_32bit <= (bit_count == 16'd32);
        end
    end else if (state != S_FIND)
        found <= 1'b0;
end

// ---- 像素字节计数器 ----
always @(posedge clk or posedge rst) begin
    if (rst)
        bmp_len_cnt <= 32'd0;
    else if (state == S_READ) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else if (state == S_END || state == S_IDLE)
        bmp_len_cnt <= 32'd0;
end

// ---- RGB 三字节计数器 ----
// 在像素数据起始位置(bmp_len_cnt == pixel_offset)强制对齐，防止因 pixel_offset
// 不对齐导致颜色错位。
//
// ！！这里是 2'd1 不是 2'd0 ！！
//   pixel_data_start 那一拍，下面的装配块已经用【当前】的 bmp_len_cnt_tmp(此时为0)
//   把 byte0(B) 装进了 bmp_data[7:0]。若此处再强制归零，下一个字节会重复装到
//   [7:0] 把 B 覆盖，整条字节流错位一格，导致三通道旋转：
//       {R,G,B} -> {B,R,G} -> 图像结构正常但颜色全错
//   （24bit: 0,1,2 / 32bit: 0,1,2,3 两种都会被错位）
//   所以正确做法是"本拍已消费 byte0"，下一拍从 byte1 开始。
wire pixel_data_start = (bmp_len_cnt == pixel_offset) && bmp_data_valid;

always @(posedge clk or posedge rst) begin
    if (rst)
        bmp_len_cnt_tmp <= 2'd0;
    else if (state == S_READ) begin
        if (pixel_data_start)
            bmp_len_cnt_tmp <= 2'd1;        // 本拍已装 byte0，下一字节从 byte1 起
        else if (bmp_data_valid)
            bmp_len_cnt_tmp <= (bmp_len_cnt_tmp == (is_32bit ? 2'd3 : 2'd2)) ? 2'd0 : bmp_len_cnt_tmp + 2'd1;
    end else
        bmp_len_cnt_tmp <= 2'd0;
end

// ---- 像素数据输出 (BMP的BGR顺序 -> RGB, 兼容24位和32位BMP) ----
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == S_READ) begin
        if (bmp_data_valid) begin
            // 装配像素数据：byte0=B, byte1=G, byte2=R, byte3=A(32位时忽略)
            case (bmp_len_cnt_tmp)
                2'd0: bmp_data[7:0]   <= sd_sec_read_data; // B
                2'd1: bmp_data[15:8]  <= sd_sec_read_data; // G
                2'd2: bmp_data[23:16] <= sd_sec_read_data; // R
                default: ; // byte3: 32位BMP的A通道，忽略
            endcase
            // 输出使能：24位在byte2触发，32位在byte3触发
            if (bmp_len_cnt_tmp == (is_32bit ? 2'd3 : 2'd2))
                bmp_data_wr_en <= 1'b1;
            else
                bmp_data_wr_en <= 1'b0;
        end else
            bmp_data_wr_en <= 1'b0;
    end else
        bmp_data_wr_en <= 1'b0;
end

// ---- 主状态机 ----
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state           <= S_IDLE;
        sd_sec_read     <= 1'b0;
        sd_sec_read_addr <= IMG_BASE_SEC;      // 上电默认指向第 0 张
        write_req       <= 1'b0;
        state_code      <= 4'd0;
        timeout_cnt     <= 32'd0;
        search_end_addr <= IMG_BASE_SEC + IMG_STRIDE;
    end else if (!sd_init_done) begin
        state       <= S_IDLE;
        sd_sec_read <= 1'b0;
        timeout_cnt <= 32'd0;
    end else case (state)
        S_IDLE: begin
            state_code  <= 4'd1;
            timeout_cnt <= 32'd0;
            if (find) begin
                state <= S_FIND;
                // ★ 这里是"页 → 图"的唯一落地点 ★
                //   IMG_STRIDE 是 32 位 parameter，所以乘积按 32 位求值。
                //   写成 {18'd0,img_index} << 11 会因为左操作数只有 21 位而截断。
                sd_sec_read_addr <= IMG_BASE_SEC + img_index * IMG_STRIDE;
                search_end_addr  <= IMG_BASE_SEC + img_index * IMG_STRIDE + IMG_STRIDE;
            end
        end

        S_FIND: begin
            state_code <= 4'd2;
            if (timeout_cnt >= TIMEOUT_LIMIT) begin
                // 扇区读彻底没响应（拔卡/没卡）——放弃，保留上一帧
                state       <= S_IDLE;
                sd_sec_read <= 1'b0;
                timeout_cnt <= 32'd0;
            end else if (sd_sec_read_end) begin
                state_code  <= 4'd3;
                timeout_cnt <= 32'd0;
                if (found) begin
                    state       <= S_READ_WAIT;
                    sd_sec_read <= 1'b0;
                    write_req   <= 1'b1;
                end else if (sd_sec_read_addr + 32'd8 >= search_end_addr) begin
                    // 窗口扫满了还是没找到合法的 BMP 头。
                    // 【有界兜底】：直接放弃，回 S_IDLE，
                    // 不产生 write_req -> 帧缓冲不换页 -> 屏幕上保持上一帧。
                    //
                    // ★ 这里【故意不做】旧版的"绕回第一张"★
                    //   绕回会在页 3 上显示出第 0 张的底图，页和图错位之后
                    //   再也对不回来，而且看不出是哪一步错的。
                    //   停在上一帧 + 数码管 state_code 停在 1，
                    //   一眼就能判定"这个索引的扇区常量抄错了"。
                    state       <= S_IDLE;
                    sd_sec_read <= 1'b0;
                end else
                    sd_sec_read_addr <= sd_sec_read_addr + 32'd8;
            end else begin
                sd_sec_read <= 1'b1;
                timeout_cnt <= timeout_cnt + 32'd1;
            end
        end

        S_READ_WAIT: begin
            if (write_req_ack) begin
                state     <= S_READ;
                write_req <= 1'b0;
            end
        end

        S_READ: begin
            state_code <= 4'd4;
            if (sd_sec_read_end) begin
                sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                sd_sec_read      <= 1'b0;
                if (bmp_len_cnt >= file_len) begin
                    state       <= S_END;
                    sd_sec_read <= 1'b0;
                end
            end else
                sd_sec_read <= 1'b1;
        end

        S_END: begin
            // 一张读完，回 S_IDLE 等下一次 find。
            // 下一次 find 会重新从 IMG_BASE_SEC + idx*IMG_STRIDE 算地址，
            // 所以这里 sd_sec_read_addr 停在哪都无所谓 —— 这正是"直读"的好处，
            // 不像旧版必须记住第一张的地址才能绕回来。
            state <= S_IDLE;
        end

        default: state <= S_IDLE;
    endcase
end

endmodule
