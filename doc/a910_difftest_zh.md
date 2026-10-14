# A910_cpu 跑顺序核用例：difftest 台 + 首轮结果 + 交接清单

**日期**：2026-10-12
**目标**：让 `mySoC/A910_cpu.sv`（乱序多发射整核）跑仓库里那批**顺序核用例**
（`bin/*.bin`，即 `make run-all` 跑的那 49 个）。
**入口**：

```bash
make a910-difftest TEST=addi          # 单个用例
make a910-difftest-all                # 整套 (跳过 coremark/start/peri/trap)
make a910-difftest TEST=mul A910_DT_ARGS=+TRACE    # 打全部退休流
```

---

## 0. 为什么不能用冒烟台跑这批用例

冒烟台 (`tb/a910/tb_a910_smoke.sv`) 的判据是"看到 `x17=93` 且最后一次写 `a0` 是 0"。
而 riscv-tests 的用例把 `fail` 块**紧挨着**排在 `pass` 块前面，`ecall` 在 A910 顶层
又**不停机**（C910 的 IDU 把整个 SYSTEM 主 opcode 判成非法指令）⇒
**"走错路撞进 fail → 落穿进 pass" 会被判成 PASS**。

实测（改之前）：`beq` 用例的 `beq` 根本没跳、PC 直接跑到 `fail`，
冒烟台照样报 `=== A910 SMOKE: PASS ===`。⇒ 这批用例**必须逐条比对**才判得了对错。

## 1. difftest 台怎么搭的

复用仓库现成的黄金模型（`golden_model/` + `dpi/dpi_shim.c`，与 `tb_miniRV_dpi` 同一份）：

* 模型是**提交步进**的：调一次 `gm_check_step()` 才执行一条架构指令并逐位比对；
  `have_inst=0` 时原地不动。
* DUT 侧接**顶层那 15 根 `dbg_commit_*`**（`RTU.v:383-392` 本来就是为 difftest 写的）。
  3 发射 ⇒ 每拍按**槽 0→1→2（程序序）**喂三次。
* 收尾交给模型自己：`cpu_poll_halt()` 在 `cpu.npc` 指到一条 `ecall` 且 `mtvec==0` 时
  停机，用当时的 `a0` 定 pass/fail —— **不受"落穿"影响**（它停在第一个 ecall）。

文件：`tb/a910/tb_a910_difftest.sv`；Makefile 目标 `a910-difftest` / `a910-difftest-all`
（独立 `obj_a910_dt/`，**不开 FSDB**）。

### 判据的两条修正（都在 A910 顶层做的，两边模块一行没动）

| 现象 | 修法 |
|---|---|
| `jal x0,4` 在模型里 `ena=0`、在 RTU 里 `ena=1`（RTU 只看"带不带写口"） | 顶层按 `mycpu.v:1572` 的同一口径摘掉"写 x0"：`dbg_commit_ena = rtu_ena & (reg != 0)` |
| PRF 的 4 个写口是**边沿**写、RTU 那 4 个读口是**组合**读 ⇒ 写回与退休同拍时读到旧值 | 顶层加**写口旁路**（4 写口 × 4 读口，判命中用 PRF 自己用的 `_wb_preg_expand` 独热） |

## 2. 本轮在**我们的模块**里修的 bug

> 约定：IFU / RTU / A910 集成层是我们的，可以直接改；IDU / LSU / BIU 是同事的，
> 只定位不修（见 §4）。

### 2.1 `mySoC/A910_cpu.sv`（集成层）

1. **PRF 读口旁路**（见上表第 2 条）。
2. **`ena` 摘掉写 x0**（见上表第 1 条）。
3. **误预测冻结窗**（`mispred_hold_q`）：EX 级重定向那一拍起、到 `rtu_yy_xx_flush`
   到来为止，**不给 IDU 交任何指令**，并且把交给 IFU 的 `idu_accept_num` 夹成 0。
   * 为什么：执行级重定向比冲刷**早 3 拍**，而我们的 IFU2 命中 I-Cache 时**下一拍**
     就把重定向目标那条交给 IDU ⇒ 冲刷（一把大扫帚，整条 ID/IR/IS 全清）把它一起
     清掉 ⇒ **跳转目标那条指令凭空消失**。实测（`lui` 用例）：PC 从 0x60 直接跳到
     0x80，中间的 0x7c 没了。
   * ⚠️ **只关 `vld` 不够**，必须连 `accept_num` 一起夹 0 —— IDU 报收几条是它按
     自己的停顿状态算的、**不看 vld**，IBUF 会照它把人弹进黑洞。

### 2.2 `mySoC/rtu/rtl/RTU_commit.v`（我们的）

**误预测那条退休时，比它年轻的槽这一拍不许退。**

`rv0/rv1/rv2`（判退前缀 + `commit_vld`）原来只被 `int_take` / `trap_hit` 门控，
**误预测漏了** ⇒ 那条分支退休**当拍**把错误路径上的表项一起交付掉。
实测（`mul` 用例）：T100 一个包退了 `0x14/0x18/0x1c` —— `0x18`、`0x1c` 是 fail 分支，
它们不但退了还改了 `x10`。而 BEU 那边算得完全正确
（`+PROBE_BEU`: `actual_npc=0x20 mismatch=1 chgflw_vld=1`）—— 重定向发出去了，
只是**退得比冲刷快**。
新增 `mis_stop0/mis_stop1`（仲裁口径与 `mispred_hit`/`mispred_target` 逐位一致）。

