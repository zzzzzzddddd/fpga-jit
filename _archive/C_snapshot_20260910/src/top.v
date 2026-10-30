// ============================================================
// top.v — 基础1+基础2+基础3 集成顶层（HX4S20C 板上板工程）
// 基于官方 lab_ex_6 工程 + 基础2/基础3 改造：
//   基础1) 自动轮播+手动翻图：carousel_ctl（KEY1 手动翻图 / KEY2 切轮播）
//   基础2) 无闪烁双缓冲：dbl_buf_ctl + dbl_buf_addr（写非显示帧/读显示帧）
//          轮播回绕：bmp_read.v 已替换为回绕版（SEARCH_LIMIT 超限回 16000）
//   基础3) I2S音频：audio_gen(48kHz 1kHz正弦) + i2s_tx(FPGA master) + sin_lut
//          音频时钟12.5MHz(100MHz/8,近似标准12.288MHz,误差1.7%)
//          I2S信号保留在内部, 待官方2026 HDMI音频IP(lab_ex_5)集成后接入HDMI
// 按键分配（手册 p19）：
//   A2=KEY1 -> rst_n(复位)   B2=KEY2 -> key1(翻图,官方原绑定)
//   B1=KEY3 -> key2(新增,轮播/手动模式切换)
// ============================================================
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,
    input                       key2,               // 基础2新增: 轮播/手动模式切换
    output [5:0]                seg_sel,
    output [7:0]                seg_data,
    output                      vga_out_hs,
    output                      vga_out_vs,
    output [11:0]               vga_data,
    //HDMI
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,
    //HDMI DDC (EDID读取, HDMI1.4b音频核心需要)
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,
    output                      sd_ncs,            //SD card chip select (SPI mode)
    output                      sd_dclk,           //SD card clock
    output                      sd_mosi,           //SD card controller data output
    input                       sd_miso            //SD card controller data input
);

parameter MEM_DATA_BITS         = 32  ;            //external memory user interface data width
parameter ADDR_BITS             = 21  ;            //external memory user interface address width
parameter BUSRT_BITS            = 10  ;            //external memory user interface burst width

wire                            vga_out_de;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire                            read_req;
wire                            read_req_ack;
wire                            read_en;
wire                            write_en;
wire                            write_req;
wire                            write_req_ack;
wire                            sd_card_clk;       //SD card controller clock
wire                            ext_mem_clk;       //external memory clock
wire                            ext_mem_clk_sft;

wire                            video_clk;         //video pixel clock
wire                            hdmi_5x_clk;
wire                            hs;
wire                            vs;
wire                            de;
wire [23:0]                     vout_data;
wire [3:0]                      state_code;
wire [6:0]                      seg_data_0;

wire                            video_read_req;
wire                            video_read_req_ack;
wire                            video_read_en;
wire [31:0]                     video_read_data;
wire                            sd_card_write_en;
wire [31:0]                     sd_card_write_data;
wire                            sd_card_write_req;
wire                            sd_card_write_req_ack;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS - 1 : 0]Sdr_rd_dout;

wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS - 1 : 0]App_wr_din;
wire [3:0] App_wr_dm;

// ================= 基础2 集成信号 =================
wire                            bmp_ready;          // bmp_read.ready
wire                            key2_nedge;         // key2 消抖沿(模式切换)
wire                            carousel_find;      // carousel_ctl 触发脉冲
wire                            carousel_en_wire;   // 1=轮播 0=手动
wire                            frame_sel;          // 写域帧号
wire                            frame_sel_v;        // 读域同步后帧号
wire                            frame_done;         // 一帧写完(state_code 4->1)
wire [23:0]                     write_base;         // 写基地址(非显示帧)
wire [23:0]                     read_base;          // 读基地址(显示帧)
reg  [3:0]                      state_code_d;
reg                             frame_sel_v1, frame_sel_v2;

// frame_done 沿检测: state_code 从 4(写中) 回到 1(等待) = 一帧写完 (sd_card_clk 域)
always @(posedge sd_card_clk or negedge rst_n) begin
    if (!rst_n)
        state_code_d <= 4'd0;
    else
        state_code_d <= state_code;
