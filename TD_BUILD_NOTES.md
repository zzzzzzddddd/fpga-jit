# TD 构建告警与时序问题记录

针对这一次构建（2026-09-28 20:04）里出现的三条 CRITICAL-WARNING，以及顺带查出来的
一条时序违例。每条都给了证据和结论，不是"看着像没事"。

---

## 结论速查

| # | 告警 | 是否新引入 | 处理 |
|---|---|---|---|
| 1 | `'derive_pll_clocks' is obsolete` | 否（一直有） | **已改** `top.sdc`：换成 `derive_clocks` |
| 2 | `U3/sdram location (...) is not honored` | 否，**改动前逐字相同** | 无需处理，见下文 |
| 3 | `1 clock net utilize the local routing` | 否，**改动前逐字相同** | 无需处理，见下文 |
| 4 | **Setup 时序违例 -328ps**（不是告警，是真问题） | 改动前就有 -146ps，HUD 让它恶化 | **已改** `frame_fifo_write.v`，见下文 |

---

## 1. `derive_pll_clocks` 已作废

TD 6.2 综合时刷：

```
CRITICAL-WARNING: 'derive_pll_clocks' is obsolete.
                  Please use 'derive_clocks' instead
```

厂商自己的板级例程也还是老写法（TD 安装目录下
`board_designs/ANLOGIC/AP102/DNA_AP102/source_code/constraints/DNA.sdc` 里同样是
`derive_pll_clocks`），属于示例没跟上工具版本。

**已改** `top.sdc`：

```diff
- derive_pll_clocks
+ derive_clocks
```

`derive_clocks` 是它的超集（工具提示原文："handles more types of clock deriving
resources"），后面那些 `rename_clock ... [get_pins {xxx_pll/pll_inst.clkc[n]}]`
不受影响。

**改完请核对一次**：跑完综合后看 `final_timing.rpt` 的 "Clock Summary"，应该仍然是
这 8 个时钟：

```
clk0 video_clk        clk4 clk
clk1 ext_mem_clk      clk5 hdmi_5x_clk
clk2 sd_card_clk      clk6 ext_mem_clk_sft
clk3 audio_mclk       clk7 u_audio_pll/pll_inst.clkc[0]
```

都在就说明派生关系没丢。

---

## 2. `U3/sdram location (12, 12) is not honored`

```
PHY-7002 CRITICAL-WARNING: Instance U3/sdram location (12, 12) is not honored.
          Cell's initial location is not legal at the beginning of ECO placement,
          and will be moved during placement.
```

**改动前就有，连坐标都一模一样。** 对比 2026-09-10 那次构建的 `run.log`：

```
PHY-7002 CRITICAL-WARNING: Instance U3/sdram location (12, 12) is not honored.
PHY-7002 CRITICAL-WARNING: Instance U3/sdram location (164, 288) is not honored.
```

`U3/sdram` 是 `src/sdram/sdram.v` 里例化的厂商硬核 `EG_PHY_SDRAM_2M_32`。硬核在
芯片上的位置是硅片固定的，TD 先给它一个初始坐标、布局时再挪到合法位置。

我把 `top.adc` / `top.sdc` / `pic_sdram.al` / `al_ip/*.ipc` 全搜了一遍，
**没有任何一条用户侧的位置约束**是指向它的——所以这条不是能"改约束"改掉的，
也不该改：日志自己说了 `will be moved during placement`，工具会解决。

**结论：无害，忽略。**

---

## 3. `1 clock net(s) utilize the local routing resources`

详情行（`phy_1/run.log`）：

```
ClockName      | DriverType | Clock/Fanout | LocalWireNum | NetName              | Marked
ext_mem_clk_sft| AL_PHY_PLL |     0/1      |      1       | U3/u2_ram/SDRAM_CLK  | true
```

**改动前同样有，同一个网、同样的数字。** （09-10 的 `run.log` 里一字不差。）

含义：`ext_mem_clk_sft`（125MHz 相移时钟）只驱动 **1 个负载** ——
SDRAM 的时钟输出脚。TD 认为给一个单负载网络占用全局时钟缓冲不划算，
就让它走了局部布线。

这对 SDRAM 时钟是**合理**的：点对点走线，不存在时钟偏斜问题，省下一个 GCLK。
TD 用 CRITICAL-WARNING 这个措辞是因为它是个通用检查项，不代表真有问题
（原文也是"Please check the log message and the sinks"——让你去看一眼，
而不是"你必须改"）。

