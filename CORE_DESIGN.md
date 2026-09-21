# miniRV 核心设计要点

> **这是活文档。** 每实现一个功能，就在 §9 按模板追加一节，并回头更新
> §1（能力清单）和 §7（信号一览）。设计取舍的"为什么"写这里；
> bug 的发现与修复过程写 `DUT_BUG_REPORT.md`，两边不要互相抄。

本文只讲 **DUT（`mySoC/` 的 RTL）**。golden model / difftest / TB 侧的约定
见 `DUT_BUG_REPORT.md` 与 `dpi/`、`tb/` 里的注释。

---

## 1. 当前能力清单

| 能力 | 状态 | 落点 |
|---|---|---|
| RV32I 基础指令 | ✅ | `Control.v` |
| RV32M 乘除法（3 级流水乘法 + 32 拍恢复余数除法） | ✅ | `MUL_DIV.v` |
| 五级流水 / 前递 / load-use 停顿 / 分支冲刷 | ✅ | `Hazard_Detection.v` |
| MMIO：MONITOR / DIG / TIMER | ✅ | `perip_bridge.v` |
| M 模式 CSR（11 个地址） | ✅ | `CSR.v` |
| 同步异常 9 类：0/1/2/3/4/5/6/7/11 | ✅ | §4 |
| 机器定时器中断 MTIP | ✅ | §4.6 |
| `mtvec` 向量模式 | ⚠ 已实现但**未测试** | §4.1 |
| 计数器 `cycle/instret` | ✅ | `CSR.v` |
| 软件中断 MSIP / 外部中断 MEIP | ❌ 未实现 | — |
| `WFI` | ❌ 判为非法指令 | — |
| U/S 模式、delegation、PLIC | ❌ 未实现 | — |

---

## 2. 流水线总览

```
 IF ──► IF_ID ──► ID ──► ID_EX ──► EX ──► EX_MEM ──► MEM ──► MEM_WB ──► WB
 │                 │                │                  │                 │
 │ 取指            │ 译码+寄存器堆  │ ALU/MUL_DIV      │ 访存(组合)      │ 提交点
 │                 │ 立即数         │ 异常检出(非对齐/ │ Bus_* 直接出     │ 陷阱/中断裁决
 │                 │ 异常检出(取指  │ 越界)/CSR 读写   │ 去,不经寄存器    │ 寄存器写回
 │                 │ 越界/非法/ecall)                  │                 │
```

**关键事实（后面所有设计都建立在这上面）**

1. **提交点是 WB**：`have_inst_WB` 的脉冲就是"退休了一条指令"，
   与 golden model 的步进节拍一一对应。
2. **访存在 MEM 级是组合的**：`MEM.v` 当拍就把 `Bus_wen/Bus_addr/Bus_wdata`
   发出去，**比 WB 提交点早一拍**。这条约束直接决定了 §4.4 的四条拦截。
3. **复位是高有效异步**（`always @(posedge clk or posedge rst)`）。
4. **`RegFile` 读是组合的**，写是时序的；`SB/SH` 靠 `Bus_rdata` 做读-改-写，
   所以**存储周期也必须保持 `Bus_rdata` 有效**。

---

## 3. 控制信号一览（`Control.v`）

主译码是一个 `case (opcode)`，每个分支给全套控制信号。**坑见 §8.1。**

