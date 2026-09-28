# Golden Model 重建 + DUT Bug 修复报告

日期：2026-09-21
状态：**全部修复并验证通过**

> **本文只记"发现了什么问题、怎么定位、怎么修的"。**
> 核的**设计意图**（各模块怎么组织、为什么这么设计、扩展时要小心什么）
> 见 `CORE_DESIGN.md`——那是一份活文档，新功能的设计要点追加在那里。

---

## 0. 起因

RV32I CPU 上加了 RV32M 乘除法后，difftest 一直报不匹配。最初的怀疑是 golden model 被改坏了，
实际排查下来是**三层叠加**的问题：difftest 握手协议、golden model 自身缺陷、以及 RTL 里的 7 个 bug。

---

## 1. 第一层：difftest 步进节奏错误

**症状**：`addi` 测试在 cycle 23 报不匹配，golden 报 `pc=0x10, x3=2`，DUT 报 `pc=0x00, ena=0`。

**根因**：`tb/tb_miniRV_dpi.sv` 每周期调用 `gm_check_step()`，`dpi/dpi_shim.c` 则**无条件**调用
`cpu_run_once()` —— golden model 每**周期**推进一条指令；而 DUT 是 5 级流水线，每**可变周期数**
才退休一条。比较动作被 `dut_wb_have_inst` 保护，**推进动作没有**，两者必然漂移。

对照 `asm/addi.dump` 可确认 golden model 的算术完全正确（`pc=0x10, x3=2` 正是 `0x10: addi x3,x0,2`），
只是它已经跑完 5 条而 DUT 还在第 1 条。

原先 `golden_model/emu.c` 里的 `Pipeline_state` / `get_muldiv_stall_cycles()`（硬编码 MUL 停 2 拍、
DIV 停 32 拍）是想模仿 DUT 微架构时序来掩盖它，原理上就错，且任何其他停顿源都会立刻失步。

**修复**：改为**提交驱动**（`dpi/dpi_shim.c`）——只在 DUT 报告有效提交时推进一次：

```c
if (cpu_poll_halt()) return 0;        // 终止检测, 每周期都要跑（见下）
if (!dut_wb_have_inst) return 0;      // DUT 未提交 → golden model 原地不动
WB_info ref = cpu_run_once();          // 恰好推进一条架构指令
```

时序从此无关。`Pipeline_state` 那套整个删除。

**终止检测**：测试程序用 `ecall` 结束，但 `Control.v:45-49` 的 `have_inst` 白名单不含 opcode `0x73`，
DUT 从不把它当作退休指令，提交驱动的 difftest 永远等不到它。因此在 golden model 侧每周期轮询
`cpu.npc` 指向的指令是否为 ECALL（`emu.c: cpu_poll_halt()`）。

> ⚠️ 该轮询**必须在提交门控之外**执行（见 `dpi/dpi_shim.c` 的注释）——放进去会导致永远不被求值，
> 测试跑到周期上限才结束。

---

## 2. 第二层：golden model 的修复

以 `golden_model_reference/` 为基线重建（已验证与 git `9d3bbee` 完全一致），
保留 RV32M 扩展（译码 + 8 条指令 ALU 语义均验证正确），并修掉参考版固有缺陷：

| 位置 | 问题 |
|---|---|
| `WB.c` | `wb_ena==0` 时 `wb_value` 未初始化，返回栈垃圾 |
| `ID.c` `ID_S`/`ID_B` | `dst`/`wb_sel`/`br_op` 未初始化（改为结构体整体清零） |
| `ID.c` `0x73` 分支 | 全捕获 → EBREAK/CSR/WFI/MRET 都被当成 ECALL 退出（改为精确译码） |
| `EX.c` | `ECALL` 走 `exit()`，会从 DPI 内部杀掉整个 simv（改为由 TB 汇报） |
| `ID.c` | JALR 目标未清 bit 0 |
| `emu.c` | `init_memory` 无 `MEM_SZ` 边界检查 |
| `peripheral/result_monitor.c` | 缺 `break`（穿透后必然 panic）；`case 1` 在字节偏移语义下不可达，应为 `case 4` |

`result_monitor` 的 `case 4` 后来被 `coremark/riscv-port/test_end.h` 佐证：它用
`*MONITOR_ADDR = flag`（0x80000000）报 pass、0x80000004 报 fail。

**删除**：`golden_model_reference/`、`golden_model_rv32im/`（前者可从 git `9d3bbee` 完整恢复）。

---

## 3. 第三层：RTL 的 7 个 bug（已全部修复）

### BUG-1 `ID_EX.v` — stall 分支抹除正在执行的 MUL/DIV

`stall = load_use_exist || muldiv_stall`（`Hazard_Detection.v:80`），所以本意给 load-use 插气泡的
`stall` 分支，**乘除法停顿也走**，把 `ex_is_muldiv`/`ex_rf_we`/`ex_wR` 全清零：

- `ex_is_muldiv` 归零 → `muldiv_stall` 下一拍自我解除，停顿只维持 1 拍（MUL 需要 3 拍）
- `ex_rf_we`/`ex_wR` 归零 → 写回路径被销毁，乘积算出来也无处可去

**修复**：`stall` 时**保持**寄存器（不再清零），清零只由 `flush` 负责。
`pc_o` / `have_inst_o` 的条件链同步改成一致，消除"幽灵指令"。

