# 自研 IFU2 与香山 IFU/BPU 对比

> **代码基准**
> - **IFU2**：`mySoC/ifu2/`（当前工作树；Makefile 默认 `IFU=2`、`BP_PRED=0`、`ICACHE_BYTES=1024`）
> - **香山**：`/x2025/GPrj1/IC1/riscv/RISCV_CPU/XiangShan`，commit `893e1580b`
>
> **口径**：结构、参数、连线全部以 RTL 为准；性能数字只在 IFU2 侧有仓库内实测，香山侧本仓库没有跑分，**本文不比较两者的 CoreMark 分数**。
>
> **代码优先说明**：IFU2 的 `doc/ifu2_zh.md` 与部分 RTL 头注释有滞后，本文以当前 `rv32ifu2_top.v` 的连线为准；四处主要差异见 §10。

---

## 0. 结论速览

| 维度 | IFU2 | 香山 IFU/BPU |
|---|---|---|
| 核的定位 | IFU2 是前端模块：**miniRV 只接 lane0（消费 1 条/拍）**，**A910 接 3 lane**；两者分别是顺序/乱序核 | RV64、8-wide decode/rename、ROB 160 的乱序核（`Parameters.scala:81-82,115`） |
| 取指流水 | **F0 → F1**，2 级 | **IFU S0/S1/S2 + WB**；另有 **BPU S0–S3** 与 **ICache Prefetch/Main** |
| 取指块 | **16 B / 4 slot** | **64 B / 32 个 2B slot**；支持 **2-fetch** |
| 每拍交付 | F1 最多 4 条进 IBUF；模块出队 3 条；**miniRV 实际消费 1 条，A910 消费 3 条** | IBuffer 入队宽度 36（默认）；decode 8；ICache 每拍最多 2 个 block |
| 队列 | IBUF 8 项（4 写 / 3 读，含旁路） | IBuffer 48 项；**FTQ 64 项**（Minimal 8） |
| ICache | 默认 **1 KB、2-way、16 B 行** | **64 KB、4-way、64 B 行**；2 个 fetch port + prefetch/MSHR |
| 分支预测位置 | **在取指环里**：F0 查表、F1 用结果 | **独立 4 级 BPU**，通过 FTQ 与取指解耦，可领先 32 个 block |
| 方向预测 | 默认 **gshare**（512 行 × 4 slot × 2 bit，GHR 8）；可选 **TAGE**（T0 + 4 表，64 行，历史 2/5/9/14，GHR 16） | **TAGE 8 表 × 4096 项**（历史 4…397）+ **SC** 8 表 + uTAGE/ABTB/uBTB |
| 目标预测 | 块 BTB 64 行 × 4 slot，所有 CFI 共用；RAS 8 项默认关 | uBTB + ABTB + MBTB + VBTB + **ITTAGE** + RAS/uRAS |
| 预测器面积 | 8,920 bit（gshare）/ 13,008 bit（TAGE） | 数量级更大（仅 TAGE 就是 8 × 4096 × 2 way × 4 bank） |
| 误预测代价 | IFU2 文档在 **miniRV（1 lane）** 实测约 1.07 拍/次；A910（乱序、3 lane）未做同类周期账 | 乱序深流水，代价远大于 2 级顺序核；本仓库未测具体值 |
| 关键设计取舍 | **延迟优先**：预测器必须塞进 F1 环，宁可牺牲准确率/面积换 Fmax | **准确率优先**：预测流水化 + FTQ 解耦，用面积/复杂度换准确率 |

一句话：**IFU2 是“取指环 = 预测环”的紧耦合小前端；香山是“预测流水 + FTQ 解耦”的大前端。** 两者的 TAGE 都按取指块起始 PC 索引，但 IFU2 把块内位置做成行内 4 个固定 slot，香山把位置 XOR 进 tag 并由 MBTB 枚举分支位置；IFU2 的 TAGE 在 F1 组合环里，香山的 TAGE 在独立 4 级 BPU 里。

---

## 1. 设计目标不同，数字不能直接比

### 1.1 IFU2 的约束

> **先分清两个集成场景**：IFU2 是一个 3-lane 前端模块，但 `mycpu.v`（miniRV）只接 lane0、`idu_accept_num` 恒 0/1（`mycpu.v:409-460`）；`A910_cpu.sv` 把 3 个 lane 全部接上（`A910_cpu.sv:848-870`），核是乱序。下面的 1.07 拍/0.31% 周期账来自 **miniRV**，不能直接套到 A910。

- miniRV：2 级流水、1 条/拍消费、顺序核；IFU 的直接职责很小。IFU2 文档的 CoreMark 周期账（`ifu2_zh.md` §“周期账”）：
  - 总 11,421,985 拍，退休 9,233,680 条，IPC 0.808；
  - 核内停顿 13.34%，误预测冲刷 2.76%，**IFU 没货只有 0.31%**；
  - **每次误预测约 1.07 拍**（1 拍冲刷 + 0.068 拍重填）。
