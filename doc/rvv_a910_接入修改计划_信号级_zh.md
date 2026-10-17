# A910 接入 coralnpu RVV core —— 信号级修改计划书

> 版本：v1.1（2026-10-17）
> 范围：IDU 向量识别与发射队列、RVV core 接入、完成/提交/冲刷、vaiq/vmacq/vpq 命名、
> 向量 load/store 经 IDU 拆解后走 A910 LSU。
> 不在范围：向量寄存器重命名、浮点/Zvt、精确异常、`vmv.x.s/vfirst/vcpop`。
>
> **2026-10-17 修订（A 方案）**：向量 load/store 改为 **LSIQ anchor + VPU 逐
> beat 填充**。原"4 个向量专用 LSIQ tag（8~11）+ 独立 4-slot 引擎"作废；
> LSIQ 保持 8 项、SDIQ 保持 4 项，agevec/old/发射顺序复用。详见 §7。
>
> **2026-10-17 修订 2（S3b，与分阶段执行计划同步）**：
> - RVV core 固定 **N=1**（单发射）；整个通路的**唯一指令缓冲**是 IDU 的
>   `ct_idu_vecq`。本文所有 `core_inst_*[3:0]` / `core_reg_read_*[7:0]` 一律按
>   **1 lane** 理解，后端 RVVCmd 命令队列保留（它解耦的是已译码命令的发射）。
> - **标量源就绪的归属**：
>   - `vset*` 不进入后端，仍由 VIQ 的 `ct_idu_dep_reg_entry` 门控发射；
>   - 其余向量**计算**指令由 VIQ **立即发射**（只看 valid + core 容量），标量源
>     在 **RVV 后端的 ALU/MUL/DIV/PMT 保留站**里等：bridge 把源 preg/iid/wb +
>     5 路 A910 标量写回（IU pipe0/1/2、LSU pipe3、vset）送进 core，backend 用
>     **按 A910 iid 的等待表**捕获 issue 后的第一次 WB，RS 发车时读表；
>   - 向量 **L/S 的基址等待放在 A910 LSIQ anchor**（P5），RVV 只送向量侧信息。
> - 具体字段与坑见分阶段计划 §4（S2 修订）、§5.6a（S3b），以及本文 §3.7/§4.7。
>
> 本文所有"现状"均按当前工作树逐个文件核对，给出文件:行号。**本计划不删除任何
> 现有信号**；所有改动只有两类：**新增信号** 与 **位宽扩展**。

---

## 0. 命名约定

| 前缀 | 含义 |
|---|---|
| `idu_vec_*` | IDU 侧向量通路（VIQ→bridge、bridge→IDU） |
| `rvv_*` | bridge 与 core / RTU 之间 |
| `vec_*` | 向量访存 fill 引擎/anchor 内部信号（beat、uop_idx、staging） |
| `core_*` | bridge 内部连 `RvvCore` 的信号 |
| `_v` / `_x` | 沿用 C910 风格：`_v`=组合值，`_x`=组合条件；本计划新增信号不强制后缀 |

阶段标记：**[P0]** 编译基线、**[P1]** IDU 识别与 VIQ、**[P2]** core 接入与 vset 写回、
**[P3]** 完成/提交门控/冲刷、**[P4]** 计算类、**[P5]** 向量访存。

---

## 1. 跨模块新增接口总览

### 1.1 IDU → bridge（VIQ 头 → RvvCore 指令入口）

**VIQ：IS 每拍最多写入 2 条，VIQ 每拍发射 1 条给 core。**
因此 IDU→bridge 仍是单车道；core 的 `inst_ready[0]` 直接反压 VIQ。

| 信号 | 位宽 | 方向 | 来源 → 去向 | 阶段 |
|---|---|---|---|---|
| `idu_vec_inst_valid` | 1 | IDU→bridge | VIQ head 有效 | P2 |
| `idu_vec_inst_iid[6:0]` | 7 | IDU→bridge | VIQ 表项 iid（A910 rob iid） | P2 |
| `idu_vec_inst_pc[31:0]` | 32 | IDU→bridge | VIQ 表项 pc | P2 |
| `idu_vec_inst_opcode[1:0]` | 2 | IDU→bridge | `RVVOpCode`：0=LOAD 1=STORE 2=RVV | P2 |
| `idu_vec_inst_bits[24:0]` | 25 | IDU→bridge | `inst[31:7]` | P2 |
| `idu_vec_src0_vld` | 1 | IDU→bridge | VIQ 表项 src0 有效 | P2 |
| `idu_vec_src0_data[31:0]` | 32 | IDU→bridge | VIQ head 的 src0 在 PRF 中的值（含同拍 WB 旁路） | P2 |
| `idu_vec_src0_preg[5:0]` | 6 | IDU→bridge | VIQ 表项的 src0 物理号 | S3b |
| `idu_vec_src0_wb` | 1 | IDU→bridge | issue 时 dep entry 的**当前** wb（不是建表快照） | S3b |
| `idu_vec_src1_vld` | 1 | IDU→bridge | VIQ 表项 src1 有效 | P2 |
| `idu_vec_src1_data[31:0]` | 32 | IDU→bridge | VIQ head 的 src1 在 PRF 中的值（含同拍 WB 旁路） | P2 |
| `idu_vec_src1_preg[5:0]` | 6 | IDU→bridge | VIQ 表项的 src1 物理号 | S3b |
| `idu_vec_src1_wb` | 1 | IDU→bridge | issue 时 dep entry 的**当前** wb | S3b |
| `idu_vec_dst_preg[5:0]` | 6 | IDU→bridge | vset* 的 rd 物理号；非 vset 恒 0 | P2 |
| `idu_vec_dst_vld` | 1 | IDU→bridge | vset* 且 rd!=x0 | P2 |
| `idu_vec_dst_reg[4:0]` | 5 | IDU→bridge | 架构 rd（仅供断言/波形） | P2 |
| `rvv_vec_inst_ready` | 1 | bridge→IDU | `RvvCore.inst_ready[0]`，反压 VIQ | P2 |

> 单发射口 ⇒ 每拍最多一个 vset 完成脉冲，PRF 只加 1 个写口、cmplt 口只需 1 路。
> 标量操作数由 VIQ head 直接驱动 2 个 PRF 读口读出（见 §3.7/§4.3），
> **不需要** 3 组读口。
>
> **S3b 补充**：core 侧不再等源 ready；bridge 还必须接收 **5 路 A910 标量写回**
> `{vld, preg[5:0], data[31:0]}`（IU pipe0/1/2、LSU pipe3、vset），用于后端
> RS 的迟到写回捕获。VIQ head 读 PRF 时还要做**同拍写回旁路**：dep entry 在
> WB 当拍就报 ready，但 PRF 写是寄存器 ⇒ 组合读仍是旧值，源 preg 命中 WB 时
> 直接用 WB 数据。

### 1.2 bridge → IDU（vset 的 rd 写回 + vxsat 回存）

| 信号 | 位宽 | 方向 | 阶段 |
|---|---|---|---|
| `rvv_idu_vset_wb_vld` | 1 | bridge→IDU | P2 |
| `rvv_idu_vset_wb_preg[5:0]` | 6 | bridge→IDU | P2 |
| `rvv_idu_vset_wb_data[31:0]` | 32 | bridge→IDU | P2 |
| `rvv_idu_vset_wb_iid[6:0]` | 7 | bridge→IDU | P2 |

### 1.3 bridge ↔ RTU

| 信号 | 位宽 | 方向 | 说明 | 阶段 |
|---|---|---|---|---|
| `cmplt_vld1` / `cmplt_iid1[6:0]` | 1/7 | bridge→RTU | 向量计算/访存指令完成（现状未驱动，`A910_cpu.sv:544-547`） | P3 |
| `cmplt_vld2` / `cmplt_iid2[6:0]` | 1/7 | bridge→RTU | vset* 完成 | P2 |
| `rtu_yy_xx_commit{0,1,2}` | 1 | RTU→bridge | 提交脉冲（现状已存在） | P3 |
| `rtu_yy_xx_commit{0,1,2}_iid[6:0]` | 7 | RTU→bridge | 提交 iid（现状已存在） | P3 |
| `rtu_yy_xx_flush` | 1 | RTU→bridge | 冲刷（现状已存在） | P3 |
| `rtu_yy_xx_wb_preg_mask[63:0]`（复用 `preg_wb_mask`） | 64 | IDU/bridge→RTU | vset 写回必须并进 RTU 写回门（见 §3.4） | P2 |

### 1.4 bridge ↔ IDU fill 引擎（P5）

| 信号 | 位宽 | 方向 | 阶段 |
|---|---|---|---|
| `rvv_lsu_uop_valid` | 1 | core/bridge→IDU | P5 |
| `rvv_lsu_uop[UOP_RVV2LSU_W-1:0]` | 扩展后结构（含 `rob_tag/uop_index/lsu_id/addr/data/eew/vl/last`） | core/bridge→IDU | P5 |
| `rvv_lsu_uop_ready` | 1 | IDU→core/bridge | P5 |
| `rvv_lsu_resp_valid` | 1 | IDU→core/bridge | P5 |
| `rvv_lsu_resp[UOP_LSU2RVV_W-1:0]` | 扩展后结构（含 `rob_tag/uop_index/lsu_id`） | IDU→core/bridge | P5 |
| `rvv_lsu_resp_ready` | 1 | core/bridge→IDU | P5 |

### 1.5 LSIQ anchor ↔ LSU（P5）

> **LSIQ 保持 8 项，SDIQ 保持 4 项**。vector L/S 在 IS 派发时创建 LSIQ
> anchor；以下信号是 anchor 的 beat 字段贯通 LSU 流水的部分。

| 信号 | 位宽 | 方向 | 阶段 |
|---|---|---|---|
| `idu_lsu_ld_vec` / `idu_lsu_st_vec` | 1 | IDU→LSU | P5 |
| `idu_lsu_ld_uop_idx[4:0]` / `idu_lsu_st_uop_idx[4:0]` | 5 | IDU→LSU | P5 |
| `idu_lsu_ld_last` / `idu_lsu_st_last` | 1 | IDU→LSU | P5 |
| `lsu_idu_beat_done[LSIQ_ENTRY-1:0]` | 8 | LSU→IDU | P5 |
| `lsu_idu_wb_pipe3_wb_preg_vec` | 1 | LSU→IDU | P5 |
| `lsu_idu_wb_pipe3_wb_uop_idx[4:0]` | 5 | LSU→IDU | P5 |
| `lsu_rtu_wb_pipe3_wb_preg_vec` | 1 | LSU→RTU（经适配层屏蔽） | P5 |
| `lsu_rtu_wb_pipe4_vec` | 1 | LSU→RTU（经适配层屏蔽） | P5 |
| `vec_st_cmit_vld` / `vec_st_cmit_iid[6:0]` | 1/7 | fill 引擎→SQ（**电平**，保持到排空结束） | P5 |
| `vec_sdiq_create_vld` / `vec_sdiq_create_entry[3:0]` | 1/4 | fill 引擎↔SDIQ | P5 |
| `vec_sdiq_issue_entry[3:0]` / `vec_sd_data[31:0]` | 4/32 | fill 引擎→IDU pipe5 | P5 |

> 不再有 `vec_lsu_sel`/`12 位 LSIQ tag`/`tag 8~11` 这些信号。

---

## 2. [P0] 编译基线（无 RTL 信号改动）

### 2.1 文件

- 新增目录 `mySoC/design/inc/`：9 个 `rvv_backend*.svh`（已拷贝）。
- 新增目录 `mySoC/design/common/`：20 个原语 `.sv`，**排除 `fp_add.sv`**（已拷贝）。
- 不拷贝 `Zvt/` 进文件表；不定义 `ZVE32F_ON/ZVT_ON/ARBITER_ON/DISPATCH3/PRECISE_RVVTRAP`。

### 2.2 Makefile 新增变量

| 变量 | 内容 |
|---|---|
| `RVV_DESIGN` | `$(wildcard $(PWD)/mySoC/design/*.sv)` |
| `RVV_DROP` | `rvv_backend_falu.sv rvv_backend_falu_unit.sv rvv_backend_fdiv.sv rvv_backend_fdiv_unit.sv rvv_backend_fdiv_wrapper.sv rvv_backend_freduction.sv rvv_backend_sqrt7_rec7.sv` |
| `RVV_SRC` | `$(filter-out $(RVV_DROP),$(RVV_DESIGN))` |
| `RVV_COMMON` | `$(wildcard $(PWD)/mySoC/design/common/*.sv)` |
| `RVV_INC` | `+incdir+$(PWD)/mySoC/design/inc` |
| `RVV_DEFS` | `+define+VLEN_128 +define+RTBUF_DEPTH=128`（后者把 `ROB_TAG_WIDTH` 变 7） |

- `A910_SRC`（`Makefile:736-743`）追加 `$(RVV_SRC) $(RVV_COMMON)`。
- `a910-elab` / `a910-run` / `a910-difftest` 的 VCS 命令追加 `$(RVV_INC) $(RVV_DEFS)`。
- 新增 `rvv-elab` 目标：`-top RvvCore`，先 `rm -rf simv.daidir`（沿用现有防陈旧做法）。
- `a910-elab` 的 IWNF/DCTTSW 计数限定到 A910 自己的文件，RVV 警告只打印。