### BUG-2 `EX_MEM.v` — 停顿时"保持"导致同一指令被重复提交

`EX_MEM` 原本在 `muldiv_stall` 时保持，但 `MEM_WB` **没有停顿端口**、照常每拍锁存，
于是被冻结的指令在 `debug_wb_*` 上连续多拍以相同值出现，被 difftest 当成多次提交。

**修复**：停顿时向 MEM 级**插入气泡**（清零），让 MEM/WB 正常排空。

> 这两个必须一起修：单独修 BUG-1 会让停顿从 1 拍变成完整 3 拍（DIV 是 30+ 拍），
> 重复提交反而更严重。

### BUG-3 `MUL_DIV.v` — `div_cnt` 位宽不足

```verilog
reg [4:0] div_cnt;          // 5 位，值域 0..31
if (div_cnt < 32)           // 恒为真 → DIV_DONE 永不可达
```
**修复**：扩为 `[5:0]`。

### BUG-4 `MUL_DIV.v` — 操作码寄存器位宽截断 ⭐

```verilog
reg [3:0] mul_op_stage1, mul_op_stage2, mul_op_stage3;
reg [3:0] div_op_save;
```
`defines.vh:30` 定义 `ALU_OP_WIDTH = 5`，而 `ALU_MUL = 16`、`ALU_DIV = 20` 都需要 5 位。
4 位截断后 `16 → 0 (ALU_ADD)`，输出逻辑的 `case (mul_op_stage3) ALU_MUL:` **永远不匹配**，
落到 `default: result = 32'b0` —— **乘积算对了却在最后一步被丢弃，写回 0**。