- 因此 **miniRV 场景**下 IFU2 的核心指标是 **Fmax + 少量面积**，不是“预测准确率最大化”。这也解释了为什么 2026-09-29 把默认方向预测器从 TAGE 切回 gshare：TAGE 的 4~5 级组合在 F1 环里，Fmax 从 183.9 MHz 掉到 161.9 MHz（−13.6%）。
  - **A910 场景不同**：A910 是乱序核、消费 3 lane，误预测代价远大于 miniRV 的 1.07 拍；同一份 IFU2/TAGE 在 A910 上的准确率收益会更大。但 A910 的构建默认不挂 `BP_DEFS`（Makefile 里 A910 规则用 `VCS_FLAGS_EXTRA`），因此默认仍是 gshare；要用 TAGE 需要显式 `+define+BP_PRED=1`（见 §8.1）。
  - 在 **Fmax 对比那组镜像**（`make` 注释里的 w4 树）里，TAGE 的 CoreMark 周期是 11,270,384，gshare 是 11,611,077（TAGE 少 3.02%）；净吞吐 `1.136 / 1.030 ≈ +10.3%` 仍是 gshare 高（`Makefile:468-486`）。
  - 在 **§4.2 那组基线镜像**里，TAGE 只省 0.67% 周期（11,285,969 vs 11,362,153）。两组数字不要混用：差异主要来自 W2.4 把查表 GHR 改成寄存的 `ghr_q`（滞后一块），gshare 只有 8 位历史，相对损失更大。

### 1.2 香山的约束

- RV64、8-wide decode/rename、ROB 160 的乱序核；误预测要冲刷并重填远比 2 级顺序核更长的流水，**准确率的收益被流水深度放大**。
- 因此香山愿意为 TAGE/SC/ITTAGE/RAS 付出大得多的面积，并把预测拆成 4 级、用 FTQ 解耦，让长历史查表不进入取指环。

> **结论**：拿 IFU2 的“TAGE 只省 0.67% CoreMark”去评价香山的 TAGE 是不公平的；IFU2 的文档自己也写了：“这套收益该和乱序一起做——乱序把每次误预测的代价从 1.07 拍放大到约 10 拍，同样的准确率增益才值钱。”（`ifu2_zh.md` §4）

---

## 2. 流水与取指带宽

### 2.1 IFU2：2 级、单 PC 寄存器、逐 lane 交付

```
F0  next_pc ─┬─→ i-cache 阵列寻址（同步读）
             ├─→ 块 BTB（同步读）
             └─→ 方向表（gshare 或 TAGE，同步读）
                    │
F1  q_pc/q_data ─→ tag 比较 → 对齐 ≤4 条 → 截断于第一个预测 taken → IBUF
     q_hit / slot_vld / slot_taken ─┘
```

代码事实（`rv32ifu2_top.v`）：

- **全设计只有一份 PC 寄存器**，在 `u_icache` 内部（`q_pc_q`）；顶层组合计算 `next_pc` 喂阵列（`:334-347`）。
- `MAX_ISSUE = 4`：F1 一拍最多把整个 16 B 块的 4 条都推进 IBUF（`:285-289`）。模块出队仍是 3 条（`:663`）；**miniRV 只消费 lane0，A910 消费 3 条**（见 §1.1）。
- `push_mask` 由三条前缀条件取交集：本块剩余、第一个预测 taken、IBUF 空位（`:640-660`）。
- IBUF 深度 8，4 写 / 3 读，空队列旁路（`rv32ifu2_ibuf.v:1-20`）。
- 重定向：RTU（提交点）当拍进 `next_pc`；IU（EX）默认经 `REDIRECT_PIPE=1` 打一拍（`Makefile:488-500`、`rv32ifu2_top.v:290-330`）。`next_pc = redirect ? redirect_pc : reached_taken ? taken_tgt : q_pc + adv`（`:1056-1068`）。
- 没有 FTQ、没有取指包、没有 way 预测；F1 逐 lane 有效，参差由 IBUF 吸收。

### 2.2 香山：IFU 3 级 + WB，BPU 4 级，FTQ 解耦

- IFU 本体：S0（边界/压缩）→ S1（半字拼接/PC/预译码/IBuffer 对齐）→ S2（RVC 展开/PredChecker stage 1/入 IBuffer）；WB（PredChecker stage 2 → `wbRedirect`）。详见 `doc/xiangshan_ifu_bpu_zh.md`。
- BPU：S0（uBTB/ABTB/TAGE/SC/uTAGE 读）→ S1（uBTB/ABTB/uTAGE/uRAS，写 FTQ）→ S2（MBTB + TAGE fast，`s2_override`）→ S3（完整 TAGE + SC + ITTAGE + RAS，`s3_override`）。
- FTQ 缓存预测块，BPU 可以领先取指 `distance(bpuPtr, fetchPtr) < PrefetchDepth = 32`（`Ftq.scala:180-186`）；ICache PrefetchPipe 与 MainPipe 之间还有深度 32 的 WayLookup。

### 2.3 带宽/延迟对比

