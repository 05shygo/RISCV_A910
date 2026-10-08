module ct_lsu_st_da #(
  parameter int DCACHE_SIZE = 2048,  // 1024, 2048, 4096 bytes
  parameter int LSIQ_ENTRY = 8,
  parameter int CACHELINE_SIZE = 32,
  parameter int NUM_WAYS = 2,
  parameter int OFFSET_WIDTH = 5,
  parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
  parameter int INDEX_WIDTH = $clog2(NUM_SETS),
  parameter int DATA_INDEX_WIDTH = INDEX_WIDTH + 1,
  parameter int TAG_LSB = OFFSET_WIDTH + INDEX_WIDTH,
  parameter int TAG_WIDTH = 32 - TAG_LSB,
  parameter int ST_TAG_ARRAY_WIDTH = TAG_WIDTH * 2 // 2 ways
)(
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic [4:0]   dcache_dirty_din,
  input  logic         dcache_dirty_gwen,
  input  logic [4:0]   dcache_dirty_wen,
  input  logic [INDEX_WIDTH-1:0] dcache_idx,
  input  logic [ST_TAG_ARRAY_WIDTH-1:0] dcache_tag_din,
  input  logic         dcache_tag_gwen,
  input  logic [1:0]   dcache_tag_wen,
  input  logic         ld_da_st_da_hit_idx,
  input  logic         lfb_st_da_hit_idx,
  input  logic         rb_st_da_full,
  input  logic         rb_st_da_hit_idx,
  input  logic         rtu_yy_xx_commit0,
  input  logic [6:0]   rtu_yy_xx_commit0_iid,
  input  logic         rtu_yy_xx_commit1,
  input  logic [6:0]   rtu_yy_xx_commit1_iid,
  input  logic         rtu_yy_xx_commit2,
  input  logic [6:0]   rtu_yy_xx_commit2_iid,
  input  logic         rtu_yy_xx_flush,
  input  logic [31:0]  st_dc_addr0,
  input  logic         st_dc_borrow_vld,
  input  logic         st_dc_boundary,
  input  logic [15:0]  st_dc_bytes_vld,
  input  logic [4:0]   st_dc_da_dcache_dirty_array,
  input  logic [ST_TAG_ARRAY_WIDTH-1:0] st_dc_da_dcache_tag_array,
  input  logic         st_dc_da_inst_vld,
  input  logic         st_dc_da_tag0_hit,
  input  logic         st_dc_da_tag1_hit,
  input  logic         st_dc_dcwp_hit_idx,
  input  logic         st_dc_get_dcache_tag_dirty,
  input  logic [6:0]   st_dc_iid,
  input  logic         st_dc_inst_vld,
  input  logic [LSIQ_ENTRY-1:0] st_dc_lsid,
  input  logic         st_dc_old,
  input  logic         st_dc_expt,
  input  logic         st_dc_secd,
  input  logic         st_dc_spec_fail,

  output logic         st_da_borrow_vld,
  output logic         st_da_dcache_dirty,
  output logic         st_da_dcache_hit,
  output logic         st_da_dcache_miss,
  output logic         st_da_dcache_replace_dirty,
  output logic         st_da_dcache_replace_valid,
  output logic         st_da_dcache_replace_way,
  output logic         st_da_dcache_way,
  output logic         st_da_idu_pop_vld,
  output logic [LSIQ_ENTRY-1:0] st_da_idu_pop_entry,
  output logic [LSIQ_ENTRY-1:0] st_da_idu_rb_full,
  output logic [LSIQ_ENTRY-1:0] st_da_idu_secd,
  output logic [6:0]   st_da_iid,
  output logic         st_da_inst_vld,
  output logic         st_da_old,
  output logic         st_da_rb_cmit,
  output logic         st_da_rb_create_dp_vld,
  output logic         st_da_rb_create_gateclk_en,
  output logic         st_da_rb_create_vld,
  output logic         st_da_secd,
  output logic         st_da_sq_dcache_dirty,
  output logic         st_da_sq_dcache_valid,
  output logic         st_da_sq_dcache_way,
  output logic [21:0]  st_da_vb_feedback_addr_tto10,
  output logic         st_da_wb_cmplt_req,
  output logic         st_da_wb_expt_vld,
  output logic [31:0]  st_da_wb_expt_addr,
  output logic         st_da_wb_spec_fail,
  output logic [31:0]  st_da_addr,
  output logic         st_da_boundary,
  output logic [15:0]  st_da_bytes_vld,
  output logic         st_da_sq_no_restart
);

