# 第三轮：实现侧两条杠杆都用尽 + gshare 对照实测（2026-09-29）

> 对象：ifu2 配置（`USE_IFU2` + `REDIRECT_PIPE`，icache 1024B/16B 行）。
> 基线：**第二轮 RTL 不变**，6.9ns 收敛（WNS +0.114）⇒ **147.4 MHz**。
> 方法：复用第二轮 run 已综合的 synth DCP 做**纯 impl**（opt/place/phys_opt/route，2~5 分钟一个 run），
> 因为工程模式的 synth DCP 不带约束，必须补 `read_xdc <run>/fmax_gen.xdc`。
> 用 `base` 臂验证过：与工程 run **逐位一致**（6.9ns → +0.114，6.5ns → −0.473）。

---

## 0. 结论

1. **扇出复制是负结果**：把全设计 ≥60 负载的 147 根网做 3 轮 `phys_opt_design -force_replication_on_nets`
   （888→16、`q_row_idx` 62→3 都生效）后，6.9ns 点从 +0.114 掉到 **−0.881**（6.5ns 点 −0.473 → −0.862）。
2. **布局压缩是负结果**：12 个 pblock 臂（形状 12×200 ~ 48×50、密度 21%~75%、单时钟区域、
   三子块 tage/ibuf/btb、Explore、CONTAIN_ROUTING）**全部不如基线**，最好 −0.067（s48x50）。
3. **机理（本轮最值钱的发现）**：单跳延迟与负载、与物理跨度**都无关**——
   500 条最差路径的逐跳中位延迟在压缩前后是 **0.412ns → 0.411ns（不变）**；
   连 1 列宽的跳也要 0.35~0.45ns。周期 = ~14 跳 × ~0.41ns + 0.8ns 逻辑 ≈ 6.5ns。
4. **`切 GHR` 的收益被高估**：500 条最差路径里 **406 条终点在 ibuf `ent_q`，且 0 条含 ghr/哈希跳**
   （走的是前向链 `q_row_idx → 表读 → dir_pred 优先树 → taken/字选 → push/写锥 → ent_q`）；
   只有 18 条终点在 `q_row_idx`/`q_row_tag`（哈希闭环）。切状态环只值 18/500。
5. **gshare 对照（`BP_PRED=0`，RTL 里本来就有的变体）**：最紧收敛点 **6.0ns（+0.133）⇒ 170.4 MHz**，
   比 TAGE 高 **15.6%**，CoreMark 代价 −0.71% 周期（既有实测）。而且它在紧点上的绑定路径换成了
   **EX→前端**（`ex_A`/`ex_csr_op` → `id_pc`/`id_pred_npc`/`ibuf/head_q`，≈5.87ns）
   ⇒ **两种配置最后都撞在 ~170 MHz 的「EX→前端」同一堵墙上**。

## 1. 扇出复制（P0a）

| 臂 @6.9ns | WNS | 说明 |
|---|---|---|
| base（基线复刻） | +0.114 | 与工程 run 逐位一致 |
| pass（3 轮空转 phys_opt） | +0.114 | 对照：多跑 3 轮本身无影响 |
| **repl（3 轮强制复制）** | **−0.881** | 6.5ns 点：−0.473 → −0.862 |

- 复制效果（网表侧实测）：`ent_q[6][150]_i_1` 888→16、`q_row_idx_reg[1]_0[*]` 62→3、
  `tg_u_reg_r1_0_63*` 189→1、`sel0[1]` 233→1、`ex_alu_op[3]_i_1` 250→1。
- 但第一跳（`q_row_idx→表地址`，62→9 负载）只从 **0.752 → 0.648ns（省 0.10ns）**，
  同一条闭环的其它跳合计 **+0.83ns**（副本改变了布局、D 侧网变长）→ 净 −1.0ns。
- 结论：**扇出负载不是瓶颈**。全局 hf 报告里那几根 888/736/613 负载的网也都不在违例路径上
  （6.5ns 的 500 条最差路径里 0 次出现；`wb_is_mret`、`U_IF_ID/Q[15..16]` 在 opt 阶段已被工具自己拆到 37/5 负载）。

## 2. 布局约束（P0b/P0c，12 个臂，均 @6.9ns）

