# A910 接入 coralnpu RVV core —— 分阶段修改执行计划（v2）

> 版本：v2.1（2026-10-17）
> 上游方案：`doc/rvv_a910_接入修改计划_信号级_zh.md`（下称 v1）
> 本文不改 v1 的总体技术方案；只把"怎么改"拆成 10 个可独立落地的修改批次，
> 并修正 v1 中会导致返工/卡死的事实性错误（见附录 A）。
>
> **2026-10-17 方案修订（A 方案）**：向量 load/store 改为
> **IS 派发时在 LSIQ 创建 anchor + RVV core 逐 beat 填充**。
> LSIQ 保持 **8 项**、SDIQ 保持 **4 项**；不再使用"专用 tag 8~11 / LSIQ 8→12 /
> SDIQ 4→6 / 4-slot 独立引擎"。agevec/old/同类型发射顺序复用。详见 S7/S8。
>
> **核心执行原则**：阶段之间只做**编译级检查**（elaborate），不跑仿真、不跑
> difftest、不出波形。功能验证全部集中在 S9 一次做完。这样做的目的就是避免
> "每个阶段都搭台、都调试、都返工"的验证内耗。

---

## 0. 执行模型（先读这一节）

### 0.1 阶段的定义：修改批次，不是验证里程碑

S0 ~ S8 的每一段都是一组**互不重叠的 RTL 修改**。每段结束时只要求：

1. 设计**能 elaborate**（语法、端口、位宽、模块存在性全部过关）；
2. 本段引入的新信号在"生产者/消费者"两端都有明确归属（静态 grep 核对）；
3. 工作树可以整体回滚到本段之前（建议一段一个 git commit）。

**不做**：仿真、单元台、difftest、波形、性能测试。

### 0.2 为什么可以把功能验证全部压到 S9

| 中间阶段跑仿真的问题 | 本计划的替代手段 |
|---|---|
| 大部分新逻辑被钉 0/悬空，仿真只覆盖"没接通的电路"，噪声远大于信息 | 用 elaborate 检查所有结构错误（漏端口、位宽不符、悬空线、常量截断） |
| 接口在后续阶段还会变，前面写的 TB 要重写 | S3/S4/S6 一次性冻结 bridge↔IDU、bridge↔core、core↔LSU 三组接口 |
| 每段重编 simv 的时间远大于改 RTL | 每段只跑一次 `a910-elab`（VCS 编译，不仿真） |
| 早测出来的"失败"多数是阶段内的半成品状态，不是真 bug | 所有功能路径在 S9 一起打开，失败定位按 S9 的分层顺序做 |

风险是"逻辑 bug 堆到最后"。控制手段有三条：

- **改法机械化**：每个阶段只做"加端口/改位宽/加 mux/照抄同类逻辑"，不引入
  新算法；
- **接口先冻结**：bridge 的端口在 S3 一次定义完，后面只填内部逻辑；
- **阶段提交**：S9 出问题时按阶段二分（先摘 S7/S8 的 tie-off，再摘 S5/S6）。

### 0.3 三条硬纪律

1. **接口先冻结**：S3 定义 bridge 的全部端口（包括 S5/S8 才会用到的 trap/LSU
   端口），S4/S5/S8 只改内部连线；端口名和位宽不再变。
2. **新输入先钉 0、新输出先悬空**：一个模块新增的输入端口，如果生产者还没落地，
   父层必须显式接 `'0`，**不允许**留空（VCS 的隐式线会把悬空变成静默错误）。
   新增输出端口如果暂时没人用，可以不接，但必须在阶段清单里记一笔。
3. **位宽一次改到位**：IR/IS/ctrl_info/VIQ 这类位宽扩展，在同一阶段内把所有
   参数副本、所有拼接、所有切片一次改完；不允许"先改一半让别的阶段补"。

### 0.4 每个阶段的唯一出口检查

```bash
# 只要改了 mySoC/design/（coralnpu core）里的文件，先跑：
make rvv-elab
# 每个阶段都必须跑：
make a910-elab
```

判据：

- `Error-[...]` = 0；
- A910 侧（`mySoC/` 下、`mySoC/design/` 以外）新增的 `IWNF`（悬空线）/
  `DCTTSW`（常量截断）/`PCWM-W` 必须为 0；
- RVV 上游文件的历史警告可以打印出来，但**与本阶段改动前逐条对比，不能新增**。
  S0 结束时把 RVV 警告全集存一份基线（见 S0.4）。

**除上面两条命令外，S0~S8 期间禁止**：

```text
make a910-run / a910-run_smoke
make a910-difftest / a910-difftest-all / a910-difftest-*-wave
make idu-unit / lsu-unit / rtu-unit / rtu-adapter-unit / biu-unit
make verdi / verdi-difftest
```

> 唯一例外：S0 的 `make rvv-elab` 本身就是编译检查，不是仿真。
> `a910-elab` 内部已经用 `rm -rf simv.daidir simv` 防陈旧，直接复用即可。

### 0.5 阶段提交

建议每段结束执行一次（用户已明确要求分阶段进行）：

```bash
git add -A
git commit -m "rvv-S<n>: <阶段名> (elab only)"
```

S9 之前不 push。这样 S9 定位问题时可以 `git diff rvv-S<n-1>..rvv-S<n>` 看某一
段到底改了什么。

---

## 1. 阶段总览

| 阶段 | 名称 | 主要落点 | 依赖 | 出口 |
|---|---|---|---|---|
| S0 | 编译基线 | Makefile、`mySoC/design/{inc,common}` | — | `rvv-elab` + `a910-elab` |
| S1 | ID/IR/IS 识别与位宽通道 | 6 个 IDU 流水模块 + top | S0 | `a910-elab` |
| S2 | VIQ 与 IS 派遣 | `ct_idu_vecq*`（新）、is_ctrl/is_dp/top | S1 | `a910-elab` |
| S3 | PRF 端口、vset 唤醒、bridge 骨架 | PRF、dep entry 全族、bridge（新）、A910_cpu | S2 | `a910-elab` |
| S4 | 完成、提交门控、flush、配置恢复 | ROB、backend、RvvCore、bridge | S3 | `a910-elab` |
| S5 | 计算类闭环与异常出口 | queue 改名、bridge trap、adapter 合并 | S4 | `a910-elab` |
| S6 | core LSU 接口与 remap scoreboard | `rvv_backend*.s*`、RvvCore、remap | S5 | `a910-elab` |
| S7 | LSIQ anchor 与 LSU 向量支持 | anchor 字段/create/beat_done/pop-last、vec/uop_idx 贯通、LQ/MSHR/SQ | S6 | `a910-elab` |
| S8 | fill 引擎与全链接通 | `ct_idu_vec_ls_fill`（新）、IDU top、SDIQ、bridge | S7 | `a910-elab` |
| S9 | 收口与全量验证 | TB force、asm、验证矩阵 | S8 | 全部功能用例 |

> S1~S8 共 8 次 `a910-elab`（每次是 VCS 编译，不是仿真），这是整个计划里
> 唯一的"阶段开销"。不要把 S1/S2、S3/S4、S7/S8 合并，否则一次错误会污染
> 上百行 diff，定位成本反而更高。

---

## 2. S0 —— 编译基线（不改任何 RTL 行为）

### 2.1 目标

- coralnpu RVV core 子集与 A910 在同一个 VCS 文件表里，且能单独 elaborate；
- A910 原有 elaborate 判据不退化；
- 之后所有阶段都复用这套 Makefile。

### 2.2 已就位的前置

当前工作树里已经存在（无需再拷）：

- `mySoC/design/inc/`：9 个 `rvv_backend*.svh`；
- `mySoC/design/common/`：20 个原语 `.sv`（已排除 `fp_add.sv`）；
- `mySoC/design/`：57 个 coralnpu `.sv`。

### 2.3 Makefile 改动

在 `A910_SRC` 定义（Makefile:737 起）之前加：

```make
RVV_DESIGN := $(wildcard $(PWD)/mySoC/design/*.sv)
RVV_DROP   := rvv_backend_falu.sv rvv_backend_falu_unit.sv \
              rvv_backend_fdiv.sv rvv_backend_fdiv_unit.sv \
              rvv_backend_fdiv_wrapper.sv rvv_backend_freduction.sv \
              rvv_backend_sqrt7_rec7.sv \
              Aligner_tb.sv MultiFifo_tb.sv
RVV_SRC    := $(filter-out $(addprefix $(PWD)/mySoC/design/,$(RVV_DROP)),$(RVV_DESIGN))
RVV_COMMON := $(wildcard $(PWD)/mySoC/design/common/*.sv)
RVV_INC    := +incdir+$(PWD)/mySoC/design/inc
RVV_DEFS   := +define+VLEN_128 +define+RTBUF_DEPTH=128
```

然后：

1. `A910_SRC` 末尾追加 `$(RVV_SRC) $(RVV_COMMON)`（Makefile:737-743）。
2. 所有 VCS 命令行追加 `$(RVV_INC) $(RVV_DEFS)`：
   - `a910-elab`（:753）；
   - `$(A910_SIMV)`（:825）；
   - `$(A910_DT_SIMV)`（:869）；
   - `$(A910_DT_WAVE_SIMV)`（:928）。
3. 所有 Verdi 定义追加同样的东西（否则波形位宽与编译时不一致）：
   - `A910_VERDI_DEFS`（:1145）；
   - `A910_DT_VERDI_DEFS`（:1152）。
4. 新增目标：

```make
RVV_BUILD := $(PWD)/obj_rvv_elab
RVV_LOG   := $(RVV_BUILD)/elab.log

rvv-elab:
	@mkdir -p $(RVV_BUILD)
	@rm -rf $(RVV_BUILD)/simv.daidir $(RVV_BUILD)/simv
	@$(VCS) $(VCS_FLAGS) $(INC) $(RVV_INC) $(RVV_DEFS) \
	  -top RvvCore -o $(RVV_BUILD)/simv \
	  $(RVV_SRC) $(RVV_COMMON) > $(RVV_LOG) 2>&1 || true
	@E=$$(grep -cE 'Error-\[' $(RVV_LOG) || true); \
	 echo "  RVV Error=$$E"; \
	 if [ "$$E" != "0" ]; then echo "  ❌ rvv-elab 失败, 见 $(RVV_LOG)"; exit 1; fi
```

5. `a910-elab` 的 IWNF/DCTTSW/PCWM 计数：**A910 自己的文件继续严格为 0**；
   `mySoC/design/` 下的 RVV 警告单独打印，不参与门禁。实现方式是在计数命令里
   过滤路径，或者新增一个 `RVV_W` 计数并只打印。**不要**把 RVV 警告一起算进
   `IWNF != 0` 的失败分支，否则上游既有警告会让后续每个阶段都"红"。

### 2.4 基线与出口

```bash
make rvv-elab && make a910-elab
# 额外做一次：把 RVV 警告全集存成基线
grep -E 'Warning-\[(IWNF|DCTTSW|PCWM-W)\]' obj_rvv_elab/elab.log | sort -u \
  > doc/rvv_a910_elab_warn_baseline.txt
```

- `RvvCore` 单独 elaborate：Error = 0；
- `A910_cpu` elaborate：Error = 0，A910 侧 IWNF/DCTTSW/PCWM = 0；
- 自此之后，任何阶段若 RVV 警告比基线多，必须在本阶段内解决或明确记录原因。

### 2.5 风险

- 不定义 `VLEN_128`，`rvv_backend_define.svh` 会直接 `$display` 报错。
- **不要**定义 `ZVE32F_ON` / `ZVT_ON` / `ARBITER_ON` / `DISPATCH3` /
  `PRECISE_RVVTRAP`；默认配置就是本计划要的"无 FP/Zvt、PU 直连 ROB"。
- `RTBUF_DEPTH=128` 把 `ROB_TAG_WIDTH` 变成 7，正好装 A910 的 iid；
  不定义就是 4 位，直接错位。
- 不要拷 `fp_add.sv`（无条件引用 `fpnew_pkg`）。
- 不要用 `obj_unit_rvv/`、`obj_scratch_rvv/` 里的旧 simv/log 作为任何依据。

---

## 3. S1 —— ID/IR/IS 识别与位宽通道

### 3.1 目标

- 向量三类 opcode（LOAD-FP / STORE-FP / OP-V）在 ID 级不再判非法；
- `vec / vec_type` 两位标志从 ID 一路带到 IS；
- IR 123→126、ctrl_info 7→9（vec + vmem）、IS 76→79 三条位宽通道一次打通；
- 向量指令**不进**任何标量队列（AIQ/BIQ/MD/LSIQ/SDIQ）。
  > 例外在 S7 才打开：vector LOAD/STORE 要在 LSIQ 建 anchor。S1~S6 期间仍按
  > `!vec` 全挡；S7 把 LSIQ 的判据改成 `(标量 LSU) || IS_CTRL_VMEM`。
- 因为 A 方案需要区分"向量计算"和"向量访存"，`ctrl_info` 加两位：
  `IS_CTRL_VEC=7`、`IS_CTRL_VMEM=8`，宽度 7→**9**。

本阶段**不建 VIQ**：向量指令在本阶段只会被判为"不派遣"，不会卡住流水；
编译可过即可。

### 3.2 `ct_idu_id_decd.sv`

新增端口：

| 端口 | 方向 | 位宽 |
|---|---|---|
| `vec` | output | 1 |
| `vec_type` | output | 2（01=LOAD，10=STORE，11=RVV） |

内部 wire（按当前文件的实际行号核对过）：

```systemverilog
wire op_vload  = (opcode == 7'b0000111);  // LOAD-FP
wire op_vstore = (opcode == 7'b0100111);  // STORE-FP
wire op_rvv    = (opcode == 7'b1010111);  // OP-V / vset
wire is_vset   = op_rvv && (funct3 == 3'b111);
wire is_vsetivli = is_vset && (inst[31:30] == 2'b11);
wire is_vsetvl   = is_vset && inst[31] && !is_vsetivli;
wire is_vstride  = (op_vload || op_vstore) && (inst[27:26] == 2'b10);
wire is_vsrc1    = is_vstride || is_vsetvl;
wire is_vsrc0    = op_vload || op_vstore ||
                   (op_rvv && (is_vset ? !is_vsetivli : funct3[2]));
```

修改的现有赋值（行号为当前文件实测）：

| 信号 | 行 | 改为 |
|---|---|---|
| `valid_inst` | 134 | 追加 `\|\| op_vload \|\| op_vstore \|\| op_rvv` |
| `illegal` | 138 | 不变（向量已进 valid_inst） |
| `src0_vld` | 144 | `(原有标量项) \|\| is_vsrc0`，整体仍 `&& !illegal` |
| `src1_vld` | 148 | `(原有标量项) \|\| is_vsrc1`，整体仍 `&& !illegal` |
| `dst_vld` | 155 | `(原有标量项) \|\| (is_vset && rd != 5'b0)`，整体仍 `&& !illegal` |
| `dst_x0` | 157 | `(rd == 5'b0) \|\| (vec && !is_vset)` |
| `inst_type[5:0]` | — | **不改**：三类向量 opcode 不会命中任何标量 op_* 判定 |

输出：

```systemverilog
assign vec      = op_vload | op_vstore | op_rvv;
assign vec_type = op_rvv    ? 2'b11 :
                  op_vstore ? 2'b10 :
                  op_vload  ? 2'b01 : 2'b00;
```

要点：

- `vsetivli` 没有 rs1/rs2，`is_vsrc0/is_vsrc1` 都必须为 0；
- `vsetvli` 的 rs1=x0 仍置 `src0_vld=1`，读到的是 preg0（恒 ready），最省事；
- `vsetvl` 的 rs2 是 vtype，走 `src1`；
- 向量 L/S 的 rs1 恒为基址；strided 的 rs2 为步长；
- **不要**把 `vec` 拼进 `inst_type`，否则会误进 LSIQ/AIQ。

### 3.3 `ct_idu_id_dp.sv`

| 项 | 现状 | 改为 |
|---|---|---|
| `IR_WIDTH`（:47） | 123 | 126 |
| 新增 `IR_VEC` | — | 123 |
| 新增 `IR_VEC_TYPE` | — | 125:124 |
| `crtl_ir_inst2_data` 端口（:13） | `[122:0]` | `[125:0]` |
| `dp_id_pipedown_inst{0,1,2}_data` 端口（:18/:20/:22） | `[122:0]` | `[125:0]` |
| `dp_id_pipedown_inst*_data_raw`（:113-115） | `[IR_WIDTH-1:0]` | 跟随参数 |

拼装改动：在 3 处 `assign dp_id_pipedown_inst{k}_data_raw = {`（:264/:283/:302）
的花括号**最前面**加两个字段：

```systemverilog
{ id_inst{k}_vec_type, id_inst{k}_vec,
  id_inst{k}_taken, id_inst{k}_npc, ... }
```

> 这不是"把老字段整体左移"：新字段占据 [125:123]，老的 `taken` 仍在 122，
> 所以 `IR_TAKEN/IR_NPC/...` 这些**绝对位号全部不用改**。
> 在 3 个 `ct_idu_id_decd` 例化处新增 `.vec()/.vec_type()`，内部新增
> `id_inst{0,1,2}_vec`、`id_inst{0,1,2}_vec_type[1:0]` 并接上。

`ct_idu_id_ctrl.sv` **不改**（它只搬 vld/accept_num）。

### 3.4 `ct_idu_ir_dp.sv`