### 2.3 出口

```bash
make rvv-elab && make a910-elab && make idu-unit && make lsu-unit
```

---

## 3. [P1] IDU 向量识别与向量指令队列

### 3.1 `mySoC/idu_c910/rtl/ct_idu_id_decd.sv`

**新增端口**

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `vec` | output | 1 | 是向量指令（LOAD/STORE/RVV 任一） |
| `vec_type` | output | 2 | `2'b01`=向量 LOAD，`2'b10`=向量 STORE，`2'b11`=RVV（含 vset*），`2'b00`=非向量 |

**新增内部 wire**

```systemverilog
wire op_vload  = (opcode == 7'b0000111);  // LOAD-FP
wire op_vstore = (opcode == 7'b0100111);  // STORE-FP
wire op_rvv    = (opcode == 7'b1010111);  // OP-V / vset
wire is_vset   = op_rvv && (funct3 == 3'b111) &&
                 ((inst[31] == 1'b0) || (inst[31:30] == 2'b11) ||
                  (inst[31:25] == 7'b1000000));
wire is_vstride = (op_vload || op_vstore) && (inst[27:26] == 2'b10);
wire is_vsrc1   = is_vstride || (op_rvv && (inst[31:25] == 7'b1000000));
```

**修改的现有信号（表达式）**

| 信号 | 现状 | 改为 |
|---|---|---|
| `valid_inst` (:134-135) | 仅 RV32I/M | 追加 `\|\| op_vload \|\| op_vstore \|\| op_rvv` |
| `illegal` (:138) | `!valid_inst \|\| op_fence \|\| op_system` | 不变（向量已进 valid_inst） |
| `src0_vld` (:147) | 标量源 | `\|\| op_vload \|\| op_vstore \|\| (op_rvv && inst[31]!=0 && !is_vset_ivli)` |
| `src1_vld` (:150) | 标量源 | `\|\| is_vsrc1` |
| `dst_vld` (:156) | 标量目的 | `\|\| (is_vset && rd != 5'b0)` |
| `dst_x0` (:157) | `rd==0` | 非 vset 向量强制 1：`(rd==0) \|\| (vec && !is_vset)` |
| `inst_type[5:0]` | 6 个 one-hot | 向量恒 0（**不加任何位**） |

**输出赋值**

```systemverilog
assign vec      = op_vload | op_vstore | op_rvv;
assign vec_type = op_rvv ? 2'b11 : op_vstore ? 2'b10 : op_vload ? 2'b01 : 2'b00;
```

> `vsetivli` 无 rs1/rs2（`inst[31:30]==2'b11`）；`vsetvli/vsetvl` 的 rs1=x0 时
> `src0_vld` 也应为 1（AVL 取 0/vl），但读到的 pregs 是 x0，天然 ready。
> 具体表达式在实现时按 `RvvFrontEnd.sv:183-243` 的 vset 判定对齐。

### 3.2 `ct_idu_id_dp.sv`（ID→IR 流水寄存器）

**位宽改动（增，不删）**

| 信号/参数 | 现状 | 改为 |
|---|---|---|
| `IR_WIDTH` (:53) | 123 | **126** |
| 新增 `IR_VEC` | — | 123 |
| 新增 `IR_VEC_TYPE` | — | 125:124 |
| `dp_id_pipedown_inst{0,1,2}_data` 端口 | `[122:0]` | `[125:0]` |
| `dp_id_pipedown_inst{0,1,2}_data_raw` | `[122:0]` | `[125:0]` |

**拼装改动**（3 处 `assign dp_id_pipedown_inst{k}_data_raw = {...}`，`:264-300`）
在花括号最前面追加 3 个字段：

```systemverilog
{ id_inst{k}_vec_type, id_inst{k}_vec,   // IR[125:123]
  id_inst{k}_taken, id_inst{k}_npc, ... }
```

**新增内部信号**：`id_inst{0,1,2}_vec`、`id_inst{0,1,2}_vec_type[1:0]`，
并接到新例化的 3 个 `ct_idu_id_decd` 的 `vec/vec_type` 端口。

> `ct_idu_id_ctrl.sv` **不改**：它只处理 vld/accept_num，不搬数据。

### 3.3 `ct_idu_ir_dp.sv`（IR 级）

**位宽改动**

| 信号/参数 | 现状 | 改为 |
|---|---|---|
| `IR_WIDTH` | 123 | 126 |
| `IR_VEC` / `IR_VEC_TYPE` | — | 123 / 125:124 |
| `crtl_ir_inst2_data` 端口 | `[122:0]` | `[125:0]` |
| `dp_id_pipedown_inst{0,1,2}_data` 端口 | `[122:0]` | `[125:0]` |
| `dp_ctrl_ir_inst{0,1,2}_ctrl_info` 端口 | `[6:0]` | `[8:0]` |
| `IS_CTRL_WIDTH` | 7 | **9** |
| 新增 `IS_CTRL_VEC` | — | **7** |
| 新增 `IS_CTRL_VMEM` | — | **8**（vector L/S：P5 用它把 anchor 送进 LSIQ） |
| `IS_WIDTH`（`dp_ir_inst*_data`） | 76 | **79** |
| 新增 `IS_VEC` / `IS_VEC_TYPE` | — | 76 / 78:77 |

**信号改动**

- 新增内部：`ir_inst{0,1,2}_vec`、`ir_inst{0,1,2}_vec_type[1:0]`，
  取自 `ir_inst{k}_data[IR_VEC]` / `[IR_VEC_TYPE]`。
- `dp_ctrl_ir_inst{k}_ctrl_info[IS_CTRL_VEC] = ir_inst{k}_vec`；
  `dp_ctrl_ir_inst{k}_ctrl_info[IS_CTRL_VMEM] = ir_inst{k}_vec &&
      (ir_inst{k}_vec_type == 2'b01 || ir_inst{k}_vec_type == 2'b10)`；
  其余 7 位不变。
- `dp_ir_inst{k}_data` 的拼装（`:463-695`）在最高位追加
  `{ir_inst{k}_vec_type, ir_inst{k}_vec}`，其余字段偏移不变。
- `ct_idu_ir_decd.sv` **不改**：向量位来自 IR[123]，不需要在 IR 级重译 opcode。

### 3.4 `ct_idu_ir_ctrl.sv`

**新增端口**

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `dp_ctrl_ir_inst{0,1,2}_ctrl_info` | input | `[6:0]`→`[8:0]` | 位宽扩展 |
| `ctrl_ir_pre_dis_vec_create0_en` | output | 1 | 向量队列 create0 使能 |
| `ctrl_ir_pre_dis_vec_create0_sel` | output | 2 | 装的是三条车道里的哪一条 |

**新增内部信号**

```systemverilog
logic [14:0] ir_pipedown_inst0/1/2_ctrl_info;   // 13 → 15（bit7=vec，bit8=vmem）
logic        ctrl_ir_inst{0,1,2}_vec;
logic        ctrl_ir_pre_dis_inst{0,1,2}_vec;
logic        ctrl_ir_pre_dis_3_vec_inst;
logic        ctrl_ir_pre_dis_vec_create0_sel_inst0/inst1;
```

**修改的现有信号（P1 先全部加 `&& !vec`；P5 再把 lsiq 放行 vmem）**

```systemverilog
ctrl_ir_inst{k}_aiq  = ... && !ctrl_ir_inst{k}_vec;
ctrl_ir_inst{k}_mult = ... && !ctrl_ir_inst{k}_vec;
ctrl_ir_inst{k}_div  = ... && !ctrl_ir_inst{k}_vec;
ctrl_ir_inst{k}_biq  = ... && !ctrl_ir_inst{k}_vec;
ctrl_ir_inst{k}_sdiq = ... && !ctrl_ir_inst{k}_vec;

// P1：
ctrl_ir_inst{k}_lsiq = ... && !ctrl_ir_inst{k}_vec;
// P5（A 方案 anchor）：改成
// ctrl_ir_inst{k}_lsiq = (原标量 LSU 项) || ctrl_ir_inst{k}_vmem;
// 其中 vmem = ir_pipedown_inst{k}_ctrl_info[IS_CTRL_VMEM]
```

> 这条 P5 改动是 anchor 能在 IS 派发时创建 LSIQ 表项的前提。
> `ctrl_ir_pre_dis_3_lsiq_inst` 自动把 vector L/S 计入"同拍 3 条 LSIQ"的
> pipedown2 stall，保证 agevec 连续。

> 注意：`IS_CTRL_ILLEGAL` 仍拼进 aiq（`:315`），但向量指令的 `illegal` 已为 0。

**新增仲裁（照抄 AIQ 的 `:444-489`）**

```systemverilog
assign ctrl_ir_pre_dis_inst{k}_vec = ctrl_ir_pre_dis_inst{k}_vld && ctrl_ir_inst{k}_vec;
// 同拍只建一条：inst0 优先，其次 inst1，其次 inst2
```

**修改的现有信号**：`ctrl_ir_pre_dis_3_vec_inst` 加入
`ctrl_ir_pre_dis_type_stall_pipedown2` 的 OR 链（保证同拍只放一条向量）。

### 3.5 `ct_idu_is_ctrl.sv`

**新增端口**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `ctrl_ir_pre_dis_inst{0,1,2}_vec` | input | 1 each |
| `ctrl_ir_pre_dis_vec_create0_en` / `_sel[1:0]` | input | 1 / 2 |
| `ctrl_ir_pre_dis_vec_create1_en` / `_sel[1:0]` | input | 1 / 2 |
| `vecq_ctrl_1_left_updt` | input | 1 |
| `vecq_ctrl_full_updt` | input | 1 |
| `ctrl_vec_create0_en` / `ctrl_dp_is_dis_vec_create0_sel` | output | 1 / 2 |
| `ctrl_vec_create1_en` / `ctrl_dp_is_dis_vec_create1_sel` | output | 1 / 2 |
| `ctrl_dp_dis_inst{0,1,2}_vec` | output | 1 each |

**新增内部寄存器**：`is_dis_vec_create0/1_en`、`is_dis_vec_create0/1_sel[1:0]`、
`is_dis_vec_create0/1_en_updt`。在现有 `always_ff` 的
**reset / flush / stall / update** 四个分支里同步更新
（与 `is_dis_aiq_create0/1_en/sel` 同款，见 `:257-402`）。

**修改的现有信号**

```systemverilog
// create 使能（与 AIQ 同款，:435-439）
assign ctrl_vec_create0_en = is_dis_vec_create0_en && !ctrl_is_dis_stall;
assign ctrl_vec_create1_en = is_dis_vec_create1_en && !ctrl_is_dis_stall;

// 满判据（照抄 AIQ 的 :524-553）
assign ctrl_is_vecq_full_updt =
          (is_dis_vec_create0_en_updt && vecq_ctrl_full_updt)
       || (is_dis_vec_create1_en_updt && vecq_ctrl_1_left_updt);

// 汇入全局
assign ctrl_is_iq_full_updt = ... || ctrl_is_vecq_full_updt;
```

- `ctrl_ir_pre_dis_vec_create0/1_sel` 的仲裁**照抄 AIQ 的 `:444-489`**：
  create0 取最老的向量车道，create1 取次老的；同拍 3 条都是向量时，
  由 `ctrl_ir_pre_dis_3_vec_inst`（§3.4）把最年轻的一条 stall 到下一拍。
- `ctrl_is_dis_stall = ctrl_is_rob_full || ctrl_is_iq_full`（`:574-580`）自然覆盖。

### 3.6 `ct_idu_is_dp.sv`

**位宽改动**

| 信号/参数 | 现状 | 改为 |
|---|---|---|
| `IS_WIDTH` | 76 | 79 |
| `dp_ir_inst{0,1,2}_data` 端口 | `[75:0]` | `[78:0]` |
| `dp_is_dis_inst{0,1,2}_data` 端口 | `[75:0]` | `[78:0]` |
| 新增 `IS_VEC` / `IS_VEC_TYPE` | — | 76 / 78:77 |

**新增端口**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `ctrl_dp_is_dis_vec_create0_sel` | input | 2 |
| `dp_vec_create0_data` | output | `[VIQ_WIDTH-1:0]`（101，见 §3.7） |
| `dp_vec_create0_iid` | output | `[6:0]` |
| `dp_ctrl_is_inst{0,1,2}_vec` | output | 1 each |

**新增内部信号**：`is_inst{0,1,2}_vec`、`is_inst{0,1,2}_vec_type[1:0]`、
`is_inst{0,1,2}_create_vec_data[VIQ_WIDTH-1:0]`。

**组装规则**

```systemverilog
// 三车道按 ctrl_dp_is_dis_vec_create0_sel 做 mux（照抄 AIQ 的 :443-497）
// 每车道:
is_inst{k}_create_vec_data = { is_inst{k}_read_pc[31:0],          // VIQ[100:69]
                               is_inst{k}_read_data[IS_OPCODE+:32],// VIQ[68:37]
                               is_inst{k}_iid[6:0],               // VIQ[36:30]
                               is_inst{k}_read_data[IS_VEC_TYPE+:2],
                               is_inst{k}_read_data[IS_DST_PREG+:6],
                               is_inst{k}_read_data[IS_DST_REG+:5],
                               is_inst{k}_read_data[IS_DST_VLD],
                               is_inst{k}_read_data[IS_SRC1_DATA+:7],
                               is_inst{k}_read_data[IS_SRC0_DATA+:7],
                               is_inst{k}_read_data[IS_SRC1_VLD],
                               is_inst{k}_read_data[IS_SRC0_VLD] };
```

