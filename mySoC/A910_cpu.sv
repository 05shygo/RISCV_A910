odule A910_cpu (
    //---------------------------------------------------------
    // AXI master read address
    //---------------------------------------------------------
    output wire [31:0]  biu_pad_araddr,
    output wire [3:0]   biu_pad_arid,
    output wire [1:0]   biu_pad_arlen,
    output wire [2:0]   biu_pad_arsize,
    output wire [1:0]   biu_pad_arburst,
    output wire [3:0]   biu_pad_arcache,
    output wire [2:0]   biu_pad_arprot,
    output wire         biu_pad_arvalid,
    input  wire         pad_biu_arready,

    //---------------------------------------------------------
    // AXI master read data
    //---------------------------------------------------------
    input  wire [127:0] pad_biu_rdata,
    input  wire [3:0]   pad_biu_rid,
    input  wire         pad_biu_rlast,
    input  wire [1:0]   pad_biu_rresp,
    input  wire         pad_biu_rvalid,
    output wire         biu_pad_rready,

    //---------------------------------------------------------
    // AXI master write address
    //---------------------------------------------------------
    output wire [31:0]  biu_pad_awaddr,
    output wire [3:0]   biu_pad_awid,
    output wire [1:0]   biu_pad_awlen,
    output wire [2:0]   biu_pad_awsize,
    output wire [1:0]   biu_pad_awburst,
    output wire [3:0]   biu_pad_awcache,
    output wire [2:0]   biu_pad_awprot,
    output wire         biu_pad_awvalid,
    input  wire         pad_biu_awready,

    //---------------------------------------------------------
    // AXI master write data
    //---------------------------------------------------------
    output wire [127:0] biu_pad_wdata,
    output wire [15:0]  biu_pad_wstrb,
    output wire         biu_pad_wlast,
    output wire         biu_pad_wvalid,
    input  wire         pad_biu_wready,

    //---------------------------------------------------------
    // AXI master write response
    //---------------------------------------------------------
    input  wire [3:0]   pad_biu_bid,
    input  wire [1:0]   pad_biu_bresp,
    input  wire         pad_biu_bvalid,
    output wire         biu_pad_bready
);
// ============================================================
// IFU
// ============================================================
rv32ifu2_top u_rv32ifu2_top (
    .clk                (),
    .rst                (),

    // ---- IDU 交付 ----
    .idu_inst0_vld      (idu_inst0_vld),
    .idu_inst0_data     (idu_inst0_data),
    .idu_inst0_chk      (idu_inst0_chk),
    .idu_inst1_vld      (idu_inst1_vld),
    .idu_inst1_data     (idu_inst1_data),
    .idu_inst1_chk      (idu_inst1_chk),
    .idu_inst2_vld      (idu_inst2_vld),
    .idu_inst2_data     (idu_inst2_data),
    .idu_inst2_chk      (idu_inst2_chk),
    .idu_flush          (),
    .idu_accept_num     (idu_accept_num),

    // ---- 后端重定向 ----
    .iu_chgflw_vld      (),
    .iu_chgflw_pc       (),
    .rtu_flush          (),
    .rtu_chgflw_vld     (),
    .rtu_chgflw_pc      (),

    // ---- 分支预测器训练 ----
    .rtu_train_vld      (),
    .rtu_train_pc       (),
    .rtu_train_target   (),
    .rtu_train_chk      (),
    .rtu_train_taken    (),
    .rtu_train_is_cond  (),
    .rtu_train_is_jal   (),
    .rtu_train_is_jalr  (),

    .iu_btb_chk         (),
    .iu_btb_taken       (),
    .iu_btb_is_cond     (),

    // ---- 状态 ----
    .init_done          (),

    // ---- BIU 主端 ----
    .biu_rd_req         (),
    .biu_rd_addr        (),
    .biu_rd_id          (),
    .biu_rd_len         (),
    .biu_rd_grnt        (),
    .biu_rd_data_vld    (),
    .biu_rd_data        (),
    .biu_rd_rid         (),
    .biu_rd_last        (),
    .biu_rd_resp        (),
    .biu_r_ready        ()
);

logic [96:0]ifu_idu_ib_inst0_data;
logic [96:0]ifu_idu_ib_inst1_data;
logic [96:0]ifu_idu_ib_inst2_data;

assign ifu_idu_ib_inst0_data[96:0] = {idu_inst0_data[95:0],idu_inst0_data[122]};
assign ifu_idu_ib_inst1_data[96:0] = {idu_inst1_data[95:0],idu_inst2_data[122]};
assign ifu_idu_ib_inst2_data[96:0] = {idu_inst2_data[95:0],idu_inst2_data[122]};

