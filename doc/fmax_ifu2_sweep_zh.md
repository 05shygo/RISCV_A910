# ifu2 配置 Fmax 扫频实测（xc7k325tffg900-2，Vivado 2023.2）

> 对象：IFU=2 自研前端（`USE_IFU2`，TAGE `BP_PRED=1` / GHR=16，icache 1024B 16B 行，
> 存储为 `mySoC/sync_mem.v` 块 RAM 版），综合顶层 `synth/top_fmax.v`。
>
> 方法：`vivado -mode batch -source synth/build_fmax.tcl -tclargs <period> impl`，
> 跑到 route_design 读 WNS，Fmax = 1000/(period − WNS)。
> 原始报告与完整 log 已入库：`synth/reports/`。

---

## 0. 结论摘要

> 📌 本节与 §1 是**第一轮**（TAGE 阵列重排 + 存储器换 BRAM 之后）的扫频结论，
> 那一版 RTL 的天花板 ≈ 115 MHz。**第二轮按 §1 的归因做了重构，见 §2** ——
> 那一轮之后的新 Fmax 还没测（要重跑综合）。

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

## 2. 第二轮：按这条链做重构（2026-09-28，已实施）

上面 §1 归因出的三个结构性原因，逐条改掉。**前四步要求周期逐位不变**（不等就是错），
第五步是唯一花周期的一刀，代价逐条实测。

| 步 | 改什么 | 提交 | VCS 实测（IFU=2） |
|---|---|---|---|
| 1 | 修掉 **112 个推断 latch**（`Control.v` 6 处、`ALU.v` 的 `alu_c`、`MEM.v` 的 `rdo`+`wdata_out`）—— 它们原先被报成 `TIMING-20 Non-clocked latch`，**根本不进时序分析** | `d0b6cee` | 逐位不变 |
| 2 | 把 `redirect` 从 push 计数链摘下来（`push_num` 去掉 `& ~redirect`）—— 它原先一路穿透到 `acc_push → pushed_m → ghr_next`、`pc_adv/reached_taken → next_pc`、以及 `ent_q` 的写数据锥，而这条 gating 语义上是冗余的（IBUF 的 `flush=redirect` 分支根本不写 `ent_q`） | `4cfc39d` | 逐位不变 |
| 3 | CSR 读搬到 **ID 级** + EX→ID 旁路 —— 那条 16:1 读 mux 原先挂在 ALU 的 A 口上（还有一条反向长链经 `A_forward` 回到 `ID_EX.ex_A`） | `34ba0fc` | 逐位不变 |
| 4 | 分支目标改 **三个并行加法器**（`npc_pc4`/`npc_imm`/`npc_jalr`），`actual_npc` 不再串在 ALU 进位链后面 | `5aa66f2` | 逐位不变 |
| 5 | **EX 重定向打一拍进前端**（`REDIRECT_PIPE`，默认开）—— 把这条单周期长链从中间切断 | `378385d` | branch_bench 159,717→163,743 (+2.52%)；CoreMark 10,963,525→11,208,658 (+2.24%)，Score 2.736→2.676 |

第 5 步的代价恰好是**每次重定向 1.0002 拍**（branch_bench 那次 4,027 次重定向、多 4,026 拍），
方向准确率五类逐项不变 —— 打拍只改恢复延迟，不改预测质量。
`REDIRECT_PIPE=0` 逐位回到 159,717，开关可信。

顺带记一笔被实测否掉的猜想：把 `refill_req` 也改成跟**当拍**的 `iu_chgflw_vld`
（想省掉一次错误路径的 icache 回填）反而更慢 —— CoreMark 11,208,658 → 11,213,090。

**这一步之后 Fmax 是多少，要等新一轮综合。** 预期瓶颈会从 EX 段移到**前端 F1 那一拍**
（icache tag 比较 + BTB 行匹配 + TAGE 读/优先/use_sel + taken 选择 + next_pc）——
而那一拍**到现在都没有测量数据**：`report_timing -max_paths 500` 的默认 `-nworst 1`
每终点只报最差一条，500 条全被 EX 起点占满了。`synth/build_fmax.tcl` 已经补了三样
（`-nworst 8` 的同终点多起点报告、`-from q_pc_q_reg` 的定向报告、log 里的
`WORST_NON_EX` 一行），下一轮综合就能看到 F1 到底多长。

拿到那个数字之后才好定：缩 TAGE 几何 / 换 gshare（它在 CoreMark 上只值 −0.71% 周期，
但组合链比 TAGE 短 6~9 级）/ 重做 IBUF 的 1224 个触发器。

---

## 3. 文件索引

| 路径 | 内容 |
|---|---|
| `synth/build_fmax.tcl` / `synth/top_fmax.v` | 测量脚手架与综合顶层（沿 85e55ed；第二轮补了 F1 定向报告） |
| `synth/reports/fmax_impl_<period>ns/` | 7 个 impl run：timing_summary / timing_paths500 / utilization |
| `synth/reports/fmax_synth_12.0ns/` | 早期仅综合 run（未布线，仅作参照） |
| `synth/reports/logs/fmax_<period>.log` | 各 run 完整 stdout（含 `FMAX_SUMMARY` 行） |
