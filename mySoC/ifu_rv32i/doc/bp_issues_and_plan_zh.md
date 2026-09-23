# 分支预测 / L0 BTB 问题清单与改造计划（面向乱序多发射）

本文记录 2026-09-23 对 `rv32_ifu_top` 接入 mySoC 后**分支预测与 L0 BTB 更新通路**的实测审计结果，
以及按 C910 结构、面向未来乱序多发射 CPU 的改造计划。

测量对象：`IFU=1`、`ICACHE_EN=1`、`LBUF_EN=0`、`BHT_TRAIN_EN=1`、`ITERATIONS=25` 的 CoreMark，
10,146,229 拍 / 10,107,213 ticks / Score 2.473 / 三个 CRC 全对 / `Test Point Pass!`。
测量手段是 `tb/tb_miniRV_dpi.sv` 里的纯观测计数器（见附录 C），加计数器前后周期数逐位不变。

---

## 0. 结论摘要

1. **跑分不是零和**：IFU 接入后确实更快（相对旧 PC/NPC 通路 11,017,550 → 10,107,213 拍）。
   但**前端当前的瓶颈不在 cache**（全程 i-cache 只填 169 行），而在预测质量、以及被裁剪掉的
   后端交互接口。

2. **L0 BTB 的更新通路存在 3 处与 C910 不一致的行为**，其中两处会直接制造"白取"：
   - 分配条件过宽：**801,429 次分配中 438,191 次（54.7%）是 "BHT 预测不跳" 时分配的废项**，
     这些项 `cnt<=0`，按命中规则永远不可能命中，只挤掉有用项 → 查询命中率仅 **33.09%**。
   - 武装条件过宽：C910 只在**强 taken**（`bht_pre_result==2'b11`）时武装，这版**弱 taken 也武装**
     （实测预测 taken 的 881,922 次里弱 taken 占 **189,759 次 = 21.5%**）。
   - 撤销条件错：C910 在**弱 taken** 时就删项（`l0_btb_not_saturate`），这版改成"预测不跳才删"，
     整场**只删了 135 次**，而 hold 有 463,012 次 → **一旦武装几乎无法降级，taken 位是粘滞的**。
     直接后果：**IP 级判 L0 预测错 196,593 次**，占 1,238,715 次改向的 **15.9%**，其中 **79% 是方向冲突**
     （L0 说跳、包内方向预测说不跳）。

3. **更新目标的来源被换掉了**：C910 把"命中的那一条"以 one-hot 随包带到后端、再原样送回来当更新目标
   （`ct_ifu_addrgen.v:302`），L0 内部不做任何仲裁；这版改成了在 L0 内部**按 PC 重扫 CAM**，
   于是出现"更新取最高编号、查找取最低编号"的不对称。**当前实测不会打中**（同 PC 重复项 0 次），
   但它是一颗地雷：一旦按第 2 条的建议放宽分配条件，重复项就会出现，届时会变成
   "查找可见的那条永远陈旧 + 每次更新抖动另一条"的正反馈。

4. **被裁剪掉的后端接口才是乱序多发射的真正欠账**：只消费 lane0（`idu_accept_num=1`）、
   PCFIFO 是桩（credit 恒 2、token 恒 0、create/cancel 全悬空）、`rtu_ifu_retire0/1/2_*` 全 0、
   `iu_ifu_mispred_stall` 接 0、LBUF 关、无 LSU i-cache 失效通路。
   值得注意的是：**C910 原生就把 `chk_idx[24:0]` 走 PCFIFO create 总线交给后端**
   （`ct_ifu_top.v:112/389`），我们后来加在 IBUF 上的 chk 旁路是这条原生通路的替代品。

5. 改造分 4 期，每期可独立验证/回退：
   **P0 一致性修复**（小改、先拆雷）→ **P1 更新源回归 IP 级 + 随包带命中 one-hot** →
   **P2 交付/恢复接口换成 C910 原生（PCFIFO full + create 总线）** →
   **P3 retire 反馈：训练与恢复移到退休点** → **P4 乱序专用项**（mispred_stall / LBUF / checkpoint / i-cache 失效）。

---

## 1. 基线实测

### 1.1 分支预测

| 指标 | 数值 |
|---|---|
| 条件分支准确率 | **86.87%**（1,357,591 / 1,562,711）|
| jal/jalr 准确率 | **92.00%**（169,426 / 184,157）|
| 总体控制转移准确率 | **87.41%**（1,527,017 / 1,746,868）|
| 误预测总数 / MPKI | 219,851（条件 205,120 + jal/jalr 14,731）/ 28.55 |
| BHT 预测 taken / 实际 taken | 56.44% / 54.97% |
| └ 强 taken(11) / 弱 taken(10) | 692,163 / 189,759 |
| 预测 taken 实际不跳 / 预测不跳实际跳 | 113,985 / 91,135 |
| 退休指令 / IPC | 7,699,275 / 0.759 |

两个方向都错、预测 taken 比例与实际 taken 比例贴合 ⇒ 方向表确实在工作，不是退化成静态预测。

### 1.2 L0 BTB

| 指标 | 数值 |
|---|---|
| lookup | 7,385,475 |
| CAM 命中 | 2,444,101（**查询命中率 33.09%**；条件 2,138,176 / jal 259,219 / jalr 46,706）|
| IF 级接受并改向（`ifctrl_l0_btb_accept`） | 1,238,715 |
| **IP 级判 L0 预测错（`l0_invalidate`）** | **196,593**（占改向 15.9%）|
| └ 方向错 / 目标不符 / 类型错 | 154,954（79.0%）/ 32,226（16.4%）/ 8,948（4.6%）|
| 训练上报 `train_valid` | 2,395,527（条件 2,096,310 / jal 213,033 / jalr 86,184）|
| 命中已有条目 / 未命中→分配 | 1,594,098 / **801,429** |
| └ `update_taken=1` 时分配 / `=0` 时分配 | 363,238 / **438,191（54.7%，废项）** |
| update_fire / kill / hold | 1,932,515 / **135** / 463,012 |
| 表内平均有效 / 武装条目（共 16） | 9.67 / 12.02 |
| fragment 分拍推进 | **0** / 4,522,816 次 consume（排除"静态 lane 索引漏训"这条怀疑）|

