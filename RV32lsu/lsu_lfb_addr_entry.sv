module ct_lsu_lfb_addr_entry #(
    parameter int DCACHE_SIZE = 2048,  // 1024, 2048, or 4096 bytes
    parameter int CACHELINE_SIZE = 32,
    parameter int NUM_WAYS = 2,
    parameter int OFFSET_WIDTH = 5,
    parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
    parameter int INDEX_WIDTH = $clog2(NUM_SETS)
)(
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [INDEX_WIDTH-1:0]   ld_da_idx,
    input  logic         ld_da_lfb_discard_grnt,
    input  logic         lfb_addr_entry_rb_create_vld_x,
    input  logic         lfb_addr_entry_resp_set_x,
    input  logic         lfb_addr_entry_vb_pe_req_grnt_x,
    input  logic         lfb_data_addr_pop_req_x,
    input  logic         lfb_lf_sm_addr_pop_req_x,
    input  logic         lfb_vb_pe_req,
    input  logic         lfb_vb_pe_req_permit,
    input  logic [31:0]  rb_biu_req_addr,
    input  logic [27:0]  rb_lfb_addr_tto4,
    input  logic         rb_lfb_depd,
    input  logic [31:0]  st_da_addr,
    input  logic         vb_lfb_addr_entry_rcl_done_x,
    input  logic         vb_lfb_dcache_hit,
    input  logic         vb_lfb_dcache_way,
    input  logic [31:0]  wmb_write_req_addr,

    output logic [27:0]  lfb_addr_entry_addr_tto4_v,
    output logic         lfb_addr_entry_dcache_hit_x,
    output logic         lfb_addr_entry_depd_x,
    output logic         lfb_addr_entry_discard_vld_x,
    output logic         lfb_addr_entry_ld_da_hit_idx_x,
    output logic         lfb_addr_entry_linefill_permit_x,
    output logic         lfb_addr_entry_not_resp_x,
    output logic         lfb_addr_entry_pop_vld_x,
    output logic         lfb_addr_entry_rb_biu_req_hit_idx_x,
    output logic         lfb_addr_entry_rcl_done_x,
    output logic         lfb_addr_entry_refill_way_x,
    output logic         lfb_addr_entry_st_da_hit_idx_x,
    output logic         lfb_addr_entry_vb_pe_req_x,
    output logic         lfb_addr_entry_vld_x,
    output logic         lfb_addr_entry_wmb_read_req_hit_idx_x,
    output logic         lfb_addr_entry_wmb_write_req_hit_idx_x
);

localparam int INDEX_LSB = OFFSET_WIDTH;
localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;

//------------------------------------------------------------------
// 内部信号声明
//------------------------------------------------------------------
logic [27:0] lfb_addr_entry_addr_tto4;
logic        lfb_addr_entry_dcache_hit;
logic        lfb_addr_entry_depd;
logic        lfb_addr_entry_rcl_done;
logic        lfb_addr_entry_refill_way;
logic        lfb_addr_entry_resp;
logic        lfb_addr_entry_vb_pe_req_success;
logic        lfb_addr_entry_vld;



logic        lfb_addr_entry_discard_vld;
logic        lfb_addr_entry_ld_da_hit_idx;
logic        lfb_addr_entry_linefill_permit;
logic        lfb_addr_entry_not_resp;
logic        lfb_addr_entry_pop_vld;
logic        lfb_addr_entry_rb_biu_req_hit_idx;
logic        lfb_addr_entry_rb_create_vld;
logic        lfb_addr_entry_resp_set;
logic        lfb_addr_entry_st_da_hit_idx;
logic        lfb_addr_entry_vb_pe_req;
logic        lfb_addr_entry_vb_pe_req_grnt;
logic        lfb_addr_entry_vb_pe_req_success_set;
logic        lfb_addr_entry_wmb_read_req_hit_idx;
logic        lfb_addr_entry_wmb_write_req_hit_idx;
logic        lfb_data_addr_pop_req;
logic        lfb_lf_sm_addr_pop_req;
logic        vb_lfb_addr_entry_rcl_done;

logic [31:0] lfb_addr_entry_cmp_st_da_addr;
logic [31:0] lfb_addr_entry_cmp_rb_biu_req_addr;
logic [31:0] lfb_addr_entry_cmp_wmb_read_req_addr;
logic [31:0] lfb_addr_entry_cmp_wmb_write_req_addr;

