# ifu3 — FTQ + 香山式 BTB/TAGE + 3 级 IFU（Phase 2 收口）

2026-10-17。入口 `rtl/rv32ifu3_top.v`。目标核：A910（RV32I 无 RVC、3 lane、ROB 160）。
对外端口与 `rv32ifu2_top` 基本一致，A910 构建开关：

```
make a910-elab A910_IFU=3
make a910-difftest-all A910_IFU=3 \
  A910_DT_BUILD=$PWD/obj_a910_dt_ifu3 \
  A910_DT_LOGDIR=$PWD/obj_a910_dt_ifu3/logs \
  A910_DT_MAX_CYCLES=1500000 \
  A910_DT_SKIP="coremark coremark_c4 coremark_i1 start peri trap npu_loop npu_smoke"
```

`IFU=3`（miniRV）暂时显式报错；A910 用 `A910_IFU=3`，默认 `A910_IFU=2` 保持 ifu2 基线。

---

## 0. 状态

- **Phase 0/1/2 已完成**：FTQ、3 级 IFU、香山式 BTB/uBTB/TAGE-lite/PHR、
  BP2 S2 override、RAS、PredChecker、精确 PHR 恢复、S0 吞吐规则。
- A910 `a910-elab` IFU2/IFU3 均 Error/IWNF/DCTTSW/PCWM=0；
  `a910-difftest-all` **IFU2 46 PASS、IFU3 46 PASS / 0 FAIL**。
- 5 个 IFU3 单元/定向台：`make ifu3-unit` 全 PASS。
- `branch_bench`：IFU3 **180,856 拍**，IFU2 192,973 拍（IFU3 快 6.3%）。
- **完整 B CoreMark（30 iteration，`+NOVALID`）**：IFU2 **3.634/MHz，8,254,858 ticks，275,160 cycles/iter**；
  IFU3（当前默认 5/10/15/16）**3.744/MHz，8,011,507 ticks，267,049 cycles/iter**（score +3.03%）。
  旧默认 4/8/12/16 为 3.731 / 8,038,860 / 267,960。B 镜像 ticks < 10M，
  CoreMark 的 10 秒合法性不过，两个都是 `+NOVALID` 跑完的**不合法分数**。
- **当前前端默认**：TAGE 历史窗口 **5/10/15/16**（零面积）；i-cache 保持 **1 KB/2-way/16 B**；
  BTB 保持 **64 行**。2 KB/4 KB i-cache 与 BTB 128/256 均已实测，但面积不划算，未采用。
- `a910-run TEST=a910_smoke A910_IFU=3` PASS。
- Phase 3（SC/ITTAGE、override 零停拍、Fmax）未做；miniRV 未接。

---

## 1. 结构

```
BPU (香山 S1/S2 式: 早预测 + S2 override)
  BP0: 用 btb_rd_pc 读 BTB; 用 (line_pc, phr_q) 读 TAGE
  BP1: uBTB / BTB+base 早预测 -> 写 FTQ; next_pc 组合反馈到 BP0 读地址
       (TAGE 的 tag/hit/provider 并行算好, 只送 BP2)
  BP2: 用 latched BTB slots + TAGE dir 重算; 与早预测不同 =>
       S2 override: 重写同一 FTQ 项、丢弃年轻项, BPU 从修正后的
       next_pc/PHR 重启
        │ {startPc, taken, takenSlot, target, phr, btb_cond}
        ▼
FTQ (16 预测项 + 64 meta RAM; meta RAM 仍未使用, 留给 Phase 3)
        │
ICache (复用 rv32ifu2_icache/refill; 16 B 行, 1-cycle read)
        │
IFU 3 级 (S0/S1/S2 各自 line 寄存器)
  S0: 1 块/拍: ICache 响应可**旁路**进 S1, 同拍再发下一块;
      S1 接不走时落 `s0_resp` skid buffer
      (ICache 返回拍只寄存整行/预测, 不做译码)
  S1: RV32I 预译码 + PredChecker (用已寄存的 s1_data/s1_*);
      修正结果沿上写回 s1_* 并停一拍, 下一拍 fire
  S2: 组 128-bit packet + 25-bit **per-lane** chk; 按 IBUF 空位推前缀;
      整块推完才 pop FTQ
  IFU override: PredChecker 发现确定错误时重写 FTQ 当前项、丢弃年轻项,
                BPU 从修正 target 重启; S1 块保留, S0 丢弃
        │
IBUF (复用 rv32ifu2_ibuf, 4 push / 3 pop)
```

