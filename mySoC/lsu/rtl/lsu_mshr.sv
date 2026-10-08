/*Copyright 2019-2021 T-Head Semiconductor Co., Ltd.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// RV32I lightweight read buffer (MSHR).
// AXI interface, fixed ARLEN=1 (2-beat, 32B linefill). No non-cacheable,
// no sync/fence, no atomic/ldamo, no MMU attributes, no prefetch.
// id is 4-bit. dp_vld/gateclk_en create signals removed.
module lsu_mshr #(
    parameter RB_ENTRY = 4
)(
    //==========================================================
    // BIU (AXI) response
    //==========================================================
    input  logic [127:0] biu_lsu_r_data,
    input  logic [3:0]   biu_lsu_r_id,
    input  logic [1:0]   biu_lsu_r_resp,
    input  logic         biu_lsu_r_vld,

    //==========================================================
    // Clock / Reset
    //==========================================================
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [31:0]  wmb_ce_addr,

    //==========================================================
    // Bus arbiter
    //==========================================================
    input  logic         bus_arb_rb_ar_grnt,

    //==========================================================
    // ld_da stage
    //==========================================================
    input  logic [31:0]  ld_da_addr,
    input  logic         ld_da_boundary_after_mask,
    input  logic [15:0]  ld_da_bytes_vld,
    input  logic [31:0]  ld_da_data_ori,
    input  logic [7:0]   ld_da_data_rot_sel,
    input  logic [4:0]   ld_da_idx,
    input  logic [6:0]   ld_da_iid,
    input  logic [1:0]   ld_da_inst_size,
    input  logic         ld_da_old,
    input  logic [5:0]   ld_da_preg,
    input  logic         ld_da_rb_cmit,
    input  logic         ld_da_rb_create_vld,
    input  logic         ld_da_rb_data_vld,
    input  logic         ld_da_rb_discard_grnt,
    input  logic         ld_da_rb_merge_vld,
    input  logic         ld_da_sign_extend,

    //==========================================================
    // ld_wb stage
    //==========================================================
    input  logic         ld_wb_rb_cmplt_grnt,
    input  logic         ld_wb_rb_data_grnt,

    //==========================================================
    // LFB
    //==========================================================
    input  logic         lfb_addr_full,
    input  logic         lfb_rb_biu_req_hit_idx,
    input  logic         lfb_rb_ca_rready_grnt,
    input  logic [3:0]   lfb_rb_create_id,

    //==========================================================
    // RTU
    //==========================================================
    input  logic         rtu_yy_xx_commit0,
    input  logic [6:0]   rtu_yy_xx_commit0_iid,
    input  logic         rtu_yy_xx_commit1,
    input  logic [6:0]   rtu_yy_xx_commit1_iid,
    input  logic         rtu_yy_xx_commit2,
    input  logic [6:0]   rtu_yy_xx_commit2_iid,
    input  logic         rtu_yy_xx_flush,

    //==========================================================
    // sq / st_da / wmb / vb
    //==========================================================
    input  logic [31:0]  sq_pop_addr,
    input  logic [31:0]  st_da_addr,
    input  logic [15:0]  st_da_bytes_vld,
    input  logic         st_da_dcache_hit,
    input  logic [6:0]   st_da_iid,
    input  logic         st_da_old,
    input  logic         st_da_rb_cmit,
    input  logic         st_da_rb_create_vld,
    input  logic         vb_rb_biu_req_hit_idx,
    input  logic         wmb_rb_biu_req_hit_idx,

    //==========================================================
    // BIU (AXI) AR channel
    //==========================================================
    output logic [31:0]  rb_biu_ar_addr,
    output logic [3:0]   rb_biu_ar_id,
    output logic [1:0]   rb_biu_ar_len,
    output logic [2:0]   rb_biu_ar_size,
    output logic [1:0]   rb_biu_ar_burst,
    output logic         rb_biu_ar_lock,
    output logic [3:0]   rb_biu_ar_cache,
    output logic [2:0]   rb_biu_ar_prot,
    output logic         rb_biu_ar_req,

    //==========================================================
    // Status
    //==========================================================
    output logic         rb_ld_da_full,
    output logic         rb_ld_da_hit_idx,
    output logic         rb_ld_da_merge_fail,
    output logic         rb_st_da_full,
    output logic         rb_st_da_hit_idx,

    //==========================================================
    // ld_wb writeback
    //==========================================================
    output logic         rb_ld_wb_bus_err,
    output logic [31:0]  rb_ld_wb_bus_err_addr,
    output logic         rb_ld_wb_cmplt_req,
    output logic [31:0]  rb_ld_wb_data,
    output logic [6:0]   rb_ld_wb_data_iid,
    output logic         rb_ld_wb_data_req,
    output logic [6:0]   rb_ld_wb_iid,
    output logic [5:0]   rb_ld_wb_preg,
    output logic [3:0]   rb_ld_wb_preg_sign_sel,

    //==========================================================
    // LFB interface
    //==========================================================
    output logic [27:0]  rb_lfb_addr_tto4,
    output logic         rb_lfb_boundary_depd_wakeup,
    output logic         rb_lfb_create_req,
    output logic         rb_lfb_create_vld,
    output logic         rb_lfb_depd,
    output  logic [31:0]  rb_biu_req_addr,

    //==========================================================
    // hit idx
    //==========================================================
    output logic         rb_sq_pop_hit_idx,
    //==========================================================
    // Other
    //==========================================================
    output logic         lsu_idu_rb_not_full
);

//==========================================================
//                 Internal registers
//==========================================================
logic [RB_ENTRY-1:0] rb_biu_pe_req_ptr;

logic                 rb_biu_req_create_lfb;
logic [RB_ENTRY-1:0] rb_biu_req_ptr;
logic                 rb_biu_req_unmask;
logic [RB_ENTRY-1:0] rb_create_ptr0;
logic [RB_ENTRY-1:0] rb_create_ptr1;
logic [RB_ENTRY-1:0] rb_ld_wb_cmplt_ptr;
logic [RB_ENTRY-1:0] rb_ld_wb_data_ptr;
logic [RB_ENTRY-1:0] rb_ld_wb_data_ptr_pre;
logic [63:0]         rb_wb_data;

//==========================================================
//                 Internal wires
//==========================================================
logic [127:0] biu_lsu_r_data_mask;
logic         rb_biu_pe_create_lfb;
logic         rb_biu_pe_req;
logic [31:0]  rb_biu_pe_req_addr;
logic         rb_biu_pe_req_permit;
logic         rb_biu_req_flush_clear;
logic         rb_biu_req_hit_idx;
logic         rb_create_ld_success;
logic         rb_create_st_success;
logic         rb_empty_less2;
logic         rb_full;
logic         rb_ld_biu_pe_req;
logic         rb_ld_biu_pe_req_grnt;
logic [7:0]   rb_ld_rot_sel;
logic [127:0] rb_ld_wb_data_64;
logic         rb_ld_wb_data_req_unmask;
logic [1:0]   rb_ld_wb_inst_size;
logic         rb_ld_wb_sign_extend;
logic [127:0] rb_wb_data_unsettle;
logic         rb_pipe_biu_pe_req;
logic         rb_read_req_grnt;
logic         rb_not_empty;
logic         rb_r_resp_err;

// entry aggregate buses
logic [RB_ENTRY-1:0] rb_entry_biu_pe_req;
logic [RB_ENTRY-1:0] rb_entry_biu_pe_req_grnt;
logic [RB_ENTRY-1:0] rb_entry_biu_req;
logic [RB_ENTRY-1:0] rb_entry_boundary_wakeup;
logic [RB_ENTRY-1:0] rb_entry_bus_err;
logic [RB_ENTRY-1:0] rb_entry_cmit_data_vld;
logic [RB_ENTRY-1:0] rb_entry_create_lfb;
logic [RB_ENTRY-1:0] rb_entry_depd;
logic [RB_ENTRY-1:0] rb_entry_discard_vld;
logic [RB_ENTRY-1:0] rb_entry_flush_clear;
logic [RB_ENTRY-1:0] rb_entry_ld_create_vld;
logic [RB_ENTRY-1:0] rb_entry_ld_da_hit_idx;
logic [RB_ENTRY-1:0] rb_entry_merge_fail;
logic [RB_ENTRY-1:0] rb_entry_read_req_grnt;
logic [RB_ENTRY-1:0] rb_entry_sq_pop_hit_idx;
logic [RB_ENTRY-1:0] rb_entry_st_create_vld;
logic [RB_ENTRY-1:0] rb_entry_st_da_hit_idx;
logic [RB_ENTRY-1:0] rb_entry_vld;
logic [RB_ENTRY-1:0] rb_entry_wb_cmplt_grnt;
logic [RB_ENTRY-1:0] rb_entry_wb_cmplt_req;
logic [RB_ENTRY-1:0] rb_entry_wb_data_grnt;
logic [RB_ENTRY-1:0] rb_entry_wb_data_pre_sel;
logic [RB_ENTRY-1:0] rb_entry_wb_data_req;
logic [RB_ENTRY-1:0] rb_entry_wmb_ce_hit_idx;
logic [31:0]         rb_entry_addr [RB_ENTRY-1:0];
logic [31:0]         rb_entry_data [RB_ENTRY-1:0];
logic [6:0]          rb_entry_iid [RB_ENTRY-1:0];
logic [1:0]          rb_entry_inst_size [RB_ENTRY-1:0];
logic [5:0]          rb_entry_preg [RB_ENTRY-1:0];
logic [7:0]          rb_entry_rot_sel [RB_ENTRY-1:0];
logic [RB_ENTRY-1:0] rb_entry_sign_extend;

//==========================================================
//                 BIU data mask
//==========================================================
// AXI RRESP: 2'b00 OKAY, 2'b10 SLVERR, 2'b11 DECERR.
// mask out data on any non-OKAY response.
assign biu_lsu_r_data_mask[127:0] = (biu_lsu_r_resp[1:0] == 2'b00)
                                    ? biu_lsu_r_data[127:0]
                                    : 128'b0;

assign rb_r_resp_err = biu_lsu_r_vld && (biu_lsu_r_resp[1:0] == 2'b10);

//==========================================================
//                 Instance read buffer entries
//==========================================================
genvar i;
generate
    for (i = 0; i < RB_ENTRY; i = i + 1) begin : gen_mshr_entry
lsu_mshr_entry u_mshr_entry (
    .biu_lsu_r_data_mask            (biu_lsu_r_data_mask),
    .biu_lsu_r_id                   (biu_lsu_r_id),
    .biu_lsu_r_vld                  (biu_lsu_r_vld),
    .cpurst_b                       (cpurst_b),
    .forever_cpuclk                 (forever_cpuclk),
    .ld_da_addr                     (ld_da_addr),
    .ld_da_boundary_after_mask      (ld_da_boundary_after_mask),
    .ld_da_bytes_vld                (ld_da_bytes_vld),
    .ld_da_data_ori                 (ld_da_data_ori),
    .ld_da_data_rot_sel             (ld_da_data_rot_sel),
    .ld_da_idx                      (ld_da_idx),
    .ld_da_iid                      (ld_da_iid),
    .ld_da_inst_size                (ld_da_inst_size),
    .ld_da_preg                     (ld_da_preg),
    .ld_da_rb_cmit                  (ld_da_rb_cmit),
    .ld_da_rb_data_vld              (ld_da_rb_data_vld),
    .ld_da_rb_discard_grnt          (ld_da_rb_discard_grnt),
    .ld_da_rb_merge_vld             (ld_da_rb_merge_vld),
    .ld_da_sign_extend              (ld_da_sign_extend),
    .rb_biu_ar_id                   (rb_biu_ar_id),
    .rb_entry_biu_pe_req_grnt_x     (rb_entry_biu_pe_req_grnt[i]),
    .rb_entry_ld_create_vld_x       (rb_entry_ld_create_vld[i]),
    .rb_entry_read_req_grnt_x       (rb_entry_read_req_grnt[i]),
    .rb_entry_st_create_vld_x       (rb_entry_st_create_vld[i]),
    .rb_entry_wb_cmplt_grnt_x       (rb_entry_wb_cmplt_grnt[i]),
    .rb_entry_wb_data_grnt_x        (rb_entry_wb_data_grnt[i]),
    .rb_ld_biu_pe_req_grnt          (rb_ld_biu_pe_req_grnt),
    .rb_r_resp_err                  (rb_r_resp_err),
    .rtu_yy_xx_commit0              (rtu_yy_xx_commit0),
    .rtu_yy_xx_commit0_iid          (rtu_yy_xx_commit0_iid),
    .rtu_yy_xx_commit1              (rtu_yy_xx_commit1),
    .rtu_yy_xx_commit1_iid          (rtu_yy_xx_commit1_iid),
    .rtu_yy_xx_commit2              (rtu_yy_xx_commit2),
    .rtu_yy_xx_commit2_iid          (rtu_yy_xx_commit2_iid),
    .rtu_yy_xx_flush                (rtu_yy_xx_flush),
    .sq_pop_addr                    (sq_pop_addr),
    .st_da_addr                     (st_da_addr),
    .st_da_bytes_vld                (st_da_bytes_vld),
    .st_da_dcache_hit               (st_da_dcache_hit),
    .st_da_iid                      (st_da_iid),
    .st_da_rb_cmit                  (st_da_rb_cmit),
    .wmb_ce_addr                    (wmb_ce_addr),

    .rb_entry_addr_v                (rb_entry_addr[i]),
    .rb_entry_biu_pe_req_x          (rb_entry_biu_pe_req[i]),
    .rb_entry_biu_req_x             (rb_entry_biu_req[i]),
    .rb_entry_boundary_wakeup_x     (rb_entry_boundary_wakeup[i]),
    .rb_entry_bus_err_x             (rb_entry_bus_err[i]),
    .rb_entry_create_lfb_x          (rb_entry_create_lfb[i]),
    .rb_entry_data_v                (rb_entry_data[i]),
    .rb_entry_depd_x                (rb_entry_depd[i]),
    .rb_entry_discard_vld_x         (rb_entry_discard_vld[i]),
    .rb_entry_flush_clear_x         (rb_entry_flush_clear[i]),
    .rb_entry_iid_v                 (rb_entry_iid[i]),
    .rb_entry_inst_size_v           (rb_entry_inst_size[i]),
    .rb_entry_ld_da_hit_idx_x       (rb_entry_ld_da_hit_idx[i]),
    .rb_entry_merge_fail_x          (rb_entry_merge_fail[i]),
    .rb_entry_preg_v                (rb_entry_preg[i]),
    .rb_entry_rot_sel_v             (rb_entry_rot_sel[i]),
    .rb_entry_sign_extend_x         (rb_entry_sign_extend[i]),
    .rb_entry_sq_pop_hit_idx_x      (rb_entry_sq_pop_hit_idx[i]),
    .rb_entry_st_da_hit_idx_x       (rb_entry_st_da_hit_idx[i]),
    .rb_entry_vld_x                 (rb_entry_vld[i]),
    .rb_entry_wb_cmplt_req_x        (rb_entry_wb_cmplt_req[i]),
    .rb_entry_wb_data_pre_sel_x     (rb_entry_wb_data_pre_sel[i]),
    .rb_entry_wb_data_req_x         (rb_entry_wb_data_req[i]),
    .rb_entry_wmb_ce_hit_idx_x      (rb_entry_wmb_ce_hit_idx[i])
);
    end
endgenerate

//==========================================================
//                      Create signal
//==========================================================
//+------------+
//| create_ptr |
//+------------+
always @( rb_entry_vld[RB_ENTRY-1:0])
begin
  rb_create_ptr0[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  casez(rb_entry_vld[RB_ENTRY-1:0])
    4'b???0: rb_create_ptr0[0] = 1'b1;
    4'b??01: rb_create_ptr0[1] = 1'b1;
    4'b?011: rb_create_ptr0[2] = 1'b1;
    4'b0111: rb_create_ptr0[3] = 1'b1;
    default: rb_create_ptr0[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  endcase
end

always @( rb_entry_vld[RB_ENTRY-1:0])
begin
  rb_create_ptr1[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  casez(rb_entry_vld[RB_ENTRY-1:0])
    4'b0???: rb_create_ptr1[3] = 1'b1;
    4'b10??: rb_create_ptr1[2] = 1'b1;
    4'b110?: rb_create_ptr1[1] = 1'b1;
    4'b1110: rb_create_ptr1[0] = 1'b1;
    default: rb_create_ptr1[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  endcase
end
assign lsu_idu_rb_not_full = !rb_empty_less2;
//------------------full signal-----------------------------
assign rb_full        = &rb_entry_vld[RB_ENTRY-1:0];
assign rb_empty_less2 = &(rb_entry_vld[RB_ENTRY-1:0]
                          | rb_create_ptr0[RB_ENTRY-1:0]);

assign rb_ld_da_full  = rb_full
                        || (!ld_da_old && rb_empty_less2);
assign rb_st_da_full  = rb_full
                        || (!st_da_old && rb_empty_less2);

//------------------empty signal----------------------------
assign rb_not_empty = |rb_entry_vld[RB_ENTRY-1:0];


//------------------merge signal----------------------------
assign rb_ld_da_merge_fail = |(rb_entry_merge_fail[RB_ENTRY-1:0]);

//------------------create vld------------------------------
assign rb_create_ld_success = ld_da_rb_create_vld
                              && !rb_ld_da_full
                              && !rtu_yy_xx_flush;

assign rb_create_st_success = st_da_rb_create_vld
                              && !rb_st_da_full
                              && !rtu_yy_xx_flush;

assign rb_entry_ld_create_vld[RB_ENTRY-1:0] =
                rb_create_ptr0[RB_ENTRY-1:0]
                & {RB_ENTRY{rb_create_ld_success}};
assign rb_entry_st_create_vld[RB_ENTRY-1:0] =
                rb_create_ptr1[RB_ENTRY-1:0]
                & {RB_ENTRY{rb_create_st_success}};

//==========================================================
//                  Request biu pop entry
//==========================================================
//+---------+
//| biu_req |
//+---------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_biu_req_unmask <= 1'b0;
  else if (rb_pipe_biu_pe_req)
    rb_biu_req_unmask <= 1'b1;
  else if (rb_read_req_grnt || rb_biu_req_flush_clear)
    rb_biu_req_unmask <= 1'b0;
end

//+---------+------+------------+
//| pop ptr | addr | lfb_create |
//+---------+------+------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    rb_biu_req_ptr[RB_ENTRY-1:0] <= {RB_ENTRY{1'b0}};
    rb_biu_req_addr[31:0]         <= 32'b0;
  end
  else if (rb_biu_pe_req_permit && rb_biu_pe_req)
  begin
    rb_biu_req_ptr[RB_ENTRY-1:0] <= rb_biu_pe_req_ptr[RB_ENTRY-1:0];
    rb_biu_req_addr[31:0]         <= rb_biu_pe_req_addr[31:0];
  end
  else if (rb_ld_biu_pe_req_grnt)
  begin
    rb_biu_req_ptr[RB_ENTRY-1:0] <= rb_create_ptr0[RB_ENTRY-1:0];
    rb_biu_req_addr[31:0]         <= ld_da_addr[31:0];
  end
end

//-----------------------biu req ptr------------------------
assign rb_biu_pe_req = |rb_entry_biu_pe_req[RB_ENTRY-1:0];

always @( rb_entry_biu_pe_req[RB_ENTRY-1:0])
begin
  rb_biu_pe_req_ptr[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  casez(rb_entry_biu_pe_req[RB_ENTRY-1:0])
    4'b???1: rb_biu_pe_req_ptr[0] = 1'b1;
    4'b??10: rb_biu_pe_req_ptr[1] = 1'b1;
    4'b?100: rb_biu_pe_req_ptr[2] = 1'b1;
    4'b1000: rb_biu_pe_req_ptr[3] = 1'b1;
    default: rb_biu_pe_req_ptr[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  endcase
end

assign rb_biu_pe_req_addr[31:0]
    = {32{rb_biu_pe_req_ptr[0]}} & rb_entry_addr[0][31:0]
    | {32{rb_biu_pe_req_ptr[1]}} & rb_entry_addr[1][31:0]
    | {32{rb_biu_pe_req_ptr[2]}} & rb_entry_addr[2][31:0]
    | {32{rb_biu_pe_req_ptr[3]}} & rb_entry_addr[3][31:0];

//-------------------ld/st biu pop req----------------------
assign rb_ld_biu_pe_req = rb_create_ld_success
                          && !ld_da_rb_data_vld;

assign rb_pipe_biu_pe_req = rb_biu_pe_req
                            || rb_ld_biu_pe_req;

//---------------------pe_req_grnt-------------------------
assign rb_biu_pe_req_permit = !rb_biu_req_unmask
                              || rb_read_req_grnt
                              || rb_biu_req_flush_clear;
assign rb_entry_biu_pe_req_grnt[RB_ENTRY-1:0] =
                {RB_ENTRY{rb_biu_pe_req_permit}}
                & rb_biu_pe_req_ptr[RB_ENTRY-1:0];

assign rb_ld_biu_pe_req_grnt = rb_biu_pe_req_permit
                               && !rb_biu_pe_req
                               && rb_ld_biu_pe_req;

//-----------------flush clear in coror----------------------
assign rb_biu_req_flush_clear = ( |(rb_biu_req_ptr[RB_ENTRY-1:0]
                                    & rb_entry_flush_clear[RB_ENTRY-1:0]))
                                && rb_biu_req_unmask;

//==========================================================
//                      Request biu
//==========================================================
assign rb_biu_req_hit_idx = wmb_rb_biu_req_hit_idx
                            || lfb_rb_biu_req_hit_idx
                            || vb_rb_biu_req_hit_idx;

//----------ar channel------------------
assign rb_biu_ar_req = rb_biu_req_unmask
                       && !rb_biu_req_flush_clear
                       && !rb_biu_req_hit_idx
                       && !lfb_addr_full
                       && lfb_rb_ca_rready_grnt;

assign rb_biu_ar_addr[31:0] = {rb_biu_req_addr[31:4],4'b0};
assign rb_biu_ar_id[3:0]    = lfb_rb_create_id[3:0];
// fixed: 2-beat burst (32B linefill), 16B/beat
assign rb_biu_ar_len[1:0]   = 2'b01;
assign rb_biu_ar_size[2:0]  = 3'b100;
assign rb_biu_ar_burst[1:0] = 2'b10;   // WRAP
assign rb_biu_ar_lock       = 1'b0;
assign rb_biu_ar_cache[3:0] = 4'b1111; // cacheable + bufferable
assign rb_biu_ar_prot[2:0]  = 3'b000;

//-----------------biu grnt signal--------------------------
assign rb_read_req_grnt = bus_arb_rb_ar_grnt;
assign rb_entry_read_req_grnt[RB_ENTRY-1:0] =
                {RB_ENTRY{rb_read_req_grnt}}
                & rb_biu_req_ptr[RB_ENTRY-1:0];

//==========================================================
//                  Request ld_wb stage
//==========================================================
//------------------wb cmplt part signal--------------------
assign rb_ld_wb_cmplt_req = |rb_entry_wb_cmplt_req[RB_ENTRY-1:0];

always @( rb_entry_wb_cmplt_req[RB_ENTRY-1:0])
begin
  rb_ld_wb_cmplt_ptr[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  casez(rb_entry_wb_cmplt_req[RB_ENTRY-1:0])
    4'b???1: rb_ld_wb_cmplt_ptr[0] = 1'b1;
    4'b??10: rb_ld_wb_cmplt_ptr[1] = 1'b1;
    4'b?100: rb_ld_wb_cmplt_ptr[2] = 1'b1;
    4'b1000: rb_ld_wb_cmplt_ptr[3] = 1'b1;
    default: rb_ld_wb_cmplt_ptr[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  endcase
end

assign rb_ld_wb_iid[6:0]
    = {7{rb_ld_wb_cmplt_ptr[0]}} & rb_entry_iid[0][6:0]
    | {7{rb_ld_wb_cmplt_ptr[1]}} & rb_entry_iid[1][6:0]
    | {7{rb_ld_wb_cmplt_ptr[2]}} & rb_entry_iid[2][6:0]
    | {7{rb_ld_wb_cmplt_ptr[3]}} & rb_entry_iid[3][6:0];

assign rb_entry_wb_cmplt_grnt[RB_ENTRY-1:0] = rb_ld_wb_cmplt_ptr[RB_ENTRY-1:0]
                                              & {RB_ENTRY{ld_wb_rb_cmplt_grnt}};

//------------------wb data part signal---------------------
always @( rb_entry_wb_data_pre_sel[RB_ENTRY-1:0])
begin
  rb_ld_wb_data_ptr_pre[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  casez(rb_entry_wb_data_pre_sel[RB_ENTRY-1:0])
    4'b???1: rb_ld_wb_data_ptr_pre[0] = 1'b1;
    4'b??10: rb_ld_wb_data_ptr_pre[1] = 1'b1;
    4'b?100: rb_ld_wb_data_ptr_pre[2] = 1'b1;
    4'b1000: rb_ld_wb_data_ptr_pre[3] = 1'b1;
    default: rb_ld_wb_data_ptr_pre[RB_ENTRY-1:0] = {RB_ENTRY{1'b0}};
  endcase
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_ld_wb_data_ptr[RB_ENTRY-1:0] <= {RB_ENTRY{1'b0}};
  else if (rb_not_empty)
    rb_ld_wb_data_ptr[RB_ENTRY-1:0] <= rb_ld_wb_data_ptr_pre[RB_ENTRY-1:0];
end

assign rb_ld_wb_data_req_unmask = |(rb_ld_wb_data_ptr[RB_ENTRY-1:0] & rb_entry_wb_data_req[RB_ENTRY-1:0]);
assign rb_ld_wb_data_req        = rb_ld_wb_data_req_unmask;

assign rb_ld_wb_inst_size[1:0]
    = {2{rb_ld_wb_data_ptr[0]}} & rb_entry_inst_size[0][1:0]
    | {2{rb_ld_wb_data_ptr[1]}} & rb_entry_inst_size[1][1:0]
    | {2{rb_ld_wb_data_ptr[2]}} & rb_entry_inst_size[2][1:0]
    | {2{rb_ld_wb_data_ptr[3]}} & rb_entry_inst_size[3][1:0];

assign rb_ld_wb_preg[5:0]
    = {7{rb_ld_wb_data_ptr[0]}} & rb_entry_preg[0][6:0]
    | {7{rb_ld_wb_data_ptr[1]}} & rb_entry_preg[1][6:0]
    | {7{rb_ld_wb_data_ptr[2]}} & rb_entry_preg[2][6:0]
    | {7{rb_ld_wb_data_ptr[3]}} & rb_entry_preg[3][6:0];

assign rb_ld_wb_sign_extend = |(rb_ld_wb_data_ptr[RB_ENTRY-1:0] & rb_entry_sign_extend[RB_ENTRY-1:0]);
assign rb_ld_wb_bus_err     = |(rb_ld_wb_data_ptr[RB_ENTRY-1:0] & rb_entry_bus_err[RB_ENTRY-1:0]);

assign rb_ld_wb_bus_err_addr[31:0]
    = {32{rb_ld_wb_data_ptr[0]}} & rb_entry_addr[0][31:0]
    | {32{rb_ld_wb_data_ptr[1]}} & rb_entry_addr[1][31:0]
    | {32{rb_ld_wb_data_ptr[2]}} & rb_entry_addr[2][31:0]
    | {32{rb_ld_wb_data_ptr[3]}} & rb_entry_addr[3][31:0];

assign rb_ld_wb_data_iid[6:0]
    = {7{rb_ld_wb_data_ptr[0]}} & rb_entry_iid[0][6:0]
    | {7{rb_ld_wb_data_ptr[1]}} & rb_entry_iid[1][6:0]
    | {7{rb_ld_wb_data_ptr[2]}} & rb_entry_iid[2][6:0]
    | {7{rb_ld_wb_data_ptr[3]}} & rb_entry_iid[3][6:0];

assign rb_entry_wb_data_grnt[RB_ENTRY-1:0] =
                rb_ld_wb_data_ptr[RB_ENTRY-1:0]
                & {RB_ENTRY{ld_wb_rb_data_grnt && !rtu_yy_xx_flush}};

//==========================================================
//            Settle data to register mode
//==========================================================
assign rb_ld_rot_sel[7:0]
    = {8{rb_ld_wb_data_ptr[0]}} & rb_entry_rot_sel[0][7:0]
    | {8{rb_ld_wb_data_ptr[1]}} & rb_entry_rot_sel[1][7:0]
    | {8{rb_ld_wb_data_ptr[2]}} & rb_entry_rot_sel[2][7:0]
    | {8{rb_ld_wb_data_ptr[3]}} & rb_entry_rot_sel[3][7:0];

always @( rb_entry_data[0][31:0]
       or rb_entry_data[1][31:0]
       or rb_entry_data[2][31:0]
       or rb_entry_data[3][31:0]
       or rb_ld_wb_data_ptr[RB_ENTRY-1:0])
begin
  case(rb_ld_wb_data_ptr[RB_ENTRY-1:0])
    4'b0001: rb_wb_data[31:0] = rb_entry_data[0][31:0];
    4'b0010: rb_wb_data[31:0] = rb_entry_data[1][31:0];
    4'b0100: rb_wb_data[31:0] = rb_entry_data[2][31:0];
    4'b1000: rb_wb_data[31:0] = rb_entry_data[3][31:0];
    default: rb_wb_data[31:0] = {32{1'bx}};
  endcase
end

assign rb_wb_data_unsettle[127:0] = {rb_wb_data[31:0], rb_wb_data[31:0], rb_wb_data[31:0], rb_wb_data[31:0]};

//rotate data
ct_lsu_rot_data x_lsu_rb_wb_data_rot (
  .data_in         (rb_wb_data_unsettle),
  .data_settle_out (rb_ld_wb_data_64  ),
  .rot_sel         (rb_ld_rot_sel      )
);

assign rb_ld_wb_data[31:0] = rb_ld_wb_data_64[31:0];

//------------------select sign bit-------------------------
always @( rb_ld_wb_inst_size[1:0]
       or rb_ld_wb_sign_extend)
begin
  case({rb_ld_wb_sign_extend, rb_ld_wb_inst_size[1:0]})
    {1'b1, 2'b00}: rb_ld_wb_preg_sign_sel[3:0] = 4'b0010; // byte
    {1'b1, 2'b01}: rb_ld_wb_preg_sign_sel[3:0] = 4'b0100; // half
    {1'b1, 2'b10}: rb_ld_wb_preg_sign_sel[3:0] = 4'b1000; // word
    default:       rb_ld_wb_preg_sign_sel[3:0] = 4'b0001;
  endcase
end

//==========================================================
//                    compare index
//==========================================================
assign rb_sq_pop_hit_idx = |rb_entry_sq_pop_hit_idx[RB_ENTRY-1:0];
assign rb_ld_da_hit_idx  = |rb_entry_ld_da_hit_idx[RB_ENTRY-1:0];
assign rb_st_da_hit_idx  = |rb_entry_st_da_hit_idx[RB_ENTRY-1:0];

//==========================================================
//        interface to other module (except biu_arb)
//==========================================================
//------------------------lfb-------------------------------
assign rb_lfb_create_req = rb_biu_req_unmask;
assign rb_lfb_depd       = |(rb_biu_req_ptr[RB_ENTRY-1:0]
                             & (rb_entry_depd[RB_ENTRY-1:0]
                                | rb_entry_discard_vld[RB_ENTRY-1:0]));
assign rb_lfb_addr_tto4[27:0] = rb_biu_req_addr[31:4];

assign rb_lfb_create_vld = bus_arb_rb_ar_grnt;
assign rb_lfb_boundary_depd_wakeup = |(rb_entry_boundary_wakeup[RB_ENTRY-1:0]);



endmodule
