# 香山处理器 IFU 流水线与分支预测微架构分析

> **分析对象**：`/x2025/GPrj1/IC1/riscv/RISCV_CPU/XiangShan`
> **代码版本**：`893e1580b`（`v3.2.2-alpha-2285-g893e1580b`，2026-10-16）
> **分析范围**：`src/main/scala/xiangshan/frontend/` 下的 BPU、FTQ、ICache、IFU、IBuffer
> **说明**：本文所有结论以该 commit 的 RTL 为准。代码中没有 F0–F3 的流水命名，本文不使用该命名（见 §7）。

---

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| **IFU 模块本体有几级流水？** | **3 级取指流水（S0 / S1 / S2）+ 1 级预测校验/写回（WB）** |
| 从 ICache 返回数据到指令写入 IBuffer | **3 拍**（S0 → S1 → S2） |
| 从 ICache 返回数据到 IFU 发出重定向 | **4 拍**（S0 → S1 → S2 → WB）；FTQ 再打一拍后全局生效 |
| 上游 ICache MainPipe | **2 级有效流水**（S0 读 data SRAM，S1 数据返回并送给 IFU）；另有 S2 只做 ECC/parity 检查（默认 parity） |
| 上游 ICache PrefetchPipe | 取指路径 2 级（S0 发 ITLB/meta 读，S1 收 meta、产生 waymask），后接深度 32 的 WayLookup 队列；另有 S2 负责向 missUnit 发预取请求/监控回填 |
| 分支预测 | **4 级（S0–S3）多级预测 + 逐级 override**：uBTB/uRAS → ABTB+uTAGE → MBTB+TAGE → SC/ITTAGE/RAS |
| 预测/取指带宽 | BPU 每拍产生 1 个 fetch block 的预测；ICache/IFU 每拍最多取 **2 个 fetch block**（2-fetch） |
| 前端解耦 | BPU 与取指之间由 **FTQ** 解耦；ICache prefetch 与 main pipe 之间由 **WayLookup** 解耦 |

一句话概括：**香山是“预测先行、逐级精化、预测与取指解耦”的前端**。BPU 用 4 拍完成一次由粗到细的预测，第一步（S1）就把预测写进 FTQ 让取指先跑起来，后面的 S2/S3 如果发现更好的结果就回写并冲刷下游。IFU 本身只负责“把 ICache 给的字节流变成正确的指令流”，只有 3 级，但它后面还有一级专门做预测校验和提前重定向。

### 0.1 关键结论的代码依据

| 结论 | 直接代码依据 |
|---|---|
| IFU 有 S0/S1/S2 三级 | `ifu/Ifu.scala:116`（stage 0 注释）、`:181`（stage 1）、`:388`（stage 2） |
| IFU 另有 WB 级 | `ifu/Ifu.scala:717`（IFU Write-back Stage 注释）、`:722-723`（`wbEnable`/`wbValid` 打拍） |
| IFU 流水长度按 3 计 | `ftq/Ftq.scala:162` 注释 “magic number 3 (the length of ifu pipeline)” |
| S0 做指令边界/压缩 | `ifu/Ifu.scala:137-178`、`ifu/InstrBoundary.scala:47-135`、`ifu/Helpers.scala:166-195` |
| S1 做 PC/预译码/IBuffer 对齐 | `ifu/Ifu.scala:281-386`、`ifu/Helpers.scala:197-209` |
| S2 做 RVC 展开/PredChecker/入 IBuffer | `ifu/Ifu.scala:424-533`、`ifu/PredChecker.scala:80-118` |
| WB 产生 `wbRedirect` | `ifu/Ifu.scala:722-756`、`ifu/PredChecker.scala:153-186`、`ftq/IfuRedirectReceiver.scala:61` |
| BPU 有 S0–S3 四级 | `bpu/Bpu.scala:109-153`（`s0_fire`/`s1_fire`/`s2_fire`/`s3_fire`） |
| S1 预测写 FTQ，S2/S3 override | `bpu/Bpu.scala:280-380`、`:509-519`；`ftq/Ftq.scala:183-222` |
| ICache Prefetch/Main 的级数与动作 | `icache/ICachePrefetchPipe.scala:73-130`（S0/S1）、`:429-470`（S2 预取请求）；`icache/ICacheMainPipe.scala:101-105, 434-470` |
| 预测器结构与大小 | `bpu/*/Parameters.scala`（uBTB/ABTB/uTAGE/MBTB/TAGE/SC/ITTAGE/RAS） |
| Default/Minimal 参数 | `top/Configs.scala:93-170`、`frontend/FrontendParameters.scala:28-33`、`ftq/FtqParameters.scala`、`ibuffer/IBufferParameters.scala`、`icache/ICacheParameters.scala` |

---

## 1. 前端总体结构

```
                        ┌─────────────────────────────────────────────┐
                        │                 BPU (S0–S3)                 │
                        │  uBTB / ABTB / uTAGE / MBTB / TAGE / SC /   │
                        │  ITTAGE / RAS / uRAS / PHR / CommonHR       │
                        └───────────────┬─────────────────────────────┘
                                        │ prediction {startPc, taken, target, cfiPos}
                                        │ meta / train / redirect
                                        ▼
                        ┌─────────────────────────────────────────────┐
                        │                    FTQ                      │
                        │  entryQueue + redirect/resolve/commit meta  │
                        │  bpuPtr / pfPtr / fetchPtr / commitPtr / pnr │
                        └───────┬─────────────────────────┬───────────┘
                                │ prefetch req            │ fetch req
                                ▼                         ▼
                ┌───────────────────────────┐   ┌───────────────────────────┐
                │  ICache PrefetchPipe      │   │   ICache MainPipe         │
                │  S0: ITLB + meta SRAM 读  │   │   S0: data SRAM 读        │
                │  S1: waymask 产生         │   │   S1: 选路/ECC/PMP → IFU  │
                └─────────────┬─────────────┘   │   S2: 仅 parity 检查      │
                              │                 └─────────────┬─────────────┘
                              ▼                               │ toIfu.req
                    ┌───────────────────┐                     ▼
                    │    WayLookup      │          ┌───────────────────────────┐
                    │  depth = 32       │          │          IFU              │
                    │  (prefetch 队列)  │          │  S0 → S1 → S2 → WB        │
                    └───────────────────┘          └─────────────┬─────────────┘
                                                                 │ enqueue
                                                                 ▼
                                                          ┌─────────────┐
                                                          │   IBuffer   │
                                                          └─────────────┘
```

关键连接（`Frontend.scala:224-265`）：

- `bpu.io.fromFtq / toFtq` ↔ `ftq.io.toBpu / fromBpu`
- `ftq.io.toICache` → `icache.io.fromFtq`；`icache.io.toIfu` → `ifu.io.fromICache`
- `ftq.io.toIfu` → IFU（backend redirect、BPU S2/S3 flush）
- `ifu.io.toFtq.wbRedirect` → FTQ（IFU 自己的提前重定向）
- `ifu.io.toIBuffer` → `ibuffer.io.in`

### 1.1 三个“S0/S1/S2”不要混淆

这份 RTL 里同时存在三套 S 编号：