关键点：

- **RV32I 无 RVC**：16 B 块固定 4 条 4 B 指令；跳过香山的 RVC/边界/压缩/半字拼接。
- **startPc 可非 16 B 对齐**：`pc_ofs = startPc[3:2]`，只交付 `slot >= pc_ofs`；
  lane PC 必须从 `align16(startPc)` 加 `slot*4`；fall-through 是 `line_pc+16`。
- **FTQ 只在整块交付完后 pop**；3 lane 交付 4 条指令时不会丢第四 lane。
- **S0 1 块/拍**：`s0_issue` 允许与响应消费同拍；S1 反压时响应进 skid。

## 2. 预测器

| 模块 | 结构 |
|---|---|
| `rv32ifu3_btb.v` | 64 行 × 4 slot，row=pc[9:4]，tag=pc[15:10]；每 slot `{valid, type, target, 2-bit ctr}`；cond 方向 base 用 ctr；JAL/JALR 恒 taken；退休点训练 |
| `rv32ifu3_ubtb.v` | 32 项全相联 always-taken；存 `{tag, pos, is_cond, target}` |
| `rv32ifu3_phr.v` | 16-bit PHR 组合折叠：4 表窗口 4/8/12/16，fold 到 6-bit set / 8-bit tag |
| `rv32ifu3_tage.v` | 4 张 tagged 表 × 64 set × 1 way；每项 `{tag[7:0], ctr[2:0]}` + valid；provider/alt；无 hit 回落 BTB base |
| `rv32ifu3_ras.v` | **已从 IFU 移除例化**（2026-10-18）：文件保留，留给 BPU S3 的 RAS；IFU chk[24:16] 固定 0 |
| `rv32ifu3_predcheck.v` | **Phase 2 新**：RV32I 预译码 + 确定错误的修正 |
| `rv32ifu3_bht.v` | 未例化；Phase 3 A/B 对照 |

### 2.1 PHR

- 16-bit，只在 **predicted-taken CFI** 时推进；FPU 块在第一个 taken 截断，
  所以块内被交付的分支之前不会再有 taken。
- 推进基底是全局索引寄存器 `phr_q`（不是延迟快照 `bp_rd_phr_q`）；查表/tag/
  FTQ snapshot 用一拍滞后的副本（与 ifu2 W2.4 同源）。redirect/override 重启
  气泡里**禁止**再推进 `phr_q`，否则会覆盖刚恢复的值。
- 精确恢复：`chk[15:0]` 是块首快照；IU 重定向时如果实际是 taken 条件分支，
  `phr_q <= {chk[13:0], branch_pc[3:2]^branch_pc[7:6]^target[3:2]}`；
  非条件/not-taken 直接回块首；RTU 重定向清 0。
- 需要 `iu_btb_pc`（BEU 的 `idu_pc`）才能重算 hash；即使用一拍滞后口径，
  “快照 + 本次实际结果”仍能恢复全局索引。

### 2.2 RAS（已从 IFU 移除）

> **2026-10-18**: IFU 不再例化 RAS。退预测已由 BTB/uBTB 直接给 target，
> `top/top_vld` 没有任何消费者；`chk[24:16]` 在 IDU/RTU/BEU 里也没有读者
> （只回传 `chk[15:0]` 的 PHR）。按香山分工，RAS 属于 BPU S3（状态只在
> s3_fire 更新），后续在 BPU 重建 uRAS/RAS。以下为原 IFU RAS 设计存档。

- `chk[24:19]` = 该指令动作前的 undo-log 写指针，`chk[18:16]` = 实际生效动作
  （0 none / 1 push / 2 pop / 3 pop_push）；`chk[15:0]` 仍是 PHR。
- 每个块在 S1 fire 时一次性应用 0..4 条动作；同块内先 pop 后 push，带 bypass。
- undo log 精确记录 push 目标/pop 值；回滚按逆序撤销，连被覆盖的栈内容一起恢复
  （不是 ifu2 的 pointer-only + valid 位）。
- IU 重定向：按 chk 的 ckpt 回滚，再重放该分支的实际动作。
- BPU override 命中已 fire 的 S2 块：回滚到该块的 `s2_start_ras_ckpt`。
- RTU 重定向：无 chk，清空（与 PHR 清 0 同口径）。
- 退休训练推进 log 的 commit 指针；log 满（占用≥63）时反压 S1。
- 回滚是多拍 FSM；rollback 期间 S1 不 fire，PredChecker 视为 RAS 无效。
- 迟到训练事件（RTU clear 之后）在 log 为空时忽略，打印一次 warning。

