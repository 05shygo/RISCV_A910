module ct_idu_top(
  //==========================================================
  // Global signals
  //==========================================================
  input  logic         forever_cpuclk,
  input  logic         cpurst_b,

  //==========================================================
  // Interface with IFU (Instruction Fetch Unit)
  //==========================================================
  input  logic         ifu_idu_ib_inst0_vld,
  input  logic         ifu_idu_ib_inst1_vld,
  input  logic         ifu_idu_ib_inst2_vld,
  input  logic [96:0]  ifu_idu_ib_inst0_data,
  input  logic [24:0]  ifu_idu_if_inst0_chk,
  input  logic [96:0]  ifu_idu_ib_inst1_data,
  input  logic [24:0]  ifu_idu_if_inst1_chk,
  input  logic [96:0]  ifu_idu_ib_inst2_data,
  input  logic [24:0]  ifu_idu_if_inst2_chk,
  output logic [1:0]   idu_accept_num,

  //==========================================================
  // Interface with RTU (Retire Unit)
  //==========================================================
  input  logic         rtu_idu_alloc_preg0_vld,
  input  logic         rtu_idu_alloc_preg1_vld,
  input  logic         rtu_idu_alloc_preg2_vld,
  input  logic [5:0]   rtu_idu_alloc_preg0,
  input  logic [5:0]   rtu_idu_alloc_preg1,
  input  logic [5:0]   rtu_idu_alloc_preg2,
  input  logic [6:0]   rtu_idu_rob_inst0_iid,
  input  logic [6:0]   rtu_idu_rob_inst1_iid,
  input  logic [6:0]   rtu_idu_rob_inst2_iid,
  input  logic         rtu_idu_rob_full,
  input  logic [191:0] rtu_idu_rt_recover_preg,
  input  logic         rtu_yy_xx_flush,
  output logic         idu_rtu_ir_preg0_alloc_vld,
  output logic         idu_rtu_ir_preg1_alloc_vld,
  output logic         idu_rtu_ir_preg2_alloc_vld,
  output logic [63:0]  idu_rtu_pst_preg_dealloc_mask,

  //==========================================================
  // Interface with IU (Integer Unit) - Writeback
  //==========================================================
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [31:0]  iu_idu_ex2_pipe0_wb_preg_data,
  input  logic [63:0]  iu_idu_ex2_pipe0_wb_preg_expand,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [31:0]  iu_idu_ex2_pipe1_wb_preg_data,
  input  logic [63:0]  iu_idu_ex2_pipe1_wb_preg_expand,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld,

  //==========================================================
  // Interface with LSU (Load Store Unit) - Writeback
  //==========================================================
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic [31:0]  lsu_idu_wb_pipe3_wb_preg_data,
  input  logic [63:0]  lsu_idu_wb_pipe3_wb_preg_expand,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld,

  //==========================================================
  // Interface with LSU - LSIQ control
  //==========================================================
  input  logic [7:0]   lsu_idu_lq_full,
  input  logic         lsu_idu_lq_not_full,
  input  logic [7:0]   lsu_idu_rb_full,
  input  logic         lsu_idu_rb_not_full,
  input  logic [7:0]   lsu_idu_sq_full,
  input  logic         lsu_idu_sq_not_full,
  input  logic [7:0]   lsu_idu_secd,
  input  logic [7:0]   lsu_idu_imme_wakeup,
  input  logic         lsu_idu_lsiq_pop_vld,
  input  logic         lsu_idu_lsiq_pop0_vld,
  input  logic         lsu_idu_lsiq_pop1_vld,
  input  logic [7:0]   lsu_idu_lsiq_pop_entry,

  //==========================================================
  // Interface with LSU - SDIQ control
  //==========================================================
  input  logic         lsu_sdiq_has_in_sq_vld,
  input  logic [3:0]   lsu_sdiq_has_in_sq_sdiq,

  //==========================================================
  // Output to AIQ (ALU Issue Queue)
  //==========================================================
  output logic         idu_aiq_sel,
  output logic [6:0]   idu_aiq_iid,
  output logic [5:0]   idu_aiq_dst_preg,
  output logic [31:0]  idu_aiq_src0,
  output logic [31:0]  idu_aiq_src1,
  output logic [31:0]  idu_aiq_pc,        // 2026-10-08 新增: AUIPC 要用 (见 rf_dp 的说明)
  output logic [12:0]  idu_aiq_rslt_sel,
  output logic         idu_aiq_illegal,

  //==========================================================
  // Output to MULT (Multiply Unit)
  //==========================================================
  output logic         idu_mult_sel,
  output logic [6:0]   idu_mult_iid,
  output logic [5:0]   idu_mult_dst_preg,
  output logic [31:0]  idu_mult_src0,
  output logic [31:0]  idu_mult_src1,
  output logic [3:0]   idu_mult_rslt_sel,

  //==========================================================
  // Output to DIV (Divide Unit)
  //==========================================================
  output logic         idu_div_sel,
  output logic [6:0]   idu_div_iid,
  output logic         idu_div_dst_vld,
  output logic [5:0]   idu_div_dst_preg,
  output logic [31:0]  idu_div_src0,
  output logic [31:0]  idu_div_src1,
  output logic [3:0]   idu_div_rslt_sel,

  //==========================================================
  // Output to LSU - Load pipe
  //==========================================================
  output logic         idu_lsu_ld_sel,
  output logic [6:0]   idu_lsu_ld_iid,
  output logic [5:0]   idu_lsu_ld_preg,
  output logic [31:0]  idu_lsu_ld_src0,
  output logic [11:0]  idu_lsu_ld_offset,
  output logic [12:0]  idu_lsu_ld_offset_plus,
  output logic         idu_lsu_ld_sign_extend,
  output logic [1:0]   idu_lsu_ld_inst_size,
  output logic         idu_lsu_ld_unalign_2nd,
  output logic [7:0]   idu_lsu_ld_lch_entry,
  output logic         idu_lsu_ld_oldest,

  //==========================================================
  // Output to LSU - Store pipe
  //==========================================================
  output logic         idu_lsu_st_sel,
  output logic [6:0]   idu_lsu_st_iid,
  output logic [5:0]   idu_lsu_st_preg,
  output logic [31:0]  idu_lsu_st_src0,
  output logic [11:0]  idu_lsu_st_offset,
  output logic [12:0]  idu_lsu_st_offset_plus,
  output logic [1:0]   idu_lsu_st_inst_size,
  output logic         idu_lsu_st_unalign_2nd,
  output logic [7:0]   idu_lsu_st_lch_entry,
  output logic         idu_lsu_st_oldest,
  output logic [3:0]   idu_lsu_st_sdiq_entry,

  //==========================================================
  // Output to LSU - SDIQ pipe
  //==========================================================
  output logic         idu_lsu_sdiq_sel,
  output logic [3:0]   idu_lsu_rf_pipe5_sdiq_entry,
  output logic [31:0]  idu_lsu_rf_pipe5_src0,

  //==========================================================
  // Output to BIQ (Branch Issue Queue)
  //==========================================================
  output logic         idu_biq_sel,
  output logic [6:0]   idu_biq_iid,
  output logic [31:0]  idu_biq_src0,
  output logic [31:0]  idu_biq_src1,
  output logic [5:0]   idu_biq_rslt_sel,
  output logic [31:0]  idu_biq_br_imme,
  output logic         idu_biq_dst_vld,
  output logic [5:0]   idu_biq_dst_preg,
  output logic         idu_biq_taken,
  output logic [31:0]  idu_biq_npc,
  output logic [31:0]  idu_biq_pc,
  output logic [24:0]  idu_biq_chk,

  //==========================================================
  // Interface with RTU — 派遣记录 (2026-10-08 新增)
  //==========================================================
  // k = 0/1/2 = **程序序** (0 最老)。RTU 的 §6.1 契约:
  //   * 一拍最多 3 条, 必须是程序序前缀 —— 这里天然满足: `_vld{k}` 直接来自
  //     IS 级那三路的有效位;
  //   * **必须与"真的进了 ROB"同源** —— 见下面 ctrl_dp_dis_inst{k}_vld 的说明;
  //   * A6d: `rf_we == 0` 时 `dst_lreg` **必须给 0** (不能给垃圾 rd, 否则 RTU 会
  //     按"要写 rd"去分配编号而退休时又不写 ⇒ 编号静默泄漏)。本模块的
  //     IS_DST_REG 字段在译码阶段就已按 dst_vld 清过, 这里照搬;
  //   * A6b: `rf_we` 必须与写回级同源 —— 这里就是 IS_DST_VLD(与它进发射队列的
  //     那一份同源), 不是用 rd != 0 现推的;
  //   * A6c: `csr_op` 给 **funct3 原样** (从原始指令字切 [14:12]), 不是译码后的
  //     两位码 —— 否则 csrrwi 会被当成寄存器形式。
  //
  // ⚠️ `_sq_id` **故意没有** —— 见 doc/idu_rtu_接口待办.txt 的讨论: IDU 这边的
  //    SDIQ (4 项) 不是 LSU 的 SQ (6 项), 两者不是同一个队列; 且 LSU 那侧是按
  //    **iid 广播**找表项的 (rtu_yy_xx_commit*), 根本不需要槽号。要不要这根线
  //    等跟 LSU 确认后再定, 现在不造一根语义不清的。
  output logic         idu_rtu_disp0_vld,
  output logic [31:0]  idu_rtu_disp0_pc,
  output logic [24:0]  idu_rtu_disp0_chk,
  output logic [4:0]   idu_rtu_disp0_dst_lreg,
  output logic         idu_rtu_disp0_rf_we,
  output logic [6:0]   idu_rtu_disp0_dst_preg,
  output logic [6:0]   idu_rtu_disp0_old_preg,
  output logic [6:0]   idu_rtu_disp0_src1_preg,
  output logic [11:0]  idu_rtu_disp0_csr_addr,
  output logic [2:0]   idu_rtu_disp0_csr_op,
  output logic [4:0]   idu_rtu_disp0_csr_imm,
  output logic [6:0]   idu_rtu_disp0_flags,

  output logic         idu_rtu_disp1_vld,
  output logic [31:0]  idu_rtu_disp1_pc,
  output logic [24:0]  idu_rtu_disp1_chk,
  output logic [4:0]   idu_rtu_disp1_dst_lreg,
  output logic         idu_rtu_disp1_rf_we,
  output logic [6:0]   idu_rtu_disp1_dst_preg,
  output logic [6:0]   idu_rtu_disp1_old_preg,
  output logic [6:0]   idu_rtu_disp1_src1_preg,
  output logic [11:0]  idu_rtu_disp1_csr_addr,
  output logic [2:0]   idu_rtu_disp1_csr_op,
  output logic [4:0]   idu_rtu_disp1_csr_imm,
  output logic [6:0]   idu_rtu_disp1_flags,

  output logic         idu_rtu_disp2_vld,
  output logic [31:0]  idu_rtu_disp2_pc,
  output logic [24:0]  idu_rtu_disp2_chk,
  output logic [4:0]   idu_rtu_disp2_dst_lreg,
  output logic         idu_rtu_disp2_rf_we,
  output logic [6:0]   idu_rtu_disp2_dst_preg,
  output logic [6:0]   idu_rtu_disp2_old_preg,
  output logic [6:0]   idu_rtu_disp2_src1_preg,
  output logic [11:0]  idu_rtu_disp2_csr_addr,
  output logic [2:0]   idu_rtu_disp2_csr_op,
  output logic [4:0]   idu_rtu_disp2_csr_imm,
  output logic [6:0]   idu_rtu_disp2_flags,

  //==========================================================
  // Interface with RTU — 物理寄存器堆访问 (2026-10-08 新增)
  //==========================================================
  // 退休级要**按物理号**取数: difftest 的提交值(3 个退休槽) + CSR 指令的 rs1 源操作数。
  // 交付的 PRF 是 11 读 3 写、全被内部占满 ⇒ 这 4 个读口 + 1 个写口都是新加的
  // (见 ct_idu_rf_prf_pregfile 的说明与 RTU §6.1 的 A1/A5)。
  //
  // ⚠️ 地址是 **6 位**(PRF 是 64 档), RTU 侧是 7 位 ⇒ 由适配层切位后送进来。
  // ⚠️ 读口是**组合**的: 退休那拍必须已经写回(顺序由 RTU 的"只有完成的才准退休"保证)。
  input  logic [5:0]   rtu_preg_raddr0,
  input  logic [5:0]   rtu_preg_raddr1,
  input  logic [5:0]   rtu_preg_raddr2,
  input  logic [5:0]   rtu_csr_src_raddr,
  input  logic         rtu_csr_rd_we,
  input  logic [5:0]   rtu_csr_rd_addr,
  input  logic [31:0]  rtu_csr_rd_wdata,
  output logic [31:0]  rtu_preg_rdata0,
  output logic [31:0]  rtu_preg_rdata1,
  output logic [31:0]  rtu_preg_rdata2,
  output logic [31:0]  rtu_csr_src_rdata
);