| 单元 | 级数 | 命名 | 说明 |
|---|---|---|---|
| **BPU** | 4 | `s0`–`s3` | 预测流水，S2/S3 可以 override 前面的预测 |
| **ICache** | Prefetch 取指路径 2 级（另有 S2 预取请求）、Main 2+1 级 | `s0/s1`（Main 还有 `s2`） | MainPipe 的 s2 只做 ECC/parity，不参与数据通路；PrefetchPipe 的 s2 只负责 miss 请求 |
| **IFU** | 3 + WB | `s0/s1/s2`，外加 `wb` | 本文重点 |

所以问“IFU 有几级”时，**答案只针对 `frontend/ifu/Ifu.scala` 这个模块：3 级 + WB**；不要把 BPU 的 `s0–s3` 或 ICache 的 `s0/s1` 算进 IFU。

---

## 2. IFU 流水线：3 级 + WB

### 2.1 总览

IFU 的输入是 ICache MainPipe 的 S1 输出（**ICache S1 和 IFU S0 是同一拍**），输出是 IBuffer 的入队请求和 FTQ 的提前重定向。

```
ICache MainPipe S1 ──► IFU S0 ──► IFU S1 ──► IFU S2 ──► IBuffer
   (数据返回)            边界/压缩    拼接/PC/    展开/检查/
                                      预译码      入队
                                                    │
                                                    └──► IFU WB ──► FTQ (wbRedirect)
```

| 级 | 主要工作 | 关键源码 |
|---|---|---|
| **S0** | 接收 ICache 的 1–2 个 fetch block；**指令边界识别**（RVC/跨块 32 位指令/跨 fetch block）；指令压缩（compact）；计算 2-fetch 的总结束位置；检查 BPU S3 flush；计算推测指令数 | `Ifu.scala:115-179`、`InstrBoundary.scala:47-135` |
| **S1** | 打拍；合并 ICache parity 异常；**半条 RVI 指令拼接**；为每条指令生成 PC；按 IBuffer 写 bank **预对齐**；生成 predicted-taken / invalid-taken mask；**分支预译码**（BranchAttribute、跳转偏移）；维护 IBuffer 入队指针 | `Ifu.scala:180-386` |
| **S2** | **RVC 展开**（16→32，非法指令检测）；**预测检查 stage 1**（PredChecker）；按第一个预测错误截断 `enqEnable`；处理 uncache/MMIO 请求；前端 trigger；异常合成；组包 `FetchToIBuffer` 并写入 IBuffer | `Ifu.scala:387-714`、`PredChecker.scala:80-118` |
| **WB** | 预测检查 stage 2（打一拍）；产生 `wbRedirect` 给 FTQ（direct jump 未预测 taken、indirect/ret 未预测 taken、非 CFI 却预测 taken、invalid taken 等）；处理 uncache flush；恢复半字/IBuffer 指针状态 | `Ifu.scala:716-768`、`PredChecker.scala:153-186` |

> **注意**：S2 已经把指令写进 IBuffer 了；WB 不是“指令写回”，而是“预测校验/重定向”级。所以数据通路的有效级数是 3，而“一次预测错误从 IFU 发出 `wbRedirect`”的延迟是 4 拍；FTQ 的 `IfuRedirectReceiver` 还会对 redirect 打一拍（`IfuRedirectReceiver.scala:61`），因此全局生效是 5 拍。FTQ 里也有一句注释把 IFU 流水长度称为 3（`Ftq.scala:162` 的 magic number 3），指的就是 S0–S2 这 3 级。

### 2.2 S0：从字节流到指令边界

S0 的输入是 `io.fromICache.req`（`Ifu.scala:122-135`）：

- 每拍最多 2 个 fetch block（`FetchPorts = 2`），每个 block 带：
  - `startVAddr`、`data`（整条 cacheline 的数据）、`takenCfiOffset`（BPU 预测的 taken 位置）、`size`、`ftqIdx`
  - `icacheMeta`（异常、pmpMmio、pAddr、ITLB PBMT 等）
  - `maybeRvcMap`：以 2B 为槽位的“该槽位是否是 16 位指令”的位图
  - `firstRange/totalRange`：2-fetch 时两个 block 的有效范围

S0 做的事情（`Ifu.scala:137-178`、`InstrBoundary.scala`）：

1. **构造 FetchBlock**：把 ICache 的 `MainPipeToIfuReq.info` 转成 IFU 内部的 `FetchBlock`。
2. **指令边界识别**：
   - `InstrBoundary` 用 `maybeRvcMap` 递推每条指令的起始位置：
     `boundary(i) = !boundary(i-1) || maybeRvc(i-1)`（`InstrBoundary.scala:54-78`）。
   - 一个 64B block 有 32 个 2B 槽位；如果全是 RVC，就是 32 条 16 位指令。
   - 对 block 后半部分并行算两套边界（假设前半最后一条是 32 位 / 16 位），再根据实际 `maybeRvc` 选择，避免串行等待（`InstrBoundary.scala:68-78`）。
   - **跨 fetch block 的 32 位指令**：当 block0 的 fall-through 结束位置落在一条 32 位指令中间、而 block1 从这条指令的高半字开始时，标记 `isCrossBlockInstr`（`InstrBoundary.scala:84-114`）。
   - **半条 RVI（half RVI）**：32 位指令可能被 block 边界切成两半；S0 记录 `prevEndIsHalfRvi`，S1 负责拼接。
3. **指令压缩（compact）**：把带有空洞的 `rawInstrVec` 按 valid 排名压紧，去掉无效槽位（`Helpers.scala:166-195`）。压缩结果在 S0→S1 的寄存器边界打拍。
4. **2-fetch 结束位置**：`s0_totalEndPos` 在 block1 有效时等于 `block0.size + block1.takenCfiOffset`，否则等于 block0 的 taken offset（`Ifu.scala:139-143`）。
5. **BPU S3 flush 检查**：如果 BPU 在 S3 对本 block 做了 override，`s0_flushFromBpu` 会冲掉这个 block（`Ifu.scala:135`）。
6. **推测指令数**：`s0_instrCount` 是 S0 根据边界算出的推测值，用于提前判断 IBuffer 是否有空间；S1 可能因 ICache 异常/invalid-taken 修正它（`Ifu.scala:170-172`）。

### 2.3 S1：半字拼接、取指 PC、预译码、IBuffer 对齐

S1 是 IFU 里“信息最密集”的一级，主要工作都在 `Ifu.scala:180-386`。

1. **打拍并合并 ICache 异常**
   - ICache 的 ECC/parity 检查结果（`corrupt`）在 `req.fire` 之后一拍才到，正好在 S1 合并进 `icacheMeta`（`Ifu.scala:230-238`）。
   - 计算 `s1_exception`，并对 `instrCount` 做修正：异常时只保留到异常指令（`Ifu.scala:240-259`）。