### 1.3 取指气泡拆解

`if_accept=0` 共 2,245,222 拍 = **22.13%**：

| 来源 | 拍数 | 占全程 |
|---|---|---|
| IFU 初始化 | 1,027 | 0.01% |
| 冲刷（误预测/陷阱） | 219,852 | 2.17% |
| **核内停顿** | **1,270,610** | **12.52%** |
| └ load-use | 561,400 | 5.53% |
| └ muldiv（乘除未 ready） | 709,210 | 6.99% |
| 核在等、IFU 没货 | 753,733 | 7.43% |
| └ reissue / bp_read_stall / 其它 | 37 / 82,080 / 671,616 | |

- **最大的单项是乘除停顿（7%）**，比分支预测的全部损失还大；load-use 5.5%。这两项都是顺序单发射
  流水线的固有代价，乱序化后自然消失（见 P4 的说明）。
- 真正"IFU 供不上"的是 753,733 拍（7.4%），其中 671,616 拍归在"其它"（既非 reissue 也非
  `bp_read_stall`/`if_frontend_stall`），尚未细分。
- **i-cache 全程只填 169 行** ⇒ 代码常驻，前端断供与 cache 无关。

---

## 2. 问题清单

### P-1（行为错）L0 分配条件过宽

C910 只在两类事件上分配 L0 项：① IP 级报的 **L0 未命中**（`ct_ifu_ibdp.v:2233`
`l0_btb_br_miss|br_mispred|ras_*`，且 `!ibdp_btb_miss`）；② ipdp 的计数维护（只改已有项）。

本版 `train_valid` 是 ibctrl 对**每一条**推进 IBUF 的控制转移发的（`rv32_ifu_ibctrl.v:81-87,137-149`，
`has_train = active && cf_type∈{1,2,3}`），没有任何"是否值得进表"的资格判定。

实测：801,429 次分配中 438,191 次发生在 `update_taken=0`（该分支的方向预测是"不跳"），
而 `eligible`（`rv32_ifu_l0_btb.v:186`）要求 `entry_cnt`，所以这些项**天然不可能命中**。
16 项 FIFO 每分配一次转一格 ⇒ 条目存活期 ≈ 16 次分配 ≈ 200 拍，这是命中率只有 33% 的直接原因。

### P-2（行为错）L0 武装条件过宽

`rv32_ifu_l0_btb.v:160` `l0_btb_update_cnt_bit = update_taken`，而 `update_taken` 是包内 bit122
= BHT 的**方向预测位**（`bht_pred = bht_counter[1]`），**弱 taken（2'b10）与强 taken（2'b11）无法区分**。

C910（`ct_ifu_ipdp.v:5856-5862`）：
```verilog
assign l0_btb_counter_zero = ifdp_ipdp_l0_btb_hit && !ifdp_ipdp_l0_btb_counter && ...
                          && (bht_pre_result[1:0] == 2'b11);   // 只有强 taken 才武装
```
实测预测 taken 的条件分支里 **21.5% 是弱 taken**，按 C910 规则都不该武装。

### P-3（行为错）L0 撤销条件错 → taken 位粘滞

`rv32_ifu_l0_btb.v:131` `update_kill = update_en && update_match && !update_taken && update_cnt_armed`。

C910（`ct_ifu_ipdp.v:5850-5855`）的撤销触发是 **弱 taken**：
```verilog
assign l0_btb_not_saturate = ... con_br && (bht_pre_result[1:0] == 2'b10);
assign l0_btb_wen[3] = ipctrl_ipdp_ip_data_vld && (l0_btb_not_saturate || l0_btb_mistaken);
assign l0_btb_update_vld_bit = l0_btb_counter_zero;   // 即：not_saturate/mistaken 时写 vld<=0
```
即：**方向预测一旦从"强 taken"降到"弱 taken"，C910 就把该项删掉，让 L0 停止按它改向**；
本版要等到预测位翻成 0 才删，而那时该项往往已被 FIFO 淘汰。

实测：**kill 只有 135 次**（hold 463,012 次）；而 IP 级仍判错 196,593 次，
其中 79% 是"L0 说跳、包内方向预测说不跳"。这 196,593 次就是白取一整趟的来源。

> 注意 `l0_invalidate`（IP 级的出错纠正）与这里的"训练期降级"是**两条不同的通路**，
> 本版只有前者在起作用，后者形同虚设。

### P-4（潜伏）更新目标来源退化：CAM 重扫 + 最高编号优先

```verilog
// rv32_ifu_l0_btb.v:177  更新：同 PC 取【最高】编号（注释称沿用旧实现的升序扫描语义）
assign update_select[entry] = update_match_vec[entry] && !(|(update_match_vec & HIGHER_ENTRIES));
// rv32_ifu_l0_btb.v:191  查找：命中取【最低】编号
assign hit_select[entry]    = hit_candidates[entry]    && !(|(hit_candidates  & LOWER_ENTRIES));
```
C910 里不存在这个仲裁：命中 one-hot（`entry_hit = entry_rd_hit | entry_bypass_hit`，**multi-hot**）
随包经 ifdp→ipdp→ibdp 到 addrgen，寄存后原样当更新目标回来
（`ct_ifu_addrgen.v:189 / :228 / :302`）。