### 2.3 PredChecker（S1）

令 `f` = 块内第一条真实 CFI（`slot >= pc_ofs`），`k` = FTQ 预测 taken 的 slot：

1. `k` 之前有真实 JAL `f`：JAL always-taken，修到 f 的 target，deliver 到 f。
2. `k` 是非 CFI：假 taken；修成整块 fall-through（`taken=0, end=3,
   target=line+16`）。
3. `k` 就是第一条真实 CFI 且是 JAL：target 不对则修。
4. 未预测 taken 且 `f` 是 JAL：修到 JAL 目标。
5. `f` 是 cond / 非 ret JALR / ret：方向或目标不可知，**不修**
   （ret 的 target 交给 BTB/uBTB 和后端重定向）。

修正时 IFU 发一拍 `ifu_ovr`：FTQ 重写当前项、`count=idx-head+1`；BPU 从修正
target 重启、PHR 用该块块首；IFU 保留 S1 块、丢弃 S0、闸住 S2 finish/push 一拍，
`inflight=min(s1_dist+1,7)`。优先级：backend redirect > IFU override > BPU override。

## 3. 验证

### 3.1 单元/定向 TB

```
make ifu3-unit          # 5 个一起
make ifu3-ftq-unit      # 随机 alloc/finish/alloc+finish/override/flush/inflight
make ifu3-ras-unit      # 3000 block + 随机回滚 + commit
make ifu3-predcheck-unit# JAL/ret/假 taken/cond 不修/pop_push/非对齐
make ifu3-bpu-unit      # BTB 训练、PHR 两次推进、IU/IFU override、气泡
make ifu3-ifu-unit      # S0 back-to-back=49/50、skid、非对齐块
```

### 3.2 周期（同镜像 A910 difftest）

| 用例 | IFU2 | IFU3 最终 |
|---|---:|---:|
| addi | 373 | 426 |
| beq | — | 726 |
| jalr | — | 289 |
| branch_bench | 192,973 | **180,856** |

小用例受 3 级 IFU + 启动/重定向固定开销影响；branch_bench 上 IFU3 已快于 IFU2。
历史阶段（Phase 1 263,128；Phase 2 早期 317,738）只作对照。

### 3.3 CoreMark（B 配置，30 iteration）

镜像 `coremark/build_w_B_sched`（30 iteration，B scheduling）。同配置：
IFU2 = TAGE + `AIQ_ENTRY=16`；IFU3 = `AIQ_ENTRY=16`。直接调 simv，
`GM_MONITOR=1`、`+NOVALID +PROBE_PERF +MAX_CYCLES=20000000`：

| 配置 | Total ticks | Average cycles/iteration | CoreMark Score |
|---|---:|---:|---:|
| IFU2 TAGE | 8,254,858 | 275,160 | 3.634 (/MHz) |
| IFU3（默认 5/10/15/16） | **8,011,507** | **267,049** | **3.744 (/MHz)** |
| 变化 | **−2.95%** | **−2.95%** | **+3.03%** |

`Total ticks` 8.0–8.25M < 10M，CoreMark 自己会打
`ERROR! Must execute for at least 10 secs for a valid result!` 并写 `0xDEAD`；
加 `+NOVALID` 才能跑完，所以**这两个 Score 都不是合法 CoreMark 分数**，
比较时引用 `Average cycles/iteration`，Score 要带“不合法”一起说。
CoreMark 自己打印的 `Iterations/Sec : 3` 是 port 的整数除法假象，不引用。
日志：`/tmp/cm_ifu2_b_full.stdout`、`/tmp/cm_ifu3_b_full.stdout`。

#### 分支预测准确率（300k B 代理，退休点，按控制转移类型）

| 类型 | IFU2 TAGE | IFU3 | 变化 |
|---|---:|---:|---:|
| 条件分支 | 88.57%（56,220 / 误 6,428） | **89.30%**（58,343 / 误 6,240） | +0.73pp |
| JAL | 89.90%（11,204 / 误 1,132） | **99.60%**（11,202 / 误 45） | +9.7pp |
| JALR | 66.13%（877 / 误 297） | **99.32%**（878 / 误 6） | +33.2pp |
| **合计** | **87.18%**（60,663 / 误 7,775） | **90.03%**（62,854 / 误 6,264） | **+2.85pp** |

