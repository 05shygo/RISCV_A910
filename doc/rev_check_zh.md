# 反向验证（变异测试）：证明 asm/ 用例真的能失败

> 对象：`asm/` 下 7 个手写用例 —— `mul` / `div` / `muldiv_edge` / `branch_bench` /
> `c3_only` / `peri` / `trap`（`bin/` 里另外 41 个是导入的预制镜像，本仓没有源码）。
>
> 动因：`CORE_DESIGN.md` §9 自检清单的最后一条是「把关键门控拿掉，测试真的会失败吗？」
> 而实际上 **7 个用例里 6 个从来没做过这件事**（只有 `trap.S` 在 `DUT_BUG_REPORT.md`
> §15 有一张手工记的表）。只看"改完还全绿"没有说服力 —— 一个"改坏了也不报错"的用例
> 等于没测。
>
> 方法：`python3 scripts/rev_check.py`。按 `scripts/rev_mutations.txt` 的清单逐条
> **故意注入一个错误** → 独立 `BUILD_DIR` 重新编译 → 跑指定用例 → 断言**必须失败**
> → 自动还原（含崩溃快照 + `--restore`）。
> 全部实验在 HEAD `f72f06e`（IDU 重构之后）上做的；此后 RTL 又做过两次改动，
> 清单与结果都已同步：**非法 S 型 funct3 改成 no-op**（见 §5.3）、
> **目录重组**（IDU→`mySoC/idu/rtl/`、执行单元→`mySoC/iu/rtl/`，见
> `CORE_DESIGN.md` §2.1）。重组后 25 条全部重跑，结果不变。

---

## 1. 结论速览

| | |
|---|---|
| 变异总数 | **25** |
| 被抓 | **22** |
| 幸存 | **3** |
| 因本轮实验**补上的 asm 覆盖** | 3 条（`asm/trap.S` 三处：两处「反向验证补丁」+ 第 11 节非法 S 型） |
| 补完后由幸存转被抓 | **3 条**（M06 / M15 / M11） |
| 剩下的 3 条 | 全部是**被下游门控遮蔽**的纵深防御，加用例**不可能**抓到 —— 见 §4 |

四种「被抓到」的签名（都由 `-exitstatus` 变成非 0 返回码）：

| 签名 | 含义 | 出处 |
|---|---|---|
| `Mismatch` | 逐拍 difftest 失配 | `tb_miniRV_dpi.sv:612-617` |
| `TestPoint` | 用例自检失败（a0 非 0 / MONITOR 收到 0xDEAD） | `tb:641-657` |
| `Timeout` | 流水线卡死，超过 `MAX_CYCLES` | `tb:667-682` |
| `CAUGHT(metric)` | **仅** `branch_bench` / `c3_only`：`+BENCH` 逐类统计发生变化 | `tb:454-465` |

> ⚠️ `branch_bench` 与 `c3_only` **结构上**不可能靠返回码抓到预测错误：预测错了会在
> EX 级被纠正，永远到不了 WB 提交点，而 difftest 只比架构状态。它们的判据只能是
> 指标有没有动。这两条本来就不是 pass/fail 用例，是"度量实验"。

---

## 2. 怎么跑

```bash
python3 scripts/rev_check.py                 # 全部 25 条，约 12 分钟
python3 scripts/rev_check.py M06 M15         # 只跑指定条目
python3 scripts/rev_check.py --validate      # 只核对清单（不碰 RTL，秒级）
python3 scripts/rev_check.py --list          # 列清单
python3 scripts/rev_check.py --restore       # 进程被 kill -9 后手动还原
```

**改了 RTL 之后先跑 `--validate`。** 每条变异的 `BEFORE` 必须在该文件里**恰好出现
一次**，对不上就响亮地报错并拒绝跑 —— 这是有意的：静默跳过一条已经过期的变异，
等于假装验证过了。

三条本工程用血换来的规矩（与 `scripts/ifu2_cm_sweep.sh` 同源，脚本里都已落实）：
不给 `SIM_ARGS=`（会连 `+= -exitstatus` 一起吃掉，卡死报成 PASS）、
`env -u VERDI_HOME -u NOVAS_HOME`（否则写共享 FSDB）、
`meminit.{bin,hex,hex128}` **三个一起链**且串行（只链 bin 会让 DUT 跑上一个用例）。

### 2.1 写这个脚本时自己踩的两个坑（都在脚本里有注释）