**修复**：改为 `[`ALU_OP_WIDTH-1:0]`。

### BUG-5 `MUL_DIV.v` — 除法算法被非阻塞赋值破坏

```verilog
remainder <= {remainder[62:0], 1'b0};              // 全 64 位
if (remainder[63:32] >= divisor_abs) begin          // 读到的是移位【前】的旧值
    remainder[63:32] <= remainder[63:32] - divisor_abs;   // 仅高 32 位，覆盖上面那条
```
两处错误叠加：`if` 读旧值；且"整体左移"与"只减高 32 位"两条赋值混用时，
后者覆盖前者，**低位向高位的进位（`remainder[31]`）被丢弃**。
结果 100/7 算成 5 而不是 14。

**修复**：用阻塞赋值先算出 `remainder_shift`，比较与相减都基于它。

### BUG-6 `MUL_DIV.v` — 乘法器在流水线未排空时重复接受操作

CPU 在等待 `ready_o` 期间会一直保持 `valid_i` 为高（因为它把这条 MUL 保持在 EX 级），
于是 3 级流水线被同一条指令反复灌入，`mul_valid_stage3` 不止一拍为高。
**下一条紧邻的 MUL** 进入 EX 时会看到残留的 `ready_o=1`，既不产生停顿，又取走一个陈旧的
stage3 值 —— 单独测 `mul` 看不出来，CoreMark 的背靠背 MUL 才暴露。

**修复**：增加 `mul_pipe_empty` 条件，只在流水线排空时接受新操作。

### BUG-7 `MUL_DIV.v` — REM/REMU 读错半个寄存器

恢复余数除法跑完后，最终余数留在 `remainder` 的**高 32 位**，低 32 位是移位过程中被除数移出的比特。
但输出逻辑写的是 `remainder[31:0]`：

```verilog
`ALU_REM:  result = div_sign_r ? (~remainder[31:0] + 1) : remainder[31:0];
`ALU_REMU: result = remainder[31:0];
```
**修复**：改为 `[63:32]`。同时修正除零时 REM/REMU 的返回值——按规范应返回**原始被除数 rs1**，
而不是它的绝对值（新增 `dividend_orig` 保存）。

---

## 4. 未改动项

`Control.v` 的 `have_inst` 白名单仍不含 `OPCODE_SYSTEM`，ECALL 依旧不作为退休指令提交。
终止仍由 golden model 侧轮询实现。

这样处理是有意的：轮询方式不依赖 DUT 的调试端口插桩，对 difftest 而言更稳健。
若希望 ECALL 像普通指令一样退休（difftest 能自然比对它），需要：
1. `Control.v:45` 把 `OPCODE_SYSTEM` 加入白名单（`rf_we=0`、不访存、NPC 顺序）；
2. `emu.c` 改成"先执行 ECALL 再置 halt"，去掉每周期轮询。

---

## 5. 验证结果

```
RV32I + RV32M 全部测试：PASS=41, FAIL=0
```

含 `mul` 与 `div`。覆盖分支冲刷（`jal`/`bne`）、load-use 冒险（`lw`/`lb`）、
以及乘除法停顿路径。

**CoreMark**（`-march=rv32im`，会真正走硬件乘除法）：
以 **3,000,000 周期**运行，**零不匹配**（0 处 Diffrence）。
注意 CoreMark 用 `sim_end()` 死循环写 MONITOR 外设来结束，**没有 ECALL**，
所以它不会报 "Test Point Pass"，只会跑到周期上限——判据是日志中不出现 `Diffrence`。

### 复现

```bash
export VCS_HOME=/mnt/tools/synopsys/vcs/V-2023.12-SP2
export VERDI_HOME=/mnt/tools/synopsys/verdi/V-2023.12-SP2
export SNPSLMD_LICENSE_FILE=27000@192.168.50.152     # 来自 /mnt/tools/env/eda.cshrc
export PATH=$VCS_HOME/bin:$VERDI_HOME/bin:$PATH

make build
make run TEST=mul            # Test Point Pass!
make run TEST=div            # Test Point Pass!
make run TEST=coremark MAX_CYCLES=300000
```

### 调试手段

- `GM_TRACE=1 make run TEST=mul` —— 逐条打印 DUT 与 golden model 的提交对照
- `+TRACE` —— 逐周期流水线探针（`tb/tb_miniRV_dpi.sv`），输出各级 PC、`have_inst` 链、
  停顿/冲刷信号、`MUL_DIV` 三级流水线状态与 EX/MEM/WB 写回信息：

```bash
ln -sf "$PWD/bin/mul.bin" meminit.bin
./obj_vcs/simv +vcs+lic+wait +MAX_CYCLES=5000 +TRACE
```

---

## 6. 附注：两个非有效测试用例

`bin/test_minimal.bin`、`bin/test_simple.bin` 由 `coremark/riscv-port/test_minimal.S` 与
`test_simple.c` 生成，**都不含 ECALL**，无法正常终止：

- `test_minimal` → 跑到周期上限（TIMEOUT）
- `test_simple` → 跑飞后越界访存，golden model 的 `Assert` 中止进程

建议补上 ECALL 结尾，或从 `bin/` 移除，以免污染 `make run-all` 的结果。

---

# 第二阶段：添加 MMIO 外设 + CoreMark 跑分

## 7. 起因

测 CoreMark 分数时发现三件事：

1. **DUT 完全没有 MMIO**。`miniRV_SoC.v` 只有 CPU + IROM + DRAM，而 golden model
   （`emu.c`）却注册了 MONITOR@0x80000000 和 Digit@0xFFFFF000。于是 `0x80000000` 的写
   被 `Bus_addr[15:2]` 截断后**静默落到 DRAM 第 0 个字**——difftest 发现不了，
   因为存储指令不写寄存器，比较不到。
2. **CoreMark 的计时器是死代码**。`core_portme.c` 的 `timer_counter` 从未被赋值，
   `Total cycles: 0`，`1000000/0` 除零，报出 `CoreMark Score: -1.-01`。
3. `sim_end()` 写在 `iterate()` 里且是死循环，`main()` **永远走不到 CRC 校验**。

## 8. 新增：`mySoC/perip_bridge.v`

地址映射沿用 `mySoC/defines.vh` 既有定义（`PERI_ADDR_DIG = 0xFFFF_F000` 正好与
golden model 注册的 `Digit` 一致），新增 `PERI_ADDR_TIMER 32'hFFFF_F040`：

| 地址 | 外设 | 说明 |
|---|---|---|
| `0x8000_0000` / `+4` | MONITOR | pass/fail 标志（+0）、fail 标志（+4）、字符输出 |
| `0xFFFF_F000` | DIG | 数码管，可回读 |
| `0xFFFF_F040`–`F04F` | TIMER | mtime lo/hi、mtimecmp lo/hi（照参考 `cpu/src/timer.v` 约定） |

设计约束（来自 `mySoC/MEM.v`，均已核实）：

- **读必须当拍组合返回**——MEM 级没有 ready/busy/stall
- **存储周期也要保持 DRAM 读数据有效**——`MEM.v` 用 `Bus_rdata` 给 `sb`/`sh` 做读-改-写
- **写只能用 `Bus_wen` 限定**——`Bus_wdata` 在 `Bus_wen==0` 时是寄存器保持的垃圾
- **总线上看不出 `sb`/`sh`/`sw`**（无字节使能）→ 外设只能按整字 `sw` 写
- **解码在 `Bus_addr[15:2]` 截断之前**，并用解码结果门控 DRAM 写

golden model 侧新增 `peripheral/timer.c` 镜像同样语义；`emu.c` 的 `is_peripheral`
边界从闭区间改为左闭右开，与 RTL 解码严格一致。

## 9. 本阶段修复的 bug

### BUG-8 `vsrc/ram.v` — `mem_rd` 未清零导致 X 传播 ⭐

```verilog
reg [32-1:0] mem_rd[(2**20)-1:0];   // 从未初始化
...
$fread(mem_rd, mem_file);            // 只填镜像覆盖到的字
for (...) mem[j] = {byteswap(mem_rd[j])};   // 但把【每个字】都赋给了 mem[]
```
镜像之外的字保持 X，于是**任何读到未初始化 DRAM 的 load 都会把 X 灌进寄存器**。
X 一旦进入分支条件，DUT 就会走错路径，并且一路传播。

现场（`+TRACE`，CoreMark 在 cycle 536455 报不匹配）：

```
[T536450] EX wR=15 wD=00000000 | MEM we=1 wR=15 wD=xxxxxxxx   ← load 在 MEM 级变成 X
[T536451] (beq a5,x0) EX we=1 wR=15 wD=0000000X alu_c_final=0000000X
```
前一条 `andi a5,a5,1` 双方都提交了 a5=0，本该跳转的 `beq a5,x0,2994` 却没跳。

**修法**：`$fread` 之前先清零 `mem_rd`（IROM 和 DRAM 都要，因为两边都用了同样的模式）。
这也让 DUT 与 golden model（`memory[]` 是零初始化 BSS）行为一致。

### BUG-9 CoreMark 栈溢出（`riscv-port/link.ld`）

```
000036e8 B _bss_end          ← 程序映像结束
00004000 B _stack_top        ← 栈顶(RAM LENGTH = 16K)
```
可用栈空间只有 **2328 字节**，而 `main()` 里的局部数组 `stack_memblock[2000]`（CoreMark 的
工作区）一项就占 2000 字节 → 栈压穿 `.data`/`.bss`，踩掉 `default_num_contexts`(0x36c0)、
`seed4_volatile`(0x36c4) 等全局量。

症状：`Iterations : 234`（实际是 1）、报告循环越界打印 `results[1..11]`。

**注意**：DUT 与 golden model 跑同一个程序、踩法完全一样，所以 **difftest 全程不报错**——
这类问题只能靠程序自身的自检（CRC）暴露。

**修法**：`RAM LENGTH` 16K → 64K（CPU 的数据窗口本来就是 `Bus_addr[15:2]` 决定的 64KB，
golden model 的 `MEM_SZ` 也是 64KB）。`_stack_top` 变成 0x10000，栈有 ~51KB。

### 一个我自己引入又修掉的回归

我先前看到 `iterate()` 里只有 list 循环，误判为「matrix / state 从未被调用」，并补了两段
显式循环。**这是错的**：标准 CoreMark 的 matrix/state 是通过 `core_list_join.c:calc_func()`
在 list 内部间接调用的，并在那里设置 `crcmatrix`/`crcstate`：

```c
case 0: retval = core_bench_state(...);  if (res->crcstate  == 0) res->crcstate  = retval;
case 1: retval = core_bench_matrix(...); if (res->crcmatrix == 0) res->crcmatrix = retval;
```

补的显式循环会**覆盖** `calc_func` 算好的值，导致 matrix/state CRC 报错。已回退，
`iterate()` 现在只保留 list 循环（即标准结构）+ 计时括号。

## 10. 结果

**回归：42/42 通过**（41 个原有 + 新增的 `asm/peri.S` 外设定向测试）。

`asm/peri.S` 覆盖：MONITOR 写后回读、TIMER mtime 递增、mtime 高位、mtimecmp 读写、
DIG 回读，以及**写 MMIO 不再污染 DRAM[0]**（就是上面第 1 条那个静默 bug）。

**CoreMark 跑分**（`-march=rv32im`，`ITERATIONS=25`，11.0M 周期，40 秒仿真）：

```
CoreMark Size    : 666
Total ticks      : 11017585
Total time (secs): 11                 ← 满足 CoreMark 的 >=10 秒有效性规则
Iterations       : 25
seedcrc          : 0xe9f5             ← 2K performance run
[0]crclist       : 0xe714   ✓
[0]crcmatrix     : 0x1fd7   ✓
[0]crcstate      : 0x8e3a   ✓
Correct operation validated. See README.md for run and reporting rules.

Average cycles/iteration: 440702
CoreMark Score: 2.269 (iterations/sec)/MHz
```

**≈ 2.27 CoreMark/MHz**，三个工作负载的 CRC 全部与官方常量匹配，且满足 10 秒有效性规则。

复现：
```bash
make -f Makefile.coremark ITERATIONS=25     # 迭代次数可覆盖
make run TEST=coremark MAX_CYCLES=30000000
```
默认 `ITERATIONS=1`（约 44 万周期，秒级）跑得快，但会触发 CoreMark 自己的
"Must execute for at least 10 secs for a valid result" —— 那是有效性规则，不是 CPU 错误。

## 11. mtime 与流水线相位的对齐

DUT 的 `mtime` 是自由计数器，而 golden model 是**按提交步进**的：一条指令在 MEM 级读到
mtime，要到下一拍才出现在 WB 上被 difftest 看见。所以 testbench 必须把 DUT 的真实
`mtime` **延迟 1 拍**再喂给 golden model：

```systemverilog
mtime_d1 <= dut.u_bridge.mtime;          // 1 拍延迟(实测: 2 拍会让参考值小 1)
gm_set_timer(mtime_d1[31:0], mtime_d1[63:32]);
```

这样做 timer 的**值**由 DUT 提供，difftest 不会去校验计时器本身（计时器是环境状态而非
架构状态）；计时器逻辑由 `asm/peri.S` 单独验证。

---

# 第三阶段：RISC-V 异常 / 中断处理机制

## 12. 起因

在此之前 miniRV 是一个纯顺序执行的 RV32IM 五级流水线，**完全没有特权态概念**：
`grep -riE "csr|trap|mstatus|mcause|mtvec|privilege" mySoC/` 零命中。
`Control.v` 的 `have_inst` 是一张 opcode 白名单，**不含 `0x73`**，
所以 `ecall` 根本不进流水线——difftest 只能靠 golden model 在取指前
"偷看" `memory[cpu.npc>>2]` 是不是 `ecall` 来终止测试（`emu.c:44-79`）。
另一头，`perip_bridge.v:125` 的 `timer_int_flag = (mtime >= mtimecmp)` 悬空，
`miniRV_SoC.v` 的注释自己写着"本 CPU 未接中断"。

目标：参照 `cpu/src`（`csr_reg.v` + `clint.v`），实现一套 **M 模式、精确陷阱**的
异常/中断机制，并把它纳入 difftest 的覆盖范围。

范围（用户选定）：异常 6 类（0/2/3/4/6/11）+ 机器定时器中断 MTIP +
CSR 五条指令 + `mcycle/minstret` 计数器。

## 13. 设计要点

**陷阱点选在 WB（提交点）**，与参考设计在 ROB 提交阶段裁决异常一致。
`have_inst_WB` 脉冲就是"提交"，与 golden model 的步进节拍一一对应。

- 异常在 ID（非法/ecall/ebreak）与 EX（非对齐）检出，
  作为 `exc_valid/exc_cause/exc_tval` 随 ID_EX → EX_MEM → MEM_WB 传到 WB。
- `mepc = pc_WB`（陷阱指令自己的地址）。
- `redirect = wb_exc | irq_taken | wb_mret` 当拍：
  PC ← 重定向地址，**IF_ID / ID_EX / EX_MEM / MEM_WB 全部清成气泡**。

### 异常 vs 中断在"是否提交"上的区别（必须与 golden model 一致）

| | 提交脉冲 | 原因 |
|---|---|---|
| 同步异常 | **发**（该指令以陷阱形式完成，`ena=0`） | 参考模型也要执行它才能写 CSR / 跳 mtvec |
| 中断 | **不发**（WB 指令被 squash，`mret` 后重执行） | 参考模型不执行指令，只做陷阱入口 |

### 四条"副作用拦截"（设计评审发现，缺一不可）

本流水线的存储是在 **MEM 级（组合）**就写下去的，比 WB 提交点早一拍。
因此任何在 WB 发出的重定向都**来不及拦住陷阱指令自己那次写**：

1. `MEM.we_in = mem_ram_we & ~mem_exc_valid & ~redirect`
   —— `~mem_exc_valid` 拦陷阱指令自己的 store（EX 级检出，随 EX_MEM 带过来）；
   `~redirect` 拦同拍在 MEM 的那条更年轻的 store。两者互斥，合起来是精确的。
2. `irq_safe = ~ram_we & ~csr_we` 沿流水线传到 WB；
   `irq_taken = have_inst_WB & irq_safe & ~wb_exc & ~wb_mret & mip[7] & mie[7] & mstatus[3]`
   —— 被 squash 的指令若已经写过内存（MEM 级）或写过 CSR（EX 级），
   squash 会造成 DUT 与参考模型**永久不一致**。
3. `CSR.we_i = ex_csr_we & ~redirect` —— 重定向当拍，EX 级那条更年轻的 CSR 写会漏进 CSR 文件。
4. `wb_rf_we_eff = wb_rf_we & ~wb_exc & ~irq_taken`，同时用于 `RegFile.we`、
   `Hazard_Detection.wb_rf_we`、`debug_wb_ena`
   —— 非对齐 load 的 `rf_we=1`，只改 `debug_wb_ena` 的话寄存器堆照样写进垃圾值，
   而且还会被后面的指令转发走。

### `have_inst` 改成 IF_ID 的真实有效位

原来的 opcode 白名单有两个洞：不含 `0x73`（CSR 指令不提交），
且未知 opcode 一律记 0（**非法指令也不会提交**，陷阱根本发不出去，
参考模型等不到脉冲会一直卡住）。靠 `id_inst != 0` 也不行——
气泡正好是全零，而 `.word 0x00000000` 恰恰是一条合法的"非法指令"用例。
所以 `IF_ID` 增加一位 `have_inst`：正常捕获置 1，flush/rst 清 0，停顿保持。

### 中断的节拍对齐

`timer_int_flag` 是电平信号，而参考模型是提交步进的，自己算必然差拍。
沿用已有的 `mtime_d1` 先例：TB 直接采 DUT 内部**它自己正在用的那一级寄存信号**
（`dut.Core_cpu.timer_irq_d1`）推给参考模型，两边拿到的是逐位相同的值。

中断检查放在 `dut_wb_have_inst` 门**之内**：DUT 只在提交点取中断，
流水线停顿时 WB 是气泡、不取中断；每拍都查会让参考模型提前几拍取中断而失步。

### ECALL 兼容层

`cpu_poll_halt()` 增加 `mtvec == 0` 条件：参考模型只把**没装 handler 时**的 ecall
当成"测试结束"。现有几十个测试从不写 mtvec，行为与实现陷阱前完全一致；
要测真正的 ecall 异常，测试自己先写 mtvec 即可。

### CSR 也要纳入 difftest

原来只比 `wb_pc/wb_ena/wb_reg/wb_value`，**CSR 状态完全不可见**，
而 `mstatus.MIE` 一错中断节拍立刻发散。新增 `gm_check_csr()`，
但只在 `csr_quiescent = ~redirect & ~ex_csr_we & ~mem_csr_we & ~wb_csr_we` 时比较：
DUT 在 EX 级写 CSR（比提交早 2 拍），参考模型在提交当拍才写，
在途窗口里比较会误报。

## 14. 本阶段发现的 bug

### 14.1 既有代码里的（与本阶段无关，但一直被掩盖）

**BUG-10（重要）：golden model 的 SYSTEM 译码一直是死代码。**
`case B8(1110011)` 只写了 7 位，而 `B8(B0)` 展开成 `0x##B0`——
参数紧挨着 `##` 不会预展开，于是拼出来的是字面量 `0xB1110011` 而不是 `0x73`。
**这个 case 从来没有命中过**，以前的 ecall 只靠 `emu.c` 的偷看生效。
正确写法是 8 位：`B8(01110011)`。

**BUG-11（重要）：`$fatal` 在 VCS 下不返回非零退出码。**
实测：TB 打印了 `Fatal:` 和 `Test Point Failed`，但 `simv` 的 `$?` 仍是 **0**。
`run-all` 是按 make 退出码统计的，于是**所有失败都被算成 PASS**——
包括 difftest 不匹配那条路径。修复：给 simv 加 `-exitstatus`。
这解释了此前"回归全绿"里 coremark 明明打印 `Test Point Failed` 却被列入 Passed。

**BUG-12：TB 的周期上限超时走 `$finish`（exit 0）**，跑飞到超时会被算成通过。
这正好会把"节拍失步"伪装成通过（失步的典型表现就是卡住到超时）。
已改成 `$fatal(1, ...)`。

**BUG-13：`bin/test_simple.bin` 不是有效测试。**
它由 `coremark/riscv-port/test_simple.c` 直接编译而来，开头是 `addi sp,sp,-16`
（C 函数序言），**没有复位向量**，而且 `main` 体是 `while(1)` 死循环、无终止路径。
CPU 从 PC=0 跑飞后乱写内存，触发 golden model 的 `mem_store` 断言而 abort。
`test_minimal` 已覆盖同样的 MONITOR/终止路径，故将其从回归中移除。
（源文件 `coremark/riscv-port/test_simple.c` 未删，留作参考。）

**BUG-14：`bin/coremark.bin` 的默认构建按 CoreMark 自己的规则判失败。**
`Makefile.coremark` 里 `ITERATIONS ?= 1`，而本 port 把 1 周期 = 1 tick = 1us，
CoreMark 规定有效跑分必须持续 ≥10 秒 → `time_in_secs = 478133/1e6 = 0`
→ 打印 `ERROR! Must execute for at least 10 secs` → 写 `0xDEAD` 判失败。
这是**正确行为**，不是 bug；要有效跑分就 `make coremark ITERATIONS=25`（约 11.0M 周期，41 秒）。
`run-all` 为此给 coremark 单独的 `COREMARK_MAX_CYCLES=15000000`。

### 14.2 本阶段实现中我自己写错、又定位修掉的

1. **`ex_is_load` 的判据不可靠**：起初用 `rf_wsel == RF_WSEL_DRAM` 判 load，
   但 `rf_wsel` 在**分支/存储**分支里是不赋值的（它们不写寄存器），会 latch 住上一条的值——
   紧跟 `lw` 之后的 `bne` 带着 `rf_wsel=DRAM`，被误判成非对齐 load 并报陷阱。
   改用 `rf_we & (rf_wsel == DRAM)`：`rf_we`/`ram_we` 在**每一个** opcode 分支里都赋了值。
   > ⚠️ **2026-09-28 更正**：那个 latch 已经修掉了（`Control.v` 的 case 前加了无条件默认值，
   > 全设计 112 个推断 latch 归零）。但 `rf_we & (...)` 这层门控**保留**——它是对的，
   > 而且 latch 消失不代表"这个信号在这条指令上有意义"这件事变成真。
2. **CSR 的源操作数是 rs1，不是 rs2**。对 `csrrw/rs/rc` 来说 `inst[24:20]` 属于 **csr 域**，
   不是寄存器号。起初走了 B 口的 RD2 通路，`csrw mtvec, t5` 实际读的是 `t0`(=0)。
   改为在 `ID_EX` 里单独锁存一份"已转发的 rs1"（`ex_rD1`）。
3. **CSR 读不能放在 ID 级的 A 通路**。CSR 读地址 `ex_csr_addr` 是 **EX 级**的锁存值，
   在 ID 级读会读到"当时 EX 里那条指令的地址"对应的值，而 A 口是在 ID→EX 边沿锁存的——
   等真正到 EX 用时地址已经变成本条指令的，数据却是上一条的。
   实测表现就是 `csrw` 后紧跟 `csrr` 读到旧值。改为在 EX 级用 `ex_A_final` 直接取。
   > ⚠️ **2026-09-28 改回去了，但换了做法**：为了 FPGA 时序（那条 16:1 读 mux 是
   > 关键路径的链头），CSR 读搬回 ID 级 —— 但用的是**本条指令自己的** `id_csr_addr`
   > (`inst[31:20]`)，不是 EX 锁存的那个；结果随新增的 `ID_EX.id_csr_rdata → ex_csr_rdata`
   > 锁一拍进 EX，并配一条 `ex_csr_we & ~redirect & (ex_csr_addr == id_csr_addr)` 的
   > EX→ID 旁路。上面这条 bug 的教训仍然成立：**别用 EX 锁存的地址去 ID 级读**；
   > 另外 CSR 值仍然**不能**塞进 ID 级的 A 通路（A 口是转发通路，`Forward_A_en`
   > 会把它覆盖掉），所以走的是独立的 `ex_csr_rdata` 字段。
4. **`CSRRWI`(funct3=101) 漏了映射**，落进内层 `case` 的 `default:` 被当成 `CSRRC`（清位）。
5. **`mret` 的 rs1 域是 0**，那个 `010` 在 **rs2 域**（`inst[24:20]`）里。
   按 `rs1 == 2` 判会把 `mret` 误判成非法指令（表现为 mret 自己陷入）。
   改为用 csr 域区分：ecall=0x000 / ebreak=0x001 / mret=0x302，且都要求 rs1==x0。
6. **golden model 侧 `ID_SYSTEM` 忘了置 `is_mret`**，`mret` 不重定向，
   参考模型继续顺序执行 → 与 DUT 立刻失步。
7. **CSR 比较在"在途窗口"误报**：DUT 在 EX 写、参考模型在提交当拍写，
   中间隔着 2 拍，无条件比较必然误报。加 `csr_quiescent` 门控后解决。

### 14.3 与参考设计的有意偏离

- 参考把 `mstatus[6:4]` 当作伪 MPP 且硬件从不写它。这里按规范用 `[12:11]`，
  且因为只有 M 模式，恒读 `2'b11`（只读）。
- 参考的向量模式地址算成了 `(base + cause) << 2`——Verilog 里 `+` 的优先级高于 `<<`。
  这里显式写成 `base + (cause << 2)`。
- 参考对未实现的 CSR 读返回 0、写静默丢弃，从不报非法指令。
  这里未实现地址 / 写只读 CSR 都判**非法指令**。

## 15. 验证结果

```
make run-all   →  Passed: 45  Failed: (none)    difftest/CSR 不匹配数: 0
make run TEST=trap
  → Test Point Pass!
make run TEST=coremark MAX_CYCLES=15000000
  → Total ticks 11017585 / crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a
  → Correct operation validated / CoreMark Score: 2.269 (iterations/sec)/MHz
```

CoreMark 的数字与加陷阱机制**之前完全一致**（11,017,585 ticks，2.269），
这是"陷阱改动没有污染正常执行路径"的最强证据。

新增 `asm/trap.S` 覆盖：CSR 五条指令的旧值语义、ecall(11)、ebreak(3)、
非法指令(2)+mtval、load 非对齐(4)、store 非对齐(6)、jalr 目标非对齐(0)、
store 越界(7)、load 越界(5)、外设页未实现偏移(5)、取指越界(1)、
定时器中断(0x80000007)+mret 恢复 MIE。
其中两处是**专门为交叉验证设计的**：
- 非对齐 load 之后检查 rd **没有被改写**（验证 `wb_rf_we_eff` 的源头门控）；
- 非对齐 store 之后回读该地址，确认**内存没有被写**（验证 `~mem_exc_valid` 门控）。

### 反向验证（证明这些测试真的能失败）

只看"改完还全绿"是没有说服力的——一个"改坏了也不报错"的测试等于没测。
逐项故意注入错误，确认**每一项都被抓到**：

| 注入的错误 | 结果 |
|---|---|
| `mepc` 写成 `pc_WB + 4` | ✅ 抓到（handler 读到的 mepc 变成 0xd0） |
| 去掉 `irq_safe` 门控 | ✅ 抓到（中断落在 store/CSR 写的提交点上，失步） |
| 把中断检查挪到提交门外 | ✅ 抓到（参考模型提前取中断，失步） |
| 去掉 `~mem_exc_valid` 门控 | ✅ 抓到（非对齐 store 真的写进了内存） |
| 去掉 DUT 的越界异常上报 | ✅ 抓到（mcause 不符） |
| 只恢复桥的越界别名 | ❌ 抓不到（见 16.2——CPU 侧已经挡住了，属纵深防御） |

> 第一版 `trap.S` 的自旋等待循环里全是无副作用的指令，
> 去掉 `irq_safe` 门控**照样通过**——说明那条路径没被覆盖。
> 已在循环体里加入一条 store 和一条 CSR 写，之后该项才真正可被检出。

## 16. 遗留项与归因

按"是 DUT 的问题、参考模型的问题，还是验证覆盖不到"三类重新归因：

| 项 | DUT | 参考模型 | difftest 覆盖 |
|---|---|---|---|
| 1. 中断 squash 与 store/CSR 写 | 无缺陷（已完全挡住） | 无缺陷 | ✅ 反向验证 #2 |
| 2. 地址越界（≥64KB 非外设） | ~~缺陷~~ **已修复**（见 16.2） | ~~不合格~~ **已修复** | ✅ 新增定向用例 |
| 3. 计数器 CSR | 无缺陷 | **局限**：提交步进，原理上算不出周期数 | ❌ 有意排除 |
| 4. 仅 M 模式 | 非缺陷（范围决定） | 同左 | — |

### 16.1 中断 squash 与 store/CSR 写 —— 两边都不是问题

**上一版这里写错了**，把它列成"局限"是自相矛盾的：既然 `irq_safe` 挡住了，
就不存在"参考模型要到 mret 后才看见"的偏差。

准确的说法是：`irq_safe = ~ram_we & ~csr_we` 沿流水线传到 WB，
中断**只落在没有副作用的提交点上**，DUT 与参考模型用同一个条件
（参考模型直接采 `dut_wb_irq_safe`），所以两边行为逐位一致，不存在偏差。
被 squash 的指令唯一可能的副作用（写寄存器）由 `wb_rf_we_eff` 同拍按掉。

真正的代价是**中断延迟**：遇到 store / CSR 写的提交点要顺延到下一个
无副作用的提交点才取中断。这是有意为之的保守取舍，不是正确性问题。
（该路径由反向验证 #2 守着——去掉门控立刻失步。）

### 16.2 地址越界 —— 已修复

**原来的问题**：DUT 侧 `dram_word_addr = {2'b00, Bus_addr[15:2]}` 把高位丢掉，
数据窗口只有 64KB，**任何 ≥64KB 且不属于外设的地址都被静默取模别名**
（写 `0x0001_0000` 实际落到字节地址 0）。既不是合法访问、也不报异常——
最难查的一类问题。取指路径同理（`inst_addr = if_pc[15:2]`）。
模型侧则直接 `Assert` 把宿主进程 `abort()` 掉，那也不是任何合法的架构行为。

**修法**：两边都补上访问异常，并且判据**只有一处定义**。

`mySoC/defines.vh` 新增：
```verilog
`define ADDR_IN_MAP(a) ( ((a) <= 32'h0000_FFFF)                            \
                       || ((a) >= 32'h8000_0000 && (a) <= 32'h8000_0007) \
                       || ((a) >= 32'hFFFF_F000 && (a) <= 32'hFFFF_F003) \
                       || ((a) >= 32'hFFFF_F040 && (a) <= 32'hFFFF_F04F) )
`define INST_ADDR_OK(a)  ((a) <= 32'h0000_FFFF)
```
- `mycpu.v` EX 级：`ex_is_load/ex_is_store & ~ADDR_IN_MAP(ex_alu_c)` → cause 5/7；
  ID 级：`~INST_ADDR_OK(id_pc)` → cause 1。
  **优先级**：取指越界 > 指令目标非对齐 > 访问异常 > 访存非对齐。
- `perip_bridge.v` 的 DRAM 写门控改用同一份判据（`sel_dram = Bus_addr <= 64KB`），
  越界地址**绝不截断后照写**。
- `perip_bridge.v` 的外设解码同时**收窄**到已实现的三个区间，
  不再"整页放行"——原来往 `0xFFFF_F004`（DIG 与 TIMER 之间的空隙）写会被
  静默丢弃，那是和越界别名同一类的病。
- 模型侧：`IF.c` 不再 `Assert`（越界取指给 0 占位），`ID.c` 报 cause 1，
  `EX.c` 报 cause 5/7 且**跳过整次访存**；`MEM.c` 的 `Assert` 从此只是
  "EX 级检查漏了"的不变量。

**关于"哪一部分真正承重"（反向验证的结论，如实记录）**：

| 注入 | 结果 |
|---|---|
| 去掉 DUT 的越界异常上报 | ✅ 抓到（mcause 不符） |
| 只恢复桥的越界别名 | ❌ **没抓到**——因为 `~mem_exc_valid` 已经在 CPU 侧把 store 挡住了 |
| 同时去掉 CPU 与桥的写门控 | ✅ 抓到，但先触发的是**非对齐 store** 那条检查 |

也就是说：**主要防线是 CPU 侧的异常上报 + `~mem_exc_valid` 写门控**，
桥那侧的区间门控是**纵深防御**（保证无论 CPU 怎么错，硬件都不会写出界），
在当前设计下不是独立承重的。同理，`trap.S` 里"回读地址 0 确认没被改写"
那两条检查是冗余的安全网——留着值，但要知道它不是主防线。

顺带修掉了一个**测试自身的缺陷**：第一版 `trap.S` 的防别名检查回读的是
`scratch`(0x1260)，而 0x0001_0000 别名到的是**字节地址 0**——
检查盯错了地方，永远不可能触发。反向验证时才暴露出来，已改为回读地址 0。

### 16.3 计数器 CSR —— 参考模型的原理性局限

DUT 侧实现是对的：`cycle/cycleh` 数真实周期，`instret` 数提交指令数。
参考模型是**提交步进**的（一次调用执行一条指令），
原理上不知道 DUT 在每条指令之间花了几个周期，所以它只能按"每条指令 +1"计数。
这不是谁的 bug，是 difftest 这种"架构状态比对"方法本身的边界——
周期数是环境状态而非架构状态。因此这两类 CSR 被**有意排除**在比较之外，
其正确性只由"单调递增"间接保证。

### 16.4 仅 M 模式 —— 范围决定，不是缺陷

没有 U/S 模式、没有 delegation（`medeleg/mideleg`）、没有 PLIC。
这是用户选定的实现范围；参照的 `cpu/src` 本身也是 M-only。
两边实现一致，不构成分歧。

### 16.5 另一处同类隐患（未触发）

`IF.c` 的 `Assert(npc < MEM_SZ)`：与 16.2 同源——轨迹一旦跑出 64KB
就把仿真进程 abort 掉。`trap.S` 里保证 `mtvec`/handler 落在映像内，
所以没有触发，但它是同一类"DUT 会回绕、模型会 abort"的隐患。
