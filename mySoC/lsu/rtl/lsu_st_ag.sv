module ct_lsu_st_ag #(
    parameter int DCACHE_SIZE = 2048, 
    parameter int LSIQ_ENTRY = 8, // 1024, 2048, or 4096 bytes
    parameter int SDIQ_ENTRY = 4,
    parameter int CACHELINE_SIZE = 32,
    parameter int NUM_WAYS = 2,
    parameter int OFFSET_WIDTH = 5,
    parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
    parameter int INDEX_WIDTH = $clog2(NUM_SETS)
)(
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [31:0]  dcache_arb_st_ag_addr,
    input  logic         dcache_arb_st_ag_borrow_addr_vld,
    input  logic         idu_lsu_st_sel,
    input  logic [1:0]   idu_lsu_st_inst_size,
    input  logic         idu_lsu_st_unalign_2nd,
    input  logic [6:0]   idu_lsu_st_iid,
    input  logic [LSIQ_ENTRY-1:0]  idu_lsu_st_lch_entry,
    input  logic [SDIQ_ENTRY-1:0]  idu_lsu_st_sdiq_entry,
    input  logic         idu_lsu_st_oldest,
    input  logic [11:0]  idu_lsu_st_offset,
    input  logic [12:0]  idu_lsu_st_offset_plus,
    input  logic [31:0]  idu_lsu_st_src0,
    input  logic         rtu_yy_xx_flush,
    input  logic         dcache_arb_ag_st_sel,

    output logic         ag_dcache_arb_st_dirty_gateclk_en,
    output logic [INDEX_WIDTH-1:0]   ag_dcache_arb_st_dirty_idx,
    output logic         ag_dcache_arb_st_dirty_req,
    output logic         ag_dcache_arb_st_tag_gateclk_en,
    output logic [INDEX_WIDTH-1:0]   ag_dcache_arb_st_tag_idx,
    output logic         ag_dcache_arb_st_tag_req,
    output logic         st_ag_boundary,
    output logic [31:0]  st_ag_dc_addr0,
    output logic [15:0]  st_ag_dc_bytes_vld,
    output logic         st_ag_dc_inst_vld,
    output logic [3:0]   st_ag_dc_rot_sel,
    output logic [6:0]   st_ag_iid,
    output logic         st_ag_inst_vld,
    output logic [LSIQ_ENTRY-1:0]   st_ag_lsid,
    output logic         st_ag_old,
    output logic [SDIQ_ENTRY-1:0]   st_ag_sdid_oh,
    output logic         st_ag_secd,
    output logic [LSIQ_ENTRY-1:0]   st_ag_stall_restart_entry
);
    localparam int INDEX_LSB = OFFSET_WIDTH;
    localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;

    localparam BYTE  = 2'b00,
               HALF  = 2'b01,
               WORD  = 2'b10,
               DWORD = 2'b11;

    localparam PC_LEN     = 15;

    //==========================================================
    //                 Pipeline Register
    //==========================================================
    logic st_ag_stall_vld;
    logic st_ag_stall_mask;
    logic st_ag_stall_restart;
    logic st_ag_dcache_stall_req;
    logic st_ag_dcache_stall_unmask;

    assign st_ag_dcache_stall_unmask = !dcache_arb_ag_st_sel;
    assign st_ag_dcache_stall_req = st_ag_dcache_stall_unmask && st_ag_inst_vld;
    assign st_ag_stall_vld = st_ag_dcache_stall_req && !st_ag_stall_mask;
    assign st_ag_stall_restart = st_ag_dcache_stall_req && st_ag_stall_mask;

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            st_ag_inst_vld <= 1'b0;
        else if (rtu_yy_xx_flush)
            st_ag_inst_vld <= 1'b0;
        else if (st_ag_stall_vld || idu_lsu_st_sel)
            st_ag_inst_vld <= 1'b1;
        else
            st_ag_inst_vld <= 1'b0;
    end

    logic [31:0] st_ag_base;
    logic [31:0] st_ag_offset;
    logic [12:0] st_ag_offset_plus;
    logic [1:0]  st_ag_inst_size;

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            st_ag_inst_size[1:0]          <= 2'b0;
            st_ag_secd                    <= 1'b0;
            st_ag_iid[6:0]                <= 7'b0;
            st_ag_lsid[LSIQ_ENTRY-1:0]    <= {LSIQ_ENTRY{1'b0}};
            st_ag_sdid_oh[SDIQ_ENTRY-1:0] <= {SDIQ_ENTRY{1'b0}};
            st_ag_old                     <= 1'b0;
        end
        else if (!st_ag_stall_vld && idu_lsu_st_sel) begin
            st_ag_inst_size[1:0]          <= idu_lsu_st_inst_size[1:0];
            st_ag_secd                    <= idu_lsu_st_unalign_2nd;
            st_ag_iid[6:0]                <= idu_lsu_st_iid[6:0];
            st_ag_lsid[LSIQ_ENTRY-1:0]    <= idu_lsu_st_lch_entry[LSIQ_ENTRY-1:0];
            st_ag_sdid_oh[SDIQ_ENTRY-1:0] <= idu_lsu_st_sdiq_entry[SDIQ_ENTRY-1:0];
            st_ag_old                     <= idu_lsu_st_oldest;
        end
    end

    always_ff @(posedge forever_cpuclk) begin
        if (!st_ag_stall_vld && idu_lsu_st_sel)
            st_ag_offset[31:0] <= {{20{idu_lsu_st_offset[11]}}, idu_lsu_st_offset[11:0]};
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            st_ag_offset_plus[12:0] <= 13'h0;
        else if (!st_ag_stall_vld && idu_lsu_st_sel)
            st_ag_offset_plus[12:0] <= idu_lsu_st_offset_plus[12:0];
    end

    always_ff @(posedge forever_cpuclk) begin
        if (!st_ag_stall_vld && idu_lsu_st_sel)
            st_ag_base[31:0] <= idu_lsu_st_src0[31:0];
    end

    //==========================================================
    //               Generate virtual address
    //==========================================================
    logic [31:0] st_ag_addr_ori;
    logic [31:0] st_ag_addr_plus;
    logic        st_ag_addr_plus_sel;
    logic [31:0] st_ag_addr;

    assign st_ag_addr_ori[31:0] = st_ag_base[31:0] + st_ag_offset[31:0];

    assign st_ag_addr_plus[31:0] = st_ag_base[31:0] +
        {{19{st_ag_offset_plus[12]}}, st_ag_offset_plus[12:0]};

    assign st_ag_addr_plus_sel = st_ag_secd;

    assign st_ag_addr[31:0] = st_ag_addr_plus_sel ? st_ag_addr_plus[31:0]
                                                  : st_ag_addr_ori[31:0];

    //==========================================================
    //            Generate unalign, bytes_vld
    //==========================================================
    logic [3:0]  st_ag_access_size_ori;
    logic [3:0]  st_ag_access_size;
    logic [15:0] st_ag_le_bytes_vld_high_bits_full;
    logic [15:0] st_ag_le_bytes_vld_low_bits_full;
    logic [15:0] st_ag_le_bytes_vld_cross;
    logic [15:0] st_ag_le_bytes_vld_high_cross_bits;
    logic [15:0] st_ag_bytes_vld_low_bits;
    logic [15:0] st_ag_bytes_vld_high_cross_bits;
    logic [15:0] st_ag_bytes_vld;
    logic [4:0]  st_ag_va_add_access_size;
    logic        st_ag_boundary_unmask;

    always_comb begin
        case (st_ag_inst_size[1:0])
            BYTE:    st_ag_access_size_ori[3:0] = 4'b0000;
            HALF:    st_ag_access_size_ori[3:0] = 4'b0001;
            WORD:    st_ag_access_size_ori[3:0] = 4'b0011;
            DWORD:   st_ag_access_size_ori[3:0] = 4'b0111;
            default: st_ag_access_size_ori[3:0] = 4'b0;
        endcase
    end

    assign st_ag_access_size[3:0] = st_ag_access_size_ori[3:0];

    assign st_ag_va_add_access_size[4:0] = {1'b0, st_ag_addr_ori[3:0]} +
                                           {1'b0, st_ag_access_size[3:0]};
    assign st_ag_boundary_unmask = st_ag_va_add_access_size[4];

    assign st_ag_boundary = st_ag_boundary_unmask || st_ag_secd;

    always_comb begin
        case (st_ag_addr_ori[3:0])
            4'b0000: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffff;
            4'b0001: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfffe;
            4'b0010: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfffc;
            4'b0011: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfff8;
            4'b0100: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfff0;
            4'b0101: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffe0;
            4'b0110: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffc0;
            4'b0111: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hff80;
            4'b1000: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hff00;
            4'b1001: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfe00;
            4'b1010: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfc00;
            4'b1011: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hf800;
            4'b1100: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hf000;
            4'b1101: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'he000;
            4'b1110: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hc000;
            4'b1111: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'h8000;
            default: st_ag_le_bytes_vld_high_bits_full[15:0] = {16{1'bx}};
        endcase
    end

    always_comb begin
        case (st_ag_va_add_access_size[3:0])
            4'b0000: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0001;
            4'b0001: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0003;
            4'b0010: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0007;
            4'b0011: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h000f;
            4'b0100: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h001f;
            4'b0101: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h003f;
            4'b0110: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h007f;
            4'b0111: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h00ff;
            4'b1000: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h01ff;
            4'b1001: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h03ff;
            4'b1010: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h07ff;
            4'b1011: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0fff;
            4'b1100: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h1fff;
            4'b1101: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h3fff;
            4'b1110: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h7fff;
            4'b1111: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'hffff;
            default: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'b0;
        endcase
    end

    assign st_ag_le_bytes_vld_cross[15:0] =
        st_ag_le_bytes_vld_high_bits_full[15:0] & st_ag_le_bytes_vld_low_bits_full[15:0];

    assign st_ag_le_bytes_vld_high_cross_bits[15:0] =
        st_ag_boundary_unmask ? st_ag_le_bytes_vld_high_bits_full[15:0]
                              : st_ag_le_bytes_vld_cross[15:0];

    assign st_ag_bytes_vld_low_bits[15:0] = st_ag_le_bytes_vld_low_bits_full[15:0];
    assign st_ag_bytes_vld_high_cross_bits[15:0] = st_ag_le_bytes_vld_high_cross_bits[15:0];

    assign st_ag_bytes_vld[15:0] = st_ag_secd ? st_ag_bytes_vld_low_bits[15:0]
                                              : st_ag_bytes_vld_high_cross_bits[15:0];

    //==========================================================
    //        vector mask
    //==========================================================
    assign st_ag_dc_bytes_vld[15:0] = st_ag_bytes_vld[15:0];
    assign st_ag_dc_rot_sel[3:0] = st_ag_addr_ori[3:0];

    //==========================================================
    //        Generate dcache request information
    //==========================================================
    logic ag_dcache_arb_st_gateclk_en;
    logic ag_dcache_arb_st_req;

    assign ag_dcache_arb_st_gateclk_en = st_ag_inst_vld;
    assign ag_dcache_arb_st_req = st_ag_inst_vld;

    assign ag_dcache_arb_st_tag_gateclk_en = ag_dcache_arb_st_gateclk_en;
    assign ag_dcache_arb_st_tag_req        = ag_dcache_arb_st_req;
    assign ag_dcache_arb_st_tag_idx        = st_ag_addr[INDEX_MSB:INDEX_LSB];

    assign ag_dcache_arb_st_dirty_gateclk_en = ag_dcache_arb_st_gateclk_en;
    assign ag_dcache_arb_st_dirty_req        = ag_dcache_arb_st_req;
    assign ag_dcache_arb_st_dirty_idx        = st_ag_addr[INDEX_MSB:INDEX_LSB];

    //==========================================================
    //        Generate stall/restart signal
    //==========================================================
    logic rf_iid_older_than_st_ag;

    ct_rtu_compare_iid x_lsu_rf_compare_st_ag_iid (
        .x_iid0       (idu_lsu_st_iid[6:0]),
        .x_iid0_older (rf_iid_older_than_st_ag),
        .x_iid1       (st_ag_iid[6:0])
    );

    assign st_ag_stall_mask = idu_lsu_st_sel && rf_iid_older_than_st_ag;

    assign st_ag_stall_restart_entry[LSIQ_ENTRY-1:0] =
        st_ag_stall_mask ? st_ag_lsid[LSIQ_ENTRY-1:0]
                         : idu_lsu_st_lch_entry[LSIQ_ENTRY-1:0];

    //==========================================================
    //        Generate to DC stage signal
    //==========================================================
    assign st_ag_dc_inst_vld = st_ag_inst_vld && !st_ag_stall_restart;

    assign st_ag_dc_addr0[31:0] = dcache_arb_st_ag_borrow_addr_vld
        ? dcache_arb_st_ag_addr[31:0]
        : st_ag_addr[31:0];

endmodule