顺带说明：这条**不能**用 SDC 消掉。`SYN-4025 Tag rtl::Net ... as clock net`
是综合阶段根据网表结构打的标记，跟 SDC 里有没有 `rename_clock` 无关。
要让它变全局网络只能给这个网加负载，那是本末倒置。

**结论：无害，建议忽略。**

---

## 4. Setup 时序违例（这条才是真问题）

### 现象

改动前（09-10）：

```
Setup : WNS  -0.146ns  TNS  -0.358ns  NUM_FEPS  3
```

改动后（09-28）：

```
Setup : WNS  -0.328ns  TNS  -0.809ns  NUM_FEPS  3
Hold  : WNS    11ps    TNS     0ps    NUM_FEPS  0
```

**违例原本就存在，加了 HUD 之后从 -146ps 恶化到 -328ps。**

要注意：**3 条违例全部在 `ext_mem_clk`（125MHz）域，不在 HUD 所在的
`video_clk` 域**。25MHz 那一侧余量大得很：

```
clk0 video_clk    25MHz   SWNS +4.236ns   0 Viol Endpoints   ← HUD 全在这
clk1 ext_mem_clk 125MHz   SWNS -0.328ns   3 Viol Endpoints   ← 违例全在这
```

HUD 本身没超预算（LUT 34.55%、BRAM 46.88%、DSP 41.38%，都还有余量），
但它多出来的 3200 个 LUT 改变了整体布局，把原本就勉强的那条路压得更差。

### 根因路径

```
Slack       : -0.328ns
Begin Point : frame_read_write_m0/write_buf/rd_addr_reg[0]
End Point   : frame_fifo_read_m0 的状态寄存器
Budget      : 8.000ns      实际: 11.770ns      逻辑级数: 7
Data Path   : 8.048ns (cell 4.828ns 59%, net 3.220ns 41%)

rd_addr →[ADDER 1.10ns]→ rdusedw →[ADDER 0.77+0.39+0.59]→
        →[10 级进位链比较器 ≈1.5ns]→ into_burst → O_wr_busy →
        → frame_fifo_read 状态机
```

问题出在 `src/frame_fifo_write.v` 的这一行：

```verilog
assign into_burst = (((write_len_latch <= (rdusedw + write_cnt))||rdusedw > BURST_SIZE) && ~App_rd_busy);
```

一个 21 位加法器 + 21 位比较器串在一条路径上。而且 `into_burst` 在
`S_CHECK_FIFO` 里是**每拍都采样**的，所以**不能用 multicycle 放宽** —— 只能拆逻辑。

### 修复

关键是被比较的两个量都是"一次突发才变一次"的寄存器：
`write_len_latch` 只在 `S_ACK` 更新，`write_cnt` 只在突发结束时 +128。
所以把它们之差做成一个同步递减的寄存器 `wr_remain`，就能把 21 位加法器整个
搬出组合路径：

```verilog
// write_len_latch <= rdusedw + write_cnt
// 等价于  (write_len_latch - write_cnt) <= rdusedw  ==  wr_remain <= rdusedw
wire        remain_hi = |wr_remain[ADDR_BITS-1:10];      // >= 1024 必不成立
wire        enough    = (~remain_hi) && (wr_remain[9:0] <= rdusedw);
assign into_burst = ((enough || rdusedw > BURST_SIZE) && ~App_rd_busy);
```

`wr_remain` 在**与 `write_cnt` 完全相同的三处**同步更新（复位、`S_ACK`、突发结束），
保证任何时刻都等于 `write_len_latch - write_cnt`。

### 验证

`sim/tb_fifo_equiv.v` 做的是**改动前后逐拍对比**：把改动后的模块和一份自动生成的
参考模块（`sim/ref_frame_fifo_write.v`，由 `tools/make_ref_fifo.py` 从当前源码
还原出改动前的写法）并排跑，每个时钟比较 `into_burst` / `App_wr_en` / `App_wr_addr`
/ `write_req_ack` / `write_finish` / `O_wr_busy` / 状态机 / FIFO 水位。

```
12 轮随机写长度 + 随机生产端速率，共 35922 拍对比：
  不一致次数   : 0
=== 等价性验证通过：改动前后逐拍完全一致 ===
```