| 项 | IFU2 | 香山 |
|---|---|---|
| 取指块 | 16 B / 4 slot | 64 B / 32 个 2B slot |
| 每拍取指 | 1 个 16 B 块；最多推 4 条 | 最多 2 个 block（2-fetch）；IFU 可接收 1–2 个 block |
| 交付/消费 | IBUF 4 写 / 3 读 | IBuffer 入队宽度 36；decode 8 |
| 预测延迟 | F0 查表、F1 结果；**在取指环内** | BPU 4 级；S1 写入 FTQ，S2/S3 只做 override |
| 重定向进 PC | RTU 0 拍；IU 默认 1 拍 | FTQ redirect；IFU wbRedirect 4 拍（FTQ 再打一拍） |
| 关键路径 | `q_idx → 表读 → 预测 → taken/目标 → next_pc → 哈希 → q_idx`（IFU2 文档称 TAGE 的 4~5 级全在这条环里） | 预测延迟被 FTQ 吸收，取指环只看 FTQ entry |

**这是两者最根本的差别**：IFU2 的预测器是取指环的一部分，任何预测器逻辑都会直接变成 Fmax 的代价；香山的预测器在独立流水里，长历史 TAGE 不进入 IFU 的取指环。

---

## 3. 分支预测总体对比

| 功能 | IFU2（当前代码） | 香山（当前代码） |
|---|---|---|
| 快速目标 | 块 BTB：64 行 × 4 slot；每 slot 16 bit = `{valid, is_cond, target[15:2]}`；所有 CFI 共用 | uBTB 32 项全相联（always-taken）+ ABTB 1024 项（4 bank × 4 way，最多 4 候选）+ MBTB 8192 项（4 way、4 internal bank、2 align bank、VBTB） |
| 方向 | 默认 gshare：512 行 × 4 slot × 2 bit ≈ 4,096 bit（文档计 4,104）；GHR 8；`idx = pc[12:4] ^ fold(GHR)` | TAGE 8 表 × 4096 项 × 2 way × 4 bank（历史 4/9/17/29/56/109/211/397）；uTAGE 2 表 × 512（5/9）做 S1 修正；SC 8 表（path/global/BW/IMLI/bias） |
| 间接跳转 | 无 ITTAGE；BTB 对 JAL/JALR 都存目标（`SLOT_W=16` 的 target 字段）；RAS 只处理 return | ITTAGE 5 表（256/256/512/512/512，历史 4/8/13/16/32）+ 16 项 Region 目标缓存 |
| 返回 | RAS 8 项，`RAS_EN=0` **默认关** | RAS commit 16 / spec 32 + uRAS；S1 给出 return target，S3 用 RAS 栈顶 |
| 每块控制转移 | 只预测**第一个 taken**；块内后续分支靠 EX 重定向兜底 | 也只预测**第一个 taken**，但 MBTB 给 10 个候选（2 align bank × (4 way + VBTB)），TAGE 逐位置给方向 |
| 历史 | GHR：gshare 默认 8 位，TAGE 16 位；**只记录条件分支方向**；无 PHR/CommonHR | PHR 默认 532 位（397 + 2×64 + 4，对齐 4，**所有 taken CFI**）+ CommonHR（条件分支 GHR/BW/IMLI） |
| 训练 | **退休点** `rtu_train_*`：BTB 收所有 CFI，方向表只收条件分支；TAGE 额外带 1 位 `upd_fpred` | 后端 resolve（FTQ 只保留到第一个 mispredict）+ IFU 提前 resolve + S3 fast-train + RAS commit |
| 历史恢复 | 误预测时用 chk 里的 GHR 快照近似恢复；陷阱时 GHR 清零 | FTQ 每个 entry 保存 PHR/CommonHR/RAS meta，redirect 时恢复 |
| 面积 | 8,920 bit（gshare）/ 13,008 bit（TAGE）——IFU2 文档口径 | 数量级更大（仅 TAGE 8×4096×2×4 项） |
| 时序位置 | 在 F1 取指环里；TAGE 让 Fmax 从 183.9 → 161.9 MHz | 在独立 BPU S0–S3 里；不与 IFU 取指环闭合 |

### 3.1 IFU2 的预测器细节（代码）

- **块 BTB**（`rv32ifu2_btb.v`）：
  - 64 行 × 4 slot（默认 `BTB_ROW_AW=6`，`rv32ifu2_top.v:156-160`）；
  - 每行 `ROW_W = 4 × 16 = 64` bit；行标签 `TAG_BITS = 15 - (6+4) + 1 = 6`，加 1 位行 valid（`:44-70`）；
  - 每 slot 只存 `{valid, is_cond, target[15:2]}`，**不存方向**（方向是方向表的活，`:67-70`）；
  - 目标只有 14 位，绑定 64 KB 地址空间（`TAG_HI=15`）。
- **gshare**（`rv32ifu2_bht.v`）：
  - 512 行 × 4 slot × 2 bit（`BHT_ROW_AW=9`，`GHR_W=8`，`rv32ifu2_top.v:161-171`）；
  - 读写共用同一个索引公式；GHR 快照随指令走（`chk`）。
