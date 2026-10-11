# A910_cpu 整核调试记录

**日期**：2026-10-11
**对象**：`mySoC/A910_cpu.sv` —— 乱序多发射整核新顶层
（自研 IFU2 + C910 IDU/LSU/BIU + 自研 RTU + 自研 IU 三个 wrapper）

---

## 0. 背景：这个核此前一次都没跑过

仓库里只有 `make a910-elab`，那是**只 elaborate、不仿真**。全仓搜 `A910_cpu` 只命中模块自身，
**没有任何 TB 例化它**。所以这次先补了最小冒烟台，然后才谈得上"跑"。

冒烟台交付物：

| 文件 | 说明 |
|---|---|
| `tb/a910/tb_a910_smoke.sv` | 时钟/复位 + force 未驱动线 + 退休监视 + PASS/FAIL |
| `tb/a910/axi_slave_128.v` | AXI4 从机 + 128 位内存（`rid`/`bid` 回显、2 拍 WRAP 回卷、`wstrb` 逐字节写） |
| `asm/a910_smoke.S` | 纯直线无跳转自检用例（结果压进 `a0`） |
| `Makefile` | `make a910-run TEST=...` |

### 复现命令

```bash
make a910-run TEST=a910_smoke                                  # 基本跑
make a910-run TEST=a910_smoke A910_SIM_ARGS=+TRACE_EARLY       # 逐拍追踪
make a910-run TEST=a910_smoke A910_SIM_ARGS=+FIX_ACCEPT        # 验证 Bug 1 (夹 accept_num)
make a910-run TEST=a910_smoke A910_SIM_ARGS=+FIX_ACCEPT2       # 验证 Bug 2 (按 {0,2,3} 造)
make a910-run TEST=a910_smoke A910_SIM_ARGS=+KILL_FLUSH        # 诊断: 钉死 rtu.flush_trig
```

### 三条搭台时必须知道的、反直觉的事

1. **`ecall` 在这个顶层不会停机。** `ct_idu_id_decd.sv:139`
   `illegal = !valid_inst || op_fence || op_system` 把**整个 SYSTEM 主 opcode**（`1110011`）
   判成非法指令，而 `ct_idu_top` **没有异常输出口** ⇒ `ecall` 等价于"不写 rd 的普通指令"，
   静默滑过去、PC 继续走进补零区。**终止条件必须由 TB 自己给。**
2. **不接 difftest 也能判 PASS/FAIL。** 顶层 `dbg_commit_*` 那 15 根是**架构寄存器视角**的
   退休 trace（`RTU.v:383-392` 的注释就是为逐条比对写的）。用例用 `sub` 把自检压进 `a0`，
   TB 盯 `dbg_commit_reg==5'd10` 取值即可，**不需要分支**。
3. **六根未驱动的线必须在 TB 里 `force`**，否则第一条指令退休那拍整个 RTU 变 X：
   `int_pending`（进 `RTU_commit` 的组合前缀链）、`csr_trap_vector/mepc/rdata`、
   `iu_btb_chk/taken/is_cond`、`cmplt_vld1,2`。
   （用 force 而不是改 RTL，与 `a910-elab` 那套"不接常量桩、免得分不清'没接'和'真不会发生'"
   的原则一致。）

---

## 1. 症状

一条指令都不退休。`rtu_retire_cnt`、`rob_occ`、`q_pc_q` 全是 X，AXI 上零流量。

逐拍追踪（`+TRACE_EARLY`）抓到 **三层独立叠加**的 bug，每层单独都足以让整核死透。

---

## 2. Bug 1（已修）：`idu_accept_num` 不看有效位 ⇒ IBUF 计数器下溢

### 因果链