| 信号 | 含义 |
|---|---|
| `sext_op` | 立即数类型（I/S/B/U/J/**Z**） |
| `npc_op` | 下一条 PC 选择（PC+4 / 分支 / JALR 的 ALU / JAL） |
| `alu_op` / `alua_sel` / `alub_sel` | ALU 操作与两个操作数来源 |
| `rf_wsel` | 写回数据来源（ALUC / DRAM / PC4 / SEXT） |
| `rf_we` / `ram_we` | 写寄存器 / 写内存 |
| `is_muldiv` | 走 `MUL_DIV` |
| `is_illegal` `is_ecall` `is_ebreak` `is_mret` | 系统指令分类（本核新增） |
| `csr_op` `csr_addr` `csr_imm` `csr_we` | CSR 指令 (本核新增) |

---

## 4. 异常 / 中断机制（本核的核心定制）

### 4.1 陷阱点选在 WB（提交点）

参照 `cpu/src` 在 ROB 提交阶段裁决异常的做法。本项目没有 ROB，
**提交点就是 WB**。选它的理由：

- 与 difftest 的"提交步进"节拍天然对齐——一条指令一个脉冲。
- 精确陷阱：只有最老的指令能触发，年轻指令整条冲掉即可，不需要回滚。

`mepc = pc_WB`：陷阱指令自己的地址（与参考设计的 `rob_inst_addr_i` 一致）。

### 4.2 异常在哪些级检出、怎么携带

| 级 | 检出的异常 | 判据 |
|---|---|---|
| ID | 取指越界 (1)、非法指令 (2)、ebreak (3)、ecall (11) | `~INST_ADDR_OK(id_pc)` / `Control.is_*` |
| EX | 指令目标非对齐 (0)、load/store 越界 (5/7)、load/store 非对齐 (4/6) | `ex_target[1:0]!=0` / `~ADDR_IN_MAP(ex_alu_c)` / `ex_addr_bad` |

携带方式：`exc_valid / exc_cause[3:0] / exc_tval[31:0]` 三个字段
**逐级锁存**走过 `ID_EX → EX_MEM → MEM_WB`，到 WB 才裁决。

**合并点的优先级**（写在 `mycpu.v`）：

```
ID 级  : 取指越界 > 非法 > ecall > ebreak
EX 级  : 指令目标非对齐 > 访存越界 > 访存非对齐
ID vs EX: ID 级优先（二者实际互斥）
WB 裁决: 同步异常 / 中断 > mret，且中断只在"无副作用"提交点取（§4.4）
```

> 取指越界必须**压过非法指令**：IROM 只有 64KB，PC 跑到外面时
> `inst_addr = if_pc[15:2]` 会回绕，取回来的是**别的地址上的指令字**——
> 那是垃圾，不能再按它译码。

### 4.3 重定向与冲刷

```verilog
wire redirect = wb_exc | irq_taken | wb_mret;
wire [31:0] redirect_pc = wb_mret ? csr_mepc : csr_trap_vector;
```

`redirect` 当拍：

- **PC** ← `redirect_pc`（`PC.v` 新增 `trap`/`trap_pc` 端口）
- **IF_ID / ID_EX / EX_MEM / MEM_WB 全部清成气泡**

`EX_MEM` 与 `MEM_WB` 本来是**没有 flush 端口**的（`MEM_WB` 连 stall 都没有），
这次各加了一个。**必须加**：否则陷阱当拍"已经走到 MEM 的年轻指令"
下一拍照样提交。

### 4.4 四条副作用拦截 ⚠ 缺一不可

这是本核实现陷阱时**最容易搞错的地方**。根源就是 §2 的第 2 条事实：
**存储在 MEM 级就写下去了，比 WB 早一拍**，所以任何在 WB 发出的重定向
都**来不及拦住陷阱指令自己那次写**。

| # | 拦什么 | 表达式 | 为什么 |
|---|---|---|---|
| 1 | 陷阱指令自己的 store | `MEM.we_in = mem_ram_we & ~mem_exc_valid & ~redirect` | `~redirect` 只能拦"同拍在 MEM 的年轻 store"；自己那次在上一拍已经写了，只能靠 EX 级检出、随 `EX_MEM` 带上来的 `mem_exc_valid` 拦 |
| 2 | 被中断 squash 的指令 | `irq_taken = have_inst_WB & irq_safe & ~wb_exc & ~wb_mret & mip[7] & mie[7] & mstatus[3]`，其中 `irq_safe = ~ram_we & ~csr_we` | 被 squash 的指令若已经写过内存（MEM 级）或写过 CSR（EX 级），squash 会造成 DUT 与参考模型**永久不一致** |
| 3 | 年轻指令的 CSR 写 | `CSR.we_i = ex_csr_we & ~redirect` | 重定向当拍，EX 级那条更年轻的 CSR 指令的写会在这个边沿生效 |
| 4 | 陷阱指令的寄存器写 | `wb_rf_we_eff = wb_rf_we & ~wb_exc & ~irq_taken` | 非对齐 load 的 `rf_we=1`；**只改 `debug_wb_ena` 不够**——`RegFile.we` 和 `Hazard_Detection.wb_rf_we`（转发源）都在用 |

第 2 条还有个副作用：**中断延迟**——遇到 store / CSR 写的提交点要顺延到
下一个无副作用的提交点。这是有意的保守取舍。

### 4.5 异常 vs 中断：提交脉冲不一样

| | 提交脉冲 | 参考模型侧的动作 |
|---|---|---|
| 同步异常 | **发**（`ena` 强制 0） | 也要"执行"这条指令才能写 CSR / 跳 mtvec |
| 中断 | **不发**（WB 指令被 squash，`mret` 后重执行） | 不执行指令，只做陷阱入口 |

两者必须一致，否则 difftest 立刻失步。

### 4.6 中断：源、屏蔽、节拍

- **源**：只有机器定时器 MTIP（`perip_bridge.v` 的 `timer_int_flag = mtime >= mtimecmp`，
  电平有效，复位后 `mtime==mtimecmp==0` 所以**上电就是 1**，只能靠软件抬高
  `mtimecmp` 清掉）。
- **屏蔽**：`mstatus.MIE && mie.MTIE && mip.MTIP`。
- **节拍对齐**：`timer_int_flag` 是电平，而参考模型是提交步进的，自己算必然差拍。
  `myCPU` 内部把它**打一拍**（`timer_irq_d1`），TB 直接采这个信号推给参考模型
  —— 两边拿到的是**逐位相同**的值。**不要**在参考模型里用 mtime/mtimecmp 重算。

### 4.7 `have_inst` 必须是 IF_ID 的真实有效位

原来 `Control.v` 用一张 opcode 白名单产生 `have_inst`，有两个洞：

1. 不含 `0x73` → CSR / ecall / mret 根本不提交；
2. 未知 opcode 一律记 0 → **非法指令也不提交**，陷阱发不出去，参考模型一直等脉冲。

靠 `id_inst != 0` 也不行：气泡正好是全零，而 `.word 0x00000000` 恰恰是
一条合法的"非法指令"用例，两者必须区分。

**所以 `IF_ID.v` 增加一位 `id_have_inst`**：正常捕获置 1，flush/rst 清 0，
停顿保持。整条 `have_inst_ID/EX/MEM/WB` 链改由它驱动。

---

## 5. CSR 文件（`CSR.v`）

### 5.1 地址表

| CSR | 地址 | 实现位 | 读写 |
|---|---|---|---|
| `mstatus` | 0x300 | MIE(3)、MPIE(7)、MPP[12:11] 恒 `2'b11`（只读） | RW |
| `mie` | 0x304 | MTIE(7) | RW |
| `mtvec` | 0x305 | [31:2] 基址 + [0] 模式（[1] 恒 0） | RW |
| `mscratch` | 0x340 | 全 32 位 | RW |
| `mepc` | 0x341 | [31:2]（[1:0] 恒 0） | RW |
| `mcause` | 0x342 | 全 32 位（bit31 = 中断标志） | RW |
| `mtval` | 0x343 | 全 32 位 | RW |
| `mip` | 0x344 | MTIP(7)，硬件驱动 | **只读** |
| `mcycle`/`minstret` | 0xB00/0xB02 (+h 0xB80/0xB82) | 64 位 | 只读 |
| `cycle`/`instret` | 0xC00/0xC02 (+h 0xC80/0xC82) | 同上（别名） | 只读 |

只保存**已实现位**（WARL），未实现位读回恒 0。
未实现地址、或对只读 CSR 尝试写（`csrrw` 总是写；`csrrs/csrrc` 只要 `rs1!=x0` 就写）
→ **非法指令**。纯读 `csrrs rd, csr, x0` 对只读 CSR 仍然合法。

### 5.2 端口与写优先级

- **读口**：组合，`raddr_i = ex_csr_addr`，在 **EX 级**使用。
- **软件写口**：来自 EX，**必须用 `~redirect` 门控**（§4.4 第 3 条）。
- **硬件口**：`trap_i / trap_cause_i / trap_epc_i / trap_tval_i / mret_i / retire_i / timer_irq_i`。

写优先级（同一 `always` 块，靠后的覆盖靠前的）：
**计数器 → 软件写 → 陷阱入口 → mret**。

陷阱入口：`mepc←epc, mcause←cause, mtval←tval, MPIE←MIE, MIE←0`
mret：`MIE←MPIE, MPIE←1`

### 5.3 与参考设计（`cpu/src/csr_reg.v` + `clint.v`）的有意偏离

1. 参考把 `mstatus[6:4]` 当伪 MPP 且硬件从不写它。这里按规范用 `[12:11]`，
   且只有 M 模式，恒读 `2'b11`。
2. 参考的向量模式地址算成了 `(base + cause) << 2`——Verilog 里 `+` 优先级
   高于 `<<`。这里显式写成 `base + (cause << 2)`。
3. 参考对未实现 CSR 读返回 0、写静默丢弃，从不报非法指令。这里报非法指令。

### 5.4 CSR 指令怎么执行（两个反直觉的点）

- **读留在 EX 级**，`raddr_i = ex_csr_addr`，用 `ex_A_final` 直接喂 ALU 的 A 口。
  ⚠ **不能**走 ID 级的 `ALU_input_MUX`：读地址是 EX 级的锁存值，
  在 ID 级读会读到"当时 EX 里那条指令的地址"对应的值，而 A 口在 ID→EX
  边沿就锁存了——地址和数据错开一级（实测表现：`csrw` 后紧跟 `csrr` 读到旧值）。
- **源操作数是 rs1，不是 rs2**。对 `csrrw/rs/rc` 来说 `inst[24:20]` 属于
  **csr 域**，不是寄存器号。所以 `ID_EX` 单独锁存了一份"已转发的 rs1"（`ex_rD1`），
  走 A 通路的转发（`Forward_A_en`，按 `id_rR1` 判定）。
  `csrrwi` 系列的 uimm5 在 rs1 域，经 `Sext_Z`（`din[12:8]`）得到。

---

## 6. 寻址与访问异常

### 6.1 地址映射只有一处定义

`defines.vh`：

```verilog
`define ADDR_IN_MAP(a) ( ((a) <= 32'h0000_FFFF)                            \
                       || ((a) >= 32'h8000_0000 && (a) <= 32'h8000_0007) \
                       || ((a) >= 32'hFFFF_F000 && (a) <= 32'hFFFF_F003) \
                       || ((a) >= 32'hFFFF_F040 && (a) <= 32'hFFFF_F04F) )
`define INST_ADDR_OK(a)  ((a) <= 32'h0000_FFFF)
```

| 区间 | 归属 |
|---|---|
| `0x0000_0000 - 0x0000_FFFF` | DRAM（64KB 数据窗口） |
| `0x8000_0000 - 0x8000_0007` | MONITOR |
| `0xFFFF_F000 - 0xFFFF_F003` | DIG |
| `0xFFFF_F040 - 0xFFFF_F04F` | TIMER |
| 其余 | **访问异常**（load 5 / store 7 / 取指 1） |

**这个宏是唯一真源**：`mycpu.v`（异常判据）和 `perip_bridge.v`（写门控）
共用它。注意外设区间与 golden model 注册的
`Digit/TIMER/MONITOR` **一一对应**——不要"整页放行"，否则往未实现的外设写
会变成静默丢弃，和越界地址被静默别名是同一类病。

### 6.2 为什么必须有访问异常

原来 `dram_word_addr = {2'b00, Bus_addr[15:2]}` 把高位丢掉，
**≥64KB 的地址会被静默取模别名**（写 `0x0001_0000` 落到字节地址 0）。
既不合法、也不报错——最难查的一类问题。取指侧同理。

---

## 7. 新增信号一览（按模块）

### `IF_ID.v`
`id_have_inst`（输出，真实有效位，见 §4.7）

### `Control.v`（新增端口）
输入 `rs1_addr[4:0]`、`csr_addr[11:0]`；
输出 `is_illegal` `is_ecall` `is_ebreak` `is_mret` `csr_op[2:0]` `csr_imm` `csr_we`

### `ID_EX.v`
输入/输出各增加：
`csr_op[2:0]` `csr_addr[11:0]` `csr_we` `csr_imm` `is_mret`
`exc_valid` `exc_cause[3:0]` `exc_tval[31:0]`
以及输入 `id_rD1` / 输出 `ex_rD1`（§5.4）

### `EX_MEM.v`
新增 **`flush`** 端口；`irq_safe`、`exc_valid/cause/tval`、`is_mret`、`csr_we` 透传

### `MEM_WB.v`
新增 **`flush`** 端口（原来连 stall 都没有）；上述字段透传

### `PC.v`
新增 `trap` / `trap_pc`，优先级 **rst > trap > stall > din**

### `Hazard_Detection.v`
新增输入 `trap`，OR 进 `flush_IF_ID` 与 `flush_ID_EX`

### `myCPU`（顶层）
新增输入 `timer_irq_in`；内部新信号
`timer_irq_d1` `wb_exc` `wb_mret` `irq_taken` `redirect` `redirect_pc`
`trap_cause` `trap_tval` `wb_rf_we_eff` `retire_now` `csr_quiescent`
`ex_A_final` `ex_csr_src` `ex_csr_wdata` `id_inst_oob` `ex_load_oob` `ex_store_oob`

### `CSR.v`（新文件）
见 §5.2

---

## 8. 改这个核时要小心的坑（都是踩过的）

### 8.1 控制信号会 **latch**——别拿它当判据

`Control.v` 的有些分支**故意不赋值**某些信号（例如 `LUI` 不赋 `alua_sel/alub_sel`、
分支与存储分支不赋 `rf_wsel`），它们会**保持上一条指令的值**。

- ❌ 曾经用 `rf_wsel == RF_WSEL_DRAM` 判 load → 紧跟 `lw` 之后的 `bne`
  继承了 `rf_wsel`，被误判成非对齐 load 并报陷阱。
- ✅ 改用 `rf_we & (rf_wsel == DRAM)`：`rf_we`/`ram_we` 在**每一个** opcode
  分支里都赋了值，可以用来门控。

**新增判据前，先确认参与判定的信号在每条分支上都被赋值。**

### 8.2 流水线寄存器的三个 `always` 块必须同步

`ID_EX` / `EX_MEM` / `MEM_WB` 的 **payload 在一个块里，
`pc_o` 和 `have_inst_o` 各在独立的块里**，靠人工维护的条件链保持一致。
条件链一旦不同步，就会向流水线注入"`have_inst=1` 但 payload 已清零"的
**幽灵指令**，或者重复提交。加字段时**三个块都要改**。

### 8.3 `EX_MEM` 的 stall 是"插气泡"不是"保持"

`MEM_WB` 没有停顿端口，会照常锁存。所以 `EX_MEM` 在 `stall` 时必须**清零**
而不是保持，否则被冻结的同一条指令会在 `debug_wb_*` 上连续多拍重复出现，
被 difftest 当成多次提交。`flush` 与 `stall` 必须**在同一个分支里做同一件事**。

### 8.4 `PC` 的 `trap` 必须压过 `stall`

陷阱在 WB 发出，而同一拍完全可能正赶上一个 load-use 或 muldiv 停顿。
若让 `stall` 赢了，PC 被冻住，**陷阱向量被静默丢掉**。

### 8.5 阻塞/非阻塞与"最后赋值者胜"

`CSR.v` 的写用一个 `always` 块 + 显式排序（计数器 → 软件写 → 陷阱 → mret），
靠"后面的赋值覆盖前面的"。不要改成分别写多个块——那样优先级就说不清了。

### 8.6 `mret` 的 rs1 域是 0

`0x30200073` 里那个 `010` 在 **rs2 域**（`inst[24:20]`）。
按 `rs1 == 2` 判会把 `mret` 误判成非法指令（表现为 mret 自己陷入）。
本核用 csr 域区分：`ecall=0x000 / ebreak=0x001 / mret=0x302`，且都要求 `rs1==x0`。

### 8.7 取指越界不能用 `mepc+4` 恢复

handler 里"同步异常一律 `mepc+=4`"的惯例对取指越界**不成立**——
下一格地址照样取不到，会无限陷入。本核的 `trap.S` 里 cause 1 走独立分支，
恢复地址由测试预先放进 `mscratch`。

---

## 9. 后续功能的记录模板

每实现一个功能，在下面按这个模板**追加一节**，并更新 §1 与 §7：

```markdown
## 10. <功能名>

### 10.1 做了什么
（一段话，说清对外可见的行为）

### 10.2 设计取舍
（为什么这么做；考虑过哪些替代方案、为什么没选）

### 10.3 动了哪些文件 / 新增哪些信号
（照 §7 的格式列出来）

### 10.4 踩过的坑
（写清"错在哪、表现是什么、怎么发现"，方便下次不重犯）

### 10.5 验证方式
（哪个 asm 用例 / 哪条反向验证覆盖它）
```

### 追加时的自检清单

- [ ] `flush` / `stall` / `redirect` 的优先级是否想清楚了？会跟既有的
      `load_use_exist` / `branched` / `muldiv_stall` 打架吗？
- [ ] 新加的硬件动作**发生在哪一级**？它和 WB 提交点差几拍？
      **会不会在"已经发生、无法撤销"之后才被拦？**（§4.4 的教训）
- [ ] 新增的控制信号在 `Control.v` 的**每条** opcode 分支上都赋值了吗？（§8.1）
- [ ] 流水线寄存器加字段时，`pc_o` / `have_inst_o` 的条件链同步了吗？（§8.2）
- [ ] 这个功能会影响 difftest 的**提交脉冲**吗？会影响 golden model 的镜像吗？
- [ ] 有没有对应的 `asm/` 用例？**把关键门控拿掉，测试真的会失败吗？**
      （反向验证——本项目已经抓到过一次"改坏了也不报错"的假覆盖）
