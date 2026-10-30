# 压力容器多媒体播放系统 — 工程目录说明

EG4S20BG256 / 安路 Tang Dynasty 6.2.168116。工程入口是 `pic_sdram.al`（TD 里直接打开）。
详细设计见 `HUD_README.md`，构建告警与时序见 `TD_BUILD_NOTES.md`，TF 卡素材链路见 `FAT32_README.md`。

## 目录

| 目录 | 内容 | 说明 |
|---|---|---|
| `src/` | RTL 源码 | TD 工程按相对路径引用，**不要挪** |
| `al_ip/` | PLL / FIFO / SDRAM 等 IP | 工具生成，**不要挪** |
| `pic_sdram_Runs/` | 构建输出 | `syn_1/`、`phy_1/` 为当前流水线；`best_result/` 是已验证 bit（`sweep_candidates/` 为 20 个布线种子候选）；`archive/` 是历史 bit 与源码备份 |
| `tools/` | 素材生成、卡检查、自检脚本 | 脚本按仓库根目录解析路径，在根目录运行 |
| `tools/_selftest/` | 自检脚本与 testbench | 生成的 `.vvp` / `_*.png` 可随时重跑 |
| `sd_assets/` | TF 卡素材**母版** | `01..06.png/.wav` + `fat32/`（可直接拖进卡）+ 历次备份子目录 |
| `sd_image.img` | 裸盘整盘镜像（28 MB） | 由 `tools/layout_sd.py` 生成，可重建；`tools/write_sd.py` 用它写卡 |
| `log/` | TD 构建日志 | 已按 `2026-09/`、`2026-10/` 分月归档，新构建仍写在本目录 |
| `photo/` | 脚本生成的预览图 | `gen_hud_assets.py` / `gen_sd_assets.py` 的输出位置 |
| `sim/` | 仿真 testbench 与输出 | `hex2bmp.py` 读 `sim/out_hud_*.hex` |
| `probe/` | 独立的 SPI/FAT32 探针工程 | 自带 `.al` 与 `*_Runs/`，与主工程无关 |
| `_fat32_backup/` | FAT32 改造前的回滚备份 | `FAT32_README.md` 明确引用，保留 |
| `_archive/` | 2026-10-30 整理归档 | 见下节，确认无用后可整个删除 |

## 根目录保留的文件

- `1.bmp` / `3.bmp` / `A.bmp` / `logo.bmp` — 原始素材；`tools/bmp_noise_check.py` 会读根目录的 `1.bmp`、`3.bmp`。
- `hud_rom_cjk.mem` / `hud_rom_dial.mem` / `hud_rom_sincos.mem` — HUD 字库/表盘数据，RTL 注释约定放在工程根目录。
- `convert_images.py` — 单张图片转 640×480 24bit BMP 的小工具。

## `_archive/` 里是什么

| 路径 | 内容 |
|---|---|
| `C_snapshot_20260910/` | 2026-09-10 的完整旧工程副本（原 `C/`），有 35 个文件与当前版本不同或缺失，仅作历史参考 |
| `scratch/` | 9–10 月调试时抓的 `_syn_out.txt` / `_phy_out*.txt` / `_chk_*.txt` / `_c*.txt` / `_wavchk.py` |
| `previews/` | 根目录散落的检查图：`check*.png`、`sheet*.png`、`img0.png`、`_wm_*.png` 等（均可由脚本重新生成） |
| `_tmp_oldpng/` | 旧版六张 `01..06.png` |
| `noise_look/` | 六张噪声对照图 |
| `src_bak/` | `src/` 下 TD 自动生成的 `.v.bak`（不参与编译） |
| `tools_bak/` | `tools/_selftest/watermark_off.py.bak` |
| `tools_outputs/` | `tools/` 下的历史输出图：`wm_compare.png`、`_final_sheet.png`、`_sheet_*.png` |
| `selftest_outputs/` | `tools/_selftest/` 的 12 个 `.vvp` 与 5 张对比图，重跑脚本即可再生成 |
| `MANIFEST.txt` | 每个文件的原路径 → 归档路径，照着搬回去即可还原 |
| `pic_sdram.al.unexcl.bak` | TD 的旧工程备份 |

## 常用操作

```powershell
# 当前链路：母版 sd_assets/0N.png + 0N.wav -> sd_assets/fat32/ 的 12 个文件
# （BMP 头部与卡上逐字节一致，整个 fat32/ 目录拖进卡根目录即可）
python tools/real_assets.py
python tools/real_assets.py --check        # 只校验源素材

# 旧的“占位素材”链路（gen 占位图/音频，再整理成 fat32/），仅供通路调试
python tools/gen_sd_assets.py
python tools/make_fat32_card.py

# 旧的固定 LBA 链路：生成/写入整盘镜像（现设计用不到）
python tools/layout_sd.py
python tools/write_sd.py --list
python tools/write_sd.py --drive N --yes

# 核对母版 / fat32 拷贝 / 实体卡三者一致（卡在 E:\）
python -X utf8 tools/_selftest/chk_card_vs_master.py E:\
```

> 换素材时注意 `tools/real_assets.py` 的 `PAGE_IMG_SRC`：报警页固定是页 5 = `06.BMP`，**红色那张必须编号 06**。