//==========================================================
// Internal Signal Declarations
//==========================================================

//==========================================================
//  【2026-10-08 补】顶层缺失的信号声明 —— 共 38 根
//==========================================================
// ⚠️ 这些信号在本文件里**从来没被声明过**，而它们是 Verilog 的**隐式 1 位线网**
//    （`default_nettype wire`）⇒ 连到多位端口时**被静默截断成 1 位**。
//    后果: **整条发射通路是断的** ——
//      * `aiq_dp_issue_read_data` 应该是 96 位 (AIQ 读出的整条指令信息),
//        截成 1 位后 ALU 拿到的 iid/src/preg/opcode 全是垃圾;
//      * 所有 `*_create*_sel[1:0]` 截成 1 位 ⇒ 2 选 1 的 create 口 mux
//        永远只能区分 0/1 两路, 第 3 路选不中;
//      * biq/mult/div/lsiq/sdiq 的读出数据同理。
//    本仓历史上栽过三次同一类坑 (漏声明 → 隐式线网 → 静默失效, 见 mycpu.v 的注释),
//    这是第四次, 而且是面积最大的一次。宽度取自各自的端口定义 (取最宽的那个口)。
//==========================================================
logic [95:0] aiq_dp_issue_read_data;
logic [151:0] biq_dp_issue_read_data;
logic [1:0] ctrl_dp_is_dis_aiq_create0_sel;
logic [1:0] ctrl_dp_is_dis_aiq_create1_sel;
logic [1:0] ctrl_dp_is_dis_biq_create0_sel;
logic [1:0] ctrl_dp_is_dis_biq_create1_sel;
logic [1:0] ctrl_dp_is_dis_div_create0_sel;
logic [1:0] ctrl_dp_is_dis_div_create1_sel;
logic [1:0] ctrl_dp_is_dis_lsiq_create0_sel;
logic [1:0] ctrl_dp_is_dis_lsiq_create1_sel;
logic [1:0] ctrl_dp_is_dis_mult_create0_sel;
logic [1:0] ctrl_dp_is_dis_mult_create1_sel;
logic [1:0] ctrl_dp_is_dis_sdiq_create0_sel;
logic [1:0] ctrl_dp_is_dis_sdiq_create1_sel;
logic [1:0] ctrl_ir_pre_dis_aiq_create0_sel;
logic [1:0] ctrl_ir_pre_dis_aiq_create1_sel;
logic [1:0] ctrl_ir_pre_dis_biq_create0_sel;
logic [1:0] ctrl_ir_pre_dis_biq_create1_sel;
logic [1:0] ctrl_ir_pre_dis_div_create0_sel;
logic [1:0] ctrl_ir_pre_dis_div_create1_sel;
logic [1:0] ctrl_ir_pre_dis_lsiq_create0_sel;
logic [1:0] ctrl_ir_pre_dis_lsiq_create1_sel;
logic [1:0] ctrl_ir_pre_dis_mult_create0_sel;
logic [1:0] ctrl_ir_pre_dis_mult_create1_sel;
logic [1:0] ctrl_ir_pre_dis_sdiq_create0_sel;
logic [1:0] ctrl_ir_pre_dis_sdiq_create1_sel;
logic [62:0] div_dp_issue_read_data;
logic [59:0] lsiq_dp_pipe3_entry_read_data;
logic [7:0] lsiq_dp_pipe3_issue_entry;
logic [59:0] lsiq_dp_pipe3_issue_read_data;
logic [59:0] lsiq_dp_pipe4_entry_read_data;
logic [7:0] lsiq_dp_pipe4_issue_entry;
logic [59:0] lsiq_dp_pipe4_issue_read_data;
logic [62:0] mult_dp_issue_read_data;
logic [3:0] sdiq_create0_entry;
logic [3:0] sdiq_create1_entry;
logic [3:0] sdiq_dp_issue_entry;
logic [7:0] sdiq_dp_issue_read_data;

logic         idu_ifu_inst0_ready;
logic         idu_ifu_inst1_ready;
logic         idu_ifu_inst2_ready;
logic  [1:0]  idu_accept_num;
assign idu_accept_num[1:0] = {idu_ifu_inst2_ready | idu_ifu_inst0_ready, idu_ifu_inst2_ready};

// ID Stage signals
logic        id_inst0_vld;
logic        id_inst1_vld;
logic        id_inst2_vld;
logic        ctrl_dp_id_stall;
logic [121:0] dp_id_pipedown_inst0_data;
logic [24:0]  dp_id_pipedown_inst0_chk;
logic [121:0] dp_id_pipedown_inst1_data;
logic [24:0]  dp_id_pipedown_inst1_chk;
logic [121:0] dp_id_pipedown_inst2_data;
logic [24:0]  dp_id_pipedown_inst2_chk;

// IR Stage control signals
logic        ctrl_ir_stall;
logic        ctrl_ir_pipedown;
logic        ctrl_ir_inst2_vld;
logic        ctrl_ir_pre_dis_aiq0_create0_en;
logic        ctrl_ir_pre_dis_aiq0_create1_en;
logic        ctrl_ir_pre_dis_aiq1_create0_en;
logic        ctrl_ir_pre_dis_biq_create0_en;
logic        ctrl_ir_pre_dis_biq_create1_en;
logic        ctrl_ir_pre_dis_biq_create2_en;
logic        ctrl_ir_pre_dis_lsiq_create0_en;
logic        ctrl_ir_pre_dis_lsiq_create1_en;
logic        ctrl_ir_pre_dis_lsiq_create2_en;
logic        ctrl_ir_pre_dis_mult_create0_en;
logic        ctrl_ir_pre_dis_div_create0_en;

// IR Stage datapath signals
logic [6:0]  dp_ctrl_ir_inst0_ctrl_info;
logic [6:0]  dp_ctrl_ir_inst1_ctrl_info;
logic [6:0]  dp_ctrl_ir_inst2_ctrl_info;
logic        dp_ctrl_ir_inst0_dst_vld;
logic        dp_ctrl_ir_inst1_dst_vld;
logic        dp_ctrl_ir_inst2_dst_vld;
logic        dp_ctrl_ir_inst0_dst_x0;
logic        dp_ctrl_ir_inst1_dst_x0;
logic        dp_ctrl_ir_inst2_dst_x0;
logic        dp_ctrl_ir_inst0_illegal;
logic        dp_ctrl_ir_inst1_illegal;
logic        dp_ctrl_ir_inst2_illegal;
logic [96:0] crtl_ir_inst2_data;
logic [24:0] crtl_ir_inst2_chk;
logic [82:0] dp_ir_inst0_data;
logic [64:0] dp_ir_inst0_pc;
logic [24:0] dp_ir_inst0_chk;
logic [82:0] dp_ir_inst1_data;
logic [64:0] dp_ir_inst1_pc;
logic [24:0] dp_ir_inst1_chk;
logic [82:0] dp_ir_inst2_data;
logic [64:0] dp_ir_inst2_pc;
logic [24:0] dp_ir_inst2_chk;

// IR → RT (改名表) 的指令有效位 (2026-10-08 补声明 + 补连接)
// ⚠️ 交给 ct_idu_ir_ctrl 产生、原来只接在 ir_ctrl 例化那一侧,
//    ir_rt 例化那一侧是空连接 `()`, 而这两根名字又**没有显式声明** ⇒
//    靠隐式 1 位线网"恰好"连上、且 ir_rt 的端口拿到的是悬空的 Z。
//    后果: ir_rt 里 inst{k}_write_en = Z && ... = X ⇒ 改名表写使能是 X,
//    `preg <= x_create_preg` 在 X 条件下写入 ⇒ 表项被写成 X。
//    (本的 `mycpu.v` 历史上也栽过同一个坑: 漏声明 → 隐式线网 → 静默失效。)
logic        ctrl_rt_inst0_vld;
logic        ctrl_rt_inst1_vld;
logic        ctrl_rt_inst2_vld;

// Rename table signals
logic [4:0]  dp_rt_inst0_src0_reg;
logic [4:0]  dp_rt_inst0_src1_reg;
logic [4:0]  dp_rt_inst0_dst_reg;
logic        dp_rt_inst0_src0_vld;
logic        dp_rt_inst0_src1_vld;
logic        dp_rt_inst0_dst_vld;
logic [5:0]  dp_rt_inst0_dst_preg;
logic [4:0]  dp_rt_inst1_src0_reg;
logic [4:0]  dp_rt_inst1_src1_reg;
logic [4:0]  dp_rt_inst1_dst_reg;
logic        dp_rt_inst1_src0_vld;
logic        dp_rt_inst1_src1_vld;
logic        dp_rt_inst1_dst_vld;
logic [5:0]  dp_rt_inst1_dst_preg;
logic [4:0]  dp_rt_inst2_src0_reg;
logic [4:0]  dp_rt_inst2_src1_reg;
logic [4:0]  dp_rt_inst2_dst_reg;
logic        dp_rt_inst2_src0_vld;
logic        dp_rt_inst2_src1_vld;
logic        dp_rt_inst2_dst_vld;
logic [5:0]  dp_rt_inst2_dst_preg;
logic [5:0]  rt_dp_inst0_src0_preg;
logic [5:0]  rt_dp_inst0_src1_preg;
logic [8:0]  rt_dp_inst0_src0_data;
logic [8:0]  rt_dp_inst0_src1_data;
logic [9:0]  rt_dp_inst0_src2_data;
logic [5:0]  rt_dp_inst0_rel_preg;
logic [5:0]  rt_dp_inst1_src0_preg;
logic [5:0]  rt_dp_inst1_src1_preg;
logic [8:0]  rt_dp_inst1_src0_data;
logic [8:0]  rt_dp_inst1_src1_data;
logic [9:0]  rt_dp_inst1_src2_data;
logic [5:0]  rt_dp_inst1_rel_preg;
logic [5:0]  rt_dp_inst2_src0_preg;
logic [5:0]  rt_dp_inst2_src1_preg;
logic [8:0]  rt_dp_inst2_src0_data;
logic [8:0]  rt_dp_inst2_src1_data;
logic [9:0]  rt_dp_inst2_src2_data;
logic [5:0]  rt_dp_inst2_rel_preg;

// IS Stage control signals
logic        ctrl_is_stall;
logic        ctrl_is_inst2_vld;
// 语义(照 ct_idu_id_dp 的 case)：2'b10 = 三条都取自 IFU 的 0/1/2 车道(1:1 打包)；
// 2'b01 = IR 级只放行了两条，inst2 顺延成新的 inst0(走 crtl_ir_inst2_data 旁路)。
// 由 ct_idu_is_ctrl 产生(它是那个实例的输出端口)，这里只是声明。
// ⚠️ 原声明是 1 位 —— 而它要驱动 4 个 [1:0] 端口, 会被零扩展, case 落 default ⇒
//    整条 ID 数据路灌 X。加宽到 [1:0] 即可, 不需要额外驱动。
logic [1:0]  ctrl_xx_is_inst0_sel;
logic        ctrl_aiq_create0_en;
logic        ctrl_aiq_create1_en;
logic [1:0]  ctrl_aiq_create0_sel;
logic [1:0]  ctrl_aiq_create1_sel;
logic        ctrl_mult_create0_en;
logic [1:0]  ctrl_mult_create0_sel;
logic        ctrl_div_create0_en;
logic [1:0]  ctrl_div_create0_sel;
logic        ctrl_biq_create0_en;
logic        ctrl_biq_create1_en;
logic        ctrl_biq_create2_en;
logic [1:0]  ctrl_biq_create0_sel;
logic [1:0]  ctrl_biq_create1_sel;
logic [1:0]  ctrl_biq_create2_sel;
logic        ctrl_lsiq_create0_en;
logic        ctrl_lsiq_create1_en;
logic        ctrl_lsiq_create2_en;
logic [1:0]  ctrl_lsiq_create0_sel;
logic [1:0]  ctrl_lsiq_create1_sel;
logic [1:0]  ctrl_lsiq_create2_sel;
logic        ctrl_sdiq_create0_en;
logic        ctrl_sdiq_create1_en;
logic        ctrl_sdiq_create2_en;
logic [1:0]  ctrl_sdiq_create0_sel;
logic [1:0]  ctrl_sdiq_create1_sel;
logic [1:0]  ctrl_sdiq_create2_sel;