localparam int INDEX_LSB = OFFSET_WIDTH;
localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;

//==========================================================
//                 Internal Wire/Reg
//==========================================================
logic [31:0]  st_da_addr0;
logic [4:0]   st_da_dcache_dirty_array;
logic [ST_TAG_ARRAY_WIDTH-1:0] st_da_dcache_tag_array;
logic         st_da_tag0_hit;
logic         st_da_tag1_hit;
logic         st_da_spec_fail;
logic [LSIQ_ENTRY-1:0] st_da_lsid;
logic         st_da_dcwp_dc_hit_idx;
logic [4:0]   st_da_dcwp_dc_dirty_din;
logic [4:0]   st_da_dcwp_dc_dirty_wen;

logic         st_da_dcache_info_vld;
logic         st_da_dcache_valid0;
logic         st_da_dcache_valid1;
logic         st_da_hit_way0;
logic         st_da_hit_way1;
logic [1:0]   st_da_dcache_dirty_hit_info;
logic [4:0]   st_da_dirty_dc_update;
logic [4:0]   st_da_dirty_dc_update_dout;
logic [1:0]   st_da_dcache_dirty_dc_up_hit_info;
logic         st_da_dcache_dc_up_dirty;
logic         st_da_dcache_dc_up_valid;
logic         st_da_dcache_dc_up_way;
logic         st_da_dcache_hit_idx;
logic         st_da_dcache_update_vld;
logic         st_da_feedback_sel_tag_way1;
logic         st_da_feedback_sel_tag;
logic         st_da_rb_create_vld_unmask;
logic         st_da_rb_full_vld;
logic         st_da_restart_vld;
logic         st_da_boundary_first;
logic [LSIQ_ENTRY-1:0] st_da_mask_lsid;
logic         st_da_idu_secd_vld;
logic         st_da_cmit_hit0;
logic         st_da_cmit_hit1;
logic         st_da_cmit_hit2;

//==========================================================
//                 Pipeline Register
//==========================================================
always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b)
    st_da_inst_vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    st_da_inst_vld <= 1'b0;
  else if(st_dc_da_inst_vld)
    st_da_inst_vld <= 1'b1;
  else
    st_da_inst_vld <= 1'b0;
end

always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b)
    st_da_borrow_vld <= 1'b0;
  else if(st_dc_borrow_vld)
    st_da_borrow_vld <= 1'b1;
  else
    st_da_borrow_vld <= 1'b0;
end