2. **半条 RVI 指令拼接**
   - 如果上一条 fetch block 的最后一条指令是 32 位指令的低半字，`s1_prevEndHalfRviInfo` 会保存它的 PC 和低 16 位数据。
   - S1 用 `genBaseInstrData` 把上一条 block 的低 16 位和当前 block 的高 16 位拼成完整 32 位指令（`Ifu.scala:312-340`、`Helpers.scala:119-139`）。
   - 如果这条 32 位指令跨越两个 fetch block（`isCrossBlockInstr`），PC 取 `block1.startVAddr - 2`（`Helpers.scala:91-102`）。
   - 这套逻辑同时处理“预测 taken 落在 32 位指令中间”的情况：此时 `invalidTaken` 被置起，IFU 会在 WB 级用 `invalidTaken` 产生重定向，改用正确的顺序地址（见 §2.5）。

3. **生成每条指令的 PC**
   - `getInstrPc` 根据 `startOffset`、`blockSel`、`pcUpperBits` 生成 GuardedPc，并处理跨页进位（`Helpers.scala:84-102`）。
   - 同时生成 `foldpc`（PC 做 XOR fold 到 `MemPredPCWidth`），供 IBuffer/后端使用（`Ifu.scala:344-345`）。

4. **按 IBuffer 写 bank 预对齐**
   - IBuffer 每拍有 `NumWriteBank = 4` 个写 bank，写入必须按 bank 对齐。
   - S1 用上一条请求留下的 `prevIBufEnqPtr` 低 2 位作为 `alignShiftInstrNum`，把指令向量右移 0–3 个槽位，生成 `s1_alignedInstrVec` / `s1_alignedInstrValid`（`Ifu.scala:281-287`、`Helpers.scala:197-209`）。
   - 这会在向 IBuffer 的入队数据前部产生 0–3 个气泡；因此 `IBufferEnqueueWidth = FetchBlockInstNum + NumWriteBank`（默认 32 + 4 = 36）。
   - `s1_alignedInstrVec(IBufferEnqueueWidth - 1)` 被强制清 0，减少无用逻辑（`Ifu.scala:342`）。

5. **预测 taken mask 与 invalid taken mask**
   - `s1_predTakenMask` 根据 `takenCfiOffset` 和该 block 的有效指令数，定位预测 taken 的指令位置（`Ifu.scala:261-269`）。
   - 两个 block 的 mask 合并成 `s1_mergedPredTakenMask`。
   - 如果预测位置落在半条 RVI 中间（`s1_invalidTaken`），生成 `s1_invalidTakenMask`（`Ifu.scala:271-279`）。

6. **分支预译码**
   - 对每条有效指令做 `BranchAttribute.decode`：分支类型（None/Conditional/Direct/Indirect）和 RAS 动作（Push/Pop/PopAndPush）。
   - 同时计算 JAL/BR 的跳转偏移（`getJalOffset` / `getBrOffset`），生成 `PreDecodeInfo` 和 `jumpOffset`（`Ifu.scala:374-386`、`Helpers.scala:27-42`）。
   - 这些信息在 S2 送给 PredChecker，用来判断“预测 taken 是否合理、实际 CFI 的目标在哪里”。

7. **IBuffer 指针与 uncache 标记**
   - 维护 `s1_prevIBufEnqPtrDup`（instr/valid 两份），并在 redirect 时恢复到重定向点（`Ifu.scala:216-217, 361-369`）。
   - 如果 ICache 标记这条请求走 uncache（`isUncache`），S2 会走 MMIO/uncache 通道。

### 2.4 S2：展开、检查、入 IBuffer

S2 的工作在 `Ifu.scala:387-714`：

1. **RVC 展开**
   - `IBufferEnqueueWidth` 个 `RvcExpander` 并行工作，把 16 位指令展开成 32 位；非法编码通过 `io.ill` 标记（`Ifu.scala:424-437`）。

2. **预测检查 stage 1**
   - `PredChecker` 的输入是 S2 的指令向量、PC、预译码信息和跳转偏移（`Ifu.scala:510-515`）。
   - 它检查以下情况（`PredChecker.scala:82-98`）：
     - `jalFault`：存在 direct jump，但 BPU 没有预测 taken；
     - `jalrFault`：存在非 return 的 indirect branch，但没有预测 taken；
     - `retFault`：存在 return，但没有预测 taken；
     - `notCfiTaken`：BPU 预测 taken，但该指令不是 CFI；
     - `invalidTaken`：预测 taken 落在 32 位指令中间。
   - 用前缀 OR 找到**第一个错误位置**，把 `fixedInstrValid` 截断到该位置之前（包含错误指令本身），从而只把正确的指令前缀写入 IBuffer（`PredChecker.scala:99-113`）。
   - `stage1Out.fixedInstrValid` 直接作为 `io.toIBuffer.bits.enqEnable`（`Ifu.scala:532-533`）。

3. **写 IBuffer**
   - `io.toIBuffer` 打包：
     - `instrs`（展开后的 32 位指令）、`valid`、`enqEnable`、`isRvc`、`pc`
     - `instrEndOffset`（`predTaken` + `offset`）、`foldpc`
     - `isLastInFtqEntry`、`prevIBufEnqPtr`、`prevInstrCount`
     - `exceptionType`、`isBackendException`、`hasSatpFlush`、`exceptionCrossPage`、`exceptionMask`
     - `triggered`、`topdownInfo`
   - `s2_fire = io.toIBuffer.fire`；`s2_ready` 受 IBuffer ready 和 uncache 完成条件约束（`Ifu.scala:418-419, 508`）。

4. **uncache / MMIO**
   - 当 ICache 标记 `isUncache` 时，S2 不再把 ICache 数据当作普通指令，而是通过 `IfuUncacheUnit` 发请求（`Ifu.scala:444-486`）。
   - 支持跨页 uncache：如果一条非 RVC 指令跨页，`needResend` 会触发重发，并在完成后以 `uncacheRedirect` 更新 FTQ/IFU 状态（`Ifu.scala:706-715`）。
   - `uncacheFlushWb` 在 uncache 返回后向 FTQ 写回，表示该 block 已经处理完（`Ifu.scala:643-670`）。

5. **异常和 trigger**
   - ICache 异常（page fault、access fault、ECC）、RVC illegal、后端异常、satp flush 等在这里合成（`Ifu.scala:581-609`）。
   - 前端 trigger 根据 PC 和预译码信息产生 `triggered`（`Ifu.scala:520-527`）。
   - gpf 的 gpa 写入 `io.toBackend.gpAddrMem`（`Ifu.scala:631-640`）。

### 2.5 WB：预测校验与提前重定向

WB 由 `Ifu.scala:716-768` 和 `PredChecker.scala:153-186` 组成：

1. **打一拍**：`wbEnable = RegNext(s1_fire && !s1_flush) && !s2_useUncacheFetch && !s2_flush`，`wbValid = RegNext(wbEnable)`（`Ifu.scala:722-723`），所以 WB 在 S2 之后一拍。
2. **PredChecker stage 2**：
   - 对 S2 找到的第一个错误位置，计算修正后的目标：
     - 如果是 JAL/BR，目标 = 指令 PC + 指令立即数偏移；
     - 否则目标 = 顺序 PC（RVC 或 invalidTaken 时 +2，否则 +4）。
   - 生成 `checkerRedirect`：`valid`、`target`、`taken`、`attribute`、`blockSel`、`isCrossBlockInstr`、`invalidTaken`、`notCfiTaken`、`endOffset`、`mispredPc`（`PredChecker.scala:168-186`）。