```
ct_idu_top.sv:332   idu_accept_num = {inst2_ready|inst0_ready, inst2_ready}
ct_idu_id_ctrl.sv:36-38  三根 ready 全来自同一个 stall ⇒ 只有 00 / 11 两态
                         ⇒ **从不看 ifu_idu_ib_inst*_vld**
        ↓
rv32ifu2_ibuf.v:120  cnt_q <= cnt_q + acc_push - pop_num     ← 没有下溢保护
        ↓  复位后 IBUF 是空的 (cnt=0), 而 IDU 每拍都报"收了 3 条"
        ↓  0 - 3 在 5 位无符号里回卷成 **29**
        ↓  （实测 29→26→23→20→17, 每拍恰好 -3, 而 push_mask=0000 根本没有推入）
        ↓
rv32ifu2_ibuf.v:95   out_vld[0] = empty ? push_mask[0] : 1'b1
        ↓  cnt=29 ⇒ empty=0 ⇒ **out_vld 无条件拉 1**
        ↓
rv32ifu2_ibuf.v:91   out_data0 = empty ? push_data0 : ent_q[head_q]
        ↓  ent_q **从不复位、也从没被写过** ⇒ 读出 **X**
        ↓
IFU 以 valid=1 交出 X 指令 → IDU 译码全 X → alloc_vld / ren_preg_req 全 X
        ↓
RTU_ROB.v:311  occ_q <= occ_q + ndisp - pop_n    ← **反馈计数器, 一次 X 永远回不来**
        ↓  ⇒ okp0 X ⇒ mret_hit/mispred_hit X ⇒ flush_trig X
        ↓  ⇒ RTU_flush 的 st_q 进 X 态 ⇒ rtu_ifu_flush X ⇒ IFU 的 PC 变 X
        ⇒ **整核一条都退休不了**
```

**特别狠的一点：这个错误回不去。** `cnt_q` 每拍 −3 却**永远踩不到 0**
（29→…→2→(2−3)→31→28→…），而清它的只有 `rst` 和 `flush` 两条路。
**挨一拍就废到下一次冲刷为止。**

### 验证

`+FIX_ACCEPT` 把 `accept_num` 夹成"IFU 本拍真的交了几条"（`ib_vld` 的连续前缀）：

```
改前:  T21  IBUF cnt=29  empty=0  out_vld=111  out_data0=xxxxxxxx  occ=x
加开关: T21  IBUF cnt=0   empty=1  out_vld=000  inst=000           occ=0 st_q=00
```

**X 风暴消失。** 两条实施上的坑记一下：`force` 必须放 `always @(*)` 里
（`initial force` 会在 time 0 把 RHS 求值锁死）；X 要用 `===` 当 0 处理，
否则 force 的 RHS 会把 X 灌回 IBUF，那就不是"验证"而是"另一个 X 源"。

### 修法：两处，**缺一不可**

**(1) IFU 侧 —— `rv32ifu2_ibuf.v`：`pop_num` 从"确数"改成"上限"**

```verilog
wire [1:0] pop_avail = ~out_vld[0] ? 2'd0 :
                       ~out_vld[1] ? 2'd1 :
                       ~out_vld[2] ? 2'd2 : 2'd3;
wire [1:0] pop_eff   = (pop_num < pop_avail) ? pop_num : pop_avail;
// head_q / cnt_q 改用 pop_eff
```

⚠️ **这是接口语义的改动**：端口表原来写的是"`pop_num` **必须**是 `out_vld` 的连续前缀"
（义务在消费端），现在改成"`pop_num` 是**上限**，本模块按有效前缀截断"。

**(2) IDU 侧 —— 见 Bug 2。**

### 为什么把截断放 IFU 而不是 IDU

IDU 消费的**恰好是** IFU 的有效前缀（见 `ct_idu_id_ctrl.sv:25-34` 的 pipedown 三式：
`sel[1]` 吃 ifu inst0/1/2、`sel[0]` 吃 ifu inst0/inst1），所以
`min(cap, 前缀数)` 在两边算**结果一样**。放 IFU 侧的理由：

- **时序**：放 IDU 会造出 `IFU out_vld →（跨模块）→ accept_num →（跨回）→ cnt_q` 的
  **往返组合路径**；放 IFU 则 `pop_num` 只单向跨一次。