**修改的现有信号**：`dp_is_dis_inst{k}_chk`
改为 `is_inst{k}_vec ? 25'd0 : is_inst{k}_read_chk`（向量指令不带预测快照）。

**`ct_idu_is_pipe_entry.sv`（IS 流水寄存器）同步扩宽**

| 信号/参数 | 现状 | 改为 |
|---|---|---|
| `IS_WIDTH` | 76 | 79 |
| `x_create_data` 端口 | `[75:0]` | `[78:0]` |
| `x_read_data` 端口 | `[75:0]` | `[78:0]` |
| 新增 `IS_VEC` / `IS_VEC_TYPE` | — | 76 / 78:77 |

该模块被 `ct_idu_is_dp.sv:336/357/378` 例化三份，端口位宽随参数同步。
其余六个队列（AIQ/BIQ/LSIQ/SDIQ/MD×2）的 create 数据只取 ≤75 位，**位宽不变**。

### 3.7 新文件 `ct_idu_vecq.sv` + `ct_idu_vecq_entry.sv`

**表项位域（唯一定义）**

```systemverilog
parameter VIQ_WIDTH     = 101;
parameter VIQ_PC        = 100;  // [100:69]
parameter VIQ_OPCODE    = 68;   // [68:37]
parameter VIQ_IID       = 36;   // [36:30]
parameter VIQ_VEC_TYPE  = 29;   // [29:28]
parameter VIQ_DST_PREG  = 27;   // [27:22]
parameter VIQ_DST_REG   = 21;   // [21:17]
parameter VIQ_DST_VLD   = 16;
parameter VIQ_SRC1_DATA = 15;   // [15:9] = {preg[5:0], wb}
parameter VIQ_SRC0_DATA = 8;    // [8:2]
parameter VIQ_SRC1_VLD  = 1;
parameter VIQ_SRC0_VLD  = 0;
```

**`ct_idu_vecq_entry` 端口**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `cpurst_b`, `forever_cpuclk`, `rtu_yy_xx_flush` | input | 1 |
| `iu_idu_ex2_pipe0/1/2_wb_preg_dupx` + `_vld_dupx` | input | 6 / 1 |
| `lsu_idu_wb_pipe3_wb_preg_dupx` + `_vld_dupx` | input | 6 / 1 |
| `rvv_idu_vset_wb_preg` + `rvv_idu_vset_wb_vld` | input | 6 / 1（P2 第 5 路唤醒） |
| `x_create_data` | input | `[VIQ_WIDTH-1:0]` |
| `x_create_en` | input | 1 |
| `x_read_data` | output | `[VIQ_WIDTH-1:0]` |
| `x_rdy` | output | 1 |
| `x_vld` | output | 1 |
| `x_src0_wb` / `x_src1_wb` | output | 1 each（S3b：dep entry 的**当前** wb） |

内部：`vld`、`dst_preg[5:0]`、`opcode[31:0]`、`iid[6:0]`、`vec_type[1:0]`、
`src0_vld/src1_vld`、`dst_vld`、两个 `ct_idu_dep_reg_entry`。

> 无标量源的源编码强制为 `7'b0000001`（preg0 + ready），保证立即就绪。

**`ct_idu_vecq` 端口（2 入 / 1 出）**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `vecq_ctrl_1_left_updt`, `vecq_ctrl_full_updt` | output | 1 |
| `vecq_xx_issue_en` | output | 1 |
| `vecq_dp_issue_data` | output | `[VIQ_WIDTH-1:0]` |
| `vecq_dp_issue_src0_wb` / `src1_wb` | output | 1 each（S3b：当前 wb，不是建表快照） |
| `cpurst_b`, `forever_cpuclk` | input | 1 |
| `ctrl_vec_create0_en` / `ctrl_vec_create1_en` | input | 1 each |
| `dp_vec_create0_data` / `dp_vec_create1_data` | input | `VIQ_WIDTH` each |
| `rtu_yy_xx_flush` | input | 1 |
| 三路 IU + LSU pipe3 写回 snoop | input | 同 entry |
| `rvv_idu_vset_wb_preg/vld` | input | 6/1 |
| `vecq_prf_rd_addr0/1` | output | 6 each |
| `vecq_prf_rd_data0/1` | input | 32 each |

**队列规格与发射规则**

- 4~8 项按序 FIFO，首版 **4 项**（与 AIQ 同深），计数器产生
  `vecq_ctrl_1_left_updt`（只剩 1 空位）与 `vecq_ctrl_full_updt`（满）。
- **create**：每拍最多 2 条（create0 较老、create1 较年轻），按程序序入队。
- **issue（S3b 修订）**：只从 head 发 1 条：
  ```systemverilog
  head_is_vset   = (head_opcode == 7'b1010111) && (head_funct3 == 3'b111);
  vecq_xx_issue_en = entry_vld &&
                     (!head_is_vset || entry_rdy);   // 只有 vset 等源 ready
  ```
  与 `rvv_vec_inst_ready` 相与后才 pop。非 vset 计算指令立即发射，源在 RVV
  后端 RS 等（§4.7）；向量 L/S 立即发射，基址等待在 LSIQ（§7）。
- **操作数**：head 的 `VIQ_SRC0_DATA[6:1]` / `VIQ_SRC1_DATA[6:1]` 直接驱动
  PRF 的 2 个新读口，读出的 `vecq_prf_rd_data0/1` 就是送给 bridge 的
  `src0_data/src1_data`。**不需要抓取寄存器**（单发射口，值在 issue 拍稳定）。
  `srcX_vld=0` 时把读地址接到 0，读值丢弃。
  - ⚠️ 源在 issue 当拍写回时 PRF 组合读还是旧值（PRF 写是寄存器），top 必须
    用 5 路 WB 对 `srcX_data` 做**同拍旁路**。
  - ⚠️ 送 core 的 `srcX_wb` 必须取 `entry` 的 `x_srcX_wb`（dep entry 实时值），
    不能取 101 位表项里的建表快照。
- **依赖**：每表项两个 `ct_idu_dep_reg_entry`。**只有 vset 的发射用
  `x_rdy = vld && src0_rdy && src1_rdy`**；非 vset 的 dep entry 仍然保留，
  用于提供当前 wb（`x_srcX_wb`）和 flush 语义。
- **flush**：`rtu_yy_xx_flush` 清空全部表项（与 AIQ 一致）。

### 3.8 `ct_idu_top.sv`

**新增端口**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `idu_vec_inst_valid` | output | 1 |
| `idu_vec_inst_iid` | output | 7 |
| `idu_vec_inst_pc` | output | 32 |
| `idu_vec_inst_opcode` | output | 2 |
| `idu_vec_inst_bits` | output | 25 |
| `idu_vec_src0_vld` / `idu_vec_src0_data` | output | 1 / 32 |
| `idu_vec_src1_vld` / `idu_vec_src1_data` | output | 1 / 32 |
| `idu_vec_dst_preg` | output | 6 |
| `idu_vec_dst_vld` | output | 1 |
| `idu_vec_dst_reg` | output | 5 |
| `rvv_vec_inst_ready` | input | 1 |
| `rvv_idu_vset_wb_vld` | input | 1 |
| `rvv_idu_vset_wb_preg` | input | 6 |
| `rvv_idu_vset_wb_data` | input | 32 |
| `rvv_idu_vset_wb_iid` | input | 7 |

> `src0_data/src1_data` 直接来自 VIQ head 驱动的 2 个 PRF 读口
> （在 `ct_idu_top` 内部连线），不是额外寄存器。

**内部新增**

- 例化 `ct_idu_vecq u_ct_idu_vecq`。
- 例化/连线改动：`ct_idu_ir_dp`、`ct_idu_ir_ctrl`、`ct_idu_is_ctrl`、`ct_idu_is_dp`
  的位宽同步（IR 126 / ctrl_info 8 / IS 79）。
- PRF 新增 2 个读口（P2）与 1 个写口（P2），见 §4.3。

**删除信号**：无。

---

## 4. [P2] bridge 接入、标量操作数、vset 写回

### 4.1 新文件 `mySoC/rvv_a910_bridge.sv`

**端口（与 A910_cpu 连接）**

```systemverilog
// 时钟/复位（core 用低有效 rstn）
input  wire        clk;
input  wire        rst;              // 高有效；内部取反送 core.rstn

// 指令入口（来自 IDU VIQ，1 条/拍）
input  wire        idu_vec_inst_valid;
input  wire [6:0]  idu_vec_inst_iid;
input  wire [31:0] idu_vec_inst_pc;
input  wire [1:0]  idu_vec_inst_opcode;
input  wire [24:0] idu_vec_inst_bits;
input  wire        idu_vec_src0_vld;
input  wire [31:0] idu_vec_src0_data;
input  wire [5:0]  idu_vec_src0_preg;
input  wire        idu_vec_src0_wb;
input  wire        idu_vec_src1_vld;
input  wire [31:0] idu_vec_src1_data;
input  wire [5:0]  idu_vec_src1_preg;
input  wire        idu_vec_src1_wb;
input  wire [5:0]  idu_vec_dst_preg;
input  wire        idu_vec_dst_vld;
input  wire [4:0]  idu_vec_dst_reg;
output wire        rvv_vec_inst_ready;

// vset 写回
output wire        rvv_idu_vset_wb_vld;
output wire [5:0]  rvv_idu_vset_wb_preg;
output wire [31:0] rvv_idu_vset_wb_data;
output wire [6:0]  rvv_idu_vset_wb_iid;

// RTU 完成 / 提交 / 冲刷
output wire        cmplt_vld1;
output wire [6:0]  cmplt_iid1;
output wire        cmplt_vld2;
output wire [6:0]  cmplt_iid2;
input  wire        rtu_commit0, rtu_commit1, rtu_commit2;
input  wire [6:0]  rtu_commit_iid0, rtu_commit_iid1, rtu_commit_iid2;
input  wire        rtu_flush;

// 标量写回直通 (S3b)：IU pipe0/1/2、LSU pipe3、vset
// 用于 RVV 后端 RS 捕获迟到的标量源
input  wire [4:0]        scalar_wb_vld;
input  wire [4:0][5:0]   scalar_wb_preg;
input  wire [4:0][31:0]  scalar_wb_data;

// 状态/调试
output wire        rvv_idle;
output wire        rvv_trap_valid;
output wire [31:0] rvv_trap_inst;

// 向量 LSU（P5）
output wire        rvv_lsu_uop_valid;
output wire [..]   rvv_lsu_uop;
input  wire        rvv_lsu_uop_ready;
input  wire        rvv_lsu_resp_valid;
input  wire [..]   rvv_lsu_resp;
output wire        rvv_lsu_resp_ready;
```

**内部信号**

| 信号 | 位宽 | 说明 |
|---|---|---|
| `core_inst_valid[0:0]` | 1 | = `idu_vec_inst_valid`（N=1） |
| `core_inst_data[RVVInstruction][0:0]` | — | `.rob_tag=.iid`、`.pc`、`.opcode`、`.bits` |
| `core_inst_ready[0:0]` | 1 | `[0]` → `rvv_vec_inst_ready` |
| `core_reg_read_valid[1:0]` | 2 | `{src1_vld, src0_vld}`（N=1） |
| `core_reg_read_data[1:0][31:0]` | 2×32 | `{src1_data, src0_data}`（accept 后一拍影子） |
| `src{0,1}_wt_*` | — | 前端→backend 的按-iid 源等待表写口（S3b，§4.7） |
| `scalar_wb_*` | 5×(1+6+32) | bridge→backend 直通（S3b） |
| `acc_iid[6:0]` / `acc_valid` | 7/1 | accept 后一拍影子 |
| `acc_dst_preg[5:0]` / `acc_dst_vld` | 6/1 | vset 写回配对 |
| `acc_src0_data[31:0]` / `acc_src1_data[31:0]` | 32 | accept 后一拍保持 |
| `acc_cfg_state` | `RVVConfigState` | vset 完成时的 post-state（P3） |
| `core_flush` | 1 | P3：收敛后的冲刷 |
| `flush_pending` | 1 | P3 |
| `cmt_wmk_valid` / `cmt_wmk_iid[6:0]` | 1/7 | P3 提交水位 |
| `core_cmplt_valid` / `core_cmplt_iid[6:0]` | 1/7 | P3 来自 ROB |
| `rob_head_rob_tag[6:0]` / `rob_head_valid` | 7/1 | P3 来自 ROB |
| `vxsat_q` | 1 | `wr_vxsat_valid_o` 回存后接回 `RvvCore.vxsat` |

> `reg_read_valid/data` 必须按 `RvvFrontEnd.sv:183-243` 的时序：**accept 后一整拍**
> 保持 `inst_q` 对应的值。用 `acc_src0_data/acc_src1_data` 驱动即可。

### 4.2 `RvvFrontEnd.sv` / `RvvCore.sv` 的端口增改

