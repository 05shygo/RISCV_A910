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
// ---- 物理寄存器数量 (构建期可配: 64 / 96) ----------------------------------
// `RTU_PREG64` 定义 ⇒ 64 项 (与同事交付的 C910 IDU 的 6 位 preg 直接对得上);
// 不定义 ⇒ 96 项 (**默认, 与 D-cache LSU 的 96 preg / LSIQ 12 项一致**)。
// 开关走 Makefile 的 `PREG=64|96`, 由带配置戳的 define 传进来 (见 doc/rtu_preg_size_config_zh.md)。
// ⚠️ 只有**池子**跟着变 (`RTU_preg.v` 内部): 数组 / 掩码 / 选择树 / 计数器的复位常数。
//    端口位宽、ROB 表项位域、AMT 一律**固定取最大值** —— 64 档下编号的最高位恒 0,
//    将来接 IDU 时由适配层切 [5:0]。这样改配置不碰任何其它模块, 两个档共用一份 §6 契约。
`ifdef RTU_PREG64
`define RTU_NUM_PREG    64          // 物理寄存器数
`else
`define RTU_NUM_PREG    96          // 物理寄存器数
`endif
`define RTU_PREG_W      7           // 端口/表项的编号位宽 —— **固定 7** (= log2(96)), 不随档变
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

// ---- preg 五态 (D2) ----
// ⚠️ 2026-10-07 起是**门房语义**: 号被选中**补进门房(tap)**那一拍 FREE→WF_ALLOC,
//    派遣认领那一拍 WF_ALLOC→ALLOC (两者相隔几拍不限)。见 §6.0 与
//    doc/rtu_preg_alloc_plan_zh.md。
// ⚠️ WF_ALLOC 不是多余的簿记 —— 它是给优先编码器打拍用的, 砍了就把它
//    串进派遣链 (§4.2 P3)。
// ⚠️ **2026-10-08 加了第 5 态 RELEASE** (2 bit → 3 bit)。理由与 C910 的 RELEASE
//    不同: C910 那条是给"快速退休/折叠"用的 (所以本核当初把它并掉了), 我们这条
//    是给 **store 数据读的 WAR** 用的 —— store 的"完成"不蕴含"数据已读"
//    (lsu_st_da.sv 的 st_da_wb_cmplt_req 只看地址流水走完), 于是更年轻的那条
//    覆盖同一条 lreg 的指令退休时, 会把 store 还要读的那个号放回池子。
//    现在: 释放一律先落 RELEASE, 等 IDU 的 dealloc mask 把这个号撤下来才回 FREE。
`define RTU_P_FREE      3'd0        // 在自由池里, 可被分配
`define RTU_P_WFALLOC   3'd1        // 已出池、备在门房里, 等派遣认领
`define RTU_P_ALLOC     3'd2        // 已分配给在途指令(推测态)
`define RTU_P_ARCH      3'd3        // 已是架构态(某个 lreg 的当前映射)
`define RTU_P_RELEASE   3'd4        // 已被顶掉但**还被 store 引用着**, 等 mask 落下才回 FREE

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

// ---- ROB 表项位域 (125 bit, D4) ----
// 布局与 D4 的表格逐行对应; 表项模块的拼接顺序必须与这里一致。
//   [124] replay (2026-10-08 新增, 加在**最高位**)  [123] vld  [122] cmplt
//   [121] wrap  [120:89] pc   [88:57] target   [56:32] chk   [31:27] dst_lreg
//   [26:20] dst_preg [19:13] old_preg [12:6] flags [5] rf_we
//   [4] actual_taken [3] mispred [2:0] sq_id
//   ⚠️ 新位加在最高位是为了**不动任何老字段的位置** —— 挤在低位会让所有位域整体
//      挪一格, 而拼接是隐式零扩展的、写错了不报错 (2026-10-08 踩过)。
// 为什么不存完整 iid: iid = {wrap, 本表项固定索引}, 索引是常量 (§4.3 第 2 条)。
// ⚠️ 2026-10-02: 122 → 124 —— flags 由 5 位扩到 7 位 (加 JAL/JALR, 见上)。
`define RTU_E_W        125
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
// `replay`: 这条指令**要重放** —— 由 LSU 在完成那一拍报回来
//   (对应 `lsu_rtu_wb_pipe4_flush` / `_spec_fail`: store 的投机写失败)。
//   置位后它**不能退休**(它的 store 不许落内存), 等它走到退休窗口最前面时
//   触发一次 `RTU_FS_REPLAY` 冲刷 + 从它的 PC 重取。见 RTU_commit 的仲裁注释。
`define RTU_E_REPLAY   124

// ---- 冲刷来源 (D11 的优先级: 异常/中断 > mret > 误预测) ----
// ⚠️ 2026-10-08: 由 2 位扩到 3 位 —— 加了第 5 类 `REPLAY` (LSU 报的 store 重放)。
`define RTU_FS_EXPT     3'd0
`define RTU_FS_INT      3'd1
`define RTU_FS_MRET     3'd2
`define RTU_FS_MISPRED  3'd3
`define RTU_FS_REPLAY   3'd4     // store 投机失败 ⇒ 冲掉它和更年轻的, 从它的 PC 重取
                                 //   (与误预测的区别: **要重启前端** —— 见 RTU_flush)

// 中断的 cause: MTIP (与 defines.vh 的 INTR_MTIP_CAUSE 同值, 这里自带一份,
// 免得退休单元的非测试台也得去 include 核的 defines.vh)
`define RTU_CAUSE_MTIP  5'd7

`endif