end
assign frame_done = (state_code == 4'd1) && (state_code_d == 4'd4);

// key2 消抖 (与 key1 同域: sd_card_clk)
ax_debounce ax_debounce_key2_m0(
    .clk             (sd_card_clk),
    .rst             (~rst_n),
    .button_in       (key2),
    .button_posedge  (),
    .button_negedge  (key2_nedge),
    .button_out      ()
);

// 轮播+手动控制器 (sd_card_clk 域)
carousel_ctl #(.FREQ_MHZ(100), .INTERVAL_MS(5000)) carousel_m0(
    .clk            (sd_card_clk),
    .rst_n          (rst_n),
    .key_mode_nedge (key2_nedge),
    .ready          (bmp_ready),
    .carousel_en    (carousel_en_wire),
    .find_pulse     (carousel_find)
);

// 双缓冲帧切换 (sd_card_clk 域)
dbl_buf_ctl #(.ADDR_BITS(21), .FRAME_WORDS(307200)) dbl_buf_m0(
    .clk           (sd_card_clk),
    .rst_n         (rst_n),
    .frame_done    (frame_done),
    .frame_sel     (frame_sel)
);

// 读写基地址 (写非显示帧/读显示帧)
dbl_buf_addr #(.FRAME_WORDS(307200)) dbl_buf_addr_m0(
    .frame_sel     (frame_sel),
    .frame_sel_v   (frame_sel_v),
    .write_base    (write_base),
    .read_base     (read_base)
);

