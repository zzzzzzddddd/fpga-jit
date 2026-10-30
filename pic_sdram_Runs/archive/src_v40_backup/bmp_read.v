`timescale 1ns/1ps
// ============================================================
// bmp_read.v — BMP 读取控制器（FAT32 按文件名版）
// ============================================================
// 【这一版相对固定 LBA 版的改动，只有"地址从哪来"一件事】
// ============================================================
//   旧版：地址是算出来的常量
//       sd_sec_read_addr <= IMG_BASE_SEC + img_index * IMG_STRIDE;
//   新版：地址是查出来的
//       先按文件名打开(open_req) -> 再逐扇区翻译(xl_req/xl_sec_idx)
//
//   除了地址来源，**下面的状态机、头部解析、RGB 装配一行没动**。
//   这是因为原设计里地址只影响 sd_sec_read_addr 这一个寄存器，
//   整个流水线（S_FIND 解析头 / S_READ 流式出像素）完全与地址无关。
//
// ============================================================
// 【★ 必须保留"第一个扇区被读两遍"这个行为 ★】
// ============================================================
//   旧版里 S_FIND 读第 0 个扇区只为解析 54 字节头；随后 sd_sec_read_addr
//   保持不动（只有"没找到"的分支才 +8），于是 S_READ 进来时读的**还是
//   第 0 个扇区**，而 bmp_len_cnt 从 0 开始计数。
//
//   也就是说：bmp_len_cnt == 0 精确对应**文件字节 0**，
//   所以 `pixel_offset(54) <= bmp_len_cnt < file_len` 这个区间判断才成立。
//
//   如果为了"省一次读"让 S_READ 从第 1 个扇区开始，bmp_len_cnt 就整体
//   少了 512，像素起点会落到文件字节 566 —— 画面横向错位约 170 像素。
//   tools/layout_sd.py 第 201 行那句"否则 RTL 按下标读像素会错位"说的
//   就是这件事。
//
//   新版换成 FAT32 之后，翻译是带状态的（簇游标），但重复翻译 sec_idx=0
//   的开销只是"命中当前簇直接出 LBA"，一次多余翻译 + 一次多余扇区读
//   （约 170us / 张），相对整张图 300ms 完全无感。**不要动。**
//
// ============================================================
// 【页与图彻底解耦】
// ============================================================
//   旧版靠"扫到下一个 BM 头就是下一张"自主推进，页号和图绑死。
//   新版给个索引就直接查文件名打开，"我要第 3 张"就去读第 3 张，
//   两张图之间没有隐含顺序依赖。所以 sd_card_bmp 的"最新目标锁存器"
//   那套连按覆盖语义依然成立。
// ============================================================
module bmp_read (
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
    output reg[23:0]            bmp_data,

    // ---------- 到 fat32_reader（顶层例化的 u_fat32_bmp）----------
    output reg                  f_open_req,      // 单拍：打开 img_index 对应的 BMP
    output reg[3:0]             f_file_idx,      // 0..5 -> 01.BMP..06.BMP
    input                       f_open_done,     // 单拍
    input                       f_found,
    output reg                  f_xl_req,        // 单拍：翻译 f_xl_sec_idx
    output reg[31:0]            f_xl_sec_idx,    // 文件内第几个扇区（0 起）
    input                       f_xl_valid,      // 单拍：f_xl_lba 有效
    input[31:0]                 f_xl_lba,
    input                       f_xl_err
);

localparam S_IDLE      = 4'd0;
localparam S_OPEN      = 4'd1;   // 发 open_req
localparam S_OPEN_W    = 4'd2;   // 等 open_done
localparam S_XL        = 4'd3;   // 发翻译请求
localparam S_XL_W      = 4'd4;   // 等翻译结果
localparam S_FIND      = 4'd5;   // 读第 0 扇区解析 54 字节头
localparam S_READ_WAIT = 4'd6;   // 等帧缓冲允许写入
localparam S_READ      = 4'd7;   // 流式出像素
localparam S_END       = 4'd8;

// 单次扇区读的超时（100MHz 下 1 秒）。一次正常读约 170us，差三个数量级，
// 只用来兜住"卡被拔了 / 没插卡"这种彻底没响应的情况。
localparam TIMEOUT_LIMIT = 32'd100_000_000;

// ==================================================================
// 重试机制（2026-10-03 加）
// ==================================================================
// 【为什么要加】
//   原来的 S_OPEN_W 在 !f_found 时直接回 S_IDLE —— 永久放弃，保留上一帧。
//   而 sd_card_bmp 的 want_pend 在发 find_go 那一拍就清掉了，
//   所以【没有任何东西会再触发一次】。于是一次失败 = 屏幕上永久一屏噪点。
//
//   但"打开失败"未必真的意味着"卡上没这个文件"：
//   MBR / 引导扇区 / 目录项里任何一次偶发读错，都会让 found 落到 0。
//   实测（同一版位流、同一张卡、同一个文件）有时出完整图、有时只出三分之一、
//   有时整屏噪点 —— 就是这种偶发。没有重试的话，这种偶发会被放大成"永久黑屏"。
//
// 【怎么重试】
//   · 打开失败  -> S_RETRY 等 RETRY_WAIT，然后用记住的 f_file_idx 重新 open
//     （f_file_idx 只在 find 那拍写、S_IDLE 不清，所以一直有效）
//   · 卡在某个等待态太久（超过 WD_LIMIT）-> 同样强制重来一次
//     这条兜住 S_OPEN_W / S_XL_W / S_READ_WAIT / S_READ 四处没有超时的等待
//   ★ 重试是无限的：真没插卡就一直试，反正屏幕状态不会比现在更差。
//     一旦哪次读通了，frame_done 就会来，帧缓冲切过去，图就出来了。
// ==================================================================
localparam S_RETRY = 4'd9;                  // state 只有 0..8，9 是空的

// 同一个目标最多重试几次，试够就放弃回 S_IDLE。
// ★ 为什么必须放弃、不能无限重试 ★
//   bmp_read 的 ready = (state == S_IDLE)，而 sd_card_bmp 的
//   find_go = want_pend & bmp_ready —— **只有回到 S_IDLE，新的 find 才发得出来**。
//   如果永远赖在 S_RETRY 循环里，后续【每一次切页请求都会被堵在 want_pend 里进不来】，
//   等于把旧版"切页能重来一次"这条唯一的恢复路径堵死了。
//   所以：先重试 FAIL_MAX 次抓偶发错误，抓不到就放弃、把控制权交回 S_IDLE。
localparam FAIL_MAX = 4'd8;                 // 8 次 × 50ms ≈ 400ms

// 重试前等多久：100MHz 下 50ms。给卡和 fat32 足够时间把上一次的残留收干净。
localparam RETRY_WAIT = 32'd5_000_000;

// 整帧最长允许读多久：100MHz 下 5 秒。
// 一帧正常读完约 0.67 秒（12.5MHz 读 1801 个扇区 + 约 225 次 FAT 读）。
// ★ 注意 stuck_cnt 是"离开 S_IDLE/S_RETRY 之后的累计时间"，不是"单个状态待了多久"★
//   —— S_READ 每读一个扇区就回 S_XL 转一圈，状态一直在换，
//   但累计量不换。所以这个数必须按【整帧】估，不能按单个状态估。
//   取 5 秒 = 7 倍余量：即便音频那条路在抢仲裁、把图片读拖慢几倍，也不会误伤。
//   ★ 以后若把读卡时钟再调慢，这个数要跟着放大 ★
localparam WD_LIMIT   = 32'd500_000_000;

reg[3:0]         state;
reg[9:0]         rd_cnt;
reg[7:0]         header_0, header_1;
reg[31:0]        file_len;
reg[31:0]        pixel_offset;
reg[31:0]        width, height;
reg[15:0]        bit_count;
reg[31:0]        compression;
reg[31:0]        bmp_len_cnt;
reg[1:0]         bmp_len_cnt_tmp;
reg[31:0]        timeout_cnt;
reg[31:0]        retry_cnt;         // S_RETRY 里的等待计数
reg[31:0]        stuck_cnt;         // 当前状态已经待了多久（看门狗）
reg[3:0]         fail_cnt;          // 本轮已经重试了几次（到 FAIL_MAX 就放弃）

// ---- 看门狗：整帧读太久就强制重来（见文件头【重试机制】）----
//   S_IDLE（空闲）和 S_RETRY（正在等重试）不计时，其余状态都算。
//   ★ stuck_cnt 只在这一个 always 块里写 ★ —— 主状态机里也写它就成多驱动了
//   （chk_drivers.py 抓过；仿真里会变 X）。主状态机只在 case 之前"读"一下
//   force_retry，不碰 stuck_cnt。
//   ★ force_retry 自己进清零条件 ★ —— 否则 stuck_cnt 会永远停在 WD_LIMIT，
//   force_retry 一直是 1，状态机就卡死在"重开 open"那一支、case 永远进不去。
//   这样它是个干净的单拍脉冲：到点 → 清 0 → 下一拍自然落下。
always @(posedge clk or posedge rst) begin
    if (rst)
        stuck_cnt <= 32'd0;
    else if (!sd_init_done || state == S_IDLE || state == S_RETRY || force_retry)
        stuck_cnt <= 32'd0;
    else if (stuck_cnt < WD_LIMIT)
        stuck_cnt <= stuck_cnt + 32'd1;
end

wire force_retry = (stuck_cnt >= WD_LIMIT);
reg              is_32bit;          // 1=32位BMP(每像素4字节), 0=24位BMP(每像素3字节)
reg              found;
// ★★ 2026-10-03 加的粘滞标志：头部解析【成功过】★★
//   ★ 2026-10-03 补充 ★
//     现在 S_XL_W 只在 sec_idx==0 时进 S_FIND，所以"每帧重进 S_FIND"
//     这件事本身已经不存在了，hdr_ok 从"必需"变成"保险"。
//     **保留它**：它同时挡住的是"重试路径再次进 S_FIND 时用像素数据
//     覆盖头部"，而且它把"头部只解析一次"这条不变量写死在代码里，
//     以后谁再动 S_XL_W 的分支也不会悄悄退化。
//   为什么需要它：
//     S_XL_W 每个扇区都要跳回 S_FIND（因为簇地址要重新翻译），
//     而 S_FIND 里那个头部解析块会把 file_len / pixel_offset / width /
//     header_0 / header_1 用【当前扇区的头 34 字节】整块重写。
//     对第 1 个扇区之后的【像素扇区】来说，那些字节是图像数据 ——
//     于是 file_len 被垃圾覆盖，`bmp_len_cnt >= file_len` 永远不成立，
//     一帧永远读不完 -> 进不了 S_END -> frame_done 永远不来 -> 屏幕不出图。
//   为什么不能用 found：
//     found 会被 `state != S_FIND` 清掉，所以它只能表示"【此刻】在 S_FIND
//     里刚解析出一个合法头"，不能表示"头已经解析过了"。
//   所以单独立一个只增不减的 hdr_ok：置 1 之后就不再重新解析头部，
//   S_FIND 的合法性判断也改用它。
//   ★ 唯一的清零点在 S_OPEN（重开文件时本来就要重新解析头）★
reg              hdr_ok;
reg[31:0]        sec_idx;           // 当前要读的文件内扇区号

wire bmp_data_valid;
wire header_match;

assign ready = (state == S_IDLE);

// BMP 头部匹配：仅校验 BM签名 + 宽度（避免过于严格导致读不出来）
// 宽度用端口 bmp_width（顶层传 640），不用参数 —— 保留原设计的写法，
// 顺便避免"参数没用上"这种多余的可配置点。
assign header_match = (header_0 == "B") && (header_1 == "M") &&
                      (width[15:0] == bmp_width);

// 像素数据有效范围：从 pixel_offset 开始到 file_len 结束。
// bmp_len_cnt 从 0 起精确对应文件字节 0（见文件头"第一个扇区被读两遍"）。
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt < file_len);

// ---- 读计数器（只在 S_FIND 用，给头部解析做字节下标）----
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
        hdr_ok       <= 1'b0;
    end else begin
        // ★★ hdr_ok 只在本块里驱动 ★★
        //   它【不能】同时被主状态机写 —— 那就是 multiple drivers，
        //   TD 综合会直接报错。清零点因此也只能放在这里。
        //   ★ 唯一的清零点：S_OPEN（重开文件本来就要重新解析头部）★
        //   解析成功时的置 1 在下面同块内，后写覆盖先写；
        //   而 S_OPEN 与 S_FIND 互斥，所以两者不会冲突。
        if (state == S_OPEN) hdr_ok <= 1'b0;

        // ★ 只在 hdr_ok 还没置起时才解析 ★
        //   否则第 1 个扇区之后，每个像素扇区都会把 file_len / pixel_offset /
        //   width / header_0 / header_1 覆盖成图像数据（垃圾）。
        if (state == S_FIND && sd_sec_read_data_valid && !hdr_ok) begin
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
                hdr_ok   <= 1'b1;      // ★ 粘滞：头解析成功过，之后不再重复解析 ★
                is_32bit <= (bit_count == 16'd32);
            end
        end else if (state != S_FIND)
            found <= 1'b0;
    end
end

// ---- 像素字节计数器 ----
// 只在 S_READ 累加。S_READ 的第一个扇区就是文件第 0 个扇区（见文件头），
// 所以这里从 0 开始的计数精确等于"文件内字节偏移"。
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
    else if (state == S_OPEN)
        // ★ 每帧只在 S_OPEN 归零一次 ★
        //   （S_OPEN 是"每次重新读图的统一入口"，见主状态机那一段）
        bmp_len_cnt_tmp <= 2'd0;
    else if (state == S_READ) begin
        if (pixel_data_start)
            bmp_len_cnt_tmp <= 2'd1;        // 本拍已装 byte0，下一字节从 byte1 起
        else if (bmp_data_valid)
            bmp_len_cnt_tmp <= (bmp_len_cnt_tmp == (is_32bit ? 2'd3 : 2'd2)) ? 2'd0 : bmp_len_cnt_tmp + 2'd1;
    end
    // ★★ 这里【绝对不能】再有 `else bmp_len_cnt_tmp <= 2'd0;` ★★
    //   原来有一句，是本次第二个 bug（2026-10-03 上板：即使出图也会是
    //   横向彩虹条）。原因：
    //     一个扇区 512 字节 = 170 个像素 + 2 字节，所以 **真实相位每跨一个
    //     扇区应该前进 512 mod 3 = 2**，RGB 的装配相位必须跨扇区保持。
    //     FAT32 版每读一个扇区都要绕一圈 S_READ -> S_XL -> S_XL_W -> S_READ，
    //     中间那两句 state != S_READ 就把相位强行清零 —— 于是每个扇区都从
    //     byte0=B 重新开始，颜色整体旋转。旧版 S_READ 连续读、中途不换状态，
    //     所以这句 else 从来没有害处；又是 FAT32 改造才把它暴露出来。
    //   （相位权威对齐点是下面的 pixel_data_start：bmp_len_cnt == pixel_offset
    //     那一拍强制从 1 起，所以哪怕上一帧残留了值也会被重新校正。）
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
        state            <= S_IDLE;
        sd_sec_read      <= 1'b0;
        sd_sec_read_addr <= 32'd0;
        write_req        <= 1'b0;
        state_code       <= 4'd0;
        timeout_cnt      <= 32'd0;
        retry_cnt        <= 32'd0;
        sec_idx          <= 32'd0;
        f_open_req       <= 1'b0;
        f_file_idx       <= 4'd0;
        f_xl_req         <= 1'b0;
        f_xl_sec_idx     <= 32'd0;
        fail_cnt         <= 4'd0;
    end else if (!sd_init_done) begin
        state       <= S_IDLE;
        sd_sec_read <= 1'b0;
        f_open_req  <= 1'b0;
        f_xl_req    <= 1'b0;
        timeout_cnt <= 32'd0;
        retry_cnt   <= 32'd0;
        fail_cnt    <= 4'd0;
    end else if (force_retry) begin
        // ---- 看门狗强拉：某个等待态卡太久了 ----
        //   把占着的请求全放开，再用记住的 f_file_idx 重开一次 open。
        //   ★ sd_sec_read 必须拉低 ★ 否则仲裁器会以为"图片这条还在要卡"，
        //   把整条 SD 通路一直占住，连 fat32 的读都进不来。
        sd_sec_read <= 1'b0;
        f_xl_req    <= 1'b0;
        f_open_req  <= 1'b1;
        retry_cnt   <= 32'd0;
        state       <= S_OPEN;
    end else case (state)
        S_IDLE: begin
            state_code  <= 4'd1;
            timeout_cnt <= 32'd0;
            f_open_req  <= 1'b0;
            f_xl_req    <= 1'b0;
            sd_sec_read <= 1'b0;
            fail_cnt    <= 4'd0;      // 回到空闲 = 本轮重试计数清零
            if (find) begin
                // ★ 这里是"页 → 图"的唯一落地点 ★
                //   旧版在这里算 IMG_BASE_SEC + img_index*IMG_STRIDE；
                //   新版改成按文件名打开，地址后面由 fat32 翻译出来。
                f_file_idx <= {1'b0, img_index};     // 0..5 -> 01.BMP..06.BMP
                f_open_req <= 1'b1;
                state      <= S_OPEN;
            end
        end

        // ---------------- 打开文件 ----------------
        // S_OPEN 现在是"每次重新读图的统一入口"：正常 find 走这里，
        // 打开失败重试走这里，看门狗强拉也走这里。
        // 所以把上一次可能残留的请求在这里一次性全部放开。
        S_OPEN: begin
            state_code  <= 4'd9;
            f_open_req  <= 1'b0;
            timeout_cnt <= 32'd0;
            retry_cnt   <= 32'd0;
            sd_sec_read <= 1'b0;
            f_xl_req    <= 1'b0;
            write_req   <= 1'b0;
            // 每发起一次 open 就记一次尝试 —— 这是【唯一】的自增点。
            // 不管本次是被哪条路径打回来的（found=0 / xl_err / 超时 / 看门狗），
            // 都会经过 S_OPEN，所以计数天然覆盖全部失败原因。
            fail_cnt    <= fail_cnt + 4'd1;
            state       <= S_OPEN_W;
        end
        S_OPEN_W: begin
            state_code <= 4'd9;
            if (f_open_done) begin
                if (!f_found) begin
                    // ★ 打开失败不再"永久放弃" ★
                    //   原来这里是 state <= S_IDLE，而 sd_card_bmp 的 want_pend
                    //   在发 find_go 那一拍就清掉了 —— 没有任何东西会再触发一次，
                    //   一次失败就是屏幕上永久一屏噪点。
                    //   而 found=0 未必真表示"卡上没这个文件"：MBR / 引导扇区 /
                    //   目录项里任何一次偶发读错都会让它落到 0。
                    //   所以改成等一会儿、用记住的 f_file_idx（没被清过）重来一次。
                    retry_cnt <= 32'd0;
                    state     <= S_RETRY;
                end else begin
                    sec_idx <= 32'd0;
                    state   <= S_XL;
                end
            end
        end

        // ---------------- 重试等待（新增）----------------
        // 数码管 D1 会显示 7 —— 看到 7 闪一下就说明"刚才那次 open 失败了、
        // 正在重来"。这是判断"读卡偶发失败"最直接的现场证据。
        S_RETRY: begin
            state_code  <= 4'd7;
            sd_sec_read <= 1'b0;      // 等的时候放开卡，别攥着 SD 通路
            f_xl_req    <= 1'b0;
            if (fail_cnt >= FAIL_MAX) begin
                // ★ 试够了 —— 放弃，回 S_IDLE ★
                //   必须回 S_IDLE：ready = (state == S_IDLE)，
                //   而 sd_card_bmp 只在 bmp_ready 时才发 find_go。
                //   永远赖在 S_RETRY 的话，后续【每一次切页请求都会被堵在
                //   want_pend 里发不出来】，等于把旧版"切页能重来"这条唯一的
                //   恢复路径堵死 —— 那比"偶尔读失败"严重得多。
                //   回到 S_IDLE 后：卡上还欠着的请求（want_pend=1）会立刻
                //   以新的 img_index 重新兑现一次，用户按键切页也照常有效。
                state    <= S_IDLE;
                fail_cnt <= 4'd0;
            end else if (retry_cnt >= RETRY_WAIT) begin
                f_open_req <= 1'b1;   // 用记住的 f_file_idx 重开一次
                state      <= S_OPEN;
            end else
                retry_cnt  <= retry_cnt + 32'd1;
        end

        // ---------------- 翻译 sec_idx ----------------
        // 注意：S_READ 每读完一个扇区就把 sec_idx +1 回到这里，
        // 所以整条读图链路是"翻译一次、读一个扇区"交替推进。
        S_XL: begin
            state_code   <= 4'd10;
            f_xl_sec_idx <= sec_idx;
            f_xl_req     <= 1'b1;
            state        <= S_XL_W;
        end
        S_XL_W: begin
            f_xl_req <= 1'b0;
            if (f_xl_valid) begin
                if (f_xl_err)
                    // 扇区号超出簇链 —— 文件比头里写的短，异常。
                    // 也可能是簇链某一步读 FAT 时采错了一位 ⇒ 不放弃，重试。
                    state <= S_RETRY;
                else begin
                    sd_sec_read_addr <= f_xl_lba;
                    // ★★ 只有【文件第 0 个扇区】才走 S_FIND ★★
                    //   原来这里是无条件 S_FIND，结果是每个扇区都重进一次。
                    //   S_FIND 里有两件【每帧只能发生一次】的事：
                    //     (a) 解析 BMP 头（用 hdr_ok 挡住了重复解析）
                    //     (b) 发 write_req（**这一件没法用粘滞标志挡**，见下）
                    //   后果（2026-10-03 上板实测：D3 到 5 却纯黑屏）：
                    //     write_req 每扇区重发 -> frame_fifo_write 每扇区重进 S_ACK
                    //     -> 那里把 write_cnt 清零、fifo_aclr 冲掉写 FIFO、
                    //        并把 App_wr_addr_r 拽回 write_addr_0（帧首）。
                    //     而每个扇区只出 ~170 个像素，够不到 into_burst 的
                    //     BURST_SIZE=256 门槛（wr_remain 此时还是 307200，
                    //     高 11 位非零 -> enough 恒假）-> 一次突发都发不出来
                    //     -> **一个像素都没写进 SDRAM** -> 纯黑。
                    //   ★ 这正是"固定 LBA 版能出图、FAT32 版不出图"的差别来源 ★
                    //     旧版 S_READ 自己递增地址、从不重进 S_FIND，
                    //     write_req 一帧只发一次；FAT32 改造把它变成每扇区一次。
                    //   ⇒ 让 S_FIND 回到"每帧一次"是唯一正确的修法。
                    //   ★ 顺带省掉每扇区一次多余的整扇区读（读图快一倍）★
                    state <= (sec_idx == 32'd0) ? S_FIND : S_READ;
                end
            end
        end

        // ---------------- 读第 0 扇区解析头部 ----------------
        S_FIND: begin
            state_code <= 4'd2;
            if (timeout_cnt >= TIMEOUT_LIMIT) begin
                // 扇区读超时（卡没响应/瞬时被抢断）——不放弃，重试
                state       <= S_RETRY;
                sd_sec_read <= 1'b0;
                timeout_cnt <= 32'd0;
            end else if (sd_sec_read_end) begin
                state_code  <= 4'd3;
                timeout_cnt <= 32'd0;
                if (hdr_ok) begin
                    // 头合法 —— 用粘滞的 hdr_ok 判，不能用 found。
                    // ★ 为什么不能用 found ★
                    //   found 被 `state != S_FIND` 清掉了，所以每进一次 S_FIND
                    //   它都从 0 开始，必须【当场】重新解析出一个合法头才会置 1。
                    //   而第 1 个扇区之后读到的是像素数据，头必然"不合法"，
                    //   于是每次都被误判成 S_RETRY —— 一帧永远读不过 512 字节。
                    // ★ 不推进地址 ★ —— S_READ 会把同一个扇区再读一遍，
                    // 让 bmp_len_cnt 从文件字节 0 对齐（见文件头）。
                    state       <= S_READ_WAIT;
                    sd_sec_read <= 1'b0;
                    write_req   <= 1'b1;
                end else
                    // 头部不合法（不是 BM / 宽度不对）——不放弃，重试。
                    // ★ 打开文件那一刻 fat32_reader 是按名查目录项、回的是确定的簇号，
                    //   所以"头不对"几乎不可能是文件内容问题（卡在电脑上看是好的），
                    //   更可能是这次读回来的那一扇区采错了 ⇒ 重来一次才可能好。
                    //   旧版这里会往后扫最多 IMG_STRIDE 个扇区找 BMP 头；
                    //   换成按文件名打开后，文件起点是确定的，扫也没有意义。
                    state       <= S_RETRY;
            end else begin
                sd_sec_read <= 1'b1;
                timeout_cnt <= timeout_cnt + 32'd1;
            end
        end

        S_READ_WAIT: begin
            state_code <= 4'd11;
            if (write_req_ack) begin
                state     <= S_READ;
                write_req <= 1'b0;
            end
        end

        // ---------------- 流式读像素 ----------------
        S_READ: begin
            state_code <= 4'd4;
            if (sd_sec_read_end) begin
                sd_sec_read <= 1'b0;
                if (bmp_len_cnt >= file_len) begin
                    state <= S_END;
                end else begin
                    // 换个扇区：翻译下一个，再回到 S_XL_W 等结果
                    sec_idx <= sec_idx + 32'd1;
                    state   <= S_XL;
                end
            end else
                sd_sec_read <= 1'b1;
        end

        S_END: begin
            // 一张读完，回 S_IDLE 等下一次 find。
            // 下一次 find 会重新打开文件、从 sec_idx=0 重来，
            // 所以这里 sec_idx 停在哪都无所谓 —— 这正是"按名直读"的好处。
            state <= S_IDLE;
        end

        default: state <= S_IDLE;
    endcase
end

endmodule