1. **必须按字节读写 RTL。** `ifu_rv32i/rtl` 那棵树是**混**的：`rv32_ifu_bht.v`
   是 CRLF（1714 行），`rv32_ifu_l0_btb.v` 却是 LF。用文本模式 `open()` 往返会
   把整个 CRLF 文件静默翻成 LF —— `git status` 表现为"整个文件都改了"，而
   `git diff` 里看不出内容差异。现在按 `rb`/`wb` 读写，并按每个文件自己的行尾折算。
2. **清单块之间要有"等待 AFTER 定界符"的状态。** 少了它，`<<<AFTER` 这一行本身
   会被当成 after 块的正文写进 RTL，症状是 VCS 报
   `div_pipe.v, 252: token is '<<<'`。

---

## 3. 全部结果

| ID | 变异 | 注入点 | 结果 | 谁抓到的 |
|---|---|---|---|---|
| M01 | `have_inst` 门控关掉 | `IDU.v` 异常有效 | 🔴 幸存 | —（见 §4.1） |
| M02 | 非法指令的 cause 改成 breakpoint | `IDU.v` cause mux | ✅ | trap |
| M03 | 非法指令的 mtval 记 0 | `IDU.v` tval mux | ✅ | trap |
| M04 | `INST_ADDR_OK` 上界放到 4GB | `defines.vh` | 🔴 幸存 | —（见 §4.2） |
| M05 | 把 mscratch 从 CSR 白名单摘掉 | `Control.v` | ✅ | trap |
| M06 | `csr_we` 恒 1 | `Control.v` | ✅ | trap（**本轮补的用例**）|
| M07 | mret 按 rs1==2 判 | `Control.v` | ✅ | trap |
| M08 | `id_rf1_used` 恒 0 | `Control.v` | ✅ | trap / muldiv_edge |
| M09 | `id_rf2_used` 恒 0 | `Control.v` | ✅ | trap / peri |
| M10 | `dram_sel` 缺省 LB→SW | `Control.v` | 🔴 幸存 | —（见 §4.3） |
| M11 | 非法 S 型 funct3 兜底臂改成会写内存 | `Control.v` | ✅ | trap（**本轮补的用例**）|
| M12 | `Sext_I` 符号位取错一位 | `SEXT.v` | ✅ | trap |
| M13 | `Sext_Z` 取到 `din[7:3]` | `SEXT.v` | ✅ | trap |
| M14 | x0 可写 | `RegFile.v` | ✅ | mul / trap |
| M15 | `ALUB_SEL_ZERO` 改成 `rD2` | `ALU_input_MUX.v` | ✅ | trap（**本轮补的用例**）|
| M16 | mret / 陷阱的重定向目标对调 | `mycpu.v:223` | ✅ | trap |
| M17 | 去掉提交点的 `~wb_exc` 写回门控 | `mycpu.v:230` | ✅ | trap |
| M18 | 乘除法写回不走 `md_resp_data` | `mycpu.v:240` | ✅ | mul / muldiv_edge |
| M19 | `mul_stall` 关掉 | `Hazard_Detection.v:107` | ✅ | muldiv_edge |
| M20 | `div_stall` 不再停顿 | `Hazard_Detection.v:110` | ✅ | div / muldiv_edge |
| M21 | 写回口恒选除法那一路 | `MUL_DIV.v:130` | ✅ | mul |
| M22 | 商 / 余数对调 | `div_pipe.v:252` | ✅ | div / muldiv_edge |
| M23 | `sel_dram` 恒 1（MMIO 写污染 DRAM） | `perip_bridge.v:59` | ✅ | peri |
| M24 | L0 BTB 永不分配 | `rv32_ifu_l0_btb.v:133` | ✅ | branch_bench（指标）|
| M25 | BHT 选择器索引丢掉相位位 | `rv32_ifu_bht.v:1076` | ✅ | c3_only + branch_bench（指标）|

每个手写用例都被至少一条变异指着，且都有"这条用例确实是抓它的那一个"的条目：

| 用例 | 专属（只有它抓到的）变异 |
|---|---|
| `mul` | M21 |
| `div` | —（M20/M22 由 div + muldiv_edge 共同抓到）|
| `muldiv_edge` | M19 |
| `peri` | M23 |
| `trap` | M02 M03 M05 M06 M07 M13 M15 M16 M17 |
| `branch_bench` | M24 |
| `c3_only` | M25（c3_only + branch_bench 都动了）|

