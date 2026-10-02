// ---------------------------------------------------------------------------
// RTU_define — 退休单元的参数与状态编码 (doc/rtu_plan_zh.md §4)
//
// 为什么用 `define 而不是 parameter: 这些常量要穿过 RTU → RTU_ROB → RTU_ROB_entry
// 三层层次, 逐层传参只会多出三处改错的机会; 本仓已有 mySoC/defines.vh 的先例。
//
// ⚠️ 每个用到的 .v 都要自己 `include "RTU_define.vh"` —— 不要靠文件顺序白嫖宏定义
//    (CORE_DESIGN.md §2.1 记着 IDU 搬家时 13 个文件白嫖宏的那次)。
// ⚠️ 本文件在 mySoC/rtu/rtl/ 里, 与使用者同目录 —— VCS 与 Vivado 都先按"包含者
//    所在目录"解析。构建侧另外显式加了 incdir/include_dirs, 三处都要在:
//    Makefile 的 INC、synth/build_fmax.tcl 的 include_dirs、Makefile.verilator 的 -I。
// ---------------------------------------------------------------------------
`ifndef RTU_DEFINE_VH
`define RTU_DEFINE_VH

`define RTU_ROB_DEPTH   64          // 表项数 (只能取 2 的幂, 见 §4.3)
`define RTU_ROB_AW      6           // log2(DEPTH)
`define RTU_IID_W       7           // ROB_AW + 1 位回绕
`define RTU_DISP_W      3           // 每拍派遣宽度 = 发射宽度
`define RTU_RETIRE_W    3           // 每拍退休宽度
`define RTU_NUM_PREG    96          // 物理寄存器数
`define RTU_PREG_W      7           // log2(NUM_PREG)
// ⚠️ 2026-10-02: 原来这里还有一个 `RTU_ARCH_PREG 32`, 注释写的是
//    "p0..p31 = x0..x31 初始映射, 永不释放"。D1.2 之后初始映射**会被回收**
//    (位置随改名漂移), 那句话不再成立; 而这个宏**全仓零引用** —— 留着只会
//    误导人, 故删除。需要 "32 个架构寄存器" 这个数时用 `RTU_NUM_LREG`。
`define RTU_NUM_LREG    32
// ---- 完成口 / 解析口的路数 (D1.3 / D1.4, 2026-10-02 定案) ----
// 完成口 7 = 3×ALU + BEU + MUL/DIV + **LSU 读 + LSU 写分开**
//   (改前是 5: MUL/DIV 与 LSU 挤在一个口上)
// 解析口 1 = **分支执行单元的条数** (本核 1 个 BEU)。
//   ⚠️ 口径: 解析吞吐受"分支单元数"限制, 不受发射宽度限制 —— 3 发射但有 1 个 BEU
//   时, 一拍最多仍只有一条分支解析出来 (2026-10-02 一度按发射宽度做成 3 路,
//   当天收回)。
// ⚠️ 这两个宏**必须与端口表一致**, 但 Verilog 的扁平端口表没法由宏生成 ——
//    所以 RTU.v 里配了一个 generate 期的路数自检 (路数对不上就 elaborate 失败),
//    免得出现"改了宏没生效"那类静默错 (§9 R7)。
`define RTU_CMPLT_PORTS   7
`define RTU_RESOLVE_PORTS 1

// ---- preg 四态 (D2) ----
// 两拍分配: T 拍优先编码选中 FREE→WF_ALLOC, T+1 派遣确认 WF_ALLOC→ALLOC。
// ⚠️ WF_ALLOC 不是多余的簿记 —— 它是给 96 位优先编码器打拍用的, 砍了就把它
//    串进派遣链 (§4.2 P3)。
`define RTU_P_FREE      2'd0        // 在自由池里, 可被分配
`define RTU_P_WFALLOC   2'd1        // 已被选中, 等下一拍派遣确认
`define RTU_P_ALLOC     2'd2        // 已分配给在途指令(推测态)
`define RTU_P_ARCH      2'd3        // 已是架构态(某个 lreg 的当前映射)

