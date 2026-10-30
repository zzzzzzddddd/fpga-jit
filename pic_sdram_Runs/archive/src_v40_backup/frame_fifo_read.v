`timescale 1ns/1ps
// ============================================================
// frame_fifo_read.v — 带行倒序寻址的帧读取控制器
//
// 功能：从 SDRAM 读取一帧图像数据到读 FIFO，供视频显示侧消费。
//       本版增加了行倒序寻址（ROW_REVERSE=1），用于修正 BMP 底行在前
//       导致的图像上下颠倒问题。
//
// 原理：BMP 像素存储顺序为 bottom-to-top。写入 SDRAM 时按线性地址
//       （第0行→地址0，第1行→地址640，...），读出时从最后一行开始
//       （第479行→地址306560），逐行递减，使显示器看到正像。
// ============================================================
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128,
	parameter IMG_WIDTH              = 640,
	parameter IMG_HEIGHT             = 480,
	parameter ROW_REVERSE            = 1       // 1=行倒序读取(修正BMP上下颠倒), 0=正常顺序
)
(
	input                            rst,
	input                            mem_clk,
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
	input							 Sdr_busy,
	input							 Sdr_rd_en,
	input							 App_wr_busy,
	output							 O_rd_busy,

	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,

	input                            read_req,
	output reg                       read_req_ack,
	output                           read_finish,
	input[ADDR_BITS - 1:0]           read_addr_0,
	input[ADDR_BITS - 1:0]           read_addr_1,
	input[ADDR_BITS - 1:0]           read_addr_2,
	input[ADDR_BITS - 1:0]           read_addr_3,
	input[1:0]                       read_addr_index,
	input[ADDR_BITS - 1:0]           read_len,
	output reg                       fifo_aclr,
	input[9:0]                      wrusedw
);
localparam ONE                       = 256'd1;
localparam ZERO                      = 256'd0;
localparam S_IDLE                    = 0;
localparam S_ACK                     = 1;
localparam S_CHECK_FIFO              = 2;
localparam S_READ_BURST              = 3;
localparam S_READ_BURST_END          = 4;
localparam S_END                     = 5;

reg                                  read_req_d0;
reg                                  read_req_d1;
reg                                  read_req_d2;
reg[ADDR_BITS - 1:0]                 read_len_d0;
reg[ADDR_BITS - 1:0]                 read_len_d1;
reg[ADDR_BITS - 1:0]                 read_len_latch;
reg[ADDR_BITS - 1:0]                 read_cnt;
reg[3:0]                             state;
reg[1:0]                             read_addr_index_d0;
reg[1:0]                             read_addr_index_d1;
reg [ADDR_BITS - 1:0]	             App_rd_addr_r;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								rd_burst_finish;
reg App_rd_en_r;
reg App_rd_en_d0;

wire rd_vld;
reg [3:0] rd_delay;

// ---- 行倒序寻址寄存器 ----
reg [9:0]                  col_cnt;      // 列计数器 (0 ~ IMG_WIDTH-1)
reg [ADDR_BITS-1:0]        row_base;     // 当前行起始地址

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
assign rd_vld = (state == S_READ_BURST && burst_cnt >= BURST_SIZE);
assign O_rd_busy = (state == S_READ_BURST);
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10);
assign read_finish = (state == S_END) ? 1'b1 : 1'b0;
assign App_rd_en = App_rd_en_d0;

always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];
		read_addr_index_d0 <= 2'b00;
		read_addr_index_d1 <= 2'b00;
	end
	else
	begin
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0;
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
	end
end

always@(posedge mem_clk or posedge rst)
begin
	if(rst)begin
        rd_delay <= 4'd0;
    end
    else if(App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end

// ---- 突发计数器 + 地址生成 ----
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt      <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r  <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0   <= 1'b0;
		col_cnt        <= 10'd0;
		row_base       <= ZERO[ADDR_BITS - 1:0];
	end
	else begin
		// 突发计数器
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;

		// ---- 地址生成 ----
		if(state == S_ACK) begin
			// S_ACK 状态：初始化起始地址
			col_cnt <= 10'd0;
			if(ROW_REVERSE) begin
				// 行倒序：从最后一行开始读
				row_base <= read_addr_0 + (IMG_HEIGHT - 1) * IMG_WIDTH;
				case(read_addr_index_d1)
					2'd0: App_rd_addr_r <= read_addr_0 + (IMG_HEIGHT - 1) * IMG_WIDTH;
					2'd1: App_rd_addr_r <= read_addr_1 + (IMG_HEIGHT - 1) * IMG_WIDTH;
					2'd2: App_rd_addr_r <= read_addr_2 + (IMG_HEIGHT - 1) * IMG_WIDTH;
					2'd3: App_rd_addr_r <= read_addr_3 + (IMG_HEIGHT - 1) * IMG_WIDTH;
				endcase
			end else begin
				// 正常顺序
				case(read_addr_index_d1)
					2'd0: App_rd_addr_r <= read_addr_0;
					2'd1: App_rd_addr_r <= read_addr_1;
					2'd2: App_rd_addr_r <= read_addr_2;
					2'd3: App_rd_addr_r <= read_addr_3;
				endcase
			end
		end
		else if(App_rd_en) begin
			if(ROW_REVERSE) begin
				// 行倒序：列递增，行结束时跳到上一行
				if(col_cnt == IMG_WIDTH - 1) begin
					col_cnt      <= 10'd0;
					row_base     <= row_base - IMG_WIDTH;
					App_rd_addr_r <= row_base - IMG_WIDTH;
				end else begin
					col_cnt      <= col_cnt + 10'd1;
					App_rd_addr_r <= row_base + col_cnt + 1;
				end
			end else begin
				// 正常顺序：线性递增
				App_rd_addr_r <= App_rd_addr_r + 1'b1;
			end
		end
		else
			App_rd_addr_r <= App_rd_addr_r;

		// App_rd_en 生成
		if(App_rd_en_r && burst_cnt + App_rd_en < BURST_SIZE)
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;
	end
end

// ---- 主状态机 ----
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_r <= 1'b0;
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		read_req_ack <= 1'b0;
	end
	else
		case(state)
			S_IDLE:
			begin
				if(read_req_d2 == 1'b1 && Sdr_init_done)
					state <= S_ACK;
				read_req_ack <= 1'b0;
			end

			S_ACK:
			begin
				if(read_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					read_req_ack <= 1'b0;
				end
				else
				begin
					read_req_ack <= 1'b1;
					fifo_aclr <= 1'b1;
					read_len_latch <= read_len_d1;
				end
				read_cnt <= ZERO[ADDR_BITS - 1:0];
			end

			S_CHECK_FIFO:
			begin
				if(read_req_d2 == 1'b1)
					state <= S_ACK;
				else if(wrusedw < (FIFO_DEPTH - BURST_SIZE) && ~App_wr_busy)
				begin
					state <= S_READ_BURST;
					App_rd_en_r <= 1'b1;
				end
			end

			S_READ_BURST:
			begin
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					read_cnt <= read_cnt + BURST_SIZE[ADDR_BITS - 1:0];
				end
			end

			S_READ_BURST_END:
			begin
				if(read_req_d2 == 1'b1)
					state <= S_ACK;
				else if(read_cnt < read_len_latch)
					state <= S_CHECK_FIFO;
				else
					state <= S_END;
			end

			S_END:
			begin
				state <= S_IDLE;
			end

			default:
				state <= S_IDLE;
		endcase
end

endmodule