- **语义**：`accept_num` 变成纯粹的"IDU 最多能吃几条"——这正是 IDU 唯一知道的事，
  它本来就不知道 IBUF 里装了多少。
- **健壮性**："队列计数器不许减到负"是队列自己的常识，不是给谁擦屁股。

安全性的论证：`min` 只会**减少**弹出条数，而"弹出比有效更多的条数"在任何设计里
都已经是错的 ⇒ **构造性安全**。
回归：顺序核 `IFU=2` 跑 `muldiv_edge` / `div` / `mul` / `c3_only` **4/4 PASS**。

---

## 3. Bug 2（已修）：`idu_ifu_inst2_ready` 用了 `|` 而不是 `&`

### 编码本身没问题，是 `b` 从不为低

```verilog
accept_num = {inst2_ready | inst0_ready, inst2_ready}
             └────── bit1 ──────┘  └─ bit0 ─┘
```

`inst2_ready = 0` 时 bit0=0、bit1=`inst0_ready` ⇒ `{inst0_ready, 0}` = **2**。
所以这个编码要给出 `{0,2,3}`，只需要一条不变量：

> **`inst2_ready` 为 1 时 `inst0_ready` 必须也为 1**（`b ≤ a`）。

### 但 `ct_idu_id_ctrl.sv:38` 破坏了它

```verilog
assign idu_ifu_inst2_ready = !ctrl_id_pipedown_stall | !ctrl_xx_is_inst0_sel[0];
//                                                   ↑ 这个 |
```

`!stall | !pd2` **不小于** `!stall`，把不变量顶穿：

| `ir_stall` | `pipedown2` | `inst0_ready` | `inst2_ready` | 实际 | 应为 |
|---|---|---|---|---|---|
| 0 | 0 | 1 | 1 | 3 | 3 ✓ |
| 0 | 1 | 1 | 1 | **3** | **2** ✗ |
| 1 | 0 | 0 | **1** | **3** | **0** ✗ |
| 1 | 1 | 0 | 0 | 0 | 0 ✓ |

改成 `&` 后 `inst2_ready = !stall & !pd2 ≤ !stall = inst0_ready`，四象限 → **3 / 2 / 0 / 0**。

### 后果：丢指令

pipedown2 模式下 ID 级只吃 IFU 的 inst0/inst1（slot0 靠 `ctrl_ir_inst2_vld` 补），
**却告诉 IFU"收了 3 条"** ⇒ IFU 多弹一条、那条永远不处理 = **静默丢指令**。

### 影响面

`idu_ifu_inst0/1/2_ready` 三根**只被 `idu_accept_num` 一处消费**，改动爆炸半径就是一格。

### 顺带更正一处旧认知

`tb/unit/tb_idu_c910.sv` 原来写着"`2` 是不可达编码"——那是**改之前**的行为
（`inst2_ready` 恒 1 ⇒ 只出 0/3），而且它引用的 `ct_idu_top.sv:180` 行号早已漂移
（现在那儿是个端口声明）。**`2` 既可达也是必需的**，已更正。
另加了常驻不变量检查：`accept_num` 出现 `1` 就当场 `$fatal`。

---

## 4. Bug 3（**已定位，未修**）：`ctrl_ir_inst2_vld` 整根没被驱动

前两个修完之后整核仍不跑，逐拍追到：

```
T85  ctrl_ir_inst2_vld=x   ir_stall=0      ← 任何派遣之前就是 X
T90  pd2=x → accept_num=1x → disp=x11 → ID 级全 X
```

在 `ct_idu_top.sv` 里搜 `ctrl_ir_inst2_vld`，**只有两处**：

- `:349` 声明 `logic ctrl_ir_inst2_vld;`
- `:609` 当作**输入**连给 `ct_idu_id_ctrl`

**没有任何 `assign`、没有任何模块把它作为输出接过来** ⇒ 悬空 Z ⇒ X。
而它正是 `ct_idu_id_ctrl.sv:26` 里 pipedown2 那一支的数据源。

