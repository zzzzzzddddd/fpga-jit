`timescale 1ns/1ps
// ============================================================
// fat32_reader.v — FAT32 只读：按文件名打开 + 文件内扇区号 -> 绝对 LBA
// ============================================================
// 【这一版和 pic_sdram 原链路的根本区别】
// ============================================================
//   原链路（bmp_read.v / audio_sd_reader.v）用的是**固定 LBA 裸读**：
//   图 k 恒定在扇区 IMG_BASE_SEC + k*IMG_STRIDE，地址是算出来的常量。
//   代价是卡上文件的位置必须由 PC 端工具（tools/layout_sd.py）摆好，
//   换一张图就要重跑一次工具、重写整张卡。
//
//   本模块把"地址"变成**查出来的**：读 MBR 找分区 -> 读引导扇区拿 BPB ->
//   遍历根目录按短文件名匹配 -> 拿到起始簇和文件长度 -> 读数据时跟随
//   FAT 链算出每一簇的绝对 LBA。
//
//   于是卡就是一张普通的 Windows FAT32 卡，文件用资源管理器拖进去即可。
//
// ============================================================
// 【为什么要两个实例，而不是一个共享的】
// ============================================================
//   图片流和音频流读的是**两个不同的文件**，各自有一条独立的簇链游标
//   (cur_cluster / cur_ord)。共用一个实例的话，两条流交替请求翻译时，
//   每次都发现"当前簇游标不是我要的那个文件"，于是每次都要从头重走簇链 ——
//   音频每读一个扇区就要重走几百次 FAT 表，SD 带宽会被这种重走吃光。
//
//   所以顶2 例化两份（u_fat32_bmp / u_fat32_wav），各自持有自己的游标，
//   代价只是约 600 个 LUT。
//
// ============================================================
// 【无死锁的时序依据】
// ============================================================
//   本模块自己也要读扇区（读 FAT 表），所以它和数据客户端（bmp_read /
//   wav_loader）一样，是 sd_arbiter 的一个请求方。
//
//   死锁的可能情形是：bmp_read 占着仲裁器不放，同时等 fat32 给出的 LBA，
//   而 fat32 要仲裁器才能算 LBA。实际上不会发生，因为调用方的时序是
//
//       xl_req --> 等 xl_valid --> 拿到 LBA --> 才 assert 仲裁器请求
//
//   等待翻译期间调用方**根本没有占用仲裁器**，FAT 读随时拿得到。
//   这条约束写进了 bmp_read.v / wav_loader.v 的状态机里，改动那两个模块时
//   不要破坏它。
//
// ============================================================
// 【磁盘结构里几个容易踩的点】
// ============================================================
//   1. 目录项是 32 字节，但文件名域只有前 11 字节（8+3）。区分：
//        首字节 0x00 -> 目录到此结束，后面全是 0，可以停
//        首字节 0xE5 -> 已删除，跳过
//        属性   0x0F -> 长文件名(LFN)项，跳过
//        属性   0x08 -> 卷标，跳过
//        属性   0x10 -> 子目录，跳过（我们只要文件）
//   2. 起始簇号是**两个 16 位字段**：高 16 位在 0x14，低 16 位在 0x1A。
//      FAT32 只用低 28 位，高 4 位必须屏蔽掉。
//   3. FAT 项也是 32 位，**低 28 位**才是簇号。>= 0x0FFFFFF8 表示链结束。
//   4. 每扇区字节数固定按 512 处理。FAT32 在 512 字节物理扇区的卡上
//      这个值必然是 512，读 BPB 0x0B 只是为了核对。
//   5. 簇大小只可能是 2 的幂（1,2,4,...,128 扇区/簇），所以
//      "扇区号/簇大小"可以写成移位，不需要除法器。
//      Windows 对 4~8GB 的卡默认 4KB/簇 = 8 扇区。
// ============================================================
module fat32_reader (
    input  wire        clk,           // sd_card_clk 100MHz
    input  wire        rst,           // 高有效异步复位（沿用本工程约定）
    input  wire        sd_init_done,  // 来自 sd_card_top

    // ---------------- 打开文件 ----------------
    input  wire        open_req,      // 单拍：请求打开 file_idx 指定的文件
    input  wire [3:0]  file_idx,      // 0..5 = 01.BMP..06.BMP, 6..11 = 01.WAV..06.WAV
    // ★ open_busy / xl_busy 必须是 wire 而不是 reg ★
    //   它们是用 assign 连续赋值算出来的（下面 assign open_busy = ...）。
    //   Verilog 不允许对 reg 做连续赋值，声明成 output reg 会直接综合报错。
    output wire        open_busy,     // 1 = 打开流程进行中
    output reg         open_done,     // 单拍：打开流程结束（不管成功失败）
    output reg         found,         // 1 = 找到且是普通文件
    output reg  [31:0] file_size,     // 字节数（来自目录项 0x1C）

    // ---------------- 诊断输出 ----------------
    //   主工程里全部留空不接；探针工程（probe/fat32_probe_top.v）拿去显示和 ILA。
    //   做成正式端口而不是在探针里写 u_fat32.xxx 的层次化引用 ——
    //   层次化引用内部 reg 依赖综合器实现，TD 不保证支持，属于坏习惯。
    output reg  [31:0] first_cluster, // 文件起始簇
    output reg  [7:0]  spc,           // 每簇扇区数
    output reg  [15:0] reserved_sec,  // 保留扇区数

    // ---------------- 扇区翻译 ----------------
    //   调用方说"我要这个文件的第 xl_sec_idx 个扇区（0 起）"，
    //   本模块回一个 xl_valid 单拍脉冲 + xl_lba。
    //   xl_lba 会保持到下一次 xl_req，调用方在脉冲那拍锁存即可。
    input  wire        xl_req,        // 单拍
    input  wire [31:0] xl_sec_idx,
    output wire        xl_busy,       // 1 = 翻译进行中（assign 出来的，所以是 wire）
    output reg         xl_valid,      // 单拍：xl_lba 有效
    output reg  [31:0] xl_lba,
    output reg         xl_err,        // 1 = 越界 / 簇链提前结束（翻译失败）

    // ---------------- 到 sd_arbiter 的 FAT 读口 ----------------
    output reg         fat_req,
    output reg  [31:0] fat_addr,
    input  wire        fat_grant,
    input  wire [7:0]  fat_data,
    input  wire        fat_valid,
    input  wire        fat_end,

    output reg  [3:0]  state_code     // 给数码管诊断
);

// ------------------------------------------------------------------
// 常量 / 状态编码
// ------------------------------------------------------------------
localparam S_IDLE        = 4'd0;
// --- 打开流程 ---
localparam S_MBR_REQ     = 4'd1;
localparam S_MBR_RD      = 4'd2;
localparam S_VBR_REQ     = 4'd3;
localparam S_VBR_RD      = 4'd4;
localparam S_DIR_REQ     = 4'd5;
localparam S_DIR_RD      = 4'd6;
localparam S_DCHAIN_REQ  = 4'd7;
localparam S_DCHAIN_RD   = 4'd8;
localparam S_OPEN_END    = 4'd9;
// --- 翻译流程 ---
localparam S_XL_CHK      = 4'd10;
localparam S_XL_FAT_REQ  = 4'd11;
localparam S_XL_FAT_RD   = 4'd12;
localparam S_XL_DONE     = 4'd13;

reg [3:0] state;

// 一次扇区读最多 512 字节，10 位足够
reg [9:0] bcnt;

// ------------------------------------------------------------------
// 打开请求的"欠账"标志
//
//   为什么不能直接在 S_IDLE 里采样 open_req：
//     切页是随时可能发生的，而 fat32 在翻译/读 FAT 表时并不在 S_IDLE。
//     那一拍直接采样就会漏掉这次打开请求，调用方随后死等 open_done。
//   所以改成在 always 顶层检测上升沿、置 open_pend，
//   等 FSM 回到 S_IDLE 再兑现（最新那次覆盖前面的）。
// ------------------------------------------------------------------
reg open_req_d;
reg open_pend;

// 目录解析块的"清结果"脉冲（由主状态机发单拍）
//   found / file_size / first_cluster 归目录解析块独占驱动，
//   主状态机想清它们只能发这个脉冲，不能自己去写。
reg dir_rst;

// ------------------------------------------------------------------
// 文件名的 11 字节短名表（8+3，空格补齐，大写）
//
//   0.. 5 -> "01".."06" + 6 空格 + "BMP"
//   6..11 -> "01".."06" + 6 空格 + "WAV"
//
// 用函数生成而不是写 12x11 的常量表：省 132 字节的 ROM，而且
// 改文件名规则时只改这一处。
// ------------------------------------------------------------------
function [7:0] tgt_name;
    input [3:0] fi;      // file_idx
    input [3:0] p;       // 名字内第几个字节 0..10
    reg   [3:0] n;       // 序号 1..6
    begin
        if (fi < 4'd6) n = fi + 4'd1;   // BMP 组
        else           n = fi - 4'd5;   // WAV 组
        case (p)
            4'd0 : tgt_name = "0";
            4'd1 : tgt_name = 8'h30 + {4'd0, n};
            // p = 2..7 是 8.3 里 8 字节名字域的 6 个空格填充
            4'd8 : tgt_name = (fi < 4'd6) ? "B" : "W";
            4'd9 : tgt_name = (fi < 4'd6) ? "M" : "A";
            4'd10: tgt_name = (fi < 4'd6) ? "P" : "V";
            default: tgt_name = " ";
        endcase
    end
endfunction

// ------------------------------------------------------------------
// BPB / 分区表解析结果
// ------------------------------------------------------------------
reg [31:0] part_start;      // FAT32 分区起始 LBA（MBR 分区表项）
// 注：spc 已提升为输出端口（诊断用），这里不再重复声明
reg [3:0]  spc_log2;        // log2(spc)，用移位代替除法
reg [31:0] fat_start;       // 第一份 FAT 表的起始 LBA
reg [7:0]  num_fats;        // FAT 份数
reg [31:0] fat_size;        // 每份 FAT 占多少扇区
reg [31:0] data_start;      // 数据区起始 LBA
reg [31:0] root_cluster;    // 根目录起始簇（通常为 2）

// ------------------------------------------------------------------
// 打开流程的中间量
// ------------------------------------------------------------------
reg [1:0]  pt_idx;          // 正在看第几个分区表项
reg        pt_hit;          // 是否已找到 FAT32 分区
reg [31:0] dir_cluster;     // 目录遍历的当前簇
reg [7:0]  dir_sec;         // 当前簇内的第几个扇区
// ★ dir_clu_off = (dir_cluster - 2) << spc_log2 ★
//   纯粹是为了打散关键路径，值 = 上式，和直接算完全等价。
//   为什么要有它：2026-10-03 的 route 报告里，本设计的【全局最长路径】就是
//       dir_cluster -> fat_addr
//   即 S_DIR_REQ 里那一行 `data_start + ((dir_cluster-2)<<spc_log2) + dir_sec`：
//   减 2 -> 变长移位(桶形移位器) -> 加 -> 加，四段串在一拍里，
//   实测 sd_card_clk 自环 Fmax 只有 98.23MHz，**差 100MHz 一点点**（-180ps）。
//   而 dir_cluster 只在【换目录簇】时才变（整个目录扫描里没几次），
//   完全可以把"减 2 + 移位"提前到那时算好，放进寄存器。
//   于是 fat_addr 那拍只剩两次加法，关键路径从四段降到两段。
//   ★ 改完 dir_cluster 的地方必须同步改 dir_clu_off，否则地址会算错 ★
reg [31:0] dir_clu_off;
reg [5:0]  dir_eoff;        // 目录项内字节偏移 0..31
reg        dir_attr;        // 当前项的属性
reg [7:0]  dir_match;       // 名字逐字节比对，全中才留 1
reg        dir_isfile;      // 属性判定：不是 LFN/卷标/目录
reg [31:0] scan_size;       // 当前目录项的 FileSize

// ------------------------------------------------------------------
// 翻译流程的中间量
// ------------------------------------------------------------------
// 注：first_cluster 已提升为输出端口（诊断用），这里不再重复声明
reg [31:0] cur_cluster;     // 当前簇游标
reg [31:0] cur_ord;         // cur_cluster 是链上第几簇（0 起）
reg [31:0] tgt_ord;         // 本次翻译要的是第几簇
reg [31:0] tgt_off;         // 簇内扇区偏移
reg [31:0] next_cluster;    // FAT 项读出来的下一簇
reg [31:0] fat_entry;       // 组装的 32 位 FAT 项
reg [8:0]  fat_boff;        // FAT 项在 512B 扇区内的字节偏移 (0..508)

assign open_busy = (state != S_IDLE) && (state >= S_MBR_REQ) && (state <= S_OPEN_END);
assign xl_busy   = (state >= S_XL_CHK) && (state <= S_XL_DONE);

// ------------------------------------------------------------------
// 扇区内字节计数
//   fat_grant 有效期间才计数；无效时清零。
//   这样每个扇区的第一个 fat_valid 一定对应 bcnt == 0。
// ------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        bcnt <= 10'd0;
    else if (!fat_grant)
        bcnt <= 10'd0;
    else if (fat_valid)
        bcnt <= bcnt + 10'd1;
end

// ------------------------------------------------------------------
// MBR 解析：4 个分区表项，每项 16 字节，起始偏移 0x1BE
//   项内 +0   : 引导标志
//   项内 +4   : 分区类型（0x0B / 0x0C 是 FAT32）
//   项内 +8..11: 起始 LBA（小端）
//
// pt_hit 在整张 MBR 读完（fat_end）时若仍为 0，走"超级软盘"兜底：
// 直接认为 LBA 0 就是引导扇区（有些小卡没有 MBR）。
// ------------------------------------------------------------------
reg        this_ok;         // 当前这一项是不是 FAT32（每项开头清零）
// ------------------------------------------------------------------
 always @(posedge clk or posedge rst) begin
    if (rst) begin
        pt_idx     <= 2'd0;
        pt_hit     <= 1'b0;
        this_ok    <= 1'b0;
        part_start <= 32'd0;
    end else if (state == S_MBR_REQ) begin
        pt_idx <= 2'd0;
        pt_hit <= 1'b0;
        this_ok <= 1'b0;
        // 顺便清 part_start：整张 MBR 扫完都没命中 FAT32 时它就保持 0，
        // 主状态机据此走"超级软盘"兜底（把 LBA 0 当引导扇区）。
        // ★ 这一句必须在【本块】里，不能在主状态机里 ★ ——
        //   part_start 归本块独占驱动，两处都写就是 multiple drivers。
        part_start <= 32'd0;
    end else if ((state == S_MBR_RD) && fat_valid) begin
        // 分区表项的起点：0x1BE + pt_idx*16
        // 类型字节在项内 +4，起始 LBA 在项内 +8..11
        //
        // ★ part_start 必须【逐项】判断类型，不能无条件写 ★
        //   原先四句 part_start 的赋值没有 this_ok 把关，四个分区项会依次
        //   覆盖，于是上面注释写明的意图完全没有生效：
        //     · 标准 Windows 卡：第 0 项是 FAT32(LBA=2048)，但第 1/2/3 项
        //       全 0 —— part_start 最终被写成 0，永远走"超级软盘"兜底。
        //     · 超软盘格式的卡（没有 MBR，0x1BE 往后全是引导代码）：
        //       把引导代码当成 LBA，解析出一个离谱的地址；读那个地址时
        //       卡会回错误 R1，而 sd_card_cmd 的 S_CMD17 出错只会重发，
        //       于是 sd_sec_read_end 永不拉高，主状态机永远停在 S_VBR_RD。
        //   pt_hit 是"整张 MBR 里出现过 FAT32 项"的粘滞标志，一旦置起就
        //   不再清，拿它逐项把关是错的，所以另用一个每项开头清零的 this_ok。
        if (bcnt == (10'd446 + {4'd0, pt_idx} * 10'd16))
            this_ok <= 1'b0;                      // 新的一项开始，先清
        if (bcnt == (10'd446 + {4'd0, pt_idx} * 10'd16 + 10'd4)) begin
            this_ok <= (fat_data == 8'h0B) || (fat_data == 8'h0C);
            if ((fat_data == 8'h0B) || (fat_data == 8'h0C))
                pt_hit <= 1'b1;
        end
        if (this_ok) begin
            if (bcnt == (10'd446 + {4'd0, pt_idx} * 10'd16 + 10'd8))  part_start[7:0]   <= fat_data;
            if (bcnt == (10'd446 + {4'd0, pt_idx} * 10'd16 + 10'd9))  part_start[15:8]  <= fat_data;
            if (bcnt == (10'd446 + {4'd0, pt_idx} * 10'd16 + 10'd10)) part_start[23:16] <= fat_data;
            if (bcnt == (10'd446 + {4'd0, pt_idx} * 10'd16 + 10'd11)) part_start[31:24] <= fat_data;
        end
        // 每读完一项就推进 pt_idx（项的最后一个字节是 +15）
        if (bcnt == (10'd446 + {4'd0, pt_idx} * 10'd16 + 10'd15))
            pt_idx <= pt_idx + 2'd1;
    end
end

// ------------------------------------------------------------------
// 引导扇区(BPB)解析
//   0x0B..0x0C 每扇区字节数
//   0x0D       每簇扇区数
//   0x0E..0x0F 保留扇区数
//   0x10       FAT 份数
//   0x24..0x27 每份 FAT 扇区数
//   0x2C..0x2F 根目录起始簇
// ------------------------------------------------------------------
// ★ 本块只驱动 spc / num_fats / fat_size / root_cluster 四个 ★
//   fat_start / data_start 归主状态机（它们要等 reserved_sec 和 num_fats
//   都收齐才能算），spc_log2 有自己独立的一块。
//
//   早先的版本把 fat_start / data_start / spc_log2 也写在这里的复位里，
//   结果和主状态机、独立块三处互相驱动同一批 reg —— 综合会直接报
//   multiple drivers。这类错误 tools/vcheck.py 的纯语法检查看不出来，
//   是 tools/chk_drivers.py 查出来的。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        spc          <= 8'd1;
        num_fats     <= 8'd2;
        fat_size     <= 32'd0;
        root_cluster <= 32'd2;
    end else if ((state == S_VBR_REQ) && fat_grant) begin
        // 进 S_VBR_RD 之前先把组合量清干净，避免上一张卡的残留
        fat_size <= 32'd0;
    end else if ((state == S_VBR_RD) && fat_valid) begin
        case (bcnt)
            10'd13: spc  <= fat_data;                    // 每簇扇区数
            10'd16: num_fats  <= fat_data;
            10'd36: fat_size[7:0]   <= fat_data;
            10'd37: fat_size[15:8]  <= fat_data;
            10'd38: fat_size[23:16] <= fat_data;
            10'd39: fat_size[31:24] <= fat_data;
            10'd44: root_cluster[7:0]   <= fat_data;
            10'd45: root_cluster[15:8]  <= fat_data;
            10'd46: root_cluster[23:16] <= fat_data;
            10'd47: root_cluster[31:24] <= fat_data;
            default: ;
        endcase
    end
end

// 保留扇区数用一个小寄存器单独接，避免和 fat_start 复用同一个位域。
// 注：reserved_sec 已提升为输出端口（诊断用），这里不再重复声明。

always @(posedge clk or posedge rst) begin
    if (rst)
        reserved_sec <= 16'd0;
    else if ((state == S_VBR_REQ) && fat_grant)
        reserved_sec <= 16'd0;
    else if ((state == S_VBR_RD) && fat_valid) begin
        if (bcnt == 10'd14) reserved_sec[7:0]  <= fat_data;
        if (bcnt == 10'd15) reserved_sec[15:8] <= fat_data;
    end
end

// spc_log2：spc 必然是 2 的幂，用优先编码取 log2
always @(posedge clk) begin
    case (spc)
        8'd1  : spc_log2 <= 4'd0;
        8'd2  : spc_log2 <= 4'd1;
        8'd4  : spc_log2 <= 4'd2;
        8'd8  : spc_log2 <= 4'd3;
        8'd16 : spc_log2 <= 4'd4;
        8'd32 : spc_log2 <= 4'd5;
        8'd64 : spc_log2 <= 4'd6;
        default: spc_log2 <= 4'd7;   // 128
    endcase
end

// ------------------------------------------------------------------
// 根目录遍历：逐扇区、逐 32 字节项比对短文件名
//
// 名字比对是"逐字节放行"的：进每一项前 dir_match 置 1，
// 每收到名字域一个字节就与期望值相与。到属性字节(+11)时定案。
// ------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dir_eoff  <= 6'd0;
        dir_attr  <= 1'b0;
        dir_match <= 8'd0;
        dir_isfile<= 1'b0;
        scan_size <= 32'd0;
        found     <= 1'b0;
        file_size <= 32'd0;
        first_cluster <= 32'd0;
    end else if (dir_rst) begin
        // 主状态机要开一个新文件了，把上一次的查找结果清掉。
        // 这三个信号归本块独占驱动，主状态机只能靠这个脉冲来清。
        found         <= 1'b0;
        file_size     <= 32'd0;
        first_cluster <= 32'd0;
    end else if (state == S_DIR_REQ) begin
        // 每进一个新扇区，把项内偏移归零
        dir_eoff   <= 6'd0;
        dir_match  <= 8'd1;
        dir_isfile <= 1'b0;
    end else if ((state == S_DIR_RD) && fat_valid) begin
        // 项内一字节收完就推进；到 31 后回到 0（下一项）
        dir_eoff <= (dir_eoff == 6'd31) ? 6'd0 : (dir_eoff + 6'd1);
        if (dir_eoff == 6'd0) dir_match <= 8'd1;   // 新的一项，重新开始比对

        // ---- 名字域 0..10 ----
        if (dir_eoff <= 6'd10) begin
            if (fat_data != tgt_name(file_idx_reg, {2'd0, dir_eoff[3:0]}))
                dir_match <= 8'd0;
        end

        // ---- 属性 ----
        if (dir_eoff == 6'd11) begin
            dir_attr   <= (fat_data == 8'h0F) || (fat_data == 8'h08) || (fat_data == 8'h10);
            dir_isfile <= !((fat_data == 8'h0F) || (fat_data == 8'h08) || (fat_data == 8'h10));
        end

        // ---- 起始簇 高16位(0x14-0x15) 低16位(0x1A-0x1B) ----
        // ★★ 2026-10-04 修复：这四个赋值必须带 `&& !found` ★★
        //   症状：六页工况页的底图永远不变（卡上 06.BMP 是橙色，屏幕就一直橙），
        //         但图号(D2)对、file_size 对、D3=5(读完)、D4=C(读写都健康)。
        //   真因：原来这四行【不带任何命中判断】，目录里【每一项】都会把
        //     first_cluster 覆盖一遍；而扫描命中之后并不会立刻停 ——
        //     S_DIR_RD 要读到本扇区末尾（真正提前退出只发生在遇到 0x00
        //     "目录结束"标记时）。根目录是 01..06.BMP 后面紧跟 0x00，
        //     ⇒ 最后一个被写进去的永远是【06.BMP 的起始簇】，跟请求哪个文件无关。
        //     ⇒ cur_cluster 恒等于 06.BMP 的起始簇 ⇒ 每次读回来的都是 06.BMP
        //       的像素 ⇒ 屏幕永远是同一张图。
        //   ★ 为什么 file_size 没这个毛病：它在字节 31「命中那一拍」单独锁存
        //     （见下面 file_size 那行），而 first_cluster 是"边扫边写、
        //     最后才读"，所以只有它被后来的项冲掉。★
        //   加 !found 之后：命中那一项的四个字节照写（found 要到字节 31 才置起，
        //     此刻还是 0），命中之后不再被任何后续项覆盖。
        //   ★ 判据：该值随翻页而变 = 修好了；恒定 = 还有别的问题 ★
        if (dir_eoff == 6'd20 && !found) first_cluster[23:16] <= fat_data;
        if (dir_eoff == 6'd21 && !found) first_cluster[31:24] <= {4'd0, fat_data[3:0]}; // 高4位保留
        if (dir_eoff == 6'd26 && !found) first_cluster[7:0]   <= fat_data;
        if (dir_eoff == 6'd27 && !found) first_cluster[15:8]  <= fat_data;

        // ---- 文件长度 ----
        if (dir_eoff == 6'd28) scan_size[7:0]   <= fat_data;
        if (dir_eoff == 6'd29) scan_size[15:8]  <= fat_data;
        if (dir_eoff == 6'd30) scan_size[23:16] <= fat_data;
        if (dir_eoff == 6'd31) begin
            scan_size[31:24] <= fat_data;
            // 一项收完，这里定案。注意用的是本拍之前的 dir_match / dir_attr，
            // 也就是名字域和属性都已经填好之后的值 —— 正好。
            if (dir_match && dir_isfile && !found) begin
                found     <= 1'b1;
                file_size <= {fat_data, scan_size[23:0]};
            end
        end
    end
end

// file_idx 在打开流程中必须保持不变（调用方保证），这里打一拍给名字比对用
reg [3:0] file_idx_reg;
always @(posedge clk or posedge rst) begin
    if (rst)
        file_idx_reg <= 4'd0;
    else if (open_req)
        file_idx_reg <= file_idx;
end

// ------------------------------------------------------------------
// FAT 项组装：读 FAT 扇区时，只挑出目标偏移的那 4 个字节
//   项在扇区内的字节偏移 = (cur_cluster % 128) * 4
//   512 字节扇区 / 4 字节每项 = 128 项，所以取低 7 位再左移 2
// ------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        fat_boff <= 9'd0;
    else
        fat_boff <= {2'd0, cur_cluster[6:0]} << 2;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        fat_entry <= 32'd0;
    else if ((state == S_XL_FAT_RD) && fat_valid) begin
        if (bcnt == {1'b0, fat_boff})            fat_entry[7:0]   <= fat_data;
        if (bcnt == {1'b0, fat_boff} + 10'd1)    fat_entry[15:8]  <= fat_data;
        if (bcnt == {1'b0, fat_boff} + 10'd2)    fat_entry[23:16] <= fat_data;
        if (bcnt == {1'b0, fat_boff} + 10'd3)    fat_entry[31:24] <= fat_data;
    end
end

// ------------------------------------------------------------------
// 组合量
// ------------------------------------------------------------------
// 簇 -> 绝对 LBA：data_start + (cluster - 2) * spc + 簇内偏移
wire [31:0] clu_lba = data_start + ((cur_cluster - 32'd2) << spc_log2) + tgt_off;
// FAT 项所在扇区
wire [31:0] fat_sec = fat_start + (cur_cluster >> 7);   // /128
// 簇链结束判定
//   ★ 必须用【刚读回来的】fat_entry 判，不能用寄存过的 next_cluster ★
//     next_cluster 是 fat_entry 的寄存副本，在 fat_end 那一拍它【还没更新】——
//     拿它判等于在判【上一次】读到的那一项。后果是真正走到链尾那一项时
//     判不出来，反手把 0x0FFFFFFF 当合法簇号存进 cur_cluster：
//       · cur_ord 照样加一，S_XL_CHK 可能正好 tgt_ord == cur_ord
//       · 于是 xl_lba = data_start + (0x0FFFFFFF-2)<<spc_log2 —— 天文数字
//       · 而 xl_err 仍是 0，调用方完全不知道翻译失败了（假的安全网）
//     请求超出文件末尾时就会这样。直接看 fat_entry 之后 xl_err 才真的会报。
//     （fat_entry 在 fat_end 那一拍早已组装完毕：它取的是 bcnt == fat_boff+0..3
//       这 4 个字节，而 fat_end 是整个 512 字节扇区读完之后才来的。）
wire        chain_end = (fat_entry[27:0] >= 28'h0FFFFFF8);

// ------------------------------------------------------------------
// 主状态机
// ------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state       <= S_IDLE;
        fat_req     <= 1'b0;
        fat_addr    <= 32'd0;
        open_done   <= 1'b0;
        xl_valid    <= 1'b0;
        xl_err      <= 1'b0;
        xl_lba      <= 32'd0;
        state_code  <= 4'd0;
        dir_cluster <= 32'd0;
        dir_clu_off <= 32'd0;
        dir_sec     <= 8'd0;
        cur_cluster <= 32'd0;
        cur_ord     <= 32'd0;
        tgt_ord     <= 32'd0;
        tgt_off     <= 32'd0;
        next_cluster<= 32'd0;
        open_req_d  <= 1'b0;
        open_pend   <= 1'b0;
    end else if (!sd_init_done) begin
        // 卡重新初始化期间，一切归零，避免带着陈旧状态跑
        state      <= S_IDLE;
        fat_req    <= 1'b0;
        open_done  <= 1'b0;
        xl_valid   <= 1'b0;
        xl_err     <= 1'b0;
        state_code <= 4'd0;
        open_pend  <= 1'b0;
    end else begin
        // 默认单拍信号拉低
        open_done <= 1'b0;
        xl_valid  <= 1'b0;

        // open_req 的上升沿 -> 欠一次打开（不管当前在哪个状态）
        open_req_d <= open_req;
        if (open_req && !open_req_d) open_pend <= 1'b1;

        dir_rst <= 1'b0;             // 每拍默认不发，S_IDLE 里显式置起

        // ------------------------------------------------------------------
        // 新的打开请求到来时，立即放弃在途的翻译。
        //
        //   那次翻译属于【上一个文件】，结果已经没人要了。但如果让它继续跑完
        //   并脉冲 xl_valid，新的一轮就可能采到这个陈旧 LBA —— 把上一个文件的
        //   簇号当成当前文件的，读出来的字节全是错的，而且这种错很难从现象上
        //   判断（画面花、声音是噪声，但状态机一切正常）。
        //
        //   什么时候会发生：wav_loader 的 play 是全局覆盖，切页可以打断正在
        //   进行的翻译；bmp_read 只在 S_IDLE 才发 open，不会撞上。
        //
        //   不发 xl_valid 是安全的：调用方在 play 那一拍就已经离开等待状态。
        // ------------------------------------------------------------------
        if (open_pend && (state != S_IDLE)) begin
            state    <= S_IDLE;
            fat_req  <= 1'b0;
            xl_valid <= 1'b0;
        end else case (state)
        // ============================ 空闲 ============================
        S_IDLE: begin
            state_code <= 4'd1;
            if (open_pend) begin
                open_pend    <= 1'b0;
                // 打开新文件：把簇游标清掉。
                // ★ found / file_size / first_cluster 归目录解析块，pt_hit /
                //   part_start 归 MBR 解析块 —— 这里一概不写 ★
                //   要清它们就发一个 dir_rst 脉冲，让目录块自己清。
                dir_rst      <= 1'b1;
                dir_cluster  <= 32'd0;
                dir_clu_off  <= 32'd0;
                dir_sec      <= 8'd0;
                state        <= S_MBR_REQ;
            end else if (xl_req && (first_cluster != 32'd0)) begin
                tgt_ord <= xl_sec_idx >> spc_log2;
                tgt_off <= xl_sec_idx & {28'd0, spc} - 32'd1; // 见下方说明
                state   <= S_XL_CHK;
            end else if (xl_req) begin
                // 还没成功打开过文件就要求翻译 —— 直接报错
                xl_err   <= 1'b1;
                xl_valid <= 1'b1;
                xl_lba   <= 32'd0;
            end
        end

        // ========================= 读 MBR(LBA 0) =====================
        S_MBR_REQ: begin
            state_code <= 4'd2;
            fat_req    <= 1'b1;
            fat_addr   <= 32'd0;
            if (fat_grant) state <= S_MBR_RD;
        end
        S_MBR_RD: begin
            if (fat_end) begin
                fat_req <= 1'b0;
                // 没找到 FAT32 分区项时 part_start 保持 0（由 MBR 块负责清零），
                // 于是下面读的就是 LBA0 —— 即"超级软盘"兜底：
                // 有些小卡没有 MBR，引导扇区直接在 LBA0。
                // ★ 这里【不要】再写 part_start，它归 MBR 解析块独占驱动 ★
                state <= S_VBR_REQ;
            end
        end

        // ======================= 读引导扇区(BPB) =====================
        S_VBR_REQ: begin
            state_code <= 4'd3;
            fat_req    <= 1'b1;
            fat_addr   <= part_start;
            if (fat_grant) state <= S_VBR_RD;
        end
        S_VBR_RD: begin
            if (fat_end) begin
                fat_req    <= 1'b0;
                // 数据区起点 = 分区起点 + 保留扇区 + FAT份数*FAT大小
                data_start <= part_start + {16'd0, reserved_sec} + num_fats * fat_size;
                fat_start  <= part_start + {16'd0, reserved_sec};
                // 从根目录第一簇开始
                dir_cluster <= root_cluster;
                // 这一步就把"减 2 + 移位"算好（见 dir_clu_off 的声明处）
                dir_clu_off <= (root_cluster - 32'd2) << spc_log2;
                dir_sec     <= 8'd0;
                state       <= S_DIR_REQ;
            end
        end

        // ==================== 遍历目录（第 dir_sec 扇区）=============
        S_DIR_REQ: begin
            state_code <= 4'd4;
            fat_req    <= 1'b1;
            // ★ 等价于 data_start + ((dir_cluster-2) << spc_log2) + dir_sec ★
            //   但把"减2 + 变长移位"挪进了 dir_clu_off 这个寄存器（见其声明处），
            //   这里只剩两次加法 —— 这是本设计原来的全局最长路径。
            fat_addr   <= data_start + dir_clu_off + {24'd0, dir_sec};
            if (fat_grant) state <= S_DIR_RD;
        end
        S_DIR_RD: begin
            // 名字比对在独立的 always 块里做，这里只管推进
            if (fat_valid && (dir_eoff == 6'd0) && (bcnt != 10'd0)) begin
                // 首字节 0x00 -> 目录结束，不用再找
                if (fat_data == 8'h00) begin
                    fat_req <= 1'b0;
                    state   <= S_OPEN_END;
                end
            end
            if (fat_end) begin
                fat_req <= 1'b0;
                if (found) begin
                    // 已经命中，不必再扫
                    state <= S_OPEN_END;
                end else if (dir_sec + 8'd1 < spc) begin
                    // 本簇还有扇区
                    dir_sec <= dir_sec + 8'd1;
                    state   <= S_DIR_REQ;
                end else begin
                    // 本簇扫完，跟 FAT 链去下一簇
                    dir_sec   <= 8'd0;
                    cur_cluster <= dir_cluster;
                    state     <= S_DCHAIN_REQ;
                end
            end
        end

        // ================== 目录跨簇：读 FAT 取下一簇 =================
        S_DCHAIN_REQ: begin
            state_code <= 4'd5;
            fat_req    <= 1'b1;
            fat_addr   <= fat_start + (dir_cluster >> 7);
            if (fat_grant) state <= S_DCHAIN_RD;
        end
        S_DCHAIN_RD: begin
            if (fat_end) begin
                fat_req <= 1'b0;
                // 复用 fat_entry 的组装寄存器（此时 cur_cluster == dir_cluster）
                if ((fat_entry[27:0] >= 28'h0FFFFFF8) || (fat_entry[27:0] < 28'h2)) begin
                    // 链断了还没找到 —— 报"未找到"。
                    // ★ 这里【不要】写 found <= 0 ★ —— found 归目录解析块独占驱动，
                    //   它在开文件时已被 dir_rst 清成 0，这里保持 0 即可。
                    state <= S_OPEN_END;
                end else begin
                    dir_cluster <= fat_entry;
                    // 换簇了 —— 同步把偏移重算（见 dir_clu_off 的声明处）
                    dir_clu_off <= (fat_entry - 32'd2) << spc_log2;
                    state       <= S_DIR_REQ;
                end
            end
        end

        // ======================= 打开流程收尾 ========================
        S_OPEN_END: begin
            state_code <= 4'd6;
            open_done  <= 1'b1;
            if (found) begin
                cur_cluster <= first_cluster;
                cur_ord     <= 32'd0;
            end
            state <= S_IDLE;
        end

        // ======================= 翻译：判断要不要走簇 =================
        S_XL_CHK: begin
            state_code <= 4'd7;
            if (tgt_ord == cur_ord) begin
                // 目标就在当前簇，直接算 LBA
                state <= S_XL_DONE;
            end else if (tgt_ord == (cur_ord + 32'd1)) begin
                // 正好是下一簇，跟一次链
                cur_cluster <= cur_cluster;   // 保持，下面用它在 FAT_RD 里取项
                state       <= S_XL_FAT_REQ;
            end else if (tgt_ord > cur_ord) begin
                // 往前跳很多簇：这里不做加速，逐簇跟链。
                // 顺序读时永远不会走到这条分支（只有 +1 和 == 两种）。
                cur_cluster <= cur_cluster;
                state       <= S_XL_FAT_REQ;
            end else begin
                // 目标在当前簇之前（往回跳）：从起始簇重走
                cur_cluster <= first_cluster;
                cur_ord     <= 32'd0;
                // 回 S_XL_CHK 重新判断
            end
        end

        // ==================== 读 FAT 项取得下一簇 ====================
        S_XL_FAT_REQ: begin
            state_code <= 4'd8;
            fat_req    <= 1'b1;
            fat_addr   <= fat_sec;
            if (fat_grant) state <= S_XL_FAT_RD;
        end
        S_XL_FAT_RD: begin
            if (fat_end) begin
                fat_req      <= 1'b0;
                next_cluster <= fat_entry & 32'h0FFFFFFF;
                if (chain_end) begin
                    // 簇链提前结束 —— 请求的扇区号超出文件实际长度
                    xl_err   <= 1'b1;
                    xl_valid <= 1'b1;
                    xl_lba   <= 32'd0;
                    state    <= S_IDLE;
                end else begin
                    cur_cluster <= fat_entry & 32'h0FFFFFFF;
                    cur_ord     <= cur_ord + 32'd1;
                    state       <= S_XL_CHK;
                end
            end
        end

        // ========================= 翻译收尾 =========================
        S_XL_DONE: begin
            state_code <= 4'd9;
            xl_lba     <= clu_lba;
            xl_valid   <= 1'b1;
            xl_err     <= 1'b0;
            state      <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