// IS Stage create data signals
logic [95:0]  dp_aiq_create0_data;   // 64 → 96 (2026-10-08 加 PC)
logic [95:0]  dp_aiq_create1_data;
logic [151:0] dp_biq_create0_data;
logic [151:0] dp_biq_create1_data;
logic [67:0]  dp_lsiq_create0_data;
logic [67:0]  dp_lsiq_create1_data;
logic [7:0]   dp_sdiq_create0_data;
logic [7:0]   dp_sdiq_create1_data;
logic [62:0]  dp_mult_create0_data;
logic [62:0]  dp_mult_create1_data;
logic [62:0]  dp_div_create0_data;
logic [62:0]  dp_div_create1_data;
logic [6:0]   dp_ctrl_is_dis_inst2_ctrl_info;
logic         dp_ctrl_is_inst0_dst_vld;
logic         dp_ctrl_is_inst1_dst_vld;
logic         dp_ctrl_is_inst2_dst_vld;

// ---- 派遣记录 (2026-10-08 新增) ----
// is_dp 按车道录出的三路原始数据 + is_ctrl 的"本路真的派发"
logic [82:0]  dp_is_dis_inst0_data;
logic [82:0]  dp_is_dis_inst1_data;
logic [82:0]  dp_is_dis_inst2_data;
logic [31:0]  dp_is_dis_inst0_pc;
logic [31:0]  dp_is_dis_inst1_pc;
logic [31:0]  dp_is_dis_inst2_pc;
logic [24:0]  dp_is_dis_inst0_chk;
logic [24:0]  dp_is_dis_inst1_chk;
logic [24:0]  dp_is_dis_inst2_chk;
logic         ctrl_dp_dis_inst0_vld;
logic         ctrl_dp_dis_inst1_vld;
logic         ctrl_dp_dis_inst2_vld;

// AIQ (ALU Issue Queue) signals
logic        ctrl_aiq_rf_pop_vld;
logic        aiq_ctrl_1_left_updt;
logic        aiq_ctrl_empty;
logic [6:0]  aiq_ctrl_entry_cnt;
logic        rf_aiq_issue_en;
logic [80:0] aiq_rf_issue_read_data;

// MULT Issue Queue signals
logic        ctrl_mult_rf_pop_vld;
logic        mult_ctrl_1_left_updt;
logic        mult_ctrl_empty;
logic [3:0]  mult_ctrl_entry_cnt;
logic        rf_mult_issue_en;
logic [70:0] mult_rf_issue_read_data;

// DIV Issue Queue signals
logic        ctrl_div_rf_pop_vld;
logic        div_ctrl_1_left_updt;
logic        div_ctrl_empty;
logic [3:0]  div_ctrl_entry_cnt;
logic        rf_div_issue_en;
logic [71:0] div_rf_issue_read_data;

// BIQ (Branch Issue Queue) signals
logic        ctrl_biq_rf_pop_vld;
logic        biq_ctrl_1_left_updt;
logic        biq_ctrl_empty;
logic [2:0]  biq_ctrl_entry_cnt;
logic        rf_biq_issue_en;
logic [117:0] biq_rf_issue_read_data;

// LSIQ (Load Store Issue Queue) signals
logic        ctrl_lsiq_rf_pop_vld;
logic        lsiq_ctrl_1_left_updt;
logic        lsiq_ctrl_empty;
logic [3:0]  lsiq_ctrl_entry_cnt;
logic        rf_lsiq_ld_issue_en;
logic        rf_lsiq_st_issue_en;
logic [104:0] lsiq_rf_ld_issue_read_data;
logic [99:0] lsiq_rf_st_issue_read_data;

// SDIQ (Store Data Issue Queue) signals
logic        ctrl_sdiq_rf_pop_vld;
logic        sdiq_ctrl_1_left_updt;
logic        sdiq_ctrl_empty;
logic [1:0]  sdiq_ctrl_entry_cnt;
logic        rf_sdiq_issue_en;
logic [38:0] sdiq_rf_issue_read_data;

// Physical Register File signals
logic [5:0]  dp_prf_rf_pipe0_src0_preg;
logic [5:0]  dp_prf_rf_pipe0_src1_preg;
logic [5:0]  dp_prf_rf_pipe1_src0_preg;
logic [5:0]  dp_prf_rf_pipe1_src1_preg;
logic [5:0]  dp_prf_rf_pipe2_src0_preg;
logic [5:0]  dp_prf_rf_pipe2_src1_preg;
logic [5:0]  dp_prf_rf_pipe3_src0_preg;
logic [5:0]  dp_prf_rf_pipe4_src0_preg;
logic [5:0]  dp_prf_rf_pipe5_src0_preg;
logic [5:0]  dp_prf_rf_pipe6_src0_preg;
logic [5:0]  dp_prf_rf_pipe6_src1_preg;
logic [31:0] prf_dp_rf_pipe0_src0_data;
logic [31:0] prf_dp_rf_pipe0_src1_data;
logic [31:0] prf_dp_rf_pipe1_src0_data;
logic [31:0] prf_dp_rf_pipe1_src1_data;
logic [31:0] prf_dp_rf_pipe2_src0_data;
logic [31:0] prf_dp_rf_pipe2_src1_data;
logic [31:0] prf_dp_rf_pipe3_src0_data;
logic [31:0] prf_dp_rf_pipe4_src0_data;
logic [31:0] prf_dp_rf_pipe5_src0_data;
logic [31:0] prf_dp_rf_pipe6_src0_data;
logic [31:0] prf_dp_rf_pipe6_src1_data;












//==========================================================
// Module Instantiations
//==========================================================
ct_idu_id_ctrl u_ct_idu_id_ctrl (
    // 时钟与复位
    .forever_cpuclk       (forever_cpuclk      ),//in
    .cpurst_b             (cpurst_b            ),//in
    
    // 来自 IFU (Instruction Fetch Unit) 的握手与指令有效信号
    .ifu_idu_ib_inst0_vld (ifu_idu_ib_inst0_vld),//in
    .ifu_idu_ib_inst1_vld (ifu_idu_ib_inst1_vld),//in
    .ifu_idu_ib_inst2_vld (ifu_idu_ib_inst2_vld),//in
    
    // 来自 CTRL 的控制信号
    .ctrl_xx_is_inst0_sel (ctrl_xx_is_inst0_sel),
    .ctrl_ir_stall        (ctrl_ir_stall       ),
    .ctrl_ir_inst2_vld    (ctrl_ir_inst2_vld   ),
    .rtu_yy_xx_flush      (rtu_yy_xx_flush     ),
    
    // 输出到 IDU (Instruction Decode Unit) 内部的有效信号
    .id_inst0_vld         (id_inst0_vld        ),
    .id_inst1_vld         (id_inst1_vld        ),
    .id_inst2_vld         (id_inst2_vld        ),
    
    // 输出到 IFU 的 ready 信号
    .idu_ifu_inst0_ready  (idu_ifu_inst0_ready ),//out
    .idu_ifu_inst1_ready  (idu_ifu_inst1_ready ),//out
    .idu_ifu_inst2_ready  (idu_ifu_inst2_ready ),//out
    .ctrl_dp_id_stall     (ctrl_dp_id_stall    )
);

ct_idu_id_dp u_ct_idu_id_dp (
    // 时钟与复位
    .cpurst_b                  (cpurst_b                 ),
    .forever_cpuclk            (forever_cpuclk           ),
    
    // 控制信号 (来自 Control 模块的流水线阻塞信号)
    .ctrl_dp_id_stall          (ctrl_dp_id_stall         ),
    .ctrl_xx_is_inst0_sel       (ctrl_xx_is_inst0_sel),
    
    // 从 IFU 输入的数据 (97 bits x 3)
    .ifu_idu_ib_inst0_data     (ifu_idu_ib_inst0_data    ),//in
    .ifu_idu_if_inst0_chk       (ifu_idu_if_inst0_chk),
    .ifu_idu_ib_inst1_data     (ifu_idu_ib_inst1_data    ),//in
    .ifu_idu_if_inst1_chk       (ifu_idu_if_inst1_chk),
    .ifu_idu_ib_inst2_data     (ifu_idu_ib_inst2_data    ),//in
    .ifu_idu_if_inst2_chk       (ifu_idu_if_inst2_chk),
    .rtu_yy_xx_flush           (rtu_yy_xx_flush          ),
    .crtl_ir_inst2_data         (crtl_ir_inst2_data),
    .crtl_ir_inst2_chk          (crtl_ir_inst2_chk),
    
    // 向下游流水线输出的数据 (122 bits x 3)
    .dp_id_pipedown_inst0_data (dp_id_pipedown_inst0_data),
    .dp_id_pipedown_inst0_chk   (dp_id_pipedown_inst0_chk),
    .dp_id_pipedown_inst1_data (dp_id_pipedown_inst1_data),
    .dp_id_pipedown_inst1_chk   (dp_id_pipedown_inst1_chk),
    .dp_id_pipedown_inst2_data (dp_id_pipedown_inst2_data),
    .dp_id_pipedown_inst2_chk   (dp_id_pipedown_inst2_chk)
);