### 2.3 `mySoC/rtu/rtl/RTU_preg.v`（我们的）

**p0（常量 0 号）不许出池。**

`st[0]` 原来只靠复位成 ARCH；只要有一条退休记录的 `old_preg` 字段是 0（**IDU 的派遣
记录会给错**，见 §4.2），p0 就被当成"被顶掉的旧映射" → RELEASE → FREE →
**被当普通号发出去**。拿到 p0 的指令写不进去（PRF 的 `preg_wb_vld[0]` 恒 0），
它的目标寄存器永远保持旧值 —— 症状是 difftest 报"某条指令结果不对"，而那条指令的
发射/执行/写回全是对的。

实测指纹（`mul`，`+PROBE_PREG`）：

```
T103 tap: vld=111 num=63,0,59 | IR alloc=011 preg=63,0,0     ← 门房给 lane1 备的是 0 号
T104 ...                      | 派遣 vld=011 号=63,0,0      ← x17 拿到 0 号
```

（编号 0 之所以能"看着有效"：`PREG_BM0..BM6` 的 **bit0 全是 0** ⇒ 选中 bit0 时
编码器输出 0 而 `|g_sel` 仍为 1。）

两道保险：五态表里 `i==0` 恒 ARCH（最高优先级）+ `free_pool` 结构上掩掉 bit0。

### 2.4 ⚠️ 试过但**已还原**：`IU_beu_pipe` 的重定向窗

**现象**：执行级重定向早发，而错误路径上那些分支这时还堵在 BIQ 里没发射完 ——
它们下一拍各自再报一次"我也误预测了"，把刚建好的正确重定向**顶掉**。
实测（`beq`，`+PROBE_BEU`）：

```
T96  0x10 beq → actual=0x1c mispred=1 chgflw_vld=1     ← 正确的那次
T97  0x14 bne → actual=0x2c4 mispred=1 chgflw_vld=1    ← 错误路径上的, 把 PC 拽到 fail
T98  0x18 bne → actual=0x24 mispred=1 chgflw_vld=0
```

**试过的修法**：在 `IU_beu_pipe` 里加 `red_in_flight_q`（本拍发了重定向就关窗，
`rtu_yy_xx_flush` 开窗），把窗口内第二次重定向挡掉 —— 对应 C910
`ct_iu_bju.v:506` 的 `!idu_mispred_stall` 那一项。

**结果：净负收益，已还原。** `beq` 从第 6 条推进到第 7 条，但 **`mul` 从 PASS 退回 FAIL**
（窗内那条**正确路径**上的重定向也被挡掉了）。⇒ 说明这个窗口的判据不能只看"发过没发过"，
得按 C910 那样带**年龄**比（`bju_older_inst_vld` / `mispred_iid`）。
**留给下一步**：先把 §4.3 那两个 IDU 输入补回来（C910 的正解），再谈这条。

## 3. 首轮结果（`make a910-difftest-all`，45 个用例）

```
PASS (4):  a910_smoke, simple, div, mul
FAIL (41): 其余
```

**失败点高度集中，按"第一个失配那条指令"分三类**：

| 类 | 条数 | 第一个失配点 | 病因 |
|---|---|---|---|
| **U-type 指令**（`lui`/`auipc`） | **31** | 全是 `lui`/`auipc`（opcode 0x37/0x17） | §4.1 —— **IDU 一行** |
| **控制转移**（分支/跳转） | 10 | `beq`/`bne`/`blt`/`bge`/`jal`/`jalr`/`jal x0,8` | §4.3 + 本轮已修的三处 |
| 存储器（lb/lw/sb/sw…） | 8 | 也是 `lui`（先用 lui 造地址） | §4.1 + §4.4/§4.5 |

⇒ **IDU 那个 U-type 立即数一修，那 31 条（纯 ALU 自检）大概率直接全过** ——
它们的身体就是"造数 → 算 → 与期望比 → 跳 fail/pass"，不含别的硬骨头。

## 4. 交接给同事的清单（**只定位，未改**）

### 4.1 IDU：U-type 立即数从来没被驱动过 🔴 阻断性

`mySoC/idu_c910/rtl/ct_idu_rf_pipe0_decd.sv:120-122`

```verilog
7'b0110111: pipe0_decd_sel = ALU_LUI;      // ← 没给 pipe0_decd_imm 赋值
7'b0010111: pipe0_decd_sel = ALU_AUIPC;    // ← 同上
```

`pipe0_decd_imm` 保持默认的 `32'd0`，而这条通路上 **LUI 的结果就是 src1（= 这个立即数）**、
AUIPC 是 `pc + 它`（见 `mySoC/iu/rtl/IU_alu_pipe.v` 的 LUI/AUIPC 段）⇒
`lui x1,0xfffff` 算出 **0**、`auipc` 算出 **pc**。

对照 C910 原版（`open_riscv_2035/.../ct_idu_rf_pipe0_decd.v:74-75`）是显式处理 U-type 立即数的
（`decd_imm_sel[0] = op==7'b0110111 || op==7'b0010111`），这一版重写时漏了。
修法：把 `{opcode[31:12], 12'b0}` 一起赋给 `pipe0_decd_imm`
（本轮曾改好验证通过，按约定已还原）。

