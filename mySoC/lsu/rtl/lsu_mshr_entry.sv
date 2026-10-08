module lsu_mshr_entry #(
    parameter int DCACHE_SIZE = 2048,  // 1024, 2048, or 4096 bytes
    // Derived parameters for dcache indexing
    parameter int CACHELINE_SIZE = 32,
    parameter int NUM_WAYS = 2,
    parameter int OFFSET_WIDTH = 5,
    parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
    parameter int INDEX_WIDTH = $clog2(NUM_SETS),
    parameter int INDEX_LSB = OFFSET_WIDTH,
    parameter int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1,
    parameter int TAG_LSB = INDEX_MSB + 1,
    parameter int TAG_WIDTH = 32 - TAG_LSB
)(
    // ---------------- inputs ----------------
    input  logic [127:0] biu_lsu_r_data_mask,
    input  logic [3:0]   biu_lsu_r_id,
    input  logic         biu_lsu_r_vld,
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [31:0]  ld_da_addr,
    input  logic         ld_da_boundary_after_mask,
    input  logic [15:0]  ld_da_bytes_vld,
    input  logic [31:0]  ld_da_data_ori,
    input  logic [7:0]   ld_da_data_rot_sel,
    input  logic [INDEX_WIDTH-1:0] ld_da_idx,
    input  logic [6:0]   ld_da_iid,
    input  logic [1:0]   ld_da_inst_size,
    input  logic [5:0]   ld_da_preg,
    input  logic         ld_da_rb_cmit,
    input  logic         ld_da_rb_data_vld,
    input  logic         ld_da_rb_discard_grnt,
    input  logic         ld_da_rb_merge_vld,
    input  logic         ld_da_sign_extend,
    input  logic [3:0]   rb_biu_ar_id,
    input  logic         rb_entry_biu_pe_req_grnt_x,
    input  logic         rb_entry_ld_create_vld_x,
    input  logic         rb_entry_read_req_grnt_x,
    input  logic         rb_entry_st_create_vld_x,
    input  logic         rb_entry_wb_cmplt_grnt_x,
    input  logic         rb_entry_wb_data_grnt_x,
    input  logic         rb_ld_biu_pe_req_grnt,
    input  logic         rb_r_resp_err,
    input  logic         rtu_yy_xx_commit0,
    input  logic [6:0]   rtu_yy_xx_commit0_iid,
    input  logic         rtu_yy_xx_commit1,
    input  logic [6:0]   rtu_yy_xx_commit1_iid,
    input  logic         rtu_yy_xx_commit2,
    input  logic [6:0]   rtu_yy_xx_commit2_iid,
    input  logic         rtu_yy_xx_flush,
    input  logic [31:0]  sq_pop_addr,
    input  logic [31:0]  st_da_addr,
    input  logic [15:0]  st_da_bytes_vld,
    input  logic         st_da_dcache_hit,
    input  logic [6:0]   st_da_iid,
    input  logic         st_da_rb_cmit,
    input  logic [31:0]  wmb_ce_addr,
    // ---------------- outputs ----------------
    output logic [31:0]  rb_entry_addr_v,
    output logic         rb_entry_biu_pe_req_x,
    output logic         rb_entry_biu_req_x,
    output logic         rb_entry_boundary_wakeup_x,
    output logic         rb_entry_bus_err_x,
    output logic         rb_entry_create_lfb_x,
    output logic [31:0]  rb_entry_data_v,
    output logic         rb_entry_depd_x,
    output logic         rb_entry_discard_vld_x,
    output logic         rb_entry_flush_clear_x,
    output logic [6:0]   rb_entry_iid_v,
    output logic [1:0]   rb_entry_inst_size_v,
    output logic         rb_entry_ld_da_hit_idx_x,
    output logic         rb_entry_merge_fail_x,
    output logic [5:0]   rb_entry_preg_v,
    output logic [7:0]   rb_entry_rot_sel_v,
    output logic         rb_entry_sign_extend_x,
    output logic         rb_entry_sq_pop_hit_idx_x,
    output logic         rb_entry_st_da_hit_idx_x,
    output logic         rb_entry_vld_x,
    output logic         rb_entry_wb_cmplt_req_x,
    output logic         rb_entry_wb_data_pre_sel_x,
    output logic         rb_entry_wb_data_req_x,
    output logic         rb_entry_wmb_ce_hit_idx_x
);