| 项 | 现状 | 改为 |
|---|---|---|
| `IR_WIDTH`（:87） | 123 | 126 |
| `IS_CTRL_WIDTH`（:102） | 7 | 9 |
| `dp_ctrl_ir_inst{0,1,2}_ctrl_info` 端口（:34/:39/:44） | `[6:0]` | `[8:0]` |
| `dp_ir_inst{0,1,2}_data` 端口（:49/:52/:55） | `[75:0]` | `[78:0]` |
| `crtl_ir_inst2_data` 端口（:5） | `[122:0]` | `[125:0]` |
| `assign crtl_ir_inst2_data[122:0]`（:399） | 123 位 | `[125:0]`，右接 `ir_inst2_data` |
| 新增 `IS_VEC` / `IS_VEC_TYPE` | — | 76 / 78:77 |
| 新增 `IS_CTRL_VEC` | — | 7 |
| 新增 `IS_CTRL_VMEM` | — | 8（`vec && vec_type∈{01,10}`） |

内部：

```systemverilog
wire [1:0] ir_inst{k}_vec_type = ir_inst{k}_data[IR_VEC_TYPE];
wire       ir_inst{k}_vec      = ir_inst{k}_data[IR_VEC];
assign dp_ctrl_ir_inst{k}_ctrl_info[IS_CTRL_VEC]  = ir_inst{k}_vec;
assign dp_ctrl_ir_inst{k}_ctrl_info[IS_CTRL_VMEM] =
       ir_inst{k}_vec && (ir_inst{k}_vec_type == 2'b01 ||
                          ir_inst{k}_vec_type == 2'b10);
```

`dp_ir_inst{k}_data` 是逐位 assign 的（:469 起），不是一整个拼接：
在每一组里新增两行即可，老位号不动：

```systemverilog
assign dp_ir_inst{k}_data[78:77] = ir_inst{k}_vec_type;
assign dp_ir_inst{k}_data[76]    = ir_inst{k}_vec;
```

`ct_idu_ir_decd.sv` **不改**：向量位来自 IR[123]，IR 级不重译 opcode。

### 3.5 `ct_idu_ir_ctrl.sv`

| 项 | 现状 | 改为 |
|---|---|---|
| `dp_ctrl_ir_inst*_ctrl_info` 输入 | `[6:0]` | `[8:0]` |
| `ir_pipedown_inst{0,1,2}_ctrl_info`（:125-129） | `[12:0]` | `[14:0]` |
| `IS_CTRL_WIDTH`（:184） | 7 | 9 |
| 新增 `IS_CTRL_VEC` | — | 7 |
| 新增 `IS_CTRL_VMEM` | — | 8（`vec && vec_type∈{01,10}`） |

新增内部信号：

```systemverilog
logic ctrl_ir_inst{0,1,2}_vec;
logic ctrl_ir_inst{0,1,2}_vec_vld;
logic ctrl_ir_pre_dis_inst{0,1,2}_vec;
logic ctrl_ir_pre_dis_3_vec_inst;
logic ctrl_ir_pre_dis_vec_create0_en;
logic ctrl_ir_pre_dis_vec_create1_en;
logic [1:0] ctrl_ir_pre_dis_vec_create0_sel;
logic [1:0] ctrl_ir_pre_dis_vec_create1_sel;
```

1. **六个标量队列全部加 `&& !vec`**（:315-337 那一组）：

```systemverilog
assign ctrl_ir_inst{k}_aiq  = (原表达式) && !ctrl_ir_inst{k}_vec;
assign ctrl_ir_inst{k}_mult = (原表达式) && !ctrl_ir_inst{k}_vec;
assign ctrl_ir_inst{k}_div  = (原表达式) && !ctrl_ir_inst{k}_vec;
assign ctrl_ir_inst{k}_biq  = (原表达式) && !ctrl_ir_inst{k}_vec;
assign ctrl_ir_inst{k}_lsiq = (原表达式) && !ctrl_ir_inst{k}_vec;
assign ctrl_ir_inst{k}_sdiq = (原表达式) && !ctrl_ir_inst{k}_vec;
```

> S1 阶段 lsiq 也按 `!vec` 挡住；**S7 再改成**
> `(原标量 LSU 项) || ir_pipedown_inst{k}_ctrl_info[IS_CTRL_VMEM]`，
> 让 vector LOAD/STORE 在 IS 创建 anchor。其余五个队列永远 `!vec`。

2. **create0/create1 仲裁照抄 AIQ 的 :435-489**，把 `_aiq` 换成 `_vec`：

```systemverilog
assign ctrl_ir_pre_dis_inst{k}_vec = ctrl_ir_pre_dis_inst{k}_vld && ctrl_ir_inst{k}_vec;
assign ctrl_ir_pre_dis_3_vec_inst =
       ctrl_ir_pre_dis_inst0_vec && ctrl_ir_pre_dis_inst1_vec &&
       ctrl_ir_pre_dis_inst2_vec;
wire v0 = ctrl_ir_pre_dis_inst0_vec;
wire v1 = ctrl_ir_pre_dis_inst1_vec;
wire v2 = ctrl_ir_pre_dis_inst2_vec;
assign ctrl_ir_pre_dis_vec_create0_en = v0 | v1 | v2;
assign ctrl_ir_pre_dis_vec_create1_en = (v0 & v1) | (v0 & v2) | (v1 & v2);
// create0_sel: v0 优先，其次 v1，其次 v2
// create1_sel: v0&v1 ⇒ 1，否则 ⇒ 2
```

3. 把 `ctrl_ir_pre_dis_3_vec_inst` 或进
   `ctrl_ir_pre_dis_type_stall_pipedown2`（:387-392）。这样一拍最多只放两条
   向量指令进 IS，第三条留到下一拍，保证 VIQ 的 2 个写口不会溢出、也不会
   打乱程序序。

4. `IS_CTRL_ILLEGAL` 仍拼进 aiq（:315-317）没问题：向量指令的 `illegal` 已经
   是 0。

### 3.6 `ct_idu_is_ctrl.sv`

新增端口：

| 端口 | 方向 | 位宽 |
|---|---|---|
| `ctrl_ir_pre_dis_inst{0,1,2}_vec` | input | 1 |
| `ctrl_ir_pre_dis_vec_create0_en/_sel` | input | 1 / 2 |
| `ctrl_ir_pre_dis_vec_create1_en/_sel` | input | 1 / 2 |
| `vecq_ctrl_1_left_updt` / `vecq_ctrl_full_updt` | input | 1 |
| `ctrl_vec_create0_en` / `ctrl_dp_is_dis_vec_create0_sel` | output | 1 / 2 |
| `ctrl_vec_create1_en` / `ctrl_dp_is_dis_vec_create1_sel` | output | 1 / 2 |
| `ctrl_dp_dis_inst{0,1,2}_vec` | output | 1 |

新增寄存器（与 `is_dis_aiq_*` 同款）：`is_dis_vec_create0/1_en/sel`、
`is_dis_vec_create0/1_en_updt`。在现有 `always_ff` 的 **reset / flush / stall /
update** 四个分支里同步更新（:264 起是 reset，:300 起 flush，:336 起 update，
:372 起 hold）。

修改：

```systemverilog
assign ctrl_vec_create0_en = is_dis_vec_create0_en && !ctrl_is_dis_stall;
assign ctrl_vec_create1_en = is_dis_vec_create1_en && !ctrl_is_dis_stall;

assign ctrl_is_vecq_full_updt =
          (is_dis_vec_create0_en_updt && vecq_ctrl_full_updt)
       || (is_dis_vec_create1_en_updt && vecq_ctrl_1_left_updt);

assign ctrl_is_iq_full_updt = (原有 6 项) || ctrl_is_vecq_full_updt;
```

`ctrl_is_dis_stall = ctrl_is_rob_full || ctrl_is_iq_full`（:574-580）自然覆盖；
不用再单独加一条 stall。

### 3.7 `ct_idu_is_dp.sv`

| 项 | 现状 | 改为 |
|---|---|---|
| `IS_WIDTH`（:129） | 76 | 79 |
| `IS_CTRL_WIDTH`（:316） | 7 | 9 |
| `dp_ir_inst*_data` 输入 | `[75:0]` | `[78:0]` |
| `dp_is_dis_inst*_data` 输出（:111-113） | `[75:0]` | `[78:0]` |
| 新增 `IS_VEC` / `IS_VEC_TYPE` | — | 76 / 78:77 |

新增端口（**create0 和 create1 都要有**，这是 v1 的遗漏）：

| 端口 | 方向 | 位宽 |
|---|---|---|
| `ctrl_dp_is_dis_vec_create0_sel` | input | 2 |
| `ctrl_dp_is_dis_vec_create1_sel` | input | 2 |
| `dp_vec_create0_data` / `dp_vec_create1_data` | output | 101 each |
| `dp_vec_create0_iid` / `dp_vec_create1_iid` | output | 7 each |
| `dp_ctrl_is_inst{0,1,2}_vec` | output | 1 each |

内部：`is_inst{0,1,2}_vec`、`is_inst{0,1,2}_vec_type[1:0]`、
`is_inst{0,1,2}_create_vec_data[100:0]`。

101 位打包（**顺序必须与 VIQ 参数完全一致**）：

```systemverilog
is_inst{k}_create_vec_data[100:69] = is_inst{k}_read_pc[31:0];
is_inst{k}_create_vec_data[68:37]  = is_inst{k}_read_data[IS_OPCODE +: 32];
is_inst{k}_create_vec_data[36:30]  = is_inst{k}_iid[6:0];
is_inst{k}_create_vec_data[29:28]  = is_inst{k}_vec_type[1:0];
is_inst{k}_create_vec_data[27:22]  = is_inst{k}_read_data[IS_DST_PREG +: 6];
is_inst{k}_create_vec_data[21:17]  = is_inst{k}_read_data[IS_DST_REG  +: 5];
is_inst{k}_create_vec_data[16]     = is_inst{k}_read_data[IS_DST_VLD];
is_inst{k}_create_vec_data[15:9]   = is_inst{k}_read_data[IS_SRC1_DATA +: 7];
is_inst{k}_create_vec_data[8:2]    = is_inst{k}_read_data[IS_SRC0_DATA +: 7];
is_inst{k}_create_vec_data[1]      = is_inst{k}_read_data[IS_SRC1_VLD];
is_inst{k}_create_vec_data[0]      = is_inst{k}_read_data[IS_SRC0_VLD];
```

按 `ctrl_dp_is_dis_vec_create0_sel` / `create1_sel` 做三选一 mux（照抄 AIQ 的
:446-500）。`iid` 直接取对应车道的 `is_inst{k}_iid`（:402-408）。

修改：

```systemverilog
assign dp_is_dis_inst{k}_chk = is_inst{k}_vec ? 25'd0 : is_inst{k}_read_chk;
```

向量指令没有分支预测快照，`chk` 必须清零。

`ct_idu_is_pipe_entry.sv` 同步：`IS_WIDTH` 76→79（:33）、`x_create_data` /
`x_read_data` `[75:0]`→`[78:0]`、新增 `IS_VEC/IS_VEC_TYPE` 参数。它被
`ct_idu_is_dp.sv` 例化三份，端口位宽跟随参数即可。

### 3.8 `ct_idu_top.sv`

- `parameter IS_WIDTH`（:1416）76→79；
- `logic [122:0] crtl_ir_inst2_data`（:381）→ `[125:0]`；
- 三个 `ct_idu_is_pipe_entry`、`ct_idu_ir_dp`、`ct_idu_ir_ctrl` 的端口位宽随参数；
- 本阶段不新增 VIQ。

### 3.9 S1 出口（只做这些）

```bash
make a910-elab
```

再加静态核对（贴进可以，写成脚本更好）：

```bash
grep -rn "IR_WIDTH *=" mySoC/idu_c910/rtl        # 只应剩 126（两处同名参数）
grep -rn "IS_WIDTH *=" mySoC/idu_c910/rtl        # 只应剩 79
grep -rn "IS_CTRL_WIDTH *=" mySoC/idu_c910/rtl   # 只应剩 9
grep -rn "\[122:0\]" mySoC/idu_c910/rtl          # 应为空
grep -rn "\[75:0\]"  mySoC/idu_c910/rtl          # 应为空
grep -rn "ctrl_ir_inst._aiq\|ctrl_ir_inst._lsiq" mySoC/idu_c910/rtl/ct_idu_ir_ctrl.sv
                                                 # 每一行都应含 !ctrl_ir_inst._vec
```

不跑 `a910-run`，不跑 `idu-unit`。

### 3.10 风险

- `IS_CTRL_WIDTH` 有 3 份副本（ir_dp/ir_ctrl/top），漏一个会静默错位。
- `IS_SRC1_DATA` 是 7 位 `{preg[5:0], wb}`，不是 6 位 preg；整段搬，别切位。
- `vsetivli` 误置 srcX_vld 会让它白等一个永远不 ready 的源。
- `ctrl_ir_pre_dis_3_vec_inst` 必须带 `_vld` 门控（参考 :366-383 的注释），
  否则无效车道的 X 会污染 `pipedown2`，整核一条都退休不了。

---

## 4. S2 —— VIQ 与 IS 派遣

> **2026-10-17 用户方案修订（并入本阶段执行）**
>
> 1. **vecq 明确为 4 深、2 写 / 1 读**：create0/create1 是两个写口，
>    `vecq_xx_issue_en` 是唯一读口。真正的 pop =
>    `vecq_xx_issue_en && rvv_vec_inst_ready`，所以 vecq 需要
>    `vecq_dp_issue_pop` 输入（由顶层把 issue_en 与 ready 相与后送回）。
> 2. **vecq 就是整条 RVV 通路的唯一指令缓冲**：bridge 不再加指令 FIFO；
>    `RvvFrontEnd` 的 N 槽 `inst_q/valid_inst_q` 退化为 **N=1** 的单级流水
>    寄存器（只承担"accept 后一拍 reg_read_data 对齐"的时序），不再承担
>    排队/容量管理；排队全部由 vecq 完成。
>    `rvv_backend` 里的 RVVCmd 命令队列**保留** —— 它解耦的是"已译码命令"
>    的发射，不是指令缓冲，与 vecq 不重复。
> 3. **RVV 解码流水线固定 1 条指令**：`RvvCore` 参数默认 `N=1`，
>    `rvv_backend_define.svh` 的 `ISSUE_LANE`/`INST_LANE` 4→1。
>    S3 的 bridge 端口随之从 4 lane 改为 1 lane：`core_inst_valid` 1 位、
>    `core_reg_read_valid/data` 各 2 位（src0/src1 各一条）。
> 4. 本阶段落地文件在 §4.2 的基础上额外包含 `mySoC/design/RvvCore.sv` 与
>    `mySoC/design/inc/rvv_backend_define.svh`；出口增加 `make rvv-elab`。
> 5. **就绪等待的归属（2026-10-17 二次修订）**：
>    - `vset*` 不进入后端（frontend 直接改 vl/vtype），仍由 vecq 的
>      `ct_idu_dep_reg_entry` 门控发射；
>    - 其余向量**计算**指令由 vecq **立即发射**（只看 valid + core 容量），
>      `src preg / vld / issue 时的 wb` 随指令进入 RvvCore，在
>      ALU/MUL/DIV/PMT 的保留站里等迟到写回；
>    - 向量 **LOAD/STORE** 的标量基址等待放在 **A910 LSIQ**（S7 anchor 自己的
>      dep entry），RVV 只把向量侧信息送到 LSIQ，不在 RVV 后端等。
>    - 因此 vecq 的发射条件改为：
>      `entry_vld && (head_is_vset ? entry_rdy : 1'b1)`。

### 4.1 目标

- 新增 4 深按序向量队列 `ct_idu_vecq`，规格固定为 **2 写（create0/create1）/
  1 读（head）**；
- **vecq 是 RVV 通路上唯一的指令缓冲**（取代 `RvvFrontEnd` 内部的指令槽），
  RVV 解码流水线固定 1 条（N=1）；
- IS 级把向量指令装进 VIQ，标量队列完全不受影响；
- VIQ head 的 src0/src1 preg 直接驱动 PRF 的 2 个新读口；
- 顶层暴露 `idu_vec_*` / `rvv_vec_inst_ready` 端口（ready 先钉 0）。

### 4.2 新文件

**`mySoC/idu_c910/rtl/ct_idu_vecq_entry.sv`**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `cpurst_b`, `forever_cpuclk`, `rtu_yy_xx_flush` | input | 1 |
| `iu_idu_ex2_pipe{0,1,2}_wb_preg_dupx` + `_vld_dupx` | input | 6 / 1 |
| `lsu_idu_wb_pipe3_wb_preg_dupx` + `_vld_dupx` | input | 6 / 1 |
| `rvv_idu_vset_wb_preg` + `_vld` | input | 6 / 1（第 5 路唤醒，S3 接） |
| `x_create_data` | input | 101 |
| `x_create_en` | input | 1 |
| `x_pop` | input | 1（本表项被真正发射/弹出） |
| `x_read_data` | output | 101 |
| `x_rdy`, `x_vld` | output | 1 |

内部：`vld`、`dst_preg[5:0]`、`opcode[31:0]`、`iid[6:0]`、`vec_type[1:0]`、
`src0_vld/src1_vld`、`dst_vld`、两个 `ct_idu_dep_reg_entry`。
`srcX_vld=0` 时源编码强制为 `7'b0000001`（preg0 + ready），保证立即就绪。