**影响面比想象大**：编译器生成的代码里 `lui`/`auipc` 到处都是（大立即数、全局地址），
所以这条不修，A910 连自己编译的程序都跑不了。

### 4.2 IDU：派遣记录的 `old_preg` 字段会给错 🔴 阻断性（已在我们 RTU 侧兜住）

实测（`+PROBE_DISP`）：

| 派发 | pc | lreg | dst_preg | old_preg 实测 | 应为 |
|---|---|---|---|---|---|
| `mul` T91（vld=001，单车道） | 0x0c | 7 | 61 | **0** | 7 |
| `mul` T94（vld=111） | 0x10 | 8 | 60 | **7** | 8 |
| `mul` T105（vld=011，部分派发） | 0x24 | 17 | 0(被 4.3 连带) | **0** | 17 |

规律：**部分派发时最低那条有效车道的 `old_preg` 读到 0**。后果是 RTU 把 **preg 0**
当成"被顶掉的旧映射"回收 ⇒ 见 §2.3。
我们已在 RTU 里挡住（p0 不出池），但这只挡住"号被发出去"，
**真正被顶掉的那个旧号（如 p7）会永久留在 ARCH 出不了池** ⇒ 自由池单调缩水，
长用例（CoreMark）迟早耗尽。**根子还得在 IDU 侧修。**

### 4.3 IDU：`iu_idu_mispred_stall` / `rtu_idu_flush_stall` 两个输入被删掉了 🔴 阻断性

C910 原版 `ct_idu_ir_ctrl.v:1070-1074`：

```verilog
assign ctrl_ir_stage_stall = ctrl_ir_preg_stall || ... || rtu_idu_flush_stall
                           || iu_idu_mispred_stall;      // "stall ID stage until all
                                                         //  frontend and backend pipeline empty"
```

`iu_idu_mispred_stall` 由 BJU 产生（`ct_iu_bju.v:799-819`：EX1 重定向置起、
`rtu_yy_xx_flush` 清掉），`rtu_idu_flush_stall = !flush_cur_state[0]`（`ct_rtu_retire.v:1985`）。

**交付版 `ct_idu_ir_ctrl.sv:276` 只剩下 `ctrl_ir_stage_stall = ctrl_ir_preg_stall`**，
两个输入连端口都没有了。后果就是 §2.1 那条时序竞态（重定向目标那条被冲刷扫掉）——
C910 靠"IDU 从 EX 重定向一直冻到冲刷到来"错开，我们只能用顶层闸门近似（有代价：
每次误预测多冻几拍）。

### 4.4 LSU：空载时 LD 流水里有个"幽灵"在转 🟠 阻断性

`lui` 用例（**一条 load 都没有**）实测（`+PROBE_IFU`）：

```
T117 dc2da=0 da_vld=1 da_wb_req=1 wb_pre=1 wb_vld=0
T118 dc2da=1 da_vld=0 da_wb_req=0 wb_pre=0 wb_vld=1   ← 报了一条 load 完成 (iid=0)
...
T123/T124 每 6 拍重复一次
```

`ld_dc_da_inst_vld` 每 6 拍自己翻一次（`idu_lsu_ld_sel` 恒 0），于是
`lsu_rtu_wb_pipe3_cmplt` **凭空报出一条 iid=0 的 load 完成** ⇒ 把一条刚派遣进来的
iid=0 指令标成完成 ⇒ **它在写回前一拍就退休**（`dbg_commit_value` 读到未写过的号 = X）。

嫌疑：`lsu_ld_da.sv` 里 `ld_da_inst_vld` 会清（`rtu_yy_xx_flush`），而
`ld_da_expt` 等兄弟**不随冲刷清零**（CSV 第 60 行已记过这一笔）；
`lsu_ld_wb.sv:165-175` 那段还**缺 begin/end**（也是同一处）。
建议先把那段 begin/end 补上再看幽灵还在不在。

### 4.5 已记在案、本轮又碰到的

* `lsu_biu_bready` 没有驱动源（写通道收不到 B）⇒ **store 类用例必挂**
  —— 见 `A910_cpu.sv` 末尾待接清单第 3 条。
* `idu_accept_num` 不看 `ifu_idu_ib_inst*_vld`（同清单第 1 条）。

### 4.6 IDU：`is_dis_pipedown2` 的"顺延"把**同一条指令改名两次** 🔴 阻断性

**这是 beq/bne/blt/bge 卡住的那个真凶**（2026-10-12 定位，见 §6 的完整证据链）。

`mySoC/idu_c910/rtl/ct_idu_id_dp.sv:316-335`（lucy, `115214f7` 2026-10-11 "preg debug"）

```verilog
case(ctrl_xx_is_inst0_sel[1:0])          // [0]=is_dis_pipedown2, [1]=!is_dis_pipedown2
  2'b01 : begin   // ← "顺延"那拍
      dp_id_pipedown_inst0_data = crtl_ir_inst2_data;      // **IR 级自己的 inst2 寄存器**
      dp_id_pipedown_inst1_data = dp_id_pipedown_inst0_data_raw;
      dp_id_pipedown_inst2_data = dp_id_pipedown_inst1_data_raw;
  end
  2'b10 : /* 三条道 1:1 直通 */
  default: /* 全 X */
endcase
```