// ---------------- internal registers ----------------
logic [31:0] rb_entry_addr;
logic [3:0]  rb_entry_biu_id;
logic        rb_entry_biu_pe_req_success;
logic        rb_entry_boundary;
logic        rb_entry_boundary_depd;
logic        rb_entry_bus_err;
logic [15:0] rb_entry_bytes_vld;
logic        rb_entry_cmit;
logic        rb_entry_create_lfb;
logic [63:0] rb_entry_data;
logic        rb_entry_depd;
logic        rb_entry_dest_vld;
logic [6:0]  rb_entry_iid;
logic [1:0]  rb_entry_inst_size;
logic [3:0]  rb_entry_next_state;
logic [5:0]  rb_entry_preg;
logic [7:0]  rb_entry_rot_sel;
logic        rb_entry_secd;
logic        rb_entry_sign_extend;
logic        rb_entry_st;
logic [3:0]  rb_entry_state;
logic        rb_entry_wb_cmplt_success;
logic        rb_entry_wb_data_success;

// ---------------- internal combinational/wire signals ----------------
logic [127:0] rb_entry_biu_data_ori;
logic [63:0]  rb_entry_biu_data_update;
logic         rb_entry_biu_pe_req;
logic         rb_entry_biu_pe_req_grnt;
logic         rb_entry_biu_r_resp_set;
logic         rb_entry_biu_req;
logic         rb_entry_biu_req_success;
logic         rb_entry_boundary_depd_set;
logic         rb_entry_boundary_wakeup;
logic         rb_entry_bus_err_set;
logic         rb_entry_cmit_data_not_vld;
logic         rb_entry_cmit_hit0;
logic         rb_entry_cmit_hit1;
logic         rb_entry_cmit_hit2;
logic         rb_entry_cmit_set;
logic [31:0]  rb_entry_cmp_sq_pop_addr;
logic [31:0]  rb_entry_cmp_wmb_ce_addr;
logic         rb_entry_create_vld;
logic         rb_entry_data_bypass_vld;
logic         rb_entry_data_merge_vld;
logic         rb_entry_discard_vld;
logic         rb_entry_flush_clear;
logic         rb_entry_iid_hit;
logic         rb_entry_ld_create_vld;
logic         rb_entry_ld_da_hit_idx;
logic         rb_entry_ld_merge_pre;
logic         rb_entry_ld_merge_vld;
logic [7:0]   rb_entry_merge_bytes_vld;
logic [63:0]  rb_entry_merge_data;
logic [63:0]  rb_entry_merge_data_ori;
logic [63:0]  rb_entry_merge_data_sel;
logic         rb_entry_merge_fail;
logic         rb_entry_merge_sel;
logic         rb_entry_r_id_hit;
logic         rb_entry_read_req_grnt;
logic         rb_entry_req_wb_success;
logic         rb_entry_sq_pop_cmp_vld;
logic         rb_entry_sq_pop_hit_idx;
logic         rb_entry_st_create_vld;
logic         rb_entry_st_da_hit_idx;
logic         rb_entry_vld;
logic         rb_entry_wait_resp_to_req_merge;
logic         rb_entry_wb_cmplt_grnt;
logic         rb_entry_wb_cmplt_req;
logic         rb_entry_wb_data_grnt;
logic         rb_entry_wb_data_req;
logic         rb_entry_wb_data_req_pre;
logic         rb_entry_wmb_ce_cmp_vld;


//the state machine is devided to 2 part:
//before request biu: state[2] = 0
//after request biu:  state[2] = 1
parameter IDLE        = 4'b0000,
          REQ_BIU     = 4'b1001,
          WAIT_RESP   = 4'b1100,
          REQ_WB      = 4'b1101,
          WAIT_MERGE  = 4'b1110;