| 臂 | pblock | 面积/密度 | place | WNS |
|---|---|---|---|---|
| 基线 | 无 | — | Default | **+0.114** |
| expnone | 无 | — | Explore | +0.065 |
| pb48def | 48×100 (X53..100,Y125..224) | 4800 / 36% | Default | −0.116 |
| pb24def | 24×200 | 4800 / 36% | Default | −0.074 |
| pb24exp | 24×200 | 4800 / 36% | Explore | −0.196 |
| pb12exp | 12×200 | 2400 / 73% | Explore | −0.249 |
| pb24crexp | 24×200 | 4800 / 36% | Explore + CONTAIN_ROUTING | −0.521 |
| s48x50 | 48×50（单时钟区域） | 2400 / 73% | Default | −0.067 |
| s32x100 | 32×100 | 3200 / 55% | Default | −0.109 |
| s24x100 | 24×100 | 2400 / 73% | Default | −0.316 |
| s24x100exp | 24×100 | 2400 / 73% | Explore | −0.132 |
| s16x150 | 16×150 | 2400 / 73% | Default | −0.546 |
| sub3 | tage 10×100 + ibuf 20×100 + btb 4×50 | ~49% | Explore | −0.216 |

- IFU 簇（9194 个原语）确实被压紧了：跨 90 列 → 48 列；单时钟区域臂的 skew 也从 −0.029 改善到 −0.012，
  数据路径 6.504ns（比基线 6.755 短 0.25ns）——但 WNS 仍然更差。
- **逐跳延迟分布不变**（见 §0.3），所以"把版图摊小"并不能换来 Fmax。
- 关键路径上那根 `cnt_q_reg[4]_2`（fo=114）即使在 7 列宽的压缩块里仍要 **0.966ns**：
  它的 114 个负载是撒在整个 ibuf 写锥上的，单跳成本由**该网全部负载的散布**决定，压缩版图改不了这个。

## 3. gshare 对照（`BP_PRED=0`，全流程 run，RTL/配置均未改动）

| period | WNS | 判定 | 反推 Fmax |
|---|---|---|---|
| 6.9 ns | +0.426 | 过 | 154.5 MHz |
| 6.5 ns | +0.173 | 过 | 158.1 MHz |
| **6.0 ns** | **+0.133** | **过（最紧）** | **170.4 MHz** |
| 5.6 ns | −0.686 | 垮 | — |
| 5.2 ns | −0.767 | 垮 | — |
| 4.8 ns | −1.255 | 垮 | — |

- gshare 生效已确认：紧点最差路径起点是 `g_gshare.u_bht/q_idx_q_reg`。
- 6.0ns 起绑定路径变成 **EX→前端**：`U_ID_EX/ex_A_reg[13] → u_ibuf/head_q_reg[0]/D`、
  `ex_csr_op_reg[1]_rep__0 → U_IF_ID/id_pred_npc_reg[26]`、`ex_A_reg[3] → U_IF_ID/id_pc_reg[4]`
  （路径里含 ALU 进位链 → `ex_alu_f` → 重定向/目标选择 → IF_ID 捕获逻辑）。
- 也就是说：**TAGE 147.4 MHz / gshare 170.4 MHz 两个天花板，共同卡在 EX→前端那一族**（≈5.87ns）。

## 3.5 第三轮下半场：RTL 削级数（bit-exact）+ 按 `vivado_guide.txt` 扫策略

### A. RTL 削级数 5 刀（补丁见 `patches/`，全部逐位等价）

| # | 文件 | 改动 | 等价性依据 |
|---|---|---|---|
| C1 | `rv32ifu2_tage.v` | per-slot provider/altpred：去掉"3 位优先编码→解码→mux"往返，改逐级 one-hot 优先选择 | 优先级 h4>h3>h2>h1 与"无命中回 T0"不变 |
| C2 | `rv32ifu2_ibuf.v` | `acc_push >= k` → `push_num >= k & space >= k`（space 只依赖寄存器 cnt_q） | `min(p,n) ≥ k ⟺ p ≥ k ∧ n ≥ k` |
| C3 | `rv32ifu2_top.v` | `want_cnt_raw = (t0?1:t1?2:t2?3:4) - pc_ofs` 取代 any_taken/taken_slot/blk_left 三路 | 无 taken 时 `taken_slot` 默认 3 ⇒ 原式退化成 `4-pc_ofs` |
| C4 | `rv32ifu2_tage.v` | `init_done` 门控从路径末尾提前到 `tb_hit`/`t0_pred` | 扫描期 hit=0 ⇒ 取已门控的 t0_pred |
| C5 | `ALU.v` | 32 位比较拆 4×8 位并行 + 组间优先（有符号用标准恒等） | **Verilator A/B：16 op × 12 边界向量 + 20 万随机 → PASS** |