**`RvvFrontEnd.sv` 新增输出**

| 端口 | 位宽 | 说明 |
|---|---|---|
| `cmd_config_state_o[N-1:0]` | `RVVConfigState` ×N | 每 lane 指令执行后的配置态，供 bridge 保存 vset 的 post-state |

**`RvvFrontEnd.sv` 新增输入（P3）**

| 端口 | 位宽 |
|---|---|
| `config_load_valid_i` | 1 |
| `config_load_data_i` | `RVVConfigState` |

**`RvvFrontEnd.sv` 修改的现有信号**

```systemverilog
// :605-611 rs1 选择：向量的 LOAD/STORE 必须无条件取 rs1
unaligned_cmd_data[i].rs1 =
  (inst_q[i].opcode != RVV) ? reg_read_data_i[2*i] :
  inst_q[i].bits[7] ? (...原逻辑...) : 0;
```

**`RvvCore.sv` 对应新增端口**（透传）

| 端口 | 方向 | 位宽 |
|---|---|---|
| `cmd_config_state_o` | output | `RVVConfigState [N-1:0]` |
| `config_load_valid_i` | input | 1 |
| `config_load_data_i` | input | `RVVConfigState` |
| `cmt_wmk_valid_i` | input | 1（P3） |
| `cmt_wmk_iid_i` | input | 7（P3） |
| `inst_cmplt_valid_o` | output | 1（P3） |
| `inst_cmplt_iid_o` | output | 7（P3） |
| `rob_head_rob_tag_o` | output | 7（P3） |
| `rob_head_valid_o` | output | 1（P3） |

**`RvvCore.sv` 新增参数**

```systemverilog
parameter type ROBCmdT = logic [6:0];   // 可选；也可直接用 7 位 iid
```

### 4.3 `ct_idu_rf_prf_pregfile.sv` / `ct_idu_rf_prf_gated_preg.sv`

**新增读口（2 个）**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `vec_rd_addr0` | input | 6 |
| `vec_rd_data0` | output | 32 |
| `vec_rd_addr1` | input | 6 |
| `vec_rd_data1` | output | 32 |

内部：`assign vec_rd_data0 = preg_reg_dout[vec_rd_addr0];`（另 1 路同理）。
地址由 **VIQ head** 的 `VIQ_SRC0_DATA[6:1]` / `VIQ_SRC1_DATA[6:1]` 驱动；
读出的值直接作为 `idu_vec_src0_data/src1_data` 送给 bridge。
**单发射口 ⇒ 只需 2 个读口**；地址不出 `ct_idu_top`。

**新增写口（1 个，vset rd）**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `rvv_vset_wb_preg_data` | input | 32 |
| `rvv_vset_wb_preg_expand` | input | 64（或用 6 位地址就地移位） |
| `rvv_vset_wb_preg_vld` | input | 1 |

**修改的现有信号**

| 信号 | 现状 | 改为 |
|---|---|---|
| `preg_wb_vld[0:63]` | `[4:0]` | **`[5:0]`** |
| `preg_wb_vld[j]` 拼接 | `{csr, pipe3, pipe2, pipe1, pipe0}` | `{vset, csr, pipe3, pipe2, pipe1, pipe0}` |
| 新增 `vset_wb_vld[63:0]` | — | `{64{rvv_vset_wb_preg_vld}} & (64'd1 << rvv_vset_wb_preg_addr)` |
| `ct_idu_rf_prf_gated_preg` 的 `x_wb_vld` | 5 位 | 6 位 |
| `ct_idu_rf_prf_gated_preg` 的 `unique case` | 5 分支 | 6 分支，新增 `6'b100000 : rvv_vset_wb_preg_data` |

**`ct_idu_top` 的 PRF 例化端口新增**

- `dp_prf_rf_vec_src0/1_preg`（由 VIQ head 驱动）
- `prf_dp_rf_vec_src0/1_data`（送 VIQ 影子 / 顶层输出）
- `rvv_vset_wb_*`（来自顶层端口）

### 4.4 `ct_idu_dep_reg_entry.sv`（及所有使用它的队列/表项）

**`ct_idu_dep_reg_entry` 新增端口**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `rvv_idu_vset_wb_preg_dupx` | input | 6 |
| `rvv_idu_vset_wb_preg_vld_dupx` | input | 1 |

**内部新增**

```systemverilog
logic vset_wb;
assign vset_wb = rvv_idu_vset_wb_preg_vld_dupx &&
                 (rvv_idu_vset_wb_preg_dupx[5:0] == preg[5:0]);
assign write_back = wb || pipe0_wb || pipe1_wb || pipe2_wb || pipe3_wb || vset_wb;
```

**透传改动（必须全改，漏一个就是"vset 写完消费者永不 ready"）**

以下模块各新增两个同款端口并把它们接到内部所有 `ct_idu_dep_reg_entry`：
- `ct_idu_is_pipe_entry.sv`
- `ct_idu_is_aiq_entry.sv`、`ct_idu_is_aiq.sv`
- `ct_idu_is_lsiq_entry.sv`、`ct_idu_is_lsiq.sv`
- `ct_idu_is_sdiq_entry.sv`、`ct_idu_is_sdiq.sv`
- `ct_idu_is_biq_entry.sv`、`ct_idu_is_biq.sv`
- `ct_idu_is_md_entry.sv`、`ct_idu_is_md.sv`（例化两份：mult/div）
- `ct_idu_vecq_entry.sv`（新增，直接带）

### 4.5 `A910_cpu.sv`

**新增 wire**

```systemverilog
// IDU → bridge
wire        idu_vec_inst_valid;      wire [6:0]  idu_vec_inst_iid;
wire [31:0] idu_vec_inst_pc;         wire [1:0]  idu_vec_inst_opcode;
wire [24:0] idu_vec_inst_bits;
wire        idu_vec_src0_vld;        wire [31:0] idu_vec_src0_data;
wire        idu_vec_src1_vld;        wire [31:0] idu_vec_src1_data;
wire [5:0]  idu_vec_dst_preg;        wire        idu_vec_dst_vld;
wire [4:0]  idu_vec_dst_reg;
wire        rvv_vec_inst_ready;
// bridge → IDU
wire        rvv_idu_vset_wb_vld;     wire [5:0]  rvv_idu_vset_wb_preg;
wire [31:0] rvv_idu_vset_wb_data;    wire [6:0]  rvv_idu_vset_wb_iid;
// 状态
wire        rvv_idle_dbg;            wire        rvv_trap_valid;
wire [31:0] rvv_trap_inst;
```

**修改的现有 wire/连线**

| 位置 | 改动 |
|---|---|
| `ct_idu_top u_ct_idu_top` 实例（:1084） | 新增上述 15+4 个端口连接 |
| `rvv_a910_bridge u_rvv_bridge`（新增例化） | 放在 IDU 之后、RTU 之前 |
| `RTU u_rtu` 的 `cmplt_vld1/iid1`（:1860-1863） | 改为由 bridge 驱动 |
| `preg_wb_mask`（:1789-1795） | OR 上 `{64{rvv_idu_vset_wb_vld}} & expand(rvv_idu_vset_wb_preg)` |
| `rtu_yy_xx_flush`（:1123 等） | 同时送 bridge.rtu_flush |
| `rtu_yy_xx_commit{0,1,2}` + `_iid`（:470-475） | 同时送 bridge |
| TB | 删除 `tb/a910/tb_a910_smoke.sv:159-162`、`tb/a910/tb_a910_difftest.sv:1112-1115` 的 force |

### 4.6 vset 的派遣字段（`ct_idu_top` 的派遣记录打包）

现有打包块 `ct_idu_top.sv:1439-1508` **不改结构**，仅依赖译码结果：

| 字段 | 非 vset 向量 | vset |
|---|---|---|
| `rf_we` | `IS_DST_VLD=0` → 0 | `IS_DST_VLD=1` |
| `dst_lreg` | 0（A6d 掩码） | `rd` |
| `dst_preg` | 0 | IR 分配的 preg |
| `flags[1]`（is_store） | 0 | 0 |
| `chk` | 0（§3.6） | 0 |

### 4.7 标量源在 RVV 后端 RS 等待（S3b）

> 适用于非 vset 的向量计算指令（ALU/MUL/DIV/PMT）。向量 L/S 不走这里（§7）。
> `vset*` 仍由 VIQ 的 dep entry 门控。

**1. 前端写"按 iid 的源等待表"**

`RvvFrontEnd` 新增输入 `src{0,1}_{vld,preg,wb,data}`（来自 bridge 的 VIQ head）
和输出 `src{0,1}_wt_{vld,iid,preg,wb,data}`。accept 时写 backend 的表：

```systemverilog
srcX_wt_vld  = inst_accepted && srcX_vld_i;
srcX_wt_iid  = inst_data_i.rob_tag;      // A910 iid
srcX_wt_preg = srcX_preg_i;
srcX_wt_wb   = srcX_wb_i;                // dep entry 的当前 wb
srcX_wt_data = srcX_data_i;              // accept 当拍的 PRF 组合读值
```

> ⚠️ `srcX_wt_data` **不能**用 frontend 的 `reg_read_data_i`：那是 accept 后
> 一拍的影子。两者时序不同。

**2. backend 表**

```systemverilog
typedef struct packed { logic vld; logic [5:0] preg;
                        logic captured; logic [31:0] data; } scalar_wait_t;
scalar_wait_t src0_wt_tbl[0:127], src1_wt_tbl[0:127];  // 7 位 iid 直接索引
```

- accept 写入 `{preg, captured=wb, data=accept 读值}`；
- 5 路 WB 命中 `vld && !captured && preg==wb_preg` ⇒ `captured=1; data=wb_data`
  （只捕获该指令 issue 后的**第一次** WB）；
- accept 同拍 WB 命中（`srcX_wt_hit`）⇒ 新表项直接 captured，data 用 WB 值；
- `trap_flush_rvv` 清 `vld`。

> ⚠️ **不要**用"按 preg 的全局 captured + re-arm"：preg 复用时会把下一个
> 生产者的数据/就绪状态串给更老的消费者。按 iid 分开存才是安全的。

**3. RS 结构与发车**

`ALU_RS_t / MUL_RS_t / DIV_RS_t / PMT_RDT_RS_t` 新增
`rs1_preg[5:0] / rs1_iid[6:0] / rs1_vld`（`rs1_wb` 可保留但已不用）。
decode 从 `LCMD_t.cmd` 复制，dispatch 从 `UOP_QUEUE_t` 复制。

```systemverilog
rs1_rdy = !rs1_vld || src0_wt_tbl[rs1_iid].captured;
// x-form: vs1_data[31:0] = src0_wt_tbl[rs1_iid].data;
// PMT   : rs1_data       = src0_wt_tbl[rs1_iid].data;
uop_valid_* = ~fifo_almost_empty & rs1_rdy;   // 多 lane 保持 in-order
```

**4. `RvvCore` 新增端口**

| 端口 | 方向 | 位宽 |
|---|---|---|
| `src0_vld_i/src1_vld_i` | input | 1 |
| `src0_preg_i/src1_preg_i` | input | 6 |
| `src0_wb_i/src1_wb_i` | input | 1 |
| `src0_data_i/src1_data_i` | input | 32 |
| `scalar_wb_vld` | input | 5 |
| `scalar_wb_preg` | input | 5×6 |
| `scalar_wb_data` | input | 5×32 |

**5. 遗留**

- `trap_flush_rvv` 的驱动在 P3（S4）收敛；当前 core `flush` 钉 0，表项只在
  reset/显式 flush 时清。
- 向量 L/S 的基址 `rs1_data` 与 LSIQ 通路在 §7 做；RVV 后端不为它等待。

---

## 5. [P3] 完成脉冲、提交门控、冲刷（RVV core 内部信号）

### 5.1 `rvv_backend_rob.sv`

**新增端口**

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `cmt_wmk_valid` | input | 1 | 提交水位有效（来自 A910 提交广播） |
| `cmt_wmk_iid[ROB_TAG_WIDTH-1:0]` | input | 7 | 当拍最年轻的已提交 iid |
| `inst_cmplt_valid` | output | 1 | 指令全部 uop 完成脉冲 |
| `inst_cmplt_rob_tag[ROB_TAG_WIDTH-1:0]` | output | 7 | 该指令 iid |
| `rob_head_rob_tag[ROB_TAG_WIDTH-1:0]` | output | 7 | ROB 头 iid（冲刷收敛用） |
| `rob_head_valid` | output | 1 | — |

**新增内部信号**

```systemverilog
logic [ROB_DEPTH-1:0] uop_cmplt_sent;   // 每个表项只发一次完成
logic [ROB_DEPTH-1:0] inst_done_chain;  // last_uop 边界断开的"全 done"链
logic [ROB_DEPTH-1:0] entry_committed;  // tag_committed(alluop_info[i].rob_tag)
```

**修改的现有信号**