// ============================================================
// IDU
// ============================================================
ct_idu_top u_ct_idu_top (
  //==========================================================
  // Global signals
  //==========================================================
  .forever_cpuclk                 (),
  .cpurst_b                       (),

  //==========================================================
  // Interface with IFU
  //==========================================================
  .ifu_idu_ib_inst0_vld           (idu_inst0_vld),
  .ifu_idu_ib_inst1_vld           (idu_inst1_vld),
  .ifu_idu_ib_inst2_vld           (idu_inst2_vld),
  .ifu_idu_ib_inst0_data          (ifu_idu_ib_inst0_data),
  .ifu_idu_if_inst0_chk           (idu_inst0_chk),
  .ifu_idu_ib_inst1_data          (ifu_idu_ib_inst1_data),
  .ifu_idu_if_inst1_chk           (idu_inst1_chk),
  .ifu_idu_ib_inst2_data          (ifu_idu_ib_inst2_data),
  .ifu_idu_if_inst2_chk           (idu_inst2_chk),
  .idu_accept_num                 (idu_accept_num),

  //==========================================================
  // Interface with RTU
  //==========================================================
  .rtu_idu_alloc_preg0_vld        (),
  .rtu_idu_alloc_preg1_vld        (),
  .rtu_idu_alloc_preg2_vld        (),
  .rtu_idu_alloc_preg0            (),
  .rtu_idu_alloc_preg1            (),
  .rtu_idu_alloc_preg2            (),
  .rtu_idu_rob_inst0_iid          (),
  .rtu_idu_rob_inst1_iid          (),
  .rtu_idu_rob_inst2_iid          (),
  .rtu_idu_rob_full               (),
  .rtu_idu_rt_recover_preg        (),
  .rtu_yy_xx_flush                (),
  .idu_rtu_ir_preg0_alloc_vld     (),
  .idu_rtu_ir_preg1_alloc_vld     (),
  .idu_rtu_ir_preg2_alloc_vld     (),
  .idu_rtu_pst_preg_dealloc_mask  (),

  //==========================================================
  // Interface with IU - Writeback
  //==========================================================
  .iu_idu_ex2_pipe0_wb_preg_dupx      (),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx  (),
  .iu_idu_ex2_pipe0_wb_preg_data      (),
  .iu_idu_ex2_pipe0_wb_preg_expand    (),
  .iu_idu_ex2_pipe0_wb_preg_vld       (),
  .iu_idu_ex2_pipe1_wb_preg_dupx      (),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx  (),
  .iu_idu_ex2_pipe1_wb_preg_data      (),
  .iu_idu_ex2_pipe1_wb_preg_expand    (),
  .iu_idu_ex2_pipe1_wb_preg_vld       (),

  //==========================================================
  // Interface with LSU - Writeback
  //==========================================================
  .lsu_idu_wb_pipe3_wb_preg_dupx      (lsu_idu_wb_pipe3_wb_preg),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx  (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_data      (lsu_idu_wb_pipe3_wb_preg_data),
  .lsu_idu_wb_pipe3_wb_preg_expand    (lsu_idu_wb_pipe3_wb_preg_expand),
  .lsu_idu_wb_pipe3_wb_preg_vld       (lsu_idu_wb_pipe3_wb_preg_vld),

  //==========================================================
  // Interface with LSU - LSIQ control
  //==========================================================
  .lsu_idu_lq_full                (lsu_idu_lq_full),
  .lsu_idu_lq_not_full            (lsu_idu_lq_not_full),
  .lsu_idu_rb_full                (lsu_idu_rb_full),
  .lsu_idu_rb_not_full            (lsu_idu_rb_not_full),
  .lsu_idu_sq_full                (lsu_idu_sq_full),
  .lsu_idu_sq_not_full            (lsu_idu_sq_not_full),
  .lsu_idu_secd                   (lsu_idu_secd),
  .lsu_idu_imme_wakeup            (lsu_idu_imme_wakeup),
  .lsu_idu_lsiq_pop_vld           (lsu_idu_lsiq_pop_vld),
  .lsu_idu_lsiq_pop0_vld          (lsu_idu_lsiq_pop0_vld),
  .lsu_idu_lsiq_pop1_vld          (lsu_idu_lsiq_pop1_vld),
  .lsu_idu_lsiq_pop_entry         (lsu_idu_lsiq_pop_entry),

  //==========================================================
  // Interface with LSU - SDIQ control
  //==========================================================
//  .lsu_sdiq_has_in_sq_vld         (),
  .lsu_sdiq_has_in_sq_sdiq        (lsu_idu_has_in_sq),

  //==========================================================
  // Output to AIQ
  //==========================================================
  .idu_aiq_sel                    (),
  .idu_aiq_iid                    (),
  .idu_aiq_dst_preg               (),
  .idu_aiq_src0                   (),
  .idu_aiq_src1                   (),
  .idu_aiq_pc                     (),
  .idu_aiq_rslt_sel               (),
  .idu_aiq_illegal                (),

  //==========================================================
  // Output to MULT
  //==========================================================
  .idu_mult_sel                   (),
  .idu_mult_iid                   (),
  .idu_mult_dst_preg              (),
  .idu_mult_src0                  (),
  .idu_mult_src1                  (),
  .idu_mult_rslt_sel              (),

  //==========================================================
  // Output to DIV
  //==========================================================
  .idu_div_sel                    (),
  .idu_div_iid                    (),
  .idu_div_dst_vld                (),
  .idu_div_dst_preg               (),
  .idu_div_src0                   (),
  .idu_div_src1                   (),
  .idu_div_rslt_sel               (),

  //==========================================================
  // Output to LSU - Load pipe
  //==========================================================
  .idu_lsu_ld_sel                 (idu_lsu_ld_sel),
  .idu_lsu_ld_iid                 (idu_lsu_ld_iid),
  .idu_lsu_ld_preg                (idu_lsu_ld_preg),
  .idu_lsu_ld_src0                (idu_lsu_ld_src),
  .idu_lsu_ld_offset              (idu_lsu_ld_offset),
  .idu_lsu_ld_offset_plus         (idu_lsu_ld_offset_plus),
  .idu_lsu_ld_sign_extend         (idu_lsu_ld_sign_extend),
  .idu_lsu_ld_inst_size           (idu_lsu_ld_inst_size),
  .idu_lsu_ld_unalign_2nd         (idu_lsu_ld_unalign_2nd),
  .idu_lsu_ld_lch_entry           (idu_lsu_ld_lch_entry),
  .idu_lsu_ld_oldest              (idu_lsu_ld_oldest),

  //==========================================================
  // Output to LSU - Store pipe
  //==========================================================
  .idu_lsu_st_sel                 (idu_lsu_st_sel),
  .idu_lsu_st_iid                 (idu_lsu_st_iid),
 // .idu_lsu_st_preg                (),
  .idu_lsu_st_src0                (idu_lsu_st_src0),
  .idu_lsu_st_offset              (idu_lsu_st_offset),
  .idu_lsu_st_offset_plus         (idu_lsu_st_offset_plus),
  .idu_lsu_st_inst_size           (idu_lsu_st_inst_size),
  .idu_lsu_st_unalign_2nd         (idu_lsu_st_unalign_2nd),
  .idu_lsu_st_lch_entry           (idu_lsu_st_lch_entry),
  .idu_lsu_st_oldest              (idu_lsu_st_oldest),
  .idu_lsu_st_sdiq_entry          (idu_lsu_st_sdiq_entry),

  //==========================================================
  // Output to LSU - SDIQ pipe
  //==========================================================
  .idu_lsu_sdiq_sel               (idu_lsu_sdiq_sel),
  .idu_lsu_rf_pipe5_sdiq_entry    (idu_lsu_rf_pipe5_sdiq_entry),
  .idu_lsu_rf_pipe5_src0          (idu_lsu_rf_pipe5_src0),

  //==========================================================
  // Output to BIQ
  //==========================================================
  .idu_biq_sel                    (),
  .idu_biq_iid                    (),
  .idu_biq_src0                   (),
  .idu_biq_src1                   (),
  .idu_biq_rslt_sel               (),
  .idu_biq_br_imme                (),
  .idu_biq_dst_vld                (),
  .idu_biq_dst_preg               (),
  .idu_biq_taken                  (),
  .idu_biq_npc                    (),
  .idu_biq_pc                     (),
  .idu_biq_chk                    (),

  //==========================================================
  // Interface with RTU — 派遣记录
  //==========================================================
  .idu_rtu_disp0_vld              (),
  .idu_rtu_disp0_pc               (),
  .idu_rtu_disp0_chk              (),
  .idu_rtu_disp0_dst_lreg         (),
  .idu_rtu_disp0_rf_we            (),
  .idu_rtu_disp0_dst_preg         (),
  .idu_rtu_disp0_old_preg         (),
  .idu_rtu_disp0_src1_preg        (),
  .idu_rtu_disp0_csr_addr         (),
  .idu_rtu_disp0_csr_op           (),
  .idu_rtu_disp0_csr_imm          (),
  .idu_rtu_disp0_flags            (),

  .idu_rtu_disp1_vld              (),
  .idu_rtu_disp1_pc               (),
  .idu_rtu_disp1_chk              (),
  .idu_rtu_disp1_dst_lreg         (),
  .idu_rtu_disp1_rf_we            (),
  .idu_rtu_disp1_dst_preg         (),
  .idu_rtu_disp1_old_preg         (),
  .idu_rtu_disp1_src1_preg        (),
  .idu_rtu_disp1_csr_addr         (),
  .idu_rtu_disp1_csr_op           (),
  .idu_rtu_disp1_csr_imm          (),
  .idu_rtu_disp1_flags            (),

  .idu_rtu_disp2_vld              (),
  .idu_rtu_disp2_pc               (),
  .idu_rtu_disp2_chk              (),
  .idu_rtu_disp2_dst_lreg         (),
  .idu_rtu_disp2_rf_we            (),
  .idu_rtu_disp2_dst_preg         (),
  .idu_rtu_disp2_old_preg         (),
  .idu_rtu_disp2_src1_preg        (),
  .idu_rtu_disp2_csr_addr         (),
  .idu_rtu_disp2_csr_op           (),
  .idu_rtu_disp2_csr_imm          (),
  .idu_rtu_disp2_flags            (),

  //==========================================================
  // Interface with RTU — 物理寄存器堆访问
  //==========================================================
  .rtu_preg_raddr0                (),
  .rtu_preg_raddr1                (),
  .rtu_preg_raddr2                (),
  .rtu_csr_src_raddr              (),
  .rtu_csr_rd_we                  (),
  .rtu_csr_rd_addr                (),
  .rtu_csr_rd_wdata               (),
  .rtu_preg_rdata0                (),
  .rtu_preg_rdata1                (),
  .rtu_preg_rdata2                (),
  .rtu_csr_src_rdata              (),

  //==========================================================
  // 执行单元的发射准入
  //==========================================================
  .md_unit_stall                  ()
);

// ============================================================
// LSU
// ============================================================
lsu_top #(
    .DCACHE_SIZE     (2048),
    .LSIQ_ENTRY      (8),
    .SQ_ENTRY        (6),
    .SDIQ_ENTRY      (4),
    .WMB_ENTRY       (4),
    .LFB_ADDR_ENTRY  (3),
    .LFB_DATA_ENTRY  (1)
) u_lsu_top (
    // IDU to LSU - Load interface
    .idu_lsu_ld_sel                 (idu_lsu_ld_sel),
    .idu_lsu_ld_inst_size           (idu_lsu_ld_inst_size),
    .idu_lsu_ld_unalign_2nd         (idu_lsu_ld_unalign_2nd),
    .idu_lsu_ld_sign_extend         (idu_lsu_ld_sign_extend),
    .idu_lsu_ld_iid                 (idu_lsu_ld_iid),
    .idu_lsu_ld_lch_entry           (idu_lsu_ld_lch_entry),
    .idu_lsu_ld_oldest              (idu_lsu_ld_oldest),
    .idu_lsu_ld_preg                (idu_lsu_ld_preg),
    .idu_lsu_ld_offset              (idu_lsu_ld_offset),
    .idu_lsu_ld_offset_plus         (idu_lsu_ld_offset_plus),
    .idu_lsu_ld_src                 (idu_lsu_ld_src),

    // IDU to LSU - Store interface
    .idu_lsu_st_sel                 (idu_lsu_st_sel),
    .idu_lsu_st_inst_size           (idu_lsu_st_inst_size),
    .idu_lsu_st_unalign_2nd         (idu_lsu_st_unalign_2nd),
    .idu_lsu_st_iid                 (idu_lsu_st_iid),
    .idu_lsu_st_lch_entry           (idu_lsu_st_lch_entry),
    .idu_lsu_st_sdiq_entry          (idu_lsu_st_sdiq_entry),
    .idu_lsu_st_oldest              (idu_lsu_st_oldest),
    .idu_lsu_st_offset              (idu_lsu_st_offset),
    .idu_lsu_st_offset_plus         (idu_lsu_st_offset_plus),
    .idu_lsu_st_src0                (idu_lsu_st_src0),

    .idu_lsu_rf_pipe5_src0          (idu_lsu_rf_pipe5_src0),
    .idu_lsu_sdiq_sel               (idu_lsu_sdiq_sel),
    .idu_lsu_rf_pipe5_sdiq_entry    (idu_lsu_rf_pipe5_sdiq_entry),

    // RTU interface
    .rtu_yy_xx_flush                (),
    .rtu_yy_xx_commit0              (),
    .rtu_yy_xx_commit0_iid          (),
    .rtu_yy_xx_commit1              (),
    .rtu_yy_xx_commit1_iid          (),
    .rtu_yy_xx_commit2              (),
    .rtu_yy_xx_commit2_iid          (),
    .rtu_lsu_async_flush            (),

    // Clock and reset
    .forever_cpuclk                 (),
    .cpurst_b                       (),

    // BIU read interface (from bus to LSU)
    .biu_lsu_r_data                 (biu_lsu_rdata),
    .biu_lsu_r_id                   (biu_lsu_rid),
    .biu_lsu_r_last                 (biu_lsu_rlast),
    .biu_lsu_r_resp                 (biu_lsu_rresp),
    .biu_lsu_r_vld                  (biu_lsu_rvalid),

    // BIU write response interface (from bus to LSU)
    .biu_lsu_b_id                   (biu_lsu_bid),
    .biu_lsu_b_resp                 (biu_lsu_bresp),
    .biu_lsu_b_vld                  (biu_lsu_bvalid),

    .biu_lsu_ar_ready               (lsu_biu_arready),
    // 4 个 grnt: store 走 WMB 通路, victim 走 VB 通路
    .biu_lsu_aw_wmb_grnt            (lsu_biu_aw_st_ready),
    .biu_lsu_w_wmb_grnt             (lsu_biu_w_st_ready),
    .biu_lsu_aw_vb_grnt             (lsu_biu_aw_vict_ready),
    .biu_lsu_w_vb_grnt              (lsu_biu_w_vict_ready),

    // BIU AR 输出
    .lsu_biu_ar_addr                (lsu_biu_araddr),
 // .lsu_biu_ar_bar                 (),   // ct_biu_top 无此口 (AXI4)
    .lsu_biu_ar_burst               (lsu_biu_arburst),
    .lsu_biu_ar_cache               (lsu_biu_arcache),
 // .lsu_biu_ar_domain              (),   // ct_biu_top 无此口
    .lsu_biu_ar_id                  (lsu_biu_arid),
    .lsu_biu_ar_len                 (lsu_biu_arlen),
 // .lsu_biu_ar_lock                (),   // ct_biu_top 无此口
    .lsu_biu_ar_prot                (lsu_biu_arprot),
    .lsu_biu_ar_req                 (lsu_biu_arvalid),
    .lsu_biu_ar_size                (lsu_biu_arsize),
 // .lsu_biu_ar_user                (),   // ct_biu_top 无此口
    .lsu_biu_r_ready                (lsu_biu_rready),

    // BIU AW store 输出
    .lsu_biu_aw_st_addr             (lsu_biu_aw_st_addr),
 // .lsu_biu_aw_st_bar              (),   // ct_biu_top 无此口
    .lsu_biu_aw_st_burst            (lsu_biu_aw_st_burst),
    .lsu_biu_aw_st_cache            (lsu_biu_aw_st_cache),
 // .lsu_biu_aw_st_domain           (),   // ct_biu_top 无此口
    .lsu_biu_aw_st_id               (lsu_biu_aw_st_id),
    .lsu_biu_aw_st_len              (lsu_biu_aw_st_len),
 // .lsu_biu_aw_st_lock             (),   // ct_biu_top 无此口
    .lsu_biu_aw_st_prot             (lsu_biu_aw_st_prot),
    .lsu_biu_aw_st_req              (lsu_biu_aw_st_valid),
    .lsu_biu_aw_st_size             (lsu_biu_aw_st_size),
 // .lsu_biu_aw_st_user             (),   // ct_biu_top 无此口

    // BIU AW victim 输出
    .lsu_biu_aw_vict_addr           (lsu_biu_aw_vict_addr),
 // .lsu_biu_aw_vict_bar            (),   // ct_biu_top 无此口
    .lsu_biu_aw_vict_burst          (lsu_biu_aw_vict_burst),
    .lsu_biu_aw_vict_cache          (lsu_biu_aw_vict_cache),
 // .lsu_biu_aw_vict_domain         (),   // ct_biu_top 无此口
    .lsu_biu_aw_vict_id             (lsu_biu_aw_vict_id),
    .lsu_biu_aw_vict_len            (lsu_biu_aw_vict_len),
 // .lsu_biu_aw_vict_lock           (),   // ct_biu_top 无此口
    .lsu_biu_aw_vict_prot           (lsu_biu_aw_vict_prot),
    .lsu_biu_aw_vict_req            (lsu_biu_aw_vict_valid),
    .lsu_biu_aw_vict_size           (lsu_biu_aw_vict_size),
 // .lsu_biu_aw_vict_user           (),   // ct_biu_top 无此口

    // BIU W store 输出
    .lsu_biu_w_st_data              (lsu_biu_w_st_data),
    .lsu_biu_w_st_last              (lsu_biu_w_st_last),
    .lsu_biu_w_st_strb              (lsu_biu_w_st_strb),
    .lsu_biu_w_st_vld               (lsu_biu_w_st_valid),

    // BIU W victim 输出
    .lsu_biu_w_vict_data            (lsu_biu_w_vict_data),
    .lsu_biu_w_vict_last            (lsu_biu_w_vict_last),
    .lsu_biu_w_vict_strb            (lsu_biu_w_vict_strb),
    .lsu_biu_w_vict_vld             (lsu_biu_w_vict_valid),

    // LSU to IDU - Load queue status
    .lsu_idu_imme_wakeup            (lsu_idu_imme_wakeup),
    .lsu_idu_lsiq_pop_vld           (lsu_idu_lsiq_pop_vld),
    .lsu_idu_lsiq_pop0_vld          (lsu_idu_lsiq_pop0_vld),
    .lsu_idu_lsiq_pop1_vld          (lsu_idu_lsiq_pop1_vld),
    .lsu_idu_pop_entry              (lsu_idu_lsiq_pop_entry),
    .lsu_idu_secd                   (lsu_idu_secd),

    .lsu_idu_lq_full                (lsu_idu_lq_full),
    .lsu_idu_lq_not_full            (lsu_idu_lq_not_full),

    .lsu_idu_rb_full                (lsu_idu_rb_full),
    .lsu_idu_rb_not_full            (lsu_idu_rb_not_full),

    .lsu_idu_sq_full                (lsu_idu_sq_full),
    .lsu_idu_sq_not_full            (lsu_idu_sq_not_full),

    .lsu_idu_has_in_sq              (lsu_idu_has_in_sq),

    // LSU to RTU - Writeback pipe3
    .lsu_rtu_wb_pipe3_cmplt         (),
    .lsu_rtu_wb_pipe3_iid           (),
    .lsu_rtu_wb_pipe3_expt_vld      (),
    .lsu_rtu_wb_pipe3_expt_addr     (),
    .lsu_rtu_wb_pipe3_wb_preg_expand(),
    .lsu_rtu_wb_pipe3_wb_preg_vld   (),

    // LSU to IDU - Writeback pipe3
    .lsu_idu_wb_pipe3_wb_preg       (lsu_idu_wb_pipe3_wb_preg),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
    .lsu_idu_wb_pipe3_wb_preg_data  (lsu_idu_wb_pipe3_wb_preg_data),
    .lsu_idu_wb_pipe3_wb_preg_expand(lsu_idu_wb_pipe3_wb_preg_expand),
    .lsu_idu_wb_pipe3_wb_preg_vld   (lsu_idu_wb_pipe3_wb_preg_vld),

    // LSU to RTU - Writeback pipe4
    .lsu_rtu_wb_pipe4_cmplt         (),
    .lsu_rtu_wb_pipe4_expt_vld      (),
    .lsu_rtu_wb_pipe4_expt_addr     (),
    .lsu_rtu_wb_pipe4_flush         (),
    .lsu_rtu_wb_pipe4_iid           (),
    .lsu_rtu_wb_pipe4_spec_fail     ()

    // Store queue wakeup
 // .sq_data_depd_wakeup            (),
 // .sq_global_depd_wakeup          (),

    // LFB dependency wakeup
 // .lfb_depd_wakeup                ()
);

