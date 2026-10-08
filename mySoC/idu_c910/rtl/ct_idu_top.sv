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
  output logic [24:0]  idu_biq_chk
);

//==========================================================
// Internal Signal Declarations
//==========================================================
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
logic [63:0]  dp_aiq_create0_data;
logic [63:0]  dp_aiq_create1_data;
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
  .cpurst_b                              (cpurst_b),
  .ctrl_ir_stall                              (ctrl_ir_stall),
  .ctrl_rt_inst0_vld                     (),//in
  .ctrl_rt_inst1_vld                     (),//in
  .ctrl_rt_inst2_vld                     (),//in
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
  .ctrl_xx_is_inst0_sel                  (ctrl_xx_is_inst0_sel)
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
  .dp_div_create1_data                   (dp_div_create1_data)
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
  .lsu_sq_sdiq_unalign_sdiq              (lsu_sq_sdiq_unalign_sdiq),
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
  .prf_dp_rf_pipe6_src1_data                              (prf_dp_rf_pipe6_src1_data)
);

endmodule
