# RV32I IFU 分支预测数据流与流水线规格（按控制流类型组织）

版本：v3.0，2026-09-21。v2.0 按预测器模块组织；v3.0 改为**按跳转指令类型**组织（条件分支 / JAL / JALR / AUIPC），每个类型内部依次给出：类型判定 → 数据流 → 逐拍时序 → 命中/未命中（或未知目标）→ 更新与训练 → 恢复。结构本身的组织方式（阵列布局、索引公式）都放在该类型实际用到的地方，跨类型的公共资源集中在 §0。
验证结论见 `verification_zh.md`；设计动机见 `RV32I_IFU_branch_prediction_rationale_zh.md`（那份有 ISA 编码速查）。

范围：本目录 `rtl/` 内 L0 BTB、主 BTB、Bi-Mode BHT、IND BTB、RAS 及连接层 `rv32_ifu_bp_top`。IF/IP/IB 控制、I-Cache、PCFIFO、LBUF 本体、SFP、后端不在此文档内。

---

## 0. 公共约定与共享资源

### 0.1 读法约定

- “拍 N”指一次 `forever_cpuclk` 上升沿之后的稳定周期，`N+1` 表示下一个上升沿之后可见。
- 所有顶层 `*_pc`、`*_target` 是 32 位字节地址，`PC[1:0]=0`。BHT 叶模块内部的半字坐标已在连接层转换，本文直接写成字节 PC。
- **组合输出**（L0 命中、RAS 栈顶、IND 的有效性判定）不经过寄存器，必须在同一拍捕获；**寄存输出**（主 BTB 结果、IND dout、BHT 快照）以“valid 脉冲 + 数据保持”给出，不是 ready/valid 握手。

### 0.2 共享资源一：L0 BTB 与主 BTB（目标表）

两张表都只存**目标与提示**，且在本层只为 JALR 提供目标——条件分支与 JAL 的目标由译码直接算（见 §1.2、§2.2）。它们的早期改向价值属于尚未实现的 IF 级控制。

```text
L0 BTB：16 项寄存器 CAM，项 = {valid, src[31:0], dst[31:0], kind[2:0], way[1:0], taken, use_ras}
主 BTB：row = PC[12:4]（512 行）  slot = PC[3:2]（4 槽）  tag = PC[31:13]
        每 bank {Tag 512×40, Data 512×68}，bank = slot[1]，每 bank 2 槽
```

**L0 查询（组合，同拍出结果）**

```text
命中条件： valid && !(directed_inv_mask && directed_inv_vld)
        && src[31:4] == PC[31:4]        // 同块
        && src[3:2]  >= PC[3:2]         // 位于本次入口槽及其之后
        && taken                        // 只有 taken 项才有资格改向
        && (!use_ras || ras_valid)      // 返回项要求旧栈顶真实可用
        && 目标[1:0] == 0               // 目标必须对齐
多候选取槽号最小者；无命中即 miss，同拍给出结论、不产生状态、不阻塞后续查询。
```

**主 BTB 查询（同步读）**

| 拍 | 动作 |
|---|---|
| N | `lookup_vld && lookup_ready` 接受：`rd_pc_q <= lookup_pc`，SRAM 读 `PC[12:4]` |
| N+1 | SRAM Q 返回，对 4 槽判命中 |
| N+2 | `result_vld` 脉冲一拍，`hit[3:0]/target[127:0]/way_hint[7:0]` 锁存，保持到下一次结果 |

```text
slot_eligible[s] = enable && s >= rd_pc_q[3:2] && rd_pc_q[1:0] == 0
slot_hit[s]      = slot_eligible[s] && (update_bypass || buffer_bypass || (tag_valid && tag == PC[31:13]))
```

- **被阻挡 ≠ miss**：`lookup_ready=0`（写缓冲占用单端口、未初始化、失效中、取消）时查询**未被接受**，发起方必须等 `ready`；不得当作未命中，也不得仅因 `ready=0` 丢弃。
- **真 miss**：入口槽及其之后四槽都不命中；不重发、不记录。

**两张表的更新（同一条数据流）**