3. **写回 FTQ**：
   - `toFtq.wbRedirect` 带上 `ftqIdx`、`pc`、`taken`、`ftqOffset`、`attribute`、`target`、`canTrain`（`Ifu.scala:736-756`）。
   - FTQ 收到后把它当作一次 redirect：冲刷 BPU/ICache/IFU，指向正确的 PC；如果 `canTrain` 为真，还会训练 BPU（例如 direct jump）。
4. **状态恢复**：
   - 重定向时清空/恢复 `s0_prevEndIsHalfRvi`、`s1_prevEndHalfRviInfo`、`s1_prevIBufEnqPtrDup`，保证下一条路径从正确的半字/IBuffer 位置开始（`Ifu.scala:160-168, 347-369`）。

> **PredChecker 只检查“方向/位置/是否 CFI”，不检查 direct jump 的绝对目标是否正确**。如果 BPU 预测 taken 且方向对、但 target 错了，IFU 不会在这里发现，要等后端解析；IFU 的重定向主要用于消除“该 taken 没 taken”“不该 taken 却 taken”“taken 落在半条指令中间”这类前端可见的错误。

### 2.6 IFU 的反压与冲刷

- **S0 反压**：`s0_fire = s0_valid && s1_ready && !s0_flush`；`s1_ready = s1_fire || !s1_valid`。
- **S1 反压**：`s1_fire = s1_valid && s2_ready`。
- **S2 反压**：`s2_ready` 需要 IBuffer ready；uncache 时还需要 uncache 响应可用。
- **冲刷来源**：
  - `backendRedirect`（来自 FTQ 的后端重定向）：冲刷 S0/S1/S2；
  - `wbRedirect`（IFU 自己的提前重定向）：冲刷 S0/S1；如果它对应的 block 已经不在 S2（`!s2_wbNotFlush`），也冲 S2；
  - `uncacheRedirect`：冲刷 S0/S1；
  - `s0_flushFromBpu`：BPU S3 override 导致的 flush，只冲 S0。
- IFU 的 `IfuPerfAnalysis` 会把 stall 归因为：FTQ bubble、backend redirect、IFU wbRedirect、BPU flush、ICache bubble 等（`Ifu.scala:789-793`）。

### 2.7 为什么 IFU 只有 3 级，整体取指却远不止 3 拍？

因为 IFU 前面还有一长串“预测 + 队列 + cache”：

```
BPU S0/S1 → FTQ → ICache Prefetch S0/S1 → WayLookup → ICache Main S0/S1 → IFU S0/S1/S2 → IBuffer
```

- BPU 是**预测**流水，不是取指流水；它在 S1 就把预测写进 FTQ，然后 FTQ 可以提前发起 ICache prefetch。
- ICache PrefetchPipe 和 MainPipe 之间隔着 `WayLookup`（深度 = `PrefetchDepth = 32`），prefetch 可以跑在 fetch 前面很多拍。
- 所以“从 BPU 预测到指令进入 IBuffer”的延迟不是一个固定拍数，而取决于队列占用和是否命中；**IFU 自身从收到 ICache 数据到写 IBuffer 固定是 3 拍**。

---

## 3. 上游：BPU 的 4 级预测流水

### 3.1 总览

BPU 顶层在 `frontend/bpu/Bpu.scala`。它维护 `s0`–`s3` 四个有效级信号（`Bpu.scala:109-153`）：

```
s0_fire → s1_valid → s1_fire → s2_valid → s2_fire → s3_valid → s3_fire
  │          │          │          │          │          │
  │          │          │          │          │          └─ 最终预测 + meta + fastTrain
  │          │          │          │          └─ MBTB/TAGE fast + s2_override
  │          │          │          └─ 收 uBTB/ABTB/uTAGE/uRAS，写 FTQ
  │          │          └─ uBTB/ABTB 读
  │          └─ 选 startPc
  └─ 发预测请求
```

| 级 | 主要工作 | 关键源码 |
|---|---|---|
| **S0** | 选择本拍要预测的 fetch block 起始 PC；并发读取 uBTB、ABTB；启动 TAGE/SC/uTAGE 的索引计算和表读（ITTAGE 在 S1 发读请求）；顺序预测（fall-through）；产生 PHR/CommonHR 的 s0 折叠历史视图（供各表索引） | `Bpu.scala:532-541`、各 predictor 的 `predict stage 0` |
| **S1** | 收 uBTB 命中（always-taken）；收 ABTB 的多个候选分支并用 uTAGE 修正条件方向；uRAS 提供 return target；选出**第一个 taken**；把预测写入 FTQ | `Bpu.scala:280-338`、`Bpu.scala:509-519` |
| **S2** | 收 MBTB 结果（2 个 align bank × (4 way + VBTB)）；TAGE 给出每个候选的**快速方向**；与 S1 预测比较；若不同则 `s2_override` 并回写 FTQ | `Bpu.scala:339-380` |
| **S3** | 收完整 TAGE（provider/alt）、SC 阈值判决、ITTAGE 目标、RAS 栈顶；做**最终预测**；若与 S2 不同则 `s3_override`；写 BPU meta 到 FTQ；用最终预测 fast-train uBTB/ABTB/uTAGE | `Bpu.scala:382-474`、`Bpu.scala:500-530` |

### 3.2 S0：起跑

- `s0_startPc` 的选择优先级（`Bpu.scala:532-541`）：
  1. `redirect.valid` → 重定向目标；
  2. `s3_override` → S3 修正后的目标；
  3. `s2_override` → S2 修正后的目标；
  4. `s1_valid` → 上一条预测的 target；
  5. 否则保持 `s0_startPcReg`（stall 时）。
- 起始 PC 有 3 份复制寄存器（`NumStartPcDuplicate = 3`），用于降低 fanout（`Bpu.scala:136-139`）。
- 所有 predictor 在同一拍看到 `s0_startPc` 和 `stageCtrl`，各自按自己的流水读表（`Bpu.scala:176-188`）。
- `fallThrough`（顺序预测器）在 S1 给出顺序下一块；如果没有任何 predictor 预测 taken，就用它（`FallThroughPredictor.scala`）。

### 3.3 S1：第一版预测，写入 FTQ

S1 用到以下几类预测资源（`Bpu.scala:280-329`）：

1. **uBTB**（MicroBtb）：
   - 32 项全相联，命中即 **always-taken**，只给一个分支（`slot1`）。
   - 目标来自 uBTB 的 target；如果是 return 且 uRAS 可用，则用 uRAS 的返回地址（`Bpu.scala:282-287`）。
2. **ABTB**（Ahead BTB）：
   - 1024 项，4 bank × 4 way；每个 block 最多给 4 个候选分支。
   - 对每个候选，如果它是条件分支，用 uTAGE 的 hit/taken 结果覆盖 ABTB 自己的 taken counter（`Bpu.scala:296-310`）。
   - 用 `CompareMatrix` 选出位置最靠前的 taken 分支（`Bpu.scala:312-324`）。