**当前是否打中：否。** `alloc_vld = update_en && !update_match`（`:117`）保证同一 PC 在表里最多一条
有效项，两条规则只在"同 PC 重复项 ≥2"时才分叉。整场实测：**多路匹配拍数 = 0，其中真发生写入 = 0**
（自检：`matchvec==1` 的拍数 80,834 ≈ `update_match` 73,302，差值来自 `update_en=0` 的拍，
说明该信号确实被读到、不是常量 0）。

**为什么仍必须修**：它正好埋在 P-1 的修法上。一旦照 C910 把分配改成"IP 级报 miss 才分配"，
分配与命中就不再来自同一个独占判定，重复项立刻可能出现；届时填充/杀项打最高编号那条，
而查找与 directed invalidation（`l0_invalidate_mask = ifdp_ipdp_l0_entry_mask`，来自查找命中项）
打最低编号那条 ⇒ 查找可见的那条永远留着旧 target 与陈旧武装位。**顺序上必须先修一致性，再放宽分配。**

### P-5（架构）更新时机与资格错位

C910 的 L0 维护在 **ipdp（IP 级）**，能同时看到 `ifdp_ipdp_l0_btb_hit`、`ipctrl_ipdp_ip_mistaken`、
`bht_pre_result[1:0]`、`l0_btb_hit_l1_btb`、`con_br`、`!l0_btb_ras`；分配在 **ibdp**，
带 `ib_data_vld && !expt_vld && !self_stall` 等资格。

本版把两者合并后放在 **ibctrl（IBUF 消费侧）**，只有包内的 `bht_pred` 位可用，
丢掉了上述全部资格判定，且时机更靠前（更推测）。BHT 侧的对应问题见 P-6。

### P-6（架构）BHT 缺少 retire 层

现状：训练与 VGHR 修复都在 **EX 级**（`mycpu.v` 的 `iu_bht_check_vld` + `chk_idx` 快照），
`rtu_ifu_retire0/1/2_*` 全部接 0（`ifu_subsys.v:188-226`）。

C910 同时使用三个 retire 槽（`rtu_ifu_retire0/1/2_condbr_taken/chk_idx/jmp/mispred/pcall/preturn/...`）
+ committed GHR（`committed_recover_ghr`）做**精确**恢复与训练。顺序单发射下 EX 级反馈还能凑合，
但乱序下 EX 级是推测点，用它训练/恢复会引入系统性偏差；正确的训练点在**退休**。

另外 `iu_ifu_check_token` 被接 0 —— 该端口**在本机任何 C910 里都不存在**（见 6.2），
是移植版自创的；按 C1 补充原则应删除，训练资格改由 create/retire 通路保证。

### P-7（架构）交付与取消接口被裁剪

| 机制 | C910 | 本版 |
|---|---|---|
| 指令交付 | IBUF 3 lane + `idu_ifu_accept_num` | 只消费 lane0（accept_num=1）|
| 分支元数据 | PCFIFO create0/1 总线：`cur_pc[39:0] / tar_pc / bht_pred / chk_idx[24:0] / jal / jalr / dst_vld / jmp_mispred`（`ct_ifu_top.v:111-130`）| create 总线**全部悬空**（`ifu_subsys.v:150-171`）|
| 流控 | `iu_ifu_pcfifo_full`（1 位，C910 原生）| 自创的 `credit` 恒 2'b10、`alloc0/1_token` 恒 0 |
| 恢复/取消 | `iu_ifu_mispred_stall` + L0→IP 的 `mispred_pc`/`ip_mistaken` 握手 | `mispred_stall` 接 0；自创的 `cancel_vld`/`first_token` 悬空 |
| chk_idx 交付 | **PCFIFO create 总线原生字段** | 后加在 IBUF 上的旁路（`rv32_ifu_ibuf.v` 的 `chk_q`/`out_chk`）|

也就是说：**我们为了补上被打桩的 PCFIFO，自己加了一条 IBUF 旁路 —— 而这条路 C910 本来是有的。**
`allocate_rv32_ifu_ibuf` 的旁路在顺序核上工作良好（difftest 通过），但它绑死了"每拍一条"的假设，
且没有 token 语义，乱序化后会被 P2 替换。

### P-8（性能）前端供应与恢复路径

- `iu_ifu_mispred_stall` 接 0（注释说接 1 会死锁——那是因为缺少真正的后端恢复协议，
  不是 C910 的语义问题）。
- `cp0_ifu_lbuf_en = 0`，循环缓冲未启用。
- `lsu_ifu_icache_inv_*` 接死：一旦有 store / DMA / 自修改码，i-cache 失效必须接通。
- "核在等而 IFU 没货" 753,733 拍中，"其它" 671,616 拍未细分（疑似重定向后的前端重填，
  需要用 IFU 内部的重定向/重填计数进一步拆）。

---

## 3. 改造计划

原则：**先修行为错（P0），再恢复 C910 的数据流（P1/P2），最后接后端（P3/P4）**。
每期独立可测、可回退；不把"性能优化"和"接口重构"混在同一次提交里。

### P0 一致性修复（小改，先拆雷）