//==========================================================
//                 Register
//==========================================================
//+-------+
//| state |
//+-------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_state[3:0]         <=  IDLE;
  else
    rb_entry_state[3:0]         <=  rb_entry_next_state[3:0];
end
assign rb_entry_vld             = rb_entry_state[3];
assign rb_entry_biu_req_success = rb_entry_state[2];

//+------+
//| cmit |
//+------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_cmit             <=  1'b0;
  else if(rb_entry_ld_create_vld)
    rb_entry_cmit             <=  ld_da_rb_cmit;
  else if(rb_entry_st_create_vld)
    rb_entry_cmit             <=  st_da_rb_cmit;
  else if(rb_entry_cmit_set)
    rb_entry_cmit             <=  1'b1;
end

//+-------------------------+
//| instruction information |
//+-------------------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    rb_entry_addr[31:0]  <=  {32{1'b0}};
    rb_entry_bytes_vld[15:0]  <=  16'b0;
    rb_entry_iid[6:0]         <=  7'b0;
    rb_entry_sign_extend      <=  1'b0;
    rb_entry_boundary         <=  1'b0;
    rb_entry_preg[5:0]        <=  7'b0;
    rb_entry_st               <=  1'b0;
    rb_entry_inst_size[1:0]   <=  2'b0;
    rb_entry_create_lfb       <=  1'b0;
  end
  else if(rb_entry_ld_merge_vld)
  begin
    rb_entry_addr[31:0]  <=  ld_da_addr[31:0];
    rb_entry_bytes_vld[15:0]  <=  ld_da_bytes_vld[15:0];
    rb_entry_iid[6:0]         <=  ld_da_iid[6:0];
    rb_entry_sign_extend      <=  ld_da_sign_extend;
    rb_entry_boundary         <=  ld_da_boundary_after_mask;
    rb_entry_preg[5:0]        <=  ld_da_preg[5:0];
    rb_entry_st               <=  1'b0;
    rb_entry_inst_size[1:0]   <=  ld_da_inst_size[1:0];
  end
  else if(rb_entry_ld_create_vld)
  begin
    rb_entry_addr[31:0]  <=  ld_da_addr[31:0];
    rb_entry_bytes_vld[15:0]  <=  ld_da_bytes_vld[15:0];
    rb_entry_iid[6:0]         <=  ld_da_iid[6:0];
    rb_entry_sign_extend      <=  ld_da_sign_extend;
    rb_entry_boundary         <=  ld_da_boundary_after_mask;
    rb_entry_preg[5:0]        <=  ld_da_preg[5:0];
    rb_entry_st               <=  1'b0;
    rb_entry_inst_size[1:0]   <=  ld_da_inst_size[1:0];
  end
  else if(rb_entry_st_create_vld)
  begin
    rb_entry_addr[31:0]  <=  st_da_addr[31:0];
    rb_entry_bytes_vld[15:0]  <=  st_da_bytes_vld[15:0];
    rb_entry_iid[6:0]         <=  st_da_iid[6:0];
    rb_entry_sign_extend      <=  1'b0;
    rb_entry_boundary         <=  1'b0;
    rb_entry_preg[5:0]        <=  7'b0;
    rb_entry_st               <=  1'b1;
    rb_entry_inst_size[1:0]   <=  2'b0;
  end
end

//+---------+
//| rot_sel |
//+---------+
//used for rot sel
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_rot_sel[7:0]     <=  8'b0;
  else if(rb_entry_ld_create_vld)
    rb_entry_rot_sel[7:0]     <=  ld_da_data_rot_sel[7:0];
end

//+------+
//| secd |
//+------+
//secd must be accurate, so it use set signal
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_secd             <=  1'b0;
  else if(rb_entry_ld_merge_vld)
    rb_entry_secd             <=  1'b1;
  else if(rb_entry_ld_create_vld ||  rb_entry_st_create_vld)
    rb_entry_secd             <=  1'b0;
end

