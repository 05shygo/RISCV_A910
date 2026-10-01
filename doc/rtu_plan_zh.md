# 退休单元（RTU）实现计划 —— 以 C910 为蓝本，规模对标 `cpu` 参考核

> 对象：把 `mySoC/` 从"5 级顺序单发射"改造成"乱序 3 发射超标量"，
> 本文件只覆盖**退休单元**这一块（ROB / 寄存器状态与恢复 / 异常 / 冲刷）。
> 蓝本 = `open_riscv_2035/.../rtu/rtl/`（玄铁 C910，实测 35 635 行）；
> 规模基准 = `/x2025/.../cpu/src/ROB.v`（参考核，642 行）。
>
> 材料来源：`doc/c910退休单元分析.txt`（本文引用为"分析文档"）+ C910 原码核对
> + `cpu/src` 参考核原码 + 本核现状。**凡是标了行号/位宽的数字都是从 RTL 里抠出来的，
> 不是从分析文档转抄的。**

---

## 0. 一句话结论

**把 C910 的"三级指针 + 退休窗口 + 逐 preg 状态表 + 最旧门控的执行级重定向"这套骨架
搬过来**，砍掉三样东西：快速退休、指令折叠（cmplt_cnt）、96 项 5 态状态机
（换成 96×2 bit 四态 + 32×7 的架构映射表）。
**`read_entry` 中间级反过来要照抄** —— 见 D5 与 §4.2。

关键分裂：**重定向快的走执行级（只允许最旧的分支发），训练准的走退休点。**
两者的分工见 D1，是本计划承重最大的一条。

**两条硬约束**（决定了后面几乎所有取舍）：

1. **时序不许变差**：Vivado 布局布线后 **Fmax ≥ 183.9 MHz**（基线 = 现在的默认
   配置，5.6 ns 点 WNS ≥ 0 = 183.9 MHz；报告尚未入库，见 §4.2 的 ⚠️）。为此 `read_entry` 影子表项（D5）、
   `WF_ALLOC` 打拍（D2）、`iid_oldest` 并行算（D12）都是**必做项**，不是优化项；
   §4.2 列了基线、当前瓶颈、8 条新路径与对策。⚠️ **本机没有 Vivado，这条要外跑。**
2. **省资源 —— 但排在时序后面**：省要省在**不碰关键路径**的地方。
   退休级要用的字段（`pc`/`target`/`chk`/`dst_preg`/`old_preg`）一位不砍；
   只在 CSR 退休时用的字段（约 26 bit/项）抽成单槽，省 ≈1.5 Kb（§4.3）。
   **判据是"这个字段在哪条路径上被消费"，不是"能省多少"。**

目标是 **≤ 1500 行 RTL**，ROB 表项约 **122 bit** × 64 项 ≈ **7.8 Kb** 触发器
（外加 `read_entry` 影子表项 360 bit + CSR 槽 26 bit）。

---

## 1. 目标与边界

### 1.1 本核现状里已经为乱序准备好的东西（重要）

| 已有 | 位置 | 对 RTU 的意义 |
|---|---|---|
| 前端一拍出 **3 条**指令（`idu_inst0/1/2_*`） | `ifu2/rtl/rv32ifu2_top.v` | 3 发射的取指带宽已经在了；现在核只消费 1 条（`idu_accept_num = if_accept ? 2'd1 : 0`） |
| 前端有 `rtu_flush / rtu_chgflw_vld / rtu_chgflw_pc` 三个口 | 同上 | 继续给**异常/中断/`mret`** 用（它们本来就在退休点裁决）；误预测**不走这条**，走 `iu_ifu_chgflw_*`（见 D1） |
| 前端有 `iu_chgflw_vld / iu_chgflw_pc`（现在是 EX 级误预测重定向） | `mycpu.v:833-834` | **误预测重定向留在这条**，只加"最旧门控"；`pc` 已经是 `actual_npc`，与 ifu2 约定天然对齐 |
| **预测器快照随指令走**：`idu_inst*_chk`（25 bit，含 GHR 快照 / ras_ptr / 三个归因位） | 同上 | 退休点**重训练**需要的 `chk` 有现成格式，**直接存进 ROB 表项**即可（重定向本身不需要它） |
| 重定向/训练时按 `chk` 修复 GHR/RAS 的通路 | `rv32ifu2_top.v:894` | 同一条路可复用，但**驱动源要换**：现在喂进去的是 `iu_btb_chk`（= EX 级当拍那份），重训练搬到退休点后必须由 RTU 用**表项里存的那份 chk** 驱动（见阶段 4b） |
| 提交点已经是一个明确的裁决点（WB），有完整的异常/中断/`mret` 语义 | `mycpu.v:213-232`、`CORE_DESIGN.md §4` | 退休单元要做的正是**把这个裁决点从"WB 这一级"换成"ROB 头部窗口"** |

### 1.2 退休单元负责什么

1. **ROB**：按派遣顺序建表项、按 iid 收集完成情况、按程序序退休。
2. **寄存器状态与恢复**：物理寄存器的分配/释放/回滚，架构映射表（AMT），冲刷时把映射表还给重命名级。
3. **异常与中断的裁决**：只有最旧的指令能进入陷阱；`mepc/mcause/mtval` 的产生。
4. **流水线冲刷**：误预测、异常、中断、`mret` 四类重定向 + 冲刷状态机。
5. **提交点副作用**：store 真正写内存、CSR 真正写、寄存器写回对外可见（difftest）、`instret` 计数。

### 1.3 不负责（但接口必须现在定死）

重命名、发射队列、物理寄存器堆、LSU 的乱序访存。这些是**别的计划**，
但本计划第 6 节会把它们与 RTU 的契约写清楚 —— 接口一变，RTU 就得重写。

---

## 2. 蓝本对照

| 维度 | C910（实测） | 参考核 `cpu` | **本核（建议）** |
|---|---|---|---|
| ROB 深度 | 64（`rob_create0_ptr[63:0]`，64 个 entry 例化） | 64（`rob_valid[0:63]`） | **64** |
| 派遣宽度 | 4（create0..3） | 2 | **3**（前端一拍最多 3 条） |
| 退休宽度 | 3（read0..2 / pop0..2） | 2 | **3** |
| iid 位宽 | 7（6 位索引 + 1 位回绕） | 6（直接当索引用） | **7** |
| 物理寄存器 | 96（7 bit，`x_rel_preg_expand[95:0]`） | 64（6 bit） | **96**（32 架构 + 64 自由） |
| 重命名恢复 | PST 96 项 × 5 态状态机 + recover table | 4 份快照（每份整个 RAT + free head） | **96×2 bit 四态 + 32×7 AMT** |
| 重定向时机 | **执行级**：最旧的待解析分支在 EX2 直接发 IFU（`ct_iu_bju.v:1008`，不经 RTU）；退休点只做**重训练**（`rtu_ifu_retire0_*`） | **执行级**（`jump_flag_i` + 掩码清 `rob_valid`） | **执行级 + 最旧门控**（见 D1） |
| 快速退休（先退休后写回） | 有（`retired_reg_wb`） | 无 | **不做** |
| 指令折叠 `cmplt_cnt` | 有 | 无 | **不做** |
| 头部读结构 | `read_entry` 中间级（3 份寄存副本） | 静态信息放异步读 RAM（80b×32×2 bank） | **`read_entry` 中间级**（D5，按时序约束必做） |
| 异常收集 | `expt_entry` 70 bit 单项，按 iid 判最旧者胜 | 提交级现算 | **`expt_entry` 精简版（约 45 bit）** |
| 冲刷 FSM | 7 态两段式（FE/IS × BE） | 掩码清 + 恢复 wr_ptr | **2~3 态** |
| RTL 规模 | 35 635 行（整个 `rtu/`） | 642 行（ROB.v 一个文件） | **≤ 1500 行** |

**关键观察：本核与 C910 的发射宽度一致（3），退休窗口宽度直接照抄 3 即可 ——
这一点上不需要做任何折衷。**

---

## 3. 关键设计决策

下面每一条都是"会牵动全局、事后改代价很大"的选择。**决策 = 建议选的那条。**

### D1 重定向时机：**最旧指令在执行级发出**，恢复靠架构映射表（不做快照）★最重要

> ⚠️ **这一节写过一版错的，已按 RTL 推翻重写。** 教训记在最后。

先给结论：**重定向从执行级发出（不由 RTU 的退休级发出），但只有"最旧的待解析分支"能发**；
恢复不靠快照，靠架构映射表（AMT）。这两件事必须同时成立才自洽。

#### 从 RTL 抠出来的三条事实

**① 重定向是 IU 直连 IFU 的，根本不经 RTU。**（`iu/rtl/ct_iu_bju.v:1008`）

```verilog
assign iu_ifu_chgflw_vld = ex2_pipe2_chgflw_vld;      // → IFU pcgen 的高优先级 pcload
assign iu_ifu_chgflw_pc  = {ex2_pipe2_tar_pc_msb, ex2_pipe2_tar_pc};   // 真实目标
assign iu_ifu_chk_idx    = ex2_pipe2_chk_idx;         // 快照索引也同拍给
assign iu_yy_xx_cancel   = ex2_pipe2_chgflw_vld;      // 同时取消 IDU
```

**② 退休级那根 `chgflw` 与 mispred 无关**（`rtu/rtl/ct_rtu_retire.v:1576`）：

```verilog
retire_ifu_chgflw_vld <= retire_inst0_inst_flush;   // 只由 inst_flush 驱动
assign retire_inst0_flush   = retire_expt_vld || retire_inst0_inst_flush
                            || dbgreq_ack || retire_async_expt_vld;      // ← 没有 mispred
assign retire_inst0_mispred = retire_inst0_normal_retire && (jmp_mispred || bht_mispred);
```

`retire_inst0_inst_flush` 来自 `expt_entry` 的 `flush` 位（fence.i / cache 维护类），
**不是误预测**。退休点的 `rtu_ifu_retire0_mispred / _next_pc / _condbr_taken` 是
**重训练**信号（防错误路径污染 BHT/BTB/RAS），不是纠错路径。
一句话：**重定向快的走执行级，训练准的走退休点。**

**③ IDU 的重命名表没有回滚历史**（`idu/rtl/ct_idu_ir_rt.v:2431`）：

```verilog
assign rt_recover_updt_vld = ifu_xx_sync_reset || rtu_yy_xx_flush;
assign rt_recover_updt_preg = ifu_xx_sync_reset ? 初始映射 : rtu_idu_rt_recover_preg;
```

`rtu_yy_xx_flush`（= FLUSH_BE 单拍脉冲）到来时**整张 32×7 表被 RTU 的架构映射表覆盖**，
没有任何按分支的历史/快照。**这就是"不需要快照"的确证。**

#### 由三条事实推出的设计约束

架构映射表只反映**已退休**的映射。若某个分支在"还有比它更老的指令在飞"时就重定向，
那些更老指令的重命名会随着整表覆盖而丢失 —— 要么核会算错，要么它们必须被一起冲掉
（那就会跳过它们，同样算错）。**所以：重定向点必须等于"最旧的非退休指令"。**

C910 让这件事成立的手法是把重定向**放在最旧那条指令自己的执行级**上发，
而不是等它走完退休级：

* 它比自己走完 `read → retire → 状态机 → 发信号` 早若干拍；
* 又比"任何分支都能提前重定向"省掉整套快照。

门控在 BJU 里（`ct_iu_bju.v:752`）：

