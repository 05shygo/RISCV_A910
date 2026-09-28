# ifu2 配置 Fmax 扫频实测（xc7k325tffg900-2，Vivado 2023.2）

> 对象：IFU=2 自研前端（`USE_IFU2`，TAGE `BP_PRED=1` / GHR=16，icache 1024B 16B 行，
> 存储为 `mySoC/sync_mem.v` 块 RAM 版），综合顶层 `synth/top_fmax.v`。
>
> 方法：`vivado -mode batch -source synth/build_fmax.tcl -tclargs <period> impl`，
> 跑到 route_design 读 WNS，Fmax = 1000/(period − WNS)。
> 原始报告与完整 log 已入库：`synth/reports/`。

---

## 0. 结论摘要

**当前 RTL 的天花板 ≈ 115 MHz**：9.0ns 约束收敛（+0.323ns 余量）；8.5ns 及以下直接垮掉。

| period | WNS | 违例终点 | TNS | 判定 | 反推 Fmax |
|---|---|---|---|---|---|
| 12.0 ns | +1.085 | 0 | 0 | 过 | 91.6 MHz |
| 11.0 ns | +0.687 | 0 | 0 | 过 | 97.0 MHz |
| 10.0 ns | +0.366 | 0 | 0 | 过 | 103.8 MHz |
| 9.5 ns | +0.365 | 0 | 0 | 过 | 109.5 MHz |
| **9.0 ns** | **+0.323** | 0 | 0 | **过（最紧）** | **115.3 MHz** |
| 8.5 ns | −0.686 | 984 | −250 ns | 垮 | — |
| 8.0 ns | −0.696 | 978 | −278 ns | 垮 | — |

两点注意：

1. 约束放松时反推 Fmax 反而下降（12ns 只有 91.6MHz）是工具行为，不代表 RTL 变差；
   有意义的数字是最紧收敛点 9.0ns 的 115.3MHz。
2. 8.5/8.0 不是"差一点"：一次掉出 ~980 个违例终点、TNS −250ns；两次失败 run 里
   工具最好也只把关键路径压到 ~8.7ns（≈115MHz 的物理下限）。换工具参数没用，
   再往上必须动 RTL。

---

## 1. 瓶颈：一条共享的「EX 重定向 → 前端数组」单周期链

9.0ns run 全部 500 条最差路径（`timing_paths500.rpt`）的起点**是同一个寄存器位**
`U_CSR/minstret_reg[3]`（500/500）；8.5ns run 里 500 条全部落在
`U_ID_EX/ex_csr_addr_reg`（bit[4] 465 条 + bit[0] 35 条）。起点"换人"说明它并不是
逻辑源，只是这条共享长链上电学最差的输入：

```
CSR 读数据 → EX ALU（7×CARRY4 串行，28 位量级）→ u1_taken 分支判决
→ mispredict0 → actual_npc → TAGE q_row_idx/q_row_tag 写口
                              + icache 读地址（u_dat_way*/ADDRARDADDR）
                              + ibuf ent_q 写口
```

- 25~26 级逻辑，数据路径延迟 8.0~8.6ns，其中 **76% 为走线延迟**；
- 终点分布（9.0ns run，500 条口径）：ibuf `ent_q_reg` 429 条（86%）、
  icache 读地址 43 条（9%）、TAGE row 写口 24 条（5%）；
- 最差 50 条 slack 只从 +0.323 排到 +0.536 —— 整片同步地紧，不是个别尖峰。

即 EX 段的「CSR 读 → ALU → 分支判决 → NPC 重定向」和前端数组寻址压在**同一拍**里。

---

## 2. 下一步候选（未实施）

1. EX→前端之间切一刀：NPC 选完先寄存一拍再进 icache/TAGE/ibuf（代价：重定向 +1 拍）；
2. 或只给 TAGE 更新口（row idx/tag）打拍；
3. 削弱判决段进位链（28 位 carry 串行是链上最贵的一段）。

第 1 条预计一刀消掉 ~86% 的违例终点（ibuf 是大头）。

---

## 3. 文件索引

| 路径 | 内容 |
|---|---|
| `synth/build_fmax.tcl` / `synth/top_fmax.v` | 测量脚手架与综合顶层（沿 85e55ed） |
| `synth/reports/fmax_impl_<period>ns/` | 7 个 impl run：timing_summary / timing_paths500 / utilization |
| `synth/reports/fmax_synth_12.0ns/` | 早期仅综合 run（未布线，仅作参照） |
| `synth/reports/logs/fmax_<period>.log` | 各 run 完整 stdout（含 `FMAX_SUMMARY` 行） |
