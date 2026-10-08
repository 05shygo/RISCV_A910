//==========================================================
// tb_idu_c910 —— C910 移植 IDU (ct_idu_top) 的 elaboration 冒烟台
//==========================================================
// 【这个台子要守住什么】
// 主构建 (make build) 里没有任何模块例化 ct_idu_top, 而 VCS 只 elaborate
// 从 -top 可达的层次 —— 于是这个 IDU 只会被 "Parsing", 内部的端口连接错误
// (接错的端口名 / 位宽不符 / 未驱动网) 一个都查不出来。
// 这里把它**真的例化一次**, 专门逼出这类错误; 顺便跑几百拍看有没有 X。
//
// 【它不是功能验证】输入全接常量, 只验证"能 elaborate + 上电不炸"。
// 真正的契约测试 (派遣记录 / preg 分配握手 / 冲刷) 要等 Phase 3-4 再往这里加。
//
// ⚠️ 端口连接是 scripts/gen_idu_smoke_tb.py 从 ct_idu_top.sv **生成的**,
//    手改这里会在下次重生成时丢掉。改了 IDU 顶层端口就重跑那个脚本。
//==========================================================

`timescale 1ns/1ps

module tb_idu_c910;

  reg clk;
  reg rst_n;

  initial begin clk = 1'b0; forever #5 clk = ~clk; end

  // ---- 时钟/复位 ----
  wire       forever_cpuclk;
  wire       cpurst_b;

  // ---- 定向激励驱动的输入 (由下面的 initial 块给值) ----
  reg       ifu_idu_ib_inst0_vld;
  reg [96:0] ifu_idu_ib_inst0_data;
  reg [24:0] ifu_idu_if_inst0_chk;
  reg       rtu_idu_alloc_preg0_vld;
  reg [ 5:0] rtu_idu_alloc_preg0;
  reg [ 5:0] rtu_preg_raddr0;
  reg       rtu_csr_rd_we;
  reg [ 5:0] rtu_csr_rd_addr;
  reg [31:0] rtu_csr_rd_wdata;

  // ---- 其余输入: 全部接常量 0 ----
  wire       ifu_idu_ib_inst1_vld;
  wire       ifu_idu_ib_inst2_vld;
  wire [96:0] ifu_idu_ib_inst1_data;
  wire [24:0] ifu_idu_if_inst1_chk;
  wire [96:0] ifu_idu_ib_inst2_data;
  wire [24:0] ifu_idu_if_inst2_chk;
  wire       rtu_idu_alloc_preg1_vld;
  wire       rtu_idu_alloc_preg2_vld;
  wire [ 5:0] rtu_idu_alloc_preg1;
  wire [ 5:0] rtu_idu_alloc_preg2;
  wire [ 6:0] rtu_idu_rob_inst0_iid;
  wire [ 6:0] rtu_idu_rob_inst1_iid;
  wire [ 6:0] rtu_idu_rob_inst2_iid;
  wire [191:0] rtu_idu_rt_recover_preg;
  wire [ 5:0] iu_idu_ex2_pipe0_wb_preg_dupx;
  wire       iu_idu_ex2_pipe0_wb_preg_vld_dupx;
  wire [31:0] iu_idu_ex2_pipe0_wb_preg_data;
  wire [63:0] iu_idu_ex2_pipe0_wb_preg_expand;
  wire       iu_idu_ex2_pipe0_wb_preg_vld;
  wire [ 5:0] iu_idu_ex2_pipe1_wb_preg_dupx;
  wire       iu_idu_ex2_pipe1_wb_preg_vld_dupx;
  wire [31:0] iu_idu_ex2_pipe1_wb_preg_data;
  wire [63:0] iu_idu_ex2_pipe1_wb_preg_expand;
  wire       iu_idu_ex2_pipe1_wb_preg_vld;
  wire [ 5:0] lsu_idu_wb_pipe3_wb_preg_dupx;
  wire       lsu_idu_wb_pipe3_wb_preg_vld_dupx;
  wire [31:0] lsu_idu_wb_pipe3_wb_preg_data;
  wire [63:0] lsu_idu_wb_pipe3_wb_preg_expand;
  wire       lsu_idu_wb_pipe3_wb_preg_vld;
  wire [ 7:0] lsu_idu_lq_full;
  wire [ 7:0] lsu_idu_rb_full;
  wire [ 7:0] lsu_idu_sq_full;
  wire [ 7:0] lsu_idu_secd;
  wire [ 7:0] lsu_idu_imme_wakeup;
  wire       lsu_idu_lsiq_pop_vld;
  wire       lsu_idu_lsiq_pop0_vld;
  wire       lsu_idu_lsiq_pop1_vld;
  wire [ 7:0] lsu_idu_lsiq_pop_entry;
  wire       lsu_sdiq_has_in_sq_vld;
  wire [ 3:0] lsu_sdiq_has_in_sq_sdiq;
  wire [ 5:0] rtu_preg_raddr1;
  wire [ 5:0] rtu_preg_raddr2;
  wire [ 5:0] rtu_csr_src_raddr;

  // ---- 输出 ----
  wire [ 1:0] idu_accept_num;
  wire       idu_rtu_ir_preg0_alloc_vld;
  wire       idu_rtu_ir_preg1_alloc_vld;
  wire       idu_rtu_ir_preg2_alloc_vld;
  wire [63:0] idu_rtu_pst_preg_dealloc_mask;
  wire       idu_aiq_sel;
  wire [ 6:0] idu_aiq_iid;
  wire [ 5:0] idu_aiq_dst_preg;
  wire [31:0] idu_aiq_src0;
  wire [31:0] idu_aiq_src1;
  wire [31:0] idu_aiq_pc;
  wire [12:0] idu_aiq_rslt_sel;
  wire       idu_aiq_illegal;
  wire       idu_mult_sel;
  wire [ 6:0] idu_mult_iid;
  wire [ 5:0] idu_mult_dst_preg;
  wire [31:0] idu_mult_src0;
  wire [31:0] idu_mult_src1;
  wire [ 3:0] idu_mult_rslt_sel;
  wire       idu_div_sel;
  wire [ 6:0] idu_div_iid;
  wire       idu_div_dst_vld;
  wire [ 5:0] idu_div_dst_preg;
  wire [31:0] idu_div_src0;
  wire [31:0] idu_div_src1;
  wire [ 3:0] idu_div_rslt_sel;
  wire       idu_lsu_ld_sel;
  wire [ 6:0] idu_lsu_ld_iid;
  wire [ 5:0] idu_lsu_ld_preg;
  wire [31:0] idu_lsu_ld_src0;
  wire [11:0] idu_lsu_ld_offset;
  wire [12:0] idu_lsu_ld_offset_plus;
  wire       idu_lsu_ld_sign_extend;
  wire [ 1:0] idu_lsu_ld_inst_size;
  wire       idu_lsu_ld_unalign_2nd;
  wire [ 7:0] idu_lsu_ld_lch_entry;
  wire       idu_lsu_ld_oldest;
  wire       idu_lsu_st_sel;
  wire [ 6:0] idu_lsu_st_iid;
  wire [ 5:0] idu_lsu_st_preg;
  wire [31:0] idu_lsu_st_src0;
  wire [11:0] idu_lsu_st_offset;
  wire [12:0] idu_lsu_st_offset_plus;
  wire [ 1:0] idu_lsu_st_inst_size;
  wire       idu_lsu_st_unalign_2nd;
  wire [ 7:0] idu_lsu_st_lch_entry;
  wire       idu_lsu_st_oldest;
  wire [ 3:0] idu_lsu_st_sdiq_entry;
  wire       idu_lsu_sdiq_sel;
  wire [ 3:0] idu_lsu_rf_pipe5_sdiq_entry;
  wire [31:0] idu_lsu_rf_pipe5_src0;
  wire       idu_biq_sel;
  wire [ 6:0] idu_biq_iid;
  wire [31:0] idu_biq_src0;
  wire [31:0] idu_biq_src1;
  wire [ 5:0] idu_biq_rslt_sel;
  wire [31:0] idu_biq_br_imme;
  wire       idu_biq_dst_vld;
  wire [ 5:0] idu_biq_dst_preg;
  wire       idu_biq_taken;
  wire [31:0] idu_biq_npc;
  wire [31:0] idu_biq_pc;
  wire [24:0] idu_biq_chk;
  wire       idu_rtu_disp0_vld;
  wire [31:0] idu_rtu_disp0_pc;
  wire [24:0] idu_rtu_disp0_chk;
  wire [ 4:0] idu_rtu_disp0_dst_lreg;
  wire       idu_rtu_disp0_rf_we;
  wire [ 6:0] idu_rtu_disp0_dst_preg;
  wire [ 6:0] idu_rtu_disp0_old_preg;
  wire [ 6:0] idu_rtu_disp0_src1_preg;
  wire [11:0] idu_rtu_disp0_csr_addr;
  wire [ 2:0] idu_rtu_disp0_csr_op;
  wire [ 4:0] idu_rtu_disp0_csr_imm;
  wire [ 6:0] idu_rtu_disp0_flags;
  wire       idu_rtu_disp1_vld;
  wire [31:0] idu_rtu_disp1_pc;
  wire [24:0] idu_rtu_disp1_chk;
  wire [ 4:0] idu_rtu_disp1_dst_lreg;
  wire       idu_rtu_disp1_rf_we;
  wire [ 6:0] idu_rtu_disp1_dst_preg;
  wire [ 6:0] idu_rtu_disp1_old_preg;
  wire [ 6:0] idu_rtu_disp1_src1_preg;
  wire [11:0] idu_rtu_disp1_csr_addr;
  wire [ 2:0] idu_rtu_disp1_csr_op;
  wire [ 4:0] idu_rtu_disp1_csr_imm;
  wire [ 6:0] idu_rtu_disp1_flags;
  wire       idu_rtu_disp2_vld;
  wire [31:0] idu_rtu_disp2_pc;
  wire [24:0] idu_rtu_disp2_chk;
  wire [ 4:0] idu_rtu_disp2_dst_lreg;
  wire       idu_rtu_disp2_rf_we;
  wire [ 6:0] idu_rtu_disp2_dst_preg;
  wire [ 6:0] idu_rtu_disp2_old_preg;
  wire [ 6:0] idu_rtu_disp2_src1_preg;
  wire [11:0] idu_rtu_disp2_csr_addr;
  wire [ 2:0] idu_rtu_disp2_csr_op;
  wire [ 4:0] idu_rtu_disp2_csr_imm;
  wire [ 6:0] idu_rtu_disp2_flags;
  wire [31:0] rtu_preg_rdata0;
  wire [31:0] rtu_preg_rdata1;
  wire [31:0] rtu_preg_rdata2;
  wire [31:0] rtu_csr_src_rdata;

  assign forever_cpuclk = clk;
  assign cpurst_b       = rst_n;
  assign ifu_idu_ib_inst1_vld             = 1'b0;
  assign ifu_idu_ib_inst2_vld             = 1'b0;
  assign ifu_idu_ib_inst1_data            = 97'b0;
  assign ifu_idu_if_inst1_chk             = 25'b0;
  assign ifu_idu_ib_inst2_data            = 97'b0;
  assign ifu_idu_if_inst2_chk             = 25'b0;
  assign rtu_idu_alloc_preg1_vld          = 1'b0;
  assign rtu_idu_alloc_preg2_vld          = 1'b0;
  assign rtu_idu_alloc_preg1              = 6'b0;
  assign rtu_idu_alloc_preg2              = 6'b0;
  assign rtu_idu_rob_inst0_iid            = 7'b0;
  assign rtu_idu_rob_inst1_iid            = 7'b0;
  assign rtu_idu_rob_inst2_iid            = 7'b0;
  assign rtu_idu_rt_recover_preg          = 192'b0;
  assign iu_idu_ex2_pipe0_wb_preg_dupx    = 6'b0;
  assign iu_idu_ex2_pipe0_wb_preg_vld_dupx = 1'b0;
  assign iu_idu_ex2_pipe0_wb_preg_data    = 32'b0;
  assign iu_idu_ex2_pipe0_wb_preg_expand  = 64'b0;
  assign iu_idu_ex2_pipe0_wb_preg_vld     = 1'b0;
  assign iu_idu_ex2_pipe1_wb_preg_dupx    = 6'b0;
  assign iu_idu_ex2_pipe1_wb_preg_vld_dupx = 1'b0;
  assign iu_idu_ex2_pipe1_wb_preg_data    = 32'b0;
  assign iu_idu_ex2_pipe1_wb_preg_expand  = 64'b0;
  assign iu_idu_ex2_pipe1_wb_preg_vld     = 1'b0;
  assign lsu_idu_wb_pipe3_wb_preg_dupx    = 6'b0;
  assign lsu_idu_wb_pipe3_wb_preg_vld_dupx = 1'b0;
  assign lsu_idu_wb_pipe3_wb_preg_data    = 32'b0;
  assign lsu_idu_wb_pipe3_wb_preg_expand  = 64'b0;
  assign lsu_idu_wb_pipe3_wb_preg_vld     = 1'b0;
  assign lsu_idu_lq_full                  = 8'b0;
  assign lsu_idu_rb_full                  = 8'b0;
  assign lsu_idu_sq_full                  = 8'b0;
  assign lsu_idu_secd                     = 8'b0;
  assign lsu_idu_imme_wakeup              = 8'b0;
  assign lsu_idu_lsiq_pop_vld             = 1'b0;
  assign lsu_idu_lsiq_pop0_vld            = 1'b0;
  assign lsu_idu_lsiq_pop1_vld            = 1'b0;
  assign lsu_idu_lsiq_pop_entry           = 8'b0;
  assign lsu_sdiq_has_in_sq_vld           = 1'b0;
  assign lsu_sdiq_has_in_sq_sdiq          = 4'b0;
  assign rtu_preg_raddr1                  = 6'b0;
  assign rtu_preg_raddr2                  = 6'b0;
  assign rtu_csr_src_raddr                = 6'b0;

  // ROB 不满 ⇒ 允许派遣; 不冲刷
  assign rtu_idu_rob_full = 1'b0;
  assign rtu_yy_xx_flush  = 1'b0;
  // LSU 队列的"不满"指示: 接 1 (接 0 会让 LSIQ 建不进去, 走不到派遣)
  assign lsu_idu_lq_not_full              = 1'b1;
  assign lsu_idu_rb_not_full              = 1'b1;
  assign lsu_idu_sq_not_full              = 1'b1;

  ct_idu_top u_ct_idu_top (
    .forever_cpuclk                 (forever_cpuclk),
    .cpurst_b                       (cpurst_b),
    .ifu_idu_ib_inst1_vld             (ifu_idu_ib_inst1_vld            ),
    .ifu_idu_ib_inst2_vld             (ifu_idu_ib_inst2_vld            ),
    .ifu_idu_ib_inst1_data            (ifu_idu_ib_inst1_data           ),
    .ifu_idu_if_inst1_chk             (ifu_idu_if_inst1_chk            ),
    .ifu_idu_ib_inst2_data            (ifu_idu_ib_inst2_data           ),
    .ifu_idu_if_inst2_chk             (ifu_idu_if_inst2_chk            ),
    .rtu_idu_alloc_preg1_vld          (rtu_idu_alloc_preg1_vld         ),
    .rtu_idu_alloc_preg2_vld          (rtu_idu_alloc_preg2_vld         ),
    .rtu_idu_alloc_preg1              (rtu_idu_alloc_preg1             ),
    .rtu_idu_alloc_preg2              (rtu_idu_alloc_preg2             ),
    .rtu_idu_rob_inst0_iid            (rtu_idu_rob_inst0_iid           ),
    .rtu_idu_rob_inst1_iid            (rtu_idu_rob_inst1_iid           ),
    .rtu_idu_rob_inst2_iid            (rtu_idu_rob_inst2_iid           ),
    .rtu_idu_rt_recover_preg          (rtu_idu_rt_recover_preg         ),
    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx   ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
    .iu_idu_ex2_pipe0_wb_preg_data    (iu_idu_ex2_pipe0_wb_preg_data   ),
    .iu_idu_ex2_pipe0_wb_preg_expand  (iu_idu_ex2_pipe0_wb_preg_expand ),
    .iu_idu_ex2_pipe0_wb_preg_vld     (iu_idu_ex2_pipe0_wb_preg_vld    ),
    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx   ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
    .iu_idu_ex2_pipe1_wb_preg_data    (iu_idu_ex2_pipe1_wb_preg_data   ),
    .iu_idu_ex2_pipe1_wb_preg_expand  (iu_idu_ex2_pipe1_wb_preg_expand ),
    .iu_idu_ex2_pipe1_wb_preg_vld     (iu_idu_ex2_pipe1_wb_preg_vld    ),
    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx   ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
    .lsu_idu_wb_pipe3_wb_preg_data    (lsu_idu_wb_pipe3_wb_preg_data   ),
    .lsu_idu_wb_pipe3_wb_preg_expand  (lsu_idu_wb_pipe3_wb_preg_expand ),
    .lsu_idu_wb_pipe3_wb_preg_vld     (lsu_idu_wb_pipe3_wb_preg_vld    ),
    .lsu_idu_lq_full                  (lsu_idu_lq_full                 ),
    .lsu_idu_rb_full                  (lsu_idu_rb_full                 ),
    .lsu_idu_sq_full                  (lsu_idu_sq_full                 ),
    .lsu_idu_secd                     (lsu_idu_secd                    ),
    .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup             ),
    .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld            ),
    .lsu_idu_lsiq_pop0_vld            (lsu_idu_lsiq_pop0_vld           ),
    .lsu_idu_lsiq_pop1_vld            (lsu_idu_lsiq_pop1_vld           ),
    .lsu_idu_lsiq_pop_entry           (lsu_idu_lsiq_pop_entry          ),
    .lsu_sdiq_has_in_sq_vld           (lsu_sdiq_has_in_sq_vld          ),
    .lsu_sdiq_has_in_sq_sdiq          (lsu_sdiq_has_in_sq_sdiq         ),
    .rtu_preg_raddr1                  (rtu_preg_raddr1                 ),
    .rtu_preg_raddr2                  (rtu_preg_raddr2                 ),
    .rtu_csr_src_raddr                (rtu_csr_src_raddr               ),
    .rtu_idu_rob_full                 (rtu_idu_rob_full                ),
    .rtu_yy_xx_flush                  (rtu_yy_xx_flush                 ),
    .lsu_idu_lq_not_full              (lsu_idu_lq_not_full             ),
    .lsu_idu_rb_not_full              (lsu_idu_rb_not_full             ),
    .lsu_idu_sq_not_full              (lsu_idu_sq_not_full             ),
    .ifu_idu_ib_inst0_vld             (ifu_idu_ib_inst0_vld            ),
    .ifu_idu_ib_inst0_data            (ifu_idu_ib_inst0_data           ),
    .ifu_idu_if_inst0_chk             (ifu_idu_if_inst0_chk            ),
    .rtu_idu_alloc_preg0_vld          (rtu_idu_alloc_preg0_vld         ),
    .rtu_idu_alloc_preg0              (rtu_idu_alloc_preg0             ),
    .rtu_preg_raddr0                  (rtu_preg_raddr0                 ),
    .rtu_csr_rd_we                    (rtu_csr_rd_we                   ),
    .rtu_csr_rd_addr                  (rtu_csr_rd_addr                 ),
    .rtu_csr_rd_wdata                 (rtu_csr_rd_wdata                ),
    .idu_accept_num                   (idu_accept_num                  ),
    .idu_rtu_ir_preg0_alloc_vld       (idu_rtu_ir_preg0_alloc_vld      ),
    .idu_rtu_ir_preg1_alloc_vld       (idu_rtu_ir_preg1_alloc_vld      ),
    .idu_rtu_ir_preg2_alloc_vld       (idu_rtu_ir_preg2_alloc_vld      ),
    .idu_rtu_pst_preg_dealloc_mask    (idu_rtu_pst_preg_dealloc_mask   ),
    .idu_aiq_sel                      (idu_aiq_sel                     ),
    .idu_aiq_iid                      (idu_aiq_iid                     ),
    .idu_aiq_dst_preg                 (idu_aiq_dst_preg                ),
    .idu_aiq_src0                     (idu_aiq_src0                    ),
    .idu_aiq_src1                     (idu_aiq_src1                    ),
    .idu_aiq_pc                       (idu_aiq_pc                      ),
    .idu_aiq_rslt_sel                 (idu_aiq_rslt_sel                ),
    .idu_aiq_illegal                  (idu_aiq_illegal                 ),
    .idu_mult_sel                     (idu_mult_sel                    ),
    .idu_mult_iid                     (idu_mult_iid                    ),
    .idu_mult_dst_preg                (idu_mult_dst_preg               ),
    .idu_mult_src0                    (idu_mult_src0                   ),
    .idu_mult_src1                    (idu_mult_src1                   ),
    .idu_mult_rslt_sel                (idu_mult_rslt_sel               ),
    .idu_div_sel                      (idu_div_sel                     ),
    .idu_div_iid                      (idu_div_iid                     ),
    .idu_div_dst_vld                  (idu_div_dst_vld                 ),
    .idu_div_dst_preg                 (idu_div_dst_preg                ),
    .idu_div_src0                     (idu_div_src0                    ),
    .idu_div_src1                     (idu_div_src1                    ),
    .idu_div_rslt_sel                 (idu_div_rslt_sel                ),
    .idu_lsu_ld_sel                   (idu_lsu_ld_sel                  ),
    .idu_lsu_ld_iid                   (idu_lsu_ld_iid                  ),
    .idu_lsu_ld_preg                  (idu_lsu_ld_preg                 ),
    .idu_lsu_ld_src0                  (idu_lsu_ld_src0                 ),
    .idu_lsu_ld_offset                (idu_lsu_ld_offset               ),
    .idu_lsu_ld_offset_plus           (idu_lsu_ld_offset_plus          ),
    .idu_lsu_ld_sign_extend           (idu_lsu_ld_sign_extend          ),
    .idu_lsu_ld_inst_size             (idu_lsu_ld_inst_size            ),
    .idu_lsu_ld_unalign_2nd           (idu_lsu_ld_unalign_2nd          ),
    .idu_lsu_ld_lch_entry             (idu_lsu_ld_lch_entry            ),
    .idu_lsu_ld_oldest                (idu_lsu_ld_oldest               ),
    .idu_lsu_st_sel                   (idu_lsu_st_sel                  ),
    .idu_lsu_st_iid                   (idu_lsu_st_iid                  ),
    .idu_lsu_st_preg                  (idu_lsu_st_preg                 ),
    .idu_lsu_st_src0                  (idu_lsu_st_src0                 ),
    .idu_lsu_st_offset                (idu_lsu_st_offset               ),
    .idu_lsu_st_offset_plus           (idu_lsu_st_offset_plus          ),
    .idu_lsu_st_inst_size             (idu_lsu_st_inst_size            ),
    .idu_lsu_st_unalign_2nd           (idu_lsu_st_unalign_2nd          ),
    .idu_lsu_st_lch_entry             (idu_lsu_st_lch_entry            ),
    .idu_lsu_st_oldest                (idu_lsu_st_oldest               ),
    .idu_lsu_st_sdiq_entry            (idu_lsu_st_sdiq_entry           ),
    .idu_lsu_sdiq_sel                 (idu_lsu_sdiq_sel                ),
    .idu_lsu_rf_pipe5_sdiq_entry      (idu_lsu_rf_pipe5_sdiq_entry     ),
    .idu_lsu_rf_pipe5_src0            (idu_lsu_rf_pipe5_src0           ),
    .idu_biq_sel                      (idu_biq_sel                     ),
    .idu_biq_iid                      (idu_biq_iid                     ),
    .idu_biq_src0                     (idu_biq_src0                    ),
    .idu_biq_src1                     (idu_biq_src1                    ),
    .idu_biq_rslt_sel                 (idu_biq_rslt_sel                ),
    .idu_biq_br_imme                  (idu_biq_br_imme                 ),
    .idu_biq_dst_vld                  (idu_biq_dst_vld                 ),
    .idu_biq_dst_preg                 (idu_biq_dst_preg                ),
    .idu_biq_taken                    (idu_biq_taken                   ),
    .idu_biq_npc                      (idu_biq_npc                     ),
    .idu_biq_pc                       (idu_biq_pc                      ),
    .idu_biq_chk                      (idu_biq_chk                     ),
    .idu_rtu_disp0_vld                (idu_rtu_disp0_vld               ),
    .idu_rtu_disp0_pc                 (idu_rtu_disp0_pc                ),
    .idu_rtu_disp0_chk                (idu_rtu_disp0_chk               ),
    .idu_rtu_disp0_dst_lreg           (idu_rtu_disp0_dst_lreg          ),
    .idu_rtu_disp0_rf_we              (idu_rtu_disp0_rf_we             ),
    .idu_rtu_disp0_dst_preg           (idu_rtu_disp0_dst_preg          ),
    .idu_rtu_disp0_old_preg           (idu_rtu_disp0_old_preg          ),
    .idu_rtu_disp0_src1_preg          (idu_rtu_disp0_src1_preg         ),
    .idu_rtu_disp0_csr_addr           (idu_rtu_disp0_csr_addr          ),
    .idu_rtu_disp0_csr_op             (idu_rtu_disp0_csr_op            ),
    .idu_rtu_disp0_csr_imm            (idu_rtu_disp0_csr_imm           ),
    .idu_rtu_disp0_flags              (idu_rtu_disp0_flags             ),
    .idu_rtu_disp1_vld                (idu_rtu_disp1_vld               ),
    .idu_rtu_disp1_pc                 (idu_rtu_disp1_pc                ),
    .idu_rtu_disp1_chk                (idu_rtu_disp1_chk               ),
    .idu_rtu_disp1_dst_lreg           (idu_rtu_disp1_dst_lreg          ),
    .idu_rtu_disp1_rf_we              (idu_rtu_disp1_rf_we             ),
    .idu_rtu_disp1_dst_preg           (idu_rtu_disp1_dst_preg          ),
    .idu_rtu_disp1_old_preg           (idu_rtu_disp1_old_preg          ),
    .idu_rtu_disp1_src1_preg          (idu_rtu_disp1_src1_preg         ),
    .idu_rtu_disp1_csr_addr           (idu_rtu_disp1_csr_addr          ),
    .idu_rtu_disp1_csr_op             (idu_rtu_disp1_csr_op            ),
    .idu_rtu_disp1_csr_imm            (idu_rtu_disp1_csr_imm           ),
    .idu_rtu_disp1_flags              (idu_rtu_disp1_flags             ),
    .idu_rtu_disp2_vld                (idu_rtu_disp2_vld               ),
    .idu_rtu_disp2_pc                 (idu_rtu_disp2_pc                ),
    .idu_rtu_disp2_chk                (idu_rtu_disp2_chk               ),
    .idu_rtu_disp2_dst_lreg           (idu_rtu_disp2_dst_lreg          ),
    .idu_rtu_disp2_rf_we              (idu_rtu_disp2_rf_we             ),
    .idu_rtu_disp2_dst_preg           (idu_rtu_disp2_dst_preg          ),
    .idu_rtu_disp2_old_preg           (idu_rtu_disp2_old_preg          ),
    .idu_rtu_disp2_src1_preg          (idu_rtu_disp2_src1_preg         ),
    .idu_rtu_disp2_csr_addr           (idu_rtu_disp2_csr_addr          ),
    .idu_rtu_disp2_csr_op             (idu_rtu_disp2_csr_op            ),
    .idu_rtu_disp2_csr_imm            (idu_rtu_disp2_csr_imm           ),
    .idu_rtu_disp2_flags              (idu_rtu_disp2_flags             ),
    .rtu_preg_rdata0                  (rtu_preg_rdata0                 ),
    .rtu_preg_rdata1                  (rtu_preg_rdata1                 ),
    .rtu_preg_rdata2                  (rtu_preg_rdata2                 ),
    .rtu_csr_src_rdata                (rtu_csr_src_rdata               )
  );

  //==========================================================
  //   定向激励 + 判据 (2026-10-08 加)
  //==========================================================
  // 【要证的三个东西 —— 都是这次修复的核心, 而且是 elaboration 查不出来的】
  //
  //  ⓐ **RAT 真的在写**。交付的 IDU 里改名表挂在无驱动的 write_clk 上 (C910 工厂版的
  //     门控时钟单元被剥掉了), 写使能数组也压根没接 ⇒ 一个字都写不进去。
  //     判据: 灌一条 `addi x1,x0,1` 并让 RTU 恒给号 33, 然后**直接看 x1 表项**
  //     是不是变成了 33 —— 即"编号从 rtu_idu_alloc_preg0 一路走到表项"。
  //
  //  ⓑ **复位映射真的灌进了 RAT**。`rt_reset_updt_preg` 原来是零消费的 ⇒ 上电后
  //     所有逻辑寄存器都指向 p0。判据: 复位一释放、**还没灌任何指令时**查 x1 表项
  //     必须是架构映射 p1 (一旦有指令改名它就被覆盖了, 所以必须在这之前查)。
  //
  //  ⓒ **派遣记录真的出来了**。查 36 根新口的 vld/pc/rf_we/dst_lreg/dst_preg/chk
  //     与灌进去的激励对得上, 外加 A6d (不写寄存器时 dst_lreg 必须为 0)。
  //
  // ⚠️ ⓐ / ⓑ 走的是**层次引用**(见下面"观察点"那段注释): 对外唯一能看到表项的路径
  //    是派遣记录的 `old_preg`, 而那条路有交付缺陷 (采样晚一拍), 用它会变成恒真空判据。
  // 激励: 每拍往 inst0 车道灌一条 `addi x1, x0, 1` (pc=0x100), RTU 侧恒给号 33。
  //==========================================================
  localparam [31:0] PC0       = 32'h0000_0100;
  localparam [31:0] INST_ADDI = 32'h0010_0093;      // addi x1, x0, 1
  localparam [6:0]  PREG_GIVEN = 7'd33;
  localparam [6:0]  ARCH_X1    = 7'd1;              // rt_reset_updt_preg 里 x1 → p1
  localparam [24:0] CHK0      = 25'h0_12345;
  localparam [5:0]  PRF_ADDR  = 6'd9;               // 随便挑一个非 0 的物理号
  localparam [31:0] PRF_DATA  = 32'hDEAD_BEEF;      // 一个不会跟别的值撞的常数

  integer     n_disp;          // 观测到的派遣次数
  integer     errs;
  logic       saw_rat_write;   // ★ 见过 old_preg 变成 RTU 给的号

  // ---- 改名表 x1 表项的观察点 ----
  // ⚠️ 这里**故意用层次引用**。判据要用的是"表项里存的到底是不是那个号", 而
  //    对外唯一能看到它的路径是派遣记录的 `old_preg` —— 那条路**有交付缺陷**:
  //    `IS_DST_REL_PREG` 是对 RAT 的**实时组合读**, 到 IS 建表目那一拍才采样,
  //    比改名晚一拍, 于是采到的是**写之后**的值, 恒等于自己的 `dst_preg` ⇒
  //    "RAT 有没有写进去" 用它是问不出来的 (会变成恒真的空判据)。
  //    要修的是交付侧 (把 rel_preg 在 IR→IS 边界寄存), 不是这里。
  //    路径: ct_idu_top → ct_idu_ir_rt → generate 块 → 表项 (x1 是 1 号)
  wire [6:0] dbg_rat_x1 =
      u_ct_idu_top.x_ct_idu_ir_rt.gen_ct_idu_ir_rt_entry[1].x_ct_idu_ir_rt_entry_reg.preg;

  // ---- 派遣监视 ----
  always @(posedge clk) begin
    if (rst_n === 1'b1 && idu_rtu_disp0_vld === 1'b1) begin
      n_disp = n_disp + 1;

      if (idu_rtu_disp0_pc       !== PC0)       begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 pc=%h 期望 %h", n_disp, idu_rtu_disp0_pc, PC0); end
      if (idu_rtu_disp0_rf_we    !== 1'b1)      begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 rf_we=%b 期望 1 (addi 写 rd)", n_disp, idu_rtu_disp0_rf_we); end
      if (idu_rtu_disp0_dst_lreg !== 5'd1)      begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 dst_lreg=%0d 期望 1 (x1)", n_disp, idu_rtu_disp0_dst_lreg); end
      if (idu_rtu_disp0_dst_preg !== PREG_GIVEN)begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 dst_preg=%0d 期望 %0d (RTU 给的号)", n_disp, idu_rtu_disp0_dst_preg, PREG_GIVEN); end
      if (idu_rtu_disp0_chk      !== CHK0)      begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 chk=%h 期望 %h (chk 旁路要原样透传)", n_disp, idu_rtu_disp0_chk, CHK0); end

      // ★ 判据 2: RAT 真的把 **RTU 给的号** 写进去了 (直接看表项, 理由见观察点注释)。
      //   它变成 33 说明 "编号 33 从 rtu_idu_alloc_preg0 一路走到表项" 全线通了。
      if (dbg_rat_x1 === PREG_GIVEN) begin
        if (!saw_rat_write)
          $display("TB-IDU: ✅ RAT 在写 —— 第%0d次派遣时 RAT[x1]=%0d (= RTU 给的号)",
                   n_disp, PREG_GIVEN);
        saw_rat_write = 1'b1;
      end
    end
  end

  // ---- 激励 ----
  initial begin
    ifu_idu_ib_inst0_vld    = 1'b0;
    ifu_idu_ib_inst0_data   = 97'd0;
    ifu_idu_if_inst0_chk    = 25'd0;
    rtu_idu_alloc_preg0_vld = 1'b0;
    rtu_idu_alloc_preg0     = 6'd0;
    n_disp = 0; errs = 0; saw_rat_write = 1'b0;

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // ---- 判据 1: 复位映射 ⓒ (必须在灌任何指令**之前**查 —— 一旦有指令改名,
    //      x1 的表项就被改成它拿到的号了, 复位映射就被覆盖掉了) ----
    if (dbg_rat_x1 !== ARCH_X1) begin
      $display("TB-IDU: ❌ 复位映射没灌进 RAT! 复位释放后 RAT[x1]=%0d, 期望 %0d (x1→p%0d)",
               dbg_rat_x1, ARCH_X1, ARCH_X1);
      errs = errs + 1;
    end
    else
      $display("TB-IDU: ✅ 复位映射在 (复位释放后 RAT[x1]=%0d = x1→p%0d)", ARCH_X1, ARCH_X1);

    // ---- 判据 4: PRF 的 RTU 写口 / 读口 (2026-10-08 新加的 4 读 1 写) ----
    // 不依赖 IDU 流水: 直接按"退休拍写一个物理号、再按号读回来"验通路。
    rtu_csr_rd_we    = 1'b1;
    rtu_csr_rd_addr  = PRF_ADDR;
    rtu_csr_rd_wdata = PRF_DATA;
    @(posedge clk);
    rtu_csr_rd_we    = 1'b0;
    rtu_preg_raddr0  = PRF_ADDR;
    @(posedge clk);
    @(posedge clk);
    if (rtu_preg_rdata0 !== PRF_DATA) begin
      $display("TB-IDU: ❌ PRF 走访存失败: 写入 %h, 读回 %h (地址 %0d)", PRF_DATA, rtu_preg_rdata0, PRF_ADDR);
      errs = errs + 1;
    end
    else
      $display("TB-IDU: ✅ PRF 的 RTU 写/读口通 (p%0d <- %h, 读回一致)", PRF_ADDR, PRF_DATA);

    // ---- 连续灌激励, 验 RAT 在写 ⓐ + 派遣记录 ⓑ ----
    // 灌激励: {taken, npc, pc, inst}
    ifu_idu_ib_inst0_data   = {1'b0, PC0 + 32'd4, PC0, INST_ADDI};
    ifu_idu_if_inst0_chk    = CHK0;
    rtu_idu_alloc_preg0     = PREG_GIVEN[5:0];
    rtu_idu_alloc_preg0_vld = 1'b1;
    ifu_idu_ib_inst0_vld    = 1'b1;
    repeat (200) @(posedge clk);
    ifu_idu_ib_inst0_vld    = 1'b0;
    rtu_idu_alloc_preg0_vld = 1'b0;
    repeat (5) @(posedge clk);

    if (^idu_accept_num === 1'bx)
      $display("TB-IDU: 注意 — idu_accept_num 含 X");
    else if (idu_accept_num === 2'b10)
      $display("TB-IDU: 警告 — idu_accept_num = 2 是不可达编码 (见 ct_idu_top.sv:180)");

    if (n_disp < 2) begin
      $display("TB-IDU: FAIL — 只观测到 %0d 次派遣, 定向判据没跑到 (期望 >= 2)", n_disp);
      $fatal(1, "stimulus did not reach dispatch");
    end
    if (errs != 0) begin
      $display("TB-IDU: FAIL — %0d 条判据不过", errs);
      $fatal(1, "checks failed");
    end
    if (!saw_rat_write) begin
      $display("TB-IDU: FAIL — 200 拍里从没读到 old_preg=%0d ⇒ **改名表没在写** (表项时钟没通?)", PREG_GIVEN);
      $fatal(1, "RAT write never observed");
    end
    $display("=== IDU smoke: PASS (%0d 次派遣, RAT 在读写在转, 派遣记录对得上) ===", n_disp);
    $finish;
  end

  // 超时保护: 没人推进就报错退出, 而不是挂死
  initial begin
    repeat (5000) @(posedge clk);
    $display("TB-IDU: FAIL — 超时");
    $fatal(1, "timeout");
  end

endmodule