---

## 4. 幸存变异 —— 逐条归因

**三条都不是"用例写漏了"**，加用例抓不到它们 —— 都是**被下游门控遮蔽**的
纵深防御（有第二条防线兜着）。两条都用"复合变异"实验**证明**了遮蔽来源，
不是靠读代码断言。

### 4.1 M01 · `IDU.v` 的 `have_inst` 门控 —— 被提交点的第二道门控遮蔽

去掉 `idu_exc_vld_o` 上的 `& idu_have_inst_i` 之后，每个流水线气泡（`inst` 全零，
而全零正好是"非法指令"）都会产生一个异常。看起来应该炸掉一切，实际 `mul` 和 `trap`
**都照过**。

原因：提交点还有一道

```verilog
wire wb_exc = wb_exc_valid & have_inst_WB;      // mycpu.v:214
```

气泡带到 WB 时 `have_inst_WB = 0`，异常在那里被二次挡掉；寄存器写回也被
`wb_rf_we_eff = wb_rf_we & ~wb_exc & ~irq_taken` 挡着。

**复合变异证明**（本轮实跑）：

| 注入 | 结果 |
|---|---|
| 只有 M01 | `mul` = PASS |
| M01 **+** 把 `wb_exc` 的 `& have_inst_WB` 拆掉 | `mul` = **Timeout** |

⇒ IDU 这位门控是**冗余的纵深防御**，不是唯一防线。它仍然该留着（让异常在最早一级
就干净），但**不能**把它当成"气泡不会变成陷阱"的保证 —— 真正兜底的是提交点那道。

### 4.2 M04 · `INST_ADDR_OK` 的上界 —— 被 IFU 的取指故障包遮蔽

把取指越界判据从 64KB 放到 4GB，`trap.S` 第 9 节（`jalr x0,0x20000` 断言 cause 1）
**照样通过**。

原因：cause 1 有**两个**来源 —— IFU 自己的取指故障包（`idu_ifu_fault_i`，走 IFU 的
fault 位）和 IDU 自己算的 `id_inst_oob`。前者是**主**来源，后者只是
`pc >= 64KB` 时的兜底；两条判据在这个用例上完全一致（`IDU.v` 的注释写的就是这件事）。

**复合变异证明**：

| 注入 | 结果 |
|---|---|
| 只有 M04 | `trap` = PASS |
| M04 **+** 把 `id_ifu_fault` 恒 0 | `trap` = **Timeout** |

⇒ 同样是冗余的纵深防御。要真正验证 `id_inst_oob` 这条兜底，需要一个**绕过 IFU
故障包**的激励（例如让 IFU 不报 fault 而 PC 已经越界）—— 当前 ifu2/ifu_rv32i 都
不会造出这种包，所以这条兜底在现有前端下**不可达**。

### 4.3 M10 · `Control.v` 的 `dram_sel` 缺省值 —— **等价变异**

`Control.v:155-157` 有一段很重的注释，说 `dram_sel` 缺省必须取 LB ——
"LB 让 `ex_wsize_word/ex_wsize_half` 都为 0，于是 `ex_addr_bad` 连 `ex_alu_c` 都不看"，
并叮嘱"**不要**改成 SW/SH"。把缺省改成 SW 之后，`muldiv_edge` 和 `trap` 都没抓到。

原因：这段注释描述的危害**已经被下游消灭了**。`ex_addr_bad` 的消费者只有两个：

```verilog
wire ex_load_misaligned  = have_inst_EX & ex_is_load  & ex_addr_bad;   // mycpu.v:762
wire ex_store_misaligned = have_inst_EX & ex_is_store & ex_addr_bad;   // mycpu.v:763
```

而 `ex_is_load = ex_rf_we & (ex_rf_wsel == RF_WSEL_DRAM)`、`ex_is_store = ex_ram_we`
—— **都不看 `dram_sel`**。这正是 `CORE_DESIGN.md` §8.1 那条"判 load 不能只看
`dram_sel`"的规矩被落实之后的结果。于是对非访存指令来说，`dram_sel` 缺省取什么都
是 don't-care ⇒ 改了也**没有任何可观测差异**。

⇒ 注释本身无害（保守一点没坏处），但它描述的**因果链已经断了**。§8.1 那条判据才是
真正承重的那一条。