// ============================================================
// RTU
// ============================================================
RTU u_rtu (
    .cpu_clk                    (),
    .cpu_rst                    (),

    // ===================== §6.0 物理寄存器分配握手 =====================
    .ren_preg_req               (),
    .ren_preg_req_lreg0         (),
    .ren_preg_req_lreg1         (),
    .ren_preg_req_lreg2         (),
    .rtu_preg_alloc0            (),
    .rtu_preg_alloc1            (),
    .rtu_preg_alloc2            (),
    .rtu_preg_alloc_vld0        (),
    .rtu_preg_alloc_vld1        (),
    .rtu_preg_alloc_vld2        (),
    .rtu_preg_free_cnt          (),

    // ===================== §6.1 派遣 (车道 0) =====================
    .disp0_vld                  (),
    .disp0_pc                   (),
    .disp0_chk                  (),
    .disp0_dst_lreg             (),
    .disp0_rf_we                (),
    .disp0_dst_preg             (),
    .disp0_old_preg             (),
    .disp0_src1_preg            (),
    .disp0_csr_addr             (),
    .disp0_csr_op               (),
    .disp0_csr_imm              (),
    .disp0_flags                (),
    .disp0_sq_id                (),

    // ===================== §6.1 派遣 (车道 1) =====================
    .disp1_vld                  (),
    .disp1_pc                   (),
    .disp1_chk                  (),
    .disp1_dst_lreg             (),
    .disp1_rf_we                (),
    .disp1_dst_preg             (),
    .disp1_old_preg             (),
    .disp1_src1_preg            (),
    .disp1_csr_addr             (),
    .disp1_csr_op               (),
    .disp1_csr_imm              (),
    .disp1_flags                (),
    .disp1_sq_id                (),

    // ===================== §6.1 派遣 (车道 2) =====================
    .disp2_vld                  (),
    .disp2_pc                   (),
    .disp2_chk                  (),
    .disp2_dst_lreg             (),
    .disp2_rf_we                (),
    .disp2_dst_preg             (),
    .disp2_old_preg             (),
    .disp2_src1_preg            (),
    .disp2_csr_addr             (),
    .disp2_csr_op               (),
    .disp2_csr_imm              (),
    .disp2_flags                (),
    .disp2_sq_id                (),

    // ===================== §6.1 完成 (p = 0..6) =====================
    .cmplt_vld0                 (),
    .cmplt_iid0                 (),
    .cmplt_vld1                 (),
    .cmplt_iid1                 (),
    .cmplt_vld2                 (),
    .cmplt_iid2                 (),
    .cmplt_vld3                 (),
    .cmplt_iid3                 (),
    .cmplt_vld4                 (),
    .cmplt_iid4                 (),
    .cmplt_vld5                 (),
    .cmplt_iid5                 (),
    .cmplt_vld6                 (),
    .cmplt_iid6                 (),

    // ===================== §6.1 解析结果 (BEU) =====================
    .resolve_vld                (),
    .resolve_iid                (),
    .resolve_taken              (),
    .resolve_mispred            (),
    .resolve_target             (),

    // ===================== §6.1 LSU store 重放请求 =====================
    .lsu_replay_vld             (),
    .lsu_replay_iid             (),

    // ===================== §6.1 异常 =====================
    .expt_vld                   (),
    .expt_iid                   (),
    .expt_cause                 (),
    .expt_tval                  (),

    // ===================== §6.1 存储队列 / CSR / 中断 =====================
    .sq_rdy0                    (),
    .sq_rdy1                    (),
    .sq_rdy2                    (),
    .sq_stall                   (),
    .csr_rdata                  (),
    .int_pending                (),

    // ============ §6.1 IDU 的释放否决掩码 ============
    .preg_dealloc_mask          (),

    // ===================== BEU -> RTU (D13) =====================
    .beu_redirect_vld           (),

    // ===================== §6.1 物理寄存器堆读口 (A1) =====================
    .preg_rdata0                (),
    .preg_rdata1                (),
    .preg_rdata2                (),
    .rtu_csr_src_rdata          (),

    // ===================== §6.1 重定向目标的来源 (A6) =====================
    .csr_trap_vector            (),
    .csr_mepc                   (),

    // ===================== §6.2 前端: 陷阱/中断/mret 的重定向 =====================
    .rtu_ifu_flush              (),
    .rtu_ifu_chgflw_vld         (),
    .rtu_ifu_chgflw_pc          (),

    // ---- 退休点重训练 ----
    .rtu_ifu_train_vld          (),
    .rtu_ifu_train_pc           (),
    .rtu_ifu_train_target       (),
    .rtu_ifu_train_chk          (),
    .rtu_ifu_train_taken        (),
    .rtu_ifu_train_is_cond      (),
    .rtu_ifu_train_is_jal       (),
    .rtu_ifu_train_is_jalr      (),

    // ===================== §6.2 后端冲刷 (D11 的 FLUSH_1) =====================
    .rtu_backend_flush          (),

    // ===================== §6.2 核内重定向事件 (D13) =====================
    .rtu_core_redirect          (),

    // ===================== §6.2 提交窗口广播 (给 LSU) =====================
    .rtu_yy_xx_commit0          (),
    .rtu_yy_xx_commit1          (),
    .rtu_yy_xx_commit2          (),
    .rtu_yy_xx_commit0_iid      (),
    .rtu_yy_xx_commit1_iid      (),
    .rtu_yy_xx_commit2_iid      (),

    // ===================== §6.2 异步冲刷 (给 LSU) =====================
    .rtu_lsu_async_flush        (),

    // ===================== §6.2 BEU: D1 的最旧门控 + 冲刷屏蔽 =====================
    .rtu_beu_retire_iid         (),
    .rtu_beu_flush_chgflw_mask  (),

    // ===================== §6.2 重命名级 =====================
    .rtu_disp_stall             (),
    .rtu_ren_recover_vld        (),
    .rtu_ren_recover_map        (),
    .rtu_ren_flush              (),
    .rtu_ren_free_preg0         (),
    .rtu_ren_free_preg1         (),
    .rtu_ren_free_preg2         (),
    .rtu_ren_free_vld0          (),
    .rtu_ren_free_vld1          (),
    .rtu_ren_free_vld2          (),

    // ---- 派遣回执 ----
    .rtu_disp_vld0              (),
    .rtu_disp_vld1              (),
    .rtu_disp_vld2              (),
    .rtu_disp_iid0              (),
    .rtu_disp_iid1              (),
    .rtu_disp_iid2              (),

    // ===================== §6.2 物理寄存器堆访问 (A1) =====================
    .rtu_preg_raddr0            (),
    .rtu_preg_raddr1            (),
    .rtu_preg_raddr2            (),
    .rtu_csr_src_raddr          (),
    .rtu_csr_rd_we              (),
    .rtu_csr_rd_addr            (),
    .rtu_csr_rd_wdata           (),

    // ===================== §6.2 提交点副作用 =====================
    .rtu_store_vld0             (),
    .rtu_store_vld1             (),
    .rtu_store_vld2             (),
    .rtu_store_sq_id0           (),
    .rtu_store_sq_id1           (),
    .rtu_store_sq_id2           (),
    .rtu_csr_we                 (),
    .rtu_csr_addr               (),
    .rtu_csr_wdata              (),
    .rtu_trap_vld               (),
    .rtu_mret_vld               (),
    .rtu_trap_epc               (),
    .rtu_trap_tval              (),
    .rtu_trap_cause             (),
    .rtu_retire_cnt             (),

    // ===================== §6.2 difftest / debug =====================
    .dbg_commit_vld0            (),
    .dbg_commit_vld1            (),
    .dbg_commit_vld2            (),
    .dbg_commit_pc0             (),
    .dbg_commit_pc1             (),
    .dbg_commit_pc2             (),
    .dbg_commit_ena0            (),
    .dbg_commit_ena1            (),
    .dbg_commit_ena2            (),
    .dbg_commit_reg0            (),
    .dbg_commit_reg1            (),
    .dbg_commit_reg2            (),
    .dbg_commit_value0          (),
    .dbg_commit_value1          (),
    .dbg_commit_value2          ()
);