3. **uTAGE**（MicroTage）：
   - 不是独立预测器，而是 ABTB 的“条件方向修正器”。它只关心条件分支，使用 ABTB 给出的 `fastPositions` 对齐（`MicroTage.scala:52-243`）。
   - 采用 ahead 流水（源码中记作 a0/a1/a2，并保留 a3 快照给 S3 override），为 S1 的 ABTB 结果提供条件方向修正。
4. **uRAS**（MicroRas）：
   - 跟踪 S1–S3 中尚未提交的 call/return，预测“如果当前返回指令执行，栈顶是什么”（`MicroRas.scala:34-246`）。
   - 在 S1 直接覆盖 uBTB/ABTB 的 return target（`Bpu.scala:282-287, 320-324`）。

**S1 选择逻辑**（`Bpu.scala:325-329`）：

```
if (ABTB 有命中)
    if (ABTB 第一个 taken 有效) 用 ABTB 结果（条件方向由 uTAGE 修正）
    else 用 fall-through
else
    if (uBTB 命中) 用 uBTB
    else 用 fall-through
```

注意：**ABTB 只要命中就会压过 uBTB**，即使 ABTB 的候选都没 taken（此时走 fall-through），这是为了让 ABTB 的多分支覆盖优先于 uBTB 的单分支。

S1 的结果通过 `io.toFtq.prediction` 写入 FTQ（`Bpu.scala:509-519`）：

```
{startPc, target, taken, endPosition = cfiPosition, s2Override=0, s3Override=0}
```

### 3.4 S2：MBTB + TAGE 快速方向

- **MBTB**（Main BTB）：
  - 默认 8192 项，4 way、4 internal bank、2 align bank；每个 align bank 还有一份 VBTB（victim BTB）。
  - 返回值是 `NumBtbResultEntries = (NumWay + 1) × NumAlignBanks` 个候选（默认 10 个；Minimal 是 6 个）。
  - 读请求在 S0 发出，S1 得到分支位置（`s1_positions`，同时供 TAGE 使用），S2 得到完整结果（`MainBtbAlignBank.scala:100-160`、`MainBtb.scala:62-108`）。
- **TAGE 快速方向**：
  - TAGE 在 S0 读表，S1 算 tag，S2 得到命中/方向（`Tage.scala:62-195`）。
  - S2 用 `fastTakenVec`（provider-only，不含 alt-on-NA）给每个 MBTB 候选一个方向（`Bpu.scala:351-360`）。
- **第一个 taken**：用 `CompareMatrix` 在 MBTB 候选中找位置最靠前的 taken（`Bpu.scala:362-368`）。
- **override 条件**（`Bpu.scala:370-380`）：
  - taken 与 S1 不同；
  - 或第一个 taken 分支的 cfiPosition 与 S1 不同；
  - 或分支属性（attribute）与 S1 不同。
- 如果 override，`io.toFtq.prediction` 会带上 `s2Override=1` 和同一个 FTQ 指针，FTQ 用它覆盖同一 entry，并把下游指针回退（见 §3.7）。

### 3.5 S3：最终预测

S3 在 S2 的基础上加入慢速/精确信息（`Bpu.scala:382-474`）：

- **完整 TAGE**：provider/alt 选择、USE_ALT_ON_NA、base counter（`Tage.scala:109-195`）。
- **SC**（Statistical Correlator）：对每个 MBTB 候选的多个历史表计数求和，与阈值比较（`Sc.scala:224-325`）。SC 的 `scUsed` 决定是否用 SC 覆盖 TAGE。
- **ITTAGE**：间接跳转目标（`Ittage.scala:191-268`）。ITTAGE 只给目标低 20 位，高位由 16 项的 Region 目标缓存给出（`Ittage.scala:216-250`）。
- **RAS**：提交栈顶返回地址（`Ras.scala:64-90`）。
- **最终选择**（`Bpu.scala:435-457`）：

```
方向：条件分支
        SC 可用 → SC
        否则 TAGE 可用 → TAGE
        否则 → MBTB 的 taken counter
      非条件分支 → 直接 taken
目标：return → RAS
      needIttage 的 indirect → ITTAGE
      其他 → MBTB target
      都没有 taken → fall-through 目标
```

- **s3_override 条件**：taken 与 S2 不同，或第一个 taken 分支不同，或目标不同（RAS/ITTAGE/MBTB target）（`Bpu.scala:459-474`）。
- S3 还负责把以下 meta 写进 FTQ（`Bpu.scala:487-530`）：
  - `redirectMeta`：PHR、CommonHR、RAS 的恢复信息；
  - `resolveMeta`：MBTB/TAGE/SC/ITTAGE/PHR/CommonHR/uTAGE，供后端 resolve 训练；
  - `commitMeta`：RAS 提交信息；
  - `perfMeta`：预测来源、S2/S3 override 等性能信息。

### 3.6 预测流水线控制与重放

- `s0_fire = s1_ready && sramResetDone`；BPU 每拍可以启动一个新 block 的预测。
- `s1_fire = s1_valid && s2_ready && io.toFtq.prediction.ready`；如果 FTQ 满，BPU 在 S1 停住。
- `s2_fire = s2_valid && s3_ready`；`s3_fire = s3_valid`（S3 总是排空）。
- 由于 S2/S3 可能 override，BPU 内部保留了一些**重放状态**：
  - ABTB 的 `bpuS3ReplayState`：S3 override 时用旧的 S2 state 重新匹配（`AheadBtb.scala:150-170`）；
  - uTAGE 的 `a3` 快照：S3 override 时重用更老的 entry（`MicroTage.scala:143-200`）；
  - PHR 的 s1/s2/s3 folded history 快照：override 时选择对应的历史（`Phr.scala:88-96, 303-345`）。
- 这些机制保证 **S2/S3 的修正仍然使用“那个 block 当时的历史/索引状态”**，而不是当前已经前进的历史。

### 3.7 FTQ：BPU 与取指之间的解耦队列

FTQ 是理解香山前端的关键（`Ftq.scala`）：

- 每个 entry 保存一个 fetch block 的预测：`startPc`、`taken`、`endPosition`（`ftq/Bundles.scala:35-39`）。
- 另外有三套 meta 队列：
  - `metaQueueRedirect`：PHR/CommonHR/RAS 恢复信息；
  - `metaQueueResolve`：MBTB/TAGE/SC/ITTAGE/PHR/CommonHR/uTAGE 训练信息；
  - `metaQueueCommit`：RAS 提交信息。
- 指针（`Ftq.scala:105-116`）：
  - `bpuPtr`：BPU 将要写的 entry；
  - `pfPtr`：ICache prefetch 的 entry；
  - `fetchPtr`：ICache 实际取指的 entry；
  - `commitPtr`：后端已提交的 entry；
  - `pnrPtr`（point of no return）：BPU 还能 override 的最老 entry。