**预期效果**：把 21 位加法器移出路径后，数据路径从 8.048ns 降到约 6.3ns，
对 8ns 预算有约 1.7ns 余量。但这是静态估算，**以 TD 重新跑一遍的实际数字为准**。

### ⚠ 需要你做的事

1. **重新综合 + 布局布线**，确认 `Setup WNS` 变成正值
2. **上板复测**：时序修好了不代表功能就对，尤其是这条路径在图片写入链路上，
   要确认显示正常、翻图不花屏

### 顺带发现（不需要动）

`frame_fifo_write` 在 `write_len` **不是 `BURST_SIZE` 整数倍时会卡死**
（`sim/tb_fifo_equiv.v` 里第 3 轮实测，改动前的原模块同样卡死）。
贵工程里 `write_len` 恒为 307200 = 2400×128，碰不到这个边界，所以不用管。
如果哪天要改成别的分辨率，记得 `宽 × 高 × 3 ÷ 4` 得是 128 的整数倍。

---

## 如果改完还是不过时序

-328ps 相对 8ns 只有 4%，**重新跑一次布局布线**（TD 的优化器有随机性，
  `OPT-0007` 那几行就是在做时序优化）经常会落到不同的解。先试这个。

还不行的话，同一条路径上还有一处可以再压：`S_WRITE_BURST_END` 里的
`write_cnt < write_len_latch` 也是 21 位比较器，用 `wr_remain != 0` 代替即可
（两者完全等价）。我这次没动它，因为它不在关键路径上，少改一处少一分风险。

---

# 基础融合构建记录（2026-09-29 13:33 / 13:36）

选题一（基础）融合进选题二（工业 HUD 拓展）之后的一次完整综合 + 布线。
改动内容见 `HUD_README.md` §3 的"基础融合改动过的文件"表和 §5.11/§5.12。
**本次不新增任何源文件**，所以 `.al` 和两个 run 目录的 `.prj` 都没动。

## 结论速查

| 检查项 | 09-29 基线 | 本次 | 判定 |
|---|---|---|---|
| `Successfully analyzed N source files` | 55 | **55** | ✅ 无新增/丢失文件 |
| `CRITICAL-WARNING` | 2×`PHY-7002` + 1×`PHY-5079` | **逐条相同** | ✅ 无新增 |
| `ERROR` | 0 | **0** | ✅ |
| Setup 违例端点 | 0 | **0** | ✅ |
| Hold 违例端点 | 0 | **0** | ✅ |
| Setup WNS (SWNS) | +0.375ns | **+0.310ns** | ⚠ 差 65ps，见下 |
| Hold WNS (HWNS) | +0.007ns | **+0.011ns** | ✅ 略好 |
| `#lut`（门级） | 7467 | 7585 | +118 |
| `#lut`（布线后） | — | 7832 (39.96%) | — |
| `#reg`（布线后） | — | 4937 (25.19%) | — |
| `#bram` / `#dsp` / `#pll` | 31 / 13 / 3 | **31 / 13 / 3** | ✅ 不变 |
| bit 流大小 | 641264 B | **641264 B** | 同 |

`top.sdc` 新增的 `set_false_path -from [get_clocks {video_clk}] -to [get_clocks {sd_card_clk}]`
解析干净：日志里 `read_sdc ../../top.sdc` 之后**没有任何 `USR-` 报错**
（只有 6 条正常的 `USR-1002 Derived clock:` 信息行）。
`final_timing.rpt` 里 `sd_card_clk` 自身的 SWNS 是 +1.623ns，新增的
`video_clk -> sd_card_clk` 通路**没有产生任何违例**。

## 那 65ps 是什么：是布线绕远，不是逻辑变慢

关键路径前后**是同一条**，而且**逻辑一个字没变**：

| | 基线 | 本次 |
|---|---|---|
| Begin Point | `dbl_buf_m0/frame_sel_reg_syn_10.clk` (sd_card_clk) | 同 |
| End Point | `frame_fifo_write_m0/App_wr_addr_r_reg[15]_syn_4.b[0]` (ext_mem_clk) | 同 |
| Logic Level | `1 ( LUT3=1 )` | **`1 ( LUT3=1 )`** |
| **cell 延迟** | **0.695ns** | **0.695ns（完全相同）** |
| **net 延迟** | 0.693ns | **0.758ns（+65ps）** |
| 终点的布线坐标 | `x015y017z3` | `x017y018z3`（挪了 2 列） |