**`mySoC/idu_c910/rtl/ct_idu_vecq.sv`**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `vecq_ctrl_1_left_updt`, `vecq_ctrl_full_updt` | output | 1 |
| `vecq_xx_issue_en` | output | 1 |
| `vecq_dp_issue_data` | output | 101 |
| `cpurst_b`, `forever_cpuclk` | input | 1 |
| `vecq_dp_issue_pop` | input | 1（= issue_en && rvv_vec_inst_ready；唯一读口的 pop） |
| `ctrl_vec_create0_en` / `ctrl_vec_create1_en` | input | 1 |
| `dp_vec_create0_data/_iid` / `dp_vec_create1_data/_iid` | input | 101/7 each |
| `rtu_yy_xx_flush` | input | 1 |
| 三路 IU + LSU pipe3 写回 snoop | input | 同 entry |
| `rvv_idu_vset_wb_preg/vld` | input | 6/1 |
| `vecq_prf_rd_addr0/1` | output | 6 |
| `vecq_prf_rd_data0/1` | input | 32 |

规格：

- 4 项按序 FIFO（与 AIQ 同深），create0 较老、create1 较年轻；
- 每拍最多装 2 条、发射 1 条；
- `vecq_xx_issue_en = head_vld && (!head_is_vset || head_rdy)`（2026-10-17
  S3b 修订：**只有 vset\* 在 vecq 里等源 ready**；非 vset 计算类立即发射、
  在 core 的 ALU/MUL/DIV/PMT RS 里等，向量 L/S 在 LSIQ 里等）；顶层再与
  `rvv_vec_inst_ready` 相与后 pop（本阶段 ready 钉 0，所以实际不会 pop）；
- head 的 `VIQ_SRC0_DATA[6:1]` / `VIQ_SRC1_DATA[6:1]` 驱动 PRF 两个新读口；
  `srcX_vld=0` 时读地址接 0，读值丢弃；
- `rtu_yy_xx_flush` 清空全部表项（与 AIQ 一致）。

**字段定义（唯一定义：`mySoC/idu_c910/rtl/ct_idu_vecq_defs.svh`，
由 `ct_idu_vecq.sv` 与 `ct_idu_vecq_entry.sv` 共同 include）**

```systemverilog
`define VIQ_WIDTH      101
`define VIQ_PC         100   // [100:69]
`define VIQ_OPCODE     68    // [68:37] 完整 32 位指令字
`define VIQ_IID        36    // [36:30]
`define VIQ_VEC_TYPE   29    // [29:28]
`define VIQ_DST_PREG   27    // [27:22]
`define VIQ_DST_REG    21    // [21:17]
`define VIQ_DST_VLD    16
`define VIQ_SRC1_DATA  15    // [15:9] = {preg[5:0], wb}
`define VIQ_SRC0_DATA  8     // [8:2]
`define VIQ_SRC1_VLD   1
`define VIQ_SRC0_VLD   0
```

> 用宏而不是 module parameter：VCS 默认把多个源文件当同一编译单元，
> 带 `ifndef` 的 parameter 头在第二个模块里会被 guard 跳过 ⇒ 参数未声明。
> 宏带 guard 则是全局可见的，正好适合"单一来源"。

### 4.3 PRF 两个读口（本阶段就加）

`ct_idu_rf_prf_pregfile.sv`：

| 端口 | 方向 | 位宽 |
|---|---|---|
| `dp_prf_rf_vec_src0_preg` / `dp_prf_rf_vec_src1_preg` | input | 6 |
| `prf_dp_rf_vec_src0_data` / `prf_dp_rf_vec_src1_data` | output | 32 |

内部：

```systemverilog
assign prf_dp_rf_vec_src0_data = preg_reg_dout[dp_prf_rf_vec_src0_preg];
assign prf_dp_rf_vec_src1_data = preg_reg_dout[dp_prf_rf_vec_src1_preg];
```

### 4.4 `ct_idu_top.sv`

- 例化 `u_ct_idu_vecq`；
- 连 create0/create1（来自 is_ctrl/is_dp）、写回 snoop、flush；
- PRF 两个读口由 VIQ head 驱动；
- 新增顶层端口：

```systemverilog
output logic        idu_vec_inst_valid;
output logic [6:0]  idu_vec_inst_iid;
output logic [31:0] idu_vec_inst_pc;
output logic [1:0]  idu_vec_inst_opcode;
output logic [24:0] idu_vec_inst_bits;
output logic        idu_vec_src0_vld;
output logic [31:0] idu_vec_src0_data;
output logic        idu_vec_src1_vld;
output logic [31:0] idu_vec_src1_data;
output logic [5:0]  idu_vec_dst_preg;
output logic        idu_vec_dst_vld;
output logic [4:0]  idu_vec_dst_reg;
input  logic        rvv_vec_inst_ready;
input  logic        rvv_idu_vset_wb_vld;
input  logic [5:0]  rvv_idu_vset_wb_preg;
input  logic [31:0] rvv_idu_vset_wb_data;
input  logic [6:0]  rvv_idu_vset_wb_iid;
```

- `idu_vec_inst_opcode` 的映射：
  `2'b01(LOAD)→0`、`2'b10(STORE)→1`、`2'b11(RVV)→2`；
- `idu_vec_inst_bits = VIQ_OPCODE[31:7]`；
- `idu_vec_inst_pc` 取 VIQ pc 字段。

### 4.5 `A910_cpu.sv`

- `ct_idu_top` 例化（:1084）补上上述 17 个端口（12 出 + 5 入）；
- 本阶段 `rvv_vec_inst_ready` 钉 `1'b0`（bridge 还没接），
  `rvv_idu_vset_wb_*` 钉 0；
- 不删 TB 的 force（本阶段不仿真，S9 统一删）。

### 4.6 S2 出口

```bash
make rvv-elab && make a910-elab
```

静态核对：

```bash
grep -n "VIQ_" mySoC/idu_c910/rtl/ct_idu_vecq_defs.svh    # 11 个字段，位段无重叠
grep -n "dp_vec_create" mySoC/idu_c910/rtl/ct_idu_top.sv  # create0/1 都接了
grep -n "vecq_dp_issue_pop\|vecq_xx_issue_en" mySoC/idu_c910/rtl/ct_idu_vecq.sv
                                                          # pop 是唯一读口的使能
grep -n "parameter N" mySoC/design/RvvCore.sv             # 必须是 1
grep -n "ISSUE_LANE\|INST_LANE" mySoC/design/inc/rvv_backend_define.svh  # 必须是 1
```

不跑 `idu-unit`。

### 4.7 风险

- **create1 漏定义**（v1 的 §3.6/§3.8 就漏了）：如果只做 create0，两条向量
  一起到 IS 时第二条会丢；本计划要求 create0/1 同时落地。
- VIQ 的 101 位字段顺序必须和 is_dp 的打包顺序逐位对应，错一位就是静默错值。
- VIQ 满判据要汇进 `ctrl_is_iq_full_updt`，否则队列满了还在 create。

---

## 5. S3 —— PRF 写口、vset 唤醒、bridge 骨架、顶层接通

### 5.1 目标

- vset* 的 rd 能以第 5 个写口写进 PRF；
- 所有依赖表项都能被 vset 写回唤醒；
- `rvv_a910_bridge` 落地并例化，指令入口/操作数/`inst_ready` 接通；
- vset 完成脉冲（`cmplt_vld2`）接进 RTU；
- 暂时不做完成链、提交门控、flush（S4），trap（S5），LSU（S8）。

### 5.2 `ct_idu_rf_prf_pregfile.sv` / `ct_idu_rf_prf_gated_preg.sv`

新增写口：

| 端口 | 方向 | 位宽 |
|---|---|---|
| `rvv_vset_wb_preg_data` | input | 32 |
| `rvv_vset_wb_preg_vld` | input | 1 |
| `rvv_vset_wb_preg_addr` | input | 6 |

`ct_idu_rf_prf_pregfile.sv`：

```systemverilog
logic [63:0] vset_wb_vld;
assign vset_wb_vld = {64{rvv_vset_wb_preg_vld}} & (64'd1 << rvv_vset_wb_preg_addr);
```

- `preg_wb_vld` 位宽 `[4:0]` → `[5:0]`（:90）；
- `preg_wb_vld[0] = 6'b000000`（:142）；
- 拼接（:147）：

```systemverilog
assign preg_wb_vld[j] = {vset_wb_vld[j],
                         csr_rd_wb_vld[j], pipe3_wb_vld[j],
                         pipe2_wb_vld[j], pipe1_wb_vld[j], pipe0_wb_vld[j]};
```

`ct_idu_rf_prf_gated_preg.sv`：

- `x_wb_vld` `[4:0]` → `[5:0]`（:13）；
- `unique case` 加第 6 分支（:28-35）：

```systemverilog
6'b100000 : write_data = rvv_vset_wb_preg_data;
```

> 位序是"第 0 位 = pipe0、第 4 位 = CSR、第 5 位 = vset"；不要插在中间，
> 否则 `preg_wb_vld` 与 case 分支的对应关系会错。

### 5.3 `ct_idu_dep_reg_entry.sv` 及全族透传

`ct_idu_dep_reg_entry.sv` 新增端口：

| 端口 | 方向 | 位宽 |
|---|---|---|
| `rvv_idu_vset_wb_preg_dupx` | input | 6 |
| `rvv_idu_vset_wb_preg_vld_dupx` | input | 1 |

内部：

```systemverilog
logic vset_wb;
assign vset_wb = rvv_idu_vset_wb_preg_vld_dupx &&
                 (rvv_idu_vset_wb_preg_dupx[5:0] == preg[5:0]);
assign write_back = wb || pipe0_wb || pipe1_wb || pipe2_wb || pipe3_wb || vset_wb;
```

**所有使用它的模块都要加这两个端口并透传**（漏一个 = 该队列的消费者永远
不 ready）：

```text
ct_idu_is_pipe_entry.sv
ct_idu_is_aiq_entry.sv      ct_idu_is_aiq.sv
ct_idu_is_biq_entry.sv      ct_idu_is_biq.sv
ct_idu_is_lsiq_entry.sv     ct_idu_is_lsiq.sv
ct_idu_is_sdiq_entry.sv     ct_idu_is_sdiq.sv
ct_idu_is_md_entry.sv       ct_idu_is_md.sv（例化两份）
ct_idu_ir_rt.sv             （改名表 32 项，v1 漏列；不接 ⇒ vset 的 rd 在改名表里永不 ready）
ct_idu_vecq_entry.sv        （S2 新建，直接带）
```

> `ct_idu_dep_reg_src2_entry.sv` 如果当前没有被任何队列例化，就不用改；
> 动手前先 `grep -rn ct_idu_dep_reg_src2_entry mySoC/idu_c910/rtl` 确认。

`ct_idu_top` 负责把 `rvv_idu_vset_wb_vld` / `rvv_idu_vset_wb_preg` 扇出到
AIQ、BIQ、LSIQ、SDIQ、MD×2、IS pipe、IR 改名表、VIQ 共 **9 个例化**（再逐级
透传到每个 dep entry）。**不能只接到 PRF 写口**——那样 vset 的消费者永远不 ready。

### 5.4 新文件 `mySoC/rvv_a910_bridge.sv`

端口一次定义完（**包括 S5 的 trap 和 S8 的 LSU**，后面阶段只填内部逻辑）：

```systemverilog
// 时钟/复位
input  wire        clk;
input  wire        rst;              // 高有效；内部取反送 core.rstn

// 指令入口（IDU VIQ head，1 条/拍）
input  wire        idu_vec_inst_valid;
input  wire [6:0]  idu_vec_inst_iid;
input  wire [31:0] idu_vec_inst_pc;
input  wire [1:0]  idu_vec_inst_opcode;   // 0=LOAD 1=STORE 2=RVV
input  wire [24:0] idu_vec_inst_bits;
input  wire        idu_vec_src0_vld;
input  wire [31:0] idu_vec_src0_data;
input  wire        idu_vec_src1_vld;
input  wire [31:0] idu_vec_src1_data;
input  wire [5:0]  idu_vec_dst_preg;
input  wire        idu_vec_dst_vld;
input  wire [4:0]  idu_vec_dst_reg;
output wire        rvv_vec_inst_ready;

// vset 写回
output wire        rvv_idu_vset_wb_vld;
output wire [5:0]  rvv_idu_vset_wb_preg;
output wire [31:0] rvv_idu_vset_wb_data;
output wire [6:0]  rvv_idu_vset_wb_iid;

// RTU
output wire        cmplt_vld1;
output wire [6:0]  cmplt_iid1;
output wire        cmplt_vld2;
output wire [6:0]  cmplt_iid2;
input  wire        rtu_commit0, rtu_commit1, rtu_commit2;
input  wire [6:0]  rtu_commit_iid0, rtu_commit_iid1, rtu_commit_iid2;
input  wire        rtu_flush;

// 异常（S5 实现）
output wire        rvv_expt_vld;
output wire [6:0]  rvv_expt_iid;
output wire [4:0]  rvv_expt_cause;   // 恒 5'd2
output wire [31:0] rvv_expt_tval;

// 状态/调试
output wire        rvv_idle;
output wire        rvv_trap_valid;
output wire [31:0] rvv_trap_inst;

// 向量 LSU（S8 接）
output wire        rvv_lsu_uop_valid;
output wire UOP_RVV2LSU_t rvv_lsu_uop;
input  wire        rvv_lsu_uop_ready;
input  wire        rvv_lsu_resp_valid;
input  wire UOP_LSU2RVV_t rvv_lsu_resp;
output wire        rvv_lsu_resp_ready;
```

内部本阶段只实现：

| 信号 | 实现 |
|---|---|
| `core_inst_valid[0:0]` | = `idu_vec_inst_valid`（N=1，只有一条指令/拍） |
| `core_inst_data[0]` | `.rob_tag=.iid`、`.pc`、`.opcode`、`.bits` |
| `core_inst_ready[0]` | → `rvv_vec_inst_ready` |
| `core_reg_read_valid[1:0]` | `{src1_vld, src0_vld}`（N=1，2 条源） |
| `core_reg_read_data[1:0]` | `{src1_data, src0_data}` |
| `acc_iid[6:0]` / `acc_src*` | accept 后一拍影子（只服务 `reg_read_data` 的时序） |
| `vset_wb_fifo` | 4 深，push `{iid,dst_preg,dst_vld}` on accept if vset；pop 于 `reg_write_valid[0]`；`rtu_flush` 时清空 |
| `vxsat_q` | 本阶段恒 0（S4 接） |
| `core_flush` | 本阶段恒 0（S4 接） |
| `cmplt_vld1` | 本阶段恒 0（S4 接） |
| `cmplt_vld2/iid2` | `reg_write_valid[0]` + FIFO 头 iid |
| `rvv_idu_vset_wb_*` | `reg_write_valid[0]` 时输出 FIFO 头的 preg + `reg_write_data[0]`；`dst_vld=0` 时不写 PRF（但仍发 cmplt） |

关键时序（必须按 `RvvFrontEnd.sv:183-243`）：

- `reg_read_valid/data` 在 **accept 后一整拍**仍要对应刚收下的指令；
  用 `acc_src0_data/acc_src1_data` 保持即可；
- vset 的识别（bridge 只有 `opcode[1:0]` + `bits[24:0]`）：

```systemverilog
wire is_vset = (idu_vec_inst_opcode == 2'd2) &&      // OP-V
               (idu_vec_inst_bits[7:5] == 3'b111);   // funct3 == 111
```

- `reg_write_valid_o[0]` 是 frontend 处理 vset 的脉冲；**不能**用"accept 后
  一拍"的影子去配 iid，因为 core 可以连续收多条指令，vset 的完成可能晚几拍。
  必须用按 accept 顺序排的 **vset FIFO**；`rd=x0` 的 vset 也照常入 FIFO
  （要发 cmplt），但 `dst_vld=0` 时不做 PRF 写。

### 5.5 `RvvFrontEnd.sv`

1. 新增输出：

```systemverilog
output RVVConfigState [N-1:0] cmd_config_state_o;
assign cmd_config_state_o[i] = inst_config_state[i+1];
```

2. 新增输入（S4 使用，本阶段先接 0）：

```systemverilog
input logic                    config_load_valid_i;
input RVVConfigState           config_load_data_i;
```

3. **修 rs1 选择**（:605-611）。当前向量 L/S 的 `bits[7]`（funct3[2]）常为 0，
   导致基址恒 0：

```systemverilog
unaligned_cmd_data[i].rs1 =
    (inst_q[i].opcode != RVV) ? reg_read_data_i[2*i] :
    inst_q[i].bits[7] ? (...) : 0;
```

4. **新增 rs2 通道**（strided 的步长）。`RVVCmd` 现在只有 `rs1`：

```systemverilog
unaligned_cmd_data[i].rs2       = ((inst_q[i].opcode != RVV) &&
                                   (inst_q[i].bits[20:19] == 2'b10))
                                  ? reg_read_data_i[2*i+1] : '0;
unaligned_cmd_data[i].rs2_valid = (inst_q[i].opcode != RVV) &&
                                  (inst_q[i].bits[20:19] == 2'b10) &&
                                  reg_read_valid_i[2*i+1];
```

> `bits[20:19]` 对应 `inst[27:26]`（mop），`2'b10` = strided。
> `RVVCmd` / `UOP_QUEUE_t` / `UOP_RVV2LSU_t` 的 `rs2` 字段在 S6 一起加；
> 本阶段先把 `RVVCmd` 的字段加上，避免 S6 再改接口。

### 5.6 `RvvCore.sv`

本阶段只加"bridge 需要、但内部暂时不接"的端口，并接到 frontend：