//+------+
//| depd |
//+------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_depd             <=  1'b0;
  else if(rb_entry_ld_merge_vld ||  rb_entry_create_vld)
    rb_entry_depd             <=  1'b0;
  else if(rb_entry_discard_vld)
    rb_entry_depd             <=  1'b1;
end

//+---------------+
//| boundary_depd |
//+---------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_boundary_depd       <=  1'b0;
  else if(rb_entry_create_vld  ||  rb_entry_boundary_wakeup)
    rb_entry_boundary_depd       <=  1'b0;
  else if(rb_entry_boundary_depd_set)
    rb_entry_boundary_depd       <=  1'b1;
end

//+----------+
//| dest_vld |
//+----------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_dest_vld         <=  1'b0;
  else if(rb_entry_ld_create_vld)
    rb_entry_dest_vld         <=  1'b1;
  else if(rb_entry_st_create_vld)
    rb_entry_dest_vld         <=  1'b0;
end

//+------+
//| data |
//+------+
assign rb_entry_data_merge_vld = rb_entry_ld_merge_vld &&  ld_da_rb_data_vld
                                 || rb_entry_data_bypass_vld && rb_entry_secd;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_data[31:0]       <=  32'b0;
  else if(rb_entry_data_merge_vld)
    rb_entry_data[31:0]       <=  rb_entry_merge_data[31:0];
  else if(rb_entry_data_bypass_vld)
    rb_entry_data[31:0]       <=  rb_entry_biu_data_update[31:0];
  else if(rb_entry_ld_create_vld &&  ld_da_rb_data_vld)
    rb_entry_data[31:0]       <=  ld_da_data_ori[31:0];
end


//+-----------------+
//| wb_data_success |
//+-----------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_wb_data_success  <=  1'b0;
  else if(rb_entry_ld_create_vld)
    rb_entry_wb_data_success  <=  1'b0;
  else if(rb_entry_st_create_vld)
    rb_entry_wb_data_success  <=  1'b1;
  else if(rb_entry_wb_data_grnt)
    rb_entry_wb_data_success  <=  1'b1;
end

//+--------+
//| biu_id |
//+--------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_biu_id[3:0]    <=  4'b0;
  else if(rb_entry_read_req_grnt)
    rb_entry_biu_id[3:0]    <=  rb_biu_ar_id[3:0];
end

//+---------+
//| bus_err |
//+---------+
//ecc err will not carry bus err expt
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    rb_entry_bus_err        <=  1'b0;
  end
  else if(rb_entry_create_vld)
  begin
    rb_entry_bus_err        <=  1'b0;
  end
  else if(rb_entry_bus_err_set)
  begin
    rb_entry_bus_err        <=  1'b1;
  end
end

//+-----------------------+
//| biu_pop_entry_success |
//+-----------------------+
//this signal represents request biu_pop_entry successfully
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    rb_entry_biu_pe_req_success   <=  1'b0;
  else if(rb_entry_ld_create_vld &&  rb_ld_biu_pe_req_grnt)
    rb_entry_biu_pe_req_success   <=  1'b1;
  else if(rb_entry_create_vld  ||  rb_entry_ld_merge_vld)
    rb_entry_biu_pe_req_success   <=  1'b0;
  else if(rb_entry_biu_pe_req_grnt)
    rb_entry_biu_pe_req_success   <=  1'b1;
end

//==========================================================
//                 Generate create/cmit signal
//==========================================================
//------------------create read buffer signal---------------

assign rb_entry_create_vld    = rb_entry_ld_create_vld
                                ||  rb_entry_st_create_vld;