// ---- ROB 满的判据 (§4 不变量 1) ----
// 用计数器 + 留空位, 不用指针比较: 一拍最多派 3 条, 留 RSV 个空位就置 full。
// 留空位顺带把 full 变成"只依赖寄存器值"(§4.2 P8) —— 停顿晚一拍也无害。
`define RTU_ROB_RSV     4
`define RTU_ROB_FULL_TH (`RTU_ROB_DEPTH - `RTU_ROB_RSV)   // 占用 >= 60 即 full

// ---- flush 相关 (D11) ----
// ⚠️ 2026-10-02: F1/F2 合成一拍 ⇒ 状态数从 3 降到 2 (IDLE -> F1 -> IDLE),
//    派遣冻结 3 拍 -> 2 拍, CoreMark 实测 +1.48%。见 RTU_flush.v 的 FSM 长注。
`define RTU_FLUSH_LAT   1           // 冲刷状态机拍数 (F1 那一级); 全部动作都在这拍
`define RTU_FSM_IDLE    2'd0
`define RTU_FSM_F1      2'd1
`define RTU_FSM_F2      2'd2        // ⚠️ **已废弃**: 合成一拍后不再使用 (留着只占编码, 无人引用)

// ---- disp_flags 的位序 (§6.1, 7 位) ----
`define RTU_FLG_BRANCH  0
`define RTU_FLG_STORE   1
`define RTU_FLG_INTMASK 2
`define RTU_FLG_CSR     3
`define RTU_FLG_MRET    4
// ⚠️ JAL/JALR 两位是 **2026-10-02 为阶段 4b 加的** (原来 5 位)。
//    BTB 的训练口要 `upd_cond / upd_jal / upd_jalr` 三分类, 而 `is_branch` 只有
//    "是不是控制转移"这一位 —— 原来这个分类是 EX 当拍从 `ex_npc_op/ex_is_jump/
//    ex_is_jalr` 现算的, 搬到退休点之后必须由表项提供。
//    三分类互斥: 条件分支 = BRANCH & ~JAL & ~JALR (本核 JALR 走 `NPC_SEL_ALU`)。
`define RTU_FLG_JAL     5
`define RTU_FLG_JALR    6

// ---- ROB 表项位域 (124 bit, D4) ----
// 布局与 D4 的表格逐行对应; 表项模块的拼接顺序必须与这里一致。
//   [123] vld   [122] cmplt  [121] wrap  [120:89] pc   [88:57] target
//   [56:32] chk [31:27] dst_lreg [26:20] dst_preg [19:13] old_preg [12:6] flags
//   [5] rf_we   [4] actual_taken [3] mispred [2:0] sq_id
// 为什么不存完整 iid: iid = {wrap, 本表项固定索引}, 索引是常量 (§4.3 第 2 条)。
// ⚠️ 2026-10-02: 122 → 124 —— flags 由 5 位扩到 7 位 (加 JAL/JALR, 见上)。
`define RTU_E_W        124
`define RTU_E_VLD      123
`define RTU_E_CMPLT    122
`define RTU_E_WRAP     121
`define RTU_E_PC       120:89
`define RTU_E_TARGET   88:57
`define RTU_E_CHK      56:32
`define RTU_E_DST_LREG 31:27
`define RTU_E_DST_PREG 26:20
`define RTU_E_OLD_PREG 19:13
`define RTU_E_FLAGS    12:6
`define RTU_E_RF_WE    5
`define RTU_E_TAKEN    4
`define RTU_E_MISPRED  3
`define RTU_E_SQ_ID    2:0

// ---- 冲刷来源 (D11 的优先级: 异常/中断 > mret > 误预测) ----
`define RTU_FS_EXPT     2'd0
`define RTU_FS_INT      2'd1
`define RTU_FS_MRET     2'd2
`define RTU_FS_MISPRED  2'd3

// 中断的 cause: MTIP (与 defines.vh 的 INTR_MTIP_CAUSE 同值, 这里自带一份,
// 免得退休单元的非测试台也得去 include 核的 defines.vh)
`define RTU_CAUSE_MTIP  5'd7

`endif