`crtl_ir_inst2_data` 就是 IR 级自己的寄存器（`ct_idu_ir_dp.sv:399`）。于是"顺延"那拍，
**一条已经改过名的指令被原样塞回 ID 窗口的车道 0**，下一拍在 IR 车道 0 上**又改一次名**。

改名表的写使能（`ct_idu_ir_rt.sv:175-195`）只认
`ctrl_rt_inst*_vld && !ctrl_ir_stall && !rt_recover_updt_vld && dp_rt_inst*_dst_vld`
—— **"这一车道有没有一条要写寄存器的指令"，不认"这条已经改过名"** ⇒ 两次改名各从门房拿一个号。

* `dst != src` 的指令：**无害**（第一圈那个号白烧一次，第二圈写进 RAT 的号与派遣记录一致）；
* **`dst == src`**（`addi x4,x4,1` 这种自引用）：**致命** —— 第二圈读 RAT 时读到的是
  **它自己第一圈刚写进去的号** ⇒ 派遣记录 `old_preg` = 一个**永远没人写**的号
  ⇒ 源操作数从它读出前一个值。

**触发条件很宽**：`ctrl_ir_pre_dis_pipedown2 = ir_pipedown_inst2_vld && (IR 三条道同类型都发不出去)`
（`ct_idu_ir_ctrl.sv:392`）—— 只要 IR 里**连续三条同类**（例如三条 `addi`），第 3 条就顺延。
beq 里正是如此：T304 的 IR = `0x120/0x124/0x128`（三条 addi）⇒ T305 顺延。
**所以凡是"循环体里有自增计数器"的用例都会栽在这**（beq/bne/blt/bge 全是这个形状）。

**实测指纹**（`make a910-difftest TEST=beq A910_DT_ARGS=+PROBE_X4`，T300 冲刷之后）

```
T304  写en=111 lreg=1,2,0   dst=63,1,0
      ID: pc=0x12c,0x130,0x134 vld=111 → IR: pc=0x120,0x124,0x128    ← 三条 addi ⇒ 下拍顺延
T305  写en=101 lreg=0,20,4  dst=0,2,59                              ← RAT[4] := 59
      ID: pc=0x138,0x13c,0x140 vld=111 → IR: pc=0x12c,0x130,0x134
T306  写en=110 lreg=4,5,5   dst=57,2,59                             ← 0x134 又被改一次名 RAT[4] := 57
      ID: pc=0x140,0x144,0x148 vld=111 → IR: pc=0x134,0x138,0x13c    ← 0x134 从车道 2 回灌到车道 0
T307  派: 0x134 l4 d57 o59                    ← old_preg=59 是它自己第一圈的产物, 没人写过
T318  退休 0x134 x4<=1   （参考要 x4<=2）
```

对照 C910 原版 `ct_idu_id_dp.v:1582-1650`：ID→IR 数据路**只**从 ID 级各条道 +
split/fence 重排取数（`id_normal_inst*` / `id_split_short*_inst*` / `id_split_long_inst*` /
`fence_dp_inst*`），**从不把 IR 级寄存器的值回灌进 ID 窗口**。这一版是重写时自己造的型。

**建议改法（二选一）**

1. **顺延那拍别给 IR inst2 分号 / 别写表**：把 `inst2_write_en`（`ct_idu_ir_rt.sv:189`）与
   `idu_rtu_ir_preg2_alloc_vld`（`ct_idu_ir_ctrl.sv:291`）一起门掉 `!ctrl_xx_is_inst0_sel[0]`。
   反正它下一拍会在车道 0 上把 IR→IS 再走一遍，那一遍才是真的。
   （注意：门掉分号请求后，我们 RTU 的门房是"不请求就保持"，不会被多抽一个号。）
2. 或者照 C910 把"顺延"挪到 **IR→IS** 那一级（`ir_pipedown_inst*_vld` 那套，
   `ct_idu_ir_ctrl.v:955-968`），让 preg 随 IS 的表项一起走，别在 ID→IR 边界上做。

### 4.6.1 ✅ 改法 1 已在 worktree 里**验证通过**（2026-10-12）

在 `0b9968a` 上开独立 worktree，按改法 1 打补丁（`ct_idu_ir_rt.inst2_write_en` 与
`ct_idu_ir_ctrl.idu_rtu_ir_preg2_alloc_vld` 一起门掉 `!ctrl_xx_is_inst0_sel[0]`），
跑 `make a910-difftest-all`，**跑完已还原、未进主干**。四组对照：

| 跑的是哪棵树 | PASS | 新过 | 退化 |
|---|---|---|---|
| `HEAD` 基线 | 5 | — | — |
| 仅 §6.5（我们自己那处） | 6 | `jalr` | 无 |
| **仅 §4.6**（改法 1） | 5 | 无 | 无 |
| **§4.6 + §6.5** | **10** | `beq, bge, blt, bne, jalr` | 无 |

⇒ **两个 bug 互相遮蔽，单独修哪一个都解锁不了分支类。**
实测指纹也印证了这一点：只修 §4.6 时，`beq` 的**第一个失配从第 89 条（`0x134` 读 x4）推进到第 96 条
（`0x150 addi x2,x0,-1` 把 src0 读成 2 —— 典型的"两个指令共用一个 preg"）**，
而那正是 §6.5 漏号/重发造成的形状；两处一起修，`beq/bne/blt/bge` 四条全过。