```text
主 BTB：update_vld && update_ready（源与目标都对齐）→ 写缓冲（1 项）
        → 下一拍占用端口写 Tag/Data → 再下一拍起表内容更新
        旁路优先级：本次接受的更新 > 已有写缓冲 > SRAM 读结果
L0：    update_vld && enable && kind ∈ [1,3] && 源/目标对齐
        → 同源项原地写，否则写 replace_ptr 并圆形 +1（直接覆盖最老项）
        同拍 directed_inv_vld 清掩码命中的项 → 优先于更新，本拍写入不复活
```

`l0_directed_inv_vld` 不经 `frontend_ok` 门控（它描述已被证明过时的项，不是新的预测推进），但被全表失效覆盖。

### 0.3 共享资源二：RAS（调用/返回栈）

```text
TOP：12 项，项 = {filled, pc[31:0], priv[1:0]}，由前端推测 push/pop 维护
RTU：12 项物理存储按 rtu_write_ptr 与 ptr+6 交叉写，任一时刻只有最近 6 项构成“已提交有效后缀”
     rtu_available[2:0]（0..6）说明有多少项可被证明
top_ptr / rtu_ptr 为 5 bit（4 bit 索引 + 环绕位）；status_ptr 为溢出计数的参考指针
ras_empty = (top_ptr == status_ptr)      ras_full = (top_ptr == ~status_ptr[4],status_ptr[3:0])
```

RAS 自身不区分“哪种跳转”：它只接收 `ibctrl_ras_pcall_vld`（push）、`ibctrl_ras_preturn_vld`（pop）与 `ibdp_ras_push_pc`。**谁产生这两个脉冲取决于指令类型**——JAL/JALR 的 call 与 ret 形态，见 §2.3 与 §3.6。

### 0.4 查询是按“块”还是按“指令”触发的

这是最容易误解的一点：**不是每个 PC 都查所有表，也不是只有分支才查表**。四张表分成两类：

| 结构 | 触发信号 | 谁触发 | 触发频率 |
|---|---|---|---|
| L0 BTB | `l0_lookup_vld` | 外部 IF 控制（本层为输入） | **每个取指块** |
| 主 BTB | `btb_lookup_vld` | 外部 IF/IP 控制 | **每个取指块** |
| BHT 选择表 | `pcgen_bht_seq_read` / `pcgen_bht_chgflw` | IF | **每个取指块**（含顺序取指块） |
| BHT 方向表 | `ipctrl_bht_con_br_vld` | IP | **块内存在条件分支且该预测被接纳** |
| IND BTB | `ipdp_ind_btb_jmp_detect` | IP | **块内存在 JALR** |
| RAS 栈顶 | 组合常现 | — | 每个查询拍都可见，但只有 JALR/call/return 形态会使用它 |
| RAS push/pop | `ibctrl_ras_pcall_vld` / `preturn_vld` | IB 接纳事件 | 每个 call/return 形态的指令 |

**原因**：IF 级在取指当拍**还不知道块里有什么指令**，所以只能按 PC 查——“这里到底有没有控制流、跳到哪里”本身就是 BTB 要回答的问题；到了 IP 级已经译码，才知道“有没有条件分支”“有没有 JALR”，于是按指令查。这也解释了容量差异：每个块都要读的选择表只有 128×16，而只在有分支时才读的方向表是 1024×64。

三点补充：

- 查询单位是**取指块（16 B）**，不是每条指令：一次查询覆盖 4 个槽；块内后续分支靠槽序与 `more_br` 复用同一次读（§1.4）。
- **顺序取指块也会查** L0 / 主 BTB / 选择表（`pcgen_bht_seq_read` 就是“这一块顺序走”的触发）；只有方向表必须等到确认存在条件分支。
- 恢复/flush 也会读方向表（`bju_mispred`、`rtu_ifu_flush`、`local_recover_vld`），但那是为了修复状态与重建偏移，不是为某条分支做预测。
- 因为按块查询，“块里其实没有控制流但表命中”是可能的（陈旧项/假命中）→ 由 ADDRGEN 定向失效与 IP/IB 校正处理，而不是靠查询端预判。

---

## 1. 类型一：条件分支（B 型）