| 端口 | 方向 | 位宽 | 本阶段处理 |
|---|---|---|---|
| `cmd_config_state_o` | output | `RVVConfigState [N-1:0]` | 接 `RvvFrontEnd` 新输出 |
| `config_load_valid_i` | input | 1 | 接 frontend，数据先 0 |
| `config_load_data_i` | input | `RVVConfigState` | 接 frontend，先 0 |
| `cmt_wmk_valid_i` | input | 1 | 悬空（S4 接 backend） |
| `cmt_wmk_iid_i` | input | 7 | 悬空（S4） |
| `inst_cmplt_valid_o` | output | 1 | 先钉 0（S4） |
| `inst_cmplt_iid_o` | output | 7 | 先钉 0（S4） |
| `rob_head_rob_tag_o` | output | 7 | 先钉 0（S4） |
| `rob_head_valid_o` | output | 1 | 先钉 0（S4） |

`vxsat` / `flush` 继续接 0（S4/S5 再改）。

### 5.6a 标量写回直通与 RS 等待（S3b，2026-10-17 二次修订）

- `RvvCore` 新增 **5 路标量写回输入** `{vld, preg[5:0], data[31:0]}`：
  IU pipe0/1/2、LSU pipe3、vset（bridge 自己的 `rvv_idu_vset_wb_*`）。
- `RvvFrontEnd` 在 accept 时把源信息写进 backend 的 **按 A910 iid 索引的等待表**
  （`src0_wt_*` / `src1_wt_*`）：
  `{preg, captured = issue 时的 wb, data = accept 当拍的 PRF 组合读值}`。
  `data` 必须用 bridge 的 `idu_vec_src*_data`（accept 当拍），**不能**用
  frontend 的 `reg_read_data_i` —— 那是 accept 后一拍的影子。
- `rvv_backend` 为每个源维护 128 项（7 位 iid 直接索引）表项：
  - WB 命中且该表项尚未 captured ⇒ 写入 WB 数据并置 captured。
    只认该指令 issue 后的**第一次** WB，preg 复用不会串到下一个生产者；
  - 用"按 preg 的全局最新值 + re-arm"在 preg 复用时是不安全的，故按 iid 分开存；
  - accept 同拍就有 WB 命中时（`src*_wt_hit`），新表项直接记为 captured。
- `ALU_RS_t / MUL_RS_t / DIV_RS_t / PMT_RDT_RS_t` 增加
  `rs1_preg/rs1_iid/rs1_vld`；发车条件加
  `!rs1_vld || src0_wt_tbl[rs1_iid].captured`；x-form 的 `vs1_data[31:0]`
  （PMT 的 `rs1_data`）发车时用 `src0_wt_tbl[rs1_iid].data` 修正。
- 多 lane RS 保持 in-order：lane i 的 valid 要求 0..i 都 ready。
- `vset*` 仍由 vecq 的 dep entry 门控（它不进入后端）。
- 向量 L/S 不在这里等：见 S7 的 LSIQ anchor（其自身的 dep entry 等基址），
  RVV 只提供向量侧信息。

### 5.7 `A910_cpu.sv`

- 新增 wire 与 bridge 例化（放在 IDU 之后、RTU 之前）；
- `ct_idu_top` 的 12 个 `idu_vec_*` 输出 / 4 个 `rvv_idu_vset_wb_*` 输入接上；
- `cmplt_vld2/cmplt_iid2` 接 RTU（:1860-1863）；
- `preg_wb_mask`（:1789）OR 上 vset 写口：

```systemverilog
wire [63:0] vset_wb_mask =
    {64{rvv_idu_vset_wb_vld}} & (64'd1 << rvv_idu_vset_wb_preg);
assign preg_wb_mask = (原有各项) | vset_wb_mask;
```

- `rtu_yy_xx_commit{0,1,2}` + `_iid`（:470-475）同时送 bridge；
- `rtu_yy_xx_flush` 同时送 bridge；
- **TB 的 force 本阶段不删**（不仿真，S9 统一删）。

### 5.8 S3 出口

```bash
make a910-elab
```

静态核对：

```bash
grep -rn "ct_idu_dep_reg_entry" mySoC/idu_c910/rtl | wc -l   # 与改后端口数一致
grep -rn "rvv_idu_vset_wb_preg_vld_dupx" mySoC/idu_c910/rtl  # 每个 entry 例化都有
grep -n "preg_wb_vld\[0\]" mySoC/idu_c910/rtl/ct_idu_rf_prf_pregfile.sv
                                                             # 必须是 6'b0
```

不跑 `a910-run`，不跑 `a910-difftest-all`。

### 5.9 风险

- 漏一个队列的 vset 唤醒 ⇒ 该队列消费者永远不 ready（症状像死锁，但只在
  vset 之后出现）。
- `preg_wb_mask` 漏 OR ⇒ RTU 的 preg 永远等不到写回事件，静默永久出池。
- vset 的 rd 写是**推测写**；flush 后由 RTU 映射恢复丢弃，允许。
- vset FIFO 溢出：按 2026-10-17 修订，RvvFrontEnd 退化为 **N=1 的单级流水
  寄存器**（不再有 16 条容量），排队全部在 VIQ（4 深）⇒ 最多 4 条在飞；
  若改成更深 VIQ，vset FIFO 深度要跟着加。

---

## 6. S4 —— 完成、提交门控、flush、配置恢复

### 6.1 目标

- core 的 ROB 在"一条指令的所有 uop 都 done"时发一次完成脉冲（`cmplt_vld1`）；
- A910 未提交的 core 表项**不 pop**，VRF 写只发生在提交之后；
- `rtu_yy_xx_flush` 到达时先排空已提交前缀，再全局清 core；
- `vxsat` 回存、vtype/vl 配置在 flush 后能恢复到已提交值。

### 6.2 `rvv_backend_rob.sv`

新增端口：

| 端口 | 方向 | 位宽 |
|---|---|---|
| `cmt_wmk_valid` | input | 1 |
| `cmt_wmk_iid` | input | 7 |
| `inst_cmplt_valid` | output | 1 |
| `inst_cmplt_rob_tag` | output | 7 |
| `rob_head_rob_tag` | output | 7 |
| `rob_head_valid` | output | 1 |

内部：

```systemverilog
logic [ROB_DEPTH-1:0] uop_cmplt_sent;
logic [ROB_DEPTH-1:0] inst_done_chain;
logic [ROB_DEPTH-1:0] entry_committed;
```

**完成链（务必按 ROB 头为基、按槽位回绕，v1 的 `i-1` 写法不对）**：