- **TAGE**（`rv32ifu2_tage.v`，`BP_PRED=1` 时）：
  - T0：64 行 × 4 slot × 2 位饱和计数器，必定命中；
  - T1–T4：64 行 × 4 slot；每 slot `{valid, pred[2:0], u[1:0]}`；每行 `{row_valid, tag[5:0]}`；
  - 历史长度 2/5/9/14，GHR 16，tag 6；
  - `index_i = pc[ROW_AW+3:4] ^ fold(ghr, L_i, ROW_AW)`；
  - `tag_i = pc[TAG_HI:ROW_AW+4] ^ rotl(fold(ghr, L_i, TAG_W), i mod TAG_W)`；
  - provider = 命中表里历史最长者；altpred = 次长命中；
  - 静态：`fpred = provider 强信心 ? provider : altpred`；动态 USE_SEL（64 × 4 位有符号计数器，按 PC 索引）在弱信心时决定选谁；
  - 训练：退休点重算索引/tag，只从 chk 带 1 位 `upd_fpred`；TAGE 头注释仍写“EX 重算”，但当前 `top.v` 的 `upd_*` 接的是 `rtu_train_*`（见 §10）。
- **RAS**（`rv32ifu2_ras.v`）：8 项（`RAS_AW=3`），默认 `RAS_EN=0`；只在 `push_lane/pop_lane` 且 `RAS_EN` 时工作（`rv32ifu2_top.v:900-930`）。
- **训练源（当前代码）**：
  - `rtu_train_vld/pc/target/taken/is_cond/is_jal/is_jalr` 来自退休点（`rv32ifu2_top.v:236-260`）；
  - BTB：`upd_*` 全部接 `rtu_train_*`（`:429-445`）；
  - BHT/TAGE：`upd_vld = rtu_train_vld & rtu_train_is_cond`（`:962-966, 996-1005`）；
  - `iu_btb_chk/taken/is_cond` **不再训练**，只用于重定向当拍的 `ghr_restore` 和 RAS 快照（`:754-770, 920-930`）。

### 3.2 香山的预测器细节

已在 `doc/xiangshan_ifu_bpu_zh.md` 中详细展开，这里只强调与 IFU2 对比相关的点：

- **多级**：S1 的 uBTB/ABTB/uTAGE/uRAS 先给一版；S2 的 MBTB + TAGE fast 修正；S3 的完整 TAGE + SC + ITTAGE + RAS 最终修正。
- **多候选**：MBTB 返回 10 个候选分支；TAGE 按 MBTB 给出的 position 逐候选算 tag/方向（`Tage.scala:96-98`、`Helpers.scala:65-66`）。
- **长历史**：TAGE 8 表，历史 4…397；PHR 默认 532 位；SC 另有 8 张统计表。
- **训练**：FTQ 的 `metaQueueResolve` 保存 MBTB/TAGE/SC/ITTAGE/PHR/CommonHR/uTAGE 信息；后端 resolve + IFU 提前 resolve + S3 fast-train + RAS commit；只训练到第一个 mispredict（含）。
- **恢复**：FTQ entry 的 `BpuRedirectMeta` 保存 PHR/CommonHR/RAS，redirect 时恢复。

---

## 4. TAGE 深对比（重点）

两者都按**取指块起始 PC**索引，而不是按分支 PC 索引；这是 2 级/早期预测的共同要求。但块内位置的表示方式不同，导致容量、关联度和面积效率不同。

| 维度 | IFU2 TAGE | 香山 TAGE |
|---|---|---|
| 索引基 | 16 B 块 PC（`pc[ROW_AW+3:4]`） | 64 B 块 `startPc`（`getSetIndex(startPc, hist)`） |
| 块内位置 | **行内 4 个固定 slot**，每个 slot 独立 pred/u | **位置 XOR 进 tag**（`getTag(..., position)`）；位置由 MBTB 的候选给出 |
| 每表几何 | 64 行 × 4 slot；1-way（无组相联） | 4096 项 = 512 set × 2 way × 4 bank；每组 2 way |
| base/T0 | **独立的 T0 表**：64 行 × 4 slot × 2 位饱和计数器，必定命中 | **没有独立 T0 表**：用 MBTB 表项的 2 位 taken counter 作为 base（`Tage.scala:215-223, 396`） |
| 表数/历史 | T0 + 4 张 tagged 表；历史 2/5/9/14；GHR 16 | 8 张 tagged 表；历史 4/9/17/29/56/109/211/397；PHR 默认 532 位 |
| 历史语义 | GHR **只记录条件分支**的方向（`lane_cond`，`rv32ifu2_top.v:720-745`） | TAGE 用 **PHR（所有 taken CFI 的路径历史）**；SC 才用 CommonHR 的条件分支 GHR/BW/IMLI（`Bpu.scala:573-575, 601`） |
| 计数器 | pred 3 位、u 2 位 | pred 3 位、u 2 位；另有 USE_ALT_ON_NA |
| tag | 6 位 | 13 位 |
| alt/use | provider/alt 静态 + 动态 USE_SEL（64×4） | provider/alt + USE_ALT_ON_NA + useful 老化 |
| 读出流水 | F0 index、F1 结果（组合 tag 比较/优先级/mux） | S0 读表、S1 算 tag、S2 fast 方向、S3 完整预测 |
| 训练 | 退休点重算，带 1 位 `upd_fpred` | FTQ resolve meta + fast train；带 provider/way/ctr 等 meta |
| 额外方向预测 | 无 SC | SC 8 表（path/global/BW/IMLI/bias），S3 与 TAGE 竞争 |
| 面积 | 8,464 bit（文档口径） | 仅 TAGE 就 8 × 4096 × 2 way × 4 bank，数量级更大 |
| 时序 | 在 F1 环里，TAGE 让 Fmax −13.6% | 在独立 BPU 流水里，不闭合取指环 |