⚠️ `bgeu` / `bltu` 仍然 FAIL（无符号比较那一类），**还没查**，别当成已经被这两条覆盖了。

> 说明：§4.6 这条**只在 IDU 里**，按约定我们没动（只有验证补丁，已还原）。
> §6.5 是我们自己的，已修并留在树上（见 `doc/rtu_preg_alloc_plan_zh.md` §7）。
> §6 有 §4.6 的完整证据链。

### 4.6.2 ⚠️ lucy 已改**一半**（`e83df67` "debug 3dis"，2026-10-12 16:14）—— 还不够

他改了 `ct_idu_ir_ctrl.sv:291`（给 `idu_rtu_ir_preg2_alloc_vld` 加
`&& !ctrl_xx_is_inst0_sel[0]`），**但改名表的写使能没门** ——
`ct_idu_ir_rt.sv:189` 的 `inst2_write_en` 照写不误。

只门"门房请求"的后果：门房不换号了，**但 RAT 还是被写两次**，
第二圈照样读到自己第一圈的产物。实测（`+PROBE_X4`，beq，叠在我们已提交的 §6.5 上）：

```
T305  IR: 0x12c,0x130,0x134   写en=101 → lane2 (0x134) RAT[x4] := 62
T306  IR: 0x134,0x138,0x13c   写en=110 → lane0 (0x134) RAT[x4] := 59   ← 又写一次
T318  退休 0x134 x4<=1 （参考 2）            ← 还是死在第 89 条, 一点没动
```

**缺的是第二行**（`inst2_write_en` 也要 `&& !<那根>`）—— 也就是 §4.6 改法 1 的**两处必须一起门**。
只改一处时圆点上什么都没有变：`make a910-difftest TEST=beq` 依旧第 89 条，
`a910-difftest-all` 依旧 5 PASS。

### 4.7 LSU：三条与"load 的完成/写回"有关的口径差（**只定位，未改**）

**起因**：RTU 侧 2026-10-13 给 preg 池补了 C910 那道"写回过才准回池"的门（`RTU_preg.v`
的 `wb_ok`，见 `doc/rtu_plan_zh.md` 的 D6 更正块）。这道门**依赖"每个被分配出去的号
最终一定有一个写回事件"**，所以下面三条要当面谈定。前两条是**阻断性**的（阶段 2 开
真重命名之前必须修）。

#### ① `lsu_ld_da.sv:515` 的完成条件比 C910 少两道门（**建议加**）

```verilog
// 现在
assign ld_da_wb_cmplt_req = ld_da_inst_vld && !ld_da_secd;
// C910 (ct_lsu_ld_da.v:2419-2424)
assign ld_da_wb_cmplt_req = ld_da_inst_vld && !ecc_stall && !sq_fwd_ecc_discard
                            && !restart_vld && !boundary_first && ld_da_inst_cmplt;
```

我们缺 `!ld_da_restart_vld && !ld_da_boundary_first`：**被 restart（重放）的那一拍也会
报"完成"**。同拍 `ld_da_wb_data_req = cmplt_req & ld_da_data_vld` 也不排除那几种
discard（C910 有 `ld_da_wb_data_req_mask` 掩掉五个源）⇒ 会往 PRF 写一次**本该丢弃**的数据。
好消息：`ld_da_boundary_first` lucy 在 `d769f0d` 已经补上驱动（`lsu_ld_da.sv:533`），
这两道门现在是现成可加的。**建议**：先加门，再对着 `ld_da_wb_data_req_mask` 那五项核一遍
"哪些 discard 场景下 `data_vld` 仍为 1"。

#### ② `lsu_mshr_entry.sv:572`：miss 的 load 只有 DA 那一拍报完成（**口径差异，供知情**）

```verilog
assign rb_entry_wb_cmplt_req = 1'b0;      // ← 同事原始交付版就是 1'b0
// C910 (ct_lsu_rb_entry.v:1350)
assign rb_entry_wb_cmplt_req = !wb_cmplt_success && dest_vld && (... REQ_WB ...);
```

⇒ 整核里 miss 的 load **在数据到手之前就被标成"完成"**（DA 级那一拍）。
这不是必须改（RTU 侧已按 C910 在池子上补了写回门），但要知道：**`lsu_rtu_wb_pipe3_cmplt`
不等于"数据已写回"**。`A910_cpu.sv` 的 difftest 延迟线（§2.1 那一节 / `:610-752`）就是
为了这件事才存在的。

#### ③ ⚠️ 疑似竞态：冲刷与"提交广播"同拍会**杀掉一条刚退休 load 的 RB 表项**（**请确认**）

`lsu_mshr_entry.sv:655`：

```verilog
assign rb_entry_flush_clear   = rtu_yy_xx_flush && !rb_entry_cmit;
```

推理链（每一步都在本仓源码里核对过）：
* RTU 的提交广播 `rtu_yy_xx_commit*` 是**寄存器**（`RTU.v:898-918` 的 `cmt_q`）⇒ 一条
  指令在 T 拍退休、广播在 **T+1** 拍出现在 LSU 面前，`rb_entry_cmit` 在 T+1 边沿才置 1。
* 冲刷 FSM 的 `backend_flush` / `ren_flush` / `flush_lvl` 都在 **F1 拍**（`RTU_flush.v:105-120`）
  ⇒ 若 T 拍同时触发了冲刷（误预测/陷阱/中断/mret/重放都能与"某槽退休"同拍），
  `rtu_yy_xx_flush` 也在 **T+1** 拍为 1。