`opcode = 1100011`，`funct3 ∈ {000,001,100,101,110,111}`（BEQ/BNE/BLT/BGE/BLTU/BGEU）。
**目标可算（`PC + imm_b`，±4 KiB），方向不可算** → 方向靠 BHT，目标靠译码。

### 1.1 参与的预测资源

| 资源 | 在本类型中的作用 |
|---|---|
| BHT 选择表 + 方向表 | 提供方向预测，并给出历史快照 `chk_idx` |
| 主 BTB / L0 | 只提供“这里有一条控制流”的早期信息与 Way 提示；**本层不用它们取目标** |
| RAS | 不参与（除非该分支的源被误判为 call/return，见 §1.6） |

### 1.2 数据流

```text
IF  拍 N   pcgen_bht_seq_read/chgflw + if_pc ─► 选择表读（索引 if_pc[13:7]）
拍 N+1     选择表 Q（8 个 2bit 计数器）→ 按 if_pc[6:4] 选一 → sel_result
IP         ipctrl_bht_con_br_vld + VGHR ─► 方向表读
           索引 = {VGHR[11:8], VGHR[7:2]^VGHR[19:14]}      ← 只含历史，不含 PC
拍 +1      方向表 Q（32bit = 16 个 taken 计数器 + 16 个 not-taken 计数器）
           offset = PC[7:4] ^ VGHR[3:0] → 16 选一 one-hot
合成       bht_selected  = sel_result[1] ? taken行 : ntaken行
           bht_counter   = one-hot 与 32bit 行数据做 16 选一（每项 2bit）
           bht_pred      = cp0_ifu_bht_en && bht_counter[1]
           bht_chk_idx   = {bht_counter[0], sel_result[1:0], VGHR[21:0]}      // 25bit
目标       bp_target：cf_type=1 → pred_taken = bht_pred
                                  pred_npc   = bht_pred ? (PC + imm_b) : PC+4
                                  recorded_target = PC + imm_b（恒定，供 PCFIFO 比对）
```

**BHT 没有 hit/miss**：两张表在初始化完成后恒定返回有效内容（taken 计数器初值 `2'b11`、not-taken 初值 `2'b00`、选择计数器初值 0），不存在“未命中”分支。正确性是统计量，不是结构事实。

### 1.3 逐拍时序

| 拍 | IF 侧 | IP 侧 |
|---|---|---|
| N | 发起选择表读；`ifctrl_bht_stall` 会阻止 `sel_rd_q` 置位（该次读不计为一次有效获取） | — |
| N+1 | `sel_rd_q=1` → 选择表数据可用 | 若有 IP 条件分支：发起方向表读 |
| N+2 | — | 方向表数据可用；`ifctrl_bht_pipedown` 时锁存 `sel_array_result / pre_array_data / offset_onehot / vghr` |
| 同上 | — | `bht_pred`/`bht_chk_idx` 组合产生，必须与源 PC 同拍被锁存 |

### 1.4 同块多条件分支

- `ipctrl_bht_more_br=1`：偏移的 PC 项改用 `ip_pc[7:4]`、历史项改用 `{VGHR[2:0], 本分支预测方向}`，选择值沿用上一拍锁存的 `sel_array_result`（同一块的选择模式不变）。
- 每条分支的 VGHR 追加**恰好一次**，绑定其“预测被接纳”事件（`ipctrl_bht_con_br_vld` / `lbuf_bht_con_br_vld`）；重发、反压、同块后缀处理都不得重复追加。
- 预测 taken 时其后缀被截断：被截掉的槽不追加历史、不创建 PCFIFO。

### 1.5 目标不可用

```text
bad_target = |(PC + imm_b)[1:0]| ≠ 0        // 不对齐
此时：pred_taken 仍输出方向判定，但 pred_npc 保持 PC+4 → 前端不改向
异常（instruction-address-misaligned）归因于源分支指令，由后端按序确认
```

**消费方必须同时看 `pred_taken` 与 `bad_target`/`target_unknown` 才能决定是否改向**——只看 `pred_taken` 会在目标非法时错误改向。前端绝不允许自行把 bit1 清零凑一个对齐目标。

### 1.6 更新与训练数据流