完整 B 的总误预测 219,062（IFU2）→ **175,211（IFU3 默认 5/10/15/16，−20.0%）**；
完整 B 条件准确率 88.78%、合计 89.58%。**IFU3 的收益几乎全在 JAL/JALR 目标
（RAS + uBTB/BTB）；条件分支方向只 +0.73pp，剩下的 ~11% 条件误预测才是继续
提分的墙。**

#### BTB 行数扫描（300k B 代理，`IFU3_BTB_ROW_AW`）

| ROW_AW | rows | 条件准确率 | 总误预测 | IPC | 退休 |
|---:|---:|---:|---:|---:|---:|
| 6 | 64 | 89.30% | 6,264 | 0.896 | 268,862 |
| 7 | 128 | 89.18% | 6,319 | 0.895 | 268,335 |
| 8 | 256 | 89.46% | 6,208 | 0.901 | 270,162 |

**加 BTB 行数没有换来条件方向准确率**（6,240→6,188，−0.8%），128 行甚至略差；
256 行的 IPC/退休 +0.5% 更像时序/窗口噪声，而面积 4×。⇒ IFU3 的剩余误预测
主要不是 BTB 覆盖，而是条件方向本身；下一刀应换方向预测器（TAGE 几何/历史/
useful/2-way 或 SC），不要再加 BTB 行数。

#### TAGE 历史窗口扫描（`IFU3_TAGE_L0..L3`）

| 窗口 | 300k 条件 | 300k 总误 | 300k IPC | 1.5M 退休 | 1.5M 条件 | 1.5M 总误 | 1.5M IPC |
|---|---:|---:|---:|---:|---:|---:|---:|
| 4/8/12/16（默认） | 89.30% | 6,264 | 0.896 | 1,353,855 | 88.75% | 32,786 | 0.903 |
| 2/4/8/16 | 87.29% | 7,004 | 0.855 | — | — | — | — |
| 2/6/10/14 | 88.50% | 6,564 | 0.878 | — | — | — | — |
| **5/10/15/16** | **89.64%** | **6,123** | **0.902** | **1,356,989** | **88.84%** | **32,579** | **0.905** |

短历史明显更差；**5/10/15/16 在 1.5M 上只有 +0.23% 退休 / −0.63% 误预测 /
条件 +0.09pp**（300k 的 +0.68% 偏乐观）。它零面积，**已切为当前默认**，但
**历史长度不是条件方向的主杠杆**——16-bit PHR 已经是上限；再往上要
2-way/useful/SC 或更宽的 PHR。真正更大的前端桶仍是 i-cache（1.5M 里 120k 拍）
和 S0/S1/S2 的重取填充（106k 拍）。

#### i-cache 容量扫描（`ICACHE_BYTES`，16 B 行 / 2-way / LRU，1.5M B 代理）

| 容量 | 退休 | IPC | miss | 回填在途 | i-cache miss idle | 前端无货 | 其它供给不上 | 条件准确率 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 KB | 1,353,855 | 0.903 | 39,840 | 119,755（8.0%） | 120,100 | 22.0% | 106,585 | 88.75% |
| **2 KB** | **1,365,451** | **0.910** | 18,346 | 55,214（3.7%） | 89,639 | 19.8% | 95,624 | 88.69% |
| 4 KB | 1,369,027 | 0.913 | 14,569 | 43,885（2.9%） | 20,951 | 19.4% | 100,036 | 88.69% |

- **2 KB：+0.86% 退休，i-cache miss −54%，i-cache idle −25%**；
  **4 KB：+1.12% 退休，miss −63%，i-cache idle −83%**，但只比 2 KB 多 0.26%，
  面积是 2×。2 KB 是面积/收益的甜点，但**本版不采用**（面积优先，保持 1 KB）；
  4 KB 同样不采用。
- 4 KB 的 i-cache idle 只剩 21k 拍，但“其它供给不上”仍有 100k、front-end idle
  19.4%——瓶颈已经搬到 IFU/后端，继续加 cache 收益饱和。
- 分支准确率略降 0.06pp（88.75→88.69），但 IPC 净升；预测器没变，属于时序/路径差异。
- 可与 TAGE 5/10/15/16（零面积）叠加；S2 bypass 因 Fmax 风险暂不做。

## 4. 已知限制 / Phase 3

1. **override 仍是“闸一拍”**：FTQ 的 override 分支忽略同拍 finish/alloc，
   IFU/BPU 各停一拍。要省这一拍需要 FTQ 同时处理 finish+override（Phase 3）。