| 编号 | 改动 | 位置 |
|---|---|---|
| P0-1 | 武装条件改为**强 taken**：`update_cnt_bit = train_taken & train_packet[184]`（bit184 = `chk_idx[24]` = 预测当时 BHT 计数器低位，ibctrl 的 `train_packet` 已含该位）| `rv32_ifu_l0_btb.v:160` |
| P0-2 | 撤销条件改为**弱 taken**：`update_kill = update_en && update_match && update_taken && !chk[24]`（对齐 `l0_btb_not_saturate`）；是否保留 `update_cnt_armed` 门控需 A/B —— C910 对命中的项不看 counter 就删 | `rv32_ifu_l0_btb.v:131` |
| P0-3 | 分配加资格：`alloc_vld = update_en && !update_match && update_taken`（未命中的 not-taken 分支不再进表；命中项的武装/降级不受影响）| `rv32_ifu_l0_btb.v:117` |
| P0-4 | 选择优先级与查找一致：`update_select` 改用 `LOWER_ENTRIES` | `rv32_ifu_l0_btb.v:177` |

**预期**：方向类白取（154,954）应大幅下降；分配从 801,429 降到 ≈363,238 或更低；命中率上升。
**但周期数是否下降必须 A/B 实测**——分配减少会同时降低"预置未武装项"带来的后续武装机会，
理论上净收益为正，但不做实测不下结论。

**回归门槛**：`make run-all` 45 项全过 + CoreMark 三个 CRC 一致 + 无 `Diffrence`。

### P1 更新源回归 IP 级 + 随包带命中 one-hot（对齐 C910）

- L0 的**维护**（武装/降级）由 ipdp/ipctrl 产生：需要 `l0_btb_hit`、`ip_mistaken`、`bht_pre_result[1:0]`、
  `con_br`、`!ras`、`l1_btb_hit` 这些 IP 级信息 —— 参照 `ct_ifu_ipdp.v:5846-5878` 原样对照实现。
- L0 的**分配**由 IP 级报的 miss/mispred 事件驱动 —— 参照 `ct_ifu_ibdp.v:2225-2240`。
- **命中 one-hot 随包下传**，更新目标不再重扫 CAM：
  192 位槽包的空闲位 `[127:125]`(3) + `[121:109]`(13) 正好 16 位，照 C910 的
  `addrgen_l0_btb_update_entry = addrgen_l0_btb_hit_entry` 把 one-hot 寄存后送回 L0。
  **注意一个坑**：`rv32_ifu_pcfifo_if.v:50-55` 目前在外送 IDU 包时用 `[121:109]` 装自创的 token，
  所以 one-hot 必须在 **IP 级（ipctrl，pcfifo_if 之前）就被消费掉**——
  这也正好与"把更新搬回 IP 级"一致，不是额外约束。P2 删掉 token 后这段位宽会空出来。
- 删除 `rv32_ifu_ibctrl.v` 的 `train_*` 输出与 `has_train/selected_train`（或保留接口但只作为
  "IP 级事件的搬运工"）。

这一步做完，P-4 的不对称从"潜伏"变成"不存在"，P-1/P-5 也从根上解决。

### P2 交付与恢复接口换成 C910 原生（PCFIFO full + create 总线）

- 接通 `ifu_iu_pcfifo_create0/1_*`：`{cur_pc, tar_pc/npc, cf_type, dst_vld, pred, chk_idx[24:0], jmp_mispred}`
  交给后端（未来的 ROB/重命名级），**用它取代 IBUF 上的 chk 旁路**。
- **流控与恢复：照 C910 原生机制做**（设计者 2026-09-23 决定，见 6.2）：
  `iu_ifu_pcfifo_full` + 2 条 create 总线 + `iu_ifu_mispred_stall` 恢复背压，
  **不采用**移植版自创的 `credit`/`token`/`cancel` 方案——它在本机 5 份 C910 里都找不到出处，
  协议语义无处对齐，属于"自创机制"。
- 端口表按 C910 重写（删 credit/token/cancel/check_token，加 `pcfifo_full`，create 总线字段对齐）；
  `rv32_ifu_pcfifo_if.v` 按 `ct_ifu_pcfifo_if.v` 重建为 2 项记录缓冲；
  `allowed_count` 的交付门控改走 `pcfifo_wait` → IP stall → IBUF 排空这条 C910 链路。
- IBUF 输出 3 lane 放开：`idu_ifu_accept_num` 支持到 3，前端每拍可交付 3 条。

### P3 retire 反馈：训练与恢复移到退休点

后端需要提供的字段（C910 每拍 3 个退休槽）：
`retire{0,1,2}_{vld, cur_pc, condbr, condbr_taken, jmp, chk_idx, load, store, no_spec_hit/miss/mispred}`、
`retire0_{pcall, preturn, inc_pc, next_pc, mispred, jmp_mispred}`。

用途：
1. **committed GHR 恢复**（`committed_recover_ghr`）：比 EX 级的 chk 快照更权威；
2. **BHT/L0 训练改在退休点**，用 `no_spec` 限定，剔除推测路径的影响；
3. **RAS 修复**：`pcall/preturn` 以退休为准；
4. 退休槽 3 条/拍是 C910 为多发射准备的带宽，顺序核可以先接 1 条。

### P4 乱序多发射专用项

- `iu_ifu_mispred_stall`：误预测恢复窗口内由后端压住前端（需要真正的恢复协议，
  不能像现在这样"接 0 因为接 1 会死锁"）。
- 分支 checkpoint：`chk_idx`（22 位 VGHR + 2 位 sel + 1 位 counter 低位）已经是**每条分支的
  预测时快照**，天然可作重命名级的恢复点；配合 P2 的 create 总线 + P3 的 retire 反馈，
就是完整的按分支恢复（C910 的做法，不需要自创 token）。
- LBUF（`cp0_ifu_lbuf_en`）打开：小循环零取指开销。
- LSU i-cache 失效通路（`lsu_ifu_icache_inv_*`）：有 store / DMA 之后必须。
- 每拍多包/多块取指吞吐：PCGen 与 IBUF 的带宽检查（顺序核下不是瓶颈，多发射下会变成瓶颈）。
- 顺序单发射下最大的两块停顿（muldiv 709,210 拍、load-use 561,400 拍）在乱序化后自然消解，
  **不需要在 IFU 侧做任何补偿**——这也是"改动要朝乱序框架走"的直接理由。