### 4.1 为什么 IFU2 用“行内 4 slot”，香山用“position 进 tag”

- **IFU2**：2 级流水要求 F1 就给出整块 4 个 slot 的方向；把 4 个 slot 放在同一行，一次读就拿全。代价：
  - 一行只有 4 个固定 slot；在 **miniRV（1 条/拍）** 上 slot 维度大量闲置（IFU2 文档写了“一行 4 个 slot 多数时候只用得上 1 个”）；A910 可消费 3 条，slot 利用率会高一些，但块内分支仍受 4 slot 上限约束；
  - 表是 1-way，冲突只能靠容量；
  - 块索引在同面积下比“每条分支一个表项”贵约 2.5×（IFU2 文档引用的 C++ 模型结论）；
  - 块内第二条分支方向错了只能靠 EX 重定向兜底。
- **香山**：TAGE 的 set index 用块 startPc + 折叠历史；tag 里 XOR 进 position。MBTB 先给出块内所有候选 position，TAGE 对每个 position 算一次 tag，因此：
  - 不限制块内分支数为 4；
  - 2-way + 4 bank 提供关联，减少冲突；
  - 代价是要先有 MBTB 的 position，所以 TAGE 最早在 S1 才能算 tag、S2 出 fast 方向，S3 才完整。

### 4.2 准确率/收益对比（只列 IFU2 实测，香山无本地跑分）

IFU2 文档的同镜像实测（`ifu2_zh.md` §4）：

| | gshare（默认） | TAGE |
|---|---:|---:|
| branch_bench 周期 | 161,496 | **159,722（−1.10%）** |
| 总方向准确率 | 95.02% | **96.57%** |
| 类 3 交替 T/N | 87.20% | **93.38%** |
| 类 5 T,T,T,N | 83.81% | **96.28%** |
| 条件分支误预测 | 2,851 | **1,965（−31%）** |
| CoreMark 周期 | 11,362,153 | **11,285,969（−0.67%）** |
| 方向表面积 | 4,104 bit | 8,464 bit |
| 整机预测器面积 | 8,920 bit | 13,008 bit |
| Fmax（TAGE 默认几何） | 183.9 MHz | 161.9 MHz |

- IFU2 的结论（**miniRV 场景**）：TAGE 的方向收益是真的（条件分支误预测 −31%），但 CoreMark 只有 −0.67%；而 Fmax −13.6%，净吞吐反而是 gshare 高约 10.3%。所以 miniRV 默认切回 gshare。
- **A910 场景需要单独判断**：A910 是乱序核、3 lane，误预测代价远大于 miniRV；TAGE 的准确率收益可能超过 Fmax 损失。但 A910 构建默认不挂 `BP_DEFS`，现在的 A910 实际仍是 gshare；要测 TAGE 需显式传 `+define+BP_PRED=1`（见 §8.1）。
- 香山没有本地跑分，不比较准确率数字；从结构上看，香山的 TAGE 历史长得多（最长 397 vs 14），且额外有 SC/ITTAGE/RAS/uRAS，面向的是误预测代价更高的乱序核。

### 4.3 训练与恢复的差异

| | IFU2 | 香山 |
|---|---|---|
| 训练时机 | 退休点（`rtu_train_*`） | 后端 resolve（可能早于退休）+ IFU 提前 resolve + S3 fast-train + RAS commit |
| 条件分支训练 | 方向表只收 `rtu_train_is_cond` | TAGE/SC/ITTAGE/MBTB 按 resolve meta 训练；只到第一个 mispredict |
| TAGE 需要的预测时信息 | 只带 1 位 `upd_fpred`；其余用 `upd_pc + upd_ghr` 重算 | 带 provider/way/ctr/position 等 meta（存在 FTQ） |
| 历史快照 | `chk` 25 位，含 GHR/RAS/元信息；当前代码所有 lane 共用 `ghr_q_d1` 这一份块首快照 | 每个 FTQ entry 保存 PHR/CommonHR/RAS meta |
| 重定向恢复 | GHR 近似恢复（块首 + 真实方向）；陷阱清零 | 按 FTQ entry 的 meta 恢复；可精确到该分支之前 |