2. **TAGE-lite**：1-way、无 useful/SC/ITTAGE；原计划按 A/B 决定是否加。
3. **RTU 重定向没有 chk**：trap/mret/store replay 会清 PHR/RAS，而不是精确恢复。
4. **miniRV 的 IFU=3 未接**：`Makefile` 继续显式报错。
5. **FTQ meta RAM 仍未使用**：RAS/PHR 都走 chk sideband；meta 留给 Phase 3。
6. **A910 TB 的 iu_btb_* force**：IFU3 构建下已移除（IFU2 保留旧基线）。
7. **PredChecker 不做**：cond 方向、非 ret JALR 目标；这些交给 BEU。

## 5. 文件

```
rtl/rv32ifu3_top.v        对外 drop-in top
rtl/rv32ifu3_ftq.v        16 项预测队列 + 64 项 meta RAM (未使用)
rtl/rv32ifu3_ifu.v        S0/S1/S2 + PredChecker/RAS 集成 + IFU override
rtl/rv32ifu3_bpu.v        BPU 环 + 精确 PHR + IFU override 重启
rtl/rv32ifu3_btb.v        块 BTB
rtl/rv32ifu3_ubtb.v       uBTB
rtl/rv32ifu3_tage.v       TAGE-lite
rtl/rv32ifu3_phr.v        PHR 折叠
rtl/rv32ifu3_ras.v        推测栈 + undo log（已不例化，留给 BPU S3）
rtl/rv32ifu3_predcheck.v  RV32I 预译码 + S1 预测检查
```

## 6. 2026-10-18 Fmax 时序改造（A910 实测）

**改动（全部与香山 IFU 的分级对齐）**

1. **RAS 移出 IFU**：`top/top_vld` 无消费者、`chk[24:16]` 无外部读者，
   IFU 里只剩一份推测状态和 `busy` 门控。删除例化，chk 高位填 0；
   RAS 按香山分工属于 BPU S3，后续在 BPU 重建。
2. **S0/S1 重排**：ICache 返回拍只把整行/预测元信息寄存进 `s1_data/s1_*`；
   RV32I 预译码和 PredChecker 放到 S1 拍（数据/预测都已是寄存器），
   修正值沿上写回 `s1_*`、下一拍 fire。`s1_corr_done_q` 保证每块只修一次，
   与改前单趟检查逐拍等价。
3. **训练口打拍**：`rtu_train_*` 在 BPU 入口统一寄存一拍，再进 BTB 写 mux、
   TAGE 四表读改写、uBTB 32 路 CAM（香山也是 write buffer/多拍写表）。
4. **redirect 出组合门控**：`redirect` 不再串进 `s0_issue / s1_fire /
   ftq_finish / alloc_valid / alloc_fire / ovr_valid / refill_req`。override/
   flush 当拍本来就由各状态机的 redirect/flush 分支优先接管，不写任何流水
   寄存器；组合出来的 ICache 地址只会多读一行，不会被消费。
5. 32 位 `!=`（PredChecker、BPU override 比较）改成 `|(a^b)`，避免借位链。

**实测**（`synth/build_fmax_a910.tcl`，xc7k325t-2，Performance_NetDelay_high）

| 配置 | top WNS / Fmax | 内部最差 | IFU 最差 |
|---|---:|---:|---:|
| 基线 HEAD @190MHz (5.263ns) | -7.821 / 76.43MHz | **-6.711 (IFU: BEU redirect→ICache)** | -6.711 |
| 本轮 @190MHz | -7.657 / 77.40MHz | **-5.966 (LSU MSHR)** | -5.567 (IDU RF→FTQ/BPU) |
| 基线 HEAD @150MHz (6.667ns) | -6.947 / 73.45MHz | **-5.430 (IFU: ICache)** | -5.430 |
| 本轮 @150MHz | -7.078 / 72.75MHz | **-5.695 (LSU DCache)** | -4.426 (IDU RF→BPU) |

- **IFU 内部寄存器到寄存器的路径已全部退出 top-500**；剩下的 IFU 相关路径
  都是「后端 BEU redirect → IFU 状态/FTQ」的跨模块路径，源头在核内。
- top-line WNS 由 `biu_pad_*`/`pad_biu_*` 主导（0ns I/O + ~4.1ns 时钟插入
  skew 惩罚），看 Fmax 应看内部 WNS；本轮内部最差从 -6.711 改善到 -5.966
  （+0.75ns）。
- 150MHz 点的 top-line 比基线差 0.13ns 是 pad 路径的布局运气；内部最差已
  从 IFU 换成 LSU/DCache。**下一步的 Fmax 杠杆在 LSU/RTU，不在 IFU。**
