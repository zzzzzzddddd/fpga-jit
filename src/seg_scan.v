
// ============================================================================
// seg_scan.v -- 8 位数码管动态扫描（原厂例程从 6 位扩到 8 位）
//
// 扩位时改了三处，漏一处就会出问题：
//   1. SCAN_COUNT 里的 *6 -> *8
//      写成 *6 的话每位停留时间只有应该的 6/8，整帧刷新率从 200Hz 掉到 150Hz，
//      而且 8 位扫完一轮的时间变长，肉眼会看到轻微闪烁。
//   2. scan_sel 的回绕点 4'd5 -> 4'd7
//   3. seg_sel 的复位值/one-hot 字面量全部加宽到 8 位
//
// 位选和段选都是【低有效】：seg_sel 里被拉低的那一位点亮，
// seg_data 的 MSB 是小数点，也是低有效（8'hff = 全灭）。
// ============================================================================
module seg_scan(
	input           clk,
	input           rst_n,
	output reg[7:0] seg_sel,      //digital led chip select
	output reg[7:0] seg_data,     //eight segment digital tube output,MSB is the decimal point
	input[7:0]      seg_data_0,
	input[7:0]      seg_data_1,
	input[7:0]      seg_data_2,
	input[7:0]      seg_data_3,
	input[7:0]      seg_data_4,
	input[7:0]      seg_data_5,
	input[7:0]      seg_data_6,
	input[7:0]      seg_data_7
);
parameter SCAN_FREQ = 200;     //scan frequency
parameter CLK_FREQ = 50000000; //clock frequency

parameter SCAN_COUNT = CLK_FREQ /(SCAN_FREQ * 8) - 1;

reg[31:0] scan_timer;  //scan time counter
reg[3:0] scan_sel;     //Scan select counter
always@(posedge clk or negedge rst_n)
begin
	if(rst_n == 1'b0)
	begin
		scan_timer <= 32'd0;
		scan_sel <= 4'd0;
	end
	else if(scan_timer >= SCAN_COUNT)
	begin
		scan_timer <= 32'd0;
		if(scan_sel == 4'd7)
			scan_sel <= 4'd0;
		else
			scan_sel <= scan_sel + 4'd1;
	end
	else
		begin
			scan_timer <= scan_timer + 32'd1;
		end
end
always@(posedge clk or negedge rst_n)
begin
	if(rst_n == 1'b0)
	begin
		seg_sel <= 8'b11111111;
		seg_data <= 8'hff;
	end
	else
	begin
		case(scan_sel)
			//first digital led
			4'd0:
			begin
				seg_sel <= 8'b1111_1110;
				seg_data <= seg_data_0;
			end
			//second digital led
			4'd1:
			begin
				seg_sel <= 8'b1111_1101;
				seg_data <= seg_data_1;
			end
			//...
			4'd2:
			begin
				seg_sel <= 8'b1111_1011;
				seg_data <= seg_data_2;
			end
			4'd3:
			begin
				seg_sel <= 8'b1111_0111;
				seg_data <= seg_data_3;
			end
			4'd4:
			begin
				seg_sel <= 8'b1110_1111;
				seg_data <= seg_data_4;
			end
			4'd5:
			begin
				seg_sel <= 8'b1101_1111;
				seg_data <= seg_data_5;
			end
			4'd6:
			begin
				seg_sel <= 8'b1011_1111;
				seg_data <= seg_data_6;
			end
			4'd7:
			begin
				seg_sel <= 8'b0111_1111;
				seg_data <= seg_data_7;
			end
			default:
			begin
				seg_sel <= 8'b1111_1111;
				seg_data <= 8'hff;
			end
		endcase
	end
end

endmodule