**为什么 IFU2 可以“重算”**：它的表小、训练在退休点、每条指令带着 `upd_pc + upd_ghr`，在训练口用和预测相同的索引/ tag 函数重算即可；代价是如果表在指令飞行期间被替换，重算可能落到“当前表”而不是“预测时的表”。IFU2 的取舍是：只带 1 位 `upd_fpred`，接受这一点点不精确，换取 chk 只有 25 位、训练逻辑简单。

> **在 A910 上要额外注意**：退休点比 resolve 更晚；OoO 下训练滞后更大，TAGE 的适应速度会受影响。香山在 resolve 就训练，并且 S3 还有 fast-train。IFU2 退休训练的设计理由是 OoO 分支乱序完成（`rv32ifu2_top.v:236-260` 的注释），但这也意味着 A910 上的 TAGE 收益需要实测确认，不能直接套 miniRV 的结论。

**香山为什么不能只重算**：TAGE 表大、飞行时间长、训练来自 resolve meta；它把预测时的 provider/way/ctr 等直接存进 FTQ，训练时按 meta 更新，避免“表已经变了”导致更新到错误表项。代价是 FTQ meta 很宽。

---

## 5. BTB/间接跳转/返回对比

| | IFU2 | 香山 |
|---|---|---|
| 一级 BTB | 块 BTB 64 行 × 4 slot；所有 CFI 共用；slot 16 bit | uBTB 32 项全相联（always-taken）；ABTB 1024 项（4 bank × 4 way，最多 4 候选） |
| 主 BTB | 无独立主 BTB | MBTB 8192 项（4 way、4 internal bank、2 align bank）+ VBTB 32 项 |
| 间接目标 | BTB 里 JAL/JALR 都存目标（target[15:2]） | ITTAGE 5 表 + 16 项 Region 目标缓存 |
| 返回 | RAS 8 项，默认关 | RAS commit 16 / spec 32 + uRAS（S1 就给 return target） |
| 多分支 | 只预测第一个 taken；块内后续分支不预测 | MBTB 给 10 个候选；TAGE 逐位置给方向；仍只取第一个 taken |
| 目标宽度 | 14 位（64 KB 地址空间） | MBTB tag 16/target 20；ABTB tag 24/target 22；uBTB tag22/target22 |
| 训练 | BTB 退休点收所有 CFI；JAL/JALR 目标也学 | MBTB/ABTB/uBTB 由 resolve/fast-train 训练；ITTAGE/RAS 各自训练 |

对 IFU2 来说，**BTB 存 Jalr 目标**已经覆盖了大部分间接跳转；ITTAGE 的价值取决于 jalr 的目标是否“同一个 BTB 行记不住”（多目标）。IFU2 文档的 RAS 实测显示：RAS 对 jalr 密集的 branch_bench 是大赢（jal/jalr 误预测 2,056 → 12），但对 CoreMark 略亏（+0.25%），所以默认关。香山则把 RAS/uRAS 作为常开部件，因为它的调用深度和乱序窗口更大。

---

## 6. ICache/存储子系统对比

| | IFU2 | 香山 |
|---|---|---|
| 容量/相联 | 默认 1 KB、2-way（`ICACHE_BYTES=1024`、`IC_WAYS=2`） | 64 KB、4-way（256 set × 64 B） |
| 行大小 | 16 B | 64 B |
| 阵列 | 真实 RAM：每路 tag 24 位、data 128 位；1R1W；读口写穿透 | SRAM；2 个 fetch port；WayLookup + MainPipe；meta/data 分离 |
| 命中路径 | 两路并行读 + tag 比较后 mux；**无 way 预测/重发** | WayLookup 提供 waymask；MainPipe S0 读 data、S1 选路/ECC/PMP → IFU |
| 预取 | **无** | PrefetchPipe + 深度 32 的 WayLookup；2-prefetch；MSHR 4 fetch + 10 prefetch |
| 回填 | 简单 refill FSM + BIU AXI；写穿透 | MSHR + L2；ECC/parity；支持 2-fetch/2-prefetch |
| 一致性 | fence.i 等由核处理 | fence.i、satp flush、ITLB/PMP、异常等完整路径 |

IFU2 的实测（`ifu2_zh.md`）：1 KB 与 64 KB 的 CoreMark 只差 0.3%（2.634 vs 2.642），说明它的工作集对容量不敏感；因此它没有做预取/大容量。香山面向更大的工作集和更高的取指带宽，64 KB + 预取 + 2-fetch 是必要的。

---

## 7. 面积、时序、性能：两种“划算”

### 7.1 IFU2 的账（仓库内实测）

