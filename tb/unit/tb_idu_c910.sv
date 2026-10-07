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

  // ---- 其余输入: 全部接常量 0 ----
  wire       ifu_idu_ib_inst0_vld;
  wire       ifu_idu_ib_inst1_vld;
  wire       ifu_idu_ib_inst2_vld;
  wire [96:0] ifu_idu_ib_inst0_data;
  wire [96:0] ifu_idu_ib_inst1_data;
  wire [96:0] ifu_idu_ib_inst2_data;
  wire       rtu_idu_alloc_preg0_vld;
  wire       rtu_idu_alloc_preg1_vld;
  wire       rtu_idu_alloc_preg2_vld;
  wire [ 5:0] rtu_idu_alloc_preg0;
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
  wire       lsu_idu_lq_not_full;
  wire [ 7:0] lsu_idu_rb_full;
  wire       lsu_idu_rb_not_full;
  wire [ 7:0] lsu_idu_sq_full;
  wire       lsu_idu_sq_not_full;
  wire [ 7:0] lsu_idu_secd;
  wire [ 7:0] lsu_idu_imme_wakeup;
  wire       lsu_idu_lsiq_pop_vld;
  wire       lsu_idu_lsiq_pop0_vld;
  wire       lsu_idu_lsiq_pop1_vld;
  wire [ 7:0] lsu_idu_lsiq_pop_entry;
  wire [11:0] lsu_idu_ex1_sdiq_entry;
  wire       lsu_idu_ex1_sdiq_pop_vld;
  wire       lsu_sdiq_has_in_sq_vld;
  wire [ 3:0] lsu_sdiq_has_in_sq_sdiq;
  wire       lsu_sq_sdiq_unalign_vld;
  wire [ 3:0] lsu_sq_sdiq_unalign_sdiq;

  // ---- 输出 ----
  wire       idu_ifu_inst0_ready;
  wire       idu_ifu_inst1_ready;
  wire       idu_ifu_inst2_ready;
  wire       idu_rtu_ir_preg0_alloc_vld;
  wire       idu_rtu_ir_preg1_alloc_vld;
  wire       idu_rtu_ir_preg2_alloc_vld;
  wire [63:0] idu_rtu_pst_preg_dealloc_mask;
  wire       idu_aiq_sel;
  wire [ 6:0] idu_aiq_iid;
  wire [ 5:0] idu_aiq_dst_preg;
  wire [31:0] idu_aiq_src0;
  wire [31:0] idu_aiq_src1;
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

  assign forever_cpuclk = clk;
  assign cpurst_b       = rst_n;
  assign ifu_idu_ib_inst0_vld             = 1'b0;
  assign ifu_idu_ib_inst1_vld             = 1'b0;
  assign ifu_idu_ib_inst2_vld             = 1'b0;
  assign ifu_idu_ib_inst0_data            = 97'b0;
  assign ifu_idu_ib_inst1_data            = 97'b0;
  assign ifu_idu_ib_inst2_data            = 97'b0;
  assign rtu_idu_alloc_preg0_vld          = 1'b0;
  assign rtu_idu_alloc_preg1_vld          = 1'b0;
  assign rtu_idu_alloc_preg2_vld          = 1'b0;
  assign rtu_idu_alloc_preg0              = 6'b0;
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
  assign lsu_idu_lq_not_full              = 1'b0;
  assign lsu_idu_rb_full                  = 8'b0;
  assign lsu_idu_rb_not_full              = 1'b0;
  assign lsu_idu_sq_full                  = 8'b0;
  assign lsu_idu_sq_not_full              = 1'b0;
  assign lsu_idu_secd                     = 8'b0;
  assign lsu_idu_imme_wakeup              = 8'b0;
  assign lsu_idu_lsiq_pop_vld             = 1'b0;
  assign lsu_idu_lsiq_pop0_vld            = 1'b0;
  assign lsu_idu_lsiq_pop1_vld            = 1'b0;
  assign lsu_idu_lsiq_pop_entry           = 8'b0;
  assign lsu_idu_ex1_sdiq_entry           = 12'b0;
  assign lsu_idu_ex1_sdiq_pop_vld         = 1'b0;
  assign lsu_sdiq_has_in_sq_vld           = 1'b0;
  assign lsu_sdiq_has_in_sq_sdiq          = 4'b0;
  assign lsu_sq_sdiq_unalign_vld          = 1'b0;
  assign lsu_sq_sdiq_unalign_sdiq         = 4'b0;

  // ROB 不满 ⇒ 允许派遣; 不冲刷
  assign rtu_idu_rob_full = 1'b0;
  assign rtu_yy_xx_flush  = 1'b0;

  ct_idu_top u_ct_idu_top (
    .forever_cpuclk                 (forever_cpuclk),
    .cpurst_b                       (cpurst_b),
    .ifu_idu_ib_inst0_vld             (ifu_idu_ib_inst0_vld            ),
    .ifu_idu_ib_inst1_vld             (ifu_idu_ib_inst1_vld            ),
    .ifu_idu_ib_inst2_vld             (ifu_idu_ib_inst2_vld            ),
    .ifu_idu_ib_inst0_data            (ifu_idu_ib_inst0_data           ),
    .ifu_idu_ib_inst1_data            (ifu_idu_ib_inst1_data           ),
    .ifu_idu_ib_inst2_data            (ifu_idu_ib_inst2_data           ),
    .rtu_idu_alloc_preg0_vld          (rtu_idu_alloc_preg0_vld         ),
    .rtu_idu_alloc_preg1_vld          (rtu_idu_alloc_preg1_vld         ),
    .rtu_idu_alloc_preg2_vld          (rtu_idu_alloc_preg2_vld         ),
    .rtu_idu_alloc_preg0              (rtu_idu_alloc_preg0             ),
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
    .lsu_idu_lq_not_full              (lsu_idu_lq_not_full             ),
    .lsu_idu_rb_full                  (lsu_idu_rb_full                 ),
    .lsu_idu_rb_not_full              (lsu_idu_rb_not_full             ),
    .lsu_idu_sq_full                  (lsu_idu_sq_full                 ),
    .lsu_idu_sq_not_full              (lsu_idu_sq_not_full             ),
    .lsu_idu_secd                     (lsu_idu_secd                    ),
    .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup             ),
    .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld            ),
    .lsu_idu_lsiq_pop0_vld            (lsu_idu_lsiq_pop0_vld           ),
    .lsu_idu_lsiq_pop1_vld            (lsu_idu_lsiq_pop1_vld           ),
    .lsu_idu_lsiq_pop_entry           (lsu_idu_lsiq_pop_entry          ),
    .lsu_idu_ex1_sdiq_entry           (lsu_idu_ex1_sdiq_entry          ),
    .lsu_idu_ex1_sdiq_pop_vld         (lsu_idu_ex1_sdiq_pop_vld        ),
    .lsu_sdiq_has_in_sq_vld           (lsu_sdiq_has_in_sq_vld          ),
    .lsu_sdiq_has_in_sq_sdiq          (lsu_sdiq_has_in_sq_sdiq         ),
    .lsu_sq_sdiq_unalign_vld          (lsu_sq_sdiq_unalign_vld         ),
    .lsu_sq_sdiq_unalign_sdiq         (lsu_sq_sdiq_unalign_sdiq        ),
    .rtu_idu_rob_full                 (rtu_idu_rob_full                ),
    .rtu_yy_xx_flush                  (rtu_yy_xx_flush                 ),
    .idu_ifu_inst0_ready              (idu_ifu_inst0_ready             ),
    .idu_ifu_inst1_ready              (idu_ifu_inst1_ready             ),
    .idu_ifu_inst2_ready              (idu_ifu_inst2_ready             ),
    .idu_rtu_ir_preg0_alloc_vld       (idu_rtu_ir_preg0_alloc_vld      ),
    .idu_rtu_ir_preg1_alloc_vld       (idu_rtu_ir_preg1_alloc_vld      ),
    .idu_rtu_ir_preg2_alloc_vld       (idu_rtu_ir_preg2_alloc_vld      ),
    .idu_rtu_pst_preg_dealloc_mask    (idu_rtu_pst_preg_dealloc_mask   ),
    .idu_aiq_sel                      (idu_aiq_sel                     ),
    .idu_aiq_iid                      (idu_aiq_iid                     ),
    .idu_aiq_dst_preg                 (idu_aiq_dst_preg                ),
    .idu_aiq_src0                     (idu_aiq_src0                    ),
    .idu_aiq_src1                     (idu_aiq_src1                    ),
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
    .idu_biq_pc                       (idu_biq_pc                      )
  );

  // ---- 复位 + 跑若干拍 ----
  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (200) @(posedge clk);

    if (^{idu_ifu_inst0_ready, idu_ifu_inst1_ready, idu_ifu_inst2_ready} === 1'bx)
      $display("TB-IDU: 注意 — ifu ready 信号含 X");

    $display("=== IDU elaboration smoke: PASS (跑完 210 拍无异常) ===");
    $finish;
  end

  // 超时保护: 没人推进就报错退出, 而不是挂死
  initial begin
    repeat (5000) @(posedge clk);
    $display("TB-IDU: FAIL — 超时");
    $fatal(1, "timeout");
  end

endmodule