```verilog
assign bju_older_inst_vld = ex1_pipe2_inst_vld && ex1_pipe2_iid_oldest;
assign bju_chgflw_vld     = bju_mispred && !rtu_iu_flush_chgflw_mask && bju_older_inst_vld;
```

> ❓ **留一个待核项**：`ex1_pipe2_iid_oldest` 我只追到它与"上一个待处理误预测的 iid"
> 做年龄比较（`bju_rf_older_ex1` / `bju_rf_older_mispred`，注释是"new mispred could be
> generated only when it is older"），**没找到它同时与 ROB 退休指针比较的证据**。
> 由 ②③ 反推，它必须等价于"最旧"才自洽 —— 实现阶段若发现 C910 还另有更老指令存活的路径，
> 这条要在本核补一个显式的 `iid_oldest` 门控（见下）。

#### 本核的落地方式

**选"执行级发出 + 最旧门控"**，比纯退休点重定向快，又完全不需要快照：

| | 本核方案 | 纯退休点 | 任意分支提前重定向 |
|---|---|---|---|
| 恢复机制 | AMT 整表覆盖（同 C910） | 同左 | 需要 N 份快照 + 用尽停顿 |
| 重定向发出者 | **BEU（执行级）** | RTU 退休窗口 | BEU |
| 门控 | `rtu_beu_iid_oldest` | 天然成立 | 无 |
| 额外接口 | RTU → BEU：退休指针 / `iid_oldest`；RTU → BEU：`flush_chgflw_mask` | 无 | 快照读写 |

新增两条接口（都已进了 §6）：

```verilog
output [6:0] rtu_beu_retire_iid;      // ROB 的 pop iid, BEU 拿它比出 iid_oldest
output       rtu_beu_flush_chgflw_mask;  // 冲刷期间屏蔽再次重定向(对应 rtu_iu_flush_chgflw_mask)
```

> ⚠️ **别把 `target` 塞进 RTU 的重定向路径**：重定向 PC 由 BEU 直接送 IFU，
> 走的是 `actual_npc`（与现有 `mycpu.v:834` 的 `iu_ifu_chgflw_pc` 同源，**接口天然对齐**）。
> ROB 表项里的 `target` 只服务于**退休点重训练**（对应 C910 的 `rtu_ifu_retire0_next_pc`）。

#### 这一节写错过的教训（留给下次）

我第一版读到 `retire_inst0_mispred = retire_inst0_normal_retire && (...)` 就断定
"C910 等退休才重定向"，**只看了一根信号的门控，没去看这根信号的消费者是谁**。
`retire_inst0_mispred` 驱动的是**冲刷状态机**（清后端 + 重训练），
而真正的 IFU 重定向在同一颗芯片的另一个目录（`iu/`）里，根本不经过 `rtu/`。
**下次判断"某个动作在哪一拍发生"，要顺着信号的消费者走到尽头，而不是只看它的产生条件。**

### D2 寄存器状态与恢复：四态表 + AMT，不用 C910 的 5 态机

C910 的 `ct_rtu_pst_preg_entry.v`（577 行，例化 96 次）每个 preg 存
`lifecycle_cur_state[4:0]`（独热 5 态）+ `create_iid/create_dst_reg/create_rel_preg`
+ `iid/dst_reg/rel_preg` + 3 个 `retire_inst*_iid_match` 比较器。整个
`ct_rtu_pst_preg.v` 8 637 行。

**本核砍成四态**（不做快速退休、不做折叠，所以 `RETIRE` / `RELEASE` 两态可以合并）：

```verilog
// 每个 preg 2 bit，共 96×2 = 192 bit 状态
localparam P_FREE  = 2'd0;   // DEALLOC: 在自由池里，可被分配
localparam P_WFALLOC = 2'd1; // WF_ALLOC: 已被【选中】，等下一拍派遣确认
localparam P_ALLOC = 2'd2;   // 已分配给在途指令（推测态）
localparam P_ARCH  = 2'd3;   // 已是架构态（某个逻辑寄存器的当前映射）
```

> ⚠️ **`WF_ALLOC` 不是多余的簿记，它是给分配器打拍用的 —— 不能砍。**
> 96 位三端口优先编码器是 7 级左右的组合深度，直接串在"派遣 → 分配 →
> 更新状态"这条链上会把派遣拍压垮。C910 的做法是把它切成两拍：
> 第 1 拍只做选择（`DEALLOC → WF_ALLOC`），第 2 拍派遣确认时才落
> `WF_ALLOC → ALLOC`（`ct_rtu_pst_preg_entry.v:288-295`）。
> **时序优先的前提下，这个状态必须留着。**

转移表（**这就是全部**）：

| 事件 | 动作 |
|---|---|
| 优先编码选中 | 本拍选中的 preg：`FREE → WF_ALLOC`（**第 1 拍，只做选择**） |
| 派遣确认 | 被派遣的 preg：`WF_ALLOC → ALLOC`（第 2 拍；没派成/被冲刷则回 `FREE`） |
| 指令退休 | 新 preg：`ALLOC → ARCH`；`old_preg`（且 `old_preg >= 32`）：`ARCH → FREE` |
| **冲刷** | **所有 `ALLOC` 与 `WF_ALLOC` → `FREE`**（每个 preg 各看各的，一拍并行，不需扫描） |
| 复位 | `p0..p31 = ARCH`（x0..x31 的初始映射），`p32..p95 = FREE` |

**"冲刷时所有 ALLOC 直接回 FREE"成立的前提是 D1 的那条"最旧门控"。**
注意它**不是**在重定向当拍发生的 —— 重定向在执行级发出，而这条转移发生在几拍后
该分支退休触发的 FLUSH_BE 那一拍（完整推理见 D3.1）。
若哪天放宽门控、允许不是最旧的分支提前重定向，就会有"比它更老、但还没退休的指令"
占着 ALLOC 态，这条转移会把它们的 preg 也放掉 —— 那就必须改成按 iid 比较，
复杂度立刻回到 C910 水平。**D1 与 D2 是一根绳上的两头。**

另外两处简化：
* **不需要 `retire_inst*_iid_match` 那套 96×3 的 iid 比较**：把 `dst_preg / old_preg`
  直接放进 ROB 表项（14 bit/项 = 896 bit），退休时由 ROB 广播 preg 号。
  这比 C910 的 iid 匹配**更省**（96×7 bit iid 存储 + 96×3×7 bit 比较器 vs 896 bit）。
* **不需要 96 路的 recover table 优先级仲裁**：直接维护一张 32 项的 **AMT**
  （架构映射表，32 × 7 = 224 bit，3 个写口来自 3 路退休），冲刷时整张发给重命名级
  （`rtu_ren_recover_map[223:0]`，与 C910 的 `rtu_idu_rt_recover_preg[223:0]` 同格式）。

分配用**优先编码**（C910 的 `ct_rtu_encode_96/expand_96` 就是干这个的），
按 C910 的扫描方向错开，避免 3 个口总挑同一个：

```
alloc0: p32 → p95 顺序找第一个 FREE     (低→高)
alloc1: p95 → p32 倒序找                (高→低)
alloc2: 低→高，但屏蔽掉 alloc0 已选中的
```

> ⚠️ `p0..p31` 永不进自由池。退休释放 `old_preg` 时必须判 `old_preg >= 32`，
> 否则第一次写 x1 就会把初始映射 p1 放回自由池，**这是最容易漏的一行**。

### D3 自由池用"逐 preg 状态"而不是环形 FIFO + 检查点

参考核用环形 FIFO 自由表 + 每个分支快照存一份 `head_ptr`，冲刷时把 head 拉回去。

**先说清楚：这条路本身是对的**，只是有个不容易看出来的前提 ——
FIFO 的 push（退休释放）会绕圈覆盖槽位，如果盖掉了"被 pop 走、等着回拉"的槽位就错了。
它成立的条件是 `检查点以来的 push 次数 < 检查点时刻的在途 preg 数`，
而后者恒成立：能在这期间退休的只有**比分支更老**的指令，最多 `在途数 - 1` 条
（分支自己还没退休）。**所以参考核的写法是严密的，不是隐患。**
这个不变量值得记下来：**"检查点的持有者必须一直活到冲刷发生"**。

那为什么本核不选它？因为**检查点是按分支数目算的资源**：

| | 环形 FIFO + 检查点 | 逐 preg 四态（本核选） |
|---|---|---|
| 状态 | 64×7 bit FIFO + 4~16 份检查点 | 96×2 = **192 bit** |
| 检查点代价 | 每份 = 整个 RAT(32×7) + 7 bit head ≈ 231 bit | 无 |
| 按 3 发射 64 项 ROB 配够检查点 | 需 8~16 份 ≈ **1.8~3.7 Kb** | — |
| 检查点用尽 | **停顿重命名**（参考核 `stall_o` 里那一项） | 不存在这个约束 |
| 冲刷恢复 | 回拉一个指针 | 所有 `ALLOC → FREE`（并行，一拍） |
| 分配 | 读 FIFO 头（便宜） | 96 位优先编码 ×3（组合逻辑） |

本核选逐 preg 状态：**省掉"按分支数展开"的那一维资源，也省掉"快照用尽停顿"这条约束**。
代价是分配从"读 FIFO 头"变成 96 位优先编码 —— 这是组合逻辑，不是状态。

#### D3.1 为什么"逐 preg 状态 + `ALLOC → FREE`"是对的（写给将来改代码的人）

关键是分清**两件事发生在不同时刻**（D1 定了重定向在执行级，但 `ALLOC → FREE` 发生在
后面的 FLUSH_BE 那拍）：

1. **执行级**：最旧的分支在 EX2 发出重定向（前端立刻重启）+ 取消 IDU；
2. **退休级（几拍后）**：这条分支走到 ROB 头**正常退休**，触发冲刷状态机；
   状态机跑到 `FLUSH_BE` 时发一个单拍脉冲（`rtu_yy_xx_flush`），
   **这一拍**才做 `ALLOC → FREE` 与 RAT 整表覆盖。

到了第 2 步，这条分支**已经退休**（它自己是"正常退休 + 误预测"，不是被冲掉的那条），
所以在飞指令只剩"比它年轻的"，全都是要被冲掉的。于是：

* `ALLOC → FREE` 是精确的，既不漏放也不误放；
* RAT 用架构映射表整表覆盖也是精确的（所有非退休指令都已作废）。

**三条前提缺一不可，写 RTL 时按这个顺序自查**：
① 重定向只能由最旧的待解析分支发出；② `ALLOC → FREE` 与 RAT 覆盖必须在
*该分支退休之后*那一拍；③ 从执行级重定向到 FLUSH_BE 之间，**派遣必须一直冻住**
（否则前端重启后新重命名的指令会被第 2 步的整表覆盖误伤）。

> 反过来说：只要允许"不是最旧的指令"提前重定向，①就破了，
> 比它老的指令还活着、还占着 `ALLOC`，于是 RAT 不能整表覆盖、preg 也不能一律放回 ——
> 必须改成按 iid 比较，复杂度立刻回到 C910 的 `ct_rtu_pst_preg.v`（8 637 行）水平。

### D4 ROB 表项位域（122 bit，已含 §4.3 的省资源）

对比：C910 动态部分 40 bit（含向量/断点/debug）+ PST 里的寄存器簿记；
参考核 80 bit 静态字段放异步读 RAM。