```text
iu_ifu_bht_check_vld + iu_ifu_chk_idx[24:0]
  └─ 拆分：pred_rst={iu_ifu_bht_pred, chk_idx[24]}   sel_rst=chk_idx[23:22]   ghr=chk_idx[21:0]
       ├─ admission：pred_rst 饱和且方向相同 → 方向表不更新
       │              sel_rst 饱和 或 Bi-Mode 模式抑制成立 → 选择表不更新
       └─ 训练条目 {真实方向, sel_rst, pred_rst, ghr, 源 PC[13:4]}
            ├─ 有旧条目或读端口忙 → 入 4 项缓冲（按序退休）
            ├─ 缓冲满 → 丢弃本次训练，bht_train_drop 拉高一拍，计数递增（饱和）
            └─ 无旧条目且端口空闲 → 当拍写表
表写掩码：方向表在 offset 指向的那一对计数器中写 2bit；选择表在 PC[6:4] 指向的那一项写 2bit
读出旁路：下一次读命中同一 (行索引, 历史快照) 的缓冲条目 → 用缓冲值覆盖 SRAM 读数
```

主 BTB / L0 也要为条件分支建项（kind=1，含 taken 与 Way），供未来 IF 级早期改向使用；写入的是**已校验**事件。

### 1.7 恢复

```text
优先级：rtu_ifu_flush > iu_ifu_chgflw_vld（±同拍 check） > local_recover_vld > LBUF > 普通 IP
chgflw + 同拍 check  → VGHR := {chk_idx历史[20:0], 本分支真实方向}
chgflw 无 check      → VGHR := chk_idx历史[21:0]
local_recover_vld    → VGHR := 外部给出的已保留前缀精确历史（不带范围判断）
```

被取消的后缀不得留下历史；只修复 VGHR 而不修复 PC 是无效的，反之亦然（两者必须同源同拍）。

---

## 2. 类型二：JAL（J 型，恒定 taken）

`opcode = 1101111`。**目标可算（`PC + imm_j`，±1 MiB），方向恒为 taken** → 不需要方向预测；目标是算术，不需要从表里取。

### 2.1 类型判定与目标

```text
cf_type = 2；direct_target = PC + imm_j；link_pc = PC + 4
call 形态：rd ∈ {x1, x5} → ras_push（见 §2.3）
非 call：rd = x0（伪指令 j）→ 无 RAS 动作
```

### 2.2 数据流

```text
bp_target：pred_taken = 1（恒定）
           pred_npc   = bad_target ? PC+4 : direct_target
           recorded_target = direct_target
           bad_target = |direct_target[1:0]| ≠ 0
```

即：**JAL 的改向不依赖任何预测表**（要么直接改向，要么因目标非法而拒绝改向并让后端报异常）。

**那么为什么 JAL 还要写进 L0/主 BTB？** 因为未来 IF 级在译码之前不知道某个位置是 JAL，需要“这里有一条控制流、目标是 X”的早期信息才能同拍改向。本层已经把这类项与 Way 提示准备好（kind=2），但早期改向本身属于未实现的 IF 控制。

### 2.3 call 形态的 RAS push 数据流

```text
IB 接纳该 JAL（前缀已确认）─► ibctrl_ras_pcall_vld（+ for_gateclk）
                              ibdp_ras_push_pc = 源 PC + 4    ← 由流水提供，不是 RAS 自己算
RAS：top_write_ptr = (push && pop && !empty) ? top_ptr-1 : top_ptr
     写该项 {pc:=ibdp_ras_push_pc, priv:=当前特权, filled:=1} → top_ptr+1（环形）
     满栈时 status_ptr 环形 +1（记录被覆盖的最老项，使之后的空栈判定正确推进）
供 L0：ras_l0_btb_ras_push / ras_l0_btb_push_pc（源 PC+4）→ 更新 L0 的 use_ras 项
```

推测 push 只绑定“IB 接纳 call”这一事件；停顿时不得重复 push。该 push 同时被记录进 RTU 备份（退休时 `rtu_ifu_retire0_pcall` + `retire0_inc_pc`）。

---

## 3. 类型三：JALR（I 型，间接）

`opcode = 1100111`，`funct3 = 000`。**目标依赖寄存器值，前端算不出来** → 必须查表/查栈；方向恒为 taken。