// frame_sel 跨时钟域: 写域(sd_card_clk) -> 读域(video_clk) 两级触发器同步
always @(posedge video_clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_sel_v1 <= 1'b0;
        frame_sel_v2 <= 1'b0;
    end else begin
        frame_sel_v1 <= frame_sel;
        frame_sel_v2 <= frame_sel_v1;
    end
end
assign frame_sel_v = frame_sel_v2;
// =====================================================

// ================= 基础3: HDMI 1.4b 内嵌音频信号 =================
// 官方lab_ex5_i2s方案: PLL_HDMI_AUDIO精确产生12.288MHz -> I2S测试音(64fs)
//   -> I2S_receiver转24bit并行 -> ACR计算 -> HDMI1.4b核心打包音视频 -> PHY输出
wire                            audio_pll_lock;     // 音频PLL锁定标志
wire                            audio_mclk;         // 12.288MHz 精确音频主时钟
wire                            audio_i2s_bclk;     // I2S位时钟(64fs=3.072MHz)
wire                            audio_i2s_lrck;     // I2S帧时钟(48kHz)
wire                            audio_i2s_dout;     // I2S串行数据
wire                            audio_valid;         // 音频采样有效
wire [23:0]                     audio_left_data;    // 左声道24bit
wire [23:0]                     audio_right_data;   // 右声道24bit
wire                            acr_valid;           // ACR有效
wire [19:0]                     acr_cts;             // ACR CTS值
wire [19:0]                     acr_n;               // ACR N值
// AXIS视频流(RGB->AXIS转换)
wire                            axis_s_user;
wire                            axis_s_valid;
wire                            axis_s_last;
wire [23:0]                     axis_s_data;
wire                            axis_s_ready;
// EDID
wire                            edid_trig;
wire                            edid_valid;
wire [7:0]                      edid_data;
// TMDS 10bit数据(HDMI核心->PHY)
wire [9:0]                      tmds_ch0_data;
wire [9:0]                      tmds_ch1_data;
wire [9:0]                      tmds_ch2_data;
wire [9:0]                      tmds_clk_data;
// 统一复位: 系统复位 + 音频PLL未锁定
wire                            rst_all;
assign rst_all = ~rst_n | ~audio_pll_lock;
// =====================================================

assign vga_out_hs = hs;
assign vga_out_vs = vs;
assign vga_out_de = de;
assign vga_data = {vout_data[23:20],vout_data[15:12],vout_data[7:4]};

//generate SD card controller clock and SDRAM controller clock
sys_pll sys_pll_m0(
    .refclk                     (clk),
    .clk0_out                   (sd_card_clk),
    .clk1_out                   (ext_mem_clk),
    .clk2_out                   (ext_mem_clk_sft),
    .reset                      (1'b0)
);

//generate video pixel clock
video_pll video_pll_m0(
    .refclk                     (clk),
    .clk0_out                   (video_clk),
    .clk1_out                   (hdmi_5x_clk),
    .reset                      (1'b0)
);

//基础3: 精确12.288MHz音频主时钟PLL (clk2_out, VCO=75MHz/61分频)
PLL_HDMI_AUDIO u_audio_pll(
    .refclk                     (clk),
    .reset                      (1'b0),
    .extlock                    (audio_pll_lock),
    .clk0_out                   (),
    .clk1_out                   (),
    .clk2_out                   (audio_mclk)
);

//SD card BMP file read
sd_card_bmp  sd_card_bmp_m0(
    .clk                        (sd_card_clk              ),
    .rst                        (~rst_n                   ),
    .key                        (key1                     ),
    .state_code                 (state_code               ),
    .bmp_width                  (16'd640                  ),  //image width
    .write_req                  (sd_card_write_req        ),
    .write_req_ack              (sd_card_write_req_ack    ),
    .write_en                   (sd_card_write_en         ),
    .write_data                 (sd_card_write_data       ),
    .SD_nCS                     (sd_ncs                   ),
    .SD_DCLK                    (sd_dclk                  ),
    .SD_MOSI                    (sd_mosi                  ),
    .SD_MISO                    (sd_miso                  ),
    .find_ext                   (carousel_find            ),  //基础2: 轮播触发
    .bmp_ready                  (bmp_ready                )   //基础2: 空闲门控
);

//with a digital display of state_code
// 0:SD card is initializing
// 1:wait for the button to press
// 2:looking for the bmp file
// 3:wait for the fifo
// 4:reading
seg_decoder seg_decoder_m0(
    .bin_data                   (state_code               ),
    .seg_data                   (seg_data_0               )
);

seg_scan seg_scan_m0(
    .clk                        (clk                      ),
    .rst_n                      (rst_n                    ),
    .seg_sel                    (seg_sel                  ),
    .seg_data                   (seg_data                 ),
    .seg_data_0                 ({1'b1,7'b1111_111}       ),
    .seg_data_1                 ({1'b1,7'b1111_111}       ),
    .seg_data_2                 ({1'b1,7'b1111_111}       ),
    .seg_data_3                 ({1'b1,7'b1111_111}       ),
    .seg_data_4                 ({1'b1,7'b1111_111}       ),
    .seg_data_5                 ({1'b1,seg_data_0}        )
);

wire hs_0;
wire vs_0;
wire de_0;
video_timing_data video_timing_data_m0(
    .video_clk                  (video_clk                ),
    .rst                        (~rst_n                   ),
    .read_req                   (video_read_req           ),
    .read_req_ack               (video_read_req_ack       ),
    .hs                         (hs_0                     ),
    .vs                         (vs_0                     ),
    .de                         (de_0                     )
);

video_delay video_delay_m0(
    .video_clk                  (video_clk                ),
    .rst                        (~rst_n                   ),
    .read_en                    (video_read_en            ),
    .read_data                  (video_read_data[31:8]    ),
    .hs                         (hs_0                     ),
    .vs                         (vs_0                     ),
    .de                         (de_0                     ),
    .hs_r                       (hs                       ),
    .vs_r                       (vs                       ),
    .de_r                       (de                       ),
    .vout_data                  (vout_data                )
);

//基础3: RGB/DE/VS 转 AXIS 视频流 (640x480)
video_rgb_to_axis_640x480 u_video_rgb_to_axis(
    .I_clk                     (video_clk),
    .I_rst                     (rst_all),
    .I_vs                      (vs),
    .I_de                      (de),
    .I_rgb                     (vout_data),
    .O_video_user              (axis_s_user),
    .O_video_valid             (axis_s_valid),
    .O_video_last              (axis_s_last),
    .O_video_data              (axis_s_data)
);

//上电后自动打一拍, 触发一次EDID读取
startup_pulse #(.CNT_MAX(20'd100000)) u_startup_pulse(
    .I_clk                     (video_clk),
    .I_rst                     (rst_all),
    .O_pulse                   (edid_trig)
);

//基础3: HDMI 1.4b 发送器核心 (视频AXIS + 音频I2S打包 + ACR + DDC/EDID + TMDS编码)
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                    ("EG"),
    .HTOTAL                    (800),
    .HSA                       (96),
    .HFP                       (16),
    .HBP                       (48),
    .HACTIVE                   (640),
    .VTOTAL                    (525),
    .VSA                       (2),
    .VFP                       (10),
    .VBP                       (33),
    .VACTIVE                   (480),
    .VIDEO_VIC                 (1),
    .VIDEO_TPG                 ("Disable"),
    .VIDEO_FORMAT              ("RGB"),
    .AUDIO_SAMPLE_RATE         ("48K"),
    .IIC_SCL_DIV               (250)
) u_hdmi_core(
    .I_pixel_clk               (video_clk),
    .I_rst                     (rst_all),
    .I_edid_read_trig          (edid_trig),
    .O_edid_read_valid         (edid_valid),
    .O_edid_read_data          (edid_data),
    .I_axis_s_user             (axis_s_user),
    .I_axis_s_valid            (axis_s_valid),
    .I_axis_s_last             (axis_s_last),
    .I_axis_s_data             (axis_s_data),
    .O_axis_s_ready            (axis_s_ready),
    .I_audio_valid             (audio_valid),
    .I_audio_left_data         (audio_left_data),
    .I_audio_right_data        (audio_right_data),
    .I_acr_valid               (acr_valid),
    .I_acr_cts                 (acr_cts),
    .I_acr_n                   (acr_n),
    .O_video_locked            (),
    .O_ddc_scl                 (HDMI_DDC_SCL),
    .IO_ddc_sda                (HDMI_DDC_SDA),
    .O_ch0_tmds_data           (tmds_ch0_data),
    .O_ch1_tmds_data           (tmds_ch1_data),
    .O_ch2_tmds_data           (tmds_ch2_data),
    .O_clk_tmds_data           (tmds_clk_data)
);

//基础3: HDMI PHY封装 (10bit TMDS -> LVDS串行输出, 4通道10:1序列化)
hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi_phy(
    .I_pixel_clk               (video_clk),
    .I_serial_clk              (hdmi_5x_clk),
    .I_rst                     (rst_all),
    .I_tmds_channel_0          (tmds_ch0_data),
    .I_tmds_channel_1          (tmds_ch1_data),
    .I_tmds_channel_2          (tmds_ch2_data),
    .I_tmds_channel_clk        (tmds_clk_data),
    .O_tmds_ch0_p              (HDMI_D0_P),
    .O_tmds_ch1_p              (HDMI_D1_P),
    .O_tmds_ch2_p              (HDMI_D2_P),
    .O_tmds_clk_p              (HDMI_CLK_P)
);

//video frame data read-write control
frame_read_write #(
    .IMG_WIDTH  (640),
    .IMG_HEIGHT (480),
    .ROW_REVERSE(1)
) frame_read_write_m0(
    .mem_clk                    (ext_mem_clk              ),
    .rst                        (~rst_n                   ),
    .Sdr_init_done              (Sdr_init_done            ),
    .Sdr_init_ref_vld           (Sdr_init_ref_vld         ),
    .Sdr_busy                   (Sdr_busy                 ),

    .App_rd_en                  (App_rd_en                ),
    .App_rd_addr                (App_rd_addr              ),
    .Sdr_rd_en                  (Sdr_rd_en                ),
    .Sdr_rd_dout                (Sdr_rd_dout              ),

    .read_clk                   (video_clk                ),
    .read_req                   (video_read_req           ),
    .read_req_ack               (video_read_req_ack       ),
    .read_finish                (                         ),
    .read_addr_0                (read_base                ), //基础2: 读显示帧(动态)
    .read_addr_1                (24'd0                    ),
    .read_addr_2                (24'd0                    ),
    .read_addr_3                (24'd0                    ),
    .read_addr_index            (2'd0                     ), //use only read_addr_0
    .read_len                   (24'd307200               ), //frame size
    .read_en                    (video_read_en            ),
    .read_data                  (video_read_data          ),

    .App_wr_en                  (App_wr_en                ),
    .App_wr_addr                (App_wr_addr              ),
    .App_wr_din                 (App_wr_din               ),
    .App_wr_dm                  (App_wr_dm                ),

    .write_clk                  (sd_card_clk              ),
    .write_req                  (sd_card_write_req        ),
    .write_req_ack              (sd_card_write_req_ack    ),
    .write_finish               (                         ),
    .write_addr_0               (write_base               ), //基础2: 写非显示帧(动态)
    .write_addr_1               (24'd0                    ),
    .write_addr_2               (24'd0                    ),
    .write_addr_3               (24'd0                    ),
    .write_addr_index           (2'd0                     ), //use only write_addr_0
    .write_len                  (24'd307200               ), //frame size
    .write_en                   (sd_card_write_en         ),
    .write_data                 (sd_card_write_data       )
);

sdram U3(
    .Clk                        (ext_mem_clk              ),
    .Clk_sft                    (ext_mem_clk_sft          ),
    .Rst                        (~rst_n                   ),

    .Sdr_init_done              (Sdr_init_done            ),
    .Sdr_init_ref_vld           (Sdr_init_ref_vld         ),
    .Sdr_busy                   (Sdr_busy                 ),

    .App_wr_en                  (App_wr_en                ),
    .App_wr_addr                (App_wr_addr              ),
    .App_wr_dm                  (App_wr_dm                ),
    .App_wr_din                 (App_wr_din               ),

    .App_rd_en                  (App_rd_en                ),//data_req
    .App_rd_addr                (App_rd_addr              ),
    .Sdr_rd_en                  (Sdr_rd_en                ),//data_valid
    .Sdr_rd_dout                (Sdr_rd_dout              )
);

// ================= 基础3: HDMI内嵌音频 (官方lab_ex5_i2s方案) =================
// 音频链路: 12.288MHz -> I2S测试音发生器(64fs, 音阶循环) -> I2S接收器转24bit并行
//           -> ACR时钟再生计算 -> HDMI1.4b核心打包进TMDS流 -> PHY输出 -> 显示器出声
// 音画同步: 音频时钟(12.288MHz)与视频像素时钟(25MHz)同源(都由50MHz晶振PLL产生),
//           ACR机制让接收端恢复音频时钟, 保证音画同步。

// I2S测试音发生器 (64fs, 内部音阶循环 do/re/mi/fa/so/la/si/do, 每音0.5s)
hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC                 (32'd39370534),
    .AMP                       (24'sd2000000)
) u_audio_tone(
    .I_mclk                    (audio_mclk),
    .I_rst                     (rst_all),
    .O_i2s_BCLK                (audio_i2s_bclk),
    .O_i2s_LRCK                (audio_i2s_lrck),
    .O_i2s_DOUT                (audio_i2s_dout)
);

// I2S接收器: 串行I2S -> 24bit并行左右声道 (video_clk域, 跨时钟域同步)
I2S_receiver u_i2s_rx(
    .I_clk                     (video_clk),
    .I_rst                     (rst_all),
    .I_i2s_BCLK                (audio_i2s_bclk),
    .I_i2s_LRCK                (audio_i2s_lrck),
    .I_i2s_DOUT                (audio_i2s_dout),
    .O_audio_valid             (audio_valid),
    .O_audio_left_data         (audio_left_data),
    .O_audio_right_data        (audio_right_data)
);

// HDMI ACR (Audio Clock Regeneration) 计算: 让接收端从视频时钟恢复12.288MHz音频时钟
audio_arc_calculate #(.ACR_N(6144)) u_audio_arc(
    .I_clk                     (video_clk),
    .I_rst                     (rst_all),
    .I_audio_valid             (audio_valid),
    .O_acr_valid               (acr_valid),
    .O_acr_cts                 (acr_cts),
    .O_acr_n                   (acr_n)
);
// ====================================================================================

endmodule