### 4.4 原 M11 · 非法 store funct3 的兜底臂 —— 曾是等价变异，现已改掉

第一轮里 M11 打的是 `Control.v` 的 `default: dram_sel = DRAM_SEL_SW` / `LW`。
它是**等价变异**：`MEM.v:46` 的 case 之前无条件给了 `wdata_out = wdin`，而 LW
那一臂**只赋 `rdo`**、不碰 `wdata_out` ⇒ SW 与 LW 对 store **逐位相同**；而
`ex_wsize_word` 也把 LW/SW 同等看待（`mycpu.v:759`），`rdo` 对 store 又不可达
（store 的 `rf_we=0`）。历史那个"垃圾数据"bug 的成因是"**MEM.v 的 `wdata_out`
当时也是 latch**"——MEM.v 在 2026-09-28 那轮 112 个推断 latch 的清理里补上了
无条件默认值，**承重的那一半就搬到了 `MEM.v:46`**。

**这条后来被处理掉了**（见 §5.3）：整个兜底臂改成纯 no-op 之后，承重位从
"dram_sel 取哪个读选择子"变成了 `ram_we = 1'b0`，M11 也随之重定向成一条**真能被
抓到**的变异。

---

## 5. 本轮补上的三处 asm 覆盖

三处都是"用例没覆盖到"，补完即由幸存转被抓（`asm/trap.S`）。

### 5.1 补丁 1：CSR 读的 B 口必须是 0（抓 M15）

守 `ALU_input_MUX` 的 `ALUB_SEL_ZERO: B = 32'b0`。改成 `B = rD2` 时，CSR 读回的
变成"旧值 + 某个寄存器"。

**原来为什么抓不到**：`rD2 = regs[inst[24:20]]`，而 CSR 指令的 `inst[24:20]` 是
**csr 地址的低 5 位**。原来那些用例只用了 `mscratch`(0x340) 和 `mstatus`(0x300) ——
两者的低 5 位**都是 0**，索引到 `x0`，而 `x0` 恒为 0，于是"B 口给 0"和"B 口给 rD2"
**完全分不出来**。

补丁用 `mtvec`(0x305 → 低 5 位 = 5 → `x5`)，先把 `x5` 设成非 0 再读：

```asm
la   x28, trap_handler
csrw mtvec, x28
li   x5, 0xDEADBEEF          # 让 rD2 指向的 x5 非 0
csrr x29, mtvec
bne  x29, x28, fail          # 正确结果 = mtvec 本身, 不是 mtvec + x5
li   x5, 0
```

### 5.2 补丁 2：对**只读** CSR 的纯读必须合法（抓 M06）

守 `Control.v` 的 `csr_we = (csr_op == CSR_OP_RW) || (rs1_addr != 5'b0)`。
若 `csr_we` 恒 1，`csrrs rd, <只读 CSR>, x0` 会撞上
`is_illegal = csr_we && csr_addr_ro` 被判非法。

**原来为什么抓不到**：原有那条 `csrrs x25, mscratch, x0` 里的 `mscratch`
**可写**，恒写也只是把旧值写回去，语义上没有差别。

补丁用 `mcycle`（只读），拿 `x5` 当哨兵：

```asm
li   x5, -1
csrrs x0, mcycle, x0         # rd 必须写 x0 —— 见下面的坑
li   x28, -1
bne  x5, x28, fail           # 没陷入的话 x5 保持 -1
```

> ⚠️ **`rd` 必须写 `x0`**。第一版写成 `csrrs x29, mcycle, x0`，`trap` 在第 **1146**
> 拍就 difftest 失配：DUT 的 `mcycle` 数真实周期，而参考模型是**提交步进**的、只能
> 按"每条指令 +1"计数（`DUT_BUG_REPORT.md` §16.3），两者本来就对不上 —— 计数器的值
> 一旦落进 `rd` 就会被提交点比较。这里只需要"有没有陷入"这一个信息，值本身不要。

### 5.3 补丁 3：非法 S 型 funct3 退化成纯 no-op（§4.4 的收口）

§4.4 里追出过一个规范偏离：非法 S 型 funct3 被 DUT 和参考模型**都**当成 SW 执行。
按 `RISCV_CPU/cpu`（参考核）的做法对齐之后，这条**已经定案**：

**参考核怎么做的**（`cpu/src/inst_decoder.v:218-240`）：