### 3.1 三个子形态（决定用哪条目标通路）

| 子形态 | 判定（rd / rs1 相对 x1、x5） | 典型写法 | 目标通路 | RAS 动作 |
|---|---|---|---|---|
| call | rd ∈ {x1,x5}，rs1 非链接寄存器 | `jalr x1, 0(x5)` | IND BTB → 主 BTB | push（PC+4） |
| ret | rs1 ∈ {x1,x5}，rd 非链接寄存器，`imm == 0` | `ret` = `jalr x0,0(x1)` | **RAS 旧栈顶（最高优先）** | pop |
| ret（非零偏移） | rs1 ∈ {x1,x5}，`imm ≠ 0` | `jalr x0, 8(x1)` | IND BTB → 主 BTB | pop（提示仍有效，但栈顶不能直接用） |
| jr | rd = x0，rs1 非链接寄存器 | `jr x5`（跳转表、函数指针） | IND BTB → 主 BTB | 无 |
| 同寄存器 | rd = rs1 ∈ {x1,x5} | `jalr x1, 0(x1)` | IND BTB → 主 BTB | 本版只按 call 处理（**不使用栈顶**） |

### 3.2 目标仲裁数据流

```text
bp_target：cf_type=3
  优先级 1：ras_usable && ras_valid   → chosen = ras_target（= ras_l0_btb_pc，pop 前栈顶）
  优先级 2：ind_valid                 → chosen = ind_target
  优先级 3：btb_valid                 → chosen = btb_target
  都没有：  target_unknown = 1，pred_taken = 0，pred_npc = PC+4
  chosen 非对齐：bad_target = 1，target_unknown = 1，pred_taken = 0
  有效：    pred_taken = 1，pred_npc = recorded_target = chosen
```

### 3.3 逐拍时序（三条通路各有自己的延迟）

| 通路 | 发起 | 数据 | 可消费 |
|---|---|---|---|
| RAS 栈顶 | 同拍组合 | 同拍 | 同拍（含空/特权/filled 判定） |
| 主 BTB | `vld && ready` 接受 | +1 拍 | **+2 拍** `result_vld` 一拍，数据保持 |
| IND BTB | IP `ipdp_ind_btb_jmp_detect` | +1 拍（SRAM Q） | **+2 拍** `ind_result_vld` 一拍 |

```text
IND 两拍细节：拍 M detect → M+1 SRAM Q → M+2 dout 锁存 + priv_mode_q 锁存 + ind_result_vld
被杀条件（不产生 result_vld）：cancel、表失效中、path_reg_rtu_updt（flush/retire0 误预测）、retire0 目标更新
ibctrl_ind_btb_fifo_stall 期间不发起读（“等待中”≠“未命中”）
```

### 3.4 命中判定与“未知目标”

```text
IND 有效： ind_result_vld
        && dout[34]（项 valid）
        && dout[33:32] == 当前特权      // 项内特权
        && priv_mode_q == 当前特权      // 本次读发生时的特权（读时锁存）
        && dout[1:0] == 0              // 目标 4 字节对齐
miss（三张通路都没有可用结果）或目标非法 → target_unknown=1
  → 前端不改向：按顺序路径继续取指
  → 后端按真实 rs1 执行该 JALR，必然产生一次执行级 misprediction 并重定向
  → 该次误预测在 retire0 时成为 IND BTB 的训练事件（§3.5）
```

**这就是间接跳转的“第一次必错”**：任何从未见过的 JALR 都不可能被预测对，设计上接受这一点，把代价限制在“一次重定向 + 一次训练”，而不是让前端停下来等。

### 3.5 更新与训练数据流

```text
推测路径：ibctrl_ind_btb_check_vld（IB 真正接纳该 JAL/JALR 前缀）
          → path_reg[3:1] <= path_reg[2:0]，path_reg[0] <= ib_pred_target[11:4]
          必须与同一实例的 ib_pred_target 配套；“发起查表”不等于路径推进
提交路径：三路退休 jmp 按 retire0→1→2 压入 rtu_path_reg[3:0]（8 种组合逐一处理）
路径恢复：rtu_ifu_flush 或 retire0_mispred → path_reg <= rtu_path_reg
训练：    rtu_ifu_retire0_jmp_mispred
          → 写索引 = rtu_path_reg 与 RTUGHR[7:0] 的异或
          → 写数据 = {1'b1, 当前特权, retire0_next_pc}
          写优先于读；写期间不发起读
读索引：  {path_reg[7:6]^GHR[7:6], path_reg[5:4]^GHR[5:4], path_reg[3:2]^GHR[3:2], path_reg[1:0]^GHR[1:0]}
```