always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    st_da_dcache_tag_array <= {ST_TAG_ARRAY_WIDTH{1'b0}};
    st_da_dcache_dirty_array <= 5'b0;
    st_da_tag0_hit <= 1'b0;
    st_da_tag1_hit <= 1'b0;
  end
  else if(st_dc_get_dcache_tag_dirty) begin
    st_da_dcache_tag_array <= st_dc_da_dcache_tag_array;
    st_da_dcache_dirty_array <= st_dc_da_dcache_dirty_array;
    st_da_tag0_hit <= st_dc_da_tag0_hit;
    st_da_tag1_hit <= st_dc_da_tag1_hit;
  end
end

logic st_da_expt;
always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    st_da_spec_fail <= 1'b0;
    st_da_secd <= 1'b0;
    st_da_iid <= 7'b0;
    st_da_lsid <= {LSIQ_ENTRY{1'b0}};
    st_da_old <= 1'b0;
    st_da_expt<= 1'b0;
    st_da_boundary <= 1'b0;
    st_da_bytes_vld <= 16'b0;
  end
  else if(st_dc_inst_vld) begin
    st_da_spec_fail <= st_dc_spec_fail;
    st_da_secd <= st_dc_secd;
    st_da_iid <= st_dc_iid;
    st_da_lsid <= st_dc_lsid;
    st_da_old <= st_dc_old;
    st_da_expt<= st_dc_expt;
    st_da_boundary <= st_dc_boundary;
    st_da_bytes_vld <= st_dc_bytes_vld;
  end
end

always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    st_da_addr0 <= 32'b0;
    st_da_dcwp_dc_hit_idx <= 1'b0;
    st_da_dcwp_dc_dirty_din <= 5'b0;
    st_da_dcwp_dc_dirty_wen <= 5'b0;
  end
  else if(st_dc_inst_vld || st_dc_borrow_vld) begin
    st_da_addr0 <= st_dc_addr0;
    st_da_dcwp_dc_hit_idx <= st_dc_dcwp_hit_idx;
    st_da_dcwp_dc_dirty_din <= dcache_dirty_din;
    st_da_dcwp_dc_dirty_wen <= dcache_dirty_wen;
  end
end
//==========================================================
//              Compare tag and select data
//==========================================================
assign st_da_dcache_info_vld = st_da_inst_vld || st_da_borrow_vld;

assign st_da_dcache_valid0 = st_da_dcache_dirty_array[0] && st_da_dcache_info_vld;
assign st_da_dcache_valid1 = st_da_dcache_dirty_array[2] && st_da_dcache_info_vld;

assign st_da_hit_way0 = st_da_dcache_valid0 && st_da_tag0_hit;
assign st_da_hit_way1 = st_da_dcache_valid1 && st_da_tag1_hit;

assign st_da_dcache_hit = st_da_hit_way0 || st_da_hit_way1;
assign st_da_dcache_miss = !st_da_dcache_hit;

assign st_da_dcache_dirty_hit_info[1:0] =
  {2{st_da_hit_way0}} & st_da_dcache_dirty_array[1:0] |
  {2{st_da_hit_way1}} & st_da_dcache_dirty_array[3:2];

assign st_da_dcache_dirty = st_da_dcache_dirty_hit_info[1];
assign st_da_dcache_way = st_da_hit_way1;

assign st_da_dcache_replace_way = st_da_dcache_hit ? st_da_hit_way1 : st_da_dcache_dirty_array[4];
assign st_da_dcache_replace_dirty = st_da_dcache_replace_way ? st_da_dcache_dirty_array[3] : st_da_dcache_dirty_array[1];
assign st_da_dcache_replace_valid = st_da_dcache_replace_way ? st_da_dcache_dirty_array[2] : st_da_dcache_dirty_array[0];

//==========================================================
//          Feedback address to VB
//==========================================================
assign st_da_feedback_sel_tag_way1 = st_da_dcache_replace_way && st_da_borrow_vld;
assign st_da_feedback_sel_tag = st_da_borrow_vld;

always_comb begin
  st_da_vb_feedback_addr_tto10 = st_da_addr0[31:10];
  case({st_da_feedback_sel_tag, st_da_feedback_sel_tag_way1})
    2'b10: st_da_vb_feedback_addr_tto10 = st_da_dcache_tag_array[21:0];
    2'b11: st_da_vb_feedback_addr_tto10 = st_da_dcache_tag_array[ST_TAG_ARRAY_WIDTH-1:22];
    default: st_da_vb_feedback_addr_tto10 = st_da_addr0[31:10];
  endcase
end

//==========================================================
//          Dirty array update da stage for sq
//==========================================================
assign st_da_dirty_dc_update[4:0] = {5{st_da_dcwp_dc_hit_idx}} & st_da_dcwp_dc_dirty_wen[4:0];

assign st_da_dirty_dc_update_dout[4:0] =
  st_da_dirty_dc_update[4:0] & st_da_dcwp_dc_dirty_din[4:0] |
  (~st_da_dirty_dc_update[4:0]) & st_da_dcache_dirty_array[4:0];

assign st_da_dcache_dirty_dc_up_hit_info[1:0] =
  {2{st_da_hit_way0}} & st_da_dirty_dc_update_dout[1:0] |
  {2{st_da_hit_way1}} & st_da_dirty_dc_update_dout[3:2];

assign st_da_dcache_dc_up_dirty = st_da_dcache_dirty_dc_up_hit_info[1];
assign st_da_dcache_dc_up_valid = st_da_dcache_dirty_dc_up_hit_info[0];
assign st_da_dcache_dc_up_way = st_da_dcache_way;

lsu_dcache_info_update x_lsu_st_da_dcache_info_update (
  .compare_dcwp_addr       (st_da_addr0),
  .dcache_dirty_din        (dcache_dirty_din[4:0]),
  .dcache_dirty_gwen       (dcache_dirty_gwen),
  .dcache_dirty_wen        (dcache_dirty_wen[4:0]),
  .dcache_idx              (dcache_idx[4:0]),
  .dcache_tag_din          (dcache_tag_din[43:0]),
  .dcache_tag_gwen         (dcache_tag_gwen),
  .dcache_tag_wen          (dcache_tag_wen),
  .origin_dcache_dirty     (st_da_dcache_dc_up_dirty),
  .origin_dcache_valid     (st_da_dcache_dc_up_valid),
  .origin_dcache_way       (st_da_dcache_dc_up_way),
  .compare_dcwp_hit_idx    (st_da_dcache_hit_idx),
  .compare_dcwp_update_vld (st_da_dcache_update_vld),
  .update_dcache_dirty     (st_da_sq_dcache_dirty),
  .update_dcache_valid     (st_da_sq_dcache_valid),
  .update_dcache_way       (st_da_sq_dcache_way)
);
//==========================================================
//        Generate commit signal
//==========================================================
assign st_da_cmit_hit0 = {rtu_yy_xx_commit0, rtu_yy_xx_commit0_iid[6:0]} == {1'b1, st_da_iid[6:0]};
assign st_da_cmit_hit1 = {rtu_yy_xx_commit1, rtu_yy_xx_commit1_iid[6:0]} == {1'b1, st_da_iid[6:0]};
assign st_da_cmit_hit2 = {rtu_yy_xx_commit2, rtu_yy_xx_commit2_iid[6:0]} == {1'b1, st_da_iid[6:0]};

assign st_da_rb_cmit = st_da_cmit_hit0 || st_da_cmit_hit1 || st_da_cmit_hit2;

//==========================================================
//        Request read buffer & Compare index
//==========================================================
assign st_da_rb_create_vld_unmask = st_da_inst_vld && st_da_dcache_miss && !st_da_expt;

assign st_da_addr[31:0] = st_da_addr0[31:0];

assign st_da_rb_create_vld = st_da_rb_create_vld_unmask &&
                             !ld_da_st_da_hit_idx &&
                             !rb_st_da_hit_idx &&
                             !lfb_st_da_hit_idx;

assign st_da_rb_create_dp_vld = st_da_rb_create_vld;
assign st_da_rb_create_gateclk_en = st_da_rb_create_vld;

//==========================================================
//        Restart signal
//==========================================================
assign st_da_rb_full_vld = st_da_rb_create_vld_unmask && rb_st_da_full;
assign st_da_restart_vld = st_da_rb_full_vld;

//==========================================================
//        Generate to WB stage signal
//==========================================================
assign st_da_boundary_first = st_da_boundary && !st_da_secd;
assign st_da_wb_cmplt_req = st_da_inst_vld && !st_da_restart_vld && !st_da_boundary_first;
assign st_da_wb_spec_fail = st_da_spec_fail;
assign st_da_wb_expt_vld = st_da_expt;
assign st_da_wb_expt_addr= st_da_addr0;

assign st_da_sq_no_restart = st_da_inst_vld && !st_da_restart_vld;

//==========================================================
//        Generate lsiq signal
//==========================================================
assign st_da_mask_lsid[LSIQ_ENTRY-1:0] = {LSIQ_ENTRY{st_da_inst_vld}} & st_da_lsid[LSIQ_ENTRY-1:0];

assign st_da_idu_rb_full[LSIQ_ENTRY-1:0] = {LSIQ_ENTRY{st_da_rb_full_vld}} & st_da_mask_lsid[LSIQ_ENTRY-1:0];

assign st_da_idu_pop_vld = st_da_wb_cmplt_req;
assign st_da_idu_pop_entry[LSIQ_ENTRY-1:0] = {LSIQ_ENTRY{st_da_idu_pop_vld}} & st_da_mask_lsid[LSIQ_ENTRY-1:0];

assign st_da_idu_secd_vld = st_da_inst_vld && st_da_boundary_first && !st_da_restart_vld && !st_da_expt;
assign st_da_idu_secd[LSIQ_ENTRY-1:0] = {LSIQ_ENTRY{st_da_idu_secd_vld}} & st_da_mask_lsid[LSIQ_ENTRY-1:0];

endmodule