* 于是 T+1 拍上 LSU 同时看到 `cmit_set=1` 与 `flush=1`，而**判 flush_clear 用的是边沿前
  的 `cmit`（=0）** ⇒ 边沿上"表项状态→IDLE"与"`cmit`→1"同时发生 ⇒ 表项死了、
  **数据永远不会 grant** ⇒ 这条 load 的写回**永远不来**。

后果：改动前 = "这条 load 的值是旧的"（错数）；**补上写回门之后 = 那个号永久出池**
（池子单调缩水 → 停派遣）。⇒ 阶段 2 之前必须修。

**建议修法（1 行，LSU 侧）**：

```verilog
assign rb_entry_flush_clear = rtu_yy_xx_flush && !rb_entry_cmit && !rb_entry_cmit_set;
```

（"这一拍正在被提交的表项不杀"。方向安全：能同拍提交的必然**已经退休**，它晚到的写回
对 PRF 无害。⚠️ C910 那版 `ct_lsu_rb_entry.v:1487` 也**没有**这一项 —— 所以要么那边
时序不同、要么是同一个潜伏问题；请按"定向验证"确认，别只按代码对比下结论。
定向验证的作法：造一条 miss 的 load + 同拍触发冲刷，用 `+PROBE_RET` 看它有没有等到写回。）

> 顺带两笔（都不阻断，记着）：
> * `rb_entry_flush_clear` 相对 C910 还少了 `(rb_entry_boundary && !rb_entry_secd)`
>   那一项（跨界 load 的第一半合并进第二半之后要清掉源表项）。少了它，第一半留在
>   `WAIT_MERGE` ⇒ **RB 表项泄漏**。
> * `rtu_lsu_async_flush` 在本核恒 0（`RTU.v:883`）。C910 那边它是**成对**用的：
>   一边在 LSU 无条件清未提交表项，一边在 preg 池把 `wb_cur_state` 强置 WB
>   （`ct_rtu_pst_preg_entry.v:349`）。**将来真接它必须两半一起接**，否则又是一个
>   "写回不会来"的入口。

## 5. 复现命令

```bash
# 单条
make a910-difftest TEST=simple        # 纯直线, 应当 PASS
make a910-difftest TEST=mul           # 手写小用例, 应当 PASS
make a910-difftest TEST=beq           # 分支类, 见 §4

# 现场
make a910-difftest TEST=beq A910_DT_ARGS=+TRACE      # 全部退休流
make a910-difftest TEST=beq A910_DT_ARGS=+PROBE_BEU   # BIQ→BEU 那条路
make a910-difftest TEST=beq A910_DT_ARGS=+PROBE_IFU   # 重定向前后 IFU/IDU 手上有什么
make a910-difftest TEST=mul A910_DT_ARGS=+PROBE_PREG  # preg 分配握手
make a910-difftest TEST=mul A910_DT_ARGS=+PROBE_WB    # 递交代 vs 写口 vs PRF 读口
make a910-difftest TEST=beq A910_DT_ARGS=+PROBE_X4    # §4.6: 改名表写口 + ID/IR 窗口 + 派遣流

# 整套
make a910-difftest-all
```

⚠️ **本机时钟偏移**：VCS 会静默跳过重编译（删 `obj_a910_dt/simv` 即可）。

---

## 6. §4.6 的定位过程（2026-10-12）

留一份"怎么走到那一步的"，免得下次重新踩。

### 6.1 现象先被纠正了一次

交接时说"退休流里少/多了一条"。用 `+TRACE` 一跑就否掉了：

```
T296 slot0 pc=0x134 x4<=0x1     ← 第一圈, 对的
T318 slot0 pc=0x134 x4<=0x1     ← 第二圈, 该是 0x2
```

`0x134` **出现两次、位置也对**，只是第二圈的值少 1 ⇒ 不是"丢指令"，是
**第二圈的 `addi` 把 x4 读成了 0**。反汇编确认 `0x134: addi x4,x4,1`（自引用）。

### 6.2 逐层排除

| 探针 | 结论 |
|---|---|
| `+PROBE_WB` | 写回口/PRF 读口无同拍竞争，**不是** §1 那条旁路的老问题 |
| `+PROBE_X4`（新增）看 `AMT[4]` / `RAT[4]` | 冲刷 **T300** 把 RAT[4] 恢复成 32（正确，T301-T305 一直是 32）；**T306 变成 59、T307 变成 57** |

⇒ 不是"恢复错了"，是**恢复之后又被两条改名写脏了**。

### 6.3 关键一跳：把 IR 的写口和 ID 的窗口并排打

`+PROBE_X4` 里加了改名表写口（`ct_idu_ir_rt.{inst*_write_en,dp_rt_inst*_dst_*}`）和
`dp_ir_inst*_pc` / `dp_id_pipedown_inst*_pc` / `id_ir_inst*_vld`：

* **ID 窗口每拍前进 3，`0x134` 只出现一次**（T304 的车道 2）；
* **IR 窗口里 `0x134` 出现两次**：T305 车道 2、T306 车道 0；
* 「IR 车道 0(T306) = ID 窗口里根本没有的值」⇒ 只能来自 `ct_idu_id_dp` 那个
  `2'b01` 分支的 `crtl_ir_inst2_data` 回灌。