// ============================================================
// BIU
// ============================================================
ct_biu_top #(
    .PA_WIDTH       (32),
    .ID_WIDTH       (4),
    .DATA_WIDTH     (128),
    .STRB_WIDTH     (16),
    .LEN_WIDTH      (2)
) u_ct_biu_top (
    .forever_cpuclk         (),
    .cpurst_b               (),

    //---------------------------------------------------------
    // IFU read request
    //---------------------------------------------------------
    .ifu_biu_araddr         (),
    .ifu_biu_arlen          (),
    .ifu_biu_arsize         (),
    .ifu_biu_arburst        (),
    .ifu_biu_arcache        (),
    .ifu_biu_arprot         (),
    .ifu_biu_arvalid        (),
    .ifu_biu_arready        (),
    .ifu_biu_rid            (),

    //---------------------------------------------------------
    // IFU read response
    //---------------------------------------------------------
    .biu_ifu_rdata          (),
    .biu_ifu_rvalid         (),
    .biu_ifu_rlast          (),
    .biu_ifu_rresp          (),
    .biu_ifu_rid            (),
    .ifu_biu_rready         (),

    //---------------------------------------------------------
    // LSU read request
    //---------------------------------------------------------
    .lsu_biu_araddr         (lsu_biu_araddr),
    .lsu_biu_arid           (lsu_biu_arid),
    .lsu_biu_arlen          (lsu_biu_arlen),
    .lsu_biu_arsize         (lsu_biu_arsize),
    .lsu_biu_arburst        (lsu_biu_arburst),
    .lsu_biu_arcache        (lsu_biu_arcache),
    .lsu_biu_arprot         (lsu_biu_arprot),
    .lsu_biu_arvalid        (lsu_biu_arvalid),
    .lsu_biu_arready        (lsu_biu_arready),

    //---------------------------------------------------------
    // LSU read response
    //---------------------------------------------------------
    .biu_lsu_rdata          (biu_lsu_rdata),
    .biu_lsu_rid            (biu_lsu_rid),
    .biu_lsu_rvalid         (biu_lsu_rvalid),
    .biu_lsu_rlast          (biu_lsu_rlast),
    .biu_lsu_rresp          (biu_lsu_rresp),
    .lsu_biu_rready         (lsu_biu_rready),

    //---------------------------------------------------------
    // LSU write source 0: store
    //---------------------------------------------------------
    .lsu_biu_aw_st_addr     (lsu_biu_aw_st_addr),
    .lsu_biu_aw_st_id       (lsu_biu_aw_st_id),
    .lsu_biu_aw_st_len      (lsu_biu_aw_st_len),
    .lsu_biu_aw_st_size     (lsu_biu_aw_st_size),
    .lsu_biu_aw_st_burst    (lsu_biu_aw_st_burst),
    .lsu_biu_aw_st_cache    (lsu_biu_aw_st_cache),
    .lsu_biu_aw_st_prot     (lsu_biu_aw_st_prot),
    .lsu_biu_aw_st_valid    (lsu_biu_aw_st_valid),
    .lsu_biu_aw_st_ready    (lsu_biu_aw_st_ready),

    .lsu_biu_w_st_data      (lsu_biu_w_st_data),
    .lsu_biu_w_st_strb      (lsu_biu_w_st_strb),
    .lsu_biu_w_st_last      (lsu_biu_w_st_last),
    .lsu_biu_w_st_valid     (lsu_biu_w_st_valid),
    .lsu_biu_w_st_ready     (lsu_biu_w_st_ready),

    //---------------------------------------------------------
    // LSU write source 1: victim
    //---------------------------------------------------------
    .lsu_biu_aw_vict_addr   (lsu_biu_aw_vict_addr),
    .lsu_biu_aw_vict_id     (lsu_biu_aw_vict_id),
    .lsu_biu_aw_vict_len    (lsu_biu_aw_vict_len),
    .lsu_biu_aw_vict_size   (lsu_biu_aw_vict_size),
    .lsu_biu_aw_vict_burst  (lsu_biu_aw_vict_burst),
    .lsu_biu_aw_vict_cache  (lsu_biu_aw_vict_cache),
    .lsu_biu_aw_vict_prot   (lsu_biu_aw_vict_prot),
    .lsu_biu_aw_vict_valid  (lsu_biu_aw_vict_valid),
    .lsu_biu_aw_vict_ready  (lsu_biu_aw_vict_ready),

    .lsu_biu_w_vict_data    (lsu_biu_w_vict_data),
    .lsu_biu_w_vict_strb    (lsu_biu_w_vict_strb),
    .lsu_biu_w_vict_last    (lsu_biu_w_vict_last),
    .lsu_biu_w_vict_valid   (lsu_biu_w_vict_valid),
    .lsu_biu_w_vict_ready   (lsu_biu_w_vict_ready),

    //---------------------------------------------------------
    // LSU write response
    //---------------------------------------------------------
    .biu_lsu_bid            (biu_lsu_bid),
    .biu_lsu_bresp          (biu_lsu_bresp),
    .biu_lsu_bvalid         (biu_lsu_bvalid),
    .lsu_biu_bready         (lsu_biu_bready),

    //---------------------------------------------------------
    // AXI master read address
    //---------------------------------------------------------
    .biu_pad_araddr         (biu_pad_araddr),
    .biu_pad_arid           (biu_pad_arid),
    .biu_pad_arlen          (biu_pad_arlen),
    .biu_pad_arsize         (biu_pad_arsize),
    .biu_pad_arburst        (biu_pad_arburst),
    .biu_pad_arcache        (biu_pad_arcache),
    .biu_pad_arprot         (biu_pad_arprot),
    .biu_pad_arvalid        (biu_pad_arvalid),
    .pad_biu_arready        (pad_biu_arready),

    //---------------------------------------------------------
    // AXI master read data
    //---------------------------------------------------------
    .pad_biu_rdata          (pad_biu_rdata),
    .pad_biu_rid            (pad_biu_rid),
    .pad_biu_rlast          (pad_biu_rlast),
    .pad_biu_rresp          (pad_biu_rresp),
    .pad_biu_rvalid         (pad_biu_rvalid),
    .biu_pad_rready         (biu_pad_rready),

    //---------------------------------------------------------
    // AXI master write address
    //---------------------------------------------------------
    .biu_pad_awaddr         (biu_pad_awaddr),
    .biu_pad_awid           (biu_pad_awid),
    .biu_pad_awlen          (biu_pad_awlen),
    .biu_pad_awsize         (biu_pad_awsize),
    .biu_pad_awburst        (biu_pad_awburst),
    .biu_pad_awcache        (biu_pad_awcache),
    .biu_pad_awprot         (biu_pad_awprot),
    .biu_pad_awvalid        (biu_pad_awvalid),
    .pad_biu_awready        (pad_biu_awready),

    //---------------------------------------------------------
    // AXI master write data
    //---------------------------------------------------------
    .biu_pad_wdata          (biu_pad_wdata),
    .biu_pad_wstrb          (biu_pad_wstrb),
    .biu_pad_wlast          (biu_pad_wlast),
    .biu_pad_wvalid         (biu_pad_wvalid),
    .pad_biu_wready         (pad_biu_wready),

    //---------------------------------------------------------
    // AXI master write response
    //---------------------------------------------------------
    .pad_biu_bid            (pad_biu_bid),
    .pad_biu_bresp          (pad_biu_bresp),
    .pad_biu_bvalid         (pad_biu_bvalid),
    .biu_pad_bready         (biu_pad_bready)
);

endmodule