| 字段 | 位宽 | 来源 / 用途 |
|---|---|---|
| `vld` | 1 | 表项有效 |
| `cmplt` | 1 | 执行单元回送完成 |
| `wrap` | 1 | iid 的回绕位。**表项不存完整 iid** —— `iid = {wrap, 本表项的固定索引}`，索引是常量、不需存储（照 C910 的做法）；完成总线按 7 位 iid 匹配，每项只需 6 位常量比较 + 1 位回绕比较 |
| `pc[31:0]` | 32 | 退休 PC（`mepc` / difftest / 分支训练）。**阶段一先存下来**，见 D8 |
| `target[31:0]` | 32 | **真实后继 PC**，分支在 EX 解出后写回；**退休点重训练**用它（重定向本身由 BEU 直连 IFU，不读这里） |
| `chk[24:0]` | 25 | 前端预测快照，退休时回送 IFU（修 GHR/RAS + 训练） |
| `dst_lreg[4:0]` | 5 | 退休时写 AMT |
| `dst_preg[6:0]` | 7 | 退休时 `ALLOC → ARCH`；difftest 读结果用 |
| `old_preg[6:0]` | 7 | 退休时释放（判 `>= 32`） |
| `rf_we` | 1 | 写 rd（**2026-10-01 补 A6b**：`dpi_shim.c:164` 连 `debug_wb_ena` 都比对，ena 不能用 `dst_lreg!=0` 现推） |
| `is_csr` | 1 | 本指令是 CSR 指令（字段见下表后的"CSR 槽"） |
| `is_mret` | 1 | `mret`（**2026-10-01 补**：§6.2 要输出 `rtu_mret_vld`，而 mret 没有异常包可依） |
| `is_branch` | 1 | 分支/JAL/JALR：要训练、可能要重定向 |
| `actual_taken` | 1 | 实际方向（EX 解出后写回） |
| `mispred` | 1 | 预测错误（EX 解出后写回，退休时触发 flush） |
| `is_store` | 1 | 退休时提交存储 |
| `sq_id[2:0]` | 3 | 存储队列槽号 |
| `intmask` | 1 | 阻断中断（CSR 等），见 D10 |
| — | **≈122** | 总共 64 项 ≈ 7.8 Kb 触发器 |

**CSR 槽（表项外，单个寄存器，27 bit）**：`{src1_preg[6:0], csr_addr[11:0], csr_op[2:0], csr_imm[4:0]}`。
（`csr_op` 取 **funct3 原样**、不是 2 位压缩版 —— 本核 `Control.v` 把 `csrrwi/rsri/rrci`
折进了 `RW/RS/RC`，那样一折，退休级就分不出"源是 rs1 还是 uimm5"了。A6c。）

CSR 的四个字段本来要占 **27 bit × 64 = 1.7 Kb**，而它们**只在 CSR 指令退休那一拍**
被消费（不参与判退，不在 P1 链上）。抽成单槽后表项只剩 1 位 `is_csr`：

* **省 ≈1.5 Kb**，且退休级少读 4 个 64 选 1 的字段 —— **时序是正向的**；
* 代价：**只允许一条 CSR 在途**，第二条到了停派遣（派遣逻辑加一个 `csr_inflight` 门控，
  冲刷时清掉）。CSR 在 CoreMark 里几乎不出现，实测代价 ≈ 0；
* 这条正是"省资源要在保证时序的前提下"的样板：**看字段在哪条路径上被消费，
  而不是看它能省多少**。同类字段（退休级要用的 `pc/target/chk/dst_preg/old_preg`）
  一位都不许砍。

**没有异常字段** —— 走 D9 的全局 `expt_entry`。

**判决原则（两条约束的先后）**：
**① 时序不许变差；② 在①的前提下尽量省资源。** 这两条不矛盾 ——
上一版我把它写成了"一位都不砍"，那是过头了。正确的分法是看字段**在哪条路径上被消费**：

| 字段 | 消费路径 | 判决 |
|---|---|---|
| `pc` `target` `chk` `dst_preg` `old_preg` `wrap` | **退休级**（判退、释放、训练） | **一位不砍** —— 省它们就是把组合逻辑搬进 P1 那条最长链 |
| `csr_addr/op/imm` `src1_preg` | **只在 CSR 指令退休时**用（约 1% 的指令） | **该省，见 §4.3** —— 它们不参与判退，砍掉不影响 P1 |
| `dst_lreg` `is_*` `sq_id` `intmask` | 退休级，但本来就只有 1~5 位 | 保持 |

被明确**否掉**的三个瘦身方案（记录在此，免得以后有人再提）：

| 方案 | 为什么否 |
|---|---|
| `pc` 改成 C910 的推断链（`rob_cur_pc` + `pc_offset` + 分支 `next_pc`） | 省 2 Kb，但引入一条**跨表项的加法/mux 链**（C910 那段 `read2_cur_pc_addend0` 的三选一就是新增关键路径），而且 difftest 逐条比 PC，错一位就炸。**等 §4.2 的 P1 实测有余量了再回来看这条** |
| `chk` 改成侧表（只给分支发槽位） | 省 0.7 Kb，但要加槽位分配/回收/溢出处理，**收回来的面积还不够补偿新逻辑** |
| `dst_lreg`/`old_preg` 改成"ROB 只广播 iid、PST 每项各自比对"（C910 原案） | 反而更费：96 项 × 7 位 iid 存储 + 96×3 个 7 位比较器，比 64 项 × 14 位贵得多 |

### D5 头部读：**必须用 C910 的 `read_entry` 中间级**（不做组合读）

⚠️ 这一条原来写的是"阶段一先组合读，后面再补中间级"——**按时序约束推翻**。

组合读的代价是 `64 选 1 × 3 路 × 120 bit ≈ 23 k 门`，而且它**不是孤立的一条链**，
下游紧接着就是三级联动的判退逻辑（commit1 依赖 commit0、commit2 依赖 commit0+1）
和三个 `old_preg` 释放比较 —— 整条链会变成
**"64:1 mux → 类型译码 → commit 级联 → preg 释放/AMT 写"**，
全部压在一拍里。这是新引入的最长路径，也正是本项目历次 Fmax 攻坚反复砍的那类链。

**做法（照 C910）**：3 份与表项同宽的**影子表项** `read_entry0/1/2`，
它们是寄存器、由读指针驱动：

* 退休把头部 3 项"推"进影子表项 → 判退逻辑面对的**永远是 3 个已寄存的值**，
  64:1 mux 被移出关键路径，只剩 3 选 1 的重填；
* 影子表项有三条写入路径：**移位（退休后补位）/ 补空 / 完成信号按 iid 匹配**；
* `read_entry0` 永不 pop（`ct_rtu_rob_entry.v` 里 `read_entry0_pop_en = 1'b0`）；
* 完成匹配只比 **iid 低 6 位**（退休判定才用完整的 7 位）—— 因为影子表项一定
  是当前指针附近的那几项，低 6 位足够区分，这一条也是省时序的。

**代价**：3 × 120 bit = 360 bit 额外寄存器，外加每条完成信号多 3 个比较器。
**这个面积按时序约束是必须花的。**

> ⚠️ 若改用 RAM 存静态字段（参考核的做法），**必须按异步读建模** ——
> `cpu/sim/README.md` §1 记着这个坑：按同步读建模会让取指假命中。
> 本计划默认**不用 RAM**，全部触发器，绕开这一整类问题。

### D6 不做快速退休

C910 允许"指令退休先于写回"，代价是 PST 要区分 `RETIRE`（已退休未写回）与
`RELEASE`（已释放未写回）两个状态，以及冲刷状态机里的 `WF_EMPTY`
（等"已退休未写回"的 preg 写回）。

**本核退休条件直接要求 `cmplt`（已写回）**，于是：
* 状态少一档（不需要 `RETIRE` / `RELEASE` 之分）；
* 冲刷状态机里**没有 WF_EMPTY**；
* "后端流水线是否清空"这个判据（C910 是 `pst_retire_retired_reg_wb && lsu_rtu_all_commit_data_vld`）
  **整个不需要**。

代价：退休比 C910 晚几拍。在 64 项 ROB 下这点延迟基本不影响 IPC ——
挡住退休的从来是"最慢的那条指令"，不是写回排队的最后几拍。

### D7 不做指令折叠（`cmplt_cnt`）

C910 的 `cmplt_cnt[1:0]` 是给"IDU 把多条指令折叠进一个 ROB 表项"用的。
本核 **1 条指令 = 1 个表项**，完成信号一到即完成，`ROB_CMPLT_CNT` 这两位不要。
连带 `ROB_INST_NUM`、`ROB_SPLIT`（拆分指令）也一并砍掉。

### D8 PC：阶段一每条存，推断链留作优化

C910 不存 PC，靠 `rob_cur_pc`（头部基址）+ 每条 3 bit `pc_offset` + 分支的
`next_pc` 推断（分析文档 §1 的代码）。本核**阶段一每条都存 32 bit PC**：

* difftest 逐条比对 `debug_wb_pc`，PC 错一位立刻炸 —— 存下来等于把这整类
  调试问题消灭掉；
* `mepc` / 分支训练 / debug 都要它；
* 32 bit × 64 = 2 Kb，可接受。

阶段 5 若要省面积，再按 C910 换成推断链，**验证方式现成**：
difftest 全绿 + 周期逐位不变，就证明推断链与存储等价。

### D9 异常：全局 `expt_entry`（最旧者胜），不是逐表项

C910 的 `ct_rtu_rob_expt.v` 维护**一个** 70 bit 的 `expt_entry`，
由 pipe0/2/3/4 各自的异常信息按 iid 比较更新（分析文档 §3.2 的 `expt_entry_write_sel`），
只有当**最旧的异常指令退休**时才发给 CP0。

**不采用逐表项存异常字段**（`vld+cause+tval` ≈ 37 bit × 64 = 2.4 Kb）。

本核精简版（约 45 bit）：`{vld, iid[6:0], cause[4:0], tval[31:0]}`。
* 各级（ID/EX/MEM）检出异常时，把 `{iid, cause, tval}` 打到收集口；
* 收集口按 `rtu_compare_iid`（**这个模块可以从 C910 原样搬**，74 行）判新旧，
  只保留最旧的一条；
* 冲刷时清 `vld`（错误路径上的异常要丢掉 —— 这条漏了会"凭空陷入"）；
* 退休时：若 3 条退休指令里有 iid 命中 `expt_entry.iid`，则**只退到它为止**，
  它自己不写寄存器、不写内存、不写 CSR，直接发陷阱。

`mtval` 的取值按 `CORE_DESIGN.md §4.2` 已有的口径（非法指令给指令字、
访存故障给地址、取指故障给 PC），由**检出级**装好随异常口送进来，RTU 不再重算。

### D10 CSR / store / 中断的提交点

| 副作用 | 现在（WB 提交） | 改成 |
|---|---|---|
| **store 写内存** | MEM 级就写下去（`CORE_DESIGN.md §4.4` 靠四条门控兜） | **退休时写**：地址/数据进存储队列，ROB 表项带 `sq_id`，退休才真正发出 |
| **CSR 写** | EX 级写 + `~redirect` 门控 | **退休时写**：RTU 用 `src1_preg` 读物理寄存器堆拿源操作数，算完写 CSR 并写回 rd（参考核就是这么做的） |
| **中断** | WB 提交点取，且只落在"无副作用"提交点 | **退休窗口内取**，且被 `intmask` 与"退休宽度"约束，见下 |
| **`instret` 计数** | `retire_i` 单脉冲 | **3 bit 计数**（`retire_cnt[1:0]`），golden model 同步 |

