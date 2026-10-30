`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: anlgoic
// Author: 	xg 
// description:  top module
//////////////////////////////////////////////////////////////////////////////////

`define DEBUG

`include "./src/sdram/enc_file/global_def.v"

module sdram(
    `ifdef SIMULATION
	output					SDRAM_CLK,
	output					SDR_CKE,
	output					SDR_RAS,
	output					SDR_CAS,
	output					SDR_WE,
	output	[`BA_WIDTH-1:0]	SDR_BA,
	output	[`ROW_WIDTH-1:0]SDR_ADDR,
	output	[`DM_WIDTH-1:0]	SDR_DM,
	inout	[`DATA_WIDTH-1:0]	SDR_DQ,	
	`endif
    input   					Clk,
    input						Clk_sft,
    input						Rst,
    
    output 						Sdr_init_done,
    output						Sdr_init_ref_vld,
    output						Sdr_busy,
    
    input						App_wr_en,
	input [`ADDR_WIDTH-1:0]		App_wr_addr,  	
	input [`DM_WIDTH-1:0]		App_wr_dm,
	input [`DATA_WIDTH-1:0]		App_wr_din,	//synthesis keep
    
    input 						App_rd_en,
	input [`ADDR_WIDTH-1:0]		App_rd_addr,
	output 						Sdr_rd_en,
	output [`DATA_WIDTH-1:0]	Sdr_rd_dout	//synthesis keep
    
    
    
);
`ifndef SIMULATION
wire  			SDRAM_CLK;
wire 			SDR_RAS;
wire  			SDR_CAS;
wire  			SDR_WE;
wire  [`BA_WIDTH-1:0]	SDR_BA; 
wire  [`ROW_WIDTH-1:0]	SDR_ADDR;
wire  [`DATA_WIDTH-1:0]	SDR_DQ ;
wire  [`DM_WIDTH-1:0]	SDR_DM; 
`endif

// ============================================================
// ★★ 2026-10-05 第二十八版：主动发刷新请求（改前它被钉死在 1'b0）★★
// ============================================================
// 【为什么怀疑这里】
//   板上症状（2026-10-05 实测）：
//     · 噪点【位置钉死不动】—— 换个页再回来，还是同样那几个点
//       ⇒ 错的是【SDRAM 里存的数据】，不是"某一次读错了"
//     · 噪点【过一会儿才长出来】，不是一上电就有 ⇒ 是慢慢积累出来的
//     · 【没在显示的那几页更脏】，当前显示的那一页反而干净
//       ⇒ 一个槽在不被显示的时候，只有两件东西会碰它：
//          【刷新】和【写】。而"读一次"会激活整行再写回，
//          等于顺手把那一行充了电 ⇒ 【当前显示的那页一直是被读刷新的】，
//          只有没人读的槽完全依赖硬件的刷新。
//     · ★ 与读卡速度完全无关（老实验：SPI 12.5→3.125MHz，噪点数量和位置
//         一模一样）—— 刷新跟 SD 卡一点关系都没有，这条老结论正是最硬的旁证 ★
//   ⇒ 三条全都指向"没人读的那些槽在掉数据" ⇒ 先补刷新。
//
// 【这个改动会不会有害】
//   脉冲只有 1 拍，周期取厂商自己在 global_def.v 里写的那个数：
//       SELF_REFRESH_INTERVAL = 64_000_000 / SDR_CLK_PERIOD(8) / 2**11 = 3906
//   即 2048 行 / 64ms ⇒ 每行 31.25us，125MHz 下正好 3906 拍。
//   ⇒ 若控制器内部本来就在按同一个节奏刷新，这只是把刷新率变成 2 倍
//     （一条 REF 命令约 9 个 tRC，占用不到 0.1% 带宽，而读侧只用了约 18%）
//     —— 无害；
//     若它其实一直靠 App_ref_req 而这里又被钉成 0，那就正好把缺的那件事补上。
//   两种情况下都不会更差，所以这是个"零风险、高信息量"的实验。
//
//   ★ init 未完成前不发（计数器一直被清零），避免和初始化时序抢 ★
//
// ============================================================
// ★★ 2026-10-05 第二十九版：刷新率提高 8 倍（3906 → 488）★★
// ============================================================
// 【为什么】v28 上板：噪点全没了（⇒ "从来没刷新"这条真因确认），
//   但出现新症状——【个别点在闪、六页都闪、v28 之前没有】。
//   这正是"弱单元半死不活"的样子：
//     · v27 及以前一个刷新都没有 ⇒ 弱单元电荷漏光 ⇒ 【永远读错 = 静止噪点】
//     · v28 有刷新了，但周期取的是厂商公式原值 3906 拍 = 31.25us
//       ⇒ 走完全部 2048 行要 64ms ⇒ 【正好是规格下限、余量为零】
//       ⇒ 规格线以内的单元保住，差一点的单元在两次刷新之间漏掉
//       ⇒ 【时对时错 = 闪烁】
//   同一批单元，两种死法。用户报的三个特征全对上：
//     新出现（v28 才有）/ 个别点（只有少数弱单元）/ 所有页（每页都有自己的弱单元）。
//
// 【为什么是 488】= 3906/8，即每 3.904us 发一次 ⇒ 走完 2048 行只要 8ms
//   = 【半个显示帧】**每个单元每帧至少被刷两遍**，这是"显示中不会再闪"的充分条件。
//   （规格只要 64ms 一遍；我们给 8 倍余量，够覆盖电压/温度漂移和弱单元。）
//   代价：一条 REF 约 9~20 拍，每 488 拍一次 ⇒ 占用约 2%~4% 带宽，
//   而读侧只用约 18%（125M 峰值 / 18.4M 需求）⇒ 毫无压力。
//   tRC 下限（同 bank 连续命令 ≥60~66ns）也远没有碰到：488 拍 = 3.9us。
//   ★ 就算控制器自己还在按内部定时器刷，叠加起来也只是更密，不会更差 ★
// ============================================================
localparam [12:0] APP_REF_DIV = 13'd488;       // 3.904us @125MHz（8 倍余量）
reg [12:0]        app_ref_cnt;
reg               app_ref_req_w;

always @(posedge Clk or posedge Rst) begin
    if (Rst || !Sdr_init_done) begin
        app_ref_cnt   <= 13'd0;
        app_ref_req_w <= 1'b0;
    end else if (app_ref_cnt >= (APP_REF_DIV - 13'd1)) begin
        app_ref_cnt   <= 13'd0;
        app_ref_req_w <= 1'b1;                 // 单拍
    end else begin
        app_ref_cnt   <= app_ref_cnt + 13'd1;
        app_ref_req_w <= 1'b0;
    end
end

// ★★ 为什么把 self_refresh_open 从 1 改成 0 ★★
//   `self_refresh_open(1'b1)` 是要求控制器用【自刷新模式】来刷新，
//   而自刷新要求把 CKE 拉低 —— 可 sdr_as_ram 的端口里【根本没有 CKE 输出】，
//   本文件下面那行 `assign SDR_CKE=1'b1;` 把 CKE 钉死在高电平
//   ⇒ 自刷新【永远进不去】⇒ 这条刷新路径是死的。
//   改成 0 是让控制器走普通的自动刷新（REF 命令），它不需要 CKE 参与。
//   同时下面还自己按周期发 App_ref_req（万一这颗控制器的刷新是靠应用侧驱动的）。
//   两个旋钮一起拧，只要其中任意一个是真正的刷新机制，就都能刷上。
sdr_as_ram  #( .self_refresh_open(1'b0))
	u2_ram(
		.Sdr_clk(Clk),
		.Sdr_clk_sft(Clk_sft),
		.Rst(Rst),

		.Sdr_init_done(Sdr_init_done),
		.Sdr_init_ref_vld(Sdr_init_ref_vld),
		.Sdr_busy(Sdr_busy),

		.App_ref_req(app_ref_req_w),
		
        .App_wr_en(App_wr_en), 
        .App_wr_addr(App_wr_addr),  	
		.App_wr_dm(App_wr_dm),
		.App_wr_din(App_wr_din),

		.App_rd_en(App_rd_en),
		.App_rd_addr(App_rd_addr),
		.Sdr_rd_en	(Sdr_rd_en),
		.Sdr_rd_dout(Sdr_rd_dout),
	
		.SDRAM_CLK(SDRAM_CLK),
		.SDR_RAS(SDR_RAS),
		.SDR_CAS(SDR_CAS),
		.SDR_WE(SDR_WE),
		.SDR_BA(SDR_BA),
		.SDR_ADDR(SDR_ADDR),
		.SDR_DM(SDR_DM),
		.SDR_DQ(SDR_DQ)	
	);


assign SDR_CKE=1'b1;

//`ifndef SIMULATION
	EG_PHY_SDRAM_2M_32 sdram(
		.clk(SDRAM_CLK),
		.ras_n(SDR_RAS),
		.cas_n(SDR_CAS),
		.we_n(SDR_WE),
		.addr(SDR_ADDR[10:0]),
		.ba(SDR_BA),
		.dq(SDR_DQ),
		.cs_n(1'b0),
		.dm0(SDR_DM[0]),
		.dm1(SDR_DM[1]),
		.dm2(SDR_DM[2]),
		.dm3(SDR_DM[3]),
		.cke(1'b1)
		);
//`endif

endmodule 