### 6.4 反向验证（已做，结论见 §4.6.1）

改法 1 是一行的量级，已在 worktree 里验过：**只修它没用，得和 §6.5 一起修**，
`beq/bne/blt/bge` 才全过（5 → 10 PASS）。详细对照表在 §4.6.1。

**给 lucy 的复现步骤**（补丁本身已还原，需要重打）：

1. `ct_idu_ir_rt.sv`：加一根输入（ct_idu_top 里接 `ctrl_xx_is_inst0_sel[0]`），
   `inst2_write_en` 加 `&& !<那根>`；
2. `ct_idu_ir_ctrl.sv:291`：`idu_rtu_ir_preg2_alloc_vld` 加 `&& !ctrl_xx_is_inst0_sel[0]`；
3. **同时**要我们这边先落 §6.5（`doc/rtu_preg_alloc_plan_zh.md` §7）—— 否则第 96 条还会栽。

### 6.5 顺带挖出的、**我们自己**的一个 bug（未修）

追 §4.6 时一起看到的，与 §4.6 相互独立。**在 `RTU_idu_lsu_adapter.v:258-267`。**

```verilog
assign ren_preg_req[1:0] = {1'b0, idu_rtu_ir_preg0_alloc_vld}
                         + {1'b0, idu_rtu_ir_preg1_alloc_vld}
                         + {1'b0, idu_rtu_ir_preg2_alloc_vld};   // ← 这是**求和**, 不是前缀长度
assign ren_preg_req_lreg0/1/2 = 5'd1;   // ← 恒非零 ⇒ RTU 里那条 x0 门控被架空
```

注释里写的假设是"IDU 三路请求天然是程序序前缀 ⇒ 数个数就是前缀长度"。**这个假设不成立**：
`idu_rtu_ir_preg{k}_alloc_vld = ir_inst{k}_vld && !stall && dst_vld && !dst_x0`，
每条车道**各自**看自己要不要写寄存器 —— 车道 0 是"写 x0 的 nop/分支"时它就是 0，而车道 2 照样可以是 1。

实测（`+PROBE_X4`，`ALLOC:` 那行，beq，T300 附近）：

```
IDU 请求=110 (vld2,vld1,vld0) → ren_preg_req=2   ← 非前缀: 真请求者是车道 1,2
IDU 请求=101                  → ren_preg_req=2   ← 非前缀: 真请求者是车道 0,2
IDU 请求=011                  → ren_preg_req=2   ← 这个才是前缀, 只有它是对的
tap vld=111 num=62,34,53 → 57,33,53              ← 101 那拍 tap2 的 53 **没换**, 而车道 2 正是请求者
free_cnt 长期在 16~21 徘徊 (复位后是 32)
```

后果两个，都是池子层面的：
1. **漏号**：`take_lane[0]` 被判成 1 而车道 0 根本没请求 ⇒ 门房把 `tap_num0` 换掉，
   旧号 M 既没被取走也不再挂在任何门房里 ⇒ **永久停在 WF_ALLOC**（年龄回收已删 ⇒ 没人救它）。
2. **重发**：真请求者那一路的门房**没换** ⇒ 同一路连着请求两次（且中间那条还没派遣）会拿到**同一个号**。
   现在靠 `tap_hit`（派遣认领时才补号）兜着，属于"晚一拍才补"，窗口是开的。

**改法**：`ren_preg_req` 的语义得从"前缀长度 [1:0]"换成**三路各自的请求向量 [2:0]**，
`RTU_preg.take_lane[k]` 直接吃第 k 位（C910 本来就是每路独立：
`ct_rtu_pst_preg.v:6995` 的 `alloc_preg{k}_invalid` 各自看 `idu_rtu_ir_preg{k}_alloc_vld`）。
这条会动 §6.0 的接口，`doc/rtu_if_*.xlsx` 是生成的 ⇒ 要改 `gen_rtu_if_xlsx.py` 再重跑。
**因为 §4.6 才是 beq 的拦路虎，这条没有急迫性，等定了一起做。**

---

## 7. 2026-10-14：CoreMark 上 A910 —— 两个 bug（**只定位，未改，转同事**）

【为什么盯 CoreMark】它是唯一同时压 取指/分支/访存/重命名 的真实负载，也是"乱序核到底
比顺序核快多少"的口径来源。台子已经能跑它了（§7.3 是为此新加的能力），但**跑不完** ——
第 132 条就分叉。下面两条互相独立，都卡在 LSU。

### 7.1 🔴 已提交的 store 丢写（确定性复现，`coremark_i1` 第 132 条）

复现（编译好的台子，约 30 秒）：

    make a910-difftest TEST=coremark_i1 A910_DT_MAX_CYCLES=3000000 A910_DT_ARGS=+NOVALID

现象（每次都同一条指令、同一拍）：

    T424  slot0 pc=00002728 ena=0        ← sh a5,16(sp)：把 seed3=0x66 存到 sp+16 = 0xF7B0
    T507  [AX] AR addr=0000f7a0 len=1    ← 后面 lh a14,2032(a5) 缺行，回填
    T508  [AX] R  data=0000...0000       ← 整行全 0：0x66 根本不在内存里
    T537  ❌ 第 132 条退休 pc=00002758 lh a14,2032(a5)：模型 0x66 / DUT 0
    之后 beqz a14 走了错路（T523 冲刷 tgt=00002ab4）