```systemverilog
// 原: .pop (rd_valid_rob2rt & rd_ready_rt2rob)
// 改: 增加提交门控（表项不 pop ⇒ 仍在 ROB 里参与 dispatch RAW 检查）
wire [NUM_RT_UOP-1:0] pop = rd_valid_rob2rt & rd_ready_rt2rob &
                            entry_committed[wind_uop_rptr];
// 完成脉冲（早于退休，避免 commit/cmplt 互等）
assign inst_done_chain[i] = uop_done[i] &&
       (alluop_info[i-1].last_uop_valid || inst_done_chain[i-1]);
assign inst_cmplt_valid = |(inst_done_chain & alluop_info_last_uop & ~uop_cmplt_sent);
// 选一条（ROB 头方向）输出其 rob_tag
```

`uop_cmplt_sent`：表项分配时清 0，`inst_cmplt_valid` 命中时置 1，pop/flush 清 0。

**iid 年龄比较**：新增组合函数 `iid_committed(tag)`，规则同
`RTU_iid_cmp.v:28-61`（回绕位相同比索引；不同时索引大的属于上一圈）。
只用于退休门控慢路径，不接重定向链。

### 5.2 `rvv_backend.sv`

**新增端口**（透传 ROB 与水位）

| 端口 | 方向 | 位宽 |
|---|---|---|
| `cmt_wmk_valid` | input | 1 |
| `cmt_wmk_iid` | input | `ROB_TAG_WIDTH` |
| `inst_cmplt_valid` | output | 1 |
| `inst_cmplt_rob_tag` | output | `ROB_TAG_WIDTH` |
| `rob_head_rob_tag` | output | `ROB_TAG_WIDTH` |
| `rob_head_valid` | output | 1 |

**内部连线**：`u_rob` 新增 6 个端口一一对接。

### 5.3 `RvvCore.sv`

新增端口见 §4.2；另需：

- `vxsat` 输入改由 bridge 的 `vxsat_q` 驱动（不再恒 0）。
- `flush` 输入改由 bridge 的 `core_flush` 驱动（不再恒 0）。

### 5.4 bridge 内部（P3）

| 信号 | 位宽 | 逻辑 |
|---|---|---|
| `cmt_wmk_valid` / `cmt_wmk_iid` | 1/7 | 由 `rtu_commit{0,1,2}[_iid]` 取最年轻 |
| `flush_pending` | 1 | `rtu_flush` 置位；`core_flush` 后清零 |
| `flush_drain_cnt[2:0]` | 3 | 等 ROB 头未提交 + 2~3 拍 VRF 流水 |
| `core_flush` | 1 | 收敛后单拍脉冲 |
| `cmplt_vld1/iid1` | 1/7 | `core_cmplt_valid/inst_cmplt_rob_tag` |
| `cmplt_vld2/iid2` | 1/7 | vset 的 `reg_write_valid` 脉冲 + `acc_iid` |
| `vxsat_q` | 1 | `wr_vxsat_valid_o` 时更新 |
| `committed_cfg` | `RVVConfigState` | vset 提交时更新 |
| `vset_cfg_fifo` | {iid, post_state} ×4 | vset 完成→提交之间暂存 |

---

## 6. [P4] 计算类端到端

### 6.1 队列改名（仅实例名/注释，无信号改动）

`rvv_backend.sv:599-699`：

| 现实例名 | 改为 |
|---|---|
| `u_alu_rs` | `u_vaiq` |
| `u_mul_rs` | `u_vmacq` |
| `u_pmtrdt_rs` | `u_vpq` |

深度保持 `ALU_RS_DEPTH=4 / MUL_RS_DEPTH=4 / PMTRDT_RS_DEPTH=8`。

### 6.2 异常回路（非法/未支持向量指令）

| 信号 | 位宽 | 说明 |
|---|---|---|
| `rvv_trap_valid` | 1 | `RvvCore.trap_valid_o` |
| `rvv_trap_inst[31:0]` | 32 | `trap_data_o.bits` + 低位补 `opcode` |
| `expt_iu_vld/iid/cause/tval` | 1/7/5/32 | 复用适配层现有 `other_expt_*` 路径（cause=2） |

---

## 7. [P5] 向量 load/store —— LSIQ anchor + VPU 逐 beat 填充

> **2026-10-17 方案修订（用户决策 A）**
>
> 原方案"4 个向量专用 LSIQ tag（8~11）+ 独立引擎维护 4 个 super slot"作废。
> 改为：**派发时在现有 8 项 LSIQ 里占一个 anchor 表项**；RVV core 后续每产生
> 一个 LSU uop，IDU 的 fill 引擎把元素地址/数据/合并后的 beat 写进这个 anchor；
> LSU 用**原有的 LSIQ 发射口和 AG/DC/DA/WB 流水**处理每个 beat。
>
> **回答"是流水线还是 LSIQ entry"**：是 **LSIQ entry（anchor）**。
> 不另开向量流水线，也不占专用 tag。向量 L/S 指令在 IS 派发时：
>
> 1. 照常进 VIQ，送 RVV core 产生 uop；
> 2. 同时在 LSIQ 建 anchor：`valid=1`、`vec=1`、`raw_rdy=0`，agevec 位置
>    由此固定；
> 3. core 的 uop 到来后，fill 引擎把 beat 写进 anchor，`vec_beat_rdy=1`；
> 4. LSIQ 的正常 agevec 仲裁选中它，LSU 原有流水访问内存；
> 5. DA 级：`beat_last=0` 发 `beat_done` 不 pop；`beat_last=1` 才正常 pop。
>
> 这样 `agevec / old / 同类型发射顺序` 全部复用，不需要 8→12 扩 tag，
> 也不需要第二套 AG/DC/DA。
>
> **S3b 补充（标量基址等待）**：向量 L/S 的标量基址 `rs1` **不在 RVV 后端等待**。
> anchor 建表沿用 LSIQ 表项自己的 `ct_idu_dep_reg_entry`（src0）等基址 ready；
> RVV core 只负责产生向量侧的 beat 信息。因此 VIQ 对向量 L/S 立即发射，
> core 的 LSU uop 不承担 rs1 迟到写回的等待（`UOP_RVV2LSU_t` 的 rs1 字段仍按
> §7 的需要加，但就绪判据在 LSIQ）。

### 7.1 总体数据流

```
IS 派发 vector LOAD/STORE
  ├─ VIQ create ──────────────► RVV core（产生 UOP_RVV2LSU_t）
  └─ LSIQ create anchor
        {vec=1, iid, load/store, raw_rdy=0, agevec=正常排位}
             │
             │  core uop: {rob_tag, uop_index, lsu_type, vidx/vs3/v0,
             │             rs1/rs2, eew, vl, first/last, lsu_id}
             ▼
      IDU fill 引擎 ct_idu_vec_ls_fill
        · 按 US/CS/IU/IO 算元素地址
        · 4B 对齐字内合并成 1/2/4B 请求
        · 分配 request index（下文 `uop_idx[4:0]`）
        · 写 anchor 的 beat 寄存器：
          {synthetic opcode, addr, sdiq_entry, uop_idx, last, sd_data}
        · vec_beat_rdy=1
             │
             ▼
      LSIQ 原有 agevec 仲裁（anchor 与标量表项一起排）
             │
             ▼
      LSU 原有流水: AG → DC → DA → WB
        · load : LQ 表项键 = {iid, uop_idx}
        · store: 每 beat 建一个 SDIQ 数据项 + SQ 表项键 = {iid, uop_idx}
             │
             ▼ DA
        beat_last=1 → lsu_idu_lsiq_pop（正常 pop，清 vld/agevec/counter）
        beat_last=0 → lsu_idu_beat_done（不 pop；清 frz，fill 引擎装下一 beat）
```

### 7.2 为什么"只改 pop 和 inst_hit"不够

用户给的 A 方案骨架正确，但按本仓当前 RTL，至少还要补下面几处；否则会
**静默卡死**或**年龄错位**：

| # | 必须补的点 | 不补的后果 |
|---|---|---|
| 1 | IS 派发时把 vector L/S 也纳入 LSIQ create 仲裁（vector 指令本来只进 VIQ） | LSIQ 里没有 anchor，后续 beat 无处可填 |
| 2 | LSIQ entry 的 `frz` 在 `beat_done` 时清、且非最后 beat 不 pop | 第一 beat 发射后 `frz=1` 永久冻住，后续 beat 发不出去（`ct_idu_is_lsiq_entry.sv:110-126`） |
| 3 | `lsu_idu_lsiq_pop_vld` 只在 `beat_last` 时拉；非最后 beat 走单独的 `beat_done` | agevec/counter 被提前清掉，anchor 从 LSIQ 里"消失"，但 vld 还在 |
| 4 | anchor 的 beat 字段（opcode/addr/sdiq_entry/uop_idx/last）要能被 fill 引擎逐 beat 改写 | 第二个 beat 还是第一个 beat 的地址/大小 |
| 5 | `uop_idx` 必须贯通 LSU 流水到 LQ/MSHR/SQ/load 写回 | 同 iid 的后续 beat 被 `inst_hit` 挡住，LQ/SQ 建不了表项 |
| 6 | 向量 store 仍要"提交后再排空"（staging）；anchor 在不提交时 `vec_beat_rdy=0` | 向量 store 在提交前就写内存；或 SQ(6 项) 被填满后"提交等完成、完成等提交"死锁 |
| 7 | SDIQ 每个 beat 仍要一个数据项（可复用现有 4 项） | store 数据没有落点 |

> 下面按这 7 点逐项给出信号级改法。LSIQ 保持 **8 项**；SDIQ 保持 **4 项**
> （不再扩 6；若后续发现标量/向量抢 SDIQ 严重，再单独扩到 6）。

### 7.3 LSIQ 表项：新增 anchor/beat 字段

文件：`mySoC/idu_c910/rtl/ct_idu_is_lsiq_entry.sv`

#### 7.3.1 新增端口

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `x_vec` | input | 1 | create 时从 `x_create_data` 解析；1=anchor |
| `x_vec_beat_rdy` | input | 1 | fill 引擎：当前 beat 已填好、可发射 |
| `x_vec_upd_en` | input | 1 | fill 引擎：写入下一个 beat |
| `x_vec_upd_data` | input | `VEC_BEAT_WIDTH` | beat 字段（见下） |
| `x_vec_beat_done` | input | 1 | 来自 LSU DA：本 beat 已完成但不是最后 beat |
| `x_read_vec_beat` | output | `VEC_BEAT_WIDTH` | 给 IDU 顶层做发射 mux |
| `x_read_vec` | output | 1 | 该表项是 anchor |

#### 7.3.2 beat 字段（`VEC_BEAT_WIDTH`）

```systemverilog
parameter VEC_BEAT_WIDTH = 32   // synthetic opcode
                         + 32   // addr
                         + 4    // sdiq_entry（store；load 恒 0）
                         + 5    // uop_idx（request index）
                         + 1    // last
                         + 32;  // sd_data（store beat 的 32 位数据）
// = 106 bit
```

- `synthetic opcode`：load 用 `LBU/LHU/LW`（引擎按字节取数，扩展位不用），
  store 用 `SB/SH/SW`。这样 **`ct_idu_rf_dp` 的 pipe3/pipe4 解码完全不用改**，
  `inst_size/sign_extend` 自动正确。
- `addr`：**完整元素地址**；LSU 的 `offset` 恒 0。
- `uop_idx`：request index，见 §7.5；同时作为 load 的 `dst_preg[5:0]`（高位补 0）。
- `last`：本 beat 是整条向量指令的最后一个 A910 请求。

#### 7.3.3 状态机改动

```systemverilog
// raw ready：anchor 不看标量 src0 的 wb，改看 fill 引擎的 beat_rdy
assign src0_rdy_for_issue = x_vec ? x_vec_beat_rdy : read_src0_data[0];
assign x_raw_rdy = vld && !frz && src0_rdy_for_issue;

// frz：任何一次发射都置 1；anchor 在 beat_done 清（标量没有 beat_done）
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)                      frz <= 1'b0;
  else if (x_create_en)               frz <= 1'b0;
  else if (x_issue_en)                frz <= 1'b1;   // 标量/anchor 的每个 beat
  else if (x_vec_beat_done)           frz <= 1'b0;   // 非最后 beat：解锁下一拍
  else if (lsu_frz_clr | lsu_idu_imme_wakeup)
                                      frz <= 1'b0;
  else                                frz <= frz;
end

// vld：只有 pop（最后 beat）才清
else if (lsu_idu_lsiq_pop_vld && x_pop_cur_entry)
    vld <= 1'b0;

// agevec / agevec_all / entry counter：
//   只在 lsu_idu_lsiq_pop_vld（最后 beat）时更新；
//   beat_done 绝不能清 agevec/agevec_all，也不能减 counter。
```

> 最后 beat 发射时 `frz` 同样置 1，防止它在 pop 之前又发一次；`pop` 清 vld。
> `beat_done` 只清 frz，不碰 vld/agevec/counter。

#### 7.3.4 `old` / 发射顺序

- `old = !|agevec_all` **完全不变**：anchor 创建时正常占 agevec，直到最后
  一个 beat pop 才清；
- `older_entry_rdy_mask` 用 `x_other_raw_rdy`，anchor 的 `x_raw_rdy` 含
  `vec_beat_rdy`，所以"老 anchor 没准备好时不挡年轻表项"的行为与标量一致；
- 同拍最多一个表项发射（原有 one-hot 选择），anchor 连续多个 beat 时，
  每个 beat 之间至少隔一拍（`beat_done` 清 frz 后才能再选中）；