训练入口**只有** `retire0_jmp_mispred`：执行级才知道真实目标，而退休点才知道它是否在正确路径上。

### 3.6 ret 子形态的 RAS 数据流与恢复

```text
查询（组合）：
  top_ptr → 12 选一 → {ras_pc_out, ras_filled, ras_priv_mode}
  ras_top_valid     = !ras_empty && ras_filled && ras_en && (当前特权 == 项特权)
  ras_l0_btb_pc     = ras_pc_out                    // L0 的 use_ras 项与 bp_target 都取这里
  ras_ipdp_data_vld = ((!ras_empty && ras_filled && 特权匹配) || ras_push) && ras_en
  ras_ipdp_pc       = ibctrl_ras_inst_pcall ? ibdp_ras_push_pc : ras_pc_out
pop：ibctrl_ras_preturn_vld → top_ptr-1（空栈时不变）
     与 push 同拍：top_write_ptr 取 top_ptr-1，使新 PC 覆盖被弹出的项（深度不变）
恢复：rtu_ifu_retire0_mispred || rtu_ifu_flush
     → top_ptr := rtu_ptr；status_ptr := 回退到最老可证明项
     → TOP 每项：在 6 项备份范围内则从 rtu_entry 重载 pc/filled/priv，否则 filled := 0
```

**恢复只发布 6 项备份能证明的已提交后缀**；深层返回在恢复后可能落到 IND BTB 或后端校验，这是本版明确的性能折中。恢复期间 `iu_ifu_mispred_stall=1`：本层阻止推测 push/pop、IND 读与路径推进，并屏蔽相关输出，但退休更新继续；直到误预测源退休（或被更老的全 flush 取代）才解除。

---

## 4. 类型四：AUIPC（U 型，PC 相关但不改向）

`opcode = 0010111`。**它不改变取指流**，但结果依赖自身 PC。

```text
bp_decode：pc_oper=1，cf_type=4，dst_vld = (rd != x0)
bp_target：落到 case default → pred_npc = PC+4，pred_taken = 0，
           target_unknown = 0，bad_target = 0，recorded_target = PC+4
预测器更新：无。不查 L0/主 BTB，不进 L0 的 kind 集合（kind 只取 1..3），
           不追加 VGHR，不创建方向快照
```

它仍然要占用 `pc_oper` 配额（每拍最多 2 项创建 PCFIFO）与后端校验资源，因为后端需要它的 PC 才能计算/校验 `rd = PC + imm<<12`。**把“PC 相关”与“改控制流”混为一谈**，会导致两类错误：要么把 AUIPC 当成跳转去预测（污染历史与表），要么不记录它的 PC（后端无法校验）。

一个典型的“同块多 AUIPC”情形：`AUIPC0, AUIPC1, AUIPC2, ADDI3` —— 没有任何条件分支，却需要 3 个 pc_oper 记录，超过每拍 2 项的上限，必须分段处理。

---

## 5. 跨类型的公共通路

### 5.1 门控与输出有效位（`bp_top`）

```text
frontend_ok = bp_init_done && !frontend_cancel && !maint_fire
              && !rtu_ifu_flush && !iu_ifu_chgflw_vld && !local_recover_vld
  → 门控所有“新前端事件”：L0/主 BTB 查询与更新、BHT 读/推进/历史追加、
    RAS 推测 push/pop、IND 读发起与路径推进、LBUF 路径
  → 不提供回滚值：撤销已追加历史必须同时给 local_recover_ghr

输出有效位：ras_top_valid / ras_ipdp_data_vld / ind_result_vld
            = 原始有效 && frontend_ok && !bp_recovery_stall
ind_target_valid = ind_result_vld && 项 valid && 两次特权比较 && 目标对齐
bp_recovery_stall = iu_ifu_mispred_stall      // 为 1 时阻断推测 RAS/IND 推进，退休更新继续
```