**中断的"单退休模式"**（C910 的做法，分析文档 §3.3）：中断到来时立刻
*停止新指令 commit*（`rob_int_commit_mask`），但**不影响已经提交的**，
然后在 `inst0` 退休时**把退休宽度压到 1** 并接受中断。
本核照做：`int_pending` 拉高后，`commit_mask` 只允许窗口里的 inst0 及其之前的
（用 iid 比较，与 C910 `rob_commit1/2_sync_mask` 同构），
且被中断的那条**不发 `retire` 脉冲**（`CORE_DESIGN.md §4.5` 的两边口径不能改）。

### D11 冲刷：**快慢两拍分离**，不是一条状态机包办

D1 定了重定向由 BEU 在执行级发出，所以"冲刷"其实是**两条路**，
写代码时必须分开看，混在一起是这一块最容易出的错：

| | 快路（执行级，BEU 发） | 慢路（退休级，RTU 状态机发） |
|---|---|---|
| 触发 | 最旧分支在 EX2 解析出误预测 | 该分支走到 ROB 头**正常退休** |
| 谁发 | BEU → IFU（`iu_ifu_chgflw_vld/pc/chk`） | RTU 状态机 |
| 动作 | 前端立刻从真实目标重启；`iu_yy_xx_cancel` 取消 IDU | 冲发射队列/执行级/存储队列；清 `expt_entry`；`ALLOC→FREE`；RAT 整表覆盖 |
| 延迟 | ~0（与 mispred 同拍） | 分支退休 + 状态机若干拍 |

**异常/中断/`mret` 没有快路** —— 它们本来就只在退休点裁决，直接走慢路。
所以：

```
FLUSH_IDLE --(退休窗口出现 flush 源: 异常/中断/mret/误预测退休)--> FLUSH_1
FLUSH_1    --(无条件)--> FLUSH_2      // 冲执行级/发射队列/存储队列, 清 expt_entry
FLUSH_2    --(无条件)--> FLUSH_IDLE   // ALLOC→FREE + RAT 整表覆盖 + ROB 指针复位
```

* **派遣从快路那拍起就必须冻住，一直到 FLUSH_2 结束**（见 D3.1 的前提③）——
  C910 对应的是 `start to stall IDU ID`。这条门控漏了，症状是"前端重启后刚重命名的
  几条指令被 FLUSH_2 的整表覆盖误伤"，表现为偶发算错、极难复现。
* **`rtu_beu_flush_chgflw_mask`**：慢路期间屏蔽 BEU 再次发重定向
  （对应 C910 的 `rtu_iu_flush_chgflw_mask`）。漏了会让两次重定向打架。
* 本核无快速退休（D6），所以**没有** C910 的 `WF_EMPTY` / `retire_flush_pipeline_empty`
  那一整套"等已退休未写回"的判据 —— 这是 D2/D6 换来的最大一块简化。
* 2 拍是上界，能不能像 C910 的 `FLUSH_FE_BE` 那样合成一拍，等阶段 1 实测再定。

**优先级**：异常/中断（同步，取最旧）> `mret` > 误预测。
同一拍里有异常又有误预测时，异常赢，误预测那条被一起冲掉（它本来就年轻），
**并且要确保它不会把前端重定向到错误的目标**（快路此时要能被慢路屏蔽掉，
这就是 `flush_chgflw_mask` 的第二个用处）。

---

### D12 `iid_oldest` 门控必须**并行**算，不许串在重定向链上

D1 要求给 BEU 加"最旧门控"，而 BEU 的输出正是**本核历史上最敏感的那条链**
（`git log` 里有连续四轮专门砍它：`4cfc39d` 把 redirect 从 push 计数链上摘下来、
`378385d` 给重定向加 `REDIRECT_PIPE`、`5aa66f2` 把进位链移出重定向路径）。
**往这条链上串任何逻辑都要先算清楚。**

好消息是这条门控可以做得极浅：

* **判定退化成"相等比较"，不是年龄比较。** "最旧的在途指令"就是 ROB 头，
  所以 `iid_oldest = (inst_iid == rtu_beu_retire_iid)` —— 7 位相等，1~2 级 LUT。
  **不要照搬 C910 的 `ct_rtu_compare_iid`**：那个是完整年龄比较（约 5 级），
  它存在是因为 C910 还要跟"上一个待处理误预测的 iid"比，本核按最严门控不需要；
* **两个比较数都必须是寄存器**：`inst_iid` 来自 ID_EX，`pop_iid` 来自 ROB 的
  指针寄存器。**不能用"本拍退休判决算出来的下一个头部 iid"** —— 那会把
  判退链串进来。允许它比实际头晚一拍（代价是分支晚一拍才能重定向，安全且几乎无感）；
* **让它和 `mispredict` 同时到达，而不是在它之后**。现有 BEU 已经是
  "三个后继候选并行算 + 各自失配检测"（`mycpu.v:811-831` 的注释），
  `ex_npc_mismatch` 本身有深度；7 位相等比较落在它的阴影里，末级只多一个 AND。

这样 `iu_ifu_chgflw_vld = mispredict & ~redirect & iid_oldest & ~flush_chgflw_mask`
相比现在（`mispredict & ~redirect`）**只多一级 AND**，且该 AND 的输入同时到，
不构成新的关键路径。

> 这条与 C910 的做法一致：它的 BJU 里有一句原话注释
> **"timing optimization: move ex1 iid age compare to rf stage"**（`ct_iu_bju.v:479`）
> —— 说明 C910 自己也是把年龄比较提前到流水线前一级去躲时序的。

---

## 4. 微架构规格（参数表）

```verilog
// mySoC/rtu/rtl/RTU_define.vh  (或并入 mySoC/defines.vh)
parameter ROB_DEPTH   = 64;      // 表项数
parameter ROB_AW      = 6;       // log2(DEPTH)
parameter IID_W       = 7;       // ROB_AW + 1 位回绕
parameter DISP_W      = 3;       // 每拍派遣宽度 = 发射宽度
parameter RETIRE_W    = 3;       // 每拍退休宽度
parameter NUM_PREG    = 96;      // 物理寄存器数
parameter PREG_W      = 7;       // log2(NUM_PREG)
parameter ARCH_PREG   = 32;      // p0..p31 = x0..x31 初始映射, 永不释放
parameter NUM_LREG    = 32;
parameter CMPLT_PORTS = 5;       // ALU0/1/2 + BEU + MUL/DIV/LSU 汇总
parameter FLUSH_LAT   = 2;       // 冲刷状态机拍数
```

**不变量**（写 RTL 时当断言用）：

1. `create_ptr - pop_ptr (mod 64) = 在途表项数`，范围 `[0, 64]`。
   **判满不要用指针比较，用计数器**：C910 是 `rob_entry_num[6:0]` 计数器，
   且**留 3~4 个空位**就置 `full`（`ct_rtu_rob.v:4471-4488`）——
   因为一拍最多要派 3~4 条，必须保证它们有位置。本核 3 宽派遣同理留 3 个空位。
2. 自由 preg 数 = `popcount(preg_state == FREE)`。
   **`FREE < 本拍要分配的个数` 时必须停重命名** —— 这是"死锁而不是变慢"的那类约束。
   参考核 free_list 只有 32 项却配 64 项 ROB，**在途写寄存器指令被压在 32**，
   64 项 ROB 根本填不满（`refcore` 独立复核确认了这一条）；
   要往 CoreMark 上跑之前，先加一条**上电自检打印**：`FREE 数 == 0 且还有指令在途`
   就 `$display` 报错，否则症状是"跑着跑着不动了"。
3. 表项 `vld=1` 的 `iid` 必须唯一（回绕位保证）。
4. 任一拍里 `preg_state` 的 `ARCH` 项数 == 32（每个 lreg 恰好一个）。
   这条适合做仿真断言，不是综合逻辑。

### 4.2 时序预算（本核的硬约束）

#### 基线（已存档，不是估计值）

| 项 | 值 | 出处 |
|---|---|---|
| **器件 / 流程** | xc7k325tffg900-2，Vivado **impl（place & route 之后）** | `synth/build_fmax.tcl` |
| **配置** | IFU=2 默认：`BP_PRED=0` gshare / icache 1024B·16B 行 / GHR=8 / `REDIRECT_PIPE=1` | `Makefile:250-283` |
| **基线 Fmax** | **183.9 MHz（5.6 ns，WNS +0.163）** | commit `7d8c8b1` 的实测记录 + 用户自己的 Vivado 运行 |
| 扫频 | 6.2(+0.334) / 6.0(+0.233) / 5.6(+0.163) 过；**5.2 ns 垮（−0.044）** | 同上 |
| **物理极限** | **≈5.44 ns ⇒ 余量只有 0.16 ns** | 同上 |
| 复现 | `vivado -mode batch -source synth/build_fmax.tcl -tclargs 5.6 impl` | `build_fmax.tcl:4-8` |

> ⚠️ **基线报告没有入库 —— 这是复现口径上的一个洞，动手前要先补上。**
> 全仓扫描 `synth/reports/**/FMAX_SUMMARY`，**没有任何一次运行对得上 +0.163 @5.6 ns**；
> 最好的一条是 `r3/gshare/fmax_impl_6.0ns` = **+0.133 / 170.4 MHz**，
> 而 `r3/gshare/fmax_impl_5.6ns` 是 **−0.686（垮）**。原因是 `r3` 那一轮跑在
> **w4 减级数之前的树**（`f6cef3d` 的 BEU + 前端减级数还没进），
> 183.9 那次是之后的树 + 用户机器上的运行。
>
> **后果**：如果直接拿 `r3` 当"同一套流程"的对照，会得到 −0.686，
> 从而**误判成"RTU 把时序搞垮了"**。所以动手前请先做一件事：
> **把 183.9 那次的 `timing_summary.rpt` 与所用 impl strategy 归档**
> （建议放 `synth/reports/baseline_5.6ns/`，照 `r2`/`r3` 的格式写一份 `README_zh.md`）。
> 那份报告同时也是"改动前关键路径清单"的对照基准。

> ⚠️ **本机没有 Vivado**（`which vivado` 为空，`synth/reports/` 里只有历史报告）。
> 所以 Fmax 验收**必须到有 Vivado 的机器上跑**，本机只能做两件事：
> ① 对着 `synth/reports/` 的历史路径清单**人工核对没有新增的同类长链**；
> ② 跑功能回归。**不要把"本机没报错"当成时序过关。**

#### 当前瓶颈在哪（这决定了 RTU 该往哪使劲）

commit `7d8c8b1` 的实测分布 —— 500 条最差路径里：

* **270 条是 `u_soc→u_soc`（EX → 前端）**：`ex_A → BTB 训练写口`、
  `ex_csr_rdata` 的 CE、`IF_ID` 捕获；
* 取指环只剩 55 条（+0.191）；
* 两者齐平在 ~5.4 ns。

**这条信息对 RTU 是利好，而且改变了阶段排序**：

1. **阶段 4b（预测器训练搬到退休点）会把 `ex_A → BTB 训练写口` 这一整类路径
   从 EX→前端 上摘掉** —— 那正是 270 条里的主力。也就是说 RTU 在这条上是**减负**。
   ⇒ **4b 不只是"为了乱序正确性"，它同时是本项目最大的一笔时序收益。**
   建议把它排在能跑通的最早位置（阶段 3 之后立刻做，不要拖到阶段 4 末尾）。
2. **唯一新增到 EX→前端 的是 `iid_oldest` 那个 AND**（P2）。所以 D12 那句
   "只多一级 AND"从设计美感变成了**硬指标** —— 余量只有 0.16 ns，多一级就可能垮。
