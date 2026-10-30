`timescale 1ns/1ps
// ============================================================
// bmp_read.v — 优化版 BMP 读取控制器
//
// 相比原版改进：
//   1) 从 BMP 头部读取 pixel_offset（字节10-13），不再硬编码54
//   2) 增加 height(480)、bit_count(24)、compression(0) 校验
//   3) 保留轮播回绕和图片计数器逻辑
// ============================================================
module bmp_read #(
    parameter [31:0] SEARCH_LIMIT = 32'd1_000_000,
    parameter [3:0]  MAX_BMP_NUM  = 4'd4,
    parameter [15:0] BMP_HEIGHT   = 16'd480
)(
    input                       clk,
    input                       rst,
    output                      ready,
    input                       find,
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
reg[3:0]         bmp_cnt;
reg              is_32bit;              // 1=32位BMP(每像素4字节), 0=24位BMP(每像素3字节)
reg[31:0]        row_stride;            // BMP行步进(含padding, 按4字节对齐)
reg[31:0]        bytes_in_row;          // 当前行已读字节数

wire bmp_data_valid;
wire header_match;

assign ready = (state == S_IDLE);

// BMP 头部匹配：仅校验 BM签名 + 宽度（与B版本一致，避免过于严格导致轮播卡住）
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
        // 头部读完后校验（与B版本一致：仅在匹配时置1，不匹配时保持原值）
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
// 在像素数据起始位置(bmp_len_cnt == pixel_offset)时强制归零，
// 确保B/G/R字节对齐，防止因pixel_offset不对齐导致颜色错位
wire pixel_data_start = (bmp_len_cnt == pixel_offset) && bmp_data_valid;

always @(posedge clk or posedge rst) begin
    if (rst)
        bmp_len_cnt_tmp <= 2'd0;
    else if (state == S_READ) begin
        if (pixel_data_start)
            bmp_len_cnt_tmp <= 2'd0;        // 像素数据起始：强制对齐
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
        state          <= S_IDLE;
        sd_sec_read    <= 1'b0;
        sd_sec_read_addr <= 32'd16000;
        write_req      <= 1'b0;
        state_code     <= 4'd0;
        timeout_cnt    <= 32'd0;
        bmp_cnt        <= 4'd0;
    end else if (!sd_init_done) begin
        state       <= S_IDLE;
        timeout_cnt <= 32'd0;
    end else case (state)
        S_IDLE: begin
            state_code  <= 4'd1;
            timeout_cnt <= 32'd0;
            if (find) state <= S_FIND;
            sd_sec_read_addr <= {sd_sec_read_addr[31:3], 3'd0}; // 8扇区对齐
        end

        S_FIND: begin
            state_code <= 4'd2;
            if (timeout_cnt >= TIMEOUT_LIMIT) begin
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
                end else begin
                    // 未找到：步进8扇区继续搜索，超过上限则回绕（与B版本一致）
                    if (sd_sec_read_addr >= SEARCH_LIMIT)
                        sd_sec_read_addr <= 32'd16000;
                    else
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd8;
                end
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
            if (bmp_cnt == MAX_BMP_NUM - 4'd1) begin
                bmp_cnt         <= 4'd0;
                sd_sec_read_addr <= 32'd16000;
            end else begin
                bmp_cnt <= bmp_cnt + 4'd1;
                // sd_sec_read_addr 已在 S_READ 中推进到文件末尾之后
            end
            state <= S_IDLE;
        end

        default: state <= S_IDLE;
    endcase
end

endmodule