### 5.2 初始化与维护状态机

| 状态 | 行为 |
|---|---|
| 0 → 1（复位后立即） | 全表失效：`active_mask=5'b11111`，BHT/IND/RAS 清空、主 BTB 与 L0 扫描 |
| 1 → 2 | BHT/IND 失效完成、主 BTB 扫描完成 → `bp_init_done=1`，各类型查询通路开始可接受事件 |
| 2 | 空闲；`bp_maint_ready = !rtu_ifu_flush && !iu_ifu_chgflw_vld` |
| 2 → 3 → 4 → 2 | 维护：锁存 mask → 按位失效 → BHT/IND/RAS 同时按提交边界做一次恢复 → `bp_maint_done` 单拍脉冲 |

mask 位序 `[0]=L0, [1]=主 BTB, [2]=BHT, [3]=IND BTB, [4]=RAS`；零 mask 等价于“只做提交边界恢复”。

### 5.3 快照与恢复的公共规则

1. `bht_pred`/`bht_chk_idx`、`bht_ipdp_pre_array_data_{taken,ntaken}`、`bht_ipdp_pre_offset_onehot`、`bht_ipdp_sel_array_result`、`bht_ipdp_vghr` 必须**整组同拍锁存**，再与源 PC 和 PCFIFO token 绑定。
2. VGHR 与 RTUGHR 分属推测/提交两套历史：前者按预测推进与修复，后者按 retire0→1→2 程序顺序追加（一次最多 3 个真实方向）。
3. `local_recover_vld/ghr` 只提供“已保留前缀的精确历史”，不判断撤销范围；`frontend_cancel` 只阻止本拍新事件，本身不带回滚值。
4. 恢复优先级：RTU flush > IU chgflw > local_recover > LBUF > 普通 IP。
5. 训练丢失（`bht_train_drop`）是性能事件，不得影响恢复、RTUGHR 追加、路径推进。

### 5.4 时序汇总（按类型标注）

| 通路 | 发起 | 数据 | 可消费 | 属于哪个类型 |
|---|---|---|---|---|
| L0 查询 | N | 同拍 | 同拍 | 三类跳转的早期信息（本层不取目标） |
| L0 更新 | N | — | N+1 可见；定向失效同拍优先 | 条件分支 / JAL / JALR |
| 主 BTB 查询 | N（`vld && ready`） | N+1 | N+2 `result_vld` 一拍，数据保持 | JALR（本层唯一取目标的类型） |
| 主 BTB 更新 | N | — | N+2 表更新，同拍旁路 | 三类跳转 |
| BHT 选择表读 | N（IF） | N+1 | pipedown 拍锁存 | 条件分支 |
| BHT 方向表读 | N（IP） | N+1 | pipedown 拍锁存 | 条件分支 |
| BHT 表写 | 缓冲退休拍 | — | 下一拍可见 | 条件分支 |
| IND 读 | M（detect） | M+1 | M+2 `result_vld` 一拍 | JALR（间接） |
| IND 写 | N（retire0 误预测） | — | N+1 可见 | JALR（间接） |
| RAS 栈顶读 | 同拍 | 同拍 | 同拍 | JALR 的 ret 形态（+ L0 返回项） |
| RAS push | N（IB 接纳 call） | — | N+1 可见 | JAL / JALR 的 call 形态 |
| RAS 恢复 | 退休/flush | — | 同拍生效 | ret 形态 |

---

## 6. 待定集成契约

TODO(human)

要求：用 2–10 行写清查询被阻挡时的重试与取值契约，覆盖：

- 主 BTB `lookup_ready=0`（写缓冲占端口）时，IF/IP 由谁保持查询、可保持多少拍、是否允许丢弃；对 JALR（本层唯一用它取目标的类型）这意味着什么；
- L0 组合命中与同拍 `l0_update`/`l0_directed_inv` 的一致性要求（命中结果是否必须与发起拍的表内容对应）；
- IND `result_vld` 到来前若发生局部改向/flush，IB 侧需要满足的最小检查。
