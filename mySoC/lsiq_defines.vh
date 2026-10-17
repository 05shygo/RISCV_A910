// ---------------------------------------------------------------------------
// lsiq_defines —— LSIQ (load/store 发射队列) 的深度, 供**跨模块的端口位宽**使用。
//
// 为什么用 `define 而不是 parameter: LSIQ 的那几根一位一项的向量 (one-hot lsid /
//   lq_full / sq_full / ...) 要穿过 ct_idu_is_lsiq → ct_idu_rf_dp → ct_idu_top →
//   A910_cpu → lsu_top 五六层, 逐层传参只会多出五六处改错的机会; 而且 **ANSI 端口
//   位宽只能用宏, 不能用模块内的 localparam** (端口列表先于模块体解析)。
//   本仓已有 mySoC/defines.vh 与 mySoC/rtu/rtl/RTU_define.vh 两个先例。
//
// 单一真源: 只认编译期的 `+define+LSIQ_ENTRY=N` (默认 12, 即 C910 原版深度)。
//   不定义 ⇒ 12。要回退到 8 (改动前的基线) 就传 `+define+LSIQ_ENTRY=8`。
//   A910 那几条规则不挂 BP_DEFS, 所以走 `VCS_FLAGS_EXTRA`:
//     make a910-difftest TEST=... A910_DT_BUILD=$PWD/obj_xxx \
//          VCS_FLAGS_EXTRA="+define+AIQ_ENTRY=16 +define+LSIQ_ENTRY=8"
//
// ⚠️ 每个用到的文件都要自己 `include "lsiq_defines.vh"` —— 不要靠文件顺序白嫖宏
//    定义 (CORE_DESIGN.md §2.1 记着 IDU 搬家时 13 个文件白嫖宏的那次)。
// ⚠️ `ct_idu_is_lsiq{,_entry}.sv` 自己带 `ifdef LSIQ_ENTRY 的 ANSI 参数口, 读的是
//    **同一个** `+define` —— 两边必须由这一条真源驱动, 改一半会"看起来能编"但位宽
//    对不上 (静默截断)。
// ---------------------------------------------------------------------------
`ifndef LSIQ_DEFINES_VH
`define LSIQ_DEFINES_VH

`ifdef LSIQ_ENTRY
`define LSIQ_NUM   `LSIQ_ENTRY
`else
`define LSIQ_NUM   12
`endif

`endif // LSIQ_DEFINES_VH
