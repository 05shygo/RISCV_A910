// =============================================================================
// ct_idu_vecq_defs.svh —— VIQ (向量队列) 101 位表项的字段定义
//
// 单一来源：ct_idu_vecq.sv / ct_idu_vecq_entry.sv / ct_idu_top.sv 共同 include。
// 用 `define 而不是 module parameter：VCS 默认把多个文件当同一编译单元，
// 带 ifndef 的 parameter 头在第二个模块里会被 guard 跳过 ⇒ 参数未声明。
//
//   [100:69] pc          —— 指令 PC (32)
//   [68:37]  opcode      —— 完整 32 位指令字
//   [36:30]  iid         —— A910 ROB iid (7)
//   [29:28]  vec_type    —— 01=向量 LOAD, 10=向量 STORE, 11=RVV
//   [27:22]  dst_preg    —— vset 的目的物理寄存器 (6)
//   [21:17]  dst_reg     —— vset 的目的逻辑寄存器 (5)
//   [16]     dst_vld
//   [15:9]   src1_data   —— {preg[5:0], wb} (7)
//   [8:2]    src0_data   —— {preg[5:0], wb} (7)
//   [1]      src1_vld
//   [0]      src0_vld
//
// ⚠️ 这个顺序必须与 ct_idu_is_dp.sv 的 101 位打包顺序逐位一致。
// =============================================================================
`ifndef CT_IDU_VECQ_DEFS_SVH
`define CT_IDU_VECQ_DEFS_SVH

`define VIQ_WIDTH      101
`define VIQ_PC         100   // [100:69]
`define VIQ_OPCODE     68    // [68:37]
`define VIQ_IID        36    // [36:30]
`define VIQ_VEC_TYPE   29    // [29:28]
`define VIQ_DST_PREG   27    // [27:22]
`define VIQ_DST_REG    21    // [21:17]
`define VIQ_DST_VLD    16
`define VIQ_SRC1_DATA  15    // [15:9]
`define VIQ_SRC0_DATA  8     // [8:2]
`define VIQ_SRC1_VLD   1
`define VIQ_SRC0_VLD   0

`endif // CT_IDU_VECQ_DEFS_SVH