- 级数：500 条最差路径平均 **14.1 → ~13**；最差路径 6.755 → 6.386ns；固定周期 slack 在 6.5/6.6/6.7 三点一致 **+0.35~0.39ns**。
- 注意：单周期点 A/B 有 **±0.2~0.3ns 的"布局运气"**（同 RTL 同流程逐位确定，pass 臂复现 +0.114 验证过）；松约束点（6.9ns）工具可能把等价 RTL 规范成同一网表。

### B. 按 `vivado_guide.txt` 扫策略（固定 6.5ns，基线 −0.473，见 `strat/`）

| 臂 | 策略 | WNS | Δ |
|---|---|---|---|
| ctrl | Defaults / Defaults | −0.473 | —（精确复现基线） |
| **ndhi** | impl **Performance_NetDelay_high** | **−0.191** | **+0.282**（最优） |
| prpo | impl Performance_ExplorePostRoutePhysOpt | −0.258 | +0.215 |
| syncarry | synth Flow_PerfThresholdCarry + impl Explore | −0.328 | +0.145 |
| pexp | impl Performance_Explore | −0.347 | +0.126 |
| retim | impl Performance_Retiming | −0.417 | +0.056 |
| synperf | synth Flow_PerfOptimized_high + impl Explore | −0.510 | −0.037 |
| ffo | net 级 `MAX_FANOUT 32`（150 根 IFU 胖网） | −0.313 | +0.16 |
| merge | `opt_design -merge_equivalent_drivers` | −0.592 | −0.12 |
| incr | `read_checkpoint -incremental`（6.9ns 已布线） | −0.775 | −0.30 |

指南的版本差异（已实测确认）：综合策略名是 UltraScale 命名，7 系列用 `Flow_*`；`set_property SEED [get_runs impl_1]` 与 `place_design -seed` 在 2023.2 都不存在；`FORCE_MAX_FANOUT` 不是 design 属性；`report_design_analysis -complexity -congestion` 显示**本设计无拥塞**（窗口都在阈值以下）→ 拥塞类手段没有着力点。

### C. 组合（RTL 五刀 + Performance_NetDelay_high）

| period | WNS | 说明 |
|---|---|---|
| 6.5 ns | **+0.066（过）** | 基线同点 −0.473 ⇒ **+0.54ns** |
| 6.2 ns | −0.227 | 最紧通过点 ≈ 6.35ns ⇒ **≈157 MHz**（基线 147.4） |

新的绑定路径换成了 EX 控制锥：`ex_csr_op_reg[*] → U_ID_EX/{ex_rf_we,ex_wR,pc_o,ex_pc4,ex_sext}_reg/CE` 与 `icache/q_pc_q_reg[*] → icache mem ADDRARDADDR`（见 `strat/combo/`）。

## 4. 复现

```bash
# 快速 impl 试验台 (2~5 分钟/run, 不要重新综合)
vivado -mode batch -source scripts/p0a_flow.tcl -tclargs 6.9 base     # 基线复刻
vivado -mode batch -source scripts/p0a_flow.tcl -tclargs 6.9 repl     # 扇出复制
vivado -mode batch -source scripts/p0b_flow.tcl -tclargs 6.9 pb24def {SLICE_X65Y75:SLICE_X88Y274} Default 0
vivado -mode batch -source scripts/p0c_flow.tcl -tclargs 6.9 sub3 "pb_tage|*g_tage.u_tage*|SLICE_X64Y125:SLICE_X73Y224;..." Explore
# gshare (全流程, ~7 分钟/run)
vivado -mode batch -source scripts/build_fmax_gs.tcl -tclargs 6.0 impl
```

注：`scripts/build_fmax_gs.tcl` = `synth/build_fmax.tcl` 的副本，只改了 3 处：显式 SP/ROOT、
工程名加 `_gs` 后缀（避免删掉 TAGE 的 run 目录）、`BP_PRED=1`/`BP_GHR_W=16` → `BP_GHR_W=8`。

## 5. 文件

| 路径 | 内容 |
|---|---|
| `logs/p0a_*.log` | 扇出实验 6 臂（含 `P0A_PRE/POST` 每根网的复制前后扇出、`P0A_SUMMARY`） |
| `logs/p0b_*.log`、`logs/p0c_*.log` | 12 个 pblock 臂（含 `SPAN`/`P0C_PB`/`P0C_SUMMARY`） |
| `logs/gshare_*.log` | gshare 6 个周期点（含 `FMAX_SUMMARY` / `WORST_NON_EX`） |
| `gshare/fmax_impl_<p>ns/` | gshare 各点 timing_summary/utilization（6.0/6.9 另含 timing_paths500/f1） |
| `scripts/` | 上述四支脚本 |