---

## 4. 验证方法与回归门槛

**已有工具**（`tb/tb_miniRV_dpi.sv`，`ifdef USE_IFU` 内，`$finish` 前自动打印）：
分支准确率三档 + MPKI、BHT 强/弱 taken 分布、L0 全漏斗（lookup/hit/accept/invalidate）、
L0 判决拆分（方向/目标/类型/无命中，三桶与顶层 `l0_invalidate` 精确对平）、
分配/命中/kill/hold 与废项占比、表内有效/武装均值、气泡四分类、i-cache 填充数、
`fragment` 分拍推进、选择优先级一致性（多路匹配 / 更新选中项与查找命中项是否一致）。

**回归门槛**（每期都必须满足）：
1. `make run-all` 45 项全过；
2. CoreMark：`crclist 0xe714` / `crcmatrix 0x1fd7` / `crcstate 0x8e3a` 全对，无 `Diffrence`，`Test Point Pass!`；
3. 周期数不退化（P0/P1 之后应改善，需记录 A/B 两组数字）；
4. 预测准确率与白取次数的**联合**判据：只看准确率会被"预测得少所以错得少"骗过，
   必须同时看 `l0_invalidate` 绝对次数与 `accept` 次数。

**A/B 方法**：
```bash
make build BUILD_DIR=$PWD/obj_nofsdb FSDB_HOME=     # 不带 FSDB, 单测试约 4s
make run   TEST=addi BUILD_DIR=$PWD/obj_nofsdb FSDB_HOME=   # 冒烟: IFU=1 应约 2366 拍
ln -sf $PWD/bin/coremark.bin meminit.bin
GM_MONITOR=1 $PWD/obj_nofsdb/simv +vcs+lic+wait +MAX_CYCLES=15000000 -exitstatus > /tmp/cm.txt 2>&1
```
- 快速迭代可用 `ITERATIONS=1`（约 40 万拍、1~2 分钟），**比例与整场一致**（已交叉验证），
  但跑分不合法（<10 秒），报告会走失败路径打印——为此 TB 已在失败路径也调用报告函数；
- 跑整场约 21 分钟。

---

## 5. 风险、回退与已知坑

**风险**
- P0-2/P0-3 会改变预测质量，可能连带改变周期数（升或降都要实测，不能想当然）；
  必要时照 `BHT_TRAIN_EN` 的做法加参数开关（`ifu_subsys` 里的 `parameter`）便于 A/B 与回退。
- P1/P2 会动包格式与模块接口，difftest 是主要防线（它是提交驱动的，对取指气泡免疫，
  但对重复提交/漏提交极其敏感）。
- P2 的 create 总线/流控需要后端配合设计，不能在 IFU 单侧改完就宣称可用。

**已知坑（都是踩过的，务必先看）**
1. `pcgen_l0_btb_chgflw_vld` **不是 L0 专用信号**（含 ipctrl/ibctrl 各路改向）。
   统计 L0 改向要用 `ifctrl_l0_btb_accept`。
2. **ipctrl 的输入端口做分层引用读出来不可信**（实测 `ifdp_ipdp_l0_slot` 读出来像只取到低位，
   与 `last_index` 恒差 2）。读模块**内部 wire**（`last_packet`/`l0_correct`/`fragment_fire`/`reaches_l0`）
   和顶层网是可信的；凡涉及端口的分层引用都要先用"复算-对账"验证。
3. `make run TEST=xxx` 会把 `meminit.bin` 重新指到 `bin/xxx.bin` —— 跑 CoreMark 前必须确认链接目标。
4. 增量编译有 clock skew 警告；怀疑 build 与源码不一致时用 `rm -rf obj_nofsdb` 全量重建验证
   （实测本仓库曾出现"编译进 simv 的 `l0_correct` 与磁盘源码不一致"的现象，全量重建后仍复现，
   最终定位为第 2 条的分层引用问题，与编译无关）。
5. IFU 初始化需要约 1,027 拍才吐第一条指令（`addi` 单测试 IFU=1 约 2366 拍 vs IFU=0 约 244 拍），
   小测试的统计量会被初始化淹没，不要用小测试判断预测质量。
6. CoreMark 有效性下限：`time_in_secs = ticks/1e6`，25 iterations ≈ 10.1M ticks 刚好过 10 秒，
   提速后必须调大 `ITERATIONS`（`make -f coremark/Makefile.coremark ITERATIONS=N`，
   注意要先 `rm -rf coremark/build`，否则 `.o` 不会重建）。

---

## 6. 决策记录与未完成清单

### 6.1 已定决策（2026-09-23，设计者确认）