//==========================================================
//                 Register
//==========================================================
//+-----------+
//| entry_vld |
//+-----------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
    if (!cpurst_b)
        lfb_addr_entry_vld <= 1'b0;
    else if (lfb_addr_entry_pop_vld)
        lfb_addr_entry_vld <= 1'b0;
    else if (lfb_addr_entry_rb_create_vld)
        lfb_addr_entry_vld <= 1'b1;
end

//+------+--------+
//| addr | pfu_id |
//+------+--------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
    if (!cpurst_b)
        lfb_addr_entry_addr_tto4[27:0] <= 28'b0;
    else if (lfb_addr_entry_rb_create_vld)
        lfb_addr_entry_addr_tto4[27:0] <= rb_lfb_addr_tto4[27:0];
end

//+--------------------+
//| vb_pe_req_success  |
//+--------------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
    if (!cpurst_b)
        lfb_addr_entry_vb_pe_req_success <= 1'b0;
    else if (lfb_addr_entry_vb_pe_req_success_set)
        lfb_addr_entry_vb_pe_req_success <= 1'b1;
    else if (lfb_addr_entry_rb_create_vld)
        lfb_addr_entry_vb_pe_req_success <= 1'b0;
end

//+-----------------+
//| cache line info |
//+-----------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
    if (!cpurst_b) begin
        lfb_addr_entry_rcl_done     <= 1'b0;
        lfb_addr_entry_refill_way   <= 1'b0;
        lfb_addr_entry_dcache_hit   <= 1'b0;
    end
    else if (lfb_addr_entry_rb_create_vld) begin
        lfb_addr_entry_rcl_done     <= 1'b0;
        lfb_addr_entry_refill_way   <= 1'b0;
        lfb_addr_entry_dcache_hit   <= 1'b0;
    end
    else if (vb_lfb_addr_entry_rcl_done) begin
        lfb_addr_entry_rcl_done     <= 1'b1;
        lfb_addr_entry_refill_way   <= vb_lfb_dcache_way;
        lfb_addr_entry_dcache_hit   <= vb_lfb_dcache_hit;
    end
end

//+------+
//| depd |
//+------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
    if (!cpurst_b)
        lfb_addr_entry_depd <= 1'b0;
    else if (lfb_addr_entry_rb_create_vld)
        lfb_addr_entry_depd <= rb_lfb_depd;
    else if (lfb_addr_entry_discard_vld)
        lfb_addr_entry_depd <= 1'b1;
end

//+------+
//| resp |
//+------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
    if (!cpurst_b)
        lfb_addr_entry_resp <= 1'b0;
    else if (lfb_addr_entry_rb_create_vld)
        lfb_addr_entry_resp <= 1'b0;
    else if (lfb_addr_entry_resp_set)
        lfb_addr_entry_resp <= 1'b1;
end

//==========================================================
//                 Generate create signal
//==========================================================
//==========================================================
//                 Generate vb req signal
//==========================================================
assign lfb_addr_entry_vb_pe_req = lfb_addr_entry_vld
                                  && !lfb_addr_entry_vb_pe_req_success;

assign lfb_addr_entry_vb_pe_req_success_set = (lfb_addr_entry_rb_create_vld
                                               && lfb_vb_pe_req_permit
                                               && !lfb_vb_pe_req)
                                            || (lfb_addr_entry_vb_pe_req
                                                && lfb_addr_entry_vb_pe_req_grnt);

//==========================================================
//            Linefill permit
//==========================================================
assign lfb_addr_entry_linefill_permit = lfb_addr_entry_rcl_done
                                        && !lfb_addr_entry_dcache_hit;

//for rready
assign lfb_addr_entry_not_resp = lfb_addr_entry_vld
                                 && !lfb_addr_entry_resp;

//==========================================================
//                 Generate pop signal
//==========================================================
assign lfb_addr_entry_pop_vld = lfb_lf_sm_addr_pop_req
                                || lfb_data_addr_pop_req;