// Instance 1: ct_idu_ir_ctrl
ct_idu_ir_ctrl x_ct_idu_ir_ctrl (
  .forever_cpuclk                        (forever_cpuclk),//2026-10-08 补: IR 级流水寄存器的时钟
  .cpurst_b                              (cpurst_b),
  .ctrl_id_pipedown_inst0_vld            (id_inst0_vld),
  .ctrl_id_pipedown_inst1_vld            (id_inst1_vld),
  .ctrl_id_pipedown_inst2_vld            (id_inst2_vld),
  .ctrl_is_inst2_vld                     (ctrl_is_inst2_vld),
  .ctrl_is_stall                         (ctrl_is_stall),
  .ctrl_xx_is_inst0_sel                  (ctrl_xx_is_inst0_sel),
  .dp_ctrl_ir_inst0_ctrl_info            (dp_ctrl_ir_inst0_ctrl_info),
  .dp_ctrl_ir_inst0_dst_vld              (dp_ctrl_ir_inst0_dst_vld),
  .dp_ctrl_ir_inst0_dst_x0               (dp_ctrl_ir_inst0_dst_x0),
  .dp_ctrl_ir_inst1_ctrl_info            (dp_ctrl_ir_inst1_ctrl_info),
  .dp_ctrl_ir_inst1_dst_vld              (dp_ctrl_ir_inst1_dst_vld),
  .dp_ctrl_ir_inst1_dst_x0               (dp_ctrl_ir_inst1_dst_x0),
  .dp_ctrl_ir_inst2_ctrl_info            (dp_ctrl_ir_inst2_ctrl_info),
  .dp_ctrl_ir_inst2_dst_vld              (dp_ctrl_ir_inst2_dst_vld),
  .dp_ctrl_ir_inst2_dst_x0               (dp_ctrl_ir_inst2_dst_x0),
  .dp_ctrl_is_dis_inst2_ctrl_info        (dp_ctrl_is_dis_inst2_ctrl_info),
  .rtu_idu_alloc_preg0_vld                              (rtu_idu_alloc_preg0_vld),//in
  .rtu_idu_alloc_preg1_vld                              (rtu_idu_alloc_preg1_vld),//in
  .rtu_idu_alloc_preg2_vld                              (rtu_idu_alloc_preg2_vld),//in
  .rtu_yy_xx_flush                       (rtu_yy_xx_flush),   // 补: 原来这根没接, 输入悬空
  .ctrl_ir_pipedown                              (ctrl_ir_pipedown),
  .ctrl_ir_pipedown_inst0_vld            (ctrl_ir_pipedown_inst0_vld),
  .ctrl_ir_pipedown_inst1_vld            (ctrl_ir_pipedown_inst1_vld),
  .ctrl_ir_pipedown_inst2_vld            (ctrl_ir_pipedown_inst2_vld),
  .ctrl_ir_pre_dis_aiq_create0_en        (ctrl_ir_pre_dis_aiq_create0_en),
  .ctrl_ir_pre_dis_aiq_create0_sel       (ctrl_ir_pre_dis_aiq_create0_sel),
  .ctrl_ir_pre_dis_aiq_create1_en        (ctrl_ir_pre_dis_aiq_create1_en),
  .ctrl_ir_pre_dis_aiq_create1_sel       (ctrl_ir_pre_dis_aiq_create1_sel),
  .ctrl_ir_pre_dis_biq_create0_en        (ctrl_ir_pre_dis_biq_create0_en),
  .ctrl_ir_pre_dis_biq_create0_sel       (ctrl_ir_pre_dis_biq_create0_sel),
  .ctrl_ir_pre_dis_biq_create1_en        (ctrl_ir_pre_dis_biq_create1_en),
  .ctrl_ir_pre_dis_biq_create1_sel       (ctrl_ir_pre_dis_biq_create1_sel),
  .ctrl_ir_pre_dis_inst0_vld             (ctrl_ir_pre_dis_inst0_vld),
  .ctrl_ir_pre_dis_inst1_vld             (ctrl_ir_pre_dis_inst1_vld),
  .ctrl_ir_pre_dis_inst2_vld             (ctrl_ir_pre_dis_inst2_vld),
  .ctrl_ir_pre_dis_lsiq_create0_en       (ctrl_ir_pre_dis_lsiq_create0_en),
  .ctrl_ir_pre_dis_lsiq_create0_sel      (ctrl_ir_pre_dis_lsiq_create0_sel),
  .ctrl_ir_pre_dis_lsiq_create1_en       (ctrl_ir_pre_dis_lsiq_create1_en),
  .ctrl_ir_pre_dis_lsiq_create1_sel      (ctrl_ir_pre_dis_lsiq_create1_sel),
  .ctrl_ir_pre_dis_pipedown2             (ctrl_ir_pre_dis_pipedown2),
  .ctrl_ir_pre_dis_sdiq_create0_en       (ctrl_ir_pre_dis_sdiq_create0_en),
  .ctrl_ir_pre_dis_sdiq_create0_sel      (ctrl_ir_pre_dis_sdiq_create0_sel),
  .ctrl_ir_pre_dis_sdiq_create1_sel      (ctrl_ir_pre_dis_sdiq_create1_sel),
  .ctrl_ir_stage_stall                   (ctrl_ir_stage_stall),
  .ctrl_ir_stall                          (ctrl_ir_stall),
  .ctrl_rt_inst0_vld                     (ctrl_rt_inst0_vld),
  .ctrl_rt_inst1_vld                     (ctrl_rt_inst1_vld),
  .ctrl_rt_inst2_vld                     (ctrl_rt_inst2_vld),
  .idu_rtu_ir_preg0_alloc_vld            (idu_rtu_ir_preg0_alloc_vld),//out
  .idu_rtu_ir_preg1_alloc_vld            (idu_rtu_ir_preg1_alloc_vld),//out
  .idu_rtu_ir_preg2_alloc_vld            (idu_rtu_ir_preg2_alloc_vld)//out
);

// Instance 2: ct_idu_ir_dp
ct_idu_ir_dp x_ct_idu_ir_dp (
  .cpurst_b                              (cpurst_b),
  .forever_clk                           (forever_cpuclk),   // 该模块端口名就是 forever_clk
  .ctrl_ir_stall                         (ctrl_ir_stall),
  .crtl_ir_inst2_data                    (crtl_ir_inst2_data),
  .crtl_ir_inst2_chk                     (crtl_ir_inst2_chk),  
  .dp_id_pipedown_inst0_data             (dp_id_pipedown_inst0_data),
  .dp_id_pipedown_inst0_chk               (dp_id_pipedown_inst0_chk),
  .dp_id_pipedown_inst1_data             (dp_id_pipedown_inst1_data),
  .dp_id_pipedown_inst1_chk               (dp_id_pipedown_inst1_chk),
  .dp_id_pipedown_inst2_data             (dp_id_pipedown_inst2_data),
  .dp_id_pipedown_inst2_chk               (dp_id_pipedown_inst2_chk),
  .rt_dp_inst0_rel_preg                  (rt_dp_inst0_rel_preg),
  .rt_dp_inst0_src0_data                 (rt_dp_inst0_src0_data),
  .rt_dp_inst0_src1_data                 (rt_dp_inst0_src1_data),
  .rt_dp_inst0_src2_data                 (rt_dp_inst0_src2_data),
  .rt_dp_inst1_rel_preg                  (rt_dp_inst1_rel_preg),
  .rt_dp_inst1_src0_data                 (rt_dp_inst1_src0_data),
  .rt_dp_inst1_src1_data                 (rt_dp_inst1_src1_data),
  .rt_dp_inst1_src2_data                 (rt_dp_inst1_src2_data),
  .rt_dp_inst2_rel_preg                  (rt_dp_inst2_rel_preg),
  .rt_dp_inst2_src0_data                 (rt_dp_inst2_src0_data),
  .rt_dp_inst2_src1_data                 (rt_dp_inst2_src1_data),
  .rt_dp_inst2_src2_data                 (rt_dp_inst2_src2_data),
  .rtu_idu_alloc_preg0                              (rtu_idu_alloc_preg0),//in
  .rtu_idu_alloc_preg1                              (rtu_idu_alloc_preg1),//in
  .rtu_idu_alloc_preg2                              (rtu_idu_alloc_preg2),//in
  .dp_ctrl_ir_inst0_ctrl_info            (dp_ctrl_ir_inst0_ctrl_info),
  .dp_ctrl_ir_inst0_dst_vld              (dp_ctrl_ir_inst0_dst_vld),
  .dp_ctrl_ir_inst0_dst_x0               (dp_ctrl_ir_inst0_dst_x0),
  .dp_ctrl_ir_inst1_ctrl_info            (dp_ctrl_ir_inst1_ctrl_info),
  .dp_ctrl_ir_inst1_dst_vld              (dp_ctrl_ir_inst1_dst_vld),
  .dp_ctrl_ir_inst1_dst_x0               (dp_ctrl_ir_inst1_dst_x0),
  .dp_ctrl_ir_inst2_ctrl_info            (dp_ctrl_ir_inst2_ctrl_info),
  .dp_ctrl_ir_inst2_dst_vld              (dp_ctrl_ir_inst2_dst_vld),
  .dp_ctrl_ir_inst2_dst_x0               (dp_ctrl_ir_inst2_dst_x0),
  .dp_ir_inst0_data                              (dp_ir_inst0_data),
  .dp_ir_inst0_pc                           (dp_ir_inst0_pc),
  .dp_ir_inst0_chk                        (dp_ir_inst0_chk),
  .dp_ir_inst1_data                              (dp_ir_inst1_data),
  .dp_ir_inst1_pc                           (dp_ir_inst1_pc),
  .dp_ir_inst1_chk                        (dp_ir_inst1_chk),
  .dp_ir_inst2_data                              (dp_ir_inst2_data),
  .dp_ir_inst2_pc                           (dp_ir_inst2_pc),
  .dp_ir_inst2_chk                        (dp_ir_inst2_chk),
  .dp_rt_inst0_dst_preg                  (dp_rt_inst0_dst_preg),
  .dp_rt_inst0_dst_reg                   (dp_rt_inst0_dst_reg),
  .dp_rt_inst0_dst_vld                   (dp_rt_inst0_dst_vld),
  .dp_rt_inst0_src0_reg                  (dp_rt_inst0_src0_reg),
  .dp_rt_inst0_src0_vld                  (dp_rt_inst0_src0_vld),
  .dp_rt_inst0_src1_reg                  (dp_rt_inst0_src1_reg),
  .dp_rt_inst0_src1_vld                  (dp_rt_inst0_src1_vld),
  .dp_rt_inst1_dst_preg                  (dp_rt_inst1_dst_preg),
  .dp_rt_inst1_dst_reg                   (dp_rt_inst1_dst_reg),
  .dp_rt_inst1_dst_vld                   (dp_rt_inst1_dst_vld),
  .dp_rt_inst1_src0_reg                  (dp_rt_inst1_src0_reg),
  .dp_rt_inst1_src0_vld                  (dp_rt_inst1_src0_vld),
  .dp_rt_inst1_src1_reg                  (dp_rt_inst1_src1_reg),
  .dp_rt_inst1_src1_vld                  (dp_rt_inst1_src1_vld),
  .dp_rt_inst2_dst_preg                  (dp_rt_inst2_dst_preg),
  .dp_rt_inst2_dst_reg                   (dp_rt_inst2_dst_reg),
  .dp_rt_inst2_dst_vld                   (dp_rt_inst2_dst_vld),
  .dp_rt_inst2_src0_reg                  (dp_rt_inst2_src0_reg),
  .dp_rt_inst2_src0_vld                  (dp_rt_inst2_src0_vld),
  .dp_rt_inst2_src1_reg                  (dp_rt_inst2_src1_reg),
  .dp_rt_inst2_src1_vld                  (dp_rt_inst2_src1_vld)
);

// Instance 3: ct_idu_ir_rt
ct_idu_ir_rt x_ct_idu_ir_rt (
  .forever_cpuclk                        (forever_cpuclk),//2026-10-08 补: 改名表的时钟
  .cpurst_b                              (cpurst_b),
  .ctrl_ir_stall                              (ctrl_ir_stall),
  .ctrl_rt_inst0_vld                     (ctrl_rt_inst0_vld),//2026-10-08 补: 原来是空连接
  .ctrl_rt_inst1_vld                     (ctrl_rt_inst1_vld),
  .ctrl_rt_inst2_vld                     (ctrl_rt_inst2_vld),
  .dp_rt_inst0_dst_preg                  (dp_rt_inst0_dst_preg),
  .dp_rt_inst0_dst_reg                   (dp_rt_inst0_dst_reg),
  .dp_rt_inst0_dst_vld                   (dp_rt_inst0_dst_vld),
  .dp_rt_inst0_src0_reg                  (dp_rt_inst0_src0_reg),
  .dp_rt_inst0_src0_vld                  (dp_rt_inst0_src0_vld),
  .dp_rt_inst0_src1_reg                  (dp_rt_inst0_src1_reg),
  .dp_rt_inst0_src1_vld                  (dp_rt_inst0_src1_vld),
  .dp_rt_inst1_dst_preg                  (dp_rt_inst1_dst_preg),
  .dp_rt_inst1_dst_reg                   (dp_rt_inst1_dst_reg),
  .dp_rt_inst1_dst_vld                   (dp_rt_inst1_dst_vld),
  .dp_rt_inst1_src0_reg                  (dp_rt_inst1_src0_reg),
  .dp_rt_inst1_src0_vld                  (dp_rt_inst1_src0_vld),
  .dp_rt_inst1_src1_reg                  (dp_rt_inst1_src1_reg),
  .dp_rt_inst1_src1_vld                  (dp_rt_inst1_src1_vld),
  .dp_rt_inst2_dst_preg                  (dp_rt_inst2_dst_preg),
  .dp_rt_inst2_dst_reg                   (dp_rt_inst2_dst_reg),
  .dp_rt_inst2_dst_vld                   (dp_rt_inst2_dst_vld),
  .dp_rt_inst2_src0_reg                  (dp_rt_inst2_src0_reg),
  .dp_rt_inst2_src0_vld                  (dp_rt_inst2_src0_vld),
  .dp_rt_inst2_src1_reg                  (dp_rt_inst2_src1_reg),
  .dp_rt_inst2_src1_vld                  (dp_rt_inst2_src1_vld),
  .iu_idu_ex2_pipe0_wb_preg_dupx                              (iu_idu_ex2_pipe0_wb_preg_dupx),//in
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx                              (iu_idu_ex2_pipe0_wb_preg_vld_dupx),//in
  .iu_idu_ex2_pipe1_wb_preg_dupx                              (iu_idu_ex2_pipe1_wb_preg_dupx),//in
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx                              (iu_idu_ex2_pipe1_wb_preg_vld_dupx),//in
  .lsu_idu_wb_pipe3_wb_preg_dupx                              (lsu_idu_wb_pipe3_wb_preg_dupx),//in
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx                              (lsu_idu_wb_pipe3_wb_preg_vld_dupx),//in
  .rtu_idu_rt_recover_preg                              (rtu_idu_rt_recover_preg),//in
  .rtu_yy_xx_flush                              (rtu_yy_xx_flush),//in
  .rt_dp_inst0_rel_preg                  (rt_dp_inst0_rel_preg),
  .rt_dp_inst0_src0_data                 (rt_dp_inst0_src0_data),
  .rt_dp_inst0_src1_data                 (rt_dp_inst0_src1_data),
  .rt_dp_inst0_src2_data                 (rt_dp_inst0_src2_data),
  .rt_dp_inst1_rel_preg                  (rt_dp_inst1_rel_preg),
  .rt_dp_inst1_src0_data                 (rt_dp_inst1_src0_data),
  .rt_dp_inst1_src1_data                 (rt_dp_inst1_src1_data),
  .rt_dp_inst1_src2_data                 (rt_dp_inst1_src2_data),
  .rt_dp_inst2_rel_preg                  (rt_dp_inst2_rel_preg),
  .rt_dp_inst2_src0_data                 (rt_dp_inst2_src0_data),
  .rt_dp_inst2_src1_data                 (rt_dp_inst2_src1_data),
  .rt_dp_inst2_src2_data                 (rt_dp_inst2_src2_data)
);