| 编号 | 问题 | 决定 |
|---|---|---|
| A1 | P0-3 的步子 | **先只加一行资格**（`alloc_vld &= update_taken`），更新源暂留 ibctrl；未完成部分必须记录（见 6.3）|
| A2 | P0 验收门槛 | **软门槛**：周期数允许 ±1%，以"准确率 + 白取次数"改善为准 |
| A3 | P0-2 的严格度 | **严格对齐 C910**：去掉 `update_cnt_armed` 门控，命中项直接按弱 taken 删 |
| A4 | 开关留存 | **验证完就删**，只留最终行为（不长期保留 parameter 开关矩阵）|
| B1 | 分支恢复机制 | ~~按 token 精确取消~~ → **改为照 C910 原生机制**（见 6.2 与 B2 修正）：`iu_ifu_pcfifo_full` 流控 + 2 条 create 总线 + `iu_ifu_mispred_stall` 恢复背压，不用自创的 token/credit |
| B2 | 参考来源 | 移植自 `open_riscv_2035`。**已核实**：本机 5 份 C910 树（open_riscv_2035 / XuanTie-NEW-CIU / mars1 / openc910_sv02 / chang-openc910）的 IFU RTL 里**既没有 `pcfifo_credit`/`alloc0_token`，也没有 `check_token`，连 "token" 这个词都搜不到**（对照：`iu_ifu_bht_check_vld` 能搜到，说明搜索有效）。⇒ `iu_ifu_pcfifo_credit` / `alloc0_token` / `cancel_vld` / `cancel_first_token` / `iu_ifu_check_token` 全是**移植版自创**。**处理原则（设计者 2026-09-23 明确）：没有 C910 参考的自创机制一律舍弃，改为照 C910 实现**（见 6.2）|
| B3 | 后端消费带宽 | 未来每拍 **3 条**（`idu_accept_num` 上限放开到 3，IBUF 3 lane 用满）|
| B4 | retire 反馈 | **宽度按 3 槽预留**，先只驱动 retire0 |
| B5 | 多线程/特权上下文 | **不预留**（单区域、恒 M 模式、i-cache tag 不加上下文语义）|
| C1 | "对齐 C910"的标准 | **结构对齐、细节允许工程优化**（不要求逐条行为等价）；**补充原则**：凡"没有 C910 参考的自创机制"一律舍弃并改为 C910 做法——C1 的"细节可优化"只适用于**有 C910 依据的适配**，不适用于自创 |
| C2 | 基线/指标/验收 | 由本文档 6.4 定义（见下）|
| C3 | 提交方式 | 先整理提交当前工作区，再按 P0/P1 分次提交 |

### 6.2 自创机制清点与处置（按 B2/C1 补充原则）

"自创"指在 C910 里**找不到对应物**的机制（已逐条核对 `open_riscv_2035` 等 5 份 C910）。
注意与**必要适配**区分：把 C910 的机制按 RV32 位宽/word 槽改造（如 L0 用全宽 tag 取代
C910 的半字局部 tag + 跨模块 PC 高位重建）属于适配，有 `changes_zh.md` 记录，保留。

| 自创机制 | 位置 | C910 对应物 | 处置 |
|---|---|---|---|
| PCFIFO `credit` / `alloc0,1_token` / `cancel_vld` / `cancel_first_token` | `rv32_ifu_top` 端口、`rv32_ifu_pcfifo_if.v` | `iu_ifu_pcfifo_full`（1 位）流控 + `ifu_iu_pcfifo_create0/1_*` 记录总线 | **P2 替换**：改用 full + create 总线，端口表按 C910 重写 |
| `iu_ifu_check_token[12:0]` | `rv32_ifu_top` 端口（现接 0） | 无（C910 的 check 只有 `chk_idx[24:0]`，不带 token）| **删除**（P2），训练资格改由 create/retire 通路保证 |
| IBUF 的 chk 旁路（`in_chk`/`out_chk`/`chk_q`、`instruction_chk`）| `rv32_ifu_ibuf.v`、`rv32_ifu_pcfifo_if.v` | create 总线的 `chk_idx[24:0]` 字段（`ct_ifu_top.v:112/389`）| **P2 删除**：`chk_idx` 回到 create 总线原生交付 |
| ibctrl 的 `train_*`/`has_train`/`selected_train`（L0 训练上报）| `rv32_ifu_ibctrl.v:81-87,137-149` | 无；C910 的 L0 维护在 `ct_ifu_ipdp.v:5846-5878`、分配在 `ct_ifu_ibdp.v:2225-2240` | **P1 删除**：改为 ipdp/ibdp 驱动（这也是 P-1/P-5 的根治）|
| L0 内部 CAM 重扫（`update_match_vec`/`update_select` + 最高编号优先）| `rv32_ifu_l0_btb.v:175-191` | 命中 one-hot 随包带回（`ct_ifu_addrgen.v:189/228/302`）| **P1 删除** |
| ipctrl 本地复算 `l0_correct` + `l0_in_fragment` 补丁 | `rv32_ifu_ipctrl.v:125-143` | L0→IP 的显式握手：`ipdp_ipctrl_l0_btb_mispred_pc` → `ipctrl_ipdp_ip_mistaken` → `l0_btb_mistaken`，以及 `ipctrl_l0_btb_wait_next` / `l0_btb_ipctrl_st_wait` | **待审计**（见下）|
| L0 的 `kind[2:0]` 类型字段 + ipctrl 的类型比对 | `rv32_ifu_l0_btb.v`、`rv32_ifu_ipctrl.v` | C910 用"预测错的那条 PC"（`mispred_pc`）做身份判定，不比类型 | **待审计** |

**"待审计"两项的说明**：`l0_in_fragment` 是为修一个真实故障（coremark 里 slot1 的 bltu 之后
0x858/0x85c 被跳过）加的补丁，它**必须留到 C910 的握手通路补上之后再拆**，不能先删后补。
审计内容：把 `ct_ifu_ipctrl.v` 的 `ipctrl_l0_btb_chgflw_vld / ip_vld / wait_next` 与
`ct_ifu_ipdp.v` 的 `ipdp_ipctrl_l0_btb_mispred_pc / hit_way / vld` 全套对照本版，
判断"本地复算 + 补丁"能否被原生握手整体取代。这一项建议放在 P2 之后（create 总线接通后
`chk_idx`/类型信息本来就会重新分配，届时再动风险最小）。