- **vector load 的 `vec_beat_rdy` 额外要求 `old=1`**（该 anchor 是 LSIQ 最老
  项）：这样 LQ 表项可以安全地提前 pop（没有更老的 store 会在之后到 DC）。
  store 不需要这个门控（走 SQ，不做 LQ 查表）。这条会在最坏情况下让向量
  load 等更老的 LSIQ 项排空，但**不会**改变 agevec/old 的定义，也不改变
  标量的发射顺序。

### 7.4 LSIQ 队列：create / update / issue 三条通路

文件：`mySoC/idu_c910/rtl/ct_idu_is_lsiq.sv`

#### 7.4.1 create：vector L/S 也要建表项

1. `LSIQ_WIDTH` 从 60 扩到 **61**（新增 `LSIQ_VEC` 位，最高位；老位号全部
   不动）。`x_create_data` 相应扩 1 位。**4 份副本全部同步**：
   `ct_idu_is_lsiq.sv:43`、`ct_idu_is_lsiq_entry.sv:47`、
   `ct_idu_is_dp.sv:195`、`ct_idu_rf_dp.sv:180`。
   所有硬编码 `[59:0]` 也要同步改成 `[60:0]`：
   `ct_idu_top.sv:323/326/494/495`、`ct_idu_is_lsiq.sv:5/6/33/37`、
   `ct_idu_is_lsiq_entry.sv:20/31`、`ct_idu_is_dp.sv:85/86`、
   `ct_idu_rf_dp.sv:63/85`。
2. 在 `ct_idu_is_dp.sv` 的 `is_lsiq_create{0,1}_data` 打包处，把
   `is_inst{k}_vec` 填进 `LSIQ_VEC`；标量自然为 0。
3. **IS 控制**：vector LOAD/STORE（`vec_type=01/10`）要参与 LSIQ create
   仲裁，和标量 LSIQ 指令一起决定 create0/create1：
   - 在 `ct_idu_ir_ctrl.sv` 里把 `ctrl_ir_inst{k}_lsiq` 的判据扩成
     `(原标量 LSIQ) || ir_pipedown_inst{k}_ctrl_info[IS_CTRL_VMEM]`
     （`IS_CTRL_VMEM` 在 §3.4 由 `vec_type==01/10` 生成）；
   - `ctrl_ir_pre_dis_3_lsiq_inst` 的"同拍 3 条 LSIQ"stall 自动覆盖；
   - `ct_idu_is_dp.sv` 的 LSIQ create data 选路照旧（create0 老、create1 年轻）。
4. **VIQ 仍要同时 create**：vector L/S 指令同时进 VIQ 和 LSIQ；两者是同一条
   指令的两个影子，iid 相同。
   给 fill 引擎的 `lsiq_vec_create_entry` 必须带**表项号**：由
   `ct_idu_is_lsiq` 的 `lsiq_entry_create{0,1}_in`（create0/1 落到哪个空槽）
   生成 one-hot；只给 create_en 不够，fill 引擎无法知道 anchor 的槽号。
5. anchor 的 create data 里：
   - `LSIQ_LOAD/STORE`：按指令类型置位；
   - `LSIQ_IID`：指令 iid；
   - `LSIQ_SRC0_VLD`：置 1，但源编码固定 **`7'b0000001`**（preg0 + wb=1）；
     anchor 的 ready 由 `vec_beat_rdy` 旁路，不靠这个 dep entry，也不会被
     真实 preg 的写回误唤醒；
   - `LSIQ_DST_VLD/DST_PREG/OPCODE/SDIQ_ENTRY`：填 0 / 占位（等 fill 引擎 beat
     更新）；
   - `LSIQ_VEC=1`。

> 如果同拍 3 条都是 LSIQ（标量+向量混合），现有 `pipedown2` stall 会把最年轻
> 的一条留到下一拍，保证程序序和 agevec 连续。

#### 7.4.2 update：fill 引擎逐 beat 写表项

新增一对广播端口，连到 8 个 entry：

```systemverilog
input  logic [LSIQ_ENTRY-1:0]     lsiq_vec_upd_entry;   // one-hot
input  logic [VEC_BEAT_WIDTH-1:0] lsiq_vec_upd_data;
input  logic [LSIQ_ENTRY-1:0]     lsiq_vec_beat_rdy;    // 逐表项
input  logic [LSIQ_ENTRY-1:0]     lsu_idu_beat_done;    // 逐表项
```

- `lsiq_vec_upd_entry` 由 fill 引擎给（已按 iid 找到 anchor 的表项号）；
- `lsiq_vec_beat_rdy` 扇出到每个 entry 的 `x_vec_beat_rdy`；
- entry 在 `x_vec_upd_en` 时锁存 beat 字段，`x_read_vec_beat` 输出；
- 更新只改 beat 字段，不改 `iid/load/store/vec/agevec`；
- 同一 anchor 已有 beat 未发射时，fill 引擎必须等 `vec_beat_rdy` 被消费
  （或等 `beat_done`）再写下一个 beat；不会覆盖在途数据；
- **update 与 `vec_beat_rdy` 至少隔一拍**（update 在 T 拍锁存，ready 在 T+1
  拍才拉高），或者 ready 同拍走组合旁路；否则 LSIQ 在 update 同拍发射，
  `rf_pipe3_data` 读到的还是**上一 beat** 的 opcode/addr/sdiq_entry。

#### 7.4.3 issue：顶层 mux

`ct_idu_is_lsiq.sv` 用现有 `lsiq_dp_pipe3_issue_entry`/`pipe4_issue_entry`
one-hot，把 anchor 的 beat 总线也选出来：

```systemverilog
output logic [VEC_BEAT_WIDTH-1:0] lsiq_dp_pipe3_vec_beat;
output logic [VEC_BEAT_WIDTH-1:0] lsiq_dp_pipe4_vec_beat;
output logic                      lsiq_dp_pipe3_issue_vec;
output logic                      lsiq_dp_pipe4_issue_vec;
output logic [LSIQ_ENTRY-1:0]     lsiq_vec_old;   // 给 fill 引擎做 load old 门控
```

`ct_idu_rf_dp.sv` 的 pipe3/pipe4 把这个总线与 `rf_pipe3_data/rf_pipe4_data`
一起打拍，然后 override：

```systemverilog
// 以 pipe3 load 为例；pipe4 store 同理
assign idu_lsu_ld_src[31:0] = issue_vec ? beat_addr : lsiq_src0_from_prf;
assign idu_lsu_ld_preg[5:0] = issue_vec ? {1'b0, beat_uop_idx} : lsiq_dst_preg;
assign idu_lsu_ld_oldest    = issue_vec ? 1'b0 : lsiq_oldest;
assign idu_lsu_ld_vec       = issue_vec;
assign idu_lsu_ld_last      = issue_vec ? beat_last : 1'b1;
assign idu_lsu_ld_uop_idx   = beat_uop_idx;
```

- `ct_idu_rf_dp` 的 `LSIQ_WIDTH` 60→61，`rf_pipe3_data/rf_pipe4_data` 同步；
  `issue_vec` 可直接取 `rf_pipe3_data[LSIQ_VEC]` / `rf_pipe4_data[LSIQ_VEC]`；
- `iid` 仍取 entry 的 `LSIQ_IID`（create 时固定）；
- `synthetic opcode` 建议直接写进 entry 的 `opcode` 字段，这样
  `pipe3_decd_opcode`/`inst_size/sign_extend` 的解码完全复用；
- `sdiq_entry`（store）直接写进 entry 的 `LSIQ_SDIQ_ENTRY` 字段，pipe4 原路取；
- `offset` 恒 0：beat.addr 已经是完整地址；
- `uop_idx` 同时作为 load 的 preg（元素键）；store 侧走独立的 `uop_idx` 流水，
  见 §7.6；
- `vec_beat_iid` 不必重复存，直接用 entry 的 iid。

### 7.5 fill 引擎：`ct_idu_vec_ls_fill.sv`（新文件）

#### 7.5.1 职责

接收 RVV core 的 `UOP_RVV2LSU_t`，把它拆成 A910 的 1/2/4B beat，写进
anchor 表项；收集 load 写回并回送 core；管理 store staging。**它不直接驱动
LSU 发射口**——发射由 LSIQ 正常仲裁完成。

`rtu_yy_xx_flush` 到达时：清所有 anchor 上下文、request 表、staging、
`committed` 标志；LSIQ 表项由 LSIQ 自己的 flush 清（`vld/agevec/counter`）。
不要在 flush 后保留任何 beat 指针或 request 表项。

#### 7.5.2 端口（与现有 bridge/IDU/LSU 的连接）

| 端口 | 方向 | 位宽/类型 |
|---|---|---|
| `rvv_lsu_uop_valid` / `_data` | input | 1 / `UOP_RVV2LSU_t` |
| `rvv_lsu_uop_ready` | output | 1（按 anchor 上下文/beat 槽反压 core） |
| `rvv_lsu_resp_valid` / `_data` | output | 1 / `UOP_LSU2RVV_t` |
| `rvv_lsu_resp_ready` | input | 1（core 的 remap ready） |
| `lsiq_vec_create_entry` / `_vld` | input | 8 one-hot / 1（IS 建 anchor 时给） |
| `lsiq_vec_create_iid` / `_store` | input | 7 / 1 |
| `lsiq_vec_upd_entry` / `_data` | output | 8 one-hot / `VEC_BEAT_WIDTH` |
| `lsiq_vec_beat_rdy` | output | `LSIQ_ENTRY` 位（逐表项 ready） |
| `lsiq_vec_old` | input | `LSIQ_ENTRY` 位（load 的 beat 还要等 `old=1`） |
| `lsu_idu_beat_done` | input | `LSIQ_ENTRY` one-hot |
| `lsu_idu_pop_entry` | input | `LSIQ_ENTRY` one-hot（最后 beat） |
| `lsu_idu_wb_pipe3_wb_preg_vec` / `_uop_idx` / `_iid` / `_data` | input | 1 / 5 / 7 / 32 |
| `lsu_idu_sq_pop_vld` / `_uop_idx` | input | 1 / 5（释放 request index） |
| `rtu_commit0/1/2` + `_iid0/1/2` | input | 1/7 each（RTU commit 脉冲，bridge 透传） |
| `vec_st_cmit_vld` / `_iid` | output | 1 / 7（**电平**，保持到该 anchor 排空；给 SQ） |
| `vec_sdiq_create_vld` / `_entry` | output/input | 1 / 4（one-hot） |
| `vec_sdiq_issue_entry` / `vec_sd_data` | output | 4 / 32 |
| `lsu_idu_lq_full` / `rb_full` / `sq_full` | input | 8 each |
| `rvv_old_iid` / `_vld` | output | 7 / 1（供标量 LSIQ 的 `old` 修正） |

> `LSIQ_ENTRY` 保持 8；`vec_sdiq_create_entry` 仍是 4 位，复用现有 4 个 SDIQ
> 表项（不扩 6）。

#### 7.5.3 anchor 上下文

每个 LSIQ 表项对应一份上下文（8 份）：

```systemverilog
typedef struct packed {
  logic        active;
  logic [6:0]  iid;
  logic        store;
  logic [4:0]  cur_core_uop;      // 当前 core uop_index
  logic [7:0]  cur_vl;
  logic [2:0]  vd_eew, vs2_eew;
  logic [1:0]  mop;               // US/CS/IU/IO
  logic [31:0] base;              // rs1
  logic [31:0] stride;            // rs2
  logic [127:0] vidx;             // 当前 uop 的 index/vs2 数据
  logic [127:0] sdata;            // 当前 uop 的 store 数据
  logic [15:0] mask;              // v0 逐字节
  logic        data_ok;
  logic [4:0]  beat_ptr;          // 当前 uop 内的 beat 指针
  logic [127:0] ld_asm;           // load 128 位拼装缓冲
  logic        store_staged;      // store 数据已齐、等提交
  logic        committed;         // 已收到 vec_st_cmit
  // store staging：最多 4 个 core uop
  logic [3:0]  stage_vld;
  ... 4 × {core_uop, vidx, sdata, mask, eew, mop, base, stride, vl}
} vec_anchor_ctx_t;
```

> load 只保留当前 core uop；store 要保留最多 4 个 core uop（LMUL≤4）。
> core uop 的 `rob_tag` 就是 anchor 的 iid；引擎在 8 份上下文里按 iid 匹配。
> anchor 在 IS 先建、uop 后到，不会反序。
> 字段宽度只是说明，实现时按实际宽度裁剪。

#### 7.5.4 request index（`uop_idx[4:0]`）

- 全局 32 项 request 表（所有 anchor 共用），每项：
  `{anchor_idx[2:0], core_uop[4:0], cell_mask[15:0], store, valid}`；
- 每个 A910 beat 分配一个唯一的 5 位 index，写进 anchor 的 beat 字段；
- index 随 LSU 流水到 LQ/MSHR/SQ；load 写回带回来；
- **释放时机**：load 在 LQ 表项弹出（写回或提交）后释放；store 在 **SQ
  表项弹出**后释放。**不能**在"store 数据捕获"时就释放——SQ 表项还带着
  `uop_idx` 活着，复用会让新 beat 被旧表项的 `inst_hit` 挡住；