```verilog
`INST_TYPE_S: begin
    ...
    case (funct3)
        `INST_SB: inst_subtype_o = `MEM_SB;
        `INST_SH: inst_subtype_o = `MEM_SH;
        `INST_SW: inst_subtype_o = `MEM_SW;
        default:  inst_subtype_o = 4'b0;      // = 它的 MEM_LB
    endcase
end
```

`reg_wflag_o` 在 S 分支开头就已置 0。也就是说参考核的策略是
**「挑一个无害的默认值继续走，不判非法指令」**——它整个核都没有非法指令机制
（异常只有 `ecall`/`ebreak`/`mret`，见 `cpu/src/wb.v:35-58`）。

**本核据此改成**（`Control.v` 的 `OPCODE_S` 兜底臂）：

```verilog
default: begin
    dram_sel = `DRAM_SEL_LB;
    ram_we   = 1'b0;              // 关键：不写内存
end
```

副产物是 `ex_is_store = ex_ram_we = 0` ⇒ 既不查非对齐也不查越界；
`ex_is_load` 也恒 0（本分支 `rf_we=0`）⇒ cause 5/6/7 都产生不了，整条退化成 no-op。

参考模型同步（`golden_model/stage/ID.c` 的 `ID_S` 兜底臂）：

```c
default: ret.mem_op = MEM_LB; ret.is_mem = 0; break;
```

`is_mem = 0` 是关键：`MEM.c:110` 的访存块是 `if(ex_info.is_mem && ...)` 进入的，
置 0 之后既不写内存也不做越界/非对齐检查。**只把 `mem_op` 改成 `MEM_LB` 而留着
`is_mem=1` 是不行的**——那样 `EX.c` 会把 `mem_op==MEM_LB` 当成一次 **load** 去查
越界并报 cause **5**，而 DUT 什么都不报，两边立刻对不上。
（`EX.c:128-130` 的 `is_store_op` 也只认 SB/SH/SW，所以留着 `MEM_SW` 会报 cause 6/7。）

**为什么比原来的 SW 更好**：SW 仍然**真的写一个整字**（本核没有字节使能，
`MEM.v` 靠读-改-写模拟窄访问），而且奇数地址上还会报 cause 6 ——
给一条非法指令报"非对齐"没有意义。改成 `ram_we=0` 之后，那类"垃圾写"从根上没有了。

**新用例**（`asm/trap.S` 第 11 节）把这条行为钉住：

```asm
la   x30, s_f3_target
li   x29, 0x11112222
sw   x29, 0(x30)            # 哨兵
li   x29, 0x5555AAAA
.word 0x01DF3023            # 非法 funct3 的 S 型 (本该是 sw x29,0(x30))
lw   x31, 0(x30)
bne  x31, x28, fail         # 哨兵必须原封不动
addi x30, x30, 1            # 奇数地址: 旧写法会报 cause 6
li   x5, -1
.word 0x01FF3023            # 同一编码, rs2=x31
bne  x5, x28, fail          # 不该陷入
```

配套的 M11 也随之**重定向**：原来打 `dram_sel` 取 SW 还是 LW（等价变异），
现在打 `ram_we = 1'b0` → `1'b1`。补完**由幸存转为被抓**。

> 注：这条同时说明了一件事——**"参考核怎么做"和"规范怎么说"不总是一致**。
> 这里选择了跟参考核（不陷入）。要改成按规范判非法指令的话，DUT 与参考模型
> 必须同时改，并重跑全量回归。

---

## 6. 已知边界

- **没覆盖的**：`bin/` 里另外 41 个导入用例（`addi`/`lw`/`sw`/…）。它们大多极短
  （`addi` 只跑 1725 拍），造激励的性价比低；7 个手写用例已经覆盖了全部 RTL 模块。
- **`branch_bench` / `c3_only` 的判据是"指标动了"**，不是阈值 —— 只要 `+BENCH`
  的逐类统计与基线有一处不同就算抓到。这足以回答"这条用例对预测器改动有没有反应"，
  但不回答"动多少才算有意义"。
- **没跑综合**：本轮全是仿真，没有 Vivado。
- `scripts/rev_check.py` 会改工作树里的 RTL。它在开跑前落一份磁盘快照，`finally`
  里还原，并提供 `--restore`；每轮结束打印 `git status --porcelain` 自检。
  实测 25 轮跑完工作树无残留。