**P2 修订后的做法**（替代原"自定义 token 协议"）：
1. `rv32_ifu_top` 的 PCFIFO 端口改成 C910 形状：删 `iu_ifu_pcfifo_credit` / `alloc0,1_token` /
   `cancel_vld` / `cancel_first_token` / `iu_ifu_check_token`，加 `iu_ifu_pcfifo_full`；
   create0/1 总线字段对齐 C910（`cur_pc[39:0]→[31:0]`、`tar_pc`、`jal`/`jalr` 取代 `cf_type`、
   保留 `bht_pred` / `chk_idx[24:0]` / `dst_vld` / `jmp_mispred`）。
2. `rv32_ifu_pcfifo_if.v` 按 `ct_ifu_pcfifo_if.v` 重建为 2 项记录缓冲；
   现在靠 `credit` 算出来的 `allowed_count`（指令交付门控）要改成 C910 的 `pcfifo_wait` →
   IP 级 stall → IBUF 排空这条链（顺带处理现在 `credit_stall` 悬空的问题）。
3. IBUF 的 chk 旁路、指令包里的 token 位（`[121:109]`）随之删除。
4. `iu_ifu_mispred_stall` 按 C910 语义接上（P4 的恢复协议）。

### 6.3 未完成内容（A1 要求记录）

| 项 | 状态 | 归属期 |
|---|---|---|
| 更新源仍在 ibctrl（应按 C910 搬回 IP 级 ipdp/ipctrl）| 未做 | P1 |
| 命中 one-hot 未随包带，L0 内部 CAM 重扫仍在（P0-4 只做了一致化，没拆根）| 未做 | P1 |
| L0 分配仍是"每条控制转移"触发，未改成 IP 级 miss/mispred 驱动 | 未做（P0-3 只是加了 taken 资格）| P1 |
| BHT 无 retire 层：`rtu_ifu_retire0/1/2_*` 仍全 0，无 committed GHR 恢复 | 未做 | P3 |
| PCFIFO/create 总线未接；IBUF 上的 chk 旁路仍在承担交付；自创的 credit/token/cancel 端口待删 | 未做 | P2 |
| `iu_ifu_mispred_stall` 仍接 0（缺后端恢复协议）| 未做 | P4 |
| LBUF（`cp0_ifu_lbuf_en`）未启用 | 未做 | P4 |
| `lsu_ifu_icache_inv_*` 未接（有 store/DMA 后必须）| 未做 | P4 |
| `idu_accept_num` 仍恒为 1，IBUF 3 lane 未用满 | 未做 | P2 |
| 气泡中"核在等、IFU 没货"的"其它 671,616 拍"未细分 | 未做 | P4（需 IFU 内部重定向/重填计数）|
| `hpcp_ifu_cnt_en` 接 0，C910 自带性能计数器全部闲置 | 未做 | 可选 |
| 自创的 PCFIFO credit/token/cancel 与 `iu_ifu_check_token` 仍在端口表里 | 未做（6.2）| P2 |
| IBUF 的 chk 旁路仍在承担 `chk_idx` 交付 | 未做（6.2）| P2 |
| ibctrl 的 `train_*` 是自创上报口（P1 要删）| 未做 | P1 |
| ipctrl 本地复算 `l0_correct` + `l0_in_fragment` 补丁 vs C910 的 `mispred_pc`/`ip_mistaken`/`wait_next` 握手 | **待审计**（6.2）| P2 之后 |
| L0 `kind[2:0]` + ipctrl 类型比对是否可被 C910 的 `mispred_pc` 身份判定取代 | **待审计** | P2 之后 |

### 6.4 验收基准与指标（C2 决定）

**基准三层**
1. **主基准**：CoreMark `ITERATIONS=25`（10.1M 拍，约 21 分钟）——唯一与既有记录可比的整场基准。
   硬门槛：三 CRC（`0xe714`/`0x1fd7`/`0x8e3a`）+ 无 `Diffrence` + `Test Point Pass!`。
2. **快速代理**：CoreMark `ITERATIONS=1`（约 40 万拍、1~2 分钟，需 `rm -rf coremark/build` 后重建）。
   已交叉验证比例与整场同向（L0 命中率 34.8% vs 33.1%、白取/改向 9.9% vs 15.9%）。
   **只用于迭代筛选，不用来下结论**（跑分不合法且含冷启动偏置）。
3. **新增定向基准（待做）**：`asm/branch_bench.S` —— 现有小测试的统计量被 IFU 初始化 1,027 拍淹没
   （`beq` 全程仅 1,509 拍，其中 1,027 拍是初始化），无法用于评估预测质量。要求：
   - 运行 ≥ 5 万拍（初始化占比 < 2%）；
   - 覆盖 4 类可判定场景：① 稳定 taken 的循环回边；② 几乎不跳的前向分支；
     ③ 交替 taken/not-taken（2 位计数器最坏情况）；④ 函数调用/返回（考 RAS + L0 target）；
   - 每类单独可统计（靠 PC 区间区分），用来**定向验证 P0 的具体语义**
     （弱→强才武装、弱 taken 降级、not-taken 不再分配）——这是 CoreMark 做不到的。

**指标与目标（方向性目标，每期实测后校准，不作为承诺）**

| 指标 | 当前 | P0 目标 | 来源 |
|---|---|---|---|
| CoreMark 周期数 | 10,146,229 | ±1%（软）| TB |
| 条件分支准确率 | 86.87% | ≥ 88.5% | TB |
| L0 `invalidate/accept` | 15.9% | < 8% | TB |
| L0 查询命中率 | 33.09% | > 45% | TB |
| 分配中废项占比 | 54.7% | < 10% | TB |
| 45 项定向测试 | 全过 | 全过（硬）| `make run-all` |

**每次改动必须落盘一条 A/B 记录**（周期数、三 CRC、上表五项），建议追加到
`doc/bp_change_log_zh.md`（待建）。