- 实现建议：5 位轮转计数 + 32 位 `req_valid` 位图；分配时从当前指针找第一个
  `!req_valid`，置位；对应 LQ/SQ 表项弹出时清位。32 > LQ(8)+SQ(6)+
  MSHR+pipeline，正常情况下不会出现"全 32 项都在飞"；
- 超长指令可以回绕，只要对应表项已经弹出。

> 这就是用户说的"需要 uop_idx"。它**不是** core 的 `uop_index` 原值，而是
> **A910 请求级**的唯一键；core 的 `uop_index` 另存一列（`cur_core_uop`），
> 用于把 load 数据拼回正确的 128 位向量寄存器。

#### 7.5.5 beat 生成

1. core uop 进入：按 `lsu_type/mop` 算每个 active 字节的地址：
   - US：`base + (chunk_base + k) * (1<<vd_eew)/8`；
   - CS：`base + (chunk_base + k) * $signed(stride)`；
   - IU/IO：`base + sign_extend(vidx[slice])`；
2. 在 4B 对齐字内合并连续有效字节：
   - 4B 全有效 → `LW/SW`；2B → `LHU/SH`；1B → `LBU/SB`；有洞就拆；
   - store 数据按起始字节旋转（coralnpu `LsuCell.rotl`，`Lsu.scala:611-620`）；
3. 每个合并请求分配 request index，写 anchor beat：
   `{opcode, addr, sdiq_entry, uop_idx, last, sd_data}`；
4. `last = core_uop.last_uop_valid && 本 uop 的最后一个请求`；
5. `vec_beat_rdy=1`；**load 还要求 `lsiq_vec_old[anchor]=1`**（见 §7.6.4 的
   RAW 说明），store 不等；LSIQ 正常仲裁发射；
6. 收到 `beat_done`：清 beat、`beat_ptr++`；还有请求就填下一个，否则
   等 core 下一个 uop；
7. 收到最后 beat 的 `pop_entry`：该 anchor 结束，释放上下文。

#### 7.5.6 load 写回与拼装

- LSU 写回：`lsu_idu_wb_pipe3_wb_preg_vec=1` + `uop_idx` + `iid` + `data[31:0]`；
- 用 `{iid, uop_idx}` 查 request 表 → `{anchor, core_uop, cell_mask}`；
- 每个 core uop 开始时把 `ctx.ld_asm` 清 0；`data` 的有效字节写到对应
  字节；未写的 inactive/tail 字节保持 0（tail 语义）；
- `ff_tail_index` 恒 `VLENB`（不做 fault-only-first）；
- 该 core uop 的所有 request 都返回后：
  - `rvv_lsu_resp.vregfile_write_valid=1`；
  - `vregfile_write_addr = core uop.dst_index`；
  - `vregfile_write_data = ld_asm`；
  - `ff_tail_index = VLENB`；
  - `rob_tag/uop_index/lsu_id` 原样带回；
- **不等提交**（load 提前完成，否则 LQ 8 项会死锁）；
- `rvv_lsu_resp_ready` 低时用一个 4 深响应 FIFO 暂存（存 `lsu_id/rob_tag/
  uop_index/dst_index/data`），FIFO 满则对应 anchor 不再接收新的 core uop，
  但不影响已经发出的 beat。

#### 7.5.7 store staging 与提交后排空

1. core store uop 到来：把 `{opcode, vidx, sdata, mask, eew, mop, base, stride,
   vl, last}` 存进 staging（每 anchor 最多 4 个 core uop；uop 数 > 4 已在
   decode 阶段 trap，不会到这里）；
2. 该 uop 的数据齐后，向 core 回 `lsu_vstore_last`（`UOP_LSU2RVV_t`，
   `vregfile_write_valid=0`），让 core 完成/提交；
3. **提交前 anchor 的 `vec_beat_rdy` 恒 0**，不会访问内存；
4. 收到 `rtu_commit*_iid == anchor iid`：把 `ctx.committed` 置 1（保持），
   排空期间 `vec_st_cmit_vld` 一直为 1；
   **`vec_st_cmit_vld` 必须是电平，不是单拍脉冲**：从 commit 命中开始一直保持
   到该 anchor 的所有 beat 排空。原因：向量 store 的 beat 是在**提交之后**
   才进入 SQ 的，如果只用一拍 commit 脉冲，后建的 SQ 表项永远看不到它，
   会一直等第二次提交（永远不会来）；
5. 每个 beat：
   - 向 SDIQ 申请一个数据项（复用现有 4 项），写 32 位 store 数据；
   - 写 anchor beat（`sdiq_entry`、addr、synthetic store opcode、uop_idx、last）；
   - `vec_beat_rdy=1`；LSIQ 发射；SQ 按 `{iid, uop_idx}` 建表项；
6. 所有 beat 排空后释放 anchor 上下文；
7. 用 `lsu_idu_sq_full/not_full` / SDIQ 可用性反压，避免填满；
8. **多个 vector store 同时 committed 时，排空要串行**（一次只排一个
   anchor）；`vec_st_cmit_vld/iid` 只对当前排空的 anchor 有效，避免一个
   单线电平同时代表多个 iid。

> store 的 SQ(6 项) 在提交前不会被向量 store 占用，所以不会出现
> "提交等完成、完成等提交"的经典死锁。
>
> **容量约束**：每 anchor 的 store staging 只放 **4 个 core uop**。因此首版
> 限制的是"单条向量 store 的 core uop 数 ≤ 4"，不是只看 LMUL：
> unit-stride 下 uop 数 = LMUL（所以 LMUL≤4）；strided/indexed/segment 由
> `decode_unit_lsu` 实际的 `uop_index_max+1` 决定，超过 4 就必须在 decode 阶段
> trap，不能等出核后才因 staging 不够卡住。

### 7.6 LSU 侧改动

#### 7.6.1 LSIQ/SDIQ 深度

- **LSIQ 保持 8 项**（不再 8→12）；anchor 就是普通 LSIQ 表项；
- **SDIQ 保持 4 项**（不再 4→6）；每个 store beat 动态申请一个；
- `LSIQ_ENTRY`/`SDIQ_ENTRY` 参数**不变**，所有 `lsu_top`/子模块的 8/4 位
  信号宽度不变。

#### 7.6.2 `vec` / `uop_idx` / `last` 贯穿

新增流水字段（每一级与 `iid` 同条件打拍）：

| 级 | 信号 |
|---|---|
| IDU→LSU | `idu_lsu_ld_vec`, `idu_lsu_ld_uop_idx[4:0]`, `idu_lsu_ld_last` |
| IDU→LSU | `idu_lsu_st_vec`, `idu_lsu_st_uop_idx[4:0]`, `idu_lsu_st_last` |
| AG→DC | `ld_ag_dc_vec/uop_idx/last`, `st_ag_dc_vec/uop_idx/last` |
| DC→DA | `ld_dc_da_vec/uop_idx/last`, `st_dc_da_vec/uop_idx/last` |
| DA→WB | `ld_da_wb_vec/uop_idx`, `st_da_wb_vec/uop_idx` |
| LSU→IDU | `lsu_idu_wb_pipe3_wb_preg_vec`, `lsu_idu_wb_pipe3_wb_uop_idx[4:0]` |
| LSU→IDU | `lsu_idu_beat_done[LSIQ_ENTRY-1:0]` |
| LSU→IDU | `lsu_idu_sq_pop_vld` / `lsu_idu_sq_pop_uop_idx[4:0]`（SQ 表项弹出，释放 request index） |
| LSU→RTU | `lsu_rtu_wb_pipe3_wb_preg_vec`, `lsu_rtu_wb_pipe4_vec` |

> `last` 只需要到 DA：pop 门控在 DA 级。WB 不需要 last。

#### 7.6.3 DA 级 pop / beat_done

`lsu_ld_da.sv`（当前 :638-641）：

```systemverilog
// 原来
// assign ld_da_idu_pop_vld = ld_da_inst_vld && !ld_da_restart_vld;
// 改为
assign ld_da_idu_pop_vld = ld_da_inst_vld && !ld_da_restart_vld &&
                           (!ld_da_vec || ld_da_last);

// 新增：非最后 beat 的"beat 完成"
assign ld_da_idu_beat_vld = ld_da_inst_vld && !ld_da_restart_vld &&
                            ld_da_vec && !ld_da_last;
assign ld_da_idu_beat_done[LSIQ_ENTRY-1:0] =
    {LSIQ_ENTRY{ld_da_idu_beat_vld}} & ld_da_mask_lsid[LSIQ_ENTRY-1:0];
```

`lsu_st_da.sv` 同理（当前 :331-332）：

```systemverilog
assign st_da_idu_pop_vld = st_da_wb_cmplt_req &&
                           (!st_da_vec || st_da_last);
assign st_da_idu_beat_done[LSIQ_ENTRY-1:0] =
    {LSIQ_ENTRY{st_da_wb_cmplt_req && st_da_vec && !st_da_last}} &
    st_da_mask_lsid[LSIQ_ENTRY-1:0];
```

`lsu_top.sv`：

```systemverilog
assign lsu_idu_pop_entry = ld_da_idu_pop_entry | st_da_idu_pop_entry;
assign lsu_idu_beat_done = ld_da_idu_beat_done | st_da_idu_beat_done;
```

**注意**：非最后 beat **不能**拉 `lsu_idu_pop_vld`。`ct_idu_is_lsiq` 的
entry counter、8 个 entry 的 `agevec/agevec_all` 都是在 `pop_vld` 上更新的；
如果提前拉，anchor 会被从年龄图里删掉，而同 iid 的 vld 还在。

#### 7.6.4 LQ 表项：`uop_idx` + 提前 pop

`lsu_lq_entry.sv`：

- 新增输入 `ld_dc_vec`、`ld_dc_old`、`ld_dc_uop_idx[4:0]`、
  `ld_wb_data_vld`、`ld_wb_data_iid[6:0]`、`ld_wb_data_uop_idx[4:0]`；
- 新增寄存器 `lq_entry_vec`、`lq_entry_old`、`lq_entry_uop_idx[4:0]`；
- **`lq_entry_old` 的锁存**：标量取 `ld_dc_old`；向量取 **1**（因为
  §7.3.4 已经保证向量 load 只在 anchor 是 LSIQ 最老项时才发 beat）。
  如果以后放宽这个 old 门控，必须改成真实的 `vec_old` 信号；
- `:127` 改为：

```systemverilog
assign lq_entry_inst_hit = lq_entry_vld &&
                           (lq_entry_iid[6:0] == ld_dc_iid[6:0]) &&
                           (!ld_dc_vec ||
                            (lq_entry_uop_idx[4:0] == ld_dc_uop_idx[4:0]));
```

- `:120` 改为：

```systemverilog
assign lq_entry_pop_vld = lq_entry_cmit_vld ||
                          (lq_entry_vec && ld_wb_data_vld &&
                           (ld_wb_data_iid[6:0] == lq_entry_iid[6:0]) &&
                           (ld_wb_data_uop_idx[4:0] == lq_entry_uop_idx[4:0]));
```

- `ld_dc_uop_idx` 来自 LSIQ beat 的 `uop_idx`（§7.4.3）；
- load 写回带 `uop_idx`，保证不同 beat 的写回不会串。

> ⚠️ **提前 pop 的 RAW 风险（必须显式处理）**：A910 的 LQ 表项原本要保留到
> 提交，用来接收"更老的 store 晚到 DC"时的 RAW spec-fail 重放。向量 load
> 提前 pop 后，如果一条更老的 store 在该 beat 数据返回之后才到 DC，就找不到
> LQ 表项 ⇒ **静默读旧值**。
>
> 首版采用保守门控：**只有该 beat 的 `old=1`（LSIQ 里没有更老项）时才允许
> 提前 pop；否则保留到提交**。如果实测出现"load 8 项填满 → 指令未完成 →
> 无法提交"的死锁，改用另一种保守法：anchor 在不是最老 LSIQ 项时先不发
> beat（等 `old=1`），而不是牺牲 RAW 检查。两条路都**不要**无条件提前 pop。

#### 7.6.5 MSHR：`uop_idx`

`lsu_mshr_entry.sv`：

- 新增 `ld_da_vec`、`ld_da_uop_idx[4:0]`、`rb_entry_vec`、
  `rb_entry_uop_idx[4:0]`；
- `:598` 改为：

```systemverilog
assign rb_entry_iid_hit = (rb_entry_iid[6:0] == ld_da_iid[6:0]) &&
                          (!ld_da_vec ||
                           (rb_entry_uop_idx[4:0] == ld_da_uop_idx[4:0]));
```

标量 `ld_da_vec=0`，行为不变；向量不同 beat 不合并。

#### 7.6.6 SQ 表项：`uop_idx`

`lsu_sq_entry.sv`：

- 新增 `st_dc_vec`、`st_dc_uop_idx[4:0]`、`sq_entry_vec`、
  `sq_entry_uop_idx[4:0]`、`st_da_uop_idx[4:0]`；
- `:477` 的 `sq_entry_inst_hit` 改为：

