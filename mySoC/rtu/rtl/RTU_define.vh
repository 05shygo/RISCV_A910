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
`define RTU_ARCH_PREG   32          // p0..p31 = x0..x31 初始映射, 永不释放
`define RTU_NUM_LREG    32
`define RTU_CMPLT_PORTS 5           // ALU0/1/2 + BEU + MUL/DIV/LSU 汇总

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
`define RTU_FLUSH_LAT   2           // 冲刷状态机拍数: F1 -> F2 -> IDLE
`define RTU_FSM_IDLE    2'd0
`define RTU_FSM_F1      2'd1
`define RTU_FSM_F2      2'd2

// ---- disp_flags 的位序 (§6.1, 5 位) ----
`define RTU_FLG_BRANCH  0
`define RTU_FLG_STORE   1
`define RTU_FLG_INTMASK 2
`define RTU_FLG_CSR     3
`define RTU_FLG_MRET    4

`endif