// Instance 5: ct_idu_is_ctrl
ct_idu_is_ctrl x_ct_idu_is_ctrl (
  // Inputs
  .forever_clk                           (forever_cpuclk),   // 该模块端口名就是 forever_clk
  .cpurst_b                              (cpurst_b),
  .aiq_ctrl_1_left_updt                  (aiq_ctrl_1_left_updt),
  .aiq_ctrl_full_updt                    (aiq_ctrl_full_updt),
  .biq_ctrl_1_left_updt                  (biq_ctrl_1_left_updt),
  .biq_ctrl_full_updt                    (biq_ctrl_full_updt),
  .ctrl_ir_pipedown_inst0_vld            (ctrl_ir_pipedown_inst0_vld),
  .ctrl_ir_pipedown_inst1_vld            (ctrl_ir_pipedown_inst1_vld),
  .ctrl_ir_pipedown_inst2_vld            (ctrl_ir_pipedown_inst2_vld),
  .ctrl_ir_pre_dis_aiq_create0_en        (ctrl_ir_pre_dis_aiq_create0_en),
  .ctrl_ir_pre_dis_aiq_create0_sel       (ctrl_ir_pre_dis_aiq_create0_sel),
  .ctrl_ir_pre_dis_aiq_create1_en        (ctrl_ir_pre_dis_aiq_create1_en),
  .ctrl_ir_pre_dis_aiq_create1_sel       (ctrl_ir_pre_dis_aiq_create1_sel),
  .ctrl_ir_pre_dis_biq_create0_en        (ctrl_ir_pre_dis_biq_create0_en),
  .ctrl_ir_pre_dis_biq_create0_sel       (ctrl_ir_pre_dis_biq_create0_sel),
  .ctrl_ir_pre_dis_biq_create1_en        (ctrl_ir_pre_dis_biq_create1_en),
  .ctrl_ir_pre_dis_biq_create1_sel       (ctrl_ir_pre_dis_biq_create1_sel),
  .ctrl_ir_pre_dis_inst0_vld             (ctrl_ir_pre_dis_inst0_vld),
  .ctrl_ir_pre_dis_inst1_vld             (ctrl_ir_pre_dis_inst1_vld),
  .ctrl_ir_pre_dis_inst2_vld             (ctrl_ir_pre_dis_inst2_vld),
  .ctrl_ir_pre_dis_lsiq_create0_en       (ctrl_ir_pre_dis_lsiq_create0_en),
  .ctrl_ir_pre_dis_lsiq_create0_sel      (ctrl_ir_pre_dis_lsiq_create0_sel),
  .ctrl_ir_pre_dis_lsiq_create1_en       (ctrl_ir_pre_dis_lsiq_create1_en),
  .ctrl_ir_pre_dis_lsiq_create1_sel      (ctrl_ir_pre_dis_lsiq_create1_sel),
  .ctrl_ir_pre_dis_pipedown2             (ctrl_ir_pre_dis_pipedown2),
  .ctrl_ir_pre_dis_sdiq_create0_en       (ctrl_ir_pre_dis_sdiq_create0_en),
  .ctrl_ir_pre_dis_sdiq_create0_sel      (ctrl_ir_pre_dis_sdiq_create0_sel),
  .ctrl_ir_pre_dis_sdiq_create1_en       (ctrl_ir_pre_dis_sdiq_create1_en),
  .ctrl_ir_pre_dis_sdiq_create1_sel      (ctrl_ir_pre_dis_sdiq_create1_sel),
  .ctrl_ir_pre_dis_mult_create0_en       (ctrl_ir_pre_dis_mult_create0_en),
  .ctrl_ir_pre_dis_mult_create0_sel      (ctrl_ir_pre_dis_mult_create0_sel),
  .ctrl_ir_pre_dis_mult_create1_en       (ctrl_ir_pre_dis_mult_create1_en),
  .ctrl_ir_pre_dis_mult_create1_sel      (ctrl_ir_pre_dis_mult_create1_sel),
  .ctrl_ir_pre_dis_div_create0_en        (ctrl_ir_pre_dis_div_create0_en),
  .ctrl_ir_pre_dis_div_create0_sel       (ctrl_ir_pre_dis_div_create0_sel),
  .ctrl_ir_pre_dis_div_create1_en        (ctrl_ir_pre_dis_div_create1_en),
  .ctrl_ir_pre_dis_div_create1_sel       (ctrl_ir_pre_dis_div_create1_sel),
  .dp_ctrl_is_inst0_dst_vld              (dp_ctrl_is_inst0_dst_vld),
  .dp_ctrl_is_inst1_dst_vld              (dp_ctrl_is_inst1_dst_vld),
  .dp_ctrl_is_inst2_dst_vld              (dp_ctrl_is_inst2_dst_vld),
  .lsiq_ctrl_1_left_updt                 (lsiq_ctrl_1_left_updt),
  .lsiq_ctrl_full_updt                   (lsiq_ctrl_full_updt),
  .mult_ctrl_1_left_updt                 (mult_ctrl_1_left_updt),
  .mult_ctrl_full_updt                   (mult_ctrl_full_updt),
  .div_ctrl_1_left_updt                  (div_ctrl_1_left_updt),
  .div_ctrl_full_updt                    (div_ctrl_full_updt),
  .rtu_idu_rob_full                      (rtu_idu_rob_full),
  .rtu_yy_xx_flush                       (rtu_yy_xx_flush),
  .sdiq_ctrl_1_left_updt                 (sdiq_ctrl_1_left_updt),
  .sdiq_ctrl_full_updt                   (sdiq_ctrl_full_updt),
  // Outputs
  .ctrl_aiq_create0_en                   (ctrl_aiq_create0_en),
  .ctrl_aiq_create1_en                   (ctrl_aiq_create1_en),
  .ctrl_biq_create0_en                   (ctrl_biq_create0_en),
  .ctrl_biq_create1_en                   (ctrl_biq_create1_en),
  .ctrl_lsiq_create0_en                  (ctrl_lsiq_create0_en),
  .ctrl_lsiq_create1_en                  (ctrl_lsiq_create1_en),
  .ctrl_sdiq_create0_en                  (ctrl_sdiq_create0_en),
  .ctrl_sdiq_create1_en                  (ctrl_sdiq_create1_en),
  .ctrl_mult_create0_en                  (ctrl_mult_create0_en),
  .ctrl_mult_create1_en                  (ctrl_mult_create1_en),
  .ctrl_div_create0_en                   (ctrl_div_create0_en),
  .ctrl_div_create1_en                   (ctrl_div_create1_en),
  .ctrl_dp_dis_inst0_preg_vld            (ctrl_dp_dis_inst0_preg_vld),
  .ctrl_dp_dis_inst1_preg_vld            (ctrl_dp_dis_inst1_preg_vld),
  .ctrl_dp_dis_inst2_preg_vld            (ctrl_dp_dis_inst2_preg_vld),
  .ctrl_dp_dis_inst3_preg_vld            (ctrl_dp_dis_inst3_preg_vld),
  .ctrl_dp_is_dis_aiq_create0_sel        (ctrl_dp_is_dis_aiq_create0_sel),
  .ctrl_dp_is_dis_aiq_create1_sel        (ctrl_dp_is_dis_aiq_create1_sel),
  .ctrl_dp_is_dis_biq_create0_sel        (ctrl_dp_is_dis_biq_create0_sel),
  .ctrl_dp_is_dis_biq_create1_sel        (ctrl_dp_is_dis_biq_create1_sel),
  .ctrl_dp_is_dis_lsiq_create0_sel       (ctrl_dp_is_dis_lsiq_create0_sel),
  .ctrl_dp_is_dis_lsiq_create1_sel       (ctrl_dp_is_dis_lsiq_create1_sel),
  .ctrl_dp_is_dis_sdiq_create0_sel       (ctrl_dp_is_dis_sdiq_create0_sel),
  .ctrl_dp_is_dis_sdiq_create1_sel       (ctrl_dp_is_dis_sdiq_create1_sel),
  .ctrl_dp_is_dis_mult_create0_sel       (ctrl_dp_is_dis_mult_create0_sel),
  .ctrl_dp_is_dis_mult_create1_sel       (ctrl_dp_is_dis_mult_create1_sel),
  .ctrl_dp_is_dis_div_create0_sel        (ctrl_dp_is_dis_div_create0_sel),
  .ctrl_dp_is_dis_div_create1_sel        (ctrl_dp_is_dis_div_create1_sel),
  .ctrl_dp_is_dis_stall                  (ctrl_dp_is_dis_stall),
  .ctrl_dp_is_inst0_vld                  (ctrl_dp_is_inst0_vld),
  .ctrl_dp_is_inst1_vld                  (ctrl_dp_is_inst1_vld),
  .ctrl_dp_is_inst2_vld                  (ctrl_dp_is_inst2_vld),
  .ctrl_is_inst2_vld                     (ctrl_is_inst2_vld),
  .ctrl_is_stall                         (ctrl_is_stall),
  .ctrl_xx_is_inst0_sel                  (ctrl_xx_is_inst0_sel),
  // ---- 派遣记录: 本路真的派发 (2026-10-08 新增) ----
  .ctrl_dp_dis_inst0_vld                 (ctrl_dp_dis_inst0_vld),
  .ctrl_dp_dis_inst1_vld                 (ctrl_dp_dis_inst1_vld),
  .ctrl_dp_dis_inst2_vld                 (ctrl_dp_dis_inst2_vld)
);