3. **P8 是隐蔽的一条**：ROB 的 `full` 若由"本拍退休判决 → 表项计数 → full"组合产生，
   再喂给前端的捕获使能，就新造了一条
   **退休判决 → 派遣停顿 → 前端捕获**的长链，而 `IF_ID 捕获` 本来就在 270 条里。
   ⇒ **`full` 必须只依赖寄存器**（把计数/`full` 打一拍，或按 C910 留 3~4 个空位让
   停顿信号晚一拍也无害）。

#### RTU 新引入的路径与对策

| # | 新路径 | 深度 | 对策 |
|---|---|---|---|
| P1 | **头部读 64:1 mux → 判退级联 → preg 释放/AMT 写** | ★★★ 最长 | **D5 的 `read_entry` 影子表项**：把 64:1 移出关键路径，判退只面对 3 个寄存值（表项 122 bit 而非 145 bit，这条 mux 也顺带窄了 16%） |
| P2 | **`iid_oldest` 串进重定向链**（★ 唯一新增到 EX→前端 的） | ★★ | **D12**：退化成 7 位相等 + 并行到达；两个比较数都必须来自寄存器。**这条要拿报告验** |
| P8 | **`rob_full` → 前端捕获使能** | ★★ | `full` 只依赖寄存器；留 3~4 个空位容忍晚一拍（见上） |
| P3 | 96 位三端口优先编码 → preg 状态更新 | ★★ | **D2 的 `WF_ALLOC`**：切成"选择 / 派遣确认"两拍 |
| P4 | 5 路完成总线 → 64 项 × 7 位比较 → 置 `cmplt` | ★ 浅 | 一级相等 + AND-OR；影子表项另加 3 个比较器 |
| P5 | 3 路退休 → AMT 三写口 + `old_preg` 释放比较 | ★ 浅 | 寄存器直出，无长链 |
| P6 | 冲刷状态机 → 全表清 + RAT 224 位广播 | ★ 浅 | 一拍广播，无级联 |
| P7 | 派遣 → 表项写（独热指针译码） | ★ 浅 | **用独热指针**（C910 做法）：省掉 6 位加法器 + 译码器 |

**三条通用原则**（都是 C910 用了、我们照抄的）：

1. **能用寄存器隔开就隔开**：`read_entry` 影子表项（P1）、`WF_ALLOC`（P3）、
   退休判决提前一拍预计算（C910 的 "compare retire inst iid before retire"）。
   多花的寄存器按时序约束是划算的。
2. **独热指针优先于二进制指针**：C910 的 create/read 指针是**独热 64 位寄存器**，
   靠 `{ptr[62:0], ptr[63]}` 旋转更新，天然给出每项的使能，没有加法器、
   没有译码器。（它的 pop 指针是 6 位二进制 + 现展开，因为那里不敏感。）
3. **退休级要用的字段宁可多存，不要在退休级现算**：`pc/target/chk/dst_preg/old_preg`
   一位不砍（它们就在 P1 链上）；**反之，不在退休级用的字段要果断抽出去**
   （§4.3 的 CSR 槽省了 1.5 Kb，还让 P1 少读 4 个字段）。
   **退休级是新引入的收敛点，判据永远是"这条字段在哪条路径上被消费"。**

**验收判据（可执行，不是口号）**：

```sh
# 在有 Vivado 的机器上，与基线完全同一套流程/同一份约束
vivado -mode batch -source synth/build_fmax.tcl -tclargs 5.6 impl
# 判据: WNS >= 0   ⇒ Fmax >= 183.9 MHz
```

1. **判据是"5.6 ns 点上 WNS ≥ 0"，对应 Fmax ≥ 183 MHz** —— 不是"差不多"。
   注意**余量只有 0.16 ns**：基线自己是 +0.163，所以这条判据等价于"一点都不能退"。
2. 掉下来就按上面的 P1~P8 表定位是哪条路径，**先改 RTL 再考虑放宽约束**。
3. **本机没有 Vivado ⇒ 每阶段的时序验收必须外跑**，本机只做"人工核对无新增同类长链
   + 功能回归"。阶段 1 / 3 / 4 各跑一次（阶段 4 预期是**变好**，见上面的 P2 说明）。
4. 若某一阶段确实必须牺牲，**先记下掉在哪条路径、掉多少**，再决定是否接受 ——
   不要静默放过（本项目历次 Fmax 攻坚的结论都归档在 `synth/reports/`，
   新报告请按 `r2`/`r3` 的格式新开一轮目录，写 `README_zh.md`）。

---

### 4.3 省资源清单（**在 §4.2 时序达标的前提下**按序做）

原则：**先保证时序，再省；省要省在"不在关键路径上"的地方。**
下面按"收益 / 代价"排序，1 和 2 建议直接做进第一版，3 以后留到实测。

| # | 方案 | 省 | 时序影响 | 代价 |
|---|---|---|---|---|
| 1 | **CSR 字段抽成单个"CSR 槽"**：`csr_addr`(12)+`csr_op`(2)+`csr_imm`(5)+`src1_preg`(7) 从表项里拿出去，表项只留 `is_csr`(1 位)；**只允许一条 CSR 在途**，第二条到了停派遣 | **≈1.5 Kb** | **正向**：退休级少读 4 个 64 选 1 字段，P1 变浅 | 派遣多一条串行化约束；CSR 在 CoreMark 里几乎不出现，实测代价≈0 |
| 2 | **不存完整 iid，只存回绕位 `wrap`** | 384 bit | 中性 | 无（完成比较变成"6 位常量 + 1 位回绕"） |
| 3 | `pc` 改 C910 推断链 | 2 Kb | **负向**：新增跨表项 mux 链 | difftest 逐条比 PC，错一位就炸 —— **等 P1 实测有余量再说** |
| 4 | `chk` 改侧表 | 0.7 Kb | 中性 | 槽位分配/回收/溢出逻辑，**不划算** |
| 5 | 物理寄存器 96 → 80 | ~0.5 Kb（寄存器堆） | 中性 | 在途目标寄存器被压到 48，**会拖 IPC，不建议** |

**已经省掉的**（写在这里免得被当成遗漏）：全局 `expt_entry` 单表项而不是逐表项
（省 2.4 Kb）、不做快速退休（省 `RETIRE`/`RELEASE` 两态 + `WF_EMPTY` 整套）、
不做 `cmplt_cnt`/向量/断点/debug（C910 那部分占了它表项的 16 位 + 整个 `rob_expt` 子模块）。

**明确不做省的地方**（这几处省了就是拿时序换面积，方向反了）：
ROB 深度（**只能取 2 的幂**，48 会让指针回绕数学变丑；32 太浅，3 发射塞不下 10 拍
指令流，所以保持 64）、`read_entry` 影子表项、`WF_ALLOC` 打拍、
`pc/target/chk/dst_preg/old_preg` 五个退休级字段的宽度。

## 5. 模块划分与文件计划

对齐现有目录约定（`mySoC/idu/rtl/`、`mySoC/iu/rtl/`），新增 `mySoC/rtu/rtl/`：