//==========================================================
//                    Compare index
//==========================================================
//------------------compare ld_da stage---------------------
assign lfb_addr_entry_ld_da_hit_idx = lfb_addr_entry_vld
                                      && (lfb_addr_entry_addr_tto4[INDEX_WIDTH:1]
                                          == ld_da_idx[INDEX_WIDTH-1:0]);

//------------------compare st_da stage---------------------
assign lfb_addr_entry_cmp_st_da_addr[31:0] = st_da_addr[31:0];
assign lfb_addr_entry_st_da_hit_idx = lfb_addr_entry_vld
                                      && (lfb_addr_entry_addr_tto4[INDEX_WIDTH:1]
                                          == lfb_addr_entry_cmp_st_da_addr[INDEX_MSB:INDEX_LSB]);

//------------------depd_vld--------------------------------
assign lfb_addr_entry_discard_vld = ld_da_lfb_discard_grnt
                                    && lfb_addr_entry_ld_da_hit_idx;

//----------------compare rb biu req entry------------------
assign lfb_addr_entry_cmp_rb_biu_req_addr[31:0] = rb_biu_req_addr[31:0];
assign lfb_addr_entry_rb_biu_req_hit_idx = lfb_addr_entry_vld
                                           && (lfb_addr_entry_addr_tto4[INDEX_WIDTH:1]
                                               == lfb_addr_entry_cmp_rb_biu_req_addr[INDEX_MSB:INDEX_LSB]);

//------------------compare wmb write req-------------------
assign lfb_addr_entry_cmp_wmb_write_req_addr[31:0] = wmb_write_req_addr[31:0];
assign lfb_addr_entry_wmb_write_req_hit_idx = lfb_addr_entry_vld
                                              && (lfb_addr_entry_addr_tto4[INDEX_WIDTH:1]
                                                  == lfb_addr_entry_cmp_wmb_write_req_addr[INDEX_MSB:INDEX_LSB]);

//==========================================================
//                 Generate interface
//==========================================================
//------------------input-----------------------------------
assign lfb_addr_entry_rb_create_vld = lfb_addr_entry_rb_create_vld_x;
assign lfb_addr_entry_vb_pe_req_grnt = lfb_addr_entry_vb_pe_req_grnt_x;
assign vb_lfb_addr_entry_rcl_done = vb_lfb_addr_entry_rcl_done_x;
assign lfb_data_addr_pop_req = lfb_data_addr_pop_req_x;
assign lfb_lf_sm_addr_pop_req = lfb_lf_sm_addr_pop_req_x;
assign lfb_addr_entry_resp_set = lfb_addr_entry_resp_set_x;

//------------------output----------------------------------
assign lfb_addr_entry_vld_x = lfb_addr_entry_vld;
assign lfb_addr_entry_addr_tto4_v[27:0] = lfb_addr_entry_addr_tto4[27:0];
assign lfb_addr_entry_refill_way_x = lfb_addr_entry_refill_way;
assign lfb_addr_entry_depd_x = lfb_addr_entry_depd;
assign lfb_addr_entry_rcl_done_x = lfb_addr_entry_rcl_done;
assign lfb_addr_entry_dcache_hit_x = lfb_addr_entry_dcache_hit;
assign lfb_addr_entry_not_resp_x = lfb_addr_entry_not_resp;
assign lfb_addr_entry_vb_pe_req_x = lfb_addr_entry_vb_pe_req;
assign lfb_addr_entry_pop_vld_x = lfb_addr_entry_pop_vld;
assign lfb_addr_entry_discard_vld_x = lfb_addr_entry_discard_vld;
assign lfb_addr_entry_linefill_permit_x = lfb_addr_entry_linefill_permit;
assign lfb_addr_entry_ld_da_hit_idx_x = lfb_addr_entry_ld_da_hit_idx;
assign lfb_addr_entry_st_da_hit_idx_x = lfb_addr_entry_st_da_hit_idx;
assign lfb_addr_entry_rb_biu_req_hit_idx_x = lfb_addr_entry_rb_biu_req_hit_idx;
assign lfb_addr_entry_wmb_read_req_hit_idx_x = lfb_addr_entry_wmb_read_req_hit_idx;
assign lfb_addr_entry_wmb_write_req_hit_idx_x = lfb_addr_entry_wmb_write_req_hit_idx;

// &ModuleEnd; @368
endmodule