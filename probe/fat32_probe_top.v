`timescale 1ns/1ps
// ============================================================
// fat32_probe_top.v — fat32_reader 的最小上板验证工程
// ============================================================
// 【目的】
//   把 fat32_reader 从整个系统里摘出来单独跑，只做一件事：
//     初始化 TF 卡 -> 打开 01.BMP -> 把 found / file_size / first_cluster 显示出来。
//
//   为什么值得单独做一个工程：
//     在完整工程里，fat32_reader 出错的表现是"画面没出来"，可能的原因有
//     十几个（SPI 没初始化、图片格式不对、SDRAM 时序、HDMI 时序、帧缓冲握手…）。
//     摘出来之后，唯一可能的失败原因就是 FAT32 解析本身。
//     这一步过了，后面联调时再出问题就一定是别的环节。
//
// ============================================================
// 【为什么不用 PLL】
// ============================================================
//   本工程直接跑 50MHz 板时钟，不例化 sys_pll。原因：
//     sd_card_top 的默认参数 SPI_LOW_SPEED_DIV=248 / SPI_HIGH_SPEED_DIV=0，
//     在 50MHz 下正好给出
//         初始化 50MHz/((248+2)*2) = 100kHz   （要求 <=400kHz）
//         读卡   50MHz/((0+2)*2)   = 12.5MHz   （正好是 spec 要求的频率）
//     在完整工程里跑 100MHz 时读卡是 25MHz —— 两种都远快于 FAT32 解析所需，
//     功能等价。这样探针工程不依赖任何 IP，依赖面最小。
//
// ============================================================
// 【数码管怎么读】（位选/段选都是低有效）
// ============================================================
//   8 位自动轮换三个视图，每 1.5 秒换一个，靠"小数点在哪个位置"区分：
//
//     视图 A（小数点在第 0 位）：首位显示 F=找到了 / -=没找到，
//                                后面 7 位是 file_size 的【十进制】
//                                01.BMP 应显示  F 0921654   （=921654）
//
//     视图 B（小数点在第 1 位）：首位同上，
//                                后面 7 位是 first_cluster 的【十六进制】
//                                一般是一个较小的簇号，如   F 0000002
//
//     视图 C（小数点在第 2 位）：首位是 state_code（十六进制 0..9），
//                                后面 7 位是 每簇扇区数(2位) + 保留扇区数(5位)
//                                4KB/簇的卡一般是        C 08 00020 之类
//
//   为什么要三个视图而不是一个：8 位数码管放不下 32 位十进制 + 簇号 + 状态。
//   轮换能全看到，代价只是要等 1.5 秒。
//
// ============================================================
// 【ILA（ChipProbe）要抓的信号】
// ============================================================
//   本模块里所有调试信号都是**内部网**，没有引到引脚上 —— 因为引出来要占
//   一百多根 IO。用 TD 的 ChipProbe 按层次名抓即可，路径：
//
//     u_fat32/found
//     u_fat32/file_size[31:0]
//     u_fat32/first_cluster[31:0]
//     u_fat32/state_code[3:0]
//     u_fat32/spc[7:0]            (每簇扇区数)
//     u_fat32/reserved_sec[15:0]  (保留扇区数)
//     u_fat32/fat_size[31:0]      (每份 FAT 占多少扇区)
//     u_fat32/part_start[31:0]    (分区起始 LBA)
//     u_fat32/data_start[31:0]    (数据区起始 LBA)
//     u_fat32/root_cluster[31:0]
//     u_fat32/open_done
//     u_fat32/xl_valid
//     u_fat32/xl_lba[31:0]
//
//   建议的触发条件：u_fat32/open_done 上升沿。
//   这样一次触发就能同时看到打开流程结束时的全部结果。
// ============================================================
module fat32_probe_top (
    input  wire        clk,        // 50MHz 板时钟 R7
    input  wire        rst_n,      // 复位按键 A2（低有效）
    // TF 卡 SPI 四线
    output wire        sd_ncs,     // A12
    output wire        sd_dclk,    // A14
    output wire        sd_mosi,    // A13
    input  wire        sd_miso,    // B14（板上已有上拉）
    // 8 位数码管
    output wire [7:0]  seg_sel,
    output wire [7:0]  seg_data
);

// ==================================================================
// 上电复位：50MHz 下数 20ms
//   不去复用 src/startup_pulse.v，是因为本工程要尽量少的依赖 ——
//   这个计数逻辑只有几行，自己写反而更清楚。
// ==================================================================
reg [19:0] por_cnt;
reg        por_rst_n;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        por_cnt   <= 20'd0;
        por_rst_n <= 1'b0;
    end else if (por_cnt != 20'd1_000_000 - 20'd1) begin
        por_cnt   <= por_cnt + 20'd1;
        por_rst_n <= 1'b0;
    end else
        por_rst_n <= 1'b1;
end

// ==================================================================
// SD 卡控制器（只例化这一个，不接仲裁器 —— 探针工程只有一个请求方）
// ==================================================================
wire        sd_init_done;
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [7:0]  sd_sec_read_data;
wire        sd_sec_read_data_valid;
wire        sd_sec_read_end;

sd_card_top sd_card_top_m0(
    .clk                        (clk                     ),
    .rst                        (~por_rst_n              ),  // 本模块 rst 是高有效
    .SD_nCS                     (sd_ncs                  ),
    .SD_DCLK                    (sd_dclk                 ),
    .SD_MOSI                    (sd_mosi                 ),
    .SD_MISO                    (sd_miso                 ),
    .sd_init_done               (sd_init_done            ),
    .sd_sec_read                (sd_sec_read             ),
    .sd_sec_read_addr           (sd_sec_read_addr        ),
    .sd_sec_read_data           (sd_sec_read_data        ),
    .sd_sec_read_data_valid     (sd_sec_read_data_valid  ),
    .sd_sec_read_end            (sd_sec_read_end         ),
    // 只读，写口全接 0
    .sd_sec_write               (1'b0                    ),
    .sd_sec_write_addr          (32'd0                   ),
    .sd_sec_write_data          (8'd0                    ),
    .sd_sec_write_data_req      (                        ),
    .sd_sec_write_end           (                        )
);

// ==================================================================
// 被测对象
// ==================================================================
wire        f_open_req;
wire [3:0]  f_file_idx;
wire        f_open_done;
wire        f_found;
wire [31:0] f_file_size;
wire        f_xl_req;
wire [31:0] f_xl_sec_idx;
wire        f_xl_valid;
wire [31:0] f_xl_lba;
wire        f_xl_err;

// 探针工程里 fat32 是唯一的请求方，没有 sd_arbiter。
// grant 的语义是"这个扇区是给你的"，唯一请求方时恒等于"卡在读"。
wire fat_grant_w = sd_sec_read;

// 诊断量（fat32_reader 的正式输出端口，不是跨层引用内部 reg）
wire [3:0]  probe_state;
wire [31:0] probe_cluster;
wire [7:0]  probe_spc;
wire [15:0] probe_reserved;

fat32_reader u_fat32(
    .clk                        (clk                     ),
    .rst                        (~por_rst_n              ),
    .sd_init_done               (sd_init_done            ),

    .open_req                   (f_open_req              ),
    .file_idx                   (f_file_idx              ),
    .open_busy                  (                        ),
    .open_done                  (f_open_done             ),
    .found                      (f_found                 ),
    .file_size                  (f_file_size             ),

    // 诊断输出
    .first_cluster              (probe_cluster           ),
    .spc                        (probe_spc               ),
    .reserved_sec               (probe_reserved          ),

    .xl_req                     (f_xl_req                ),
    .xl_sec_idx                 (f_xl_sec_idx            ),
    .xl_busy                    (                        ),
    .xl_valid                   (f_xl_valid              ),
    .xl_lba                     (f_xl_lba                ),
    .xl_err                     (f_xl_err                ),

    // 唯一请求方，直接连 sd_card_top
    .fat_req                    (sd_sec_read             ),
    .fat_addr                   (sd_sec_read_addr        ),
    .fat_grant                  (fat_grant_w             ),
    .fat_data                   (sd_sec_read_data        ),
    .fat_valid                  (sd_sec_read_data_valid  ),
    .fat_end                    (sd_sec_read_end         ),

    .state_code                 (probe_state             )
);

// ★ 关于 fat_grant_w ★
//   sd_arbiter 里 grant 的作用是"告诉请求方：这个扇区是给你的"，
//   用来把共用的 data_valid/end 切开。
//   探针工程没有仲裁器，fat32 是唯一请求方，所以"卡在读"就等于"授权给我"，
//   回接 sd_sec_read 是成立的。
//   ★ 如果以后在探针工程里加了第二个请求方（比如 bmp_read），
//     必须换回真正的 sd_arbiter，否则两个请求方的数据会串。★

// ==================================================================
// MBR 原始字节抓取 —— 本轮诊断的核心
// ==================================================================
//   要回答的问题：part_start 解析出来是 0xC0000 而不是 2048，到底是因为
//     (a) 计数/偏移对不上 —— 读到的根本不是 0x1BE 往后那几个字节，还是
//     (b) 卡上的 MBR 长得就跟标准 Windows 的不一样（甚至是"超软盘"，没有 MBR）。
//
//   办法：探针自己再数一遍，把 MBR 里几个关键字节的【原值】摆到数码管上。
//   计数规则和 fat32_reader 里那段完全一样（只是信号名换了一下）：
//       fat_grant -> 0 清零        这里就是 sd_sec_read
//       fat_valid -> 加一          这里就是 sd_sec_read_data_valid
//   两边都从同一个 sd_sec_read 上升沿开始数，所以序号必然一致 ——
//   于是"读到的值"和"解析用的值"是同一个数，可以直接对照。
//
//   只抓第一个扇区（MBR = LBA0）。第一个扇区读完就锁住，后面读的不再覆盖。
//
//   标准 Windows 格式化的 FAT32 卡，预期：
//     偏移 0   = MBR 引导代码首字节（常见 0x33 / 0xFA / 0xEB…）
//               ★ 注意：如果这里是 0xEB，说明 LBA0 直接就是 FAT 引导扇区 ——
//                 这张卡是"超软盘"格式，根本没有 MBR ★
//     偏移 450 = 分区项 0 的类型字节，FAT32 是 0x0B 或 0x0C
//     偏移 454 = 分区项 0 起始 LBA 的最低字节，从 2048 起分区时应为 0x00
// ==================================================================
reg [9:0]  m_cnt;
reg [7:0]  mb000, mb450, mb454;
reg        mbr_locked;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || !por_rst_n) begin
        m_cnt      <= 10'd0;
        mb000      <= 8'hFF;
        mb450      <= 8'hFF;
        mb454      <= 8'hFF;
        mbr_locked <= 1'b0;
    end else begin
        if (sd_sec_read_end) mbr_locked <= 1'b1;
        if (!mbr_locked) begin
            if (!sd_sec_read) m_cnt <= 10'd0;
            else if (sd_sec_read_data_valid) begin
                if (m_cnt == 10'd0)   mb000 <= sd_sec_read_data;
                if (m_cnt == 10'd450) mb450 <= sd_sec_read_data;
                if (m_cnt == 10'd454) mb454 <= sd_sec_read_data;
                m_cnt <= m_cnt + 10'd1;
            end
        end
    end
end

// ==================================================================
// 测试时序：等卡初始化完成 -> 打开 0 号文件（01.BMP）
//           找不到就每 500ms 重试一次，方便 ILA 反复触发
// ==================================================================
localparam T_INIT   = 3'd0;
localparam T_OPEN   = 3'd1;
localparam T_WOPEN  = 3'd2;
localparam T_RETRY  = 3'd3;
localparam T_HOLD   = 3'd4;

reg [2:0]  tst;
reg [31:0] retry_cnt;
reg        open_req_r;
reg        open_req_d;
reg        capture;        // 单拍：锁存这一轮的结果

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tst        <= T_INIT;
        retry_cnt  <= 32'd0;
        open_req_r <= 1'b0;
        capture    <= 1'b0;
    end else if (!por_rst_n) begin
        tst        <= T_INIT;
        retry_cnt  <= 32'd0;
        open_req_r <= 1'b0;
        capture    <= 1'b0;
    end else begin
        open_req_r <= 1'b0;
        capture    <= 1'b0;
        case (tst)
        T_INIT:  if (sd_init_done) begin
                     open_req_r <= 1'b1;
                     tst        <= T_WOPEN;
                 end
        T_WOPEN: if (f_open_done) begin
                     capture <= 1'b1;
                     if (f_found)
                         tst <= T_HOLD;      // 找到了就停，别再打扰
                     else begin
                         retry_cnt <= 32'd0;
                         tst       <= T_RETRY;
                     end
                 end
        T_RETRY: begin
                     // 没找到 -> 每 500ms 重试。这样 ILA 有个稳定的复现节拍，
                     // 不用每次手动复位。
                     if (retry_cnt >= 32'd25_000_000) begin
                         retry_cnt  <= 32'd0;
                         open_req_r <= 1'b1;
                         tst        <= T_WOPEN;
                     end else
                         retry_cnt <= retry_cnt + 32'd1;
                 end
        T_HOLD:  ;                    // 保持，显示结果
        default: tst <= T_INIT;
        endcase
    end
end

assign f_open_req = open_req_r;
assign f_file_idx = 4'd0;            // 0 -> 01.BMP

// ==================================================================
// 结果锁存
//   capture 那一拍把结果抄进一组"显示用"寄存器。
//   为什么要抄：T_RETRY 分支下 found 会被下一轮清掉，不抄的话数码管
//   会跟着闪。抄一份之后显示的是"最近一次打开的结果"，稳定可读。
// ==================================================================
reg        d_found;
reg [31:0] d_size;
reg [31:0] d_cluster;
reg [3:0]  d_state;
reg [7:0]  d_spc;
reg [15:0] d_reserved;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        d_found    <= 1'b0;
        d_size     <= 32'd0;
        d_cluster  <= 32'd0;
        d_state    <= 4'd0;
        d_spc      <= 8'd0;
        d_reserved <= 16'd0;
    end else if (capture) begin
        d_found    <= f_found;
        d_size     <= f_file_size;
        d_cluster  <= probe_cluster;
        d_state    <= probe_state;
        d_spc      <= probe_spc;
        d_reserved <= probe_reserved;
    end
end

// ==================================================================
// file_size 十进制转换（双 dabble）
//
//   为什么费劲转十进制而不是直接显示十六进制：
//     这一步的唯一判据是"file_size 正好等于 921654"。
//     十六进制是 000E11B6，还要在脑子里换算一次，多一个出错机会。
//     直接显示 0921654 就没有歧义。
//
//   时序：32 拍移位，50MHz 下 640ns 完成，一次性做，之后一直保持。
//   组合版（for 循环 32 次）会有 32×8 级"比较+加3"，是条很长的组合链，
//   有可能过不了时序，所以这里做成顺序的。
// ==================================================================
reg [31:0] dd_bin;
reg [31:0] dd_bcd;          // 8 个 BCD 位
reg [31:0] dd_tmp;          // 本拍的"加3修正"中间结果
reg [5:0]  dd_cnt;
reg        dd_busy;
reg [31:0] bcd_size;        // 转换结果，高 4 位是最高位数字

wire dd_start = capture && f_found;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dd_bin  <= 32'd0;
        dd_bcd  <= 32'd0;
        dd_tmp  <= 32'd0;
        dd_cnt  <= 6'd0;
        dd_busy <= 1'b0;
        bcd_size<= 32'd0;
    end else if (dd_start) begin
        dd_bin  <= f_file_size;
        dd_bcd  <= 32'd0;
        dd_cnt  <= 6'd0;
        dd_busy <= 1'b1;
    end else if (dd_busy) begin
        // 1) 每个 BCD 位 >= 5 就加 3
        //    用阻塞赋值写进 dd_tmp，这样下一步移位用的是修正后的值
        dd_tmp = dd_bcd;
        if (dd_tmp[ 3: 0] >= 4'd5) dd_tmp[ 3: 0] = dd_tmp[ 3: 0] + 4'd3;
        if (dd_tmp[ 7: 4] >= 4'd5) dd_tmp[ 7: 4] = dd_tmp[ 7: 4] + 4'd3;
        if (dd_tmp[11: 8] >= 4'd5) dd_tmp[11: 8] = dd_tmp[11: 8] + 4'd3;
        if (dd_tmp[15:12] >= 4'd5) dd_tmp[15:12] = dd_tmp[15:12] + 4'd3;
        if (dd_tmp[19:16] >= 4'd5) dd_tmp[19:16] = dd_tmp[19:16] + 4'd3;
        if (dd_tmp[23:20] >= 4'd5) dd_tmp[23:20] = dd_tmp[23:20] + 4'd3;
        if (dd_tmp[27:24] >= 4'd5) dd_tmp[27:24] = dd_tmp[27:24] + 4'd3;
        if (dd_tmp[31:28] >= 4'd5) dd_tmp[31:28] = dd_tmp[31:28] + 4'd3;
        // 2) 整体左移一位，最低位补 bin 的最高位
        dd_bcd <= {dd_tmp[30:0], dd_bin[31]};
        dd_bin <= {dd_bin[30:0], 1'b0};
        dd_cnt <= dd_cnt + 6'd1;
        if (dd_cnt == 6'd31) begin
            dd_busy  <= 1'b0;
            bcd_size <= {dd_tmp[30:0], dd_bin[31]};
        end
    end
end

// ==================================================================
// 上电启动标记（6 秒）
//
//   复位释放后 d7 先显示 6 秒的 "9"，再开始打开文件。
//   看到 9 = 位流是新的、程序在跑；看不到 = 下载/时钟问题，别去查 SD。
//   （这条是从 spi_probe 那边搬过来的：上板现象"和以前一样"时，
//     第一个要排掉的是"跑的还是旧位流"，而不是去改逻辑。）
// ==================================================================
localparam [28:0] BOOT_MAX = 29'd300_000_000 - 29'd1;   // 6s @50MHz

reg [28:0] boot_cnt;
reg        boot_done;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        boot_cnt  <= 29'd0;
        boot_done <= 1'b0;
    end else if (!boot_done) begin
        if (boot_cnt >= BOOT_MAX)
            boot_done <= 1'b1;
        else
            boot_cnt <= boot_cnt + 29'd1;
    end
end

// ==================================================================
// 数码管显示 —— 固定显示，不轮换
//
//   从左到右（d7 是物理上的一端）：
//     d7     : 9 = 启动标记（前 6 秒）
//              F = 找到了文件
//              E = 没找到 / 打开失败
//     d6..d0 : 找到时 = file_size 的【十进制】7 位
//              没找到 = d6..d1 全灭，d0 显示 state_code
//
//   01.BMP 正常应该显示：  F 0 9 2 1 6 5 4
//                          ↑ file_size = 921654
//
//   ★ 为什么不再用三视图轮换 ★
//     轮换要等 1.5 秒，还要靠"小数点在几位"记住当前是哪个视图，
//     读数容易记错，而且没法一眼判断"到底对上没有"。
//     固定显示把最关键的 file_size 一直摆在眼前，
//     判断就一句话：是不是 F0921654。
// ==================================================================

// 7 段译码（低有效：1=灭）。复用 src/seg_decoder.v 的字形，
// 但写成函数省掉 8 个例化。
function [6:0] seg7;
    input [3:0] d;
    begin
        case (d)
            4'h0: seg7 = 7'b100_0000;
            4'h1: seg7 = 7'b111_1001;
            4'h2: seg7 = 7'b010_0100;
            4'h3: seg7 = 7'b011_0000;
            4'h4: seg7 = 7'b001_1001;
            4'h5: seg7 = 7'b001_0010;
            4'h6: seg7 = 7'b000_0010;
            4'h7: seg7 = 7'b111_1000;
            4'h8: seg7 = 7'b000_0000;
            4'h9: seg7 = 7'b001_0000;
            4'ha: seg7 = 7'b000_1000;
            4'hb: seg7 = 7'b000_0011;
            4'hc: seg7 = 7'b100_0110;
            4'hd: seg7 = 7'b010_0001;
            4'he: seg7 = 7'b000_0110;
            // ★ 4'hF 必须显示成 'F'，不能落到 default（全灭）★
            //   R1 = 0xFF 是"卡完全没响应"的特征值，是最需要看见的那个数。
            //   早期版本没有这个分支，0xFF 显示成空白 ——
            //   于是"没响应"和"程序根本没跑"长得一模一样，白绕了好几轮。
            //   这条教训在 spi_probe 上已经付过一次代价，这里保持一致。
            4'hf: seg7 = 7'b000_1110;       // 'F'
            default: seg7 = 7'b111_1111;
        endcase
    end
endfunction

// 送去扫描的 8 个数字（每位 8 位：{DP, 7 段}，都是低有效）
reg [7:0] s0, s1, s2, s3, s4, s5, s6, s7;

// 固定显示的 8 个数字（只有 d7 和 d0..d6 用得到）
//
//   d7 = 启动标记 9 / 找到 F / 没找到 E
//   d6..d0 = file_size 十进制（低 7 位数字，够放下 921654 的 6 位）
//   ★ 注意 d0 是十进制的最低位 ★
//     早期版本把 found 标记放在 d0、BCD 数字放在 d1..d6，
//     结果 921654 显示成 "F9216549"，末尾那个 9 是标记不是数字，
//     很容易读成"末位多了个 9"。现在 d0..d6 就是纯数字，不再插标记。
// ★ 用【实时】state_code，不用锁存的 d_state ★
//   原因：d_state 只在 capture（= open_done 那一拍）更新。如果打开流程从来没结束，
//   d_state 就一直是复位值 0 —— 于是下面两件事在屏幕上长得一模一样：
//       (a) 卡没初始化成（sd_init_done = 0，fat32_reader 把 state_code 硬摁在 0）
//       (b) 初始化好了，但读扇区卡住（open_done 永不拉高，d_state 停在复位值）
//   改成实时值之后 (b) 会显示 2/3/4… ，一眼就能和 (a) 分开。
wire [3:0] x_d0 = f_found ? bcd_size[ 3: 0] : probe_state;
wire [3:0] x_d1 = bcd_size[ 7: 4];
wire [3:0] x_d2 = bcd_size[11: 8];
wire [3:0] x_d3 = bcd_size[15:12];
wire [3:0] x_d4 = bcd_size[19:16];
wire [3:0] x_d5 = bcd_size[23:20];
wire [3:0] x_d6 = bcd_size[27:24];
wire [3:0] x_d7 = boot_done ? (f_found ? 4'hf : 4'he) : 4'h9;

always @(*) begin
    // d0 一直显示（找到时是十进制最低位，没找到时是 state_code）
    s0 = {1'b1, seg7(x_d0)};
    s7 = {1'b1, seg7(x_d7)};
    // d1..d6 只在找到时才亮；没找到时全灭，避免"0"和"灭"混起来看错
    // s1（物理左起第 2 位）：找到时是十进制第 2 位；
    //   没找到时专门用来显示 sd_init_done： 1 = 初始化完成   0 = 没完成
    s1 = f_found ? {1'b1, seg7(x_d1)}
                 : {1'b1, seg7(sd_init_done ? 4'd1 : 4'd0)};
    // 没找到时，中间 5 位显示 MBR 里几个关键字节的【原值】（十六进制）：
    //   位3,4 = 偏移 450 —— 分区项 0 的类型字节，FAT32 应为 0B / 0C  ★最关键★
    //   位5,6 = 偏移 454 —— 分区项 0 起始 LBA 最低字节，应为 00
    //   位7   = 偏移 0 的高半字节 —— 0xEB 说明 LBA0 是 FAT 引导扇区（超软盘，没有 MBR）
    //
    // 标准 Windows FAT32 卡 + 计数正确，应读作： 3 1 0C 00 3 E   （330C003E 的镜像）
    //
    // ★ 上一版这里显示的是 sd_sec_read_addr[19:0]（= part_start），读到了 0xC0000。
    //   那个值只说明"解析结果是错的"，不说明错在哪 —— 现在直接看原始字节，
    //   就能把"计数错位"和"卡上 MBR 本来就不是标准布局"这两件事分开。
    s2 = f_found ? {1'b1, seg7(x_d2)}  : {1'b1, seg7(mb450[7:4])};
    s3 = f_found ? {1'b1, seg7(x_d3)}  : {1'b1, seg7(mb450[3:0])};
    s4 = f_found ? {1'b1, seg7(x_d4)}  : {1'b1, seg7(mb454[7:4])};
    s5 = f_found ? {1'b1, seg7(x_d5)}  : {1'b1, seg7(mb454[3:0])};
    s6 = f_found ? {1'b1, seg7(x_d6)}  : {1'b1, seg7(mb000[7:4])};
end

seg_scan u_seg_scan(
    .clk        (clk      ),
    .rst_n      (por_rst_n),
    .seg_sel    (seg_sel  ),
    .seg_data   (seg_data ),
    .seg_data_0 (s0),
    .seg_data_1 (s1),
    .seg_data_2 (s2),
    .seg_data_3 (s3),
    .seg_data_4 (s4),
    .seg_data_5 (s5),
    .seg_data_6 (s6),
    .seg_data_7 (s7)
);

endmodule