```systemverilog
// i_prev 是物理前一个槽；chain 在 ROB 头（uop_rptr）重新起头。
// 已弹出的前缀一定已经 done，所以以 uop_done[rptr] 起头是正确的。
always_comb begin
  for (int i = 0; i < `ROB_DEPTH; i++) begin
    automatic int i_prev = (i == 0) ? `ROB_DEPTH-1 : i-1;
    if (i == uop_rptr)
      inst_done_chain[i] = uop_done[i];
    else
      inst_done_chain[i] = uop_done[i] &&
                           (alluop_info[i_prev].last_uop_valid ||
                            inst_done_chain[i_prev]);
  end
end

wire [`ROB_DEPTH-1:0] alluop_last;
for (genvar i = 0; i < `ROB_DEPTH; i++)
  assign alluop_last[i] = alluop_info[i].last_uop_valid;
// ⚠️ 必须带 entry_valid：ROB 槽位在 rptr..wptr 之外是**上次的残留值**，
//    不加这个掩码会从已弹出的槽里发出幽灵完成脉冲。
// ⚠️ 必须带 ~trap_flag：trap 表项由异常路径负责，不能再发 cmplt，
//    否则 A910 会和异常竞争。
assign inst_cmplt_valid = |(inst_done_chain & alluop_last & entry_valid &
                             ~trap_flag & ~uop_cmplt_sent);
// 从 ROB 头方向选一条，输出其 rob_tag
```

`uop_cmplt_sent`：

- uop 被 push 进 ROB 时清 0（或 pop 时清 0，二者都做最稳）；
- `inst_cmplt_valid` 命中该槽时置 1；
- `trap_flush_rvv` 时全清。

**提交门控（门控 `rd_valid_rob2rt`，不能只门控 FIFO 的 pop）**：

v1 说"pop 被门控后 VRF 写自然被门控"，**不成立**。retire 级
（`rvv_backend_retire.sv:172-180`）是直接看 `rob2rt_write_valid`
（= `rd_valid_rob2rt`）和 `rt2rob_write_ready`（= `rd_ready_rt2rob`）写 VRF；
ROB 内部 uop FIFO 的 `pop` 只是另一条旁路。只门控 pop，VRF 照样会被推测写。
正确做法是把**送给 retire 级的 valid 本身**门控住：

```systemverilog
assign entry_committed[i] = cmt_wmk_valid &&
                            (alluop_info[i].rob_tag == cmt_wmk_iid ||
                             iid_older(alluop_info[i].rob_tag, cmt_wmk_iid));

// raw_valid[k] = 原来的 rd_valid_rob2rt（含 uop_done 与前缀链）
assign rd_valid_rob2rt[k] = raw_valid[k] &
        (entry_committed[wind_uop_rptr[k]] | trap_flag[wind_uop_rptr[k]]);
```

- trap 表项放行：`w_valid_chkTrap` 已经保证 `trap_flag=1` 时不写 VRF，
  而且核心自己的 trap 冲刷需要它流到 retire 级；不放行会卡住 core 的 trap。
- ROB 内部 FIFO 的 pop 继续用 `rd_valid_rob2rt & rd_ready_rt2rob`，
  **不要再额外加门控**。

`iid_older(a,b)` 完全照 `RTU_iid_cmp.v:28-61` 的规则（回绕位相同比低 6 位；
回绕位不同时低 6 位大的属于上一圈）。只用于退休门控慢路径。

`rob_head_valid = entry_valid[uop_rptr]`；
`rob_head_rob_tag = alluop_info[uop_rptr].rob_tag`。

> 为什么"完成"必须早于"提交"：cmplt 用来让 A910 退休；如果 cmplt 等提交，
> A910 等 cmplt，互相等 ⇒ 死锁。pop/VRF 写才是等提交的那一半。

### 6.3 `rvv_backend.sv`

把 6 个新端口从顶层透传到 `u_rob`，并在 `rd_valid_rob2rt_o`/`rd_rob2rt_o`
之外新增完成脉冲输出。注意 `de2rt` 的 retire 输出在
`rd_valid_rob2rt_o[`NUM_RT_UOP +: `NUM_DE_INST]`（高位），S5 会用它做 trap
兜底。

### 6.4 `RvvCore.sv`

- 把 S3 预留的 6 个端口接到 backend；
- `vxsat` 改由 bridge 的 `vxsat_q` 驱动；
- `flush` 改由 bridge 的 `core_flush` 驱动。

### 6.5 bridge 内部（S4 新增）

| 信号 | 位宽 | 逻辑 |
|---|---|---|
| `cmt_wmk_valid` | 1 | 任一 commit 有效 |
| `cmt_wmk_iid` | 7 | 取当拍**最年轻**的提交：`commit2 ? iid2 : commit1 ? iid1 : iid0` |
| `flush_pending` | 1 | `rtu_flush` 置位；`core_flush` 后清 |
| `flush_drain_cnt[2:0]` | 3 | 等 ROB 头未提交 + 2~3 拍 VRF 流水 |
| `core_flush` | 1 | 收敛后单拍脉冲 |
| `cmplt_vld1/iid1` | 1/7 | `inst_cmplt_valid/rob_tag` |
| `vxsat_q` | 1 | `wr_vxsat_valid_o` 时更新，接回 `vxsat` |
| `vset_cfg_fifo` | 4 深 | vset 完成时 push `{iid, post_state}` |
| `committed_cfg` | `RVVConfigState` | 该 iid 提交时更新 |

flush 收敛（与 v1 相同，但顺序写死）：

1. `rtu_flush` 到达：立刻 `inst_valid[0]=0`，清 VIQ（IDU 侧自己清），
   `flush_pending=1`；
2. **不要立刻**拉 `core_flush`；等 `!rob_head_valid ||
   !iid_committed(rob_head_rob_tag)`（core 的 ROB 头已经全是未提交项）；
3. 再等 2~3 拍（`flush_drain_cnt`），让 retire→VRF 最后一级流完；
4. 拉一拍 `core_flush`，同拍把 `config_load_valid=1`、
   `config_load_data=committed_cfg` 送 frontend；
5. 清 `flush_pending`。

> `rtu_yy_xx_commit*_iid` 是**寄存器输出**（`RTU.v:933-935`，比 dbg 晚一拍），
> 水位逻辑用它，别用 `dbg_commit_*`。
> `rtu_flush` 与 `core_flush` 不是同一根：前者是 A910 的冲刷起点，后者是
> 收敛后给 core 的全局清空。

### 6.6 S4 出口

```bash
make a910-elab
```

静态核对：

```bash
grep -n "rd_valid_rob2rt" mySoC/design/rvv_backend_rob.sv
# 输出给 retire 级的 valid 必须带 entry_committed[...] | trap_flag[...]
grep -n "uop_cmplt_sent" mySoC/design/rvv_backend_rob.sv
# set / pop 清 / trap_flush 清 三处都要有
```

不跑仿真。

### 6.7 风险

- 完成链如果不用 `uop_rptr` 起头，槽位回绕后会变成全 0，core 永不 cmplt。
- `inst_cmplt_valid` 不按 `entry_valid` 掩码 ⇒ 会从已弹出的残留槽发出幽灵完成。
- `inst_cmplt_valid` 不排除 `trap_flag` ⇒ trap 指令同时收到 cmplt 与异常，
  A910 的退休/异常通路会竞争。
- `uop_cmplt_sent` 只在 set 时置、不在 pop/flush 清，重用槽位会吞掉新指令的完成。
- `rd_valid_rob2rt` 门控漏掉某个 `wind_uop_rptr[k]`，会出现"部分 uop 已退休、
  部分没退休"，ROB 指针错乱。
- 只门控 FIFO 的 pop、不门控送给 retire 级的 valid ⇒ **VRF 仍会被推测写**。
- flush 直接全局清 core 会把已提交但尚未 pop 的表项的 VRF 写冲掉；必须等
  水位收敛。

---

## 7. S5 —— 计算类闭环与异常出口

### 7.1 目标

- `vset*`、ALU/MULMAC/PMTRDT/mask 全链路可完成、可提交；
- 不支持的向量指令**不会静默退休**，而是通过 A910 的异常口报 illegal；
- 三个保留站改名为 vaiq/vmacq/vpq（只改实例名/注释，功能不动）。

### 7.2 队列改名

`rvv_backend.sv`：

| 现实例名 | 行 | 改为 |
|---|---|---|
| `u_alu_rs` | :606 | `u_vaiq` |
| `u_mul_rs` | :678 | `u_vmacq` |
| `u_pmtrdt_rs` | :642 | `u_vpq` |

深度保持 `ALU_RS_DEPTH=4 / MUL_RS_DEPTH=4 / PMTRDT_RS_DEPTH=8`。本阶段不改
任何队列逻辑。

### 7.3 异常出口（这是 v1 最大的漏洞，必须按本节做）

**事实核查**：

- `RvvCore.trap_valid_o` / `trap_data_o` 只来自 **frontend** 的
  `unaligned_trap_valid`（`RvvFrontEnd.sv:645-660`），只覆盖 `vill`；
- 后端 `rvv_backend_decode.sv` 对**解不出的指令**走 `de2rt`：产生一条
  `w_valid=0 / trap_flag=0` 的假退休记录（:54-69），**不会**出现在
  `trap_valid_o` 上，也不会进内部 ROB；
- A910 的 ID 级 `illegal=1` **不会**产生异常：`IU_alu_pipe.v:161` 只是
  `ex2_wr <= idu_sel & ~idu_illegal`，即静默丢弃；
- `de2rt` 的退休记录在 `rd_valid_rob2rt_o[`NUM_RT_UOP +: `NUM_DE_INST]`，
  因此 bridge 是唯一能看见它的地方。

**设计顺序：入口过滤优先，退休监视只做兜底。**

原因：如果让 `vmv.x.s / vfirst.m / vcpop.m` 进 core，它们会正常完成并触发
`cmplt_vld1`；A910 可能先提交、后收到异常，异常就丢了。所以这三条必须在
**accept 时**就被 bridge 拦下，根本不进 core。

**F0 —— 入口过滤（主通路）**

```systemverilog
// bits = inst[31:7]
wire is_vwrxn = (idu_vec_inst_opcode == 2'd2) &&           // OP-V
                (idu_vec_inst_bits[7:5] == 3'b010) &&      // funct3 = OPMVV
                (idu_vec_inst_bits[24:19] == 6'b010000);   // funct6 = VWRXUNARY0
wire is_vmv_x_s = is_vwrxn && (idu_vec_inst_bits[12:8] == 5'b00000); // VMV_X_S
wire is_vcpop   = is_vwrxn && (idu_vec_inst_bits[12:8] == 5'b10000); // VCPOP
wire is_vfirst  = is_vwrxn && (idu_vec_inst_bits[12:8] == 5'b10001); // VFIRST
wire is_scalar_dest = is_vmv_x_s | is_vcpop | is_vfirst;
```

- 命中时：**不送 core**、`rvv_vec_inst_ready=1` 让 VIQ 正常 pop，同时把
  `{iid, inst, cause=2}` 推进 bridge 的异常队列；
- 该指令在 A910 ROB 里的表项由 RTU 异常机制冲刷，不需要 cmplt；
- 不管 `vm` 是否为 1 都拦，否则非法编码会落进 core 的奇怪分支。

```systemverilog
assign core_inst_valid[0] = idu_vec_inst_valid && !is_scalar_dest;
assign rvv_vec_inst_ready = is_scalar_dest ? 1'b1 : core_inst_ready[0];
```

**F1/F2/F3 —— 退休监视（兜底，正常不应触发）**

| 源 | 判据 | iid 来源 | tval |
|---|---|---|---|
| F1 后端解不出 | `rd_valid_rob2rt_o[NUM_RT_UOP + i]` | `rd_rob2rt_o[NUM_RT_UOP + i].rob_tag` | 该 iid 的指令字 |
| F2 标量写回漏网 | `rd_valid_rob2rt_o[0] && async_rd_valid` | `rd_rob2rt_o[0].rob_tag` | 同上 |
| F3 frontend vill | `trap_valid_o` | `trap_data_o.rob_tag` | `{trap_data_o.bits, 7'b1010111}` |

- F1：core 解不出的指令不会进内部 ROB，不会产生 cmplt，直接报异常即可。
  注意 `de2rt_valid[i] = inst_valid[i] & !lcmd_valid[i]` 可能**连续多拍为 1**
  （上游 valid 未撤），必须按 iid 去重：已在异常队列/已报过的不再入队，
  否则同一条指令会被 trap 多次；
- F2：如果 F0 解码条件写错，这条能兜住。**同时必须用同一个
  `is_scalar_dest` 判据把该 iid 的 `inst_cmplt_valid` 闸掉**，防止
  "先 cmplt 后异常"；
- F3：vset/vill 不进后端，天然没有 cmplt。

**必做的配套**：

1. bridge 维护一张按 iid 索引的 `accepted_inst[128]`（直接映射，
   `{valid, inst[31:0]}`），accept 时写入，**cmplt / trap / flush 时清除**；
   F1/F2/F3 用 iid 查表拿 tval。128 项足够：A910 in-flight 窗口远小于 128。
   注意 bridge 只收到 `bits[24:0]`（= inst[31:7]）和 2 位类别，必须自己补回
   低 7 位 opcode：

```systemverilog
wire [6:0] opcode7 = (idu_vec_inst_opcode == 2'd0) ? 7'b0000111 :
                     (idu_vec_inst_opcode == 2'd1) ? 7'b0100111 :
                                                     7'b1010111;
// accept 时
accepted_inst[iid].inst = {idu_vec_inst_bits, opcode7};
```
2. 三种源同拍最多各一条；用 `iid_older` 做一次锦标赛，取最老的一条输出到
   `rvv_expt_*`，其余保持 pending（或直接丢弃更年轻的——更老的那条 trap 后
   A910 会冲刷，更年轻的本来也要被冲掉）。**不要**同时丢两条独立异常。
3. `rvv_expt_cause` 恒 `5'd2`（illegal instruction）。
4. `cmplt_vld1` 的门控：

```systemverilog
wire cmplt_block = is_scalar_dest_for_iid(inst_cmplt_rob_tag) ||
                   trap_pending_for_iid(inst_cmplt_rob_tag);
assign cmplt_vld1 = inst_cmplt_valid && !cmplt_block;
```

> 这张 `is_scalar_dest_for_iid` 查的是 `accepted_inst`，F0 已经把正常情况
> 拦掉了；这里只是防止 F2 兜底时出现 cmplt/异常竞争。

**A910_cpu 侧的合并**：

- `RTU_idu_lsu_adapter` 的 `other_expt_*` 当前由 `IU_beu_pipe.expt_*`
  （取指非对齐，cause 0）驱动；
- 新增 `rvv_expt_*` 后，在 `A910_cpu.sv` 里用一个 `RTU_iid_cmp` 做年龄锦标赛，
  再把胜者送 `other_expt_*`：

```systemverilog
RTU_iid_cmp u_cmp_expt (
    .x_iid0(other_expt_iid), .x_iid1(rvv_expt_iid),
    .x_iid0_older(beu_older_rvv));
wire pick_beu = other_expt_vld & (~rvv_expt_vld | beu_older_rvv);
wire pick_rvv = rvv_expt_vld & ~pick_beu;
wire [6:0]  expt_iid_m   = pick_beu ? other_expt_iid   : rvv_expt_iid;
wire [4:0]  expt_cause_m = pick_beu ? other_expt_cause : rvv_expt_cause;
wire [31:0] expt_tval_m  = pick_beu ? other_expt_tval  : rvv_expt_tval;
wire        expt_vld_m   = pick_beu | pick_rvv;
```

> 不能简单 `OR` 两路 vld：同拍两个异常时会把更老的丢掉，而 RTU_expt
> 的注释（`RTU_expt.v` 开头）明确说明"同拍冲突在进模块前无法补救"。

### 7.4 vxsat

S4 已经把 `wr_vxsat_valid_o` 回存到 `vxsat_q` 并接回 core。本阶段只需确认：

```bash
grep -n "vxsat" mySoC/rvv_a910_bridge.sv   # vxsat_q 驱动 core.vxsat
grep -n "vxsat" mySoC/design/RvvCore.sv    # vxsat_i 接输入，不再恒 0
```

### 7.5 S5 出口

```bash
make a910-elab
```

静态核对：

```bash
grep -n "async_rd_valid\|rd_valid_rob2rt_o" mySoC/rvv_a910_bridge.sv
# F0 过滤 + F1/F2 兜底通道都要有
grep -n "rvv_expt" mySoC/A910_cpu.sv mySoC/rvv_a910_bridge.sv
# cause=2、tval、iid 三根都接进锦标赛
```

不跑 `a910-run`；向量指令的**第一条功能验证**在 S9。

### 7.6 风险

- 只做 `trap_valid_o` 转发（v1 的写法）⇒ 后端解不出的指令静默退休或卡死。
- 把 F1 的退休脉冲当成完成脉冲 ⇒ 会和 trap 冲突。
- async_rd 的 rob_tag 取错槽（必须取 ROB 输出槽 0，对应 `rvv2rvs[0]`）。
- F0 的 `vmv.x.s/vcpop/vfirst` 编码位号写错 ⇒ 三条指令进 core 后静默丢标量写回。

---

## 8. S6 —— core LSU 接口扩展与 remap scoreboard

### 8.1 目标

- `UOP_RVV2LSU_t` 带上地址、元素宽度、vl、mask、rob_tag、uop_index、
  `lsu_id` 等全部字段；
- `RvvCore` / `rvv_backend` 的 LSU 端口补齐；
- `rvv_backend_lsu_remap` 从"两条 FIFO 同索引配对"改成"按 `lsu_id` 查表的
  scoreboard"，允许乱序返回。

本阶段**不接 A910 LSU**，只在 core 内部把接口和配对逻辑做完。
S6/S7 期间 bridge 把 `uop_lsu_ready_lsu2rvv[0]` 钉 0（引擎还没接），
向量 L/S uop 会停在 core 的 LSU RS 里；只影响仿真，不影响 elaborate。

### 8.2 结构体（`mySoC/design/inc/rvv_backend.svh`）

`UOP_RVV2LSU_t`（:444-457）追加：

```systemverilog
logic [`ROB_TAG_WIDTH-1:0]      rob_tag;        // A910 iid
logic [`UOP_INDEX_WIDTH_LSU-1:0] uop_index;
logic                           first_uop_valid, last_uop_valid;
logic                           lsu_is_store;
LSU_TYPE_t                      lsu_type;
EEW_e                           vd_eew, vs2_eew;
logic [`VL_WIDTH-1:0]           vl;
logic [`VSTART_WIDTH-1:0]       vstart;
logic [`REGIDX_WIDTH-1:0]       dst_index;
logic [`XLEN-1:0]               rs1_data;
logic                           rs1_data_valid;
logic [`XLEN-1:0]               rs2_data;       // strided 步长
logic                           rs2_data_valid;
logic [$clog2(`EMUL_MAX)-1:0]   seg_field_index;
logic [2:0]                     lsu_id;         // 8 项 scoreboard 槽号
```

`UOP_LSU2RVV_t`（:516-531）追加：`rob_tag`、`uop_index`、`lsu_id`。

`LSU_MAP_INFO_t`（:505-514）追加：`lsu_id`、`rob_tag`。

`RVVCmd`（:113-122）追加：

```systemverilog
logic [`XLEN-1:0] rs2;
logic             rs2_valid;
```

`UOP_QUEUE_t`（:295 附近）已有 `rs1_data/rs1_data_valid`，补
`rs2_data/rs2_data_valid`（如果还没有）。

### 8.3 数据通路

| 文件 | 改动 |
|---|---|
| `RvvFrontEnd.sv` | S3 已填 `rs2/rs2_valid` |
| `rvv_backend_decode_unit_lsu_de2.sv` | `uop.rs1_data = lcmd.cmd.rs1`（已有）；**LSU uop 的 `rs1_data_valid` 恒 1**（包括普通向量 L/S，不只 VME）。当前 :822-826 只在 `ZVT_ON && VMELSU` 时为 1，非 ZVT 恒 0 ⇒ A910 侧拿不到基址，必须改。`uop.rs2_data = lcmd.cmd.rs2`，`rs2_data_valid = lcmd.cmd.rs2_valid` |
| `rvv_backend_decode_unit_lsu.sv` | 把 `lsu_type/mop`、`vd_eew/vs2_eew`、`vl/vstart`、`dst_index`、`seg_field_index` 从 `lcmd.cmd` 带到 `UOP_QUEUE_t`（多数字段已存在，核对一遍） |
| `rvv_backend_dispatch.sv` | LSU RS 赋值（:519-538）补 `rs1_data/rs1_data_valid/rs2_data/rs2_data_valid/lsu_type/vd_eew/vs2_eew/vl/vstart/dst_index/seg_field_index/first/last/lsu_is_store`；MAPINFO 补 `rob_tag` |
| `rvv_backend.sv` | RS→LSU 的 `uop_lsu_rvv2lsu` 装配处补同样的字段 |
| `rvv_backend_decode_unit_lsu.sv` | **加合法性检查**：`lsu_is_store && csr_lmul > LMUL4 ⇒ illegal`（走 `de2rt`，S5 的 F1 会把它变成 trap）。原因见 §9.4 |

### 8.4 `RvvCore.sv` / `rvv_backend.sv` 端口

保留现有 8 根扁平数据线，只**追加**（不建议改成结构端口，避免动顶层）：

RVV→LSU：

```systemverilog
output logic [`NUM_LSU-1:0][`ROB_TAG_WIDTH-1:0]      uop_lsu_rob_tag_rvv2lsu;
output logic [`NUM_LSU-1:0][`UOP_INDEX_WIDTH_LSU-1:0]uop_lsu_uop_index_rvv2lsu;
output logic [`NUM_LSU-1:0][2:0]                     uop_lsu_lsu_id_rvv2lsu;
output logic [`NUM_LSU-1:0]                          uop_lsu_first_rvv2lsu;
output logic [`NUM_LSU-1:0]                          uop_lsu_last_rvv2lsu;
output logic [`NUM_LSU-1:0]                          uop_lsu_is_store_rvv2lsu;
output LSU_TYPE_t [`NUM_LSU-1:0]                     uop_lsu_type_rvv2lsu;
output EEW_e [`NUM_LSU-1:0]                          uop_lsu_vd_eew_rvv2lsu;
output EEW_e [`NUM_LSU-1:0]                          uop_lsu_vs2_eew_rvv2lsu;
output logic [`NUM_LSU-1:0][`VL_WIDTH-1:0]           uop_lsu_vl_rvv2lsu;
output logic [`NUM_LSU-1:0][`VSTART_WIDTH-1:0]       uop_lsu_vstart_rvv2lsu;
output logic [`NUM_LSU-1:0][`REGIDX_WIDTH-1:0]       uop_lsu_dst_index_rvv2lsu;
output logic [`NUM_LSU-1:0][31:0]                    uop_lsu_rs1_data_rvv2lsu;
output logic [`NUM_LSU-1:0]                          uop_lsu_rs1_vld_rvv2lsu;
output logic [`NUM_LSU-1:0][31:0]                    uop_lsu_rs2_data_rvv2lsu;
output logic [`NUM_LSU-1:0]                          uop_lsu_rs2_vld_rvv2lsu;
output logic [`NUM_LSU-1:0][$clog2(`EMUL_MAX)-1:0]   uop_lsu_seg_index_rvv2lsu;
```

LSU→RVV：

```systemverilog
input logic [`NUM_LSU-1:0][`ROB_TAG_WIDTH-1:0]       uop_lsu_rob_tag_lsu2rvv;
input logic [`NUM_LSU-1:0][`UOP_INDEX_WIDTH_LSU-1:0] uop_lsu_uop_index_lsu2rvv;
input logic [`NUM_LSU-1:0][2:0]                      uop_lsu_lsu_id_lsu2rvv;
```

`NUM_LSU=2`（`rvv_backend_define.svh:95`）；本计划只用车到 0，lane1 的
`uop_lsu_ready_lsu2rvv[1]` 恒 0 即可。

### 8.5 `rvv_backend_lsu_remap.sv` → keyed scoreboard

现状（:57-101）：`mapinfo` FIFO 与 `lsu_res` FIFO **同索引配对**，隐含"按序
返回"。改成：

```systemverilog
localparam NUM_SS = 8;

logic               ss_valid[0:NUM_SS-1];
logic [3:0]         ss_rob_entry[0:NUM_SS-1];  // ROB_DEPTH_WIDTH
logic [6:0]         ss_rob_tag[0:NUM_SS-1];
logic               ss_is_store[0:NUM_SS-1];
logic [4:0]         ss_waddr[0:NUM_SS-1];      // REGIDX_WIDTH
logic [2:0]         ss_lsu_id[0:NUM_SS-1];     // 自校验
logic               ss_free[0:NUM_SS-1];
logic [2:0]         lsu_slot_ptr;
```

- **分配**：`mapinfo_valid[i]` 时找 `lsu_slot_ptr` 起第一个 `!ss_valid` 的槽，
  写入 `mapinfo` 的 `rob_entry/lsu_is_store/vregfile_write_addr`，置
  `ss_valid`；同时把 `lsu_id` 写进 `UOP_RVV2LSU_t`（这会连带写进 RS 的
  `lsu_id` 字段）。`pop_mapinfo[i]` 在分配成功那拍置 1（mapinfo 表项被消费）。
- **完成**：`lsu_res_valid[i]` 时用 `lsu_res[i].uop_lsu2rvv.lsu_id` 查槽；
  - `vregfile_write_valid`（load）→ `PU2ROB_t{rob_entry, w_data, w_valid}`
    （原 :68-74 的逻辑不变，只是 `rob_entry` 从 `ss_rob_entry[lsu_id]` 取）；
  - `lsu_vstore_last`（store）→ `w_valid=0`、`last_uop_valid=1`；
  - 置 `ss_free[lsu_id]`，`pop_lsu_res[i]=1`。
- **trap**：`lsu_res[i].trap_valid` → `trap_rob_entry_rmp2rob =
  ss_rob_entry[lsu_id]`，然后释放槽。
- **同拍多个返回**：两个 lane 各自查表；`lsu_id` 唯一（分配指针跳过 busy），
  不会冲突。
- **自校验**：比较 `ss_lsu_id[lsu_id] == lsu_res[i].lsu_id`，不等就断言
  （防止槽被错误覆盖导致的串数据）。
- `lsu_slot_ptr` 分配后自增；如果 8 槽全忙，`mapinfo` 侧反压
  （`uop_lsu_ready_lsu2rvv` 相应拉低），不能覆盖。

### 8.6 S6 出口

```bash
make rvv-elab && make a910-elab
```

静态核对：

```bash
grep -n "rs1_data_valid" mySoC/design/rvv_backend_decode_unit_lsu_de2.sv
# 非 ZVT 分支必须是 1
grep -n "lsu_id" mySoC/design/rvv_backend_lsu_remap.sv
# 分配/完成/释放三处都要有
```

不跑仿真。

### 8.7 风险

- `rs1_data_valid` 不改 ⇒ 所有向量访存的基址都是 0（而且不报错）。
- scoreboard 槽分配不是原子的话，同拍两个 lane 可能拿到同一个槽。
- `uop_index`/`lsu_id` 在 RS 里漏传，返回时配对失败 ⇒ 静默丢写回。
- `UOP_RVV2LSU_t` 是 packed struct，字段顺序变了以后所有按位置赋值的代码
  都要用字段名，不能再用拼接。

---

## 9. S7 —— LSIQ anchor 与 LSU 侧向量支持

### 9.1 目标

> **先回答"是流水线还是 LSIQ entry"**：是 **LSIQ entry（anchor）**。
> 不另开一条向量 LSU 流水线；LSU 仍是同一套 AG/DC/DA/WB。S8 的 fill 引擎
> 只负责把 core uop 拆成 A910 beat 并填进 anchor，不直接驱动发射口。

- vector LOAD/STORE 在 **IS 派发时**在现有 8 项 LSIQ 里创建一个 anchor；
- LSIQ 表项支持 anchor 字段、逐 beat 更新、`beat_done`、最后 beat 才 pop；
- `vec/uop_idx/last` 贯通 LSU 流水；
- LQ/MSHR/SQ 的 `inst_hit` 带 `uop_idx`，LQ 支持向量提前 pop；
- 标量 LSIQ/SDIQ 在 `vec=0` 时逐拍行为不变；
- **仍不跑功能仿真，只 elaborate**。

> 本阶段不建 fill 引擎。所有 anchor 的 `vec_beat_rdy` 先由 `A910_cpu` 钉 0，
> 所以 anchor 只占位、不发射；S8 再接 fill 引擎。

### 9.2 `ct_idu_is_lsiq_entry.sv`

#### 9.2.1 新增端口

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `x_vec` | input | 1 | create 时从 `x_create_data` 解析 |
| `x_vec_beat_rdy` | input | 1 | fill 引擎：当前 beat 可发射 |
| `x_vec_upd_en` | input | 1 | fill 引擎：写下一个 beat |
| `x_vec_upd_data` | input | `VEC_BEAT_WIDTH` | beat 字段 |
| `x_vec_beat_done` | input | 1 | LSU DA：本 beat 完成但非最后 beat |
| `x_read_vec_beat` | output | `VEC_BEAT_WIDTH` | 给 IDU 顶层发射 mux |
| `x_read_vec` | output | 1 | 本表项是 anchor |

#### 9.2.2 beat 字段

```systemverilog
parameter VEC_BEAT_WIDTH = 32   // synthetic opcode: LBU/LHU/LW / SB/SH/SW
                         + 32   // 完整元素地址（offset 恒 0）
                         + 4    // sdiq_entry（store；load 恒 0）
                         + 5    // uop_idx（A910 request index）
                         + 1    // last
                         + 32;  // sd_data（store beat 的 32 位数据）
// = 106 bit
```

- synthetic opcode 让 `ct_idu_rf_dp` 的 pipe3/pipe4 解码**完全不用改**，
  `inst_size/sign_extend` 自动正确；
- `addr` 是完整地址，LSU 的 `offset` 恒 0；
- `uop_idx` 同时作为 load 的 `dst_preg[5:0]`（高位补 0）。

#### 9.2.3 状态机

```systemverilog
assign src0_rdy_for_issue = x_vec ? x_vec_beat_rdy : read_src0_data[0];
assign x_raw_rdy = vld && !frz && src0_rdy_for_issue;

// frz：任何一次发射都置 1；anchor 在 beat_done 清
else if (x_issue_en)                                 frz <= 1'b1;
else if (x_vec_beat_done)                            frz <= 1'b0;
else if (lsu_frz_clr | lsu_idu_imme_wakeup)          frz <= 1'b0;

// vld：只有 pop（最后 beat）才清
else if (lsu_idu_lsiq_pop_vld && x_pop_cur_entry)    vld <= 1'b0;
```

- `agevec`、`agevec_all`、entry counter **只在 `lsu_idu_lsiq_pop_vld` 上更新**；
  `beat_done` 绝不能清 agevec/counter；
- `old = !|agevec_all` 完全不变；
- anchor 的 `older_entry_rdy_mask` 用 `x_other_raw_rdy`，与标量一致。

#### 9.2.4 create/update 字段

- `LSIQ_WIDTH` 60→**61**，新增 `LSIQ_VEC`（最高位）；
- create data 需要包含 `LSIQ_VEC`、iid、load/store；`opcode/dst_preg/sdiq_entry`
  先填占位；
- update 只改 beat 字段，不改 iid/load/store/vec/agevec；
- 同一 anchor 的上一 beat 未消费时，fill 引擎不得覆盖；
- **update 与 `vec_beat_rdy` 至少隔一拍**（T 拍 update，T+1 拍 ready），
  或 ready 同拍走组合旁路；否则 LSIQ 在 update 同拍发射，读到上一 beat。

### 9.3 `ct_idu_is_lsiq.sv`

1. create：8 个 entry 的 create data/agevec 照旧，只是宽度 +1；
2. 新增广播：

```systemverilog
input  logic [LSIQ_ENTRY-1:0]     lsiq_vec_upd_entry;
input  logic [VEC_BEAT_WIDTH-1:0] lsiq_vec_upd_data;
input  logic [LSIQ_ENTRY-1:0]     lsiq_vec_beat_rdy;   // 扇出到 x_vec_beat_rdy
input  logic [LSIQ_ENTRY-1:0]     lsu_idu_beat_done;
```

3. 发射数据选路：用现有 issue one-hot 把 anchor 的 beat 总线也选出来，
   送 `ct_idu_rf_dp`，在 pipe3/pipe4 打拍后 override：

```systemverilog
output logic [VEC_BEAT_WIDTH-1:0] lsiq_dp_pipe3_vec_beat;
output logic [VEC_BEAT_WIDTH-1:0] lsiq_dp_pipe4_vec_beat;
output logic                      lsiq_dp_pipe3_issue_vec;
output logic                      lsiq_dp_pipe4_issue_vec;
output logic [LSIQ_ENTRY-1:0]     lsiq_vec_old;   // 给 fill 引擎做 load old 门控
// ct_idu_rf_dp:
assign idu_lsu_ld_src[31:0] = issue_vec ? beat_addr : lsiq_src0_from_prf;
assign idu_lsu_ld_preg[5:0] = issue_vec ? {1'b0, beat_uop_idx} : lsiq_dst_preg;
assign idu_lsu_ld_oldest    = issue_vec ? 1'b0 : lsiq_oldest;
assign idu_lsu_ld_vec       = issue_vec;
assign idu_lsu_ld_last      = issue_vec ? beat_last : 1'b1;
assign idu_lsu_ld_uop_idx   = beat_uop_idx;
```

- `ct_idu_rf_dp` 的 `LSIQ_WIDTH` 60→61，`rf_pipe3_data/rf_pipe4_data` 同步；
  `issue_vec` 可直接取 `rf_pipe3_data[LSIQ_VEC]` / `rf_pipe4_data[LSIQ_VEC]`；
- synthetic opcode 直接写进 entry 的 `opcode` 字段 ⇒ pipe3/pipe4 解码复用；
- `sdiq_entry` 直接写进 entry 的 `LSIQ_SDIQ_ENTRY` 字段 ⇒ pipe4 原路取；
- `iid` 用 entry 的 iid；`offset` 恒 0。

4. `old` 跨类型修正（同 v1 §7.7）：标量 entry 的 `old` 再与
   `vec_old_iid/vld` 比较一次。

### 9.4 IS 派发：vector L/S 同时建 VIQ 和 LSIQ anchor

文件：`ct_idu_ir_ctrl.sv`、`ct_idu_is_dp.sv`、`ct_idu_is_ctrl.sv`

1. `IS_CTRL_VMEM`（bit8）已由 `ct_idu_ir_dp` 从 `vec_type` 生成（S1 已加）；
2. `ctrl_ir_inst{k}_lsiq` 在 S1 是 `... && !vec`，本阶段改为：

```systemverilog
assign ctrl_ir_inst{k}_lsiq =
       (原标量 LSU 项) || ir_pipedown_inst{k}_ctrl_info[IS_CTRL_VMEM];
```

3. `ctrl_ir_pre_dis_inst{k}_lsiq`/`ctrl_ir_pre_dis_3_lsiq_inst` 自动覆盖
   vector L/S，pipedown2 stall 保证同拍最多 2 条 LSIQ、agevec 连续；
4. `LSIQ_WIDTH` 60→**61**（新增 `LSIQ_VEC` 最高位；老位号全部不动）。
   **4 份副本全部同步**：`ct_idu_is_lsiq.sv:43`、
   `ct_idu_is_lsiq_entry.sv:47`、`ct_idu_is_dp.sv:195`、
   `ct_idu_rf_dp.sv:180`；所有硬编码 `[59:0]`（top:323/326/494/495、
   is_lsiq:5/6/33/37、is_lsiq_entry:20/31、is_dp:85/86、rf_dp:63/85）
   改成 `[60:0]`；
5. `ct_idu_is_dp` 的 LSIQ create data：
   - `LSIQ_VEC = is_inst{k}_vec`；
   - `LSIQ_LOAD = 原标量 LOAD || (vec && vec_type==01)`；
   - `LSIQ_STORE = 原标量 STORE || (vec && vec_type==10)`；
   - `LSIQ_SRC0_VLD=1`，源编码固定 **`7'b0000001`**（preg0+wb=1），
     anchor 的 ready 由 `vec_beat_rdy` 旁路；
   - iid 照旧；
   - `opcode/dst_preg/sdiq_entry` 填 0（等 beat update）；
6. VIQ 照旧同时 create：同一条指令两个影子，iid 相同。
   给 fill 引擎的 `lsiq_vec_create_entry` 要带**表项号**（由
   `ct_idu_is_lsiq` 的 `lsiq_entry_create{0,1}_in` 生成的 one-hot），
   只给 create_en 不够。

> 这一步是本方案和旧方案的根本区别：anchor 在 **IS 派发**时就进入年龄图，
> 不是等 core 出 uop 才建。

### 9.5 LSU 流水：`vec/uop_idx/last` 与 `beat_done`

#### 9.5.1 新增字段

| 级 | 信号 |
|---|---|
| IDU→LSU | `idu_lsu_ld_vec`, `idu_lsu_ld_uop_idx[4:0]`, `idu_lsu_ld_last` |
| IDU→LSU | `idu_lsu_st_vec`, `idu_lsu_st_uop_idx[4:0]`, `idu_lsu_st_last` |
| AG→DC | `ld_ag_dc_vec/uop_idx/last`, `st_ag_dc_vec/uop_idx/last` |
| DC→DA | `ld_dc_da_vec/uop_idx/last`, `st_dc_da_vec/uop_idx/last` |
| DA→WB | `ld_da_wb_vec/uop_idx`, `st_da_wb_vec/uop_idx` |
| LSU→IDU | `lsu_idu_wb_pipe3_wb_preg_vec`, `lsu_idu_wb_pipe3_wb_uop_idx[4:0]` |
| LSU→IDU | `lsu_idu_beat_done[LSIQ_ENTRY-1:0]` |
| LSU→RTU | `lsu_rtu_wb_pipe3_wb_preg_vec`, `lsu_rtu_wb_pipe4_vec` |

`last` 只到 DA；WB 不需要。

#### 9.5.2 DA 级 pop / beat_done

`lsu_ld_da.sv`（当前 :638-641）：

```systemverilog
assign ld_da_idu_pop_vld = ld_da_inst_vld && !ld_da_restart_vld &&
                           (!ld_da_vec || ld_da_last);
assign ld_da_idu_beat_vld = ld_da_inst_vld && !ld_da_restart_vld &&
                            ld_da_vec && !ld_da_last;
assign ld_da_idu_beat_done[LSIQ_ENTRY-1:0] =
    {LSIQ_ENTRY{ld_da_idu_beat_vld}} & ld_da_mask_lsid[LSIQ_ENTRY-1:0];
```

`lsu_st_da.sv`（当前 :331-332）：

```systemverilog
assign st_da_idu_pop_vld = st_da_wb_cmplt_req && (!st_da_vec || st_da_last);
assign st_da_idu_beat_done[LSIQ_ENTRY-1:0] =
    {LSIQ_ENTRY{st_da_wb_cmplt_req && st_da_vec && !st_da_last}} &
    st_da_mask_lsid[LSIQ_ENTRY-1:0];
```

`lsu_top.sv`：

```systemverilog
assign lsu_idu_pop_entry = ld_da_idu_pop_entry | st_da_idu_pop_entry;
assign lsu_idu_beat_done = ld_da_idu_beat_done | st_da_idu_beat_done;
```

**非最后 beat 绝不能拉 `lsu_idu_pop_vld`**：`ct_idu_is_lsiq` 的 counter 和
8 个 entry 的 `agevec/agevec_all` 都在 pop 上更新；提前拉会把 anchor 从年龄图
删掉，但 vld 还在。

### 9.6 LQ / MSHR / SQ：`uop_idx`

#### 9.6.1 LQ

`lsu_lq_entry.sv`：

- 新增 `ld_dc_vec`、`ld_dc_old`、`ld_dc_uop_idx[4:0]`、`ld_wb_data_vld`、
  `ld_wb_data_iid[6:0]`、`ld_wb_data_uop_idx[4:0]`；
- 新增寄存器 `lq_entry_vec`、`lq_entry_old`、`lq_entry_uop_idx[4:0]`；
- **`lq_entry_old` 锁存**：标量取 `ld_dc_old`；向量取 **1**（S8 的 fill
  引擎保证向量 load 只在 anchor 是 LSIQ 最老项时才发 beat）；
- `:127`：

```systemverilog
assign lq_entry_inst_hit = lq_entry_vld &&
                           (lq_entry_iid[6:0] == ld_dc_iid[6:0]) &&
                           (!ld_dc_vec ||
                            (lq_entry_uop_idx[4:0] == ld_dc_uop_idx[4:0]));
```

- `:120`：

```systemverilog
assign lq_entry_pop_vld = lq_entry_cmit_vld ||
                          (lq_entry_vec && lq_entry_old &&
                           ld_wb_data_vld &&
                           (ld_wb_data_iid[6:0] == lq_entry_iid[6:0]) &&
                           (ld_wb_data_uop_idx[4:0] == lq_entry_uop_idx[4:0]));
```

> ⚠️ **RAW 风险**：无条件提前 pop 会让"更老 store 晚到 DC"找不到 LQ 表项 ⇒
> 静默读旧值。首版采用**双保险**：
> 1. fill 引擎对 **vector load** 的 `vec_beat_rdy` 额外要求该 anchor 的
>    `lsiq_vec_old=1`（它是 LSIQ 最老项）——这样不存在"更老的 store 以后才到
>    DC"；
> 2. LQ 提前 pop 条件再带 `lq_entry_old`（`ld_dc_old` 锁存）作为断言/兜底。
>
> store 不需要第 1 条（走 SQ）。这条门控会让向量 load 等更老的 LSIQ 项排空，
> 但不改 agevec/old 的定义，也不改标量发射顺序。

#### 9.6.2 MSHR

`lsu_mshr_entry.sv`：

- 新增 `ld_da_vec`、`ld_da_uop_idx[4:0]`、`rb_entry_vec`、
  `rb_entry_uop_idx[4:0]`；
- `:598`：

```systemverilog
assign rb_entry_iid_hit = (rb_entry_iid[6:0] == ld_da_iid[6:0]) &&
                          (!ld_da_vec ||
                           (rb_entry_uop_idx[4:0] == ld_da_uop_idx[4:0]));
```

#### 9.6.3 SQ

`lsu_sq_entry.sv`：

- 新增 `st_dc_vec`、`st_dc_uop_idx[4:0]`、`sq_entry_vec`、
  `sq_entry_uop_idx[4:0]`、`st_da_uop_idx[4:0]`；
- `:477` `sq_entry_inst_hit`：

```systemverilog
assign sq_entry_inst_hit = sq_entry_vld && !sq_entry_no_restart &&
                           (sq_entry_iid[IID_WIDTH-1:0] ==
                            st_dc_iid[IID_WIDTH-1:0]) &&
                           (!st_dc_vec ||
                            (sq_entry_uop_idx[4:0] == st_dc_uop_idx[4:0]));
```

- `sq_entry_st_da_info_set` 也加 `!st_da_vec || uop_idx 匹配`，否则
  `st_da` 的写完成信息会写到同 iid 的另一个 beat 表项；
- 提交匹配（`sq_entry_cmit_set`）仍只比 iid：整条指令的所有 beat 一起提交；
  **`vec_st_cmit_vld` 必须是电平，不是单拍脉冲**：它从 commit 命中开始一直
  保持到该 anchor 的所有 beat 排空。向量 store 的 beat 在提交之后才进 SQ；
  只给一拍，后建的表项永远看不到 commit，会等第二次提交（永远不会来）；
- 同一 iid 多个 beat 之间的**同地址顺序**：首版由"anchor 顺序发射 + SQ 创建
  顺序"保证；若 IO 重叠地址用例失败，再把 `uop_idx` 加进 same-addr newest
  比较；
- **SQ 表项弹出要把 `uop_idx` 回送给 fill 引擎**（新增
  `lsu_idu_sq_pop_vld`/`_uop_idx`），用于释放 request index；不能在"数据
  捕获"时就释放；
- `sq_entry_sdid_hit` 仍比 sdid。

### 9.7 RTU 适配层屏蔽

`RTU_idu_lsu_adapter.v`：

```systemverilog
assign cmplt_vld5 = lsu_rtu_wb_pipe3_cmplt & ~lsu_rtu_wb_pipe3_wb_preg_vec;
assign cmplt_vld6 = lsu_rtu_wb_pipe4_cmplt & ~lsu_rtu_wb_pipe4_vec;
```

同时 vec 写回时把 `lsu_rtu_wb_pipe3_wb_preg_expand/vld` 清 0。`uop_idx` 只用于
LQ/MSHR/引擎，不能进 PRF/唤醒/RTU 释放/dealloc 四处。

### 9.8 SDIQ：每个 store beat 一个数据项（4 项不变）

- **不扩 SDIQ**；复用现有 4 项；
- `ct_idu_is_sdiq.sv` 增加向量 create/issue 旁路：
  - `vec_sdiq_create_vld/entry` 由 fill 引擎给（S8）；
  - create data 固定 **`8'b0000_0010`**（`x_create_data[7:1]=7'b0000001`，
    `src0_vld=0`）；**不是** 7 位 `{6'b0,1'b1}`（见 §9.8.1）；
  - 真实数据由 `vec_sd_data` 在 `ct_idu_rf_dp` pipe5 mux；
  - 向量项不参与 `idu_rtu_pst_preg_dealloc_mask`（只 OR 0~3）；
- 地址和数据解耦：anchor beat 带 `sdiq_entry`，SDIQ 单独 issue，SQ 等数据。

#### 9.8.1 create data 位宽（静默坑）

`ct_idu_is_sdiq_entry.sv:79` `SDIQ_WIDTH=8`；布局：

```text
x_create_data[7:1] = 依赖表项 7 位 {preg[5:0], wb}
x_create_data[6]   = SDIQ_SRC0_VLD（与 preg[5] 重叠）
```

正确常量：

```systemverilog
assign vec_sdiq_create_data = 8'b0000_0010;
```

v1 的 `{6'b0,1'b1}` 是 7 位，零扩展成 `8'b0000_0001` 后 wb 落到 bit0，
`x_create_data[7:1]` 全 0 ⇒ **SDIQ 表项永不 ready**。

### 9.9 向量 store 的 LMUL 限制

store beat 在提交前要 staging 在 fill 引擎里；每 anchor 预留 **4 个 core
uop** 的 staging（S8）。所以限制的是 **单条向量 store 的 core uop 数 ≤ 4**：

```systemverilog
// rvv_backend_decode_unit_lsu.sv
// uop_index_max 是本条指令解出的 uop 数 - 1（:48/:186 起）
if (lsu_is_store && ((uop_index_max + 1) > 4)) lcmd_valid = 0;
```

- unit-stride 下 uop 数 = LMUL，所以等价于 LMUL≤4；
- strided/indexed/segment 由实际 `uop_index_max+1` 决定，不能只看 LMUL；
- 走 `de2rt` → S5 的 F1 trap。**不要**等 uop 出核后因 staging 不够而卡住。

### 9.10 `old` 的跨类型修正

anchor 让"标量 load 前面只有更老的向量 store"重新出现。标量 LSIQ entry 的
`old` 只看 8 个 LSIQ 表项，会误判最老 ⇒ `ld_dc_old=1` ⇒ 跳过 LQ 建表
（`lsu_ld_dc.sv:308-312`）⇒ 更老的向量 store 后到时无法通过 LQ 的 RAW
spec-fail 触发重放 ⇒ **静默读旧值**。

```systemverilog
// 标量 LSIQ 表项 i
wire lsiq_entry{i}_old_raw = /* 原 old 表达式 */;
assign lsiq_entry{i}_old = lsiq_entry{i}_old_raw &&
                           !(vec_old_vld &&
                             iid_older(vec_old_iid, lsiq_entry{i}_iid));
```

- `vec_old_iid/vld` 由 S8 的 fill 引擎给；
- anchor 的 `oldest` 恒 0（保守建 LQ）；
- `iid_older` 用 `RTU_iid_cmp.v:28-61` 的规则。

### 9.11 S7 出口

```bash
make a910-elab
```

静态核对：

```bash
# LSIQ 仍是 8，SDIQ 仍是 4
grep -rn "LSIQ_ENTRY *= *8" mySoC/lsu/rtl/lsu_top.sv mySoC/lsu/rtl/lsu_ld_*.sv
grep -rn "SDIQ_ENTRY *= *4" mySoC/lsu/rtl/lsu_top.sv
# LSIQ 宽度 61，旧硬编码清空
grep -rn "\[59:0\]" mySoC/idu_c910/rtl || true
# anchor 字段/状态
grep -n "VEC_BEAT_WIDTH\|beat_done\|vec_beat_rdy" \
  mySoC/idu_c910/rtl/ct_idu_is_lsiq_entry.sv mySoC/idu_c910/rtl/ct_idu_is_lsiq.sv
# pop 门控
grep -n "ld_da_idu_pop_vld\|st_da_idu_pop_vld" mySoC/lsu/rtl/lsu_ld_da.sv mySoC/lsu/rtl/lsu_st_da.sv
# 每一处都应含 (!xx_vec || xx_last)
# uop_idx 贯通 / old 门控
grep -rn "uop_idx" mySoC/lsu/rtl/lsu_lq_entry.sv mySoC/lsu/rtl/lsu_mshr_entry.sv \
  mySoC/lsu/rtl/lsu_sq_entry.sv
grep -rn "lsiq_vec_old\|lq_entry_old\|ld_dc_old" \
  mySoC/idu_c910/rtl/ct_idu_is_lsiq.sv mySoC/lsu/rtl/lsu_lq_entry.sv
```

**本阶段 `vec_beat_rdy` 全钉 0**（fill 引擎未接），anchor 只占位不发射。

### 9.12 风险

- 只改 pop、不改 `frz` ⇒ 第一个 beat 之后永久冻住。
- 非最后 beat 误拉 `pop_vld` ⇒ agevec/counter 提前清，anchor 从年龄图消失。
- `uop_idx` 只接到 LQ、没接 SQ/MSHR ⇒ 同 iid 的后续 beat 建不了表项。
- SQ 的 `st_da_info_set` 不加 uop_idx ⇒ 写完成信息串到另一个 beat。
- 向量 store 未做 staging ⇒ 提交前写内存，或 SQ 满死锁。


---

## 10. S8 —— fill 引擎与全链接通

### 10.1 目标

- 新模块 `ct_idu_vec_ls_fill.sv`：把 RVV core 的 `UOP_RVV2LSU_t` 拆成 A910
  beat，写进 S7 的 LSIQ anchor；
- 收集 load 写回、拼 128 位、回送 core；
- 向量 store staging + 提交后排空；
- IDU 顶层把 anchor 的 create/update/issue/写回/commit 全接上；
- 仍不跑功能仿真。

### 10.2 新模块端口

| 端口 | 方向 | 位宽/类型 |
|---|---|---|
| `rvv_lsu_uop_valid` / `_data` | input | 1 / `UOP_RVV2LSU_t` |
| `rvv_lsu_uop_ready` | output | 1（按 anchor 上下文/beat 槽反压 core） |
| `rvv_lsu_resp_valid` / `_data` | output | 1 / `UOP_LSU2RVV_t` |
| `rvv_lsu_resp_ready` | input | 1 |
| `lsiq_vec_create_vld` / `_entry[7:0]` / `_iid[6:0]` / `_store` | input | IS 建 anchor 时给 |
| `lsiq_vec_upd_entry[7:0]` / `_data[VEC_BEAT_WIDTH-1:0]` | output | 给 LSIQ entry |
| `lsiq_vec_beat_rdy[7:0]` | output | 给 LSIQ entry 的 `x_vec_beat_rdy` |
| `lsiq_vec_old[7:0]` | input | 该 anchor 是否是 LSIQ 最老项（load 用） |
| `lsu_idu_beat_done[7:0]` | input | 来自 LSU DA |
| `lsu_idu_pop_entry[7:0]` | input | 最后 beat 的 pop |
| `lsu_idu_wb_pipe3_wb_preg_vec` / `_uop_idx[4:0]` / `_iid[6:0]` / `_data[31:0]` | input | load 写回 |
| `lsu_idu_sq_pop_vld` / `_uop_idx[4:0]` | input | SQ 表项弹出（释放 request index） |
| `rtu_commit0/1/2` + `_iid0/1/2` | input | 1/7 each（RTU commit 脉冲，bridge 透传） |
| `vec_st_cmit_vld` / `_iid[6:0]` | output | 1/7（**电平**，保持到该 anchor 排空；给 SQ） |
| `vec_sdiq_create_vld` / `_entry[3:0]` | output/input | SDIQ 申请/回告 |
| `vec_sdiq_issue_entry[3:0]` / `vec_sd_data[31:0]` | output | SDIQ 数据 |
| `lsu_idu_lq_full/rb_full/sq_full[7:0]` | input | 反压 |
| `vec_old_iid[6:0]` / `_vld` | output | 给标量 LSIQ 的 `old` 修正 |

> LSIQ_ENTRY=8、SDIQ_ENTRY=4，**没有 tag 8~11**。

### 10.3 anchor 上下文

每个 LSIQ 表项一份上下文（8 份），按表项号索引：

```systemverilog
typedef struct packed {
  logic        active;
  logic [6:0]  iid;
  logic        store;
  logic [4:0]  cur_core_uop;      // core 的 uop_index
  logic [7:0]  cur_vl;
  logic [2:0]  vd_eew, vs2_eew;
  logic [1:0]  mop;               // US/CS/IU/IO
  logic [31:0] base, stride;
  logic [127:0] vidx, sdata;
  logic [15:0] mask;
  logic        data_ok;
  logic [4:0]  beat_ptr;          // 当前 core uop 内的 beat 指针
  logic [127:0] ld_asm;           // load 128 位拼装
  logic        store_staged;
  logic        committed;
  // store staging：最多 4 个 core uop（LMUL≤4）
  logic [3:0]  stage_vld;
  /* 4 × {core_uop, vidx, sdata, mask, eew, mop, base, stride, vl} */
} vec_anchor_ctx_t;
```

- load：只保留当前 core uop；
- store：保留最多 4 个 core uop，提交前不排空；
- core uop 的 `rob_tag` 就是 anchor 的 iid；引擎在 8 份上下文里按 iid 匹配。
  anchor 在 IS 先建、uop 后到，不会反序；
- `rtu_yy_xx_flush` 时清所有上下文/request 表/staging/committed；LSIQ 表项由
  LSIQ 自己的 flush 清；
- 该结构只是说明，实现时按实际宽度裁剪。

### 10.4 request index（`uop_idx[4:0]`）

- 全局 32 项 request 表（所有 anchor 共用）：
  `{anchor_idx[2:0], core_uop[4:0], cell_mask[15:0], store, valid}`；
- 每个 A910 beat 分配一个唯一的 5 位 index，写进 anchor 的 beat 字段；
- index 随 LSU 流水到 LQ/MSHR/SQ；load 写回带回来；
- **释放时机**：load 在 LQ 表项弹出后释放；store 在 **SQ 表项弹出**后释放
  （不能在"数据捕获"时释放；SQ 表项还带着 `uop_idx` 活着）；
- 实现建议：5 位轮转 + 32 位 `req_valid` 位图，分配时找第一个空闲 index；
  对应 LQ/SQ 表项弹出时清位；
- 32 > LQ(8)+SQ(6)+MSHR+pipeline，正常情况下不会 32 项全在飞；超长指令
  可以回绕，只要对应表项已弹出。

> 这是用户说的 `uop_idx`：**A910 请求级唯一键**，不是 core 的
> `uop_index` 原值。core 的 `uop_index` 另存在 `cur_core_uop`，用于把 load
> 数据拼回正确的 128 位向量寄存器。

### 10.5 beat 生成

1. core uop 进入后，按 `lsu_type/mop` 算每个 active 字节的地址：
   - US：`base + (chunk_base + k) * (1<<vd_eew)/8`；
   - CS：`base + (chunk_base + k) * $signed(stride)`；
   - IU/IO：`base + sign_extend(vidx[slice])`；
2. 4B 对齐字内合并连续有效字节：
   - 4B → `LW/SW`；2B → `LHU/SH`；1B → `LBU/SB`；有洞就拆；
   - store 数据按起始字节旋转（`LsuCell.rotl`，`Lsu.scala:611-620`）；
3. 每个合并请求分配 request index，写 anchor beat：
   `{opcode, addr, sdiq_entry, uop_idx, last, sd_data}`；
4. `last = core_uop.last_uop_valid && 本 uop 的最后一个请求`；
5. `vec_beat_rdy=1`；**load 还要求 `lsiq_vec_old[anchor]=1`**（见 §9.6.1
   的 RAW 说明），store 不等；LSIQ 正常仲裁；
6. 收到 `beat_done`：清 beat、`beat_ptr++`；有请求就填下一个，否则等
   core 下一个 uop；
7. 收到最后 beat 的 `pop_entry`：释放 anchor 上下文和 request 表项。

### 10.6 load 写回与拼装

- LSU 写回：`wb_preg_vec=1` + `uop_idx` + `iid` + `data[31:0]`；
- 用 `{iid, uop_idx}` 查 request 表 → `{anchor, core_uop, cell_mask}`；
- 每个 core uop 开始时 `ctx.ld_asm` 清 0；把有效字节写进对应字节；
  未写的 inactive/tail 字节保持 0；
- `ff_tail_index` 恒 `VLENB`（不做 fault-only-first）；
- 该 core uop 的所有 request 返回后：
  - `rvv_lsu_resp.vregfile_write_valid=1`；
  - `vregfile_write_addr = core uop.dst_index`；
  - `vregfile_write_data = ld_asm`；
  - `ff_tail_index = VLENB`；
  - `rob_tag/uop_index/lsu_id` 原样带回；
- **不等提交**（load 提前完成，否则 LQ 8 项死锁）；
- `rvv_lsu_resp_ready` 低时用 4 深响应 FIFO 暂存；FIFO 满则对应 anchor
  不再接收新 core uop，但不影响已发出的 beat。

### 10.7 store staging 与提交后排空

1. core store uop 到来：把
   `{core_uop, vidx, sdata, mask, eew, mop, base, stride, vl, last}` 存进
   staging（每 anchor ≤4 个 core uop；LMUL>4 已在 S5 被 trap）；
2. 数据齐后向 core 回 `lsu_vstore_last`
   （`UOP_LSU2RVV_t`，`vregfile_write_valid=0`），让 core 完成/提交；
3. **提交前 anchor 的 `vec_beat_rdy` 恒 0**；
4. 收到 `rtu_commit*_iid == anchor iid` 后把 `ctx.committed` 置 1；
   排空期间 `vec_st_cmit_vld` 一直为 1；
   **`vec_st_cmit_vld` 是电平**：从 commit 命中保持到所有 beat 排空。
   提交后才建的 SQ beat 表项靠这个电平"一建即已提交"；
5. 每个 beat：
   - 向 SDIQ 申请一个数据项（4 项池），写 32 位数据；
   - 写 anchor beat（sdiq_entry/addr/synthetic store opcode/uop_idx/last）；
   - `vec_beat_rdy=1`；LSIQ 发射；SQ 按 `{iid,uop_idx}` 建表项；
6. 所有 beat 排空后释放 anchor；
7. 用 `sq_full/not_full` 和 SDIQ 可用性反压；
8. **多个 vector store 同时 committed 时串行排空**（一次一个 anchor）；
   `vec_st_cmit_vld/iid` 只代表当前排空的 anchor。

> SQ(6 项) 在提交前不被向量 store 占用，所以不会出现
> "提交等完成、完成等提交"死锁。

### 10.8 IDU 顶层接通

| 位置 | 改动 |
|---|---|
| `ct_idu_is_dp` | LSIQ create data 里带 `vec/load/store`（S7 已改），接 `lsiq_vec_create_*` 到 fill 引擎 |
| `ct_idu_is_lsiq` | 接 `lsiq_vec_upd_*`、`lsiq_vec_beat_rdy`、`lsiq_vec_old`、`lsu_idu_beat_done`、`vec_old_*` |
| `ct_idu_rf_dp` | pipe3/pipe4 的 opcode 用 anchor beat 的 synthetic opcode；`sdiq_entry` 用 beat 的；pipe5 数据 mux 加 `vec_sd_data` |
| `ct_idu_is_sdiq` | 接 fill 引擎的 `vec_sdiq_create_vld/entry`、`vec_sdiq_issue_entry`，pipe5 数据 mux |
| `ct_idu_top` | 例化 fill 引擎；接 LSU 写回（vec/uop_idx）、SQ pop（uop_idx）、commit、LQ/SQ full、old |
| `A910_cpu` | `vec_beat_rdy` 不再钉 0；commit/flush 送 fill 引擎 |

### 10.9 bridge 的 LSU 侧

- 把 RvvCore 的扁平 LSU 端口拼成 `rvv_lsu_uop` / `rvv_lsu_resp`；
- 只接 lane 0；
- `uop_lsu_ready_lsu2rvv[0]` 来自 fill 引擎；
- 返回侧 `rob_tag/uop_index/lsu_id` 原样透传。

### 10.10 S8 出口

```bash
make a910-elab
```

静态核对：

```bash
grep -n "lsiq_vec_upd\|vec_beat_rdy\|beat_done" \
  mySoC/idu_c910/rtl/ct_idu_top.sv mySoC/idu_c910/rtl/ct_idu_vec_ls_fill.sv
grep -n "rvv_lsu" mySoC/rvv_a910_bridge.sv mySoC/design/RvvCore.sv
grep -n "uop_idx" mySoC/lsu/rtl/lsu_ld_da.sv mySoC/lsu/rtl/lsu_ld_wb.sv
# 每一级都要有
```

**到这里 RTL 修改全部完成；S9 之前仍然不跑任何仿真。**

### 10.11 风险

- anchor 的 `uop_idx` 与 core `uop_index` 混淆 ⇒ load 拼错向量寄存器。
- 同一 beat 未 `beat_done` 就覆盖 beat 字段 ⇒ 地址/数据串。
- store staging 未在提交前挡住 `vec_beat_rdy` ⇒ 提交前写内存。
- load 写回 `uop_idx` 漏打一拍 ⇒ LQ 不 pop、引擎找不到请求。
- SDIQ 数据未及时捕获就复用 ⇒ store 数据被覆盖。
- 向量 L/S 的 page-fault/精确异常不在本方案范围（v1 顶部已声明）；
  fill 引擎只保证合法页内、非对齐拆成对齐 1/2/4B 请求。


---

## 11. S9 —— 收口与全量功能验证

### 11.1 先做三件收尾

1. **删 TB force**（否则仿真永远看不到 cmplt）：

```bash
grep -rn "force dut.cmplt_vld" tb/a910/
# 删除 tb/a910/tb_a910_smoke.sv:159-162
# 删除 tb/a910/tb_a910_difftest.sv:1112-1115
```

2. **asm 构建规则支持 RVV**：

全局把 `-march=rv32im_zicsr` 改成 `-march=rv32imv_zicsr`（Makefile:241）。
`rv32imv` 是 `rv32im` 的超集，既有标量用例的编码不变；务必确认工具链支持
V 扩展（`$(CROSS)gcc --target-help` 或直接编一条 `vsetvli` 试）。

3. **新建向量自检用例**（`asm/rvv_*.S`，末尾统一）：

```asm
    # ... 自检结果压进 a0 (x10)，a0 == 0 表示全对 ...
    addi x17, x0, 93
    ecall
    unimp
```

> `a910-run` 的 smoke TB 判据是 `a0==0` 且看到 `x17==93`；
> `a910-difftest` 的黄金模型只支持 RV32IM，**不能**用来判向量结果。

### 11.2 验证顺序（从便宜到贵，失败就地停下）

**第 1 层：结构/单元（分钟级）**

```bash
make rvv-elab
make a910-elab
make idu-unit
make lsu-unit
make rtu-unit
make rtu-adapter-unit
# 新增两个单元台（S9 建）：
#   tb_ct_idu_is_lsiq_vec_anchor：anchor create/agevec/beat_done/pop-last
#   tb_rvv_ls_fill：beat 生成/request index/staging
```

**第 2 层：标量零回归（最重要的一次测量）**

```bash
make a910-difftest-all
```

判据：与改动前的基线**逐项**一致，不能新增 FAIL。不要只看总数；基线取
**S0 之前**的 commit（`git worktree` 或单独 clone），不要拿 S8 自己当基线。
若有 FAIL：

1. 先查 S3（vset 写口/wakeup/preg_wb_mask）与 S7（anchor/pop 门控、
   `uop_idx` 贯通、vec 屏蔽）；
2. 用 `make a910-difftest TEST=<失败项> A910_DT_ARGS=+TRACE` 对比退休流；
3. 二分：先把 `idu_lsu_ld_vec/st_vec` 和 `vec_st_cmit` 钉回 0，再跑；若恢复，
   说明 S7/S8 的向量通路漏进了标量。

**第 3 层：向量计算（定向汇编）**

| 用例 | 覆盖 |
|---|---|
| `rvv_vset` | vsetvli/vsetivli/vsetvl，rs1=x0/非 0，rd=x0/非 0 |
| `rvv_alu` | `.vv/.vx/.vi`、饱和/比较/移位/扩展 |
| `rvv_mul` | VMUL/VMACC/VWMUL 等 |
| `rvv_mask` | VMSEQ/VMSLT/VMSBF/VMERGE 等（VCPOP/VFIRST 不在此列，见下） |
| `rvv_red` | 归约（含种子） |
| `rvv_backtoback` | 连续 vset + 消费者 + 背靠背向量指令 |
| `rvv_flush` | 向量指令前后误预测 |
| `rvv_illegal` | vmv.x.s / vfirst / vcpop / 非法 funct6 → 必须 trap，不能静默 |

**第 4 层：向量访存**

| 用例 | 覆盖 |
|---|---|
| `rvv_lsu` | unit-stride，VL=1/4/8/16，load/store |
| `rvv_strided` | 正负 stride |
| `rvv_indexed` | IU/IO（e8/e16/e32） |
| `rvv_mask_ls` | v0 mask 逐字节 |
| `rvv_flush_ls` | 误预测路径上的向量 L/S |
| `rvv_multi_beat` | 一个 core uop 拆成多个 A910 beat（e8 / 非对齐起始） |
| `rvv_age_order` | 向量 L/S 与标量 L/S 交错；检查 anchor 年龄与发射顺序 |
| `rvv_store_after_load` | 向量 store 后跟标量 load 同地址；检查 `old` 修正 |
| `rvv_lsu_long` | `MAX_CYCLES=2000000`，检查 LQ/SQ/anchor 不泄漏 |

**第 5 层：长跑（可选）**

```bash
make a910-run TEST=coremark MAX_CYCLES=15000000
```

### 11.3 收敛判据

- `rvv-elab` / `a910-elab`：Error=0，A910 侧新警告=0；
- 标量 difftest：与基线逐项一致；
- `doc/v-instruction.md` 列出的 ALU/MULMAC/PMTRDT/mask 指令定向用例全过；
- 向量 L/S 四类（unit/strided/indexed/mask）全过；
- `rvv_illegal` 反例全部 trap（不是静默退休）；
- 误预测 + 向量 L/S 用例通过；
- 长跑无 LQ/SQ/LSIQ 泄漏。

### 11.4 调试探针（只在 S9 使用）

| 探针 | 用途 |
|---|---|
| `dut.u_ct_idu_top.u_ct_idu_vecq.vecq_xx_issue_en` | 向量指令发射 |
| `dut.u_rvv_bridge.u_rvv_core.backend.u_rob.uop_done` | uop 完成 |
| `dut.u_rvv_bridge.cmt_wmk_iid` | 提交水位 |
| `dut.u_rvv_bridge.u_rvv_core.backend.u_vrf.vrf_reg` | VRF 内容 |
| `dut.u_lsu_top.ld_ag_dc_vec` | 向量访存进入流水 |
| `dut.u_lsu_top.lsu_idu_beat_done` | 非最后 beat 的完成脉冲 |
| `dut.u_ct_idu_top.u_ct_idu_vec_ls_fill.ctx[*].beat_ptr` | anchor 的 beat 游标 |
| `dut.u_ct_idu_top.u_ct_idu_is_lsiq.lsiq_entry*_vec` | anchor 表项/年龄图 |
| `dut.u_ct_idu_top.u_ct_idu_vecq.x_read_data` | VIQ head 内容 |

### 11.5 常见故障的第一反应

| 症状 | 先查 |
|---|---|
| 一条都不退休 | `cmplt_vld1/2` 有没有接、TB force 删没删 |
| 向量指令退休但结果错 | 源操作数影子（accept 后一拍）、VIQ 字段顺序 |
| vset 之后下游卡死 | `ct_idu_dep_reg_entry` 的 vset 唤醒漏了某个队列 |
| 标量回归 FAIL | S7 的 vec 屏蔽（PRF/唤醒/RTU/dealloc 四处） |
| 向量 load 卡死 | LQ 提前 pop、MSHR `uop_idx`、anchor 的 `frz` 是否在 `beat_done` 清 |
| 向量 store 卡死 | LMUL>4 是否被 trap、staging 是否等提交、SDIQ 是否可申请 |
| anchor 只发第一个 beat | `frz` 未清 / `beat_done` 未接 / `vec_beat_rdy` 未更新 |
| 同 iid 的第二个 beat 建不了表项 | LQ/MSHR/SQ 的 `inst_hit` 漏了 `uop_idx` |
| 非法指令静默通过 | S5 的 F0 过滤与 F1/F2 兜底是否接进 A910 异常口 |

---

## 附录 A —— 对 v1 的修正清单（按重要性排序）

| # | v1 的说法 | 实际情况 / 本计划的修正 |
|---|---|---|
| A1 | `trap_valid_o` 可以覆盖"core 解不出的指令" | `trap_valid_o` **只来自 frontend 的 vill 检查**（`RvvFrontEnd.sv:645-660`）；后端 `de2rt` 是 `trap_flag=0` 的假退休，不进内部 ROB。必须按 S5 在 bridge 监视 `rd_valid_rob2rt_o[NUM_RT_UOP +: NUM_DE_INST]` 和 `async_rd_valid`，否则要么静默退休要么卡死 |
| A2 | 不支持的指令走 A910 的 `illegal` | A910 的 `illegal` 不产生异常：`IU_alu_pipe.v:161` 只是 `ex2_wr <= idu_sel & ~idu_illegal`。不能依赖它 |
| A3 | VIQ 每拍最多 create 2 条 | v1 的 §3.6/§3.8 只定义了 create0；必须同时定义 create0/1 的 data/iid/sel（§4.2、§3.7） |
| A4 | ROB 完成链用 `inst_done_chain[i-1]` | 必须以 `uop_rptr` 起头、按槽位回绕；否则槽位回绕后链会断成 0，core 永不 cmplt（§6.2） |
| A5 | vset 写回用"accept 后一拍"的影子配 iid | core 可连续收多条指令，vset 完成可能晚几拍；必须用按 accept 顺序的 vset FIFO（§5.4） |
| A6 | `lsu` 侧 `rs1_data_valid` 不用改 | `rvv_backend_decode_unit_lsu_de2.sv:822-826` 在非 ZVT 下恒 0 ⇒ 向量基址恒 0。必须为 1（§8.3） |
| A7 | SDIQ 只加"旁路路径" | `ct_idu_is_sdiq.sv` 的 vld/agevec/issue/read mux/`has_in_sq` 全是硬编码 `[3:0]`；A 方案**不扩 4 项**，但要按 S7 §9.8 加向量 create/issue/数据 mux 旁路，且 dealloc 掩码只 OR 0~3 |
| A8 | `rvv_backend.svh` 在 `mySoC/design/` | 实际在 `mySoC/design/inc/rvv_backend.svh` |
| A9 | `ct_idu_id_dp.sv` IR_WIDTH 在 :53；`ct_idu_sq_entry.sv` cmit_set 在 :197 | 实际分别在 :47 和 :437（:197 是声明） |
| A10 | `src0_vld/src1_vld/dst_vld` 行号 :147/:150/:156 | 实际 :144/:148/:155 |
| A11 | v1 §5.2："pop 被门控后 VRF 写自然被门控" | retire 级直接看 `rd_valid_rob2rt` 写 VRF（`rvv_backend_retire.sv:172-180`）；只门控 FIFO 的 pop **挡不住**推测写。必须门控送给 retire 级的 valid（trap 表项放行），见 §6.2 |
| A12 | v1 §7.6：向量 SDIQ 数据固定 `{6'b0,1'b1}` | SDIQ create data 是 **8 位**（`SDIQ_WIDTH=8`），依赖编码在 `[7:1]`；7 位常量零扩展后 wb 位落到 bit0 ⇒ 表项永不 ready。正确值 `8'b0000_0010`，见 §9.8.1 |
| A13 | 用户 A 方案："只改 pop 和 inst_hit 两处" | 骨架正确，但实际还要补：IS 建 anchor（LSIQ create 仲裁 + `IS_CTRL_VMEM`）、`frz` 在 `beat_done` 清、`agevec/counter` 只在最后 pop 更新、beat 字段逐 beat 改写、`uop_idx` 贯通 LQ/MSHR/SQ/写回、store staging。只改两处会"第一个 beat 之后永久冻住"或"同 iid 后续 beat 建不了表项"，见 S7 §9.1、§9.11 |

> **A 方案取代了 v1 §7 的"4 个专用 tag 8~11 / LSIQ 8→12 / SDIQ 4→6 /
> 4-slot 独立引擎"**。保留下来的 v1 技术判断：向量不进标量计算队列、
> 提交门控、LQ 提前 pop、store staging、伪 preg/`uop_idx` 四处屏蔽、
> 同一个 LSU 单发射口。


---

## 附录 B —— 文件清单（按阶段）

**新增**

| 阶段 | 文件 |
|---|---|
| S2 | `mySoC/idu_c910/rtl/ct_idu_vecq.sv`、`ct_idu_vecq_entry.sv` |
| S3 | `mySoC/rvv_a910_bridge.sv` |
| S8 | `mySoC/idu_c910/rtl/ct_idu_vec_ls_fill.sv` |
| S9 | `asm/rvv_*.S` |

**修改（仅列首次改动阶段）**

| 阶段 | 文件 |
|---|---|
| S0 | `Makefile` |
| S1 | `ct_idu_id_decd.sv`、`ct_idu_id_dp.sv`、`ct_idu_ir_dp.sv`、`ct_idu_ir_ctrl.sv`、`ct_idu_is_ctrl.sv`、`ct_idu_is_dp.sv`、`ct_idu_is_pipe_entry.sv`、`ct_idu_top.sv` |
| S2 | `ct_idu_rf_prf_pregfile.sv`（读口）、`ct_idu_top.sv`、`A910_cpu.sv` |
| S3 | `ct_idu_rf_prf_pregfile.sv`（写口）、`ct_idu_rf_prf_gated_preg.sv`、`ct_idu_dep_reg_entry.sv` 及 6 个队列 entry、`A910_cpu.sv`、`mySoC/design/{RvvFrontEnd,RvvCore}.sv`、`mySoC/design/inc/rvv_backend.svh` |
| S4 | `rvv_backend_rob.sv`、`rvv_backend.sv`、`RvvCore.sv` |
| S5 | `rvv_backend.sv`（改名）、`A910_cpu.sv`、`rvv_a910_bridge.sv` |
| S6 | `rvv_backend.svh`、`rvv_backend_decode_unit_lsu*.sv`、`rvv_backend_dispatch.sv`、`rvv_backend_lsu_remap.sv`、`rvv_backend.sv`、`RvvCore.sv`、`RvvFrontEnd.sv` |
| S7 | `ct_idu_is_lsiq_entry.sv`、`ct_idu_is_lsiq.sv`、`ct_idu_ir_ctrl.sv`、`ct_idu_is_dp.sv`、`ct_idu_is_ctrl.sv`、`ct_idu_top.sv`、`lsu_top.sv`、`lsu_ld_ag/dc/da`, `lsu_st_ag/dc/da`, `lsu_lfb`, `lsu_ld_wb`, `lsu_st_wb`, `lsu_lq_entry`, `lsu_mshr_entry`, `lsu_sq_entry`、`RTU_idu_lsu_adapter.v`、`ct_idu_is_sdiq.sv`、`ct_idu_rf_dp.sv`、`A910_cpu.sv` |
| S8 | `ct_idu_vec_ls_fill.sv`、`ct_idu_top.sv`、`A910_cpu.sv`、`rvv_a910_bridge.sv`、`RvvCore.sv`、`ct_idu_is_sdiq.sv`、`ct_idu_rf_dp.sv` |
| S9 | `tb/a910/tb_a910_smoke.sv`、`tb/a910/tb_a910_difftest.sv`、`Makefile`、`asm/*` |

---

## 附录 C —— 阶段外的最小静态检查脚本

把下面存成 `scripts/rvv_stage_check.sh`，每个阶段结束跑一遍（只读，不改设计）：

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/.."

echo "== width copies =="
grep -rn "IR_WIDTH *=" mySoC/idu_c910/rtl || true
grep -rn "IS_WIDTH *=" mySoC/idu_c910/rtl || true
grep -rn "IS_CTRL_WIDTH *=" mySoC/idu_c910/rtl || true

echo "== old slices =="
grep -rn "\[122:0\]" mySoC/idu_c910/rtl || true
grep -rn "\[75:0\]"  mySoC/idu_c910/rtl || true

echo "== vset wakeup =="
grep -rn "ct_idu_dep_reg_entry" mySoC/idu_c910/rtl | wc -l
grep -rn "rvv_idu_vset_wb_preg_vld_dupx" mySoC/idu_c910/rtl | wc -l

echo "== vec masking =="
grep -rn "wb_pipe3_wb_preg_vec\|wb_pipe4_vec" mySoC/lsu/rtl mySoC/rtu/rtl || true

echo "== LSIQ/SDIQ still 8/4 (A scheme) =="
grep -n "LSIQ_ENTRY *= *8" mySoC/lsu/rtl/lsu_top.sv
grep -n "SDIQ_ENTRY *= *4" mySoC/lsu/rtl/lsu_top.sv

echo "== LSIQ width 61 =="
grep -rn "\[59:0\]" mySoC/idu_c910/rtl || true

echo "== anchor fields =="
grep -rn "VEC_BEAT_WIDTH\|vec_beat_rdy\|beat_done" \
  mySoC/idu_c910/rtl/ct_idu_is_lsiq_entry.sv mySoC/idu_c910/rtl/ct_idu_is_lsiq.sv || true
grep -rn "uop_idx" mySoC/lsu/rtl/lsu_lq_entry.sv mySoC/lsu/rtl/lsu_mshr_entry.sv \
  mySoC/lsu/rtl/lsu_sq_entry.sv || true

echo "== pop-last =="
grep -n "idu_pop_vld" mySoC/lsu/rtl/lsu_ld_da.sv mySoC/lsu/rtl/lsu_st_da.sv
# 每一处都应含 (!xx_vec || xx_last)

echo "== TB force =="
grep -rn "force dut.cmplt_vld" tb/a910/ || true
```

> 这个脚本只替代"人眼扫一遍"，不能替代 S9 的功能验证。

---

## 附录 D —— 不可破坏的不变量

1. 每条向量指令在 A910 ROB 里有且只有一个表项；非 vset 的 `rf_we=0`、
   `dst_preg=0`、`is_store=0`。
2. 向量计算指令一律不进标量队列；标量指令一律不进 VIQ。
   vector LOAD/STORE 例外：它在 LSIQ 里有且只有一个 anchor（A 方案）。
3. VIQ 按程序序喂 core（vtype 快照依赖程序序）。
4. VRF 的写只发生在对应 iid 已被 RTU 提交之后。
5. core 的完成脉冲在"所有 uop done"时发出，**早于**提交。
6. `rtu_yy_xx_flush` 到达时，core 已提交前缀先排空再全局清空。
7. `vec` 标记必须堵住四个泄漏点：PRF 写口、IDU 依赖唤醒、RTU preg 释放、
   SDIQ dealloc 掩码。
8. 同一条向量访存指令的多个 beat 共享 iid；LQ/MSHR/SQ 的去重与合并必须带
   `uop_idx`（A910 请求级唯一键）。
9. 向量 store 的元素在提交前只暂存、不访问内存；提交后再流入 LSU。
10. 每条进入 core 的指令都必须有完成回路（cmplt 或 trap），否则整核卡死。
11. anchor 在 `beat_last` 之前不 pop；`agevec/agevec_all/entry counter` 只在
    最后 beat 的 pop 上更新，`beat_done` 不更新。
12. anchor 的 `frz` 在 `beat_done` 清；非最后 beat 发射后不能被永久冻住。
13. vector load 的 beat 只在 anchor 是 LSIQ 最老项（`old=1`）时发射；LQ 提前
    pop 再带 `lq_entry_old` 兜底（否则更老 store 晚到 DC 会丢 RAW）。
14. request index 只在对应 LQ/SQ 表项弹出后释放；store 不能在"数据捕获"时
    释放（SQ 表项还带着 `uop_idx` 活着）。

---

*本计划只描述"怎么改"，不在阶段间做功能验证。所有仿真、波形、difftest、
性能测试集中在 S9。*
