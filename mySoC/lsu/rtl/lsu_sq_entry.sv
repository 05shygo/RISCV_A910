module ct_lsu_sq_entry #(
    parameter SQ_ENTRY   = 6,
    parameter LSIQ_ENTRY = 8,
    parameter IID_WIDTH  = 7
)(
    //==========================================================
    // Clock / Reset
    //==========================================================
    input  logic                  cpurst_b,
    input  logic                  forever_cpuclk,

    //==========================================================
    // dcache write port
    //==========================================================
    input  logic [4:0]            dcache_dirty_din,
    input  logic                  dcache_dirty_gwen,
    input  logic [4:0]            dcache_dirty_wen,
    input  logic [4:0]            dcache_idx,
    input  logic [43:0]           dcache_tag_din,
    input  logic                  dcache_tag_gwen,
    input  logic [1:0]            dcache_tag_wen,

    //==========================================================
    // from LD DA / LD DC
    //==========================================================
    input  logic [LSIQ_ENTRY-1:0] ld_da_lsid,
    input  logic [31:0]           ld_dc_addr0,
    input  logic [7:0]            ld_dc_addr1_11to4,
    input  logic [15:0]           ld_dc_bytes_vld,
    input  logic [15:0]           ld_dc_bytes_vld1,
    input  logic                  ld_dc_chk_ld_addr1_vld,
    input  logic                  ld_dc_chk_ld_bypass_vld,
    input  logic                  ld_dc_chk_ld_inst_vld,
    input  logic [IID_WIDTH-1:0]  ld_dc_iid,

    //==========================================================
    // RTU
    //==========================================================
    input  logic         rtu_yy_xx_commit0,
    input  logic [6:0]   rtu_yy_xx_commit0_iid,
    input  logic         rtu_yy_xx_commit1,
    input  logic [6:0]   rtu_yy_xx_commit1_iid,
    input  logic         rtu_yy_xx_commit2,
    input  logic [6:0]   rtu_yy_xx_commit2_iid,
    input  logic                  rtu_yy_xx_flush,

    //==========================================================
    // SD
    //==========================================================
    input  logic                  sd_ex1_inst_vld,
    input  logic [3:0]            sd_rf_ex1_sdid,

    //==========================================================
    // SQ create
    //==========================================================
    input  logic                  sq_age_vec_set,
    input  logic [SQ_ENTRY-1:0]   sq_create_age_vec,
    input  logic                  sq_create_pop_clk,
    input  logic                  sq_create_same_addr_newest,
    input  logic                  sq_create_success,
    input  logic [SQ_ENTRY-1:0]   sq_create_vld,
    input  logic [31:0]           sq_data_settle,

    //==========================================================
    // SQ entry interface
    //==========================================================
    input  logic                  sq_entry_create_vld_x,
    input  logic                  sq_entry_data_discard_grnt_x,
    input  logic                  sq_entry_fwd_multi_depd_set_x,
    input  logic [SQ_ENTRY-1:0]   sq_entry_pop_to_ce_grnt_b,
    input  logic                  sq_entry_pop_to_ce_grnt_x,
    input  logic                  sq_pop_ptr_x,

    //==========================================================
    // ST DA
    //==========================================================
    input  logic [IID_WIDTH-1:0]  st_da_iid,
    input  logic                  st_da_inst_vld,
    input  logic                  st_da_secd,
    input  logic                  st_da_sq_dcache_dirty,
    input  logic                  st_da_sq_dcache_valid,
    input  logic                  st_da_sq_dcache_way,
    input  logic                  st_da_sq_no_restart,

    //==========================================================
    // ST DC
    //==========================================================
    input  logic [31:0]           st_dc_addr0,
    input  logic                  st_dc_boundary,
    input  logic                  st_dc_boundary_first,
    input  logic [15:0]           st_dc_bytes_vld,
    input  logic [IID_WIDTH-1:0]  st_dc_iid,
    input  logic [7:0]            st_dc_rot_sel_rev,
    input  logic [3:0]            st_dc_sdid,
 //   input  logic                  st_dc_sdid_hit,
    input  logic                  st_dc_secd,
    input  logic                  st_dc_sq_data_vld,

    //==========================================================
    // WMB
    //==========================================================
    input  logic                  wmb_sq_pop_grnt,

    //==========================================================
    // SQ entry output
    //==========================================================
    output logic [31:0]           sq_entry_addr0_v,
    output logic                  sq_entry_addr1_dep_discard_x,
    output logic                  sq_entry_age_vec_surplus1_ptr_x,
    output logic                  sq_entry_age_vec_zero_ptr_x,
    output logic [15:0]           sq_entry_bytes_vld_v,
    output logic                  sq_entry_cancel_acc_req_x,
    output logic                  sq_entry_cmit_data_vld_x,
    output logic                  sq_entry_cmit_x,
    output logic [LSIQ_ENTRY-1:0] sq_entry_data_depd_wakeup_v,

    output logic                  sq_entry_data_discard_req_x,
    output logic [31:0]           sq_entry_data_v,
    output logic                  sq_entry_dcache_dirty_x,
    output logic                  sq_entry_dcache_info_vld_x,
    output logic                  sq_entry_dcache_valid_x,
    output logic                  sq_entry_dcache_way_x,
    output logic                  sq_entry_depd_set_x,
    output logic                  sq_entry_depd_x,
    output logic                  sq_entry_discard_req_x,
    output logic                  sq_entry_fwd_req_x,
    output logic [IID_WIDTH-1:0]  sq_entry_iid_v,
    output logic                  sq_entry_inst_hit_x,
    output logic                  sq_entry_pop_req_x,
    output logic [7:0]            sq_entry_rot_sel_v,
    output logic                  sq_entry_same_addr_newest_x,
    output logic                  sq_entry_settle_data_hit_x,
    output logic                  sq_entry_st_dc_create_age_vec_x,
    output logic                  sq_entry_st_dc_same_addr_newer_x,
    output logic                  sq_entry_vld_x
);

    //==========================================================
    //                 Internal registers
    //==========================================================
    logic [31:0]           sq_entry_addr0;
    logic [SQ_ENTRY-1:0]   sq_entry_age_vec;
    logic [SQ_ENTRY-1:0]   sq_entry_age_vec_1;
    logic                  sq_entry_bond_first_only;
    logic                  sq_entry_boundary;
    logic [15:0]           sq_entry_bytes_vld;
    logic                  sq_entry_cmit;
    logic                  sq_entry_cmit0_iid_hit;
    logic                  sq_entry_cmit1_iid_hit;
    logic                  sq_entry_cmit2_iid_hit;
    logic [31:0]           sq_entry_data;
    logic                  sq_entry_data_set_ff;
    logic                  sq_entry_data_vld;
    logic                  sq_entry_dcache_dirty;
    logic                  sq_entry_dcache_info_vld;
    logic                  sq_entry_dcache_valid;
    logic                  sq_entry_dcache_way;
    logic                  sq_entry_depd;
    logic [IID_WIDTH-1:0]  sq_entry_iid;
    logic                  sq_entry_in_wmb_ce;
    logic                  sq_entry_no_restart;
    logic [7:0]            sq_entry_rot_sel;
    logic                  sq_entry_same_addr_newest;
    logic [3:0]            sq_entry_sdid;
    logic                  sq_entry_secd;
    logic                  sq_entry_st_data_sdid_hit;
    logic                  sq_entry_vld;
    logic [LSIQ_ENTRY-1:0] sq_entry_wakeup_queue;

    //==========================================================
    //                 Internal wires
    //==========================================================
    logic                  sq_bond_secd_create_vld;
    logic                  sq_entry_addr1_dep_discard;
    logic                  sq_entry_addr_11to4_hit_st_dc;
    logic [SQ_ENTRY-1:0]   sq_entry_age_vec_create;
    logic                  sq_entry_age_vec_less2;
    logic [SQ_ENTRY-1:0]   sq_entry_age_vec_next;
    logic                  sq_entry_age_vec_surplus1_ptr;
    logic                  sq_entry_age_vec_zero;
    logic                  sq_entry_age_vec_zero_ptr;
    logic                  sq_entry_and_ld_dc_bytes_vld1_hit;
    logic                  sq_entry_and_ld_dc_bytes_vld_hit;
    logic                  sq_entry_cancel_acc_req;
    logic                  sq_entry_cmit0_iid_pre_hit;
    logic                  sq_entry_cmit1_iid_pre_hit;
    logic                  sq_entry_cmit2_iid_pre_hit;
    logic                  sq_entry_cmit_data_not_vld;
    logic                  sq_entry_cmit_data_vld;
    logic                  sq_entry_cmit_hit0;
    logic                  sq_entry_cmit_hit1;
    logic                  sq_entry_cmit_hit2;
    logic                  sq_entry_cmit_set;
    logic                  sq_entry_create_vld;
    logic [LSIQ_ENTRY-1:0] sq_entry_data_depd_wakeup;
    logic                  sq_entry_data_depd_wakeup_vld;
    logic                  sq_entry_data_discard_grnt;
    logic                  sq_entry_data_discard_req;
    logic                  sq_entry_data_discard_req_short;
    logic                  sq_entry_data_set;
    logic                  sq_entry_data_vld_now;
    logic                  sq_entry_dcache_update_vld;
    logic                  sq_entry_dcache_update_vld_unmask;
    logic                  sq_entry_depd_addr0_11to4_hit;
    logic                  sq_entry_depd_addr1_11to4_hit;
    logic                  sq_entry_depd_addr1_tto4_hit;
    logic                  sq_entry_depd_addr_tto12_hit;
    logic                  sq_entry_depd_addr_tto4_hit;
    logic                  sq_entry_depd_bv1_do_hit;
    logic                  sq_entry_depd_exact_hit;
    logic                  sq_entry_depd_hit1;
    logic                  sq_entry_depd_hit4;
    logic                  sq_entry_depd_hit5;
    logic                  sq_entry_depd_hit6;
    logic                  sq_entry_depd_hit7;
    logic                  sq_entry_depd_hit8;
    logic                  sq_entry_depd_part_hit;
    logic                  sq_entry_depd_set;
    logic                  sq_entry_depd_whole_hit;
    logic                  sq_entry_discard_req;
    logic                  sq_entry_flush_pop_vld;
    logic [31:0]           sq_entry_from_ld_dc_addr0;
    logic                  sq_entry_fwd_bypass_req;
    logic                  sq_entry_fwd_multi_depd_set;
    logic                  sq_entry_fwd_req;
    logic                  sq_entry_iid_newer_than_st_dc;
    logic                  sq_entry_iid_older_than_ld_dc;
    logic                  sq_entry_inst_hit;
    logic                  sq_entry_newer_than_st_dc;
    logic                  sq_entry_not_and_ld_dc_bytes_vld_hit;
    logic                  sq_entry_older_than_ld_dc;
    logic                  sq_entry_pop_req;
    logic                  sq_entry_pop_to_ce_grnt;
    logic                  sq_entry_pop_vld;
    logic                  sq_entry_same_addr_newest_clr;
    logic                  sq_entry_sdid_hit;
    logic                  sq_entry_settle_data_hit;
    logic                  sq_entry_st_da_info_set;
    logic                  sq_entry_st_dc_bv_do_hit;
    logic                  sq_entry_st_dc_create_age_vec;
    logic                  sq_entry_st_dc_same_addr_newer;
    logic                  sq_entry_update_dcache_dirty;
    logic                  sq_entry_update_dcache_valid;
    logic                  sq_entry_update_dcache_way;
    logic                  sq_pop_ptr;

    //==========================================================
    //                 Register
    //==========================================================
    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_vld <= 1'b0;
        else if (sq_entry_pop_vld || sq_entry_flush_pop_vld)
            sq_entry_vld <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_vld <= 1'b1;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_in_wmb_ce <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_in_wmb_ce <= 1'b0;
        else if (sq_entry_pop_to_ce_grnt)
            sq_entry_in_wmb_ce <= 1'b1;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_same_addr_newest <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_same_addr_newest <= sq_create_same_addr_newest;
        else if (sq_entry_same_addr_newest_clr)
            sq_entry_same_addr_newest <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            sq_entry_iid[IID_WIDTH-1:0]  <= {IID_WIDTH{1'b0}};
            sq_entry_sdid[3:0]           <= 4'b0;
            sq_entry_boundary            <= 1'b0;
            sq_entry_secd                <= 1'b0;
            sq_entry_addr0[31:0]         <= 32'b0;
            sq_entry_bytes_vld[15:0]     <= 16'b0;
            sq_entry_rot_sel[7:0]        <= 8'b0;
        end
        else if (sq_entry_create_vld) begin
            sq_entry_iid[IID_WIDTH-1:0]  <= st_dc_iid[IID_WIDTH-1:0];
            sq_entry_sdid[3:0]           <= st_dc_sdid[3:0];
            sq_entry_boundary            <= st_dc_boundary;
            sq_entry_secd                <= st_dc_secd;
            sq_entry_addr0[31:0]         <= st_dc_addr0[31:0];
            sq_entry_bytes_vld[15:0]     <= st_dc_bytes_vld[15:0];
            sq_entry_rot_sel[7:0]        <= st_dc_rot_sel_rev[7:0];
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_cmit <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_cmit <= 1'b0;
        else if (sq_entry_cmit_set)
            sq_entry_cmit <= 1'b1;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_data_vld <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_data_vld <= st_dc_sq_data_vld;
        else if (sq_entry_data_set)
            sq_entry_data_vld <= 1'b1;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_data_set_ff <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_data_set_ff <= 1'b0;
        else if (sq_entry_data_set)
            sq_entry_data_set_ff <= 1'b1;
        else
            sq_entry_data_set_ff <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_wakeup_queue[LSIQ_ENTRY-1:0] <= {LSIQ_ENTRY{1'b0}};
        else if (sq_entry_data_set && !sq_entry_data_discard_grnt ||
                 sq_entry_data_set_ff || rtu_yy_xx_flush)
            sq_entry_wakeup_queue[LSIQ_ENTRY-1:0] <= {LSIQ_ENTRY{1'b0}};
        else if (sq_entry_data_set && sq_entry_data_discard_grnt)
            sq_entry_wakeup_queue[LSIQ_ENTRY-1:0] <= ld_da_lsid[LSIQ_ENTRY-1:0];
        else if (sq_entry_data_discard_grnt)
            sq_entry_wakeup_queue[LSIQ_ENTRY-1:0] <= ld_da_lsid[LSIQ_ENTRY-1:0]
                                                     | sq_entry_wakeup_queue[LSIQ_ENTRY-1:0];
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_data[31:0] <= 32'b0;
        else if (sq_entry_data_set)
            sq_entry_data[31:0] <= sq_data_settle[31:0];
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            sq_entry_dcache_info_vld  <= 1'b0;
            sq_entry_no_restart       <= 1'b0;
        end
        else if (sq_entry_create_vld) begin
            sq_entry_dcache_info_vld  <= 1'b0;
            sq_entry_no_restart       <= 1'b0;
        end
        else if (sq_entry_st_da_info_set) begin
            sq_entry_dcache_info_vld  <= 1'b1;
            sq_entry_no_restart       <= st_da_sq_no_restart;
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            sq_entry_dcache_valid     <= 1'b0;
            sq_entry_dcache_dirty     <= 1'b0;
            sq_entry_dcache_way       <= 1'b0;
        end
        else if (sq_entry_dcache_update_vld) begin
            sq_entry_dcache_valid     <= sq_entry_update_dcache_valid;
            sq_entry_dcache_dirty     <= sq_entry_update_dcache_dirty;
            sq_entry_dcache_way       <= sq_entry_update_dcache_way;
        end
        else if (sq_entry_st_da_info_set) begin
            sq_entry_dcache_valid     <= st_da_sq_dcache_valid;
            sq_entry_dcache_dirty     <= st_da_sq_dcache_dirty;
            sq_entry_dcache_way       <= st_da_sq_dcache_way;
        end
    end

    always_ff @(posedge sq_create_pop_clk) begin
        if (sq_entry_create_vld)
            sq_entry_age_vec[SQ_ENTRY-1:0] <= sq_create_age_vec[SQ_ENTRY-1:0];
        else if (sq_age_vec_set && sq_entry_vld)
            sq_entry_age_vec[SQ_ENTRY-1:0] <= sq_entry_age_vec_next[SQ_ENTRY-1:0];
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_depd <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_depd <= 1'b0;
        else if (sq_entry_depd_set)
            sq_entry_depd <= 1'b1;
    end


    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_st_data_sdid_hit <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_st_data_sdid_hit <= 1'b0;//st_dc_sdid_hit;
        else if (sq_entry_vld && !sq_entry_data_vld)
            sq_entry_st_data_sdid_hit <= sq_entry_sdid_hit;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_entry_bond_first_only <= 1'b0;
        else if (sq_entry_create_vld)
            sq_entry_bond_first_only <= st_dc_boundary_first;
        else if (sq_bond_secd_create_vld)
            sq_entry_bond_first_only <= 1'b0;
    end

    //==========================================================
    //      Generate cmit/st_da info/update signal
    //==========================================================
    assign sq_entry_cmit0_iid_pre_hit = (rtu_yy_xx_commit0_iid[IID_WIDTH-1:0] ==
                                         sq_entry_iid[IID_WIDTH-1:0]);
    assign sq_entry_cmit1_iid_pre_hit = (rtu_yy_xx_commit1_iid[IID_WIDTH-1:0] ==
                                         sq_entry_iid[IID_WIDTH-1:0]);
    assign sq_entry_cmit2_iid_pre_hit = (rtu_yy_xx_commit2_iid[IID_WIDTH-1:0] ==
                                         sq_entry_iid[IID_WIDTH-1:0]);

    assign sq_entry_cmit_hit0 = rtu_yy_xx_commit0 && sq_entry_cmit0_iid_pre_hit;
    assign sq_entry_cmit_hit1 = rtu_yy_xx_commit1 && sq_entry_cmit1_iid_pre_hit;
    assign sq_entry_cmit_hit2 = rtu_yy_xx_commit2 && sq_entry_cmit2_iid_pre_hit;

    assign sq_entry_cmit_set = (sq_entry_cmit_hit0 || sq_entry_cmit_hit1 || sq_entry_cmit_hit2)
                               && sq_entry_vld;

    assign sq_entry_cmit_data_not_vld = sq_entry_vld &&
                                        (sq_entry_cmit || sq_entry_cmit_set) &&
                                        !sq_entry_data_vld;

    assign sq_entry_cmit_data_vld = !sq_entry_cmit_data_not_vld;

    assign sq_entry_st_da_info_set = sq_entry_vld && st_da_inst_vld &&
                                     !sq_entry_no_restart &&
                                     (st_da_secd == sq_entry_secd) &&
                                     (st_da_iid[IID_WIDTH-1:0] == sq_entry_iid[IID_WIDTH-1:0]);

    assign sq_bond_secd_create_vld = sq_entry_vld && sq_create_success &&
                                     (sq_entry_iid[IID_WIDTH-1:0] == st_dc_iid[IID_WIDTH-1:0]) &&
                                     st_dc_secd;

    assign sq_entry_sdid_hit = sq_entry_sdid[3:0] == sd_rf_ex1_sdid[3:0];

    assign sq_entry_settle_data_hit = sq_entry_vld && !sq_entry_data_vld && sq_entry_st_data_sdid_hit;

    assign sq_entry_data_set = sq_entry_vld && !sq_entry_data_vld &&
                               sd_ex1_inst_vld && sq_entry_st_data_sdid_hit;

    assign sq_entry_addr_11to4_hit_st_dc = (sq_entry_addr0[11:4] == st_dc_addr0[11:4]);
    assign sq_entry_st_dc_bv_do_hit = |(st_dc_bytes_vld[15:0] & sq_entry_bytes_vld[15:0]);

    assign sq_entry_same_addr_newest_clr = sq_entry_vld && sq_create_success &&
                                           !sq_entry_newer_than_st_dc &&
                                           sq_entry_addr_11to4_hit_st_dc &&
                                           sq_entry_st_dc_bv_do_hit;

    assign sq_entry_st_dc_same_addr_newer = sq_entry_vld && sq_entry_newer_than_st_dc &&
                                            sq_entry_addr_11to4_hit_st_dc &&
                                            sq_entry_st_dc_bv_do_hit;

    assign sq_entry_inst_hit = sq_entry_vld && !sq_entry_no_restart &&
                               (sq_entry_secd == st_dc_secd) &&
                               (sq_entry_iid[IID_WIDTH-1:0] == st_dc_iid[IID_WIDTH-1:0]);

    //==========================================================
    //            Compare dcache write port(dcwp)
    //==========================================================
    lsu_dcache_info_update x_lsu_sq_entry_dcache_info_update (
        .compare_dcwp_addr      (sq_entry_addr0[31:0]              ),
        .compare_dcwp_hit_idx   (                                  ),
        .compare_dcwp_update_vld(sq_entry_dcache_update_vld_unmask ),
        .dcache_dirty_din       (dcache_dirty_din                  ),
        .dcache_dirty_gwen      (dcache_dirty_gwen                 ),
        .dcache_dirty_wen       (dcache_dirty_wen                  ),
        .dcache_idx             (dcache_idx                        ),
        .dcache_tag_din         (dcache_tag_din                    ),
        .dcache_tag_gwen        (dcache_tag_gwen                   ),
        .dcache_tag_wen         (dcache_tag_wen                    ),
        .origin_dcache_dirty    (sq_entry_dcache_dirty             ),
        .origin_dcache_valid    (sq_entry_dcache_valid             ),
        .origin_dcache_way      (sq_entry_dcache_way               ),
        .update_dcache_dirty    (sq_entry_update_dcache_dirty      ),
        .update_dcache_valid    (sq_entry_update_dcache_valid      ),
        .update_dcache_way      (sq_entry_update_dcache_way        )
    );

    assign sq_entry_dcache_update_vld = sq_entry_dcache_update_vld_unmask &&
                                        sq_entry_vld && sq_entry_dcache_info_vld;

    //==========================================================
    //                  Maintain Age Vector
    //==========================================================
    ct_rtu_compare_iid x_lsu_sq_entry_compare_st_dc_iid (
        .x_iid0       (st_dc_iid[IID_WIDTH-1:0]      ),
        .x_iid0_older (sq_entry_iid_newer_than_st_dc ),
        .x_iid1       (sq_entry_iid[IID_WIDTH-1:0]   )
    );

    assign sq_entry_newer_than_st_dc = !sq_entry_cmit && sq_entry_iid_newer_than_st_dc;

    assign sq_entry_st_dc_create_age_vec = sq_entry_vld && !sq_entry_in_wmb_ce &&
                                           !sq_entry_pop_to_ce_grnt &&
                                           !sq_entry_newer_than_st_dc;

    assign sq_entry_age_vec_create[SQ_ENTRY-1:0] =
        sq_create_vld[SQ_ENTRY-1:0] & {SQ_ENTRY{sq_entry_newer_than_st_dc}}
        | sq_entry_age_vec[SQ_ENTRY-1:0];

    assign sq_entry_age_vec_next[SQ_ENTRY-1:0] = sq_entry_pop_to_ce_grnt_b[SQ_ENTRY-1:0]
                                                 & sq_entry_age_vec_create[SQ_ENTRY-1:0];

    always_comb begin
        sq_entry_age_vec_1 = {SQ_ENTRY{1'b1}};
        for (int i = 0; i < SQ_ENTRY; i++) begin
            if (sq_entry_age_vec[i] && ~|(sq_entry_age_vec & ((1 << i) - 1)))
                sq_entry_age_vec_1[i] = 1'b0;
        end
    end

    assign sq_entry_age_vec_less2 = !(|(sq_entry_age_vec[SQ_ENTRY-1:0] &
                                        sq_entry_age_vec_1[SQ_ENTRY-1:0]));
    assign sq_entry_age_vec_zero  = !(|sq_entry_age_vec[SQ_ENTRY-1:0]);

    assign sq_entry_age_vec_zero_ptr = sq_entry_vld && !sq_entry_in_wmb_ce &&
                                       sq_entry_age_vec_zero;

    assign sq_entry_age_vec_surplus1_ptr = sq_entry_vld && !sq_entry_in_wmb_ce &&
                                           sq_entry_age_vec_less2 && !sq_entry_age_vec_zero;

    assign sq_entry_pop_req = sq_pop_ptr && sq_entry_vld && sq_entry_cmit &&
                              sq_entry_data_vld && sq_entry_no_restart &&
                              !sq_entry_in_wmb_ce;

    //==========================================================
    //                 Dependency check
    //==========================================================
    ct_rtu_compare_iid x_lsu_sq_entry_compare_ld_dc_iid (
        .x_iid0       (sq_entry_iid[IID_WIDTH-1:0]   ),
        .x_iid0_older (sq_entry_iid_older_than_ld_dc ),
        .x_iid1       (ld_dc_iid[IID_WIDTH-1:0]      )
    );

    assign sq_entry_older_than_ld_dc = sq_entry_iid_older_than_ld_dc || sq_entry_cmit;

    assign sq_entry_from_ld_dc_addr0[31:0] = ld_dc_addr0[31:0];
    assign sq_entry_depd_addr_tto12_hit  = (sq_entry_addr0[31:12] ==
                                            sq_entry_from_ld_dc_addr0[31:12]);
    assign sq_entry_depd_addr0_11to4_hit = sq_entry_addr0[11:4] == sq_entry_from_ld_dc_addr0[11:4];
    assign sq_entry_depd_addr1_11to4_hit = sq_entry_addr0[11:4] == ld_dc_addr1_11to4[7:0];

    assign sq_entry_depd_addr_tto4_hit = sq_entry_depd_addr_tto12_hit &&
                                         sq_entry_depd_addr0_11to4_hit;

    assign sq_entry_depd_addr1_tto4_hit = sq_entry_depd_addr_tto12_hit &&
                                          sq_entry_depd_addr1_11to4_hit;

    assign sq_entry_and_ld_dc_bytes_vld_hit     = |(sq_entry_bytes_vld[15:0] & ld_dc_bytes_vld[15:0]);
    assign sq_entry_not_and_ld_dc_bytes_vld_hit = |((~sq_entry_bytes_vld[15:0]) & ld_dc_bytes_vld[15:0]);
    assign sq_entry_and_ld_dc_bytes_vld1_hit    = |(sq_entry_bytes_vld[15:0] & ld_dc_bytes_vld1[15:0]);

    assign sq_entry_depd_whole_hit = sq_entry_and_ld_dc_bytes_vld_hit &&
                                     !sq_entry_not_and_ld_dc_bytes_vld_hit;
    assign sq_entry_depd_part_hit  = sq_entry_and_ld_dc_bytes_vld_hit &&
                                     sq_entry_not_and_ld_dc_bytes_vld_hit;
    assign sq_entry_depd_exact_hit = (sq_entry_bytes_vld[15:0] == ld_dc_bytes_vld[15:0]);
    assign sq_entry_depd_bv1_do_hit = sq_entry_and_ld_dc_bytes_vld1_hit;

    assign sq_entry_data_vld_now = sq_entry_data_vld || sq_entry_data_set;

    // 部分数据交集
    assign sq_entry_depd_hit1 = sq_entry_vld  &&
                                ld_dc_chk_ld_inst_vld && sq_entry_older_than_ld_dc &&
                                sq_entry_depd_addr_tto4_hit && sq_entry_depd_part_hit;

    // 跟 load 的第二半请求有数据交集
    assign sq_entry_depd_hit4 = sq_entry_vld  &&
                                ld_dc_chk_ld_addr1_vld && sq_entry_older_than_ld_dc &&
                                sq_entry_bond_first_only && sq_entry_depd_addr1_tto4_hit &&
                                sq_entry_depd_bv1_do_hit;

    // 数据完全覆盖，但是数据还没到来
    assign sq_entry_depd_hit6 = sq_entry_vld  &&
                                ld_dc_chk_ld_inst_vld && sq_entry_older_than_ld_dc &&
                                sq_entry_depd_addr_tto4_hit && !sq_entry_data_vld_now &&
                                sq_entry_depd_whole_hit;

    // 数据完全覆盖，并且数据到来了
    assign sq_entry_depd_hit7 = sq_entry_vld  &&
                                ld_dc_chk_ld_inst_vld && sq_entry_older_than_ld_dc &&
                                sq_entry_depd_addr_tto4_hit && sq_entry_data_vld_now &&
                                sq_entry_depd_whole_hit;



    // 跟 load 的第二半请求有数据交集，不能 cb 加速
    assign sq_entry_depd_hit8 = sq_entry_vld  &&
                                sq_entry_older_than_ld_dc && sq_entry_depd_addr1_tto4_hit &&
                                sq_entry_depd_bv1_do_hit;

    assign sq_entry_discard_req = sq_entry_depd_hit1 || sq_entry_depd_hit4;

    assign sq_entry_addr1_dep_discard = sq_entry_depd_hit4;

    assign sq_entry_data_discard_req = sq_entry_depd_hit6;

    assign sq_entry_fwd_req = sq_entry_depd_hit7;

    assign sq_entry_cancel_acc_req = sq_entry_depd_hit8;

    assign sq_entry_depd_set = sq_entry_discard_req || sq_entry_fwd_multi_depd_set;

    assign sq_entry_data_depd_wakeup_vld = sq_entry_data_set || sq_entry_data_set_ff;

    assign sq_entry_data_depd_wakeup[LSIQ_ENTRY-1:0] =
        {LSIQ_ENTRY{sq_entry_data_depd_wakeup_vld}} & sq_entry_wakeup_queue[LSIQ_ENTRY-1:0];

    //==========================================================
    //                 Generate pop signal
    //==========================================================
    assign sq_entry_flush_pop_vld = rtu_yy_xx_flush && !sq_entry_cmit;

    assign sq_entry_pop_vld = sq_entry_vld && sq_entry_in_wmb_ce && wmb_sq_pop_grnt;

    //==========================================================
    //                 Generate interface
    //==========================================================
    assign sq_entry_create_vld        = sq_entry_create_vld_x;
    assign sq_pop_ptr                 = sq_pop_ptr_x;
    assign sq_entry_data_discard_grnt = sq_entry_data_discard_grnt_x;
    assign sq_entry_fwd_multi_depd_set = sq_entry_fwd_multi_depd_set_x;
    assign sq_entry_pop_to_ce_grnt    = sq_entry_pop_to_ce_grnt_x;

    assign sq_entry_vld_x               = sq_entry_vld;
    assign sq_entry_inst_hit_x          = sq_entry_inst_hit;
    assign sq_entry_iid_v[IID_WIDTH-1:0]= sq_entry_iid[IID_WIDTH-1:0];
    assign sq_entry_same_addr_newest_x  = sq_entry_same_addr_newest;
    assign sq_entry_addr0_v[31:0]       = sq_entry_addr0[31:0];
    assign sq_entry_bytes_vld_v[15:0]   = sq_entry_bytes_vld[15:0];
    assign sq_entry_cmit_data_vld_x     = sq_entry_cmit_data_vld;
    assign sq_entry_data_v[31:0]        = sq_entry_data[31:0];
    assign sq_entry_rot_sel_v[7:0]      = sq_entry_rot_sel[7:0];
    assign sq_entry_dcache_valid_x      = sq_entry_dcache_valid;
    assign sq_entry_dcache_dirty_x      = sq_entry_dcache_dirty;
    assign sq_entry_dcache_way_x        = sq_entry_dcache_way;
    assign sq_entry_depd_x              = sq_entry_depd;
    assign sq_entry_dcache_info_vld_x   = sq_entry_dcache_info_vld;

    assign sq_entry_data_depd_wakeup_v[LSIQ_ENTRY-1:0] = sq_entry_data_depd_wakeup[LSIQ_ENTRY-1:0];
    assign sq_entry_discard_req_x       = sq_entry_discard_req;
    assign sq_entry_depd_set_x          = sq_entry_depd_set;
    assign sq_entry_pop_req_x           = sq_entry_pop_req;
    assign sq_entry_cmit_x              = sq_entry_cmit;

    assign sq_entry_age_vec_zero_ptr_x      = sq_entry_age_vec_zero_ptr;
    assign sq_entry_age_vec_surplus1_ptr_x  = sq_entry_age_vec_surplus1_ptr;
    assign sq_entry_st_dc_create_age_vec_x  = sq_entry_st_dc_create_age_vec;
    assign sq_entry_settle_data_hit_x       = sq_entry_settle_data_hit;
    assign sq_entry_st_dc_same_addr_newer_x = sq_entry_st_dc_same_addr_newer;
    assign sq_entry_addr1_dep_discard_x     = sq_entry_addr1_dep_discard;
    assign sq_entry_data_discard_req_x      = sq_entry_data_discard_req;
    assign sq_entry_fwd_req_x               = sq_entry_fwd_req;
    assign sq_entry_cancel_acc_req_x        = sq_entry_cancel_acc_req;

endmodule