【已经排除的】

* **不是二进制/我的 TB 改动**：同一个 `bin/coremark_i1.bin` 在顺序核上 **0 失配**
  跑完 339,458 条（`make run TEST=coremark_i1 MAX_CYCLES=2000000 BUILD_DIR=$PWD/obj_nofsdb
  VERDI_HOME= NOVAS_HOME= VERDI_ROOTS=`）。
* **不是"没 AW 因为写进了 cache"**：本核的 store 是**直通总线**的 —— 拿**能过的** `sh`
  用例对照（`make a910-difftest TEST=sh A910_DT_ARGS="+PROBE_AXI +STL_LO=0 +STL_HI=900"`），
  它的写在 T106/T107 立刻上 AXI，strb/data 都对。
* **不是写通道 lane/strb 错位**：我一度按 hex 自左向右读成"数据在最低字却配 strb=0xF000"，
  实际 128 位里**最左是 w3**，与 strb 一致（用 `sw`/`sh` 的每一笔 AW/W 逐条核过）。

【指向】整跑里 `0xF7A0` 那一带**只有一次 AW**（T233，strb=0x00f0 的零写），那两笔 `sh`
（0x2718 → 0xF7AE、0x2728 → 0xF7B0）**退休了，但从没上过写通道**。store 已提交却既没落
内存、83 拍后同地址的 load 也没被挡住/转发 ⇒ 两个可查点：

  (a) SQ/WMB 里那条表项被谁清了 —— 时间线上 T430/T445/T458/T480/T495/T523 全是
      `src=MISPRED` 的冲刷，与 §4.7 ① **同族**（"冲刷条件把已提交的东西一起杀了"）；
  (b) load 的 WMB 依赖判据（`lsu_wmb_entry.sv` 的 `wmb_entry_depd_do_hit`）漏了这笔。

探针：`+PROBE_AXI` / `+PROBE_SQ` / `+PROBE_SD2`（窗用 `STL_LO/STL_HI`）；现场留在
`/tmp/a910_dt/coremark_i1.log`（`A910_DT_ARGS="+PROBE_AXI +STL_LO=90 +STL_HI=560"`）。

### 7.2 🟠 LSU/dcache 没有 device/uncached 旁路（MMIO 读全废）

`asm/a910_timer.S`（本轮新增的最小用例）**同一地址连读三次**：AXI 上**只有一次 AR**
（T100 `addr=fffff040 len=1`），三次都返回第一次填进 cache 的那个值 ⇒ 任何 MMIO 读
（TIMER 的 mtime、NPU 寄存器……）第二次起全是陈值。

后果：CoreMark 的 `timer_counter`（`coremark/riscv-port/core_portme.h` 的 `CM_TIMER_ADDR`）
恒等 ⇒ `total_time = 0` ⇒ 打 "ERROR! Must execute for at least 10 secs" ⇒ **分数不合法**
（这就是 §7.3 里 `+NOVALID` 存在的原因）。

修法方向：给 load 的 tag 命中与行填充各加一根 `cacheable` 判据（设备地址：不命中 +
不填充 + 直走 BIU；store 侧同理别去更新/分配 cache 行）。取值域按 SoC 约定 ——
本台 RAM 只有低 64KB，`0xFFFF_F0xx` / `0x4000_0xxx` 都是设备。

### 7.3 台子这边已经就位的（不是 bug，是能力，供跑 CoreMark 用）

* **A910 顶层没有外设**（`Peripheral name:` 那几行是黄金模型自己打的），所以 TIMER 由
  difftest 台在 AXI 从机上**现造**：读 `0xFFFFF040` 返回 TB 的周期计数器。见
  `tb/a910/tb_a910_difftest.sv` 顶部 "TIMER 外设" 那段。
* **模型计时器按"这条指令自己带回来的值"对齐**（喂每条退休包之前
  `gm_set_timer(dbg_commit_value)`）。顺序核那套"延迟 N 拍采样 `mtime`"在乱序核上不成立
  —— load 的 读→提交 距离不固定，固定延迟必然对不上。
* **`+NOVALID`**：照 `tb_miniRV_dpi.sv` 的同名开关 —— 逐拍 difftest 通过 = 功能无误，
  只是跑分不合法（退出码 1），降级成 PASS 并把**退休条数/用了多少拍**打出来。
  用它跑出来的分数**不能引用**，只能看周期/退休数。
* **CoreMark 的 context 数可配**：

      make -C coremark -f Makefile.coremark ITERATIONS=30 CONTEXTS=4 \
           BUILD_DIR=build_c4 BIN_TARGET=../bin/coremark_c4.bin

  （CoreMark 里 `MULTITHREAD` 是**数组维度**、`default_num_contexts` 才决定跑几路 ⇒
  两者一起由 `-DCOREMARK_CONTEXTS` 驱动；port 里补了缺失的 `core_start_parallel` /
  `core_stop_parallel` = 顺序跑。默认 1，与入库的 `bin/coremark.bin` **逐位相同**，`cmp` 验过。）

⚠️ 4-context 那版**还没在 A910 上跑过**：§7.1 的丢写会让 DUT 在 #132 之后走错分支，
周期数不可引用。**§7.1 修完再跑才作数。**