也就是说：**新增的约 118 个 LUT 挤动了布局，`frame_sel` 这根线（fanout=6）的落点被
挪了 2 列，线变长 65ps。** 这正是本文档上面那段"每多一个 LUT 都在啃这条路径的布局
裕量"的又一次印证 —— 和 `wr_remain` 那次不同，这次不是逻辑问题。

**判定：可以接受。** 8ns 预算下还剩 310ps（3.9%），两个 corner 都是 0 违例，
而且 310ps 是**布线裕量**不是逻辑裕量，重跑布线就有机会回来。

## ⚠ 重跑布线这一次是无效的：TD 走的是增量 ECO

按上面"如果改完还是不过时序"那段的建议重跑了一次 `phy_1/run.bat`，
结果 SWNS/HWNS **逐位相同**（0.310 / 0.011），bit 流大小也一样。
查日志才发现原因：

```
PHY-3001 : Start incremental legalization ...
PHY-7002 CRITICAL-WARNING: Instance U3/sdram location ... will be moved during placement.
```

TD 检测到 `place_flow.status` / `route_flow.status` 已经存在，于是**复用了上一次的布局
数据库做增量 ECO**，根本没重新布局，所以"再跑一次碰运气"这个办法**在这里不成立**。

**要真正换一个解**，得先删掉这几个中间文件逼它从头布局：

```bash
cd pic_sdram_Runs/phy_1
rm -f flow.status place_flow.status route_flow.status \
      pic_sdram_place.db pic_sdram_pr.db pic_sdram_eco_pr.db \
      pic_sdram_inst.bid pic_sdram_place.timing pic_sdram_pr.timing
# 然后照常跑 run.bat
```

本次**没有做**这一步：310ps 的裕量对演示完全够用，不值得为它冒一次结果未知的重跑。

## 顺带记下：`note_inc_lut` 合并成 16 项并不省 LUT

曾考虑把报警的 800/640Hz 并进 `hdmi_audio_tone_i2s_64fs.v` 里现有的
`note_inc_lut`（8 项 case 函数，TD 实现成 32 位宽的 8:1 mux），
用 `alarm_s2 ? (S_alarm_hi ? 4'd9 : 4'd8) : {1'b0, S_note_idx}` 做索引。
算下来**不省**：

* 现状：8:1 mux（约 2 LUT4/bit × 32）+ 报警用的 3:1 mux（约 1 LUT4/bit × 32）≈ 96 个 LUT4
* 改法：16:1 mux（约 3 LUT4/bit × 32）≈ 96 个 LUT4

所以**保持现状，不动**。

---

## 环境备忘：批处理怎么跑

`pic_sdram_Runs/{syn_1,phy_1}/run.bat` 里写的是

```
D:/TD APP/bin/td_commands_prompt.exe D:\TD APP\arch/../doc/scripts/DefaultFlow.tcl
```

**这个路径带空格且没加引号**，直接跑 `run.bat` 参数会被截断。做法是把它复制到
一个无空格路径再调用（`DefaultFlow.tcl` 会用 `source ./settings.cfg` 读当前目录，
所以必须 `cd` 到对应的 run 目录再执行）：

```bash
mkdir -p /d/td_flow && cp "/d/TD APP/doc/scripts/DefaultFlow.tcl" /d/td_flow/
cd pic_sdram_Runs/syn_1 && "/d/TD APP/bin/td_commands_prompt.exe" /d/td_flow/DefaultFlow.tcl
cd ../phy_1           && "/d/TD APP/bin/td_commands_prompt.exe" /d/td_flow/DefaultFlow.tcl
```

拷贝副本已经在 `D:\td_flow\DefaultFlow.tcl`，下次直接用即可。
`run.bat` 结尾还有个 `pause`，非交互环境下会挂住，所以别用 `run.bat`。

**跑之前先关掉 TD IDE。** 批处理和 IDE 读写的是同一个 run 目录
（`run.log`、`*.db`、`flow.status`），同时操作会得到一次混合运行的结果，
而且看起来还像正常跑完了 —— 没法用在时序核对上。

`syn_1` 只跑综合（约 20 秒），`phy_1` 跑布局布线（约 3 分钟）。
