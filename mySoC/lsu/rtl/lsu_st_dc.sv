module ct_lsu_st_dc #(
    parameter LSIQ_ENTRY = 12,
    parameter SDIQ_ENTRY = 4
)(
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,

    // dcache borrow / array
    input  logic         dcache_arb_st_dc_borrow_vld,
    input  logic [4:0]   dcache_lsu_st_dirty_dout,
    input  logic [43:0]  dcache_lsu_st_tag_dout,

    // commit / flush
    input  logic         rtu_yy_xx_flush,

    // dcache dirty write port check
    input  logic         dcache_dirty_gwen,
    input  logic [4:0]   dcache_idx,

    // SQ
    input  logic         lq_st_dc_spec_fail,
    input  logic         sq_st_dc_full,
    input  logic         sq_st_dc_inst_hit,

    // from ST AG
    input  logic         st_ag_boundary,
    input  logic [31:0]  st_ag_dc_addr0,
    input  logic [15:0]  st_ag_dc_bytes_vld,
    input  logic         st_ag_dc_inst_vld,
    input  logic [3:0]   st_ag_dc_rot_sel,
    input  logic [6:0]   st_ag_iid,
    input  logic         st_ag_inst_vld,
    input  logic [11:0]  st_ag_lsid,
    input  logic         st_ag_old,
    input  logic [3:0]  st_ag_sdid_oh,
    input  logic         st_ag_secd,

    // outputs
    output logic         st_dc_inst_vld,
    output logic         st_dc_borrow_vld,
    output logic         st_dc_secd,
    output logic [6:0]   st_dc_iid,
    output logic [11:0]  st_dc_lsid,
    output logic [11:0]  st_dc_sdid_oh,
    output logic         st_dc_old,
    output logic [15:0]  st_dc_bytes_vld,
    output logic [3:0]   st_dc_rot_sel,
    output logic         st_dc_boundary,
    output logic [31:0]  st_dc_addr0,
    output logic [3:0]   st_dc_sdid,
    output logic         st_dc_sq_create_vld,
    output logic         st_dc_sq_create_dp_vld,
    output logic         st_dc_sq_create_gateclk_en,
    output logic         st_dc_sq_data_vld,
    output logic         st_dc_boundary_first,
    output logic         st_dc_chk_st_inst_vld,
    output logic [7:0]   st_dc_rot_sel_rev,
    output logic         st_dc_da_inst_vld,
    output logic [43:0]  st_dc_da_dcache_tag_array,
    output logic [4:0]   st_dc_da_dcache_dirty_array,
    output logic         st_dc_da_tag0_hit,
    output logic         st_dc_da_tag1_hit,
    output logic [11:0]  st_dc_idu_sq_full,
    output logic         st_dc_dcwp_hit_idx,
    output logic         st_dc_spec_fail,
    output logic [SDIQ_ENTRY-1:0] lsu_idu_has_in_sq
);

    //==========================================================
    //                 Internal signals
    //==========================================================
    logic [7:0]  st_dc_data_rot_sel;
    logic [11:0] st_dc_mask_lsid;
    logic        st_dc_sq_full_vld;
    logic        st_dc_restart_vld;

    //==========================================================
    //                 Pipeline Register
    //==========================================================
    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            st_dc_inst_vld <= 1'b0;
        else if (rtu_yy_xx_flush)
            st_dc_inst_vld <= 1'b0;
        else if (st_ag_dc_inst_vld)
            st_dc_inst_vld <= 1'b1;
        else
            st_dc_inst_vld <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            st_dc_borrow_vld <= 1'b0;
        else if (dcache_arb_st_dc_borrow_vld)
            st_dc_borrow_vld <= 1'b1;
        else
            st_dc_borrow_vld <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            st_dc_secd                    <= 1'b0;
            st_dc_iid[6:0]                <= 7'b0;
            st_dc_lsid[LSIQ_ENTRY-1:0]    <= {LSIQ_ENTRY{1'b0}};
            st_dc_sdid_oh[SDIQ_ENTRY-1:0] <= {SDIQ_ENTRY{1'b0}};
            st_dc_old                     <= 1'b0;
            st_dc_bytes_vld[15:0]         <= 16'b0;
            st_dc_rot_sel[3:0]            <= 4'b0;
            st_dc_boundary                <= 1'b0;
        end
        else if (st_ag_inst_vld) begin
            st_dc_secd                    <= st_ag_secd;
            st_dc_iid[6:0]                <= st_ag_iid[6:0];
            st_dc_lsid[LSIQ_ENTRY-1:0]    <= st_ag_lsid[LSIQ_ENTRY-1:0];
            st_dc_sdid_oh[SDIQ_ENTRY-1:0] <= st_ag_sdid_oh[SDIQ_ENTRY-1:0];
            st_dc_old                     <= st_ag_old;
            st_dc_bytes_vld[15:0]         <= st_ag_dc_bytes_vld[15:0];
            st_dc_rot_sel[3:0]            <= st_ag_dc_rot_sel[3:0];
            st_dc_boundary                <= st_ag_boundary;
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            st_dc_addr0[31:0] <= {32{1'b0}};
        else if (st_ag_inst_vld || dcache_arb_st_dc_borrow_vld)
            st_dc_addr0[31:0] <= st_ag_dc_addr0[31:0];
    end


    //==========================================================
    //                  dcache write port conflict check
    //==========================================================
`ifdef DCACHE_1KB
assign st_dc_dcwp_hit_idx = dcache_dirty_gwen
                            &&  (st_dc_addr0[8:5]  ==  dcache_idx[3:0]);
`elsif DCACHE_2KB
assign st_dc_dcwp_hit_idx = dcache_dirty_gwen
                            &&  (st_dc_addr0[9:5]  ==  dcache_idx[4:0]);
`elsif DCACHE_4KB
assign st_dc_dcwp_hit_idx = dcache_dirty_gwen
                            &&  (st_dc_addr0[10:5]  ==  dcache_idx[5:0]);
`else
assign st_dc_dcwp_hit_idx = 1'b0;
`endif



    //==========================================================
    //                 Create load queue
    //==========================================================
    assign st_dc_sq_create_vld = st_dc_inst_vld && !sq_st_dc_inst_hit;

    assign st_dc_sq_create_dp_vld     = st_dc_sq_create_vld;
    assign st_dc_sq_create_gateclk_en = st_dc_sq_create_dp_vld;

    assign st_dc_sq_data_vld = 1'b0;

    assign st_dc_boundary_first = st_dc_boundary && !st_dc_secd;

    //==========================================================
    //        Generate check signal to lq/ld_dc stage
    //==========================================================
    assign st_dc_chk_st_inst_vld = st_dc_inst_vld;

    //==========================================================
    //        data pre_select
    //==========================================================
    always_comb begin
        casez (st_dc_rot_sel[3:0])
            4'h0: st_dc_data_rot_sel[7:0] = 8'b00000001;
            4'h1: st_dc_data_rot_sel[7:0] = 8'b00000010;
            4'h2: st_dc_data_rot_sel[7:0] = 8'b00000100;
            4'h3: st_dc_data_rot_sel[7:0] = 8'b00001000;
            4'h4: st_dc_data_rot_sel[7:0] = 8'b00010000;
            4'h5: st_dc_data_rot_sel[7:0] = 8'b00100000;
            4'h6: st_dc_data_rot_sel[7:0] = 8'b01000000;
            4'h7: st_dc_data_rot_sel[7:0] = 8'b10000000;
            default: st_dc_data_rot_sel[7:0] = {8{1'bx}};
        endcase
    end

    assign st_dc_rot_sel_rev[7:0] = {st_dc_data_rot_sel[1],
                                     st_dc_data_rot_sel[2],
                                     st_dc_data_rot_sel[3],
                                     st_dc_data_rot_sel[4],
                                     st_dc_data_rot_sel[5],
                                     st_dc_data_rot_sel[6],
                                     st_dc_data_rot_sel[7],
                                     st_dc_data_rot_sel[0]};

    //==========================================================
    //                 Restart signal
    //==========================================================
    assign st_dc_spec_fail = lq_st_dc_spec_fail;


    assign st_dc_sq_full_vld = st_dc_sq_create_dp_vld && sq_st_dc_full;
    assign st_dc_restart_vld = st_dc_sq_full_vld;

    //==========================================================
    //        Generate to DA stage signal
    //==========================================================
    assign st_dc_da_inst_vld = st_dc_inst_vld && !st_dc_restart_vld;

    assign st_dc_da_dcache_tag_array[43:0] = dcache_lsu_st_tag_dout[43:0];
    assign st_dc_da_dcache_dirty_array[4:0] = dcache_lsu_st_dirty_dout[4:0];

    assign st_dc_da_tag0_hit = (st_dc_addr0[31:10] == dcache_lsu_st_tag_dout[21:0]);
    assign st_dc_da_tag1_hit = (st_dc_addr0[31:10] == dcache_lsu_st_tag_dout[43:22]);

    //==========================================================
    //        Generate lsiq signal
    //==========================================================
    assign st_dc_mask_lsid[LSIQ_ENTRY-1:0] = {LSIQ_ENTRY{st_dc_inst_vld}} &
                                             st_dc_lsid[LSIQ_ENTRY-1:0];


    assign st_dc_idu_sq_full[LSIQ_ENTRY-1:0] = {LSIQ_ENTRY{st_dc_sq_full_vld}} &
                                                 st_dc_mask_lsid[LSIQ_ENTRY-1:0];

    assign lsu_idu_has_in_sq[SDIQ_ENTRY-1:0] = {SDIQ_ENTRY{st_dc_sq_create_vld & !sq_st_dc_full}} &
                                                st_dc_sdid_oh[SDIQ_ENTRY-1:0];

endmodule