- S1 预测写入 FTQ；S2/S3 override 时用 `s2FtqPtr/s3FtqPtr` 回写同一 entry，并把 `pfPtr/fetchPtr` 回退到该 entry，从而冲刷已经取出的错误路径（`Ftq.scala:183-222, 247-277`）。
- BPU 的 runahead 上限是 `distance(bpuPtr, fetchPtr) < PrefetchDepth = 32`；enqueue ready 还受 `distance(bpuPtr, commitPtr) < FtqSize` 和 `BpTrainStallLimit` 限制（`Ftq.scala:180-186`）。
- FTQ 的 2-prefetch / 2-fetch：
  - 2-prefetch：两个 block 同页、第二个已过 `pnrPtr`、没有已知异常时，一次向 ICache 发两个 prefetch 请求（`Ftq.scala:282-330`）。
  - 2-fetch：两个 block 同页、总大小不超过一个 fetch block、第二个已过 `pnrPtr`、且没有已知异常时，ICache 一拍取两个 block（`Ftq.scala:334-360`）。

---

## 4. 分支预测微架构

### 4.1 预测器总表

| 预测器 | 结构（DefaultConfig） | 预测级 | 作用 |
|---|---|---|---|
| **FallThrough** | 顺序下一块 | S1 | 没有 predictor 预测 taken 时的兜底 |
| **uBTB**（MicroBtb） | 32 项全相联；tag 22、target 22；2-bit useful；PLRU | S0 读 / S1 出 | 最快路径，单分支 always-taken |
| **ABTB**（Ahead Btb） | 1024 项 = 64 set × 4 way × 4 bank；tag 24、target 22；2-bit taken counter；write buffer 4 | S0 读 / S1 使用 | 提前一拍的 BTB，最多 4 个候选分支；给 uTAGE 提供位置 |
| **uTAGE**（MicroTage） | 2 表 × 512 set × 1 way；history 5/9；tag 8；3-bit counter | ahead 流水，S1 出 | 只修正 ABTB 条件分支方向；只 fast-train |
| **MBTB**（Main Btb） | 8192 项 = 256 set × 4 way × 4 internal bank × 2 align bank；tag 16、target 20；2-bit taken；LRU；VBTB 32 项 | S0 读 / S1 位置 / S2 出 | 主 BTB，给 10 个候选分支 |
| **TAGE** | 8 表，每表 4096 项（512 set × 2 way × 4 bank）；history 4/9/17/29/56/109/211/397；tag 13；3-bit counter；2-bit useful；USE_ALT_ON_NA | S0 读 / S1 tag / S2 快速方向 / S3 完整 | 条件分支主预测器 |
| **SC** | path 2×128、global 2×128、backward 2×128、IMLI 1×128、bias 1×128；8 way；6-bit counter；threshold 1130（13-bit） | S0 读 / S1 求和 / S2 总判决（S3 使用） | 统计相关器，补充 TAGE |
| **ITTAGE** | 5 表（256/256/512/512/512），history 4/8/13/16/32；2 bank；tag 9；target offset 20；region cache 16 项 | S1 读 / S2 响应 / S3 出 | 间接跳转目标 |
| **RAS** | commit stack 16、spec queue 32、3-bit 重复计数 | S3 | return 目标 |
| **uRAS** | 跟踪 S1–S3 在途 call/return | S1 | 给 uBTB/ABTB 提供 return 目标 |
| **PHR / CommonHR** | PHR：Shamt=2、PathHashWidth=15、长度默认 532 位（397 + 2×64 + 4，对齐 4）；CommonHR：GHR/BW/IMLI，历史队列 8 | 全流水 | 提供折叠历史（index/tag）和恢复信息 |

> 上表是 `BpuParameters` 的默认值。`MinimalConfig` 会缩小大部分表（见 §6 的参数表），但结构和流水级不变。

### 4.2 为什么需要这么多预测器？

> 下面是对代码中“多级预测 + override”结构的解释，便于理解；具体的预测器选择逻辑仍以 `Bpu.scala` 为准。

因为香山把“预测”拆成了**时间上逐级精化**的三段：

1. **S1 快速段**：uBTB + ABTB + uTAGE + uRAS
   - 目标：**尽早**给 FTQ 一个可用的预测，让取指开始。
   - uBTB 容量很小但极快；ABTB 容量中等、能覆盖一个 block 内的多个分支；uTAGE 负责条件方向；uRAS 负责 return。
2. **S2 主段**：MBTB + TAGE（fast）
   - 目标：用更大的 BTB 和更强的 TAGE 给出更准的 taken/position/target。
   - 如果与 S1 不同，回写 FTQ 并冲刷下游。
3. **S3 慢段**：完整 TAGE + SC + ITTAGE + RAS
   - 目标：用长历史、统计相关器和间接目标预测做最终修正。
   - 只有确实改变结果时才 override（`s3_override`）。

这是一种**预测延迟与准确率解耦**的设计：常见情况（uBTB/ABTB 命中）在 S1 就有预测；复杂情况（长历史条件分支、间接跳转）到 S2/S3 才修正，最多晚 2 拍，但不会阻塞前端启动。

### 4.3 多分支候选与“第一个 taken”

一个 fetch block（默认 64B，32 个 2B 槽位）里可能有多条分支，但 BPU 每个 block 只预测**第一条 taken 分支**（标准做法）。

- ABTB 给出最多 4 个候选（`NumAheadBtbPredictionEntries = NumWays = 4`）。
- MBTB 给出 `(4+1) × 2 = 10` 个候选（每个 align bank 的 4 个 way + 1 个 VBTB）。
- 用 `CompareMatrix` 对候选的 `cfiPosition` 做两两比较，得到“最靠前的 taken”独热码（`CompareMatrix.scala`）：
  - S1：`s1_abtbFirstTakenBrOH`（`Bpu.scala:312-314`）；
  - S2：`s2_firstTakenBranchOH`（`Bpu.scala:362-363`）；
  - S3：`s3_firstTakenBranchOH`（`Bpu.scala:435-436`）。
- 如果所有候选都不 taken，就用 fall-through。

### 4.4 分支属性与 RAS 动作

`BranchAttribute`（`bpu/Bundles.scala:41-147`）把分支分为：

| branchType | 含义 | 例子 |
|---|---|---|
| None | 非 CFI | 普通 ALU/load/store |
| Conditional | 条件分支 | beq/bne/blt/bge/bltu/bgeu |
| Direct | 直接跳转 | jal、c.j |
| Indirect | 间接跳转 | jalr、c.jr、ret |

同时有 RAS 动作：

| rasAction | 含义 |
|---|---|
| None | 无 |
| Push | call（jal rd=x1/x5；jalr rd=x1/x5 且 rs≠rd） |
| Pop | return（jalr rs1=x1/x5 且 rd≠rs） |
| PopAndPush | 既是 return 又是 call（jalr rd=x1/x5 且 rs1=x1/x5 且 rs1≠rd） |

这些属性在 IFU S1 的预译码中也会重新解码，用于 PredChecker（`Ifu.scala:374-386`）。

### 4.5 历史寄存器：PHR + CommonHR