- 预测器面积：gshare 8,920 bit / TAGE 13,008 bit（`ifu2_zh.md` §4）。
- Fmax：gshare 183.9 MHz（5.6 ns）/ TAGE 161.9 MHz（6.2 ns）（`Makefile:468-486`）。
- CoreMark 周期：**§4.2 基线镜像** gshare 11,362,153 / TAGE 11,285,969（TAGE −0.67%）；**Fmax 实验镜像** gshare 11,611,077 / TAGE 11,270,384（TAGE −3.02%）。两组不能混用，见 §1.1。IFU2 文档另记 GCC 14.2 基线 score 2.694，本文不把它与香山比较。
- branch_bench：gshare 161,496 拍 / TAGE 159,722 拍（−1.10%）；方向准确率 95.02% → 96.57%。
- 周期账（**miniRV，1 lane**）：误预测只占 2.76%，IFU 没货 0.31%；**每次误预测约 1.07 拍**。
- 结论：**在 miniRV 这个 1-lane、2 级顺序前端上，预测器准确率的边际收益很小；Fmax 才是主杠杆。** 所以 miniRV 默认 gshare，TAGE 是“精度臂”。A910 的乱序核不适用这组周期账，需要单独跑 TAGE/gshare A/B。

### 7.2 香山的账

- 香山侧本仓库没有跑分；只能从结构上说：TAGE/SC/ITTAGE 的面积是 IFU2 的几十倍到上百倍，BPU 4 级 + FTQ 也很贵。
- 它换到的是：长历史（397）、多级修正（S1/S2/S3）、多候选（10 个 MBTB 候选）、间接目标（ITTAGE）、统计相关器（SC）、更精确的历史恢复（FTQ meta）。
- 在乱序深流水里，一次误预测的代价远大于 1.07 拍；同样的准确率增益会被放大很多倍。这是香山愿意付这些面积的根本原因。

> **所以不能用“IFU2 TAGE 只省 0.67%”去证明“TAGE 没用”**；也不能用“香山有 8 表 TAGE”去要求 IFU2 也上 8 表。两者的最优解由“误预测代价 × 取指环时序预算”决定。

---

## 8. 互相可以借鉴什么

### 8.1 IFU2 可以向香山借鉴（按优先级）

1. **先在 A910 上做 TAGE vs gshare 的 A/B**：A910 是乱序核、3 lane，误预测代价远大于 miniRV；miniRV 上“TAGE 净亏”的结论不能直接搬。注意 A910 构建默认不挂 `BP_DEFS`，现在的 A910 实际是 gshare；要测 TAGE 需显式传 `+define+BP_PRED=1`（A910 规则用 `VCS_FLAGS_EXTRA`，见 Makefile 的 A910 段）。
2. **间接目标预测（ITTAGE 或类似）**：如果未来 jalr 密集、且 BTB 的多目标冲突明显，可以加一个小 ITTAGE/目标缓存；但 IFU2 当前 BTB 已存 jalr 目标，先量“jalr 目标冲突率”再决定。
3. **更精确的历史恢复**：当前 IFU2 的 GHR 恢复是近似的（块首 + 真实方向），陷阱清零；在 A910 这种乱序场景下，可以学香山把 PHR/CommonHR/RAS 快照存进队列，做精确恢复。
4. **uRAS/RAS 默认开**：如果工作负载 call/ret 密集，RAS 对 jalr 误预测的收益很大（branch_bench 2,056 → 12）；但 IFU2 的 CoreMark 实测略亏，需按工作负载决定。
5. **FTQ + 预测流水**：如果未来要做更深流水/更大预测器，把预测从取指环里拿出来，是香山这套大预测器的前提；但在 2 级前端上不划算。
6. **预取/2-fetch**：如果工作集/取指带宽变大再考虑；IFU2 目前 1 KB→64 KB 只差 0.3%，没有证据支持现在加。

### 8.2 香山可以向 IFU2 借鉴（思路层面）

1. **块索引的小 TAGE**：在 2 级/紧耦合前端里，块索引 + 行内 slot 是让预测在 F1 就绪的有效办法；香山虽然用 position 进 tag，但“按块索引”的思想相同。
2. **ragged 交付 + IBUF 吸收抖动**：IFU2 取消“取指包”，逐 lane 有效，省掉 fragment/prefix/PCFIFO 一套状态机；香山用 IBuffer 也做了类似的吸收，但前端仍有 2-fetch/对齐逻辑。
3. **小缓存的简化**：1R1W + 写穿透、两路并行读、不做 way 预测；香山 64 KB 需要 way 预测/WayLookup，不能直接照搬，但“先证明容量不敏感再加复杂度”的方法论值得借鉴。
4. **一份 PC 寄存器**：IFU2 把 PC 放在 ICache 里，顶层只算 next_pc，避免重复取指；香山的 FTQ/ICache 结构不同，但“PC 与数据天然对齐”的思想仍适用。

---

## 9. 代码索引

### IFU2

| 主题 | 文件 |
|---|---|
| 顶层、PC、F0/F1、IBUF、GHR、重定向 | `mySoC/ifu2/rtl/rv32ifu2_top.v` |
| TAGE | `mySoC/ifu2/rtl/rv32ifu2_tage.v` |
| gshare | `mySoC/ifu2/rtl/rv32ifu2_bht.v` |
| 块 BTB | `mySoC/ifu2/rtl/rv32ifu2_btb.v` |
| RAS | `mySoC/ifu2/rtl/rv32ifu2_ras.v` |
| ICache | `mySoC/ifu2/rtl/rv32ifu2_icache.v`、`rv32ifu2_spram.v` |
| IBUF | `mySoC/ifu2/rtl/rv32ifu2_ibuf.v` |
| Refill/BIU | `mySoC/ifu2/rtl/rv32ifu2_refill.v`、`ifu_biu_axi.v` |
| 设计文档 | `mySoC/ifu2/doc/ifu2_zh.md` |
| 参数 | `Makefile`（IFU2 段：ICACHE_BYTES/BP_PRED/BP_TAGE_*/BP_RAS/REDIRECT_PIPE） |

