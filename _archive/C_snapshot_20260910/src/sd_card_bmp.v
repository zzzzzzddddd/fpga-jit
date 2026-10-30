// ============================================================
// sd_card_bmp.v — SD卡BMP读取控制器（支持轮播）
// 功能：
//   1) 按键触发：KEY1按下后读取BMP文件
//   2) 轮播触发：外部find_ext脉冲触发读取下一张
//   3) 忙时锁存：读取过程中按键被锁存，空闲后自动补发
// ============================================================
module sd_card_bmp(
    input                       clk,
    input                       rst,
    input                       key,                //press the button to start searching for the BMP file
    output [3:0]                state_code,         //state indication coding,
                                                    // 0:SD card is initializing,
                                                    // 1:wait for the button to press
                                                    // 2:looking for the bmp file
                                                    // 3:reading
    input [15:0]                bmp_width,          //search the width of bmp
    output                      write_req,          //start writing request
    input                       write_req_ack,      //write request response
    output                      write_en,           //bmp image data write enable
    output [31:0]               write_data,         //bmp image data
    output                      SD_nCS,             //SD card chip select (SPI mode)
    output                      SD_DCLK,            //SD card clock
    output                      SD_MOSI,            //SD card controller data output
    input                       SD_MISO,            //SD card controller data input
    // ---- 基础2 集成新增 ----
    input                       find_ext,           // 外部轮播触发脉冲(carousel_ctl.find_pulse)
    output                      bmp_ready           // bmp_read.ready 引出(供 carousel_ctl 门控)
);

wire button_negedge;

// ---- 按键锁存：bmp_read 忙(读图中)时按 KEY 不丢，空闲后立即补发一次 ----
// 注意：rst 为高有效复位(rst=1 复位)，工作态 rst=0
reg key_pend;
always @(posedge clk or posedge rst) begin
    if (rst)                 key_pend <= 1'b0;
    else if (bmp_ready)      key_pend <= 1'b0;    // 空闲:消费(清除锁存)
    else if (button_negedge) key_pend <= 1'b1;    // 忙时按键:锁存请求
end
wire find_manual = button_negedge | key_pend;    // 空闲按键立即触发;忙时按键空闲后补发

ax_debounce ax_debounce_m0(
    .clk             (clk),
    .rst             (rst),
    .button_in       (key),
    .button_posedge  (),
    .button_negedge  (button_negedge),
    .button_out      ()
);

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data; //synthesis keep
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;

assign write_en = bmp_data_wr_en;
assign write_data = {bmp_data[23:16],bmp_data[15:8],bmp_data[7:0],8'b0};

bmp_read bmp_read_m0(
    .clk                       (clk                    ),
    .rst                       (rst                    ),
    .ready                     (bmp_ready              ),
    // 基础2: 手动翻图=按键直连(官方 lab_ex_6 方式)+忙时锁存补发；
    // 轮播触发=carousel_ctl.find_pulse(find_ext)。两条路径互不干扰。
    .find                      (find_manual | find_ext ), // 按键直连+锁存 | 轮播触发
    .sd_init_done              (sd_init_done           ),
    .state_code                (state_code             ),
    .bmp_width                 (bmp_width              ),
    .write_req                 (write_req              ),
    .write_req_ack             (write_req_ack          ),
    .sd_sec_read               (sd_sec_read            ),
    .sd_sec_read_addr          (sd_sec_read_addr       ),
    .sd_sec_read_data          (sd_sec_read_data       ),
    .sd_sec_read_data_valid    (sd_sec_read_data_valid ),
    .sd_sec_read_end           (sd_sec_read_end        ),
    .bmp_data_wr_en            (bmp_data_wr_en         ),
    .bmp_data                  (bmp_data               )
);

sd_card_top sd_card_top_m0(
    .clk                       (clk                    ),
    .rst                       (rst                    ),
    .SD_nCS                    (SD_nCS                 ),
    .SD_DCLK                   (SD_DCLK                ),
    .SD_MOSI                   (SD_MOSI                ),
    .SD_MISO                   (SD_MISO                ),
    .sd_init_done              (sd_init_done           ),
    .sd_sec_read               (sd_sec_read            ),
    .sd_sec_read_addr          (sd_sec_read_addr       ),
    .sd_sec_read_data          (sd_sec_read_data       ),
    .sd_sec_read_data_valid    (sd_sec_read_data_valid ),
    .sd_sec_read_end           (sd_sec_read_end        ),
    .sd_sec_write              (1'b0                   ),
    .sd_sec_write_addr         (32'd0                  ),
    .sd_sec_write_data         (                       ),
    .sd_sec_write_data_req     (                       ),
    .sd_sec_write_end          (                       )
);

endmodule
