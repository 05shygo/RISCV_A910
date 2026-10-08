// Copyright 2019-2021 T-Head Semiconductor Co., Ltd.
// Licensed under the Apache License, Version 2.0
// http://www.apache.org/licenses/LICENSE-2.0

module ct_lsu_sq #(
    parameter SQ_ENTRY   = 6,
    parameter LSIQ_ENTRY = 8,
    parameter IID_WIDTH  = 7
)(
    input  logic         cpurst_b,
    input  logic [4:0]   dcache_dirty_din,
    input  logic         dcache_dirty_gwen,
    input  logic [4:0]   dcache_dirty_wen,
    input  logic [4:0]   dcache_idx,
    input  logic [43:0]  dcache_tag_din,
    input  logic         dcache_tag_gwen,
    input  logic [1:0]   dcache_tag_wen,
    input  logic         forever_cpuclk,
    input  logic [7:0]  ld_da_lsid,
    input  logic         ld_da_sq_data_discard_vld,
    input  logic [SQ_ENTRY-1:0] ld_da_sq_fwd_id,
    input  logic         ld_da_sq_fwd_multi_vld,
    input  logic         ld_da_sq_global_discard_vld,
    input  logic [31:0]  ld_dc_addr0,
    input  logic [7:0]   ld_dc_addr1_11to4,
    input  logic [15:0]  ld_dc_bytes_vld,
    input  logic [15:0]  ld_dc_bytes_vld1,
    input  logic         ld_dc_chk_ld_addr1_vld,
    input  logic         ld_dc_chk_ld_bypass_vld,
    input  logic         ld_dc_chk_ld_inst_vld,
    input  logic [IID_WIDTH-1:0] ld_dc_iid,
    input  logic         rb_sq_pop_hit_idx,
    input  logic         rtu_lsu_async_flush,
    input  logic         rtu_yy_xx_commit0,
    input  logic [6:0]   rtu_yy_xx_commit0_iid,
    input  logic         rtu_yy_xx_commit1,
    input  logic [6:0]   rtu_yy_xx_commit1_iid,
    input  logic         rtu_yy_xx_commit2,
    input  logic [6:0]   rtu_yy_xx_commit2_iid,
    input  logic         rtu_yy_xx_flush,
    input  logic [31:0]  idu_lsu_rf_pipe5_src0,
    input  logic         idu_lsu_sdiq_sel,
    input  logic [3:0]   idu_lsu_rf_pipe5_sdiq_entry,
    input  logic [IID_WIDTH-1:0] st_da_iid,
    input  logic         st_da_inst_vld,
    input  logic         st_da_secd,
    input  logic         st_da_sq_dcache_dirty,
    input  logic         st_da_sq_dcache_valid,
    input  logic         st_da_sq_dcache_way,
    input  logic         st_da_sq_no_restart,
    input  logic [31:0]  st_dc_addr0,
    input  logic         st_dc_boundary,
    input  logic         st_dc_boundary_first,
    input  logic [15:0]  st_dc_bytes_vld,
    input  logic [IID_WIDTH-1:0] st_dc_iid,
    input  logic         st_dc_old,
    input  logic [7:0]   st_dc_rot_sel_rev,
    input  logic [3:0]   st_dc_sdid,
  //  input  logic         st_dc_sdid_hit,
    input  logic         st_dc_secd,
    input  logic         st_dc_sq_create_vld,
    input  logic         st_dc_sq_data_vld,
    input  logic [31:0]  wmb_ce_addr,
    input  logic [SQ_ENTRY-1:0] wmb_ce_sq_ptr,
    input  logic         wmb_sq_pop_grnt,
    input  logic         wmb_sq_pop_to_ce_grnt,

    output logic [LSIQ_ENTRY-1:0] sq_data_depd_wakeup,
    output logic [LSIQ_ENTRY-1:0] sq_global_depd_wakeup,
    output logic [31:0]  sq_ld_da_fwd_data,
    output logic         sq_ld_dc_addr1_dep_discard,
    output logic         sq_ld_dc_cancel_acc_req,
    output logic         sq_ld_dc_data_discard_req,
    output logic [SQ_ENTRY-1:0] sq_ld_dc_fwd_id,
    output logic         sq_ld_dc_fwd_multi,
    output logic         sq_ld_dc_fwd_multi_mask,
    output logic         sq_ld_dc_fwd_req,
    output logic         sq_ld_dc_other_discard_req,
    output logic [31:0]  sq_pop_addr,
    output logic [15:0]  sq_pop_bytes_vld,
    output logic [SQ_ENTRY-1:0] sq_pop_ptr,
    output logic         sq_st_dc_full,
    output logic         sq_st_dc_inst_hit,
    output logic         sq_wmb_merge_stall_req,
    output logic         sq_wmb_pop_to_ce_req,
    output logic [127:0] wmb_ce_data128,
    output logic         wmb_ce_update_dcache_dirty,
    output logic         wmb_ce_update_dcache_valid,
    output logic         wmb_ce_update_dcache_way,
    output logic         lsu_idu_sq_not_full
);

    localparam int PA_WIDTH = 32;
    localparam logic [1:0] BYTE  = 2'b00;
    localparam logic [1:0] HALF  = 2'b01;
    localparam logic [1:0] WORD  = 2'b10;
    localparam logic [1:0] DWORD = 2'b11;

    //==========================================================
    // Registers
    //==========================================================
    logic [SQ_ENTRY-1:0] sq_create_ptr;
    logic [SQ_ENTRY-1:0] sq_data_discard_id_sel;
    logic [31:0]         sq_pe_age_vec_surplus1_addr;
    logic [15:0]         sq_pe_age_vec_surplus1_bytes_vld;
    logic [31:0]         sq_pe_age_vec_zero_addr;
    logic [15:0]         sq_pe_age_vec_zero_bytes_vld;
    logic                sq_pop_depd_ff;
    logic [LSIQ_ENTRY-1:0] sq_wakeup_queue;
    logic [31:0]         wmb_ce_data32;

    //==========================================================
    // Wires
    //==========================================================
    logic                sq_age_vec_set;
    logic                sq_clk;
    logic [SQ_ENTRY-1:0] sq_create_age_vec;
    logic                sq_create_pop_clk;
    logic                sq_create_same_addr_newest;
    logic                sq_create_success;
    logic [SQ_ENTRY-1:0] sq_create_vld;
    logic [127:0]         sq_data_after_rot;
    logic                sq_data_discard_has_newest;
    logic [SQ_ENTRY-1:0] sq_data_discard_newest_id;
    logic                sq_data_discard_req;
    logic                sq_data_discard_req_short;
    logic [127:0]         sq_data_ori;
    logic [31:0]         sq_data_settle;
    logic                sq_empty_less2;
    logic [SQ_ENTRY-1:0] sq_entry_addr1_dep_discard;
    logic [SQ_ENTRY-1:0] sq_entry_age_vec_surplus1_ptr;
    logic [SQ_ENTRY-1:0] sq_entry_age_vec_zero_ptr;
    logic [SQ_ENTRY-1:0] sq_entry_cancel_acc_req;
    logic [SQ_ENTRY-1:0] sq_entry_cmit;
    logic [SQ_ENTRY-1:0] sq_entry_cmit_data_vld;
    logic [SQ_ENTRY-1:0] sq_entry_create_vld;
    logic [SQ_ENTRY-1:0] sq_entry_data_discard_grnt;
    logic [SQ_ENTRY-1:0] sq_entry_data_discard_req;
    logic [SQ_ENTRY-1:0] sq_entry_data_discard_req_short;
    logic [SQ_ENTRY-1:0] sq_entry_dcache_dirty;
    logic [SQ_ENTRY-1:0] sq_entry_dcache_info_vld;
    logic [SQ_ENTRY-1:0] sq_entry_dcache_valid;
    logic [SQ_ENTRY-1:0] sq_entry_dcache_way;
    logic [SQ_ENTRY-1:0] sq_entry_depd;
    logic [SQ_ENTRY-1:0] sq_entry_depd_set;
    logic [SQ_ENTRY-1:0] sq_entry_discard_req;
    logic [SQ_ENTRY-1:0] sq_entry_fwd_bypass_req;
    logic [SQ_ENTRY-1:0] sq_entry_fwd_multi_depd_set;
    logic [SQ_ENTRY-1:0] sq_entry_fwd_req;
    logic [SQ_ENTRY-1:0] sq_entry_inst_hit;
    logic [SQ_ENTRY-1:0] sq_entry_pop_req;
    logic [SQ_ENTRY-1:0] sq_entry_pop_to_ce_grnt;
    logic [SQ_ENTRY-1:0] sq_entry_pop_to_ce_grnt_b;
    logic [SQ_ENTRY-1:0] sq_entry_same_addr_newest;
    logic [SQ_ENTRY-1:0] sq_entry_settle_data_hit;
    logic [SQ_ENTRY-1:0] sq_entry_st_dc_create_age_vec;
    logic [SQ_ENTRY-1:0] sq_entry_st_dc_same_addr_newer;
    logic [SQ_ENTRY-1:0] sq_entry_vld;
    logic [SQ_ENTRY-1:0] sq_entry_wakeup_queue_set_id;
    logic                sq_full;
    logic                sq_fwd_bypass_req;
    logic                sq_fwd_multi;
    logic                sq_fwd_req;
    logic [SQ_ENTRY-1:0] sq_fwd_req_id;
    logic                sq_has_cmit;
    logic                sq_newest_fwd_bypass_req;
    logic                sq_newest_fwd_req;
    logic                sq_newest_fwd_req_data_vld_short;
    logic [SQ_ENTRY-1:0] sq_newest_fwd_req_id;
    logic                sq_pe_sel_age_vec_surplus1_entry_vld;
    logic                sq_pe_sel_age_vec_zero_entry_vld;
    logic                sq_pop_clk;
    logic                sq_pop_req_unmask;
    logic                sq_pop_to_ce_req;
    logic [7:0]          sq_settle_rot_sel;
    logic                sq_wakeup_queue_clk;
    logic [LSIQ_ENTRY-1:0] sq_wakeup_queue_grnt;
    logic [LSIQ_ENTRY-1:0] sq_wakeup_queue_next;
    logic                wmb_ce_dcache_hit_idx;
    logic                wmb_ce_dcache_update_vld;
    logic                wmb_ce_dcache_way;
    logic                wmb_ce_depd;
    logic                wmb_ce_depd_set;

    // -----------------------------------------------------------------------
    // 本地时钟驱动（2026-10-08 补, 三个一起放这里 —— 它们的声明分散在 116/172/176,
    // 连续赋值必须写在三处声明之后, 否则前面的引用算未声明)
    //
    // ⚠️ C910 工厂版在这里例化了门控时钟单元 (forever_cpuclk + 各 *_gateclk_en
    //    → ct_clk_cell), **交付时那批单元被整体剥掉** ⇒ 这三个时钟全仓无驱动。
    //    后果是**整个存储队列不在跑**:
    //      * `sq_clk`          —— sq_pop_depd_ff (弹出依赖标志);
    //      * `sq_pop_clk`      —— 弹出地址/掩码/指针 (没有复位, 纯"条件成立就装"型);
    //      * `sq_wakeup_queue_clk` —— 重启唤醒队列。
    //    即 SQ 的弹出侧全部冻结 ⇒ store 永远弹不出去。
    //
    // 本模块的 forever_cpuclk 端口一直存在 (端口表 :20, 且 lsu_top:1264 已连)。
    // 各 always_ff 内部自带使能条件 (cpurst_b / rtu_yy_xx_flush / *_vld),
    // 所以直接接 forever_cpuclk 功能等价, 只是少了时钟门控的省电效果。
    // -----------------------------------------------------------------------
    assign sq_clk              = forever_cpuclk;
    assign sq_pop_clk          = forever_cpuclk;
    assign sq_wakeup_queue_clk = forever_cpuclk;

    //==========================================================
    // Entry arrays
    //==========================================================
    logic [31:0] sq_entry_addr0 [0:SQ_ENTRY-1];
    logic [15:0] sq_entry_bytes_vld [0:SQ_ENTRY-1];
    logic [31:0] sq_entry_data [0:SQ_ENTRY-1];
    logic [IID_WIDTH-1:0] sq_entry_iid [0:SQ_ENTRY-1];
    logic [7:0]  sq_entry_rot_sel [0:SQ_ENTRY-1];
    logic [7:0]  sq_entry_data_depd_wakeup [0:SQ_ENTRY-1];

    //==========================================================
    // SQ entry instances
    //==========================================================
    genvar i ;
    generate
        for (i = 0; i < SQ_ENTRY; i++) begin : gen_sq_entry
            ct_lsu_sq_entry #(
                .SQ_ENTRY   (SQ_ENTRY),
                .LSIQ_ENTRY (LSIQ_ENTRY),
                .IID_WIDTH  (IID_WIDTH)
            ) x_ct_lsu_sq_entry (
                .cpurst_b                                  (cpurst_b),
                .forever_cpuclk                            (forever_cpuclk),
                .dcache_dirty_din                          (dcache_dirty_din),
                .dcache_dirty_gwen                         (dcache_dirty_gwen),
                .dcache_dirty_wen                          (dcache_dirty_wen),
                .dcache_idx                                (dcache_idx),
                .dcache_tag_din                            (dcache_tag_din),
                .dcache_tag_gwen                           (dcache_tag_gwen),
                .dcache_tag_wen                            (dcache_tag_wen),
                .ld_da_lsid                                (ld_da_lsid),
                .ld_dc_addr0                               (ld_dc_addr0),
                .ld_dc_addr1_11to4                         (ld_dc_addr1_11to4),
                .ld_dc_bytes_vld                           (ld_dc_bytes_vld),
                .ld_dc_bytes_vld1                          (ld_dc_bytes_vld1),
                .ld_dc_chk_ld_addr1_vld                    (ld_dc_chk_ld_addr1_vld),
                .ld_dc_chk_ld_bypass_vld                   (ld_dc_chk_ld_bypass_vld),
                .ld_dc_chk_ld_inst_vld                     (ld_dc_chk_ld_inst_vld),
                .ld_dc_iid                                 (ld_dc_iid),
                .rtu_yy_xx_commit0                         (rtu_yy_xx_commit0),
                .rtu_yy_xx_commit0_iid                     (rtu_yy_xx_commit0_iid),
                .rtu_yy_xx_commit1                         (rtu_yy_xx_commit1),
                .rtu_yy_xx_commit1_iid                     (rtu_yy_xx_commit1_iid),
                .rtu_yy_xx_commit2                         (rtu_yy_xx_commit2),
                .rtu_yy_xx_commit2_iid                     (rtu_yy_xx_commit2_iid),
                .rtu_yy_xx_flush                           (rtu_yy_xx_flush),
                .sd_ex1_inst_vld                           (idu_lsu_sdiq_sel),
                .sd_rf_ex1_sdid                            (idu_lsu_rf_pipe5_sdiq_entry),
                .sq_age_vec_set                            (sq_age_vec_set),
                .sq_create_age_vec                         (sq_create_age_vec),
                .sq_create_pop_clk                         (sq_create_pop_clk),
                .sq_create_same_addr_newest                (sq_create_same_addr_newest),
                .sq_create_success                         (sq_create_success),
                .sq_create_vld                             (sq_create_vld),
                .sq_data_settle                            (sq_data_settle),
                .sq_entry_create_vld_x                     (sq_entry_create_vld[i]),
                .sq_entry_data_discard_grnt_x              (sq_entry_data_discard_grnt[i]),
                .sq_entry_fwd_multi_depd_set_x             (sq_entry_fwd_multi_depd_set[i]),
                .sq_entry_pop_to_ce_grnt_b                 (sq_entry_pop_to_ce_grnt_b),
                .sq_entry_pop_to_ce_grnt_x                 (sq_entry_pop_to_ce_grnt[i]),
                .sq_pop_ptr_x                              (sq_pop_ptr[i]),
                .st_da_iid                                 (st_da_iid),
                .st_da_inst_vld                            (st_da_inst_vld),
                .st_da_secd                                (st_da_secd),
                .st_da_sq_dcache_dirty                     (st_da_sq_dcache_dirty),
                .st_da_sq_dcache_valid                     (st_da_sq_dcache_valid),
                .st_da_sq_dcache_way                       (st_da_sq_dcache_way),
                .st_da_sq_no_restart                       (st_da_sq_no_restart),
                .st_dc_addr0                               (st_dc_addr0),
                .st_dc_boundary                            (st_dc_boundary),
                .st_dc_boundary_first                      (st_dc_boundary_first),
                .st_dc_bytes_vld                           (st_dc_bytes_vld),
                .st_dc_iid                                 (st_dc_iid),
                .st_dc_rot_sel_rev                         (st_dc_rot_sel_rev),
                .st_dc_sdid                                (st_dc_sdid),
            //    .st_dc_sdid_hit                            (st_dc_sdid_hit),
                .st_dc_secd                                (st_dc_secd),
                .st_dc_sq_data_vld                         (st_dc_sq_data_vld),
                .wmb_sq_pop_grnt                           (wmb_sq_pop_grnt),
                .sq_entry_addr0_v                          (sq_entry_addr0[i]),
                .sq_entry_addr1_dep_discard_x              (sq_entry_addr1_dep_discard[i]),
                .sq_entry_age_vec_surplus1_ptr_x           (sq_entry_age_vec_surplus1_ptr[i]),
                .sq_entry_age_vec_zero_ptr_x               (sq_entry_age_vec_zero_ptr[i]),
                .sq_entry_bytes_vld_v                      (sq_entry_bytes_vld[i]),
                .sq_entry_cancel_acc_req_x                 (sq_entry_cancel_acc_req[i]),
                .sq_entry_cmit_data_vld_x                  (sq_entry_cmit_data_vld[i]),
                .sq_entry_cmit_x                           (sq_entry_cmit[i]),
                .sq_entry_data_depd_wakeup_v               (sq_entry_data_depd_wakeup[i]),
                .sq_entry_data_discard_req_x               (sq_entry_data_discard_req[i]),
                .sq_entry_data_v                           (sq_entry_data[i]),
                .sq_entry_dcache_dirty_x                   (sq_entry_dcache_dirty[i]),
                .sq_entry_dcache_info_vld_x                (sq_entry_dcache_info_vld[i]),
                .sq_entry_dcache_valid_x                   (sq_entry_dcache_valid[i]),
                .sq_entry_dcache_way_x                     (sq_entry_dcache_way[i]),
                .sq_entry_depd_set_x                       (sq_entry_depd_set[i]),
                .sq_entry_depd_x                           (sq_entry_depd[i]),
                .sq_entry_discard_req_x                    (sq_entry_discard_req[i]),
                .sq_entry_fwd_req_x                        (sq_entry_fwd_req[i]),
                .sq_entry_iid_v                            (sq_entry_iid[i]),
                .sq_entry_inst_hit_x                       (sq_entry_inst_hit[i]),
                .sq_entry_pop_req_x                        (sq_entry_pop_req[i]),
                .sq_entry_rot_sel_v                        (sq_entry_rot_sel[i]),
                .sq_entry_same_addr_newest_x               (sq_entry_same_addr_newest[i]),
                .sq_entry_settle_data_hit_x                (sq_entry_settle_data_hit[i]),
                .sq_entry_st_dc_create_age_vec_x           (sq_entry_st_dc_create_age_vec[i]),
                .sq_entry_st_dc_same_addr_newer_x          (sq_entry_st_dc_same_addr_newer[i]),
                .sq_entry_vld_x                            (sq_entry_vld[i])
            );
        end
    endgenerate

    //==========================================================
    // Generate full/create signal
    //==========================================================
    always_comb begin
        sq_create_ptr = {SQ_ENTRY{1'b0}};
        casez (sq_entry_vld[SQ_ENTRY-1:0])
            6'b????_?0: sq_create_ptr[0] = 1'b1;
            6'b????_01: sq_create_ptr[1] = 1'b1;
            6'b???0_11: sq_create_ptr[2] = 1'b1;
            6'b??01_11: sq_create_ptr[3] = 1'b1;
            6'b?011_11: sq_create_ptr[4] = 1'b1;
            6'b0111_11: sq_create_ptr[5] = 1'b1;
            default: sq_create_ptr = {SQ_ENTRY{1'b0}};
        endcase
    end

    assign sq_has_cmit = |(sq_entry_cmit[SQ_ENTRY-1:0] & sq_entry_vld[SQ_ENTRY-1:0]);
    assign sq_full = &sq_entry_vld[SQ_ENTRY-1:0];
    assign sq_empty_less2 = &(sq_entry_vld[SQ_ENTRY-1:0] | sq_create_ptr[SQ_ENTRY-1:0]);
    assign sq_st_dc_inst_hit = |sq_entry_inst_hit[SQ_ENTRY-1:0];
    assign sq_st_dc_full = sq_full || (!st_dc_old && sq_empty_less2 && !sq_has_cmit);
    assign sq_create_success = st_dc_sq_create_vld && !sq_st_dc_full && !rtu_yy_xx_flush;

    assign lsu_idu_sq_not_full = !sq_empty_less2;

    assign sq_entry_create_vld = {SQ_ENTRY{sq_create_success}} & sq_create_ptr;
    assign sq_create_same_addr_newest = &(~sq_entry_st_dc_same_addr_newer[SQ_ENTRY-1:0]);
    assign sq_create_vld = sq_entry_create_vld;
    assign sq_create_age_vec = sq_entry_st_dc_create_age_vec;
    assign sq_age_vec_set = sq_create_success || wmb_sq_pop_to_ce_grnt;

    //==========================================================
    // Settle data
    //==========================================================
    assign sq_data_ori = {idu_lsu_rf_pipe5_src0, idu_lsu_rf_pipe5_src0, idu_lsu_rf_pipe5_src0, idu_lsu_rf_pipe5_src0};
    assign sq_settle_rot_sel = {8{sq_entry_settle_data_hit[0]}} & sq_entry_rot_sel[0] |
                               {8{sq_entry_settle_data_hit[1]}} & sq_entry_rot_sel[1] |
                               {8{sq_entry_settle_data_hit[2]}} & sq_entry_rot_sel[2] |
                               {8{sq_entry_settle_data_hit[3]}} & sq_entry_rot_sel[3] |
                               {8{sq_entry_settle_data_hit[4]}} & sq_entry_rot_sel[4] |
                               {8{sq_entry_settle_data_hit[5]}} & sq_entry_rot_sel[5];

    ct_lsu_rot_data x_lsu_sq_data_rot_to_mem_format (
        .data_in         (sq_data_ori),
        .data_settle_out (sq_data_after_rot),
        .rot_sel         (sq_settle_rot_sel)
    );
    assign sq_data_settle = sq_data_after_rot[31:0];

    //==========================================================
    // SQ to LD DC depd/discard
    //==========================================================
    assign sq_ld_dc_other_discard_req = |sq_entry_discard_req;
    assign sq_ld_dc_addr1_dep_discard = |sq_entry_addr1_dep_discard;
    assign sq_ld_dc_cancel_acc_req = |sq_entry_cancel_acc_req;

    assign sq_data_discard_req = |sq_entry_data_discard_req;
    assign sq_fwd_req = |sq_entry_fwd_req;
    assign sq_newest_fwd_req_id = sq_entry_fwd_req & sq_entry_same_addr_newest;
    assign sq_newest_fwd_req = |sq_newest_fwd_req_id;

    assign sq_ld_dc_fwd_req = sq_fwd_req;

    assign sq_ld_dc_data_discard_req = sq_data_discard_req &&  !sq_newest_fwd_req;
    assign sq_ld_dc_fwd_id = sq_fwd_req_id;
    assign sq_fwd_req_id = sq_newest_fwd_req ? sq_newest_fwd_req_id : sq_entry_fwd_req;

    always_comb begin
        sq_fwd_multi = 1'b1;
        case (sq_entry_fwd_req)
            6'b000000,
            6'b000001,
            6'b000010,
            6'b000100,
            6'b001000,
            6'b010000,
            6'b100000: sq_fwd_multi = 1'b0;
            default: sq_fwd_multi = 1'b1;
        endcase
    end
    assign sq_ld_dc_fwd_multi = sq_fwd_multi;
    assign sq_ld_dc_fwd_multi_mask = sq_newest_fwd_req;

    //==========================================================
    // Forward data to LD DA
    //==========================================================
    always_comb begin
        case (ld_da_sq_fwd_id)
            6'h01: sq_ld_da_fwd_data = sq_entry_data[0];
            6'h02: sq_ld_da_fwd_data = sq_entry_data[1];
            6'h04: sq_ld_da_fwd_data = sq_entry_data[2];
            6'h08: sq_ld_da_fwd_data = sq_entry_data[3];
            6'h10: sq_ld_da_fwd_data = sq_entry_data[4];
            6'h20: sq_ld_da_fwd_data = sq_entry_data[5];
            default: sq_ld_da_fwd_data = {32{1'bx}};
        endcase
    end

    //==========================================================
    // LD DA to SQ depd/discard
    //==========================================================
    assign sq_entry_fwd_multi_depd_set = {SQ_ENTRY{ld_da_sq_fwd_multi_vld}} &
                                         ld_da_sq_fwd_id & sq_entry_vld;

    always_comb begin
        sq_data_discard_id_sel = {SQ_ENTRY{1'b0}};
        casez (ld_da_sq_fwd_id)
            6'b1?????: sq_data_discard_id_sel[5] = 1'b1;
            6'b01????: sq_data_discard_id_sel[4] = 1'b1;
            6'b001???: sq_data_discard_id_sel[3] = 1'b1;
            6'b0001??: sq_data_discard_id_sel[2] = 1'b1;
            6'b00001?: sq_data_discard_id_sel[1] = 1'b1;
            6'b000001: sq_data_discard_id_sel[0] = 1'b1;
            default: sq_data_discard_id_sel = {SQ_ENTRY{1'b0}};
        endcase
    end

    assign sq_data_discard_newest_id = sq_entry_same_addr_newest & ld_da_sq_fwd_id;
    assign sq_data_discard_has_newest = |sq_data_discard_newest_id;
    assign sq_entry_wakeup_queue_set_id = sq_data_discard_has_newest
                                          ? sq_data_discard_newest_id
                                          : sq_data_discard_id_sel;
    assign sq_entry_data_discard_grnt = {SQ_ENTRY{ld_da_sq_data_discard_vld}} &
                                        sq_entry_wakeup_queue_set_id;

    //==========================================================
    // Maintain restart wakeup queue
    //==========================================================
    always_ff @(posedge sq_wakeup_queue_clk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_wakeup_queue <= {LSIQ_ENTRY{1'b0}};
        else if (rtu_yy_xx_flush)
            sq_wakeup_queue <= {LSIQ_ENTRY{1'b0}};
        else if (ld_da_sq_global_discard_vld || sq_pop_depd_ff)
            sq_wakeup_queue <= sq_wakeup_queue_next;
    end

    always_ff @(posedge sq_clk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_pop_depd_ff <= 1'b0;
        else if (wmb_sq_pop_grnt && (wmb_ce_depd || wmb_ce_depd_set))
            sq_pop_depd_ff <= 1'b1;
        else
            sq_pop_depd_ff <= 1'b0;
    end

    assign sq_wakeup_queue_grnt = sq_wakeup_queue |
                                  ({LSIQ_ENTRY{ld_da_sq_global_discard_vld}} & ld_da_lsid);
    assign sq_wakeup_queue_next = sq_pop_depd_ff ? {LSIQ_ENTRY{1'b0}} : sq_wakeup_queue_grnt;
    assign sq_global_depd_wakeup = sq_pop_depd_ff ? sq_wakeup_queue_grnt : {LSIQ_ENTRY{1'b0}};

    assign sq_data_depd_wakeup = sq_entry_data_depd_wakeup[0] |
                                 sq_entry_data_depd_wakeup[1] |
                                 sq_entry_data_depd_wakeup[2] |
                                 sq_entry_data_depd_wakeup[3] |
                                 sq_entry_data_depd_wakeup[4] |
                                 sq_entry_data_depd_wakeup[5];

    //==========================================================
    // Pop entry
    //==========================================================
    always_ff @(posedge sq_pop_clk) begin
        if (sq_pe_sel_age_vec_zero_entry_vld) begin
            sq_pop_addr        <= sq_pe_age_vec_zero_addr[31:0];
            sq_pop_bytes_vld   <= sq_pe_age_vec_zero_bytes_vld;
            sq_pop_ptr         <= sq_entry_age_vec_zero_ptr;
        end
        else if (sq_pe_sel_age_vec_surplus1_entry_vld) begin
            sq_pop_addr        <= sq_pe_age_vec_surplus1_addr[31:0];
            sq_pop_bytes_vld   <= sq_pe_age_vec_surplus1_bytes_vld;
            sq_pop_ptr         <= sq_entry_age_vec_surplus1_ptr;
        end
    end

    assign sq_pe_sel_age_vec_zero_entry_vld = |(sq_entry_age_vec_zero_ptr & (~sq_entry_dcache_info_vld));
    assign sq_pe_sel_age_vec_surplus1_entry_vld = wmb_sq_pop_to_ce_grnt;

    always_comb begin
        case (sq_entry_age_vec_zero_ptr)
            6'h01: sq_pe_age_vec_zero_addr = sq_entry_addr0[0][31:0];
            6'h02: sq_pe_age_vec_zero_addr = sq_entry_addr0[1][31:0];
            6'h04: sq_pe_age_vec_zero_addr = sq_entry_addr0[2][31:0];
            6'h08: sq_pe_age_vec_zero_addr = sq_entry_addr0[3][31:0];
            6'h10: sq_pe_age_vec_zero_addr = sq_entry_addr0[4][31:0];
            6'h20: sq_pe_age_vec_zero_addr = sq_entry_addr0[5][31:0];
            default: sq_pe_age_vec_zero_addr = {PA_WIDTH{1'bx}};
        endcase
    end

    always_comb begin
        case (sq_entry_age_vec_zero_ptr)
            6'h01: sq_pe_age_vec_zero_bytes_vld = sq_entry_bytes_vld[0];
            6'h02: sq_pe_age_vec_zero_bytes_vld = sq_entry_bytes_vld[1];
            6'h04: sq_pe_age_vec_zero_bytes_vld = sq_entry_bytes_vld[2];
            6'h08: sq_pe_age_vec_zero_bytes_vld = sq_entry_bytes_vld[3];
            6'h10: sq_pe_age_vec_zero_bytes_vld = sq_entry_bytes_vld[4];
            6'h20: sq_pe_age_vec_zero_bytes_vld = sq_entry_bytes_vld[5];
            default: sq_pe_age_vec_zero_bytes_vld = {16{1'bx}};
        endcase
    end


    always_comb begin
        case (sq_entry_age_vec_surplus1_ptr)
            6'h01: sq_pe_age_vec_surplus1_addr = sq_entry_addr0[0][31:0];
            6'h02: sq_pe_age_vec_surplus1_addr = sq_entry_addr0[1][31:0];
            6'h04: sq_pe_age_vec_surplus1_addr = sq_entry_addr0[2][31:0];
            6'h08: sq_pe_age_vec_surplus1_addr = sq_entry_addr0[3][31:0];
            6'h10: sq_pe_age_vec_surplus1_addr = sq_entry_addr0[4][31:0];
            6'h20: sq_pe_age_vec_surplus1_addr = sq_entry_addr0[5][31:0];
            default: sq_pe_age_vec_surplus1_addr = {PA_WIDTH{1'bx}};
        endcase
    end

    always_comb begin
        case (sq_entry_age_vec_surplus1_ptr)
            6'h01: sq_pe_age_vec_surplus1_bytes_vld = sq_entry_bytes_vld[0];
            6'h02: sq_pe_age_vec_surplus1_bytes_vld = sq_entry_bytes_vld[1];
            6'h04: sq_pe_age_vec_surplus1_bytes_vld = sq_entry_bytes_vld[2];
            6'h08: sq_pe_age_vec_surplus1_bytes_vld = sq_entry_bytes_vld[3];
            6'h10: sq_pe_age_vec_surplus1_bytes_vld = sq_entry_bytes_vld[4];
            6'h20: sq_pe_age_vec_surplus1_bytes_vld = sq_entry_bytes_vld[5];
            default: sq_pe_age_vec_surplus1_bytes_vld = {16{1'bx}};
        endcase
    end


    //==========================================================
    // Request WMB CE
    //==========================================================
    assign sq_pop_req_unmask = |sq_entry_pop_req;
    assign sq_pop_to_ce_req = sq_pop_req_unmask && !rtu_lsu_async_flush;
    assign sq_entry_pop_to_ce_grnt = {SQ_ENTRY{wmb_sq_pop_to_ce_grnt}} & sq_entry_pop_req;
    assign sq_entry_pop_to_ce_grnt_b = ~sq_entry_pop_to_ce_grnt;

    assign sq_wmb_pop_to_ce_req = sq_pop_to_ce_req;
    assign sq_wmb_merge_stall_req = rb_sq_pop_hit_idx;

    //==========================================================
    // WMB CE data path
    //==========================================================
    always_comb begin
        case (wmb_ce_sq_ptr)
            6'h01: wmb_ce_data32 = sq_entry_data[0];
            6'h02: wmb_ce_data32 = sq_entry_data[1];
            6'h04: wmb_ce_data32 = sq_entry_data[2];
            6'h08: wmb_ce_data32 = sq_entry_data[3];
            6'h10: wmb_ce_data32 = sq_entry_data[4];
            6'h20: wmb_ce_data32 = sq_entry_data[5];
            default: wmb_ce_data32 = {32{1'bx}};
        endcase
    end
    assign wmb_ce_data128 = {wmb_ce_data32, wmb_ce_data32, wmb_ce_data32, wmb_ce_data32};

    assign wmb_ce_dcache_valid = |(wmb_ce_sq_ptr & sq_entry_dcache_valid);
    assign wmb_ce_dcache_dirty = |(wmb_ce_sq_ptr & sq_entry_dcache_dirty);
    assign wmb_ce_dcache_way = |(wmb_ce_sq_ptr & sq_entry_dcache_way);
    assign wmb_ce_depd = |(wmb_ce_sq_ptr & sq_entry_depd);
    assign wmb_ce_depd_set = |(wmb_ce_sq_ptr & sq_entry_depd_set);


    //==========================================================
    // Compare dcache write port
    //==========================================================
    lsu_dcache_info_update x_lsu_wmb_ce_dcache_info_update (
        .compare_dcwp_addr       (wmb_ce_addr[31:0]),
        .compare_dcwp_hit_idx    (wmb_ce_dcache_hit_idx),
        .compare_dcwp_update_vld (wmb_ce_dcache_update_vld),
        .dcache_dirty_din        (dcache_dirty_din),
        .dcache_dirty_gwen       (dcache_dirty_gwen),
        .dcache_dirty_wen        (dcache_dirty_wen),
        .dcache_idx              (dcache_idx),
        .dcache_tag_din          (dcache_tag_din),
        .dcache_tag_gwen         (dcache_tag_gwen),
        .dcache_tag_wen          (dcache_tag_wen),
        .origin_dcache_dirty     (wmb_ce_dcache_dirty),
        .origin_dcache_valid     (wmb_ce_dcache_valid),
        .origin_dcache_way       (wmb_ce_dcache_way),
        .update_dcache_dirty     (wmb_ce_update_dcache_dirty),
        .update_dcache_valid     (wmb_ce_update_dcache_valid),
        .update_dcache_way       (wmb_ce_update_dcache_way)
    );

endmodule