| 文件 | 对标 C910 | 估计行数 | 内容 |
|---|---|---|---|
| `RTU_define.vh` | —（C910 靠层次传参） | ~40 | §4 的参数与 preg 状态编码。用 `` `define `` 而不是 `parameter`：参数要穿过 4 层层次，逐层传只会多出 4 处改错的机会 |
| `RTU.v` | `ct_rtu_top.v`（2 475 行） | ~200 | 退休单元顶层：例化下面几个并把对外端口接起来 |
| `RTU_ROB.v` | `ct_rtu_rob.v`（6 487 行） | ~350 | 表项数组 + 三指针 + 派遣/完成/退休数据通路 |
| `RTU_ROB_entry.v` | `ct_rtu_rob_entry.v`（535 行） | ~150 | 一条表项（位域 + 完成/解析位更新），例化 64 次 |
| `RTU_commit.v` | `ct_rtu_rob_rt.v`（2 768 行） | ~250 | 提交/退休判定 + 3 路退休信号 + 中断掩码 |
| `RTU_preg.v` | `ct_rtu_pst_preg.v`（8 637 行） | ~220 | 四态表（含 `WF_ALLOC` 打拍）+ 优先编码分配 + AMT + 释放/回滚 |
| `RTU_csr_slot.v` | —（C910 无此结构） | ~40 | CSR 单槽 + 在途门控（§4.3 的省资源项） |
| `RTU_expt.v` | `ct_rtu_rob_expt.v`（822 行） | ~120 | 异常收集（最旧者胜） |
| `RTU_flush.v` | `ct_rtu_retire.v`（2 201 行） | ~150 | 冲刷状态机 + 重定向分发 + 提交点副作用 |
| `RTU_iid_cmp.v` | `ct_rtu_compare_iid.v`（74 行） | ~74 | **可原样搬**，只改端口命名 |
| | **35 635 行** | **≈ 1500** | |

> 📌 **踩过的坑（写进 Makefile 前必看）**：`Makefile:46-52` 有明确警告 ——
> `$(wildcard mySoC/*.v)` **不递归**，新开目录必须在 `VSRC` 里**逐个列出来**
> （`Makefile:54-60`）。忘了加的症状是 elaborate 报"找不到模块 XXX"，
> 而不是报文件缺失。

---

## 6. 对外接口契约

> 📌 **这一节是交接契约，写给做重命名级的同事（以及写发射队列的人）。**
> 它可以独立阅读：你不需要看本文其它 900 行，只要按这里的端口和时序约定实现，
> 两边就能接上。有疑问的地方**先在这里改，再动 RTL** —— 契约漂移的代价是两边返工。
>
> **谁负责什么（一句话版）**：
> * **重命名级（你）**：维护投机映射表 RAT、源操作数映射与旁路、算出每条指令的
>   `dst_preg`/`old_preg`，并在收到 `rtu_ren_flush` 时**用 `rtu_ren_recover_map`
>   整表覆盖自己的 RAT**。你不需要知道 ROB 有多深、退休窗口有多宽。
> * **退休单元（本计划）**：表项分配与回收、物理寄存器自由池与三态维护、
>   架构映射表 AMT、异常与冲刷裁决、提交点副作用（store/CSR/difftest/instret）。
>   它**不碰你的 RAT**，只在你该覆盖时给你一份完整映射。
> * **交界处的硬约定**（下面每条都有对应小节，别漏）：
>   1. **派遣必须等 `rtu_disp_stall == 0`**，一拍最多 `DISP_W = 3` 条，
>      且**必须是程序序的前缀**（允许少于 3 条，不允许跳号）。
>   2. **物理寄存器是"两拍分配"**：本拍你从 `rtu_preg_alloc_*` 看到的编号，
>      下一拍派遣时才真正落到 `ALLOC` 态（`WF_ALLOC` 打拍，见 D2）。
>      所以**同一拍内不要把刚拿到的编号再用于另一次分配**。
>   3. **`old_preg >= 32` 才需要释放**；`p0..p31` 是 x0..x31 的初始映射，永不回收。
>   4. **冲刷时你什么都不用算**：收到 `rtu_ren_flush` 就把整张 RAT 换成
>      `rtu_ren_recover_map`（32×7 bit），然后在 `rtu_disp_stall` 放开之前不要派遣。
>      不需要快照、不需要历史 —— 这份映射表只反映**已退休**的映射。
>   5. **`x0` 不分配、不映射**：`dst_lreg == 0` 时 `disp_dst_preg` 与 `disp_old_preg`
>      都是 don't-care，RTU 侧按 0 处理。

> ⚠️ **端口风格已定案（2026-10-01）：扁平编号，不用 SV unpacked array。**
> 本节最初的版本写的是 `input [6:0] disp_pc[DISP_W]` 这类端口。改掉的三个理由：
> ① `mySoC/**` 递归 grep，这类端口**一处先例都没有**；② 蓝本 C910 自己也是扁平编号
> （`rob_create0_inst_pc` / `rob_retire_inst2_cur_pc`）；③ 本核的 Fmax 验收要在 Vivado 上过，
> **不该拿一个新语法当第一次综合实验**。所以三路派遣 / 三路退休 / 五路完成一律写成
> `xxx0/xxx1/xxx2`（`xxx0` = 程序序最老的那条），与前端已有的 `idu_inst0/1/2_*` 同风格。
> 位宽与语义一位没变，只是把数组拆成编号端口。

### 6.0 物理寄存器分配握手（**重命名级最先要看的一段**）

preg 自由池与优先编码器**在 RTU 侧**（D2），所以是"你要、我给"，不是"你选、我记账"：

```verilog
// 重命名级 → RTU：本拍需要几个新 preg（每拍最多 DISP_W 个）
input  [1:0]  ren_preg_req;                 // 0..3
input  [4:0]  ren_preg_req_lreg0;           // 与"第 0 个请求"对应的 dst 逻辑寄存器（判 x0 用）
input  [4:0]  ren_preg_req_lreg1;
input  [4:0]  ren_preg_req_lreg2;
// RTU → 重命名级：给出去的编号（两拍语义，见下）
output [6:0]  rtu_preg_alloc0;
output [6:0]  rtu_preg_alloc1;
output [6:0]  rtu_preg_alloc2;
output        rtu_preg_alloc_vld0;          // lreg==0 的那一路给 0（x0 不分配）
output        rtu_preg_alloc_vld1;
output        rtu_preg_alloc_vld2;
output [1:0]  rtu_preg_free_cnt;            // 剩余可用数（< 请求数时你自己别发请求）
```

**车道语义（写死，别推导）**：`ren_preg_req = n` 表示**车道 0..n−1 是本次的请求者**，
车道 n..2 的内容是 don't-care。某条请求的 `lreg == 0` 时 RTU 给它 `alloc_vld = 0`
且编号 don't-care —— **不要**因为"车道被跳过了"就把后面的请求往前挪。

**时序语义（照 D2 的 `WF_ALLOC` 两拍）：**

| 拍 | 发生什么 |
|---|---|
| T | 你拉 `ren_preg_req`；RTU 做 96 位优先编码，把选中的 preg 置 `WF_ALLOC`，**同拍**把编号放到 `rtu_preg_alloc` |
| T+1 | 你拿这个编号更新自己的 RAT、随指令下发；RTU 在派遣确认那拍把它推到 `ALLOC` |

⇒ **`rtu_preg_alloc` 是"给下一拍用的"**，不要在同一拍里拿它去更新 RAT 再组合出
`disp_*`（那样会把优先编码器串进派遣链）。RTU 会保证这个编号在 T+1 拍仍然有效。

### 6.1 输入

```verilog
// —— 派遣（来自重命名级 / IDU）；k = 0/1/2 = 程序序 ——
input        disp0_vld;               // 允许少于 3 条，但不许跳号（前缀）
input [31:0] disp0_pc;
input [24:0] disp0_chk;               // 前端快照, 随指令走
input [4:0]  disp0_dst_lreg;          // ⚠️ **不写寄存器时必须给 0**（见下面的 A6d）
input        disp0_rf_we;             // A6b: 与今天 mycpu.v 的 wb_rf_we 同源
input [6:0]  disp0_dst_preg;          // ← 来自 §6.0 的 rtu_preg_alloc k
input [6:0]  disp0_old_preg;          // 被替换的（来自你自己的 RAT）
input [6:0]  disp0_src1_preg;         // 仅 CSR 指令有意义（退休级要读源操作数）
input [11:0] disp0_csr_addr;
input [2:0]  disp0_csr_op;            // A6c: **funct3 原样** 001=RW 010=RS 011=RC 101=RWI 110=RSI 111=RCI
input [4:0]  disp0_csr_imm;           // csrrwi 系列的 uimm5（只有 csr_op[2]=1 时有效）
input [4:0]  disp0_flags;             // {is_mret, is_csr, intmask, is_store, is_branch}
input [2:0]  disp0_sq_id;
// disp1_* / disp2_* 同上（源操作数与 dst 的对应关系按车道，不跨车道借用）
//
// ⚠️ **A6d（2026-10-01 补，单测台挖出来的）**：`rf_we == 0` 的指令，`dst_lreg` 必须给 0。
//    RTU 侧"分配过就归还"的判据是 `wr_eff = write_vld & rf_we & (dst_lreg != 0)`：
//    若给一个非 0 的垃圾 rd 域（store 的那几位本来是立即数），RTU 会按"要写 rd"去要
//    编号、分配出去，而退休时 `wr_eff` 不成立 ⇒ 这个 preg 既不转 ARCH 也不释放，
//    **静默泄漏**在 ALLOC 态，随后被优先编码器当空闲再发出去。
//    给 0 不影响 difftest：`ena = rf_we`，`ena==0` 时 golden model 根本不比 `reg`
//    （`dpi_shim.c:165` 的 `if (dut_wb_ena)`）。**不要把"原样"理解成"不清洗"**。
//
// ⚠️ 另一条同样是为了 difftest:
//    `dpi/dpi_shim.c:164` 连 `debug_wb_ena` 本身都比对, 所以 ena 不能用
//    `dst_lreg != 0` 现推 (addi x0,... 的 rf_we=1 而 rd=x0, 两者必须能分开)。
//    AMT 的写口用 `rf_we & (dst_lreg != 0)` 门控。

// —— 完成（来自各执行单元 / LSU），p = 0..4 ——
input        cmplt_vld0;  input [6:0] cmplt_iid0;
input        cmplt_vld1;  input [6:0] cmplt_iid1;
input        cmplt_vld2;  input [6:0] cmplt_iid2;
input        cmplt_vld3;  input [6:0] cmplt_iid3;
input        cmplt_vld4;  input [6:0] cmplt_iid4;

// —— 解析结果（来自 BEU，分支/JAL/JALR 解出时写回表项）——
input        resolve_vld;
input [6:0]  resolve_iid;
input        resolve_taken;
input        resolve_mispred;
input [31:0] resolve_target;

// —— 异常（来自 ID/EX/MEM 各级的检出点）——
input        expt_vld;
input [6:0]  expt_iid;
input [4:0]  expt_cause;
input [31:0] expt_tval;

// —— 存储队列 / CSR / 中断 ——
input        sq_rdy0;                 // 退休窗口第 k 槽对应 store 的数据就绪
input        sq_rdy1;
input        sq_rdy2;
input        sq_stall;                // 存储队列满/下游忙 → 压退休宽度
input [31:0] csr_rdata;               // 组合读：地址见 §6.2 的 rtu_csr_addr
input        int_pending;             // 已按 mstatus/mie/mip 屏蔽过

// —— 物理寄存器堆读口（**A1 新增**：退休级要按 preg 取数）——
input [31:0] preg_rdata0;             // ← PRF[rtu_preg_raddr0]，difftest 用
input [31:0] preg_rdata1;
input [31:0] preg_rdata2;
input [31:0] rtu_csr_src_rdata;       // ← PRF[rtu_csr_src_raddr]，CSR 的 rs1 值

// —— 重定向目标的来源（**A6 新增**：§6.2 声明了 rtu_ifu_chgflw_pc，就得有地方拿）——
input [31:0] csr_trap_vector;         // 与今天喂给 PC 的那根同源（mtvec + cause<<2）
input [31:0] csr_mepc;                // mret 的重定向目标
```

### 6.2 输出

```verilog
// —— 前端：重定向只有异常/中断/mret 这一路；误预测的重定向由 BEU 直连 IFU（D1）——
output        rtu_ifu_flush;          // 陷阱/mret: 接口现成, 见 ifu2 的 rtu_* 端口
output        rtu_ifu_chgflw_vld;
output [31:0] rtu_ifu_chgflw_pc;
output        rtu_ifu_train_vld;      // 退休点重训练(BHT/BTB/TAGE) —— 取代 EX 级训练
output [31:0] rtu_ifu_train_pc;
output [24:0] rtu_ifu_train_chk;      // 表项里存的 chk
output        rtu_ifu_train_taken;

// —— 后端冲刷（D11 的 FLUSH_1 干的事；阶段 1 直接并进 mycpu.v 的 redirect）——
output        rtu_backend_flush;      // 单拍脉冲: 冲发射队列/执行级/存储队列

// —— 分支执行单元（BEU）：D1 的最旧门控 + 冲刷屏蔽 ——
output [6:0]  rtu_beu_retire_iid;        // ROB 的 pop iid, BEU 用它比出 iid_oldest
output        rtu_beu_flush_chgflw_mask; // 慢路冲刷期间屏蔽 BEU 再发重定向
// BEU → IFU 的重定向是**直连**的, 不经过本模块:
//   beu_ifu_chgflw_vld / _pc(=真实目标) / _chk  (与现有 iu_ifu_chgflw_* 同构)

// —— 重命名级（另有 §6.0 的 preg 分配握手）——
output        rtu_disp_stall;         // ROB 满 / preg 不足 / 冲刷窗口 → 停派遣
output        rtu_ren_recover_vld;
output [223:0] rtu_ren_recover_map;   // 32 × 7bit AMT
output        rtu_ren_flush;          // 重命名自身清空（FLUSH_2 那拍）
output [6:0]  rtu_ren_free_preg0;     // 退休释放的 preg（自由池在 RTU 侧，
output [6:0]  rtu_ren_free_preg1;     //   这三个口是**观察口**，供 debug/difftest）
output [6:0]  rtu_ren_free_preg2;
output        rtu_ren_free_vld0;
output        rtu_ren_free_vld1;
output        rtu_ren_free_vld2;

// —— 物理寄存器堆读地址（**A1 新增**：数据由 §6.1 的 preg_rdata* 送回）——
output [6:0]  rtu_preg_raddr0;        // = 退休槽 0 的 dst_preg（difftest 取值用）
output [6:0]  rtu_preg_raddr1;
output [6:0]  rtu_preg_raddr2;
output [6:0]  rtu_csr_src_raddr;      // = 在途 CSR 指令的 src1_preg

// —— 物理寄存器堆写口（**A1 新增**：CSR 的 rd 结果在退休时才算得出来）——
output        rtu_csr_rd_we;
output [6:0]  rtu_csr_rd_addr;        // = 该 CSR 指令的 dst_preg
output [31:0] rtu_csr_rd_wdata;       // = CSR 旧值（CSR 指令写 rd 的就是它）

// —— 提交点副作用 ——
output        rtu_store_vld0;         // 退休槽 k 是一条要提交的 store
output        rtu_store_vld1;
output        rtu_store_vld2;
output [2:0]  rtu_store_sq_id0;
output [2:0]  rtu_store_sq_id1;
output [2:0]  rtu_store_sq_id2;
output        rtu_csr_we;             // CSR 写：地址口兼作组合读地址（见 §6.3）
output [11:0] rtu_csr_addr;
output [31:0] rtu_csr_wdata;
output        rtu_trap_vld, rtu_mret_vld;
output [31:0] rtu_trap_epc, rtu_trap_tval;
output [4:0]  rtu_trap_cause;
output [1:0]  rtu_retire_cnt;         // instret 计数（0..3；被中断 squash 的那条不计）

// —— difftest / debug（★ 必须从 1 路扩成 3 路）——
output        dbg_commit_vld0;
output        dbg_commit_vld1;
output        dbg_commit_vld2;
output [31:0] dbg_commit_pc0;
output [31:0] dbg_commit_pc1;
output [31:0] dbg_commit_pc2;
output        dbg_commit_ena0;        // 陷阱那条: vld=1 但 ena=0（§4.5 的口径）
output        dbg_commit_ena1;
output        dbg_commit_ena2;
output [4:0]  dbg_commit_reg0;
output [4:0]  dbg_commit_reg1;
output [4:0]  dbg_commit_reg2;
output [31:0] dbg_commit_value0;      // 摘自 preg_rdata*，CSR 那条换成 CSR 旧值
output [31:0] dbg_commit_value1;
output [31:0] dbg_commit_value2;
```

---

### 6.3 时序与边角约定（写 RTL / 写 TB 时按这个自查）

**① 冲刷时间线**（T = 触发拍，`FLUSH_LAT = 2`）

| 拍 | FSM | 动作 / 可见信号 |
|---|---|---|
| **T** | IDLE→F1 | 退休窗口照常出信号（陷阱那条也在内：`dbg_commit_vld=1 / ena=0`）；**`rtu_disp_stall=1` 与 `rtu_beu_flush_chgflw_mask=1` 从这一拍就起** |
| **T+1** | F1 | `rtu_backend_flush=1`（冲发射队列/执行级/存储队列）；清 `expt_entry.vld`；无退休 |
| **T+2** | F2 | `rtu_ren_flush=1` + `rtu_ren_recover_vld/map`（AMT 整表）；所有 `ALLOC/WF_ALLOC → FREE`；ROB 三指针复位 |
| **T+3** | IDLE | `rtu_disp_stall` 放开 —— **早于此不得再派遣**（D3.1 的前提③） |

**② `rtu_disp_stall` 只依赖寄存器**（P8）。ROB 占用计数、preg 空闲数、FSM 状态一律取**寄存值**，
不许把"本拍判退结果"组合进来（那会造出 `退休判决 → 派遣停顿 → 前端捕获` 这条新长链，
而 `IF_ID 捕获` 本来就在 500 条最差路径里）。代价是停顿晚一拍 —— 按 C910 留 3~4 个空位容忍。

**③ `iid_oldest` 不许串年龄比较**（D12）。BEU 侧只做 7 位相等（`inst_iid == rtu_beu_retire_iid`），
两个比较数都来自寄存器。`RTU_iid_cmp`（年龄比较，约 5 级）**只给异常收集与中断掩码用**。

**④ 异常收集口只有一路，仲裁规则是"老级优先"**（MEM > EX > ID）。被丢掉的年轻异常不会丢信息 ——
异常随流水逐级锁存，下一拍还会从下一级报到；RTU 侧只留最旧的一条。

**⑤ CSR 指令的完成与写回（最容易做错的一条）**：
* 它的 rd 值（= CSR 旧值）**退休当拍才产生**，所以 `rtu_csr_rd_we` 那一拍值才进物理寄存器堆，
  **它的 `cmplt` 不代表 rd 可读**；
* 消费方（阶段 3 的发射队列）必须把 CSR 的目的寄存器当"不可旁路、等退休写回"处理；
  阶段 1（顺序核）的等价做法：依赖在途 CSR rd 的指令在 ID 停到它退休；
* `rtu_csr_addr` **一个口两种用**：组合读（→ `csr_rdata`）与写地址同值。退休那拍的组合路径是
  `csr_rdata → rtu_csr_wdata → CSR 写口`，只对 CSR 指令成立，不在 P1 链上。

**⑥ 交付脉冲口径（不许改，改了 difftest 立刻失步）**：同步异常那条**发**脉冲（`ena` 强制 0）；
被中断 squash 的那条**不发**（`retire_cnt` 也不计）；`mret` 正常发。

**⑦ `rtu_retire_cnt` 是 `[1:0]`**（编码 0..3），不是 3 bit 宽。`int_pending` 拉高后退休宽度压到 1。

**⑧ 同一时刻只允许一条 CSR 在途**：`disp_stall` 里必须有这一项，冲刷时清掉。

**⑩ CSR 的新值在退休级现算**（`csr_rdata` 是组合读口的输出，地址由 `rtu_csr_addr` 给）：

```
csr_src   = csr_op[2] ? {27'b0, csr_imm} : rtu_csr_src_rdata;  // csrrwi 系列没有 rs1
csr_wdata = (csr_op[1:0] == 2'b01) ? csr_src                   // RW
          : (csr_op[1:0] == 2'b10) ? (csr_rdata |  csr_src)    // RS
          :                          (csr_rdata & ~csr_src);   // RC
rtu_csr_rd_wdata = csr_rdata;      // 写 rd 的就是"旧值", 三种 op 一样
rtu_csr_we       = (csr_op[1:0] == 2'b01)                      // RW 恒写
                 | (csr_op[2] ? (csr_imm != 0) : (src1_preg != 0));  // 与 Control.v 同口径
```

> 最后那行能这么写，是因为 **x0 恒映射到 p0**（复位时 `AMT[0]=p0`，且 `p0` 永不进自由池），
> 所以 `src1_preg == 0` 与"rs1 域是 x0"等价 —— 这正是 `Control.v` 里
> `csr_we = (csr_op==RW) || (rs1_addr != 0)` 那一条的退休级改写。

**⑨ 慢路冲刷**也要重定向前端**（A6 的落地，这一条是从"哪些指令会被杀"倒推出来的）**：
T 拍 `rtu_ifu_chgflw_vld=1`，`rtu_ifu_chgflw_pc` 按来源三选一 ——
陷阱/中断取 `csr_trap_vector`；`mret` 取 `csr_mepc`；**误预测退休取该分支表项里的 `target`**。

> 为什么误预测也要重定向：从 BEU 在执行级发出重定向（D1 的快路）到这条分支退休之间，
> 前端已经重启并派出了若干条**正确路径**的指令 —— 但它们**是拿着还没恢复的 RAT
> 改名出来的**（RAT 要到 FLUSH_2 才被 AMT 整表覆盖）。所以它们必须和错误路径一起冲掉，
> 而冲掉之后必须**从分支的真实目标重取**，否则这些指令会被静默跳过。
> 换句话说：慢路不是"只冲后端"，它是一次完整的"冲干净 + 从目标重取"。
> 代价是误预测要重取几条指令（阶段 1 允许周期变差）；若将来要省掉这一笔，
> 加法是给 RTU 一个 `beu_redirect_vld`（BEU 在执行级发重定向时告诉 RTU 一声），
> 从那一拍起就把 `rtu_disp_stall` 拉高直到 FLUSH_2 —— **那是加法，不是返工**。

---

## 7. 分阶段实施路线图

每一阶段都**可独立验收、可停在原地不回退**。前置依赖写在括号里。

> **每个阶段的验收都多一条固定项：`vivado ... -tclargs 5.6 impl` 的 WNS ≥ 0
> （即 Fmax ≥ 183.9 MHz，基线见 §4.2）。**
> 掉下来就按 §4.2 的 P1~P8 表定位是哪条路径，**先改 RTL 再谈别的**。
> ⚠️ **本机没有 Vivado，这条必须外跑** —— 本机能做的只有
> "对着 `synth/reports/` 核对没有新增同类长链 + 功能回归"。
> 这是用户给的硬约束，不要留到最后再补。
>
> 📌 排期上有一条**免费收益**要先兑现：阶段 4b（训练搬到退休点）会摘掉当前
> 500 条最差路径里 270 条的来源（`ex_A → BTB 训练写口`）。所以
> **只要功能跑得通，就尽早做 4b**，别把它排到最后 —— 它既能腾出余量，
> 又能给后面更重的改动（阶段 3 的发射队列）留出 0.16 ns 之外的缓冲。

### 阶段 0：契约冻结 + 独立单测台（无依赖）
* 落本文件 + `mySoC/rtu/rtl/` 目录 + Makefile 的 `VSRC` 加一行；
* `tb/unit/tb_rtu_rob.sv`：**不接核**，用激励直接驱动 §6.1 的输入端口，
  按脚本检查退休序列 / 异常 / 冲刷 / preg 释放与恢复 / ROB 满停顿。
* **验收**：ROB 在独立 TB 下，自造的 200 条随机派遣+乱序完成+随机冲刷的
  追踪能逐拍比对（TB 里写一个纯 Verilog 的参考队列模型）。
* 这一步的价值：**退休单元 90% 的 bug 能在这里抓住**，不用等整个乱序核跑起来。

### 阶段 1：提交点从 WB 搬到 ROB（仍然全顺序）
* 流水线保持 5 级顺序，但 WB 不再直接提交；指令在派遣时进 ROB，
  由 ROB 按序退休（此时每条指令"分到"的 preg 就是它自己，映射是恒等的）。
* 接上**四态** preg 表（含 `WF_ALLOC` 打拍）+ AMT，但释放/分配还是顺序的。
* store 改成退休时写；CSR 改成退休时读写；`instret` 改成 3 bit 计数。
* **验收**：`bin/` 全部 48 个用例 difftest 全绿 + `asm/trap.S` 过 +
  **CoreMark 逐位一致**（周期可以变差，指令数/结果必须一致）+ **Fmax ≥ 基线**。
  ⚠️ 本阶段的 `read_entry` 影子表项（D5）**必须一起上**，不能等以后再补 ——
  它就是为这条路径准备的，先上组合读再改等于把 Fmax 验收推迟一轮。

### 阶段 2：真重命名 + 自由池
* 重命名级（`idu/rtl/` 或新目录）出 RAT、旁路、`old_preg`；
  RTU 侧接上优先编码分配与退休释放。
* 新增 `asm/rename_stress.S`：WAW/WAR/RAW 密集 + 每次写不同物理寄存器，
  专门压 preg 耗尽路径。
* **验收**：上一阶段全部 + 新用例；并且**把 `old_preg >= 32` 那行门控拿掉，
  测试必须失败**（反向验证）。

### 阶段 3：乱序执行
* 发射队列 + 唤醒/选择 + 按 iid 完成；RTU 的完成口接上多条。
* **验收**：difftest 全绿 + CoreMark IPC 提升（记入 `CORE_DESIGN.md`）+
  **Fmax ≥ 基线**（重点是完成总线 5 路 × 64 项比较与优先编码器这两条新链）。

### 阶段 4：重定向加最旧门控 + 预测器训练搬到退休点（★ D1 的落地）

**重定向留在执行级**（不搬），**训练搬到退休点**（要搬）—— 两件事分开做：

**4a. 重定向加最旧门控**（BEU 侧）
* 给 BEU 接上 `rtu_beu_retire_iid`，把 `iu_ifu_chgflw_vld` 的门控从当前的
  `mispredict & ~redirect`（`mycpu.v:833`）改成
  `mispredict & ~redirect & iid_oldest & ~flush_chgflw_mask`；
* `iid_oldest` **按 D12 做成 7 位相等比较**（`inst_iid == pop_iid`，两个比较数都来自
  寄存器），**不要照搬 `ct_rtu_compare_iid` 的年龄比较** —— 那是给 C910 的
  "与上一个待处理误预测比年龄"用的，约 5 级深，会直接压在重定向链上；
  本核按最严门控只需要"是不是队头"；
* **重定向 PC 仍然走 `actual_npc`**（`mycpu.v:834` 不用改）。
  ⚠️ **不要照抄 C910 的"跳回分支自己的 PC"那一手** —— C910 的
  `rtu_ifu_chgflw_pc = rob_retire_inst0_cur_pc`（`ct_rtu_retire.v:1582`）只服务于
  fence 类指令的重取，误预测那条走的是 `ex2_pipe2_tar_pc`（真实目标）。
  本核 ifu2 吃的正是真实目标 + 同拍 chk（`rv32ifu2_top.v:680`），两者天然对齐。

**4b. 训练搬到退休点**（RTU 侧）
* 把 `iu_bht_check_vld` / `iu_btb_update_vld` 那两条（`mycpu.v:844-886`）
  从 EX 级搬到 RTU，数据源换成 ROB 表项里的 `pc / target / chk / actual_taken`；
* **`iu_chk_idx` 与 `iu_btb_chk` 的驱动源要改**：现在都接 `ex_bht_chk`
  （`mycpu.v:849/872`），要改成"RTU 在重训练当拍送出的那份 chk"。
  漏了的症状是 **GHR/RAS 修到了错误路径的快照上**，而所有状态看起来都正常
  —— 正好是 `ifu2_zh.md` §604 记的那类坑；
* **为什么必须搬**：乱序执行下分支是乱序完成/解析的，EX 级训练会把 GHR 按乱序顺序推，
  方向表被静默带偏。这与"重定向必须最旧"是同一个约束的两个面。

**4c. 验收**
* `branch_bench` 与 `c3_only` 的 `+BENCH` 逐类统计**与搬迁前逐位一致**；
* `asm/trap.S` 全过；
* difftest 全绿 + CoreMark 指令数一致。
* **验收（等价性证明）**：`branch_bench` 与 `c3_only` 的 `+BENCH` 逐类统计
  **与搬迁前逐位一致**；`asm/trap.S` 全过。这条是本项目惯用的"逐位不变"证据链。

### 阶段 5（可选）：时序与面积
* 头部读加 `read_entry` 中间级（D5）、PC 推断链（D8）、`chk` 侧表（D4）；
* 每次只做一样，验收都是 **difftest 全绿 + 周期逐位不变**。

---

## 8. 验证计划

### 8.1 三道防线

| 层 | 工具 | 覆盖什么 |
|---|---|---|
| 单元 | 阶段 0 的 `tb/unit/tb_rtu_rob.sv` | 退休/异常/冲刷/preg 表的所有边界组合（含随机） |
| 差分 | `tb/tb_miniRV_dpi.sv` + golden model | 每条退休指令的 PC/rd/数据；**必须扩成 3 路/拍** |
| 反向 | `scripts/rev_check.py` | "拿掉关键门控，测试真的会失败吗" |

### 8.2 difftest 必须同步改的两处（**容易漏**）

1. **`gm_check_step` 一拍要能喂多条**。现在 TB 每拍调一次（`tb_miniRV_dpi.sv:588`），
   3 路退休后要按 `rtu_retire_cnt` 调 1~3 次，且**顺序必须是程序序**。
2. **`retire_i` 从脉冲变成计数**。`CSR.v:100` 的 `minstret + 1` 要改成 `+ retire_cnt`，
   golden model 侧同步。`doc/rev_check_zh.md §5.2` 记着这个坑：
   DUT 的 `mcycle` 数**真实周期**、参考模型按**提交步进**计数，两者本来就对不上，
   计数器的值一旦落进 `rd` 就会被提交点比较 —— 所以 `asm/` 里那些读计数器的用例
   （`csrrs x0, mcycle, x0`）**必须保持 `rd = x0`**，改 RTU 时不要顺手动了它们。

### 8.3 三条铁律（记忆里已经用血换过，脚本里都已落实）

* `meminit.{bin,hex,hex128}` **三个一起链**，且串行 —— 只链 `bin` 会让 DUT 跑上一个用例；
* 不给 `SIM_ARGS=`（会把 `+= -exitstatus` 一起吃掉，**卡死报成 PASS**）；
* `env -u VERDI_HOME -u NOVAS_HOME`（否则写共享 FSDB）。

### 8.4 建议新增的反向验证条目

| 变异 | 预期被抓 |
|---|---|
| 退休时忘记释放 `old_preg` | `rename_stress`（自由池慢慢漏干 → 卡死） |
| 冲刷时漏掉 `ALLOC → FREE` | 任意用例（preg 池漏干 → 卡死） |
| 冲刷时忘记清 `expt_entry.vld` | `trap`（错误路径异常凭空陷入） |
| `old_preg >= 32` 判据拿掉 | `rename_stress`（初始映射 p1..p31 被放回池） |
| 退休宽度写死 2 | CoreMark（指令数不变、周期变化 → difftest 仍绿，**要靠指标抓**） |
| `intmask` 门控拿掉 | `trap`（中断落在 CSR 指令上） |

---

## 9. 风险与已知的坑

| # | 风险 | 说明 / 对策 |
|---|---|---|
| R1 | **自由 preg 耗尽静默卡死** | 参考核只有 32 个自由 preg，**在途指令上限被压在 32**（64 项 ROB 填不满）—— 它 CoreMark 跑不起来是另一个原因（`ret` 把 `ra` 读成 0），但"自由池见底 ⇒ 前端停摆 ⇒ 看起来像卡死"是本核必须防的。对策：不变量 §4.2 + 仿真断言 + 上电自检打印 |
| R2 | 头部读 + 3 级联判退是新的关键路径 | 本核历史上关键路径一直在前端（`synth/` 报告）。RTU 引入 P1（64:1 mux → 判退级联）与 P2（`iid_oldest` 串进重定向链）两条新链。对策：D5 影子表项、D12 并行门控，全部列在 §4.2，且**每阶段用同一套 `synth/` 流程与基线比 Fmax** |
| R3 | 物理寄存器堆端口暴涨 | 3 发射要 6 个读口 + 3 个写口 + **3 个退休读口**（difftest 要数据）。RegFile 是别的计划，但**端口预算现在就要按 12 口规划** |
| R4 | 内存接口时序 | 现在 MEM 级组合直出（`CORE_DESIGN.md §8.3`）。改成"退休时写"之后，store 的地址/数据路径与现在的转发逻辑完全不同，**要重画时序图再动手** |
| R5 | 位宽静默截断 | `ifu2` 的历史 bug：漏写 wire 位宽被截成 1 位、`25'd1 << 26` 恒 0。RTU 里 `chk`/`iid`/`preg` 全是窄位宽，**每个 assign 都要核位宽** |
| R6 | X 传播 | 冲刷后表项要清干净（`vld/cmplt/chk`），否则 difftest 读到 X。这是"X & X = X"那个老坑的翻版 |
| R7 | 先用后声明 | `cpu/sim/rtl_patch/README.md` 记着：VCS 对先用后声明会造 1 位隐式线网，症状是**语义静默错**而不是报错。新写的 RTU 代码要避免 |

---

## 10. 待办与待定

分三类。**只有 A 类真的需要你定**；B 类我已经按建议定了，你随时可以推翻；
C 类不是决策，是我追踪的未决事项。

### A. 已拍板（2026-10-01）

**A1. Vivado 时序验收 —— 由用户亲自做。** ✅
所以计划不安排外跑流程，但**有两件事要交付给这次验收**：

* **先补基线报告**（见 §4.2 的 ⚠️）：183.9 MHz 那次的 `timing_summary.rpt` + 所用
  impl strategy 目前**没有入库**，仓库里最好的一条只有 170.4 MHz。
  不补的话，第一次验收会看到 −0.686 而误判成"RTU 把时序搞垮了"。
* **每次改完给一份"改前/改后"的关键路径对照**：`synth/build_fmax.tcl` 已经会打印
  `WORST_NON_EX`（最差非 ex_csr_addr 路径）与 500 条最差路径的起点/终点分布，
  直接贴报告即可，§4.2 的 P1~P8 表就是拿来对号入座的。

**A2. 重命名级由同事完成。** ✅ ⇒ 走 ②：**单开一份重命名计划，两边按 §6 对接。**
**连带后果（重要）**：§6 从此是**跨人契约**，不是内部笔记 —— 它必须
① 能独立读懂（不依赖本文其他 900 行）；② 端口名/位宽/方向/时序语义齐全；
③ 把"谁 stall 谁""谁先动"写死。已按这个标准重写过，见 §6 开头的说明。

**A3. 走阶段 1（提交点从 WB 搬到 ROB，仍然全顺序）。** ✅
这一阶段的副产品是把 §6 的契约**先跑通一遍**（用伪重命名顶替真重命名），
同事那边的真重命名可以并行开发，最后按同一组端口接上 —— 这正是选阶段 1 的额外好处。

**A4. §6 的端口一律用扁平编号，不用 SV unpacked array。** ✅（2026-10-01）
理由三条：本仓 `mySoC/**` 递归 grep 这类端口**一处先例都没有**；蓝本 C910 自己是
`rob_create0_*` / `rob_retire_inst2_cur_pc` 扁平编号；而 Fmax 验收要在 Vivado 上过，
**不该拿一个新语法当第一次综合实验**。位宽/语义不变，只是把数组拆成 `xxx0/1/2` 三组。

**A5. §6 补上物理寄存器堆访问口（A1 的洞）。** ✅（2026-10-01）
原 §6 一个 preg 访问口都没有，但 `dbg_commit_value` 要按 `dst_preg` 读、CSR 要按
`src1_preg` 读源操作数、CSR 的 rd 结果要到退休才算得出来。补齐：
`rtu_preg_raddr0/1/2` + `preg_rdata0/1/2`（difftest）、`rtu_csr_src_raddr/rdata`、
`rtu_csr_rd_we/addr/wdata`。**连带后果**：R3 的"12 口预算"变成 **10 读 + 4 写**，
要知会做寄存器堆与发射队列的那份计划。
另补 `is_mret` 进 `disp_flags`（4→5 位）与一个后端冲刷口 `rtu_backend_flush`（D11 的 FLUSH_1
必须有出口）。

### B. 我已按建议定了，你可以推翻（2 条，都不需要现在回答）

**B1. D1 的"最旧门控"取最严档。** 重定向在执行级发出，但只允许**最旧的非退休分支**发，
因此不需要分支快照。放宽门控能减小误预测代价，但要补整套快照机制
（D2/D3/D11 全部重写）。**建议先按最严的来把正确性钉死** —— 那时再放宽是**加法，不是返工**。
（另见 C2 的待核项。）

**B2. 物理寄存器数 96。** 提醒一句：**这个数对 RTU 侧几乎不花钱**
（自由池状态 96×2 = 192 bit，64 就是 128 bit，差 64 个触发器），
真正的代价在**寄存器堆的读口宽度**（96:1 比 64:1 多一级 LUT，6 个读口）。
所以**这个决定应该由"寄存器堆 + 发射队列"那份计划来下**，本计划只是按
"能填满 64 项 ROB"的需要建议 96；真选了 64，RTU 改一个 `parameter` 即可。

### C. 未决事项（不是决策，是我的追踪清单）

**C1. `read_entry` 影子表项要不要再多切一级** —— 由 §4.2 的实测决定，不由人定。
若 P1 仍是瓶颈，下一手是把判退级联也切开（C910 的 `rob_read*_commit` 是组合的、
`rtu_yy_xx_retire*` 是它的打拍版，等于留了个现成切点）。

**C2. `iid_oldest` 的显式判定**（D1 末尾的待核项）—— `ex1_pipe2_iid_oldest` 我只追到
它与其他待处理误预测比年龄，**没找到它与 ROB 退休指针比较的证据**。由另外两条事实
反推它必须等价于"最旧"才自洽。本核按 D12 直接做成显式的 7 位相等比较，不受这条影响；
但 C910 那边若有别的机制，值得再花半小时确认一次。