### 与 C910 原版的对照

```verilog
// 原版 (openc910 ct_idu_id_ctrl.sv:129-132) —— 三模式, 中间那支用 ID 级**自己**的寄存器
assign ctrl_ib_pipedown_inst0_vld =
            ctrl_id_pipedown_1_inst && id_inst1_vld
         || ctrl_id_pipedown_2_inst && id_inst2_vld
         || ctrl_id_pipedown_3_inst && ifu_idu_ib_inst0_vld;

// 我们这份 —— 中间那支换成了 IR 级的信号, 而那根没接
assign ctrl_ib_pipedown_inst0_vld =
            ctrl_xx_is_inst0_sel[0] && ctrl_ir_inst2_vld      // ← 悬空
         || ctrl_xx_is_inst0_sel[1] && ifu_idu_ib_inst0_vld;
```

交付版把"用 ID 级自己的 `id_inst2_vld`"改写成了"用 IR 级的 `ctrl_ir_inst2_vld`"，
**而新引入的这根信号没接线**。

### 两个候选改法（**待 IDU 侧定语义，未动**）

**(a) 改回 `id_inst2_vld`** —— ID 级自己的寄存器，`ct_idu_id_ctrl.sv:68` 那行就在写它，
和 C910 逐字一致。**推荐**：用 IR 级的信号会让 `ID → IR → ID` 形成**跨级组合环**
（ID 级的 pipedown 依赖 IR 级的寄存器状态，而 IR 级的输入又来自 ID 级），
C910 特意用 ID 级自己的寄存器应该就是为了避开它。

**(b) 接上 `ctrl_rt_inst2_vld`** —— `ct_idu_ir_ctrl.sv:243`
`assign ctrl_rt_inst2_vld = ir_inst2_vld;` 才是"IR 级那个寄存器"的导出。
若确实要 IR 级语义，源应该是它。

---

## 5. 改动与回归清单

| 文件 | 改动 | 状态 |
|---|---|---|
| `mySoC/ifu2/rtl/rv32ifu2_ibuf.v` | `pop_eff = min(pop_num, 有效前缀)`，端口语义改为 cap | ✅ 已验证 |
| `mySoC/idu_c910/rtl/ct_idu_id_ctrl.sv` | `idu_ifu_inst2_ready` 的 `\|` → `&` | ✅ 已验证 |
| `tb/unit/tb_idu_c910.sv` | 更正"2 不可达"的旧断言 | ✅ |
| `mySoC/A910_cpu.sv` | **一行未动**（中途怀疑过 `rst_b` 悬空，查下来它由适配层的输出驱动，已完整还原） | — |

| 回归 | 结果 |
|---|---|
| `run TEST={muldiv_edge,div,mul,c3_only} IFU=2` | 4/4 PASS |
| `a910-run` 不变量（`accept_num` 只出 0/2/3） | ✅ `1` 从未出现 |
| `make iu-md-unit` / `make muldiv-unit` / `make a910-elab` | 全绿 |

### 一笔无关的旧账

`make idu-unit` 的 `PRF 走访存失败: 写入 deadbeef, 读回 xxxxxxxx (地址 9)` 是**既有**红 ——
把本次改动 stash 掉重跑一样红。与上面这些链都无关，是独立的一笔。

---

## 6. 下一步

修完 Bug 3 之后，三层坑就都填上了，整核理论上能真正跑起来。之后：

1. 跑现成用例（`muldiv_edge` / `mul` / `div`）。
   ⚠️ 它们**开头就是 `jal`、中间有 `beq`**，会踩 `idu_accept_num` 那个已知契约问题
   （见记忆 `idu-accept-num-contract`）——`a910_smoke.S` 特意做成纯直线就是为了能区分
   "TB 没搭对"和"复现了已知 bug"。
2. 接 CSR（`csr_rdata` / `csr_trap_vector` / `csr_mepc` / `int_pending` 目前都是 force 成 0）。
3. 接 difftest（`dbg_commit_*` 那 15 根就是现成的接入点）。