//------------------commit set signal-----------------------
assign rb_entry_cmit_hit0       = {rtu_yy_xx_commit0,rtu_yy_xx_commit0_iid[6:0]}
                                  ==  {1'b1,rb_entry_iid[6:0]};
assign rb_entry_cmit_hit1       = {rtu_yy_xx_commit1,rtu_yy_xx_commit1_iid[6:0]}
                                  ==  {1'b1,rb_entry_iid[6:0]};
assign rb_entry_cmit_hit2       = {rtu_yy_xx_commit2,rtu_yy_xx_commit2_iid[6:0]}
                                  ==  {1'b1,rb_entry_iid[6:0]};

assign rb_entry_cmit_set  = (rb_entry_cmit_hit0
                                ||  rb_entry_cmit_hit1
                                ||  rb_entry_cmit_hit2)
                            &&  rb_entry_vld;

//==========================================================
//                 Generate next state
//==========================================================
// &CombBeg; @579
always @( rb_entry_state[3:0]
       or rb_entry_ld_create_vld
       or ld_da_boundary_after_mask
       or ld_da_rb_data_vld
       or rb_entry_create_vld
       or rb_entry_flush_clear
       or rb_entry_read_req_grnt
       or rb_entry_wait_resp_to_req_merge
       or rb_entry_biu_r_resp_set
       or rb_entry_req_wb_success
       or rb_entry_ld_merge_vld)
begin
rb_entry_next_state[3:0]  = IDLE;
case(rb_entry_state[3:0])
  IDLE:
    if(rb_entry_ld_create_vld &&  ld_da_boundary_after_mask &&  ld_da_rb_data_vld)
      rb_entry_next_state[3:0]  = WAIT_MERGE;
    else if(rb_entry_create_vld)
      rb_entry_next_state[3:0]  = REQ_BIU;
    else
      rb_entry_next_state[3:0]  = IDLE;
  REQ_BIU:
    if(rb_entry_flush_clear)
      rb_entry_next_state[3:0]  = IDLE;
    else if(rb_entry_read_req_grnt)
      rb_entry_next_state[3:0]  = WAIT_RESP;
    else
      rb_entry_next_state[3:0]  = REQ_BIU;
  WAIT_RESP:
    if(rb_entry_flush_clear)
      rb_entry_next_state[3:0]  = IDLE;
    else if(rb_entry_wait_resp_to_req_merge)
      rb_entry_next_state[3:0]  = WAIT_MERGE;
    else if(rb_entry_biu_r_resp_set)
      rb_entry_next_state[3:0]  = REQ_WB;
    else
      rb_entry_next_state[3:0]  = WAIT_RESP;
  REQ_WB:
    if(rb_entry_req_wb_success | rb_entry_flush_clear)
      rb_entry_next_state[3:0]  = IDLE;
    else
      rb_entry_next_state[3:0]  = REQ_WB;
  WAIT_MERGE:
    if(rb_entry_flush_clear)
      rb_entry_next_state[3:0]  = IDLE;
    else if(rb_entry_ld_merge_vld &&  ld_da_rb_data_vld)
      rb_entry_next_state[3:0]  = REQ_WB;
    else if(rb_entry_ld_merge_vld)
      rb_entry_next_state[3:0]  = REQ_BIU;
    else
      rb_entry_next_state[3:0]  = WAIT_MERGE;
  default:rb_entry_next_state[3:0]  = IDLE;
endcase
// &CombEnd; @632
end

//==========================================================
//                 State 0 : idle
//==========================================================
//create ptr0 is used for ld pipe
//create ptr1 is used for st pipe

//==========================================================
//                 State 1 : request biu pipe-exclusive
//==========================================================

assign rb_entry_biu_pe_req      = (rb_entry_biu_req
                                          &&  !rb_entry_biu_pe_req_success)
                                  &&  !rb_entry_flush_clear;
//==========================================================
//                 State 2 : request biu/lfb
//==========================================================
//------------------biu/lfb req-----------------------------
assign rb_entry_biu_req         = rb_entry_state[3:0]  ==  REQ_BIU;

//if request both biu and lfb, then the rb_entry must get two grnt signal, else
//it will not request biu or lfb. it is realized in rb top module.

//rb_entry_read_req_grnt is an input signal and will not generate in the entry.
//==========================================================
//                 State 3 : wait data/resp
//==========================================================
//------------------biu response signal---------------------
assign rb_entry_r_id_hit    = biu_lsu_r_vld
                              &&  (rb_entry_biu_id[3:0]  ==  biu_lsu_r_id[3:0]);

//-----------biu response signal--------
//memory is always cacheable in this RV32I (no MMU) design
assign rb_entry_biu_r_resp_set  = rb_entry_r_id_hit
                                  &&  (rb_entry_state[3:0] ==  WAIT_RESP);

//if non-cacheable ldex, response okay is regarded as bus error
assign rb_entry_bus_err_set     = rb_entry_biu_r_resp_set
                                  &&  rb_r_resp_err;

//------------------data bypass signal----------------------
assign rb_entry_data_bypass_vld = rb_entry_biu_r_resp_set;

//------------------settle data from biu--------------------

assign rb_entry_biu_data_ori[127:0]  =   {{{8{rb_entry_bytes_vld[15]}}  & biu_lsu_r_data_mask[127:120]}
                                         ,{{8{rb_entry_bytes_vld[14]}}  & biu_lsu_r_data_mask[119:112]}
                                         ,{{8{rb_entry_bytes_vld[13]}}  & biu_lsu_r_data_mask[111:104]}
                                         ,{{8{rb_entry_bytes_vld[12]}}  & biu_lsu_r_data_mask[103:96]}
                                         ,{{8{rb_entry_bytes_vld[11]}}  & biu_lsu_r_data_mask[95:88]}
                                         ,{{8{rb_entry_bytes_vld[10]}}  & biu_lsu_r_data_mask[87:80]}
                                         ,{{8{rb_entry_bytes_vld[9]}}   & biu_lsu_r_data_mask[79:72]}
                                         ,{{8{rb_entry_bytes_vld[8]}}   & biu_lsu_r_data_mask[71:64]}
                                         ,{{8{rb_entry_bytes_vld[7]}}   & biu_lsu_r_data_mask[63:56]}
                                         ,{{8{rb_entry_bytes_vld[6]}}   & biu_lsu_r_data_mask[55:48]}
                                         ,{{8{rb_entry_bytes_vld[5]}}   & biu_lsu_r_data_mask[47:40]}
                                         ,{{8{rb_entry_bytes_vld[4]}}   & biu_lsu_r_data_mask[39:32]}
                                         ,{{8{rb_entry_bytes_vld[3]}}   & biu_lsu_r_data_mask[31:24]}
                                         ,{{8{rb_entry_bytes_vld[2]}}   & biu_lsu_r_data_mask[23:16]}
                                         ,{{8{rb_entry_bytes_vld[1]}}   & biu_lsu_r_data_mask[15:8]}
                                         ,{{8{rb_entry_bytes_vld[0]}}   & biu_lsu_r_data_mask[7:0]}};

assign rb_entry_biu_data_update[31:0]  = rb_entry_biu_data_ori[127:96] | rb_entry_biu_data_ori[95:64]
                                         | rb_entry_biu_data_ori[63:32] | rb_entry_biu_data_ori[31:0];
//---------------------merge data---------------------------
assign rb_entry_merge_sel = (rb_entry_state[3:0] ==  WAIT_MERGE);
assign rb_entry_merge_data_ori[31:0]  = rb_entry_merge_sel
                                        ? ld_da_data_ori[31:0]
                                        : rb_entry_biu_data_update[31:0];

assign rb_entry_merge_bytes_vld[3:0]  = rb_entry_merge_sel
                                        ? ld_da_bytes_vld[15:12] | ld_da_bytes_vld[11:8] | ld_da_bytes_vld[7:4] | ld_da_bytes_vld[3:0]
                                        : rb_entry_bytes_vld[15:12] | rb_entry_bytes_vld[11:8] | rb_entry_bytes_vld[7:4] | rb_entry_bytes_vld[3:0];

assign rb_entry_merge_data_sel[31:0]  = {{8{rb_entry_merge_bytes_vld[3]}},
                                         {8{rb_entry_merge_bytes_vld[2]}},
                                         {8{rb_entry_merge_bytes_vld[1]}},
                                         {8{rb_entry_merge_bytes_vld[0]}}};

assign rb_entry_merge_data[31:0]  = rb_entry_data[31:0] & ~rb_entry_merge_data_sel[31:0]
                                    | rb_entry_merge_data_ori[31:0];

//------------------generate next state signal--------------

assign rb_entry_wait_resp_to_req_merge  = rb_entry_biu_r_resp_set
                                          &&  rb_entry_boundary
                                          &&  !rb_entry_secd;

//==========================================================
//                 State 4 : req cmplt/data
//==========================================================
//------------------req cmplt signal------------------------
//so need to request wb cmplt part when grnt
//ldex need to request wb cmplt part when get data
//and only one entry will request cmplt part
assign rb_entry_wb_cmplt_req    = 1'b0;
//------------------req data signal-------------------------
//if get bus error, then it must commit and send bus_err signal
assign rb_entry_wb_data_req     = rb_entry_dest_vld
                                  &&  (rb_entry_state[3:0] ==  REQ_WB)
                                  &&  (!rb_entry_bus_err  ||  rb_entry_cmit)
                                  &&  !rb_entry_wb_data_success;

//for timing, select data_ptr one cycle ahead
assign rb_entry_wb_data_req_pre = rb_entry_biu_r_resp_set
                                  &&  (!rb_entry_boundary
                                      || rb_entry_secd);

assign rb_entry_wb_data_pre_sel = rb_entry_wb_data_req
                                  || rb_entry_wb_data_req_pre;
//------------------generate next state signal--------------
assign rb_entry_req_wb_success     = rb_entry_vld
                                     &&  (rb_entry_wb_data_grnt || rb_entry_wb_data_success);

//==========================================================
//                 State 5 : wait for merge
//==========================================================
//------------------generate merge signal------------------
assign rb_entry_iid_hit         = rb_entry_iid[6:0] ==  ld_da_iid[6:0];
assign rb_entry_ld_merge_pre    = (rb_entry_state[3:0] ==  WAIT_MERGE)
                                  &&  rb_entry_iid_hit;

assign rb_entry_ld_merge_vld    = ld_da_rb_merge_vld
                                  &&  rb_entry_ld_merge_pre;

//------------------boundary depd vld-----------------------
assign rb_entry_merge_fail      = rb_entry_iid_hit
                                  &&  rb_entry_boundary
                                  &&  !rb_entry_secd
                                  &&  rb_entry_vld
                                  &&  (rb_entry_state[3:0] !=  WAIT_MERGE);

assign rb_entry_boundary_depd_set = rb_entry_merge_fail
                                    &&  ld_da_rb_discard_grnt
                                    &&  !rb_entry_ld_da_hit_idx;
//------------------boundary depd clr-----------------------
assign rb_entry_boundary_wakeup   = rb_entry_boundary_depd
                                    &&  (rb_entry_state[3:0] ==  WAIT_MERGE);

//==========================================================
//                 Compare index
//==========================================================
//------------------compare ld_da stage---------------------
//if has requested biu, then it will not compare with ld_da/st_da
assign rb_entry_ld_da_hit_idx   = rb_entry_vld
                                  &&  !rb_entry_biu_req_success
                                  &&  (rb_entry_addr[INDEX_MSB:INDEX_LSB] ==  ld_da_idx[INDEX_WIDTH-1:0]);
//------------------compare st_da stage---------------------
assign rb_entry_st_da_hit_idx   = rb_entry_vld
                                  &&  !rb_entry_biu_req_success
                                  &&  (rb_entry_addr[INDEX_MSB:INDEX_LSB]
                                      ==  st_da_addr[INDEX_MSB:INDEX_LSB]);
//------------------depd_vld--------------------------------
assign rb_entry_discard_vld = ld_da_rb_discard_grnt
                              &&  rb_entry_ld_da_hit_idx;

//------------------compare sq pop entry--------------------
assign rb_entry_cmp_sq_pop_addr[31:0] = sq_pop_addr[31:0];
assign rb_entry_sq_pop_cmp_vld  = !rb_entry_biu_req_success;
assign rb_entry_sq_pop_hit_idx  = rb_entry_sq_pop_cmp_vld
                                  &&  rb_entry_vld
                                  &&  rb_entry_cmit
                                  &&  (rb_entry_addr[INDEX_MSB:INDEX_LSB]
                                      ==  rb_entry_cmp_sq_pop_addr[INDEX_MSB:INDEX_LSB]);

//------------------compare wmb ce entry---------------------
assign rb_entry_cmp_wmb_ce_addr[31:0] = wmb_ce_addr[31:0];
assign rb_entry_wmb_ce_cmp_vld  = !rb_entry_biu_req_success;

assign rb_entry_wmb_ce_hit_idx  = rb_entry_wmb_ce_cmp_vld
                                  &&  rb_entry_vld
                                  &&  rb_entry_cmit
                                  &&  (rb_entry_addr[INDEX_MSB:INDEX_LSB]
                                      ==  rb_entry_cmp_wmb_ce_addr[INDEX_MSB:INDEX_LSB]);                                      
//==========================================================
//                 Flush dest_vld/Pop signal
//==========================================================
//req_biu_success && !cmit will cancel dest_vld
assign rb_entry_flush_clear   = rtu_yy_xx_flush
                                    &&  !rb_entry_cmit;
 //                                       ||  rb_entry_boundary &&  !rb_entry_secd);

//==========================================================
//                 Generate interface
//==========================================================
//------------------input-----------------------------------
//-----------create signal--------------
assign rb_entry_ld_create_vld           = rb_entry_ld_create_vld_x;
assign rb_entry_st_create_vld           = rb_entry_st_create_vld_x;
//-----------grnt signal----------------
assign rb_entry_biu_pe_req_grnt         = rb_entry_biu_pe_req_grnt_x;
assign rb_entry_read_req_grnt           = rb_entry_read_req_grnt_x;
assign rb_entry_wb_cmplt_grnt           = rb_entry_wb_cmplt_grnt_x;
assign rb_entry_wb_data_grnt            = rb_entry_wb_data_grnt_x;
//------------------output----------------------------------
//-----------rb entry signal------------
assign rb_entry_vld_x                   = rb_entry_vld;
assign rb_entry_addr_v[31:0]            = rb_entry_addr[31:0];
assign rb_entry_iid_v[6:0]              = rb_entry_iid[6:0];
assign rb_entry_sign_extend_x           = rb_entry_sign_extend;
assign rb_entry_preg_v[5:0]             = rb_entry_preg[5:0];
assign rb_entry_inst_size_v[1:0]        = rb_entry_inst_size[1:0];
assign rb_entry_depd_x                  = rb_entry_depd;
assign rb_entry_data_v[31:0]            = rb_entry_data[31:0];
assign rb_entry_bus_err_x               = rb_entry_bus_err;
assign rb_entry_flush_clear_x           = rb_entry_flush_clear;
//-----------request--------------------
assign rb_entry_biu_req_x               = rb_entry_biu_req;
assign rb_entry_create_lfb_x            = rb_entry_create_lfb;
assign rb_entry_wb_cmplt_req_x          = rb_entry_wb_cmplt_req;
assign rb_entry_wb_data_req_x           = rb_entry_wb_data_req;
assign rb_entry_boundary_wakeup_x       = rb_entry_boundary_wakeup;
assign rb_entry_merge_fail_x            = rb_entry_merge_fail;
assign rb_entry_biu_pe_req_x            = rb_entry_biu_pe_req;
//-----------hit idx--------------------
assign rb_entry_ld_da_hit_idx_x         = rb_entry_ld_da_hit_idx;
assign rb_entry_st_da_hit_idx_x         = rb_entry_st_da_hit_idx;
assign rb_entry_sq_pop_hit_idx_x        = rb_entry_sq_pop_hit_idx;
assign rb_entry_wmb_ce_hit_idx_x        = rb_entry_wmb_ce_hit_idx;
//-----------other signal---------------
assign rb_entry_discard_vld_x           = rb_entry_discard_vld;
assign rb_entry_rot_sel_v[7:0]          = rb_entry_rot_sel[7:0];
assign rb_entry_wb_data_pre_sel_x       = rb_entry_wb_data_pre_sel;

// &ModuleEnd; @1136
endmodule