```systemverilog
assign sq_entry_inst_hit = sq_entry_vld && !sq_entry_no_restart &&
                           (sq_entry_iid[IID_WIDTH-1:0] ==
                            st_dc_iid[IID_WIDTH-1:0]) &&
                           (!st_dc_vec ||
                            (sq_entry_uop_idx[4:0] == st_dc_uop_idx[4:0]));
```

- `sq_entry_st_da_info_set` 同样加 `!st_da_vec || uop_idx 匹配`，否则
  `st_da` 的写完成信息会写到同 iid 的另一个 beat 表项上；
- 提交匹配（`sq_entry_cmit_set`）仍只比 iid：整条指令的所有 beat 一起提交；
  向量分支用 **电平** `vec_st_cmit_vld`（保持到排空结束），不是单拍脉冲，
  否则提交后新建的 beat 表项永远等不到 commit；
- 同一 iid 多个 beat 之间的**同地址顺序**：首版由"anchor 顺序发射 + SQ 创建
  顺序"保证；如果 IO（indexed-ordered）重叠地址用例失败，再把 `uop_idx`
  加进 `sq_entry_*_same_addr_newer` 的比较；
- `sq_entry_sdid_hit` 仍比 sdid，数据配对不变。

#### 7.6.7 写回屏蔽

`RTU_idu_lsu_adapter.v`：

```systemverilog
assign cmplt_vld5 = lsu_rtu_wb_pipe3_cmplt & ~lsu_rtu_wb_pipe3_wb_preg_vec;
assign cmplt_vld6 = lsu_rtu_wb_pipe4_cmplt & ~lsu_rtu_wb_pipe4_vec;
```

同时把 `lsu_rtu_wb_pipe3_wb_preg_expand/vld` 在 vec 时清 0；`uop_idx` 当
preg 用时只服务于 LQ/MSHR/引擎，不能进 PRF 写口、IDU 唤醒、RTU 释放、
SDIQ dealloc 四处。

#### 7.6.8 SDIQ 与 store 数据

- 不扩 SDIQ；每个 store beat 复用现有 4 项之一；
- `ct_idu_is_sdiq.sv` 增加向量 create/issue 旁路：
  - `vec_sdiq_create_vld/entry`：由 fill 引擎给，按 4 项中空闲的分配；
  - 数据固定 **`8'b0000_0010`**（`x_create_data[7:1]=7'b0000001` 即
    preg0+ready，`src0_vld=0`）；**不是** 7 位 `{6'b0,1'b1}`（见 §9.3 的
    修正）；
  - 真实数据由 `vec_sd_data` 在 pipe5 mux；
  - 向量项不参与 `idu_rtu_pst_preg_dealloc_mask`（只 OR 0~3）；
- 地址与数据解耦：LSIQ beat 带 `sdiq_entry`，SDIQ 单独 issue，SQ 等数据
  （`sq_entry_settle_data_hit`）。

### 7.7 标量 `old` 的跨类型修正

anchor 让"标量 load 前面只有更老的向量 store"这种情况重新出现：

- 标量 LSIQ entry 的 `old` 只看 8 个 LSIQ 表项；
- 如果一条标量 load 前面只有更老的**向量** store，它会被误判成最老
  ⇒ `ld_dc_old=1` ⇒ 跳过 LQ 建表（`lsu_ld_dc.sv:308-312`）⇒ 更老的向量
  store 后到时无法通过 LQ 的 RAW spec-fail 触发重放 ⇒ **静默读旧值**。

修正只改 `old`，不动 `x_rdy`、不加跨队列发射门控：

```systemverilog
// 标量 LSIQ 表项 i（在 ct_idu_is_lsiq.sv 的 old 计算处）
wire lsiq_entry{i}_old_raw = /* 原来的 old 表达式 */;
assign lsiq_entry{i}_old = lsiq_entry{i}_old_raw &&
                           !(vec_old_vld &&
                             iid_older(vec_old_iid, lsiq_entry{i}_iid));
```

- `vec_old_iid/vld` 由 fill 引擎给：所有 active anchor 中最老的 iid；
- anchor 自己的 `oldest` 恒 0（保守地总是建 LQ）；
- `iid_older` 用 `RTU_iid_cmp.v:28-61` 的规则（回绕位相同比低 6 位；
  回绕位不同时低 6 位大的属于上一圈）；
- 发射顺序不设约束：谁 ready 谁发，LQ/SQ 的 RAW/WAR 本来就靠 iid 比较维护。

### 7.8 与"专用 tag 方案"的对比

| 维度 | 专用 4 tag（旧） | LSIQ anchor（本方案） |
|---|---|---|
| LSIQ 深度 | 8→12 | 8（不变） |
| agevec/old | 向量表项游离在标量年龄图外，需额外修 `old` | anchor 在正常年龄图内，天然有序 |
| 发射仲裁 | 引擎 vs 标量 LSIQ 另做仲裁+饥饿计数 | 复用原有 agevec 仲裁 |
| LSU 流水 | 仍是同一套 AG/DC/DA | 同一套 |
| 表项生命周期 | 引擎自己的 4 个 super slot | LSIQ 表项，最后 beat pop |
| 主要风险 | tag 宽度/仲裁/`old` 修正 | `frz/agevec/counter` 的 pop 门控、`uop_idx` 贯通 |
| 槽位效率 | 固定 4 个 | 每条向量指令 1 个 anchor（LMUL 动态不占额外槽） |

### 7.9 不变量（P5 必须始终成立）

1. 每条向量 L/S 指令在 LSIQ 里有**且只有一个** anchor；创建时 iid/agevec 固定；
2. anchor 在 `beat_last` 之前**不 pop**；`agevec/agevec_all/counter` 只在
   最后 beat 的 pop 上更新；
3. anchor 的 `frz` 在 `beat_done` 清、在最后 beat 发射后保持到 pop；
4. `uop_idx` 在**在飞**的 LQ/MSHR/SQ/写回里唯一；load 写回按
   `{iid, uop_idx}` 配对；
5. 向量 beat 的 `vec` 标记堵住 PRF 写口、IDU 唤醒、RTU preg 释放、SDIQ
   dealloc 四个泄漏点；
6. 向量 store 在提交前只 staging，不访问内存；提交后逐 beat 排空；
7. 标量 LSIQ/SDIQ 的行为在 `vec=0` 时与改前逐拍一致；
8. **vector load 的 beat 只在 anchor 是 LSIQ 最老项（`old=1`）时发射**；
   LQ 提前 pop 再带 `lq_entry_old` 兜底。否则更老 store 晚到 DC 会丢 RAW；
9. request index 只在对应 **LQ/SQ 表项弹出**后释放；store 不能在"数据捕获"
   时释放，否则复用会被旧 SQ 表项的 `inst_hit` 挡住。

> **异常范围**：本方案保证"合法页内、非对齐由 fill 引擎拆成对齐的 1/2/4B
> 请求"，不保证向量 L/S 的 page-fault/精确异常；这与 v1 顶部"不做精确异常"
> 的范围一致。若后续要支持精确异常，需要在 anchor 上加"所有 beat 完成才允许
> 提交"的门控。

### 7.10 验证入口（P5）

- 单元：`tb_ct_idu_is_lsiq_vec_anchor`：
  - 1 条 vector load，2 个 core uop、每 uop 3 个 beat；
  - 检查 anchor 创建/agevec/`old`/`beat_done`/最后 pop；
  - 检查 LQ 表项键 `{iid,uop_idx}`、提前 pop；
- 单元：`tb_rvv_ls_fill`：随机 core uop，随机 mask/eew，检查地址/合并/
  request index/staging；
- 系统：`asm/rvv_lsu`、`rvv_strided`、`rvv_indexed`、`rvv_mask_ls`、
  `rvv_flush_ls`；
- 专项：`rvv_store_after_load`（向量 store 后跟标量 load 同地址）、
  `rvv_age_order`（向量 L/S 与标量 L/S 交错）；
- 标量零回归：`a910-difftest-all` 与改动前逐项一致。


---

## 8. 信号增删汇总

### 8.1 新增（按模块）

| 模块 | 新增信号数 | 关键信号 |
|---|---|---|
| `ct_idu_id_decd` | 2 组 | `vec`、`vec_type[1:0]` |
| `ct_idu_id_dp` | 6 组 | IR 位宽 123→126 |
| `ct_idu_ir_dp` | 8 组 | ctrl_info 7→**9**（vec + vmem）、IS 76→79 |
| `ct_idu_ir_ctrl` | 3 组 | `ctrl_ir_pre_dis_vec_create0_{en,sel}` |
| `ct_idu_is_ctrl` | 7 组 | `ctrl_vec_create0/1_en`、`ctrl_dp_is_dis_vec_create0/1_sel` |
| `ct_idu_is_dp` | 4 组 | `dp_vec_create0_{data,iid}` |
| `ct_idu_vecq(+entry)` | 新模块 | VIQ_WIDTH=101；**2 create / 1 issue**；2 个 PRF 读口由 head 驱动；S3b 输出 `vecq_dp_issue_src{0,1}_wb`；**只有 vset 按 ready 门控** |
| `ct_idu_top` | 18 组 | `idu_vec_*`（含 src preg/wb）、`rvv_idu_vset_wb_*`；S3b 同拍 WB 旁路 |
| `ct_idu_rf_prf_pregfile` | 7 组 | 2 读口 + 1 写口 |
| `ct_idu_dep_reg_entry` + 6 队列 | 2 组 ×N | `rvv_idu_vset_wb_*` |
| `rvv_a910_bridge` | 新模块 | 全部 `rvv_*`/`core_*`；S3b 5 路 `scalar_wb_*` 直通 |
| `RvvCore`/`RvvFrontEnd` | 6+10 组 | cmplt/commit/config；S3b `src{0,1}_{vld,preg,wb,data}` + 按-iid 等待表写口 |
| `rvv_backend_rob` | 6 组 + 3 内部 | 完成链/提交门控 |
| `rvv_backend` | 6+S3b | 透传；S3b `src{0,1}_wt_tbl[0:127]` + RS 发车门控/数据修正 |
| `rvv_backend.svh` | 4 结构体 | LSU key 字段；S3b RVVCmd/UOP/RS 的 `rs1_preg/iid/vld/wb` |
| `ct_idu_is_lsiq_entry` / `ct_idu_is_lsiq` | 约 10 组 | `vec`/`vec_beat_rdy`/`vec_upd_*`/`beat_done`/beat 字段；LSIQ 仍 8 项；**向量 L/S 的标量基址等待用 LSIQ 表项自己的 dep entry** |
| `ct_idu_vec_ls_fill` | 新模块 | anchor 上下文、beat 生成、request index、load 拼装、store staging |
| `lsu_top` + 6 个 LSU 子模块 | 约 25 组 | `vec/uop_idx/last` 贯通 / `beat_done` / pop-last / LQ 提前 pop |
| `ct_idu_is_sdiq` | 约 5 组 | 向量 create/issue 旁路；SDIQ 仍 4 项 |
| `RTU_idu_lsu_adapter` | 2 组 | 向量写回屏蔽 |

### 8.2 删除的信号

**无。** 本计划不删除任何现有端口或内部信号。

唯一"停用"的现有通路：
- `rvv_top`/旧 wrapper 不存在，无需处理；
- 其余现有标量通路全部保留。

---

## 9. 验证探针（新信号可观测性）

| 探针 | 位置 | 用途 |
|---|---|---|
| `dut.u_ct_idu_top.u_ct_idu_vecq.vecq_xx_issue_en` | IDU | 向量指令发射 |
| `dut.u_rvv_bridge.u_rvv_core.backend.u_rob.uop_done` | core | uop 完成 |
| `dut.u_rvv_bridge.cmt_wmk_iid` | bridge | 提交水位 |
| `dut.u_rvv_bridge.u_rvv_core.backend.u_vrf.vrf_reg` | core | VRF 内容 |
| `dut.u_lsu_top.ld_ag_dc_vec` | LSU | 向量访存进入流水 |
| `dut.u_lsu_top.lsu_idu_beat_done` | LSU | 非最后 beat 的完成脉冲 |
| `dut.u_ct_idu_top.u_ct_idu_vec_ls_fill.ctx[*].beat_ptr` | IDU | 每个 anchor 的 beat 游标 |
| `dut.u_ct_idu_top.u_ct_idu_is_lsiq.lsiq_entry*_vec` | IDU | anchor 表项/年龄图 |

> 这些探针只用于仿真 TB / 波形，不写进可综合 RTL。

---

## 10. 实施顺序（信号依赖）

```
P0 编译基线
  └─ P1 IDU: id_decd → id_dp(IR 126) → ir_dp(ctrl 9 / IS 79) → ir_ctrl →
             is_ctrl → is_dp → vecq → top
       └─ P2 bridge + PRF 读/写口 + dep 唤醒 + RvvFrontEnd rs1
            └─ P3 ROB 完成链/提交水位/flush/配置恢复
                 └─ P4 计算类 + 迁移命名 vaiq/vmacq/vpq
                      └─ P5 LSU uop 扩展 + remap keyed scoreboard
                           + LSIQ anchor（create/beat/pop-last/beat_done）
                           + fill 引擎 ct_idu_vec_ls_fill
                           + LSU vec/uop_idx 贯通 + LQ/MSHR/SQ
```

每个阶段的出口判据见主计划（`~/.claude/plans/purrfect-churning-biscuit.md`）。