- **PHR（Path History Register）**：
  - 是一个长度为 `PhrHistoryLength` 的环形历史寄存器，而不是 15 位：`getPhrHistoryLength = align4(max(表历史长度) + Shamt × FtqSize + 4)`（`FrontendParameters.scala:40-58`）。默认 TAGE 最长历史 397、Shamt=2、FtqSize=64 ⇒ **532 位**；MinimalConfig 下 FtqSize=8 ⇒ 420 位（`Phr.scala:44-45`）。
  - taken 分支按 `Shamt = 2` 的粒度推进指针，并写入 `PathHashWidth = 15` 位的 `pathHash(cfiPc, target)`（加上 2 位 shift bits，共 15 位）；not-taken 分支写入 13 位 `PathHashHighWidth` 低位历史（`history/phr/Helpers.scala:62-110`、`Phr.scala:283-298`）。
  - 为每个 TAGE/ITTAGE/SC/uTAGE 表维护**折叠历史**（`FoldedHistoryInfo`），分别用于 set index 和 tag（`bpu/Types.scala`）。
  - `Phr.scala` 维护 s0/s1/s2/s3 四个折叠历史快照，并提供 `oldFoldedPhr`（正常路径）和 `trainFoldedPhr`（训练路径）（`Phr.scala:88-96, 303-345`）。
- **CommonHR**：
  - 代码维护 GHR、BW、IMLI 三组历史信号（`history/commonhr/CommonHR.scala`）：
    - `ghr`：全局分支历史；
    - `bw`：由 `isBackwardBranch(cfiPc, target)` 更新的 backward 分支历史（`history/commonhr/Helpers.scala:54`）；
    - `imli`：由 `s1_imliTaken` 更新的历史；`s1_imliTaken` 的条件是“S1 预测 taken、是条件分支、且 CFI PC 的低位大于 target 的低位”（`Bpu.scala:591-596`）。
  - 供 SC 的 global/backward/IMLI 表使用；`HistQueueSize = 8`（`history/commonhr/Parameters.scala`）。
- **恢复**：
  - 每个 FTQ entry 的 `BpuRedirectMeta` 保存 PHR/CommonHR/RAS 状态（`Bpu.scala:487-490`）。
  - redirect 时，FTQ 把对应 entry 的 meta 送给 BPU，BPU 恢复到“该分支之前”的历史，而不是简单地清空（`Bpu.scala:608-613`）。

### 4.6 训练

香山的 BPU 训练主要有以下几条路径：

1. **后端 resolve 训练（主路径）**
   - 后端把分支解析结果（最多 `ResolveEntryBranchNumber = 8` 条/FTQ entry）通过 `ResolveQueue` 收集（`ftq/ResolveQueue.scala`）。
   - FTQ 只保留到**第一个 mispredict（含）为止**的分支（`trainFirstMispredictMask`），避免错误路径污染预测器（`Ftq.scala:420-440`）。
   - 组装成 `BpuTrain {startPcVec, branches, meta, perfMeta}`，经 `trainCache` 送给 BPU（`Ftq.scala:430-445`）。
   - BPU 各 predictor 用 `io.train` 更新表；写请求先进 write buffer，以缓解单端口 SRAM 的读写冲突。
2. **IFU 提前 resolve**
   - IFU 的 PredChecker 在 WB 级发现 direct jump 等错误时，除了 redirect，还会通过 `ifuResolve` 进入 `ResolveQueue`（`Ftq.scala:360-375`、`ResolveQueue.scala:100-130`）。
   - 这样不必等后端执行完，就能训练 BPU（`canTrain` 的 direct jump 场景）。
3. **Fast train（S3 自训练）**
   - S3 的最终预测 `fastTrain` 直接训练 S1 段的 uBTB/ABTB/uTAGE（`Bpu.scala:169-188`）。
   - 对于 uTAGE，这是唯一的训练方式（它没有后端 resolve 训练，源码注释：`utage can only be fast-trained`）。
   - 优点：S1 段能快速跟上短周期模式；缺点：如果 S3 自己预测错，会短暂自污染，靠后续 resolve 修正。
4. **RAS 提交训练**
   - call/return 在提交时更新 RAS commit stack（`BpuCommitMeta`、`commitQueue`）（`Ftq.scala:520-540`）。

### 4.7 重定向与预测器恢复

重定向有两个来源：

1. **后端重定向**（`backendRedirect`）：分支解析、异常、中断、memory violation 等；
2. **IFU 重定向**（`wbRedirect`）：预译码发现的预测错误（§2.5）。

FTQ 的 `receiveBackendRedirect` / `receiveIfuRedirect` 选择优先级更高的一个（`Ftq.scala:130-160`），然后：

- 把 `bpuPtr/pfPtr/fetchPtr` 重置到 `newFtqIdx`；
- `pnrPtr = newFtqIdx`；
- 向 BPU 发 `BpuRedirect {cfiPc, target, taken, attribute, meta}`；
- 向 ICache/IFU 发 flush；
- BPU 用 `meta` 恢复 PHR/CommonHR/RAS（`Bpu.scala:608-613`），并清空 s1/s2/s3 流水。

### 4.8 预测来源统计

`BpuPredictionSource`（`bpu/Bundles.scala:149-192`）区分：

- **Stage1**：Ubtb / Abtb / AbtbUtage / Fallthrough；
- **Stage3**：Ras / ITTage / Sc / Tage / Mbtb / Fallthrough。

这些枚举用于性能计数（最终预测来自哪一级），是分析香山前端瓶颈的重要入口。

---

## 5. 流水线逐拍示意

假设没有 stall，取一个 fetch block B：

| 拍 | BPU | ICache | IFU | 说明 |
|---|---|---|---|---|
| C | S0(B)：读 uBTB/ABTB，启动 TAGE/SC/uTAGE 表读 | — | — | 选 startPc |
| C+1 | S1(B)：uBTB/ABTB/uTAGE/uRAS，写 FTQ | — | — | 第一版预测 |
| ... | S2/S3(B)：MBTB/TAGE/SC/ITTAGE/RAS，可能 override | Prefetch S0/S1(B) → WayLookup | — | 预测细化 + ICache 预取 |
| D | — | Main S0(B)：读 data SRAM | — | |
| D+1 | — | Main S1(B)：数据返回 → `toIfu.req` | **S0(B)**：边界/压缩 | ICache S1 与 IFU S0 同拍 |
| D+2 | — | （S2 只做 ECC/parity） | **S1(B)**：拼接/PC/预译码/对齐 | |
| D+3 | — | — | **S2(B)**：RVC 展开/检查/入 IBuffer | 指令此时已进 IBuffer |
| D+4 | — | — | **WB(B)**：PredChecker stage2 → FTQ | 若有预测错误，发出 `wbRedirect` |
| D+5 | — | — | — | FTQ 打一拍后应用 redirect、冲刷前端 |

注意：C 到 D 之间隔着 FTQ、PrefetchPipe 和 WayLookup，实际拍数取决于队列状态；从 IFU S0（D+1）到 S2（D+3）的 3 拍是 IFU 固定延迟。

---

## 6. 参数速查

### 6.1 前端总体