### 6.5 执行顺序

1. 整理提交当前工作区（C3）；
2. 建 `asm/branch_bench.S` + `bp_change_log_zh.md`（P0 的验证前提）；
3. P0-1 ~ P0-4（逐条 A/B，开关验证完即删）；
4. P1（更新源回归 IP 级 + one-hot 随包，同时删掉 ibctrl 的自创 train_*）；
5. P2（照 C910 重做 PCFIFO full + create 总线，删自创 token 与 IBUF chk 旁路）；6. P3；7. P4。

---

## 附录 A：当前在 `ifu_subsys.v` 里接死的端口（按用途分类）

| 分类 | 端口 | 现值 | 乱序下应 |
|---|---|---|---|
| PCFIFO 流控 | `iu_ifu_pcfifo_credit` / `alloc0/1_token`（**自创**）| `2'b10` / `13'h0` | **删除**，改用 C910 的 `iu_ifu_pcfifo_full`（P2）|
| PCFIFO 交付 | `ifu_iu_pcfifo_create0/1_*` | 悬空 | 接后端（P2）|
| PCFIFO 取消 | `ifu_iu_pcfifo_cancel_vld` / `first_token`（**自创**）| 悬空 | **删除**，恢复走 `iu_ifu_mispred_stall` + L0/retire 握手（P4/P2）|
| 误预测反馈 | `iu_ifu_mispred_stall` | `1'b0`（接 1 会死锁）| 真正的恢复协议（P4）|
| BHT check 限定 | `iu_ifu_check_token`（**自创**）| `13'h0` | **删除**（P2）；训练资格由 create/retire 通路保证 |
| 退休反馈 | `rtu_ifu_retire0/1/2_*`（共 40+ 根）| 全 0 | 接 ROB（P3）|
| 维护 | `cp0_ifu_maint_*` | 0 | 软失效/清表时可接 |
| 调试/断点 | `had_ifu_*` / `cp0_ifu_bkpt*` | 0 | 调试器接入时 |
| 性能计数 | `hpcp_ifu_cnt_en` | `1'b0`（所有 `ifu_hpcp_*` 因此恒 0）| 打开即可用 C910 自带计数器 |
| LSU 失效 | `lsu_ifu_icache_inv_*` | 0 | 有 store/DMA 后必须 |
| 区域/权限 | `cp0_yy_priv_mode=2'b11`、`REGION_COUNT=1` | 固定 | 特权模式/多区域时 |

## 附录 B：C910 参考源码位置（本机 `/x2025/GPrj1/IC1/riscv/RISCV_CPU/open_riscv_2035/C910_RTL_FACTORY/gen_rtl/ifu/rtl/`）

| 主题 | 文件:行 |
|---|---|
| L0 维护（武装/降级/误预测删项）| `ct_ifu_ipdp.v:5846-5878` |
| L0 分配（IP 级 miss 驱动）| `ct_ifu_ibdp.v:2225-2240` |
| 命中 one-hot 随包带回 | `ct_ifu_addrgen.v:189 / :228 / :302`；`ct_ifu_l0_btb.v:366-378` |
| BHT 训练与 VGHR 恢复 | `ct_ifu_bht.v:486-570`（rtughr / vghr）、`:788-800`（admission）|
| PCFIFO create 总线（含 `chk_idx[24:0]`）| `ct_ifu_top.v:111-130`、`ct_ifu_pcfifo_if.v:105-...` |
| retire 反馈端口 | `ct_ifu_top.v:166-176 / :302-312` |

> 注意：**本机所有 C910 版本的 PCFIFO 都是 `iu_ifu_pcfifo_full` + 2 条 create 总线**
> （`chk_idx[24:0]` 是其原生字段）；而 `rv32_ifu_top` 暴露的
> `credit + alloc0/1_token + cancel_vld/first_token`（以及 `iu_ifu_check_token`）
> **在本机 5 份 C910 树里都不存在**——连 "token" 一词都搜不到，是移植版自创的接口。
> 决策（B1/B2 + C1 补充原则）：**P2 照 C910 原生机制实现**，自创的 token 方案舍弃；见 6.2。

## 附录 C：TB 计数器清单

`tb/tb_miniRV_dpi.sv` 中 `ifdef USE_IFU` 的两段（`report_branch_stats` / `report_l0_stats` /
`report_bubble_stats`），全部只读、无副作用：

- **分支**：`n_cond/n_jmp/n_mispred/n_mis_cond/n_mis_jmp`、`n_cond_tpred/n_cond_taken/n_pt_nt/n_pn_t`、
  `n_cond_strong/n_cond_weak`（用 `ex_bht_chk[24]` 区分强弱 taken）、`n_retire/n_bubble/n_fill`。
- **L0**：`l0_lk/l0_hitn`（+按类型）、`l0_redirn`（`ifctrl_l0_btb_accept`）、`l0_ipn`、
  `l0_invn` + `l0_inv_entries`、`tr_v/tr_tk/tr_nt`（按类型）、`l0_updn/l0_mtchn/l0_allocn`
  （+按 taken 拆）、`l0_killn/l0_holdn/l0_firen`、`l0_sum_vld/l0_sum_cnt`、
  `ev_dir/ev_tgt/ev_typ`（+无命中项，三者与顶层 `l0_invalidate` 对账）、
  `b_mm/b_mm_fire/b_mm1`（选择优先级一致性）、`b_armed0`、`b_partial/b_consume`。
- **气泡**：`b_init/b_flush/b_stall/b_nofetch`（互斥，合计自检）、
  `b_raw_*`（不互斥原始计数）、`b_nf_reissue/b_nf_bpread/b_nf_frontend/b_nf_other`。