### 香山

| 主题 | 文件 |
|---|---|
| IFU | `frontend/ifu/Ifu.scala`、`InstrBoundary.scala`、`PredChecker.scala` |
| BPU | `frontend/bpu/Bpu.scala` |
| TAGE | `frontend/bpu/tage/Tage.scala`、`TageTable.scala`、`Helpers.scala` |
| SC | `frontend/bpu/sc/Sc.scala` |
| ITTAGE | `frontend/bpu/ittage/Ittage.scala`、`RegionWays.scala` |
| BTB | `frontend/bpu/ubtb/MicroBtb.scala`、`abtb/AheadBtb.scala`、`mbtb/MainBtb.scala` |
| RAS | `frontend/bpu/ras/Ras.scala`、`MicroRas.scala` |
| PHR/CommonHR | `frontend/bpu/history/phr/Phr.scala`、`history/commonhr/CommonHR.scala` |
| FTQ | `frontend/ftq/Ftq.scala`、`ResolveQueue.scala` |
| ICache | `frontend/icache/ICachePrefetchPipe.scala`、`ICacheMainPipe.scala`、`ICacheWayLookup.scala` |
| 参数 | `frontend/FrontendParameters.scala`、`top/Configs.scala`、`xiangshan/Parameters.scala` |

---

## 10. 口径纠正：IFU2 文档/RTL 注释与当前代码不一致的四处

以下是写本文时实际核对到的差异，**以当前 `rv32ifu2_top.v` 的连线为准**：

1. **训练时机**
   - `rv32ifu2_tage.v` 头注释、`ifu2_zh.md` §4 仍写“训练在 EX 重算 / 训练回送走 `iu_btb_*`”。
   - 当前 `rv32ifu2_top.v`：BTB 的 `upd_*` 接 `rtu_train_*`；BHT/TAGE 的 `upd_vld = rtu_train_vld & rtu_train_is_cond`（`:429-445, 962-1005`）。`iu_btb_chk/taken/is_cond` 只用于重定向当拍的 GHR 恢复和 RAS 快照。
   - 这是 2026-10-02 “阶段 4b” 之后的代码；文档/头注释未同步。
2. **GHR 快照**
   - `ifu2_zh.md` 的“两条必须更正的既有说法”说实际是“每条 lane 推进时自己的 GHR”。
   - 当前代码：`chk_snap` 对所有 lane 都用同一个 `ghr_q_d1`（块首 GHR 的延迟版）；每条 lane 只有 `CHK_BTBHIT/PREDTK/FPRED` 三位元信息不同（`rv32ifu2_top.v:840-870`）。
3. **块 BTB 面积**
   - `ifu2_zh.md` §4 的 bullet 写“数据 8,704 + 标签 1,472 = 10,176 bit”，那是 34 位/slot 的旧版。
   - 当前 `rv32ifu2_btb.v`：`SLOT_W=16`、`ROW_W=64`、`TAG_BITS=6`，64 行 ⇒ 数据 4,096 + 标签 448 ≈ 4,544 bit。文档后面“8,920 bit”的总面积表与当前实现一致，bullet 是旧数。
4. **默认方向预测器**
   - `rv32ifu2_top.v:57-60` 的头注释写“1 = TAGE ... **默认**，0 = gshare ... 旧默认”。
   - 当前实际默认是 **gshare**：Makefile `BP_PRED ?= 0`（`:486`），且 RTL 的 `ifdef` 兜底也是 `BP_PRED_MODE = 0`（`:62-66`）。Makefile 的注释（`:468-470`）明确写了 “0 = gshare, **默认**, 2026-09-29 起 —— 为 FPGA Fmax”。以 Makefile + RTL 兜底为准。

> 这四处不影响本文的主结论（2 级紧耦合 vs 4 级解耦；块索引 slot vs position 进 tag），但在引用 IFU2 文档的具体数字/训练描述时，应以 RTL 为准。

---

## 11. 一句话总结

**IFU2 用 2 级流水 + 块索引 BTB/gshare/TAGE，把预测器塞进取指环，用 8.9–13 Kbit 和 162–184 MHz 换一个 3-lane 前端（miniRV 只消费 1 lane，A910 消费 3 lane）的简单与高频；香山用 IFU 3 级 + BPU 4 级 + FTQ 解耦，用大得多的面积（TAGE 8 表、SC、ITTAGE、RAS/uRAS、PHR/CommonHR）换乱序深流水下的预测准确率。两者都按取指块起始 PC 索引 TAGE，但 IFU2 用行内 4 个固定 slot，香山把位置 XOR 进 tag 并由 MBTB 枚举位置。**