| 参数 | DefaultConfig | MinimalConfig | 源码 |
|---|---|---|---|
| `FetchBlockSize` | 64B | 32B | `FrontendParameters.scala:28`、`top/Configs.scala:122` |
| `FetchPorts` | 2 | 2 | `FrontendParameters.scala:29` |
| `FetchBlockInstNum` | 32（2B 槽位） | 16 | `FetchBlockSize / instBytes` |
| `IBufferEnqueueWidth` | 36 | 20 | `FetchBlockInstNum + NumWriteBank(4)` |
| `FTQ Size` | 64 | 8 | `FtqParameters.scala`、`top/Configs.scala:167` |
| `IBuffer` | 48 项（4 写 bank / 8 读 bank） | 24 项 | `IBufferParameters.scala`、`top/Configs.scala:170` |
| `ICache` | 256 set × 4 way × 64B = 64KB | 64 set × 4 way × 64B = 16KB | `ICacheParameters.scala`、`top/Configs.scala:172` |
| `PrefetchDepth` / WayLookup | 32 | 32 | `FrontendParameters.scala:30` |
| `DecodeWidth` | 8 | 8 | `Parameters.scala` |

### 6.2 分支预测器

| 预测器 | DefaultConfig | MinimalConfig |
|---|---|---|
| uBTB | 32 项 | 32 项 |
| ABTB | 1024 项（4 bank × 4 way × 64 set） | 同默认（未覆盖） |
| uTAGE | 2 表 × 512 set，h=5/9，tag 8 | 2 表 × 512 set，h=6/12，tag 15 |
| MBTB | 8192 项，4 way，2 align bank | 512 项，2 way，2 align bank |
| TAGE | 8 表，每表 4096 项（512 set × 2 way × 4 bank），h=4..397，tag 13 | 4 表，每表 1024 项（128 set × 2 way × 4 bank），h=6/9/17/31 |
| SC | 8 表（path 2 + global 2 + backward 2 + IMLI 1 + bias 1） | 5 表（path/global/backward 各 1 + IMLI + bias） |
| ITTAGE | 5 表（256/256/512/512/512），tag 9 | 3 表（256/256/512），tag 7 |
| RAS | commit 16 / spec 32 | commit 8 / spec 16 |

> MinimalConfig 的覆盖见 `top/Configs.scala:121-170`。

---

## 7. 代码里没有 F0–F3 这套流水命名

只在代码里搜索 `F3`/`F0` 这类流水命名时，会发现：

- 正在使用的 `Ifu` 模块只有 `s0`/`s1`/`s2` 和 “IFU Write-back Stage” 四段注释（`Ifu.scala:115`、`Ifu.scala:180`、`Ifu.scala:387`、`Ifu.scala:716`）；
- `frontend/ifu/F3PreDecode.scala` 只有类定义，没有任何 `new F3PreDecode` 例化点，是一个未使用的遗留模块；
- `Ifu.scala` 里没有 `f0`/`f1`/`f2` 这类信号或注释。

因此，**按代码回答：IFU 是 S0/S1/S2 + WB，不是 F0–F3 四级**。旧文档中的 F0–F3 说法不适用于这个 commit，本文不采用。

---

## 8. 设计要点与可借鉴之处

> 以下是基于前述 RTL 结构的分析/观点，不是 RTL 的直接语义。

1. **预测与取指解耦**：FTQ 让 BPU 可以“跑在前面”，取指只需按 FTQ entry 消费；BPU 的 S2/S3 override 通过回退 FTQ 指针来冲刷错误路径。这比“预测必须在一拍内完成”更容易做到高频。
2. **逐级精化（override）**：S1 先给一个可用预测，S2/S3 再修正。关键是 S2/S3 能拿到“那个 block 当时的历史快照”（PHR/ABTB/uTAGE 的 replay state），否则 override 会用错历史。
3. **IFU 的提前校验**：PredChecker 用预译码信息在 IFU 内部发现“该 taken 没 taken / 不该 taken 却 taken / taken 落在半条指令中间”，不必等后端，缩短了误预测惩罚。它只检查前端可见的错误，target 的正确性仍由后端保证。
4. **半字/跨块处理**：RVC + 32 位指令跨 fetch block 是前端最容易出 bug 的地方；香山用 `maybeRvcMap`、`firstInstrIsHalfRvi`、`prevEndHalfRviInfo`、`isCrossBlockInstr` 一套机制在 S0/S1 处理，并在 S1 预对齐 IBuffer 写 bank。
5. **2-fetch / 2-prefetch**：通过 FTQ 的 `passedPnr + 同页 + 总大小限制` 判断能否一拍取两个 block；WayLookup 和 PrefetchPipe 让预取与取指解耦。
6. **SRAM 端口与写缓冲**：TAGE/MBTB/SC/ITTAGE/uTAGE 都是 banked SRAM + write buffer，训练写和预测读冲突时由 buffer 吸收；这也是高频设计的一部分。

---

## 9. 关键源码索引

| 主题 | 文件 |
|---|---|
| IFU 顶层、S0/S1/S2/WB | `frontend/ifu/Ifu.scala` |
| 指令边界 | `frontend/ifu/InstrBoundary.scala` |
| 预测检查 | `frontend/ifu/PredChecker.scala` |
| IFU 辅助（compact/align/PC/offset） | `frontend/ifu/Helpers.scala` |
| RVC 展开 | `frontend/ifu/RvcExpander.scala` |
| uncache | `frontend/ifu/IfuUncacheUnit.scala` |
| BPU 顶层 | `frontend/bpu/Bpu.scala` |
| BPU 参数 | `frontend/bpu/Parameters.scala` 及各子目录 `Parameters.scala` |
| uBTB | `frontend/bpu/ubtb/MicroBtb.scala` |
| ABTB | `frontend/bpu/abtb/AheadBtb.scala` |
| uTAGE | `frontend/bpu/utage/MicroTage.scala` |
| MBTB | `frontend/bpu/mbtb/MainBtb.scala`、`MainBtbAlignBank.scala` |
| TAGE | `frontend/bpu/tage/Tage.scala` |
| SC | `frontend/bpu/sc/Sc.scala` |
| ITTAGE | `frontend/bpu/ittage/Ittage.scala`、`RegionWays.scala` |
| RAS / uRAS | `frontend/bpu/ras/Ras.scala`、`MicroRas.scala` |
| PHR / CommonHR | `frontend/bpu/history/phr/Phr.scala`、`history/commonhr/CommonHR.scala` |
| FTQ | `frontend/ftq/Ftq.scala`、`ResolveQueue.scala` |
| ICache Prefetch/Main | `frontend/icache/ICachePrefetchPipe.scala`、`ICacheMainPipe.scala` |
| ICache WayLookup | `frontend/icache/ICacheWayLookup.scala` |
| IBuffer | `frontend/ibuffer/IBuffer.scala` |
| 前端顶层连线 | `frontend/Frontend.scala` |
| 参数与配置 | `frontend/FrontendParameters.scala`、`xiangshan/Parameters.scala`、`top/Configs.scala` |

---

## 10. 附：一句话回答

**香山的 IFU 本体是 3 级流水（S0 边界/压缩 → S1 拼接/PC/预译码/IBuffer 对齐 → S2 展开/检查/入队），外加 1 级 WB 做预测校验和提前重定向；它上游的 BPU 是 4 级（S0 发起预测、S1 写 FTQ、S2 MBTB+TAGE 修正、S3 SC/ITTAGE/RAS 最终修正），通过 FTQ 与取指解耦，形成“预测先行、逐级精化”的前端。**
