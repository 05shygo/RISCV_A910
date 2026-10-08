`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// RTU_subsys —— **RTU 与它所有对端的连线**
//
// ⚠️ 本文件由 `scripts/gen_rtu_top.py` **生成**, 不要手改 ——
//    改端口/改接法请改那个脚本再重跑 (`python3 scripts/gen_rtu_top.py`)。
//    生成的理由: 三个模块加起来 270+ 个端口, 手抄必错; 而本工程的端口命名
//    约定是**同名即同线**, 所以'按名字接 + 一张例外表'更可靠 ——
//    所有不按名字接的地方都集中在脚本的 EXCEPTIONS 里, 一眼能看完。
// ---------------------------------------------------------------------------
// 【范围】(用户 2026-10-09 定)
//   * 属于本层: **RTU 的每一条边**
//       - RTU↔IDU、RTU↔LSU: 全部接死 (经 `RTU_idu_lsu_adapter` + 几根直连)
//       - RTU↔IFU / CSR / PRF / 完成口 / difftest: 引出成端口 ——
//         那些模块不在本层里, 但**接口是我们的责任**
//   * 不属于本层: 其余模块**彼此之间**的连线
//       - IFU↔IDU 的取指握手 (`ifu_idu_*` / `idu_accept_num` / chk)
//       - IDU↔执行单元的发射口 (`idu_aiq_*` / `idu_biq_*` / `idu_mult_*` …)
//       - LSU↔总线 (`rb_biu_*` / `wmb_biu_*` / `vb_biu_*` / `biu_lsu_*` …)
//     这些原样引出去。
//
// 【配置】按 **PREG=64** 使用 (交付的 C910 IDU 的 PRF 是 64 项 / 6 位寻址)。
//   64 档下 RTU 的 7 位物理号**最高位恒 0** ⇒ 与 IDU 的 6 位口直接相接就对
//   (Verilog 在端口连接处隐式截掉的那一位正好是 0, 这是**有意的**)。
//   适配层里有 generate 守卫, 拿 96 档编会在 elaborate 期直接失败。
// ---------------------------------------------------------------------------

module RTU_subsys (
  input  wire beu_redirect_vld                      ,
  input  wire [3:0] biu_lsu_b_id                          ,
  input  wire [1:0] biu_lsu_b_resp                        ,
  input  wire biu_lsu_b_vld                         ,
  input  wire [127:0] biu_lsu_r_data                        ,
  input  wire [3:0] biu_lsu_r_id                          ,
  input  wire biu_lsu_r_last                        ,
  input  wire [1:0] biu_lsu_r_resp                        ,
  input  wire biu_lsu_r_vld                         ,
  input  wire bus_arb_rb_ar_grnt                    ,
  input  wire bus_arb_rb_ar_sel                     ,
  input  wire bus_arb_vb_aw_grnt                    ,
  input  wire bus_arb_vb_w_grnt                     ,
  input  wire bus_arb_wmb_aw_grnt                   ,
  input  wire bus_arb_wmb_w_grnt                    ,
  input  wire [6:0] cmplt_iid0                            ,
  input  wire [6:0] cmplt_iid1                            ,
  input  wire [6:0] cmplt_iid2                            ,
  input  wire [6:0] cmplt_iid3                            ,
  input  wire [6:0] cmplt_iid4                            ,
  input  wire cmplt_vld0                            ,
  input  wire cmplt_vld1                            ,
  input  wire cmplt_vld2                            ,
  input  wire cmplt_vld3                            ,
  input  wire cmplt_vld4                            ,
  input  wire cpu_clk                               ,
  input  wire cpu_rst                               ,
  input  wire [31:0] csr_mepc                              ,
  input  wire [31:0] csr_rdata                             ,
  input  wire [31:0] csr_trap_vector                       ,
  output wire dbg_commit_ena0                       ,
  output wire dbg_commit_ena1                       ,
  output wire dbg_commit_ena2                       ,
  output wire [31:0] dbg_commit_pc0                        ,
  output wire [31:0] dbg_commit_pc1                        ,
  output wire [31:0] dbg_commit_pc2                        ,
  output wire [4:0] dbg_commit_reg0                       ,
  output wire [4:0] dbg_commit_reg1                       ,
  output wire [4:0] dbg_commit_reg2                       ,
  output wire [31:0] dbg_commit_value0                     ,
  output wire [31:0] dbg_commit_value1                     ,
  output wire [31:0] dbg_commit_value2                     ,
  output wire dbg_commit_vld0                       ,
  output wire dbg_commit_vld1                       ,
  output wire dbg_commit_vld2                       ,
  input  wire forever_cpuclk                        ,
  output wire [1:0] idu_accept_num                        ,
  output wire [5:0] idu_aiq_dst_preg                      ,
  output wire [6:0] idu_aiq_iid                           ,
  output wire idu_aiq_illegal                       ,
  output wire [31:0] idu_aiq_pc                            ,
  output wire [12:0] idu_aiq_rslt_sel                      ,
  output wire idu_aiq_sel                           ,
  output wire [31:0] idu_aiq_src0                          ,
  output wire [31:0] idu_aiq_src1                          ,
  output wire [31:0] idu_biq_br_imme                       ,
  output wire [24:0] idu_biq_chk                           ,
  output wire [5:0] idu_biq_dst_preg                      ,
  output wire idu_biq_dst_vld                       ,
  output wire [6:0] idu_biq_iid                           ,
  output wire [31:0] idu_biq_npc                           ,
  output wire [31:0] idu_biq_pc                            ,
  output wire [7:0] idu_biq_rslt_sel                      ,
  output wire idu_biq_sel                           ,
  output wire [31:0] idu_biq_src0                          ,
  output wire [31:0] idu_biq_src1                          ,
  output wire idu_biq_taken                         ,
  output wire [5:0] idu_div_dst_preg                      ,
  output wire idu_div_dst_vld                       ,
  output wire [6:0] idu_div_iid                           ,
  output wire [3:0] idu_div_rslt_sel                      ,
  output wire idu_div_sel                           ,
  output wire [31:0] idu_div_src0                          ,
  output wire [31:0] idu_div_src1                          ,
  input  wire [31:0] idu_lsu_ld_src                        ,
  output wire [5:0] idu_lsu_st_preg                       ,
  output wire [5:0] idu_mult_dst_preg                     ,
  output wire [6:0] idu_mult_iid                          ,
  output wire [3:0] idu_mult_rslt_sel                     ,
  output wire idu_mult_sel                          ,
  output wire [31:0] idu_mult_src0                         ,
  output wire [31:0] idu_mult_src1                         ,
  input  wire [96:0] ifu_idu_ib_inst0_data                 ,
  input  wire ifu_idu_ib_inst0_vld                  ,
  input  wire [96:0] ifu_idu_ib_inst1_data                 ,
  input  wire ifu_idu_ib_inst1_vld                  ,
  input  wire [96:0] ifu_idu_ib_inst2_data                 ,
  input  wire ifu_idu_ib_inst2_vld                  ,
  input  wire [24:0] ifu_idu_if_inst0_chk                  ,
  input  wire [24:0] ifu_idu_if_inst1_chk                  ,
  input  wire [24:0] ifu_idu_if_inst2_chk                  ,
  input  wire int_pending                           ,
  input  wire [31:0] iu_idu_ex2_pipe0_wb_preg_data         ,
  input  wire [5:0] iu_idu_ex2_pipe0_wb_preg_dupx         ,
  input  wire [63:0] iu_idu_ex2_pipe0_wb_preg_expand       ,
  input  wire iu_idu_ex2_pipe0_wb_preg_vld          ,
  input  wire iu_idu_ex2_pipe0_wb_preg_vld_dupx     ,
  input  wire [31:0] iu_idu_ex2_pipe1_wb_preg_data         ,
  input  wire [5:0] iu_idu_ex2_pipe1_wb_preg_dupx         ,
  input  wire [63:0] iu_idu_ex2_pipe1_wb_preg_expand       ,
  input  wire iu_idu_ex2_pipe1_wb_preg_vld          ,
  input  wire iu_idu_ex2_pipe1_wb_preg_vld_dupx     ,
  output wire [7:0] lfb_depd_wakeup                       ,
  input  wire [7:0] lsu_idu_lsiq_pop_entry                ,
  output wire [5:0] lsu_idu_wb_pipe3_wb_preg              ,
  input  wire [5:0] lsu_idu_wb_pipe3_wb_preg_dupx         ,
  input  wire lsu_idu_wb_pipe3_wb_preg_vld_dupx     ,
  output wire [63:0] lsu_rtu_wb_pipe3_wb_preg_expand       ,
  output wire lsu_rtu_wb_pipe3_wb_preg_vld          ,
  input  wire [3:0] lsu_sdiq_has_in_sq_sdiq               ,
  input  wire lsu_sdiq_has_in_sq_vld                ,
  input  wire md_unit_stall                         ,
  input  wire [4:0] other_expt_cause                      ,
  input  wire [6:0] other_expt_iid                        ,
  input  wire [31:0] other_expt_tval                       ,
  input  wire other_expt_vld                        ,
  input  wire [31:0] preg_rdata0                           ,
  input  wire [31:0] preg_rdata1                           ,
  input  wire [31:0] preg_rdata2                           ,
  output wire [31:0] rb_biu_ar_addr                        ,
  output wire [1:0] rb_biu_ar_bar                         ,
  output wire [1:0] rb_biu_ar_burst                       ,
  output wire [3:0] rb_biu_ar_cache                       ,
  output wire [1:0] rb_biu_ar_domain                      ,
  output wire [3:0] rb_biu_ar_id                          ,
  output wire [1:0] rb_biu_ar_len                         ,
  output wire rb_biu_ar_lock                        ,
  output wire [2:0] rb_biu_ar_prot                        ,
  output wire rb_biu_ar_req                         ,
  output wire [2:0] rb_biu_ar_size                        ,
  output wire [3:0] rb_biu_ar_snoop                       ,
  output wire rb_biu_ar_user                        ,
  input  wire [6:0] resolve_iid                           ,
  input  wire resolve_mispred                       ,
  input  wire resolve_taken                         ,
  input  wire [31:0] resolve_target                        ,
  input  wire resolve_vld                           ,
  output wire rtu_beu_flush_chgflw_mask             ,
  output wire [6:0] rtu_beu_retire_iid                    ,
  output wire rtu_core_redirect                     ,
  output wire [11:0] rtu_csr_addr                          ,
  output wire [31:0] rtu_csr_wdata                         ,
  output wire rtu_csr_we                            ,
  output wire rtu_disp_vld0                         ,
  output wire rtu_disp_vld1                         ,
  output wire rtu_disp_vld2                         ,
  output wire [31:0] rtu_ifu_chgflw_pc                     ,
  output wire rtu_ifu_chgflw_vld                    ,
  output wire rtu_ifu_flush                         ,
  output wire [24:0] rtu_ifu_train_chk                     ,
  output wire rtu_ifu_train_is_cond                 ,
  output wire rtu_ifu_train_is_jal                  ,
  output wire rtu_ifu_train_is_jalr                 ,
  output wire [31:0] rtu_ifu_train_pc                      ,
  output wire rtu_ifu_train_taken                   ,
  output wire [31:0] rtu_ifu_train_target                  ,
  output wire rtu_ifu_train_vld                     ,
  output wire rtu_mret_vld                          ,
  output wire [31:0] rtu_preg_rdata0                       ,
  output wire [31:0] rtu_preg_rdata1                       ,
  output wire [31:0] rtu_preg_rdata2                       ,
  output wire [6:0] rtu_ren_free_preg0                    ,
  output wire [6:0] rtu_ren_free_preg1                    ,
  output wire [6:0] rtu_ren_free_preg2                    ,
  output wire rtu_ren_free_vld0                     ,
  output wire rtu_ren_free_vld1                     ,
  output wire rtu_ren_free_vld2                     ,
  output wire rtu_ren_recover_vld                   ,
  output wire [1:0] rtu_retire_cnt                        ,
  output wire [2:0] rtu_store_sq_id0                      ,
  output wire [2:0] rtu_store_sq_id1                      ,
  output wire [2:0] rtu_store_sq_id2                      ,
  output wire rtu_store_vld0                        ,
  output wire rtu_store_vld1                        ,
  output wire rtu_store_vld2                        ,
  output wire [4:0] rtu_trap_cause                        ,
  output wire [31:0] rtu_trap_epc                          ,
  output wire [31:0] rtu_trap_tval                         ,
  output wire rtu_trap_vld                          ,
  output wire [7:0] sq_data_depd_wakeup                   ,
  output wire [7:0] sq_global_depd_wakeup                 ,
  output wire [31:0] vb_biu_aw_addr                        ,
  output wire [1:0] vb_biu_aw_burst                       ,
  output wire [3:0] vb_biu_aw_cache                       ,
  output wire [3:0] vb_biu_aw_id                          ,
  output wire [1:0] vb_biu_aw_len                         ,
  output wire vb_biu_aw_lock                        ,
  output wire [2:0] vb_biu_aw_prot                        ,
  output wire vb_biu_aw_req                         ,
  output wire [2:0] vb_biu_aw_size                        ,
  output wire [127:0] vb_biu_w_data                         ,
  output wire [3:0] vb_biu_w_id                           ,
  output wire vb_biu_w_last                         ,
  output wire vb_biu_w_req                          ,
  output wire [15:0] vb_biu_w_strb                         ,
  output wire vb_biu_w_vld                          ,
  output wire [31:0] wmb_biu_aw_addr                       ,
  output wire [1:0] wmb_biu_aw_bar                        ,
  output wire [1:0] wmb_biu_aw_burst                      ,
  output wire [3:0] wmb_biu_aw_cache                      ,
  output wire [1:0] wmb_biu_aw_domain                     ,
  output wire [3:0] wmb_biu_aw_id                         ,
  output wire [1:0] wmb_biu_aw_len                        ,
  output wire wmb_biu_aw_lock                       ,
  output wire [2:0] wmb_biu_aw_prot                       ,
  output wire wmb_biu_aw_req                        ,
  output wire [2:0] wmb_biu_aw_size                       ,
  output wire [2:0] wmb_biu_aw_snoop                      ,
  output wire wmb_biu_aw_user                       ,
  output wire [127:0] wmb_biu_w_data                        ,
  output wire [3:0] wmb_biu_w_id                          ,
  output wire wmb_biu_w_req                         ,
  output wire [15:0] wmb_biu_w_strb                        ,
  output wire wmb_biu_w_vld                         
);

    // ============================================================
    //  内部连线 (两侧模块之间, 不出本层)
    // ============================================================
    wire [6:0] cmplt_iid5                            ;   // 内部
    wire [6:0] cmplt_iid6                            ;   // 内部
    wire cmplt_vld5                            ;   // 内部
    wire cmplt_vld6                            ;   // 内部
    wire cpurst_b                              ;   // 内部
    wire [24:0] disp0_chk                             ;   // 内部
    wire [11:0] disp0_csr_addr                        ;   // 内部
    wire [4:0] disp0_csr_imm                         ;   // 内部
    wire [2:0] disp0_csr_op                          ;   // 内部
    wire [4:0] disp0_dst_lreg                        ;   // 内部
    wire [6:0] disp0_dst_preg                        ;   // 内部
    wire [6:0] disp0_flags                           ;   // 内部
    wire [6:0] disp0_old_preg                        ;   // 内部
    wire [31:0] disp0_pc                              ;   // 内部
    wire disp0_rf_we                           ;   // 内部
    wire [2:0] disp0_sq_id                           ;   // 内部
    wire [6:0] disp0_src1_preg                       ;   // 内部
    wire disp0_vld                             ;   // 内部
    wire [24:0] disp1_chk                             ;   // 内部
    wire [11:0] disp1_csr_addr                        ;   // 内部
    wire [4:0] disp1_csr_imm                         ;   // 内部
    wire [2:0] disp1_csr_op                          ;   // 内部
    wire [4:0] disp1_dst_lreg                        ;   // 内部
    wire [6:0] disp1_dst_preg                        ;   // 内部
    wire [6:0] disp1_flags                           ;   // 内部
    wire [6:0] disp1_old_preg                        ;   // 内部
    wire [31:0] disp1_pc                              ;   // 内部
    wire disp1_rf_we                           ;   // 内部
    wire [2:0] disp1_sq_id                           ;   // 内部
    wire [6:0] disp1_src1_preg                       ;   // 内部
    wire disp1_vld                             ;   // 内部
    wire [24:0] disp2_chk                             ;   // 内部
    wire [11:0] disp2_csr_addr                        ;   // 内部
    wire [4:0] disp2_csr_imm                         ;   // 内部
    wire [2:0] disp2_csr_op                          ;   // 内部
    wire [4:0] disp2_dst_lreg                        ;   // 内部
    wire [6:0] disp2_dst_preg                        ;   // 内部
    wire [6:0] disp2_flags                           ;   // 内部
    wire [6:0] disp2_old_preg                        ;   // 内部
    wire [31:0] disp2_pc                              ;   // 内部
    wire disp2_rf_we                           ;   // 内部
    wire [2:0] disp2_sq_id                           ;   // 内部
    wire [6:0] disp2_src1_preg                       ;   // 内部
    wire disp2_vld                             ;   // 内部
    wire [4:0] expt_cause                            ;   // 内部
    wire [6:0] expt_iid                              ;   // 内部
    wire [31:0] expt_tval                             ;   // 内部
    wire expt_vld                              ;   // 内部
    wire [6:0] idu_lsu_ld_iid                        ;   // 内部
    wire [1:0] idu_lsu_ld_inst_size                  ;   // 内部
    wire [7:0] idu_lsu_ld_lch_entry                  ;   // 内部
    wire [11:0] idu_lsu_ld_offset                     ;   // 内部
    wire [12:0] idu_lsu_ld_offset_plus                ;   // 内部
    wire idu_lsu_ld_oldest                     ;   // 内部
    wire [5:0] idu_lsu_ld_preg                       ;   // 内部
    wire idu_lsu_ld_sel                        ;   // 内部
    wire idu_lsu_ld_sign_extend                ;   // 内部
    wire [31:0] idu_lsu_ld_src0                       ;   // 内部
    wire idu_lsu_ld_unalign_2nd                ;   // 内部
    wire [3:0] idu_lsu_rf_pipe5_sdiq_entry           ;   // 内部
    wire [31:0] idu_lsu_rf_pipe5_src0                 ;   // 内部
    wire idu_lsu_sdiq_sel                      ;   // 内部
    wire [6:0] idu_lsu_st_iid                        ;   // 内部
    wire [1:0] idu_lsu_st_inst_size                  ;   // 内部
    wire [7:0] idu_lsu_st_lch_entry                  ;   // 内部
    wire [11:0] idu_lsu_st_offset                     ;   // 内部
    wire [12:0] idu_lsu_st_offset_plus                ;   // 内部
    wire idu_lsu_st_oldest                     ;   // 内部
    wire [3:0] idu_lsu_st_sdiq_entry                 ;   // 内部
    wire idu_lsu_st_sel                        ;   // 内部
    wire [31:0] idu_lsu_st_src0                       ;   // 内部
    wire idu_lsu_st_unalign_2nd                ;   // 内部
    wire [24:0] idu_rtu_disp0_chk                     ;   // 内部
    wire [11:0] idu_rtu_disp0_csr_addr                ;   // 内部
    wire [4:0] idu_rtu_disp0_csr_imm                 ;   // 内部
    wire [2:0] idu_rtu_disp0_csr_op                  ;   // 内部
    wire [4:0] idu_rtu_disp0_dst_lreg                ;   // 内部
    wire [6:0] idu_rtu_disp0_dst_preg                ;   // 内部
    wire [6:0] idu_rtu_disp0_flags                   ;   // 内部
    wire [6:0] idu_rtu_disp0_old_preg                ;   // 内部
    wire [31:0] idu_rtu_disp0_pc                      ;   // 内部
    wire idu_rtu_disp0_rf_we                   ;   // 内部
    wire [6:0] idu_rtu_disp0_src1_preg               ;   // 内部
    wire idu_rtu_disp0_vld                     ;   // 内部
    wire [24:0] idu_rtu_disp1_chk                     ;   // 内部
    wire [11:0] idu_rtu_disp1_csr_addr                ;   // 内部
    wire [4:0] idu_rtu_disp1_csr_imm                 ;   // 内部
    wire [2:0] idu_rtu_disp1_csr_op                  ;   // 内部
    wire [4:0] idu_rtu_disp1_dst_lreg                ;   // 内部
    wire [6:0] idu_rtu_disp1_dst_preg                ;   // 内部
    wire [6:0] idu_rtu_disp1_flags                   ;   // 内部
    wire [6:0] idu_rtu_disp1_old_preg                ;   // 内部
    wire [31:0] idu_rtu_disp1_pc                      ;   // 内部
    wire idu_rtu_disp1_rf_we                   ;   // 内部
    wire [6:0] idu_rtu_disp1_src1_preg               ;   // 内部
    wire idu_rtu_disp1_vld                     ;   // 内部
    wire [24:0] idu_rtu_disp2_chk                     ;   // 内部
    wire [11:0] idu_rtu_disp2_csr_addr                ;   // 内部
    wire [4:0] idu_rtu_disp2_csr_imm                 ;   // 内部
    wire [2:0] idu_rtu_disp2_csr_op                  ;   // 内部
    wire [4:0] idu_rtu_disp2_dst_lreg                ;   // 内部
    wire [6:0] idu_rtu_disp2_dst_preg                ;   // 内部
    wire [6:0] idu_rtu_disp2_flags                   ;   // 内部
    wire [6:0] idu_rtu_disp2_old_preg                ;   // 内部
    wire [31:0] idu_rtu_disp2_pc                      ;   // 内部
    wire idu_rtu_disp2_rf_we                   ;   // 内部
    wire [6:0] idu_rtu_disp2_src1_preg               ;   // 内部
    wire idu_rtu_disp2_vld                     ;   // 内部
    wire idu_rtu_ir_preg0_alloc_vld            ;   // 内部
    wire idu_rtu_ir_preg1_alloc_vld            ;   // 内部
    wire idu_rtu_ir_preg2_alloc_vld            ;   // 内部
    wire [63:0] idu_rtu_pst_preg_dealloc_mask         ;   // 内部
    wire [3:0] lsu_idu_has_in_sq                     ;   // 内部
    wire [7:0] lsu_idu_imme_wakeup                   ;   // 内部
    wire [7:0] lsu_idu_lq_full                       ;   // 内部
    wire lsu_idu_lq_not_full                   ;   // 内部
    wire lsu_idu_lsiq_pop0_vld                 ;   // 内部
    wire lsu_idu_lsiq_pop1_vld                 ;   // 内部
    wire lsu_idu_lsiq_pop_vld                  ;   // 内部
    wire [7:0] lsu_idu_pop_entry                     ;   // 内部
    wire [7:0] lsu_idu_rb_full                       ;   // 内部
    wire lsu_idu_rb_not_full                   ;   // 内部
    wire [7:0] lsu_idu_secd                          ;   // 内部
    wire [7:0] lsu_idu_sq_full                       ;   // 内部
    wire lsu_idu_sq_not_full                   ;   // 内部
    wire [31:0] lsu_idu_wb_pipe3_wb_preg_data         ;   // 内部
    wire [63:0] lsu_idu_wb_pipe3_wb_preg_expand       ;   // 内部
    wire lsu_idu_wb_pipe3_wb_preg_vld          ;   // 内部
    wire [6:0] lsu_replay_iid                        ;   // 内部
    wire lsu_replay_vld                        ;   // 内部
    wire lsu_rtu_wb_pipe3_cmplt                ;   // 内部
    wire [31:0] lsu_rtu_wb_pipe3_expt_addr            ;   // 内部
    wire lsu_rtu_wb_pipe3_expt_vld             ;   // 内部
    wire [6:0] lsu_rtu_wb_pipe3_iid                  ;   // 内部
    wire lsu_rtu_wb_pipe4_cmplt                ;   // 内部
    wire [31:0] lsu_rtu_wb_pipe4_expt_addr            ;   // 内部
    wire lsu_rtu_wb_pipe4_expt_vld             ;   // 内部
    wire lsu_rtu_wb_pipe4_flush                ;   // 内部
    wire [6:0] lsu_rtu_wb_pipe4_iid                  ;   // 内部
    wire lsu_rtu_wb_pipe4_spec_fail            ;   // 内部
    wire [63:0] preg_dealloc_mask                     ;   // 内部
    wire [1:0] ren_preg_req                          ;   // 内部
    wire [4:0] ren_preg_req_lreg0                    ;   // 内部
    wire [4:0] ren_preg_req_lreg1                    ;   // 内部
    wire [4:0] ren_preg_req_lreg2                    ;   // 内部
    wire rtu_backend_flush                     ;   // 内部
    wire [6:0] rtu_csr_rd_addr                       ;   // 内部
    wire [31:0] rtu_csr_rd_wdata                      ;   // 内部
    wire rtu_csr_rd_we                         ;   // 内部
    wire [6:0] rtu_csr_src_raddr                     ;   // 内部
    wire [31:0] rtu_csr_src_rdata                     ;   // 内部
    wire [6:0] rtu_disp_iid0                         ;   // 内部
    wire [6:0] rtu_disp_iid1                         ;   // 内部
    wire [6:0] rtu_disp_iid2                         ;   // 内部
    wire rtu_disp_stall                        ;   // 内部
    wire [5:0] rtu_idu_alloc_preg0                   ;   // 内部
    wire rtu_idu_alloc_preg0_vld               ;   // 内部
    wire [5:0] rtu_idu_alloc_preg1                   ;   // 内部
    wire rtu_idu_alloc_preg1_vld               ;   // 内部
    wire [5:0] rtu_idu_alloc_preg2                   ;   // 内部
    wire rtu_idu_alloc_preg2_vld               ;   // 内部
    wire rtu_idu_rob_full                      ;   // 内部
    wire [6:0] rtu_idu_rob_inst0_iid                 ;   // 内部
    wire [6:0] rtu_idu_rob_inst1_iid                 ;   // 内部
    wire [6:0] rtu_idu_rob_inst2_iid                 ;   // 内部
    wire [191:0] rtu_idu_rt_recover_preg               ;   // 内部
    wire rtu_lsu_async_flush                   ;   // 内部
    wire [6:0] rtu_preg_alloc0                       ;   // 内部
    wire [6:0] rtu_preg_alloc1                       ;   // 内部
    wire [6:0] rtu_preg_alloc2                       ;   // 内部
    wire rtu_preg_alloc_vld0                   ;   // 内部
    wire rtu_preg_alloc_vld1                   ;   // 内部
    wire rtu_preg_alloc_vld2                   ;   // 内部
    wire [1:0] rtu_preg_free_cnt                     ;   // 内部
    wire [6:0] rtu_preg_raddr0                       ;   // 内部
    wire [6:0] rtu_preg_raddr1                       ;   // 内部
    wire [6:0] rtu_preg_raddr2                       ;   // 内部
    wire rtu_ren_flush                         ;   // 内部
    wire [223:0] rtu_ren_recover_map                   ;   // 内部
    wire rtu_yy_xx_commit0                     ;   // 内部
    wire [6:0] rtu_yy_xx_commit0_iid                 ;   // 内部
    wire rtu_yy_xx_commit1                     ;   // 内部
    wire [6:0] rtu_yy_xx_commit1_iid                 ;   // 内部
    wire rtu_yy_xx_commit2                     ;   // 内部
    wire [6:0] rtu_yy_xx_commit2_iid                 ;   // 内部
    wire rtu_yy_xx_flush                       ;   // 内部
    wire sq_rdy0                               ;   // 内部
    wire sq_rdy1                               ;   // 内部
    wire sq_rdy2                               ;   // 内部
    wire sq_stall                              ;   // 内部
    wire lsu_sdiq_has_in_sq_any                 = |lsu_idu_has_in_sq;

    // ============================================================
    //  u_rtu : RTU
    // ============================================================
    RTU u_rtu (
    .cpu_clk                            (cpu_clk                           ),
    .cpu_rst                            (cpu_rst                           ),
    .ren_preg_req                       (ren_preg_req                      ),
    .ren_preg_req_lreg0                 (ren_preg_req_lreg0                ),
    .ren_preg_req_lreg1                 (ren_preg_req_lreg1                ),
    .ren_preg_req_lreg2                 (ren_preg_req_lreg2                ),
    .rtu_preg_alloc0                    (rtu_preg_alloc0                   ),
    .rtu_preg_alloc1                    (rtu_preg_alloc1                   ),
    .rtu_preg_alloc2                    (rtu_preg_alloc2                   ),
    .rtu_preg_alloc_vld0                (rtu_preg_alloc_vld0               ),
    .rtu_preg_alloc_vld1                (rtu_preg_alloc_vld1               ),
    .rtu_preg_alloc_vld2                (rtu_preg_alloc_vld2               ),
    .rtu_preg_free_cnt                  (rtu_preg_free_cnt                 ),
    .disp0_vld                          (disp0_vld                         ),
    .disp0_pc                           (disp0_pc                          ),
    .disp0_chk                          (disp0_chk                         ),
    .disp0_dst_lreg                     (disp0_dst_lreg                    ),
    .disp0_rf_we                        (disp0_rf_we                       ),
    .disp0_dst_preg                     (disp0_dst_preg                    ),
    .disp0_old_preg                     (disp0_old_preg                    ),
    .disp0_src1_preg                    (disp0_src1_preg                   ),
    .disp0_csr_addr                     (disp0_csr_addr                    ),
    .disp0_csr_op                       (disp0_csr_op                      ),
    .disp0_csr_imm                      (disp0_csr_imm                     ),
    .disp0_flags                        (disp0_flags                       ),
    .disp0_sq_id                        (disp0_sq_id                       ),
    .disp1_vld                          (disp1_vld                         ),
    .disp1_pc                           (disp1_pc                          ),
    .disp1_chk                          (disp1_chk                         ),
    .disp1_dst_lreg                     (disp1_dst_lreg                    ),
    .disp1_rf_we                        (disp1_rf_we                       ),
    .disp1_dst_preg                     (disp1_dst_preg                    ),
    .disp1_old_preg                     (disp1_old_preg                    ),
    .disp1_src1_preg                    (disp1_src1_preg                   ),
    .disp1_csr_addr                     (disp1_csr_addr                    ),
    .disp1_csr_op                       (disp1_csr_op                      ),
    .disp1_csr_imm                      (disp1_csr_imm                     ),
    .disp1_flags                        (disp1_flags                       ),
    .disp1_sq_id                        (disp1_sq_id                       ),
    .disp2_vld                          (disp2_vld                         ),
    .disp2_pc                           (disp2_pc                          ),
    .disp2_chk                          (disp2_chk                         ),
    .disp2_dst_lreg                     (disp2_dst_lreg                    ),
    .disp2_rf_we                        (disp2_rf_we                       ),
    .disp2_dst_preg                     (disp2_dst_preg                    ),
    .disp2_old_preg                     (disp2_old_preg                    ),
    .disp2_src1_preg                    (disp2_src1_preg                   ),
    .disp2_csr_addr                     (disp2_csr_addr                    ),
    .disp2_csr_op                       (disp2_csr_op                      ),
    .disp2_csr_imm                      (disp2_csr_imm                     ),
    .disp2_flags                        (disp2_flags                       ),
    .disp2_sq_id                        (disp2_sq_id                       ),
    .cmplt_vld0                         (cmplt_vld0                        ),
    .cmplt_iid0                         (cmplt_iid0                        ),
    .cmplt_vld1                         (cmplt_vld1                        ),
    .cmplt_iid1                         (cmplt_iid1                        ),
    .cmplt_vld2                         (cmplt_vld2                        ),
    .cmplt_iid2                         (cmplt_iid2                        ),
    .cmplt_vld3                         (cmplt_vld3                        ),
    .cmplt_iid3                         (cmplt_iid3                        ),
    .cmplt_vld4                         (cmplt_vld4                        ),
    .cmplt_iid4                         (cmplt_iid4                        ),
    .cmplt_vld5                         (cmplt_vld5                        ),
    .cmplt_iid5                         (cmplt_iid5                        ),
    .cmplt_vld6                         (cmplt_vld6                        ),
    .cmplt_iid6                         (cmplt_iid6                        ),
    .resolve_vld                        (resolve_vld                       ),
    .resolve_iid                        (resolve_iid                       ),
    .resolve_taken                      (resolve_taken                     ),
    .resolve_mispred                    (resolve_mispred                   ),
    .resolve_target                     (resolve_target                    ),
    .lsu_replay_vld                     (lsu_replay_vld                    ),
    .lsu_replay_iid                     (lsu_replay_iid                    ),
    .expt_vld                           (expt_vld                          ),
    .expt_iid                           (expt_iid                          ),
    .expt_cause                         (expt_cause                        ),
    .expt_tval                          (expt_tval                         ),
    .sq_rdy0                            (sq_rdy0                           ),
    .sq_rdy1                            (sq_rdy1                           ),
    .sq_rdy2                            (sq_rdy2                           ),
    .sq_stall                           (sq_stall                          ),
    .csr_rdata                          (csr_rdata                         ),
    .int_pending                        (int_pending                       ),
    .preg_dealloc_mask                  (preg_dealloc_mask                 ),
    .beu_redirect_vld                   (beu_redirect_vld                  ),
    .preg_rdata0                        (preg_rdata0                       ),
    .preg_rdata1                        (preg_rdata1                       ),
    .preg_rdata2                        (preg_rdata2                       ),
    .rtu_csr_src_rdata                  (rtu_csr_src_rdata                 ),
    .csr_trap_vector                    (csr_trap_vector                   ),
    .csr_mepc                           (csr_mepc                          ),
    .rtu_ifu_flush                      (rtu_ifu_flush                     ),
    .rtu_ifu_chgflw_vld                 (rtu_ifu_chgflw_vld                ),
    .rtu_ifu_chgflw_pc                  (rtu_ifu_chgflw_pc                 ),
    .rtu_ifu_train_vld                  (rtu_ifu_train_vld                 ),
    .rtu_ifu_train_pc                   (rtu_ifu_train_pc                  ),
    .rtu_ifu_train_target               (rtu_ifu_train_target              ),
    .rtu_ifu_train_chk                  (rtu_ifu_train_chk                 ),
    .rtu_ifu_train_taken                (rtu_ifu_train_taken               ),
    .rtu_ifu_train_is_cond              (rtu_ifu_train_is_cond             ),
    .rtu_ifu_train_is_jal               (rtu_ifu_train_is_jal              ),
    .rtu_ifu_train_is_jalr              (rtu_ifu_train_is_jalr             ),
    .rtu_backend_flush                  (rtu_backend_flush                 ),
    .rtu_core_redirect                  (rtu_core_redirect                 ),
    .rtu_yy_xx_commit0                  (rtu_yy_xx_commit0                 ),
    .rtu_yy_xx_commit1                  (rtu_yy_xx_commit1                 ),
    .rtu_yy_xx_commit2                  (rtu_yy_xx_commit2                 ),
    .rtu_yy_xx_commit0_iid              (rtu_yy_xx_commit0_iid             ),
    .rtu_yy_xx_commit1_iid              (rtu_yy_xx_commit1_iid             ),
    .rtu_yy_xx_commit2_iid              (rtu_yy_xx_commit2_iid             ),
    .rtu_lsu_async_flush                (rtu_lsu_async_flush               ),
    .rtu_beu_retire_iid                 (rtu_beu_retire_iid                ),
    .rtu_beu_flush_chgflw_mask          (rtu_beu_flush_chgflw_mask         ),
    .rtu_disp_stall                     (rtu_disp_stall                    ),
    .rtu_ren_recover_vld                (rtu_ren_recover_vld               ),
    .rtu_ren_recover_map                (rtu_ren_recover_map               ),
    .rtu_ren_flush                      (rtu_ren_flush                     ),
    .rtu_ren_free_preg0                 (rtu_ren_free_preg0                ),
    .rtu_ren_free_preg1                 (rtu_ren_free_preg1                ),
    .rtu_ren_free_preg2                 (rtu_ren_free_preg2                ),
    .rtu_ren_free_vld0                  (rtu_ren_free_vld0                 ),
    .rtu_ren_free_vld1                  (rtu_ren_free_vld1                 ),
    .rtu_ren_free_vld2                  (rtu_ren_free_vld2                 ),
    .rtu_disp_vld0                      (rtu_disp_vld0                     ),
    .rtu_disp_vld1                      (rtu_disp_vld1                     ),
    .rtu_disp_vld2                      (rtu_disp_vld2                     ),
    .rtu_disp_iid0                      (rtu_disp_iid0                     ),
    .rtu_disp_iid1                      (rtu_disp_iid1                     ),
    .rtu_disp_iid2                      (rtu_disp_iid2                     ),
    .rtu_preg_raddr0                    (rtu_preg_raddr0                   ),
    .rtu_preg_raddr1                    (rtu_preg_raddr1                   ),
    .rtu_preg_raddr2                    (rtu_preg_raddr2                   ),
    .rtu_csr_src_raddr                  (rtu_csr_src_raddr                 ),
    .rtu_csr_rd_we                      (rtu_csr_rd_we                     ),
    .rtu_csr_rd_addr                    (rtu_csr_rd_addr                   ),
    .rtu_csr_rd_wdata                   (rtu_csr_rd_wdata                  ),
    .rtu_store_vld0                     (rtu_store_vld0                    ),
    .rtu_store_vld1                     (rtu_store_vld1                    ),
    .rtu_store_vld2                     (rtu_store_vld2                    ),
    .rtu_store_sq_id0                   (rtu_store_sq_id0                  ),
    .rtu_store_sq_id1                   (rtu_store_sq_id1                  ),
    .rtu_store_sq_id2                   (rtu_store_sq_id2                  ),
    .rtu_csr_we                         (rtu_csr_we                        ),
    .rtu_csr_addr                       (rtu_csr_addr                      ),
    .rtu_csr_wdata                      (rtu_csr_wdata                     ),
    .rtu_trap_vld                       (rtu_trap_vld                      ),
    .rtu_mret_vld                       (rtu_mret_vld                      ),
    .rtu_trap_epc                       (rtu_trap_epc                      ),
    .rtu_trap_tval                      (rtu_trap_tval                     ),
    .rtu_trap_cause                     (rtu_trap_cause                    ),
    .rtu_retire_cnt                     (rtu_retire_cnt                    ),
    .dbg_commit_vld0                    (dbg_commit_vld0                   ),
    .dbg_commit_vld1                    (dbg_commit_vld1                   ),
    .dbg_commit_vld2                    (dbg_commit_vld2                   ),
    .dbg_commit_pc0                     (dbg_commit_pc0                    ),
    .dbg_commit_pc1                     (dbg_commit_pc1                    ),
    .dbg_commit_pc2                     (dbg_commit_pc2                    ),
    .dbg_commit_ena0                    (dbg_commit_ena0                   ),
    .dbg_commit_ena1                    (dbg_commit_ena1                   ),
    .dbg_commit_ena2                    (dbg_commit_ena2                   ),
    .dbg_commit_reg0                    (dbg_commit_reg0                   ),
    .dbg_commit_reg1                    (dbg_commit_reg1                   ),
    .dbg_commit_reg2                    (dbg_commit_reg2                   ),
    .dbg_commit_value0                  (dbg_commit_value0                 ),
    .dbg_commit_value1                  (dbg_commit_value1                 ),
    .dbg_commit_value2                  (dbg_commit_value2                 )
    );

    // ============================================================
    //  u_idu : ct_idu_top
    // ============================================================
    ct_idu_top u_idu (
    .forever_cpuclk                     (cpu_clk                           ),
    .cpurst_b                           (cpurst_b                          ),   // 适配层就地反相 (RTU 高有效 / IDU-LSU 低有效)
    .ifu_idu_ib_inst0_vld               (ifu_idu_ib_inst0_vld              ),
    .ifu_idu_ib_inst1_vld               (ifu_idu_ib_inst1_vld              ),
    .ifu_idu_ib_inst2_vld               (ifu_idu_ib_inst2_vld              ),
    .ifu_idu_ib_inst0_data              (ifu_idu_ib_inst0_data             ),
    .ifu_idu_if_inst0_chk               (ifu_idu_if_inst0_chk              ),
    .ifu_idu_ib_inst1_data              (ifu_idu_ib_inst1_data             ),
    .ifu_idu_if_inst1_chk               (ifu_idu_if_inst1_chk              ),
    .ifu_idu_ib_inst2_data              (ifu_idu_ib_inst2_data             ),
    .ifu_idu_if_inst2_chk               (ifu_idu_if_inst2_chk              ),
    .idu_accept_num                     (idu_accept_num                    ),
    .rtu_idu_alloc_preg0_vld            (rtu_idu_alloc_preg0_vld           ),
    .rtu_idu_alloc_preg1_vld            (rtu_idu_alloc_preg1_vld           ),
    .rtu_idu_alloc_preg2_vld            (rtu_idu_alloc_preg2_vld           ),
    .rtu_idu_alloc_preg0                (rtu_idu_alloc_preg0               ),
    .rtu_idu_alloc_preg1                (rtu_idu_alloc_preg1               ),
    .rtu_idu_alloc_preg2                (rtu_idu_alloc_preg2               ),
    .rtu_idu_rob_inst0_iid              (rtu_idu_rob_inst0_iid             ),
    .rtu_idu_rob_inst1_iid              (rtu_idu_rob_inst1_iid             ),
    .rtu_idu_rob_inst2_iid              (rtu_idu_rob_inst2_iid             ),
    .rtu_idu_rob_full                   (rtu_idu_rob_full                  ),
    .rtu_idu_rt_recover_preg            (rtu_idu_rt_recover_preg           ),
    .rtu_yy_xx_flush                    (rtu_yy_xx_flush                   ),
    .idu_rtu_ir_preg0_alloc_vld         (idu_rtu_ir_preg0_alloc_vld        ),
    .idu_rtu_ir_preg1_alloc_vld         (idu_rtu_ir_preg1_alloc_vld        ),
    .idu_rtu_ir_preg2_alloc_vld         (idu_rtu_ir_preg2_alloc_vld        ),
    .idu_rtu_pst_preg_dealloc_mask      (idu_rtu_pst_preg_dealloc_mask     ),
    .iu_idu_ex2_pipe0_wb_preg_dupx      (iu_idu_ex2_pipe0_wb_preg_dupx     ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx  (iu_idu_ex2_pipe0_wb_preg_vld_dupx ),
    .iu_idu_ex2_pipe0_wb_preg_data      (iu_idu_ex2_pipe0_wb_preg_data     ),
    .iu_idu_ex2_pipe0_wb_preg_expand    (iu_idu_ex2_pipe0_wb_preg_expand   ),
    .iu_idu_ex2_pipe0_wb_preg_vld       (iu_idu_ex2_pipe0_wb_preg_vld      ),
    .iu_idu_ex2_pipe1_wb_preg_dupx      (iu_idu_ex2_pipe1_wb_preg_dupx     ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx  (iu_idu_ex2_pipe1_wb_preg_vld_dupx ),
    .iu_idu_ex2_pipe1_wb_preg_data      (iu_idu_ex2_pipe1_wb_preg_data     ),
    .iu_idu_ex2_pipe1_wb_preg_expand    (iu_idu_ex2_pipe1_wb_preg_expand   ),
    .iu_idu_ex2_pipe1_wb_preg_vld       (iu_idu_ex2_pipe1_wb_preg_vld      ),
    .lsu_idu_wb_pipe3_wb_preg_dupx      (lsu_idu_wb_pipe3_wb_preg_dupx     ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx  (lsu_idu_wb_pipe3_wb_preg_vld_dupx ),
    .lsu_idu_wb_pipe3_wb_preg_data      (lsu_idu_wb_pipe3_wb_preg_data     ),
    .lsu_idu_wb_pipe3_wb_preg_expand    (lsu_idu_wb_pipe3_wb_preg_expand   ),
    .lsu_idu_wb_pipe3_wb_preg_vld       (lsu_idu_wb_pipe3_wb_preg_vld      ),
    .lsu_idu_lq_full                    (lsu_idu_lq_full                   ),
    .lsu_idu_lq_not_full                (lsu_idu_lq_not_full               ),
    .lsu_idu_rb_full                    (lsu_idu_rb_full                   ),
    .lsu_idu_rb_not_full                (lsu_idu_rb_not_full               ),
    .lsu_idu_sq_full                    (lsu_idu_sq_full                   ),
    .lsu_idu_sq_not_full                (lsu_idu_sq_not_full               ),
    .lsu_idu_secd                       (lsu_idu_secd                      ),
    .lsu_idu_imme_wakeup                (lsu_idu_imme_wakeup               ),
    .lsu_idu_lsiq_pop_vld               (lsu_idu_lsiq_pop_vld              ),
    .lsu_idu_lsiq_pop0_vld              (lsu_idu_lsiq_pop0_vld             ),
    .lsu_idu_lsiq_pop1_vld              (lsu_idu_lsiq_pop1_vld             ),
    .lsu_idu_lsiq_pop_entry             (lsu_idu_pop_entry                 ),   // 交付侧名字少个 lsiq_, 位宽/语义一致
    .lsu_sdiq_has_in_sq_vld             (lsu_sdiq_has_in_sq_any            ),   // IDU 要 {vld, 独热}, LSU 只给一个带门控的独热
    .lsu_sdiq_has_in_sq_sdiq            (lsu_idu_has_in_sq                 ),
    .idu_aiq_sel                        (idu_aiq_sel                       ),
    .idu_aiq_iid                        (idu_aiq_iid                       ),
    .idu_aiq_dst_preg                   (idu_aiq_dst_preg                  ),
    .idu_aiq_src0                       (idu_aiq_src0                      ),
    .idu_aiq_src1                       (idu_aiq_src1                      ),
    .idu_aiq_pc                         (idu_aiq_pc                        ),
    .idu_aiq_rslt_sel                   (idu_aiq_rslt_sel                  ),
    .idu_aiq_illegal                    (idu_aiq_illegal                   ),
    .idu_mult_sel                       (idu_mult_sel                      ),
    .idu_mult_iid                       (idu_mult_iid                      ),
    .idu_mult_dst_preg                  (idu_mult_dst_preg                 ),
    .idu_mult_src0                      (idu_mult_src0                     ),
    .idu_mult_src1                      (idu_mult_src1                     ),
    .idu_mult_rslt_sel                  (idu_mult_rslt_sel                 ),
    .idu_div_sel                        (idu_div_sel                       ),
    .idu_div_iid                        (idu_div_iid                       ),
    .idu_div_dst_vld                    (idu_div_dst_vld                   ),
    .idu_div_dst_preg                   (idu_div_dst_preg                  ),
    .idu_div_src0                       (idu_div_src0                      ),
    .idu_div_src1                       (idu_div_src1                      ),
    .idu_div_rslt_sel                   (idu_div_rslt_sel                  ),
    .idu_lsu_ld_sel                     (idu_lsu_ld_sel                    ),
    .idu_lsu_ld_iid                     (idu_lsu_ld_iid                    ),
    .idu_lsu_ld_preg                    (idu_lsu_ld_preg                   ),
    .idu_lsu_ld_src0                    (idu_lsu_ld_src0                   ),
    .idu_lsu_ld_offset                  (idu_lsu_ld_offset                 ),
    .idu_lsu_ld_offset_plus             (idu_lsu_ld_offset_plus            ),
    .idu_lsu_ld_sign_extend             (idu_lsu_ld_sign_extend            ),
    .idu_lsu_ld_inst_size               (idu_lsu_ld_inst_size              ),
    .idu_lsu_ld_unalign_2nd             (idu_lsu_ld_unalign_2nd            ),
    .idu_lsu_ld_lch_entry               (idu_lsu_ld_lch_entry              ),
    .idu_lsu_ld_oldest                  (idu_lsu_ld_oldest                 ),
    .idu_lsu_st_sel                     (idu_lsu_st_sel                    ),
    .idu_lsu_st_iid                     (idu_lsu_st_iid                    ),
    //  .idu_lsu_st_preg                    (  ),   // store 不写回, LSU 侧没有对应口
    .idu_lsu_st_src0                    (idu_lsu_st_src0                   ),
    .idu_lsu_st_offset                  (idu_lsu_st_offset                 ),
    .idu_lsu_st_offset_plus             (idu_lsu_st_offset_plus            ),
    .idu_lsu_st_inst_size               (idu_lsu_st_inst_size              ),
    .idu_lsu_st_unalign_2nd             (idu_lsu_st_unalign_2nd            ),
    .idu_lsu_st_lch_entry               (idu_lsu_st_lch_entry              ),
    .idu_lsu_st_oldest                  (idu_lsu_st_oldest                 ),
    .idu_lsu_st_sdiq_entry              (idu_lsu_st_sdiq_entry             ),
    .idu_lsu_sdiq_sel                   (idu_lsu_sdiq_sel                  ),
    .idu_lsu_rf_pipe5_sdiq_entry        (idu_lsu_rf_pipe5_sdiq_entry       ),
    .idu_lsu_rf_pipe5_src0              (idu_lsu_rf_pipe5_src0             ),
    .idu_biq_sel                        (idu_biq_sel                       ),
    .idu_biq_iid                        (idu_biq_iid                       ),
    .idu_biq_src0                       (idu_biq_src0                      ),
    .idu_biq_src1                       (idu_biq_src1                      ),
    .idu_biq_rslt_sel                   (idu_biq_rslt_sel                  ),
    .idu_biq_br_imme                    (idu_biq_br_imme                   ),
    .idu_biq_dst_vld                    (idu_biq_dst_vld                   ),
    .idu_biq_dst_preg                   (idu_biq_dst_preg                  ),
    .idu_biq_taken                      (idu_biq_taken                     ),
    .idu_biq_npc                        (idu_biq_npc                       ),
    .idu_biq_pc                         (idu_biq_pc                        ),
    .idu_biq_chk                        (idu_biq_chk                       ),
    .idu_rtu_disp0_vld                  (idu_rtu_disp0_vld                 ),
    .idu_rtu_disp0_pc                   (idu_rtu_disp0_pc                  ),
    .idu_rtu_disp0_chk                  (idu_rtu_disp0_chk                 ),
    .idu_rtu_disp0_dst_lreg             (idu_rtu_disp0_dst_lreg            ),
    .idu_rtu_disp0_rf_we                (idu_rtu_disp0_rf_we               ),
    .idu_rtu_disp0_dst_preg             (idu_rtu_disp0_dst_preg            ),
    .idu_rtu_disp0_old_preg             (idu_rtu_disp0_old_preg            ),
    .idu_rtu_disp0_src1_preg            (idu_rtu_disp0_src1_preg           ),
    .idu_rtu_disp0_csr_addr             (idu_rtu_disp0_csr_addr            ),
    .idu_rtu_disp0_csr_op               (idu_rtu_disp0_csr_op              ),
    .idu_rtu_disp0_csr_imm              (idu_rtu_disp0_csr_imm             ),
    .idu_rtu_disp0_flags                (idu_rtu_disp0_flags               ),
    .idu_rtu_disp1_vld                  (idu_rtu_disp1_vld                 ),
    .idu_rtu_disp1_pc                   (idu_rtu_disp1_pc                  ),
    .idu_rtu_disp1_chk                  (idu_rtu_disp1_chk                 ),
    .idu_rtu_disp1_dst_lreg             (idu_rtu_disp1_dst_lreg            ),
    .idu_rtu_disp1_rf_we                (idu_rtu_disp1_rf_we               ),
    .idu_rtu_disp1_dst_preg             (idu_rtu_disp1_dst_preg            ),
    .idu_rtu_disp1_old_preg             (idu_rtu_disp1_old_preg            ),
    .idu_rtu_disp1_src1_preg            (idu_rtu_disp1_src1_preg           ),
    .idu_rtu_disp1_csr_addr             (idu_rtu_disp1_csr_addr            ),
    .idu_rtu_disp1_csr_op               (idu_rtu_disp1_csr_op              ),
    .idu_rtu_disp1_csr_imm              (idu_rtu_disp1_csr_imm             ),
    .idu_rtu_disp1_flags                (idu_rtu_disp1_flags               ),
    .idu_rtu_disp2_vld                  (idu_rtu_disp2_vld                 ),
    .idu_rtu_disp2_pc                   (idu_rtu_disp2_pc                  ),
    .idu_rtu_disp2_chk                  (idu_rtu_disp2_chk                 ),
    .idu_rtu_disp2_dst_lreg             (idu_rtu_disp2_dst_lreg            ),
    .idu_rtu_disp2_rf_we                (idu_rtu_disp2_rf_we               ),
    .idu_rtu_disp2_dst_preg             (idu_rtu_disp2_dst_preg            ),
    .idu_rtu_disp2_old_preg             (idu_rtu_disp2_old_preg            ),
    .idu_rtu_disp2_src1_preg            (idu_rtu_disp2_src1_preg           ),
    .idu_rtu_disp2_csr_addr             (idu_rtu_disp2_csr_addr            ),
    .idu_rtu_disp2_csr_op               (idu_rtu_disp2_csr_op              ),
    .idu_rtu_disp2_csr_imm              (idu_rtu_disp2_csr_imm             ),
    .idu_rtu_disp2_flags                (idu_rtu_disp2_flags               ),
    .rtu_preg_raddr0                    (rtu_preg_raddr0                   ),
    .rtu_preg_raddr1                    (rtu_preg_raddr1                   ),
    .rtu_preg_raddr2                    (rtu_preg_raddr2                   ),
    .rtu_csr_src_raddr                  (rtu_csr_src_raddr                 ),
    .rtu_csr_rd_we                      (rtu_csr_rd_we                     ),
    .rtu_csr_rd_addr                    (rtu_csr_rd_addr                   ),
    .rtu_csr_rd_wdata                   (rtu_csr_rd_wdata                  ),
    .rtu_preg_rdata0                    (rtu_preg_rdata0                   ),
    .rtu_preg_rdata1                    (rtu_preg_rdata1                   ),
    .rtu_preg_rdata2                    (rtu_preg_rdata2                   ),
    .rtu_csr_src_rdata                  (rtu_csr_src_rdata                 ),
    .md_unit_stall                      (md_unit_stall                     )
    );

    // ============================================================
    //  u_lsu : lsu_top
    // ============================================================
    lsu_top
    #(.DCACHE_SIZE (2048),
      .LSIQ_ENTRY  (8),
      .SQ_ENTRY    (6),
      .SDIQ_ENTRY  (4),
      .WMB_ENTRY   (4),
      .LFB_ADDR_ENTRY(3),
      .LFB_DATA_ENTRY(1)) u_lsu (
    .idu_lsu_ld_sel                     (idu_lsu_ld_sel                    ),
    .idu_lsu_ld_inst_size               (idu_lsu_ld_inst_size              ),
    .idu_lsu_ld_unalign_2nd             (idu_lsu_ld_unalign_2nd            ),
    .idu_lsu_ld_sign_extend             (idu_lsu_ld_sign_extend            ),
    .idu_lsu_ld_iid                     (idu_lsu_ld_iid                    ),
    .idu_lsu_ld_lch_entry               (idu_lsu_ld_lch_entry              ),
    .idu_lsu_ld_oldest                  (idu_lsu_ld_oldest                 ),
    .idu_lsu_ld_preg                    (idu_lsu_ld_preg                   ),
    .idu_lsu_ld_offset                  (idu_lsu_ld_offset                 ),
    .idu_lsu_ld_offset_plus             (idu_lsu_ld_offset_plus            ),
    .idu_lsu_ld_src                     (idu_lsu_ld_src0                   ),   // 交付侧名字多个 0
    .idu_lsu_st_sel                     (idu_lsu_st_sel                    ),
    .idu_lsu_st_inst_size               (idu_lsu_st_inst_size              ),
    .idu_lsu_st_unalign_2nd             (idu_lsu_st_unalign_2nd            ),
    .idu_lsu_st_iid                     (idu_lsu_st_iid                    ),
    .idu_lsu_st_lch_entry               (idu_lsu_st_lch_entry              ),
    .idu_lsu_st_sdiq_entry              (idu_lsu_st_sdiq_entry             ),
    .idu_lsu_st_oldest                  (idu_lsu_st_oldest                 ),
    .idu_lsu_st_offset                  (idu_lsu_st_offset                 ),
    .idu_lsu_st_offset_plus             (idu_lsu_st_offset_plus            ),
    .idu_lsu_st_src0                    (idu_lsu_st_src0                   ),
    .idu_lsu_rf_pipe5_src0              (idu_lsu_rf_pipe5_src0             ),
    .idu_lsu_sdiq_sel                   (idu_lsu_sdiq_sel                  ),
    .idu_lsu_rf_pipe5_sdiq_entry        (idu_lsu_rf_pipe5_sdiq_entry       ),
    .rtu_yy_xx_flush                    (rtu_yy_xx_flush                   ),   // 用适配层合并后的那根, 与 IDU 同源
    .rtu_yy_xx_commit0                  (rtu_yy_xx_commit0                 ),
    .rtu_yy_xx_commit0_iid              (rtu_yy_xx_commit0_iid             ),
    .rtu_yy_xx_commit1                  (rtu_yy_xx_commit1                 ),
    .rtu_yy_xx_commit1_iid              (rtu_yy_xx_commit1_iid             ),
    .rtu_yy_xx_commit2                  (rtu_yy_xx_commit2                 ),
    .rtu_yy_xx_commit2_iid              (rtu_yy_xx_commit2_iid             ),
    .rtu_lsu_async_flush                (rtu_lsu_async_flush               ),
    .forever_cpuclk                     (cpu_clk                           ),
    .cpurst_b                           (cpurst_b                          ),
    .bus_arb_rb_ar_grnt                 (bus_arb_rb_ar_grnt                ),
    .bus_arb_rb_ar_sel                  (bus_arb_rb_ar_sel                 ),
    .biu_lsu_r_data                     (biu_lsu_r_data                    ),
    .biu_lsu_r_id                       (biu_lsu_r_id                      ),
    .biu_lsu_r_last                     (biu_lsu_r_last                    ),
    .biu_lsu_r_resp                     (biu_lsu_r_resp                    ),
    .biu_lsu_r_vld                      (biu_lsu_r_vld                     ),
    .biu_lsu_b_id                       (biu_lsu_b_id                      ),
    .biu_lsu_b_resp                     (biu_lsu_b_resp                    ),
    .biu_lsu_b_vld                      (biu_lsu_b_vld                     ),
    .bus_arb_wmb_aw_grnt                (bus_arb_wmb_aw_grnt               ),
    .bus_arb_wmb_w_grnt                 (bus_arb_wmb_w_grnt                ),
    .bus_arb_vb_aw_grnt                 (bus_arb_vb_aw_grnt                ),
    .bus_arb_vb_w_grnt                  (bus_arb_vb_w_grnt                 ),
    .rb_biu_ar_addr                     (rb_biu_ar_addr                    ),
    .rb_biu_ar_bar                      (rb_biu_ar_bar                     ),
    .rb_biu_ar_burst                    (rb_biu_ar_burst                   ),
    .rb_biu_ar_cache                    (rb_biu_ar_cache                   ),
    .rb_biu_ar_domain                   (rb_biu_ar_domain                  ),
    .rb_biu_ar_id                       (rb_biu_ar_id                      ),
    .rb_biu_ar_len                      (rb_biu_ar_len                     ),
    .rb_biu_ar_lock                     (rb_biu_ar_lock                    ),
    .rb_biu_ar_prot                     (rb_biu_ar_prot                    ),
    .rb_biu_ar_req                      (rb_biu_ar_req                     ),
    .rb_biu_ar_size                     (rb_biu_ar_size                    ),
    .rb_biu_ar_snoop                    (rb_biu_ar_snoop                   ),
    .rb_biu_ar_user                     (rb_biu_ar_user                    ),
    .wmb_biu_aw_addr                    (wmb_biu_aw_addr                   ),
    .wmb_biu_aw_bar                     (wmb_biu_aw_bar                    ),
    .wmb_biu_aw_burst                   (wmb_biu_aw_burst                  ),
    .wmb_biu_aw_cache                   (wmb_biu_aw_cache                  ),
    .wmb_biu_aw_domain                  (wmb_biu_aw_domain                 ),
    .wmb_biu_aw_id                      (wmb_biu_aw_id                     ),
    .wmb_biu_aw_len                     (wmb_biu_aw_len                    ),
    .wmb_biu_aw_lock                    (wmb_biu_aw_lock                   ),
    .wmb_biu_aw_prot                    (wmb_biu_aw_prot                   ),
    .wmb_biu_aw_req                     (wmb_biu_aw_req                    ),
    .wmb_biu_aw_size                    (wmb_biu_aw_size                   ),
    .wmb_biu_aw_snoop                   (wmb_biu_aw_snoop                  ),
    .wmb_biu_aw_user                    (wmb_biu_aw_user                   ),
    .wmb_biu_w_data                     (wmb_biu_w_data                    ),
    .wmb_biu_w_id                       (wmb_biu_w_id                      ),
    .wmb_biu_w_req                      (wmb_biu_w_req                     ),
    .wmb_biu_w_strb                     (wmb_biu_w_strb                    ),
    .wmb_biu_w_vld                      (wmb_biu_w_vld                     ),
    .vb_biu_aw_addr                     (vb_biu_aw_addr                    ),
    .vb_biu_aw_burst                    (vb_biu_aw_burst                   ),
    .vb_biu_aw_cache                    (vb_biu_aw_cache                   ),
    .vb_biu_aw_id                       (vb_biu_aw_id                      ),
    .vb_biu_aw_len                      (vb_biu_aw_len                     ),
    .vb_biu_aw_lock                     (vb_biu_aw_lock                    ),
    .vb_biu_aw_prot                     (vb_biu_aw_prot                    ),
    .vb_biu_aw_size                     (vb_biu_aw_size                    ),
    .vb_biu_aw_req                      (vb_biu_aw_req                     ),
    .vb_biu_w_data                      (vb_biu_w_data                     ),
    .vb_biu_w_id                        (vb_biu_w_id                       ),
    .vb_biu_w_last                      (vb_biu_w_last                     ),
    .vb_biu_w_req                       (vb_biu_w_req                      ),
    .vb_biu_w_strb                      (vb_biu_w_strb                     ),
    .vb_biu_w_vld                       (vb_biu_w_vld                      ),
    .lsu_idu_imme_wakeup                (lsu_idu_imme_wakeup               ),
    .lsu_idu_lsiq_pop_vld               (lsu_idu_lsiq_pop_vld              ),
    .lsu_idu_lsiq_pop0_vld              (lsu_idu_lsiq_pop0_vld             ),
    .lsu_idu_lsiq_pop1_vld              (lsu_idu_lsiq_pop1_vld             ),
    .lsu_idu_pop_entry                  (lsu_idu_pop_entry                 ),
    .lsu_idu_secd                       (lsu_idu_secd                      ),
    .lsu_idu_lq_full                    (lsu_idu_lq_full                   ),
    .lsu_idu_lq_not_full                (lsu_idu_lq_not_full               ),
    .lsu_idu_rb_full                    (lsu_idu_rb_full                   ),
    .lsu_idu_rb_not_full                (lsu_idu_rb_not_full               ),
    .lsu_idu_sq_full                    (lsu_idu_sq_full                   ),
    .lsu_idu_sq_not_full                (lsu_idu_sq_not_full               ),
    .lsu_idu_has_in_sq                  (lsu_idu_has_in_sq                 ),
    .lsu_rtu_wb_pipe3_cmplt             (lsu_rtu_wb_pipe3_cmplt            ),
    .lsu_rtu_wb_pipe3_iid               (lsu_rtu_wb_pipe3_iid              ),
    .lsu_rtu_wb_pipe3_expt_vld          (lsu_rtu_wb_pipe3_expt_vld         ),
    .lsu_rtu_wb_pipe3_expt_addr         (lsu_rtu_wb_pipe3_expt_addr        ),
    .lsu_rtu_wb_pipe3_wb_preg_expand    (lsu_rtu_wb_pipe3_wb_preg_expand   ),
    .lsu_rtu_wb_pipe3_wb_preg_vld       (lsu_rtu_wb_pipe3_wb_preg_vld      ),
    .lsu_idu_wb_pipe3_wb_preg           (lsu_idu_wb_pipe3_wb_preg          ),
    .lsu_idu_wb_pipe3_wb_preg_data      (lsu_idu_wb_pipe3_wb_preg_data     ),
    .lsu_idu_wb_pipe3_wb_preg_expand    (lsu_idu_wb_pipe3_wb_preg_expand   ),
    .lsu_idu_wb_pipe3_wb_preg_vld       (lsu_idu_wb_pipe3_wb_preg_vld      ),
    .lsu_rtu_wb_pipe4_cmplt             (lsu_rtu_wb_pipe4_cmplt            ),
    .lsu_rtu_wb_pipe4_expt_vld          (lsu_rtu_wb_pipe4_expt_vld         ),
    .lsu_rtu_wb_pipe4_expt_addr         (lsu_rtu_wb_pipe4_expt_addr        ),
    .lsu_rtu_wb_pipe4_flush             (lsu_rtu_wb_pipe4_flush            ),
    .lsu_rtu_wb_pipe4_iid               (lsu_rtu_wb_pipe4_iid              ),
    .lsu_rtu_wb_pipe4_spec_fail         (lsu_rtu_wb_pipe4_spec_fail        ),
    .sq_data_depd_wakeup                (sq_data_depd_wakeup               ),
    .sq_global_depd_wakeup              (sq_global_depd_wakeup             ),
    .lfb_depd_wakeup                    (lfb_depd_wakeup                   )
    );

    // ============================================================
    //  u_adapter : RTU_idu_lsu_adapter
    // ============================================================
    RTU_idu_lsu_adapter u_adapter (
    .cpu_clk                            (cpu_clk                           ),
    .cpu_rst                            (cpu_rst                           ),
    .cpurst_b                           (cpurst_b                          ),
    .idu_rtu_ir_preg0_alloc_vld         (idu_rtu_ir_preg0_alloc_vld        ),
    .idu_rtu_ir_preg1_alloc_vld         (idu_rtu_ir_preg1_alloc_vld        ),
    .idu_rtu_ir_preg2_alloc_vld         (idu_rtu_ir_preg2_alloc_vld        ),
    .rtu_idu_alloc_preg0                (rtu_idu_alloc_preg0               ),
    .rtu_idu_alloc_preg1                (rtu_idu_alloc_preg1               ),
    .rtu_idu_alloc_preg2                (rtu_idu_alloc_preg2               ),
    .rtu_idu_alloc_preg0_vld            (rtu_idu_alloc_preg0_vld           ),
    .rtu_idu_alloc_preg1_vld            (rtu_idu_alloc_preg1_vld           ),
    .rtu_idu_alloc_preg2_vld            (rtu_idu_alloc_preg2_vld           ),
    .rtu_idu_rob_inst0_iid              (rtu_idu_rob_inst0_iid             ),
    .rtu_idu_rob_inst1_iid              (rtu_idu_rob_inst1_iid             ),
    .rtu_idu_rob_inst2_iid              (rtu_idu_rob_inst2_iid             ),
    .rtu_idu_rob_full                   (rtu_idu_rob_full                  ),
    .rtu_yy_xx_flush                    (rtu_yy_xx_flush                   ),
    .rtu_idu_rt_recover_preg            (rtu_idu_rt_recover_preg           ),
    .idu_rtu_pst_preg_dealloc_mask      (idu_rtu_pst_preg_dealloc_mask     ),
    .idu_rtu_disp0_vld                  (idu_rtu_disp0_vld                 ),
    .idu_rtu_disp0_pc                   (idu_rtu_disp0_pc                  ),
    .idu_rtu_disp0_chk                  (idu_rtu_disp0_chk                 ),
    .idu_rtu_disp0_dst_lreg             (idu_rtu_disp0_dst_lreg            ),
    .idu_rtu_disp0_rf_we                (idu_rtu_disp0_rf_we               ),
    .idu_rtu_disp0_dst_preg             (idu_rtu_disp0_dst_preg            ),
    .idu_rtu_disp0_old_preg             (idu_rtu_disp0_old_preg            ),
    .idu_rtu_disp0_src1_preg            (idu_rtu_disp0_src1_preg           ),
    .idu_rtu_disp0_csr_addr             (idu_rtu_disp0_csr_addr            ),
    .idu_rtu_disp0_csr_op               (idu_rtu_disp0_csr_op              ),
    .idu_rtu_disp0_csr_imm              (idu_rtu_disp0_csr_imm             ),
    .idu_rtu_disp0_flags                (idu_rtu_disp0_flags               ),
    .idu_rtu_disp1_vld                  (idu_rtu_disp1_vld                 ),
    .idu_rtu_disp1_pc                   (idu_rtu_disp1_pc                  ),
    .idu_rtu_disp1_chk                  (idu_rtu_disp1_chk                 ),
    .idu_rtu_disp1_dst_lreg             (idu_rtu_disp1_dst_lreg            ),
    .idu_rtu_disp1_rf_we                (idu_rtu_disp1_rf_we               ),
    .idu_rtu_disp1_dst_preg             (idu_rtu_disp1_dst_preg            ),
    .idu_rtu_disp1_old_preg             (idu_rtu_disp1_old_preg            ),
    .idu_rtu_disp1_src1_preg            (idu_rtu_disp1_src1_preg           ),
    .idu_rtu_disp1_csr_addr             (idu_rtu_disp1_csr_addr            ),
    .idu_rtu_disp1_csr_op               (idu_rtu_disp1_csr_op              ),
    .idu_rtu_disp1_csr_imm              (idu_rtu_disp1_csr_imm             ),
    .idu_rtu_disp1_flags                (idu_rtu_disp1_flags               ),
    .idu_rtu_disp2_vld                  (idu_rtu_disp2_vld                 ),
    .idu_rtu_disp2_pc                   (idu_rtu_disp2_pc                  ),
    .idu_rtu_disp2_chk                  (idu_rtu_disp2_chk                 ),
    .idu_rtu_disp2_dst_lreg             (idu_rtu_disp2_dst_lreg            ),
    .idu_rtu_disp2_rf_we                (idu_rtu_disp2_rf_we               ),
    .idu_rtu_disp2_dst_preg             (idu_rtu_disp2_dst_preg            ),
    .idu_rtu_disp2_old_preg             (idu_rtu_disp2_old_preg            ),
    .idu_rtu_disp2_src1_preg            (idu_rtu_disp2_src1_preg           ),
    .idu_rtu_disp2_csr_addr             (idu_rtu_disp2_csr_addr            ),
    .idu_rtu_disp2_csr_op               (idu_rtu_disp2_csr_op              ),
    .idu_rtu_disp2_csr_imm              (idu_rtu_disp2_csr_imm             ),
    .idu_rtu_disp2_flags                (idu_rtu_disp2_flags               ),
    .lsu_rtu_wb_pipe3_cmplt             (lsu_rtu_wb_pipe3_cmplt            ),
    .lsu_rtu_wb_pipe3_iid               (lsu_rtu_wb_pipe3_iid              ),
    .lsu_rtu_wb_pipe3_expt_vld          (lsu_rtu_wb_pipe3_expt_vld         ),
    .lsu_rtu_wb_pipe3_expt_addr         (lsu_rtu_wb_pipe3_expt_addr        ),
    .lsu_rtu_wb_pipe4_cmplt             (lsu_rtu_wb_pipe4_cmplt            ),
    .lsu_rtu_wb_pipe4_iid               (lsu_rtu_wb_pipe4_iid              ),
    .lsu_rtu_wb_pipe4_expt_vld          (lsu_rtu_wb_pipe4_expt_vld         ),
    .lsu_rtu_wb_pipe4_expt_addr         (lsu_rtu_wb_pipe4_expt_addr        ),
    .lsu_rtu_wb_pipe4_flush             (lsu_rtu_wb_pipe4_flush            ),
    .lsu_rtu_wb_pipe4_spec_fail         (lsu_rtu_wb_pipe4_spec_fail        ),
    .other_expt_vld                     (other_expt_vld                    ),
    .other_expt_iid                     (other_expt_iid                    ),
    .other_expt_cause                   (other_expt_cause                  ),
    .other_expt_tval                    (other_expt_tval                   ),
    .ren_preg_req                       (ren_preg_req                      ),
    .ren_preg_req_lreg0                 (ren_preg_req_lreg0                ),
    .ren_preg_req_lreg1                 (ren_preg_req_lreg1                ),
    .ren_preg_req_lreg2                 (ren_preg_req_lreg2                ),
    .rtu_preg_alloc0                    (rtu_preg_alloc0                   ),
    .rtu_preg_alloc1                    (rtu_preg_alloc1                   ),
    .rtu_preg_alloc2                    (rtu_preg_alloc2                   ),
    .rtu_preg_alloc_vld0                (rtu_preg_alloc_vld0               ),
    .rtu_preg_alloc_vld1                (rtu_preg_alloc_vld1               ),
    .rtu_preg_alloc_vld2                (rtu_preg_alloc_vld2               ),
    .disp0_vld                          (disp0_vld                         ),
    .disp0_pc                           (disp0_pc                          ),
    .disp0_chk                          (disp0_chk                         ),
    .disp0_dst_lreg                     (disp0_dst_lreg                    ),
    .disp0_rf_we                        (disp0_rf_we                       ),
    .disp0_dst_preg                     (disp0_dst_preg                    ),
    .disp0_old_preg                     (disp0_old_preg                    ),
    .disp0_src1_preg                    (disp0_src1_preg                   ),
    .disp0_csr_addr                     (disp0_csr_addr                    ),
    .disp0_csr_op                       (disp0_csr_op                      ),
    .disp0_csr_imm                      (disp0_csr_imm                     ),
    .disp0_flags                        (disp0_flags                       ),
    .disp0_sq_id                        (disp0_sq_id                       ),
    .disp1_vld                          (disp1_vld                         ),
    .disp1_pc                           (disp1_pc                          ),
    .disp1_chk                          (disp1_chk                         ),
    .disp1_dst_lreg                     (disp1_dst_lreg                    ),
    .disp1_rf_we                        (disp1_rf_we                       ),
    .disp1_dst_preg                     (disp1_dst_preg                    ),
    .disp1_old_preg                     (disp1_old_preg                    ),
    .disp1_src1_preg                    (disp1_src1_preg                   ),
    .disp1_csr_addr                     (disp1_csr_addr                    ),
    .disp1_csr_op                       (disp1_csr_op                      ),
    .disp1_csr_imm                      (disp1_csr_imm                     ),
    .disp1_flags                        (disp1_flags                       ),
    .disp1_sq_id                        (disp1_sq_id                       ),
    .disp2_vld                          (disp2_vld                         ),
    .disp2_pc                           (disp2_pc                          ),
    .disp2_chk                          (disp2_chk                         ),
    .disp2_dst_lreg                     (disp2_dst_lreg                    ),
    .disp2_rf_we                        (disp2_rf_we                       ),
    .disp2_dst_preg                     (disp2_dst_preg                    ),
    .disp2_old_preg                     (disp2_old_preg                    ),
    .disp2_src1_preg                    (disp2_src1_preg                   ),
    .disp2_csr_addr                     (disp2_csr_addr                    ),
    .disp2_csr_op                       (disp2_csr_op                      ),
    .disp2_csr_imm                      (disp2_csr_imm                     ),
    .disp2_flags                        (disp2_flags                       ),
    .disp2_sq_id                        (disp2_sq_id                       ),
    .cmplt_vld5                         (cmplt_vld5                        ),
    .cmplt_iid5                         (cmplt_iid5                        ),
    .cmplt_vld6                         (cmplt_vld6                        ),
    .cmplt_iid6                         (cmplt_iid6                        ),
    .lsu_replay_vld                     (lsu_replay_vld                    ),
    .lsu_replay_iid                     (lsu_replay_iid                    ),
    .expt_vld                           (expt_vld                          ),
    .expt_iid                           (expt_iid                          ),
    .expt_cause                         (expt_cause                        ),
    .expt_tval                          (expt_tval                         ),
    .sq_rdy0                            (sq_rdy0                           ),
    .sq_rdy1                            (sq_rdy1                           ),
    .sq_rdy2                            (sq_rdy2                           ),
    .sq_stall                           (sq_stall                          ),
    .preg_dealloc_mask                  (preg_dealloc_mask                 ),
    .rtu_disp_stall                     (rtu_disp_stall                    ),
    .rtu_ren_flush                      (rtu_ren_flush                     ),
    .rtu_backend_flush                  (rtu_backend_flush                 ),
    .rtu_ren_recover_map                (rtu_ren_recover_map               ),
    .rtu_disp_iid0                      (rtu_disp_iid0                     ),
    .rtu_disp_iid1                      (rtu_disp_iid1                     ),
    .rtu_disp_iid2                      (rtu_disp_iid2                     ),
    .rtu_preg_free_cnt                  (rtu_preg_free_cnt                 )
    );

endmodule