// Instance 6: ct_idu_is_dp
ct_idu_is_dp x_ct_idu_is_dp (
  .forever_clk                           (forever_cpuclk),   // 该模块端口名就是 forever_clk
  .cpurst_b                              (cpurst_b),
  .dp_ctrl_is_dis_inst2_ctrl_info       (dp_ctrl_is_dis_inst2_ctrl_info),
  .dp_ir_inst0_data                              (dp_ir_inst0_data),
  .dp_ir_inst0_pc                           (dp_ir_inst0_pc),
  .dp_ir_inst0_chk                        (dp_ir_inst0_chk),
  .dp_ir_inst1_data                              (dp_ir_inst1_data),
  .dp_ir_inst1_pc                           (dp_ir_inst1_pc),
  .dp_ir_inst1_chk                        (dp_ir_inst1_chk),
  .dp_ir_inst2_data                              (dp_ir_inst2_data),
  .dp_ir_inst2_pc                           (dp_ir_inst1_pc),
  .dp_ir_inst2_chk                        (dp_ir_inst2_chk),
  .rtu_idu_rob_inst0_iid                              (rtu_idu_rob_inst0_iid),//in
  .rtu_idu_rob_inst1_iid                              (rtu_idu_rob_inst1_iid),//in
  .rtu_idu_rob_inst2_iid                              (rtu_idu_rob_inst2_iid),//in
  .iu_idu_ex2_pipe0_wb_preg_dupx                              (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx                              (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx                              (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx                              (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx                              (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx                              (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .ctrl_dp_is_inst0_vld                  (ctrl_dp_is_inst0_vld),
  .ctrl_dp_is_inst1_vld                  (ctrl_dp_is_inst1_vld),
  .ctrl_dp_is_inst2_vld                  (ctrl_dp_is_inst2_vld),
  .ctrl_dp_is_dis_stall                  (ctrl_dp_is_dis_stall),
  .ctrl_ir_pipedown                              (ctrl_ir_pipedown),
  .rtu_yy_xx_flush                        (rtu_yy_xx_flush),
  .ctrl_xx_is_inst0_sel                              (ctrl_xx_is_inst0_sel),
  .sdiq_create0_entry                              (sdiq_create0_entry),//in
  .sdiq_create1_entry                              (sdiq_create1_entry),//in
  .ctrl_sdiq_create0_en                              (ctrl_sdiq_create0_en),
  .ctrl_sdiq_create1_en                              (ctrl_sdiq_create1_en),
  .ctrl_dp_is_dis_aiq_create0_sel        (ctrl_dp_is_dis_aiq_create0_sel),
  .ctrl_dp_is_dis_aiq_create1_sel        (ctrl_dp_is_dis_aiq_create1_sel),
  .ctrl_dp_is_dis_biq_create0_sel        (ctrl_dp_is_dis_biq_create0_sel),
  .ctrl_dp_is_dis_biq_create1_sel        (ctrl_dp_is_dis_biq_create1_sel),
  .ctrl_dp_is_dis_lsiq_create0_sel       (ctrl_dp_is_dis_lsiq_create0_sel),
  .ctrl_dp_is_dis_lsiq_create1_sel       (ctrl_dp_is_dis_lsiq_create1_sel),
  .ctrl_dp_is_dis_sdiq_create0_sel       (ctrl_dp_is_dis_sdiq_create0_sel),
  .ctrl_dp_is_dis_sdiq_create1_sel       (ctrl_dp_is_dis_sdiq_create1_sel),
  .ctrl_dp_is_dis_mult_create0_sel       (ctrl_dp_is_dis_mult_create0_sel),
  .ctrl_dp_is_dis_mult_create1_sel       (ctrl_dp_is_dis_mult_create1_sel),
  .ctrl_dp_is_dis_div_create0_sel        (ctrl_dp_is_dis_div_create0_sel),
  .ctrl_dp_is_dis_div_create1_sel        (ctrl_dp_is_dis_div_create1_sel),
  .dp_aiq_create0_data                              (dp_aiq_create0_data),
  .dp_aiq_create1_data                              (dp_aiq_create1_data),
  .dp_biq_create0_data                   (dp_biq_create0_data),
  .dp_biq_create1_data                   (dp_biq_create1_data),
  .dp_ctrl_is_inst0_dst_vld                              (dp_ctrl_is_inst0_dst_vld),
  .dp_ctrl_is_inst1_dst_vld                              (dp_ctrl_is_inst1_dst_vld),
  .dp_ctrl_is_inst2_dst_vld                              (dp_ctrl_is_inst2_dst_vld),
  .dp_lsiq_create0_data                              (dp_lsiq_create0_data),
  .dp_lsiq_create1_data                              (dp_lsiq_create1_data),
  .dp_sdiq_create0_data                              (dp_sdiq_create0_data),
  .dp_sdiq_create1_data                              (dp_sdiq_create1_data),
  .dp_mult_create0_data                  (dp_mult_create0_data),
  .dp_mult_create1_data                  (dp_mult_create1_data),
  .dp_div_create0_data                   (dp_div_create0_data),
  .dp_div_create1_data                   (dp_div_create1_data),
  // ---- 派遣记录: 按车道录出 (2026-10-08 新增) ----
  .dp_is_dis_inst0_data                  (dp_is_dis_inst0_data),
  .dp_is_dis_inst1_data                  (dp_is_dis_inst1_data),
  .dp_is_dis_inst2_data                  (dp_is_dis_inst2_data),
  .dp_is_dis_inst0_pc                    (dp_is_dis_inst0_pc),
  .dp_is_dis_inst1_pc                    (dp_is_dis_inst1_pc),
  .dp_is_dis_inst2_pc                    (dp_is_dis_inst2_pc),
  .dp_is_dis_inst0_chk                   (dp_is_dis_inst0_chk),
  .dp_is_dis_inst1_chk                   (dp_is_dis_inst1_chk),
  .dp_is_dis_inst2_chk                   (dp_is_dis_inst2_chk)
);

// Instance 4: ct_idu_is_aiq
ct_idu_is_aiq x_ct_idu_is_aiq (
  .aiq_ctrl_1_left_updt                              (aiq_ctrl_1_left_updt),
  .aiq_ctrl_full_updt                              (aiq_ctrl_full_updt),
  .aiq_xx_issue_en                              (aiq_xx_issue_en),
  .aiq_dp_issue_read_data               (aiq_dp_issue_read_data),
  .cpurst_b                              (cpurst_b),
  .ctrl_aiq_create0_en                              (ctrl_aiq_create0_en),
  .ctrl_aiq_create1_en                              (ctrl_aiq_create1_en),
  .dp_aiq_create0_data                              (dp_aiq_create0_data),
  .dp_aiq_create1_data                              (dp_aiq_create1_data),
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx                              (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx                              (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx                              (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx                              (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx                              (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx                              (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                              (rtu_yy_xx_flush)
);

ct_idu_is_md x_ct_idu_is_mult (
  .md_ctrl_1_left_updt                              (mult_ctrl_1_left_updt),
  .md_ctrl_full_updt                              (mult_ctrl_full_updt),
  .md_xx_issue_en                              (mult_xx_issue_en),
  .md_dp_issue_read_data               (mult_dp_issue_read_data),
  .cpurst_b                              (cpurst_b),
  .ctrl_md_create0_en                              (ctrl_mult_create0_en),
  .ctrl_md_create1_en                              (ctrl_mult_create1_en),
  .dp_md_create0_data                              (dp_mult_create0_data),
  .dp_md_create1_data                              (dp_mult_create1_data),
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx                              (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx                              (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx                              (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx                              (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx                              (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx                              (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                              (rtu_yy_xx_flush)
);

ct_idu_is_md x_ct_idu_is_div (
  .md_ctrl_1_left_updt                              (div_ctrl_1_left_updt),
  .md_ctrl_full_updt                              (div_ctrl_full_updt),
  .md_xx_issue_en                              (div_xx_issue_en),
  .md_dp_issue_read_data               (div_dp_issue_read_data),
  .cpurst_b                              (cpurst_b),
  .ctrl_md_create0_en                              (ctrl_div_create0_en),
  .ctrl_md_create1_en                              (ctrl_div_create1_en),
  .dp_md_create0_data                              (dp_div_create0_data),
  .dp_md_create1_data                              (dp_div_create1_data),
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx                              (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx                              (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx                              (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx                              (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx                              (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx                              (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                              (rtu_yy_xx_flush)
);

// Instance 7: ct_idu_is_lsiq
ct_idu_is_lsiq x_ct_idu_is_lsiq (
  .cpurst_b                              (cpurst_b),
  .ctrl_lsiq_create0_en                              (ctrl_lsiq_create0_en),
  .ctrl_lsiq_create1_en                              (ctrl_lsiq_create1_en),
  .dp_lsiq_create0_data                              (dp_lsiq_create0_data),
  .dp_lsiq_create1_data                              (dp_lsiq_create1_data),
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx                              (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx                              (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx                              (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx                              (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_full                       (lsu_idu_lq_full),//in
  .lsu_idu_lq_not_full                   (lsu_idu_lq_not_full),//in
  .lsu_idu_lsiq_pop0_vld                 (lsu_idu_lsiq_pop0_vld),//in
  .lsu_idu_lsiq_pop1_vld                 (lsu_idu_lsiq_pop1_vld),//in
  .lsu_idu_lsiq_pop_entry                (lsu_idu_lsiq_pop_entry),//in
  .lsu_idu_lsiq_pop_vld                  (lsu_idu_lsiq_pop_vld),//in
  .lsu_idu_rb_full                       (lsu_idu_rb_full),//in
  .lsu_idu_rb_not_full                   (lsu_idu_rb_not_full),//in
  .lsu_idu_secd                          (lsu_idu_secd),//in
  .lsu_idu_sq_full                       (lsu_idu_sq_full),//in
  .lsu_idu_sq_not_full                   (lsu_idu_sq_not_full),//in
  .lsu_idu_wb_pipe3_wb_preg_dupx                              (lsu_idu_wb_pipe3_wb_preg_dupx),//in
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx                              (lsu_idu_wb_pipe3_wb_preg_vld_dupx),//in
  .rtu_yy_xx_flush                              (rtu_yy_xx_flush),//in
  .lsiq_ctrl_1_left_updt                              (lsiq_ctrl_1_left_updt),
  .lsiq_ctrl_full_updt                              (lsiq_ctrl_full_updt),
  .lsiq_rf_pipe3_issue_en                (lsiq_xx_pipe3_issue_en),
  .lsiq_rf_pipe4_issue_en                (lsiq_xx_pipe4_issue_en),
  .lsiq_dp_pipe3_entry_read_data            (lsiq_dp_pipe3_entry_read_data),
  .lsiq_pipe3_entry_unalign_2nd          (lsiq_pipe3_entry_unalign_2nd),
  .lsiq_pipe3_entry_old                  (lsiq_pipe3_entry_old),
  .lsiq_dp_pipe3_issue_entry            (lsiq_dp_pipe3_issue_entry),
  .lsiq_dp_pipe4_entry_read_data            (lsiq_dp_pipe4_entry_read_data),
  .lsiq_pipe4_entry_unalign_2nd          (lsiq_pipe4_entry_unalign_2nd),
  .lsiq_pipe4_entry_old                  (lsiq_pipe4_entry_old),
  .lsiq_dp_pipe4_issue_entry            (lsiq_dp_pipe4_issue_entry)

);

// Instance 8: ct_idu_is_sdiq
ct_idu_is_sdiq x_ct_idu_is_sdiq (
  .cpurst_b                              (cpurst_b),
  .lsu_sdiq_has_in_sq_vld                (lsu_sdiq_has_in_sq_vld),//in
  // 2026-10-08 修: 原来这里连了 .lsu_sq_sdiq_unalign_sdiq, 但该端口在
  // ct_idu_is_sdiq 里**已经被注释掉了** (见其 :6 的注释行与 :428 的注释 assign)
  // ⇒ VCS 报 "Undefined port in module instantiation", 整个 IDU elaborate 失败。
  // 对应信号在顶层也没有声明 (是隐式线网)。这里跟着注释掉。
  // 语义上它是"LSU 报回来的非对齐 SDIQ 条目号", 属于走硬件拆分的路径 ——
  // 本核按"非对齐直接报 expt 陷入"设计 (见 RTU↔LSU 接口表), 用不到。
//  .lsu_sq_sdiq_unalign_sdiq              (lsu_sq_sdiq_unalign_sdiq),
  .ctrl_sdiq_create0_en                              (ctrl_sdiq_create0_en),
  .ctrl_sdiq_create1_en                              (ctrl_sdiq_create1_en),
  .dp_sdiq_create0_data                              (dp_sdiq_create0_data),
  .dp_sdiq_create1_data                              (dp_sdiq_create1_data),
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx                              (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx                              (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx                              (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx                              (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx                              (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx                              (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                              (rtu_yy_xx_flush),
  .idu_rtu_pst_preg_dealloc_mask         (idu_rtu_pst_preg_dealloc_mask),//out
  .sdiq_ctrl_1_left_updt                              (sdiq_ctrl_1_left_updt),
  .sdiq_ctrl_full_updt                              (sdiq_ctrl_full_updt),
  .sdiq_issue_en                         (sdiq_xx_issue_en),
  .sdiq_dp_issue_entry                              (sdiq_dp_issue_entry),
  .sdiq_dp_issue_read_data                              (sdiq_dp_issue_read_data),
  .sdiq_create0_entry                              (sdiq_create0_entry),
  .sdiq_create1_entry                              (sdiq_create1_entry)
);

ct_idu_is_biq x_ct_idu_is_biq (
  .biq_ctrl_1_left_updt                              (biq_ctrl_1_left_updt),
  .biq_ctrl_full_updt                              (biq_ctrl_full_updt),
  .biq_xx_issue_en                              (biq_xx_issue_en),
  .biq_dp_issue_read_data               (biq_dp_issue_read_data),
  .cpurst_b                              (cpurst_b),
  .ctrl_biq_create0_en                              (ctrl_biq_create0_en),
  .ctrl_biq_create1_en                              (ctrl_biq_create1_en),
  .dp_biq_create0_data                              (dp_biq_create0_data),
  .dp_biq_create1_data                              (dp_biq_create1_data),
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx                              (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx                              (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx                              (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx                              (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx                              (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx                              (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                              (rtu_yy_xx_flush)
);

// Instance 9: ct_idu_rf_ctrl
ct_idu_rf_ctrl x_ct_idu_rf_ctrl (
  .cpurst_b                              (cpurst_b),
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .aiq_xx_issue_en                              (aiq_xx_issue_en),
  .mult_xx_issue_en                              (mult_xx_issue_en),
  .div_xx_issue_en                              (div_xx_issue_en),
  .lsiq_xx_pipe3_issue_en                              (lsiq_xx_pipe3_issue_en),
  .lsiq_xx_pipe4_issue_en                              (lsiq_xx_pipe4_issue_en),
  .sdiq_xx_issue_en                              (sdiq_xx_issue_en),
  .biq_xx_issue_en                              (biq_xx_issue_en),
  .rtu_yy_xx_flush                              (rtu_yy_xx_flush),
  .idu_aiq_sel                           (idu_aiq_sel),//out
  .idu_mult_sel                          (idu_mult_sel),//out
  .idu_div_sel                           (idu_div_sel),//out
  .idu_lsu_ld_sel                        (idu_lsu_ld_sel),//out
  .idu_lsu_st_sel                        (idu_lsu_st_sel),//out
  .idu_lsu_sdiq_sel                      (idu_lsu_sdiq_sel),//out
  .idu_biq_sel                           (idu_biq_sel)//out
);

// Instance 10: ct_idu_rf_dp
ct_idu_rf_dp x_ct_idu_rf_dp (
  .cpurst_b                              (cpurst_b),
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .aiq_dp_issue_read_data                (aiq_dp_issue_read_data),
  .aiq_xx_issue_en                              (aiq_xx_issue_en),
  .prf_dp_rf_pipe0_src0_data                              (prf_dp_rf_pipe0_src0_data),
  .prf_dp_rf_pipe0_src1_data                              (prf_dp_rf_pipe0_src1_data),
  .dp_prf_rf_pipe0_src0_preg                              (dp_prf_rf_pipe0_src0_preg),
  .dp_prf_rf_pipe0_src1_preg                              (dp_prf_rf_pipe0_src1_preg),
  .idu_aiq_iid                           (idu_aiq_iid),//out
  .idu_aiq_dst_preg                      (idu_aiq_dst_preg),//out
  .idu_aiq_src0                          (idu_aiq_src0),//out
  .idu_aiq_src1                          (idu_aiq_src1),//out
  .idu_aiq_rslt_sel                      (idu_aiq_rslt_sel),//out
  .idu_aiq_illegal                       (idu_aiq_illegal),//out
    .mult_dp_issue_read_data             (mult_dp_issue_read_data),
    .mult_xx_issue_en                    (mult_xx_issue_en),
  .prf_dp_rf_pipe1_src0_data                              (prf_dp_rf_pipe1_src0_data),
  .prf_dp_rf_pipe1_src1_data                              (prf_dp_rf_pipe1_src1_data),
  .dp_prf_rf_pipe1_src0_preg                              (dp_prf_rf_pipe1_src0_preg),
  .dp_prf_rf_pipe1_src1_preg                              (dp_prf_rf_pipe1_src1_preg),
  .idu_mult_iid                          (idu_mult_iid),//out
  .idu_mult_dst_preg                     (idu_mult_dst_preg),   //out
  .idu_mult_src0                         (idu_mult_src0),//out
  .idu_mult_src1                         (idu_mult_src1),//out
  .idu_mult_rslt_sel                     (idu_mult_rslt_sel),//out
  .div_dp_issue_read_data                (div_dp_issue_read_data),
  .div_xx_issue_en                       (div_xx_issue_en),
  .prf_dp_rf_pipe2_src0_data                              (prf_dp_rf_pipe2_src0_data),
  .prf_dp_rf_pipe2_src1_data                              (prf_dp_rf_pipe2_src1_data),
  .dp_prf_rf_pipe2_src0_preg                              (dp_prf_rf_pipe2_src0_preg),
  .dp_prf_rf_pipe2_src1_preg                              (dp_prf_rf_pipe2_src1_preg),
  .idu_div_iid                           (idu_div_iid),//out
  .idu_div_dst_vld                       (idu_div_dst_vld),//out
  .idu_div_dst_preg                      (idu_div_dst_preg),//out
  .idu_div_src0                          (idu_div_src0),//out
  .idu_div_src1                          (idu_div_src1),//out
  .idu_div_rslt_sel                      (idu_div_rslt_sel),//out
  .lsiq_dp_pipe3_issue_entry             (lsiq_dp_pipe3_issue_entry),
  .lsiq_dp_pipe3_issue_read_data         (lsiq_dp_pipe3_issue_read_data),
  .lsiq_xx_pipe3_issue_en                              (lsiq_xx_pipe3_issue_en),
  .lsiq_pipe3_entry_unalign_2nd          (lsiq_pipe3_entry_unalign_2nd),
  .lsiq_pipe3_entry_old                  (lsiq_pipe3_entry_old),
  .prf_dp_rf_pipe3_src0_data                              (prf_dp_rf_pipe3_src0_data),
  .dp_prf_rf_pipe3_src0_preg                              (dp_prf_rf_pipe3_src0_preg),
  .idu_lsu_ld_iid                        (idu_lsu_ld_iid),//out
  .idu_lsu_ld_preg                       (idu_lsu_ld_preg),//out
  .idu_lsu_ld_src0                       (idu_lsu_ld_src0),//out
  .idu_lsu_ld_offset                     (idu_lsu_ld_offset),//out
  .idu_lsu_ld_offset_plus                (idu_lsu_ld_offset_plus),//out
  .idu_lsu_ld_sign_extend                (idu_lsu_ld_sign_extend),//out
  .idu_lsu_ld_inst_size                  (idu_lsu_ld_inst_size),//out
  .idu_lsu_ld_unalign_2nd                (idu_lsu_ld_unalign_2nd),//out
  .idu_lsu_ld_lch_entry                  (idu_lsu_ld_lch_entry),//out
  .idu_lsu_ld_oldest                     (idu_lsu_ld_oldest),//out
  .lsiq_dp_pipe4_issue_entry             (lsiq_dp_pipe4_issue_entry),
  .lsiq_dp_pipe4_issue_read_data         (lsiq_dp_pipe4_issue_read_data),
  .lsiq_xx_pipe4_issue_en                              (lsiq_xx_pipe4_issue_en),
  .lsiq_pipe4_entry_unalign_2nd          (lsiq_pipe4_entry_unalign_2nd),
  .lsiq_pipe4_entry_old                  (lsiq_pipe4_entry_old),
  .prf_dp_rf_pipe4_src0_data                              (prf_dp_rf_pipe4_src0_data),
  .dp_prf_rf_pipe4_src0_preg                              (dp_prf_rf_pipe4_src0_preg),
  .idu_lsu_st_iid                        (idu_lsu_st_iid),//out
  .idu_lsu_st_preg                       (idu_lsu_st_preg),//out
  .idu_lsu_st_src0                       (idu_lsu_st_src0),//out
  .idu_lsu_st_offset                     (idu_lsu_st_offset),//out
  .idu_lsu_st_offset_plus                (idu_lsu_st_offset_plus),//out
  .idu_lsu_st_inst_size                  (idu_lsu_st_inst_size),//out
  .idu_lsu_st_unalign_2nd                (idu_lsu_st_unalign_2nd),//out
  .idu_lsu_st_lch_entry                  (idu_lsu_st_lch_entry),//out
  .idu_lsu_st_oldest                     (idu_lsu_st_oldest),//out
  .idu_lsu_st_sdiq_entry                 (idu_lsu_st_sdiq_entry),//out
  .sdiq_dp_issue_entry                              (sdiq_dp_issue_entry),
  .sdiq_dp_issue_read_data                              (sdiq_dp_issue_read_data),
  .sdiq_xx_issue_en                              (sdiq_xx_issue_en),
  .prf_dp_rf_pipe5_src0_data                              (prf_dp_rf_pipe5_src0_data),
  .dp_prf_rf_pipe5_src0_preg                              (dp_prf_rf_pipe5_src0_preg),
  .idu_lsu_rf_pipe5_sdiq_entry           (idu_lsu_rf_pipe5_sdiq_entry),//out
  .idu_lsu_rf_pipe5_src0                 (idu_lsu_rf_pipe5_src0),//out
  .biq_dp_issue_read_data                (biq_dp_issue_read_data),
  .biq_xx_issue_en                              (biq_xx_issue_en),
  .prf_dp_rf_pipe6_src0_data                              (prf_dp_rf_pipe6_src0_data),
  .prf_dp_rf_pipe6_src1_data                              (prf_dp_rf_pipe6_src1_data),
  .dp_prf_rf_pipe6_src0_preg                              (dp_prf_rf_pipe6_src0_preg),
  .dp_prf_rf_pipe6_src1_preg                              (dp_prf_rf_pipe6_src1_preg),
  .idu_biq_iid                           (idu_biq_iid),//out
  .idu_biq_src0                          (idu_biq_src0),//out
  .idu_biq_src1                          (idu_biq_src1),//out
  .idu_biq_rslt_sel                      (idu_biq_rslt_sel),//out
  .idu_biq_br_imme                       (idu_biq_br_imme),//out
  .idu_biq_dst_vld                        (idu_biq_dst_vld),//out
  .idu_biq_dst_preg                        (idu_biq_dst_preg),//out
  .idu_biq_taken                        (idu_biq_taken),//out
  .idu_biq_npc                        (idu_biq_npc),//out
  .idu_biq_pc                        (idu_biq_pc),//out
  .idu_biq_chk                        (idu_biq_chk)//out
);

// Instance 11: ct_idu_rf_prf_pregfile
ct_idu_rf_prf_pregfile x_ct_idu_rf_prf_pregfile (
  .forever_cpuclk                      (forever_cpuclk),   // 原接 .forever_clk, 但该模块端口是 forever_cpuclk
  .dp_prf_rf_pipe0_src0_preg                              (dp_prf_rf_pipe0_src0_preg),
  .dp_prf_rf_pipe0_src1_preg                              (dp_prf_rf_pipe0_src1_preg),
  .dp_prf_rf_pipe1_src0_preg                              (dp_prf_rf_pipe1_src0_preg),
  .dp_prf_rf_pipe1_src1_preg                              (dp_prf_rf_pipe1_src1_preg),
  .dp_prf_rf_pipe2_src0_preg                              (dp_prf_rf_pipe2_src0_preg),
  .dp_prf_rf_pipe2_src1_preg                              (dp_prf_rf_pipe2_src1_preg),
  .dp_prf_rf_pipe3_src0_preg                              (dp_prf_rf_pipe3_src0_preg),
  .dp_prf_rf_pipe4_src0_preg                              (dp_prf_rf_pipe4_src0_preg),
  .dp_prf_rf_pipe5_src0_preg                              (dp_prf_rf_pipe5_src0_preg),
  .dp_prf_rf_pipe6_src0_preg                              (dp_prf_rf_pipe6_src0_preg),
  .dp_prf_rf_pipe6_src1_preg                              (dp_prf_rf_pipe6_src1_preg),
  .iu_idu_ex2_pipe0_wb_preg_data                              (iu_idu_ex2_pipe0_wb_preg_data),//in
  .iu_idu_ex2_pipe0_wb_preg_expand                              (iu_idu_ex2_pipe0_wb_preg_expand),//in
  .iu_idu_ex2_pipe0_wb_preg_vld                              (iu_idu_ex2_pipe0_wb_preg_vld),//in
  .iu_idu_ex2_pipe1_wb_preg_data                              (iu_idu_ex2_pipe1_wb_preg_data),//in
  .iu_idu_ex2_pipe1_wb_preg_expand                              (iu_idu_ex2_pipe1_wb_preg_expand),//in
  .iu_idu_ex2_pipe1_wb_preg_vld                              (iu_idu_ex2_pipe1_wb_preg_vld),//in
  .lsu_idu_wb_pipe3_wb_preg_data                              (lsu_idu_wb_pipe3_wb_preg_data),//in
  .lsu_idu_wb_pipe3_wb_preg_expand                              (lsu_idu_wb_pipe3_wb_preg_expand),//in
  .lsu_idu_wb_pipe3_wb_preg_vld                              (lsu_idu_wb_pipe3_wb_preg_vld),//in
  .prf_dp_rf_pipe0_src0_data                              (prf_dp_rf_pipe0_src0_data),
  .prf_dp_rf_pipe0_src1_data                              (prf_dp_rf_pipe0_src1_data),
  .prf_dp_rf_pipe1_src0_data                              (prf_dp_rf_pipe1_src0_data),
  .prf_dp_rf_pipe1_src1_data                              (prf_dp_rf_pipe1_src1_data),
  .prf_dp_rf_pipe2_src0_data                              (prf_dp_rf_pipe2_src0_data),
  .prf_dp_rf_pipe2_src1_data                              (prf_dp_rf_pipe2_src1_data),
  .prf_dp_rf_pipe3_src0_data                              (prf_dp_rf_pipe3_src0_data),
  .prf_dp_rf_pipe4_src0_data                              (prf_dp_rf_pipe4_src0_data),
  .prf_dp_rf_pipe5_src0_data                              (prf_dp_rf_pipe5_src0_data),
  .prf_dp_rf_pipe6_src0_data                              (prf_dp_rf_pipe6_src0_data),
  .prf_dp_rf_pipe6_src1_data                              (prf_dp_rf_pipe6_src1_data),
  // ---- RTU 的访问口 (2026-10-08 新增, 4 读 1 写) ----
  .rtu_preg_raddr0                       (rtu_preg_raddr0),
  .rtu_preg_raddr1                       (rtu_preg_raddr1),
  .rtu_preg_raddr2                       (rtu_preg_raddr2),
  .rtu_csr_src_raddr                     (rtu_csr_src_raddr),
  .rtu_csr_rd_we                         (rtu_csr_rd_we),
  .rtu_csr_rd_addr                       (rtu_csr_rd_addr),
  .rtu_csr_rd_wdata                      (rtu_csr_rd_wdata),
  .rtu_preg_rdata0                       (rtu_preg_rdata0),
  .rtu_preg_rdata1                       (rtu_preg_rdata1),
  .rtu_preg_rdata2                       (rtu_preg_rdata2),
  .rtu_csr_src_rdata                     (rtu_csr_src_rdata)
);

//==========================================================
//   派遣记录字段打包 (2026-10-08 新增)
//==========================================================
// 从 is_dp 按车道录出的三路 83 位原始数据里拆出 RTU 要的字段。
// 位域见 ct_idu_is_dp.sv 的 IS_* parameter:
//
//   bit 77  IS_BJU            → is_branch
//   bit 75  IS_STORE          → is_store
//   [72:67] IS_DST_REL_PREG   → old_preg   (6 位: 被替换掉的旧映射)
//   [66:61] IS_DST_PREG       → dst_preg   (6 位: 分到的新物理号)
//   [60:56] IS_DST_REG        → dst_lreg   (5 位)
//   [48:43] IS_SRC1_DATA      → src1_preg  (6 位)
//            ⚠️ **不是 [48:42]**: 那 7 位是 `{preg[5:0], wb_valid}`, bit42 是 wb_valid!
//                (见 ct_idu_ir_dp.sv:528-530 与 ct_idu_ir_rt.sv:338 的
//                 `rt_dp_inst0_src1_data[6:1] = ..._read_preg[5:0]`)
//   bit 34  IS_DST_VLD        → rf_we
//   [31:0]  IS_OPCODE         → 原始指令字 (csr_addr/op/imm 与 JAL/JALR/SYSTEM 都从它切)
//
// IDU 是 6 位 preg / RTU 端口是 7 位 ⇒ 高位补 0 (PREG=64 档下本来就恒 0)。
//
// ⚠️ **A6d 必须在这里补**: `ct_idu_id_decd.sv:156` 是 `assign dst_reg = rd;` ——
//    **不写寄存器时并不清零** (store 的 inst[11:7] 是立即数的一部分, 是垃圾值)。
//    直接把它送进 `disp*_dst_lreg` 会让 RTU 按"要写 rd"去分配编号, 而退休时
//    `wr_eff` 又不成立 ⇒ 那个编号既不转 ARCH 也不释放, **静默泄漏**。
//    所以下面一律用 `{5{rf_we}} & dst_reg` 掩一遍 (老核 mycpu.v 也是这么接的)。
//
// ⚠️ flags 的位序 = RTU_define.vh 的 `RTU_FLG_*`:
//      {is_jalr, is_jal, is_mret, is_csr, intmask, is_store, is_branch}
//    * is_jal/jalr/csr/mret 从原始指令字现解 (IDU 里没有现成的这些标记 ——
//      `ct_idu_ir_decd` 只出 alu_short/load/store);
//    * `intmask` 恒 0: RTU 侧**零消费点** (全仓 grep 只有 `RTU_FLG_INTMASK` 的
//      定义与端口注释, 没有任何读取), 所以不花力气去解它。将来 RTU 真用它时,
//      这里要按"这条指令能不能被中断打断"重解。
//    * is_store/is_branch 直接用 IS 级已经分类好的 IS_STORE / IS_BJU。
//==========================================================

// ---- 车道 0 (最老) ----
assign idu_rtu_disp0_vld            = ctrl_dp_dis_inst0_vld;
assign idu_rtu_disp0_pc[31:0]       = dp_is_dis_inst0_pc[31:0];
assign idu_rtu_disp0_chk[24:0]      = dp_is_dis_inst0_chk[24:0];
assign idu_rtu_disp0_rf_we          = dp_is_dis_inst0_data[34];
assign idu_rtu_disp0_dst_lreg[4:0]  = {5{dp_is_dis_inst0_data[34]}}
                                      & dp_is_dis_inst0_data[60:56];       // A6d
assign idu_rtu_disp0_dst_preg[6:0]  = {1'b0, dp_is_dis_inst0_data[66:61]};
assign idu_rtu_disp0_old_preg[6:0]  = {1'b0, dp_is_dis_inst0_data[72:67]};
assign idu_rtu_disp0_src1_preg[6:0] = {1'b0, dp_is_dis_inst0_data[48:43]};
assign idu_rtu_disp0_csr_addr[11:0] = dp_is_dis_inst0_data[31:20];
assign idu_rtu_disp0_csr_imm[4:0]   = dp_is_dis_inst0_data[19:15];
assign idu_rtu_disp0_csr_op[2:0]    = dp_is_dis_inst0_data[14:12];         // A6c: funct3 原样
assign idu_rtu_disp0_flags[6]       = (dp_is_dis_inst0_data[6:0] == 7'b1100111); // is_jalr
assign idu_rtu_disp0_flags[5]       = (dp_is_dis_inst0_data[6:0] == 7'b1101111); // is_jal
assign idu_rtu_disp0_flags[4]       = (dp_is_dis_inst0_data[6:0] == 7'b1110011)  // is_mret
                                    & (dp_is_dis_inst0_data[14:12] == 3'b000)
                                    & (dp_is_dis_inst0_data[31:20] == 12'h302);
assign idu_rtu_disp0_flags[3]       = (dp_is_dis_inst0_data[6:0] == 7'b1110011)  // is_csr
                                    & (dp_is_dis_inst0_data[14:12] != 3'b000);
assign idu_rtu_disp0_flags[2]       = 1'b0;                                      // intmask
assign idu_rtu_disp0_flags[1]       = dp_is_dis_inst0_data[75];                  // is_store
assign idu_rtu_disp0_flags[0]       = dp_is_dis_inst0_data[77];                  // is_branch

// ---- 车道 1 (居中) ----
assign idu_rtu_disp1_vld            = ctrl_dp_dis_inst1_vld;
assign idu_rtu_disp1_pc[31:0]       = dp_is_dis_inst1_pc[31:0];
assign idu_rtu_disp1_chk[24:0]      = dp_is_dis_inst1_chk[24:0];
assign idu_rtu_disp1_rf_we          = dp_is_dis_inst1_data[34];
assign idu_rtu_disp1_dst_lreg[4:0]  = {5{dp_is_dis_inst1_data[34]}}
                                      & dp_is_dis_inst1_data[60:56];       // A6d
assign idu_rtu_disp1_dst_preg[6:0]  = {1'b0, dp_is_dis_inst1_data[66:61]};
assign idu_rtu_disp1_old_preg[6:0]  = {1'b0, dp_is_dis_inst1_data[72:67]};
assign idu_rtu_disp1_src1_preg[6:0] = {1'b0, dp_is_dis_inst1_data[48:43]};
assign idu_rtu_disp1_csr_addr[11:0] = dp_is_dis_inst1_data[31:20];
assign idu_rtu_disp1_csr_imm[4:0]   = dp_is_dis_inst1_data[19:15];
assign idu_rtu_disp1_csr_op[2:0]    = dp_is_dis_inst1_data[14:12];
assign idu_rtu_disp1_flags[6]       = (dp_is_dis_inst1_data[6:0] == 7'b1100111);
assign idu_rtu_disp1_flags[5]       = (dp_is_dis_inst1_data[6:0] == 7'b1101111);
assign idu_rtu_disp1_flags[4]       = (dp_is_dis_inst1_data[6:0] == 7'b1110011)
                                    & (dp_is_dis_inst1_data[14:12] == 3'b000)
                                    & (dp_is_dis_inst1_data[31:20] == 12'h302);
assign idu_rtu_disp1_flags[3]       = (dp_is_dis_inst1_data[6:0] == 7'b1110011)
                                    & (dp_is_dis_inst1_data[14:12] != 3'b000);
assign idu_rtu_disp1_flags[2]       = 1'b0;
assign idu_rtu_disp1_flags[1]       = dp_is_dis_inst1_data[75];
assign idu_rtu_disp1_flags[0]       = dp_is_dis_inst1_data[77];

// ---- 车道 2 (最年轻) ----
assign idu_rtu_disp2_vld            = ctrl_dp_dis_inst2_vld;
assign idu_rtu_disp2_pc[31:0]       = dp_is_dis_inst2_pc[31:0];
assign idu_rtu_disp2_chk[24:0]      = dp_is_dis_inst2_chk[24:0];
assign idu_rtu_disp2_rf_we          = dp_is_dis_inst2_data[34];
assign idu_rtu_disp2_dst_lreg[4:0]  = {5{dp_is_dis_inst2_data[34]}}
                                      & dp_is_dis_inst2_data[60:56];       // A6d
assign idu_rtu_disp2_dst_preg[6:0]  = {1'b0, dp_is_dis_inst2_data[66:61]};
assign idu_rtu_disp2_old_preg[6:0]  = {1'b0, dp_is_dis_inst2_data[72:67]};
assign idu_rtu_disp2_src1_preg[6:0] = {1'b0, dp_is_dis_inst2_data[48:43]};
assign idu_rtu_disp2_csr_addr[11:0] = dp_is_dis_inst2_data[31:20];
assign idu_rtu_disp2_csr_imm[4:0]   = dp_is_dis_inst2_data[19:15];
assign idu_rtu_disp2_csr_op[2:0]    = dp_is_dis_inst2_data[14:12];
assign idu_rtu_disp2_flags[6]       = (dp_is_dis_inst2_data[6:0] == 7'b1100111);
assign idu_rtu_disp2_flags[5]       = (dp_is_dis_inst2_data[6:0] == 7'b1101111);
assign idu_rtu_disp2_flags[4]       = (dp_is_dis_inst2_data[6:0] == 7'b1110011)
                                    & (dp_is_dis_inst2_data[14:12] == 3'b000)
                                    & (dp_is_dis_inst2_data[31:20] == 12'h302);
assign idu_rtu_disp2_flags[3]       = (dp_is_dis_inst2_data[6:0] == 7'b1110011)
                                    & (dp_is_dis_inst2_data[14:12] != 3'b000);
assign idu_rtu_disp2_flags[2]       = 1'b0;
assign idu_rtu_disp2_flags[1]       = dp_is_dis_inst2_data[75];
assign idu_rtu_disp2_flags[0]       = dp_is_dis_inst2_data[77];

endmodule
